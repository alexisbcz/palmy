package main

// What the window shows, and every action it can take. The CLI (cli.odin)
// calls the same drivecore procedures, so the two front ends cannot drift:
// there is no second implementation of sharing, trashing or uploading.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import dc "drive:core"
import kit "kit:."
import p "palmy:."

Section :: enum {
	Drive,
	Shared,
	Recent,
	Starred,
	Trash,
	Search,
}

SECTION_LABEL := [Section]string {
	.Drive   = "My Drive",
	.Shared  = "Shared with me",
	.Recent  = "Recent",
	.Starred = "Starred",
	.Trash   = "Trash",
	.Search  = "Search",
}

View :: enum {
	List,
	Grid,
}

Dialog :: enum {
	None,
	Share,
	Identity,
	New_Folder,
	Empty_Trash,
}

Row :: struct {
	item:      dc.Item,
	owner:     string, // the other identity's handle, for Shared with me
	owner_id:  string,
	role:      string, // viewer / editor, for Shared with me
	shared:    bool, // this identity has shared it, or has a live link to it
	where_:    string, // the folder it is in, for Recent / Starred / Search
	icon:      p.Icon,
	tint:      string,
	kind_text: string,
	size_text: string,
	date_text: string,
	local:     string, // the synced copy on this device, when there is one
}

Crumb :: struct {
	id, name: string,
}

State :: struct {
	cfg:          dc.Config,
	ident:        int,
	c:            dc.Client,
	section:      Section,
	view:         View,
	crumbs:       [dynamic]Crumb, // the folder path in My Drive (or in a shared folder)
	owner:        string, // identity id of the drive being browsed, when it is not ours
	owner_handle: string,
	rows:         [dynamic]Row,
	sel:          int,
	top:          int,
	vis_rows:     int,
	cols:         int,
	pane_w:       f32,
	shared_set:   map[string]bool,
	usage:        dc.Usage,
	usage_ok:     bool,
	offline:      string, // non-empty when the server could not be reached
	inspector:    bool,
	show_insp:    bool, // the inspector, when the window is wide enough for it

	// search
	query:        [dynamic]u8,
	typing:       bool,

	// dialogs
	dialog:       Dialog,
	field:        [dynamic]u8, // the handle in Share, the name in New Folder
	share_role:   string,
	share_rows:   []dc.Share_Row,
	share_sel:    int, // -1: the field; 0..: a person; len: the link row
	links:        []dc.Link,
	minted:       string, // a token shown once, right after minting
	ident_sel:    int,

	// the selection's details, fetched when it changes
	detail_id:    string,
	versions:     []dc.Version,

	pick:         kit.Pick,
	toast:        string,
	toast_at:     f64,
	now:          time.Time,
	thumbs:       map[string]p.Image,
	thumb_tried:  map[string]bool,
	scroll_acc:   f32,
	locked:       bool, // started inside one identity's scope ($PALM_IDENTITY)
}

ident :: proc(st: ^State) -> ^dc.Identity {
	return &st.cfg.identities[st.ident]
}

// The colour each identity is drawn in. It is the one accent in the window,
// so the identity you are in is the first thing you see, everywhere.
identity_hex :: proc(color: string) -> u32 {
	switch color {
	case "emerald":
		return 0x059669
	case "amber":
		return 0xd97706
	case "rose":
		return 0xe11d48
	case "sky":
		return 0x0284c7
	case "violet":
		return 0x7c3aed
	case "slate":
		return 0x475569
	}
	return 0x4f46e5 // indigo
}

identity_soft :: proc(color: string) -> u32 {
	switch color {
	case "emerald":
		return 0xecfdf5
	case "amber":
		return 0xfffbeb
	case "rose":
		return 0xfff1f2
	case "sky":
		return 0xf0f9ff
	case "violet":
		return 0xf5f3ff
	case "slate":
		return 0xf8fafc
	}
	return 0xeef2ff
}

kind_label :: proc(kind: string) -> string {
	switch kind {
	case "work":
		return "Work"
	case "public":
		return "Public"
	case "project":
		return "Project"
	}
	return "Personal"
}

initials :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	prev_space := true
	for r in name {
		if r == ' ' || r == '-' || r == '—' {
			prev_space = true
			continue
		}
		if prev_space && n < 2 && r != '—' {
			strings.write_rune(&b, r >= 'a' && r <= 'z' ? r - 32 : r)
			n += 1
		}
		prev_space = false
	}
	return strings.to_string(b)
}

select_identity :: proc(st: ^State, i: int) {
	if i < 0 || i >= len(st.cfg.identities) {
		return
	}
	if st.locked && st.c.identity != "" && i != st.ident {
		note(st, fmt.tprintf("This window is scoped to %s; other identities are out of reach", ident(st).handle))
		return
	}
	st.ident = i
	st.c = dc.client_for(&st.cfg, ident(st))
	p.register_color("selection", p.hex(identity_hex(ident(st).color)))
	p.register_color("identity-soft", p.hex(identity_soft(ident(st).color)))
	clear(&st.crumbs)
	st.owner = ""
	st.owner_handle = ""
	st.section = .Drive
	clear(&st.query)
	reload(st)
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

current_folder :: proc(st: ^State) -> string {
	return len(st.crumbs) > 0 ? st.crumbs[len(st.crumbs) - 1].id : ""
}

reload :: proc(st: ^State) {
	st.now = time.now()
	prev := ""
	if r, ok := selected(st); ok {
		prev = strings.clone(r.item.id, context.temp_allocator)
	}
	clear(&st.rows)
	st.offline = ""
	e: dc.Error
	switch st.section {
	case .Drive:
		items: []dc.Item
		items, e = dc.list_children(&st.c, current_folder(st), false, st.owner)
		for it in items {
			add_row(st, it)
		}
	case .Shared:
		if len(st.crumbs) > 0 {
			items: []dc.Item
			items, e = dc.list_children(&st.c, current_folder(st), false, st.owner)
			for it in items {
				r := add_row(st, it)
				r.owner = st.owner_handle
			}
		} else {
			incoming: []dc.Incoming
			incoming, e = dc.shared_with_me(&st.c)
			for s in incoming {
				it := dc.Item {
					id          = s.item_id,
					identity_id = s.owner_identity,
					name        = s.name,
					kind        = s.kind,
					size        = s.size,
					mime        = s.mime,
					modified_at = s.modified_at,
				}
				r := add_row(st, it)
				r.owner = s.owner_handle
				r.owner_id = s.owner_identity
				r.role = s.role
				r.date_text = rel_date(st, s.shared_at)
			}
		}
	case .Recent:
		items: []dc.Item
		items, e = dc.list_recent(&st.c)
		for it in items {
			add_row(st, it)
		}
	case .Starred:
		items: []dc.Item
		items, e = dc.list_starred(&st.c)
		for it in items {
			add_row(st, it)
		}
	case .Trash:
		items: []dc.Item
		items, e = dc.list_trash(&st.c)
		for it in items {
			r := add_row(st, it)
			r.date_text = rel_date(st, it.trashed_at)
		}
	case .Search:
		q := strings.trim_space(string(st.query[:]))
		if q != "" {
			items: []dc.Item
			items, e = dc.search(&st.c, q)
			for it in items {
				add_row(st, it)
			}
		}
	}
	if dc.failed(e) {
		st.offline = dc.offline(e) ? "The drive cannot be reached. Your synced folder still works." : strings.clone(e.message)
	}
	if st.section != .Drive || len(st.crumbs) == 0 {
		// Folders first, then by name, in the views that are not one folder.
		if st.section == .Recent || st.section == .Trash || st.section == .Shared {
			// keep the server's order: most recent first
		} else {
			slice.stable_sort_by(st.rows[:], proc(a, b: Row) -> bool {
				if a.item.kind != b.item.kind {
					return a.item.kind == "folder"
				}
				return strings.to_lower(a.item.name, context.temp_allocator) < strings.to_lower(b.item.name, context.temp_allocator)
			})
		}
	}
	if ids, se := dc.shared_ids(&st.c); !dc.failed(se) {
		delete(st.shared_set)
		st.shared_set = ids
		for &r in st.rows {
			r.shared = st.shared_set[r.item.id]
		}
	}
	u, ue := dc.usage(&st.c)
	st.usage, st.usage_ok = u, !dc.failed(ue)

	st.sel = 0
	for r, i in st.rows {
		if r.item.id == prev {
			st.sel = i
		}
	}
	st.top = 0
	st.detail_id = ""
	ensure_visible(st)
}

add_row :: proc(st: ^State, it: dc.Item) -> ^Row {
	r := Row {
		item = it,
	}
	r.icon, r.tint, r.kind_text = icon_for(it.name, it.kind)
	r.size_text = it.kind == "folder" ? "—" : strings.clone(dc.human_size(it.size))
	r.date_text = rel_date(st, it.modified_at)
	// The synced copy, when this device mirrors the drive and the path is
	// known (inside a folder we are browsing).
	if it.identity_id == ident(st).id && st.section == .Drive {
		rel := strings.builder_make(context.temp_allocator)
		for c in st.crumbs {
			fmt.sbprintf(&rel, "%s/", c.name)
		}
		strings.write_string(&rel, it.name)
		full := fmt.aprintf("%s/%s", ident(st).root, strings.to_string(rel))
		if os.exists(full) {
			r.local = full
		}
	}
	append(&st.rows, r)
	return &st.rows[len(st.rows) - 1]
}

selected :: proc(st: ^State) -> (^Row, bool) {
	if st.sel >= 0 && st.sel < len(st.rows) {
		return &st.rows[st.sel], true
	}
	return nil, false
}

// load_detail fetches what the inspector shows for the selection, once per
// selection change rather than every frame.
load_detail :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok || r.item.id == st.detail_id {
		return
	}
	st.detail_id = strings.clone(r.item.id)
	st.versions = nil
	st.share_rows = nil
	st.links = nil
	if r.item.kind == "file" {
		st.versions, _ = dc.versions(&st.c, r.item.id)
	}
	if r.item.identity_id == st.c.identity {
		st.share_rows, _ = dc.shares_of(&st.c, r.item.id)
		all, _ := dc.links_of(&st.c, r.item.id)
		live := make([dynamic]dc.Link)
		for l in all {
			if l.revoked_at == "" && !expired(st, l.expires_at) {
				append(&live, l)
			}
		}
		st.links = live[:]
	}
}

expired :: proc(st: ^State, iso: string) -> bool {
	if iso == "" {
		return false
	}
	t, n := time.rfc3339_to_time_utc(iso)
	return n > 0 && time.diff(st.now, t) < 0
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

go_section :: proc(st: ^State, s: Section) {
	if s != .Search {
		clear(&st.query)
	}
	st.section = s
	clear(&st.crumbs)
	st.owner = ""
	st.owner_handle = ""
	st.typing = false
	reload(st)
}

open_row :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok {
		return
	}
	if st.section == .Trash {
		note(st, "Restore it first: R")
		return
	}
	if r.item.kind == "folder" {
		if st.section == .Shared && len(st.crumbs) == 0 {
			st.owner = strings.clone(r.owner_id)
			st.owner_handle = strings.clone(r.owner)
		} else if st.section != .Drive && st.section != .Shared {
			// From Recent / Starred / Search, a folder opens in My Drive.
			st.section = .Drive
			clear(&st.crumbs)
			path, _ := dc.item_path(&st.c, r.item.id)
			id := strings.clone(r.item.id)
			// Rebuild the crumbs by walking the path from the root.
			parent := ""
			for name in strings.split(path, "/", context.temp_allocator) {
				kids, _ := dc.list_children(&st.c, parent)
				for k in kids {
					if k.name == name && k.kind == "folder" {
						append(&st.crumbs, Crumb{strings.clone(k.id), strings.clone(k.name)})
						parent = k.id
						break
					}
				}
			}
			_ = id
			reload(st)
			return
		}
		append(&st.crumbs, Crumb{strings.clone(r.item.id), strings.clone(r.item.name)})
		reload(st)
		return
	}
	open_file(st, r)
}

go_up :: proc(st: ^State) {
	if len(st.crumbs) > 0 {
		pop(&st.crumbs)
		if len(st.crumbs) == 0 {
			st.owner = ""
			st.owner_handle = ""
		}
		reload(st)
	}
}

go_crumb :: proc(st: ^State, n: int) {
	for len(st.crumbs) > n {
		pop(&st.crumbs)
	}
	if n == 0 {
		st.owner = ""
		st.owner_handle = ""
	}
	reload(st)
}

ensure_visible :: proc(st: ^State) {
	per := st.view == .Grid ? max(1, st.cols) : 1
	line := st.sel / per
	if line < st.top {
		st.top = line
	}
	if st.vis_rows > 0 && line >= st.top + st.vis_rows {
		st.top = line - st.vis_rows + 1
	}
	st.top = max(0, st.top)
}

// ---------------------------------------------------------------------------
// Actions. Each says what happened in a toast, because a drive that changes
// the server silently is a drive nobody trusts.
// ---------------------------------------------------------------------------

note :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = 0
}

fail :: proc(st: ^State, what: string, e: dc.Error) {
	note(st, dc.offline(e) ? fmt.tprintf("%s: offline", what) : fmt.tprintf("%s: %s", what, e.message))
}

// local_copy is a path on this device holding the row's current content:
// the synced copy when it matches, otherwise a download into the cache.
local_copy :: proc(st: ^State, r: ^Row) -> (path: string, ok: bool) {
	if r.local != "" {
		if fi, err := os.stat(r.local, context.temp_allocator); err == nil && fi.size == r.item.size {
			return r.local, true
		}
	}
	it := r.item
	if it.version_id == "" {
		full, e := dc.get_item(&st.c, it.id)
		if dc.failed(e) {
			fail(st, "Open", e)
			return "", false
		}
		it = full
	}
	v, e := dc.current_version(&st.c, it)
	if dc.failed(e) {
		fail(st, "Open", e)
		return "", false
	}
	home := os.get_env("HOME", context.temp_allocator)
	dir := fmt.tprintf("%s/.cache/palm-drive/open/%s", home, it.id)
	os.make_directory_all(dir)
	dest := fmt.aprintf("%s/%s", dir, it.name)
	if fi, err := os.stat(dest, context.temp_allocator); err == nil && fi.size == v.size {
		if h, hok := dc.hash_file(dest, context.temp_allocator); hok && h.hash == v.content_hash {
			return dest, true
		}
	}
	if de := dc.download_to(&st.c, it.identity_id, v, dest); dc.failed(de) {
		fail(st, "Open", de)
		return "", false
	}
	return dest, true
}

// open_file hands the file to the Palmframe app for its kind: Docs, Sheets,
// Slides, Image, Video, Reader. Anything else goes to xdg-open.
open_file :: proc(st: ^State, r: ^Row) {
	path, ok := local_copy(st, r)
	if !ok {
		return
	}
	dc.touch(&st.c, r.item.id)
	app := dc.app_for(r.item.name)
	if app != "" {
		if bin, found := app_binary(app); found {
			if !kit.launch({bin, path}) {
				fmt.eprintfln("drive: could not start %s", bin)
			}
			note(st, fmt.tprintf("Opening %s in %s", r.item.name, app_title(app)))
			return
		}
	}
	kit.launch({"xdg-open", path})
	note(st, fmt.tprintf("Opening %s", r.item.name))
}

app_title :: proc(app: string) -> string {
	switch app {
	case "docs":
		return "Docs"
	case "sheets":
		return "Sheets"
	case "slides":
		return "Slides"
	case "image":
		return "Image"
	case "video":
		return "Video"
	case "reader":
		return "Reader"
	}
	return app
}

// app_binary finds an application the way `palm` does: $PALM_BIN_DIR, then
// beside this binary (apps/<app>/<app>.bin in the tree), then the installed
// /usr/bin/<app> of the distribution.
app_binary :: proc(app: string) -> (string, bool) {
	cands := make([dynamic]string, context.temp_allocator)
	if over := os.get_env("PALM_BIN_DIR", context.temp_allocator); over != "" {
		append(&cands, fmt.tprintf("%s/%s.bin", over, app), fmt.tprintf("%s/%s", over, app))
	}
	self, err := os.get_executable_path(context.temp_allocator)
	if err == nil {
		dir := self[:max(0, strings.last_index_byte(self, '/'))]
		append(&cands, fmt.tprintf("%s/../%s/%s.bin", dir, app, app))
	}
	append(&cands, fmt.tprintf("/usr/bin/%s", app))
	for c in cands {
		if os.exists(c) {
			return c, true
		}
	}
	return "", false
}

download_row :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok || r.item.kind != "file" {
		return
	}
	src, got := local_copy(st, r)
	if !got {
		return
	}
	home := os.get_env("HOME", context.temp_allocator)
	dir := fmt.tprintf("%s/Downloads", home)
	os.make_directory_all(dir)
	dest := unique_path(dir, r.item.name)
	data, err := os.read_entire_file(src, context.temp_allocator)
	if err != nil || os.write_entire_file(dest, data) != nil {
		note(st, "Download failed")
		return
	}
	note(st, fmt.tprintf("Saved to %s", dest))
}

unique_path :: proc(dir, name: string) -> string {
	cand := fmt.aprintf("%s/%s", dir, name)
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	for k := 2; os.exists(cand); k += 1 {
		cand = fmt.aprintf("%s/%s (%d)%s", dir, stem, k, ext)
	}
	return cand
}

upload_paths :: proc(st: ^State, paths: []string) {
	if st.section != .Drive || st.owner != "" {
		note(st, "Uploads go into My Drive: open it first")
		return
	}
	n := 0
	for path in paths {
		name := path[strings.last_index_byte(path, '/') + 1:]
		if os.is_dir(path) {
			continue
		}
		_, _, e := dc.upload_file(&st.c, path, current_folder(st), name, "", 0)
		if dc.failed(e) {
			fail(st, fmt.tprintf("Upload %s", name), e)
			return
		}
		n += 1
	}
	reload(st)
	note(st, n == 1 ? "Uploaded 1 file" : fmt.tprintf("Uploaded %d files", n))
}

toggle_star :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok || r.item.identity_id != st.c.identity {
		return
	}
	on := !r.item.starred
	if e := dc.set_starred(&st.c, r.item.id, on); dc.failed(e) {
		fail(st, "Star", e)
		return
	}
	r.item.starred = on
	note(st, on ? fmt.tprintf("Starred %s", r.item.name) : fmt.tprintf("Unstarred %s", r.item.name))
	if st.section == .Starred {
		reload(st)
	}
}

trash_row :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok || st.section == .Trash || st.section == .Shared && len(st.crumbs) == 0 {
		return
	}
	name := strings.clone(r.item.name, context.temp_allocator)
	if e := dc.trash(&st.c, r.item.id); dc.failed(e) {
		fail(st, "Move to trash", e)
		return
	}
	reload(st)
	note(st, fmt.tprintf("Moved %s to the trash", name))
}

restore_row :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok || st.section != .Trash {
		return
	}
	it, e := dc.restore(&st.c, r.item.id)
	if dc.failed(e) {
		fail(st, "Restore", e)
		return
	}
	reload(st)
	note(st, fmt.tprintf("Restored %s", it.name))
}

empty_trash :: proc(st: ^State) {
	n, e := dc.empty_trash(&st.c)
	if dc.failed(e) {
		fail(st, "Empty trash", e)
		return
	}
	reload(st)
	note(st, fmt.tprintf("Deleted %d item%s for good", n, n == 1 ? "" : "s"))
}

new_folder :: proc(st: ^State, name: string) {
	nm := strings.trim_space(name)
	if nm == "" {
		return
	}
	_, e := dc.mkdir(&st.c, current_folder(st), nm)
	if dc.failed(e) {
		fail(st, "New folder", e)
		return
	}
	reload(st)
	for r, i in st.rows {
		if r.item.name == nm {
			st.sel = i
		}
	}
	note(st, fmt.tprintf("Created %s", nm))
}

share_with :: proc(st: ^State, handle: string) {
	r, ok := selected(st)
	h := strings.to_lower(strings.trim_space(strings.trim_prefix(handle, "@")), context.temp_allocator)
	if at := strings.index_byte(h, '@'); at > 0 {
		h = h[:at] // bob@palm.test -> bob
	}
	if !ok || h == "" {
		return
	}
	if h == ident(st).handle {
		note(st, "That is this identity: it already owns the file")
		return
	}
	_, e := dc.share(&st.c, r.item.id, h, st.share_role)
	if dc.failed(e) {
		if e.code == "PT404" {
			note(st, fmt.tprintf("No identity called %s", h))
		} else {
			fail(st, "Share", e)
		}
		return
	}
	clear(&st.field)
	st.detail_id = ""
	load_detail(st)
	r.shared = true
	note(st, fmt.tprintf("Shared %s with %s as %s", r.item.name, h, st.share_role))
}

unshare :: proc(st: ^State, i: int) {
	if i < 0 || i >= len(st.share_rows) {
		return
	}
	s := st.share_rows[i]
	if e := dc.revoke_share(&st.c, s.id); dc.failed(e) {
		fail(st, "Remove access", e)
		return
	}
	who := strings.clone(s.grantee_handle, context.temp_allocator)
	st.detail_id = ""
	load_detail(st)
	note(st, fmt.tprintf("%s no longer has access", who))
}

LINK_BASE :: "https://drive.palm.test/s/"

mint_link :: proc(st: ^State) {
	r, ok := selected(st)
	if !ok {
		return
	}
	m, e := dc.link_mint(&st.c, r.item.id, "7 days")
	if dc.failed(e) {
		fail(st, "Create link", e)
		return
	}
	delete(st.minted)
	st.minted = fmt.aprintf("%s%s", LINK_BASE, m.token)
	kit.clipboard_set(st.minted)
	st.detail_id = ""
	load_detail(st)
	r.shared = true
	note(st, "Link created and copied. It is shown only now.")
}

revoke_links :: proc(st: ^State) {
	n := 0
	for l in st.links {
		if dc.revoke_link(&st.c, l.id) == {} {
			n += 1
		}
	}
	delete(st.minted)
	st.minted = ""
	st.detail_id = ""
	load_detail(st)
	note(st, n == 1 ? "Link turned off" : fmt.tprintf("%d links turned off", n))
}

// sync_status reads the daemon's state file: when it last finished a pass
// for this identity, which is all the window needs to say.
sync_status :: proc(st: ^State) -> (text: string, ok: bool) {
	path := dc.state_path(&st.cfg, ident(st))
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return "Not synced on this device", false
	}
	return fmt.tprintf("Synced %s", rel_time(st, fi.modification_time)), true
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

rel_time :: proc(st: ^State, t: time.Time) -> string {
	d := time.diff(t, st.now)
	s := time.duration_seconds(d)
	switch {
	case s < 60:
		return "just now"
	case s < 3600:
		return fmt.tprintf("%d min ago", int(s / 60))
	case s < 86400:
		return fmt.tprintf("%d h ago", int(s / 3600))
	}
	return fmt.tprintf("%d days ago", int(s / 86400))
}

MONTHS := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

rel_date :: proc(st: ^State, iso: string) -> string {
	if iso == "" {
		return "—"
	}
	t, n := time.rfc3339_to_time_utc(iso)
	if n == 0 {
		return "—"
	}
	off := time.Duration(dc.local_offset()) * time.Second
	lt := time.time_add(t, off)
	ln := time.time_add(st.now, off)
	y, m, d := time.date(lt)
	ny, nm, nd := time.date(ln)
	hh, mm, _ := time.clock(lt)
	if y == ny && m == nm && d == nd {
		return fmt.aprintf("Today %02d:%02d", hh, mm)
	}
	yd := time.time_add(ln, -24 * time.Hour)
	yy, ym, ydd := time.date(yd)
	if y == yy && m == ym && d == ydd {
		return fmt.aprintf("Yesterday %02d:%02d", hh, mm)
	}
	if y == ny {
		return fmt.aprintf("%s %d", MONTHS[int(m) - 1], d)
	}
	return fmt.aprintf("%s %d, %d", MONTHS[int(m) - 1], d, y)
}

icon_for :: proc(name, kind: string) -> (p.Icon, string, string) {
	if kind == "folder" {
		return ICON_FOLDER, "text-sky-500", "Folder"
	}
	ext := ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		ext = strings.to_lower(name[dot + 1:], context.temp_allocator)
	}
	switch ext {
	case "pdf":
		return ICON_FILE_TEXT, "text-rose-500", "PDF document"
	case "docx", "doc", "odt", "rtf":
		return ICON_FILE_TEXT, "text-blue-600", "Document"
	case "md", "txt":
		return ICON_FILE_TEXT, "text-slate-500", ext == "md" ? "Markdown" : "Plain text"
	case "xlsx", "xls", "ods", "csv":
		return ICON_FILE_SPREADSHEET, "text-emerald-600", "Spreadsheet"
	case "pptx", "ppt", "odp":
		return ICON_PRESENTATION, "text-orange-500", "Presentation"
	case "png", "jpg", "jpeg", "gif", "webp", "svg":
		return ICON_FILE_IMAGE, "text-violet-500", "Image"
	case "mp4", "webm", "mkv", "mov":
		return ICON_FILE_PLAY, "text-fuchsia-500", "Video"
	case "mp3", "flac", "wav":
		return ICON_FILE_HEADPHONE, "text-amber-500", "Audio"
	case "zip", "gz", "tar", "7z":
		return ICON_FILE_ARCHIVE, "text-orange-600", "Archive"
	case "odin", "c", "go", "rs", "js", "ts", "py", "sh", "json", "css", "html":
		return ICON_FILE_CODE, "text-emerald-600", "Source code"
	}
	return ICON_FILE, "text-slate-400", "File"
}

is_image :: proc(name: string) -> bool {
	return dc.app_for(name) == "image"
}
