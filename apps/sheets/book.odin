// The workbook: several sheets, one dependency graph, one recalculation.
//
// A single-sheet spreadsheet can keep its graph beside its cells. As soon as
// `Sheet2!A1` exists that stops working, because the edge it creates has one
// end on each sheet — so the graph, the dirty walk, the evaluation arena and
// the cycle detector all move up here, to the book, and a cell is identified
// by `Key{sheet, addr}` rather than by an address alone.
//
// That is the whole trick. Nothing else about recalculation changes: it is
// still demand driven, still visits precedents through `ensure_value`, and
// still finds a cycle for free because the cell it comes back to is already
// marked `.Visiting`. A cycle that crosses sheets is detected by exactly the
// same line of code as one that does not.
//
// A sheet name is resolved to an index on every graph rebuild rather than
// baked into the AST, so renaming, deleting and reordering sheets stay
// correct without rewriting a single formula tree.
package main

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// Key names one cell anywhere in the book.
Key :: struct {
	sheet: int,
	a:     Addr,
}

// Watcher is a range edge: one formula reads a rectangle on some sheet.
// Ranges are kept as rectangles rather than expanded, because materialising
// one edge per cell of `Sheet2!A1:A10000` is how a spreadsheet runs out of
// memory.
Watcher :: struct {
	sheet: int,
	rect:  Rect_I,
	who:   Key,
}

// Dep is one rectangle a formula reads, with the sheet it lives on resolved.
// `sheet < 0` means the name did not resolve: the formula is #REF!.
Dep :: struct {
	sheet: int,
	rect:  Rect_I,
}

// Name_Def is a named range. The sheet is kept by name, not by index, so a
// reorder cannot silently repoint it.
Name_Def :: struct {
	sheet: string, // owned; "" means the book's first sheet
	rect:  Rect_I,
	abs:   bool, // printed with dollar signs, as Excel writes them
}

MAX_SHEETS :: 256

Book :: struct {
	sheets:      [dynamic]^Sheet,
	active:      int,

	// Named ranges, keyed by the upper-cased name.
	names:       map[string]Name_Def,

	// The reverse dependency index, rebuilt whenever any formula changes.
	rdep:        map[Key][dynamic]Key,
	watchers:    [dynamic]Watcher,
	graph_dirty: bool,
	seeds:       [dynamic]Key,

	// Scratch memory for one recalculation pass. Intermediate strings from
	// CONCAT and friends land here and are released in one go.
	scratch:     virtual.Arena,
	heap:        mem.Allocator,
	depth:       int,
	evaluated:   int, // cells evaluated by the last pass, for the status bar
}

book_init :: proc(bk: ^Book) {
	bk.heap = context.allocator
	bk.graph_dirty = true
	_ = virtual.arena_init_growing(&bk.scratch)
}

// book_new is the application's entry point: a book with one empty sheet.
book_new :: proc() -> ^Book {
	bk := new(Book)
	book_init(bk)
	book_add_sheet(bk, "Sheet1")
	return bk
}

// book_attach puts an already-allocated Sheet into a book. `sheet_init` uses
// it to give a standalone sheet its own private book, which is what keeps the
// single-sheet API — and the whole existing test suite — working unchanged.
book_attach :: proc(bk: ^Book, sh: ^Sheet, name: string) {
	sh.book = bk
	sh.index = len(bk.sheets)
	if sh.name != "" {
		delete(sh.name, sh.heap)
	}
	sh.name = strings.clone(name, sh.heap)
	append(&bk.sheets, sh)
	bk.graph_dirty = true
}

// book_add_sheet appends a new sheet the book owns and will free.
book_add_sheet :: proc(bk: ^Book, name: string) -> ^Sheet {
	if len(bk.sheets) >= MAX_SHEETS {
		return nil
	}
	sh := new(Sheet, bk.heap)
	sh.heap = bk.heap
	sh.max_row = -1
	sh.max_col = -1
	sh.allocated = true
	book_attach(bk, sh, book_unique_name(bk, name))
	return sh
}

book_destroy :: proc(bk: ^Book) {
	for sh in bk.sheets {
		sheet_release(sh)
		if sh.allocated {
			free(sh, bk.heap)
		}
	}
	delete(bk.sheets)
	for _, nd in bk.names {
		delete(nd.sheet, bk.heap)
	}
	for k in bk.names {
		delete(k, bk.heap)
	}
	delete(bk.names)
	for _, arr in bk.rdep {
		delete(arr)
	}
	delete(bk.rdep)
	delete(bk.watchers)
	delete(bk.seeds)
	virtual.arena_destroy(&bk.scratch)
}

// ---------------------------------------------------------------------------
// Sheets by name
//
// Comparison is case-insensitive, which is what every spreadsheet does and
// what makes `=sheet2!A1` typed in lower case find Sheet2.
// ---------------------------------------------------------------------------

book_find :: proc(bk: ^Book, name: string) -> int {
	if bk == nil {
		return -1
	}
	for sh, i in bk.sheets {
		if strings.equal_fold(sh.name, name) {
			return i
		}
	}
	return -1
}

book_sheet :: proc(bk: ^Book, i: int) -> ^Sheet {
	if bk == nil || i < 0 || i >= len(bk.sheets) {
		return nil
	}
	return bk.sheets[i]
}

// resolve_sheet maps the sheet part of a reference to an index. An empty name
// means "the sheet the formula lives on", which is how an unqualified
// reference stays relative to its own sheet when it is copied elsewhere.
resolve_sheet :: proc(bk: ^Book, name: string, own: int) -> int {
	if name == "" {
		return own
	}
	return book_find(bk, name)
}

book_unique_name :: proc(bk: ^Book, want: string) -> string {
	base := strings.trim_space(want)
	if base == "" {
		base = "Sheet"
	}
	if book_find(bk, base) < 0 {
		return base
	}
	for n in 2 ..< 1000 {
		cand := tprint_name(base, n)
		if book_find(bk, cand) < 0 {
			return cand
		}
	}
	return base
}

@(private = "file")
tprint_name :: proc(base: string, n: int) -> string {
	return strings.concatenate({base, int_text(n)}, context.temp_allocator)
}

// book_rename_sheet renames a sheet and rewrites every formula in the book
// that named it. Excel does this, and it is the only behaviour that is not
// quietly destructive: a reference is to a sheet, not to a string.
book_rename_sheet :: proc(bk: ^Book, i: int, want: string) -> bool {
	sh := book_sheet(bk, i)
	if sh == nil {
		return false
	}
	clean := strings.trim_space(want)
	if clean == "" {
		return false
	}
	if strings.equal_fold(clean, sh.name) {
		// Only the spelling changed; no reference has to move.
		old := sh.name
		sh.name = strings.clone(clean, sh.heap)
		delete(old, sh.heap)
		return true
	}
	if book_find(bk, clean) >= 0 {
		return false
	}
	old := strings.clone(sh.name, context.temp_allocator)
	delete(sh.name, sh.heap)
	sh.name = strings.clone(clean, sh.heap)

	for s in bk.sheets {
		for _, c in s.cells {
			if c.ast == nil {
				continue
			}
			if !ast_rename_sheet(c.ast, old, clean) {
				continue
			}
			src := ast_source(c.ast, context.temp_allocator)
			delete(c.input, s.heap)
			c.input = strings.clone(src, s.heap)
			c.state = .Dirty
		}
	}
	for _, &nd in bk.names {
		if strings.equal_fold(nd.sheet, old) {
			delete(nd.sheet, bk.heap)
			nd.sheet = strings.clone(clean, bk.heap)
		}
	}
	bk.graph_dirty = true
	return true
}

// book_delete_sheet removes a sheet. References to it are left alone and
// simply stop resolving, which is exactly #REF! — the same answer Excel
// gives, and reached without rewriting a single tree.
book_delete_sheet :: proc(bk: ^Book, i: int) -> bool {
	if len(bk.sheets) <= 1 || i < 0 || i >= len(bk.sheets) {
		return false
	}
	sh := bk.sheets[i]
	ordered_remove(&bk.sheets, i)
	sheet_release(sh)
	if sh.allocated {
		free(sh, bk.heap)
	}
	for s, k in bk.sheets {
		s.index = k
	}
	bk.active = clamp(bk.active, 0, len(bk.sheets) - 1)
	bk.graph_dirty = true
	book_recalc_all(bk)
	return true
}

book_move_sheet :: proc(bk: ^Book, from, to: int) -> bool {
	if from < 0 || from >= len(bk.sheets) {
		return false
	}
	dst := clamp(to, 0, len(bk.sheets) - 1)
	if dst == from {
		return false
	}
	sh := bk.sheets[from]
	ordered_remove(&bk.sheets, from)
	inject_at(&bk.sheets, dst, sh)
	for s, k in bk.sheets {
		s.index = k
	}
	bk.graph_dirty = true
	return true
}

// ---------------------------------------------------------------------------
// Named ranges
// ---------------------------------------------------------------------------

name_is_valid :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 255 {
		return false
	}
	if !(is_alpha(s[0]) || s[0] == '_') {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !(is_alpha(c) || is_digit(c) || c == '_' || c == '.' || c >= 0x80) {
			return false
		}
	}
	// A name that reads as a cell reference would shadow it, which Excel
	// refuses for the same reason.
	if _, ok := ref_parse(s); ok {
		return false
	}
	return true
}

book_set_name :: proc(bk: ^Book, name: string, sheet: string, rect: Rect_I, abs := true) -> bool {
	if !name_is_valid(name) {
		return false
	}
	key := strings.to_upper(name, context.temp_allocator)
	book_drop_name(bk, key)
	bk.names[strings.clone(key, bk.heap)] = Name_Def {
		sheet = strings.clone(sheet, bk.heap),
		rect  = rect,
		abs   = abs,
	}
	bk.graph_dirty = true
	return true
}

book_drop_name :: proc(bk: ^Book, name: string) -> bool {
	key := strings.to_upper(name, context.temp_allocator)
	for k, nd in bk.names {
		if k == key {
			delete(nd.sheet, bk.heap)
			kk := k
			delete_key(&bk.names, k)
			delete(kk, bk.heap)
			bk.graph_dirty = true
			return true
		}
	}
	return false
}

book_get_name :: proc(bk: ^Book, name: string) -> (Name_Def, bool) {
	if bk == nil {
		return {}, false
	}
	key := strings.to_upper(name, context.temp_allocator)
	nd, ok := bk.names[key]
	return nd, ok
}

// name_target renders a named range the way the file format wants it:
// sheet-qualified and absolute, e.g. `Sheet1!$A$1:$B$4`.
name_target :: proc(bk: ^Book, nd: Name_Def) -> string {
	sname := nd.sheet
	if sname == "" && len(bk.sheets) > 0 {
		sname = bk.sheets[0].name
	}
	d := nd.abs ? "$" : ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, sheet_prefix(sname))
	strings.write_string(&b, d)
	strings.write_string(&b, col_name(nd.rect.c0))
	strings.write_string(&b, d)
	strings.write_string(&b, int_text(nd.rect.r0 + 1))
	if nd.rect.r0 != nd.rect.r1 || nd.rect.c0 != nd.rect.c1 {
		strings.write_byte(&b, ':')
		strings.write_string(&b, d)
		strings.write_string(&b, col_name(nd.rect.c1))
		strings.write_string(&b, d)
		strings.write_string(&b, int_text(nd.rect.r1 + 1))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The dependency graph
//
// It is rebuilt whole rather than patched. A sheet is small enough that
// walking every AST costs less than keeping an incremental index honest
// through renames, deletions and reorders — and it is the rebuild that
// resolves sheet names, so it is also where a rename takes effect.
// ---------------------------------------------------------------------------

book_rebuild_graph :: proc(bk: ^Book) {
	context.allocator = bk.heap
	for _, arr in bk.rdep {
		delete(arr)
	}
	clear(&bk.rdep)
	clear(&bk.watchers)

	for sh, si in bk.sheets {
		for addr, c in sh.cells {
			if c.ast == nil {
				continue
			}
			clear(&c.deps)
			ast_deps(c.ast, &c.deps, MAX_ROWS - 1, bk, si)
			who := Key{si, addr}
			for d in c.deps {
				if d.sheet < 0 {
					continue
				}
				if d.rect.r0 == d.rect.r1 && d.rect.c0 == d.rect.c1 {
					key := Key{d.sheet, {d.rect.r0, d.rect.c0}}
					if arr, found := &bk.rdep[key]; found {
						append(arr, who)
					} else {
						a := make([dynamic]Key, bk.heap)
						append(&a, who)
						bk.rdep[key] = a
					}
				} else {
					append(&bk.watchers, Watcher{d.sheet, d.rect, who})
				}
			}
		}
	}
	bk.graph_dirty = false
}

// book_mark_dirty walks forward over the dependency edges from the changed
// cells, so only what can possibly have changed is recomputed.
book_mark_dirty :: proc(bk: ^Book, seeds: []Key) -> [dynamic]Key {
	stack := make([dynamic]Key, 0, len(seeds) + 16, context.temp_allocator)
	seen := make(map[Key]bool, 64, context.temp_allocator)
	out := make([dynamic]Key, 0, 32, context.temp_allocator)
	for s in seeds {
		append(&stack, s)
	}
	for len(stack) > 0 {
		k := pop(&stack)
		if k in seen {
			continue
		}
		seen[k] = true
		if sh := book_sheet(bk, k.sheet); sh != nil {
			if c := cell_at(sh, k.a); c != nil && c.ast != nil {
				c.state = .Dirty
				append(&out, k)
			}
		}
		if arr, ok := bk.rdep[k]; ok {
			for d in arr {
				if !(d in seen) {
					append(&stack, d)
				}
			}
		}
		for w in bk.watchers {
			if w.sheet == k.sheet && rect_contains(w.rect, k.a) && !(w.who in seen) {
				append(&stack, w.who)
			}
		}
	}
	return out
}

@(private = "file")
book_begin_pass :: proc(bk: ^Book) {
	virtual.arena_free_all(&bk.scratch)
	bk.depth = 0
	bk.evaluated = 0
}

// book_recalc brings the book up to date. Call it after any batch of edits.
book_recalc :: proc(bk: ^Book) {
	if bk.graph_dirty {
		book_rebuild_graph(bk)
	}
	for sh, si in bk.sheets {
		for addr, c in sh.cells {
			if c.volatile {
				append(&bk.seeds, Key{si, addr})
			}
		}
	}
	if len(bk.seeds) == 0 {
		bk.evaluated = 0
		return
	}
	work := book_mark_dirty(bk, bk.seeds[:])
	clear(&bk.seeds)

	book_begin_pass(bk)
	arena := virtual.arena_allocator(&bk.scratch)
	ctx := context
	ctx.allocator = arena
	ctx.temp_allocator = arena
	context = ctx
	for k in work {
		if sh := book_sheet(bk, k.sheet); sh != nil {
			ensure_value(sh, k.a)
		}
	}
}

// book_recalc_all recomputes every formula in every sheet from scratch, which
// is what loading a document or importing a workbook needs.
book_recalc_all :: proc(bk: ^Book) {
	if bk.graph_dirty {
		book_rebuild_graph(bk)
	}
	work := make([dynamic]Key, 0, 64, context.temp_allocator)
	for sh, si in bk.sheets {
		for addr, c in sh.cells {
			if c.ast != nil {
				c.state = .Dirty
				append(&work, Key{si, addr})
			}
		}
	}
	clear(&bk.seeds)
	book_begin_pass(bk)
	arena := virtual.arena_allocator(&bk.scratch)
	ctx := context
	ctx.allocator = arena
	ctx.temp_allocator = arena
	context = ctx
	for k in work {
		if sh := book_sheet(bk, k.sheet); sh != nil {
			ensure_value(sh, k.a)
		}
	}
}

// The single-sheet spellings, kept because almost every call site has one
// sheet in hand and does not care that a book exists.
recalc :: proc(sh: ^Sheet) {
	book_recalc(sh.book)
}

recalc_all :: proc(sh: ^Sheet) {
	book_recalc_all(sh.book)
}
