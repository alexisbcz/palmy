#+build linux
package palmy

import "core:strings"
import "core:sys/linux"

// The Wayland half of dnd.odin: the state both ends keep, and the events.

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
