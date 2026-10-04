// The document: sparse cell storage, the dependency graph, and recalculation.
//
// Storage is a map keyed by address, so a nominally 16384 x 1048576 sheet
// costs only what is actually written into it.
//
// Recalculation is demand driven. An edit marks its transitive dependents
// dirty, and evaluating a dirty cell pulls its precedents through the same
// path, which visits cells in topological order without ever building the
// order explicitly. A cell already being visited when it is asked for again
// is, by definition, part of a cycle: that is where #CIRC! comes from.
package main

import "core:mem"
import "core:mem/virtual"
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
	deps:     [dynamic]Rect_I, // the rectangles this formula reads
	volatile: bool, // contains TODAY/NOW: recompute every pass
}

Watcher :: struct {
	rect: Rect_I,
	who:  Addr,
}

// How deep a chain of references may go before it is treated as runaway. A
// real sheet never approaches this; a pathological one would otherwise
// exhaust the stack, and a spreadsheet must never crash on a bad formula.
MAX_DEPTH :: 1500

Sheet :: struct {
	cells:       map[Addr]^Cell,
	col_w:       map[int]f32,
	row_h:       map[int]f32,
	max_row:     int, // the used bounds, -1 when the sheet is empty
	max_col:     int,

	// The reverse dependency index, rebuilt whenever a formula changes.
	// Single-cell precedents go in the map; ranges go in the watcher list,
	// because materialising one edge per cell of `A1:A10000` is how a
	// spreadsheet runs out of memory.
	rdep:        map[Addr][dynamic]Addr,
	watchers:    [dynamic]Watcher,
	graph_dirty: bool,
	seeds:       [dynamic]Addr,

	// Scratch memory for one recalculation pass. Intermediate strings from
	// CONCAT and friends land here and are released in one go.
	scratch:     virtual.Arena,
	heap:        mem.Allocator,
	depth:       int,
	evaluated:   int, // cells evaluated by the last pass, for the status bar
}

DEFAULT_COL_W :: f32(88)
DEFAULT_ROW_H :: f32(22)

sheet_init :: proc(sh: ^Sheet) {
	sh.heap = context.allocator
	sh.max_row = -1
	sh.max_col = -1
	sh.graph_dirty = true
	_ = virtual.arena_init_growing(&sh.scratch)
}

sheet_destroy :: proc(sh: ^Sheet) {
	sheet_clear(sh)
	delete(sh.cells)
	delete(sh.col_w)
	delete(sh.row_h)
	delete(sh.rdep)
	delete(sh.watchers)
	delete(sh.seeds)
	virtual.arena_destroy(&sh.scratch)
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
	for _, arr in sh.rdep {
		delete(arr)
	}
	clear(&sh.rdep)
	clear(&sh.watchers)
	clear(&sh.seeds)
	sh.max_row = -1
	sh.max_col = -1
	sh.graph_dirty = true
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

// set_input is the single door through which cell content changes. It parses,
// records the dependency rectangles, and seeds the next recalculation.
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
			ast_deps(root, &c.deps, MAX_ROWS - 1)
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

	sh.graph_dirty = true
	append(&sh.seeds, a)
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
	sh.graph_dirty = true
	append(&sh.seeds, a)
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
// The dependency graph
// ---------------------------------------------------------------------------

rebuild_graph :: proc(sh: ^Sheet) {
	context.allocator = sh.heap
	for _, arr in sh.rdep {
		delete(arr)
	}
	clear(&sh.rdep)
	clear(&sh.watchers)

	for addr, c in sh.cells {
		if c.ast == nil {
			continue
		}
		for d in c.deps {
			if d.r0 == d.r1 && d.c0 == d.c1 {
				key := Addr{d.r0, d.c0}
				if arr, found := &sh.rdep[key]; found {
					append(arr, addr)
				} else {
					a := make([dynamic]Addr, sh.heap)
					append(&a, addr)
					sh.rdep[key] = a
				}
			} else {
				append(&sh.watchers, Watcher{d, addr})
			}
		}
	}
	sh.graph_dirty = false
}

// mark_dirty walks forward over the dependency edges from the changed cells,
// so only what can possibly have changed is recomputed.
mark_dirty :: proc(sh: ^Sheet, seeds: []Addr) -> [dynamic]Addr {
	stack := make([dynamic]Addr, 0, len(seeds) + 16, context.temp_allocator)
	seen := make(map[Addr]bool, 64, context.temp_allocator)
	out := make([dynamic]Addr, 0, 32, context.temp_allocator)
	for s in seeds {
		append(&stack, s)
	}
	for len(stack) > 0 {
		a := pop(&stack)
		if a in seen {
			continue
		}
		seen[a] = true
		if c := cell_at(sh, a); c != nil && c.ast != nil {
			c.state = .Dirty
			append(&out, a)
		}
		if arr, ok := sh.rdep[a]; ok {
			for d in arr {
				if !(d in seen) {
					append(&stack, d)
				}
			}
		}
		for w in sh.watchers {
			if rect_contains(w.rect, a) && !(w.who in seen) {
				append(&stack, w.who)
			}
		}
	}
	return out
}

// recalc brings the sheet up to date. Call it after any batch of edits.
recalc :: proc(sh: ^Sheet) {
	if sh.graph_dirty {
		rebuild_graph(sh)
	}
	for addr, c in sh.cells {
		if c.volatile {
			append(&sh.seeds, addr)
		}
	}
	if len(sh.seeds) == 0 {
		sh.evaluated = 0
		return
	}
	work := mark_dirty(sh, sh.seeds[:])
	clear(&sh.seeds)

	virtual.arena_free_all(&sh.scratch)
	arena := virtual.arena_allocator(&sh.scratch)
	ctx := context
	ctx.allocator = arena
	ctx.temp_allocator = arena
	sh.depth = 0
	sh.evaluated = 0
	context = ctx
	for a in work {
		ensure_value(sh, a)
	}
}

// recalc_all recomputes every formula from scratch, which is what loading a
// document or importing a CSV needs.
recalc_all :: proc(sh: ^Sheet) {
	if sh.graph_dirty {
		rebuild_graph(sh)
	}
	work := make([dynamic]Addr, 0, len(sh.cells), context.temp_allocator)
	for addr, c in sh.cells {
		if c.ast != nil {
			c.state = .Dirty
			append(&work, addr)
		}
	}
	clear(&sh.seeds)
	virtual.arena_free_all(&sh.scratch)
	arena := virtual.arena_allocator(&sh.scratch)
	ctx := context
	ctx.allocator = arena
	ctx.temp_allocator = arena
	sh.depth = 0
	sh.evaluated = 0
	context = ctx
	for a in work {
		ensure_value(sh, a)
	}
}

// ensure_value is the heart of it: the cached value of a cell, computing it
// first if it is stale, and reporting a cycle if the cell is already on the
// evaluation stack.
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
	if sh.depth >= MAX_DEPTH {
		set_cell_value(sh, c, verr(.Circ))
		c.state = .Clean
		return c.val
	}

	c.state = .Visiting
	sh.depth += 1
	res := eval_ast(sh, c.ast, a)
	sh.depth -= 1
	v := res_scalar(sh, res)
	// A reference to an empty cell is zero when it is the whole answer:
	// `=Z99` shows 0, not nothing.
	if v.kind == .Empty {
		v = vnum(0)
	}
	set_cell_value(sh, c, v)
	c.state = .Clean
	sh.evaluated += 1
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
