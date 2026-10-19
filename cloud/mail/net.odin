package main

// Socket plumbing: buffered line and exact reads over a TCP socket, for the
// SMTP and HTTP servers and for the HTTP client that talks to PostgREST.
//
// Taken from apps/mailcore/testserver/net.odin. Plaintext only: in front of
// this server TLS is a terminating proxy's job (see cloud/docs/mail.md); on
// the dev stack everything is on 127.0.0.1.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sys/linux"

SBUF :: 64 * 1024
SMAX_LINE :: 1 << 20

SConn :: struct {
	sock:  net.TCP_Socket,
	fd:    linux.Fd,
	open:  bool,
	buf:   []u8,
	r, w:  int,
	line:  [dynamic]u8,
	label: string,
	trace: bool,
	peer:  string,
}

sconn_make :: proc(sock: net.TCP_Socket, label: string, trace: bool) -> SConn {
	return SConn {
		sock = sock,
		fd = linux.Fd(i32(sock)),
		open = true,
		buf = make([]u8, SBUF),
		line = make([dynamic]u8, 0, 1024),
		label = label,
		trace = trace,
	}
}

sconn_close :: proc(c: ^SConn) {
	if c.open {
		net.close(c.sock)
		c.open = false
	}
	delete(c.buf)
	delete(c.line)
	c.buf = nil
	c.line = nil
}

slog :: proc(c: ^SConn, format: string, args: ..any) {
	if !c.trace {
		return
	}
	fmt.eprintf("[%s] ", c.label)
	fmt.eprintfln(format, ..args)
}

@(private = "file")
sconn_fill :: proc(c: ^SConn, timeout_ms: i32) -> bool {
	if !c.open {
		return false
	}
	if c.r > 0 {
		copy(c.buf, c.buf[c.r:c.w])
		c.w -= c.r
		c.r = 0
	}
	if c.w == len(c.buf) {
		return false
	}
	if timeout_ms >= 0 {
		fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, e := linux.poll(fds[:], timeout_ms)
		if e != .NONE || n <= 0 {
			return false
		}
	}
	n, e := net.recv_tcp(c.sock, c.buf[c.w:])
	if e != nil || n <= 0 {
		c.open = false
		return false
	}
	c.w += n
	return true
}

sconn_readable :: proc(c: ^SConn, timeout_ms: i32) -> bool {
	if c.r != c.w {
		return true
	}
	if !c.open {
		return false
	}
	fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
	n, e := linux.poll(fds[:], timeout_ms)
	if e != .NONE || n <= 0 {
		return false
	}
	return .IN in fds[0].revents || .HUP in fds[0].revents
}

// sread_line returns one line without its CRLF. The slice is only valid until
// the next read.
sread_line :: proc(c: ^SConn, timeout_ms: i32 = 300_000) -> (line: string, ok: bool) {
	clear(&c.line)
	for {
		for i := c.r; i < c.w; i += 1 {
			if c.buf[i] != '\n' {
				continue
			}
			end := i
			if end > c.r && c.buf[end - 1] == '\r' {
				end -= 1
			}
			append(&c.line, ..c.buf[c.r:end])
			c.r = i + 1
			return string(c.line[:]), true
		}
		append(&c.line, ..c.buf[c.r:c.w])
		c.r = c.w
		if len(c.line) > SMAX_LINE {
			c.open = false
			return "", false
		}
		if !sconn_fill(c, timeout_ms) {
			if len(c.line) > 0 {
				return string(c.line[:]), true
			}
			return "", false
		}
	}
}

sread_exact :: proc(
	c: ^SConn,
	n: int,
	allocator := context.allocator,
	timeout_ms: i32 = 300_000,
) -> (
	data: []u8,
	ok: bool,
) {
	if n < 0 {
		return nil, false
	}
	out := make([]u8, n, allocator)
	off := 0
	for off < n {
		if c.r == c.w {
			if !sconn_fill(c, timeout_ms) {
				delete(out, allocator)
				return nil, false
			}
		}
		take := min(c.w - c.r, n - off)
		copy(out[off:], c.buf[c.r:c.r + take])
		c.r += take
		off += take
	}
	return out, true
}

swrite :: proc(c: ^SConn, data: []u8) -> bool {
	if !c.open || len(data) == 0 {
		return c.open
	}
	off := 0
	for off < len(data) {
		n, e := net.send_tcp(c.sock, data[off:])
		if e != nil || n <= 0 {
			c.open = false
			return false
		}
		off += n
	}
	return true
}

swrite_str :: proc(c: ^SConn, s: string) -> bool {
	return swrite(c, transmute([]u8)s)
}

// sline sends one CRLF-terminated line.
sline :: proc(c: ^SConn, format: string, args: ..any) -> bool {
	s := fmt.tprintf(format, ..args)
	slog(c, "-> %s", s)
	return swrite_str(c, s) && swrite_str(c, "\r\n")
}

// listen_loopback binds 127.0.0.1:port. Port 0 asks the kernel to choose.
listen_loopback :: proc(port: int) -> (sock: net.TCP_Socket, actual: int, err: string) {
	s, le := net.listen_tcp(
		net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port},
		64,
	)
	if le != nil {
		return 0, 0, fmt.aprintf("listen 127.0.0.1:%d: %v", port, le)
	}
	ep, ge := net.bound_endpoint(s)
	if ge != nil {
		return s, port, ""
	}
	return s, ep.port, ""
}

trim_crlf :: proc(s: string) -> string {
	return strings.trim_right(s, "\r\n")
}
