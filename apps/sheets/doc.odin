// The native document format: JSON, so that it can be read back exactly and
// inspected with any text tool. Only what the user authored is stored —
// inputs, formats and the sizes they changed — never computed values, which
// are rebuilt by a full recalculation on load.
//
// The same serialiser backs undo: a snapshot is just the document as a
// string, which makes undo of a structural edit as correct as undo of a typo.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

DOC_VERSION :: 1

Cell_JSON :: struct {
	ref:    string,
	input:  string,
	nfmt:   int,
	dec:    int,
	align:  int,
	bold:   bool,
	italic: bool,
}

Size_JSON :: struct {
	i: int,
	v: f32,
}

Doc_JSON :: struct {
	kind:    string,
	version: int,
	name:    string,
	cells:   []Cell_JSON,
	cols:    []Size_JSON,
	rows:    []Size_JSON,
	cursor:  string,
	anchor:  string,
}

doc_save_string :: proc(
	sh: ^Sheet,
	name: string,
	cursor, anchor: Addr,
	allocator := context.allocator,
) -> string {
	cells := make([dynamic]Cell_JSON, 0, len(sh.cells), context.temp_allocator)
	// Sorted output, so a saved file is stable and diffs cleanly.
	addrs := make([dynamic]Addr, 0, len(sh.cells), context.temp_allocator)
	for a in sh.cells {
		append(&addrs, a)
	}
	sort_addrs(addrs[:])
	for a in addrs {
		c := sh.cells[a]
		append(
			&cells,
			Cell_JSON {
				ref = fmt.tprintf("%s%d", col_name(a.col), a.row + 1),
				input = c.input,
				nfmt = int(c.fmt.num),
				dec = int(c.fmt.dec),
				align = int(c.fmt.align),
				bold = c.fmt.bold,
				italic = c.fmt.italic,
			},
		)
	}
	cols := make([dynamic]Size_JSON, 0, len(sh.col_w), context.temp_allocator)
	for i, v in sh.col_w {
		append(&cols, Size_JSON{i, v})
	}
	rows := make([dynamic]Size_JSON, 0, len(sh.row_h), context.temp_allocator)
	for i, v in sh.row_h {
		append(&rows, Size_JSON{i, v})
	}
	slice_sort_sizes(cols[:])
	slice_sort_sizes(rows[:])

	doc := Doc_JSON {
		kind    = "palmy.sheets",
		version = DOC_VERSION,
		name    = name,
		cells   = cells[:],
		cols    = cols[:],
		rows    = rows[:],
		cursor  = addr_name(cursor),
		anchor  = addr_name(anchor),
	}
	data, err := json.marshal(doc, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		return strings.clone("", allocator)
	}
	return strings.clone(string(data), allocator)
}

doc_load_string :: proc(sh: ^Sheet, data: string) -> (name: string, cursor, anchor: Addr, ok: bool) {
	doc: Doc_JSON
	if err := json.unmarshal(transmute([]u8)data, &doc, json.DEFAULT_SPECIFICATION, context.temp_allocator);
	   err != nil {
		return "", {}, {}, false
	}
	if doc.kind != "" && doc.kind != "palmy.sheets" {
		return "", {}, {}, false
	}
	sheet_clear(sh)
	for c in doc.cells {
		r, parsed := ref_parse(c.ref)
		if !parsed || r.row == NO_ROW {
			continue
		}
		a := Addr{r.row, r.col}
		set_input(sh, a, c.input)
		set_cell_fmt(
			sh,
			a,
			Cell_Fmt {
				num = Num_Format(clamp(c.nfmt, 0, int(max(Num_Format)))),
				dec = u8(clamp(c.dec, 0, 9)),
				align = Halign(clamp(c.align, 0, int(max(Halign)))),
				bold = c.bold,
				italic = c.italic,
			},
		)
	}
	for s in doc.cols {
		set_col_width(sh, s.i, s.v)
	}
	for s in doc.rows {
		set_row_height(sh, s.i, s.v)
	}
	clear(&sh.seeds)
	sh.graph_dirty = true
	recalc_all(sh)

	cursor = {}
	anchor = {}
	if r, good := ref_parse(doc.cursor); good && r.row != NO_ROW {
		cursor = {r.row, r.col}
	}
	if r, good := ref_parse(doc.anchor); good && r.row != NO_ROW {
		anchor = {r.row, r.col}
	} else {
		anchor = cursor
	}
	return strings.clone(doc.name, context.temp_allocator), cursor, anchor, true
}

doc_save_file :: proc(sh: ^Sheet, path, name: string, cursor, anchor: Addr) -> bool {
	text := doc_save_string(sh, name, cursor, anchor, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

doc_load_file :: proc(sh: ^Sheet, path: string) -> (cursor, anchor: Addr, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, {}, false
	}
	_, c, a, good := doc_load_string(sh, string(data))
	return c, a, good
}

// ---------------------------------------------------------------------------
// Sorting helpers. core:slice would do, but these are three lines each and
// avoid pulling a comparator closure through a package boundary.
// ---------------------------------------------------------------------------

sort_addrs :: proc(xs: []Addr) {
	for i in 1 ..< len(xs) {
		x := xs[i]
		j := i - 1
		for j >= 0 && (xs[j].row > x.row || (xs[j].row == x.row && xs[j].col > x.col)) {
			xs[j + 1] = xs[j]
			j -= 1
		}
		xs[j + 1] = x
	}
}

slice_sort_sizes :: proc(xs: []Size_JSON) {
	for i in 1 ..< len(xs) {
		x := xs[i]
		j := i - 1
		for j >= 0 && xs[j].i > x.i {
			xs[j + 1] = xs[j]
			j -= 1
		}
		xs[j + 1] = x
	}
}
