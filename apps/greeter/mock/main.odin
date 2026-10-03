package main

// A mock greetd, for testing the greeter's protocol implementation without
// going anywhere near the machine's real login.
//
// It speaks exactly what greetd-ipc(7) specifies: a native-endian u32 length
// prefix followed by a JSON payload, in both directions. It scripts a
// realistic PAM-shaped conversation:
//
//	create_session{username}            -> auth_message{info,   "..."}     (unless --no-info)
//	post_auth_message_response{}        -> auth_message{secret, "Password: "}
//	post_auth_message_response{"wrong"} -> error{auth_error, "Authentication failure"}
//	                                       ...and the session is dropped, as greetd does
//	post_auth_message_response{"right"} -> success
//	start_session{cmd,env}              -> success  (the argv is printed, never run)
//	cancel_session                      -> success
//
//	create_session{"<denied>"}          -> error{error, "..."}   with --deny-user
//
// Usage:
//	mock.bin [--sock PATH] [--password PW] [--deny-user NAME] [--no-info]
//	         [--visible-prompt] [--once]
//
// Nothing is executed and no credential is checked against the system: the
// password comparison is a string compare against --password.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

MAX_PAYLOAD :: 1 << 20

Cfg :: struct {
	sock:           string,
	password:       string,
	deny:           string,
	info:           bool,
	visible_prompt: bool,
	once:           bool,
}

Phase :: enum {
	Idle, // no session under configuration
	Info_Sent, // waiting for the ack of the info message
	Awaiting_Name, // --visible-prompt: waiting for the username answer
	Awaiting_Password,
	Authenticated,
}

main :: proc() {
	cfg := Cfg {
		sock     = "/tmp/greetd-mock.sock",
		password = "palmy",
		info     = true,
	}

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--sock":
			i += 1;if i < len(args) {cfg.sock = args[i]}
		case "--password":
			i += 1;if i < len(args) {cfg.password = args[i]}
		case "--deny-user":
			i += 1;if i < len(args) {cfg.deny = args[i]}
		case "--no-info":
			cfg.info = false
		case "--visible-prompt":
			cfg.visible_prompt = true
		case "--once":
			cfg.once = true
		case "-h", "--help":
			fmt.println(
				"mock greetd: --sock PATH --password PW --deny-user NAME --no-info --visible-prompt --once",
			)
			return
		case:
			fmt.eprintfln("mock: unknown argument %q", args[i])
			os.exit(2)
		}
	}

	if len(cfg.sock) >= 108 {
		fmt.eprintln("mock: socket path too long")
		os.exit(1)
	}

	// A stale socket from a previous run would make bind fail.
	cpath := strings.clone_to_cstring(cfg.sock)
	linux.unlink(cpath)

	fd, se := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if se != .NONE {
		fmt.eprintfln("mock: socket: %v", se)
		os.exit(1)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)cfg.sock)

	if be := linux.bind(fd, &addr); be != .NONE {
		fmt.eprintfln("mock: bind(%s): %v", cfg.sock, be)
		os.exit(1)
	}
	if le := linux.listen(fd, 8); le != .NONE {
		fmt.eprintfln("mock: listen: %v", le)
		os.exit(1)
	}

	fmt.printfln("mock greetd listening on %s (password %q)", cfg.sock, cfg.password)
	if cfg.deny != "" {
		fmt.printfln("mock greetd will reject create_session for %q with a fatal error", cfg.deny)
	}

	for {
		peer: linux.Sock_Addr_Un
		cfd, ae := linux.accept(fd, &peer)
		if ae != .NONE {
			if ae == .EINTR {
				continue
			}
			fmt.eprintfln("mock: accept: %v", ae)
			break
		}
		fmt.println("mock: greeter connected")
		serve(cfd, &cfg)
		linux.close(cfd)
		fmt.println("mock: greeter disconnected")
		if cfg.once {
			break
		}
	}

	linux.close(fd)
	linux.unlink(cpath)
}

// ---------------------------------------------------------------------------
// One connection
// ---------------------------------------------------------------------------

serve :: proc(fd: linux.Fd, cfg: ^Cfg) {
	phase := Phase.Idle
	username := ""

	for {
		payload, ok := read_msg(fd)
		if !ok {
			return
		}
		defer delete(payload)
		fmt.printfln("mock <- %s", payload)

		v, perr := json.parse(transmute([]u8)payload, .JSON, true)
		if perr != nil {
			send_msg(fd, `{"type":"error","error_type":"error","description":"malformed JSON"}`)
			continue
		}
		defer json.destroy_value(v)
		obj, is_obj := v.(json.Object)
		if !is_obj {
			send_msg(fd, `{"type":"error","error_type":"error","description":"not an object"}`)
			continue
		}

		switch jstr(obj, "type") {
		case "create_session":
			if phase != .Idle {
				send_msg(
					fd,
					`{"type":"error","error_type":"error","description":"a session is already under configuration"}`,
				)
				continue
			}
			username = strings.clone(jstr(obj, "username"))
			if cfg.deny != "" && username == cfg.deny {
				send_msg(fd, join3(`{"type":"error","error_type":"error","description":"no such user: `, username, `"}`))
				continue
			}
			if cfg.visible_prompt {
				phase = .Awaiting_Name
				send_msg(
					fd,
					`{"type":"auth_message","auth_message_type":"visible","auth_message":"Confirm your login name: "}`,
				)
			} else if cfg.info {
				phase = .Info_Sent
				send_msg(
					fd,
					join3(
						`{"type":"auth_message","auth_message_type":"info","auth_message":"mock greetd: last login was never, `,
						username,
						`"}`,
					),
				)
			} else {
				phase = .Awaiting_Password
				send_msg(
					fd,
					`{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}`,
				)
			}

		case "post_auth_message_response":
			resp, has_resp := jstr_opt(obj, "response")
			switch phase {
			case .Idle, .Authenticated:
				send_msg(
					fd,
					`{"type":"error","error_type":"error","description":"no authentication message to answer"}`,
				)
			case .Info_Sent:
				// An informative message needs no answer; anything is accepted.
				phase = .Awaiting_Password
				send_msg(
					fd,
					`{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}`,
				)
			case .Awaiting_Name:
				if !has_resp || resp == "" {
					send_msg(
						fd,
						`{"type":"error","error_type":"auth_error","description":"no login name given"}`,
					)
					phase = .Idle
					continue
				}
				username = strings.clone(resp)
				phase = .Awaiting_Password
				send_msg(
					fd,
					`{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}`,
				)
			case .Awaiting_Password:
				if has_resp && resp == cfg.password {
					phase = .Authenticated
					fmt.printfln("mock: %q authenticated", username)
					send_msg(fd, `{"type":"success"}`)
				} else {
					// greetd drops the session when PAM fails, so the greeter
					// has to create a new one. The mock does the same.
					phase = .Idle
					fmt.printfln("mock: %q rejected", username)
					send_msg(
						fd,
						`{"type":"error","error_type":"auth_error","description":"Authentication failure"}`,
					)
				}
			}

		case "start_session":
			if phase != .Authenticated {
				send_msg(
					fd,
					`{"type":"error","error_type":"error","description":"session is not ready to be started"}`,
				)
				continue
			}
			fmt.printfln("mock: would start %s as %q (nothing is executed)", jarr(obj, "cmd"), username)
			fmt.printfln("mock: with env %s", jarr(obj, "env"))
			send_msg(fd, `{"type":"success"}`)

		case "cancel_session":
			phase = .Idle
			username = ""
			send_msg(fd, `{"type":"success"}`)

		case:
			send_msg(
				fd,
				join3(
					`{"type":"error","error_type":"error","description":"unknown request type `,
					jstr(obj, "type"),
					`"}`,
				),
			)
		}
	}
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

read_msg :: proc(fd: linux.Fd) -> (payload: []u8, ok: bool) {
	hdr: [4]u8
	if !read_exact(fd, hdr[:]) {
		return nil, false
	}
	n := int(transmute(u32)hdr)
	if n <= 0 || n > MAX_PAYLOAD {
		fmt.eprintfln("mock: implausible length %d", n)
		return nil, false
	}
	buf := make([]u8, n)
	if !read_exact(fd, buf) {
		delete(buf)
		return nil, false
	}
	return buf, true
}

send_msg :: proc(fd: linux.Fd, payload: string) {
	fmt.printfln("mock -> %s", payload)
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	write_all(fd, hdr[:])
	write_all(fd, transmute([]u8)payload)
}

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

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

// join3 concatenates without going through a format string: the JSON payloads
// are full of braces, which Odin's fmt verbs would try to parse.
join3 :: proc(a, b, c: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, a)
	strings.write_string(&sb, b)
	strings.write_string(&sb, c)
	return strings.to_string(sb)
}

jstr :: proc(obj: json.Object, key: string) -> string {
	s, _ := jstr_opt(obj, key)
	return s
}

jstr_opt :: proc(obj: json.Object, key: string) -> (string, bool) {
	if v, ok := obj[key]; ok {
		if s, is := v.(json.String); is {
			return string(s), true
		}
	}
	return "", false
}

jarr :: proc(obj: json.Object, key: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	if v, ok := obj[key]; ok {
		if arr, is := v.(json.Array); is {
			for e, i in arr {
				if i > 0 {
					strings.write_string(&sb, ", ")
				}
				if s, iss := e.(json.String); iss {
					strings.write_quoted_string(&sb, string(s))
				}
			}
		}
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}
