// Keyboard. Every operation in this app has a key, because pointer clicks
// cannot be synthesized on this compositor and because a spreadsheet is a
// keyboard instrument anyway.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import collabui "../../cloud/collab/ui"

// nkeys counts presses of a key with exactly these modifiers, auto-repeat
// included — two arrow presses can land in one frame when a script drives the
// window, and a cursor that moves by one would fall behind.
nkeys :: proc(ui: ^p.Ctx, sym: u32, mods: p.Modifiers) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == mods {
			n += 1
		}
	}
	return n
}

once :: proc(ui: ^p.Ctx, sym: u32, mods: p.Modifiers) -> bool {
	return p.shortcut(ui, sym, mods)
}

// palmy's keysym table stops at F5 and F11, so F10 is spelled out here.
KEY_F10 :: 0xffc7

Dir :: struct {
	sym:    u32,
	dr, dc: int,
}

DIRS := [?]Dir {
	{p.KEY_UP, -1, 0},
	{p.KEY_DOWN, 1, 0},
	{p.KEY_LEFT, 0, -1},
	{p.KEY_RIGHT, 0, 1},
}

handle_keys :: proc(ui: ^p.Ctx, app: ^App) {
	// Typed text is read first: a character and the Return that commits it can
	// arrive in the same frame.
	typed := p.typed_text(ui)
	alt_held := .Alt in ui.input.mods
	// A chord's letter can also arrive as text, and when the modifier is
	// released within the same frame (a scripted Alt+S does exactly that)
	// the held-modifier test above misses it: Alt+S added a sheet *and*
	// started typing "s" into A1 of it. A frame whose key events carried a
	// command modifier is a command frame, not a typing one.
	for k in ui.input.keys {
		if k.mods & {.Alt, .Ctrl, .Super} != {} {
			alt_held = true
		}
	}

	if once(ui, 'q', {.Ctrl}) {
		app.quit = true
		return
	}
	switch app.mode {
	case .Help:
		if once(ui, p.KEY_ESCAPE, {}) || once(ui, p.KEY_F1, {}) || once(ui, '?', {.Shift}) {
			app.mode = .Nav
		}
		return
	case .Palette:
		keys_palette(ui, app, typed)
		return
	case .Prompt:
		keys_prompt(ui, app, typed)
		return
	case .Edit:
		keys_edit(ui, app, typed)
		return
	case .Nav:
	}

	if collab_keys(ui, app) {
		return
	}

	// --- scrolling ---
	if w := p.wheel(ui); w.y != 0 {
		app.top_row = clamp(app.top_row - int(w.y * 3), 0, MAX_ROWS - 1)
	}

	// --- navigation ---
	for d in DIRS {
		for _ in 0 ..< nkeys(ui, d.sym, {}) {
			move_cursor(app, d.dr, d.dc, false)
		}
		for _ in 0 ..< nkeys(ui, d.sym, {.Shift}) {
			move_cursor(app, d.dr, d.dc, true)
		}
		if nkeys(ui, d.sym, {.Ctrl}) > 0 {
			jump_edge(app, d.dr, d.dc, false)
		}
		if nkeys(ui, d.sym, {.Ctrl, .Shift}) > 0 {
			jump_edge(app, d.dr, d.dc, true)
		}
		// Alt+Arrow sets the alignment of the selection.
		if nkeys(ui, d.sym, {.Alt}) > 0 {
			switch d.sym {
			case p.KEY_LEFT:
				run_cmd(app, .Align_Left)
			case p.KEY_RIGHT:
				run_cmd(app, .Align_Right)
			case p.KEY_UP:
				run_cmd(app, .Align_Center)
			case p.KEY_DOWN:
				run_cmd(app, .Align_Auto)
			}
		}
		// Alt+Shift+Arrow resizes the column or row under the cursor — or,
		// with the cursor on a chart, the chart, the way a drag of its
		// corner handle would.
		if nkeys(ui, d.sym, {.Alt, .Shift}) > 0 && chart_at(app.sh, app.cur) >= 0 {
			switch d.sym {
			case p.KEY_LEFT:
				run_cmd(app, .Chart_Narrower)
			case p.KEY_RIGHT:
				run_cmd(app, .Chart_Wider)
			case p.KEY_UP:
				run_cmd(app, .Chart_Shorter)
			case p.KEY_DOWN:
				run_cmd(app, .Chart_Taller)
			}
		} else if nkeys(ui, d.sym, {.Alt, .Shift}) > 0 {
			switch d.sym {
			case p.KEY_LEFT:
				run_cmd(app, .Narrower_Column)
			case p.KEY_RIGHT:
				run_cmd(app, .Wider_Column)
			case p.KEY_UP:
				run_cmd(app, .Shorter_Row)
			case p.KEY_DOWN:
				run_cmd(app, .Taller_Row)
			}
		}
	}

	for _ in 0 ..< nkeys(ui, p.KEY_TAB, {}) {
		move_cursor(app, 0, 1, false)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_TAB, {.Shift}) {
		move_cursor(app, 0, -1, false)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_PAGE_DOWN, {}) {
		move_cursor(app, app.rows_vis, 0, false)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_PAGE_UP, {}) {
		move_cursor(app, -app.rows_vis, 0, false)
	}
	// Ctrl+PageUp/Down walks the tab strip, and with Shift it drags the
	// current sheet along it.
	for _ in 0 ..< nkeys(ui, p.KEY_PAGE_DOWN, {.Ctrl}) {
		run_cmd(app, .Sheet_Next)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_PAGE_UP, {.Ctrl}) {
		run_cmd(app, .Sheet_Prev)
	}
	if nkeys(ui, p.KEY_PAGE_DOWN, {.Ctrl, .Shift}) > 0 {
		run_cmd(app, .Sheet_Move_Right)
	}
	if nkeys(ui, p.KEY_PAGE_UP, {.Ctrl, .Shift}) > 0 {
		run_cmd(app, .Sheet_Move_Left)
	}
	if once(ui, p.KEY_HOME, {}) {
		goto_cell(app, {app.cur.row, 0})
	}
	if once(ui, p.KEY_HOME, {.Ctrl}) {
		goto_cell(app, {0, 0})
	}
	if once(ui, p.KEY_END, {.Ctrl}) {
		goto_cell(app, {max(app.sh.max_row, 0), max(app.sh.max_col, 0)})
	}
	// --- editing ---
	if once(ui, p.KEY_F2, {}) {
		begin_edit(app, false, false)
	}
	if once(ui, p.KEY_F2, {.Ctrl}) {
		begin_edit(app, false, true) // edit in the formula bar instead
	}
	if once(ui, p.KEY_RETURN, {}) || once(ui, p.KEY_KP_ENTER, {}) {
		begin_edit(app, false, false)
	}
	if once(ui, p.KEY_DELETE, {}) || once(ui, p.KEY_BACKSPACE, {}) {
		run_cmd(app, .Clear)
	}
	// Any printable character starts an edit that replaces the cell.
	if len(typed) > 0 && !alt_held {
		begin_edit(app, true, false)
		line_insert(&app.edit, typed)
	}

	// --- everything else goes through the command table ---
	BINDS := [?]struct {
		sym:  u32,
		mods: p.Modifiers,
		cmd:  Cmd,
	} {
		{'c', {.Ctrl}, .Copy},
		{'x', {.Ctrl}, .Cut},
		{'v', {.Ctrl}, .Paste},
		{'V', {.Ctrl, .Shift}, .Paste_System},
		{'d', {.Ctrl}, .Fill_Down},
		{'r', {.Ctrl}, .Fill_Right},
		{'z', {.Ctrl}, .Undo},
		{'y', {.Ctrl}, .Redo},
		{'Z', {.Ctrl, .Shift}, .Redo},
		{'r', {.Alt}, .Insert_Row},
		{'R', {.Alt, .Shift}, .Delete_Row},
		{'c', {.Alt}, .Insert_Col},
		{'C', {.Alt, .Shift}, .Delete_Col},
		{'b', {.Ctrl}, .Bold},
		{'i', {.Ctrl}, .Italic},
		{'.', {.Alt}, .More_Decimals},
		{',', {.Alt}, .Fewer_Decimals},
		{'a', {.Ctrl}, .Select_All},
		{'g', {.Ctrl}, .Goto},
		{'n', {.Ctrl}, .New},
		{'o', {.Ctrl}, .Open},
		{'s', {.Ctrl}, .Save},
		{'S', {.Ctrl, .Shift}, .Save_As},
		{'e', {.Ctrl}, .Export_CSV},
		{'E', {.Ctrl, .Shift}, .Export_CSV_All},
		{'O', {.Ctrl, .Shift}, .Import_CSV},
		{'e', {.Alt}, .Export_XLSX},
		{'o', {.Alt}, .Import_XLSX},
		{'s', {.Alt}, .Sheet_Add},
		{'S', {.Alt, .Shift}, .Sheet_Delete},
		{'n', {.Alt}, .Sheet_Rename},
		{'f', {.Alt}, .Freeze_Here},
		{'F', {.Alt, .Shift}, .Unfreeze},
		{'m', {.Alt}, .Merge},
		{'M', {.Alt, .Shift}, .Unmerge},
		{'b', {.Alt}, .Chart_Bar},
		{'l', {.Alt}, .Chart_Line},
		{'p', {.Alt}, .Chart_Pie},
		{'B', {.Alt, .Shift}, .Chart_Delete},
		{'d', {.Alt}, .Chart_Labels},
		{'N', {.Ctrl, .Shift}, .Name_Define},
		{'n', {.Ctrl, .Alt}, .Name_Define_Local},
	}
	for b in BINDS {
		if once(ui, b.sym, b.mods) {
			run_cmd(app, b.cmd)
		}
	}
	// Alt+0 .. Alt+5 pick the number format.
	for f, k in ([?]Cmd{.Fmt_General, .Fmt_Fixed, .Fmt_Percent, .Fmt_Currency, .Fmt_Date, .Fmt_Scientific}) {
		if once(ui, u32(int('0') + k), {.Alt}) {
			run_cmd(app, f)
		}
	}
	if once(ui, KEY_F10, {}) || once(ui, 'P', {.Ctrl, .Shift}) {
		open_palette(app)
	}

	if once(ui, p.KEY_F1, {}) || once(ui, '?', {.Shift}) {
		app.mode = .Help
	}
	if once(ui, p.KEY_ESCAPE, {}) {
		app.anchor = app.cur
		clip_reset(&app.clip)
	}
}

// ---------------------------------------------------------------------------
// In-cell and formula-bar editing
// ---------------------------------------------------------------------------

begin_edit :: proc(app: ^App, replace: bool, in_bar: bool) {
	app.mode = .Edit
	app.in_bar = in_bar
	if replace {
		line_set(&app.edit, "")
	} else {
		line_set(&app.edit, input_at(app.sh, app.cur))
	}
	app.anchor = app.cur
}

commit_edit :: proc(app: ^App, dr, dc: int) {
	text := strings.clone(line_text(&app.edit), context.temp_allocator)
	if text != input_at(app.sh, app.cur) {
		undo_push(app)
		set_input(app.sh, app.cur, text)
		recalc(app.sh)
	}
	app.mode = .Nav
	if dr != 0 || dc != 0 {
		move_cursor(app, dr, dc, false)
	}
}

keys_edit :: proc(ui: ^p.Ctx, app: ^App, typed: string) {
	l := &app.edit
	if len(typed) > 0 && .Alt not_in ui.input.mods {
		line_insert(l, typed)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_BACKSPACE, {}) {
		line_backspace(l)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_DELETE, {}) {
		line_delete(l)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_LEFT, {}) {
		l.caret = rune_start(l.buf[:], l.caret)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_RIGHT, {}) {
		l.caret = rune_end(l.buf[:], l.caret)
	}
	if once(ui, p.KEY_HOME, {}) || once(ui, 'a', {.Ctrl}) {
		l.caret = 0
	}
	if once(ui, p.KEY_END, {}) || once(ui, 'e', {.Ctrl}) {
		l.caret = len(l.buf)
	}
	if once(ui, 'u', {.Ctrl}) {
		clear(&l.buf)
		l.caret = 0
	}
	if once(ui, p.KEY_ESCAPE, {}) {
		app.mode = .Nav
		return
	}
	if once(ui, p.KEY_RETURN, {}) || once(ui, p.KEY_KP_ENTER, {}) {
		commit_edit(app, 1, 0)
		return
	}
	if once(ui, p.KEY_RETURN, {.Shift}) {
		commit_edit(app, -1, 0)
		return
	}
	if once(ui, p.KEY_TAB, {}) {
		commit_edit(app, 0, 1)
		return
	}
	if once(ui, p.KEY_TAB, {.Shift}) {
		commit_edit(app, 0, -1)
		return
	}
	// Arrow keys with a modifier leave the editor and move, the way a
	// spreadsheet lets you escape a half-typed entry.
	for d in DIRS {
		if nkeys(ui, d.sym, {.Ctrl}) > 0 {
			commit_edit(app, d.dr, d.dc)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// The command palette
// ---------------------------------------------------------------------------

keys_palette :: proc(ui: ^p.Ctx, app: ^App, typed: string) {
	l := &app.pline
	if len(typed) > 0 && .Alt not_in ui.input.mods {
		line_insert(l, typed)
		app.pal_sel = 0
	}
	for _ in 0 ..< nkeys(ui, p.KEY_BACKSPACE, {}) {
		line_backspace(l)
		app.pal_sel = 0
	}
	rows := make([dynamic]Cmd_Row, 0, len(COMMANDS), context.temp_allocator)
	palette_matches(app, &rows)
	if len(rows) > 0 {
		app.pal_sel += nkeys(ui, p.KEY_DOWN, {}) - nkeys(ui, p.KEY_UP, {})
		app.pal_sel += (nkeys(ui, p.KEY_PAGE_DOWN, {}) - nkeys(ui, p.KEY_PAGE_UP, {})) * 8
		app.pal_sel = clamp(app.pal_sel, 0, len(rows) - 1)
	}
	if once(ui, p.KEY_ESCAPE, {}) {
		app.mode = .Nav
		return
	}
	if once(ui, p.KEY_RETURN, {}) || once(ui, p.KEY_KP_ENTER, {}) || once(ui, p.KEY_TAB, {}) {
		app.mode = .Nav
		if len(rows) > 0 {
			run_cmd(app, rows[clamp(app.pal_sel, 0, len(rows) - 1)].cmd)
		}
	}
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

open_prompt :: proc(app: ^App, kind: Prompt_Kind, initial: string) {
	app.prompt = kind
	app.mode = .Prompt
	line_set(&app.pline, initial)
	// The suggestion behaves like the pre-selected name in a save dialog:
	// typing replaces it, editing it keeps it.
	app.pline_new = initial != ""
}

prompt_title :: proc(k: Prompt_Kind) -> string {
	switch k {
	case .Save_As:
		return "Save sheet as"
	case .Open:
		return "Open sheet"
	case .Export_CSV:
		return "Export CSV to"
	case .Export_CSV_All:
		return "Export every sheet as CSV, one file each, beside"
	case .Import_CSV:
		return "Import CSV from"
	case .Export_XLSX:
		return "Export Excel workbook to"
	case .Import_XLSX:
		return "Import Excel workbook from"
	case .Goto:
		return "Go to reference"
	case .Sheet_Name:
		return "Rename this sheet"
	case .Name_Define:
		return "Name the selection (Sheet!Name scopes it to one sheet)"
	case .Name_Define_Local:
		return "Name the selection, for this sheet only"
	case .Chart_Size:
		return "Chart size, columns x rows"
	case .Name_Delete:
		return "Delete which name (Sheet!Name for a local one)"
	case .Comment:
		return "Comment on this cell"
	case .Share:
		return "Share with: <handle> <view|comment|edit>, or: link <role>"
	case .Name_Version:
		return "Name this version"
	case .None:
		return ""
	}
	return ""
}

keys_prompt :: proc(ui: ^p.Ctx, app: ^App, typed: string) {
	l := &app.pline
	if len(typed) > 0 && .Alt not_in ui.input.mods {
		if app.pline_new {
			clear(&l.buf)
			l.caret = 0
		}
		line_insert(l, typed)
	}
	if len(ui.input.keys) > 0 || len(typed) > 0 {
		app.pline_new = false
	}
	for _ in 0 ..< nkeys(ui, p.KEY_BACKSPACE, {}) {
		line_backspace(l)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_DELETE, {}) {
		line_delete(l)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_LEFT, {}) {
		l.caret = rune_start(l.buf[:], l.caret)
	}
	for _ in 0 ..< nkeys(ui, p.KEY_RIGHT, {}) {
		l.caret = rune_end(l.buf[:], l.caret)
	}
	if once(ui, p.KEY_HOME, {}) || once(ui, 'a', {.Ctrl}) {
		l.caret = 0
	}
	if once(ui, p.KEY_END, {}) || once(ui, 'e', {.Ctrl}) {
		l.caret = len(l.buf)
	}
	if once(ui, 'u', {.Ctrl}) {
		clear(&l.buf)
		l.caret = 0
	}
	if once(ui, p.KEY_ESCAPE, {}) {
		app.mode = .Nav
		app.prompt = .None
		return
	}
	if once(ui, p.KEY_RETURN, {}) || once(ui, p.KEY_KP_ENTER, {}) {
		run_prompt(app, strings.clone(line_text(l), context.temp_allocator))
		app.mode = .Nav
		app.prompt = .None
	}
}

run_prompt :: proc(app: ^App, text: string) {
	arg := strings.trim_space(text)
	switch app.prompt {
	case .None:
	case .Goto:
		// Go To understands a sheet, a named range, or a plain reference, in
		// that order — which is the same vocabulary a formula has.
		if sheet, rect, _, ok := parse_ref_target(arg); ok {
			if sheet != "" {
				i := book_find(app.book, sheet)
				if i < 0 {
					set_status(app, "There is no sheet called %s", sheet)
					return
				}
				use_sheet(app, i)
			}
			app.anchor = {rect.r0, rect.c0}
			app.cur = {rect.r1, rect.c1}
			follow_cursor(app)
			set_status(app, "Went to %s", arg)
			return
		}
		if nd, _, ok := book_resolve_name(app.book, arg, app.book.active); ok {
			if i := book_find(app.book, nd.sheet); i >= 0 {
				use_sheet(app, i)
			}
			app.anchor = {nd.rect.r0, nd.rect.c0}
			app.cur = {nd.rect.r1, nd.rect.c1}
			follow_cursor(app)
			set_status(app, "Went to %s", arg)
			return
		}
		if i := book_find(app.book, arg); i >= 0 {
			use_sheet(app, i)
			set_status(app, "Sheet %s", app.sh.name)
			return
		}
		set_status(app, "%s is not a reference", arg)
	case .Sheet_Name:
		if arg == "" {
			return
		}
		undo_push(app)
		old := strings.clone(app.sh.name, context.temp_allocator)
		if book_rename_sheet(app.book, app.book.active, arg) {
			recalc_all(app.sh)
			set_status(app, "Renamed %s to %s", old, app.sh.name)
		} else {
			set_status(app, "Cannot rename to %s", arg)
		}
	case .Name_Define, .Name_Define_Local:
		if arg == "" {
			return
		}
		// `Rate` names it for the whole book and `Q2!Rate` for sheet Q2
		// only — the spelling `sheets name-set` takes too. The local command
		// scopes a bare name to the sheet you are on.
		scope, name := name_spec(arg)
		if app.prompt == .Name_Define_Local && scope == "" {
			scope = app.sh.name
		}
		undo_push(app)
		if book_set_name(app.book, name, app.sh.name, work_rect(app), true, scope) {
			recalc_all(app.sh)
			if scope != "" {
				set_status(app, "%s names %s, on %s only", name, rect_text(work_rect(app)), scope)
			} else {
				set_status(app, "%s names %s", name, rect_text(work_rect(app)))
			}
		} else {
			set_status(app, "%s is not a usable name", arg)
		}
	case .Name_Delete:
		if arg == "" {
			return
		}
		undo_push(app)
		if scope, name, ok := name_drop_spec(app.book, arg, app.book.active); ok {
			recalc_all(app.sh)
			set_status(app, "Dropped the name %s", name_label(scope, name))
		} else {
			set_status(app, "There is no name %s", arg)
		}
	case .Chart_Size:
		i := chart_at(app.sh, app.cur)
		w, h, ok := parse_chart_size(arg)
		if i < 0 || !ok {
			set_status(app, "%s is not a size like 8x14", arg)
			return
		}
		undo_push(app)
		chart_resize(app.sh, i, w, h)
		set_status(app, "Chart is %s cells", chart_size_text(app.sh.charts[i]))
	case .Comment:
		collab_comment(app, arg)
	case .Share:
		set_status(app, "%s", collabui.share_cmd(&collab.ui, arg))
	case .Name_Version:
		if e := collabui.name_version(&collab.ui, arg); e != "" {
			set_status(app, "%s", e)
		} else {
			set_status(app, "Named this version %q", arg)
		}
	case .Save_As:
		do_save(app, arg)
	case .Open:
		if arg == "" {
			return
		}
		cur, anc, ok := doc_load_file(app.book.sheets[0], arg)
		if !ok {
			set_status(app, "Could not open %s", arg)
			return
		}
		sync_sheet(app)
		app.cur, app.anchor = cur, anc
		follow_cursor(app)
		set_path(app, arg)
		app.modified = false
		set_status(app, "Opened %s", arg)
	case .Export_CSV:
		if arg == "" {
			return
		}
		sel := work_rect(app)
		rect := sel
		if sel.r0 == sel.r1 && sel.c0 == sel.c1 {
			// Nothing selected means the whole sheet.
			rect = {0, 0, max(app.sh.max_row, 0), max(app.sh.max_col, 0)}
		}
		if csv_write_file(app.sh, arg, rect) {
			set_status(
				app,
				"Exported %s:%s to %s",
				addr_name({rect.r0, rect.c0}),
				addr_name({rect.r1, rect.c1}),
				arg,
			)
		} else {
			set_status(app, "Could not write %s", arg)
		}
	case .Export_CSV_All:
		if arg == "" {
			return
		}
		files, ok := csv_write_book(app.book, arg)
		if !ok {
			set_status(app, "Could not write %s", len(files) < len(app.book.sheets) ? csv_book_paths(app.book, arg)[len(files)] : arg)
			return
		}
		if len(files) == 1 {
			set_status(app, "Exported %s to %s", app.book.sheets[0].name, files[0])
		} else {
			set_status(app, "Exported %d sheets: %s … %s", len(files), base_name(files[0]), base_name(files[len(files) - 1]))
		}
	case .Import_CSV:
		if arg == "" {
			return
		}
		undo_push(app)
		ok, rows, cols := csv_read_file(app.sh, arg, app.cur)
		if !ok {
			set_status(app, "Could not read %s", arg)
			return
		}
		set_status(app, "Imported %d x %d from %s", rows, cols, base_name(arg))
	case .Export_XLSX:
		if arg == "" {
			return
		}
		if xlsx_write_book(app.book, arg) {
			set_status(app, "Wrote %s", arg)
		} else {
			set_status(app, "Could not write %s", arg)
		}
	case .Import_XLSX:
		if arg == "" {
			return
		}
		undo_push(app)
		// A whole workbook replaces the book; a sheet-at-the-cursor import
		// would lose the other sheets, which is the one thing a multi-sheet
		// importer must not do.
		ok, sheets, cells := xlsx_read_book(app.book, arg)
		if !ok {
			set_status(app, "%s is not a readable .xlsx", base_name(arg))
			return
		}
		sync_sheet(app)
		app.cur = {}
		app.anchor = {}
		app.top_row = 0
		app.left_col = 0
		follow_cursor(app)
		set_status(app, "Imported %d sheet(s), %d cells, from %s", sheets, cells, base_name(arg))
	}
}

do_save :: proc(app: ^App, path: string) {
	if path == "" {
		return
	}
	if doc_save_file(app.sh, path, base_name(path), app.cur, app.anchor) {
		set_path(app, path)
		app.modified = false
		set_status(app, "Saved %s", path)
	} else {
		set_status(app, "Could not write %s", path)
	}
}

default_path :: proc(app: ^App, ext: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "."
	}
	base := app.name != "" ? strip_ext(app.name) : "sheet"
	return strings.concatenate({home, "/", base, ext}, context.temp_allocator)
}

strip_ext :: proc(name: string) -> string {
	if i := strings.index_byte(name, '.'); i > 0 {
		return name[:i]
	}
	return name
}

// ---------------------------------------------------------------------------
// Clipboard
//
// The system clipboard carries TSV of the displayed values, which is what
// another spreadsheet expects. The in-app clipboard keeps the inputs and
// formats so that pasting inside the app adjusts relative references. A paste
// uses the in-app copy only when the system selection is still the text we
// put there; otherwise it parses whatever is on the clipboard.
// ---------------------------------------------------------------------------

// clipboard_put writes the system selection without blocking.
//
// `kit.clipboard_set` runs `wl-copy` and waits for it, but wl-copy forks and
// keeps serving the selection until it is replaced, holding the pipe open —
// so the wait never ends and the window freezes. Writing through a file and a
// detached shell is the same effect in under a millisecond.
clipboard_put :: proc(app: ^App, text: string) -> bool {
	path := clip_path(app)
	if os.write_entire_file(path, transmute([]u8)text) != nil {
		return false
	}
	if !kit.launch({"sh", "-c", fmt.tprintf("wl-copy < %q", path)}) {
		return false
	}
	// Wait for the selection to change hands. wl-copy forks immediately, so
	// this settles in a few milliseconds; without it a paste issued in the
	// same breath would still see the previous owner's text and mistake our
	// own copy for someone else's.
	want := strings.trim_right(text, "\n")
	for _ in 0 ..< 30 {
		time.sleep(4 * time.Millisecond)
		if cur, ok := kit.clipboard_get(context.temp_allocator); ok {
			if strings.trim_right(cur, "\n") == want {
				break
			}
		}
	}
	return true
}

clip_path :: proc(app: ^App) -> string {
	if app.clip_file == "" {
		app.clip_file = fmt.aprintf("/tmp/palmy-sheets-%d.tsv", os.get_pid())
	}
	return app.clip_file
}

do_copy :: proc(app: ^App, cut: bool) {
	rect := work_rect(app)
	copy_range(app.sh, &app.clip, rect, cut)
	tsv := delim_export(app.sh, rect, '\t', false, context.temp_allocator)
	if app.last_tsv != "" {
		delete(app.last_tsv)
	}
	app.last_tsv = strings.clone(tsv)
	if clipboard_put(app, tsv) {
		set_status(
			app,
			"%s %s:%s",
			cut ? "Cut" : "Copied",
			addr_name({rect.r0, rect.c0}),
			addr_name({rect.r1, rect.c1}),
		)
	} else {
		set_status(app, "%s (clipboard tool missing)", cut ? "Cut" : "Copied")
	}
}

do_paste :: proc(app: ^App, force_system: bool) {
	outside, got := kit.clipboard_get(context.temp_allocator)
	undo_push(app)
	// wl-paste --no-newline drops the final newline, so compare without it.
	same := strings.trim_right(outside, "\n") == strings.trim_right(app.last_tsv, "\n")
	if !force_system && app.clip.live && (!got || same) {
		paste_clip(app.sh, &app.clip, work_rect(app))
		recalc(app.sh)
		set_status(app, "Pasted at %s", addr_name(app.cur))
		return
	}
	if !got || outside == "" {
		set_status(app, "Clipboard is empty")
		return
	}
	rows, cols := import_delim(app.sh, outside, app.cur, '\t')
	set_status(app, "Pasted %d x %d from the clipboard", rows, cols)
}

// ---------------------------------------------------------------------------
// Formatting commands
// ---------------------------------------------------------------------------

Fmt_Cmd :: enum u8 {
	Bold,
	Italic,
	Number,
	More_Dec,
	Less_Dec,
	Align,
}

apply_format :: proc(app: ^App, cmd: Fmt_Cmd, arg: int) {
	rect := work_rect(app)
	undo_push(app)
	// Toggles read the anchor cell and apply the opposite to the whole
	// selection, so a mixed selection becomes uniform rather than inverting
	// cell by cell.
	base := fmt_at(app.sh, {rect.r0, rect.c0})

	// Over a wide selection, format the cells that exist rather than
	// materialising an empty one for every address in it.
	targets := make([dynamic]Addr, 0, 64, context.temp_allocator)
	if (rect.r1 - rect.r0 + 1) * (rect.c1 - rect.c0 + 1) > 4096 {
		for addr in app.sh.cells {
			if rect_contains(rect, addr) {
				append(&targets, addr)
			}
		}
	} else {
		for row in rect.r0 ..= rect.r1 {
			for col in rect.c0 ..= rect.c1 {
				append(&targets, Addr{row, col})
			}
		}
	}

	for a in targets {
		{
			f := fmt_at(app.sh, a)
			switch cmd {
			case .Bold:
				f.bold = !base.bold
			case .Italic:
				f.italic = !base.italic
			case .Number:
				f.num = Num_Format(arg)
				if f.num == .Fixed && f.dec == 0 {
					f.dec = 2
				}
				if f.num == .Currency {
					f.dec = 2
				}
			case .More_Dec:
				f.dec = u8(min(int(f.dec) + 1, 9))
				if f.num == .General {
					f.num = .Fixed
				}
			case .Less_Dec:
				f.dec = u8(max(int(f.dec) - 1, 0))
				if f.num == .General {
					f.num = .Fixed
				}
			case .Align:
				f.align = Halign(arg)
			}
			if cell_at(app.sh, a) != nil || !fmt_is_default(f) {
				set_cell_fmt(app.sh, a, f)
			}
		}
	}
	switch cmd {
	case .Bold:
		set_status(app, base.bold ? "Bold off" : "Bold")
	case .Italic:
		set_status(app, base.italic ? "Italic off" : "Italic")
	case .Number:
		set_status(app, "Format: %s", num_format_name(Num_Format(arg)))
	case .More_Dec, .Less_Dec:
		set_status(app, "Decimals: %d", fmt_at(app.sh, {rect.r0, rect.c0}).dec)
	case .Align:
		set_status(app, "Aligned")
	}
}
