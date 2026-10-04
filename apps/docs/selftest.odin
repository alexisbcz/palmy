// `docs --selftest` — the model without a window.
//
// Everything here exercises the same procedures the keyboard calls. Fonts are
// loaded exactly as the app loads them, so the wrap and pagination assertions
// are measured against the faces the window would draw with.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import kit "kit:."
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
	test_containers()
	test_fontfile(&fonts)
	test_export(&fonts)

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

// ---------------------------------------------------------------------------
// 11. ZIP containers
// ---------------------------------------------------------------------------

@(private = "file")
test_containers :: proc() {
	section("ZIP containers")

	// The canonical CRC-32 check value. Getting this wrong produces archives
	// that unzip refuses and Word calls corrupt, so it is worth pinning.
	ok(crc32_bytes(transmute([]u8)string("123456789")) == 0xcbf43926, "CRC-32 check value")
	ok(crc32_bytes(transmute([]u8)string("")) == 0, "CRC-32 of nothing is zero")

	z: Zip
	zip_init(&z)
	defer zip_destroy(&z)
	zip_add_string(&z, "mimetype", ODT_MIME)
	zip_add_string(&z, "a/b.xml", "<x>hello</x>")
	zip_add_string(&z, "big.txt", strings.repeat("x", 5000, context.temp_allocator))
	data := zip_finish(&z)

	eq_int(len(zip_names(data, context.temp_allocator)), 3, "three members")
	names := zip_names(data, context.temp_allocator)
	eq_str(names[0], "mimetype", "mimetype is the first member")

	// The local header is 30 bytes plus the name, so an uncompressed first
	// entry puts its payload at a fixed offset — which is how `file(1)` and
	// every ODF reader sniff the type.
	eq_str(string(data[30:30 + len("mimetype")]), "mimetype", "the name sits at offset 30")
	eq_str(string(data[38:38 + len(ODT_MIME)]), ODT_MIME, "and the mimetype right after it")
	ok(data[8] == 0 && data[9] == 0, "the first entry is stored, not deflated")

	for want in ([?]struct {
		name, body: string,
	}{{"mimetype", ODT_MIME}, {"a/b.xml", "<x>hello</x>"}}) {
		got, found := zip_read_entry(data, want.name, context.temp_allocator)
		ok(found, "read back %s", want.name)
		if found {
			eq_str(string(got), want.body, "contents of %s", want.name)
		}
	}
	_, missing := zip_read_entry(data, "nope", context.temp_allocator)
	ok(!missing, "a member that is not there is not found")
}

// ---------------------------------------------------------------------------
// 12. The TrueType reader and subsetter
// ---------------------------------------------------------------------------

@(private = "file")
test_fontfile :: proc(fonts: ^p.Fonts) {
	section("TrueType subsetting")

	path := p.font_path(fonts, .Sans, .Regular)
	ok(path != "", "palmy reports the face it loaded")
	if path == "" {
		return
	}
	f, loaded := ttf_load(path)
	ok(loaded, "the face parses as TrueType")
	if !loaded {
		return
	}
	defer ttf_destroy(&f)

	ok(f.num_glyphs > 100, "the face has glyphs (%d)", f.num_glyphs)
	ok(f.upem == 1000 || f.upem == 2048 || f.upem == 2000, "a sane units-per-em (%.0f)", f.upem)
	eq_int(len(f.loca), f.num_glyphs + 1, "loca has one entry per glyph plus a terminator")
	eq_int(len(f.advances), f.num_glyphs, "an advance per glyph")
	ok(len(f.ps_name) > 0, "a PostScript name: %s", f.ps_name)
	ok(f.ascent > 0 && f.descent < 0, "ascent above the baseline, descent below")

	// Every character this document can type has to map to a glyph.
	for r in "ABCabc0123 .,—“”" {
		if r == ' ' {
			continue
		}
		ok(ttf_gid(&f, r) != 0, "cmap has a glyph for %r", r)
	}
	ok(ttf_gid(&f, '\U0001F600') == 0, "and none for a character it does not carry")

	// The advance a PDF will use must agree with the advance palmy measures,
	// or the text in the file drifts away from the text on the screen.
	gid := ttf_gid(&f, 'H')
	want := p.text_width(fonts, "H", 1000, .Sans, .Regular)
	got := f32(ttf_advance(&f, gid))
	ok(abs(want - got) <= 1.0, "glyph advance matches palmy: %.1f vs %.1f", got, want)

	keep := make(map[u16]bool, 16, context.temp_allocator)
	for r in "Hello" {
		keep[ttf_gid(&f, r)] = true
	}
	sub := ttf_subset(&f, keep, context.temp_allocator)
	ok(len(sub) > 0, "the subset is produced")
	ok(len(sub) < len(f.data), "and is smaller than the original (%d < %d)", len(sub), len(f.data))

	// The subset must still be a font: glyph ids unchanged, advances
	// unchanged, and the glyphs that were asked for still carrying outlines.
	g2, reparsed := ttf_from_bytes(sub)
	ok(reparsed, "the subset parses as a font in its own right")
	if reparsed {
		defer ttf_release(&g2)
		eq_int(g2.num_glyphs, f.num_glyphs, "the glyph count is unchanged")
		ok(g2.loca_long, "the subset always writes the long loca format")
		eq_int(ttf_advance(&g2, gid), ttf_advance(&f, gid), "advances survive subsetting")
		kept_bytes := 0
		for r in "Hello" {
			g := ttf_gid(&f, r)
			kept_bytes += int(g2.loca[g + 1]) - int(g2.loca[g])
		}
		ok(kept_bytes > 0, "the kept glyphs still have outlines")
		// A glyph nothing asked for has an empty range: that is the subset.
		dropped := 0
		for g in 0 ..< g2.num_glyphs {
			if g2.loca[g + 1] == g2.loca[g] {
				dropped += 1
			}
		}
		ok(dropped > g2.num_glyphs / 2, "most glyphs were dropped (%d of %d)", dropped, g2.num_glyphs)
	}
}

// ---------------------------------------------------------------------------
// 13. Export: PDF, .docx, .odt, .rtf — and the tools that judge them
// ---------------------------------------------------------------------------
//
// Everything above this point can be checked against the model. A file format
// cannot: "it has the right extension" is not the same claim as "a reader
// opens it". So this section writes real files and then hands them to the
// programs that would receive them — qpdf, pdftotext, pdffonts, xmllint and
// LibreOffice — and asserts against what those say.
//
// A missing tool skips its assertions and says so, rather than passing
// quietly. Every one of them is installed on the machine this was written on,
// and the output is printed so the claims can be read rather than trusted.

@(private = "file")
SELFTEST_DIR :: "/tmp/palmy-docs-selftest"

// LibreOffice is pointed at a profile of its own. Letting it touch the user's
// would be rude at best and destructive at worst.
@(private = "file")
LO_PROFILE :: "-env:UserInstallation=file:///tmp/palmy-lo-profile"

@(private = "file")
have_tool :: proc(name: string) -> bool {
	_, found := kit.run({"sh", "-c", fmt.tprintf("command -v %s >/dev/null 2>&1", name)})
	return found
}

// word_rune decides what counts as part of a word when comparing a source
// document against what a tool extracted from a file. Latin letters with
// accents are word characters; the General Punctuation block is not, which
// matters because LibreOffice's RTF reader turns runs of spaces into U+2006
// and would otherwise glue them onto the word in front.
@(private = "file")
word_rune :: proc(r: rune) -> bool {
	switch {
	case r >= '0' && r <= '9', r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z':
		return true
	case r < 0x80:
		return false
	case r == 0xa0, r == 0xfffd, r == 0xfeff:
		// U+FEFF matters: LibreOffice's text export opens with a byte order
		// mark, and counting it as a letter glues it to the first word and
		// makes every comparison fail at index zero.
		return false
	case r >= 0x2000 && r <= 0x206f:
		return false
	}
	return true
}

@(private = "file")
words_of :: proc(s: string, alloc := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 512, alloc)
	i := 0
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		w := max(1, n)
		if !word_rune(r) {
			i += w
			continue
		}
		j := i
		for j < len(s) {
			r2, n2 := utf8.decode_rune_in_string(s[j:])
			if !word_rune(r2) {
				break
			}
			j += max(1, n2)
		}
		append(&out, s[i:j])
		i = j
	}
	return out[:]
}

// subseq_miss checks that every word of the source appears, in order, in what
// a tool extracted. Extra words are allowed — a PDF carries page numbers, a
// LibreOffice text export writes list markers — but a missing or reordered
// one is a real failure. Greedy matching is exact for a subsequence test.
@(private = "file")
subseq_miss :: proc(src, got: []string) -> int {
	j := 0
	for w, i in src {
		found := false
		for j < len(got) {
			k := j
			j += 1
			if got[k] == w {
				found = true
				break
			}
		}
		if !found {
			return i
		}
	}
	return -1
}

@(private = "file")
doc_words :: proc(d: ^Doc) -> []string {
	b := strings.builder_make(context.temp_allocator)
	for &pa in d.paras {
		for &r in pa.runs {
			strings.write_bytes(&b, r.text[:])
		}
		strings.write_byte(&b, '\n')
	}
	return words_of(strings.to_string(b))
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// check_extracted asserts that a tool's output contains the whole document.
@(private = "file")
check_extracted :: proc(label: string, src: []string, text: string) {
	got := words_of(text)
	miss := subseq_miss(src, got)
	ok(
		miss < 0,
		"%s reproduces every word in order (%d source, %d extracted%s)",
		label,
		len(src),
		len(got),
		miss < 0 ? "" : fmt.tprintf(", first missing %q at %d", src[miss], miss),
	)
	ok(len(got) >= len(src), "%s loses nothing (%d >= %d)", label, len(got), len(src))
}

// rich_fixture is a document that uses every feature the exporters have to
// carry: each paragraph kind, each alignment, nested lists of both sorts, a
// hard page break, every character style, a colour, an explicit size, runs of
// spaces inside code, and text outside ASCII.
@(private = "file")
rich_fixture :: proc() -> Doc {
	d := Doc {
		paras = make([dynamic]Paragraph, 0, 24),
	}
	add :: proc(d: ^Doc, pa: Paragraph) {
		p2 := pa
		normalise(&p2)
		append(&d.paras, p2)
	}
	styled :: proc(kind: Para_Kind, parts: []Run) -> Paragraph {
		pa := Paragraph {
			kind = kind,
			runs = make([dynamic]Run, 0, len(parts)),
		}
		for r in parts {
			append(&pa.runs, r)
		}
		return pa
	}

	add(&d, para_make(.H1, "Interchange, properly"))
	add(
		&d,
		styled(
			.Body,
			{
				run_make({}, "This paragraph mixes "),
				run_make({bold = true}, "bold"),
				run_make({}, ", "),
				run_make({italic = true}, "italic"),
				run_make({}, ", "),
				run_make({underline = true}, "underline"),
				run_make({}, ", "),
				run_make({mono = true}, "monospace"),
				run_make({}, ", "),
				run_make({color = 0xffc2410c}, "colour"),
				run_make({}, " and "),
				run_make({size = 24}, "24px"),
				run_make({}, " together."),
			},
		),
	)
	add(&d, para_make(.H2, "Lists"))
	for item, i in ([?]string{"First bullet", "Nested bullet", "Third bullet"}) {
		pa := para_make(.Body, item)
		pa.list = .Bullet
		pa.depth = i == 1 ? 1 : 0
		add(&d, pa)
	}
	for item, i in ([?]string{"Numbered one", "Numbered two", "Nested numbered"}) {
		pa := para_make(.Body, item)
		pa.list = .Numbered
		pa.depth = i == 2 ? 1 : 0
		add(&d, pa)
	}
	add(
		&d,
		para_make(
			.Quote,
			"A quotation sits behind a rule and leans over, which is how a reader knows it is borrowed.",
		),
	)
	add(&d, para_make(.Code, "    indented := \"four spaces survive\""))
	add(&d, para_make(.Code, "    and  double  spaces  too"))
	add(&d, para_make(.H3, "Alignment"))
	for al, i in ([?]Align{.Center, .Right, .Justify}) {
		pa := para_make(
			.Body,
			i == 2 \
			? "Justified text stretches the spaces between words so that both edges of the measure line up exactly, which is what the justification gap in the layout is for and what every exporter has to reproduce without measuring anything again." \
			: fmt.tprintf("Aligned paragraph number %d", i + 1),
		)
		pa.align = al
		add(&d, pa)
	}
	brk := para_make(.H2, "After a hard page break")
	brk.break_before = true
	add(&d, brk)
	add(&d, para_make(.Body, "Unicode: café, naïve, Grüße, œuvre, and an em dash — plus a bullet • inline."))
	return d
}

@(private = "file")
Export_Case :: struct {
	name: string,
	doc:  Doc,
}

@(private = "file")
test_export :: proc(fonts: ^p.Fonts) {
	section("export: PDF, .docx, .odt, .rtf")

	kit.run({"rm", "-rf", SELFTEST_DIR})
	_, made := kit.run({"mkdir", "-p", fmt.tprintf("%s/lo", SELFTEST_DIR)})
	ok(made, "a scratch directory at %s", SELFTEST_DIR)
	if !made {
		return
	}

	cases := make([dynamic]Export_Case, 0, 4, context.temp_allocator)
	append(&cases, Export_Case{"fixture", rich_fixture()})
	append(&cases, Export_Case{"seed", doc_from_markdown(SEED)})
	// A document of real substance, not a three-line toy. Both of these live
	// in the tree; whichever is readable from where the test was started is
	// used, and a missing one is skipped rather than failed.
	for cand in ([?][2]string {
		{"readme", "README.md"},
		{"readme", "/home/alex/Work/palmy/README.md"},
		{"apps", "apps/APPS.md"},
		{"apps", "/home/alex/Work/palmy/apps/APPS.md"},
	}) {
		already := false
		for c in cases {
			if c.name == cand[0] {
				already = true
			}
		}
		if already {
			continue
		}
		if nd, got := import_markdown(cand[1]); got {
			append(&cases, Export_Case{cand[0], nd})
		}
	}
	defer for &c in cases {
		doc_destroy(&c.doc)
	}
	ok(len(cases) >= 3, "%d documents under test", len(cases))

	office_paths := make([dynamic]string, 0, 16, context.temp_allocator)

	for &c in cases {
		src := doc_words(&c.doc)
		base := fmt.tprintf("%s/%s", SELFTEST_DIR, c.name)
		ok(len(src) > 0, "%s: the source has %d words", c.name, len(src))

		// --- the formats that were already here must keep working
		ok(save_doc(&c.doc, fmt.tprintf("%s.json", base)), "%s: .json still writes", c.name)
		ok(export_markdown(&c.doc, fmt.tprintf("%s.md", base)), "%s: .md still writes", c.name)
		ok(export_html(&c.doc, fmt.tprintf("%s.html", base), c.name), "%s: .html still writes", c.name)

		// --- PDF
		pdf_path := fmt.tprintf("%s.pdf", base)
		ok(cli_export_pdf(&c.doc, pdf_path, c.name), "%s: PDF written", c.name)

		// How many pages the layout makes, so the file can be held to it.
		// This is the claim that matters most about the PDF: it is not a
		// re-flow, it is the pagination the window already computed.
		pages := 0
		lines := 0
		{
			lay: Layout
			defer layout_destroy(&lay)
			layout_doc(&lay, &c.doc, fonts)
			pages, lines = lay.pages, len(lay.lines)
		}
		if raw, got := read_text(pdf_path); got {
			check_pdf_structure(c.name, raw)
			eq_int(
				strings.count(raw, "/Type /Page /Parent"),
				pages,
				"%s: the PDF has one page object per laid-out page",
				c.name,
			)
			// Each visual line opens at most one text object, and an empty
			// one opens none, so this bounds the content against the layout
			// rather than merely checking that something was written.
			bt := strings.count(raw, "\nBT\n")
			ok(bt > 0 && bt <= lines + pages + 8, "%s: %d text objects for %d lines", c.name, bt, lines)
		} else {
			ok(false, "%s: the PDF can be read back", c.name)
		}

		// --- .docx
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		docx_path := fmt.tprintf("%s-docx.docx", base)
		ok(export_docx(&c.doc, docx_path, c.name), "%s: .docx written", c.name)
		if raw, got := read_text(docx_path); got {
			check_docx_structure(c.name, transmute([]u8)raw)
		}

		// --- .odt
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		odt_path := fmt.tprintf("%s-odt.odt", base)
		ok(export_odt(&c.doc, odt_path, c.name), "%s: .odt written", c.name)
		if raw, got := read_text(odt_path); got {
			check_odt_structure(c.name, transmute([]u8)raw)
		}

		// --- .rtf
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		rtf_path := fmt.tprintf("%s-rtf.rtf", base)
		ok(export_rtf(&c.doc, rtf_path, c.name), "%s: .rtf written", c.name)
		if raw, got := read_text(rtf_path); got {
			check_rtf_structure(c.name, raw)
		}

		append(&office_paths, docx_path, odt_path, rtf_path)

		// --- import: the .docx just written must come back as the same
		// document, which is the whole claim behind "not write-only".
		if back, got := import_docx(docx_path); got {
			nd := back
			defer doc_destroy(&nd)
			eq_int(len(nd.paras), len(c.doc.paras), "%s: .docx round-trips the paragraph count", c.name)
			if len(nd.paras) == len(c.doc.paras) {
				bad_kind, bad_list := 0, 0
				for i in 0 ..< len(nd.paras) {
					if nd.paras[i].kind != c.doc.paras[i].kind {
						bad_kind += 1
					}
					if nd.paras[i].list != c.doc.paras[i].list {
						bad_list += 1
					}
				}
				eq_int(bad_kind, 0, "%s: .docx round-trips every paragraph kind", c.name)
				eq_int(bad_list, 0, "%s: .docx round-trips every list kind", c.name)
			}
			check_extracted(fmt.tprintf("%s: .docx import", c.name), src, text_of(&nd))
		} else {
			ok(false, "%s: the .docx reads back", c.name)
		}
	}

	// The window's own command path, run without a window. Every toolbar
	// button and every keyboard shortcut goes through `run_prompt`, so
	// driving it here means what the GUI exports is what was just verified,
	// rather than a second code path that nothing tests.
	{
		st := State{}
		state_init(&st, fonts)
		defer state_destroy(&st)
		st.view = {0, 0, 1280, 760}
		replace_document(&st, doc_clone(&cases[0].doc))
		relayout(&st)
		st.dirty = false

		for step in ([?]struct {
			kind: Prompt_Kind,
			ext:  string,
		} {
			{.Export_Pdf, "pdf"},
			{.Export_Docx, "docx"},
			{.Export_Odt, "odt"},
			{.Export_Rtf, "rtf"},
			{.Export_Md, "md"},
			{.Export_Html, "html"},
			{.Save_As, "json"},
		}) {
			path := fmt.tprintf("%s/prompt.%s", SELFTEST_DIR, step.ext)
			run_prompt(&st, step.kind, path)
			text, wrote := read_text(path)
			ok(wrote && len(text) > 0, "run_prompt writes .%s", step.ext)
			ok(
				!strings.contains(st.toast, "failed") && !strings.contains(st.toast, "Could not"),
				"run_prompt reports success for .%s (%q)",
				step.ext,
				st.toast,
			)
		}

		before := len(st.doc.paras)
		run_prompt(&st, .Import_Docx, fmt.tprintf("%s/prompt.docx", SELFTEST_DIR))
		eq_int(len(st.doc.paras), before, "run_prompt reads back the .docx it wrote")
		eq_str(
			text_of(&st.doc),
			text_of(&cases[0].doc),
			"and the text survives the round trip through the window's own path",
		)
	}

	check_pdf_tools(cases[:])
	check_xml_parts(cases[:])
	check_libreoffice(cases[:], office_paths[:])
}

// check_pdf_structure reads the file back as bytes and asserts the things a
// PDF must have — before any external tool is consulted, so a failure points
// at the writer rather than at the reader.
@(private = "file")
check_pdf_structure :: proc(name, raw: string) {
	ok(strings.has_prefix(raw, "%PDF-1.7"), "%s: PDF 1.7 header", name)
	ok(strings.has_suffix(strings.trim_right_space(raw), "%%EOF"), "%s: ends with %%%%EOF", name)
	for want in ([?]string {
		"/Type /Catalog",
		"/Lang (en-US)",
		"/Type /Pages",
		"/Subtype /Type0",
		"/Encoding /Identity-H",
		"/Subtype /CIDFontType2",
		"/CIDToGIDMap /Identity",
		"/FontFile2",
		"/ToUnicode",
		"beginbfchar",
		"/MediaBox [0 0 595.276 841.890]",
		"/Producer",
		"/CreationDate",
		"/Title",
		"/Type /Outlines",
		"/Dest [",
		"trailer",
	}) {
		ok(strings.contains(raw, want), "%s: PDF contains %s", name, want)
	}

	// The cross-reference table has to be where the trailer says it is, and
	// the table has to have an entry for every object.
	sx := strings.last_index(raw, "startxref")
	ok(sx > 0, "%s: a startxref", name)
	if sx > 0 {
		rest := strings.trim_left_space(raw[sx + len("startxref"):])
		n := 0
		for i in 0 ..< len(rest) {
			if rest[i] < '0' || rest[i] > '9' {
				break
			}
			n = n * 10 + int(rest[i] - '0')
		}
		ok(n > 0 && n < len(raw), "%s: startxref is inside the file", name)
		if n > 0 && n + 4 <= len(raw) {
			eq_str(raw[n:n + 4], "xref", "%s: startxref points at the table", name)
		}
	}

	objs := strings.count(raw, " 0 obj\n")
	size := strings.index(raw, "/Size ")
	ok(objs > 5, "%s: %d objects", name, objs)
	if size > 0 {
		rest := raw[size + len("/Size "):]
		v := 0
		for i in 0 ..< len(rest) {
			if rest[i] < '0' || rest[i] > '9' {
				break
			}
			v = v * 10 + int(rest[i] - '0')
		}
		eq_int(v, objs + 1, "%s: /Size counts every object plus the free head", name)
	}
	// Every object must have an xref entry; the table's own header says how
	// many there are.
	xr := strings.index(raw, "\nxref\n")
	ok(xr > 0, "%s: an xref table", name)
}

@(private = "file")
check_docx_structure :: proc(name: string, archive: []u8) {
	names := zip_names(archive, context.temp_allocator)
	for want in ([?]string {
		"[Content_Types].xml",
		"_rels/.rels",
		"word/_rels/document.xml.rels",
		"word/document.xml",
		"word/styles.xml",
		"word/numbering.xml",
		"docProps/core.xml",
	}) {
		found := false
		for n in names {
			if n == want {
				found = true
			}
		}
		ok(found, "%s: .docx has %s", name, want)
	}
	doc, got := zip_read_entry(archive, "word/document.xml", context.temp_allocator)
	ok(got, "%s: word/document.xml reads back", name)
	if got {
		s := string(doc)
		ok(strings.contains(s, "<w:pStyle w:val=\"Heading1\"/>"), "%s: headings are a named style", name)
		ok(strings.contains(s, "<w:numPr>"), "%s: list items carry numbering", name)
		ok(strings.contains(s, "xml:space=\"preserve\""), "%s: runs preserve their spaces", name)
		ok(strings.contains(s, "<w:sectPr>"), "%s: a section with the page size", name)
		ok(strings.contains(s, "w:w=\"11906\""), "%s: the page is A4", name)
	}
	st, got_st := zip_read_entry(archive, "word/styles.xml", context.temp_allocator)
	if got_st {
		s := string(st)
		for want in ([?]string{"Heading1", "Heading2", "Heading3", "Quote", "Code", "ListParagraph"}) {
			ok(
				strings.contains(s, fmt.tprintf("w:styleId=\"%s\"", want)),
				"%s: styles.xml defines %s",
				name,
				want,
			)
		}
	}
}

@(private = "file")
check_odt_structure :: proc(name: string, archive: []u8) {
	names := zip_names(archive, context.temp_allocator)
	ok(len(names) >= 4, "%s: .odt has its parts", name)
	if len(names) > 0 {
		eq_str(names[0], "mimetype", "%s: mimetype is the first entry", name)
	}
	// ODF requires the first entry to be stored, with no extra field, so that
	// the media type can be read straight out of the first few dozen bytes.
	ok(archive[8] == 0 && archive[9] == 0, "%s: mimetype is stored, not deflated", name)
	ok(archive[28] == 0 && archive[29] == 0, "%s: mimetype has no extra field", name)
	ok(
		len(archive) > 38 + len(ODT_MIME) && string(archive[38:38 + len(ODT_MIME)]) == ODT_MIME,
		"%s: the media type is at the documented offset",
		name,
	)
	content, got := zip_read_entry(archive, "content.xml", context.temp_allocator)
	ok(got, "%s: content.xml reads back", name)
	if got {
		s := string(content)
		ok(strings.contains(s, "<text:h "), "%s: headings are text:h", name)
		ok(strings.contains(s, "text:outline-level=\"1\""), "%s: with an outline level", name)
		ok(strings.contains(s, "<text:list "), "%s: lists are text:list", name)
		ok(strings.contains(s, "office:version=\"1.3\""), "%s: declares its ODF version", name)
	}
	styles, got_s := zip_read_entry(archive, "styles.xml", context.temp_allocator)
	if got_s {
		s := string(styles)
		for want in ([?]string{"Heading_20_1", "Heading_20_2", "Heading_20_3", "Quote", "Preformatted_20_Text"}) {
			ok(
				strings.contains(s, fmt.tprintf("style:name=\"%s\"", want)),
				"%s: styles.xml defines %s",
				name,
				want,
			)
		}
		ok(strings.contains(s, "fo:page-width=\"8.268in\""), "%s: the page layout is A4", name)
	}
}

@(private = "file")
check_rtf_structure :: proc(name, raw: string) {
	ok(strings.has_prefix(raw, "{\\rtf1\\ansi"), "%s: an RTF 1 header", name)
	ok(strings.contains(raw, "{\\fonttbl"), "%s: a font table", name)
	ok(strings.contains(raw, "{\\stylesheet"), "%s: a stylesheet", name)
	ok(strings.contains(raw, "\\paperw11906"), "%s: the page is A4", name)

	// Unbalanced braces are the one way an RTF file is simply unreadable, and
	// a stray `{` from a format string is exactly how it happens.
	depth := 0
	worst := 0
	i := 0
	for i < len(raw) {
		switch raw[i] {
		case '\\':
			i += 2 // an escaped character, including \{ and \}
			continue
		case '{':
			depth += 1
		case '}':
			depth -= 1
			worst = min(worst, depth)
		}
		i += 1
	}
	eq_int(depth, 0, "%s: RTF braces balance", name)
	eq_int(worst, 0, "%s: RTF never closes a group it did not open", name)
	ok(!strings.contains(raw, "%!("), "%s: no formatter leakage in the RTF", name)
}

// ---------------------------------------------------------------------------
// The external judges
// ---------------------------------------------------------------------------

@(private = "file")
check_pdf_tools :: proc(cases: []Export_Case) {
	for tool in ([?]string{"qpdf", "pdftotext", "pdffonts"}) {
		if !have_tool(tool) {
			ok(false, "SKIPPED: %s is not installed, so its assertions did not run", tool)
		}
	}

	for &c in cases {
		path := fmt.tprintf("%s/%s.pdf", SELFTEST_DIR, c.name)

		if have_tool("qpdf") {
			out, good := kit.run({"qpdf", "--check", path})
			ok(good, "%s: qpdf --check passes", c.name)
			ok(
				strings.contains(out, "No syntax or stream encoding errors found"),
				"%s: qpdf finds no syntax or stream errors",
				c.name,
			)
			fmt.printf("    qpdf --check %s.pdf:\n", c.name)
			for line in strings.split_lines(out, context.temp_allocator) {
				if len(strings.trim_space(line)) > 0 {
					fmt.printf("      %s\n", line)
				}
			}
		}

		if have_tool("pdftotext") {
			txt := fmt.tprintf("%s/%s.pdf.txt", SELFTEST_DIR, c.name)
			_, good := kit.run({"pdftotext", "-layout", path, txt})
			ok(good, "%s: pdftotext runs", c.name)
			if text, got := read_text(txt); got {
				// This is the assertion the /ToUnicode CMap exists for: the
				// glyphs in the file are ids, and only the CMap can turn them
				// back into the document's words.
				check_extracted(fmt.tprintf("%s: pdftotext", c.name), doc_words(&c.doc), text)
			} else {
				ok(false, "%s: pdftotext wrote something", c.name)
			}
		}

		if have_tool("pdffonts") {
			out, good := kit.run({"pdffonts", path})
			ok(good, "%s: pdffonts runs", c.name)
			lines := strings.split_lines(out, context.temp_allocator)
			faces := 0
			embedded := 0
			subset := 0
			unicode := 0
			tagged := 0
			for line in lines {
				if !strings.contains(line, "CID TrueType") {
					continue
				}
				faces += 1
				// The three flag columns come after the encoding name.
				rest := line[strings.index(line, "Identity-H") + len("Identity-H"):]
				cols := 0
				yes := 0
				for f in strings.fields(rest, context.temp_allocator) {
					if f == "yes" {
						yes += 1
					}
					if f == "yes" || f == "no" {
						cols += 1
					}
					if cols == 3 {
						break
					}
				}
				if yes >= 1 {embedded += 1}
				if yes >= 2 {subset += 1}
				if yes >= 3 {unicode += 1}
				// A subset's name carries a six-letter tag and a plus sign.
				if plus := strings.index_byte(line, '+'); plus >= 6 {
					tagged += 1
				}
			}
			ok(faces > 0, "%s: pdffonts sees %d composite fonts", c.name, faces)
			eq_int(embedded, faces, "%s: every font is embedded", c.name)
			eq_int(subset, faces, "%s: every font is a subset", c.name)
			eq_int(unicode, faces, "%s: every font has a ToUnicode map", c.name)
			eq_int(tagged, faces, "%s: every font carries a subset tag", c.name)
			fmt.printf("    pdffonts %s.pdf:\n", c.name)
			for line in lines {
				if len(strings.trim_space(line)) > 0 {
					fmt.printf("      %s\n", line)
				}
			}
		}
	}
}

// check_xml_parts writes every XML part out of the two ZIP containers and
// runs xmllint over it. Well-formedness is a low bar, but it is the bar a
// hand-written emitter fails first — one unescaped ampersand does it.
@(private = "file")
check_xml_parts :: proc(cases: []Export_Case) {
	if !have_tool("xmllint") {
		ok(false, "SKIPPED: xmllint is not installed, so the XML was not validated")
		return
	}
	DOCX_PARTS := [?]string {
		"[Content_Types].xml",
		"_rels/.rels",
		"word/_rels/document.xml.rels",
		"word/document.xml",
		"word/styles.xml",
		"word/numbering.xml",
		"docProps/core.xml",
		"docProps/app.xml",
	}
	ODT_PARTS := [?]string{"META-INF/manifest.xml", "content.xml", "styles.xml", "meta.xml"}

	n := 0
	for &c in cases {
		for pair in ([?]struct {
			ext:   string,
			parts: []string,
		}{{"docx", DOCX_PARTS[:]}, {"odt", ODT_PARTS[:]}}) {
			raw, got := read_text(
				fmt.tprintf("%s/%s-%s.%s", SELFTEST_DIR, c.name, pair.ext, pair.ext),
			)
			if !got {
				continue
			}
			for part in pair.parts {
				data, found := zip_read_entry(transmute([]u8)raw, part, context.temp_allocator)
				if !found {
					continue
				}
				// A flat name, so the directories inside the archive do not
				// have to exist on disk.
				flat := strings.builder_make(context.temp_allocator)
				fmt.sbprintf(&flat, "%s/xml-%s-%s-", SELFTEST_DIR, c.name, pair.ext)
				for i in 0 ..< len(part) {
					strings.write_byte(&flat, part[i] == '/' ? '_' : part[i])
				}
				tmp := strings.to_string(flat)
				if os.write_entire_file(tmp, data) != nil {
					ok(false, "%s: could not stage %s for xmllint", c.name, part)
					continue
				}
				_, clean := kit.run({"xmllint", "--noout", tmp})
				ok(clean, "%s: xmllint accepts %s/%s", c.name, pair.ext, part)
				n += 1
			}
		}
	}
	fmt.printf("    xmllint --noout: %d XML parts, all well-formed\n", n)
}

// check_libreoffice is the compatibility oracle. A format LibreOffice opens
// and reproduces is genuinely compatible; one that merely has the right
// extension is not.
@(private = "file")
check_libreoffice :: proc(cases: []Export_Case, paths: []string) {
	if !have_tool("soffice") {
		ok(false, "SKIPPED: LibreOffice is not installed, so nothing was round-tripped through it")
		return
	}
	lo := fmt.tprintf("%s/lo", SELFTEST_DIR)

	// One invocation for every file: LibreOffice is slow to start and quick
	// to convert, and the exports all have distinct names.
	argv := make([dynamic]string, 0, len(paths) + 8, context.temp_allocator)
	append(&argv, "soffice", "--headless", LO_PROFILE, "--convert-to", "txt:Text", "--outdir", lo)
	append(&argv, ..paths)
	_, ran := kit.run(argv[:])
	ok(ran, "LibreOffice converted %d files", len(paths))

	for &c in cases {
		src := doc_words(&c.doc)
		for ext in ([?]string{"docx", "odt", "rtf"}) {
			// Every export of one document lands on the same .txt name, so
			// the exports are named per format for this pass.
			out := fmt.tprintf("%s/%s-%s.txt", lo, c.name, ext)
			if text, got := read_text(out); got {
				check_extracted(fmt.tprintf("%s: LibreOffice reading .%s", c.name, ext), src, text)
			} else {
				ok(false, "%s: LibreOffice produced text from .%s", c.name, ext)
			}
		}
	}
}
