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
import p "palmy:."

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
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
