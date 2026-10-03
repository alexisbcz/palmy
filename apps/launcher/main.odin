package main

// palmy launcher — a dmenu/rofi-class application launcher.
//
// It opens as a wlr-layer-shell overlay with exclusive keyboard focus, indexes
// the real `.desktop` files on the machine, ranks them with a fuzzy matcher and
// launches the winner detached. The part it is actually built around is the
// context menu on the selected entry: see menu.odin.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// Keysyms palmy does not name.
KEY_MENU :: 0xff67

WIN_W :: 800
WIN_H :: 600

HEADER_H :: 56
CHIPS_H :: 40
FOOTER_H :: 36
ROW_H :: 48

Sort_Mode :: enum u8 {
	Relevance,
	Name,
	Frequency,
}

// Term is one terminal emulator found on the machine. `a1`/`a2` are whatever
// has to come before the command, which differs per emulator.
Term :: struct {
	bin, name, a1, a2: string,
}

Chip :: struct {
	label: string,
	all:   bool,
	cat:   Category,
	count: int,
}

St :: struct {
	apps:       []Entry,
	hits:       [dynamic]Ranked,
	chips:      [dynamic]Chip,

	query:      [dynamic]u8,
	caret:      int,
	sel:        int,
	top:        int, // first visible row
	chip:       int,
	vis:        int, // rows that fit

	// Context menu.
	menu:       bool,
	menu_i:     int,
	sub:        Sub,
	sub_i:      int,
	spec:       []MI,
	sub_spec:   []MI,
	menu_x:     f32,
	menu_y:     f32,
	sub_x:      f32,
	sub_y:      f32,

	// Options the menu drives.
	force_term: bool,
	keep_open:  bool,
	sort:       Sort_Mode,
	pinned:     map[string]bool,

	terms:      []Term,
	have_clip:  bool,
	toast:      string,
	toast_t:    f64,
	mouse:      [2]f32,
	moved:      bool,
	started:    bool,
}

main :: proc() {
	app, err := kit.start(
		{
			title = "launcher",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
			layer = true,
			layer_level = .Overlay,
			layer_keyboard = .Exclusive,
		},
	)
	if err != "" {
		fmt.eprintfln("launcher: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_dark_theme()

	st := St {
		apps      = index_apps(),
		terms     = find_terminals(),
		have_clip = which("wl-copy") != "",
		pinned    = make(map[string]bool),
	}
	load_usage(st.apps)
	load_pins(&st)
	st.hits = make([dynamic]Ranked)
	st.chips = make([dynamic]Chip)
	build_chips(&st)
	refilter(&st)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		// The pointer only takes the selection once it has actually moved, so
		// wherever the cursor happens to be sitting when the launcher opens
		// does not decide what is selected.
		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		e := current(&st)
		if st.menu && e == nil {
			st.menu = false
		}
		if st.menu {
			st.spec = build_menu(&st, e)
			st.sub_spec = st.sub != .None ? build_submenu(&st, e, st.sub) : nil
		}

		handle_keys(ui, app, &st)

		// The spec is rebuilt after input so a checkbox or radio the user just
		// hit is already drawn in its new state.
		e = current(&st)
		if st.menu && e != nil {
			st.spec = build_menu(&st, e)
			st.sub_spec = st.sub != .None ? build_submenu(&st, e, st.sub) : nil
			if st.menu_i < 0 {
				st.menu_i = first_selectable(st.spec)
			}
		}

		build(ui, &st)

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			} else {
				p.redraw(ui)
			}
		}
	}
}

// register_dark_theme re-registers the shadcn tokens with the `.dark` values
// from the same theme the widgets were measured against, so every class string
// in this app still reads like the TSX. A launcher that floats over the desktop
// has to be dark.
register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x141414))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c1c))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1f1f1f))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x303033))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x2c2c2c))
	p.register_color("input", c(0x2c2c2c))
	p.register_color("ring", c(0x8e8e8e))
}

// ---------------------------------------------------------------------------
// Selection and filtering
// ---------------------------------------------------------------------------

current :: proc(st: ^St) -> ^Entry {
	if st.sel < 0 || st.sel >= len(st.hits) {
		return nil
	}
	return &st.apps[st.hits[st.sel].idx]
}

query_text :: proc(st: ^St) -> string {
	return string(st.query[:])
}

build_chips :: proc(st: ^St) {
	clear(&st.chips)
	append(&st.chips, Chip{label = "All", all = true, count = len(st.apps)})
	for cat in Category {
		n := 0
		for e in st.apps {
			if e.cat == cat {
				n += 1
			}
		}
		if n > 0 {
			append(&st.chips, Chip{label = CAT_LABEL[cat], cat = cat, count = n})
		}
	}
}

refilter :: proc(st: ^St) {
	clear(&st.hits)
	q := strings.to_lower(strings.trim_space(query_text(st)), context.temp_allocator)
	chip := Chip{all = true}
	if len(st.chips) > 0 {
		chip = st.chips[clamp(st.chip, 0, len(st.chips) - 1)]
	}

	for &e, i in st.apps {
		if !chip.all && e.cat != chip.cat {
			continue
		}
		r, ok := rank_entry(&e, q)
		if !ok {
			continue
		}
		r.idx = i
		// Sorting by use folds the launch count into the score, so one
		// comparator serves every mode.
		if st.sort == .Frequency {
			r.score += min(e.uses, 999) * 10_000_000
		}
		// A pin lifts an entry clear of every band.
		if st.pinned[e.id] {
			r.score += 10_000_000_000
		}
		append(&st.hits, r)
	}

	if st.sort == .Name {
		// The entry table is already in name order, so index order is name
		// order; the ranking only decided which rows survive.
		slice.sort_by(st.hits[:], proc(a, b: Ranked) -> bool {
			return a.idx < b.idx
		})
	} else {
		// Stable, so that everything the score cannot separate — an empty
		// query, most of all — stays in alphabetical order.
		slice.stable_sort_by(st.hits[:], proc(a, b: Ranked) -> bool {
			return a.score > b.score
		})
	}

	st.sel = clamp(st.sel, 0, max(0, len(st.hits) - 1))
	st.top = 0
}

// keep_visible is the whole of the scrolling model: the list renders a window
// of rows and the window follows the selection.
keep_visible :: proc(st: ^St) {
	if st.vis <= 0 {
		return
	}
	if st.sel < st.top {
		st.top = st.sel
	}
	if st.sel >= st.top + st.vis {
		st.top = st.sel - st.vis + 1
	}
	st.top = clamp(st.top, 0, max(0, len(st.hits) - st.vis))
}

move_sel :: proc(st: ^St, d: int) {
	if len(st.hits) == 0 {
		return
	}
	st.sel = clamp(st.sel + d, 0, len(st.hits) - 1)
	keep_visible(st)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// The menu owns the keyboard completely while it is open: that is what
	// makes Left/Right mean "leave"/"enter" instead of moving a caret.
	if st.menu {
		menu_keys(ui, app, st)
		return
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) {
		p.quit_app(app)
		return
	}

	// Open the menu. Three bindings, because every desktop disagrees about
	// which one a context menu answers to.
	if p.shortcut(ui, 'k', {.Ctrl}) || p.key_pressed(ui, p.KEY_F2) || p.key_pressed(ui, KEY_MENU) {
		if current(st) != nil {
			open_menu(st)
			return
		}
	}

	moved := false
	if p.key_pressed(ui, p.KEY_DOWN) || p.shortcut(ui, 'n', {.Ctrl}) {
		move_sel(st, 1)
		moved = true
	}
	if p.key_pressed(ui, p.KEY_UP) || p.shortcut(ui, 'p', {.Ctrl}) {
		move_sel(st, -1)
		moved = true
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
		move_sel(st, max(1, st.vis - 1))
		moved = true
	}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {
		move_sel(st, -max(1, st.vis - 1))
		moved = true
	}

	if p.key_pressed(ui, p.KEY_TAB) {
		d := .Shift in ui.input.mods ? -1 : 1
		if len(st.chips) > 0 {
			st.chip = (st.chip + d + len(st.chips)) % len(st.chips)
			st.sel = 0
			refilter(st)
		}
		return
	}

	if e := current(st); e != nil {
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			if .Ctrl in ui.input.mods {
				launch_entry(st, app, e, true)
			} else {
				launch_entry(st, app, e, st.force_term)
			}
			return
		}
		if p.shortcut(ui, 'i', {.Ctrl}) {
			toast(st, ui, e.path)
			return
		}
		if p.shortcut(ui, 'o', {.Ctrl}) {
			open_folder(st, ui, e)
			return
		}
		if p.shortcut(ui, 'c', {.Ctrl}) {
			copy_text(st, ui, e.exec, "Exec line")
			return
		}
		if p.shortcut(ui, 'd', {.Ctrl}) {
			toggle_pin(st, ui, e)
			return
		}
		if p.shortcut(ui, 'e', {.Ctrl}) {
			edit_entry(st, ui, e)
			return
		}
		if p.shortcut(ui, p.KEY_BACKSPACE, {.Ctrl}) {
			clear_usage(st.apps)
			refilter(st)
			toast(st, ui, "Usage history cleared")
			return
		}
	}

	if moved {
		return
	}
	edit_query(ui, st)
}

// edit_query is a text field written out by hand rather than palmy's, because
// the launcher wants the field to own the keyboard without being focusable, and
// wants a caret in the theme's own colour.
edit_query :: proc(ui: ^p.Ctx, st: ^St) {
	changed := false

	if typed := p.typed_text(ui); len(typed) > 0 {
		inject_at_elems(&st.query, st.caret, ..transmute([]u8)typed)
		st.caret += len(typed)
		changed = true
	}

	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_BACKSPACE:
			if .Ctrl in k.mods {
				continue
			}
			if st.caret > 0 {
				n := utf8_back(st.query[:], st.caret)
				remove_range(&st.query, st.caret - n, st.caret)
				st.caret -= n
				changed = true
			}
		case p.KEY_DELETE:
			if st.caret < len(st.query) {
				n := utf8_fwd(st.query[:], st.caret)
				remove_range(&st.query, st.caret, st.caret + n)
				changed = true
			}
		case p.KEY_LEFT:
			if st.caret > 0 {
				st.caret -= utf8_back(st.query[:], st.caret)
			}
		case p.KEY_RIGHT:
			if st.caret < len(st.query) {
				st.caret += utf8_fwd(st.query[:], st.caret)
			}
		case p.KEY_HOME:
			st.caret = 0
		case p.KEY_END:
			st.caret = len(st.query)
		case 'u':
			if .Ctrl in k.mods {
				clear(&st.query)
				st.caret = 0
				changed = true
			}
		case 'w':
			if .Ctrl in k.mods && st.caret > 0 {
				i := st.caret
				for i > 0 && st.query[i - 1] == ' ' {i -= 1}
				for i > 0 && st.query[i - 1] != ' ' {i -= 1}
				remove_range(&st.query, i, st.caret)
				st.caret = i
				changed = true
			}
		}
	}

	if changed {
		st.sel = 0
		st.top = 0
		refilter(st)
	}
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return max(1, at - i)
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return i - at
}

// ---------------------------------------------------------------------------
// Menu keyboard and placement
// ---------------------------------------------------------------------------

open_menu :: proc(st: ^St) {
	st.menu = true
	st.sub = .None
	st.sub_i = -1
	st.spec = nil
	st.menu_i = -1
}

close_menu :: proc(st: ^St) {
	st.menu = false
	st.sub = .None
}

active_list :: proc(st: ^St) -> []MI {
	return st.sub != .None ? st.sub_spec : st.spec
}

menu_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	items := active_list(st)
	sel := st.sub != .None ? st.sub_i : st.menu_i
	if sel < 0 || sel >= len(items) || !selectable(items[sel]) {
		sel = first_selectable(items)
	}

	if p.key_pressed(ui, p.KEY_DOWN) || p.shortcut(ui, 'n', {.Ctrl}) {
		sel = step_selection(items, sel, 1)
	}
	if p.key_pressed(ui, p.KEY_UP) || p.shortcut(ui, 'p', {.Ctrl}) {
		sel = step_selection(items, sel, -1)
	}

	// Commit the motion before anything acts on it.
	if st.sub != .None {
		st.sub_i = sel
	} else {
		st.menu_i = sel
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, p.KEY_LEFT) {
		if st.sub != .None {
			st.sub = .None
			st.sub_i = -1
		} else {
			close_menu(st)
		}
		return
	}

	enter := p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER)
	right := p.key_pressed(ui, p.KEY_RIGHT)

	if sel < 0 || sel >= len(items) {
		return
	}
	m := items[sel]

	if m.kind == .Sub && (enter || right) {
		st.sub = m.sub
		e := current(st)
		if e != nil {
			st.sub_spec = build_submenu(st, e, st.sub)
			st.sub_i = first_selectable(st.sub_spec)
		}
		return
	}
	if enter {
		invoke(st, ui, app, m)
	}
}

// place_menu works out where both panels go before any node exists, from the
// row the selection is on and the heights the spec implies. Clamping keeps the
// whole menu inside the window — there is no popup to escape into.
place_menu :: proc(st: ^St, size: [2]f32) {
	row_y := f32(HEADER_H + CHIPS_H + 8) + f32(st.sel - st.top) * ROW_H
	h := menu_height(st.spec)

	st.menu_x = 56
	st.menu_y = row_y + ROW_H - 10
	if st.menu_y + h > size.y - 10 {
		st.menu_y = size.y - 10 - h
	}
	st.menu_x = clamp(st.menu_x, 10, max(10, size.x - MENU_W - 10))
	st.menu_y = max(st.menu_y, 10)

	if st.sub != .None && st.menu_i >= 0 {
		sh := menu_height(st.sub_spec)
		st.sub_x = st.menu_x + MENU_W - 8
		st.sub_y = st.menu_y + item_offset(st.spec, st.menu_i) - PANEL_PAD
		if st.sub_x + SUB_W > size.x - 10 {
			st.sub_x = st.menu_x - SUB_W + 8
		}
		if st.sub_y + sh > size.y - 10 {
			st.sub_y = size.y - 10 - sh
		}
		st.sub_y = max(st.sub_y, 10)
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	st.toast = strings.clone(msg, context.allocator)
	st.toast_t = ui.now + 4.5
}

invoke :: proc(st: ^St, ui: ^p.Ctx, app: ^p.App, m: MI) {
	e := current(st)
	if e == nil {
		return
	}
	switch m.act {
	case .None:
	case .Launch:
		launch_entry(st, app, e, st.force_term)
	case .Launch_Term:
		launch_entry(st, app, e, true)
	case .Run_In:
		if m.arg < len(st.terms) {
			launch_argv(st, app, term_argv(st.terms[m.arg], e.exec, context.temp_allocator))
		}
	case .Desktop_Act:
		if m.arg < len(e.actions) {
			launch_argv(st, app, split_exec(e.actions[m.arg].exec, context.temp_allocator))
		}
	case .Copy_Name:
		copy_text(st, ui, e.name, "Name")
	case .Copy_Exec:
		copy_text(st, ui, e.exec, "Exec line")
	case .Copy_Id:
		copy_text(st, ui, e.id, "Desktop ID")
	case .Copy_Path:
		copy_text(st, ui, e.path, "File path")
	case .Show_Path:
		toast(st, ui, e.path)
		close_menu(st)
	case .Open_Folder:
		open_folder(st, ui, e)
	case .Edit_Entry:
		edit_entry(st, ui, e)
	case .Toggle_Term:
		st.force_term = !st.force_term
	case .Toggle_Keep:
		st.keep_open = !st.keep_open
	case .Toggle_Pin:
		toggle_pin(st, ui, e)
	case .Sort_Rel:
		st.sort = .Relevance
		refilter(st)
	case .Sort_Name:
		st.sort = .Name
		refilter(st)
	case .Sort_Freq:
		st.sort = .Frequency
		refilter(st)
	case .Clear_History:
		clear_usage(st.apps)
		refilter(st)
		toast(st, ui, "Usage history cleared")
		close_menu(st)
	}
}

// launch_entry records the launch, starts the process detached and gets out of
// the way — a launcher that lingers after opening something is a bug.
launch_entry :: proc(st: ^St, app: ^p.App, e: ^Entry, in_term: bool) {
	argv: []string
	if in_term && len(st.terms) > 0 && !e.terminal {
		argv = term_argv(st.terms[0], e.exec, context.temp_allocator)
	} else if e.terminal && len(st.terms) > 0 {
		// Terminal=true means the entry has no window of its own.
		argv = term_argv(st.terms[0], e.exec, context.temp_allocator)
	} else {
		argv = split_exec(e.exec, context.temp_allocator)
	}
	if len(argv) == 0 {
		return
	}
	e.uses += 1
	save_usage(st.apps)
	kit.launch(argv)
	if !st.keep_open {
		p.quit_app(app)
	} else {
		close_menu(st)
	}
}

launch_argv :: proc(st: ^St, app: ^p.App, argv: []string) {
	if len(argv) == 0 {
		return
	}
	kit.launch(argv)
	if !st.keep_open {
		p.quit_app(app)
	} else {
		close_menu(st)
	}
}

copy_text :: proc(st: ^St, ui: ^p.Ctx, text, what: string) {
	if !st.have_clip {
		return
	}
	kit.launch({"wl-copy", "--", text})
	toast(st, ui, fmt.tprintf("%s copied to clipboard", what))
	close_menu(st)
}

open_folder :: proc(st: ^St, ui: ^p.Ctx, e: ^Entry) {
	slash := strings.last_index_byte(e.path, '/')
	if slash <= 0 {
		return
	}
	kit.launch({"xdg-open", e.path[:slash]})
	toast(st, ui, fmt.tprintf("Opening %s", e.path[:slash]))
	close_menu(st)
}

edit_entry :: proc(st: ^St, ui: ^p.Ctx, e: ^Entry) {
	if !e.editable || len(st.terms) == 0 {
		return
	}
	cmd := fmt.tprintf("${EDITOR:-nano} '%s'", e.path)
	kit.launch(term_argv(st.terms[0], cmd, context.temp_allocator))
	toast(st, ui, "Opened in editor")
	close_menu(st)
}

toggle_pin :: proc(st: ^St, ui: ^p.Ctx, e: ^Entry) {
	if st.pinned[e.id] {
		delete_key(&st.pinned, e.id)
		toast(st, ui, fmt.tprintf("%s unpinned", e.name))
	} else {
		st.pinned[e.id] = true
		toast(st, ui, fmt.tprintf("%s pinned to the top", e.name))
	}
	save_pins(st)
	refilter(st)
}

// ---------------------------------------------------------------------------
// Terminals, clipboard, pins
// ---------------------------------------------------------------------------

which :: proc(bin: string) -> string {
	for dir in ([?]string{"/usr/bin", "/usr/local/bin", "/bin"}) {
		path := fmt.tprintf("%s/%s", dir, bin)
		if os.exists(path) {
			return strings.clone(path, context.allocator)
		}
	}
	if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		path := fmt.tprintf("%s/.local/bin/%s", home, bin)
		if os.exists(path) {
			return strings.clone(path, context.allocator)
		}
	}
	return ""
}

find_terminals :: proc() -> []Term {
	cands := [?]Term {
		{bin = "ghostty", name = "Ghostty", a1 = "-e"},
		{bin = "foot", name = "Foot"},
		{bin = "alacritty", name = "Alacritty", a1 = "-e"},
		{bin = "kitty", name = "Kitty"},
		{bin = "wezterm", name = "WezTerm", a1 = "start", a2 = "--"},
		{bin = "xterm", name = "xterm", a1 = "-e"},
	}
	out := make([dynamic]Term)
	for c in cands {
		if which(c.bin) != "" {
			append(&out, c)
		}
	}
	return out[:]
}

term_argv :: proc(t: Term, cmd: string, allocator := context.allocator) -> []string {
	a := make([dynamic]string, allocator)
	append(&a, t.bin)
	if t.a1 != "" {
		append(&a, t.a1)
	}
	if t.a2 != "" {
		append(&a, t.a2)
	}
	append(&a, "sh")
	append(&a, "-c")
	append(&a, strings.clone(cmd, allocator))
	return a[:]
}

pins_path :: proc(allocator := context.allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.concatenate({home, "/.cache/palmy-launcher/pinned"}, allocator)
}

load_pins :: proc(st: ^St) {
	path := pins_path(context.temp_allocator)
	if path == "" {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		id := strings.trim_space(line)
		if id != "" {
			st.pinned[id] = true
		}
	}
}

save_pins :: proc(st: ^St) {
	path := pins_path(context.temp_allocator)
	if path == "" {
		return
	}
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir)
	b := strings.builder_make(context.temp_allocator)
	for id in st.pinned {
		strings.write_string(&b, id)
		strings.write_byte(&b, '\n')
	}
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(b))
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	list_h := size.y - HEADER_H - CHIPS_H - FOOTER_H - 16
	st.vis = max(1, int(list_h / ROW_H))
	keep_visible(st)

	search_bar(ui, st)
	chip_bar(ui, st)
	result_list(ui, st)
	footer(ui, st)

	if st.menu && len(st.spec) > 0 {
		place_menu(st, size)

		// A scrim, so the menu reads as the thing with the keyboard. It takes
		// no input of its own, so hover still reaches the panels above it.
		scrim := p.div(ui, "absolute inset-0 bg-background/55 z-40")
		p.end(ui)
		_ = scrim

		hov := render_menu(
			ui,
			st.spec,
			st.menu_x,
			st.menu_y,
			MENU_W,
			st.menu_i,
			st.sub != .None,
			"root-menu",
		)
		if hov >= 0 && st.moved && st.sub == .None {
			st.menu_i = hov
		}

		if st.sub != .None && len(st.sub_spec) > 0 {
			shov := render_menu(
				ui,
				st.sub_spec,
				st.sub_x,
				st.sub_y,
				SUB_W,
				st.sub_i,
				false,
				"sub-menu",
			)
			if shov >= 0 && st.moved {
				st.sub_i = shov
			}
		}
	}
}

search_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.icon(ui, IC_SEARCH, "size-[18] shrink-0 text-muted-foreground")

	// The field: one text run plus a caret placed by measuring the prefix.
	p.row(ui, "flex-1 h-full items-center overflow-hidden")
	txt := query_text(st)
	if len(txt) == 0 {
		p.text(ui, "Search applications…", "text-base text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, txt, "text-base whitespace-nowrap")
	}
	p.style(ui).shrink = 0

	// The caret is the only thing that animates, and it stops while the menu
	// has the keyboard — an idle palmy window costs nothing.
	caret_x := p.text_width(ui.fonts, txt[:clamp(st.caret, 0, len(txt))], 16, .Sans, .Regular)
	if !st.menu {
		ui.animating = true
	}
	if !st.menu && math.mod_f32(f32(ui.now), 1.1) < 0.62 {
		car := p.div(ui, "absolute w-[2] rounded-full bg-foreground")
		cs := p.style(ui, car)
		cs.inset[p.LEFT] = p.px(caret_x)
		cs.inset[p.TOP] = p.px(18)
		cs.h = p.px(20)
		p.end(ui)
	}
	p.end(ui)

	// Result count, and the mode the options have put the launcher in.
	p.row(ui, "shrink-0 items-center gap-2")
	if st.force_term {
		sc.badge(ui, "Terminal", .Secondary)
	}
	if st.keep_open {
		sc.badge(ui, "Stay open", .Secondary)
	}
	if st.sort != .Relevance {
		sc.badge(ui, st.sort == .Name ? "A–Z" : "Most used", .Outline)
	}
	p.textf(
		ui,
		"text-xs text-muted-foreground whitespace-nowrap",
		"%d of %d",
		len(st.hits),
		len(st.apps),
	)
	p.style(ui).shrink = 0
	p.end(ui)
}

chip_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[40] shrink-0 items-center gap-1.5 px-3 border-b border-border")
	defer p.end(ui)

	for c, i in st.chips {
		p.key(ui, c.label)
		on := i == st.chip
		idx := p.div(
			ui,
			"flex-row shrink-0 items-center gap-1.5 h-6 px-2 rounded-md border transition",
		)
		p.apply(
			ui,
			on \
			? "bg-accent border-foreground/15 text-foreground" \
			: "border-transparent text-muted-foreground hover:bg-muted",
			idx,
		)
		if p.clickable(ui, idx) {
			st.chip = i
			st.sel = 0
			refilter(st)
		}
		p.text(ui, c.label, "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d", c.count)
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.spacer(ui)
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.text(ui, "Filter", "text-[11] text-muted-foreground whitespace-nowrap")
	sc.kbd(ui, "Tab")
	p.end(ui)
}

result_list :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-full flex-1 min-h-0 p-2 gap-0 overflow-hidden")
	defer p.end(ui)

	if len(st.hits) == 0 {
		empty_state(ui, st)
		return
	}

	last := min(st.top + st.vis, len(st.hits))
	for i in st.top ..< last {
		r := st.hits[i]
		e := &st.apps[r.idx]
		p.key(ui, e.id)
		result_row(ui, st, e, r, i == st.sel)
	}

	// A hairline scrollbar: the list is a window over the results, so the
	// thumb is derived from that window rather than from a scroll offset.
	if len(st.hits) > st.vis {
		track := f32(st.vis) * ROW_H - 8
		th := max(24, track * f32(st.vis) / f32(len(st.hits)))
		frac := f32(st.top) / f32(max(1, len(st.hits) - st.vis))
		bar := p.div(ui, "absolute w-[3] rounded-full bg-border")
		bs := p.style(ui, bar)
		bs.position = .Absolute
		bs.inset[p.RIGHT] = p.px(2)
		bs.inset[p.TOP] = p.px(4 + (track - th) * frac)
		bs.h = p.px(th)
		p.end(ui)
	}
}

result_row :: proc(ui: ^p.Ctx, st: ^St, e: ^Entry, r: Ranked, sel: bool) {
	idx := p.div(ui, "flex-row w-full shrink-0 h-[48] items-center gap-3 px-2 rounded-lg transition")
	p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		// Clicking a row launches it, the way rofi's mouse does.
		launch_entry(st, ui.app, e, st.force_term)
	}
	if !st.menu && st.moved && p.is_hovered(ui, idx) {
		for h, i in st.hits {
			if h.idx == r.idx {
				st.sel = i
				break
			}
		}
	}
	defer p.end(ui)

	if sel {
		bar := p.div(ui, "absolute w-[3] rounded-full bg-primary")
		bs := p.style(ui, bar)
		bs.inset[p.LEFT] = p.px(0)
		bs.inset[p.TOP] = p.px(13)
		bs.h = p.px(22)
		p.end(ui)
	}

	// There is no image loading in palmy, so the real icon theme is out of
	// reach; a glyph chosen from the entry's category is honest about that and
	// still gives the row an anchor.
	p.div(
		ui,
		"size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border",
	)
	p.icon(ui, entry_icon(e), sel ? "size-[18] text-foreground" : "size-[18] text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px overflow-hidden")
	runs(ui, e.name, r.name, "text-sm whitespace-nowrap", sel)
	if e.comment != "" {
		runs(ui, e.comment, r.note, "text-xs text-muted-foreground whitespace-nowrap", false)
	}
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	if st.pinned[e.id] {
		p.icon(ui, IC_PIN, "size-3.5 shrink-0 text-muted-foreground")
	}
	if e.uses > 0 {
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d×", e.uses)
		p.style(ui).shrink = 0
	}
	p.text(ui, CAT_LABEL[e.cat], "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if sel {
		sc.kbd(ui, "Enter")
	}
	p.end(ui)
}

// runs draws a string with the matched bytes picked out, which is the only way
// a fuzzy list stays legible: you can see why a row is there.
runs :: proc(ui: ^p.Ctx, s: string, h: Hit, base: string, strong: bool) {
	plain := strong ? strings.concatenate({base, " font-medium"}, context.temp_allocator) : base
	if !hit_any(h) || !is_ascii(s) {
		p.text(ui, s, plain)
		p.style(ui).shrink = 0
		return
	}

	p.row(ui, "shrink-0 items-baseline")
	defer p.end(ui)

	dim := strings.concatenate({base, " text-muted-foreground"}, context.temp_allocator)
	hot := strings.concatenate({base, " text-foreground font-semibold"}, context.temp_allocator)

	i := 0
	for i < len(s) {
		on := hit_at(h, i)
		j := i
		for j < len(s) && hit_at(h, j) == on {
			j += 1
		}
		p.text(ui, s[i:j], on ? hot : dim)
		p.style(ui).shrink = 0
		i = j
	}
}

is_ascii :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

empty_state :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)

	p.div(
		ui,
		"size-12 flex-row items-center justify-center rounded-full bg-muted ring-1 ring-border",
	)
	p.icon(ui, IC_SEARCH, "size-5 text-muted-foreground")
	p.end(ui)

	p.text(ui, "No applications match", "text-sm font-medium")
	q := strings.trim_space(query_text(st))
	if q != "" {
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap",
			"Nothing in %s is called “%s”",
			st.chips[clamp(st.chip, 0, len(st.chips) - 1)].label,
			q,
		)
	} else {
		p.text(ui, "This category is empty", "text-xs text-muted-foreground")
	}

	p.row(ui, "items-center gap-1.5 pt-1")
	sc.kbd(ui, "Ctrl")
	sc.kbd(ui, "U")
	p.text(ui, "clear the search", "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[36] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
		return
	}

	hint(ui, "Up", "Down", "Move")
	hint(ui, "Enter", "", "Open")
	hint(ui, "Ctrl", "Enter", "Terminal")
	hint(ui, "Ctrl", "K", "Menu")
	p.spacer(ui)
	hint(ui, "Esc", "", "Close")
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// entry_icon picks a glyph. The category is the fallback; a handful of names
// are recognisable enough to deserve their own.
entry_icon :: proc(e: ^Entry) -> p.Icon {
	n := e.lower
	switch {
	case has_any(n, "terminal", "console", "ghostty", "foot", "alacritty", "kitty"):
		return IC_TERMINAL
	case has_any(n, "files", "nautilus", "thunar", "dolphin", "nemo"):
		return IC_FOLDER
	case has_any(n, "browser", "firefox", "chromium", "chrome", "web"):
		return IC_GLOBE
	case has_any(n, "mail", "thunderbird"):
		return IC_MAIL
	case has_any(n, "music", "spotify", "audio", "rhythmbox"):
		return IC_MUSIC
	case has_any(n, "calculator", "calc"):
		return IC_CALCULATOR
	case has_any(n, "monitor", "system", "htop", "btop", "task"):
		return IC_CPU
	case has_any(n, "image", "photo", "picture", "gimp", "viewer"):
		return IC_IMAGE
	case has_any(n, "keyboard", "input"):
		return IC_KEYBOARD
	case has_any(n, "network", "wifi", "bluetooth"):
		return IC_NETWORK
	case has_any(n, "color", "theme", "appearance", "wallpaper"):
		return IC_PALETTE
	case has_any(n, "code", "editor", "vim", "studio"):
		return IC_CODE
	}
	switch e.cat {
	case .Dev:
		return IC_CODE
	case .Web:
		return IC_GLOBE
	case .Media:
		return IC_FILM
	case .Office:
		return IC_BOOK
	case .System:
		return IC_SETTINGS
	case .Utility:
		return IC_WRENCH
	case .Game:
		return IC_GAMEPAD
	case .Other:
		return IC_PACKAGE
	}
	return IC_PACKAGE
}

has_any :: proc(s: string, needles: ..string) -> bool {
	for n in needles {
		if strings.contains(s, n) {
			return true
		}
	}
	return false
}
