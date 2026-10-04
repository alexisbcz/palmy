package main

// palmy vault -- a password manager.
//
// The shape of it: a locked screen until the master password derives a key, a
// list you can search, a detail pane you can edit, a generator, and TOTP codes
// that count down. The crypto is in seal.odin, the file format in model.odin
// and store.odin, and the only thing this file is responsible for is never
// letting the key or a plaintext live longer than it has to.
//
// There is no network code in this program. Not a socket, not a DNS lookup, no
// breach check, no sync, no telemetry. The UI says so, on the lock screen,
// because a password manager that merely does not mention the network is
// asking to be trusted rather than checked.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

WIN_W :: 1180
WIN_H :: 760

// Defaults, both overridable on the command line so the recorded demo can show
// them firing inside a short take.
IDLE_LOCK_DEFAULT :: 300.0 // seconds of no input before the key is dropped
CLIP_CLEAR_DEFAULT :: 20.0 // seconds a copied secret stays on the clipboard

Screen :: enum u8 {
	Unlock, // a vault exists; ask for the master password
	Create, // no vault yet; ask for one twice
	Open,   // unlocked
}

Field :: enum u8 {
	Title,
	Username,
	Password,
	Url,
	Tags,
	Totp,
	Notes,
}

FIELD_LABEL := [Field]string {
	.Title    = "Title",
	.Username = "Username",
	.Password = "Password",
	.Url      = "URL",
	.Tags     = "Tags",
	.Totp     = "TOTP secret",
	.Notes    = "Notes",
}

Busy :: enum u8 {
	None,
	Unlocking,
	Creating,
	Rekeying,
}

Pick_Use :: enum u8 {
	None,
	Open_Vault,
}

St :: struct {
	path:       string,
	screen:     Screen,
	sess:       Session,
	v:          Vault,

	// Lock screen
	pw:         [dynamic]u8,
	pw2:        [dynamic]u8,
	lock_err:   string,
	busy:       Busy,
	derive_ms:  f64,
	pw_id:      u64,
	pw2_id:     u64,

	// List
	query:      [dynamic]u8,
	query_id:   u64,
	tag:        string,
	sel:        int,
	rows:       [dynamic]int,

	// Detail
	editing:    bool,
	ed_new:     bool,
	ed:         [Field][dynamic]u8,
	ed_first:   u64,
	reveal:     bool,
	history:    bool,

	// Generator
	gen_open:   bool,
	gen:        Gen_Opts,
	gen_pw:     string,

	// Master password change
	mp_open:    bool,
	mp_new:     [dynamic]u8,
	mp_again:   [dynamic]u8,
	mp_err:     string,
	mp_id:      u64,

	// Clipboard
	clip_label: string,
	clip_value: string,
	clip_until: f64,
	clip_total: f64,

	// Auto-lock
	last_input: f64,
	idle_limit: f64,
	clip_limit: f64,
	lock_note:  string,
	lock_at:    f64,
	focus_pw:   bool, // the lock screen should take the keyboard back
	focus_mp:   bool, // so should the master-password dialog

	confirm_del: bool,
	toast:      string,
	toast_t:    f64,
	have_clip:  bool,

	pick:       kit.Pick,
	pick_use:   Pick_Use,
}

g: St

main :: proc() {
	idle := f64(IDLE_LOCK_DEFAULT)
	clip := f64(CLIP_CLEAR_DEFAULT)
	path := ""

	for a in os.args[1:] {
		switch {
		case a == "--selftest" || a == "-selftest":
			os.exit(selftest() == 0 ? 0 : 1)
		case strings.has_prefix(a, "--idle="):
			if v, ok := strconv.parse_f64(a[7:]); ok && v > 0 {
				idle = v
			}
		case strings.has_prefix(a, "--clip="):
			if v, ok := strconv.parse_f64(a[7:]); ok && v > 0 {
				clip = v
			}
		case strings.has_prefix(a, "--vault="):
			path = strings.clone(a[8:])
		case strings.has_prefix(a, "--shot"):
			dir := "/tmp/palmy-vault-shots"
			if strings.has_prefix(a, "--shot=") {
				dir = a[7:]
			}
			g_test = true // never touch the real clipboard from here
			os.exit(shots(dir))
		case strings.has_prefix(a, "--make-demo-vault="):
			// Builds the vault the recorded demo unlocks, then exits. The
			// password is a constant printed in the source and the entries are
			// the first-run samples, so there is nothing real anywhere near a
			// frame of that recording.
			os.exit(make_demo_vault(a[18:]) ? 0 : 1)
		case a == "--help" || a == "-h":
			fmt.println("palmy vault -- an encrypted password manager")
			fmt.println("  --selftest        run the headless checks, including the published vectors")
			fmt.println("  --idle=<seconds>  idle time before the vault locks itself (default 300)")
			fmt.println("  --clip=<seconds>  how long a copied secret stays on the clipboard (default 20)")
			fmt.println("  --vault=<path>    use this vault file instead of the default")
			fmt.println("  --make-demo-vault=<path>")
			fmt.println("                    write the demo fixture (sample entries, public TOTP seed)")
			os.exit(0)
		}
	}

	if !ensure_dir() {
		fmt.eprintfln("vault: could not create %s", data_dir())
		os.exit(1)
	}
	if path == "" {
		path = strings.clone(default_vault_path(context.temp_allocator))
	}

	g = St {
		path       = path,
		screen     = os.exists(path) ? .Unlock : .Create,
		pw         = make([dynamic]u8),
		pw2        = make([dynamic]u8),
		query      = make([dynamic]u8),
		rows       = make([dynamic]int),
		mp_new     = make([dynamic]u8),
		mp_again   = make([dynamic]u8),
		gen        = GEN_DEFAULT,
		idle_limit = idle,
		clip_limit = clip,
		focus_pw   = true,
		have_clip  = clip_available(),
	}
	for f in Field {
		g.ed[f] = make([dynamic]u8)
	}

	app, err := kit.start(
		{
			title = "Vault",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 880,
			min_height = 520,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
	)
	if err != "" {
		fmt.eprintfln("vault: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_theme()

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		frame(ui, app, &g)
	}

	// Lock on exit. The loop has ended, the window is going away, and the key
	// and every plaintext string go with it.
	lock(&g, "")
	shutdown(&g)
}

// frame is the whole per-frame body, factored out so the headless self-test
// drives exactly the same code through palmy's offscreen renderer.
frame :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// Any input at all is a sign of life, which is what the idle timer is
	// measuring. A frame drawn because a timer ticked is not.
	if len(ui.input.keys) > 0 || len(p.typed_text(ui)) > 0 || ui.input.pressed != {} {
		st.last_input = ui.now
	}
	if st.last_input == 0 {
		st.last_input = ui.now
	}

	tick_timers(ui, st)
	keys(ui, app, st)
	build(ui, st)

	// The text fields consume their input during `build`, so a search typed
	// this frame only reaches `st.query` after the list has been laid out.
	// Refiltering again here means `st.rows` always describes the query as it
	// stands now rather than as it stood one frame ago.
	if st.screen == .Open {
		refilter(st)
	}

	// While a vault is open there are three things that must happen without
	// anybody touching the keyboard: the idle lock, the clipboard clear, and
	// the TOTP countdown. palmy has no timer and no way to wake the frame loop
	// from outside, so the loop has to keep running.
	if st.screen == .Open || st.busy != .None || st.clip_until > 0 {
		ui.animating = true
	}
	// An automatic lock is the one state change nobody is watching for, so
	// hold the frame loop open for a moment afterwards. Otherwise the window
	// repaints once and goes to sleep, and on a recording the last thing on
	// screen is the instant *before* it locked.
	if st.screen != .Open && st.lock_at > 0 && ui.now - st.lock_at < 3 {
		ui.animating = true
	}
	if st.toast != "" && ui.now > st.toast_t {
		delete(st.toast)
		st.toast = ""
	}
}

tick_timers :: proc(ui: ^p.Ctx, st: ^St) {
	// The deferred half-second of Argon2id. The frame that set `busy` has
	// already been painted, so the "Unlocking…" state is on screen before the
	// derivation blocks.
	switch st.busy {
	case .None:
	case .Unlocking:
		st.busy = .None
		do_unlock(st)
	case .Creating:
		st.busy = .None
		do_create(st)
	case .Rekeying:
		st.busy = .None
		do_rekey(st)
	}

	if st.clip_until > 0 && ui.now >= st.clip_until {
		clear_clipboard(st, "The clipboard has been cleared")
	}

	if st.screen == .Open && st.idle_limit > 0 && ui.now - st.last_input >= st.idle_limit {
		lock(st, fmt.tprintf("Locked after %.0f seconds idle", st.idle_limit), ui.now)
	}
}

// ---------------------------------------------------------------------------
// Unlocking, locking
// ---------------------------------------------------------------------------

set_err :: proc(st: ^St, msg: string) {
	if st.lock_err != "" {
		delete(st.lock_err)
	}
	st.lock_err = strings.clone(msg)
}

note :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	if st.toast != "" {
		delete(st.toast)
	}
	st.toast = strings.clone(msg)
	st.toast_t = (ui == nil ? 0 : ui.now) + 3.5
}

// wipe_buf zeroes a password buffer. A text field's backing store is where the
// master password sits while it is being typed, and clearing the length alone
// would leave the bytes behind it.
wipe_buf :: proc(b: ^[dynamic]u8) {
	if len(b) > 0 {
		for i in 0 ..< len(b) {
			b[i] = 0
		}
	}
	clear(b)
}

do_unlock :: proc(st: ^St) {
	pw := string(st.pw[:])
	t0 := time.now()
	v, sess, err := store_load(st.path, pw)
	ms := time.duration_milliseconds(time.since(t0))
	wipe_buf(&st.pw)
	if err != "" {
		set_err(st, err)
		return
	}
	st.derive_ms = ms
	st.v = v
	st.sess = sess
	vault_sort(&st.v)
	st.screen = .Open
	st.sel = 0
	set_err(st, "")
	if st.lock_note != "" {
		delete(st.lock_note)
		st.lock_note = ""
	}
}

do_create :: proc(st: ^St) {
	pw := string(st.pw[:])
	pw2 := string(st.pw2[:])
	if len(pw) < 8 {
		set_err(st, "A master password shorter than 8 characters is not worth encrypting anything with")
		return
	}
	if !secret_eq(pw, pw2) {
		set_err(st, "The two master passwords do not match")
		return
	}
	t0 := time.now()
	sess, err := store_create(st.path, pw)
	ms := time.duration_milliseconds(time.since(t0))
	wipe_buf(&st.pw)
	wipe_buf(&st.pw2)
	if err != "" {
		set_err(st, err)
		return
	}
	st.derive_ms = ms
	st.sess = sess
	st.v = Vault {
		entries = make([dynamic]Entry),
	}
	st.screen = .Open
	set_err(st, "")
	seed_examples(st)
}

// lock drops the key and every decrypted string. Everything the vault held is
// freed through `entry_free`, which zeroes the secret fields before releasing
// them rather than leaving them legible in a free block.
lock :: proc(st: ^St, reason: string, ui_now: f64 = 0) {
	if st.screen != .Open {
		return
	}
	if st.clip_until > 0 {
		clear_clipboard(st, "")
	}
	cancel_edit(st)
	if st.gen_pw != "" {
		wipe_string(st.gen_pw)
		st.gen_pw = ""
	}
	vault_free(&st.v)
	session_zero(&st.sess)
	wipe_buf(&st.pw)
	wipe_buf(&st.pw2)
	wipe_buf(&st.mp_new)
	wipe_buf(&st.mp_again)
	st.mp_open = false
	st.gen_open = false
	st.confirm_del = false
	st.history = false
	st.reveal = false
	st.sel = 0
	clear(&st.rows)
	clear(&st.query)
	if st.tag != "" {
		delete(st.tag)
		st.tag = ""
	}
	if st.lock_note != "" {
		delete(st.lock_note)
	}
	st.lock_note = strings.clone(reason)
	st.lock_at = ui_now
	st.focus_pw = true
	st.screen = os.exists(st.path) ? .Unlock : .Create
	set_err(st, "")
}

shutdown :: proc(st: ^St) {
	for f in Field {
		wipe_buf(&st.ed[f])
		delete(st.ed[f])
	}
	delete(st.pw)
	delete(st.pw2)
	delete(st.mp_new)
	delete(st.mp_again)
	delete(st.query)
	delete(st.rows)
	kit.pick_destroy(&st.pick)
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------

save :: proc(st: ^St, ui: ^p.Ctx) {
	if st.screen != .Open {
		return
	}
	if err := store_save(st.path, &st.v, &st.sess); err != "" {
		note(st, ui, err)
		return
	}
}

do_rekey :: proc(st: ^St) {
	new1 := string(st.mp_new[:])
	new2 := string(st.mp_again[:])
	if len(new1) < 8 {
		st.mp_err = "A master password shorter than 8 characters is not worth encrypting anything with"
		return
	}
	if !secret_eq(new1, new2) {
		st.mp_err = "The two new passwords do not match"
		return
	}
	fresh, err := store_rekey(st.path, &st.v, &st.sess, new1)
	wipe_buf(&st.mp_new)
	wipe_buf(&st.mp_again)
	if err != "" {
		// The old vault and the old key are both untouched.
		st.mp_err = err
		return
	}
	session_zero(&st.sess)
	st.sess = fresh
	st.mp_open = false
	st.mp_err = ""
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

copy_secret :: proc(st: ^St, ui: ^p.Ctx, label: string, value: string) {
	if value == "" {
		note(st, ui, "Nothing to copy")
		return
	}
	if !st.have_clip {
		note(st, ui, "wl-clipboard is not installed, so nothing was copied")
		return
	}
	if !clip_put(value) {
		note(st, ui, "wl-copy could not be started")
		return
	}
	if st.clip_value != "" {
		wipe_string(st.clip_value)
	}
	if st.clip_label != "" {
		delete(st.clip_label)
	}
	st.clip_value = clone_secret(value)
	st.clip_label = strings.clone(label)
	st.clip_total = st.clip_limit
	st.clip_until = (ui == nil ? 0 : ui.now) + st.clip_limit
}

clear_clipboard :: proc(st: ^St, msg: string) {
	// Only clear what is still ours. If something else has taken the
	// selection since, that belongs to whoever put it there.
	if st.clip_value != "" && clip_is(st.clip_value) {
		clip_clear()
	}
	if st.clip_value != "" {
		wipe_string(st.clip_value)
		st.clip_value = ""
	}
	if st.clip_label != "" {
		delete(st.clip_label)
		st.clip_label = ""
	}
	st.clip_until = 0
	if msg != "" {
		if st.toast != "" {
			delete(st.toast)
		}
		st.toast = strings.clone(msg)
		st.toast_t = 1e18 // replaced on the next frame that has a clock
	}
}

// ---------------------------------------------------------------------------
// Rows and selection
// ---------------------------------------------------------------------------

refilter :: proc(st: ^St) {
	clear(&st.rows)
	q := strings.to_lower(strings.trim_space(string(st.query[:])), context.temp_allocator)
	for &e, i in st.v.entries {
		if st.tag != "" {
			hit := false
			for t in e.tags {
				if t == st.tag {
					hit = true
					break
				}
			}
			if !hit {
				continue
			}
		}
		if !entry_matches(&e, q) {
			continue
		}
		append(&st.rows, i)
	}
	st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
}

current :: proc(st: ^St) -> ^Entry {
	if st.sel < 0 || st.sel >= len(st.rows) {
		return nil
	}
	return &st.v.entries[st.rows[st.sel]]
}

move_sel :: proc(st: ^St, d: int) {
	if len(st.rows) == 0 {
		return
	}
	st.sel = clamp(st.sel + d, 0, len(st.rows) - 1)
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

begin_edit :: proc(st: ^St, fresh: bool) {
	cancel_edit(st)
	st.editing = true
	st.ed_new = fresh
	if fresh {
		return
	}
	e := current(st)
	if e == nil {
		st.editing = false
		return
	}
	set_buf(&st.ed[.Title], e.title)
	set_buf(&st.ed[.Username], e.username)
	set_buf(&st.ed[.Password], e.password)
	set_buf(&st.ed[.Url], e.url)
	set_buf(&st.ed[.Tags], entry_tag_text(e, context.temp_allocator))
	set_buf(&st.ed[.Totp], e.totp)
	set_buf(&st.ed[.Notes], e.notes)
}

set_buf :: proc(b: ^[dynamic]u8, s: string) {
	wipe_buf(b)
	append(b, ..transmute([]u8)s)
}

cancel_edit :: proc(st: ^St) {
	st.editing = false
	st.ed_new = false
	for f in Field {
		wipe_buf(&st.ed[f])
	}
}

commit_edit :: proc(st: ^St, ui: ^p.Ctx) {
	title := strings.trim_space(string(st.ed[.Title][:]))
	if title == "" {
		note(st, ui, "An entry needs a title")
		return
	}
	totp := strings.trim_space(string(st.ed[.Totp][:]))
	if !totp_secret_ok(totp) {
		note(st, ui, "That TOTP secret is not valid base32, so it was not saved")
		return
	}

	idx := -1
	if st.ed_new {
		append(&st.v.entries, entry_new(title))
		idx = len(st.v.entries) - 1
	} else {
		e := current(st)
		if e == nil {
			cancel_edit(st)
			return
		}
		for &c, i in st.v.entries {
			if &c == e {
				idx = i
				break
			}
		}
	}
	if idx < 0 {
		cancel_edit(st)
		return
	}

	e := &st.v.entries[idx]
	replace_string(&e.title, title)
	replace_string(&e.username, strings.trim_space(string(st.ed[.Username][:])))
	replace_string(&e.url, strings.trim_space(string(st.ed[.Url][:])))
	replace_secret(&e.notes, string(st.ed[.Notes][:]))
	entry_set_tags(e, string(st.ed[.Tags][:]))
	replace_secret(&e.totp, totp)
	entry_set_password(e, string(st.ed[.Password][:]))
	e.modified = now_unix()

	keep := e.created
	vault_sort(&st.v)
	cancel_edit(st)
	save(st, ui)
	refilter(st)
	// Keep the entry you just edited selected, wherever the sort put it.
	for r, i in st.rows {
		if st.v.entries[r].created == keep && st.v.entries[r].title == title {
			st.sel = i
			break
		}
	}
	note(st, ui, "Saved")
}

replace_string :: proc(dst: ^string, s: string) {
	delete(dst^)
	dst^ = strings.clone(s)
}

replace_secret :: proc(dst: ^string, s: string) {
	wipe_string(dst^)
	dst^ = strings.clone(s)
}

delete_current :: proc(st: ^St, ui: ^p.Ctx) {
	e := current(st)
	if e == nil {
		return
	}
	idx := st.rows[st.sel]
	entry_free(&st.v.entries[idx])
	ordered_remove(&st.v.entries, idx)
	st.confirm_del = false
	save(st, ui)
	refilter(st)
	note(st, ui, "Entry deleted")
}

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

// open_generator takes the keyboard away from whatever text field had it. The
// generator's shortcuts are bare keys -- Space redraws, 1 to 4 toggle a class
// -- and with the search field still focused they would be typed into it
// instead of acting.
open_generator :: proc(ui: ^p.Ctx, st: ^St) {
	st.gen_open = true
	regenerate(st)
	p.set_focus(ui, 0)
}

regenerate :: proc(st: ^St) {
	pw, ok := gen_password(st.gen)
	if !ok {
		return
	}
	if st.gen_pw != "" {
		wipe_string(st.gen_pw)
	}
	st.gen_pw = pw
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if kit.pick_active(&st.pick) {
		return // the dialog owns the keyboard while it is up
	}

	if p.shortcut(ui, 'q', {.Ctrl}) {
		if app != nil {
			p.quit_app(app)
		}
		return
	}

	if st.screen != .Open {
		// Enter submits whichever lock screen is showing. The text fields
		// report `submitted` too; this covers Enter with the button focused.
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			begin_lock_action(st)
		}
		if p.shortcut(ui, 'o', {.Ctrl}) {
			begin_pick(st, .Open_Vault)
		}
		return
	}

	// Modal dialogs first.
	if st.confirm_del {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'n') {
			st.confirm_del = false
		} else if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, 'y') {
			delete_current(st, ui)
		}
		return
	}
	if st.mp_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			wipe_buf(&st.mp_new)
			wipe_buf(&st.mp_again)
			st.mp_open = false
			st.mp_err = ""
		} else if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			st.busy = .Rekeying
		}
		return
	}

	if p.shortcut(ui, 'l', {.Ctrl}) {
		lock(st, "Locked", ui.now)
		return
	}

	if st.gen_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			st.gen_open = false
			return
		}
		if p.shortcut(ui, 'g', {.Ctrl}) || p.key_pressed(ui, p.KEY_SPACE) {
			regenerate(st)
			return
		}
		if n := p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT); n != 0 {
			st.gen.length = clamp(st.gen.length + n, GEN_MIN_LEN, GEN_MAX_LEN)
			regenerate(st)
			return
		}
		for c, i in Class {
			if p.key_pressed(ui, u32('1') + u32(i)) {
				if c in st.gen.classes {
					// Never leave the alphabet empty.
					if card(st.gen.classes) > 1 {
						st.gen.classes -= {c}
					}
				} else {
					st.gen.classes += {c}
				}
				regenerate(st)
				return
			}
		}
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			// Enter is "take this one and let me get on with it", so it
			// closes the generator either way.
			if st.editing {
				set_buf(&st.ed[.Password], st.gen_pw)
				note(st, ui, "Generated password put in the editor")
			} else {
				copy_secret(st, ui, "generated password", st.gen_pw)
			}
			st.gen_open = false
			return
		}
		if p.shortcut(ui, 'c', {.Ctrl}) {
			copy_secret(st, ui, "generated password", st.gen_pw)
			return
		}
		return
	}

	if st.editing {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			cancel_edit(st)
			return
		}
		if p.shortcut(ui, 's', {.Ctrl}) {
			commit_edit(st, ui)
			return
		}
		if p.shortcut(ui, 'g', {.Ctrl}) {
			open_generator(ui, st)
			return
		}
		if p.shortcut(ui, 'r', {.Ctrl}) {
			st.reveal = !st.reveal
			return
		}
		return
	}

	// Browsing.
	if p.shortcut(ui, 'f', {.Ctrl}) {
		p.set_focus(ui, st.query_id)
		return
	}
	if p.shortcut(ui, 'n', {.Ctrl}) {
		begin_edit(st, true)
		return
	}
	if p.shortcut(ui, 'g', {.Ctrl}) {
		open_generator(ui, st)
		return
	}
	if p.shortcut(ui, 'm', {.Ctrl}) {
		st.mp_open = true
		st.mp_err = ""
		st.focus_mp = true
		p.set_focus(ui, 0)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(st, .Open_Vault)
		return
	}
	if p.shortcut(ui, 'r', {.Ctrl}) {
		st.reveal = !st.reveal
		return
	}
	if p.shortcut(ui, 'h', {.Ctrl}) {
		st.history = !st.history
		return
	}
	if p.shortcut(ui, 'e', {.Ctrl}) {
		begin_edit(st, false)
		return
	}
	if e := current(st); e != nil {
		if p.shortcut(ui, 'c', {.Ctrl}) {
			copy_secret(st, ui, fmt.tprintf("password for %s", e.title), e.password)
			return
		}
		if p.shortcut(ui, 'b', {.Ctrl}) {
			copy_secret(st, ui, fmt.tprintf("username for %s", e.title), e.username)
			return
		}
		if p.shortcut(ui, 't', {.Ctrl}) {
			if code, ok := totp_code(e.totp, now_unix(), e.totp_period, int(e.totp_digits), e.totp_algo); ok {
				copy_secret(st, ui, fmt.tprintf("TOTP code for %s", e.title), code)
			} else {
				note(st, ui, "That entry has no TOTP secret")
			}
			return
		}
		if p.key_pressed(ui, p.KEY_DELETE, false) {
			st.confirm_del = true
			p.set_focus(ui, 0)
			return
		}
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(st.query) > 0 {
			clear(&st.query)
			refilter(st)
		} else if st.tag != "" {
			delete(st.tag)
			st.tag = ""
			refilter(st)
		}
		return
	}
	if d := p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP); d != 0 {
		move_sel(st, d)
		return
	}
	if d := p.key_count(ui, p.KEY_PAGE_DOWN) - p.key_count(ui, p.KEY_PAGE_UP); d != 0 {
		move_sel(st, d * 8)
		return
	}
}

begin_lock_action :: proc(st: ^St) {
	switch st.screen {
	case .Unlock:
		if len(st.pw) == 0 {
			set_err(st, "Enter the master password")
			return
		}
		st.busy = .Unlocking
		set_err(st, "")
	case .Create:
		st.busy = .Creating
		set_err(st, "")
	case .Open:
	}
}

// ---------------------------------------------------------------------------
// Picking a different vault
// ---------------------------------------------------------------------------

VAULT_FILTERS := [?]kit.Pick_Filter{{"palmy vaults", {VAULT_EXT}}, kit.PICK_ALL}

begin_pick :: proc(st: ^St, use: Pick_Use) {
	st.pick_use = use
	kit.pick_begin(
		&st.pick,
		.Open_File,
		{
			title = "Open a Vault",
			dir = data_dir(context.temp_allocator),
			filters = VAULT_FILTERS[:],
			confirm = "Open",
		},
	)
}

// pick_overlay is the only path by which this app ever opens a file the user
// did not already have it create. It checks the magic before switching, so
// pointing it at an unrelated file says so instead of asking for a password
// that could never work.
pick_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	if !kit.pick_active(&st.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &st.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := st.pick_use
	st.pick_use = .None
	if !res.ok || use != .Open_Vault {
		return
	}
	if !vault_looks_like_one(res.path) {
		note(st, ui, fmt.tprintf("%s is not a palmy vault", kit.pick_base(res.path)))
		return
	}
	lock(st, "")
	delete(st.path)
	st.path = strings.clone(res.path)
	st.screen = .Unlock
	note(st, ui, fmt.tprintf("Opening %s", short_path(st.path)))
}

// ---------------------------------------------------------------------------
// A first-run vault with obviously fake contents
//
// Every password here was produced by this app's own generator at startup, and
// every TOTP seed is the one printed in RFC 6238. Nothing in a new vault is a
// real credential, and the demo recording shows only these.
// ---------------------------------------------------------------------------

// DEMO_PASSWORD is the master password of the recorded demo's vault, and is
// therefore not a secret. It exists so that `--make-demo-vault` and the demo
// script agree, and so that nobody is tempted to film a real one.
DEMO_PASSWORD :: "demo-vault-not-a-real-password"

make_demo_vault :: proc(path: string) -> bool {
	if os.exists(path) {
		if err := os.remove(path); err != nil {
			fmt.eprintfln("vault: could not replace %s", path)
			return false
		}
	}
	// A cheap KDF would be dishonest in a demo about a memory-hard one, so
	// this is the real default: the recording shows the half second it costs.
	sess, err := store_create(path, DEMO_PASSWORD)
	if err != "" {
		fmt.eprintfln("vault: %s", err)
		return false
	}
	defer session_zero(&sess)
	st := St {
		path = path,
		sess = sess,
		v    = Vault{entries = make([dynamic]Entry)},
	}
	defer vault_free(&st.v)
	seed_examples(&st)
	fmt.printfln("wrote the demo vault to %s with %d sample entries", path, len(st.v.entries))
	return true
}

seed_examples :: proc(st: ^St) {
	add :: proc(st: ^St, title, user, url, tags, totp, notes: string) {
		e := entry_new(title)
		replace_string(&e.username, user)
		replace_string(&e.url, url)
		replace_secret(&e.notes, notes)
		entry_set_tags(&e, tags)
		replace_secret(&e.totp, totp)
		pw, _ := gen_password(GEN_DEFAULT, context.temp_allocator)
		entry_set_password(&e, pw)
		append(&st.v.entries, e)
	}
	// base32("12345678901234567890"), the RFC 6238 seed. Deliberately public.
	seed := base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator)
	add(st, "Example Mail", "sample.user@example.com", "https://mail.example.com", "email, sample", seed, "Sample entry. The password was generated just now.")
	add(st, "Example Bank", "sample-00417", "https://bank.example.org", "finance, sample", "", "Sample entry, not a real account.")
	add(st, "Example Forge", "sample-dev", "https://forge.example.net", "work, sample", seed, "Sample entry. The TOTP seed is the public one from RFC 6238.")
	add(st, "Example Router", "admin", "http://192.0.2.1", "home, sample", "", "192.0.2.0/24 is the documentation range: this is not a device.")
	vault_sort(&st.v)
	store_save(st.path, &st.v, &st.sess)
}
