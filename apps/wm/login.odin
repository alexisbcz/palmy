// login.odin — the wm's half of palm-login's session socket.
//
// Two things the session needs root for, and asks palm-login to do
// (distro/login/session_ipc.odin has the policy):
//
//   unlock{password}                  is this the user's password? The lock
//                                     screen (locker.odin) never reads
//                                     /etc/shadow: the wm runs as the user.
//   power{action, dry_run, password?} end the session, then shut down or
//                                     restart (power.odin).
//
// palm-login says where the socket is in PALM_SESSION_SOCK; with no such
// variable (nested, or a session palm-login did not start) there is nobody
// to ask, so Lock, Restart and Shut down are not offered.
//
// One request at a time, on a connection of its own. A wrong password is
// answered late on purpose (palm-login holds the reply), so the request is
// sent and the answer read without blocking the compositor: the socket is in
// the main loop's poll set and login_pump picks the reply up.
package wm

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

LOGIN_TIMEOUT :: 20.0 // s; palm-login answers in under two even when it holds a reply

Login_Req :: enum u8 {
	None,
	Unlock,
	Power_Check, // a dry run: would palm-login allow it?
	Power,
}

Login_Reply :: struct {
	ok:          bool,
	error_type:  string, // "auth_error", "auth_required", "error", "" when ok
	description: string,
}

Login_Ipc :: struct {
	fd:      linux.Fd,
	req:     Login_Req,
	inbuf:   [dynamic]u8,
	sent_at: f64,
	// Tests: requests are recorded here instead of sent, and answered by
	// login_fake_reply.
	capture: bool,
	sent:    [dynamic]string,
}

login_ipc: Login_Ipc = {
	fd = -1,
}

// login_sock is where palm-login listens for this session, or "".
login_sock :: proc() -> string {
	return os.get_env("PALM_SESSION_SOCK", context.temp_allocator)
}

// login_available: can this session lock itself and power off?
login_available :: proc() -> bool {
	return login_ipc.capture || login_sock() != ""
}

login_busy :: proc() -> bool {
	return login_ipc.req != .None
}

login_poll_fd :: proc() -> linux.Fd {
	return login_ipc.fd
}

// login_send starts a request. False when one is already in flight or the
// socket cannot be reached; the caller says so on screen.
login_send :: proc(req: Login_Req, payload: string) -> (ok: bool, why: string) {
	if login_ipc.req != .None {
		return false, "busy"
	}
	if login_ipc.capture {
		append(&login_ipc.sent, strings.clone(payload))
		login_ipc.req = req
		login_ipc.sent_at = wall_now()
		return true, ""
	}
	path := login_sock()
	if path == "" || len(path) >= 108 {
		return false, "palm-login is not running this session"
	}
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return false, fmt.tprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if ce := linux.connect(fd, &addr); ce != .NONE {
		linux.close(fd)
		return false, fmt.tprintf("cannot reach palm-login (%v)", ce)
	}
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	frame := make([]u8, 4 + len(payload), context.temp_allocator)
	copy(frame, hdr[:])
	copy(frame[4:], transmute([]u8)payload)
	off := 0
	for off < len(frame) {
		w, we := linux.send(fd, frame[off:], {.NOSIGNAL})
		if we == .EINTR {
			continue
		}
		if we != .NONE || w <= 0 {
			break
		}
		off += w
	}
	login_zero(frame) // it may carry a password
	if off < len(frame) {
		linux.close(fd)
		return false, "palm-login closed the connection"
	}
	login_ipc.fd = fd
	login_ipc.req = req
	login_ipc.sent_at = wall_now()
	clear(&login_ipc.inbuf)
	return true, ""
}

login_zero :: proc(b: []u8) {
	for i in 0 ..< len(b) {
		(^u8)(&b[i])^ = 0
	}
}

// login_json_string writes a JSON string literal.
login_json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
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

// login_unlock_payload and login_power_payload build the requests. The
// builder's bytes are zeroed by the caller once sent.
login_unlock_payload :: proc(password: string) -> strings.Builder {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"unlock","password":`)
	login_json_string(&sb, password)
	strings.write_string(&sb, "}")
	return sb
}

login_power_payload :: proc(action: string, dry_run: bool, password: string) -> strings.Builder {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"power","action":`)
	login_json_string(&sb, action)
	fmt.sbprintf(&sb, `,"dry_run":%v`, dry_run)
	if password != "" {
		strings.write_string(&sb, `,"password":`)
		login_json_string(&sb, password)
	}
	strings.write_string(&sb, "}")
	return sb
}

login_close :: proc() {
	if login_ipc.fd >= 0 {
		linux.close(login_ipc.fd)
	}
	login_ipc.fd = -1
	login_ipc.req = .None
	clear(&login_ipc.inbuf)
}

// login_pump reads whatever has arrived and hands a complete reply to the
// part of the wm that asked.
login_pump :: proc(s: ^Server) {
	if login_ipc.req == .None || login_ipc.capture {
		return
	}
	if login_ipc.fd < 0 {
		login_ipc.req = .None
		return
	}
	for {
		buf: [1024]u8
		n, e := linux.recv(login_ipc.fd, buf[:], {.DONTWAIT})
		if e == .EAGAIN || e == .EINTR {
			break
		}
		if e != .NONE || n <= 0 {
			login_finish(s, {error_type = "error", description = "palm-login closed the connection"})
			return
		}
		append(&login_ipc.inbuf, ..buf[:n])
	}
	if len(login_ipc.inbuf) >= 4 {
		hdr: [4]u8
		copy(hdr[:], login_ipc.inbuf[:4])
		n := int(transmute(u32)hdr)
		if n <= 0 || n > 64 * 1024 {
			login_finish(s, {error_type = "error", description = "palm-login sent a bad reply"})
			return
		}
		if len(login_ipc.inbuf) >= 4 + n {
			login_finish(s, login_parse(login_ipc.inbuf[4:4 + n]))
			return
		}
	}
	if wall_now() - login_ipc.sent_at > LOGIN_TIMEOUT {
		login_finish(s, {error_type = "error", description = "palm-login did not answer"})
	}
}

login_parse :: proc(data: []u8) -> Login_Reply {
	v, err := json.parse(data, .JSON, true, context.temp_allocator)
	if err != nil {
		return {error_type = "error", description = "palm-login sent a bad reply"}
	}
	obj, _ := v.(json.Object)
	get :: proc(obj: json.Object, k: string) -> string {
		if s, ok := obj[k].(json.String); ok {
			return string(s)
		}
		return ""
	}
	if get(obj, "type") == "success" {
		return {ok = true}
	}
	r := Login_Reply {
		error_type  = get(obj, "error_type"),
		description = get(obj, "description"),
	}
	if r.error_type == "" {
		r.error_type = "error"
	}
	return r
}

login_finish :: proc(s: ^Server, r: Login_Reply) {
	req := login_ipc.req
	login_close()
	login_dispatch(s, req, r)
}

login_dispatch :: proc(s: ^Server, req: Login_Req, r: Login_Reply) {
	switch req {
	case .Unlock:
		locker_on_reply(s, r)
	case .Power_Check, .Power:
		power_on_reply(s, req, r)
	case .None:
	}
	s.dirty = true
}

// login_fake_reply answers a captured request (tests).
login_fake_reply :: proc(s: ^Server, r: Login_Reply) {
	req := login_ipc.req
	login_ipc.req = .None
	login_dispatch(s, req, r)
}
