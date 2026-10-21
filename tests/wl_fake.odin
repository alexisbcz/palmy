// A compositor's end of a Wayland connection, for tests that drive palmy's
// Wayland backend without a compositor.
//
// The Window's socket is one end of a socketpair; the test holds the other,
// wrapped in palmy's own `Conn`: events are messages in the same wire format
// as requests, so `p.request` encodes them (descriptors included, over
// SCM_RIGHTS) and `p.conn_read` collects what palmy sent back. `p.window_pump`
// then reads and dispatches exactly as it would from sway. Nothing here knows
// about any particular interface: the tests spell out the opcodes they mean.
package palmy_tests

import "core:sys/linux"
import p "../palmy"

Fake_Wl :: struct {
	w:    ^p.Window,
	peer: p.Conn,
}

Fake_Request :: struct {
	id:     u32,
	opcode: u16,
	args:   []u8, // the body, in the temp allocator
}

// fake_wl_open wires `w` (a fresh Window when nil) to a fake compositor.
fake_wl_open :: proc(w: ^p.Window = nil) -> ^Fake_Wl {
	f := new(Fake_Wl)
	pair: [2]linux.Fd
	linux.socketpair(.UNIX, .STREAM, linux.Protocol(0), &pair)
	f.w = w != nil ? w : new(p.Window)
	f.w.backend = .Wayland
	f.w.width, f.w.height, f.w.scale = 400, 300, 1
	c := &f.w.conn
	c.fd = pair[0]
	c.out = make([dynamic]u8, 0, 4096)
	c.rx = make([dynamic]u8, 0, 8192)
	c.kinds = make([dynamic]p.Obj_Kind, 2)
	c.kinds[p.DISPLAY_ID] = .Display
	f.peer.fd = pair[1]
	f.peer.out = make([dynamic]u8, 0, 4096)
	f.peer.rx = make([dynamic]u8, 0, 8192)
	// Non-blocking on our side, so draining what palmy sent never waits.
	fl, _ := linux.fcntl(f.peer.fd, linux.F_GETFL)
	linux.fcntl(f.peer.fd, linux.F_SETFL, transmute(linux.Open_Flags)fl + {.NONBLOCK})
	return f
}

// fake_wl_close closes the fake end, and the Window's when it made the
// Window. A Window the caller passed in is theirs to close (`window_close`).
fake_wl_close :: proc(f: ^Fake_Wl, owns_window := true) {
	for fd in f.peer.rx_fds {
		linux.close(fd)
	}
	p.conn_close(&f.peer)
	if owns_window {
		p.conn_close(&f.w.conn)
		delete(f.w.input.keys)
		free(f.w)
	}
	free(f)
}

// fake_send writes one event.
fake_send :: proc(f: ^Fake_Wl, id: u32, opcode: u16, args: ..p.Arg) {
	p.request(&f.peer, id, opcode, ..args)
	p.conn_flush(&f.peer)
}

// fake_event writes one event whose arguments are all 32-bit words.
fake_event :: proc(f: ^Fake_Wl, id: u32, opcode: u16, args: ..u32) {
	a := make([]p.Arg, len(args), context.temp_allocator)
	for v, i in args {
		a[i] = v
	}
	fake_send(f, id, opcode, ..a)
}

// fake_array encodes a wl_array of u32 values as event words.
fake_array :: proc(vals: ..u32) -> []u32 {
	out := make([dynamic]u32, 0, 1 + len(vals), context.temp_allocator)
	append(&out, u32(4 * len(vals)))
	append(&out, ..vals)
	return out[:]
}

// fake_requests reads everything palmy has sent so far and splits it into
// messages. Descriptors that came with them wait in `fake_take_fd`.
fake_requests :: proc(f: ^Fake_Wl) -> []Fake_Request {
	p.conn_flush(&f.w.conn)
	p.conn_read(&f.peer)
	rx := &f.peer.rx
	out := make([dynamic]Fake_Request, 0, 16, context.temp_allocator)
	at := 0
	for at + 8 <= len(rx) {
		id := (^u32)(raw_data(rx[at:]))^
		hdr := (^u32)(raw_data(rx[at + 4:]))^
		size := int(hdr >> 16)
		if size < 8 || at + size > len(rx) {
			break
		}
		body := make([]u8, size - 8, context.temp_allocator)
		copy(body, rx[at + 8:at + size])
		append(&out, Fake_Request{id = id, opcode = u16(hdr & 0xffff), args = body})
		at += size
	}
	remove_range(rx, 0, at)
	return out[:]
}

fake_take_fd :: proc(f: ^Fake_Wl) -> (linux.Fd, bool) {
	return p.take_fd(&f.peer)
}

fake_arg :: proc(r: Fake_Request, i: int) -> u32 {
	if 4 * i + 4 > len(r.args) {
		return 0
	}
	return (^u32)(raw_data(r.args[4 * i:]))^
}

// fake_arg_string reads a string argument starting at word `i`.
fake_arg_string :: proc(r: Fake_Request, i: int) -> string {
	n := int(fake_arg(r, i))
	if n == 0 || 4 * i + 4 + n > len(r.args) {
		return ""
	}
	return string(r.args[4 * i + 4:][:n - 1])
}
