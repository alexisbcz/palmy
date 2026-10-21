package main

// The slide renderer.
//
// One procedure draws a slide into any rectangle of any canvas: the editing
// canvas, a 160x90 thumbnail in the sorter, the fullscreen projector surface
// and the PNG exporter all call `draw_slide`. That is deliberate — a sorter
// showing approximations of slides is worse than useless, and an exporter that
// renders through a second code path is a second renderer to keep honest.
//
// Everything below works in *device pixels*: the slide's 1280x720 coordinate
// space is scaled into the destination rectangle, and text is measured at the
// size it will actually be drawn at, because wrapping measured at one size and
// drawn at another is wrapping that lies.

import "core:math"
import "core:strings"
import p "palmy:."

argb :: proc(v: u32) -> p.Color {
	return {u8(v >> 16), u8(v >> 8), u8(v), u8(v >> 24)}
}

// Guide is a snapping line, in slide coordinates, shown while a drag is active.
Guide :: struct {
	vertical: bool,
	at:       f32,
	kind:     u8, // 0 slide centre/margin, 1 another element
}

// Opts is everything the renderer needs that is not the deck itself.
Opts :: struct {
	fonts:     ^p.Fonts,
	imgs:      ^Img_Cache,
	// Editing chrome. Off for export and for presenting.
	chrome:    bool,
	selected:  int,
	editing:   bool,
	caret:     int,
	caret_on:  bool,
	sel_a:     int, // the selection while editing, a byte range; empty when equal
	sel_b:     int,
	guides:    []Guide,
	// Decoration
	footer:    bool,
	number:    int,
	total:     int,
	// Thumbnails skip the small type and the footer; they are 160px wide.
	thumb:     bool,
	// The deck's face, filled in by draw_slide.
	fam:       p.Font_Family,
}

// draw_slide paints slide `si` of `d` into `dst`.
draw_slide :: proc(c: ^p.Canvas, dst: p.Rect, d: ^Deck, si: int, o: Opts) {
	if si < 0 || si >= len(d.slides) {
		return
	}
	s := &d.slides[si]
	th := &d.theme
	sc := dst.w / SLIDE_W
	o := o
	o.fam = theme_family(th)

	p.push_clip(c, dst)
	defer p.pop_clip(c)

	// Background. A two-stop vertical gradient when the theme asks for one,
	// which is what keeps a dark deck from looking like a black rectangle.
	if th.bg2 != 0 && th.bg2 != th.bg {
		p.fill_rect_paint(c, dst, p.gradient(argb(th.bg), argb(th.bg2), true))
	} else {
		p.fill_rect(c, dst, argb(th.bg))
	}

	if !d.no_decor {
		draw_master(c, dst, sc, d, s, o)
	}

	for i in 0 ..< len(s.elems) {
		e := &s.elems[i]
		editing := o.chrome && o.editing && i == o.selected
		draw_element(c, dst, sc, th, e, o, editing)
	}

	if o.chrome {
		for g in o.guides {
			draw_guide(c, dst, sc, th, g)
		}
		if o.selected >= 0 && o.selected < len(s.elems) {
			draw_handles(c, dst, sc, th, &s.elems[o.selected], o.editing)
		}
	}
}

// ---------------------------------------------------------------------------
// The master: what the layout and theme draw before any element
// ---------------------------------------------------------------------------

@(private = "file")
draw_master :: proc(c: ^p.Canvas, dst: p.Rect, sc: f32, d: ^Deck, s: ^Slide, o: Opts) {
	th := &d.theme
	accent := argb(th.accent)
	accent2 := argb(th.accent2)

	to :: proc(dst: p.Rect, sc: f32, x, y, w, h: f32) -> p.Rect {
		return {dst.x + x * sc, dst.y + y * sc, w * sc, h * sc}
	}

	switch s.layout {
	case .Title:
		// A soft accent wash in the corner, and a rule centred under whatever
		// the title turned out to be.
		fill_form(c, to(dst, sc, 820, -220, 720, 720), 360, 0, .Ellipse, p.fade(accent, 0.13))
		fill_form(c, to(dst, sc, -180, 420, 620, 620), 310, 0, .Ellipse, p.fade(accent2, 0.08))
		if ry, ok := title_baseline(c, dst, sc, s, o); ok {
			p.fill_rect(c, {dst.x + (SLIDE_W / 2 - 70) * sc, ry, 140 * sc, max(2, 3 * sc)}, p.fade(accent, 0.9))
		}
	case .Section_Header:
		p.fill_rect(c, to(dst, sc, 0, 0, 10, SLIDE_H), accent)
		fill_form(c, to(dst, sc, 980, 140, 440, 440), 220, 0, .Ellipse, p.fade(accent2, 0.1))
	case .Title_Content, .Two_Content, .Picture:
		ry, ok := title_baseline(c, dst, sc, s, o)
		if !ok {
			ry = dst.y + 182 * sc
		}
		p.fill_rect(c, {dst.x + MARGIN * sc, ry, 86 * sc, max(2, 3 * sc)}, accent)
	case .Blank:
	}

	if o.footer && !o.thumb && s.layout != .Title && s.layout != .Blank {
		size := 15 * sc
		m := p.font_metrics(o.fonts, size, o.fam, .Regular)
		y := dst.y + (SLIDE_H - 38) * sc + m.ascent
		p.fill_rect(c, to(dst, sc, MARGIN, SLIDE_H - 54, SLIDE_W - 2 * MARGIN, 1), p.fade(argb(th.muted), 0.25))
		p.draw_text(c, o.fonts, d.title, dst.x + MARGIN * sc, y, size, p.fade(argb(th.muted), 0.9), o.fam, .Regular)
		if o.total > 0 {
			label := tprintf("%d / %d", o.number, o.total)
			w := p.text_width(o.fonts, label, size, o.fam, .Medium)
			p.draw_text(
				c,
				o.fonts,
				label,
				dst.x + (SLIDE_W - MARGIN) * sc - w,
				y,
				size,
				p.fade(argb(th.muted), 0.9),
				o.fam,
				.Medium,
			)
		}
	}
}

// title_baseline finds where the title text actually ends, so the accent rule
// under it tracks a title that wrapped to two lines instead of floating in the
// middle of one. A master that ignores its own content is how slide templates
// end up looking broken.
@(private = "file")
title_baseline :: proc(c: ^p.Canvas, dst: p.Rect, sc: f32, s: ^Slide, o: Opts) -> (y: f32, ok: bool) {
	for i in 0 ..< len(s.elems) {
		e := &s.elems[i]
		if e.kind != .Text || e.style != .Title || strings.trim_space(e.text) == "" {
			continue
		}
		box := p.Rect{dst.x + e.x * sc, dst.y + e.y * sc, e.w * sc, e.h * sc}
		tl := text_layout(o.fonts, box, sc, e, o.fam)
		return text_bottom(o.fonts, &tl) + 18 * sc, true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------

draw_element :: proc(c: ^p.Canvas, dst: p.Rect, sc: f32, th: ^Theme, e: ^Element, o: Opts, editing: bool) {
	box := p.Rect{dst.x + e.x * sc, dst.y + e.y * sc, e.w * sc, e.h * sc}
	alpha := clamp(e.opacity, 0, 1)
	rad := e.radius * sc
	rot := e.rotation

	switch e.kind {
	case .Rect, .Ellipse:
		form := e.kind == .Rect ? Form.Rect : Form.Ellipse
		if has_paint(e.fill) {
			col := paint(th, e.fill)
			fill_form(c, box, rad, rot, form, p.fade(col, alpha * e.fill_a))
		}
		if has_paint(e.stroke) && e.stroke_w > 0 {
			stroke_form(c, box, rad, rot, form, e.stroke_w * sc, p.fade(paint(th, e.stroke), alpha))
		}

	case .Line, .Arrow:
		col := has_paint(e.stroke) ? paint(th, e.stroke) : paint(th, SLOT_FG)
		a, b := line_ends(e, dst, sc)
		w := max(e.stroke_w, 1) * sc
		p.draw_line(c, a.x, a.y, b.x, b.y, w, p.fade(col, alpha))
		if e.kind == .Arrow {
			draw_arrow_head(c, a, b, max(e.head, 12) * sc, p.fade(col, alpha))
		}

	case .Image:
		img, ok := img_get(o.imgs, e.src)
		if ok {
			image_form(c, box, rad, rot, img, alpha)
		} else {
			// A missing image is drawn as a frame with its path, so a deck
			// moved between machines says what it is looking for.
			fill_form(c, box, rad, rot, .Rect, p.fade(paint(th, SLOT_SURFACE), alpha))
			stroke_form(c, box, rad, rot, .Rect, max(1, 2 * sc), p.fade(paint(th, SLOT_MUTED), 0.6 * alpha))
			if !o.thumb {
				size := 16 * sc
				label := e.src == "" ? "no image" : e.src
				w := p.text_width(o.fonts, label, size, .Sans, .Regular)
				p.draw_text(
					c,
					o.fonts,
					label,
					box.x + (box.w - w) / 2,
					box.y + box.h / 2,
					size,
					paint(th, SLOT_MUTED),
					.Sans,
					.Regular,
				)
			}
		}

	case .Text:
		if has_paint(e.fill) {
			fill_form(c, box, rad, rot, .Rect, p.fade(paint(th, e.fill), alpha * e.fill_a))
		}
		if has_paint(e.stroke) && e.stroke_w > 0 {
			stroke_form(c, box, rad, rot, .Rect, e.stroke_w * sc, p.fade(paint(th, e.stroke), alpha))
		}
		draw_text_box(c, box, sc, th, e, o, editing, alpha)
	}
}

@(private = "file")
line_ends :: proc(e: ^Element, dst: p.Rect, sc: f32) -> (a, b: [2]f32) {
	cx := dst.x + (e.x + e.w / 2) * sc
	cy := dst.y + (e.y + e.h / 2) * sc
	hx := e.w / 2 * sc
	hy := e.h / 2 * sc
	co := math.cos(math.to_radians(e.rotation))
	si := math.sin(math.to_radians(e.rotation))
	rot :: proc(x, y, co, si: f32) -> [2]f32 {
		return {x * co - y * si, x * si + y * co}
	}
	p0 := rot(-hx, -hy, co, si)
	p1 := rot(hx, hy, co, si)
	return {cx + p0.x, cy + p0.y}, {cx + p1.x, cy + p1.y}
}

@(private = "file")
draw_arrow_head :: proc(c: ^p.Canvas, a, b: [2]f32, size: f32, col: p.Color) {
	dx, dy := b.x - a.x, b.y - a.y
	l := math.sqrt(dx * dx + dy * dy)
	if l < 0.01 {
		return
	}
	ux, uy := dx / l, dy / l
	// Base of the head, and the two wings.
	bx, by := b.x - ux * size, b.y - uy * size
	w := size * 0.42
	fill_triangle(c, b, {bx - uy * w, by + ux * w}, {bx + uy * w, by - ux * w}, col)
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

Line :: struct {
	start, end: int, // byte range in the element's text
	w:          f32, // measured width in device pixels
	bullet:     bool,
	indent:     f32,
	// Filled in by text_layout. A line's height follows the largest type on
	// it, so a line with one 60pt word in a 27pt box does not overprint the
	// line above.
	top:        f32,
	base:       f32, // baseline
	lh:         f32,
	size:       f32, // the largest size on the line, device pixels
}

// Measure is what wrapping needs to measure a stretch of a box's text: the
// box's own type, and its runs when it has any.
Measure :: struct {
	fonts:      ^p.Fonts,
	text:       string,
	e:          ^Element, // nil, or a box without runs: one style throughout
	size:       f32, // device pixels
	sc:         f32,
	wt:         p.Font_Weight,
	track:      f32, // tracking at `size`, device pixels
	track_frac: f32, // tracking as a fraction of the size, for a run's own size
	fam:        p.Font_Family,
}

// Span_Font is the face and size one segment is set in.
Span_Font :: struct {
	size:     f32,
	wt:       p.Font_Weight,
	sl:       p.Font_Slant,
	tracking: f32,
}

span_font :: proc(m: ^Measure, s: Run_Style) -> Span_Font {
	if style_plain(s) {
		return {m.size, m.wt, .Upright, m.track}
	}
	size := m.size
	if s.size > 0 {
		size = s.size * m.sc
	}
	return {size, s.bold ? .Bold : m.wt, s.italic ? .Italic : .Upright, m.track_frac * size}
}

// measure_width is how wide [from, to) of the text sets. Without runs it is
// the one `text_width` call it always was.
measure_width :: proc(m: ^Measure, from, to: int) -> f32 {
	if from >= to {
		return 0
	}
	if m.e == nil || len(m.e.runs) == 0 {
		return p.text_width(m.fonts, m.text[from:to], m.size, m.fam, m.wt, m.track)
	}
	w: f32
	for sg in text_segments(m.e, from, to) {
		f := span_font(m, sg.s)
		w += p.text_width(m.fonts, m.text[sg.start:sg.end], f.size, m.fam, f.wt, f.tracking, f.sl)
	}
	return w
}

// wrap_text lays a plain string out at the size it will be drawn, returning
// lines with their byte ranges so a caret can be placed back into the source
// text.
wrap_text :: proc(
	fonts: ^p.Fonts,
	text: string,
	size: f32,
	wt: p.Font_Weight,
	tracking: f32,
	max_w: f32,
	bullets: bool,
	fam := p.Font_Family.Sans,
) -> []Line {
	m := Measure {
		fonts = fonts,
		text  = text,
		size  = size,
		sc    = 1,
		wt    = wt,
		track = tracking,
		fam   = fam,
	}
	return wrap_lines(&m, max_w, bullets)
}

// wrap_lines is wrap_text over a Measure, so a box with runs wraps on the
// widths its runs actually set at.
wrap_lines :: proc(m: ^Measure, max_w: f32, bullets: bool) -> []Line {
	text := m.text
	size := m.size
	out := make([dynamic]Line, context.temp_allocator)
	i := 0
	for {
		nl := strings.index_byte(text[i:], '\n')
		end := nl < 0 ? len(text) : i + nl
		para := text[i:end]
		bullet := bullets && (strings.has_prefix(para, "- ") || strings.has_prefix(para, "• "))
		indent := bullet ? size * 1.15 : 0
		body_start := i
		if bullet {
			body_start = i + (strings.has_prefix(para, "- ") ? 2 : len("• "))
		}
		wrap_para(m, body_start, end, max_w - indent, bullet, indent, &out)
		if nl < 0 {
			break
		}
		i = end + 1
		if i > len(text) {
			break
		}
		if i == len(text) {
			// A trailing newline leaves an empty last line, which is where a
			// caret after it has to sit.
			append(&out, Line{start = i, end = i, w = 0})
			break
		}
	}
	if len(out) == 0 {
		append(&out, Line{start = 0, end = 0, w = 0})
	}
	return out[:]
}

@(private = "file")
wrap_para :: proc(m: ^Measure, from, to: int, max_w: f32, bullet: bool, indent: f32, out: ^[dynamic]Line) {
	text := m.text
	if from >= to {
		append(out, Line{start = from, end = to, w = 0, bullet = bullet, indent = indent})
		return
	}
	line_start := from
	last_break := -1
	first := true
	i := from
	for i <= to {
		// Candidate break point: a space, or the end.
		if i == to || text[i] == ' ' {
			w := measure_width(m, line_start, i)
			if w > max_w && last_break > line_start {
				append(
					out,
					Line {
						start = line_start,
						end = last_break,
						w = measure_width(m, line_start, last_break),
						bullet = first && bullet,
						indent = indent,
					},
				)
				first = false
				line_start = last_break + 1
				last_break = -1
				continue
			}
			if i == to {
				break
			}
			last_break = i
		}
		i += 1
	}
	append(
		out,
		Line {
			start = line_start,
			end = to,
			w = measure_width(m, line_start, to),
			bullet = first && bullet,
			indent = indent,
		},
	)
}

text_weight :: proc(e: ^Element) -> p.Font_Weight {
	spec := TYPE_SCALE[e.style]
	if e.bold || spec.bold {
		return .Bold
	}
	if e.style == .Subtitle || e.style == .Quote {
		return .Medium
	}
	return .Regular
}

// text_layout is the geometry a text element resolves to, shared by the
// renderer, the exporters and click-to-caret hit testing.
Text_Layout :: struct {
	lines:    []Line,
	size:     f32,
	line_h:   f32,
	first_y:  f32, // baseline of the first line
	wt:       p.Font_Weight,
	fam:      p.Font_Family,
	tracking: f32,
	box:      p.Rect, // the text area, inset from the element box
	m:        Measure,
}

text_layout :: proc(fonts: ^p.Fonts, box: p.Rect, sc: f32, e: ^Element, fam := p.Font_Family.Sans) -> Text_Layout {
	spec := TYPE_SCALE[e.style]
	size := text_size(e) * sc
	wt := text_weight(e)
	tracking := spec.tracking * size
	pad := has_paint(e.fill) ? 20 * sc : 0
	area := p.Rect{box.x + pad, box.y + pad, max(8, box.w - 2 * pad), max(8, box.h - 2 * pad)}
	m := Measure {
		fonts      = fonts,
		text       = e.text,
		e          = e,
		size       = size,
		sc         = sc,
		wt         = wt,
		track      = tracking,
		track_frac = spec.tracking,
		fam        = fam,
	}
	lines := wrap_lines(&m, area.w, e.style == .Bullets)

	line_h := size * spec.leading
	met := p.font_metrics(fonts, size, fam, wt)
	total: f32
	for &l in lines {
		l.size = size
		if len(e.runs) > 0 {
			for sg in text_segments(e, l.start, l.end) {
				if sg.s.size > 0 {
					l.size = max(l.size, sg.s.size * sc)
				}
			}
		}
		l.lh = l.size == size ? line_h : l.size * spec.leading
		total += l.lh
	}
	top := area.y
	switch e.valign {
	case .Top:
	case .Middle:
		top += (area.h - total) / 2
	case .Bottom:
		top += area.h - total
	}
	y := top
	for &l in lines {
		lm := met
		if l.size != size {
			lm = p.font_metrics(fonts, l.size, fam, wt)
		}
		l.top = y
		l.base = y + (l.lh - (lm.ascent + lm.descent)) / 2 + lm.ascent
		y += l.lh
	}
	return {
		lines = lines,
		size = size,
		line_h = line_h,
		first_y = lines[0].base,
		wt = wt,
		fam = fam,
		tracking = tracking,
		box = area,
		m = m,
	}
}

// text_bottom is where the last line's descenders end, which is where a
// master's accent rule under the title is measured from.
text_bottom :: proc(fonts: ^p.Fonts, tl: ^Text_Layout) -> f32 {
	l := tl.lines[len(tl.lines) - 1]
	m := p.font_metrics(fonts, l.size, tl.fam, tl.wt)
	return l.base + m.descent
}

line_x :: proc(tl: ^Text_Layout, l: Line, e: ^Element) -> f32 {
	switch e.halign {
	case .Left:
		return tl.box.x + l.indent
	case .Center:
		return tl.box.x + (tl.box.w - l.w) / 2
	case .Right:
		return tl.box.x + tl.box.w - l.w
	}
	return tl.box.x
}

// seg_colour is what a segment is painted with: its run's colour when it has
// one, the box's otherwise.
seg_colour :: proc(th: ^Theme, s: Run_Style, box_col: p.Color, alpha: f32) -> p.Color {
	if s.color == SLOT_NONE {
		return box_col
	}
	return p.fade(paint(th, s.color), alpha)
}

@(private = "file")
draw_text_box :: proc(
	c: ^p.Canvas,
	box: p.Rect,
	sc: f32,
	th: ^Theme,
	e: ^Element,
	o: Opts,
	editing: bool,
	alpha: f32,
) {
	if strings.trim_space(e.text) == "" && !editing {
		if o.chrome {
			// An empty placeholder still has to be findable.
			stroke_form(c, box, e.radius * sc, 0, .Rect, max(1, sc), p.fade(paint(th, SLOT_MUTED), 0.35))
		}
		return
	}
	spec := TYPE_SCALE[e.style]
	col := paint(th, e.color)
	if e.color == SLOT_NONE {
		col = spec.muted ? argb(th.muted) : argb(th.fg)
	}
	col = p.fade(col, alpha)

	tl := text_layout(o.fonts, box, sc, e, theme_family(th))

	// The caret's line is the last one that starts at or before it.
	ci := clamp(o.caret, 0, len(e.text))
	caret_line := 0
	for l, i in tl.lines {
		if ci >= l.start {
			caret_line = i
		}
	}

	// The selection, behind the text it covers.
	if editing && o.sel_a != o.sel_b {
		a := clamp(min(o.sel_a, o.sel_b), 0, len(e.text))
		b := clamp(max(o.sel_a, o.sel_b), 0, len(e.text))
		for l in tl.lines {
			lo := max(a, l.start)
			hi := min(b, l.end)
			if lo > hi || (lo == hi && !(b > l.end && a <= l.end)) {
				continue
			}
			x := line_x(&tl, l, e)
			x0 := x + measure_width(&tl.m, l.start, lo)
			x1 := x + measure_width(&tl.m, l.start, hi)
			if b > l.end {
				x1 += l.size * 0.3 // the newline itself is selected
			}
			p.fill_rect(c, {x0, l.top, max(x1 - x0, 1), l.lh}, p.fade(paint(th, SLOT_ACCENT2), 0.35))
		}
	}

	for l, li in tl.lines {
		x := line_x(&tl, l, e)
		y := l.base
		if l.bullet {
			r := tl.size * 0.16
			p.fill_circle(c, tl.box.x + r * 1.6, y - tl.size * 0.3, r, p.fade(paint(th, SLOT_ACCENT), alpha))
		}
		if len(e.runs) == 0 {
			p.draw_text(c, o.fonts, e.text[l.start:l.end], x, y, tl.size, col, tl.fam, tl.wt, tl.tracking)
		} else {
			sx := x
			for sg in text_segments(e, l.start, l.end) {
				f := span_font(&tl.m, sg.s)
				run := e.text[sg.start:sg.end]
				p.draw_text(c, o.fonts, run, sx, y, f.size, seg_colour(th, sg.s, col, alpha), tl.fam, f.wt, f.tracking, f.sl)
				sx += p.text_width(o.fonts, run, f.size, tl.fam, f.wt, f.tracking, f.sl)
			}
		}

		if editing && o.caret_on && li == caret_line {
			upto := clamp(ci, l.start, l.end)
			cx := x + measure_width(&tl.m, l.start, upto)
			cs := l.size
			p.fill_rect(c, {cx, y - cs * 0.82, max(1.5, 2 * sc), cs * 1.05}, paint(th, SLOT_ACCENT))
		}
	}
}

// caret_at maps a point inside a text element back to a byte index.
caret_at :: proc(fonts: ^p.Fonts, box: p.Rect, sc: f32, e: ^Element, x, y: f32, fam := p.Font_Family.Sans) -> int {
	tl := text_layout(fonts, box, sc, e, fam)
	if len(tl.lines) == 0 {
		return 0
	}
	li := 0
	for l, i in tl.lines {
		if y >= l.top {
			li = i
		}
	}
	l := tl.lines[li]
	lx := line_x(&tl, l, e)
	if len(e.runs) == 0 {
		idx := p.text_index_at(fonts, e.text[l.start:l.end], tl.size, x - lx, tl.fam, tl.wt, tl.tracking)
		return l.start + idx
	}
	sx := lx
	segs := text_segments(e, l.start, l.end)
	for sg, k in segs {
		f := span_font(&tl.m, sg.s)
		run := e.text[sg.start:sg.end]
		w := p.text_width(fonts, run, f.size, tl.fam, f.wt, f.tracking, f.sl)
		if x < sx + w || k == len(segs) - 1 {
			return sg.start + p.text_index_at(fonts, run, f.size, x - sx, tl.fam, f.wt, f.tracking, f.sl)
		}
		sx += w
	}
	return l.end
}

// ---------------------------------------------------------------------------
// Editing chrome
// ---------------------------------------------------------------------------

HANDLES :: 8

// handle_points returns the eight resize handles in device pixels.
handle_points :: proc(dst: p.Rect, sc: f32, e: ^Element) -> [HANDLES][2]f32 {
	x0 := dst.x + e.x * sc
	y0 := dst.y + e.y * sc
	x1 := x0 + e.w * sc
	y1 := y0 + e.h * sc
	mx := (x0 + x1) / 2
	my := (y0 + y1) / 2
	return [HANDLES][2]f32 {
		{x0, y0},
		{mx, y0},
		{x1, y0},
		{x1, my},
		{x1, y1},
		{mx, y1},
		{x0, y1},
		{x0, my},
	}
}

@(private = "file")
draw_handles :: proc(c: ^p.Canvas, dst: p.Rect, sc: f32, th: ^Theme, e: ^Element, editing: bool) {
	box := p.Rect{dst.x + e.x * sc, dst.y + e.y * sc, e.w * sc, e.h * sc}
	col := editing ? argb(th.accent2) : argb(th.accent)
	w := max(1.25, 1.5 * sc)

	// The outline sits just outside the element so it never hides its edge.
	out := p.rect_inset(box, -w)
	stroke_form(c, out, (e.radius + 2) * sc, e.rotation, .Rect, w, p.fade(col, 0.95))

	if editing {
		return // while typing, handles would only be in the way
	}
	pts := handle_points(dst, sc, e)
	r := max(3.5, 5 * sc)
	for pt in pts {
		p.fill_round_rect(c, {pt.x - r, pt.y - r, r * 2, r * 2}, {2, 2, 2, 2}, p.WHITE)
		p.stroke_round_rect(c, {pt.x - r, pt.y - r, r * 2, r * 2}, {2, 2, 2, 2}, max(1, sc), col)
	}
}

@(private = "file")
draw_guide :: proc(c: ^p.Canvas, dst: p.Rect, sc: f32, th: ^Theme, g: Guide) {
	col := g.kind == 0 ? argb(th.accent2) : argb(th.accent)
	col = p.fade(col, 0.85)
	w := max(1, sc)
	// Dashed, so a guide never reads as part of the slide.
	dash := 10 * sc
	gap := 7 * sc
	if g.vertical {
		x := dst.x + g.at * sc
		for y := dst.y; y < dst.y + dst.h; y += dash + gap {
			p.fill_rect(c, {x, y, w, min(dash, dst.y + dst.h - y)}, col)
		}
	} else {
		y := dst.y + g.at * sc
		for x := dst.x; x < dst.x + dst.w; x += dash + gap {
			p.fill_rect(c, {x, y, min(dash, dst.x + dst.w - x), w}, col)
		}
	}
}

// ---------------------------------------------------------------------------
// Shapes: rounded rectangles, ellipses and images, with rotation
//
// palmy's rasterizer draws axis-aligned rounded rectangles very fast, and that
// is the right primitive for a user interface. A slide editor also needs
// rotation and elliptical shapes, so the general case is evaluated here through
// a signed distance field in the shape's own rotated frame — the same idea
// palmy uses, one transform further out. The axis-aligned rectangle still takes
// palmy's fast path.
// ---------------------------------------------------------------------------

Form :: enum u8 {
	Rect,
	Ellipse,
}

@(private = "file")
sd_round_rect :: proc(qx, qy, hw, hh, r: f32) -> f32 {
	rr := min(r, min(hw, hh))
	ax := abs(qx) - (hw - rr)
	ay := abs(qy) - (hh - rr)
	dx := max(ax, 0)
	dy := max(ay, 0)
	return min(max(ax, ay), 0) + math.sqrt(dx * dx + dy * dy) - rr
}

@(private = "file")
sd_ellipse :: proc(qx, qy, hw, hh: f32) -> f32 {
	if hw <= 0 || hh <= 0 {
		return 1
	}
	ux := qx / hw
	uy := qy / hh
	k := math.sqrt(ux * ux + uy * uy)
	return (k - 1) * min(hw, hh)
}

@(private = "file")
sdf :: proc(form: Form, qx, qy, hw, hh, rad: f32) -> f32 {
	return form == .Ellipse ? sd_ellipse(qx, qy, hw, hh) : sd_round_rect(qx, qy, hw, hh, rad)
}

// rot_bounds is the axis-aligned box a rotated rectangle needs.
@(private = "file")
rot_bounds :: proc(box: p.Rect, rot: f32) -> (cx, cy, hw, hh, co, si: f32, bb: p.Rect) {
	hw = box.w / 2
	hh = box.h / 2
	cx = box.x + hw
	cy = box.y + hh
	a := math.to_radians(rot)
	co = math.cos(a)
	si = math.sin(a)
	ex := abs(hw * co) + abs(hh * si)
	ey := abs(hw * si) + abs(hh * co)
	bb = p.Rect{cx - ex - 1, cy - ey - 1, 2 * ex + 2, 2 * ey + 2}
	return
}

fill_form :: proc(c: ^p.Canvas, box: p.Rect, rad, rot: f32, form: Form, col: p.Color) {
	if col.a == 0 || box.w <= 0 || box.h <= 0 {
		return
	}
	if form == .Rect && abs(rot) < 0.01 {
		p.fill_round_rect(c, box, {rad, rad, rad, rad}, col)
		return
	}
	cx, cy, hw, hh, co, si, bb := rot_bounds(box, rot)
	b := p.rect_intersect(bb, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}
	for y in int(math.floor(b.y)) ..< int(math.ceil(p.rect_bottom(b))) {
		dy := f32(y) + 0.5 - cy
		for x in int(math.floor(b.x)) ..< int(math.ceil(p.rect_right(b))) {
			dx := f32(x) + 0.5 - cx
			qx := dx * co + dy * si
			qy := -dx * si + dy * co
			cov := clamp(0.5 - sdf(form, qx, qy, hw, hh, rad), 0, 1)
			if cov > 0.002 {
				p.blend(c, x, y, col, cov)
			}
		}
	}
}

stroke_form :: proc(c: ^p.Canvas, box: p.Rect, rad, rot: f32, form: Form, width: f32, col: p.Color) {
	if col.a == 0 || width <= 0 || box.w <= 0 || box.h <= 0 {
		return
	}
	if form == .Rect && abs(rot) < 0.01 {
		p.stroke_round_rect(c, box, {rad, rad, rad, rad}, width, col)
		return
	}
	cx, cy, hw, hh, co, si, bb := rot_bounds(p.rect_inset(box, -width), rot)
	b := p.rect_intersect(bb, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}
	half := width / 2
	for y in int(math.floor(b.y)) ..< int(math.ceil(p.rect_bottom(b))) {
		dy := f32(y) + 0.5 - cy
		for x in int(math.floor(b.x)) ..< int(math.ceil(p.rect_right(b))) {
			dx := f32(x) + 0.5 - cx
			qx := dx * co + dy * si
			qy := -dx * si + dy * co
			// The stroke straddles the edge of the *original* box.
			d := abs(sdf(form, qx, qy, hw - half, hh - half, max(rad - half, 0))) - half
			cov := clamp(0.5 - d, 0, 1)
			if cov > 0.002 {
				p.blend(c, x, y, col, cov)
			}
		}
	}
}

// image_form draws an image into a rounded, possibly rotated box, cropped like
// CSS `object-fit: cover`. palmy's own `draw_image` is axis-aligned and square
// cornered, so the sampling is done here.
image_form :: proc(c: ^p.Canvas, box: p.Rect, rad, rot: f32, img: p.Image, alpha: f32) {
	if img.w <= 0 || img.h <= 0 || box.w <= 0 || box.h <= 0 || alpha <= 0.002 {
		return
	}
	cx, cy, hw, hh, co, si, bb := rot_bounds(box, rot)
	b := p.rect_intersect(bb, c.clip)
	if b.w <= 0 || b.h <= 0 {
		return
	}
	// Cover: the shorter axis fills the box and the longer one is cropped.
	s := max(box.w / f32(img.w), box.h / f32(img.h))
	iw := f32(img.w) * s
	ih := f32(img.h) * s

	for y in int(math.floor(b.y)) ..< int(math.ceil(p.rect_bottom(b))) {
		dy := f32(y) + 0.5 - cy
		for x in int(math.floor(b.x)) ..< int(math.ceil(p.rect_right(b))) {
			dx := f32(x) + 0.5 - cx
			qx := dx * co + dy * si
			qy := -dx * si + dy * co
			cov := clamp(0.5 - sd_round_rect(qx, qy, hw, hh, rad), 0, 1)
			if cov <= 0.002 {
				continue
			}
			u := (qx + iw / 2) / s - 0.5
			v := (qy + ih / 2) / s - 0.5
			col := sample(img, u, v)
			if col.a == 0 {
				continue
			}
			p.blend(c, x, y, col, cov * alpha * f32(col.a) / 255)
		}
	}
}

// sample is bilinear with alpha-weighted taps, which is what keeps a
// transparent PNG from bleeding black into its edges. palmy has exactly this
// procedure but keeps it private, so it lives here too.
@(private = "file")
sample :: proc(img: p.Image, u, v: f32) -> p.Color {
	x0 := int(math.floor(u))
	y0 := int(math.floor(v))
	fx := u - f32(x0)
	fy := v - f32(y0)
	tap :: proc(img: p.Image, x, y: int) -> [4]f32 {
		cx := clamp(x, 0, img.w - 1)
		cy := clamp(y, 0, img.h - 1)
		v := img.px[cy * img.w + cx]
		a := f32((v >> 24) & 0xff)
		return {f32((v >> 16) & 0xff) * a, f32((v >> 8) & 0xff) * a, f32(v & 0xff) * a, a}
	}
	c00 := tap(img, x0, y0)
	c10 := tap(img, x0 + 1, y0)
	c01 := tap(img, x0, y0 + 1)
	c11 := tap(img, x0 + 1, y0 + 1)
	top := c00 * (1 - fx) + c10 * fx
	bot := c01 * (1 - fx) + c11 * fx
	out := top * (1 - fy) + bot * fy
	if out.w < 0.5 {
		return {}
	}
	inv := 1 / out.w
	return {
		u8(clamp(out.x * inv, 0, 255)),
		u8(clamp(out.y * inv, 0, 255)),
		u8(clamp(out.z * inv, 0, 255)),
		u8(clamp(out.w, 0, 255)),
	}
}

@(private = "file")
fill_triangle :: proc(c: ^p.Canvas, a, b, d: [2]f32, col: p.Color) {
	minx := min(a.x, min(b.x, d.x)) - 1
	maxx := max(a.x, max(b.x, d.x)) + 1
	miny := min(a.y, min(b.y, d.y)) - 1
	maxy := max(a.y, max(b.y, d.y)) + 1
	bb := p.rect_intersect({minx, miny, maxx - minx, maxy - miny}, c.clip)
	if bb.w <= 0 || bb.h <= 0 {
		return
	}
	// Edge functions, normalised so the value is a distance in pixels.
	edge :: proc(p0, p1: [2]f32, x, y: f32) -> f32 {
		ex, ey := p1.x - p0.x, p1.y - p0.y
		l := math.sqrt(ex * ex + ey * ey)
		if l < 0.0001 {
			return -1
		}
		return ((x - p0.x) * ey - (y - p0.y) * ex) / l
	}
	// Orient so inside is positive.
	flip := edge(a, b, d.x, d.y) < 0 ? f32(-1) : 1
	for y in int(bb.y) ..< int(math.ceil(p.rect_bottom(bb))) {
		py := f32(y) + 0.5
		for x in int(bb.x) ..< int(math.ceil(p.rect_right(bb))) {
			px := f32(x) + 0.5
			d0 := edge(a, b, px, py) * flip
			d1 := edge(b, d, px, py) * flip
			d2 := edge(d, a, px, py) * flip
			dmin := min(d0, min(d1, d2))
			cov := clamp(0.5 + dmin, 0, 1)
			if cov > 0.002 {
				p.blend(c, x, y, col, cov)
			}
		}
	}
}
