// Layout: wrapping, pagination, and the two mappings a caret needs.
//
// The document is laid into fixed A4 pages. A paragraph becomes one or more
// visual lines; a line becomes a run of fragments, each a stretch of text with
// a single font, size and colour, measured with `p.text_width`. Everything the
// renderer and the caret need is in `Layout` — nothing is measured twice.
//
// Page: A4 at 96 dpi, 794 x 1123 px, with 1-inch (96 px) margins, giving a
// 602 x 931 px text area.
package main

import p "palmy:."

PAGE_W :: f32(794)
PAGE_H :: f32(1123)
MARGIN :: f32(96)
CONTENT_W :: PAGE_W - 2 * MARGIN
CONTENT_H :: PAGE_H - 2 * MARGIN

LIST_INDENT :: f32(28)
DEPTH_INDENT :: f32(26)

// layout_fonts is the font table every measurement goes through. palmy threads
// `^Fonts` explicitly, but the caret mappings are called from inside hit
// testing and drawing where passing it along adds nothing, so the app pins it
// once at startup.
layout_fonts: ^p.Fonts

// Kind_Metrics is a paragraph style: the type size and weight it sets, its
// leading, the space it reserves above and below, and how far it is indented.
Kind_Metrics :: struct {
	size:   f32,
	weight: p.Font_Weight,
	line:   f32, // multiple of size
	before: f32,
	after:  f32,
	indent: f32,
	mono:   bool,
	italic: bool,
}

kind_metrics :: proc(k: Para_Kind) -> Kind_Metrics {
	switch k {
	case .Body:
		return {size = 15, weight = .Regular, line = 1.56, after = 11}
	case .H1:
		return {size = 30, weight = .Bold, line = 1.22, before = 24, after = 10}
	case .H2:
		return {size = 23, weight = .Bold, line = 1.28, before = 20, after = 8}
	case .H3:
		return {size = 18, weight = .Semibold, line = 1.36, before = 16, after = 6}
	case .Quote:
		return {size = 15, weight = .Regular, line = 1.6, before = 12, after = 12, indent = 24, italic = true}
	case .Code:
		return {size = 13, weight = .Regular, line = 1.62, before = 12, after = 12, indent = 14, mono = true}
	case .Table:
		// A table has no type of its own; the numbers that matter are the space
		// it reserves above and below, and the body size its empty run reports
		// to anything that asks.
		return {size = 15, weight = .Regular, line = 1.56, before = 14, after = 14}
	case .Image:
		return {size = 15, weight = .Regular, line = 1, before = 12, after = 12}
	}
	return {}
}

kind_label :: proc(k: Para_Kind) -> string {
	switch k {
	case .Body:
		return "Body"
	case .H1:
		return "Heading 1"
	case .H2:
		return "Heading 2"
	case .H3:
		return "Heading 3"
	case .Quote:
		return "Quote"
	case .Code:
		return "Code"
	case .Table:
		return "Table"
	case .Image:
		return "Image"
	}
	return ""
}

// ITALIC — a palmy gap, worked around here.
//
// palmy's font table is [Font_Family][Font_Weight]; there is no style or slant
// axis, so "italic" cannot be named. Rather than fake an oblique by shearing
// glyph masks, the app loads real italic faces into the two Mono weight slots
// it does not otherwise use (Mono/Medium and Mono/Semibold — code text only
// ever asks for Mono/Regular and Mono/Bold). `resolve_face` is the one place
// that knows, so the rest of the program just asks for italic.
ITALIC_FAM :: p.Font_Family.Mono
ITALIC_WT :: p.Font_Weight.Medium
ITALIC_BOLD_WT :: p.Font_Weight.Semibold

resolve_face :: proc(
	km: Kind_Metrics,
	cs: Char_Style,
) -> (
	size: f32,
	fam: p.Font_Family,
	wt: p.Font_Weight,
) {
	size = cs.size > 0 ? cs.size : km.size
	bold := cs.bold || km.weight == .Bold
	mono := cs.mono || km.mono
	ital := cs.italic || km.italic
	switch {
	case mono:
		return size, .Mono, bold ? .Bold : .Regular
	case ital:
		return size, ITALIC_FAM, bold ? ITALIC_BOLD_WT : ITALIC_WT
	case bold:
		return size, .Sans, .Bold
	}
	return size, .Sans, km.weight
}

// ---------------------------------------------------------------------------
// The laid-out document
// ---------------------------------------------------------------------------

Frag :: struct {
	start, end: int, // paragraph-relative byte range
	x, w:       f32, // x relative to the line's left edge, and width
	size:       f32,
	fam:        p.Font_Family,
	wt:         p.Font_Weight,
	color:      u32,
	underline:  bool,
	gap_after:  bool, // ends on whitespace, so a justification gap follows
}

Line :: struct {
	para:       int, // the top-level paragraph, even for a line inside a cell
	// The block this line's bytes live in — an index into `Layout.blocks`.
	// Every text lookup goes through it, so a line inside a table cell reads
	// exactly like a line of body text.
	blk:        int,
	// Where inside a table the line sits. All zero outside one.
	row:        int,
	col:        int,
	cpara:      int,
	// A line drawn as part of a repeated header row. It is painted, but it is
	// not a place the caret can be, and stepping by visual line skips it.
	repeat:     bool,
	start, end: int, // paragraph-relative range; `end` includes trailing spaces
	vis_end:    int, // end with trailing spaces removed — what is measured
	fi, fc:     int, // range into Layout.frags
	page:       int,
	x:          f32, // left edge within the page's text area
	y:          f32, // top of the line box within the page's text area
	w:          f32,
	h:          f32,
	ascent:     f32,
	first:      bool, // first visual line of its paragraph
	last:       bool, // last visual line of its paragraph
	gap:        f32, // extra width added after every gap_after fragment
	marker:     int, // -1 none, 0 bullet, >0 ordinal
	indent:     f32,
}

Seg :: struct {
	start, end: int,
	cs:         Char_Style,
}

// Cache_Key identifies a paragraph's *wrapped shape*: its bytes, its run
// styles, and the three properties that change the measure it wraps to. Two
// paragraphs with the same key wrap identically, so they can share one entry.
// The byte length and run count ride along with the hash, because a silent
// collision here would show up as the wrong text on screen.
Cache_Key :: struct {
	hash:    u64,
	nbytes:  int,
	nruns:   int,
	kind:    Para_Kind,
	list:    List_Kind,
	depth:   int,
	// A cell in a header row, which sets the type bold. It rides in the key
	// because the weight changes the wrap.
	head:    bool,
	// The measure, in whole pixels. Before tables this was implied by
	// kind/list/depth; a cell paragraph wraps to its column's width instead, so
	// two paragraphs with identical text in differently sized columns must not
	// share an entry.
	measure: int,
}

Para_Cache :: struct {
	lines: [dynamic]Line,
	frags: [dynamic]Frag,
	seen:  u64,
}

// Blk_Span is one block's slice of `Layout.text`.
Blk_Span :: struct {
	at, n: int,
}

// Cell_Box is one cell's rectangle on one page, in text-area coordinates. The
// window and the PDF both draw the rules and the header shading from this list
// and nothing else, which is what keeps the two in agreement.
Cell_Box :: struct {
	para:   int, // the table paragraph
	page:   int,
	x, y:   f32,
	w, h:   f32,
	row:    int,
	col:    int,
	header: bool,
	repeat: bool, // a header repeated at the top of a continuation page
}

Layout :: struct {
	lines:   [dynamic]Line,
	frags:   [dynamic]Frag,
	// Every block's text, concatenated once, so measurement and drawing both
	// work on plain strings instead of walking runs. Blocks are in reading
	// order: a top-level paragraph, or a paragraph inside a table cell.
	text:    [dynamic]u8,
	blocks:  [dynamic]Blk_Span,
	blk_ids: [dynamic]Blk,
	cells:   [dynamic]Cell_Box,
	pages:   int,
	height:  f32,
	segs:    [dynamic]Seg, // scratch, one paragraph at a time

	// Wrapping is the expensive part — every width goes through stb_truetype —
	// and a keystroke only changes one paragraph. The shape of each paragraph
	// is therefore cached by key, and a layout re-wraps only what moved. The
	// pagination pass still runs over everything, which is just arithmetic.
	cache:   map[Cache_Key]Para_Cache,
	gen:     u64,
	wrapped: int, // paragraphs re-wrapped by the last layout, for diagnostics
}

layout_destroy :: proc(lay: ^Layout) {
	delete(lay.lines)
	delete(lay.frags)
	delete(lay.text)
	delete(lay.blocks)
	delete(lay.blk_ids)
	delete(lay.cells)
	delete(lay.segs)
	for _, &c in lay.cache {
		delete(c.lines)
		delete(c.frags)
	}
	delete(lay.cache)
	lay^ = {}
}

// para_key hashes everything that affects how a paragraph wraps: FNV-1a over
// the text bytes and the style of each run, plus the properties that set the
// measure.
para_key :: proc(pa: ^Paragraph, measure: f32, head := false) -> Cache_Key {
	h := u64(0xcbf29ce484222325)
	feed :: proc(h: u64, b: u8) -> u64 {
		return (h ~ u64(b)) * 0x100000001b3
	}
	n := 0
	for &r in pa.runs {
		cs := r.style
		flags := u8(0)
		if cs.bold {flags |= 1}
		if cs.italic {flags |= 2}
		if cs.underline {flags |= 4}
		if cs.mono {flags |= 8}
		h = feed(h, flags)
		sz := transmute(u32)cs.size
		for k in 0 ..< u32(4) {
			h = feed(h, u8(sz >> (8 * k)))
		}
		for k in 0 ..< u32(4) {
			h = feed(h, u8(cs.color >> (8 * k)))
		}
		h = feed(h, 0xff) // a boundary marker, so "ab|c" differs from "a|bc"
		for b in r.text {
			h = feed(h, b)
		}
		n += len(r.text)
	}
	return Cache_Key {
		hash = h,
		nbytes = n,
		nruns = len(pa.runs),
		kind = pa.kind,
		list = pa.list,
		depth = pa.depth,
		head = head,
		measure = int(measure + 0.5),
	}
}

// block_string is one block's bytes. Every text lookup in the layout, the
// renderer and the PDF writer goes through it.
block_string :: proc(lay: ^Layout, bi: int) -> string {
	if bi < 0 || bi >= len(lay.blocks) {
		return ""
	}
	sp := lay.blocks[bi]
	return string(lay.text[sp.at:sp.at + sp.n])
}

// para_string keeps the old name for a top-level paragraph, by finding the
// block that holds it. A table paragraph has no bytes of its own, so it
// answers the empty string.
para_string :: proc(lay: ^Layout, pi: int) -> string {
	for b, i in lay.blk_ids {
		if b.para == pi && b.row == 0 && b.col == 0 && b.cpara == 0 {
			return block_string(lay, i)
		}
	}
	return ""
}

line_text :: proc(lay: ^Layout, li: int) -> string {
	l := lay.lines[li]
	s := block_string(lay, l.blk)
	return s[clamp(l.start, 0, len(s)):clamp(l.end, 0, len(s))]
}

frag_text :: proc(lay: ^Layout, l: Line, f: Frag) -> string {
	s := block_string(lay, l.blk)
	return s[clamp(f.start, 0, len(s)):clamp(f.end, 0, len(s))]
}

// line_pos is the position of a byte offset on a line, carrying the line's
// table path along so the caret lands in the right cell.
line_pos :: proc(l: Line, off: int) -> Pos {
	return Pos{para = l.para, off = off, row = l.row, col = l.col, cpara = l.cpara}
}

line_blk :: proc(l: Line) -> Blk {
	return Blk{l.para, l.row, l.col, l.cpara}
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

// measure_segs measures [from, to) of the current paragraph, crossing style
// boundaries. Every width in the layout comes through here.
measure_segs :: proc(lay: ^Layout, fonts: ^p.Fonts, km: Kind_Metrics, s: string, from, to: int) -> f32 {
	if to <= from {
		return 0
	}
	total := f32(0)
	for sg in lay.segs {
		a := max(sg.start, from)
		b := min(sg.end, to)
		if b <= a {
			continue
		}
		size, fam, wt := resolve_face(km, sg.cs)
		total += p.text_width(fonts, s[a:b], size, fam, wt)
	}
	return total
}

build_segs :: proc(lay: ^Layout, pa: ^Paragraph) {
	clear(&lay.segs)
	acc := 0
	for &r in pa.runs {
		l := len(r.text)
		if l > 0 {
			append(&lay.segs, Seg{acc, acc + l, r.style})
		}
		acc += l
	}
	if len(lay.segs) == 0 {
		append(&lay.segs, Seg{0, 0, pa.runs[0].style})
	}
}

seg_at :: proc(lay: ^Layout, off: int) -> Seg {
	for sg in lay.segs {
		if off < sg.end {
			return sg
		}
	}
	return lay.segs[len(lay.segs) - 1]
}

para_indent :: proc(pa: ^Paragraph, km: Kind_Metrics) -> f32 {
	ind := km.indent + f32(pa.depth) * DEPTH_INDENT
	if pa.list != .None {
		ind += LIST_INDENT
	}
	return ind
}

// ---------------------------------------------------------------------------
// The layout pass
// ---------------------------------------------------------------------------

// block_is_header reports whether a block sits in a table's header row, which
// is the one thing about a cell paragraph that is not in the paragraph itself.
block_is_header :: proc(d: ^Doc, b: Blk) -> bool {
	if b.para < 0 || b.para >= len(d.paras) {
		return false
	}
	owner := &d.paras[b.para]
	return owner.kind == .Table && owner.table != nil && owner.table.header && b.row == 0
}

// block_metrics is a block's paragraph style, with the one override a header
// cell gets: bold type. The weight changes the measured width, so it has to be
// settled before wrapping rather than at drawing time.
block_metrics :: proc(d: ^Doc, b: Blk) -> Kind_Metrics {
	pa := blk_para(d, b)
	km := kind_metrics(pa == nil ? .Body : pa.kind)
	if block_is_header(d, b) {
		km.weight = .Bold
	}
	return km
}

// block_measure is the width a block wraps to: the content measure less its
// indent for a top-level paragraph, and the column width less the cell padding
// for one inside a table.
block_measure :: proc(d: ^Doc, b: Blk) -> f32 {
	pa := blk_para(d, b)
	if pa == nil {
		return CONTENT_W
	}
	km := kind_metrics(pa.kind)
	ind := para_indent(pa, km)
	if b.para >= 0 && b.para < len(d.paras) {
		owner := &d.paras[b.para]
		if owner.kind == .Table && owner.table != nil {
			return max(20, table_span_w(owner.table, b.row, b.col) - 2 * CELL_PAD - ind)
		}
	}
	return max(40, CONTENT_W - ind)
}

layout_doc :: proc(lay: ^Layout, d: ^Doc, fonts: ^p.Fonts) {
	// One copy of every block's text, so every later lookup is a slice. The
	// blocks are in reading order — a table paragraph contributes its cells'
	// paragraphs rather than itself — which is the order the pagination pass
	// walks them in, so a single forward cursor keeps the two in step.
	clear(&lay.text)
	clear(&lay.blocks)
	clear(&lay.blk_ids)
	clear(&lay.cells)
	bs := doc_blocks(d, context.temp_allocator)
	for b in bs {
		pa := blk_para(d, b)
		at := len(lay.text)
		if pa != nil {
			para_append_text(pa, &lay.text)
		}
		append(&lay.blocks, Blk_Span{at, len(lay.text) - at})
		append(&lay.blk_ids, b)
	}

	// Pass one: wrap whatever changed.
	lay.gen += 1
	lay.wrapped = 0
	keys := make([]Cache_Key, len(bs), context.temp_allocator)
	for bi in 0 ..< len(bs) {
		pa := blk_para(d, bs[bi])
		if pa == nil {
			continue
		}
		avail := block_measure(d, bs[bi])
		head := block_is_header(d, bs[bi])
		k := para_key(pa, avail, head)
		keys[bi] = k
		if c, hit := &lay.cache[k]; hit {
			c.seen = lay.gen
			continue
		}
		km := block_metrics(d, bs[bi])
		build_segs(lay, pa)
		c := Para_Cache {
			lines = make([dynamic]Line, 0, 4),
			frags = make([dynamic]Frag, 0, 16),
			seen  = lay.gen,
		}
		wrap_paragraph(lay, &c, fonts, km, block_string(lay, bi), avail)
		lay.cache[k] = c
		lay.wrapped += 1
	}

	// Pass two: pour the wrapped blocks onto pages. This is arithmetic only —
	// no text is measured here, so it stays cheap over a long document.
	clear(&lay.lines)
	clear(&lay.frags)
	page := 0
	y := f32(0)
	counters: [12]int
	prev_list := List_Kind.None
	prev_depth := -1
	bi := 0 // the forward cursor into `bs` / `keys`

	for pi in 0 ..< len(d.paras) {
		pa := &d.paras[pi]
		km := kind_metrics(pa.kind)

		// List numbering. A numbered item restarts whenever the run of list
		// items at its depth is interrupted.
		marker := -1
		switch pa.list {
		case .None:
			counters = {}
		case .Bullet:
			marker = 0
			for j in min(pa.depth, len(counters) - 1) ..< len(counters) {
				counters[j] = 0
			}
		case .Numbered:
			k := min(pa.depth, len(counters) - 1)
			if prev_list != .Numbered || prev_depth < pa.depth {
				counters[k] = 0
			}
			counters[k] += 1
			for j in k + 1 ..< len(counters) {
				counters[j] = 0
			}
			marker = counters[k]
		}
		prev_list, prev_depth = pa.list, pa.depth

		indent := para_indent(pa, km)
		avail := max(40, CONTENT_W - indent)

		// A paragraph's space before collapses at the top of a page, the way
		// it does in every page layout engine. Consecutive code lines and
		// consecutive items of one list close up, so a code block reads as a
		// block and a list as a list rather than as loose paragraphs.
		if len(lay.lines) > 0 && y > 0 {
			sb := km.before + pa.before
			if pi > 0 {
				prev := &d.paras[pi - 1]
				if pa.kind == .Code && prev.kind == .Code {
					sb = 0
				} else if pa.list != .None && prev.list == pa.list {
					sb = 0
				}
			}
			y += sb
		}

		// A hard page break wins over everything below.
		if pa.break_before && len(lay.lines) > 0 {
			page += 1
			y = 0
		}

		// --- a table: its own pagination, which is the only block that can
		// span pages in pieces. See layout_table.
		if pa.kind == .Table && pa.table != nil && len(pa.table.rows) > 0 {
			n := table_block_count(pa.table)
			layout_table(lay, d, pi, pa, bs[bi:bi + n], keys[bi:bi + n], bi, &page, &y)
			bi += n
			y += km.after + pa.after
			continue
		}

		c, have := &lay.cache[keys[bi]]
		if !have {
			bi += 1
			continue
		}

		// --- an image: one line box as tall as the picture, placed by the
		// paragraph's own alignment. The generic "this line does not fit"
		// rule below would move it down on its own; doing it here as well
		// keeps the intent legible and handles a picture exactly as tall as
		// the remaining space.
		img_w, img_h := f32(0), f32(0)
		if pa.kind == .Image {
			img_w, img_h = image_para_size(pa)
			if y > 0 && y + img_h > CONTENT_H {
				page += 1
				y = 0
			}
		} else if y > 0 && len(c.lines) > 0 {
			// Two typographic rules that make the difference between a
			// paginated document and a column of text chopped every 931
			// pixels:
			//
			//   keep with next — a heading never sits alone at the foot of a page
			//   orphan control — a paragraph never leaves one line behind
			//
			// Both look ahead and break the page *early*. A block too tall to
			// help is left alone, or the break would gain nothing and lose a
			// page.
			need := c.lines[0].h
			switch pa.kind {
			case .H1, .H2, .H3:
				need = km.after
				for src in c.lines {
					need += src.h
				}
				if bi + 1 < len(bs) {
					if nc, okn := &lay.cache[keys[bi + 1]]; okn && len(nc.lines) > 0 {
						need += nc.lines[0].h
					}
				}
			case .Body, .Quote, .Code:
				if len(c.lines) >= 2 {
					need = c.lines[0].h + c.lines[1].h
				}
			case .Table, .Image:
			}
			if need <= CONTENT_H && y + need > CONTENT_H {
				page += 1
				y = 0
			}
		}

		base_frag := len(lay.frags)
		append(&lay.frags, ..c.frags[:])

		for src in c.lines {
			l := src
			l.para = pi
			l.blk = bi
			l.fi = base_frag + src.fi
			if pa.kind == .Image {
				l.h = img_h
				l.w = img_w
				l.ascent = img_h
			}
			if y + l.h > CONTENT_H && y > 0 {
				page += 1
				y = 0
			}
			l.page = page
			l.y = y
			l.indent = indent
			l.marker = l.first ? marker : -1

			if pa.kind == .Image {
				l.x = image_x(pa, img_w)
				l.indent = l.x
			} else {
				switch pa.align {
				case .Left, .Justify:
					l.x = indent
				case .Center:
					l.x = indent + max(0, (avail - l.w) / 2)
				case .Right:
					l.x = indent + max(0, avail - l.w)
				}
			}

			l.gap = 0
			if pa.align == .Justify && !l.last {
				gaps := 0
				for k in 0 ..< l.fc {
					if lay.frags[l.fi + k].gap_after && k != l.fc - 1 {
						gaps += 1
					}
				}
				if gaps > 0 && l.w < avail {
					l.gap = (avail - l.w) / f32(gaps)
				}
			}

			// Fragment positions depend on the justification gap, so they are
			// placed here rather than in the cache. Every line owns its own
			// fragments, so writing to them is safe even when two paragraphs
			// share a cache entry.
			x := f32(0)
			for k in 0 ..< l.fc {
				f := &lay.frags[l.fi + k]
				f.x = x
				x += f.w
				if f.gap_after && k != l.fc - 1 {
					x += l.gap
				}
			}

			y += l.h
			append(&lay.lines, l)
		}
		sa := km.after + pa.after
		if pi + 1 < len(d.paras) {
			nx := &d.paras[pi + 1]
			if pa.kind == .Code && nx.kind == .Code {
				sa = 0
			} else if pa.list != .None && nx.list == pa.list {
				sa = 4
			}
		}
		y += sa
		bi += 1
	}

	lay.pages = page + 1
	lay.height = f32(page) * CONTENT_H + y

	// Drop entries nothing has asked for in a while. A few generations of
	// slack means an undo straight after an edit still hits the cache.
	if len(lay.cache) > 4 * len(lay.blocks) + 64 {
		stale := make([dynamic]Cache_Key, 0, 64, context.temp_allocator)
		for k, c in lay.cache {
			if lay.gen - c.seen > 4 {
				append(&stale, k)
			}
		}
		for k in stale {
			if c, found := &lay.cache[k]; found {
				delete(c.lines)
				delete(c.frags)
			}
			delete_key(&lay.cache, k)
		}
	}
}

// table_block_count is how many blocks a table contributes, which is what the
// pagination pass advances its cursor by.
table_block_count :: proc(t: ^Table) -> int {
	n := 0
	for &row in t.rows {
		for &c in row.cells {
			if !c.covered {
				n += len(c.paras)
			}
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------
//
// ## The pagination rule
//
// **A row is atomic, the table breaks between rows, and a header row is
// repeated at the top of every continuation page.**
//
// That is the rule Word and LibreOffice both use by default, and it is the one
// worth the work: the alternative — move the whole table to the next page —
// cannot express a table longer than a page at all, which is most of the
// tables anyone writes. The cost is that a single row taller than a whole page
// has nowhere to go; such a row is placed at the top of a fresh page and
// allowed to run past the bottom margin, which is the one case this does not
// handle and is noted rather than hidden.
//
// Row heights are measured from the wrapped cell paragraphs, so they are exact
// before a single row is placed — the same property the rest of the pagination
// pass relies on.
//
// Merged cells extend the rule rather than change it: rows joined by a
// vertical merge are one atomic unit (Word's "do not break this row" applied
// to the merged rows together), and the header that repeats is row 0 plus any
// rows merged into it. A merged cell taller than the rows it spans shares the
// difference evenly among them; LibreOffice gives it all to the last row, and
// even sharing was chosen because it keeps the rows beside the merge looking
// like one table rather than one tall row and some short ones.

TABLE_MIN_ROW_H :: f32(26)

// cell_content_h is the height of one cell's paragraphs stacked, without the
// padding. Space-before is dropped inside a cell and only the space-after
// between paragraphs is kept, so a one-paragraph cell is exactly its text.
@(private = "file")
cell_content_h :: proc(lay: ^Layout, d: ^Doc, cl: ^Cell, keys: []Cache_Key, at: int, measure := f32(CONTENT_W)) -> f32 {
	h := f32(0)
	for j in 0 ..< len(cl.paras) {
		pa := &cl.paras[j]
		// A picture in a cell is one line box as tall as the picture, exactly
		// as it is at the top level — but measured against the cell's width,
		// not the page's.
		if pa.kind == .Image {
			_, ih := image_para_size(pa, measure, CONTENT_H)
			h += ih
			if j + 1 < len(cl.paras) {
				h += kind_metrics(pa.kind).after + pa.after
			}
			continue
		}
		if c, have := &lay.cache[keys[at + j]]; have {
			for src in c.lines {
				h += src.h
			}
		}
		if j + 1 < len(cl.paras) {
			h += kind_metrics(pa.kind).after + pa.after
		}
	}
	return h
}

// layout_table pours one table's rows onto pages and records a Cell_Box for
// every cell on every page it appears on. `page` and `y` are advanced in place,
// exactly as the paragraph loop advances them.
layout_table :: proc(
	lay: ^Layout,
	d: ^Doc,
	pi: int,
	pa: ^Paragraph,
	bs: []Blk,
	keys: []Cache_Key,
	base_bi: int,
	page: ^int,
	y: ^f32,
) {
	t := pa.table
	ncols := table_cols(t)
	nrows := len(t.rows)
	if ncols == 0 || nrows == 0 {
		return
	}

	// Where each cell's blocks start, so a cell can be found without walking.
	// A cell hidden under a merge contributes no blocks.
	starts := make([]int, nrows * ncols, context.temp_allocator)
	at := 0
	for r in 0 ..< nrows {
		for c in 0 ..< ncols {
			starts[r * ncols + c] = at
			if cl := table_cell(t, r, c); cl != nil && !cl.covered {
				at += len(cl.paras)
			}
		}
	}

	// Row heights, measured once. A cell that spans one row sets its row's
	// height directly. A cell spanning several rows is settled afterwards:
	// if its text is taller than the rows it spans, the shortfall is shared
	// evenly among those rows. Shorter spans go first, so a long span sees
	// the heights the short ones already asked for.
	row_h := make([]f32, nrows, context.temp_allocator)
	Tall :: struct {
		r, n: int,
		need: f32,
	}
	tall := make([dynamic]Tall, 0, 4, context.temp_allocator)
	for r in 0 ..< nrows {
		h := f32(0)
		for c in 0 ..< ncols {
			cl := table_cell(t, r, c)
			if cl == nil || cl.covered {
				continue
			}
			ch := cell_content_h(
				lay,
				d,
				cl,
				keys,
				starts[r * ncols + c],
				max(20, table_span_w(t, r, c) - 2 * CELL_PAD),
			)
			if rs := min(cell_rspan(cl), nrows - r); rs > 1 {
				append(&tall, Tall{r, rs, max(TABLE_MIN_ROW_H, ch + 2 * CELL_PAD)})
				continue
			}
			h = max(h, ch)
		}
		row_h[r] = max(TABLE_MIN_ROW_H, h + 2 * CELL_PAD)
	}
	for i in 1 ..< len(tall) {
		for j := i; j > 0 && tall[j].n < tall[j - 1].n; j -= 1 {
			tall[j], tall[j - 1] = tall[j - 1], tall[j]
		}
	}
	for tc in tall {
		have := f32(0)
		for r in tc.r ..< tc.r + tc.n {
			have += row_h[r]
		}
		if tc.need > have {
			share := (tc.need - have) / f32(tc.n)
			for r in tc.r ..< tc.r + tc.n {
				row_h[r] += share
			}
		}
	}

	// Rows joined by a vertical merge are one unit for pagination: `group_end`
	// is the last row of the unit a row starts. A merged cell is not split
	// across a page break, the same way a row is not.
	group_end := make([]int, nrows, context.temp_allocator)
	for r := 0; r < nrows; {
		end := r
		for k := r; k <= end; k += 1 {
			for c in 0 ..< ncols {
				if cl := table_cell(t, k, c); cl != nil && !cl.covered {
					end = max(end, min(nrows - 1, k + cell_rspan(cl) - 1))
				}
			}
		}
		for k in r ..= end {
			group_end[k] = end
		}
		r = end + 1
	}

	emit_row := proc(
		lay: ^Layout,
		d: ^Doc,
		pi: int,
		t: ^Table,
		bs: []Blk,
		keys: []Cache_Key,
		base_bi: int,
		starts: []int,
		ncols: int,
		r: int,
		page: int,
		top: f32,
		row_h: []f32,
		repeat: bool,
	) {
		for c in 0 ..< ncols {
			cl := table_cell(t, r, c)
			if cl != nil && cl.covered {
				continue // drawn, and read, as part of its anchor
			}
			cx := table_col_x(t, c)
			cw := table_span_w(t, r, c)
			h := f32(0)
			rs := cl == nil ? 1 : cell_rspan(cl)
			for k in r ..< min(len(row_h), r + rs) {
				h += row_h[k]
			}
			append(
				&lay.cells,
				Cell_Box {
					para = pi,
					page = page,
					x = cx,
					y = top,
					w = cw,
					h = h,
					row = r,
					col = c,
					header = t.header && r == 0,
					repeat = repeat,
				},
			)
			if cl == nil {
				continue
			}
			cy := top + CELL_PAD
			for j in 0 ..< len(cl.paras) {
				cpa := &cl.paras[j]
				km := kind_metrics(cpa.kind)
				bidx := starts[r * ncols + c] + j
				cc, have := &lay.cache[keys[bidx]]
				if !have {
					continue
				}
				ind := para_indent(cpa, km)
				avail := max(20, cw - 2 * CELL_PAD - ind)
				// A picture in a cell: one line box as tall as the picture,
				// sized and placed against the cell rather than the page.
				img_w, img_h := f32(0), f32(0)
				if cpa.kind == .Image {
					img_w, img_h = image_para_size(cpa, avail, CONTENT_H)
				}
				base_frag := len(lay.frags)
				append(&lay.frags, ..cc.frags[:])
				for src in cc.lines {
					l := src
					l.para = pi
					l.blk = base_bi + bidx
					l.row, l.col, l.cpara = r, c, j
					l.repeat = repeat
					l.fi = base_frag + src.fi
					l.page = page
					l.y = cy
					l.indent = cx + CELL_PAD + ind
					l.marker = l.first && cpa.list != .None ? (cpa.list == .Bullet ? 0 : 1) : -1
					if cpa.kind == .Image {
						l.h = img_h
						l.w = img_w
						l.ascent = img_h
						l.x = l.indent + image_x(cpa, img_w, avail)
						l.indent = l.x
						cy += l.h
						append(&lay.lines, l)
						continue
					}
					switch cpa.align {
					case .Left, .Justify:
						l.x = l.indent
					case .Center:
						l.x = l.indent + max(0, (avail - l.w) / 2)
					case .Right:
						l.x = l.indent + max(0, avail - l.w)
					}
					l.gap = 0
					if cpa.align == .Justify && !l.last {
						gaps := 0
						for k in 0 ..< l.fc {
							if lay.frags[l.fi + k].gap_after && k != l.fc - 1 {
								gaps += 1
							}
						}
						if gaps > 0 && l.w < avail {
							l.gap = (avail - l.w) / f32(gaps)
						}
					}
					x := f32(0)
					for k in 0 ..< l.fc {
						f := &lay.frags[l.fi + k]
						f.x = x
						x += f.w
						if f.gap_after && k != l.fc - 1 {
							x += l.gap
						}
					}
					cy += l.h
					append(&lay.lines, l)
				}
				if j + 1 < len(cl.paras) {
					cy += km.after + cpa.after
				}
			}
		}
	}

	// The header that repeats on a continuation page is row 0 and whatever
	// rows a merge joins to it.
	head_end := t.header ? group_end[0] : -1
	for r := 0; r < nrows; {
		g := group_end[r]
		gh := f32(0)
		for k in r ..= g {
			gh += row_h[k]
		}
		// The unit does not fit: break the page, and bring the header with it.
		if y^ > 0 && y^ + gh > CONTENT_H {
			page^ += 1
			y^ = 0
			if t.header && r > head_end {
				for k in 0 ..= head_end {
					emit_row(lay, d, pi, t, bs, keys, base_bi, starts, ncols, k, page^, y^, row_h, true)
					y^ += row_h[k]
				}
			}
		}
		for k in r ..= g {
			emit_row(lay, d, pi, t, bs, keys, base_bi, starts, ncols, k, page^, y^, row_h, false)
			y^ += row_h[k]
		}
		r = g + 1
	}
}

// wrap_paragraph greedily fills lines of `avail` px, breaking between words.
// A word too wide for a line of its own is broken between runes.
wrap_paragraph :: proc(
	lay: ^Layout,
	out: ^Para_Cache,
	fonts: ^p.Fonts,
	km: Kind_Metrics,
	text: string,
	avail: f32,
) {
	n := len(text)
	line_start := 0
	line_w := f32(0)
	vis_end := 0

	i := 0
	for i < n {
		// A word is a run of non-space bytes plus the spaces that follow it.
		j := i
		for j < n && text[j] > 0x20 {
			j += 1
		}
		k := j
		for k < n && text[k] <= 0x20 {
			k += 1
		}

		core := measure_segs(lay, fonts, km, text, i, j)
		full := core + measure_segs(lay, fonts, km, text, j, k)

		if line_w + core > avail && i > line_start {
			emit_line(lay, out, fonts, km, text, line_start, i, vis_end)
			line_start = i
			line_w = 0
		}

		if core > avail && i == line_start && j > i {
			// One word wider than the measure: break it between runes.
			at := i
			for at < j {
				lo := at
				hi := at
				w := f32(0)
				for hi < j {
					next := rune_after(text, hi)
					cw := measure_segs(lay, fonts, km, text, hi, next)
					if w + cw > avail && hi > lo {
						break
					}
					w += cw
					hi = next
				}
				if hi == lo {
					hi = rune_after(text, lo)
				}
				at = hi
				if hi >= j {
					break
				}
				emit_line(lay, out, fonts, km, text, lo, hi, hi)
				line_start = hi
			}
			line_w = measure_segs(lay, fonts, km, text, line_start, k)
			vis_end = j
			i = k
			continue
		}

		line_w += full
		vis_end = j
		i = k
	}

	emit_line(lay, out, fonts, km, text, line_start, n, max(vis_end, line_start))

	for li in 0 ..< len(out.lines) {
		out.lines[li].first = li == 0
		out.lines[li].last = li == len(out.lines) - 1
	}
}

emit_line :: proc(
	lay: ^Layout,
	out: ^Para_Cache,
	fonts: ^p.Fonts,
	km: Kind_Metrics,
	text: string,
	start, end, vis: int,
) {
	l := Line {
		para    = -1,
		start   = start,
		end     = end,
		vis_end = clamp(vis, start, end),
		marker  = -1,
	}
	l.fi = len(out.frags)
	build_frags(lay, out, fonts, km, text, start, end, &l)
	l.fc = len(out.frags) - l.fi

	// Heights come from the tallest fragment, so a 36px word inside a body
	// paragraph opens its line rather than overlapping the one above.
	biggest := km.size
	fam, wt := p.Font_Family.Sans, km.weight
	for k in 0 ..< l.fc {
		f := out.frags[l.fi + k]
		if f.size > biggest {
			biggest, fam, wt = f.size, f.fam, f.wt
		}
	}
	m := p.font_metrics(fonts, biggest, fam, wt)
	l.h = biggest * km.line
	l.ascent = m.ascent + (l.h - (m.ascent + m.descent)) / 2

	// The visible width — trailing spaces excluded — comes out of the
	// fragments that were just measured, rather than a second pass over the
	// text. Alignment and justification both need it.
	w := f32(0)
	for k in 0 ..< l.fc {
		f := out.frags[l.fi + k]
		if f.end <= l.vis_end {
			w += f.w
		} else if f.start < l.vis_end {
			w += p.text_width_upto(fonts, text[f.start:f.end], l.vis_end - f.start, f.size, f.fam, f.wt)
		}
	}
	l.w = w

	append(&out.lines, l)
}

// build_frags cuts [start, end) into fragments: a new one at every style
// boundary and after every run of spaces, so a fragment never contains an
// interior space. That keeps justification exact — the gap goes between
// fragments — and lets `p.text_index_at` work on a fragment directly.
build_frags :: proc(
	lay: ^Layout,
	out: ^Para_Cache,
	fonts: ^p.Fonts,
	km: Kind_Metrics,
	text: string,
	start, end: int,
	l: ^Line,
) {
	at := start
	for at < end {
		seg := seg_at(lay, at)
		stop := min(max(seg.end, at + 1), end)

		cut := at
		for cut < stop && text[cut] > 0x20 {
			cut += 1
		}
		spaces := false
		for cut < stop && text[cut] <= 0x20 {
			cut += 1
			spaces = true
		}
		if cut == at {
			cut = stop
		}

		size, fam, wt := resolve_face(km, seg.cs)
		append(
			&out.frags,
			Frag {
				start     = at,
				end       = cut,
				size      = size,
				fam       = fam,
				wt        = wt,
				color     = seg.cs.color,
				underline = seg.cs.underline,
				gap_after = spaces,
				w         = p.text_width(fonts, text[at:cut], size, fam, wt),
			},
		)
		at = cut
	}

	if len(out.frags) == l.fi {
		// An empty line still needs one fragment, so the caret has a height
		// and a font to sit against.
		seg := seg_at(lay, start)
		size, fam, wt := resolve_face(km, seg.cs)
		append(
			&out.frags,
			Frag {
				start = start,
				end = start,
				size = size,
				fam = fam,
				wt = wt,
				color = seg.cs.color,
				underline = seg.cs.underline,
			},
		)
	}
}

// ---------------------------------------------------------------------------
// Caret mapping
// ---------------------------------------------------------------------------

// line_of finds the visual line a position sits on.
//
// A position at a soft break is ambiguous: it is both the end of one line and
// the start of the next. It belongs to the line that *starts* there, because
// that is where the next character typed will appear — and because resolving
// it the other way strands Down and Page Down, which then step onto the break
// and are told they are still on the line above.
line_of :: proc(lay: ^Layout, q: Pos) -> int {
	want := Blk{q.para, q.row, q.col, q.cpara}
	best := -1
	for li in 0 ..< len(lay.lines) {
		l := lay.lines[li]
		// A repeated header row is painted but is not a place a caret can be:
		// the caret belongs to the one occurrence the model has.
		if l.repeat || line_blk(l) != want {
			if best >= 0 {
				break
			}
			continue
		}
		best = li
		if q.off < l.end || (q.off == l.end && l.last) {
			return li
		}
	}
	return best
}

// line_step walks visual lines, skipping the repeated header rows so Down
// through a table that breaks across pages does not visit the header twice.
line_step :: proc(lay: ^Layout, from, delta: int) -> int {
	if len(lay.lines) == 0 {
		return -1
	}
	dir := delta < 0 ? -1 : 1
	n := abs(delta)
	at := clamp(from, 0, len(lay.lines) - 1)
	for _ in 0 ..< n {
		k := at + dir
		for k >= 0 && k < len(lay.lines) && lay.lines[k].repeat {
			k += dir
		}
		if k < 0 || k >= len(lay.lines) {
			break
		}
		at = k
	}
	return at
}

// caret_x is the x of a caret, in page text-area coordinates.
caret_x :: proc(lay: ^Layout, li: int, off: int) -> f32 {
	if li < 0 || li >= len(lay.lines) {
		return 0
	}
	l := lay.lines[li]
	o := clamp(off, l.start, l.end)
	for k in 0 ..< l.fc {
		f := lay.frags[l.fi + k]
		if o <= f.start {
			return l.x + f.x
		}
		if o <= f.end {
			s := frag_text(lay, l, f)
			return l.x + f.x + p.text_width_upto(layout_fonts, s, o - f.start, f.size, f.fam, f.wt)
		}
	}
	if l.fc > 0 {
		f := lay.frags[l.fi + l.fc - 1]
		return l.x + f.x + f.w
	}
	return l.x
}

// off_at_x is the inverse: the byte offset nearest an x within the line.
off_at_x :: proc(lay: ^Layout, li: int, x: f32) -> int {
	if li < 0 || li >= len(lay.lines) {
		return 0
	}
	l := lay.lines[li]
	if l.fc == 0 {
		return l.start
	}
	rel := x - l.x
	if rel <= 0 {
		return l.start
	}
	for k in 0 ..< l.fc {
		f := lay.frags[l.fi + k]
		if rel <= f.x + f.w || k == l.fc - 1 {
			s := frag_text(lay, l, f)
			i := p.text_index_at(layout_fonts, s, f.size, rel - f.x, f.fam, f.wt)
			return f.start + i
		}
	}
	return l.vis_end
}

// page_cells gives the first and last cell-box index on a page. The boxes are
// built in page order, so this is a scan rather than a search.
page_cells :: proc(lay: ^Layout, page: int) -> (lo, hi: int) {
	lo, hi = -1, -1
	for i in 0 ..< len(lay.cells) {
		if lay.cells[i].page == page {
			if lo < 0 {
				lo = i
			}
			hi = i
		}
	}
	return
}

// page_lines gives the first and last line index on a page.
page_lines :: proc(lay: ^Layout, page: int) -> (lo, hi: int) {
	lo, hi = -1, -1
	for li in 0 ..< len(lay.lines) {
		if lay.lines[li].page == page {
			if lo < 0 {
				lo = li
			}
			hi = li
		} else if lo >= 0 {
			break
		}
	}
	return
}
