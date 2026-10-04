package main

// The corpus: documents whose text we know exactly, because we drew them.
//
// This is the strongest test available on this machine and it costs nothing.
// A scanned page can only ever be checked by eye — somebody has to read the
// output and the original side by side, and "it looks right" is not a number.
// But palmy already has an offscreen renderer and a PNG writer, so the
// pipeline can be handed a page image whose every word, every line break,
// every column boundary and every font size was chosen here, in code. The
// expected output is not approximately known, it is *exactly* known, which is
// what makes a character error rate meaningful rather than decorative.
//
// Each case is a render plan, and the ground truth is **derived from the
// plan** rather than written beside it. That matters: a hand-written expected
// string drifts away from the image the moment either is edited, and then the
// test is measuring the drift. Here there is one description, `Spec_Line`,
// and both the PNG and the expected Doc come out of it, so they cannot
// disagree.
//
// What the cases cover, and why each one is here:
//
//   plain        three ragged-right paragraphs separated by blank lines — the
//                base case, and the floor on any error rate below
//   indented     paragraphs marked only by a first-line indent, with no blank
//                line anywhere: the paragraph detector's hard case
//   headings     four distinct sizes, so heading levels are a measurement
//   two-column   a full-width title over two columns, which is the layout
//                that interleaves into nonsense when columns are missed
//   hyphen       a word broken across a line end, and a real compound right
//                after it that must *not* be joined
//   furniture    three pages with a running header and a numbered footer, so
//                repetition detection has something to detect
//   sizes        body text at three sizes on one page, which is where heading
//                detection by relative size goes wrong if it is naive
//   rotated      `plain` turned 1.5 degrees, which breaks any line grouper
//                that buckets by absolute y
//   skewed       the same page turned 6 degrees, which tesseract on its own
//                cannot read at all: this case is the deskew pass or nothing
//   scanned      the same page blurred, noised and halved in resolution, so
//                the summary table has an error rate in it that is not zero
//
// Nothing here is a document of the user's. Every word was written for this
// file.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import kit "kit:."
import p "palmy:."

// A4-ish at about 200 dpi. Big enough that 30-pixel body text is comfortably
// inside tesseract's sweet spot, small enough that eight pages of corpus OCR
// in a few seconds.
PAGE_W :: 1600
PAGE_H :: 2200
MARGIN :: 130

BODY_PX :: f32(30)
BODY_PITCH :: f32(46)

Spec_Line :: struct {
	text:      string,
	size:      f32, // px; 0 means BODY_PX
	bold:      bool,
	indent:    f32, // added to the column's left edge
	gap_above: f32, // extra vertical space before this line
	// Structure this line belongs to.
	starts:    bool, // this line starts a new block
	kind:      Block_Kind,
	level:     int,
	// This line ends with a hyphen that joins the next line's first word.
	hyphen:    bool,
	// Rendered but deliberately absent from the ground truth: a running
	// header or footer the pipeline is expected to drop.
	furniture: bool,
	// Absolute y override for furniture, as a fraction of the page height.
	at_y:      f32,
}

Spec_Col :: struct {
	x, w:  f32,
	lines: []Spec_Line,
}

Spec_Page :: struct {
	cols: []Spec_Col,
}

Corpus_Case :: struct {
	id:     string,
	what:   string,
	rotate: f32, // degrees, clockwise
	// Make the page look like it came off a cheap scanner: soften it, add
	// sensor noise, then halve the resolution. See `degrade`.
	scan:   bool,
	pages:  []Spec_Page,
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

@(private = "file")
load_corpus_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
}

// corpus_render draws every page of a case and returns the PNG paths.
//
// The pages are drawn straight onto the canvas with `draw_text` rather than
// through the layout engine, because the test needs to choose the line breaks
// itself: the hyphenation case is *about* a particular break, and a wrapper
// that decided for us would make the ground truth a guess again.
corpus_render :: proc(
	c: Corpus_Case,
	dir: string,
	allocator := context.allocator,
) -> (
	paths: []string,
	err: string,
) {
	off := p.offscreen_create(PAGE_W, PAGE_H, 1, "w-full h-full bg-white")
	defer p.offscreen_destroy(off)
	load_corpus_fonts(&off.fonts)

	white := p.Color{255, 255, 255, 255}
	ink := p.Color{17, 17, 17, 255}

	out := make([dynamic]string, allocator)
	for page, pi in c.pages {
		canvas := p.offscreen_canvas(off)
		p.fill_rect(canvas, p.Rect{0, 0, f32(PAGE_W), f32(PAGE_H)}, white)

		for col in page.cols {
			y := f32(MARGIN) + BODY_PITCH
			for line in col.lines {
				size := line.size == 0 ? BODY_PX : line.size
				pitch := max(BODY_PITCH, size * 1.45)
				if line.at_y > 0 {
					y = f32(PAGE_H) * line.at_y
				} else {
					y += line.gap_above
				}
				wt := line.bold ? p.Font_Weight.Bold : p.Font_Weight.Regular
				p.draw_text(
					canvas,
					&off.fonts,
					line.text,
					col.x + line.indent,
					y,
					size,
					ink,
					.Sans,
					wt,
				)
				if line.at_y <= 0 {
					y += pitch
				}
			}
		}

		px := p.offscreen_pixels(off)
		rgba := make([]u8, PAGE_W * PAGE_H * 4, context.temp_allocator)
		if c.rotate != 0 {
			rotate_into(px, PAGE_W, PAGE_H, c.rotate, rgba)
		} else {
			for v, i in px {
				rgba[i * 4 + 0] = u8(v >> 16)
				rgba[i * 4 + 1] = u8(v >> 8)
				rgba[i * 4 + 2] = u8(v)
				rgba[i * 4 + 3] = 255
			}
		}
		ow, oh := PAGE_W, PAGE_H
		if c.scan {
			rgba, ow, oh = degrade(rgba, PAGE_W, PAGE_H, u32(pi * 7919 + 13), context.temp_allocator)
		}
		path := fmt.aprintf("%s/%s-%02d.png", dir, c.id, pi + 1, allocator = allocator)
		if !p.write_png_rgba(path, rgba, ow, oh) {
			return out[:], fmt.aprintf("cannot write %s", path)
		}
		append(&out, path)
	}
	return out[:], ""
}

// rotate_into rotates the page about its centre with bilinear sampling and a
// white background, which is what a sheet of paper laid down crooked on a
// flatbed actually looks like. Nearest-neighbour would alias the stems and
// make the test easier than reality.
rotate_into :: proc(src: []u32, w, h: int, degrees: f32, dst: []u8) {
	rad := degrees * math.PI / 180
	cs := math.cos(rad)
	sn := math.sin(rad)
	cx := f32(w) * 0.5
	cy := f32(h) * 0.5
	for y in 0 ..< h {
		for x in 0 ..< w {
			// Inverse map: where in the source does this destination pixel
			// come from.
			dx := f32(x) - cx
			dy := f32(y) - cy
			sx := cs * dx + sn * dy + cx
			sy := -sn * dx + cs * dy + cy
			o := (y * w + x) * 4
			if sx < 0 || sy < 0 || sx >= f32(w - 1) || sy >= f32(h - 1) {
				dst[o + 0] = 255;dst[o + 1] = 255;dst[o + 2] = 255;dst[o + 3] = 255
				continue
			}
			x0 := int(sx)
			y0 := int(sy)
			fx := sx - f32(x0)
			fy := sy - f32(y0)
			r, g, b := f32(0), f32(0), f32(0)
			for j in 0 ..< 2 {
				for i in 0 ..< 2 {
					wgt := (i == 0 ? 1 - fx : fx) * (j == 0 ? 1 - fy : fy)
					v := src[(y0 + j) * w + (x0 + i)]
					r += f32((v >> 16) & 0xff) * wgt
					g += f32((v >> 8) & 0xff) * wgt
					b += f32(v & 0xff) * wgt
				}
			}
			dst[o + 0] = u8(clamp(r, 0, 255))
			dst[o + 1] = u8(clamp(g, 0, 255))
			dst[o + 2] = u8(clamp(b, 0, 255))
			dst[o + 3] = 255
		}
	}
}

// degrade makes a crisp render look like it came off a cheap flatbed.
//
// A corpus of perfectly rendered pages is a corpus that reports zero error
// everywhere, which is a pleasant number and not an informative one: it
// measures the renderer and the recogniser agreeing about glyphs they both
// got from the same font file. A real scan is softer, noisier and coarser
// than that, and the interesting question is what the pipeline does when the
// characters stop being obvious.
//
// Three effects, in the order a scanner applies them:
//
//   * **optical blur** — a 3x3 box filter twice, which is a crude Gaussian,
//     for a lens and a sheet of glass that are not in perfect contact;
//   * **sensor noise** — additive, uniform, the same every run because the
//     generator is seeded per page. Reproducibility matters more than
//     realism here: an error rate that moves between runs cannot be tracked.
//   * **resolution** — halved afterwards, by averaging, so a 200 dpi render
//     becomes a 100 dpi scan. This is the one that actually hurts.
//
// It is deliberately a little worse than a scanner most people own. A test
// that only passes on good input tells you nothing about the bad input you
// will actually be handed.
degrade :: proc(
	src: []u8,
	w, h: int,
	seed: u32,
	allocator := context.temp_allocator,
) -> (
	out: []u8,
	ow, oh: int,
) {
	gray := make([]f32, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		gray[i] =
			f32(src[i * 4 + 0]) * 0.299 + f32(src[i * 4 + 1]) * 0.587 + f32(src[i * 4 + 2]) * 0.114
	}
	tmp := make([]f32, w * h, context.temp_allocator)
	for _ in 0 ..< 2 {
		box3(gray, tmp, w, h)
		copy(gray, tmp)
	}

	// A plain 32-bit LCG. Not a good generator; a perfectly good one for
	// putting reproducible grain on a page.
	rng := seed | 1
	next :: proc(r: ^u32) -> u32 {
		r^ = r^ * 1664525 + 1013904223
		return r^
	}
	NOISE :: f32(26)
	for i in 0 ..< w * h {
		n := (f32(next(&rng) >> 16) / 65535.0 - 0.5) * 2 * NOISE
		gray[i] = clamp(gray[i] + n, 0, 255)
	}

	ow = w / 2
	oh = h / 2
	out = make([]u8, ow * oh * 4, allocator)
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			v :=
				(gray[(y * 2) * w + x * 2] +
						gray[(y * 2) * w + x * 2 + 1] +
						gray[(y * 2 + 1) * w + x * 2] +
						gray[(y * 2 + 1) * w + x * 2 + 1]) *
				0.25
			b := u8(clamp(v, 0, 255))
			o := (y * ow + x) * 4
			out[o + 0] = b
			out[o + 1] = b
			out[o + 2] = b
			out[o + 3] = 255
		}
	}
	return out, ow, oh
}

@(private = "file")
box3 :: proc(src, dst: []f32, w, h: int) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			sum := f32(0)
			n := 0
			for dy in -1 ..= 1 {
				yy := y + dy
				if yy < 0 || yy >= h {
					continue
				}
				for dx in -1 ..= 1 {
					xx := x + dx
					if xx < 0 || xx >= w {
						continue
					}
					sum += src[yy * w + xx]
					n += 1
				}
			}
			dst[y * w + x] = sum / f32(n)
		}
	}
}

// ---------------------------------------------------------------------------
// Ground truth, derived from the same plan
// ---------------------------------------------------------------------------

// corpus_truth builds the Doc the pipeline is expected to produce. Reading
// order is columns left to right within a page, pages in order, which is the
// same order `recover` emits.
corpus_truth :: proc(c: Corpus_Case, d: ^Doc) {
	for page, pi in c.pages {
		if pi > 0 {
			doc_add(d, .Page_Break, "", pi + 1, 0)
		}
		for col, ci in page.cols {
			b := strings.builder_make(context.temp_allocator)
			kind := Block_Kind.Paragraph
			level := 0
			open := false
			pending_hyphen := false

			for line in col.lines {
				if line.furniture {
					continue // expected to be dropped
				}
				if line.starts && open {
					doc_add(d, kind, strings.to_string(b), pi + 1, ci, level)
					b = strings.builder_make(context.temp_allocator)
					open = false
					pending_hyphen = false
				}
				if !open {
					kind = line.kind
					level = line.level
					open = true
				}
				text := line.text
				if pending_hyphen {
					// no separator: the word was closed up
				} else if strings.builder_len(b) > 0 {
					strings.write_byte(&b, ' ')
				}
				pending_hyphen = false
				if line.hyphen {
					stem, yes := ends_with_hyphen(text)
					if yes {
						strings.write_string(&b, stem)
						pending_hyphen = true
						continue
					}
				}
				strings.write_string(&b, text)
			}
			if open {
				doc_add(d, kind, strings.to_string(b), pi + 1, ci, level)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The cases
// ---------------------------------------------------------------------------

@(private = "file")
L :: proc(text: string, opts: Spec_Line = {}) -> Spec_Line {
	l := opts
	l.text = text
	return l
}

// A slice literal inside a struct literal is backed by a temporary, so every
// case has to copy its lines into the caller's allocator before returning —
// a stack-backed `pages` slice reads as a page of garbage a frame later, and
// as a segfault a frame after that.
@(private = "file")
one_col :: proc(lines: []Spec_Line, allocator: mem.Allocator) -> []Spec_Page {
	cols := make([]Spec_Col, 1, allocator)
	cols[0] = Spec_Col {
		x     = MARGIN,
		w     = COL_FULL,
		lines = slice.clone(lines, allocator),
	}
	pages := make([]Spec_Page, 1, allocator)
	pages[0] = Spec_Page {
		cols = cols,
	}
	return pages
}

@(private = "file")
three_col :: proc(a, b, c: []Spec_Line, allocator: mem.Allocator) -> []Spec_Page {
	cols := make([]Spec_Col, 3, allocator)
	cols[0] = Spec_Col{x = MARGIN, w = COL_FULL, lines = slice.clone(a, allocator)}
	cols[1] = Spec_Col{x = MARGIN, w = COL_HALF, lines = slice.clone(b, allocator)}
	cols[2] = Spec_Col{x = COL_R_X, w = COL_HALF, lines = slice.clone(c, allocator)}
	pages := make([]Spec_Page, 1, allocator)
	pages[0] = Spec_Page {
		cols = cols,
	}
	return pages
}

COL_FULL :: f32(PAGE_W - 2 * MARGIN)
COL_HALF :: f32(640)
COL_R_X :: f32(MARGIN + 640 + 90)

corpus_cases :: proc(allocator := context.allocator) -> []Corpus_Case {
	out := make([dynamic]Corpus_Case, allocator)

	// --- plain -------------------------------------------------------------
	plain_lines := []Spec_Line {
		L("The harbour was empty by the time the wind turned, and the", {starts = true, kind = .Paragraph}),
		L("boats that had been there all morning were drawn up above"),
		L("the tideline with their sails furled and tied."),
		L("Nobody on the island kept a barometer, which is not the same", {starts = true, kind = .Paragraph, gap_above = 34}),
		L("thing as nobody knowing what the weather would do. The"),
		L("knowledge was held in the shape of the clouds over the"),
		L("mainland and in the colour of the water off the point."),
		L("By four the rain had come in from the west, and the lamps", {starts = true, kind = .Paragraph, gap_above = 34}),
		L("in the two houses facing the quay were lit against it."),
	}
	append(
		&out,
		Corpus_Case {
			id = "plain",
			what = "three ragged-right paragraphs, blank line between",
			pages = one_col(plain_lines, allocator),
		},
	)

	// --- indented ----------------------------------------------------------
	// No blank lines at all. The only evidence of a paragraph boundary is the
	// indent on its first line, and the short last line before it.
	indented_lines := []Spec_Line {
		L("The ferry ran three times a week in summer and twice", {starts = true, kind = .Paragraph, indent = 44}),
		L("in winter, and the timetable was printed on a card that"),
		L("the post office kept behind the counter for anyone who"),
		L("asked for it."),
		L("Visitors found this arrangement charming for about a", {starts = true, kind = .Paragraph, indent = 44}),
		L("week. After that they began to ask whether the card"),
		L("could not simply be pinned to the door, and were told"),
		L("that it could, and that it had been, once."),
		L("The card stayed behind the counter.", {starts = true, kind = .Paragraph, indent = 44}),
	}
	append(
		&out,
		Corpus_Case {
			id = "indented",
			what = "paragraphs marked only by a first-line indent, no blank lines",
			pages = one_col(indented_lines, allocator),
		},
	)

	// --- headings ----------------------------------------------------------
	head_lines := []Spec_Line {
		L("The Weather of Small Islands", {starts = true, kind = .Heading, level = 1, size = 62, bold = true}),
		L("A field account of nine summers", {starts = true, kind = .Paragraph, gap_above = 18}),
		L("spent watching one stretch of water."),
		L("Reading the Cloud", {starts = true, kind = .Heading, level = 2, size = 46, bold = true, gap_above = 40}),
		L("Low cloud over the mainland in the morning means", {starts = true, kind = .Paragraph, gap_above = 14}),
		L("nothing by itself. Low cloud that has not lifted by"),
		L("noon means the afternoon is already decided."),
		L("Off the point", {starts = true, kind = .Heading, level = 3, size = 38, bold = true, gap_above = 38}),
		L("The water off the point changes colour before the", {starts = true, kind = .Paragraph, gap_above = 12}),
		L("wind arrives, and that is the only early warning"),
		L("the island has ever had."),
	}
	append(
		&out,
		Corpus_Case {
			id = "headings",
			what = "four distinct sizes: h1 62px, h2 46px, h3 38px, body 30px",
			pages = one_col(head_lines, allocator),
		},
	)

	// --- two-column --------------------------------------------------------
	left_lines := []Spec_Line {
		L("The gutter between these", {starts = true, kind = .Paragraph, gap_above = 150}),
		L("two columns is wide, and"),
		L("no word on any line of"),
		L("either one crosses it."),
		L("A reader following the", {starts = true, kind = .Paragraph, gap_above = 30}),
		L("page down rather than"),
		L("across would produce a"),
		L("sentence that is half of"),
		L("one thought and half of"),
		L("another, which is what"),
		L("makes this the case that"),
		L("matters."),
	}
	right_lines := []Spec_Line {
		L("The right column says", {starts = true, kind = .Paragraph, gap_above = 150}),
		L("something else entirely,"),
		L("so an interleaved result"),
		L("is obvious on sight."),
		L("Column detection here is", {starts = true, kind = .Paragraph, gap_above = 30}),
		L("a projection onto the x"),
		L("axis: a band of pixels no"),
		L("word touches, tall enough"),
		L("and wide enough, with"),
		L("text either side of it."),
	}
	span_title := []Spec_Line {
		L("Two Columns and a Title Across Both", {starts = true, kind = .Heading, level = 1, size = 56, bold = true}),
	}
	append(
		&out,
		Corpus_Case {
			id = "two-column",
			what = "a full-width title over two 640px columns with a 90px gutter",
			pages = three_col(span_title, left_lines, right_lines, allocator),
		},
	)

	// --- hyphen ------------------------------------------------------------
	hyphen_lines := []Spec_Line {
		L("The lighthouse keeper's cottage had a slate roof that the", {starts = true, kind = .Paragraph}),
		L("council had replaced twice, and a chimney that nobody"),
		L("had touched since the war. Every autumn the weather-", {hyphen = true}),
		L("vane on its ridge turned once and stopped, pointing"),
		L("south-west, where it stayed until somebody climbed up"),
		L("and freed it."),
	}
	append(
		&out,
		Corpus_Case {
			id = "hyphen",
			what = "a word broken across a line end, plus a real compound that must not be joined",
			pages = one_col(hyphen_lines, allocator),
		},
	)

	// --- furniture ---------------------------------------------------------
	// Three pages, each with the same running header and a footer whose only
	// varying part is the page number.
	furn_pages := make([dynamic]Spec_Page, allocator)
	bodies := [3][]string {
		{
			"The first page of this chapter is about the shipping",
			"forecast, which was read aloud on the radio at ten past",
			"midnight and again before six in the morning.",
			"Everyone who needed it was awake for one of the two,",
			"and everyone who did not need it slept through both.",
		},
		{
			"The second page is about the lifeboat, which was",
			"launched eleven times in the nine summers covered by",
			"this account and was needed on nine of them.",
			"The other two launches were drills, announced in",
			"advance and attended by most of the island.",
		},
		{
			"The third page is about the pier, which was condemned",
			"in the spring and then un-condemned in the autumn",
			"after a second engineer looked at the same timbers.",
			"Neither report was ever published, and both were",
			"quoted at length for years afterwards.",
		},
	}
	for pn in 1 ..= 3 {
		lines := make([dynamic]Spec_Line, allocator)
		append(
			&lines,
			Spec_Line {
				text = "THE WEATHER OF SMALL ISLANDS",
				size = 24,
				furniture = true,
				at_y = 0.035,
			},
		)
		for text, i in bodies[pn - 1] {
			append(
				&lines,
				Spec_Line{text = text, starts = i == 0, kind = .Paragraph, gap_above = i == 0 ? 180 : 0},
			)
		}
		append(
			&lines,
			Spec_Line {
				text = fmt.aprintf("Page %d of 3", pn, allocator = allocator),
				size = 24,
				furniture = true,
				at_y = 0.965,
			},
		)
		cols := make([]Spec_Col, 1, allocator)
		cols[0] = Spec_Col {
			x     = MARGIN,
			w     = COL_FULL,
			lines = lines[:],
		}
		append(&furn_pages, Spec_Page{cols = cols})
	}
	append(
		&out,
		Corpus_Case {
			id = "furniture",
			what = "three pages with a repeated header and a numbered footer",
			pages = furn_pages[:],
		},
	)

	// --- sizes -------------------------------------------------------------
	size_lines := []Spec_Line {
		L("This paragraph is set at twenty-four pixels, which is", {starts = true, kind = .Paragraph, size = 24}),
		L("smaller than the body size of the rest of the corpus and", {size = 24}),
		L("must not be mistaken for a caption or a footnote.", {size = 24}),
		L("This paragraph is thirty-two pixels and is the body size", {starts = true, kind = .Paragraph, size = 32, gap_above = 36}),
		L("of this particular page, because it has the most words", {size = 32}),
		L("on it and the median is weighted by word and not by line.", {size = 32}),
		L("This one is forty pixels", {starts = true, kind = .Paragraph, size = 40, gap_above = 36}),
		L("and is still a paragraph", {size = 40}),
		L("rather than a heading,", {size = 40}),
		L("because it runs to four", {size = 40}),
		L("lines and sixteen words.", {size = 40}),
	}
	append(
		&out,
		Corpus_Case {
			id = "sizes",
			what = "body text at 24, 32 and 40 px on one page, none of it a heading",
			pages = one_col(size_lines, allocator),
		},
	)

	// --- flush -------------------------------------------------------------
	// No blank lines, no indents, nothing but the fact that a paragraph's last
	// line stops short. This is the only case the short-last-line rule has to
	// carry on its own, and it is the one it gets wrong on real pages.
	flush_lines := []Spec_Line {
		L("The pier was condemned in the spring by an engineer who", {starts = true, kind = .Paragraph}),
		L("had walked its length twice and put his stick through one"),
		L("of the boards near the end."),
		L("It was un-condemned in the autumn by a second engineer", {starts = true, kind = .Paragraph}),
		L("who looked at the same timbers and reached the opposite"),
		L("conclusion in writing."),
		L("Neither report was published.", {starts = true, kind = .Paragraph}),
	}
	append(
		&out,
		Corpus_Case {
			id = "flush",
			what = "flush left, no blank lines and no indents: only a short last line marks the break",
			pages = one_col(flush_lines, allocator),
		},
	)

	// --- rotated -----------------------------------------------------------
	append(
		&out,
		Corpus_Case {
			id = "rotated",
			what = "the plain case turned 1.5 degrees, bilinearly resampled",
			rotate = 1.5,
			pages = one_col(plain_lines, allocator),
		},
	)

	// --- scanned -----------------------------------------------------------
	// The only case in the corpus that is not a clean render. It is here so
	// the summary table has a number in it that is not zero.
	append(
		&out,
		Corpus_Case {
			id = "scanned",
			what = "blurred, noised and halved: what a cheap flatbed would have given us",
			scan = true,
			pages = one_col(plain_lines, allocator),
		},
	)

	// --- skewed ------------------------------------------------------------
	// Six degrees is past the point where tesseract's own line finder gives
	// up and returns an empty page, so this case is entirely about the deskew
	// pass in deskew.odin. Without it the error rate here is 100%.
	append(
		&out,
		Corpus_Case {
			id = "skewed",
			what = "turned 6 degrees, which tesseract alone cannot read at all",
			rotate = 6,
			pages = one_col(plain_lines, allocator),
		},
	)

	return out[:]
}
