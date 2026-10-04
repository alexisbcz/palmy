// Tables.
//
// A table is not a parallel document model sitting next to the real one. It is
// a `Para_Kind` — `.Table` — whose content happens to be a grid instead of a
// list of runs, and every cell of that grid holds an ordinary `[]Paragraph`.
// That one decision is what makes the rest of the program keep working:
//
//   * wrapping is `wrap_paragraph` called with the column's width as the
//     measure, so a cell paragraph breaks words, justifies and carries mixed
//     runs exactly as a body paragraph does;
//   * styling is `apply_patch` over the same `Pos` range;
//   * the caret is a `Pos` with three more fields — `row`, `col`, `cpara` —
//     which are zero everywhere outside a table, so `pos(para, off)` still
//     means what it always meant;
//   * every exporter already walks paragraphs, so a cell is one more place to
//     walk rather than a second emitter.
//
// ## Column widths
//
// `widths` is one entry per column, in layout pixels, and is kept summing to
// the content measure by `table_fit_widths`. A table is therefore always
// exactly as wide as the text area, which is what a reader expects and what
// makes the page-break arithmetic exact.
//
// ## Pagination
//
// See `layout_table` in layout.odin. The rule chosen here is **break across
// pages and repeat the header row**: a row is atomic, a table that does not
// fit breaks before the first row that would overflow, and if the table has a
// header row that row is drawn again at the top of the continuation. The
// alternative — move the whole table down — is one line of code and loses the
// ability to have a table longer than a page at all.
package main

import "core:strings"

// Geometry. A cell's text is inset by CELL_PAD on every side, and the rules
// are drawn one layout pixel wide on the cell boundary.
CELL_PAD :: f32(7)
TABLE_RULE :: f32(1)
TABLE_MIN_COL :: f32(40)
TABLE_MAX_COLS :: 12
TABLE_MAX_ROWS :: 200

COL_TABLE_RULE :: u32(0xa8a8aa)
COL_TABLE_HEAD :: u32(0xf1f1f2)

Cell :: struct {
	paras: [dynamic]Paragraph,
}

Row :: struct {
	cells: [dynamic]Cell,
}

Table :: struct {
	rows:    [dynamic]Row,
	widths:  [dynamic]f32, // one per column, layout px
	header:  bool, // the first row is a header: shaded, bold, repeated
	borders: bool,
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

cell_make :: proc() -> Cell {
	c := Cell {
		paras = make([dynamic]Paragraph, 0, 1),
	}
	append(&c.paras, para_make())
	return c
}

cell_destroy :: proc(c: ^Cell) {
	for &pa in c.paras {
		para_destroy(&pa)
	}
	delete(c.paras)
	c.paras = nil
}

cell_clone :: proc(c: ^Cell) -> Cell {
	out := Cell {
		paras = make([dynamic]Paragraph, 0, max(1, len(c.paras))),
	}
	for &pa in c.paras {
		append(&out.paras, para_clone(&pa))
	}
	if len(out.paras) == 0 {
		append(&out.paras, para_make())
	}
	return out
}

table_make :: proc(nrows, ncols: int, header := true) -> Table {
	r := clamp(nrows, 1, TABLE_MAX_ROWS)
	c := clamp(ncols, 1, TABLE_MAX_COLS)
	t := Table {
		rows    = make([dynamic]Row, 0, r),
		widths  = make([dynamic]f32, 0, c),
		header  = header,
		borders = true,
	}
	for _ in 0 ..< r {
		row := Row {
			cells = make([dynamic]Cell, 0, c),
		}
		for _ in 0 ..< c {
			append(&row.cells, cell_make())
		}
		append(&t.rows, row)
	}
	for _ in 0 ..< c {
		append(&t.widths, CONTENT_W / f32(c))
	}
	return t
}

table_destroy :: proc(t: ^Table) {
	for &row in t.rows {
		for &c in row.cells {
			cell_destroy(&c)
		}
		delete(row.cells)
	}
	delete(t.rows)
	delete(t.widths)
	t^ = {}
}

table_clone :: proc(t: ^Table) -> Table {
	out := Table {
		rows    = make([dynamic]Row, 0, len(t.rows)),
		widths  = make([dynamic]f32, 0, len(t.widths)),
		header  = t.header,
		borders = t.borders,
	}
	for &row in t.rows {
		nr := Row {
			cells = make([dynamic]Cell, 0, len(row.cells)),
		}
		for &c in row.cells {
			append(&nr.cells, cell_clone(&c))
		}
		append(&out.rows, nr)
	}
	for w in t.widths {
		append(&out.widths, w)
	}
	return out
}

// table_para_make wraps a fresh table in the paragraph that owns it.
table_para_make :: proc(nrows, ncols: int, header := true) -> Paragraph {
	pa := para_make(.Table)
	pa.table = new(Table)
	pa.table^ = table_make(nrows, ncols, header)
	return pa
}

// ---------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------

table_cols :: proc(t: ^Table) -> int {
	n := len(t.widths)
	for &row in t.rows {
		n = max(n, len(row.cells))
	}
	return n
}

table_rows :: proc(t: ^Table) -> int {
	return len(t.rows)
}

table_cell :: proc(t: ^Table, row, col: int) -> ^Cell {
	if t == nil || row < 0 || row >= len(t.rows) {
		return nil
	}
	cells := &t.rows[row].cells
	if col < 0 || col >= len(cells) {
		return nil
	}
	return &cells[col]
}

table_width :: proc(t: ^Table, col: int) -> f32 {
	if col < 0 || col >= len(t.widths) {
		n := max(1, table_cols(t))
		return CONTENT_W / f32(n)
	}
	return t.widths[col]
}

// table_col_x is a column's left edge, relative to the table's own left edge.
table_col_x :: proc(t: ^Table, col: int) -> f32 {
	x := f32(0)
	for c in 0 ..< col {
		x += table_width(t, c)
	}
	return x
}

table_total_w :: proc(t: ^Table) -> f32 {
	w := f32(0)
	for c in 0 ..< table_cols(t) {
		w += table_width(t, c)
	}
	return w
}

// table_fit_widths makes `widths` have one entry per column and sum to the
// content measure. Every structural edit ends here, so a table is never wider
// or narrower than the page it lives on.
table_fit_widths :: proc(t: ^Table) {
	n := table_cols(t)
	for len(t.widths) < n {
		append(&t.widths, CONTENT_W / f32(n))
	}
	if len(t.widths) > n {
		resize(&t.widths, n)
	}
	// Every column gets at least TABLE_MIN_COL, then the slack is distributed
	// in proportion to what was asked for.
	total := f32(0)
	for w in t.widths {
		total += max(w, TABLE_MIN_COL)
	}
	if total <= 0 {
		for i in 0 ..< n {
			t.widths[i] = CONTENT_W / f32(n)
		}
		return
	}
	k := CONTENT_W / total
	acc := f32(0)
	for i in 0 ..< n {
		w := max(t.widths[i], TABLE_MIN_COL) * k
		if i == n - 1 {
			w = CONTENT_W - acc // the last column absorbs the rounding
		}
		t.widths[i] = w
		acc += w
	}
}

// table_set_width nudges one column and takes the difference out of its
// right-hand neighbour, which is how dragging a column rule behaves.
table_set_width :: proc(t: ^Table, col: int, w: f32) {
	n := table_cols(t)
	if col < 0 || col >= n || n < 2 {
		return
	}
	other := col + 1 < n ? col + 1 : col - 1
	pair := t.widths[col] + t.widths[other]
	nw := clamp(w, TABLE_MIN_COL, pair - TABLE_MIN_COL)
	t.widths[other] = pair - nw
	t.widths[col] = nw
	table_fit_widths(t)
}

// ---------------------------------------------------------------------------
// Structural edits
// ---------------------------------------------------------------------------

table_insert_row :: proc(t: ^Table, at: int) -> int {
	if len(t.rows) >= TABLE_MAX_ROWS {
		return clamp(at, 0, len(t.rows) - 1)
	}
	n := table_cols(t)
	row := Row {
		cells = make([dynamic]Cell, 0, n),
	}
	for _ in 0 ..< n {
		append(&row.cells, cell_make())
	}
	k := clamp(at, 0, len(t.rows))
	inject_at(&t.rows, k, row)
	return k
}

table_delete_row :: proc(t: ^Table, at: int) -> bool {
	if len(t.rows) <= 1 || at < 0 || at >= len(t.rows) {
		return false
	}
	for &c in t.rows[at].cells {
		cell_destroy(&c)
	}
	delete(t.rows[at].cells)
	ordered_remove(&t.rows, at)
	return true
}

table_insert_col :: proc(t: ^Table, at: int) -> int {
	n := table_cols(t)
	if n >= TABLE_MAX_COLS {
		return clamp(at, 0, n - 1)
	}
	k := clamp(at, 0, n)
	for &row in t.rows {
		for len(row.cells) < n {
			append(&row.cells, cell_make())
		}
		inject_at(&row.cells, min(k, len(row.cells)), cell_make())
	}
	// The new column takes its width from the widest existing one, halving it,
	// and `table_fit_widths` rescales the lot back onto the measure.
	w := n > 0 ? table_width(t, min(k, n - 1)) / 2 : CONTENT_W
	inject_at(&t.widths, min(k, len(t.widths)), max(w, TABLE_MIN_COL))
	table_fit_widths(t)
	return k
}

table_delete_col :: proc(t: ^Table, at: int) -> bool {
	n := table_cols(t)
	if n <= 1 || at < 0 || at >= n {
		return false
	}
	for &row in t.rows {
		if at < len(row.cells) {
			cell_destroy(&row.cells[at])
			ordered_remove(&row.cells, at)
		}
	}
	if at < len(t.widths) {
		ordered_remove(&t.widths, at)
	}
	table_fit_widths(t)
	return true
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

// table_step_cell walks the grid in reading order. `ok` is false when the walk
// runs off the end, which is the signal to leave the table — or, for Tab at the
// last cell, to grow it by a row the way every word processor does.
table_step_cell :: proc(t: ^Table, row, col, dir: int) -> (nr, nc: int, ok: bool) {
	n := table_cols(t)
	if n <= 0 || len(t.rows) == 0 {
		return row, col, false
	}
	i := row * n + clamp(col, 0, n - 1) + dir
	if i < 0 || i >= len(t.rows) * n {
		return row, col, false
	}
	return i / n, i % n, true
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

cell_text :: proc(c: ^Cell, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	for &pa, i in c.paras {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		for &r in pa.runs {
			strings.write_bytes(&b, r.text[:])
		}
	}
	return strings.to_string(b)
}

// table_is_empty reports a table whose every cell is blank, which is what the
// Markdown writer uses to decide a table is not worth emitting.
table_is_empty :: proc(t: ^Table) -> bool {
	for &row in t.rows {
		for &c in row.cells {
			for &pa in c.paras {
				if para_len(&pa) > 0 {
					return false
				}
			}
		}
	}
	return true
}
