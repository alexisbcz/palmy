// zwlr_layer_shell_v1 and zwlr_layer_surface_v1, server side.
//
// This is the protocol every desktop component is built out of: bars,
// wallpapers, notification daemons, launchers, on-screen displays. Without it
// a compositor can only run applications, never a desktop.
//
// The arrangement is the part worth getting right. Four layers stack around
// the ordinary toplevels — background and bottom below them, top and overlay
// above — and each surface is anchored to zero or more edges, inset by a
// margin, and may claim an exclusive zone that shrinks the area left for
// everything after it. The pass order is the one wlroots settled on: every
// exclusive-zone surface first, from the overlay layer down, then every
// non-exclusive surface in the same order, so a bar reserves its strip before
// a wallpaper is told how big it may be.
//
// palmy/wayland.odin is the client half of this same protocol, so `wm
// --overlay` talking to the host is the mirror image of what runs here.
package wm

import "core:fmt"
import "core:strings"
import p "palmy:."

LAYER_VERSION :: u32(4)

// Anchor bits, as the protocol numbers them.
LAYER_TOP :: u32(1)
LAYER_BOTTOM :: u32(2)
LAYER_LEFT :: u32(4)
LAYER_RIGHT :: u32(8)

// Layers, bottom to top. Ordinary toplevels sit between Bottom and Top.
Layer_Level :: enum u8 {
	Background = 0,
	Bottom     = 1,
	Top        = 2,
	Overlay    = 3,
}

Layer_Kbd :: enum u8 {
	None      = 0,
	Exclusive = 1,
	On_Demand = 2,
}

Layer_Surface :: struct {
	client:       ^Client,
	id:           u32,
	ver:          u32,
	surf:         ^Surface,
	out_global:   u32, // 0: we pick
	ns:           string,

	// Double-buffered request state. Everything a client sets is pending
	// until the next wl_surface.commit, exactly as the protocol says.
	p_w, p_h:     int,
	p_anchor:     u32,
	p_excl:       int,
	p_margin:     [4]int, // top, right, bottom, left
	p_kbd:        Layer_Kbd,
	p_layer:      Layer_Level,

	w, h:         int,
	anchor:       u32,
	excl:         int,
	margin:       [4]int,
	kbd:          Layer_Kbd,
	layer:        Layer_Level,

	// Arranged geometry, in compositor pixels.
	x, y:         int,
	cw, ch:       int,
	cfg_w, cfg_h: int,
	serial:       u32,
	acked:        u32,
	configured:   bool,
	mapped:       bool,
	closed:       bool,
}

layer_all: [dynamic]^Layer_Surface

// Set the first time `layer_draw` runs. See lock_maybe_locked.
layer_drawn_once: bool

// ---------------------------------------------------------------------------
// The work area
// ---------------------------------------------------------------------------

// layer_work_area shrinks one output's rectangle by the exclusive zones the
// layer surfaces on that output have claimed. Everything in the window manager
// that asks where a window may go goes through `ws_output_rect`, so that one
// procedure calling this one is the whole integration: placement, clamping,
// maximising, resizing and every tiling layout then respect a bar.
//
// The compositor's own bar is deliberately *not* subtracted here, because
// `ws_bar_h` is already taken off by the callers that care.
layer_work_area :: proc(s: ^Server, ox, oy, ow, oh: int) -> (x, y, w, h: int) {
	o := out_at(ox + ow / 2, oy + oh / 2)
	if o == nil {
		return ox, oy, ow, oh
	}
	return ox + o.ins[0],
		oy + o.ins[1],
		max(ow - o.ins[0] - o.ins[2], 1),
		max(oh - o.ins[1] - o.ins[3], 1)
}

// layer_output_of is the head a layer surface belongs to. A client that did
// not name one gets the primary head.
layer_output_of :: proc(ls: ^Layer_Surface) -> ^Out_Output {
	if ls.out_global != 0 {
		if o := out_by_global(ls.out_global); o != nil {
			return o
		}
	}
	return out_primary()
}

// ---------------------------------------------------------------------------
// Arrangement
// ---------------------------------------------------------------------------

// layer_arrange recomputes every layer surface's geometry and the work area
// left over. It is cheap and idempotent; `main.odin` calls it once per frame
// and whenever the output size changes.
layer_arrange :: proc(s: ^Server) {
	layer_purge(s)
	lock_purge(s)
	wm_purge_extras(s)
	out_sync(s)

	bar := ws_bar_h(s)
	order := [4]Layer_Level{.Overlay, .Top, .Bottom, .Background}
	changed := false

	for o in out_list {
		full := [4]int{o.x, o.y, o.w, o.h}
		// The compositor draws its own bar across the top of each head, so
		// that strip is spoken for before any client sees the usable area.
		usable := [4]int{o.x, o.y + bar, o.w, max(o.h - bar, 0)}

		for pass in 0 ..< 2 {
			want_exclusive := pass == 0
			for lvl in order {
				for ls in layer_all {
					if ls.closed || ls.layer != lvl {
						continue
					}
					if (ls.excl > 0) != want_exclusive {
						continue
					}
					if layer_output_of(ls) != o {
						continue
					}
					layer_place(s, ls, full, &usable)
				}
			}
		}

		if usable[2] < 0 {usable[2] = 0}
		if usable[3] < 0 {usable[3] = 0}
		ins := [4]int {
			usable[0] - o.x,
			max(usable[1] - o.y - bar, 0),
			(o.x + o.w) - (usable[0] + usable[2]),
			(o.y + o.h) - (usable[1] + usable[3]),
		}
		if ins != o.ins {
			o.ins = ins
			changed = true
		}
	}

	// A changed work area is the whole point of an exclusive zone, so it is
	// also the single place the windows under it get re-fitted. Doing it here
	// rather than at each caller is what makes a bar *disappearing* grow the
	// desktop back again: a client that died was noticed by `layer_purge`
	// above, and nothing else would have run afterwards.
	if changed {
		layer_reflow(s)
	}
}

layer_place :: proc(s: ^Server, ls: ^Layer_Surface, full: [4]int, usable: ^[4]int) {
	// An exclusive zone of -1 means "ignore everybody else's zones", which is
	// how a wallpaper or a lock-like overlay covers the whole head.
	bounds := ls.excl == -1 ? full : usable^

	a := ls.anchor
	both_h := a & (LAYER_LEFT | LAYER_RIGHT) == (LAYER_LEFT | LAYER_RIGHT)
	both_v := a & (LAYER_TOP | LAYER_BOTTOM) == (LAYER_TOP | LAYER_BOTTOM)

	x, y, w, h: int
	if ls.w == 0 {
		x = bounds[0]
		w = bounds[2]
	} else {
		w = ls.w
		switch {
		case a & LAYER_LEFT != 0 && !both_h:
			x = bounds[0]
		case a & LAYER_RIGHT != 0 && !both_h:
			x = bounds[0] + bounds[2] - w
		case:
			x = bounds[0] + (bounds[2] - w) / 2
		}
	}
	if ls.h == 0 {
		y = bounds[1]
		h = bounds[3]
	} else {
		h = ls.h
		switch {
		case a & LAYER_TOP != 0 && !both_v:
			y = bounds[1]
		case a & LAYER_BOTTOM != 0 && !both_v:
			y = bounds[1] + bounds[3] - h
		case:
			y = bounds[1] + (bounds[3] - h) / 2
		}
	}

	// Margins. Stretched between two edges they inset both sides; pinned to
	// one edge they push away from it.
	if both_h {
		x += ls.margin[3]
		w -= ls.margin[3] + ls.margin[1]
	} else if a & LAYER_LEFT != 0 {
		x += ls.margin[3]
	} else if a & LAYER_RIGHT != 0 {
		x -= ls.margin[1]
	}
	if both_v {
		y += ls.margin[0]
		h -= ls.margin[0] + ls.margin[2]
	} else if a & LAYER_TOP != 0 {
		y += ls.margin[0]
	} else if a & LAYER_BOTTOM != 0 {
		y -= ls.margin[2]
	}

	w = max(w, 0)
	h = max(h, 0)
	ls.x, ls.y, ls.cw, ls.ch = x, y, w, h

	// Only a surface that is actually on screen may take space away from the
	// windows; a bar that has not mapped yet must not shrink the desktop.
	if ls.mapped {
		layer_apply_exclusive(usable, ls)
	}

	if !ls.closed && (w != ls.cfg_w || h != ls.cfg_h || !ls.configured) {
		layer_configure(s, ls, w, h)
	}
}

// layer_apply_exclusive shrinks the usable area by one surface's exclusive
// zone. A zone only counts when the surface is anchored to exactly one edge,
// or to that edge plus the two perpendicular ones — anything else has no
// unambiguous edge to reserve against.
layer_apply_exclusive :: proc(usable: ^[4]int, ls: ^Layer_Surface) {
	if ls.excl <= 0 {
		return
	}
	Edge_Rule :: struct {
		single, triple: u32,
		horizontal:     bool,
		positive:       bool,
		margin:         int,
	}
	rules := [4]Edge_Rule {
		{LAYER_TOP, LAYER_LEFT | LAYER_RIGHT | LAYER_TOP, false, true, ls.margin[0]},
		{LAYER_BOTTOM, LAYER_LEFT | LAYER_RIGHT | LAYER_BOTTOM, false, false, ls.margin[2]},
		{LAYER_LEFT, LAYER_TOP | LAYER_BOTTOM | LAYER_LEFT, true, true, ls.margin[3]},
		{LAYER_RIGHT, LAYER_TOP | LAYER_BOTTOM | LAYER_RIGHT, true, false, ls.margin[1]},
	}
	for rule in rules {
		if ls.anchor != rule.single && ls.anchor != rule.triple {
			continue
		}
		take := ls.excl + rule.margin
		if rule.horizontal {
			if rule.positive {
				usable[0] += take
			}
			usable[2] -= take
		} else {
			if rule.positive {
				usable[1] += take
			}
			usable[3] -= take
		}
		return
	}
}

layer_configure :: proc(s: ^Server, ls: ^Layer_Surface, w, h: int) {
	ls.cfg_w, ls.cfg_h = w, h
	ls.serial = next_serial(s)
	ls.configured = true
	event(ls.client, ls.id, 0, ls.serial, u32(w), u32(h))
}

// ---------------------------------------------------------------------------
// Stacking, drawing and hit testing
// ---------------------------------------------------------------------------

// layer_draw paints one half of the layer stack: the two layers below the
// windows, or the two above them. `main.odin` calls it either side of the
// toplevel loop in `draw`.
layer_draw :: proc(s: ^Server, cv: ^p.Canvas, above_windows: bool) {
	// Proof that the compositing loop is wired to this file. lock.odin
	// refuses to promise a locker that the screen is covered until it is.
	layer_drawn_once = true
	levels := above_windows ? [2]Layer_Level{.Top, .Overlay} : [2]Layer_Level{.Background, .Bottom}
	for lvl in levels {
		for ls in layer_all {
			if !ls.mapped || ls.layer != lvl || ls.surf == nil {
				continue
			}
			p.push_clip(cv, {f32(ls.x), f32(ls.y), f32(ls.cw), f32(ls.ch)})
			blit_surface(cv, ls.surf, ls.x, ls.y)
			p.pop_clip(cv)
		}
	}
}

// layer_surface_at finds the layer surface under a point, topmost first,
// within one half of the stack.
layer_surface_at :: proc(s: ^Server, mx, my: int, above_windows: bool) -> (^Surface, int, int) {
	levels := above_windows ? [2]Layer_Level{.Overlay, .Top} : [2]Layer_Level{.Bottom, .Background}
	for lvl in levels {
		#reverse for ls in layer_all {
			if !ls.mapped || ls.layer != lvl || ls.surf == nil {
				continue
			}
			if mx < ls.x || my < ls.y || mx >= ls.x + ls.cw || my >= ls.y + ls.ch {
				continue
			}
			if surf, lx, ly := pick_surface(ls.surf, ls.x, ls.y, mx, my); surf != nil {
				return surf, lx, ly
			}
		}
	}
	return nil, 0, 0
}

// layer_kbd_surface is the surface that must hold the keyboard while it
// exists: the topmost layer surface asking for exclusive interactivity. A
// launcher uses this; a bar normally does not.
layer_kbd_surface :: proc(s: ^Server) -> ^Surface {
	for lvl in ([2]Layer_Level{.Overlay, .Top}) {
		#reverse for ls in layer_all {
			if ls.mapped && ls.layer == lvl && ls.kbd == .Exclusive && ls.surf != nil {
				return ls.surf
			}
		}
	}
	return nil
}

// layer_claims_keyboard is the question `main.odin` has to ask before giving
// the keyboard to a window.
layer_claims_keyboard :: proc(s: ^Server) -> bool {
	return layer_kbd_surface(s) != nil
}

layer_refocus :: proc(s: ^Server) {
	if k := layer_kbd_surface(s); k != nil {
		set_kbd_focus(s, k)
		return
	}
	if s.focus != nil && s.focus.xdg != nil {
		set_kbd_focus(s, s.focus.xdg.surf)
	} else {
		set_kbd_focus(s, nil)
	}
}

// ---------------------------------------------------------------------------
// zwlr_layer_shell_v1
// ---------------------------------------------------------------------------

req_layer_shell :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// get_layer_surface(id, surface, output, layer, namespace)
		lid := r_u32(r)
		sid := r_u32(r)
		oid := r_u32(r)
		lvl := r_u32(r)
		ns := r_string(r)
		if r.bad {
			return
		}
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "zwlr_layer_shell_v1.get_layer_surface on a non-surface")
			return
		}
		if lvl > 3 {
			post_error(c, id, 1, fmt.tprintf("invalid layer %d", lvl))
			return
		}
		surf := (^Surface)(so.p)
		if surf.role != .None {
			post_error(c, id, 0, "the surface already has a role")
			return
		}
		if surf.img != nil {
			post_error(c, id, 2, "the surface already has a buffer attached")
			return
		}

		ls := new(Layer_Surface)
		ls.client = c
		ls.id = lid
		ls.ver = o.ver
		ls.surf = surf
		ls.ns = strings.clone(ns)
		ls.layer = Layer_Level(lvl)
		ls.p_layer = ls.layer
		ls.excl = 0
		ls.p_excl = 0
		if oid != 0 {
			if ob, found := obj_get(c, oid); found && ob.kind == .Output {
				ls.out_global = u32(uintptr(ob.p))
			}
		}
		if !obj_new(c, lid, .Layer_Surface, o.ver, ls) {
			delete(ls.ns)
			free(ls)
			return
		}
		surf.role = .Layer
		surf.layer = ls
		append(&layer_all, ls)
		log_line("client %d: layer surface %q on layer %d", c.index, ns, lvl)
	case 1:
		obj_drop(c, id)
	}
}

req_layer_surface :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	ls := (^Layer_Surface)(o.p)
	if ls == nil {
		return
	}
	switch op {
	case 0:
		// set_size(width, height)
		ls.p_w = int(r_u32(r))
		ls.p_h = int(r_u32(r))
	case 1:
		// set_anchor(anchor)
		a := r_u32(r)
		if a > 15 {
			post_error(c, id, 0, fmt.tprintf("invalid anchor 0x%x", a))
			return
		}
		ls.p_anchor = a
	case 2:
		// set_exclusive_zone(zone)
		ls.p_excl = int(r_i32(r))
	case 3:
		// set_margin(top, right, bottom, left)
		ls.p_margin[0] = int(r_i32(r))
		ls.p_margin[1] = int(r_i32(r))
		ls.p_margin[2] = int(r_i32(r))
		ls.p_margin[3] = int(r_i32(r))
	case 4:
		// set_keyboard_interactivity(mode)
		m := r_u32(r)
		if m > 2 || (o.ver < 4 && m > 1) {
			post_error(c, id, 2, fmt.tprintf("invalid keyboard interactivity %d", m))
			return
		}
		ls.p_kbd = Layer_Kbd(m)
	case 5:
		// get_popup(popup): a popup made with a null parent hangs off this
		popup_layer_parent(s, c, ls, r_u32(r))
	case 6:
		// ack_configure(serial)
		ls.acked = r_u32(r)
	case 7:
		layer_destroy(s, c, ls, id)
	case 8:
		// set_layer(layer)
		lvl := r_u32(r)
		if lvl > 3 {
			post_error(c, id, 1, fmt.tprintf("invalid layer %d", lvl))
			return
		}
		ls.p_layer = Layer_Level(lvl)
	case 9:
		// set_exclusive_edge(edge), version 5. Accepted and ignored: we derive
		// the edge from the anchor, which is what every real client sets too.
		r_u32(r)
	}
}

// layer_commit applies the pending request state. Called from surface_commit,
// so it runs at exactly the point the protocol says these take effect.
layer_commit :: proc(s: ^Server, ls: ^Layer_Surface) {
	ls.w, ls.h = ls.p_w, ls.p_h
	ls.anchor = ls.p_anchor
	ls.excl = ls.p_excl
	ls.margin = ls.p_margin
	ls.kbd = ls.p_kbd
	ls.layer = ls.p_layer

	both_h := ls.anchor & (LAYER_LEFT | LAYER_RIGHT) == (LAYER_LEFT | LAYER_RIGHT)
	both_v := ls.anchor & (LAYER_TOP | LAYER_BOTTOM) == (LAYER_TOP | LAYER_BOTTOM)
	if (ls.w == 0 && !both_h) || (ls.h == 0 && !both_v) {
		post_error(
			ls.client,
			ls.id,
			3,
			"a zero size needs the opposite edges anchored (zwlr_layer_surface_v1 invalid_size)",
		)
		return
	}

	has := ls.surf != nil && ls.surf.img != nil && ls.surf.iw > 0
	was := ls.mapped
	geom := [4]int{ls.x, ls.y, ls.cw, ls.ch}

	if !ls.configured {
		layer_arrange(s)
		return
	}
	ls.mapped = has && !ls.closed
	layer_arrange(s)

	if ls.mapped != was {
		log_line("layer surface %q %s at %d,%d %dx%d", ls.ns, ls.mapped ? "mapped" : "unmapped", ls.x, ls.y, ls.cw, ls.ch)
		layer_refocus(s)
	}
	// A commit that only changed the pixels is the surface's own damage
	// (damage_commit); one that moved, resized or (un)mapped it is a layout
	// change.
	if !session.bare || ls.mapped != was || geom != ([4]int{ls.x, ls.y, ls.cw, ls.ch}) {
		s.dirty = true
	}
}

// layer_reflow re-fits the windows after the work area moved, so a bar
// appearing or disappearing actually moves what is underneath it.
//
// A maximised window is unmaximised and maximised again rather than having its
// geometry recomputed here. That is deliberate: it costs one extra configure
// and in exchange the restore geometry in `saved` survives untouched, and the
// arithmetic stays in `set_maximized` where the border and title heights are
// already known per window.
layer_reflow :: proc(s: ^Server) {
	for t in s.stack {
		if !t.mapped || t.client == nil || t.client.dead {
			continue
		}
		if t.maximized {
			set_maximized(s, t, false)
			set_maximized(s, t, true)
		} else {
			// A floating window keeps its place, but a bar appearing must not
			// swallow its title bar: that is the only way to move it again.
			clamp_window(s, t)
		}
	}
	s.needs_layout = true
	s.dirty = true
}

layer_destroy :: proc(s: ^Server, c: ^Client, ls: ^Layer_Surface, id: u32) {
	popup_layer_gone(s, ls)
	if ls.surf != nil {
		if s.ptr_surf == ls.surf {
			set_ptr_focus(s, nil, 0, 0)
		}
		ls.surf.role = .None
		ls.surf.layer = nil
		ls.surf = nil
	}
	ls.closed = true
	ls.mapped = false
	for x, i in layer_all {
		if x == ls {
			ordered_remove(&layer_all, i)
			break
		}
	}
	obj_drop(c, id)
	delete(ls.ns)
	free(ls)
	layer_arrange(s)
	layer_refocus(s)
	s.dirty = true
}

// layer_close asks a layer surface to go away — the compositor's side of the
// handshake, used when its output disappears.
layer_close :: proc(s: ^Server, ls: ^Layer_Surface) {
	if ls.closed {
		return
	}
	ls.closed = true
	ls.mapped = false
	event(ls.client, ls.id, 1) // closed
	s.dirty = true
}

// layer_purge drops the bookkeeping for clients that have gone away.
// `client_free` frees a client's surfaces directly without routing through
// `surface_destroy`, so this runs first in every arrange.
layer_purge :: proc(s: ^Server) {
	for i := len(layer_all) - 1; i >= 0; i -= 1 {
		ls := layer_all[i]
		alive := false
		for c in s.clients {
			if c == ls.client && !c.dead {
				alive = true
				break
			}
		}
		if alive {
			continue
		}
		ordered_remove(&layer_all, i)
		delete(ls.ns)
		free(ls)
	}
}

// ---------------------------------------------------------------------------
// The seam with main.odin
//
// Two procedures, so the compositor's own input loop only has to ask one
// question before it does anything else: did something above the windows take
// this event? Everything about layers and locks stays on this side of them.
// ---------------------------------------------------------------------------

// overlay_pointer routes the pointer to a lock surface or a layer surface.
// It returns true when the event has been consumed and the window manager's
// own hit testing must not run — which, while the session is locked, is
// always, whether or not there is a surface under the cursor.
overlay_pointer :: proc(s: ^Server, app: ^p.App, mp: [2]int) -> bool {
	in_ := &app.win.input
	surf: ^Surface
	lx, ly: int
	locked := lock_active()
	if locked {
		surf, lx, ly = lock_surface_at(s, mp.x, mp.y)
	} else {
		surf, lx, ly = layer_surface_at(s, mp.x, mp.y, true)
	}
	if surf == nil {
		if locked {
			set_ptr_focus(s, nil, 0, 0)
			if locker_internal() {
				locker_pointer(s, app, mp)
			}
			return true
		}
		return false
	}

	if surf != s.ptr_surf {
		set_ptr_focus(s, surf, lx, ly)
		pconf_update(s)
	} else if in_.mouse_delta != {0, 0} {
		if !pconf_pointer_locked(s) {
			ptr_motion(s, lx, ly)
		}
		relp_motion(s, surf, in_.mouse_delta.x, in_.mouse_delta.y)
	}

	for btn, code in ([3]struct {
		b: p.Mouse_Button,
		c: u32,
	}{{.Left, BTN_LEFT}, {.Right, BTN_RIGHT}, {.Middle, BTN_MIDDLE}}) {
		_ = code
		if in_.pressed[btn.b] {
			// A click on a layer surface asking for on-demand keyboard focus
			// is how a bar's menu gets the keyboard.
			if !locked && surf.layer != nil && surf.layer.kbd == .On_Demand {
				set_kbd_focus(s, surf)
			}
			ptr_button(s, btn.c, true)
		}
		if in_.released[btn.b] {
			ptr_button(s, btn.c, false)
		}
	}
	if scroll_pending(in_) {
		ptr_axis(s, in_.scroll.x, in_.scroll.y)
	}
	return true
}

// overlay_keys takes the keyboard while the session is locked. Only the
// compositor's own quit binding survives, so a nested session can always be
// left; on a real session that binding is the one the user already has to
// reach a TTY with.
overlay_keys :: proc(s: ^Server, app: ^p.App) -> bool {
	if !lock_active() {
		return false
	}
	in_ := &app.win.input
	send_mods(s, mods_mask(s, in_.mods, false))
	for k in in_.keys {
		if .Alt in k.mods && .Ctrl in k.mods && (k.sym == 'q' || k.sym == 'Q') {
			p.quit_app(app)
			continue
		}
		if locker_internal() {
			locker_key(s, k) // the compositor's own lock screen
			continue
		}
		forward_key(s, k)
	}
	return true
}
