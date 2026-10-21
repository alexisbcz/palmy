// `sheets --selftest`, sheet-local names.
//
// The rule under test is scope resolution: a formula looks in its own
// sheet's names first and the book's second, so a local `Rate` shadows the
// workbook `Rate` on that sheet and nowhere else, and another sheet's local
// name is reached only by qualifying it, `Q2!Rate`. Then that the scope
// survives everything a book goes through: rename, move, delete, undo, the
// native file, .xlsx (`localSheetId`), and the command line.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// names_book: Data!A1 = 0.1 is the workbook Rate; Q2 has its own Rate at
// Q2!B1 = 0.3; Q1!B1 = 0.2 is not named at all.
@(private = "file")
names_book :: proc() -> ^Book {
	b := bk_make("Data", "Q1", "Q2")
	put(b.sheets[0], "A1", "0.1")
	put(b.sheets[1], "B1", "0.2")
	put(b.sheets[2], "B1", "0.3")
	book_set_name(b, "Rate", "Data", {0, 0, 0, 0})
	book_set_name(b, "Rate", "Q2", {0, 1, 0, 1}, true, "Q2")
	return b
}

t_local_names :: proc(tc: ^TC) {
	// --- syntax ------------------------------------------------------------
	// Q2 is also a cell, so the sheet keeps its quotes, as in Excel.
	exp_src(tc, "Q2!Rate*2", "='Q2'!Rate*2")
	exp_src(tc, "Spring!Rate*2", "=Spring!Rate*2")
	exp_src(tc, "SUM('My Sheet'!Units)", "=SUM('My Sheet'!Units)")
	exp_src(tc, "Spring!my_rate.2", "=Spring!my_rate.2")
	exp_bad(tc, "Q2!SUM(1)") // a function is not on a sheet
	exp_bad(tc, "Jan:Mar!Rate") // a name does not span sheets
	exp_bad(tc, "Q2!ZZZZ1") // shaped like a cell, past the last column
	ok_mark(tc, !name_is_valid("ZZZZ1"), "a name shaped like a cell is refused")
	ok_mark(tc, !name_is_valid("R1C1"), "an R1C1 address is refused as a name")
	ok_mark(tc, name_is_valid("Rate") && name_is_valid("R1C1x") && name_is_valid("Rates"), "ordinary names pass")

	// --- resolution --------------------------------------------------------
	{
		b := names_book()
		defer bk_free(b)
		d, q1, q2 := b.sheets[0], b.sheets[1], b.sheets[2]
		ok_mark(tc, !book_set_name(b, "X", "Data", {0, 0, 0, 0}, true, "Nowhere"), "a name cannot be scoped to a sheet that is not there")
		_, has_wb := book_get_name(b, "rate")
		_, has_q2 := book_get_name(b, "rate", "q2")
		_, has_q1 := book_get_name(b, "rate", "Q1")
		ok_mark(tc, has_wb && has_q2 && !has_q1, "the same name exists in two scopes, and only those")

		put(d, "C1", "=Rate")
		put(q1, "C1", "=Rate")
		put(q2, "C1", "=Rate")
		put(q1, "C2", "=Q2!Rate")
		put(q1, "C3", "=Data!Rate") // Data has no local Rate: qualified means local only
		put(q1, "C4", "=Nowhere!Rate")
		put(q2, "C2", "=Q2!Rate+Rate") // qualifying your own sheet is fine
		put(q1, "C5", "=SUM(Rate,Q2!Rate)")
		book_recalc_all(b)
		at_num(tc, d, "C1", 0.1)
		at_num(tc, q1, "C1", 0.1)
		at_num(tc, q2, "C1", 0.3) // the local shadows the book's
		at_num(tc, q1, "C2", 0.3)
		at_err(tc, q1, "C3", .Name)
		at_err(tc, q1, "C4", .Ref)
		at_num(tc, q2, "C2", 0.6)
		at_num(tc, q1, "C5", 0.4)

		nd, local, ok := book_resolve_name(b, "RATE", 2)
		ok_mark(tc, ok && local && nd.sheet == "Q2", "Q2 resolves Rate to its own")
		nd, local, ok = book_resolve_name(b, "RATE", 1)
		ok_mark(tc, ok && !local && nd.sheet == "Data", "Q1 resolves it to the book's")

		// Each is a dependency in its own scope: changing the local target
		// recomputes the formulas that see it and not the ones that do not.
		put(q2, "B1", "0.5")
		book_recalc(b)
		at_num(tc, q2, "C1", 0.5)
		at_num(tc, q1, "C2", 0.5)
		at_num(tc, q1, "C1", 0.1)
		put(d, "A1", "0.7")
		book_recalc(b)
		at_num(tc, q1, "C1", 0.7)
		at_num(tc, q2, "C1", 0.5)

		// Dropping the local one uncovers the book's.
		ok_mark(tc, book_drop_name(b, "Rate", "Q2"), "the local name is dropped")
		book_recalc_all(b)
		at_num(tc, q2, "C1", 0.7)
		at_err(tc, q1, "C2", .Name)
		ok_mark(tc, !book_drop_name(b, "Rate", "Q2"), "and is not there to drop twice")

		// name_drop_spec, the window's and the CLI's door: bare means what
		// this sheet sees, qualified means that sheet's.
		book_set_name(b, "Rate", "Q2", {0, 1, 0, 1}, true, "Q2")
		scope, _, dropped := name_drop_spec(b, "rate", 2)
		ok_mark(tc, dropped && scope == "Q2", "a bare name dropped on Q2 is Q2's own")
		_, still := book_get_name(b, "Rate")
		ok_mark(tc, still, "and the book's survives it")
		book_set_name(b, "Rate", "Q2", {0, 1, 0, 1}, true, "Q2")
		scope, _, dropped = name_drop_spec(b, "rate", 1)
		ok_mark(tc, dropped && scope == "", "dropped on Q1 it is the book's")
		scope, _, dropped = name_drop_spec(b, "'q2'!RATE", -1)
		ok_mark(tc, dropped && scope == "Q2", "qualified, it is that sheet's, in the sheet's own spelling")
	}

	// --- rename, move, delete -----------------------------------------------
	{
		b := names_book()
		defer bk_free(b)
		q1 := b.sheets[1]
		book_set_name(b, "Base", "Data", {0, 0, 0, 0}, true, "Q1") // a local name pointing elsewhere
		put(q1, "C1", "=Q2!Rate")
		put(q1, "C2", "=Base*10")
		book_recalc_all(b)
		at_num(tc, q1, "C2", 1)

		ok_mark(tc, book_rename_sheet(b, 2, "Quarter 2"), "the scope sheet is renamed")
		at_input(tc, q1, "C1", "='Quarter 2'!Rate")
		_, moved := book_get_name(b, "Rate", "Quarter 2")
		ok_mark(tc, moved, "and its local name went with it")
		ok_mark(tc, book_rename_sheet(b, 0, "Inputs"), "the target sheet is renamed")
		nd, _ := book_get_name(b, "Base", "Q1")
		ok_mark(tc, nd.sheet == "Inputs", "and a local name's target follows it")
		book_recalc_all(b)
		at_num(tc, q1, "C1", 0.3)
		at_num(tc, q1, "C2", 1)

		book_move_sheet(b, 2, 0)
		at_num(tc, b.sheets[book_find(b, "Q1")], "C1", 0.3)

		// Deleting a sheet takes its local names with it, and a reference
		// that qualified them becomes #REF!, the sheet being gone.
		book_delete_sheet(b, book_find(b, "Quarter 2"))
		q1 = b.sheets[book_find(b, "Q1")]
		at_err(tc, q1, "C1", .Ref)
		at_num(tc, q1, "C2", 1)
	}

	// --- names follow the cells they name ----------------------------------
	{
		b := names_book()
		defer bk_free(b)
		q1, q2 := b.sheets[1], b.sheets[2]
		put(q1, "C1", "=Rate")
		put(q2, "C1", "=Rate")
		book_recalc_all(b)
		insert_rows(b.sheets[0], 0, 2) // above the workbook Rate on Data
		nd, _ := book_get_name(b, "Rate")
		ok_mark(tc, nd.rect == Rect_I{2, 0, 2, 0}, "a row inserted above a workbook name's cell moves the name")
		at_num(tc, q1, "C1", 0.1)
		insert_cols(q2, 0, 1) // before the local Rate on Q2
		nd, _ = book_get_name(b, "Rate", "Q2")
		ok_mark(tc, nd.rect == Rect_I{0, 2, 0, 2}, "so does a column inserted before a local one")
		at_num(tc, b.sheets[2], "D1", 0.3)
		nd, _ = book_get_name(b, "Rate")
		ok_mark(tc, nd.rect == Rect_I{2, 0, 2, 0}, "and an edit on another sheet leaves a name alone")
		delete_cols(q2, 2, 1)
		_, still := book_get_name(b, "Rate", "Q2")
		ok_mark(tc, !still, "a name whose cells are all deleted goes")
		book_recalc_all(b)
		at_num(tc, b.sheets[2], "C1", 0.1) // and Q2 falls back to the book's
	}

	// --- the native document, undo's snapshot, and .xlsx ---------------------
	{
		b := names_book()
		defer bk_free(b)
		put(b.sheets[2], "C1", "=Rate")
		put(b.sheets[1], "C1", "=Rate")
		book_recalc_all(b)

		text := doc_save_string(b.sheets[0], "names", {}, {}, context.temp_allocator)
		ok_mark(tc, strings.contains(text, `"scope": "Q2"`), "the native file records the scope")
		b2 := book_new()
		defer bk_free(b2)
		_, _, _, ok := doc_load_string(b2.sheets[0], text)
		ok_mark(tc, ok, "and loads")
		_, l2 := book_get_name(b2, "Rate", "Q2")
		_, g2 := book_get_name(b2, "Rate")
		ok_mark(tc, l2 && g2, "with both scopes intact")
		at_num(tc, b2.sheets[2], "C1", 0.3)
		at_num(tc, b2.sheets[1], "C1", 0.1)

		raw := xlsx_book_bytes(b, context.temp_allocator)
		files, _ := zip_read(raw, context.temp_allocator)
		wb, _ := zip_find(files, "xl/workbook.xml")
		ok_mark(tc, strings.contains(string(wb), `<definedName name="RATE" localSheetId="2">&apos;Q2&apos;!$B$1</definedName>`), "the .xlsx scopes the local name with localSheetId")
		ok_mark(tc, strings.contains(string(wb), `<definedName name="RATE">Data!$A$1</definedName>`), "and leaves the book's unscoped")
		b3 := book_new()
		defer bk_free(b3)
		rok, _, _ := xlsx_read_book_bytes(b3, raw)
		ok_mark(tc, rok, "the workbook imports")
		_, l3 := book_get_name(b3, "Rate", "Q2")
		_, g3 := book_get_name(b3, "Rate")
		ok_mark(tc, l3 && g3, "with both scopes intact")
		at_num(tc, b3.sheets[2], "C1", 0.3)
		at_num(tc, b3.sheets[1], "C1", 0.1)

		ok_mark(tc, strings.contains(names_json(b), `"scope":"Q2"`), "the shared (collaboration) document carries the scope too")
	}

	// --- the window's prompts, and undo ------------------------------------
	{
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		book_rename_sheet(app.book, 0, "Data")
		book_add_sheet(app.book, "Q2")
		put(app.book.sheets[0], "A1", "1")
		put(app.book.sheets[1], "A1", "2")
		put(app.book.sheets[1], "B1", "=Rate")
		use_sheet(app, 0)
		app.cur, app.anchor = {0, 0}, {0, 0}
		app.prompt = .Name_Define
		run_prompt(app, "Rate")
		use_sheet(app, 1)
		app.cur, app.anchor = {0, 0}, {0, 0}
		app.prompt = .Name_Define_Local
		run_prompt(app, "Rate")
		at_num(tc, app.book.sheets[1], "B1", 2)
		_, l := book_get_name(app.book, "Rate", "Q2")
		ok_mark(tc, l, "Name the selection, for this sheet only, scopes it to the sheet you are on")
		app.prompt = .Name_Delete
		run_prompt(app, "Rate")
		at_num(tc, app.book.sheets[1], "B1", 1)
		run_cmd(app, .Undo)
		at_num(tc, app.book.sheets[1], "B1", 2)
		_, l = book_get_name(app.book, "Rate", "Q2")
		ok_mark(tc, l, "and undo brings the local name back")
		// `Data!Total` typed into the ordinary prompt scopes it too.
		app.prompt = .Name_Define
		run_prompt(app, "Data!Total")
		_, t := book_get_name(app.book, "Total", "Data")
		ok_mark(tc, t, "a Sheet!Name typed into Name the selection is scoped to that sheet")
	}

	// --- the command line ------------------------------------------------------
	{
		dir := fmt.tprintf("/tmp/palmy-sheets-names-%d", os.get_pid())
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", dir))
		b := bk_make("Data", "Q1", "Q2")
		put(b.sheets[0], "A1", "0.1")
		put(b.sheets[2], "B1", "0.3")
		put(b.sheets[1], "C1", "=Rate")
		put(b.sheets[2], "C1", "=Rate")
		path := fmt.tprintf("%s/names.sheet.json", dir)
		doc_save_file(b.sheets[0], path, "names", {}, {})
		bk_free(b)

		out, code := cli_run("name-set", path, "Rate", "Data!A1", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"scope": ""`), "name-set defines a workbook name")
		out, code = cli_run("name-set", path, "Q2!Rate", "B1", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"scope": "Q2"`) && strings.contains(out, `"target": "'Q2'!B1"`), "Q2!Rate defines a local one, its target on Q2")
		out, code = cli_run("info", path, "--json")
		ok_mark(tc, strings.contains(out, `"scope": "Q2"`), "info lists the scope")
		out, _ = cli_run("get", "Q2!C1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "0.3"`), "Q2 sees its own")
		out, _ = cli_run("get", "Q1!C1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "0.1"`), "Q1 sees the book's")
		out, _ = cli_run("eval", "=Rate", path, "--sheet", "Q2", "--json")
		ok_mark(tc, strings.contains(out, `"value": "0.3"`), "eval on Q2 resolves the local name")
		_, code = cli_run("name-set", path, "Rate", "A1", "--scope", "Nowhere", "--json")
		ok_mark(tc, code == 3, "a scope that is not a sheet exits 3")
		_, code = cli_run("name-set", path, "A1", "B1", "--json")
		ok_mark(tc, code == 2, "a name that reads as a cell exits 2")
		out, code = cli_run("name-delete", path, "Rate", "--scope", "Q2", "--json")
		ok_mark(tc, code == 0, "name-delete drops the local one")
		out, _ = cli_run("get", "Q2!C1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "0.1"`), "and Q2 falls back to the book's")
		_, code = cli_run("name-delete", path, "Q2!Rate", "--json")
		ok_mark(tc, code == 3, "dropping it again exits 3")
	}
}
