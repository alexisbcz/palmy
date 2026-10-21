// `sheets --selftest`, a whole book as CSV: one file per sheet, named the way
// LibreOffice names them (`book-Sales.csv`), with a one-sheet book still
// writing `book.csv` itself. See the comment above `csv_write_book`.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

t_csv_book :: proc(tc: ^TC) {
	// --- file names ----------------------------------------------------------
	ok_mark(tc, csv_file_safe("Q1 2026") == "Q1 2026", "a space stays in a file name")
	ok_mark(tc, csv_file_safe("a/b:c*d?") == "a_b_c_d_", "what a file system trips on is replaced")
	ok_mark(tc, csv_file_safe("..") == "_" && csv_file_safe("") == "_", "and a name that is not a file name is made one")
	{
		b := bk_make("Only")
		defer bk_free(b)
		ps := csv_book_paths(b, "/x/book.csv")
		ok_mark(tc, len(ps) == 1 && ps[0] == "/x/book.csv", "a one-sheet book writes exactly the path given")
	}
	{
		b := bk_make("Sales", "a/b", "A_b", "Été")
		defer bk_free(b)
		ps := csv_book_paths(b, "/x/v1.0/book.csv")
		want := [?]string{"/x/v1.0/book-Sales.csv", "/x/v1.0/book-a_b.csv", "/x/v1.0/book-A_b-2.csv", "/x/v1.0/book-Été.csv"}
		good := len(ps) == len(want)
		for w, i in want {
			good = good && ps[i] == w
		}
		ok_mark(tc, good, fmt.tprintf("several sheets give book-<Sheet>.csv, collisions numbered (%v)", ps))
		ps2 := csv_book_paths(b, "/x/v1.0/book")
		ok_mark(tc, ps2[0] == "/x/v1.0/book-Sales", "a path with no extension keeps having none, and a dotted directory is not one")
	}

	// --- what goes in the files ---------------------------------------------
	dir := fmt.tprintf("/tmp/palmy-sheets-csvbook-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	{
		b := bk_make("Jan", "Feb", "Empty", "Sum")
		defer bk_free(b)
		put(b.sheets[0], "A1", "Item")
		put(b.sheets[0], "B1", "Cost")
		put(b.sheets[0], "A2", "Tea, green")
		put(b.sheets[0], "B2", "3.5")
		put(b.sheets[1], "A1", "Item")
		put(b.sheets[1], "B1", "Cost")
		put(b.sheets[1], "A2", "Coffee")
		put(b.sheets[1], "B2", "4")
		put(b.sheets[3], "A1", "=SUM(Jan:Feb!B2)")
		put(b.sheets[3], "B1", "=Jan!A2")
		book_recalc_all(b)

		files, ok := csv_write_book(b, fmt.tprintf("%s/book.csv", dir))
		ok_mark(tc, ok && len(files) == 4, "every sheet is written")
		text := [4]string{}
		for f, i in files {
			data, err := os.read_entire_file(f, context.temp_allocator)
			ok_mark(tc, err == nil, fmt.tprintf("%s exists", base_name(f)))
			text[i] = string(data)
		}
		ok_mark(tc, text[0] == "Item,Cost\n\"Tea, green\",3.5\n", fmt.tprintf("Jan is its used range, quoted where it must be (%q)", text[0]))
		ok_mark(tc, text[2] == "", "an empty sheet is an empty file, not a missing one")
		ok_mark(tc, text[3] == "7.5,\"Tea, green\"\n", fmt.tprintf("a formula goes out as its value, a 3-D one included (%q)", text[3]))
		ok_mark(tc, !os.exists(fmt.tprintf("%s/book.csv", dir)), "and book.csv itself is not written")

		// Each file reads back as one sheet with the same values: CSV keeps
		// values and loses formulas, formats, names and charts, and says so.
		back := bk_make("Back")
		defer bk_free(back)
		rok, rows, cols := csv_read_file(back.sheets[0], files[3], {0, 0})
		ok_mark(tc, rok && rows == 1 && cols == 2, "the summary file reads back")
		at_num(tc, back.sheets[0], "A1", 7.5)
		at_input(tc, back.sheets[0], "A1", "7.5")

		// And the set reads back as one book: the reverse of the export.
		ok_mark(tc, len(csv_book_files(fmt.tprintf("%s/book.csv", dir))) == 4, "book.csv finds its four book-<Sheet>.csv files")
		whole := book_new()
		defer bk_free(whole)
		wok, nsheets, _ := csv_read_book(whole, fmt.tprintf("%s/book.csv", dir))
		ok_mark(tc, wok && nsheets == 4 && len(whole.sheets) == 4, fmt.tprintf("and imports them as four sheets (%d)", len(whole.sheets)))
		names := make([dynamic]string, context.temp_allocator)
		for sh in whole.sheets {
			append(&names, sh.name)
		}
		ok_mark(tc, fmt.tprint(names[:]) == `["Empty", "Feb", "Jan", "Sum"]`, fmt.tprintf("named from the files, in name order, the blank first sheet reused (%v)", names[:]))
		if wok && len(whole.sheets) == 4 {
			at_text(tc, whole.sheets[2], "A2", "Tea, green")
			at_num(tc, whole.sheets[2], "B2", 3.5)
			at_num(tc, whole.sheets[3], "A1", 7.5)
			ok_mark(tc, len(whole.sheets[0].cells) == 0, "the empty sheet comes back empty")
		}
		// A path that exists is still one file, so an ordinary CSV whose
		// name happens to prefix others is not read as a book.
		_ = os.write_entire_file(fmt.tprintf("%s/book.csv", dir), transmute([]u8)string("1,2\n"))
		single := book_new()
		defer bk_free(single)
		sok, _, _, sn := csv_open(single.sheets[0], fmt.tprintf("%s/book.csv", dir), {0, 0})
		ok_mark(tc, sok && sn == 0 && len(single.sheets) == 1, "an existing book.csv is imported alone, as before")
		os.remove(fmt.tprintf("%s/book.csv", dir))
		none := book_new()
		defer bk_free(none)
		nok, _, _, _ := csv_open(none.sheets[0], fmt.tprintf("%s/nothing.csv", dir), {0, 0})
		ok_mark(tc, !nok, "a path with no file and no set is a failure")

		tfiles, tok := csv_write_book(b, fmt.tprintf("%s/book.tsv", dir))
		data, _ := os.read_entire_file(tfiles[0], context.temp_allocator)
		ok_mark(tc, tok && strings.has_suffix(tfiles[0], "book-Jan.tsv") && string(data) == "Item\tCost\nTea, green\t3.5\n", "a .tsv path writes tabs")
	}

	// --- the window's command --------------------------------------------------
	{
		app := new(App)
		defer free(app)
		app_init(app)
		defer app_destroy(app)
		seed_demo(app)
		book_recalc_all(app.book)
		app.prompt = .Export_CSV_All
		run_prompt(app, fmt.tprintf("%s/gui.csv", dir))
		n := 0
		for sh in app.book.sheets {
			if os.exists(fmt.tprintf("%s/gui-%s.csv", dir, csv_file_safe(sh.name))) {
				n += 1
			}
		}
		ok_mark(tc, n == len(app.book.sheets) && n > 1, "Export every sheet as CSV writes one file per sheet")
		ok_mark(tc, strings.contains(app.status, "Exported"), "and says so")
		// Import CSV of the same path brings them back, as sheets added
		// after the ones already open.
		before := len(app.book.sheets)
		app.prompt = .Import_CSV
		run_prompt(app, fmt.tprintf("%s/gui.csv", dir))
		ok_mark(tc, len(app.book.sheets) == 2 * before && app.book.sheets[before].name == "Sales2", fmt.tprintf("Import CSV of the exported path adds every sheet (%d, %s)", len(app.book.sheets), app.status))
		ok_mark(tc, app.sh == app.book.sheets[app.book.active], "and the window still points at a sheet of the book")
	}

	// --- the command line --------------------------------------------------
	{
		_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", dir))
		out, code := cli_run("export", fmt.tprintf("%s/cli.csv", dir), "--dry-run", "--json")
		ok_mark(tc, code == 0 && strings.contains(out, "cli-Sales.csv") && strings.contains(out, "cli-Summary.csv"), "a dry run names the files it would write")
		ok_mark(tc, !os.exists(fmt.tprintf("%s/cli-Sales.csv", dir)), "and writes none")
		out, code = cli_run("export", fmt.tprintf("%s/cli.csv", dir), "--json")
		problems := kit.cli_validate_output(out, EXPORT_FIELDS, context.temp_allocator)
		ok_mark(tc, code == 0 && len(problems) == 0, fmt.tprintf("export to .csv matches its schema %v", problems))
		ok_mark(tc, os.exists(fmt.tprintf("%s/cli-Sales.csv", dir)) && os.exists(fmt.tprintf("%s/cli-Summary.csv", dir)), "and writes both sheets")
		out, code = cli_run("info", fmt.tprintf("%s/cli.csv", dir), "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"Summary"`) && strings.contains(out, `"Sales"`), fmt.tprintf("info on the exported path reads both sheets back (%d)", code))
		// A bare word opens the window only when it names something to open.
		ok_mark(tc, sheets_takes_word(fmt.tprintf("%s/cli.csv", dir)), "the exported set's path counts as a file to open")
		ok_mark(tc, sheets_takes_word(fmt.tprintf("%s/cli-Sales.csv", dir)), "and so does one of its files")
		ok_mark(tc, !sheets_takes_word(fmt.tprintf("%s/none.csv", dir)) && !sheets_takes_word("infoo"), "a missing file or a mistyped verb does not")
		out, code = cli_run("infoo", "--json")
		ok_mark(tc, code == 2 && strings.contains(out, "neither a command nor a file"), fmt.tprintf("so `sheets infoo` is a usage error, not a window (%d)", code))
		out, code = cli_run("get", "Summary!B8", fmt.tprintf("%s/cli.csv", dir), "--json")
		ok_mark(tc, code == 0 && strings.contains(out, `"number": 2781.05`), fmt.tprintf("with the summary's values in it, as numbers (%s)", out))
		out, code = cli_run("export", fmt.tprintf("%s/one.csv", dir), "--sheet", "summary", "--json")
		ok_mark(tc, code == 0 && os.exists(fmt.tprintf("%s/one.csv", dir)) && strings.contains(out, `"sheets": 1`), "--sheet writes one sheet to exactly the path")
		_, code = cli_run("export", fmt.tprintf("%s/one.xlsx", dir), "--sheet", "Summary", "--json")
		ok_mark(tc, code == 2, "--sheet on a whole-book format is a usage error")
		_, code = cli_run("export", fmt.tprintf("%s/two.csv", dir), "--sheet", "Nope", "--json")
		ok_mark(tc, code == 3, "--sheet naming no sheet exits 3")
	}
}
