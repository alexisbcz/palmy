package main

// The interface.
//
// Four regions: a preview of the captions over a real video frame, a waveform
// with the captions laid along it, the caption list — which is where the work
// happens — and a side panel of settings per phase.
//
// Two panels are drawn pixel by pixel through `p.pixels`, because neither is
// expressible as boxes: the waveform is 16384 min/max pairs reduced to the
// width available, and the preview has to composite a decoded video frame,
// then an outlined caption on top of it, at the scale the burn-in will use.

import "core:fmt"
import "core:math"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

RIGHT_W :: 392
PREVIEW_H :: 268
WAVE_H :: 132

MONO :: "font-mono text-[12] leading-[16]"

// A stepper row is label — spacer — minus — value — plus, inside a 392px
// panel. Without `whitespace-nowrap` the label wraps onto a second line and
// the row grows; these two classes keep every one of them a single line.
STEP_LABEL :: "text-[11] text-muted-foreground whitespace-nowrap truncate"
STEP_HINT :: "font-mono text-[10] text-muted-foreground whitespace-nowrap shrink-0"
LABEL :: "text-[11] font-semibold uppercase tracking-wider text-muted-foreground"

// Preview_Ctx and Wave_Ctx live in App_State, not on the stack: `p.pixels`
// keeps the pointer until the tree is painted, which is after the frame has
// been built and this procedure has returned.
Preview_Ctx :: struct {
	fonts:    ^p.Fonts,
	img:      ^p.Image,
	has_img:  bool,
	style:    Caption_Style,
	text:     [512]u8,
	text_n:   int,
	src_w:    int,
	src_h:    int,
	selected: bool,
}

Wave_Ctx :: struct {
	fonts:    ^p.Fonts,
	peaks:    ^Peaks,
	from:     f64,
	span:     f64,
	duration: f64,
	pos:      f64,
	segs:     []Seg,
	sel:      int,
	playing:  bool,
	warn:     []bool,
}

draw :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m)

	p.row(ui, "flex-1 min-h-0 w-full")
	{
		p.col(ui, "flex-1 min-w-0 h-full min-h-0 border-r border-border")
		{
			preview_panel(ui, fonts, m)
			wave_panel(ui, fonts, m)
			transport(ui, m)
			caption_list(ui, fonts, m)
		}
		p.end(ui)

		p.col(ui, "h-full min-h-0")
		p.style(ui).w = p.px(RIGHT_W)
		{
			side_panel(ui, fonts, m)
		}
		p.end(ui)
	}
	p.end(ui)

	status_bar(ui, m)

	if m.help {
		help_overlay(ui, m)
	}

	// Last, over everything.
	pick_overlay(ui, m)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.row(ui, "w-full h-12 shrink-0 items-center gap-3 px-4 border-b border-border bg-card")
	defer p.end(ui)

	p.icon(ui, IC_CAPTIONS, "size-5 text-primary")
	p.text(ui, "Captions", "text-sm font-semibold")
	p.text(ui, "local speech to text", "text-[11] text-muted-foreground")

	p.div(ui, "w-px h-5 bg-border mx-1")
	p.end(ui)

	if m.loaded {
		p.icon(ui, m.info.has_video ? IC_FILE_PLAY : IC_AUDIO_WAVEFORM, "size-4 text-muted-foreground")
		p.text(ui, base_name(m.info.path), "text-sm font-medium truncate max-w-[280]")
		sc.badge(ui, clock(m.info.duration), .Secondary)
		if m.info.has_video {
			sc.badge(ui, fmt.tprintf("%dx%d", m.info.width, m.info.height), .Outline)
		}
	} else {
		p.text(ui, "no file open — press o", "text-sm text-muted-foreground")
	}

	p.spacer(ui)

	if len(m.segs) > 0 {
		n_warn := 0
		for _, i in m.segs {
			if seg_warnings(m.segs[:], i, m.limits) != {} {
				n_warn += 1
			}
		}
		sc.badge(ui, fmt.tprintf("%d captions", len(m.segs)), .Secondary)
		if n_warn > 0 {
			sc.badge_icon(ui, fmt.tprintf("%d to check", n_warn), IC_TRIANGLE_ALERT, .Destructive)
		} else {
			sc.badge_icon(ui, "all within limits", IC_CHECK, .Outline)
		}
		if m.dirty {
			sc.badge(ui, "unsaved", .Destructive)
		}
	}
	if m.rtf > 0 {
		sc.badge_icon(ui, fmt.tprintf("%.1fx realtime", m.rtf), IC_GAUGE, .Outline)
	}

	p.row(ui, "items-center gap-1.5 h-7 px-2 rounded-md hover:bg-accent cursor-pointer")
	if p.clickable(ui) {
		m.help = !m.help
	}
	p.text(ui, "?", "text-[12] font-semibold text-muted-foreground")
	p.text(ui, "keys", "text-[11] text-muted-foreground")
	p.end(ui)
}

base_name :: proc(path: string) -> string {
	if at := strings.last_index_byte(path, '/'); at >= 0 {
		return path[at + 1:]
	}
	return path
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

preview_panel :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State) {
	p.row(ui, "w-full shrink-0 gap-0 border-b border-border bg-[#0b0b0d]")
	p.style(ui).h = p.px(PREVIEW_H)
	defer p.end(ui)

	// The live caption at the playhead, which is what the preview shows.
	active := seg_at(m.segs[:], m.pos)
	if active < 0 && m.sel >= 0 && m.sel < len(m.segs) {
		active = m.sel // nothing playing: style against the selected line
	}
	ctx := &m.prev_ctx
	ctx.fonts = fonts
	ctx.img = &m.preview
	ctx.has_img = m.preview_ok
	ctx.style = m.style
	ctx.src_w = m.info.width > 0 ? m.info.width : 1920
	ctx.src_h = m.info.height > 0 ? m.info.height : 1080
	ctx.selected = active >= 0
	ctx.text_n = 0
	if active >= 0 {
		body := seg_text(m.segs[active])
		n := min(len(body), len(ctx.text))
		copy(ctx.text[:], body[:n])
		ctx.text_n = n
	} else if m.loaded {
		s := "no caption at the playhead"
		copy(ctx.text[:], s)
		ctx.text_n = len(s)
	} else {
		s := "Sample caption"
		copy(ctx.text[:], s)
		ctx.text_n = len(s)
	}

	pix := p.pixels(ui, "flex-1 h-full relative overflow-hidden", ctx, preview_draw)
	if p.clickable(ui, pix) {
		m.pane = .Style
	}

	// A small column of facts beside the frame, so the preview is informative
	// rather than only decorative.
	p.col(ui, "h-full w-[190] shrink-0 gap-1.5 p-3 border-l border-border bg-card")
	{
		p.text(ui, "PREVIEW", LABEL)
		if !m.loaded {
			p.text(ui, "Open a file to see a real frame with the caption over it.", "text-[11] text-muted-foreground")
		} else if !m.info.has_video {
			p.text(ui, "Audio only — the caption is drawn over black at the video size the export will declare.", "text-[11] text-muted-foreground")
		} else if !m.preview_ok {
			p.row(ui, "items-center gap-2")
			sc.spinner(ui, "size-3")
			p.text(ui, "pulling a frame", "text-[11] text-muted-foreground")
			p.end(ui)
		} else {
			p.textf(ui, "text-[11] text-muted-foreground", "frame at %s", clock(m.preview_t))
		}
		p.div(ui, "h-px w-full bg-border my-1")
		p.end(ui)

		fact(ui, "Font size", fmt.tprintf("%.0f px", m.style.size))
		fact(ui, "Outline", m.style.box ? "box" : fmt.tprintf("%.1f px", m.style.outline))
		fact(ui, "Position", position_name(m.style.pos))
		if active >= 0 {
			s := m.segs[active]
			fact(ui, "Reading speed", fmt.tprintf("%.1f cps", cps(s)))
			longest, lines := longest_line(seg_text(s))
			fact(ui, "Longest line", fmt.tprintf("%d chars", longest))
			fact(ui, "Lines", fmt.tprintf("%d", lines))
		}
		p.spacer(ui)
		p.text(ui, "Press 3 for the styling panel", "text-[10] text-muted-foreground")
	}
	p.end(ui)
}

fact :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full items-baseline gap-2")
	defer p.end(ui)
	p.text(ui, label, "text-[11] text-muted-foreground shrink-0 whitespace-nowrap truncate")
	p.spacer(ui)
	p.text(ui, value, "text-[11] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
}

// preview_draw composites the decoded frame and then the caption on top of it,
// at the scale the burn-in will use: the style's sizes are in source-video
// pixels, so everything is multiplied by (preview height / source height).
// What is on screen here is what ffmpeg will render.
preview_draw :: proc(c: ^p.Canvas, r: p.Rect, u: ^Preview_Ctx) {
	p.fill_rect(c, r, p.hex(0x0b0b0d))

	dst := r
	if u.has_img && u.img.w > 0 {
		dst = p.fitted_rect(f32(u.img.w), f32(u.img.h), r, .Contain)
		p.draw_image(c, u.img^, dst)
	} else {
		// No frame: a dark stage at the source aspect ratio, so the caption
		// still sits where it will sit in the file.
		dst = p.fitted_rect(f32(u.src_w), f32(u.src_h), r, .Contain)
		p.fill_rect(c, dst, p.hex(0x15151a))
		step := max(f32(16), dst.h / 10)
		for y := dst.y; y < dst.y + dst.h; y += step {
			p.fill_rect(c, {dst.x, math.floor(y), dst.w, 1}, p.hexa(0xffffff08))
		}
	}

	if u.text_n == 0 {
		return
	}
	text := string(u.text[:u.text_n])
	st := u.style

	// One scale factor for everything: source pixels to preview pixels.
	scale := dst.h / f32(max(u.src_h, 1))
	size := max(f32(6), st.size * scale)
	metrics := p.font_metrics(u.fonts, size, .Sans, st.bold ? .Bold : .Regular)
	line_h := max(size * 1.2, metrics.line)
	wt: p.Font_Weight = st.bold ? .Bold : .Regular

	lines := strings.split(text, "\n", context.temp_allocator)
	widest := f32(0)
	for l in lines {
		widest = max(widest, p.text_width(u.fonts, l, size, .Sans, wt))
	}

	mx := f32(st.margin_x) * scale
	my := f32(st.margin_y) * scale
	block_h := line_h * f32(len(lines))

	// ASS alignment: 1-3 bottom, 4-6 middle, 7-9 top; 1/4/7 left, 2/5/8
	// centre, 3/6/9 right. The preview honours the same mapping so the two
	// cannot disagree.
	al := ass_alignment(st.pos)
	top: f32
	switch (al - 1) / 3 {
	case 0:
		top = dst.y + dst.h - my - block_h
	case 1:
		top = dst.y + (dst.h - block_h) / 2
	case:
		top = dst.y + my
	}

	fill := p.hex(st.fill)
	line_col := p.hex(st.outline_rgb)

	if st.box {
		pad := max(f32(2), st.box_pad * scale)
		box_w := widest + pad * 2
		box_x := box_left(al, dst, mx, box_w)
		// Square corners, because libass's BorderStyle 3 box has square
		// corners and the whole point of this panel is that it agrees with
		// what ffmpeg will render.
		p.fill_rect(
			c,
			{box_x, top - pad, box_w, block_h + pad * 2},
			p.fade(p.hex(st.box_rgb), st.box_opacity),
		)
	}

	for l, i in lines {
		w := p.text_width(u.fonts, l, size, .Sans, wt)
		x := box_left(al, dst, mx, w)
		y := top + line_h * f32(i) + metrics.ascent

		// palmy's text drawing has no stroke, so the outline is the glyph run
		// printed around itself in eight directions. At the sizes captions use
		// that is indistinguishable from a real stroke, and it is the same
		// trick libass's border does at a lower level.
		if !st.box && st.outline > 0 {
			o := max(f32(1), st.outline * scale)
			for d in ([?][2]f32 {
					{-1, 0},
					{1, 0},
					{0, -1},
					{0, 1},
					{-0.7, -0.7},
					{0.7, -0.7},
					{-0.7, 0.7},
					{0.7, 0.7},
				}) {
				p.draw_text(c, u.fonts, l, x + d.x * o, y + d.y * o, size, line_col, .Sans, wt)
			}
		}
		if !st.box && st.shadow > 0 {
			s := st.shadow * scale
			p.draw_text(
				c,
				u.fonts,
				l,
				x + s,
				y + s,
				size,
				p.fade(p.hex(0x000000), 0.45),
				.Sans,
				wt,
			)
		}
		p.draw_text(c, u.fonts, l, x, y, size, fill, .Sans, wt)
	}
}

box_left :: proc(al: int, dst: p.Rect, mx, w: f32) -> f32 {
	switch (al - 1) % 3 {
	case 0:
		return dst.x + mx
	case 1:
		return dst.x + (dst.w - w) / 2
	}
	return dst.x + dst.w - mx - w
}

// ---------------------------------------------------------------------------
// Waveform
// ---------------------------------------------------------------------------

wave_panel :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State) {
	ctx := &m.wave_ctx
	ctx.fonts = fonts
	ctx.peaks = m.peaks
	ctx.duration = m.info.duration
	ctx.span = m.view_span > 0 ? m.view_span : m.info.duration
	ctx.from = m.view_from
	ctx.pos = m.pos
	ctx.segs = m.segs[:]
	ctx.sel = m.sel
	ctx.playing = m.playing

	// Which captions break a rule is computed here, once, so the pixel loop
	// stays a pixel loop.
	if len(m.warn_scratch) != len(m.segs) {
		resize(&m.warn_scratch, len(m.segs))
	}
	for i in 0 ..< len(m.segs) {
		m.warn_scratch[i] = seg_warnings(m.segs[:], i, m.limits) != {}
	}
	ctx.warn = m.warn_scratch[:]

	p.div(ui, "w-full shrink-0 relative border-b border-border bg-card")
	p.style(ui).h = p.px(WAVE_H)
	defer p.end(ui)

	idx := p.pixels(ui, "w-full h-full cursor-crosshair", ctx, wave_draw)
	// `clickable` is what opts an element into hit testing; the press/drag
	// state machine below needs the rect it records.
	_ = p.clickable(ui, idx)
	wave_input(ui, m, idx)

	if !m.loaded {
		p.div(ui, "absolute inset-0 flex-row items-center justify-center gap-2")
		p.icon(ui, IC_AUDIO_WAVEFORM, "size-4 text-muted-foreground")
		p.text(ui, "the waveform appears once a file is open", "text-[11] text-muted-foreground")
		p.end(ui)
	} else if !m.peaks.ready {
		p.div(ui, "absolute inset-0 flex-row items-center justify-center gap-2")
		sc.spinner(ui, "size-3")
		p.text(ui, "decoding the waveform", "text-[11] text-muted-foreground")
		p.end(ui)
	}

	// Over a background, because the ruler's own labels run underneath it.
	p.row(ui, "absolute top-1 right-1.5 px-1.5 py-px rounded bg-card/90 border border-border/60")
	p.textf(
		ui,
		"text-[10] font-mono text-muted-foreground whitespace-nowrap",
		"%s – %s   ·   %s shown",
		clock(ctx.from),
		clock(ctx.from + ctx.span),
		clock(ctx.span),
	)
	p.end(ui)
}

// wave_input turns the pointer into a seek or a drag. palmy reports hover and
// clicks; the press-move-release state machine for a drag is the application's
// own, which is the honest division of labour for a toolkit with no gesture
// recogniser.
wave_input :: proc(ui: ^p.Ctx, m: ^App_State, idx: int) {
	if !m.loaded {
		return
	}
	// This reads the raw pointer state against the waveform's rectangle
	// rather than through palmy's hit testing, so it would happily seek on a
	// press aimed at the file dialog sitting over it.
	if kit.pick_active(&m.pick) {
		return
	}
	id := p.node_id(ui, idx)
	r := p.rect_of(ui, id)
	if r.w <= 0 {
		return
	}
	mouse := p.mouse_pos(ui)
	inside := p.rect_contains(r, mouse[0], mouse[1])
	span := m.view_span > 0 ? m.view_span : m.info.duration
	t_at := m.view_from + f64((mouse[0] - r.x) / r.w) * span

	if p.wheel(ui) != {} && inside {
		w := p.wheel(ui)
		if .Ctrl in ui.input.mods {
			zoom_view(m, w[1] > 0 ? 0.85 : 1 / 0.85)
		} else {
			m.view_from = clamp(
				m.view_from - f64(w[0] + w[1]) * span * 0.08,
				0,
				max(0, m.info.duration - span),
			)
		}
	}

	if ui.input.pressed[.Left] && inside {
		// Within six pixels of the selected caption's edge, the press grabs
		// that edge; over its body it moves the whole caption; anywhere else
		// it is a seek.
		grabbed := Drag_What.Playhead
		if m.sel >= 0 && m.sel < len(m.segs) {
			s := m.segs[m.sel]
			x0 := r.x + f32((s.start - m.view_from) / span) * r.w
			x1 := r.x + f32((s.end - m.view_from) / span) * r.w
			if abs_f32(mouse[0] - x0) <= 6 {
				grabbed = .Seg_Start
			} else if abs_f32(mouse[0] - x1) <= 6 {
				grabbed = .Seg_End
			} else if mouse[0] > x0 && mouse[0] < x1 {
				grabbed = .Seg_Body
			}
		}
		if grabbed == .Playhead {
			// A press over another caption selects it rather than only seeking.
			if hit := seg_at(m.segs[:], t_at); hit >= 0 {
				m.sel = hit
			}
			seek_to(m, t_at)
		}
		m.drag = grabbed
		m.drag_seg = m.sel
	}

	if m.drag != .None {
		if !p.mouse_down(ui) {
			m.drag = .None
		} else {
			switch m.drag {
			case .Playhead:
				seek_to(m, t_at)
			case .Seg_Start:
				if m.drag_seg >= 0 && m.drag_seg < len(m.segs) {
					set_seg_times(
						&m.segs,
						m.drag_seg,
						t_at,
						m.segs[m.drag_seg].end,
						m.info.duration,
					)
					m.dirty = true
				}
			case .Seg_End:
				if m.drag_seg >= 0 && m.drag_seg < len(m.segs) {
					set_seg_times(
						&m.segs,
						m.drag_seg,
						m.segs[m.drag_seg].start,
						t_at,
						m.info.duration,
					)
					m.dirty = true
				}
			case .Seg_Body:
				if m.drag_seg >= 0 && m.drag_seg < len(m.segs) {
					s := m.segs[m.drag_seg]
					centre := (s.start + s.end) / 2
					shift_seg(&m.segs, m.drag_seg, t_at - centre, m.info.duration)
					m.dirty = true
				}
			case .None:
			}
			p.redraw(ui)
		}
	}
}

abs_f32 :: proc(v: f32) -> f32 {
	return v < 0 ? -v : v
}

wave_draw :: proc(c: ^p.Canvas, r: p.Rect, u: ^Wave_Ctx) {
	p.fill_rect(c, r, p.hex(0x111113))
	if u.duration <= 0 {
		return
	}
	span := u.span > 0 ? u.span : u.duration
	t_to_x := proc(r: p.Rect, from, span, t: f64) -> f32 {
		return r.x + f32((t - from) / span) * r.w
	}

	band_h := max(f32(14), r.h * 0.17)
	wave_rect := p.Rect{r.x, r.y, r.w, r.h - band_h}
	mid := wave_rect.y + wave_rect.h / 2

	// A time ruler: a tick every "nice" interval, with the label only where
	// there is room for it.
	stepping := nice_step(span, f64(r.w))
	t := math.floor(u.from / stepping) * stepping
	for ; t <= u.from + span; t += stepping {
		if t < u.from {
			continue
		}
		x := math.floor(t_to_x(r, u.from, span, t))
		p.fill_rect(c, {x, r.y, max(1, c.scale * 0.5), wave_rect.h}, p.hexa(0xffffff10))
		label := clock(t, context.temp_allocator)
		p.draw_text(
			c,
			u.fonts,
			label,
			x + 3,
			r.y + 11 * c.scale,
			10 * c.scale,
			p.hexa(0xffffff60),
			.Mono,
		)
	}

	// The centre line, so silence still reads as a signal at zero.
	p.fill_rect(c, {wave_rect.x, math.floor(mid), wave_rect.w, max(1, c.scale * 0.5)}, p.hexa(0xffffff1a))

	if u.peaks != nil && u.peaks.ready && u.peaks.n > 0 {
		half := wave_rect.h / 2 - 2
		cols := int(wave_rect.w)
		for i in 0 ..< cols {
			// Each screen column averages the peak buckets it covers, so
			// zooming out never aliases a transient away.
			a := u.from + f64(i) / f64(max(cols, 1)) * span
			b := u.from + f64(i + 1) / f64(max(cols, 1)) * span
			i0 := int(a / u.duration * f64(u.peaks.n))
			i1 := int(b / u.duration * f64(u.peaks.n))
			i0 = clamp(i0, 0, u.peaks.n - 1)
			i1 = clamp(max(i1, i0 + 1), 1, u.peaks.n)

			lo, hi := f32(0), f32(0)
			for k in i0 ..< i1 {
				lo = min(lo, u.peaks.lo[k])
				hi = max(hi, u.peaks.hi[k])
			}
			top := mid - hi * half
			bot := mid - lo * half
			h := max(bot - top, max(1, c.scale * 0.6))
			played := a <= u.pos
			col := played ? p.hex(0x6ea8fe) : p.hex(0x3f4a63)
			p.fill_rect(c, {wave_rect.x + f32(i), top, 1, h}, col)
		}
	}

	// Caption bands along the bottom edge: the shape of the subtitle file.
	for s, i in u.segs {
		if s.end < u.from || s.start > u.from + span {
			continue
		}
		x0 := max(t_to_x(r, u.from, span, s.start), r.x)
		x1 := min(t_to_x(r, u.from, span, s.end), r.x + r.w)
		w := max(x1 - x0, max(1, c.scale))
		selected := i == u.sel
		bad := i < len(u.warn) && u.warn[i]
		col := selected ? p.hex(0x3b82f6) : (bad ? p.hex(0x7f3d4a) : p.hex(0x33405c))
		p.fill_round_rect(
			c,
			{x0, r.y + r.h - band_h + 2, w, band_h - 4},
			{2, 2, 2, 2},
			col,
		)
		if selected {
			// Drag handles, drawn so it is visible that the edges are grabbable.
			hw := max(2, c.scale * 2)
			p.fill_rect(c, {x0, r.y + r.h - band_h + 2, hw, band_h - 4}, p.hex(0xdbeafe))
			p.fill_rect(c, {x1 - hw, r.y + r.h - band_h + 2, hw, band_h - 4}, p.hex(0xdbeafe))
			p.fill_rect(c, {x0, wave_rect.y, max(1, c.scale), wave_rect.h}, p.hexa(0x3b82f655))
			p.fill_rect(c, {x1, wave_rect.y, max(1, c.scale), wave_rect.h}, p.hexa(0x3b82f655))
		}
	}

	// The playhead last, over everything.
	if u.pos >= u.from && u.pos <= u.from + span {
		x := t_to_x(r, u.from, span, u.pos)
		p.fill_rect(c, {x - max(1, c.scale * 0.5), r.y, max(2, c.scale), r.h}, p.hex(0xf97316))
		p.fill_circle(c, x, r.y + 4 * c.scale, 3 * c.scale, p.hex(0xf97316))
	}
}

// nice_step picks a ruler interval from the 1/2/5/10/15/30 family so the
// labels land on times a human reads.
nice_step :: proc(span: f64, width: f64) -> f64 {
	target := span / max(width / 90, 1) // one label per ~90px
	for s in ([?]f64 {
			0.1,
			0.25,
			0.5,
			1,
			2,
			5,
			10,
			15,
			30,
			60,
			120,
			300,
			600,
			900,
			1800,
			3600,
		}) {
		if s >= target {
			return s
		}
	}
	return 3600
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

transport :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.row(ui, "w-full h-11 shrink-0 items-center gap-2 px-3 border-b border-border bg-card")
	defer p.end(ui)

	if icon_button(ui, IC_SKIP_BACK, !m.loaded) {
		select_seg(m, m.sel <= 0 ? 0 : m.sel - 1, true)
	}
	if icon_button(ui, m.playing ? IC_PAUSE : IC_PLAY, !m.loaded) {
		toggle_play(m)
	}
	if icon_button(ui, IC_SKIP_FORWARD, !m.loaded) {
		select_seg(m, m.sel + 1, true)
	}

	p.text(ui, clock(m.pos), "font-mono text-[12] font-medium w-[62] text-center")
	p.text(ui, "/", "text-[11] text-muted-foreground")
	p.text(ui, clock(m.info.duration), "font-mono text-[12] text-muted-foreground w-[62]")

	p.div(ui, "w-px h-5 bg-border mx-1")
	p.end(ui)

	// A scrubber over the whole file, independent of the zoomed waveform.
	bar := p.div(ui, "flex-1 h-6 relative cursor-pointer")
	if p.clickable(ui) && m.loaded {
		r := p.rect_of(ui, p.node_id(ui, bar))
		if r.w > 0 {
			mx := p.mouse_pos(ui)[0]
			seek_to(m, f64((mx - r.x) / r.w) * m.info.duration)
		}
	}
	{
		p.div(ui, "absolute left-0 right-0 top-[11] h-1 rounded-full bg-muted")
		p.end(ui)
		if m.loaded && m.info.duration > 0 {
			p.div(ui, "absolute left-0 top-[11] h-1 rounded-full bg-primary")
			p.style(ui).w = p.pct(f32(clamp(m.pos / m.info.duration, 0, 1)) * 100)
			p.end(ui)
			// Every caption as a tick, so the file's shape is readable here too.
			for s in m.segs {
				x := f32(clamp(s.start / m.info.duration, 0, 1))
				p.div(ui, "absolute top-[9] w-[2] h-[5] rounded-full bg-foreground/40")
				p.style(ui).inset[p.LEFT] = p.pct(x * 100)
				p.end(ui)
			}
		}
	}
	p.end(ui)

	if toggle_chip(ui, "follow", m.follow) {
		m.follow = !m.follow
	}
	p.textf(ui, "text-[11] text-muted-foreground w-[52] text-center", "%.0f%%", 100 * f64(m.view_span > 0 ? m.info.duration / m.view_span : 1))
	if icon_button(ui, IC_MINUS, !m.loaded) {
		zoom_view(m, 1 / 0.6)
	}
	if icon_button(ui, IC_PLUS, !m.loaded) {
		zoom_view(m, 0.6)
	}
}

// icon_button is a square control. There is no tooltip: palmy has no popup
// surface, so the label lives in the keyboard map instead of hovering.
icon_button :: proc(ui: ^p.Ctx, ic: p.Icon, disabled: bool) -> bool {
	p.div(ui, "size-8 shrink-0 rounded-md flex-row items-center justify-center border border-border bg-background")
	if disabled {
		p.apply(ui, "opacity-40")
	} else {
		p.apply(ui, "hover:bg-accent cursor-pointer")
	}
	hit := !disabled && p.clickable(ui)
	p.icon(ui, ic, "size-4")
	p.end(ui)
	return hit
}

toggle_chip :: proc(ui: ^p.Ctx, label: string, on: bool) -> bool {
	p.row(ui, "h-7 px-2 shrink-0 items-center gap-1.5 rounded-md border cursor-pointer")
	p.apply(ui, on ? "border-primary bg-primary/15 text-foreground" : "border-border text-muted-foreground hover:bg-accent")
	hit := p.clickable(ui)
	p.icon(ui, on ? IC_CHECK : IC_X, "size-3")
	p.text(ui, label, "text-[11] font-medium")
	p.end(ui)
	return hit
}

// ---------------------------------------------------------------------------
// The caption list
// ---------------------------------------------------------------------------

caption_list :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State) {
	p.col(ui, "flex-1 min-h-0 w-full")
	defer p.end(ui)

	p.row(ui, "w-full h-8 shrink-0 items-center gap-2 px-3 bg-muted/40 border-b border-border")
	{
		p.text(ui, "#", "text-[10] font-semibold text-muted-foreground w-[26]")
		p.text(ui, "IN", "text-[10] font-semibold text-muted-foreground w-[78]")
		p.text(ui, "OUT", "text-[10] font-semibold text-muted-foreground w-[78]")
		p.text(ui, "DUR", "text-[10] font-semibold text-muted-foreground w-[52]")
		p.text(ui, "CPS", "text-[10] font-semibold text-muted-foreground w-[46]")
		p.text(ui, "CAPTION", "text-[10] font-semibold text-muted-foreground")
		p.spacer(ui)
		if len(m.segs) > 0 {
			p.textf(ui, "text-[10] text-muted-foreground", "limits %d chars / %d lines / %.0f cps", m.limits.max_cpl, m.limits.max_lines, m.limits.max_cps)
		}
	}
	p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll")
	list_id := p.node_id(ui, list)
	sel_id := u64(0)
	{
		if len(m.segs) == 0 {
			empty_state(ui, m)
		}
		active := seg_at(m.segs[:], m.pos)
		for _, i in m.segs {
			id := caption_row(ui, fonts, m, i, i == active)
			if i == m.sel {
				sel_id = id
			}
		}
	}
	p.end(ui)

	// Keep the selection on screen while the keyboard walks the list.
	if sel_id != 0 {
		p.scroll_into_view(ui, list_id, sel_id, 24)
	}
}

empty_state :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.col(ui, "w-full flex-1 items-center justify-center gap-3 p-8")
	defer p.end(ui)

	p.icon(ui, IC_SPARKLES, "size-7 text-muted-foreground")
	if !m.loaded {
		p.text(ui, "Nothing open yet", "text-sm font-medium")
		p.text(ui, "Press o to type a path, or pick a file from the list on the right.", "text-[12] text-muted-foreground text-center max-w-[420]")
	} else if job_kind() == .Transcribe {
		p.text(ui, "Transcribing", "text-sm font-medium")
		p.text(ui, job_note(), "text-[12] text-muted-foreground text-center max-w-[520]")
	} else {
		p.text(ui, "No captions yet", "text-sm font-medium")
		p.text(ui, "Press t to transcribe this file, or open an .srt to edit one you already have.", "text-[12] text-muted-foreground text-center max-w-[420]")
	}
}

caption_row :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State, i: int, active: bool) -> u64 {
	s := &m.segs[i]
	selected := i == m.sel
	warns := seg_warnings(m.segs[:], i, m.limits)

	p.key(ui, fmt.tprintf("seg-%d", i))
	row := p.row(ui, "w-full shrink-0 items-start gap-2 px-3 py-2 border-b border-border/60 cursor-pointer")
	defer p.end(ui)
	id := p.node_id(ui, row)

	if selected {
		p.apply(ui, "bg-primary/10")
	} else if active {
		p.apply(ui, "bg-amber-500/10")
	} else {
		p.apply(ui, "hover:bg-accent/40")
	}
	if p.clickable(ui) {
		if selected && m.focus != .Caption {
			m.focus = .Caption
		}
		m.sel = i
		seek_to(m, s.start)
	}

	// The marker column doubles as the playing indicator.
	p.col(ui, "w-[26] shrink-0 items-center gap-0.5")
	{
		p.textf(ui, selected ? "text-[11] font-semibold" : "text-[11] text-muted-foreground", "%d", i + 1)
		if active {
			p.icon(ui, IC_PLAY, "size-2.5 text-amber-500")
		}
	}
	p.end(ui)

	time_cell(ui, srt_timecode(s.start), selected)
	time_cell(ui, srt_timecode(s.end), selected)
	p.textf(ui, "font-mono text-[11] w-[52] shrink-0 text-muted-foreground", "%.2fs", seg_duration(s^))

	speed := cps(s^)
	speed_class := "font-mono text-[11] w-[46] shrink-0 text-muted-foreground"
	if speed > m.limits.max_cps {
		speed_class = "font-mono text-[11] w-[46] shrink-0 text-destructive font-semibold"
	}
	p.textf(ui, speed_class, "%.0f", speed)

	// The text: an editor when this row is being edited, a label otherwise.
	p.col(ui, "flex-1 min-w-0 gap-1")
	{
		if selected && m.focus == .Caption {
			caption_editor(ui, fonts, m, s)
		} else {
			body := seg_text(s^)
			if strings.trim_space(body) == "" {
				p.text(ui, "(empty)", "text-[13] text-muted-foreground")
			} else {
				for line in strings.split(body, "\n", context.temp_allocator) {
					over := visible_chars(line) > m.limits.max_cpl
					p.text(ui, line, over ? "text-[13] text-destructive" : "text-[13]")
				}
			}
		}

		if warns != {} {
			p.row(ui, "w-full items-center gap-1.5 gap-y-1 flex-wrap")
			for k in Warn_Kind {
				if k in warns {
					// `shrink-0` and `whitespace-nowrap`: a chip is a fixed
					// 16px tall, so a label that wraps inside one overflows
					// it. The row wraps instead, which is what `flex-wrap`
					// on the parent is for.
					p.row(ui, "shrink-0 items-center gap-1 h-4 px-1.5 rounded bg-destructive/10")
					p.icon(ui, IC_TRIANGLE_ALERT, "size-2.5 shrink-0 text-destructive")
					p.text(ui, warn_text(k, m.limits), "text-[10] text-destructive whitespace-nowrap")
					p.end(ui)
				}
			}
			p.end(ui)
		}
	}
	p.end(ui)

	// Per-row confidence, which is where to look first for a mis-hearing.
	p.col(ui, "w-[54] shrink-0 items-end gap-1")
	{
		if s.conf > 0 {
			p.textf(
				ui,
				s.conf < 0.6 ? "text-[10] text-amber-500" : "text-[10] text-muted-foreground",
				"%.0f%%",
				s.conf * 100,
			)
		}
		if selected {
			p.row(ui, "items-center gap-1")
			if mini_button(ui, IC_SCISSORS) {
				queue_act(m, .Split, i)
			}
			if mini_button(ui, IC_COMBINE) {
				queue_act(m, .Merge, i)
			}
			if mini_button(ui, IC_TRASH) {
				queue_act(m, .Delete, i)
			}
			p.end(ui)
		}
	}
	p.end(ui)

	return id
}

time_cell :: proc(ui: ^p.Ctx, text: string, selected: bool) {
	class := "font-mono text-[11] w-[78] shrink-0 text-muted-foreground"
	if selected {
		class = "font-mono text-[11] w-[78] shrink-0 text-foreground"
	}
	p.text(ui, text, class)
}

mini_button :: proc(ui: ^p.Ctx, ic: p.Icon) -> bool {
	p.div(ui, "size-5 rounded flex-row items-center justify-center hover:bg-accent cursor-pointer")
	hit := p.clickable(ui)
	p.icon(ui, ic, "size-3 text-muted-foreground")
	p.end(ui)
	return hit
}

// caption_editor draws the caption being edited, with a caret this application
// places itself. The two measurements palmy exposes are exactly the two this
// needs: `text_index_at` maps a click to a byte index, `text_width_upto` maps
// a byte index back to an x position.
EDIT_SIZE :: f32(13)
EDIT_LH :: f32(19)

caption_editor :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State, s: ^Seg) {
	body := seg_text(s^)
	lines := strings.split(body, "\n", context.temp_allocator)

	// Which line the caret is on, and how far into it.
	caret := clamp(m.caret, 0, len(body))
	caret_line := 0
	caret_col := caret
	{
		at := 0
		for l, i in lines {
			if caret <= at + len(l) {
				caret_line = i
				caret_col = caret - at
				break
			}
			at += len(l) + 1
			caret_line = i + 1
			caret_col = 0
		}
	}

	host := p.col(ui, "w-full relative gap-0 py-0.5 px-1.5 rounded-md bg-background border border-ring")
	defer p.end(ui)

	line_rects := make([]int, len(lines), context.temp_allocator)
	for l, i in lines {
		over := visible_chars(l) > m.limits.max_cpl
		idx := p.text(ui, l == "" ? " " : l, over ? "text-[13] text-destructive" : "text-[13]")
		p.style(ui).leading_px = EDIT_LH
		line_rects[i] = idx
	}

	// Click to place the caret.
	if p.clickable(ui, host) {
		mouse := p.mouse_pos(ui)
		best := 0
		at := 0
		for l, i in lines {
			r := p.rect_of(ui, p.node_id(ui, line_rects[i]))
			if r.h > 0 && mouse[1] >= r.y && mouse[1] < r.y + r.h {
				best = at + p.text_index_at(fonts, l, EDIT_SIZE, mouse[0] - r.x)
				m.caret = best
				break
			}
			at += len(l) + 1
		}
	}

	// The caret: a one-pixel bar at the measured offset, blinking off the
	// frame clock so it reads as a live cursor.
	if caret_line < len(lines) {
		line := lines[min(caret_line, len(lines) - 1)]
		col := clamp(caret_col, 0, len(line))
		x := p.text_width_upto(fonts, line, col, EDIT_SIZE)
		blink := int(p.elapsed(ui) * 1.6) % 2 == 0
		if blink {
			p.div(ui, "absolute w-[2] bg-primary rounded-full")
			st := p.style(ui)
			st.position = .Absolute
			st.inset[p.LEFT] = p.px(6 + x)
			st.inset[p.TOP] = p.px(2 + EDIT_LH * f32(caret_line) + 2)
			st.h = p.px(EDIT_LH - 4)
			p.end(ui)
		}
		p.redraw(ui) // keep the blink moving
	}

	p.row(ui, "w-full items-center gap-2 pt-1")
	{
		p.text(ui, "Esc to stop editing · Enter for a line break · Ctrl-K to split here", "text-[10] text-muted-foreground")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The side panel
// ---------------------------------------------------------------------------

side_panel :: proc(ui: ^p.Ctx, fonts: ^p.Fonts, m: ^App_State) {
	p.row(ui, "w-full h-10 shrink-0 items-center gap-1 px-2 border-b border-border bg-card")
	{
		for pn in Pane {
			p.row(ui, "h-7 px-2.5 items-center gap-1.5 rounded-md cursor-pointer")
			p.apply(ui, pn == m.pane ? "bg-primary text-primary-foreground" : "hover:bg-accent text-muted-foreground")
			if p.clickable(ui) {
				m.pane = pn
			}
			p.textf(ui, "text-[10] opacity-70", "%d", int(pn) + 1)
			p.text(ui, pane_name(pn), "text-[12] font-medium")
			p.end(ui)
		}
	}
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-3 gap-3")
	defer p.end(ui)

	switch m.pane {
	case .Transcribe:
		pane_transcribe(ui, m)
	case .Captions:
		pane_captions(ui, m)
	case .Style:
		pane_style(ui, m)
	case .Export:
		pane_export(ui, m)
	}
}

section :: proc(ui: ^p.Ctx, title: string) {
	p.text(ui, title, LABEL)
}

pane_transcribe :: proc(ui: ^p.Ctx, m: ^App_State) {
	section(ui, "OPEN")
	line_field(ui, m, .Path, &m.path_buf, m.path_caret, "path to a video, audio or .srt file")

	p.row(ui, "w-full gap-2")
	{
		if text_button(ui, "Open", IC_FOLDER_OPEN, .Default, false, true) {
			queue_act(m, .Open, 0, string(m.path_buf[:]))
		}
		if text_button(ui, m.focus == .Path ? "Typing…" : "Type a path (o)", IC_TYPE, .Outline, false, true) {
			m.focus = .Path
			m.path_caret = len(m.path_buf)
		}
	}
	p.end(ui)

	if len(m.dir_files) > 0 {
		p.row(ui, "w-full items-center gap-2")
		section(ui, "IN THIS FOLDER")
		p.spacer(ui)
		p.text(ui, "p next · r open", "text-[10] text-muted-foreground")
		p.end(ui)
		p.col(ui, "w-full max-h-[168] overflow-scroll rounded-md border border-border")
		for name, i in m.dir_files {
			p.key(ui, name)
			p.row(ui, "w-full shrink-0 items-center gap-2 px-2 py-1.5 cursor-pointer")
			p.apply(ui, i == m.file_sel ? "bg-primary/15" : "hover:bg-accent/50")
			if p.clickable(ui) {
				m.file_sel = i
				queue_act(m, .Open, 0, fmt.tprintf("%s/%s", m.dir, name))
			}
			p.icon(
				ui,
				is_subtitle_path(name) ? IC_FILE_PLAY : IC_FILM,
				"size-3 shrink-0 text-muted-foreground",
			)
			p.text(ui, name, "text-[11] truncate")
			p.end(ui)
		}
		p.end(ui)
	}

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)

	section(ui, "MODEL")
	if len(m.models) == 0 {
		p.col(ui, "w-full gap-1.5 p-2.5 rounded-md border border-destructive/40 bg-destructive/10")
		p.row(ui, "items-center gap-2")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-3.5 text-destructive")
		p.text(ui, "No whisper model found", "text-[12] font-semibold text-destructive")
		p.end(ui)
		p.text(ui, "Put a ggml-*.bin in one of these directories, or install one with whisper.cpp's download script:", "text-[11] text-muted-foreground")
		for d in MODEL_DIRS {
			p.text(ui, expand_path(d), "font-mono text-[10] text-muted-foreground")
		}
		p.end(ui)
	} else {
		for mm, i in m.models {
			p.key(ui, mm.name)
			p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md border cursor-pointer")
			p.apply(ui, i == m.model_i ? "border-primary bg-primary/10" : "border-border hover:bg-accent/50")
			if p.clickable(ui) {
				m.model_i = i
			}
			p.icon(ui, i == m.model_i ? IC_CHECK : IC_BOX, "size-3 shrink-0 text-muted-foreground")
			p.col(ui, "flex-1 min-w-0 gap-0")
			p.text(ui, mm.name, "text-[12] font-medium truncate")
			p.textf(
				ui,
				"text-[10] text-muted-foreground",
				"%s · %s",
				human_size(mm.bytes),
				mm.multilingual ? "multilingual" : "English only",
			)
			p.end(ui)
			p.end(ui)
		}
		p.text(ui, "j cycles the model", "text-[10] text-muted-foreground")
	}

	cur := len(m.models) > 0 ? m.models[clamp(m.model_i, 0, len(m.models) - 1)] : Model{}

	section(ui, "LANGUAGE")
	if cur.multilingual {
		p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md border border-border hover:bg-accent/50 cursor-pointer")
		if p.clickable(ui) {
			m.lang_i = (m.lang_i + 1) % len(LANGUAGES)
		}
		p.icon(ui, IC_LANGUAGES, "size-3.5 text-muted-foreground")
		p.text(ui, LANGUAGES[clamp(m.lang_i, 0, len(LANGUAGES) - 1)].name, "text-[12]")
		p.spacer(ui)
		p.text(ui, "l", "text-[10] text-muted-foreground")
		p.end(ui)
		if m.translate || true {
			if toggle_row(ui, "Translate to English", m.translate) {
				m.translate = !m.translate
			}
		}
	} else {
		p.text(ui, fmt.tprintf("%s is an English-only model.", cur.name), "text-[11] text-muted-foreground")
	}

	section(ui, "SEGMENTS")
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Max characters", STEP_LABEL)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.max_len = max(0, m.max_len - 2)
		}
		p.textf(ui, "font-mono text-[11] w-[30] text-center", "%d", m.max_len)
		if mini_button(ui, IC_PLUS) {
			m.max_len = min(120, m.max_len + 2)
		}
	}
	p.end(ui)
	if toggle_row(ui, "Split on word boundaries", m.split_word) {
		m.split_word = !m.split_word
	}
	if m.has_vad {
		if toggle_row(ui, "Voice activity detection", m.use_vad) {
			m.use_vad = !m.use_vad
		}
	}
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Threads", STEP_LABEL)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.threads = max(1, m.threads - 1)
		}
		p.textf(ui, "font-mono text-[11] w-[30] text-center", "%d", m.threads)
		if mini_button(ui, IC_PLUS) {
			m.threads = min(32, m.threads + 1)
		}
	}
	p.end(ui)

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)

	busy := job_kind() == .Transcribe
	if busy {
		job_progress_card(ui, m, "Transcribing")
	} else if text_button(
		ui,
		"Transcribe (t)",
		IC_SPARKLES,
		.Default,
		!m.loaded || len(m.models) == 0 || job_busy(),
	) {
		begin_transcribe(m)
	}

	if m.transcribed && m.rtf > 0 {
		p.col(ui, "w-full gap-1 p-2.5 rounded-md border border-border bg-muted/30")
		p.row(ui, "items-center gap-2")
		p.icon(ui, IC_GAUGE, "size-3.5 text-muted-foreground")
		p.textf(ui, "text-[12] font-semibold", "%.1fx realtime", m.rtf)
		p.end(ui)
		p.textf(
			ui,
			"text-[11] text-muted-foreground",
			"%s of audio decoded in %.1fs on %d threads",
			clock(m.info.duration),
			m.decode_sec,
			m.threads,
		)
		if m.heard_lang != "" {
			p.textf(ui, "text-[11] text-muted-foreground", "language reported: %s", m.heard_lang)
		}
		p.text(ui, "Everything ran on this machine. No audio left it.", "text-[10] text-muted-foreground")
		p.end(ui)
	}
}

toggle_row :: proc(ui: ^p.Ctx, label: string, on: bool) -> bool {
	p.row(ui, "w-full items-center gap-2 cursor-pointer py-0.5")
	defer p.end(ui)
	hit := p.clickable(ui)
	p.div(ui, "size-3.5 shrink-0 rounded border flex-row items-center justify-center")
	p.apply(ui, on ? "border-primary bg-primary" : "border-border")
	if on {
		p.icon(ui, IC_CHECK, "size-2.5 text-primary-foreground")
	}
	p.end(ui)
	p.text(ui, label, "text-[11]")
	return hit
}

// text_button draws a button that fills its slot. `in_row` is not cosmetic:
// `flex-1` along a row is what lets two buttons share the width, but the same
// class in a column makes one button grow to the full height of the panel.
text_button :: proc(
	ui: ^p.Ctx,
	label: string,
	ic: p.Icon,
	v: sc.Variant,
	disabled: bool,
	in_row := false,
) -> bool {
	st := sc.State{disabled = disabled}
	idx := sc.button_open(ui, v, .Default, st)
	p.apply(ui, in_row ? "flex-1 justify-center" : "w-full grow-0 shrink-0 justify-center")
	if !disabled {
		p.apply(ui, "cursor-pointer")
	}
	hit := !disabled && p.clickable(ui, idx)
	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "whitespace-nowrap text-[12] font-medium")
	p.style(ui).shrink = 0
	sc.button_end(ui)
	return hit
}

job_progress_card :: proc(ui: ^p.Ctx, m: ^App_State, title: string) {
	p.col(ui, "w-full gap-2 p-2.5 rounded-md border border-primary/40 bg-primary/5")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	sc.spinner(ui, "size-3.5")
	p.text(ui, title, "text-[12] font-semibold")
	p.spacer(ui)
	p.textf(ui, "font-mono text-[11]", "%.0f%%", f64(job_progress()) * 100)
	p.end(ui)

	sc.progress_track(ui, job_progress() * 100)

	p.text(ui, stage_text(job_stage()), "text-[10] text-muted-foreground")
	if note := job_note(); note != "" {
		p.text(ui, note, "text-[11] truncate")
	}
	if text_button(ui, "Cancel (Esc)", IC_X, .Outline, false) {
		job_cancel()
	}
}

pane_captions :: proc(ui: ^p.Ctx, m: ^App_State) {
	section(ui, "SELECTION")
	if m.sel < 0 || m.sel >= len(m.segs) {
		p.text(ui, "Nothing selected. Up and Down walk the list.", "text-[11] text-muted-foreground")
	} else {
		s := &m.segs[m.sel]
		p.col(ui, "w-full gap-1 p-2.5 rounded-md border border-border bg-muted/30")
		p.textf(ui, "text-[12] font-semibold", "Caption %d of %d", m.sel + 1, len(m.segs))
		p.textf(ui, "font-mono text-[11] text-muted-foreground", "%s → %s", srt_timecode(s.start), srt_timecode(s.end))
		p.textf(ui, "text-[11] text-muted-foreground", "%.2fs · %d characters · %.1f cps", seg_duration(s^), visible_chars(seg_text(s^)), cps(s^))
		p.end(ui)

		p.row(ui, "w-full gap-2")
		if text_button(ui, m.focus == .Caption ? "Editing" : "Edit text (Enter)", IC_TYPE, m.focus == .Caption ? .Default : .Outline, false, true) {
			m.focus = .Caption
			m.caret = len(m.segs[m.sel].text)
		}
		p.end(ui)

		p.row(ui, "w-full gap-2")
		if text_button(ui, "Split (s)", IC_SCISSORS, .Outline, false, true) {
			queue_act(m, .Split, m.sel)
		}
		if text_button(ui, "Merge (m)", IC_COMBINE, .Outline, m.sel + 1 >= len(m.segs), true) {
			queue_act(m, .Merge, m.sel)
		}
		p.end(ui)
		p.row(ui, "w-full gap-2")
		if text_button(ui, "Re-wrap (w)", IC_ROWS_3, .Outline, false, true) {
			queue_act(m, .Wrap, m.sel)
		}
		if text_button(ui, "Delete (d)", IC_TRASH, .Outline, false, true) {
			queue_act(m, .Delete, m.sel)
		}
		p.end(ui)

		section(ui, "TIMING")
		nudge_row(ui, m, "In point", true)
		nudge_row(ui, m, "Out point", false)
		p.row(ui, "w-full gap-2")
		if text_button(ui, "In = playhead (i)", IC_CHEVRON_UP, .Outline, false, true) {
			set_seg_times(&m.segs, m.sel, m.pos, m.segs[m.sel].end, m.info.duration)
			m.dirty = true
		}
		if text_button(ui, "Out = playhead (u)", IC_CHEVRON_DOWN, .Outline, false, true) {
			set_seg_times(&m.segs, m.sel, m.segs[m.sel].start, m.pos, m.info.duration)
			m.dirty = true
		}
		p.end(ui)
		p.text(ui, "Drag the band under the waveform, or its edges, to retime.", "text-[10] text-muted-foreground")
	}

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)

	section(ui, "QUALITY LIMITS")
	limit_row(ui, "Characters per line", &m.limits.max_cpl, 10, 100, 1)
	limit_row(ui, "Lines per caption", &m.limits.max_lines, 1, 4, 1)
	limit_f_row(ui, "Characters per second", &m.limits.max_cps, 5, 40, 1)
	limit_f_row(ui, "Minimum duration", &m.limits.min_dur, 0.2, 3, 0.1)
	limit_f_row(ui, "Maximum duration", &m.limits.max_dur, 2, 20, 0.5)

	p.text(ui, "These are the broadcast conventions: 42 characters a line, two lines, 17 characters a second.", "text-[10] text-muted-foreground")

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)
	if text_button(ui, "Re-wrap every caption (W)", IC_ROWS_3, .Outline, len(m.segs) == 0) {
		queue_act(m, .Wrap_All)
	}
	if text_button(ui, "New caption after this (n)", IC_PLUS, .Outline, !m.loaded) {
		queue_act(m, .Insert, m.sel)
	}
}

nudge_row :: proc(ui: ^p.Ctx, m: ^App_State, label: string, is_start: bool) {
	p.row(ui, "w-full items-center gap-1.5")
	defer p.end(ui)

	p.text(ui, label, "text-[11] text-muted-foreground w-[58] shrink-0 whitespace-nowrap")
	p.text(ui, is_start ? "[ ]" : ", .", "font-mono text-[10] text-muted-foreground w-[22] shrink-0")
	if mini_button(ui, IC_CHEVRON_DOWN) {
		if is_start {
			nudge_start(&m.segs, m.sel, -0.1, m.limits)
		} else {
			nudge_end(&m.segs, m.sel, -0.1, m.limits, m.info.duration)
		}
		m.dirty = true
	}
	s := m.segs[m.sel]
	p.text(ui, srt_timecode(is_start ? s.start : s.end), "font-mono text-[11] flex-1 text-center")
	if mini_button(ui, IC_CHEVRON_UP) {
		if is_start {
			nudge_start(&m.segs, m.sel, 0.1, m.limits)
		} else {
			nudge_end(&m.segs, m.sel, 0.1, m.limits, m.info.duration)
		}
		m.dirty = true
	}
}

limit_row :: proc(ui: ^p.Ctx, label: string, v: ^int, lo, hi, step: int) {
	p.row(ui, "w-full items-center gap-2")
	defer p.end(ui)
	p.text(ui, label, STEP_LABEL)
	p.spacer(ui)
	if mini_button(ui, IC_MINUS) {
		v^ = max(lo, v^ - step)
	}
	p.textf(ui, "font-mono text-[11] w-[30] text-center", "%d", v^)
	if mini_button(ui, IC_PLUS) {
		v^ = min(hi, v^ + step)
	}
}

limit_f_row :: proc(ui: ^p.Ctx, label: string, v: ^f64, lo, hi, step: f64) {
	p.row(ui, "w-full items-center gap-2")
	defer p.end(ui)
	p.text(ui, label, STEP_LABEL)
	p.spacer(ui)
	if mini_button(ui, IC_MINUS) {
		v^ = max(lo, v^ - step)
	}
	p.textf(ui, "font-mono text-[11] w-[36] text-center", "%.2f", v^)
	if mini_button(ui, IC_PLUS) {
		v^ = min(hi, v^ + step)
	}
}

pane_style :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.text(ui, "Everything here is written into the ASS style line, which is what the burn-in uses — so the preview above and the rendered file agree.", "text-[11] text-muted-foreground")

	section(ui, "TYPE")
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Size", STEP_LABEL)
		p.text(ui, "j l", STEP_HINT)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.style.size = max(8, m.style.size - 2)
		}
		p.textf(ui, "font-mono text-[11] w-[44] text-center", "%.0f px", m.style.size)
		if mini_button(ui, IC_PLUS) {
			m.style.size = min(200, m.style.size + 2)
		}
	}
	p.end(ui)
	if toggle_row(ui, "Bold (y)", m.style.bold) {
		m.style.bold = !m.style.bold
	}

	section(ui, "FILL  (c)")
	swatches(ui, &m.style.fill)

	section(ui, "OUTLINE")
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Width", STEP_LABEL)
		p.text(ui, "h r", STEP_HINT)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.style.outline = max(0, m.style.outline - 0.5)
		}
		p.textf(ui, "font-mono text-[11] w-[44] text-center", "%.1f px", m.style.outline)
		if mini_button(ui, IC_PLUS) {
			m.style.outline = min(10, m.style.outline + 0.5)
		}
	}
	p.end(ui)
	swatches(ui, &m.style.outline_rgb)
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Shadow", STEP_LABEL)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.style.shadow = max(0, m.style.shadow - 0.5)
		}
		p.textf(ui, "font-mono text-[11] w-[44] text-center", "%.1f px", m.style.shadow)
		if mini_button(ui, IC_PLUS) {
			m.style.shadow = min(10, m.style.shadow + 0.5)
		}
	}
	p.end(ui)

	section(ui, "BACKGROUND BOX  (x)")
	if toggle_row(ui, "Opaque box behind the text", m.style.box) {
		m.style.box = !m.style.box
	}
	if m.style.box {
		swatches(ui, &m.style.box_rgb)
		p.row(ui, "w-full items-center gap-2")
		{
			p.text(ui, "Opacity", STEP_LABEL)
			p.spacer(ui)
			if mini_button(ui, IC_MINUS) {
				m.style.box_opacity = max(0, m.style.box_opacity - 0.05)
			}
			p.textf(ui, "font-mono text-[11] w-[44] text-center", "%.0f%%", m.style.box_opacity * 100)
			if mini_button(ui, IC_PLUS) {
				m.style.box_opacity = min(1, m.style.box_opacity + 0.05)
			}
		}
		p.end(ui)
		p.text(ui, "ASS carries a box as BorderStyle 3, which replaces the outline rather than sitting behind it.", "text-[10] text-muted-foreground")
	}

	section(ui, "POSITION  (p)")
	p.col(ui, "w-full gap-1")
	for pos in Position {
		p.key(ui, position_name(pos))
		p.row(ui, "w-full items-center gap-2 px-2 py-1 rounded-md cursor-pointer")
		p.apply(ui, pos == m.style.pos ? "bg-primary/15 border border-primary" : "hover:bg-accent/50 border border-transparent")
		if p.clickable(ui) {
			m.style.pos = pos
		}
		p.icon(ui, pos == m.style.pos ? IC_CHECK : IC_TEXT_ALIGN_CENTER, "size-3 text-muted-foreground")
		p.text(ui, position_name(pos), "text-[11]")
		p.spacer(ui)
		p.textf(ui, "font-mono text-[10] text-muted-foreground", "align %d", ass_alignment(pos))
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Side margin", STEP_LABEL)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.style.margin_x = max(0, m.style.margin_x - 4)
		}
		p.textf(ui, "font-mono text-[11] w-[36] text-center", "%d", m.style.margin_x)
		if mini_button(ui, IC_PLUS) {
			m.style.margin_x = min(600, m.style.margin_x + 4)
		}
	}
	p.end(ui)
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Edge margin", STEP_LABEL)
		p.spacer(ui)
		if mini_button(ui, IC_MINUS) {
			m.style.margin_y = max(0, m.style.margin_y - 4)
		}
		p.textf(ui, "font-mono text-[11] w-[36] text-center", "%d", m.style.margin_y)
		if mini_button(ui, IC_PLUS) {
			m.style.margin_y = min(600, m.style.margin_y + 4)
		}
	}
	p.end(ui)

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)
	section(ui, "THE STYLE LINE")
	p.text(ui, ass_style_preview(m), "font-mono text-[9] leading-[13] text-muted-foreground")
}

ass_style_preview :: proc(m: ^App_State) -> string {
	full := write_ass(nil, m.style, m.info.width, m.info.height, context.temp_allocator)
	for line in strings.split_lines(full, context.temp_allocator) {
		if strings.has_prefix(line, "Style: ") {
			return line
		}
	}
	return ""
}

swatches :: proc(ui: ^p.Ctx, target: ^u32) {
	p.row(ui, "w-full gap-1.5 flex-wrap")
	defer p.end(ui)
	for c in FILL_SWATCHES {
		p.key(ui, fmt.tprintf("sw-%06x", c))
		p.div(ui, "size-6 rounded-md border cursor-pointer")
		p.apply(ui, c == target^ ? "border-primary border-2" : "border-border")
		p.style(ui).bg = p.flat(p.hex(c))
		if p.clickable(ui) {
			target^ = c
		}
		p.end(ui)
	}
}

pane_export :: proc(ui: ^p.Ctx, m: ^App_State) {
	section(ui, "FORMAT  (f)")
	for f in Format {
		p.key(ui, format_ext(f))
		p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md border cursor-pointer")
		p.apply(ui, f == m.fmt_i ? "border-primary bg-primary/10" : "border-border hover:bg-accent/50")
		if p.clickable(ui) {
			m.fmt_i = f
		}
		p.icon(ui, f == m.fmt_i ? IC_CHECK : IC_FILE_PLAY, "size-3 shrink-0 text-muted-foreground")
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, format_name(f), "text-[12] font-medium")
		p.text(ui, format_blurb(f), "text-[10] text-muted-foreground")
		p.end(ui)
		p.end(ui)
	}

	section(ui, "WRITE TO")
	line_field(ui, m, .Output, &m.out_buf, m.out_caret, default_hint(m))
	p.text(ui, "Left blank, the export goes next to the media file. It never overwrites the source.", "text-[10] text-muted-foreground")

	if text_button(ui, fmt.tprintf("Export %s  (e)", strings.to_upper(format_ext(m.fmt_i), context.temp_allocator)), IC_DOWNLOAD, .Default, len(m.segs) == 0) {
		export_now(m)
	}

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)

	section(ui, "BURN INTO THE VIDEO")
	p.text(ui, "Renders the captions into a new file with ffmpeg's ass filter, using the style above. The audio is copied, not re-encoded.", "text-[11] text-muted-foreground")
	if job_kind() == .Burn {
		job_progress_card(ui, m, "Encoding")
	} else if text_button(
		ui,
		"Burn in (b)",
		IC_FLAME,
		.Outline,
		!m.loaded || !m.info.has_video || len(m.segs) == 0 || job_busy(),
	) {
		begin_burn(m)
	}
	if m.loaded && m.info.has_video {
		p.textf(
			ui,
			"font-mono text-[10] text-muted-foreground",
			"→ %s",
			default_output(m.info.path, ".captioned", "mp4"),
		)
	}

	p.div(ui, "h-px w-full bg-border")
	p.end(ui)

	section(ui, "PREVIEW OF THE FILE")
	preview_text := render_subtitles(
		m.fmt_i,
		m.segs[:],
		m.style,
		m.info.width,
		m.info.height,
		context.temp_allocator,
	)
	if preview_text == "" {
		p.text(ui, "Nothing to show yet.", "text-[11] text-muted-foreground")
	} else {
		head := preview_text
		if len(head) > 1400 {
			head = head[:1400]
		}
		p.col(ui, "w-full max-h-[260] overflow-scroll rounded-md border border-border bg-muted/30 p-2")
		for line in strings.split_lines(head, context.temp_allocator) {
			p.text(ui, line == "" ? " " : line, "font-mono text-[10] leading-[14] whitespace-nowrap")
		}
		p.end(ui)
	}
}

format_blurb :: proc(f: Format) -> string {
	switch f {
	case .SRT:
		return "the universal one; what a video editor expects"
	case .VTT:
		return "the web one; entities escaped"
	case .ASS:
		return "carries the styling; what the burn-in uses"
	case .TXT:
		return "one line per caption, no timings"
	}
	return ""
}

default_hint :: proc(m: ^App_State) -> string {
	if !m.loaded {
		return "a path to write to"
	}
	return default_output(m.info.path, "", format_ext(m.fmt_i))
}

// line_field draws one of the two single-line fields, with the caret this
// application maintains rather than palmy's own focus.
line_field :: proc(
	ui: ^p.Ctx,
	m: ^App_State,
	which: Focus,
	buf: ^[dynamic]u8,
	caret: int,
	placeholder: string,
) {
	focused := m.focus == which
	p.row(ui, "w-full h-8 shrink-0 items-center px-2.5 rounded-md border bg-background cursor-text relative overflow-hidden")
	p.apply(ui, focused ? "border-ring ring-3 ring-ring/50" : "border-input hover:border-ring/50")
	if p.clickable(ui) {
		m.focus = which
		if which == .Path {
			m.path_caret = len(m.path_buf)
		} else {
			m.out_caret = len(m.out_buf)
		}
	}
	defer p.end(ui)

	text := string(buf[:])
	if text == "" && !focused {
		p.text(ui, placeholder, "text-[12] text-muted-foreground truncate")
		return
	}
	// The caret is a real element between two runs of text, so Home, End and
	// the arrow keys are visible rather than silently moving an offset.
	at := clamp(caret, 0, len(text))
	if at > 0 {
		p.text(ui, text[:at], "text-[12] whitespace-nowrap")
	}
	if focused {
		p.div(ui, "w-[2] h-4 bg-primary rounded-full shrink-0")
		p.end(ui)
		p.redraw(ui)
	}
	if at < len(text) {
		p.text(ui, text[at:], "text-[12] whitespace-nowrap")
	}
	if text == "" && focused {
		p.text(ui, placeholder, "text-[12] text-muted-foreground truncate")
	}
}

// ---------------------------------------------------------------------------
// Status bar and help
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.row(ui, "w-full h-8 shrink-0 items-center gap-2 px-3 border-t border-border bg-card")
	defer p.end(ui)

	if job_busy() {
		sc.spinner(ui, "size-3")
		p.textf(
			ui,
			"text-[11] whitespace-nowrap shrink-0",
			"%s · %.0f%%",
			stage_text(job_stage()),
			f64(job_progress()) * 100,
		)
		if note := job_note(); note != "" {
			p.text(ui, "·", "text-[11] text-muted-foreground shrink-0")
			p.text(ui, note, "text-[11] text-muted-foreground truncate whitespace-nowrap max-w-[520]")
		}
	} else {
		p.icon(
			ui,
			m.status_bad ? IC_TRIANGLE_ALERT : IC_CHECK,
			m.status_bad ? "size-3 text-destructive" : "size-3 text-muted-foreground",
		)
		status_class := "text-[11] text-muted-foreground truncate whitespace-nowrap"
		if m.status_bad {
			status_class = "text-[11] text-destructive truncate whitespace-nowrap"
		}
		p.text(ui, m.status, status_class)
	}

	p.spacer(ui)
	p.text(ui, keys_hint(m), "text-[10] text-muted-foreground whitespace-nowrap")
}

keys_hint :: proc(m: ^App_State) -> string {
	switch m.focus {
	case .Caption:
		return "typing · Esc done · Ctrl-K split"
	case .Path:
		return "typing a path · Enter opens · Esc cancels"
	case .Output:
		return "typing a path · Enter accepts"
	case .Browse:
	}
	if !m.loaded {
		return "o open · t transcribe · ? keys"
	}
	return "Space play · ↑↓ select · Enter edit · s split · m merge · e export · ? keys"
}

HELP := [?][2]string {
	{"Ctrl O", "choose the media in a file dialog"},
	{"o", "type a path to open"},
	{"p / r", "walk the folder list, open the highlighted file"},
	{"Ctrl Shift S", "choose where to export, then export"},
	{"t", "transcribe"},
	{"Space / k", "play or pause"},
	{"← →", "seek two seconds (ten with Shift)"},
	{"↑ ↓", "select the previous or next caption and seek to it"},
	{"Home / End", "first or last caption"},
	{"Enter", "edit the selected caption"},
	{"Esc", "stop editing, or cancel a running job"},
	{"s", "split the caption at the caret"},
	{"m", "merge with the next caption"},
	{"d", "delete the caption"},
	{"n", "insert a new caption after this one"},
	{"w / W", "re-wrap this caption, or all of them"},
	{"[ ]", "nudge the in point by 0.1s (0.5s with Shift)"},
	{", .", "nudge the out point"},
	{"< >", "slide the whole caption"},
	{"i / u", "set the in or out point from the playhead"},
	{"+ - 0", "zoom the waveform in, out, or to the whole file"},
	{"g", "follow the playhead while playing"},
	{"1 2 3 4", "Transcribe, Captions, Style, Export"},
	{"f", "cycle the export format"},
	{"e / Ctrl-S", "export"},
	{"b", "burn the captions into a new video"},
	{"Ctrl-Q", "quit"},
}

help_overlay :: proc(ui: ^p.Ctx, m: ^App_State) {
	p.div(ui, "absolute inset-0 z-50 flex-row items-center justify-center bg-black/60")
	defer p.end(ui)
	if p.clickable(ui) {
		m.help = false
	}

	p.col(ui, "w-[620] max-h-[86%] gap-2 p-5 rounded-xl border border-border bg-card shadow-2xl overflow-scroll")
	{
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, IC_CAPTIONS, "size-4 text-primary")
		p.text(ui, "Keys", "text-sm font-semibold")
		p.spacer(ui)
		p.text(ui, "Esc or click to close", "text-[11] text-muted-foreground")
		p.end(ui)
		p.div(ui, "h-px w-full bg-border my-1")
		p.end(ui)

		for h in HELP {
			p.row(ui, "w-full items-baseline gap-3 py-0.5")
			p.text(ui, h[0], "font-mono text-[11] font-semibold w-[96] shrink-0 text-right")
			p.text(ui, h[1], "text-[12] text-muted-foreground")
			p.end(ui)
		}

		p.div(ui, "h-px w-full bg-border my-1")
		p.end(ui)
		p.text(ui, "Styling keys, while the Style panel is open: j l size · h r outline · c fill colour · x background box · y bold · p position.", "text-[11] text-muted-foreground")
		p.text(ui, "Everything is local: ffmpeg, ffprobe, whisper.cpp and ffplay, with the model weights read from disk. Nothing is uploaded.", "text-[11] text-muted-foreground")
	}
	p.end(ui)
}
