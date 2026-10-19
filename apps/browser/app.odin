// The browser's model: tabs, the engine's events, navigation.
//
// The window (ui_*.odin) draws this and turns input into the procedures here;
// the command line (main.odin) uses the same store procedures without a
// window. Nothing in this file draws.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import pb "pb"
import p "palmy:."

Page_Kind :: enum u8 {
	Web,
	New_Tab,
	Bookmarks,
	History,
	Downloads,
	Settings,
}

PAGE_URLS := [Page_Kind]string {
	.Web       = "",
	.New_Tab   = "palm://newtab",
	.Bookmarks = "palm://bookmarks",
	.History   = "palm://history",
	.Downloads = "palm://downloads",
	.Settings  = "palm://settings",
}

PAGE_TITLES := [Page_Kind]string {
	.Web       = "",
	.New_Tab   = "New Tab",
	.Bookmarks = "Bookmarks",
	.History   = "History",
	.Downloads = "Downloads",
	.Settings  = "Settings",
}

page_of_url :: proc(url: string) -> (Page_Kind, bool) {
	u := strings.to_lower(strings.trim_right(url, "/"), context.temp_allocator)
	for k in Page_Kind {
		if k != .Web && PAGE_URLS[k] == u {
			return k, true
		}
	}
	switch u {
	case "about:newtab", "about:home", "palm://home", "palm://new-tab":
		return .New_Tab, true
	case "palm://preferences", "about:preferences":
		return .Settings, true
	}
	return .Web, false
}

Load_Error :: struct {
	active: bool,
	code:   i32,
	text:   string,
	url:    string,
}

Tab :: struct {
	id:          int, // also the engine's view id
	page:        Page_Kind,
	url:         string,
	title:       string,
	has_view:    bool, // the engine has created a view for this tab
	pending_url: string, // a restored tab loads when first shown
	loading:     bool,
	progress:    f32,
	can_back:    bool,
	can_forward: bool,
	icon:        p.Image,
	has_icon:    bool,
	icon_url:    string,
	status:      string,
	cursor:      pb.Page_Cursor,
	zoom:        f32,
	error:       Load_Error,
	crashed:     string,
	selection:   string,
	// the internal page this tab showed before its first web page, which Back
	// returns to once the engine has no history left
	back_page:   Page_Kind,
	find_count:  i32,
	find_active: i32,
	opened_at:   i64,
}

Focus :: enum u8 {
	None,
	Page,
	Omnibox,
	Find,
	Field, // a field on an internal page
	Dialog,
	Bar, // the "Save this login?" bar
}

Overlay :: enum u8 {
	None,
	App_Menu,
	Context_Menu,
	Identity_Menu,
	Bookmark_Edit,
	Downloads,
	Tab_Search,
	Shortcuts,
	Confirm_Clear,
	Folder_Menu,
}

Page_Dialog :: struct {
	active:  bool,
	view:    int,
	id:      u32,
	kind:    pb.Dialog_Kind,
	message: string,
	field:   Line_Edit,
}

Context_Menu :: struct {
	view:      int,
	id:        u32,
	x, y:      f32, // window coordinates
	link:      string,
	selection: string,
	src:       string,
	editable:  bool,
	sel:       int,
}

Toast :: struct {
	text:   string,
	action: string, // "undo" shows an Undo button
	until:  time.Tick,
	undo:   [dynamic]Bookmark, // records to restore
}

State :: struct {
	app:          ^p.App,
	prof:         Profile,
	engine:       ^Engine,
	engine_kind:  Engine_Kind,
	dark:         bool,

	tabs:         [dynamic]^Tab,
	active:       int,
	next_id:      int,
	closed:       [dynamic]Session_Tab,

	bookmarks:    Bookmarks,
	history:      History,
	downloads:    [dynamic]Download,

	focus:        Focus,
	omni:         Line_Edit,
	omni_open:    bool, // the suggestion list is showing
	omni_sel:     int,
	suggestions:  [dynamic]Suggestion,
	find:         Line_Edit,
	find_open:    bool,

	overlay:      Overlay,
	menu_sel:     int,
	ctx_menu:     Context_Menu,
	dialog:       Page_Dialog,
	bm_edit:      struct {
		id:     string,
		title:  Line_Edit,
		url:    Line_Edit,
		folder: string,
		field:  int, // 0 title, 1 url
		is_new: bool,
	},
	toast:        Toast,
	restart_wanted: bool,

	// internal pages
	field:        Line_Edit, // the one focused field on an internal page
	field_page:   Page_Kind,
	list_sel:     int,
	bm_folder:    string, // the folder the manager shows
	settings_section: int,
	sync_status:  string,
	sync_busy:    bool,

	// geometry from the previous frame
	page_id:      u64,
	page_rect:    p.Rect,
	omni_id:      u64,
	drop_id:      u64,
	page_size:    [2]int,
	scale:        f32,
	pointer_in:   bool,
	capture:      bool,
	last_click:   time.Tick,
	last_click_at:[2]f32,
	clicks:       int,

	// remote requests from `browser open` while the window runs
	rlock:        sync.Mutex,
	remote:       [dynamic]string,
	snapshot:     string,

	menu_enter:   bool,
	menu_count:   int,
	folder_menu:  string,
	folder_menu_at: [2]f32,
	tab_w:        f32,
	window_w:     int,
	list_len:     int,
	list_enter:   bool,
	list_enter_new: bool,
	list_delete:  bool,
	list_edit:    bool,
	list_move:    int,

	quit:         bool,
	headless:     bool,
	af:           Autofill,
}

g_state: ^State

active_tab :: proc(s: ^State) -> ^Tab {
	if s.active < 0 || s.active >= len(s.tabs) {
		return nil
	}
	return s.tabs[s.active]
}

tab_by_view :: proc(s: ^State, view: int) -> ^Tab {
	for t in s.tabs {
		if t.id == view {
			return t
		}
	}
	return nil
}

tab_index :: proc(s: ^State, t: ^Tab) -> int {
	for x, i in s.tabs {
		if x == t {
			return i
		}
	}
	return -1
}

tab_title :: proc(t: ^Tab) -> string {
	if t.page != .Web {
		return PAGE_TITLES[t.page]
	}
	if t.error.active {
		return url_host(t.url) != "" ? url_host(t.url) : "Problem loading page"
	}
	if t.title != "" {
		return t.title
	}
	if t.url != "" {
		return display_url(t.url)
	}
	return "Loading…"
}

tab_url :: proc(t: ^Tab) -> string {
	return t.page != .Web ? PAGE_URLS[t.page] : t.url
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

new_tab :: proc(s: ^State, url: string, at := -1, activate := true, lazy := false) -> ^Tab {
	t := new(Tab)
	s.next_id += 1
	t.id = s.next_id
	t.zoom = s.prof.settings.zoom
	t.opened_at = now_ms()
	t.back_page = .Web
	idx := at < 0 || at > len(s.tabs) ? len(s.tabs) : at
	inject_at(&s.tabs, idx, t)
	if idx <= s.active && !activate && len(s.tabs) > 1 {
		s.active += 1
	}
	target := url == "" ? s.prof.settings.homepage : url
	if lazy {
		if k, ok := page_of_url(target); ok {
			t.page = k
		} else {
			t.page = .Web
			t.url = strings.clone(target)
			t.pending_url = strings.clone(target)
		}
	} else {
		navigate(s, t, target)
	}
	if activate {
		activate_tab(s, idx)
	}
	return t
}

activate_tab :: proc(s: ^State, idx: int) {
	if idx < 0 || idx >= len(s.tabs) {
		return
	}
	if old := active_tab(s); old != nil && old.has_view && s.active != idx {
		engine_show(s.engine, old.id, false)
	}
	s.active = idx
	t := s.tabs[idx]
	if t.pending_url != "" {
		url := t.pending_url
		t.pending_url = ""
		navigate(s, t, url)
	}
	if t.has_view && t.page == .Web {
		ensure_view_size(s, t)
		engine_show(s.engine, t.id, true)
	}
	s.omni_open = false
	s.find_open = false
	if t.page == .New_Tab {
		focus_omnibox(s, false)
	} else if t.page == .Web {
		set_focus(s, .Page)
	} else {
		set_focus(s, .None)
	}
	s.list_sel = 0
}

close_tab :: proc(s: ^State, idx: int) {
	if idx < 0 || idx >= len(s.tabs) {
		return
	}
	t := s.tabs[idx]
	if u := tab_url(t); u != "" && u != PAGE_URLS[.New_Tab] {
		append(&s.closed, Session_Tab{url = strings.clone(u), title = strings.clone(tab_title(t))})
	}
	if t.has_view {
		engine_close(s.engine, t.id)
	}
	ordered_remove(&s.tabs, idx)
	if len(s.tabs) == 0 {
		new_tab(s, PAGE_URLS[.New_Tab])
		return
	}
	if s.active > idx || s.active >= len(s.tabs) {
		s.active = max(0, s.active - 1)
	}
	if idx == s.active || s.active >= len(s.tabs) {
		s.active = min(idx, len(s.tabs) - 1)
	}
	activate_tab(s, s.active)
}

reopen_closed :: proc(s: ^State) {
	if len(s.closed) == 0 {
		return
	}
	last := pop(&s.closed)
	new_tab(s, last.url, s.active + 1)
}

move_tab :: proc(s: ^State, delta: int) {
	to := s.active + delta
	if to < 0 || to >= len(s.tabs) {
		return
	}
	s.tabs[s.active], s.tabs[to] = s.tabs[to], s.tabs[s.active]
	s.active = to
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

navigate :: proc(s: ^State, t: ^Tab, url: string) {
	t.error = {}
	t.crashed = ""
	if k, ok := page_of_url(url); ok {
		if t.page == .Web && t.has_view {
			engine_show(s.engine, t.id, false)
		}
		t.page = k
		return
	}
	if t.page != .Web {
		t.back_page = t.page
	}
	t.page = .Web
	delete(t.url)
	t.url = strings.clone(url)
	t.loading = true
	t.progress = 0.05
	if !t.has_view {
		w, h := view_size(s)
		engine_create(s.engine, t.id, w, h, s.scale, url)
		t.has_view = s.engine != nil && s.engine.ok
		if t.has_view && t.zoom != 1 {
			engine_zoom(s.engine, t.id, t.zoom)
		}
		// a view starts visible in CEF and hidden in the Gecko host, which
		// shows one tab at a time; say which explicitly
		if t.has_view {
			engine_show(s.engine, t.id, t == active_tab(s))
		}
	} else {
		engine_show(s.engine, t.id, true)
		engine_navigate(s.engine, t.id, url)
	}
}

// open_input resolves what was typed and navigates the tab to it.
open_input :: proc(s: ^State, text: string, new_tab_ := false) {
	url, _ := resolve_input(text, search_engine(s.prof.settings.search))
	if url == "" {
		return
	}
	if new_tab_ {
		new_tab(s, url, s.active + 1)
	} else if t := active_tab(s); t != nil {
		navigate(s, t, url)
		if t.page == .Web {
			set_focus(s, .Page)
		}
	}
}

go_back :: proc(s: ^State) {
	t := active_tab(s)
	if t == nil {
		return
	}
	if t.page == .Web && t.can_back {
		engine_back(s.engine, t.id)
	} else if t.page == .Web && t.back_page != .Web {
		engine_show(s.engine, t.id, false)
		t.page = t.back_page
	}
}

go_forward :: proc(s: ^State) {
	t := active_tab(s)
	if t == nil {
		return
	}
	if t.page != .Web && t.has_view && t.back_page == t.page {
		t.page = .Web
		engine_show(s.engine, t.id, true)
	} else if t.page == .Web && t.can_forward {
		engine_forward(s.engine, t.id)
	}
}

can_go_back :: proc(t: ^Tab) -> bool {
	return t != nil && t.page == .Web && (t.can_back || t.back_page != .Web)
}

can_go_forward :: proc(t: ^Tab) -> bool {
	return t != nil && ((t.page == .Web && t.can_forward) || (t.page != .Web && t.has_view && t.back_page == t.page))
}

reload :: proc(s: ^State, bypass := false) {
	t := active_tab(s)
	if t == nil || t.page != .Web {
		return
	}
	if t.crashed != "" || t.error.active {
		u := t.error.active && t.error.url != "" ? t.error.url : t.url
		t.crashed = ""
		t.error = {}
		engine_navigate(s.engine, t.id, u)
		return
	}
	engine_reload(s.engine, t.id, bypass)
}

stop_loading :: proc(s: ^State) {
	if t := active_tab(s); t != nil && t.page == .Web && t.loading {
		engine_stop_loading(s.engine, t.id)
	}
}

set_zoom :: proc(s: ^State, z: f32) {
	t := active_tab(s)
	if t == nil {
		return
	}
	LEVELS := [?]f32{0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5}
	t.zoom = clamp(z, LEVELS[0], LEVELS[len(LEVELS) - 1])
	if t.has_view {
		engine_zoom(s.engine, t.id, t.zoom)
	}
	toast(s, fmt.tprintf("Zoom %d%%", int(t.zoom * 100 + 0.5)))
}

zoom_step :: proc(s: ^State, dir: int) {
	t := active_tab(s)
	if t == nil {
		return
	}
	LEVELS := [?]f32{0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5}
	cur := t.zoom
	if dir > 0 {
		for l in LEVELS {
			if l > cur + 0.001 {
				set_zoom(s, l)
				return
			}
		}
	} else {
		#reverse for l in LEVELS {
			if l < cur - 0.001 {
				set_zoom(s, l)
				return
			}
		}
	}
}

view_size :: proc(s: ^State) -> (w, h: int) {
	w, h = s.page_size.x, s.page_size.y
	if w <= 0 || h <= 0 {
		if s.app != nil {
			w = s.app.win.width
			h = max(s.app.win.height - 120, 200)
		} else {
			w, h = 1280, 720
		}
	}
	return
}

ensure_view_size :: proc(s: ^State, t: ^Tab) {
	w, h := view_size(s)
	engine_resize(s.engine, t.id, w, h, s.scale)
}

set_focus :: proc(s: ^State, f: Focus) {
	t := active_tab(s)
	if s.focus == .Page && f != .Page && t != nil && t.has_view {
		engine_focus(s.engine, t.id, false)
	}
	if f == .Page && t != nil && t.has_view && t.page == .Web {
		engine_focus(s.engine, t.id, true)
	}
	if f != .Omnibox {
		s.omni_open = false
	}
	s.focus = f
}

focus_omnibox :: proc(s: ^State, select_all := true) {
	t := active_tab(s)
	text := ""
	if t != nil && t.page == .Web {
		text = t.url
	}
	edit_set(&s.omni, text, select_all)
	set_focus(s, .Omnibox)
	s.omni_open = false
	s.omni_sel = 0
}

toast :: proc(s: ^State, text: string, action := "") {
	delete(s.toast.text)
	s.toast.text = strings.clone(text)
	s.toast.action = action
	s.toast.until = time.tick_add(time.tick_now(), action != "" ? 5 * time.Second : 2 * time.Second)
	if s.app != nil {
		p.wake_after(s.app, action != "" ? 5 * time.Second : 2 * time.Second)
	}
}

// ---------------------------------------------------------------------------
// Bookmarks from the window
// ---------------------------------------------------------------------------

toggle_bookmark :: proc(s: ^State) {
	t := active_tab(s)
	if t == nil || t.page != .Web || t.url == "" {
		return
	}
	if b := bookmarked(&s.bookmarks, t.url); b != nil {
		open_bookmark_editor(s, b.id, false)
		return
	}
	b := bookmark_add(&s.bookmarks, ROOT_TOOLBAR, tab_title(t), t.url)
	bookmarks_save(&s.bookmarks)
	open_bookmark_editor(s, b.id, true)
}

open_bookmark_editor :: proc(s: ^State, id: string, is_new: bool) {
	b := find(&s.bookmarks, id)
	if b == nil {
		return
	}
	s.bm_edit.id = strings.clone(id)
	s.bm_edit.is_new = is_new
	s.bm_edit.folder = strings.clone(b.parent)
	s.bm_edit.field = 0
	edit_set(&s.bm_edit.title, b.title, true)
	edit_set(&s.bm_edit.url, b.url)
	s.overlay = .Bookmark_Edit
	set_focus(s, .Dialog)
}

delete_bookmark_undoable :: proc(s: ^State, id: string) {
	b := find(&s.bookmarks, id)
	if b == nil {
		return
	}
	clear(&s.toast.undo)
	append(&s.toast.undo, b^)
	label := b.kind == "folder" ? "Folder deleted" : "Bookmark deleted"
	if bookmark_delete(&s.bookmarks, id) {
		bookmarks_save(&s.bookmarks)
		toast(s, label, "undo")
	}
}

undo_delete :: proc(s: ^State) {
	for r in s.toast.undo {
		if b := find(&s.bookmarks, r.id); b != nil && b.deleted {
			b.deleted = false
			b.life_clock = tick(&s.bookmarks)
			s.bookmarks.dirty = true
		}
	}
	clear(&s.toast.undo)
	bookmarks_save(&s.bookmarks)
	s.toast.until = time.tick_now()
}

// ---------------------------------------------------------------------------
// Engine events
// ---------------------------------------------------------------------------

pump_engine :: proc(s: ^State) {
	af_pump(s)
	if s.engine == nil || !s.engine.ok {
		return
	}
	events := make([dynamic]pb.Event, context.temp_allocator)
	alive := engine_drain(s.engine, &events)
	for &ev in events {
		handle_event(s, &ev)
		pb.event_free(&ev)
	}
	if !alive && s.engine.ok {
		s.engine.ok = false
		s.engine.error = fmt.aprintf("%s stopped unexpectedly", engine_label(s.engine_kind))
		for t in s.tabs {
			if t.page == .Web {
				t.crashed = "The engine process exited."
			}
		}
	}
}

handle_event :: proc(s: ^State, ev: ^pb.Event) {
	t := tab_by_view(s, ev.view)
	#partial switch ev.op {
	case .Title:
		if t != nil {
			delete(t.title)
			t.title = strings.clone(ev.str)
			if t.page == .Web && t.url != "" {
				history_title(&s.history, t.url, t.title)
			}
		}
	case .Url:
		if t != nil && ev.str != "" {
			if t.url != ev.str {
				delete(t.url)
				t.url = strings.clone(ev.str)
				if t.has_icon {
					p.image_destroy(&t.icon)
				}
				t.has_icon = false
			}
			t.error = {}
			t.crashed = ""
			if t.page == .Web {
				history_visit(&s.history, t.url, t.title)
			}
			if s.focus != .Omnibox && t == active_tab(s) {
				edit_set(&s.omni, t.url)
			}
			af_url(s, t)
		}
	case .Load:
		if t != nil {
			was := t.loading
			t.loading = ev.loading
			t.can_back = ev.can_back
			t.can_forward = ev.can_forward
			if was && !t.loading {
				t.progress = 1
				if t.title != "" {
					history_title(&s.history, t.url, t.title)
				}
			}
		}
	case .Progress:
		if t != nil {
			t.progress = ev.progress
		}
	case .Favicon:
		if t != nil && len(ev.png) > 0 {
			if img, ok := p.decode_image(ev.png); ok {
				if t.has_icon {
					p.image_destroy(&t.icon)
				}
				t.icon = img
				t.has_icon = true
			}
		}
	case .Status:
		if t != nil {
			delete(t.status)
			t.status = strings.clone(ev.str)
		}
	case .Cursor:
		if t != nil {
			t.cursor = ev.cursor
		}
	case .Open_Tab:
		at := t != nil ? tab_index(s, t) + 1 : len(s.tabs)
		new_tab(s, ev.str, at, ev.foreground)
	case .Closed:
		if t != nil {
			close_tab(s, tab_index(s, t))
		}
	case .Crashed:
		if t != nil {
			t.crashed = strings.clone(ev.str)
			t.loading = false
		}
	case .Load_Error:
		if t != nil {
			t.error = {
				active = true,
				code   = ev.code,
				text   = strings.clone(ev.str),
				url    = strings.clone(ev.str2),
			}
			t.loading = false
		}
	case .Selection:
		if t != nil {
			delete(t.selection)
			t.selection = strings.clone(ev.str)
		}
	case .Find_Result:
		if t != nil {
			t.find_count = ev.w
			t.find_active = ev.h
		}
	case .Dialog:
		if s.dialog.active {
			// one at a time: refuse a second rather than stack them
			engine_dialog_reply(s.engine, ev.view, ev.id, false, "")
			break
		}
		s.dialog = {
			active  = true,
			view    = ev.view,
			id      = ev.id,
			kind    = ev.dialog,
			message = strings.clone(ev.str),
		}
		edit_set(&s.dialog.field, ev.str2, true)
		if t != nil {
			activate_tab(s, tab_index(s, t))
		}
		set_focus(s, .Dialog)
	case .Menu:
		if s.overlay != .None || t == nil {
			engine_menu_reply(s.engine, ev.view, ev.id, -1)
			break
		}
		s.ctx_menu = {
			view      = ev.view,
			id        = ev.id,
			x         = s.page_rect.x + ev.x,
			y         = s.page_rect.y + ev.y,
			link      = strings.clone(ev.link),
			selection = strings.clone(ev.selection),
			src       = strings.clone(ev.src),
			editable  = ev.editable,
		}
		s.overlay = .Context_Menu
		s.menu_sel = -1
	case .Download:
		on_download(s, ev)
	case .Ready:
		if t != nil {
			t.has_view = true
			if t != active_tab(s) {
				engine_show(s.engine, t.id, false)
			} else if s.focus == .Page {
				engine_focus(s.engine, t.id, true)
			}
		}
	case .Log:
		fmt.eprintln("engine:", ev.str)
	case .Field_Focus, .Fill_Result, .Form_Submit:
		af_event(s, ev)
	}
}

on_download :: proc(s: ^State, ev: ^pb.Event) {
	d: ^Download
	for &x in s.downloads {
		if x.id == ev.id && x.state == "progress" {
			d = &x
		}
	}
	state := "progress"
	switch ev.dl_state {
	case .Done:
		state = "done"
	case .Cancelled:
		state = "cancelled"
	case .Failed:
		state = "failed"
	case .Progress:
	}
	if d == nil {
		if state == "progress" && ev.path == "" && ev.received == 0 {
			// the first notice comes before a path is chosen; wait for the next
		}
		append(&s.downloads, Download{id = ev.id, url = strings.clone(ev.str), started = now_ms(), view = ev.view, state = "progress"})
		d = &s.downloads[len(s.downloads) - 1]
		toast(s, fmt.tprintf("Downloading %s", file_name(ev.path != "" ? ev.path : ev.str)))
	}
	if ev.path != "" && d.path != ev.path {
		d.path = strings.clone(ev.path)
	}
	if ev.mime != "" && d.mime == "" {
		d.mime = strings.clone(ev.mime)
	}
	d.received = ev.received
	d.total = ev.total
	if d.state != state {
		d.state = state
		if state == "done" {
			toast(s, fmt.tprintf("Downloaded %s", file_name(d.path)))
		}
		downloads_save(profile_path(&s.prof, "downloads.json"), s.downloads[:])
	}
}

file_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

downloads_active :: proc(s: ^State) -> (n: int, frac: f32) {
	got, total: i64
	for d in s.downloads {
		if d.state == "progress" {
			n += 1
			got += d.received
			total += max(d.total, 0)
		}
	}
	if total > 0 {
		frac = f32(f64(got) / f64(total))
	}
	return
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

save_session :: proc(s: ^State) {
	sess := Session {
		active = s.active,
	}
	sess.tabs = make([dynamic]Session_Tab, context.temp_allocator)
	for t in s.tabs {
		u := tab_url(t)
		if t.page == .Web && t.error.active && t.error.url != "" {
			u = t.error.url
		}
		append(&sess.tabs, Session_Tab{url = u, title = tab_title(t)})
	}
	session_save(profile_path(&s.prof, "session.json"), sess)
}

// ---------------------------------------------------------------------------
// Remote requests from `browser open`
// ---------------------------------------------------------------------------

pump_remote :: proc(s: ^State) {
	sync.mutex_lock(&s.rlock)
	urls := make([dynamic]string, context.temp_allocator)
	append(&urls, ..s.remote[:])
	clear(&s.remote)
	sync.mutex_unlock(&s.rlock)
	for u in urls {
		new_tab(s, u)
		delete(u)
	}
}

update_snapshot :: proc(s: ^State) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "[")
	for t, i in s.tabs {
		if i > 0 {
			strings.write_string(&sb, ",")
		}
		strings.write_string(&sb, "{\"url\":")
		json_quote(&sb, tab_url(t))
		strings.write_string(&sb, ",\"title\":")
		json_quote(&sb, tab_title(t))
		fmt.sbprintf(&sb, ",\"active\":%v,\"loading\":%v}", i == s.active, t.loading)
	}
	strings.write_string(&sb, "]")
	text := strings.to_string(sb)
	sync.mutex_lock(&s.rlock)
	if text != s.snapshot {
		delete(s.snapshot)
		s.snapshot = strings.clone(text)
	}
	sync.mutex_unlock(&s.rlock)
}

json_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for c in s {
		switch c {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", int(c))
			} else {
				strings.write_rune(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// ---------------------------------------------------------------------------
// Startup and shutdown
// ---------------------------------------------------------------------------

state_init :: proc(s: ^State, prof: Profile) {
	s.prof = prof
	s.scale = 1
	s.active = 0
	s.bookmarks = bookmarks_open(profile_path(&s.prof, "bookmarks.json", context.allocator), s.prof.settings.device)
	s.history = history_open(profile_path(&s.prof, "history.jsonl", context.allocator), s.prof.settings.device)
	s.downloads = downloads_load(profile_path(&s.prof, "downloads.json"))
	s.bm_folder = ROOT_TOOLBAR
	s.dark = profile_theme(&s.prof) == .Dark
	s.engine_kind = profile_engine(&s.prof)
}

state_shutdown :: proc(s: ^State) {
	if s.bookmarks.dirty {
		bookmarks_save(&s.bookmarks)
	}
	if s.prof.settings.restore_session {
		save_session(s)
	}
	af_shutdown(s)
	engine_stop(s.engine)
}

@(private = "file")
_unused :: os.Error
