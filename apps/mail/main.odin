// Mail — a mail client for palmy.
//
// Folder sidebar, threaded conversation list, reader, composer and search over
// a Maildir on disk. The engine that fills that Maildir (IMAP, JMAP, POP3)
// lives elsewhere; this is the part a person looks at.
//
// SAFETY, stated once and enforced everywhere below:
//
//   - There is no network code in this binary. No socket is opened, no host is
//     resolved, no URL is fetched. Accounts carry a host and port only so the
//     sidebar can say which local test server they belong to, and a config
//     naming anything that is not loopback is shown as refused.
//   - Send writes a file into the account's own local Outbox Maildir. Nothing
//     is transmitted. See compose.odin.
//   - Mail is read only from the app's own data directory,
//     ~/.local/share/palmy-mail, or from a `--maildir=` path given on the
//     command line. The user's real mail, wherever it might be, is never
//     touched.
//   - The reader never loads a remote resource, which is the tracking-pixel
//     problem solved by not having a loader: html_to_text discards every
//     attribute, including every src and href.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

// The faces the kit loads for a window. The offscreen renderer has its own
// font table, so `--uitest` needs the same list; it is spelled out here rather
// than reached for inside the kit, which this app does not own.
FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"

MONO_FONTS :: [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

main :: proc() {
	// Modes that do not need a window, handled before one is opened. These
	// are the flags this program has always taken, kept exactly as they were;
	// the command line proper (cli.odin) is an addition beside them.
	for arg in os.args[1:] {
		switch {
		case arg == "--fixtures":
			os.exit(run_fixtures())
		case arg == "--selftest":
			os.exit(run_selftest())
		case strings.has_prefix(arg, "--uitest"):
			dir := "/tmp/palmy-mail-uitest"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			}
			os.exit(run_uitest(dir))
		case strings.has_prefix(arg, "--walkthrough"):
			dir := "/tmp/palmy-mail-walkthrough"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			}
			os.exit(run_uitest(dir, true))
		case strings.has_prefix(arg, "--palm-shots"):
			dir := "palm-shots"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			}
			for a in os.args[1:] {
				if strings.has_prefix(a, "--data-dir=") {
					data_dir_override = strings.clone(a[len("--data-dir="):])
				}
			}
			os.exit(palm_shots(dir))
		case strings.has_prefix(arg, "--shots"):
			// Offscreen screenshots of the real interface, against a mailbox
			// generated for the purpose. No compositor, no window.
			dir := "palmy-mail-shots"
			if eq := strings.index_byte(arg, '='); eq > 0 {
				dir = arg[eq + 1:]
			} else {
				for a, i in os.args[1:] {
					if a == arg && i + 2 <= len(os.args[1:]) && i + 1 < len(os.args[1:]) {
						dir = os.args[1:][i + 1]
						break
					}
				}
			}
			os.exit(shots(dir))
		}
	}

	// The command line: everything else that is not one of the window's own
	// path options. `--data-dir=`, `--maildir=` and `--save-dir=` are taken
	// out first so `mail list --data-dir=X --json` reads X, and so a bare
	// `mail --maildir=X` still opens the window on X.
	rest := make([dynamic]string, context.temp_allocator)
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--data-dir="):
			data_dir_override = strings.clone(arg[len("--data-dir="):])
			data_dir_explicit = true
		case strings.has_prefix(arg, "--maildir="):
			cli_maildir = strings.clone(arg[len("--maildir="):])
		case strings.has_prefix(arg, "--save-dir="):
		case:
			append(&rest, arg)
		}
	}
	if code, handled := kit.cli_args(surface(), rest[:]); handled {
		os.exit(code)
	}

	app, err := kit.start(
		{
			title = "Mail",
			width = 1360,
			height = 860,
			min_width = 900,
			min_height = 520,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("mail: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	init_state(st)

	for ui in p.frames(app) {
		st.now = time.now()
		handle_keys(ui, st, app)
		draft_tick(st)
		frame(ui, st)
		apply_scroll(ui, st)
		retitle(app, st)
	}

	// The window closed. Whatever is in the composer is written out before
	// this process goes away — the autosave tick has a second of slack in it,
	// and the last second of someone's typing is exactly what they would
	// notice missing.
	if compose_dirty(&st.comp) {
		draft_save(st)
	}
}

init_state :: proc(st: ^State) {
	// `--data-dir=PATH` points the whole app at another data directory — a
	// demo account's synced identities, say — instead of the default one.
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--data-dir=") {
			data_dir_override = strings.clone(arg[len("--data-dir="):])
			data_dir_explicit = true
		}
	}
	// `--maildir=PATH` makes one ad-hoc account out of a tree on disk, which
	// is how to point the UI at whatever the engine has just written without
	// editing a config file. It is still only ever read.
	override := ""
	save_dir := ""
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--maildir=") {
			override = arg[len("--maildir="):]
		}
		if strings.has_prefix(arg, "--save-dir=") {
			save_dir = arg[len("--save-dir="):]
		}
	}
	model_open(st, override)
	st.save_dir = strings.clone(save_dir != "" ? save_dir : default_save_dir(context.temp_allocator))

	// No fixtures yet and nothing configured on disk? Write them, rather than
	// opening onto an empty window with no way forward.
	any_mail := false
	for a in st.accounts {
		if is_maildir(a.root) || os.is_dir(a.root) {
			any_mail = true
			break
		}
	}
	// Not when the directory was named: an empty account is what a person
	// who has not signed in yet should see, not somebody else's fixtures.
	if !any_mail && override == "" && !data_dir_explicit {
		write_fixtures(st.data_dir)
		clear(&st.accounts)
		load_config(st)
		discover_accounts(st)
		note(st, "No mailbox found, so a fixture Maildir was generated.")
	}

	reload_all(st)
	// Signed in to Palmy: open on the first identity, one mailbox at a
	// time, which is the default view. 0 shows them all.
	if first := palm_nth(st, 0); first >= 0 && !st.single_tree {
		set_identity_view(st, first)
	}

	// A draft left behind by the last run. The composer does not open by
	// itself — walking into half a message is startling — but the status bar
	// says it is there and C picks it up.
	draft_peek(st)
	if st.draft_waiting {
		note(st, tfmt("An unsent draft is waiting: %s  ·  press C", st.draft_label))
	}
}

// model_open sets up everything the model needs and finds the accounts, and
// nothing else: no window, no fixtures, no draft. The window's init_state
// starts here and the command line (cli.odin) starts here, so the two see the
// same accounts in the same order — which matters, because a POP3 account's
// local flag sidecar is keyed by that order.
model_open :: proc(st: ^State, maildir: string) {
	st.data_dir = default_data_dir()
	st.tz_offset = local_offset()
	st.now = time.now()
	st.reader_msg = -1
	st.list_scroll_to = -1
	st.att_sel = -1
	st.pane = .List

	st.single_tree = maildir != ""
	if maildir != "" {
		append(
			&st.accounts,
			Account {
				name = strings.clone("Maildir"),
				protocol = .IMAP,
				address = strings.clone("local@localhost"),
				host = strings.clone("127.0.0.1"),
				root = strings.clone(maildir),
				loopback = true,
			},
		)
	} else {
		load_config(st)
		discover_accounts(st)
	}
}

// default_save_dir is where the Save dialog opens the first time: the usual
// Downloads directory when there is one, and home otherwise. `--save-dir=`
// overrides it, which is what the recorded demo uses so that a recording
// writes into a scratch directory rather than somebody's Downloads.
default_save_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return strings.clone("/tmp", allocator)
	}
	for name in ([?]string{"Downloads", "Desktop"}) {
		cand := tfmt("%s/%s", home, name)
		if os.is_dir(cand) {
			return strings.clone(cand, allocator)
		}
	}
	return strings.clone(home, allocator)
}

// reload_all rescans the Maildir from disk. The engine writes files
// underneath us, so this is the refresh button and it has to be cheap enough
// to press.
reload_all :: proc(st: ^State) {
	// A Maildir the engine created since the last scan should appear without
	// anyone editing a config file, so discovery runs on every refresh —
	// except under `--maildir`, where the user named exactly one tree and
	// means exactly that one.
	if !st.single_tree {
		discover_accounts(st)
	}

	keep_folder := ""
	if st.folder_sel >= 0 && st.folder_sel < len(st.folders) {
		keep_folder = strings.clone(st.folders[st.folder_sel].name, context.temp_allocator)
		keep_folder = tfmt("%d/%s", st.folders[st.folder_sel].account, keep_folder)
	}

	scan_accounts(st)
	rebuild_sidebar(st)
	build_address_book(st)
	prune_marks(st)

	st.folder_sel = 0
	if keep_folder != "" {
		for f, i in st.folders {
			if tfmt("%d/%s", f.account, f.name) == keep_folder {
				st.folder_sel = i
				break
			}
		}
	} else {
		// Open on the first inbox, which is what a mail client is for.
		for f, i in st.folders {
			if f.role == .Inbox {
				st.folder_sel = i
				break
			}
		}
	}
	select_folder(st, st.folder_sel)
}

// local_offset asks the system for the UTC offset so dates read as wall clock.
local_offset :: proc() -> i64 {
	out, ok := kit.run({"date", "+%z"}, context.temp_allocator)
	if !ok || len(out) < 5 {
		return 0
	}
	sign: i64 = out[0] == '-' ? -1 : 1
	hh := i64(out[1] - '0') * 10 + i64(out[2] - '0')
	mm := i64(out[3] - '0') * 10 + i64(out[4] - '0')
	return sign * (hh * 3600 + mm * 60)
}

// apply_scroll drives palmy's scroll API after the tree has been built. The
// container and the row both have to have been laid out for their rectangles
// to exist, which is why this runs at the end of the frame rather than inside
// the row that asked for it.
apply_scroll :: proc(ui: ^p.Ctx, st: ^State) {
	if st.list_scroll_home && st.list_id != 0 {
		// A new folder or a new query starts at the top, not wherever the last
		// one happened to be scrolled to.
		p.scroll_to(ui, st.list_id, {0, 0})
		st.list_scroll_home = false
		st.list_scroll_to = -1
		p.redraw(ui)
	}
	if st.list_scroll_to >= 0 && st.list_id != 0 {
		i := clamp(st.list_scroll_to, 0, max(0, len(st.rows) - 1))
		if st.sel_row_id != 0 {
			// The row was built this frame, so palmy can work out the shortest
			// move for itself.
			p.scroll_into_view(ui, st.list_id, st.sel_row_id, 24)
		} else if i < len(st.row_y) {
			// The row is outside the virtualised window and has no rectangle,
			// so the offset comes from the model instead.
			view := p.rect_of(ui, st.list_id).h
			y := st.row_y[i]
			h := row_height(st.rows[i].kind)
			cur := p.scroll_of(ui, st.list_id).y
			if y < cur {
				p.scroll_to(ui, st.list_id, {0, max(0, y - 24)})
			} else if y + h > cur + view {
				p.scroll_to(ui, st.list_id, {0, y + h - view + 24})
			}
		}
		st.list_scroll_to = -1
		p.redraw(ui)
	}
	if st.side_scroll && st.side_id != 0 && st.side_row_id != 0 {
		p.scroll_into_view(ui, st.side_id, st.side_row_id, 12)
		st.side_scroll = false
		p.redraw(ui)
	}
	if st.read_scroll_home && st.read_id != 0 {
		p.scroll_to(ui, st.read_id, {0, 0})
		st.read_scroll_home = false
	}
}

// ---------------------------------------------------------------------------
// Keyboard
//
// Every command is reachable with an unmodified key. That is partly taste — a
// mail client that needs the mouse is a failure — and partly necessity: the
// recording harness can type and press named keys but cannot hold a modifier
// or synthesize a click, so a shortcut behind Ctrl is a shortcut that cannot
// be demonstrated or driven in a test.
// ---------------------------------------------------------------------------

// plain matches an unmodified, non-repeating press. Holding a key down should
// not open five threads.
plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

// key_times counts presses this frame, repeats included. Two arrow presses can
// land in one frame when a script drives the window, and a cursor that moves
// by one would fall behind.
key_times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

shifted :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && .Shift in k.mods {
			return true
		}
	}
	return false
}

PANE_CYCLE :: [?]Pane{.Sidebar, .List, .Reader, .Search}

handle_keys :: proc(ui: ^p.Ctx, st: ^State, app: ^p.App) {
	if app != nil && p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}

	// The file dialog owns the keyboard outright while it is up — it has its
	// own panes, its own type-ahead and its own overwrite confirmation, and a
	// stray 'd' reaching this app's delete would be unforgivable.
	if kit.pick_active(&st.saver.pick) {
		return
	}
	// The two in-window confirmations come next, for the same reason.
	if st.confirm_purge {
		purge_keys(ui, st)
		return
	}
	if st.move_open {
		move_keys(ui, st)
		return
	}
	if st.signin.open {
		signin_keys(ui, st)
		return
	}

	// The composer owns the keyboard while it is open: unmodified letters are
	// text there, not commands.
	if st.comp.open {
		compose_keys(ui, st)
		return
	}

	if p.shortcut(ui, 'f', {.Ctrl}) {
		focus_search(st)
		return
	}

	// The identity keys (P, 0-9, Shift+I) work from the list and the sidebar;
	// in the search field they are text.
	if st.pane != .Search && palm_keys(ui, st) {
		return
	}

	switch st.pane {
	case .Search:
		search_keys(ui, st)
	case .Sidebar:
		sidebar_keys(ui, st)
	case .List, .Reader:
		list_keys(ui, st)
	case .Compose:
		// The pane says compose but the composer is shut; recover.
		st.pane = .List
	}
}

focus_search :: proc(st: ^State) {
	st.pane = .Search
	st.swallow = true
	le_end(&st.query)
}

cycle_pane :: proc(st: ^State, by: int) {
	cycle := PANE_CYCLE
	at := 0
	for pane, i in cycle {
		if pane == st.pane {
			at = i
			break
		}
	}
	st.pane = cycle[(at + by + len(cycle)) % len(cycle)]
	if st.pane == .Search {
		st.swallow = true
	}
}

search_keys :: proc(ui: ^p.Ctx, st: ^State) {
	changed := false
	typed := st.swallow ? "" : p.typed_text(ui)
	st.swallow = false
	for b in transmute([]u8)typed {
		if b >= 0x20 {
			le_insert(&st.query, string([]u8{b}))
			changed = true
		}
	}
	if plain(ui, p.KEY_BACKSPACE) && le_backspace(&st.query) {
		changed = true
	}
	if plain(ui, p.KEY_DELETE) && le_delete(&st.query) {
		changed = true
	}
	if key_times(ui, p.KEY_LEFT) > 0 {
		le_left(&st.query)
	}
	if key_times(ui, p.KEY_RIGHT) > 0 {
		le_right(&st.query)
	}
	if plain(ui, p.KEY_HOME) {
		le_home(&st.query)
	}
	if plain(ui, p.KEY_END) {
		le_end(&st.query)
	}
	if p.shortcut(ui, 'u', {.Ctrl}) {
		le_clear(&st.query)
		changed = true
	}
	if plain(ui, p.KEY_ESCAPE) {
		// Escape clears the search, then leaves the field — the two-step every
		// search box has.
		if le_text(&st.query) != "" {
			le_clear(&st.query)
			run_search(st)
		}
		st.pane = .List
		return
	}
	if plain(ui, p.KEY_TAB) {
		cycle_pane(st, 1)
	}
	if changed {
		run_search(st)
	}
	if plain(ui, p.KEY_DOWN) || plain(ui, p.KEY_RETURN) {
		st.pane = .List
		if len(st.rows) > 0 {
			st.row_sel = clamp(st.row_sel, 0, len(st.rows) - 1)
			st.list_scroll_to = st.row_sel
			sync_reader(st)
		}
	}
}

sidebar_keys :: proc(ui: ^p.Ctx, st: ^State) {
	n := len(st.side_rows)
	if n == 0 {
		st.pane = .List
		return
	}
	step := 0
	step += key_times(ui, p.KEY_DOWN) + key_times(ui, 'j')
	step -= key_times(ui, p.KEY_UP) + key_times(ui, 'k')
	if step != 0 {
		st.side_sel = clamp(st.side_sel + step, 0, n - 1)
		st.side_scroll = true
	}
	if plain(ui, p.KEY_HOME) || plain(ui, 'g') {
		st.side_sel = 0
		st.side_scroll = true
	}
	if plain(ui, p.KEY_END) || shifted(ui, 'g') {
		st.side_sel = n - 1
		st.side_scroll = true
	}

	row := st.side_rows[clamp(st.side_sel, 0, n - 1)]
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) || plain(ui, 'l') {
		switch row.kind {
		case .Account:
			st.accounts[row.account].collapsed = !st.accounts[row.account].collapsed
			rebuild_sidebar(st)
		case .Folder:
			select_folder(st, row.folder)
			st.pane = .List
		case .Unified:
			st.unified = true
			st.row_sel = 0
			rebuild_list(st)
			st.pane = .List
		}
	}
	// Moving the cursor over a folder opens it, the way a sidebar does.
	if step != 0 && row.kind == .Folder {
		select_folder(st, row.folder)
		st.side_sel = clamp(st.side_sel, 0, len(st.side_rows) - 1)
	}
	if plain(ui, p.KEY_ESCAPE) {
		st.pane = .List
	}
	if plain(ui, p.KEY_TAB) {
		cycle_pane(st, 1)
	}
	if plain(ui, 'c') {
		compose_new(st)
	}
	if plain(ui, '/') {
		focus_search(st)
	}
	if plain(ui, 'r') {
		reload_all(st)
		note(st, "Reloaded from disk")
	}
}

list_keys :: proc(ui: ^p.Ctx, st: ^State) {
	// The wheel is handled by palmy's own scroll container; the keyboard moves
	// the cursor and asks for it to be scrolled into view.
	step := 0
	step += key_times(ui, p.KEY_DOWN) + key_times(ui, 'j')
	step -= key_times(ui, p.KEY_UP) + key_times(ui, 'k')
	if step != 0 {
		move_selection(st, step)
	}
	if plain(ui, p.KEY_PAGE_DOWN) {
		move_selection(st, 10)
	}
	if plain(ui, p.KEY_PAGE_UP) {
		move_selection(st, -10)
	}
	if plain(ui, p.KEY_HOME) || plain(ui, 'g') {
		st.row_sel = 0
		st.list_scroll_to = 0
		sync_reader(st)
	}
	if plain(ui, p.KEY_END) || shifted(ui, 'g') {
		st.row_sel = max(0, len(st.rows) - 1)
		st.list_scroll_to = st.row_sel
		sync_reader(st)
	}

	if plain(ui, p.KEY_RETURN) || plain(ui, 'o') {
		open_row(st)
	}
	// Right expands a thread without leaving the list; left collapses it.
	if plain(ui, p.KEY_RIGHT) || plain(ui, 'l') || plain(ui, 'x') {
		if ti := current_thread(st); ti >= 0 && len(st.threads[ti].msgs) > 1 {
			st.threads[ti].expanded = true
			rebuild_rows(st)
			sync_reader(st)
		}
	}
	if plain(ui, p.KEY_LEFT) || plain(ui, 'h') {
		if ti := current_thread(st); ti >= 0 && st.threads[ti].expanded {
			st.threads[ti].expanded = false
			rebuild_rows(st)
			sync_reader(st)
			st.list_scroll_to = st.row_sel
		} else {
			st.pane = .Sidebar
		}
	}

	mi := st.reader_msg
	if plain(ui, 'c') {
		compose_new(st)
	}
	// Shift+C insists on a blank message. Whatever was unsent is kept, in
	// Drafts, rather than quietly replaced.
	if shifted(ui, 'c') {
		compose_blank(st)
	}
	if plain(ui, 'r') && mi >= 0 {
		compose_reply(st, mi, false)
	}
	if plain(ui, 'a') && mi >= 0 {
		compose_reply(st, mi, true)
	}
	if plain(ui, 'f') && mi >= 0 {
		compose_forward(st, mi)
	}
	if plain(ui, 's') || plain(ui, '*') {
		toggle_flagged(st)
	}
	if plain(ui, 'u') {
		mark_read_toggle(st)
	}
	if plain(ui, 'i') {
		st.show_raw = !st.show_raw
	}

	// Attachments: V walks the chips, W writes the selected one out through
	// the shared file dialog. Both unmodified, so the recorder can drive them.
	if plain(ui, 'v') {
		attachment_cycle(st, 1)
	}
	if shifted(ui, 'v') {
		attachment_cycle(st, -1)
	}
	if plain(ui, 'w') {
		begin_save_attachment(st)
	}

	// Filing. M opens the folder sheet, E archives, D trashes, Shift+D is the
	// one irreversible operation and asks first, Z puts the last move back.
	if plain(ui, 'm') {
		open_move_sheet(st)
	}
	if plain(ui, 'e') {
		archive_selection(st)
	}
	if plain(ui, 'd') {
		delete_selection(st)
	}
	if shifted(ui, 'd') {
		begin_purge(st)
	}
	if plain(ui, 'z') {
		do_undo(st)
	}

	// Multi-select. T marks the row under the cursor — a whole conversation
	// on a thread row — and every verb above then acts on the marked set
	// instead. Shift+T clears it, and so does Escape.
	if plain(ui, 't') {
		mark_toggle_row(st)
	}
	if shifted(ui, 't') {
		if marked_count(st) > 0 {
			marks_clear(st)
			note(st, "Selection cleared")
		}
	}

	if plain(ui, '/') {
		focus_search(st)
	}
	if plain(ui, p.KEY_F5) {
		reload_all(st)
		note(st, "Reloaded from disk")
	}
	if plain(ui, p.KEY_TAB) {
		cycle_pane(st, 1)
	}
	// Escape backs out of one thing at a time and never moves the keyboard
	// somewhere the user did not ask for: collapse the conversation, then drop
	// the search, and then stop. The sidebar is reached with Left or Tab.
	if plain(ui, p.KEY_ESCAPE) {
		if marked_count(st) > 0 {
			marks_clear(st)
			note(st, "Selection cleared")
		} else if ti := current_thread(st); ti >= 0 && st.threads[ti].expanded {
			st.threads[ti].expanded = false
			rebuild_rows(st)
			sync_reader(st)
			st.list_scroll_to = st.row_sel
		} else if st.searching {
			le_clear(&st.query)
			run_search(st)
			select_folder(st, st.folder_sel)
		} else {
			st.pane = .List
		}
	}

	// The reader scrolls with space and the brackets, so a long message can be
	// read without reaching for the mouse.
	if st.read_id != 0 {
		if plain(ui, p.KEY_SPACE) {
			p.scroll_nudge(ui, st.read_id, {0, 320})
			p.redraw(ui)
		}
		if shifted(ui, p.KEY_SPACE) {
			p.scroll_nudge(ui, st.read_id, {0, -320})
			p.redraw(ui)
		}
	}
}

// ---------------------------------------------------------------------------
// Filing: the move sheet, the permanent-delete confirmation, undo
// ---------------------------------------------------------------------------

open_move_sheet :: proc(st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		note(st, "Nothing to move")
		return
	}
	if ok, why := can_file(st, st.messages[msgs[0]].account); !ok {
		note(st, why)
		return
	}
	if len(move_targets(st, msgs[0])) == 0 {
		note(st, "This account has nowhere else to put it")
		return
	}
	st.move_open = true
	st.move_sel = 0
}

move_keys :: proc(ui: ^p.Ctx, st: ^State) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		st.move_open = false
		return
	}
	targets := move_targets(st, msgs[0])
	if len(targets) == 0 {
		st.move_open = false
		return
	}
	step := key_times(ui, p.KEY_DOWN) + key_times(ui, 'j')
	step -= key_times(ui, p.KEY_UP) + key_times(ui, 'k')
	if step != 0 {
		st.move_sel = clamp(st.move_sel + step, 0, len(targets) - 1)
	}
	if plain(ui, p.KEY_ESCAPE) {
		st.move_open = false
		return
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
		do_move(st, targets[clamp(st.move_sel, 0, len(targets) - 1)])
	}
}

do_move :: proc(st: ^State, target_fi: int) {
	if target_fi < 0 || target_fi >= len(st.folders) {
		return
	}
	name := strings.clone(st.folders[target_fi].name, context.temp_allocator)
	st.move_open = false
	n, err := file_selection(st, target_fi)
	if err != "" {
		note(st, err)
		return
	}
	note(st, tfmt("Moved %d message%s to %s  ·  %s", n, plural(n), name, undo_phrase(n)))
}

do_undo :: proc(st: ^State) {
	what, err := undo_move(st)
	if err != "" {
		note(st, err)
		return
	}
	note(st, tfmt("Put “%s” back", what))
}

begin_purge :: proc(st: ^State) {
	n, _ := purge_label(st)
	if n == 0 {
		note(st, "Nothing to delete")
		return
	}
	st.confirm_purge = true
}

purge_keys :: proc(ui: ^p.Ctx, st: ^State) {
	// Enter does not confirm here. Every other dialog in this app takes Enter,
	// which is exactly why this one does not: the keystroke that queues a
	// message must not be the keystroke that unlinks one. Shift+D again, or
	// the button, and nothing else.
	if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, 'n') {
		st.confirm_purge = false
		return
	}
	if shifted(ui, 'd') || shifted(ui, 'y') {
		st.confirm_purge = false
		purge_selection(st)
	}
}

// close_composer is Escape and the X: it puts the composer away and keeps
// what is in it. Discard is the button that throws work away, and it is the
// only thing that does.
close_composer :: proc(st: ^State) {
	st.comp.open = false
	st.comp.confirm = false
	st.pane = .List
	ac_close(&st.comp)
	if compose_dirty(&st.comp) {
		if draft_save(st) {
			note(st, "Draft saved — press C to carry on with it")
		}
	}
}

// discard_composer is the one way to lose a draft on purpose: the slot goes,
// and so does the Drafts file it was opened from, if it came from one.
discard_composer :: proc(st: ^State) {
	c := &st.comp
	had := !compose_is_empty(c)
	origin := strings.clone(c.origin_path, context.temp_allocator)
	draft_discard(st)
	c.open = false
	c.confirm = false
	compose_reset(c)
	st.pane = .List
	if origin != "" && os.exists(origin) {
		os.remove(origin)
		reload_all(st)
	}
	if had {
		note(st, "Draft discarded")
	}
}

do_send :: proc(st: ^State) {
	path, ok := compose_send(st)
	if !ok {
		st.comp.confirm = false
		return
	}
	// The message is queued, so the draft of it is finished with: the slot
	// goes, and so does the Drafts file it was opened from.
	origin := strings.clone(st.comp.origin_path, context.temp_allocator)
	draft_discard(st)
	if origin != "" && os.exists(origin) {
		os.remove(origin)
	}
	compose_reset(&st.comp)
	st.comp.open = false
	st.comp.confirm = false
	st.pane = .List
	// Rescan, so the queued message appears in the Outbox folder the way any
	// other message does. Nothing special: it is a file in a Maildir.
	reload_all(st)
	note(st, tfmt("Queued locally: %s", path))
}

compose_keys :: proc(ui: ^p.Ctx, st: ^State) {
	c := &st.comp

	// The suggestion list owns Up, Down, Tab, Enter and Escape while it is
	// showing, and nothing else. Escape closes the list rather than the
	// composer, which is the one thing that would make the feature hostile.
	if c.ac_open && !c.confirm {
		if plain(ui, p.KEY_ESCAPE) {
			ac_close(c)
			return
		}
		if plain(ui, p.KEY_DOWN) {
			c.ac_sel = (c.ac_sel + 1) % max(1, len(c.ac_hits))
			return
		}
		if plain(ui, p.KEY_UP) {
			c.ac_sel = (c.ac_sel + max(1, len(c.ac_hits)) - 1) % max(1, len(c.ac_hits))
			return
		}
		if plain(ui, p.KEY_TAB) || plain(ui, p.KEY_RETURN) {
			ac_accept(st)
			return
		}
	}

	if c.confirm {
		if plain(ui, p.KEY_RETURN) {
			do_send(st)
		}
		if plain(ui, p.KEY_ESCAPE) {
			c.confirm = false
		}
		return
	}

	if plain(ui, p.KEY_ESCAPE) {
		close_composer(st)
		return
	}
	if plain(ui, p.KEY_TAB) {
		c.field = Compose_Field((int(c.field) + 1) % len(Compose_Field))
		ac_close(c)
		return
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		c.field = Compose_Field((int(c.field) + len(Compose_Field) - 1) % len(Compose_Field))
		ac_close(c)
		return
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Ctrl}) {
		c.confirm = true
		return
	}

	if c.field == .Send {
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			c.confirm = true
		}
		if plain(ui, p.KEY_UP) {
			c.field = .Body
		}
		return
	}

	typed := p.typed_text(ui)

	if c.field == .Body {
		b := &c.body
		if len(typed) > 0 {
			// One checkpoint per burst of typing, so undo steps in words
			// rather than in characters.
			if len(b.undo) == 0 || typed_is_boundary(typed) {
				buf_checkpoint(b)
			}
			buf_insert(b, typed)
		}
		if plain(ui, p.KEY_RETURN) {
			buf_newline(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_BACKSPACE) {
			buf_backspace(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_DELETE) {
			buf_delete_forward(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_LEFT) {
			buf_left(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_RIGHT) {
			buf_right(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_UP) {
			buf_up(b)
		}
		for _ in 0 ..< key_times(ui, p.KEY_DOWN) {
			buf_down(b)
		}
		if plain(ui, p.KEY_HOME) {
			buf_home(b)
		}
		if plain(ui, p.KEY_END) {
			buf_end_of_line(b)
		}
		if p.shortcut(ui, p.KEY_LEFT, {.Ctrl}) {
			buf_word_left(b)
		}
		if p.shortcut(ui, p.KEY_RIGHT, {.Ctrl}) {
			buf_word_right(b)
		}
		if p.shortcut(ui, 'k', {.Ctrl}) {
			buf_kill_to_end(b)
		}
		if p.shortcut(ui, 'u', {.Ctrl}) {
			buf_kill_to_start(b)
		}
		if p.shortcut(ui, 'z', {.Ctrl}) {
			buf_undo(b)
		}
		if p.shortcut(ui, 'y', {.Ctrl}) || p.shortcut(ui, 'z', {.Ctrl, .Shift}) {
			buf_redo(b)
		}
		return
	}

	// The header fields.
	e: ^Line_Edit
	switch c.field {
	case .To:
		e = &c.to
	case .Cc:
		e = &c.cc
	case .Subject:
		e = &c.subject
	case .Body, .Send:
		return
	}
	edited := false
	for b in transmute([]u8)typed {
		if b >= 0x20 {
			le_insert(e, string([]u8{b}))
			edited = true
		}
	}
	for _ in 0 ..< key_times(ui, p.KEY_BACKSPACE) {
		le_backspace(e)
		edited = true
	}
	for _ in 0 ..< key_times(ui, p.KEY_DELETE) {
		le_delete(e)
		edited = true
	}
	for _ in 0 ..< key_times(ui, p.KEY_LEFT) {
		le_left(e)
		edited = true
	}
	for _ in 0 ..< key_times(ui, p.KEY_RIGHT) {
		le_right(e)
		edited = true
	}
	if plain(ui, p.KEY_HOME) {
		le_home(e)
		edited = true
	}
	if plain(ui, p.KEY_END) {
		le_end(e)
		edited = true
	}
	if p.shortcut(ui, 'u', {.Ctrl}) {
		le_clear(e)
		edited = true
	}
	if edited {
		// Only To and Cc have a book behind them; ac_update knows that and
		// shuts the list for anything else.
		ac_update(st)
	}
	if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_DOWN) {
		c.field = Compose_Field(min(int(c.field) + 1, int(Compose_Field.Body)))
		ac_close(c)
	}
	if plain(ui, p.KEY_UP) {
		c.field = Compose_Field(max(int(c.field) - 1, 0))
		ac_close(c)
	}
}

// typed_is_boundary decides whether a burst of typing starts a new undo step.
// Whitespace and punctuation do; letters continue the current one.
typed_is_boundary :: proc(typed: string) -> bool {
	for i in 0 ..< len(typed) {
		c := typed[i]
		if c == ' ' || c == '\t' || c == '.' || c == ',' || c == ';' || c == ':' {
			return true
		}
	}
	return false
}
