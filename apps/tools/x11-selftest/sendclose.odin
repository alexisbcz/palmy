// sendclose — ask a window to close the way a window manager does.
//
//   x11-selftest close <window-id>
//
// This exists because nothing installed here sends a real WM_DELETE_WINDOW:
// `xdotool windowclose` calls XDestroyWindow and `xkill` calls XKillClient,
// both of which take the window away rather than asking for it. The protocol's
// polite close is a ClientMessage carrying WM_PROTOCOLS/WM_DELETE_WINDOW, and
// the whole point of palmy advertising that protocol is that a window manager
// then asks instead of killing the process.
//
// It is deliberately NOT built on palmy's X11 backend: the backend is the thing
// under test, so the driver gets an independent sender. That is also why this
// is a blocking, single-shot client with no event loop at all.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

@(private = "file")
Sock :: struct {
	fd:  linux.Fd,
	out: [dynamic]u8,
}

@(private = "file")
w8 :: proc(s: ^Sock, v: u8) {
	append(&s.out, v)
}

@(private = "file")
w16 :: proc(s: ^Sock, v: u16) {
	b := transmute([2]u8)v
	append(&s.out, ..b[:])
}

@(private = "file")
w32 :: proc(s: ^Sock, v: u32) {
	b := transmute([4]u8)v
	append(&s.out, ..b[:])
}

@(private = "file")
pad :: proc(s: ^Sock, n: int) {
	for _ in 0 ..< n {
		append(&s.out, 0)
	}
}

@(private = "file")
flush :: proc(s: ^Sock) -> bool {
	sent := 0
	for sent < len(s.out) {
		n, err := linux.write(s.fd, s.out[sent:])
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		sent += n
	}
	clear(&s.out)
	return true
}

@(private = "file")
read_exactly :: proc(s: ^Sock, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n, err := linux.read(s.fd, buf[got:])
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		got += n
	}
	return true
}

@(private = "file")
r16 :: proc(b: []u8, o: int) -> u16 {
	return u16(b[o]) | u16(b[o + 1]) << 8
}

@(private = "file")
r32 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

// auth_for reads the MIT-MAGIC-COOKIE-1 entry for a display, if there is one.
@(private = "file")
auth_for :: proc(display: string) -> (name: string, data: []u8) {
	path := os.get_env("XAUTHORITY", context.temp_allocator)
	if path == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			return "", nil
		}
		path = strings.concatenate({home, "/.Xauthority"}, context.temp_allocator)
	}
	raw, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", nil
	}
	p := 0
	blob :: proc(b: []u8, p: ^int) -> ([]u8, bool) {
		if p^ + 2 > len(b) {
			return nil, false
		}
		n := int(b[p^]) << 8 | int(b[p^ + 1])
		p^ += 2
		if p^ + n > len(b) {
			return nil, false
		}
		v := b[p^:p^ + n]
		p^ += n
		return v, true
	}
	for p + 2 <= len(raw) {
		p += 2 // family: any family will do for a loopback connection
		if _, ok := blob(raw, &p); !ok {
			break
		}
		num, ok2 := blob(raw, &p)
		if !ok2 {
			break
		}
		nm, ok3 := blob(raw, &p)
		if !ok3 {
			break
		}
		dt, ok4 := blob(raw, &p)
		if !ok4 {
			break
		}
		if string(nm) != "MIT-MAGIC-COOKIE-1" {
			continue
		}
		if len(num) > 0 && string(num) != display {
			continue
		}
		return string(nm), dt
	}
	return "", nil
}

send_close :: proc(window_arg: string) -> int {
	disp := os.get_env("DISPLAY", context.temp_allocator)
	colon := strings.last_index_byte(disp, ':')
	if colon < 0 {
		fmt.eprintln("close: DISPLAY is not set")
		return 1
	}
	num := disp[colon + 1:]
	if dot := strings.index_byte(num, '.'); dot >= 0 {
		num = num[:dot]
	}

	window: u32
	{
		t := window_arg
		base := u32(10)
		if strings.has_prefix(t, "0x") || strings.has_prefix(t, "0X") {
			t = t[2:]
			base = 16
		}
		for ch in t {
			d: u32
			switch {
			case ch >= '0' && ch <= '9':
				d = u32(ch - '0')
			case ch >= 'a' && ch <= 'f':
				d = u32(ch - 'a') + 10
			case ch >= 'A' && ch <= 'F':
				d = u32(ch - 'A') + 10
			case:
				fmt.eprintfln("close: %q is not a window id", window_arg)
				return 1
			}
			window = window * base + d
		}
	}

	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	if serr != .NONE {
		fmt.eprintfln("close: socket: %v", serr)
		return 1
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	path := fmt.tprintf("/tmp/.X11-unix/X%s", num)
	copy(addr.sun_path[:], path)
	if cerr := linux.connect(fd, &addr); cerr != .NONE {
		fmt.eprintfln("close: connect %s: %v", path, cerr)
		return 1
	}
	s := Sock {
		fd = fd,
	}

	aname, adata := auth_for(num)
	append(&s.out, 'l', 0)
	w16(&s, 11)
	w16(&s, 0)
	w16(&s, u16(len(aname)))
	w16(&s, u16(len(adata)))
	w16(&s, 0)
	append(&s.out, aname)
	pad(&s, (-len(aname)) & 3)
	append(&s.out, ..adata)
	pad(&s, (-len(adata)) & 3)
	if !flush(&s) {
		fmt.eprintln("close: could not send the setup request")
		return 1
	}

	head: [8]u8
	if !read_exactly(&s, head[:]) {
		fmt.eprintln("close: no setup reply")
		return 1
	}
	rest := make([]u8, int(r16(head[:], 6)) * 4)
	if len(rest) > 0 && !read_exactly(&s, rest) {
		fmt.eprintln("close: truncated setup reply")
		return 1
	}
	if head[0] != 1 {
		fmt.eprintfln("close: the X server refused the connection (status %d)", head[0])
		return 1
	}
	intern :: proc(s: ^Sock, name: string) -> u32 {
		start := len(s.out)
		w8(s, 16) // InternAtom
		w8(s, 0)
		w16(s, 0)
		w16(s, u16(len(name)))
		w16(s, 0)
		append(&s.out, name)
		for (len(s.out) - start) % 4 != 0 {
			append(&s.out, 0)
		}
		words := u16((len(s.out) - start) / 4)
		b := transmute([2]u8)words
		copy(s.out[start + 2:][:2], b[:])
		if !flush(s) {
			return 0
		}
		rec: [32]u8
		for {
			if !read_exactly(s, rec[:]) {
				return 0
			}
			if rec[0] == 1 {
				return r32(rec[:], 8)
			}
			if rec[0] == 0 {
				return 0
			}
			// An event: ignore it and keep looking for the reply.
		}
	}

	protocols := intern(&s, "WM_PROTOCOLS")
	delete_atom := intern(&s, "WM_DELETE_WINDOW")
	if protocols == 0 || delete_atom == 0 {
		fmt.eprintln("close: could not intern WM_PROTOCOLS/WM_DELETE_WINDOW")
		return 1
	}

	// SendEvent, carrying a 32-byte ClientMessage.
	w8(&s, 25) // SendEvent
	w8(&s, 0) // propagate = false
	w16(&s, 11) // length in words
	w32(&s, window) // destination
	w32(&s, 0) // event mask: delivered to the client that selected nothing
	w8(&s, 33) // ClientMessage
	w8(&s, 32) // format
	w16(&s, 0) // sequence, filled in by the server
	w32(&s, window)
	w32(&s, protocols)
	w32(&s, delete_atom)
	w32(&s, 0) // timestamp
	w32(&s, 0)
	w32(&s, 0)
	w32(&s, 0)
	if !flush(&s) {
		fmt.eprintln("close: could not send the ClientMessage")
		return 1
	}

	// A GetInputFocus roundtrip proves the server processed it before we exit.
	w8(&s, 43)
	w8(&s, 0)
	w16(&s, 1)
	if !flush(&s) {
		return 1
	}
	rec: [32]u8
	for {
		if !read_exactly(&s, rec[:]) {
			break
		}
		if rec[0] == 1 || rec[0] == 0 {
			break
		}
	}
	linux.close(fd)
	return 0
}
