// A compositor's end of a Wayland connection, for tests that drive palmy's
// Wayland backend without a compositor.
//
// The Window's socket is one end of a socketpair; the test holds the other.
// Events are encoded here and written to it, `p.window_pump` reads and
// dispatches them exactly as it would from sway, and the requests palmy sends
// back are decoded from the same socket. Nothing below knows about any
// particular interface: the tests spell out the opcodes they mean.
package palmy_tests

import "core:sys/linux"
import p "../palmy"

Fake_Wl :: struct {
	w:    ^p.Window,
	peer: linux.Fd,
	rx:   [dynamic]u8,
}

Fake_Request :: struct {
	id:     u32,
	opcode: u16,
	args:   []u8, // the body, valid until the next fake_requests
}

fake_wl_open :: proc() -> ^Fake_Wl {
	f := new(Fake_Wl)
	pair: [2]linux.Fd
	linux.socketpair(.UNIX, .STREAM, linux.Protocol(0), &pair)
	f.w = new(p.Window)
	f.w.backend = .Wayland
	f.w.width, f.w.height, f.w.scale = 400, 300, 1
	c := &f.w.conn
	c.fd = pair[0]
	c.out = make([dynamic]u8, 0, 4096)
	c.rx = make([dynamic]u8, 0, 8192)
	c.kinds = make([dynamic]p.Obj_Kind, 2)
	c.kinds[p.DISPLAY_ID] = .Display
	f.peer = pair[1]
	// Non-blocking on our side, so draining what palmy sent never waits.
	fl, _ := linux.fcntl(f.peer, linux.F_GETFL)
	linux.fcntl(f.peer, linux.F_SETFL, transmute(linux.Open_Flags)fl + {.NONBLOCK})
	return f
}

fake_wl_close :: proc(f: ^Fake_Wl) {
	linux.close(f.peer)
	p.conn_close(&f.w.conn)
	delete(f.w.input.keys)
	delete(f.rx)
	free(f.w)
	free(f)
}

// fake_event writes one event: `args` are 32-bit words, already encoded.
fake_event :: proc(f: ^Fake_Wl, id: u32, opcode: u16, args: ..u32) {
	size := u32(8 + 4 * len(args))
	msg := make([dynamic]u32, 0, 2 + len(args), context.temp_allocator)
	append(&msg, id, u32(opcode) | size << 16)
	append(&msg, ..args)
	bytes := ([^]u8)(raw_data(msg))[:size]
	linux.write(f.peer, bytes)
}

// fake_array encodes a wl_array of u32 values as event words.
fake_array :: proc(vals: ..u32) -> []u32 {
	out := make([dynamic]u32, 0, 1 + len(vals), context.temp_allocator)
	append(&out, u32(4 * len(vals)))
	append(&out, ..vals)
	return out[:]
}

// fake_requests reads everything palmy has sent so far and splits it into
// messages.
fake_requests :: proc(f: ^Fake_Wl) -> []Fake_Request {
	p.conn_flush(&f.w.conn)
	buf: [8192]u8
	for {
		n, err := linux.read(f.peer, buf[:])
		if err != .NONE || n <= 0 {
			break
		}
		append(&f.rx, ..buf[:n])
	}
	out := make([dynamic]Fake_Request, 0, 16, context.temp_allocator)
	at := 0
	for at + 8 <= len(f.rx) {
		id := (^u32)(raw_data(f.rx[at:]))^
		hdr := (^u32)(raw_data(f.rx[at + 4:]))^
		size := int(hdr >> 16)
		if size < 8 || at + size > len(f.rx) {
			break
		}
		body := make([]u8, size - 8, context.temp_allocator)
		copy(body, f.rx[at + 8:at + size])
		append(&out, Fake_Request{id = id, opcode = u16(hdr & 0xffff), args = body})
		at += size
	}
	remove_range(&f.rx, 0, at)
	return out[:]
}

fake_arg :: proc(r: Fake_Request, i: int) -> u32 {
	if 4 * i + 4 > len(r.args) {
		return 0
	}
	return (^u32)(raw_data(r.args[4 * i:]))^
}
