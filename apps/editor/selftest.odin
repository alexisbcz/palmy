// `editor --selftest` exercises the buffer, the undo stack and the tokeniser
// with no compositor and no window.
//
// The two things an editor must never get wrong are "what is in the buffer"
// and "what does undo put back", and neither is visible in a screenshot. So
// they are asserted here, on cases chosen because they are the ones that break:
// a multi-line insert, a delete that spans lines, an undo of a coalesced run of
// typing, a search that wraps, and a save that has to be byte-for-byte what was
// loaded.
package main

import "core:fmt"
import "core:os"
import "core:strings"

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

// whole joins the buffer back into one string, which is the only way to assert
// on the thing the user would actually see.
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
	test_positions()
	test_edits()
	test_undo()
	test_motion()
	test_search()
	test_display_columns()
	test_lexer()
	test_file_round_trip()

	if failures == 0 {
		fmt.printfln("editor selftest: %d checks passed", checks)
	} else {
		fmt.printfln("editor selftest: %d checks, %d FAILED", checks, failures)
	}
}

// ---------------------------------------------------------------------------

test_positions :: proc() {
	check(pos_eq(pos_advance({0, 0}, "abc"), {0, 3}), "advance stays on the line")
	check(pos_eq(pos_advance({2, 5}, "ab\ncd"), {3, 2}), "advance over one newline")
	check(pos_eq(pos_advance({0, 0}, "\n\n\n"), {3, 0}), "advance over three newlines")
	check(pos_less({1, 0}, {1, 1}), "pos_less compares columns")
	check(pos_less({0, 99}, {1, 0}), "pos_less compares lines first")

	b := Buffer{}
	load_text(&b, "héllo\nworld")
	check(pos_eq(pos_clamp(&b, {0, 2}), {0, 1}), "clamp steps out of a multi-byte rune")
	check(pos_eq(pos_clamp(&b, {9, 9}), {1, 5}), "clamp lands inside the buffer")
}

test_edits :: proc() {
	b := Buffer{}

	load_text(&b, "hello world")
	buf_apply(&b, {0, 5}, {0, 5}, ",", {0, 5}, .No)
	check_eq(whole(&b), "hello, world", "insert inside a line")

	load_text(&b, "hello world")
	buf_apply(&b, {0, 5}, {0, 11}, "", {0, 5}, .No)
	check_eq(whole(&b), "hello", "delete to the end of a line")

	load_text(&b, "ab")
	buf_apply(&b, {0, 1}, {0, 1}, "\n", {0, 1}, .No)
	check_eq(whole(&b), "a\nb", "a newline splits the line")
	check(buf_lines(&b) == 2, "the split produced two lines")

	load_text(&b, "a\nb")
	buf_apply(&b, {0, 1}, {1, 0}, "", {0, 1}, .No)
	check_eq(whole(&b), "ab", "deleting the newline joins the lines")

	load_text(&b, "one\nfour")
	end := buf_apply(&b, {0, 3}, {0, 3}, "\ntwo\nthree", {0, 3}, .No)
	check_eq(whole(&b), "one\ntwo\nthree\nfour", "a multi-line insert opens the gap in one go")
	check(pos_eq(end, {2, 5}), "a multi-line insert returns the end position")

	load_text(&b, "aaa\nbbb\nccc\nddd")
	buf_apply(&b, {0, 1}, {3, 2}, "X", {0, 1}, .No)
	check_eq(whole(&b), "aXd", "a delete spanning three lines joins what is left")

	load_text(&b, "abc\ndef\nghi")
	check_eq(buf_text(&b, {0, 1}, {2, 2}, context.temp_allocator), "bc\ndef\ngh", "buf_text spans lines")
	check_eq(buf_text(&b, {1, 0}, {1, 3}, context.temp_allocator), "def", "buf_text inside one line")
	check_eq(buf_text(&b, {1, 2}, {1, 2}, context.temp_allocator), "", "an empty range is empty text")

	// A paste big enough to matter: 500 lines into the middle of a file.
	load_text(&b, "head\ntail")
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 500 {
		strings.write_string(&sb, fmt.tprintf("\nline %d", i))
	}
	buf_apply(&b, {0, 4}, {0, 4}, strings.to_string(sb), {0, 4}, .No)
	check(buf_lines(&b) == 502, "a 500-line paste produced 502 lines")
	check_eq(buf_line(&b, 1), "line 0", "the first pasted line is in place")
	check_eq(buf_line(&b, 500), "line 499", "the last pasted line is in place")
	check_eq(buf_line(&b, 501), "tail", "the text after the caret survived the paste")
}

test_undo :: proc() {
	b := Buffer{}
	load_text(&b, "start")
	before := whole(&b)

	// Typing coalesces: five characters, one undo entry.
	cur := Pos{0, 5}
	for ch in ([?]string{"a", "b", "c", "d", "e"}) {
		cur = buf_apply(&b, cur, cur, ch, cur, .Type)
	}
	check_eq(whole(&b), "startabcde", "five keystrokes landed")
	check(len(b.undo) == 1, "a run of typing is one undo entry")
	check(buf_dirty(&b), "the buffer is dirty after typing")

	back, ok := buf_undo(&b)
	check(ok, "undo reported that it did something")
	check_eq(whole(&b), before, "one undo took back the whole run")
	check(pos_eq(back, {0, 5}), "undo restored the caret")
	check(!buf_dirty(&b), "undoing back to the save mark is clean again")

	again, rok := buf_redo(&b)
	check(rok, "redo reported that it did something")
	check_eq(whole(&b), "startabcde", "redo put the run back")
	check(pos_eq(again, {0, 10}), "redo restored the caret after the run")

	// Backspaces coalesce the other way.
	cur = Pos{0, 10}
	for _ in 0 ..< 3 {
		cur = buf_apply(&b, {0, cur.col - 1}, cur, "", cur, .Back)
	}
	check_eq(whole(&b), "startab", "three backspaces removed three characters")
	check(len(b.undo) == 2, "a run of backspaces is one more undo entry")
	buf_undo(&b)
	check_eq(whole(&b), "startabcde", "one undo took back the whole run of backspaces")

	// A new edit after an undo drops the redo branch.
	buf_undo(&b)
	check_eq(whole(&b), "start", "undone back to the beginning")
	buf_apply(&b, {0, 5}, {0, 5}, "!", {0, 5}, .No)
	check(len(b.redo) == 0, "a new edit throws the redo branch away")

	// Undo everything, twenty mixed edits deep, and check the text is the
	// text it started as.
	load_text(&b, "the quick brown fox\njumps over\nthe lazy dog")
	original := strings.clone(whole(&b), context.temp_allocator)
	c := Pos{0, 0}
	for i in 0 ..< 20 {
		switch i % 4 {
		case 0:
			c = buf_apply(&b, c, c, "X", c, .No)
		case 1:
			c = buf_apply(&b, c, c, "\nnew line", c, .No)
		case 2:
			c = buf_apply(&b, {0, 0}, {0, 1}, "", c, .No)
		case 3:
			c = buf_apply(&b, c, c, "   ", c, .Type)
		}
	}
	check(whole(&b) != original, "twenty edits changed the text")
	for {
		_, more := buf_undo(&b)
		if !more {
			break
		}
	}
	check_eq(whole(&b), original, "undoing twenty mixed edits restores the original exactly")
}

test_motion :: proc() {
	b := Buffer{}
	load_text(&b, "alpha beta_two  gamma(delta)")

	check(word_right(&b, {0, 0}).col == 6, "word right skips the word and the space after it")
	check(word_right(&b, {0, 6}).col == 16, "word right treats an underscore as part of the word")
	check(word_left(&b, {0, 16}).col == 6, "word left returns to the start of the word")
	check(word_left(&b, {0, 5}).col == 0, "word left from inside a word reaches its start")
	check(word_right(&b, {0, 16}).col == 21, "word right stops before punctuation")

	load_text(&b, "one\ntwo")
	check(pos_eq(word_right(&b, {0, 3}), {1, 0}), "word right crosses to the next line")
	check(pos_eq(word_left(&b, {1, 0}), {0, 3}), "word left crosses to the previous line")

	check(rune_left("héllo", 2) == 1, "rune_left steps over a two-byte rune")
	check(rune_right("héllo", 1) == 3, "rune_right steps over a two-byte rune")
}

test_search :: proc() {
	b := Buffer{}
	load_text(&b, "alpha\nBETA\nbeta gamma\nalpha")

	at, ok := buf_search(&b, "beta", {0, 0}, true)
	check(ok && at.line == 1 && at.col == 0, "a case-insensitive search finds BETA first")

	at, ok = buf_search(&b, "beta", {1, 1}, true)
	check(ok && at.line == 2 && at.col == 0, "searching on from a match finds the next one")

	at, ok = buf_search(&b, "alpha", {3, 1}, true)
	check(ok && at.line == 0, "a forward search wraps round the end")

	at, ok = buf_search(&b, "alpha", {2, 0}, true, true)
	check(ok && at.line == 0, "a backward search walks the other way")

	_, ok = buf_search(&b, "zzz", {0, 0}, true)
	check(!ok, "a search with no match says so")

	check(buf_count(&b, "beta", true) == 2, "the match count folds case")
	check(buf_count(&b, "beta", false) == 1, "a case-sensitive count does not")
	check(buf_count(&b, "a", true) == 8, "counting a single letter across every line")
	check(line_rfind("abcabc", "abc", 6, false) == 3, "rfind returns the last match before a limit")
	check(line_rfind("abcabc", "abc", 3, false) == 0, "rfind respects the limit")
}

test_display_columns :: proc() {
	// A tab is not one column, and a rune is not one byte. Everything the
	// caret does depends on these two agreeing.
	check(disp_of("\tx", 1) == 4, "a leading tab is four columns")
	check(disp_of("ab\tx", 3) == 4, "a tab fills up to the next multiple of four")
	check(disp_of("abcd\tx", 5) == 8, "a tab on a boundary advances a whole stop")
	check(disp_of("héllo", 5) == 4, "a two-byte rune is one column")
	check(byte_of("\tx", 4) == 1, "byte_of inverts a tab")
	check(byte_of("héllo", 2) == 3, "byte_of inverts a multi-byte rune")
	check(byte_of("abc", 99) == 3, "byte_of past the end clamps")
	check(disp_of("\t\t", 2) == 8, "two tabs are two stops")
}

tok_at :: proc(toks: []Token, i: int) -> Tok {
	return i < len(toks) ? toks[i].kind : .Plain
}

test_lexer :: proc() {
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)

	lex_one :: proc(src: string, st: Lex_State, out: ^[dynamic]Token) -> Lex_State {
		clear(out)
		return lex_line(src, st, out)
	}

	lex_one("x := \"// not a comment\"", {}, &toks)
	check(tok_at(toks[:], 2) == .Str, "a string holding // stays a string")
	check(len(toks) == 3, "the line is three tokens")

	lex_one("y := \"/* nor this */\" + 1", {}, &toks)
	check(tok_at(toks[:], 2) == .Str, "a string holding /* stays a string")
	check(tok_at(toks[:], 4) == .Number, "the number after it is still a number")

	st := lex_one("/* open", {}, &toks)
	check(st.depth == 1, "an unterminated block comment carries to the next line")
	st = lex_one("still comment", st, &toks)
	check(st.depth == 1, "and keeps carrying")
	st = lex_one("done */ Thing :: struct {", st, &toks)
	check(st.depth == 0, "until it closes")
	check(tok_at(toks[:], 0) == .Comment, "the closing line starts as a comment")
	check(tok_at(toks[:], 1) == .Decl, "and the declaration after it is code again")
	check(tok_at(toks[:], 3) == .Keyword, "and so is the keyword after that")

	// Odin's block comments nest; a naive scanner closes one level too early.
	st = lex_one("/* a /* b */ c */ after", {}, &toks)
	check(st.depth == 0, "a nested block comment closes at the right place")
	check(tok_at(toks[:], 1) == .Plain, "the identifier after a nested comment is code")

	st = lex_one("s := `raw", {}, &toks)
	check(st.raw, "an unterminated raw string carries over")
	st = lex_one("still raw`", st, &toks)
	check(!st.raw, "and ends at the backtick")

	lex_one("c := '\\''", {}, &toks)
	check(tok_at(toks[:], 2) == .Rune_Lit, "an escaped quote inside a rune literal")

	lex_one("n := 0xff + 0b1010 + 1_000 + 1.5e-3 + .25", {}, &toks)
	kinds := 0
	for t in toks {
		if t.kind == .Number {
			kinds += 1
		}
	}
	check(kinds == 5, "every number form is one number token")

	lex_one("@(private = \"file\")", {}, &toks)
	check(tok_at(toks[:], 0) == .Directive, "an attribute is a directive")
	lex_one("#partial switch x {", {}, &toks)
	check(tok_at(toks[:], 0) == .Directive, "a hash directive is a directive")
	check(tok_at(toks[:], 1) == .Keyword, "switch is a keyword")

	lex_one("main :: proc() {", {}, &toks)
	check(tok_at(toks[:], 0) == .Decl, "name :: is a declaration")
	check(tok_at(toks[:], 2) == .Keyword, "proc is a keyword")
	lex_one("	fmt.println(x)", {}, &toks)
	check(tok_at(toks[:], 2) == .Call, "name( is a call")
	lex_one("	v: f32", {}, &toks)
	check(tok_at(toks[:], 2) == .Type, "f32 is a type")
	lex_one("	n := len(xs)", {}, &toks)
	check(tok_at(toks[:], 2) == .Builtin, "len is a builtin")
	lex_one("// just a comment", {}, &toks)
	check(len(toks) == 1 && toks[0].kind == .Comment, "a line comment is one token")
}

test_file_round_trip :: proc() {
	cases := [?]string {
		"a\nb\n",
		"a\nb",
		"",
		"\n",
		"\n\n\n",
		"one line with no newline",
		"trailing spaces   \nand a tab\there\n",
	}
	tmp := "/tmp/palmy-editor-selftest.tmp"
	for text, i in cases {
		if os.write_entire_file(tmp, transmute([]u8)text) != nil {
			check(false, "could not write the round-trip fixture")
			continue
		}
		b := Buffer{}
		if !buf_load(&b, tmp) {
			check(false, "could not read the round-trip fixture back")
			continue
		}
		buf_save(&b, tmp)
		back, _ := os.read_entire_file_from_path(tmp, context.temp_allocator)
		check_eq(string(back), text, fmt.tprintf("case %d round trips byte for byte", i))
	}
	os.remove(tmp)

	// CRLF is detected and written back as it was found.
	crlf := "a\r\nb\r\n"
	if os.write_entire_file(tmp, transmute([]u8)crlf) == nil {
		b := Buffer{}
		buf_load(&b, tmp)
		check(b.eol == .CRLF, "CRLF line endings are detected")
		check_eq(buf_line(&b, 0), "a", "the carriage return is not part of the line")
		buf_save(&b, tmp)
		back, _ := os.read_entire_file_from_path(tmp, context.temp_allocator)
		check_eq(string(back), "a\r\nb\r\n", "CRLF is written back unchanged")
		os.remove(tmp)
	}

	// A file that is not valid UTF-8 is labelled, not mangled.
	junk := [?]u8{0xff, 0xfe, 'a', '\n'}
	if os.write_entire_file(tmp, junk[:]) == nil {
		b := Buffer{}
		buf_load(&b, tmp)
		check(b.encoding == "Binary", "invalid UTF-8 is reported as binary")
		os.remove(tmp)
	}
}
