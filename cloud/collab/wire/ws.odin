// WebSocket (RFC 6455), both ends, over core:net — the collaboration
// transport.
//
// Why WebSocket and not the chat server's length-prefixed TCP: a document is
// edited from wherever its owner is, which means through HTTP proxies and TLS
// terminators and, per the README's plan, from the WebAssembly build inside a
// browser, which can open a WebSocket and cannot open a raw socket. The cost
// is small: an HTTP upgrade, then two-to-fourteen bytes of framing per
// message. The protocol on top (protocol.odin) is the same either way.
//
// Only what the protocol needs is implemented: text and binary messages
// (fragmented messages are reassembled), ping/pong, close. No extensions,
// no compression — CRDT updates are already compact varints, and
// permessage-deflate is where WebSocket implementations historically break.
package wire

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

MAX_MESSAGE :: 64 * 1024 * 1024 // a whole snapshot can travel in one message
GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

Conn :: struct {
	sock:    net.TCP_Socket,
	client:  bool, // a client masks what it sends
	buf:     [dynamic]u8, // bytes read but not yet consumed
	send_mu: sync.Mutex, // one frame at a time, from any thread
	closed:  bool,
}

Message :: struct {
	text: bool,
	data: []u8, // owned by the caller
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private)
fill :: proc(c: ^Conn, need: int) -> bool {
	tmp: [16384]u8
	for len(c.buf) < need {
		n, err := net.recv_tcp(c.sock, tmp[:])
		if err != nil || n <= 0 {
			return false
		}
		append(&c.buf, ..tmp[:n])
	}
	return true
}

@(private)
consume :: proc(c: ^Conn, n: int) {
	remove_range(&c.buf, 0, n)
}

// read_message blocks until a whole text or binary message arrives. Pings are
// answered and pongs ignored on the way. ok=false means the peer closed or the
// stream broke.
read_message :: proc(c: ^Conn, allocator := context.allocator) -> (m: Message, ok: bool) {
	acc := make([dynamic]u8, allocator)
	first := Opcode.Binary
	started := false
	for {
		if !fill(c, 2) {
			delete(acc)
			return {}, false
		}
		b0, b1 := c.buf[0], c.buf[1]
		fin := b0 & 0x80 != 0
		op := Opcode(b0 & 0x0f)
		masked := b1 & 0x80 != 0
		ln := u64(b1 & 0x7f)
		hdr := 2
		if ln == 126 {
			if !fill(c, 4) {delete(acc); return {}, false}
			ln = u64(endian.unchecked_get_u16be(c.buf[2:4]))
			hdr = 4
		} else if ln == 127 {
			if !fill(c, 10) {delete(acc); return {}, false}
			ln = endian.unchecked_get_u64be(c.buf[2:10])
			hdr = 10
		}
		if ln > MAX_MESSAGE || u64(len(acc)) + ln > MAX_MESSAGE {
			delete(acc)
			return {}, false
		}
		mask: [4]u8
		if masked {
			if !fill(c, hdr + 4) {delete(acc); return {}, false}
			copy(mask[:], c.buf[hdr:hdr + 4])
			hdr += 4
		}
		if !fill(c, hdr + int(ln)) {
			delete(acc)
			return {}, false
		}
		payload := c.buf[hdr:hdr + int(ln)]
		if masked {
			for i in 0 ..< len(payload) {
				payload[i] ~= mask[i & 3]
			}
		}
		switch op {
		case .Ping:
			pong := make([]u8, len(payload), context.temp_allocator)
			copy(pong, payload)
			consume(c, hdr + int(ln))
			write_frame(c, .Pong, pong)
			continue
		case .Pong:
			consume(c, hdr + int(ln))
			continue
		case .Close:
			consume(c, hdr + int(ln))
			write_frame(c, .Close, nil)
			delete(acc)
			return {}, false
		case .Text, .Binary:
			if started {
				delete(acc)
				return {}, false
			}
			first = op
			started = true
			append(&acc, ..payload)
		case .Continuation:
			if !started {
				delete(acc)
				return {}, false
			}
			append(&acc, ..payload)
		case:
			delete(acc)
			return {}, false
		}
		consume(c, hdr + int(ln))
		if fin && started {
			return Message{text = first == .Text, data = acc[:]}, true
		}
	}
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

write_frame :: proc(c: ^Conn, op: Opcode, data: []u8) -> bool {
	sync.lock(&c.send_mu)
	defer sync.unlock(&c.send_mu)
	if c.closed {
		return false
	}
	hdr: [14]u8
	n := 0
	hdr[0] = 0x80 | u8(op)
	mbit: u8 = c.client ? 0x80 : 0
	l := len(data)
	switch {
	case l < 126:
		hdr[1] = mbit | u8(l)
		n = 2
	case l < 65536:
		hdr[1] = mbit | 126
		endian.put_u16(hdr[2:4], .Big, u16(l))
		n = 4
	case:
		hdr[1] = mbit | 127
		endian.put_u64(hdr[2:10], .Big, u64(l))
		n = 10
	}
	frame := make([]u8, n + (c.client ? 4 : 0) + l, context.temp_allocator)
	copy(frame, hdr[:n])
	off := n
	if c.client {
		mask: [4]u8
		v := rand.uint32()
		endian.put_u32(mask[:], .Little, v)
		copy(frame[off:], mask[:])
		off += 4
		for i in 0 ..< l {
			frame[off + i] = data[i] ~ mask[i & 3]
		}
	} else {
		copy(frame[off:], data)
	}
	sent := 0
	for sent < len(frame) {
		k, err := net.send_tcp(c.sock, frame[sent:])
		if err != nil || k <= 0 {
			c.closed = true
			return false
		}
		sent += k
	}
	return true
}

send_text :: proc(c: ^Conn, s: string) -> bool {
	return write_frame(c, .Text, transmute([]u8)s)
}

send_binary :: proc(c: ^Conn, b: []u8) -> bool {
	return write_frame(c, .Binary, b)
}

close :: proc(c: ^Conn) {
	write_frame(c, .Close, nil)
	sync.lock(&c.send_mu)
	c.closed = true
	sync.unlock(&c.send_mu)
	net.shutdown(c.sock, .Both)
	net.close(c.sock)
	delete(c.buf)
}

// ---------------------------------------------------------------------------
// Handshakes
// ---------------------------------------------------------------------------

accept_key :: proc(key: string, allocator := context.temp_allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)string(GUID))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	s, _ := base64.encode(digest[:], allocator = allocator)
	return s
}

Request :: struct {
	path:    string,
	headers: map[string]string, // lower-cased names
}

// read_request reads an HTTP request head (up to the blank line).
read_request :: proc(c: ^Conn, allocator := context.temp_allocator) -> (req: Request, ok: bool) {
	for {
		s := string(c.buf[:])
		if i := strings.index(s, "\r\n\r\n"); i >= 0 {
			head := strings.clone(s[:i], allocator)
			consume(c, i + 4)
			lines := strings.split(head, "\r\n", allocator)
			if len(lines) == 0 {return {}, false}
			parts := strings.split(lines[0], " ", allocator)
			if len(parts) < 3 || parts[0] != "GET" {return {}, false}
			req.path = parts[1]
			req.headers = make(map[string]string, 16, allocator)
			for l in lines[1:] {
				k := strings.index_byte(l, ':')
				if k <= 0 {continue}
				req.headers[strings.to_lower(strings.trim_space(l[:k]), allocator)] = strings.trim_space(l[k + 1:])
			}
			return req, true
		}
		if len(c.buf) > 16384 {
			return {}, false
		}
		if !fill(c, len(c.buf) + 1) {
			return {}, false
		}
	}
}

// server_handshake completes the upgrade, or answers a plain GET to /health.
server_handshake :: proc(c: ^Conn) -> (req: Request, ok: bool) {
	req, ok = read_request(c)
	if !ok {
		return
	}
	if req.path == "/health" {
		body := "ok\n"
		resp := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		net.send_tcp(c.sock, transmute([]u8)resp)
		return req, false
	}
	key := req.headers["sec-websocket-key"]
	if key == "" || !strings.contains(strings.to_lower(req.headers["upgrade"], context.temp_allocator), "websocket") {
		resp := "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(c.sock, transmute([]u8)string(resp))
		return req, false
	}
	resp := fmt.tprintf(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		accept_key(key),
	)
	_, err := net.send_tcp(c.sock, transmute([]u8)resp)
	return req, err == nil
}

// dial connects to ws://host:port/path.
dial :: proc(host: string, port: int, path: string, timeout := 5 * time.Second) -> (c: ^Conn, err: string) {
	ep, ok := net.resolve_ip4(fmt.tprintf("%s:%d", host, port))
	if ok != nil {
		return nil, fmt.tprintf("cannot resolve %s", host)
	}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return nil, fmt.tprintf("cannot connect to %s:%d", host, port)
	}
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	c = new(Conn)
	c.sock = sock
	c.client = true
	raw: [16]u8
	for i in 0 ..< 16 {
		raw[i] = u8(rand.uint32())
	}
	key, _ := base64.encode(raw[:], allocator = context.temp_allocator)
	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path,
		host,
		port,
		key,
	)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		net.close(sock)
		free(c)
		return nil, "cannot send the upgrade"
	}
	for {
		s := string(c.buf[:])
		if i := strings.index(s, "\r\n\r\n"); i >= 0 {
			head := s[:i]
			if !strings.has_prefix(head, "HTTP/1.1 101") ||
			   !strings.contains(head, accept_key(key)) {
				net.close(sock)
				delete(c.buf)
				free(c)
				return nil, "the server refused the upgrade"
			}
			consume(c, i + 4)
			break
		}
		if !fill(c, len(c.buf) + 1) {
			net.close(sock)
			delete(c.buf)
			free(c)
			return nil, "the server closed during the upgrade"
		}
	}
	// After the handshake, reads block until data or the connection drops; the
	// client uses ping for liveness.
	_ = net.set_option(sock, .Receive_Timeout, time.Duration(0))
	return c, ""
}

// close_socket interrupts a blocked reader on another thread; that thread
// then sees the connection end and calls `close`.
close_socket :: proc(c: ^Conn) {
	net.shutdown(c.sock, .Both)
}
