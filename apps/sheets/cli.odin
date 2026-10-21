package main

// The command-line front end of Sheets.
//
// Sheets is the exemplar for an application that already had a command line
// and had to be brought onto the convention. It had `--export`, `--shot`,
// `--film` and `--selftest`, each parsed by hand in `main` and each printing
// a sentence. Those spellings all still work — they are declared as aliases,
// so no script that calls them breaks — but they are commands now, with a
// side-effect class, a generated `--help`, a declared output schema and
// `--json`.
//
// What the convention bought beyond tidiness is the half of the engine that
// had no way out of the program at all. `eval.odin` could compute
// `=INDEX(Sales!A3:A7,MATCH(MAX(Sales!D3:D7),Sales!D3:D7,0))` and the only way
// to see the answer was to look at a window. `sheets eval` and `sheets get`
// are that same evaluator with a different front end, which is the whole
// point of the exercise: the GUI and the CLI reach the same code.

import "core:fmt"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "the sheets in a book, their size, their names and their charts",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "a .sheet.json, .csv or .xlsx; the demo book when absent"}},
		out = INFO_FIELDS,
		examples = {"sheets info --json"},
		run = cmd_info,
	},
	{
		verb = "get",
		summary = "one cell: what was typed, what it evaluates to, and how it is shown",
		effect = .Read,
		args = {
			{name = "cell", kind = .String, help = "an A1 reference, optionally Sheet!A1", required = true},
			{name = "file", kind = .Path, help = "the book; the demo book when absent"},
		},
		out = CELL_FIELDS,
		examples = {"sheets get Summary!B8 --json", "sheets get A1 book.sheet.json --json"},
		run = cmd_get,
	},
	{
		verb = "cells",
		summary = "a rectangle of cells",
		effect = .Read,
		args = {
			{name = "range", kind = .String, help = "A1:D9, or a whole sheet when absent"},
			{name = "file", kind = .Path, help = "the book; the demo book when absent"},
		},
		flags = {
			{name = "sheet", kind = .String, help = "which sheet, by name"},
			{name = "empty", kind = .Bool, help = "include cells with nothing in them"},
		},
		out = CELLS_FIELDS,
		examples = {"sheets cells A1:D9 --json", "sheets cells --sheet Summary --json"},
		run = cmd_cells,
	},
	{
		verb = "eval",
		summary = "evaluate a formula against a book, without changing it",
		effect = .Read,
		args = {
			{name = "formula", kind = .String, help = "=SUM(Sales!D3:D7), or a literal", required = true},
			{name = "file", kind = .Path, help = "the book to evaluate against"},
		},
		flags = {{name = "sheet", kind = .String, help = "which sheet the formula sits on"}},
		out = EVAL_FIELDS,
		examples = {"sheets eval '=SUM(Sales!D3:D7)' --json", "sheets eval '=1+2*3' --json"},
		run = cmd_eval,
	},
	{
		verb = "set",
		summary = "put a value or a formula in a cell and save the book",
		effect = .Mutate,
		args = {
			{name = "file", kind = .Path, help = "the book to change", required = true},
			{name = "cell", kind = .String, help = "an A1 reference, optionally Sheet!A1", required = true},
			{name = "value", kind = .String, help = "what to type into it", required = true},
		},
		flags = {{name = "out", kind = .Path, help = "write here instead of over the input"}},
		out = SET_FIELDS,
		examples = {"sheets set book.sheet.json B3 130 --json", "sheets set book.sheet.json D3 '=B3*C3' --dry-run --json"},
		run = cmd_set,
	},
	{
		verb = "sheet-add",
		summary = "add a sheet, at the end or at a position — inside a 3-D span if that is where it lands",
		effect = .Mutate,
		args = {
			{name = "file", kind = .Path, help = "the book to change", required = true},
			{name = "name", kind = .String, help = "the new sheet's name", required = true},
		},
		flags = {
			{name = "at", kind = .Int, help = "0-based position; the end when absent"},
			{name = "out", kind = .Path, help = "write here instead of over the input"},
		},
		out = SHEET_OP_FIELDS,
		examples = {"sheets sheet-add book.sheet.json Feb --at 1 --json"},
		run = cmd_sheet_add,
	},
	{
		verb = "sheet-move",
		summary = "move a sheet to a 0-based position; 3-D references that span it follow the new order",
		effect = .Idempotent,
		args = {
			{name = "file", kind = .Path, help = "the book to change", required = true},
			{name = "sheet", kind = .String, help = "which sheet, by name", required = true},
			{name = "index", kind = .Int, help = "where it goes, 0-based", required = true},
		},
		flags = {{name = "out", kind = .Path, help = "write here instead of over the input"}},
		out = SHEET_OP_FIELDS,
		examples = {"sheets sheet-move book.sheet.json Mar 0 --json"},
		run = cmd_sheet_move,
	},
	{
		verb = "sheet-rename",
		summary = "rename a sheet and every formula and name that refers to it",
		effect = .Mutate,
		args = {
			{name = "file", kind = .Path, help = "the book to change", required = true},
			{name = "sheet", kind = .String, help = "which sheet, by name", required = true},
			{name = "name", kind = .String, help = "its new name (no colon)", required = true},
		},
		flags = {{name = "out", kind = .Path, help = "write here instead of over the input"}},
		out = SHEET_OP_FIELDS,
		examples = {"sheets sheet-rename book.sheet.json Sheet2 Feb --json"},
		run = cmd_sheet_rename,
	},
	{
		verb = "sheet-delete",
		summary = "delete a sheet; a 3-D span that ended on it narrows, other references to it become #REF!",
		effect = .Destructive,
		args = {
			{name = "file", kind = .Path, help = "the book to change", required = true},
			{name = "sheet", kind = .String, help = "which sheet, by name", required = true},
		},
		flags = {{name = "out", kind = .Path, help = "write here instead of over the input"}},
		out = SHEET_OP_FIELDS,
		examples = {"sheets sheet-delete book.sheet.json Jan --yes --json"},
		run = cmd_sheet_delete,
	},
	{
		verb = "export",
		summary = "write a book out as .xlsx, .csv or the native .sheet.json",
		effect = .Mutate,
		aliases = {"--export"},
		args = {
			{name = "out", kind = .Path, help = "the file to write", required = true},
			{name = "in", kind = .Path, help = "the book to read; the demo book when absent"},
		},
		out = EXPORT_FIELDS,
		examples = {"sheets export /tmp/book.xlsx --json", "sheets export /tmp/book.csv --json"},
		run = cmd_export,
	},
	{
		verb = "shot",
		summary = "render one frame offscreen to a PNG",
		effect = .Mutate,
		aliases = {"--shot"},
		args = {
			{name = "path", kind = .Path, help = "the PNG to write", required = true},
			{name = "steps", kind = .String, help = "keys to press first", variadic = true},
		},
		out = {{name = "path", kind = .String}},
		examples = {"sheets shot /tmp/sheets.png"},
		run = cmd_shot,
	},
	{
		verb = "film",
		summary = "render one PNG per step, for a demo with no compositor",
		effect = .Mutate,
		aliases = {"--film"},
		args = {
			{name = "prefix", kind = .Path, help = "the output prefix", required = true},
			{name = "steps", kind = .String, help = "the steps to drive", variadic = true},
		},
		out = {{name = "prefix", kind = .String}},
		examples = {"sheets film /tmp/sheets-frame"},
		run = cmd_film,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "sheets",
			summary    = "a spreadsheet, and the formula engine underneath it",
			gui        = true,
			// `sheets book.csv` opens the file, which is why a bare word that
			// is not a verb is handed to the window rather than refused.
			takes_path = true,
			selftest   = selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command, sheets opens a window; a path opens that file in it.
The older spellings --export, --shot and --film are aliases of the commands
of the same name and keep working.

A cell reference may name its sheet: Summary!B8. A formula may also span
sheets, SUM(Jan:Mar!B2), which adds B2 on every sheet from Jan to Mar in the
book's current order; sheet-add, sheet-move and sheet-delete change that span
exactly as the window's commands do. Where no book is given, the
demo book is used, so every read command works on a machine with no documents
on it — which is also what makes them testable.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

INFO_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the book that was read, or \"(demo)\""},
	{
		name = "sheets",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "index", kind = .Int},
			{name = "rows", kind = .Int, help = "the used height"},
			{name = "cols", kind = .Int, help = "the used width"},
			{name = "cells", kind = .Int},
			{name = "formulas", kind = .Int},
			{name = "errors", kind = .Int},
			{name = "charts", kind = .Int},
			{name = "merges", kind = .Int},
			{name = "frozen_rows", kind = .Int},
			{name = "frozen_cols", kind = .Int},
		},
	},
	{
		name = "names",
		kind = .Array,
		of = {{name = "name", kind = .String}, {name = "target", kind = .String}},
	},
	{name = "sheet_count", kind = .Int},
	{name = "cell_count", kind = .Int},
}

CELL_FIELDS := []kit.Field {
	{name = "sheet", kind = .String},
	{name = "ref", kind = .String},
	{name = "input", kind = .String, help = "exactly what was typed"},
	{name = "formula", kind = .Bool},
	{name = "type", kind = .String, help = "number, text, bool, error or empty"},
	{name = "value", kind = .String, help = "the computed value, as text"},
	{name = "number", kind = .Float, opt = true, help = "present when the value is a number"},
	{name = "formatted", kind = .String, help = "how the grid shows it"},
	{name = "error", kind = .String, opt = true},
}

CELLS_FIELDS := []kit.Field {
	{name = "sheet", kind = .String},
	{name = "range", kind = .String},
	{
		name = "cells",
		kind = .Array,
		of = {
			{name = "ref", kind = .String},
			{name = "input", kind = .String},
			{name = "formula", kind = .Bool},
			{name = "type", kind = .String},
			{name = "value", kind = .String},
			{name = "formatted", kind = .String},
		},
	},
	{name = "count", kind = .Int},
}

EVAL_FIELDS := []kit.Field {
	{name = "formula", kind = .String},
	{name = "sheet", kind = .String, help = "the sheet it was evaluated on"},
	{name = "type", kind = .String},
	{name = "value", kind = .String},
	{name = "number", kind = .Float, opt = true},
	{name = "error", kind = .String, opt = true},
}

SET_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the file that was written"},
	{name = "sheet", kind = .String},
	{name = "ref", kind = .String},
	{name = "input", kind = .String},
	{name = "was", kind = .String, help = "what the cell held before"},
	{name = "type", kind = .String},
	{name = "value", kind = .String},
	{name = "formatted", kind = .String},
	{name = "written", kind = .Bool, help = "false under --dry-run"},
}

SHEET_OP_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the file that was (or would be) written"},
	{name = "sheet", kind = .String, help = "the sheet acted on, under its name afterwards"},
	{name = "sheets", kind = .Array, of = {{kind = .String}}, help = "every sheet, in order, afterwards"},
	{name = "rewritten", kind = .Int, help = "formulas whose text changed (rename, delete)"},
	{name = "written", kind = .Bool, help = "false under --dry-run"},
}

EXPORT_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "format", kind = .String, help = "xlsx, csv or sheet.json"},
	{name = "sheets", kind = .Int},
	{name = "cells", kind = .Int},
	{name = "written", kind = .Bool, help = "false under --dry-run"},
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

// open_book builds an App the way `main` does, minus the window, and fills it
// from `src` — the same readers the window uses. With no source it seeds the
// demo book, so a read command has something real to work on anywhere.
@(private = "file")
open_book :: proc(src: string) -> (app: ^App, ok: bool) {
	app = new(App)
	app_init(app)
	if src == "" {
		seed_demo(app)
		app.name = strings.clone("(demo)")
		return app, true
	}
	switch {
	case strings.has_suffix(src, ".csv"), strings.has_suffix(src, ".tsv"):
		got, _, _ := csv_read_file(app.sh, src, {0, 0})
		ok = got
	case strings.has_suffix(src, ".xlsx"):
		got, _, _ := xlsx_read_book(app.book, src)
		sync_sheet(app)
		ok = got
	case:
		_, _, got := doc_load_file(app.book.sheets[0], src)
		sync_sheet(app)
		ok = got
	}
	if !ok {
		app_destroy(app)
		free(app)
		return nil, false
	}
	app.name = strings.clone(base_name(src))
	book_recalc_all(app.book)
	return app, true
}

// pick_sheet resolves `Sheet!A1` and `--sheet NAME` to one sheet of the book.
@(private = "file")
pick_sheet :: proc(app: ^App, ref: string, flag: string) -> (sh: ^Sheet, rest: string, ok: bool) {
	rest = ref
	name := flag
	if bang := strings.index_byte(ref, '!'); bang >= 0 {
		name = strings.trim(ref[:bang], "'")
		rest = ref[bang + 1:]
	}
	if name == "" {
		return app.book.sheets[0], rest, true
	}
	i := book_find(app.book, name)
	if i < 0 {
		return nil, rest, false
	}
	return app.book.sheets[i], rest, true
}

@(private = "file")
value_kind :: proc(v: Value) -> string {
	switch v.kind {
	case .Empty:
		return "empty"
	case .Number:
		return "number"
	case .Text:
		return "text"
	case .Bool:
		return "bool"
	case .Error:
		return "error"
	}
	return "empty"
}

// cell_json is the one description of a cell, used by `get`, `cells` and
// `set`, so the three cannot describe the same cell differently.
@(private = "file")
cell_json :: proc(sh: ^Sheet, a: Addr) -> ^kit.Json {
	o := kit.jobj()
	c := cell_at(sh, a)
	kit.jset_str(o, "ref", addr_name(a))
	kit.jset_str(o, "input", c == nil ? "" : c.input)
	kit.jset_bool(o, "formula", c != nil && c.ast != nil)
	v := c == nil ? Value{} : c.val
	kit.jset_str(o, "type", value_kind(v))
	kit.jset_str(o, "value", c == nil ? "" : format_value(v, Cell_Fmt{}))
	kit.jset_str(o, "formatted", c == nil ? "" : format_value(v, c.fmt))
	return o
}

@(private = "file")
put_value :: proc(out: ^kit.Json, v: Value) {
	kit.jset_str(out, "type", value_kind(v))
	kit.jset_str(out, "value", format_value(v, Cell_Fmt{}))
	if v.kind == .Number {
		kit.jset_num(out, "number", v.num)
	}
	if v.kind == .Error {
		kit.jset_str(out, "error", err_text(v.err))
	}
}

@(private = "file")
no_book :: proc(c: ^kit.Call, path: string) -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", path)
	kit.cli_err_field(c, "file", path)
	return code
}

@(private = "file")
no_sheet :: proc(c: ^kit.Call, name: string) -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no sheet named %q", name)
	kit.cli_err_field(c, "sheet", name)
	return code
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	kit.jset_str(c.out, "path", src == "" ? "(demo)" : src)
	arr := kit.jarr()
	total := 0
	for sh, i in app.book.sheets {
		formulas, errors := 0, 0
		for _, cell in sh.cells {
			if cell.ast != nil {
				formulas += 1
			}
			if is_err(cell.val) {
				errors += 1
			}
		}
		total += len(sh.cells)
		o := kit.jobj()
		kit.jset_str(o, "name", sh.name)
		kit.jset_int(o, "index", i)
		kit.jset_int(o, "rows", sh.max_row + 1)
		kit.jset_int(o, "cols", sh.max_col + 1)
		kit.jset_int(o, "cells", len(sh.cells))
		kit.jset_int(o, "formulas", formulas)
		kit.jset_int(o, "errors", errors)
		kit.jset_int(o, "charts", len(sh.charts))
		kit.jset_int(o, "merges", len(sh.merges))
		kit.jset_int(o, "frozen_rows", sh.frz_rows)
		kit.jset_int(o, "frozen_cols", sh.frz_cols)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "sheets", arr)

	names := kit.jarr()
	for key, nd in app.book.names {
		o := kit.jobj()
		kit.jset_str(o, "name", key)
		kit.jset_str(o, "target", name_target(app.book, nd))
		kit.jpush(names, o)
	}
	kit.jset(c.out, "names", names)
	kit.jset_int(c.out, "sheet_count", len(app.book.sheets))
	kit.jset_int(c.out, "cell_count", total)
	return kit.EXIT_OK
}

@(private = "file")
cmd_get :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	sh, rest, found := pick_sheet(app, kit.cli_str(c, "cell"), "")
	if !found {
		return no_sheet(c, kit.cli_str(c, "cell"))
	}
	r, good := ref_parse(rest)
	if !good || r.row == NO_ROW {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a cell reference", rest)
	}
	a := Addr{r.row, r.col}
	cell := cell_at(sh, a)
	kit.jset_str(c.out, "sheet", sh.name)
	kit.jset_str(c.out, "ref", addr_name(a))
	kit.jset_str(c.out, "input", cell == nil ? "" : cell.input)
	kit.jset_bool(c.out, "formula", cell != nil && cell.ast != nil)
	v := cell == nil ? Value{} : cell.val
	put_value(c.out, v)
	kit.jset_str(c.out, "formatted", cell == nil ? "" : format_value(v, cell.fmt))
	return kit.EXIT_OK
}

@(private = "file")
cmd_cells :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	spec := kit.cli_str(c, "range")
	sh, rest, found := pick_sheet(app, spec, kit.cli_str(c, "sheet"))
	if !found {
		return no_sheet(c, kit.cli_str(c, "sheet"))
	}
	rect := Rect_I{0, 0, max(sh.max_row, 0), max(sh.max_col, 0)}
	if rest != "" {
		colon := strings.index_byte(rest, ':')
		if colon < 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a range like A1:D9", rest)
		}
		a, a_ok := ref_parse(rest[:colon])
		b, b_ok := ref_parse(rest[colon + 1:])
		if !a_ok || !b_ok || a.row == NO_ROW || b.row == NO_ROW {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a range like A1:D9", rest)
		}
		rect = rect_norm({a.row, a.col}, {b.row, b.col})
	}
	kit.jset_str(c.out, "sheet", sh.name)
	kit.jset_str(
		c.out,
		"range",
		fmt.tprintf("%s:%s", addr_name({rect.r0, rect.c0}), addr_name({rect.r1, rect.c1})),
	)
	want_empty := kit.cli_bool(c, "empty")
	arr := kit.jarr()
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			a := Addr{row, col}
			if !want_empty && cell_at(sh, a) == nil {
				continue
			}
			kit.jpush(arr, cell_json(sh, a))
		}
	}
	kit.jset(c.out, "cells", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_eval :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	sh, _, found := pick_sheet(app, "", kit.cli_str(c, "sheet"))
	if !found {
		return no_sheet(c, kit.cli_str(c, "sheet"))
	}
	f := kit.cli_str(c, "formula")
	kit.jset_str(c.out, "formula", f)
	kit.jset_str(c.out, "sheet", sh.name)

	// Evaluated in a scratch cell well past anything the book uses, then
	// removed again: this is the real evaluator on the real book, not a
	// second implementation that could disagree with the grid. `read` means
	// what it says — the book is never written back.
	scratch := Addr{sh.max_row + 4, sh.max_col + 4}
	set_input(sh, scratch, f)
	book_recalc_all(app.book)
	cell := cell_at(sh, scratch)
	v := cell == nil ? Value{} : cell.val
	put_value(c.out, v)
	return kit.EXIT_OK
}

@(private = "file")
cmd_set :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	sh, rest, found := pick_sheet(app, kit.cli_str(c, "cell"), "")
	if !found {
		return no_sheet(c, kit.cli_str(c, "cell"))
	}
	r, good := ref_parse(rest)
	if !good || r.row == NO_ROW {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a cell reference", rest)
	}
	a := Addr{r.row, r.col}
	before := cell_at(sh, a)
	was := before == nil ? "" : strings.clone(before.input, context.temp_allocator)

	set_input(sh, a, kit.cli_str(c, "value"))
	book_recalc_all(app.book)
	cell := cell_at(sh, a)
	v := cell == nil ? Value{} : cell.val

	out := kit.cli_str(c, "out")
	if out == "" {
		out = src
	}
	kit.jset_str(c.out, "path", out)
	kit.jset_str(c.out, "sheet", sh.name)
	kit.jset_str(c.out, "ref", addr_name(a))
	kit.jset_str(c.out, "input", cell == nil ? "" : cell.input)
	kit.jset_str(c.out, "was", was)
	put_value(c.out, v)
	kit.jset_str(c.out, "formatted", cell == nil ? "" : format_value(v, cell.fmt))

	// A dry run has done the whole computation and reports exactly what the
	// real run would write; it simply does not write it.
	if c.dry_run {
		kit.jset_bool(c.out, "written", false)
		return kit.EXIT_OK
	}
	if !write_book(app, out) {
		kit.jset_bool(c.out, "written", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", out)
	}
	kit.jset_bool(c.out, "written", true)
	return kit.EXIT_OK
}

// write_book is the one writer, shared by `set` and `export`, so the format is
// decided by the extension in exactly one place.
@(private = "file")
write_book :: proc(app: ^App, out: string) -> bool {
	switch {
	case strings.has_suffix(out, ".xlsx"):
		return xlsx_write_book(app.book, out)
	case strings.has_suffix(out, ".csv"), strings.has_suffix(out, ".tsv"):
		rect := Rect_I{0, 0, max(app.sh.max_row, 0), max(app.sh.max_col, 0)}
		return csv_write_file(app.sh, out, rect)
	}
	return doc_save_file(app.sh, out, base_name(out), {}, {})
}

@(private = "file")
out_format :: proc(out: string) -> string {
	switch {
	case strings.has_suffix(out, ".xlsx"):
		return "xlsx"
	case strings.has_suffix(out, ".csv"):
		return "csv"
	case strings.has_suffix(out, ".tsv"):
		return "tsv"
	}
	return "sheet.json"
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "in")
	out := kit.cli_str(c, "out")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	n := 0
	for s in app.book.sheets {
		n += len(s.cells)
	}
	kit.jset_str(c.out, "path", out)
	kit.jset_str(c.out, "format", out_format(out))
	kit.jset_int(c.out, "sheets", len(app.book.sheets))
	kit.jset_int(c.out, "cells", n)
	if c.dry_run {
		kit.jset_bool(c.out, "written", false)
		return kit.EXIT_OK
	}
	if !write_book(app, out) {
		kit.jset_bool(c.out, "written", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", out)
	}
	kit.jset_bool(c.out, "written", true)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	kit.jset_str(c.out, "path", path)
	if c.dry_run {
		return kit.EXIT_OK
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, path)
	for s in kit.cli_rest(c) {
		append(&args, s)
	}
	if shot_mode(args[:]) != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render %s", path)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_film :: proc(c: ^kit.Call) -> int {
	prefix := kit.cli_str(c, "prefix")
	kit.jset_str(c.out, "prefix", prefix)
	if c.dry_run {
		return kit.EXIT_OK
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, prefix)
	for s in kit.cli_rest(c) {
		append(&args, s)
	}
	if film_mode(args[:]) != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render %s", prefix)
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Sheet operations
//
// Each one is the very procedure the window's command runs — `book_add_sheet`
// and `book_move_sheet` (as `book_insert_sheet`), `book_move_sheet`,
// `book_rename_sheet`, `book_delete_sheet` — so a 3-D reference behaves the
// same whether its span was rearranged with Ctrl+Shift+PgUp or from a script.
// ---------------------------------------------------------------------------

// commit_book is the tail every mutating command shares: report where it
// goes, honour --dry-run, write through the one writer.
@(private = "file")
commit_book :: proc(c: ^kit.Call, app: ^App, src: string) -> int {
	out := kit.cli_str(c, "out")
	if out == "" {
		out = src
	}
	kit.jset_str(c.out, "path", out)
	if c.dry_run {
		kit.jset_bool(c.out, "written", false)
		return kit.EXIT_OK
	}
	if !write_book(app, out) {
		kit.jset_bool(c.out, "written", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", out)
	}
	kit.jset_bool(c.out, "written", true)
	return kit.EXIT_OK
}

@(private = "file")
put_sheet_list :: proc(c: ^kit.Call, app: ^App) {
	arr := kit.jarr()
	for sh in app.book.sheets {
		kit.jpush(arr, kit.jstr(sh.name))
	}
	kit.jset(c.out, "sheets", arr)
}

// count_inputs_changed compares every formula's text with a snapshot, which
// is how a command reports what a rename or a delete rewrote without each
// book procedure having to count.
@(private = "file")
snapshot_inputs :: proc(bk: ^Book) -> map[^Cell]string {
	m := make(map[^Cell]string, 64, context.temp_allocator)
	for sh in bk.sheets {
		for _, cell in sh.cells {
			if cell.ast != nil {
				m[cell] = strings.clone(cell.input, context.temp_allocator)
			}
		}
	}
	return m
}

@(private = "file")
count_rewritten :: proc(bk: ^Book, before: map[^Cell]string) -> int {
	n := 0
	for sh in bk.sheets {
		for _, cell in sh.cells {
			if was, ok := before[cell]; ok && was != cell.input {
				n += 1
			}
		}
	}
	return n
}

@(private = "file")
cmd_sheet_add :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	at := kit.cli_has(c, "at") ? kit.cli_int(c, "at") : len(app.book.sheets)
	sh := book_insert_sheet(app.book, kit.cli_str(c, "name"), at)
	if sh == nil {
		return kit.cli_failf(c, kit.EXIT_FAILED, "a book holds at most %d sheets", MAX_SHEETS)
	}
	kit.jset_str(c.out, "sheet", sh.name)
	put_sheet_list(c, app)
	kit.jset_int(c.out, "rewritten", 0)
	return commit_book(c, app, src)
}

@(private = "file")
cmd_sheet_move :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	name := kit.cli_str(c, "sheet")
	i := book_find(app.book, name)
	if i < 0 {
		return no_sheet(c, name)
	}
	to := kit.cli_int(c, "index")
	if to < 0 || to >= len(app.book.sheets) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "index %d is outside 0..%d", to, len(app.book.sheets) - 1)
	}
	book_move_sheet(app.book, i, to) // false only when it is already there
	kit.jset_str(c.out, "sheet", app.book.sheets[to].name)
	put_sheet_list(c, app)
	kit.jset_int(c.out, "rewritten", 0)
	return commit_book(c, app, src)
}

@(private = "file")
cmd_sheet_rename :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	name := kit.cli_str(c, "sheet")
	i := book_find(app.book, name)
	if i < 0 {
		return no_sheet(c, name)
	}
	before := snapshot_inputs(app.book)
	if !book_rename_sheet(app.book, i, kit.cli_str(c, "name")) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "cannot rename %s to %q (taken, empty, or holds a colon)", name, kit.cli_str(c, "name"))
	}
	book_recalc_all(app.book)
	kit.jset_str(c.out, "sheet", app.book.sheets[i].name)
	put_sheet_list(c, app)
	kit.jset_int(c.out, "rewritten", count_rewritten(app.book, before))
	return commit_book(c, app, src)
}

@(private = "file")
cmd_sheet_delete :: proc(c: ^kit.Call) -> int {
	src := kit.cli_str(c, "file")
	app, ok := open_book(src)
	if !ok {
		return no_book(c, src)
	}
	name := kit.cli_str(c, "sheet")
	i := book_find(app.book, name)
	if i < 0 {
		return no_sheet(c, name)
	}
	if len(app.book.sheets) <= 1 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "a book needs at least one sheet")
	}
	gone := strings.clone(app.book.sheets[i].name, context.temp_allocator)
	before := snapshot_inputs(app.book)
	book_delete_sheet(app.book, i)
	sync_sheet(app)
	kit.jset_str(c.out, "sheet", gone)
	put_sheet_list(c, app)
	kit.jset_int(c.out, "rewritten", count_rewritten(app.book, before))
	return commit_book(c, app, src)
}
