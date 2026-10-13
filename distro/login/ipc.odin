package login

// The greetd IPC protocol, server side.
//
// apps/greeter/ipc.odin is the client half and the reference: it was written
// against greetd-ipc(7) from greetd 0.10.3, and palm-login answers exactly
// what that client expects, so the greeter runs against either daemon
// unchanged.
//
//	<payload-length> <payload>
//	  payload-length: u32, native byte order
//	  payload:        a UTF-8 JSON object
//
// Requests:  create_session{username}, post_auth_message_response{response?},
//            start_session{cmd[], env[]}, cancel_session
// Responses: success, error{error_type, description},
//            auth_message{auth_message_type, auth_message}
//
// plus one request greetd does not have, power{action: "poweroff"|"reboot"},
// which the greeter sends only when it knows it is talking to palm-login.
//
// Each connection carries at most one session under configuration. The state
// machine is greetd's: create_session asks for a secret, the answer either
// authenticates the session or ends it with an auth_error, and only an
// authenticated session can be started. Anything out of order is a plain
// "error", which the greeter treats as fatal for that attempt.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

// A password is short; a start_session is a command line and an environment.
// Anything bigger than this is not a greeter talking.
MAX_FRAME :: 64 * 1024

Stage :: enum u8 {
	None, // no session under configuration
	Asked, // the password question is on the wire
	Authenticated, // the password was right; start_session may follow
}

Conn :: struct {
	fd:       linux.Fd,
	inbuf:    [dynamic]u8,
	stage:    Stage,
	user:     string,
	closing:  bool,

	// A failed attempt is answered late, so a guesser gets one try per
	// delay rather than one per round trip. While a reply is held back the
	// connection's further requests wait in `inbuf`.
	held:     string,
	held_at:  time.Tick,
}

// Start_Request is what a successful start_session hands the daemon: who to
// start, and with what.
Start_Request :: struct {
	user: string,
	cmd:  []string,
	env:  []string,
}

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

// json_quote writes a JSON string literal. Descriptions can carry a user name
// or a path, so they are escaped like anything else.
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
		case:
			if ch < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", int(ch))
			} else {
				strings.write_byte(sb, ch)
			}
		}
	}
	strings.write_byte(sb, '"')
}

reply_success :: proc(allocator := context.temp_allocator) -> string {
	return strings.clone(`{"type":"success"}`, allocator)
}

// reply_error: error_type is "auth_error" for wrong credentials (the greeter
// may simply try again) or "error" for everything else.
reply_error :: proc(error_type, description: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"error","error_type":`)
	json_quote(&sb, error_type)
	strings.write_string(&sb, `,"description":`)
	json_quote(&sb, description)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

reply_auth_message :: proc(kind, message: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"auth_message","auth_message_type":`)
	json_quote(&sb, kind)
	strings.write_string(&sb, `,"auth_message":`)
	json_quote(&sb, message)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

write_all :: proc(fd: linux.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		// MSG_NOSIGNAL: a greeter that hangs up mid-reply must not take the
		// daemon down with SIGPIPE.
		n, e := linux.send(fd, buf[off:], {.NOSIGNAL})
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

// send_frame writes one length-prefixed payload.
send_frame :: proc(fd: linux.Fd, payload: string) -> bool {
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	return write_all(fd, hdr[:]) && write_all(fd, transmute([]u8)payload)
}

// next_frame takes one complete payload off the front of `buf`, if one has
// arrived. `bad` reports a length no greeter would send.
next_frame :: proc(buf: ^[dynamic]u8, allocator := context.temp_allocator) -> (payload: string, ok: bool, bad: bool) {
	if len(buf) < 4 {
		return "", false, false
	}
	hdr: [4]u8
	copy(hdr[:], buf[:4])
	n := int(transmute(u32)hdr)
	if n <= 0 || n > MAX_FRAME {
		return "", false, true
	}
	if len(buf) < 4 + n {
		return "", false, false
	}
	payload = strings.clone(string(buf[4:4 + n]), allocator)
	remove_range(buf, 0, 4 + n)
	return payload, true, false
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

@(private = "file")
jstr :: proc(obj: json.Object, key: string) -> (string, bool) {
	if v, ok := obj[key]; ok {
		if s, is := v.(json.String); is {
			return string(s), true
		}
	}
	return "", false
}

@(private = "file")
jstrings :: proc(obj: json.Object, key: string, allocator := context.allocator) -> (out: []string, ok: bool) {
	v, has := obj[key]
	if !has {
		return nil, true // absent is an empty list
	}
	if _, is_null := v.(json.Null); is_null {
		return nil, true
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return nil, false
	}
	list := make([dynamic]string, allocator)
	for e in arr {
		s, is := e.(json.String)
		if !is {
			return nil, false
		}
		append(&list, strings.clone(string(s), allocator))
	}
	return list[:], true
}

// Handler is what the daemon supplies: how to check a password, and what to
// do with a session that is ready to start. Splitting them out is what lets
// --test mode and the real daemon share every line of the protocol.
Handler :: struct {
	authenticate: proc(h: ^Handler, user, password: string) -> bool,
	// start returns "" when the session was accepted, or why not.
	start:        proc(h: ^Handler, req: Start_Request) -> string,
	// power runs /sbin/poweroff or /sbin/reboot; "" or why not.
	power:        proc(h: ^Handler, action: string) -> string,
	fail_delay:   time.Duration,
	data:         rawptr,
}

// handle_request answers one payload. The reply is returned rather than sent
// so a failed attempt can be held back; `hold` says so.
handle_request :: proc(h: ^Handler, c: ^Conn, payload: string) -> (reply: string, hold: bool, fatal: bool) {
	v, err := json.parse(transmute([]u8)payload, .JSON, true, context.temp_allocator)
	if err != nil {
		return reply_error("error", "the request is not valid JSON"), false, true
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return reply_error("error", "the request is not a JSON object"), false, true
	}

	kind, _ := jstr(obj, "type")
	switch kind {
	case "create_session":
		if c.stage != .None {
			return reply_error("error", "a session is already being configured"), false, false
		}
		user, has := jstr(obj, "username")
		if !has || user == "" || len(user) > 256 {
			return reply_error("error", "create_session needs a username"), false, false
		}
		delete(c.user)
		c.user = strings.clone(user)
		c.stage = .Asked
		// The same question whether or not the account exists: whether a name
		// is real is not something to tell a stranger at the login screen.
		return reply_auth_message("secret", "Password:"), false, false

	case "post_auth_message_response":
		if c.stage != .Asked {
			return reply_error("error", "no question is waiting for an answer"), false, false
		}
		response, _ := jstr(obj, "response")
		ok := h.authenticate(h, c.user, response)
		if !ok {
			c.stage = .None
			fmt.eprintfln("palm-login: authentication failed for %q", c.user)
			return reply_error("auth_error", "The password was not accepted."), true, false
		}
		c.stage = .Authenticated
		fmt.eprintfln("palm-login: %q authenticated", c.user)
		return reply_success(), false, false

	case "start_session":
		if c.stage != .Authenticated {
			return reply_error("error", "no authenticated session to start"), false, false
		}
		cmd, cok := jstrings(obj, "cmd", context.temp_allocator)
		env, eok := jstrings(obj, "env", context.temp_allocator)
		if !cok || len(cmd) == 0 || cmd[0] == "" {
			return reply_error("error", "start_session needs a non-empty cmd"), false, false
		}
		if !eok {
			return reply_error("error", "start_session env must be a list of strings"), false, false
		}
		for e in env {
			if strings.index_byte(e, '=') <= 0 {
				return reply_error("error", fmt.tprintf("env entry %q is not KEY=value", e)), false, false
			}
		}
		if why := h.start(h, {user = c.user, cmd = cmd, env = env}); why != "" {
			return reply_error("error", why), false, false
		}
		c.stage = .None
		return reply_success(), false, false

	case "cancel_session":
		c.stage = .None
		return reply_success(), false, false

	case "power":
		// Not greetd: palm-login's one extension. busybox's poweroff and
		// reboot signal PID 1, which only root may do, so the unprivileged
		// greeter asks the daemon to run them. Only the greeter group can
		// reach this socket at all.
		action, _ := jstr(obj, "action")
		if action != "poweroff" && action != "reboot" {
			return reply_error("error", "power action must be \"poweroff\" or \"reboot\""), false, false
		}
		if why := h.power(h, action); why != "" {
			return reply_error("error", why), false, false
		}
		return reply_success(), false, false

	case "":
		return reply_error("error", "the request has no type"), false, true
	}
	return reply_error("error", fmt.tprintf("unknown request %q", kind)), false, false
}

// conn_service reads what is available on a connection and answers every
// complete request in it. It returns false when the connection should close.
conn_service :: proc(h: ^Handler, c: ^Conn, readable: bool) -> bool {
	if readable {
		chunk: [4096]u8
		n, e := linux.read(c.fd, chunk[:])
		if e == .EINTR || e == .EAGAIN {
			// nothing this time
		} else if e != .NONE || n <= 0 {
			return false
		} else {
			append(&c.inbuf, ..chunk[:n])
		}
	}

	for {
		if c.held != "" {
			if time.tick_since(c.held_at) < h.fail_delay {
				return true // the held reply goes first; the rest waits
			}
			ok := send_frame(c.fd, c.held)
			delete(c.held)
			c.held = ""
			if !ok {
				return false
			}
		}
		payload, got, bad := next_frame(&c.inbuf)
		if bad {
			send_frame(c.fd, reply_error("error", "frame length out of range"))
			return false
		}
		if !got {
			return true
		}
		reply, hold, fatal := handle_request(h, c, payload)
		// The password went through this buffer; do not leave it lying in
		// the temp arena longer than the request.
		zero_string(payload)
		if hold && h.fail_delay > 0 {
			c.held = strings.clone(reply)
			c.held_at = time.tick_now()
			continue
		}
		if !send_frame(c.fd, reply) || fatal {
			return false
		}
	}
}

zero_string :: proc(s: string) {
	if len(s) > 0 {
		b := transmute([]u8)s
		for i in 0 ..< len(b) {
			(^u8)(&b[i])^ = 0
		}
	}
}

conn_close :: proc(c: ^Conn) {
	linux.close(c.fd)
	if len(c.inbuf) > 0 {
		zero_string(string(c.inbuf[:]))
	}
	delete(c.inbuf)
	delete(c.user)
	delete(c.held)
	free(c)
}

// listen_unix creates the listening socket, replacing a stale one.
listen_unix :: proc(path: string) -> (fd: linux.Fd, err: string) {
	if len(path) >= 108 {
		return -1, fmt.aprintf("socket path %q is too long", path)
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)

	s, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if e != .NONE {
		return -1, fmt.aprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if be := linux.bind(s, &addr); be != .NONE {
		linux.close(s)
		return -1, fmt.aprintf("bind(%s): %v", path, be)
	}
	if le := linux.listen(s, 8); le != .NONE {
		linux.close(s)
		return -1, fmt.aprintf("listen(%s): %v", path, le)
	}
	return s, ""
}
