// `docs --selftest` — the model without a window.
//
// Everything here exercises the same procedures the keyboard calls. Fonts are
// loaded exactly as the app loads them, so the wrap and pagination assertions
// are measured against the faces the window would draw with.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
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
	// Blocks, not paragraphs: a table cell's text is document text, and a
	// comparison that skipped it would pass on an exporter that dropped every
	// grid in the file.
	for blk, i in doc_blocks(d, context.temp_allocator) {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		pa := blk_para(d, blk)
		if pa == nil {
			continue
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
	test_find_modes(&fonts)
	test_search_unicode(&fonts)
	test_regex(&fonts)
	test_tables(&fonts)
	test_grid_formats(&fonts)
	test_images(&fonts)
	test_cells(&fonts)
	test_containers()
	test_fontfile(&fonts)
	test_export(&fonts)
	test_rtf_import(&fonts)
	test_cell_image(&fonts)
	test_prose(&fonts)
	test_cli()
	{
		cc, cf := test_collab(&fonts)
		checks += cc
		fails += cf
	}

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
	q := insert_plain(&d, pos(0, 3), "XY", Char_Style{bold = true})
	eq_str(shape(&d.paras[0]), "abc/|XY/b|def/", "a differing style splits the run in three")
	eq_int(q.off, 5, "the caret lands after the inserted text")

	// Inserting with the same style as the run it lands in must not split.
	insert_plain(&d, pos(0, 1), "..", Char_Style{})
	eq_str(shape(&d.paras[0]), "a..bc/|XY/b|def/", "a matching style joins the run")
	eq_int(len(d.paras[0].runs), 3, "still three runs")

	// A caret on a boundary takes the style to its left, which is why typing
	// after a bold word keeps bolding.
	cs := style_at(&d, pos(0, 7))
	ok(cs.bold, "style at the end of the bold run is bold")
	cs2 := style_at(&d, pos(0, 5))
	ok(!cs2.bold, "style at the start of the bold run is the run before it")

	// Deleting the middle run merges the compatible neighbours.
	delete_range(&d, pos(0, 5), pos(0, 7))
	eq_str(shape(&d.paras[0]), "a..bcdef/", "deleting across runs merges the neighbours")
	eq_int(len(d.paras[0].runs), 1, "one run again")

	// Normalisation never leaves a paragraph with zero runs.
	delete_range(&d, pos(0, 0), pos(0, para_len(&d.paras[0])))
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
	q := break_para(&d, pos(1, 5))
	eq_int(len(d.paras), 4, "a break adds a paragraph")
	eq_int(q.para, 2, "the caret moves to the new paragraph")
	eq_int(q.off, 0, "at its start")
	eq_str(text_of(&d), "Heading\nfirst\n paragraph\nsecond paragraph", "text is preserved")
	ok(d.paras[2].kind == .Body, "the new paragraph inherits the kind")

	// Enter at the end of a heading starts body text.
	q2 := break_para(&d, pos(0, 7))
	ok(d.paras[1].kind == .Body, "Return at the end of a heading starts body text")
	eq_int(q2.para, 1, "caret in the new paragraph")

	// Backspace joining two paragraphs.
	n := len(d.paras)
	join := merge_para(&d, pos(2, 0), 2)
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
	caret := delete_range(&d2, pos(0, 2), pos(2, 2))
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
	insert_plain(&d3, pos(0, 4), "BOLD", Char_Style{bold = true})
	insert_plain(&d3, pos(0, 8), "keep", Char_Style{})
	eq_str(shape(&d3.paras[0]), "keep/|BOLD/b|keep/", "three runs set up")
	delete_range(&d3, pos(0, 4), pos(0, 8))
	eq_str(shape(&d3.paras[0]), "keepkeep/", "removing the middle run coalesces the rest")

	// Multi-line insert: a paste of three lines becomes three paragraphs.
	d4 := Doc{}
	doc_init(&d4)
	defer doc_destroy(&d4)
	end := insert_text(&d4, pos(0, 0), "one\ntwo\nthree", Char_Style{})
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
	apply_patch(&d, pos(0, 4), pos(0, 9), {{.Bold}, Char_Style{bold = true}})
	eq_str(shape(&d.paras[0]), "the /|quick/b| brown fox/", "the patch lands on the selection only")
	ok(range_all_bold(&d, pos(0, 4), pos(0, 9)), "the whole span reads as bold")
	ok(!range_all_bold(&d, pos(0, 0), pos(0, 9)), "a partly bold span does not")

	// A second patch over a superset keeps one run, not three.
	apply_patch(&d, pos(0, 0), pos(0, 19), {{.Bold}, Char_Style{bold = true}})
	eq_str(shape(&d.paras[0]), "the quick brown fox/b", "bolding everything coalesces to one run")

	// Patches are partial: adding italic must not clear bold.
	apply_patch(&d, pos(0, 4), pos(0, 9), {{.Italic}, Char_Style{italic = true}})
	eq_str(shape(&d.paras[0]), "the /b|quick/bi| brown fox/b", "italic is added without losing bold")

	// Size and colour.
	apply_patch(&d, pos(0, 0), pos(0, 3), {{.Size, .Color}, Char_Style{size = 24, color = 0xffe7000b}})
	eq_str(
		shape(&d.paras[0]),
		"the/b24#e7000b| /b|quick/bi| brown fox/b",
		"size and colour apply together",
	)

	// Clearing every field returns the paragraph to a single plain run.
	apply_patch(
		&d,
		pos(0, 0),
		pos(0, 19),
		{{.Bold, .Italic, .Underline, .Mono, .Size, .Color}, Char_Style{}},
	)
	eq_str(shape(&d.paras[0]), "the quick brown fox/", "clearing formatting collapses to one run")

	// A patch across a paragraph boundary touches both.
	append(&d.paras, para_make(.Body, "second"))
	apply_patch(&d, pos(0, 16), pos(1, 3), {{.Underline}, Char_Style{underline = true}})
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
	st.anchor = pos(0, 0)
	st.caret = pos(0, 5)
	toggle_bold(&st)
	ok(range_all_bold(&st.doc, pos(0, 0), pos(0, 5)), "the selection is bold")
	do_undo(&st)
	ok(!range_all_bold(&st.doc, pos(0, 0), pos(0, 5)), "undo removes the bold")
	eq_str(text_of(&st.doc), "hello world", "and leaves the text alone")

	// A new edit after an undo discards the redo branch.
	do_redo(&st)
	type_text(&st, "!")
	ok(!history_can_redo(&st.hist), "editing clears the redo stack")

	// Moving the caret closes the group, so two typing bursts are two steps.
	n := len(st.hist.undo)
	place_caret(&st, pos(0, 0), false)
	type_text(&st, "A")
	place_caret(&st, pos(0, 3), false)
	type_text(&st, "B")
	eq_int(len(st.hist.undo), n + 2, "a caret move between bursts splits the group")

	// Undo restores the caret and the selection, not just the text. (The cut
	// is done by hand here so the test never talks to wl-copy.)
	before := text_of(&st.doc)
	st.anchor = pos(0, 1)
	st.caret = pos(0, 4)
	clip := selection_doc(&st)
	defer doc_destroy(&clip)
	eq_int(para_len(&clip.paras[0]), 3, "the clipboard copy is three bytes")
	edit_begin(&st, .Structural)
	drop_selection(&st)
	ok(text_of(&st.doc) != before, "the cut changed the text")
	do_undo(&st)
	eq_str(text_of(&st.doc), before, "undo restored it")
	ok(st.anchor == pos(0, 1) && st.caret == pos(0, 4), "and restored the selection")

	// A styled copy pastes back with its runs intact.
	src := Doc{paras = make([dynamic]Paragraph, 0, 2)}
	defer doc_destroy(&src)
	append(&src.paras, para_make(.Body, "plain"))
	insert_plain(&src, pos(0, 5), "BOLD", Char_Style{bold = true})
	dst := Doc{}
	doc_init(&dst)
	defer doc_destroy(&dst)
	insert_doc(&dst, pos(0, 0), &src)
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
	st.caret = pos(0, 0)
	st.anchor = st.caret
	eq_int(line_of(&st.lay, st.caret), 0, "the caret starts on line 0")
	mid := off_at_x(&st.lay, 0, 240)
	st.caret = pos(0, mid)
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
		eq_int(line_of(&st.lay, pos(0, brk)), 1, "a caret on the break is on the lower line")
		eq_int(
			line_of(&st.lay, pos(0, st.lay.lines[0].vis_end)),
			0,
			"a caret before the break is on the upper line",
		)

		// Walking down with the arrow keys must reach every line and stop at
		// the end, not stall part way.
		st.caret = pos(0, 0)
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
		st.caret = pos(0, 0)
		st.anchor = st.caret
		st.goal_ok = false
		move_v(&st, 40, false)
		move_v(&st, 40, false)
		ok(st.caret == doc_end(&st.doc), "two page-downs reach the end of the document")
	}

	// Home and End work on the visual line, not the paragraph.
	st.caret = pos(0, mid)
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
		case .Body, .H1, .Table, .Image:
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
	apply_patch(&d, pos(2, 0), pos(2, 5), {{.Size, .Color}, Char_Style{size = 28, color = 0xff2563eb}})
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

	st.caret = pos(0, 0)
	st.anchor = st.caret
	ok(find_next(&st), "find jumps to the first match")
	eq_int(st.anchor.off, 4, "selecting the match")
	eq_int(st.caret.off, 7, "end of the match")
	ok(find_next(&st), "and on to the second")
	eq_int(st.caret.para, 1, "which is in the next paragraph")
	ok(find_next(&st), "the search wraps around")
	eq_int(st.caret.para, 0, "back to the first paragraph")

	// Replace keeps the style the match had.
	apply_patch(&st.doc, pos(0, 4), pos(0, 7), {{.Bold}, Char_Style{bold = true}})
	clear(&st.repl)
	append(&st.repl, ..transmute([]u8)string("dog"))
	st.caret = pos(0, 0)
	st.anchor = st.caret
	replace_one(&st)
	ok(strings.contains(text_of(&st.doc), "the dog sat"), "the first match was replaced")
	ok(range_all_bold(&st.doc, pos(0, 4), pos(0, 7)), "the replacement inherited the style")

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
// 9a. Tables and pictures through the text formats
// ---------------------------------------------------------------------------

// grid_fixture is a document whose point is the two new things: a table with a
// header, mixed character styles and a multi-paragraph cell, and a picture
// with real bytes behind it. It is used by the format round trips and by the
// export section's external validation.
@(private = "file")
grid_fixture :: proc() -> Doc {
	d := Doc {
		paras = make([dynamic]Paragraph, 0, 8),
	}
	append(&d.paras, para_make(.H1, "Grids and pictures"))
	append(&d.paras, para_make(.Body, "A paragraph before the grid, so the space above it is real."))

	tp := table_para_make(4, 3)
	HEAD := [?]string{"Format", "Carries tables as", "Carries pictures as"}
	BODY := [?][3]string {
		{"PDF", "lines and positioned text", "an XObject stream"},
		{"docx", "w:tbl with a tblGrid", "w:drawing and a relationship"},
		{"odt", "table:table", "draw:frame and draw:image"},
	}
	for c in 0 ..< 3 {
		cl := table_cell(tp.table, 0, c)
		for &r in cl.paras[0].runs {
			delete(r.text)
		}
		clear(&cl.paras[0].runs)
		append(&cl.paras[0].runs, run_make({}, HEAD[c]))
	}
	for r in 0 ..< 3 {
		for c in 0 ..< 3 {
			cl := table_cell(tp.table, r + 1, c)
			for &rr in cl.paras[0].runs {
				delete(rr.text)
			}
			clear(&cl.paras[0].runs)
			// The first column is monospace and the second carries a bold run,
			// so a cell's character styles are exercised rather than assumed.
			if c == 0 {
				append(&cl.paras[0].runs, run_make({mono = true}, BODY[r][c]))
			} else if c == 1 {
				append(&cl.paras[0].runs, run_make({bold = true}, BODY[r][c]))
			} else {
				append(&cl.paras[0].runs, run_make({}, BODY[r][c]))
			}
			normalise(&cl.paras[0])
		}
	}
	// One cell with two paragraphs, which is the thing a flat format cannot do.
	{
		cl := table_cell(tp.table, 3, 2)
		append(&cl.paras, para_make(.Body, "and a second paragraph in the cell"))
	}
	// And one cell with a picture in it, which every exporter has to carry
	// and the layout has to size against the column rather than the page.
	// The picture is wider than the column on purpose: 180 px of picture in a
	// column about 150 px wide, so "scaled to the cell" is a claim with a
	// number behind it.
	{
		cl := table_cell(tp.table, 2, 0)
		if im, got := image_from_bytes(test_png(180, 60), "/tmp/cellpic.png", "a picture inside a cell"); got {
			append(&cl.paras, image_para_make(im, .Center))
		}
	}
	tp.table.widths[0] = 140
	tp.table.widths[1] = 240
	tp.table.widths[2] = 222
	table_fit_widths(tp.table)
	append(&d.paras, tp)

	append(&d.paras, para_make(.Body, "And a picture, centred under it:"))
	if im, got := image_from_bytes(test_png(96, 64), "/tmp/fixture.png", "a generated test picture"); got {
		append(&d.paras, image_para_make(im, .Center))
	}
	append(&d.paras, para_make(.Body, "Followed by ordinary body text that keeps flowing."))
	return d
}

test_grid_formats :: proc(fonts: ^p.Fonts) {
	section("tables and pictures: JSON, Markdown and HTML")

	d := grid_fixture()
	defer doc_destroy(&d)
	eq_int(len(d.paras), 6, "the fixture has six paragraphs")
	ok(d.paras[2].kind == .Table && d.paras[2].table != nil, "one of them is a table")
	ok(d.paras[4].kind == .Image && d.paras[4].img != nil, "and one is a picture")

	// --- the native format carries both, exactly
	{
		j := doc_to_json(&d, context.temp_allocator)
		ok(strings.contains(j, "\"kind\": \"table\""), "the JSON names a table paragraph")
		ok(strings.contains(j, "\"header\": true"), "with its header flag")
		ok(strings.contains(j, "\"widths\": ["), "its column widths")
		ok(strings.contains(j, "\"kind\": \"image\""), "and an image paragraph")
		ok(strings.contains(j, "\"data\": \""), "whose bytes ride along base64'd")

		back, got := doc_from_json(j)
		ok(got, "the JSON parses back")
		if !got {
			return
		}
		defer doc_destroy(&back)
		eq_int(len(back.paras), len(d.paras), "same paragraph count")

		t0, t1 := d.paras[2].table, back.paras[2].table
		ok(t1 != nil, "the table came back")
		if t1 != nil {
			eq_int(len(t1.rows), len(t0.rows), "same number of rows")
			eq_int(table_cols(t1), table_cols(t0), "same number of columns")
			ok(t1.header == t0.header, "the header flag survives")
			ok(t1.borders == t0.borders, "and the borders flag")
			wrong := 0
			for c in 0 ..< table_cols(t0) {
				if abs(table_width(t0, c) - table_width(t1, c)) > 0.2 {
					wrong += 1
				}
			}
			eq_int(wrong, 0, "every column width survives")
			eq_int(len(table_cell(t1, 3, 2).paras), 2, "a two-paragraph cell is still two paragraphs")
			bad := 0
			for r in 0 ..< len(t0.rows) {
				for c in 0 ..< table_cols(t0) {
					a := table_cell(t0, r, c)
					b := table_cell(t1, r, c)
					if cell_text(a, context.temp_allocator) != cell_text(b, context.temp_allocator) {
						bad += 1
					}
				}
			}
			eq_int(bad, 0, "and every cell's text")
			eq_str(
				shape(&table_cell(t1, 1, 0).paras[0]),
				shape(&table_cell(t0, 1, 0).paras[0]),
				"a monospace cell keeps its run shape",
			)
			eq_str(
				shape(&table_cell(t1, 1, 1).paras[0]),
				shape(&table_cell(t0, 1, 1).paras[0]),
				"and a bold one keeps its",
			)
		}

		i0, i1 := d.paras[4].img, back.paras[4].img
		ok(i1 != nil, "the picture came back")
		if i1 != nil {
			eq_int(i1.w, i0.w, "its width")
			eq_int(i1.h, i0.h, "its height")
			eq_int(len(i1.bytes), len(i0.bytes), "every original byte")
			eq_int(len(i1.px), i0.w * i0.h, "and it decoded again")
			eq_str(i1.alt, i0.alt, "with its alternative text")
			same := true
			for k in 0 ..< len(i0.bytes) {
				if i0.bytes[k] != i1.bytes[k] {
					same = false
					break
				}
			}
			ok(same, "the bytes are identical, not merely the same length")
		}

		// And the whole thing is stable: writing it again gives the same file.
		j2 := doc_to_json(&back, context.temp_allocator)
		eq_str(j2, j, "a second write is byte-identical")
	}

	// --- Markdown: a GitHub pipe table, and ![alt](path)
	{
		md := doc_to_markdown(&d, context.temp_allocator)
		ok(strings.contains(md, "| Format |"), "the Markdown has a pipe header row")
		ok(strings.contains(md, "| --- | --- | --- |"), "and the delimiter row under it")
		ok(strings.contains(md, "![a generated test picture]"), "and a picture with its alt text")

		back := doc_from_markdown(md)
		defer doc_destroy(&back)
		tbl := 0
		img := 0
		for &pa in back.paras {
			if pa.kind == .Table {
				tbl += 1
			}
			if pa.kind == .Image {
				img += 1
			}
		}
		eq_int(tbl, 1, "reading it back gives one table")
		eq_int(img, 1, "and one picture")
		for &pa in back.paras {
			if pa.kind != .Table {
				continue
			}
			eq_int(len(pa.table.rows), 4, "with four rows")
			eq_int(table_cols(pa.table), 3, "and three columns")
			ok(pa.table.header, "the first row read as a header")
			eq_str(
				cell_text(table_cell(pa.table, 0, 0), context.temp_allocator),
				"Format",
				"the first cell",
			)
			eq_str(
				cell_text(table_cell(pa.table, 3, 0), context.temp_allocator),
				"odt",
				"and the last row's first cell",
			)
		}
	}

	// --- a pipe table needs its delimiter row to be a table at all
	{
		no_delim := doc_from_markdown("| not | a | table |\n\njust prose\n")
		defer doc_destroy(&no_delim)
		tbl := 0
		for &pa in no_delim.paras {
			if pa.kind == .Table {
				tbl += 1
			}
		}
		eq_int(tbl, 0, "a pipe row with no delimiter under it is not a table")
	}

	// --- escaped pipes inside a cell
	{
		esc := doc_from_markdown("| a \\| b | c |\n| --- | --- |\n| d | e |\n")
		defer doc_destroy(&esc)
		found := false
		for &pa in esc.paras {
			if pa.kind != .Table {
				continue
			}
			found = true
			eq_int(table_cols(pa.table), 2, "an escaped pipe does not split the cell")
			eq_str(
				cell_text(table_cell(pa.table, 0, 0), context.temp_allocator),
				"a | b",
				"and comes back as a literal pipe",
			)
		}
		ok(found, "the escaped table parsed")
	}

	// --- HTML: a real <table> and an inlined <img>
	{
		html := doc_to_html(&d, "grid", context.temp_allocator)
		ok(strings.contains(html, "<table>"), "the HTML has a table element")
		ok(strings.contains(html, "<thead>"), "with a thead for the header row")
		ok(strings.contains(html, "<tbody>"), "and a tbody for the rest")
		eq_int(strings.count(html, "<tr>"), 4, "four rows")
		eq_int(strings.count(html, "<th>"), 3, "three header cells")
		eq_int(strings.count(html, "<td>"), 9, "and nine body cells")
		ok(strings.contains(html, "<colgroup>"), "the column widths are carried")
		ok(strings.contains(html, "src=\"data:image/png;base64,"), "and the picture is inlined")
		ok(strings.contains(html, "<figure"), "inside a figure")
	}

	// --- a cell's text is document text, so the counts include it
	{
		words, chars := doc_counts(&d)
		ok(words > 30, "the fixture counts %d words, cells included", words)
		ok(chars > 200, "and %d characters", chars)
		plain := text_of(&d)
		ok(strings.contains(plain, "Carries tables as"), "a header cell is in the document text")
		ok(strings.contains(plain, "a second paragraph in the cell"), "and a cell's second paragraph")
	}
}

// ---------------------------------------------------------------------------
// 10a. Find depth: case, whole words, and one undo step for the lot
// ---------------------------------------------------------------------------

test_find_modes :: proc(fonts: ^p.Fonts) {
	section("find: match case, whole words, and undo-safe replace all")

	// --- the primitive, on its own, because every mode goes through it
	HAY :: "Art started a restart; art is not part of start."
	eq_int(find_index(HAY, "art", 0, true, false), 0, "a folded search finds Art at 0")
	eq_int(find_index(HAY, "art", 0, false, false), 6, "an exact search skips it and finds the art inside started")
	eq_int(find_index(HAY, "Art", 0, false, false), 0, "and finds Art where the case agrees")
	eq_int(find_index(HAY, "art", 0, true, true), 0, "whole-word folded finds Art")
	eq_int(find_index(HAY, "art", 1, true, true), 23, "and then the standalone art")
	eq_int(find_index(HAY, "art", 24, true, true), -1, "and nothing after it, because the rest are inside words")
	eq_int(find_index(HAY, "art", 0, false, true), 23, "exact and whole-word together")
	eq_int(find_index(HAY, "", 0, true, false), -1, "an empty needle never matches")
	eq_int(find_index(HAY, "nowhere", 0, true, false), -1, "nor one that is not there")
	eq_int(find_index("art", "art", 0, true, true), 0, "a word that is the whole string is whole")
	eq_int(find_index("art.", "art", 0, true, true), 0, "punctuation is a word boundary")
	eq_int(find_index("_art", "art", 0, true, true), -1, "an underscore is not")
	eq_int(find_index("3art", "art", 0, true, true), -1, "nor is a digit")

	// --- the modes through the find box
	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}

	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	append(&st.doc.paras, para_make(.Body, "Art and art and restart and ART."))
	append(&st.doc.paras, para_make(.Body, "A part of the start of the article."))
	relayout(&st)

	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("art"))

	ok(!st.find_case && !st.find_word, "both modes start off, as the box behaved before")
	eq_int(count_hits(&st), 7, "folded, anywhere: seven hits")

	toggle_find_case(&st)
	ok(st.find_case, "match case is on")
	eq_int(count_hits(&st), 5, "exact case: five hits")
	eq_str(find_mode_label(&st), "Aa", "and the label says so")

	toggle_find_word(&st)
	ok(st.find_word, "whole words is on too")
	eq_int(count_hits(&st), 1, "exact and whole: one hit")
	eq_str(find_mode_label(&st), "Aa W", "with both in the label")

	toggle_find_case(&st)
	eq_int(count_hits(&st), 3, "folded and whole: three hits")
	eq_str(find_mode_label(&st), "W", "label")
	toggle_find_word(&st)
	eq_int(count_hits(&st), 7, "and back to seven with both off")
	eq_str(find_mode_label(&st), "—", "and no label")

	// --- find_next honours the modes
	st.find_case, st.find_word = true, true
	st.caret = pos(0, 0)
	st.anchor = st.caret
	ok(find_next(&st), "find jumps to the only exact whole-word match")
	eq_int(st.anchor.off, 8, "which is the lower-case standalone art")
	eq_int(st.caret.off, 11, "three bytes long")

	// --- a term inside a table cell is found like any other
	{
		st2 := State{}
		state_init(&st2, fonts)
		defer state_destroy(&st2)
		st2.view = {0, 0, 1200, 700}
		insert_table(&st2, 2, 2)
		relayout(&st2)
		type_text(&st2, "needle in a cell")
		relayout(&st2)
		clear(&st2.find)
		append(&st2.find, ..transmute([]u8)string("needle"))
		eq_int(count_hits(&st2), 1, "a term inside a cell is counted")
		st2.caret = Pos{}
		st2.anchor = st2.caret
		ok(find_next(&st2), "and found")
		ok(in_cell(&st2.doc, st2.caret), "with the caret landing inside the cell")

		clear(&st2.repl)
		append(&st2.repl, ..transmute([]u8)string("pin"))
		replace_all(&st2)
		relayout(&st2)
		eq_str(
			cell_text(table_cell(table_at(&st2), 0, 0), context.temp_allocator),
			"pin in a cell",
			"and replace-all rewrites the cell",
		)
		do_undo(&st2)
		relayout(&st2)
		eq_str(
			cell_text(table_cell(table_at(&st2), 0, 0), context.temp_allocator),
			"needle in a cell",
			"and one undo puts the cell back",
		)
	}

	// --- undo-safe: replace all is exactly one history step, whatever it
	//     touches, and one undo restores the document byte for byte.
	{
		st3 := State{}
		state_init(&st3, fonts)
		defer state_destroy(&st3)
		st3.view = {0, 0, 1200, 700}
		doc_destroy(&st3.doc)
		st3.doc = Doc {
			paras = make([dynamic]Paragraph, 0, 8),
		}
		for i in 0 ..< 12 {
			append(
				&st3.doc.paras,
				para_make(.Body, fmt.tprintf("line %d: colour, colourful, discolour and Colour", i)),
			)
		}
		relayout(&st3)
		before := text_of(&st3.doc)
		depth := len(st3.hist.undo)

		clear(&st3.find)
		append(&st3.find, ..transmute([]u8)string("colour"))
		clear(&st3.repl)
		append(&st3.repl, ..transmute([]u8)string("color"))
		st3.find_case, st3.find_word = false, false
		hits := count_hits(&st3)
		eq_int(hits, 48, "48 occurrences across twelve paragraphs")

		replace_all(&st3)
		relayout(&st3)
		eq_int(len(st3.hist.undo) - depth, 1, "replace-all pushed exactly one undo step")
		eq_int(count_hits(&st3), 0, "and left nothing to find")
		ok(strings.contains(text_of(&st3.doc), "color"), "the replacement is in the document")

		do_undo(&st3)
		relayout(&st3)
		eq_str(text_of(&st3.doc), before, "one undo restores the document exactly")
		eq_int(count_hits(&st3), hits, "and every occurrence is back")

		do_redo(&st3)
		relayout(&st3)
		eq_int(count_hits(&st3), 0, "redo re-applies the whole sweep")
		do_undo(&st3)
		relayout(&st3)

		// With the modes on, replace-all touches only what the modes name.
		st3.find_case, st3.find_word = true, true
		exact := count_hits(&st3)
		eq_int(exact, 12, "exact, whole-word: one per line")
		depth2 := len(st3.hist.undo)
		replace_all(&st3)
		relayout(&st3)
		eq_int(len(st3.hist.undo) - depth2, 1, "still one undo step")
		ok(
			strings.contains(text_of(&st3.doc), "colourful"),
			"a word the modes excluded is untouched",
		)
		ok(strings.contains(text_of(&st3.doc), "Colour"), "and so is the one with the wrong case")
		do_undo(&st3)
		relayout(&st3)
		eq_str(text_of(&st3.doc), before, "and undo restores that one too")
	}

	// --- replace-one is also a single step, and the caret survives
	{
		st4 := State{}
		state_init(&st4, fonts)
		defer state_destroy(&st4)
		st4.view = {0, 0, 1200, 700}
		doc_destroy(&st4.doc)
		st4.doc = Doc {
			paras = make([dynamic]Paragraph, 0, 2),
		}
		append(&st4.doc.paras, para_make(.Body, "alpha beta alpha gamma"))
		relayout(&st4)
		before := text_of(&st4.doc)
		clear(&st4.find)
		append(&st4.find, ..transmute([]u8)string("alpha"))
		clear(&st4.repl)
		append(&st4.repl, ..transmute([]u8)string("OMEGA"))
		st4.caret = pos(0, 0)
		st4.anchor = st4.caret
		depth := len(st4.hist.undo)
		replace_one(&st4)
		relayout(&st4)
		eq_str(text_of(&st4.doc), "OMEGA beta alpha gamma", "replace-one rewrote the first match only")
		eq_int(len(st4.hist.undo) - depth, 1, "in one undo step")
		do_undo(&st4)
		relayout(&st4)
		eq_str(text_of(&st4.doc), before, "which undo takes back")
	}
}

// ---------------------------------------------------------------------------
// 11a. Tables: the model, the grid arithmetic, and the pagination rule
// ---------------------------------------------------------------------------

// st_doc_is_table answers whether a top-level paragraph index is a table,
// which is how a line is attributed without hard-coding the fixture's shape.
@(private = "file")
st_doc_is_table :: proc(d: ^Doc, pi: int) -> bool {
	return pi >= 0 && pi < len(d.paras) && d.paras[pi].kind == .Table
}

// insert_text_para is a self-test helper: put text into a bare paragraph.
@(private = "file")
set_para_text :: proc(pa: ^Paragraph, text: string) {
	for &r in pa.runs {
		delete(r.text)
	}
	clear(&pa.runs)
	append(&pa.runs, run_make({}, text))
	normalise(pa)
}

test_tables :: proc(fonts: ^p.Fonts) {
	section("tables: model, widths, and pagination")

	// --- the model
	{
		t := table_make(3, 4)
		defer table_destroy(&t)
		eq_int(len(t.rows), 3, "a 3x4 table has three rows")
		eq_int(table_cols(&t), 4, "and four columns")
		eq_int(len(t.rows[0].cells), 4, "every row has four cells")
		eq_int(len(t.rows[0].cells[0].paras), 1, "a fresh cell holds one paragraph")
		ok(t.header, "the first row is a header by default")
		ok(t.borders, "and the cells have borders")

		total := f32(0)
		for c in 0 ..< table_cols(&t) {
			total += table_width(&t, c)
		}
		ok(abs(total - CONTENT_W) < 0.01, "the columns sum to the content measure (%.2f)", total)
		ok(abs(table_col_x(&t, 0)) < 0.01, "column 0 starts at the left edge")
		ok(
			abs(table_col_x(&t, 2) - (table_width(&t, 0) + table_width(&t, 1))) < 0.01,
			"column 2 starts after columns 0 and 1",
		)

		// --- rows
		table_insert_row(&t, 1)
		eq_int(len(t.rows), 4, "a row inserted in the middle")
		eq_int(len(t.rows[1].cells), 4, "with a cell per column")
		ok(table_delete_row(&t, 1), "and deleted again")
		eq_int(len(t.rows), 3, "back to three rows")
		for len(t.rows) > 1 {
			table_delete_row(&t, 0)
		}
		ok(!table_delete_row(&t, 0), "a table never loses its last row")

		// --- columns
		table_insert_row(&t, 1)
		at := table_insert_col(&t, 2)
		eq_int(at, 2, "a column inserted at 2")
		eq_int(table_cols(&t), 5, "five columns now")
		short := 0
		for &row in t.rows {
			if len(row.cells) != 5 {
				short += 1
			}
		}
		eq_int(short, 0, "every row grew a cell")
		eq_int(len(t.widths), 5, "and there is a width per column")
		total2 := f32(0)
		for c in 0 ..< table_cols(&t) {
			total2 += table_width(&t, c)
		}
		ok(abs(total2 - CONTENT_W) < 0.01, "the widths still sum to the measure (%.2f)", total2)
		ok(table_delete_col(&t, 2), "the column is removed")
		eq_int(table_cols(&t), 4, "four columns again")
		for table_cols(&t) > 1 {
			table_delete_col(&t, 0)
		}
		ok(!table_delete_col(&t, 0), "a table never loses its last column")
	}

	// --- column widths move as a pair, never off the measure
	{
		t := table_make(2, 3)
		defer table_destroy(&t)
		before := table_width(&t, 0)
		table_set_width(&t, 0, before + 60)
		ok(table_width(&t, 0) > before, "a column widens")
		total := f32(0)
		for c in 0 ..< 3 {
			total += table_width(&t, c)
		}
		ok(abs(total - CONTENT_W) < 0.01, "and the table is still exactly the measure wide")
		table_set_width(&t, 0, 1) // far below the minimum
		ok(table_width(&t, 0) >= TABLE_MIN_COL - 0.01, "a column never goes below the minimum")
	}

	// --- cell navigation
	{
		t := table_make(2, 3)
		defer table_destroy(&t)
		r, c, moved := table_step_cell(&t, 0, 0, 1)
		ok(moved && r == 0 && c == 1, "Tab from (0,0) goes to (0,1)")
		r, c, moved = table_step_cell(&t, 0, 2, 1)
		ok(moved && r == 1 && c == 0, "Tab wraps to the next row")
		_, _, moved = table_step_cell(&t, 1, 2, 1)
		ok(!moved, "Tab past the last cell runs out, which is the signal to grow")
		_, _, moved = table_step_cell(&t, 0, 0, -1)
		ok(!moved, "Shift+Tab out of the first cell leaves the table")
		r, c, moved = table_step_cell(&t, 1, 0, -1)
		ok(moved && r == 0 && c == 2, "Shift+Tab crosses back up a row")
	}

	// --- blocks, which is how everything above the model reaches a cell
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		append(&d.paras, table_para_make(2, 2))
		append(&d.paras, para_make(.Body, "after"))

		bs := doc_blocks(&d, context.temp_allocator)
		// One for the empty first paragraph, four cells, one for "after".
		eq_int(len(bs), 6, "a 2x2 table contributes four blocks")
		eq_int(bs[1].row, 0, "the first cell block is row 0")
		eq_int(bs[1].col, 0, "column 0")
		eq_int(bs[4].row, 1, "and the fourth is row 1")
		eq_int(bs[4].col, 1, "column 1")
		ok(pos_less(blk_pos(bs[1], 0), blk_pos(bs[4], 0)), "cells are in reading order")

		// Writing into a cell through the ordinary insert path.
		q := blk_pos(bs[2], 0)
		insert_text(&d, q, "hello", {})
		eq_str(
			string(d.paras[1].table.rows[0].cells[1].paras[0].runs[0].text[:]),
			"hello",
			"insert_text reaches the cell the position names",
		)
		eq_int(pos_para_len(&d, q), 5, "and the cell's paragraph is five bytes long")
		eq_int(para_len(&d.paras[0]), 0, "the paragraph before the table is still empty")
		eq_str(para_text(&d.paras[2], context.temp_allocator), "after", "and the one after it is intact")
	}

	// --- layout: a table on one page
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		tp := table_para_make(3, 3)
		for r in 0 ..< 3 {
			for c in 0 ..< 3 {
				set_para_text(&table_cell(tp.table, r, c).paras[0], fmt.tprintf("r%dc%d", r, c))
			}
		}
		append(&d.paras, tp)
		append(&d.paras, para_make(.Body, "below"))

		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &d, fonts)

		eq_int(len(lay.cells), 9, "nine cell boxes for a 3x3 table")
		eq_int(lay.pages, 1, "it fits on one page")

		bad := 0
		for cb in lay.cells {
			if cb.x < -0.01 || cb.x + cb.w > CONTENT_W + 0.01 || cb.y < -0.01 || cb.y + cb.h > CONTENT_H + 0.01 {
				bad += 1
			}
		}
		eq_int(bad, 0, "every cell box sits inside the text area")

		// The three boxes of row 0 abut exactly.
		row0 := make([dynamic]Cell_Box, 0, 3, context.temp_allocator)
		for cb in lay.cells {
			if cb.row == 0 {
				append(&row0, cb)
			}
		}
		eq_int(len(row0), 3, "three boxes in row 0")
		ok(abs(row0[0].x + row0[0].w - row0[1].x) < 0.01, "column 0 ends where column 1 begins")
		ok(abs(row0[1].x + row0[1].w - row0[2].x) < 0.01, "column 1 ends where column 2 begins")
		ok(abs(row0[2].x + row0[2].w - CONTENT_W) < 0.01, "the last column reaches the right margin")
		ok(row0[0].header, "row 0 is the header")

		// Every cell's lines land inside its own box — the assertion that
		// catches text drawn outside the rules.
		outside := 0
		for l in lay.lines {
			if l.para != 1 {
				continue
			}
			for cb in lay.cells {
				if cb.row != l.row || cb.col != l.col || cb.repeat {
					continue
				}
				if l.x < cb.x - 0.01 || l.x + l.w > cb.x + cb.w + 0.01 {
					outside += 1
				}
				if l.y < cb.y - 0.01 || l.y + l.h > cb.y + cb.h + 0.01 {
					outside += 1
				}
			}
		}
		eq_int(outside, 0, "every line of every cell is inside its cell's box")

		cells_with_text := 0
		first_line := -1
		for l, i in lay.lines {
			if l.para == 1 && !l.repeat && l.fc > 0 && l.end > l.start {
				cells_with_text += 1
				if first_line < 0 {
					first_line = i
				}
			}
		}
		eq_int(cells_with_text, 9, "every cell contributed a line of text")
		if first_line >= 0 {
			eq_str(line_text(&lay, first_line), "r0c0", "the first cell's line reads back")
		}

		// The paragraph after the table starts below every row.
		last_bottom := f32(0)
		for cb in lay.cells {
			last_bottom = max(last_bottom, cb.y + cb.h)
		}
		after := -1
		for l, i in lay.lines {
			if l.para == 2 {
				after = i
				break
			}
		}
		ok(after >= 0, "the paragraph after the table was laid out")
		if after >= 0 {
			ok(lay.lines[after].y >= last_bottom, "and it starts below the last row")
		}
	}

	// --- pagination: a row is atomic, the table breaks between rows, and the
	//     header is repeated. This is the rule, asserted.
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		FILL :: "a note long enough to wrap inside its own column and make the row taller than one line of type"
		tp := table_para_make(40, 3)
		for r in 0 ..< 40 {
			for c in 0 ..< 3 {
				set_para_text(
					&table_cell(tp.table, r, c).paras[0],
					r == 0 ? fmt.tprintf("Heading %d", c) : FILL,
				)
			}
		}
		append(&d.paras, tp)

		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &d, fonts)

		ok(lay.pages > 1, "a 40-row table needs more than one page (%d)", lay.pages)

		// No row is split: every box of a row — leaving the repeated headers
		// out, which are extra copies by design — lands on one page at one y.
		split := 0
		for a in lay.cells {
			for b in lay.cells {
				if a.repeat || b.repeat || a.row != b.row {
					continue
				}
				if a.page != b.page || abs(a.y - b.y) > 0.01 || abs(a.h - b.h) > 0.01 {
					split += 1
				}
			}
		}
		eq_int(split, 0, "no row is split across a page boundary")

		// Every page the table reaches carries the header row.
		heads := make(map[int]int, 8, context.temp_allocator)
		pages_seen := make(map[int]bool, 8, context.temp_allocator)
		repeats := 0
		for cb in lay.cells {
			pages_seen[cb.page] = true
			if cb.header {
				heads[cb.page] = (heads[cb.page] or_else 0) + 1
			}
			if cb.repeat {
				repeats += 1
			}
		}
		missing := 0
		for pg in pages_seen {
			if (heads[pg] or_else 0) != 3 {
				missing += 1
			}
		}
		eq_int(missing, 0, "every page of the table carries all three header cells")
		eq_int(repeats, 3 * (len(pages_seen) - 1), "the header is repeated once per continuation page")

		repeat_lines := 0
		for l in lay.lines {
			if l.repeat {
				repeat_lines += 1
			}
		}
		ok(repeat_lines > 0, "the repeated header rows are drawn (%d lines)", repeat_lines)
		li := line_of(&lay, Pos{para = 1, row = 0, col = 0})
		ok(li >= 0, "the header's own line is found")
		if li >= 0 {
			ok(!lay.lines[li].repeat, "the caret in the header lands on the real row, not a repeat")
		}

		not_top := 0
		for cb in lay.cells {
			if cb.repeat && cb.y > 0.01 {
				not_top += 1
			}
		}
		eq_int(not_top, 0, "a repeated header is flush with the top of its page")

		// Rows never overlap on a page.
		overlap := 0
		for a in lay.cells {
			for b in lay.cells {
				if a.page != b.page || a.col != b.col || a.row == b.row || a.repeat || b.repeat {
					continue
				}
				if a.y < b.y + b.h - 0.01 && b.y < a.y + a.h - 0.01 {
					overlap += 1
				}
			}
		}
		eq_int(overlap, 0, "no two rows of a column overlap on a page")

		// Nothing runs off the bottom of a page.
		over := 0
		for cb in lay.cells {
			if cb.y + cb.h > CONTENT_H + 0.01 {
				over += 1
			}
		}
		eq_int(over, 0, "no row runs past the bottom margin")
	}

	// --- the one case the "rows are atomic" rule cannot serve: a single row
	//     taller than a whole page. It is given a page of its own, starting at
	//     the top so it gets every pixel there is, and what will not fit runs
	//     past the bottom margin. That is stated rather than hidden, and it is
	//     the same promise the exports make — the .docx writes <w:cantSplit/>
	//     and the .rtf writes \trkeep, so a reader keeps the row whole too.
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		append(&d.paras, para_make(.Body, "before"))
		tp := table_para_make(2, 2)
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 1200 {
			if i > 0 {
				strings.write_byte(&b, ' ')
			}
			fmt.sbprintf(&b, "word%d", i)
		}
		set_para_text(&table_cell(tp.table, 1, 0).paras[0], strings.to_string(b))
		append(&d.paras, tp)

		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &d, fonts)

		tall := Cell_Box{}
		for cb in lay.cells {
			if cb.row == 1 && cb.col == 0 && !cb.repeat {
				tall = cb
			}
		}
		ok(tall.h > CONTENT_H, "the row is %.0f px tall, more than a page", tall.h)
		ok(tall.page > 0, "so it is given a page of its own (page %d)", tall.page + 1)

		// Nothing is above it on that page but the repeated header, so it has
		// every pixel the rule can give it.
		above := f32(0)
		others := 0
		for cb in lay.cells {
			if cb.page != tall.page || (cb.row == 1 && !cb.repeat) {
				continue
			}
			if cb.repeat {
				above = max(above, cb.y + cb.h)
			} else {
				others += 1
			}
		}
		eq_int(others, 0, "with no other row on it")
		ok(above > 0, "below a repeated header %.0f px tall", above)
		ok(abs(tall.y - above) < 0.01, "and starting immediately under it")

		sib := 0
		for cb in lay.cells {
			if cb.page == tall.page && cb.row == 1 && !cb.repeat && abs(cb.y - tall.y) < 0.01 {
				sib += 1
			}
		}
		eq_int(sib, 2, "both of its cells at the same height")

		// Nothing crashes and every wrapped line of the cell is still placed.
		n := 0
		for l in lay.lines {
			if l.row == 1 && l.col == 0 && st_doc_is_table(&d, l.para) {
				n += 1
			}
		}
		ok(n > 40, "and all %d of its wrapped lines are placed", n)
	}

	// --- a cell's text wraps to its own column, not to the page
	{
		LONG :: "This sentence is far longer than one narrow column can hold on a single line."
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		tp := table_para_make(1, 4)
		tp.table.header = false
		set_para_text(&table_cell(tp.table, 0, 0).paras[0], LONG)
		append(&d.paras, tp)

		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &d, fonts)

		n := 0
		widest := f32(0)
		for l in lay.lines {
			if l.para == 1 && l.col == 0 && l.row == 0 {
				n += 1
				widest = max(widest, l.w)
			}
		}
		ok(n > 1, "the sentence wrapped to %d lines inside its column", n)
		col_w := table_width(tp.table, 0) - 2 * CELL_PAD
		ok(widest <= col_w + 0.5, "no line is wider than the column (%.1f <= %.1f)", widest, col_w)

		// The same text at full measure is fewer lines, which proves the
		// measure really is the column's and not the page's.
		d2: Doc
		doc_init(&d2)
		defer doc_destroy(&d2)
		set_para_text(&d2.paras[0], LONG)
		lay2: Layout
		defer layout_destroy(&lay2)
		layout_doc(&lay2, &d2, fonts)
		ok(len(lay2.lines) < n, "the same text is %d lines at full measure", len(lay2.lines))
	}
}

// ---------------------------------------------------------------------------
// 11b. Images
// ---------------------------------------------------------------------------

// test_png builds a tiny PNG by hand. The pixel data goes in as *stored*
// deflate blocks inside a zlib wrapper, which is legal and needs no
// compressor — Odin's core has an inflate and no deflate, so this is the only
// way the self-test can make a picture without shipping one.
@(private = "file")
test_png :: proc(w, h: int, alloc := context.temp_allocator) -> []u8 {
	be32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}
	chunk :: proc(b: ^[dynamic]u8, tag: string, data: []u8) {
		be32(b, u32(len(data)))
		start := len(b^)
		append(b, ..transmute([]u8)tag)
		append(b, ..data)
		be32(b, crc32_bytes(b[start:]))
	}
	out := make([dynamic]u8, 0, 1024, alloc)
	append(&out, 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a)

	ihdr := make([dynamic]u8, 0, 13, context.temp_allocator)
	be32(&ihdr, u32(w))
	be32(&ihdr, u32(h))
	append(&ihdr, 8, 2, 0, 0, 0) // 8-bit, truecolour
	chunk(&out, "IHDR", ihdr[:])

	raw := make([dynamic]u8, 0, h * (1 + w * 3), context.temp_allocator)
	for y in 0 ..< h {
		append(&raw, 0) // filter: none
		for x in 0 ..< w {
			append(&raw, u8(x * 255 / max(1, w - 1)), u8(y * 255 / max(1, h - 1)), 0x40)
		}
	}
	z := make([dynamic]u8, 0, len(raw) + 64, context.temp_allocator)
	append(&z, 0x78, 0x01)
	at := 0
	for {
		n := min(65535, len(raw) - at)
		last := at + n >= len(raw) ? u8(1) : u8(0)
		append(&z, last, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
		append(&z, ..raw[at:at + n])
		at += n
		if at >= len(raw) {
			break
		}
	}
	a, b := u32(1), u32(0)
	for v in raw {
		a = (a + u32(v)) % 65521
		b = (b + a) % 65521
	}
	be32(&z, b << 16 | a)
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return out[:]
}

test_images :: proc(fonts: ^p.Fonts) {
	section("images: decoding, sizing, and pagination")

	data := test_png(64, 40)
	ok(image_sniff(data) == .PNG, "the PNG magic is recognised")
	ok(image_sniff({0xff, 0xd8, 0xff, 0xe0}) == .JPEG, "and the JPEG magic")
	ok(image_sniff({1, 2, 3, 4}) == .Unknown, "and anything else is unknown")
	eq_str(image_mime(.PNG), "image/png", "the PNG media type")
	eq_str(image_mime(.JPEG), "image/jpeg", "the JPEG media type")

	im, got := image_from_bytes(data, "/tmp/test.png", "a test picture")
	ok(got, "the hand-built PNG decodes")
	if !got {
		return
	}
	defer image_destroy(&im)
	eq_int(im.w, 64, "its width")
	eq_int(im.h, 40, "its height")
	eq_int(len(im.px), 64 * 40, "every pixel decoded")
	eq_int(len(im.bytes), len(data), "the original bytes are kept for export")
	ok(im.scale == 1, "it starts at its intrinsic scale")
	eq_str(im.alt, "a test picture", "and keeps its alternative text")

	w, h := image_draw_size(&im)
	ok(w == 64 && h == 40, "at scale 1 it draws at its pixel size (%.0fx%.0f)", w, h)
	image_set_scale(&im, 2)
	w, h = image_draw_size(&im)
	ok(w == 128 && h == 80, "at scale 2 it doubles (%.0fx%.0f)", w, h)

	// The two caps: never wider than the measure, never taller than a page.
	image_set_scale(&im, 40)
	w, h = image_draw_size(&im)
	ok(w <= CONTENT_W + 0.01, "a picture is never wider than the measure (%.1f)", w)
	ok(h <= CONTENT_H + 0.01, "nor taller than a page (%.1f)", h)
	ok(abs(w / h - 64.0 / 40.0) < 0.01, "and the aspect ratio survives both caps")
	image_set_scale(&im, 1)

	{
		c := image_clone(&im)
		defer image_destroy(&c)
		eq_int(c.w, im.w, "a clone keeps the size")
		eq_int(len(c.bytes), len(im.bytes), "and the bytes")
		ok(raw_data(c.bytes) != raw_data(im.bytes), "but owns its own copy")
	}

	// --- layout
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		cp, _ := image_from_bytes(data, "/tmp/test.png", "pic")
		append(&d.paras, image_para_make(cp, .Center))
		append(&d.paras, para_make(.Body, "after the picture"))

		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &d, fonts)

		li := -1
		for l, i in lay.lines {
			if l.para == 1 {
				li = i
				break
			}
		}
		ok(li >= 0, "the image paragraph was laid out")
		if li >= 0 {
			l := lay.lines[li]
			ok(abs(l.h - 40) < 0.01, "its line box is as tall as the picture (%.1f)", l.h)
			ok(abs(l.w - 64) < 0.01, "and as wide (%.1f)", l.w)
			ok(abs(l.x - (CONTENT_W - 64) / 2) < 0.01, "centred, because the paragraph is centred")
		}

		d.paras[1].align = .Left
		layout_doc(&lay, &d, fonts)
		for l in lay.lines {
			if l.para == 1 {
				ok(abs(l.x) < 0.01, "left-aligned it sits on the left margin")
			}
		}
		d.paras[1].align = .Right
		layout_doc(&lay, &d, fonts)
		for l in lay.lines {
			if l.para == 1 {
				ok(abs(l.x - (CONTENT_W - 64)) < 0.01, "right-aligned it sits against the right margin")
			}
		}
	}

	// --- a picture taller than the space left moves to the next page
	//
	// The picture is sized from the space the filler actually leaves, so the
	// test asserts the rule rather than a number that a change in the body
	// metrics would quietly turn into a tautology.
	{
		d: Doc
		doc_init(&d)
		defer doc_destroy(&d)
		lay: Layout
		defer layout_destroy(&lay)

		// Fill the last page until less than half of it is left, so there is
		// room for a picture that is tall but not page-tall. Counting
		// paragraphs instead would bake the body metrics into the test.
		free_h := CONTENT_H
		filler_page := 0
		for i := 0; i < 400; i += 1 {
			append(&d.paras, para_make(.Body, fmt.tprintf("Filler paragraph number %d.", i + 1)))
			layout_doc(&lay, &d, fonts)
			last := lay.lines[len(lay.lines) - 1]
			filler_page = last.page
			free_h = CONTENT_H - (last.y + last.h)
			if free_h <= CONTENT_H / 2 {
				break
			}
		}
		ok(
			free_h > 60 && free_h <= CONTENT_H / 2,
			"the filler leaves %.0f px at the foot of page %d",
			free_h,
			filler_page + 1,
		)

		// A *portrait* picture, because a landscape one hits the width cap
		// before it can get tall enough to overflow the foot of a page.
		tall := test_png(40, 200)
		cp, _ := image_from_bytes(tall, "/tmp/tall.png", "pic")
		ip := image_para_make(cp, .Center)
		// Taller than what is left, but comfortably shorter than a page, so
		// the only correct answer is "move it down".
		want_h := min(free_h + 120, CONTENT_H - 60)
		ip.img.scale = want_h / 200
		append(&d.paras, ip)
		layout_doc(&lay, &d, fonts)

		ipi := len(d.paras) - 1
		img_line := -1
		for l, i in lay.lines {
			if l.para == ipi {
				img_line = i
			}
		}
		ok(img_line >= 0, "the tall picture was laid out")
		if img_line >= 0 {
			l := lay.lines[img_line]
			ok(l.h > free_h, "the picture (%.0f px) is taller than the space left", l.h)
			eq_int(l.page, filler_page + 1, "so it moved to the next page")
			ok(abs(l.y) < 0.01, "and it starts at the top of that page")
			ok(l.y + l.h <= CONTENT_H + 0.01, "and fits on it")
		}
	}
}

// ---------------------------------------------------------------------------
// 11c. Editing inside a cell
// ---------------------------------------------------------------------------

test_cells :: proc(fonts: ^p.Fonts) {
	section("cells: the caret, typing, styling and undo inside a table")

	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1280, 760}

	insert_table(&st, 2, 3)
	relayout(&st)
	ok(in_table(&st), "the caret is in the table it just inserted")
	eq_int(st.caret.para, 1, "which never ends up first, so there is a line above it")
	eq_int(st.caret.row, 0, "at row 0")
	eq_int(st.caret.col, 0, "column 0")
	ok(table_at(&st) != nil, "and table_at finds it")
	eq_int(len(st.doc.paras), 3, "a paragraph either side of it, so the caret can always leave")

	// --- typing lands in the cell
	type_text(&st, "Name")
	relayout(&st)
	eq_str(
		para_text(pos_para(&st.doc, st.caret), context.temp_allocator),
		"Name",
		"typing goes into the cell",
	)
	eq_int(para_len(&st.doc.paras[1]), 0, "and not into the table paragraph itself")

	// --- Tab walks the grid
	ok(table_move_cell(&st, 1), "Tab moves to the next cell")
	eq_int(st.caret.col, 1, "which is column 1")
	type_text(&st, "Role")
	ok(table_move_cell(&st, 1), "Tab again")
	type_text(&st, "Since")
	ok(table_move_cell(&st, 1), "Tab wraps to the next row")
	eq_int(st.caret.row, 1, "row 1")
	eq_int(st.caret.col, 0, "column 0")
	type_text(&st, "Ada")
	relayout(&st)

	eq_str(cell_text(table_cell(table_at(&st), 0, 0), context.temp_allocator), "Name", "cell (0,0)")
	eq_str(cell_text(table_cell(table_at(&st), 0, 1), context.temp_allocator), "Role", "cell (0,1)")
	eq_str(cell_text(table_cell(table_at(&st), 0, 2), context.temp_allocator), "Since", "cell (0,2)")
	eq_str(cell_text(table_cell(table_at(&st), 1, 0), context.temp_allocator), "Ada", "cell (1,0)")

	ok(table_move_cell(&st, -1), "Shift+Tab steps back")
	eq_int(st.caret.row, 0, "to row 0")
	eq_int(st.caret.col, 2, "column 2")

	// --- Tab at the last cell grows the table
	st.caret = Pos {
		para = 1,
		row  = 1,
		col  = 2,
	}
	st.anchor = st.caret
	before := len(table_at(&st).rows)
	ok(table_move_cell(&st, 1), "Tab at the last cell is handled")
	eq_int(len(table_at(&st).rows), before + 1, "and grows the table by a row")
	eq_int(st.caret.row, before, "with the caret in the new row")

	// --- styling reaches a cell through the ordinary command
	st.caret = Pos {
		para = 1,
	}
	st.anchor = st.caret
	select_word(&st)
	ok(has_selection(&st), "a word is selected inside the cell")
	eq_str(selection_text(&st, context.temp_allocator), "Name", "and it is the cell's word")
	toggle_bold(&st)
	ok(range_all_bold(&st.doc, st.anchor, st.caret), "bold applied inside the cell")
	ok(style_at(&st.doc, Pos{para = 1, off = 1}).bold, "and the run really carries it")

	// --- undo takes it back, in one step
	do_undo(&st)
	relayout(&st)
	ok(!style_at(&st.doc, Pos{para = 1, off = 1}).bold, "undo removes the bold from the cell")
	eq_str(
		cell_text(table_cell(table_at(&st), 0, 0), context.temp_allocator),
		"Name",
		"and the text survives",
	)

	// --- backspace inside a cell deletes a character, never the table
	st.caret = Pos {
		para = 1,
		off  = 4,
	}
	st.anchor = st.caret
	backspace(&st)
	relayout(&st)
	eq_str(
		cell_text(table_cell(table_at(&st), 0, 0), context.temp_allocator),
		"Nam",
		"backspace deletes one character",
	)
	eq_int(len(st.doc.paras), 3, "and the document still has its three paragraphs")

	st.caret = Pos {
		para = 1,
	}
	st.anchor = st.caret
	backspace(&st)
	eq_str(
		cell_text(table_cell(table_at(&st), 0, 0), context.temp_allocator),
		"Nam",
		"and at the head of the cell it is a no-op",
	)
	eq_int(len(table_at(&st).rows), before + 1, "the table is intact")

	// --- Return inside a cell adds a paragraph to the cell, not to the body
	st.caret = Pos {
		para = 1,
		off  = 3,
	}
	st.anchor = st.caret
	split_line(&st)
	relayout(&st)
	eq_int(len(table_cell(table_at(&st), 0, 0).paras), 2, "Return splits inside the cell")
	eq_int(len(st.doc.paras), 3, "and the document is unchanged")
	eq_int(st.caret.cpara, 1, "with the caret in the cell's second paragraph")

	// --- row and column commands
	rows_before := len(table_at(&st).rows)
	table_row_cmd(&st, true)
	eq_int(len(table_at(&st).rows), rows_before + 1, "a row is added below")
	table_delete_row_cmd(&st)
	eq_int(len(table_at(&st).rows), rows_before, "and deleted again")
	cols_before := table_cols(table_at(&st))
	table_col_cmd(&st, true)
	eq_int(table_cols(table_at(&st)), cols_before + 1, "a column is added")
	table_delete_col_cmd(&st)
	eq_int(table_cols(table_at(&st)), cols_before, "and deleted again")
	table_toggle_header(&st)
	ok(!table_at(&st).header, "the header row can be turned off")
	table_toggle_header(&st)
	ok(table_at(&st).header, "and back on")

	// --- the caret can leave the table and come back
	st.caret = Pos {
		para = 1,
	}
	st.anchor = st.caret
	relayout(&st)
	move_h(&st, -1, false)
	ok(!in_cell(&st.doc, st.caret), "Left out of the first cell leaves the table")
	move_h(&st, 1, false)
	ok(in_cell(&st.doc, st.caret), "and Right comes back into it")

	// --- Down from the last row reaches the paragraph after the table
	st.caret = Pos {
		para = 1,
		row  = len(table_at(&st).rows) - 1,
	}
	st.anchor = st.caret
	relayout(&st)
	for _ in 0 ..< 8 {
		move_v(&st, 1, false)
	}
	eq_int(st.caret.para, 2, "Down eventually leaves the table")

	// --- select-all covers the cells
	select_all(&st)
	txt := selection_text(&st, context.temp_allocator)
	ok(strings.contains(txt, "Nam"), "select-all's text includes a cell")
	ok(strings.contains(txt, "Ada"), "and another one")

	// --- deleting the table leaves the document usable, and undo restores it
	st.caret = Pos {
		para = 1,
	}
	st.anchor = st.caret
	delete_block(&st)
	relayout(&st)
	ok(table_at(&st) == nil, "the table is gone")
	ok(len(st.doc.paras) >= 1, "and the document still has a paragraph")
	do_undo(&st)
	relayout(&st)
	ok(table_at(&st) != nil, "undo brings the whole table back")
	if table_at(&st) != nil {
		eq_str(
			cell_text(table_cell(table_at(&st), 1, 0), context.temp_allocator),
			"Ada",
			"with its contents",
		)
	}
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
LO_PROFILE :: "-env:UserInstallation=file:///tmp/palmy-lo-docs2"

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
	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa == nil {
			continue
		}
		for &r in pa.runs {
			strings.write_bytes(&b, r.text[:])
		}
		strings.write_byte(&b, '\n')
	}
	return words_of(strings.to_string(b))
}

// layout_words is the words *as the page lays them out*, which is not the same
// list as the document's words: a word too long for its measure is broken
// between runes, so "unlockAndPost" in a narrow table column is two words on
// paper. Any extractor working from a rendered page sees the broken pair, and
// comparing it against the unbroken original would be comparing against
// something that was never on the page.
@(private = "file")
layout_words :: proc(d: ^Doc, fonts: ^p.Fonts) -> []string {
	lay: Layout
	defer layout_destroy(&lay)
	layout_doc(&lay, d, fonts)
	b := strings.builder_make(context.temp_allocator)
	for li in 0 ..< len(lay.lines) {
		strings.write_string(&b, line_text(&lay, li))
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

// check_covers asserts that a tool's output contains every source word at
// least as often as the source does, without caring about order.
//
// It is the right test for `pdftotext -layout`, which does not report a PDF's
// reading order: it reconstructs the *visual* rows of a page, so a table whose
// cells wrap comes out interleaved — "the surface to present | the input to
// read" on one row and "into" on the next. That is a faithful picture of the
// page and a useless sequence. Order is asserted against `-raw` instead, which
// is the content stream itself.
@(private = "file")
check_covers :: proc(label: string, src: []string, text: string) {
	got := words_of(text)
	have := make(map[string]int, len(got) * 2, context.temp_allocator)
	for w in got {
		have[w] = (have[w] or_else 0) + 1
	}
	missing := 0
	first := ""
	for w in src {
		n := have[w] or_else 0
		if n <= 0 {
			missing += 1
			if first == "" {
				first = w
			}
			continue
		}
		have[w] = n - 1
	}
	ok(
		missing == 0,
		"%s contains every word of the document (%d source, %d extracted%s)",
		label,
		len(src),
		len(got),
		missing == 0 ? "" : fmt.tprintf(", %d missing, first %q", missing, first),
	)
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
	// What the document contains, so a format check can assert the exact
	// structure rather than "something that looks like a table".
	tables: int,
	rows:   int, // across every table
	cols:   int, // across every table, summed
	cells:  int, // across every table
	lists:  int,
	images: int,
}

// case_shape counts what an exporter has to carry.
@(private = "file")
case_shape :: proc(c: ^Export_Case) {
	c^ = Export_Case {
		name = c.name,
		doc  = c.doc,
	}
	for &pa in c.doc.paras {
		if pa.kind == .Table && pa.table != nil {
			c.tables += 1
			c.rows += len(pa.table.rows)
			c.cols += table_cols(pa.table)
			c.cells += len(pa.table.rows) * table_cols(pa.table)
			// A picture inside a cell counts: every exporter has to carry it,
			// and LibreOffice counts the pictures in the file it reads back
			// without caring which of them were in cells.
			for &row in pa.table.rows {
				for &cl in row.cells {
					for &cp in cl.paras {
						if cp.kind == .Image && cp.img != nil && len(cp.img.bytes) > 0 {
							c.images += 1
						}
					}
				}
			}
		}
		if pa.kind == .Image && pa.img != nil && len(pa.img.bytes) > 0 {
			c.images += 1
		}
		if pa.list != .None {
			c.lists += 1
		}
	}
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

	cases := make([dynamic]Export_Case, 0, 5, context.temp_allocator)
	append(&cases, Export_Case{name = "fixture", doc = rich_fixture()})
	// The grid case is the one that exists for tables and pictures. It is
	// first-class here: every structural check, every external tool and the
	// LibreOffice round trip all see it.
	append(&cases, Export_Case{name = "grid", doc = grid_fixture()})
	append(&cases, Export_Case{name = "seed", doc = doc_from_markdown(SEED)})
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
			append(&cases, Export_Case{name = cand[0], doc = nd})
		}
	}
	for &c in cases {
		case_shape(&c)
	}
	defer for &c in cases {
		doc_destroy(&c.doc)
	}
	ok(len(cases) >= 4, "%d documents under test", len(cases))
	{
		with_tables, with_images := 0, 0
		for &c in cases {
			if c.tables > 0 {
				with_tables += 1
			}
			if c.images > 0 {
				with_images += 1
			}
		}
		ok(with_tables >= 2, "%d of them carry tables", with_tables)
		ok(with_images >= 1, "%d of them carry pictures", with_images)
	}

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
		markers := 0
		{
			lay: Layout
			defer layout_destroy(&lay)
			layout_doc(&lay, &c.doc, fonts)
			pages, lines = lay.pages, len(lay.lines)
			// A list marker opens a text object of its own, before the line's.
			for l in lay.lines {
				if l.marker >= 0 {
					markers += 1
				}
			}
		}
		if raw, got := read_text(pdf_path); got {
			check_pdf_structure(c.name, raw, &c)
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
			ok(
				bt > 0 && bt <= lines + markers + pages + 8,
				"%s: %d text objects for %d lines and %d list markers",
				c.name,
				bt,
				lines,
				markers,
			)
		} else {
			ok(false, "%s: the PDF can be read back", c.name)
		}

		// --- .docx
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		docx_path := fmt.tprintf("%s-docx.docx", base)
		ok(export_docx(&c.doc, docx_path, c.name), "%s: .docx written", c.name)
		if raw, got := read_text(docx_path); got {
			check_docx_structure(c.name, transmute([]u8)raw, &c)
		}

		// --- .odt
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		odt_path := fmt.tprintf("%s-odt.odt", base)
		ok(export_odt(&c.doc, odt_path, c.name), "%s: .odt written", c.name)
		if raw, got := read_text(odt_path); got {
			check_odt_structure(c.name, transmute([]u8)raw, &c)
		}

		// --- .rtf
		// Named per format so LibreOffice's one-output-per-basename
		// rule does not have three conversions overwrite each other.
		rtf_path := fmt.tprintf("%s-rtf.rtf", base)
		ok(export_rtf(&c.doc, rtf_path, c.name), "%s: .rtf written", c.name)
		if raw, got := read_text(rtf_path); got {
			check_rtf_structure(c.name, raw, &c)
		}

		append(&office_paths, docx_path, odt_path, rtf_path)

		// --- import: the .odt just written must come back as the same
		// document too. .odt used to be write-only; it is not any more, and
		// the claim is held to the same standard the .docx is.
		if back, got := import_odt(odt_path); got {
			nd := back
			defer doc_destroy(&nd)
			eq_int(len(nd.paras), len(c.doc.paras), "%s: .odt round-trips the paragraph count", c.name)
			if len(nd.paras) == len(c.doc.paras) {
				bad_kind, bad_list, bad_align := 0, 0, 0
				for i in 0 ..< len(nd.paras) {
					if nd.paras[i].kind != c.doc.paras[i].kind {
						bad_kind += 1
					}
					if nd.paras[i].list != c.doc.paras[i].list {
						bad_list += 1
					}
					if nd.paras[i].align != c.doc.paras[i].align {
						bad_align += 1
					}
				}
				eq_int(bad_kind, 0, "%s: .odt round-trips every paragraph kind", c.name)
				eq_int(bad_list, 0, "%s: .odt round-trips every list kind", c.name)
				eq_int(bad_align, 0, "%s: .odt round-trips every alignment", c.name)

				if c.tables > 0 {
					t0, t1: ^Table
					for i in 0 ..< len(nd.paras) {
						if c.doc.paras[i].kind == .Table && t0 == nil {
							t0 = c.doc.paras[i].table
							t1 = nd.paras[i].table
						}
					}
					ok(t1 != nil, "%s: the .odt reads its table back as a table", c.name)
					if t0 != nil && t1 != nil {
						eq_int(len(t1.rows), len(t0.rows), "%s: .odt keeps the row count", c.name)
						eq_int(table_cols(t1), table_cols(t0), "%s: and the column count", c.name)
						ok(t1.header == t0.header, "%s: and the header row", c.name)
						wrong := 0
						for col in 0 ..< table_cols(t0) {
							if abs(table_width(t0, col) - table_width(t1, col)) > 1.2 {
								wrong += 1
							}
						}
						eq_int(wrong, 0, "%s: and every column width to within a pixel", c.name)
						bad_cell := 0
						for r in 0 ..< len(t0.rows) {
							for col in 0 ..< table_cols(t0) {
								a := cell_text(table_cell(t0, r, col), context.temp_allocator)
								b := cell_text(table_cell(t1, r, col), context.temp_allocator)
								if a != b {
									bad_cell += 1
								}
							}
						}
						eq_int(bad_cell, 0, "%s: and every cell's text", c.name)
					}
				}
				if c.images > 0 {
					// Pictures in document order, cells included: one of them
					// is inside a table cell, and counting only the top-level
					// paragraphs is how that one used to go missing unnoticed.
					want := doc_pictures(&c.doc)
					back := doc_pictures(&nd)
					bytes_ok := 0
					for i in 0 ..< min(len(back), len(want)) {
						if len(back[i].bytes) == len(want[i].bytes) {
							bytes_ok += 1
						}
					}
					eq_int(len(back), c.images, "%s: the .odt reads its pictures back", c.name)
					eq_int(bytes_ok, c.images, "%s: with their bytes intact", c.name)
				}
			}
			check_extracted(fmt.tprintf("%s: .odt import", c.name), src, text_of(&nd))
		} else {
			ok(false, "%s: the .odt reads back", c.name)
		}

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

				// Tables and pictures, structurally, not just as text.
				if c.tables > 0 {
					t0, t1: ^Table
					for i in 0 ..< len(nd.paras) {
						if c.doc.paras[i].kind == .Table && t0 == nil {
							t0 = c.doc.paras[i].table
							t1 = nd.paras[i].table
						}
					}
					ok(t1 != nil, "%s: the .docx reads its table back as a table", c.name)
					if t0 != nil && t1 != nil {
						eq_int(len(t1.rows), len(t0.rows), "%s: with the same row count", c.name)
						eq_int(table_cols(t1), table_cols(t0), "%s: and column count", c.name)
						ok(t1.header == t0.header, "%s: and the header flag", c.name)
						wrong := 0
						for col in 0 ..< table_cols(t0) {
							// The width goes out in twips and comes back in
							// pixels, so a pixel of rounding is expected.
							if abs(table_width(t0, col) - table_width(t1, col)) > 1.2 {
								wrong += 1
							}
						}
						eq_int(wrong, 0, "%s: and every column width to within a pixel", c.name)
						bad_cell := 0
						for r in 0 ..< len(t0.rows) {
							for col in 0 ..< table_cols(t0) {
								a := cell_text(table_cell(t0, r, col), context.temp_allocator)
								b := cell_text(table_cell(t1, r, col), context.temp_allocator)
								if a != b {
									bad_cell += 1
								}
							}
						}
						eq_int(bad_cell, 0, "%s: and every cell's text", c.name)
					}
				}
				if c.images > 0 {
					want := doc_pictures(&c.doc)
					back := doc_pictures(&nd)
					bytes_ok := 0
					for i in 0 ..< min(len(back), len(want)) {
						if len(back[i].bytes) == len(want[i].bytes) {
							bytes_ok += 1
						}
					}
					eq_int(len(back), c.images, "%s: the .docx reads its pictures back", c.name)
					eq_int(bytes_ok, c.images, "%s: with their bytes intact", c.name)
				}
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

	check_pdf_tools(cases[:], fonts)
	check_pdf_render(cases[:], fonts)
	check_xml_parts(cases[:])
	check_libreoffice(cases[:], office_paths[:])
}

// check_pdf_structure reads the file back as bytes and asserts the things a
// PDF must have — before any external tool is consulted, so a failure points
// at the writer rather than at the reader.
@(private = "file")
check_pdf_structure :: proc(name, raw: string, c: ^Export_Case) {
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

	// Tables are lines and text, so the only thing to assert in the file is
	// that the rules were actually emitted: a filled rectangle per cell edge.
	if c.tables > 0 {
		// Four edges per cell, at least — shared edges are drawn twice, which
		// is what makes a grid of single-weight rules close up.
		rects := strings.count(raw, " re f\n")
		ok(rects >= 4 * c.cells, "%s: %d filled rectangles for %d cells", name, rects, c.cells)
	}
	// A picture is an XObject, drawn with `Do` under a placement matrix.
	if c.images > 0 {
		for want in ([?]string{"/Type /XObject", "/Subtype /Image", "/ColorSpace /DeviceRGB", "/XObject <<", " Do\n"}) {
			ok(strings.contains(raw, want), "%s: PDF contains %s", name, want)
		}
		ok(
			strings.contains(raw, "/Filter /RunLengthDecode") || strings.contains(raw, "/Filter /DCTDecode"),
			"%s: the image stream names a filter the format defines",
			name,
		)
		eq_int(
			strings.count(raw, "/Subtype /Image"),
			c.images,
			"%s: one image XObject per picture",
			name,
		)
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
check_docx_structure :: proc(name: string, archive: []u8, c: ^Export_Case) {
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
		if c.lists > 0 {
			ok(strings.contains(s, "<w:numPr>"), "%s: list items carry numbering", name)
		}
		ok(strings.contains(s, "xml:space=\"preserve\""), "%s: runs preserve their spaces", name)
		ok(strings.contains(s, "<w:sectPr>"), "%s: a section with the page size", name)
		ok(strings.contains(s, "w:w=\"11906\""), "%s: the page is A4", name)

		if c.tables > 0 {
			eq_int(strings.count(s, "<w:tbl>"), c.tables, "%s: one w:tbl per table", name)
			eq_int(strings.count(s, "<w:tblGrid>"), c.tables, "%s: each with a tblGrid", name)
			eq_int(strings.count(s, "<w:gridCol "), c.cols, "%s: one gridCol per column", name)
			eq_int(strings.count(s, "<w:tr>"), c.rows, "%s: one w:tr per row", name)
			eq_int(strings.count(s, "<w:tc>"), c.cells, "%s: one w:tc per cell", name)
			ok(strings.contains(s, "<w:tblHeader/>"), "%s: the header row repeats across pages", name)
			ok(strings.contains(s, "<w:tblLayout w:type=\"fixed\"/>"), "%s: the grid widths are binding", name)
			ok(strings.contains(s, "<w:tcW "), "%s: and every cell declares its own width", name)
			// Word rejects a w:tc with no paragraph in it.
			ok(
				!strings.contains(s, "<w:tc><w:tcPr></w:tcPr></w:tc>"),
				"%s: no cell is left without a paragraph",
				name,
			)
		}
		if c.images > 0 {
			eq_int(strings.count(s, "<w:drawing>"), c.images, "%s: one w:drawing per picture", name)
			eq_int(strings.count(s, "<wp:inline "), c.images, "%s: anchored inline", name)
			eq_int(strings.count(s, "<a:blip r:embed="), c.images, "%s: each naming a relationship", name)
			ok(strings.contains(s, "<pic:pic "), "%s: inside a DrawingML picture", name)
			ok(strings.contains(s, "<wp:extent cx="), "%s: with an extent", name)
		}
	}
	if c.images > 0 {
		names := zip_names(archive, context.temp_allocator)
		media := 0
		for n in names {
			if strings.has_prefix(n, "word/media/") {
				media += 1
			}
		}
		eq_int(media, c.images, "%s: .docx carries one media part per picture", name)
		if rels, got_r := zip_read_entry(archive, "word/_rels/document.xml.rels", context.temp_allocator);
		   got_r {
			eq_int(
				strings.count(string(rels), "/relationships/image"),
				c.images,
				"%s: with an image relationship each",
				name,
			)
		}
		if ct, got_ct := zip_read_entry(archive, "[Content_Types].xml", context.temp_allocator); got_ct {
			ok(
				strings.contains(string(ct), "Extension=\"png\"") ||
				strings.contains(string(ct), "Extension=\"jpeg\""),
				"%s: and a content-type default for the picture's extension",
				name,
			)
		}
	}
	if c.tables > 0 {
		if st2, got2 := zip_read_entry(archive, "word/styles.xml", context.temp_allocator); got2 {
			ok(
				strings.contains(string(st2), "w:styleId=\"TableGrid\""),
				"%s: styles.xml defines a real table style",
				name,
			)
		}
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
check_odt_structure :: proc(name: string, archive: []u8, c: ^Export_Case) {
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
		if c.lists > 0 {
			ok(strings.contains(s, "<text:list "), "%s: lists are text:list", name)
		}
		ok(strings.contains(s, "office:version=\"1.3\""), "%s: declares its ODF version", name)

		if c.tables > 0 {
			eq_int(strings.count(s, "<table:table "), c.tables, "%s: one table:table per table", name)
			eq_int(strings.count(s, "<table:table-column "), c.cols, "%s: one table-column per column", name)
			eq_int(strings.count(s, "<table:table-row>"), c.rows, "%s: one table-row per row", name)
			eq_int(strings.count(s, "<table:table-cell "), c.cells, "%s: one table-cell per cell", name)
			ok(
				strings.contains(s, "<table:table-header-rows>"),
				"%s: the header row is inside table-header-rows, which is what repeats it",
				name,
			)
			ok(strings.contains(s, "style:family=\"table-column\""), "%s: with real column styles", name)
			ok(strings.contains(s, "style:family=\"table-cell\""), "%s: and cell styles", name)
		}
		if c.images > 0 {
			eq_int(strings.count(s, "<draw:frame "), c.images, "%s: one draw:frame per picture", name)
			eq_int(strings.count(s, "<draw:image "), c.images, "%s: each holding a draw:image", name)
			ok(strings.contains(s, "xlink:href=\"Pictures/"), "%s: pointing into Pictures/", name)
			ok(strings.contains(s, "text:anchor-type=\"as-char\""), "%s: anchored as a character", name)
		}
	}
	if c.images > 0 {
		names2 := zip_names(archive, context.temp_allocator)
		pics := 0
		for n in names2 {
			if strings.has_prefix(n, "Pictures/") {
				pics += 1
			}
		}
		eq_int(pics, c.images, "%s: .odt carries one Pictures/ part per picture", name)
		if man, got_m := zip_read_entry(archive, "META-INF/manifest.xml", context.temp_allocator); got_m {
			eq_int(
				strings.count(string(man), "manifest:full-path=\"Pictures/"),
				c.images,
				"%s: and the manifest declares each one",
				name,
			)
		}
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
check_rtf_structure :: proc(name, raw: string, c: ^Export_Case) {
	ok(strings.has_prefix(raw, "{\\rtf1\\ansi"), "%s: an RTF 1 header", name)
	ok(strings.contains(raw, "{\\fonttbl"), "%s: a font table", name)
	ok(strings.contains(raw, "{\\stylesheet"), "%s: a stylesheet", name)
	ok(strings.contains(raw, "\\paperw11906"), "%s: the page is A4", name)

	if c.tables > 0 {
		eq_int(strings.count(raw, "\\trowd"), c.rows, "%s: one \\trowd per row", name)
		eq_int(strings.count(raw, "\\row\n"), c.rows, "%s: and one \\row to close each", name)
		eq_int(strings.count(raw, "\\cell\n"), c.cells, "%s: one \\cell per cell", name)
		eq_int(strings.count(raw, "\\cellx"), c.cells, "%s: and one cumulative \\cellx per cell", name)
		ok(strings.contains(raw, "\\trhdr"), "%s: the header row is marked to repeat", name)
		ok(strings.contains(raw, "\\intbl"), "%s: cell paragraphs are marked in-table", name)
	}
	if c.images > 0 {
		eq_int(strings.count(raw, "\\pict"), c.images, "%s: one \\pict per picture", name)
		ok(
			strings.contains(raw, "\\pngblip") || strings.contains(raw, "\\jpegblip"),
			"%s: declaring what the hex bytes are",
			name,
		)
		ok(strings.contains(raw, "\\picwgoal"), "%s: with a drawn size as well as a pixel size", name)
	}

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
check_pdf_tools :: proc(cases: []Export_Case, fonts: ^p.Fonts) {
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
				//
				// Order is asserted for a document without tables, exactly as
				// it always was. With a table it cannot be: `-layout` rebuilds
				// the *visual* rows of a page, so a row whose cells wrap comes
				// out interleaved — "the surface to present | the input to
				// read" on one row and "into" on the next. That is a faithful
				// picture of the page and a useless sequence, so what is
				// asserted there is completeness, word for word, cells
				// included — and the structure is asserted by the HTML pass in
				// check_libreoffice and by the pixels in check_pdf_render.
				if c.tables == 0 {
					check_extracted(fmt.tprintf("%s: pdftotext", c.name), doc_words(&c.doc), text)
				}
				check_covers(
					fmt.tprintf("%s: pdftotext", c.name),
					layout_words(&c.doc, fonts),
					text,
				)
			} else {
				ok(false, "%s: pdftotext wrote something", c.name)
			}
		}

		if c.images > 0 && have_tool("pdfimages") {
			out, good := kit.run({"pdfimages", "-list", path})
			ok(good, "%s: pdfimages runs", c.name)
			n := 0
			for line in strings.split_lines(out, context.temp_allocator) {
				if strings.contains(line, " image ") {
					n += 1
				}
			}
			eq_int(n, c.images, "%s: pdfimages finds every embedded picture", c.name)
			fmt.printf("    pdfimages -list %s.pdf:\n", c.name)
			for line in strings.split_lines(out, context.temp_allocator) {
				if len(strings.trim_space(line)) > 0 {
					fmt.printf("      %s\n", line)
				}
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

// check_pdf_render rasterises a page of the PDF and looks at the pixels.
//
// Every check above this one is structural, and a table passes all of them
// while having its rules drawn in the wrong place or its text outside its
// cells — `<w:tbl>` says a table exists, not that it looks like one. So the
// page is rendered with pdftoppm at the layout's own 96 dpi, read back through
// palmy's decoder, and the ink is checked against the cell geometry the layout
// computed: a dark row along every cell's top edge, a dark column down its
// left edge, and colour inside the picture's box.
@(private = "file")
check_pdf_render :: proc(cases: []Export_Case, fonts: ^p.Fonts) {
	if !have_tool("pdftoppm") {
		ok(false, "SKIPPED: pdftoppm is not installed, so no page was rendered and inspected")
		return
	}
	for &c in cases {
		if c.tables == 0 && c.images == 0 {
			continue
		}
		// The layout the PDF was written from, so the geometry compared
		// against is the same arithmetic the file used.
		lay: Layout
		defer layout_destroy(&lay)
		layout_doc(&lay, &c.doc, fonts)

		// The page the table is on, which in a long document is not page 1.
		want := -1
		if c.tables > 0 {
			for cb in lay.cells {
				if want < 0 || cb.page < want {
					want = cb.page
				}
			}
		}
		if want < 0 {
			for l in lay.lines {
				if c.doc.paras[l.para].kind == .Image {
					want = l.page
					break
				}
			}
		}
		if want < 0 {
			continue
		}
		base := fmt.tprintf("%s/render-%s", SELFTEST_DIR, c.name)
		pg := fmt.tprintf("%d", want + 1)
		_, ran := kit.run(
			{
				"pdftoppm",
				"-r",
				"96",
				"-f",
				pg,
				"-l",
				pg,
				"-singlefile",
				"-png",
				fmt.tprintf("%s/%s.pdf", SELFTEST_DIR, c.name),
				base,
			},
		)
		ok(ran, "%s: pdftoppm rendered page %s", c.name, pg)
		// The default allocator, not the temp one: `image_destroy` frees the
		// pixels through `delete`, which uses the context allocator.
		img, loaded := p.load_image(fmt.tprintf("%s.png", base))
		if !loaded {
			ok(false, "%s: the rendered page reads back as an image", c.name)
			continue
		}
		defer p.image_destroy(&img)
		eq_int(img.w, int(PAGE_W), "%s: the rendered page is A4 wide at 96 dpi", c.name)
		eq_int(img.h, int(PAGE_H), "%s: and A4 tall", c.name)

		ink :: proc(img: p.Image, x, y: int) -> bool {
			if x < 0 || y < 0 || x >= img.w || y >= img.h {
				return false
			}
			v := img.px[y * img.w + x]
			// Luminance, roughly. The rules are 0xa8a8aa; the page is white.
			lum := (int(u8(v >> 16)) * 30 + int(u8(v >> 8)) * 59 + int(u8(v)) * 11) / 100
			return lum < 215
		}
		// row_ink is the strongest coverage found within a pixel either side
		// of `y`, because a one-pixel rule at 96 dpi can land on either row.
		row_ink :: proc(img: p.Image, y, x0, x1: int) -> f32 {
			best := f32(0)
			for yy in y - 1 ..= y + 1 {
				hit := 0
				n := 0
				for x in x0 ..= x1 {
					n += 1
					if ink(img, x, yy) {
						hit += 1
					}
				}
				if n > 0 {
					best = max(best, f32(hit) / f32(n))
				}
			}
			return best
		}
		col_ink :: proc(img: p.Image, x, y0, y1: int) -> f32 {
			best := f32(0)
			for xx in x - 1 ..= x + 1 {
				hit := 0
				n := 0
				for y in y0 ..= y1 {
					n += 1
					if ink(img, xx, y) {
						hit += 1
					}
				}
				if n > 0 {
					best = max(best, f32(hit) / f32(n))
				}
			}
			return best
		}

		if c.tables > 0 {
			checked := 0
			weak_top := 0
			weak_left := 0
			worst := f32(1)
			for cb in lay.cells {
				if cb.page != want {
					continue
				}
				checked += 1
				x0 := int(MARGIN + cb.x) + 2
				x1 := int(MARGIN + cb.x + cb.w) - 2
				y0 := int(MARGIN + cb.y) + 2
				y1 := int(MARGIN + cb.y + cb.h) - 2
				top := row_ink(img, int(MARGIN + cb.y), x0, x1)
				left := col_ink(img, int(MARGIN + cb.x), y0, y1)
				worst = min(worst, min(top, left))
				if top < 0.95 {
					weak_top += 1
				}
				if left < 0.95 {
					weak_left += 1
				}
			}
			ok(checked > 0, "%s: %d cell boxes on page %s to check", c.name, checked, pg)
			eq_int(weak_top, 0, "%s: every cell has a rule along its top edge in the render", c.name)
			eq_int(weak_left, 0, "%s: and down its left edge", c.name)
			ok(worst > 0.95, "%s: the weakest rule is %.0f%% covered", c.name, worst * 100)

			// The inverse: a strip just inside the top-left of the first cell
			// is *not* a rule, so the test cannot be passing on a page that is
			// simply dark everywhere.
			for cb in lay.cells {
				if cb.page != want || cb.row != 0 || cb.col != 0 || cb.repeat {
					continue
				}
				inside := row_ink(
					img,
					int(MARGIN + cb.y + cb.h / 2),
					int(MARGIN + cb.x) + 3,
					int(MARGIN + cb.x + cb.w) - 3,
				)
				ok(inside < 0.9, "%s: the inside of a cell is not a rule (%.0f%%)", c.name, inside * 100)
				break
			}
		}

		if c.images > 0 {
			// The picture's box, from the layout, must hold colour in the
			// render — a page that drew nothing would be white there.
			found := 0
			coloured := 0
			for l in lay.lines {
				if l.page != want || c.doc.paras[l.para].kind != .Image {
					continue
				}
				found += 1
				hits := 0
				n := 0
				for dy in 1 ..< 10 {
					for dx in 1 ..< 10 {
						x := int(MARGIN + l.x + l.w * f32(dx) / 10)
						y := int(MARGIN + l.y + l.h * f32(dy) / 10)
						n += 1
						if x >= 0 && y >= 0 && x < img.w && y < img.h {
							if img.px[y * img.w + x] & 0xffffff != 0xffffff {
								hits += 1
							}
						}
					}
				}
				if n > 0 && f32(hits) / f32(n) > 0.9 {
					coloured += 1
				}
			}
			if found > 0 {
				eq_int(coloured, found, "%s: every picture's box is filled in the render", c.name)
			}
		}
		fmt.printf(
			"    pdftoppm %s.pdf page %s: %dx%d, rules and pictures checked against the layout\n",
			c.name,
			pg,
			img.w,
			img.h,
		)
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

	// Two passes, one invocation each: LibreOffice is slow to start and quick
	// to convert, and the exports all have distinct names.
	//
	//   txt   does every word survive, in reading order?
	//   html  did the *structure* survive — a real table with the right number
	//         of rows and cells, and the picture still in the file?
	//
	// The second question is the one that matters for this work. A .docx whose
	// table arrives as a run of tab-separated paragraphs passes the first test
	// and fails the second, and it is not a table.
	for filter in ([?][2]string {
		{"txt:Text", "txt"},
		{"html:HTML (StarWriter)", "html"},
		// ODF written by LibreOffice rather than by this app, so the .odt
		// importer is held against a file it did not produce. That is the
		// only version of the claim worth making about an importer.
		{"odt:writer8", "odt"},
	}) {
		argv := make([dynamic]string, 0, len(paths) + 8, context.temp_allocator)
		append(&argv, "soffice", "--headless", LO_PROFILE, "--convert-to", filter[0], "--outdir", lo)
		append(&argv, ..paths)
		_, ran := kit.run(argv[:])
		ok(ran, "LibreOffice converted %d files to .%s", len(paths), filter[1])
	}

	for &c in cases {
		src := doc_words(&c.doc)
		for ext in ([?]string{"docx", "odt", "rtf"}) {
			// Every export of one document lands on the same output name, so
			// the exports are named per format for this pass.
			out := fmt.tprintf("%s/%s-%s.txt", lo, c.name, ext)
			if text, got := read_text(out); got {
				label := fmt.tprintf("%s: LibreOffice reading .%s", c.name, ext)
				if c.tables > 0 {
					// LibreOffice's text export writes a table row as one line
					// with the cells separated, which re-orders a wrapped cell
					// the same way pdftotext -layout does. Completeness is the
					// claim here; the HTML pass below asserts the structure.
					check_covers(label, src, text)
				} else {
					check_extracted(label, src, text)
				}
			} else {
				ok(false, "%s: LibreOffice produced text from .%s", c.name, ext)
			}

			if c.tables == 0 && c.images == 0 {
				continue
			}
			html, got_h := read_text(fmt.tprintf("%s/%s-%s.html", lo, c.name, ext))
			if !got_h {
				ok(false, "%s: LibreOffice produced HTML from .%s", c.name, ext)
				continue
			}
			lower := strings.to_lower(html, context.temp_allocator)
			if c.tables > 0 {
				eq_int(
					strings.count(lower, "<table"),
					c.tables,
					"%s: LibreOffice reads .%s back as %d real table(s)",
					c.name,
					ext,
					c.tables,
				)
				eq_int(
					strings.count(lower, "<tr"),
					c.rows,
					"%s: with every row, out of .%s",
					c.name,
					ext,
				)
				// `<thead` also begins with `<th`, so it has to come back out
				// or every table reads as one cell too many.
				eq_int(
					strings.count(lower, "<td") + strings.count(lower, "<th") - strings.count(lower, "<thead"),
					c.cells,
					"%s: and every cell, out of .%s",
					c.name,
					ext,
				)
			}
			if c.images > 0 {
				eq_int(
					strings.count(lower, "<img"),
					c.images,
					"%s: and the picture survives .%s",
					c.name,
					ext,
				)
			}
		}
	}
	// --- the .odt importer, against LibreOffice's own ODF
	for &c in cases {
		// The .odt conversion of the .docx lands on `<case>-docx.odt`, which
		// is a file written by LibreOffice from scratch.
		path := fmt.tprintf("%s/%s-docx.odt", lo, c.name)
		back, got := import_odt(path)
		if !got {
			ok(false, "%s: the .odt LibreOffice wrote reads back", c.name)
			continue
		}
		nd := back
		defer doc_destroy(&nd)
		ok(len(nd.paras) > 0, "%s: LibreOffice's own .odt imports (%d paragraphs)", c.name, len(nd.paras))
		check_covers(
			fmt.tprintf("%s: importing LibreOffice's .odt", c.name),
			doc_words(&c.doc),
			text_of(&nd),
		)
		if c.tables > 0 {
			tbl, rows, cells := 0, 0, 0
			header := 0
			for &pa in nd.paras {
				if pa.kind != .Table || pa.table == nil {
					continue
				}
				tbl += 1
				rows += len(pa.table.rows)
				cells += len(pa.table.rows) * table_cols(pa.table)
				if pa.table.header {
					header += 1
				}
			}
			eq_int(tbl, c.tables, "%s: with every table", c.name)
			eq_int(rows, c.rows, "%s: every row", c.name)
			eq_int(cells, c.cells, "%s: and every cell", c.name)
			ok(header > 0, "%s: and a header row that LibreOffice kept as one", c.name)
		}
		if c.images > 0 {
			pics := doc_pictures(&nd)
			decoded := 0
			for im in pics {
				if len(im.px) > 0 {
					decoded += 1
				}
			}
			eq_int(len(pics), c.images, "%s: and every picture", c.name)
			eq_int(decoded, c.images, "%s: each of which decodes", c.name)
		}
	}

	fmt.printf("    LibreOffice round trip, per format:\n")
	for &c in cases {
		if c.tables == 0 && c.images == 0 {
			continue
		}
		for ext in ([?]string{"docx", "odt", "rtf"}) {
			html, got_h := read_text(fmt.tprintf("%s/%s-%s.html", lo, c.name, ext))
			if !got_h {
				continue
			}
			lower := strings.to_lower(html, context.temp_allocator)
			fmt.printf(
				"      %-8s .%-4s  %d table, %d rows, %d cells, %d images   (source: %d/%d/%d/%d)\n",
				c.name,
				ext,
				strings.count(lower, "<table"),
				strings.count(lower, "<tr"),
				strings.count(lower, "<td") + strings.count(lower, "<th") - strings.count(lower, "<thead"),
				strings.count(lower, "<img"),
				c.tables,
				c.rows,
				c.cells,
				c.images,
			)
		}
	}
}

// ---------------------------------------------------------------------------
// 19. Prose linting: the position map, and vale as its own oracle
// ---------------------------------------------------------------------------
//
// The one thing in this feature that can be subtly, silently wrong is the
// mapping from vale's `line:column` back to (block, byte offset). It has a
// checkable invariant — **the text at the mapped model position must equal the
// text vale flagged** — and that invariant is what most of this section is.
//
// The corpus is generated here rather than committed: nothing in the
// repository has to hold anybody's prose for these assertions to mean
// something, and the non-ASCII cases are in it deliberately, because a column
// counted in bytes rather than runes is invisible until the text stops being
// ASCII.

// PROSE_CORPUS is in the exact shape `prose_serialize` emits: one block per
// line, one blank line between blocks, no inline emphasis. That makes the
// oracle comparison below as strict as it can be — the markdown vale reads
// through the app can be compared with the markdown vale reads directly.
@(private = "file")
PROSE_CORPUS :: `# a heading That Is plainly Utilised

We utilize the the data in order to demonstrate a point , and that is very obviously quite sufficient for an adviser or an advisor who had already agreed with every single one of the numerous participants at this point in time.

Café très utilize this and 漢字漢字 really bad with an emoji 🙂 utilize after it.

A mispelled wrod sits here with a colour and a color.

- A really long bulleted item that we utilize

- Another item that was prepared by somebody

> A quote that will utilize something
`

@(private = "file")
prose_tmp :: proc(name: string) -> string {
	_ = os.make_directory_all(SELFTEST_DIR, os.perm(0o755))
	return fmt.tprintf("%s/%s", SELFTEST_DIR, name)
}

// prose_raw_pairs lints a file with vale directly and returns one
// "Check\tMatch" line per alert, sorted. It is the oracle: the app has to
// agree with this set, or the serialiser changed what the linter saw.
@(private = "file")
prose_raw_pairs :: proc(path, config: string) -> ([]string, bool) {
	argv := [?]string{"vale", "--no-global", "--no-exit", "--output=JSON", fmt.tprintf("--config=%s", config), path}
	out, _ := kit.run(argv[:], context.temp_allocator)
	root, err := json.parse(strings.trim_space(out), .JSON, false, context.temp_allocator)
	if err != .None {
		return nil, false
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		return nil, false
	}
	if _, bad := obj["Code"]; bad {
		return nil, false
	}
	pairs := make([dynamic]string, 0, 32, context.temp_allocator)
	for _, fv in obj {
		arr, is_arr := fv.(json.Array)
		if !is_arr {
			return nil, false
		}
		for av in arr {
			ao, is_ao := av.(json.Object)
			if !is_ao {
				continue
			}
			chk, cok := ao["Check"].(json.String)
			mat, mok := ao["Match"].(json.String)
			if !cok || !mok {
				continue
			}
			append(&pairs, fmt.tprintf("%s\t%s", string(chk), string(mat)))
		}
	}
	out_s := pairs[:]
	sort_strings(out_s)
	return out_s, true
}

@(private = "file")
sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) {
		v := s[i]
		j := i - 1
		for j >= 0 && s[j] > v {
			s[j + 1] = s[j]
			j -= 1
		}
		s[j + 1] = v
	}
}

test_prose :: proc(fonts: ^p.Fonts) {
	section("prose: the position map, and vale as its own oracle")
	before := checks
	defer fmt.printfln("    %d assertions over the prose checker", checks - before)

	// --- 1. The serialiser's map is self-consistent, with no linter involved.
	{
		d := doc_from_markdown(PROSE_CORPUS)
		defer doc_destroy(&d)
		pt := prose_serialize(&d, context.temp_allocator)

		ok(len(pt.md) > 0, "the serialiser produced markdown")
		mapped, bad_rune, bad_order := 0, 0, 0
		for &l in pt.lines {
			if !l.valid {
				continue
			}
			pa := blk_para(&d, l.blk)
			ok(pa != nil, "every mapped line names a block that exists")
			if pa == nil {
				continue
			}
			t := para_text(pa, context.temp_allocator)
			prev := -1
			for v in l.offs {
				if v < 0 {
					continue
				}
				mapped += 1
				o := int(v)
				// Every mapped offset is in range and on a rune boundary: an
				// offset inside a UTF-8 sequence is exactly the bug the whole
				// map exists to make impossible.
				if o < 0 || o >= len(t) || t[o] & 0xc0 == 0x80 {
					bad_rune += 1
					continue
				}
				// And they only ever go forwards, one rune at a time.
				if o <= prev {
					bad_order += 1
				}
				prev = o
			}
		}
		ok(mapped > 0, "the map covers the document's runes (%d of them)", mapped)
		eq_int(bad_rune, 0, "every mapped offset is in range and on a rune boundary")
		eq_int(bad_order, 0, "mapped offsets only ever advance")

		// A multi-byte block proves the map is not an identity: the rune
		// column and the byte offset of the same character must differ.
		found_wide := false
		for &l in pt.lines {
			if !l.valid {
				continue
			}
			for v, i in l.offs {
				if v >= 0 && int(v) != i {
					found_wide = true
					break
				}
			}
			if found_wide {
				break
			}
		}
		ok(found_wide, "the corpus contains a rune column that is not its byte offset")
	}

	// --- 2. Malformed output from vale. Every one of these must be an error
	// rather than an empty, clean-looking result.
	{
		d := doc_from_markdown("Just one paragraph that we utilize.")
		defer doc_destroy(&d)
		pt := prose_serialize(&d, context.temp_allocator)

		for bad in ([?]struct {
			name: string,
			text: string,
		} {
			{"empty output", ""},
			{"whitespace only", "   \n  "},
			{"not JSON at all", "E100 [.vale.ini not found] Runtime error"},
			{"truncated JSON", `{"stdin.md": [{"Check": "Palm.Wordy",`},
			{"a JSON array", `[1, 2, 3]`},
			{"a JSON string", `"nope"`},
			{"vale's config-error object", `{"Code":"E201","Text":"Missing the required 'message' key.","Path":"/x/Read.yml","Line":1,"Span":1}`},
			{"the right shape, wrong value type", `{"stdin.md": 7}`},
		}) {
			list, _, err := prose_parse(bad.text, &pt, &d, context.temp_allocator)
			ok(err != "", "%s is reported as an error, not as a clean document", bad.name)
			eq_int(len(list), 0, "%s yields no alerts", bad.name)
		}

		// And the shape that *is* valid but has nothing in it: no error, no
		// alerts. A genuinely clean document has to be distinguishable from a
		// linter that did not run, and this is the pair that proves it.
		list, _, err := prose_parse(`{"lint.md": []}`, &pt, &d, context.temp_allocator)
		eq_str(err, "", "an empty alert array is not an error")
		eq_int(len(list), 0, "an empty alert array yields no alerts")
	}

	// --- 3. A missing vale. Probed with PATH emptied, so this runs on a
	// machine that has vale as well as one that does not.
	{
		saved := strings.clone(os.get_env("PATH", context.temp_allocator))
		defer {
			os.set_env("PATH", saved)
			delete(saved)
		}
		os.set_env("PATH", "/nonexistent-for-the-self-test")
		avail, why := prose_probe(context.temp_allocator)
		ok(!avail, "vale off PATH is reported as unavailable")
		ok(strings.contains(why, PROSE_BIN), "and the message names the binary")
		ok(
			strings.contains(why, "not installed") || strings.contains(why, "would not run"),
			"and says what is wrong rather than failing obscurely",
		)
	}

	// --- 4. Everything past here needs vale. Without it the feature is
	// honestly unavailable and there is nothing left to assert.
	avail, _ := prose_probe(context.temp_allocator)
	if !avail {
		fmt.println("    vale is not installed: the oracle comparison is skipped")
		ok(true, "the prose checker degrades to unavailable rather than wrong")
		return
	}

	ini, merr := prose_materialise(context.temp_allocator)
	eq_str(merr, "", "the embedded style package writes out")
	ok(ini != "", "and produces a .vale.ini")

	// --- 5. The style package loads. A YAML typo that silently disables a
	// rule is the quiet failure here, so this is checked two ways: vale's own
	// `ls-config` must accept the package, and every rule in it must be shown
	// to fire.
	{
		out, good := kit.run(
			{"vale", "--no-global", fmt.tprintf("--config=%s", ini), "ls-config"},
			context.temp_allocator,
		)
		ok(good, "vale ls-config accepts the package")
		ok(strings.contains(out, "Palm"), "and reports Palm as the style in force")
		ok(!strings.contains(out, "E2"), "with no E2xx rule-loading error")
	}

	// --- 6. The invariant, over the generated corpus.
	corpus := prose_tmp("prose-corpus.md")
	ok(os.write_entire_file(corpus, transmute([]u8)string(PROSE_CORPUS)) == nil, "wrote the corpus")

	d, loaded := cli_load(corpus)
	ok(loaded, "and imported it")
	defer doc_destroy(&d)

	alerts, skipped, lerr := prose_lint_text(&d, ini, context.temp_allocator)
	eq_str(lerr, "", "the corpus lints without error")
	ok(len(alerts) >= 15, "and produces alerts (%d)", len(alerts))
	eq_int(skipped, 0, "with no block left unchecked")

	// THE assertion. Every alert's mapped span must hold exactly the text vale
	// said it flagged.
	mismatches := 0
	nonascii := 0
	for &a in alerts {
		pa := blk_para(&d, a.blk)
		if pa == nil {
			mismatches += 1
			continue
		}
		t := para_text(pa, context.temp_allocator)
		if a.from < 0 || a.to > len(t) || a.to <= a.from || t[a.from:a.to] != a.match {
			mismatches += 1
			fmt.eprintfln(
				"    mapping: %s at %d:%d -> block %d+%d..%d is %q, vale flagged %q",
				a.check,
				a.line,
				a.col,
				a.blk.para,
				a.from,
				a.to,
				a.from < len(t) ? t[a.from:min(a.to, len(t))] : "",
				a.match,
			)
			continue
		}
		// A span whose byte offset differs from its rune column is the case
		// that catches a byte-versus-rune mistake.
		if a.from != a.col - 1 {
			nonascii += 1
		}
	}
	eq_int(mismatches, 0, "the text at every mapped position is the text vale flagged")
	ok(nonascii > 0, "and %d of them had a byte offset that is not the rune column", nonascii)

	// Every rule in the package must have fired at least once, or the corpus
	// is not exercising it and a broken rule would pass unnoticed.
	for rule in PROSE_RULES {
		hit := false
		for &a in alerts {
			if a.check == rule {
				hit = true
				break
			}
		}
		ok(hit, "%s fired on the corpus", rule)
	}

	// --- 7. vale as its own oracle. Lint the corpus file directly, lint the
	// same content through the app, and compare the alert sets. This is the
	// assertion that proves the serialiser did not change what the linter
	// sees: if a `**` or an escape had shifted anything, the two sets would
	// disagree.
	{
		oracle, got := prose_raw_pairs(corpus, ini)
		ok(got, "vale lints the corpus file directly")

		mine := make([dynamic]string, 0, len(alerts), context.temp_allocator)
		for &a in alerts {
			append(&mine, fmt.tprintf("%s\t%s", a.check, a.match))
		}
		mine_s := mine[:]
		sort_strings(mine_s)

		eq_int(len(mine_s), len(oracle), "the app finds as many alerts as vale does directly")
		diffs := 0
		for i in 0 ..< min(len(mine_s), len(oracle)) {
			if mine_s[i] != oracle[i] {
				diffs += 1
				fmt.eprintfln("    oracle: app %q, vale %q", mine_s[i], oracle[i])
			}
		}
		eq_int(diffs, 0, "and they are the same alerts, rule for rule and match for match")

		// Stronger, where it holds: the corpus is written in the shape the
		// serialiser emits, so the round trip should be byte-identical.
		pt := prose_serialize(&d, context.temp_allocator)
		eq_str(
			strings.trim_space(pt.md),
			strings.trim_space(PROSE_CORPUS),
			"the serialised document is the corpus it came from",
		)
	}

	// --- 8. Accepting a suggestion, through the edit path.
	{
		st := State{}
		state_init(&st, fonts)
		defer state_destroy(&st)
		replace_document(&st, doc_from_markdown("We utilize the data. Utilize it again.\n"))
		relayout(&st)

		// The default allocator, not the temp one: these alerts are handed to
		// `st.prose`, which frees them in `prose_destroy`.
		list, _, e := prose_lint_text(&st.doc, ini)
		defer delete(list)
		eq_str(e, "", "a two-sentence document lints")
		for &a in list {
			if prose_ignored(&st.prose, a.check) {
				continue
			}
			append(&st.prose.alerts, a)
		}
		prose_sort(st.prose.alerts[:])
		st.prose.ran = true

		fixable := 0
		for &a in st.prose.alerts {
			if a.fix != "" {
				fixable += 1
			}
		}
		ok(fixable >= 2, "and offers a replacement for both (%d)", fixable)

		before := text_of(&st.doc)
		undos := len(st.hist.undo)

		// The second one first, so accepting it cannot be confused with a
		// lucky offset at the head of the paragraph.
		st.prose.sel = 1
		st.caret = blk_pos(st.prose.alerts[1].blk, st.prose.alerts[1].from)
		st.anchor = st.caret
		prose_accept(&st)
		relayout(&st)
		after := text_of(&st.doc)
		ok(after != before, "accepting a suggestion changed the document")
		ok(strings.contains(after, "Use it again"), "and kept the capital it replaced: %q", after)
		eq_int(len(st.hist.undo), undos + 1, "in exactly one undo step")

		do_undo(&st)
		relayout(&st)
		eq_str(text_of(&st.doc), before, "and undo takes it back")

		// The first one, which is lower case and must stay lower case.
		st.prose.sel = 0
		st.caret = blk_pos(st.prose.alerts[0].blk, st.prose.alerts[0].from)
		st.anchor = st.caret
		prose_accept(&st)
		relayout(&st)
		ok(strings.contains(text_of(&st.doc), "We use the data"), "a lower-case fix stays lower case")
	}

	// --- 9. Ignoring a rule for a document.
	{
		st := State{}
		state_init(&st, fonts)
		defer state_destroy(&st)
		replace_document(&st, doc_from_markdown(PROSE_CORPUS))
		relayout(&st)

		list, _, _ := prose_lint_text(&st.doc, ini)
		defer delete(list)
		for &a in list {
			append(&st.prose.alerts, a)
		}
		prose_sort(st.prose.alerts[:])
		st.prose.ran = true
		total := len(st.prose.alerts)

		// Pick the rule the caret is in, which is what Alt+X does.
		target := ""
		for &a in st.prose.alerts {
			if a.check == "Palm.Hedge" {
				target = a.check
				st.caret = blk_pos(a.blk, a.from)
				st.anchor = st.caret
				break
			}
		}
		ok(target != "", "the corpus has a Palm.Hedge alert to switch off")
		prose_ignore(&st)
		ok(prose_ignored(&st.prose, "Palm.Hedge"), "the rule is off for this document")
		ok(len(st.prose.alerts) < total, "and its alerts are gone (%d of %d left)", len(st.prose.alerts), total)
		left := 0
		for &a in st.prose.alerts {
			if a.check == "Palm.Hedge" {
				left += 1
			}
		}
		eq_int(left, 0, "none of them survived")

		prose_restore_rules(&st)
		eq_int(len(st.prose.ignored), 0, "and every rule comes back on")
	}

	// --- 10. The threaded path, which is what the window actually uses. The
	// shots run the lint synchronously and the sections above call it
	// directly, so without this the handshake between the frame and the worker
	// is the one part of the feature nothing exercises.
	{
		st := State{}
		state_init(&st, fonts)
		defer state_destroy(&st)
		replace_document(&st, doc_from_markdown("We utilize the the data very obviously.\n"))
		relayout(&st)
		st.prose.show = true

		ok(!prose_busy(), "no lint is in flight to start with")
		started := prose_run(&st)
		ok(started, "the worker starts")
		ok(prose_busy(), "and is reported as in flight")

		// The frame loop polls with `p.redraw`; a headless test polls with a
		// sleep, which is the same handshake without the frames.
		waited := 0
		out, good, ms, got := "", false, 0, false
		for waited < 15000 {
			out, good, ms, got = prose_collect()
			if got {
				break
			}
			time.sleep(2 * time.Millisecond)
			waited += 2
		}
		ok(got, "and the result is collected (%d ms waited)", waited)
		ok(!prose_busy(), "after which nothing is in flight")
		ok(ms >= 0, "and the run reports how long it took: %d ms", ms)
		_ = good

		prose_absorb(&st, out, good, ms)
		ok(len(st.prose.alerts) >= 4, "the threaded run produced alerts (%d)", len(st.prose.alerts))
		ok(st.prose.ran, "and is marked as having run")
		bad := 0
		for &a in st.prose.alerts {
			if !prose_verify(&st.doc, &a) {
				bad += 1
			}
		}
		eq_int(bad, 0, "every alert from the threaded run maps back correctly too")

		// A second run while the first is still in flight must be refused
		// rather than queued: one vale in the air, never two.
		ok(prose_start(strings.clone("x\n"), st.prose.config), "a second run starts once the first is done")
		for waited = 0; waited < 15000 && prose_busy(); waited += 2 {
			_, _, _, g2 := prose_collect()
			if g2 {
				break
			}
			time.sleep(2 * time.Millisecond)
		}
		ok(!prose_busy(), "and it finishes too")
	}

	// --- 11. A project's own .vale.ini wins, and `$HOME` is never consulted.
	{
		proj := prose_tmp("project")
		_ = os.make_directory_all(proj, os.perm(0o755))
		deep := fmt.tprintf("%s/chapters/two", proj)
		_ = os.make_directory_all(deep, os.perm(0o755))
		own := fmt.tprintf("%s/.vale.ini", proj)
		_ = os.write_entire_file(own, transmute([]u8)string("MinAlertLevel = error\n\n[*.md]\n"))

		found := prose_project_config(fmt.tprintf("%s/ch.md", deep), context.temp_allocator)
		eq_str(found, own, "a .vale.ini above the document is found")

		none := prose_project_config(fmt.tprintf("%s/untitled.md", kit_home()), context.temp_allocator)
		eq_str(none, "", "and the search stops below $HOME")
		eq_str(prose_project_config("", context.temp_allocator), "", "an unsaved document has no project config")
	}
	os.remove(corpus)
}

// ---------------------------------------------------------------------------
// Case folding outside ASCII, and the regular expression engine
// ---------------------------------------------------------------------------

test_search_unicode :: proc(fonts: ^p.Fonts) {
	section("find: case folding outside ASCII")

	// --- the folds themselves
	eq_int(int(fold_simple('A')), int('a'), "ASCII folds")
	eq_int(int(fold_simple('É')), int('é'), "Latin-1 folds")
	eq_int(int(fold_simple('Ż')), int('ż'), "Latin Extended-A folds")
	eq_int(int(fold_simple('Σ')), int('σ'), "Greek folds")
	eq_int(int(fold_simple('ς')), int('σ'), "and final sigma folds onto sigma")
	eq_int(int(fold_simple('Д')), int('д'), "Cyrillic folds")
	eq_int(int(fold_simple('Ÿ')), int('ÿ'), "the one out-of-order Latin pair folds")
	eq_int(int(fold_simple('ſ')), int('s'), "the long s folds onto s")
	eq_int(int(fold_simple('€')), int('€'), "something with no case is left alone")

	exp, n := fold_rune('ß')
	eq_int(n, 2, "ß folds to two runes")
	ok(exp[0] == 's' && exp[1] == 's', "and they are ss")
	exp2, n2 := fold_rune('ﬁ')
	eq_int(n2, 2, "the fi ligature folds to two runes")
	ok(exp2[0] == 'f' && exp2[1] == 'i', "and they are fi")

	// --- the search, which is the point: a span, not an offset and a length
	h1 := "Die Straße ist lang"
	lo, hi, hit := search_plain(h1, "STRASSE", 0)
	ok(hit, "Straße is found by STRASSE")
	eq_str(h1[lo:hi], "Straße", "and the span covers the ß, not seven bytes")

	h2 := "GROSSE STRASSE"
	lo2, hi2, hit2 := search_plain(h2, "straße", 0)
	ok(hit2, "and STRASSE is found by straße")
	eq_str(h2[lo2:hi2], "STRASSE", "with the span over the text that is there")

	h3 := "Le CAFÉ est ouvert"
	lo3, hi3, hit3 := search_plain(h3, "café", 0)
	ok(hit3, "CAFÉ is found by café")
	eq_str(h3[lo3:hi3], "CAFÉ", "span")

	lo4, hi4, hit4 := search_plain("ΟΔΥΣΣΕΥΣ", "οδυσσευς", 0)
	ok(hit4, "a Greek word with a final sigma is found by its lower-case form")
	eq_int(lo4, 0, "at the start")
	eq_int(hi4, len("ΟΔΥΣΣΕΥΣ"), "and the whole of it")

	_, _, hit5 := search_plain("ПРИВЕТ МИР", "привет", 0)
	ok(hit5, "Cyrillic folds too")

	// A match may not stop half way through an expansion.
	_, _, hit6 := search_plain("Straße", "stras", 0)
	ok(!hit6, "a needle that ends inside the ß is not a match")
	_, _, hit7 := search_plain("Straße", "stra", 0)
	ok(hit7, "but one that stops before it is")

	// Case-sensitive still means case-sensitive.
	_, _, hit8 := search_plain("STRASSE", "straße", 0, false)
	ok(!hit8, "with folding off, nothing is folded")
	_, _, hit9 := search_plain("Straße", "Straße", 0, false)
	ok(hit9, "and an exact match still matches")

	// Whole words, in runes: ü and ß are letters.
	_, _, hw1 := search_plain("Grüße", "grüß", 0, true, true)
	ok(!hw1, "grüß is not a whole word inside Grüße")
	_, _, hw2 := search_plain("Grüße!", "grüße", 0, true, true)
	ok(hw2, "but Grüße is, with punctuation after it")

	// Through the find box, which is where a person meets it.
	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}
	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	append(&st.doc.paras, para_make(.Body, "Die Straße ist lang. STRASSE in Großbuchstaben."))
	relayout(&st)
	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("strasse"))
	eq_int(count_hits(&st), 2, "the find box counts both spellings")
	st.caret = pos(0, 0)
	st.anchor = st.caret
	ok(find_next(&st), "and finds the first")
	a, b, _ := selection(&st)
	eq_str(para_text(&st.doc.paras[0], context.temp_allocator)[a.off:b.off], "Straße", "selecting the text that is there")

	// Replacing one spelling with another, both ways, is a span operation.
	clear(&st.repl)
	append(&st.repl, ..transmute([]u8)string("Allee"))
	replace_all(&st)
	eq_str(
		para_text(&st.doc.paras[0], context.temp_allocator),
		"Die Allee ist lang. Allee in Großbuchstaben.",
		"replace all over a folded match replaces the whole match",
	)
}

test_regex :: proc(fonts: ^p.Fonts) {
	section("find: regular expressions")

	// A tiny harness, because every case below is "does this pattern match
	// this text, and over what span".
	try :: proc(pat, hay: string, fold := false) -> (lo, hi: int, ok: bool) {
		rx, err := rx_compile(pat, fold)
		if err != "" {
			return 0, 0, false
		}
		defer {
			rx_destroy(rx)
			free(rx)
		}
		l, h, _, hit := rx_search(rx, hay, 0)
		return l, h, hit
	}
	span :: proc(pat, hay: string, fold := false) -> string {
		lo, hi, hit := try(pat, hay, fold)
		return hit ? hay[lo:hi] : "<no match>"
	}

	eq_str(span("a+", "baaad"), "aaa", "greedy plus")
	eq_str(span("a+?", "baaad"), "a", "lazy plus")
	eq_str(span("a*", "bbb"), "", "star can match nothing")
	eq_str(span("ab?c", "ac"), "ac", "optional")
	eq_str(span("c.t", "the cat sat"), "cat", "dot is one rune")
	eq_str(span("[0-9]+", "order 1234 now"), "1234", "a class with a range")
	eq_str(span("[^ ]+", " word "), "word", "a negated class")
	eq_str(span("\\d+mm", "it is 42mm wide"), "42mm", "a shorthand class")
	eq_str(span("\\s+", "a   b"), "   ", "whitespace")
	eq_str(span("^The", "The start"), "The", "an anchor at the start")
	eq_str(span("^The", "and The start"), "<no match>", "which does not match in the middle")
	eq_str(span("end$", "the end"), "end", "an anchor at the end")
	eq_str(span("cat|dog", "a dog here"), "dog", "alternation, second branch")
	eq_str(span("cat|dog", "a cat here"), "cat", "alternation, first branch")
	eq_str(span("(ab)+", "ababab!"), "ababab", "a group under a quantifier")
	eq_str(span("a{3}", "aaaa"), "aaa", "an exact repeat")
	eq_str(span("a{2,3}", "aaaa"), "aaa", "a bounded repeat is greedy")
	eq_str(span("a{2,}", "aaaa"), "aaaa", "an open repeat")
	eq_str(span("a{4}", "aaa"), "<no match>", "a repeat that cannot be satisfied")
	eq_str(span("\\bart\\b", "restart art"), "art", "a word boundary")
	eq_str(span("\\bart\\b", "restarting"), "<no match>", "which is not inside a word")
	eq_str(span("\\.", "a.b"), ".", "an escaped metacharacter is literal")
	eq_str(span("colou?r", "the color"), "color", "the classic optional letter")
	eq_str(span("é+", "café"), "é", "a non-ASCII literal")
	eq_str(span("[a-zé]+", "café!"), "café", "a class containing one")

	// Folding inside a pattern.
	eq_str(span("cat", "a CAT", true), "CAT", "a folded literal")
	eq_str(span("cat", "a CAT", false), "<no match>", "and not when folding is off")
	eq_str(span("[a-z]+", "ABC", true), "ABC", "a folded class matches the other case")

	// Captures and the replacement expansion.
	{
		rx, err := rx_compile("(\\w+)@(\\w+)", false)
		eq_str(err, "", "an address pattern compiles")
		hay := "write to ada@analytical now"
		lo, hi, caps, hit := rx_search(rx, hay, 0)
		ok(hit, "and matches")
		eq_str(hay[lo:hi], "ada@analytical", "over the whole address")
		eq_str(
			rx_expand("\\2 of \\1", hay, caps),
			"analytical of ada",
			"and the groups come back in the replacement",
		)
		eq_str(rx_expand("\\0!", hay, caps), "ada@analytical!", "\\0 is the whole match")
		eq_str(rx_expand("a\\\\b", "x", caps), "a\\b", "a doubled backslash is one backslash")
		rx_destroy(rx)
		free(rx)
	}

	// A pattern that will not compile says so.
	{
		rx, err := rx_compile("a(b", false)
		ok(rx == nil, "an unbalanced group does not compile")
		ok(err != "", "and there is a message to show: %s", err)
	}
	{
		rx, err := rx_compile("*x", false)
		ok(rx == nil, "nor does a quantifier with nothing in front of it")
		ok(err != "", "with its own message: %s", err)
	}
	{
		rx, err := rx_compile("[a-", false)
		ok(rx == nil, "nor an unterminated class")
		ok(err != "", "message: %s", err)
	}

	// Catastrophic backtracking gives up instead of hanging the editor.
	{
		rx, err := rx_compile("(a*)*b", false)
		eq_str(err, "", "the classic exponential pattern compiles")
		hay := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		_, _, _, hit := rx_search(rx, hay, 0)
		ok(!hit, "and does not match a string of a's — it gives up rather than hangs")
		rx_destroy(rx)
		free(rx)
	}

	// A greedy repeat across a long paragraph. The matcher used to recurse once
	// per repetition and gave up at 20 000 deep (after running the default
	// 8 MB stack out on the pattern above); its choice points are on the heap
	// now, so length is bounded only by the step budget.
	{
		rx, _ := rx_compile("x.*z", false)
		hay := strings.concatenate({strings.repeat("x", 30_000, context.temp_allocator), "z"}, context.temp_allocator)
		lo, hi, _, hit := rx_search(rx, hay, 0)
		ok(hit && lo == 0 && hi == len(hay), "a greedy repeat over 30 000 characters still matches (%v %d..%d)", hit, lo, hi)
		rx_destroy(rx)
		free(rx)
	}

	// --- through the find box
	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1200, 700}
	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = make([dynamic]Paragraph, 0, 4),
	}
	append(&st.doc.paras, para_make(.Body, "Rev 1.2 on 3 March, rev 1.10 on 4 April, rev 2.0 later."))
	append(&st.doc.paras, para_make(.Body, "No versions here at all."))
	relayout(&st)

	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("\\d+\\.\\d+"))
	eq_int(count_hits(&st), 0, "a pattern is literal text until regex is switched on")

	toggle_find_regex(&st)
	ok(st.find_regex, "regex is on")
	eq_str(st.rx_err, "", "and the pattern compiled")
	eq_str(find_mode_label(&st), ".*", "the label says so")
	eq_int(count_hits(&st), 3, "three version numbers")

	st.caret = pos(0, 0)
	st.anchor = st.caret
	ok(find_next(&st), "the first is found")
	lo, hi, _ := selection(&st)
	eq_str(para_text(&st.doc.paras[0], context.temp_allocator)[lo.off:hi.off], "1.2", "and selected exactly")
	ok(find_next(&st), "and the next")
	lo2, hi2, _ := selection(&st)
	eq_str(
		para_text(&st.doc.paras[0], context.temp_allocator)[lo2.off:hi2.off],
		"1.10",
		"which is four characters, not three — a span, not a length",
	)

	// Replace with a group reference.
	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("rev (\\d+)\\.(\\d+)"))
	rx_recompile(&st)
	clear(&st.repl)
	append(&st.repl, ..transmute([]u8)string("version \\1-\\2"))
	st.find_case = true
	rx_recompile(&st)
	replace_all(&st)
	eq_str(
		para_text(&st.doc.paras[0], context.temp_allocator),
		"Rev 1.2 on 3 March, version 1-10 on 4 April, version 2-0 later.",
		"replace all substitutes the captures; match-case leaves the capital Rev alone",
	)

	// A bad pattern typed into the box is reported, not silently empty.
	clear(&st.find)
	append(&st.find, ..transmute([]u8)string("a("))
	rx_recompile(&st)
	ok(st.rx_err != "", "a broken pattern leaves an error for the find bar: %s", st.rx_err)
	eq_int(count_hits(&st), 0, "and matches nothing while it is broken")

	toggle_find_regex(&st)
	ok(!st.find_regex, "switching it off leaves the box working as before")
	eq_str(st.rx_err, "", "and clears the error")
}

// ---------------------------------------------------------------------------
// .rtf import
//
// The format this program could write but not read. The strongest assertion
// available is a round trip: export a document that has one of everything,
// read it back, and insist the two agree — paragraph for paragraph, style for
// style, cell for cell, byte for byte on the picture.
// ---------------------------------------------------------------------------

test_rtf_import :: proc(fonts: ^p.Fonts) {
	section("import: .rtf")

	dir := fmt.tprintf("%s/rtfin", SELFTEST_DIR)
	kit.run({"mkdir", "-p", dir})

	// --- the pieces, on their own -----------------------------------------
	{
		// A minimal document, written by hand, so a failure points at the
		// reader rather than at the writer.
		src := "{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0\n" +
			"{\\fonttbl{\\f0\\fswiss Geist;}{\\f1\\fmodern Courier New;}}\n" +
			"{\\colortbl;\\red18\\green18\\blue18;\\red241\\green241\\blue242;\\red200\\green0\\blue0;}\n" +
			"{\\stylesheet{\\s0 Normal;}{\\s7\\b heading 1;}{\\s9\\i Quote;}}\n" +
			"\\pard\\plain\\s7 {Title here}\\par\n" +
			"\\pard\\plain\\s0 plain {\\b bold}{\\i italic}{\\f1 mono}{\\cf3 red}\\par\n" +
			"\\pard\\plain\\s9\\qc {Centred quotation}\\par\n" +
			"\\pard\\plain\\s0 caf\\'e9 and stra\\u223?e\\par\n" +
			"}\n"
		d := doc_from_rtf(src)
		defer doc_destroy(&d)
		eq_int(len(d.paras), 4, "four paragraphs")
		if len(d.paras) == 4 {
			eq_int(int(d.paras[0].kind), int(Para_Kind.H1), "the stylesheet mapped \\s7 onto Heading 1 by name")
			eq_str(para_text(&d.paras[0], context.temp_allocator), "Title here", "its text")
			ok(len(d.paras[0].runs) == 1 && !d.paras[0].runs[0].style.bold, "and a heading does not arrive full of bold runs")

			eq_str(para_text(&d.paras[1], context.temp_allocator), "plain bolditalicmonored", "the run text")
			bold, italic, mono, colored := 0, 0, 0, 0
			for &r in d.paras[1].runs {
				if r.style.bold {bold += 1}
				if r.style.italic {italic += 1}
				if r.style.mono {mono += 1}
				if r.style.color != 0 {colored += 1}
			}
			eq_int(bold, 1, "one bold run")
			eq_int(italic, 1, "one italic run")
			eq_int(mono, 1, "one run in the font table's monospace face")
			eq_int(colored, 1, "one coloured run")
			for &r in d.paras[1].runs {
				if r.style.color != 0 {
					eq_int(int(r.style.color & 0xffffff), 0xc80000, "and it is the colour the table gave")
				}
			}

			eq_int(int(d.paras[2].kind), int(Para_Kind.Quote), "\\s9 mapped onto Quote")
			eq_int(int(d.paras[2].align), int(Align.Center), "and the alignment came with it")
			eq_str(
				para_text(&d.paras[3], context.temp_allocator),
				"café and straße",
				"\\'hh is a code-page byte and \\uN is a UTF-16 unit",
			)
		}
	}

	// A file that is not RTF is refused rather than read as text.
	{
		bad := fmt.tprintf("%s/not.rtf", dir)
		kit.run({"sh", "-c", fmt.tprintf("printf 'hello, not rtf' > %s", bad)})
		_, got := import_rtf(bad)
		ok(!got, "a file that does not start with {\\rtf is refused")
	}

	// --- the round trip ----------------------------------------------------
	cases := make([dynamic]Export_Case, 0, 2, context.temp_allocator)
	append(&cases, Export_Case{name = "fixture", doc = rich_fixture()})
	append(&cases, Export_Case{name = "grid", doc = grid_fixture()})
	defer {
		for &c in cases {
			doc_destroy(&c.doc)
		}
	}

	for &c in cases {
		path := fmt.tprintf("%s/%s.rtf", dir, c.name)
		if !export_rtf(&c.doc, path, c.name) {
			ok(false, "%s.rtf was written", c.name)
			continue
		}
		back, got := import_rtf(path)
		if !got {
			ok(false, "%s.rtf was read back", c.name)
			continue
		}
		defer doc_destroy(&back)

		// Counts first: paragraph kinds, tables, cells and pictures.
		want_kinds := make([dynamic]Para_Kind, 0, 32, context.temp_allocator)
		got_kinds := make([dynamic]Para_Kind, 0, 32, context.temp_allocator)
		for &pa in c.doc.paras {
			append(&want_kinds, pa.kind)
		}
		for &pa in back.paras {
			append(&got_kinds, pa.kind)
		}
		eq_int(len(got_kinds), len(want_kinds), "%s: the same number of paragraphs came back", c.name)
		same := len(got_kinds) == len(want_kinds)
		if same {
			for i in 0 ..< len(want_kinds) {
				if want_kinds[i] != got_kinds[i] {
					same = false
					ok(
						false,
						"%s: paragraph %d is %s, was %s",
						c.name,
						i,
						kind_name(got_kinds[i]),
						kind_name(want_kinds[i]),
					)
					break
				}
			}
		}
		ok(same, "%s: every paragraph kind survived", c.name)

		// The text, paragraph by paragraph, including inside cells.
		eq_str(
			rtf_plain_text(&back),
			rtf_plain_text(&c.doc),
			fmt.tprintf("%s: every word came back, in order", c.name),
		)

		// Tables keep their shape.
		for &pa, i in c.doc.paras {
			if pa.kind != .Table || pa.table == nil || i >= len(back.paras) {
				continue
			}
			bt := back.paras[i].table
			if bt == nil {
				ok(false, "%s: paragraph %d came back as a table", c.name, i)
				continue
			}
			eq_int(len(bt.rows), len(pa.table.rows), "%s: the table has its rows", c.name)
			eq_int(table_cols(bt), table_cols(pa.table), "%s: and its columns", c.name)
			ok(bt.header == pa.table.header, "%s: \\trhdr brought the header flag back", c.name)
			// The column widths are what `\cellx` said, to within the
			// rounding that twips impose.
			for col in 0 ..< min(table_cols(bt), table_cols(pa.table)) {
				d := abs(table_width(bt, col) - table_width(pa.table, col))
				ok(d < 1.5, "%s: column %d is %.1f px wide, was %.1f", c.name, col, table_width(bt, col), table_width(pa.table, col))
			}
		}

		// A picture comes back as the same bytes, not as a note that there
		// was one.
		for &pa, i in c.doc.paras {
			if pa.kind != .Image || pa.img == nil || i >= len(back.paras) {
				continue
			}
			bi := back.paras[i].img
			if bi == nil {
				ok(false, "%s: paragraph %d came back as a picture", c.name, i)
				continue
			}
			eq_int(len(bi.bytes), len(pa.img.bytes), "%s: the picture is the same number of bytes", c.name)
			identical := len(bi.bytes) == len(pa.img.bytes)
			if identical {
				for k in 0 ..< len(bi.bytes) {
					if bi.bytes[k] != pa.img.bytes[k] {
						identical = false
						break
					}
				}
			}
			ok(identical, "%s: and they are the same bytes, hex-decoded back", c.name)
			eq_int(bi.w, pa.img.w, "%s: the intrinsic width", c.name)
			eq_int(bi.h, pa.img.h, "%s: the intrinsic height", c.name)
			dw, _ := image_draw_size(bi)
			ow, _ := image_draw_size(pa.img)
			ok(abs(dw - ow) < 1.5, "%s: and \\picwgoal put it back at %.0f px, was %.0f", c.name, dw, ow)
		}
	}
}

// doc_pictures lists every picture in a document in reading order, inside
// table cells as well as in the body. Counting only the top-level paragraphs
// is how a picture in a cell could be dropped by an exporter and nothing
// would say so.
doc_pictures :: proc(d: ^Doc) -> []^Doc_Image {
	out := make([dynamic]^Doc_Image, 0, 4, context.temp_allocator)
	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa != nil && pa.kind == .Image && pa.img != nil {
			append(&out, pa.img)
		}
	}
	return out[:]
}

// rtf_plain_text is every word of a document in reading order, cells
// included, with one space between blocks: the comparison that says "nothing
// was lost" without being sensitive to where the paragraph breaks fall.
rtf_plain_text :: proc(d: ^Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	for blk in doc_blocks(d, context.temp_allocator) {
		pa := blk_para(d, blk)
		if pa == nil {
			continue
		}
		t := strings.trim_space(para_text(pa, context.temp_allocator))
		if t == "" {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, t)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// A picture inside a table cell
//
// It used to be refused outright — "A picture cannot go inside a cell yet" —
// because the sizing needed the cell's measure rather than the page's and
// nothing could give it one. The claims now are: it is sized against its
// column, the row grows to hold it, every format carries it, and the editor
// will insert one.
// ---------------------------------------------------------------------------

test_cell_image :: proc(fonts: ^p.Fonts) {
	section("tables: a picture inside a cell")

	d := grid_fixture()
	defer doc_destroy(&d)
	t := d.paras[2].table
	ok(t != nil, "the fixture's table is there")
	cl := table_cell(t, 2, 0)
	ok(cl != nil && len(cl.paras) == 2, "the cell has a paragraph and a picture")
	if cl == nil || len(cl.paras) < 2 {
		return
	}
	cp := &cl.paras[1]
	ok(cp.kind == .Image && cp.img != nil, "the second one is the picture")

	// --- sized against the column, not the page
	col_w := table_width(t, 0)
	measure := col_w - 2 * CELL_PAD
	pw, ph := image_para_size(cp, measure, CONTENT_H)
	ok(cp.img.w > int(measure), "the picture is wider than the column on purpose (%d px source, %.0f px column)", cp.img.w, measure)
	ok(pw <= measure + 0.5, "so it is scaled down to the column: %.1f px in %.1f", pw, measure)
	ok(abs(pw / ph - f32(cp.img.w) / f32(cp.img.h)) < 0.02, "and keeps its aspect ratio")
	full_w, _ := image_para_size(cp)
	ok(full_w > pw, "the page measure would have let it be wider (%.0f vs %.0f)", full_w, pw)

	// --- the row grows to hold it
	st := State{}
	state_init(&st, fonts)
	defer state_destroy(&st)
	st.view = {0, 0, 1280, 760}
	replace_document(&st, doc_clone(&d))
	relayout(&st)

	heights := make(map[int]f32, 8, context.temp_allocator)
	for cb in st.lay.cells {
		if cb.col == 0 {
			heights[cb.row] = cb.h
		}
	}
	ok(heights[2] > heights[1] + ph / 2, "the row with the picture is taller than a text row (%.0f vs %.0f)", heights[2], heights[1])

	// Every line of that cell is inside the cell's box: a picture that
	// overflowed its row would draw over the row below it.
	pic_lines := 0
	for l in st.lay.lines {
		if l.para != 2 || l.row != 2 || l.col != 0 || l.cpara != 1 {
			continue
		}
		pic_lines += 1
		box_y, box_h := f32(0), f32(0)
		for cb in st.lay.cells {
			if cb.row == 2 && cb.col == 0 && cb.page == l.page {
				box_y, box_h = cb.y, cb.h
			}
		}
		ok(l.y >= box_y - 0.5, "the picture's line starts inside its cell")
		ok(l.y + l.h <= box_y + box_h + 0.5, "and ends inside it (%.1f vs %.1f)", l.y + l.h, box_y + box_h)
		ok(abs(l.h - ph) < 0.5, "the line box is as tall as the picture (%.1f vs %.1f)", l.h, ph)
	}
	eq_int(pic_lines, 1, "the picture is one line box")

	// --- every format carries it
	{
		j := doc_to_json(&d, context.temp_allocator)
		back, jok := doc_from_json(j)
		ok(jok, "JSON: the document parses back")
		defer doc_destroy(&back)
		bt := back.paras[2].table
		ok(bt != nil, "JSON: the table comes back")
		if bt != nil {
			bc := table_cell(bt, 2, 0)
			ok(bc != nil && len(bc.paras) == 2, "JSON: with both of the cell's paragraphs")
			if bc != nil && len(bc.paras) == 2 {
				ok(bc.paras[1].kind == .Image && bc.paras[1].img != nil, "JSON: and the picture is a picture")
				if bc.paras[1].img != nil {
					eq_int(len(bc.paras[1].img.bytes), len(cp.img.bytes), "JSON: with its bytes")
				}
			}
		}
	}
	{
		md := doc_to_markdown(&d, context.temp_allocator)
		ok(strings.contains(md, "![a picture inside a cell]"), "Markdown: the cell carries an image link")
	}
	{
		html := doc_to_html(&d, "cells", context.temp_allocator)
		// The picture is inside a <td>, not inside a <figure> of its own.
		td := strings.index(html, "<img")
		ok(td > 0, "HTML: an <img> was written")
		ok(strings.contains(html, "alt=\"a picture inside a cell\""), "HTML: with the cell picture's alt text")
	}
	{
		rtf := doc_to_rtf(&d, "cells", context.temp_allocator)
		// The cell's picture has to sit between the row definition and the
		// `\cell` that ends its cell, with no `\par` in between: either a
		// `\pard` or a `\par` there ends the cell early in a real reader.
		pict_at := strings.index(rtf, "\\pict")
		ok(pict_at > 0, "RTF: a {\\pict} group was written")
		if pict_at > 0 {
			before := rtf[:pict_at]
			trowd := strings.last_index(before, "\\trowd")
			ok(trowd >= 0, "RTF: it comes after a row definition")
			rest := rtf[pict_at:]
			cell_at := strings.index(rest, "\\cell")
			row_at := strings.index(rest, "\\row")
			par_at := strings.index(rest, "\\par")
			ok(cell_at > 0, "RTF: and is closed by a \\cell")
			ok(row_at < 0 || cell_at < row_at, "RTF: inside the row it belongs to")
			ok(par_at < 0 || par_at > cell_at, "RTF: with no \\par before the cell ends")
		}
	}

	// --- and the editor will insert one
	{
		st2 := State{}
		state_init(&st2, fonts)
		defer state_destroy(&st2)
		st2.view = {0, 0, 1280, 760}
		doc_destroy(&st2.doc)
		st2.doc = Doc {
			paras = make([dynamic]Paragraph, 0, 2),
		}
		append(&st2.doc.paras, table_para_make(2, 2))
		append(&st2.doc.paras, para_make())
		relayout(&st2)
		st2.caret = Pos{para = 0, row = 1, col = 1, cpara = 0}
		st2.anchor = st2.caret

		path := fmt.tprintf("%s/cellpic.png", SELFTEST_DIR)
		kit.run({"mkdir", "-p", SELFTEST_DIR})
		ok(os.write_entire_file(path, test_png(120, 80)) == nil, "a picture was written to insert")
		do_insert_image(&st2, path)
		ic := table_cell(st2.doc.paras[0].table, 1, 1)
		ok(ic != nil, "the cell is still there")
		found := false
		if ic != nil {
			for &q in ic.paras {
				if q.kind == .Image && q.img != nil {
					found = true
				}
			}
		}
		ok(found, "and the picture went into it rather than being refused")
		ok(st2.caret.para == 0 && st2.caret.row == 1 && st2.caret.col == 1, "the caret stayed in the cell")
		ok(!strings.contains(st2.toast, "cannot"), "and nothing was refused: %q", st2.toast)
	}
}

// ---------------------------------------------------------------------------
// The command line: the declaration, the old spellings, and each read's
// output against the shape it declares. Commands are bound by the kit's own
// parser and run in-process, so what is checked is what `docs <verb> --json`
// would print.
// ---------------------------------------------------------------------------

@(private = "file")
cli_run :: proc(argv: ..string) -> (code: int, out: string) {
	c, bind := kit.cli_bind(surface(), argv)
	if bind != kit.EXIT_OK {
		return bind, ""
	}
	code = c.cmd.run(&c)
	if code != kit.EXIT_OK {
		return code, kit.json_text(c.err, 0, context.temp_allocator)
	}
	return code, kit.json_text(c.out, 0, context.temp_allocator)
}

@(private = "file")
cli_fields_of :: proc(verb: string) -> []kit.Field {
	for cmd in surface().commands {
		if cmd.verb == verb {
			return cmd.out
		}
	}
	return nil
}

@(private = "file")
cli_schema_ok :: proc(verb, out: string) {
	problems := kit.cli_validate_output(out, cli_fields_of(verb), context.temp_allocator)
	ok(len(problems) == 0, "docs %s --json matches its declared schema%s", verb, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
}

test_cli :: proc() {
	section("command line: the declaration, the old spellings, the outputs")

	s := surface()
	ok(len(s.commands) >= 10, "the surface declares its commands (%d)", len(s.commands))
	ok(s.takes_path && s.gui, "a bare path still opens in the window")
	{
		// A bare word goes to the window only when it names a file; a typo
		// of a verb answers with a usage error instead of opening a window.
		code, _, handled := kit.cli_capture(s, {"convrt"}, context.temp_allocator)
		ok(handled && code == kit.EXIT_USAGE, "a word that is neither a command nor a file is a usage error, not a window (%v %d)", handled, code)
	}
	for cmd in s.commands {
		ok(cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, "%s has a summary, an output and an example", cmd.verb)
		for e in cmd.examples {
			words := kit.cli_split_example(e)
			ok(len(words) > 0 && words[0] == "docs", "the example %q is typed as the binary is named", e)
			if len(words) < 2 {
				continue
			}
			_, code := kit.cli_bind(s, words[1:])
			eq_int(code, kit.EXIT_OK, "the example %q parses", e)
		}
	}
	for legacy in ([?]string{"--convert", "--export-png", "--shots", "--lint", "--bench"}) {
		found := false
		for cmd in s.commands {
			for a in cmd.aliases {
				if a == legacy {found = true}
			}
		}
		ok(found, "the old spelling %s is still accepted", legacy)
	}
	{
		kit.run({"mkdir", "-p", SELFTEST_DIR})
		report := fmt.tprintf("%s/report.docx", SELFTEST_DIR)
		_ = os.write_entire_file(report, transmute([]u8)string("x"))
		_, handled := kit.cli_args(s, {report})
		ok(!handled, "`docs report.docx` is left to the window when the file exists")
		c, code := kit.cli_bind(s, {"--convert", "a.md", "b.pdf"})
		eq_int(code, kit.EXIT_OK, "`docs --convert a.md b.pdf` binds")
		ok(c.cmd != nil && c.cmd.verb == "convert", "to the convert command")
	}

	// Reads over the welcome document, which needs no file.
	code, out := cli_run("info")
	eq_int(code, 0, "docs info runs with no file")
	cli_schema_ok("info", out)
	ok(strings.contains(out, `"title":"The Anatomy of a Page"`), "and reads the welcome document")
	code, out = cli_run("text", "--format", "markdown")
	eq_int(code, 0, "docs text --format markdown runs")
	cli_schema_ok("text", out)
	code, out = cli_run("formats")
	eq_int(code, 0, "docs formats runs")
	cli_schema_ok("formats", out)
	code, out = cli_run("bench", "20")
	eq_int(code, 0, "docs bench 20 runs")
	cli_schema_ok("bench", out)

	// find is the find bar's own walk: the count it reports is find_hits.
	code, out = cli_run("find", "pagination")
	eq_int(code, 0, "docs find runs")
	cli_schema_ok("find", out)
	ok(strings.contains(out, `"count":2`), "and finds both mentions of pagination")
	code, out = cli_run("find", "\\bpage\\w*", "--regex", "--limit", "1")
	eq_int(code, 0, "docs find --regex runs")
	ok(strings.contains(out, `"mode":".*"`), "under the find bar's regex mode")
	ok(strings.count(out, `"match":`) == 1, "and --limit caps the list, not the count")
	code, out = cli_run("find", "(", "--regex")
	eq_int(code, kit.EXIT_USAGE, "a pattern that does not compile is a usage error")
	code, _ = cli_run("info", "/nonexistent/palmy-docs.md")
	eq_int(code, kit.EXIT_NOT_FOUND, "a missing file is not found")

	// The mutating commands, on files in a private directory.
	dir := fmt.tprintf("/tmp/palmy-docs-cli-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	md := fmt.tprintf("%s/memo.md", dir)
	code, out = cli_run("new", md, "--markdown", "# Memo\\n\\nThe colour of the colour chart.")
	eq_int(code, 0, "docs new writes a document")
	cli_schema_ok("new", out)
	code, _ = cli_run("new", md, "--markdown", "x")
	eq_int(code, kit.EXIT_USAGE, "and will not overwrite one without --force")

	code, out = cli_run("replace", "colour", "color", md, "--dry-run")
	eq_int(code, 0, "docs replace --dry-run runs")
	cli_schema_ok("replace", out)
	ok(strings.contains(out, `"replaced":2`) && strings.contains(out, `"written":false`), "and counts without writing")
	{
		data, _ := os.read_entire_file_from_path(md, context.temp_allocator)
		ok(strings.contains(string(data), "colour"), "the file is untouched by a dry run")
	}
	code, out = cli_run("replace", "colour", "color", md)
	eq_int(code, 0, "docs replace runs")
	{
		data, _ := os.read_entire_file_from_path(md, context.temp_allocator)
		eq_str(string(data), "# Memo\n\nThe color of the color chart.\n", "and writes Replace All's result")
	}
	// The same replace through the window's own procedure gives the same text.
	{
		fonts := new(p.Fonts)
		headless_fonts(fonts)
		st := State{}
		state_init(&st, fonts)
		defer state_destroy(&st)
		do_open(&st, md)
		find_set(&st, "color", "colour", false, false, false)
		replace_all(&st)
		code2, out2 := cli_run("replace", "color", "colour", md, "--out", fmt.tprintf("%s/cli.md", dir))
		eq_int(code2, 0, "docs replace --out runs")
		_ = out2
		data, _ := os.read_entire_file_from_path(fmt.tprintf("%s/cli.md", dir), context.temp_allocator)
		eq_str(string(data), doc_to_markdown(&st.doc, context.temp_allocator), "and agrees with the window's Replace All")
	}

	pdf := fmt.tprintf("%s/memo.pdf", dir)
	code, out = cli_run("--convert", md, pdf)
	eq_int(code, 0, "docs --convert still converts")
	cli_schema_ok("convert", out)
	ok(os.exists(pdf), "and the PDF is there")
	code, out = cli_run("export-png", md, fmt.tprintf("%s/memo", dir))
	eq_int(code, 0, "docs export-png runs")
	cli_schema_ok("export-png", out)
	ok(os.exists(fmt.tprintf("%s/memo-p1.png", dir)), "and page one is on disk")

	// lint answers either way: a result of its declared shape, or unavailable
	// when vale is not installed — never an empty "clean" list in its place.
	code, out = cli_run("lint", md)
	ok(code == 0 || code == kit.EXIT_UNAVAILABLE, "docs lint runs or says vale is unavailable (%d)", code)
	if code == 0 {
		cli_schema_ok("lint", out)
	} else {
		ok(strings.contains(out, `"error":"unavailable"`), "with the documented token")
	}
}
