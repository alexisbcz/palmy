// `mail --palm-shots=DIR --data-dir=PATH`: the Palmy walkthrough, rendered
// offscreen against a live dev stack.
//
// Unlike `--shots`, nothing here is a fixture. The run starts signed out,
// types an email and password into the sign-in sheet, and presses Enter — which
// runs `mailcore palm login` and `mailcore palm sync` for real, against
// palm-maild on loopback — and then photographs what came back: each identity
// on its own, all of them, the unified-inbox prototype, and an Outbox holding
// mail the server would not send. cloud/mail/dev/demo.sh drives it.
//
// The credentials come from PALM_DEMO_EMAIL / PALM_DEMO_PASSWORD (the dev
// stack's invented people), so no password is written into this file.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

palm_shots :: proc(dir: string) -> int {
	if data_dir_override == "" {
		fmt.eprintln("mail --palm-shots: give --data-dir=PATH (a scratch .../palmy-mail directory)")
		return 2
	}
	// Not the temp allocator: every frame frees it, and these are typed in
	// several frames later.
	email := os.get_env("PALM_DEMO_EMAIL", context.allocator)
	password := os.get_env("PALM_DEMO_PASSWORD", context.allocator)
	if email == "" || password == "" {
		fmt.eprintln("mail --palm-shots: set PALM_DEMO_EMAIL and PALM_DEMO_PASSWORD")
		return 2
	}
	os.make_directory_all(dir)

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	init_state(st)

	step :: proc(off: ^p.Offscreen, st: ^State) {
		ui := p.offscreen_begin(off)
		st.now = time.now()
		handle_keys(ui, st, nil)
		frame(ui, st)
		apply_scroll(ui, st)
		p.offscreen_end(off)
	}
	shot :: proc(off: ^p.Offscreen, st: ^State, dir, name: string) {
		for _ in 0 ..< 3 {
			step(off, st)
		}
		path := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, path) {
			fmt.printfln("  %s", path)
		}
	}
	key :: proc(off: ^p.Offscreen, st: ^State, sym: u32, mods: p.Modifiers = {}) {
		p.press_key(off, sym, mods)
		step(off, st)
		step(off, st)
	}

	shot(off, st, dir, "palm-01-signed-out")

	key(off, st, 'p')
	p.type_text(off, email)
	step(off, st)
	key(off, st, p.KEY_TAB)
	p.type_text(off, password)
	step(off, st)
	shot(off, st, dir, "palm-02-sign-in")

	key(off, st, p.KEY_RETURN) // to the button
	key(off, st, p.KEY_RETURN) // sign in: mailcore palm login, then palm sync
	if palm_identities(st) == 0 {
		shot(off, st, dir, "palm-02b-sign-in-failed")
		fmt.eprintfln("mail --palm-shots: sign-in did not produce identities: %s", st.signin.error)
		return 1
	}
	fmt.printfln("mail --palm-shots: signed in as %s, %d identities, %d messages", st.palm_email, palm_identities(st), len(st.messages))

	// Identity 1, its inbox, the top conversation opened.
	key(off, st, '1')
	key(off, st, p.KEY_HOME)
	key(off, st, p.KEY_RETURN)
	shot(off, st, dir, "palm-03-identity-1")

	key(off, st, p.KEY_ESCAPE)
	key(off, st, '2')
	key(off, st, p.KEY_HOME)
	shot(off, st, dir, "palm-04-identity-2")

	key(off, st, '0')
	shot(off, st, dir, "palm-05-all-identities")

	key(off, st, 'i', {.Shift})
	shot(off, st, dir, "palm-06-unified-prototype")
	key(off, st, 'i', {.Shift})

	// An Outbox with mail the server held: the first identity's.
	key(off, st, '1')
	first := palm_nth(st, 0)
	for f, fi in st.folders {
		if f.role == .Outbox && f.account == first {
			select_folder(st, fi)
		}
	}
	key(off, st, p.KEY_HOME)
	shot(off, st, dir, "palm-07-outbox-held")

	key(off, st, 'p')
	shot(off, st, dir, "palm-08-account")
	key(off, st, p.KEY_ESCAPE)

	fmt.printfln("mail --palm-shots: wrote PNGs to %s", dir)
	return 0
}
