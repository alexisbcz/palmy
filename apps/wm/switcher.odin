// switcher.odin — Alt+Tab and Super+Tab (UX.md P1-1).
//
// Holding Alt (or Super) and pressing Tab opens a centred strip of the
// workspace's windows (Super+Tab: every workspace's) in most-recently-used
// order: the current window first, the selection on the one before it, so a
// single Alt+Tab goes back to where the user just was. Tab moves on,
// Shift+Tab back; the arrows and the pointer work too; Q closes the selected
// window in place. Letting go of the modifier commits — focus, raise,
// un-minimize, switch workspace if need be — and Escape cancels, leaving
// focus untouched. A quick tap (released within 120 ms) switches without the
// overlay ever being drawn.
//
// Thumbnails are the windows' last buffers, scaled into a 200 x 130 box with
// the same nearest-neighbour blit the animations use.
package wm

import "core:slice"
import p "palmy:."

SW_THUMB_W :: 200
SW_THUMB_H :: 130
SW_TAP :: 0.12

Switcher :: struct {
	open:      bool,
	all:       bool,
	held:      p.Modifiers,
	list:      [dynamic]^Toplevel,
	sel:       int,
	opened_at: f64,
	steps:     int,
	rects:     [dynamic]p.Rect,
}

sw: Switcher

// mru_order lists windows most recently focused first, minimized ones last.
// Pure over its input, so the selftest can pin the order down.
mru_order :: proc(wins: []^Toplevel, allocator := context.temp_allocator) -> []^Toplevel {
	out := slice.clone(wins, allocator)
	slice.stable_sort_by(out, proc(a, b: ^Toplevel) -> bool {
		if a.minimized != b.minimized {
			return !a.minimized
		}
		return ws_win(a).mru > ws_win(b).mru
	})
	return out
}

switcher_open :: proc(s: ^Server, b: Cfg_Bind) {
	if sw.open {
		switcher_step(s, .Shift in b.mods ? -1 : 1)
		return
	}
	cand := make([dynamic]^Toplevel, 0, 16, context.temp_allocator)
	if b.arg == 1 {
		for i in 0 ..< len(s.workspaces) {
			for t in ws_stack(s, i) {
				if t.mapped {
					append(&cand, t)
				}
			}
		}
	} else {
		for t in s.stack {
			if t.mapped {
				append(&cand, t)
			}
		}
	}
	if len(cand) == 0 {
		return
	}
	clear(&sw.list)
	for t in mru_order(cand[:]) {
		append(&sw.list, t)
	}
	sw.open = true
	sw.all = b.arg == 1
	sw.held = b.any_mods ? {} : b.mods - {.Shift}
	sw.opened_at = wall_now()
	sw.steps = 1
	n := len(sw.list)
	sw.sel = n > 1 ? 1 : 0
	if .Shift in b.mods {
		sw.sel = n - 1
	}
	if sw.held == {} {
		// Bound to a bare key: there is no modifier to let go of, so it is
		// the quick switch and nothing else.
		switcher_commit(s)
		return
	}
	wake_at(sw.opened_at + SW_TAP)
	s.dirty = true
}

switcher_step :: proc(s: ^Server, d: int) {
	n := len(sw.list)
	if n == 0 {
		return
	}
	sw.sel = ((sw.sel + d) % n + n) % n
	sw.steps += 1
	s.dirty = true
}

switcher_close :: proc(s: ^Server) {
	sw.open = false
	clear(&sw.list)
	clear(&sw.rects)
	s.dirty = true
}

switcher_commit :: proc(s: ^Server) {
	if !sw.open {
		return
	}
	if sw.sel >= 0 && sw.sel < len(sw.list) {
		t := sw.list[sw.sel]
		switcher_close(s)
		idx := ws_index_of(s, t)
		if idx >= 0 && idx != s.cur_ws {
			ws_switch(s, idx)
		}
		if ws_on_current(s, t) {
			focus_window(s, t)
			ix_reveal(s, t)
		}
		return
	}
	switcher_close(s)
}

switcher_forget :: proc(s: ^Server, t: ^Toplevel) {
	if !sw.open {
		return
	}
	for w, i in sw.list {
		if w == t {
			ordered_remove(&sw.list, i)
			if sw.sel >= len(sw.list) {
				sw.sel = len(sw.list) - 1
			}
			break
		}
	}
	if len(sw.list) == 0 {
		switcher_close(s)
	}
}

// switcher_mods commits when the held modifier is let go.
switcher_mods :: proc(s: ^Server, mods: p.Modifiers) {
	if sw.open && sw.held != {} && !(sw.held <= mods) {
		switcher_commit(s)
	}
}

switcher_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event, code: u32) -> bool {
	if !sw.open {
		return false
	}
	switch k.sym {
	case p.KEY_TAB:
		switcher_step(s, .Shift in k.mods ? -1 : 1)
	case KEY_ISO_LEFT_TAB, p.KEY_LEFT, p.KEY_UP:
		switcher_step(s, -1)
	case p.KEY_RIGHT, p.KEY_DOWN:
		switcher_step(s, 1)
	case p.KEY_ESCAPE:
		switcher_close(s)
	case p.KEY_RETURN:
		switcher_commit(s)
	case 'q', 'Q':
		if sw.sel >= 0 && sw.sel < len(sw.list) {
			close_window(s, sw.list[sw.sel])
		}
	}
	// Every key belongs to the switcher while it is open, including the
	// modifiers themselves, which must not reach the client either.
	return true
}

switcher_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !sw.open {
		return false
	}
	for r, i in sw.rects {
		if p.rect_contains(r, f32(mp.x), f32(mp.y)) {
			if i != sw.sel && in_.mouse_delta != {0, 0} {
				sw.sel = i
				s.dirty = true
			}
			if in_.pressed[.Left] {
				sw.sel = i
				switcher_commit(s)
				ix.mode = .Swallow
			}
			return true
		}
	}
	return true
}

switcher_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	if !sw.open || len(sw.list) == 0 {
		return
	}
	// The quick tap: nothing is drawn until the overlay has been up for
	// 120 ms or has been stepped through.
	if wall_now() - sw.opened_at < SW_TAP && sw.steps <= 1 {
		wake_at(sw.opened_at + SW_TAP)
		return
	}
	f := &app.fonts
	o := s.outputs[s.cur_out]
	n := len(sw.list)
	cell_w := f32(SW_THUMB_W + 16)
	cell_h := f32(SW_THUMB_H + 44)
	per_row := max(1, min(n, int((f32(o.w) - 80) / cell_w)))
	rows := (n + per_row - 1) / per_row
	pw := f32(per_row) * cell_w + 24
	ph := f32(rows) * cell_h + 24
	px := f32(o.x) + (f32(o.w) - pw) / 2
	py := f32(o.y) + (f32(o.h) - ph) / 2
	p.reset_clip(cv)
	panel := p.Rect{px, py, pw, ph}
	p.drop_shadow(cv, panel, {14, 14, 14, 14}, 40, 0, {0, 14}, p.hexa(0x000000aa))
	p.fill_round_rect(cv, panel, {14, 14, 14, 14}, p.hexa(0x0f0f12f2))
	p.stroke_round_rect(cv, panel, {14, 14, 14, 14}, 1, p.hex(0x27272a))
	clear(&sw.rects)
	for t, i in sw.list {
		cx := px + 12 + f32(i % per_row) * cell_w
		cy := py + 12 + f32(i / per_row) * cell_h
		cell := p.Rect{cx, cy, cell_w, cell_h}
		append(&sw.rects, cell)
		if i == sw.sel {
			p.fill_round_rect(cv, p.rect_inset(cell, 2), {10, 10, 10, 10}, p.hex(0x27272a))
			p.stroke_round_rect(cv, p.rect_inset(cell, 2), {10, 10, 10, 10}, 2, p.hex(ACCENT))
		}
		box := p.Rect{cx + 8, cy + 8, SW_THUMB_W, SW_THUMB_H}
		draw_thumb(cv, t, box, t.minimized ? 0.45 : 1)
		draw_app_icon(cv, f, t, box.x + box.w - 26, box.y + box.h - 26, 22, t.minimized ? 0.5 : 1)
		label := ellipsize_end(f, title_of(t), 12, .Medium, cell_w - 20)
		lw := p.text_width(f, label, 12, .Sans, .Medium)
		p.draw_text(cv, f, label, cx + (cell_w - lw) / 2, cy + cell_h - 14, 12, p.hex(t.minimized ? 0x71717a : 0xe4e4e7), .Sans, .Medium)
		if sw.all {
			if idx := ws_index_of(s, t); idx >= 0 {
				tag := s.workspaces[idx].name
				p.fill_round_rect(cv, {box.x + 4, box.y + 4, 18, 16}, {4, 4, 4, 4}, p.hexa(0x000000aa))
				p.draw_text(cv, f, tag, box.x + 9, box.y + 16, 10.5, p.hex(0xc7d2fe), .Sans, .Semibold)
			}
		}
	}
}

// draw_thumb draws a window's last buffer scaled to fit a box, centred.
draw_thumb :: proc(cv: ^p.Canvas, t: ^Toplevel, box: p.Rect, alpha: f32) {
	if t.xdg == nil || t.xdg.surf == nil || t.xdg.surf.img == nil {
		p.fill_round_rect(cv, box, {6, 6, 6, 6}, p.hex(0x18181b))
		return
	}
	surf := t.xdg.surf
	iw, ih := f32(surf.iw), f32(surf.ih)
	if iw <= 0 || ih <= 0 {
		return
	}
	sc := min(box.w / iw, box.h / ih, 1)
	w := iw * sc
	h := ih * sc
	r := p.Rect{box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h}
	p.drop_shadow(cv, r, {4, 4, 4, 4}, 10, 0, {0, 3}, p.hexa(0x00000080))
	blit_scaled(cv, surf.img, surf.iw, surf.ih, r, alpha)
}
