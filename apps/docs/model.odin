// The document model.
//
// palmy draws text; it has no notion of a document. This file is that notion:
// a document is a list of paragraphs, a paragraph is a list of styled runs,
// and every edit is expressed as insert / delete / restyle over a (paragraph,
// byte offset) position.
//
// Two invariants hold after every mutation, enforced by `normalise`:
//
//   1. No paragraph contains an empty run, unless it is the paragraph's only
//      run (an empty paragraph still needs somewhere to keep its style).
//   2. No two adjacent runs share a style.
//
// Without (2) the model degrades into one run per character within a few
// seconds of typing, which is why every mutating procedure ends by calling
// `normalise` rather than leaving it to the caller.
package main

import "core:strings"
import "core:unicode/utf8"

// Char_Style is everything that can vary inside a paragraph. `size` of 0 and
// `color` of 0 mean "inherit from the paragraph style", so the zero value is a
// run that simply follows its paragraph — which is what most runs are.
Char_Style :: struct {
	bold:      bool,
	italic:    bool,
	underline: bool,
	mono:      bool,
	size:      f32, // 0 → the paragraph style's size
	color:     u32, // 0 → the default foreground; else 0xff000000 | rgb
}

Para_Kind :: enum u8 {
	Body,
	H1,
	H2,
	H3,
	Quote,
	Code,
	// Two kinds whose content is not the paragraph's own runs.
	//
	// A Table paragraph's content is `table`: a grid of cells, each of which
	// holds its own `[]Paragraph`. An Image paragraph's content is `img`. Both
	// still carry exactly one (empty) run, so every invariant above and every
	// procedure that walks runs keeps working unchanged — it simply finds
	// nothing to walk.
	Table,
	Image,
}

// text_kind reports whether a paragraph kind's content is its own runs. The
// style cycle, the find box and every exporter branch on it.
text_kind :: proc(k: Para_Kind) -> bool {
	return k != .Table && k != .Image
}

Align :: enum u8 {
	Left,
	Center,
	Right,
	Justify,
}

List_Kind :: enum u8 {
	None,
	Bullet,
	Numbered,
}

Run :: struct {
	style: Char_Style,
	text:  [dynamic]u8,
}

Paragraph :: struct {
	kind:         Para_Kind,
	align:        Align,
	list:         List_Kind,
	depth:        int,
	before:       f32, // extra space above, in px, on top of the style's own
	after:        f32,
	// A hard page break before this paragraph. It changes where the paragraph
	// lands, never how it wraps, so it stays out of the layout cache key.
	break_before: bool,
	runs:         [dynamic]Run,

	// Content for the two non-text kinds. Pointers rather than values, so a
	// Paragraph stays 16 bytes bigger rather than carrying a grid by value —
	// and so the type is not recursive through itself.
	table:        ^Table,
	img:          ^Doc_Image,
}

Doc :: struct {
	paras: [dynamic]Paragraph,
}

// Pos is a caret location: a paragraph and a byte offset into that paragraph's
// text, counting across runs. Offsets are always on a rune boundary.
// The field order matters: `off` stays second so every `pos(para, off)`
// literal in the program still means what it did before tables existed.
//
// `row`, `col` and `cpara` address a paragraph *inside* a table cell and are
// all zero for an ordinary paragraph, which is why the comparison below can
// consult them unconditionally.
Pos :: struct {
	para:  int,
	off:   int,
	row:   int,
	col:   int,
	cpara: int,
}

// pos_less is reading order. Inside a table that is row-major and then down
// the cell's own paragraphs, which is exactly the order a selection, a find
// and an export all want.
pos_less :: proc(a, b: Pos) -> bool {
	if a.para != b.para {return a.para < b.para}
	if a.row != b.row {return a.row < b.row}
	if a.col != b.col {return a.col < b.col}
	if a.cpara != b.cpara {return a.cpara < b.cpara}
	return a.off < b.off
}

// pos_same_block reports whether two positions address the same paragraph —
// the condition under which a range edit is a single splice rather than a
// walk across cells.
pos_same_block :: proc(a, b: Pos) -> bool {
	return a.para == b.para && a.row == b.row && a.col == b.col && a.cpara == b.cpara
}

// pos is the two-field constructor every call site used before tables existed:
// a top-level paragraph and a byte offset. Odin's positional struct literals
// must name every field, so the shorthand is a procedure rather than `Pos{a,b}`.
pos :: proc(para, off: int) -> Pos {
	return Pos{para = para, off = off}
}

pos_order :: proc(a, b: Pos) -> (lo, hi: Pos) {
	if pos_less(b, a) {
		return b, a
	}
	return a, b
}

// ---------------------------------------------------------------------------
// Byte helpers. Runs own their bytes in a dynamic array, so splicing is
// explicit.
// ---------------------------------------------------------------------------

bytes_insert :: proc(arr: ^[dynamic]u8, at: int, data: []u8) {
	if len(data) == 0 {
		return
	}
	n := len(arr^)
	k := clamp(at, 0, n)
	resize(arr, n + len(data))
	s := arr^[:]
	copy(s[k + len(data):], s[k:n])
	copy(s[k:], data)
}

// ---------------------------------------------------------------------------
// Construction and teardown
// ---------------------------------------------------------------------------

run_make :: proc(cs: Char_Style, text := "") -> Run {
	r := Run {
		style = cs,
		text  = make([dynamic]u8, 0, max(8, len(text))),
	}
	append(&r.text, ..transmute([]u8)text)
	return r
}

para_make :: proc(kind := Para_Kind.Body, text := "", cs := Char_Style{}) -> Paragraph {
	pa := Paragraph {
		kind = kind,
		runs = make([dynamic]Run, 0, 2),
	}
	append(&pa.runs, run_make(cs, text))
	return pa
}

para_destroy :: proc(pa: ^Paragraph) {
	for &r in pa.runs {
		delete(r.text)
	}
	delete(pa.runs)
	pa.runs = nil
	if pa.table != nil {
		table_destroy(pa.table)
		free(pa.table)
		pa.table = nil
	}
	if pa.img != nil {
		image_destroy(pa.img)
		free(pa.img)
		pa.img = nil
	}
}

doc_init :: proc(d: ^Doc) {
	d.paras = make([dynamic]Paragraph, 0, 8)
	append(&d.paras, para_make())
}

doc_destroy :: proc(d: ^Doc) {
	for &pa in d.paras {
		para_destroy(&pa)
	}
	delete(d.paras)
	d.paras = nil
}

para_clone :: proc(pa: ^Paragraph) -> Paragraph {
	out := pa^
	out.runs = make([dynamic]Run, 0, len(pa.runs))
	for &r in pa.runs {
		append(&out.runs, run_make(r.style, string(r.text[:])))
	}
	out.table = nil
	out.img = nil
	if pa.table != nil {
		out.table = new(Table)
		out.table^ = table_clone(pa.table)
	}
	if pa.img != nil {
		out.img = new(Doc_Image)
		out.img^ = image_clone(pa.img)
	}
	return out
}

doc_clone :: proc(d: ^Doc) -> Doc {
	out := Doc {
		paras = make([dynamic]Paragraph, 0, len(d.paras)),
	}
	for &pa in d.paras {
		append(&out.paras, para_clone(&pa))
	}
	return out
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

para_len :: proc(pa: ^Paragraph) -> int {
	n := 0
	for &r in pa.runs {
		n += len(r.text)
	}
	return n
}

// para_text concatenates a paragraph's runs. The result is a fresh string in
// `alloc`; layout keeps one copy of the whole document instead of calling this
// per frame.
para_text :: proc(pa: ^Paragraph, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	for &r in pa.runs {
		strings.write_bytes(&b, r.text[:])
	}
	return strings.to_string(b)
}

para_append_text :: proc(pa: ^Paragraph, dst: ^[dynamic]u8) {
	for &r in pa.runs {
		append(dst, ..r.text[:])
	}
}

// ---------------------------------------------------------------------------
// Scopes and blocks
// ---------------------------------------------------------------------------
//
// Once a table cell holds its own `[]Paragraph`, "the paragraph at `q`" is no
// longer `d.paras[q.para]`. Two notions replace it, and between them every
// edit in the program stays a single implementation rather than one for
// paragraphs and a second for cells:
//
//   * a **scope** is the `[dynamic]Paragraph` that owns the position, plus the
//     index within it. Splitting, merging and multi-paragraph deletion all
//     happen inside one scope.
//   * a **block** names one paragraph anywhere in the document, in reading
//     order. Find, replace, restyling, counting and every export walk blocks.

// in_cell reports whether `q` addresses a paragraph inside a table cell.
in_cell :: proc(d: ^Doc, q: Pos) -> bool {
	if q.para < 0 || q.para >= len(d.paras) {
		return false
	}
	pa := &d.paras[q.para]
	if pa.kind != .Table || pa.table == nil {
		return false
	}
	cl := table_cell(pa.table, q.row, q.col)
	return cl != nil && len(cl.paras) > 0
}

// pos_scope resolves a position to the paragraph array that owns it and the
// index within that array.
pos_scope :: proc(d: ^Doc, q: Pos) -> (arr: ^[dynamic]Paragraph, idx: int) {
	if len(d.paras) == 0 {
		return &d.paras, 0
	}
	pi := clamp(q.para, 0, len(d.paras) - 1)
	pa := &d.paras[pi]
	if pa.kind == .Table && pa.table != nil {
		if cl := table_cell(pa.table, q.row, q.col); cl != nil && len(cl.paras) > 0 {
			return &cl.paras, clamp(q.cpara, 0, len(cl.paras) - 1)
		}
	}
	return &d.paras, pi
}

// pos_para is the paragraph a position sits in — the one every byte-level
// operation works on.
pos_para :: proc(d: ^Doc, q: Pos) -> ^Paragraph {
	arr, i := pos_scope(d, q)
	if len(arr^) == 0 {
		return nil
	}
	return &arr[i]
}

// pos_text is that paragraph's bytes.
pos_text :: proc(d: ^Doc, q: Pos, alloc := context.temp_allocator) -> string {
	pa := pos_para(d, q)
	return pa == nil ? "" : para_text(pa, alloc)
}

pos_para_len :: proc(d: ^Doc, q: Pos) -> int {
	pa := pos_para(d, q)
	return pa == nil ? 0 : para_len(pa)
}

// pos_move_index returns `q` moved to index `i` within its own scope, which is
// what a split or a merge produces.
pos_move_index :: proc(d: ^Doc, q: Pos, i, off: int) -> Pos {
	out := q
	out.off = off
	if in_cell(d, q) {
		out.cpara = i
	} else {
		out.para = i
		out.row, out.col, out.cpara = 0, 0, 0
	}
	return out
}

// same_scope is the test that decides whether a range edit is one splice or a
// walk. Two top-level positions share a scope; two positions in one cell share
// a scope; anything else crosses a table boundary.
same_scope :: proc(d: ^Doc, a, b: Pos) -> bool {
	ac, bc := in_cell(d, a), in_cell(d, b)
	if ac != bc {
		return false
	}
	if !ac {
		return true
	}
	return a.para == b.para && a.row == b.row && a.col == b.col
}

// Blk names one editable paragraph, including inside a table cell.
Blk :: struct {
	para:  int,
	row:   int,
	col:   int,
	cpara: int,
}

blk_pos :: proc(b: Blk, off: int) -> Pos {
	return Pos{para = b.para, off = off, row = b.row, col = b.col, cpara = b.cpara}
}

blk_para :: proc(d: ^Doc, b: Blk) -> ^Paragraph {
	return pos_para(d, blk_pos(b, 0))
}

blk_len :: proc(d: ^Doc, b: Blk) -> int {
	pa := blk_para(d, b)
	return pa == nil ? 0 : para_len(pa)
}

// doc_blocks lists every paragraph in reading order: top-level paragraphs, and
// for a table paragraph the cells row-major with each cell's own paragraphs in
// order. A table paragraph itself is *not* listed — its runs are empty and
// carry nothing.
doc_blocks :: proc(d: ^Doc, alloc := context.temp_allocator) -> []Blk {
	out := make([dynamic]Blk, 0, len(d.paras) + 16, alloc)
	for pi in 0 ..< len(d.paras) {
		pa := &d.paras[pi]
		if pa.kind == .Table && pa.table != nil && len(pa.table.rows) > 0 {
			t := pa.table
			for r in 0 ..< len(t.rows) {
				for c in 0 ..< len(t.rows[r].cells) {
					cl := &t.rows[r].cells[c]
					if cl.covered {
						continue // hidden under a merge: nothing to read or edit
					}
					for j in 0 ..< len(cl.paras) {
						append(&out, Blk{pi, r, c, j})
					}
				}
			}
			continue
		}
		append(&out, Blk{pi, 0, 0, 0})
	}
	return out[:]
}

// blocks_between keeps the blocks a range touches. A block is touched when the
// range overlaps it at all, which includes a zero-width overlap at an edge —
// that is what makes "bold this selection" reach the cell the caret is in.
blocks_between :: proc(d: ^Doc, lo, hi: Pos, alloc := context.temp_allocator) -> []Blk {
	all := doc_blocks(d, alloc)
	out := make([dynamic]Blk, 0, len(all), alloc)
	for b in all {
		n := blk_len(d, b)
		if pos_less(hi, blk_pos(b, 0)) || pos_less(blk_pos(b, n), lo) {
			continue
		}
		append(&out, b)
	}
	return out[:]
}

// blk_range clips a range to one block, giving the byte offsets inside it.
blk_range :: proc(d: ^Doc, b: Blk, lo, hi: Pos) -> (from, to: int) {
	n := blk_len(d, b)
	from = 0
	to = n
	if pos_same_block(lo, blk_pos(b, 0)) {
		from = clamp(lo.off, 0, n)
	}
	if pos_same_block(hi, blk_pos(b, 0)) {
		to = clamp(hi.off, 0, n)
	}
	return from, max(from, to)
}

doc_end :: proc(d: ^Doc) -> Pos {
	bs := doc_blocks(d, context.temp_allocator)
	if len(bs) == 0 {
		return {}
	}
	b := bs[len(bs) - 1]
	return blk_pos(b, blk_len(d, b))
}

pos_clamp :: proc(d: ^Doc, q: Pos) -> Pos {
	out := q
	if len(d.paras) == 0 {
		return {}
	}
	out.para = clamp(out.para, 0, len(d.paras) - 1)
	pa := &d.paras[out.para]
	if pa.kind == .Table && pa.table != nil && len(pa.table.rows) > 0 {
		t := pa.table
		out.row = clamp(out.row, 0, len(t.rows) - 1)
		cells := len(t.rows[out.row].cells)
		out.col = clamp(out.col, 0, max(0, cells - 1))
		// A cell hidden under a merge is not a place: the anchor is.
		if ar, ac := table_anchor(t, out.row, out.col); ar != out.row || ac != out.col {
			out.row, out.col, out.cpara, out.off = ar, ac, 0, 0
		}
		if cl := table_cell(t, out.row, out.col); cl != nil && len(cl.paras) > 0 {
			out.cpara = clamp(out.cpara, 0, len(cl.paras) - 1)
		} else {
			out.cpara = 0
		}
	} else {
		out.row, out.col, out.cpara = 0, 0, 0
	}
	target := pos_para(d, out)
	if target == nil {
		out.off = 0
		return out
	}
	out.off = clamp(out.off, 0, para_len(target))
	// Never leave an offset inside a UTF-8 sequence.
	t := para_text(target, context.temp_allocator)
	for out.off > 0 && out.off < len(t) && t[out.off] & 0xc0 == 0x80 {
		out.off -= 1
	}
	return out
}

// locate maps a paragraph offset to a run and an offset inside it. An offset
// that lands exactly on a run boundary belongs to the run on its *left*, so a
// caret parked after a bold word keeps bolding as you type — the behaviour
// every word processor has.
locate :: proc(pa: ^Paragraph, off: int) -> (ri: int, within: int) {
	o := clamp(off, 0, para_len(pa))
	for i in 0 ..< len(pa.runs) {
		l := len(pa.runs[i].text)
		if o <= l && (l > 0 || i == len(pa.runs) - 1) {
			return i, o
		}
		o -= l
	}
	n := len(pa.runs) - 1
	return n, len(pa.runs[n].text)
}

// style_after is the style of the character *at* a position rather than the
// one before it. A replacement should inherit the style of what it replaces,
// which is the run starting at the match, not the run leading up to it.
style_after :: proc(d: ^Doc, q: Pos) -> Char_Style {
	pa := pos_para(d, q)
	if pa == nil || len(pa.runs) == 0 {
		return {}
	}
	acc := 0
	for &r in pa.runs {
		l := len(r.text)
		if q.off < acc + l {
			return r.style
		}
		acc += l
	}
	return pa.runs[len(pa.runs) - 1].style
}

style_at :: proc(d: ^Doc, q: Pos) -> Char_Style {
	pa := pos_para(d, q)
	if pa == nil || len(pa.runs) == 0 {
		return {}
	}
	ri, _ := locate(pa, q.off)
	return pa.runs[ri].style
}

// ---------------------------------------------------------------------------
// Normalisation — the two invariants
// ---------------------------------------------------------------------------

normalise :: proc(pa: ^Paragraph) {
	if len(pa.runs) == 0 {
		append(&pa.runs, run_make({}))
		return
	}

	// Empty runs go first: they would otherwise sit between two runs of the
	// same style and stop them coalescing.
	for i := 0; i < len(pa.runs); {
		if len(pa.runs[i].text) == 0 && len(pa.runs) > 1 {
			delete(pa.runs[i].text)
			ordered_remove(&pa.runs, i)
			continue
		}
		i += 1
	}

	for i := 0; i + 1 < len(pa.runs); {
		if pa.runs[i].style == pa.runs[i + 1].style {
			append(&pa.runs[i].text, ..pa.runs[i + 1].text[:])
			delete(pa.runs[i + 1].text)
			ordered_remove(&pa.runs, i + 1)
			continue
		}
		i += 1
	}
}

// split_at guarantees a run boundary at `off` and returns the index of the run
// that begins there — len(runs) when `off` is the end of the paragraph.
split_at :: proc(pa: ^Paragraph, off: int) -> int {
	o := clamp(off, 0, para_len(pa))
	acc := 0
	for i in 0 ..< len(pa.runs) {
		l := len(pa.runs[i].text)
		if o == acc {
			return i
		}
		if o < acc + l {
			k := o - acc
			tail := run_make(pa.runs[i].style, string(pa.runs[i].text[k:]))
			resize(&pa.runs[i].text, k)
			inject_at(&pa.runs, i + 1, tail)
			return i + 1
		}
		acc += l
	}
	return len(pa.runs)
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

// insert_text inserts `s` at `at` with style `cs`, handling embedded newlines
// as paragraph breaks — which is what a paste of several lines is.
insert_text :: proc(d: ^Doc, at: Pos, raw: string, cs: Char_Style) -> Pos {
	// Tabs never enter the model: there are no tab stops, and palmy would draw
	// U+0009 as a missing glyph.
	s := detab(raw)
	q := at
	start := 0
	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == '\n' {
			if i > start {
				q = insert_plain(d, q, s[start:i], cs)
			}
			if i < len(s) {
				q = break_para(d, q)
			}
			start = i + 1
		}
	}
	return q
}

insert_plain :: proc(d: ^Doc, at: Pos, s: string, cs: Char_Style) -> Pos {
	if len(s) == 0 {
		return at
	}
	pa := pos_para(d, at)
	if pa == nil || !text_kind(pa.kind) {
		return at
	}
	ri, within := locate(pa, at.off)
	if pa.runs[ri].style == cs {
		// The common case by far: the character joins the run it lands in.
		bytes_insert(&pa.runs[ri].text, within, transmute([]u8)s)
	} else {
		// A different style splits the run in two and goes between them.
		k := split_at(pa, at.off)
		nr := run_make(cs, s)
		if k >= len(pa.runs) {
			append(&pa.runs, nr)
		} else {
			inject_at(&pa.runs, k, nr)
		}
	}
	normalise(pa)
	out := at
	out.off = at.off + len(s)
	return out
}

// break_para splits a paragraph in two at `at`. Pressing Return at the end of
// a heading starts body text, the way Word does; splitting a heading in the
// middle leaves two headings.
break_para :: proc(d: ^Doc, at: Pos) -> Pos {
	arr, idx := pos_scope(d, at)
	if len(arr^) == 0 {
		return at
	}
	pa := &arr[idx]
	// A Return against a table or an image does not split it: it opens a fresh
	// body paragraph after it, which is the only way to get a caret back out of
	// a block that has no text of its own.
	if !text_kind(pa.kind) {
		inject_at(arr, idx + 1, para_make())
		return pos_move_index(d, at, idx + 1, 0)
	}
	at_end := at.off >= para_len(pa)
	carry := style_at(d, at)

	k := split_at(pa, at.off)
	np := Paragraph {
		kind   = pa.kind,
		align  = pa.align,
		list   = pa.list,
		depth  = pa.depth,
		before = pa.before,
		after  = pa.after,
		runs   = make([dynamic]Run, 0, max(1, len(pa.runs) - k)),
	}
	for i in k ..< len(pa.runs) {
		append(&np.runs, pa.runs[i])
	}
	resize(&pa.runs, k)
	if len(pa.runs) == 0 {
		append(&pa.runs, run_make(carry))
	}
	if len(np.runs) == 0 {
		append(&np.runs, run_make(carry))
	}
	if at_end && (pa.kind == .H1 || pa.kind == .H2 || pa.kind == .H3) {
		np.kind = .Body
	}
	normalise(pa)
	normalise(&np)

	inject_at(arr, idx + 1, np)
	return pos_move_index(d, at, idx + 1, 0)
}

// merge_para joins paragraph i+1 onto paragraph i, which is what Backspace at
// the start of a paragraph does. The surviving paragraph keeps i's properties.
merge_para :: proc(d: ^Doc, scope: Pos, i: int) -> Pos {
	arr, _ := pos_scope(d, scope)
	if i < 0 || i + 1 >= len(arr^) {
		return pos_move_index(d, scope, max(0, i), 0)
	}
	// A table or an image cannot absorb a paragraph, and a paragraph cannot
	// absorb one: Backspace at the head of the paragraph after a block deletes
	// the block instead, which is what every word processor does.
	if !text_kind(arr[i].kind) || !text_kind(arr[i + 1].kind) {
		if !text_kind(arr[i].kind) {
			para_destroy(&arr[i])
			ordered_remove(arr, i)
			if len(arr^) == 0 {
				append(arr, para_make())
			}
			return pos_move_index(d, scope, clamp(i, 0, len(arr^) - 1), 0)
		}
		para_destroy(&arr[i + 1])
		ordered_remove(arr, i + 1)
		if len(arr^) == 0 {
			append(arr, para_make())
		}
		k := clamp(i, 0, len(arr^) - 1)
		return pos_move_index(d, scope, k, para_len(&arr[k]))
	}

	join := para_len(&arr[i])
	tail := arr[i + 1].runs
	arr[i + 1].runs = nil
	para_destroy(&arr[i + 1])
	ordered_remove(arr, i + 1)

	pa := &arr[i]
	for r in tail {
		append(&pa.runs, r)
	}
	delete(tail)
	normalise(pa)
	return pos_move_index(d, scope, i, join)
}

// delete_range removes everything between two positions, across any number of
// run and paragraph boundaries, and leaves the seam normalised.
delete_range :: proc(d: ^Doc, a, b: Pos) -> Pos {
	lo, hi := pos_order(a, b)
	if !pos_less(lo, hi) {
		return lo
	}

	// --- one paragraph: a plain splice.
	if pos_same_block(lo, hi) {
		pa := pos_para(d, lo)
		if pa == nil || !text_kind(pa.kind) {
			return lo
		}
		i0 := split_at(pa, lo.off)
		i1 := split_at(pa, hi.off)
		for i in i0 ..< i1 {
			delete(pa.runs[i].text)
		}
		remove_range(&pa.runs, i0, i1)
		normalise(pa)
		return lo
	}

	// --- a range that crosses into or out of a table clears each paragraph it
	// touches and leaves the structure alone. Merging a cell's text into the
	// body would have to delete the table to do it, which is never what
	// dragging a selection past the edge of a grid was asking for.
	if !same_scope(d, lo, hi) {
		for blk in blocks_between(d, lo, hi) {
			pa := blk_para(d, blk)
			if pa == nil || !text_kind(pa.kind) {
				continue
			}
			from, to := blk_range(d, blk, lo, hi)
			if to <= from {
				continue
			}
			i0 := split_at(pa, from)
			i1 := split_at(pa, to)
			for i in i0 ..< i1 {
				delete(pa.runs[i].text)
			}
			remove_range(&pa.runs, i0, i1)
			normalise(pa)
		}
		return lo
	}

	// --- several paragraphs of one scope. Trim the tail of the first and the
	// head of the last, drop the paragraphs in between, then graft what is left
	// of the last onto the first. The first paragraph's properties survive.
	arr, i_lo := pos_scope(d, lo)
	_, i_hi := pos_scope(d, hi)
	if i_hi <= i_lo {
		return lo
	}
	first_text := text_kind(arr[i_lo].kind)
	if first_text {
		pa := &arr[i_lo]
		i0 := split_at(pa, lo.off)
		for i in i0 ..< len(pa.runs) {
			delete(pa.runs[i].text)
		}
		resize(&pa.runs, i0)
	}
	tail: [dynamic]Run
	if text_kind(arr[i_hi].kind) {
		pb := &arr[i_hi]
		i1 := split_at(pb, hi.off)
		for i in 0 ..< i1 {
			delete(pb.runs[i].text)
		}
		remove_range(&pb.runs, 0, i1)
		tail = pb.runs
		pb.runs = nil
	}
	for i in i_lo + 1 ..= i_hi {
		para_destroy(&arr[i])
	}
	remove_range(arr, i_lo + 1, i_hi + 1)

	pa := &arr[i_lo]
	if first_text {
		for r in tail {
			append(&pa.runs, r)
		}
		delete(tail)
		normalise(pa)
		return lo
	}
	// The first paragraph was a table or an image: it is gone with the rest,
	// and whatever survived of the last paragraph becomes a body paragraph in
	// its place.
	para_destroy(pa)
	np := Paragraph {
		runs = tail != nil ? tail : make([dynamic]Run, 0, 1),
	}
	if len(np.runs) == 0 {
		append(&np.runs, run_make({}))
	}
	normalise(&np)
	arr[i_lo] = np
	return pos_move_index(d, lo, i_lo, 0)
}

// ---------------------------------------------------------------------------
// Character formatting over a range
// ---------------------------------------------------------------------------

Style_Field :: enum u8 {
	Bold,
	Italic,
	Underline,
	Mono,
	Size,
	Color,
}

// Style_Patch is a partial assignment: only the fields named in `fields` are
// copied out of `cs`. That is what "bold the selection" needs — it must not
// also reset everyone's colour.
Style_Patch :: struct {
	fields: bit_set[Style_Field],
	cs:     Char_Style,
}

patch_apply :: proc(dst: ^Char_Style, patch: Style_Patch) {
	if .Bold in patch.fields {dst.bold = patch.cs.bold}
	if .Italic in patch.fields {dst.italic = patch.cs.italic}
	if .Underline in patch.fields {dst.underline = patch.cs.underline}
	if .Mono in patch.fields {dst.mono = patch.cs.mono}
	if .Size in patch.fields {dst.size = patch.cs.size}
	if .Color in patch.fields {dst.color = patch.cs.color}
}

// apply_patch restyles [a, b). Runs are split at both ends so the patch lands
// exactly on the selection, then the paragraph is coalesced again.
apply_patch :: proc(d: ^Doc, a, b: Pos, patch: Style_Patch) {
	lo, hi := pos_order(a, b)
	if !pos_less(lo, hi) {
		return
	}
	for blk in blocks_between(d, lo, hi) {
		pa := blk_para(d, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		from, to := blk_range(d, blk, lo, hi)
		if to <= from {
			continue
		}
		// Split the low end first: splitting the high end can only insert a
		// run at or after i0, so i0 stays valid.
		i0 := split_at(pa, from)
		i1 := split_at(pa, to)
		for i in i0 ..< i1 {
			patch_apply(&pa.runs[i].style, patch)
		}
		normalise(pa)
	}
}

// range_uniform reports whether every run touched by [a, b) agrees on a field,
// which is how the toolbar decides whether "bold" is on for a selection.
range_all_bold :: proc(d: ^Doc, a, b: Pos) -> bool {
	lo, hi := pos_order(a, b)
	if !pos_less(lo, hi) {
		return style_at(d, lo).bold
	}
	any := false
	for blk in blocks_between(d, lo, hi) {
		pa := blk_para(d, blk)
		if pa == nil || !text_kind(pa.kind) {
			continue
		}
		from, to := blk_range(d, blk, lo, hi)
		acc := 0
		for &r in pa.runs {
			l := len(r.text)
			if acc < to && acc + l > from && l > 0 {
				any = true
				if !r.style.bold {
					return false
				}
			}
			acc += l
		}
	}
	return any
}

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

rune_before :: proc(s: string, i: int) -> int {
	k := clamp(i, 0, len(s))
	if k == 0 {
		return 0
	}
	k -= 1
	for k > 0 && s[k] & 0xc0 == 0x80 {
		k -= 1
	}
	return k
}

rune_after :: proc(s: string, i: int) -> int {
	k := clamp(i, 0, len(s))
	if k >= len(s) {
		return len(s)
	}
	_, n := utf8.decode_rune_in_string(s[k:])
	return k + max(1, n)
}

is_word_byte :: proc(b: u8) -> bool {
	return b >= 0x80 || b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// word_bounds returns the word surrounding `off`, which double-click and the
// "select word" command both want.
word_bounds :: proc(s: string, off: int) -> (lo, hi: int) {
	if len(s) == 0 {
		return 0, 0
	}
	i := clamp(off, 0, len(s))
	if i == len(s) || !is_word_byte(s[i]) {
		if i > 0 && is_word_byte(s[i - 1]) {
			i -= 1
		} else {
			return i, i
		}
	}
	lo = i
	for lo > 0 && is_word_byte(s[lo - 1]) {
		lo -= 1
	}
	hi = i
	for hi < len(s) && is_word_byte(s[hi]) {
		hi += 1
	}
	return lo, hi
}

// ---------------------------------------------------------------------------
// Counts, for the status bar
// ---------------------------------------------------------------------------

doc_counts :: proc(d: ^Doc) -> (words, chars: int) {
	in_word := false
	for blk in doc_blocks(d) {
		pa := blk_para(d, blk)
		if pa == nil {
			continue
		}
		for &r in pa.runs {
			for b in r.text {
				chars += 1 if b & 0xc0 != 0x80 else 0
				w := b > 0x20
				if w && !in_word {
					words += 1
				}
				in_word = w
			}
		}
		in_word = false
	}
	return
}
