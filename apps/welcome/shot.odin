package main

// `welcome shots DIR`: every step, offscreen, in light and dark, in English
// and Arabic (and the first steps in every language). A fixture account
// invented here; no network, no token store, nothing written but the PNGs.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

SHOT_W :: 1280
SHOT_H :: 800

FIX_SECRET :: "PV1-K7Q2M4-ZX8B3N-R5T9WD-H2CJ6P-4F"

shot_unbalanced: int

shot_frame :: proc(off: ^p.Offscreen, st: ^St) {
	ui := p.offscreen_begin(off)
	depth := len(ui.stack)
	draw(st, ui)
	if len(ui.stack) != depth {
		fmt.eprintfln("welcome: step %v left %d elements open", st.step, len(ui.stack) - depth)
		shot_unbalanced += 1
	}
	p.offscreen_end(off)
}

shoot :: proc(off: ^p.Offscreen, st: ^St, dir, name: string) -> int {
	// Built before the frames: each frame frees the temp allocator, which is
	// where `name` usually lives.
	out := fmt.aprintf("%s/%s.png", dir, name)
	defer delete(out)
	for _ in 0 ..< 3 {
		shot_frame(off, st)
	}
	if p.offscreen_write_png(off, out) {
		return 1
	}
	return 0
}

set_buf :: proc(buf: ^[dynamic]u8, s: string) {
	clear(buf)
	append(buf, ..transmute([]u8)s)
}

fixture_state :: proc(lang: string, dark: bool) -> ^St {
	st := new(St)
	st_init(st, {fixture = true})
	st.lang_i = language_index(lang)
	st.lang_start = st.lang_i
	st.dark = dark
	set_buf(&st.url_buf, "http://127.0.0.1:54321")
	st.domain = "palm.test"
	st.choice = .Account
	return st
}

fixture_identities :: proc(st: ^St, existing: bool) {
	clear(&st.plans)
	a := add_plan(st, 0, "Camille Roux")
	a.color = 0
	b := add_plan(st, 1, "Camille at Northwind")
	set_buf(&b.handle, "camille.northwind")
	b.color = 1
	if existing {
		for &pl, i in st.plans {
			pl.existing = true
			pl.id = fmt.aprintf("fixture-%d", i)
		}
		st.plans[0].services += {.Passwords}
	}
}

shots :: proc(dir: string, only := "") -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("welcome: could not create %s", dir)
		return -1
	}
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	kit_fonts(&off.fonts)
	p.set_text_gamma(1.8)

	n := 0
	langs := []string{"en_US", "ar"}
	if only != "" {
		langs = strings.split(only, ",")
	}
	for lang in langs {
		for dark in ([?]bool{false, true}) {
			n += shots_in(off, dir, lang, dark)
		}
	}
	// The first page in the other languages, for the text that is longest
	// there (German) and the script that is not Latin (Japanese).
	if only == "" {
		for lang in ([?]string{"fr_FR", "de_DE", "es_ES", "ja_JP"}) {
			set_language(lang)
			register_theme(true)
			for step in ([?]Step{.Welcome, .Identities, .Sync, .Setup}) {
				st := fixture_state(lang, true)
				if step >= .Identities {
					st.mode = .Account
					st.email = "camille@example.org"
					st.signed_in = true
					fixture_identities(st, step != .Identities)
				}
				st.step = step
				if step == .Setup {
					fixture_setup(st, true)
				}
				n += shoot(off, st, dir, fmt.tprintf("%s-dark-%02d-%s", lang[:2], int(step) + 1, step_file(step)))
			}
		}
	}
	set_language("")
	fmt.printfln("welcome shots: %d PNGs in %s", n, dir)
	return shot_unbalanced == 0 ? n : -1
}

// kit_tr is tr without the right-to-left mark, for a format that is
// formatted later.
kit_tr :: proc(msgid: string) -> string {
	return kit.tr(msgid)
}

step_file :: proc(s: Step) -> string {
	switch s {
	case .Welcome:
		return "welcome"
	case .Account:
		return "account"
	case .Sign_In:
		return "sign-in"
	case .Identities:
		return "identities"
	case .Sync:
		return "sync"
	case .Passwords:
		return "passwords"
	case .Setup:
		return "setup"
	case .Import:
		return "import"
	case .Tour:
		return "tour"
	case .Done:
		return "done"
	}
	return "step"
}

fixture_setup :: proc(st: ^St, ran: bool) {
	st.vault_done = true
	plan_tasks(st)
	if !ran {
		return
	}
	st.setup_ran = true
	for &t in st.tasks {
		t.state = .Done
		switch t.what {
		case .Sync_Conf:
			t.detail = "~/.config/palm/sync.conf"
		case .Mailbox:
			t.detail = fmt.aprintf("%s@palm.test", t.handle)
		case .Drive:
			t.detail = fmt.aprintf("~/Drive/%s", t.handle)
		case .Calendar, .Contacts:
			t.state = .Pending_Server
			t.detail = "" // a tool's own reason, in its own words, when there is one
		case .Notes:
			t.state = .Coming
		case .Mail_Client:
			t.detail = fmt.aprintf(kit_tr("%d mailboxes on this computer"), 2)
		case .Session, .Chat, .Vault:
		}
	}
}

shots_in :: proc(off: ^p.Offscreen, dir, lang: string, dark: bool) -> int {
	set_language(lang)
	register_theme(dark)
	prefix := fmt.aprintf("%s-%s", lang[:2], dark ? "dark" : "light")
	n := 0
	name :: proc(prefix: string, i: int, s: string) -> string {
		return fmt.tprintf("%s-%02d-%s", prefix, i, s)
	}

	st := fixture_state(lang, dark)
	st.choice = .Undecided
	n += shoot(off, st, dir, name(prefix, 1, "welcome"))

	st.step = .Account
	st.choice = .Account
	n += shoot(off, st, dir, name(prefix, 2, "account"))

	st.step = .Sign_In
	st.mode = .Account
	set_buf(&st.name_buf, "Camille Roux")
	set_buf(&st.email_buf, "camille@example.org")
	set_buf(&st.pw_buf, "correct horse battery")
	set_buf(&st.pw2_buf, "correct horse battery")
	n += shoot(off, st, dir, name(prefix, 3, "sign-in"))

	st.auth_tab = .Sign_In
	set_buf(&st.pw_buf, "short")
	st.tried = true
	say(st, tr("That email and password do not match."), true)
	n += shoot(off, st, dir, name(prefix, 3, "sign-in-error"))
	clear_msg(st)
	st.tried = false
	st.auth_tab = .Create

	st.signed_in = true
	st.email = "camille@example.org"
	st.step = .Identities
	fixture_identities(st, false)
	n += shoot(off, st, dir, name(prefix, 4, "identities"))

	fixture_identities(st, true)
	st.step = .Sync
	n += shoot(off, st, dir, name(prefix, 5, "sync"))

	st.step = .Passwords
	set_buf(&st.vault_pw, "a long sentence to remember")
	set_buf(&st.vault_pw2, "a long sentence to remember")
	n += shoot(off, st, dir, name(prefix, 6, "passwords"))

	st.vault_done = true
	st.secret = FIX_SECRET
	st.kit_paths[0] = "/home/camille/Documents/Palmy Emergency Kit.png"
	st.kit_paths[1] = "/home/camille/Documents/Palmy Emergency Kit.txt"
	n += shoot(off, st, dir, name(prefix, 6, "emergency-kit"))
	st.kit_ack = true

	st.step = .Setup
	fixture_setup(st, false)
	n += shoot(off, st, dir, name(prefix, 7, "setup-plan"))
	fixture_setup(st, true)
	n += shoot(off, st, dir, name(prefix, 7, "setup-done"))

	st.step = .Import
	n += shoot(off, st, dir, name(prefix, 8, "import"))
	st.step = .Tour
	n += shoot(off, st, dir, name(prefix, 9, "tour"))
	st.step = .Done
	n += shoot(off, st, dir, name(prefix, 10, "done"))

	// The local-only path: the account steps drop out of the rail.
	lo := fixture_state(lang, dark)
	lo.mode = .Local
	lo.choice = .Local
	lo.step = .Account
	n += shoot(off, lo, dir, name(prefix, 2, "account-local"))
	lo.step = .Import
	n += shoot(off, lo, dir, name(prefix, 8, "import-local"))
	lo.step = .Tour
	n += shoot(off, lo, dir, name(prefix, 9, "tour-local"))
	lo.step = .Done
	n += shoot(off, lo, dir, name(prefix, 10, "done-local"))
	return n
}
