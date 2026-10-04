// Reflow: a book's blocks into lines, and lines onto pages.
//
// `apps/docs/layout.odin` solves the same problem for a word processor and
// this follows its shape deliberately — greedy word wrap measured through
// `p.text_width`, lines cut into fragments at style boundaries, a pagination
// pass that is pure arithmetic, and a per-paragraph cache keyed on a hash of
// the paragraph's bytes and styles. Its author measured a naive full re-wrap
// at 33 ms per keystroke over 400 paragraphs. A book is 3000 paragraphs, and
// the reader changes the font size with a key, so the same arithmetic says a
// full re-wrap would be a quarter of a second of dead interface per press.
//
// Two things are therefore different here, and both come from a book being
// long rather than from a book being different:
//
//   Nothing lays out the whole book. The unit of layout is the chapter — the
//   spine item, which is what an EPUB already divides itself into and what a
//   MOBI's headings are used to divide it into. Opening a book wraps chapter
//   one. Turning a page wraps nothing. Changing the font size re-wraps the
//   chapter you are in. The chapters either side are laid out when you
//   approach them, and a handful are kept.
//
//   Progress is not a page number. A page number is meaningless when the
//   font size can change under it, so position is (chapter, byte offset into
//   the chapter) and the fraction through the book is computed from chapter
//   byte sizes. That is what makes "reopen where I left off" survive a change
//   of font size, of window width, and of theme.
//
// The block cache sits underneath both: it is keyed on the block's content
// *and* on the measure and type size it was wrapped to, so changing the size
// and changing it back is a cache hit and returns pagination identical to
// before, rather than merely similar.
package main

import "core:slice"
import p "palmy:."

// ---------------------------------------------------------------------------
// Reading settings
// ---------------------------------------------------------------------------

Para_Style :: enum u8 {
	Indented, // first line indented, no space between paragraphs: a book
	Spaced, // space between paragraphs, no indent: a web page
}

Reflow_Opts :: struct {
	size:    f32, // body type size in px
	line:    f32, // line height, as a multiple of the type size
	measure: f32, // the text column's width in px
	page_h:  f32, // the content height one page holds
	justify: bool,
	para:    Para_Style,
}

// Kind_Metrics is one block kind's typography, derived from the reader's
// chosen body size so that everything scales together.
Kind_Metrics :: struct {
	size:   f32,
	bold:   bool,
	semi:   bool,
	italic: bool,
	mono:   bool,
	line:   f32, // multiple of size
	before: f32, // ems of its own size
	after:  f32,
	indent: f32, // ems
}

kind_metrics :: proc(k: Block_Kind, o: Reflow_Opts) -> Kind_Metrics {
	s := o.size
	switch k {
	case .Para:
		return {
			size = s,
			line = o.line,
			after = o.para == .Spaced ? 0.62 : 0,
			indent = 0,
		}
	case .H1:
		return {size = s * 1.72, bold = true, line = 1.18, before = 1.1, after = 0.5}
	case .H2:
		return {size = s * 1.38, bold = true, line = 1.24, before = 1.0, after = 0.42}
	case .H3:
		return {size = s * 1.17, semi = true, line = 1.3, before = 0.9, after = 0.36}
	case .H4:
		return {size = s * 1.02, semi = true, line = 1.34, before = 0.8, after = 0.3}
	case .Quote:
		return {
			size = s * 0.97,
			italic = true,
			line = o.line,
			before = 0.5,
			after = 0.5,
			indent = 1.4,
		}
	case .Code:
		return {size = s * 0.86, mono = true, line = 1.45, before = 0.4, after = 0.4, indent = 0.8}
	case .Item:
		return {size = s, line = o.line, after = 0.3}
	case .Image:
		return {size = s, line = 1, before = 0.6, after = 0.6}
	case .Rule:
		return {size = s, line = 1, before = 0.8, after = 0.8}
	}
	return {size = s, line = o.line}
}

resolve_face :: proc(
	km: Kind_Metrics,
	st: Char_Style,
) -> (
	size: f32,
	fam: p.Font_Family,
	wt: p.Font_Weight,
	sl: p.Font_Slant,
) {
	size = km.size * style_scale(st)
	fam = (st.mono || km.mono) ? .Mono : .Sans
	switch {
	case st.bold || km.bold:
		wt = .Bold
	case km.semi:
		wt = .Semibold
	case:
		wt = .Regular
	}
	sl = (st.italic || km.italic) ? .Italic : .Upright
	return
}

// ---------------------------------------------------------------------------
// The laid-out shapes
// ---------------------------------------------------------------------------

Frag :: struct {
	start, end: int, // block-relative byte range
	x, w:       f32, // x within the line, width
	size:       f32,
	fam:        p.Font_Family,
	wt:         p.Font_Weight,
	sl:         p.Font_Slant,
	dy:         f32, // superscript/subscript shift
	underline:  bool,
	strike:     bool,
	link:       i32,
	gap_after:  bool, // ends on whitespace, so justification adds a gap here
}

Line :: struct {
	block:      int,
	start, end: int, // block-relative; `end` keeps trailing spaces
	vis_end:    int, // what is measured and drawn
	fi, fc:     int, // range into the layout's frags
	x, y:       f32,
	w, h:       f32,
	ascent:     f32,
	page:       int,
	first:      bool,
	last:       bool,
	gap:        f32,
	marker:     i32, // -1 none, 0 bullet, >0 ordinal
	indent:     f32,
	kind:       Block_Kind,
	image:      i32,
}

// ---------------------------------------------------------------------------
// The block cache
// ---------------------------------------------------------------------------

// Wrap_Key identifies a block's wrapped shape. Everything that changes where
// the line breaks fall is in it; nothing that only changes where the lines are
// *put* is, so moving a block to another page is free.
Wrap_Key :: struct {
	hash:    u64,
	nbytes:  int,
	nsegs:   int,
	kind:    Block_Kind,
	list:    List_Kind,
	depth:   u8,
	measure: int, // whole px
	size:    int, // tenths of a px, so 13.5 and 13.6 are different entries
	line:    int, // hundredths
}

Wrap :: struct {
	lines: [dynamic]Line,
	frags: [dynamic]Frag,
	seen:  u64,
}

// block_key hashes the block's bytes and the style of every segment, plus the
// three settings that change the measure. The byte and segment counts ride
// along with the hash because a silent collision would put another paragraph's
// text on screen.
block_key :: proc(d: ^Doc, bi: int, o: Reflow_Opts, measure: f32) -> Wrap_Key {
	b := d.blocks[bi]
	h := u64(0xcbf29ce484222325)
	feed :: proc(h: u64, byte_: u8) -> u64 {
		return (h ~ u64(byte_)) * 0x100000001b3
	}
	for sg in block_segs(d, bi) {
		st := sg.st
		flags := u8(0)
		if st.bold {flags |= 1}
		if st.italic {flags |= 2}
		if st.underline {flags |= 4}
		if st.mono {flags |= 8}
		if st.strike {flags |= 16}
		if st.sup {flags |= 32}
		if st.sub {flags |= 64}
		h = feed(h, flags)
		q := u32(style_scale(st) * 1000)
		for k in 0 ..< u32(4) {
			h = feed(h, u8(q >> (8 * k)))
		}
		h = feed(h, 0xff) // a boundary, so "ab|c" differs from "a|bc"
	}
	for byte_ in transmute([]u8)block_text(d, bi) {
		h = feed(h, byte_)
	}
	// The block's own scale and image come from CSS, not from its bytes.
	q2 := u32((b.scale > 0 ? b.scale : 1) * 1000)
	for k in 0 ..< u32(4) {
		h = feed(h, u8(q2 >> (8 * k)))
	}
	h = feed(h, u8(b.align))
	h = feed(h, b.indent_set ? 1 : 0)
	q3 := u32(b.indent * 100)
	for k in 0 ..< u32(4) {
		h = feed(h, u8(q3 >> (8 * k)))
	}
	if b.image >= 0 {
		im := d.images[b.image]
		h = feed(h, u8(im.w))
		h = feed(h, u8(im.w >> 8))
		h = feed(h, u8(im.h))
		h = feed(h, u8(im.h >> 8))
	}
	return Wrap_Key {
		hash = h,
		nbytes = int(b.n),
		nsegs = int(b.sn),
		kind = b.kind,
		list = b.list,
		depth = b.depth,
		measure = int(measure + 0.5),
		size = int(o.size * 10 + 0.5),
		line = int(o.line * 100 + 0.5),
	}
}

// ---------------------------------------------------------------------------
// A chapter's layout
// ---------------------------------------------------------------------------

Layout_Key :: struct {
	chapter: int,
	measure: int,
	page_h:  int,
	size:    int,
	line:    int,
	justify: bool,
	para:    Para_Style,
}

Chapter_Layout :: struct {
	key:     Layout_Key,
	valid:   bool,
	lines:   [dynamic]Line,
	frags:   [dynamic]Frag,
	// page_at[k] is the index of the first line on page k, and it has
	// `pages + 1` entries so page k is lines[page_at[k]:page_at[k+1]].
	page_at: [dynamic]int,
	pages:   int,
	height:  f32,
	touched: u64,
}

CHAPTER_CACHE :: 5

Reflow :: struct {
	opts:    Reflow_Opts,
	cache:   map[Wrap_Key]Wrap,
	gen:     u64,
	chaps:   [CHAPTER_CACHE]Chapter_Layout,
	clock:   u64,
	fonts:   ^p.Fonts,
	// Diagnostics, reported in the status line and the selftest.
	wrapped: int, // blocks re-wrapped by the last chapter layout
	hits:    int,
	misses:  int,
	lines_cached: int,
}

reflow_init :: proc(r: ^Reflow, fonts: ^p.Fonts, o: Reflow_Opts) {
	r^ = {}
	r.fonts = fonts
	r.opts = o
	r.cache = make(map[Wrap_Key]Wrap)
	for i in 0 ..< CHAPTER_CACHE {
		r.chaps[i].lines = make([dynamic]Line, 0, 256)
		r.chaps[i].frags = make([dynamic]Frag, 0, 512)
		r.chaps[i].page_at = make([dynamic]int, 0, 32)
	}
}

reflow_destroy :: proc(r: ^Reflow) {
	for _, &w in r.cache {
		delete(w.lines)
		delete(w.frags)
	}
	delete(r.cache)
	for i in 0 ..< CHAPTER_CACHE {
		delete(r.chaps[i].lines)
		delete(r.chaps[i].frags)
		delete(r.chaps[i].page_at)
	}
	r^ = {}
}

// reflow_set_opts changes the reading settings. Chapter layouts are
// invalidated; the block cache is kept, because the reader who just made the
// text bigger will make it smaller again.
reflow_set_opts :: proc(r: ^Reflow, o: Reflow_Opts) {
	if r.opts == o {
		return
	}
	r.opts = o
	for i in 0 ..< CHAPTER_CACHE {
		r.chaps[i].valid = false
	}
}

// reflow_invalidate drops everything, which is what a new book needs.
reflow_invalidate :: proc(r: ^Reflow) {
	for _, &w in r.cache {
		delete(w.lines)
		delete(w.frags)
	}
	clear(&r.cache)
	r.lines_cached = 0
	for i in 0 ..< CHAPTER_CACHE {
		r.chaps[i].valid = false
	}
}

// reflow_chapter returns the laid-out chapter, laying it out if needed.
reflow_chapter :: proc(r: ^Reflow, d: ^Doc, ci: int) -> ^Chapter_Layout {
	key := Layout_Key {
		chapter = ci,
		measure = int(r.opts.measure + 0.5),
		page_h  = int(r.opts.page_h + 0.5),
		size    = int(r.opts.size * 10 + 0.5),
		line    = int(r.opts.line * 100 + 0.5),
		justify = r.opts.justify,
		para    = r.opts.para,
	}
	r.clock += 1

	for i in 0 ..< CHAPTER_CACHE {
		if r.chaps[i].valid && r.chaps[i].key == key {
			r.chaps[i].touched = r.clock
			return &r.chaps[i]
		}
	}

	// Evict the least recently touched slot.
	victim := 0
	for i in 1 ..< CHAPTER_CACHE {
		if !r.chaps[i].valid {
			victim = i
			break
		}
		if r.chaps[i].touched < r.chaps[victim].touched {
			victim = i
		}
	}
	cl := &r.chaps[victim]
	cl.key = key
	cl.touched = r.clock
	layout_chapter(r, d, ci, cl)
	cl.valid = true
	return cl
}

// ---------------------------------------------------------------------------
// Pass one: wrapping
// ---------------------------------------------------------------------------

// block_measure is the width a block's text wraps to: the column less its
// indent.
block_measure :: proc(d: ^Doc, bi: int, o: Reflow_Opts) -> f32 {
	b := d.blocks[bi]
	km := kind_metrics(b.kind, o)
	ind := block_indent(d, bi, o)
	_ = km
	return max(40, o.measure - ind)
}

block_indent :: proc(d: ^Doc, bi: int, o: Reflow_Opts) -> f32 {
	b := d.blocks[bi]
	km := kind_metrics(b.kind, o)
	ind := km.indent * km.size
	ind += f32(b.depth) * 1.35 * o.size
	if b.list != .None {
		ind += 1.5 * o.size
	}
	return ind
}

// wrap_block is greedy word wrap. Every width in the layout is measured here
// and nowhere else.
@(private = "file")
wrap_block :: proc(r: ^Reflow, d: ^Doc, bi: int, out: ^Wrap, avail: f32) {
	b := d.blocks[bi]
	km := kind_metrics(b.kind, r.opts)
	if b.scale > 0 {
		km.size *= b.scale
	}
	text := block_text(d, bi)
	segs := block_segs(d, bi)

	if b.kind == .Rule {
		append(
			&out.lines,
			Line {
				block = bi,
				h = km.size * 1.2,
				ascent = km.size * 0.6,
				first = true,
				last = true,
				marker = -1,
				kind = .Rule,
				image = -1,
			},
		)
		return
	}
	if b.kind == .Image {
		iw, ih := image_box(d, b.image, avail, r.opts)
		append(
			&out.lines,
			Line {
				block = bi,
				w = iw,
				h = ih,
				ascent = ih,
				first = true,
				last = true,
				marker = -1,
				kind = .Image,
				image = b.image,
			},
		)
		return
	}

	n := len(text)
	line_start := 0
	line_w := f32(0)
	vis_end := 0
	// The first line of an indented paragraph starts further in.
	first_extra := f32(0)
	if r.opts.para == .Indented && b.kind == .Para && b.align == .Left {
		first_extra = 1.3 * km.size
	}
	if b.indent_set {
		first_extra = b.indent * km.size
	}

	i := 0
	for i < n {
		// A word is a run of non-space bytes, plus the spaces after it.
		j := i
		for j < n && text[j] > 0x20 {
			j += 1
		}
		k := j
		for k < n && text[k] <= 0x20 {
			k += 1
		}

		room := avail - (len(out.lines) == 0 && line_start == 0 ? first_extra : 0)
		core := measure_range(r, km, segs, text, i, j)
		full := core + measure_range(r, km, segs, text, j, k)

		if line_w + core > room && i > line_start {
			emit_line(r, d, bi, out, km, segs, text, line_start, i, vis_end, first_extra)
			line_start = i
			line_w = 0
		}

		if core > room && i == line_start && j > i {
			// A single word wider than the measure — a URL, a German
			// compound, a run of underscores. Break it between runes rather
			// than letting it overhang the column.
			at := i
			for at < j {
				lo := at
				hi := at
				w := f32(0)
				for hi < j {
					next := rune_after(text, hi)
					cw := measure_range(r, km, segs, text, hi, next)
					if w + cw > room && hi > lo {
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
				emit_line(r, d, bi, out, km, segs, text, lo, hi, hi, first_extra)
				line_start = hi
			}
			line_w = measure_range(r, km, segs, text, line_start, k)
			vis_end = j
			i = k
			continue
		}

		line_w += full
		vis_end = j
		i = k
	}
	emit_line(r, d, bi, out, km, segs, text, line_start, n, max(vis_end, line_start), first_extra)

	for li in 0 ..< len(out.lines) {
		out.lines[li].first = li == 0
		out.lines[li].last = li == len(out.lines) - 1
	}
}

rune_after :: proc(s: string, at: int) -> int {
	i := at + 1
	for i < len(s) && (s[i] & 0xc0) == 0x80 {
		i += 1
	}
	return min(i, len(s))
}

@(private = "file")
seg_at :: proc(segs: []Seg, off: int) -> Char_Style {
	for sg in segs {
		if off < sg.end {
			return sg.st
		}
	}
	if len(segs) > 0 {
		return segs[len(segs) - 1].st
	}
	return {link = -1}
}

// measure_range measures [from, to) across style boundaries.
@(private = "file")
measure_range :: proc(
	r: ^Reflow,
	km: Kind_Metrics,
	segs: []Seg,
	s: string,
	from, to: int,
) -> f32 {
	if to <= from {
		return 0
	}
	if len(segs) == 0 {
		size, fam, wt, sl := resolve_face(km, {link = -1})
		return p.text_width(r.fonts, s[from:to], size, fam, wt, 0, sl)
	}
	total := f32(0)
	for sg in segs {
		a := max(sg.start, from)
		b := min(sg.end, to)
		if b <= a {
			continue
		}
		size, fam, wt, sl := resolve_face(km, sg.st)
		total += p.text_width(r.fonts, s[a:b], size, fam, wt, 0, sl)
	}
	return total
}

// emit_line cuts [from, to) into fragments at style boundaries and appends the
// line. Fragment x positions are left at zero here and set during pagination,
// because justification changes them.
@(private = "file")
emit_line :: proc(
	r: ^Reflow,
	d: ^Doc,
	bi: int,
	out: ^Wrap,
	km: Kind_Metrics,
	segs: []Seg,
	text: string,
	from, to, vis: int,
	first_extra: f32,
) {
	vis_end := clamp(vis, from, to)
	fi := len(out.frags)
	total := f32(0)
	ascent := f32(0)
	descent := f32(0)

	add :: proc(
		r: ^Reflow,
		out: ^Wrap,
		km: Kind_Metrics,
		text: string,
		a, b: int,
		st: Char_Style,
		total, ascent, descent: ^f32,
	) {
		if b <= a {
			return
		}
		size, fam, wt, sl := resolve_face(km, st)
		w := p.text_width(r.fonts, text[a:b], size, fam, wt, 0, sl)
		m := p.font_metrics(r.fonts, size, fam, wt, sl)
		dy := f32(0)
		if st.sup {dy = -size * 0.42}
		if st.sub {dy = size * 0.18}
		ascent^ = max(ascent^, m.ascent - dy)
		descent^ = max(descent^, m.descent + dy)
		append(
			&out.frags,
			Frag {
				start = a,
				end = b,
				w = w,
				size = size,
				fam = fam,
				wt = wt,
				sl = sl,
				dy = dy,
				underline = st.underline,
				strike = st.strike,
				link = st.link,
				gap_after = b < len(text) && text[b] <= 0x20,
			},
		)
		total^ += w
	}

	if len(segs) == 0 {
		add(r, out, km, text, from, vis_end, {link = -1}, &total, &ascent, &descent)
	} else {
		at := from
		for sg in segs {
			if sg.end <= at {
				continue
			}
			if sg.start >= vis_end {
				break
			}
			a := max(sg.start, at)
			b := min(sg.end, vis_end)
			add(r, out, km, text, a, b, sg.st, &total, &ascent, &descent)
			at = b
			if at >= vis_end {
				break
			}
		}
	}

	if ascent == 0 {
		m := p.font_metrics(r.fonts, km.size, km.mono ? .Mono : .Sans, .Regular)
		ascent, descent = m.ascent, m.descent
	}
	lh := max(km.size * km.line, ascent + descent)
	// Centre the text's own extent in the line box, so a line with a big
	// superscript does not shove its neighbours around.
	base := ascent + (lh - (ascent + descent)) / 2

	append(
		&out.lines,
		Line {
			block = bi,
			start = from,
			end = to,
			vis_end = vis_end,
			fi = fi,
			fc = len(out.frags) - fi,
			w = total,
			h = lh,
			ascent = base,
			marker = -1,
			kind = d.blocks[bi].kind,
			image = -1,
			indent = len(out.lines) == 0 ? first_extra : 0,
		},
	)
}

// image_box is the on-page size of a picture: its natural size scaled to fit
// the column, and never taller than most of a page.
image_box :: proc(d: ^Doc, idx: i32, avail: f32, o: Reflow_Opts) -> (w, h: f32) {
	nw, nh := f32(0), f32(0)
	if idx >= 0 && int(idx) < len(d.images) {
		nw, nh = f32(d.images[idx].w), f32(d.images[idx].h)
	}
	if nw <= 0 || nh <= 0 {
		// Not decoded yet, or not decodable: reserve a modest box so the
		// page does not jump when it arrives.
		return min(avail, 220), 150
	}
	// In paged mode a picture must fit the page it is on, with room for the
	// space around it. In continuous mode there is no page, so the cap is a
	// generous multiple of the type size instead of nothing at all.
	max_h := o.page_h > 0 ? o.page_h * 0.88 : o.size * 24
	s := min(1, min(avail / nw, max_h / nh))
	return nw * s, nh * s
}

// ---------------------------------------------------------------------------
// Pass two: pagination
//
// Arithmetic only. No text is measured here, which is what makes a page turn
// cost nothing and a 900-block chapter paginate in microseconds.
// ---------------------------------------------------------------------------

@(private = "file")
layout_chapter :: proc(r: ^Reflow, d: ^Doc, ci: int, cl: ^Chapter_Layout) {
	clear(&cl.lines)
	clear(&cl.frags)
	clear(&cl.page_at)
	cl.pages = 0
	cl.height = 0
	r.wrapped = 0
	if ci < 0 || ci >= len(d.chapters) {
		append(&cl.page_at, 0)
		append(&cl.page_at, 0)
		cl.pages = 1
		return
	}
	ch := d.chapters[ci]
	r.gen += 1

	// --- wrap whatever is not already wrapped
	keys := make([]Wrap_Key, ch.count, context.temp_allocator)
	for k in 0 ..< ch.count {
		bi := ch.first + k
		avail := block_measure(d, bi, r.opts)
		key := block_key(d, bi, r.opts, avail)
		keys[k] = key
		if w, hit := &r.cache[key]; hit {
			w.seen = r.gen
			r.hits += 1
			continue
		}
		w := Wrap {
			lines = make([dynamic]Line, 0, 4),
			frags = make([dynamic]Frag, 0, 8),
			seen  = r.gen,
		}
		wrap_block(r, d, bi, &w, avail)
		r.lines_cached += len(w.lines)
		r.cache[key] = w
		r.wrapped += 1
		r.misses += 1
	}

	// --- pour onto pages
	page := 0
	y := f32(0)
	append(&cl.page_at, 0)
	prev_kind := Block_Kind.Para
	prev_list := List_Kind.None
	counters: [12]int

	for k in 0 ..< ch.count {
		bi := ch.first + k
		b := d.blocks[bi]
		km := kind_metrics(b.kind, r.opts)
		if b.scale > 0 {
			km.size *= b.scale
		}
		w, have := &r.cache[keys[k]]
		if !have || len(w.lines) == 0 {
			continue
		}

		// List numbering, restarted whenever the run of items is broken.
		marker := i32(-1)
		switch b.list {
		case .None:
			counters = {}
		case .Bullet:
			marker = 0
		case .Numbered:
			lvl := min(int(b.depth), len(counters) - 1)
			if prev_list != .Numbered {
				counters[lvl] = 0
			}
			if b.marker > 0 {
				counters[lvl] = int(b.marker)
			} else {
				counters[lvl] += 1
			}
			for j in lvl + 1 ..< len(counters) {
				counters[j] = 0
			}
			marker = i32(counters[lvl])
		}

		// Space above. It collapses at the top of a page, and between two
		// blocks of the same kind that should read as one thing.
		if len(cl.lines) > 0 && y > 0 {
			sb := (km.before + b.before) * km.size
			if b.kind == .Code && prev_kind == .Code {
				sb = 0
			} else if b.list != .None && prev_list == b.list {
				sb = 0
			}
			y += sb
		}
		if b.brk && len(cl.lines) > 0 {
			page += 1
			y = 0
			append(&cl.page_at, len(cl.lines))
		}

		// Keep-with-next for headings, orphan control for prose. Both look
		// ahead and break the page early; a block too tall to be helped is
		// left alone, since breaking would lose a page and gain nothing.
		if y > 0 && r.opts.page_h > 0 {
			need := w.lines[0].h
			switch b.kind {
			case .H1, .H2, .H3, .H4:
				need = km.after * km.size
				for ln in w.lines {
					need += ln.h
				}
				if k + 1 < ch.count {
					if nw, okn := &r.cache[keys[k + 1]]; okn && len(nw.lines) > 0 {
						need += nw.lines[0].h
					}
				}
			case .Para, .Quote, .Code, .Item:
				if len(w.lines) >= 2 {
					need = w.lines[0].h + w.lines[1].h
				}
			case .Image, .Rule:
				need = w.lines[0].h
			}
			if need <= r.opts.page_h && y + need > r.opts.page_h {
				page += 1
				y = 0
				append(&cl.page_at, len(cl.lines))
			}
		}

		base_frag := len(cl.frags)
		append(&cl.frags, ..w.frags[:])
		indent := block_indent(d, bi, r.opts)
		avail := max(40, r.opts.measure - indent)

		for src in w.lines {
			ln := src
			ln.fi = base_frag + src.fi
			if r.opts.page_h > 0 && y + ln.h > r.opts.page_h && y > 0 {
				page += 1
				y = 0
				append(&cl.page_at, len(cl.lines))
			}
			ln.page = page
			ln.y = y
			ln.marker = ln.first ? marker : -1

			inner := avail - ln.indent
			switch b.align {
			case .Left, .Justify:
				ln.x = indent + ln.indent
			case .Center:
				ln.x = indent + ln.indent + max(0, (inner - ln.w) / 2)
			case .Right:
				ln.x = indent + ln.indent + max(0, inner - ln.w)
			}
			if b.kind == .Image || b.kind == .Rule {
				ln.x = indent + max(0, (avail - ln.w) / 2)
			}

			// Justification: spread the slack over the inter-word gaps. The
			// last line of a paragraph is never justified, and neither is a
			// line whose slack is so large that the result would look worse
			// than a ragged edge.
			ln.gap = 0
			justify := r.opts.justify && b.align != .Center && b.align != .Right
			if b.align == .Justify {
				justify = true
			}
			if justify && !ln.last && b.kind != .Code && b.kind != .Image && b.kind != .Rule {
				gaps := 0
				for q in 0 ..< ln.fc {
					if cl.frags[ln.fi + q].gap_after && q != ln.fc - 1 {
						gaps += 1
					}
				}
				slack := inner - ln.w
				if gaps > 0 && slack > 0 && slack < inner * 0.22 {
					ln.gap = slack / f32(gaps)
				}
			}

			x := f32(0)
			for q in 0 ..< ln.fc {
				f := &cl.frags[ln.fi + q]
				f.x = x
				x += f.w
				if f.gap_after && q != ln.fc - 1 {
					x += ln.gap
				}
			}

			y += ln.h
			append(&cl.lines, ln)
		}

		sa := (km.after + b.after) * km.size
		if k + 1 < ch.count {
			nx := d.blocks[bi + 1]
			if b.kind == .Code && nx.kind == .Code {
				sa = 0
			} else if b.list != .None && nx.list == b.list {
				sa = 0.3 * km.size
			}
		}
		y += sa
		prev_kind = b.kind
		prev_list = b.list
	}

	cl.pages = page + 1
	append(&cl.page_at, len(cl.lines))
	cl.height = r.opts.page_h > 0 ? f32(page) * r.opts.page_h + y : y

	reflow_sweep(r, d)
}

// reflow_sweep keeps the wrap cache under a bound on cached *lines*, because
// that is what the memory actually is: a chapter of a long book is a few
// hundred blocks but a few thousand lines.
//
// It evicts least-recently-seen first and stops as soon as it is under the
// bound, rather than dropping everything that missed the last couple of
// layouts. The difference shows up exactly where it matters: after reading a
// long book end to end, making the type bigger and smaller again should still
// be free for the chapter you are *in*, and a sweep that cleared the whole
// cache every few chapters would make it cost a full re-wrap.
@(private = "file")
reflow_sweep :: proc(r: ^Reflow, d: ^Doc) {
	LIMIT :: 60000 // lines; about 7 MB of Line and Frag records
	TARGET :: 45000
	if r.lines_cached <= LIMIT {
		return
	}
	Victim :: struct {
		key:   Wrap_Key,
		seen:  u64,
		lines: int,
	}
	vs := make([dynamic]Victim, 0, len(r.cache), context.temp_allocator)
	for k, w in r.cache {
		if w.seen == r.gen {
			continue // in the chapter being laid out right now
		}
		append(&vs, Victim{key = k, seen = w.seen, lines = len(w.lines)})
	}
	slice.sort_by(vs[:], proc(a, b: Victim) -> bool {
		return a.seen < b.seen
	})
	for v in vs {
		if r.lines_cached <= TARGET {
			break
		}
		if w, found := &r.cache[v.key]; found {
			r.lines_cached -= len(w.lines)
			delete(w.lines)
			delete(w.frags)
		}
		delete_key(&r.cache, v.key)
	}
}

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------

// A reading position. The byte offset is into the *chapter*, not the page,
// which is what survives a change of font size.
Pos :: struct {
	chapter: int,
	block:   int,
	off:     int,
}

// layout_page_of finds the page a position falls on.
layout_page_of :: proc(cl: ^Chapter_Layout, block, off: int) -> int {
	for ln in cl.lines {
		if ln.block == block && off < ln.end {
			return ln.page
		}
		if ln.block > block {
			return ln.page
		}
	}
	return max(0, cl.pages - 1)
}

// layout_pos_at is the inverse: the first position on a page, which is what
// gets written to disk when the reader closes the book.
layout_pos_at :: proc(cl: ^Chapter_Layout, page: int) -> (block, off: int) {
	if page < 0 || page >= len(cl.page_at) - 1 {
		return -1, 0
	}
	i := cl.page_at[page]
	if i >= len(cl.lines) {
		return -1, 0
	}
	return cl.lines[i].block, cl.lines[i].start
}

// layout_page_lines is the slice of lines on one page.
layout_page_lines :: proc(cl: ^Chapter_Layout, page: int) -> []Line {
	if page < 0 || page + 1 >= len(cl.page_at) {
		return nil
	}
	a := clamp(cl.page_at[page], 0, len(cl.lines))
	b := clamp(cl.page_at[page + 1], a, len(cl.lines))
	return cl.lines[a:b]
}
