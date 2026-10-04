// Notes — a notebook for palmy.
//
// Notes are real Markdown files under ~/.local/share/palmy-notes: one file per
// note, titled by its first line, so the directory is browsable and editable
// with anything else. The editor soft-wraps (wrap.odin), the preview renders
// Markdown with palmy's text styling (md.odin), and the text itself sits in
// the same line-array buffer with an undo stack that the editor app uses.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

tfmt :: fmt.tprintf

HEADER_H :: 52
STATUS_H :: 26
LIST_W :: 330
AUTOSAVE_IDLE :: 1.2 // seconds of quiet before the note is written
ACCENT :: 0x2563eb

run_cmd :: proc(argv: []string) -> (string, bool) {
	return kit.run(argv, context.temp_allocator)
}

Pane :: enum {
	List,
	Editor,
}

Mode :: enum {
	Normal,
	Search,
	Rename,
	Confirm_Delete,
	Help,
}

Notes :: struct {
	dir:        string,
	all:        [dynamic]Note,
	vis:        [dynamic]int,
	sel:        int,
	pane:       Pane,
	mode:       Mode,
	query:      [dynamic]u8,
	rename:     [dynamic]u8,

	// the open note
	buf:        Buffer,
	open_path:  string,
	cur:        Pos,
	anchor:     Pos,
	has_sel:    bool,
	goal_x:     f32,
	rev:        int, // bumped on every edit, so the wrapper knows to redo
	wrap:       Wrapper,
	top:        int, // first visible visual row
	rows:       int,
	body_w:     f32,
	preview:    bool,

	sel_confirm: bool, // the delete dialog's highlighted button
	dirty_since: f64,
	pending:    bool,
	swallow:    bool,
	toast:      string,
	toast_at:   f64,
	now:        time.Time,
	tz:         i64,
	space_w:    f32,
	want_quit:  bool,
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

main :: proc() {
	for a in os.args[1:] {
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
	}

	app, err := kit.start(
		{
			title = "Notes",
			width = 1150,
			height = 760,
			min_width = 760,
			min_height = 460,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("notes: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.register_color("accent-blue", p.hex(ACCENT))

	nt := Notes{}
	nt.dir = store_dir()
	nt.tz = local_offset()
	nt.now = time.now()
	buf_init_empty(&nt.buf)

	reload(&nt)
	if len(nt.all) == 0 {
		seed(&nt)
		reload(&nt)
	}
	open_sel(&nt)

	for ui in p.frames(app) {
		nt.now = time.now()
		measure(ui, &nt)
		keys(ui, &nt, app)
		autosave(ui, &nt)
		frame(ui, &nt)
		if nt.want_quit {
			break
		}
	}
	// Never lose content on exit: whatever is pending is written before the
	// window goes away, whichever way the loop ended.
	flush(&nt)
	p.quit_app(app)
}

// seed writes a first note so the app is never a blank wall on first run.
seed :: proc(nt: ^Notes) {
	body := `# Welcome to Notes

Every note here is a real Markdown file in
**~/.local/share/palmy-notes**, named after its own first line. Open the
folder in a file browser and it reads like a list of titles.

## What works

- **Bold**, *emphasis* and ` + "`inline code`" + `
- Bullet lists, and Return keeps the list going
- [ ] task boxes, which tick when you write an x
- [x] like this one
- Numbered lists, quotes and rules

> Search runs over the body of every note, not just the titles.

` + "```" + `
code blocks are set in the mono face
` + "```" + `

---

## Keys

Tab moves between the list and the editor. F2 renames, F3 switches
between writing and reading, F4 makes a new note, Delete removes one.
Everything saves itself.
`
	path := unique_path(nt.dir, "welcome-to-notes", "")
	if werr := os.write_entire_file(path, transmute([]u8)body); werr != nil {
		fmt.eprintfln("notes: could not write %s", path)
	}
}

note :: proc(nt: ^Notes, msg: string) {
	delete(nt.toast)
	nt.toast = strings.clone(msg)
	nt.toast_at = 0
}

measure :: proc(ui: ^p.Ctx, nt: ^Notes) {
	win := p.size(ui)
	nt.space_w = p.text_width(ui.fonts, " ", BODY_SIZE, .Sans, .Regular)
	nt.body_w = max(200, win.x - LIST_W - 96)
	nt.rows = max(3, int((win.y - HEADER_H - STATUS_H - 108) / BODY_LH))
}

// ---------------------------------------------------------------------------
// The note list
// ---------------------------------------------------------------------------

reload :: proc(nt: ^Notes) {
	for n in nt.all {
		note_free(n)
	}
	clear(&nt.all)
	nt.all = store_load(nt.dir)
	refilter(nt)
}

refilter :: proc(nt: ^Notes) {
	clear(&nt.vis)
	q := string(nt.query[:])
	for n, i in nt.all {
		if q == "" || contains_fold(n.title, q) || contains_fold(n.body, q) {
			append(&nt.vis, i)
		}
	}
	nt.sel = clamp(nt.sel, 0, max(0, len(nt.vis) - 1))
}

selected :: proc(nt: ^Notes) -> (Note, bool) {
	if nt.sel < 0 || nt.sel >= len(nt.vis) {
		return Note{}, false
	}
	return nt.all[nt.vis[nt.sel]], true
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
	flush(nt)
	delete(nt.open_path)
	nt.open_path = strings.clone(n.path)
	buf_load(&nt.buf, n.path)
	nt.cur = {0, 0}
	nt.anchor = {0, 0}
	nt.has_sel = false
	nt.top = 0
	nt.rev += 1
	nt.pending = false
}

// flush writes the open note if it has unsaved edits.
flush :: proc(nt: ^Notes) {
	if !nt.pending || nt.open_path == "" {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< buf_lines(&nt.buf) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(&nt.buf, i))
	}
	body := strings.to_string(sb)

	// The file is renamed when the title changes, so the list entry has to be
	// found by the path it had *before* the write, not after.
	was := strings.clone(nt.open_path, context.temp_allocator)
	new_path, ok := store_write(nt.dir, nt.open_path, body)
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
	// text without re-reading the whole directory on every save.
	at := -1
	for n, i in nt.all {
		if n.path == was {
			at = i
			break
		}
	}
	if at < 0 {
		append(&nt.all, Note{path = strings.clone(nt.open_path)})
		at = len(nt.all) - 1
	}
	n := &nt.all[at]
	delete(n.body)
	delete(n.title)
	delete(n.preview)
	delete(n.path)
	n.path = strings.clone(nt.open_path)
	n.body = strings.clone(body)
	n.title = title_of(n.body)
	n.preview = preview_of(n.body, n.title)
	n.mtime = time.now()
	n.words = word_count(body)
	n.bytes = len(body)

	refilter(nt)
}

touch :: proc(ui: ^p.Ctx, nt: ^Notes) {
	nt.pending = true
	nt.dirty_since = f64(p.elapsed(ui))
	nt.rev += 1
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

create :: proc(nt: ^Notes) {
	flush(nt)
	path, ok := store_create(nt.dir)
	if !ok {
		note(nt, "Could not create a note")
		return
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
	note(nt, "New note")
}

destroy_selected :: proc(nt: ^Notes) {
	n, ok := selected(nt)
	if !ok {
		return
	}
	title := strings.clone(n.title, context.temp_allocator)
	was_open := n.path == nt.open_path
	if !store_delete(n.path) {
		note(nt, "Could not delete that note")
		return
	}
	if was_open {
		nt.pending = false
		delete(nt.open_path)
		nt.open_path = ""
	}
	reload(nt)
	nt.sel = clamp(nt.sel, 0, max(0, len(nt.vis) - 1))
	if len(nt.vis) > 0 {
		open_sel(nt)
	} else {
		buf_init_empty(&nt.buf)
		nt.rev += 1
	}
	note(nt, tfmt("Deleted \"%s\"", title))
}

// apply_rename rewrites the note's first line, which is its title.
apply_rename :: proc(nt: ^Notes) {
	want := strings.trim_space(string(nt.rename[:]))
	if want == "" {
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
	nt.cur = buf_apply(
		&nt.buf,
		{0, 0},
		{0, len(first)},
		tfmt("%s%s", keep, want),
		nt.cur,
		.No,
	)
	nt.has_sel = false
	nt.anchor = nt.cur
	nt.pending = true
	nt.rev += 1
	flush(nt)
	note(nt, tfmt("Renamed to \"%s\"", want))
}
