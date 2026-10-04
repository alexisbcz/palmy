package main

// Structure recovery: word boxes in, a readable document out.
//
// This is the part that decides whether the output is a book or a wall of
// text. OCR hands over words and rectangles and no structure at all;
// everything a reader needs — where the columns are, where a paragraph ends,
// which line is a heading, which line is a running header that should not be
// in the text at all — has to be inferred from geometry.
//
// Seven passes, in this order, because each depends on the one before:
//
//   1. columns   x-projection; a vertical band no word touches is a gutter
//   2. lines     greedy chaining left to right, which tolerates page skew
//   3. metrics   a median glyph height per line, and a line pitch per column
//   4. furniture running headers and footers, found by repetition across pages
//   5. headings  relative size against the document's body size
//   6. paragraphs line gaps, first-line indents and short final lines
//   7. hyphens   a trailing hyphen joined to the next line's first word
//
// tesseract's own block and paragraph numbers are not used anywhere here. It
// has a page segmenter and it is a decent one, but if the pipeline leaned on
// it then a backend that returns no blocks would have no structure, and the
// column detector would never run on the page that needs it.
//
// Every threshold below is expressed as a multiple of the page's own median
// glyph height rather than in pixels, so a 150 dpi scan and a 600 dpi scan
// behave the same.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Tunables
//
// These were fitted against the generated corpus in corpus.odin, where the
// right answer is known exactly. They are named rather than inlined so the
// self-test can report which case each one decides.
// ---------------------------------------------------------------------------

// A gutter must be at least this fraction of the inked width of the page.
GUTTER_MIN_FRAC :: 0.035
// ...and this many median glyph heights wide. This is the same number as
// GAP_MAX_EM below, and it has to be: a gap the line grouper is willing to
// chain across cannot also be a column separator, or the two passes disagree
// about the same pixels.
GUTTER_MIN_EM :: 2.5
// The line grouper will not chain two words further apart than this. Word
// spacing at a 30-pixel glyph height is eight or ten pixels; even badly
// stretched justification stays under one em. Two and a half is generous for
// a space and far too small for a gutter, which is what makes the first,
// column-blind pass able to tell one line from two side by side.
GAP_MAX_EM :: 2.5
// Each side of a gutter needs this many lines before it counts as a column.
COLUMN_MIN_LINES :: 3
// A word joins the line to its left when their centres are within this many
// median glyph heights.
LINE_TOL_EM :: 0.55
// A vertical gap larger than this multiple of the local line pitch ends a
// paragraph.
PARA_GAP :: 1.55
// A first line indented by more than this many median glyph heights starts a
// paragraph.
PARA_INDENT_EM :: 0.9
// A line ending this far short of its own measure is a last line. Only used
// when a column offers no other signal — see `Para_Mode`. Fitted against the
// corpus: ragged-right prose has mid-paragraph lines down to about 85% of the
// measure, and real last lines are mostly under 60%, so the cut goes in the
// gap between them. The cost is stated rather than hidden: a paragraph whose
// last line runs past 70% of the measure is merged with the next one.
PARA_SHORT_FRAC :: 0.70
// Lines within this ratio of each other are the same size, for the purpose of
// working out what the measure is.
SAME_SIZE :: 1.3
// Heading size thresholds, as a ratio to the body size.
HEAD_MIN :: 1.22
HEAD_H2 :: 1.5
HEAD_H1 :: 1.9
// A heading is short. Anything longer is large-print body text.
HEAD_MAX_WORDS :: 16
// Running headers and footers live within this fraction of the page edge.
FURNITURE_ZONE :: 0.1
// ...and are at most this many words.
FURNITURE_MAX_WORDS :: 14

// ---------------------------------------------------------------------------
// A recognised line
// ---------------------------------------------------------------------------

Line :: struct {
	words:  [dynamic]Ocr_Word, // borrowed: text is owned by the Ocr_Result
	page:   int,
	col:    int,
	x0, x1: int,
	y0, y1: int,
	size:   f32, // median word height
	conf:   f32, // mean confidence
	// Set by the furniture pass.
	drop:   bool,
	why:    string, // why it was dropped; borrowed from a literal
}

line_cy :: proc(l: Line) -> f32 {return f32(l.y0 + l.y1) * 0.5}

line_text :: proc(l: Line, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for w, i in l.words {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, w.text)
	}
	return strings.to_string(b)
}

Page_Layout :: struct {
	page:          int,
	width, height: int,
	columns:       int,
	lines:         [dynamic]Line,
	em:            f32, // the page's median glyph height
	gutters:       [dynamic][2]int, // for the UI overlay and the self-test
}

layout_destroy :: proc(pl: ^Page_Layout) {
	for &l in pl.lines {
		delete(l.words)
	}
	delete(pl.lines)
	delete(pl.gutters)
	pl^ = {}
}

// ---------------------------------------------------------------------------
// 1. Columns
//
// Project every word box onto the x axis. A single-column page covers its
// whole text width, because successive lines break in different places; a
// two-column page leaves a band that no word on any line touches. That band is
// the gutter, and it is the only reliable signal there is — a fixed "split the
// page in half" rule gets a page with a full-width title wrong, and a
// whitespace-variance measure gets a page with a figure wrong.
//
// Three guards stop a short page from inventing a gutter out of a coincidence:
// the band has to be wide in absolute terms, each side has to hold several
// lines, and the two sides have to overlap vertically — real columns run
// alongside each other, whereas text either side of a figure does not.
// ---------------------------------------------------------------------------

median_height :: proc(words: []Ocr_Word) -> f32 {
	if len(words) == 0 {
		return 1
	}
	hs := make([]int, len(words), context.temp_allocator)
	for w, i in words {
		hs[i] = w.h
	}
	slice.sort(hs)
	return f32(hs[len(hs) / 2])
}

// find_gutters returns the x ranges no word touches, ordered left to right,
// that are wide enough and tall enough to be column separators.
find_gutters :: proc(words: []Ocr_Word, page_w: int, em: f32, allocator := context.allocator) -> [][2]int {
	out := make([dynamic][2]int, allocator)
	if len(words) < COLUMN_MIN_LINES * 2 || page_w <= 0 {
		return out[:]
	}
	cover := make([]bool, page_w, context.temp_allocator)
	ink_lo, ink_hi := page_w, 0
	for w in words {
		lo := max(0, w.x)
		hi := min(page_w, w.x + w.w)
		for x in lo ..< hi {
			cover[x] = true
		}
		ink_lo = min(ink_lo, lo)
		ink_hi = max(ink_hi, hi)
	}
	if ink_hi <= ink_lo {
		return out[:]
	}
	ink_w := ink_hi - ink_lo
	min_gap := max(int(f32(ink_w) * GUTTER_MIN_FRAC), int(em * GUTTER_MIN_EM), 4)

	x := ink_lo
	for x < ink_hi {
		if cover[x] {
			x += 1
			continue
		}
		start := x
		for x < ink_hi && !cover[x] {
			x += 1
		}
		if x - start < min_gap {
			continue
		}
		// Each side must hold enough text, and the two sides must share
		// vertical space.
		lmin, lmax, lcount := 1 << 30, -(1 << 30), 0
		rmin, rmax, rcount := 1 << 30, -(1 << 30), 0
		for w in words {
			if word_right(w) <= start {
				lcount += 1
				lmin = min(lmin, w.y)
				lmax = max(lmax, word_bottom(w))
			} else if w.x >= x {
				rcount += 1
				rmin = min(rmin, w.y)
				rmax = max(rmax, word_bottom(w))
			}
		}
		if lcount < COLUMN_MIN_LINES || rcount < COLUMN_MIN_LINES {
			continue
		}
		overlap := min(lmax, rmax) - max(lmin, rmin)
		span := max(lmax - lmin, rmax - rmin)
		if span <= 0 || f32(overlap) / f32(span) < 0.5 {
			continue
		}
		append(&out, [2]int{start, x})
	}
	return out[:]
}

// column_of maps an x position to a column index given the gutters.
column_of :: proc(gutters: [][2]int, cx: f32) -> int {
	for g, i in gutters {
		if cx < f32(g[0]) {
			return i
		}
	}
	return len(gutters)
}

// ---------------------------------------------------------------------------
// 2. Lines
//
// Words are sorted by x and chained left to right: each word joins whichever
// open line's rightmost word sits closest to it vertically, within tolerance.
//
// Chaining locally rather than bucketing by absolute y is what makes a skewed
// page work. A page scanned two degrees off square drifts by more than a
// glyph height across a 700-pixel line, so a y bucket fixed at the line's
// start has lost the line by its end; comparing each word only against its
// immediate left neighbour follows the drift instead.
// ---------------------------------------------------------------------------

build_lines :: proc(
	words: []Ocr_Word,
	cols: []int,
	em: f32,
	page: int,
	out: ^[dynamic]Line,
	line_of: []int = nil,
) {
	if len(words) == 0 {
		return
	}
	// Sort indices by x, then y. A procedure literal cannot capture, so the
	// sort key carries the index with it.
	Key :: struct {
		x, y, i: int,
	}
	keys := make([]Key, len(words), context.temp_allocator)
	for w, i in words {
		keys[i] = {w.x, w.y, i}
	}
	slice.sort_by(keys, proc(a, b: Key) -> bool {
		if a.x != b.x {return a.x < b.x}
		return a.y < b.y
	})

	tol := max(em * LINE_TOL_EM, 2)
	max_gap := max(em * GAP_MAX_EM, 8)
	open_start := len(out)

	for k in keys {
		w := words[k.i]
		col := cols[k.i]
		best := -1
		best_d := f32(1e30)
		for li in open_start ..< len(out) {
			l := &out[li]
			if l.col != col {
				continue
			}
			last := l.words[len(l.words) - 1]
			// A word that starts well to the left of the line's current right
			// edge is on a different line, whatever its y says.
			if w.x + w.w / 2 < last.x {
				continue
			}
			// ...and so is a word separated from it by more than a space.
			// Without this, two columns whose rows happen to align become one
			// line each, every line looks full width, and the gutter the next
			// pass is looking for has been covered over by the pass before it.
			if f32(w.x - l.x1) > max_gap {
				continue
			}
			d := abs(word_cy(w) - word_cy(last))
			if d <= tol && d < best_d {
				best, best_d = li, d
			}
		}
		if best >= 0 {
			l := &out[best]
			append(&l.words, w)
			l.x1 = max(l.x1, word_right(w))
			l.y0 = min(l.y0, w.y)
			l.y1 = max(l.y1, word_bottom(w))
			if line_of != nil {
				line_of[k.i] = best
			}
			continue
		}
		nl := Line {
			words = make([dynamic]Ocr_Word),
			page  = page,
			col   = col,
			x0    = w.x,
			x1    = word_right(w),
			y0    = w.y,
			y1    = word_bottom(w),
		}
		append(&nl.words, w)
		if line_of != nil {
			line_of[k.i] = len(out)
		}
		append(out, nl)
	}

	// 3. Per-line metrics.
	for li in open_start ..< len(out) {
		l := &out[li]
		slice.sort_by(l.words[:], proc(a, b: Ocr_Word) -> bool {return a.x < b.x})
		l.size = median_height(l.words[:])
		sum := f32(0)
		n := 0
		for w in l.words {
			if w.conf >= 0 {
				sum += w.conf
				n += 1
			}
		}
		l.conf = n > 0 ? sum / f32(n) : -1
	}
}

// sort_reading_order puts the lines in the order a human reads them: any
// full-width line that spans the columns first (column -1), then each column
// left to right, each top to bottom.
sort_reading_order :: proc(lines: ^[dynamic]Line) {
	slice.sort_by(lines[:], proc(a, b: Line) -> bool {
		if a.col != b.col {return a.col < b.col}
		return line_cy(a) < line_cy(b)
	})
}

// A line at least this wide, as a fraction of the page's inked width, is
// treated as spanning the columns rather than belonging to one.
SPAN_FRAC :: 0.72

// analyse_page runs passes 1 through 3 for one page.
//
// Columns are found in two rounds, which is what a full-width title over two
// columns forces. A single x-projection over every word would find no gutter
// at all on such a page, because the title's own words cover the gap — and a
// page with a banner headline is exactly the page where getting the columns
// wrong is most visible. So: group the lines once with no columns at all, set
// aside the lines that run nearly the full width of the text block, project
// only what is left, and group again. The set-aside lines get column -1 and
// are read first.
analyse_page :: proc(words: []Ocr_Word, page, width, height: int) -> Page_Layout {
	pl := Page_Layout {
		page   = page,
		width  = width,
		height = height,
		lines  = make([dynamic]Line),
	}
	pl.em = median_height(words)
	if len(words) == 0 {
		pl.gutters = make([dynamic][2]int)
		pl.columns = 1
		return pl
	}

	cols := make([]int, len(words), context.temp_allocator)
	line_of := make([]int, len(words), context.temp_allocator)

	// Round one: no columns.
	first := make([dynamic]Line, context.temp_allocator)
	build_lines(words, cols, pl.em, page, &first, line_of)
	defer for &l in first {
		delete(l.words)
	}

	ink_lo, ink_hi := 1 << 30, 0
	for w in words {
		ink_lo = min(ink_lo, w.x)
		ink_hi = max(ink_hi, word_right(w))
	}
	span_min := f32(ink_hi - ink_lo) * SPAN_FRAC

	span := make([]bool, len(words), context.temp_allocator)
	narrow := make([dynamic]Ocr_Word, 0, len(words), context.temp_allocator)
	for i in 0 ..< len(words) {
		li := line_of[i]
		if li >= 0 && li < len(first) && f32(first[li].x1 - first[li].x0) >= span_min {
			span[i] = true
			continue
		}
		append(&narrow, words[i])
	}

	gs := find_gutters(narrow[:], width, pl.em, context.temp_allocator)
	pl.gutters = make([dynamic][2]int)
	append(&pl.gutters, ..gs)
	pl.columns = len(gs) + 1

	// Round two, with the columns the projection found.
	for i in 0 ..< len(words) {
		cols[i] = span[i] && len(gs) > 0 ? -1 : column_of(gs, word_cx(words[i]))
	}
	build_lines(words, cols, pl.em, page, &pl.lines)
	sort_reading_order(&pl.lines)
	return pl
}

// ---------------------------------------------------------------------------
// 4. Running headers and footers
//
// A page number, a book title at the top of every recto, a chapter name in the
// footer: all of it is furniture, it is not the text, and leaving it in makes
// an EPUB unreadable because it lands mid-sentence in reflowed text.
//
// Repetition is the signal. A line in the top or bottom tenth of the page,
// short, whose text repeats across pages, is furniture. The comparison is
// against a normalised form with every digit collapsed to `#`, so "Page 3" and
// "Page 4" are recognised as the same running footer — which is the whole
// difficulty, since the one thing that varies is the only thing a naive
// comparison looks at.
//
// A single-page document has no repetition to measure, so nothing is dropped
// from it. That is the right answer: with one page there is no way to tell a
// header from a title.
// ---------------------------------------------------------------------------

furniture_key :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in text {
		switch {
		case r >= '0' && r <= '9':
			strings.write_byte(&b, '#')
		case r >= 'A' && r <= 'Z':
			strings.write_rune(&b, r + 32)
		case r >= 'a' && r <= 'z':
			strings.write_rune(&b, r)
		case r == ' ':
			strings.write_byte(&b, ' ')
		case:
		// punctuation dropped: OCR is least reliable on it
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// key_similar compares two normalised furniture keys loosely.
//
// Exact comparison is not enough, and finding that out took a corpus run: the
// footer "Page 1 of 3" at a small size came back from tesseract as
// "Page 10of 3", whose key is `page ##of #` and not `page # of #`. One page's
// footer therefore did not match the other two, and survived into the text.
//
// A page footer is the smallest, most reliably mangled text on a page, so the
// match allows an edit distance of a quarter of the key's length. That is
// loose enough to absorb a lost space or a misread digit and far too tight to
// join two different headers, which differ in most of their characters.
key_similar :: proc(a, b: string) -> bool {
	if a == b {
		return true
	}
	n := max(len(a), len(b))
	if n == 0 {
		return true
	}
	// A length difference bigger than the budget cannot possibly close.
	budget := max(1, n / 4)
	if abs_int(len(a) - len(b)) > budget {
		return false
	}
	return edit_distance(runes_of(a), runes_of(b)) <= budget
}

abs_int :: proc(v: int) -> int {
	return v < 0 ? -v : v
}

// mark_furniture sets `drop` on every running header and footer across a whole
// set of pages. It returns how many lines it removed, and appends a note
// naming each distinct one.
mark_furniture :: proc(pages: []Page_Layout, d: ^Doc, body: f32) -> int {
	if len(pages) < 2 {
		return 0
	}
	Cand :: struct {
		key:   string,
		top:   bool,
		pages: map[int]bool,
		hits:  [dynamic][2]int, // page index, line index
	}
	cands := make([dynamic]^Cand, 0, 8, context.temp_allocator)
	defer for c in cands {
		delete(c.pages)
		delete(c.hits)
	}

	for &pl, pi in pages {
		if pl.height <= 0 {
			continue
		}
		zone := f32(pl.height) * FURNITURE_ZONE
		for &l, li in pl.lines {
			if len(l.words) == 0 || len(l.words) > FURNITURE_MAX_WORDS {
				continue
			}
			// A running head is set small. A title page's title is set large
			// and is often *the same words*, which is how a five-page scan
			// lost its book title: the title at the top of page one matched
			// the running head on pages three to five and was dropped with
			// them. Size is what tells the two apart.
			if body > 0 && l.size > body * HEAD_MIN {
				continue
			}
			top := f32(l.y0) <= zone
			bot := f32(l.y1) >= f32(pl.height) - zone
			if !top && !bot {
				continue
			}
			key := furniture_key(line_text(l, context.temp_allocator), context.temp_allocator)
			if len(key) < 2 {
				continue
			}
			found: ^Cand
			for c in cands {
				if c.top == top && key_similar(c.key, key) {
					found = c
					break
				}
			}
			if found == nil {
				found = new(Cand, context.temp_allocator)
				found.key = key
				found.top = top
				found.pages = make(map[int]bool)
				found.hits = make([dynamic][2]int)
				append(&cands, found)
			}
			found.pages[pl.page] = true
			append(&found.hits, [2]int{pi, li})
		}
	}

	need := max(2, (len(pages) + 1) / 2)
	removed := 0
	for c in cands {
		if len(c.pages) < need {
			continue
		}
		for hit in c.hits {
			l := &pages[hit[0]].lines[hit[1]]
			if l.drop {
				continue
			}
			l.drop = true
			l.why = c.top ? "running header" : "running footer"
			removed += 1
		}
		if d != nil {
			doc_note(
				d,
				"dropped a running %s from %d of %d pages: %q",
				c.top ? "header" : "footer",
				len(c.pages),
				len(pages),
				c.key,
			)
		}
	}
	return removed
}

// ---------------------------------------------------------------------------
// 5. Headings
//
// Relative size, and nothing else. An absolute point size means nothing on a
// scan whose dpi is unknown, so the document's own median glyph height is the
// baseline and a heading is a line measurably taller than it.
//
// The body size is the median over *lines weighted by word count*, not over
// lines: a page with eight one-word headings and three long paragraphs has
// more heading lines than body lines, and an unweighted median would then call
// the body text small and the headings normal.
// ---------------------------------------------------------------------------

body_size :: proc(pages: []Page_Layout) -> f32 {
	heights := make([dynamic]f32, 0, 256, context.temp_allocator)
	for pl in pages {
		for l in pl.lines {
			if l.drop {
				continue
			}
			for _ in 0 ..< len(l.words) {
				append(&heights, l.size)
			}
		}
	}
	if len(heights) == 0 {
		return 1
	}
	slice.sort(heights[:])
	return heights[len(heights) / 2]
}

heading_level :: proc(size, body: f32, words: int) -> int {
	if body <= 0 || words > HEAD_MAX_WORDS {
		return 0
	}
	r := size / body
	switch {
	case r >= HEAD_H1:
		return 1
	case r >= HEAD_H2:
		return 2
	case r >= HEAD_MIN:
		return 3
	}
	return 0
}

// ---------------------------------------------------------------------------
// 6 and 7. Paragraphs and hyphens
//
// Within one column, consecutive lines of body text belong to the same
// paragraph unless the geometry says otherwise. Three signals, any of which
// breaks:
//
//   * a vertical gap more than 1.55x the local line pitch — a blank line;
//   * a first-line indent: this line starts more than ~1em right of the
//     paragraph's left edge;
//   * the previous line stopped short of the column's right edge *and* this
//     line starts at the left edge — the classic end-of-paragraph shape.
//
// The third is the one that earns its keep on flush-left text with no indents
// and no blank lines, where the only evidence a paragraph ended is that its
// last line was short. It is also the one that misfires, on a paragraph whose
// last line happens to fill the measure; that failure mode merges two
// paragraphs, which is a readability problem and not a correctness one.
//
// The hyphen join happens as lines are appended, because that is the only
// point at which both halves of the broken word are in hand. A trailing
// hyphen is dropped and the two fragments are closed up when the next line
// starts lowercase; a capital after the break is left alone, because
// "Franco-\nGerman" is a compound and not a break.
// ---------------------------------------------------------------------------

// line_pitch is the column's body line spacing, taken as a **low percentile**
// of the gaps rather than the median.
//
// The median is the obvious choice and it is wrong. A column is mostly body
// lines and a few paragraph gaps, so the median is near the body pitch — until
// the page mixes type sizes, at which point the median lands between two
// different body pitches and is larger than the small text's spacing. Every
// paragraph gap in the small text then looks ordinary, and the page comes out
// as one paragraph. Measured on the corpus: a three-paragraph page collapsed
// to one.
//
// Filtering the gaps by type size first was the first attempt and it is worse,
// because a line's measured size is the median height of its words and that
// swings by a quarter depending on whether the line happens to contain a
// descender. The low percentile needs no size estimate at all: paragraph gaps
// are by definition the *large* gaps, so anything near the bottom of the
// distribution is a body line, whichever size it was set in.
PITCH_PERCENTILE :: 0.30

// ends_with_hyphen reports a line-final hyphen and the word without it.
//
// Four codepoints count: the ASCII hyphen-minus, U+2010 HYPHEN, U+2011
// NON-BREAKING HYPHEN and U+00AD SOFT HYPHEN. A recogniser picks whichever its
// language model prefers, and a reader that only knows about the ASCII one
// leaves a hyphen in the middle of a word in every other case.
ends_with_hyphen :: proc(s: string) -> (stem: string, yes: bool) {
	if len(s) < 2 {
		return s, false
	}
	for suffix in ([?]string{"-", "\u2010", "\u00ad", "\u2011"}) {
		if strings.has_suffix(s, suffix) {
			st := s[:len(s) - len(suffix)]
			if len(st) < 1 {
				return s, false
			}
			return st, true
		}
	}
	return s, false
}

// starts_lower is the other half of the hyphen test. "weather-\nvane" is one
// word broken in two; "Franco-\nGerman" is a compound that keeps its hyphen,
// and the capital is the only thing that distinguishes them.
starts_lower :: proc(s: string) -> bool {
	for r in s {
		return r >= 'a' && r <= 'z'
	}
	return false
}

line_pitch :: proc(lines: []Line, from, to: int) -> f32 {
	gaps := make([dynamic]f32, 0, 32, context.temp_allocator)
	prev := -1
	for i in from ..< to {
		if lines[i].drop || len(lines[i].words) == 0 {
			continue
		}
		if prev >= 0 {
			g := line_cy(lines[i]) - line_cy(lines[prev])
			if g > 0 {
				append(&gaps, g)
			}
		}
		prev = i
	}
	if len(gaps) == 0 {
		return 0
	}
	slice.sort(gaps[:])
	at := int(f32(len(gaps)) * PITCH_PERCENTILE)
	return gaps[clamp(at, 0, len(gaps) - 1)]
}

Para :: struct {
	b:       strings.Builder,
	page:    int,
	col:     int,
	size:    f32,
	conf:    f32,
	n:       int,
	hyphen:  bool, // the text so far ends mid-word
	left:    int,
	right:   int,
	heading: int, // 0 for body, else the level
}

// Para_Mode is which signal a column actually uses to mark its paragraphs.
//
// This is chosen per column rather than fixed, because the three signals are
// mutually exclusive in practice and applying all three at once is what makes
// a paragraph detector unreliable. A book that indents does not also leave
// blank lines; a document that leaves blank lines does not also indent; and
// the short-last-line rule is what is left when a document does neither.
//
// Running the short-line rule on a document that *does* leave blank lines is
// the specific failure this fixes: ragged-right prose has short lines in the
// middle of paragraphs all the time, and every one of them became a paragraph
// break. Measured on the corpus, that split a six-block page into seven and a
// three-block page into eight. Choosing the signal first costs one pass over
// the column and makes the rule that is weakest apply only where it is the
// only thing available.
Para_Mode :: enum u8 {
	Gap, // a blank line between paragraphs
	Indent, // a first-line indent, with no blank line
	Short, // neither: a paragraph ends when its last line falls short
}

para_mode_name :: proc(m: Para_Mode) -> string {
	switch m {
	case .Gap:
		return "blank lines"
	case .Indent:
		return "first-line indents"
	case .Short:
		return "short last lines"
	}
	return ""
}

// column_mode looks at the column once and decides which signal it uses.
column_mode :: proc(lines: []Line, from, to: int, pitch, body: f32, left: int) -> Para_Mode {
	gaps := 0
	indents := 0
	prev := -1
	for i in from ..< to {
		if lines[i].drop || len(lines[i].words) == 0 {
			continue
		}
		if prev >= 0 && line_cy(lines[i]) - line_cy(lines[prev]) > pitch * PARA_GAP {
			gaps += 1
		}
		if f32(lines[i].x0 - left) > body * PARA_INDENT_EM {
			indents += 1
		}
		prev = i
	}
	if gaps > 0 {
		return .Gap
	}
	if indents > 0 {
		return .Indent
	}
	return .Short
}

// measure_at is the width of the longest line in the column set at roughly
// this size. It has to be size-aware: a page carrying 24-pixel and 40-pixel
// paragraphs has two different measures, and comparing a small paragraph's
// lines against the large one's makes every one of them look like a last
// line.
measure_at :: proc(lines: []Line, from, to: int, size: f32) -> int {
	best := 0
	for i in from ..< to {
		l := lines[i]
		if l.drop || len(l.words) == 0 || l.size <= 0 {
			continue
		}
		r := l.size / size
		if r > SAME_SIZE || r < 1 / SAME_SIZE {
			continue
		}
		best = max(best, l.x1 - l.x0)
	}
	return best
}

// recover is the whole pipeline: pages of lines in, a Doc out.
recover :: proc(pages: []Page_Layout, d: ^Doc) {
	// The body size is measured twice: once before the furniture pass, because
	// that pass needs to know what "small" means, and once after, because
	// dropping the furniture changes the distribution it is measured from.
	mark_furniture(pages, d, body_size(pages))
	body := body_size(pages)
	doc_note(d, "body glyph height measured at %.1f px", body)

	hyphens := 0
	para_breaks := 0
	modes: [Para_Mode]int

	for pl, pi in pages {
		if pi > 0 {
			doc_add(d, .Page_Break, "", pl.page, 0)
		}
		// Column ranges inside this page's line list, which build_lines
		// already sorted by (col, y).
		start := 0
		for start < len(pl.lines) {
			col := pl.lines[start].col
			end := start
			for end < len(pl.lines) && pl.lines[end].col == col {
				end += 1
			}
			pitch := line_pitch(pl.lines[:], start, end)
			if pitch <= 0 {
				pitch = body * 1.6
			}
			// The column's measure: the widest line in it.
			// The left edge is taken over body lines only. A full-width
			// heading can start left of the text it introduces, and letting it
			// set the margin would make every body line look indented.
			left := 1 << 30
			for i in start ..< end {
				l := pl.lines[i]
				if l.drop || len(l.words) == 0 || l.size > body * HEAD_MIN {
					continue
				}
				left = min(left, l.x0)
			}
			if left == 1 << 30 {
				for i in start ..< end {
					if !pl.lines[i].drop && len(pl.lines[i].words) > 0 {
						left = min(left, pl.lines[i].x0)
					}
				}
			}
			if left == 1 << 30 {
				left = 0
			}
			mode := column_mode(pl.lines[:], start, end, pitch, body, left)
			modes[mode] += 1
			if left == 1 << 30 {
				left = 0
			}

			cur: Para
			cur.b = strings.builder_make(context.temp_allocator)
			open := false
			prev_i := -1
			for i in start ..< end {
				l := pl.lines[i]
				if l.drop || len(l.words) == 0 {
					continue
				}
				txt := line_text(l, context.temp_allocator)
				lvl := heading_level(l.size, body, len(l.words))

				brk := !open
				if open {
					switch {
					case lvl != cur.heading:
						// A heading never continues a paragraph, and a
						// paragraph never continues a heading.
						brk = true
					case prev_i >= 0 &&
					     line_cy(l) - line_cy(pl.lines[prev_i]) > pitch * PARA_GAP:
						brk = true
						para_breaks += 1
					case f32(l.x0 - left) > body * PARA_INDENT_EM:
						brk = true
						para_breaks += 1
					case mode == .Short && prev_i >= 0 && short_last(pl.lines[:], start, end, prev_i, l, left, body):
						brk = true
						para_breaks += 1
					}
				}

				if brk {
					para_flush(d, &cur, &open)
					cur = Para {
						b       = strings.builder_make(context.temp_allocator),
						page    = l.page,
						col     = l.col,
						heading = lvl,
						left    = l.x0,
					}
					open = true
				}

				// Append this line's text, honouring a pending hyphen.
				if strings.builder_len(cur.b) > 0 {
					if cur.hyphen {
						// closed up: no separator at all
					} else {
						strings.write_byte(&cur.b, ' ')
					}
				}
				cur.hyphen = false

				stem, hyph := ends_with_hyphen(txt)
				next_lower := false
				for j in i + 1 ..< end {
					if pl.lines[j].drop || len(pl.lines[j].words) == 0 {
						continue
					}
					next_lower = starts_lower(pl.lines[j].words[0].text)
					break
				}
				if hyph && next_lower && i + 1 < end {
					strings.write_string(&cur.b, stem)
					cur.hyphen = true
					hyphens += 1
				} else {
					strings.write_string(&cur.b, txt)
				}

				// Running metrics: the largest size wins, so a heading whose
				// first word was clipped is still sized by its tallest line.
				cur.size = max(cur.size, l.size)
				if l.conf >= 0 {
					cur.conf = (cur.conf * f32(cur.n) + l.conf) / f32(cur.n + 1)
					cur.n += 1
				}
				cur.right = max(cur.right, l.x1)
				prev_i = i
			}
			para_flush(d, &cur, &open)
			start = end
		}
	}

	if hyphens > 0 {
		doc_note(d, "joined %d word%s broken across a line end", hyphens, hyphens == 1 ? "" : "s")
	}
	best := Para_Mode.Gap
	for m in Para_Mode {
		if modes[m] > modes[best] {
			best = m
		}
	}
	if modes[best] > 0 {
		doc_note(
			d,
			"paragraphs were found by %s, which is the signal this document uses (%d of %d columns)",
			para_mode_name(best),
			modes[best],
			modes[.Gap] + modes[.Indent] + modes[.Short],
		)
	}
	cols := 0
	for pl in pages {
		cols = max(cols, pl.columns)
	}
	if cols > 1 {
		doc_note(d, "found %d columns; text was read column by column, not across", cols)
	}
}

// short_last is the weakest of the three paragraph signals and the only one
// that can be wrong on correct input: a paragraph whose last line happens to
// fill the measure merges with the next. It is used only on a column that
// offers neither blank lines nor indents, where the alternative is one
// paragraph per page.
@(private = "file")
short_last :: proc(lines: []Line, from, to, prev_i: int, l: Line, left: int, body: f32) -> bool {
	p := lines[prev_i]
	m := measure_at(lines, from, to, p.size)
	if m <= 0 {
		return false
	}
	return f32(p.x1 - p.x0) < f32(m) * PARA_SHORT_FRAC && f32(l.x0 - left) <= body * 0.5
}

// para_flush commits the paragraph under construction. It lives at file scope
// because a nested procedure cannot capture, and everything it needs is
// already in `cur`.
@(private = "file")
para_flush :: proc(d: ^Doc, cur: ^Para, open: ^bool) {
	if !open^ {
		return
	}
	text := strings.to_string(cur.b)
	if cur.heading > 0 {
		doc_add(d, .Heading, text, cur.page, cur.col, cur.heading, cur.size, cur.conf)
	} else {
		doc_add(d, .Paragraph, text, cur.page, cur.col, 0, cur.size, cur.conf)
	}
	open^ = false
}

abs :: proc(v: f32) -> f32 {
	return math.abs(v)
}
