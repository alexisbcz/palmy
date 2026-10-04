// `docs --selftest` — the model without a window.
//
// Everything here exercises the same procedures the keyboard calls. Fonts are
// loaded exactly as the app loads them, so the wrap and pagination assertions
// are measured against the faces the window would draw with.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

@(private = "file")
checks: int
@(private = "file")
fails: int

@(private = "file")
ok :: proc(cond: bool, msg: string, args: ..any) {
	checks += 1
	if !cond {
		fails += 1
		fmt.eprintf("  FAIL  %s\n", fmt.tprintf(msg, ..args))
	}
}

@(private = "file")
eq_int :: proc(got, want: int, msg: string, args: ..any) {
	checks += 1
	if got != want {
		fails += 1
		fmt.eprintf("  FAIL  %s: got %d, want %d\n", fmt.tprintf(msg, ..args), got, want)
	}
}

@(private = "file")
eq_str :: proc(got, want: string, msg: string, args: ..any) {
	checks += 1
	if got != want {
		fails += 1
		fmt.eprintf("  FAIL  %s:\n    got  %q\n    want %q\n", fmt.tprintf(msg, ..args), got, want)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("  %s\n", name)
}

// text_of concatenates a whole document, paragraphs joined by newlines, which
// is the easiest thing to assert against.
@(private = "file")
text_of :: proc(d: ^Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &pa, i in d.paras {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		for &r in pa.runs {
			strings.write_bytes(&b, r.text[:])
		}
	}
	return strings.to_string(b)
}

// shape renders a paragraph's run structure as "text/flags|text/flags", which
// makes a splitting or coalescing bug obvious in one line of output.
@(private = "file")
shape :: proc(pa: ^Paragraph) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &r, i in pa.runs {
		if i > 0 {
			strings.write_byte(&b, '|')
		}
		strings.write_bytes(&b, r.text[:])
		strings.write_byte(&b, '/')
		if r.style.bold {strings.write_byte(&b, 'b')}
		if r.style.italic {strings.write_byte(&b, 'i')}
		if r.style.underline {strings.write_byte(&b, 'u')}
		if r.style.mono {strings.write_byte(&b, 'm')}
		if r.style.size != 0 {fmt.sbprintf(&b, "%.0f", r.style.size)}
		if r.style.color != 0 {fmt.sbprintf(&b, "#%06x", r.style.color & 0xffffff)}
	}
	return strings.to_string(b)
}

run_selftest :: proc() -> bool {
	fonts: p.Fonts
	headless_fonts(&fonts)
	layout_fonts = &fonts
	ok(fonts.any, "a sans face loaded")

	fmt.println("docs --selftest")

	test_runs()
	test_boundaries()
	test_styles()
	test_history(&fonts)
	test_wrap(&fonts)
	test_caret(&fonts)
	test_pagination(&fonts)
	test_markdown()
	test_json()
	test_find(&fonts)

	fmt.printfln("\n%d assertions, %d failed", checks, fails)
	return fails == 0
}

// ---------------------------------------------------------------------------
// 1. Runs: splitting, coalescing, and the two invariants
// ---------------------------------------------------------------------------

test_runs :: proc() {
	section("runs: splitting and coalescing")

	pa := para_make(.Body, "Hello world")
	defer para_destroy(&pa)

	eq_int(len(pa.runs), 1, "one run to start")
	eq_int(para_len(&pa), 11, "paragraph length")

	// split_at creates a boundary and reports the run that begins there.
	eq_int(split_at(&pa, 5), 1, "split at 5 yields run 1")
	eq_int(len(pa.runs), 2, "two runs after splitting")
	eq_str(shape(&pa), "Hello/| world/", "split preserves the text")

	// A split into two runs of the same style must coalesce again.
	normalise(&pa)
	eq_int(len(pa.runs), 1, "identical neighbours coalesce")
	eq_str(shape(&pa), "Hello world/", "coalesced back to one run")

	// Splitting at either end is a no-op boundary, not an empty run.
	eq_int(split_at(&pa, 0), 0, "split at 0")
	eq_int(split_at(&pa, 11), len(pa.runs), "split at the end is past the last run")
	eq_int(len(pa.runs), 1, "no empty runs created at the edges")

	// Inserting in the middle of a run with a different style splits it.
	d := Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	defer doc_destroy(&d)
	append(&d.paras, para_make(.Body, "abcdef"))
	q := insert_plain(&d, Pos{0, 3}, "XY", Char_Style{bold = true})
	eq_str(shape(&d.paras[0]), "abc/|XY/b|def/", "a differing style splits the run in three")
	eq_int(q.off, 5, "the caret lands after the inserted text")

	// Inserting with the same style as the run it lands in must not split.
	insert_plain(&d, Pos{0, 1}, "..", Char_Style{})
	eq_str(shape(&d.paras[0]), "a..bc/|XY/b|def/", "a matching style joins the run")
	eq_int(len(d.paras[0].runs), 3, "still three runs")

	// A caret on a boundary takes the style to its left, which is why typing
	// after a bold word keeps bolding.
	cs := style_at(&d, Pos{0, 7})
	ok(cs.bold, "style at the end of the bold run is bold")
	cs2 := style_at(&d, Pos{0, 5})
	ok(!cs2.bold, "style at the start of the bold run is the run before it")

	// Deleting the middle run merges the compatible neighbours.
	delete_range(&d, Pos{0, 5}, Pos{0, 7})
	eq_str(shape(&d.paras[0]), "a..bcdef/", "deleting across runs merges the neighbours")
	eq_int(len(d.paras[0].runs), 1, "one run again")

	// Normalisation never leaves a paragraph with zero runs.
	delete_range(&d, Pos{0, 0}, Pos{0, para_len(&d.paras[0])})
	eq_int(len(d.paras[0].runs), 1, "an emptied paragraph keeps one run")
	eq_int(para_len(&d.paras[0]), 0, "and it is empty")
}

// ---------------------------------------------------------------------------
// 2. Edits across run and paragraph boundaries
// ---------------------------------------------------------------------------

test_boundaries :: proc() {
	section("edits across run and paragraph boundaries")

	d := Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	defer doc_destroy(&d)
	append(&d.paras, para_make(.H2, "Heading"))
	append(&d.paras, para_make(.Body, "first paragraph"))
	append(&d.paras, para_make(.Body, "second paragraph"))

	// Enter in the middle of a paragraph.
	q := break_para(&d, Pos{1, 5})
	eq_int(len(d.paras), 4, "a break adds a paragraph")
	eq_int(q.para, 2, "the caret moves to the new paragraph")
	eq_int(q.off, 0, "at its start")
	eq_str(text_of(&d), "Heading\nfirst\n paragraph\nsecond paragraph", "text is preserved")
	ok(d.paras[2].kind == .Body, "the new paragraph inherits the kind")

	// Enter at the end of a heading starts body text.
	q2 := break_para(&d, Pos{0, 7})
	ok(d.paras[1].kind == .Body, "Return at the end of a heading starts body text")
	eq_int(q2.para, 1, "caret in the new paragraph")

	// Backspace joining two paragraphs.
	n := len(d.paras)
	join := merge_para(&d, 2)
	eq_int(len(d.paras), n - 1, "merging removes a paragraph")
	eq_int(join.para, 2, "the caret stays in the surviving paragraph")
	eq_str(text_of(&d), "Heading\n\nfirst paragraph\nsecond paragraph", "the join is seamless")

	// A delete spanning three paragraphs, from inside the first to inside the
	// last, leaves one paragraph with the first one's properties.
	d2 := Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	defer doc_destroy(&d2)
	append(&d2.paras, para_make(.H1, "AAAA"))
	append(&d2.paras, para_make(.Body, "BBBB"))
	append(&d2.paras, para_make(.Quote, "CCCC"))
	caret := delete_range(&d2, Pos{0, 2}, Pos{2, 2})
	eq_int(len(d2.paras), 1, "three paragraphs collapse into one")
	eq_str(text_of(&d2), "AACC", "only the ends survive")
	ok(d2.paras[0].kind == .H1, "the first paragraph's properties win")
	eq_int(caret.off, 2, "the caret sits at the seam")

	// Deleting across runs with matching styles on either side of the seam
	// must coalesce them.
	d3 := Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	defer doc_destroy(&d3)
	append(&d3.paras, para_make(.Body, "keep"))
	insert_plain(&d3, Pos{0, 4}, "BOLD", Char_Style{bold = true})
	insert_plain(&d3, Pos{0, 8}, "keep", Char_Style{})
	eq_str(shape(&d3.paras[0]), "keep/|BOLD/b|keep/", "three runs set up")
	delete_range(&d3, Pos{0, 4}, Pos{0, 8})
	eq_str(shape(&d3.paras[0]), "keepkeep/", "removing the middle run coalesces the rest")

	// Multi-line insert: a paste of three lines becomes three paragraphs.
	d4 := Doc{}
	doc_init(&d4)
	defer doc_destroy(&d4)
	end := insert_text(&d4, Pos{0, 0}, "one\ntwo\nthree", Char_Style{})
	eq_int(len(d4.paras), 3, "newlines in an insert become paragraphs")
	eq_str(text_of(&d4), "one\ntwo\nthree", "all three lines are there")
	eq_int(end.para, 2, "the caret ends in the last one")
	eq_int(end.off, 5, "at its end")
}

// ---------------------------------------------------------------------------
// 3. Style application over a selection
// ---------------------------------------------------------------------------

test_styles :: proc() {
	section("character styles over a selection")

	d := Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	defer doc_destroy(&d)
	append(&d.paras, para_make(.Body, "the quick brown fox"))

	// Bold exactly "quick".
	apply_patch(&d, Pos{0, 4}, Pos{0, 9}, {{.Bold}, Char_Style{bold = true}})
	eq_str(shape(&d.paras[0]), "the /|quick/b| brown fox/", "the patch lands on the selection only")
	ok(range_all_bold(&d, Pos{0, 4}, Pos{0, 9}), "the whole span reads as bold")
	ok(!range_all_bold(&d, Pos{0, 0}, Pos{0, 9}), "a partly bold span does not")

	// A second patch over a superset keeps one run, not three.
	apply_patch(&d, Pos{0, 0}, Pos{0, 19}, {{.Bold}, Char_Style{bold = true}})
	eq_str(shape(&d.paras[0]), "the quick brown fox/b", "bolding everything coalesces to one run")

	// Patches are partial: adding italic must not clear bold.
	apply_patch(&d, Pos{0, 4}, Pos{0, 9}, {{.Italic}, Char_Style{italic = true}})
	eq_str(shape(&d.paras[0]), "the /b|quick/bi| brown fox/b", "italic is added without losing bold")

	// Size and colour.
	apply_patch(&d, Pos{0, 0}, Pos{0, 3}, {{.Size, .Color}, Char_Style{size = 24, color = 0xffe7000b}})
	eq_str(
		shape(&d.paras[0]),
		"the/b24#e7000b| /b|quick/bi| brown fox/b",
		"size and colour apply together",
	)

	// Clearing every field returns the paragraph to a single plain run.
	apply_patch(
		&d,
		Pos{0, 0},
		Pos{0, 19},
		{{.Bold, .Italic, .Underline, .Mono, .Size, .Color}, Char_Style{}},
	)
	eq_str(shape(&d.paras[0]), "the quick brown fox/", "clearing formatting collapses to one run")

	// A patch across a paragraph boundary touches both.
	append(&d.paras, para_make(.Body, "second"))
	apply_patch(&d, Pos{0, 16}, Pos{1, 3}, {{.Underline}, Char_Style{underline = true}})
	eq_str(shape(&d.paras[0]), "the quick brown /|fox/u", "the tail of the first paragraph")
	eq_str(shape(&d.paras[1]), "sec/u|ond/", "and the head of the second")
}

// ---------------------------------------------------------------------------
// 4. Undo and redo, including coalesced typing
// ---------------------------------------------------------------------------

test_history :: proc(fonts: ^p.Fonts) {
	section("undo and redo")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}

	// Typing a word is one undo step, not eleven.
	for ch in "hello world" {
		type_text(&st, fmt.tprintf("%r", ch))
	}
	eq_str(text_of(&st.doc), "hello world", "the word was typed")
	eq_int(len(st.hist.undo), 2, "a word plus a space is two coalesced groups")

	do_undo(&st)
	eq_str(text_of(&st.doc), "hello ", "one undo takes back the second word")
	do_undo(&st)
	eq_str(text_of(&st.doc), "", "the second takes back the first")
	ok(!history_can_undo(&st.hist), "and the stack is empty")

	do_redo(&st)
	eq_str(text_of(&st.doc), "hello ", "redo restores the first group")
	do_redo(&st)
	eq_str(text_of(&st.doc), "hello world", "and the second")
	ok(!history_can_redo(&st.hist), "nothing left to redo")

	// A style change is its own step and never coalesces with typing.
	st.anchor = Pos{0, 0}
	st.caret = Pos{0, 5}
	toggle_bold(&st)
	ok(range_all_bold(&st.doc, Pos{0, 0}, Pos{0, 5}), "the selection is bold")
	do_undo(&st)
	ok(!range_all_bold(&st.doc, Pos{0, 0}, Pos{0, 5}), "undo removes the bold")
	eq_str(text_of(&st.doc), "hello world", "and leaves the text alone")

	// A new edit after an undo discards the redo branch.
	do_redo(&st)
	type_text(&st, "!")
	ok(!history_can_redo(&st.hist), "editing clears the redo stack")

	// Moving the caret closes the group, so two typing bursts are two steps.
	n := len(st.hist.undo)
	place_caret(&st, Pos{0, 0}, false)
	type_text(&st, "A")
	place_caret(&st, Pos{0, 3}, false)
	type_text(&st, "B")
	eq_int(len(st.hist.undo), n + 2, "a caret move between bursts splits the group")

	// Undo restores the caret and the selection, not just the text. (The cut
	// is done by hand here so the test never talks to wl-copy.)
	before := text_of(&st.doc)
	st.anchor = Pos{0, 1}
	st.caret = Pos{0, 4}
	clip := selection_doc(&st)
	defer doc_destroy(&clip)
	eq_int(para_len(&clip.paras[0]), 3, "the clipboard copy is three bytes")
	edit_begin(&st, .Structural)
	drop_selection(&st)
	ok(text_of(&st.doc) != before, "the cut changed the text")
	do_undo(&st)
	eq_str(text_of(&st.doc), before, "undo restored it")
	ok(st.anchor == Pos{0, 1} && st.caret == Pos{0, 4}, "and restored the selection")

	// A styled copy pastes back with its runs intact.
	src := Doc{paras = make([dynamic]Paragraph, 0, 2)}
	defer doc_destroy(&src)
	append(&src.paras, para_make(.Body, "plain"))
	insert_plain(&src, Pos{0, 5}, "BOLD", Char_Style{bold = true})
	dst := Doc{}
	doc_init(&dst)
	defer doc_destroy(&dst)
	insert_doc(&dst, Pos{0, 0}, &src)
	eq_str(shape(&dst.paras[0]), "plain/|BOLD/b", "a styled paste keeps its runs")
}

// ---------------------------------------------------------------------------
// 5. Word wrap at a known width
// ---------------------------------------------------------------------------

test_wrap :: proc(fonts: ^p.Fonts) {
	section("word wrap at the 602 px measure")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)

	// A short paragraph is one line; a long one is several. The measure is
	// CONTENT_W, which is A4 minus two one-inch margins.
	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	append(&st.doc.paras, para_make(.Body, "short"))
	long := strings.repeat("wrapping ", 40, context.temp_allocator)
	append(&st.doc.paras, para_make(.Body, long))
	append(&st.doc.paras, para_make(.Body, strings.repeat("M", 400, context.temp_allocator)))
	relayout(&st)

	lines0 := 0
	for l in st.lay.lines {
		if l.para == 0 {lines0 += 1}
	}
	eq_int(lines0, 1, "a five-letter paragraph is one line")

	// Every line fits, and the text is partitioned exactly.
	for pi in 0 ..< len(st.doc.paras) {
		want := para_text(&st.doc.paras[pi], context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		prev_end := 0
		first := true
		for li in 0 ..< len(st.lay.lines) {
			l := st.lay.lines[li]
			if l.para != pi {
				continue
			}
			if first {
				eq_int(l.start, 0, "paragraph %d starts at 0", pi)
				first = false
			} else {
				eq_int(l.start, prev_end, "paragraph %d lines are contiguous", pi)
			}
			ok(
				l.w <= CONTENT_W + 0.5,
				"paragraph %d line %d is %0.1f px, within the measure",
				pi,
				li,
				f64(l.w),
			)
			strings.write_string(&b, line_text(&st.lay, li))
			prev_end = l.end
			if l.last {
				eq_int(l.end, len(want), "paragraph %d ends at its length", pi)
			}
		}
		eq_str(strings.to_string(b), want, "paragraph %d: the lines rebuild the text", pi)
	}

	// Greedy means the next line's first word genuinely does not fit on the
	// line above.
	tight := 0
	for li in 1 ..< len(st.lay.lines) {
		l := st.lay.lines[li]
		prev := st.lay.lines[li - 1]
		if prev.para != l.para || l.fc == 0 {
			continue
		}
		f := st.lay.frags[l.fi]
		s := frag_text(&st.lay, l, f)
		word := strings.trim_right_space(s)
		w := p.text_width(fonts, word, f.size, f.fam, f.wt)
		// The line above, including the spaces the break consumed, is what the
		// greedy fill actually compared against.
		pf := st.lay.frags[prev.fi + prev.fc - 1]
		prev_full := pf.x + pf.w
		ok(prev_full + w > CONTENT_W - 0.5, "line %d is full: the next word would overflow", li - 1)
		tight += 1
	}
	ok(tight > 4, "the long paragraph really wrapped (%d breaks checked)", tight)

	// A single 400-character word has to be broken between runes.
	lines2 := 0
	for l in st.lay.lines {
		if l.para == 2 {lines2 += 1}
	}
	ok(lines2 > 1, "an unbreakable word is split across %d lines", lines2)

	// Indentation narrows the measure, so the same text takes more lines.
	st.doc.paras[1].list = .Bullet
	st.doc.paras[1].depth = 2
	relayout(&st)
	wide := 0
	for l in st.lay.lines {
		if l.para == 1 {wide += 1}
	}
	indent := para_indent(&st.doc.paras[1], kind_metrics(.Body))
	ok(indent > 70, "a nested bullet is indented %0.0f px", f64(indent))
	for l in st.lay.lines {
		if l.para == 1 {
			ok(l.w <= CONTENT_W - indent + 0.5, "an indented line fits the narrower measure")
			break
		}
	}
	ok(wide >= 5, "the indented paragraph still wraps (%d lines)", wide)
}

// ---------------------------------------------------------------------------
// 6. The caret mappings
// ---------------------------------------------------------------------------

test_caret :: proc(fonts: ^p.Fonts) {
	section("caret: x from offset and offset from x")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}

	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	pa := para_make(
		.Body,
		"The quick brown fox jumps over the lazy dog, and then the lazy dog gets " +
		"up and jumps over the quick brown fox, which is how these sentences " +
		"usually end up going when nobody is watching them closely enough.",
	)
	// Mixed sizes and weights, so the walk really crosses fragments.
	k := split_at(&pa, 4)
	j := split_at(&pa, 9)
	for q in k ..< j {
		pa.runs[q].style.bold = true
		pa.runs[q].style.size = 22
	}
	normalise(&pa)
	append(&st.doc.paras, pa)
	relayout(&st)

	// caret_x and off_at_x round-trip on every rune boundary.
	round := 0
	for li in 0 ..< len(st.lay.lines) {
		l := st.lay.lines[li]
		s := para_string(&st.lay, l.para)
		o := l.start
		for o <= l.vis_end {
			x := caret_x(&st.lay, li, o)
			back := off_at_x(&st.lay, li, x)
			eq_int(back, o, "line %d: offset %d round-trips through x=%0.1f", li, o, f64(x))
			round += 1
			if o >= len(s) {
				break
			}
			o = rune_after(s, o)
		}
	}
	ok(round > 40, "%d caret positions checked", round)

	// x grows monotonically along a line.
	l0 := st.lay.lines[0]
	last := f32(-1)
	s0 := para_string(&st.lay, 0)
	for o := l0.start; o <= l0.vis_end; o = rune_after(s0, o) {
		x := caret_x(&st.lay, 0, o)
		ok(x >= last - 0.01, "caret x is monotonic at offset %d", o)
		last = x
		if o >= len(s0) {
			break
		}
	}

	// Up and Down move by visual line and remember the column.
	st.caret = Pos{0, 0}
	st.anchor = st.caret
	eq_int(line_of(&st.lay, st.caret), 0, "the caret starts on line 0")
	mid := off_at_x(&st.lay, 0, 240)
	st.caret = Pos{0, mid}
	st.goal_ok = false
	move_v(&st, 1, false)
	eq_int(line_of(&st.lay, st.caret), 1, "Down moves one visual line")
	move_v(&st, -1, false)
	eq_int(line_of(&st.lay, st.caret), 0, "Up comes back")
	eq_int(st.caret.off, mid, "and lands on the remembered column")

	// A caret parked exactly on a soft break belongs to the line that starts
	// there. Getting this backwards strands Down and Page Down on that break:
	// they step onto it, are told they are still on the line above, and never
	// move again.
	{
		ok(len(st.lay.lines) >= 3, "the test paragraph wrapped to %d lines", len(st.lay.lines))
		brk := st.lay.lines[1].start
		eq_int(brk, st.lay.lines[0].end, "line 1 starts where line 0 ends")
		ok(brk > st.lay.lines[0].vis_end, "the break swallowed a space")
		eq_int(line_of(&st.lay, Pos{0, brk}), 1, "a caret on the break is on the lower line")
		eq_int(
			line_of(&st.lay, Pos{0, st.lay.lines[0].vis_end}),
			0,
			"a caret before the break is on the upper line",
		)

		// Walking down with the arrow keys must reach every line and stop at
		// the end, not stall part way.
		st.caret = Pos{0, 0}
		st.anchor = st.caret
		st.goal_ok = false
		seen := 0
		for i in 0 ..< len(st.lay.lines) + 4 {
			before := st.caret
			move_v(&st, 1, false)
			if st.caret == before {
				break
			}
			seen += 1
			_ = i
		}
		eq_int(seen, len(st.lay.lines), "Down visits every line and then stops")
		ok(st.caret == doc_end(&st.doc), "and finishes at the end of the document")

		// Page Down over a wrapped paragraph lands at the end rather than
		// stalling on a break.
		st.caret = Pos{0, 0}
		st.anchor = st.caret
		st.goal_ok = false
		move_v(&st, 40, false)
		move_v(&st, 40, false)
		ok(st.caret == doc_end(&st.doc), "two page-downs reach the end of the document")
	}

	// Home and End work on the visual line, not the paragraph.
	st.caret = Pos{0, mid}
	move_line_edge(&st, true, false)
	eq_int(st.caret.off, st.lay.lines[0].vis_end, "End goes to the end of the visual line")
	move_line_edge(&st, false, false)
	eq_int(st.caret.off, 0, "Home goes to its start")
}

// ---------------------------------------------------------------------------
// 7. Pagination
// ---------------------------------------------------------------------------

test_pagination :: proc(fonts: ^p.Fonts) {
	section("pagination")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)

	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 200),
	}
	for i in 0 ..< 120 {
		append(
			&st.doc.paras,
			para_make(
				.Body,
				fmt.tprintf("Paragraph %d, with enough words in it to take a line or two of the measure.", i),
			),
		)
	}
	relayout(&st)

	ok(st.lay.pages > 1, "120 paragraphs need %d pages", st.lay.pages)

	// No line may hang off the bottom of its page, and pages must be used in
	// order with no gaps.
	seen := 0
	for l, li in st.lay.lines {
		ok(l.y >= -0.01, "line %d sits inside the text area", li)
		ok(l.y + l.h <= CONTENT_H + 0.5, "line %d does not overflow the page", li)
		ok(l.page >= seen && l.page <= seen + 1, "line %d advances the page by at most one", li)
		seen = l.page
	}
	eq_int(seen, st.lay.pages - 1, "the last line is on the last page")

	// Each page is reasonably full: a new page only starts because the next
	// line would not have fitted.
	for pg in 0 ..< st.lay.pages - 1 {
		lo, hi := page_lines(&st.lay, pg)
		ok(lo >= 0, "page %d has lines", pg)
		last := st.lay.lines[hi]
		next := st.lay.lines[hi + 1]
		// Orphan control can break a page one line early, and every paragraph
		// here leaves 11 px after it, so the slack a page may legitimately end
		// with is two lines plus that spacing — no more.
		leftover := CONTENT_H - (last.y + last.h)
		ok(
			leftover < 2 * next.h + 12,
			"page %d breaks only because the next lines would overflow (%.1f px left)",
			pg,
			f64(leftover),
		)
	}

	// A hard page break starts a new sheet wherever it is put.
	{
		pages_now := st.lay.pages
		first_on_2 := -1
		for l, li in st.lay.lines {
			if l.page == 1 {
				first_on_2 = li
				break
			}
		}
		ok(first_on_2 > 0, "page 2 starts somewhere")
		victim := st.lay.lines[first_on_2].para - 2
		st.doc.paras[victim].break_before = true
		relayout(&st)
		moved := -1
		for l, li in st.lay.lines {
			if l.para == victim {
				moved = l.page
				break
			}
		}
		eq_int(moved, 1, "the paragraph with a break on it moved to the next page")
		ok(st.lay.pages >= pages_now, "and the document did not get shorter")
		st.doc.paras[victim].break_before = false
		relayout(&st)
		eq_int(st.lay.pages, pages_now, "removing the break restores the page count")
	}

	// Growing a paragraph reflows the pages.
	pages_before := st.lay.pages
	for i in 0 ..< 40 {
		st.doc.paras[i].kind = .H1
	}
	relayout(&st)
	ok(st.lay.pages > pages_before, "making 40 paragraphs headings grew the document to %d pages", st.lay.pages)
}

// ---------------------------------------------------------------------------
// 8. Markdown round trip
// ---------------------------------------------------------------------------

MD_SOURCE :: `# Title

Plain body text with **bold**, *italic*, ***both***, <u>underline</u> and ` + "`code`" + ` inside it.

## Second level

### Third level

- first bullet
- second bullet with **weight**
  - nested bullet

1. first item
2. second item

> A quotation, with *emphasis*.

` +
	"```" +
	`
fn main() {
    println!("hello");
}
` +
	"```" +
	`

Closing paragraph.
`

test_markdown :: proc() {
	section("Markdown round trip")

	d1 := doc_from_markdown(MD_SOURCE)
	defer doc_destroy(&d1)

	// Structure survived the import.
	ok(d1.paras[0].kind == .H1, "the first paragraph is an H1")
	eq_str(text_of(&d1)[:5], "Title", "with its text")
	found_h2, found_h3, found_quote, found_code, bullets, numbers, nested := false, false, false, false, 0, 0, 0
	for &pa in d1.paras {
		switch pa.kind {
		case .H2:
			found_h2 = true
		case .H3:
			found_h3 = true
		case .Quote:
			found_quote = true
		case .Code:
			found_code = true
		case .Body, .H1:
		}
		if pa.list == .Bullet {
			bullets += 1
			if pa.depth > 0 {nested += 1}
		}
		if pa.list == .Numbered {numbers += 1}
	}
	ok(found_h2, "H2 imported")
	ok(found_h3, "H3 imported")
	ok(found_quote, "quote imported")
	ok(found_code, "fenced code imported")
	eq_int(bullets, 3, "three bullets")
	eq_int(numbers, 2, "two numbered items")
	eq_int(nested, 1, "one nested bullet")

	// Inline styles landed on the right words.
	had_bold, had_ital, had_both, had_u, had_mono := false, false, false, false, false
	for &pa in d1.paras {
		for &r in pa.runs {
			t := string(r.text[:])
			cs := r.style
			if t == "bold" && cs.bold && !cs.italic {had_bold = true}
			if t == "italic" && cs.italic && !cs.bold {had_ital = true}
			if t == "both" && cs.bold && cs.italic {had_both = true}
			if t == "underline" && cs.underline {had_u = true}
			if t == "code" && cs.mono {had_mono = true}
		}
	}
	ok(had_bold, "**bold** became a bold run")
	ok(had_ital, "*italic* became an italic run")
	ok(had_both, "***both*** became bold and italic")
	ok(had_u, "<u>underline</u> became an underlined run")
	ok(had_mono, "`code` became a mono run")

	// Export, re-import, export again: the two exports must agree.
	md1 := doc_to_markdown(&d1, context.temp_allocator)
	d2 := doc_from_markdown(md1)
	defer doc_destroy(&d2)
	md2 := doc_to_markdown(&d2, context.temp_allocator)
	eq_str(md2, md1, "Markdown export is a fixed point")
	eq_int(len(d2.paras), len(d1.paras), "the paragraph count survives the round trip")

	for i in 0 ..< min(len(d1.paras), len(d2.paras)) {
		a, b := &d1.paras[i], &d2.paras[i]
		ok(a.kind == b.kind, "paragraph %d keeps its kind (%v vs %v)", i, a.kind, b.kind)
		ok(a.list == b.list, "paragraph %d keeps its list kind", i)
		eq_int(b.depth, a.depth, "paragraph %d keeps its depth", i)
		eq_str(shape(b), shape(a), "paragraph %d keeps its runs", i)
	}

	// Characters Markdown gives meaning to must survive as text.
	d3 := Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	defer doc_destroy(&d3)
	append(&d3.paras, para_make(.Body, "a*b_c`d[e]f\\g <h>"))
	md3 := doc_to_markdown(&d3, context.temp_allocator)
	d4 := doc_from_markdown(md3)
	defer doc_destroy(&d4)
	eq_str(text_of(&d4), "a*b_c`d[e]f\\g <h>", "Markdown metacharacters round-trip")
}

// ---------------------------------------------------------------------------
// 9. The native format
// ---------------------------------------------------------------------------

test_json :: proc() {
	section("native JSON round trip")

	d := doc_from_markdown(MD_SOURCE)
	defer doc_destroy(&d)
	// Add things Markdown cannot carry, which the native format must.
	apply_patch(&d, Pos{2, 0}, Pos{2, 5}, {{.Size, .Color}, Char_Style{size = 28, color = 0xff2563eb}})
	d.paras[2].align = .Justify
	d.paras[4].before = 7
	d.paras[4].after = 3.5
	d.paras[5].break_before = true

	j1 := doc_to_json(&d, context.temp_allocator)
	d2, ok1 := doc_from_json(j1)
	ok(ok1, "the native format parses")
	defer doc_destroy(&d2)
	j2 := doc_to_json(&d2, context.temp_allocator)
	eq_str(j2, j1, "the native format round-trips byte for byte")

	eq_int(len(d2.paras), len(d.paras), "paragraph count")
	ok(d2.paras[2].align == .Justify, "alignment survives")
	ok(d2.paras[4].before == 7, "space before survives")
	ok(d2.paras[5].break_before, "a hard page break survives")
	for i in 0 ..< min(len(d.paras), len(d2.paras)) {
		eq_str(shape(&d2.paras[i]), shape(&d.paras[i]), "paragraph %d runs survive", i)
	}

	// Strings with quotes, backslashes and newlines in them.
	d3 := Doc {
		paras = make([dynamic]Paragraph, 0, 2),
	}
	defer doc_destroy(&d3)
	append(&d3.paras, para_make(.Body, "he said \"hi\\there\"\tand left"))
	j3 := doc_to_json(&d3, context.temp_allocator)
	d4, ok3 := doc_from_json(j3)
	ok(ok3, "escaped text parses")
	defer doc_destroy(&d4)
	eq_str(text_of(&d4), "he said \"hi\\there\"\tand left", "escapes round-trip")

	// Garbage must be rejected rather than crash.
	_, bad := doc_from_json("{\"nope\": 1}")
	ok(!bad, "a file without paragraphs is rejected")
	_, bad2 := doc_from_json("not json at all")
	ok(!bad2, "nonsense is rejected")
}

// ---------------------------------------------------------------------------
// 10. Find and replace
// ---------------------------------------------------------------------------

test_find :: proc(fonts: ^p.Fonts) {
	section("find and replace")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}

	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	append(&st.doc.paras, para_make(.Body, "the cat sat on the mat"))
	append(&st.doc.paras, para_make(.Body, "The CAT came back"))
	relayout(&st)

	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("cat"))
	eq_int(count_hits(&st), 2, "case-insensitive search finds both")

	st.caret = Pos{0, 0}
	st.anchor = st.caret
	ok(find_next(&st), "find jumps to the first match")
	eq_int(st.anchor.off, 4, "selecting the match")
	eq_int(st.caret.off, 7, "end of the match")
	ok(find_next(&st), "and on to the second")
	eq_int(st.caret.para, 1, "which is in the next paragraph")
	ok(find_next(&st), "the search wraps around")
	eq_int(st.caret.para, 0, "back to the first paragraph")

	// Replace keeps the style the match had.
	apply_patch(&st.doc, Pos{0, 4}, Pos{0, 7}, {{.Bold}, Char_Style{bold = true}})
	clear(&st.repl)
	append(&st.repl, ..transmute([]u8)string("dog"))
	st.caret = Pos{0, 0}
	st.anchor = st.caret
	replace_one(&st)
	ok(strings.contains(text_of(&st.doc), "the dog sat"), "the first match was replaced")
	ok(range_all_bold(&st.doc, Pos{0, 4}, Pos{0, 7}), "the replacement inherited the style")

	replace_all(&st)
	eq_int(count_hits(&st), 0, "replace all leaves no matches")
	eq_str(text_of(&st.doc), "the dog sat on the mat\nThe dog came back", "both occurrences replaced")

	// One undo takes back the whole replace-all.
	do_undo(&st)
	ok(strings.contains(text_of(&st.doc), "CAT"), "undo restores the replaced text")

	// A replacement longer than the search term must not loop forever.
	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("a"))
	clear(&st.repl)
	append(&st.repl, ..transmute([]u8)string("aa"))
	replace_all(&st)
	ok(count_hits(&st) > 0, "a growing replacement terminates")
}
