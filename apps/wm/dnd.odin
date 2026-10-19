// Drag and drop over wl_data_device.
//
// The dance, in order: a client calls start_drag with the serial of the button
// press that is still held, which is the implicit grab. From then until the
// button comes up the pointer belongs to the drag: no wl_pointer events go
// anywhere, and the surface under the cursor instead sees enter / motion /
// leave on its wl_data_device with a wl_data_offer attached. That surface
// answers with accept (which becomes wl_data_source.target) and, at version 3,
// set_actions, and the compositor arbitrates the two sides' action masks into
// the single action both are told about. On release, a target that accepted
// something and settled on an action other than none gets drop, the source
// gets dnd_drop_performed, and once the target says finish the source gets
// dnd_finished. Every other way out of the drag ends in cancelled.
//
// The drag icon is an ordinary wl_surface with no role of its own; we composite
// it at the cursor every frame and stop the moment the drag ends.
//
// Object lifetime here is all Data_Ref rather than pointers: a drag can outlive
// any of the three clients involved in it, and the one thing it must never do
// is dereference one that has gone.
package wm

import p "palmy:."

Dnd_State :: struct {
	active:   bool,
	src:      Data_Ref, // wl_data_source; cidx 0 is a drag with no source
	dev:      Data_Ref, // the wl_data_device that started it
	icon:     Data_Ref, // wl_surface drawn at the cursor, cidx 0 if none
	origin:   Data_Ref, // wl_surface the drag began on
	serial:   u32,

	// The surface currently under the pointer, and the offer we minted in its
	// client. tgt_off is 0 when there is no target.
	tgt:      Data_Ref,
	tgt_dev:  u32,
	tgt_off:  u32,

	accepted: bool,
	tgt_act:  u32,
	tgt_pref: u32,
	action:   u32,

	dropped:  bool, // drop sent, waiting for wl_data_offer.finish
	wait:     int,  // frames since the drop, for the watchdog
	x, y:     int,  // pointer in compositor pixels
}

dnd: Dnd_State

// A drop that is never finished must not wedge the pointer. Ten seconds at the
// host's frame rate is far longer than any real client takes.
DND_FINISH_FRAMES :: 600

// ---------------------------------------------------------------------------
// The seam
//
// A drag is driven by the pointer and drawn on top of the frame, and this file
// owns neither. Three call sites in main.odin, none of them more than a line,
// are what it needs; everything else is self-contained. In handle_pointer,
// immediately after `s_pointer = mp` and *before* the `!in_.over_surface`
// early return, so that a pointer leaving the host window cannot strand a
// drag:
//
//	if dnd_active() {
//		dnd_update(s, mp.x, mp.y, in_.down[.Left] || in_.down[.Middle] || in_.down[.Right])
//		return
//	}
//
// At the very end of draw, after its closing `wm_reset_clip(cv)`, so the icon
// is above every window including the one being dragged over:
//
//	dnd_draw(s, cv)
//
// And in the frame loop, right after `server_poll(s)`:
//
//	data_pump(s)
//
// Without the first two, the protocol side still behaves: start_drag is
// validated and refused or accepted, and every path still ends in cancelled
// rather than a stuck grab -- but no drag can reach a target, because nothing
// tells it where the pointer is.
// ---------------------------------------------------------------------------

// dnd_active reports whether the pointer currently belongs to a drag. The
// compositor's own pointer routing has to stand aside while it does.
dnd_active :: proc() -> bool {
	return dnd.active
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

// dnd_start handles wl_data_device.start_drag(source, origin, icon, serial).
dnd_start :: proc(s: ^Server, c: ^Client, o: Object, id: u32, r: ^Reader) {
	sid := r_u32(r)
	oid := r_u32(r)
	iid := r_u32(r)
	serial := r_u32(r)
	if r.bad {
		return
	}

	fail :: proc(s: ^Server, c: ^Client, sid: u32, why: string) {
		log_line("client %d start_drag refused: %s", c.index, why)
		if sid == 0 {
			return
		}
		if so, ok := obj_get(c, sid); ok && so.kind == .Data_Source {
			src := (^Data_Source)(so.p)
			if !src.gone {
				event(c, sid, 2) // cancelled
				client_flush(c)
			}
		}
	}

	if dnd.active {
		fail(s, c, sid, "a drag is already in progress")
		return
	}
	if !data_serial_ok(s, serial) {
		fail(s, c, sid, "the serial was never issued")
		return
	}

	// The origin must be one of this client's surfaces, and the implicit grab
	// means the pointer has to be on this client right now.
	oo, ook := obj_get(c, oid)
	if !ook || oo.kind != .Surface {
		fail(s, c, sid, "the origin is not a surface")
		return
	}
	if s.ptr_surf == nil || s.ptr_surf.client != c {
		fail(s, c, sid, "the client does not hold the pointer")
		return
	}

	src: ^Data_Source
	if sid != 0 {
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Data_Source {
			fail(s, c, sid, "the source is not a wl_data_source")
			return
		}
		src = (^Data_Source)(so.p)
		if src.used || src.gone {
			post_error(c, id, 1, "wl_data_source used twice") // wl_data_device.used_source
			return
		}
		src.used = true
		src.dnd = true
	}

	dnd = Dnd_State {
		active = true,
		dev    = data_ref(c, id),
		origin = data_ref(c, oid),
		serial = serial,
		x      = s_pointer.x,
		y      = s_pointer.y,
	}
	if sid != 0 {
		dnd.src = data_ref(c, sid)
	}
	if iid != 0 {
		if io, ok := obj_get(c, iid); ok && io.kind == .Surface {
			dnd.icon = data_ref(c, iid)
		}
	}

	// The pointer leaves the client for the duration: from here the drag
	// protocol carries the position, not wl_pointer.
	set_ptr_focus(s, nil, 0, 0)
	s.dirty = true
	log_line("drag started by client %d (%d mime types)", c.index, src != nil ? len(src.mimes) : 0)

	dnd_retarget(s)
}

// ---------------------------------------------------------------------------
// Per-frame tracking
// ---------------------------------------------------------------------------

// dnd_update is the main loop's handle on a drag: the pointer position in
// compositor pixels and whether the button is still down.
dnd_update :: proc(s: ^Server, mx, my: int, held: bool) {
	if !dnd.active {
		return
	}
	if mx != dnd.x || my != dnd.y {
		dnd.x, dnd.y = mx, my
		s.dirty = true
	}
	if dnd.dropped {
		return
	}
	dnd_retarget(s)
	if !held {
		dnd_release(s)
	}
}

// dnd_retarget works out which surface is under the cursor and keeps the
// enter / motion / leave sequence honest across the change.
@(private = "file")
dnd_retarget :: proc(s: ^Server) {
	surf: ^Surface
	lx, ly: int

	t, region, _ := window_at(s, dnd.x, dnd.y)
	if region == .Content && t != nil && t.xdg != nil && t.xdg.surf != nil {
		surf, lx, ly = pick_surface(t.xdg.surf, t.x, t.y, dnd.x, dnd.y)
	}

	// A client with no wl_data_device cannot be a drop target.
	if surf != nil {
		if surf.client.dead || len(surf.client.data_devices) == 0 {
			surf = nil
		}
	}

	same := surf != nil && dnd.tgt.cidx == surf.client.index && dnd.tgt.id == surf.id
	if !same {
		dnd_leave(s)
		if surf != nil {
			dnd_enter(s, surf, lx, ly)
		}
		return
	}

	c := data_client(s, dnd.tgt)
	if c == nil {
		dnd_leave(s)
		return
	}
	event(c, dnd.tgt_dev, 3, now_ms(), fixed(f32(lx)), fixed(f32(ly))) // motion
	client_flush(c)
}

@(private = "file")
dnd_enter :: proc(s: ^Server, surf: ^Surface, lx, ly: int) {
	c := surf.client
	dev := c.data_devices[0]
	_, src := data_source_of(s, dnd.src)

	off_id := u32(0)
	ver := u32(1)
	if src != nil {
		off_id = data_new_offer(s, c, dev, src, true)
		if o, ok := obj_get(c, off_id); ok {
			ver = o.ver
		}
	}

	// enter(serial, surface, x, y, id)
	event(c, dev, 1, next_serial(s), surf.id, fixed(f32(lx)), fixed(f32(ly)), off_id)

	dnd.tgt = data_ref(c, surf.id)
	dnd.tgt_dev = dev
	dnd.tgt_off = off_id
	dnd.accepted = false
	dnd.tgt_act = DND_NONE
	dnd.tgt_pref = DND_NONE

	if off_id != 0 && ver >= 3 {
		event(c, off_id, 1, dnd_source_actions(s)) // source_actions
	}
	// A fresh offer has heard no action yet, so it is told even when the
	// answer is none -- toolkits wait for that event before drawing a cursor.
	dnd_recompute(s, true)
	client_flush(c)
}

@(private = "file")
dnd_leave :: proc(s: ^Server) {
	if dnd.tgt.cidx == 0 {
		return
	}
	if c := data_client(s, dnd.tgt); c != nil {
		event(c, dnd.tgt_dev, 2) // leave
		client_flush(c)
	}
	dnd.tgt = {}
	dnd.tgt_dev = 0
	dnd.tgt_off = 0
	dnd.accepted = false
	dnd.tgt_act = DND_NONE
	dnd.tgt_pref = DND_NONE
	// The source is told the target went away before the action is recomputed,
	// otherwise it would be left believing a drop is still possible.
	dnd_send_target(s, "", true)
	dnd_recompute(s)
}

// ---------------------------------------------------------------------------
// Action negotiation
// ---------------------------------------------------------------------------

@(private = "file")
dnd_source_actions :: proc(s: ^Server) -> u32 {
	_, src := data_source_of(s, dnd.src)
	if src == nil {
		return DND_NONE
	}
	if src.ver < 3 {
		// Versions below 3 have no set_actions; the historical behaviour is a
		// plain copy.
		return DND_COPY
	}
	return src.actions
}

// dnd_recompute intersects the two sides' action masks and tells both about
// the result, but only when it has actually changed.
@(private = "file")
dnd_recompute :: proc(s: ^Server, force: bool = false) {
	avail := dnd_source_actions(s) & dnd.tgt_act
	act := DND_NONE
	switch {
	case avail == 0:
	case dnd.tgt_pref & avail != 0:
		act = dnd.tgt_pref
	case avail & DND_COPY != 0:
		act = DND_COPY
	case avail & DND_MOVE != 0:
		act = DND_MOVE
	case:
		act = DND_ASK
	}
	if act == dnd.action && !force {
		return
	}
	dnd.action = act

	if c, src := data_source_of(s, dnd.src); src != nil && src.ver >= 3 {
		event(c, src.id, 5, act) // wl_data_source.action
		client_flush(c)
	}
	if dnd.tgt_off != 0 {
		if c := data_client(s, dnd.tgt); c != nil {
			if o, ok := obj_get(c, dnd.tgt_off); ok && o.ver >= 3 {
				event(c, dnd.tgt_off, 2, act) // wl_data_offer.action
				client_flush(c)
			}
		}
	}
}

// dnd_send_target is wl_data_source.target. A null mime type is a zero-length
// string on the wire, which is what the bare u32(0) encodes.
@(private = "file")
dnd_send_target :: proc(s: ^Server, mime: string, null: bool) {
	c, src := data_source_of(s, dnd.src)
	if src == nil {
		return
	}
	if null {
		if !src.sent_target {
			return
		}
		src.sent_target = false
		event(c, src.id, 0, u32(0))
	} else {
		src.sent_target = true
		event(c, src.id, 0, mime)
	}
	client_flush(c)
}

// ---------------------------------------------------------------------------
// Requests arriving on the offer
// ---------------------------------------------------------------------------

dnd_offer_accept :: proc(s: ^Server, off: ^Data_Offer, mime: string) {
	if !off.dnd {
		return
	}
	if !dnd.active || dnd.tgt_off != off.id || dnd.tgt.cidx != off.client.index {
		return
	}
	off.accepted = mime != ""
	dnd.accepted = off.accepted
	dnd_send_target(s, mime, mime == "")
	dnd_recompute(s)
}

dnd_offer_actions :: proc(s: ^Server, off: ^Data_Offer, actions, pref: u32) {
	off.actions = actions
	off.pref = pref
	if !off.dnd || !dnd.active || dnd.tgt_off != off.id || dnd.tgt.cidx != off.client.index {
		return
	}
	dnd.tgt_act = actions
	dnd.tgt_pref = pref
	dnd_recompute(s)
}

// dnd_offer_finish is wl_data_offer.finish: the target has taken the data and
// the source may now let go of it.
dnd_offer_finish :: proc(s: ^Server, off: ^Data_Offer, c: ^Client, id: u32) {
	if !off.dnd {
		post_error(c, id, 0, "wl_data_offer.finish on a selection offer") // invalid_finish
		return
	}
	if !dnd.active || !dnd.dropped || dnd.tgt_off != off.id {
		// The watchdog may already have ended the drag. Killing the client for
		// being slow would be a worse bug than ignoring a late finish.
		log_line("client %d sent finish for a drag that is already over", c.index)
		return
	}
	if sc, src := data_source_of(s, dnd.src); src != nil && src.ver >= 3 {
		event(sc, src.id, 4) // dnd_finished
		client_flush(sc)
	}
	dnd_clear(s)
}

// dnd_offer_gone is the target destroying its offer. If that happens after a
// drop but before finish, the transfer never completed and the source has to
// hear cancelled rather than wait forever.
dnd_offer_gone :: proc(s: ^Server, off: ^Data_Offer) {
	if !dnd.active || !off.dnd || dnd.tgt_off != off.id {
		return
	}
	dnd.tgt_off = 0
	if dnd.dropped {
		dnd_cancel(s, "the target destroyed the offer without finishing")
	}
}

// ---------------------------------------------------------------------------
// Ending
// ---------------------------------------------------------------------------

// dnd_release is the button coming up.
@(private = "file")
dnd_release :: proc(s: ^Server) {
	_, src := data_source_of(s, dnd.src)

	if dnd.tgt_off == 0 || !dnd.accepted || dnd.action == DND_NONE {
		dnd_cancel(s, "dropped with nothing willing to take it")
		return
	}

	c := data_client(s, dnd.tgt)
	if c == nil {
		dnd_cancel(s, "the target went away")
		return
	}
	event(c, dnd.tgt_dev, 4) // drop
	client_flush(c)

	if src == nil {
		dnd_clear(s)
		return
	}
	if src.ver < 3 {
		// Nothing to wait for: dnd_drop_performed and dnd_finished are both
		// version 3. The drag is over the moment the drop is sent.
		dnd_clear(s)
		return
	}
	sc, _ := data_source_of(s, dnd.src)
	event(sc, src.id, 3) // dnd_drop_performed
	client_flush(sc)
	dnd.dropped = true
	dnd.wait = 0
	log_line("drop performed, waiting for the target to finish")
}

// dnd_cancel ends a drag that produced nothing. Every path out of a drag that
// is not a completed drop goes through here, which is what guarantees the
// source always hears exactly one of cancelled or dnd_finished.
dnd_cancel :: proc(s: ^Server, why: string) {
	if !dnd.active {
		return
	}
	log_line("drag cancelled: %s", why)
	if c := data_client(s, dnd.tgt); c != nil && dnd.tgt_dev != 0 && !dnd.dropped {
		event(c, dnd.tgt_dev, 2) // leave
		client_flush(c)
	}
	if c, src := data_source_of(s, dnd.src); src != nil {
		event(c, src.id, 2) // cancelled
		client_flush(c)
	}
	dnd_clear(s)
}

@(private = "file")
dnd_clear :: proc(s: ^Server) {
	dnd = {}
	s.dirty = true
}

// dnd_source_gone: the wl_data_source behind the drag was destroyed.
dnd_source_gone :: proc(s: ^Server, src: ^Data_Source) {
	if !dnd.active || !src.dnd {
		return
	}
	if dnd.src.cidx != src.client.index || dnd.src.id != src.id {
		return
	}
	// The source is already being torn down, so only the target is told.
	if c := data_client(s, dnd.tgt); c != nil && dnd.tgt_dev != 0 && !dnd.dropped {
		event(c, dnd.tgt_dev, 2) // leave
		client_flush(c)
	}
	dnd_clear(s)
}

// dnd_device_gone: a wl_data_device involved in the drag was released.
dnd_device_gone :: proc(s: ^Server, c: ^Client, id: u32) {
	if !dnd.active {
		return
	}
	if dnd.dev.cidx == c.index && dnd.dev.id == id {
		dnd_cancel(s, "the originating device was released")
		return
	}
	if dnd.tgt.cidx == c.index && dnd.tgt_dev == id {
		dnd.tgt_dev = 0
		dnd_leave(s)
	}
}

// dnd_source_actions_changed: the source called set_actions mid-drag.
dnd_source_actions_changed :: proc(s: ^Server, src: ^Data_Source) {
	if !dnd.active || dnd.src.cidx != src.client.index || dnd.src.id != src.id {
		return
	}
	if dnd.tgt_off != 0 {
		if c := data_client(s, dnd.tgt); c != nil {
			if o, ok := obj_get(c, dnd.tgt_off); ok && o.ver >= 3 {
				event(c, dnd.tgt_off, 1, dnd_source_actions(s)) // source_actions
				client_flush(c)
			}
		}
	}
	dnd_recompute(s)
}

// dnd_tick is the watchdog, called once a frame from data_pump. A drag whose
// source or origin client has exited, or whose target took the drop and never
// finished, ends here rather than holding the pointer hostage.
dnd_tick :: proc(s: ^Server) {
	if !dnd.active {
		return
	}
	if data_client(s, dnd.dev) == nil {
		dnd_clear(s)
		return
	}
	if dnd.src.cidx != 0 {
		if _, src := data_source_of(s, dnd.src); src == nil {
			dnd_cancel(s, "the source client went away")
			return
		}
	}
	if dnd.tgt.cidx != 0 && data_surface_of(s, dnd.tgt) == nil {
		if dnd.dropped {
			dnd_cancel(s, "the target surface went away after the drop")
		} else {
			dnd_leave(s)
		}
		return
	}
	if dnd.dropped {
		dnd.wait += 1
		if dnd.wait > DND_FINISH_FRAMES {
			dnd_cancel(s, "the target never sent finish")
		}
	}
}

// ---------------------------------------------------------------------------
// The icon
// ---------------------------------------------------------------------------

// dnd_draw composites the drag icon at the cursor. It belongs at the very end
// of the frame: the icon is above every window, including the one it is being
// dragged over.
dnd_draw :: proc(s: ^Server, cv: ^p.Canvas) {
	if !dnd.active || dnd.icon.cidx == 0 {
		return
	}
	icon := data_surface_of(s, dnd.icon)
	if icon == nil || icon.img == nil {
		return
	}
	wm_reset_clip(cv)
	blit_surface(cv, icon, dnd.x, dnd.y)
}
