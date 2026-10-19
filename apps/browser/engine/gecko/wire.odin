// The Wayland wire protocol, server side, for the one client this compositor
// ever has: Firefox.
//
// Adapted from apps/wm/wire.odin, which is the same thing for a whole
// desktop. Encoding, SCM_RIGHTS descriptors and the delete_id bookkeeping are
// identical; what differs is that every client here is the same program and a
// misbehaving one ends the engine rather than being dropped politely.
package gecko

import "core:fmt"
import "core:sys/linux"

DISPLAY_ID :: u32(1)

Fixed :: distinct i32

fixed :: proc "contextless" (v: f32) -> Fixed {
	return Fixed(i32(v * 256))
}

Fd :: distinct linux.Fd

Arg :: union {
	u32,
	i32,
	Fixed,
	Fd,
	string,
	[]u8,
}

SOL_SOCKET :: 1
SCM_RIGHTS :: 1

Cmsg_Hdr :: struct {
	len:   uint,
	level: i32,
	type:  i32,
}

@(private = "file")
put_u32 :: proc(c: ^Client, v: u32) {
	b := transmute([4]u8)v
	append(&c.out, ..b[:])
}

// event queues one event. Descriptors travel with the message that names
// them, so a message carrying one is flushed at once.
event :: proc(c: ^Client, id: u32, opcode: u16, args: ..Arg) {
	if c.dead || id == 0 {
		for a in args {
			if fd, ok := a.(Fd); ok {
				linux.close(linux.Fd(fd))
			}
		}
		return
	}
	start := len(c.out)
	put_u32(c, id)
	put_u32(c, 0)
	for arg in args {
		switch v in arg {
		case u32:
			put_u32(c, v)
		case i32:
			put_u32(c, u32(v))
		case Fixed:
			put_u32(c, u32(i32(v)))
		case Fd:
			append(&c.out_fds, linux.Fd(v))
		case string:
			put_u32(c, u32(len(v) + 1))
			append(&c.out, v)
			append(&c.out, 0)
			for len(c.out) % 4 != 0 {
				append(&c.out, 0)
			}
		case []u8:
			put_u32(c, u32(len(v)))
			append(&c.out, ..v)
			for len(c.out) % 4 != 0 {
				append(&c.out, 0)
			}
		}
	}
	size := u32(len(c.out) - start)
	header := (u32(opcode) & 0xffff) | (size << 16)
	hb := transmute([4]u8)header
	copy(c.out[start + 4:][:4], hb[:])
	if len(c.out_fds) > 0 {
		client_flush(c)
	}
}

client_flush :: proc(c: ^Client) {
	if c.dead || len(c.out) == 0 {
		return
	}
	ctrl: [256]u8
	ctrl_len := 0
	if n := len(c.out_fds); n > 0 {
		payload := n * size_of(i32)
		hdr := Cmsg_Hdr {
			len   = uint(size_of(Cmsg_Hdr) + payload),
			level = SOL_SOCKET,
			type  = SCM_RIGHTS,
		}
		hb := transmute([size_of(Cmsg_Hdr)]u8)hdr
		copy(ctrl[:], hb[:])
		for fd, i in c.out_fds {
			fb := transmute([4]u8)i32(fd)
			copy(ctrl[size_of(Cmsg_Hdr) + i * 4:][:4], fb[:])
		}
		ctrl_len = (size_of(Cmsg_Hdr) + payload + 7) & ~int(7)
	}
	sent := 0
	stalls := 0
	for sent < len(c.out) {
		remaining := uint(len(c.out)) - uint(sent)
		iov := [1]linux.IO_Vec{{base = raw_data(c.out[sent:]), len = remaining}}
		hdr := linux.Msg_Hdr {
			iov = iov[:],
		}
		if sent == 0 && ctrl_len > 0 {
			hdr.control = ctrl[:ctrl_len]
		}
		n, err := linux.sendmsg(c.fd, &hdr, {.NOSIGNAL})
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			stalls += 1
			if stalls > 200 {
				logf("client stopped reading its socket")
				c.dead = true
				break
			}
			pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
			linux.poll(pfd[:], 5)
			continue
		}
		if err != .NONE || n <= 0 {
			c.dead = true
			break
		}
		sent += n
	}
	for fd in c.out_fds {
		linux.close(fd)
	}
	clear(&c.out_fds)
	clear(&c.out)
}

client_read :: proc(c: ^Client) -> bool {
	staging: [32768]u8
	ctrl: [512]u8
	for {
		iov := [1]linux.IO_Vec{{base = &staging[0], len = len(staging)}}
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = ctrl[:],
		}
		n, err := linux.recvmsg(c.fd, &hdr, {.CMSG_CLOEXEC})
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			return true
		}
		if err != .NONE || n == 0 {
			if err != .NONE {
				logf("reading the client failed: %v", err)
			}
			return false
		}
		append(&c.rx, ..staging[:n])
		off := 0
		for off + size_of(Cmsg_Hdr) <= len(hdr.control) {
			cm := (^Cmsg_Hdr)(raw_data(hdr.control[off:]))
			if cm.len < size_of(Cmsg_Hdr) || off + int(cm.len) > len(hdr.control) {
				break
			}
			if cm.level == SOL_SOCKET && cm.type == SCM_RIGHTS {
				count := (int(cm.len) - size_of(Cmsg_Hdr)) / 4
				for i in 0 ..< count {
					fd := (^i32)(raw_data(hdr.control[off + size_of(Cmsg_Hdr) + i * 4:]))^
					append(&c.rx_fds, linux.Fd(fd))
				}
			}
			off += (int(cm.len) + 7) & ~int(7)
		}
		if n < len(staging) {
			return true
		}
	}
}

Reader :: struct {
	b:   []u8,
	p:   int,
	bad: bool,
}

r_u32 :: proc(r: ^Reader) -> u32 {
	if r.p + 4 > len(r.b) {
		r.bad = true
		return 0
	}
	v := (^u32)(raw_data(r.b[r.p:]))^
	r.p += 4
	return v
}

r_i32 :: proc(r: ^Reader) -> i32 {
	return i32(r_u32(r))
}

r_fixed :: proc(r: ^Reader) -> f32 {
	return f32(r_i32(r)) / 256
}

r_string :: proc(r: ^Reader) -> string {
	n := int(r_u32(r))
	if n == 0 || r.p + n > len(r.b) {
		if n != 0 {
			r.bad = true
		}
		return ""
	}
	s := string(r.b[r.p:r.p + n - 1])
	r.p += (n + 3) & ~int(3)
	return s
}

r_array :: proc(r: ^Reader) -> []u8 {
	n := int(r_u32(r))
	if r.p + n > len(r.b) {
		r.bad = true
		return nil
	}
	s := r.b[r.p:r.p + n]
	r.p += (n + 3) & ~int(3)
	return s
}

take_fd :: proc(c: ^Client) -> (linux.Fd, bool) {
	if len(c.rx_fds) == 0 {
		return -1, false
	}
	fd := c.rx_fds[0]
	ordered_remove(&c.rx_fds, 0)
	return fd, true
}

client_dispatch :: proc(c: ^Client) {
	consumed := 0
	for !c.dead {
		avail := len(c.rx) - consumed
		if avail < 8 {
			break
		}
		id := (^u32)(raw_data(c.rx[consumed:]))^
		header := (^u32)(raw_data(c.rx[consumed + 4:]))^
		opcode := u16(header & 0xffff)
		size := int(header >> 16)
		if size < 8 {
			c.dead = true
			break
		}
		if size > avail {
			break
		}
		body := c.rx[consumed + 8:consumed + size]
		rr := Reader {
			b = body,
		}
		handle_request(c, id, opcode, &rr)
		consumed += size
	}
	if consumed > 0 {
		remaining := len(c.rx) - consumed
		if remaining > 0 {
			copy(c.rx[:remaining], c.rx[consumed:])
		}
		resize(&c.rx, remaining)
	}
}

post_error :: proc(c: ^Client, id: u32, code: u32, msg: string) {
	event(c, DISPLAY_ID, 0, id, code, msg)
	client_flush(c)
	logf("protocol error on object %d: %s", id, msg)
	c.dead = true
}

logf :: proc(format: string, args: ..any) {
	fmt.eprintf("gecko-host: ")
	fmt.eprintfln(format, ..args)
}
