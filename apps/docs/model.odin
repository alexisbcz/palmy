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
}

Doc :: struct {
	paras: [dynamic]Paragraph,
}

// Pos is a caret location: a paragraph and a byte offset into that paragraph's
// text, counting across runs. Offsets are always on a rune boundary.
Pos :: struct {
	para: int,
	off:  int,
}

pos_less :: proc(a, b: Pos) -> bool {
	return a.para < b.para || (a.para == b.para && a.off < b.off)
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

doc_end :: proc(d: ^Doc) -> Pos {
	n := len(d.paras) - 1
	return {n, para_len(&d.paras[n])}
}

pos_clamp :: proc(d: ^Doc, q: Pos) -> Pos {
	out := q
	out.para = clamp(out.para, 0, len(d.paras) - 1)
	out.off = clamp(out.off, 0, para_len(&d.paras[out.para]))
	// Never leave an offset inside a UTF-8 sequence.
	pa := &d.paras[out.para]
	t := para_text(pa, context.temp_allocator)
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
	if q.para < 0 || q.para >= len(d.paras) {
		return {}
	}
	pa := &d.paras[q.para]
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
	if q.para < 0 || q.para >= len(d.paras) {
		return {}
	}
	pa := &d.paras[q.para]
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
	pa := &d.paras[at.para]
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
	return Pos{at.para, at.off + len(s)}
}

// break_para splits a paragraph in two at `at`. Pressing Return at the end of
// a heading starts body text, the way Word does; splitting a heading in the
// middle leaves two headings.
break_para :: proc(d: ^Doc, at: Pos) -> Pos {
	pa := &d.paras[at.para]
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

	inject_at(&d.paras, at.para + 1, np)
	return Pos{at.para + 1, 0}
}

// merge_para joins paragraph i+1 onto paragraph i, which is what Backspace at
// the start of a paragraph does. The surviving paragraph keeps i's properties.
merge_para :: proc(d: ^Doc, i: int) -> Pos {
	if i < 0 || i + 1 >= len(d.paras) {
		return {i, 0}
	}
	join := para_len(&d.paras[i])
	tail := d.paras[i + 1].runs
	d.paras[i + 1].runs = nil
	ordered_remove(&d.paras, i + 1)

	pa := &d.paras[i]
	for r in tail {
		append(&pa.runs, r)
	}
	delete(tail)
	normalise(pa)
	return Pos{i, join}
}

// delete_range removes everything between two positions, across any number of
// run and paragraph boundaries, and leaves the seam normalised.
delete_range :: proc(d: ^Doc, a, b: Pos) -> Pos {
	lo, hi := pos_order(a, b)
	if !pos_less(lo, hi) {
		return lo
	}

	if lo.para == hi.para {
		pa := &d.paras[lo.para]
		i0 := split_at(pa, lo.off)
		i1 := split_at(pa, hi.off)
		for i in i0 ..< i1 {
			delete(pa.runs[i].text)
		}
		remove_range(&pa.runs, i0, i1)
		normalise(pa)
		return lo
	}

	// Trim the tail of the first paragraph and the head of the last, drop the
	// paragraphs in between, then graft what is left of the last onto the
	// first. The first paragraph's properties survive.
	{
		pa := &d.paras[lo.para]
		i0 := split_at(pa, lo.off)
		for i in i0 ..< len(pa.runs) {
			delete(pa.runs[i].text)
		}
		resize(&pa.runs, i0)
	}
	tail: [dynamic]Run
	{
		pb := &d.paras[hi.para]
		i1 := split_at(pb, hi.off)
		for i in 0 ..< i1 {
			delete(pb.runs[i].text)
		}
		remove_range(&pb.runs, 0, i1)
		tail = pb.runs
		pb.runs = nil
	}
	for i in lo.para + 1 ..= hi.para {
		para_destroy(&d.paras[i])
	}
	remove_range(&d.paras, lo.para + 1, hi.para + 1)

	pa := &d.paras[lo.para]
	for r in tail {
		append(&pa.runs, r)
	}
	delete(tail)
	normalise(pa)
	return lo
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
	for pi in lo.para ..= hi.para {
		pa := &d.paras[pi]
		n := para_len(pa)
		from := pi == lo.para ? lo.off : 0
		to := pi == hi.para ? hi.off : n
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
	for pi in lo.para ..= hi.para {
		pa := &d.paras[pi]
		n := para_len(pa)
		from := pi == lo.para ? lo.off : 0
		to := pi == hi.para ? hi.off : n
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
	for &pa in d.paras {
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
