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
font_id :: proc(s: Xlsx_Style) -> int {
	return (s.bold ? 1 : 0) | (s.italic ? 2 : 0)
}

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

// xlsx_tab_name is the same trimming applied to a sheet's own name, which —
// unlike a file name — must keep everything after a dot.
xlsx_tab_name :: proc(name: string) -> string {
	base := name
	if strings.trim_space(base) == "" {
		base = "Sheet"
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

// Xlsx_Tables are the two book-wide tables. They have to be book-wide, not
// sheet-wide: `s="3"` on a cell of Sheet2 means index 3 of the one cellXfs
// list, and `t="s"` with `<v>7</v>` means entry 7 of the one string table.
Xlsx_Tables :: struct {
	sst:       [dynamic]string,
	sst_index: map[string]int,
	xfs:       [dynamic]Xlsx_Style,
	xf_index:  map[Xlsx_Style]int,
}

tables_make :: proc() -> (t: Xlsx_Tables) {
	t.sst = make([dynamic]string, 0, 64, context.temp_allocator)
	t.sst_index = make(map[string]int, 64, context.temp_allocator)
	t.xfs = make([dynamic]Xlsx_Style, 0, 16, context.temp_allocator)
	t.xf_index = make(map[Xlsx_Style]int, 16, context.temp_allocator)
	append(&t.xfs, Xlsx_Style{}) // index 0 is the default, as the format requires
	t.xf_index[Xlsx_Style{}] = 0
	return
}

tbl_intern :: proc(t: ^Xlsx_Tables, s: string) -> int {
	if i, ok := t.sst_index[s]; ok {
		return i
	}
	i := len(t.sst)
	append(&t.sst, s)
	t.sst_index[s] = i
	return i
}

tbl_style :: proc(t: ^Xlsx_Tables, s: Xlsx_Style) -> int {
	if i, ok := t.xf_index[s]; ok {
		return i
	}
	i := len(t.xfs)
	append(&t.xfs, s)
	t.xf_index[s] = i
	return i
}

// xlsx_pane_xml is the frozen split. `state="frozen"` is what distinguishes a
// freeze from a split the user can drag, and `topLeftCell` names the first
// cell of the scrolling region — which is exactly `frz_cols`/`frz_rows`
// expressed in A1 notation.
xlsx_pane_xml :: proc(sh: ^Sheet) -> string {
	if sh.frz_rows <= 0 && sh.frz_cols <= 0 {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<pane")
	if sh.frz_cols > 0 {
		fmt.sbprintf(&b, " xSplit=\"%d\"", sh.frz_cols)
	}
	if sh.frz_rows > 0 {
		fmt.sbprintf(&b, " ySplit=\"%d\"", sh.frz_rows)
	}
	fmt.sbprintf(&b, " topLeftCell=\"%s\"", addr_name({sh.frz_rows, sh.frz_cols}))
	active := "bottomRight"
	if sh.frz_cols == 0 {
		active = "bottomLeft"
	} else if sh.frz_rows == 0 {
		active = "topRight"
	}
	fmt.sbprintf(&b, " activePane=\"%s\" state=\"frozen\"/>", active)
	return strings.to_string(b)
}

// xlsx_sheet_xml renders one worksheet part. `drawing` is the relationship id
// of this sheet's drawing, or "" when it has no charts.
xlsx_sheet_xml :: proc(sh: ^Sheet, t: ^Xlsx_Tables, drawing: string) -> string {
	r0, c0 := 0, 0
	r1 := max(sh.max_row, 0)
	c1 := max(sh.max_col, 0)

	sd := strings.builder_make(context.temp_allocator)
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
			ref := fmt.tprintf("%s%d", col_name(col), row + 1)
			sid := tbl_style(t, style_of(c.fmt))

			// A formula that parsed goes out as a formula with its cached
			// value beside it. One that did not parse is kept as text: the
			// user still has to be able to see and repair it, and writing a
			// formula Excel cannot parse would make the whole file unopenable.
			if c.ast != nil {
				f := xlsx_formula_text(c.input)
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
			if tt := strings.trim_space(c.input); len(tt) > 1 && tt[0] == '=' {
				si := tbl_intern(t, c.input)
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
				si := tbl_intern(t, c.val.text)
				fmt.sbprintf(&sd, "<c r=\"%s\" s=\"%d\" t=\"s\"><v>%d</v></c>", ref, sid, si)
			case .Empty:
				// A cell that exists only to carry a format. It still needs
				// the style, or the formatting is lost.
				if c.input != "" && strings.trim_space(c.input) != "" {
					si := tbl_intern(t, c.input)
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

	// --- merges ------------------------------------------------------------
	merges := strings.builder_make(context.temp_allocator)
	if len(sh.merges) > 0 {
		fmt.sbprintf(&merges, "<mergeCells count=\"%d\">", len(sh.merges))
		for m in sh.merges {
			fmt.sbprintf(&merges, "<mergeCell ref=\"%s\"/>", rect_text(m))
		}
		strings.write_string(&merges, "</mergeCells>")
	}

	draw := ""
	if drawing != "" {
		draw = fmt.tprintf("<drawing r:id=\"%s\"/>", drawing)
	}

	pane := xlsx_pane_xml(sh)
	dim := fmt.tprintf("%s%d:%s%d", col_name(c0), r0 + 1, col_name(c1), r1 + 1)
	// The element order here is the schema's, not a preference: dimension,
	// sheetViews, sheetFormatPr, cols, sheetData, mergeCells, drawing. A
	// reader that validates will refuse the part if they are shuffled.
	return fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="%s" xmlns:r="%s"><dimension ref="%s"/><sheetViews><sheetView workbookViewId="0">%s</sheetView></sheetViews><sheetFormatPr defaultRowHeight="%s" defaultColWidth="%s"/>%s<sheetData>%s</sheetData>%s%s</worksheet>`,
		NS_MAIN,
		NS_REL,
		dim,
		pane,
		f2(px_to_points(DEFAULT_ROW_H)),
		f2(px_to_chars(DEFAULT_COL_W)),
		strings.to_string(cols),
		strings.to_string(sd),
		strings.to_string(merges),
		draw,
	)
}

// Chart_Ref is one chart part as the package sees it.
@(private = "file")
Chart_Ref :: struct {
	sheet:      int, // index into `sheets`
	chart:      int, // index into that sheet's charts
	part:       int, // chartN.xml
	data_sheet: string,
}

// xlsx_compose builds the whole package. One sheet or twelve goes through the
// same path; the single-sheet entry point is just this with a one-element
// slice, so there is no second writer to keep in step.
xlsx_compose :: proc(
	bk: ^Book,
	sheets: []^Sheet,
	names: []string,
	allocator := context.allocator,
) -> []u8 {
	t := tables_make()

	// --- charts, so each sheet knows whether it needs a drawing -----------
	charts := make([dynamic]Chart_Ref, 0, 4, context.temp_allocator)
	for sh, si in sheets {
		for _, ci in sh.charts {
			// A chart's series formulas have to name the sheet the data is
			// on, under its *exported* name.
			dn := names[si]
			if sh.charts[ci].sheet != "" {
				for s2, j in sheets {
					if strings.equal_fold(s2.name, sh.charts[ci].sheet) {
						dn = names[j]
						break
					}
				}
			}
			append(&charts, Chart_Ref{si, ci, len(charts) + 1, dn})
		}
	}

	// --- the sheets -------------------------------------------------------
	sheet_xml := make([dynamic]string, 0, len(sheets), context.temp_allocator)
	for sh, si in sheets {
		rid := len(sh.charts) > 0 ? "rId1" : ""
		append(&sheet_xml, xlsx_sheet_xml(sh, &t, rid))
	}

	// --- styles ------------------------------------------------------------
	// Number format codes are interned too: two styles that differ only in
	// boldness must not produce two identical numFmt records.
	codes := make([dynamic]string, 0, 8, context.temp_allocator)
	code_id := make(map[string]int, 8, context.temp_allocator)
	numfmt_ids := make([]int, len(t.xfs), context.temp_allocator)
	for s, i in t.xfs {
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
	fmt.sbprintf(&st, "<cellXfs count=\"%d\">", len(t.xfs))
	for s, i in t.xfs {
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
		len(t.sst),
		len(t.sst),
	)
	for s in t.sst {
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
	wbb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&wbb,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"%s\" xmlns:r=\"%s\"><workbookPr date1904=\"false\"/><bookViews><workbookView activeTab=\"%d\"/></bookViews><sheets>",
		NS_MAIN,
		NS_REL,
		bk != nil ? clamp(bk.active, 0, max(len(sheets) - 1, 0)) : 0,
	)
	for nm, i in names {
		fmt.sbprintf(
			&wbb,
			"<sheet name=\"%s\" sheetId=\"%d\" r:id=\"rId%d\"/>",
			xml_escape(nm),
			i + 1,
			i + 1,
		)
	}
	strings.write_string(&wbb, "</sheets>")
	if bk != nil {
		// A sheet-local name carries `localSheetId`, the 0-based position of
		// its sheet *in this package* — so a name scoped to a sheet that is
		// not being written (a one-sheet export) is left out rather than
		// pinned to the wrong tab.
		entries := book_name_entries(bk)
		wrote := false
		for e in entries {
			local := -1
			if e.scope != "" {
				for s, j in sheets {
					if strings.equal_fold(s.name, e.scope) {
						local = j
						break
					}
				}
				if local < 0 {
					continue
				}
			}
			if !wrote {
				strings.write_string(&wbb, "<definedNames>")
				wrote = true
			}
			if local >= 0 {
				fmt.sbprintf(
					&wbb,
					"<definedName name=\"%s\" localSheetId=\"%d\">%s</definedName>",
					xml_escape(e.name),
					local,
					xml_escape(name_target(bk, e.def)),
				)
			} else {
				fmt.sbprintf(
					&wbb,
					"<definedName name=\"%s\">%s</definedName>",
					xml_escape(e.name),
					xml_escape(name_target(bk, e.def)),
				)
			}
		}
		if wrote {
			strings.write_string(&wbb, "</definedNames>")
		}
	}
	strings.write_string(&wbb, "<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/></workbook>")

	// --- [Content_Types] and the relationships -----------------------------
	ct := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&ct,
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>`,
	)
	for _, i in sheets {
		fmt.sbprintf(
			&ct,
			"<Override PartName=\"/xl/worksheets/sheet%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>",
			i + 1,
		)
	}
	strings.write_string(
		&ct,
		`<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>`,
	)
	for sh, i in sheets {
		if len(sh.charts) == 0 {
			continue
		}
		fmt.sbprintf(
			&ct,
			"<Override PartName=\"/xl/drawings/drawing%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>",
			i + 1,
		)
	}
	for cr in charts {
		fmt.sbprintf(
			&ct,
			"<Override PartName=\"/xl/charts/chart%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>",
			cr.part,
		)
	}
	strings.write_string(&ct, "</Types>")

	root_rels := fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
		NS_PKG_REL,
		NS_REL_TYPE,
	)

	wbr := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&wbr,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"%s\">",
		NS_PKG_REL,
	)
	for _, i in sheets {
		fmt.sbprintf(
			&wbr,
			"<Relationship Id=\"rId%d\" Type=\"%s/worksheet\" Target=\"worksheets/sheet%d.xml\"/>",
			i + 1,
			NS_REL_TYPE,
			i + 1,
		)
	}
	fmt.sbprintf(
		&wbr,
		"<Relationship Id=\"rId%d\" Type=\"%s/styles\" Target=\"styles.xml\"/><Relationship Id=\"rId%d\" Type=\"%s/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>",
		len(sheets) + 1,
		NS_REL_TYPE,
		len(sheets) + 2,
		NS_REL_TYPE,
	)

	z := zip_make(context.temp_allocator)
	// [Content_Types].xml first: OPC requires it in the package, and readers
	// that stream the archive expect to meet it before anything it describes.
	zip_add_string(&z, "[Content_Types].xml", strings.to_string(ct))
	zip_add_string(&z, "_rels/.rels", root_rels)
	zip_add_string(&z, "xl/workbook.xml", strings.to_string(wbb))
	zip_add_string(&z, "xl/_rels/workbook.xml.rels", strings.to_string(wbr))
	for x, i in sheet_xml {
		zip_add_string(&z, fmt.tprintf("xl/worksheets/sheet%d.xml", i + 1), x)
	}
	for sh, i in sheets {
		if len(sh.charts) == 0 {
			continue
		}
		zip_add_string(
			&z,
			fmt.tprintf("xl/worksheets/_rels/sheet%d.xml.rels", i + 1),
			sheet_rels_xml(i + 1),
		)
		first := 0
		for cr in charts {
			if cr.sheet == i {
				first = cr.part
				break
			}
		}
		zip_add_string(&z, fmt.tprintf("xl/drawings/drawing%d.xml", i + 1), drawing_part_xml(sh.charts[:]))
		zip_add_string(
			&z,
			fmt.tprintf("xl/drawings/_rels/drawing%d.xml.rels", i + 1),
			drawing_rels_xml(len(sh.charts), first),
		)
	}
	for cr in charts {
		zip_add_string(
			&z,
			fmt.tprintf("xl/charts/chart%d.xml", cr.part),
			chart_part_xml(sheets[cr.sheet], sheets[cr.sheet].charts[cr.chart], cr.data_sheet),
		)
	}
	zip_add_string(&z, "xl/styles.xml", strings.to_string(st))
	zip_add_string(&z, "xl/sharedStrings.xml", strings.to_string(ss))
	raw := zip_finish(&z)
	out := make([]u8, len(raw), allocator)
	copy(out, raw)
	return out
}

// xlsx_bytes writes a one-sheet workbook under `name`, which is the shape a
// caller with a single sheet in hand wants.
xlsx_bytes :: proc(sh: ^Sheet, name: string, allocator := context.allocator) -> []u8 {
	sheets := [1]^Sheet{sh}
	names := [1]string{xlsx_sheet_name(name)}
	return xlsx_compose(sh.book, sheets[:], names[:], allocator)
}

// xlsx_book_bytes writes the whole book, every sheet under its own name.
xlsx_book_bytes :: proc(bk: ^Book, allocator := context.allocator) -> []u8 {
	sheets := make([dynamic]^Sheet, 0, len(bk.sheets), context.temp_allocator)
	names := make([dynamic]string, 0, len(bk.sheets), context.temp_allocator)
	for sh in bk.sheets {
		append(&sheets, sh)
		append(&names, xlsx_tab_name(sh.name))
	}
	return xlsx_compose(bk, sheets[:], names[:], allocator)
}

xlsx_write_file :: proc(sh: ^Sheet, path, name: string) -> bool {
	data := xlsx_bytes(sh, name, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

xlsx_write_book :: proc(bk: ^Book, path: string) -> bool {
	data := xlsx_book_bytes(bk, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

NS_MAIN :: "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG_REL :: "http://schemas.openxmlformats.org/package/2006/relationships"
NS_REL_TYPE :: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

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
x_is :: proc(ident, name: string) -> bool {
	if ident == name {
		return true
	}
	if i := strings.last_index_byte(ident, ':'); i >= 0 {
		return ident[i + 1:] == name
	}
	return false
}

x_attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> string {
	for a in doc.elements[id].attribs {
		if x_is(a.key, key) {
			return a.val
		}
	}
	return ""
}

// x_text concatenates an element's direct character data.
x_text :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v in doc.elements[id].value {
		if s, ok := v.(string); ok {
			strings.write_string(&b, s)
		}
	}
	return strings.to_string(b)
}

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

Xlsx_Xf :: struct {
	num:    Num_Format,
	dec:    u8,
	align:  Halign,
	bold:   bool,
	italic: bool,
}

// Xlsx_Pkg is an opened package: the archive, plus the two book-wide tables
// every worksheet in it points into.
Xlsx_Pkg :: struct {
	files: [dynamic]Zip_File,
	sst:   [dynamic]string,
	xfs:   [dynamic]Xlsx_Xf,
}

// Xlsx_Tab is one entry of the workbook's sheet list.
Xlsx_Tab :: struct {
	name: string,
	part: string,
	rid:  string,
}

xlsx_parse :: proc(files: [dynamic]Zip_File, path: string) -> (^xml.Document, bool) {
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

// xlsx_rel_target resolves a relationship id inside a `_rels` part, returning
// the archive path it names.
xlsx_rel_target :: proc(
	files: [dynamic]Zip_File,
	rels_part: string,
	base: string,
	rid: string,
) -> (
	string,
	bool,
) {
	rels, ok := xlsx_parse(files, rels_part)
	if !ok {
		return "", false
	}
	for r in x_kids(rels, 0, "Relationship") {
		if x_attr(rels, r, "Id") != rid {
			continue
		}
		t := x_attr(rels, r, "Target")
		if t == "" {
			continue
		}
		return xlsx_resolve(base, t), true
	}
	return "", false
}

// xlsx_resolve joins a relationship target onto the directory of the part
// that referenced it, `../` included — which is how a drawing points back out
// of `xl/drawings/` and into `xl/charts/`.
xlsx_resolve :: proc(base, target: string) -> string {
	if strings.has_prefix(target, "/") {
		return target[1:]
	}
	dir := base
	t := target
	for strings.has_prefix(t, "../") {
		t = t[3:]
		if i := strings.last_index_byte(dir, '/'); i >= 0 {
			dir = dir[:i]
		} else {
			dir = ""
		}
	}
	if dir == "" {
		return strings.clone(t, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", t}, context.temp_allocator)
}

// xlsx_open reads everything that is shared between worksheets, and lists the
// sheets in the order the workbook declares them — which is the tab order.
xlsx_open :: proc(raw: []u8) -> (pkg: Xlsx_Pkg, tabs: [dynamic]Xlsx_Tab, ok: bool) {
	files, zok := zip_read(raw, context.temp_allocator)
	if !zok {
		return {}, nil, false
	}
	pkg.files = files
	tabs = make([dynamic]Xlsx_Tab, 0, 4, context.temp_allocator)

	if wb, good := xlsx_parse(files, "xl/workbook.xml"); good {
		if sheets_el, found := x_kid(wb, 0, "sheets"); found {
			for k in x_kids(wb, sheets_el, "sheet") {
				tab := Xlsx_Tab {
					name = x_attr(wb, k, "name"),
					rid  = x_attr(wb, k, "id"), // r:id, prefix-insensitive
				}
				if tab.rid != "" {
					if t, tok := xlsx_rel_target(
						files,
						"xl/_rels/workbook.xml.rels",
						"xl",
						tab.rid,
					); tok {
						tab.part = t
					}
				}
				if tab.part == "" {
					tab.part = fmt.tprintf("xl/worksheets/sheet%d.xml", len(tabs) + 1)
				}
				append(&tabs, tab)
			}
		}
	}
	if len(tabs) == 0 {
		// A hand-written fixture may have no workbook part at all.
		append(&tabs, Xlsx_Tab{name = "", part = "xl/worksheets/sheet1.xml"})
	}

	// --- the string table --------------------------------------------------
	pkg.sst = make([dynamic]string, context.temp_allocator)
	if ss, good := xlsx_parse(files, "xl/sharedStrings.xml"); good {
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
			append(&pkg.sst, strings.to_string(b))
		}
	}

	// --- styles ------------------------------------------------------------
	pkg.xfs = make([dynamic]Xlsx_Xf, context.temp_allocator)
	if sty, good := xlsx_parse(files, "xl/styles.xml"); good {
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
				append(&pkg.xfs, e)
			}
		}
	}
	return pkg, tabs, true
}

// xlsx_load_sheet writes one worksheet part into `sh` at `at`. `sh` is not
// cleared: an import can land where the cursor is, like a paste.
xlsx_load_sheet :: proc(
	sh: ^Sheet,
	pkg: ^Xlsx_Pkg,
	part: string,
	at: Addr,
) -> (
	ok: bool,
	rows, cols: int,
) {
	files := pkg.files
	sst := pkg.sst
	xfs := pkg.xfs
	ws, wgood := xlsx_parse(files, part)
	if !wgood {
		return false, 0, 0
	}

	// --- the frozen split --------------------------------------------------
	// Only read when the import lands at A1: a pane is a property of the
	// whole sheet, and pasting somebody else's sheet into the middle of one
	// must not re-pin it.
	if at.row == 0 && at.col == 0 {
		if svs, found := x_kid(ws, 0, "sheetViews"); found {
			for sv in x_kids(ws, svs, "sheetView") {
				pane, pok := x_kid(ws, sv, "pane")
				if !pok {
					continue
				}
				if x_attr(ws, pane, "state") != "frozen" {
					continue // a split the user can drag is not a freeze
				}
				xs, _ := strconv.parse_int(x_attr(ws, pane, "xSplit"))
				ys, _ := strconv.parse_int(x_attr(ws, pane, "ySplit"))
				set_freeze(sh, ys, xs)
				break
			}
		}
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
		return false, 0, 0
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
			if !pok || r.row == NO_ROW || r.col == NO_COL {
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

	// --- merges ------------------------------------------------------------
	if mc, found := x_kid(ws, 0, "mergeCells"); found {
		for m in x_kids(ws, mc, "mergeCell") {
			if rect, good := parse_a1_range(x_attr(ws, m, "ref")); good {
				shifted := Rect_I {
					rect.r0 + at.row,
					rect.c0 + at.col,
					rect.r1 + at.row,
					rect.c1 + at.col,
				}
				add_merge(sh, shifted)
			}
		}
	}

	// --- charts ------------------------------------------------------------
	if dr, found := x_kid(ws, 0, "drawing"); found && at.row == 0 && at.col == 0 {
		rid := x_attr(ws, dr, "id")
		base := part
		dir := ""
		if i := strings.last_index_byte(base, '/'); i >= 0 {
			dir = base[:i]
			base = base[i + 1:]
		}
		rels := fmt.tprintf("%s/_rels/%s.rels", dir, base)
		if dpath, dok := xlsx_rel_target(files, rels, dir, rid); dok {
			xlsx_load_charts(sh, pkg, dpath)
		}
	}

	return true, max_r + 1, max_c + 1
}

// xlsx_load_charts reads a drawing part and the chart parts it points at.
// Only what this program can draw is kept: the kind, the title, the anchor,
// and the cell range the series read from — which is reconstructed from the
// `<c:f>` formulas rather than from the cached values, because the formulas
// are the thing that stays true when the data changes.
xlsx_load_charts :: proc(sh: ^Sheet, pkg: ^Xlsx_Pkg, drawing_part: string) {
	files := pkg.files
	dw, ok := xlsx_parse(files, drawing_part)
	if !ok {
		return
	}
	dir := ""
	base := drawing_part
	if i := strings.last_index_byte(base, '/'); i >= 0 {
		dir = base[:i]
		base = base[i + 1:]
	}
	rels := fmt.tprintf("%s/_rels/%s.rels", dir, base)

	for anchor in x_kids(dw, 0, "twoCellAnchor") {
		frame, fok := x_kid(dw, anchor, "graphicFrame")
		if !fok {
			continue
		}
		gr, gok := x_kid(dw, frame, "graphic")
		if !gok {
			continue
		}
		gd, dok := x_kid(dw, gr, "graphicData")
		if !dok {
			continue
		}
		cref, cok := x_kid(dw, gd, "chart")
		if !cok {
			continue
		}
		rid := x_attr(dw, cref, "id")
		cpath, pok := xlsx_rel_target(files, rels, dir, rid)
		if !pok {
			continue
		}
		at := Addr{}
		w, h := CHART_DEF_W, CHART_DEF_H
		if from, found := x_kid(dw, anchor, "from"); found {
			if e, f2 := x_kid(dw, from, "col"); f2 {
				at.col, _ = strconv.parse_int(x_text(dw, e))
			}
			if e, f2 := x_kid(dw, from, "row"); f2 {
				at.row, _ = strconv.parse_int(x_text(dw, e))
			}
		}
		if to, found := x_kid(dw, anchor, "to"); found {
			if e, f2 := x_kid(dw, to, "col"); f2 {
				if v, vok := strconv.parse_int(x_text(dw, e)); vok {
					w = max(v - at.col, 1)
				}
			}
			if e, f2 := x_kid(dw, to, "row"); f2 {
				if v, vok := strconv.parse_int(x_text(dw, e)); vok {
					h = max(v - at.row, 1)
				}
			}
		}
		if ch, good := xlsx_read_chart(pkg, cpath); good {
			c := ch
			c.at = at
			c.w = clamp(w, 1, 60)
			c.h = clamp(h, 1, 120)
			c.title = strings.clone(ch.title, sh.heap)
			// A chart whose data is on its own sheet records no sheet at all,
			// so that renaming the sheet cannot orphan it.
			own := strings.equal_fold(ch.sheet, sh.name)
			c.sheet = own ? "" : strings.clone(ch.sheet, sh.heap)
			append(&sh.charts, c)
		}
	}
}

// xlsx_read_chart pulls the kind, the title and the data range out of one
// chart part. The range is the union of every `<c:f>` the chart names, which
// is how a chart written by another program — where the categories and the
// values are separate references — comes back as one rectangle.
xlsx_read_chart :: proc(pkg: ^Xlsx_Pkg, part: string) -> (ch: Chart, ok: bool) {
	doc, good := xlsx_parse(pkg.files, part)
	if !good {
		return {}, false
	}
	root, rok := x_kid(doc, 0, "chart")
	if !rok {
		return {}, false
	}
	plot, pok := x_kid(doc, root, "plotArea")
	if !pok {
		return {}, false
	}
	kind := Chart_Kind.Bar
	found_kind := false
	if _, f := x_kid(doc, plot, "barChart"); f {
		kind, found_kind = .Bar, true
	} else if _, f2 := x_kid(doc, plot, "lineChart"); f2 {
		kind, found_kind = .Line, true
	} else if _, f3 := x_kid(doc, plot, "pieChart"); f3 {
		kind, found_kind = .Pie, true
	}
	if !found_kind {
		return {}, false
	}

	// Every `<c:f>` anywhere under the plot area, unioned.
	refs := make([dynamic]string, 0, 8, context.temp_allocator)
	collect_f(doc, plot, &refs)
	sheet := ""
	rect := Rect_I{}
	have := false
	for f in refs {
		sn, rc, _, good2 := parse_ref_target(f)
		if !good2 {
			continue
		}
		if sheet == "" {
			sheet = sn
		}
		if !have {
			rect, have = rc, true
		} else {
			rect.r0 = min(rect.r0, rc.r0)
			rect.c0 = min(rect.c0, rc.c0)
			rect.r1 = max(rect.r1, rc.r1)
			rect.c1 = max(rect.c1, rc.c1)
		}
	}
	if !have {
		return {}, false
	}
	title := ""
	if t, f := x_kid(doc, root, "title"); f {
		title = strings.trim_space(first_text(doc, t))
	}
	return Chart {
			kind = kind,
			title = title,
			sheet = sheet,
			rect = rect,
			w = CHART_DEF_W,
			h = CHART_DEF_H,
			labels = chart_shows_values(doc, plot),
		},
		true
}

// chart_shows_values reports whether any `<c:dLbls>` under the plot area
// turns values (or percentages, which is how a pie is usually labelled
// elsewhere) on. This program has one switch where the format has a dozen,
// so any series or chart-group label that shows a number counts; one that is
// `<c:delete val="1"/>` does not.
chart_shows_values :: proc(doc: ^xml.Document, id: xml.Element_ID) -> bool {
	if int(id) >= len(doc.elements) {
		return false
	}
	for v in doc.elements[id].value {
		kid, is_el := v.(xml.Element_ID)
		if !is_el {
			continue
		}
		if x_is(doc.elements[kid].ident, "dLbls") {
			if del, f := x_kid(doc, kid, "delete"); f && x_attr(doc, del, "val") != "0" {
				continue
			}
			for flag in ([?]string{"showVal", "showPercent"}) {
				if e, f := x_kid(doc, kid, flag); f {
					v2 := x_attr(doc, e, "val")
					if v2 == "1" || v2 == "true" || v2 == "" {
						return true
					}
				}
			}
			continue
		}
		if chart_shows_values(doc, kid) {
			return true
		}
	}
	return false
}

// collect_f walks a subtree gathering the text of every `<c:f>` element.
collect_f :: proc(doc: ^xml.Document, id: xml.Element_ID, out: ^[dynamic]string) {
	if int(id) >= len(doc.elements) {
		return
	}
	for v in doc.elements[id].value {
		kid, is_el := v.(xml.Element_ID)
		if !is_el {
			continue
		}
		if x_is(doc.elements[kid].ident, "f") {
			if t := strings.trim_space(x_text(doc, kid)); t != "" {
				append(out, t)
			}
			continue
		}
		collect_f(doc, kid, out)
	}
}

// first_text is the first non-empty run of text anywhere under an element,
// which is where a chart title's `<a:t>` ends up.
first_text :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	if int(id) >= len(doc.elements) {
		return ""
	}
	for v in doc.elements[id].value {
		switch k in v {
		case string:
			if strings.trim_space(k) != "" {
				return k
			}
		case xml.Element_ID:
			if t := first_text(doc, k); t != "" {
				return t
			}
		}
	}
	return ""
}

// xlsx_read_bytes writes the first worksheet of an .xlsx into `sh` at `at`.
// `sh` is not cleared: an import lands where the cursor is, like a paste.
xlsx_read_bytes :: proc(sh: ^Sheet, raw: []u8, at: Addr) -> (ok: bool, rows, cols: int, name: string) {
	pkg, tabs, good := xlsx_open(raw)
	if !good || len(tabs) == 0 {
		return false, 0, 0, ""
	}
	gok, r, c := xlsx_load_sheet(sh, &pkg, tabs[0].part, at)
	if !gok {
		return false, 0, 0, tabs[0].name
	}
	sh.book.graph_dirty = true
	recalc_all(sh)
	return true, r, c, tabs[0].name
}

// xlsx_read_book replaces the whole book with the workbook in `raw` — every
// sheet, under its own name, so that the cross-sheet formulas in it resolve.
// Importing one sheet at the cursor would silently turn `Sheet2!A1` into
// #REF!, which is the one thing a multi-sheet importer must not do.
xlsx_read_book :: proc(bk: ^Book, path: string) -> (ok: bool, sheets, cells: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false, 0, 0
	}
	return xlsx_read_book_bytes(bk, data)
}

xlsx_read_book_bytes :: proc(bk: ^Book, raw: []u8) -> (ok: bool, sheets, cells: int) {
	pkg, tabs, good := xlsx_open(raw)
	if !good || len(tabs) == 0 {
		return false, 0, 0
	}

	// Collapse the book to one sheet, then grow it back. The first sheet is
	// reused rather than replaced so that a caller holding `bk.sheets[0]`
	// keeps a valid pointer.
	keep := bk.sheets[0]
	for i := len(bk.sheets) - 1; i >= 1; i -= 1 {
		s := bk.sheets[i]
		ordered_remove(&bk.sheets, i)
		sheet_release(s)
		if s.allocated {
			free(s, bk.heap)
		}
	}
	sheet_clear(keep)
	book_clear_names(bk)

	// Name every sheet *before* loading any of them: a formula on sheet 1 can
	// name sheet 3, and the graph resolves names, not order.
	for tab, i in tabs {
		nm := tab.name != "" ? tab.name : fmt.tprintf("Sheet%d", i + 1)
		if i == 0 {
			if keep.name != "" {
				delete(keep.name, keep.heap)
			}
			keep.name = strings.clone(nm, keep.heap)
		} else if book_add_sheet(bk, nm) == nil {
			break
		}
	}
	for tab, i in tabs {
		if i >= len(bk.sheets) {
			break
		}
		if gok, _, _ := xlsx_load_sheet(bk.sheets[i], &pkg, tab.part, {}); gok {
			sheets += 1
		}
	}

	// --- defined names -----------------------------------------------------
	if wb, wgood := xlsx_parse(pkg.files, "xl/workbook.xml"); wgood {
		if dn, found := x_kid(wb, 0, "definedNames"); found {
			for d in x_kids(wb, dn, "definedName") {
				nm := x_attr(wb, d, "name")
				// `_xlnm.`-prefixed names are print areas and the like, not
				// anything a user typed.
				if nm == "" || strings.has_prefix(nm, "_xlnm.") {
					continue
				}
				// `localSheetId` scopes the name to one tab, by position.
				scope := ""
				if ls := x_attr(wb, d, "localSheetId"); ls != "" {
					li, lok := strconv.parse_int(ls)
					if !lok || li < 0 || li >= len(bk.sheets) {
						continue
					}
					scope = bk.sheets[li].name
				}
				if sn, rect, abs, gok := parse_ref_target(x_text(wb, d)); gok {
					book_set_name(bk, nm, sn, rect, abs, scope)
				}
			}
		}
		if bvs, found := x_kid(wb, 0, "bookViews"); found {
			for v in x_kids(wb, bvs, "workbookView") {
				if a, aok := strconv.parse_int(x_attr(wb, v, "activeTab")); aok {
					bk.active = clamp(a, 0, len(bk.sheets) - 1)
				}
			}
		}
	}

	for sh in bk.sheets {
		cells += len(sh.cells)
	}
	bk.graph_dirty = true
	book_recalc_all(bk)
	return sheets > 0, sheets, cells
}

// Shared_F is one entry of a worksheet's shared-formula table: the master's
// text and the cell it was written in.
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
