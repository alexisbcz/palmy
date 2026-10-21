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
// ## Merged cells
//
// A merged cell is an **anchor** — the top-left cell of the merged rectangle,
// which carries `cspan` columns by `rspan` rows — and the cells it hides, which
// stay in the grid with `covered` set. The grid therefore stays rectangular:
// every (row, col) still has a `Cell`, so a `Pos`, the CRDT's row and column
// identities, and every loop over `t.rows[r].cells` keep meaning what they
// meant. What changes is who *reads* a covered cell: nobody. It holds one empty
// paragraph, it contributes no block (`doc_blocks` skips it), no line, no box,
// and a position that lands on one is moved to its anchor (`pos_clamp`).
//
// The spans are the truth and `covered` is derived from them by
// `table_normalise`, which every structural edit and every reader ends with. It
// also repairs what a hand-edited or foreign file can say — spans running off
// the grid, two merges claiming one cell (the earlier one in reading order
// wins, the later one shrinks), text sitting in a covered cell (it moves into
// the anchor rather than vanishing).
//
// Merging moves every merged cell's paragraphs into the anchor, in reading
// order, skipping cells that are blank — which is what Word and LibreOffice do.
// Splitting gives the hidden cells back empty and leaves the text where it is.
//
// Inserting a row or column *inside* a merged rectangle grows the merge, and
// deleting one shrinks it; deleting the anchor's own row or column hands the
// text and the rest of the span to the next cell down or right.
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
	paras:   [dynamic]Paragraph,
	// An anchor's extent, in columns and rows. 0 and 1 both mean one, so a
	// zero-initialised cell is an ordinary cell.
	cspan:   int,
	rspan:   int,
	// Hidden under some anchor's span. Derived by `table_normalise`.
	covered: bool,
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
		paras   = make([dynamic]Paragraph, 0, max(1, len(c.paras))),
		cspan   = c.cspan,
		rspan   = c.rspan,
		covered = c.covered,
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
	// A row inserted strictly inside a vertical merge grows it.
	for r in 0 ..< min(k, len(t.rows)) {
		for &cl in t.rows[r].cells {
			if !cl.covered && r < k && k < r + cell_rspan(&cl) {
				cl.rspan = cell_rspan(&cl) + 1
			}
		}
	}
	inject_at(&t.rows, k, row)
	table_normalise(t)
	return k
}

table_delete_row :: proc(t: ^Table, at: int) -> bool {
	if len(t.rows) <= 1 || at < 0 || at >= len(t.rows) {
		return false
	}
	table_normalise(t)
	for r in 0 ..< len(t.rows) {
		for c in 0 ..< len(t.rows[r].cells) {
			cl := &t.rows[r].cells[c]
			if cl.covered {
				continue
			}
			rs := cell_rspan(cl)
			if r < at && at < r + rs {
				cl.rspan = rs - 1 // the row goes from under the merge
			} else if r == at && rs > 1 && at + 1 < len(t.rows) {
				// The anchor's own row goes: the cell below takes over its
				// text and the rest of its span.
				below := &t.rows[at + 1].cells[c]
				cell_destroy(below)
				below^ = cl^
				below.rspan = rs - 1
				below.covered = false
				cl^ = cell_make()
			}
		}
	}
	for &c in t.rows[at].cells {
		cell_destroy(&c)
	}
	delete(t.rows[at].cells)
	ordered_remove(&t.rows, at)
	table_normalise(t)
	return true
}

table_insert_col :: proc(t: ^Table, at: int) -> int {
	n := table_cols(t)
	if n >= TABLE_MAX_COLS {
		return clamp(at, 0, n - 1)
	}
	k := clamp(at, 0, n)
	// A column inserted strictly inside a horizontal merge grows it.
	for &row in t.rows {
		for c in 0 ..< min(k, len(row.cells)) {
			cl := &row.cells[c]
			if !cl.covered && c < k && k < c + cell_cspan(cl) {
				cl.cspan = cell_cspan(cl) + 1
			}
		}
	}
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
	table_normalise(t)
	return k
}

table_delete_col :: proc(t: ^Table, at: int) -> bool {
	n := table_cols(t)
	if n <= 1 || at < 0 || at >= n {
		return false
	}
	table_normalise(t)
	for &row in t.rows {
		for c in 0 ..< len(row.cells) {
			cl := &row.cells[c]
			if cl.covered {
				continue
			}
			cs := cell_cspan(cl)
			if c < at && at < c + cs {
				cl.cspan = cs - 1
			} else if c == at && cs > 1 && at + 1 < len(row.cells) {
				right := &row.cells[at + 1]
				cell_destroy(right)
				right^ = cl^
				right.cspan = cs - 1
				right.covered = false
				cl^ = cell_make()
			}
		}
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
	table_normalise(t)
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
	// From an anchor, in reading order, skipping the cells a merge hides:
	// those hold nothing and are not places a caret can be.
	ar, ac := table_anchor(t, row, clamp(col, 0, n - 1))
	i := ar * n + ac
	for {
		i += dir
		if i < 0 || i >= len(t.rows) * n {
			return row, col, false
		}
		if cl := table_cell(t, i / n, i % n); cl == nil || !cl.covered {
			return i / n, i % n, true
		}
	}
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

// ---------------------------------------------------------------------------
// Merged cells
// ---------------------------------------------------------------------------

cell_cspan :: proc(c: ^Cell) -> int {
	return max(1, c.cspan)
}

cell_rspan :: proc(c: ^Cell) -> int {
	return max(1, c.rspan)
}

// cell_is_merged reports an anchor that spans more than itself.
cell_is_merged :: proc(c: ^Cell) -> bool {
	return c != nil && !c.covered && (c.cspan > 1 || c.rspan > 1)
}

// table_has_merges is what the exporters ask before they bother with spans.
table_has_merges :: proc(t: ^Table) -> bool {
	for &row in t.rows {
		for &c in row.cells {
			if cell_is_merged(&c) {
				return true
			}
		}
	}
	return false
}

// table_anchor finds the cell whose span covers (row, col): the cell itself
// unless it is covered.
table_anchor :: proc(t: ^Table, row, col: int) -> (ar, ac: int) {
	cl := table_cell(t, row, col)
	if cl == nil || !cl.covered {
		return row, col
	}
	for r := row; r >= 0; r -= 1 {
		for c := col; c >= 0; c -= 1 {
			a := table_cell(t, r, c)
			if a == nil || a.covered {
				continue
			}
			if r + cell_rspan(a) > row && c + cell_cspan(a) > col {
				return r, c
			}
		}
	}
	return row, col
}

// table_span_w is the width a cell's text wraps in: the sum of the columns it
// spans.
table_span_w :: proc(t: ^Table, row, col: int) -> f32 {
	cl := table_cell(t, row, col)
	n := cl == nil ? 1 : cell_cspan(cl)
	w := f32(0)
	for c in col ..< col + n {
		w += table_width(t, c)
	}
	return w
}

// table_normalise pads every row to the full width, clips spans to the grid,
// resolves overlapping spans (the earlier anchor in reading order wins and
// the later one shrinks until it fits) and recomputes `covered`. Text found in
// a covered cell is moved into the anchor that covers it, so a malformed file
// loses no words.
table_normalise :: proc(t: ^Table) {
	nr := len(t.rows)
	nc := table_cols(t)
	for &row in t.rows {
		for len(row.cells) < nc {
			append(&row.cells, cell_make())
		}
	}
	claimed := make([]bool, nr * nc, context.temp_allocator)
	owner := make([][2]int, nr * nc, context.temp_allocator)
	for r in 0 ..< nr {
		for c in 0 ..< nc {
			cl := &t.rows[r].cells[c]
			if claimed[r * nc + c] {
				cl.covered = true
				cl.cspan, cl.rspan = 0, 0
				continue
			}
			cl.covered = false
			cs := clamp(cell_cspan(cl), 1, nc - c)
			rs := clamp(cell_rspan(cl), 1, nr - r)
			// Shrink across first, then down, until no claimed cell is inside.
			for cs > 1 {
				clash := false
				for k in c ..< c + cs {
					if claimed[r * nc + k] {clash = true}
				}
				if !clash {break}
				cs -= 1
			}
			for rs > 1 {
				clash := false
				for rr in r + 1 ..< r + rs {
					for k in c ..< c + cs {
						if claimed[rr * nc + k] {clash = true}
					}
				}
				if !clash {break}
				rs -= 1
			}
			cl.cspan = cs > 1 ? cs : 0
			cl.rspan = rs > 1 ? rs : 0
			for rr in r ..< r + rs {
				for cc in c ..< c + cs {
					claimed[rr * nc + cc] = true
					owner[rr * nc + cc] = {r, c}
				}
			}
		}
	}
	// A covered cell holds one empty paragraph and nothing else.
	for r in 0 ..< nr {
		for c in 0 ..< nc {
			cl := &t.rows[r].cells[c]
			if !cl.covered {
				continue
			}
			o := owner[r * nc + c]
			cell_absorb(&t.rows[o[0]].cells[o[1]], cl)
		}
	}
}

// cell_blank is a cell with no text and no picture.
cell_blank :: proc(c: ^Cell) -> bool {
	for &pa in c.paras {
		if !text_kind(pa.kind) || para_len(&pa) > 0 {
			return false
		}
	}
	return true
}

// cell_absorb moves `from`'s paragraphs onto the end of `into` (unless `from`
// is blank) and leaves `from` holding one empty paragraph.
@(private = "file")
cell_absorb :: proc(into, from: ^Cell) {
	if cell_blank(from) {
		if len(from.paras) == 1 {
			return
		}
	} else {
		if cell_blank(into) {
			for &pa in into.paras {
				para_destroy(&pa)
			}
			clear(&into.paras)
		}
		for &pa in from.paras {
			append(&into.paras, pa)
		}
		clear(&from.paras)
	}
	for &pa in from.paras {
		para_destroy(&pa)
	}
	clear(&from.paras)
	append(&from.paras, para_make())
}

// table_merge_rect grows a rectangle until no merged cell straddles its
// edge, which is the only shape a merge can take.
table_merge_rect :: proc(t: ^Table, r0, c0, r1, c1: int) -> (a0, b0, a1, b1: int) {
	nr, nc := len(t.rows), table_cols(t)
	a0, a1 = clamp(min(r0, r1), 0, nr - 1), clamp(max(r0, r1), 0, nr - 1)
	b0, b1 = clamp(min(c0, c1), 0, nc - 1), clamp(max(c0, c1), 0, nc - 1)
	for {
		grew := false
		for r in a0 ..= a1 {
			for c in b0 ..= b1 {
				ar, ac := table_anchor(t, r, c)
				a := table_cell(t, ar, ac)
				if a == nil {
					continue
				}
				er, ec := ar + cell_rspan(a) - 1, ac + cell_cspan(a) - 1
				if ar < a0 {a0 = ar; grew = true}
				if ac < b0 {b0 = ac; grew = true}
				if er > a1 {a1 = er; grew = true}
				if ec > b1 {b1 = ec; grew = true}
			}
		}
		if !grew {
			return
		}
	}
}

// table_merge merges the rectangle between two cells (in any order, grown to
// whole merges). It answers false — and changes nothing — when the rectangle
// is a single cell.
table_merge :: proc(t: ^Table, r0, c0, r1, c1: int) -> bool {
	if t == nil || len(t.rows) == 0 {
		return false
	}
	table_normalise(t)
	a0, b0, a1, b1 := table_merge_rect(t, r0, c0, r1, c1)
	if a0 == a1 && b0 == b1 {
		return false
	}
	anchor := &t.rows[a0].cells[b0]
	for r in a0 ..= a1 {
		for c in b0 ..= b1 {
			if r == a0 && c == b0 {
				continue
			}
			cl := &t.rows[r].cells[c]
			cell_absorb(anchor, cl)
			cl.cspan, cl.rspan = 0, 0
		}
	}
	anchor.cspan = b1 - b0 + 1
	anchor.rspan = a1 - a0 + 1
	table_normalise(t)
	return true
}

// table_split undoes the merge whose anchor covers (row, col). The text stays
// in the anchor; the cells it hid come back empty. False when there was no
// merge there.
table_split :: proc(t: ^Table, row, col: int) -> bool {
	if t == nil {
		return false
	}
	ar, ac := table_anchor(t, row, col)
	a := table_cell(t, ar, ac)
	if !cell_is_merged(a) {
		return false
	}
	a.cspan, a.rspan = 0, 0
	table_normalise(t)
	return true
}

// table_head_end is the last row of the header: row 0 and any rows a vertical
// merge joins to it. The layout repeats exactly these rows on a continuation
// page, and HTML puts exactly these in <thead> (a rowspan cannot reach out of
// its row group). -1 when the table has no header.
table_head_end :: proc(t: ^Table) -> int {
	if !t.header || len(t.rows) == 0 {
		return -1
	}
	end := 0
	for r := 0; r <= end && r < len(t.rows); r += 1 {
		for &cl in t.rows[r].cells {
			if !cl.covered {
				end = max(end, min(len(t.rows) - 1, r + cell_rspan(&cl) - 1))
			}
		}
	}
	return end
}

// table_apply_conts turns the "this cell continues a merge" flags that the
// .docx and .rtf readers collect into spans. Both formats describe a merge
// cell by cell rather than by extent: a continuation across (`\clmrg`, or the
// grid columns a `gridSpan` stands for) or down (`\clvmrg`, a bare
// `<w:vMerge/>`). Across is settled first — a cell continuing across belongs
// to its row's anchor, so it is not then read as continuing down — and
// `table_normalise` finishes the job.
table_apply_conts :: proc(t: ^Table, across, down: [][2]int) {
	nr, nc := len(t.rows), table_cols(t)
	if nr == 0 || nc == 0 {
		return
	}
	h := make([]bool, nr * nc, context.temp_allocator)
	v := make([]bool, nr * nc, context.temp_allocator)
	for q in across {
		if q[0] >= 0 && q[0] < nr && q[1] >= 0 && q[1] < nc {
			h[q[0] * nc + q[1]] = true
		}
	}
	for q in down {
		if q[0] >= 0 && q[0] < nr && q[1] >= 0 && q[1] < nc {
			v[q[0] * nc + q[1]] = true
		}
	}
	for r in 0 ..< nr {
		for c in 1 ..< nc {
			if !h[r * nc + c] {
				continue
			}
			ac := c - 1
			for ac > 0 && h[r * nc + ac] {
				ac -= 1
			}
			if a := table_cell(t, r, ac); a != nil {
				a.cspan = max(cell_cspan(a), c - ac + 1)
			}
		}
	}
	for r in 1 ..< nr {
		for c in 0 ..< nc {
			if !v[r * nc + c] || h[r * nc + c] {
				continue
			}
			ar := r - 1
			for ar > 0 && v[ar * nc + c] {
				ar -= 1
			}
			if a := table_cell(t, ar, c); a != nil {
				a.rspan = max(cell_rspan(a), r - ar + 1)
			}
		}
	}
	table_normalise(t)
}
