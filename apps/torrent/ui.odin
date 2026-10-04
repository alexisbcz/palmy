package main

// The window.
//
// Three bands: a toolbar, the torrent table, and a details pane with tabs. The
// engine runs on another thread and is read once a frame through
// `engine_snapshot`; nothing here touches a socket or a piece buffer.
//
// A PALMY LAYOUT BUG, WORKED AROUND HERE
//
// `h-full` and `flex-1` resolve against a PRE-SHRINK height. A `flex-1` row
// containing a tall scrolling list therefore sizes itself to that list's
// content height — a 2000px list inside a 400px slot makes the row 2000px —
// and every sibling after it is pushed off the window. `min-h-0` does not stop
// it, because the overflow happens during measurement rather than during the
// shrink pass.
//
// So no band in this file uses `flex-1` for its height. Every one of them gets
// an explicit pixel height computed from `p.size(ui).y` minus the fixed bands
// (`Geom` below). It is more arithmetic than it should be and it is completely
// reliable. Reported rather than patched.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Tab :: enum {
	General,
	Peers,
	Files,
	Trackers,
	Graph,
}

tab_name :: proc(t: Tab) -> string {
	switch t {
	case .General:
		return "General"
	case .Peers:
		return "Peers"
	case .Files:
		return "Files"
	case .Trackers:
		return "Trackers"
	case .Graph:
		return "Speed"
	}
	return "?"
}

Dialog :: enum {
	None,
	Add_File,
	Add_Magnet,
	Remove,
	Remove_Data,
	Help,
}

Ui :: struct {
	app:          ^p.App,
	eng:          ^Engine,
	view:         Engine_View,

	sel:          int, // index into view.torrents
	sel_id:       int,
	tab:          Tab,
	file_sel:     int,
	peer_sel:     int,
	list_top:     int,
	detail_top:   int,
	detail_h:     f32,

	dialog:       Dialog,
	path_buf:     [dynamic]u8,
	dir_buf:      [dynamic]u8,
	magnet_buf:   [dynamic]u8,
	dialog_field: int, // which field of the add dialog has focus
	confirm_sel:  int, // 0 = Cancel, 1 = the destructive action

	toast:        string,
	toast_at:     f64,

	demo:         Demo,
	start:        f64,
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

run_ui :: proc(a: Args) {
	app, err := kit.start({title = "Torrent", width = 1500, height = 900}, true)
	if err != "" {
		fmt.eprintfln("torrent: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	u := new(Ui)
	u.app = app
	u.detail_h = 340
	u.start = now_s()
	u.path_buf = make([dynamic]u8, 0, 256)
	u.dir_buf = make([dynamic]u8, 0, 256)
	u.magnet_buf = make([dynamic]u8, 0, 256)

	eng := new(Engine)
	seed := u64(time.to_unix_nanoseconds(time.now())) ~ u64(os.get_pid()) * 0x9e3779b9
	if ierr := engine_init(eng, a.port, seed); ierr != "" {
		fmt.eprintfln("torrent: %s", ierr)
		os.exit(1)
	}
	eng.down_limit = a.down_limit
	eng.verbose = a.verbose
	u.eng = eng

	default_dir := expand_home("~/Downloads")
	if !path_exists(default_dir) {
		default_dir = expand_home("~")
	}

	if a.demo {
		// The demo stages a complete local swarm: a tracker and a seeder, both
		// children of this process, both on 127.0.0.1, serving a payload this
		// process generated. The add dialog opens pre-filled with it, so the
		// transfer that follows is real.
		if derr := demo_setup(&u.demo); derr != "" {
			fmt.eprintfln("torrent: demo setup failed: %s", derr)
		} else {
			default_dir = u.demo.out_dir
			append(&u.path_buf, ..transmute([]u8)u.demo.torrent)
			eng.down_limit = DEMO_RATE
			ui_toast(u, tsprint("demo swarm ready on 127.0.0.1:%d — press A to add the torrent", u.demo.http_port))
		}
	}
	// An explicit --dir wins over the default download directory.
	if a.dir != "" {
		default_dir = expand_home(a.dir)
	}
	make_dirs(default_dir)
	append(&u.dir_buf, ..transmute([]u8)default_dir)

	if a.torrent != "" && a.mode == .Ui {
		engine_add(eng, a.torrent, default_dir, true)
	}

	engine_start_thread(eng)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		u.view = engine_snapshot(eng, u.sel_id, context.temp_allocator)
		ui_sync_selection(u)
		ui_keys(u, ui)
		ui_frame(u, ui)
		// The rates and the piece map change every frame of a transfer, so the
		// window redraws continuously while anything is moving and sleeps when
		// nothing is.
		if ui_busy(u) {
			p.redraw(ui)
		}
	}

	engine_request_quit(eng)
	engine_shutdown(eng)
	demo_teardown(&u.demo)
}

@(private = "file")
ui_busy :: proc(u: ^Ui) -> bool {
	for t in u.view.torrents {
		if t.state == .Downloading || t.state == .Checking || t.up_rate > 1 {
			return true
		}
	}
	return u.toast != ""
}

@(private = "file")
ui_toast :: proc(u: ^Ui, msg: string) {
	if u.toast != "" {
		delete(u.toast)
	}
	u.toast = strings.clone(msg, context.allocator)
	u.toast_at = now_s()
}

@(private = "file")
ui_sync_selection :: proc(u: ^Ui) {
	n := len(u.view.torrents)
	if n == 0 {
		u.sel = 0
		u.sel_id = 0
		return
	}
	// Follow the selected torrent by id, so adding or removing another one does
	// not move the selection.
	if u.sel_id != 0 {
		for t, i in u.view.torrents {
			if t.id == u.sel_id {
				u.sel = i
				return
			}
		}
	}
	u.sel = clamp(u.sel, 0, n - 1)
	u.sel_id = u.view.torrents[u.sel].id
}

@(private = "file")
ui_selected :: proc(u: ^Ui) -> (Torrent_View, bool) {
	if u.sel < 0 || u.sel >= len(u.view.torrents) {
		return {}, false
	}
	return u.view.torrents[u.sel], true
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

@(private = "file")
ui_keys :: proc(u: ^Ui, ui: ^p.Ctx) {
	if u.dialog != .None {
		ui_dialog_keys(u, ui)
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) && u.toast != "" {
		delete(u.toast)
		u.toast = ""
	}
	typed := p.typed_text(ui)

	// `key_count`, not `key_pressed`: several presses can land in one frame and
	// collapse into a single `true`, so a driven script moves one row for two
	// taps. One press must be one step.
	if n := p.key_count(ui, p.KEY_DOWN); n > 0 {
		ui_move_selection(u, n)
	}
	if n := p.key_count(ui, p.KEY_UP); n > 0 {
		ui_move_selection(u, -n)
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		ui_set_selection(u, 0)
	}
	if p.key_pressed(ui, p.KEY_END) {
		ui_set_selection(u, len(u.view.torrents) - 1)
	}

	for ch in typed {
		switch ch {
		case 'a', 'A':
			u.dialog = .Add_File
			u.dialog_field = 0
		case 'm', 'M':
			u.dialog = .Add_Magnet
			u.dialog_field = 0
		case 'p', 'P':
			ui_toggle_pause(u)
		case 'r', 'R':
			if t, ok := ui_selected(u); ok {
				engine_post(u.eng, Engine_Cmd{kind = .Recheck, id = t.id})
				ui_toast(u, tsprint("rechecking %s — every piece is re-hashed from disk", t.name))
			}
		case '1':
			u.tab = .General
		case '2':
			u.tab = .Peers
		case '3':
			u.tab = .Files
		case '4':
			u.tab = .Trackers
		case '5':
			u.tab = .Graph
		case 'j':
			ui_detail_move(u, 1)
		case 'k':
			ui_detail_move(u, -1)
		case '?':
			u.dialog = .Help
		case 'q':
			p.quit_app(u.app)
		case '[':
			u.detail_h = clampf(u.detail_h - 40, 120, p.size(ui).y - 260)
		case ']':
			u.detail_h = clampf(u.detail_h + 40, 120, p.size(ui).y - 260)
		}
	}
	// Tab switching with the arrow keys when the details pane is the focus of
	// attention.
	if p.shortcut(ui, p.KEY_RIGHT, {.Ctrl}) {
		u.tab = Tab((int(u.tab) + 1) % len(Tab))
	}
	if p.shortcut(ui, p.KEY_LEFT, {.Ctrl}) {
		u.tab = Tab((int(u.tab) + len(Tab) - 1) % len(Tab))
	}
	// Per-file priority, which is what Left/Right do in the files tab.
	if u.tab == .Files {
		if n := p.key_count(ui, p.KEY_RIGHT); n > 0 {
			ui_bump_priority(u, n)
		}
		if n := p.key_count(ui, p.KEY_LEFT); n > 0 {
			ui_bump_priority(u, -n)
		}
	}
	// Removal. Delete asks before removing; Shift+Delete asks before removing
	// the data as well, and that dialog defaults to Cancel.
	if p.shortcut(ui, p.KEY_DELETE, {.Shift}) {
		if _, ok := ui_selected(u); ok {
			u.dialog = .Remove_Data
			u.confirm_sel = 0
		}
	} else if p.shortcut(ui, p.KEY_DELETE, {}) {
		if _, ok := ui_selected(u); ok {
			u.dialog = .Remove
			u.confirm_sel = 0
		}
	}
	if p.key_pressed(ui, p.KEY_SPACE) {
		ui_toggle_pause(u)
	}
}

@(private = "file")
ui_move_selection :: proc(u: ^Ui, delta: int) {
	ui_set_selection(u, u.sel + delta)
}

@(private = "file")
ui_set_selection :: proc(u: ^Ui, idx: int) {
	n := len(u.view.torrents)
	if n == 0 {
		return
	}
	u.sel = clamp(idx, 0, n - 1)
	u.sel_id = u.view.torrents[u.sel].id
	u.file_sel = 0
	u.peer_sel = 0
	u.detail_top = 0
}

@(private = "file")
ui_detail_move :: proc(u: ^Ui, delta: int) {
	t, ok := ui_selected(u)
	if !ok {
		return
	}
	switch u.tab {
	case .Files:
		if len(t.files) > 0 {
			u.file_sel = clamp(u.file_sel + delta, 0, len(t.files) - 1)
		}
	case .Peers:
		if len(t.peers) > 0 {
			u.peer_sel = clamp(u.peer_sel + delta, 0, len(t.peers) - 1)
		}
	case .General, .Trackers, .Graph:
		u.detail_top = max(0, u.detail_top + delta)
	}
}

@(private = "file")
ui_toggle_pause :: proc(u: ^Ui) {
	t, ok := ui_selected(u)
	if !ok {
		return
	}
	if t.state == .Stopped {
		engine_post(u.eng, Engine_Cmd{kind = .Start, id = t.id})
		ui_toast(u, tsprint("resumed %s", t.name))
	} else {
		engine_post(u.eng, Engine_Cmd{kind = .Stop, id = t.id})
		ui_toast(u, tsprint("paused %s — the tracker was told `stopped`", t.name))
	}
}

@(private = "file")
ui_bump_priority :: proc(u: ^Ui, delta: int) {
	t, ok := ui_selected(u)
	if !ok || len(t.files) == 0 {
		return
	}
	i := clamp(u.file_sel, 0, len(t.files) - 1)
	cur := int(t.files[i].prio)
	next := clamp(cur + delta, 0, len(File_Prio) - 1)
	if next == cur {
		return
	}
	engine_post(
		u.eng,
		Engine_Cmd{kind = .Set_Priority, id = t.id, file = i, prio = File_Prio(next)},
	)
	ui_toast(u, tsprint("%s set to %s", t.files[i].path, file_prio_name(File_Prio(next))))
}

@(private = "file")
ui_dialog_keys :: proc(u: ^Ui, ui: ^p.Ctx) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		u.dialog = .None
		return
	}
	switch u.dialog {
	case .None:
	case .Help:
		if p.key_pressed(ui, p.KEY_RETURN) {
			u.dialog = .None
		}
	case .Add_File:
		if p.key_pressed(ui, p.KEY_TAB) {
			u.dialog_field = 1 - u.dialog_field
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			ui_do_add_file(u)
		}
	case .Add_Magnet:
		if p.key_pressed(ui, p.KEY_RETURN) {
			ui_do_add_magnet(u)
		}
	case .Remove, .Remove_Data:
		// Left/Right move between Cancel and the action; Cancel is selected
		// when the dialog opens.
		if p.key_pressed(ui, p.KEY_LEFT) {
			u.confirm_sel = 0
		}
		if p.key_pressed(ui, p.KEY_RIGHT) {
			u.confirm_sel = 1
		}
		if p.key_pressed(ui, p.KEY_TAB) {
			u.confirm_sel = 1 - u.confirm_sel
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			if u.confirm_sel == 1 {
				ui_do_remove(u, u.dialog == .Remove_Data)
			}
			u.dialog = .None
		}
	}
}

@(private = "file")
ui_do_add_file :: proc(u: ^Ui) {
	path := strings.trim_space(string(u.path_buf[:]))
	dir := strings.trim_space(string(u.dir_buf[:]))
	if path == "" {
		ui_toast(u, "a .torrent path is needed")
		return
	}
	full := expand_home(path, context.temp_allocator)
	if !path_exists(full) {
		ui_toast(u, tsprint("%s does not exist", full))
		return
	}
	d := dir == "" ? "." : expand_home(dir, context.temp_allocator)
	if derr := make_dirs(d); derr != "" {
		ui_toast(u, derr)
		return
	}
	engine_add(u.eng, full, d, true)
	u.dialog = .None
	ui_toast(u, tsprint("added %s", path_base(full)))
}

@(private = "file")
ui_do_add_magnet :: proc(u: ^Ui) {
	uri := strings.trim_space(string(u.magnet_buf[:]))
	mg, err := magnet_parse(uri, context.temp_allocator)
	if err != "" {
		ui_toast(u, err)
		return
	}
	// A magnet names a torrent by hash and nothing more. Fetching the metadata
	// means asking a stranger for it (BEP 9, over the DHT), which this client
	// is not allowed to do — so a magnet resolves only against a .torrent
	// already in the state directory, keyed by info-hash.
	hex := hash20_hex(mg.info_hash, context.temp_allocator)
	cached := path_join(state_dir(context.temp_allocator), tsprint("%s.torrent", hex), allocator = context.temp_allocator)
	if !path_exists(cached) {
		ui_toast(
			u,
			tsprint(
				"no metadata for %s: a magnet needs BEP 9 over a DHT, which this client will not do. Put the .torrent at %s.",
				hex[:12],
				cached,
			),
		)
		return
	}
	dir := strings.trim_space(string(u.dir_buf[:]))
	engine_add(u.eng, cached, dir == "" ? "." : dir, true)
	u.dialog = .None
	ui_toast(u, tsprint("added %s from the metadata cache", mg.name == "" ? hex[:12] : mg.name))
}

@(private = "file")
ui_do_remove :: proc(u: ^Ui, with_data: bool) {
	t, ok := ui_selected(u)
	if !ok {
		return
	}
	engine_post(
		u.eng,
		Engine_Cmd{kind = with_data ? .Remove_With_Data : .Remove, id = t.id},
	)
	u.sel_id = 0
	ui_toast(
		u,
		with_data \
		? tsprint("removed %s and deleted its data", t.name) \
		: tsprint("removed %s — its files were left on disk", t.name),
	)
}

// ---------------------------------------------------------------------------
// Geometry
//
// Every band's height is computed here from the window size. See the note at
// the top of the file: nothing below uses `flex-1` to size itself vertically.
// ---------------------------------------------------------------------------

TOOLBAR_H :: 46
HEADER_H :: 34
STATUS_H :: 30
ROW_H :: 30
TABS_H :: 38
DETAIL_ROW_H :: 26

Geom :: struct {
	w, h:     f32,
	list_h:   f32,
	detail_h: f32,
	body_h:   f32, // the detail pane's content area, below its tab strip
	rows:     int,
	drows:    int,
}

@(private = "file")
ui_geom :: proc(u: ^Ui, ui: ^p.Ctx) -> Geom {
	sz := p.size(ui)
	g := Geom {
		w = sz.x,
		h = sz.y,
	}
	g.detail_h = clampf(u.detail_h, 120, max(140, sz.y - TOOLBAR_H - HEADER_H - STATUS_H - 3 * ROW_H))
	g.list_h = sz.y - TOOLBAR_H - HEADER_H - STATUS_H - g.detail_h - 2
	if g.list_h < ROW_H {
		g.list_h = ROW_H
	}
	g.rows = max(1, int(g.list_h / ROW_H))
	g.body_h = g.detail_h - TABS_H - 1
	g.drows = max(1, int(g.body_h / DETAIL_ROW_H))
	return g
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

// ui_frame_offscreen is the door shot.odin builds its frames through: the
// frame builder is private to this file, and the offscreen renderer lives in
// another one.
ui_frame_offscreen :: proc(u: ^Ui, ui: ^p.Ctx) {
	ui_frame(u, ui)
}

@(private = "file")
ui_frame :: proc(u: ^Ui, ui: ^p.Ctx) {
	g := ui_geom(u, ui)

	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	ui_toolbar(u, ui, g)
	ui_table(u, ui, g)
	p.div(ui, "w-full h-px bg-border shrink-0")
	p.end(ui)
	ui_details(u, ui, g)
	ui_status(u, ui, g)

	if u.dialog != .None {
		ui_dialog(u, ui, g)
	}
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

@(private = "file")
ui_toolbar :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom) {
	p.row(ui, "w-full items-center gap-2 px-3 border-b border-border shrink-0")
	p.style(ui).h = p.px(TOOLBAR_H)
	defer p.end(ui)

	p.icon(ui, sc.ICON_DOWNLOAD, "size-5 text-primary")
	p.text(ui, "Torrent", "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0

	p.div(ui, "w-px h-5 bg-border mx-1")
	p.end(ui)

	sel, has_sel := ui_selected(u)
	running := has_sel && (sel.state == .Downloading || sel.state == .Seeding || sel.state == .Checking)

	if ui_tool_button(u, ui, "Add", sc.ICON_PLUS, false, "A") {
		u.dialog = .Add_File
		u.dialog_field = 0
	}
	if ui_tool_button(u, ui, "Magnet", ICON_MAGNET, false, "M") {
		u.dialog = .Add_Magnet
	}
	p.div(ui, "w-px h-5 bg-border mx-1")
	p.end(ui)
	if ui_tool_button(u, ui, running ? "Pause" : "Resume", running ? ICON_PAUSE : ICON_PLAY, !has_sel, "P") {
		ui_toggle_pause(u)
	}
	if ui_tool_button(u, ui, "Recheck", ICON_RECHECK, !has_sel, "R") {
		if has_sel {
			engine_post(u.eng, Engine_Cmd{kind = .Recheck, id = sel.id})
			ui_toast(u, tsprint("rechecking %s", sel.name))
		}
	}
	p.div(ui, "w-px h-5 bg-border mx-1")
	p.end(ui)
	if ui_tool_button(u, ui, "Remove", sc.ICON_MINUS, !has_sel, "Del") {
		if has_sel {
			u.dialog = .Remove
			u.confirm_sel = 0
		}
	}
	if ui_tool_button(u, ui, "Remove + data", sc.ICON_TRASH, !has_sel, "Sh+Del") {
		if has_sel {
			u.dialog = .Remove_Data
			u.confirm_sel = 0
		}
	}

	p.spacer(ui, "flex-1")

	// The live totals, which is what a title bar would carry.
	p.row(ui, "items-center gap-3 shrink-0")
	{
		p.icon(ui, sc.ICON_ARROW_DOWN, "size-4 text-emerald-500")
		p.text(
			ui,
			human_rate(u.view.total_down, context.temp_allocator),
			"text-xs font-mono text-emerald-500 whitespace-nowrap",
		)
		p.icon(ui, ICON_ARROW_UP, "size-4 text-sky-500")
		p.text(
			ui,
			human_rate(u.view.total_up, context.temp_allocator),
			"text-xs font-mono text-sky-500 whitespace-nowrap",
		)
		if u.view.down_limit > 0 {
			sc.badge(ui, tsprint("limit %s", human_rate(f64(u.view.down_limit), context.temp_allocator)), .Secondary)
		}
		p.text(
			ui,
			tsprint("127.0.0.1:%d", u.view.port),
			"text-xs font-mono text-muted-foreground whitespace-nowrap",
		)
		if ui_tool_button(u, ui, "?", sc.ICON_INFO, false, "") {
			u.dialog = .Help
		}
	}
	p.end(ui)
}

@(private = "file")
ui_tool_button :: proc(
	u: ^Ui,
	ui: ^p.Ctx,
	label: string,
	icon: p.Icon,
	disabled: bool,
	key: string,
) -> bool {
	idx := p.row(ui, "items-center gap-1.5 h-8 px-2.5 rounded-lg border border-transparent shrink-0 transition")
	if disabled {
		p.apply(ui, "opacity-40")
	} else {
		p.apply(ui, "hover:bg-muted cursor-pointer")
		p.focusable(ui)
	}
	defer p.end(ui)

	hovered := !disabled && p.is_hovered(ui, idx)
	if p.focused(ui, idx) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	p.icon(ui, icon, hovered ? "size-4 text-foreground" : "size-4 text-muted-foreground")
	p.text(ui, label, "text-sm whitespace-nowrap")
	p.style(ui).shrink = 0
	if key != "" {
		p.text(ui, key, "text-[10] font-mono text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	return !disabled && p.activated(ui, idx)
}

// ---------------------------------------------------------------------------
// The torrent table
// ---------------------------------------------------------------------------

Col :: struct {
	label: string,
	w:     f32,
	right: bool,
}

@(rodata)
COLS := []Col {
	{"Name", 360, false},
	{"Size", 92, true},
	{"Progress", 170, false},
	{"Status", 112, false},
	{"Down", 92, true},
	{"Up", 92, true},
	{"Seeds", 78, true},
	{"Peers", 70, true},
	{"Ratio", 64, true},
	{"ETA", 84, true},
}

@(private = "file")
ui_table :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom) {
	// Header.
	p.row(ui, "w-full items-center border-b border-border bg-muted/40 shrink-0 overflow-hidden")
	p.style(ui).h = p.px(HEADER_H)
	{
		p.div(ui, "w-3 shrink-0")
		p.end(ui)
		for c in COLS {
			p.col(ui, "justify-center px-2 shrink-0")
			p.style(ui).w = p.px(c.w)
			p.text(
				ui,
				c.label,
				c.right \
				? "text-xs font-medium text-muted-foreground text-right whitespace-nowrap" \
				: "text-xs font-medium text-muted-foreground whitespace-nowrap",
			)
			p.end(ui)
		}
	}
	p.end(ui)

	// The rows. An explicit height, not `flex-1` — see the note at the top.
	list := p.col(ui, "w-full overflow-hidden shrink-0")
	p.style(ui).h = p.px(g.list_h)
	defer p.end(ui)

	if len(u.view.torrents) == 0 {
		p.col(ui, "w-full items-center justify-center gap-2")
		p.style(ui).h = p.px(g.list_h)
		p.icon(ui, sc.ICON_INBOX, "size-8 text-muted-foreground")
		p.text(ui, "No torrents", "text-sm text-muted-foreground")
		p.text(
			ui,
			"Press A to add a .torrent, or M for a magnet link.",
			"text-xs text-muted-foreground",
		)
		p.end(ui)
		return
	}

	// Scroll the window of rows to keep the selection visible.
	if u.sel < u.list_top {
		u.list_top = u.sel
	}
	if u.sel >= u.list_top + g.rows {
		u.list_top = u.sel - g.rows + 1
	}
	u.list_top = clamp(u.list_top, 0, max(0, len(u.view.torrents) - g.rows))
	if w := p.wheel(ui); w.y != 0 && p.is_hovered(ui, list) {
		u.list_top = clamp(u.list_top - int(w.y), 0, max(0, len(u.view.torrents) - g.rows))
	}

	last := min(len(u.view.torrents), u.list_top + g.rows)
	for i in u.list_top ..< last {
		t := u.view.torrents[i]
		p.key(ui, tsprint("t%d", t.id))
		row := p.row(ui, "w-full items-center shrink-0 overflow-hidden transition")
		p.style(ui).h = p.px(ROW_H)
		selected := i == u.sel
		if selected {
			p.apply(ui, "bg-primary/15")
		} else if i % 2 == 1 {
			p.apply(ui, "bg-muted/20")
		}
		p.apply(ui, "hover:bg-accent cursor-pointer")
		if p.clickable(ui, row) {
			ui_set_selection(u, i)
		}
		{
			// The selection marker, which is also the state colour.
			p.div(ui, "w-3 h-full shrink-0 items-center justify-center")
			if selected {
				p.div(ui, "w-0.5 h-full bg-primary")
				p.end(ui)
			}
			p.end(ui)

			ui_cell_text(ui, t.name, COLS[0].w, false, "text-sm truncate")
			ui_cell_text(
				ui,
				human_size(t.size, context.temp_allocator),
				COLS[1].w,
				true,
				"text-xs font-mono text-muted-foreground",
			)
			ui_cell_progress(ui, t, COLS[2].w)
			ui_cell_state(ui, t, COLS[3].w)
			ui_cell_text(
				ui,
				t.down_rate > 1 ? human_rate(t.down_rate, context.temp_allocator) : "—",
				COLS[4].w,
				true,
				t.down_rate > 1 ? "text-xs font-mono text-emerald-500" : "text-xs font-mono text-muted-foreground",
			)
			ui_cell_text(
				ui,
				t.up_rate > 1 ? human_rate(t.up_rate, context.temp_allocator) : "—",
				COLS[5].w,
				true,
				t.up_rate > 1 ? "text-xs font-mono text-sky-500" : "text-xs font-mono text-muted-foreground",
			)
			ui_cell_text(
				ui,
				tsprint("%d (%d)", t.seeds_connected, t.seeds),
				COLS[6].w,
				true,
				"text-xs font-mono text-muted-foreground",
			)
			ui_cell_text(
				ui,
				tsprint("%d (%d)", t.peers_connected, t.leeches),
				COLS[7].w,
				true,
				"text-xs font-mono text-muted-foreground",
			)
			ui_cell_text(
				ui,
				t.ratio < 0 ? "inf" : tsprint("%.2f", t.ratio),
				COLS[8].w,
				true,
				"text-xs font-mono text-muted-foreground",
			)
			ui_cell_text(
				ui,
				t.state == .Downloading && t.eta > 0 \
				? human_duration(t.eta, context.temp_allocator) \
				: "—",
				COLS[9].w,
				true,
				"text-xs font-mono text-muted-foreground",
			)
		}
		p.end(ui)
	}
}

@(private = "file")
ui_cell_text :: proc(ui: ^p.Ctx, s: string, w: f32, right: bool, class: string) {
	p.col(ui, "justify-center px-2 shrink-0 overflow-hidden")
	p.style(ui).w = p.px(w)
	defer p.end(ui)
	p.text(ui, s, right ? p.concat(ui, class, " text-right w-full") : class)
}

@(private = "file")
ui_cell_progress :: proc(ui: ^p.Ctx, t: Torrent_View, w: f32) {
	p.col(ui, "justify-center px-2 gap-1 shrink-0")
	p.style(ui).w = p.px(w)
	defer p.end(ui)

	frac := t.progress
	if t.state == .Checking && t.check_total > 0 {
		frac = f32(t.check_done) / f32(t.check_total)
	}
	p.row(ui, "w-full items-center gap-2")
	{
		p.div(ui, "relative flex-row h-1.5 flex-1 items-center overflow-hidden rounded-full bg-muted")
		{
			p.div(ui, "h-full rounded-full")
			p.apply(
				ui,
				t.state == .Error \
				? "bg-destructive" \
				: (t.state == .Seeding ? "bg-sky-500" : (t.state == .Checking ? "bg-amber-500" : "bg-emerald-500")),
			)
			p.style(ui).w = p.pct(clampf(frac * 100, 0, 100))
			p.end(ui)
		}
		p.end(ui)
		p.text(ui, tsprint("%.1f%%", frac * 100), "text-[10] font-mono text-muted-foreground w-[42] text-right whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
}

@(private = "file")
ui_cell_state :: proc(ui: ^p.Ctx, t: Torrent_View, w: f32) {
	p.col(ui, "justify-center px-2 shrink-0 overflow-hidden")
	p.style(ui).w = p.px(w)
	defer p.end(ui)
	class := "text-xs whitespace-nowrap "
	switch t.state {
	case .Downloading:
		class = p.concat(ui, class, "text-emerald-500")
	case .Seeding:
		class = p.concat(ui, class, "text-sky-500")
	case .Checking:
		class = p.concat(ui, class, "text-amber-500")
	case .Stopped:
		class = p.concat(ui, class, "text-muted-foreground")
	case .Error:
		class = p.concat(ui, class, "text-destructive")
	}
	label := t.state_text
	if t.state == .Checking && t.check_total > 0 {
		label = tsprint("Checking %d%%", int(100 * f32(t.check_done) / f32(t.check_total)))
	}
	p.text(ui, label, class)
}

// ---------------------------------------------------------------------------
// The details pane
// ---------------------------------------------------------------------------

@(private = "file")
ui_details :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom) {
	p.col(ui, "w-full shrink-0 overflow-hidden")
	p.style(ui).h = p.px(g.detail_h)
	defer p.end(ui)

	// The tab strip.
	p.row(ui, "w-full items-center gap-1 px-3 border-b border-border bg-muted/30 shrink-0")
	p.style(ui).h = p.px(TABS_H)
	{
		for tb in Tab {
			idx := p.row(ui, "items-center h-7 px-2.5 rounded-md shrink-0 cursor-pointer transition")
			if tb == u.tab {
				p.apply(ui, "bg-background shadow-sm")
			} else {
				p.apply(ui, "hover:bg-muted")
			}
			if p.clickable(ui, idx) {
				u.tab = tb
			}
			p.text(
				ui,
				tab_name(tb),
				tb == u.tab \
				? "text-xs font-medium text-foreground whitespace-nowrap" \
				: "text-xs text-muted-foreground whitespace-nowrap",
			)
			p.style(ui).shrink = 0
			p.text(ui, tsprint("%d", int(tb) + 1), "text-[9] font-mono text-muted-foreground ml-1 whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.spacer(ui, "flex-1")
		t, ok := ui_selected(u)
		if ok {
			p.text(ui, t.name, "text-xs text-muted-foreground truncate max-w-[420]")
		}
	}
	p.end(ui)

	body := p.col(ui, "w-full overflow-hidden shrink-0")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	t, ok := ui_selected(u)
	if !ok {
		p.col(ui, "w-full items-center justify-center")
		p.style(ui).h = p.px(g.body_h)
		p.text(ui, "Nothing selected", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	_ = body

	switch u.tab {
	case .General:
		ui_tab_general(u, ui, g, t)
	case .Peers:
		ui_tab_peers(u, ui, g, t)
	case .Files:
		ui_tab_files(u, ui, g, t)
	case .Trackers:
		ui_tab_trackers(u, ui, g, t)
	case .Graph:
		ui_tab_graph(u, ui, g, t)
	}
}

@(private = "file")
ui_kv :: proc(ui: ^p.Ctx, k, v: string, mono := false) {
	p.row(ui, "w-full items-baseline gap-2 shrink-0")
	p.style(ui).h = p.px(20)
	defer p.end(ui)
	p.text(ui, k, "text-xs text-muted-foreground w-[120] shrink-0 whitespace-nowrap")
	p.text(ui, v, mono ? "text-xs font-mono truncate" : "text-xs truncate")
}

@(private = "file")
ui_tab_general :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom, t: Torrent_View) {
	p.row(ui, "w-full gap-6 p-3 overflow-hidden")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	// Left: the piece map and the headline numbers.
	p.col(ui, "gap-2 shrink-0 w-[520]")
	{
		p.text(ui, "Pieces", "text-xs font-medium")
		// The piece map: one cell per bucket, filled when the pieces in that
		// bucket are in hand. This is the thing that makes a transfer legible.
		p.pixels(ui, "w-full h-10 rounded-md bg-muted overflow-hidden", &u.view, draw_piece_map)
		p.row(ui, "w-full items-center gap-3")
		{
			p.text(
				ui,
				tsprint("%d / %d pieces", t.have_pieces, t.piece_count),
				"text-xs font-mono text-muted-foreground whitespace-nowrap",
			)
			p.text(
				ui,
				tsprint("%s each", human_size(t.piece_length, context.temp_allocator)),
				"text-xs font-mono text-muted-foreground whitespace-nowrap",
			)
			p.text(
				ui,
				tsprint("%d verified", t.pieces_verified),
				"text-xs font-mono text-emerald-500 whitespace-nowrap",
			)
		}
		p.end(ui)
		ui_kv(ui, "Downloaded", human_size(t.downloaded, context.temp_allocator), true)
		ui_kv(ui, "Uploaded", human_size(t.uploaded, context.temp_allocator), true)
		ui_kv(
			ui,
			"Wasted",
			t.wasted == 0 \
			? "0 B (no block failed a hash check)" \
			: human_size(t.wasted, context.temp_allocator),
			true,
		)
		ui_kv(ui, "Ratio", t.ratio < 0 ? "inf" : tsprint("%.3f", t.ratio), true)
	}
	p.end(ui)

	p.div(ui, "w-px h-full bg-border shrink-0")
	p.end(ui)

	// Right: the identity of the torrent.
	p.col(ui, "gap-0 flex-1 overflow-hidden")
	{
		ui_kv(ui, "Name", t.name)
		ui_kv(ui, "Info hash", t.info_hash, true)
		ui_kv(ui, "Total size", human_size(t.size, context.temp_allocator), true)
		ui_kv(ui, "Files", tsprint("%d", len(t.files)))
		ui_kv(ui, "Layout", t.single_file ? "single file" : "directory")
		ui_kv(ui, "Private", t.private ? "yes (no DHT or PEX)" : "no")
		ui_kv(ui, "Save to", t.dir, true)
		ui_kv(ui, "Torrent file", t.torrent_path, true)
		ui_kv(ui, "Created by", t.created_by == "" ? "—" : t.created_by)
		ui_kv(ui, "Comment", t.comment == "" ? "—" : t.comment)
		ui_kv(ui, "Magnet", t.magnet, true)
		if t.err != "" {
			p.text(ui, t.err, "text-xs text-destructive mt-1")
		}
	}
	p.end(ui)
}

@(private = "file")
draw_piece_map :: proc(c: ^p.Canvas, r: p.Rect, v: ^Engine_View) {
	// Drawn straight into the buffer, because a bar of 220 separate elements is
	// 220 nodes of layout for something that is a single row of pixels.
	if len(v.torrents) == 0 {
		return
	}
	// The selected torrent is the one carrying a piece map in the snapshot.
	hm: []f32
	for t in v.torrents {
		if len(t.have_map) > 0 {
			hm = t.have_map
			break
		}
	}
	if len(hm) == 0 {
		return
	}
	got := p.rgba(16, 185, 129) // emerald-500
	part := p.rgba(6, 95, 70) // emerald-900, for a partly-held bucket
	for i in 0 ..< len(hm) {
		x0 := r.x + r.w * f32(i) / f32(len(hm))
		x1 := r.x + r.w * f32(i + 1) / f32(len(hm))
		w := max(1, x1 - x0)
		if hm[i] >= 0.999 {
			p.fill_rect(c, p.Rect{x = x0, y = r.y, w = w, h = r.h}, got)
		} else if hm[i] > 0 {
			p.fill_rect(c, p.Rect{x = x0, y = r.y, w = w, h = r.h}, part)
		}
	}
}

@(private = "file")
ui_tab_peers :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom, t: Torrent_View) {
	p.col(ui, "w-full overflow-hidden")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	// Header.
	p.row(ui, "w-full items-center px-3 border-b border-border shrink-0")
	p.style(ui).h = p.px(DETAIL_ROW_H)
	{
		ui_dhead(ui, "Address", 150, false)
		ui_dhead(ui, "Client", 130, false)
		ui_dhead(ui, "Flags", 80, false)
		ui_dhead(ui, "Progress", 130, false)
		ui_dhead(ui, "Down", 90, true)
		ui_dhead(ui, "Up", 90, true)
		ui_dhead(ui, "Got", 90, true)
		ui_dhead(ui, "Sent", 90, true)
		ui_dhead(ui, "Reqs", 60, true)
		ui_dhead(ui, "Dir", 60, false)
	}
	p.end(ui)

	if len(t.peers) == 0 {
		p.col(ui, "w-full items-center justify-center")
		p.style(ui).h = p.px(g.body_h - DETAIL_ROW_H)
		p.text(ui, "No peers connected", "text-xs text-muted-foreground")
		p.text(
			ui,
			"Peers come from the tracker, and only loopback addresses are dialled.",
			"text-[10] text-muted-foreground",
		)
		p.end(ui)
		return
	}

	rows := max(1, g.drows - 1)
	top := clamp(u.peer_sel - rows / 2, 0, max(0, len(t.peers) - rows))
	for i in top ..< min(len(t.peers), top + rows) {
		pv := t.peers[i]
		p.row(ui, "w-full items-center px-3 shrink-0")
		p.style(ui).h = p.px(DETAIL_ROW_H)
		if i == u.peer_sel {
			p.apply(ui, "bg-primary/10")
		}
		{
			ui_dcell(ui, tsprint("%s:%d", pv.host, pv.port), 150, false, "text-xs font-mono")
			ui_dcell(ui, pv.client, 130, false, "text-xs")
			ui_dcell(ui, pv.flags, 80, false, "text-xs font-mono text-muted-foreground")
			// A small inline bar, because a number alone does not show a peer
			// catching up.
			p.col(ui, "justify-center px-1 shrink-0")
			p.style(ui).w = p.px(130)
			{
				p.row(ui, "w-full items-center gap-2")
				{
					p.div(ui, "relative flex-row h-1 flex-1 rounded-full bg-muted overflow-hidden")
					p.div(ui, pv.seed ? "h-full bg-sky-500" : "h-full bg-emerald-500")
					p.style(ui).w = p.pct(clampf(pv.progress * 100, 0, 100))
					p.end(ui)
					p.end(ui)
					p.text(
						ui,
						pv.seed ? "seed" : tsprint("%.0f%%", pv.progress * 100),
						"text-[10] font-mono text-muted-foreground w-[34] text-right whitespace-nowrap",
					)
					p.style(ui).shrink = 0
				}
				p.end(ui)
			}
			p.end(ui)
			ui_dcell(
				ui,
				pv.down_rate > 1 ? human_rate(pv.down_rate, context.temp_allocator) : "—",
				90,
				true,
				pv.down_rate > 1 ? "text-xs font-mono text-emerald-500" : "text-xs font-mono text-muted-foreground",
			)
			ui_dcell(
				ui,
				pv.up_rate > 1 ? human_rate(pv.up_rate, context.temp_allocator) : "—",
				90,
				true,
				pv.up_rate > 1 ? "text-xs font-mono text-sky-500" : "text-xs font-mono text-muted-foreground",
			)
			ui_dcell(ui, human_size(pv.downloaded, context.temp_allocator), 90, true, "text-xs font-mono text-muted-foreground")
			ui_dcell(ui, human_size(pv.uploaded, context.temp_allocator), 90, true, "text-xs font-mono text-muted-foreground")
			ui_dcell(ui, tsprint("%d", pv.requests), 60, true, "text-xs font-mono text-muted-foreground")
			ui_dcell(ui, pv.incoming ? "in" : "out", 60, false, "text-xs text-muted-foreground")
		}
		p.end(ui)
	}
	p.text(
		ui,
		"Flags: O/I outgoing or incoming · i we are interested · C they choke us · r they want data · u/c we unchoke or choke · S seed",
		"text-[10] text-muted-foreground px-3 pt-1",
	)
}

@(private = "file")
ui_dhead :: proc(ui: ^p.Ctx, s: string, w: f32, right: bool) {
	p.col(ui, "justify-center shrink-0 px-1")
	p.style(ui).w = p.px(w)
	defer p.end(ui)
	p.text(
		ui,
		s,
		right \
		? "text-[10] font-medium text-muted-foreground text-right w-full whitespace-nowrap" \
		: "text-[10] font-medium text-muted-foreground whitespace-nowrap",
	)
}

@(private = "file")
ui_dcell :: proc(ui: ^p.Ctx, s: string, w: f32, right: bool, class: string) {
	p.col(ui, "justify-center shrink-0 px-1 overflow-hidden")
	p.style(ui).w = p.px(w)
	defer p.end(ui)
	p.text(ui, s, right ? p.concat(ui, class, " text-right w-full") : p.concat(ui, class, " truncate"))
}

@(private = "file")
ui_tab_files :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom, t: Torrent_View) {
	p.col(ui, "w-full overflow-hidden")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	p.row(ui, "w-full items-center px-3 border-b border-border shrink-0")
	p.style(ui).h = p.px(DETAIL_ROW_H)
	{
		ui_dhead(ui, "File", 430, false)
		ui_dhead(ui, "Size", 100, true)
		ui_dhead(ui, "Progress", 180, false)
		ui_dhead(ui, "Pieces", 110, true)
		ui_dhead(ui, "Priority", 130, false)
	}
	p.end(ui)

	rows := max(1, g.drows - 2)
	u.file_sel = clamp(u.file_sel, 0, max(0, len(t.files) - 1))
	top := clamp(u.file_sel - rows / 2, 0, max(0, len(t.files) - rows))
	for i in top ..< min(len(t.files), top + rows) {
		f := t.files[i]
		row := p.row(ui, "w-full items-center px-3 shrink-0 cursor-pointer")
		p.style(ui).h = p.px(DETAIL_ROW_H)
		if i == u.file_sel {
			p.apply(ui, "bg-primary/10")
		} else {
			p.apply(ui, "hover:bg-accent")
		}
		if p.clickable(ui, row) {
			u.file_sel = i
		}
		{
			p.row(ui, "items-center gap-1.5 shrink-0 px-1 overflow-hidden")
			p.style(ui).w = p.px(430)
			{
				p.icon(
					ui,
					f.prio == .Skip ? sc.ICON_X : kit.ICON_FILE,
					f.prio == .Skip ? "size-3.5 text-muted-foreground" : "size-3.5 text-muted-foreground",
				)
				p.text(
					ui,
					f.path,
					f.prio == .Skip ? "text-xs text-muted-foreground truncate line-through" : "text-xs truncate",
				)
			}
			p.end(ui)
			ui_dcell(ui, human_size(f.length, context.temp_allocator), 100, true, "text-xs font-mono text-muted-foreground")
			p.col(ui, "justify-center px-1 shrink-0")
			p.style(ui).w = p.px(180)
			{
				p.row(ui, "w-full items-center gap-2")
				{
					p.div(ui, "relative flex-row h-1 flex-1 rounded-full bg-muted overflow-hidden")
					p.div(ui, f.prio == .Skip ? "h-full bg-muted-foreground" : "h-full bg-emerald-500")
					p.style(ui).w = p.pct(clampf(f.progress * 100, 0, 100))
					p.end(ui)
					p.end(ui)
					p.text(ui, tsprint("%.0f%%", f.progress * 100), "text-[10] font-mono text-muted-foreground w-[34] text-right whitespace-nowrap")
					p.style(ui).shrink = 0
				}
				p.end(ui)
			}
			p.end(ui)
			ui_dcell(ui, tsprint("%d–%d", f.first, max(f.first, f.last - 1)), 110, true, "text-xs font-mono text-muted-foreground")
			// The priority chip.
			p.col(ui, "justify-center px-1 shrink-0")
			p.style(ui).w = p.px(130)
			{
				cls := "text-[10] px-1.5 py-0.5 rounded-md whitespace-nowrap "
				switch f.prio {
				case .Skip:
					cls = p.concat(ui, cls, "bg-destructive/15 text-destructive")
				case .Low:
					cls = p.concat(ui, cls, "bg-muted text-muted-foreground")
				case .Normal:
					cls = p.concat(ui, cls, "bg-muted text-foreground")
				case .High:
					cls = p.concat(ui, cls, "bg-primary/20 text-primary")
				}
				p.div(ui, "self-start")
				p.text(ui, file_prio_name(f.prio), cls)
				p.end(ui)
			}
			p.end(ui)
		}
		p.end(ui)
	}
	p.text(
		ui,
		"j / k move · Left / Right change priority (Don't download · Low · Normal · High). A piece shared with a wanted file is still fetched.",
		"text-[10] text-muted-foreground px-3 pt-1",
	)
}

@(private = "file")
ui_tab_trackers :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom, t: Torrent_View) {
	p.col(ui, "w-full overflow-hidden p-3 gap-2")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	if len(t.trackers) == 0 {
		p.text(ui, "This torrent lists no trackers.", "text-xs text-muted-foreground")
		return
	}
	for tr, i in t.trackers {
		if i >= max(1, g.drows - 1) {
			break
		}
		p.row(ui, "w-full items-center gap-3 shrink-0")
		p.style(ui).h = p.px(DETAIL_ROW_H)
		{
			ok := tr.announces > 0 && !strings.contains(tr.status, "refus") && tr.status == "working"
			p.div(ui, ok ? "size-2 rounded-full bg-emerald-500 shrink-0" : "size-2 rounded-full bg-amber-500 shrink-0")
			p.end(ui)
			p.text(ui, tr.url, "text-xs font-mono w-[330] truncate shrink-0")
			p.text(ui, tr.status, ok ? "text-xs text-emerald-500 w-[260] truncate shrink-0" : "text-xs text-amber-500 w-[260] truncate shrink-0")
			p.text(ui, tsprint("%d seeds", tr.seeders), "text-xs font-mono text-muted-foreground w-[90] shrink-0")
			p.text(ui, tsprint("%d leechers", tr.leechers), "text-xs font-mono text-muted-foreground w-[110] shrink-0")
			p.text(ui, tsprint("%d announces", tr.announces), "text-xs font-mono text-muted-foreground w-[120] shrink-0")
			p.text(ui, tsprint("next in %.0fs", tr.next_in), "text-xs font-mono text-muted-foreground shrink-0")
		}
		p.end(ui)
	}
	p.text(
		ui,
		"The tracker's `interval` is honoured. There is no DHT and no peer exchange in this client, by design.",
		"text-[10] text-muted-foreground pt-1",
	)
}

Graph_Data :: struct {
	down: []f32,
	up:   []f32,
}

@(private = "file")
ui_tab_graph :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom, t: Torrent_View) {
	p.col(ui, "w-full p-3 gap-2 overflow-hidden")
	p.style(ui).h = p.px(g.body_h)
	defer p.end(ui)

	peak: f32 = 0
	for v in t.down_hist {
		peak = max(peak, v)
	}
	for v in t.up_hist {
		peak = max(peak, v)
	}

	p.row(ui, "w-full items-center gap-4 shrink-0")
	{
		p.row(ui, "items-center gap-1.5 shrink-0")
		p.div(ui, "size-2 rounded-full bg-emerald-500")
		p.end(ui)
		p.text(ui, tsprint("down %s", human_rate(t.down_rate, context.temp_allocator)), "text-xs font-mono whitespace-nowrap")
		p.end(ui)
		p.row(ui, "items-center gap-1.5 shrink-0")
		p.div(ui, "size-2 rounded-full bg-sky-500")
		p.end(ui)
		p.text(ui, tsprint("up %s", human_rate(t.up_rate, context.temp_allocator)), "text-xs font-mono whitespace-nowrap")
		p.end(ui)
		p.spacer(ui, "flex-1")
		p.text(
			ui,
			tsprint("peak %s · %d seconds", human_rate(f64(peak), context.temp_allocator), len(t.down_hist)),
			"text-xs font-mono text-muted-foreground whitespace-nowrap",
		)
	}
	p.end(ui)

	gd := Graph_Data {
		down = t.down_hist,
		up   = t.up_hist,
	}
	data := new_clone(gd, context.temp_allocator)
	p.pixels(ui, "w-full rounded-md bg-muted/40 overflow-hidden shrink-0", data, draw_rate_graph)
	p.style(ui).h = p.px(max(40, g.body_h - 56))
}

@(private = "file")
draw_rate_graph :: proc(c: ^p.Canvas, r: p.Rect, d: ^Graph_Data) {
	grid := p.rgba(128, 128, 128, 64)
	for i in 1 ..< 4 {
		y := r.y + r.h * f32(i) / 4
		p.fill_rect(c, p.Rect{x = r.x, y = y, w = r.w, h = 1}, grid)
	}
	n := max(len(d.down), len(d.up))
	if n < 2 {
		return
	}
	peak: f32 = 1
	for v in d.down {
		peak = max(peak, v)
	}
	for v in d.up {
		peak = max(peak, v)
	}

	plot :: proc(c: ^p.Canvas, r: p.Rect, vals: []f32, peak: f32, n: int, col: p.Color, fill: p.Color) {
		if len(vals) < 2 {
			return
		}
		for i in 0 ..< len(vals) - 1 {
			x0 := r.x + r.w * f32(i) / f32(n - 1)
			x1 := r.x + r.w * f32(i + 1) / f32(n - 1)
			y0 := r.y + r.h - r.h * clampf(vals[i] / peak, 0, 1)
			y1 := r.y + r.h - r.h * clampf(vals[i + 1] / peak, 0, 1)
			// The area under the line, so the two series read as volumes.
			top := min(y0, y1)
			p.fill_rect(c, p.Rect{x = x0, y = top, w = max(1, x1 - x0), h = r.y + r.h - top}, fill)
			p.draw_line(c, x0, y0, x1, y1, 1.5, col)
		}
	}
	plot(c, r, d.up, peak, n, p.rgba(14, 165, 233), p.rgba(14, 165, 233, 32))
	plot(c, r, d.down, peak, n, p.rgba(16, 185, 129), p.rgba(16, 185, 129, 40))
}

// ---------------------------------------------------------------------------
// The status bar
// ---------------------------------------------------------------------------

@(private = "file")
ui_status :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom) {
	p.row(ui, "w-full items-center gap-3 px-3 border-t border-border bg-muted/40 shrink-0 overflow-hidden")
	p.style(ui).h = p.px(STATUS_H)
	defer p.end(ui)

	if u.toast != "" {
		if now_s() - u.toast_at > 7 {
			delete(u.toast)
			u.toast = ""
		} else {
			p.icon(ui, sc.ICON_INFO, "size-3.5 text-primary")
			p.text(ui, u.toast, "text-xs truncate")
			p.spacer(ui, "flex-1")
		}
	}
	if u.toast == "" {
		p.text(
			ui,
			tsprint("%d torrent%s", len(u.view.torrents), len(u.view.torrents) == 1 ? "" : "s"),
			"text-xs text-muted-foreground whitespace-nowrap",
		)
		p.text(ui, "·", "text-xs text-muted-foreground")
		p.text(
			ui,
			"loopback only — no DHT, no peer exchange, no port forwarding",
			"text-xs text-muted-foreground whitespace-nowrap",
		)
		p.spacer(ui, "flex-1")
		p.text(
			ui,
			"A add · M magnet · P pause · R recheck · Del remove · Shift+Del remove+data · 1-5 tabs · ? help",
			"text-[10] text-muted-foreground whitespace-nowrap",
		)
	}
	if u.view.last_error != "" {
		p.text(ui, u.view.last_error, "text-xs text-destructive truncate max-w-[480]")
	}
}

// ---------------------------------------------------------------------------
// Dialogs
//
// There is no xdg_popup in palmy, so these are absolutely positioned overlays
// inside the window with a backdrop behind them.
// ---------------------------------------------------------------------------

@(private = "file")
ui_dialog :: proc(u: ^Ui, ui: ^p.Ctx, g: Geom) {
	// The backdrop.
	p.div(ui, "absolute inset-0 bg-black/50 z-40")
	p.end(ui)

	p.col(ui, "absolute inset-0 items-center justify-center z-50")
	defer p.end(ui)

	switch u.dialog {
	case .None:
	case .Add_File:
		ui_dialog_add_file(u, ui)
	case .Add_Magnet:
		ui_dialog_add_magnet(u, ui)
	case .Remove:
		ui_dialog_remove(u, ui, false)
	case .Remove_Data:
		ui_dialog_remove(u, ui, true)
	case .Help:
		ui_dialog_help(u, ui)
	}
}

@(private = "file")
dialog_panel_open :: proc(ui: ^p.Ctx, w: f32) {
	p.col(ui, "gap-4 rounded-xl bg-popover p-4 text-popover-foreground shadow-2xl ring-1 ring-foreground/10")
	p.style(ui).w = p.px(w)
}

@(private = "file")
ui_dialog_add_file :: proc(u: ^Ui, ui: ^p.Ctx) {
	dialog_panel_open(ui, 640)
	defer p.end(ui)

	p.text(ui, "Add a torrent", "text-base font-medium")
	p.text(
		ui,
		"A .torrent file on disk. Nothing is fetched over the network to read it.",
		"text-xs text-muted-foreground",
	)

	p.text(ui, "Torrent file", "text-xs font-medium mt-1")
	path_field := p.node_count(ui)
	p.text_field(ui, &u.path_buf, "/path/to/file.torrent", "w-full h-9 text-sm bg-background border-border")
	if u.dialog_field == 0 {
		p.set_focus(ui, p.node_id(ui, path_field))
	}

	p.text(ui, "Save to", "text-xs font-medium")
	dir_field := p.node_count(ui)
	p.text_field(ui, &u.dir_buf, "~/Downloads", "w-full h-9 text-sm bg-background border-border")
	if u.dialog_field == 1 {
		p.set_focus(ui, p.node_id(ui, dir_field))
	}

	// A preview of what will be added, parsed right here, so a bad path or a
	// malformed file is visible before anything is started.
	path := strings.trim_space(string(u.path_buf[:]))
	if path != "" {
		full := expand_home(path, context.temp_allocator)
		if !path_exists(full) {
			p.text(ui, tsprint("%s does not exist", full), "text-xs text-destructive")
		} else if m, err := metainfo_load(full, context.temp_allocator); err != "" {
			p.text(ui, err, "text-xs text-destructive")
		} else {
			p.col(ui, "gap-0.5 rounded-lg bg-muted/50 p-2")
			ui_kv(ui, "Name", m.name)
			ui_kv(ui, "Size", human_size(m.total_length, context.temp_allocator), true)
			ui_kv(ui, "Files", tsprint("%d", len(m.files)))
			ui_kv(ui, "Pieces", tsprint("%d × %s", len(m.pieces), human_size(m.piece_length, context.temp_allocator)), true)
			ui_kv(ui, "Info hash", hash20_hex(m.info_hash, context.temp_allocator), true)
			ui_kv(ui, "Tracker", len(m.announce_list) > 0 ? m.announce_list[0] : "none", true)
			p.end(ui)
		}
	}

	p.row(ui, "w-full justify-end gap-2 pt-1")
	{
		if ui_dialog_button(u, ui, "Cancel", false, false) {
			u.dialog = .None
		}
		if ui_dialog_button(u, ui, "Add torrent", true, false) {
			ui_do_add_file(u)
		}
	}
	p.end(ui)
	p.text(ui, "Tab moves between the fields · Enter adds · Escape cancels", "text-[10] text-muted-foreground")
}

@(private = "file")
ui_dialog_add_magnet :: proc(u: ^Ui, ui: ^p.Ctx) {
	dialog_panel_open(ui, 640)
	defer p.end(ui)

	p.text(ui, "Add a magnet link", "text-base font-medium")
	p.text_field(ui, &u.magnet_buf, "magnet:?xt=urn:btih:…", "w-full h-9 text-sm font-mono bg-background border-border")

	uri := strings.trim_space(string(u.magnet_buf[:]))
	if uri != "" {
		if mg, err := magnet_parse(uri, context.temp_allocator); err != "" {
			p.text(ui, err, "text-xs text-destructive")
		} else {
			p.col(ui, "gap-0.5 rounded-lg bg-muted/50 p-2")
			ui_kv(ui, "Info hash", hash20_hex(mg.info_hash, context.temp_allocator), true)
			ui_kv(ui, "Name", mg.name == "" ? "—" : mg.name)
			ui_kv(ui, "Trackers", tsprint("%d", len(mg.trackers)))
			p.end(ui)
		}
	}
	p.col(ui, "gap-1 rounded-lg bg-amber-500/10 p-2")
	{
		p.row(ui, "items-center gap-1.5")
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-3.5 text-amber-500")
		p.text(ui, "A magnet carries only a hash", "text-xs font-medium text-amber-500")
		p.end(ui)
		p.text(
			ui,
			"Turning one into a torrent means asking a stranger for the metadata over a DHT, which this client will not do. A magnet is resolved against ~/.local/share/palmy-torrent/<info-hash>.torrent instead.",
			"text-[10] text-muted-foreground",
		)
	}
	p.end(ui)

	p.row(ui, "w-full justify-end gap-2 pt-1")
	{
		if ui_dialog_button(u, ui, "Cancel", false, false) {
			u.dialog = .None
		}
		if ui_dialog_button(u, ui, "Add magnet", true, false) {
			ui_do_add_magnet(u)
		}
	}
	p.end(ui)
}

// ui_dialog_remove is the destructive one, and it is built to be hard to get
// wrong: the data variant names every path it will delete, says the deletion
// cannot be undone, and starts with Cancel selected.
@(private = "file")
ui_dialog_remove :: proc(u: ^Ui, ui: ^p.Ctx, with_data: bool) {
	t, ok := ui_selected(u)
	if !ok {
		u.dialog = .None
		return
	}
	dialog_panel_open(ui, 660)
	defer p.end(ui)

	if with_data {
		p.row(ui, "items-center gap-2")
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-5 text-destructive")
		p.text(ui, "Delete the downloaded data?", "text-base font-medium text-destructive")
		p.end(ui)
		p.text(
			ui,
			tsprint("This removes %s from the list AND deletes the files below from your disk. It cannot be undone.", t.name),
			"text-sm",
		)
		p.col(ui, "gap-1 rounded-lg bg-destructive/10 p-2")
		{
			p.text(ui, "These paths will be deleted:", "text-xs font-medium text-destructive")
			base := t.single_file ? t.dir : path_join(t.dir, t.name, allocator = context.temp_allocator)
			if t.single_file {
				for f, i in t.files {
					if i >= 8 {
						break
					}
					p.text(ui, path_join(t.dir, f.path, allocator = context.temp_allocator), "text-xs font-mono")
				}
			} else {
				p.text(ui, base, "text-xs font-mono")
				p.text(
					ui,
					tsprint("…and everything under it: %d file%s, %s", len(t.files), len(t.files) == 1 ? "" : "s", human_size(t.size, context.temp_allocator)),
					"text-xs text-muted-foreground",
				)
			}
		}
		p.end(ui)
	} else {
		p.text(ui, "Remove this torrent?", "text-base font-medium")
		p.text(
			ui,
			tsprint("%s is removed from the list. The downloaded files stay on disk at %s.", t.name, t.dir),
			"text-sm",
		)
		p.text(
			ui,
			"Use Remove + data (Shift+Del) if you also want the files deleted.",
			"text-xs text-muted-foreground",
		)
	}

	p.row(ui, "w-full justify-end gap-2 pt-1")
	{
		// Cancel first, and selected: the destructive button is never the one
		// Enter presses by default.
		if ui_dialog_button(u, ui, "Cancel", u.confirm_sel == 0, false) {
			u.dialog = .None
		}
		if ui_dialog_button(
			u,
			ui,
			with_data ? "Delete the files" : "Remove",
			u.confirm_sel == 1,
			with_data,
		) {
			ui_do_remove(u, with_data)
			u.dialog = .None
		}
	}
	p.end(ui)
	p.text(
		ui,
		with_data \
		? "Left / Right choose · Enter confirms the highlighted button · Escape cancels. Cancel is selected." \
		: "Left / Right choose · Enter confirms · Escape cancels",
		"text-[10] text-muted-foreground",
	)
}

@(private = "file")
ui_dialog_help :: proc(u: ^Ui, ui: ^p.Ctx) {
	dialog_panel_open(ui, 620)
	defer p.end(ui)
	p.text(ui, "Keyboard", "text-base font-medium")
	rows := [?][2]string {
		{"↑ ↓ Home End", "move the selection"},
		{"A", "add a .torrent"},
		{"M", "add a magnet link"},
		{"P or Space", "pause / resume"},
		{"R", "force recheck (re-hash every piece)"},
		{"Del", "remove, leaving the files"},
		{"Sh+Del", "remove and delete the files"},
		{"1 … 5", "General, Peers, Files, Trackers, Speed"},
		{"Ctrl + Left/Right", "cycle the tabs"},
		{"j / k", "move within the Peers and Files tabs"},
		{"Left / Right", "change a file's priority in the Files tab"},
		{"[ ]", "shrink / grow the details pane"},
		{"?", "this"},
		{"q", "quit"},
	}
	p.col(ui, "gap-0.5")
	for r in rows {
		p.row(ui, "w-full items-baseline gap-3")
		p.text(ui, r[0], "text-xs font-mono w-[120] shrink-0 whitespace-nowrap")
		p.text(ui, r[1], "text-xs text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "w-full justify-end")
	if ui_dialog_button(u, ui, "Close", true, false) {
		u.dialog = .None
	}
	p.end(ui)
}

@(private = "file")
ui_dialog_button :: proc(
	u: ^Ui,
	ui: ^p.Ctx,
	label: string,
	primary: bool,
	destructive: bool,
) -> bool {
	idx := p.row(ui, "items-center justify-center h-8 px-3 rounded-lg border border-transparent shrink-0 cursor-pointer transition")
	if destructive {
		p.apply(ui, primary ? "bg-destructive text-white" : "bg-destructive/15 text-destructive hover:bg-destructive/25")
	} else if primary {
		p.apply(ui, "bg-primary text-primary-foreground hover:bg-primary/80")
	} else {
		p.apply(ui, "bg-background border-border hover:bg-muted")
	}
	if primary {
		p.apply(ui, "ring-2 ring-ring/60")
	}
	defer p.end(ui)
	p.text(ui, label, "text-sm whitespace-nowrap")
	p.style(ui).shrink = 0
	return p.clickable(ui, idx)
}

// ---------------------------------------------------------------------------
// The demo swarm
// ---------------------------------------------------------------------------

// DEMO_RATE throttles the download so the 2.5 MB payload takes about half a
// minute and the progress bar can be watched moving. The limiter is a real
// feature, not a sleep: it sizes the request pipeline to what the token bucket
// can pay for, so the transfer runs at a steady rate rather than in bursts.
DEMO_RATE :: 78 * 1024

Demo :: struct {
	root:      string,
	seed_dir:  string,
	out_dir:   string,
	torrent:   string,
	ports:     string,
	http_port: int,
	udp_port:  int,
	tracker:   os.Process,
	seeder:    os.Process,
	live:      bool,
}

demo_setup :: proc(d: ^Demo) -> (err: string) {
	bin, ok := find_self()
	if !ok {
		return "cannot find this binary to start the demo swarm"
	}
	d.root = asprint("/tmp/palmy-torrent-demo-%d", os.get_pid())
	rm_rf(d.root)
	d.seed_dir = path_join(d.root, "seed")
	d.out_dir = path_join(d.root, "downloads")
	d.torrent = path_join(d.root, "palmy-synthetic.torrent")
	d.ports = path_join(d.root, "ports")
	if e := make_dirs(d.seed_dir); e != "" {
		return e
	}
	if e := make_dirs(d.out_dir); e != "" {
		return e
	}
	if e := make_payload(d.seed_dir); e != "" {
		return e
	}

	logf, lerr := os.open(
		path_join(d.root, "tracker.log", allocator = context.temp_allocator),
		{.Write, .Create, .Trunc},
		os.Permissions_Default_File,
	)
	if lerr != nil {
		return tsprint("%v", lerr)
	}
	tp, terr := os.process_start(
		os.Process_Desc {
			command = {bin, "--tracker", "--http-port", "0", "--udp-port", "0", "--ports-file", d.ports, "--run-for", "1800"},
			stdout = logf,
			stderr = logf,
		},
	)
	os.close(logf)
	if terr != nil {
		return tsprint("cannot start the demo tracker: %v", terr)
	}
	d.tracker = tp
	d.live = true

	for i in 0 ..< 200 {
		if data, rok := read_file(d.ports, context.temp_allocator); rok && len(data) > 0 {
			for line in strings.split_lines(string(data), context.temp_allocator) {
				f := strings.fields(line, context.temp_allocator)
				if len(f) < 2 {
					continue
				}
				switch f[0] {
				case "http":
					d.http_port = parse_int_default(f[1], 0)
				case "udp":
					d.udp_port = parse_int_default(f[1], 0)
				}
			}
			if d.http_port > 0 {
				break
			}
		}
		time.sleep(25 * time.Millisecond)
	}
	if d.http_port == 0 {
		return "the demo tracker never reported its port"
	}

	data, cerr := metainfo_create(
		path_join(d.seed_dir, PAYLOAD_NAME, allocator = context.temp_allocator),
		Make_Opts {
			piece_length = PAYLOAD_PIECE_LENGTH,
			announce = asprint("http://127.0.0.1:%d/announce", d.http_port),
			comment = "synthetic payload generated by this process; nothing was downloaded",
		},
		context.temp_allocator,
	)
	if cerr != "" {
		return cerr
	}
	if werr := write_file(d.torrent, data); werr != "" {
		return werr
	}
	// The magnet cache, so the magnet dialog has something real to resolve.
	if m, merr := metainfo_parse(clone_bytes(data, context.temp_allocator), context.temp_allocator); merr == "" {
		cache := path_join(
			state_dir(context.temp_allocator),
			tsprint("%s.torrent", hash20_hex(m.info_hash, context.temp_allocator)),
			allocator = context.temp_allocator,
		)
		write_file(cache, data)
	}

	slogf, serr2 := os.open(
		path_join(d.root, "seeder.log", allocator = context.temp_allocator),
		{.Write, .Create, .Trunc},
		os.Permissions_Default_File,
	)
	if serr2 != nil {
		return tsprint("%v", serr2)
	}
	sp, serr := os.process_start(
		os.Process_Desc {
			command = {bin, "--engine", "--torrent", d.torrent, "--dir", d.seed_dir, "--port", "0", "--run-for", "1800"},
			stdout = slogf,
			stderr = slogf,
		},
	)
	os.close(slogf)
	if serr != nil {
		return tsprint("cannot start the demo seeder: %v", serr)
	}
	d.seeder = sp
	return ""
}

demo_teardown :: proc(d: ^Demo) {
	if !d.live {
		return
	}
	_ = os.process_kill(d.seeder)
	_, _ = os.process_wait(d.seeder)
	_ = os.process_kill(d.tracker)
	_, _ = os.process_wait(d.tracker)
	d.live = false
	// The demo's own scratch directory goes with it. The user's download
	// directory is never touched here.
	rm_rf(d.root)
}
