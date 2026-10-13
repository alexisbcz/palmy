package main

// palmy greeter — a greetd greeter.
//
// It opens as a wlr-layer-shell OVERLAY surface with EXCLUSIVE keyboard focus,
// which is what a login screen is: a surface the compositor places over
// everything, and the only thing the keyboard can reach.
//
// The login itself is the greetd IPC conversation in ipc.odin. Everything the
// screen shows about the machine — the accounts, the sessions, the hostname —
// is read off the real system in system.odin. The power buttons are stubs
// except under Palmframe's palm-login, where they really power off and
// reboot; see `power_request`.
//
// Under palm-login the greeter runs inside `wm --drm --kiosk` and covers
// whatever output that gives it: the layer surface asks for 0x0 anchored to
// every edge, and if the compositor has no layer shell at all it falls back
// to an ordinary fullscreen window.
//
//	greeter [--mock] [--sock PATH] [--demo-users] [--log]
//
// --mock points the client at the mock greetd in ./mock and labels the screen
// so there is no doubt about what is being talked to.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

Focus :: enum u8 {
	User,
	Answer,
	Session,
	Suspend,
	Reboot,
	Shutdown,
}

FOCUS_ORDER := [?]Focus{.User, .Answer, .Session, .Suspend, .Reboot, .Shutdown}

// Stage is where the greetd conversation has got to.
Stage :: enum u8 {
	Idle, // no session under configuration
	Busy, // a request is in flight
	Prompting, // an auth_message is waiting for the user
	Started, // start_session succeeded
}

// Await is the request we are waiting on a reply for.
Await :: enum u8 {
	Nothing,
	Create,
	Answer,
	Start,
	Cancel,
}

St :: struct {
	users:         []User,
	sessions:      []Session,
	user_i:        int,
	session_i:     int,
	hostname:      string,
	tz:            time.Duration,

	// The answer field. `secret` decides whether it is masked.
	answer:        [dynamic]u8,
	caret:         int,
	secret:        bool,

	focus:         Focus,
	stage:         Stage,
	await:         Await,
	session_live:  bool,

	prompt:        string, // the auth_message a question asked
	info:          string, // the last info auth_message
	err:           string, // the last error, from greetd or from us
	err_fatal:     bool,
	note:          string, // the power-action stub's line
	queued_secret: string, // typed before greetd asked for it

	client:        Client,
	mock:          bool,
	sock:          string,
	show_log:      bool,
	connected:     bool,

	started_at:    f32,
	busy_since:    f32,
}

main :: proc() {
	st := new(St)

	demo_users := false
	run_selftest := false
	test_user := os.get_env("USER", context.allocator)
	test_password := "palmy"
	st.sock = os.get_env("GREETD_SOCK", context.allocator)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--mock":
			st.mock = true
		case "--sock":
			i += 1
			if i < len(args) {
				st.sock = args[i]
			}
		case "--demo-users":
			demo_users = true
		case "--log":
			st.show_log = true
		case "--selftest":
			run_selftest = true
		case "--shots":
			// Render the login screen offscreen and write PNGs. No surface is
			// opened, no greetd socket is touched, and nothing about this
			// machine is read: see shot.odin.
			i += 1
			os.exit(shots(i < len(args) ? args[i] : "shots"))
		case "--user":
			i += 1
			if i < len(args) {
				test_user = args[i]
			}
		case "--password":
			i += 1
			if i < len(args) {
				test_password = args[i]
			}
		case "-h", "--help":
			fmt.println(
				"greeter [--mock] [--sock PATH] [--demo-users] [--log]\n" +
				"        --shots DIR                                offscreen PNGs, no window\n" +
				"        --selftest [--user NAME] [--password PW]   headless protocol test",
			)
			return
		case:
			fmt.eprintfln("greeter: unknown argument %q", args[i])
			os.exit(2)
		}
	}
	if st.mock {
		if st.sock == "" {
			st.sock = "/tmp/greetd-mock.sock"
		}
		st.show_log = true
	}

	if run_selftest {
		if st.sock == "" {
			st.sock = "/tmp/greetd-mock.sock"
		}
		selftest_main(st.sock, test_user, test_password)
	}

	st.users = read_users()
	if demo_users {
		// Synthetic rows so the selector can be demonstrated on a machine with
		// a single account. They are never offered to a real greetd: see the
		// guard in submit().
		extra := [?]User {
			{name = "rwatson", real = "Rosalind Watson", uid = 1001, shell = "/usr/bin/zsh", synthetic = true},
			{name = "kjarvis", real = "Kofi Jarvis", uid = 1002, shell = "/usr/bin/fish", synthetic = true},
		}
		merged := make([dynamic]User)
		append(&merged, ..st.users)
		for e in extra {
			u := e
			u.initials = initials_of(u.real)
			append(&merged, u)
		}
		st.users = merged[:]
	}
	st.sessions = read_sessions()
	if d := default_session(st.sessions); d >= 0 {
		st.session_i = d
	}
	st.hostname = read_hostname()
	st.tz = local_utc_offset()

	// Prefer the account the greeter is running as, if it is in the list.
	if me := os.get_env("USER", context.allocator); me != "" {
		for u, i in st.users {
			if u.name == me {
				st.user_i = i
				break
			}
		}
	}
	st.focus = .Answer
	st.secret = true // a login screen starts by asking for a password

	ow, oh := detect_output_size()
	cfg := p.Config {
		title = "greeter",
		app_id = "palmy-greeter",
		// A layer surface anchored to all four edges fills the output when
		// it asks for 0x0. On a host compositor the output is measured and
		// requested exactly (see detect_output_size); under palm-login the
		// size is 0x0 and the window manager fills it in.
		width = ow,
		height = oh,
		root_class = "w-full h-full bg-background text-foreground",
		always = true, // the clock ticks and the spinner spins
		layer = true,
		layer_level = .Overlay,
		layer_keyboard = .Exclusive,
		layer_anchor = {.Top, .Bottom, .Left, .Right},
		exclusive_zone = -1, // sit over panels rather than beside them
	}
	app, err := kit.start(cfg)
	if err != "" && under_palm_login() {
		// A login screen that cannot open is a machine nobody can log in to,
		// so a compositor without wlr-layer-shell still gets one: an ordinary
		// toplevel, asked to go fullscreen. wm --kiosk fullscreens its first
		// client regardless.
		fmt.eprintfln("greeter: %s; falling back to a fullscreen window", err)
		cfg.layer = false
		cfg.width, cfg.height = 1280, 800
		app, err = kit.start(cfg)
		if err == "" {
			p.set_fullscreen(app, true)
		}
	}
	if err != "" {
		fmt.eprintfln("greeter: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	register_dark_theme()

	if e := client_connect(&st.client, st.sock); e != "" {
		st.err = e
		st.err_fatal = true
	} else {
		st.connected = true
	}
	defer client_close(&st.client)

	for ui in p.frames(app) {
		pump(st, ui)
		handle_keys(st, ui)
		draw(st, ui)

		if st.stage == .Started && !st.mock && p.elapsed(ui) - st.started_at > 2.5 {
			// A real greeter exits so greetd can start the session in its
			// place. In --mock mode the success state stays on screen.
			p.quit_app(app)
		}
	}
}

// register_dark_theme re-registers the shadcn tokens with the dark palette.
// shadcn's theme in this repo is the light one; a login screen is dark, so the
// tokens are overridden here rather than in the toolkit.
register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x18181b))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x262626))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xe5e5e5))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x262626))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x3f3f46))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0x450a0a))
	p.register_color("border", c(0x2e2e32))
	p.register_color("input", c(0x3a3a3f))
	p.register_color("ring", c(0x8e8e93))
}

// ---------------------------------------------------------------------------
// The greetd conversation
// ---------------------------------------------------------------------------

cur_user :: proc(st: ^St) -> User {
	if len(st.users) == 0 {
		return {name = "", real = "no local accounts"}
	}
	return st.users[clamp(st.user_i, 0, len(st.users) - 1)]
}

cur_session :: proc(st: ^St) -> Session {
	if len(st.sessions) == 0 {
		return {name = "no sessions found"}
	}
	return st.sessions[clamp(st.session_i, 0, len(st.sessions) - 1)]
}

request :: proc(st: ^St, payload: string, display: string, what: Await, ui: ^p.Ctx) {
	if e := send(&st.client, payload, display); e != "" {
		st.err = e
		st.err_fatal = true
		st.stage = .Idle
		st.session_live = false
		st.await = .Nothing
		return
	}
	st.await = what
	st.stage = .Busy
	st.busy_since = p.elapsed(ui)
}

// submit is Enter on the answer field: either open a session or answer the
// question that is on screen.
submit :: proc(st: ^St, ui: ^p.Ctx) {
	if st.stage == .Busy || st.stage == .Started {
		return
	}
	if !st.connected {
		st.err = fmt.aprintf("not connected to greetd at %s", st.sock)
		st.err_fatal = true
		return
	}
	u := cur_user(st)
	if u.name == "" {
		st.err = "there is no account to log in to"
		return
	}

	st.err = ""
	st.err_fatal = false
	st.note = ""

	if st.session_live && st.stage == .Prompting {
		// Answer the question greetd asked.
		answer := string(st.answer[:])
		// The log line is built by the same encoder, with the secret replaced:
		// a password must never reach the on-screen log or stderr.
		request(
			st,
			req_post_response(answer, true, context.temp_allocator),
			req_post_response(
				st.secret ? "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022" : answer,
				true,
				context.temp_allocator,
			),
			.Answer,
			ui,
		)
		if st.secret {
			clear(&st.answer)
			st.caret = 0
		}
		return
	}

	// Open a session. Whatever has been typed is held back and used for the
	// first secret question, so one Enter is enough for the common case.
	if u.synthetic {
		st.err = fmt.aprintf(
			"%s is a --demo-users placeholder, not a real account; it is never sent to greetd",
			u.name,
		)
		return
	}
	st.queued_secret = strings.clone(string(st.answer[:]))
	clear(&st.answer)
	st.caret = 0
	st.prompt = ""
	st.info = ""
	create := req_create_session(u.name, context.temp_allocator)
	request(st, create, create, .Create, ui)
}

cancel :: proc(st: ^St, ui: ^p.Ctx) {
	if !st.session_live || st.stage == .Busy {
		return
	}
	c := req_cancel_session(context.temp_allocator)
	request(st, c, c, .Cancel, ui)
}

start_session_now :: proc(st: ^St, ui: ^p.Ctx) {
	s := cur_session(st)
	u := cur_user(st)
	cmd := session_cmd(s, context.temp_allocator)
	env := session_env(s, u, context.temp_allocator)
	payload := req_start_session(cmd, env, context.temp_allocator)
	request(st, payload, payload, .Start, ui)
}

// pump drains whatever greetd has sent, without ever blocking the frame loop.
pump :: proc(st: ^St, ui: ^p.Ctx) {
	for st.await != .Nothing && st.client.open && readable(&st.client, 0) {
		r, e := recv(&st.client)
		if e != "" {
			st.err = e
			st.err_fatal = true
			st.stage = .Idle
			st.await = .Nothing
			st.session_live = false
			st.connected = st.client.open
			return
		}
		apply_reply(st, r, ui)
	}
}

apply_reply :: proc(st: ^St, r: Reply, ui: ^p.Ctx) {
	was := st.await
	st.await = .Nothing

	switch r.kind {
	case .None:
		st.err = "greetd sent an empty reply"
		st.stage = .Idle

	case .Auth_Message:
		st.session_live = true
		switch r.auth_kind {
		case .Secret, .Visible:
			st.prompt = r.auth_message
			st.secret = r.auth_kind == .Secret
			st.stage = .Prompting
			st.focus = .Answer
			clear(&st.answer)
			st.caret = 0
			if st.secret && st.queued_secret != "" {
				// The password was typed before greetd asked. Answer at once.
				append(&st.answer, ..transmute([]u8)st.queued_secret)
				st.caret = len(st.answer)
				st.queued_secret = ""
				submit(st, ui)
			}
		case .Info:
			st.info = r.auth_message
			// Informative messages need no answer, but they do need to be
			// acknowledged before the conversation moves on.
			ack := req_post_response("", false, context.temp_allocator)
			request(st, ack, ack, .Answer, ui)
		case .Error:
			st.err = r.auth_message
			st.err_fatal = false
			ack := req_post_response("", false, context.temp_allocator)
			request(st, ack, ack, .Answer, ui)
		}

	case .Success:
		switch was {
		case .Create, .Answer:
			// Authentication is done; the session is ready to be started.
			st.session_live = true
			st.prompt = ""
			st.err = ""
			start_session_now(st, ui)
		case .Start:
			st.stage = .Started
			st.started_at = p.elapsed(ui)
			st.session_live = false
			client_log(
				&st.client,
				"session accepted; a real greeter now exits so greetd can start it",
			)
		case .Cancel:
			st.stage = .Idle
			st.session_live = false
			st.prompt = ""
			st.info = ""
			st.err = ""
			clear(&st.answer)
			st.caret = 0
			st.queued_secret = ""
		case .Nothing:
			st.stage = .Idle
		}

	case .Error:
		st.queued_secret = ""
		clear(&st.answer)
		st.caret = 0
		st.prompt = ""
		if r.error_type == "auth_error" {
			// Not fatal: wrong credentials. greetd drops the session, so the
			// next attempt starts a fresh one.
			st.err = r.description == "" ? "Authentication failed" : r.description
			st.err_fatal = false
		} else {
			st.err = r.description == "" ? "greetd reported an error" : r.description
			st.err_fatal = true
		}
		st.session_live = false
		st.stage = .Idle
		st.focus = .Answer
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

focus_step :: proc(st: ^St, delta: int) {
	at := 0
	for f, i in FOCUS_ORDER {
		if f == st.focus {
			at = i
			break
		}
	}
	n := len(FOCUS_ORDER)
	st.focus = FOCUS_ORDER[(at + delta + n) % n]
	if st.focus == .Suspend && !power_available(.Suspend) {
		// A button that is not drawn is not in the focus ring either.
		st.focus = FOCUS_ORDER[(at + 2 * delta + n) % n]
	}
}

rune_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {
		i -= 1
	}
	return at - i
}

rune_forward :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {
		i += 1
	}
	return i - at
}

handle_keys :: proc(st: ^St, ui: ^p.Ctx) {
	// Printable input only lands in the answer field, and it is taken before
	// the named keys below. A frame can carry both — `type "palmy"` followed
	// immediately by Return arrives as one batch — and handling Return first
	// would submit a password that is missing its last characters.
	if st.focus == .Answer && st.stage != .Busy && st.stage != .Started {
		if typed := p.typed_text(ui); len(typed) > 0 {
			st.caret = clamp(st.caret, 0, len(st.answer))
			inject_at_elems(&st.answer, st.caret, ..transmute([]u8)typed)
			st.caret += len(typed)
		}
	}

	// One dispatcher for the whole screen: the greeter owns its focus ring
	// rather than letting each field grab keys, because the arrows mean
	// different things depending on where focus is.
	for k in ui.input.keys {
		shift := .Shift in k.mods
		ctrl := .Ctrl in k.mods

		// Holding a key should not re-submit, re-cancel or walk the focus
		// ring: those are one-shot actions. Text, arrows and the delete keys
		// are the ones that want the compositor's repeat rate.
		if k.repeat {
			switch k.sym {
			case p.KEY_RETURN, p.KEY_KP_ENTER, p.KEY_ESCAPE, p.KEY_TAB, p.KEY_SPACE, p.KEY_F2:
				continue
			}
		}

		switch k.sym {
		case p.KEY_TAB:
			focus_step(st, shift ? -1 : 1)
			continue
		case p.KEY_ESCAPE:
			if st.session_live {
				cancel(st, ui)
			} else {
				clear(&st.answer)
				st.caret = 0
				st.err = ""
				st.info = ""
				st.note = ""
				st.queued_secret = ""
			}
			continue
		case p.KEY_F2:
			st.show_log = !st.show_log
			continue
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			switch st.focus {
			case .Answer:
				submit(st, ui)
			case .User, .Session:
				st.focus = .Answer
			case .Suspend:
				st.note = power_request(.Suspend, st.sock)
			case .Reboot:
				st.note = power_request(.Reboot, st.sock)
			case .Shutdown:
				st.note = power_request(.Shutdown, st.sock)
			}
			continue
		case p.KEY_SPACE:
			switch st.focus {
			case .Suspend:
				st.note = power_request(.Suspend, st.sock)
				continue
			case .Reboot:
				st.note = power_request(.Reboot, st.sock)
				continue
			case .Shutdown:
				st.note = power_request(.Shutdown, st.sock)
				continue
			case .User, .Answer, .Session:
			// a space in the answer: fall through to typed text
			}
		case p.KEY_UP, p.KEY_DOWN:
			d := k.sym == p.KEY_DOWN ? 1 : -1
			if st.focus == .Session {
				step_session(st, d)
			} else {
				step_user(st, d)
			}
			continue
		case p.KEY_LEFT, p.KEY_RIGHT:
			d := k.sym == p.KEY_RIGHT ? 1 : -1
			switch st.focus {
			case .User:
				step_user(st, d)
				continue
			case .Session:
				step_session(st, d)
				continue
			case .Suspend, .Reboot, .Shutdown:
				focus_step(st, d)
				continue
			case .Answer:
				if d < 0 {
					if st.caret > 0 {
						st.caret -= rune_back(st.answer[:], st.caret)
					}
				} else {
					if st.caret < len(st.answer) {
						st.caret += rune_forward(st.answer[:], st.caret)
					}
				}
				continue
			}
		case p.KEY_BACKSPACE:
			if st.focus == .Answer && st.caret > 0 {
				n := rune_back(st.answer[:], st.caret)
				remove_range(&st.answer, st.caret - n, st.caret)
				st.caret -= n
			}
			continue
		case p.KEY_DELETE:
			if st.focus == .Answer && st.caret < len(st.answer) {
				n := rune_forward(st.answer[:], st.caret)
				remove_range(&st.answer, st.caret, st.caret + n)
			}
			continue
		case p.KEY_HOME:
			st.caret = 0
			continue
		case p.KEY_END:
			st.caret = len(st.answer)
			continue
		case 'u':
			if ctrl {
				clear(&st.answer)
				st.caret = 0
				continue
			}
		case 'a':
			if ctrl {
				st.caret = 0
				continue
			}
		case 'e':
			if ctrl {
				st.caret = len(st.answer)
				continue
			}
		case 'c':
			if ctrl {
				if st.session_live {
					cancel(st, ui)
				}
				continue
			}
		}
	}

}

step_user :: proc(st: ^St, d: int) {
	if len(st.users) == 0 {
		return
	}
	st.user_i = (st.user_i + d + len(st.users)) % len(st.users)
	// Changing account invalidates anything already under configuration.
	if !st.session_live {
		clear(&st.answer)
		st.caret = 0
		st.err = ""
		st.info = ""
	}
}

step_session :: proc(st: ^St, d: int) {
	if len(st.sessions) == 0 {
		return
	}
	st.session_i = (st.session_i + d + len(st.sessions)) % len(st.sessions)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

draw :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	// A soft wash so the card has something to sit on.
	p.div(ui, "absolute inset-0 bg-gradient-to-b from-[#121217] to-[#07070a]")
	p.end(ui)

	header(st, ui)

	p.col(ui, "flex-1 w-full items-center justify-center px-8 pb-[96]")
	card(st, ui)
	p.end(ui)

	footer(st, ui)
}

header :: proc(st: ^St, ui: ^p.Ctx) {
	h, m, s := local_clock(st)
	y, mon, d := local_date(st)
	wd := local_weekday(st)

	p.col(ui, "w-full items-center pt-[64] gap-1")
	defer p.end(ui)

	p.row(ui, "items-end gap-2")
	p.textf(ui, "text-8xl font-bold text-foreground tracking-tight", "%02d:%02d", h, m)
	p.textf(ui, "text-2xl font-medium text-muted-foreground pb-[14]", ":%02d", s)
	p.end(ui)

	p.textf(ui, "text-lg text-muted-foreground", "%s, %d %s %d", wd, d, mon, y)

	p.row(ui, "items-center gap-2 mt-3")
	p.icon(ui, GI_SERVER, "size-3.5 text-muted-foreground")
	p.text(ui, st.hostname, "text-sm text-muted-foreground")
	if st.mock {
		p.div(ui, "w-2")
		p.end(ui)
		sc.badge(ui, "MOCK greetd", .Destructive)
	}
	p.end(ui)
}

CARD :: "w-[520] p-6 gap-5 rounded-xl border border-border bg-card shadow-2xl"

card :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, CARD)
	defer p.end(ui)

	// --- the account -------------------------------------------------------
	u := cur_user(st)
	p.row(ui, "items-center gap-4")
	{
		sc.avatar_open(ui, .LG)
		sc.avatar_fallback(ui, u.initials == "" ? "?" : u.initials, .LG)
		sc.avatar_end(ui)

		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, u.real == "" ? "no local accounts" : u.real, "text-base font-semibold text-foreground")
		if u.name != "" {
			p.textf(ui, "text-xs text-muted-foreground", "%s · uid %d · %s", u.name, u.uid, u.shell)
		}
		p.end(ui)

		stepper(ui, st.focus == .User, len(st.users))
	}
	p.end(ui)

	sc.separator(ui)

	// --- the question ------------------------------------------------------
	label := st.prompt
	if label == "" {
		label = "Password"
	}
	p.col(ui, "gap-2")
	{
		p.row(ui, "items-center gap-2")
		p.icon(ui, st.secret ? GI_LOCK : GI_KEY_ROUND, "size-3.5 text-muted-foreground")
		p.text(ui, strings.trim_right(label, ": "), "text-xs font-medium text-muted-foreground")
		p.end(ui)

		answer_field(st, ui)
	}
	p.end(ui)

	// --- state -------------------------------------------------------------
	banner(st, ui)

	// --- the action --------------------------------------------------------
	p.row(ui, "items-center gap-3")
	{
		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, "Enter to sign in · Tab to move · Esc to clear", "text-xs text-muted-foreground")
		p.textf(
			ui,
			"text-xs text-muted-foreground",
			"%d account%s · %d session%s",
			len(st.users),
			len(st.users) == 1 ? "" : "s",
			len(st.sessions),
			len(st.sessions) == 1 ? "" : "s",
		)
		p.end(ui)

		busy := st.stage == .Busy
		done := st.stage == .Started
		idx := sc.button_open(
			ui,
			done ? .Secondary : .Default,
			.LG,
			{focus = st.focus == .Answer, disabled = busy || done},
		)
		p.apply(ui, "px-4 gap-2")
		if p.clickable(ui, idx) && !busy && !done {
			submit(st, ui)
		}
		if busy {
			sc.spinner(ui, "size-4")
			p.text(ui, "Authenticating", "whitespace-nowrap")
		} else if done {
			p.icon(ui, GI_CIRCLE_CHECK, "size-4")
			p.text(ui, "Session ready", "whitespace-nowrap")
		} else {
			p.icon(ui, GI_ARROW_RIGHT, "size-4")
			p.text(ui, "Sign in", "whitespace-nowrap")
		}
		sc.button_end(ui)
	}
	p.end(ui)
}

// stepper is the `‹ n ›` affordance that says a row is a selector.
stepper :: proc(ui: ^p.Ctx, focused: bool, count: int) {
	cls := focused ? "items-center gap-1 px-2 py-1 rounded-md border border-ring ring-3 ring-ring/50 bg-muted" : "items-center gap-1 px-2 py-1 rounded-md border border-border"
	p.row(ui, cls)
	defer p.end(ui)
	p.icon(ui, GI_CHEVRON_LEFT, focused ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground")
	p.textf(ui, focused ? "text-xs text-foreground" : "text-xs text-muted-foreground", "%d", count)
	p.icon(ui, GI_CHEVRON_RIGHT, focused ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground")
}

// answer_field is the password box. palmy's `text_field` cannot mask its
// contents, so this is the same shape built from the primitives: the real
// bytes live in `st.answer` and only bullets are ever drawn.
answer_field :: proc(st: ^St, ui: ^p.Ctx) {
	focused := st.focus == .Answer
	invalid := st.err != "" && !st.err_fatal

	idx := p.div(
		ui,
		"h-10 w-full min-w-0 flex-row items-center gap-0 rounded-lg border border-input bg-background px-3 py-1 text-sm cursor-text overflow-hidden",
	)
	if focused {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	if invalid {
		p.apply(ui, "border-destructive ring-3 ring-destructive/20")
	}
	if st.stage == .Busy || st.stage == .Started {
		p.apply(ui, "opacity-60")
	}
	if p.clickable(ui, idx) {
		st.focus = .Answer
	}
	defer p.end(ui)

	content := string(st.answer[:])
	if len(content) == 0 {
		caret_bar(ui, focused)
		ph := st.secret ? "Password" : "Answer"
		p.text(ui, ph, "text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	} else {
		before := content[:clamp(st.caret, 0, len(content))]
		after := content[clamp(st.caret, 0, len(content)):]
		if st.secret {
			p.text(ui, bullets(before), "text-foreground whitespace-nowrap tracking-widest")
			p.style(ui).shrink = 0
			caret_bar(ui, focused)
			p.text(ui, bullets(after), "text-foreground whitespace-nowrap tracking-widest")
			p.style(ui).shrink = 0
		} else {
			p.text(ui, before, "text-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			caret_bar(ui, focused)
			p.text(ui, after, "text-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
	}
}

// caret_bar blinks, which is also what keeps the surface animating.
caret_bar :: proc(ui: ^p.Ctx, focused: bool) {
	if !focused {
		return
	}
	on := int(p.elapsed(ui) / 0.53) % 2 == 0
	p.div(ui, on ? "w-[2] h-[18] rounded-sm bg-primary" : "w-[2] h-[18]")
	p.style(ui).shrink = 0
	p.end(ui)
}

// bullets renders one dot per rune, never the real bytes.
bullets :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in s {
		strings.write_string(&sb, "•")
	}
	return strings.to_string(sb)
}

banner :: proc(st: ^St, ui: ^p.Ctx) {
	if st.err != "" {
		cls :=
			st.err_fatal \
			? "w-full flex-row items-start gap-2 p-3 rounded-lg border border-destructive/50 bg-destructive/10" \
			: "w-full flex-row items-start gap-2 p-3 rounded-lg border border-destructive/60 bg-destructive/15"
		p.row(ui, cls)
		p.icon(ui, st.err_fatal ? GI_TRIANGLE_ALERT : GI_CIRCLE_ALERT, "size-4 text-destructive mt-px")
		p.col(ui, "flex-1 gap-0.5")
		p.text(
			ui,
			st.err_fatal ? "greetd error" : "Authentication failed",
			"text-xs font-semibold text-destructive",
		)
		p.text(ui, st.err, "text-xs text-destructive/90")
		p.end(ui)
		p.end(ui)
	}
	if st.info != "" {
		p.row(ui, "w-full flex-row items-start gap-2 p-3 rounded-lg border border-border bg-muted")
		p.icon(ui, GI_INFO, "size-4 text-muted-foreground mt-px")
		p.text(ui, st.info, "flex-1 text-xs text-muted-foreground")
		p.end(ui)
	}
	if st.note != "" {
		p.row(ui, "w-full flex-row items-start gap-2 p-3 rounded-lg border border-border bg-muted")
		p.icon(ui, GI_POWER, "size-4 text-muted-foreground mt-px")
		p.text(ui, st.note, "flex-1 text-xs text-muted-foreground")
		p.end(ui)
	}
	if st.stage == .Started {
		p.row(
			ui,
			"w-full flex-row items-center gap-2 p-3 rounded-lg border border-emerald-700 bg-emerald-950",
		)
		p.icon(ui, GI_CIRCLE_CHECK, "size-4 text-emerald-400")
		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, "Signed in", "text-xs font-semibold text-emerald-300")
		p.textf(
			ui,
			"text-xs text-emerald-400/90",
			"greetd accepted the session; it starts as soon as the greeter exits",
		)
		p.end(ui)
		p.end(ui)
	}
}

footer :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full gap-3 px-8 pb-6")
	defer p.end(ui)

	if st.show_log {
		protocol_log(st, ui)
	}

	p.row(ui, "w-full items-center gap-4")
	defer p.end(ui)

	// Session selector.
	s := cur_session(st)
	cls := st.focus == .Session ? "items-center gap-3 px-3 py-2 rounded-lg border border-ring ring-3 ring-ring/50 bg-card" : "items-center gap-3 px-3 py-2 rounded-lg border border-border bg-card/60"
	idx := p.row(ui, cls)
	if p.clickable(ui, idx) {
		st.focus = .Session
	}
	{
		p.icon(ui, s.kind == .Shell ? GI_TERMINAL : GI_MONITOR, "size-4 text-muted-foreground")
		p.col(ui, "gap-0.5")
		p.text(ui, s.name, "text-sm font-medium text-foreground whitespace-nowrap")
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap",
			"%s · %s",
			session_kind_label(s.kind),
			s.exec,
		)
		p.end(ui)
		p.icon(ui, GI_CHEVRONS_UP_DOWN, "size-4 text-muted-foreground")
	}
	p.end(ui)

	p.spacer(ui)

	if !st.connected {
		p.row(ui, "items-center gap-2 px-3 py-2 rounded-lg border border-destructive/50 bg-destructive/10")
		p.icon(ui, GI_TRIANGLE_ALERT, "size-4 text-destructive")
		p.textf(ui, "text-xs text-destructive whitespace-nowrap", "no greetd on %s", st.sock)
		p.end(ui)
		p.div(ui, "w-4")
		p.end(ui)
	}

	// Power actions. Every one of these calls a stub, except under
	// palm-login, where the ones that exist are real (see power_request).
	for act in Power {
		if !power_available(act) {
			continue
		}
		focused := (act == .Suspend && st.focus == .Suspend) ||
			(act == .Reboot && st.focus == .Reboot) ||
			(act == .Shutdown && st.focus == .Shutdown)
		b := sc.button_open(ui, .Outline, .LG, {focus = focused, hover = false})
		p.apply(ui, "px-3 gap-2")
		if p.clickable(ui, b) {
			st.note = power_request(act, st.sock)
		}
		p.icon(ui, power_icon(act), "size-4")
		p.text(ui, power_label(act), "whitespace-nowrap")
		sc.button_end(ui)
	}
}

LOG_LINES :: 6

protocol_log :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full gap-1 p-3 rounded-lg border border-border bg-card/60")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	p.icon(ui, GI_TERMINAL, "size-3.5 text-muted-foreground")
	p.textf(
		ui,
		"text-xs font-medium text-muted-foreground",
		"greetd IPC · %s  (F2 hides this)",
		st.sock == "" ? "no socket" : st.sock,
	)
	p.end(ui)

	n := len(st.client.log)
	from := max(0, n - LOG_LINES)
	for i in from ..< n {
		line := st.client.log[i]
		cls := "text-xs font-mono text-muted-foreground whitespace-nowrap truncate"
		if strings.has_prefix(line, "-> ") {
			cls = "text-xs font-mono text-sky-400 whitespace-nowrap truncate"
		} else if strings.has_prefix(line, "<- ") {
			cls = "text-xs font-mono text-emerald-400 whitespace-nowrap truncate"
		}
		p.text(ui, line, cls)
	}
	if n == 0 {
		p.text(ui, "nothing sent yet", "text-xs font-mono text-muted-foreground")
	}
}

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

local_now :: proc(st: ^St) -> time.Time {
	return time.time_add(time.now(), st.tz)
}

local_clock :: proc(st: ^St) -> (h, m, s: int) {
	return time.clock_from_time(local_now(st))
}

local_date :: proc(st: ^St) -> (y: int, month: string, d: int) {
	yy, mm, dd := time.date(local_now(st))
	return yy, MONTHS[int(mm) - 1], dd
}

local_weekday :: proc(st: ^St) -> string {
	return DAYS[int(time.weekday(local_now(st)))]
}

MONTHS := [?]string {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

DAYS := [?]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
