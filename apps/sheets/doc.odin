// The native document format: JSON, so that it can be read back exactly and
// inspected with any text tool. Only what the user authored is stored —
// inputs, formats, the sizes they changed, the frozen split, the merges, the
// charts and the names — never computed values, which are rebuilt by a full
// recalculation on load.
//
// The same serialiser backs undo: a snapshot is just the document as a
// string, which makes undo of a structural edit as correct as undo of a typo.
// That also sets the rule for anything added to the model — if it does not
// serialise, undo silently loses it. Sheets, panes, merges, names and charts
// are all here for that reason.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Version 1 was a single sheet with its cells at the top level. Version 2 is
// a book. Both are read; only version 2 is written.
DOC_VERSION :: 2

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

Chart_JSON :: struct {
	kind:  int,
	title: string,
	sheet: string,
	range: string,
	at:    string,
	w:     int,
	h:     int,
	labels: bool,
}

Name_JSON :: struct {
	name:  string,
	sheet: string,
	range: string,
	abs:   bool,
	// "" for a name the whole book sees; a sheet's name for one only that
	// sheet sees. Absent in files written before scopes existed, which reads
	// as "" — exactly what those names were.
	scope: string,
}

Sheet_JSON :: struct {
	name:    string,
	cells:   []Cell_JSON,
	cols:    []Size_JSON,
	rows:    []Size_JSON,
	frz_row: int,
	frz_col: int,
	merges:  []string,
	charts:  []Chart_JSON,
}

Doc_JSON :: struct {
	kind:    string,
	version: int,
	name:    string,
	active:  int,
	sheets:  []Sheet_JSON,
	names:   []Name_JSON,
	cursor:  string,
	anchor:  string,
	// Version 1, still read so an older file opens. Never written.
	cells:   []Cell_JSON,
	cols:    []Size_JSON,
	rows:    []Size_JSON,
}

rect_text :: proc(r: Rect_I) -> string {
	return fmt.tprintf("%s:%s", addr_name({r.r0, r.c0}), addr_name({r.r1, r.c1}))
}

@(private = "file")
sheet_json :: proc(sh: ^Sheet) -> Sheet_JSON {
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
				ref = addr_name(a),
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

	merges := make([dynamic]string, 0, len(sh.merges), context.temp_allocator)
	for m in sh.merges {
		append(&merges, rect_text(m))
	}
	charts := make([dynamic]Chart_JSON, 0, len(sh.charts), context.temp_allocator)
	for ch in sh.charts {
		append(
			&charts,
			Chart_JSON {
				kind = int(ch.kind),
				title = ch.title,
				sheet = ch.sheet,
				range = rect_text(ch.rect),
				at = addr_name(ch.at),
				w = ch.w,
				h = ch.h,
				labels = ch.labels,
			},
		)
	}

	return Sheet_JSON {
		name = sh.name,
		cells = cells[:],
		cols = cols[:],
		rows = rows[:],
		frz_row = sh.frz_rows,
		frz_col = sh.frz_cols,
		merges = merges[:],
		charts = charts[:],
	}
}

// doc_save_string serialises the whole book the sheet belongs to. Taking a
// sheet rather than a book is deliberate: every call site has one in hand,
// and a sheet always knows its book.
doc_save_string :: proc(
	sh: ^Sheet,
	name: string,
	cursor, anchor: Addr,
	allocator := context.allocator,
) -> string {
	bk := sh.book
	sheets := make([dynamic]Sheet_JSON, 0, len(bk.sheets), context.temp_allocator)
	for s in bk.sheets {
		append(&sheets, sheet_json(s))
	}

	names := names_to_json(bk)

	doc := Doc_JSON {
		kind    = "palmy.sheets",
		version = DOC_VERSION,
		name    = name,
		active  = bk.active,
		sheets  = sheets[:],
		names   = names[:],
		cursor  = addr_name(cursor),
		anchor  = addr_name(anchor),
	}
	data, err := json.marshal(
		doc,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone("", allocator)
	}
	return strings.clone(string(data), allocator)
}

@(private = "file")
load_sheet_json :: proc(sh: ^Sheet, sj: Sheet_JSON) {
	for c in sj.cells {
		r, parsed := ref_parse(c.ref)
		if !parsed || r.row == NO_ROW || r.col == NO_COL {
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
	for s in sj.cols {
		set_col_width(sh, s.i, s.v)
	}
	for s in sj.rows {
		set_row_height(sh, s.i, s.v)
	}
	set_freeze(sh, sj.frz_row, sj.frz_col)
	for m in sj.merges {
		if r, ok := parse_a1_range(m); ok {
			add_merge(sh, r)
		}
	}
	for cj in sj.charts {
		rect, rok := parse_a1_range(cj.range)
		if !rok {
			continue
		}
		at, aok := ref_parse(cj.at)
		if !aok || at.row == NO_ROW || at.col == NO_COL {
			continue
		}
		append(
			&sh.charts,
			Chart {
				kind = Chart_Kind(clamp(cj.kind, 0, int(max(Chart_Kind)))),
				title = strings.clone(cj.title, sh.heap),
				sheet = strings.clone(cj.sheet, sh.heap),
				rect = rect,
				at = {at.row, at.col},
				w = clamp(cj.w, 1, CHART_MAX_W),
				h = clamp(cj.h, 1, CHART_MAX_H),
				labels = cj.labels,
			},
		)
	}
}

// rename_raw sets a sheet's name without rewriting the formulas that mention
// it, which is what loading wants: the formulas already say the right thing.
@(private = "file")
rename_raw :: proc(sh: ^Sheet, name: string) {
	if name == "" {
		return
	}
	if sh.name != "" {
		delete(sh.name, sh.heap)
	}
	sh.name = strings.clone(name, sh.heap)
}

doc_load_string :: proc(
	sh: ^Sheet,
	data: string,
) -> (
	name: string,
	cursor, anchor: Addr,
	ok: bool,
) {
	doc: Doc_JSON
	if err := json.unmarshal(
		transmute([]u8)data,
		&doc,
		json.DEFAULT_SPECIFICATION,
		context.temp_allocator,
	); err != nil {
		return "", {}, {}, false
	}
	if doc.kind != "" && doc.kind != "palmy.sheets" {
		return "", {}, {}, false
	}

	bk := sh.book
	// Collapse the book back to the one sheet the caller handed us, then grow
	// it again. Doing it this way keeps `sh` valid, which matters because the
	// caller — and the undo stack — holds a pointer to it.
	for i := len(bk.sheets) - 1; i >= 0; i -= 1 {
		if bk.sheets[i] == sh {
			continue
		}
		s := bk.sheets[i]
		ordered_remove(&bk.sheets, i)
		sheet_release(s)
		if s.allocated {
			free(s, bk.heap)
		}
	}
	sh.index = 0
	sheet_clear(sh)
	book_clear_names(bk)

	if len(doc.sheets) > 0 {
		for sj, i in doc.sheets {
			target := sh
			if i > 0 {
				target = book_add_sheet(bk, sj.name != "" ? sj.name : "Sheet")
				if target == nil {
					break
				}
			} else {
				rename_raw(sh, sj.name)
			}
			load_sheet_json(target, sj)
		}
	} else {
		// Version 1: one sheet, its cells at the top level.
		load_sheet_json(sh, Sheet_JSON{cells = doc.cells, cols = doc.cols, rows = doc.rows})
	}

	names_from_json(bk, doc.names)

	bk.active = clamp(doc.active, 0, len(bk.sheets) - 1)
	clear(&bk.seeds)
	bk.graph_dirty = true
	book_recalc_all(bk)

	cursor = {}
	anchor = {}
	if r, good := ref_parse(doc.cursor); good && r.row != NO_ROW && r.col != NO_COL {
		cursor = {r.row, r.col}
	}
	if r, good := ref_parse(doc.anchor); good && r.row != NO_ROW && r.col != NO_COL {
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

// names_to_json lists every name of every scope, sorted, so the file is
// stable. The collaboration document stores the very same list.
names_to_json :: proc(bk: ^Book) -> []Name_JSON {
	entries := book_name_entries(bk)
	out := make([dynamic]Name_JSON, 0, len(entries), context.temp_allocator)
	for e in entries {
		append(
			&out,
			Name_JSON {
				name = e.name,
				sheet = e.def.sheet,
				range = rect_text(e.def.rect),
				abs = e.def.abs,
				scope = e.scope,
			},
		)
	}
	return out[:]
}

// names_from_json defines them again. The sheets must exist first, since a
// local name lives on its sheet; one whose sheet is missing is dropped.
names_from_json :: proc(bk: ^Book, names: []Name_JSON) {
	for nj in names {
		if r, good := parse_a1_range(nj.range); good {
			book_set_name(bk, nj.name, nj.sheet, r, nj.abs, nj.scope)
		}
	}
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

sort_strings :: proc(xs: []string) {
	for i in 1 ..< len(xs) {
		x := xs[i]
		j := i - 1
		for j >= 0 && xs[j] > x {
			xs[j + 1] = xs[j]
			j -= 1
		}
		xs[j + 1] = x
	}
}
