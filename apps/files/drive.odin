// Drive: the folders palm-drive mirrors, ~/Drive/<handle>, one per identity
// (cloud/docs/drive.md, "What apps/files should do").
//
//   - The sidebar gets a Drive group, one entry per identity, from
//     `palm-drive identities --json`, coloured by the identity's kind.
//   - Files under a drive carry a sync badge, from `palm-drive status
//     --json`, read on a thread of its own because it asks the server: a
//     pending upload or download, a conflict (or a "(conflicted copy, ...)"
//     name), or synced.
//   - Share... and Copy Link in the context menu run `drive share` and
//     `drive link` as the identity that owns the file (PALM_IDENTITY), on
//     the path relative to its folder.
//   - A move (Cut, then Paste) between two identities' folders is refused:
//     across identities that is a share or an explicit copy, never a rename,
//     the same way the database refuses it.
//
// Without palm-drive on PATH, or with no identities, none of this shows.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import kit "kit:."
import p "palmy:."

Drive_Id :: struct {
	handle: string,
	name:   string,
	kind:   string,
	root:   string,
}

Drive_Badge :: enum u8 {
	None, // not under a drive, or its status is not known yet
	Synced,
	Pending, // a pass would upload, download, create or delete it (or something inside it)
	Conflict,
}

Drive :: struct {
	ids:      [dynamic]Drive_Id,

	// Written by the status thread, read by the frame under `mu`.
	mu:       sync.Mutex,
	badges:   map[string]Drive_Badge, // absolute path -> Pending/Conflict
	known:    map[string]bool, // roots whose status has been read
	offline:  bool,
	running:  bool,
	app:      ^p.App,

	cut:      string, // a path waiting for Paste, "" when none

	// The Share... prompt.
	share_open:   bool,
	share_path:   string,
	share_handle: [dynamic]u8,
}

// ---------------------------------------------------------------------------
// Identities
// ---------------------------------------------------------------------------

// drive_init reads the identities once, at start, and adds them as places.
drive_init :: proc(st: ^State, app: ^p.App) {
	st.drive.app = app
	st.drive.ids = drive_identities()
	for id in st.drive.ids {
		if !is_dir_path(id.root) {
			continue
		}
		label := id.name != "" ? id.name : id.handle
		append(&st.places, Place{strings.clone(label), strings.clone(id.root), ICON_CLOUD, drive_tint(id.kind), "Drive"})
	}
}

// drive_identities asks palm-drive which identities have a folder here. No
// palm-drive, or no session, is no identities — and none of Drive shows. The
// browser and `files move` both read them through this.
drive_identities :: proc() -> [dynamic]Drive_Id {
	if !on_path("palm-drive") {
		return make([dynamic]Drive_Id)
	}
	out, ok := kit.run({"palm-drive", "identities", "--json"}, context.temp_allocator)
	if !ok {
		return make([dynamic]Drive_Id)
	}
	return drive_parse_identities(out)
}

// drive_tint is the colour of an identity's kind, the same everywhere the
// identity appears in Files.
drive_tint :: proc(kind: string) -> string {
	switch kind {
	case "personal":
		return "text-sky-500"
	case "work":
		return "text-amber-500"
	case "school":
		return "text-emerald-500"
	}
	return "text-violet-500"
}

// find_list returns the array under `key` in a palm-drive --json answer,
// at the top level or one object down.
@(private = "file")
find_list :: proc(v: json.Value, key: string) -> (json.Array, bool) {
	obj, is := v.(json.Object)
	if !is {
		return nil, false
	}
	if a, has := obj[key].(json.Array); has {
		return a, true
	}
	for _, inner in obj {
		if o, io := inner.(json.Object); io {
			if a, has := o[key].(json.Array); has {
				return a, true
			}
		}
	}
	return nil, false
}

@(private = "file")
jstr :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return string(s)
}

drive_parse_identities :: proc(text: string, allocator := context.allocator) -> [dynamic]Drive_Id {
	out := make([dynamic]Drive_Id, allocator)
	v, err := json.parse(transmute([]u8)strings.trim_space(text), .JSON, true, context.temp_allocator)
	if err != nil {
		return out
	}
	arr, ok := find_list(v, "identities")
	if !ok {
		return out
	}
	for it in arr {
		o, is := it.(json.Object)
		if !is {continue}
		id := Drive_Id {
			handle = strings.clone(jstr(o, "handle"), allocator),
			name   = strings.clone(jstr(o, "name"), allocator),
			kind   = strings.clone(jstr(o, "kind"), allocator),
			root   = strings.clone(strings.trim_right(jstr(o, "root"), "/"), allocator),
		}
		if id.handle != "" && id.root != "" {
			append(&out, id)
		}
	}
	return out
}

// drive_of is the identity whose folder holds `path`, and the path inside it.
drive_of :: proc(d: ^Drive, path: string) -> (id: Drive_Id, rel: string, ok: bool) {
	for it in d.ids {
		if path == it.root {
			return it, "", true
		}
		if strings.has_prefix(path, it.root) && len(path) > len(it.root) && path[len(it.root)] == '/' {
			return it, path[len(it.root) + 1:], true
		}
	}
	return {}, "", false
}

// ---------------------------------------------------------------------------
// Status badges
// ---------------------------------------------------------------------------

// drive_parse_status turns `palm-drive status --json` into badges by
// absolute path: each action names a path relative to its identity's root
// ("would Upload_Change notes/a.md", "queued: upload new file notes/b.md",
// "would Conflict report.txt"). The folders above a pending or conflicted
// path are marked too, so the way to it shows from the drive's top.
drive_parse_status :: proc(text: string, badges: ^map[string]Drive_Badge, known: ^map[string]bool) -> (offline: bool) {
	v, err := json.parse(transmute([]u8)strings.trim_space(text), .JSON, true, context.temp_allocator)
	if err != nil {
		return false
	}
	arr, ok := find_list(v, "identities")
	if !ok {
		return false
	}
	for it in arr {
		o, is := it.(json.Object)
		if !is {continue}
		root := strings.trim_right(jstr(o, "root"), "/")
		if root == "" {continue}
		known[strings.clone(root)] = true
		if b, has := o["offline"].(json.Boolean); has && bool(b) {
			offline = true
		}
		acts, _ := o["actions"].(json.Array)
		for a in acts {
			s, _ := a.(json.String)
			rel, badge := action_path(string(s))
			if rel == "" || badge == .None {continue}
			mark(badges, root, rel, badge)
		}
	}
	return
}

// action_path is the relative path an action names and what it means for it.
action_path :: proc(action: string) -> (rel: string, badge: Drive_Badge) {
	switch {
	case strings.has_prefix(action, "would "):
		rest := action[len("would "):]
		sp := strings.index_byte(rest, ' ')
		if sp < 0 {return "", .None}
		plan := rest[:sp]
		rel = rest[sp + 1:]
		switch plan {
		case "Conflict":
			return rel, .Conflict
		case "Upload_New", "Upload_Change", "Download", "Mkdir_Remote", "Mkdir_Local", "Trash_Remote", "Delete_Local":
			return rel, .Pending
		}
		return "", .None
	case strings.has_prefix(action, "queued: upload new "):
		// "queued: upload new <kind> <path>"
		rest := action[len("queued: upload new "):]
		sp := strings.index_byte(rest, ' ')
		return sp < 0 ? "" : rest[sp + 1:], .Pending
	case strings.has_prefix(action, "queued: upload change "):
		return action[len("queued: upload change "):], .Pending
	case strings.has_prefix(action, "queued: delete "):
		return action[len("queued: delete "):], .Pending
	}
	return "", .None
}

@(private = "file")
mark :: proc(badges: ^map[string]Drive_Badge, root, rel: string, badge: Drive_Badge) {
	path := fmt.tprintf("%s/%s", strings.trim_right(root, "/"), strings.trim_right(rel, "/"))
	for len(path) > len(root) {
		if have, has := badges[path]; !has {
			badges[strings.clone(path)] = badge
		} else if badge > have {
			badges[path] = badge
		}
		i := strings.last_index_byte(path, '/')
		if i < 0 {
			break
		}
		path = path[:i]
	}
}

// drive_badge is what a row shows for `path` (whose last element is `name`).
drive_badge :: proc(d: ^Drive, path, name: string) -> Drive_Badge {
	if len(d.ids) == 0 {
		return .None
	}
	id, _, ok := drive_of(d, path)
	if !ok {
		return .None
	}
	if strings.contains(name, "(conflicted copy, ") {
		return .Conflict
	}
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	if b, has := d.badges[path]; has {
		return b
	}
	if d.known[id.root] {
		return .Synced
	}
	return .None
}

// drive_refresh asks palm-drive for the status on a thread of its own, when
// the folder being shown is in a drive and no refresh is running already.
drive_refresh :: proc(st: ^State) {
	d := &st.drive
	if len(d.ids) == 0 || !on_path("palm-drive") {
		return
	}
	if _, _, in_drive := drive_of(d, st.cwd); !in_drive {
		return
	}
	sync.mutex_lock(&d.mu)
	busy := d.running
	d.running = true
	sync.mutex_unlock(&d.mu)
	if busy {
		return
	}
	t := thread.create(proc(t: ^thread.Thread) {
		d := (^Drive)(t.data)
		out, ok := kit.run({"palm-drive", "status", "--json"})
		badges := make(map[string]Drive_Badge)
		known := make(map[string]bool)
		offline := false
		if ok || out != "" {
			offline = drive_parse_status(out, &badges, &known)
		}
		if len(out) > 0 {delete(out)}
		sync.mutex_lock(&d.mu)
		for k, _ in d.badges {delete(k)}
		delete(d.badges)
		for k, _ in d.known {delete(k)}
		delete(d.known)
		d.badges = badges
		d.known = known
		d.offline = offline
		d.running = false
		sync.mutex_unlock(&d.mu)
		if d.app != nil {
			p.wake(d.app)
		}
	})
	t.data = d
	t.init_context = context
	thread.start(t)
}

// ---------------------------------------------------------------------------
// Moving, sharing, links
// ---------------------------------------------------------------------------

// drive_move_refusal is why `src` may not be renamed into the folder `dir`,
// or "" when it may: a plain rename never crosses from one identity's drive
// into another's.
drive_move_refusal :: proc(d: ^Drive, src, dir: string) -> string {
	a, _, in_a := drive_of(d, src)
	b, _, in_b := drive_of(d, dir)
	if in_a && in_b && a.handle != b.handle {
		return fmt.tprintf(
			"Not moved: %s and %s are different identities' drives. Share it with %s instead (Share…), or copy it.",
			a.handle, b.handle, b.handle,
		)
	}
	return ""
}

// drive_paste moves the cut item into the current folder.
drive_paste :: proc(st: ^State) {
	d := &st.drive
	if d.cut == "" {
		note(st, "Nothing to paste: cut something first (Ctrl X)")
		return
	}
	if why := drive_move_refusal(d, d.cut, st.cwd); why != "" {
		note(st, why)
		return
	}
	// The move itself is the core's (fs.odin), the same one `files move` runs.
	if _, fail, why := fs_move(d.cut, st.cwd); fail != .None {
		if fail == .Refused && why == "it is already here" {
			note(st, "It is already here")
		} else {
			note(st, fmt.tprintf("Not moved: %s", why))
		}
		return
	}
	note(st, fmt.tprintf("Moved %s here", base_of(d.cut)))
	delete(d.cut)
	d.cut = ""
	reload(st)
}

drive_cut :: proc(st: ^State) {
	e, has := selected(st)
	if !has {
		return
	}
	if st.drive.cut != "" {delete(st.drive.cut)}
	st.drive.cut = strings.clone(e.path)
	note(st, fmt.tprintf("Cut %s — open a folder and paste (Ctrl V) to move it", e.name))
}

// drive_cmd runs the drive CLI as the identity that owns the file.
@(private = "file")
drive_cmd :: proc(handle: string, args: ..string) -> (string, bool) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "env", fmt.tprintf("PALM_IDENTITY=%s", handle), "drive")
	append(&argv, ..args)
	append(&argv, "--json")
	return kit.run(argv[:], context.temp_allocator)
}

@(private = "file")
cli_error :: proc(out: string) -> string {
	if v, err := json.parse(transmute([]u8)strings.trim_space(out), .JSON, true, context.temp_allocator); err == nil {
		if o, is := v.(json.Object); is {
			if e, has := o["error"].(json.String); has {
				return string(e)
			}
		}
	}
	return strings.trim_space(out)
}

drive_copy_link :: proc(st: ^State, path: string) {
	id, rel, ok := drive_of(&st.drive, path)
	if !ok || rel == "" {
		return
	}
	out, good := drive_cmd(id.handle, "link", rel)
	url := ""
	if v, err := json.parse(transmute([]u8)strings.trim_space(out), .JSON, true, context.temp_allocator); err == nil {
		if o, is := v.(json.Object); is {
			url = jstr(o, "url")
			if url == "" {
				for _, inner in o {
					if io, iis := inner.(json.Object); iis && jstr(io, "url") != "" {
						url = jstr(io, "url")
					}
				}
			}
		}
	}
	if !good || url == "" {
		note(st, fmt.tprintf("No link: %s", cli_error(out)))
		return
	}
	if p.clipboard_set(url) || kit.launch({"wl-copy", "--", url}) {
		note(st, fmt.tprintf("Link copied: %s", url))
	} else {
		note(st, fmt.tprintf("Link: %s", url))
	}
}

drive_share_open :: proc(st: ^State, path: string) {
	if _, rel, ok := drive_of(&st.drive, path); !ok || rel == "" {
		return
	}
	d := &st.drive
	if d.share_path != "" {delete(d.share_path)}
	d.share_path = strings.clone(path)
	clear(&d.share_handle)
	d.share_open = true
}

drive_share_commit :: proc(st: ^State) {
	d := &st.drive
	grantee := strings.trim_space(string(d.share_handle[:]))
	d.share_open = false
	id, rel, ok := drive_of(d, d.share_path)
	if !ok || grantee == "" {
		return
	}
	out, good := drive_cmd(id.handle, "share", rel, grantee)
	if good {
		note(st, fmt.tprintf("Shared %s with %s (viewer)", base_of(d.share_path), grantee))
	} else {
		note(st, fmt.tprintf("Not shared: %s", cli_error(out)))
	}
}

// drive_share_keys runs while the Share… prompt is open: typed text goes to
// the handle, Enter shares, Escape cancels.
drive_share_keys :: proc(ui: ^p.Ctx, st: ^State) {
	d := &st.drive
	if plain(ui, p.KEY_ESCAPE) {
		d.share_open = false
		return
	}
	if plain(ui, p.KEY_RETURN) {
		drive_share_commit(st)
		return
	}
	for _ in 0 ..< key_times(ui, p.KEY_BACKSPACE) {
		if len(d.share_handle) > 0 {
			pop(&d.share_handle)
		}
	}
	text := strings.to_string(ui.input.text)
	for i in 0 ..< len(text) {
		c := text[i]
		if c > ' ' && c < 0x7f {
			append(&d.share_handle, c)
		}
	}
}

drive_share_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	d := &st.drive
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/40 items-center justify-center")
	if p.clickable(ui, scrim) {
		d.share_open = false
	}
	defer p.end(ui)
	id, rel, _ := drive_of(d, d.share_path)
	p.col(ui, "w-[420] p-5 gap-3 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)
	p.text(ui, fmt.tprintf("Share %s", base_of(d.share_path)), "text-[15] font-semibold text-foreground truncate")
	p.text(ui, fmt.tprintf("From %s's drive (%s). Type the handle of the identity to share it with; it gets view access.", id.handle, rel), "text-[12.5] text-muted-foreground")
	p.row(ui, "h-9 w-full items-center px-3 rounded-lg border border-ring ring-3 ring-ring/40 bg-background")
	typed := string(d.share_handle[:])
	if typed == "" {
		p.text(ui, "bob.chen", "text-[13] text-muted-foreground")
	} else {
		p.text(ui, typed, "text-[13] text-foreground")
	}
	p.div(ui, "w-[2] h-[16] bg-primary")
	p.end(ui)
	p.end(ui)
	p.text(ui, "Enter to share · Esc to cancel", "text-[11.5] text-muted-foreground")
}
