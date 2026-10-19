// Notes — Markdown notes you own, per identity, synced across devices.
//
// Every identity on the device has a folder of real Markdown files
// (ident.odin); the window shows them side by side — identities and notebooks,
// the list, the note — and is always in exactly one identity when it acts:
// a new note, a share or a carry happens as the identity it names, and in the
// All identities view the window asks rather than guesses (product.md P3).
//
// The editor formats Markdown as you type (wrap.odin), the note list and
// search run over the files on this device, and sync runs as the same
// `notes sync` command the shell can run, in a child process, while the open
// note — if its identity is synced — has a live session with the sync server
// of its own (live.odin): other people's edits and carets arrive as they type.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf

HEADER_H :: 52
STATUS_H :: 26
SIDEBAR_W :: 232
LIST_W :: 304
AUTOSAVE_IDLE :: 1.2 // seconds of quiet before the note is written
SYNC_EVERY :: 30.0 // seconds between background syncs
ACCENT :: 0x2563eb

run_cmd :: proc(argv: []string) -> (string, bool) {
	return kit.run(argv, context.temp_allocator)
}

Pane :: enum {
	Sidebar,
	List,
	Editor,
}

Mode :: enum {
	Normal,
	Search,
	Rename,
	Confirm_Delete,
	Help,
	Styles, // the writing-style picker
	Share,
	Carry,
	Choose_Identity, // a new note in All identities: as whom?
	Move,
}

Section :: enum u8 {
	All, // every note of the identity (or of every identity)
	Inbox, // the top level of the identity's folder
	Pinned,
	Notebook,
	Tag,
	Shared, // notes other identities shared with this one
	Trash,
}

// View is what the list shows: one identity (or all of them, -1) and a
// section of it.
View :: struct {
	ident:   int,
	section: Section,
	name:    string, // the notebook or tag, owned
}

// Side_Item is one row of the sidebar, flattened for keyboard navigation.
Side_Item :: struct {
	view:  View,
	label: string,
	count: int,
	depth: int,
	head:  bool, // an identity row
}

Layout :: enum {
	Three, // sidebar, list, editor
	Two, // list and editor; the sidebar is a drawer
	One, // one pane at a time
}

Person :: struct {
	handle, name, color, access: string,
}

Notes :: struct {
	ids:          [dynamic]Ident,
	all:          [dynamic]Note,
	vis:          [dynamic]int,
	sel:          int,
	view:         View,
	side:         [dynamic]Side_Item,
	side_sel:     int,
	pane:         Pane,
	mode:         Mode,
	layout:       Layout,
	drawer:       bool, // the sidebar drawn over the list in narrower layouts
	hide_sidebar: bool,
	query:        [dynamic]u8,
	other_hits:   int, // matches in identities outside the view, for the honesty line
	rename:       [dynamic]u8,
	move_to:      [dynamic]u8,
	dir:          string, // the first identity's folder (import, legacy callers)

	// the open note
	buf:          Buffer,
	open_path:    string,
	open_id:      string,
	open_ident:   int,
	open_access:  string, // owner, read or edit
	open_owner:   string, // for a shared note
	cur:          Pos,
	anchor:       Pos,
	has_sel:      bool,
	goal_x:       f32,
	rev:          int, // bumped on every edit, so the wrapper knows to redo
	wrap:         Wrapper,
	top:          int, // first visible visual row
	rows:         int,
	view_h:       f32, // the writing area's height
	body_w:       f32,
	preview:      bool,
	backlinks:    bool, // the backlinks panel

	sel_confirm:  bool, // the delete dialog's highlighted button
	dirty_since:  f64,
	pending:      bool,
	swallow:      bool,
	toast:        string,
	toast_at:     f64,
	now:          time.Time,
	tz:           i64,
	space_w:      f32,
	want_quit:    bool,
	dark:         bool,

	// share and carry
	share_handle: [dynamic]u8,
	share_edit:   bool,
	people:       [dynamic]Person,
	share_msg:    string,
	share_sel:    int,
	carry_to:     int,
	choose_sel:   int,

	// sync
	sync:         Sync_Proc,
	live:         Live,

	// Import and export, through the shared file dialog. See pick.odin.
	pick:         kit.Pick,
	pick_use:     Pick_Use,

	// The writing coach. See prose_state.odin and prose_ui.odin; the engine
	// itself is apps/prose, which `prose lint` is the other front end of.
	pr:           Prose,
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

main :: proc() {
	// The command line is the other front end over the same store: see
	// cli.odin for the declaration and apps/kit/cli.odin for everything that
	// is done with it. With no command there is a window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	os.exit(run_window())
}

run_window :: proc() -> int {
	dark := os.get_env("PALM_THEME", context.temp_allocator) == "dark"
	app, err := kit.start(
		{
			title = "Notes",
			width = 1320,
			height = 820,
			min_width = 420,
			min_height = 420,
			root_class = "w-full h-full bg-background text-foreground",
		},
		dark,
	)
	if err != "" {
		fmt.eprintfln("notes: %s", err)
		return 1
	}
	defer p.destroy(app)
	register_colors(dark)

	nt := Notes{}
	nt.live.app = app
	notes_init(&nt, dark)
	defer prose_destroy(&nt)
	defer kit.pick_destroy(&nt.pick)
	sync_start(&nt) // whatever happened while the window was closed

	for ui in p.frames(app) {
		nt.now = time.now()
		measure(ui, &nt)
		sync_tick(ui, &nt)
		live_tick(ui, &nt)
		keys(ui, &nt, app)
		autosave(ui, &nt)
		prose_tick(ui, &nt)
		frame(ui, &nt)
		if nt.want_quit {
			break
		}
	}
	// Never lose content on exit: whatever is pending is written before the
	// window goes away, whichever way the loop ended.
	flush(&nt)
	live_close(&nt)
	p.quit_app(app)
	return 0
}

register_colors :: proc(dark: bool) {
	p.register_color("accent-blue", p.hex(dark ? 0x60a5fa : ACCENT))
	prose_register_colors()
}

notes_init :: proc(nt: ^Notes, dark: bool) {
	nt.dark = dark
	nt.tz = local_offset()
	nt.now = time.now()
	nt.backlinks = true
	nt.pane = .List
	nt.view = View{ident = -1, section = .All}
	buf_init_empty(&nt.buf)
	prose_init(nt)
	reload(nt)
	if len(nt.all) == 0 && len(nt.ids) > 0 {
		seed(nt)
		reload(nt)
	}
	// Start in the identity the shell says the person is in, if it is here.
	if i := capture_ident(&Book{ids = nt.ids}); i >= 0 && len(nt.ids) > 1 {
		set_view(nt, View{ident = i, section = .All})
	} else if len(nt.ids) == 1 {
		set_view(nt, View{ident = 0, section = .All})
	}
	open_sel(nt)
	prose_force(nt)
}

// seed writes a first note so the app is never a blank wall on first run.
seed :: proc(nt: ^Notes) {
	body := `# Welcome to Notes

Every note here is a real Markdown file, in a folder of its own identity:
**~/Notes/<identity>/**. A folder is a notebook. Open it in a file browser
and it reads like a list of titles.

## What works

- **Bold**, *emphasis*, ` + "`inline code`" + `, [[links to notes]] and #tags
- Lists that keep going when you press Return
- [ ] tasks you tick with a click, or Ctrl+Enter
- [x] like this one
- Quotes, rules and code blocks

> Search runs over every note on this device, in every identity, and says
> which identity each result belongs to.

## Keys

F1 lists every key. Ctrl+N is a new note, Ctrl+F searches, Ctrl+Alt+K shares,
Ctrl+Shift+C carries a copy into another of your identities. Everything saves
itself, and syncs when the identity is signed in.
`
	path, ok := store_create_in(nt.ids[0].root, "", body)
	if ok {
		delete(path)
	}
}

note :: proc(nt: ^Notes, msg: string) {
	delete(nt.toast)
	nt.toast = strings.clone(msg)
	nt.toast_at = 0
}

measure :: proc(ui: ^p.Ctx, nt: ^Notes) {
	win := p.size(ui)
	switch {
	case win.x >= 1100:
		nt.layout = .Three
	case win.x >= 760:
		nt.layout = .Two
	case:
		nt.layout = .One
	}
	if nt.layout == .Three {
		nt.drawer = false
	}
	nt.space_w = p.text_width(ui.fonts, " ", BODY_SIZE, .Sans, .Regular)
	left: f32 = 0
	switch nt.layout {
	case .Three:
		left = (nt.hide_sidebar ? 0 : SIDEBAR_W) + LIST_W
	case .Two:
		left = LIST_W
	case .One:
		left = 0
	}
	panel := nt.pr.show_report ? f32(PROSE_PANEL_W) : 0
	gutter: f32 = win.x - left - panel > 900 ? 120 : 64
	nt.body_w = clamp(win.x - left - panel - gutter, 200, 760)
	// The explanation strip and the backlinks panel eat height when they are
	// up, so the caret arithmetic has to know about them.
	strip := f32(nt.pr.on && !nt.preview ? (nt.pr.mark >= 0 ? 92 : 34) : 0)
	back := nt.backlinks && nt.open_path != "" ? f32(BACKLINKS_H) : 0
	nt.view_h = max(60, win.y - 3 - HEADER_H - STATUS_H - 74 - 40 - strip - back)
	nt.rows = rows_fitting(&nt.wrap, nt.top, nt.view_h)
}

// ---------------------------------------------------------------------------
// The notes and the views over them
// ---------------------------------------------------------------------------

reload :: proc(nt: ^Notes) {
	for n in nt.all {
		note_free(n)
	}
	clear(&nt.all)
	for &x in nt.ids {
		ident_free(&x)
	}
	clear(&nt.ids)
	fresh := idents_load()
	append(&nt.ids, ..fresh[:])
	delete(fresh)
	if len(nt.ids) > 0 {
		delete(nt.dir)
		nt.dir = strings.clone(nt.ids[0].root)
	}
	for id, i in nt.ids {
		ns := store_load(id.root)
		for &n in ns {
			n.ident = i
			append(&nt.all, n)
		}
		delete(ns)
	}
	// One list, newest first across identities, pinned first within each.
	slice.sort_by(nt.all[:], proc(a, b: Note) -> bool {
		if a.meta.pinned != b.meta.pinned {
			return a.meta.pinned
		}
		return a.mtime._nsec > b.mtime._nsec
	})
	if nt.view.ident >= len(nt.ids) {
		set_view(nt, View{ident = -1, section = .All})
	}
	build_side(nt)
	refilter(nt)
}

in_view :: proc(nt: ^Notes, n: Note) -> bool {
	v := nt.view
	if v.ident >= 0 && n.ident != v.ident {
		return false
	}
	switch v.section {
	case .All:
		return !n.trashed
	case .Inbox:
		return !n.trashed && !n.shared && n.notebook == ""
	case .Pinned:
		return !n.trashed && n.meta.pinned
	case .Notebook:
		return !n.trashed && !n.shared && (n.notebook == v.name || strings.has_prefix(n.notebook, tfmt("%s/", v.name)))
	case .Tag:
		if n.trashed {return false}
		for t in n.tags {
			if t == v.name || strings.has_prefix(t, tfmt("%s/", v.name)) {return true}
		}
		return false
	case .Shared:
		return n.shared && !n.trashed
	case .Trash:
		return n.trashed
	}
	return false
}

refilter :: proc(nt: ^Notes) {
	keep := ""
	if n, ok := selected(nt); ok {
		keep = strings.clone(n.path, context.temp_allocator)
	}
	clear(&nt.vis)
	nt.other_hits = 0
	q := string(nt.query[:])
	if q != "" {
		// Search is the same engine as `notes search`: every identity in the
		// view, labelled, best first. Notes in identities outside the view are
		// only counted, for one honest line under the results.
		handles := make([]string, len(nt.ids), context.temp_allocator)
		for id, i in nt.ids {
			handles[i] = id.handle
		}
		pq := parse_query(q)
		for h in search_notes(nt.all[:], handles, pq) {
			n := nt.all[h.note]
			if nt.view.ident >= 0 && n.ident != nt.view.ident {
				nt.other_hits += 1
				continue
			}
			append(&nt.vis, h.note)
		}
	} else {
		for n, i in nt.all {
			if in_view(nt, n) {
				append(&nt.vis, i)
			}
		}
	}
	nt.sel = clamp(nt.sel, 0, max(0, len(nt.vis) - 1))
	if keep != "" {
		for v, i in nt.vis {
			if nt.all[v].path == keep {
				nt.sel = i
			}
		}
	}
}

set_view :: proc(nt: ^Notes, v: View) {
	delete(nt.view.name)
	nt.view = v
	nt.view.name = strings.clone(v.name)
	nt.sel = 0
	refilter(nt)
	for it, i in nt.side {
		if it.view.ident == v.ident && it.view.section == v.section && it.view.name == v.name {
			nt.side_sel = i
		}
	}
}

// build_side flattens the sidebar: All identities, then each identity with —
// for the one in view — its sections, notebooks and tags.
build_side :: proc(nt: ^Notes) {
	for it in nt.side {
		delete(it.label)
		delete(it.view.name)
	}
	clear(&nt.side)
	add :: proc(nt: ^Notes, v: View, label: string, count, depth: int, head := false) {
		vv := v
		vv.name = strings.clone(v.name)
		append(&nt.side, Side_Item{view = vv, label = strings.clone(label), count = count, depth = depth, head = head})
	}
	count :: proc(nt: ^Notes, v: View) -> int {
		saved := nt.view
		nt.view = v
		n := 0
		for x in nt.all {
			if in_view(nt, x) {n += 1}
		}
		nt.view = saved
		return n
	}
	if len(nt.ids) > 1 {
		add(nt, View{ident = -1, section = .All}, "All identities", count(nt, View{ident = -1, section = .All}), 0, true)
	}
	for id, i in nt.ids {
		add(nt, View{ident = i, section = .All}, id.name, count(nt, View{ident = i, section = .All}), 0, true)
		if nt.view.ident != i && len(nt.ids) > 1 {
			continue
		}
		add(nt, View{ident = i, section = .Inbox}, "Inbox", count(nt, View{ident = i, section = .Inbox}), 1)
		if c := count(nt, View{ident = i, section = .Pinned}); c > 0 {
			add(nt, View{ident = i, section = .Pinned}, "Pinned", c, 1)
		}
		for b in notebooks_of(nt.all[:], i) {
			depth := 1 + strings.count(b.name, "/")
			label := b.name
			if k := strings.last_index_byte(b.name, '/'); k >= 0 {
				label = b.name[k + 1:]
			}
			add(nt, View{ident = i, section = .Notebook, name = b.name}, label, count(nt, View{ident = i, section = .Notebook, name = b.name}), depth)
		}
		if c := count(nt, View{ident = i, section = .Shared}); c > 0 {
			add(nt, View{ident = i, section = .Shared}, "Shared with me", c, 1)
		}
		add(nt, View{ident = i, section = .Trash}, "Trash", count(nt, View{ident = i, section = .Trash}), 1)
		// Tags, most used first, at most eight.
		Tc :: struct {
			t: string,
			n: int,
		}
		tags := make([dynamic]Tc, context.temp_allocator)
		for x in nt.all {
			if x.ident != i || x.trashed {continue}
			for t in x.tags {
				found := false
				for &e in tags {
					if e.t == t {
						e.n += 1
						found = true
					}
				}
				if !found {append(&tags, Tc{t, 1})}
			}
		}
		slice.sort_by(tags[:], proc(a, b: Tc) -> bool {return a.n > b.n || (a.n == b.n && a.t < b.t)})
		for t, k in tags {
			if k >= 8 {break}
			add(nt, View{ident = i, section = .Tag, name = t.t}, tfmt("#%s", t.t), t.n, 1)
		}
	}
	nt.side_sel = clamp(nt.side_sel, 0, max(0, len(nt.side) - 1))
}

selected :: proc(nt: ^Notes) -> (Note, bool) {
	if nt.sel < 0 || nt.sel >= len(nt.vis) {
		return Note{}, false
	}
	return nt.all[nt.vis[nt.sel]], true
}

open_note :: proc(nt: ^Notes) -> (^Note, bool) {
	for &n in nt.all {
		if n.path == nt.open_path {
			return &n, true
		}
	}
	return nil, false
}

// view_ident is the identity the window acts as: the open note's, else the
// one in view, else none (-1) — and then the window asks.
view_ident :: proc(nt: ^Notes) -> int {
	if nt.open_path != "" && nt.open_ident >= 0 && nt.open_ident < len(nt.ids) {
		return nt.open_ident
	}
	return nt.view.ident
}

// open_sel loads the selected note into the buffer, saving whatever was open.
open_sel :: proc(nt: ^Notes) {
	n, ok := selected(nt)
	if !ok {
		return
	}
	if n.path == nt.open_path {
		return
	}
	open_path(nt, n)
}

open_path :: proc(nt: ^Notes, n: Note) {
	flush(nt)
	live_close(nt)
	delete(nt.open_path)
	delete(nt.open_id)
	delete(nt.open_access)
	delete(nt.open_owner)
	nt.open_path = strings.clone(n.path)
	nt.open_id = strings.clone(n.meta.id)
	nt.open_ident = n.ident
	nt.open_access = strings.clone(n.shared ? (n.meta.access != "" ? n.meta.access : "read") : "owner")
	nt.open_owner = strings.clone(n.meta.shared_from)
	buf_load_text(&nt.buf, n.path, n.body)
	nt.cur = {0, 0}
	nt.anchor = {0, 0}
	nt.has_sel = false
	nt.top = 0
	nt.rev += 1
	nt.pending = false
	delete(nt.wrap.own)
	nt.wrap.own = strings.clone(nt.ids[n.ident].handle)
	prose_conf_apply_note(nt)
	prose_invalidate(nil, nt)
	live_open(nt)
}

read_only :: proc(nt: ^Notes) -> bool {
	return nt.open_access == "read"
}

buffer_text :: proc(nt: ^Notes, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< buf_lines(&nt.buf) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(&nt.buf, i))
	}
	return strings.to_string(sb)
}

// flush writes the open note if it has unsaved edits.
flush :: proc(nt: ^Notes) {
	if !nt.pending || nt.open_path == "" || read_only(nt) {
		return
	}
	body := buffer_text(nt)
	root := nt.open_ident >= 0 && nt.open_ident < len(nt.ids) ? nt.ids[nt.open_ident].root : nt.dir

	// The file is renamed when the title changes, so the list entry has to be
	// found by the path it had *before* the write, not after.
	was := strings.clone(nt.open_path, context.temp_allocator)
	new_path, ok := store_write(root, nt.open_path, body)
	if !ok {
		return
	}
	if new_path != nt.open_path {
		delete(nt.open_path)
		nt.open_path = new_path
	} else {
		delete(new_path)
	}
	nt.pending = false
	nt.buf.save_mark = len(nt.buf.undo)

	// Refresh the list entry in place so the title and timestamp follow the
	// text without re-reading every folder on every save.
	for &n in nt.all {
		if n.path != was {
			continue
		}
		data, _ := os.read_entire_file_from_path(nt.open_path, context.temp_allocator)
		fresh := note_from_text(nt.open_path, strings.trim_prefix(strings.trim_prefix(nt.open_path, root), "/"), string(data), time.now())
		fresh.ident = n.ident
		note_free(n)
		n = fresh
		break
	}
	refilter(nt)
}

touch :: proc(ui: ^p.Ctx, nt: ^Notes) {
	nt.pending = true
	nt.dirty_since = f64(p.elapsed(ui))
	nt.rev += 1
	live_edit(nt)
	// The coach is told the line, not the document: that is what lets it
	// re-read one paragraph instead of the note. See prose_state.odin.
	prose_touch(ui, nt, nt.cur.line)
}

autosave :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pending {
		return
	}
	// Keep the clock running while a save is pending, otherwise an idle
	// window would never reach the deadline.
	p.redraw(ui)
	if f64(p.elapsed(ui)) - nt.dirty_since >= AUTOSAVE_IDLE {
		flush(nt)
	}
}

// create makes a new note in the identity the window is in. In All
// identities there is no such identity, so it asks (product.md P3).
create :: proc(nt: ^Notes) {
	ti := view_ident(nt)
	if nt.view.ident < 0 && len(nt.ids) > 1 {
		nt.mode = .Choose_Identity
		nt.choose_sel = -1
		nt.swallow = true
		return
	}
	if ti < 0 {
		ti = 0
	}
	create_in(nt, ti)
}

create_in :: proc(nt: ^Notes, ti: int) {
	flush(nt)
	notebook := nt.view.section == .Notebook && nt.view.ident == ti ? nt.view.name : ""
	path, ok := store_create_in(nt.ids[ti].root, notebook, "New note\n\n")
	if !ok {
		note(nt, "Could not create a note")
		return
	}
	if nt.view.ident >= 0 && nt.view.ident != ti {
		set_view(nt, View{ident = ti, section = .All})
	} else if nt.view.section == .Trash || nt.view.section == .Shared || nt.view.section == .Tag || nt.view.section == .Pinned {
		set_view(nt, View{ident = nt.view.ident, section = .All})
	}
	reload(nt)
	clear(&nt.query)
	refilter(nt)
	for idx, i in nt.vis {
		if nt.all[idx].path == path {
			nt.sel = i
			break
		}
	}
	delete(path)
	open_sel(nt)
	nt.pane = .Editor
	// A new note starts with its title selected, ready to be typed over.
	nt.cur = {0, len(buf_line(&nt.buf, 0))}
	nt.anchor = {0, 0}
	nt.has_sel = true
	note(nt, tfmt("New note in %s", nt.ids[ti].name))
}

// trash_selected moves the selected note to its identity's trash, or out of
// it again when the trash is what is in view.
trash_selected :: proc(nt: ^Notes) {
	n, ok := selected(nt)
	if !ok {
		return
	}
	if n.shared {
		note(nt, tfmt("Shared by %s: only its owner can move it", n.meta.shared_from))
		return
	}
	if n.path == nt.open_path {
		flush(nt)
		live_close(nt)
		delete(nt.open_path)
		nt.open_path = ""
	}
	root := nt.ids[n.ident].root
	title := strings.clone(n.title, context.temp_allocator)
	was_trashed := n.trashed
	np: string
	moved: bool
	if n.trashed {
		np, moved = store_restore(root, n)
	} else {
		np, moved = store_trash(root, n)
	}
	if !moved {
		note(nt, "Could not move that note")
		return
	}
	delete(np)
	reload(nt)
	open_sel(nt)
	note(nt, was_trashed ? tfmt("Restored \"%s\"", title) : tfmt("Moved \"%s\" to the trash", title))
	sync_soon(nt)
}

destroy_selected :: proc(nt: ^Notes) {
	n, ok := selected(nt)
	if !ok {
		return
	}
	title := strings.clone(n.title, context.temp_allocator)
	if n.path == nt.open_path {
		nt.pending = false
		live_close(nt)
		delete(nt.open_path)
		nt.open_path = ""
	}
	// Deleting for good is the same command the CLI runs, so the cloud copy
	// goes too (or is queued for the next sync).
	out, done := run_cmd({self_exe(), "delete", n.path, "--yes", "--json"})
	_ = out
	if !done && os.exists(n.path) {
		store_delete(n.path)
	}
	reload(nt)
	nt.sel = clamp(nt.sel, 0, max(0, len(nt.vis) - 1))
	if len(nt.vis) > 0 {
		open_sel(nt)
	} else {
		buf_init_empty(&nt.buf)
		nt.rev += 1
	}
	note(nt, tfmt("Deleted \"%s\" for good", title))
}

self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// apply_rename rewrites the note's first line, which is its title.
apply_rename :: proc(ui: ^p.Ctx, nt: ^Notes) {
	want := strings.trim_space(string(nt.rename[:]))
	if want == "" || read_only(nt) {
		return
	}
	first := buf_line(&nt.buf, 0)
	keep := ""
	if strings.has_prefix(strings.trim_left(first, " \t"), "#") {
		t := strings.trim_left(first, " \t")
		h := 0
		for h < len(t) && t[h] == '#' {
			h += 1
		}
		keep = tfmt("%s ", t[:h])
	}
	nt.cur = buf_apply(&nt.buf, {0, 0}, {0, len(first)}, tfmt("%s%s", keep, want), nt.cur, .No)
	nt.has_sel = false
	nt.anchor = nt.cur
	touch(ui, nt)
	flush(nt)
	note(nt, tfmt("Renamed to \"%s\"", want))
}

// apply_move files the open note in another notebook of its identity.
apply_move :: proc(nt: ^Notes) {
	n, ok := open_note(nt)
	if !ok || n.shared {
		return
	}
	want := strings.trim(strings.trim_space(string(nt.move_to[:])), "/")
	if strings.contains(want, "..") || strings.has_prefix(want, ".") || want == SHARED_DIR || want == ATTACH_DIR {
		note(nt, tfmt("\"%s\" cannot be a notebook", want))
		return
	}
	flush(nt)
	root := nt.ids[n.ident].root
	path, moved := store_move(root, n.path, want)
	if !moved {
		note(nt, "Could not move the note")
		return
	}
	delete(nt.open_path)
	nt.open_path = path
	reload(nt)
	note(nt, want == "" ? "Moved to the inbox" : tfmt("Filed in %s", want))
	sync_soon(nt)
}

// toggle_pin pins or unpins the open note.
toggle_pin :: proc(nt: ^Notes) {
	n, ok := open_note(nt)
	if !ok || n.shared {
		return
	}
	flush(nt)
	m := meta_clone(n.meta, context.temp_allocator)
	m.pinned = !m.pinned
	if store_write_meta(n.path, m) {
		reload(nt)
		note(nt, m.pinned ? "Pinned" : "Unpinned")
		sync_soon(nt)
	}
}
