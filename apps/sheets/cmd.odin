// Commands.
//
// Every operation in the app is a value in `Cmd`, run through `run_cmd`. The
// keyboard binds the common ones directly; the palette (F10) lists all of
// them, which is both how an operation is discovered and how it is reached on
// a keyboard that cannot send the modifier — the demo recorder, for one.
package main

import "core:fmt"
import "core:strings"

Cmd :: enum u8 {
	None,
	Copy,
	Cut,
	Paste,
	Paste_System,
	Clear,
	Fill_Down,
	Fill_Right,
	Undo,
	Redo,
	Insert_Row,
	Delete_Row,
	Insert_Col,
	Delete_Col,
	Fmt_General,
	Fmt_Fixed,
	Fmt_Percent,
	Fmt_Currency,
	Fmt_Date,
	Fmt_Scientific,
	More_Decimals,
	Fewer_Decimals,
	Bold,
	Italic,
	Align_Left,
	Align_Center,
	Align_Right,
	Align_Auto,
	Wider_Column,
	Narrower_Column,
	Taller_Row,
	Shorter_Row,
	Select_All,
	Goto,
	Sheet_Add,
	Sheet_Rename,
	Sheet_Delete,
	Sheet_Next,
	Sheet_Prev,
	Sheet_Move_Left,
	Sheet_Move_Right,
	Freeze_Here,
	Freeze_Header,
	Unfreeze,
	Merge,
	Unmerge,
	Chart_Bar,
	Chart_Line,
	Chart_Pie,
	Chart_Delete,
	Name_Define,
	Name_Define_Local,
	Name_Delete,
	New,
	Open,
	Save,
	Save_As,
	Export_CSV,
	Export_CSV_All,
	Import_CSV,
	Export_XLSX,
	Import_XLSX,
	Help,
	Quit,
}

Cmd_Row :: struct {
	cmd:   Cmd,
	label: string,
	keys:  string,
}

// The palette's contents, in the order a spreadsheet's menus would have them.
COMMANDS := [?]Cmd_Row {
	{.Copy, "Copy", "Ctrl+C"},
	{.Cut, "Cut", "Ctrl+X"},
	{.Paste, "Paste", "Ctrl+V"},
	{.Paste_System, "Paste from another app", "Ctrl+Shift+V"},
	{.Clear, "Clear cells", "Delete"},
	{.Fill_Down, "Fill down", "Ctrl+D"},
	{.Fill_Right, "Fill right", "Ctrl+R"},
	{.Undo, "Undo", "Ctrl+Z"},
	{.Redo, "Redo", "Ctrl+Y"},
	{.Insert_Row, "Insert rows", "Alt+R"},
	{.Delete_Row, "Delete rows", "Alt+Shift+R"},
	{.Insert_Col, "Insert columns", "Alt+C"},
	{.Delete_Col, "Delete columns", "Alt+Shift+C"},
	{.Fmt_General, "Format as general", "Alt+0"},
	{.Fmt_Fixed, "Format as fixed decimals", "Alt+1"},
	{.Fmt_Percent, "Format as percent", "Alt+2"},
	{.Fmt_Currency, "Format as currency", "Alt+3"},
	{.Fmt_Date, "Format as date", "Alt+4"},
	{.Fmt_Scientific, "Format as scientific", "Alt+5"},
	{.More_Decimals, "More decimals", "Alt+."},
	{.Fewer_Decimals, "Fewer decimals", "Alt+,"},
	{.Bold, "Bold", "Ctrl+B"},
	{.Italic, "Italic", "Ctrl+I"},
	{.Align_Left, "Align left", "Alt+Left"},
	{.Align_Center, "Align centre", "Alt+Up"},
	{.Align_Right, "Align right", "Alt+Right"},
	{.Align_Auto, "Align automatically", "Alt+Down"},
	{.Wider_Column, "Wider column", "Alt+Shift+Right"},
	{.Narrower_Column, "Narrower column", "Alt+Shift+Left"},
	{.Taller_Row, "Taller row", "Alt+Shift+Down"},
	{.Shorter_Row, "Shorter row", "Alt+Shift+Up"},
	{.Select_All, "Select the used range", "Ctrl+A"},
	{.Goto, "Go to reference", "Ctrl+G"},
	{.Sheet_Add, "Add a sheet", "Alt+S"},
	{.Sheet_Rename, "Rename this sheet", "Alt+N"},
	{.Sheet_Delete, "Delete this sheet", "Alt+Shift+S"},
	{.Sheet_Next, "Next sheet", "Ctrl+PgDn"},
	{.Sheet_Prev, "Previous sheet", "Ctrl+PgUp"},
	{.Sheet_Move_Left, "Move sheet left", "Alt+Shift+Left"},
	{.Sheet_Move_Right, "Move sheet right", "Alt+Shift+Right"},
	{.Freeze_Here, "Freeze panes at the cursor", "Alt+F"},
	{.Freeze_Header, "Freeze the header row", ""},
	{.Unfreeze, "Unfreeze panes", "Alt+Shift+F"},
	{.Merge, "Merge the selection", "Alt+M"},
	{.Unmerge, "Unmerge", "Alt+Shift+M"},
	{.Chart_Bar, "Insert a bar chart", "Alt+B"},
	{.Chart_Line, "Insert a line chart", "Alt+L"},
	{.Chart_Pie, "Insert a pie chart", "Alt+P"},
	{.Chart_Delete, "Delete the chart here", "Alt+Shift+B"},
	{.Name_Define, "Name the selection", "Ctrl+Shift+N"},
	{.Name_Define_Local, "Name the selection, for this sheet only", "Ctrl+Alt+N"},
	{.Name_Delete, "Delete a name", ""},
	{.New, "New sheet", "Ctrl+N"},
	{.Open, "Open sheet", "Ctrl+O"},
	{.Save, "Save", "Ctrl+S"},
	{.Save_As, "Save as", "Ctrl+Shift+S"},
	{.Export_CSV, "Export CSV", "Ctrl+E"},
	{.Export_CSV_All, "Export every sheet as CSV", "Ctrl+Shift+E"},
	{.Import_CSV, "Import CSV", "Ctrl+Shift+O"},
	{.Export_XLSX, "Export Excel workbook", "Alt+E"},
	{.Import_XLSX, "Import Excel workbook", "Alt+O"},
	{.Help, "Keyboard map", "F1"},
	{.Quit, "Quit", "Ctrl+Q"},
}

run_cmd :: proc(app: ^App, cmd: Cmd) {
	sel := work_rect(app)
	switch cmd {
	case .None:

	case .Copy:
		do_copy(app, false)
	case .Cut:
		do_copy(app, true)
	case .Paste:
		do_paste(app, false)
	case .Paste_System:
		do_paste(app, true)
	case .Clear:
		undo_push(app)
		clear_rect(app.sh, sel)
		recalc(app.sh)
		set_status(app, "Cleared")
	case .Fill_Down:
		undo_push(app)
		fill_down(app.sh, sel)
		recalc(app.sh)
		set_status(app, "Filled down")
	case .Fill_Right:
		undo_push(app)
		fill_right(app.sh, sel)
		recalc(app.sh)
		set_status(app, "Filled right")

	case .Undo:
		do_undo(app)
	case .Redo:
		do_redo(app)

	case .Insert_Row:
		undo_push(app)
		insert_rows(app.sh, sel.r0, sel.r1 - sel.r0 + 1)
		set_status(app, "Inserted %d row(s) at %d", sel.r1 - sel.r0 + 1, sel.r0 + 1)
	case .Delete_Row:
		undo_push(app)
		delete_rows(app.sh, sel.r0, sel.r1 - sel.r0 + 1)
		set_status(app, "Deleted %d row(s)", sel.r1 - sel.r0 + 1)
	case .Insert_Col:
		undo_push(app)
		insert_cols(app.sh, sel.c0, sel.c1 - sel.c0 + 1)
		set_status(app, "Inserted %d column(s) at %s", sel.c1 - sel.c0 + 1, col_name(sel.c0))
	case .Delete_Col:
		undo_push(app)
		delete_cols(app.sh, sel.c0, sel.c1 - sel.c0 + 1)
		set_status(app, "Deleted %d column(s)", sel.c1 - sel.c0 + 1)

	case .Fmt_General:
		apply_format(app, .Number, int(Num_Format.General))
	case .Fmt_Fixed:
		apply_format(app, .Number, int(Num_Format.Fixed))
	case .Fmt_Percent:
		apply_format(app, .Number, int(Num_Format.Percent))
	case .Fmt_Currency:
		apply_format(app, .Number, int(Num_Format.Currency))
	case .Fmt_Date:
		apply_format(app, .Number, int(Num_Format.Date))
	case .Fmt_Scientific:
		apply_format(app, .Number, int(Num_Format.Scientific))
	case .More_Decimals:
		apply_format(app, .More_Dec, 0)
	case .Fewer_Decimals:
		apply_format(app, .Less_Dec, 0)
	case .Bold:
		apply_format(app, .Bold, 0)
	case .Italic:
		apply_format(app, .Italic, 0)
	case .Align_Left:
		apply_format(app, .Align, int(Halign.Left))
	case .Align_Center:
		apply_format(app, .Align, int(Halign.Center))
	case .Align_Right:
		apply_format(app, .Align, int(Halign.Right))
	case .Align_Auto:
		apply_format(app, .Align, int(Halign.Auto))

	case .Wider_Column, .Narrower_Column:
		undo_push(app)
		d := f32(cmd == .Wider_Column ? 12 : -12)
		for col in sel.c0 ..= sel.c1 {
			set_col_width(app.sh, col, col_width(app.sh, col) + d)
		}
		set_status(app, "Column width %d", int(col_width(app.sh, sel.c0)))
	case .Taller_Row, .Shorter_Row:
		undo_push(app)
		d := f32(cmd == .Taller_Row ? 4 : -4)
		for row in sel.r0 ..= sel.r1 {
			set_row_height(app.sh, row, row_height(app.sh, row) + d)
		}
		set_status(app, "Row height %d", int(row_height(app.sh, sel.r0)))

	case .Select_All:
		app.anchor = {0, 0}
		app.cur = {max(app.sh.max_row, 0), max(app.sh.max_col, 0)}
		follow_cursor(app)
		set_status(app, "Selected the used range")
	case .Goto:
		open_prompt(app, .Goto, "")

	case .Sheet_Add:
		undo_push(app)
		sh := book_add_sheet(app.book, fmt.tprintf("Sheet%d", len(app.book.sheets) + 1))
		if sh == nil {
			set_status(app, "A book holds at most %d sheets", MAX_SHEETS)
			break
		}
		use_sheet(app, len(app.book.sheets) - 1)
		goto_cell(app, {0, 0})
		set_status(app, "Added %s", sh.name)
	case .Sheet_Rename:
		open_prompt(app, .Sheet_Name, app.sh.name)
	case .Sheet_Delete:
		if len(app.book.sheets) <= 1 {
			set_status(app, "A book needs at least one sheet")
			break
		}
		undo_push(app)
		gone := strings.clone(app.sh.name, context.temp_allocator)
		book_delete_sheet(app.book, app.book.active)
		sync_sheet(app)
		follow_cursor(app)
		set_status(app, "Deleted %s — references to it are now #REF!", gone)
	case .Sheet_Next:
		use_sheet(app, (app.book.active + 1) % len(app.book.sheets))
		set_status(app, "Sheet %s", app.sh.name)
	case .Sheet_Prev:
		n := len(app.book.sheets)
		use_sheet(app, (app.book.active + n - 1) % n)
		set_status(app, "Sheet %s", app.sh.name)
	case .Sheet_Move_Left, .Sheet_Move_Right:
		d := cmd == .Sheet_Move_Left ? -1 : 1
		to := app.book.active + d
		if to < 0 || to >= len(app.book.sheets) {
			break
		}
		// The snapshot has to be taken *before* the move, or undo restores
		// the moved order — which matters more now that the order decides
		// what a 3-D reference adds up.
		undo_push(app)
		if book_move_sheet(app.book, app.book.active, to) {
			app.book.active = clamp(app.book.active + d, 0, len(app.book.sheets) - 1)
			sync_sheet(app)
			set_status(app, "Moved %s to position %d", app.sh.name, app.book.active + 1)
		}

	case .Freeze_Here:
		// Freezing "here" pins everything above and left of the cursor, which
		// is what every spreadsheet means by it.
		undo_push(app)
		set_freeze(app.sh, app.cur.row, app.cur.col)
		app.top_row = app.sh.frz_rows
		app.left_col = app.sh.frz_cols
		follow_cursor(app)
		set_status(app, "Froze %d row(s) and %d column(s)", app.sh.frz_rows, app.sh.frz_cols)
	case .Freeze_Header:
		undo_push(app)
		set_freeze(app.sh, 1, 0)
		app.top_row = 1
		follow_cursor(app)
		set_status(app, "Froze the header row")
	case .Unfreeze:
		undo_push(app)
		set_freeze(app.sh, 0, 0)
		set_status(app, "Panes unfrozen")

	case .Merge:
		if sel.r0 == sel.r1 && sel.c0 == sel.c1 {
			set_status(app, "Select more than one cell to merge")
			break
		}
		undo_push(app)
		add_merge(app.sh, sel)
		set_status(app, "Merged %s", rect_text(sel))
	case .Unmerge:
		undo_push(app)
		if drop_merge(app.sh, app.cur) {
			set_status(app, "Unmerged")
		} else {
			set_status(app, "%s is not merged", addr_name(app.cur))
		}

	case .Chart_Bar, .Chart_Line, .Chart_Pie:
		kind := cmd == .Chart_Bar ? Chart_Kind.Bar : (cmd == .Chart_Line ? Chart_Kind.Line : Chart_Kind.Pie)
		insert_chart(app, kind, sel)
	case .Chart_Delete:
		undo_push(app)
		if delete_chart_at(app.sh, app.cur) {
			set_status(app, "Chart deleted")
		} else {
			set_status(app, "No chart at %s", addr_name(app.cur))
		}

	case .Name_Define:
		open_prompt(app, .Name_Define, "")
	case .Name_Define_Local:
		open_prompt(app, .Name_Define_Local, "")
	case .Name_Delete:
		open_prompt(app, .Name_Delete, "")

	case .New:
		undo_push(app)
		// A new document is a new *book*: one empty sheet and no names.
		for i := len(app.book.sheets) - 1; i >= 1; i -= 1 {
			book_delete_sheet(app.book, i)
		}
		sync_sheet(app)
		sheet_clear(app.sh)
		book_clear_names(app.book)
		app.cur = {}
		app.anchor = {}
		app.top_row = 0
		app.left_col = 0
		set_status(app, "New sheet")
	case .Open:
		open_prompt(app, .Open, app.path != "" ? app.path : default_path(app, ".sheet.json"))
	case .Save:
		if app.path == "" {
			open_prompt(app, .Save_As, default_path(app, ".sheet.json"))
		} else {
			do_save(app, app.path)
		}
	case .Save_As:
		open_prompt(app, .Save_As, app.path != "" ? app.path : default_path(app, ".sheet.json"))
	case .Export_CSV:
		open_prompt(app, .Export_CSV, default_path(app, ".csv"))
	case .Export_CSV_All:
		open_prompt(app, .Export_CSV_All, default_path(app, ".csv"))
	case .Import_CSV:
		open_prompt(app, .Import_CSV, default_path(app, ".csv"))
	case .Export_XLSX:
		open_prompt(app, .Export_XLSX, default_path(app, ".xlsx"))
	case .Import_XLSX:
		open_prompt(app, .Import_XLSX, default_path(app, ".xlsx"))

	case .Help:
		app.mode = .Help
	case .Quit:
		app.quit = true
	}
}

// ---------------------------------------------------------------------------
// The palette
// ---------------------------------------------------------------------------

palette_matches :: proc(app: ^App, out: ^[dynamic]Cmd_Row) {
	q := strings.to_lower(strings.trim_space(line_text(&app.pline)), context.temp_allocator)
	for row in COMMANDS {
		if q == "" || fuzzy_has(strings.to_lower(row.label, context.temp_allocator), q) {
			append(out, row)
		}
	}
}

// fuzzy_has is a subsequence test, so "fid" finds "Fill down".
fuzzy_has :: proc(hay, needle: string) -> bool {
	i := 0
	for j in 0 ..< len(hay) {
		if i < len(needle) && hay[j] == needle[i] {
			i += 1
		}
	}
	return i == len(needle)
}

open_palette :: proc(app: ^App) {
	app.mode = .Palette
	app.pal_sel = 0
	line_set(&app.pline, "")
}
