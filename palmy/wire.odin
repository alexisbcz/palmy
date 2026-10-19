package palmy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Wayland wire protocol.
//
// This is a direct implementation of the protocol described in wayland.xml: a
// stream of 32-bit-aligned messages over a unix socket, with file descriptors
// travelling out of band in SCM_RIGHTS control messages. There is no libwayland
// here, so a palmy binary links against nothing but libc.
// ---------------------------------------------------------------------------

DISPLAY_ID :: u32(1)

// Obj_Kind tells the event dispatcher which interface an object id belongs to,
// so that an (id, opcode) pair can be resolved to an event.
Obj_Kind :: enum u8 {
	None,
	Display,
	Registry,
	Callback,
	Frame_Callback,
	Compositor,
	Shm,
	Shm_Pool,
	Surface,
	Buffer,
	Xdg_Wm_Base,
	Xdg_Surface,
	Xdg_Toplevel,
	Seat,
	Pointer,
	Keyboard,
	Decor_Manager,
	Decoration,
	Output,
	Region,
	Cursor_Manager,
	Cursor_Device,
	Layer_Shell,
	Layer_Surface,

	// The clipboard: wl_data_device_manager and the primary selection
	// protocol. Offers are created by the server, see `server_kinds`.
	Data_Device_Manager,
	Data_Device,
	Data_Source,
	Data_Offer,
	Primary_Manager,
	Primary_Device,
	Primary_Source,
	Primary_Offer,

	// The object has been destroyed locally but the server has not confirmed
	// it yet, so its id must not be handed out again.
	Dead,
}

// Fixed is wl_fixed_t: a signed 24.8 fixed point number.
Fixed :: distinct i32

fixed_to_f32 :: proc "contextless" (v: Fixed) -> f32 {
	return f32(i32(v)) / 256
}

// Fd wraps a file descriptor so that the argument encoder can tell it apart
// from a plain integer and route it into the socket's control message.
Fd :: distinct linux.Fd

// Obj is an object id argument. Nil objects are encoded as 0.
Obj :: distinct u32

// Arg is one argument of a request.
Arg :: union {
	u32,
	i32,
	Obj,
	Fixed,
	Fd,
	string,
	[]u8,
}

Conn :: struct {
	fd:       linux.Fd,
	out:      [dynamic]u8,
	out_fds:  [dynamic]linux.Fd,
	rx:       [dynamic]u8,
	rx_fds:   [dynamic]linux.Fd,
	kinds:    [dynamic]Obj_Kind,
	free_ids: [dynamic]u32,
	fatal:    string,

	// Objects the server created (ids from 0xff000000 up), which an event
	// introduces with a new_id argument: today only clipboard offers. They
	// are forgotten when the client destroys them; there is no delete_id.
	server_kinds: map[u32]Obj_Kind,
}

// SERVER_ID_BASE is where the server's half of the object id space starts.
SERVER_ID_BASE :: u32(0xff00_0000)

// server_id records an object the server just created.
server_id :: proc(c: ^Conn, id: u32, kind: Obj_Kind) {
	if id >= SERVER_ID_BASE {
		c.server_kinds[id] = kind
	}
}

// forget_server_id drops a server-created object the client has destroyed.
forget_server_id :: proc(c: ^Conn, id: u32) {
	delete_key(&c.server_kinds, id)
}

@(private)
SOL_SOCKET :: 1
@(private)
SCM_RIGHTS :: 1

@(private)
Cmsg_Hdr :: struct {
	len:   uint,
	level: i32,
	type:  i32,
}

// display_path resolves the socket to connect to the same way libwayland does.
@(private)
display_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	name := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	if name == "" {
		name = "wayland-0"
	}
	if strings.has_prefix(name, "/") {
		return strings.clone(name, allocator), true
	}
	runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime_dir == "" {
		return "", false
	}
	return fmt.aprintf("%s/%s", runtime_dir, name, allocator = allocator), true
}

// conn_open_unix connects a non-blocking SOCK_STREAM to a unix socket path.
// Both backends reach their server this way: Wayland's compositor socket under
// XDG_RUNTIME_DIR and X11's /tmp/.X11-unix/X<n> are the same kind of thing.
conn_open_unix :: proc(c: ^Conn, path: string, who: string) -> (err: string) {
	sock, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, linux.Protocol(0))
	if serr != .NONE {
		return fmt.tprintf("socket() failed: %v", serr)
	}

	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		linux.close(sock)
		return fmt.tprintf("the %s socket path is too long", who)
	}
	copy(addr.sun_path[:], path)

	if cerr := linux.connect(sock, &addr); cerr != .NONE {
		linux.close(sock)
		return fmt.tprintf("cannot connect to the %s at %s: %v", who, path, cerr)
	}

	c.fd = sock
	c.out = make([dynamic]u8, 0, 4096)
	c.rx = make([dynamic]u8, 0, 8192)
	return ""
}

conn_open :: proc(c: ^Conn) -> (err: string) {
	path, ok := display_path(context.temp_allocator)
	if !ok {
		return "XDG_RUNTIME_DIR is not set, so the Wayland socket cannot be located"
	}
	if e := conn_open_unix(c, path, "Wayland compositor"); e != "" {
		return e
	}
	c.kinds = make([dynamic]Obj_Kind, 2)
	c.kinds[DISPLAY_ID] = .Display
	return ""
}

conn_close :: proc(c: ^Conn) {
	if c.fd != 0 {
		linux.close(c.fd)
		c.fd = 0
	}
	delete(c.out)
	delete(c.out_fds)
	delete(c.rx)
	delete(c.rx_fds)
	delete(c.kinds)
	delete(c.free_ids)
	delete(c.server_kinds)
}

// new_id reserves a client-side object id and records its interface.
new_id :: proc(c: ^Conn, kind: Obj_Kind) -> u32 {
	if n := len(c.free_ids); n > 0 {
		id := c.free_ids[n - 1]
		pop(&c.free_ids)
		c.kinds[id] = kind
		return id
	}
	id := u32(len(c.kinds))
	append(&c.kinds, kind)
	return id
}

// retire_id marks an object as destroyed so that any events still in flight
// for it are ignored. The id itself stays reserved: the protocol only allows it
// to be reused once the server has acknowledged the destruction with
// wl_display.delete_id, and reusing it earlier corrupts the id space.
retire_id :: proc(c: ^Conn, id: u32) {
	if int(id) < len(c.kinds) && c.kinds[id] != .None {
		c.kinds[id] = .Dead
	}
}

// free_id returns an id to the pool. Only wl_display.delete_id may call it.
free_id :: proc(c: ^Conn, id: u32) {
	if int(id) >= len(c.kinds) || c.kinds[id] == .None {
		return
	}
	c.kinds[id] = .None
	append(&c.free_ids, id)
}

kind_of :: proc(c: ^Conn, id: u32) -> Obj_Kind {
	if id >= SERVER_ID_BASE {
		return c.server_kinds[id] or_else .None
	}
	if int(id) < len(c.kinds) {
		return c.kinds[id]
	}
	return .None
}

@(private)
put_u32 :: proc(c: ^Conn, v: u32) {
	b := transmute([4]u8)v
	append(&c.out, ..b[:])
}

// request encodes and queues one request. Arguments are encoded in order:
// integers and object ids as one word, strings and arrays with a length prefix
// and 32-bit padding, and file descriptors into the pending control message.
request :: proc(c: ^Conn, id: u32, opcode: u16, args: ..Arg) {
	if c.fatal != "" {
		return
	}
	start := len(c.out)
	put_u32(c, id)
	put_u32(c, 0) // opcode and size, patched below

	for arg in args {
		switch v in arg {
		case u32:
			put_u32(c, v)
		case i32:
			put_u32(c, u32(v))
		case Obj:
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

	// Descriptors must accompany the message that carries them.
	if len(c.out_fds) > 0 {
		conn_flush(c)
	}
}

conn_flush :: proc(c: ^Conn) {
	if c.fatal != "" || len(c.out) == 0 {
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
			// Wait for room in the socket buffer rather than spinning.
			pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
			linux.poll(pfd[:], 100)
			continue
		}
		if err != .NONE || n <= 0 {
			c.fatal = fmt.tprintf("lost the connection to the display server while writing: %v", err)
			return
		}
		sent += n
	}

	for fd in c.out_fds {
		linux.close(fd)
	}
	clear(&c.out_fds)
	clear(&c.out)
}

// conn_read pulls whatever is available into the receive buffer. It returns
// false if the compositor hung up.
conn_read :: proc(c: ^Conn) -> bool {
	staging: [8192]u8
	ctrl: [512]u8

	for {
		iov := [1]linux.IO_Vec{{base = &staging[0], len = len(staging)}}
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = ctrl[:],
		}

		n, err := linux.recvmsg(c.fd, &hdr, {})
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			return true
		}
		if err != .NONE {
			c.fatal = fmt.tprintf("lost the connection to the display server while reading: %v", err)
			return false
		}
		if n == 0 {
			c.fatal = "the display server closed the connection"
			return false
		}

		append(&c.rx, ..staging[:n])

		// Harvest any descriptors that rode along with these bytes.
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

// Reader decodes the argument list of a received event.
Reader :: struct {
	b: []u8,
	p: int,
}

r_u32 :: proc(r: ^Reader) -> u32 {
	if r.p + 4 > len(r.b) {
		r.p = len(r.b) + 4
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
	return fixed_to_f32(Fixed(r_i32(r)))
}

// r_string returns a view into the receive buffer, valid until the next read.
r_string :: proc(r: ^Reader) -> string {
	n := int(r_u32(r))
	if n == 0 || r.p + n > len(r.b) {
		return ""
	}
	s := string(r.b[r.p:r.p + n - 1]) // drop the trailing NUL
	r.p += (n + 3) & ~int(3)
	return s
}

r_array :: proc(r: ^Reader) -> []u8 {
	n := int(r_u32(r))
	if r.p + n > len(r.b) {
		return nil
	}
	s := r.b[r.p:r.p + n]
	r.p += (n + 3) & ~int(3)
	return s
}

// take_fd pops the next descriptor received out of band.
take_fd :: proc(c: ^Conn) -> (linux.Fd, bool) {
	if len(c.rx_fds) == 0 {
		return 0, false
	}
	fd := c.rx_fds[0]
	ordered_remove(&c.rx_fds, 0)
	return fd, true
}

// wl_dispatch_pending decodes every complete message in the receive buffer
// and hands each one to `on_event`.
wl_dispatch_pending :: proc(c: ^Conn, w: ^Window) {
	consumed := 0
	for {
		avail := len(c.rx) - consumed
		if avail < 8 {
			break
		}
		id := (^u32)(raw_data(c.rx[consumed:]))^
		header := (^u32)(raw_data(c.rx[consumed + 4:]))^
		opcode := u16(header & 0xffff)
		size := int(header >> 16)
		if size < 8 || size > avail {
			break
		}

		body := c.rx[consumed + 8:consumed + size]
		r := Reader{b = body}
		wl_on_event(w, id, opcode, &r)
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
