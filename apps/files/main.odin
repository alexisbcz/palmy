// Files — a file browser for palmy, held to Finder's standard.
//
// Real directories read through core:os, a sidebar of places, a list view with
// sortable columns and an icon grid, breadcrumb navigation, live filtering, and
// a context menu drawn in-window because Wayland's xdg_popup is not available
// here.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Metrics. One place for every number the layout depends on.
// ---------------------------------------------------------------------------

TOOLBAR_H :: 52
STATUS_H :: 28
HEADER_H :: 30
ROW_H :: 28
SIDEBAR_W :: 220
INSPECTOR_W :: 248
TILE_W :: 112
TILE_H :: 100
GRID_PAD :: 12

KEY_MENU :: 0xff67

// The one accent in an otherwise neutral product: selection, in the sidebar,
// the list, the grid and the focus ring.
SELECTION :: 0x2563eb

run_cmd :: proc(argv: []string) -> (string, bool) {
	return kit.run(argv, context.temp_allocator)
}

main :: proc() {
	// `--shots <dir>` renders the browser offscreen and writes PNGs. It never
	// opens a window and never reads the real home directory; see shot.odin.
	args := os.args[1:]
	for a, i in args {
		if a == "--shots" {
			dir := i + 1 < len(args) ? args[i + 1] : "shots"
			os.exit(shots(dir))
		}
	}

	app, err := kit.start(
		{
			title = "Files",
			width = 1180,
			height = 760,
			min_width = 820,
			min_height = 480,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("files: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	p.register_color("selection", p.hex(SELECTION))

	st := State{}
	st.tz_offset = local_offset()
	st.now = time.now()
	build_places(&st)

	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/"
	}
	// `files /some/path` opens there, the way every other browser does.
	start := home
	if len(os.args) > 1 && is_dir_path(os.args[1]) {
		start = os.args[1]
	}
	go_to(&st, start)
	sync_place(&st)
	st.pane = .Files

	for ui in p.frames(app) {
		// How much fits is worked out first: the keyboard uses it for Page
		// Up/Down and for keeping the selection on screen.
		measure(ui, &st)
		handle_keys(ui, &st, app)
		frame(ui, &st)
		retitle(app, &st)
	}
}

@(private = "file")
last_title: string

retitle :: proc(app: ^p.App, st: ^State) {
	t := base_of(st.cwd)
	if t != last_title {
		delete(last_title)
		last_title = strings.clone(t)
		p.set_title(app, fmt.tprintf("%s — Files", t))
	}
}

// measure works out how much of the directory fits, which the keyboard and the
// scroll wheel both need before anything is drawn.
measure :: proc(ui: ^p.Ctx, st: ^State) {
	win := p.size(ui)
	pane_w := win.x - SIDEBAR_W - (st.inspector ? INSPECTOR_W : 0)
	body_h := win.y - TOOLBAR_H - STATUS_H
	st.pane_w = pane_w

	switch st.view {
	case .List:
		st.cols = 1
		st.rows = max(1, int((body_h - HEADER_H) / ROW_H))
	case .Grid:
		st.cols = max(1, int((pane_w - 2 * GRID_PAD) / TILE_W))
		st.rows = max(1, int((body_h - 2 * GRID_PAD) / TILE_H))
	}
	st.top = clamp(st.top, 0, max(0, total_lines(st) - st.rows))
}

total_lines :: proc(st: ^State) -> int {
	n := len(st.vis)
	if st.view == .Grid {
		return (n + st.cols - 1) / st.cols
	}
	return n
}

line_of :: proc(st: ^State, i: int) -> int {
	return st.view == .Grid ? i / max(1, st.cols) : i
}

ensure_visible :: proc(st: ^State) {
	l := line_of(st, st.sel)
	if l < st.top {
		st.top = l
	}
	if l >= st.top + st.rows {
		st.top = l - st.rows + 1
	}
	st.top = clamp(st.top, 0, max(0, total_lines(st) - st.rows))
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

// plain matches an unmodified key, and ignores the compositor's auto-repeat.
// Holding a key down should not open five folders or walk five levels up the
// tree, so the commands all go through here; only the arrow keys, which read
// their presses through `key_times`, are allowed to repeat.
plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

// key_times counts the presses of a key in this frame. Two arrow keys can
// easily land in one frame when a key repeats or a script drives the window,
// and a selection that moves by one would then fall behind.
key_times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

handle_keys :: proc(ui: ^p.Ctx, st: ^State, app: ^p.App) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}

	// The wheel scrolls the pane the same way it scrolls a list anywhere else:
	// the compositor reports surface units, ten or so to a notch.
	if sy := ui.input.scroll.y; sy != 0 {
		st.scroll_acc += sy / 10
		step := int(st.scroll_acc)
		if step != 0 {
			st.scroll_acc -= f32(step)
			st.top = clamp(st.top + step, 0, max(0, total_lines(st) - st.rows))
		}
	}

	// The context menu owns the keyboard while it is open.
	if st.menu_open {
		items := menu_items(st)
		if plain(ui, p.KEY_ESCAPE) {
			st.menu_open = false
			return
		}
		for _ in 0 ..< key_times(ui, p.KEY_DOWN) {
			st.menu_sel = menu_step(items, st.menu_sel, 1)
		}
		for _ in 0 ..< key_times(ui, p.KEY_UP) {
			st.menu_sel = menu_step(items, st.menu_sel, -1)
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			if st.menu_sel >= 0 && st.menu_sel < len(items) {
				do_menu(st, items[st.menu_sel].action)
			}
		}
		return
	}

	// Global toggles.
	// Outside the search field the unmodified keys are commands, which is also
	// the only way the recording harness can drive the app: it cannot hold a
	// modifier down. Focusing the field has to be settled first, so that the
	// very same frame does not read the rest as commands.
	typing := st.pane == .Search
	if p.shortcut(ui, 'f', {.Ctrl}) || (!typing && plain(ui, '/')) {
		st.pane = .Search
		st.swallow = true
		typing = true
	}
	if p.shortcut(ui, '1', {.Ctrl}) || (!typing && plain(ui, '1')) {
		set_view(st, .List)
	}
	if p.shortcut(ui, '2', {.Ctrl}) || (!typing && plain(ui, '2')) {
		set_view(st, .Grid)
	}
	if p.shortcut(ui, 'h', {.Ctrl}) || (!typing && plain(ui, '.')) {
		do_menu(st, .Toggle_Hidden)
	}
	if p.shortcut(ui, 'i', {.Ctrl}) || (!typing && plain(ui, 'i')) {
		st.inspector = !st.inspector
	}
	if p.shortcut(ui, 'c', {.Ctrl}) {
		do_menu(st, .Copy_Path)
	}
	if plain(ui, p.KEY_F5) || p.shortcut(ui, 'r', {.Ctrl}) || (!typing && plain(ui, 'r')) {
		reload(st)
		ensure_visible(st)
		note(st, "Reloaded")
	}
	if p.shortcut(ui, p.KEY_LEFT, {.Alt}) {
		go_back(st)
		sync_place(st)
	}
	if p.shortcut(ui, p.KEY_RIGHT, {.Alt}) {
		go_forward(st)
		sync_place(st)
	}
	if p.shortcut(ui, p.KEY_UP, {.Alt}) {
		go_up(st)
		sync_place(st)
	}
	if plain(ui, p.KEY_TAB) {
		st.pane = Pane((int(st.pane) + 1) % len(Pane))
	}
	if p.shortcut(ui, p.KEY_TAB, {.Shift}) {
		st.pane = Pane((int(st.pane) + len(Pane) - 1) % len(Pane))
	}
	if p.shortcut(ui, p.KEY_RETURN, {.Ctrl}) ||
	   plain(ui, KEY_MENU) ||
	   (!typing && plain(ui, 'm')) {
		open_menu(st)
		return
	}

	switch st.pane {
	case .Search:
		typed := st.swallow ? "" : p.typed_text(ui)
		st.swallow = false
		changed := false
		for b in transmute([]u8)typed {
			if b >= 0x20 {
				append(&st.filter, b)
				changed = true
			}
		}
		if plain(ui, p.KEY_BACKSPACE) && len(st.filter) > 0 {
			n := 1
			for n < len(st.filter) && st.filter[len(st.filter) - n] & 0xc0 == 0x80 {
				n += 1
			}
			resize(&st.filter, len(st.filter) - n)
			changed = true
		}
		if p.shortcut(ui, 'u', {.Ctrl}) {
			clear(&st.filter)
			changed = true
		}
		if plain(ui, p.KEY_ESCAPE) {
			// Escape cancels the whole search, the way it does in Finder.
			if len(st.filter) > 0 {
				clear(&st.filter)
				changed = true
			}
			st.pane = .Files
		}
		if changed {
			st.sel = 0
			st.top = 0
			rebuild(st)
		}
		if plain(ui, p.KEY_DOWN) {
			st.pane = .Files
		}
		if plain(ui, p.KEY_RETURN) {
			st.pane = .Files
			open_selection(st)
		}

	case .Sidebar:
		if d := key_times(ui, p.KEY_DOWN); d > 0 && len(st.places) > 0 {
			st.place_sel = min(st.place_sel + d, len(st.places) - 1)
			go_to(st, st.places[st.place_sel].path)
		}
		if d := key_times(ui, p.KEY_UP); d > 0 && len(st.places) > 0 {
			st.place_sel = max(st.place_sel - d, 0)
			go_to(st, st.places[st.place_sel].path)
		}
		if plain(ui, p.KEY_END) && len(st.places) > 0 {
			st.place_sel = len(st.places) - 1
			go_to(st, st.places[st.place_sel].path)
		}
		if plain(ui, p.KEY_HOME) && len(st.places) > 0 {
			st.place_sel = 0
			go_to(st, st.places[st.place_sel].path)
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_RIGHT) {
			st.pane = .Files
		}
		if plain(ui, p.KEY_ESCAPE) {
			st.pane = .Files
		}

	case .Files:
		n := len(st.vis)
		moved := false
		step :: proc(st: ^State, by: int) {
			st.sel = clamp(st.sel + by, 0, max(0, len(st.vis) - 1))
		}
		if d := key_times(ui, p.KEY_DOWN); d > 0 {
			step(st, d * (st.view == .Grid ? st.cols : 1))
			moved = true
		}
		if d := key_times(ui, p.KEY_UP); d > 0 {
			step(st, -d * (st.view == .Grid ? st.cols : 1))
			moved = true
		}
		if st.view == .Grid {
			if d := key_times(ui, p.KEY_RIGHT); d > 0 {
				step(st, d)
				moved = true
			}
			if d := key_times(ui, p.KEY_LEFT); d > 0 {
				step(st, -d)
				moved = true
			}
		} else {
			if plain(ui, p.KEY_RIGHT) {
				if e, ok := selected(st); ok && e.is_dir {
					go_to(st, e.path)
					sync_place(st)
				}
			}
			if plain(ui, p.KEY_LEFT) {
				go_up(st)
				sync_place(st)
			}
		}
		if plain(ui, p.KEY_PAGE_DOWN) {
			step(st, st.rows * max(1, st.cols))
			moved = true
		}
		if plain(ui, p.KEY_PAGE_UP) {
			step(st, -st.rows * max(1, st.cols))
			moved = true
		}
		if plain(ui, p.KEY_HOME) {
			st.sel = 0
			moved = true
		}
		if plain(ui, p.KEY_END) {
			st.sel = max(0, n - 1)
			moved = true
		}
		if plain(ui, p.KEY_BACKSPACE) {
			go_up(st)
			sync_place(st)
		}
		if plain(ui, p.KEY_RETURN) {
			open_selection(st)
		}
		if plain(ui, p.KEY_ESCAPE) && len(st.filter) > 0 {
			clear(&st.filter)
			rebuild(st)
		}
		if moved {
			ensure_visible(st)
		}
	}
}

set_view :: proc(st: ^State, v: View) {
	if st.view == v {
		return
	}
	st.view = v
	st.top = 0
	ensure_visible(st)
}

open_selection :: proc(st: ^State) {
	e, ok := selected(st)
	if !ok {
		return
	}
	if e.is_dir {
		go_to(st, e.path)
		sync_place(st)
		return
	}
	kit.launch({"xdg-open", e.path})
	note(st, fmt.tprintf("Opening %s", e.name))
}

// sync_place highlights the place that encloses the current directory, which
// is the longest of them that is a prefix of it.
sync_place :: proc(st: ^State) {
	best, best_len := -1, -1
	for pl, i in st.places {
		if pl.path == st.cwd || strings.has_prefix(st.cwd, pl.path == "/" ? "/" : tfmt("%s/", pl.path)) {
			if len(pl.path) > best_len {
				best, best_len = i, len(pl.path)
			}
		}
	}
	if best >= 0 {
		st.place_sel = best
	}
}

note :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = 0
}

// ---------------------------------------------------------------------------
// The context menu, as data
// ---------------------------------------------------------------------------

Menu_Action :: enum {
	None,
	Open,
	Open_Terminal,
	Copy_Path,
	Reveal_Parent,
	Get_Info,
	Toggle_Hidden,
	View_List,
	View_Grid,
}

Menu_Item :: struct {
	label:    string,
	shortcut: string,
	icon:     p.Icon,
	action:   Menu_Action,
	rule:     bool, // a separator sits above this item
	heading:  string, // a group label sits above this item
	check:    bool, // reserves the tick gutter
	ticked:   bool,
	disabled: bool,
}

menu_items :: proc(st: ^State) -> []Menu_Item {
	e, has := selected(st)
	out := make([dynamic]Menu_Item, 0, 10, context.temp_allocator)

	append(
		&out,
		Menu_Item {
			label = e.is_dir ? "Open Folder" : "Open",
			shortcut = "Enter",
			icon = e.is_dir ? ICON_FOLDER_OPEN : ICON_EXTERNAL_LINK,
			action = .Open,
			disabled = !has,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Open in Terminal",
			icon = ICON_SQUARE_TERMINAL,
			action = .Open_Terminal,
			disabled = !has,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Copy Path",
			shortcut = "Ctrl C",
			icon = ICON_COPY,
			action = .Copy_Path,
			disabled = !has,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Enclosing Folder",
			shortcut = "Backspace",
			icon = ICON_CORNER_UP_LEFT,
			action = .Reveal_Parent,
			disabled = st.cwd == "/",
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Get Info",
			shortcut = "Ctrl I",
			icon = ICON_INFO,
			action = .Get_Info,
			rule = true,
			check = true,
			ticked = st.inspector,
			disabled = !has,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "Show Hidden Files",
			shortcut = "Ctrl H",
			icon = ICON_EYE,
			action = .Toggle_Hidden,
			check = true,
			ticked = st.show_hidden,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "as List",
			shortcut = "Ctrl 1",
			icon = ICON_LIST,
			action = .View_List,
			rule = true,
			heading = "View",
			check = true,
			ticked = st.view == .List,
		},
	)
	append(
		&out,
		Menu_Item {
			label = "as Icons",
			shortcut = "Ctrl 2",
			icon = ICON_LAYOUT_GRID,
			action = .View_Grid,
			check = true,
			ticked = st.view == .Grid,
		},
	)
	return out[:]
}

menu_step :: proc(items: []Menu_Item, from, by: int) -> int {
	i := from
	for _ in 0 ..< len(items) {
		i = (i + by + len(items)) % len(items)
		if !items[i].disabled {
			return i
		}
	}
	return from
}

open_menu :: proc(st: ^State) {
	items := menu_items(st)
	st.menu_open = true
	st.menu_sel = 0
	if len(items) > 0 && items[0].disabled {
		st.menu_sel = menu_step(items, 0, 1)
	}
	// Anchor on the selected item, where a right-click would have landed.
	r := st.sel_rect
	st.menu_at = {r.x + 24, r.y + r.h - 4}
	if r.w == 0 {
		st.menu_at = {SIDEBAR_W + 32, TOOLBAR_H + HEADER_H + 8}
	}
}

// open_terminal starts a terminal in `dir`: the user's $TERMINAL when it is
// set, else Palmframe's own `term`, else foot. $TERMINAL is a command, not a
// known program, so it gets no flags of its own; it is started from a shell
// that has already changed into the folder, which every terminal honours.
// `term` and foot are both told with `--working-directory`.
open_terminal :: proc(dir: string) -> bool {
	if os.get_env("TERMINAL", context.temp_allocator) != "" {
		return kit.launch({"sh", "-c", `cd -- "$1" && exec $TERMINAL`, "sh", dir})
	}
	for bin in ([?]string{"term", "foot"}) {
		if on_path(bin) {
			return kit.launch({bin, "--working-directory", dir})
		}
	}
	return false
}

// on_path reports whether an executable of that name is on $PATH, without
// starting a process to ask.
on_path :: proc(bin: string) -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir != "" && os.exists(fmt.tprintf("%s/%s", dir, bin)) {
			return true
		}
	}
	return false
}

do_menu :: proc(st: ^State, a: Menu_Action) {
	e, has := selected(st)
	switch a {
	case .None:
	case .Open:
		open_selection(st)
	case .Open_Terminal:
		if has {
			dir := e.is_dir ? e.path : st.cwd
			if open_terminal(dir) {
				note(st, "Opened a terminal here")
			} else {
				note(st, "No terminal emulator is installed")
			}
		}
	case .Copy_Path:
		if has {
			kit.launch({"wl-copy", "--", e.path})
			note(st, fmt.tprintf("Copied %s", e.path))
		}
	case .Reveal_Parent:
		go_up(st)
		sync_place(st)
	case .Get_Info:
		st.inspector = !st.inspector
	case .Toggle_Hidden:
		st.show_hidden = !st.show_hidden
		rebuild(st)
		ensure_visible(st)
	case .View_List:
		set_view(st, .List)
	case .View_Grid:
		set_view(st, .Grid)
	}
	st.menu_open = false
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
	if st.err != "" {
		empty_state(ui, ICON_LOCK, "Not available", st.err)
	} else if len(st.entries) == 0 {
		empty_state(ui, ICON_FOLDER_OPEN, "Empty folder", "There is nothing in here.")
	} else if len(st.vis) == 0 {
		empty_state(
			ui,
			ICON_SEARCH,
			"No matches",
			tfmt("Nothing in this folder matches \"%s\".", string(st.filter[:])),
		)
	} else if st.view == .List {
		list_view(ui, st)
	} else {
		grid_view(ui, st)
	}
	p.end(ui)
	if st.inspector {
		inspector(ui, st)
	}
	p.end(ui)

	status_bar(ui, st)

	if st.menu_open {
		context_menu(ui, st)
	}
	toast(ui, st)
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

toolbar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-b border-border")
	defer p.end(ui)

	p.row(ui, "items-center gap-0.5 shrink-0")
	if tool_button(ui, "back", ICON_ARROW_LEFT, st.hpos > 0) {
		go_back(st)
		sync_place(st)
	}
	if tool_button(ui, "fwd", ICON_ARROW_RIGHT, st.hpos < len(st.history) - 1) {
		go_forward(st)
		sync_place(st)
	}
	if tool_button(ui, "up", ICON_ARROW_UP, st.cwd != "/") {
		go_up(st)
		sync_place(st)
	}
	p.end(ui)

	sc.separator(ui, .Vertical, "h-5 mx-1 shrink-0")

	breadcrumbs(ui, st)

	view_switcher(ui, st)
	search_field(ui, st)

	if tool_button(ui, "info", ICON_INFO, true, st.inspector) {
		st.inspector = !st.inspector
	}
}

tool_button :: proc(
	ui: ^p.Ctx,
	key: string,
	ic: p.Icon,
	enabled: bool,
	on := false,
) -> (
	fired: bool,
) {
	p.key(ui, key)
	base :: "flex-row size-7 shrink-0 items-center justify-center rounded-md transition cursor-pointer"
	idx := p.div(ui, base)
	if enabled {
		p.apply(ui, on ? "bg-accent text-foreground" : "hover:bg-accent text-foreground", idx)
		fired = p.clickable(ui, idx)
	} else {
		p.apply(ui, "text-muted-foreground/40", idx)
	}
	p.icon(ui, ic, "size-4")
	p.end(ui)
	return fired && enabled
}

// breadcrumbs renders the path, with the home directory folded into a single
// crumb and the middle elided when it will not fit.
breadcrumbs :: proc(ui: ^p.Ctx, st: ^State) {
	home := os.get_env("HOME", context.temp_allocator)

	Crumb :: struct {
		label: string,
		path:  string,
		icon:  p.Icon,
		home:  bool,
	}
	crumbs := make([dynamic]Crumb, 0, 12, context.temp_allocator)

	rest := st.cwd
	if home != "" && (st.cwd == home || strings.has_prefix(st.cwd, tfmt("%s/", home))) {
		append(&crumbs, Crumb{"Home", home, ICON_HOUSE, true})
		rest = st.cwd[len(home):]
	} else {
		append(&crumbs, Crumb{"Filesystem", "/", ICON_HARD_DRIVE, true})
		rest = st.cwd
	}
	acc := crumbs[0].path == "/" ? "" : crumbs[0].path
	for seg in strings.split(rest, "/", context.temp_allocator) {
		if seg == "" {
			continue
		}
		acc = tfmt("%s/%s", acc, seg)
		append(&crumbs, Crumb{seg, acc, ICON_FOLDER, false})
	}

	// Keep the first crumb, elide the middle, keep the last three.
	MAX :: 4
	elide := len(crumbs) > MAX + 1

	p.row(ui, "flex-1 min-w-0 items-center gap-0.5 overflow-hidden")
	defer p.end(ui)

	for c, i in crumbs {
		if elide && i > 0 && i < len(crumbs) - MAX {
			if i == 1 {
				p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
				p.div(ui, "flex-row h-6 px-1 items-center shrink-0")
				p.text(ui, "...", "text-[13] text-muted-foreground")
				p.end(ui)
			}
			continue
		}
		if i > 0 {
			p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
		}
		last := i == len(crumbs) - 1
		p.key(ui, c.path)
		idx := p.row(
			ui,
			"h-6 items-center gap-1.5 px-1.5 rounded-md shrink-0 cursor-pointer transition hover:bg-accent",
		)
		if p.clickable(ui, idx) {
			go_to(st, c.path)
			sync_place(st)
		}
		if c.home {
			p.icon(ui, c.icon, "size-3.5 shrink-0 text-selection")
		}
		p.text(
			ui,
			c.label,
			last \
			? "text-[13] font-semibold text-foreground whitespace-nowrap" \
			: "text-[13] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.end(ui)
	}
}

view_switcher :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	defer p.end(ui)

	seg :: proc(ui: ^p.Ctx, st: ^State, key: string, ic: p.Icon, v: View) {
		p.key(ui, key)
		on := st.view == v
		idx := p.div(
			ui,
			"flex-row h-6 w-8 items-center justify-center rounded-md transition cursor-pointer",
		)
		p.apply(
			ui,
			on \
			? "bg-background text-foreground shadow-sm" \
			: "text-muted-foreground hover:text-foreground",
			idx,
		)
		if p.clickable(ui, idx) {
			set_view(st, v)
		}
		p.icon(ui, ic, "size-3.5")
		p.end(ui)
	}
	seg(ui, st, "list", ICON_LIST, .List)
	seg(ui, st, "grid", ICON_LAYOUT_GRID, .Grid)
}

search_field :: proc(ui: ^p.Ctx, st: ^State) {
	focus := st.pane == .Search
	idx := p.row(
		ui,
		"h-7 w-[200] shrink-0 items-center gap-1.5 px-2 rounded-lg border border-input bg-background cursor-text transition",
	)
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	if p.clickable(ui, idx) {
		st.pane = .Search
		st.swallow = true
	}
	defer p.end(ui)

	p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")

	text := string(st.filter[:])
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	if text == "" {
		p.text(ui, "Search this folder", "text-[13] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.text(ui, text, "text-[13] text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	if focus {
		// palmy's own text_field owns its caret and its focus; this field is
		// driven from the pane state instead, so the caret is drawn here.
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[15] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)

	if text != "" {
		x := p.div(
			ui,
			"flex-row size-4 shrink-0 items-center justify-center rounded-full bg-muted-foreground/25 hover:bg-muted-foreground/50 cursor-pointer transition",
		)
		if p.clickable(ui, x) {
			clear(&st.filter)
			rebuild(st)
		}
		p.icon(ui, ICON_X, "size-2.5 text-background")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(
		ui,
		tfmt(
			"w-[%d] shrink-0 h-full bg-sidebar border-r border-border px-2 py-2.5 gap-px overflow-hidden",
			SIDEBAR_W,
		),
	)
	defer p.end(ui)

	group := ""
	for pl, i in st.places {
		if pl.group != group {
			group = pl.group
			p.div(ui, i == 0 ? "px-2 pt-1 pb-1.5" : "px-2 pt-3 pb-1.5")
			p.text(ui, group, "text-[11] font-semibold text-muted-foreground/80 tracking-wide")
			p.end(ui)
		}

		exact := pl.path == st.cwd
		cursor := st.pane == .Sidebar && i == st.place_sel
		inside := !exact && i == st.place_sel

		p.key(ui, pl.path)
		idx := p.row(ui, "h-[30] shrink-0 items-center gap-2 px-2 rounded-md transition cursor-pointer")
		switch {
		case exact:
			p.apply(ui, "bg-selection", idx)
		case inside:
			p.apply(ui, "bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent/70", idx)
		}
		if cursor && !exact {
			p.apply(ui, "ring-2 ring-selection/40", idx)
		}
		if p.clickable(ui, idx) {
			go_to(st, pl.path)
			st.place_sel = i
			st.pane = .Files
		}

		p.icon(ui, pl.icon, exact ? "size-4 shrink-0 text-white" : tfmt("size-4 shrink-0 %s", pl.tint))
		p.text(
			ui,
			pl.label,
			exact \
			? "flex-1 min-w-0 truncate text-[13] font-medium text-white" \
			: "flex-1 min-w-0 truncate text-[13] font-medium text-foreground",
		)
		p.end(ui)
	}

	p.spacer(ui, "flex-1")

	// A quiet footer: what the keyboard does, because this app is driven by it.
	p.col(ui, "px-2 pb-1 gap-1 shrink-0")
	hint(ui, "Tab", "switch pane")
	hint(ui, "M", "context menu")
	hint(ui, "/", "search")
	p.end(ui)
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1.5")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// List view
// ---------------------------------------------------------------------------

COL_KIND :: 128
COL_SIZE :: 84
COL_DATE :: 150

// The name column never gets squeezed out: the others drop away first.
show_kind :: proc(st: ^State) -> bool {
	return st.pane_w >= 620
}

show_date :: proc(st: ^State) -> bool {
	return st.pane_w >= 400
}

list_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-full h-full")
	defer p.end(ui)

	// Header.
	p.row(
		ui,
		tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-background border-b border-border", HEADER_H),
	)
	col_header(ui, st, "Name", .Name, 0)
	if show_kind(st) {
		col_header(ui, st, "Kind", .Kind, COL_KIND)
	}
	col_header(ui, st, "Size", .Size, COL_SIZE)
	if show_date(st) {
		col_header(ui, st, "Date Modified", .Date, COL_DATE)
	}
	p.end(ui)

	// Body.
	p.col(ui, "flex-1 min-h-0 w-full relative overflow-hidden")
	defer p.end(ui)

	focused := st.pane == .Files
	last := min(st.top + st.rows, len(st.vis))
	for row := st.top; row < last; row += 1 {
		e := st.entries[st.vis[row]]
		on := row == st.sel
		p.key(ui, tfmt("row:%s", e.name))
		idx := p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 transition", ROW_H))
		switch {
		case on && focused:
			p.apply(ui, "bg-selection", idx)
		case on:
			p.apply(ui, "bg-foreground/10", idx)
		case row % 2 == 1:
			p.apply(ui, "bg-muted/40 hover:bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			if st.sel == row && st.pane == .Files {
				open_selection(st)
			} else {
				st.sel = row
				st.pane = .Files
			}
		}
		if on {
			st.sel_rect = p.rect_of(ui, p.node_id(ui, idx))
		}

		hl := on && focused
		p.icon(ui, e.icon, hl ? "size-4 shrink-0 text-white" : tfmt("size-4 shrink-0 %s", e.tint))

		p.row(ui, "flex-1 min-w-0 items-center gap-1")
		p.text(
			ui,
			e.name,
			hl \
			? "flex-1 min-w-0 truncate text-[13] text-white" \
			: "flex-1 min-w-0 truncate text-[13] text-foreground",
		)
		if e.is_link {
			p.icon(
				ui,
				ICON_LINK,
				hl ? "size-3 shrink-0 text-white/70" : "size-3 shrink-0 text-muted-foreground",
			)
		}
		p.end(ui)

		meta := hl ? "text-[12] text-white/75 whitespace-nowrap" : "text-[12] text-muted-foreground whitespace-nowrap"
		if show_kind(st) {
			cell(
				ui,
				COL_KIND,
				.Left,
				e.kind,
				hl ? "truncate text-[12] text-white/75" : "truncate text-[12] text-muted-foreground",
			)
		}
		cell(ui, COL_SIZE, .Right, e.size_text, meta)
		if show_date(st) {
			cell(ui, COL_DATE, .Left, e.date_text, meta)
		}
		p.end(ui)
	}

	scrollbar(ui, st, f32(st.rows * ROW_H))
}

Cell_Align :: enum {
	Left,
	Right,
}

cell :: proc(ui: ^p.Ctx, w: int, align: Cell_Align, value, class: string) {
	p.row(
		ui,
		tfmt("w-[%d] shrink-0 items-center overflow-hidden %s", w, align == .Right ? "justify-end" : ""),
	)
	p.text(ui, value, class)
	p.end(ui)
}

col_header :: proc(ui: ^p.Ctx, st: ^State, label: string, key: Sort_Key, w: int) {
	active := st.sort == key
	p.key(ui, label)
	idx := p.row(ui, w == 0 ? "flex-1 min-w-0 items-center gap-1" : tfmt("w-[%d] shrink-0 items-center gap-1 %s", w, key == .Size ? "justify-end" : ""))
	p.apply(ui, "cursor-pointer", idx)
	if p.clickable(ui, idx) {
		if active {
			st.descending = !st.descending
		} else {
			st.sort = key
			st.descending = false
		}
		rebuild(st)
		ensure_visible(st)
	}
	hovered := p.is_hovered(ui, idx)
	p.text(
		ui,
		label,
		active || hovered \
		? "text-[11.5] font-semibold text-foreground whitespace-nowrap" \
		: "text-[11.5] font-medium text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	if active {
		p.icon(
			ui,
			st.descending ? ICON_CHEVRON_DOWN : ICON_CHEVRON_UP,
			"size-3 shrink-0 text-muted-foreground",
		)
	}
	p.end(ui)
}

// scrollbar is drawn rather than scrolled: the list is virtual, so palmy's own
// scroll container never sees the full content height.
scrollbar :: proc(ui: ^p.Ctx, st: ^State, view_h: f32) {
	lines := total_lines(st)
	if lines <= st.rows || view_h <= 0 {
		return
	}
	frac := f32(st.rows) / f32(lines)
	h := max(28, view_h * frac)
	travel := view_h - h
	t := f32(st.top) / f32(max(1, lines - st.rows))

	idx := p.div(ui, "absolute right-[3] w-[5] rounded-full bg-foreground/20")
	s := p.style(ui, idx)
	s.inset[p.TOP] = p.px(travel * t + 2)
	s.h = p.px(h - 4)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Icon grid
// ---------------------------------------------------------------------------

grid_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("w-full h-full p-[%d] gap-0 relative overflow-hidden", GRID_PAD))
	defer p.end(ui)

	focused := st.pane == .Files
	first := st.top * st.cols
	last := min(first + st.rows * st.cols, len(st.vis))

	for i := first; i < last; i += st.cols {
		p.row(ui, tfmt("h-[%d] shrink-0 w-full items-start", TILE_H))
		for j := i; j < min(i + st.cols, last); j += 1 {
			e := st.entries[st.vis[j]]
			on := j == st.sel
			hl := on && focused
			p.key(ui, tfmt("tile:%s", e.name))
			idx := p.col(
				ui,
				tfmt(
					"w-[%d] h-[%d] shrink-0 items-center justify-center gap-2 px-1.5 rounded-xl transition cursor-pointer",
					TILE_W,
					TILE_H - 6,
				),
			)
			switch {
			case hl:
				p.apply(ui, "bg-selection", idx)
			case on:
				p.apply(ui, "bg-foreground/10", idx)
			case:
				p.apply(ui, "hover:bg-accent/70", idx)
			}
			if p.clickable(ui, idx) {
				if st.sel == j && st.pane == .Files {
					open_selection(st)
				} else {
					st.sel = j
					st.pane = .Files
				}
			}
			if on {
				st.sel_rect = p.rect_of(ui, p.node_id(ui, idx))
			}

			p.icon(ui, e.icon, hl ? "size-9 shrink-0 text-white" : tfmt("size-9 shrink-0 %s", e.tint))
			p.text(
				ui,
				e.name,
				hl \
				? "w-full truncate text-center text-[12] text-white" \
				: "w-full truncate text-center text-[12] text-foreground",
			)
			p.end(ui)
		}
		p.end(ui)
	}

	scrollbar(ui, st, f32(st.rows * TILE_H))
}

// ---------------------------------------------------------------------------
// Inspector
// ---------------------------------------------------------------------------

inspector :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(
		ui,
		tfmt(
			"w-[%d] shrink-0 h-full bg-sidebar border-l border-border px-4 py-4 gap-4 overflow-hidden",
			INSPECTOR_W,
		),
	)
	defer p.end(ui)

	e, ok := selected(st)
	if !ok {
		p.text(ui, "Nothing selected", "text-[13] text-muted-foreground")
		return
	}

	p.col(ui, "items-center gap-2.5 shrink-0 w-full")
	p.div(ui, "flex-row size-16 items-center justify-center rounded-2xl bg-background border border-border shrink-0")
	p.icon(ui, e.icon, tfmt("size-8 %s", e.tint))
	p.end(ui)
	p.text(ui, e.name, "w-full truncate text-center text-[13.5] font-semibold")
	p.text(ui, e.kind, "text-[11.5] text-muted-foreground")
	p.end(ui)

	sc.separator(ui)

	p.col(ui, "gap-2.5 w-full shrink-0")
	field(ui, "Size", e.is_dir ? "--" : e.size_text)
	field(ui, "Modified", e.date_text)
	field(ui, "Where", parent_of(e.path))
	if e.is_link {
		field(ui, "Kind", "Alias")
	}
	p.end(ui)
}

field :: proc(ui: ^p.Ctx, label, value: string) {
	p.col(ui, "gap-0.5 w-full")
	p.text(ui, label, "text-[11] font-medium text-muted-foreground/80 tracking-wide")
	p.text(ui, value, "w-full truncate text-[12.5] text-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(
		ui,
		tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-t border-border", STATUS_H),
	)
	defer p.end(ui)

	total := 0
	for e in st.entries {
		if !e.hidden || st.show_hidden {
			total += 1
		}
	}
	count := len(st.filter) > 0 \
		? tfmt("%d of %d items", len(st.vis), total) \
		: tfmt("%d items", total)
	p.text(ui, count, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	if st.show_hidden {
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50")
		p.text(ui, "hidden shown", "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}

	p.spacer(ui, "flex-1")

	if e, ok := selected(st); ok {
		p.row(ui, "items-center gap-1.5 min-w-0")
		p.icon(ui, e.icon, tfmt("size-3 shrink-0 %s", e.tint))
		p.text(ui, e.name, "truncate text-[11.5] text-foreground max-w-[320]")
		if !e.is_dir {
			p.text(ui, "·", "text-[11.5] text-muted-foreground/50")
			p.style(ui).shrink = 0
			p.text(ui, e.size_text, "text-[11.5] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Overlays: the context menu, the empty state, the toast
// ---------------------------------------------------------------------------

MENU_W :: 248

context_menu :: proc(ui: ^p.Ctx, st: ^State) {
	items := menu_items(st)

	// A scrim, so a click anywhere else dismisses the menu the way a real
	// popup would.
	scrim := p.div(ui, "absolute inset-0 z-40")
	if p.clickable(ui, scrim) {
		st.menu_open = false
	}
	p.end(ui)

	// Enough of the height to keep the menu inside the window; the header
	// block above the items is counted first.
	h := f32(8)
	if _, ok := selected(st); ok {
		h += 48
	}
	for it in items {
		if it.rule {
			h += 9
		}
		if it.heading != "" {
			h += 22
		}
		h += 26
	}

	win := p.size(ui)
	x := clamp(st.menu_at.x, 8, max(8, win.x - MENU_W - 8))
	y := clamp(st.menu_at.y, 8, max(8, win.y - h - 8))

	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", MENU_W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(x)
	s.inset[p.TOP] = p.px(y)
	defer p.end(ui)

	sc.menu_content_open(ui)
	p.apply(ui, "shadow-lg")
	defer p.end(ui)

	if e, ok := selected(st); ok {
		p.div(ui, "flex-col px-1.5 pt-1 pb-1.5")
		p.text(ui, e.name, "w-full truncate text-[12] font-semibold text-foreground")
		p.text(ui, e.kind, "text-[11] text-muted-foreground")
		p.end(ui)
		sc.menu_separator(ui)
	}

	for it, i in items {
		if it.rule {
			sc.menu_separator(ui)
		}
		if it.heading != "" {
			sc.menu_label(ui, it.heading)
		}

		p.key(ui, it.label)
		idx := it.check ? sc.menu_check_item_open(ui) : sc.menu_item_open(ui)
		p.apply(ui, "h-[26] cursor-pointer transition", idx)
		hot := i == st.menu_sel || p.is_hovered(ui, idx)
		if it.disabled {
			p.apply(ui, "text-muted-foreground/45", idx)
		} else if i == st.menu_sel {
			p.apply(ui, "bg-selection text-white", idx)
		} else if hot {
			p.apply(ui, "bg-accent text-accent-foreground", idx)
		}
		if !it.disabled && p.clickable(ui, idx) {
			do_menu(st, it.action)
		}

		cur := i == st.menu_sel
		p.icon(
			ui,
			it.icon,
			it.disabled \
			? "size-3.5 shrink-0 text-muted-foreground/45" \
			: cur ? "size-3.5 shrink-0 text-white" : "size-3.5 shrink-0 text-muted-foreground",
		)
		p.text(ui, it.label, "flex-1 min-w-0 truncate text-[13] whitespace-nowrap")
		if it.shortcut != "" {
			// shadcn's own shortcut is `tracking-widest`, which spaces out a
			// word like "Backspace"; these are words, so they are set plain.
			p.text(
				ui,
				it.shortcut,
				cur ? "text-[11] text-white/70 whitespace-nowrap" : "text-[11] text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
		}
		if it.check && it.ticked {
			sc.menu_indicator(ui)
		}
		p.end(ui)
	}
}

empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "w-full h-full items-center justify-center gap-3 px-10")
	defer p.end(ui)

	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ic, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-[14] font-semibold text-foreground")
	p.text(ui, body, "max-w-[360] text-center text-[12.5] text-muted-foreground")
}

toast :: proc(ui: ^p.Ctx, st: ^State) {
	if st.toast == "" {
		return
	}
	if st.toast_at == 0 {
		st.toast_at = f64(p.elapsed(ui))
	}
	age := f64(p.elapsed(ui)) - st.toast_at
	if age > 2.6 {
		delete(st.toast)
		st.toast = ""
		st.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(
		ui,
		"absolute z-30 right-[16] bottom-[40] max-w-[420] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg",
	)
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-selection")
	p.text(ui, st.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
