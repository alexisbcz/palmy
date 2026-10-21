package main

// The greetd IPC client.
//
// Verified against greetd-ipc(7) from greetd 0.10.3 on this machine:
//
//	<payload-length> <payload>
//	  payload-length: a 32-bit integer in NATIVE byte order
//	  payload:        a UTF-8 JSON object
//
// Requests:  create_session{username}, post_auth_message_response{response?},
//            start_session{cmd[], env[]}, cancel_session
// Responses: success, error{error_type, description},
//            auth_message{auth_message_type, auth_message}
//
// There is no libgreetd here: the socket is a plain SOCK_STREAM AF_UNIX fd and
// the framing is done by hand, the same way palmy talks to Wayland.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import p "palmy:."

Auth_Kind :: enum u8 {
	Visible,
	Secret,
	Info,
	Error,
}

Reply_Kind :: enum u8 {
	None,
	Success,
	Error,
	Auth_Message,
}

// Reply is one decoded response. Strings are cloned into the client's
// allocator so they outlive the read buffer.
Reply :: struct {
	kind:         Reply_Kind,
	error_type:   string, // "auth_error" (not fatal) or "error"
	description:  string,
	auth_kind:    Auth_Kind,
	auth_message: string,
	raw:          string, // the JSON as it arrived, for the protocol log
}

Client :: struct {
	fd:    linux.Fd,
	open:  bool,
	path:  string,
	// Every frame of the conversation, newest last. The UI shows the tail of
	// this so the protocol is visible rather than merely claimed.
	log:   [dynamic]string,
}

MAX_PAYLOAD :: 1 << 20

client_log :: proc(c: ^Client, format: string, args: ..any) {
	line := fmt.aprintf(format, ..args)
	append(&c.log, line)
	if len(c.log) > 200 {
		delete(c.log[0])
		ordered_remove(&c.log, 0)
	}
	fmt.eprintfln("greeter: %s", line)
}

// client_connect dials the greetd socket named by $GREETD_SOCK.
client_connect :: proc(c: ^Client, path: string) -> (err: string) {
	if path == "" {
		return "GREETD_SOCK is not set"
	}
	if len(path) >= 108 {
		return "GREETD_SOCK path is too long for a unix socket"
	}

	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return fmt.aprintf("socket(AF_UNIX): %v", e)
	}

	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)

	if ce := linux.connect(fd, &addr); ce != .NONE {
		linux.close(fd)
		return fmt.aprintf("connect(%s): %v", path, ce)
	}

	c.fd = fd
	c.open = true
	c.path = strings.clone(path)
	client_log(c, "connected to %s", path)
	return ""
}

client_close :: proc(c: ^Client) {
	if c.open {
		linux.close(c.fd)
		c.open = false
	}
}

@(private = "file")
write_all :: proc(fd: linux.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		n, e := linux.write(fd, buf[off:])
		if e == .EINTR {
			continue
		}
		if e != .NONE || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

@(private = "file")
read_exact :: proc(fd: linux.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		n, e := linux.read(fd, buf[off:])
		if e == .EINTR {
			continue
		}
		if e != .NONE || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

// send transmits one request. `payload` is the JSON body; the length prefix is
// added here in native byte order.
// `display` is what goes in the on-screen protocol log. It exists so a
// password is never written to the log or to stderr: callers pass a redacted
// copy of the payload.
send :: proc(c: ^Client, payload: string, display := "") -> (err: string) {
	if !c.open {
		return "not connected to greetd"
	}
	n := u32(len(payload))
	hdr := transmute([4]u8)n // native endian, as the protocol specifies
	if !write_all(c.fd, hdr[:]) {
		c.open = false
		return "short write sending the length prefix"
	}
	if !write_all(c.fd, transmute([]u8)payload) {
		c.open = false
		return "short write sending the payload"
	}
	client_log(c, "-> %s", display == "" ? payload : display)
	return ""
}

// readable reports whether a reply is already waiting, without blocking.
readable :: proc(c: ^Client, timeout_ms: i32 = 0) -> bool {
	if !c.open {
		return false
	}
	fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
	n, e := p.poll_fds(fds[:], int(timeout_ms)) // -1 must mean forever on arm64 too
	if e != .NONE || n <= 0 {
		return false
	}
	return .IN in fds[0].revents || .HUP in fds[0].revents
}

// recv reads exactly one reply. It blocks, so callers poll with `readable`
// first and keep the UI responsive.
recv :: proc(c: ^Client) -> (r: Reply, err: string) {
	if !c.open {
		return {}, "not connected to greetd"
	}
	hdr: [4]u8
	if !read_exact(c.fd, hdr[:]) {
		c.open = false
		return {}, "greetd closed the connection"
	}
	n := int(transmute(u32)hdr)
	if n <= 0 || n > MAX_PAYLOAD {
		c.open = false
		return {}, fmt.aprintf("implausible payload length %d", n)
	}
	buf := make([]u8, n)
	defer delete(buf)
	if !read_exact(c.fd, buf) {
		c.open = false
		return {}, "greetd closed the connection mid-payload"
	}

	raw := strings.clone(string(buf))
	client_log(c, "<- %s", raw)
	return decode_reply(raw)
}

// decode_reply turns one JSON payload into a Reply. Exposed separately so the
// decoder can be exercised without a socket.
decode_reply :: proc(raw: string) -> (r: Reply, err: string) {
	r.raw = raw

	v, e := json.parse(transmute([]u8)raw, .JSON, true)
	if e != nil {
		return r, fmt.aprintf("malformed JSON from greetd: %v", e)
	}
	defer json.destroy_value(v)

	obj, is_obj := v.(json.Object)
	if !is_obj {
		return r, "greetd sent something that is not a JSON object"
	}

	switch str(obj, "type") {
	case "success":
		r.kind = .Success
	case "error":
		r.kind = .Error
		r.error_type = strings.clone(str(obj, "error_type"))
		r.description = strings.clone(str(obj, "description"))
		if r.error_type == "" {
			r.error_type = "error"
		}
	case "auth_message":
		r.kind = .Auth_Message
		r.auth_message = strings.clone(str(obj, "auth_message"))
		switch str(obj, "auth_message_type") {
		case "visible":
			r.auth_kind = .Visible
		case "secret":
			r.auth_kind = .Secret
		case "info":
			r.auth_kind = .Info
		case "error":
			r.auth_kind = .Error
		case:
			// Unknown message types are treated as visible questions, which is
			// what greetd-ipc(7) asks for: make no assumptions, just ask.
			r.auth_kind = .Visible
		}
	case "":
		return r, "greetd sent a reply with no type"
	case:
		return r, fmt.aprintf("unknown reply type %q", str(obj, "type"))
	}
	return r, ""
}

@(private = "file")
str :: proc(obj: json.Object, key: string) -> string {
	if v, ok := obj[key]; ok {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

// json_quote writes a JSON string literal, escaping what RFC 8259 requires.
// A password can contain anything, so this cannot be skipped.
json_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case '\b':
			strings.write_string(sb, "\\b")
		case '\f':
			strings.write_string(sb, "\\f")
		case:
			if ch < 0x20 {
				strings.write_string(sb, fmt.tprintf("\\u%04x", int(ch)))
			} else {
				strings.write_byte(sb, ch)
			}
		}
	}
	strings.write_byte(sb, '"')
}

req_create_session :: proc(username: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"create_session","username":`)
	json_quote(&sb, username)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// req_post_response answers an auth_message. An informative message (info,
// error) needs no response field at all, which is what `has_response = false`
// produces.
req_post_response :: proc(
	response: string,
	has_response := true,
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"post_auth_message_response"`)
	if has_response {
		strings.write_string(&sb, `,"response":`)
		json_quote(&sb, response)
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

req_start_session :: proc(cmd: []string, env: []string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"start_session","cmd":[`)
	for a, i in cmd {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		json_quote(&sb, a)
	}
	strings.write_string(&sb, `],"env":[`)
	for a, i in env {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		json_quote(&sb, a)
	}
	strings.write_string(&sb, "]}")
	return strings.to_string(sb)
}

req_cancel_session :: proc(allocator := context.allocator) -> string {
	return strings.clone(`{"type":"cancel_session"}`, allocator)
}

// req_power is not greetd: it is palm-login's one extension, a request to run
// /sbin/poweroff or /sbin/reboot as root on the greeter's behalf. `action` is
// "poweroff" or "reboot". Only sent under palm-login; see `power_request`.
req_power :: proc(action: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"power","action":`)
	json_quote(&sb, action)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}
