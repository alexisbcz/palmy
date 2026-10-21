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
//
// A name has a *scope* as well as a target: the whole book (`Book.names`),
// or one sheet (`Sheet.names`). A formula looks in its own sheet's names
// first and the book's second, so a sheet-local `Rate` shadows a workbook
// `Rate` on that sheet and nowhere else — Excel's and LibreOffice's rule.
// Another sheet's local name is reached by qualifying it, `Q2!Rate`.
//
// A name can also be 3-D, `Jan:Mar!$B$2`: `sheet2` is then the far end of the
// span, which is resolved by position on every read exactly as a 3-D
// reference typed into a formula is (see eval.odin). Such a name is legal
// where a 3-D reference is — inside the aggregates — and #VALUE! elsewhere.
//
// And a name can be *broken*: `bad` is Excel's `=#REF!`. When every cell a
// name covered is deleted, or the sheet it pointed at is, the name stays —
// listed, saved, exported — and every formula that uses it reads #REF!,
// instead of the name vanishing and those formulas quietly turning into
// #NAME? (or worse, falling back to a workbook name of the same spelling).
Name_Def :: struct {
	sheet:  string, // owned; "" means the book's first sheet
	sheet2: string, // owned; the far end of a 3-D name, "" otherwise
	rect:   Rect_I,
	abs:    bool, // printed with dollar signs, as Excel writes them
	bad:    bool, // refers to #REF!: what it named is gone
}

// name_def_release frees what a definition owns.
name_def_release :: proc(nd: Name_Def, heap: mem.Allocator) {
	delete(nd.sheet, heap)
	if nd.sheet2 != "" {
		delete(nd.sheet2, heap)
	}
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
	names_clear(&bk.names, bk.heap)
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
	// A colon is what separates the two ends of `'Jan:Mar'!A1`, so a sheet
	// name may not hold one — Excel's rule too, and for the same reason.
	if strings.index_byte(clean, ':') >= 0 {
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
	// A local name's *scope* needs nothing — it lives on the sheet — but its
	// *target* is kept by name, on whichever sheet it was defined, and a 3-D
	// name has two of them.
	rename_targets :: proc(m: ^map[string]Name_Def, heap: mem.Allocator, old, clean: string) {
		for _, &nd in m {
			if strings.equal_fold(nd.sheet, old) {
				delete(nd.sheet, heap)
				nd.sheet = strings.clone(clean, heap)
			}
			if nd.sheet2 != "" && strings.equal_fold(nd.sheet2, old) {
				delete(nd.sheet2, heap)
				nd.sheet2 = strings.clone(clean, heap)
			}
		}
	}
	rename_targets(&bk.names, bk.heap, old, clean)
	for s in bk.sheets {
		rename_targets(&s.names, s.heap, old, clean)
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
	book_fix_spans_for_delete(bk, i)
	book_fix_names_for_delete(bk, i)
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

// book_move_sheet reorders the book. Order is meaningful now: a 3-D
// reference spans every sheet between its two ends *by position*, so a move
// can change what `SUM(Jan:Mar!B2)` adds up without touching a formula. The
// graph is rebuilt and every formula recomputed for that reason; a book is
// small enough that being right is cheaper than being clever.
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
	book_recalc_all(bk)
	return true
}

// book_insert_sheet adds a sheet at a position rather than at the end, which
// is how a sheet lands *inside* a 3-D span. It is `book_add_sheet` followed
// by `book_move_sheet`, so there is no second path that could disagree.
book_insert_sheet :: proc(bk: ^Book, name: string, at: int) -> ^Sheet {
	sh := book_add_sheet(bk, name)
	if sh == nil {
		return nil
	}
	if at >= 0 && at < len(bk.sheets) - 1 {
		book_move_sheet(bk, len(bk.sheets) - 1, at)
	} else {
		book_recalc_all(bk)
	}
	return sh
}

// book_fix_spans_for_delete narrows every 3-D reference that has the sheet
// about to be deleted as one of its ends, before it goes.
//
// This is the one sheet operation that has to rewrite formulas, and both
// Excel and LibreOffice do it: delete `Jan` from `SUM(Jan:Mar!B2)` and the
// formula becomes `SUM(Feb:Mar!B2)`, not #REF!. The new end is the next sheet
// inward. A span left with one sheet becomes an ordinary reference to it. A
// sheet deleted from the *middle* of a span needs nothing: the span is
// positional, so it simply stops being in it.
book_fix_spans_for_delete :: proc(bk: ^Book, gone: int) -> (rewritten: int) {
	for s, si in bk.sheets {
		if si == gone {
			continue
		}
		for _, c in s.cells {
			if c.ast == nil {
				continue
			}
			if !ast_fix_spans(c.ast, bk, gone) {
				continue
			}
			src := ast_source(c.ast, context.temp_allocator)
			delete(c.input, s.heap)
			c.input = strings.clone(src, s.heap)
			c.state = .Dirty
			rewritten += 1
		}
	}
	if rewritten > 0 {
		bk.graph_dirty = true
	}
	return
}

// book_fix_names_for_delete is the same rule for names: a 3-D name that ends
// on the sheet narrows to the next sheet inward, and a name on that sheet
// alone becomes `=#REF!` — Excel's answer — rather than going on naming a
// sheet that no longer exists (and that a later sheet of the same name would
// silently inherit). A sheet's own local names go with it.
book_fix_names_for_delete :: proc(bk: ^Book, gone: int) {
	fix :: proc(bk: ^Book, m: ^map[string]Name_Def, heap: mem.Allocator, gone: int) {
		for _, &nd in m {
			if nd.bad {
				continue
			}
			a := resolve_sheet(bk, nd.sheet, 0)
			if nd.sheet2 == "" {
				if nd.sheet != "" && a == gone {
					name_def_release(nd, heap)
					nd = Name_Def{abs = nd.abs, bad = true}
				}
				continue
			}
			b := book_find(bk, nd.sheet2)
			if a < 0 || b < 0 || (a != gone && b != gone) {
				continue
			}
			lo, hi := min(a, b), max(a, b)
			if lo == gone {
				lo += 1
			}
			if hi == gone {
				hi -= 1
			}
			name_def_release(nd, heap)
			nd.sheet = strings.clone(bk.sheets[lo].name, heap)
			nd.sheet2 = lo == hi ? "" : strings.clone(bk.sheets[hi].name, heap)
		}
	}
	fix(bk, &bk.names, bk.heap, gone)
	for s, si in bk.sheets {
		if si != gone {
			fix(bk, &s.names, s.heap, gone)
		}
	}
	bk.graph_dirty = true
}

@(private = "file")
ast_fix_spans :: proc(n: ^Ast, bk: ^Book, gone: int) -> bool {
	if n == nil {
		return false
	}
	hit := false
	if (n.kind == .Ref || n.kind == .Range) && n.sheet2 != "" {
		a := book_find(bk, n.sheet)
		b := book_find(bk, n.sheet2)
		if a >= 0 && b >= 0 && (a == gone || b == gone) {
			lo, hi := min(a, b), max(a, b)
			if lo == gone {
				lo += 1
			}
			if hi == gone {
				hi -= 1
			}
			delete(n.sheet)
			delete(n.sheet2)
			n.sheet = strings.clone(bk.sheets[lo].name)
			n.sheet2 = lo == hi ? "" : strings.clone(bk.sheets[hi].name)
			hit = true
		}
	}
	for k in n.kids {
		if ast_fix_spans(k, bk, gone) {
			hit = true
		}
	}
	return hit
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
	// refuses for the same reason — and so does one *shaped* like a cell
	// past the last column (`ZZZZ1`), or an R1C1 address, because either
	// would read differently in another program.
	if _, ok := ref_parse(s); ok {
		return false
	}
	if looks_like_cell(s) || looks_r1c1(s) {
		return false
	}
	return true
}

// looks_like_cell is the *shape* of an A1 address, `$AB$12`, whether or not
// the column exists.
looks_like_cell :: proc(s: string) -> bool {
	i := 0
	if i < len(s) && s[i] == '$' {
		i += 1
	}
	l := i
	for i < len(s) && is_alpha(s[i]) {
		i += 1
	}
	if i == l {
		return false
	}
	if i < len(s) && s[i] == '$' {
		i += 1
	}
	d := i
	for i < len(s) && is_digit(s[i]) {
		i += 1
	}
	return i > d && i == len(s)
}

names_clear :: proc(m: ^map[string]Name_Def, heap: mem.Allocator) {
	for k, nd in m {
		name_def_release(nd, heap)
		delete(k, heap)
	}
	clear(m)
}

// name_scope_map is where a name of this scope lives: the book's map for
// "", a sheet's own for a sheet name, nil when no such sheet exists.
@(private = "file")
name_scope_map :: proc(bk: ^Book, scope: string) -> (m: ^map[string]Name_Def, heap: mem.Allocator, ok: bool) {
	if scope == "" {
		return &bk.names, bk.heap, true
	}
	sh := book_sheet(bk, book_find(bk, scope))
	if sh == nil {
		return nil, {}, false
	}
	return &sh.names, sh.heap, true
}

// book_set_name defines (or redefines) a name. `scope` is "" for the whole
// book or a sheet's name for a name only that sheet sees.
book_set_name :: proc(
	bk: ^Book,
	name: string,
	sheet: string,
	rect: Rect_I,
	abs := true,
	scope := "",
	sheet2 := "",
	bad := false,
) -> bool {
	if !name_is_valid(name) {
		return false
	}
	m, heap, ok := name_scope_map(bk, scope)
	if !ok {
		return false
	}
	key := strings.to_upper(name, context.temp_allocator)
	book_drop_name(bk, key, scope)
	// A span whose two ends are one sheet is just that sheet.
	far := sheet2
	if far != "" && strings.equal_fold(far, sheet) {
		far = ""
	}
	m[strings.clone(key, heap)] = Name_Def {
		sheet  = strings.clone(bad ? "" : sheet, heap),
		sheet2 = far != "" && !bad ? strings.clone(far, heap) : "",
		rect   = bad ? {} : rect,
		abs    = abs,
		bad    = bad,
	}
	bk.graph_dirty = true
	return true
}

book_drop_name :: proc(bk: ^Book, name: string, scope := "") -> bool {
	m, heap, ok := name_scope_map(bk, scope)
	if !ok {
		return false
	}
	key := strings.to_upper(name, context.temp_allocator)
	for k, nd in m {
		if k == key {
			name_def_release(nd, heap)
			kk := k
			delete_key(m, k)
			delete(kk, heap)
			bk.graph_dirty = true
			return true
		}
	}
	return false
}

// book_get_name looks a name up in exactly one scope: the book's by default.
book_get_name :: proc(bk: ^Book, name: string, scope := "") -> (Name_Def, bool) {
	if bk == nil {
		return {}, false
	}
	m, _, ok := name_scope_map(bk, scope)
	if !ok {
		return {}, false
	}
	key := strings.to_upper(name, context.temp_allocator)
	nd, found := m[key]
	return nd, found
}

// book_resolve_name is what a formula on sheet `own` means by a bare name:
// its own sheet's, if it has one, and the book's otherwise. `local` says
// which won, for the status bar and the CLI.
book_resolve_name :: proc(bk: ^Book, name: string, own: int) -> (nd: Name_Def, local: bool, ok: bool) {
	if bk == nil {
		return {}, false, false
	}
	key := strings.to_upper(name, context.temp_allocator)
	if sh := book_sheet(bk, own); sh != nil {
		if d, found := sh.names[key]; found {
			return d, true, true
		}
	}
	d, found := bk.names[key]
	return d, false, found
}

// Name_Entry is one name with its scope, for everything that lists them:
// the file formats, the CLI, the collaboration document.
Name_Entry :: struct {
	scope: string, // "" for the book, else the sheet's name
	name:  string, // upper-cased, as stored
	def:   Name_Def,
}

// book_name_entries lists every name — the book's, then each sheet's in
// sheet order — each group sorted, so a saved file is stable.
book_name_entries :: proc(bk: ^Book) -> [dynamic]Name_Entry {
	out := make([dynamic]Name_Entry, 0, 8, context.temp_allocator)
	group :: proc(out: ^[dynamic]Name_Entry, m: map[string]Name_Def, scope: string) {
		keys := make([dynamic]string, 0, len(m), context.temp_allocator)
		for k in m {
			append(&keys, k)
		}
		sort_strings(keys[:])
		for k in keys {
			append(out, Name_Entry{scope, k, m[k]})
		}
	}
	group(&out, bk.names, "")
	for sh in bk.sheets {
		group(&out, sh.names, sh.name)
	}
	return out
}

// book_clear_names drops every name of every scope.
book_clear_names :: proc(bk: ^Book) {
	names_clear(&bk.names, bk.heap)
	for sh in bk.sheets {
		names_clear(&sh.names, sh.heap)
	}
	bk.graph_dirty = true
}

// name_spec reads how a person or a script writes a name with its scope:
// `Rate` for the book, `Q2!Rate` (or `'My Sheet'!Rate`) for one sheet. The
// window's prompts and the CLI both go through it.
name_spec :: proc(text: string) -> (scope, name: string) {
	t := strings.trim_space(text)
	if sc, rest, ok := split_sheet_ref(t); ok && sc != "" {
		return sc, strings.trim_space(rest)
	}
	return "", t
}

// name_drop_spec removes the name a spec means. Qualified (`Q2!Rate`) it is
// that sheet's; bare, it is whichever a formula on sheet `own` would see —
// the local one first — and with no sheet in hand (`own < 0`, the CLI) the
// book's. The window and `sheets name-delete` both come through here.
name_drop_spec :: proc(bk: ^Book, spec: string, own: int) -> (scope, name: string, ok: bool) {
	scope, name = name_spec(spec)
	if scope == "" && own >= 0 {
		if sh := book_sheet(bk, own); sh != nil {
			if _, found := book_get_name(bk, name, sh.name); found {
				scope = sh.name
			}
		}
	}
	if scope != "" {
		if i := book_find(bk, scope); i >= 0 {
			scope = bk.sheets[i].name // the sheet's own spelling
		}
	}
	return scope, name, book_drop_name(bk, name, scope)
}

// name_label is the inverse of `name_spec`, for display.
name_label :: proc(scope, name: string) -> string {
	return strings.concatenate({sheet_prefix(scope), name}, context.temp_allocator)
}

// name_target renders a named range the way the file format wants it:
// sheet-qualified and absolute, e.g. `Sheet1!$A$1:$B$4`.
// A broken name is `#REF!`, as Excel writes it, and a 3-D one carries its
// span: `Jan:Mar!$B$2`.
name_target :: proc(bk: ^Book, nd: Name_Def) -> string {
	if nd.bad {
		return "#REF!"
	}
	sname := nd.sheet
	if sname == "" && len(bk.sheets) > 0 {
		sname = bk.sheets[0].name
	}
	d := nd.abs ? "$" : ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, sheet_span_prefix(sname, nd.sheet2))
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
