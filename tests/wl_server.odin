// A small Wayland compositor for tests: enough of wl_compositor, wl_shm,
// xdg_shell and wl_seat for `palmy.create` to open a real App on it, and for
// popups to be created, configured, painted and dismissed. It runs on its own
// thread and answers on its own; the test sends input through it and reads
// what palmy asked for from its log.
//
// It is deliberately literal: every request it does not care about is logged
// and otherwise ignored, and it never sends an event it was not asked for.
package palmy_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import p "../palmy"

Srv_Positioner :: struct {
	size:    [2]i32,
	anchor:  [4]i32,
	anc:     u32,
	grav:    u32,
	adjust:  u32,
	offset:  [2]i32,
}

Srv_Popup :: struct {
	id:         u32,
	xdg:        u32,
	surface:    u32,
	parent:     u32,
	pos:        Srv_Positioner,
	grab:       u32, // serial, 0 when it did not grab
	configured: bool,
	rect:       [4]i32, // x, y, w, h as configured
	destroyed:  bool,
}

Srv_Buffer :: struct {
	pool:   u32,
	offset: int,
	w, h:   int,
	stride: int,
	format: u32,
}

Srv_Commit :: struct {
	surface: u32,
	buffer:  u32,
	format:  u32,
	w, h:    int,
	px:      []u32, // a copy of the pixels at commit
	geometry: [4]i32,
	acked:   u32,
}

Wl_Server :: struct {
	listen:   linux.Fd,
	path:     string,
	conn:     p.Conn,
	lock:     sync.Mutex,
	thread:   ^thread.Thread,
	stop:     bool,
	running:  bool,

	ifaces:   map[u32]string,
	positioners: map[u32]Srv_Positioner,
	popups:   [dynamic]Srv_Popup,
	pools:    map[u32][]u8,
	buffers:  map[u32]Srv_Buffer,
	attached: map[u32]u32, // surface -> buffer
	geometry: map[u32][4]i32, // xdg_surface -> window geometry
	acked:    map[u32]u32, // xdg_surface -> last ack_configure serial
	xdg_of:   map[u32]u32, // wl_surface -> xdg_surface
	commits:  [dynamic]Srv_Commit,
	log:      [dynamic]string,

	serial:   u32,
	toplevel_surface: u32,
	toplevel_xdg:     u32,
	toplevel_configured: bool,
	seat:     u32,
	pointer:  u32,
	keyboard: u32,
	wm_base_version: u32,
	// The test's allocator, so what the server thread allocates is freed
	// by the same one (the test runner tracks it).
	allocator: mem.Allocator,
}

// server_start listens on a fresh socket and points WAYLAND_DISPLAY at it.
server_start :: proc(wm_base_version: u32 = 2) -> ^Wl_Server {
	s := new(Wl_Server)
	s.wm_base_version = wm_base_version
	s.allocator = context.allocator
	s.serial = 100
	s.path = fmt.aprintf("/tmp/palmy-test-wl-%d-%d", linux.getpid(), time.tick_now()._nsec)
	sock, _ := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	copy(addr.sun_path[:], s.path)
	linux.bind(sock, &addr)
	linux.listen(sock, 1)
	s.listen = sock
	os.set_env("WAYLAND_DISPLAY", s.path)
	s.running = true
	s.thread = thread.create_and_start_with_data(s, server_loop)
	return s
}

server_stop :: proc(s: ^Wl_Server) {
	sync.mutex_lock(&s.lock)
	s.stop = true
	sync.mutex_unlock(&s.lock)
	thread.join(s.thread)
	thread.destroy(s.thread)
	linux.close(s.listen)
	os.unset_env("WAYLAND_DISPLAY")
	unlink_path(s.path)
	for fd in s.conn.rx_fds {
		linux.close(fd)
	}
	p.conn_close(&s.conn)
	for _, mem in s.pools {
		linux.munmap(raw_data(mem), uint(len(mem)))
	}
	for _, name in s.ifaces {
		delete(name)
	}
	for c in s.commits {
		delete(c.px)
	}
	for l in s.log {
		delete(l)
	}
	delete(s.ifaces)
	delete(s.positioners)
	delete(s.popups)
	delete(s.pools)
	delete(s.buffers)
	delete(s.attached)
	delete(s.geometry)
	delete(s.acked)
	delete(s.xdg_of)
	delete(s.commits)
	delete(s.log)
	delete(s.path)
	free(s)
}

@(private = "file")
unlink_path :: proc(path: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)
}

@(private = "file")
server_loop :: proc(data: rawptr) {
	s := (^Wl_Server)(data)
	context.allocator = s.allocator
	// Accept the one client.
	for {
		pfd := [1]linux.Poll_Fd{{fd = s.listen, events = {.IN}}}
		p.poll_fds(pfd[:], 20)
		if .IN in pfd[0].revents {
			fd, err := linux.accept(s.listen, (^linux.Sock_Addr_Un)(nil), {.CLOEXEC, .NONBLOCK})
			if err == .NONE {
				s.conn.fd = fd
				s.conn.out = make([dynamic]u8, 0, 4096)
				s.conn.rx = make([dynamic]u8, 0, 8192)
				break
			}
		}
		sync.mutex_lock(&s.lock)
		stop := s.stop
		sync.mutex_unlock(&s.lock)
		if stop {
			return
		}
	}
	for {
		pfd := [1]linux.Poll_Fd{{fd = s.conn.fd, events = {.IN}}}
		p.poll_fds(pfd[:], 10)
		sync.mutex_lock(&s.lock)
		if s.stop {
			sync.mutex_unlock(&s.lock)
			return
		}
		if .IN in pfd[0].revents {
			if !p.conn_read(&s.conn) {
				sync.mutex_unlock(&s.lock)
				return
			}
			server_dispatch(s)
		}
		p.conn_flush(&s.conn)
		sync.mutex_unlock(&s.lock)
	}
}

// server_send sends one event from the test's thread.
server_send :: proc(s: ^Wl_Server, id: u32, opcode: u16, args: ..p.Arg) {
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	p.request(&s.conn, id, opcode, ..args)
	p.conn_flush(&s.conn)
}

server_next_serial :: proc(s: ^Wl_Server) -> u32 {
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	s.serial += 1
	return s.serial
}

// server_locked runs `body` with the server's state stable.
server_with :: proc(s: ^Wl_Server, user: rawptr, body: proc(s: ^Wl_Server, user: rawptr)) {
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	body(s, user)
}

// server_wait waits until `cond` holds, for at most `ms`.
server_wait :: proc(s: ^Wl_Server, ms: int, cond: proc(s: ^Wl_Server) -> bool) -> bool {
	deadline := time.time_add(time.now(), time.Duration(ms) * time.Millisecond)
	for time.since(deadline) < 0 {
		sync.mutex_lock(&s.lock)
		ok := cond(s)
		sync.mutex_unlock(&s.lock)
		if ok {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private = "file")
logf :: proc(s: ^Wl_Server, format: string, args: ..any) {
	append(&s.log, fmt.aprintf(format, ..args))
}

@(private = "file")
Rd :: struct {
	b: []u8,
	p: int,
}

@(private = "file")
ru :: proc(r: ^Rd) -> u32 {
	if r.p + 4 > len(r.b) {
		return 0
	}
	v := (^u32)(raw_data(r.b[r.p:]))^
	r.p += 4
	return v
}

@(private = "file")
ri :: proc(r: ^Rd) -> i32 {
	return i32(ru(r))
}

@(private = "file")
rs :: proc(r: ^Rd) -> string {
	n := int(ru(r))
	if n == 0 || r.p + n > len(r.b) {
		return ""
	}
	str := string(r.b[r.p:r.p + n - 1])
	r.p += (n + 3) & ~int(3)
	return str
}

@(private = "file")
ev :: proc(s: ^Wl_Server, id: u32, opcode: u16, args: ..p.Arg) {
	p.request(&s.conn, id, opcode, ..args)
}

@(private = "file")
new_obj :: proc(s: ^Wl_Server, id: u32, iface: string) {
	if old, ok := s.ifaces[id]; ok {
		delete(old)
	}
	s.ifaces[id] = strings.clone(iface)
}

@(private = "file")
server_dispatch :: proc(s: ^Wl_Server) {
	rx := &s.conn.rx
	at := 0
	for at + 8 <= len(rx) {
		id := (^u32)(raw_data(rx[at:]))^
		hdr := (^u32)(raw_data(rx[at + 4:]))^
		size := int(hdr >> 16)
		if size < 8 || at + size > len(rx) {
			break
		}
		r := Rd{b = rx[at + 8:at + size]}
		server_request(s, id, u16(hdr & 0xffff), &r)
		at += size
	}
	remove_range(rx, 0, at)
}

@(private = "file")
server_request :: proc(s: ^Wl_Server, id: u32, op: u16, r: ^Rd) {
	iface := id == 1 ? "wl_display" : (s.ifaces[id] or_else "?")
	switch iface {
	case "wl_display":
		switch op {
		case 0:
			cb := ru(r)
			ev(s, cb, 0, u32(0))
			ev(s, 1, 1, cb) // delete_id
		case 1:
			reg := ru(r)
			new_obj(s, reg, "wl_registry")
			ev(s, reg, 0, u32(1), "wl_compositor", u32(4))
			ev(s, reg, 0, u32(2), "wl_shm", u32(1))
			ev(s, reg, 0, u32(3), "xdg_wm_base", s.wm_base_version)
			ev(s, reg, 0, u32(4), "wl_seat", u32(7))
		}
	case "wl_registry":
		ru(r)
		name := rs(r)
		ru(r)
		nid := ru(r)
		new_obj(s, nid, name)
		logf(s, "bind %s", name)
		if name == "wl_seat" {
			s.seat = nid
			ev(s, nid, 0, u32(3)) // pointer | keyboard
		}
	case "wl_compositor":
		nid := ru(r)
		new_obj(s, nid, op == 0 ? "wl_surface" : "wl_region")
	case "wl_shm":
		if op == 0 {
			nid := ru(r)
			size := int(ri(r))
			new_obj(s, nid, "wl_shm_pool")
			if fd, ok := p.take_fd(&s.conn); ok {
				mem, err := linux.mmap(0, uint(size), {.READ}, {.SHARED}, fd, 0)
				if err == .NONE {
					s.pools[nid] = ([^]u8)(mem)[:size]
				}
				linux.close(fd)
			}
		}
	case "wl_shm_pool":
		if op == 0 {
			nid := ru(r)
			b := Srv_Buffer{pool = id}
			b.offset = int(ri(r))
			b.w = int(ri(r))
			b.h = int(ri(r))
			b.stride = int(ri(r))
			b.format = ru(r)
			s.buffers[nid] = b
			new_obj(s, nid, "wl_buffer")
		}
	case "wl_seat":
		nid := ru(r)
		if op == 0 {
			s.pointer = nid
			new_obj(s, nid, "wl_pointer")
		} else if op == 1 {
			s.keyboard = nid
			new_obj(s, nid, "wl_keyboard")
		}
	case "wl_surface":
		switch op {
		case 0:
			logf(s, "surface.destroy %d", id)
		case 1:
			s.attached[id] = ru(r)
		case 3:
			cb := ru(r)
			// The frame is shown at once.
			ev(s, cb, 0, u32(0))
			ev(s, 1, 1, cb)
		case 6:
			server_commit(s, id)
		}
	case "xdg_wm_base":
		switch op {
		case 1:
			nid := ru(r)
			new_obj(s, nid, "xdg_positioner")
			s.positioners[nid] = {}
		case 2:
			nid := ru(r)
			surf := ru(r)
			new_obj(s, nid, "xdg_surface")
			s.xdg_of[surf] = nid
		}
	case "xdg_positioner":
		ps := &s.positioners[id]
		switch op {
		case 1:
			ps.size = {ri(r), ri(r)}
		case 2:
			ps.anchor = {ri(r), ri(r), ri(r), ri(r)}
		case 3:
			ps.anc = ru(r)
		case 4:
			ps.grav = ru(r)
		case 5:
			ps.adjust = ru(r)
		case 6:
			ps.offset = {ri(r), ri(r)}
		}
	case "xdg_surface":
		switch op {
		case 0:
			logf(s, "xdg_surface.destroy %d", id)
		case 1:
			nid := ru(r)
			new_obj(s, nid, "xdg_toplevel")
			s.toplevel_xdg = id
			for surf, x in s.xdg_of {
				if x == id {
					s.toplevel_surface = surf
				}
			}
		case 2:
			nid := ru(r)
			parent := ru(r)
			pos := ru(r)
			new_obj(s, nid, "xdg_popup")
			pp := Srv_Popup{id = nid, xdg = id, parent = parent, pos = s.positioners[pos]}
			for surf, x in s.xdg_of {
				if x == id {
					pp.surface = surf
				}
			}
			append(&s.popups, pp)
			logf(s, "get_popup %d parent %d size %v anchor %v anc %d grav %d adjust %d offset %v", nid, parent, pp.pos.size, pp.pos.anchor, pp.pos.anc, pp.pos.grav, pp.pos.adjust, pp.pos.offset)
		case 3:
			s.geometry[id] = {ri(r), ri(r), ri(r), ri(r)}
		case 4:
			s.acked[id] = ru(r)
		}
	case "xdg_popup":
		for &pp in s.popups {
			if pp.id != id {
				continue
			}
			switch op {
			case 0:
				pp.destroyed = true
				logf(s, "popup.destroy %d", id)
			case 1:
				ru(r)
				pp.grab = ru(r)
				logf(s, "popup.grab %d serial %d", id, pp.grab)
			}
		}
	}
}

// server_commit answers a surface's first commit with a configure, and
// records every commit that carries a buffer.
@(private = "file")
server_commit :: proc(s: ^Wl_Server, surf: u32) {
	if surf == s.toplevel_surface && !s.toplevel_configured {
		s.toplevel_configured = true
		top: u32
		for oid, name in s.ifaces {
			if name == "xdg_toplevel" {
				top = oid
			}
		}
		states := []u8{}
		ev(s, top, 0, i32(400), i32(300), states)
		s.serial += 1
		ev(s, s.toplevel_xdg, 0, s.serial)
		return
	}
	for &pp in s.popups {
		if pp.surface != surf || pp.destroyed || pp.configured {
			continue
		}
		pp.configured = true
		pp.rect = popup_server_place(pp.pos)
		ev(s, pp.id, 0, pp.rect[0], pp.rect[1], pp.rect[2], pp.rect[3])
		s.serial += 1
		ev(s, pp.xdg, 0, s.serial)
		logf(s, "configure popup %d at %v", pp.id, pp.rect)
		return
	}
	if buf, ok := s.attached[surf]; ok && buf != 0 {
		b := s.buffers[buf]
		c := Srv_Commit{surface = surf, buffer = buf, format = b.format, w = b.w, h = b.h}
		if mem, has := s.pools[b.pool]; has && b.offset + b.stride * b.h <= len(mem) {
			c.px = make([]u32, b.w * b.h)
			for y in 0 ..< b.h {
				row := mem[b.offset + y * b.stride:]
				copy(c.px[y * b.w:][:b.w], ([^]u32)(raw_data(row))[:b.w])
			}
		}
		xdg := s.xdg_of[surf]
		c.geometry = s.geometry[xdg]
		c.acked = s.acked[xdg]
		append(&s.commits, c)
		s.attached[surf] = 0
		// Released at once: the test compositor has no screen to hold it.
		ev(s, buf, 0)
	}
}

// popup_server_place follows the positioner without any constraint:
// the anchor point on the anchor rectangle, then the gravity, then the offset.
popup_server_place :: proc(ps: Srv_Positioner) -> [4]i32 {
	a := ps.anchor
	pt := [2]i32{a[0] + a[2] / 2, a[1] + a[3] / 2}
	switch ps.anc {
	case 1: pt.y = a[1]
	case 2: pt.y = a[1] + a[3]
	case 3: pt.x = a[0]
	case 4: pt.x = a[0] + a[2]
	case 5: pt = {a[0], a[1]}
	case 6: pt = {a[0], a[1] + a[3]}
	case 7: pt = {a[0] + a[2], a[1]}
	case 8: pt = {a[0] + a[2], a[1] + a[3]}
	}
	w, h := ps.size.x, ps.size.y
	x, y := pt.x - w / 2, pt.y - h / 2
	switch ps.grav {
	case 1: y = pt.y - h
	case 2: y = pt.y
	case 3: x = pt.x - w
	case 4: x = pt.x
	case 5: x, y = pt.x - w, pt.y - h
	case 6: x, y = pt.x - w, pt.y
	case 7: x, y = pt.x, pt.y - h
	case 8: x, y = pt.x, pt.y
	}
	return {x + ps.offset.x, y + ps.offset.y, w, h}
}
