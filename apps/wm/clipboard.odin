// wl_data_device_manager: the selection half of it.
//
// foot refuses to start without this global, and a terminal without copy and
// paste is not much of a terminal, so this is a real clipboard rather than a
// stub: the owning client keeps the data, and a paste turns into a pipe
// between the two clients with the compositor only brokering the handshake.
// Drag and drop is accepted and ignored.
package wm

import "core:strings"
import "core:sys/linux"

Data_Source :: struct {
	client: ^Client,
	id:     u32,
	mimes:  [dynamic]string,
	gone:   bool,
}

Data_Device :: struct {
	client: ^Client,
	id:     u32,
}

Data_Offer :: struct {
	client: ^Client,
	id:     u32,
	source: ^Data_Source,
}

req_data_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		sid := r_u32(r)
		src := new(Data_Source)
		src.client = c
		src.id = sid
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
		// A device created while this client already holds focus should see the
		// current selection straight away.
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
		append(&src.mimes, strings.clone(r_string(r)))
	case 1:
		if s.selection == src {
			s.selection = nil
			broadcast_selection(s)
		}
		src.gone = true
		obj_drop(c, id)
		for m in src.mimes {
			delete(m)
		}
		delete(src.mimes)
		free(src)
	case 2:
		r_u32(r)
	}
}

req_data_device :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// start_drag: accepted, but this compositor does not do drag and drop.
		r_u32(r);r_u32(r);r_u32(r);r_u32(r)
	case 1:
		// set_selection(source, serial)
		sid := r_u32(r)
		r_u32(r)
		old := s.selection
		s.selection = nil
		if sid != 0 {
			if so, ok := obj_get(c, sid); ok && so.kind == .Data_Source {
				s.selection = (^Data_Source)(so.p)
			}
		}
		if old != nil && old != s.selection && !old.gone && !old.client.dead {
			event(old.client, old.id, 2) // wl_data_source.cancelled
			client_flush(old.client)
		}
		broadcast_selection(s)
	case 2:
		for d, i in c.data_devices {
			if d == id {
				ordered_remove(&c.data_devices, i)
				break
			}
		}
		obj_drop(c, id)
	}
}

req_data_offer :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	off := (^Data_Offer)(o.p)
	switch op {
	case 0:
		r_u32(r);r_string(r)
	case 1:
		// receive(mime, fd): hand the descriptor to the owning client and let
		// the two of them talk over the pipe directly.
		mime := r_string(r)
		fd, got := take_fd(c)
		if !got {
			return
		}
		src := off.source
		if src == nil || src.gone || src.client.dead {
			linux.close(fd)
			return
		}
		event(src.client, src.id, 1, mime, Fd(fd))
		client_flush(src.client)
	case 2:
		obj_drop(c, id)
		free(off)
	case 3:
	case 4:
		r_u32(r);r_u32(r)
	}
}

// offer_selection publishes the current selection to one client.
offer_selection :: proc(s: ^Server, c: ^Client) {
	if c.dead || len(c.data_devices) == 0 {
		return
	}
	src := s.selection
	for dev in c.data_devices {
		if src == nil || src.gone || src.client == c {
			// A client never has to be offered its own selection back, but it
			// does have to be told when there is nothing.
			if src == nil || src.gone {
				event(c, dev, 5, u32(0))
			}
			continue
		}
		oid := server_id(c)
		off := new(Data_Offer)
		off.client = c
		off.id = oid
		off.source = src
		c.objs[oid] = Object{kind = .Data_Offer, ver = 3, p = off}

		event(c, dev, 0, oid) // data_offer(new_id)
		for m in src.mimes {
			event(c, oid, 0, m) // wl_data_offer.offer(mime)
		}
		event(c, dev, 5, oid) // selection(offer)
	}
	client_flush(c)
}

broadcast_selection :: proc(s: ^Server) {
	if s.kbd_surf == nil {
		return
	}
	offer_selection(s, s.kbd_surf.client)
}
