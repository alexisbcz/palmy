// `sheets --selftest`, the two things a name can be besides one rectangle on
// one sheet: a 3-D range (`Units` = `Jan:Mar!$B$2`), and `=#REF!`, which is
// what Excel leaves behind when the cells a name covered are deleted.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// span_book: Jan, Feb, Mar each hold a number in B2 (1, 2, 3), Sum reads them.
@(private = "file")
span_book :: proc() -> ^Book {
	b := bk_make("Jan", "Feb", "Mar", "Sum")
	put(b.sheets[0], "B2", "1")
	put(b.sheets[1], "B2", "2")
	put(b.sheets[2], "B2", "3")
	book_set_name(b, "Units", "Jan", {1, 1, 1, 1}, true, "", "Mar")
	return b
}

t_name_spans :: proc(tc: ^TC) {
	// --- reading the spelling ------------------------------------------------
	{
		s, s2, r, abs, bad, ok := parse_name_target("Jan:Mar!$B$2")
		ok_mark(tc, ok && !bad && s == "Jan" && s2 == "Mar" && r == Rect_I{1, 1, 1, 1} && abs, "Jan:Mar!$B$2 reads as a 3-D target")
		s, s2, r, _, _, ok = parse_name_target("'Jan 1:Mar 1'!B2:C3")
		ok_mark(tc, ok && s == "Jan 1" && s2 == "Mar 1" && r == Rect_I{1, 1, 2, 2}, "a quoted span with spaces reads too")
		s, s2, _, _, _, ok = parse_name_target("Data!A1")
		ok_mark(tc, ok && s == "Data" && s2 == "", "an ordinary target has no second sheet")
		_, _, _, _, bad, ok = parse_name_target("#REF!")
		ok_mark(tc, ok && bad, "#REF! is a target: the broken one")
		_, _, _, _, bad, ok = parse_name_target("=Sheet1!#REF!")
		ok_mark(tc, ok && bad, "and so is Sheet1!#REF!, the other way Excel writes it")
		_, _, _, _, _, ok = parse_name_target(":Mar!B2")
		ok_mark(tc, !ok, "a span with an end missing is refused")
	}

	// --- evaluation --------------------------------------------------------
	{
		b := span_book()
		defer bk_free(b)
		sum := b.sheets[3]
		put(sum, "A1", "=SUM(Units)")
		put(sum, "A2", "=AVERAGE(Units)")
		put(sum, "A3", "=PRODUCT(Units)")
		put(sum, "A4", "=Units")
		put(sum, "A5", "=COUNT(Units,Jan!B2)")
		book_recalc_all(b)
		at_num(tc, sum, "A1", 6)
		at_num(tc, sum, "A2", 2)
		at_num(tc, sum, "A3", 6)
		at_err(tc, sum, "A4", .Value) // a 3-D range where one value is wanted
		at_num(tc, sum, "A5", 4)
		nd, _ := book_get_name(b, "Units")
		ok_mark(tc, name_target(b, nd) == "Jan:Mar!$B$2", fmt.tprintf("the target prints as a span (%s)", name_target(b, nd)))

		// The graph sees every sheet of the span.
		put(b.sheets[1], "B2", "20")
		book_recalc_all(b)
		at_num(tc, sum, "A1", 24)

		// A sheet moved in between the ends joins it, as a 3-D reference's does.
		ins := book_insert_sheet(b, "Feb2", 2)
		put(ins, "B2", "100")
		book_recalc_all(b)
		at_num(tc, b.sheets[book_find(b, "Sum")], "A1", 124)

		// A row inserted on one sheet of the span moves nothing.
		insert_rows(b.sheets[0], 0, 1)
		nd, _ = book_get_name(b, "Units")
		ok_mark(tc, nd.rect == Rect_I{1, 1, 1, 1} && !nd.bad, "a one-sheet row insert leaves a 3-D name where it was")

		// Renaming an end renames the name's end.
		book_rename_sheet(b, book_find(b, "Mar"), "Q1 end")
		nd, _ = book_get_name(b, "Units")
		ok_mark(tc, nd.sheet2 == "Q1 end", "renaming the far end follows it")
		ok_mark(tc, name_target(b, nd) == "'Jan:Q1 end'!$B$2", fmt.tprintf("and quotes the whole span (%s)", name_target(b, nd)))

		// Deleting an end narrows the span, the same rule as a formula's.
		book_delete_sheet(b, book_find(b, "Q1 end"))
		nd, _ = book_get_name(b, "Units")
		ok_mark(tc, nd.sheet == "Jan" && nd.sheet2 == "Feb2", "deleting the far end narrows the name to the next sheet in")
		book_delete_sheet(b, book_find(b, "Jan"))
		book_delete_sheet(b, book_find(b, "Feb"))
		nd, _ = book_get_name(b, "Units")
		ok_mark(tc, nd.sheet == "Feb2" && nd.sheet2 == "" && !nd.bad, "and a span down to one sheet is an ordinary name")
		book_recalc_all(b)
		at_num(tc, b.sheets[book_find(b, "Sum")], "A1", 100)
		at_num(tc, b.sheets[book_find(b, "Sum")], "A4", 100)
	}

	// --- =#REF! ----------------------------------------------------------------
	{
		b := bk_make("Data", "Calc")
		defer bk_free(b)
		put(b.sheets[0], "B2", "7")
		put(b.sheets[1], "B2", "8")
		book_set_name(b, "Rate", "Data", {1, 1, 1, 1})
		book_set_name(b, "Other", "Calc", {1, 1, 1, 1})
		put(b.sheets[1], "A1", "=Rate*2")
		put(b.sheets[1], "A2", "=SUM(Rate)")
		put(b.sheets[0], "A1", "=Other+1")
		book_recalc_all(b)
		at_num(tc, b.sheets[1], "A1", 14)

		delete_rows(b.sheets[0], 1, 1)
		nd, still := book_get_name(b, "Rate")
		ok_mark(tc, still && nd.bad, "deleting the row a name covered leaves it as =#REF!")
		book_recalc_all(b)
		at_err(tc, b.sheets[1], "A1", .Ref)
		at_err(tc, b.sheets[1], "A2", .Ref)
		at_input(tc, b.sheets[1], "A1", "=Rate*2") // the formula itself is untouched

		// The broken name survives the file, undo's snapshot and .xlsx.
		text := doc_save_string(b.sheets[0], "refs", {}, {}, context.temp_allocator)
		ok_mark(tc, strings.contains(text, `"range": "#REF!"`), "the native file writes #REF! as the range")
		b2 := book_new()
		defer bk_free(b2)
		doc_load_string(b2.sheets[0], text)
		nd2, has2 := book_get_name(b2, "Rate")
		ok_mark(tc, has2 && nd2.bad, "and reads it back as a broken name")
		at_err(tc, b2.sheets[1], "A1", .Ref)

		raw := xlsx_book_bytes(b, context.temp_allocator)
		files, _ := zip_read(raw, context.temp_allocator)
		wb, _ := zip_find(files, "xl/workbook.xml")
		ok_mark(tc, strings.contains(string(wb), `<definedName name="RATE">#REF!</definedName>`), "the .xlsx writes it as Excel does")
		b3 := book_new()
		defer bk_free(b3)
		xlsx_read_book_bytes(b3, raw)
		nd3, has3 := book_get_name(b3, "Rate")
		ok_mark(tc, has3 && nd3.bad, "and reads it back")

		// Deleting the sheet a name points at breaks it the same way.
		book_delete_sheet(b, book_find(b, "Calc"))
		nd, still = book_get_name(b, "Other")
		ok_mark(tc, still && nd.bad, "deleting the sheet a name is on leaves it as =#REF!")
		book_recalc_all(b)
		at_err(tc, b.sheets[0], "A1", .Ref)

		// And redefining it mends it.
		book_set_name(b, "Rate", "Data", {0, 1, 0, 1})
		put(b.sheets[0], "B1", "5")
		put(b.sheets[0], "C1", "=Rate+1")
		book_recalc_all(b)
		at_num(tc, b.sheets[0], "C1", 6)
	}

	// --- files ------------------------------------------------------------------
	{
		b := span_book()
		defer bk_free(b)
		put(b.sheets[3], "A1", "=SUM(Units)")
		book_recalc_all(b)
		text := doc_save_string(b.sheets[0], "span", {}, {}, context.temp_allocator)
		ok_mark(tc, strings.contains(text, `"sheet2": "Mar"`), "the native file records the far end")
		b2 := book_new()
		defer bk_free(b2)
		doc_load_string(b2.sheets[0], text)
		at_num(tc, b2.sheets[3], "A1", 6)

		raw := xlsx_book_bytes(b, context.temp_allocator)
		files, _ := zip_read(raw, context.temp_allocator)
		wb, _ := zip_find(files, "xl/workbook.xml")
		ok_mark(tc, strings.contains(string(wb), `<definedName name="UNITS">Jan:Mar!$B$2</definedName>`), "the .xlsx writes the span as Excel does")
		b3 := book_new()
		defer bk_free(b3)
		xlsx_read_book_bytes(b3, raw)
		at_num(tc, b3.sheets[3], "A1", 6)
		ok_mark(tc, strings.contains(names_json(b), `"sheet2":"Mar"`), "the shared document carries the span")
	}

	// --- the window's prompt -----------------------------------------------------
	{
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		book_rename_sheet(app.book, 0, "Jan")
		book_add_sheet(app.book, "Feb")
		book_add_sheet(app.book, "Sum")
		put(app.book.sheets[0], "B2", "4")
		put(app.book.sheets[1], "B2", "5")
		put(app.book.sheets[2], "A1", "=SUM(Units)")
		use_sheet(app, 2)
		app.prompt = .Name_Define
		run_prompt(app, "Units = Jan:Feb!B2")
		book_recalc_all(app.book)
		at_num(tc, app.book.sheets[2], "A1", 9)
		app.prompt = .Name_Define
		run_prompt(app, "Bad = Jan:Nowhere!B2")
		_, has := book_get_name(app.book, "Bad")
		ok_mark(tc, !has, "a span to a sheet that is not there is refused")
	}

	// --- the command line ----------------------------------------------------------
	{
		dir := fmt.tprintf("/tmp/palmy-sheets-names3d-%d", os.get_pid())
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", dir))
		b := span_book()
		book_clear_names(b)
		put(b.sheets[3], "A1", "=SUM(Units)")
		path := fmt.tprintf("%s/span.sheet.json", dir)
		doc_save_file(b.sheets[0], path, "span", {}, {})
		bk_free(b)

		out, code := cli_run("name-set", path, "Units", "Jan:Mar!B2", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"target": "Jan:Mar!B2"`), "name-set takes a 3-D target")
		out, _ = cli_run("get", "Sum!A1", path, "--json")
		ok_mark(tc, strings.contains(out, `"value": "6"`), "and the book sums through it")
		_, code = cli_run("name-set", path, "Units", "Jan:Nowhere!B2", "--json")
		ok_mark(tc, code == 3, "a span to a missing sheet exits 3")
	}
}
