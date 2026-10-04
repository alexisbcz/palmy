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
	para:       int,
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
	hash:   u64,
	nbytes: int,
	nruns:  int,
	kind:   Para_Kind,
	list:   List_Kind,
	depth:  int,
}

Para_Cache :: struct {
	lines: [dynamic]Line,
	frags: [dynamic]Frag,
	seen:  u64,
}

Layout :: struct {
	lines:   [dynamic]Line,
	frags:   [dynamic]Frag,
	// Every paragraph's text, concatenated once, so measurement and drawing
	// both work on plain strings instead of walking runs.
	text:    [dynamic]u8,
	para_at: [dynamic]int,
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
	delete(lay.para_at)
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
para_key :: proc(pa: ^Paragraph) -> Cache_Key {
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
	}
}

para_string :: proc(lay: ^Layout, pi: int) -> string {
	if pi < 0 || pi >= len(lay.para_at) {
		return ""
	}
	a := lay.para_at[pi]
	b := pi + 1 < len(lay.para_at) ? lay.para_at[pi + 1] : len(lay.text)
	return string(lay.text[a:b])
}

line_text :: proc(lay: ^Layout, li: int) -> string {
	l := lay.lines[li]
	s := para_string(lay, l.para)
	return s[clamp(l.start, 0, len(s)):clamp(l.end, 0, len(s))]
}

frag_text :: proc(lay: ^Layout, l: Line, f: Frag) -> string {
	s := para_string(lay, l.para)
	return s[clamp(f.start, 0, len(s)):clamp(f.end, 0, len(s))]
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

layout_doc :: proc(lay: ^Layout, d: ^Doc, fonts: ^p.Fonts) {
	// One copy of the whole document's text, so every later lookup is a slice.
	clear(&lay.text)
	clear(&lay.para_at)
	for pi in 0 ..< len(d.paras) {
		append(&lay.para_at, len(lay.text))
		para_append_text(&d.paras[pi], &lay.text)
	}

	// Pass one: wrap whatever changed.
	lay.gen += 1
	lay.wrapped = 0
	keys := make([]Cache_Key, len(d.paras), context.temp_allocator)
	for pi in 0 ..< len(d.paras) {
		pa := &d.paras[pi]
		k := para_key(pa)
		keys[pi] = k
		if c, hit := &lay.cache[k]; hit {
			c.seen = lay.gen
			continue
		}
		km := kind_metrics(pa.kind)
		build_segs(lay, pa)
		avail := max(40, CONTENT_W - para_indent(pa, km))
		c := Para_Cache {
			lines = make([dynamic]Line, 0, 4),
			frags = make([dynamic]Frag, 0, 16),
			seen  = lay.gen,
		}
		wrap_paragraph(lay, &c, fonts, km, para_string(lay, pi), avail)
		lay.cache[k] = c
		lay.wrapped += 1
	}

	// Pass two: pour the wrapped paragraphs onto pages. This is arithmetic
	// only — no text is measured here, so it stays cheap over a long document.
	clear(&lay.lines)
	clear(&lay.frags)
	page := 0
	y := f32(0)
	counters: [12]int
	prev_list := List_Kind.None
	prev_depth := -1

	for pi in 0 ..< len(d.paras) {
		pa := &d.paras[pi]
		km := kind_metrics(pa.kind)
		c, have := &lay.cache[keys[pi]]
		if !have {
			continue
		}

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

		// Two typographic rules that make the difference between a paginated
		// document and a column of text chopped every 931 pixels:
		//
		//   keep with next — a heading never sits alone at the foot of a page
		//   orphan control — a paragraph never leaves one line behind
		//
		// Both look ahead and break the page *early*. A block too tall to help
		// is left alone, or the break would gain nothing and lose a page.
		if y > 0 && len(c.lines) > 0 {
			need := c.lines[0].h
			switch pa.kind {
			case .H1, .H2, .H3:
				need = km.after
				for src in c.lines {
					need += src.h
				}
				if pi + 1 < len(d.paras) {
					if nc, okn := &lay.cache[keys[pi + 1]]; okn && len(nc.lines) > 0 {
						need += nc.lines[0].h
					}
				}
			case .Body, .Quote, .Code:
				if len(c.lines) >= 2 {
					need = c.lines[0].h + c.lines[1].h
				}
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
			l.fi = base_frag + src.fi
			if y + l.h > CONTENT_H && y > 0 {
				page += 1
				y = 0
			}
			l.page = page
			l.y = y
			l.indent = indent
			l.marker = l.first ? marker : -1

			switch pa.align {
			case .Left, .Justify:
				l.x = indent
			case .Center:
				l.x = indent + max(0, (avail - l.w) / 2)
			case .Right:
				l.x = indent + max(0, avail - l.w)
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
	}

	lay.pages = page + 1
	lay.height = f32(page) * CONTENT_H + y

	// Drop entries nothing has asked for in a while. A few generations of
	// slack means an undo straight after an edit still hits the cache.
	if len(lay.cache) > 4 * len(d.paras) + 64 {
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
	best := -1
	for li in 0 ..< len(lay.lines) {
		l := lay.lines[li]
		if l.para != q.para {
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
