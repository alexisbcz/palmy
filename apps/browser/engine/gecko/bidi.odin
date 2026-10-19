// WebDriver BiDi over a WebSocket: how this host steers Firefox.
//
// Firefox's Remote Agent (--remote-debugging-port) speaks the W3C WebDriver
// BiDi protocol at ws://127.0.0.1:<port>/session. It is the standard,
// supported way to drive Firefox from outside, which is the point: nothing
// here depends on Firefox internals that change between releases.
//
// The WebSocket client is the minimum RFC 6455 needs from a client on the
// loopback interface: the upgrade, masked text frames out, unmasked frames
// in, continuation, ping and close.
package gecko

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

Ws :: struct {
	fd:     linux.Fd,
	rx:     [dynamic]u8,
	frag:   [dynamic]u8,
	open:   bool,
}

tcp_connect :: proc(port: int) -> (fd: linux.Fd, ok: bool) {
	sock, err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if err != .NONE {
		return -1, false
	}
	addr := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = u16be(port),
		sin_addr   = {127, 0, 0, 1},
	}
	if linux.connect(sock, &addr) != .NONE {
		linux.close(sock)
		return -1, false
	}
	return sock, true
}

// free_port asks the kernel for an unused loopback port.
free_port :: proc() -> int {
	sock, err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if err != .NONE {
		return 0
	}
	defer linux.close(sock)
	addr := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_addr   = {127, 0, 0, 1},
	}
	if linux.bind(sock, &addr) != .NONE {
		return 0
	}
	got: linux.Sock_Addr_Any
	if linux.getsockname(sock, &got) != .NONE {
		return 0
	}
	return int(got.ipv4.sin_port)
}

send_all :: proc(fd: linux.Fd, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := linux.send(fd, data[off:], {.NOSIGNAL})
		if err == .EINTR || err == .EAGAIN {
			pfd := [1]linux.Poll_Fd{{fd = fd, events = {.OUT}}}
			linux.poll(pfd[:], 50)
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		off += int(n)
	}
	return true
}

ws_connect :: proc(port: int, path: string) -> (ws: Ws, ok: bool) {
	fd, cok := tcp_connect(port)
	if !cok {
		return {}, false
	}
	key: [16]u8
	crypto.rand_bytes(key[:])
	k64, _ := base64.encode(key[:], allocator = context.temp_allocator)
	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path,
		port,
		k64,
	)
	if !send_all(fd, transmute([]u8)req) {
		linux.close(fd)
		return {}, false
	}
	resp := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	for {
		pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		if n, _ := linux.poll(pfd[:], 5000); n <= 0 {
			linux.close(fd)
			return {}, false
		}
		n, err := linux.recv(fd, buf[:], {})
		if err != .NONE || n <= 0 {
			linux.close(fd)
			return {}, false
		}
		append(&resp, ..buf[:n])
		if i := strings.index(string(resp[:]), "\r\n\r\n"); i >= 0 {
			head := string(resp[:i])
			if !strings.contains(strings.split_lines(head, context.temp_allocator)[0], " 101") {
				logf("websocket upgrade refused: %s", head)
				linux.close(fd)
				return {}, false
			}
			ws.fd = fd
			ws.open = true
			append(&ws.rx, ..resp[i + 4:])
			return ws, true
		}
	}
}

ws_send :: proc(ws: ^Ws, text: string, opcode: u8 = 1) -> bool {
	if !ws.open {
		return false
	}
	frame := make([dynamic]u8, context.temp_allocator)
	append(&frame, 0x80 | opcode)
	n := len(text)
	switch {
	case n < 126:
		append(&frame, 0x80 | u8(n))
	case n < 65536:
		append(&frame, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&frame, 0x80 | 127)
		for i := 7; i >= 0; i -= 1 {
			append(&frame, u8(n >> uint(i * 8)))
		}
	}
	mask: [4]u8
	crypto.rand_bytes(mask[:])
	append(&frame, ..mask[:])
	for i in 0 ..< n {
		append(&frame, text[i] ~ mask[i % 4])
	}
	if !send_all(ws.fd, frame[:]) {
		ws.open = false
		return false
	}
	return true
}

// ws_read pulls what is available and returns every complete text message.
ws_read :: proc(ws: ^Ws, out: ^[dynamic]string) -> bool {
	buf: [65536]u8
	for {
		n, err := linux.recv(ws.fd, buf[:], {.DONTWAIT})
		if err == .EAGAIN {
			break
		}
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			ws.open = false
			return false
		}
		append(&ws.rx, ..buf[:n])
		if n < len(buf) {
			break
		}
	}
	for {
		b := ws.rx[:]
		if len(b) < 2 {
			break
		}
		fin := b[0] & 0x80 != 0
		op := b[0] & 0x0f
		masked := b[1] & 0x80 != 0
		ln := int(b[1] & 0x7f)
		at := 2
		if ln == 126 {
			if len(b) < 4 {break}
			ln = int(b[2]) << 8 | int(b[3])
			at = 4
		} else if ln == 127 {
			if len(b) < 10 {break}
			ln = 0
			for i in 0 ..< 8 {
				ln = ln << 8 | int(b[2 + i])
			}
			at = 10
		}
		mk: [4]u8
		if masked {
			if len(b) < at + 4 {break}
			copy(mk[:], b[at:at + 4])
			at += 4
		}
		if len(b) < at + ln {
			break
		}
		payload := b[at:at + ln]
		if masked {
			for i in 0 ..< ln {
				payload[i] ~= mk[i % 4]
			}
		}
		switch op {
		case 0, 1:
			append(&ws.frag, ..payload)
			if fin {
				append(out, strings.clone(string(ws.frag[:]), context.temp_allocator))
				clear(&ws.frag)
			}
		case 8:
			ws.open = false
		case 9:
			ws_send(ws, string(payload), 10)
		}
		remove_range(&ws.rx, 0, at + ln)
	}
	return ws.open
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

jq :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '"')
	for c in s {
		switch c {
		case '"':
			strings.write_string(&sb, "\\\"")
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
			strings.write_string(&sb, "\\r")
		case '\t':
			strings.write_string(&sb, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(&sb, "\\u%04x", int(c))
			} else {
				strings.write_rune(&sb, c)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

jget :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok {
			return nil
		}
		cur = obj[k] or_else nil
	}
	return cur
}

jstr :: proc(v: json.Value, keys: ..string) -> string {
	if s, ok := jget(v, ..keys).(json.String); ok {
		return string(s)
	}
	return ""
}

jbool :: proc(v: json.Value, keys: ..string) -> bool {
	if b, ok := jget(v, ..keys).(json.Boolean); ok {
		return bool(b)
	}
	return false
}

jnum :: proc(v: json.Value, keys: ..string) -> f64 {
	#partial switch n in jget(v, ..keys) {
	case json.Integer:
		return f64(n)
	case json.Float:
		return f64(n)
	}
	return 0
}

// J formats a JSON template. Odin's fmt reads `{` and `}` as argument
// syntax, so a JSON literal is never a safe format string; this doubles every
// brace first, so only the % verbs are interpreted.
J :: proc(format: string, args: ..any) -> string {
	f, _ := strings.replace_all(format, "{", "{{", context.temp_allocator)
	f, _ = strings.replace_all(f, "}", "}}", context.temp_allocator)
	return fmt.tprintf(f, ..args)
}
