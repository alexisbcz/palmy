// Commands.
//
// Every operation in the app is a value in `Cmd`, run through `run_cmd`. The
// keyboard binds the common ones directly; the palette (F10) lists all of
// them, which is both how an operation is discovered and how it is reached on
// a keyboard that cannot send the modifier — the demo recorder, for one.
package main

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
	New,
	Open,
	Save,
	Save_As,
	Export_CSV,
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
	{.New, "New sheet", "Ctrl+N"},
	{.Open, "Open sheet", "Ctrl+O"},
	{.Save, "Save", "Ctrl+S"},
	{.Save_As, "Save as", "Ctrl+Shift+S"},
	{.Export_CSV, "Export CSV", "Ctrl+E"},
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
		clear_rect(&app.sh, sel)
		recalc(&app.sh)
		set_status(app, "Cleared")
	case .Fill_Down:
		undo_push(app)
		fill_down(&app.sh, sel)
		recalc(&app.sh)
		set_status(app, "Filled down")
	case .Fill_Right:
		undo_push(app)
		fill_right(&app.sh, sel)
		recalc(&app.sh)
		set_status(app, "Filled right")

	case .Undo:
		do_undo(app)
	case .Redo:
		do_redo(app)

	case .Insert_Row:
		undo_push(app)
		insert_rows(&app.sh, sel.r0, sel.r1 - sel.r0 + 1)
		set_status(app, "Inserted %d row(s) at %d", sel.r1 - sel.r0 + 1, sel.r0 + 1)
	case .Delete_Row:
		undo_push(app)
		delete_rows(&app.sh, sel.r0, sel.r1 - sel.r0 + 1)
		set_status(app, "Deleted %d row(s)", sel.r1 - sel.r0 + 1)
	case .Insert_Col:
		undo_push(app)
		insert_cols(&app.sh, sel.c0, sel.c1 - sel.c0 + 1)
		set_status(app, "Inserted %d column(s) at %s", sel.c1 - sel.c0 + 1, col_name(sel.c0))
	case .Delete_Col:
		undo_push(app)
		delete_cols(&app.sh, sel.c0, sel.c1 - sel.c0 + 1)
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
			set_col_width(&app.sh, col, col_width(&app.sh, col) + d)
		}
		set_status(app, "Column width %d", int(col_width(&app.sh, sel.c0)))
	case .Taller_Row, .Shorter_Row:
		undo_push(app)
		d := f32(cmd == .Taller_Row ? 4 : -4)
		for row in sel.r0 ..= sel.r1 {
			set_row_height(&app.sh, row, row_height(&app.sh, row) + d)
		}
		set_status(app, "Row height %d", int(row_height(&app.sh, sel.r0)))

	case .Select_All:
		app.anchor = {0, 0}
		app.cur = {max(app.sh.max_row, 0), max(app.sh.max_col, 0)}
		follow_cursor(app)
		set_status(app, "Selected the used range")
	case .Goto:
		open_prompt(app, .Goto, "")

	case .New:
		undo_push(app)
		sheet_clear(&app.sh)
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
