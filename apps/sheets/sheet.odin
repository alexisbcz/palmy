// One sheet of the book: sparse cell storage, geometry, the frozen split, and
// the single door through which cell content changes.
//
// Storage is a map keyed by address, so a nominally 16384 x 1048576 sheet
// costs only what is actually written into it.
//
// The dependency graph and recalculation live one level up, in book.odin,
// because `Sheet2!A1` makes an edge with one end on each sheet. What stays
// here is `ensure_value`: the cached value of a cell, computed on demand, and
// the place a circular reference is noticed — a cell already marked
// `.Visiting` when it is asked for again is, by definition, part of a cycle.
package main

import "core:mem"
import "core:strings"

Calc_State :: enum u8 {
	Clean,
	Dirty,
	Visiting,
}

Cell :: struct {
	input:    string, // exactly what the user typed, owned
	ast:      ^Ast, // nil when the input is a literal
	val:      Value, // the computed value; .text is owned
	fmt:      Cell_Fmt,
	state:    Calc_State,
	deps:     [dynamic]Dep, // the rectangles this formula reads, sheet included
	volatile: bool, // contains TODAY/NOW: recompute every pass
}

// How deep a chain of references may go before it is treated as runaway. A
// real sheet never approaches this; a pathological one would otherwise
// exhaust the stack, and a spreadsheet must never crash on a bad formula.
MAX_DEPTH :: 1500

Sheet :: struct {
	name:      string, // owned
	book:      ^Book,
	index:     int, // this sheet's position in the book
	allocated: bool, // the book allocated this Sheet and must free it
	// A sheet created by `sheet_init` carries its own one-sheet book, so the
	// single-sheet API works with no ceremony. That book is freed with it.
	own_book:  bool,

	cells:     map[Addr]^Cell,
	col_w:     map[int]f32,
	row_h:     map[int]f32,
	max_row:   int, // the used bounds, -1 when the sheet is empty
	max_col:   int,

	// The frozen split: the first `frz_rows` rows and `frz_cols` columns stay
	// put while the rest scrolls under them.
	frz_rows:  int,
	frz_cols:  int,

	charts:    [dynamic]Chart,
	merges:    [dynamic]Rect_I,

	// Where the user last was on this sheet. Transient — it is not part of
	// the document — but it has to live per sheet or switching tabs would
	// leave the scroll position of the one you came from, which is wrong the
	// moment the two sheets have different frozen regions.
	ui_cur:    Addr,
	ui_anchor: Addr,
	ui_top:    int,
	ui_left:   int,

	heap:      mem.Allocator,
}

DEFAULT_COL_W :: f32(88)
DEFAULT_ROW_H :: f32(22)

// sheet_init prepares a standalone sheet and gives it a private book, which
// is what lets a caller with one sheet in hand ignore books entirely.
sheet_init :: proc(sh: ^Sheet, name := "Sheet1") {
	sh.heap = context.allocator
	sh.max_row = -1
	sh.max_col = -1
	if sh.book == nil {
		bk := new(Book, sh.heap)
		book_init(bk)
		sh.own_book = true
		book_attach(bk, sh, name)
	}
}

// sheet_release frees everything the sheet owns, leaving the book alone.
sheet_release :: proc(sh: ^Sheet) {
	sheet_clear(sh)
	delete(sh.cells)
	delete(sh.col_w)
	delete(sh.row_h)
	delete(sh.charts)
	delete(sh.merges)
	if sh.name != "" {
		delete(sh.name, sh.heap)
		sh.name = ""
	}
}

sheet_destroy :: proc(sh: ^Sheet) {
	bk := sh.book
	if sh.own_book && bk != nil {
		heap := sh.heap
		book_destroy(bk) // releases every sheet, this one included
		free(bk, heap)
		sh.book = nil
		return
	}
	sheet_release(sh)
}

cell_destroy :: proc(sh: ^Sheet, c: ^Cell) {
	context.allocator = sh.heap
	if c.input != "" {
		delete(c.input)
	}
	ast_free(c.ast)
	if c.val.kind == .Text && c.val.text != "" {
		delete(c.val.text)
	}
	delete(c.deps)
	free(c)
}

sheet_clear :: proc(sh: ^Sheet) {
	context.allocator = sh.heap
	for _, c in sh.cells {
		cell_destroy(sh, c)
	}
	clear(&sh.cells)
	clear(&sh.col_w)
	clear(&sh.row_h)
	for ch in sh.charts {
		chart_release(ch, sh.heap)
	}
	clear(&sh.charts)
	clear(&sh.merges)
	sh.frz_rows = 0
	sh.frz_cols = 0
	sh.max_row = -1
	sh.max_col = -1
	if sh.book != nil {
		sh.book.graph_dirty = true
	}
}

cell_at :: proc(sh: ^Sheet, a: Addr) -> ^Cell {
	c, ok := sh.cells[a]
	if !ok {
		return nil
	}
	return c
}

cell_ensure :: proc(sh: ^Sheet, a: Addr) -> ^Cell {
	if c, ok := sh.cells[a]; ok {
		return c
	}
	context.allocator = sh.heap
	c := new(Cell)
	sh.cells[a] = c
	sh.max_row = max(sh.max_row, a.row)
	sh.max_col = max(sh.max_col, a.col)
	return c
}

// seed marks a cell as changed for the next recalculation pass.
seed :: proc(sh: ^Sheet, a: Addr) {
	if sh.book == nil {
		return
	}
	append(&sh.book.seeds, Key{sh.index, a})
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

col_width :: proc(sh: ^Sheet, col: int) -> f32 {
	if w, ok := sh.col_w[col]; ok {
		return w
	}
	return DEFAULT_COL_W
}

row_height :: proc(sh: ^Sheet, row: int) -> f32 {
	if h, ok := sh.row_h[row]; ok {
		return h
	}
	return DEFAULT_ROW_H
}

set_col_width :: proc(sh: ^Sheet, col: int, w: f32) {
	sh.col_w[col] = clamp(w, 28, 520)
}

set_row_height :: proc(sh: ^Sheet, row: int, h: f32) {
	sh.row_h[row] = clamp(h, 14, 200)
}

// set_freeze pins the first `rows` rows and `cols` columns in place. Both are
// counts, not indices: `set_freeze(sh, 1, 0)` freezes row 1 only.
set_freeze :: proc(sh: ^Sheet, rows, cols: int) {
	sh.frz_rows = clamp(rows, 0, MAX_ROWS - 1)
	sh.frz_cols = clamp(cols, 0, MAX_COLS - 1)
}

// ---------------------------------------------------------------------------
// Merged cells
//
// A merge is a rectangle whose top-left cell owns the content; the rest are
// covered. Overlapping merges are not a thing, so adding one drops whatever
// it intersects.
// ---------------------------------------------------------------------------

rects_overlap :: proc(a, b: Rect_I) -> bool {
	return a.r0 <= b.r1 && b.r0 <= a.r1 && a.c0 <= b.c1 && b.c0 <= a.c1
}

add_merge :: proc(sh: ^Sheet, r: Rect_I) -> bool {
	if r.r0 == r.r1 && r.c0 == r.c1 {
		return false
	}
	for i := len(sh.merges) - 1; i >= 0; i -= 1 {
		if rects_overlap(sh.merges[i], r) {
			ordered_remove(&sh.merges, i)
		}
	}
	append(&sh.merges, r)
	return true
}

// drop_merge removes any merge covering `a`, and reports whether it did.
drop_merge :: proc(sh: ^Sheet, a: Addr) -> bool {
	for i := len(sh.merges) - 1; i >= 0; i -= 1 {
		if rect_contains(sh.merges[i], a) {
			ordered_remove(&sh.merges, i)
			return true
		}
	}
	return false
}

merge_at :: proc(sh: ^Sheet, a: Addr) -> (Rect_I, bool) {
	for m in sh.merges {
		if rect_contains(m, a) {
			return m, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Writing cells
// ---------------------------------------------------------------------------

set_cell_value :: proc(sh: ^Sheet, c: ^Cell, v: Value) {
	context.allocator = sh.heap
	if c.val.kind == .Text && c.val.text != "" {
		delete(c.val.text)
	}
	c.val = v
	if v.kind == .Text {
		c.val.text = strings.clone(v.text, sh.heap)
	}
}

// literal_value is the type inference a cell does on plain typed input: a
// leading apostrophe forces text, otherwise dates, percentages, currency,
// booleans, error literals and numbers are all recognised, and anything else
// is text.
literal_value :: proc(text: string) -> (v: Value, f: Cell_Fmt, formatted: bool) {
	t := strings.trim_space(text)
	if t == "" {
		return EMPTY, {}, false
	}
	if t[0] == '\'' {
		return vtext(text[1:]), {}, false
	}
	if strings.equal_fold(t, "TRUE") {
		return vbool(true), {}, false
	}
	if strings.equal_fold(t, "FALSE") {
		return vbool(false), {}, false
	}
	if e, ok := err_parse(t); ok {
		return verr(e), {}, false
	}
	if serial, ok := date_parse(t); ok {
		return vnum(serial), {num = .Date}, true
	}
	if x, ok := number_from_text(t); ok {
		if strings.has_suffix(t, "%") {
			return vnum(x), {num = .Percent, dec = u8(decimals_in(t[:len(t) - 1]))}, true
		}
		if strings.has_prefix(t, "$") || strings.has_prefix(t, "-$") {
			return vnum(x), {num = .Currency, dec = 2}, true
		}
		return vnum(x), {}, false
	}
	// Text keeps whatever spacing was typed; only numeric parsing trims.
	return vtext(text), {}, false
}

decimals_in :: proc(s: string) -> int {
	d := strings.index_byte(s, '.')
	if d < 0 {
		return 0
	}
	n := 0
	for i in d + 1 ..< len(s) {
		if is_digit(s[i]) {
			n += 1
		} else {
			break
		}
	}
	return min(n, 9)
}

// set_input is the single door through which cell content changes. It parses
// and seeds the next recalculation; the dependency rectangles are worked out
// by the graph rebuild, which is also where sheet names are resolved.
set_input :: proc(sh: ^Sheet, a: Addr, text: string) {
	if a.row < 0 || a.col < 0 || a.row >= MAX_ROWS || a.col >= MAX_COLS {
		return
	}
	trimmed := strings.trim_space(text)
	existing := cell_at(sh, a)
	if trimmed == "" && (existing == nil || fmt_is_default(existing.fmt)) {
		clear_cell(sh, a)
		return
	}

	c := cell_ensure(sh, a)
	context.allocator = sh.heap
	if c.input != "" {
		delete(c.input)
	}
	ast_free(c.ast)
	c.ast = nil
	clear(&c.deps)
	c.volatile = false
	c.input = strings.clone(text, sh.heap)

	if len(trimmed) > 1 && trimmed[0] == '=' {
		root, ok := parse_formula(trimmed[1:])
		if !ok {
			// A formula that does not parse is kept verbatim so the user can
			// repair it, and shows #VALUE! where its result would go.
			set_cell_value(sh, c, verr(.Value))
			c.state = .Clean
		} else {
			c.ast = root
			c.volatile = ast_has_volatile(root)
			c.state = .Dirty
		}
	} else {
		v, f, did := literal_value(text)
		set_cell_value(sh, c, v)
		if did && fmt_is_default(c.fmt) {
			c.fmt = f
		}
		c.state = .Clean
	}

	sh.book.graph_dirty = true
	seed(sh, a)
}

set_cell_fmt :: proc(sh: ^Sheet, a: Addr, f: Cell_Fmt) {
	// Formatting an empty cell that is going back to the default would only
	// create a cell with nothing in it.
	if fmt_is_default(f) && cell_at(sh, a) == nil {
		return
	}
	c := cell_ensure(sh, a)
	c.fmt = f
	if c.input == "" && c.val.kind == .Empty && fmt_is_default(f) {
		clear_cell(sh, a)
	}
}

clear_cell :: proc(sh: ^Sheet, a: Addr) {
	context.allocator = sh.heap
	c, ok := sh.cells[a]
	if !ok {
		return
	}
	delete_key(&sh.cells, a)
	cell_destroy(sh, c)
	sh.book.graph_dirty = true
	seed(sh, a)
	// Only a cell on the used boundary can shrink it, and rescanning is O(n),
	// so a bulk clear does not pay for it per cell.
	if a.row == sh.max_row || a.col == sh.max_col {
		refresh_bounds(sh)
	}
}

refresh_bounds :: proc(sh: ^Sheet) {
	sh.max_row = -1
	sh.max_col = -1
	for a in sh.cells {
		sh.max_row = max(sh.max_row, a.row)
		sh.max_col = max(sh.max_col, a.col)
	}
}

// ---------------------------------------------------------------------------
// Reading cells
// ---------------------------------------------------------------------------

// ensure_value is the heart of it: the cached value of a cell, computing it
// first if it is stale, and reporting a cycle if the cell is already on the
// evaluation stack. Nothing here knows which sheet it is on, which is why a
// cycle that crosses sheets is caught by the same three lines.
ensure_value :: proc(sh: ^Sheet, a: Addr) -> Value {
	c := cell_at(sh, a)
	if c == nil {
		return EMPTY
	}
	switch c.state {
	case .Clean:
		return c.val
	case .Visiting:
		// Already being computed further up the stack: a circular reference.
		return verr(.Circ)
	case .Dirty:
	}
	if c.ast == nil {
		c.state = .Clean
		return c.val
	}
	bk := sh.book
	if bk.depth >= MAX_DEPTH {
		set_cell_value(sh, c, verr(.Circ))
		c.state = .Clean
		return c.val
	}

	c.state = .Visiting
	bk.depth += 1
	res := eval_ast(sh, c.ast, a)
	bk.depth -= 1
	v := res_scalar(sh, res)
	// A reference to an empty cell is zero when it is the whole answer:
	// `=Z99` shows 0, not nothing.
	if v.kind == .Empty {
		v = vnum(0)
	}
	set_cell_value(sh, c, v)
	c.state = .Clean
	bk.evaluated += 1
	return c.val
}

// value_at reads a cell without recomputing: the UI always draws the last
// settled state.
value_at :: proc(sh: ^Sheet, a: Addr) -> Value {
	if c := cell_at(sh, a); c != nil {
		return c.val
	}
	return EMPTY
}

fmt_at :: proc(sh: ^Sheet, a: Addr) -> Cell_Fmt {
	if c := cell_at(sh, a); c != nil {
		return c.fmt
	}
	return {}
}

input_at :: proc(sh: ^Sheet, a: Addr) -> string {
	if c := cell_at(sh, a); c != nil {
		return c.input
	}
	return ""
}

display_at :: proc(sh: ^Sheet, a: Addr) -> string {
	c := cell_at(sh, a)
	if c == nil {
		return ""
	}
	return format_value(c.val, c.fmt)
}

// clamp_rect trims a rectangle to the cells that actually exist, so a whole
// column reference costs the same as the data in it.
clamp_rect :: proc(sh: ^Sheet, r: Rect_I) -> (out: Rect_I, any: bool) {
	out = r
	out.r1 = min(out.r1, sh.max_row)
	out.c1 = min(out.c1, sh.max_col)
	out.r0 = max(out.r0, 0)
	out.c0 = max(out.c0, 0)
	return out, out.r0 <= out.r1 && out.c0 <= out.c1
}
