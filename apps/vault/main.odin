package main

// palmy vault -- a password manager.
//
// Two vaults behind one window. On a device that is not enrolled in a
// Palmy account it is what it always was: one encrypted file, no network
// code reachable from the window, no sync. On an enrolled device it is the
// account vault: every identity's vaults, end-to-end encrypted, synced item by
// item, shared deliberately between identities (cloud/docs/vault.md). Both go
// through book.odin, the engine the command line uses too.
//
// The crypto is in seal.odin (the file) and keys.odin (the account); the
// records in model.odin; sync in cloud.odin and sync.odin. This file is
// responsible for never letting the key or a plaintext live longer than it
// has to, and for the three timers that must fire without anyone touching
// the keyboard: the idle lock, the clipboard clear, and the TOTP countdown.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

WIN_W :: 1280
WIN_H :: 800

// Defaults, both overridable on the command line so the recorded demo can show
// them firing inside a short take.
IDLE_LOCK_DEFAULT :: 300.0 // seconds of no input before the key is dropped
CLIP_CLEAR_DEFAULT :: 20.0 // seconds a copied secret stays on the clipboard
SYNC_EVERY :: 60.0 // seconds between background syncs while unlocked

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

// The labelled fields each kind of item offers in the editor, beyond the
// common ones. A `*` marks a secret: masked, wiped, never in search.
KIND_FIELDS := [Item_Kind][]string {
	.Login    = {},
	.Passkey  = {},
	.Card     = {"Cardholder", "Number*", "Expiry", "Security code*", "PIN*"},
	.Note     = {},
	.Document = {"Document", "Number*", "Full name", "Issued by", "Expires"},
	.Totp     = {},
}

Busy :: enum u8 {
	None,
	Unlocking,
	Creating,
	Rekeying,
	Syncing,
}

Pick_Use :: enum u8 {
	None,
	Open_Vault,
	Import,
}

// What the sidebar has selected, which decides what the list shows.
Nav_Kind :: enum u8 {
	All,
	Favorites,
	Kind,
	Tag,
	Source, // one vault (account mode), or "Shared with me"
	Health,
}

Nav :: struct {
	kind:  Nav_Kind,
	ikind: Item_Kind,
	src:   int,
}

Kv_Buf :: struct {
	label:  string,
	buf:    [dynamic]u8,
	secret: bool,
}

St :: struct {
	using bk:   Book,
	screen:     Screen,
	dark:       bool,

	// Lock screen
	pw:         [dynamic]u8,
	pw2:        [dynamic]u8,
	lock_err:   string,
	busy:       Busy,
	derive_ms:  f64,
	pw_id:      u64,
	pw2_id:     u64,
	// The Notes text area, so a shortcut or the self-test can focus it.
	notes_id:   u64,

	// List
	query:      [dynamic]u8,
	query_id:   u64,
	tag:        string,
	nav:        Nav,
	sel:        int,
	rows:       [dynamic]int,

	// Detail
	editing:    bool,
	ed_new:     bool,
	ed:         [Field][dynamic]u8,
	ed_kind:    Item_Kind,
	ed_kv:      [dynamic]Kv_Buf,
	ed_target:  int, // the source a new item goes into (account mode)
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

	// Sharing (account mode)
	share_open: bool,
	share_with: [dynamic]u8,
	share_role: string,
	share_err:  string,
	share_id:   u64,

	// Health
	health:     Health,
	health_ok:  bool,
	breach_on:  bool, // the person allowed the breach check (off by default)
	breach_msg: string,

	// Import
	imp:        Import_Result,
	imp_open:   bool,
	imp_path:   string,
	imp_target: int,

	// Autofill
	af:         Af_Server,
	af_on:      bool,

	// Sync
	sync_msg:   string,
	sync_at:    f64,
	sync_pend:  int,

	// Clipboard
	clip_label: string,
	clip_value: string,
	clip_until: f64,
	clip_total: f64,

	// Auto-lock. Every time here is on `clock`, in seconds.
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
	totp_shown: bool, // a TOTP countdown was drawn this frame
	have_clip:  bool,

	pick:       kit.Pick,
	pick_use:   Pick_Use,
}

g: St

is_gui_flag :: proc(a: string) -> bool {
	for pfx in ([?]string{"--idle=", "--clip=", "--vault=", "--shot", "--make-demo-vault=", "--local", "--theme=", "--no-autofill"}) {
		if strings.has_prefix(a, pfx) {
			return true
		}
	}
	return false
}

main :: proc() {
	idle := f64(IDLE_LOCK_DEFAULT)
	clip := f64(CLIP_CLEAR_DEFAULT)
	path := ""
	force_local := false
	autofill := true
	dark := os.get_env("PALM_THEME", context.temp_allocator) == "dark"

	// The command line first (cli.odin). The window's own flags (--idle=,
	// --shot, ...) are not verbs, so they skip straight past it.
	if len(os.args) > 1 && !is_gui_flag(os.args[1]) {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
	}

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
			force_local = true
		case a == "--local":
			force_local = true
		case a == "--no-autofill":
			autofill = false
		case a == "--theme=dark":
			dark = true
		case a == "--theme=light":
			dark = false
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
		}
	}

	if !ensure_dir() {
		dir, why := data_dir_explained()
		fmt.eprintfln("vault: could not create %s (chosen by %s)", dir, why)
		os.exit(1)
	}
	if path == "" {
		path = strings.clone(default_vault_path(context.temp_allocator))
	}

	g = st_new(path)
	g.idle_limit = idle
	g.clip_limit = clip
	g.dark = dark
	if !force_local {
		g.acct = acct_open()
		if !acct_set_up(g.acct) {
			acct_close(g.acct)
			g.acct = nil
		}
	}
	g.mode = book_mode_for(force_local, g.acct)
	g.scope = os.get_env("PALM_IDENTITY", context.allocator)
	g.screen = book_exists(&g.bk) ? .Unlock : .Create
	g.have_clip = true
	g.af_on = autofill

	app, err := kit.start(
		{
			title = "Vault",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 960,
			min_height = 560,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
		dark,
	)
	if err != "" {
		fmt.eprintfln("vault: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_theme(dark)
	g.have_clip = clip_available()
	g_trace = os.get_env("VAULT_TRACE_TIMERS", context.temp_allocator) == "1"

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		frame(ui, app, &g)
	}

	// Lock on exit. The loop has ended, the window is going away, and the key
	// and every plaintext string go with it.
	lock(&g, "")
	shutdown(&g)
}

st_new :: proc(path: string) -> St {
	st := St {
		bk         = Book{path = path},
		pw         = make([dynamic]u8),
		pw2        = make([dynamic]u8),
		query      = make([dynamic]u8),
		rows       = make([dynamic]int),
		mp_new     = make([dynamic]u8),
		mp_again   = make([dynamic]u8),
		share_with = make([dynamic]u8),
		ed_kv      = make([dynamic]Kv_Buf),
		gen        = GEN_DEFAULT,
		idle_limit = IDLE_LOCK_DEFAULT,
		clip_limit = CLIP_CLEAR_DEFAULT,
		focus_pw   = true,
		share_role = "read",
	}
	for f in Field {
		st.ed[f] = make([dynamic]u8)
	}
	return st
}

// frame is the whole per-frame body, factored out so the headless self-test
// drives exactly the same code through palmy's offscreen renderer.
frame :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// Any input at all is a sign of life, which is what the idle timer is
	// measuring. A frame drawn because a timer ticked is not.
	now := clock(ui)
	if len(ui.input.keys) > 0 || len(p.typed_text(ui)) > 0 || ui.input.pressed != {} {
		st.last_input = now
	}
	if st.last_input == 0 {
		st.last_input = now
	}
	st.totp_shown = false // set again by the TOTP card if it is drawn

	tick_timers(ui, st)
	autofill_tick(ui, st)
	keys(ui, app, st)
	build(ui, st)

	// The text fields consume their input during `build`, so a search typed
	// this frame only reaches `st.query` after the list has been laid out.
	// Refiltering again here means `st.rows` always describes the query as it
	// stands now rather than as it stood one frame ago.
	if st.screen == .Open {
		refilter(st)
	}

	if st.toast != "" && clock(ui) >= st.toast_t {
		delete(st.toast)
		st.toast = ""
	}

	schedule(ui, app, st)
}

// ---------------------------------------------------------------------------
// Timers
//
// Three things must happen while nobody touches the keyboard: the idle lock,
// the clipboard clear and the TOTP countdown. The first two are security
// timers. They used to be served by holding the frame loop at the display
// rate for as long as a vault was open -- a third of a core, all day -- on
// the belief that palmy had no way to wake the loop from outside. It has:
// `wake_after` parks the loop until a deadline and runs exactly one frame
// then. So every frame ends by working out the next instant anything here is
// due and arming the loop for it, and between those instants the window costs
// nothing.
//
// The deadlines are kept on `clock`, a real monotonic clock. `ui.now` cannot
// be used: palmy clamps each frame's `dt` to 0.1 s so an animation does not
// jump after a stall, which means `ui.now` only advances 0.1 s per frame. With
// the loop asleep between frames, a 300-second idle limit measured on it
// would take thousands of seconds -- the lock would effectively never fire.
// ---------------------------------------------------------------------------

// clock is the time, in seconds, that every timer in this file is kept on: a
// monotonic clock in a live window (the wall clock can be stepped, and must
// not move a deadline), and the renderer's synthetic time offscreen, so the
// self-test can step through a 300-second limit in a handful of frames.
clock :: proc(ui: ^p.Ctx) -> f64 {
	if ui == nil {
		return 0
	}
	if ui.app == nil {
		return ui.now
	}
	return time.duration_seconds(time.tick_diff(time.Tick{}, time.tick_now()))
}

// NEVER is the answer `next_due` gives when nothing is waiting.
NEVER :: max(f64)

// next_due is the next instant, on `clock`, at which a frame has something to
// do: a timer fires, or a countdown on screen shows a different number.
// Separate from `schedule` so the self-test can check it without a window.
next_due :: proc(st: ^St, now: f64) -> f64 {
	due := NEVER
	// The next instant a countdown of `left` seconds, shown rounded up,
	// changes its number.
	next_digit :: proc(now, left: f64) -> f64 {
		if left <= 0 {
			return now
		}
		frac := left - f64(i64(left))
		if frac <= 0 {
			frac = 1
		}
		return now + frac
	}

	if st.clip_until > 0 {
		due = min(due, st.clip_until, next_digit(now, st.clip_until - now))
	}
	if st.screen == .Open && st.idle_limit > 0 {
		at := st.last_input + st.idle_limit
		due = min(due, at)
		// The "locks in Ns" chip appears for the last 30 seconds and counts.
		show := at - min(30.0, st.idle_limit)
		if now >= show {
			due = min(due, next_digit(now, at - now))
		} else {
			due = min(due, show)
		}
	}
	if st.screen == .Open && st.mode == .Account && st.sync_at > 0 && !g_test {
		due = min(due, st.sync_at + SYNC_EVERY)
	}
	if st.toast != "" && st.toast_t < 1e17 {
		due = min(due, st.toast_t)
	}
	return due
}

// schedule arms the frame loop for whatever is due next and lets it sleep
// until then.
schedule :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// Work deferred to the next frame -- the Argon2id derivation, a sync --
	// needs exactly that one frame.
	if st.busy != .None {
		p.wake(ui)
	}
	// An autofill request queued behind a prompt that was answered this
	// frame is served on the next one.
	if st.af.running && len(st.af.queue) > 0 && st.af.prompt.kind == .None {
		p.wake(ui)
	}
	// The autofill socket used to be read only because the loop was spinning.
	// Now a thread sleeps on it and wakes the loop when a client writes.
	if st.af.running && !st.af.watching && app != nil {
		af_watch(&st.af, app)
	}

	now := clock(ui)
	if due := next_due(st, now); due != NEVER {
		// A millisecond past the deadline, so the frame it buys is never the
		// one just before it.
		p.wake_after(ui, time.Duration((max(due - now, 0) + 0.001) * f64(time.Second)))
	}
	// The TOTP code and its countdown follow the wall clock, as the server
	// that checks them does, so the next second is a wall-clock second.
	if st.totp_shown {
		ns := i64(time.Second) - time.time_to_unix_nano(time.now()) % i64(time.Second)
		p.wake_after(ui, time.Duration(ns) + 2 * time.Millisecond)
	}
}

// VAULT_TRACE_TIMERS=1 prints, to stderr, each security timer as it fires:
// when it was due, when it ran, and how late. It is how the claim "the lock
// fires on time with the window idle" was measured, and it prints nothing
// secret -- no titles, no values.
g_trace: bool

timer_trace :: proc(what: string, due, now: f64) {
	if !g_trace {
		return
	}
	fmt.eprintfln(
		"vault-timer: %s  wall=%v  due=%.3f  ran=%.3f  late=%.1fms",
		what,
		time.now(),
		due,
		now,
		(now - due) * 1000,
	)
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
		if st.screen == .Open && st.mode == .Account {
			st.busy = .Syncing
		}
	case .Creating:
		st.busy = .None
		do_create(st)
	case .Rekeying:
		st.busy = .None
		do_rekey(st)
	case .Syncing:
		st.busy = .None
		do_sync(st, ui)
	}

	now := clock(ui)
	if st.clip_until > 0 && now >= st.clip_until {
		timer_trace("clipboard clear", st.clip_until, now)
		clear_clipboard(st, "The clipboard has been cleared")
	}

	if st.screen == .Open && st.idle_limit > 0 && now - st.last_input >= st.idle_limit {
		timer_trace("idle lock", st.last_input + st.idle_limit, now)
		lock(st, fmt.tprintf("Locked after %.0f seconds idle", st.idle_limit), now)
	}

	if st.screen == .Open && st.mode == .Account && st.busy == .None && st.sync_at > 0 && now - st.sync_at >= SYNC_EVERY && !g_test {
		st.busy = .Syncing
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
	st.toast_t = clock(ui) + 3.5
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
	err := book_unlock(&st.bk, pw)
	ms := time.duration_milliseconds(time.since(t0))
	wipe_buf(&st.pw)
	if err != "" {
		set_err(st, err)
		return
	}
	st.derive_ms = ms
	st.screen = .Open
	st.sel = 0
	st.nav = {}
	st.ed_target = book_default_target(&st.bk)
	set_err(st, "")
	if st.lock_note != "" {
		delete(st.lock_note)
		st.lock_note = ""
	}
	st.health_ok = false
	if st.af_on && !st.af.running && !g_test {
		if aerr := af_start(&st.af); aerr != "" {
			fmt.eprintfln("vault: autofill socket: %s", aerr)
		}
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
	st.mode = .Local
	st.derive_ms = ms
	st.sess = sess
	st.v = Vault {
		entries = make([dynamic]Entry),
	}
	st.screen = .Open
	set_err(st, "")
	seed_examples(st)
}

do_sync :: proc(st: ^St, ui: ^p.Ctx) {
	if st.mode != .Account || st.screen != .Open {
		return
	}
	keep := ""
	if e := current(st); e != nil {
		keep = strings.clone(e.id, context.temp_allocator)
	}
	rep, err := book_sync(&st.bk)
	if st.sync_msg != "" {
		delete(st.sync_msg)
	}
	switch {
	case err != "":
		st.sync_msg = fmt.aprintf("offline · %d waiting", len(st.acct.cache.pending))
	case rep.merged > 0:
		st.sync_msg = fmt.aprintf("synced %s · merged %d", clock_text(now_unix()), rep.merged)
	case:
		st.sync_msg = fmt.aprintf("synced %s", clock_text(now_unix()))
	}
	st.sync_at = ui != nil ? clock(ui) : 1
	st.health_ok = false
	refilter(st)
	select_id(st, keep)
}

clock_text :: proc(t: i64) -> string {
	h, m, _ := time.clock_from_time(time.unix(t, 0))
	return fmt.tprintf("%02d:%02d", h, m)
}

select_id :: proc(st: ^St, id: string) {
	if id == "" {
		return
	}
	for r, i in st.rows {
		if st.v.entries[r].id == id {
			st.sel = i
			return
		}
	}
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
	// A prompt waiting for an answer is answered "no".
	if st.af.prompt.kind != .None {
		af_decide(&st.af, &st.bk, .Deny)
	}
	book_lock(&st.bk)
	health_free(&st.health)
	st.health_ok = false
	if st.imp_open {
		import_result_free(&st.imp)
		st.imp_open = false
	}
	wipe_buf(&st.pw)
	wipe_buf(&st.pw2)
	wipe_buf(&st.mp_new)
	wipe_buf(&st.mp_again)
	st.mp_open = false
	st.gen_open = false
	st.share_open = false
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
	st.screen = book_exists(&st.bk) ? .Unlock : .Create
	set_err(st, "")
}

shutdown :: proc(st: ^St) {
	for f in Field {
		wipe_buf(&st.ed[f])
		delete(st.ed[f])
	}
	kv_bufs_clear(st)
	delete(st.ed_kv)
	delete(st.pw)
	delete(st.pw2)
	delete(st.mp_new)
	delete(st.mp_again)
	delete(st.share_with)
	delete(st.query)
	delete(st.rows)
	if st.af.running || st.af.pairs_path != "" {
		af_stop(&st.af)
	}
	kit.pick_destroy(&st.pick)
	if st.acct != nil {
		acct_close(st.acct)
		st.acct = nil
	}
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------

save_entry :: proc(st: ^St, ui: ^p.Ctx, idx: int) {
	if st.screen != .Open {
		return
	}
	if err := book_commit(&st.bk, idx); err != "" {
		note(st, ui, err)
	}
	st.health_ok = false
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
	if st.mode == .Account {
		err := acct_change_password(st.acct, new1)
		wipe_buf(&st.mp_new)
		wipe_buf(&st.mp_again)
		if err != "" {
			st.mp_err = err
			return
		}
		st.mp_open = false
		st.mp_err = ""
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
		note(st, ui, "There is no clipboard to copy to")
		return
	}
	if !clip_put(value) {
		note(st, ui, "The clipboard refused the copy")
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
	st.clip_until = clock(ui) + st.clip_limit
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

entry_in_nav :: proc(st: ^St, e: ^Entry) -> bool {
	switch st.nav.kind {
	case .All:
	case .Favorites:
		return e.favorite
	case .Kind:
		return e.kind == st.nav.ikind
	case .Tag:
		for t in e.tags {
			if t == st.tag {
				return true
			}
		}
		return false
	case .Source:
		return e.src == st.nav.src
	case .Health:
		if !st.health_ok {
			return true
		}
		for f in st.health.findings {
			if &st.v.entries[f.entry] == e {
				return true
			}
		}
		return false
	}
	return true
}

refilter :: proc(st: ^St) {
	clear(&st.rows)
	if st.nav.kind == .Health && !st.health_ok {
		health_refresh(st)
	}
	q := strings.to_lower(strings.trim_space(string(st.query[:])), context.temp_allocator)
	for &e, i in st.v.entries {
		if !entry_in_nav(st, &e) {
			continue
		}
		if !entry_matches(&e, q) {
			continue
		}
		append(&st.rows, i)
	}
	st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
}

health_refresh :: proc(st: ^St) {
	health_free(&st.health)
	st.health = health_check(&st.v)
	st.health_ok = true
}

current :: proc(st: ^St) -> ^Entry {
	if st.sel < 0 || st.sel >= len(st.rows) {
		return nil
	}
	return &st.v.entries[st.rows[st.sel]]
}

current_index :: proc(st: ^St) -> int {
	if st.sel < 0 || st.sel >= len(st.rows) {
		return -1
	}
	return st.rows[st.sel]
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

kv_bufs_clear :: proc(st: ^St) {
	for &k in st.ed_kv {
		wipe_buf(&k.buf)
		delete(k.buf)
		delete(k.label)
	}
	clear(&st.ed_kv)
}

// kv_bufs_for lays out the kind's template fields, then any other fields the
// entry already carries, so editing never drops a field the template lacks.
kv_bufs_for :: proc(st: ^St, kind: Item_Kind, e: ^Entry) {
	kv_bufs_clear(st)
	for t in KIND_FIELDS[kind] {
		secret := strings.has_suffix(t, "*")
		label := strings.trim_suffix(t, "*")
		b := Kv_Buf{label = strings.clone(label), buf = make([dynamic]u8), secret = secret}
		if e != nil {
			append(&b.buf, ..transmute([]u8)field_get(e, label))
		}
		append(&st.ed_kv, b)
	}
	if e == nil {
		return
	}
	for f in e.fields {
		have := false
		for k in st.ed_kv {
			if k.label == f.label {
				have = true
			}
		}
		if !have {
			b := Kv_Buf{label = strings.clone(f.label), buf = make([dynamic]u8), secret = f.secret}
			append(&b.buf, ..transmute([]u8)f.value)
			append(&st.ed_kv, b)
		}
	}
}

begin_edit :: proc(st: ^St, fresh: bool, kind := Item_Kind.Login) {
	cancel_edit(st)
	st.editing = true
	st.ed_new = fresh
	if fresh {
		st.ed_kind = kind
		kv_bufs_for(st, kind, nil)
		if st.nav.kind == .Source && st.mode == .Account {
			if s := st.nav.src; s >= 0 && s < len(st.acct.sources) && (st.acct.sources[s].role != "read") {
				st.ed_target = s
			}
		}
		return
	}
	e := current(st)
	if e == nil {
		st.editing = false
		return
	}
	if !book_writable(&st.bk, e) {
		st.editing = false
		return
	}
	st.ed_kind = e.kind
	set_buf(&st.ed[.Title], e.title)
	set_buf(&st.ed[.Username], e.username)
	set_buf(&st.ed[.Password], e.password)
	set_buf(&st.ed[.Url], e.url)
	set_buf(&st.ed[.Tags], entry_tag_text(e, context.temp_allocator))
	set_buf(&st.ed[.Totp], e.totp)
	set_buf(&st.ed[.Notes], e.notes)
	kv_bufs_for(st, e.kind, e)
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
	kv_bufs_clear(st)
}

commit_edit :: proc(st: ^St, ui: ^p.Ctx) {
	title := strings.trim_space(string(st.ed[.Title][:]))
	if title == "" {
		note(st, ui, "An item needs a title")
		return
	}
	totp := strings.trim_space(string(st.ed[.Totp][:]))
	if !totp_secret_ok(totp) {
		note(st, ui, "That TOTP secret is not valid base32, so it was not saved")
		return
	}

	e: ^Entry
	fresh: Entry
	if st.ed_new {
		fresh = entry_new(title)
		e = &fresh
	} else {
		e = current(st)
		if e == nil {
			cancel_edit(st)
			return
		}
	}
	e.kind = st.ed_kind
	replace_string(&e.title, title)
	replace_string(&e.username, strings.trim_space(string(st.ed[.Username][:])))
	replace_string(&e.url, strings.trim_space(string(st.ed[.Url][:])))
	replace_secret(&e.notes, string(st.ed[.Notes][:]))
	entry_set_tags(e, string(st.ed[.Tags][:]))
	replace_secret(&e.totp, totp)
	entry_set_password(e, string(st.ed[.Password][:]))
	for k in st.ed_kv {
		v := strings.trim_space(string(k.buf[:]))
		if v == "" && field_get(e, k.label) == "" {
			continue
		}
		field_set(e, k.label, v, k.secret)
	}
	e.modified = now_unix()
	id := strings.clone(e.id, context.temp_allocator)

	err := ""
	if st.ed_new {
		_, err = book_add(&st.bk, fresh, st.ed_target)
	} else {
		err = book_commit(&st.bk, current_index(st))
	}
	cancel_edit(st)
	if err != "" {
		note(st, ui, err)
		return
	}
	vault_sort(&st.v)
	st.health_ok = false
	refilter(st)
	select_id(st, id)
	note(st, ui, st.mode == .Account ? "Saved · encrypted on this device" : "Saved")
	if st.mode == .Account {
		st.busy = .Syncing
	}
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
	idx := current_index(st)
	if idx < 0 {
		return
	}
	st.confirm_del = false
	if !book_writable(&st.bk, &st.v.entries[idx]) {
		note(st, ui, "This item is shared with you read-only")
		return
	}
	if err := book_remove(&st.bk, idx); err != "" {
		note(st, ui, err)
		return
	}
	st.health_ok = false
	refilter(st)
	note(st, ui, "Item deleted")
	if st.mode == .Account {
		st.busy = .Syncing
	}
}

toggle_favorite :: proc(st: ^St, ui: ^p.Ctx) {
	idx := current_index(st)
	if idx < 0 || !book_writable(&st.bk, &st.v.entries[idx]) {
		return
	}
	st.v.entries[idx].favorite = !st.v.entries[idx].favorite
	save_entry(st, ui, idx)
}

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

do_share :: proc(st: ^St, ui: ^p.Ctx) {
	e := current(st)
	who := strings.trim_space(string(st.share_with[:]))
	if e == nil || who == "" || st.mode != .Account {
		return
	}
	id := strings.clone(e.id, context.temp_allocator)
	err := acct_share_item(st.acct, id, who)
	if err != "" {
		st.share_err = strings.clone(err)
		return
	}
	st.share_open = false
	wipe_buf(&st.share_with)
	book_rebuild(&st.bk)
	refilter(st)
	select_id(st, id)
	note(st, ui, fmt.tprintf("Shared with %s, read-only", who))
}

do_revoke :: proc(st: ^St, ui: ^p.Ctx, share_id: string) {
	keep := ""
	if e := current(st); e != nil {
		keep = strings.clone(e.id, context.temp_allocator)
	}
	n, err := acct_revoke(st.acct, share_id)
	if err != "" {
		note(st, ui, err)
		return
	}
	book_rebuild(&st.bk)
	st.health_ok = false
	refilter(st)
	select_id(st, keep)
	note(st, ui, fmt.tprintf("Revoked; %d item(s) re-encrypted under a new key", n))
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

begin_import :: proc(st: ^St, path: string) {
	if st.imp_open {
		import_result_free(&st.imp)
	}
	st.imp = import_path(path, "auto", "")
	if st.imp_path != "" {
		delete(st.imp_path)
	}
	st.imp_path = strings.clone(path)
	st.imp_open = true
	st.imp_target = book_default_target(&st.bk)
}

finish_import :: proc(st: ^St, ui: ^p.Ctx) {
	n := 0
	for len(st.imp.entries) > 0 {
		e := pop_front(&st.imp.entries)
		if _, err := book_add(&st.bk, e, st.imp_target); err != "" {
			note(st, ui, err)
			break
		}
		n += 1
	}
	import_result_free(&st.imp)
	st.imp_open = false
	vault_sort(&st.v)
	st.health_ok = false
	refilter(st)
	note(st, ui, fmt.tprintf("Imported %d items", n))
	if st.mode == .Account {
		st.busy = .Syncing
	}
}

// ---------------------------------------------------------------------------
// Autofill: the socket is served from the frame loop
// ---------------------------------------------------------------------------

autofill_tick :: proc(ui: ^p.Ctx, st: ^St) {
	if !st.af.running {
		return
	}
	af_service(&st.af, 0)
	for len(st.af.queue) > 0 && st.af.prompt.kind == .None {
		r := pop_front(&st.af.queue)
		resp := af_handle(&st.af, &st.bk, r)
		delete(r.line)
		if resp != "" {
			af_send(&st.af, r.conn, resp)
		}
	}
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
		if p.shortcut(ui, 'o', {.Ctrl}) && st.mode == .Local {
			begin_pick(st, .Open_Vault)
		}
		return
	}

	// An autofill request waiting for an answer comes before anything else.
	if st.af.prompt.kind != .None {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			af_decide(&st.af, &st.bk, .Deny)
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
	if st.share_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			st.share_open = false
		} else if p.key_pressed(ui, p.KEY_RETURN) {
			do_share(st, ui)
		}
		return
	}
	if st.imp_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			import_result_free(&st.imp)
			st.imp_open = false
		} else if p.key_pressed(ui, p.KEY_RETURN) && st.imp.err == "" {
			finish_import(st, ui)
		}
		return
	}

	if p.shortcut(ui, 'l', {.Ctrl}) {
		lock(st, "Locked", clock(ui))
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
	if p.shortcut(ui, 'o', {.Ctrl}) && st.mode == .Local {
		begin_pick(st, .Open_Vault)
		return
	}
	if p.shortcut(ui, 'i', {.Ctrl}) {
		begin_pick(st, .Import)
		return
	}
	if p.shortcut(ui, 'y', {.Ctrl}) && st.mode == .Account {
		st.busy = .Syncing
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
				note(st, ui, "That item has no TOTP secret")
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
		} else if st.nav.kind != .All {
			st.nav = {}
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
// Picking a file: a different local vault, or an export to import
// ---------------------------------------------------------------------------

VAULT_FILTERS := [?]kit.Pick_Filter{{"palmy vaults", {VAULT_EXT}}, kit.PICK_ALL}
IMPORT_FILTERS := [?]kit.Pick_Filter {
	{"password exports", {"json", "csv", "1pux", "kdbx", VAULT_EXT}},
	kit.PICK_ALL,
}

begin_pick :: proc(st: ^St, use: Pick_Use) {
	st.pick_use = use
	if use == .Import {
		home := os.get_env("HOME", context.temp_allocator)
		kit.pick_begin(&st.pick, .Open_File, {title = "Import passwords", dir = home, filters = IMPORT_FILTERS[:], confirm = "Import"})
		return
	}
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
	if !res.ok {
		return
	}
	if use == .Import {
		begin_import(st, res.path)
		return
	}
	if use != .Open_Vault {
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
		bk = Book{path = path, sess = sess, v = Vault{entries = make([dynamic]Entry)}},
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

