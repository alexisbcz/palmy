// `sheets --selftest`, the .xlsx half.
//
// Three things have to be true of an exported workbook, and each is checked
// here rather than left to the eye:
//
//   1. the container is a real ZIP — a wrong CRC-32 or a wrong central
//      directory offset is how a hand-written archive is quietly rejected;
//   2. every part is well-formed XML, which is checked by parsing it back
//      with the same reader the importer uses;
//   3. the *formulas* survive, because a spreadsheet exported without its
//      formulas is a CSV with extra steps.
//
// And then the whole thing round-trips: a sheet with formulas, every number
// format, bold, italic, alignment, column widths, row heights, errors and a
// circular reference goes out and comes back, and every cell is compared.
package main

import "core:encoding/xml"
import "core:fmt"
import "core:strings"

// build_ledger is the fixture: deliberately the awkward cases, not the easy
// ones. It is the same shape as the sheet the LibreOffice round-trip uses.
@(private = "file")
build_ledger :: proc(sh: ^Sheet) {
	hdr := [?]string{"Item", "Qty", "Unit", "Total", "Share"}
	for h, i in hdr {
		set_input(sh, {0, i}, h)
		set_cell_fmt(sh, {0, i}, {bold = true, align = .Center})
	}
	rows := [?][3]string{{"Widget", "12", "$3.50"}, {"Gadget", "7", "$12.25"}, {"Doohickey", "31", "$0.99"}}
	for r, i in rows {
		row := i + 1
		set_input(sh, {row, 0}, r[0])
		set_input(sh, {row, 1}, r[1])
		set_cell_fmt(sh, {row, 1}, {align = .Right})
		set_input(sh, {row, 2}, r[2])
		set_cell_fmt(sh, {row, 2}, {num = .Currency, dec = 2})
		set_input(sh, {row, 3}, fmt.tprintf("=B%d*C%d", row + 1, row + 1))
		set_cell_fmt(sh, {row, 3}, {num = .Currency, dec = 2})
		set_input(sh, {row, 4}, fmt.tprintf("=D%d/$D$5", row + 1))
		set_cell_fmt(sh, {row, 4}, {num = .Percent, dec = 1})
	}
	set_input(sh, {4, 0}, "Total")
	set_cell_fmt(sh, {4, 0}, {bold = true})
	set_input(sh, {4, 3}, "=SUM(D2:D4)")
	set_cell_fmt(sh, {4, 3}, {num = .Currency, dec = 2, bold = true})
	set_input(sh, {4, 4}, "=SUM(E2:E4)")
	set_cell_fmt(sh, {4, 4}, {num = .Percent, dec = 1, bold = true})

	pairs := [?][2]string {
		{"Date", "2026-10-04"},
		{"Days to year end", "=DATE(2026,12,31)-B7"},
		{"Power (^)", "=2^10"},
		{"Postfix percent", "=50%*80"},
		{"Concatenation", "=A2&\" x \"&B2"},
		{"Fixed, grouped", "=1234567.891"},
		{"Scientific", "=6.02214076E23"},
		{"Divide by zero", "=1/0"},
		{"Unknown name", "=NOPE(1)"},
		{"Circular", "=B17+1"},
		{"Circular too", "=B16+1"},
		{"VLOOKUP", "=VLOOKUP(\"Gadget\",A2:D4,2,FALSE)"},
		{"Text functions", "=UPPER(LEFT(A4,4))"},
		{"Comparison", "=B2>10"},
	}
	for pr, i in pairs {
		row := 6 + i
		set_input(sh, {row, 0}, pr[0])
		set_input(sh, {row, 1}, pr[1])
	}
	set_cell_fmt(sh, {6, 0}, {italic = true})
	set_cell_fmt(sh, {6, 1}, {num = .Date})
	set_cell_fmt(sh, {7, 0}, {italic = true})
	set_cell_fmt(sh, {11, 1}, {num = .Fixed, dec = 2})
	set_cell_fmt(sh, {12, 1}, {num = .Scientific, dec = 3})
	set_col_width(sh, 0, 170)
	set_col_width(sh, 3, 110)
	set_row_height(sh, 0, 30)
	sh.graph_dirty = true
	recalc_all(sh)
}

t_xlsx :: proc(tc: ^TC) {
	// --- the ZIP container -------------------------------------------------

	// The CRC-32 check value from the ZIP appnote: the digits 1..9.
	ok_mark(tc, crc32_of(transmute([]u8)string("123456789")) == 0xcbf4_3926, "CRC-32 matches the standard check value")
	ok_mark(tc, crc32_of(nil) == 0, "an empty payload has a zero CRC")

	{
		z := zip_make(context.temp_allocator)
		zip_add_string(&z, "a.txt", "hello")
		zip_add_string(&z, "dir/b.bin", "\x00\x01\x02binary\xff")
		raw := zip_finish(&z)
		files, good := zip_read(raw, context.temp_allocator)
		ok_mark(tc, good && len(files) == 2, "a written archive reads back with both entries")
		if good && len(files) == 2 {
			ok_mark(tc, files[0].name == "a.txt" && string(files[0].data) == "hello", "the first entry round-trips")
			ok_mark(
				tc,
				files[1].name == "dir/b.bin" && string(files[1].data) == "\x00\x01\x02binary\xff",
				"a binary entry with a path round-trips",
			)
		} else {
			tc.n += 2
			tc.failed += 2
		}
		// A truncated archive must be refused, not half-read.
		_, bad := zip_read(raw[:len(raw) / 2], context.temp_allocator)
		ok_mark(tc, !bad, "a truncated archive is rejected")
	}

	// --- the conversions ---------------------------------------------------

	// Excel counts days from 1899-12-30 and so does this program, so a serial
	// crosses unchanged. These three are the ones worth pinning: the Unix
	// epoch, the first date after Excel's fictitious 1900-02-29, and a date
	// the LibreOffice round-trip also checks.
	{
		s, ok1 := date_parse("1970-01-01")
		ok_mark(tc, ok1 && s == 25569, "1970-01-01 is serial 25569, as Excel has it")
		s2, ok2 := date_parse("1900-03-01")
		ok_mark(tc, ok2 && s2 == 61, "1900-03-01 is serial 61, past Excel's fictitious leap day")
		s3, ok3 := date_parse("2026-10-04")
		ok_mark(tc, ok3 && date_text(s3) == "2026-10-04", "a date serial prints back as the same date")
		s4, ok4 := date_parse("1900-01-01")
		ok_mark(
			tc,
			ok4 && s4 == 2,
			"1900-01-01 is serial 2 here and 1 in Excel — the documented one-day gap before 1900-03-01",
		)
	}

	// Excel measures a column in characters and a row in points.
	ok_mark(tc, abs(chars_to_px(px_to_chars(88)) - 88) < 0.001, "a column width survives pixels -> characters -> pixels")
	ok_mark(tc, abs(px_to_chars(DEFAULT_COL_W) - 11.857) < 0.01, "the default column is 11.86 characters wide")
	ok_mark(tc, px_to_points(22) == 16.5, "a 22px row is 16.5pt")
	ok_mark(tc, abs(points_to_px(px_to_points(44)) - 44) < 0.001, "a row height survives pixels -> points -> pixels")

	// Every format this program has must survive being written as an Excel
	// format code and classified back.
	for n in Num_Format {
		for dec in u8(0) ..= 4 {
			d := (n == .General || n == .Date) ? 0 : dec
			code := numfmt_code(n, d)
			back, bdec := numfmt_from_code(code)
			ok_mark(
				tc,
				back == n && (n == .General || n == .Date || bdec == d),
				fmt.tprintf("%s with %d decimals round-trips through the format code %q (got %v/%d)", num_format_name(n), d, code, back, bdec),
			)
		}
	}
	// And the dialects other writers use.
	{
		n, d := numfmt_from_code("\\$#,##0.00")
		ok_mark(tc, n == .Currency && d == 2, "LibreOffice's escaped currency code is recognised")
		n2, _ := numfmt_from_code("yyyy\\-mm\\-dd")
		ok_mark(tc, n2 == .Date, "an ISO date code is recognised")
		n3, _ := numfmt_from_code("mm-dd-yy")
		ok_mark(tc, n3 == .Date, "Excel's builtin 14 is recognised as a date")
		n4, d4 := numfmt_from_code("0.000E+00")
		ok_mark(tc, n4 == .Scientific && d4 == 3, "a scientific code keeps its decimals")
		n5, d5 := numfmt_from_code("0.0%")
		ok_mark(tc, n5 == .Percent && d5 == 1, "a percent code keeps its decimals")
		n6, _ := numfmt_from_code("General")
		ok_mark(tc, n6 == .General, "General stays General")
		n7, _ := numfmt_from_code("[$€-407]#,##0.00")
		ok_mark(tc, n7 == .Currency, "a euro code reads as currency")
	}

	// --- escaping and names ------------------------------------------------
	ok_mark(tc, xml_escape("a<b&c>\"d\"") == "a&lt;b&amp;c&gt;&quot;d&quot;", "XML metacharacters are escaped")
	ok_mark(tc, xml_escape("plain") == "plain", "a clean string is passed through untouched")
	ok_mark(tc, xlsx_sheet_name("budget[2026].sheet.json") == "budget_2026_", "a sheet name drops the characters Excel reserves")
	ok_mark(tc, len(xlsx_sheet_name(strings.repeat("x", 60, context.temp_allocator))) == 31, "a sheet name is trimmed to 31 characters")

	// --- the formula dialect -----------------------------------------------
	ok_mark(tc, xlsx_formula_text("=SUM(A1:A5)") == "SUM(A1:A5)", "the leading = is dropped on the way out")
	ok_mark(tc, xlsx_formula_text("=A1+#CIRC!") == "A1+#REF!", "#CIRC! becomes #REF!, which Excel has")
	ok_mark(tc, xlsx_error_text(.Circ) == "#REF!", "a circular value exports as #REF!")
	ok_mark(tc, xlsx_error_text(.Div0) == "#DIV/0!", "every other error keeps its own spelling")
	ok_mark(tc, xlsx_normalise_formula("VLOOKUP(\"x\",A1:B2,2,FALSE())") == "VLOOKUP(\"x\",A1:B2,2,FALSE)", "FALSE() comes in as the literal FALSE")
	ok_mark(tc, xlsx_normalise_formula("_xlfn.CONCAT(A1,B1)") == "CONCAT(A1,B1)", "the _xlfn. prefix is stripped")
	ok_mark(tc, xlsx_normalise_formula("\"FALSE()\"&TRUE()") == "\"FALSE()\"&TRUE", "a rewrite does not reach inside a string literal")
	ok_mark(tc, xlsx_normalise_formula("A1+1") == "A1+1", "a formula with nothing to translate is left alone")

	// --- a real export -----------------------------------------------------
	fx: Fx
	fx_init(&fx)
	defer fx_done(&fx)
	sh := &fx.sh
	build_ledger(sh)

	raw := xlsx_bytes(sh, "ledger", context.temp_allocator)
	files, zok := zip_read(raw, context.temp_allocator)
	ok_mark(tc, zok, "the exported workbook is a readable ZIP")

	PARTS := [?]string {
		"[Content_Types].xml",
		"_rels/.rels",
		"xl/workbook.xml",
		"xl/_rels/workbook.xml.rels",
		"xl/worksheets/sheet1.xml",
		"xl/styles.xml",
		"xl/sharedStrings.xml",
	}
	ok_mark(tc, len(files) == len(PARTS), fmt.tprintf("the package has %d parts, got %d", len(PARTS), len(files)))
	ok_mark(tc, len(files) > 0 && files[0].name == "[Content_Types].xml", "[Content_Types].xml comes first in the archive")
	for part in PARTS {
		data, found := zip_find(files, part)
		ok_mark(tc, found, fmt.tprintf("the package contains %s", part))
		if !found {
			continue
		}
		doc, err := xml.parse_bytes(data, XML_OPTS, part, nil, context.temp_allocator)
		ok_mark(tc, err == .None && doc != nil, fmt.tprintf("%s is well-formed XML (%v)", part, err))
	}

	sheet_xml, _ := zip_find(files, "xl/worksheets/sheet1.xml")
	sx := string(sheet_xml)
	ok_mark(tc, strings.contains(sx, "<f>B2*C2</f>"), "a cell formula is written as <f>")
	ok_mark(tc, strings.contains(sx, "<f>SUM(D2:D4)</f>"), "an aggregate formula is written as <f>")
	ok_mark(tc, strings.contains(sx, "<f>D2/$D$5</f>"), "an absolute reference keeps its dollar signs")
	ok_mark(tc, strings.contains(sx, "<v>42</v>"), "the cached value is written beside the formula")
	ok_mark(tc, strings.contains(sx, "&quot;Gadget&quot;"), "a string inside a formula is escaped, not quoted raw")
	ok_mark(tc, strings.contains(sx, "t=\"e\"><f>1/0</f><v>#DIV/0!</v>"), "an error keeps its formula and its error value")
	ok_mark(tc, !strings.contains(sx, "#CIRC!"), "no #CIRC! reaches the file — Excel has no such literal")
	ok_mark(tc, strings.contains(sx, "<f>B17+1</f>"), "a circular cell still exports its formula")
	ok_mark(tc, strings.count(sx, "<v>#REF!</v>") == 2, "both circular cells cache #REF!")
	ok_mark(tc, strings.contains(sx, "customWidth=\"1\""), "column widths are written")
	ok_mark(tc, strings.contains(sx, "customHeight=\"1\""), "row heights are written")
	ok_mark(tc, strings.contains(sx, "ht=\"22.50\""), "a 30px row is written as 22.5pt")

	wb_xml, _ := zip_find(files, "xl/workbook.xml")
	ok_mark(tc, strings.contains(string(wb_xml), "fullCalcOnLoad=\"1\""), "the book asks the reader to recalculate on open")
	ok_mark(tc, strings.contains(string(wb_xml), "date1904=\"false\""), "the book declares the 1900 date system")
	ok_mark(tc, strings.contains(string(wb_xml), "name=\"ledger\""), "the sheet carries the document's name")

	sty_xml, _ := zip_find(files, "xl/styles.xml")
	st := string(sty_xml)
	ok_mark(tc, strings.contains(st, "&quot;$&quot;#,##0.00"), "the currency format code is written, escaped for XML")
	ok_mark(tc, strings.contains(st, "0.0%"), "the percent format code is written")
	ok_mark(tc, strings.contains(st, "yyyy\\-mm\\-dd"), "the date format code is written")
	ok_mark(tc, strings.contains(st, "0.000E+00"), "the scientific format code is written")
	ok_mark(tc, strings.contains(st, "horizontal=\"center\""), "a centred cell writes its alignment")
	ok_mark(tc, strings.contains(st, "<b/>"), "a bold font record is written")
	ok_mark(tc, strings.contains(st, "<i/>"), "an italic font record is written")

	sst_xml, _ := zip_find(files, "xl/sharedStrings.xml")
	ss := string(sst_xml)
	ok_mark(tc, strings.contains(ss, "<t>Widget</t>"), "text cells go into the shared string table")
	ok_mark(tc, strings.count(ss, "<si>") == strings.count(ss, "</si>"), "the string table is balanced")

	// --- and back again ----------------------------------------------------
	fx2: Fx
	fx_init(&fx2)
	defer fx_done(&fx2)
	s2 := &fx2.sh
	good, rows, cols, name := xlsx_read_bytes(s2, raw, {0, 0})
	ok_mark(tc, good, "the exported workbook imports")
	ok_mark(tc, name == "ledger", "the sheet name comes back")
	ok_mark(tc, rows == 20 && cols == 5, fmt.tprintf("the used range comes back as 20x5, got %dx%d", rows, cols))
	ok_mark(tc, len(s2.cells) == len(sh.cells), fmt.tprintf("%d cells out, %d cells back", len(sh.cells), len(s2.cells)))

	// Every cell: the formula, the value it settles on, and the format it
	// carries. These are the assertions that matter.
	//
	// Formulas are compared byte for byte — that is the whole point of the
	// format. Literals are compared by what they display, because the file
	// stores a number and a format rather than the keystrokes: `$3.50` typed
	// into a cell comes back as the number 3.5 with the currency format, which
	// shows `$3.50` again and is the same cell by every measure a reader has.
	bad_input, bad_value, bad_fmt := 0, 0, 0
	first_bad := ""
	for a, c in sh.cells {
		c2 := cell_at(s2, a)
		if c2 == nil {
			bad_input += 1
			continue
		}
		if c.ast != nil && c.input != c2.input {
			bad_input += 1
			if first_bad == "" {
				first_bad = fmt.tprintf("%s: %q -> %q", addr_name(a), c.input, c2.input)
			}
		}
		if format_value(c.val, c.fmt) != format_value(c2.val, c2.fmt) {
			bad_value += 1
			if first_bad == "" {
				first_bad = fmt.tprintf(
					"%s: %q -> %q",
					addr_name(a),
					format_value(c.val, c.fmt),
					format_value(c2.val, c2.fmt),
				)
			}
		}
		if c.fmt != c2.fmt {
			bad_fmt += 1
			if first_bad == "" {
				first_bad = fmt.tprintf("%s: %v -> %v", addr_name(a), c.fmt, c2.fmt)
			}
		}
	}
	ok_mark(tc, bad_input == 0, fmt.tprintf("every formula round-trips byte for byte (%d wrong, first %s)", bad_input, first_bad))
	ok_mark(tc, bad_value == 0, fmt.tprintf("every cell displays the same after a round trip (%d wrong, first %s)", bad_value, first_bad))
	ok_mark(tc, bad_fmt == 0, fmt.tprintf("every cell's format round-trips (%d wrong, first %s)", bad_fmt, first_bad))

	// The interesting individual cells, named, so a failure says which.
	at_disp(tc, s2, "D2", "$42.00")
	at_disp(tc, s2, "E2", "26.5%")
	at_disp(tc, s2, "D5", "$158.44")
	at_disp(tc, s2, "B7", "2026-10-04")
	at_disp(tc, s2, "B8", "88")
	at_num(tc, s2, "B9", 1024)
	at_num(tc, s2, "B10", 40)
	at_text(tc, s2, "B11", "Widget x 12")
	at_disp(tc, s2, "B12", "1,234,567.89")
	at_disp(tc, s2, "B13", "6.022E+23")
	at_err(tc, s2, "B14", .Div0)
	at_err(tc, s2, "B15", .Name)
	at_err(tc, s2, "B16", .Circ)
	at_input(tc, s2, "B16", "=B17+1")
	at_num(tc, s2, "B18", 7)
	at_text(tc, s2, "B19", "DOOH")
	ok_mark(tc, value_at(s2, ref("B20")).kind == .Bool, "a boolean comes back as a boolean")

	ok_mark(tc, abs(col_width(s2, 0) - 170) < 0.5, fmt.tprintf("the 170px column comes back (%v)", col_width(s2, 0)))
	ok_mark(tc, abs(col_width(s2, 3) - 110) < 0.5, fmt.tprintf("the 110px column comes back (%v)", col_width(s2, 3)))
	ok_mark(tc, abs(row_height(s2, 0) - 30) < 0.5, fmt.tprintf("the 30px row comes back (%v)", row_height(s2, 0)))

	// A formula that does not parse is kept as text, because writing a
	// formula Excel cannot read would make the whole file unopenable.
	{
		fx3: Fx
		fx_init(&fx3)
		defer fx_done(&fx3)
		put(&fx3.sh, "A1", "=SUM(")
		recalc(&fx3.sh)
		r3 := xlsx_bytes(&fx3.sh, "broken", context.temp_allocator)
		f3, _ := zip_read(r3, context.temp_allocator)
		sx3, _ := zip_find(f3, "xl/worksheets/sheet1.xml")
		ok_mark(tc, !strings.contains(string(sx3), "<f>"), "an unparseable formula is not written as a formula")
		ss3, _ := zip_find(f3, "xl/sharedStrings.xml")
		ok_mark(tc, strings.contains(string(ss3), "=SUM("), "an unparseable formula is kept verbatim as text")
	}

	// A text cell that looks like a number has to come back as text.
	{
		fx4: Fx
		fx_init(&fx4)
		defer fx_done(&fx4)
		put(&fx4.sh, "A1", "'007")
		put(&fx4.sh, "A2", "  padded  ")
		recalc(&fx4.sh)
		r4 := xlsx_bytes(&fx4.sh, "text", context.temp_allocator)
		fx5: Fx
		fx_init(&fx5)
		defer fx_done(&fx5)
		g4, _, _, _ := xlsx_read_bytes(&fx5.sh, r4, {0, 0})
		ok_mark(tc, g4, "the text workbook imports")
		at_text(tc, &fx5.sh, "A1", "007")
		at_text(tc, &fx5.sh, "A2", "  padded  ")
	}

	// A shared formula: Excel writes a run of identical formulas once and has
	// the rest point at it by index. Reconstructing the followers is the
	// importer's job, so it gets a hand-built workbook to do it on.
	{
		sheet := fmt.tprintf(
			`<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="%s"><sheetData>` +
			`<row r="1"><c r="A1"><v>10</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2</f><v>20</v></c></row>` +
			`<row r="2"><c r="A2"><v>11</v></c><c r="B2"><f t="shared" si="0"/><v>22</v></c></row>` +
			`<row r="3"><c r="A3"><v>12</v></c><c r="B3"><f t="shared" si="0"/><v>24</v></c></row>` +
			`</sheetData></worksheet>`,
			NS_MAIN,
		)
		z := zip_make(context.temp_allocator)
		zip_add_string(&z, "[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
		zip_add_string(&z, "xl/worksheets/sheet1.xml", sheet)
		raw5 := zip_finish(&z)

		fx6: Fx
		fx_init(&fx6)
		defer fx_done(&fx6)
		g5, _, _, _ := xlsx_read_bytes(&fx6.sh, raw5, {0, 0})
		ok_mark(tc, g5, "a workbook with shared formulas imports")
		at_input(tc, &fx6.sh, "B1", "=A1*2")
		at_input(tc, &fx6.sh, "B2", "=A2*2")
		at_input(tc, &fx6.sh, "B3", "=A3*2")
		at_num(tc, &fx6.sh, "B3", 24)
	}

	// Inline strings instead of a shared table — the other way a writer can
	// spell a text cell.
	{
		sheet := fmt.tprintf(
			`<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="%s"><sheetData>` +
			`<row r="1"><c r="A1" t="inlineStr"><is><t>hello</t></is></c></row></sheetData></worksheet>`,
			NS_MAIN,
		)
		z := zip_make(context.temp_allocator)
		zip_add_string(&z, "xl/worksheets/sheet1.xml", sheet)
		fx7: Fx
		fx_init(&fx7)
		defer fx_done(&fx7)
		g6, _, _, _ := xlsx_read_bytes(&fx7.sh, zip_finish(&z), {0, 0})
		ok_mark(tc, g6, "a workbook with inline strings imports")
		at_text(tc, &fx7.sh, "A1", "hello")
	}

	// Rubbish must be refused rather than crashing or half-importing.
	{
		fx8: Fx
		fx_init(&fx8)
		defer fx_done(&fx8)
		g7, _, _, _ := xlsx_read_bytes(&fx8.sh, transmute([]u8)string("this is not a zip"), {0, 0})
		ok_mark(tc, !g7, "a file that is not a ZIP is rejected")
		ok_mark(tc, len(fx8.sh.cells) == 0, "a rejected import leaves the sheet untouched")
	}

	// An import lands at the cursor, like a paste.
	{
		fx9: Fx
		fx_init(&fx9)
		defer fx_done(&fx9)
		g8, _, _, _ := xlsx_read_bytes(&fx9.sh, raw, ref("C3"))
		ok_mark(tc, g8, "an offset import succeeds")
		at_text(tc, &fx9.sh, "C3", "Item")
		// The formulas move with it: D2*E2 one row and two columns over.
		at_input(tc, &fx9.sh, "F4", "=D4*E4")
	}
}
