// Reading and writing documents.
//
// This file owns the three text formats; the three binary-ish ones live next
// door, because each of them is a program in its own right:
//
//   .json  the native format — a direct serialisation of the model, so a
//          document round-trips byte-for-byte through it. Written by hand so
//          the output is stable and readable; read with core:encoding/json.
//   .md    Markdown, as real interop: headings, bold, italic, underline
//          (<u>, which Markdown has no syntax for), inline code, fenced code
//          blocks, bullet and numbered lists with nesting, and quotes.
//   .html  export only, for pasting into something else.
//
//   .pdf   pdf.odin — a real PDF, with the fonts embedded and subset and the
//          text positioned from the layout, so it is searchable and
//          selectable rather than a picture of each page.
//   .docx  office.odin — WordprocessingML in a ZIP written by zip.odin, and
//          read back as well as written.
//   .odt   office.odin — OpenDocument, likewise read and written, including
//          files LibreOffice wrote rather than this app.
//   .rtf   office.odin — plain text, and the cheapest broad compatibility
//          there is.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Enum names, shared by the JSON writer and reader
// ---------------------------------------------------------------------------

kind_name :: proc(k: Para_Kind) -> string {
	switch k {
	case .Body:
		return "body"
	case .H1:
		return "h1"
	case .H2:
		return "h2"
	case .H3:
		return "h3"
	case .Quote:
		return "quote"
	case .Code:
		return "code"
	case .Table:
		return "table"
	case .Image:
		return "image"
	}
	return "body"
}

kind_from_name :: proc(s: string) -> Para_Kind {
	switch s {
	case "h1":
		return .H1
	case "h2":
		return .H2
	case "h3":
		return .H3
	case "quote":
		return .Quote
	case "code":
		return .Code
	case "table":
		return .Table
	case "image":
		return .Image
	}
	return .Body
}

align_name :: proc(a: Align) -> string {
	switch a {
	case .Left:
		return "left"
	case .Center:
		return "center"
	case .Right:
		return "right"
	case .Justify:
		return "justify"
	}
	return "left"
}

align_from_name :: proc(s: string) -> Align {
	switch s {
	case "center":
		return .Center
	case "right":
		return .Right
	case "justify":
		return .Justify
	}
	return .Left
}

list_name :: proc(l: List_Kind) -> string {
	switch l {
	case .None:
		return "none"
	case .Bullet:
		return "bullet"
	case .Numbered:
		return "number"
	}
	return "none"
}

list_from_name :: proc(s: string) -> List_Kind {
	switch s {
	case "bullet":
		return .Bullet
	case "number":
		return .Numbered
	}
	return .None
}

// ---------------------------------------------------------------------------
// The native format
// ---------------------------------------------------------------------------

json_escape :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// json_write_runs is the run array a paragraph or a cell paragraph writes.
@(private = "file")
json_write_runs :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	for &r, ri in pa.runs {
		if ri > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "{\"t\": ")
		json_escape(b, string(r.text[:]))
		cs := r.style
		if cs.bold {strings.write_string(b, ", \"b\": true")}
		if cs.italic {strings.write_string(b, ", \"i\": true")}
		if cs.underline {strings.write_string(b, ", \"u\": true")}
		if cs.mono {strings.write_string(b, ", \"m\": true")}
		if cs.size != 0 {fmt.sbprintf(b, ", \"size\": %.1f", cs.size)}
		if cs.color != 0 {fmt.sbprintf(b, ", \"color\": \"#%06x\"", cs.color & 0xffffff)}
		strings.write_string(b, "}")
	}
}

// json_write_para writes one paragraph inside a cell. Cell paragraphs carry
// only the properties a cell can use — kind, alignment, list and depth — which
// keeps a grid of plain text to one short line per cell.
@(private = "file")
json_write_para :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	strings.write_string(b, "{")
	fmt.sbprintf(b, "\"kind\": \"%s\"", kind_name(pa.kind))
	if pa.align != .Left {
		fmt.sbprintf(b, ", \"align\": \"%s\"", align_name(pa.align))
	}
	if pa.list != .None {
		fmt.sbprintf(b, ", \"list\": \"%s\"", list_name(pa.list))
	}
	if pa.depth != 0 {
		fmt.sbprintf(b, ", \"depth\": %d", pa.depth)
	}
	// A picture in a cell writes its bytes here, exactly as one in the body
	// does: the JSON is the format that must lose nothing.
	if pa.kind == .Image && pa.img != nil {
		json_write_image(b, pa.img)
	}
	strings.write_string(b, ", \"runs\": [")
	json_write_runs(b, pa)
	strings.write_string(b, "]}")
}

@(private = "file")
json_write_table :: proc(b: ^strings.Builder, t: ^Table) {
	strings.write_string(b, ", \"table\": {")
	fmt.sbprintf(b, "\"header\": %s, \"borders\": %s", t.header ? "true" : "false", t.borders ? "true" : "false")
	strings.write_string(b, ", \"widths\": [")
	for c in 0 ..< table_cols(t) {
		if c > 0 {
			strings.write_string(b, ", ")
		}
		fmt.sbprintf(b, "%.1f", table_width(t, c))
	}
	strings.write_string(b, "], \"rows\": [")
	for &row, ri in t.rows {
		if ri > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "[")
		for &cl, ci in row.cells {
			if ci > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, "[")
			for &cp, pi in cl.paras {
				if pi > 0 {
					strings.write_string(b, ", ")
				}
				json_write_para(b, &cp)
			}
			strings.write_string(b, "]")
		}
		strings.write_string(b, "]")
	}
	strings.write_string(b, "]")
	// Merged cells ride beside the grid rather than inside it: `rows` stays a
	// plain grid of cells (a covered cell is written as its one empty
	// paragraph), so a reader that predates merging still reads every word,
	// and `merges` lists each anchor with its extent.
	if table_has_merges(t) {
		strings.write_string(b, ", \"merges\": [")
		first := true
		for &row, ri in t.rows {
			for &cl, ci in row.cells {
				if !cell_is_merged(&cl) {
					continue
				}
				if !first {
					strings.write_string(b, ", ")
				}
				first = false
				fmt.sbprintf(b, "{{\"row\": %d, \"col\": %d, \"rows\": %d, \"cols\": %d}}", ri, ci, cell_rspan(&cl), cell_cspan(&cl))
			}
		}
		strings.write_string(b, "]")
	}
	strings.write_string(b, "}")
}

// json_write_image carries the original file bytes base64'd. A path alone
// would make the native format depend on a file that may not be on the next
// machine, which is the one thing the native format must not do.
@(private = "file")
json_write_image :: proc(b: ^strings.Builder, im: ^Doc_Image) {
	strings.write_string(b, ", \"image\": {")
	fmt.sbprintf(b, "\"w\": %d, \"h\": %d, \"scale\": %.4f", im.w, im.h, im.scale)
	strings.write_string(b, ", \"path\": ")
	json_escape(b, im.path)
	strings.write_string(b, ", \"alt\": ")
	json_escape(b, im.alt)
	if len(im.bytes) > 0 {
		enc, err := base64.encode(im.bytes, base64.ENC_TABLE, context.temp_allocator)
		if err == nil {
			strings.write_string(b, ", \"data\": \"")
			strings.write_string(b, enc)
			strings.write_string(b, "\"")
		}
	}
	strings.write_string(b, "}")
}

doc_to_json :: proc(d: ^Doc, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(&b, "{\n  \"format\": \"palmy-docs\",\n  \"version\": 1,\n  \"page\": \"a4\",\n  \"paragraphs\": [\n")
	for &pa, pi in d.paras {
		strings.write_string(&b, "    {")
		fmt.sbprintf(&b, "\"kind\": \"%s\"", kind_name(pa.kind))
		if pa.align != .Left {
			fmt.sbprintf(&b, ", \"align\": \"%s\"", align_name(pa.align))
		}
		if pa.list != .None {
			fmt.sbprintf(&b, ", \"list\": \"%s\"", list_name(pa.list))
		}
		if pa.depth != 0 {
			fmt.sbprintf(&b, ", \"depth\": %d", pa.depth)
		}
		if pa.before != 0 {
			fmt.sbprintf(&b, ", \"before\": %.1f", pa.before)
		}
		if pa.after != 0 {
			fmt.sbprintf(&b, ", \"after\": %.1f", pa.after)
		}
		if pa.break_before {
			strings.write_string(&b, ", \"break\": true")
		}
		// A table writes its grid; an image writes its bytes. Both go in before
		// the runs, which for these two kinds are empty.
		if pa.kind == .Table && pa.table != nil {
			json_write_table(&b, pa.table)
		}
		if pa.kind == .Image && pa.img != nil {
			json_write_image(&b, pa.img)
		}
		strings.write_string(&b, ", \"runs\": [")
		json_write_runs(&b, &pa)
		strings.write_string(&b, "]}")
		if pi + 1 < len(d.paras) {
			strings.write_string(&b, ",")
		}
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "  ]\n}\n")
	return strings.to_string(b)
}

@(private = "file")
jget :: proc(o: json.Object, key: string) -> (json.Value, bool) {
	v, ok := o[key]
	return v, ok
}

@(private = "file")
jstr :: proc(o: json.Object, key: string, def := "") -> string {
	if v, ok := jget(o, key); ok {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return def
}

@(private = "file")
jnum :: proc(o: json.Object, key: string, def: f64 = 0) -> f64 {
	if v, ok := jget(o, key); ok {
		#partial switch n in v {
		case json.Float:
			return f64(n)
		case json.Integer:
			return f64(n)
		}
	}
	return def
}

@(private = "file")
jbool :: proc(o: json.Object, key: string) -> bool {
	if v, ok := jget(o, key); ok {
		if bb, is := v.(json.Boolean); is {
			return bool(bb)
		}
	}
	return false
}

@(private = "file")
json_read_runs :: proc(pa: ^Paragraph, po: json.Object) {
	rv, hr := jget(po, "runs")
	if !hr {
		return
	}
	ra, ria := rv.(json.Array)
	if !ria {
		return
	}
	for rvv in ra {
		ro, rois := rvv.(json.Object)
		if !rois {
			continue
		}
		cs := Char_Style {
			bold      = jbool(ro, "b"),
			italic    = jbool(ro, "i"),
			underline = jbool(ro, "u"),
			mono      = jbool(ro, "m"),
			size      = f32(jnum(ro, "size", 0)),
		}
		if c := jstr(ro, "color"); len(c) == 7 && c[0] == '#' {
			if v, pok := strconv.parse_u64_of_base(c[1:], 16); pok {
				cs.color = 0xff000000 | u32(v & 0xffffff)
			}
		}
		append(&pa.runs, run_make(cs, jstr(ro, "t")))
	}
}

@(private = "file")
json_read_cell_para :: proc(po: json.Object) -> Paragraph {
	pa := Paragraph {
		kind  = kind_from_name(jstr(po, "kind", "body")),
		align = align_from_name(jstr(po, "align", "left")),
		list  = list_from_name(jstr(po, "list", "none")),
		depth = int(jnum(po, "depth", 0)),
		runs  = make([dynamic]Run, 0, 2),
	}
	// A picture in a cell is representable; a table inside one is not, and a
	// hand-edited file that asks for a nested table gets a body paragraph.
	if pa.kind == .Image {
		if iv, hi := jget(po, "image"); hi {
			if io_, iis := iv.(json.Object); iis {
				if im, got := json_read_image(io_); got {
					pa.img = new(Doc_Image)
					pa.img^ = im
				}
			}
		}
	} else if !text_kind(pa.kind) {
		pa.kind = .Body
	}
	json_read_runs(&pa, po)
	if len(pa.runs) == 0 {
		append(&pa.runs, run_make({}))
	}
	normalise(&pa)
	return pa
}

@(private = "file")
json_read_table :: proc(to: json.Object) -> Table {
	t := Table {
		rows    = make([dynamic]Row, 0, 4),
		widths  = make([dynamic]f32, 0, 4),
		header  = jbool(to, "header"),
		borders = true,
	}
	if bv, hb := jget(to, "borders"); hb {
		if bb, is := bv.(json.Boolean); is {
			t.borders = bool(bb)
		}
	}
	if rv, hr := jget(to, "rows"); hr {
		if ra, is := rv.(json.Array); is {
			for row_v in ra {
				row_a, ria := row_v.(json.Array)
				if !ria {
					continue
				}
				row := Row {
					cells = make([dynamic]Cell, 0, max(1, len(row_a))),
				}
				for cell_v in row_a {
					cl := Cell {
						paras = make([dynamic]Paragraph, 0, 1),
					}
					if cell_a, cis := cell_v.(json.Array); cis {
						for pv in cell_a {
							if po, pis := pv.(json.Object); pis {
								append(&cl.paras, json_read_cell_para(po))
							}
						}
					}
					if len(cl.paras) == 0 {
						append(&cl.paras, para_make())
					}
					append(&row.cells, cl)
				}
				if len(row.cells) == 0 {
					append(&row.cells, cell_make())
				}
				append(&t.rows, row)
			}
		}
	}
	if len(t.rows) == 0 {
		append(&t.rows, Row{cells = make([dynamic]Cell, 0, 1)})
		append(&t.rows[0].cells, cell_make())
	}
	if wv, hw := jget(to, "widths"); hw {
		if wa, is := wv.(json.Array); is {
			for w in wa {
				#partial switch n in w {
				case json.Float:
					append(&t.widths, f32(n))
				case json.Integer:
					append(&t.widths, f32(n))
				}
			}
		}
	}
	if mv, hm := jget(to, "merges"); hm {
		if ma, is := mv.(json.Array); is {
			for m in ma {
				mo, mis := m.(json.Object)
				if !mis {
					continue
				}
				if cl := table_cell(&t, int(jnum(mo, "row", -1)), int(jnum(mo, "col", -1))); cl != nil {
					cl.rspan = int(jnum(mo, "rows", 1))
					cl.cspan = int(jnum(mo, "cols", 1))
				}
			}
		}
	}
	table_fit_widths(&t)
	table_normalise(&t)
	return t
}

@(private = "file")
json_read_image :: proc(io_: json.Object) -> (Doc_Image, bool) {
	data := jstr(io_, "data")
	scale := f32(jnum(io_, "scale", 1))
	if len(data) > 0 {
		if raw, err := base64.decode(data, base64.DEC_TABLE, nil, context.temp_allocator); err == nil {
			if im, got := image_from_bytes(raw, jstr(io_, "path"), jstr(io_, "alt"), scale); got {
				return im, true
			}
		}
	}
	// No bytes in the file: fall back to the path it came from, so a document
	// written by hand can name a picture rather than inline it.
	if path := jstr(io_, "path"); path != "" {
		if im, got := image_load(path, scale); got {
			return im, true
		}
	}
	return {}, false
}

// doc_from_json parses the native format. Anything missing falls back to the
// model's own default, so a hand-edited file with half the fields still loads.
doc_from_json :: proc(src: string) -> (d: Doc, ok: bool) {
	root, err := json.parse(src, .JSON, false, context.temp_allocator)
	if err != .None {
		return {}, false
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		return {}, false
	}
	paras_v, has := jget(obj, "paragraphs")
	if !has {
		return {}, false
	}
	arr, is_arr := paras_v.(json.Array)
	if !is_arr {
		return {}, false
	}

	out := Doc {
		paras = make([dynamic]Paragraph, 0, max(1, len(arr))),
	}
	for pv in arr {
		po, pis := pv.(json.Object)
		if !pis {
			continue
		}
		pa := Paragraph {
			kind   = kind_from_name(jstr(po, "kind", "body")),
			align  = align_from_name(jstr(po, "align", "left")),
			list   = list_from_name(jstr(po, "list", "none")),
			depth  = int(jnum(po, "depth", 0)),
			before = f32(jnum(po, "before", 0)),
			after  = f32(jnum(po, "after", 0)),
			break_before = jbool(po, "break"),
			runs   = make([dynamic]Run, 0, 2),
		}
		json_read_runs(&pa, po)
		if tv, ht := jget(po, "table"); ht {
			if to, tis := tv.(json.Object); tis {
				pa.kind = .Table
				pa.table = new(Table)
				pa.table^ = json_read_table(to)
			}
		}
		if iv, hi := jget(po, "image"); hi {
			if io_, iis := iv.(json.Object); iis {
				if im, got := json_read_image(io_); got {
					pa.kind = .Image
					pa.img = new(Doc_Image)
					pa.img^ = im
				} else {
					// The bytes would not decode: keep the paragraph as a
					// placeholder rather than dropping the picture silently.
					pa.kind = .Image
				}
			}
		}
		if pa.kind == .Table && pa.table == nil {
			pa.kind = .Body
		}
		if len(pa.runs) == 0 {
			append(&pa.runs, run_make({}))
		}
		normalise(&pa)
		append(&out.paras, pa)
	}
	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out, true
}

save_doc :: proc(d: ^Doc, path: string) -> bool {
	text := doc_to_json(d, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

load_doc :: proc(path: string) -> (d: Doc, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, false
	}
	return doc_from_json(string(data))
}

// ---------------------------------------------------------------------------
// Markdown export
// ---------------------------------------------------------------------------

@(private = "file")
md_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\', '*', '`', '<', '[', ']':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
		case:
			strings.write_byte(b, c)
		}
	}
}

// md_marks returns the opening and closing delimiters for a character style.
// Whitespace at the edges of a run is moved outside them, because `**bold **`
// is not emphasis in any Markdown dialect.
@(private = "file")
md_write_run :: proc(b: ^strings.Builder, text: string, cs: Char_Style) {
	if len(text) == 0 {
		return
	}
	lead := 0
	for lead < len(text) && text[lead] == ' ' {
		lead += 1
	}
	tail := len(text)
	for tail > lead && text[tail - 1] == ' ' {
		tail -= 1
	}
	strings.write_string(b, text[:lead])
	core := text[lead:tail]

	if len(core) > 0 {
		if cs.underline {strings.write_string(b, "<u>")}
		if cs.bold {strings.write_string(b, "**")}
		if cs.italic {strings.write_string(b, "*")}
		if cs.mono {
			strings.write_byte(b, '`')
			strings.write_string(b, core)
			strings.write_byte(b, '`')
		} else {
			md_escape(b, core)
		}
		if cs.italic {strings.write_string(b, "*")}
		if cs.bold {strings.write_string(b, "**")}
		if cs.underline {strings.write_string(b, "</u>")}
	}
	strings.write_string(b, text[tail:])
}

@(private = "file")
md_write_inline :: proc(b: ^strings.Builder, pa: ^Paragraph) {
	for &r in pa.runs {
		md_write_run(b, string(r.text[:]), r.style)
	}
}

// md_write_table writes a GitHub pipe table. Every cell is one line — the
// syntax has no way to say otherwise — so a cell with several paragraphs is
// joined with spaces, and a pipe inside a cell is escaped.
//
// Pipe tables cannot merge cells either, so a merged table is **flattened**:
// the merged cell's text is written once, in its top-left cell, and the cells
// it covered are written empty. The grid keeps its shape, every column still
// lines up, and no text is duplicated — which is also what pandoc does. The
// merge itself is lost; reading the file back gives the unmerged grid.
@(private = "file")
md_write_table :: proc(b: ^strings.Builder, t: ^Table) {
	ncols := table_cols(t)
	cell_line :: proc(b: ^strings.Builder, cl: ^Cell) {
		if cl == nil {
			return
		}
		for &cp, i in cl.paras {
			if i > 0 {
				strings.write_byte(b, ' ')
			}
			// A picture in a cell: Markdown has an inline image syntax, so
			// this one needs no special case beyond writing it.
			if cp.kind == .Image && cp.img != nil {
				strings.write_string(b, "![")
				md_escape(b, cp.img.alt)
				fmt.sbprintf(b, "](%s)", cp.img.path)
				continue
			}
			for &r in cp.runs {
				text := string(r.text[:])
				for k in 0 ..< len(text) {
					if text[k] == '|' {
						strings.write_string(b, "\\|")
					} else if text[k] == '\n' {
						strings.write_byte(b, ' ')
					} else {
						strings.write_byte(b, text[k])
					}
				}
			}
		}
	}
	for r in 0 ..< len(t.rows) {
		strings.write_string(b, "|")
		for c in 0 ..< ncols {
			strings.write_byte(b, ' ')
			cell_line(b, table_cell(t, r, c))
			strings.write_string(b, " |")
		}
		strings.write_byte(b, '\n')
		// The delimiter row goes after the first row, always: a pipe table
		// without one is not a table to any reader, header or no header.
		if r == 0 {
			strings.write_string(b, "|")
			for _ in 0 ..< ncols {
				strings.write_string(b, " --- |")
			}
			strings.write_byte(b, '\n')
		}
	}
}

doc_to_markdown :: proc(d: ^Doc, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	in_code := false
	prev_block := false // a block that needs a blank line after it was written
	prev_list := false

	for &pa in d.paras {
		is_list := pa.list != .None

		// A table becomes a GitHub pipe table, and a picture becomes
		// `![alt](path)`. Both need a blank line either side or the next
		// reader folds them into the paragraph above.
		if pa.kind == .Table || pa.kind == .Image {
			if in_code {
				strings.write_string(&b, "```\n")
				in_code = false
			}
			if prev_block {
				strings.write_string(&b, "\n")
			}
			if pa.kind == .Table && pa.table != nil {
				md_write_table(&b, pa.table)
			} else if pa.img != nil {
				strings.write_string(&b, "![")
				md_escape(&b, pa.img.alt)
				fmt.sbprintf(&b, "](%s)\n", pa.img.path)
			}
			prev_block = true
			prev_list = false
			continue
		}

		if pa.kind == .Code {
			if !in_code {
				if prev_block {
					strings.write_string(&b, "\n")
				}
				strings.write_string(&b, "```\n")
				in_code = true
			}
			// Inside a fence everything is literal.
			for &r in pa.runs {
				strings.write_bytes(&b, r.text[:])
			}
			strings.write_string(&b, "\n")
			prev_block = true
			prev_list = false
			continue
		}
		if in_code {
			strings.write_string(&b, "```\n")
			in_code = false
		}

		// Blank line between blocks; consecutive list items stay packed.
		if prev_block && !(is_list && prev_list) {
			strings.write_string(&b, "\n")
		}

		switch pa.kind {
		case .H1:
			strings.write_string(&b, "# ")
		case .H2:
			strings.write_string(&b, "## ")
		case .H3:
			strings.write_string(&b, "### ")
		case .Quote:
			strings.write_string(&b, "> ")
		case .Body, .Code, .Table, .Image:
		}
		if is_list {
			for _ in 0 ..< pa.depth {
				strings.write_string(&b, "  ")
			}
			if pa.list == .Bullet {
				strings.write_string(&b, "- ")
			} else {
				strings.write_string(&b, "1. ")
			}
		}
		md_write_inline(&b, &pa)
		strings.write_string(&b, "\n")
		prev_block = true
		prev_list = is_list
	}
	if in_code {
		strings.write_string(&b, "```\n")
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Markdown import
// ---------------------------------------------------------------------------

// md_parse_inline turns one line of Markdown into styled runs appended to
// `pa`. Emphasis is handled as a toggle rather than a tree, which is what the
// model can represent — nesting is expressed by the style flags, not by depth.
md_parse_inline :: proc(pa: ^Paragraph, s: string, base: Char_Style) {
	cs := base
	buf := strings.builder_make(context.temp_allocator)

	flush :: proc(pa: ^Paragraph, buf: ^strings.Builder, cs: Char_Style) {
		t := strings.to_string(buf^)
		if len(t) > 0 {
			append(&pa.runs, run_make(cs, t))
			strings.builder_reset(buf)
		}
	}

	i := 0
	for i < len(s) {
		c := s[i]

		// An escape is always one literal character.
		if c == '\\' && i + 1 < len(s) {
			strings.write_byte(&buf, s[i + 1])
			i += 2
			continue
		}

		if c == '`' {
			// Inline code runs to the next backtick, verbatim.
			j := i + 1
			for j < len(s) && s[j] != '`' {
				j += 1
			}
			if j < len(s) {
				flush(pa, &buf, cs)
				code := cs
				code.mono = true
				append(&pa.runs, run_make(code, s[i + 1:j]))
				i = j + 1
				continue
			}
		}

		if strings.has_prefix(s[i:], "<u>") {
			flush(pa, &buf, cs)
			cs.underline = true
			i += 3
			continue
		}
		if strings.has_prefix(s[i:], "</u>") {
			flush(pa, &buf, cs)
			cs.underline = false
			i += 4
			continue
		}
		if strings.has_prefix(s[i:], "<em>") {
			flush(pa, &buf, cs)
			cs.italic = true
			i += 4
			continue
		}
		if strings.has_prefix(s[i:], "</em>") {
			flush(pa, &buf, cs)
			cs.italic = false
			i += 5
			continue
		}
		if strings.has_prefix(s[i:], "<strong>") {
			flush(pa, &buf, cs)
			cs.bold = true
			i += 8
			continue
		}
		if strings.has_prefix(s[i:], "</strong>") {
			flush(pa, &buf, cs)
			cs.bold = false
			i += 9
			continue
		}

		if c == '*' || c == '_' {
			n := 0
			for i + n < len(s) && s[i + n] == c {
				n += 1
			}
			// An opening delimiter must be followed by text, a closing one
			// preceded by it. `_` additionally has to start at a word
			// boundary, so snake_case identifiers survive.
			after := i + n < len(s) ? s[i + n] : ' '
			before := i > 0 ? s[i - 1] : ' '
			opening := after != ' ' && after != 0
			closing := before != ' '
			if c == '_' && opening && !(i == 0 || before == ' ') {
				opening = false
			}
			want_bold := n >= 2
			want_ital := n == 1 || n >= 3
			is_open := want_bold ? !cs.bold : !cs.italic
			if (is_open && opening) || (!is_open && closing) {
				flush(pa, &buf, cs)
				if want_bold {cs.bold = !cs.bold}
				if want_ital {cs.italic = !cs.italic}
				i += min(n, 3)
				continue
			}
		}

		// `[label](url)` keeps the label; the model has no link attribute.
		if c == '[' {
			close := strings.index_byte(s[i:], ']')
			if close > 0 && i + close + 1 < len(s) && s[i + close + 1] == '(' {
				paren := strings.index_byte(s[i + close + 1:], ')')
				if paren > 0 {
					strings.write_string(&buf, s[i + 1:i + close])
					i += close + 1 + paren + 1
					continue
				}
			}
		}

		strings.write_byte(&buf, c)
		i += 1
	}
	flush(pa, &buf, cs)
	if len(pa.runs) == 0 {
		append(&pa.runs, run_make(base))
	}
	normalise(pa)
}

// detab turns tabs into four spaces. The model has no tab stops, and palmy
// draws U+0009 as a missing glyph, so a tab that reaches a run shows up as a
// box in the middle of a code block.
detab :: proc(s: string, alloc := context.temp_allocator) -> string {
	if strings.index_byte(s, '\t') < 0 {
		return s
	}
	b := strings.builder_make(alloc)
	for i in 0 ..< len(s) {
		if s[i] == '\t' {
			strings.write_string(&b, "    ")
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// Block is the paragraph currently being accumulated. Markdown's "lazy
// continuation" means a line that is not itself a block marker belongs to
// whatever block is open — so a bullet wrapped over three source lines is one
// list item, not an item followed by two paragraphs.
@(private = "file")
Block :: struct {
	kind:  Para_Kind,
	list:  List_Kind,
	depth: int,
	open:  bool,
}

doc_from_markdown :: proc(src: string) -> Doc {
	out := Doc {
		paras = make([dynamic]Paragraph, 0, 32),
	}
	lines := strings.split_lines(detab(src), context.temp_allocator)

	pending := strings.builder_make(context.temp_allocator)
	blk := Block{}

	flush :: proc(out: ^Doc, pending: ^strings.Builder, blk: ^Block) {
		if !blk.open {
			return
		}
		pa := Paragraph {
			kind  = blk.kind,
			list  = blk.list,
			depth = blk.depth,
			runs  = make([dynamic]Run, 0, 2),
		}
		md_parse_inline(&pa, strings.to_string(pending^), {})
		append(&out.paras, pa)
		strings.builder_reset(pending)
		blk^ = {}
	}

	// cont appends a continuation line to the open block, with the single
	// space Markdown's soft wrap collapses to.
	cont :: proc(pending: ^strings.Builder, blk: ^Block, text: string) {
		if blk.open && strings.builder_len(pending^) > 0 {
			strings.write_byte(pending, ' ')
		}
		strings.write_string(pending, text)
		blk.open = true
	}

	in_code := false
	md_in_table := false
	md_table_pending: [dynamic]string
	for raw, raw_i in lines {
		line := raw

		if strings.has_prefix(strings.trim_left_space(line), "```") ||
		   strings.has_prefix(strings.trim_left_space(line), "~~~") {
			flush(&out, &pending, &blk)
			in_code = !in_code
			continue
		}
		if in_code {
			pa := Paragraph {
				kind = .Code,
				runs = make([dynamic]Run, 0, 1),
			}
			append(&pa.runs, run_make({}, line))
			append(&out.paras, pa)
			continue
		}

		trimmed := strings.trim_right(line, " \t")
		if len(strings.trim_space(trimmed)) == 0 {
			flush(&out, &pending, &blk)
			continue
		}

		// Leading spaces give a list its nesting depth: two per level.
		indent := 0
		for indent < len(trimmed) && trimmed[indent] == ' ' {
			indent += 1
		}
		body := trimmed[indent:]
		depth := indent / 2

		// A pipe table: a row of `|`-separated cells, and the row after it
		// made only of dashes and colons. Both have to be present — a line
		// with a pipe in it is not a table.
		if md_is_table_row(body) && md_is_delim_row(raw_i + 1 < len(lines) ? lines[raw_i + 1] : "") {
			flush(&out, &pending, &blk)
			rows := make([dynamic]string, 0, 8, context.temp_allocator)
			append(&rows, body)
			md_table_pending = rows
			md_in_table = true
			continue
		}
		if md_in_table {
			if md_is_delim_row(body) {
				continue
			}
			if md_is_table_row(body) {
				append(&md_table_pending, body)
				continue
			}
			md_flush_table(&out, &md_table_pending)
			md_in_table = false
			// fall through: this line is ordinary content
		}

		// A picture on a line of its own: `![alt](path)`.
		if strings.has_prefix(body, "![") {
			if im_pa, got := md_parse_image(body); got {
				flush(&out, &pending, &blk)
				append(&out.paras, im_pa)
				continue
			}
		}

		// Headings are always one line of their own.
		hashes := 0
		for hashes < len(body) && body[hashes] == '#' {
			hashes += 1
		}
		if hashes >= 1 && hashes <= 3 && hashes < len(body) && body[hashes] == ' ' {
			flush(&out, &pending, &blk)
			pa := Paragraph {
				kind = hashes == 1 ? .H1 : (hashes == 2 ? .H2 : .H3),
				runs = make([dynamic]Run, 0, 2),
			}
			md_parse_inline(&pa, body[hashes + 1:], {})
			append(&out.paras, pa)
			continue
		}

		// Bullets.
		if len(body) >= 2 && (body[0] == '-' || body[0] == '*' || body[0] == '+') && body[1] == ' ' {
			flush(&out, &pending, &blk)
			blk = {list = .Bullet, depth = depth}
			cont(&pending, &blk, body[2:])
			continue
		}

		// Numbered items: digits, then `.` or `)`, then a space.
		{
			k := 0
			for k < len(body) && body[k] >= '0' && body[k] <= '9' {
				k += 1
			}
			if k > 0 && k + 1 < len(body) && (body[k] == '.' || body[k] == ')') && body[k + 1] == ' ' {
				flush(&out, &pending, &blk)
				blk = {list = .Numbered, depth = depth}
				cont(&pending, &blk, body[k + 2:])
				continue
			}
		}

		// Quotes.
		if strings.has_prefix(body, ">") {
			rest := strings.trim_prefix(body, ">")
			rest = strings.trim_prefix(rest, " ")
			if blk.open && blk.kind != .Quote {
				flush(&out, &pending, &blk)
			}
			blk.kind = .Quote
			cont(&pending, &blk, rest)
			continue
		}

		// Horizontal rules are not in the model; skip them.
		if body == "---" || body == "***" || body == "___" {
			flush(&out, &pending, &blk)
			continue
		}

		// Anything else continues whatever block is open, or starts a body
		// paragraph if none is.
		cont(&pending, &blk, body)
	}
	flush(&out, &pending, &blk)
	if md_in_table {
		md_flush_table(&out, &md_table_pending)
	}

	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

// ---------------------------------------------------------------------------
// Markdown tables and pictures
// ---------------------------------------------------------------------------

// md_is_table_row is a line that starts and ends with a pipe, which is the
// form every writer emits and the only one worth accepting — a bare
// `a | b` line is far more often prose than a table.
@(private = "file")
md_is_table_row :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	return len(t) >= 2 && t[0] == '|' && t[len(t) - 1] == '|'
}

// md_is_delim_row is the `| --- | --- |` line under a header.
@(private = "file")
md_is_delim_row :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if !md_is_table_row(t) {
		return false
	}
	dashes := 0
	for i in 1 ..< len(t) - 1 {
		switch t[i] {
		case '-':
			dashes += 1
		case ':', ' ', '|', '\t':
		case:
			return false
		}
	}
	return dashes > 0
}

// md_split_row cuts a pipe row into cells, honouring `\|`.
@(private = "file")
md_split_row :: proc(s: string, alloc := context.temp_allocator) -> []string {
	t := strings.trim_space(s)
	if len(t) >= 2 && t[0] == '|' {
		t = t[1:]
	}
	if len(t) >= 1 && t[len(t) - 1] == '|' {
		t = t[:len(t) - 1]
	}
	out := make([dynamic]string, 0, 4, alloc)
	cur := strings.builder_make(alloc)
	i := 0
	for i < len(t) {
		if t[i] == '\\' && i + 1 < len(t) && t[i + 1] == '|' {
			strings.write_byte(&cur, '|')
			i += 2
			continue
		}
		if t[i] == '|' {
			append(&out, strings.clone(strings.trim_space(strings.to_string(cur)), alloc))
			strings.builder_reset(&cur)
			i += 1
			continue
		}
		strings.write_byte(&cur, t[i])
		i += 1
	}
	append(&out, strings.clone(strings.trim_space(strings.to_string(cur)), alloc))
	return out[:]
}

// md_flush_table turns the collected pipe rows into a table paragraph. The
// first row is the header, because a pipe table always has one.
@(private = "file")
md_flush_table :: proc(out: ^Doc, rows: ^[dynamic]string) {
	if len(rows^) == 0 {
		return
	}
	cols := 1
	for r in rows^ {
		cols = max(cols, len(md_split_row(r)))
	}
	pa := table_para_make(len(rows^), min(cols, TABLE_MAX_COLS), true)
	for r, ri in rows^ {
		cells := md_split_row(r)
		for ci in 0 ..< min(len(cells), table_cols(pa.table)) {
			cl := table_cell(pa.table, ri, ci)
			if cl == nil {
				continue
			}
			cp := &cl.paras[0]
			clear(&cp.runs)
			md_parse_inline(cp, cells[ci], {})
		}
	}
	append(&out.paras, pa)
	clear(rows)
}

// md_parse_image reads `![alt](path)`. The picture is loaded from disk if it
// is there; if it is not, the paragraph is still created so the document keeps
// its shape and the window shows a placeholder saying what is missing.
@(private = "file")
md_parse_image :: proc(s: string) -> (Paragraph, bool) {
	t := strings.trim_space(s)
	if !strings.has_prefix(t, "![") {
		return {}, false
	}
	close := strings.index(t, "](")
	if close < 0 || !strings.has_suffix(t, ")") {
		return {}, false
	}
	alt := t[2:close]
	path := t[close + 2:len(t) - 1]
	// A relative path is relative to the Markdown file, not to wherever the
	// program was started: README.md's docs/components.png opened from
	// another directory must still find the picture.
	if md_base_dir != "" && !strings.has_prefix(path, "/") && !strings.has_prefix(path, "~/") {
		path = strings.concatenate({md_base_dir, "/", path}, context.temp_allocator)
	}
	if im, got := image_load(expand_home(path, context.temp_allocator)); got {
		im2 := im
		im2.alt = strings.clone(alt == "" ? base_name(path) : alt)
		delete(im.alt)
		return image_para_make(im2), true
	}
	pa := para_make(.Image)
	pa.align = .Center
	pa.img = new(Doc_Image)
	pa.img^ = Doc_Image {
		path  = strings.clone(path),
		alt   = strings.clone(alt),
		scale = 1,
	}
	return pa, true
}

export_markdown :: proc(d: ^Doc, path: string) -> bool {
	text := doc_to_markdown(d, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// md_base_dir is the directory of the Markdown file being imported, for
// md_parse_image; empty when parsing text that came from no file.
@(private = "file")
md_base_dir: string

import_markdown :: proc(path: string) -> (d: Doc, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, false
	}
	slash := strings.last_index_byte(path, '/')
	md_base_dir = slash > 0 ? path[:slash] : (slash == 0 ? "/" : "")
	defer md_base_dir = ""
	return doc_from_markdown(string(data)), true
}

// ---------------------------------------------------------------------------
// HTML export
// ---------------------------------------------------------------------------

@(private = "file")
html_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

doc_to_html :: proc(d: ^Doc, title: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(&b, "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<title>")
	html_escape(&b, title)
	strings.write_string(
		&b,
		"</title>\n<style>\nbody{margin:0;background:#d4d4d4;font-family:Geist,Inter,system-ui,sans-serif;color:#0a0a0a}\n" +
		".page{width:602px;min-height:931px;margin:32px auto;padding:96px;background:#fff;box-shadow:0 10px 30px rgba(0,0,0,.25)}\n" +
		"h1{font-size:30px;margin:24px 0 10px}h2{font-size:23px;margin:20px 0 8px}h3{font-size:18px;margin:16px 0 6px}\n" +
		"p{font-size:15px;line-height:1.56;margin:0 0 11px}\n" +
		"blockquote{margin:12px 0;padding-left:24px;border-left:3px solid #d4d4d4;font-style:italic}\n" +
		"pre{margin:12px 0;padding:10px 14px;background:#f5f5f5;border-radius:6px;font-size:13px;overflow-x:auto}\n" +
		"ul,ol{font-size:15px;line-height:1.56;padding-left:28px;margin:0 0 11px}\n" +
		"table{border-collapse:collapse;width:100%;margin:14px 0;font-size:15px;line-height:1.45}\n" +
		"th,td{border:1px solid #a8a8aa;padding:7px;vertical-align:top;text-align:left}\n" +
		"th{background:#f1f1f2;font-weight:600}\n" +
		"figure{margin:12px 0;text-align:center}figure img{max-width:100%;height:auto}\n</style></head>\n<body><div class=\"page\">\n",
	)

	emit_runs :: proc(b: ^strings.Builder, pa: ^Paragraph) {
		for &r in pa.runs {
			cs := r.style
			if cs.color != 0 || cs.size != 0 {
				strings.write_string(b, "<span style=\"")
				if cs.color != 0 {
					fmt.sbprintf(b, "color:#%06x;", cs.color & 0xffffff)
				}
				if cs.size != 0 {
					fmt.sbprintf(b, "font-size:%.0fpx;", cs.size)
				}
				strings.write_string(b, "\">")
			}
			if cs.bold {strings.write_string(b, "<strong>")}
			if cs.italic {strings.write_string(b, "<em>")}
			if cs.underline {strings.write_string(b, "<u>")}
			if cs.mono {strings.write_string(b, "<code>")}
			html_escape(b, string(r.text[:]))
			if cs.mono {strings.write_string(b, "</code>")}
			if cs.underline {strings.write_string(b, "</u>")}
			if cs.italic {strings.write_string(b, "</em>")}
			if cs.bold {strings.write_string(b, "</strong>")}
			if cs.color != 0 || cs.size != 0 {strings.write_string(b, "</span>")}
		}
	}

	// emit_table writes a real <table>: a <thead> when the first row is a
	// header, so the structure survives into whatever receives the HTML
	// rather than being a grid of divs that merely looks like one.
	emit_table :: proc(b: ^strings.Builder, t: ^Table) {
		strings.write_string(b, "<table>\n")
		if table_cols(t) > 0 {
			strings.write_string(b, "<colgroup>")
			for c in 0 ..< table_cols(t) {
				fmt.sbprintf(b, "<col style=\"width:%.1f%%\">", table_width(t, c) / CONTENT_W * 100)
			}
			strings.write_string(b, "</colgroup>\n")
		}
		// A merged cell is one <td> with colspan/rowspan; the cells it covers
		// are not written at all, which is what the HTML table model means.
		head_end := table_head_end(t)
		for r in 0 ..< len(t.rows) {
			head := r <= head_end
			if r == 0 && head {
				strings.write_string(b, "<thead>")
			} else if r == head_end + 1 {
				strings.write_string(b, "<tbody>")
			}
			strings.write_string(b, "<tr>")
			for c in 0 ..< table_cols(t) {
				cl := table_cell(t, r, c)
				if cl != nil && cl.covered {
					continue
				}
				tag := head ? "th" : "td"
				fmt.sbprintf(b, "<%s", tag)
				if cl != nil && cell_cspan(cl) > 1 {
					fmt.sbprintf(b, " colspan=\"%d\"", cell_cspan(cl))
				}
				if cl != nil && cell_rspan(cl) > 1 {
					fmt.sbprintf(b, " rowspan=\"%d\"", cell_rspan(cl))
				}
				strings.write_string(b, ">")
				if cl != nil {
					for &cp, i in cl.paras {
						if i > 0 {
							strings.write_string(b, "<br>")
						}
						// A picture in a cell is the same <img> as one in the
						// body, without the <figure> around it: a figure is a
						// block, and a cell is already one.
						if cp.kind == .Image {
							emit_cell_image(b, &cp, max(20, table_span_w(t, r, c) - 2 * CELL_PAD))
							continue
						}
						emit_runs(b, &cp)
					}
				}
				fmt.sbprintf(b, "</%s>", tag)
			}
			strings.write_string(b, "</tr>")
			if r == head_end {
				strings.write_string(b, "</thead>\n")
			}
		}
		if len(t.rows) > head_end + 1 {
			strings.write_string(b, "</tbody>\n")
		}
		strings.write_string(b, "</table>\n")
	}

	// emit_image inlines the picture as a data URI, so the exported page is
	// one self-contained file rather than a document that breaks when the
	// picture beside it is not copied too.
	emit_image :: proc(b: ^strings.Builder, pa: ^Paragraph) {
		im := pa.img
		w, h := image_para_size(pa)
		align := "center"
		switch pa.align {
		case .Left:
			align = "left"
		case .Right:
			align = "right"
		case .Center, .Justify:
		}
		fmt.sbprintf(b, "<figure style=\"text-align:%s\">", align)
		if im != nil && len(im.bytes) > 0 {
			enc, err := base64.encode(im.bytes, base64.ENC_TABLE, context.temp_allocator)
			if err == nil {
				fmt.sbprintf(b, "<img width=\"%.0f\" height=\"%.0f\" alt=\"", w, h)
				html_escape(b, im == nil ? "" : im.alt)
				fmt.sbprintf(b, "\" src=\"data:%s;base64,%s\">", image_mime(im.kind), enc)
			}
		} else if im != nil {
			fmt.sbprintf(b, "<img width=\"%.0f\" height=\"%.0f\" alt=\"", w, h)
			html_escape(b, im.alt)
			strings.write_string(b, "\" src=\"")
			html_escape(b, im.path)
			strings.write_string(b, "\">")
		}
		strings.write_string(b, "</figure>\n")
	}

	// emit_cell_image is the same picture without the <figure>: a cell is
	// already a block, and a figure inside a table cell is not something a
	// browser lays out the way anyone wants.
	emit_cell_image :: proc(b: ^strings.Builder, pa: ^Paragraph, measure: f32) {
		im := pa.img
		if im == nil {
			return
		}
		w, h := image_para_size(pa, measure, CONTENT_H)
		if len(im.bytes) > 0 {
			enc, err := base64.encode(im.bytes, base64.ENC_TABLE, context.temp_allocator)
			if err == nil {
				fmt.sbprintf(b, "<img width=\"%.0f\" height=\"%.0f\" alt=\"", w, h)
				html_escape(b, im.alt)
				fmt.sbprintf(b, "\" src=\"data:%s;base64,%s\">", image_mime(im.kind), enc)
				return
			}
		}
		fmt.sbprintf(b, "<img width=\"%.0f\" height=\"%.0f\" alt=\"", w, h)
		html_escape(b, im.alt)
		strings.write_string(b, "\" src=\"")
		html_escape(b, im.path)
		strings.write_string(b, "\">")
	}

	list_open := List_Kind.None
	in_pre := false
	for &pa in d.paras {
		if pa.kind == .Table || pa.kind == .Image {
			if in_pre {
				strings.write_string(&b, "</pre>\n")
				in_pre = false
			}
			if list_open != .None {
				strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
				list_open = .None
			}
			if pa.kind == .Table && pa.table != nil {
				emit_table(&b, pa.table)
			} else if pa.kind == .Image {
				emit_image(&b, &pa)
			}
			continue
		}
		if pa.kind == .Code {
			if list_open != .None {
				strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
				list_open = .None
			}
			if !in_pre {
				strings.write_string(&b, "<pre>")
				in_pre = true
			} else {
				strings.write_string(&b, "\n")
			}
			for &r in pa.runs {
				html_escape(&b, string(r.text[:]))
			}
			continue
		}
		if in_pre {
			strings.write_string(&b, "</pre>\n")
			in_pre = false
		}
		if pa.list != list_open {
			if list_open != .None {
				strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
			}
			if pa.list != .None {
				strings.write_string(&b, pa.list == .Bullet ? "<ul>\n" : "<ol>\n")
			}
			list_open = pa.list
		}

		style := ""
		switch pa.align {
		case .Center:
			style = " style=\"text-align:center\""
		case .Right:
			style = " style=\"text-align:right\""
		case .Justify:
			style = " style=\"text-align:justify\""
		case .Left:
		}

		if pa.list != .None {
			fmt.sbprintf(&b, "<li%s>", style)
			emit_runs(&b, &pa)
			strings.write_string(&b, "</li>\n")
			continue
		}
		tag := "p"
		switch pa.kind {
		case .H1:
			tag = "h1"
		case .H2:
			tag = "h2"
		case .H3:
			tag = "h3"
		case .Quote:
			tag = "blockquote"
		case .Body, .Code, .Table, .Image:
		}
		fmt.sbprintf(&b, "<%s%s>", tag, style)
		emit_runs(&b, &pa)
		fmt.sbprintf(&b, "</%s>\n", tag)
	}
	if in_pre {
		strings.write_string(&b, "</pre>\n")
	}
	if list_open != .None {
		strings.write_string(&b, list_open == .Bullet ? "</ul>\n" : "</ol>\n")
	}
	strings.write_string(&b, "</div></body></html>\n")
	return strings.to_string(b)
}

export_html :: proc(d: ^Doc, path, title: string) -> bool {
	text := doc_to_html(d, title, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// base_name is the last path component, which is what a title defaults to.
base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

// doc_display_title is the document's own title where it has one — the text of
// its first heading — and the file name otherwise. It is what goes into a
// PDF's /Title, a .docx's dc:title and an .odt's office:meta.
doc_display_title :: proc(d: ^Doc, fallback: string) -> string {
	for &pa in d.paras {
		if pa.kind != .H1 {
			continue
		}
		t := strings.trim_space(para_text(&pa, context.temp_allocator))
		if len(t) > 0 {
			return t
		}
	}
	return fallback
}

swap_ext :: proc(path, ext: string, alloc := context.allocator) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_byte(path, '/')
	if dot > slash && dot >= 0 {
		return strings.concatenate({path[:dot], ext}, alloc)
	}
	return strings.concatenate({path, ext}, alloc)
}

expand_home :: proc(path: string, alloc := context.allocator) -> string {
	if strings.has_prefix(path, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			return strings.concatenate({home, path[1:]}, alloc)
		}
	}
	return strings.clone(path, alloc)
}
