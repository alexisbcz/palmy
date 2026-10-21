package main

// The chrome: the top bar, the slide sorter, the canvas, the inspector, the
// notes strip, the status bar, the command menu and the cheatsheet.
//
// The chrome is built from shadcn tokens so it looks like the rest of the
// suite; the slide itself follows the deck's own theme and is drawn with the
// rasterizer, inside two `p.pixels` panels — one for the canvas, one per
// thumbnail. Those are the only places this application leaves the layout
// engine, and they are exactly the places a slide editor has to.

import "core:math"
import "core:strings"
import "core:time"
import p "palmy:."
import collabui "../../cloud/collab/ui"
import sc "shadcn:."

TOP_H :: 44
FOOT_H :: 34
NOTES_H :: 132

build :: proc(ui: ^p.Ctx, st: ^St) {
	// Asked once per frame, and only while a caret is up: `caret_on` arms the
	// wake for the next blink edge, so an editor with nothing being typed
	// into sleeps.
	caret_lit = st.mode == .Text || st.mode == .Notes ? p.caret_on(ui) : true
	size := p.size(ui)

	// Hyprland tiles, so the window is whatever the compositor says. The two
	// side panels give way first, and the canvas keeps what is left.
	narrow := size.x < 1180
	st.sorter_w = narrow ? 146 : 196
	st.inspect_w = narrow ? 254 : 304
	st.thumb_w = st.sorter_w - 44

	body_h := size.y - TOP_H - FOOT_H
	st.sorter_vis = max(1, int((body_h - 36) / (st.thumb_w * 9 / 16 + 18)))
	sorter_follow(st)

	collabui.band(ui, &collab.ui)
	top_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 items-stretch")
	sorter(ui, st)
	p.col(ui, "flex-1 min-w-0 h-full")
	canvas_pane(ui, st)
	if st.show_notes {
		notes_pane(ui, st)
	}
	p.end(ui)
	if collab.on && collab.ui.panel != .None {
		collab_panel(ui, st)
	} else {
		inspector(ui, st)
	}
	p.end(ui)

	status_bar(ui, st)

	if st.mode == .Menu {
		menu_overlay(ui, st)
	}
	if st.mode == .Help {
		help_overlay(ui, st)
	}
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

@(private = "file")
top_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[44] shrink-0 items-center gap-3 px-3 border-b border-border bg-card")
	defer p.end(ui)

	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-md bg-[#6366f1]")
	p.icon(ui, IC_PRESENTATION, "size-4 text-white")
	p.end(ui)

	p.col(ui, "min-w-0 gap-0")
	p.row(ui, "items-center gap-1.5")
	p.text(ui, st.deck.title, "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	if st.dirty {
		p.div(ui, "size-1.5 rounded-full bg-[#f59e0b]")
		p.end(ui)
	}
	p.end(ui)
	p.textf(
		ui,
		"text-[10] text-muted-foreground whitespace-nowrap",
		"%s · %s · %d slides",
		LAYOUT_NAMES[cur_slide(st).layout],
		st.deck.theme.name,
		len(st.deck.slides),
	)
	p.end(ui)

	collabui.chip(ui, &collab.ui)
	p.spacer(ui)

	if collab.on {
		collabui.presence(ui, &collab.ui)
		if collabui.share_button(ui, &collab.ui) {
			collab.ui.panel = collab.ui.panel == .Share ? .None : .Share
			if collab.ui.panel == .Share {collabui.load_people(&collab.ui)}
		}
	}

	p.row(ui, "shrink-0 items-center gap-2")
	if !st.snap {
		sc.badge(ui, "No snap", .Outline)
	}
	switch st.mode {
	case .Text:
		sc.badge(ui, "Editing text", .Default)
	case .Notes:
		sc.badge(ui, "Editing notes", .Default)
	case .Menu, .Help, .Browse:
	}
	p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "Slide %d of %d", st.slide + 1, len(st.deck.slides))
	p.style(ui).shrink = 0
	sc.kbd(ui, "F5")
	p.text(ui, "present", "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Ctrl K")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The sorter
// ---------------------------------------------------------------------------

sorter_follow :: proc(st: ^St) {
	if st.slide < st.sorter_top {
		st.sorter_top = st.slide
	}
	if st.slide >= st.sorter_top + st.sorter_vis {
		st.sorter_top = st.slide - st.sorter_vis + 1
	}
	st.sorter_top = clamp(st.sorter_top, 0, max(0, len(st.deck.slides) - st.sorter_vis))
}

@(private = "file")
sorter :: proc(ui: ^p.Ctx, st: ^St) {
	col := p.col(ui, "h-full shrink-0 border-r border-border bg-card overflow-hidden")
	p.style(ui, col).w = p.px(st.sorter_w)
	defer p.end(ui)

	p.row(ui, "w-full h-9 shrink-0 items-center justify-between px-3")
	p.text(ui, "SLIDES", "text-[10] font-semibold tracking-wider text-muted-foreground")
	p.textf(ui, "text-[10] text-muted-foreground", "%d", len(st.deck.slides))
	p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 px-2 gap-1 overflow-hidden")
	last := min(st.sorter_top + st.sorter_vis, len(st.deck.slides))
	for i in st.sorter_top ..< last {
		p.key(ui, tprintf("slide-%d", i))
		// The thumbnail contexts are indexed by row, not by slide, so a deck
		// longer than the array still draws every visible thumbnail.
		row := i - st.sorter_top
		if row < MAX_THUMBS {
			st.thumbs[row] = {st, i}
		}
		sorter_row(ui, st, i, row)
	}
	p.end(ui)
}

@(private = "file")
sorter_row :: proc(ui: ^p.Ctx, st: ^St, i: int, row: int) {
	on := i == st.slide
	idx := p.div(ui, "flex-row w-full shrink-0 items-center gap-2 p-1 rounded-lg transition")
	p.apply(ui, on ? "bg-accent" : "hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		goto_slide(st, i)
	}
	defer p.end(ui)

	p.textf(ui, on ? "w-4 shrink-0 text-[10] font-semibold text-center" : "w-4 shrink-0 text-[10] text-muted-foreground text-center", "%d", i + 1)

	// The thumbnail is the real renderer at 150 pixels wide.
	frame := p.div(ui, "shrink-0 rounded-md overflow-hidden border")
	fs := p.style(ui, frame)
	fs.w = p.px(st.thumb_w)
	fs.h = p.px(st.thumb_w * 9 / 16)
	p.apply(ui, on ? "border-ring" : "border-border", frame)
	if row < MAX_THUMBS {
		p.pixels(ui, "w-full h-full", &st.thumbs[row], thumb_draw)
	}
	p.end(ui)
}

thumb_draw :: proc(c: ^p.Canvas, r: p.Rect, t: ^Thumb) {
	st := t.st
	if t.i >= len(st.deck.slides) {
		return
	}
	// Keep the 16:9 aspect whatever the row gave us.
	h := min(r.h, r.w * 9 / 16)
	w := h * 16 / 9
	box := p.Rect{r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
	draw_slide(
		c,
		box,
		&st.deck,
		t.i,
		{fonts = st.fonts, imgs = &st.imgs, thumb = true, selected = -1, footer = st.footer},
	)
}

// ---------------------------------------------------------------------------
// The canvas
// ---------------------------------------------------------------------------

@(private = "file")
canvas_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.div(ui, "w-full flex-1 min-h-0 bg-workspace overflow-hidden")
	p.pixels(ui, "w-full h-full", st, canvas_draw)
	p.end(ui)
}

canvas_draw :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	// A workspace, not a window: a slightly darker field than any panel, with
	// a dotted grid so the slide reads as a sheet lying on something.
	p.fill_rect(c, r, p.hex(0x06060a))
	step := 24 * c.scale
	dot := p.hexa(0xffffff1c)
	for y := r.y + step; y < r.y + r.h; y += step {
		for x := r.x + step; x < r.x + r.w; x += step {
			p.fill_rect(c, {math.floor(x), math.floor(y), max(1, c.scale), max(1, c.scale)}, dot)
		}
	}

	pad := 26 * c.scale
	avail := p.Rect{r.x + pad, r.y + pad, max(40, r.w - 2 * pad), max(40, r.h - 2 * pad)}
	w := avail.w
	h := w * SLIDE_H / SLIDE_W
	if h > avail.h {
		h = avail.h
		w = h * SLIDE_W / SLIDE_H
	}
	slide := p.Rect{avail.x + (avail.w - w) / 2, avail.y + (avail.h - h) / 2, w, h}

	// Remember where the slide landed, in logical pixels, so the pointer can
	// be mapped back into slide coordinates next frame.
	st.canvas = {slide.x / c.scale, slide.y / c.scale, slide.w / c.scale, slide.h / c.scale}
	st.canvas_sc = st.canvas.w / SLIDE_W

	p.drop_shadow(c, slide, {2, 2, 2, 2}, 36 * c.scale, 2 * c.scale, {0, 10 * c.scale}, p.hexa(0x00000099))

	blink := st.mode == .Text
	on := !blink || caret_lit
	draw_slide(
		c,
		slide,
		&st.deck,
		st.slide,
		{
			fonts = st.fonts,
			imgs = &st.imgs,
			chrome = true,
			selected = st.sel,
			editing = st.mode == .Text,
			caret = st.ed.caret,
			caret_on = on,
			guides = st.guides[:],
			footer = st.footer,
			number = st.slide + 1,
			total = len(st.deck.slides),
		},
	)
	if collab.on {
		draw_peer_marks(c, slide, st)
	}
	// A hairline so a white slide still has an edge against the workspace.
	p.stroke_round_rect(c, p.rect_inset(slide, -0.5), {2, 2, 2, 2}, max(1, c.scale), p.hexa(0xffffff1c))
}

// caret_lit is whether the blinking caret is lit this frame. The canvas draw
// callback has no Ctx, so it is decided when the editor builds the frame.
@(private = "file")
caret_lit: bool

// pres_clock is the presenter view's elapsed-time reading, for the same
// reason: the projector draws on a canvas with no Ctx.
@(private = "file")
pres_clock: f64

// ---------------------------------------------------------------------------
// Notes
// ---------------------------------------------------------------------------

@(private = "file")
notes_pane :: proc(ui: ^p.Ctx, st: ^St) {
	s := cur_slide(st)
	editing := st.mode == .Notes
	p.col(ui, "w-full h-[132] shrink-0 border-t border-border bg-card px-4 py-2.5 gap-1.5")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, sc.ICON_FILE_TEXT, "size-3.5 text-muted-foreground")
	p.text(ui, "SPEAKER NOTES", "text-[10] font-semibold tracking-wider text-muted-foreground")
	p.spacer(ui)
	if editing {
		sc.badge(ui, "Esc to finish", .Secondary)
	} else {
		sc.kbd(ui, "N")
		p.text(ui, "edit", "text-[10] text-muted-foreground")
	}
	p.end(ui)

	text := editing ? notes_with_caret(st) : s.notes
	if strings.trim_space(text) == "" {
		p.text(ui, "No notes on this slide.", "text-xs text-muted-foreground")
	} else {
		p.text(ui, text, "w-full text-xs leading-5 text-foreground/90")
	}
}

// notes_with_caret puts a visible insertion bar in the string. The notes pane
// is a wrapped paragraph laid out by palmy, so there is no measured caret to
// place; an inserted bar is honest and reads correctly at any wrap point.
@(private = "file")
notes_with_caret :: proc(st: ^St) -> string {
	t := ed_text(st)
	at := clamp(st.ed.caret, 0, len(t))
	if !caret_lit {
		return t
	}
	return strings.concatenate({t[:at], "|", t[at:]}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// The inspector
// ---------------------------------------------------------------------------

@(private = "file")
inspector :: proc(ui: ^p.Ctx, st: ^St) {
	col := p.col(ui, "h-full shrink-0 border-l border-border bg-card overflow-hidden")
	p.style(ui, col).w = p.px(st.inspect_w)
	defer p.end(ui)

	e := cur_elem(st)

	p.row(ui, "w-full h-9 shrink-0 items-center justify-between px-3")
	p.text(ui, e != nil ? "ELEMENT" : "SLIDE", "text-[10] font-semibold tracking-wider text-muted-foreground")
	if e != nil {
		sc.badge(ui, KIND_NAMES[e.kind], .Secondary)
	} else {
		sc.badge(ui, LAYOUT_NAMES[cur_slide(st).layout], .Secondary)
	}
	p.end(ui)
	sc.separator(ui)

	if e == nil {
		slide_inspector(ui, st)
		return
	}

	// Geometry.
	p.col(ui, "w-full shrink-0 px-3 py-2.5 gap-1.5")
	p.row(ui, "w-full gap-1.5")
	num_field(ui, "X", e.x)
	num_field(ui, "Y", e.y)
	p.end(ui)
	p.row(ui, "w-full gap-1.5")
	num_field(ui, "W", e.w)
	num_field(ui, "H", e.h)
	p.end(ui)
	p.end(ui)
	sc.separator(ui)

	// The adjustable properties. The active row is what +/- act on.
	p.col(ui, "w-full flex-1 min-h-0 px-2 py-2 gap-0.5 overflow-hidden")
	for pr in Prop {
		if !prop_applies(pr, e) {
			continue
		}
		p.key(ui, PROP_NAMES[pr])
		row := p.div(ui, "flex-row w-full shrink-0 h-7 items-center gap-2 px-2 rounded-md transition")
		p.apply(ui, pr == st.prop ? "bg-accent ring-1 ring-ring/70" : "hover:bg-muted", row)
		if p.clickable(ui, row) {
			st.prop = pr
		}
		p.text(ui, PROP_NAMES[pr], "flex-1 text-[11] text-muted-foreground whitespace-nowrap truncate")
		if pr == .Fill || pr == .Stroke {
			v := pr == .Stroke ? e.stroke : elem_colour(e)
			if has_paint(v) {
				p.div(ui, "size-3 shrink-0 rounded-sm ring-1 ring-white/20")
				p.style(ui).bg = p.flat(paint(&st.deck.theme, v))
				p.end(ui)
			}
		}
		p.text(ui, prop_value(st, pr, e), "shrink-0 text-[11] font-medium whitespace-nowrap")
		if pr == st.prop {
			p.row(ui, "shrink-0 items-center gap-0.5")
			sc.kbd(ui, "-")
			sc.kbd(ui, "+")
			p.end(ui)
		}
		p.end(ui)
	}

	p.spacer(ui)

	// Layers: paint order, top first, which is also the z-order model.
	s := cur_slide(st)
	p.col(ui, "w-full shrink-0 gap-0.5 pt-1")
	p.row(ui, "w-full items-center justify-between px-2 pb-1")
	p.text(ui, "LAYERS", "text-[10] font-semibold tracking-wider text-muted-foreground")
	p.textf(ui, "text-[10] text-muted-foreground", "%d of %d", st.sel + 1, len(s.elems))
	p.end(ui)
	// The list shows seven at a time, from the top of the stack down, and
	// follows the selection rather than hiding it.
	LAYER_ROWS :: 7
	top := len(s.elems) - 1
	if st.sel >= 0 && st.sel < top - (LAYER_ROWS - 1) {
		top = min(len(s.elems) - 1, st.sel + LAYER_ROWS - 1)
	}
	shown := 0
	for i := top; i >= 0 && shown < LAYER_ROWS; i -= 1 {
		el := &s.elems[i]
		p.key(ui, tprintf("layer-%d", i))
		row := p.div(ui, "flex-row w-full shrink-0 h-6 items-center gap-2 px-2 rounded-md")
		p.apply(ui, i == st.sel ? "bg-accent" : "hover:bg-muted", row)
		if p.clickable(ui, row) {
			st.sel = i
			st.mode = .Browse
		}
		p.icon(ui, kind_icon(el.kind), "size-3 shrink-0 text-muted-foreground")
		p.text(ui, elem_label(el), "flex-1 text-[11] whitespace-nowrap truncate")
		p.end(ui)
		shown += 1
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-1.5 px-2 py-2 border-t border-border")
	sc.kbd(ui, "[")
	sc.kbd(ui, "]")
	p.text(ui, "z-order", "text-[10] text-muted-foreground whitespace-nowrap")
	p.spacer(ui)
	sc.kbd(ui, ",")
	sc.kbd(ui, ".")
	p.text(ui, "property", "text-[10] text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)
}

// elem_colour is the paint the Fill row shows: a text box's ink, a line's
// stroke, a shape's fill.
elem_colour :: proc(e: ^Element) -> u32 {
	switch e.kind {
	case .Text:
		return e.color
	case .Line, .Arrow:
		return e.stroke
	case .Rect, .Ellipse, .Image:
		return e.fill
	}
	return e.fill
}

prop_applies :: proc(pr: Prop, e: ^Element) -> bool {
	text := e.kind == .Text
	line := e.kind == .Line || e.kind == .Arrow
	switch pr {
	case .Style, .Size, .Align, .Valign:
		return text
	case .Fill_Alpha:
		return !text && !line && has_paint(e.fill)
	case .Radius:
		return e.kind == .Rect || e.kind == .Image || text
	case .Stroke:
		return !line // a line's colour is on the Fill row, where a user looks
	case .Stroke_Width:
		return e.kind != .Text || has_paint(e.stroke)
	case .Fill, .Opacity, .Rotation:
		return true
	}
	return true
}

@(private = "file")
num_field :: proc(ui: ^p.Ctx, label: string, v: f32) {
	p.row(ui, "flex-1 h-7 items-center gap-1.5 px-2 rounded-md border border-input bg-background")
	defer p.end(ui)
	p.text(ui, label, "text-[10] font-semibold text-muted-foreground")
	p.spacer(ui)
	p.textf(ui, "text-[11] font-medium font-mono whitespace-nowrap", "%.0f", v)
}

@(private = "file")
slide_inspector :: proc(ui: ^p.Ctx, st: ^St) {
	s := cur_slide(st)
	p.col(ui, "w-full flex-1 min-h-0 px-3 py-3 gap-3 overflow-hidden")
	defer p.end(ui)

	p.col(ui, "w-full gap-1")
	p.text(ui, "LAYOUT", "text-[10] font-semibold tracking-wider text-muted-foreground")
	for l in Layout {
		p.key(ui, LAYOUT_NAMES[l])
		row := p.div(ui, "flex-row w-full shrink-0 h-7 items-center gap-2 px-2 rounded-md transition")
		p.apply(ui, l == s.layout ? "bg-accent" : "hover:bg-muted", row)
		if p.clickable(ui, row) {
			apply_layout(&st.deck, st.slide, l)
			st.dirty = true
		}
		p.text(ui, LAYOUT_NAMES[l], "flex-1 text-[11] whitespace-nowrap")
		sc.kbd(ui, tprintf("%d", int(l) + 1))
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "w-full gap-1")
	p.text(ui, "THEME", "text-[10] font-semibold tracking-wider text-muted-foreground")
	for t, i in THEMES {
		p.key(ui, t.name)
		row := p.div(ui, "flex-row w-full shrink-0 h-7 items-center gap-2 px-2 rounded-md transition")
		p.apply(ui, t.name == st.deck.theme.name ? "bg-accent" : "hover:bg-muted", row)
		if p.clickable(ui, row) {
			st.deck.theme = THEMES[i]
			st.dirty = true
		}
		for swatch in ([?]u32{t.bg, t.accent, t.accent2, t.fg}) {
			p.div(ui, "size-3 shrink-0 rounded-sm ring-1 ring-white/15")
			p.style(ui).bg = p.flat(argb(swatch))
			p.end(ui)
		}
		p.text(ui, t.name, "flex-1 text-[11] whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "w-full gap-1.5")
	p.text(ui, "DECK", "text-[10] font-semibold tracking-wider text-muted-foreground")
	kv(ui, "Slides", tprintf("%d", len(st.deck.slides)))
	kv(ui, "Elements here", tprintf("%d", len(s.elems)))
	kv(ui, "Notes", tprintf("%d chars", len(s.notes)))
	kv(ui, "Snapping", st.snap ? "on" : "off")
	kv(ui, "File", short_path(st.path))
	p.end(ui)

	p.spacer(ui)
	p.row(ui, "w-full items-center gap-1.5")
	sc.kbd(ui, "Tab")
	p.text(ui, "select an element", "text-[10] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

@(private = "file")
kv :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "w-full items-center gap-2")
	defer p.end(ui)
	p.text(ui, k, "text-[11] text-muted-foreground whitespace-nowrap")
	p.spacer(ui)
	p.text(ui, v, "text-[11] font-medium whitespace-nowrap truncate")
}

short_path :: proc(path: string) -> string {
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		return path[slash + 1:]
	}
	return path
}

elem_label :: proc(e: ^Element) -> string {
	if e.kind == .Text {
		t := strings.trim_space(e.text)
		if t == "" {
			return "Empty text"
		}
		if nl := strings.index_byte(t, '\n'); nl > 0 {
			t = t[:nl]
		}
		if len(t) > 22 {
			return tprintf("%s…", t[:22])
		}
		return t
	}
	if e.kind == .Image {
		return short_path(e.src)
	}
	return KIND_NAMES[e.kind]
}

kind_icon :: proc(k: Kind) -> p.Icon {
	switch k {
	case .Text:
		return IC_TYPE
	case .Rect:
		return IC_SQUARE
	case .Ellipse:
		return IC_CIRCLE
	case .Line:
		return IC_SLASH
	case .Arrow:
		return sc.ICON_ARROW_RIGHT
	case .Image:
		return sc.ICON_IMAGE
	}
	return IC_SQUARE
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

@(private = "file")
status_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-3 border-t border-border bg-card")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, sc.ICON_INFO, "size-3.5 shrink-0 text-[#6366f1]")
		p.text(ui, st.toast, "flex-1 text-[11] whitespace-nowrap truncate")
		return
	}

	switch st.mode {
	case .Text:
		hint(ui, "Esc", "", "finish")
		hint(ui, "Enter", "", "new line")
		hint(ui, "Ctrl", "U", "clear line")
		p.spacer(ui)
		p.text(ui, "typing into the slide", "text-[10] text-muted-foreground whitespace-nowrap")
	case .Notes:
		hint(ui, "Esc", "", "finish")
		hint(ui, "Enter", "", "new line")
		p.spacer(ui)
		p.text(ui, "speaker notes", "text-[10] text-muted-foreground whitespace-nowrap")
	case .Menu, .Help:
		hint(ui, "Up", "Down", "move")
		hint(ui, "Enter", "", "run")
		hint(ui, "Esc", "", "close")
	case .Browse:
		if st.sel >= 0 {
			hint(ui, "Arrows", "", "move")
			hint(ui, "Ctrl", "Shift", "resize")
			hint(ui, "Enter", "", "edit text")
			hint(ui, "D", "", "duplicate")
			hint(ui, "X", "", "delete")
			hint(ui, "U", "", "undo")
		} else {
			hint(ui, "J", "K", "slide")
			hint(ui, "Tab", "", "select")
			hint(ui, "T", "R", "add text or shape")
			hint(ui, "1", "6", "layout")
		}
		p.spacer(ui)
		hint(ui, "?", "", "keys")
		hint(ui, "Ctrl", "S", "save")
	}
}

@(private = "file")
hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// The command menu, drawn in the window because there is no xdg_popup
// ---------------------------------------------------------------------------

MENU_W :: 540

@(private = "file")
menu_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	p.div(ui, "absolute inset-0 bg-background/60 z-40")
	p.end(ui)

	// No xdg_popup, so the menu is a panel inside the window. The table is
	// longer than a window is tall, so it runs in two columns, split at a
	// section boundary rather than mid group.
	split := menu_split()

	panel := p.div(ui, "absolute flex-row rounded-xl border border-border bg-popover shadow-2xl z-50 overflow-hidden p-2 gap-2")
	ps := p.style(ui, panel)
	ps.inset[p.LEFT] = p.px(st.sorter_w + 20)
	ps.inset[p.TOP] = p.px(TOP_H + 14)
	ps.w = p.px(min(MENU_W, p.size(ui).x - st.sorter_w - 40))
	ps.max_h = p.px(max(200, p.size(ui).y - TOP_H - FOOT_H - 24))
	defer p.end(ui)

	for col in 0 ..< 2 {
		lo := col == 0 ? 0 : split
		hi := col == 0 ? split : len(MENU)
		p.col(ui, "flex-1 min-w-0 gap-px")
		for i in lo ..< hi {
			m := MENU[i]
			if m.head {
				p.row(ui, "w-full h-[20] shrink-0 items-center px-2")
				p.text(ui, m.label, "text-[10] font-semibold tracking-wider text-muted-foreground")
				p.end(ui)
				continue
			}
			on := i == st.menu_i
			row := p.div(ui, "flex-row w-full h-[22] shrink-0 items-center gap-2 px-2 rounded-md")
			p.apply(ui, on ? "bg-accent" : "hover:bg-muted", row)
			if p.clickable(ui, row) {
				st.mode = .Browse
				invoke(st, ui, ui.app, m.cmd)
			}
			if st.moved && p.is_hovered(ui, row) {
				st.menu_i = i
			}
			p.text(ui, m.label, on ? "flex-1 text-[11] font-medium whitespace-nowrap truncate" : "flex-1 text-[11] whitespace-nowrap truncate")
			if m.keys != "" {
				p.text(ui, m.keys, "shrink-0 text-[10] font-mono text-muted-foreground whitespace-nowrap")
			}
			p.end(ui)
		}
		p.end(ui)
	}
}

// menu_split picks the heading nearest the middle of the table.
menu_split :: proc() -> int {
	best, best_d := len(MENU) / 2, len(MENU)
	for m, i in MENU {
		if !m.head {
			continue
		}
		d := abs(i - len(MENU) / 2)
		if d < best_d {
			best, best_d = i, d
		}
	}
	return best
}

// ---------------------------------------------------------------------------
// The cheatsheet
// ---------------------------------------------------------------------------

@(private = "file")
help_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	p.div(ui, "absolute inset-0 bg-background/75 z-40")
	p.end(ui)

	p.div(ui, "absolute inset-0 flex-row items-center justify-center z-50")
	p.col(ui, "w-[760] max-w-full max-h-full rounded-xl border border-border bg-popover shadow-2xl p-5 gap-3")

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_KEYBOARD, "size-4 text-muted-foreground")
	p.text(ui, "Keyboard", "text-sm font-semibold")
	p.spacer(ui)
	p.text(ui, "any key closes", "text-[10] text-muted-foreground")
	p.end(ui)
	sc.separator(ui)

	split := menu_split()
	p.row(ui, "w-full gap-6 items-start")
	for col in 0 ..< 2 {
		lo := col == 0 ? 0 : split
		hi := col == 0 ? split : len(MENU)
		p.col(ui, "flex-1 gap-0.5")
		for i in lo ..< hi {
			m := MENU[i]
			if m.head {
				p.row(ui, "w-full h-5 items-center pt-1.5")
				p.text(ui, m.label, "text-[10] font-semibold tracking-wider text-muted-foreground")
				p.end(ui)
				continue
			}
			p.row(ui, "w-full h-5 items-center gap-2")
			p.text(ui, m.label, "flex-1 text-[11] whitespace-nowrap truncate")
			p.text(ui, m.keys, "shrink-0 text-[10] font-mono text-muted-foreground whitespace-nowrap")
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	sc.separator(ui)
	p.text(
		ui,
		"Arrows move the selected element · Ctrl+arrows nudge by one · Ctrl+Shift+arrows resize · , and . pick the inspector row · - and + change it · F2 opens the command menu",
		"w-full text-[11] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The projector
// ---------------------------------------------------------------------------

build_present :: proc(ui: ^p.Ctx, st: ^St) {
	// The audience view is drawn once per slide and then the loop sleeps. The
	// presenter view has a running mm:ss clock on it, which changes once a
	// second, so it asks for exactly that: one wake at the next whole second
	// on a real clock, rather than every frame at the display rate.
	pres_clock = now_s(ui)
	if st.pres_notes && !st.pres_black {
		el := max(0, pres_clock - st.pres_start)
		p.wake_after(ui, secs(math.floor(el) + 1 - el) + 2 * time.Millisecond)
	}
	p.pixels(ui, "w-full h-full", st, present_draw)
}

present_draw :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	p.fill_rect(c, r, p.BLACK)
	if st.pres_black {
		return
	}
	if st.pres_notes {
		present_notes(c, r, st)
		return
	}

	// Full bleed, letterboxed, with a sliver of margin so a compositor that
	// trims an edge does not trim a title.
	box := fit_16_9(p.rect_inset(r, 10 * c.scale))
	draw_slide(
		c,
		box,
		&st.deck,
		st.slide,
		{
			fonts = st.fonts,
			imgs = &st.imgs,
			footer = true,
			number = st.slide + 1,
			total = len(st.deck.slides),
			selected = -1,
		},
	)

	// The counter and a progress rule, drawn over the slide the way a
	// projector's own chrome would be.
	label := tprintf("%d / %d", st.slide + 1, len(st.deck.slides))
	size := 13 * c.scale
	w := p.text_width(st.fonts, label, size, .Sans, .Medium)
	pad := 10 * c.scale
	pill := p.Rect{p.rect_right(r) - w - 3 * pad, p.rect_bottom(r) - 2.2 * pad - size, w + 2 * pad, size + pad}
	p.fill_round_rect(c, pill, {pill.h / 2, pill.h / 2, pill.h / 2, pill.h / 2}, p.hexa(0x000000aa))
	p.draw_text(c, st.fonts, label, pill.x + pad, pill.y + pill.h / 2 + size * 0.36, size, p.hexa(0xffffffcc), .Sans, .Medium)

	if len(st.deck.slides) > 1 {
		frac := f32(st.slide + 1) / f32(len(st.deck.slides))
		p.fill_rect(c, {r.x, p.rect_bottom(r) - 3 * c.scale, r.w * frac, 3 * c.scale}, argb(st.deck.theme.accent))
	}
}

@(private = "file")
fit_16_9 :: proc(r: p.Rect) -> p.Rect {
	w := r.w
	h := w * SLIDE_H / SLIDE_W
	if h > r.h {
		h = r.h
		w = h * SLIDE_W / SLIDE_H
	}
	return {r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
}

// present_notes is the presenter view: the slide now, the slide next, the
// clock and the notes — on the one output this machine has, so it replaces the
// audience view rather than sitting beside it.
@(private = "file")
present_notes :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	s := c.scale
	p.fill_rect(c, r, p.hex(0x09090b))
	gap := 18 * s
	left_w := r.w * 0.62

	cur := fit_16_9({r.x + gap, r.y + gap, left_w - gap, r.h - 2 * gap})
	p.drop_shadow(c, cur, {4, 4, 4, 4}, 30 * s, 0, {0, 8 * s}, p.hexa(0x000000aa))
	draw_slide(
		c,
		cur,
		&st.deck,
		st.slide,
		{fonts = st.fonts, imgs = &st.imgs, footer = true, number = st.slide + 1, total = len(st.deck.slides), selected = -1},
	)

	rx := r.x + left_w + gap / 2
	rw := r.w - left_w - 1.5 * gap

	// Next slide.
	label_size := 12 * s
	p.draw_text(c, st.fonts, "NEXT", rx, r.y + gap + label_size, label_size, p.hexa(0xffffff66), .Sans, .Semibold)
	next := p.Rect{rx, r.y + gap + label_size * 1.8, rw, rw * SLIDE_H / SLIDE_W}
	if st.slide + 1 < len(st.deck.slides) {
		draw_slide(
			c,
			next,
			&st.deck,
			st.slide + 1,
			{fonts = st.fonts, imgs = &st.imgs, thumb = true, selected = -1},
		)
		p.stroke_round_rect(c, next, {2, 2, 2, 2}, max(1, s), p.hexa(0xffffff22))
	} else {
		p.fill_round_rect(c, next, {4, 4, 4, 4}, p.hexa(0xffffff0c))
		t := "End of deck"
		tw := p.text_width(st.fonts, t, 14 * s, .Sans, .Regular)
		p.draw_text(c, st.fonts, t, next.x + (next.w - tw) / 2, next.y + next.h / 2, 14 * s, p.hexa(0xffffff66), .Sans, .Regular)
	}

	// Notes.
	ny := p.rect_bottom(next) + gap
	p.draw_text(c, st.fonts, "NOTES", rx, ny + label_size, label_size, p.hexa(0xffffff66), .Sans, .Semibold)
	notes := st.deck.slides[st.slide].notes
	if strings.trim_space(notes) == "" {
		notes = "No notes on this slide."
	}
	draw_paragraph(
		c,
		st.fonts,
		notes,
		{rx, ny + label_size * 2, rw, p.rect_bottom(r) - (ny + label_size * 2) - gap},
		15 * s,
		p.hexa(0xffffffcc),
	)

	// Slide counter and the elapsed time, which is the other half of why a
	// presenter view exists.
	sec := int(max(0, pres_clock - st.pres_start))
	counter := tprintf("%d / %d     %02d:%02d", st.slide + 1, len(st.deck.slides), sec / 60, sec % 60)
	p.draw_text(c, st.fonts, counter, r.x + gap, p.rect_bottom(r) - gap * 0.6, 14 * s, p.hexa(0xffffff88), .Sans, .Medium)
	hintt := "Space advances · Tab leaves the presenter view · Escape exits"
	hw := p.text_width(st.fonts, hintt, 12 * s, .Sans, .Regular)
	p.draw_text(c, st.fonts, hintt, p.rect_right(r) - gap - hw, p.rect_bottom(r) - gap * 0.6, 12 * s, p.hexa(0xffffff55), .Sans, .Regular)
}

// draw_paragraph is wrapped text straight onto the canvas, which the projector
// needs because it draws no UI tree at all.
draw_paragraph :: proc(c: ^p.Canvas, fonts: ^p.Fonts, text: string, box: p.Rect, size: f32, col: p.Color) {
	lines := wrap_text(fonts, text, size, .Regular, 0, box.w, false)
	m := p.font_metrics(fonts, size, .Sans, .Regular)
	y := box.y + m.ascent
	for l in lines {
		if y > p.rect_bottom(box) {
			break
		}
		p.draw_text(c, fonts, text[l.start:l.end], box.x, y, size, col, .Sans, .Regular)
		y += size * 1.45
	}
}
