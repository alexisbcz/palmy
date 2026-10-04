// Editor — a text editor for palmy.
//
// The buffer is a line array (see buffer.odin), the Odin highlighter is a real
// tokeniser (lex.odin), and everything the app can do is reachable from the
// keyboard. Escape opens a command palette, which is both the discoverable way
// in and the only way a recording harness — which cannot hold a modifier down —
// can drive an application whose unmodified keys all mean "type that".
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

tfmt :: fmt.tprintf

TITLE_H :: 46
STATUS_H :: 26
FOOT_H :: 34
FONT_SIZE :: 13
LINE_H :: 19
TAB_W :: 4
GUTTER_PAD :: 22

MONO :: "font-mono text-[13] leading-[19] whitespace-nowrap shrink-0"
SELECTION :: 0x2563eb

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

Mode :: enum {
	Edit,
	Palette,
	Prompt,
	Confirm_Quit,
	Help,
}

Prompt_Kind :: enum {
	None,
	Find,
	Replace,
	Goto,
	Save_As,
}

Field :: enum {
	Primary,
	Secondary,
}

Editor :: struct {
	buf:        Buffer,
	cur:        Pos,
	anchor:     Pos,
	has_sel:    bool,
	// The column vertical motion aims for, measured in display cells from the
	// start of the caret's *visual* row. With wrap off a row starts at cell 0,
	// so this is the plain display column and nothing changes.
	goal:       int,
	top:        int,
	left:       int,
	rows:       int,
	cols:       int,
	cw:         f32,
	gutter:     f32,
	numbers:    bool,
	syntax:     bool,
	lang:       Lang, // picked from the file name, or cycled by hand
	stats:      bool,

	// Soft wrap. The top of the window is a logical line plus a sub-row
	// inside it, because a file too long to wrap is a file too long to count
	// the visual rows of. `vis` is the rows on screen, rebuilt once a frame so
	// the gutter and the text iterate the same list; `scratch` is the one
	// reusable buffer `wrap_count` wraps into.
	wrap:       bool,
	top_sub:    int,
	vis:        [dynamic]Vis,
	scratch:    [dynamic]Vis,

	// Every caret but the primary one, which stays in `cur`/`anchor` above.
	// See carets.odin. `type_run` is the undo group a run of multi-caret
	// typing is accumulating into, so that one Ctrl-Z takes back the word
	// rather than one letter in every place at once.
	extra:      [dynamic]Caret,
	type_run:   int,
	mode:       Mode,
	prompt:     Prompt_Kind,
	field:      Field,
	find:       [dynamic]u8,
	repl:       [dynamic]u8,
	target:     [dynamic]u8, // save-as path, goto line
	pal_filter: [dynamic]u8,
	pal_sel:    int,
	quit_sel:   int,
	swallow:    bool, // ignore typed text for one frame after a mode change
	toast:      string,
	toast_at:   f64,
	matches:    int,
	scroll_acc: f32,
	want_quit:  bool,

	// The shared Open/Save dialog, and what it was opened for. See pick.odin.
	pick:       kit.Pick,
	pick_use:   Pick_Use,
}

// ---------------------------------------------------------------------------
// Display columns
//
// A column on screen is not a byte: a tab jumps to the next multiple of
// TAB_W and a multi-byte rune is one cell. Every conversion goes through
// these two, so the caret, the selection and the horizontal scroll all agree.
// ---------------------------------------------------------------------------

disp_of :: proc(s: string, byte_col: int) -> int {
	col := 0
	i := 0
	for i < len(s) && i < byte_col {
		if s[i] == '\t' {
			col += TAB_W - col % TAB_W
			i += 1
			continue
		}
		col += 1
		i = rune_right(s, i)
	}
	return col
}

byte_of :: proc(s: string, dcol: int) -> int {
	col := 0
	i := 0
	for i < len(s) {
		if col >= dcol {
			return i
		}
		if s[i] == '\t' {
			col += TAB_W - col % TAB_W
			i += 1
			continue
		}
		col += 1
		i = rune_right(s, i)
	}
	return len(s)
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

main :: proc() {
	args := os.args[1:]
	// `--shots <dir>` renders the interface offscreen and writes PNGs, with
	// no window and no compositor. See shot.odin.
	for a, i in args {
		if a == "--shots" || strings.has_prefix(a, "--shots=") {
			dir := ""
			if eq := strings.index_byte(a, '='); eq > 0 {
				dir = a[eq + 1:]
			} else if i + 1 < len(args) {
				dir = args[i + 1]
			}
			if dir == "" {
				fmt.eprintln("editor --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(dir))
		}
	}
	path := ""
	for a in args {
		if a == "--bench" || a == "--selftest" {
			continue
		}
		if path == "" {
			path = a
		}
	}
	for a in args {
		if a == "--bench" {
			run_bench(path)
			return
		}
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
	}

	app, err := kit.start(
		{
			title = "Editor",
			width = 1180,
			height = 780,
			min_width = 720,
			min_height = 420,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("editor: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	p.register_color("selection", p.hex(SELECTION))

	ed := Editor {
		numbers = true,
		syntax  = true,
	}
	if path != "" {
		if !buf_load(&ed.buf, path) {
			// A path that does not exist yet is a new file, not an error.
			buf_init_empty(&ed.buf)
			ed.buf.path = strings.clone(path)
			note(&ed, tfmt("New file %s", base_of(path)))
		}
	} else {
		buf_init_empty(&ed.buf)
	}
	relang(&ed)
	retitle(app, &ed)

	defer kit.pick_destroy(&ed.pick)

	for ui in p.frames(app) {
		measure(ui, &ed)
		keys(ui, &ed, app)
		build_visible(&ed)
		frame(ui, &ed)
		retitle(app, &ed)
		if ed.want_quit {
			p.quit_app(app)
		}
	}
}

@(private = "file")
shown_title: string

retitle :: proc(app: ^p.App, ed: ^Editor) {
	name := ed.buf.path == "" ? "Untitled" : base_of(ed.buf.path)
	t := tfmt("%s%s — Editor", buf_dirty(&ed.buf) ? "• " : "", name)
	if t != shown_title {
		delete(shown_title)
		shown_title = strings.clone(t)
		p.set_title(app, shown_title)
	}
}

base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	return ""
}

// relang re-detects the language and throws away the highlighter's per-line
// state cache, which was computed under the old grammar.
relang :: proc(ed: ^Editor) {
	ed.lang = lang_detect(ed.buf.path, buf_line(&ed.buf, 0))
	ed.buf.valid = 0
	clear(&ed.extra)
	ed.type_run = 0
}

note :: proc(ed: ^Editor, msg: string) {
	delete(ed.toast)
	ed.toast = strings.clone(msg)
	ed.toast_at = 0
}

measure :: proc(ui: ^p.Ctx, ed: ^Editor) {
	win := p.size(ui)
	ed.cw = p.text_width(ui.fonts, "0", FONT_SIZE, .Mono, .Regular)
	if ed.cw <= 0 {
		ed.cw = 8
	}
	digits := 1
	for n := buf_lines(&ed.buf); n >= 10; n /= 10 {
		digits += 1
	}
	ed.gutter = ed.numbers ? f32(GUTTER_PAD) + f32(digits) * ed.cw : 10

	foot := ed.prompt != .None ? f32(FOOT_H) : 0
	body := win.y - TITLE_H - STATUS_H - foot
	ed.rows = max(1, int(body / LINE_H))
	ed.cols = max(8, int((win.x - ed.gutter - 16) / ed.cw))
	ed.top = clamp(ed.top, 0, max(0, buf_lines(&ed.buf) - 1))
	if ed.wrap {
		// Nothing is off the right edge any more, so there is nothing to
		// scroll to. Leaving `left` behind would shift every row.
		ed.left = 0
	}
}

// ---------------------------------------------------------------------------
// Selection helpers
// ---------------------------------------------------------------------------

sel_range :: proc(ed: ^Editor) -> (lo, hi: Pos, ok: bool) {
	if !ed.has_sel || pos_eq(ed.anchor, ed.cur) {
		return ed.cur, ed.cur, false
	}
	lo, hi = pos_order(ed.anchor, ed.cur)
	return lo, hi, true
}

clear_sel :: proc(ed: ^Editor) {
	ed.has_sel = false
	ed.anchor = ed.cur
}

// begin_sel is called before a motion: with Shift held the anchor stays put,
// without it the selection collapses.
begin_sel :: proc(ed: ^Editor, shift: bool) {
	if shift {
		if !ed.has_sel {
			ed.anchor = ed.cur
			ed.has_sel = true
		}
	} else {
		clear_sel(ed)
	}
}

// delete_sel removes the selection if there is one and returns true.
delete_sel :: proc(ed: ^Editor) -> bool {
	lo, hi, ok := sel_range(ed)
	if !ok {
		return false
	}
	ed.cur = buf_apply(&ed.buf, lo, hi, "", ed.cur, .No)
	clear_sel(ed)
	return true
}

insert :: proc(ed: ^Editor, text: string, coalesce := Coalesce.No) {
	lo, hi, ok := sel_range(ed)
	if ok {
		ed.cur = buf_apply(&ed.buf, lo, hi, text, ed.cur, .No)
	} else {
		ed.cur = buf_apply(&ed.buf, ed.cur, ed.cur, text, ed.cur, coalesce)
	}
	clear_sel(ed)
	goal_set(ed)
}

// goal_set records where vertical motion should aim, in cells from the start
// of the caret's visual row.
goal_set :: proc(ed: ^Editor) {
	_, dx := caret_vis(ed, ed.cur)
	ed.goal = dx
}

// move_vert moves the caret `d` **visual** rows, keeping the goal column. With
// wrap off a visual row is a logical line and this is the ordinary Up/Down; with
// wrap on, down-then-up returns to the same place because both directions go
// through the same pair of conversions.
move_vert :: proc(ed: ^Editor, d: int) {
	sub, _ := caret_vis(ed, ed.cur)
	nl, ns := vis_advance(ed, ed.cur.line, sub, d)
	if nl == ed.cur.line && ns == sub {
		return
	}
	ed.cur = col_at(ed, nl, ns, ed.goal)
}

ensure_visible :: proc(ed: ^Editor) {
	ed.cur = pos_clamp(&ed.buf, ed.cur)
	ed.top = clamp(ed.top, 0, max(0, buf_lines(&ed.buf) - 1))

	sub, dx := caret_vis(ed, ed.cur)
	if vis_before(ed.cur.line, sub, ed.top, ed.top_sub) {
		ed.top, ed.top_sub = ed.cur.line, sub
	} else if vis_gap(ed, ed.top, ed.top_sub, ed.cur.line, sub, ed.rows) >= ed.rows {
		ed.top, ed.top_sub = vis_advance(ed, ed.cur.line, sub, -(ed.rows - 1))
	}

	if ed.wrap {
		ed.left = 0
		return
	}
	if dx < ed.left {
		ed.left = dx
	}
	if dx >= ed.left + ed.cols - 1 {
		ed.left = dx - ed.cols + 2
	}
	ed.left = max(0, ed.left)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

Cmd :: enum {
	None,
	Open,
	Save,
	Save_As,
	Find,
	Find_Next,
	Find_Prev,
	Replace,
	Goto_Line,
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
	Dup_Line,
	Del_Line,
	Top,
	Bottom,
	Toggle_Numbers,
	Toggle_Syntax,
	Toggle_Wrap,
	Toggle_Stats,
	Match_Bracket,
	Select_Bracket,
	Cycle_Lang,
	Cursor_Below,
	Cursor_Above,
	Cursor_Next,
	Cursor_All,
	Cursor_One,
	Reload,
	Help,
	Quit,
}

Command :: struct {
	cmd:   Cmd,
	label: string,
	keys:  string,
	icon:  p.Icon,
}

COMMANDS := [?]Command {
	{.Open, "Open…", "Ctrl O", ICON_FOLDER},
	{.Save, "Save", "Ctrl S", ICON_SAVE},
	{.Save_As, "Save As…", "Ctrl Shift S", ICON_SAVE},
	{.Find, "Find…", "Ctrl F", ICON_SEARCH},
	{.Find_Next, "Find Next", "F3", ICON_ARROW_DOWN},
	{.Find_Prev, "Find Previous", "Shift F3", ICON_ARROW_UP},
	{.Replace, "Find and Replace…", "Ctrl H", ICON_REPLACE},
	{.Goto_Line, "Go to Line…", "Ctrl L", ICON_HASH},
	{.Undo, "Undo", "Ctrl Z", ICON_UNDO_2},
	{.Redo, "Redo", "Ctrl Y", ICON_REDO_2},
	{.Cut, "Cut", "Ctrl X", ICON_SCISSORS},
	{.Copy, "Copy", "Ctrl C", ICON_COPY},
	{.Paste, "Paste", "Ctrl V", ICON_CLIPBOARD_PASTE},
	{.Select_All, "Select All", "Ctrl A", ICON_TYPE},
	{.Dup_Line, "Duplicate Line", "Ctrl D", ICON_COPY},
	{.Del_Line, "Delete Line", "Ctrl K", ICON_TRASH},
	{.Top, "Go to Start of File", "Ctrl Home", ICON_ARROW_UP},
	{.Bottom, "Go to End of File", "Ctrl End", ICON_ARROW_DOWN},
	{.Cursor_Below, "Add Cursor Below", "Ctrl Alt Down", ICON_ARROW_DOWN},
	{.Cursor_Above, "Add Cursor Above", "Ctrl Alt Up", ICON_ARROW_UP},
	{.Cursor_Next, "Add Cursor at Next Match", "Ctrl Shift D", ICON_SQUARE_PEN},
	{.Cursor_All, "Add Cursor at Every Match", "Ctrl Shift L", ICON_SQUARE_PEN},
	{.Cursor_One, "Back to One Cursor", "Esc", ICON_DOT},
	{.Match_Bracket, "Go to Matching Bracket", "Ctrl M", ICON_BRACES},
	{.Select_Bracket, "Select to Matching Bracket", "Ctrl Shift M", ICON_BRACES},
	{.Toggle_Wrap, "Toggle Soft Wrap", "Alt Z", ICON_CORNER_DOWN_LEFT},
	{.Cycle_Lang, "Change Language", "Ctrl G", ICON_CODE},
	{.Toggle_Numbers, "Toggle Line Numbers", "", ICON_LIST_ORDERED},
	{.Toggle_Syntax, "Toggle Syntax Highlighting", "", ICON_CODE},
	{.Toggle_Stats, "Toggle Frame Stats", "", ICON_SPARKLES},
	{.Reload, "Reload from Disk", "F5", ICON_ARROW_UP_DOWN},
	{.Help, "Keyboard Shortcuts", "F1", ICON_KEYBOARD},
	{.Quit, "Quit", "Ctrl Q", ICON_X},
}

open_prompt :: proc(ed: ^Editor, kind: Prompt_Kind) {
	ed.mode = .Prompt
	ed.prompt = kind
	ed.field = .Primary
	ed.swallow = true
	if kind == .Save_As {
		clear(&ed.target)
		append(&ed.target, ..transmute([]u8)ed.buf.path)
	}
	if kind == .Goto {
		clear(&ed.target)
	}
}

do_save :: proc(ed: ^Editor, path: string) {
	if path == "" {
		// Nowhere to write it yet, so ask — through the file dialog now,
		// rather than making the user type a path from memory.
		begin_pick(ed, .Save_As)
		note(ed, "This buffer has no name yet")
		return
	}
	if buf_save(&ed.buf, path) {
		note(ed, tfmt("Saved %s, %d lines", base_of(path), buf_lines(&ed.buf)))
	} else {
		note(ed, tfmt("Could not write %s", path))
	}
}

do_copy :: proc(ed: ^Editor) {
	if carets_multi(ed) {
		// One line per caret, in document order — which is what pasting it
		// back into the same carets would need.
		text := carets_text(ed)
		if kit.clipboard_set(text) {
			note(ed, tfmt("Copied %d cursors", carets_count(ed)))
		} else {
			note(ed, "wl-copy is not installed")
		}
		return
	}
	lo, hi, ok := sel_range(ed)
	if !ok {
		// No selection: copy the whole line, which is what every editor does.
		lo = Pos{ed.cur.line, 0}
		hi = Pos{ed.cur.line, len(buf_line(&ed.buf, ed.cur.line))}
	}
	text := buf_text(&ed.buf, lo, hi, context.temp_allocator)
	if kit.clipboard_set(text) {
		note(ed, tfmt("Copied %d bytes", len(text)))
	} else {
		note(ed, "wl-copy is not installed")
	}
}

do_find_step :: proc(ed: ^Editor, backwards: bool) {
	needle := string(ed.find[:])
	if needle == "" {
		open_prompt(ed, .Find)
		return
	}
	from := ed.cur
	if !backwards {
		from.col += 1
	}
	at, ok := buf_search(&ed.buf, needle, pos_clamp(&ed.buf, from), true, backwards)
	if !ok {
		note(ed, tfmt("No match for \"%s\"", needle))
		return
	}
	ed.cur = at
	ed.anchor = Pos{at.line, at.col + len(needle)}
	ed.has_sel = true
	goal_set(ed)
	ensure_visible(ed)
}

run_cmd :: proc(ed: ^Editor, c: Cmd) {
	// Anything that moves the caret somewhere definite, replaces the buffer,
	// or rewinds history has one answer, not N. Those collapse to one cursor
	// rather than doing something arbitrary with the rest.
	#partial switch c {
	case .Undo, .Redo, .Select_All, .Goto_Line, .Reload, .Open, .Save_As, .Find,
	     .Find_Next, .Find_Prev, .Replace, .Top, .Bottom, .Match_Bracket, .Select_Bracket:
		clear(&ed.extra)
		ed.type_run = 0
	}
	switch c {
	case .None:
	case .Open:
		begin_pick(ed, .Open)
	case .Save:
		do_save(ed, ed.buf.path)
	case .Save_As:
		begin_pick(ed, .Save_As)
	case .Find:
		open_prompt(ed, .Find)
	case .Replace:
		open_prompt(ed, .Replace)
	case .Goto_Line:
		open_prompt(ed, .Goto)
	case .Find_Next:
		do_find_step(ed, false)
	case .Find_Prev:
		do_find_step(ed, true)
	case .Undo:
		if cur, ok := buf_undo(&ed.buf); ok {
			ed.cur = cur
			clear_sel(ed)
			ensure_visible(ed)
			note(ed, "Undo")
		} else {
			note(ed, "Nothing left to undo")
		}
	case .Redo:
		if cur, ok := buf_redo(&ed.buf); ok {
			ed.cur = cur
			clear_sel(ed)
			ensure_visible(ed)
			note(ed, "Redo")
		} else {
			note(ed, "Nothing left to redo")
		}
	case .Copy:
		do_copy(ed)
	case .Cut:
		do_copy(ed)
		if !delete_sel(ed) {
			run_cmd(ed, .Del_Line)
		}
		ensure_visible(ed)
	case .Paste:
		text, ok := kit.clipboard_get(context.temp_allocator)
		if !ok {
			note(ed, "wl-paste is not installed")
			break
		}
		insert(ed, text)
		ensure_visible(ed)
	case .Select_All:
		ed.anchor = Pos{0, 0}
		ed.cur = buf_end(&ed.buf)
		ed.has_sel = true
		ensure_visible(ed)
	case .Dup_Line:
		l := buf_line(&ed.buf, ed.cur.line)
		at := Pos{ed.cur.line, len(l)}
		ed.cur = buf_apply(&ed.buf, at, at, tfmt("\n%s", l), ed.cur, .No)
		ed.cur = Pos{ed.cur.line, min(ed.cur.col, len(buf_line(&ed.buf, ed.cur.line)))}
		clear_sel(ed)
		ensure_visible(ed)
	case .Del_Line:
		li := ed.cur.line
		from := Pos{li, 0}
		to := li + 1 < buf_lines(&ed.buf) ? Pos{li + 1, 0} : Pos{li, len(buf_line(&ed.buf, li))}
		ed.cur = buf_apply(&ed.buf, from, to, "", ed.cur, .No)
		clear_sel(ed)
		ensure_visible(ed)
	case .Top:
		ed.cur = Pos{0, 0}
		clear_sel(ed)
		ensure_visible(ed)
	case .Bottom:
		ed.cur = buf_end(&ed.buf)
		clear_sel(ed)
		ensure_visible(ed)
	case .Toggle_Numbers:
		ed.numbers = !ed.numbers
	case .Toggle_Syntax:
		ed.syntax = !ed.syntax
	case .Toggle_Wrap:
		ed.wrap = !ed.wrap
		// The caret keeps its place; the goal column is now measured from a
		// different row start, so it has to be taken again.
		ed.top_sub = 0
		ed.left = 0
		goal_set(ed)
		ensure_visible(ed)
		note(ed, ed.wrap ? "Soft wrap on" : "Soft wrap off")
	case .Toggle_Stats:
		ed.stats = !ed.stats
	case .Match_Bracket:
		at, m, ok := bracket_pair_at_caret(ed)
		if !ok {
			note(ed, "No matching bracket here")
			break
		}
		_ = at
		ed.cur = m
		clear_sel(ed)
		goal_set(ed)
		ensure_visible(ed)
	case .Select_Bracket:
		at, m, ok := bracket_pair_at_caret(ed)
		if !ok {
			note(ed, "No matching bracket here")
			break
		}
		lo, hi := pos_order(at, m)
		ed.anchor = lo
		ed.cur = Pos{hi.line, hi.col + 1}
		ed.has_sel = true
		goal_set(ed)
		ensure_visible(ed)
	case .Cycle_Lang:
		ed.lang = Lang((int(ed.lang) + 1) % (int(max(Lang)) + 1))
		ed.buf.valid = 0
		note(ed, tfmt("Language: %s", lang_name(ed.lang)))
	case .Cursor_Below:
		caret_add_vert(ed, 1)
	case .Cursor_Above:
		caret_add_vert(ed, -1)
	case .Cursor_Next:
		caret_add_next(ed)
	case .Cursor_All:
		caret_add_all(ed)
	case .Cursor_One:
		carets_collapse(ed)
	case .Reload:
		if ed.buf.path == "" {
			note(ed, "Nothing to reload")
			break
		}
		path := strings.clone(ed.buf.path, context.temp_allocator)
		buf_load(&ed.buf, path)
		ed.cur = {0, 0}
		ed.top, ed.left, ed.top_sub = 0, 0, 0
		relang(ed)
		clear_sel(ed)
		note(ed, tfmt("Reloaded %s", base_of(path)))
	case .Help:
		ed.mode = ed.mode == .Help ? .Edit : .Help
		ed.swallow = true
	case .Quit:
		if buf_dirty(&ed.buf) {
			ed.mode = .Confirm_Quit
			ed.quit_sel = 0
			ed.swallow = true
		} else {
			ed.want_quit = true
		}
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

plain :: proc(ui: ^p.Ctx, sym: u32, repeat := false) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && (repeat || !k.repeat) && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

// held reports the modifiers that were down for a key this frame.
held :: proc(ui: ^p.Ctx, sym: u32) -> (times: int, shift: bool, ctrl: bool) {
	for k in ui.input.keys {
		if k.sym == sym {
			times += 1
			shift |= .Shift in k.mods
			ctrl |= .Ctrl in k.mods
		}
	}
	return
}

// field_edit is the one-line editing shared by the prompt and the palette.
field_edit :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8, swallow: bool) -> bool {
	changed := false
	if !swallow {
		for b in transmute([]u8)p.typed_text(ui) {
			if b >= 0x20 && b != 0x7f {
				append(buf, b)
				changed = true
			}
		}
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_BACKSPACE) {
		if len(buf) > 0 {
			n := 1
			for n < len(buf) && buf[len(buf) - n] & 0xc0 == 0x80 {
				n += 1
			}
			resize(buf, len(buf) - n)
			changed = true
		}
	}
	if p.shortcut(ui, 'u', {.Ctrl}) && len(buf) > 0 {
		clear(buf)
		changed = true
	}
	return changed
}

keys :: proc(ui: ^p.Ctx, ed: ^Editor, app: ^p.App) {
	// The file dialog owns the keyboard while it is up, and it reads its own
	// input inside `pick_overlay` during the draw pass. Nothing here may
	// consume a key before it gets there.
	if kit.pick_active(&ed.pick) {
		return
	}

	swallow := ed.swallow
	ed.swallow = false

	switch ed.mode {
	case .Help:
		// The keystroke that opened this sheet can still be in flight — a
		// press and its release do not always land in the same frame — and
		// without the guard the Return that chose "Keyboard Shortcuts" in the
		// palette closes the sheet again before it has been seen. `swallow`
		// is set by whatever opened it and spends exactly one frame.
		if swallow {
			return
		}
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_F1) {
			ed.mode = .Edit
		}
		return

	case .Confirm_Quit:
		if swallow {
			return
		}
		if plain(ui, p.KEY_ESCAPE) {
			ed.mode = .Edit
			return
		}
		if n, _, _ := held(ui, p.KEY_RIGHT); n > 0 {
			ed.quit_sel = min(ed.quit_sel + n, 2)
		}
		if n, _, _ := held(ui, p.KEY_LEFT); n > 0 {
			ed.quit_sel = max(ed.quit_sel - n, 0)
		}
		if plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_SPACE) {
			switch ed.quit_sel {
			case 0:
				do_save(ed, ed.buf.path)
				if !buf_dirty(&ed.buf) {
					ed.want_quit = true
				}
				ed.mode = .Edit
			case 1:
				ed.want_quit = true
			case 2:
				ed.mode = .Edit
			}
		}
		return

	case .Palette:
		if plain(ui, p.KEY_ESCAPE) {
			ed.mode = .Edit
			return
		}
		items := palette_items(ed)
		if n, _, _ := held(ui, p.KEY_DOWN); n > 0 {
			ed.pal_sel = min(ed.pal_sel + n, max(0, len(items) - 1))
		}
		if n, _, _ := held(ui, p.KEY_UP); n > 0 {
			ed.pal_sel = max(ed.pal_sel - n, 0)
		}
		if plain(ui, p.KEY_RETURN) {
			ed.mode = .Edit
			if ed.pal_sel >= 0 && ed.pal_sel < len(items) {
				run_cmd(ed, items[ed.pal_sel].cmd)
			}
			return
		}
		if field_edit(ui, &ed.pal_filter, swallow) {
			ed.pal_sel = 0
		}
		return

	case .Prompt:
		prompt_keys(ui, ed, swallow)
		return

	case .Edit:
	}

	// ---- Commands -------------------------------------------------------
	// Escape has two jobs, and the more urgent one wins: with several cursors
	// up, it puts them away. Only then does it open the palette.
	if plain(ui, p.KEY_ESCAPE) && carets_multi(ed) {
		carets_collapse(ed)
		return
	}
	if p.shortcut(ui, p.KEY_ESCAPE, {.Shift}) && carets_multi(ed) {
		carets_collapse(ed)
		return
	}
	if plain(ui, p.KEY_ESCAPE) || p.shortcut(ui, 'p', {.Ctrl}) {
		ed.mode = .Palette
		ed.pal_sel = 0
		clear(&ed.pal_filter)
		ed.swallow = true
		return
	}
	if plain(ui, p.KEY_F1) {
		run_cmd(ed, .Help)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		run_cmd(ed, .Open)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		run_cmd(ed, .Save)
	}
	if p.shortcut(ui, 's', {.Ctrl, .Shift}) || p.shortcut(ui, 'S', {.Ctrl, .Shift}) {
		run_cmd(ed, .Save_As)
	}
	if p.shortcut(ui, 'f', {.Ctrl}) {
		run_cmd(ed, .Find)
		return
	}
	if p.shortcut(ui, 'h', {.Ctrl}) {
		run_cmd(ed, .Replace)
		return
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {
		run_cmd(ed, .Goto_Line)
		return
	}
	if p.shortcut(ui, 'z', {.Ctrl}) {
		run_cmd(ed, .Undo)
	}
	if p.shortcut(ui, 'y', {.Ctrl}) ||
	   p.shortcut(ui, 'z', {.Ctrl, .Shift}) ||
	   p.shortcut(ui, 'Z', {.Ctrl, .Shift}) {
		run_cmd(ed, .Redo)
	}
	if p.shortcut(ui, 'c', {.Ctrl}) {
		run_cmd(ed, .Copy)
	}
	if p.shortcut(ui, 'x', {.Ctrl}) {
		run_cmd(ed, .Cut)
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		run_cmd(ed, .Paste)
	}
	if p.shortcut(ui, 'a', {.Ctrl}) {
		run_cmd(ed, .Select_All)
	}
	if p.shortcut(ui, 'd', {.Ctrl}) {
		run_cmd(ed, .Dup_Line)
	}
	if p.shortcut(ui, 'k', {.Ctrl}) {
		run_cmd(ed, .Del_Line)
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		run_cmd(ed, .Quit)
		return
	}
	if p.shortcut(ui, 'z', {.Alt}) || p.shortcut(ui, 'Z', {.Alt}) {
		run_cmd(ed, .Toggle_Wrap)
		return
	}
	if p.shortcut(ui, 'm', {.Ctrl}) {
		run_cmd(ed, .Match_Bracket)
		return
	}
	if p.shortcut(ui, 'm', {.Ctrl, .Shift}) || p.shortcut(ui, 'M', {.Ctrl, .Shift}) {
		run_cmd(ed, .Select_Bracket)
		return
	}
	if p.shortcut(ui, 'g', {.Ctrl}) {
		run_cmd(ed, .Cycle_Lang)
		return
	}
	if p.shortcut(ui, p.KEY_DOWN, {.Ctrl, .Alt}) {
		run_cmd(ed, .Cursor_Below)
		return
	}
	if p.shortcut(ui, p.KEY_UP, {.Ctrl, .Alt}) {
		run_cmd(ed, .Cursor_Above)
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl, .Shift}) || p.shortcut(ui, 'D', {.Ctrl, .Shift}) {
		run_cmd(ed, .Cursor_Next)
		return
	}
	if p.shortcut(ui, 'l', {.Ctrl, .Shift}) || p.shortcut(ui, 'L', {.Ctrl, .Shift}) {
		run_cmd(ed, .Cursor_All)
		return
	}
	if plain(ui, p.KEY_F5) {
		run_cmd(ed, .Reload)
		return
	}
	if plain(ui, p.KEY_F3) {
		run_cmd(ed, .Find_Next)
	}
	if p.shortcut(ui, p.KEY_F3, {.Shift}) {
		run_cmd(ed, .Find_Prev)
	}

	// ---- The wheel ------------------------------------------------------
	if w := p.wheel(ui).y; w != 0 {
		ed.scroll_acc += w * 3
		step := int(ed.scroll_acc)
		if step != 0 {
			ed.scroll_acc -= f32(step)
			ed.top, ed.top_sub = vis_advance(ed, ed.top, ed.top_sub, -step)
		}
	}

	// ---- Motion ---------------------------------------------------------
	//
	// Horizontal motion rewrites the goal column; vertical motion keeps it, so
	// walking down past a short line and back up returns to the same column.
	// With several cursors up, motion and editing both go through the
	// multi-caret path and nothing falls through to the single-caret one —
	// otherwise a key it did not handle would move the primary caret and
	// leave the rest behind, which looks exactly like the editor losing them.
	if carets_multi(ed) {
		multi_motion(ui, ed)
		multi_edit(ui, ed, swallow)
		return
	}

	moved_h := false
	moved_v := false
	for k in ui.input.keys {
		shift := .Shift in k.mods
		ctrl := .Ctrl in k.mods
		if .Alt in k.mods || .Super in k.mods {
			continue
		}
		switch k.sym {
		case p.KEY_LEFT:
			begin_sel(ed, shift)
			if ctrl {
				ed.cur = word_left(&ed.buf, ed.cur)
			} else if ed.cur.col > 0 {
				ed.cur.col = rune_left(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
			} else if ed.cur.line > 0 {
				ed.cur = {ed.cur.line - 1, len(buf_line(&ed.buf, ed.cur.line - 1))}
			}
			moved_h = true
		case p.KEY_RIGHT:
			begin_sel(ed, shift)
			if ctrl {
				ed.cur = word_right(&ed.buf, ed.cur)
			} else {
				l := buf_line(&ed.buf, ed.cur.line)
				if ed.cur.col < len(l) {
					ed.cur.col = rune_right(l, ed.cur.col)
				} else if ed.cur.line + 1 < buf_lines(&ed.buf) {
					ed.cur = {ed.cur.line + 1, 0}
				}
			}
			moved_h = true
		case p.KEY_UP:
			begin_sel(ed, shift)
			move_vert(ed, -1)
			moved_v = true
		case p.KEY_DOWN:
			begin_sel(ed, shift)
			move_vert(ed, 1)
			moved_v = true
		case p.KEY_PAGE_UP:
			begin_sel(ed, shift)
			move_vert(ed, -ed.rows)
			ed.top, ed.top_sub = vis_advance(ed, ed.top, ed.top_sub, -ed.rows)
			moved_v = true
		case p.KEY_PAGE_DOWN:
			begin_sel(ed, shift)
			move_vert(ed, ed.rows)
			ed.top, ed.top_sub = vis_advance(ed, ed.top, ed.top_sub, ed.rows)
			moved_v = true
		case p.KEY_HOME:
			begin_sel(ed, shift)
			switch {
			case ctrl:
				ed.cur = {0, 0}
			case ed.wrap:
				// Wrapped, Home means the start of the visual row; on the
				// first row of a line that is still the first non-blank.
				sub, _ := caret_vis(ed, ed.cur)
				if sub > 0 {
					ed.cur = col_at(ed, ed.cur.line, sub, 0)
				} else {
					ed.cur.col = home_col(ed)
				}
			case:
				ed.cur.col = home_col(ed)
			}
			moved_h = true
		case p.KEY_END:
			begin_sel(ed, shift)
			switch {
			case ctrl:
				ed.cur = buf_end(&ed.buf)
			case ed.wrap:
				sub, _ := caret_vis(ed, ed.cur)
				ed.cur = col_at(ed, ed.cur.line, sub, max(int))
			case:
				ed.cur.col = len(buf_line(&ed.buf, ed.cur.line))
			}
			moved_h = true
		}
	}
	if moved_h || moved_v {
		ed.cur = pos_clamp(&ed.buf, ed.cur)
		if moved_h {
			goal_set(ed)
		}
		ensure_visible(ed)
	}

	// ---- Editing --------------------------------------------------------
	for _ in 0 ..< p.key_count(ui, p.KEY_BACKSPACE) {
		if delete_sel(ed) {
			continue
		}
		// The pair appeared in one keystroke, so it goes in one keystroke.
		if backspace_pair(ed) {
			ensure_visible(ed)
			continue
		}
		if ed.cur.col > 0 {
			l := buf_line(&ed.buf, ed.cur.line)
			from := Pos{ed.cur.line, rune_left(l, ed.cur.col)}
			ed.cur = buf_apply(&ed.buf, from, ed.cur, "", ed.cur, .Back)
		} else if ed.cur.line > 0 {
			prev := len(buf_line(&ed.buf, ed.cur.line - 1))
			ed.cur = buf_apply(
				&ed.buf,
				{ed.cur.line - 1, prev},
				ed.cur,
				"",
				ed.cur,
				.Back,
			)
		}
		goal_set(ed)
		ensure_visible(ed)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_DELETE) {
		if delete_sel(ed) {
			continue
		}
		l := buf_line(&ed.buf, ed.cur.line)
		if ed.cur.col < len(l) {
			to := Pos{ed.cur.line, rune_right(l, ed.cur.col)}
			ed.cur = buf_apply(&ed.buf, ed.cur, to, "", ed.cur, .No)
		} else if ed.cur.line + 1 < buf_lines(&ed.buf) {
			ed.cur = buf_apply(&ed.buf, ed.cur, {ed.cur.line + 1, 0}, "", ed.cur, .No)
		}
		ensure_visible(ed)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_RETURN) {
		// Return between an empty pair opens a block rather than leaving the
		// closing half stranded at the end of the new line.
		if return_in_pair(ed) {
			ensure_visible(ed)
			continue
		}
		// Auto-indent: carry the leading whitespace of the current line.
		l := buf_line(&ed.buf, ed.cur.line)
		i := 0
		for i < min(len(l), ed.cur.col) && (l[i] == ' ' || l[i] == '\t') {
			i += 1
		}
		insert(ed, tfmt("\n%s", l[:i]))
		ensure_visible(ed)
	}
	if tn, tshift, _ := held(ui, p.KEY_TAB); tn > 0 {
		if _, _, has := sel_range(ed); has {
			indent_selection(ed, !tshift)
		} else if tshift {
			outdent_line(ed)
		} else {
			insert(ed, "\t", .Type)
		}
		ensure_visible(ed)
	}
	if typed := p.typed_text(ui); len(typed) > 0 && !swallow {
		type_text(ed, typed)
	}
}

// type_text is the path every printable keystroke takes.
//
// Plain characters are still batched into one insert — a paste or a fast
// burst must not become one edit per byte — but a character that might open or
// close a pair is handled on its own, so the pending run is flushed first.
// Every pair character is ASCII, so scanning bytes can never split a rune.
type_text :: proc(ed: ^Editor, typed: string) {
	pending := make([dynamic]u8, 0, len(typed), context.temp_allocator)

	flush :: proc(ed: ^Editor, pending: ^[dynamic]u8) {
		if len(pending) == 0 {
			return
		}
		insert(ed, string(pending[:]), .Type)
		clear(pending)
		ensure_visible(ed)
	}

	for b in transmute([]u8)typed {
		if b < 0x20 || b == 0x7f {
			continue
		}
		_, opens := auto_pair_open(b)
		_, closes := auto_pair_close(b)
		if opens || closes {
			flush(ed, &pending)
			if type_bracket(ed, b) {
				ensure_visible(ed)
				continue
			}
		}
		append(&pending, b)
	}
	flush(ed, &pending)
}

// home_col is the first non-blank, or 0 if the caret is already there — the
// two-step Home every real editor has.
home_col :: proc(ed: ^Editor) -> int {
	l := buf_line(&ed.buf, ed.cur.line)
	i := 0
	for i < len(l) && (l[i] == ' ' || l[i] == '\t') {
		i += 1
	}
	return ed.cur.col == i ? 0 : i
}

// multi_motion moves every caret. A key it does not recognise is ignored
// rather than handed on: with several cursors up there is no single-caret
// path to hand it to.
multi_motion :: proc(ui: ^p.Ctx, ed: ^Editor) {
	for k in ui.input.keys {
		if .Alt in k.mods || .Super in k.mods {
			continue
		}
		shift := .Shift in k.mods
		ctrl := .Ctrl in k.mods
		m: Caret_Motion
		switch k.sym {
		case p.KEY_LEFT:
			m = ctrl ? .Word_Left : .Left
		case p.KEY_RIGHT:
			m = ctrl ? .Word_Right : .Right
		case p.KEY_UP:
			m = .Up
		case p.KEY_DOWN:
			m = .Down
		case p.KEY_HOME:
			m = .Home
		case p.KEY_END:
			m = .End
		case p.KEY_PAGE_UP, p.KEY_PAGE_DOWN:
			// Paging with a dozen cursors means nothing, so it means one.
			carets_collapse(ed)
			continue
		case:
			continue
		}
		carets_move(ed, m, shift)
	}
}

// multi_edit is the editing half: one keystroke, every caret, one undo step.
multi_edit :: proc(ui: ^p.Ctx, ed: ^Editor, swallow: bool) {
	for _ in 0 ..< p.key_count(ui, p.KEY_BACKSPACE) {
		carets_edit(ed, .Backspace)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_DELETE) {
		carets_edit(ed, .Delete)
	}
	for _ in 0 ..< p.key_count(ui, p.KEY_RETURN) {
		carets_edit(ed, .Newline)
	}
	if n, _, _ := held(ui, p.KEY_TAB); n > 0 {
		carets_edit(ed, .Tab)
	}
	if typed := p.typed_text(ui); len(typed) > 0 && !swallow {
		keep := make([dynamic]u8, 0, len(typed), context.temp_allocator)
		for b in transmute([]u8)typed {
			if b >= 0x20 && b != 0x7f {
				append(&keep, b)
			}
		}
		if len(keep) > 0 {
			// Auto-close is deliberately not applied at every caret: a pair
			// inserted in five places where only one of them was in front of
			// whitespace would be five different results from one keystroke.
			carets_edit(ed, .Insert, string(keep[:]))
		}
	}
}

indent_selection :: proc(ed: ^Editor, add: bool) {
	lo, hi, ok := sel_range(ed)
	if !ok {
		return
	}
	last := hi.col == 0 && hi.line > lo.line ? hi.line - 1 : hi.line
	for li := lo.line; li <= last; li += 1 {
		l := buf_line(&ed.buf, li)
		if add {
			buf_apply(&ed.buf, {li, 0}, {li, 0}, "\t", ed.cur, .No)
		} else if len(l) > 0 && l[0] == '\t' {
			buf_apply(&ed.buf, {li, 0}, {li, 1}, "", ed.cur, .No)
		} else {
			n := 0
			for n < len(l) && n < TAB_W && l[n] == ' ' {
				n += 1
			}
			if n > 0 {
				buf_apply(&ed.buf, {li, 0}, {li, n}, "", ed.cur, .No)
			}
		}
	}
	ed.anchor = pos_clamp(&ed.buf, {lo.line, 0})
	ed.cur = pos_clamp(&ed.buf, {last, len(buf_line(&ed.buf, last))})
	ed.has_sel = true
}

outdent_line :: proc(ed: ^Editor) {
	li := ed.cur.line
	l := buf_line(&ed.buf, li)
	if len(l) > 0 && l[0] == '\t' {
		ed.cur = buf_apply(&ed.buf, {li, 0}, {li, 1}, "", ed.cur, .No)
		ed.cur = pos_clamp(&ed.buf, {li, max(0, ed.cur.col)})
		return
	}
	n := 0
	for n < len(l) && n < TAB_W && l[n] == ' ' {
		n += 1
	}
	if n > 0 {
		buf_apply(&ed.buf, {li, 0}, {li, n}, "", ed.cur, .No)
		ed.cur = pos_clamp(&ed.buf, {li, max(0, ed.cur.col - n)})
	}
}

prompt_keys :: proc(ui: ^p.Ctx, ed: ^Editor, swallow: bool) {
	if plain(ui, p.KEY_ESCAPE) {
		ed.mode = .Edit
		ed.prompt = .None
		return
	}
	if plain(ui, p.KEY_TAB) && ed.prompt == .Replace {
		ed.field = ed.field == .Primary ? .Secondary : .Primary
		return
	}

	active: ^[dynamic]u8
	switch ed.prompt {
	case .Find:
		active = &ed.find
	case .Replace:
		active = ed.field == .Primary ? &ed.find : &ed.repl
	case .Goto, .Save_As:
		active = &ed.target
	case .None:
		ed.mode = .Edit
		return
	}

	if field_edit(ui, active, swallow) && (ed.prompt == .Find || ed.prompt == .Replace) {
		ed.matches = buf_count(&ed.buf, string(ed.find[:]), true)
		// Live search from the top of the viewport, so typing walks matches.
		if at, ok := buf_search(&ed.buf, string(ed.find[:]), {ed.top, 0}, true); ok {
			ed.cur = at
			ed.anchor = Pos{at.line, at.col + len(ed.find)}
			ed.has_sel = true
			ensure_visible(ed)
		}
	}

	if plain(ui, p.KEY_F3) {
		do_find_step(ed, false)
	}
	if plain(ui, p.KEY_F4) && ed.prompt == .Replace {
		replace_all(ed)
	}

	if plain(ui, p.KEY_RETURN) {
		switch ed.prompt {
		case .Find:
			do_find_step(ed, false)
		case .Replace:
			replace_one(ed)
		case .Goto:
			if n, ok := strconv.parse_int(string(ed.target[:])); ok {
				ed.cur = pos_clamp(&ed.buf, {clamp(n - 1, 0, buf_lines(&ed.buf) - 1), 0})
				clear_sel(ed)
				ensure_visible(ed)
				ed.mode = .Edit
				ed.prompt = .None
			} else {
				note(ed, "That is not a line number")
			}
		case .Save_As:
			do_save(ed, string(ed.target[:]))
			relang(ed)
			ed.mode = .Edit
			ed.prompt = .None
		case .None:
		}
	}
}

replace_one :: proc(ed: ^Editor) {
	needle := string(ed.find[:])
	if needle == "" {
		return
	}
	lo, hi, has := sel_range(ed)
	cur := buf_text(&ed.buf, lo, hi, context.temp_allocator)
	if has && strings.equal_fold(cur, needle) {
		ed.cur = buf_apply(&ed.buf, lo, hi, string(ed.repl[:]), ed.cur, .No)
		clear_sel(ed)
		ed.matches = buf_count(&ed.buf, needle, true)
	}
	do_find_step(ed, false)
}

replace_all :: proc(ed: ^Editor) {
	needle := string(ed.find[:])
	if needle == "" {
		return
	}
	with := strings.clone(string(ed.repl[:]), context.temp_allocator)
	n := 0
	at := Pos{0, 0}
	for {
		found, ok := buf_search(&ed.buf, needle, at, true)
		if !ok || (n > 0 && pos_less(found, at)) {
			break
		}
		end := Pos{found.line, found.col + len(needle)}
		buf_apply(&ed.buf, found, end, with, ed.cur, .No)
		at = Pos{found.line, found.col + len(with)}
		n += 1
		if n > 200_000 {
			break
		}
	}
	ed.cur = pos_clamp(&ed.buf, ed.cur)
	clear_sel(ed)
	ed.matches = 0
	note(ed, tfmt("Replaced %d occurrence%s", n, n == 1 ? "" : "s"))
}

// ---------------------------------------------------------------------------
// The palette's filtered list
// ---------------------------------------------------------------------------

palette_items :: proc(ed: ^Editor) -> []Command {
	f := string(ed.pal_filter[:])
	if f == "" {
		return COMMANDS[:]
	}
	out := make([dynamic]Command, 0, len(COMMANDS), context.temp_allocator)
	for c in COMMANDS {
		if fuzzy(c.label, f) {
			append(&out, c)
		}
	}
	return out[:]
}

// fuzzy is a subsequence match, folded: "sva" finds "Save As…".
fuzzy :: proc(hay, needle: string) -> bool {
	i := 0
	for j in 0 ..< len(hay) {
		if i < len(needle) && fold(hay[j]) == fold(needle[i]) {
			i += 1
		}
	}
	return i == len(needle)
}
