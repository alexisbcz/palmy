package main

// Menus and dialogs.
//
// palmy implements no `xdg_popup`, so none of this is a second surface: every
// overlay is an absolutely positioned subtree with a `z-` class, drawn inside
// the one window the process owns. That is a real constraint and it shapes the
// design — there is nowhere to put a floating palette, so each dialog is modal,
// centred, and owns the keyboard while it is up.
//
// Every overlay is fully keyboard-driven, because the recorder cannot
// synthesise pointer clicks and because an editor that needs the mouse to
// change a blur radius is a worse editor. The convention throughout is
// Up/Down to choose, Left/Right to adjust, Return to accept, Escape to cancel.

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

open_overlay :: proc(st: ^St, o: Overlay) {
	st.ov = o
	st.ov_sel = 0
	st.focus_sent = false

	switch o {
	case .Open:
		refresh_files(st, st.files_dir == "" ? cwd() : st.files_dir)
	case .Save_As:
		clear(&st.path_buf)
		suggested := st.doc.path != "" ? st.doc.path : join_path(cwd(), "untitled.png")
		append(&st.path_buf, ..transmute([]u8)suggested)
	case .Adjust:
		st.adj_v = adjust_defaults(st.adj_kind)
		preview_begin(st)
		if st.adj_kind == .Levels && st.prev_pool >= 0 {
			st.hist_bins, st.hist_peak = histogram(st.prev_base, st.doc.w, clip_rect(st))
		}
	case .Filter:
		st.flt_v = filter_defaults(st.flt_kind)
		preview_begin(st)
	case .Rename:
		clear(&st.name_buf)
		if l := active_layer(&st.doc); l != nil {
			append(&st.name_buf, ..transmute([]u8)layer_name(l))
		}
	case .None, .Help, .New_Doc, .Picker, .Adjust_Menu, .Filter_Menu, .Layer_Menu:
	}
}

close_overlay :: proc(st: ^St) {
	st.ov = .None
	st.ov_sel = 0
}

start_rename :: proc(st: ^St) {
	if active_layer(&st.doc) == nil {
		return
	}
	open_overlay(st, .Rename)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

MENU_ADJUST := [?]string{"Brightness / Contrast", "Hue / Saturation", "Levels", "Invert", "Desaturate"}
MENU_FILTER := [?]string {
	"Gaussian Blur",
	"Sharpen (unsharp mask)",
	"Edge Detect (Sobel)",
	"Emboss",
}
MENU_LAYER := [?]string {
	"New layer",
	"Duplicate layer",
	"Delete layer",
	"Raise layer",
	"Lower layer",
	"Toggle visibility",
	"Rename layer...",
	"Select all",
	"Deselect",
}

overlay_keys :: proc(ui: ^p.Ctx, st: ^St) {
	shift := .Shift in ui.input.mods
	esc := p.key_pressed(ui, p.KEY_ESCAPE, false)
	ret := p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false)

	switch st.ov {
	case .None:

	case .Help:
		if esc || ret || p.key_pressed(ui, '?', false) {
			close_overlay(st)
		}

	case .Open:
		n := len(st.files)
		if p.key_pressed(ui, p.KEY_DOWN) && n > 0 {st.ov_sel = min(st.ov_sel + 1, n - 1)}
		if p.key_pressed(ui, p.KEY_UP) && n > 0 {st.ov_sel = max(st.ov_sel - 1, 0)}
		if p.key_pressed(ui, p.KEY_HOME, false) {st.ov_sel = 0}
		if p.key_pressed(ui, p.KEY_END, false) && n > 0 {st.ov_sel = n - 1}
		if p.key_pressed(ui, p.KEY_BACKSPACE, false) {
			refresh_files(st, parent_of(st.files_dir))
		}
		if ret && st.ov_sel >= 0 && st.ov_sel < n {
			e := st.files[st.ov_sel]
			if e.is_dir {
				refresh_files(st, e.path)
			} else if open_file(st, e.path) {
				close_overlay(st)
				toast(st, fmt.tprintf("opened %s", e.name))
			} else {
				toast(st, fmt.tprintf("could not decode %s", e.name))
			}
		}
		if esc {close_overlay(st)}

	case .Save_As:
		if esc {close_overlay(st)}
		// Return is handled by the text field's `submitted`, in the builder.

	case .Rename:
		if esc {close_overlay(st)}

	case .New_Doc:
		rows := 3
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, rows - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		step := shift ? 256 : 16
		dl := p.key_count(ui, p.KEY_LEFT)
		dr := p.key_count(ui, p.KEY_RIGHT)
		delta := (dr - dl) * step
		switch st.ov_sel {
		case 0:
			st.new_w = clamp(st.new_w + delta, 16, 8192)
		case 1:
			st.new_h = clamp(st.new_h + delta, 16, 8192)
		case 2:
			if dr - dl != 0 {
				st.new_fill = ((st.new_fill + (dr - dl)) % 3 + 3) % 3
			}
		}
		for i in 0 ..< len(NEW_PRESETS) {
			if p.key_pressed(ui, u32('1' + i), false) {
				st.new_w = NEW_PRESETS[i].w
				st.new_h = NEW_PRESETS[i].h
			}
		}
		if ret {
			new_document(st, st.new_w, st.new_h, st.new_fill)
			close_overlay(st)
			toast(st, fmt.tprintf("new %d x %d document", st.doc.w, st.doc.h))
		}
		if esc {close_overlay(st)}

	case .Picker:
		dh :=
			f32(p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT)) +
			f32(p.key_count(ui, p.KEY_PAGE_UP) - p.key_count(ui, p.KEY_PAGE_DOWN)) * 6
		dv := f32(p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP))
		if dh != 0 {
			st.pick_h += dh * (shift ? 20 : 4)
			for st.pick_h < 0 {st.pick_h += 360}
			for st.pick_h >= 360 {st.pick_h -= 360}
		}
		if dv != 0 {
			if shift {
				st.pick_s = clamp(st.pick_s - dv * 0.04, 0, 1)
			} else {
				st.pick_v = clamp(st.pick_v - dv * 0.04, 0, 1)
			}
		}
		if p.key_pressed(ui, 'x', false) {
			st.pick_bg = !st.pick_bg
			sync_picker_from(st, st.pick_bg ? st.bg : st.fg)
		}
		for i in 0 ..< len(SWATCHES) {
			if i < 9 && p.key_pressed(ui, u32('1' + i), false) {
				sync_picker_from(st, SWATCHES[i])
			}
		}
		if ret {
			v := picker_color(st)
			if st.pick_bg {
				st.bg = v
			} else {
				st.fg = v
			}
			close_overlay(st)
			toast(st, fmt.tprintf("%s %s", st.pick_bg ? "background" : "foreground", hex_string(v, context.temp_allocator)))
		}
		if esc {close_overlay(st)}

	case .Adjust_Menu:
		n := len(MENU_ADJUST)
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, n - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		for i in 0 ..< n {
			if p.key_pressed(ui, u32('1' + i), false) {st.ov_sel = i}
		}
		if ret {
			switch st.ov_sel {
			case 0:
				st.adj_kind = .Brightness_Contrast
				open_overlay(st, .Adjust)
			case 1:
				st.adj_kind = .Hue_Sat
				open_overlay(st, .Adjust)
			case 2:
				st.adj_kind = .Levels
				open_overlay(st, .Adjust)
			case 3:
				close_overlay(st)
				run_pixel_op(st, invert_region, "Invert")
			case 4:
				close_overlay(st)
				run_pixel_op(st, desaturate_region, "Desaturate")
			}
		}
		if esc {close_overlay(st)}

	case .Filter_Menu:
		n := len(MENU_FILTER)
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, n - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		for i in 0 ..< n {
			if p.key_pressed(ui, u32('1' + i), false) {st.ov_sel = i}
		}
		if ret {
			st.flt_kind = Filter_Kind(clamp(st.ov_sel, 0, len(Filter_Kind) - 1))
			open_overlay(st, .Filter)
		}
		if esc {close_overlay(st)}

	case .Layer_Menu:
		n := len(MENU_LAYER)
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, n - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		for i in 0 ..< n {
			if p.key_pressed(ui, u32('1' + i), false) {st.ov_sel = i}
		}
		if ret {
			sel := st.ov_sel
			close_overlay(st)
			switch sel {
			case 0:
				add_layer(st)
			case 1:
				duplicate_layer(st)
			case 2:
				delete_layer(st)
			case 3:
				move_layer(st, 1)
			case 4:
				move_layer(st, -1)
			case 5:
				toggle_visible(st)
			case 6:
				start_rename(st)
			case 7:
				select_all(st)
			case 8:
				deselect(st)
			}
		}
		if esc {close_overlay(st)}

	case .Adjust:
		sp := adjust_spec(st.adj_kind)
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, sp.n - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		fine := p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT)
		coarse := p.key_count(ui, p.KEY_PAGE_UP) - p.key_count(ui, p.KEY_PAGE_DOWN)
		if (fine != 0 || coarse != 0) && st.ov_sel < sp.n {
			pm := sp.params[st.ov_sel]
			mul := shift ? f32(10) : 1
			delta := (f32(fine) * mul + f32(coarse) * 10) * pm.step
			st.adj_v[st.ov_sel] = clamp(st.adj_v[st.ov_sel] + delta, pm.lo, pm.hi)
			st.prev_stale = true
		}
		if p.key_pressed(ui, '0', false) {
			st.adj_v = adjust_defaults(st.adj_kind)
			st.prev_stale = true
		}
		if ret {
			preview_commit(st, ADJUST_NAMES[st.adj_kind])
			close_overlay(st)
		}
		if esc {
			preview_cancel(st)
			close_overlay(st)
		}

	case .Filter:
		sp := filter_spec(st.flt_kind)
		if p.key_pressed(ui, p.KEY_DOWN) {st.ov_sel = min(st.ov_sel + 1, sp.n - 1)}
		if p.key_pressed(ui, p.KEY_UP) {st.ov_sel = max(st.ov_sel - 1, 0)}
		fine := p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT)
		coarse := p.key_count(ui, p.KEY_PAGE_UP) - p.key_count(ui, p.KEY_PAGE_DOWN)
		if (fine != 0 || coarse != 0) && st.ov_sel < sp.n {
			pm := sp.params[st.ov_sel]
			mul := shift ? f32(10) : 1
			delta := (f32(fine) * mul + f32(coarse) * 10) * pm.step
			st.flt_v[st.ov_sel] = clamp(st.flt_v[st.ov_sel] + delta, pm.lo, pm.hi)
			st.prev_stale = true
		}
		if p.key_pressed(ui, '0', false) {
			st.flt_v = filter_defaults(st.flt_kind)
			st.prev_stale = true
		}
		if ret {
			preview_commit(st, FILTER_NAMES[st.flt_kind])
			close_overlay(st)
		}
		if esc {
			preview_cancel(st)
			close_overlay(st)
		}
	}
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

NEW_PRESETS := [?]struct {
	label: string,
	w, h:  int,
}{{"512 square", 512, 512}, {"1024 x 768", 1024, 768}, {"1920 x 1080", 1920, 1080}, {"800 x 600", 800, 600}}

build_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	scrim := p.div(ui, "absolute flex-col items-center justify-center bg-black/55 z-50")
	s := p.style(ui, scrim)
	s.inset = {p.px(0), p.px(0), p.px(0), p.px(0)}
	defer p.end(ui)
	if p.clickable(ui, scrim) {
		if st.ov == .Adjust || st.ov == .Filter {
			preview_cancel(st)
		}
		close_overlay(st)
	}

	switch st.ov {
	case .None:
	case .Help:
		help_panel(ui, st)
	case .New_Doc:
		new_doc_panel(ui, st)
	case .Open:
		open_panel(ui, st)
	case .Save_As:
		path_panel(ui, st)
	case .Rename:
		rename_panel(ui, st)
	case .Picker:
		picker_panel(ui, st)
	case .Adjust_Menu:
		menu_panel(ui, st, "Adjustments", IC_SLIDERS_HORIZONTAL, MENU_ADJUST[:], "A")
	case .Filter_Menu:
		menu_panel(ui, st, "Filters", IC_SPARKLES, MENU_FILTER[:], "F")
	case .Layer_Menu:
		menu_panel(ui, st, "Layer", IC_LAYERS, MENU_LAYER[:], "L")
	case .Adjust:
		param_panel(ui, st, true)
	case .Filter:
		param_panel(ui, st, false)
	}
}

panel_open :: proc(ui: ^p.Ctx, width: string) -> int {
	idx := sc.dialog_content_open(ui)
	p.apply(ui, width, idx)
	p.apply(ui, "shadow-2xl", idx)
	return idx
}

dialog_head :: proc(ui: ^p.Ctx, ic: p.Icon, title, sub: string) {
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ic, "size-4 text-primary shrink-0")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	sc.dialog_title(ui, title)
	if sub != "" {
		p.text(ui, sub, "text-[11] text-muted-foreground")
	}
	p.end(ui)
	p.end(ui)
}

dialog_feet :: proc(ui: ^p.Ctx, hints: []string) {
	p.row(ui, "w-full flex-wrap items-center gap-x-2 gap-y-1 pt-1")
	defer p.end(ui)
	for h, i in hints {
		if i > 0 {
			p.text(ui, "·", "text-[11] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.text(ui, h, "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
}

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------

menu_panel :: proc(ui: ^p.Ctx, st: ^St, title: string, ic: p.Icon, items: []string, keyhint: string) {
	panel_open(ui, "max-w-[360] w-[360]")
	defer p.end(ui)

	dialog_head(ui, ic, title, fmt.tprintf("opened with %s · the active layer is the target", keyhint))

	p.col(ui, "w-full gap-0.5")
	{
		for it, i in items {
			p.key(ui, fmt.tprintf("mi%d", i))
			row := p.row(ui, "w-full items-center gap-2 rounded-md px-2 py-1.5 cursor-pointer")
			p.apply(ui, i == st.ov_sel ? "bg-primary text-primary-foreground" : "hover:bg-accent", row)
			{
				p.text(ui, fmt.tprintf("%d", i + 1), i == st.ov_sel ? "text-[11] font-mono text-primary-foreground/80 w-[14]" : "text-[11] font-mono text-muted-foreground w-[14]")
				p.style(ui).shrink = 0
				p.text(ui, it, "flex-1 text-[13] whitespace-nowrap")
				p.style(ui).shrink = 0
				if i == st.ov_sel {
					sc.kbd(ui, "Return")
				}
			}
			p.end(ui)
			if p.clickable(ui, row) {
				st.ov_sel = i
				// A click is the same as Return on the highlighted row.
				menu_activate(st, i)
			}
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Up/Down choose", "Return apply", "Esc close"})
}

// menu_activate is the pointer path into the same actions the keyboard drives,
// so there is exactly one implementation of each command.
menu_activate :: proc(st: ^St, i: int) {
	switch st.ov {
	case .Adjust_Menu:
		switch i {
		case 0:
			st.adj_kind = .Brightness_Contrast
			open_overlay(st, .Adjust)
		case 1:
			st.adj_kind = .Hue_Sat
			open_overlay(st, .Adjust)
		case 2:
			st.adj_kind = .Levels
			open_overlay(st, .Adjust)
		case 3:
			close_overlay(st)
			run_pixel_op(st, invert_region, "Invert")
		case 4:
			close_overlay(st)
			run_pixel_op(st, desaturate_region, "Desaturate")
		}
	case .Filter_Menu:
		st.flt_kind = Filter_Kind(clamp(i, 0, len(Filter_Kind) - 1))
		open_overlay(st, .Filter)
	case .Layer_Menu:
		close_overlay(st)
		switch i {
		case 0:
			add_layer(st)
		case 1:
			duplicate_layer(st)
		case 2:
			delete_layer(st)
		case 3:
			move_layer(st, 1)
		case 4:
			move_layer(st, -1)
		case 5:
			toggle_visible(st)
		case 6:
			start_rename(st)
		case 7:
			select_all(st)
		case 8:
			deselect(st)
		}
	case .None, .Help, .New_Doc, .Open, .Save_As, .Picker, .Adjust, .Filter, .Rename:
	}
}

// ---------------------------------------------------------------------------
// Parameters (adjustments and filters share the panel)
// ---------------------------------------------------------------------------

param_panel :: proc(ui: ^p.Ctx, st: ^St, is_adjust: bool) {
	sp := is_adjust ? adjust_spec(st.adj_kind) : filter_spec(st.flt_kind)
	title := is_adjust ? ADJUST_NAMES[st.adj_kind] : FILTER_NAMES[st.flt_kind]
	sub :=
		st.has_sel \
		? fmt.tprintf("live preview · selection %d x %d", st.sel.x1 - st.sel.x0, st.sel.y1 - st.sel.y0) \
		: "live preview on the active layer"

	panel_open(ui, "max-w-[420] w-[420]")
	defer p.end(ui)

	dialog_head(ui, is_adjust ? IC_SLIDERS_HORIZONTAL : IC_SPARKLES, title, sub)

	if is_adjust && st.adj_kind == .Levels {
		p.pixels(ui, "w-full h-[72] rounded-md bg-muted overflow-hidden", st, draw_histogram)
	}

	p.col(ui, "w-full gap-1.5")
	{
		for i in 0 ..< sp.n {
			pm := sp.params[i]
			p.key(ui, fmt.tprintf("pp%d", i))
			row := p.row(ui, "w-full items-center gap-2 rounded-md px-2 py-1")
			p.apply(ui, i == st.ov_sel ? "bg-accent ring-1 ring-primary/50" : "", row)
			{
				p.text(ui, pm.name, "text-[12] text-muted-foreground w-[92] whitespace-nowrap")
				p.style(ui).shrink = 0

				vp := is_adjust ? &st.adj_v[i] : &st.flt_v[i]
				if slider_row(ui, "", param_readout(pm, vp^), vp, pm.lo, pm.hi, "flex-1", "flex-1 min-w-0") {
					st.prev_stale = true
				}
			}
			p.end(ui)
			if p.clickable(ui, row) {
				st.ov_sel = i
			}
		}
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	{
		p.textf(
			ui,
			"text-[11] text-muted-foreground font-mono whitespace-nowrap",
			"%.1f ms over %s px",
			st.prev_ms,
			thousands(rect_i_area(clip_rect(st))),
		)
		p.style(ui).shrink = 0
		p.spacer(ui)
		if text_button(ui, "Cancel", .Outline) {
			preview_cancel(st)
			close_overlay(st)
		}
		if text_button(ui, "Apply", .Default) {
			preview_commit(st, title)
			close_overlay(st)
		}
	}
	p.end(ui)

	dialog_feet(
		ui,
		{
			"Up/Down parameter",
			"Left/Right adjust",
			"PgUp/PgDn x10",
			"0 reset",
			"Return apply",
			"Esc cancel",
		},
	)
}

param_readout :: proc(pm: Param, v: f32) -> string {
	if pm.step < 1 {
		return fmt.tprintf("%.2f%s", v, pm.unit)
	}
	return fmt.tprintf("%.0f%s", v, pm.unit)
}

// draw_histogram plots the luma distribution of the snapshot the Levels dialog
// is working from, on a square-root scale so the tail is visible next to the
// peak.
draw_histogram :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	if st.hist_peak == 0 {
		return
	}
	n := 256
	for i in 0 ..< n {
		v := f32(st.hist_bins[i]) / f32(st.hist_peak)
		v = v <= 0 ? 0 : math.sqrt(v)
		bw := r.w / f32(n)
		bh := v * (r.h - 2)
		if bh < 0.5 {
			continue
		}
		p.fill_rect(
			c,
			{r.x + f32(i) * bw, p.rect_bottom(r) - bh - 1, max(bw, 1), bh},
			p.Color{200, 200, 210, 230},
		)
	}
}

// ---------------------------------------------------------------------------
// New document
// ---------------------------------------------------------------------------

NEW_FILL_NAMES := [?]string{"White", "Transparent", "Background colour"}

new_doc_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[400] w-[400]")
	defer p.end(ui)

	dialog_head(ui, IC_FILE_PLUS, "New document", "the current document is replaced")

	rows := [?]struct {
		label: string,
		value: string,
	} {
		{"Width", fmt.tprintf("%d px", st.new_w)},
		{"Height", fmt.tprintf("%d px", st.new_h)},
		{"Background", NEW_FILL_NAMES[clamp(st.new_fill, 0, 2)]},
	}
	p.col(ui, "w-full gap-1")
	{
		for row, i in rows {
			p.key(ui, fmt.tprintf("nd%d", i))
			line := p.row(ui, "w-full items-center gap-2 rounded-md px-2 py-1.5")
			p.apply(ui, i == st.ov_sel ? "bg-accent ring-1 ring-primary/50" : "", line)
			{
				p.text(ui, row.label, "text-[12] text-muted-foreground w-[90] whitespace-nowrap")
				p.style(ui).shrink = 0
				p.text(ui, row.value, "flex-1 text-[13] font-mono whitespace-nowrap")
				p.style(ui).shrink = 0
				if i == st.ov_sel {
					sc.kbd(ui, "Left")
					sc.kbd(ui, "Right")
				}
			}
			p.end(ui)
			if p.clickable(ui, line) {
				st.ov_sel = i
			}
		}
	}
	p.end(ui)

	p.row(ui, "w-full flex-wrap gap-1.5")
	{
		for pr, i in NEW_PRESETS {
			p.key(ui, fmt.tprintf("np%d", i))
			if text_button(ui, fmt.tprintf("%d  %s", i + 1, pr.label), .Outline, .XS) {
				st.new_w = pr.w
				st.new_h = pr.h
			}
		}
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	{
		p.spacer(ui)
		if text_button(ui, "Cancel", .Outline) {close_overlay(st)}
		if text_button(ui, "Create", .Default) {
			new_document(st, st.new_w, st.new_h, st.new_fill)
			close_overlay(st)
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Up/Down field", "Left/Right ±16 px (Shift ±256)", "1-4 presets", "Return create"})
}

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

open_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[520] w-[520]")
	defer p.end(ui)

	dialog_head(
		ui,
		IC_FOLDER_OPEN,
		"Open image",
		fmt.tprintf("%s · only this folder is listed", st.files_dir),
	)

	p.col(ui, "w-full h-[300] overflow-scroll rounded-md border border-border bg-background p-1 gap-0.5")
	{
		if len(st.files) == 0 {
			p.text(ui, "no images or folders here", "text-[12] text-muted-foreground p-3")
		}
		for e, i in st.files {
			p.key(ui, fmt.tprintf("fe%d", i))
			row := p.row(ui, "w-full shrink-0 items-center gap-2 rounded-md px-2 py-1.5 cursor-pointer")
			p.apply(ui, i == st.ov_sel ? "bg-primary text-primary-foreground" : "hover:bg-accent", row)
			{
				p.icon(ui, e.is_dir ? IC_FOLDER_OPEN : IC_IMAGE, "size-3.5 shrink-0")
				p.text(ui, e.name, "flex-1 text-[12] truncate")
				if !e.is_dir && e.w > 0 {
					p.textf(
						ui,
						i == st.ov_sel ? "text-[11] font-mono text-primary-foreground/80 whitespace-nowrap" : "text-[11] font-mono text-muted-foreground whitespace-nowrap",
						"%d x %d",
						e.w,
						e.h,
					)
					p.style(ui).shrink = 0
				}
			}
			p.end(ui)
			if p.clickable(ui, row) {
				st.ov_sel = i
				if e.is_dir {
					refresh_files(st, e.path)
				} else if open_file(st, e.path) {
					close_overlay(st)
				}
			}
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Up/Down choose", "Return open", "Backspace parent folder", "Esc cancel"})
}

// ---------------------------------------------------------------------------
// Save As / Rename: the two text-entry dialogs
// ---------------------------------------------------------------------------

path_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[520] w-[520]")
	defer p.end(ui)

	dialog_head(ui, IC_SAVE, "Save a PNG", "the flattened composite is written to this path")

	at := p.node_count(ui)
	_, submitted := p.text_field(
		ui,
		&st.path_buf,
		"/path/to/image.png",
		"w-full h-9 text-[13] font-mono",
	)
	if !st.focus_sent {
		p.set_focus(ui, p.node_id(ui, at))
		st.focus_sent = true
	}

	p.row(ui, "w-full items-center gap-2")
	{
		p.spacer(ui)
		if text_button(ui, "Cancel", .Outline) {close_overlay(st)}
		if text_button(ui, "Save", .Default) || submitted {
			if save_to(st, strings.trim_space(string(st.path_buf[:]))) {
				close_overlay(st)
			}
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Return save", "Esc cancel", "nothing outside this path is written"})
}

rename_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[380] w-[380]")
	defer p.end(ui)

	dialog_head(ui, IC_PENCIL, "Rename layer", "")

	at := p.node_count(ui)
	_, submitted := p.text_field(ui, &st.name_buf, "Layer name", "w-full h-9 text-[13]")
	if !st.focus_sent {
		p.set_focus(ui, p.node_id(ui, at))
		st.focus_sent = true
	}

	p.row(ui, "w-full items-center gap-2")
	{
		p.spacer(ui)
		if text_button(ui, "Cancel", .Outline) {close_overlay(st)}
		if text_button(ui, "Rename", .Default) || submitted {
			d := &st.doc
			if l := active_layer(d); l != nil {
				before := meta_capture(d)
				layer_set_name(l, strings.trim_space(string(st.name_buf[:])))
				push_meta_edit(&st.hist, d, before, "Rename layer")
			}
			close_overlay(st)
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Return rename", "Esc cancel"})
}

// ---------------------------------------------------------------------------
// Colour picker
// ---------------------------------------------------------------------------

picker_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[420] w-[420]")
	defer p.end(ui)

	cur := picker_color(st)
	dialog_head(
		ui,
		IC_DROPLET,
		st.pick_bg ? "Background colour" : "Foreground colour",
		"hue strip and saturation / value square",
	)

	p.row(ui, "w-full gap-2 h-[200]")
	{
		sv := p.pixels(ui, "flex-1 h-full rounded-md overflow-hidden cursor-crosshair", st, draw_sv_square)
		{
			r := p.rect_of(ui, p.node_id(ui, sv))
			if p.is_active(ui, sv) && r.w > 4 {
				m := p.mouse_pos(ui)
				st.pick_s = clamp((m.x - r.x) / r.w, 0, 1)
				st.pick_v = clamp(1 - (m.y - r.y) / r.h, 0, 1)
			}
			p.clickable(ui, sv)
		}

		hue := p.pixels(ui, "w-[26] h-full rounded-md overflow-hidden cursor-crosshair", st, draw_hue_strip)
		{
			r := p.rect_of(ui, p.node_id(ui, hue))
			if p.is_active(ui, hue) && r.h > 4 {
				st.pick_h = clamp((p.mouse_pos(ui).y - r.y) / r.h, 0, 1) * 360
			}
			p.clickable(ui, hue)
		}

		p.col(ui, "w-[96] h-full gap-1.5")
		{
			ch := p.div(ui, "w-full h-10 rounded-md border border-white/25")
			p.style(ui, ch).bg = p.flat(swatch_color(cur))
			p.end(ui)
			p.text(ui, hex_string(cur, context.temp_allocator), "text-[12] font-mono text-center")
			r, g, b, _ := unpack_argb(cur)
			p.textf(ui, "text-[11] font-mono text-muted-foreground text-center", "%d %d %d", r, g, b)
			p.textf(
				ui,
				"text-[11] font-mono text-muted-foreground text-center",
				"H %.0f°",
				st.pick_h,
			)
			p.textf(
				ui,
				"text-[11] font-mono text-muted-foreground text-center",
				"S %.0f%%  V %.0f%%",
				st.pick_s * 100,
				st.pick_v * 100,
			)
			p.spacer(ui)
			if text_button(ui, st.pick_bg ? "Editing bg" : "Editing fg", .Outline, .XS) {
				st.pick_bg = !st.pick_bg
				sync_picker_from(st, st.pick_bg ? st.bg : st.fg)
			}
		}
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full flex-wrap gap-1")
	{
		for v, i in SWATCHES {
			p.key(ui, fmt.tprintf("pk%d", i))
			idx := p.div(ui, "size-6 rounded-[4] border border-white/15 cursor-pointer hover:border-white/70 transition")
			p.style(ui, idx).bg = p.flat(swatch_color(v))
			p.end(ui)
			if p.clickable(ui, idx) {
				sync_picker_from(st, v)
			}
		}
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	{
		p.spacer(ui)
		if text_button(ui, "Cancel", .Outline) {close_overlay(st)}
		if text_button(ui, "Use colour", .Default) {
			if st.pick_bg {
				st.bg = cur
			} else {
				st.fg = cur
			}
			close_overlay(st)
		}
	}
	p.end(ui)

	dialog_feet(
		ui,
		{
			"Left/Right hue",
			"PgUp/PgDn hue x6",
			"Up/Down value",
			"Shift Up/Down saturation",
			"1-9 swatch",
			"x swaps target",
			"Return use",
		},
	)
}

// draw_sv_square is the saturation/value plane for the current hue, with a ring
// marking the chosen point.
draw_sv_square :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	x0 := max(int(r.x), int(c.clip.x))
	y0 := max(int(r.y), int(c.clip.y))
	x1 := min(int(p.rect_right(r)), min(c.w, int(p.rect_right(c.clip))))
	y1 := min(int(p.rect_bottom(r)), min(c.h, int(p.rect_bottom(c.clip))))
	if x1 <= x0 || y1 <= y0 {
		return
	}
	for y in y0 ..< y1 {
		v := 1 - (f32(y) + 0.5 - r.y) / r.h
		row := c.px[y * c.w:]
		for x in x0 ..< x1 {
			s := (f32(x) + 0.5 - r.x) / r.w
			rr, gg, bb := hsv_to_rgb(st.pick_h, clamp(s, 0, 1), clamp(v, 0, 1))
			row[x] =
				0xff00_0000 |
				(u32(rr * 255 + 0.5) << 16) |
				(u32(gg * 255 + 0.5) << 8) |
				u32(bb * 255 + 0.5)
		}
	}
	cx := r.x + st.pick_s * r.w
	cy := r.y + (1 - st.pick_v) * r.h
	marker(c, cx, cy)
}

draw_hue_strip :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	x0 := max(int(r.x), int(c.clip.x))
	y0 := max(int(r.y), int(c.clip.y))
	x1 := min(int(p.rect_right(r)), min(c.w, int(p.rect_right(c.clip))))
	y1 := min(int(p.rect_bottom(r)), min(c.h, int(p.rect_bottom(c.clip))))
	for y in y0 ..< y1 {
		h := (f32(y) + 0.5 - r.y) / r.h * 360
		rr, gg, bb := hsv_to_rgb(h, 1, 1)
		v :=
			0xff00_0000 |
			(u32(rr * 255 + 0.5) << 16) |
			(u32(gg * 255 + 0.5) << 8) |
			u32(bb * 255 + 0.5)
		row := c.px[y * c.w:]
		for x in x0 ..< x1 {
			row[x] = v
		}
	}
	y := r.y + st.pick_h / 360 * r.h
	p.fill_rect(c, {r.x, y - 1, r.w, 2}, p.Color{255, 255, 255, 230})
	p.fill_rect(c, {r.x, y - 2, r.w, 1}, p.Color{0, 0, 0, 120})
	p.fill_rect(c, {r.x, y + 1, r.w, 1}, p.Color{0, 0, 0, 120})
}

marker :: proc(c: ^p.Canvas, cx, cy: f32) {
	p.stroke_round_rect(c, {cx - 6, cy - 6, 12, 12}, {6, 6, 6, 6}, 2, p.Color{255, 255, 255, 240})
	p.stroke_round_rect(c, {cx - 7.5, cy - 7.5, 15, 15}, {7.5, 7.5, 7.5, 7.5}, 1, p.Color{0, 0, 0, 160})
}

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------

HELP := [?][2]string {
	{"b e g i m v h", "the seven tools, in palette order"},
	{"Arrows", "move the keyboard cursor"},
	{"Return", "act with the tool there: paint, fill, sample"},
	{"Space (hold)", "pan from any tool"},
	{"[ ]", "brush size"},
	{"{ }", "brush hardness"},
	{"1 - 0", "brush opacity 10% - 100%"},
	{"x / d", "swap colours / reset to black and white"},
	{"c", "colour picker"},
	{"a / f / l", "adjustments / filters / layer menu"},
	{"r", "rename the active layer"},
	{"PgUp PgDn", "select the layer above / below"},
	{"Ctrl PgUp PgDn", "reorder the active layer"},
	{"/", "toggle the layer's visibility"},
	{"; '", "layer opacity down / up"},
	{", .", "previous / next blend mode"},
	{"Arrows + Move tool", "nudge the layer (Shift = 10 px)"},
	{"u / y", "undo / redo"},
	{"o", "open an image from this folder"},
	{"Ctrl Z", "undo"},
	{"Ctrl Shift Z", "redo"},
	{"Ctrl A / Ctrl D", "select all / deselect"},
	{"Ctrl I", "invert the layer"},
	{"Ctrl Shift U", "desaturate the layer"},
	{"Ctrl N / O / S", "new / open / save"},
	{"Ctrl Shift S", "save as"},
	{"Ctrl J", "duplicate layer"},
	{"Ctrl Shift N", "new layer"},
	{"Ctrl Delete", "delete layer"},
	{"Ctrl 0 / Ctrl 1", "fit / 100%"},
	{"+ -", "zoom in / out"},
	{"Esc", "cancel, or drop the selection"},
	{"? or F1", "this list"},
}

help_panel :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, "max-w-[700] w-[700]")
	defer p.end(ui)

	dialog_head(ui, IC_KEYBOARD, "Keyboard", "every command is reachable without the pointer")

	p.row(ui, "w-full gap-5")
	{
		half := (len(HELP) + 1) / 2
		for col in 0 ..< 2 {
			p.key(ui, col == 0 ? "hc0" : "hc1")
			p.col(ui, "flex-1 min-w-0 gap-0.5")
			lo := col * half
			hi := min(lo + half, len(HELP))
			for i in lo ..< hi {
				p.row(ui, "w-full items-center gap-2 shrink-0")
				p.text(ui, HELP[i][0], "text-[11] font-mono text-primary w-[104] shrink-0 whitespace-nowrap")
				p.text(ui, HELP[i][1], "flex-1 text-[11] text-muted-foreground truncate")
				p.end(ui)
			}
			p.end(ui)
		}
	}
	p.end(ui)

	dialog_feet(ui, {"Esc or Return closes"})
	_ = st
}
