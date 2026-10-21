package palmy

import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Drag and drop between windows (Wayland).
//
//	// The source: on a press that has started to move, offer the payload.
//	if dragging_my_item && !p.drag_active(ui) {
//		p.drag_start(ui, {"text/plain;charset=utf-8"}, {item.name})
//	}
//	switch p.drag_result(ui) { case .Dropped: ...; case .Cancelled: ... }
//
//	// The target: say which types this window takes, every frame.
//	p.drop_accept(ui, {"text/plain;charset=utf-8", "text/uri-list"})
//	if pos, types, over := p.drag_over(ui); over { highlight(pos) }
//	if d, ok := p.dropped(ui); ok { insert(d.data, d.pos) }
//
// It is wl_data_device's drag: the source creates a wl_data_source, offers its
// MIME types and calls start_drag with the serial of the press that began it;
// the compositor then owns the pointer until the button comes up. A target
// is told about the drag as a wl_data_offer on enter, motion and drop, and
// says which type it would take with `accept` -- before the drop, so the
// source knows whether to show a refusal. On drop the target reads the bytes
// through a pipe exactly like a paste, says `finish`, and the source hears
// `dnd_finished`.
//
// Which types a window takes is decided by the application in its frame, but
// the compositor asks while the drag moves, between frames. So the answer is
// the list `drop_accept` was given last frame: an application that starts
// accepting text this frame takes drags from the next one, which is the same
// one-frame latency as hit testing.
//
// Not done: X11 (XDND), drag icons (the compositor shows its own cursor), the
// `ask` action, and a drop that should only be taken over part of a window
// (drop_accept is window-wide; `drag_over` gives the position to decide with,
// and a drop the application does not want can simply be ignored).
// ---------------------------------------------------------------------------

// Drag_Result is how the last drag this window started ended.
Drag_Result :: enum {
	None,      // no drag has ended since the last time this was read
	Dropped,   // a target took it
	Cancelled, // dropped nowhere, refused, or the compositor would not start it
}

// Drop is what landed in this window.
Drop :: struct {
	mime: string, // valid for this frame
	data: string, // valid for this frame
	pos:  [2]f32, // where, in logical pixels
}

@(private)
Dnd_State :: struct {
	// Source.
	source:    u32,
	types:     [dynamic]string,
	payloads:  [dynamic]string,
	result:    Drag_Result,
	performed: bool,

	// Target.
	accept:    [dynamic]string, // what the application took last frame
	offer:     u32,
	offer_types: [dynamic]string,
	serial:    u32,
	pos:       [2]f32,
	origin:    [2]f32, // of the surface the drag is over, in window coordinates
	over:      bool,
	chosen:    string, // the type accepted for the current offer, or ""
	drop:      Drop,
	has_drop:  bool,
}

@(private)
WL_DATA_DEVICE_START_DRAG :: 0
@(private)
WL_DATA_OFFER_ACCEPT :: 0
@(private)
WL_DATA_OFFER_FINISH :: 3
@(private)
WL_DATA_OFFER_SET_ACTIONS :: 4
@(private)
WL_DATA_SOURCE_SET_ACTIONS :: 2
@(private)
DND_COPY :: u32(1)
@(private)
DND_MOVE :: u32(2)

// drag_start begins dragging `payloads`, one per entry of `types`, out of this
// window. Call it from the frame in which the pointer is held down and has
// moved far enough to mean a drag: the compositor checks that the press it was
// started from is the one still held. False when it cannot start (X11, no
// pointer press, a drag already running).
drag_start :: proc(ctx: ^Ctx, types: []string, payloads: []string) -> bool {
	if ctx.app == nil || len(types) == 0 || len(types) != len(payloads) {
		return false
	}
	w := &ctx.app.win
	if w.backend != .Wayland || w.clip.device == 0 || w.clip.ddm == 0 || w.wl.press_serial == 0 {
		return false
	}
	d := &w.clip.dnd
	if d.source != 0 {
		return false
	}
	c := &w.conn
	dnd_clear_source(d)
	for t in types {
		append(&d.types, strings.clone(t))
	}
	for s in payloads {
		append(&d.payloads, strings.clone(s))
	}
	d.result = .None
	d.performed = false
	d.source = new_id(c, .Drag_Source)
	request(c, w.clip.ddm, WL_DDM_CREATE_DATA_SOURCE, Obj(d.source))
	for t in types {
		request(c, d.source, WL_DATA_SOURCE_OFFER, t)
	}
	if w.clip.ddm_ver >= 3 {
		request(c, d.source, WL_DATA_SOURCE_SET_ACTIONS, DND_COPY | DND_MOVE)
	}
	request(c, w.clip.device, WL_DATA_DEVICE_START_DRAG, Obj(d.source), Obj(w.wl.surface), Obj(0), w.wl.press_serial)
	conn_flush(c)
	return true
}

// drag_active reports whether a drag this window started is still running.
drag_active :: proc(ctx: ^Ctx) -> bool {
	return ctx.app != nil && ctx.app.win.clip.dnd.source != 0
}

// drag_result is how the last drag ended, once: reading it resets it to None.
drag_result :: proc(ctx: ^Ctx) -> Drag_Result {
	if ctx.app == nil {
		return .None
	}
	d := &ctx.app.win.clip.dnd
	if d.source != 0 {
		return .None
	}
	r := d.result
	d.result = .None
	return r
}

// drop_accept says which MIME types this window takes from a drag, best first.
// Call it every frame the window wants drops; a frame without it takes none.
drop_accept :: proc(ctx: ^Ctx, types: []string) {
	if ctx.app == nil {
		return
	}
	d := &ctx.app.win.clip.dnd
	dnd_clear_list(&d.accept)
	for t in types {
		append(&d.accept, strings.clone(t))
	}
}

// drag_over reports a drag hovering over this window: where, and what it
// offers. The types are valid for this frame.
drag_over :: proc(ctx: ^Ctx) -> (pos: [2]f32, types: []string, ok: bool) {
	if ctx.app == nil {
		return
	}
	d := &ctx.app.win.clip.dnd
	if !d.over {
		return
	}
	return d.pos, d.offer_types[:], true
}

// dropped hands over what was dropped on this window, in the frame after the
// drop. The strings are valid for that frame.
dropped :: proc(ctx: ^Ctx) -> (drop: Drop, ok: bool) {
	if ctx.app == nil {
		return
	}
	d := &ctx.app.win.clip.dnd
	if !d.has_drop {
		return
	}
	d.has_drop = false
	// Copied into the frame's arena; the window's own copy goes now.
	drop = Drop {
		mime = strings.clone(d.drop.mime, ctx.alloc),
		data = strings.clone(d.drop.data, ctx.alloc),
		pos  = d.drop.pos,
	}
	delete(d.drop.mime)
	delete(d.drop.data)
	d.drop = {}
	return drop, true
}

// ---------------------------------------------------------------------------
// Wire
// ---------------------------------------------------------------------------

// dnd_source_event handles the drag source's events.
@(private)
dnd_source_event :: proc(w: ^Window, id: u32, opcode: u16, r: ^Reader) {
	c := &w.conn
	d := &w.clip.dnd
	if id != d.source {
		return
	}
	switch opcode {
	case 0:
	// target(mime or null): what the surface under the pointer would take.
	case 1:
		// send(mime, fd)
		mime := r_string(r)
		if fd, ok := take_fd(c); ok {
			served := false
			for t, i in d.types {
				if t == mime {
					serve_fd(fd, d.payloads[i])
					served = true
					break
				}
			}
			if !served {
				linux.close(fd)
			}
		}
	case 2:
		// cancelled: refused, dropped nowhere, or replaced.
		dnd_source_end(w, d.performed && w.clip.ddm_ver < 3 ? .Dropped : .Cancelled)
	case 3:
		// dnd_drop_performed: the button came up over a target that accepted.
		d.performed = true
		dnd_pointer_released(w)
	case 4:
		// dnd_finished: the target has read it and said finish.
		dnd_source_end(w, .Dropped)
	case 5:
	// action(dnd_action)
	}
	w.input_dirty = true
}

@(private)
dnd_source_end :: proc(w: ^Window, result: Drag_Result) {
	c := &w.conn
	d := &w.clip.dnd
	if d.source != 0 {
		request(c, d.source, WL_DATA_SOURCE_DESTROY)
		retire_id(c, d.source)
		d.source = 0
	}
	d.result = result
	dnd_clear_source(d)
	dnd_pointer_released(w)
}

// The compositor held the pointer for the drag and the release that ended it
// went to the drag, not to this window: let go of the button by hand, or it
// stays down until the next click.
@(private)
dnd_pointer_released :: proc(w: ^Window) {
	if w.input.down[.Left] {
		w.input.down[.Left] = false
		w.input.released[.Left] = true
		w.input.button_at = w.input.mouse
	}
}

// dnd_device_event takes the data device's drag events: enter, leave, motion
// and drop. Returns false for the ones it does not handle.
@(private)
dnd_device_event :: proc(w: ^Window, opcode: u16, r: ^Reader) -> bool {
	c := &w.conn
	d := &w.clip.dnd
	switch opcode {
	case 1:
		// enter(serial, surface, x, y, offer). Over one of this window's
		// popups the coordinates are the popup's; palmy's are the window's.
		d.serial = r_u32(r)
		d.origin, _ = wl_popup_origin(w, r_u32(r))
		d.pos = [2]f32{r_fixed(r), r_fixed(r)} + d.origin
		oid := r_u32(r)
		dnd_drop_offer(w)
		d.offer = oid
		d.over = true
		if list, found := w.clip.pending[oid]; found {
			for t in list {
				append(&d.offer_types, t)
			}
			delete(list)
			delete_key(&w.clip.pending, oid)
		}
		// Choose now, from what the application took last frame.
		d.chosen = ""
		pick: for want in d.accept {
			for t in d.offer_types {
				if t == want {
					d.chosen = t
					break pick
				}
			}
		}
		if oid != 0 {
			if w.clip.ddm_ver >= 3 {
				request(c, oid, WL_DATA_OFFER_SET_ACTIONS, DND_COPY | DND_MOVE, DND_COPY)
			}
			dnd_send_accept(w)
		}
	case 2:
		// leave
		dnd_drop_offer(w)
	case 3:
		// motion(time, x, y)
		r_u32(r)
		d.pos = [2]f32{r_fixed(r), r_fixed(r)} + d.origin
		if d.offer != 0 {
			dnd_send_accept(w)
		}
	case 4:
		// drop
		dnd_take_drop(w)
	case:
		return false
	}
	w.input_dirty = true
	return true
}

@(private)
dnd_send_accept :: proc(w: ^Window) {
	d := &w.clip.dnd
	c := &w.conn
	if d.chosen != "" {
		request(c, d.offer, WL_DATA_OFFER_ACCEPT, d.serial, d.chosen)
	} else {
		// A null type: this window would refuse a drop here.
		request(c, d.offer, WL_DATA_OFFER_ACCEPT, d.serial, Obj(0))
	}
}

// dnd_take_drop reads the dropped bytes and finishes the offer. A drag that
// started in this same window is answered from memory: asking the compositor
// would make it ask us, and we would be blocked reading the pipe we are
// supposed to be writing.
@(private)
dnd_take_drop :: proc(w: ^Window) {
	c := &w.conn
	d := &w.clip.dnd
	if d.offer == 0 || d.chosen == "" {
		dnd_drop_offer(w)
		return
	}
	data: string
	ok := false
	if d.source != 0 {
		for t, i in d.types {
			if t == d.chosen {
				data, ok = strings.clone(d.payloads[i]), true
				break
			}
		}
	} else {
		fds: [2]linux.Fd
		if linux.pipe2(&fds, {.CLOEXEC}) == .NONE {
			request(c, d.offer, WL_DATA_OFFER_RECEIVE, d.chosen, Fd(fds[1]))
			conn_flush(c)
			data, ok = read_all_fd(fds[0])
			linux.close(fds[0])
		}
	}
	if ok {
		delete(d.drop.mime)
		delete(d.drop.data)
		d.drop = Drop {
			mime = strings.clone(d.chosen),
			data = data,
			pos  = d.pos,
		}
		d.has_drop = true
		if w.clip.ddm_ver >= 3 {
			request(c, d.offer, WL_DATA_OFFER_FINISH)
		}
	}
	dnd_drop_offer(w)
}

// dnd_drop_offer lets go of the current drag offer.
@(private)
dnd_drop_offer :: proc(w: ^Window) {
	d := &w.clip.dnd
	if d.offer != 0 {
		wl_offer_destroy(w, .Data_Offer, d.offer)
		d.offer = 0
	}
	dnd_clear_list(&d.offer_types)
	d.over = false
	d.chosen = ""
}

@(private)
dnd_clear_list :: proc(l: ^[dynamic]string) {
	for s in l {
		delete(s)
	}
	clear(l)
}

@(private)
dnd_clear_source :: proc(d: ^Dnd_State) {
	dnd_clear_list(&d.types)
	dnd_clear_list(&d.payloads)
}

@(private)
dnd_destroy :: proc(d: ^Dnd_State) {
	dnd_clear_source(d)
	delete(d.types)
	delete(d.payloads)
	dnd_clear_list(&d.accept)
	delete(d.accept)
	dnd_clear_list(&d.offer_types)
	delete(d.offer_types)
	delete(d.drop.mime)
	delete(d.drop.data)
}
