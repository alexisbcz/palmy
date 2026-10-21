// `sheets --selftest`, 3-D references: `Sheet1:Sheet3!A1` and
// `SUM(Jan:Mar!B2:C3)`.
//
// The assertions that matter are the ones about *order*. A 3-D reference is
// not a list of sheets, it is every sheet between two ends as the book is
// arranged right now, so the tests insert a sheet inside the span, move one
// out, move an end past the other, delete one from the middle and delete each
// end — and check the number after each, against what Excel and LibreOffice
// document for the same operation.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// span_book is Jan, Feb, Mar, Summary, with A1 = 1, 2, 3 on the months and a
// 2x2 block at B1:C2 holding 10x the month number, so every total is easy to
// check by eye: SUM(Jan:Mar!A1) = 6, SUM(Jan:Mar!B1:C2) = 4 * 60 = 240.
@(private = "file")
span_book :: proc() -> ^Book {
	b := bk_make("Jan", "Feb", "Mar", "Summary")
	for m in 0 ..< 3 {
		s := b.sheets[m]
		put(s, "A1", fmt.tprintf("%d", m + 1))
		for a in ([?]string{"B1", "C1", "B2", "C2"}) {
			put(s, a, fmt.tprintf("%d", 10 * (m + 1)))
		}
	}
	return b
}

@(private = "file")
order_is :: proc(b: ^Book, want: ..string) -> bool {
	if len(b.sheets) != len(want) {
		return false
	}
	for sh, i in b.sheets {
		if sh.name != want[i] {
			return false
		}
	}
	return true
}

t_spans :: proc(tc: ^TC) {
	// --- syntax: the lexer, the parser and the printer ---------------------
	exp_src(tc, "SUM(Sheet1:Sheet3!A1)", "=SUM(Sheet1:Sheet3!A1)")
	exp_src(tc, "SUM(Sheet1:Sheet3!A1:B2)", "=SUM(Sheet1:Sheet3!A1:B2)")
	exp_src(tc, "SUM(Sheet1:Sheet3!$A$1:B$2)", "=SUM(Sheet1:Sheet3!$A$1:B$2)")
	exp_src(tc, "sum(jan:mar!b2)", "=SUM(jan:mar!B2)")
	exp_src(tc, "SUM(Jan:Mar!A:A)", "=SUM(Jan:Mar!A:A)")
	exp_src(tc, "SUM(Jan:Mar!1:2)", "=SUM(Jan:Mar!1:2)")
	// Names that need quotes put the whole span in one pair, Excel's form.
	exp_src(tc, "SUM('Jan 2026:Mar 2026'!B2)", "=SUM('Jan 2026:Mar 2026'!B2)")
	exp_src(tc, "SUM('Q1:Q4'!A1)", "=SUM('Q1:Q4'!A1)")
	exp_src(tc, "SUM('It''s:Mar'!A1)", "=SUM('It''s:Mar'!A1)")
	// A quoted span of two plain names comes back bare.
	exp_src(tc, "SUM('Jan:Mar'!A1)", "=SUM(Jan:Mar!A1)")
	// A span of one sheet is an ordinary reference.
	exp_src(tc, "Feb:feb!A1", "=Feb!A1")
	// A cell range is still a cell range: `A1:B2` never turns 3-D.
	exp_src(tc, "SUM(A1:B2)", "=SUM(A1:B2)")
	exp_src(tc, "SUM(Data!A1:B2)", "=SUM(Data!A1:B2)")
	exp_bad(tc, "SUM(Jan:Mar!)")
	exp_bad(tc, "SUM('Jan:'!A1)")
	exp_bad(tc, "SUM(':Mar'!A1)")
	exp_bad(tc, "Jan:Mar!A")
	// Copying moves the cells, never the sheets.
	exp_offset(tc, "=SUM(Jan:Mar!A1)", 1, 1, "=SUM(Jan:Mar!B2)")
	exp_offset(tc, "=SUM(Jan:Mar!$A$1:A2)", 2, 0, "=SUM(Jan:Mar!$A$1:A4)")

	// --- evaluation --------------------------------------------------------
	{
		b := span_book()
		defer bk_free(b)
		sm := b.sheets[3]
		put(sm, "A1", "=SUM(Jan:Mar!A1)")
		put(sm, "A2", "=SUM(Jan:Mar!B1:C2)")
		put(sm, "A3", "=AVERAGE(Jan:Mar!A1)")
		put(sm, "A4", "=COUNT(Jan:Mar!A1:C2)")
		put(sm, "A5", "=MAX(Jan:Mar!A1)")
		put(sm, "A6", "=MIN(Jan:Mar!B1:C2)")
		put(sm, "A7", "=PRODUCT(Jan:Mar!A1)")
		put(sm, "A8", "=STDEV(Jan:Mar!A1)")
		put(sm, "A9", "=COUNTA(Jan:Mar!A1:C2)")
		put(sm, "A10", "=SUM(Mar:Jan!A1)") // ends written backwards
		put(sm, "A11", "=SUM(Jan:Mar!A1,100)") // mixed with a scalar
		put(sm, "A12", "=Jan:Mar!A1") // one value wanted: Excel says #VALUE!
		put(sm, "A13", "=Jan:Mar!A1+1")
		put(sm, "A14", "=SUM(Jan:Nope!A1)") // an end that does not exist
		put(sm, "A15", "=SUM(Jan:Mar!A:A)")
		put(sm, "A16", "=SUM(Jan:Feb!A1)*10+SUM(Feb:Mar!A1)")
		book_recalc(b)
		at_num(tc, sm, "A1", 6)
		at_num(tc, sm, "A2", 240)
		at_num(tc, sm, "A3", 2)
		at_num(tc, sm, "A4", 15)
		at_num(tc, sm, "A5", 3)
		at_num(tc, sm, "A6", 10)
		at_num(tc, sm, "A7", 6)
		at_num(tc, sm, "A8", 1)
		at_num(tc, sm, "A9", 15)
		at_num(tc, sm, "A10", 6)
		at_num(tc, sm, "A11", 106)
		at_err(tc, sm, "A12", .Value)
		at_err(tc, sm, "A13", .Value)
		at_err(tc, sm, "A14", .Ref)
		at_num(tc, sm, "A15", 6)
		at_num(tc, sm, "A16", 35)

		// Text and errors inside the span follow the one-sheet rules: text
		// is skipped by SUM, an error propagates.
		put(b.sheets[1], "A1", "two")
		book_recalc(b)
		at_num(tc, sm, "A1", 4)
		at_num(tc, sm, "A9", 15)
		put(b.sheets[1], "A1", "=1/0")
		book_recalc(b)
		at_err(tc, sm, "A1", .Div0)

		// The graph sees every sheet in the span: an edit on the middle one
		// recomputes the total without a full pass.
		put(b.sheets[1], "A1", "20")
		book_recalc(b)
		at_num(tc, sm, "A1", 24)
		put(b.sheets[2], "C2", "1000")
		book_recalc(b)
		at_num(tc, sm, "A2", 240 - 30 + 1000)
	}

	// --- order: insert, move, delete ----------------------------------------
	{
		b := span_book()
		defer bk_free(b)
		sm := b.sheets[3]
		put(sm, "A1", "=SUM(Jan:Mar!A1)")
		put(sm, "A2", "=SUM(Jan:Mar!B1:C2)")
		book_recalc(b)
		at_num(tc, sm, "A1", 6)

		// A sheet inserted between the ends joins the span.
		x := book_insert_sheet(b, "Extra", 1)
		ok_mark(tc, x != nil && order_is(b, "Jan", "Extra", "Feb", "Mar", "Summary"), "a sheet is inserted at a position")
		put(x, "A1", "100")
		put(x, "B1", "1")
		book_recalc(b)
		at_num(tc, sm, "A1", 106)
		at_num(tc, sm, "A2", 241)
		// One added at the end, outside the span, does not.
		y := book_insert_sheet(b, "After", len(b.sheets))
		put(y, "A1", "1000")
		book_recalc(b)
		at_num(tc, sm, "A1", 106)

		// Moved out, it leaves; moved back in, it rejoins — with no formula
		// rewritten either way.
		book_move_sheet(b, 1, len(b.sheets) - 1)
		ok_mark(tc, order_is(b, "Jan", "Feb", "Mar", "Summary", "After", "Extra"), "a sheet moves to the end")
		at_num(tc, sm, "A1", 6)
		book_move_sheet(b, len(b.sheets) - 1, 2)
		at_num(tc, sm, "A1", 106)
		at_input(tc, sm, "A1", "=SUM(Jan:Mar!A1)")
		book_move_sheet(b, 2, 4) // Extra out again: Jan Feb Mar Summary Extra After
		at_num(tc, sm, "A1", 6)

		// Moving an *end* re-spans: Mar to the front leaves Mar, Jan as the
		// span, so Feb drops out (3 + 1).
		book_move_sheet(b, 2, 0)
		ok_mark(tc, order_is(b, "Mar", "Jan", "Feb", "Summary", "Extra", "After"), "an end moves to the front")
		at_num(tc, sm, "A1", 4)
		// Moving it to the far side of Feb widens the span again.
		book_move_sheet(b, 0, 2)
		at_num(tc, sm, "A1", 6)
		// Moving Jan past Mar writes the ends backwards; the span is still
		// whatever lies between them, which no longer includes Feb (3 + 1).
		book_move_sheet(b, 0, 2) // Feb Mar Jan ...
		ok_mark(tc, order_is(b, "Feb", "Mar", "Jan", "Summary", "Extra", "After"), "an end moves past the other")
		at_num(tc, sm, "A1", 4)
		book_move_sheet(b, 2, 0) // back to Jan Feb Mar
		at_num(tc, sm, "A1", 6)

		// A sheet deleted from the middle simply stops being in the span.
		book_delete_sheet(b, book_find(b, "Feb"))
		at_num(tc, sm, "A1", 4)
		at_input(tc, sm, "A1", "=SUM(Jan:Mar!A1)")
	}
	{
		// Deleting an end narrows the span to the next sheet inward, and
		// the formula says so.
		b := span_book()
		defer bk_free(b)
		sm := b.sheets[3]
		put(sm, "A1", "=SUM(Jan:Mar!A1)")
		put(sm, "A2", "=SUM(Mar:Jan!B1:C2)")
		put(sm, "A3", "=SUM(Jan:Feb!A1)")
		put(sm, "A4", "=Jan!A1+Mar!A1")
		book_recalc(b)
		ok_mark(tc, book_fix_spans_for_delete(b, -1) == 0, "nothing is rewritten when no end is deleted")
		book_delete_sheet(b, book_find(b, "Jan"))
		at_input(tc, sm, "A1", "=SUM(Feb:Mar!A1)")
		at_num(tc, sm, "A1", 5)
		at_input(tc, sm, "A2", "=SUM(Feb:Mar!B1:C2)")
		at_num(tc, sm, "A2", 200)
		// A span left with one sheet becomes an ordinary reference.
		at_input(tc, sm, "A3", "=SUM(Feb!A1)")
		at_num(tc, sm, "A3", 2)
		// A plain reference to the deleted sheet is #REF!, as before.
		at_err(tc, sm, "A4", .Ref)
		// The last end: Mar goes, Feb:Mar becomes Feb.
		book_delete_sheet(b, book_find(b, "Mar"))
		at_input(tc, sm, "A1", "=SUM(Feb!A1)")
		at_num(tc, sm, "A1", 2)
	}
	{
		// Rename rewrites both ends; a row insert on one sheet of the span
		// leaves the reference alone; a span that includes the formula's own
		// cell is a cycle.
		b := span_book()
		defer bk_free(b)
		sm := b.sheets[3]
		put(sm, "A1", "=SUM(Jan:Mar!A1)")
		put(sm, "A2", "=SUM(Jan:Summary!A2)")
		put(sm, "B1", "=SUM(Jan:Summary!A9)")
		book_recalc(b)
		ok_mark(tc, book_rename_sheet(b, 0, "January"), "an end is renamed")
		ok_mark(tc, book_rename_sheet(b, 2, "March 2026"), "the other end is renamed to a name that needs quotes")
		at_input(tc, sm, "A1", "=SUM('January:March 2026'!A1)")
		book_recalc_all(b)
		at_num(tc, sm, "A1", 6)
		ok_mark(tc, !book_rename_sheet(b, 1, "Feb:Mar"), "a sheet name may not hold a colon")

		insert_rows(b.sheets[1], 0, 1)
		at_input(tc, sm, "A1", "=SUM('January:March 2026'!A1)")
		book_recalc_all(b)
		at_num(tc, sm, "A1", 4) // Feb's 2 moved to A2

		at_err(tc, sm, "A2", .Circ)
		at_num(tc, sm, "B1", 0) // A9 is empty everywhere: no cycle
	}

	// --- the native document and .xlsx carry it ----------------------------
	{
		b := span_book()
		defer bk_free(b)
		sm := b.sheets[3]
		put(sm, "A1", "=SUM(Jan:Mar!A1)")
		put(sm, "A2", "=AVERAGE('Jan:Mar'!B1:C2)")
		book_recalc(b)

		text := doc_save_string(b.sheets[0], "spans", {}, {}, context.temp_allocator)
		b2 := book_new()
		defer bk_free(b2)
		_, _, _, ok := doc_load_string(b2.sheets[0], text)
		ok_mark(tc, ok, "a book with 3-D references saves and loads")
		s2 := b2.sheets[3]
		at_input(tc, s2, "A1", "=SUM(Jan:Mar!A1)")
		at_num(tc, s2, "A1", 6)
		at_num(tc, s2, "A2", 20)

		raw := xlsx_book_bytes(b, context.temp_allocator)
		files, _ := zip_read(raw, context.temp_allocator)
		part, found := zip_find(files, "xl/worksheets/sheet4.xml")
		ok_mark(tc, found && strings.contains(string(part), "<f>SUM(Jan:Mar!A1)</f>"), "the .xlsx formula is Excel's 3-D spelling")
		b3 := book_new()
		defer bk_free(b3)
		rok, _, _ := xlsx_read_book_bytes(b3, raw)
		ok_mark(tc, rok, "and the workbook imports")
		s3 := b3.sheets[3]
		at_input(tc, s3, "A1", "=SUM(Jan:Mar!A1)")
		at_num(tc, s3, "A1", 6)
		at_num(tc, s3, "A2", 20)
	}

	// --- the window's commands, and undo ----------------------------------
	{
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		for name in ([?]string{"Feb", "Mar", "Summary"}) {
			book_add_sheet(app.book, name)
		}
		book_rename_sheet(app.book, 0, "Jan")
		for m in 0 ..< 3 {
			put(app.book.sheets[m], "A1", fmt.tprintf("%d", m + 1))
		}
		put(app.book.sheets[3], "A1", "=SUM(Jan:Mar!A1)")
		book_recalc_all(app.book)
		use_sheet(app, 2) // Mar
		run_cmd(app, .Sheet_Move_Left)
		ok_mark(tc, order_is(app.book, "Jan", "Mar", "Feb", "Summary"), "Move sheet left moves the end inward")
		at_num(tc, app.book.sheets[3], "A1", 4)
		run_cmd(app, .Undo)
		ok_mark(tc, order_is(app.book, "Jan", "Feb", "Mar", "Summary"), "and undo puts it back")
		at_num(tc, app.book.sheets[3], "A1", 6)
		use_sheet(app, 0)
		run_cmd(app, .Sheet_Delete)
		at_input(tc, app.book.sheets[2], "A1", "=SUM(Feb:Mar!A1)")
		run_cmd(app, .Undo)
		at_input(tc, app.book.sheets[3], "A1", "=SUM(Jan:Mar!A1)")
		at_num(tc, app.book.sheets[3], "A1", 6)
	}

	{
		// A span whose end did not exist yet resolves the moment the sheet
		// is added from the window.
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		put(app.book.sheets[0], "A1", "5")
		put(app.book.sheets[0], "B1", "=SUM(Sheet1:Sheet2!A1)")
		book_recalc_all(app.book)
		at_err(tc, app.book.sheets[0], "B1", .Ref)
		run_cmd(app, .Sheet_Add)
		ok_mark(tc, len(app.book.sheets) == 2 && app.book.sheets[1].name == "Sheet2", "Add a sheet appends Sheet2")
		at_num(tc, app.book.sheets[0], "B1", 5)
	}

	// --- the same operations from the command line --------------------------
	{
		dir := fmt.tprintf("/tmp/palmy-sheets-span-%d", os.get_pid())
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", dir))
		b := span_book()
		put(b.sheets[3], "A1", "=SUM(Jan:Mar!A1)")
		book_recalc(b)
		path := fmt.tprintf("%s/spans.sheet.json", dir)
		ok_mark(tc, doc_save_file(b.sheets[0], path, "spans", {}, {}), "a fixture book is written")
		bk_free(b)

		out, code := cli_run("get", "Summary!A1", path, "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"value": "6"`), "sheets get reads a 3-D total")
		out, code = cli_run("sheet-add", path, "Extra", "--at", "1", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"Extra"`), "sheet-add inserts inside the span")
		out, code = cli_run("set", path, "Extra!A1", "100", "--json")
		out, code = cli_run("get", "Summary!A1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "106"`), "and the total takes it in")
		out, code = cli_run("sheet-move", path, "Extra", "4", "--json")
		ok_mark(tc, code == 0, "sheet-move exits 0")
		out, code = cli_run("get", "Summary!A1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "6"`), "and moved out, it leaves the total")
		out, code = cli_run("sheet-delete", path, "Jan", "--json")
		ok_mark(tc, code == 4, "sheet-delete refuses without --yes")
		out, code = cli_run("sheet-delete", path, "Jan", "--yes", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"rewritten": 1`), "with it, it deletes and reports the one formula it narrowed")
		out, code = cli_run("get", "Summary!A1", path, "--json")
		ok_mark(tc, strings.contains(out, `"input": "=SUM(Feb:Mar!A1)"`) && strings.contains(out, `"value": "5"`), "and the narrowed formula is what the next reader sees")
		out, code = cli_run("sheet-rename", path, "Mar", "Q:1", "--json")
		ok_mark(tc, code == 2, "a name with a colon is a usage error")
		out, code = cli_run("sheet-rename", path, "Mar", "March", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"rewritten": 1`), "sheet-rename rewrites the span's end")
		out, code = cli_run("eval", "=SUM(Feb:March!A1)*2", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "10"`), "and eval agrees with the grid")
	}
}
