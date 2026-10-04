package main

// The chrome: top bar, tool options, tool palette, layers panel, status bar.
//
// shadcn supplies the widgets. Its components are presentational — they take an
// explicit `State{hover, focus, disabled}` and draw it — so the pointer half of
// each control lives here. Two helpers carry that weight: `icon_button`, which
// re-applies shadcn's own hover class to the node after creating it (palmy lays
// out and paints after the whole tree is built, so an element can still be
// restyled once its hover state is known), and `slider_row`, which reads the
// previous frame's track rectangle out of palmy's geometry store to turn a
// shadcn slider into a draggable one.

import "core:fmt"
import p "palmy:."
import sc "shadcn:."

build_ui :: proc(ui: ^p.Ctx, st: ^St) {
	top_bar(ui, st)
	options_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		tool_palette(ui, st)

		p.col(ui, "flex-1 min-w-0 min-h-0 overflow-hidden relative bg-[#18181b]")
		{
			idx := p.pixels(ui, "w-full flex-1 min-h-0", st, draw_canvas)
			p.apply(ui, canvas_cursor(st.tool), idx)
			st.view = p.rect_of(ui, p.node_id(ui, idx))
			if st.want_fit && st.view.w > 8 {
				do_fit(st)
			}
			p.clickable(ui, idx)
			if st.ov == .None {
				canvas_input(ui, st, idx)
			} else {
				st.over_canvas = false
			}
			zoom_pill(ui, st)
			if st.toast_len > 0 {
				toast_pill(ui, st)
			}
		}
		p.end(ui)

		right_panel(ui, st)
	}
	p.end(ui)

	status_bar(ui, st)

	if st.ov != .None {
		build_overlay(ui, st)
	}
}

canvas_cursor :: proc(t: Tool) -> string {
	switch t {
	case .Pan:
		return "cursor-grab"
	case .Brush, .Eraser, .Fill, .Eyedropper, .Select:
		return "cursor-crosshair"
	case .Move:
		return "cursor-move"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Shared widget helpers
// ---------------------------------------------------------------------------

// icon_button is a shadcn icon button wired to the pointer. The hover class is
// applied *after* the node exists, which is exact: predicting the next node's
// id a line early reports "hovered" for every button whenever the pointer is
// over nothing at all.
icon_button :: proc(
	ui: ^p.Ctx,
	ic: p.Icon,
	variant := sc.Variant.Ghost,
	size := sc.Size.Icon_SM,
	disabled := false,
	on := false,
) -> bool {
	idx := sc.button_open(ui, variant, size, sc.State{disabled = disabled})
	p.icon(ui, ic, "size-4 shrink-0")
	sc.button_end(ui)
	if disabled {
		return false
	}
	if on {
		p.apply(ui, "bg-primary text-primary-foreground", idx)
	}
	if p.is_hovered(ui, idx) {
		p.apply(ui, sc.button_variant_class(variant, sc.State{hover = true}), idx)
		if on {
			p.apply(ui, "bg-primary/80 text-primary-foreground", idx)
		}
	}
	return p.clickable(ui, idx)
}

text_button :: proc(
	ui: ^p.Ctx,
	label: string,
	variant := sc.Variant.Outline,
	size := sc.Size.SM,
	disabled := false,
) -> bool {
	idx := sc.button_open(ui, variant, size, sc.State{disabled = disabled})
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.button_end(ui)
	if disabled {
		return false
	}
	if p.is_hovered(ui, idx) {
		p.apply(ui, sc.button_variant_class(variant, sc.State{hover = true}), idx)
	}
	return p.clickable(ui, idx)
}

// slider_row is shadcn's slider made draggable. The track geometry comes from
// `rect_of`, which is where palmy keeps the previous frame's layout for hit
// testing — the same numbers the pointer was tested against, so the value the
// drag computes matches the pixel the user pressed.
slider_row :: proc(
	ui: ^p.Ctx,
	label: string,
	readout: string,
	value: ^f32,
	lo, hi: f32,
	width := "w-[104]",
	row_class := "shrink-0",
) -> bool {
	changed := false
	p.row(ui, p.concat(ui, "items-center gap-2 ", row_class))
	defer p.end(ui)

	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	track := p.div(ui, p.concat(ui, width, " h-6 min-w-0 justify-center cursor-pointer"))
	{
		r := p.rect_of(ui, p.node_id(ui, track))
		if p.is_active(ui, track) && r.w > 4 {
			t := clamp((p.mouse_pos(ui).x - r.x) / r.w, 0, 1)
			nv := lo + t * (hi - lo)
			if nv != value^ {
				value^ = nv
				changed = true
			}
		}
		p.clickable(ui, track)
		norm := hi > lo ? clamp((value^ - lo) / (hi - lo), 0, 1) : 0
		sc.slider(ui, {norm})
	}
	p.end(ui)

	p.text(ui, readout, "text-[11] font-mono text-foreground w-[46] text-center whitespace-nowrap")
	p.style(ui).shrink = 0
	return changed
}

// swatch draws a colour chip over a checkerboard, so a colour with alpha reads
// honestly rather than as a dark version of itself.
swatch :: proc(ui: ^p.Ctx, v: u32, class: string) -> int {
	idx := p.div(ui, class)
	p.style(ui, idx).bg = p.flat(swatch_color(v))
	p.end(ui)
	return idx
}

swatch_color :: proc(v: u32) -> p.Color {
	r, g, b, a := unpack_argb(v)
	return {r, g, b, a}
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

top_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[44] shrink-0 items-center gap-2 px-3 border-b border-border bg-card")
	defer p.end(ui)

	p.icon(ui, IC_LAYERS, "size-4 text-primary shrink-0")
	p.text(ui, "Photoshop", "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0

	sc.separator(ui, .Vertical, "h-5 mx-1")

	name := st.doc.path == "" ? "untitled" : base_of(st.doc.path)
	p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "%s%s", name, st.doc.saved ? "" : " *")
	p.style(ui).shrink = 0
	sc.badge(ui, fmt.tprintf("%d x %d", st.doc.w, st.doc.h), .Secondary)

	p.spacer(ui)

	if icon_button(ui, IC_UNDO_2, .Ghost, .Icon_SM, !hist_can_undo(&st.hist)) {
		if label, ok := hist_undo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("undo %s", label))
		}
	}
	if icon_button(ui, IC_REDO_2, .Ghost, .Icon_SM, !hist_can_redo(&st.hist)) {
		if label, ok := hist_redo(&st.hist, &st.doc); ok {
			toast(st, fmt.tprintf("redo %s", label))
		}
	}

	sc.separator(ui, .Vertical, "h-5 mx-1")

	if icon_button(ui, IC_ZOOM_OUT) {set_zoom(st, st.zoom / ZOOM_STEP)}
	p.textf(ui, "text-xs font-mono w-[52] text-center whitespace-nowrap", "%.0f%%", st.zoom * 100)
	p.style(ui).shrink = 0
	if icon_button(ui, IC_ZOOM_IN) {set_zoom(st, st.zoom * ZOOM_STEP)}
	if icon_button(ui, IC_MAXIMIZE) {do_fit(st)}

	sc.separator(ui, .Vertical, "h-5 mx-1")

	if icon_button(ui, IC_FILE_PLUS) {open_overlay(st, .New_Doc)}
	if icon_button(ui, IC_FOLDER_OPEN) {open_overlay(st, .Open)}
	if icon_button(ui, IC_SAVE) {
		if st.doc.path == "" {
			open_overlay(st, .Save_As)
		} else {
			save_to(st, st.doc.path)
		}
	}
	if icon_button(ui, IC_KEYBOARD) {open_overlay(st, .Help)}
}

// ---------------------------------------------------------------------------
// Options bar
// ---------------------------------------------------------------------------

options_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[38] shrink-0 items-center gap-3 px-3 border-b border-border bg-background")
	defer p.end(ui)

	p.icon(ui, tool_icon(st.tool), "size-3.5 text-muted-foreground shrink-0")
	p.text(ui, TOOL_NAMES[st.tool], "text-xs font-medium w-[78] whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-4")

	switch st.tool {
	case .Brush, .Eraser:
		slider_row(ui, "Size", fmt.tprintf("%.0f px", st.brush.size), &st.brush.size, BRUSH_MIN, BRUSH_MAX)
		hard := st.brush.hardness * 100
		if slider_row(ui, "Hardness", fmt.tprintf("%.0f%%", hard), &hard, 0, 100) {
			st.brush.hardness = hard / 100
		}
		op := st.brush.opacity * 100
		if slider_row(ui, "Opacity", fmt.tprintf("%.0f%%", op), &op, 1, 100) {
			st.brush.opacity = op / 100
		}
		p.spacer(ui)
		if st.kb_live {
			sc.badge(ui, "painting \u2014 arrows draw, Return lifts", .Default)
		} else {
			hint_keys(ui, "[", "]", "size")
			hint_keys(ui, "1", "0", "opacity")
			hint_keys(ui, "Return", "Arrows", "paint")
		}
	case .Fill:
		slider_row(ui, "Tolerance", fmt.tprintf("%.0f", st.brush.flow_tol), &st.brush.flow_tol, 0, 255)
		op := st.brush.opacity * 100
		if slider_row(ui, "Opacity", fmt.tprintf("%.0f%%", op), &op, 1, 100) {
			st.brush.opacity = op / 100
		}
		p.spacer(ui)
		p.text(
			ui,
			"4-connected scanline fill, max-channel tolerance",
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		hint_keys(ui, "Return", "", "fill at the cursor")
	case .Select:
		if st.has_sel {
			sc.badge(
				ui,
				fmt.tprintf(
					"%d, %d  %d x %d",
					st.sel.x0,
					st.sel.y0,
					st.sel.x1 - st.sel.x0,
					st.sel.y1 - st.sel.y0,
				),
				.Secondary,
			)
		} else {
			p.text(ui, "no selection", "text-[11] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.spacer(ui)
		if text_button(ui, "Select all") {select_all(st)}
		if text_button(ui, "Deselect", .Ghost) {deselect(st)}
		hint_keys(ui, "Return", "Arrows", st.kb_sel ? "sizing" : "drag from the keyboard")
	case .Move:
		p.text(
			ui,
			st.has_sel ? "moves the selected pixels" : "moves the whole active layer",
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.spacer(ui)
		hint_keys(ui, "Left", "Right", "nudge 1 px")
		hint_keys(ui, "Shift", "Up", "nudge 10 px")
	case .Eyedropper:
		p.text(
			ui,
			"samples the composite, not the active layer",
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.spacer(ui)
		p.text(ui, hex_string(st.pick_bg ? st.bg : st.fg, context.temp_allocator), "text-xs font-mono whitespace-nowrap")
		p.style(ui).shrink = 0
	case .Pan:
		p.text(
			ui,
			"drag to pan · hold Space from any tool · Ctrl-scroll zooms",
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.spacer(ui)
	}
}

hint_keys :: proc(ui: ^p.Ctx, a, b, label: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	sc.kbd(ui, a)
	if b != "" {
		sc.kbd(ui, b)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

tool_icon :: proc(t: Tool) -> p.Icon {
	switch t {
	case .Brush:
		return IC_BRUSH
	case .Eraser:
		return IC_ERASER
	case .Fill:
		return IC_PAINT_BUCKET
	case .Eyedropper:
		return IC_PIPETTE
	case .Select:
		return IC_SQUARE_DASHED
	case .Move:
		return IC_MOVE
	case .Pan:
		return IC_HAND
	}
	return IC_BRUSH
}

// ---------------------------------------------------------------------------
// Tool palette
// ---------------------------------------------------------------------------

tool_palette :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[56] h-full shrink-0 items-center gap-1 py-2 border-r border-border bg-card")
	defer p.end(ui)

	for t in Tool {
		p.key(ui, TOOL_NAMES[t])
		idx := p.div(
			ui,
			"size-9 shrink-0 flex-row items-center justify-center rounded-lg cursor-pointer transition relative",
		)
		on := st.tool == t
		p.apply(
			ui,
			on ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
			idx,
		)
		p.icon(ui, tool_icon(t), "size-[18] shrink-0")
		// The shortcut letter in the corner, as Photoshop's own palette does.
		p.text(ui, TOOL_KEYS[t], on ? "absolute text-[9] font-bold text-primary-foreground/80" : "absolute text-[9] font-bold text-muted-foreground/70")
		ks := p.style(ui)
		ks.position = .Absolute
		ks.inset[p.RIGHT] = p.px(2)
		ks.inset[p.BOTTOM] = p.px(0)
		p.end(ui)
		if p.clickable(ui, idx) {
			set_tool(st, t)
		}
	}

	sc.separator(ui, .Horizontal, "my-1 w-7")

	// The foreground / background colour pair.
	pair := p.div(ui, "size-9 shrink-0 relative cursor-pointer")
	{
		back := p.div(ui, "size-6 rounded-[3] border border-white/25 absolute")
		bs := p.style(ui, back)
		bs.inset[p.RIGHT] = p.px(0)
		bs.inset[p.BOTTOM] = p.px(0)
		bs.bg = p.flat(swatch_color(st.bg))
		p.end(ui)

		front := p.div(ui, "size-6 rounded-[3] border border-white/40 absolute")
		fs := p.style(ui, front)
		fs.inset[p.LEFT] = p.px(0)
		fs.inset[p.TOP] = p.px(0)
		fs.bg = p.flat(swatch_color(st.fg))
		p.end(ui)
	}
	p.end(ui)
	if p.clickable(ui, pair) {
		st.pick_bg = false
		sync_picker_from(st, st.fg)
		open_overlay(st, .Picker)
	}

	if icon_button(ui, IC_ARROW_LEFT_RIGHT, .Ghost, .Icon_XS) {
		st.fg, st.bg = st.bg, st.fg
		sync_picker_from(st, st.fg)
	}

	p.spacer(ui)

	if icon_button(ui, IC_SLIDERS_HORIZONTAL) {open_overlay(st, .Adjust_Menu)}
	if icon_button(ui, IC_SPARKLES) {open_overlay(st, .Filter_Menu)}
}

// ---------------------------------------------------------------------------
// Canvas overlays
// ---------------------------------------------------------------------------

zoom_pill :: proc(ui: ^p.Ctx, st: ^St) {
	idx := p.row(
		ui,
		"absolute items-center gap-2 rounded-lg bg-popover/90 px-2.5 py-1 ring-1 ring-foreground/10 z-20",
	)
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(12)
	s.inset[p.BOTTOM] = p.px(12)
	defer p.end(ui)

	p.textf(ui, "text-[11] font-mono text-popover-foreground whitespace-nowrap", "%.0f%%", st.zoom * 100)
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-3")
	if st.over_canvas {
		p.textf(
			ui,
			"text-[11] font-mono text-muted-foreground whitespace-nowrap",
			"%d, %d",
			int(st.cursor_doc.x),
			int(st.cursor_doc.y),
		)
	} else {
		p.text(ui, "—", "text-[11] font-mono text-muted-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if st.zoom > NEAREST_ABOVE {
		sc.separator(ui, .Vertical, "h-3")
		p.text(ui, "nearest", "text-[11] text-primary whitespace-nowrap")
		p.style(ui).shrink = 0
	}
}

toast_pill :: proc(ui: ^p.Ctx, st: ^St) {
	idx := p.row(
		ui,
		"absolute items-center gap-2 rounded-lg bg-popover px-3 py-1.5 shadow-md ring-1 ring-foreground/10 z-20",
	)
	s := p.style(ui, idx)
	s.inset[p.TOP] = p.px(12)
	s.inset[p.LEFT] = p.px(12)
	defer p.end(ui)
	p.icon(ui, IC_CHECK, "size-3 text-primary shrink-0")
	p.text(ui, toast_text(st), "text-[11] text-popover-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Right panel
// ---------------------------------------------------------------------------

right_panel :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[272] h-full shrink-0 border-l border-border bg-card overflow-hidden")
	defer p.end(ui)

	colour_section(ui, st)
	sc.separator(ui)
	layer_controls(ui, st)
	sc.separator(ui)
	layer_list(ui, st)
}

colour_section :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full shrink-0 gap-2 p-3")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	{
		p.icon(ui, IC_PALETTE, "size-3.5 text-muted-foreground shrink-0")
		p.text(ui, "Colour", "text-xs font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		p.text(ui, hex_string(st.fg, context.temp_allocator), "text-[11] font-mono text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if text_button(ui, "Pick", .Outline, .XS) {
			st.pick_bg = false
			sync_picker_from(st, st.fg)
			open_overlay(st, .Picker)
		}
	}
	p.end(ui)

	// Two chips: foreground and background, each clickable to edit.
	p.row(ui, "w-full items-center gap-2")
	{
		fgi := p.div(ui, "flex-1 h-8 rounded-md border border-white/20 cursor-pointer")
		p.style(ui, fgi).bg = p.flat(swatch_color(st.fg))
		p.end(ui)
		if p.clickable(ui, fgi) {
			st.pick_bg = false
			sync_picker_from(st, st.fg)
			open_overlay(st, .Picker)
		}
		bgi := p.div(ui, "flex-1 h-8 rounded-md border border-white/20 cursor-pointer")
		p.style(ui, bgi).bg = p.flat(swatch_color(st.bg))
		p.end(ui)
		if p.clickable(ui, bgi) {
			st.pick_bg = true
			sync_picker_from(st, st.bg)
			open_overlay(st, .Picker)
		}
	}
	p.end(ui)

	// The swatch row.
	p.row(ui, "w-full flex-wrap gap-1")
	{
		for v, i in SWATCHES {
			p.key(ui, fmt.tprintf("sw%d", i))
			idx := p.div(ui, "size-5 rounded-[3] border border-white/15 cursor-pointer hover:border-white/60 transition")
			p.style(ui, idx).bg = p.flat(swatch_color(v))
			p.end(ui)
			if p.clickable(ui, idx) {
				if st.pick_bg {
					st.bg = v
				} else {
					st.fg = v
				}
				sync_picker_from(st, v)
			}
		}
	}
	p.end(ui)
}

layer_controls :: proc(ui: ^p.Ctx, st: ^St) {
	d := &st.doc
	l := active_layer(d)
	p.col(ui, "w-full shrink-0 gap-2 p-3")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	{
		p.icon(ui, IC_LAYERS, "size-3.5 text-muted-foreground shrink-0")
		p.text(ui, "Layers", "text-xs font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		if icon_button(ui, IC_PLUS, .Ghost, .Icon_XS) {add_layer(st)}
		if icon_button(ui, IC_COPY, .Ghost, .Icon_XS) {duplicate_layer(st)}
		if icon_button(ui, IC_CHEVRON_UP, .Ghost, .Icon_XS, d.active >= len(d.order) - 1) {
			move_layer(st, 1)
		}
		if icon_button(ui, IC_CHEVRON_DOWN, .Ghost, .Icon_XS, d.active <= 0) {
			move_layer(st, -1)
		}
		if icon_button(ui, IC_TRASH, .Ghost, .Icon_XS, len(d.order) <= 1) {delete_layer(st)}
	}
	p.end(ui)

	if l == nil {
		return
	}

	// Blend mode, stepped through with the two chevrons or `,` and `.`.
	p.row(ui, "w-full items-center gap-2")
	{
		p.text(ui, "Blend", "text-[11] text-muted-foreground w-[44] whitespace-nowrap")
		p.style(ui).shrink = 0
		if icon_button(ui, IC_CHEVRON_DOWN, .Outline, .Icon_XS) {cycle_blend(st, -1)}
		box := p.div(ui, "flex-1 h-6 flex-row items-center justify-center rounded-md bg-muted")
		p.text(ui, BLEND_NAMES[l.blend], "text-[11] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		_ = box
		if icon_button(ui, IC_CHEVRON_UP, .Outline, .Icon_XS) {cycle_blend(st, 1)}
	}
	p.end(ui)

	op := l.opacity * 100
	if slider_row(ui, "Opacity", fmt.tprintf("%.0f%%", op), &op, 0, 100, "flex-1", "w-full") {
		l.opacity = op / 100
		doc_dirty_all(d)
		d.saved = false
	}
}

layer_list :: proc(ui: ^p.Ctx, st: ^St) {
	d := &st.doc
	p.col(ui, "w-full flex-1 min-h-0 overflow-scroll px-2 py-2 gap-1")
	defer p.end(ui)

	// Top of the panel is the top of the stack, as every editor shows it.
	for i := len(d.order) - 1; i >= 0; i -= 1 {
		pool := d.order[i]
		l := &d.pool[pool]
		p.key(ui, fmt.tprintf("layer-%d", pool))
		row := p.row(ui, "w-full shrink-0 items-center gap-2 rounded-lg p-1.5 cursor-pointer transition")
		p.apply(
			ui,
			i == d.active ? "bg-accent ring-1 ring-primary/60" : "hover:bg-accent/50",
			row,
		)
		{
			// Visibility.
			eye := p.div(ui, "size-6 shrink-0 flex-row items-center justify-center rounded-md hover:bg-background/60")
			p.icon(
				ui,
				l.visible ? IC_EYE : IC_EYE_OFF,
				l.visible ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground/50",
			)
			p.end(ui)
			if p.clickable(ui, eye) {
				d.active = i
				toggle_visible(st)
			}

			// Thumbnail over a checkerboard.
			tpx, tw, th := layer_thumb(d, pool)
			if pool < MAX_LAYERS {
				st.thumbs[pool] = {px = tpx, w = tw, h = th}
				p.pixels(
					ui,
					"size-9 shrink-0 rounded-[4] overflow-hidden border border-white/10",
					&st.thumbs[pool],
					draw_thumb,
				)
			}

			p.col(ui, "flex-1 min-w-0 gap-0.5")
			{
				p.text(
					ui,
					trim_name(layer_name(l), 20),
					i == d.active ? "text-[12] font-medium truncate" : "text-[12] truncate",
				)
				p.textf(
					ui,
					"text-[10] text-muted-foreground whitespace-nowrap",
					"%s · %.0f%%",
					BLEND_NAMES[l.blend],
					l.opacity * 100,
				)
			}
			p.end(ui)

			if i == d.active {
				p.icon(ui, IC_PENCIL, "size-3 text-muted-foreground shrink-0")
			}
		}
		p.end(ui)
		if p.clickable(ui, row) {
			d.active = i
		}
	}
}

Thumb_View :: struct {
	px:   []u32,
	w, h: int,
}

// draw_thumb paints a layer thumbnail over a fine checkerboard, so an empty
// layer looks empty and a half-transparent one looks half-transparent.
draw_thumb :: proc(c: ^p.Canvas, r: p.Rect, t: ^Thumb_View) {
	cell := 4 * c.scale
	x0 := int(r.x)
	y0 := int(r.y)
	x1 := min(int(p.rect_right(r)), c.w)
	y1 := min(int(p.rect_bottom(r)), c.h)
	if t.w <= 0 || len(t.px) < t.w * t.h {
		return
	}
	// Fit the thumbnail inside the box, preserving aspect.
	s := min(r.w / f32(t.w), r.h / f32(t.h))
	ox := r.x + (r.w - f32(t.w) * s) / 2
	oy := r.y + (r.h - f32(t.h) * s) / 2

	for y in y0 ..< y1 {
		if y < 0 {continue}
		row := c.px[y * c.w:]
		gy := int(f32(y) / cell)
		for x in x0 ..< x1 {
			if x < 0 {continue}
			gx := int(f32(x) / cell)
			base := (gx + gy) % 2 == 0 ? u32(0x00_4a4a50) : u32(0x00_3a3a40)
			br := (base >> 16) & 0xff
			bg := (base >> 8) & 0xff
			bb := base & 0xff

			sx := int((f32(x) + 0.5 - ox) / s)
			sy := int((f32(y) + 0.5 - oy) / s)
			v: u32 = 0
			if sx >= 0 && sx < t.w && sy >= 0 && sy < t.h {
				v = t.px[sy * t.w + sx]
			}
			a := (v >> 24) & 0xff
			if a == 0 {
				row[x] = 0xff00_0000 | (br << 16) | (bg << 8) | bb
				continue
			}
			ia := 255 - a
			row[x] =
				0xff00_0000 |
				(((((v >> 16) & 0xff) * a + br * ia) / 255) << 16) |
				(((((v >> 8) & 0xff) * a + bg * ia) / 255) << 8) |
				(((v & 0xff) * a + bb * ia) / 255)
		}
	}
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[26] shrink-0 items-center gap-3 px-3 border-t border-border bg-card")
	defer p.end(ui)

	d := &st.doc
	p.textf(ui, "text-[11] text-muted-foreground font-mono whitespace-nowrap", "%d x %d", d.w, d.h)
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-3")
	p.textf(
		ui,
		"text-[11] text-muted-foreground whitespace-nowrap",
		"%d layer%s",
		len(d.order),
		len(d.order) == 1 ? "" : "s",
	)
	p.style(ui).shrink = 0

	if l := active_layer(d); l != nil {
		sc.separator(ui, .Vertical, "h-3")
		p.textf(
			ui,
			"text-[11] text-foreground whitespace-nowrap",
			"%s · %s · %.0f%%",
			trim_name(layer_name(l), 18),
			BLEND_NAMES[l.blend],
			l.opacity * 100,
		)
		p.style(ui).shrink = 0
	}

	p.spacer(ui)

	// The numbers that say whether dirtying is actually working.
	p.textf(
		ui,
		"text-[11] text-muted-foreground font-mono whitespace-nowrap",
		"composite %s px / %.2f ms",
		thousands(st.comp_px),
		st.comp_ms,
	)
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-3")
	p.textf(
		ui,
		"text-[11] text-muted-foreground font-mono whitespace-nowrap",
		"blit %.2f ms",
		st.blit_ms,
	)
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-3")
	p.textf(
		ui,
		"text-[11] text-muted-foreground font-mono whitespace-nowrap",
		"frame %.1f ms",
		st.frame_ms,
	)
	p.style(ui).shrink = 0
	sc.separator(ui, .Vertical, "h-3")
	p.textf(
		ui,
		"text-[11] text-muted-foreground font-mono whitespace-nowrap",
		"undo %d/%d · %d MB",
		st.hist.head,
		len(st.hist.entries),
		hist_bytes(&st.hist) / (1024 * 1024),
	)
	p.style(ui).shrink = 0
}

thousands :: proc(n: int) -> string {
	if n < 1000 {
		return fmt.tprintf("%d", n)
	}
	if n < 1000000 {
		return fmt.tprintf("%d,%03d", n / 1000, n % 1000)
	}
	return fmt.tprintf("%d,%03d,%03d", n / 1000000, (n / 1000) % 1000, n % 1000)
}
