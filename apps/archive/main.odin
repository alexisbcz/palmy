package main

// palmy archive manager.
//
// Browse an archive as a tree, extract all of it or a selection, and build a
// new archive from a directory. bsdtar does the work; this is the part that
// decides what it is allowed to do.
//
// Extraction is the only thing here that writes to the filesystem, so it is the
// only thing with a gate in front of it:
//
//   * the destination is always a directory the user can see and edit, and it
//     defaults to ~/Downloads/<archive name>/ rather than anywhere surprising;
//   * every entry name is checked before it is offered (see check_name in
//     arc.odin): absolute paths, drive letters, anything whose `..` segments
//     take it above the destination, and symbolic links are marked and left
//     out of the extraction list;
//   * a confirmation step names the destination, the number of entries, the
//     number already on disk and the number refused, and overwriting is a
//     separate key from going ahead.
//
// Everything slow — listing, extracting, creating — runs on a worker thread.
// The frame polls two atomics and keeps drawing.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1120
WIN_H :: 720

ROW_H :: 34
SIDE_W :: 340

Mode :: enum u8 {
	Browse,
	Open,
	Dest,
	Create,
	Confirm,
	Done,
}

// Row is one line of the current view: a real entry, or a directory implied by
// the entries beneath it.
Row :: struct {
	name:  string, // full path inside the archive
	label: string,
	dir:   bool,
	size:  i64,
	date:  string,
	count: int, // entries beneath, for a directory
	bad:   bool,
	why:   string,
	item:  int, // index into st.items, or -1 when implied
}

St :: struct {
	archive:   string,
	items:     []Item,
	cwd:       string,
	rows:      [dynamic]Row,
	// Names of rows that exist only because something below them named a
	// folder. They outlive the frame arena because `handle_keys` reads the
	// rows built on the previous pass.
	owned:     [dynamic]string,
	sel:       int,
	top:       int,
	vis:       int,
	marks:     map[string]bool,

	dest:      string,
	create_src: string,
	create_out: string,

	filtering: bool,
	filter:    [dynamic]u8,

	mode:      Mode,
	edit:      [dynamic]u8,
	edit_which: int,

	found:     [dynamic]string,
	found_sel: int,

	// Staged for the confirmation dialog.
	stage:     [dynamic]string,
	stage_bad: int,
	stage_hit: int, // entries that already exist in the destination

	busy_label: string,
	result:    string,
	result_ok: bool,

	toast:     string,
	toast_t:   f64,
	have_tar:  bool,
}

main :: proc() {
	for a in os.args[1:] {
		if a == "--selftest" || a == "-selftest" {
			os.exit(selftest() == 0 ? 0 : 1)
		}
	}

	app, err := kit.start(
		{
			title = "Archive",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 820,
			min_height = 460,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
	)
	if err != "" {
		fmt.eprintfln("archive: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_dark_theme()

	st := St {
		rows       = make([dynamic]Row),
		owned      = make([dynamic]string),
		marks      = make(map[string]bool),
		filter     = make([dynamic]u8),
		edit       = make([dynamic]u8),
		found      = make([dynamic]string),
		stage      = make([dynamic]string),
		have_tar   = kit.has_tool("bsdtar"),
		create_src = strings.clone(home_rel("")),
		create_out = strings.clone(home_rel("Downloads/archive.zip")),
	}
	scan_for_archives(&st)
	st.mode = .Open

	if len(os.args) > 1 && os.args[1] != "" {
		open_archive(&st, os.args[1])
	}

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		if job_busy() {
			ui.animating = true
		}
		collect(&st, ui)

		handle_keys(ui, app, &st)
		rebuild_rows(&st)
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

// quit is nil-safe so the headless self-test can drive `handle_keys` with no
// window behind it.
quit :: proc(app: ^p.App) {
	if app != nil {
		p.quit_app(app)
	}
}

home_rel :: proc(rest: string, al := context.temp_allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		home = "/tmp"
	}
	if rest == "" {
		return strings.clone(home, al)
	}
	return fmt.aprintf("%s/%s", home, rest, allocator = al)
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

// scan_for_archives looks in the obvious places so the Open pane is not an
// empty text field.
scan_for_archives :: proc(st: ^St) {
	for s in st.found {delete(s)}
	clear(&st.found)

	dirs := [?]string{home_rel("Downloads"), home_rel("Desktop"), home_rel(""), "/tmp"}
	for d in dirs {
		f, oerr := os.open(d)
		if oerr != nil {
			continue
		}
		infos, rerr := os.read_dir(f, -1, context.temp_allocator)
		os.close(f)
		if rerr != nil && len(infos) == 0 {
			continue
		}
		for fi in infos {
			if fi.type == .Directory || !is_archive_path(fi.name) {
				continue
			}
			append(&st.found, strings.clone(fi.fullpath))
			if len(st.found) >= 60 {
				return
			}
		}
	}
	slice.sort(st.found[:])
}

open_archive :: proc(st: ^St, path: string) {
	if !st.have_tar {
		return
	}
	abs := strings.trim_space(path)
	if abs == "" {
		return
	}
	if !os.exists(abs) {
		st.result_ok = false
		st.result = fmt.aprintf("%s does not exist", abs)
		st.mode = .Done
		return
	}

	if st.items != nil {
		free_items(st.items)
		st.items = nil
	}
	clear_marks(st)
	delete(st.archive)
	st.archive = strings.clone(abs)
	st.cwd = ""
	st.sel = 0
	st.top = 0

	delete(st.dest)
	st.dest = fmt.aprintf(
		"%s/%s",
		home_rel("Downloads", context.temp_allocator),
		strip_archive_ext(abs, context.temp_allocator),
	)

	st.busy_label = "Reading the archive"
	job_start(Job{kind = .List, archive = strings.clone(abs)})
	st.mode = .Browse
}

collect :: proc(st: ^St, ui: ^p.Ctx) {
	j, got := job_collect()
	if !got {
		return
	}
	st.busy_label = ""
	switch j.kind {
	case .None:
	case .List:
		if j.ok {
			st.items = j.items
			st.sel = 0
			st.top = 0
		} else {
			st.result_ok = false
			st.result = strings.clone(j.msg)
			st.mode = .Done
		}
	case .Extract, .Create:
		st.result_ok = j.ok
		st.result = strings.clone(j.msg)
		st.mode = .Done
		if j.kind == .Create {
			scan_for_archives(st)
		}
	}
	job_release(j)
}

// ---------------------------------------------------------------------------
// The directory view
// ---------------------------------------------------------------------------

filter_text :: proc(st: ^St) -> string {
	return string(st.filter[:])
}

rebuild_rows :: proc(st: ^St) {
	clear(&st.rows)
	for s in st.owned {delete(s)}
	clear(&st.owned)
	if st.items == nil {
		st.sel = 0
		return
	}

	q := strings.to_lower(strings.trim_space(filter_text(st)), context.temp_allocator)
	if st.filtering && q != "" {
		// Searching flattens the tree: an archive is usually opened to find one
		// file, and making the user walk to it is the wrong answer.
		for it, i in st.items {
			if it.dir {
				continue
			}
			low := strings.to_lower(it.name, context.temp_allocator)
			if !strings.contains(low, q) {
				continue
			}
			append(
				&st.rows,
				Row {
					name = it.name,
					label = it.name,
					dir = false,
					size = it.size,
					date = it.date,
					bad = it.bad,
					why = it.why,
					item = i,
				},
			)
		}
		st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
		return
	}

	seen := make(map[string]bool, context.temp_allocator)
	for it, i in st.items {
		if !strings.has_prefix(it.name, st.cwd) {
			continue
		}
		rest := it.name[len(st.cwd):]
		if rest == "" || rest == "/" {
			continue
		}
		slash := strings.index_byte(rest, '/')
		if slash < 0 {
			append(
				&st.rows,
				Row {
					name = it.name,
					label = rest,
					dir = false,
					size = it.size,
					date = it.date,
					bad = it.bad,
					why = it.why,
					item = i,
				},
			)
			continue
		}
		// Either an explicit directory entry, or a directory implied by a
		// deeper path. Both land on the same row.
		seg := rest[:slash]
		full := fmt.tprintf("%s%s/", st.cwd, seg)
		if seen[full] {
			continue
		}
		seen[full] = true
		n, total := 0, i64(0)
		for d in st.items {
			if strings.has_prefix(d.name, full) && d.name != full {
				n += 1
				total += d.size
			}
		}
		// A folder that only exists because something below it named it —
		// `../` or the root of an absolute entry — is refused in its own
		// right, so it reads as refused in the list rather than looking like
		// an ordinary directory full of refused files.
		why := check_name(full, false)
		owned := strings.clone(full)
		append(&st.owned, owned)
		append(
			&st.rows,
			Row {
				name = owned,
				label = seg == "" ? "/" : seg,
				dir = true,
				size = total,
				date = it.dir && rest == fmt.tprintf("%s/", seg) ? it.date : "",
				count = n,
				bad = why != "",
				why = why,
				item = it.dir && slash == len(rest) - 1 ? i : -1,
			},
		)
	}

	slice.sort_by(st.rows[:], proc(a, b: Row) -> bool {
		if a.dir != b.dir {
			return a.dir
		}
		return a.label < b.label
	})
	st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
}

current :: proc(st: ^St) -> (Row, bool) {
	if st.sel < 0 || st.sel >= len(st.rows) {
		return {}, false
	}
	return st.rows[st.sel], true
}

keep_visible :: proc(st: ^St) {
	if st.vis <= 0 {
		return
	}
	if st.sel < st.top {st.top = st.sel}
	if st.sel >= st.top + st.vis {st.top = st.sel - st.vis + 1}
	st.top = clamp(st.top, 0, max(0, len(st.rows) - st.vis))
}

// ---------------------------------------------------------------------------
// Marks and staging
// ---------------------------------------------------------------------------

marked_count :: proc(st: ^St) -> int {
	return len(st.marks)
}

// stage_extraction expands the marks into a concrete list of entry names,
// counts what the safety check refused, and counts what already exists in the
// destination. Nothing is written until the dialog it feeds is confirmed.
stage_extraction :: proc(st: ^St) {
	for s in st.stage {delete(s)}
	clear(&st.stage)
	st.stage_bad = 0
	st.stage_hit = 0

	want :: proc(st: ^St, it: Item) -> bool {
		if len(st.marks) == 0 {
			return true
		}
		for m in st.marks {
			if m == it.name {
				return true
			}
			if strings.has_suffix(m, "/") && strings.has_prefix(it.name, m) {
				return true
			}
		}
		return false
	}

	for it in st.items {
		if !want(st, it) {
			continue
		}
		if it.bad {
			st.stage_bad += 1
			continue
		}
		append(&st.stage, strings.clone(it.name))
		if !it.dir {
			if os.exists(fmt.tprintf("%s/%s", st.dest, it.name)) {
				st.stage_hit += 1
			}
		}
	}
}

start_extract :: proc(st: ^St, overwrite: bool) {
	names := make([]string, len(st.stage))
	for s, i in st.stage {
		names[i] = strings.clone(s)
	}
	st.busy_label = overwrite ? "Extracting, overwriting existing files" : "Extracting"
	job_start(
		Job {
			kind = .Extract,
			archive = strings.clone(st.archive),
			dest = strings.clone(st.dest),
			names = names,
			overwrite = overwrite,
		},
	)
	st.mode = .Browse
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if job_busy() {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			job_cancel()
		}
		return
	}

	switch st.mode {
	case .Done:
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_ESCAPE) ||
		   p.key_pressed(ui, p.KEY_SPACE) {
			delete(st.result)
			st.result = ""
			st.mode = st.items != nil ? .Browse : .Open
		}
		return
	case .Confirm:
		confirm_keys(ui, st)
		return
	case .Open:
		open_keys(ui, app, st)
		return
	case .Dest:
		edit_keys(ui, st, proc(st: ^St, text: string) {
			delete(st.dest)
			st.dest = strings.clone(strings.trim_space(text))
			st.mode = .Browse
		})
		return
	case .Create:
		create_keys(ui, st)
		return
	case .Browse:
	}

	if st.filtering {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			st.filtering = false
			clear(&st.filter)
			st.sel = 0
			return
		}
	} else if p.key_pressed(ui, p.KEY_ESCAPE) {
		quit(app)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		quit(app)
		return
	}

	// `key_count`, so several presses landing in one frame all count.
	st.sel += p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP)
	st.sel +=
		(p.key_count(ui, p.KEY_PAGE_DOWN) - p.key_count(ui, p.KEY_PAGE_UP)) * max(1, st.vis - 1)
	if p.key_pressed(ui, p.KEY_HOME) {st.sel = 0}
	if p.key_pressed(ui, p.KEY_END) {st.sel = len(st.rows) - 1}
	st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
	keep_visible(st)

	if st.filtering {
		// While the filter is open the letters belong to it, so only the keys
		// that cannot be typed stay bound.
		if p.key_pressed(ui, p.KEY_RETURN) {
			st.filtering = false
			return
		}
		edit_buffer(ui, &st.filter)
		st.sel = clamp(st.sel, 0, max(0, len(st.rows) - 1))
		return
	}

	if r, ok := current(st); ok {
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			if r.dir {
				delete_cwd(st)
				st.cwd = strings.clone(r.name)
				st.sel = 0
				st.top = 0
			}
			return
		}
		if p.key_pressed(ui, p.KEY_SPACE) {
			if st.marks[r.name] {
				// The map owns its keys, so dropping one has to free it.
				k, _ := delete_key(&st.marks, r.name)
				delete(k)
			} else {
				st.marks[strings.clone(r.name)] = true
			}
			st.sel = min(st.sel + 1, max(0, len(st.rows) - 1))
			keep_visible(st)
			return
		}
	}

	if p.key_pressed(ui, p.KEY_BACKSPACE) {
		if st.cwd != "" {
			parent, _ := split_parent(strings.trim_suffix(st.cwd, "/"))
			delete_cwd(st)
			st.cwd = strings.clone(parent)
			st.sel = 0
			st.top = 0
		}
		return
	}

	if p.key_pressed(ui, '/') {
		st.filtering = true
		clear(&st.filter)
		st.sel = 0
		return
	}
	if p.key_pressed(ui, 'a') {
		if len(st.marks) > 0 {
			clear_marks(st)
			toast(st, ui, "Selection cleared — extracting now takes everything")
		} else {
			for r in st.rows {
				if !st.marks[r.name] {
					st.marks[strings.clone(r.name)] = true
				}
			}
			toast(st, ui, fmt.tprintf("Marked %d entries in this folder", len(st.rows)))
		}
		return
	}
	if p.key_pressed(ui, 'e') {
		if st.items == nil {
			return
		}
		stage_extraction(st)
		st.mode = .Confirm
		return
	}
	if p.key_pressed(ui, 'd') {
		begin_edit(st, st.dest)
		st.mode = .Dest
		return
	}
	if p.key_pressed(ui, 'o') {
		scan_for_archives(st)
		// Empty, not prefilled with the open archive: the field starting empty
		// is what makes the found list reachable with Up/Down and Enter.
		begin_edit(st, "")
		st.mode = .Open
		return
	}
	if p.key_pressed(ui, 'n') {
		st.edit_which = 0
		begin_edit(st, st.create_src)
		st.mode = .Create
		return
	}
	if p.key_pressed(ui, 'r') && st.archive != "" {
		path := strings.clone(st.archive, context.temp_allocator)
		open_archive(st, path)
		return
	}
}

delete_cwd :: proc(st: ^St) {
	if st.cwd != "" {
		delete(st.cwd)
		st.cwd = ""
	}
}

clear_marks :: proc(st: ^St) {
	for k in st.marks {
		delete(k)
	}
	clear(&st.marks)
}

confirm_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'c') {
		st.mode = .Browse
		return
	}
	if p.key_pressed(ui, 'd') {
		begin_edit(st, st.dest)
		st.mode = .Dest
		return
	}
	if p.key_pressed(ui, 'o') && st.stage_hit > 0 {
		start_extract(st, true)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		if len(st.stage) == 0 {
			st.mode = .Browse
			return
		}
		start_extract(st, false)
	}
}

open_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if st.items != nil {
			st.mode = .Browse
			return
		}
		quit(app)
		return
	}
	if p.key_pressed(ui, p.KEY_DOWN) {st.found_sel += 1}
	if p.key_pressed(ui, p.KEY_UP) {st.found_sel -= 1}
	st.found_sel = clamp(st.found_sel, 0, max(0, len(st.found) - 1))

	if p.key_pressed(ui, p.KEY_TAB) && len(st.found) > 0 {
		// Tab drops the highlighted file into the field, so it can be edited
		// rather than only accepted.
		clear(&st.edit)
		append(&st.edit, ..transmute([]u8)st.found[st.found_sel])
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		typed := strings.trim_space(string(st.edit[:]))
		if typed != "" {
			open_archive(st, strings.clone(typed, context.temp_allocator))
		} else if len(st.found) > 0 {
			open_archive(st, st.found[st.found_sel])
		}
		return
	}
	if p.key_pressed(ui, p.KEY_F5) {
		scan_for_archives(st)
		return
	}
	edit_buffer(ui, &st.edit)
}

create_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		st.mode = st.items != nil ? .Browse : .Open
		return
	}
	if p.key_pressed(ui, p.KEY_TAB) {
		commit_edit(st)
		st.edit_which = 1 - st.edit_which
		begin_edit(st, st.edit_which == 0 ? st.create_src : st.create_out)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		commit_edit(st)
		src := strings.trim_space(st.create_src)
		out := strings.trim_space(st.create_out)
		if src == "" || out == "" {
			return
		}
		if !os.exists(src) {
			st.result_ok = false
			st.result = fmt.aprintf("%s does not exist", src)
			st.mode = .Done
			return
		}
		if os.exists(out) {
			st.result_ok = false
			st.result = fmt.aprintf("%s already exists — choose another name", out)
			st.mode = .Done
			return
		}
		st.busy_label = "Creating the archive"
		job_start(Job{kind = .Create, src = strings.clone(src), out = strings.clone(out)})
		st.mode = .Browse
		return
	}
	edit_buffer(ui, &st.edit)
}

commit_edit :: proc(st: ^St) {
	text := strings.trim_space(string(st.edit[:]))
	if st.edit_which == 0 {
		delete(st.create_src)
		st.create_src = strings.clone(text)
	} else {
		delete(st.create_out)
		st.create_out = strings.clone(text)
	}
}

begin_edit :: proc(st: ^St, initial: string) {
	clear(&st.edit)
	append(&st.edit, ..transmute([]u8)initial)
}

edit_keys :: proc(ui: ^p.Ctx, st: ^St, commit: proc(st: ^St, text: string)) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		st.mode = .Browse
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		commit(st, string(st.edit[:]))
		return
	}
	edit_buffer(ui, &st.edit)
}

// edit_buffer is the one text field this app has, reused by every pane.
edit_buffer :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8) {
	if typed := p.typed_text(ui); len(typed) > 0 {
		append(buf, ..transmute([]u8)typed)
	}
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			if k.sym == 'u' {
				clear(buf)
			}
			if k.sym == 'w' {
				i := len(buf)
				for i > 0 && buf[i - 1] == '/' {i -= 1}
				for i > 0 && buf[i - 1] != '/' {i -= 1}
				resize(buf, i)
			}
			continue
		}
		if k.sym == p.KEY_BACKSPACE && len(buf) > 0 {
			n := 1
			for n < len(buf) && buf[len(buf) - n] & 0xc0 == 0x80 {n += 1}
			resize(buf, len(buf) - n)
		}
	}
}

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	if st.toast != "" {
		delete(st.toast)
	}
	st.toast = strings.clone(msg)
	st.toast_t = ui.now + 4
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	st.vis = max(1, int((size.y - 56 - 38 - 34 - 16) / ROW_H))
	keep_visible(st)

	header(ui, st)
	crumbs(ui, st)

	p.row(ui, "w-full flex-1 min-h-0")
	list_pane(ui, st)
	side_pane(ui, st)
	p.end(ui)

	footer(ui, st)

	if job_busy() {
		busy_overlay(ui, st)
	} else {
		switch st.mode {
		case .Browse:
		case .Open:
			open_overlay(ui, st)
		case .Dest:
			field_overlay(ui, st, "Extract to", "The directory everything is written into. It is created if it does not exist.")
		case .Create:
			create_overlay(ui, st)
		case .Confirm:
			confirm_overlay(ui, st)
		case .Done:
			done_overlay(ui, st)
		}
	}
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_FOLDER_ARCHIVE, "size-4 text-foreground")
	p.end(ui)

	if st.archive == "" {
		p.text(ui, "No archive open", "text-sm font-semibold whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		if !st.have_tar {
			sc.badge(ui, "bsdtar missing", .Destructive)
		}
		return
	}

	_, base := split_parent(st.archive)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, base, "text-sm font-semibold whitespace-nowrap truncate")
	p.text(ui, st.archive, "text-[11] text-muted-foreground whitespace-nowrap truncate")
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	sc.badge(ui, archive_label(st.archive), .Secondary)
	if st.items != nil {
		files, dirs, bad := 0, 0, 0
		total := i64(0)
		for it in st.items {
			if it.dir {dirs += 1} else {files += 1; total += it.size}
			if it.bad {bad += 1}
		}
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap",
			"%d files · %d folders · %s uncompressed",
			files,
			dirs,
			human(total),
		)
		p.style(ui).shrink = 0
		if bad > 0 {
			sc.badge_icon(ui, fmt.tprintf("%d unsafe", bad), IC_SHIELD_ALERT, .Destructive)
		}
	}
	p.end(ui)
}

crumbs :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[38] shrink-0 items-center gap-1 px-3 border-b border-border overflow-hidden")
	defer p.end(ui)

	if st.filtering {
		p.icon(ui, IC_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
		t := filter_text(st)
		p.text(
			ui,
			t == "" ? "Type to search every path in the archive…" : t,
			t == "" \
			? "text-xs text-muted-foreground whitespace-nowrap" \
			: "text-xs whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		p.spacer(ui)
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d matches", len(st.rows))
		p.style(ui).shrink = 0
		return
	}

	crumb(ui, st, "", st.archive == "" ? "—" : strip_archive_ext(st.archive))
	acc := ""
	rest := st.cwd
	for rest != "" {
		i := strings.index_byte(rest, '/')
		if i < 0 {
			break
		}
		seg := rest[:i]
		acc = fmt.tprintf("%s%s/", acc, seg)
		p.icon(ui, IC_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground")
		crumb(ui, st, strings.clone(acc, context.temp_allocator), seg)
		rest = rest[i + 1:]
	}

	p.spacer(ui)
	if n := marked_count(st); n > 0 {
		sc.badge(ui, fmt.tprintf("%d marked", n), .Default)
	}
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.text(ui, "Search", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "/")
	p.end(ui)
}

crumb :: proc(ui: ^p.Ctx, st: ^St, path, label: string) {
	on := path == st.cwd
	p.key(ui, label)
	idx := p.row(ui, "shrink-0 h-6 items-center px-2 rounded-md transition")
	p.apply(ui, on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		delete_cwd(st)
		st.cwd = strings.clone(path)
		st.sel = 0
		st.top = 0
	}
	defer p.end(ui)
	p.text(ui, label, "text-xs font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
}

list_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 min-w-0 min-h-0 p-2 gap-0 overflow-hidden relative")
	defer p.end(ui)

	if st.items == nil {
		centred(ui, IC_FOLDER_ARCHIVE, "No archive open", "Press o to choose one, or n to build a new archive from a directory")
		return
	}
	if len(st.rows) == 0 {
		centred(ui, IC_SEARCH, "Nothing here", st.filtering ? "No path in the archive matches" : "This folder is empty")
		return
	}

	last := min(st.top + st.vis, len(st.rows))
	for i in st.top ..< last {
		p.key(ui, st.rows[i].name)
		row(ui, st, st.rows[i], i == st.sel)
	}

	if len(st.rows) > st.vis {
		track := f32(st.vis) * ROW_H - 8
		th := max(24, track * f32(st.vis) / f32(len(st.rows)))
		frac := f32(st.top) / f32(max(1, len(st.rows) - st.vis))
		bar := p.div(ui, "absolute w-[3] rounded-full bg-border")
		bs := p.style(ui, bar)
		bs.position = .Absolute
		bs.inset[p.RIGHT] = p.px(2)
		bs.inset[p.TOP] = p.px(4 + (track - th) * frac)
		bs.h = p.px(th)
		p.end(ui)
	}
}

row :: proc(ui: ^p.Ctx, st: ^St, r: Row, sel: bool) {
	idx := p.row(ui, "w-full shrink-0 h-[34] items-center gap-3 px-2 rounded-md transition overflow-hidden")
	p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		for row2, i in st.rows {
			if row2.name == r.name {
				st.sel = i
				break
			}
		}
	}
	defer p.end(ui)

	marked := st.marks[r.name]
	p.div(ui, "size-4 shrink-0 flex-row items-center justify-center rounded border transition")
	p.apply(ui, marked ? "bg-primary border-primary" : "border-border")
	if marked {
		p.icon(ui, IC_CHECK, "size-3 text-primary-foreground")
	}
	p.end(ui)

	p.icon(
		ui,
		r.bad ? IC_SHIELD_ALERT : r.dir ? IC_FOLDER : file_icon(r.label),
		r.bad ? "size-4 shrink-0 text-destructive" : "size-4 shrink-0 text-muted-foreground",
	)

	p.text(ui, r.label, "flex-1 min-w-0 text-sm whitespace-nowrap truncate")
	if r.bad {
		p.style(ui).fg = p.hex(0xff6467)
	}

	if r.bad {
		sc.badge(ui, "refused", .Destructive)
	}
	if r.dir {
		p.textf(ui, "w-[92] shrink-0 text-[11] text-muted-foreground text-center whitespace-nowrap", "%d items", r.count)
	} else {
		p.text(ui, human(r.size), "w-[92] shrink-0 text-[11] text-muted-foreground text-center whitespace-nowrap")
	}
	p.text(ui, r.date, "w-[110] shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
}

file_icon :: proc(name: string) -> p.Icon {
	low := strings.to_lower(name, context.temp_allocator)
	switch {
	case is_archive_path(low):
		return IC_FILE_ARCHIVE
	case strings.has_suffix(low, ".png"), strings.has_suffix(low, ".jpg"),
	     strings.has_suffix(low, ".jpeg"), strings.has_suffix(low, ".gif"),
	     strings.has_suffix(low, ".webp"):
		return IC_IMAGE
	case strings.has_suffix(low, ".md"), strings.has_suffix(low, ".txt"):
		return IC_FILE_TEXT
	case strings.has_suffix(low, ".odin"), strings.has_suffix(low, ".c"),
	     strings.has_suffix(low, ".go"), strings.has_suffix(low, ".rs"),
	     strings.has_suffix(low, ".py"), strings.has_suffix(low, ".ts"),
	     strings.has_suffix(low, ".js"):
		return IC_FILE_CODE
	}
	return IC_FILE
}

centred :: proc(ui: ^p.Ctx, ic: p.Icon, title, note: string) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)
	p.div(ui, "size-12 flex-row items-center justify-center rounded-full bg-muted ring-1 ring-border")
	p.icon(ui, ic, "size-5 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-sm font-medium")
	p.text(ui, note, "text-xs text-muted-foreground text-center")
}

// ---------------------------------------------------------------------------
// The side panel
// ---------------------------------------------------------------------------

side_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[340] shrink-0 h-full min-h-0 border-l border-border overflow-hidden")
	defer p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 p-4 gap-3 overflow-scroll")

	if r, ok := current(st); ok {
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, r.dir ? IC_FOLDER : file_icon(r.label), "size-4 shrink-0 text-muted-foreground")
		p.text(ui, r.label, "flex-1 text-sm font-semibold whitespace-nowrap truncate")
		p.end(ui)

		meta(ui, "Path", r.name)
		if r.dir {
			meta(ui, "Contents", fmt.tprintf("%d entries, %s", r.count, human(r.size)))
		} else {
			meta(ui, "Size", human(r.size))
		}
		if r.date != "" {
			meta(ui, "Modified", r.date)
		}
		if r.item >= 0 && st.items[r.item].perms != "" {
			meta(ui, "Mode", st.items[r.item].perms)
		}
		meta(ui, "Marked", st.marks[r.name] ? "yes" : "no")

		if r.bad {
			p.col(ui, "w-full shrink-0 gap-1 p-3 rounded-lg bg-destructive/10 ring-1 ring-destructive/40")
			p.row(ui, "items-center gap-2")
			p.icon(ui, IC_SHIELD_ALERT, "size-3.5 shrink-0 text-destructive")
			p.text(ui, "Will not be extracted", "text-xs font-semibold text-destructive whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
			p.text(ui, r.why, "text-[11] text-destructive/80")
			p.end(ui)
		}
	} else {
		p.text(ui, "Nothing selected", "text-xs text-muted-foreground")
	}

	p.end(ui)

	// Destination, always visible: extraction writes files, so where it writes
	// is not something to find in a dialog after pressing go.
	p.col(ui, "w-full shrink-0 gap-2 p-4 border-t border-border")
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_FOLDER_INPUT, "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		"Extract to",
		"text-[10] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	sc.kbd(ui, "d")
	p.end(ui)

	p.row(ui, "w-full h-9 items-center px-2.5 rounded-md bg-background ring-1 ring-border overflow-hidden")
	p.text(
		ui,
		st.dest == "" ? "(not set)" : st.dest,
		"text-[11] font-mono whitespace-nowrap truncate",
	)
	p.end(ui)

	p.row(ui, "w-full items-center gap-2 pt-1")
	p.icon(ui, IC_DOWNLOAD, "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		marked_count(st) > 0 \
		? fmt.tprintf("Extract %d marked entries", marked_count(st)) \
		: "Extract everything",
		"flex-1 text-xs whitespace-nowrap truncate",
	)
	sc.kbd(ui, "e")
	p.end(ui)
	p.end(ui)
}

meta :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full shrink-0 items-start gap-3")
	defer p.end(ui)
	p.text(ui, label, "w-[66] shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "flex-1 text-[11] font-mono truncate whitespace-nowrap")
}

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
		return
	}

	hint(ui, "Enter", "", "Open folder")
	hint(ui, "Backspace", "", "Up")
	hint(ui, "Space", "", "Mark")
	hint(ui, "a", "", "All")
	hint(ui, "e", "", "Extract")
	hint(ui, "d", "", "Destination")
	hint(ui, "o", "", "Open")
	hint(ui, "n", "", "New archive")
	p.spacer(ui)
	hint(ui, "Esc", "", "Quit")
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

// ---------------------------------------------------------------------------
// Overlays — palmy has no xdg_popup, so every dialog is drawn in the window
// ---------------------------------------------------------------------------

panel_open :: proc(ui: ^p.Ctx, w, h: f32) -> int {
	size := p.size(ui)
	p.div(ui, "absolute inset-0 bg-background/70 z-40")
	p.end(ui)

	idx := p.col(ui, "absolute z-50 gap-3 p-5 rounded-xl bg-popover ring-1 ring-border shadow-2xl")
	s := p.style(ui, idx)
	s.position = .Absolute
	s.inset[p.LEFT] = p.px(max(12, (size.x - w) * 0.5))
	s.inset[p.TOP] = p.px(max(12, (size.y - h) * 0.35))
	s.w = p.px(min(w, size.x - 24))
	return idx
}

panel_title :: proc(ui: ^p.Ctx, ic: p.Icon, title, note: string) {
	p.row(ui, "w-full items-center gap-2")
	p.div(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-lg bg-muted")
	p.icon(ui, ic, "size-4 text-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, title, "text-sm font-semibold whitespace-nowrap")
	if note != "" {
		p.text(ui, note, "text-[11] text-muted-foreground")
	}
	p.end(ui)
	p.end(ui)
}

text_field :: proc(ui: ^p.Ctx, label, value: string, active: bool) {
	p.col(ui, "w-full shrink-0 gap-1")
	defer p.end(ui)
	p.text(ui, label, "text-[10] font-medium uppercase tracking-wide text-muted-foreground whitespace-nowrap")
	p.row(ui, "w-full h-9 items-center px-2.5 rounded-md bg-background ring-1 transition overflow-hidden")
	p.apply(ui, active ? "ring-ring" : "ring-border")
	p.text(
		ui,
		value == "" ? "…" : value,
		"text-[12] font-mono whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)
}

field_overlay :: proc(ui: ^p.Ctx, st: ^St, title, note: string) {
	panel_open(ui, 560, 190)
	defer p.end(ui)
	panel_title(ui, IC_FOLDER_INPUT, title, note)
	text_field(ui, "Path", string(st.edit[:]), true)
	p.row(ui, "w-full items-center gap-3 pt-1")
	keyhint(ui, "Enter", "use this directory")
	keyhint(ui, "Ctrl U", "clear")
	keyhint(ui, "Ctrl W", "up one")
	p.spacer(ui)
	keyhint(ui, "Esc", "cancel")
	p.end(ui)
}

open_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, 640, 430)
	defer p.end(ui)
	panel_title(ui, IC_ARCHIVE, "Open an archive", "Type a path, or pick one of the archives found in Downloads, Desktop, home and /tmp")
	text_field(ui, "Path", string(st.edit[:]), true)

	p.col(ui, "w-full max-h-[220] gap-0.5 overflow-hidden")
	if len(st.found) == 0 {
		p.text(ui, "No archives found in the usual places", "text-xs text-muted-foreground")
	}
	lo := max(0, min(st.found_sel - 3, len(st.found) - 7))
	for i in lo ..< min(lo + 7, len(st.found)) {
		f := st.found[i]
		p.key(ui, f)
		idx := p.row(ui, "w-full h-8 shrink-0 items-center gap-2 px-2 rounded-md transition")
		p.apply(ui, i == st.found_sel ? "bg-accent" : "hover:bg-muted", idx)
		if p.clickable(ui, idx) {
			st.found_sel = i
		}
		p.icon(ui, IC_FILE_ARCHIVE, "size-3.5 shrink-0 text-muted-foreground")
		_, base := split_parent(f)
		p.text(ui, base, "text-xs whitespace-nowrap truncate")
		p.style(ui).shrink = 0
		p.spacer(ui)
		p.text(ui, archive_label(f), "text-[10] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-3 pt-1")
	keyhint(ui, "Up Down", "choose")
	keyhint(ui, "Tab", "edit that path")
	keyhint(ui, "Enter", "open")
	p.spacer(ui)
	keyhint(ui, "Esc", st.items != nil ? "back" : "quit")
	p.end(ui)
}

create_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, 620, 280)
	defer p.end(ui)
	panel_title(
		ui,
		IC_FOLDER_PLUS,
		"Create an archive",
		"bsdtar picks the format from the output extension: .zip, .tar.gz, .tar.xz, .tar.zst…",
	)
	text_field(
		ui,
		"Source directory",
		st.edit_which == 0 ? string(st.edit[:]) : st.create_src,
		st.edit_which == 0,
	)
	text_field(
		ui,
		"Output file",
		st.edit_which == 1 ? string(st.edit[:]) : st.create_out,
		st.edit_which == 1,
	)
	p.row(ui, "w-full items-center gap-3 pt-1")
	keyhint(ui, "Tab", "other field")
	keyhint(ui, "Enter", "create")
	p.spacer(ui)
	keyhint(ui, "Esc", "cancel")
	p.end(ui)
}

confirm_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, 600, 330)
	defer p.end(ui)
	panel_title(ui, IC_DOWNLOAD, "Extract", "Nothing is written until you confirm")

	line(ui, IC_FOLDER_INPUT, "Destination", st.dest)
	line(ui, IC_FILE, "Entries", fmt.tprintf("%d", len(st.stage)))
	if st.stage_hit > 0 {
		line(
			ui,
			IC_TRIANGLE_ALERT,
			"Already on disk",
			fmt.tprintf("%d files — kept unless you choose to overwrite", st.stage_hit),
		)
	}
	if st.stage_bad > 0 {
		line(
			ui,
			IC_SHIELD_ALERT,
			"Refused",
			fmt.tprintf("%d entries escape the destination or are symlinks", st.stage_bad),
		)
	}

	p.row(ui, "w-full items-center gap-3 pt-2 flex-wrap")
	keyhint(ui, "Enter", st.stage_hit > 0 ? "extract, keeping existing files" : "extract")
	if st.stage_hit > 0 {
		keyhint(ui, "o", "extract and overwrite")
	}
	keyhint(ui, "d", "change the destination")
	p.spacer(ui)
	keyhint(ui, "Esc", "cancel")
	p.end(ui)
}

line :: proc(ui: ^p.Ctx, ic: p.Icon, label, value: string) {
	p.row(ui, "w-full shrink-0 items-center gap-2 h-7")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "w-[120] shrink-0 text-xs text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "flex-1 text-xs font-mono whitespace-nowrap truncate")
}

busy_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, 520, 180)
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	// shadcn's spinner is drawn at rotation zero because the parity route
	// disables the animation; here it should actually turn, which palmy does
	// by handing `icon` a turn count.
	p.icon(ui, IC_LOADER_CIRCLE, "size-4 shrink-0 text-foreground", p.elapsed(ui))
	p.text(ui, st.busy_label == "" ? "Working" : st.busy_label, "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	done, total := job_progress()
	frac := total > 0 ? clamp(f32(done) / f32(total), 0, 1) : 0

	sc.progress_open(ui, "w-full")
	sc.progress_header(
		ui,
		total > 0 ? fmt.tprintf("%d of %d entries", done, total) : "Reading the archive",
		total > 0 ? fmt.tprintf("%.0f%%", frac * 100) : "…",
	)
	sc.progress_track(ui, frac * 100)
	sc.progress_end(ui)

	p.row(ui, "w-full items-center gap-3 pt-1")
	p.spacer(ui)
	keyhint(ui, "Esc", "stop after the current batch")
	p.end(ui)
}

done_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	panel_open(ui, 600, 190)
	defer p.end(ui)
	panel_title(
		ui,
		st.result_ok ? IC_CIRCLE_CHECK : IC_CIRCLE_ALERT,
		st.result_ok ? "Done" : "That did not work",
		"",
	)
	p.text(ui, st.result, st.result_ok ? "text-xs text-muted-foreground" : "text-xs text-destructive")
	p.row(ui, "w-full items-center gap-3 pt-1")
	p.spacer(ui)
	keyhint(ui, "Enter", "close")
	p.end(ui)
}

keyhint :: proc(ui: ^p.Ctx, keys, label: string) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)
	for part in strings.split(keys, " ", context.temp_allocator) {
		sc.kbd(ui, part)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}
