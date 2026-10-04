// The reflowable document: what an EPUB or a MOBI becomes once it has been
// parsed, and the only thing the reflow engine knows about.
//
// A book is long — a novel is twenty to a hundred thousand words across thirty
// chapters — so the model is flat and shared. Every block's bytes live in one
// arena and a block holds an offset into it, which means loading a book is a
// handful of allocations rather than one per paragraph, and a search over the
// whole book is a scan of one contiguous buffer.
//
// Slices into `text` and `segs` are taken at the point of use, never stored,
// because both are `[dynamic]` and a growing arena moves.
package main

import "core:strings"

Block_Kind :: enum u8 {
	Para,
	H1,
	H2,
	H3,
	H4,
	Quote,
	Code,
	Item,
	Image,
	Rule,
}

List_Kind :: enum u8 {
	None,
	Bullet,
	Numbered,
}

Align :: enum u8 {
	Left,
	Center,
	Right,
	Justify,
}

// Char_Style is one stretch of text's appearance. `scale` multiplies the
// block's own type size, which is how an EPUB's `font-size: 0.9em` and a
// `<small>` both land in the same place.
Char_Style :: struct {
	bold:      bool,
	italic:    bool,
	mono:      bool,
	underline: bool,
	strike:    bool,
	sup:       bool,
	sub:       bool,
	scale:     f32, // 0 means 1
	link:      i32, // index into Doc.links, -1 for none
}

Seg :: struct {
	start, end: int, // block-relative byte range
	st:         Char_Style,
}

Block :: struct {
	kind:    Block_Kind,
	list:    List_Kind,
	depth:   u8,
	align:   Align,
	chapter: i32,
	at, n:   i32, // range into Doc.text
	si, sn:  i32, // range into Doc.segs
	image:   i32, // index into Doc.images, -1
	marker:  i32, // list ordinal; -1 bullet or none, filled by layout
	before:  f32, // extra space above, in ems of the block's own size
	after:   f32,
	scale:   f32, // block type size multiplier; 0 means the kind's default
	indent:  f32, // first-line indent in ems
	// Whether `indent` came from the book rather than from the reader's
	// paragraph style. It matters because the value an EPUB most often sets
	// is zero -- `p.first { text-indent: 0 }` on the paragraph after a
	// heading -- and a zero that means "none" has to outrank the reader's
	// default indent rather than being mistaken for "unset".
	indent_set: bool,
	brk:     bool, // force a page break before this block
}

Chapter :: struct {
	path:  string, // the spine item's archive path, for anchor resolution
	title: string,
	first: int, // first block index
	count: int,
	bytes: int, // text bytes, for the progress fraction
}

Toc_Entry :: struct {
	title: string,
	depth: int,
	href:  string, // as written in the NCX or nav, relative to its own file
	block: int, // resolved block index, -1 when the target is missing
}

Doc_Image :: struct {
	key:   string, // archive path, or "rec:NNN" for a MOBI record
	alt:   string,
	w, h:  int, // natural pixels, 0 until decoded
	tried: bool,
	ok:    bool,
}

Doc :: struct {
	text:     [dynamic]u8,
	segs:     [dynamic]Seg,
	blocks:   [dynamic]Block,
	chapters: [dynamic]Chapter,
	toc:      [dynamic]Toc_Entry,
	links:    [dynamic]string,
	images:   [dynamic]Doc_Image,
	// anchors maps "path#id" and bare "path" to a block index. Both forms are
	// needed: a TOC entry points at a file, an internal link at a fragment.
	anchors:  map[string]int,
	// pos_marks is MOBI's answer to anchors: {source byte offset, block}, in
	// increasing order, so a `filepos` link resolves by binary search. MOBI
	// has no named anchors at all — a link is a byte position in the
	// decompressed HTML — so this is the only way one can be followed.
	pos_marks: [dynamic][2]int,

	title:    string,
	author:   string,
	language: string,
	publisher: string,
	ident:    string,
	// Problems found while parsing, shown to the reader rather than hidden.
	// A book with a broken spine entry still opens; it just says so.
	notes:    [dynamic]string,
}

doc_destroy :: proc(d: ^Doc) {
	delete(d.text)
	delete(d.segs)
	delete(d.blocks)
	for c in d.chapters {
		delete(c.path)
		delete(c.title)
	}
	delete(d.chapters)
	for t in d.toc {
		delete(t.title)
		delete(t.href)
	}
	delete(d.toc)
	for l in d.links {
		delete(l)
	}
	delete(d.links)
	for im in d.images {
		delete(im.key)
		delete(im.alt)
	}
	delete(d.images)
	for k in d.anchors {
		delete(k)
	}
	delete(d.anchors)
	delete(d.pos_marks)
	delete(d.title)
	delete(d.author)
	delete(d.language)
	delete(d.publisher)
	delete(d.ident)
	for n in d.notes {
		delete(n)
	}
	delete(d.notes)
	d^ = {}
}

doc_note :: proc(d: ^Doc, s: string) {
	if len(d.notes) < 64 {
		append(&d.notes, strings.clone(s))
	}
}

block_text :: proc(d: ^Doc, bi: int) -> string {
	if bi < 0 || bi >= len(d.blocks) {
		return ""
	}
	b := d.blocks[bi]
	return string(d.text[b.at:b.at + b.n])
}

block_segs :: proc(d: ^Doc, bi: int) -> []Seg {
	if bi < 0 || bi >= len(d.blocks) {
		return nil
	}
	b := d.blocks[bi]
	return d.segs[b.si:b.si + b.sn]
}

doc_total_bytes :: proc(d: ^Doc) -> int {
	n := 0
	for c in d.chapters {
		n += c.bytes
	}
	return max(n, 1)
}

// doc_anchor resolves a link or TOC href against the file it was written in.
// Returns -1 when nothing in the book answers to it, which is common: books
// ship TOCs pointing at files their own manifest forgot.
doc_anchor :: proc(d: ^Doc, base_dir, href: string) -> int {
	if href == "" {
		return -1
	}
	// An href that is only a fragment names the current file.
	key := href
	if strings.has_prefix(href, "#") {
		return -1 // callers that have a base path use doc_anchor_in
	}
	path, frag := split_frag(key)
	full := path_resolve(base_dir, path, context.temp_allocator)
	if frag != "" {
		if bi, ok := d.anchors[strings.concatenate({full, "#", frag}, context.temp_allocator)]; ok {
			return bi
		}
	}
	if bi, ok := d.anchors[full]; ok {
		return bi
	}
	return -1
}

// doc_anchor_pos resolves a MOBI filepos: the last block whose source offset
// is at or before the position asked for.
doc_anchor_pos :: proc(d: ^Doc, off: int) -> int {
	if len(d.pos_marks) == 0 {
		return -1
	}
	lo, hi := 0, len(d.pos_marks) - 1
	best := -1
	for lo <= hi {
		mid := (lo + hi) / 2
		if d.pos_marks[mid][0] <= off {
			best = d.pos_marks[mid][1]
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return best
}

split_frag :: proc(href: string) -> (path, frag: string) {
	if i := strings.index_byte(href, '#'); i >= 0 {
		return href[:i], href[i + 1:]
	}
	return href, ""
}

// chapter_of_block is a binary search, because a search result jumping to a
// block needs its chapter and a long book has many.
chapter_of_block :: proc(d: ^Doc, bi: int) -> int {
	lo, hi := 0, len(d.chapters) - 1
	best := 0
	for lo <= hi {
		mid := (lo + hi) / 2
		if d.chapters[mid].first <= bi {
			best = mid
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return best
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

// Doc_Builder accumulates one block at a time. The HTML reader drives it; the
// MOBI reader drives the same one through the same HTML reader.
Doc_Builder :: struct {
	d:       ^Doc,
	buf:     [dynamic]u8, // the block under construction
	segs:    [dynamic]Seg,
	cur:     Block,
	open:    bool,
	chapter: i32,
	// Pending anchors: ids seen since the last flush, which belong to the
	// next block that is actually emitted.
	pending: [dynamic]string,
}

builder_init :: proc(b: ^Doc_Builder, d: ^Doc) {
	b^ = {}
	b.d = d
	b.buf = make([dynamic]u8, 0, 1024)
	b.segs = make([dynamic]Seg, 0, 16)
	b.pending = make([dynamic]string, 0, 4)
	b.cur.image = -1
}

builder_destroy :: proc(b: ^Doc_Builder) {
	delete(b.buf)
	delete(b.segs)
	for s in b.pending {
		delete(s)
	}
	delete(b.pending)
	b^ = {}
}

builder_begin :: proc(b: ^Doc_Builder, kind: Block_Kind) {
	builder_flush(b)
	b.cur = Block {
		kind    = kind,
		image   = -1,
		marker  = -1,
		chapter = b.chapter,
	}
	b.open = true
	clear(&b.buf)
	clear(&b.segs)
}

builder_text :: proc(b: ^Doc_Builder, s: string, st: Char_Style) {
	if !b.open || len(s) == 0 {
		return
	}
	at := len(b.buf)
	append(&b.buf, s)
	// Merge with the previous span when the style is identical, which it
	// usually is: a paragraph of plain prose should be one segment, not one
	// per text node the markup happened to split it into.
	if n := len(b.segs); n > 0 && b.segs[n - 1].st == st && b.segs[n - 1].end == at {
		b.segs[n - 1].end = len(b.buf)
		return
	}
	append(&b.segs, Seg{at, len(b.buf), st})
}

// builder_add_anchor records an id that the next emitted block answers to.
builder_add_anchor :: proc(b: ^Doc_Builder, key: string) {
	append(&b.pending, strings.clone(key))
}

builder_flush :: proc(b: ^Doc_Builder) {
	if !b.open {
		return
	}
	b.open = false
	d := b.d

	// Trim trailing whitespace: markup leaves it behind constantly and it
	// would otherwise widen the last line of every paragraph.
	for len(b.buf) > 0 && (b.buf[len(b.buf) - 1] == ' ' || b.buf[len(b.buf) - 1] == '\n' || b.buf[len(b.buf) - 1] == '\t') {
		pop(&b.buf)
	}
	for len(b.segs) > 0 {
		s := &b.segs[len(b.segs) - 1]
		s.end = min(s.end, len(b.buf))
		if s.end <= s.start {
			pop(&b.segs)
			continue
		}
		break
	}

	// An empty block is dropped, unless it carries something other than text:
	// a picture, a rule, or a page break the next block must inherit.
	if len(b.buf) == 0 && b.cur.kind != .Image && b.cur.kind != .Rule {
		if len(b.pending) > 0 {
			// Its ids still have to land somewhere, so hold them for the
			// next block rather than losing the link target.
			return
		}
		return
	}

	bi := len(d.blocks)
	nb := b.cur
	nb.at = i32(len(d.text))
	append(&d.text, ..b.buf[:])
	nb.n = i32(len(b.buf))
	nb.si = i32(len(d.segs))
	append(&d.segs, ..b.segs[:])
	nb.sn = i32(len(b.segs))
	append(&d.blocks, nb)

	for k in b.pending {
		if _, dup := d.anchors[k]; dup {
			delete(k)
			continue
		}
		d.anchors[k] = bi
	}
	clear(&b.pending)

	if int(nb.chapter) >= 0 && int(nb.chapter) < len(d.chapters) {
		d.chapters[nb.chapter].bytes += int(nb.n)
	}
}

// builder_pending_to applies any ids still waiting to a block index, which is
// how an id on an empty <div> ends up pointing at the paragraph after it.
builder_pending_to :: proc(b: ^Doc_Builder, bi: int) {
	for k in b.pending {
		if _, dup := b.d.anchors[k]; dup {
			delete(k)
			continue
		}
		b.d.anchors[k] = bi
	}
	clear(&b.pending)
}

doc_add_link :: proc(d: ^Doc, href: string) -> i32 {
	append(&d.links, strings.clone(href))
	return i32(len(d.links) - 1)
}

doc_add_image :: proc(d: ^Doc, key, alt: string) -> i32 {
	append(&d.images, Doc_Image{key = strings.clone(key), alt = strings.clone(alt)})
	return i32(len(d.images) - 1)
}
