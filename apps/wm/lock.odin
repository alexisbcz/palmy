// ext_session_lock_v1, and zwp_idle_inhibit_manager_v1 next to it.
//
// A screen locker is not a window that happens to be on top. The whole reason
// this protocol replaced the old "fullscreen surface with a keyboard grab"
// arrangement is the failure mode: if the locker crashes, the old design
// unlocked the session. Here the compositor owns the lock state, and the only
// thing that can clear it is an explicit unlock_and_destroy from the client
// that took it. A locker that dies leaves the session locked showing the
// compositor's own fallback, which is exactly what you want at 3am.
//
// The three properties this file has to hold:
//
//   1. From the moment `lock` arrives, no client but the locker sees input,
//      and nothing but the lock surfaces is drawn.
//   2. `locked` is only sent once every output is actually covered, because
//      the client is allowed to believe the screen is safe after it.
//   3. If the locker goes away without unlocking, the session stays locked.
package wm

import p "palmy:."

Lock_State :: enum u8 {
	Unlocked,
	Locking, // the request arrived; the screen is already blanked
	Locked, // every output is covered and `locked` has been sent
}

Lock_Session :: struct {
	client:      ^Client,
	id:          u32,
	ver:         u32,
	locked_sent: bool,
	finished:    bool,
}

Lock_Surface :: struct {
	client:     ^Client,
	id:         u32,
	surf:       ^Surface,
	out_global: u32,
	serial:     u32,
	acked:      u32,
	x, y:       int,
	w, h:       int,
	mapped:     bool,
}

lock_state: Lock_State
lock_session: ^Lock_Session
lock_surfaces: [dynamic]^Lock_Surface
lock_abandoned: bool // the locker died while the session was locked
lock_warned: bool

// ---------------------------------------------------------------------------
// What the rest of the compositor asks
// ---------------------------------------------------------------------------

// lock_active is the single question `main.odin` has to ask: when it is true,
// the desktop, the windows, the bar and every layer surface are not drawn and
// receive no input.
lock_active :: proc() -> bool {
	return lock_state != .Unlocked
}

// lock_covered reports whether real lock surfaces are on screen. When it is
// false but the session is locked we are showing the fallback, either because
// the locker has not drawn yet or because it died.
lock_covered :: proc() -> bool {
	for ls in lock_surfaces {
		if ls.mapped {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

lock_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	lock_purge(s)
	wm_reset_clip(cv)
	p.fill_rect(cv, {0, 0, f32(cv.w), f32(cv.h)}, p.hex(0x05050a))

	drew := false
	for ls in lock_surfaces {
		if !ls.mapped || ls.surf == nil {
			continue
		}
		p.push_clip(cv, {f32(ls.x), f32(ls.y), f32(ls.w), f32(ls.h)})
		blit_surface(cv, ls.surf, ls.x, ls.y)
		p.pop_clip(cv)
		drew = true
	}
	if drew {
		return
	}
	// No client lock surface on screen (the compositor locked the session
	// itself, or a client locker has not drawn yet or died): the
	// compositor's own lock screen, which takes the password (locker.odin).
	locker_draw(s, app, cv)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// lock_surface_at routes the pointer. Only lock surfaces can be hit.
lock_surface_at :: proc(s: ^Server, mx, my: int) -> (^Surface, int, int) {
	for ls in lock_surfaces {
		if !ls.mapped || ls.surf == nil {
			continue
		}
		if mx < ls.x || my < ls.y || mx >= ls.x + ls.w || my >= ls.y + ls.h {
			continue
		}
		if surf, lx, ly := pick_surface(ls.surf, ls.x, ls.y, mx, my); surf != nil {
			return surf, lx, ly
		}
	}
	return nil, 0, 0
}

lock_kbd_surface :: proc() -> ^Surface {
	for ls in lock_surfaces {
		if ls.mapped && ls.surf != nil {
			return ls.surf
		}
	}
	return nil
}

lock_refocus :: proc(s: ^Server) {
	set_kbd_focus(s, lock_kbd_surface())
}

// ---------------------------------------------------------------------------
// ext_session_lock_manager_v1
// ---------------------------------------------------------------------------

req_lock_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// lock(id)
		lid := r_u32(r)
		ses := new(Lock_Session)
		ses.client = c
		ses.id = lid
		ses.ver = o.ver
		if !obj_new(c, lid, .Lock, o.ver, ses) {
			free(ses)
			return
		}
		// Only one lock at a time. A second one is refused with `finished`,
		// which tells the client to destroy the object and give up.
		if lock_state != .Unlocked {
			ses.finished = true
			event(c, lid, 1)
			log_line("client %d asked to lock an already locked session", c.index)
			return
		}
		lock_session = ses
		lock_state = .Locking
		lock_abandoned = false
		lock_blank(s)
		log_line("client %d locked the session", c.index)
	}
}

// lock_blank takes input away from everything that is not the locker. The
// screen stops being drawn in the same frame, because `lock_active` is already
// true by the time `draw` runs.
lock_blank :: proc(s: ^Server) {
	// A drag in flight would otherwise go on delivering motion, and its drop,
	// to whatever window is under the pointer.
	if dnd_active() {
		dnd_cancel(s, "the session locked")
	}
	set_ptr_focus(s, nil, 0, 0)
	set_kbd_focus(s, nil)
	s.drag = .None
	s.drag_t = nil
	s.hover_t = nil
	s.hover_btn = 0
	s.dirty = true
}

// ---------------------------------------------------------------------------
// ext_session_lock_v1
// ---------------------------------------------------------------------------

req_lock :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	ses := (^Lock_Session)(o.p)
	switch op {
	case 0:
		// destroy. Legal only after `finished`, or after unlock_and_destroy.
		if ses != nil && !ses.finished && ses == lock_session && lock_state != .Unlocked {
			post_error(c, id, 0, "ext_session_lock_v1.destroy while the session is locked")
			return
		}
		if ses == lock_session {
			lock_session = nil
		}
		obj_drop(c, id)
		free(ses)
	case 1:
		// get_lock_surface(id, surface, output)
		sid := r_u32(r)
		wsid := r_u32(r)
		oid := r_u32(r)
		if ses == nil || ses.finished {
			// The lock was refused; the client must not get surfaces.
			obj_new(c, sid, .Lock_Surface, 1, nil)
			return
		}
		so, ok := obj_get(c, wsid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 2, "ext_session_lock_v1.get_lock_surface on a non-surface")
			return
		}
		surf := (^Surface)(so.p)
		if surf.role != .None {
			post_error(c, id, 2, "the surface already has a role")
			return
		}
		if surf.img != nil {
			post_error(c, id, 4, "the surface already has a buffer attached")
			return
		}
		og := u32(0)
		if ob, found := obj_get(c, oid); found && ob.kind == .Output {
			og = u32(uintptr(ob.p))
		}
		for existing in lock_surfaces {
			if existing.out_global == og {
				post_error(c, id, 3, "that output already has a lock surface")
				return
			}
		}

		ls := new(Lock_Surface)
		ls.client = c
		ls.id = sid
		ls.surf = surf
		ls.out_global = og
		if !obj_new(c, sid, .Lock_Surface, 1, ls) {
			free(ls)
			return
		}
		surf.role = .Lock
		surf.lock = ls
		append(&lock_surfaces, ls)
		lock_place(s, ls)
		lock_configure(s, ls)
	case 2:
		// unlock_and_destroy
		if ses == nil || !ses.locked_sent {
			post_error(c, id, 1, "ext_session_lock_v1.unlock_and_destroy before `locked` was sent")
			return
		}
		log_line("client %d unlocked the session", c.index)
		lock_clear(s)
		if ses == lock_session {
			lock_session = nil
		}
		obj_drop(c, id)
		free(ses)
	}
}

lock_place :: proc(s: ^Server, ls: ^Lock_Surface) {
	o := out_by_global(ls.out_global)
	if o == nil {
		o = out_primary()
	}
	if o != nil {
		ls.x, ls.y, ls.w, ls.h = o.x, o.y, o.w, o.h
	} else {
		ls.x, ls.y, ls.w, ls.h = 0, 0, s.out_w, s.out_h
	}
}

lock_configure :: proc(s: ^Server, ls: ^Lock_Surface) {
	ls.serial = next_serial(s)
	event(ls.client, ls.id, 0, ls.serial, u32(ls.w), u32(ls.h))
}

req_lock_surface :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	ls := (^Lock_Surface)(o.p)
	switch op {
	case 0:
		// destroy
		if ls != nil {
			if ls.surf != nil {
				ls.surf.role = .None
				ls.surf.lock = nil
			}
			for x, i in lock_surfaces {
				if x == ls {
					ordered_remove(&lock_surfaces, i)
					break
				}
			}
			free(ls)
		}
		obj_drop(c, id)
		lock_refocus(s)
		s.dirty = true
	case 1:
		// ack_configure(serial)
		if ls != nil {
			ls.acked = r_u32(r)
		}
	}
}

// lock_commit runs from surface_commit when a lock surface gets pixels.
lock_commit :: proc(s: ^Server, ls: ^Lock_Surface) {
	has := ls.surf != nil && ls.surf.img != nil && ls.surf.iw > 0
	was := ls.mapped
	ls.mapped = has
	if ls.mapped != was {
		lock_refocus(s)
	}
	lock_maybe_locked(s)
	if !session.bare || ls.mapped != was {
		s.dirty = true
	}
}

// lock_maybe_locked sends `locked` once every output is covered. Until then
// the screen is blank but the client has not been promised anything.
lock_maybe_locked :: proc(s: ^Server) {
	if lock_state != .Locking || lock_session == nil || lock_session.finished {
		return
	}
	// `locked` is a promise: after it, the client is entitled to believe
	// nothing else is on screen. If the compositing loop has never called
	// `layer_draw`, this file is not wired into it and the desktop is still
	// being painted, so the promise would be a lie. Stay in .Locking — input
	// is already withheld — and say so once.
	if !layer_drawn_once {
		if !lock_warned {
			lock_warned = true
			log_line("refusing to send `locked`: main.odin never calls layer_draw/lock_draw")
		}
		return
	}
	needed := max(len(out_list), 1)
	covered := 0
	for ls in lock_surfaces {
		if ls.mapped {
			covered += 1
		}
	}
	if covered < needed {
		return
	}
	lock_state = .Locked
	lock_session.locked_sent = true
	event(lock_session.client, lock_session.id, 0) // locked
	client_flush(lock_session.client)
	log_line("session locked: %d of %d outputs covered", covered, needed)
}

// lock_clear is the only path back to an unlocked session.
lock_clear :: proc(s: ^Server) {
	for ls in lock_surfaces {
		if ls.surf != nil {
			ls.surf.role = .None
			ls.surf.lock = nil
		}
		free(ls)
	}
	clear(&lock_surfaces)
	lock_state = .Unlocked
	lock_abandoned = false
	lock_session = nil
	locker_forget()
	if s.focus != nil && s.focus.xdg != nil {
		set_kbd_focus(s, s.focus.xdg.surf)
	}
	layer_refocus(s)
	s.dirty = true
}

// lock_purge notices that the locking client has gone. The session does not
// unlock: that is the entire point of this protocol over a grabbing window.
lock_purge :: proc(s: ^Server) {
	alive :: proc(s: ^Server, c: ^Client) -> bool {
		for x in s.clients {
			if x == c && !x.dead {
				return true
			}
		}
		return false
	}
	for i := len(lock_surfaces) - 1; i >= 0; i -= 1 {
		ls := lock_surfaces[i]
		if alive(s, ls.client) {
			continue
		}
		ordered_remove(&lock_surfaces, i)
		free(ls)
	}
	for i := len(lock_idle_list) - 1; i >= 0; i -= 1 {
		if !alive(s, lock_idle_list[i].client) {
			ordered_remove(&lock_idle_list, i)
		}
	}
	if lock_session != nil && !alive(s, lock_session.client) {
		if lock_state != .Unlocked {
			if !lock_abandoned {
				log_line("the locking client died; the session stays locked")
			}
			lock_abandoned = true
			lock_state = .Locked
		}
		lock_session = nil
	}
}

// ---------------------------------------------------------------------------
// zwp_idle_inhibit_manager_v1
// ---------------------------------------------------------------------------

Lock_Idle :: struct {
	client: ^Client,
	id:     u32,
}

lock_idle_list: [dynamic]Lock_Idle

// lock_idle_inhibited is what an idle timer in `config.odin` or a session
// daemon should consult before blanking or locking on its own.
lock_idle_inhibited :: proc() -> bool {
	return len(lock_idle_list) > 0
}

req_lock_idle_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// create_inhibitor(id, surface)
		iid := r_u32(r)
		sid := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "zwp_idle_inhibit_manager_v1 on a non-surface")
			return
		}
		if obj_new(c, iid, .Idle_Inhibitor, 1, so.p) {
			append(&lock_idle_list, Lock_Idle{client = c, id = iid})
			log_line("idle inhibited (%d holders)", len(lock_idle_list))
		}
	}
}

req_lock_idle_inhibitor :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	if op == 0 {
		for e, i in lock_idle_list {
			if e.client == c && e.id == id {
				ordered_remove(&lock_idle_list, i)
				break
			}
		}
		obj_drop(c, id)
	}
}
