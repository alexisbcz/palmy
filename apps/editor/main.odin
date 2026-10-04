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
	goal:       int, // display column kept across vertical motion
	top:        int,
	left:       int,
	rows:       int,
	cols:       int,
	cw:         f32,
	gutter:     f32,
	numbers:    bool,
	syntax:     bool,
	odin:       bool, // the file is Odin, so highlighting applies
	stats:      bool,
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
	ed.odin = strings.has_suffix(ed.buf.path, ".odin")
	retitle(app, &ed)

	for ui in p.frames(app) {
		measure(ui, &ed)
		keys(ui, &ed, app)
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
	ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
}

ensure_visible :: proc(ed: ^Editor) {
	ed.cur = pos_clamp(&ed.buf, ed.cur)
	if ed.cur.line < ed.top {
		ed.top = ed.cur.line
	}
	if ed.cur.line >= ed.top + ed.rows {
		ed.top = ed.cur.line - ed.rows + 1
	}
	ed.top = clamp(ed.top, 0, max(0, buf_lines(&ed.buf) - 1))

	d := disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
	if d < ed.left {
		ed.left = d
	}
	if d >= ed.left + ed.cols - 1 {
		ed.left = d - ed.cols + 2
	}
	ed.left = max(0, ed.left)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

Cmd :: enum {
	None,
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
	Toggle_Stats,
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
		open_prompt(ed, .Save_As)
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
	ed.goal = disp_of(buf_line(&ed.buf, at.line), at.col)
	ensure_visible(ed)
}

run_cmd :: proc(ed: ^Editor, c: Cmd) {
	switch c {
	case .None:
	case .Save:
		do_save(ed, ed.buf.path)
	case .Save_As:
		open_prompt(ed, .Save_As)
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
	case .Toggle_Stats:
		ed.stats = !ed.stats
	case .Reload:
		if ed.buf.path == "" {
			note(ed, "Nothing to reload")
			break
		}
		path := strings.clone(ed.buf.path, context.temp_allocator)
		buf_load(&ed.buf, path)
		ed.cur = {0, 0}
		ed.top, ed.left = 0, 0
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
	swallow := ed.swallow
	ed.swallow = false

	switch ed.mode {
	case .Help:
		if plain(ui, p.KEY_ESCAPE) || plain(ui, p.KEY_RETURN) || plain(ui, p.KEY_F1) {
			ed.mode = .Edit
		}
		return

	case .Confirm_Quit:
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
			ed.top = clamp(ed.top - step, 0, max(0, buf_lines(&ed.buf) - 1))
		}
	}

	// ---- Motion ---------------------------------------------------------
	//
	// Horizontal motion rewrites the goal column; vertical motion keeps it, so
	// walking down past a short line and back up returns to the same column.
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
			if ed.cur.line > 0 {
				ed.cur.line -= 1
				ed.cur.col = byte_of(buf_line(&ed.buf, ed.cur.line), ed.goal)
			}
			moved_v = true
		case p.KEY_DOWN:
			begin_sel(ed, shift)
			if ed.cur.line + 1 < buf_lines(&ed.buf) {
				ed.cur.line += 1
				ed.cur.col = byte_of(buf_line(&ed.buf, ed.cur.line), ed.goal)
			}
			moved_v = true
		case p.KEY_PAGE_UP:
			begin_sel(ed, shift)
			ed.cur.line = max(0, ed.cur.line - ed.rows)
			ed.cur.col = byte_of(buf_line(&ed.buf, ed.cur.line), ed.goal)
			ed.top = max(0, ed.top - ed.rows)
			moved_v = true
		case p.KEY_PAGE_DOWN:
			begin_sel(ed, shift)
			ed.cur.line = min(buf_lines(&ed.buf) - 1, ed.cur.line + ed.rows)
			ed.cur.col = byte_of(buf_line(&ed.buf, ed.cur.line), ed.goal)
			ed.top = min(max(0, buf_lines(&ed.buf) - 1), ed.top + ed.rows)
			moved_v = true
		case p.KEY_HOME:
			begin_sel(ed, shift)
			if ctrl {
				ed.cur = {0, 0}
			} else {
				// First press goes to the first non-blank, like a real editor.
				l := buf_line(&ed.buf, ed.cur.line)
				i := 0
				for i < len(l) && (l[i] == ' ' || l[i] == '\t') {
					i += 1
				}
				ed.cur.col = ed.cur.col == i ? 0 : i
			}
			moved_h = true
		case p.KEY_END:
			begin_sel(ed, shift)
			if ctrl {
				ed.cur = buf_end(&ed.buf)
			} else {
				ed.cur.col = len(buf_line(&ed.buf, ed.cur.line))
			}
			moved_h = true
		}
	}
	if moved_h || moved_v {
		ed.cur = pos_clamp(&ed.buf, ed.cur)
		if moved_h {
			ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
		}
		ensure_visible(ed)
	}

	// ---- Editing --------------------------------------------------------
	for _ in 0 ..< p.key_count(ui, p.KEY_BACKSPACE) {
		if delete_sel(ed) {
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
		ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
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
		keep := make([dynamic]u8, 0, len(typed), context.temp_allocator)
		for b in transmute([]u8)typed {
			if b >= 0x20 && b != 0x7f {
				append(&keep, b)
			}
		}
		if len(keep) > 0 {
			insert(ed, string(keep[:]), .Type)
			ensure_visible(ed)
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
			ed.odin = strings.has_suffix(ed.buf.path, ".odin")
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
