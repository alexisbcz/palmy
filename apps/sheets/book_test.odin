// `sheets --selftest`, the multi-sheet half: cross-sheet references through
// the parser, the printer, the graph and the recalculation order; frozen
// panes; charts; named ranges; whole-row ranges; and merged cells.
//
// The two assertions that matter most are the ones a single-sheet engine
// cannot even express:
//
//   * a cycle that crosses sheets is still a cycle. `Sheet1!A1` reading
//     `Sheet2!A1` reading `Sheet1!A1` has to come out #CIRC!, which it does
//     because the cycle detector works on cells, not on addresses, and a
//     cell is the thing that gets marked `.Visiting`.
//   * inserting a row on one sheet shifts the references *on other sheets*
//     that point into it, and leaves alone the references on those sheets
//     that point at their own rows. Both halves are checked, because getting
//     only the first is how a formula silently starts reading the wrong row.
package main

import "core:encoding/xml"
import "core:fmt"
import "core:strings"

// bk_make builds a book with the named sheets, in order.
bk_make :: proc(names: ..string) -> ^Book {
	b := book_new()
	for n, i in names {
		if i == 0 {
			book_rename_sheet(b, 0, n)
		} else {
			book_add_sheet(b, n)
		}
	}
	return b
}

bk_free :: proc(b: ^Book) {
	book_destroy(b)
	free(b)
}

// ---------------------------------------------------------------------------
// The parser and the printer
// ---------------------------------------------------------------------------

t_cross_syntax :: proc(tc: ^TC) {
	exp_src(tc, "Sheet2!A1", "=Sheet2!A1")
	exp_src(tc, "Sheet2!$A$1", "=Sheet2!$A$1")
	exp_src(tc, "Sheet2!A1:B4", "=Sheet2!A1:B4")
	exp_src(tc, "SUM(Data!A1:A5)", "=SUM(Data!A1:A5)")
	exp_src(tc, "Sheet2!A1+Sheet3!B2", "=Sheet2!A1+Sheet3!B2")
	exp_src(tc, "sheet2!a1", "=sheet2!A1")
	exp_src(tc, "Q1.actuals!A1", "=Q1.actuals!A1")
	// A quoted name keeps its quotes only when it needs them.
	exp_src(tc, "'My Sheet'!A1:B4", "='My Sheet'!A1:B4")
	exp_src(tc, "'Plain'!A1", "=Plain!A1")
	exp_src(tc, "'It''s here'!A1", "='It''s here'!A1")
	// A name that reads as a cell reference must stay quoted or it would be
	// one.
	exp_src(tc, "'A1'!B2", "='A1'!B2")
	exp_src(tc, "'2026'!B2", "='2026'!B2")
	// A whole-column range on another sheet.
	exp_src(tc, "SUM(Sheet2!A:A)", "=SUM(Sheet2!A:A)")

	exp_bad(tc, "Sheet2!")
	exp_bad(tc, "Sheet2!!A1")
	exp_bad(tc, "'unterminated!A1")
	exp_bad(tc, "Sheet2!ZZZZ1")
	exp_bad(tc, "!A1")
	// A sheet-qualified column with no row is still only legal in a range.
	exp_bad(tc, "Sheet2!A")

	// Offsetting a cross-sheet reference moves the cell, not the sheet.
	exp_offset(tc, "=Sheet2!A1", 2, 1, "=Sheet2!B3")
	exp_offset(tc, "=Sheet2!$A$1", 2, 1, "=Sheet2!$A$1")
	exp_offset(tc, "='My Sheet'!A1:B2", 1, 0, "='My Sheet'!A2:B3")

	// A sheet name is not an operator: `A1!B1` with no such sheet is still a
	// parse, and evaluates to #REF! rather than exploding.
	exp_err(tc, "=NoSuchSheet!A1", .Ref)
}

t_row_ranges :: proc(tc: ^TC) {
	exp_src(tc, "SUM(1:1)", "=SUM(1:1)")
	exp_src(tc, "SUM(2:5)", "=SUM(2:5)")
	exp_src(tc, "SUM($1:$3)", "=SUM($1:$3)")
	exp_src(tc, "SUM(Sheet2!1:2)", "=SUM(Sheet2!1:2)")
	// The disambiguation that makes it possible: a number is still a number.
	exp_num(tc, "=1", 1)
	exp_num(tc, "=1+1", 2)
	exp_num(tc, "=10/2", 5)
	exp_bad(tc, "=1:1")
	exp_bad(tc, "A1:1") // a cell and a row are not the same kind of endpoint
	exp_bad(tc, "1:A")
	exp_bad(tc, "1.5:2")

	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	put(sh, "A1", "1")
	put(sh, "B1", "2")
	put(sh, "C1", "3")
	put(sh, "A2", "10")
	put(sh, "B2", "20")
	put(sh, "A4", "=SUM(1:1)")
	put(sh, "B4", "=SUM(2:2)")
	put(sh, "C4", "=COUNT(1:2)")
	recalc(sh)
	at_num(tc, sh, "A4", 6)
	at_num(tc, sh, "B4", 30)
	at_num(tc, sh, "C4", 5)

	// A row range is watched like any other: editing a cell in it recomputes.
	put(sh, "D1", "4")
	recalc(sh)
	at_num(tc, sh, "A4", 10)
}

// ---------------------------------------------------------------------------
// Cross-sheet evaluation
// ---------------------------------------------------------------------------

t_cross_eval :: proc(tc: ^TC) {
	b := bk_make("Sheet1", "Sheet2", "My Sheet")
	defer bk_free(b)
	s1, s2, s3 := b.sheets[0], b.sheets[1], b.sheets[2]

	ok_mark(tc, len(b.sheets) == 3, "a book holds three sheets")
	ok_mark(tc, book_find(b, "sheet2") == 1, "a sheet is found case-insensitively")
	ok_mark(tc, book_find(b, "nope") < 0, "an unknown sheet is not found")

	put(s1, "A1", "10")
	put(s1, "A2", "20")
	put(s1, "A3", "30")
	put(s2, "A1", "=Sheet1!A1*2")
	put(s2, "A2", "=SUM(Sheet1!A1:A3)")
	put(s2, "B1", "=Sheet1!A1+Sheet1!A2")
	put(s3, "A1", "=Sheet1!A3")
	put(s1, "B1", "='My Sheet'!A1+1")
	recalc(s1)

	at_num(tc, s2, "A1", 20)
	at_num(tc, s2, "A2", 60)
	at_num(tc, s2, "B1", 30)
	at_num(tc, s3, "A1", 30)
	at_num(tc, s1, "B1", 31)

	// The graph crosses sheets, so an edit on one propagates to the other
	// without a full pass.
	put(s1, "A1", "100")
	recalc(s1)
	at_num(tc, s2, "A1", 200)
	at_num(tc, s2, "A2", 150)
	at_num(tc, s2, "B1", 120)
	ok_mark(
		tc,
		b.evaluated == 3,
		fmt.tprintf("only the three cross-sheet dependents recalculated (got %d)", b.evaluated),
	)

	// A range watcher on another sheet fires for a cell written inside it.
	put(s1, "A3", "1")
	recalc(s1)
	at_num(tc, s2, "A2", 121)
	at_num(tc, s3, "A1", 1)

	// A reference to a sheet that does not exist is #REF!, not a crash.
	put(s2, "C1", "=Ghost!A1")
	recalc(s2)
	at_err(tc, s2, "C1", .Ref)

	// A sheet-qualified reference reads the other sheet's values, not its own
	// cell of the same address.
	put(s2, "D1", "7")
	put(s2, "D2", "=D1")
	put(s2, "D3", "=Sheet1!D1")
	recalc(s2)
	at_num(tc, s2, "D2", 7)
	at_num(tc, s2, "D3", 0) // Sheet1!D1 is empty, and an empty cell reads 0
}

t_cross_cycles :: proc(tc: ^TC) {
	// Two sheets pointing at each other.
	{
		b := bk_make("A", "B")
		defer bk_free(b)
		sa, sb := b.sheets[0], b.sheets[1]
		put(sa, "A1", "=B!A1+1")
		put(sb, "A1", "=A!A1+1")
		book_recalc(b)
		at_err(tc, sa, "A1", .Circ)
		at_err(tc, sb, "A1", .Circ)
	}
	// Three sheets round a ring, with a bystander on each that must stay
	// healthy.
	{
		b := bk_make("One", "Two", "Three")
		defer bk_free(b)
		s1, s2, s3 := b.sheets[0], b.sheets[1], b.sheets[2]
		put(s1, "A1", "=Two!A1+1")
		put(s2, "A1", "=Three!A1+1")
		put(s3, "A1", "=One!A1+1")
		put(s1, "B1", "=2*3")
		put(s2, "B1", "=One!B1+1")
		book_recalc(b)
		at_err(tc, s1, "A1", .Circ)
		at_err(tc, s2, "A1", .Circ)
		at_err(tc, s3, "A1", .Circ)
		at_num(tc, s1, "B1", 6)
		at_num(tc, s2, "B1", 7)

		// Breaking the ring on one sheet brings all three back to life.
		put(s3, "A1", "10")
		book_recalc(b)
		at_num(tc, s2, "A1", 11)
		at_num(tc, s1, "A1", 12)

		// And re-introducing it reports the cycle again rather than keeping a
		// stale number.
		put(s3, "A1", "=One!A1+1")
		book_recalc(b)
		at_err(tc, s1, "A1", .Circ)
		at_err(tc, s3, "A1", .Circ)
	}
	// A sheet naming itself is still just this sheet, so a formula that names
	// its own sheet and its own cell is an ordinary self-reference.
	{
		b := bk_make("Me", "Other")
		defer bk_free(b)
		sm := b.sheets[0]
		put(sm, "A1", "=Me!A1+1")
		put(sm, "B1", "5")
		put(sm, "C1", "=Me!B1*2")
		book_recalc(b)
		at_err(tc, sm, "A1", .Circ)
		at_num(tc, sm, "C1", 10)
	}
	// A cycle through a cross-sheet *range*, not a cell.
	{
		b := bk_make("Src", "Dst")
		defer bk_free(b)
		sa, sb := b.sheets[0], b.sheets[1]
		put(sa, "A1", "=SUM(Dst!A1:A3)")
		put(sb, "A2", "=Src!A1")
		book_recalc(b)
		at_err(tc, sa, "A1", .Circ)
	}
}

t_cross_structural :: proc(tc: ^TC) {
	b := bk_make("Data", "Report")
	defer bk_free(b)
	d, r := b.sheets[0], b.sheets[1]
	for i in 1 ..= 6 {
		set_input(d, {i - 1, 0}, fmt.tprintf("%d", i * 10))
	}
	put(r, "A1", "=Data!A5")
	put(r, "A2", "=SUM(Data!A1:A6)")
	put(r, "A3", "=Data!$A$5")
	// A reference on Report to Report's own row 5 must *not* move when Data
	// gains a row. This is the assertion that separates a real book-wide
	// fixup from a global search and replace.
	put(r, "A5", "555")
	put(r, "B1", "=A5")
	put(r, "B2", "=SUM(A1:A6)")
	book_recalc(b)
	at_num(tc, r, "A1", 50)
	at_num(tc, r, "A2", 210)

	insert_rows(d, 2, 1) // a new row 3 on Data
	at_input(tc, r, "A1", "=Data!A6")
	at_input(tc, r, "A2", "=SUM(Data!A1:A7)")
	at_input(tc, r, "A3", "=Data!$A$6")
	at_input(tc, r, "B1", "=A5")
	at_input(tc, r, "B2", "=SUM(A1:A6)")
	at_num(tc, r, "A1", 50)
	at_num(tc, r, "A2", 210)
	at_num(tc, r, "B1", 555)

	// Deleting the row a cross-sheet reference names turns it into #REF!,
	// while a range that merely overlaps is clamped.
	delete_rows(d, 5, 1) // Data row 6, which is where A5's value went
	at_input(tc, r, "A1", "=Data!#REF!")
	at_err(tc, r, "A1", .Ref)
	at_input(tc, r, "A2", "=SUM(Data!A1:A6)")

	// An edit on Report leaves the references into Data alone.
	insert_cols(r, 0, 1)
	at_input(tc, r, "B2", "=SUM(Data!A1:A6)")
	at_input(tc, r, "C2", "=SUM(B1:B6)")
}

t_sheet_ops :: proc(tc: ^TC) {
	// Renaming rewrites the formulas that named the sheet.
	{
		b := bk_make("Sheet1", "Sheet2")
		defer bk_free(b)
		s1, s2 := b.sheets[0], b.sheets[1]
		put(s1, "A1", "5")
		put(s2, "A1", "=Sheet1!A1*3")
		put(s2, "A2", "=SUM(Sheet1!A1:A2)+A1")
		book_recalc(b)
		at_num(tc, s2, "A1", 15)

		ok_mark(tc, book_rename_sheet(b, 0, "Inputs"), "a sheet renames")
		at_input(tc, s2, "A1", "=Inputs!A1*3")
		at_input(tc, s2, "A2", "=SUM(Inputs!A1:A2)+A1")
		book_recalc_all(b)
		at_num(tc, s2, "A1", 15)
		at_num(tc, s2, "A2", 20)

		// A name with a space comes back quoted, which is the only spelling
		// that round-trips.
		ok_mark(tc, book_rename_sheet(b, 0, "Raw Inputs"), "a sheet renames to a quoted name")
		at_input(tc, s2, "A1", "='Raw Inputs'!A1*3")
		book_recalc_all(b)
		at_num(tc, s2, "A1", 15)

		ok_mark(tc, !book_rename_sheet(b, 0, "Sheet2"), "a duplicate name is refused")
		ok_mark(tc, !book_rename_sheet(b, 0, "   "), "an empty name is refused")
	}
	// Deleting a sheet leaves the references to it as #REF!.
	{
		b := bk_make("Keep", "Doomed")
		defer bk_free(b)
		s1 := b.sheets[0]
		put(s1, "A1", "=Doomed!A1+1")
		put(b.sheets[1], "A1", "9")
		book_recalc(b)
		at_num(tc, s1, "A1", 10)
		ok_mark(tc, book_delete_sheet(b, 1), "a sheet deletes")
		at_err(tc, s1, "A1", .Ref)
		at_input(tc, s1, "A1", "=Doomed!A1+1") // the text is kept, so it can be repaired
		ok_mark(tc, !book_delete_sheet(b, 0), "the last sheet cannot be deleted")
	}
	// Reordering changes the tab order and nothing else.
	{
		b := bk_make("A", "B", "C")
		defer bk_free(b)
		put(b.sheets[0], "A1", "1")
		put(b.sheets[2], "A1", "=A!A1+1")
		book_recalc(b)
		at_num(tc, b.sheets[2], "A1", 2)
		ok_mark(tc, book_move_sheet(b, 2, 0), "a sheet moves to the front")
		ok_mark(tc, b.sheets[0].name == "C", "the moved sheet is first")
		ok_mark(tc, b.sheets[0].index == 0 && b.sheets[2].index == 2, "the indices follow the order")
		book_recalc_all(b)
		at_num(tc, b.sheets[0], "A1", 2) // still resolves after the reorder
	}
	// A duplicate name is made unique rather than refused on creation.
	{
		b := bk_make("Sheet1")
		defer bk_free(b)
		book_add_sheet(b, "Sheet1")
		ok_mark(tc, b.sheets[1].name == "Sheet12", "a clashing new name is made unique")
	}
}

// ---------------------------------------------------------------------------
// Frozen panes
// ---------------------------------------------------------------------------

t_panes :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	set_freeze(sh, 1, 2)
	ok_mark(tc, sh.frz_rows == 1 && sh.frz_cols == 2, "a freeze is recorded")
	set_freeze(sh, -4, 99999999)
	ok_mark(tc, sh.frz_rows == 0 && sh.frz_cols < MAX_COLS, "a freeze is clamped to the sheet")
	set_freeze(sh, 2, 1)

	// The pane element: the split counts and the first scrolling cell.
	x := xlsx_pane_xml(sh)
	ok_mark(tc, strings.contains(x, "ySplit=\"2\""), "ySplit carries the frozen row count")
	ok_mark(tc, strings.contains(x, "xSplit=\"1\""), "xSplit carries the frozen column count")
	ok_mark(tc, strings.contains(x, "topLeftCell=\"B3\""), "topLeftCell names the first scrolling cell")
	ok_mark(tc, strings.contains(x, "state=\"frozen\""), "the pane is frozen, not merely split")
	ok_mark(tc, strings.contains(x, "activePane=\"bottomRight\""), "both splits make the active pane bottom-right")

	set_freeze(sh, 1, 0)
	ok_mark(
		tc,
		strings.contains(xlsx_pane_xml(sh), "activePane=\"bottomLeft\"") &&
		!strings.contains(xlsx_pane_xml(sh), "xSplit"),
		"a frozen header row writes only ySplit",
	)
	set_freeze(sh, 0, 1)
	ok_mark(
		tc,
		strings.contains(xlsx_pane_xml(sh), "activePane=\"topRight\"") &&
		!strings.contains(xlsx_pane_xml(sh), "ySplit"),
		"a frozen first column writes only xSplit",
	)
	set_freeze(sh, 0, 0)
	ok_mark(tc, xlsx_pane_xml(sh) == "", "no freeze writes no pane at all")

	// Inserting rows above the split pushes the split along with them.
	set_freeze(sh, 2, 1)
	insert_rows(sh, 0, 3)
	ok_mark(tc, sh.frz_rows == 5, "inserting above the split moves it")
	delete_rows(sh, 0, 3)
	ok_mark(tc, sh.frz_rows == 2, "deleting above the split moves it back")

	// The viewport: a frozen strip is never scrolled past, and a cursor
	// inside it does not scroll the sheet.
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	app.fonts = nil
	set_freeze(app.sh, 2, 1)
	for i in 0 ..< 200 {
		set_input(app.sh, {i, 0}, int_text(i))
	}
	app.grid_h = 220
	app.grid_w = 600
	app.scroll_h = 220 - frozen_h(app)
	app.scroll_w = 600 - frozen_w(app)
	goto_cell(app, {100, 0})
	ok_mark(tc, app.top_row >= 2, "the scroll position never enters the frozen rows")
	ok_mark(tc, app.left_col == 1, "the scroll position never enters the frozen columns")
	before := app.top_row
	goto_cell(app, {0, 0})
	ok_mark(
		tc,
		app.top_row == before,
		fmt.tprintf("a cursor inside the frozen region does not scroll (%d -> %d)", before, app.top_row),
	)
	goto_cell(app, {3, 0})
	ok_mark(tc, app.top_row == 3, "a cursor just below the split scrolls to it")
}

// ---------------------------------------------------------------------------
// Merged cells
// ---------------------------------------------------------------------------

t_merges :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	ok_mark(tc, add_merge(sh, {0, 0, 0, 2}), "a row of cells merges")
	ok_mark(tc, !add_merge(sh, {5, 5, 5, 5}), "one cell is not a merge")
	_, found := merge_at(sh, {0, 1})
	ok_mark(tc, found, "a covered cell reports its merge")
	m, _ := merge_at(sh, {0, 2})
	ok_mark(tc, m.c0 == 0 && m.c1 == 2, "the merge rectangle comes back whole")
	// An overlapping merge replaces the one it covers rather than nesting.
	add_merge(sh, {0, 1, 2, 3})
	ok_mark(tc, len(sh.merges) == 1, "an overlapping merge replaces the old one")
	_, still := merge_at(sh, {0, 0})
	ok_mark(tc, !still, "the replaced merge is gone")
	ok_mark(tc, drop_merge(sh, {1, 2}), "a merge is dropped from any cell inside it")
	ok_mark(tc, len(sh.merges) == 0, "and the list is empty again")

	// A merge moves with the rows under it, and dies with them.
	add_merge(sh, {4, 0, 4, 2})
	insert_rows(sh, 0, 2)
	ok_mark(tc, len(sh.merges) == 1 && sh.merges[0].r0 == 6, "a merge follows an insert")
	delete_rows(sh, 6, 1)
	ok_mark(tc, len(sh.merges) == 0, "a merge whose rows are deleted goes with them")
}

// ---------------------------------------------------------------------------
// Named ranges
// ---------------------------------------------------------------------------

t_names :: proc(tc: ^TC) {
	b := bk_make("Data", "Calc")
	defer bk_free(b)
	d, c := b.sheets[0], b.sheets[1]
	put(d, "A1", "2")
	put(d, "A2", "3")
	put(d, "A3", "4")
	ok_mark(tc, book_set_name(b, "Prices", "Data", {0, 0, 2, 0}), "a range is named")
	ok_mark(tc, !book_set_name(b, "A1", "Data", {0, 0, 0, 0}), "a name that reads as a reference is refused")
	ok_mark(tc, !book_set_name(b, "2bad", "Data", {0, 0, 0, 0}), "a name cannot start with a digit")
	ok_mark(tc, !book_set_name(b, "has space", "Data", {0, 0, 0, 0}), "a name cannot contain a space")

	put(c, "A1", "=SUM(Prices)")
	put(c, "A2", "=prices")
	put(c, "A3", "=Nope")
	book_recalc(b)
	at_num(tc, c, "A1", 9)
	at_err(tc, c, "A2", .Value) // a multi-cell range where a scalar is wanted
	at_err(tc, c, "A3", .Name)

	// A name is a dependency like any other: editing inside it recomputes.
	put(d, "A2", "30")
	book_recalc(b)
	at_num(tc, c, "A1", 36)

	// The file-format spelling, which is what `<definedName>` holds.
	nd, got := book_get_name(b, "prices")
	ok_mark(tc, got, "a name is found case-insensitively")
	ok_mark(
		tc,
		name_target(b, nd) == "Data!$A$1:$A$3",
		fmt.tprintf("a name prints as a sheet-qualified absolute range (%s)", name_target(b, nd)),
	)
	ok_mark(tc, book_drop_name(b, "PRICES"), "a name is dropped")
	book_recalc_all(b)
	at_err(tc, c, "A1", .Name)
}

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

t_charts :: proc(tc: ^TC) {
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	rows := [?][3]string {
		{"Region", "Units", "Price"},
		{"North", "120", "4.5"},
		{"South", "86", "4.5"},
		{"East", "203", "3.95"},
	}
	for r, i in rows {
		for v, j in r {
			set_input(sh, {i, j}, v)
		}
	}
	recalc(sh)

	ch := Chart {
		kind  = .Bar,
		title = "Units",
		rect  = {0, 0, 3, 2},
		at    = {0, 4},
		w     = 6,
		h     = 12,
	}
	d := chart_read(sh, ch)
	ok_mark(tc, d.has_hdr, "a text first row is read as the series names")
	ok_mark(tc, d.has_cat, "a text first column is read as the categories")
	ok_mark(tc, len(d.cats) == 3, fmt.tprintf("three categories, got %d", len(d.cats)))
	ok_mark(tc, len(d.cats) == 3 && d.cats[0] == "North", "the first category is the first label")
	ok_mark(tc, len(d.series) == 2, fmt.tprintf("two series, got %d", len(d.series)))
	ok_mark(tc, len(d.series) > 0 && d.series[0].name == "Units", "a series takes its name from the header")
	ok_mark(tc, len(d.series) > 0 && d.series[0].vals[2] == 203, "a series value comes from the cell")
	ok_mark(tc, d.hi == 203, fmt.tprintf("the axis reaches the largest value (%v)", d.hi))
	ok_mark(tc, d.lo == 0, "a bar chart's axis includes zero")

	// A chart is a view, not a copy: changing a cell changes what it plots.
	// This is what makes it fall out of the dependency graph rather than need
	// its own invalidation.
	put(sh, "B4", "=120+80")
	recalc(sh)
	d2 := chart_read(sh, ch)
	ok_mark(tc, d2.series[0].vals[2] == 200, "a chart follows a recalculated cell")
	ok_mark(tc, d2.hi == 200, "and the axis follows with it")

	// A gap is a gap, not a zero.
	set_input(sh, {2, 1}, "")
	recalc(sh)
	d3 := chart_read(sh, ch)
	ok_mark(tc, !d3.series[0].have[1], "an empty cell is a gap in the series")

	// Headerless, label-less data still charts: the columns are the series
	// and the row numbers are the categories.
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	put(s2, "A1", "1")
	put(s2, "A2", "2")
	put(s2, "A3", "3")
	recalc(s2)
	d4 := chart_read(s2, Chart{kind = .Line, rect = {0, 0, 2, 0}})
	ok_mark(tc, !d4.has_hdr && !d4.has_cat, "all-numeric data has neither a header nor labels")
	ok_mark(tc, len(d4.series) == 1 && len(d4.cats) == 3, "it is one series of three points")
	ok_mark(tc, len(d4.cats) == 3 && d4.cats[0] == "1", "the categories are the row numbers")

	// The axis tick chooser picks round numbers.
	{
		start, step, n := axis_ticks(0, 203)
		ok_mark(tc, step == 50, fmt.tprintf("a 0..203 axis steps by 50 (got %v)", step))
		ok_mark(tc, start == 0, "and starts at zero")
		ok_mark(tc, start + step * f64(n - 1) >= 203, "and reaches past the largest value")
	}
	{
		_, step, _ := axis_ticks(0, 1)
		ok_mark(tc, step == 0.2 || step == 0.25, fmt.tprintf("a 0..1 axis steps finely (got %v)", step))
	}

	// Charts move with the rows under them.
	append(&sh.charts, Chart{kind = .Bar, rect = {0, 0, 3, 2}, at = {0, 4}, w = 6, h = 12})
	insert_rows(sh, 0, 2)
	ok_mark(tc, sh.charts[0].rect.r0 == 2, "a chart's data range follows an insert")
	ok_mark(tc, sh.charts[0].at.row == 2, "and so does its anchor")
	ok_mark(tc, chart_covers(sh.charts[0], {5, 6}), "a chart covers the cells it is drawn over")
	ok_mark(tc, !chart_covers(sh.charts[0], {5, 1}), "and not the ones it is not")
	ok_mark(tc, delete_chart_at(sh, {5, 6}), "a chart is deleted from any cell it covers")
	ok_mark(tc, len(sh.charts) == 0, "and the list is empty again")
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

t_book_document :: proc(tc: ^TC) {
	b := bk_make("Data", "My Report")
	defer bk_free(b)
	d, r := b.sheets[0], b.sheets[1]
	put(d, "A1", "1")
	put(d, "A2", "2")
	put(d, "B1", "x")
	set_cell_fmt(d, ref("A1"), {num = .Currency, dec = 2})
	set_col_width(d, 1, 150)
	set_freeze(d, 1, 1)
	add_merge(d, {0, 2, 0, 4})
	put(r, "A1", "=SUM(Data!A1:A2)")
	put(r, "A2", "='Data'!B1")
	book_set_name(b, "Inputs", "Data", {0, 0, 1, 0})
	append(
		&r.charts,
		Chart {
			kind = .Pie,
			title = strings.clone("Share", r.heap),
			sheet = strings.clone("Data", r.heap),
			rect = {0, 0, 1, 0},
			at = {4, 1},
			w = 5,
			h = 10,
		},
	)
	b.active = 1
	book_recalc(b)
	at_num(tc, r, "A1", 3)

	text := doc_save_string(d, "book", ref("B2"), ref("A1"), context.temp_allocator)
	ok_mark(tc, strings.contains(text, "\"sheets\""), "the document is a book")
	ok_mark(tc, strings.contains(text, "\"My Report\""), "a sheet's name is saved")
	ok_mark(tc, strings.contains(text, "=SUM(Data!A1:A2)"), "a cross-sheet formula is saved as source")
	ok_mark(tc, strings.contains(text, "\"frz_row\": 1"), "the frozen split is saved")
	ok_mark(tc, strings.contains(text, "\"C1:E1\""), "a merge is saved")
	ok_mark(tc, strings.contains(text, "\"INPUTS\""), "a name is saved")
	ok_mark(tc, strings.contains(text, "\"Share\""), "a chart is saved")
	ok_mark(tc, !strings.contains(text, "\"val\""), "computed values are not saved")

	b2 := book_new()
	defer bk_free(b2)
	name, cur, anc, ok := doc_load_string(b2.sheets[0], text)
	ok_mark(tc, ok, "the book loads")
	ok_mark(tc, name == "book", "the document name round-trips")
	ok_mark(tc, cur == ref("B2") && anc == ref("A1"), "the selection round-trips")
	ok_mark(tc, len(b2.sheets) == 2, fmt.tprintf("two sheets come back, got %d", len(b2.sheets)))
	ok_mark(tc, b2.active == 1, "the active tab round-trips")
	if len(b2.sheets) == 2 {
		d2, r2 := b2.sheets[0], b2.sheets[1]
		ok_mark(tc, d2.name == "Data" && r2.name == "My Report", "the sheet names round-trip")
		at_num(tc, r2, "A1", 3)
		at_input(tc, r2, "A1", "=SUM(Data!A1:A2)")
		at_text(tc, r2, "A2", "x")
		ok_mark(tc, d2.frz_rows == 1 && d2.frz_cols == 1, "the frozen split round-trips")
		ok_mark(tc, len(d2.merges) == 1 && d2.merges[0].c1 == 4, "the merge round-trips")
		ok_mark(tc, col_width(d2, 1) == 150, "a column width round-trips")
		nd, got := book_get_name(b2, "Inputs")
		ok_mark(tc, got && nd.rect.r1 == 1, "the name round-trips")
		ok_mark(tc, len(r2.charts) == 1, "the chart round-trips")
		if len(r2.charts) == 1 {
			ok_mark(tc, r2.charts[0].kind == .Pie, "the chart keeps its kind")
			ok_mark(tc, r2.charts[0].title == "Share", "the chart keeps its title")
			ok_mark(tc, r2.charts[0].sheet == "Data", "the chart keeps its data sheet")
			ok_mark(tc, r2.charts[0].at == ref("B5"), "the chart keeps its anchor")
		}
		// Saving again must produce the same bytes — which is also what makes
		// undo of a structural edit sound.
		text2 := doc_save_string(d2, "book", ref("B2"), ref("A1"), context.temp_allocator)
		ok_mark(tc, text == text2, "save -> load -> save is byte identical for a book")
	}

	// Undo carries the sheets with it: the snapshot is the whole book.
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	put(app.sh, "A1", "1")
	recalc(app.sh)
	undo_push(app)
	book_add_sheet(app.book, "Second")
	use_sheet(app, 1)
	put(app.sh, "A1", "=Sheet1!A1+1")
	recalc(app.sh)
	at_num(tc, app.sh, "A1", 2)
	do_undo(app)
	ok_mark(tc, len(app.book.sheets) == 1, "undo removes the sheet that was added")
	ok_mark(tc, app.sh == app.book.sheets[0], "and the active sheet pointer follows")
	do_redo(app)
	ok_mark(tc, len(app.book.sheets) == 2, "redo brings it back")
	ok_mark(tc, len(app.book.sheets) == 2 && value_at(app.book.sheets[1], ref("A1")).num == 2, "with its cross-sheet formula intact")

	// A version 1 document — one sheet, cells at the top level — still opens.
	{
		v1 := `{"kind":"palmy.sheets","version":1,"name":"old","cells":[{"ref":"A1","input":"7"},{"ref":"A2","input":"=A1*2"}],"cursor":"A2","anchor":"A2"}`
		b3 := book_new()
		defer bk_free(b3)
		_, c3, _, ok3 := doc_load_string(b3.sheets[0], v1)
		ok_mark(tc, ok3, "a version 1 document still loads")
		ok_mark(tc, len(b3.sheets) == 1, "as one sheet")
		at_num(tc, b3.sheets[0], "A2", 14)
		ok_mark(tc, c3 == ref("A2"), "with its cursor")
	}
}

// ---------------------------------------------------------------------------
// .xlsx, the multi-sheet half
// ---------------------------------------------------------------------------

t_xlsx_book :: proc(tc: ^TC) {
	b := bk_make("Inputs", "My Report")
	defer bk_free(b)
	d, r := b.sheets[0], b.sheets[1]
	hdr := [?]string{"Region", "Units"}
	for h, i in hdr {
		set_input(d, {0, i}, h)
		set_cell_fmt(d, {0, i}, {bold = true})
	}
	vals := [?][2]string{{"North", "120"}, {"South", "86"}, {"East", "203"}}
	for v, i in vals {
		set_input(d, {i + 1, 0}, v[0])
		set_input(d, {i + 1, 1}, v[1])
	}
	set_freeze(d, 1, 1)
	add_merge(d, {5, 0, 5, 1})
	put(r, "A1", "=SUM(Inputs!B2:B4)")
	put(r, "A2", "=Inputs!B2*2")
	put(r, "A3", "='My Report'!A1")
	book_set_name(b, "Units", "Inputs", {1, 1, 3, 1})
	append(
		&r.charts,
		Chart {
			kind = .Bar,
			title = strings.clone("Units by region", r.heap),
			sheet = strings.clone("Inputs", r.heap),
			rect = {0, 0, 3, 1},
			at = {4, 2},
			w = 7,
			h = 14,
		},
	)
	b.active = 1
	book_recalc(b)
	at_num(tc, r, "A1", 409)

	raw := xlsx_book_bytes(b, context.temp_allocator)
	files, zok := zip_read(raw, context.temp_allocator)
	ok_mark(tc, zok, "a multi-sheet workbook is a readable ZIP")

	WANT := [?]string {
		"[Content_Types].xml",
		"_rels/.rels",
		"xl/workbook.xml",
		"xl/_rels/workbook.xml.rels",
		"xl/worksheets/sheet1.xml",
		"xl/worksheets/sheet2.xml",
		"xl/worksheets/_rels/sheet2.xml.rels",
		"xl/drawings/drawing2.xml",
		"xl/drawings/_rels/drawing2.xml.rels",
		"xl/charts/chart1.xml",
		"xl/styles.xml",
		"xl/sharedStrings.xml",
	}
	for part in WANT {
		_, found := zip_find(files, part)
		ok_mark(tc, found, fmt.tprintf("the package contains %s", part))
	}
	ok_mark(tc, len(files) == len(WANT), fmt.tprintf("the package has %d parts, got %d", len(WANT), len(files)))

	// Every part parses, with the same reader the importer uses.
	for f in files {
		if !strings.has_suffix(f.name, ".xml") && !strings.has_suffix(f.name, ".rels") {
			continue
		}
		doc, err := xml.parse_bytes(f.data, XML_OPTS, f.name, nil, context.temp_allocator)
		ok_mark(tc, err == .None && doc != nil, fmt.tprintf("%s is well-formed XML (%v)", f.name, err))
	}

	wb, _ := zip_find(files, "xl/workbook.xml")
	w := string(wb)
	ok_mark(tc, strings.contains(w, "name=\"Inputs\" sheetId=\"1\" r:id=\"rId1\""), "the first sheet is declared")
	ok_mark(tc, strings.contains(w, "name=\"My Report\" sheetId=\"2\" r:id=\"rId2\""), "the second sheet is declared")
	ok_mark(tc, strings.contains(w, "activeTab=\"1\""), "the active tab is declared")
	ok_mark(tc, strings.contains(w, "<definedName name=\"UNITS\">Inputs!$B$2:$B$4</definedName>"), "the defined name is written")

	wr, _ := zip_find(files, "xl/_rels/workbook.xml.rels")
	ok_mark(tc, strings.contains(string(wr), "worksheets/sheet2.xml"), "the second sheet has a relationship")

	s1x, _ := zip_find(files, "xl/worksheets/sheet1.xml")
	ok_mark(tc, strings.contains(string(s1x), "state=\"frozen\""), "the frozen pane reaches the file")
	ok_mark(tc, strings.contains(string(s1x), "<mergeCell ref=\"A6:B6\"/>"), "the merge reaches the file")

	s2x, _ := zip_find(files, "xl/worksheets/sheet2.xml")
	ok_mark(tc, strings.contains(string(s2x), "<f>SUM(Inputs!B2:B4)</f>"), "a cross-sheet formula is written verbatim")
	// A quoted sheet name reaches the file with its apostrophes as `&apos;`,
	// which is the same string once the XML is decoded — and the import
	// assertion below proves it comes back identical.
	ok_mark(
		tc,
		strings.contains(string(s2x), "<f>&apos;My Report&apos;!A1</f>"),
		"a quoted sheet name keeps its quotes, XML-escaped",
	)
	ok_mark(tc, strings.contains(string(s2x), "<drawing r:id=\"rId1\"/>"), "the sheet points at its drawing")
	ok_mark(
		tc,
		strings.index(string(s2x), "<mergeCells") < strings.index(string(s2x), "<drawing") ||
		!strings.contains(string(s2x), "<mergeCells"),
		"the drawing comes after the merges, as the schema requires",
	)

	cx, _ := zip_find(files, "xl/charts/chart1.xml")
	cs := string(cx)
	ok_mark(tc, strings.contains(cs, "<c:barChart>"), "a bar chart writes a barChart")
	ok_mark(tc, strings.contains(cs, "<c:f>Inputs!$A$2:$A$4</c:f>"), "the categories name the label column")
	ok_mark(tc, strings.contains(cs, "<c:f>Inputs!$B$2:$B$4</c:f>"), "the values name the data column")
	ok_mark(tc, strings.contains(cs, "<c:f>Inputs!$B$1</c:f>"), "the series name points at the header cell")
	ok_mark(tc, strings.contains(cs, "<c:v>203</c:v>"), "the value cache carries the numbers")
	ok_mark(tc, strings.contains(cs, "<c:v>North</c:v>"), "the category cache carries the labels")
	ok_mark(tc, strings.contains(cs, "Units by region"), "the chart carries its title")
	ok_mark(tc, strings.count(cs, "<c:axId") == 4, "the plot and the two axes agree on two axis ids")

	dr, _ := zip_find(files, "xl/drawings/drawing2.xml")
	ds := string(dr)
	ok_mark(tc, strings.contains(ds, "<xdr:col>2</xdr:col>"), "the anchor names the chart's column")
	ok_mark(tc, strings.contains(ds, "<xdr:row>4</xdr:row>"), "the anchor names the chart's row")
	ok_mark(tc, strings.contains(ds, "r:id=\"rId1\""), "the frame points at the chart part")

	// --- and back again ----------------------------------------------------
	b2 := book_new()
	defer bk_free(b2)
	good, nsheets, ncells := xlsx_read_book_bytes(b2, raw)
	ok_mark(tc, good, "the multi-sheet workbook imports")
	ok_mark(tc, nsheets == 2, fmt.tprintf("two sheets import, got %d", nsheets))
	ok_mark(tc, len(b2.sheets) == 2, "and the book has two")
	ok_mark(tc, ncells > 0, "with cells in them")
	if len(b2.sheets) == 2 {
		d2, r2 := b2.sheets[0], b2.sheets[1]
		ok_mark(tc, d2.name == "Inputs", "the first sheet keeps its name")
		ok_mark(tc, r2.name == "My Report", "the second keeps its name, spaces and all")
		ok_mark(tc, b2.active == 1, "the active tab comes back")
		// The assertion the whole format exists for.
		at_input(tc, r2, "A1", "=SUM(Inputs!B2:B4)")
		at_input(tc, r2, "A2", "=Inputs!B2*2")
		at_input(tc, r2, "A3", "='My Report'!A1")
		at_num(tc, r2, "A1", 409)
		at_num(tc, r2, "A2", 240)
		ok_mark(tc, d2.frz_rows == 1 && d2.frz_cols == 1, "the frozen pane comes back")
		ok_mark(tc, len(d2.merges) == 1, "the merge comes back")
		nd, gotn := book_get_name(b2, "Units")
		ok_mark(tc, gotn && nd.rect.r0 == 1 && nd.rect.r1 == 3, "the defined name comes back")
		ok_mark(tc, len(r2.charts) == 1, fmt.tprintf("the chart comes back, got %d", len(r2.charts)))
		if len(r2.charts) == 1 {
			c := r2.charts[0]
			ok_mark(tc, c.kind == .Bar, "the chart kind comes back")
			ok_mark(tc, c.title == "Units by region", fmt.tprintf("the chart title comes back (%q)", c.title))
			ok_mark(tc, c.sheet == "Inputs", fmt.tprintf("the chart's data sheet comes back (%q)", c.sheet))
			ok_mark(
				tc,
				c.rect == Rect_I{0, 0, 3, 1},
				fmt.tprintf("the chart range is rebuilt from its <c:f> formulas (%v)", c.rect),
			)
			ok_mark(tc, c.at == Addr{4, 2}, "the chart anchor comes back")
			ok_mark(tc, c.w == 7 && c.h == 14, fmt.tprintf("the chart size comes back (%dx%d)", c.w, c.h))
		}
	}

	// A line chart and a pie chart write their own plot elements.
	{
		b3 := bk_make("S")
		defer bk_free(b3)
		s := b3.sheets[0]
		put(s, "A1", "a")
		put(s, "B1", "n")
		put(s, "A2", "x")
		put(s, "B2", "1")
		put(s, "A3", "y")
		put(s, "B3", "2")
		book_recalc(b3)
		append(&s.charts, Chart{kind = .Line, rect = {0, 0, 2, 1}, at = {0, 3}, w = 5, h = 10})
		append(&s.charts, Chart{kind = .Pie, rect = {0, 0, 2, 1}, at = {12, 3}, w = 5, h = 10})
		raw3 := xlsx_book_bytes(b3, context.temp_allocator)
		f3, _ := zip_read(raw3, context.temp_allocator)
		c1, _ := zip_find(f3, "xl/charts/chart1.xml")
		c2, _ := zip_find(f3, "xl/charts/chart2.xml")
		ok_mark(tc, strings.contains(string(c1), "<c:lineChart>"), "a line chart writes a lineChart")
		ok_mark(tc, strings.contains(string(c1), "<c:smooth val=\"0\"/>"), "a line series is not smoothed")
		ok_mark(tc, strings.contains(string(c2), "<c:pieChart>"), "a pie chart writes a pieChart")
		ok_mark(tc, !strings.contains(string(c2), "<c:valAx>"), "a pie chart has no axes")
		ok_mark(tc, strings.contains(string(c2), "<c:legend>"), "a pie chart has a legend")
		rel, _ := zip_find(f3, "xl/drawings/_rels/drawing1.xml.rels")
		ok_mark(tc, strings.contains(string(rel), "chart1.xml") && strings.contains(string(rel), "chart2.xml"),
			"one drawing points at both chart parts")
	}

	// A one-sheet export still names its sheet after the document, which is
	// what the single-sheet entry point promises.
	{
		b4 := bk_make("Whatever")
		defer bk_free(b4)
		put(b4.sheets[0], "A1", "1")
		book_recalc(b4)
		raw4 := xlsx_bytes(b4.sheets[0], "ledger.sheet.json", context.temp_allocator)
		f4, _ := zip_read(raw4, context.temp_allocator)
		w4, _ := zip_find(f4, "xl/workbook.xml")
		ok_mark(tc, strings.contains(string(w4), "name=\"ledger\""), "a one-sheet export is named after the document")
		ok_mark(tc, len(f4) == 7, fmt.tprintf("and is still seven parts, got %d", len(f4)))
	}
}

_ :: xml
