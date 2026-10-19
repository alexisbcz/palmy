// start.odin — the start menu: every application, one click or one key away.
//
// Opened by a lone tap of Super, by clicking the Palmy button at the left
// of the bar, or by pushing the pointer into that corner and clicking. It
// drops from the button:
//
//     ┌──────────────────────────────────────────────┐
//     │ ⌕  Type to search apps, settings and files    │
//     │                                              │
//     │ Pinned                            All apps › │
//     │  [T]   [F]   [W]   [M]   [D]   [S]           │
//     │  Term  Files Web   Mail  Docs  Sheets        │
//     │ Recent                                       │
//     │  [D] report.md        [T] Terminal           │
//     │──────────────────────────────────────────────│
//     │ (A) Alex · Switch identity           ⚙   ⏻   │
//     └──────────────────────────────────────────────┘
//
// Typing anything searches at once: applications through the same matcher
// the launcher uses (kit:appindex), then the Settings pages a word names
// ("dark", "wifi", "password"), then recent files. Enter opens the selection;
// the arrows move it across the grid and down the lists; Escape clears the
// query, then leaves All apps, then closes.
//
// Why the compositor draws it rather than a client (the launcher is one):
//   - latency: it is on screen in the frame that handles the key — no
//     process to start, no fonts to load, no .desktop files to parse (the
//     index is kept between openings and rescanned only when the
//     applications directory changes);
//   - robustness: it works when the launcher binary is broken or missing,
//     when every client has crashed, when the system is out of processes —
//     and Log out is in it;
//   - keyboard focus: like the window menu, it takes the keyboard for as long
//     as it is open and hands it back to the window that had it, with no
//     layer-shell exclusive-focus negotiation and no race with the window
//     that is mapping as it opens.
// The launcher keeps its place (Super+Space) as the type-only power tool,
// over the same index, history and pins.
package wm

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"
import ai "kit:appindex"
import p "palmy:."

SM_W :: 640
SM_H :: 612
SM_PAD :: 18
SM_SEARCH_H :: 44
SM_FOOT_H :: 62
SM_COLS :: 6
SM_CELL_H :: 88
SM_ROW_H :: 40
SM_RECENT_H :: 48

Start_Page :: enum u8 {
	Home,
	All,
}

Start_Hit_Kind :: enum u8 {
	App, // idx: entry
	File, // idx: recent file
	Setting, // idx: SETTINGS_PAGES row
	All_Btn,
	Back_Btn,
	Identity,
	Settings_Btn,
	Power_Btn,
}

Start_Hit :: struct {
	kind:  Start_Hit_Kind,
	rect:  p.Rect,
	idx:   int,
	nav:   bool, // reachable with the arrow keys
}

Start_Menu :: struct {
	open:      bool,
	out:       int,
	page:      Start_Page,
	query:     strings.Builder,
	sel:       int, // index into hits of the keyboard selection, -1 none
	sel_auto:  bool, // the selection was put there, not moved by a key
	hover:     int,
	scroll:    f32,
	scroll_max: f32,
	rect:      p.Rect,
	body:      p.Rect,
	hits:      [dynamic]Start_Hit,
	opened_at: f64,

	// The index: entries live in `arena`, rebuilt when the applications
	// directories change.
	arena:     virtual.Arena,
	al:        mem.Allocator,
	indexed:   bool,
	mtime:     i64,
	entries:   []ai.Entry,
	pins:      [dynamic]string, // in `al`
	bar_pins:  [dynamic]string,
	files:     []ai.Recent_File,
	pid_entry: map[int]int, // client pid -> entry, for windows

	// Search results, rebuilt when the query changes.
	res_apps:  [dynamic]int,
	res_set:   [dynamic]int,
	res_files: [dynamic]int,
	res_for:   string,
	res_top:   int, // the best app's score
	best_set:  bool, // a settings page is a better answer than any app
}

start: Start_Menu

// SETTINGS_PAGES are the pages of apps/settings a search can land on, with
// the words people use for what is on them.
Settings_Page :: struct {
	page:  string,
	title: string,
	words: string,
	icon:  p.Icon,
}

SETTINGS_PAGES := [?]Settings_Page {
	{"appearance", "Appearance", "appearance dark light mode theme accent colour color wallpaper background", ai.ICON_PALETTE},
	{"appearance", "Wallpaper", "wallpaper background desktop picture image", ai.ICON_IMAGE},
	{"displays", "Displays", "display displays monitor screen resolution scale output", ai.ICON_MONITOR},
	{"keyboard", "Keyboard", "keyboard layout language input repeat typing azerty qwerty", ai.ICON_KEYBOARD},
	{"mouse", "Mouse & touchpad", "mouse touchpad trackpad pointer natural scrolling scroll tap click speed left-handed", ai.ICON_MOUSE_POINTER_2},
	{"sound", "Sound", "sound audio volume speaker microphone output input mute", ai.ICON_VOLUME_2},
	{"network", "Network", "network wifi wi-fi wireless ethernet internet ip connection", ai.ICON_WIFI},
	{"datetime", "Date & time", "date time clock time zone timezone", ai.ICON_CLOCK},
	{"users", "Users & passwords", "user users account password passwd login", ai.ICON_USERS},
	{"updates", "Software updates", "software update updates upgrade packages palm", ai.ICON_REFRESH_CW},
	{"about", "About this computer", "about system version kernel hardware memory cpu disk computer", ai.ICON_INFO},
}

start_active :: proc() -> bool {
	return start.open
}

// ---------------------------------------------------------------------------
// The index
// ---------------------------------------------------------------------------

// start_index_ensure (re)reads the applications when they changed, and the
// launch history and pins every time it is asked to with `fresh` (which
// opening the menu does: another program — the launcher — may have written
// them since).
start_index_ensure :: proc(fresh := false) {
	fresh := fresh
	mt := ai.index_mtime()
	if !start.indexed || mt != start.mtime {
		if start.indexed {
			virtual.arena_destroy(&start.arena)
		}
		if virtual.arena_init_growing(&start.arena) != nil {
			return
		}
		start.al = virtual.arena_allocator(&start.arena)
		start.entries = ai.index_apps(start.al)
		start.indexed = true
		start.mtime = mt
		start.pins = {}
		start.bar_pins = {}
		clear(&start.pid_entry)
		fresh = true
	}
	if fresh {
		for &e in start.entries {
			e.uses, e.last = 0, 0
		}
		ai.load_usage(start.entries)
		start.pins = ai.pins_or_default(.Start, start.entries, start.al)
		start.bar_pins = ai.pins_or_default(.Bar, start.entries, start.al)
	}
}

// window_entry is the application a window belongs to: its client's program
// (SO_PEERCRED's pid, then /proc/<pid>/exe) looked up by Exec, else its
// app_id as a desktop id or a program name.
window_entry :: proc(t: ^Toplevel) -> int {
	if t == nil {
		return -1
	}
	start_index_ensure()
	pid := t.client != nil ? t.client.pid : 0
	if pid > 0 {
		if i, ok := start.pid_entry[pid]; ok {
			return i
		}
		buf: [512]u8
		path := fmt.tprintf("/proc/%d/exe", pid)
		i := -1
		if n, err := os_readlink(path, buf[:]); err && n > 0 {
			i = ai.find_program(start.entries, string(buf[:n]))
		}
		if i < 0 && t.app_id != "" {
			i = app_id_entry(t.app_id)
		}
		start.pid_entry[pid] = i
		return i
	}
	return app_id_entry(t.app_id)
}

@(private = "file")
app_id_entry :: proc(app_id: string) -> int {
	if app_id == "" {
		return -1
	}
	if i := ai.find_id(start.entries, app_id); i >= 0 {
		return i
	}
	name := strings.trim_prefix(strings.trim_prefix(app_id, "palmy-"), "palm-")
	if i := ai.find_program(start.entries, name); i >= 0 {
		return i
	}
	return -1
}

@(private = "file")
os_readlink :: proc(path: string, buf: []u8) -> (int, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	n, err := linux.readlink(cpath, buf)
	return n, err == .NONE
}

// entry_running says whether a window of this entry is mapped anywhere.
entry_running :: proc(s: ^Server, idx: int) -> (^Toplevel, bool) {
	best: ^Toplevel
	for t in s.stack {
		if t.mapped && window_entry(t) == idx {
			best = t // the stack is bottom to top: the last is the topmost
		}
	}
	return best, best != nil
}

// ---------------------------------------------------------------------------
// Opening and closing
// ---------------------------------------------------------------------------

start_toggle :: proc(s: ^Server) {
	if start.open {
		start_close(s)
	} else {
		start_open(s)
	}
}

start_open :: proc(s: ^Server) {
	if session.kiosk {
		return
	}
	menu_close(s)
	if ov.open {
		overview_close(s)
	}
	start_index_ensure(fresh = true)
	if start.files != nil {
		for f in start.files {
			delete(f.path)
		}
		delete(start.files)
	}
	start.files = ai.recent_files(8)
	start.open = true
	start.out = s.cur_out
	start.page = .Home
	strings.builder_reset(&start.query)
	start.sel = -1
	start.sel_auto = true
	start.hover = -1
	start.scroll = 0
	start.opened_at = wall_now()
	start.res_for = ""
	s.dirty = true
}

start_close :: proc(s: ^Server) {
	if !start.open {
		return
	}
	start.open = false
	clear(&start.hits)
	s.dirty = true
}

// ---------------------------------------------------------------------------
// Doing things
// ---------------------------------------------------------------------------

// start_launch opens an entry (with a file, when one is given), records it,
// and closes the menu.
start_launch :: proc(s: ^Server, idx: int, file := "", action := -1) {
	if idx < 0 || idx >= len(start.entries) {
		return
	}
	e := &start.entries[idx]
	argv: []string
	switch {
	case action >= 0 && action < len(e.actions):
		argv = ai.split_exec(e.actions[action].exec, context.temp_allocator)
	case file != "":
		argv = ai.exec_with_file(e, file, context.temp_allocator)
	case:
		argv = ai.split_exec(e.exec, context.temp_allocator)
	}
	if len(argv) == 0 {
		return
	}
	if e.terminal {
		wrapped := make([dynamic]string, context.temp_allocator)
		append(&wrapped, "term", "-e")
		append(&wrapped, ..argv)
		argv = wrapped[:]
	}
	ix.launch_at = wall_now()
	if _, ok := spawn(s, argv); ok {
		ai.note_launch(start.entries, idx)
	}
	start_close(s)
}

start_open_file :: proc(s: ^Server, fi: int) {
	if fi < 0 || fi >= len(start.files) {
		return
	}
	f := start.files[fi]
	if i := ai.opener_for(start.entries, f.path); i >= 0 {
		start_launch(s, i, f.path)
		return
	}
	start_open_folder(s, fi)
}

start_open_folder :: proc(s: ^Server, fi: int) {
	if fi < 0 || fi >= len(start.files) {
		return
	}
	f := start.files[fi]
	dir := f.path
	if sl := strings.last_index_byte(dir, '/'); sl > 0 {
		dir = dir[:sl]
	}
	ix.launch_at = wall_now()
	spawn(s, {"files", dir})
	start_close(s)
}

start_open_setting :: proc(s: ^Server, si: int) {
	if si < 0 || si >= len(SETTINGS_PAGES) {
		return
	}
	ix.launch_at = wall_now()
	spawn(s, {"settings", SETTINGS_PAGES[si].page})
	start_close(s)
}

start_toggle_pin :: proc(s: ^Server, which: ai.Pin_List, idx: int) {
	if idx < 0 || idx >= len(start.entries) {
		return
	}
	start_index_ensure()
	id := start.entries[idx].id
	list := which == .Start ? &start.pins : &start.bar_pins
	on := ai.toggle_pin(which, list, id, start.al)
	name := start.entries[idx].name
	where_ := which == .Start ? "Start" : "the bar"
	toast(s, on ? fmt.tprintf("%s pinned to %s", name, where_) : fmt.tprintf("%s unpinned from %s", name, where_))
	s.dirty = true
}

start_pinned :: proc(which: ai.Pin_List, idx: int) -> bool {
	if idx < 0 || idx >= len(start.entries) {
		return false
	}
	list := which == .Start ? start.pins[:] : start.bar_pins[:]
	return ai.pin_index(list, start.entries[idx].id) >= 0
}

// start_activate runs a hit: the thing a click or Enter on it means.
start_activate :: proc(s: ^Server, h: Start_Hit) {
	switch h.kind {
	case .App:
		start_launch(s, h.idx)
	case .File:
		start_open_file(s, h.idx)
	case .Setting:
		start_open_setting(s, h.idx)
	case .All_Btn:
		start.page = .All
		start.scroll = 0
		start.sel = -1
		start.sel_auto = true
	case .Back_Btn:
		start.page = .Home
		start.scroll = 0
		start.sel = -1
		start.sel_auto = true
	case .Identity:
		ix.launch_at = wall_now()
		spawn(s, {"accounts"})
		start_close(s)
	case .Settings_Btn:
		ix.launch_at = wall_now()
		spawn(s, {"settings"})
		start_close(s)
	case .Power_Btn:
		start_power_menu(s, h.rect)
	}
	s.dirty = true
}

// start_context opens the menu for a hit: an app's verbs and its pins, or a
// file's.
start_context :: proc(s: ^Server, h: Start_Hit, x, y: int) {
	if menu_app == nil {
		return
	}
	switch h.kind {
	case .App:
		menu_close(s)
		it := &menu.items
		e := &start.entries[h.idx]
		menu_add(it, "Open", .Start_Open, arg = h.idx)
		for a, ai_ in e.actions {
			if ai_ >= 15 {
				break
			}
			menu_add_owned(it, a.name, .Start_Action, arg = h.idx * 16 + ai_)
		}
		menu_add_sep(it)
		menu_add(it, start_pinned(.Start, h.idx) ? "Unpin from Start" : "Pin to Start", .Start_Pin, arg = h.idx)
		menu_add(it, start_pinned(.Bar, h.idx) ? "Unpin from bar" : "Pin to bar", .Bar_Pin, arg = h.idx)
		menu_place(s, x, y)
	case .File:
		menu_close(s)
		it := &menu.items
		menu_add(it, "Open", .Start_File_Open, arg = h.idx)
		if _, ok := cfg_which("files"); ok {
			menu_add(it, "Show in Files", .Start_File_Folder, arg = h.idx)
		}
		menu_place(s, x, y)
	case .Setting, .All_Btn, .Back_Btn, .Identity, .Settings_Btn, .Power_Btn:
	}
}

// start_power_menu is the power button's menu. Only what works on this
// machine is offered (UX.md P1-3). Lock, Restart and Shut down need
// palm-login (it checks the lock's password, and only root may power the
// machine off): a session it started has PALM_SESSION_SOCK, and gets all
// three (locker.odin, power.odin). Without it, a bare-metal session can still
// end itself, which hands the seat back to the login screen.
start_power_menu :: proc(s: ^Server, anchor: p.Rect) {
	menu_close(s)
	start_power_items(s, &menu.items)
	h := menu_height(menu.items[:])
	w := menu_width(menu_app, menu.items[:])
	menu_place(s, int(anchor.x + anchor.w - w), int(anchor.y - h - 6))
	menu.hover = 0
}

start_power_items :: proc(s: ^Server, it: ^[dynamic]Menu_Item) {
	if power_offered() {
		menu_add(it, "Lock", .Lock_Screen, key_for_act(s, .Session, cfg_session_id("lock")))
		menu_add_sep(it)
		menu_add(it, "Log out…", .Logout)
		menu_add(it, "Restart…", .Power_Intent, arg = 0)
		menu_add(it, "Shut down…", .Power_Intent, arg = 1)
	} else if session.bare {
		menu_add(it, "Log out", .Logout)
		menu_add_sep(it)
		menu_add(it, "Restart or shut down from the login screen", .None, disabled = true)
	} else {
		menu_add(it, "Log out", .Logout)
		menu_add(it, "Restart", .Power_Intent, arg = 0)
		menu_add(it, "Shut down", .Power_Intent, arg = 1)
	}
}

// ---------------------------------------------------------------------------
// Searching
// ---------------------------------------------------------------------------

start_query :: proc() -> string {
	return strings.to_string(start.query)
}

start_search :: proc() {
	q := strings.to_lower(strings.trim_space(start_query()), context.temp_allocator)
	if q == start.res_for {
		return
	}
	delete(start.res_for)
	start.res_for = strings.clone(q)
	clear(&start.res_apps)
	clear(&start.res_set)
	clear(&start.res_files)
	if q == "" {
		return
	}
	Scored :: struct {
		idx:   int,
		score: int,
	}
	apps := make([dynamic]Scored, context.temp_allocator)
	for &e, i in start.entries {
		if r, ok := ai.rank_entry(&e, q); ok {
			append(&apps, Scored{i, r.score})
		}
	}
	// Insertion sort, stable: the index is in name order, so equal scores
	// stay alphabetical.
	for i in 1 ..< len(apps) {
		v := apps[i]
		j := i - 1
		for j >= 0 && apps[j].score < v.score {
			apps[j + 1] = apps[j]
			j -= 1
		}
		apps[j + 1] = v
	}
	for a in apps[:min(len(apps), 8)] {
		append(&start.res_apps, a.idx)
	}
	start.res_top = len(apps) > 0 ? apps[0].score : 0
	if _, ok := cfg_which("settings"); ok {
		for pg, i in SETTINGS_PAGES {
			if len(start.res_set) >= 3 {
				break
			}
			if strings.contains(strings.to_lower(pg.title, context.temp_allocator), q) || words_match(pg.words, q) {
				append(&start.res_set, i)
			}
		}
	}
	// "dark" is a word on the Appearance page and a scattered match in
	// "Calendar": when no app name starts a word with the query, a settings
	// page that does is the better first answer.
	start.best_set = len(start.res_set) > 0 && (len(start.res_apps) == 0 || start.res_top < ai.BAND_WORD)
	for f, i in start.files {
		if len(start.res_files) >= 4 {
			break
		}
		if strings.contains(strings.to_lower(f.name, context.temp_allocator), q) {
			append(&start.res_files, i)
		}
	}
}

// words_match is true when every word of the query starts a word of the
// list: "nat scr" finds natural scrolling.
@(private = "file")
words_match :: proc(words, q: string) -> bool {
	qs := strings.fields(q, context.temp_allocator)
	if len(qs) == 0 {
		return false
	}
	ws := strings.fields(words, context.temp_allocator)
	for qw in qs {
		found := false
		for w in ws {
			if strings.has_prefix(w, qw) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

start_nav_hits :: proc() -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for h, i in start.hits {
		if h.nav {
			append(&out, i)
		}
	}
	return out[:]
}

// start_move moves the keyboard selection: Left/Right step through the
// items in order, Up/Down go to the nearest item in the row above or below,
// which is what a grid and a list both want.
start_move :: proc(dx, dy: int) {
	nav := start_nav_hits()
	if len(nav) == 0 {
		return
	}
	cur := -1
	for n, k in nav {
		if n == start.sel {
			cur = k
		}
	}
	if cur < 0 {
		start.sel = nav[0]
		start.sel_auto = false
		return
	}
	if dx != 0 {
		k := clamp(cur + dx, 0, len(nav) - 1)
		start.sel = nav[k]
		start.sel_auto = false
		return
	}
	r := start.hits[start.sel].rect
	cx := r.x + r.w / 2
	best := -1
	best_d := f32(1e9)
	for n in nav {
		h := start.hits[n].rect
		below := h.y >= r.y + r.h - 1
		above := h.y + h.h <= r.y + 1
		if (dy > 0 && !below) || (dy < 0 && !above) {
			continue
		}
		vy := dy > 0 ? h.y - r.y : r.y - h.y
		d := vy * 4 + abs((h.x + h.w / 2) - cx)
		if d < best_d {
			best_d = d
			best = n
		}
	}
	if best >= 0 {
		start.sel = best
		start.sel_auto = false
	}
}

start_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event) -> bool {
	if !start.open {
		return false
	}
	if k.sym == KEY_SUPER_L || k.sym == KEY_SUPER_R {
		// The tap that closes it is decided on release, like the overview's.
		return true
	}
	if k.mods & {.Ctrl, .Alt, .Super} != {} && !(k.sym == p.KEY_BACKSPACE && .Ctrl in k.mods) {
		// A chord while the menu is open: close it and let the binding run.
		start_close(s)
		return false
	}
	q := start_query()
	switch k.sym {
	case p.KEY_ESCAPE:
		switch {
		case len(q) > 0:
			strings.builder_reset(&start.query)
			start.sel, start.sel_auto, start.scroll = -1, true, 0
		case start.page == .All:
			start.page = .Home
			start.sel, start.sel_auto, start.scroll = -1, true, 0
		case:
			start_close(s)
		}
	case p.KEY_RETURN, KEY_KP_ENTER:
		if start.sel >= 0 && start.sel < len(start.hits) {
			start_activate(s, start.hits[start.sel])
		}
	case p.KEY_BACKSPACE:
		b := &start.query.buf
		if .Ctrl in k.mods {
			clear(b)
		} else if len(b) > 0 {
			_, w := utf8.decode_last_rune(b[:])
			resize(b, len(b) - max(w, 1))
		}
		start.sel, start.sel_auto, start.scroll = -1, true, 0
	case p.KEY_DOWN:
		start_move(0, 1)
	case p.KEY_UP:
		start_move(0, -1)
	case p.KEY_LEFT:
		start_move(-1, 0)
	case p.KEY_RIGHT:
		start_move(1, 0)
	case p.KEY_TAB, KEY_ISO_LEFT_TAB:
		start_move(.Shift in k.mods || k.sym == KEY_ISO_LEFT_TAB ? -1 : 1, 0)
	case p.KEY_PAGE_DOWN:
		start.scroll = min(start.scroll + start.body.h * 0.8, start.scroll_max)
	case p.KEY_PAGE_UP:
		start.scroll = max(start.scroll - start.body.h * 0.8, 0)
	case KEY_MENU, KEY_F10:
		// The Menu key, or Shift+F10 on keyboards without one.
		if k.sym == KEY_F10 && .Shift not_in k.mods {
			break
		}
		if start.sel >= 0 && start.sel < len(start.hits) {
			r := start.hits[start.sel].rect
			start_context(s, start.hits[start.sel], int(r.x + r.w / 2), int(r.y + r.h / 2))
		}
	case:
		if r, ok := key_rune(k.sym); ok {
			strings.write_rune(&start.query, r)
			start.sel, start.sel_auto, start.scroll = -1, true, 0
		}
	}
	s.dirty = true
	return true
}

KEY_KP_ENTER :: 0xff8d
KEY_MENU :: 0xff67
KEY_F10 :: 0xffc7

// key_rune is the character a keysym types: Latin-1 keysyms are their own
// code points, and 0x01000000 + cp is the rest of Unicode.
key_rune :: proc(sym: u32) -> (rune, bool) {
	switch {
	case sym >= 0x20 && sym < 0x7f:
		return rune(sym), true
	case sym >= 0xa0 && sym <= 0xff:
		return rune(sym), true
	case sym >= 0x01000100 && sym <= 0x0110ffff:
		return rune(sym - 0x01000000), true
	}
	return 0, false
}

start_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if !start.open {
		return false
	}
	px, py := f32(mp.x), f32(mp.y)
	hover := -1
	for h, i in start.hits {
		if p.rect_contains(h.rect, px, py) && (h.kind == .Power_Btn || h.kind == .Settings_Btn || h.kind == .Identity || p.rect_contains(start.body, px, py) || h.kind == .All_Btn || h.kind == .Back_Btn) {
			hover = i
			break
		}
	}
	if hover != start.hover {
		start.hover = hover
		s.dirty = true
	}
	inside := p.rect_contains(start.rect, px, py)
	if in_.scroll.y != 0 && inside {
		start.scroll = clamp(start.scroll + in_.scroll.y * 40, 0, start.scroll_max)
		s.dirty = true
	}
	pressed := in_.pressed[.Left] || in_.pressed[.Right] || in_.pressed[.Middle]
	if pressed && !inside {
		start_close(s)
		ix.mode = .Swallow
		return true
	}
	if hover >= 0 {
		h := start.hits[hover]
		switch {
		case in_.pressed[.Left]:
			start_activate(s, h)
			ix.mode = .Swallow
		case in_.pressed[.Right]:
			start.sel = hover
			start.sel_auto = false
			start_context(s, h, mp.x, mp.y)
			ix.mode = .Swallow
		case in_.pressed[.Middle] && h.kind == .App:
			start_launch(s, h.idx)
			ix.mode = .Swallow
		}
	} else if pressed {
		ix.mode = .Swallow
	}
	return true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

start_icons: p.Icons
start_icons_ok: bool

wm_icons :: proc() -> ^p.Icons {
	if !start_icons_ok {
		p.icons_init(&start_icons)
		start_icons_ok = true
	}
	return &start_icons
}

// start_tile draws an application's tile: its glyph on a wash of its hue.
start_tile :: proc(cv: ^p.Canvas, e: ^ai.Entry, x, y, size: f32) {
	hue := ai.hue_for(e.id)
	wash := pal.dark ? mix(hue, 0x18181b, 0.78) : mix(hue, 0xffffff, 0.84)
	ink := pal.dark ? mix(hue, 0xffffff, 0.35) : mix(hue, 0x000000, 0.18)
	rad := size * 0.28
	p.fill_round_rect(cv, {x, y, size, size}, {rad, rad, rad, rad}, p.hex(wash))
	gs := size * 0.52
	p.draw_icon(cv, wm_icons(), ai.icon_for(e), x + (size - gs) / 2, y + (size - gs) / 2, gs, p.hex(ink))
}

// start_glyph_tile is a tile for something that is not an app (a file, a
// settings page): a neutral wash and the glyph.
start_glyph_tile :: proc(cv: ^p.Canvas, ic: p.Icon, x, y, size: f32) {
	rad := size * 0.28
	p.fill_round_rect(cv, {x, y, size, size}, {rad, rad, rad, rad}, p.hex(pal.pop_field))
	gs := size * 0.52
	p.draw_icon(cv, wm_icons(), ic, x + (size - gs) / 2, y + (size - gs) / 2, gs, p.hex(pal.pop_dim))
}

start_add_hit :: proc(kind: Start_Hit_Kind, r: p.Rect, idx: int, nav := true) -> (i: int, hot: bool) {
	append(&start.hits, Start_Hit{kind = kind, rect = r, idx = idx, nav = nav})
	i = len(start.hits) - 1
	// Typing selects the best match, so Enter opens it; the home page and
	// All apps wait for an arrow key before showing a selection.
	if start.sel_auto && start.sel < 0 && nav && len(start_query()) > 0 {
		start.sel = i
	}
	hot = i == start.hover || i == start.sel
	return
}

start_place :: proc(s: ^Server) -> p.Rect {
	o := s.outputs[clamp(start.out, 0, len(s.outputs) - 1)]
	top := f32(o.y + ws_bar_h(s)) + 8
	h := min(f32(SM_H), f32(o.y + o.h) - top - 12)
	w := min(f32(SM_W), f32(o.w) - 16)
	x := f32(o.x) + 8
	if !s.cfg.bar {
		x = f32(o.x) + (f32(o.w) - w) / 2
		top = f32(o.y) + (f32(o.h) - h) / 2
	}
	return {x, top, w, h}
}

start_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	if !start.open {
		return
	}
	start_search()
	f := &app.fonts
	clear(&start.hits)
	R := start_place(s)
	// A short drop out of the button, which reduced motion leaves out.
	if anim_mode(s) == .On {
		k := clamp(f32(wall_now() - start.opened_at) / 0.12, 0, 1)
		if k < 1 {
			R.y -= (1 - ease_out(k)) * 8
			anim_keep_going()
		}
	}
	start.rect = R
	rad := f32(12)
	wm_reset_clip(cv)
	p.drop_shadow(cv, R, {rad, rad, rad, rad}, 30, 0, {0, 12}, p.hexa(pal.shadow))
	p.fill_round_rect(cv, R, {rad, rad, rad, rad}, p.hex(pal.pop_bg))

	// --- the footer: who, and the way out ---------------------------------
	foot := p.Rect{R.x, R.y + R.h - SM_FOOT_H, R.w, SM_FOOT_H}
	p.fill_round_rect(cv, foot, {0, 0, rad, rad}, p.hex(pal.pop_section))
	p.fill_rect(cv, {R.x, foot.y, R.w, 1}, p.hex(pal.pop_line))
	start_draw_footer(s, f, cv, foot)

	// --- the search field ---------------------------------------------------
	field := p.Rect{R.x + SM_PAD, R.y + SM_PAD, R.w - 2 * SM_PAD, SM_SEARCH_H}
	p.fill_round_rect(cv, field, {10, 10, 10, 10}, p.hex(pal.pop_field))
	p.stroke_round_rect(cv, field, {10, 10, 10, 10}, 1, p.hex(len(start_query()) > 0 ? pal.accent_edge : pal.pop_line))
	p.draw_icon(cv, wm_icons(), ai.ICON_SEARCH, field.x + 14, field.y + 13, 18, p.hex(pal.pop_dim))
	tx := field.x + 42
	ty := field.y + 28
	if q := start_query(); q != "" {
		qw := p.draw_text(cv, f, q, tx, ty, 15, p.hex(pal.pop_text), .Sans, .Regular)
		// The caret: the field always has the keyboard while the menu is open.
		if int(wall_now() * 2) % 2 == 0 || anim_mode(s) == .Off {
			p.fill_rect(cv, {tx + qw + 1, field.y + 12, 1.5, 20}, p.hex(pal.accent))
		}
		wake_at(f64(int(wall_now() * 2) + 1) / 2)
	} else {
		p.fill_rect(cv, {tx, field.y + 12, 1.5, 20}, p.hex(pal.accent))
		p.draw_text(cv, f, "Type to search apps, settings and files", tx + 6, ty, 14.5, p.hex(pal.pop_faint), .Sans, .Regular)
	}

	// --- the body -----------------------------------------------------------
	body := p.Rect{R.x, field.y + field.h + 14, R.w, foot.y - (field.y + field.h + 14) - 6}
	start.body = body
	p.push_clip(cv, body)
	y0 := body.y - start.scroll
	end_y: f32
	switch {
	case len(start_query()) > 0:
		end_y = start_draw_results(s, f, cv, body, y0)
	case start.page == .All:
		end_y = start_draw_all(s, f, cv, body, y0)
	case:
		end_y = start_draw_home(s, f, cv, body, y0)
	}
	p.pop_clip(cv)
	start.scroll_max = max(0, end_y + start.scroll - body.y - body.h + 8)
	if start.scroll > start.scroll_max {
		start.scroll = start.scroll_max
	}

	// Keep the keyboard selection in view.
	if start.sel >= 0 && start.sel < len(start.hits) && !start.sel_auto {
		hr := start.hits[start.sel].rect
		if hr.y < body.y {
			start.scroll = max(0, start.scroll - (body.y - hr.y) - 8)
			s.dirty = true
		} else if hr.y + hr.h > body.y + body.h {
			start.scroll = min(start.scroll_max, start.scroll + (hr.y + hr.h - body.y - body.h) + 8)
			s.dirty = true
		}
	}
	// A scrolled body fades into the footer and the field rather than
	// cutting a row in half.
	if start.scroll_max > 0 {
		draw_scrollbar(cv, body, start.scroll, start.scroll_max)
	}
	p.stroke_round_rect(cv, R, {rad, rad, rad, rad}, 1, p.hex(pal.pop_line))
}

@(private = "file")
draw_scrollbar :: proc(cv: ^p.Canvas, body: p.Rect, scroll, max_: f32) {
	total := body.h + max_
	h := max(body.h * body.h / total, 24)
	y := body.y + (body.h - h) * (scroll / max_)
	p.fill_round_rect(cv, {body.x + body.w - 6, y, 3, h}, {1.5, 1.5, 1.5, 1.5}, with_alpha(pal.pop_dim, 0.5))
}

@(private = "file")
section_title :: proc(f: ^p.Fonts, cv: ^p.Canvas, label: string, x, y: f32) {
	p.draw_text(cv, f, label, x, y, 12, p.hex(pal.pop_dim), .Sans, .Semibold)
}

// start_draw_home is the empty-query page: the pinned grid and the recent
// list.
start_draw_home :: proc(s: ^Server, f: ^p.Fonts, cv: ^p.Canvas, body: p.Rect, y0: f32) -> f32 {
	x := body.x + SM_PAD
	w := body.w - 2 * SM_PAD
	y := y0 + 4
	section_title(f, cv, "Pinned", x + 4, y + 13)
	// All apps ›
	{
		label := "All apps"
		lw := p.text_width(f, label, 12, .Sans, .Medium)
		r := p.Rect{x + w - lw - 34, y - 2, lw + 34, 24}
		_, hot := start_add_hit(.All_Btn, r, 0, false)
		p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(hot ? pal.pop_hover : pal.pop_field))
		p.draw_text(cv, f, label, r.x + 12, r.y + 16, 12, p.hex(pal.pop_text), .Sans, .Medium)
		p.draw_icon(cv, wm_icons(), ai.ICON_CHEVRON_RIGHT, r.x + r.w - 20, r.y + 5, 14, p.hex(pal.pop_dim))
	}
	y += 30

	cell_w := w / SM_COLS
	n := 0
	for id in start.pins {
		i := ai.find_id(start.entries, id)
		if i < 0 {
			continue
		}
		col := n % SM_COLS
		row := n / SM_COLS
		r := p.Rect{x + f32(col) * cell_w, y + f32(row) * SM_CELL_H, cell_w, SM_CELL_H - 4}
		start_draw_cell(f, cv, i, r)
		n += 1
	}
	if n == 0 {
		p.draw_text(cv, f, "Right-click an app in All apps to pin it here.", x + 4, y + 22, 12.5, p.hex(pal.pop_faint))
		n = 1
	}
	y += f32((n + SM_COLS - 1) / SM_COLS) * SM_CELL_H + 8

	// Recent: apps launched lately and files touched lately, newest first,
	// in two columns.
	section_title(f, cv, "Recent", x + 4, y + 13)
	y += 26
	Rec :: struct {
		app:  bool,
		idx:  int,
		at:   i64,
	}
	recs := make([dynamic]Rec, context.temp_allocator)
	for i in ai.recent_apps(start.entries, 4) {
		append(&recs, Rec{true, i, start.entries[i].last * 1_000_000_000})
	}
	for fl, i in start.files {
		if i >= 4 {
			break
		}
		append(&recs, Rec{false, i, fl.mtime})
	}
	for i in 1 ..< len(recs) {
		v := recs[i]
		j := i - 1
		for j >= 0 && recs[j].at < v.at {
			recs[j + 1] = recs[j]
			j -= 1
		}
		recs[j + 1] = v
	}
	if len(recs) == 0 {
		p.draw_text(cv, f, "The apps and files you open show up here.", x + 4, y + 18, 12.5, p.hex(pal.pop_faint))
		return y + 30
	}
	half := (w - 8) / 2
	for rc, k in recs[:min(len(recs), 6)] {
		col := k % 2
		row := k / 2
		r := p.Rect{x + f32(col) * (half + 8), y + f32(row) * (SM_RECENT_H + 2), half, SM_RECENT_H}
		if rc.app {
			_, hot := start_add_hit(.App, r, rc.idx)
			if hot {
				p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
			}
			e := &start.entries[rc.idx]
			start_tile(cv, e, r.x + 8, r.y + 8, 32)
			p.draw_text(cv, f, ellipsize_end(f, e.name, 13, .Medium, r.w - 60), r.x + 50, r.y + 21, 13, p.hex(pal.pop_text), .Sans, .Medium)
			p.draw_text(cv, f, fmt.tprintf("App · %s", ago(e.last * 1_000_000_000)), r.x + 50, r.y + 37, 11.5, p.hex(pal.pop_dim))
		} else {
			fl := start.files[rc.idx]
			_, hot := start_add_hit(.File, r, rc.idx)
			if hot {
				p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
			}
			start_glyph_tile(cv, file_icon(fl.path), r.x + 8, r.y + 8, 32)
			p.draw_text(cv, f, ellipsize_middle(f, fl.name, 13, .Medium, r.w - 60), r.x + 50, r.y + 21, 13, p.hex(pal.pop_text), .Sans, .Medium)
			p.draw_text(cv, f, ellipsize_end(f, fmt.tprintf("%s · %s", file_place(fl.path), ago(fl.mtime)), 11.5, .Regular, r.w - 60), r.x + 50, r.y + 37, 11.5, p.hex(pal.pop_dim))
		}
	}
	rows := (min(len(recs), 6) + 1) / 2
	return y + f32(rows) * (SM_RECENT_H + 2)
}

// start_draw_cell is one pinned app: a tile and its name under it.
start_draw_cell :: proc(f: ^p.Fonts, cv: ^p.Canvas, i: int, r: p.Rect) {
	_, hot := start_add_hit(.App, r, i)
	if hot {
		p.fill_round_rect(cv, p.rect_inset(r, 2), {10, 10, 10, 10}, p.hex(pal.pop_hover))
	}
	e := &start.entries[i]
	ts := f32(44)
	start_tile(cv, e, r.x + (r.w - ts) / 2, r.y + 10, ts)
	label := ellipsize_end(f, e.name, 12, .Medium, r.w - 10)
	lw := p.text_width(f, label, 12, .Sans, .Medium)
	p.draw_text(cv, f, label, r.x + (r.w - lw) / 2, r.y + 74, 12, p.hex(pal.pop_text), .Sans, .Medium)
}

// start_draw_row is one app in a list: tile, name, and its comment dimmed.
start_draw_row :: proc(f: ^p.Fonts, cv: ^p.Canvas, i: int, r: p.Rect, big := false) {
	_, hot := start_add_hit(.App, r, i)
	if hot {
		p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
	}
	e := &start.entries[i]
	ts := big ? f32(40) : f32(28)
	start_tile(cv, e, r.x + 8, r.y + (r.h - ts) / 2, ts)
	nx := r.x + ts + 20
	if big {
		p.draw_text(cv, f, e.name, nx, r.y + r.h / 2 - 2, 15, p.hex(pal.pop_text), .Sans, .Semibold)
		if e.comment != "" {
			p.draw_text(cv, f, ellipsize_end(f, e.comment, 12, .Regular, r.w - (nx - r.x) - 90), nx, r.y + r.h / 2 + 15, 12, p.hex(pal.pop_dim))
		}
		hint := "Open  ↵"
		hw := p.text_width(f, hint, 11.5, .Sans, .Medium)
		p.draw_text(cv, f, hint, r.x + r.w - hw - 14, r.y + r.h / 2 + 4, 11.5, p.hex(pal.pop_dim), .Sans, .Medium)
		return
	}
	nw := p.text_width(f, e.name, 13, .Sans, .Medium)
	p.draw_text(cv, f, e.name, nx, r.y + r.h / 2 + 4.5, 13, p.hex(pal.pop_text), .Sans, .Medium)
	cx := nx + nw + 10
	if e.demo {
		bw := p.text_width(f, "demo", 10.5, .Sans, .Semibold) + 12
		br := p.Rect{cx, r.y + r.h / 2 - 9, bw, 18}
		p.stroke_round_rect(cv, br, {5, 5, 5, 5}, 1, p.hex(pal.pop_line))
		p.draw_text(cv, f, "demo", br.x + 6, br.y + 13, 10.5, p.hex(pal.pop_dim), .Sans, .Semibold)
		cx += bw + 8
	}
	if e.comment != "" && r.x + r.w - cx > 60 {
		p.draw_text(cv, f, ellipsize_end(f, e.comment, 12, .Regular, r.x + r.w - cx - 12), cx, r.y + r.h / 2 + 4.5, 12, p.hex(pal.pop_dim))
	}
}

// start_draw_all is every application, grouped.
start_draw_all :: proc(s: ^Server, f: ^p.Fonts, cv: ^p.Canvas, body: p.Rect, y0: f32) -> f32 {
	x := body.x + SM_PAD
	w := body.w - 2 * SM_PAD
	y := y0 + 2
	{
		r := p.Rect{x, y - 2, 96, 24}
		_, hot := start_add_hit(.Back_Btn, r, 0, false)
		p.fill_round_rect(cv, r, {6, 6, 6, 6}, p.hex(hot ? pal.pop_hover : pal.pop_field))
		p.draw_icon(cv, wm_icons(), ai.ICON_CHEVRON_LEFT, r.x + 6, r.y + 5, 14, p.hex(pal.pop_dim))
		p.draw_text(cv, f, "All apps", r.x + 24, r.y + 16, 12, p.hex(pal.pop_text), .Sans, .Medium)
		cnt := fmt.tprintf("%d apps", len(start.entries))
		cw := p.text_width(f, cnt, 12, .Sans, .Regular)
		p.draw_text(cv, f, cnt, x + w - cw - 4, y + 13, 12, p.hex(pal.pop_dim))
	}
	y += 34
	for cat in ai.CAT_ORDER {
		first := true
		for &e, i in start.entries {
			if e.cat != cat {
				continue
			}
			if first {
				section_title(f, cv, ai.CAT_TITLE[cat], x + 4, y + 14)
				y += 24
				first = false
			}
			start_draw_row(f, cv, i, {x, y, w, SM_ROW_H})
			y += SM_ROW_H
		}
		if !first {
			y += 8
		}
	}
	return y
}

// start_draw_results is the search page: the best match large, then the
// other apps, the settings pages and the files.
start_draw_results :: proc(s: ^Server, f: ^p.Fonts, cv: ^p.Canvas, body: p.Rect, y0: f32) -> f32 {
	x := body.x + SM_PAD
	w := body.w - 2 * SM_PAD
	y := y0 + 2
	if len(start.res_apps) == 0 && len(start.res_set) == 0 && len(start.res_files) == 0 {
		msg := fmt.tprintf("Nothing matches “%s”.", strings.trim_space(start_query()))
		mw := p.text_width(f, msg, 13.5, .Sans, .Medium)
		p.draw_text(cv, f, msg, body.x + (body.w - mw) / 2, body.y + 60, 13.5, p.hex(pal.pop_text), .Sans, .Medium)
		sub := "Try part of a name, or a word like “wifi” or “dark”."
		sw := p.text_width(f, sub, 12, .Sans, .Regular)
		p.draw_text(cv, f, sub, body.x + (body.w - sw) / 2, body.y + 82, 12, p.hex(pal.pop_dim))
		return body.y + 100
	}
	apps := start.res_apps[:]
	sets := start.res_set[:]
	if start.best_set || len(apps) > 0 {
		section_title(f, cv, "Best match", x + 4, y + 13)
		y += 22
		if start.best_set {
			start_draw_setting(f, cv, sets[0], {x, y, w, 60}, big = true)
			sets = sets[1:]
		} else {
			start_draw_row(f, cv, apps[0], {x, y, w, 60}, big = true)
			apps = apps[1:]
		}
		y += 66
	}
	if len(apps) > 0 {
		section_title(f, cv, "Apps", x + 4, y + 13)
		y += 22
		for i in apps {
			start_draw_row(f, cv, i, {x, y, w, SM_ROW_H})
			y += SM_ROW_H
		}
		y += 6
	}
	if len(sets) > 0 {
		section_title(f, cv, "Settings", x + 4, y + 13)
		y += 22
		for si in sets {
			start_draw_setting(f, cv, si, {x, y, w, SM_ROW_H})
			y += SM_ROW_H
		}
		y += 6
	}
	if len(start.res_files) > 0 {
		section_title(f, cv, "Files", x + 4, y + 13)
		y += 22
		for fi in start.res_files {
			r := p.Rect{x, y, w, SM_ROW_H}
			_, hot := start_add_hit(.File, r, fi)
			if hot {
				p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
			}
			fl := start.files[fi]
			start_glyph_tile(cv, file_icon(fl.path), r.x + 8, r.y + 6, 28)
			p.draw_text(cv, f, fl.name, r.x + 48, r.y + 24.5, 13, p.hex(pal.pop_text), .Sans, .Medium)
			nw := p.text_width(f, fl.name, 13, .Sans, .Medium)
			p.draw_text(cv, f, fmt.tprintf("%s · %s", file_place(fl.path), ago(fl.mtime)), r.x + 48 + nw + 10, r.y + 24.5, 12, p.hex(pal.pop_dim))
			y += SM_ROW_H
		}
	}
	return y
}

// start_draw_setting is one Settings page in the results.
start_draw_setting :: proc(f: ^p.Fonts, cv: ^p.Canvas, si: int, r: p.Rect, big := false) {
	_, hot := start_add_hit(.Setting, r, si)
	if hot {
		p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
	}
	pg := SETTINGS_PAGES[si]
	ts := big ? f32(40) : f32(28)
	start_glyph_tile(cv, pg.icon, r.x + 8, r.y + (r.h - ts) / 2, ts)
	nx := r.x + ts + 20
	if big {
		p.draw_text(cv, f, pg.title, nx, r.y + r.h / 2 - 2, 15, p.hex(pal.pop_text), .Sans, .Semibold)
		p.draw_text(cv, f, "Settings", nx, r.y + r.h / 2 + 15, 12, p.hex(pal.pop_dim))
		hint := "Open  ↵"
		hw := p.text_width(f, hint, 11.5, .Sans, .Medium)
		p.draw_text(cv, f, hint, r.x + r.w - hw - 14, r.y + r.h / 2 + 4, 11.5, p.hex(pal.pop_dim), .Sans, .Medium)
		return
	}
	p.draw_text(cv, f, pg.title, nx, r.y + r.h / 2 + 4.5, 13, p.hex(pal.pop_text), .Sans, .Medium)
	tw := p.text_width(f, pg.title, 13, .Sans, .Medium)
	p.draw_text(cv, f, "Settings", nx + tw + 10, r.y + r.h / 2 + 4.5, 12, p.hex(pal.pop_dim))
}

start_draw_footer :: proc(s: ^Server, f: ^p.Fonts, cv: ^p.Canvas, foot: p.Rect) {
	id := shell_identity()
	_, have_accounts := cfg_which("accounts")
	ir := p.Rect{foot.x + 10, foot.y + 9, 260, foot.h - 18}
	hot := false
	if have_accounts {
		_, hot = start_add_hit(.Identity, ir, 0, false)
	}
	if hot {
		p.fill_round_rect(cv, ir, {8, 8, 8, 8}, p.hex(pal.pop_hover))
	}
	cx := ir.x + 22
	cy := ir.y + ir.h / 2
	col := id.color != 0 ? id.color : (pal.dark ? 0x3f3f46 : 0xd4d4d8)
	p.fill_circle(cv, cx, cy, 15, p.hex(id.color != 0 ? mix(col, pal.pop_section, 0.75) : col))
	if id.color != 0 {
		p.stroke_round_rect(cv, {cx - 15, cy - 15, 30, 30}, {15, 15, 15, 15}, 1.5, p.hex(col))
	}
	m := monogram(id.name)
	mw := p.text_width(f, m, 13, .Sans, .Semibold)
	p.draw_text(cv, f, m, cx - mw / 2, cy + 4.5, 13, p.hex(id.color != 0 ? col : pal.pop_text), .Sans, .Semibold)
	p.draw_text(cv, f, ellipsize_end(f, id.name, 13, .Semibold, 190), cx + 24, cy - 2, 13, p.hex(pal.pop_text), .Sans, .Semibold)
	sub := id.subtitle
	if !id.ok && have_accounts {
		sub = "Sign in to Palmy"
	}
	p.draw_text(cv, f, sub, cx + 24, cy + 14, 11.5, p.hex(pal.pop_dim))

	// The buttons on the right: Settings, then power.
	bx := foot.x + foot.w - 14 - 36
	by := foot.y + (foot.h - 36) / 2
	{
		r := p.Rect{bx, by, 36, 36}
		_, h := start_add_hit(.Power_Btn, r, 0, false)
		if h {
			p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
		}
		p.draw_icon(cv, wm_icons(), ai.ICON_POWER, r.x + 9, r.y + 9, 18, p.hex(pal.pop_text))
	}
	if _, ok := cfg_which("settings"); ok {
		r := p.Rect{bx - 42, by, 36, 36}
		_, h := start_add_hit(.Settings_Btn, r, 0, false)
		if h {
			p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(pal.pop_hover))
		}
		p.draw_icon(cv, wm_icons(), ai.ICON_SETTINGS, r.x + 9, r.y + 9, 18, p.hex(pal.pop_text))
	}
}

// ago is a short "how long since": "now", "5 min ago", "3 h ago",
// "yesterday", "4 days ago", then the date.
ago :: proc(ns: i64) -> string {
	if ns <= 0 {
		return "earlier"
	}
	now := time.to_unix_nanoseconds(time.now())
	d := (now - ns) / 1_000_000_000
	switch {
	case d < 60:
		return "now"
	case d < 3600:
		return fmt.tprintf("%d min ago", d / 60)
	case d < 86400:
		return fmt.tprintf("%d h ago", d / 3600)
	case d < 2 * 86400:
		return "yesterday"
	case d < 30 * 86400:
		return fmt.tprintf("%d days ago", d / 86400)
	}
	t := time.unix(0, ns)
	y, mo, dd := time.date(t)
	return fmt.tprintf("%d %v %d", dd, mo, y)
}

// file_place is where a file is, as a person would say it: "Documents",
// "Home".
file_place :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := path
	if sl := strings.last_index_byte(dir, '/'); sl > 0 {
		dir = dir[:sl]
	}
	if dir == home {
		return "Home"
	}
	if sl := strings.last_index_byte(dir, '/'); sl >= 0 {
		return dir[sl + 1:]
	}
	return dir
}

file_icon :: proc(path: string) -> p.Icon {
	m := ai.mime_of(path)
	switch {
	case strings.has_prefix(m, "image/"):
		return ai.ICON_IMAGE
	case strings.has_prefix(m, "audio/"):
		return ai.ICON_MUSIC
	case strings.has_prefix(m, "video/"):
		return ai.ICON_CLAPPERBOARD
	case m == "text/csv":
		return ai.ICON_FILE_SPREADSHEET
	case m == "application/pdf" || m == "application/epub+zip":
		return ai.ICON_BOOK_OPEN
	case strings.has_prefix(m, "application/"):
		return ai.ICON_ARCHIVE
	case strings.has_prefix(m, "text/"):
		return ai.ICON_FILE_TEXT
	}
	return ai.ICON_FILE
}
