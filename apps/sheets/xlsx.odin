// .xlsx — SpreadsheetML, both directions.
//
// This is the format that makes the sheet handable to somebody who does not
// run this program. A CSV is a photograph of the values; an .xlsx carries the
// *formulas*, so the file recalculates in Excel and LibreOffice instead of
// going stale the moment anything changes. That is the whole reason for it.
//
// The package is a ZIP (see zip.odin, method 0 "stored") of seven parts:
//
//   [Content_Types].xml          what every part in the package is
//   _rels/.rels                  the package's one entry point
//   xl/workbook.xml              the book: one sheet, 1900 date system
//   xl/_rels/workbook.xml.rels   the book's parts
//   xl/worksheets/sheet1.xml     cells, formulas, cached values, geometry
//   xl/styles.xml                number formats, fonts, alignment
//   xl/sharedStrings.xml         the string table every text cell points into
//
// Three conversions have to be exactly right, and each is checked by the test
// suite rather than assumed:
//
//   * Date serials. Both this program and Excel count days from 1899-12-30, so
//     a serial crosses unchanged — but only from 1900-03-01 on. Excel's serial
//     60 is the 1900-02-29 that never existed, which this program deliberately
//     does not reproduce, so the 59 dates in January and February 1900 land one
//     day late. `date_parse` refuses years before 1900 anyway, and the suite
//     pins 1970-01-01 == 25569 and 2026-10-04 to catch a drift in either.
//   * Column widths. Excel measures a column in characters of the default
//     font, not pixels: width = (px - 5) / 7 for an 11pt Calibri grid.
//   * Row heights. Excel measures a row in points: pt = px * 0.75.
//
// And one judgement call. `#CIRC!` is this program's spelling for a circular
// reference and Excel has no such error literal, so a circular cell exports
// with its formula intact and `#REF!` as the cached value — which is exactly
// what Google Sheets writes for a circular dependency, and what Excel and
// LibreOffice both flag for themselves the moment they recalculate.
package main

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

// xml_escape makes a string safe for element content and for a double-quoted
// attribute. `&` has to go first or it would escape its own replacements.
xml_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	need := false
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&', '<', '>', '"', '\'', 0 ..< 0x09, 0x0b, 0x0c, 0x0e ..< 0x20:
			need = true
		}
		if need {
			break
		}
	}
	if !need {
		return s
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&apos;")
		case '\t', '\n', '\r':
			strings.write_byte(&b, c)
		case 0 ..< 0x20:
			// XML 1.0 has no escape for these at all; dropping them is the
			// only thing a conforming writer can do.
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// xml_escape_preserve is `xml_escape` plus one defence. Odin's XML reader
// strips trailing whitespace from every tag body unconditionally, so a text
// cell ending in a space would lose it on the way back in — and so would any
// other reader that normalises the same way. Emitting the final run of
// whitespace as numeric character references puts it past that: a `&#32;` is
// decoded *after* the trim, so it survives. (This is a gap in core:encoding/xml,
// worked around here rather than patched there.)
xml_escape_preserve :: proc(s: string) -> string {
	ws :: proc(c: u8) -> bool {
		return c == ' ' || c == '\t' || c == '\r' || c == '\n'
	}
	lead := 0
	for lead < len(s) && ws(s[lead]) {
		lead += 1
	}
	if lead == len(s) {
		// All whitespace: every byte has to be a reference.
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< len(s) {
			fmt.sbprintf(&b, "&#%d;", int(s[i]))
		}
		return strings.to_string(b)
	}
	end := len(s)
	for end > lead && ws(s[end - 1]) {
		end -= 1
	}
	if lead == 0 && end == len(s) {
		return xml_escape(s)
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< lead {
		fmt.sbprintf(&b, "&#%d;", int(s[i]))
	}
	strings.write_string(&b, xml_escape(s[lead:end]))
	for i in end ..< len(s) {
		fmt.sbprintf(&b, "&#%d;", int(s[i]))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

// numfmt_code renders one of this program's formats as an Excel format code.
// They line up with `format_value` in value.odin: Fixed and Currency group
// thousands, Percent does not, and a date prints ISO.
numfmt_code :: proc(num: Num_Format, dec: u8) -> string {
	zeros := ""
	if dec > 0 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '.')
		for _ in 0 ..< int(dec) {
			strings.write_byte(&b, '0')
		}
		zeros = strings.to_string(b)
	}
	switch num {
	case .General:
		return "General"
	case .Fixed:
		return fmt.tprintf("#,##0%s", zeros)
	case .Percent:
		return fmt.tprintf("0%s%%", zeros)
	case .Currency:
		return fmt.tprintf("\"$\"#,##0%s", zeros)
	case .Date:
		return "yyyy\\-mm\\-dd"
	case .Scientific:
		return fmt.tprintf("0%sE+00", zeros)
	}
	return "General"
}

// A cell's format reduced to what the file can carry. Decimals are forced to
// zero where the format ignores them, so two cells that look identical share
// one style record.
Xlsx_Style :: struct {
	num:    Num_Format,
	dec:    u8,
	align:  Halign,
	bold:   bool,
	italic: bool,
}

style_of :: proc(f: Cell_Fmt) -> Xlsx_Style {
	dec := f.dec
	if f.num == .General || f.num == .Date {
		dec = 0
	}
	return {num = f.num, dec = dec, align = f.align, bold = f.bold, italic = f.italic}
}

XLSX_FIRST_CUSTOM_NUMFMT :: 164

// font_id packs bold and italic into the four font records styles.xml writes.
@(private = "file")
font_id :: proc(s: Xlsx_Style) -> int {
	return (s.bold ? 1 : 0) | (s.italic ? 2 : 0)
}

@(private = "file")
halign_name :: proc(a: Halign) -> string {
	switch a {
	case .Left:
		return "left"
	case .Center:
		return "center"
	case .Right:
		return "right"
	case .Auto:
		return ""
	}
	return ""
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// Excel's column width is in units of the default font's '0' glyph plus the
// cell padding: 7 pixels per character and 5 pixels of padding at 96 dpi.
XLSX_CHAR_PX :: f32(7)
XLSX_PAD_PX :: f32(5)

px_to_chars :: proc(px: f32) -> f32 {
	return max(0, (px - XLSX_PAD_PX) / XLSX_CHAR_PX)
}

chars_to_px :: proc(ch: f32) -> f32 {
	return ch * XLSX_CHAR_PX + XLSX_PAD_PX
}

// A row is in points, and a logical pixel is three quarters of a point.
px_to_points :: proc(px: f32) -> f32 {
	return px * 0.75
}

points_to_px :: proc(pt: f32) -> f32 {
	return pt / 0.75
}

@(private = "file")
f2 :: proc(x: f32) -> string {
	return fmt.tprintf("%.2f", x)
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

// xlsx_sheet_name trims a name to what the format allows: 31 characters, none
// of the six that Excel reserves for its own reference syntax.
xlsx_sheet_name :: proc(name: string) -> string {
	base := strip_ext(base_name(name))
	if strings.trim_space(base) == "" {
		base = "Sheet1"
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(base) {
		switch base[i] {
		case '[', ']', ':', '*', '?', '/', '\\':
			strings.write_byte(&b, '_')
		case:
			strings.write_byte(&b, base[i])
		}
	}
	out := strings.to_string(b)
	if len(out) > 31 {
		out = out[:31]
	}
	return out
}

// xlsx_formula_text turns a cell's input into an Excel formula body: the
// leading `=` goes, and `#CIRC!` — which Excel does not have — becomes
// `#REF!`. Everything else in this program's formula language is already
// Excel's: `^` for power, postfix `%`, `&` for concatenation, `<>` for not
// equal, `,` between arguments, and a function set that is Excel's by name.
xlsx_formula_text :: proc(input: string) -> string {
	t := strings.trim_space(input)
	if len(t) > 0 && t[0] == '=' {
		t = t[1:]
	}
	if !strings.contains(t, "#CIRC!") {
		return t
	}
	return strings.replace_all(t, "#CIRC!", "#REF!", context.temp_allocator) or_else t
}

// xlsx_error_text is the same mapping for a value, not a formula.
xlsx_error_text :: proc(e: Err) -> string {
	if e == .Circ {
		return "#REF!"
	}
	return err_text(e)
}

xlsx_bytes :: proc(sh: ^Sheet, name: string, allocator := context.allocator) -> []u8 {
	r0, c0 := 0, 0
	r1 := max(sh.max_row, 0)
	c1 := max(sh.max_col, 0)

	// --- the string table --------------------------------------------------
	// Shared strings rather than inline ones: a column of repeated labels is
	// the common case, and this is the form every reader optimises for.
	sst := make([dynamic]string, 0, 64, context.temp_allocator)
	sst_index := make(map[string]int, 64, context.temp_allocator)
	intern :: proc(sst: ^[dynamic]string, idx: ^map[string]int, s: string) -> int {
		if i, ok := idx[s]; ok {
			return i
		}
		i := len(sst)
		append(sst, s)
		idx[s] = i
		return i
	}

	// --- the style table ---------------------------------------------------
	xfs := make([dynamic]Xlsx_Style, 0, 16, context.temp_allocator)
	xf_index := make(map[Xlsx_Style]int, 16, context.temp_allocator)
	append(&xfs, Xlsx_Style{}) // index 0 is the default, as the format requires
	xf_index[Xlsx_Style{}] = 0
	style_id :: proc(xfs: ^[dynamic]Xlsx_Style, idx: ^map[Xlsx_Style]int, s: Xlsx_Style) -> int {
		if i, ok := idx[s]; ok {
			return i
		}
		i := len(xfs)
		append(xfs, s)
		idx[s] = i
		return i
	}

	// --- the sheet ---------------------------------------------------------
	sd := strings.builder_make(context.temp_allocator)
	rows_written := 0
	cells_written := 0
	formulas_written := 0

	for row in r0 ..= r1 {
		// Count the row's cells first: an empty <row> is legal but noise.
		n := 0
		for col in c0 ..= c1 {
			if cell_at(sh, {row, col}) != nil {
				n += 1
			}
		}
		_, has_h := sh.row_h[row]
		if n == 0 && !has_h {
			continue
		}
		rows_written += 1
		if has_h {
			fmt.sbprintf(
				&sd,
				"<row r=\"%d\" ht=\"%s\" customHeight=\"1\">",
				row + 1,
				f2(px_to_points(row_height(sh, row))),
			)
		} else {
			fmt.sbprintf(&sd, "<row r=\"%d\">", row + 1)
		}
		for col in c0 ..= c1 {
			c := cell_at(sh, {row, col})
			if c == nil {
				continue
			}
			cells_written += 1
			ref := fmt.tprintf("%s%d", col_name(col), row + 1)
			sid := style_id(&xfs, &xf_index, style_of(c.fmt))

			// A formula that parsed goes out as a formula with its cached
			// value beside it. One that did not parse is kept as text: the
			// user still has to be able to see and repair it, and writing a
			// formula Excel cannot parse would make the whole file unopenable.
			live := c.ast != nil
			if live {
				f := xlsx_formula_text(c.input)
				formulas_written += 1
				switch c.val.kind {
				case .Number:
					fmt.sbprintf(
						&sd,
						"<c r=\"%s\" s=\"%d\"><f>%s</f><v>%s</v></c>",
						ref,
						sid,
						xml_escape(f),
						number_source(c.val.num),
					)
				case .Text:
					fmt.sbprintf(
						&sd,
						"<c r=\"%s\" s=\"%d\" t=\"str\"><f>%s</f><v>%s</v></c>",
						ref,
						sid,
						xml_escape(f),
						xml_escape_preserve(c.val.text),
					)
				case .Bool:
					fmt.sbprintf(
						&sd,
						"<c r=\"%s\" s=\"%d\" t=\"b\"><f>%s</f><v>%d</v></c>",
						ref,
						sid,
						xml_escape(f),
						c.val.num != 0 ? 1 : 0,
					)
				case .Error:
					fmt.sbprintf(
						&sd,
						"<c r=\"%s\" s=\"%d\" t=\"e\"><f>%s</f><v>%s</v></c>",
						ref,
						sid,
						xml_escape(f),
						xlsx_error_text(c.val.err),
					)
				case .Empty:
					fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\"><f>%s</f></c>", ref, sid, xml_escape(f))
				}
				continue
			}

			// Input that starts with `=` but did not parse is not a formula
			// and must not be written as one — Excel would refuse the whole
			// file. It is not its own error value either: what the user needs
			// back is the text they typed, so they can repair it.
			if t := strings.trim_space(c.input); len(t) > 1 && t[0] == '=' {
				si := intern(&sst, &sst_index, c.input)
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"s\"><v>%d</v></c>", ref, sid, si)
				continue
			}

			switch c.val.kind {
			case .Number:
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\"><v>%s</v></c>", ref, sid, number_source(c.val.num))
			case .Bool:
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"b\"><v>%d</v></c>", ref, sid, c.val.num != 0 ? 1 : 0)
			case .Error:
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"e\"><v>%s</v></c>", ref, sid, xlsx_error_text(c.val.err))
			case .Text:
				si := intern(&sst, &sst_index, c.val.text)
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"s\"><v>%d</v></c>", ref, sid, si)
			case .Empty:
				// A cell that exists only to carry a format. It still needs
				// the style, or the formatting is lost.
				if c.input != "" && strings.trim_space(c.input) != "" {
					si := intern(&sst, &sst_index, c.input)
					fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"s\"><v>%d</v></c>", ref, sid, si)
				} else {
					fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\"/>", ref, sid)
				}
			}
		}
		strings.write_string(&sd, "</row>")
	}

	// --- columns -----------------------------------------------------------
	cols := strings.builder_make(context.temp_allocator)
	{
		// Sorted, so the part is stable and a diff of two exports is readable.
		idx := make([dynamic]int, 0, len(sh.col_w), context.temp_allocator)
		for i in sh.col_w {
			append(&idx, i)
		}
		for i in 1 ..< len(idx) {
			x := idx[i]
			j := i - 1
			for j >= 0 && idx[j] > x {
				idx[j + 1] = idx[j]
				j -= 1
			}
			idx[j + 1] = x
		}
		if len(idx) > 0 {
			strings.write_string(&cols, "<cols>")
			for i in idx {
				fmt.sbprintf(
					&cols,
					"<col min=\"%d\" max=\"%d\" width=\"%s\" customWidth=\"1\"/>",
					i + 1,
					i + 1,
					f2(px_to_chars(col_width(sh, i))),
				)
			}
			strings.write_string(&cols, "</cols>")
		}
	}

	dim := fmt.tprintf("%s%d:%s%d", col_name(c0), r0 + 1, col_name(c1), r1 + 1)
	sheet_xml := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="%s" xmlns:r="%s"><dimension ref="%s"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="%s" defaultColWidth="%s"/>%s<sheetData>%s</sheetData></worksheet>`,
		NS_MAIN,
		NS_REL,
		dim,
		f2(px_to_points(DEFAULT_ROW_H)),
		f2(px_to_chars(DEFAULT_COL_W)),
		strings.to_string(cols),
		strings.to_string(sd),
	)

	// --- styles ------------------------------------------------------------
	// Number format codes are interned too: two styles that differ only in
	// boldness must not produce two identical numFmt records.
	codes := make([dynamic]string, 0, 8, context.temp_allocator)
	code_id := make(map[string]int, 8, context.temp_allocator)
	numfmt_ids := make([]int, len(xfs), context.temp_allocator)
	for s, i in xfs {
		if s.num == .General {
			numfmt_ids[i] = 0 // the builtin
			continue
		}
		code := numfmt_code(s.num, s.dec)
		if id, ok := code_id[code]; ok {
			numfmt_ids[i] = id
			continue
		}
		id := XLSX_FIRST_CUSTOM_NUMFMT + len(codes)
		append(&codes, code)
		code_id[code] = id
		numfmt_ids[i] = id
	}

	st := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&st, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"%s\">", NS_MAIN)
	if len(codes) > 0 {
		fmt.sbprintf(&st, "<numFmts count=\"%d\">", len(codes))
		for code, i in codes {
			fmt.sbprintf(
				&st,
				"<numFmt numFmtId=\"%d\" formatCode=\"%s\"/>",
				XLSX_FIRST_CUSTOM_NUMFMT + i,
				xml_escape(code),
			)
		}
		strings.write_string(&st, "</numFmts>")
	}
	strings.write_string(&st, "<fonts count=\"4\">")
	for i in 0 ..< 4 {
		strings.write_string(&st, "<font>")
		if i & 1 != 0 {
			strings.write_string(&st, "<b/>")
		}
		if i & 2 != 0 {
			strings.write_string(&st, "<i/>")
		}
		strings.write_string(&st, "<sz val=\"11\"/><color theme=\"1\"/><name val=\"Calibri\"/><family val=\"2\"/><scheme val=\"minor\"/></font>")
	}
	strings.write_string(&st, "</fonts>")
	strings.write_string(
		&st,
		`<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>`,
	)
	fmt.sbprintf(&st, "<cellXfs count=\"%d\">", len(xfs))
	for s, i in xfs {
		fid := font_id(s)
		al := halign_name(s.align)
		fmt.sbprintf(&st, "<xf numFmtId=\"%d\" fontId=\"%d\" fillId=\"0\" borderId=\"0\" xfId=\"0\"", numfmt_ids[i], fid)
		if numfmt_ids[i] != 0 {
			strings.write_string(&st, " applyNumberFormat=\"1\"")
		}
		if fid != 0 {
			strings.write_string(&st, " applyFont=\"1\"")
		}
		if al != "" {
			fmt.sbprintf(&st, " applyAlignment=\"1\"><alignment horizontal=\"%s\"/></xf>", al)
		} else {
			strings.write_string(&st, "/>")
		}
	}
	strings.write_string(
		&st,
		`</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/></styleSheet>`,
	)

	// --- shared strings ----------------------------------------------------
	ss := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&ss,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<sst xmlns=\"%s\" count=\"%d\" uniqueCount=\"%d\">",
		NS_MAIN,
		len(sst),
		len(sst),
	)
	for s in sst {
		// Leading or trailing whitespace is only preserved if the file says so.
		keep := len(s) > 0 && (s[0] == ' ' || s[len(s) - 1] == ' ' || s[0] == '\t' || s[len(s) - 1] == '\t')
		if keep {
			fmt.sbprintf(&ss, "<si><t xml:space=\"preserve\">%s</t></si>", xml_escape_preserve(s))
		} else {
			fmt.sbprintf(&ss, "<si><t>%s</t></si>", xml_escape(s))
		}
	}
	strings.write_string(&ss, "</sst>")

	// --- the book ----------------------------------------------------------
	// fullCalcOnLoad is the point of the exercise: the reader recomputes every
	// formula on open rather than trusting the cached values written here, so
	// a file that opens with the right numbers proves the formulas crossed.
	wb := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="%s" xmlns:r="%s"><workbookPr date1904="false"/><bookViews><workbookView/></bookViews><sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="124519" fullCalcOnLoad="1"/></workbook>`,
		NS_MAIN,
		NS_REL,
		xml_escape(xlsx_sheet_name(name)),
	)

	content_types := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>`,
	)

	root_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
		NS_PKG_REL,
		NS_REL_TYPE,
	)

	wb_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="%s/styles" Target="styles.xml"/><Relationship Id="rId3" Type="%s/sharedStrings" Target="sharedStrings.xml"/></Relationships>`,
		NS_PKG_REL,
		NS_REL_TYPE,
		NS_REL_TYPE,
		NS_REL_TYPE,
	)

	z := zip_make(context.temp_allocator)
	// [Content_Types].xml first: OPC requires it in the package, and readers
	// that stream the archive expect to meet it before anything it describes.
	zip_add_string(&z, "[Content_Types].xml", content_types)
	zip_add_string(&z, "_rels/.rels", root_rels)
	zip_add_string(&z, "xl/workbook.xml", wb)
	zip_add_string(&z, "xl/_rels/workbook.xml.rels", wb_rels)
	zip_add_string(&z, "xl/worksheets/sheet1.xml", sheet_xml)
	zip_add_string(&z, "xl/styles.xml", strings.to_string(st))
	zip_add_string(&z, "xl/sharedStrings.xml", strings.to_string(ss))
	raw := zip_finish(&z)
	out := make([]u8, len(raw), allocator)
	copy(out, raw)
	return out
}

NS_MAIN :: "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG_REL :: "http://schemas.openxmlformats.org/package/2006/relationships"
NS_REL_TYPE :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

xlsx_write_file :: proc(sh: ^Sheet, path, name: string) -> bool {
	data := xlsx_bytes(sh, name, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

// ---------------------------------------------------------------------------
// Import
//
// Reading somebody else's .xlsx means reading somebody else's conventions:
// strings may be shared or inline, numbers may be dates in disguise, and the
// parts may be deflated. All three are handled.
// ---------------------------------------------------------------------------

XML_OPTS :: xml.Options {
	flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities},
}

// x_is compares an element name ignoring any namespace prefix, because a
// writer is free to emit `<x:sheetData>` instead of `<sheetData>`.
@(private = "file")
x_is :: proc(ident, name: string) -> bool {
	if ident == name {
		return true
	}
	if i := strings.last_index_byte(ident, ':'); i >= 0 {
		return ident[i + 1:] == name
	}
	return false
}

@(private = "file")
x_attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> string {
	for a in doc.elements[id].attribs {
		if x_is(a.key, key) {
			return a.val
		}
	}
	return ""
}

// x_text concatenates an element's direct character data.
@(private = "file")
x_text :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v in doc.elements[id].value {
		if s, ok := v.(string); ok {
			strings.write_string(&b, s)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
x_kids :: proc(doc: ^xml.Document, id: xml.Element_ID, name: string, allocator := context.temp_allocator) -> [dynamic]xml.Element_ID {
	out := make([dynamic]xml.Element_ID, allocator)
	for v in doc.elements[id].value {
		if cid, ok := v.(xml.Element_ID); ok {
			if doc.elements[cid].kind == .Element && x_is(doc.elements[cid].ident, name) {
				append(&out, cid)
			}
		}
	}
	return out
}

@(private = "file")
x_kid :: proc(doc: ^xml.Document, id: xml.Element_ID, name: string) -> (xml.Element_ID, bool) {
	for v in doc.elements[id].value {
		if cid, ok := v.(xml.Element_ID); ok {
			if doc.elements[cid].kind == .Element && x_is(doc.elements[cid].ident, name) {
				return cid, true
			}
		}
	}
	return 0, false
}

// The builtin number format codes an .xlsx is allowed to refer to by id alone.
// Only the ones a real file uses are listed; anything else falls through to
// General, which is the safe answer.
@(private = "file")
BUILTIN_NUMFMT := [?]struct {
	id:   int,
	code: string,
} {
	{1, "0"},
	{2, "0.00"},
	{3, "#,##0"},
	{4, "#,##0.00"},
	{9, "0%"},
	{10, "0.00%"},
	{11, "0.00E+00"},
	{14, "mm-dd-yy"},
	{15, "d-mmm-yy"},
	{16, "d-mmm"},
	{17, "mmm-yy"},
	{18, "h:mm AM/PM"},
	{19, "h:mm:ss AM/PM"},
	{20, "h:mm"},
	{21, "h:mm:ss"},
	{22, "m/d/yy h:mm"},
	{37, "#,##0 ;(#,##0)"},
	{38, "#,##0 ;[Red](#,##0)"},
	{39, "#,##0.00;(#,##0.00)"},
	{40, "#,##0.00;[Red](#,##0.00)"},
	{44, "_(\"$\"* #,##0.00_)"},
	{45, "mm:ss"},
	{46, "[h]:mm:ss"},
	{47, "mmss.0"},
	{48, "##0.0E+0"},
	{49, "@"},
}

// numfmt_from_code is the inverse of `numfmt_code`, generalised: it classifies
// *any* Excel format code into this program's six formats. Date detection has
// to come before the digit tests, because `mm` and `dd` are not digits but
// `yyyy\-mm\-dd` has no `0` in it at all.
numfmt_from_code :: proc(code_in: string) -> (num: Num_Format, dec: u8) {
	code := code_in
	if code == "" || code == "General" {
		return .General, 0
	}
	if code == "@" {
		return .General, 0 // the text format; nothing numeric to carry
	}
	// Take the positive section only: Excel codes are ;-separated by sign.
	if i := strings.index_byte(code, ';'); i > 0 {
		code = code[:i]
	}
	// Strip quoted literals so a currency symbol spelled "$" is found but the
	// letters inside a literal are not mistaken for date tokens.
	quoted := strings.builder_make(context.temp_allocator)
	bare := strings.builder_make(context.temp_allocator)
	in_q := false
	for i := 0; i < len(code); i += 1 {
		c := code[i]
		if c == '"' {
			in_q = !in_q
			continue
		}
		if c == '\\' {
			// An escaped character is a literal, which is how LibreOffice
			// spells a currency symbol: `\$#,##0.00`. Dropping it would lose
			// the one glyph that says this is money.
			if i + 1 < len(code) {
				strings.write_byte(&quoted, code[i + 1])
			}
			i += 1
			continue
		}
		if in_q {
			strings.write_byte(&quoted, c)
		} else {
			strings.write_byte(&bare, c)
		}
	}
	lit := strings.to_string(quoted)
	body := strings.to_string(bare)
	low := strings.to_lower(body, context.temp_allocator)

	// Decimals: the run of zeros and hashes after the first decimal point.
	count_dec :: proc(s: string) -> u8 {
		d := strings.index_byte(s, '.')
		if d < 0 {
			return 0
		}
		n := 0
		for i in d + 1 ..< len(s) {
			if s[i] == '0' || s[i] == '#' {
				n += 1
			} else {
				break
			}
		}
		return u8(min(n, 9))
	}

	has_y := strings.contains(low, "y")
	has_d := strings.contains(low, "d")
	has_m := strings.contains(low, "m")
	if has_y || (has_d && has_m) {
		return .Date, 0
	}
	if strings.contains(low, "e+") || strings.contains(low, "e-") {
		return .Scientific, count_dec(body)
	}
	if strings.contains(body, "%") {
		return .Percent, count_dec(body)
	}
	if strings.contains(lit, "$") ||
	   strings.contains(body, "$") ||
	   strings.contains(lit, "¤") ||
	   strings.contains(lit, "€") ||
	   strings.contains(lit, "£") ||
	   strings.contains(lit, "¥") {
		return .Currency, count_dec(body)
	}
	if strings.contains(body, "0") || strings.contains(body, "#") {
		return .Fixed, count_dec(body)
	}
	return .General, 0
}

@(private = "file")
Xlsx_Xf :: struct {
	num:    Num_Format,
	dec:    u8,
	align:  Halign,
	bold:   bool,
	italic: bool,
}

// xlsx_read_bytes writes the first worksheet of an .xlsx into `sh` at `at`.
// `sh` is not cleared: an import lands where the cursor is, like a paste.
xlsx_read_bytes :: proc(sh: ^Sheet, raw: []u8, at: Addr) -> (ok: bool, rows, cols: int, name: string) {
	files, zok := zip_read(raw, context.temp_allocator)
	if !zok {
		return false, 0, 0, ""
	}

	parse :: proc(files: [dynamic]Zip_File, path: string) -> (^xml.Document, bool) {
		data, found := zip_find(files, path)
		if !found {
			return nil, false
		}
		doc, err := xml.parse_bytes(data, XML_OPTS, path, nil, context.temp_allocator)
		if err != .None && err != .Unexpected_Token {
			return nil, false
		}
		return doc, doc != nil
	}

	// --- which part is the first sheet? ------------------------------------
	sheet_part := "xl/worksheets/sheet1.xml"
	sheet_name := ""
	if wb, good := parse(files, "xl/workbook.xml"); good {
		if sheets_el, found := x_kid(wb, 0, "sheets"); found {
			kids := x_kids(wb, sheets_el, "sheet")
			if len(kids) > 0 {
				sheet_name = x_attr(wb, kids[0], "name")
				rid := x_attr(wb, kids[0], "id") // r:id, prefix-insensitive
				if rid != "" {
					if rels, rgood := parse(files, "xl/_rels/workbook.xml.rels"); rgood {
						for r in x_kids(rels, 0, "Relationship") {
							if x_attr(rels, r, "Id") != rid {
								continue
							}
							t := x_attr(rels, r, "Target")
							if t == "" {
								continue
							}
							if strings.has_prefix(t, "/") {
								sheet_part = t[1:]
							} else {
								sheet_part = fmt.tprintf("xl/%s", t)
							}
							break
						}
					}
				}
			}
		}
	}

	// --- the string table --------------------------------------------------
	sst := make([dynamic]string, context.temp_allocator)
	if ss, good := parse(files, "xl/sharedStrings.xml"); good {
		for si in x_kids(ss, 0, "si") {
			// Either one <t>, or a sequence of <r><t> runs to concatenate.
			b := strings.builder_make(context.temp_allocator)
			if t, found := x_kid(ss, si, "t"); found {
				strings.write_string(&b, x_text(ss, t))
			} else {
				for r in x_kids(ss, si, "r") {
					if t, f2 := x_kid(ss, r, "t"); f2 {
						strings.write_string(&b, x_text(ss, t))
					}
				}
			}
			append(&sst, strings.to_string(b))
		}
	}

	// --- styles ------------------------------------------------------------
	xfs := make([dynamic]Xlsx_Xf, context.temp_allocator)
	if sty, good := parse(files, "xl/styles.xml"); good {
		codes := make(map[int]string, 16, context.temp_allocator)
		for e in BUILTIN_NUMFMT {
			codes[e.id] = e.code
		}
		if nf, found := x_kid(sty, 0, "numFmts"); found {
			for n in x_kids(sty, nf, "numFmt") {
				if id, iok := strconv.parse_int(x_attr(sty, n, "numFmtId")); iok {
					codes[id] = x_attr(sty, n, "formatCode")
				}
			}
		}
		bolds := make([dynamic]bool, context.temp_allocator)
		italics := make([dynamic]bool, context.temp_allocator)
		if fo, found := x_kid(sty, 0, "fonts"); found {
			for f in x_kids(sty, fo, "font") {
				_, b := x_kid(sty, f, "b")
				_, i := x_kid(sty, f, "i")
				append(&bolds, b)
				append(&italics, i)
			}
		}
		if cx, found := x_kid(sty, 0, "cellXfs"); found {
			for x in x_kids(sty, cx, "xf") {
				e := Xlsx_Xf{}
				if id, iok := strconv.parse_int(x_attr(sty, x, "numFmtId")); iok && id != 0 {
					code, have := codes[id]
					if !have && id >= XLSX_FIRST_CUSTOM_NUMFMT {
						code = ""
					}
					e.num, e.dec = numfmt_from_code(code)
				}
				if fid, fok := strconv.parse_int(x_attr(sty, x, "fontId")); fok && fid >= 0 && fid < len(bolds) {
					e.bold = bolds[fid]
					e.italic = italics[fid]
				}
				if al, found2 := x_kid(sty, x, "alignment"); found2 {
					switch x_attr(sty, al, "horizontal") {
					case "left":
						e.align = .Left
					case "center", "centre", "centerContinuous":
						e.align = .Center
					case "right":
						e.align = .Right
					}
				}
				append(&xfs, e)
			}
		}
	}

	// --- the sheet ---------------------------------------------------------
	ws, wgood := parse(files, sheet_part)
	if !wgood {
		return false, 0, 0, sheet_name
	}

	if cl, found := x_kid(ws, 0, "cols"); found {
		for c in x_kids(ws, cl, "col") {
			lo, lok := strconv.parse_int(x_attr(ws, c, "min"))
			hi, hok := strconv.parse_int(x_attr(ws, c, "max"))
			w, wok := strconv.parse_f32(x_attr(ws, c, "width"))
			if !lok || !wok {
				continue
			}
			if !hok {
				hi = lo
			}
			// A writer may legally say max="16384" for the whole sheet; only
			// the columns the data reaches are worth materialising.
			hi = min(hi, lo + 255)
			for i in lo ..= hi {
				set_col_width(sh, at.col + i - 1, chars_to_px(w))
			}
		}
	}

	sdata, sfound := x_kid(ws, 0, "sheetData")
	if !sfound {
		return false, 0, 0, sheet_name
	}

	max_r, max_c := -1, -1
	shared := make(map[int]Shared_F, 16, context.temp_allocator)
	for rw in x_kids(ws, sdata, "row") {
		rn, rok := strconv.parse_int(x_attr(ws, rw, "r"))
		if !rok {
			continue
		}
		row := at.row + rn - 1
		if ht, hok := strconv.parse_f32(x_attr(ws, rw, "ht")); hok && x_attr(ws, rw, "customHeight") != "" {
			set_row_height(sh, row, points_to_px(ht))
		}
		for ce in x_kids(ws, rw, "c") {
			r, pok := ref_parse(x_attr(ws, ce, "r"))
			if !pok || r.row == NO_ROW {
				continue
			}
			a := Addr{at.row + r.row, at.col + r.col}
			t := x_attr(ws, ce, "t")
			vtxt := ""
			if v, found := x_kid(ws, ce, "v"); found {
				vtxt = x_text(ws, v)
			}

			// The style first: a number's format decides whether it is a date,
			// and therefore how its input text is written.
			xf := Xlsx_Xf{}
			if sid, sok := strconv.parse_int(x_attr(ws, ce, "s")); sok && sid >= 0 && sid < len(xfs) {
				xf = xfs[sid]
			}

			input := ""
			if f, found := x_kid(ws, ce, "f"); found {
				body := strings.trim_space(x_text(ws, f))
				if body != "" {
					input = fmt.tprintf("=%s", xlsx_normalise_formula(body))
					// Remember a shared formula's master so the cells that
					// only reference it by index can be rebuilt.
					if x_attr(ws, f, "t") == "shared" {
						if si, sok := strconv.parse_int(x_attr(ws, f, "si")); sok {
							shared[si] = Shared_F{text = input, at = {r.row, r.col}}
						}
					}
				} else if x_attr(ws, f, "t") == "shared" {
					// Excel writes a run of identical formulas once and has
					// the rest point at it by index; each one is the master
					// offset by the distance between the two cells.
					if si, sok := strconv.parse_int(x_attr(ws, f, "si")); sok {
						if m, have := shared[si]; have {
							input = offset_formula(
								m.text,
								r.row - m.at.row,
								r.col - m.at.col,
								context.temp_allocator,
							)
						}
					}
				}
			}
			if input == "" {
				switch t {
				case "s":
					if i, iok := strconv.parse_int(vtxt); iok && i >= 0 && i < len(sst) {
						input = xlsx_text_input(sst[i])
					}
				case "inlineStr":
					if is, found := x_kid(ws, ce, "is"); found {
						if tt, f2 := x_kid(ws, is, "t"); f2 {
							input = xlsx_text_input(x_text(ws, tt))
						}
					}
				case "str":
					input = xlsx_text_input(vtxt)
				case "b":
					input = vtxt == "1" || strings.equal_fold(vtxt, "true") ? "TRUE" : "FALSE"
				case "e":
					input = vtxt
				case "n", "":
					if vtxt != "" {
						// A date-formatted number keeps its serial; the Date
						// format applied below is what makes it read as a
						// date, which is exactly how this program stores one.
						input = strings.trim_space(vtxt)
					}
				case:
					input = xlsx_text_input(vtxt)
				}
			}

			if input == "" && xf == (Xlsx_Xf{}) {
				continue
			}
			if input != "" {
				// An import at a cursor is a paste: relative references move
				// with the data and absolute ones do not.
				if (at.row != 0 || at.col != 0) && len(input) > 1 && input[0] == '=' {
					input = offset_formula(input, at.row, at.col, context.temp_allocator)
				}
				set_input(sh, a, input)
			}
			set_cell_fmt(
				sh,
				a,
				Cell_Fmt{num = xf.num, dec = xf.dec, align = xf.align, bold = xf.bold, italic = xf.italic},
			)
			max_r = max(max_r, r.row)
			max_c = max(max_c, r.col)
		}
	}

	sh.graph_dirty = true
	recalc_all(sh)
	return true, max_r + 1, max_c + 1, sheet_name
}

// Shared_F is one entry of a worksheet's shared-formula table: the master's
// text and the cell it was written in.
@(private = "file")
Shared_F :: struct {
	text: string,
	at:   Addr,
}

// xlsx_normalise_formula translates the two things Excel and LibreOffice
// write that this program's formula language does not have:
//
//   * `_xlfn.` — the prefix Excel puts on functions older readers would not
//     know. The name after it is the real one.
//   * `TRUE()` and `FALSE()` — in the file format a boolean literal is a
//     zero-argument function call. Here it is a literal.
//
// Both rewrites skip string literals, so a cell containing the text
// `FALSE()` is left alone.
xlsx_normalise_formula :: proc(src: string) -> string {
	if !strings.contains(src, "_xlfn.") &&
	   !strings.contains(src, "TRUE()") &&
	   !strings.contains(src, "FALSE()") {
		return src
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(src) {
		if src[i] == '"' {
			// Copy the whole literal, doubled quotes included.
			strings.write_byte(&b, src[i])
			i += 1
			for i < len(src) {
				strings.write_byte(&b, src[i])
				if src[i] == '"' {
					if i + 1 < len(src) && src[i + 1] == '"' {
						strings.write_byte(&b, '"')
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		if strings.has_prefix(src[i:], "_xlfn.") {
			i += len("_xlfn.")
			continue
		}
		if strings.has_prefix(src[i:], "TRUE()") {
			strings.write_string(&b, "TRUE")
			i += len("TRUE()")
			continue
		}
		if strings.has_prefix(src[i:], "FALSE()") {
			strings.write_string(&b, "FALSE")
			i += len("FALSE()")
			continue
		}
		strings.write_byte(&b, src[i])
		i += 1
	}
	return strings.to_string(b)
}

// xlsx_text_input prepares a string cell for `set_input`, which otherwise
// re-infers a type: "120" in a text cell has to stay the text "120", and the
// leading apostrophe is how this program spells that.
xlsx_text_input :: proc(s: string) -> string {
	if s == "" {
		return ""
	}
	v, _, _ := literal_value(s)
	if v.kind == .Text {
		return s
	}
	return fmt.tprintf("'%s", s)
}

xlsx_read_file :: proc(sh: ^Sheet, path: string, at: Addr) -> (ok: bool, rows, cols: int, name: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false, 0, 0, ""
	}
	return xlsx_read_bytes(sh, data, at)
}
