package main

// `welcome drive`: the window, run offscreen, typed into the way a person
// would type into it — Enter, Tab, Space, letters, Ctrl+N — against a real
// server, from the first page to the last. Nothing calls the flow's
// procedures directly: if a key does not reach the control it is meant for,
// the run gets stuck and says on which page.
//
// It is the end-to-end test of the window (apps/welcome/e2e.sh runs it in a
// fresh HOME against cloud/dev), and with --shots it photographs each step
// as it is reached.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

Drive_Result :: struct {
	steps:    [dynamic]string,
	finished: bool,
	keys:     int,
	err:      string,
}

@(private = "file")
Driver :: struct {
	off:   ^p.Offscreen,
	st:    ^St,
	res:   ^Drive_Result,
	shots: string,
	n:     int,
}

@(private = "file")
frame :: proc(d: ^Driver) {
	ui := p.offscreen_begin(d.off)
	draw(d.st, ui)
	p.offscreen_end(d.off)
}

@(private = "file")
settle :: proc(d: ^Driver, n := 3) {
	for _ in 0 ..< n {
		frame(d)
	}
}

@(private = "file")
key :: proc(d: ^Driver, sym: u32, mods: p.Modifiers = {}) {
	append(&d.off.input.keys, p.Key_Event{sym = sym, mods = mods})
	if sym == p.KEY_SPACE && mods == {} {
		strings.write_string(&d.off.input.text, " ")
	}
	d.res.keys += 1
	settle(d)
}

@(private = "file")
type :: proc(d: ^Driver, s: string) {
	strings.write_string(&d.off.input.text, s)
	d.res.keys += len(s)
	settle(d)
}

@(private = "file")
tabs :: proc(d: ^Driver, n: int) {
	for _ in 0 ..< n {
		key(d, p.KEY_TAB)
	}
}

// wait runs frames until the job is over, as the window's loop would.
@(private = "file")
wait :: proc(d: ^Driver) {
	deadline := time.tick_now()
	for d.st.job.running {
		frame(d)
		time.sleep(20 * time.Millisecond)
		if time.tick_since(deadline) > 180 * time.Second {
			break
		}
	}
	settle(d)
}

@(private = "file")
expect :: proc(d: ^Driver, want: Step) -> bool {
	settle(d)
	if d.st.step != want {
		if d.res.err == "" {
			d.res.err = fmt.aprintf("expected the %v page, on the %v page (message: %q)", want, d.st.step, d.st.msg)
		}
		return false
	}
	name := step_file(want)
	append(&d.res.steps, name)
	if d.shots != "" {
		d.n += 1
		out := fmt.aprintf("%s/%02d-%s.png", d.shots, d.n, name)
		p.offscreen_write_png(d.off, out)
		delete(out)
	}
	return true
}

@(private = "file")
snap :: proc(d: ^Driver, name: string) {
	if d.shots == "" {
		return
	}
	d.n += 1
	out := fmt.aprintf("%s/%02d-%s.png", d.shots, d.n, name)
	p.offscreen_write_png(d.off, out)
	delete(out)
}

drive_flow :: proc(local: bool, email, shots_dir, lang, theme: string) -> Drive_Result {
	res: Drive_Result
	if shots_dir != "" {
		os.make_directory_all(shots_dir, os.perm(0o755))
	}
	if lang != "" {
		set_language(lang)
	}
	st := new(St)
	st_init(st, {})
	switch theme {
	case "dark":
		st.dark = true
	case "light":
		st.dark = false
	}
	open_store(st)

	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	kit_fonts(&off.fonts)
	p.set_text_gamma(1.8)
	register_theme(st.dark)
	d := Driver{off = off, st = st, res = &res, shots = shots_dir}

	// The handles are global, so a run makes its own from the email's local
	// part: e2e7781@palm.test gives e2e7781 and e2e7781.northwind.
	at := strings.index_byte(email, '@')
	who := at > 0 ? email[:at] : "welcome"
	password := fmt.tprintf("pw %s %s", who, "correct horse")
	vault_pw := fmt.tprintf("vault %s battery staple", who)
	password = strings.clone(password)
	vault_pw = strings.clone(vault_pw)
	who = strings.clone(who)

	if !expect(&d, .Welcome) {return res}
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Account) {return res}

	if local {
		key(&d, p.KEY_DOWN) // "Only on this computer"
		key(&d, p.KEY_RETURN)
		if !expect(&d, .Import) {return res}
		key(&d, p.KEY_RETURN)
		if !expect(&d, .Tour) {return res}
		key(&d, p.KEY_RETURN)
		if !expect(&d, .Done) {return res}
		key(&d, p.KEY_RETURN)
		res.finished = st.finished
		return res
	}

	key(&d, p.KEY_RETURN) // the focused card, "Use an account", and Next
	if !expect(&d, .Sign_In) {return res}
	if st.signed_in {
		res.err = strings.clone("this HOME is already signed in; run it in a fresh one")
		return res
	}
	// Create account: name, email, password, confirm, Enter.
	type(&d, who)
	tabs(&d, 1)
	type(&d, email)
	tabs(&d, 1)
	type(&d, password)
	tabs(&d, 1)
	type(&d, password)
	snap(&d, "sign-in-typed")
	key(&d, p.KEY_RETURN)
	wait(&d)
	if !expect(&d, .Identities) {return res}

	// The suggested row is named after the person. A second, for work.
	key(&d, 'n', {.Ctrl})
	type(&d, fmt.tprintf("%s at Northwind", who))
	snap(&d, "identities-typed")
	key(&d, p.KEY_RETURN)
	wait(&d)
	if !expect(&d, .Sync) {return res}

	// The first identity's first switch has the keyboard: Mail, Drive,
	// Calendar, Notes, Passwords. Four Tabs reach Passwords; Space turns it on.
	tabs(&d, 4)
	key(&d, p.KEY_SPACE)
	snap(&d, "sync-chosen")
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Passwords) {return res}

	type(&d, vault_pw)
	tabs(&d, 1)
	type(&d, vault_pw)
	key(&d, p.KEY_RETURN)
	wait(&d)
	if !st.vault_done {
		res.err = fmt.aprintf("the vault was not set up: %s", st.msg)
		return res
	}
	if !expect(&d, .Passwords) {return res}
	key(&d, p.KEY_SPACE) // Save Emergency Kit, which has the keyboard
	wait(&d)
	if st.kit_paths[0] == "" {
		res.err = fmt.aprintf("the Emergency Kit was not saved: %s", st.msg)
		return res
	}
	settle(&d)
	key(&d, p.KEY_SPACE) // "I have saved my Emergency Kit"
	snap(&d, "emergency-kit-saved")
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Setup) {return res}

	key(&d, p.KEY_RETURN) // Set up
	wait(&d)
	snap(&d, "setup-done")
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Import) {return res}
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Tour) {return res}
	key(&d, p.KEY_RETURN)
	if !expect(&d, .Done) {return res}
	key(&d, p.KEY_RETURN)
	res.finished = st.finished

	// What the run left behind, for the caller to check.
	for t in st.tasks {
		fmt.eprintfln("welcome drive: %-28s %-12v %-15v %s", t.handle == "" ? "(computer)" : t.handle, t.what, t.state, t.detail)
	}
	return res
}
