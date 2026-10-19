// Software — Palmy's app store.
//
// Discover applications by category, search as you type, see what is
// installed and what can be updated, and read a package's page: its
// description, size, licence, dependencies, what depends on it and every
// file it puts down. Install, Remove and Update all show palm's exact plan
// first ("will install track, emoji; download 1.2 MB"), ask, then stream
// palm's progress, and show palm's own words if it fails.
//
// Two halves, one direction each:
//
//   - reading is `palm ... --json`, run as you (model.odin). No root, no
//     daemon, and no second opinion about what is installed.
//   - changing is palmd (daemon.odin), the root daemon that runs palm for
//     members of group wheel. Software never builds palm's argv for a
//     change; it names an action and some packages, and palmd decides the
//     rest.
//
//	store                       the window
//	store --demo                the window, on fabricated data
//	store --shots <dir>         render every view offscreen to PNGs (demo data)
//	store search <text> [--json] | info <pkg> | list [--installed|--upgradable]
//	store plan|install|remove <pkg>... | upgrade | update     (through palmd)
//	store --selftest
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

WIN_W :: 1180
WIN_H :: 760
TOOLBAR_H :: 52
SIDEBAR_W :: 224
STATUS_H :: 28

// The one accent, as in Files: selection, the primary action, progress.
SELECTION :: 0x2563eb

View :: enum u8 {
	Discover,
	Category,
	Search,
	Installed,
	Updates,
	Package,
}

// Nav is one place the back button can return to.
Nav :: struct {
	view:     View,
	category: string,
	pkg:      string,
}

State :: struct {
	cat:            Catalog,
	nav:            Nav,
	history:        [dynamic]Nav,
	query:          [dynamic]u8,
	searching:      bool, // the search field has the keyboard
	swallow:        bool, // the key that focused the field is not text
	installed_all:  bool, // Installed shows dependencies too
	txn:            Txn,
	files_error:    string,
	toast:          string,
	toast_at:       f64,
	demo:           bool,
	quit:           bool,
}

main :: proc() {
	// --shots and --demo are the window's business, not the CLI's, and are
	// looked for before the command line is handed to the kit.
	args := os.args[1:]
	demo := false
	for a, i in args {
		switch a {
		case "--shots":
			dir := i + 1 < len(args) ? args[i + 1] : "shots"
			os.exit(shots(dir))
		case "--demo":
			demo = true
		}
	}
	if !demo {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
	}

	app, err := kit.start(
		{
			title = "Software",
			app_id = "store",
			width = WIN_W,
			height = WIN_H,
			min_width = 860,
			min_height = 520,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("store: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.register_color("selection", p.hex(SELECTION))

	st := new(State)
	st.demo = demo
	state_init(st)

	for ui in p.frames(app) {
		tick(ui, st)
		handle_keys(ui, st)
		frame(ui, st)
		if st.quit {
			p.quit_app(app)
		}
	}
}

state_init :: proc(st: ^State) {
	st.txn.demo = st.demo
	if st.demo {
		demo_catalog(&st.cat)
		demo_attach(&st.cat)
	} else {
		reload(st)
	}
	st.nav = {view = .Discover}
}

// reload asks palm again. It runs after every change, so the window shows
// what palm says now rather than what Software assumes happened.
reload :: proc(st: ^State) {
	if st.demo {
		return
	}
	catalog_load(&st.cat)
	for &q in st.cat.pkgs {
		q.required_by = clone_strings(rdeps_local(&st.cat, &q))
	}
}

// tick moves a running change along and keeps frames coming while it runs.
tick :: proc(ui: ^p.Ctx, st: ^State) {
	if txn_busy(&st.txn) {
		// palmd is polled, not waited on: a frame every 50 ms is enough to
		// see each progress line as it arrives, and the loop sleeps between.
		p.wake_after(ui, 50 * time.Millisecond)
		if txn_poll(&st.txn, f64(p.elapsed(ui))) {
			reload(st)
		}
	}
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

go :: proc(st: ^State, to: Nav) {
	if to == st.nav {
		return
	}
	if st.nav.view != .Search {
		append(&st.history, st.nav)
	}
	st.nav = Nav{view = to.view, category = strings.clone(to.category), pkg = strings.clone(to.pkg)}
	if to.view != .Search {
		st.searching = false
	}
	delete(st.files_error)
	st.files_error = ""
}

go_back :: proc(st: ^State) {
	if len(st.history) == 0 {
		st.nav = {view = .Discover}
		return
	}
	st.nav = pop(&st.history)
}

open_package :: proc(st: ^State, name: string) {
	go(st, {view = .Package, pkg = name})
	if pk := find(&st.cat, name); pk != nil {
		if st.demo {
			if pk.installed != "" {
				demo_files(pk)
			}
		} else {
			package_load_info(pk)
			if pk.installed != "" {
				// An installed package's files are in the database already;
				// asking costs nothing. One that is not installed would have
				// to be downloaded, so that waits for "Show files".
				if why := package_load_files(pk); why != "" {
					st.files_error = strings.clone(why)
				}
			}
		}
	}
}

note :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = 0
}

// start_change asks palmd for a plan; the dialog takes it from there.
start_change :: proc(st: ^State, action: Action, names: ..string) {
	txn_begin(&st.txn, action, names)
}

open_app :: proc(st: ^State, pk: ^Package) {
	cmd := command_of(pk)
	if cmd == "" {
		return
	}
	if st.demo {
		note(st, fmt.tprintf("Would open %s", cmd))
		return
	}
	if kit.launch({cmd}) {
		note(st, fmt.tprintf("Opening %s", cmd))
	} else {
		note(st, fmt.tprintf("Could not start %s", cmd))
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

handle_keys :: proc(ui: ^p.Ctx, st: ^State) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		st.quit = true
		return
	}

	// The dialog owns the keyboard while it is up.
	if st.txn.stage != .Idle {
		switch st.txn.stage {
		case .Confirm:
			if plain(ui, p.KEY_RETURN) && !plan_empty(st.txn.plan) {
				txn_confirm(&st.txn)
			} else if plain(ui, p.KEY_ESCAPE) {
				txn_cancel(&st.txn)
			}
		case .Done, .Failed:
			if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_ESCAPE) {
				txn_reset(&st.txn)
			}
		case .Planning, .Applying, .Idle:
		}
		return
	}

	if p.shortcut(ui, 'f', {.Ctrl}) || (!st.searching && plain(ui, '/')) {
		st.searching = true
		st.swallow = true
	}
	if p.shortcut(ui, 'r', {.Ctrl}) || plain(ui, p.KEY_F5) {
		reload(st)
		note(st, "Reloaded from palm")
	}

	if st.searching {
		typed := st.swallow ? "" : p.typed_text(ui)
		st.swallow = false
		changed := false
		for b in transmute([]u8)typed {
			if b >= 0x20 {
				append(&st.query, b)
				changed = true
			}
		}
		if plain(ui, p.KEY_BACKSPACE) && len(st.query) > 0 {
			n := 1
			for n < len(st.query) && st.query[len(st.query) - n] & 0xc0 == 0x80 {
				n += 1
			}
			resize(&st.query, len(st.query) - n)
			changed = true
		}
		if p.shortcut(ui, 'u', {.Ctrl}) {
			clear(&st.query)
			changed = true
		}
		if plain(ui, p.KEY_ESCAPE) {
			clear(&st.query)
			changed = true
			st.searching = false
		}
		if changed {
			sync_search(st)
		}
		if plain(ui, p.KEY_RETURN) {
			// Return opens the best match, the way a launcher does.
			if hits := search(&st.cat, string(st.query[:])); len(hits) > 0 && len(st.query) > 0 {
				open_package(st, hits[0].name)
			}
		}
		return
	}

	if plain(ui, p.KEY_ESCAPE) || p.shortcut(ui, p.KEY_LEFT, {.Alt}) || plain(ui, p.KEY_BACKSPACE) {
		go_back(st)
	}
}

// sync_search shows results while there is a query and goes back when the
// query is emptied.
sync_search :: proc(st: ^State) {
	if len(st.query) > 0 {
		if st.nav.view != .Search {
			go(st, {view = .Search})
		}
	} else if st.nav.view == .Search {
		go_back(st)
	}
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	toolbar(ui, st)
	p.row(ui, "flex-1 min-h-0 w-full")
	sidebar(ui, st)
	p.col(ui, "flex-1 min-w-0 h-full relative overflow-hidden")
	if st.cat.error != "" && len(st.cat.pkgs) == 0 {
		empty_state(ui, ICON_CIRCLE_ALERT, "palm could not be asked", st.cat.error)
	} else {
		switch st.nav.view {
		case .Discover:
			discover_view(ui, st)
		case .Category:
			category_view(ui, st)
		case .Search:
			search_view(ui, st)
		case .Installed:
			installed_view(ui, st)
		case .Updates:
			updates_view(ui, st)
		case .Package:
			package_view(ui, st)
		}
	}
	p.end(ui)
	p.end(ui)
	status_bar(ui, st)

	if st.txn.stage != .Idle {
		change_dialog(ui, st)
	}
	toast(ui, st)
}
