// popup.odin — xdg_popup and xdg_positioner.
//
// Every menu, <select>, tooltip, combo box and autocomplete list in GTK, Qt,
// Chromium and Firefox is an xdg_popup, and none of them has a fallback: a
// compositor that answers get_popup with an error kills the client the first
// time the user opens a menu. This is the whole of the protocol a browser
// needs:
//
//   - xdg_positioner keeps the rules (size, anchor rectangle, anchor edge,
//     gravity, offset, constraint adjustments, reactive, parent size); the
//     popup takes a copy at get_popup and at reposition, as the protocol says.
//   - Placement is relative to the parent's window geometry. When the result
//     does not fit the output the parent is on, the adjustments are tried in
//     the protocol's order per axis: flip, then slide, then resize.
//   - The first commit gets xdg_popup.configure + xdg_surface.configure; the
//     popup maps on the first buffer after that.
//   - grab: the popup takes the keyboard, and a click anywhere outside the
//     grabbing client's popups dismisses them (popup_done, topmost first) and
//     is not delivered. A popup whose parent goes away, or is unmapped, is
//     dismissed too.
//   - Popups are drawn above the windows and the bar, in the order they were
//     created (a submenu above its menu), and get the pointer first.
//   - zwlr_layer_surface_v1.get_popup parents a popup created with a null
//     parent to a layer surface (a bar's menus).
package wm

import "core:fmt"
import p "palmy:."

Positioner :: struct {
	w, h:           int,
	ax, ay, aw, ah: int, // the anchor rectangle, in parent geometry coordinates
	anchor:         u32,
	gravity:        u32,
	adjust:         u32,
	ox, oy:         int,
	reactive:       bool,
	parent_w:       int,
	parent_h:       int,
}

POS_SLIDE_X :: u32(1)
POS_SLIDE_Y :: u32(2)
POS_FLIP_X :: u32(4)
POS_FLIP_Y :: u32(8)
POS_RESIZE_X :: u32(16)
POS_RESIZE_Y :: u32(32)

Popup :: struct {
	client:       ^Client,
	id:           u32,
	ver:          u32,
	xdg:          ^Xdg_Surface, // its own
	parent:       ^Xdg_Surface, // a toplevel's or another popup's
	parent_layer: ^Layer_Surface,
	pos:          Positioner,
	// The placed geometry, relative to the parent's window geometry.
	x, y, w, h:   int,
	initial_sent: bool,
	mapped:       bool,
	grab:         bool,
	done:         bool, // popup_done sent; it stays until the client destroys it
	focus_back:   ^Surface, // keyboard focus to restore when it goes
}

popups: [dynamic]^Popup

// --- xdg_positioner ---------------------------------------------------------

req_positioner :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	ps := (^Positioner)(o.p)
	if ps == nil {
		return
	}
	switch op {
	case 0:
		obj_drop(c, id)
		free(ps)
	case 1:
		w, h := int(r_i32(r)), int(r_i32(r))
		if w <= 0 || h <= 0 {
			post_error(c, id, 0, "xdg_positioner.set_size with a non-positive size")
			return
		}
		ps.w, ps.h = w, h
	case 2:
		x, y, w, h := int(r_i32(r)), int(r_i32(r)), int(r_i32(r)), int(r_i32(r))
		if w < 0 || h < 0 {
			post_error(c, id, 0, "xdg_positioner.set_anchor_rect with a negative size")
			return
		}
		ps.ax, ps.ay, ps.aw, ps.ah = x, y, w, h
	case 3:
		a := r_u32(r)
		if a > 8 {
			post_error(c, id, 0, "xdg_positioner.set_anchor: invalid anchor")
			return
		}
		ps.anchor = a
	case 4:
		g := r_u32(r)
		if g > 8 {
			post_error(c, id, 0, "xdg_positioner.set_gravity: invalid gravity")
			return
		}
		ps.gravity = g
	case 5:
		ps.adjust = r_u32(r)
	case 6:
		ps.ox, ps.oy = int(r_i32(r)), int(r_i32(r))
	case 7:
		ps.reactive = true
	case 8:
		ps.parent_w, ps.parent_h = int(r_i32(r)), int(r_i32(r))
	case 9:
		r_u32(r) // set_parent_configure(serial): nothing to match it against
	}
}

positioner_new :: proc(c: ^Client, id, ver: u32) {
	ps := new(Positioner)
	if !obj_new(c, id, .Positioner, ver, ps) {
		free(ps)
	}
}

// --- placement --------------------------------------------------------------

pos_left :: proc(a: u32) -> bool {return a == 3 || a == 5 || a == 6}
pos_right :: proc(a: u32) -> bool {return a == 4 || a == 7 || a == 8}
pos_top :: proc(a: u32) -> bool {return a == 1 || a == 5 || a == 7}
pos_bottom :: proc(a: u32) -> bool {return a == 2 || a == 6 || a == 8}

// pos_flip_x swaps left and right in an anchor or a gravity; pos_flip_y top
// and bottom. The values are the protocol's: 1 top, 2 bottom, 3 left, 4 right,
// 5 top_left, 6 bottom_left, 7 top_right, 8 bottom_right.
pos_flip_x :: proc(a: u32) -> u32 {
	switch a {
	case 3: return 4
	case 4: return 3
	case 5: return 7
	case 7: return 5
	case 6: return 8
	case 8: return 6
	}
	return a
}

pos_flip_y :: proc(a: u32) -> u32 {
	switch a {
	case 1: return 2
	case 2: return 1
	case 5: return 6
	case 6: return 5
	case 7: return 8
	case 8: return 7
	}
	return a
}

// pos_unconstrained is the rectangle the rules ask for, before any adjustment.
pos_unconstrained :: proc(ps: Positioner, anchor, gravity: u32) -> [4]int {
	ax := ps.ax + ps.aw / 2
	if pos_left(anchor) {
		ax = ps.ax
	} else if pos_right(anchor) {
		ax = ps.ax + ps.aw
	}
	ay := ps.ay + ps.ah / 2
	if pos_top(anchor) {
		ay = ps.ay
	} else if pos_bottom(anchor) {
		ay = ps.ay + ps.ah
	}
	x := ax - ps.w / 2
	if pos_left(gravity) {
		x = ax - ps.w
	} else if pos_right(gravity) {
		x = ax
	}
	y := ay - ps.h / 2
	if pos_top(gravity) {
		y = ay - ps.h
	} else if pos_bottom(gravity) {
		y = ay
	}
	return {x + ps.ox, y + ps.oy, ps.w, ps.h}
}

// pos_place puts the popup inside `bounds` (both relative to the parent's
// geometry) using the adjustments the client allowed, one axis at a time:
// flip if the flipped rectangle fits, else slide, else resize.
pos_place :: proc(ps: Positioner, bounds: [4]int) -> [4]int {
	r := pos_unconstrained(ps, ps.anchor, ps.gravity)
	bx0, by0 := bounds[0], bounds[1]
	bx1, by1 := bounds[0] + bounds[2], bounds[1] + bounds[3]
	fits_x :: proc(r: [4]int, x0, x1: int) -> bool {return r[0] >= x0 && r[0] + r[2] <= x1}
	fits_y :: proc(r: [4]int, y0, y1: int) -> bool {return r[1] >= y0 && r[1] + r[3] <= y1}

	if !fits_x(r, bx0, bx1) {
		done := false
		if ps.adjust & POS_FLIP_X != 0 {
			f := pos_unconstrained(ps, pos_flip_x(ps.anchor), pos_flip_x(ps.gravity))
			if fits_x(f, bx0, bx1) {
				r[0] = f[0]
				done = true
			}
		}
		if !done && ps.adjust & POS_SLIDE_X != 0 {
			// Slide towards the side it overflows; if it is wider than the
			// output, keep its left edge visible.
			if r[0] + r[2] > bx1 {
				r[0] = bx1 - r[2]
			}
			if r[0] < bx0 {
				r[0] = bx0
			}
			done = fits_x(r, bx0, bx1)
		}
		if !done && ps.adjust & POS_RESIZE_X != 0 {
			x0 := max(r[0], bx0)
			x1 := min(r[0] + r[2], bx1)
			if x1 > x0 {
				r[0], r[2] = x0, x1 - x0
			}
		}
	}
	if !fits_y(r, by0, by1) {
		done := false
		if ps.adjust & POS_FLIP_Y != 0 {
			f := pos_unconstrained(ps, pos_flip_y(ps.anchor), pos_flip_y(ps.gravity))
			if fits_y(f, by0, by1) {
				r[1] = f[1]
				done = true
			}
		}
		if !done && ps.adjust & POS_SLIDE_Y != 0 {
			if r[1] + r[3] > by1 {
				r[1] = by1 - r[3]
			}
			if r[1] < by0 {
				r[1] = by0
			}
			done = fits_y(r, by0, by1)
		}
		if !done && ps.adjust & POS_RESIZE_Y != 0 {
			y0 := max(r[1], by0)
			y1 := min(r[1] + r[3], by1)
			if y1 > y0 {
				r[1], r[3] = y0, y1 - y0
			}
		}
	}
	return r
}

// --- where things are -------------------------------------------------------

// xdg_geom_origin is where an xdg surface's window geometry starts, in layout
// pixels: a toplevel's content rectangle, or a popup's placed rectangle.
xdg_geom_origin :: proc(x: ^Xdg_Surface) -> (ox, oy: int, ok: bool) {
	if x == nil {
		return 0, 0, false
	}
	if t := x.top; t != nil {
		return t.x, t.y, t.mapped
	}
	if pp := x.popup; pp != nil {
		return popup_origin(pp)
	}
	return 0, 0, false
}

// popup_origin is where a popup's geometry starts, in layout pixels.
popup_origin :: proc(pp: ^Popup) -> (ox, oy: int, ok: bool) {
	if pp.parent_layer != nil {
		ls := pp.parent_layer
		if !ls.mapped {
			return 0, 0, false
		}
		return ls.x + pp.x, ls.y + pp.y, true
	}
	px, py, pok := xdg_geom_origin(pp.parent)
	return px + pp.x, py + pp.y, pok
}

// popup_surface_origin is where the popup's surface is drawn: its geometry's
// origin less its own window-geometry offset.
popup_surface_origin :: proc(pp: ^Popup) -> (int, int, bool) {
	x, y, ok := popup_origin(pp)
	if pp.xdg != nil && pp.xdg.geom_set {
		x -= pp.xdg.gx
		y -= pp.xdg.gy
	}
	return x, y, ok
}

// popup_root is the toplevel at the bottom of a popup chain, or nil for one
// that hangs off a layer surface.
popup_root :: proc(pp: ^Popup) -> ^Toplevel {
	q := pp
	for i := 0; i < 32 && q != nil; i += 1 {
		if q.parent == nil {
			return nil
		}
		if q.parent.top != nil {
			return q.parent.top
		}
		q = q.parent.popup
	}
	return nil
}

// popup_visible: mapped, not dismissed, and its whole chain on screen.
popup_visible :: proc(s: ^Server, pp: ^Popup) -> bool {
	if !pp.mapped || pp.done || pp.xdg == nil || pp.xdg.surf == nil {
		return false
	}
	if pp.parent_layer != nil {
		return pp.parent_layer.mapped
	}
	t := popup_root(pp)
	if t == nil || !t.mapped || t.minimized || !ws_on_current(s, t) {
		return false
	}
	_, _, ok := popup_origin(pp)
	return ok
}

// popup_bounds is the output the popup's parent is on, relative to the
// parent's geometry origin: what the popup must stay inside.
popup_bounds :: proc(s: ^Server, pp: ^Popup) -> [4]int {
	px, py, _ := 0, 0, false
	if pp.parent_layer != nil {
		px, py = pp.parent_layer.x, pp.parent_layer.y
	} else {
		px, py, _ = xdg_geom_origin(pp.parent)
	}
	oi := ws_output_at(s, px, py)
	if oi >= 0 && oi < len(s.outputs) {
		o := s.outputs[oi]
		return {o.x - px, o.y - py, o.w, o.h}
	}
	return {-px, -py, s.out_w, s.out_h}
}

// --- xdg_surface.get_popup and xdg_popup ------------------------------------

popup_create :: proc(s: ^Server, c: ^Client, x: ^Xdg_Surface, id, parent_id, pos_id, ver: u32) {
	if x.top != nil || x.popup != nil {
		post_error(c, x.id, 1, "xdg_surface already has a role") // already_constructed
		return
	}
	pp := new(Popup)
	pp.client = c
	pp.id = id
	pp.ver = ver
	pp.xdg = x
	if parent_id != 0 {
		po, ok := obj_get(c, parent_id)
		if !ok || po.kind != .Xdg_Surface || po.p == nil {
			post_error(c, x.id, 0, "xdg_surface.get_popup: invalid parent")
			free(pp)
			return
		}
		pp.parent = (^Xdg_Surface)(po.p)
	}
	ps, pok := obj_get(c, pos_id)
	if !pok || ps.kind != .Positioner || ps.p == nil {
		post_error(c, x.id, 0, "xdg_surface.get_popup: invalid positioner")
		free(pp)
		return
	}
	pp.pos = (^Positioner)(ps.p)^
	if pp.pos.w <= 0 || pp.pos.h <= 0 {
		// xdg_wm_base.invalid_positioner
		for b in c.wm_bases {
			post_error(c, b, 5, "xdg_positioner without a size")
			break
		}
		free(pp)
		return
	}
	if !obj_new(c, id, .Popup, ver, pp) {
		free(pp)
		return
	}
	x.popup = pp
	append(&popups, pp)
	log_line("client %d: popup %d created", c.index, id)
}

// popup_place computes the geometry from the positioner.
popup_place :: proc(s: ^Server, pp: ^Popup) {
	r := pos_place(pp.pos, popup_bounds(s, pp))
	pp.x, pp.y, pp.w, pp.h = r[0], r[1], r[2], r[3]
}

// popup_configure sends xdg_popup.configure and xdg_surface.configure.
popup_configure :: proc(s: ^Server, pp: ^Popup) {
	popup_place(s, pp)
	event(pp.client, pp.id, 0, i32(pp.x), i32(pp.y), i32(pp.w), i32(pp.h))
	pp.xdg.serial = next_serial(s)
	event(pp.client, pp.xdg.id, 0, pp.xdg.serial)
	s.dirty = true
}

req_popup :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	pp := (^Popup)(o.p)
	if pp == nil {
		return
	}
	switch op {
	case 0:
		popup_destroy(s, pp)
		obj_drop(c, id)
	case 1:
		// grab(seat, serial). A popup can only grab while it is the topmost
		// of its client's chain and before it maps; a grab requested late is
		// dismissed at once, which is what the protocol prescribes.
		r_u32(r)
		serial := r_u32(r)
		if pp.mapped || !data_serial_ok(s, serial) {
			popup_dismiss(s, pp)
			return
		}
		pp.grab = true
	case 2:
		// reposition(positioner, token)
		pid := r_u32(r)
		token := r_u32(r)
		if po, ok := obj_get(c, pid); ok && po.kind == .Positioner && po.p != nil {
			pp.pos = (^Positioner)(po.p)^
			if pp.ver >= 3 {
				event(c, id, 2, token) // repositioned
			}
			popup_configure(s, pp)
		}
	}
}

// popup_commit runs on every commit of a popup's surface.
popup_commit :: proc(s: ^Server, pp: ^Popup) {
	surf := pp.xdg.surf
	if !pp.initial_sent {
		pp.initial_sent = true
		pp.xdg.initial_sent = true
		popup_configure(s, pp)
		return
	}
	has := surf != nil && surf.img != nil && surf.iw > 0
	if has && !pp.mapped && !pp.done {
		pp.mapped = true
		if pp.grab {
			// The grabbing popup gets the keyboard; it goes back when the
			// popup does.
			pp.focus_back = s.kbd_surf
			set_kbd_focus(s, surf)
		}
		if !surf.entered {
			surf.entered = true
			if oid := out_binding_id(pp.client, out_primary()); oid != 0 {
				event(pp.client, surf.id, 0, oid)
			}
		}
		s.dirty = true
		log_line("popup %d mapped at %d,%d %dx%d", pp.id, pp.x, pp.y, pp.w, pp.h)
	} else if !has && pp.mapped {
		popup_unmapped(s, pp)
	}
}

// popup_unmapped is a popup leaving the screen without being destroyed.
popup_unmapped :: proc(s: ^Server, pp: ^Popup) {
	pp.mapped = false
	if s.ptr_surf != nil && pp.xdg != nil && s.ptr_surf == pp.xdg.surf {
		set_ptr_focus(s, nil, 0, 0)
	}
	if pp.xdg != nil && s.kbd_surf == pp.xdg.surf {
		back := pp.focus_back
		if back == nil || !surface_alive(s, back) {
			if t := popup_root(pp); t != nil && t.xdg != nil {
				back = t.xdg.surf
			}
		}
		set_kbd_focus(s, back)
	}
	s.dirty = true
}

// popup_dismiss sends popup_done to a popup and everything above it.
popup_dismiss :: proc(s: ^Server, pp: ^Popup) {
	// Children first: a submenu is told before its menu.
	#reverse for q in popups {
		if q != pp && !q.done && popup_descends(q, pp) {
			popup_done(s, q)
		}
	}
	popup_done(s, pp)
}

popup_done :: proc(s: ^Server, pp: ^Popup) {
	if pp.done {
		return
	}
	pp.done = true
	if pp.mapped {
		popup_unmapped(s, pp)
	}
	if !pp.client.dead {
		event(pp.client, pp.id, 1) // popup_done
	}
	s.dirty = true
}

// popup_descends says whether q sits somewhere above pp in a chain.
popup_descends :: proc(q, pp: ^Popup) -> bool {
	cur := q
	for i := 0; i < 32 && cur != nil; i += 1 {
		if cur.parent == nil {
			return false
		}
		if cur.parent == pp.xdg {
			return true
		}
		cur = cur.parent.popup
	}
	return false
}

popup_destroy :: proc(s: ^Server, pp: ^Popup) {
	// Its children cannot outlive it on screen.
	#reverse for q in popups {
		if q != pp && popup_descends(q, pp) {
			popup_done(s, q)
		}
	}
	if pp.mapped {
		popup_unmapped(s, pp)
	}
	for q, i in popups {
		if q == pp {
			ordered_remove(&popups, i)
			break
		}
	}
	for q in popups {
		if q.parent != nil && q.parent == pp.xdg {
			q.parent = nil
		}
	}
	if pp.xdg != nil {
		pp.xdg.popup = nil
	}
	s.dirty = true
	free(pp)
}

// popup_xdg_gone is an xdg_surface being destroyed: a popup that hung off it
// is dismissed, and its own popup (if it was one) is forgotten.
popup_xdg_gone :: proc(s: ^Server, x: ^Xdg_Surface) {
	for q in popups {
		if q.parent == x {
			popup_done(s, q)
			q.parent = nil
		}
		if q.xdg == x {
			q.xdg = nil
		}
	}
}

// popup_layer_gone is the same for a layer surface.
popup_layer_gone :: proc(s: ^Server, ls: ^Layer_Surface) {
	for q in popups {
		if q.parent_layer == ls {
			popup_done(s, q)
			q.parent_layer = nil
		}
	}
}

// popup_client_gone drops every popup of a client that disconnected.
popup_client_gone :: proc(s: ^Server, c: ^Client) {
	for i := len(popups) - 1; i >= 0; i -= 1 {
		if popups[i].client == c {
			pp := popups[i]
			ordered_remove(&popups, i)
			free(pp)
		}
	}
}

// popup_layer_parent is zwlr_layer_surface_v1.get_popup.
popup_layer_parent :: proc(s: ^Server, c: ^Client, ls: ^Layer_Surface, popup_id: u32) {
	po, ok := obj_get(c, popup_id)
	if !ok || po.kind != .Popup || po.p == nil {
		return
	}
	pp := (^Popup)(po.p)
	pp.parent_layer = ls
}

surface_alive :: proc(s: ^Server, surf: ^Surface) -> bool {
	for x in s.surfaces {
		if x == surf {
			return true
		}
	}
	return false
}

// popup_tick dismisses popups whose parent left the screen.
popup_tick :: proc(s: ^Server) {
	for pp in popups {
		if pp.done || !pp.mapped {
			continue
		}
		if pp.parent == nil && pp.parent_layer == nil {
			popup_done(s, pp)
			continue
		}
		if pp.parent_layer == nil {
			if t := popup_root(pp); t == nil || !t.mapped || t.minimized {
				popup_done(s, pp)
			}
		}
	}
}

// --- drawing and input ------------------------------------------------------

popup_draw :: proc(s: ^Server, cv: ^p.Canvas) {
	for pp in popups {
		if !popup_visible(s, pp) {
			continue
		}
		x, y, _ := popup_surface_origin(pp)
		wm_reset_clip(cv)
		blit_surface(cv, pp.xdg.surf, x, y)
	}
	wm_reset_clip(cv)
}

// popup_at is the topmost visible popup surface under a point.
popup_at :: proc(s: ^Server, mx, my: int) -> (^Popup, ^Surface, int, int) {
	#reverse for pp in popups {
		if !popup_visible(s, pp) {
			continue
		}
		x, y, _ := popup_surface_origin(pp)
		if surf, lx, ly := pick_surface(pp.xdg.surf, x, y, mx, my); surf != nil {
			return pp, surf, lx, ly
		}
	}
	return nil, nil, 0, 0
}

// popup_grabbed is the topmost grabbing popup, if any is open.
popup_grabbed :: proc(s: ^Server) -> ^Popup {
	#reverse for pp in popups {
		if pp.grab && popup_visible(s, pp) {
			return pp
		}
	}
	return nil
}

// popup_pointer gives the pointer to popups before anything else in the
// window layer. Returns true when it took this frame's pointer input.
popup_pointer :: proc(s: ^Server, app: ^p.App, mp: [2]int, moved: bool) -> bool {
	if len(popups) == 0 {
		return false
	}
	in_ := &app.win.input
	pp, surf, lx, ly := popup_at(s, mp.x, mp.y)
	any_press := in_.pressed[.Left] || in_.pressed[.Right] || in_.pressed[.Middle]
	g := popup_grabbed(s)
	if surf == nil {
		if g != nil && any_press {
			// A click outside the grab: close the chain and swallow it.
			root := g
			for root.parent != nil && root.parent.popup != nil && root.parent.popup.grab {
				root = root.parent.popup
			}
			popup_dismiss(s, root)
			set_ptr_focus(s, nil, 0, 0)
			ix.mode = .Swallow
			return true
		}
		return false
	}
	_ = pp
	if surf != s.ptr_surf {
		set_ptr_focus(s, surf, lx, ly)
	} else if moved || in_.mouse_delta != {0, 0} {
		ptr_motion(s, lx, ly)
	}
	for btn in ([3]struct {
		b: p.Mouse_Button,
		c: u32,
	}{{.Left, BTN_LEFT}, {.Right, BTN_RIGHT}, {.Middle, BTN_MIDDLE}}) {
		if in_.pressed[btn.b] {
			ptr_button(s, btn.c, true)
		}
		if in_.released[btn.b] {
			ptr_button(s, btn.c, false)
		}
	}
	if scroll_pending(in_) {
		ptr_axis(s, in_.scroll.x, in_.scroll.y)
	}
	s.hover_t = nil
	s.hover_btn = 0
	ix.cursor = .Client
	return true
}

// popup_selftest checks the placement rules against the protocol's examples.
popup_selftest :: proc() -> (pass, fail: int) {
	check :: proc(pass, fail: ^int, cond: bool, f: string, args: ..any) {
		if cond {
			pass^ += 1
		} else {
			fail^ += 1
			fmt.printf("  FAIL popup: ")
			fmt.printfln(f, ..args)
		}
	}
	// A menu under a button at 100,10 20x20, anchored bottom-left with
	// gravity bottom-right: it hangs below the button's left edge.
	ps := Positioner{w = 200, h = 300, ax = 100, ay = 10, aw = 20, ah = 20, anchor = 6, gravity = 8}
	bounds := [4]int{-50, -50, 1280, 800}
	r := pos_place(ps, bounds)
	check(&pass, &fail, r == {100, 30, 200, 300}, "bottom-left anchor, bottom-right gravity: %v", r)
	// Centre anchor and gravity: centred on the anchor rectangle.
	ps2 := Positioner{w = 40, h = 20, ax = 0, ay = 0, aw = 100, ah = 100}
	check(&pass, &fail, pos_place(ps2, bounds) == {30, 40, 40, 20}, "centred: %v", pos_place(ps2, bounds))
	// Offset.
	ps2.ox, ps2.oy = 5, -7
	check(&pass, &fail, pos_place(ps2, bounds) == {35, 33, 40, 20}, "offset: %v", pos_place(ps2, bounds))
	// Near the bottom of the output: flip_y puts it above the button.
	ps3 := ps
	ps3.ay = 700
	ps3.adjust = POS_FLIP_Y
	r = pos_place(ps3, bounds)
	check(&pass, &fail, r == {100, 400, 200, 300}, "flip_y opens upwards: %v", r)
	// No flip allowed, slide_y: pushed up to fit.
	ps3.adjust = POS_SLIDE_Y
	r = pos_place(ps3, bounds)
	check(&pass, &fail, r[1] + r[3] == 750 && r[3] == 300, "slide_y keeps it inside: %v", r)
	// Neither: resize_y cuts it at the output's edge.
	ps3.adjust = POS_RESIZE_Y
	r = pos_place(ps3, bounds)
	check(&pass, &fail, r[1] == 720 && r[1] + r[3] == 750, "resize_y clips: %v", r)
	// Nothing allowed: left where the rules put it.
	ps3.adjust = 0
	check(&pass, &fail, pos_place(ps3, bounds) == {100, 720, 200, 300}, "no adjustment: unconstrained")
	// A submenu off the right edge: flip_x opens it to the left.
	ps4 := Positioner{w = 150, h = 100, ax = 1150, ay = 100, aw = 50, ah = 20, anchor = 7, gravity = 8, adjust = POS_FLIP_X | POS_SLIDE_Y}
	r = pos_place(ps4, bounds)
	check(&pass, &fail, r == {1000, 100, 150, 100}, "flip_x opens leftwards: %v", r)
	// A flip that does not fit either: slide instead when allowed.
	ps5 := Positioner{w = 1300, h = 10, ax = 600, ay = 0, aw = 0, ah = 0, anchor = 7, gravity = 8, adjust = POS_FLIP_X | POS_SLIDE_X}
	r = pos_place(ps5, bounds)
	check(&pass, &fail, r[0] == -50, "too wide for either side: slid to the left edge: %v", r)
	return
}
