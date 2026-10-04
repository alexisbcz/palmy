package main

// `greeter --shots <dir>`: render the login screen offscreen and write PNGs.
//
// Everything the real greeter shows about the machine — the accounts, the
// sessions, the hostname — is read off the system it is running on, and none
// of that belongs in a published picture. So nothing is read here: the user
// list, the session list and the hostname are all fabricated, and the greetd
// socket is never opened. The only live value is the clock.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1440
SHOT_H :: 900

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("greeter: could not create %s", dir)
		return 1
	}

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	register_dark_theme()

	st := new(St)
	st.users = shot_users()
	st.sessions = shot_sessions()
	st.hostname = "atelier"
	st.tz = 0
	st.sock = "/run/greetd/greetd.sock"
	st.connected = true
	st.answer = make([dynamic]u8)
	st.focus = .Answer
	st.secret = true
	st.stage = .Idle

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		handle_keys(st, ui)
		draw(st, ui)
		p.offscreen_end(off)
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// The screen as it waits: an account, a session, a masked password.
	p.type_text(off, "correct horse battery")
	step(off, st)
	step(off, st)
	shot(off, dir, "app-greeter", &n)

	// The account selector, on a different account.
	st.focus = .User
	st.user_i = 1
	step(off, st)
	step(off, st)
	shot(off, dir, "02-greeter-account", &n)

	// A rejected password.
	st.focus = .Answer
	st.user_i = 0
	clear(&st.answer)
	st.caret = 0
	st.err = strings.clone("Authentication failure")
	step(off, st)
	step(off, st)
	shot(off, dir, "03-greeter-rejected", &n)

	// The request in flight.
	delete(st.err)
	st.err = ""
	append(&st.answer, "hunter2hunter2")
	st.caret = len(st.answer)
	st.stage = .Busy
	st.await = .Answer
	step(off, st)
	step(off, st)
	shot(off, dir, "04-greeter-authenticating", &n)

	// Accepted, with the protocol log open so the IPC is visible rather than
	// merely claimed.
	st.stage = .Started
	st.await = .Nothing
	st.show_log = true
	shot_log(st)
	step(off, st)
	step(off, st)
	shot(off, dir, "05-greeter-signed-in", &n)

	// The session selector, which is where the other half of a greeter lives.
	st.stage = .Idle
	st.show_log = false
	st.focus = .Session
	st.session_i = 2
	clear(&st.answer)
	st.caret = 0
	step(off, st)
	step(off, st)
	shot(off, dir, "06-greeter-session", &n)

	fmt.printfln("greeter --shots: %d PNGs in %s", n, dir)
	return 0
}

// ---------------------------------------------------------------------------
// Fabricated system facts
// ---------------------------------------------------------------------------

shot_users :: proc() -> []User {
	out := make([dynamic]User)
	for u in ([?]User {
		{
			name = "amerrick",
			real = "Ada Merrick",
			uid = 1000,
			home = "/var/home/amerrick",
			shell = "/usr/bin/fish",
			synthetic = true,
		},
		{
			name = "rwatson",
			real = "Rosalind Watson",
			uid = 1001,
			home = "/var/home/rwatson",
			shell = "/usr/bin/zsh",
			synthetic = true,
		},
		{
			name = "kjarvis",
			real = "Kofi Jarvis",
			uid = 1002,
			home = "/var/home/kjarvis",
			shell = "/bin/bash",
			synthetic = true,
		},
	}) {
		e := u
		e.initials = initials_of(e.real)
		append(&out, e)
	}
	return out[:]
}

shot_sessions :: proc() -> []Session {
	out := make([dynamic]Session)
	append(
		&out,
		Session {
			name = "palmy wm",
			comment = "The nested compositor in this repository",
			exec = "palmy-wm",
			desktop = "palmy",
			kind = .Wayland,
			path = "/usr/share/wayland-sessions/palmy.desktop",
		},
	)
	append(
		&out,
		Session {
			name = "Hyprland",
			comment = "A dynamic tiling Wayland compositor",
			exec = "Hyprland",
			desktop = "Hyprland",
			kind = .Wayland,
			path = "/usr/share/wayland-sessions/hyprland.desktop",
		},
	)
	append(
		&out,
		Session {
			name = "Plasma (X11)",
			comment = "The KDE Plasma desktop on Xorg",
			exec = "startplasma-x11",
			desktop = "KDE",
			kind = .X11,
			path = "/usr/share/xsessions/plasma.desktop",
		},
	)
	append(&out, Session{name = "Shell", comment = "A login shell", exec = "$SHELL -l", kind = .Shell})
	return out[:]
}

// shot_log fabricates the greetd conversation the log panel shows, since no
// socket is opened for a screenshot.
shot_log :: proc(st: ^St) {
	for line in ([?]string {
		"connected to /run/greetd/greetd.sock",
		"-> {\"type\":\"create_session\",\"username\":\"amerrick\"}",
		"<- {\"type\":\"auth_message\",\"auth_message_type\":\"secret\",\"auth_message\":\"Password: \"}",
		"-> {\"type\":\"post_auth_message_response\",\"response\":\"***\"}",
		"<- {\"type\":\"success\"}",
		"-> {\"type\":\"start_session\",\"cmd\":[\"palmy-wm\"]}",
		"<- {\"type\":\"success\"}",
	}) {
		append(&st.client.log, strings.clone(line))
	}
}

// ---------------------------------------------------------------------------
// Fonts, exactly as `kit.start` loads them
// ---------------------------------------------------------------------------

shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}
