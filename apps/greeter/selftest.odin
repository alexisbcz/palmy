package main

// `greeter --selftest` drives the greetd client in ipc.odin against whatever
// is listening on the socket, with no window and no compositor. Point it at
// the mock in ./mock and it checks the whole conversation: the happy path, a
// rejected password, a cancelled session, and a request made out of order.
//
//	greeter --selftest --sock PATH [--user NAME] [--password PW]
//
// It never talks to the real greetd unless someone points it there, and even
// then it only ever sends create/post/cancel — `start_session` is only sent in
// the success scenario, which requires the password to have been accepted.

import "core:fmt"
import "core:os"
import "core:strings"

Test_Result :: struct {
	name:   string,
	passed: bool,
	detail: string,
}

@(private = "file")
results: [dynamic]Test_Result

@(private = "file")
check :: proc(name: string, ok: bool, detail: string) -> bool {
	append(&results, Test_Result{name = name, passed = ok, detail = detail})
	fmt.printfln("%s  %-46s  %s", ok ? "pass" : "FAIL", name, detail)
	return ok
}

// expect reads one reply and reports it.
@(private = "file")
expect :: proc(c: ^Client) -> (Reply, string) {
	if !readable(c, 3000) {
		return {}, "timed out waiting for a reply"
	}
	return recv(c)
}

@(private = "file")
dial :: proc(sock: string) -> (c: Client, ok: bool) {
	if e := client_connect(&c, sock); e != "" {
		fmt.eprintfln("selftest: %s", e)
		return c, false
	}
	return c, true
}

selftest :: proc(sock, user, password: string) -> int {
	fmt.printfln("selftest against %s as %q", sock, user)
	fmt.println(strings.repeat("-", 72, context.temp_allocator))

	// --- 1. a wrong password is rejected with auth_error --------------------
	{
		c, ok := dial(sock)
		if !ok {
			return 1
		}
		defer client_close(&c)

		send(&c, req_create_session(user, context.temp_allocator))
		r, e := expect(&c)
		if e != "" {
			check("wrong password: create_session", false, e)
			return 1
		}
		// An informative message may come first; acknowledge and read on.
		if r.kind == .Auth_Message && (r.auth_kind == .Info || r.auth_kind == .Error) {
			check("wrong password: info message is acknowledged", true, r.auth_message)
			send(&c, req_post_response("", false, context.temp_allocator))
			r, e = expect(&c)
		}
		check(
			"wrong password: greetd asks for a secret",
			r.kind == .Auth_Message && r.auth_kind == .Secret,
			fmt.tprintf("%v / %v %q", r.kind, r.auth_kind, r.auth_message),
		)

		send(&c, req_post_response("definitely-not-the-password", true, context.temp_allocator))
		r, e = expect(&c)
		check(
			"wrong password: rejected with error_type auth_error",
			r.kind == .Error && r.error_type == "auth_error",
			fmt.tprintf("%v %q %q", r.kind, r.error_type, r.description),
		)
	}

	// --- 2. the right password gets a session started -----------------------
	{
		c, ok := dial(sock)
		if !ok {
			return 1
		}
		defer client_close(&c)

		send(&c, req_create_session(user, context.temp_allocator))
		r, e := expect(&c)
		if r.kind == .Auth_Message && (r.auth_kind == .Info || r.auth_kind == .Error) {
			send(&c, req_post_response("", false, context.temp_allocator))
			r, e = expect(&c)
		}
		if !check(
			"right password: greetd asks for a secret",
			r.kind == .Auth_Message && r.auth_kind == .Secret,
			fmt.tprintf("%v %q", r.kind, r.auth_message),
		) {
			return 1
		}

		send(&c, req_post_response(password, true, context.temp_allocator))
		r, e = expect(&c)
		if !check(
			"right password: accepted with success",
			r.kind == .Success,
			fmt.tprintf("%v %q", r.kind, r.description),
		) {
			return 1
		}

		cmd := []string{"/usr/bin/start-hyprland"}
		env := []string{"XDG_SESSION_TYPE=wayland", "XDG_CURRENT_DESKTOP=Hyprland"}
		send(&c, req_start_session(cmd, env, context.temp_allocator))
		r, e = expect(&c)
		check(
			"right password: start_session succeeds",
			r.kind == .Success,
			fmt.tprintf("%v %q", r.kind, r.description),
		)
		_ = e
	}

	// --- 3. a session under configuration can be cancelled ------------------
	{
		c, ok := dial(sock)
		if !ok {
			return 1
		}
		defer client_close(&c)

		send(&c, req_create_session(user, context.temp_allocator))
		r, e := expect(&c)
		if r.kind == .Auth_Message && (r.auth_kind == .Info || r.auth_kind == .Error) {
			send(&c, req_post_response("", false, context.temp_allocator))
			r, e = expect(&c)
		}
		check(
			"cancel: a question is on the wire",
			r.kind == .Auth_Message,
			fmt.tprintf("%v %q", r.kind, r.auth_message),
		)

		send(&c, req_cancel_session(context.temp_allocator))
		r, e = expect(&c)
		check(
			"cancel: cancel_session succeeds",
			r.kind == .Success,
			fmt.tprintf("%v %q", r.kind, r.description),
		)

		// After a cancel there is nothing to answer, so the next answer is a
		// general error rather than an auth_error.
		send(&c, req_post_response("anything", true, context.temp_allocator))
		r, e = expect(&c)
		check(
			"cancel: answering afterwards is a fatal error, not auth_error",
			r.kind == .Error && r.error_type == "error",
			fmt.tprintf("%v %q %q", r.kind, r.error_type, r.description),
		)
		_ = e
	}

	// --- 4. the decoder handles what it is given ----------------------------
	{
		r, e := decode_reply(`{"type":"auth_message","auth_message_type":"visible","auth_message":"Name: "}`)
		check(
			"decoder: visible auth_message",
			e == "" && r.kind == .Auth_Message && r.auth_kind == .Visible && r.auth_message == "Name: ",
			fmt.tprintf("%v %v %q", r.kind, r.auth_kind, r.auth_message),
		)

		r2, e2 := decode_reply(`{"type":"error","error_type":"auth_error","description":"nope"}`)
		check(
			"decoder: auth_error",
			e2 == "" && r2.kind == .Error && r2.error_type == "auth_error",
			fmt.tprintf("%v %q", r2.kind, r2.error_type),
		)

		_, e3 := decode_reply(`not json at all`)
		check("decoder: malformed JSON is reported", e3 != "", e3)

		sb := strings.builder_make(context.temp_allocator)
		json_quote(&sb, "a\"b\\c\nd")
		check(
			"encoder: strings are escaped",
			strings.to_string(sb) == `"a\"b\\c\nd"`,
			strings.to_string(sb),
		)

		payload := req_start_session(
			[]string{"sh", "-c", "echo \"hi\""},
			[]string{"A=1"},
			context.temp_allocator,
		)
		check(
			"encoder: start_session shape",
			payload == `{"type":"start_session","cmd":["sh","-c","echo \"hi\""],"env":["A=1"]}`,
			payload,
		)

		pw := req_power("poweroff", context.temp_allocator)
		check(
			"encoder: palm-login's power extension",
			pw == `{"type":"power","action":"poweroff"}`,
			pw,
		)

		// The session list picks the palmy window manager when it is offered.
		list := []Session {
			{name = "Hyprland", exec = "start-hyprland", kind = .Wayland},
			PALMFRAME_SESSION,
			{name = "Shell", exec = "bash -l", kind = .Shell},
		}
		check("sessions: Palmframe is the default", default_session(list) == 1, fmt.tprintf("%d", default_session(list)))
		check(
			"sessions: Palmframe starts wm --drm",
			strings.join(session_cmd(PALMFRAME_SESSION, context.temp_allocator), " ", context.temp_allocator) == "wm --drm",
			"",
		)
		check("sessions: no wm, no default", default_session(list[:1]) == -1, "")

		none := req_post_response("", false, context.temp_allocator)
		check(
			"encoder: an informative message is answered with no response field",
			none == `{"type":"post_auth_message_response"}`,
			none,
		)
	}

	fmt.println(strings.repeat("-", 72, context.temp_allocator))
	failed := 0
	for r in results {
		if !r.passed {
			failed += 1
		}
	}
	fmt.printfln("%d checks, %d failed", len(results), failed)
	return failed == 0 ? 0 : 1
}

selftest_main :: proc(sock, user, password: string) {
	code := selftest(sock, user, password)
	os.exit(code)
}
