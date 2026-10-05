// wl_data_device_manager and zwp_primary_selection_device_manager_v1.
//
// Two protocols, one idea: the client that owns the data keeps it, and a paste
// is a pipe between two clients with the compositor only brokering the
// handshake. We never see the bytes, which is both the cheapest implementation
// and the only one that cannot leak a password into a log line.
//
// Drag and drop lives next door in dnd.odin; it shares the object model here
// (Data_Source, Data_Offer) and the descriptor hand-off below.
package wm

import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Stable references
// ---------------------------------------------------------------------------

// Data_Ref names an object without holding a pointer to it.
//
// This matters more than it looks. A wl_data_offer routinely outlives the
// wl_data_source it describes: the source client can destroy the source, or
// exit outright, while another client is still holding the offer and about to
// call receive on it. The old code stored `source: ^Data_Source` and
// dereferenced it there, which is a use-after-free the moment the owner quits
// -- exactly the "owner exits" path the protocol says must merely invalidate
// the offer.
//
// Client.index is handed out monotonically from Server.next_index and is never
// reused, so a reference to a client that has gone resolves to nothing rather
// than to recycled memory. cidx 0 means "no reference".
Data_Ref :: struct {
	cidx: int,
	id:   u32,
}

data_ref :: proc(c: ^Client, id: u32) -> Data_Ref {
	return Data_Ref{cidx = c.index, id = id}
}

// data_client resolves a reference to a live client, or nil.
data_client :: proc(s: ^Server, ref: Data_Ref) -> ^Client {
	if ref.cidx == 0 {
		return nil
	}
	for c in s.clients {
		if c.index == ref.cidx {
			return c.dead ? nil : c
		}
	}
	return nil
}

// data_obj resolves a reference to an object of a given kind, or nil.
data_obj :: proc(s: ^Server, ref: Data_Ref, kind: Kind) -> (^Client, rawptr) {
	c := data_client(s, ref)
	if c == nil {
		return nil, nil
	}
	o, ok := obj_get(c, ref.id)
	if !ok || o.kind != kind {
		return nil, nil
	}
	return c, o.p
}

// data_source_of resolves a reference to a usable wl_data_source.
data_source_of :: proc(s: ^Server, ref: Data_Ref) -> (^Client, ^Data_Source) {
	c, p := data_obj(s, ref, .Data_Source)
	if p == nil {
		return nil, nil
	}
	src := (^Data_Source)(p)
	if src.gone {
		return nil, nil
	}
	return c, src
}

data_surface_of :: proc(s: ^Server, ref: Data_Ref) -> ^Surface {
	_, p := data_obj(s, ref, .Surface)
	return (^Surface)(p)
}

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

Data_Source :: struct {
	client:      ^Client,
	id:          u32,
	ver:         u32,
	mimes:       [dynamic]string,
	gone:        bool,

	// Drag and drop. `actions` is what set_actions declared, `dnd` is set once
	// the source has been handed to start_drag, and `used` catches a source
	// being reused for a second selection or drag, which is a protocol error.
	dnd:         bool,
	used:        bool,
	actions:     u32,
	sent_action: u32,
	sent_target: bool,
}

Data_Device :: struct {
	client: ^Client,
	id:     u32,
}

Data_Offer :: struct {
	client: ^Client,
	id:     u32,
	src:    Data_Ref,

	// Drag-and-drop offers carry the negotiation; selection offers do not.
	// Nothing here owns heap memory: main.odin's client_free releases these
	// with a plain free(), so anything allocated would leak on client exit.
	dnd:      bool,
	accepted: bool,
	actions:  u32,
	pref:     u32,
}

// wl_data_device_manager.dnd_action
DND_NONE :: u32(0)
DND_COPY :: u32(1)
DND_MOVE :: u32(2)
DND_ASK :: u32(4)
DND_ALL :: DND_COPY | DND_MOVE | DND_ASK

// ---------------------------------------------------------------------------
// Pipe brokering, shared by both protocols
// ---------------------------------------------------------------------------

// data_handoff passes a receiving client's pipe descriptor straight to the
// client that owns the data.
//
// The compositor deliberately never reads or writes the pipe. That is what
// keeps a receiver which never drains it from stalling anything but the source
// client: the kernel's 64 KiB pipe buffer fills, the *source's* write blocks,
// and the compositor is not in the loop at all. It is also why the descriptor
// is left in whatever mode the receiver created it in -- O_NONBLOCK lives on
// the shared open file description, so setting it here would change the
// semantics of the source client's write() and silently truncate large pastes.
//
// Exactly one close happens for every descriptor we take: either here on the
// rejection paths, or inside event()/client_flush() once it has been queued
// into the control message.
data_handoff :: proc(c: ^Client, mime: string, owner: ^Client, owner_id: u32, op: u16) {
	fd, got := take_fd(c)
	if !got {
		log_line("client %d asked to receive without a descriptor", c.index)
		return
	}
	if owner == nil || owner.dead || mime == "" {
		linux.close(fd)
		return
	}
	event(owner, owner_id, op, mime, Fd(fd))
	client_flush(owner)
}

// data_drop_obj retires an object id. wl_display.delete_id exists so a client
// can reuse an id *it* allocated; sending it for one of ours makes libwayland
// print "received delete_id for unknown id", which is how this was noticed --
// every wl_data_offer and every primary-selection offer is server-allocated.
data_drop_obj :: proc(c: ^Client, id: u32) {
	if id >= SERVER_ID_BASE {
		delete_key(&c.objs, id)
		return
	}
	obj_drop(c, id)
}

// data_serial_ok rejects a serial we never issued. A serial from the future is
// a confused or hostile client; a zero serial is never valid.
data_serial_ok :: proc(s: ^Server, serial: u32) -> bool {
	return serial != 0 && serial <= s.serial
}

data_has_focus :: proc(s: ^Server, c: ^Client) -> bool {
	if s.kbd_surf != nil && s.kbd_surf.client == c {
		return true
	}
	if s.ptr_surf != nil && s.ptr_surf.client == c {
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// wl_data_device_manager
// ---------------------------------------------------------------------------

req_data_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		sid := r_u32(r)
		src := new(Data_Source)
		src.client = c
		src.id = sid
		src.ver = o.ver
		if !obj_new(c, sid, .Data_Source, o.ver, src) {
			free(src)
		}
	case 1:
		did := r_u32(r)
		r_u32(r) // seat
		dev := new(Data_Device)
		dev.client = c
		dev.id = did
		if !obj_new(c, did, .Data_Device, o.ver, dev) {
			free(dev)
			return
		}
		append(&c.data_devices, did)
		// A device created while this client already holds focus should see
		// the current selection straight away.
		if s.kbd_surf != nil && s.kbd_surf.client == c {
			offer_selection(s, c)
		}
	case 2:
		obj_drop(c, id)
	}
}

req_data_source :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	src := (^Data_Source)(o.p)
	switch op {
	case 0:
		// offer(mime_type)
		m := r_string(r)
		if r.bad || m == "" {
			return
		}
		append(&src.mimes, strings.clone(m))
	case 1:
		// destroy
		data_source_dropped(s, src)
		src.gone = true
		obj_drop(c, id)
		for m in src.mimes {
			delete(m)
		}
		delete(src.mimes)
		free(src)
	case 2:
		// set_actions(dnd_actions), v3
		a := r_u32(r)
		if r.bad {
			return
		}
		if a & ~DND_ALL != 0 {
			post_error(c, id, 0, "wl_data_source.set_actions with an unknown action")
			return
		}
		src.actions = a
		dnd_source_actions_changed(s, src)
	}
}

// data_source_dropped unhooks a source that is going away from everything that
// points at it. Offers hold a Data_Ref rather than a pointer, so they need no
// repair -- they simply stop resolving.
data_source_dropped :: proc(s: ^Server, src: ^Data_Source) {
	if s.selection == src {
		s.selection = nil
		broadcast_selection(s)
	}
	dnd_source_gone(s, src)
}

req_data_device :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// start_drag(source, origin, icon, serial)
		dnd_start(s, c, o, id, r)
	case 1:
		// set_selection(source, serial)
		sid := r_u32(r)
		serial := r_u32(r)
		if r.bad {
			return
		}
		if !data_serial_ok(s, serial) {
			log_line("client %d set_selection with serial %d we never issued", c.index, serial)
			return
		}
		if !data_has_focus(s, c) {
			// Not fatal: a client can lose focus between deciding to copy and
			// the request reaching us. Worth a line at -v, nothing more.
			log_line("client %d set the selection without focus", c.index)
		}

		var_new: ^Data_Source = nil
		if sid != 0 {
			so, ok := obj_get(c, sid)
			if !ok || so.kind != .Data_Source {
				return
			}
			ns := (^Data_Source)(so.p)
			if ns.dnd {
				post_error(c, id, 0, "wl_data_source already used for drag and drop")
				return
			}
			ns.used = true
			var_new = ns
		}

		old := s.selection
		s.selection = var_new
		if old != nil && old != var_new && !old.gone && !old.client.dead {
			event(old.client, old.id, 2) // wl_data_source.cancelled
			client_flush(old.client)
		}
		broadcast_selection(s)
	case 2:
		// release
		for d, i in c.data_devices {
			if d == id {
				ordered_remove(&c.data_devices, i)
				break
			}
		}
		dnd_device_gone(s, c, id)
		obj_drop(c, id)
	}
}

req_data_offer :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	off := (^Data_Offer)(o.p)
	switch op {
	case 0:
		// accept(serial, mime_type)
		r_u32(r)
		m := r_string(r)
		if r.bad {
			return
		}
		dnd_offer_accept(s, off, m)
	case 1:
		// receive(mime_type, fd)
		mime := r_string(r)
		if r.bad {
			// The descriptor still arrived; do not leak it.
			if fd, got := take_fd(c); got {
				linux.close(fd)
			}
			return
		}
		owner, src := data_source_of(s, off.src)
		data_handoff(c, mime, owner, src != nil ? src.id : 0, 1) // wl_data_source.send
	case 2:
		// destroy
		dnd_offer_gone(s, off)
		data_drop_obj(c, id)
		free(off)
	case 3:
		// finish, v3
		dnd_offer_finish(s, off, c, id)
	case 4:
		// set_actions(dnd_actions, preferred_action), v3
		a := r_u32(r)
		pref := r_u32(r)
		if r.bad {
			return
		}
		if a & ~DND_ALL != 0 || (pref != DND_NONE && pref & ~DND_ALL != 0) {
			post_error(c, id, 1, "wl_data_offer.set_actions with an unknown action") // invalid_action_mask
			return
		}
		dnd_offer_actions(s, off, a, pref)
	}
}

// ---------------------------------------------------------------------------
// Selection delivery
// ---------------------------------------------------------------------------

data_dev_ver :: proc(c: ^Client, dev: u32) -> u32 {
	if o, ok := obj_get(c, dev); ok {
		return o.ver
	}
	return 1
}

// data_new_offer mints a wl_data_offer in a client and sends the mime list.
// The id is server-allocated, so it is written straight into the object table
// rather than through obj_new, which only accepts client ids.
data_new_offer :: proc(s: ^Server, c: ^Client, dev: u32, src: ^Data_Source, dnd: bool) -> u32 {
	oid := server_id(c)
	off := new(Data_Offer)
	off.client = c
	off.id = oid
	off.src = data_ref(src.client, src.id)
	off.dnd = dnd
	c.objs[oid] = Object{kind = .Data_Offer, ver = data_dev_ver(c, dev), p = off}

	event(c, dev, 0, oid) // wl_data_device.data_offer(new_id)
	for m in src.mimes {
		event(c, oid, 0, m) // wl_data_offer.offer(mime)
	}
	return oid
}

// offer_selection publishes both current selections to one client.
//
// A client is offered its own selection back. That is not a courtesy: a
// terminal that copies and then pastes into itself is one client, and skipping
// it (as this code used to) made copy-and-paste inside a single foot window
// silently do nothing.
offer_selection :: proc(s: ^Server, c: ^Client) {
	prim_sweep(s)
	if c == nil || c.dead {
		return
	}

	src := s.selection
	if src != nil && (src.gone || src.client.dead) {
		// The owner went away between setting the selection and now.
		s.selection = nil
		src = nil
	}

	for dev in c.data_devices {
		if src == nil {
			event(c, dev, 5, u32(0)) // selection(nil)
			continue
		}
		oid := data_new_offer(s, c, dev, src, false)
		event(c, dev, 5, oid) // selection(offer)
	}

	prim_offer_to(s, c)
	client_flush(c)
}

broadcast_selection :: proc(s: ^Server) {
	if s.kbd_surf == nil {
		return
	}
	offer_selection(s, s.kbd_surf.client)
}

// ---------------------------------------------------------------------------
// zwp_primary_selection_device_manager_v1
//
// The same shape as wl_data_device_manager minus drag and drop, which is why
// it shares data_handoff, Data_Ref and the focus rules above rather than
// growing a second copy of them. All four interfaces share one Kind in the
// object table (.Prim) and discriminate on Prim_Obj.role, so the dispatch
// table in proto.odin needed a single case.
// ---------------------------------------------------------------------------

Prim_Role :: enum u8 {
	Mgr,
	Device,
	Source,
	Offer,
}

Prim_Obj :: struct {
	role:  Prim_Role,
	cidx:  int,
	id:    u32,
	ver:   u32,
	mimes: [dynamic]string, // Source only
	gone:  bool,
	src:   Data_Ref, // Offer -> its source
}

// Every primary-selection object lives here as well as in its client's object
// table. main.odin's client_free knows nothing about .Prim, so this list, swept
// against the live client set, is what keeps a client exit from leaking them.
@(private = "file")
prim_objs: [dynamic]^Prim_Obj

// The current primary selection, as a reference rather than a pointer for the
// same reason wl_data_offer holds one.
prim_sel: Data_Ref

prim_bind :: proc(c: ^Client, id: u32, ver: u32) {
	prim_obj_new(c, id, ver, .Mgr)
}

@(private = "file")
prim_obj_new :: proc(c: ^Client, id: u32, ver: u32, role: Prim_Role) -> ^Prim_Obj {
	po := new(Prim_Obj)
	po.role = role
	po.cidx = c.index
	po.id = id
	po.ver = ver
	if !obj_new(c, id, .Prim, ver, po) {
		free(po)
		return nil
	}
	append(&prim_objs, po)
	return po
}

@(private = "file")
prim_obj_free :: proc(po: ^Prim_Obj) {
	for i := len(prim_objs) - 1; i >= 0; i -= 1 {
		if prim_objs[i] == po {
			ordered_remove(&prim_objs, i)
		}
	}
	for m in po.mimes {
		delete(m)
	}
	delete(po.mimes)
	free(po)
}

// prim_sweep drops the objects of clients that have gone. It is cheap (a
// handful of objects against a handful of clients) and runs from
// offer_selection, which fires on every focus and selection change, so a
// departed client's objects never survive long even if data_pump is never
// wired into the main loop.
prim_sweep :: proc(s: ^Server) {
	for i := len(prim_objs) - 1; i >= 0; i -= 1 {
		po := prim_objs[i]
		live := false
		for c in s.clients {
			if c.index == po.cidx && !c.dead {
				live = true
				break
			}
		}
		if live {
			continue
		}
		if prim_sel.cidx == po.cidx {
			prim_sel = {}
		}
		ordered_remove(&prim_objs, i)
		for m in po.mimes {
			delete(m)
		}
		delete(po.mimes)
		free(po)
	}
}

@(private = "file")
prim_source_of :: proc(s: ^Server, ref: Data_Ref) -> (^Client, ^Prim_Obj) {
	c, p := data_obj(s, ref, .Prim)
	if p == nil {
		return nil, nil
	}
	po := (^Prim_Obj)(p)
	if po.role != .Source || po.gone {
		return nil, nil
	}
	return c, po
}

req_prim :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	po := (^Prim_Obj)(o.p)
	if po == nil {
		return
	}
	switch po.role {
	case .Mgr:
		switch op {
		case 0:
			// create_source(id)
			prim_obj_new(c, r_u32(r), o.ver, .Source)
		case 1:
			// get_device(id, seat)
			did := r_u32(r)
			r_u32(r)
			if prim_obj_new(c, did, o.ver, .Device) != nil {
				if s.kbd_surf != nil && s.kbd_surf.client == c {
					prim_offer_to(s, c)
					client_flush(c)
				}
			}
		case 2:
			obj_drop(c, id)
			prim_obj_free(po)
		}

	case .Source:
		switch op {
		case 0:
			// offer(mime_type)
			m := r_string(r)
			if r.bad || m == "" {
				return
			}
			append(&po.mimes, strings.clone(m))
		case 1:
			// destroy
			po.gone = true
			if prim_sel.cidx == po.cidx && prim_sel.id == po.id {
				prim_sel = {}
				prim_broadcast(s)
			}
			obj_drop(c, id)
			prim_obj_free(po)
		}

	case .Device:
		switch op {
		case 0:
			// set_selection(source, serial)
			sid := r_u32(r)
			serial := r_u32(r)
			if r.bad {
				return
			}
			// This is the request a pointer text selection turns into: the
			// client that owns the text sets it with the serial of the button
			// press that started the selection. That client very often holds
			// the pointer and not the keyboard, which is why data_has_focus
			// accepts either.
			if !data_serial_ok(s, serial) {
				log_line("client %d primary set_selection with serial %d we never issued", c.index, serial)
				return
			}
			if !data_has_focus(s, c) {
				log_line("client %d set the primary selection without focus", c.index)
			}
			old := prim_sel
			prim_sel = {}
			if sid != 0 {
				so, ok := obj_get(c, sid)
				if !ok || so.kind != .Prim {
					return
				}
				ns := (^Prim_Obj)(so.p)
				if ns.role != .Source || ns.gone {
					return
				}
				prim_sel = data_ref(c, sid)
			}
			if old.cidx != 0 && (old.cidx != prim_sel.cidx || old.id != prim_sel.id) {
				if oc, op_ := prim_source_of(s, old); op_ != nil {
					event(oc, op_.id, 1) // cancelled
					client_flush(oc)
				}
			}
			prim_broadcast(s)
		case 1:
			obj_drop(c, id)
			prim_obj_free(po)
		}

	case .Offer:
		switch op {
		case 0:
			// receive(mime_type, fd)
			mime := r_string(r)
			if r.bad {
				if fd, got := take_fd(c); got {
					linux.close(fd)
				}
				return
			}
			owner, src := prim_source_of(s, po.src)
			data_handoff(c, mime, owner, src != nil ? src.id : 0, 0) // source.send
		case 1:
			data_drop_obj(c, id)
			prim_obj_free(po)
		}
	}
}

// prim_offer_to publishes the primary selection to one client, mirroring
// offer_selection. Called from offer_selection so the two selections always
// travel together on a focus change.
prim_offer_to :: proc(s: ^Server, c: ^Client) {
	if c == nil || c.dead {
		return
	}
	_, src := prim_source_of(s, prim_sel)
	if src == nil {
		prim_sel = {}
	}

	// Snapshot the device list: minting an offer appends to prim_objs, and
	// that can reallocate the array out from under an iteration of it.
	devs: [dynamic]u32
	defer delete(devs)
	for po in prim_objs {
		if po.cidx == c.index && po.role == .Device {
			append(&devs, po.id)
		}
	}

	for dev in devs {
		if src == nil {
			event(c, dev, 1, u32(0)) // selection(nil)
			continue
		}
		oid := server_id(c)
		off := new(Prim_Obj)
		off.role = .Offer
		off.cidx = c.index
		off.id = oid
		off.ver = 1
		off.src = prim_sel
		c.objs[oid] = Object{kind = .Prim, ver = 1, p = off}
		append(&prim_objs, off)

		event(c, dev, 0, oid) // data_offer(new_id)
		for m in src.mimes {
			event(c, oid, 0, m) // offer(mime)
		}
		event(c, dev, 1, oid) // selection(offer)
	}
}

prim_broadcast :: proc(s: ^Server) {
	if s.kbd_surf == nil {
		return
	}
	c := s.kbd_surf.client
	prim_offer_to(s, c)
	client_flush(c)
}

// ---------------------------------------------------------------------------
// Main-loop seam
// ---------------------------------------------------------------------------

// data_pump is the one thing this file needs from the main loop: a call once a
// frame, after server_poll. It is cheap and never blocks.
//
//   - It retires the objects of clients that have exited, including the
//     primary-selection objects main.odin's client_free does not know about.
//   - It notices that a selection owner has gone and tells the focused client
//     the selection is empty, which is what the protocol asks for when a
//     source is destroyed and is otherwise only discovered on the next focus
//     change.
//   - It runs the drag watchdog, so a client that takes a drop and never sends
//     wl_data_offer.finish cannot wedge the pointer forever.
//
// It is deliberately not where clipboard bytes move: see data_handoff.
data_pump :: proc(s: ^Server) {
	prim_sweep(s)

	if s.selection != nil && (s.selection.gone || s.selection.client.dead) {
		s.selection = nil
		broadcast_selection(s)
	}
	if prim_sel.cidx != 0 {
		if _, src := prim_source_of(s, prim_sel); src == nil {
			prim_sel = {}
			prim_broadcast(s)
		}
	}

	dnd_tick(s)
}
