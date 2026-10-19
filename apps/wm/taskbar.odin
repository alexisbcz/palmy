// taskbar.odin — the bar across the top of each output, and what clicking
// it does (UX.md P0-10).
//
//     [◆ Palmy] [1 2 3 … 9] [layout]  [▣ Terminal] [▣ gallery] …  [kbd] [clock]
//
// The bar used to be a debugging HUD — window and client counts, the frame
// rate, an F-key legend, a status line that announced every action — and it
// ignored the pointer. Now the workspace indicators switch on click and step
// on scroll, and a taskbar lists the windows of the workspace on screen:
// click to focus (restoring a minimized one), click the focused entry to
// minimize it, middle-click to close, right-click for the window menu. The
// minimized-window dock that sat over window content at the bottom of the
// screen is gone; its job is the taskbar's.
//
// The bar is drawn and hit-tested from one list of rectangles: drawing
// records what it drew where, and the next frame's clicks are tested against
// that, so the two can never disagree about where an entry is.
package wm

import "core:fmt"
import "core:strings"
import ai "kit:appindex"
import p "palmy:."

Bar_Hit_Kind :: enum u8 {
	Brand, // the start button
	Pin, // idx: an app pinned to the bar (start.odin's entry index)
	Workspace,
	Layout,
	Entry,
}

Bar_Hit :: struct {
	kind: Bar_Hit_Kind,
	rect: p.Rect,
	idx:  int, // workspace index
	t:    ^Toplevel,
	out:  int,
}

bar_hits: [dynamic]Bar_Hit
bar_hover: int = -1 // index into bar_hits under the pointer

ENTRY_MAX_W :: 200

// taskbar_windows is the taskbar's order: creation order (the tiling seq),
// which is stable — focusing a window must not make the entries jump.
taskbar_windows :: proc(s: ^Server, ws_idx: int) -> []^Toplevel {
	out := make([dynamic]^Toplevel, 0, 8, context.temp_allocator)
	for t in ws_stack(s, ws_idx) {
		if t.mapped {
			ws_win(t)
			append(&out, t)
		}
	}
	for i in 1 ..< len(out) {
		v := out[i]
		k := ws_win(v).seq
		j := i - 1
		for j >= 0 && ws_win(out[j]).seq > k {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = v
	}
	return out[:]
}

draw_bar :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, oi, ws_idx: int) {
	if !s.cfg.bar {
		return
	}
	f := &app.fonts
	o := s.outputs[oi]
	X := f32(o.x)
	Y := f32(o.y)
	W := f32(o.w)
	H := f32(s.cfg.bar_h)
	p.fill_rect(cv, {X, Y, W, H}, p.hex(pal.bar_bg))
	p.fill_rect(cv, {X, Y + H - 1, W, 1}, p.hex(pal.bar_line))
	cy := Y + H / 2
	mid := cy + 4.5

	hit :: proc(kind: Bar_Hit_Kind, r: p.Rect, idx: int, t: ^Toplevel, out: int) -> bool {
		append(&bar_hits, Bar_Hit{kind, r, idx, t, out})
		return bar_hover == len(bar_hits) - 1
	}

	// The start button: the brand, which opens the start menu (start.odin).
	// Its hit area runs to the corner of the screen, so a pointer thrown
	// into the corner and clicked lands on it.
	brand := session.bare ? "Palmy" : "palmy wm"
	bw := p.text_width(f, brand, 13, .Sans, .Semibold)
	bhot := hit(.Brand, {X, Y, bw + 46, H}, 0, nil, oi)
	{
		r := p.Rect{X + 5, cy - 12, bw + 38, 24}
		open_here := start.open && start.out == oi
		if open_here || bhot {
			p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(open_here ? pal.entry_focus : pal.chip_hover))
		}
	}
	p.fill_round_rect(cv, {X + 12, cy - 7, 14, 14}, {4, 4, 4, 4}, p.hex(ACCENT))
	p.fill_round_rect(cv, {X + 16, cy - 3, 6, 6}, {2, 2, 2, 2}, with_alpha(pal.on_accent, 0.8))
	x := X + 34
	x += p.draw_text(cv, f, brand, x, mid, 13, p.hex(pal.bar_text), .Sans, .Semibold)
	x += 14

	// The apps pinned to the bar: one click opens the app, or brings its
	// window forward when it already has one; a dot under it says it is
	// running.
	if s.cfg.bar_pins && !session.kiosk {
		start_index_ensure()
		drew := false
		for id in start.bar_pins {
			i := ai.find_id(start.entries, id)
			if i < 0 {
				continue
			}
			r := p.Rect{x, cy - 13, 26, 26}
			hot := hit(.Pin, r, i, nil, oi)
			if hot {
				p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(pal.chip_hover))
			}
			e := &start.entries[i]
			hue := ai.hue_for(e.id)
			ink := pal.dark ? mix(hue, 0xffffff, 0.35) : mix(hue, 0x000000, 0.15)
			p.draw_icon(cv, wm_icons(), ai.icon_for(e), r.x + 5, r.y + 5, 16, p.hex(ink))
			if _, running := entry_running(s, i); running {
				p.fill_round_rect(cv, {r.x + 10, r.y + r.h - 1, 6, 2}, {1, 1, 1, 1}, p.hex(pal.accent))
			}
			x += 28
			drew = true
		}
		if drew {
			p.fill_rect(cv, {x + 4, cy - 8, 1, 16}, p.hex(pal.bar_line))
			x += 14
		}
	}

	// The workspace strip. Every workspace that exists is drawn: filled when
	// it is the one on screen, outlined when it holds windows you cannot
	// see, dimmed when empty — and each is a button now.
	for w, i in s.workspaces {
		if w.output != oi {
			continue
		}
		lw := max(p.text_width(f, w.name, 11, .Sans, .Semibold) + 14, 22)
		r := p.Rect{x, cy - 9, lw, 18}
		hot := hit(.Workspace, {x - 2, Y, lw + 4, H}, i, nil, oi)
		occupied := ws_count_on(s, i) > 0
		switch {
		case i == ws_idx:
			p.fill_round_rect(cv, r, {5, 5, 5, 5}, p.hex(ACCENT))
		case occupied:
			p.fill_round_rect(cv, r, {5, 5, 5, 5}, p.hex(hot ? mix(pal.accent_wash, pal.accent, 0.15) : pal.accent_wash))
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(pal.accent_edge))
		case:
			if hot {
				p.fill_round_rect(cv, r, {5, 5, 5, 5}, p.hex(pal.chip_hover))
			}
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(pal.chip_line))
		}
		col := u32(i == ws_idx ? pal.on_accent : (occupied ? pal.accent_text : (hot ? pal.pop_dim : pal.bar_dim)))
		tw := p.text_width(f, w.name, 11, .Sans, .Semibold)
		p.draw_text(cv, f, w.name, r.x + (lw - tw) / 2, cy + 4, 11, p.hex(col), .Sans, .Semibold)
		x += lw + 4
	}
	x += 8

	// The layout badge: which automatic layout this workspace is running, or
	// that it is floating. Clicking it cycles layouts.
	ws := &s.workspaces[ws_idx]
	mode := ws.tiling ? tile_layout_name(ws.layout) : "floating"
	mw := p.text_width(f, mode, 11, .Sans, .Medium) + 14
	lhot := hit(.Layout, {x - 2, Y, mw + 4, H}, ws_idx, nil, oi)
	p.fill_round_rect(cv, {x, cy - 9, mw, 18}, {5, 5, 5, 5}, p.hex(lhot ? pal.chip_hover : pal.chip_fill))
	p.stroke_round_rect(cv, {x, cy - 9, mw, 18}, {5, 5, 5, 5}, 1, p.hex(pal.chip_line))
	p.draw_text(cv, f, mode, x + 7, cy + 4, 11, p.hex(pal.accent_soft), .Sans, .Medium)
	x += mw + 14

	if s.wm_mode {
		lbl := "WINDOW MODE"
		w := p.text_width(f, lbl, 11, .Sans, .Semibold) + 16
		p.fill_round_rect(cv, {x, cy - 9, w, 18}, {5, 5, 5, 5}, p.hex(ACCENT))
		p.draw_text(cv, f, lbl, x + 8, cy + 4, 11, p.hex(pal.on_accent), .Sans, .Semibold)
		x += w + 10
	}

	// The right side: the clock, in local time (clock.odin), and the keyboard
	// layout just left of it whenever it is not plain US or there is more
	// than one to switch between.
	right := X + W
	{
		local, _ := clock_now()
		ct := clock_text(local)
		cw := p.text_width(f, ct, 12, .Sans, .Medium)
		p.draw_text(cv, f, ct, right - cw - 12, mid, 12, p.hex(pal.bar_text), .Sans, .Medium)
		right -= cw + 24
		if session.bare && (kbd.label != "us" || xkb_km.ngroups > 1) && kbd.label != "" {
			lbl := strings.to_upper(kbd.label, context.temp_allocator)
			lw := p.text_width(f, lbl, 11, .Sans, .Semibold) + 14
			r := p.Rect{right - lw, cy - 9, lw, 18}
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(pal.chip_line))
			p.draw_text(cv, f, lbl, r.x + 7, cy + 4, 11, p.hex(pal.accent_soft), .Sans, .Semibold)
			right -= lw + 10
		}
	}

	// The taskbar: one entry per window on this workspace, up to 200 px
	// each, shrinking together when they do not fit.
	wins := taskbar_windows(s, ws_idx)
	if len(wins) == 0 {
		return
	}
	avail := right - x - 8
	gap := f32(4)
	ew := min(f32(ENTRY_MAX_W), (avail - gap * f32(len(wins) - 1)) / f32(len(wins)))
	if ew < 40 {
		return
	}
	for t in wins {
		r := p.Rect{x, cy - 12, ew, 24}
		hot := hit(.Entry, r, ws_idx, t, oi)
		m := ws_win(t)
		focused := s.focus == t
		switch {
		case focused:
			p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(pal.entry_focus))
			p.fill_round_rect(cv, {r.x + 8, r.y + r.h - 2, r.w - 16, 2}, {1, 1, 1, 1}, p.hex(ACCENT))
		case m.urgent:
			p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(hot ? mix(pal.accent_wash, pal.accent, 0.2) : pal.accent_wash))
		case hot:
			p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(pal.chip_hover))
		}
		dim := t.minimized
		draw_app_icon(cv, f, t, r.x + 7, cy - 8, 16, dim ? 0.4 : 1)
		label := ellipsize_end(f, title_of(t), 12, .Medium, r.w - 34)
		col := focused ? pal.bar_text : pal.entry_text
		if dim {
			col = pal.pop_dim
		}
		p.draw_text(cv, f, label, r.x + 29, cy + 4.2, 12, p.hex(col), .Sans, .Medium)
		x += ew + gap
	}
}

// bar_pointer handles the pointer over the bar. Returns false when the
// pointer is not on a bar.
bar_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !s.cfg.bar || session.kiosk {
		bar_hover = -1
		return false
	}
	oi := ws_output_at(s, mp.x, mp.y)
	o := s.outputs[oi]
	if mp.y < o.y || mp.y >= o.y + s.cfg.bar_h {
		if bar_hover != -1 {
			bar_hover = -1
			s.dirty = true
		}
		return false
	}
	hover := -1
	for h, i in bar_hits {
		if h.out == oi && p.rect_contains(h.rect, f32(mp.x), f32(mp.y)) {
			hover = i
			break
		}
	}
	if hover != bar_hover {
		bar_hover = hover
		s.dirty = true
	}
	if in_.scroll.y != 0 {
		// Scrolling anywhere on the bar's left half steps through
		// workspaces, without wrapping off either end.
		step := in_.scroll.y > 0 ? 1 : -1
		next := s.cur_ws + step
		if next >= 0 && next < len(s.workspaces) {
			ws_switch(s, next)
		}
	}
	if hover < 0 {
		return true
	}
	h := bar_hits[hover]
	switch h.kind {
	case .Brand:
		if in_.pressed[.Left] {
			s.cur_out = oi
			start_toggle(s)
		}
		if in_.pressed[.Right] {
			menu_open_start_button(s, mp.x, mp.y)
		}
	case .Pin:
		switch {
		case in_.pressed[.Left]:
			if t, running := entry_running(s, h.idx); running {
				if !ws_on_current(s, t) {
					for w, wi in s.workspaces {
						for x in ws_stack(s, wi) {
							if x == t {
								ws_switch(s, wi)
							}
						}
						_ = w
					}
				}
				focus_window(s, t)
			} else {
				start_launch(s, h.idx)
			}
		case in_.pressed[.Middle]:
			start_launch(s, h.idx)
		case in_.pressed[.Right]:
			menu_open_pin(s, h.idx, mp.x, mp.y)
		}
	case .Workspace:
		if in_.pressed[.Left] {
			ws_switch(s, h.idx)
		}
	case .Layout:
		if in_.pressed[.Left] {
			ws_next_layout(s)
		}
		if in_.pressed[.Right] {
			menu_open_layout(s, mp.x, mp.y)
		}
	case .Entry:
		t := h.t
		if t == nil || !ws_on_current(s, t) {
			return true
		}
		switch {
		case in_.pressed[.Left]:
			if s.focus == t && !t.minimized {
				minimize_window(s, t)
			} else {
				focus_window(s, t)
			}
		case in_.pressed[.Middle]:
			close_window(s, t)
		case in_.pressed[.Right]:
			menu_open_window(s, t, mp.x, mp.y)
		}
	}
	return true
}

// bar_entry_rect is where a window's taskbar entry was last drawn, which is
// where a minimize animates to.
bar_entry_rect :: proc(t: ^Toplevel) -> (p.Rect, bool) {
	for h in bar_hits {
		if h.kind == .Entry && h.t == t {
			return h.rect, true
		}
	}
	return {}, false
}

bar_forget :: proc(t: ^Toplevel) {
	for &h in bar_hits {
		if h.t == t {
			h.t = nil
		}
	}
}

// ---------------------------------------------------------------------------
// Toasts and the debug HUD
// ---------------------------------------------------------------------------

TOAST_S :: 2.0

draw_toast :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output) {
	if s.toast == "" {
		return
	}
	age := wall_now() - s.toast_at
	if age >= TOAST_S {
		return
	}
	wake_at(s.toast_at + TOAST_S)
	f := &app.fonts
	tw := p.text_width(f, s.toast, 12.5, .Sans, .Medium)
	w := tw + 28
	r := p.Rect{f32(o.x) + (f32(o.w) - w) / 2, f32(o.y + ws_bar_h(s)) + 10, w, 30}
	p.drop_shadow(cv, r, {8, 8, 8, 8}, 16, 0, {0, 6}, p.hexa(pal.shadow))
	p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_bg))
	p.stroke_round_rect(cv, r, {8, 8, 8, 8}, 1, p.hex(pal.pop_line))
	p.draw_text(cv, f, s.toast, r.x + 14, r.y + 19.5, 12.5, p.hex(pal.pop_text), .Sans, .Medium)
}

// draw_debug_hud is the instrumentation the bar used to carry, now behind
// `debug_hud = on` or Super+Ctrl+Shift+D, in a corner.
draw_debug_hud :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output) {
	if !s.cfg.debug_hud {
		return
	}
	f := &app.fonts
	mapped := 0
	for t in s.stack {
		if t.mapped {mapped += 1}
	}
	lines := [?]string {
		fmt.tprintf("%d window%s  %d client%s", mapped, mapped == 1 ? "" : "s", len(s.clients), len(s.clients) == 1 ? "" : "s"),
		fmt.tprintf("%.0f fps  draw %.1f ms", app.fps, anim_state.draw_ms),
		fmt.tprintf("animations %v%s", anim_mode(s), anim_state.auto_reduced ? " (auto)" : ""),
		s.status != "" ? fmt.tprintf("last: %s", s.status) : "",
	}
	w := f32(0)
	for l in lines {
		w = max(w, p.text_width(f, l, 11, .Mono))
	}
	w += 20
	h := f32(len(lines)) * 16 + 12
	r := p.Rect{f32(o.x + o.w) - w - 10, f32(o.y + ws_bar_h(s)) + 10, w, h}
	p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hexa(0x09090be6))
	p.stroke_round_rect(cv, r, {6, 6, 6, 6}, 1, p.hex(0x3f3f46))
	y := r.y + 18
	for l in lines {
		p.draw_text(cv, f, l, r.x + 10, y, 11, p.hex(0xa1a1aa), .Mono)
		y += 16
	}
}
