package palmy

import "core:strings"


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
// Wayland only for now: elsewhere every call answers "no drag". Not done:
// X11 (XDND), macOS, the web, drag icons (the compositor shows its own cursor), the
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

// drag_start begins dragging `payloads`, one per entry of `types`, out of this
// window. Call it from the frame in which the pointer is held down and has
// moved far enough to mean a drag: the compositor checks that the press it was
// started from is the one still held. False when it cannot start (X11, no
// pointer press, a drag already running).
drag_start :: proc(ctx: ^Ctx, types: []string, payloads: []string) -> bool {
	when ODIN_OS != .Linux {
		return false
	} else {
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
}

// drag_active reports whether a drag this window started is still running.
drag_active :: proc(ctx: ^Ctx) -> bool {
	when ODIN_OS != .Linux {
		return false
	} else {
		return ctx.app != nil && ctx.app.win.clip.dnd.source != 0
	}
}

// drag_result is how the last drag ended, once: reading it resets it to None.
drag_result :: proc(ctx: ^Ctx) -> Drag_Result {
	when ODIN_OS != .Linux {
		return .None
	} else {
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
}

// drop_accept says which MIME types this window takes from a drag, best first.
// Call it every frame the window wants drops; a frame without it takes none.
drop_accept :: proc(ctx: ^Ctx, types: []string) {
	when ODIN_OS != .Linux {
		return
	} else {
		if ctx.app == nil {
			return
		}
		d := &ctx.app.win.clip.dnd
		dnd_clear_list(&d.accept)
		for t in types {
			append(&d.accept, strings.clone(t))
		}
	}
}

// drag_over reports a drag hovering over this window: where, and what it
// offers. The types are valid for this frame.
drag_over :: proc(ctx: ^Ctx) -> (pos: [2]f32, types: []string, ok: bool) {
	when ODIN_OS != .Linux {
		return
	} else {
		if ctx.app == nil {
			return
		}
		d := &ctx.app.win.clip.dnd
		if !d.over {
			return
		}
		return d.pos, d.offer_types[:], true
	}
}

// dropped hands over what was dropped on this window, in the frame after the
// drop. The strings are valid for that frame.
dropped :: proc(ctx: ^Ctx) -> (drop: Drop, ok: bool) {
	when ODIN_OS != .Linux {
		return
	} else {
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
}
