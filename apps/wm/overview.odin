// overview.odin — every window of the workspace at once (UX.md P1-2).
//
// Opened by a lone tap of Super, by Super+W, by the brand in the bar, or by
// pushing the pointer into the top-left hot corner. The workspace's windows
// are laid out scaled down, without overlap, keeping roughly their relative
// positions (a grid filled in order of the windows' centres), each with its
// title. Above them, a strip of workspace thumbnails, the current one
// outlined, plus an empty one at the end.
//
//   - click a window: focus it and close the overview; middle-click: close
//     the window
//   - drag a window onto a workspace thumbnail: move it there
//   - click a workspace thumbnail: switch to it, staying in the overview
//   - type to filter by title and app id; Enter focuses the first match, or
//     opens the launcher when nothing matches
//   - arrows move the selection; Escape or Super closes
//
// The windows fly from where they are to their overview rectangles in
// 180 ms on the way in.
package wm

import "core:math"
import "core:slice"
import "core:strings"
import p "palmy:."

OV_STRIP_H :: 96
OV_ANIM :: 0.18

Ov_Item :: struct {
	t:    ^Toplevel,
	rect: p.Rect, // the window's scaled rectangle (content, title bar above)
	from: p.Rect, // where it flew from
}

Overview :: struct {
	open:     bool,
	out:      int,
	items:    [dynamic]Ov_Item,
	ws_rects: [dynamic]p.Rect,
	sel:      int,
	hover:    int,
	filter:   strings.Builder,
	t0:       f64,
	built_ws: int,
	press_i:  int,
	press_at: [2]int,
	dragging: bool,
}

ov: Overview

overview_active :: proc(s: ^Server, oi: int) -> bool {
	return ov.open && ov.out == oi
}

overview_toggle :: proc(s: ^Server) {
	if ov.open {
		overview_close(s)
		return
	}
	if session.kiosk {
		return
	}
	menu_close(s)
	ov.open = true
	ov.out = s.cur_out
	ov.sel = 0
	ov.hover = -1
	ov.press_i = -1
	ov.dragging = false
	strings.builder_reset(&ov.filter)
	ov.t0 = wall_now()
	ov.built_ws = -1
	overview_layout(s)
	// Start the selection on the focused window.
	for it, i in ov.items {
		if it.t == s.focus {
			ov.sel = i
		}
	}
	s.dirty = true
}

overview_close :: proc(s: ^Server) {
	ov.open = false
	clear(&ov.items)
	clear(&ov.ws_rects)
	s.dirty = true
}

overview_forget :: proc(s: ^Server, t: ^Toplevel) {
	if !ov.open {
		return
	}
	for it, i in ov.items {
		if it.t == t {
			ordered_remove(&ov.items, i)
			break
		}
	}
	ov.built_ws = -1
}

// ov_grid is the layout, pure: n boxes of aspect ratios `aspect` (w / h)
// placed into an area as a grid, rows filled in the order given, each box
// as large as its cell allows but never larger than max_w x max_h.
ov_grid :: proc(area: p.Rect, sizes: [][2]f32, gap: f32, out: []p.Rect) {
	n := len(sizes)
	if n == 0 {
		return
	}
	cols := int(math.ceil(math.sqrt(f32(n) * area.w / max(area.h, 1) * 0.75)))
	cols = clamp(cols, 1, n)
	rows := (n + cols - 1) / cols
	cw := (area.w - gap * f32(cols - 1)) / f32(cols)
	ch := (area.h - gap * f32(rows - 1)) / f32(rows)
	for i in 0 ..< n {
		r := i / cols
		in_row := min(cols, n - r * cols)
		c := i % cols
		// A short last row is centred rather than left-aligned.
		row_w := f32(in_row) * cw + gap * f32(in_row - 1)
		x0 := area.x + (area.w - row_w) / 2
		cell := p.Rect{x0 + f32(c) * (cw + gap), area.y + f32(r) * (ch + gap), cw, ch - 26}
		w, h := sizes[i].x, sizes[i].y
		sc := min(cell.w / max(w, 1), cell.h / max(h, 1), 1)
		bw, bh := w * sc, h * sc
		out[i] = {cell.x + (cell.w - bw) / 2, cell.y + (cell.h - bh) / 2, bw, bh}
	}
}

overview_layout :: proc(s: ^Server) {
	clear(&ov.items)
	clear(&ov.ws_rects)
	ov.built_ws = s.cur_ws
	o := s.outputs[ov.out]
	top := f32(o.y + ws_bar_h(s))

	// The workspace strip: one thumbnail per workspace on this output, plus
	// an empty one at the end that stands for "a new workspace".
	n_ws := 0
	for w in s.workspaces {
		if w.output == ov.out {
			n_ws += 1
		}
	}
	th := f32(OV_STRIP_H - 24)
	tw := th * f32(o.w) / f32(max(o.h, 1))
	tw = min(tw, (f32(o.w) - 40) / f32(n_ws + 1) - 10)
	th = tw * f32(o.h) / f32(max(o.w, 1))
	total := f32(n_ws + 1) * (tw + 10) - 10
	x := f32(o.x) + (f32(o.w) - total) / 2
	for w in s.workspaces {
		if w.output != ov.out {
			continue
		}
		append(&ov.ws_rects, p.Rect{x, top + 14, tw, th})
		x += tw + 10
	}
	append(&ov.ws_rects, p.Rect{x, top + 14, tw, th})

	// The windows, sorted by their centres (top to bottom, then left to
	// right), so the overview keeps roughly the arrangement on screen.
	wins := make([dynamic]^Toplevel, 0, 16, context.temp_allocator)
	for t in s.stack {
		if t.mapped && !t.minimized {
			append(&wins, t)
		}
	}
	for t in s.stack {
		if t.mapped && t.minimized {
			append(&wins, t)
		}
	}
	slice.stable_sort_by(wins[:], proc(a, b: ^Toplevel) -> bool {
		if a.minimized != b.minimized {
			return !a.minimized
		}
		ay := (a.y + a.h / 2) / 200
		by := (b.y + b.h / 2) / 200
		if ay != by {
			return ay < by
		}
		return a.x + a.w / 2 < b.x + b.w / 2
	})
	area := p.Rect{f32(o.x) + 48, top + OV_STRIP_H + 52, f32(o.w) - 96, f32(o.h) - (top - f32(o.y)) - OV_STRIP_H - 84}
	sizes := make([][2]f32, len(wins), context.temp_allocator)
	for t, i in wins {
		fr := frame_rect(t)
		sizes[i] = {fr.w, fr.h}
	}
	rects := make([]p.Rect, len(wins), context.temp_allocator)
	ov_grid(area, sizes, 28, rects)
	for t, i in wins {
		append(&ov.items, Ov_Item{t = t, rect = rects[i], from = frame_rect(t)})
	}
	ov.sel = clamp(ov.sel, 0, max(len(ov.items) - 1, 0))
}

ov_matches :: proc(t: ^Toplevel) -> bool {
	q := strings.to_string(ov.filter)
	if q == "" {
		return true
	}
	lq := strings.to_lower(q, context.temp_allocator)
	return strings.contains(strings.to_lower(t.title, context.temp_allocator), lq) || strings.contains(strings.to_lower(t.app_id, context.temp_allocator), lq)
}

ov_first_match :: proc() -> int {
	if ov.sel >= 0 && ov.sel < len(ov.items) && ov_matches(ov.items[ov.sel].t) {
		return ov.sel
	}
	for it, i in ov.items {
		if ov_matches(it.t) {
			return i
		}
	}
	return -1
}

ov_pick :: proc(s: ^Server, i: int) {
	if i < 0 || i >= len(ov.items) {
		return
	}
	t := ov.items[i].t
	overview_close(s)
	focus_window(s, t)
	ix_reveal(s, t)
}

// ov_item_rect is where item i is drawn now, mid-flight on the way in.
ov_item_rect :: proc(s: ^Server, it: Ov_Item) -> p.Rect {
	if anim_mode(s) != .On {
		return it.rect
	}
	k := f32(clamp((wall_now() - ov.t0) / OV_ANIM, 0, 1))
	if k < 1 {
		anim_keep_going()
	}
	return lerp_rect(it.from, it.rect, ease_out(k))
}

overview_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !ov.open {
		return false
	}
	if ov.built_ws != s.cur_ws {
		overview_layout(s)
	}
	px, py := f32(mp.x), f32(mp.y)
	hover := -1
	for it, i in ov.items {
		if p.rect_contains(p.rect_inset(it.rect, -4), px, py) {
			hover = i
		}
	}
	if hover != ov.hover {
		ov.hover = hover
		s.dirty = true
	}
	ws_hit := -1
	for r, i in ov.ws_rects {
		if p.rect_contains(r, px, py) {
			ws_hit = i
		}
	}
	if in_.pressed[.Left] {
		ov.press_i = hover
		ov.press_at = mp
		ov.dragging = false
		if hover < 0 && ws_hit >= 0 {
			ov_switch_to(s, ws_hit)
		} else if hover < 0 && ws_hit < 0 && py > f32(s.outputs[ov.out].y + ws_bar_h(s)) {
			overview_close(s)
			ix.mode = .Swallow
			return true
		}
	}
	if in_.down[.Left] && ov.press_i >= 0 && !ov.dragging {
		if abs(mp.x - ov.press_at.x) > DRAG_THRESHOLD || abs(mp.y - ov.press_at.y) > DRAG_THRESHOLD {
			ov.dragging = true
		}
	}
	if ov.dragging {
		s.dirty = true
	}
	if in_.released[.Left] && ov.press_i >= 0 {
		i := ov.press_i
		ov.press_i = -1
		if ov.dragging {
			ov.dragging = false
			if ws_hit >= 0 && i < len(ov.items) {
				target := ov_ws_index(s, ws_hit)
				if target >= 0 {
					ws_move_to(s, ov.items[i].t, target)
					overview_layout(s)
				}
			}
		} else if i == hover {
			ov_pick(s, i)
			ix.mode = .Swallow
		}
	}
	if in_.pressed[.Middle] && hover >= 0 {
		close_window(s, ov.items[hover].t)
	}
	return true
}

// ov_ws_index maps a strip thumbnail to a workspace index; the last, empty
// thumbnail is the first empty workspace.
ov_ws_index :: proc(s: ^Server, strip: int) -> int {
	k := 0
	for w, i in s.workspaces {
		if w.output != ov.out {
			continue
		}
		if k == strip {
			return i
		}
		k += 1
	}
	for _, i in s.workspaces {
		if s.workspaces[i].output == ov.out && ws_count_on(s, i) == 0 && i != s.cur_ws {
			return i
		}
	}
	return -1
}

ov_switch_to :: proc(s: ^Server, strip: int) {
	if idx := ov_ws_index(s, strip); idx >= 0 && idx != s.cur_ws {
		ws_switch(s, idx)
		anim_state.ws_active = false
		ov.t0 = wall_now() - OV_ANIM
		overview_layout(s)
	}
}

overview_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event) -> bool {
	if !ov.open {
		return false
	}
	switch k.sym {
	case KEY_SUPER_L, KEY_SUPER_R:
		// The tap that closes the overview is decided on release
		// (handle_keys); the press itself is just swallowed.
	case p.KEY_ESCAPE:
		if len(strings.to_string(ov.filter)) > 0 {
			strings.builder_reset(&ov.filter)
		} else {
			overview_close(s)
		}
	case p.KEY_RETURN:
		if i := ov_first_match(); i >= 0 {
			ov_pick(s, i)
		} else {
			q := strings.clone(strings.to_string(ov.filter), context.temp_allocator)
			overview_close(s)
			ix.launch_at = wall_now()
			if q != "" {
				spawn(s, {"launcher", q})
			} else {
				spawn(s, {"launcher"})
			}
		}
	case p.KEY_BACKSPACE:
		b := &ov.filter
		if n := len(b.buf); n > 0 {
			resize(&b.buf, n - 1)
		}
	case p.KEY_LEFT, p.KEY_UP:
		ov_move_sel(-1)
	case p.KEY_RIGHT, p.KEY_DOWN, p.KEY_TAB:
		ov_move_sel(1)
	case:
		if k.mods & {.Ctrl, .Alt, .Super} != {} {
			// A chord while the overview is open: close it and let the
			// binding run.
			overview_close(s)
			return false
		}
		if k.sym >= 0x20 && k.sym < 0x7f {
			strings.write_byte(&ov.filter, u8(k.sym))
			if i := ov_first_match(); i >= 0 {
				ov.sel = i
			}
		}
	}
	s.dirty = true
	return true
}

ov_move_sel :: proc(d: int) {
	n := len(ov.items)
	if n == 0 {
		return
	}
	i := ov.sel
	for _ in 0 ..< n {
		i = ((i + d) % n + n) % n
		if ov_matches(ov.items[i].t) {
			ov.sel = i
			return
		}
	}
}

overview_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, oi: int) {
	if ov.built_ws != s.cur_ws {
		overview_layout(s)
	}
	f := &app.fonts
	o := s.outputs[oi]
	top := f32(o.y + ws_bar_h(s))
	p.fill_rect(cv, {f32(o.x), top, f32(o.w), f32(o.h) - (top - f32(o.y))}, p.hexa(0x00000066))

	// The workspace strip.
	strip := 0
	for w, i in s.workspaces {
		if w.output != oi || strip >= len(ov.ws_rects) {
			continue
		}
		r := ov.ws_rects[strip]
		strip += 1
		draw_ws_thumb(s, cv, i, r)
		col := u32(i == s.cur_ws ? ACCENT : 0x3f3f46)
		p.stroke_round_rect(cv, p.rect_inset(r, -1), {6, 6, 6, 6}, i == s.cur_ws ? 2 : 1, p.hex(col))
		tw := p.text_width(f, w.name, 11, .Sans, .Semibold)
		p.draw_text(cv, f, w.name, r.x + (r.w - tw) / 2, r.y + r.h + 13, 11, p.hex(i == s.cur_ws ? 0xffffff : 0xa1a1aa), .Sans, .Semibold)
	}
	if strip < len(ov.ws_rects) {
		r := ov.ws_rects[strip]
		p.stroke_round_rect(cv, r, {6, 6, 6, 6}, 1, p.hex(0x3f3f46))
		p.draw_line(cv, r.x + r.w / 2 - 7, r.y + r.h / 2, r.x + r.w / 2 + 7, r.y + r.h / 2, 1.5, p.hex(0x71717a))
		p.draw_line(cv, r.x + r.w / 2, r.y + r.h / 2 - 7, r.x + r.w / 2, r.y + r.h / 2 + 7, 1.5, p.hex(0x71717a))
	}

	// The search field, once something has been typed.
	q := strings.to_string(ov.filter)
	if q != "" {
		w := max(p.text_width(f, q, 14, .Sans, .Medium) + 40, 240)
		r := p.Rect{f32(o.x) + (f32(o.w) - w) / 2, top + OV_STRIP_H + 10, w, 30}
		p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(0x18181b))
		p.stroke_round_rect(cv, r, {8, 8, 8, 8}, 1, p.hex(ACCENT))
		p.draw_text(cv, f, q, r.x + 14, r.y + 20, 14, p.hex(0xfafafa), .Sans, .Medium)
	}

	if len(ov.items) == 0 {
		msg := "no windows on this workspace"
		mw := p.text_width(f, msg, 14, .Sans, .Medium)
		p.draw_text(cv, f, msg, f32(o.x) + (f32(o.w) - mw) / 2, f32(o.y) + f32(o.h) / 2, 14, p.hex(0xa1a1aa), .Sans, .Medium)
	}
	for it, i in ov.items {
		if ov.dragging && i == ov.press_i {
			continue
		}
		r := ov_item_rect(s, it)
		match := ov_matches(it.t)
		alpha := f32(match ? 1 : 0.3)
		if it.t.minimized {
			alpha *= 0.6
		}
		draw_ov_window(s, app, cv, it.t, r, alpha)
		if (i == ov.sel || i == ov.hover) && match {
			p.stroke_round_rect(cv, p.rect_inset(r, -3), {8, 8, 8, 8}, 2, p.hex(i == ov.sel ? ACCENT : 0x71717a))
		}
		label := ellipsize_end(f, title_of(it.t), 12, .Medium, max(r.w, 120))
		lw := p.text_width(f, label, 12, .Sans, .Medium)
		lx := r.x + (r.w - lw) / 2
		p.fill_round_rect(cv, {lx - 8, r.y + r.h + 6, lw + 16, 20}, {6, 6, 6, 6}, p.hexa(0x000000aa))
		p.draw_text(cv, f, label, lx, r.y + r.h + 20, 12, p.hex(match ? 0xfafafa : 0x71717a), .Sans, .Medium)
	}
	if ov.dragging && ov.press_i >= 0 && ov.press_i < len(ov.items) {
		it := ov.items[ov.press_i]
		w := it.rect.w * 0.6
		h := it.rect.h * 0.6
		draw_ov_window(s, app, cv, it.t, {f32(s_pointer.x) - w / 2, f32(s_pointer.y) - h / 2, w, h}, 0.85)
	}
}

// draw_ov_window draws a window's scaled render (frame included).
draw_ov_window :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel, r: p.Rect, alpha: f32) {
	p.drop_shadow(cv, r, {8, 8, 8, 8}, 18, 0, {0, 6}, p.hexa(0x00000080))
	if px, w, h, ok := anim_render(s, app, t); ok {
		blit_scaled(cv, px, w, h, r, alpha)
	}
}

// draw_ws_thumb is a miniature of a workspace: its wallpaper and its
// windows' buffers, scaled.
draw_ws_thumb :: proc(s: ^Server, cv: ^p.Canvas, idx: int, r: p.Rect) {
	if s.bg != nil {
		blit_scaled(cv, s.bg, s.bg_w, s.bg_h, r, 1)
	}
	o := s.outputs[s.workspaces[idx].output]
	sx := r.w / f32(max(o.w, 1))
	sy := r.h / f32(max(o.h, 1))
	for t in ws_stack(s, idx) {
		if !t.mapped || t.minimized {
			continue
		}
		fr := frame_rect(t)
		mr := p.Rect{r.x + (fr.x - f32(o.x)) * sx, r.y + (fr.y - f32(o.y)) * sy, fr.w * sx, fr.h * sy}
		p.fill_rect(cv, mr, p.hex(0x27272a))
		if t.xdg != nil && t.xdg.surf != nil && t.xdg.surf.img != nil {
			cr := content_rect(t)
			cm := p.Rect{r.x + (cr.x - f32(o.x)) * sx, r.y + (cr.y - f32(o.y)) * sy, cr.w * sx, cr.h * sy}
			blit_scaled(cv, t.xdg.surf.img, t.xdg.surf.iw, t.xdg.surf.ih, cm, 1)
		}
	}
}
