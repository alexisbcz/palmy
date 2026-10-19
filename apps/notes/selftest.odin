// `notes --selftest` checks the parts that have no pixels: the store, the
// Markdown parser, the soft-wrap arithmetic and the buffer underneath both.
//
// It runs against a scratch directory under /tmp and never looks at
// ~/.local/share/palmy-notes, so running the tests cannot touch real notes.
//
// The wrap tests do need text measurement, so they borrow palmy's offscreen
// renderer for a font-loaded context. No compositor is involved.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import prose "../prose"

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

check_int :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s: got %d, want %d", what, got, want)
	}
}

check_eq :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s\n        got  %q\n        want %q", what, got, want)
	}
}

whole :: proc(b: ^Buffer) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< buf_lines(b) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(b, i))
	}
	return strings.to_string(sb)
}

load_text :: proc(b: ^Buffer, text: string) {
	buf_init_empty(b)
	buf_apply(b, {0, 0}, {0, 0}, text, {0, 0}, .No)
	clear(&b.undo)
	b.save_mark = 0
}

run_selftest :: proc() {
	test_titles()
	test_slugs()
	test_search()
	test_store()
	test_markdown_blocks()
	test_markdown_inline()
	test_list_continue()
	test_buffer()
	test_wrap()
	test_prose()
	test_cli()
	run_selftest_sync()

	if failures == 0 {
		fmt.printfln("notes selftest: %d checks passed", checks)
	} else {
		fmt.printfln("notes selftest: %d checks, %d FAILED", checks, failures)
	}
}

// ---------------------------------------------------------------------------

test_titles :: proc() {
	check_eq(title_of("# Shopping list\n\nmilk", context.temp_allocator), "Shopping list", "a heading is the title")
	check_eq(title_of("Plain first line\nmore", context.temp_allocator), "Plain first line", "a plain first line is the title")
	check_eq(title_of("\n\n   \n### Third\n", context.temp_allocator), "Third", "blank lines are skipped")
	check_eq(title_of("> quoted\n", context.temp_allocator), "quoted", "a quote mark is stripped")
	check_eq(title_of("", context.temp_allocator), "Untitled note", "an empty note still has a title")
	check_eq(title_of("#\n#\nreal\n", context.temp_allocator), "real", "a bare hash is not a title")
	check(len(title_of(strings.repeat("x", 200, context.temp_allocator), context.temp_allocator)) == 80, "a very long title is cut")

	body := "# Title\n\nThe second line of prose.\nthird"
	check_eq(preview_of(body, "Title", context.temp_allocator), "The second line of prose.", "the preview is the next line of text")
	check_eq(preview_of("# Only a title\n", "x", context.temp_allocator), "", "a note with nothing else has no preview")

	check(word_count("one two  three\nfour") == 4, "words are counted across lines")
	check(word_count("") == 0, "an empty note has no words")
	check(word_count("   \n\t ") == 0, "whitespace alone is no words")
}

test_slugs :: proc() {
	check_eq(slug("Shopping list", context.temp_allocator), "shopping-list", "a title becomes a file name")
	check_eq(slug("  Spaces   everywhere  ", context.temp_allocator), "spaces-everywhere", "runs of spaces collapse")
	check_eq(slug("Odin & palmy: notes!", context.temp_allocator), "odin-palmy-notes", "punctuation becomes separators")
	check_eq(slug("", context.temp_allocator), "untitled", "an empty title has a fallback")
	check_eq(slug("!!!", context.temp_allocator), "untitled", "so does a title of only punctuation")
	check_eq(slug("2026 Plans", context.temp_allocator), "2026-plans", "digits survive")
	check(len(slug(strings.repeat("word ", 40, context.temp_allocator), context.temp_allocator)) <= 48, "a long title makes a short file name")
}

test_search :: proc() {
	check(contains_fold("The Quick Brown", "quick"), "search folds case")
	check(contains_fold("abc", ""), "an empty query matches everything")
	check(!contains_fold("abc", "abcd"), "a query longer than the text does not match")
	check(contains_fold("abc", "abc"), "an exact match matches")
	check(!contains_fold("abc", "xyz"), "a miss is a miss")

	body := "# Title\n\nsomething about LEAP years\nand more"
	check_eq(match_line(body, "leap", context.temp_allocator), "something about LEAP years", "the matching line is reported")
	check_eq(match_line(body, "nothing", context.temp_allocator), "", "no match, no line")
	check_eq(match_line(body, "", context.temp_allocator), "", "no query, no line")
}

test_store :: proc() {
	dir := "/tmp/palmy-notes-selftest"
	if !os.is_dir(dir) {
		os.make_directory(dir)
	}
	// Start from empty, whatever a previous run left behind.
	if h, e := os.open(dir); e == nil {
		infos, _ := os.read_dir(h, -1, context.temp_allocator)
		for info in infos {
			os.remove(fmt.tprintf("%s/%s", dir, info.name))
		}
		os.close(h)
	}

	first, ok1 := store_create(dir)
	check(ok1, "a note is created")
	check(strings.has_suffix(first, "new-note.md"), "and named from its first line")

	second, ok2 := store_create(dir)
	check(ok2 && second != first, "a second note does not overwrite the first")
	check(strings.has_suffix(second, "new-note-2.md"), "it gets a counter instead")

	// Writing a new title renames the file to match.
	renamed, okw := store_write(dir, first, "# Shopping list\n\nmilk\n")
	check(okw, "a note is written")
	check(strings.has_suffix(renamed, "shopping-list.md"), "and the file follows the title")
	check(!os.exists(first), "the old name is gone")
	check(os.exists(renamed), "the new name is there")

	// Writing again with the same title keeps the same file.
	again, _ := store_write(dir, renamed, "# Shopping list\n\nmilk\nbread\n")
	check_eq(again, renamed, "an unchanged title keeps the file name")

	notes := store_load(dir)
	check(len(notes) == 2, "both notes are loaded back")
	found := false
	for n in notes {
		if n.title == "Shopping list" {
			found = true
			check(strings.contains(n.body, "bread"), "the latest text is what was loaded")
			check(n.words == 5, "the word count is from the file, hash included")
		}
	}
	check(found, "the renamed note is in the list")

	check(store_delete(renamed), "a note is deleted")
	check(!os.exists(renamed), "and the file is gone")
	check(!store_delete("/tmp/palmy-notes-selftest/not-a-note.txt"), "only .md files are deleted")

	store_delete(second)
}

test_markdown_blocks :: proc() {
	src := "# One\n## Two\n### Three\ntext\n- bullet\n* star\n1. first\n> quote\n---\n- [ ] todo\n- [x] done\n\n```\ncode\n```\n"
	b := md_blocks(src)
	kinds := make([dynamic]Block_Kind, 0, 32, context.temp_allocator)
	for blk in b {
		append(&kinds, blk.kind)
	}
	want := [?]Block_Kind {
		.H1,
		.H2,
		.H3,
		.Para,
		.Bullet,
		.Bullet,
		.Number,
		.Quote,
		.Rule,
		.Check_Off,
		.Check_On,
		.Blank,
		.Code,
	}
	check(len(kinds) == len(want), "every line became one block")
	same := len(kinds) == len(want)
	if same {
		for k, i in want {
			if kinds[i] != k {
				same = false
				fmt.printfln("        block %d is %v, expected %v", i, kinds[i], k)
			}
		}
	}
	check(same, "each line was classified correctly")

	check_eq(b[0].text, "One", "a heading keeps its text and loses its marks")
	check_eq(b[6].marker, "1.", "an ordered item keeps its marker")
	check_eq(b[6].text, "first", "and its text")
	check_eq(b[9].text, "todo", "an unticked task keeps its text")

	// Inside a fence, Markdown means nothing.
	fenced := md_blocks("```\n# not a heading\n- not a bullet\n```\n")
	check(len(fenced) == 2 && fenced[0].kind == .Code && fenced[1].kind == .Code, "a fenced block is all code")
	check(!is_ordered("1x item"), "a digit without a dot is not a list")
	check(is_ordered("12. item"), "a two-digit list marker is a list")
}

span_text :: proc(spans: []Span, i: int) -> string {
	return i < len(spans) ? spans[i].text : "<none>"
}

test_markdown_inline :: proc() {
	s := md_spans("plain **bold** and *em* and `code`", context.temp_allocator)
	check(len(s) == 6, "the line split into six runs")
	check(s[0].text == "plain " && !s[0].bold, "the leading text is plain")
	check(s[1].text == "bold" && s[1].bold, "the bold run is marked bold")
	check(s[3].text == "em" && s[3].em, "the emphasis run is marked")
	check(s[5].text == "code" && s[5].code, "the code run is marked")

	esc := md_spans("a \\*not emphasis\\* b", context.temp_allocator)
	check(len(esc) == 1 && strings.contains(esc[0].text, "*not emphasis*"), "a backslash escapes a mark")

	snake := md_spans("call some_function_name now", context.temp_allocator)
	check(len(snake) == 1, "underscores inside a word are not emphasis")

	link := md_spans("see [the docs](https://x) now", context.temp_allocator)
	check(len(link) == 3 && link[1].link && link[1].text == "the docs", "a link keeps its label")

	// The glue rule: punctuation after a styled run belongs to the same word.
	atoms := md_atoms(md_spans("**Bold**, *em* and `code`", context.temp_allocator), context.temp_allocator)
	check(len(atoms) >= 2, "the line produced atoms")
	check(atoms[0].span.text == "Bold" && !atoms[0].glued, "the first word starts a group")
	check(atoms[1].span.text == "," && atoms[1].glued, "the comma is glued to the word before it")
	// "and" follows a space, so it must not be glued.
	and_at := -1
	for a, i in atoms {
		if a.span.text == "and" {
			and_at = i
		}
	}
	check(and_at >= 0 && !atoms[and_at].glued, "a word after a space is not glued")
	check(atoms[len(atoms) - 1].span.code, "inline code stays one atom")

	single := md_atoms(md_spans("one two three", context.temp_allocator), context.temp_allocator)
	check(len(single) == 3, "a plain line is one atom per word")
	check(!single[1].glued && !single[2].glued, "and none of them are glued")
}

test_list_continue :: proc() {
	pre, clear_it := list_continue("- an item", 9)
	check_eq(pre, "- ", "Return inside a bullet continues the bullet")
	check(!clear_it, "and does not clear it")

	pre, clear_it = list_continue("- ", 2)
	check(clear_it, "Return on an empty bullet ends the list")

	pre, _ = list_continue("- [ ] a task", 12)
	check_eq(pre, "- [ ] ", "a task list continues with an empty box")

	pre, _ = list_continue("- [x] a done task", 17)
	check_eq(pre, "- [ ] ", "a ticked task continues with an empty box, not a ticked one")

	pre, _ = list_continue("3. third", 8)
	check_eq(pre, "4. ", "a numbered list counts on")

	pre, _ = list_continue("  - indented", 12)
	check_eq(pre, "  - ", "indentation is carried too")

	pre, clear_it = list_continue("- an item", 0)
	check_eq(pre, "", "Return before the marker splits the line instead")
	check(!clear_it, "and does not clear it either")

	pre, _ = list_continue("    indented prose", 18)
	check_eq(pre, "    ", "plain text carries its indentation")

	pre, _ = list_continue("no list here", 5)
	check_eq(pre, "", "and unindented text carries nothing")

	pre, _ = list_continue("> quoted", 8)
	check_eq(pre, "> ", "a quote continues as a quote")
}

test_buffer :: proc() {
	b := Buffer{}
	load_text(&b, "one\ntwo\nthree")
	check(buf_lines(&b) == 3, "three lines loaded")
	buf_apply(&b, {1, 0}, {1, 3}, "TWO", {1, 0}, .No)
	check_eq(whole(&b), "one\nTWO\nthree", "a replacement inside a line")
	buf_apply(&b, {0, 3}, {1, 0}, "", {0, 3}, .No)
	check_eq(whole(&b), "oneTWO\nthree", "a delete across a newline joins")
	cur, ok := buf_undo(&b)
	check(ok && whole(&b) == "one\nTWO\nthree", "undo puts the newline back")
	_ = cur

	load_text(&b, "")
	cur2 := Pos{0, 0}
	for ch in ([?]string{"h", "i", "!"}) {
		cur2 = buf_apply(&b, cur2, cur2, ch, cur2, .Type)
	}
	check_eq(whole(&b), "hi!", "typing into an empty note")
	check(len(b.undo) == 1, "and it is one undo step")
}

test_wrap :: proc() {
	// Text measurement needs a font, which needs a context; the offscreen
	// renderer provides one without a compositor.
	off := p.offscreen_create(900, 600)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)

	b := Buffer{}
	load_text(
		&b,
		"a short line\n" +
		"the quick brown fox jumps over the lazy dog and keeps going for a good while longer than one line can hold\n" +
		"\n" +
		"last",
	)

	w := Wrapper{}
	wrap_rebuild(&w, ui, &b, 240, 1)
	check(len(w.rows) > 4, "the long line wrapped into several rows")

	// Every row must fit, except one made of a single over-wide word.
	all_fit := true
	for r in w.rows {
		src := buf_line(&b, r.line)
		if r.to > r.from && text_w(ui, src[r.from:r.to]) > 244 {
			all_fit = false
		}
	}
	check(all_fit, "no wrapped row is wider than the column")

	// The rows have to cover the text exactly, with no byte lost or repeated.
	covered := true
	for li in 0 ..< buf_lines(&b) {
		want := 0
		seen := -1
		for r in w.rows {
			if r.line != li {
				continue
			}
			if seen < 0 {
				covered = covered && r.from == 0
			}
			seen = r.to
			want += 1
		}
		covered = covered && want >= 1 && seen == len(buf_line(&b, li))
	}
	check(covered, "the rows cover every line from its start to its end")

	// An empty line still gets a row, or the caret cannot sit on it.
	empty_rows := 0
	for r in w.rows {
		if r.line == 2 {
			empty_rows += 1
		}
	}
	check(empty_rows == 1, "an empty line is exactly one row")

	// row_of and caret_x have to agree with col_at, in both directions.
	first := Pos{0, 0}
	check(row_of(&w, first) == 0, "the first position is on the first row")
	check(caret_x(&w, ui, &b, first) == 0, "and its caret is at zero")

	mid := Pos{0, 5}
	x := caret_x(&w, ui, &b, mid)
	check(x > 0, "a caret further along the line is further right")
	back := col_at(&w, ui, &b, row_of(&w, mid), x)
	check(pos_eq(back, mid), "col_at inverts caret_x")

	// Walking down a wrapped paragraph and back up returns to the same column.
	start := Pos{1, 30}
	r0 := row_of(&w, start)
	gx := caret_x(&w, ui, &b, start)
	down := col_at(&w, ui, &b, r0 + 1, gx)
	up := col_at(&w, ui, &b, r0, gx)
	check(pos_eq(up, start), "down then up with the same goal returns to the start")
	check(down.line == 1 || down.line == 2, "down lands on the next visual row")

	// Re-wrapping at the same width and revision must be a no-op.
	n := len(w.rows)
	wrap_rebuild(&w, ui, &b, 240, 1)
	check(len(w.rows) == n, "re-wrapping with nothing changed does nothing")
	wrap_rebuild(&w, ui, &b, 600, 1)
	check(len(w.rows) < n, "a wider column needs fewer rows")

	p.offscreen_end(off)
}


// ---------------------------------------------------------------------------
// The writing coach
// ---------------------------------------------------------------------------
//
// The engine has its own suite (`prose --selftest`, 380 checks). What is
// asserted here is only what the *application* adds: that an alert's offsets
// land on the right bytes of the line-array buffer, that accepting a
// suggestion goes through the undo stack rather than around it, and that
// picking a different style changes what is flagged.

PROSE_SAMPLE :: `# Quarterly update

We will utilize the synergy going forward in order to leverage our core
competencies, and it is my understanding that a decision was taken.

- Obviously we should just run the migration
- The the plan is clearly very simple

` + "```" + `
utilize(very, really);
` + "```" + `

See http://example.com/utilize/very for the proposal.
`

test_prose :: proc() {
	// Text measurement is not needed, but `touch` and `prose_touch` want a
	// context for the clock, and the offscreen renderer provides one with no
	// compositor involved.
	off := p.offscreen_create(900, 600)
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)
	defer p.offscreen_end(off)

	nt := Notes{}
	nt.dir = strings.clone("/tmp/palmy-notes-selftest-prose")
	defer delete(nt.dir)
	if !os.is_dir(nt.dir) {
		os.make_directory(nt.dir)
	}
	// Start from a clean slate so a previous run's prose.conf cannot change
	// what this one sees.
	os.remove(fmt.tprintf("%s/%s", nt.dir, PROSE_CONF))
	buf_init_empty(&nt.buf)
	load_text(&nt.buf, PROSE_SAMPLE)
	nt.open_path = strings.clone(fmt.tprintf("%s/quarterly-update.md", nt.dir))
	defer delete(nt.open_path)

	prose_init(&nt)
	defer prose_destroy(&nt)
	check(nt.pr.ready, "the engine loaded")
	check(len(nt.pr.eng.errors) == 0, "every shipped rule file compiled")
	check(len(nt.pr.eng.packs) == 6, "six style packs are available")

	// --- offsets ---------------------------------------------------------
	check_int(doc_offset(&nt, Pos{0, 0}), 0, "the first position is offset zero")
	for li in 0 ..< buf_lines(&nt.buf) {
		off2 := doc_offset(&nt, Pos{li, 0})
		back := doc_pos(&nt, off2)
		checks += 1
		if back.line != li || back.col != 0 {
			failures += 1
			fmt.printfln("  FAIL  doc_pos(doc_offset(line %d)) = %v", li, back)
		}
	}

	// --- a full pass -----------------------------------------------------
	set_style :: proc(nt: ^Notes, name: string) -> int {
		i := prose.pack_index(&nt.pr.eng, name)
		nt.pr.style = max(0, i)
		prose_invalidate(nil, nt)
		prose_force(nt)
		return len(nt.pr.alerts)
	}

	n_business := set_style(&nt, "Business")
	check(n_business > 3, "Business finds several issues in the sample")

	// Every alert's span has to name the bytes it claims to, or the marks sit
	// under the wrong words and an accepted suggestion eats the wrong text.
	text := note_text(&nt, context.temp_allocator)
	bad := 0
	for a in nt.pr.alerts {
		if a.from < 0 || a.to > len(text) || a.to <= a.from {
			bad += 1
			continue
		}
		if a.match != text[a.from:a.to] {
			bad += 1
			fmt.printfln("  FAIL  %s claims %q but the note has %q", a.rule, a.match, text[a.from:a.to])
		}
	}
	check_int(bad, 0, "every alert's span is exactly the text it reports")

	// --- nothing fires in code or a URL ----------------------------------
	fence := strings.index(text, "```")
	url := strings.index(text, "http://")
	check(fence > 0 && url > 0, "the sample has a code fence and a URL")
	fence_end := strings.index(text[fence + 3:], "```") + fence + 6
	for pack in ([?]string{"Plain", "Business", "Academic", "Journalistic", "Inclusive", "Concise"}) {
		set_style(&nt, pack)
		inside := 0
		for a in nt.pr.alerts {
			if a.from >= fence && a.to <= fence_end {
				inside += 1
				fmt.printfln("  FAIL  %s fired inside the code fence: %q", a.rule, a.match)
			}
			if a.from >= url && a.from < url + 36 {
				inside += 1
				fmt.printfln("  FAIL  %s fired inside the URL: %q", a.rule, a.match)
			}
		}
		check_int(inside, 0, fmt.tprintf("%s fires nothing in code or a URL", pack))
	}

	// --- picking a style changes what is flagged -------------------------
	names_for :: proc(nt: ^Notes, allocator := context.temp_allocator) -> string {
		sb := strings.builder_make(allocator)
		for a in nt.pr.alerts {
			strings.write_string(&sb, a.rule)
			strings.write_byte(&sb, ' ')
		}
		return strings.to_string(sb)
	}
	set_style(&nt, "Business")
	biz := strings.clone(names_for(&nt), context.temp_allocator)
	nbiz := len(nt.pr.alerts)
	set_style(&nt, "Concise")
	con := strings.clone(names_for(&nt), context.temp_allocator)
	ncon := len(nt.pr.alerts)
	check(nbiz > 0 && ncon > 0, "both packs flag something")
	check(biz != con, "switching style packs changes the alert set")
	check(
		strings.contains(biz, "Business.Buzzwords") && !strings.contains(con, "Business"),
		"and the rules that fired come from the pack that was picked",
	)
	set_style(&nt, "Inclusive")
	check(len(nt.pr.alerts) != nbiz || names_for(&nt) != biz, "a third pack differs again")

	// --- accepting a suggestion goes through the undo stack --------------
	set_style(&nt, "Business")
	before := strings.clone(note_text(&nt, context.temp_allocator), context.temp_allocator)
	undo_before := len(nt.buf.undo)

	pick := -1
	for a, i in nt.pr.alerts {
		if a.has_fix && a.fix != "" {
			pick = i
			break
		}
	}
	check(pick >= 0, "at least one issue offers a concrete rewrite")
	if pick >= 0 {
		a := nt.pr.alerts[pick]
		nt.pr.mark = pick
		nt.cur = doc_pos(&nt, a.from)
		prose_apply(ui, &nt)

		after := note_text(&nt, context.temp_allocator)
		check(after != before, "applying the suggestion changed the note")
		check(strings.contains(after, a.fix), "the replacement is in the text")
		check_int(len(nt.buf.undo), undo_before + 1, "it added exactly one undo entry")

		cur, ok := buf_undo(&nt.buf)
		check(ok, "and Ctrl-Z has something to undo")
		_ = cur
		check_eq(
			note_text(&nt, context.temp_allocator),
			before,
			"undo restores the note byte for byte",
		)
		// Redo puts it back, which is the other half of being on the stack.
		cur2, ok2 := buf_redo(&nt.buf)
		check(ok2, "and redo has something to redo")
		_ = cur2
		check(strings.contains(note_text(&nt, context.temp_allocator), a.fix), "redo re-applies it")
		buf_undo(&nt.buf)
	}

	// --- the paragraph pass agrees with the full pass ---------------------
	// This is the whole basis for re-reading one paragraph per keystroke.
	set_style(&nt, "Concise")
	full_names := strings.clone(names_for(&nt), context.temp_allocator)
	full_n := len(nt.pr.alerts)
	para := strings.index(text, "- Obviously")
	nt.pr.doc_len = len(note_text(&nt, context.temp_allocator))
	nt.pr.win_from = para
	nt.pr.win_to = para + 10
	nt.pr.dirty = true
	prose_tick_now(&nt)
	check_int(len(nt.pr.alerts), full_n, "a window pass leaves the alert count unchanged")
	check_eq(names_for(&nt), full_names, "and the same rules in the same order")

	// --- dismissing ------------------------------------------------------
	set_style(&nt, "Concise")
	n_all := len(nt.pr.alerts)
	if n_all > 0 {
		nt.pr.mark = 0
		dropped := strings.clone(nt.pr.alerts[0].rule, context.temp_allocator)
		prose_dismiss(ui, &nt, true)
		check(len(nt.pr.alerts) < n_all, "dismissing a rule removes its marks")
		still := false
		for a in nt.pr.alerts {
			if a.rule == dropped {
				still = true
			}
		}
		check(!still, "and it stops firing")

		// It survives a restart: the settings live beside the notes.
		nt2 := Notes{}
		nt2.dir = strings.clone(nt.dir)
		defer delete(nt2.dir)
		nt2.open_path = strings.clone(nt.open_path)
		defer delete(nt2.open_path)
		buf_init_empty(&nt2.buf)
		load_text(&nt2.buf, PROSE_SAMPLE)
		prose_init(&nt2)
		defer prose_destroy(&nt2)
		found := false
		for d in nt2.pr.dismissed {
			if d == dropped {
				found = true
			}
		}
		check(found, "the dismissal is still there after a restart")

		prose_undismiss_all(ui, &nt)
		check_int(len(nt.pr.alerts), n_all, "restoring brings every rule back")

		// The same, for one note only.
		nt.pr.mark = 0
		only_here := strings.clone(nt.pr.alerts[0].rule, context.temp_allocator)
		prose_dismiss(ui, &nt, false)
		check(len(nt.pr.alerts) < n_all, "a note-local dismissal removes its marks too")
		prose_conf_apply_note(&nt)
		found_local := false
		for d in nt.pr.note_dismissed {
			if d == only_here {
				found_local = true
			}
		}
		check(found_local, "and is written against this note's file name")
		prose_undismiss_all(ui, &nt)
	}

	// --- a per-note style overrides the global one, and only for that note -
	{
		prose_set_style(ui, &nt, prose.pack_index(&nt.pr.eng, "Plain"), false)
		check_eq(prose_style_name(&nt), "Plain", "the global style is Plain")
		prose_set_style(ui, &nt, prose.pack_index(&nt.pr.eng, "Academic"), true)
		check_eq(prose_style_name(&nt), "Academic", "this note is Academic")
		// Opening a note with no style of its own falls back to the global
		// one rather than inheriting the previous note's.
		other := strings.clone(nt.open_path, context.temp_allocator)
		delete(nt.open_path)
		nt.open_path = strings.clone(fmt.tprintf("%s/another.md", nt.dir))
		prose_conf_apply_note(&nt)
		check_eq(prose_style_name(&nt), "Plain", "another note falls back to the global style")
		delete(nt.open_path)
		nt.open_path = strings.clone(other)
		prose_conf_apply_note(&nt)
		check_eq(prose_style_name(&nt), "Academic", "and the first note keeps its own")
		prose_set_style(ui, &nt, prose.pack_index(&nt.pr.eng, "Business"), false)
	}

	// --- the report ------------------------------------------------------
	set_style(&nt, "Business")
	check(nt.pr.have_report, "a full pass produces a report")
	rp := &nt.pr.report
	check(rp.words > 40, "which counts the words")
	check(rp.sentences > 2, "and the sentences")
	check(rp.grade_ok, "and produces a grade")
	check(strings.contains(prose.band(rp.grade_mean), " "), "a grade always arrives with a band")
	check(rp.caveat != "", "and the caveat travels with it")
	check(len(rp.issues) > 0, "the recurring-issue tally is not empty")

	// --- off means off ---------------------------------------------------
	prose_toggle(ui, &nt)
	check(!nt.pr.on, "the checks can be switched off")
	check_int(len(nt.pr.alerts), 0, "and every mark goes with them")
	prose_toggle(ui, &nt)
	check(nt.pr.on && len(nt.pr.alerts) > 0, "and come back")

	os.remove(fmt.tprintf("%s/%s", nt.dir, PROSE_CONF))
}

// ---------------------------------------------------------------------------
// The command surface
//
// Notes had an engine and no command line. These assertions are what says the
// command line is the *same* engine rather than a second one that will drift:
// every command runs the store procedures the window runs, so a note written
// by `notes write` is a note the window can open, with the same title rule and
// the same file name.
//
// They drive the real binary as a child process, with $PALMY_NOTES_DIR
// pointing at a scratch notebook, because `notes delete` is only honestly
// testable against files it may really remove.
// ---------------------------------------------------------------------------

cli_self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// cli_run runs this binary again against the scratch notebook and hands back
// stdout and the exit code. The display variables are cleared so that a
// mistake in the dispatcher could never make a child open a window and hang
// the test run on it.
cli_run :: proc(dir: string, args: ..string) -> (out: string, code: int) {
	return cli_run_env(dir, {}, ..args)
}

cli_run_env :: proc(dir: string, env: []string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	strings.write_string(&line, fmt.tprintf("PALMY_NOTES_DIR=%q PALM_AUDIT=%q ", dir, fmt.tprintf("%s/audit.jsonl", dir)))
	for e in env {
		strings.write_string(&line, e)
		strings.write_byte(&line, ' ')
	}
	strings.write_string(&line, fmt.tprintf("%q", cli_self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec(
		{command = {"sh", "-c", strings.to_string(line)}},
		context.temp_allocator,
	)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

test_cli :: proc() {
	dir := fmt.tprintf("/tmp/palmy-notes-cli-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	sf := surface()

	// --- the declaration -------------------------------------------------
	check(sf.noun == "notes", "the surface is named notes")
	check(sf.selftest != nil, "--selftest is part of the declaration")
	destructive := 0
	for cmd in sf.commands {
		check(cmd.run != nil, tfmt("%s has an implementation", cmd.verb))
		check(cmd.summary != "", tfmt("%s has a summary", cmd.verb))
		check(len(cmd.out) > 0, tfmt("%s declares what it prints", cmd.verb))
		check(len(cmd.examples) > 0, tfmt("%s ships an example", cmd.verb))
		if cmd.effect == .Destructive {
			destructive += 1
		}
	}
	check_int(destructive, 1, "exactly one command is destructive")

	// --- every example parses --------------------------------------------
	for cmd in sf.commands {
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(words[0] == "notes", tfmt("the example %q starts with the noun", ex))
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(dir, ..args[:])
			check_int(code, 0, tfmt("the example %q parses", ex))
		}
	}

	// --- an empty notebook is an empty list, not an error -----------------
	{
		out, code := cli_run(dir, "list", "--json")
		check_int(code, 0, "list on an empty notebook exits 0")
		problems := kit.cli_validate_output(out, LIST_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "and matches its declared schema")
		check(strings.contains(out, `"count": 0`), "with nothing in it")
	}

	// --- write, read, and the window's own store agree --------------------
	{
		out, code := cli_run(dir, "write", "groceries", "--text", "# Groceries\\n\\n- milk\\n- eggs", "--json")
		check_int(code, 0, "write exits 0")
		problems := kit.cli_validate_output(out, WROTE_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "write matches its declared schema")
		check(strings.contains(out, `"title": "Groceries"`), "the title comes from the first line")
		check(strings.contains(out, "groceries.md"), "and the file is named after it")
		check(strings.contains(out, `"created": true`), "and it says the note is new")

		// The file on disk is a note the window would load, with the same
		// title and the same word count the engine computes.
		all := store_load(dir)
		check_int(len(all), 1, "the window's own store sees exactly one note")
		if len(all) == 1 {
			check_eq(all[0].title, "Groceries", "and reads the same title")
			check(strings.contains(all[0].body, "- eggs"), "and the same text")
		}
	}
	{
		out, code := cli_run(dir, "read", "groceries", "--json")
		check_int(code, 0, "read exits 0")
		problems := kit.cli_validate_output(out, READ_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "read matches its declared schema")
		check(strings.contains(out, "- milk"), "and hands back the text")
	}
	{
		// A title, a slug and a prefix all find the same note.
		_, by_title := cli_run(dir, "read", "Groceries", "--json")
		check_int(by_title, 0, "a note is found by its title")
		_, by_prefix := cli_run(dir, "read", "groc", "--json")
		check_int(by_prefix, 0, "and by an unambiguous prefix of it")
		_, by_path := cli_run(dir, "read", fmt.tprintf("%s/groceries.md", dir), "--json")
		check_int(by_path, 0, "and by its path")
	}

	// --- append and rename ------------------------------------------------
	{
		_, code := cli_run(dir, "append", "groceries", "--text", "- bread", "--json")
		check_int(code, 0, "append exits 0")
		n, found := store_load(dir)[0], true
		_ = found
		check(strings.contains(n.body, "- bread"), "and the line is in the file")
	}
	{
		out, code := cli_run(dir, "rename", "groceries", "Shopping", "--json")
		check_int(code, 0, "rename exits 0")
		check(strings.contains(out, "shopping.md"), "and the file follows the title")
		check(!os.exists(fmt.tprintf("%s/groceries.md", dir)), "and the old file is gone")
	}

	// --- search ------------------------------------------------------------
	{
		out, code := cli_run(dir, "search", "bread", "--json")
		check_int(code, 0, "search exits 0")
		problems := kit.cli_validate_output(out, SEARCH_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "search matches its declared schema")
		check(strings.contains(out, `"count": 1`), "and finds the note")
		out2, _ := cli_run(dir, "search", "parsnips", "--json")
		check(strings.contains(out2, `"count": 0`), "and finds nothing when there is nothing")
	}

	// --- refusal rather than prompting -------------------------------------
	//
	// The one assertion that makes the destructive class mean something: the
	// command exits non-zero with a reason, leaves the note alone, and does
	// not block on a terminal read. It is run with stdin closed, so if it ever
	// tried to ask it would fail rather than wait.
	{
		out, code := cli_run(dir, "delete", "shopping", "--json")
		check_int(code, kit.EXIT_NEEDS_YES, "delete without --yes exits 4")
		check(strings.contains(out, `"error": "needs --yes"`), "with the documented token")
		check(strings.contains(out, `"effect": "destructive"`), "naming the class it refused on")
		check(os.exists(fmt.tprintf("%s/shopping.md", dir)), "and the note is still there")
	}
	{
		out, code := cli_run(dir, "delete", "shopping", "--yes", "--dry-run", "--json")
		check_int(code, 0, "a dry run of delete exits 0")
		check(strings.contains(out, `"deleted": false`), "and says it deleted nothing")
		check(os.exists(fmt.tprintf("%s/shopping.md", dir)), "and the note is still there")
	}
	{
		out, code := cli_run(dir, "delete", "shopping", "--yes", "--json")
		check_int(code, 0, "delete with --yes exits 0")
		check(strings.contains(out, `"deleted": true`), "and says so")
		check(!os.exists(fmt.tprintf("%s/shopping.md", dir)), "and the note is gone")
	}

	// --- the documented exit codes ------------------------------------------
	{
		_, code := cli_run(dir, "read", "nothing-like-this", "--json")
		check_int(code, kit.EXIT_NOT_FOUND, "reading a note that is not there exits 3")
	}
	{
		_, code := cli_run(dir, "scribble")
		check_int(code, kit.EXIT_USAGE, "an unknown command exits 2")
	}
	{
		_, code := cli_run(dir, "read")
		check_int(code, kit.EXIT_USAGE, "a missing required argument exits 2")
	}
	{
		_, code := cli_run(dir, "list", "--limit", "banana")
		check_int(code, kit.EXIT_USAGE, "a flag of the wrong type exits 2")
	}
	{
		_, code := cli_run_env(dir, {"PALM_IDENTITY=work"}, "list", "--identity", "personal", "--json")
		check_int(code, kit.EXIT_OUT_OF_SCOPE, "asking for another identity exits 5")
	}
	{
		_, code := cli_run(dir, "write", "x", "--text", "hi", "--json")
		check_int(code, 0, "write creates a note that was not there")
		_, bad := cli_run(dir, "write", "x")
		check_int(bad, kit.EXIT_USAGE, "and write with neither --text nor --file exits 2")
	}

	// --- --json means one document on stdout and nothing else ---------------
	for verb in ([?]string{"list", "path"}) {
		out, _ := cli_run(dir, verb, "--json")
		trimmed := strings.trim_space(out)
		check(strings.has_prefix(trimmed, "{"), tfmt("%s --json starts with the document", verb))
		check(strings.has_suffix(trimmed, "}"), tfmt("%s --json ends with it too", verb))
	}

	// --- the schema -----------------------------------------------------------
	{
		out, code := cli_run(dir, "--schema")
		check_int(code, 0, "--schema exits 0")
		for cmd in sf.commands {
			check(
				strings.contains(out, fmt.tprintf("\"verb\": %q", cmd.verb)),
				tfmt("the schema advertises %s", cmd.verb),
			)
		}
		check(strings.contains(out, `"effect": "destructive"`), "and says which command is destructive")
	}
}
