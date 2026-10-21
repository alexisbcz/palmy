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
	test_languages()
	test_json()
	test_markdown()
	test_wrap()
	test_wrap_motion()
	test_brackets()
	test_auto_close()
	test_grouped_undo()
	test_carets()
	test_file_round_trip()
	test_doc_core() // selftest_doc.odin: the core with no window
	test_cli()

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


// ---------------------------------------------------------------------------
// Languages
// ---------------------------------------------------------------------------

// sorted checks a word table really is in order. `in_set` binary-searches it,
// so a word out of place is silently never matched and nothing looks wrong
// until somebody notices one keyword is the wrong colour.
sorted :: proc(set: []string, what: string) {
	bad := ""
	for i in 1 ..< len(set) {
		if strings.compare(set[i - 1], set[i]) >= 0 {
			bad = fmt.tprintf("%q after %q", set[i], set[i - 1])
			break
		}
	}
	check(bad == "", fmt.tprintf("%s is sorted%s", what, bad == "" ? "" : fmt.tprintf(" (%s)", bad)))
}

test_languages :: proc() {
	sorted(ODIN_KEYWORDS[:], "the Odin keyword table")
	sorted(ODIN_TYPES[:], "the Odin type table")
	sorted(ODIN_BUILTINS[:], "the Odin builtin table")
	sorted(C_KEYWORDS[:], "the C keyword table")
	sorted(C_TYPES[:], "the C type table")
	sorted(C_BUILTINS[:], "the C builtin table")
	sorted(PY_KEYWORDS[:], "the Python keyword table")
	sorted(PY_TYPES[:], "the Python type table")
	sorted(PY_BUILTINS[:], "the Python builtin table")
	sorted(SH_KEYWORDS[:], "the Shell keyword table")
	sorted(SH_TYPES[:], "the Shell type table")
	sorted(SH_BUILTINS[:], "the Shell builtin table")

	// The extension is what picks the language, so every one of them has to
	// land where it was meant to.
	check(lang_for_path("/a/b.odin") == .Odin, "an .odin file is Odin")
	check(lang_for_path("x.c") == .C && lang_for_path("x.h") == .C, "C and its header")
	check(lang_for_path("x.cpp") == .C && lang_for_path("x.hpp") == .C, "C++ too")
	check(lang_for_path("pkg.json") == .JSON, "a .json file is JSON")
	check(lang_for_path("README.md") == .Markdown, "a .md file is Markdown")
	check(lang_for_path("README") == .Markdown, "and so is a bare README")
	check(lang_for_path("x.py") == .Python, "a .py file is Python")
	check(lang_for_path("x.sh") == .Shell && lang_for_path(".bashrc") == .Shell, "shell scripts")
	check(lang_for_path("/a/b.txt") == .Plain, "a .txt file has no highlighter")
	check(lang_for_path("Makefile") == .Plain, "nor has a Makefile — it is not pretended")
	check(lang_for_path("/a/b.MD") == .Markdown, "the extension is matched without case")

	// A script with no extension says what it is on its first line.
	l, ok := lang_for_shebang("#!/usr/bin/env python3")
	check(ok && l == .Python, "a python shebang")
	l, ok = lang_for_shebang("#!/bin/bash")
	check(ok && l == .Shell, "a bash shebang")
	l, ok = lang_for_shebang("#!/bin/sh")
	check(ok && l == .Shell, "a plain sh shebang")
	_, ok = lang_for_shebang("not a shebang")
	check(!ok, "a line that is not a shebang says nothing")
	check(lang_detect("script", "#!/bin/zsh") == .Shell, "detect falls back to the shebang")
	check(
		lang_detect("notes.md", "#!/bin/sh") == .Markdown,
		"but the name wins when it knows something",
	)

	check(lang_highlights(.Odin) && lang_highlights(.JSON), "the real languages highlight")
	check(!lang_highlights(.Plain), "plain text does not")
	check(lang_name(.Markdown) == "Markdown", "a language has a name for the status bar")

	// C's block comments do not nest, and Odin's do. Same scanner, one flag,
	// and getting it backwards would silently swallow the rest of a file.
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)
	cst := lex_line("/* a /* b */ code_here", {}, &toks, .C)
	check(cst.depth == 0, "a C block comment closes at the first terminator")
	check(tok_at(toks[:], 1) != .Comment, "so what follows it is code")
	ost := lex_line("/* a /* b */ still_comment", {}, &toks, .Odin)
	check(ost.depth == 1, "an Odin block comment nests, so the same line stays open")

	clear(&toks)
	lex_line("#include <stdio.h>", {}, &toks, .C)
	check(tok_at(toks[:], 0) == .Directive, "a C preprocessor line is a directive")
	clear(&toks)
	lex_line("char c = 'x';", {}, &toks, .C)
	check(tok_at(toks[:], 0) == .Type, "char is a C type")
	check(tok_at(toks[:], 3) == .Rune_Lit, "and 'x' is a character literal")
	clear(&toks)
	lex_line("size_t n = sizeof(buf);", {}, &toks, .C)
	check(tok_at(toks[:], 0) == .Type, "size_t is a type")
	check(tok_at(toks[:], 3) == .Keyword, "sizeof is a keyword")

	// Python: `#` is a comment, so it can never be a directive, and a single
	// quote is a string rather than a character.
	clear(&toks)
	lex_line("x = 1  # a comment", {}, &toks, .Python)
	check(toks[len(toks) - 1].kind == .Comment, "a # comment in Python")
	clear(&toks)
	lex_line("s = 'text'", {}, &toks, .Python)
	check(tok_at(toks[:], 2) == .Str, "a single-quoted Python string is a string")
	clear(&toks)
	lex_line("def main(argv):", {}, &toks, .Python)
	check(tok_at(toks[:], 0) == .Keyword, "def is a keyword")
	check(tok_at(toks[:], 1) == .Call, "and the name after it is being defined as a call")
	clear(&toks)
	lex_line("if x is None:", {}, &toks, .Python)
	check(tok_at(toks[:], 3) == .Builtin, "None is a builtin")

	// Shell: a $-prefixed word is the variable, not the punctuation.
	clear(&toks)
	lex_line("echo \"$HOME/bin\"", {}, &toks, .Shell)
	check(tok_at(toks[:], 0) == .Builtin, "echo is a shell builtin")
	check(tok_at(toks[:], 1) == .Str, "and the quoted argument is a string")
	clear(&toks)
	lex_line("cd $HOME", {}, &toks, .Shell)
	check(tok_at(toks[:], 2) == .Builtin, "a $VAR is painted as the variable it names")
	clear(&toks)
	lex_line("for f in *.c; do", {}, &toks, .Shell)
	check(tok_at(toks[:], 0) == .Keyword, "for is a keyword")

	// Plain text produces nothing at all, which is what makes it cheap.
	clear(&toks)
	lex_line("anything at all { } \" //", {}, &toks, .Plain)
	check(len(toks) == 0, "plain text produces no tokens")
}

test_json :: proc() {
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)

	// The distinction that makes a JSON highlighter worth having.
	lex_line(`  "name": "value",`, {}, &toks, .JSON)
	check(tok_at(toks[:], 0) == .Key, "a string before a colon is a key")
	check(tok_at(toks[:], 2) == .Str, "a string after one is a value")

	clear(&toks)
	lex_line(`{"a":1,"b":-2.5e3,"c":true,"d":null,"e":false}`, {}, &toks, .JSON)
	nums, builtins, keys := 0, 0, 0
	for t in toks {
		switch t.kind {
		case .Number:
			nums += 1
		case .Builtin:
			builtins += 1
		case .Key:
			keys += 1
		case .Plain, .Keyword, .Type, .Str, .Rune_Lit, .Comment, .Directive, .Punct, .Call,
		     .Decl, .Heading, .Emph, .Strong, .Code, .Link, .Marker:
		}
	}
	check(keys == 5, "five keys")
	check(nums == 2, "two numbers, one of them negative with an exponent")
	check(builtins == 3, "true, false and null are the whole vocabulary")

	clear(&toks)
	lex_line(`  "with // slashes and a { brace": 1`, {}, &toks, .JSON)
	check(tok_at(toks[:], 0) == .Key, "a key containing // is still one token")
	check(
		len(toks) > 0 && toks[0].to - toks[0].from == len(`"with // slashes and a { brace"`),
		"and the whole string",
	)

	// JSONC: a comment is not data.
	clear(&toks)
	lex_line(`  // a note`, {}, &toks, .JSON)
	check(len(toks) == 1 && tok_at(toks[:], 0) == .Comment, "a // comment in JSON is a comment")
	clear(&toks)
	st := lex_line(`/* open`, {}, &toks, .JSON)
	check(st.depth == 1, "an unterminated JSON block comment carries over")
	clear(&toks)
	st = lex_line(`still */ "k": 2`, st, &toks, .JSON)
	check(st.depth == 0 && tok_at(toks[:], 0) == .Comment, "and closes on the next line")
	check(tok_at(toks[:], 1) == .Key, "leaving the key after it as a key")

	// A bare word is not JSON, and the highlighter says so by not colouring it.
	clear(&toks)
	lex_line(`  undefined`, {}, &toks, .JSON)
	check(len(toks) == 1 && tok_at(toks[:], 0) == .Plain, "a word that is not a literal stays plain")
}

test_markdown :: proc() {
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)

	lex_line("## A heading", {}, &toks, .Markdown)
	check(len(toks) == 1 && tok_at(toks[:], 0) == .Heading, "a heading is one span, markers and all")
	clear(&toks)
	lex_line("####### seven hashes is not a heading", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) != .Heading, "seven hashes is too many to be a heading")

	// The cross-line case a regex highlighter always gets wrong: inside a
	// fence a `#` is a shell comment, not a heading.
	clear(&toks)
	st := lex_line("```sh", {}, &toks, .Markdown)
	check(st.fence, "a fence opens")
	clear(&toks)
	st = lex_line("# this is a comment, not a heading", st, &toks, .Markdown)
	check(st.fence, "and stays open")
	check(tok_at(toks[:], 0) == .Code, "so the line inside it is code, not a heading")
	clear(&toks)
	st = lex_line("```", st, &toks, .Markdown)
	check(!st.fence, "and closes on the next fence")
	clear(&toks)
	clear(&toks)
	lex_line("# a real heading again", st, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Heading, "after which a heading is a heading again")

	clear(&toks)
	lex_line("- a bullet with **bold** and *italic* and `code`", {}, &toks, .Markdown)
	kinds: [Tok]int
	for t in toks {
		kinds[t.kind] += 1
	}
	check(kinds[.Marker] == 1, "the bullet is a marker")
	check(kinds[.Strong] == 1, "the bold run is one span")
	check(kinds[.Emph] == 1, "the italic run is another")
	check(kinds[.Code] == 1, "and the code span a third")

	clear(&toks)
	lex_line("- [x] a done task", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Marker && toks[0].to == 6, "a task-list marker is one marker")
	clear(&toks)
	lex_line("  3. an ordered item", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Marker && toks[0].from == 2, "an ordered marker keeps its indent out")
	clear(&toks)
	lex_line("> a quotation", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Marker, "a blockquote marker")
	clear(&toks)
	lex_line("---", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Marker, "a thematic break")

	clear(&toks)
	lex_line("see [the docs](https://example.com) for more", {}, &toks, .Markdown)
	found := false
	for t in toks {
		if t.kind == .Link {
			found = true
			check(t.to - t.from == len("[the docs](https://example.com)"), "the whole link")
		}
	}
	check(found, "a link is one span")

	// `*` with no partner is punctuation, not an unterminated italic swallowing
	// the rest of the line.
	clear(&toks)
	lex_line("2 * 3 = 6", {}, &toks, .Markdown)
	for t in toks {
		check(t.kind != .Emph, "a lone asterisk is not emphasis")
		break
	}

	// A `#` inside a code span is not a heading either, because the span is
	// tested before the line is.
	clear(&toks)
	lex_line("the `#define` macro", {}, &toks, .Markdown)
	check(tok_at(toks[:], 0) == .Code, "an inline code span wins over everything inside it")
}

// ---------------------------------------------------------------------------
// Soft wrap
//
// The caret lives in two coordinate systems and the round trip between them is
// the whole feature, so it is asserted exhaustively: every byte position of
// every line of a buffer chosen to contain each wrapping case there is.
// ---------------------------------------------------------------------------

wrap_fixture :: proc(ed: ^Editor, text: string, cols: int) {
	load_text(&ed.buf, text)
	ed.cols = cols
	ed.rows = 8
	ed.wrap = true
	ed.cur = {0, 0}
	ed.top, ed.top_sub, ed.left = 0, 0, 0
}

WRAP_TEXT :: "the quick brown fox jumps over the lazy dog and then keeps on going\n" +
	"short\n" +
	"\n" +
	"\tan indented line that also has to wrap somewhere sensible\n" +
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" +
	"trailing   spaces   between   words   that   wrap   oddly\n" +
	"héllo wörld with multi-byte runes that must stay whole when wrapped"

test_wrap :: proc() {
	ed := Editor{}
	wrap_fixture(&ed, WRAP_TEXT, 20)

	// No visual row is wider than the window, unless it is a single character
	// that cannot be broken any smaller.
	rows := make([dynamic]Vis, 0, 16, context.temp_allocator)
	wide := 0
	tiles := 0
	for li in 0 ..< buf_lines(&ed.buf) {
		wrap_rows(&ed, li, &rows)
		check(len(rows) > 0, "every line has at least one visual row")
		for r, k in rows {
			if r.c1 - r.c0 > ed.cols {
				wide += 1
			}
			check(r.sub == k, "a row knows which row of its line it is")
			// Rows run forwards and never overlap.
			if k > 0 && rows[k - 1].c1 > r.c0 {
				tiles += 1
			}
		}
		check(rows[len(rows) - 1].last, "the last row says so")
		check(rows[0].c0 == 0, "the first row starts at the first cell")
		check(
			rows[len(rows) - 1].c1 == disp_of(buf_line(&ed.buf, li), len(buf_line(&ed.buf, li))),
			"the last row ends at the last cell",
		)
	}
	check(wide == 0, "no visual row is wider than the window")
	check(tiles == 0, "visual rows never overlap")

	// The round trip. This is the assertion the whole feature rests on.
	bad := 0
	total := 0
	for li in 0 ..< buf_lines(&ed.buf) {
		src := buf_line(&ed.buf, li)
		col := 0
		for {
			sub, dx := caret_vis(&ed, {li, col})
			back := col_at(&ed, li, sub, dx)
			total += 1
			if back.line != li || back.col != col {
				bad += 1
				if bad == 1 {
					fmt.printfln(
						"        first failure: line %d col %d -> (row %d, +%d) -> col %d",
						li,
						col,
						sub,
						dx,
						back.col,
					)
				}
			}
			if col >= len(src) {
				break
			}
			col = rune_right(src, col)
		}
	}
	check(total > 300, "the round trip was tried on a few hundred positions")
	check(bad == 0, fmt.tprintf("every caret position round trips (%d of %d failed)", bad, total))

	// With wrap off, the same round trip has to hold trivially — one row per
	// line, starting at cell zero.
	ed.wrap = false
	bad = 0
	for li in 0 ..< buf_lines(&ed.buf) {
		src := buf_line(&ed.buf, li)
		col := 0
		for {
			sub, dx := caret_vis(&ed, {li, col})
			if sub != 0 || dx != disp_of(src, col) {
				bad += 1
			}
			if !pos_eq(col_at(&ed, li, sub, dx), {li, col}) {
				bad += 1
			}
			if col >= len(src) {
				break
			}
			col = rune_right(src, col)
		}
	}
	check(bad == 0, "unwrapped, a visual row is a logical line and the goal is the column")

	// A very narrow window still wraps rather than looping.
	wrap_fixture(&ed, "a b c d e f g h i j k l m n o p", 8)
	wrap_rows(&ed, 0, &rows)
	check(len(rows) >= 4, "a narrow window produces many rows")
	// And so does one with a word longer than it.
	wrap_fixture(&ed, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 8)
	wrap_rows(&ed, 0, &rows)
	check(len(rows) == 4, "a word longer than the window is broken, not left to overflow")
	check(rows[0].c0 == 0 && rows[0].c1 == 8, "the first hard-broken row is exactly the width")

	// A tab wider than what is left on the row moves to the next one without
	// splitting the tab across two rows.
	wrap_fixture(&ed, "abcdef\tgh", 8)
	wrap_rows(&ed, 0, &rows)
	ok_tab := true
	for r in rows {
		if r.c1 - r.c0 > 8 {
			ok_tab = false
		}
	}
	check(ok_tab, "a tab near the edge does not overflow the row")
}

test_wrap_motion :: proc() {
	ed := Editor{}
	wrap_fixture(&ed, WRAP_TEXT, 20)

	// Down then up with the same goal column returns to the same place. This
	// is the property that makes vertical motion in a wrapped buffer usable,
	// and the one that breaks the moment the two conversions disagree.
	bad := 0
	tried := 0
	for li in 0 ..< buf_lines(&ed.buf) {
		for sub in 0 ..< wrap_count(&ed, li) {
			if _, _, can := vis_step(&ed, li, sub, 1); !can {
				continue
			}
			for dx in ([?]int{0, 1, 5, 13, 19, 40}) {
				ed.cur = col_at(&ed, li, sub, dx)
				goal_set(&ed)
				start := ed.cur
				g := ed.goal
				move_vert(&ed, 1)
				ed.goal = g // vertical motion keeps the goal, as the app does
				move_vert(&ed, -1)
				tried += 1
				if !pos_eq(ed.cur, start) {
					bad += 1
					if bad == 1 {
						fmt.printfln(
							"        first failure: line %d row %d +%d -> %d:%d",
							li,
							sub,
							dx,
							ed.cur.line,
							ed.cur.col,
						)
					}
				}
			}
		}
	}
	check(tried > 100, "down-then-up was tried from a hundred places")
	check(bad == 0, fmt.tprintf("down then up returns to the same place (%d of %d failed)", bad, tried))

	// Stepping down through the whole buffer visits every visual row once and
	// stops at the end rather than running off it.
	li, sub := 0, 0
	seen := 0
	for {
		seen += 1
		nl, ns, ok := vis_step(&ed, li, sub, 1)
		if !ok {
			break
		}
		check_once(vis_before(li, sub, nl, ns), "a step down always moves forwards")
		li, sub = nl, ns
		if seen > 500 {
			break
		}
	}
	check(seen > buf_lines(&ed.buf), "there are more visual rows than logical lines")
	check(li == buf_lines(&ed.buf) - 1, "stepping down ends on the last line")
	check(sub == wrap_count(&ed, li) - 1, "and on its last visual row")

	// And back up to the very top.
	for {
		nl, ns, ok := vis_step(&ed, li, sub, -1)
		if !ok {
			break
		}
		li, sub = nl, ns
	}
	check(li == 0 && sub == 0, "stepping up ends at the first row of the first line")

	// vis_gap gives up rather than counting through a long file.
	check(vis_gap(&ed, 0, 0, 0, 0, 10) == 0, "no rows between a row and itself")
	check(vis_gap(&ed, 0, 0, 1, 0, 10) == wrap_count(&ed, 0), "the gap over one wrapped line")
	check(vis_gap(&ed, 5, 0, 0, 0, 6) == 6, "a gap it cannot reach is reported as the limit")

	// The viewport walker fills the window and no more, and starts where it
	// was told to.
	ed.rows = 5
	ed.top, ed.top_sub = 0, 1
	build_visible(&ed)
	check(len(ed.vis) == 5, "the viewport is exactly as tall as the window")
	check(ed.vis[0].line == 0 && ed.vis[0].sub == 1, "and starts at the row it was pointed at")

	// Scrolling to the caret is bounded and lands it on screen.
	ed.cur = buf_end(&ed.buf)
	goal_set(&ed)
	ensure_visible(&ed)
	build_visible(&ed)
	on_screen := false
	csub, _ := caret_vis(&ed, ed.cur)
	for v in ed.vis {
		if v.line == ed.cur.line && v.sub == csub {
			on_screen = true
		}
	}
	check(on_screen, "the caret's visual row is on screen after ensure_visible")
}

// check_once reports a repeated failure only the first time, so one broken
// invariant inside a loop does not print five hundred lines.
once_failed: map[string]bool
check_once :: proc(ok: bool, what: string) {
	if ok || once_failed[what] {
		return
	}
	once_failed[what] = true
	check(false, what)
}

// ---------------------------------------------------------------------------
// Brackets
// ---------------------------------------------------------------------------

bracket_fixture :: proc(ed: ^Editor, text: string, lang := Lang.Odin) {
	load_text(&ed.buf, text)
	ed.lang = lang
	ed.cols = 120
	ed.rows = 20
	ed.wrap = false
	ed.buf.valid = 0
}

test_brackets :: proc() {
	ed := Editor{}

	bracket_fixture(&ed, "main :: proc(a: int) {\n\tx := f(g(a))\n}")
	// The parenthesis after `proc` matches the one before the brace.
	m, ok := bracket_match(&ed, {0, 12})
	check(ok && pos_eq(m, {0, 19}), "a parenthesis finds its partner on the same line")
	m, ok = bracket_match(&ed, {0, 19})
	check(ok && pos_eq(m, {0, 12}), "and the partner finds it back")
	m, ok = bracket_match(&ed, {0, 21})
	check(ok && pos_eq(m, {2, 0}), "a brace matches across lines")
	m, ok = bracket_match(&ed, {2, 0})
	check(ok && pos_eq(m, {0, 21}), "and back again")

	// Nesting: the inner pair must not steal the outer one's partner.
	line := buf_line(&ed.buf, 1)
	outer := strings.index_byte(line, '(')
	m, ok = bracket_match(&ed, {1, outer})
	check(ok && m.col == len(line) - 1, "the outer parenthesis matches the outer close")
	inner := strings.index_byte(line[outer + 1:], '(') + outer + 1
	m, ok = bracket_match(&ed, {1, inner})
	check(ok && m.col == len(line) - 2, "and the inner one matches the inner close")

	// A bracket inside a string or a comment is not a bracket. This is the
	// whole reason matching goes through the tokeniser.
	bracket_fixture(&ed, "x := \"{ not a brace\"\ny := 1 // ) nor this\nf()")
	_, ok = bracket_match(&ed, {0, 6})
	check(!ok, "a brace inside a string has no partner")
	_, ok = bracket_match(&ed, {1, 10})
	check(!ok, "nor has one inside a comment")
	m, ok = bracket_match(&ed, {2, 1})
	check(ok && pos_eq(m, {2, 2}), "a real pair still matches")

	// An unbalanced bracket says so rather than running to the end of time.
	bracket_fixture(&ed, "{\n\tnothing closes this")
	_, ok = bracket_match(&ed, {0, 0})
	check(!ok, "an unbalanced brace reports no match")

	// What the caret is "on": the character to the right, else the one to the
	// left, so the highlight appears both before a bracket and just after it.
	bracket_fixture(&ed, "f(x)")
	at, _, found := bracket_at_caret(&ed, {0, 1})
	check(found && pos_eq(at, {0, 1}), "the caret in front of ( is on it")
	at, _, found = bracket_at_caret(&ed, {0, 2})
	check(found && pos_eq(at, {0, 1}), "and the caret just after ( is still on it")
	at, _, found = bracket_at_caret(&ed, {0, 4})
	check(found && pos_eq(at, {0, 3}), "the caret at the end of the line is on the )")
	_, _, found = bracket_at_caret(&ed, {0, 0})
	check(!found, "the caret in front of a letter is on no bracket")

	// The pair the renderer asks for.
	ed.cur = {0, 1}
	a, b, pok := bracket_pair_at_caret(&ed)
	check(pok && pos_eq(a, {0, 1}) && pos_eq(b, {0, 3}), "the renderer gets both ends")
	ed.cur = {0, 0}
	_, _, pok = bracket_pair_at_caret(&ed)
	check(!pok, "and nothing when there is nothing to show")

	// Matching works in the other languages too, through their own lexers.
	bracket_fixture(&ed, "{\n  \"k\": [1, 2]\n}", .JSON)
	m, ok = bracket_match(&ed, {0, 0})
	check(ok && pos_eq(m, {2, 0}), "JSON braces match")
	bracket_fixture(&ed, "if (a) { /* } */ b(); }", .C)
	m, ok = bracket_match(&ed, {0, 7})
	check(ok && m.col == 22, "a C comment holding a brace does not close the block")
}

test_auto_close :: proc() {
	// The decision, as a pure function.
	check(should_auto_close("", 0, {'(', ')'}), "an empty line closes the pair")
	check(should_auto_close("f", 1, {'(', ')'}), "at the end of a line it closes")
	check(should_auto_close("f  x", 2, {'(', ')'}), "in front of a space it closes")
	check(!should_auto_close("foo", 0, {'(', ')'}), "in front of a word it does not")
	check(should_auto_close("f)", 1, {'(', ')'}), "in front of a closing bracket it does")
	check(should_auto_close("f,", 1, {'(', ')'}), "and in front of a comma")
	check(!should_auto_close("don", 3, {'\'', '\''}), "a quote after a word is an apostrophe")
	check(should_auto_close("x = ", 4, {'"', '"'}), "a quote after a space is a string opening")
	check(!should_auto_close("x = \"", 5, {'"', '"'}), "and not immediately after another quote")

	// Typing it for real.
	ed := Editor{}
	bracket_fixture(&ed, "f")
	ed.cur = {0, 1}
	type_text(&ed, "(")
	check_eq(whole(&ed.buf), "f()", "typing ( inserts the pair")
	check(pos_eq(ed.cur, {0, 2}), "and leaves the caret between the halves")

	// The behaviour that makes auto-close tolerable rather than infuriating.
	type_text(&ed, ")")
	check_eq(whole(&ed.buf), "f()", "typing ) over the one already there inserts nothing")
	check(pos_eq(ed.cur, {0, 3}), "it just moves over it")

	// And the other half: an empty pair goes in one keystroke.
	bracket_fixture(&ed, "f")
	ed.cur = {0, 1}
	type_text(&ed, "(")
	check(backspace_pair(&ed), "backspace between an empty pair reports that it acted")
	check_eq(whole(&ed.buf), "f", "and removed both halves")
	check(pos_eq(ed.cur, {0, 1}), "leaving the caret where the pair was")

	// A pair that is not empty is not touched, so backspace deletes one
	// character the way it always does.
	bracket_fixture(&ed, "f(x)")
	ed.cur = {0, 3}
	check(!backspace_pair(&ed), "a pair with something in it is left alone")

	// Quotes close themselves and skip over themselves.
	bracket_fixture(&ed, "x := ")
	ed.cur = {0, 5}
	type_text(&ed, "\"")
	check_eq(whole(&ed.buf), "x := \"\"", "typing a quote opens a pair of them")
	type_text(&ed, "hi")
	check_eq(whole(&ed.buf), "x := \"hi\"", "typing inside it stays inside")
	type_text(&ed, "\"")
	check_eq(whole(&ed.buf), "x := \"hi\"", "and the closing quote steps over the one there")
	check(pos_eq(ed.cur, {0, 9}), "landing after the string")

	// An apostrophe in prose does not sprout a partner.
	bracket_fixture(&ed, "don")
	ed.cur = {0, 3}
	type_text(&ed, "'t")
	check_eq(whole(&ed.buf), "don't", "an apostrophe after a word is just an apostrophe")

	// A selection is surrounded rather than replaced, which is the one gesture
	// worth having for free.
	bracket_fixture(&ed, "hello world")
	ed.anchor = {0, 0}
	ed.cur = {0, 5}
	ed.has_sel = true
	type_text(&ed, "(")
	check_eq(whole(&ed.buf), "(hello) world", "typing ( with a selection wraps it")
	check(ed.has_sel, "and keeps the selection")
	check_eq(
		buf_text(&ed.buf, ed.anchor, ed.cur, context.temp_allocator),
		"hello",
		"around the same text",
	)

	// Typing a letter is still just typing a letter, in one undo entry.
	bracket_fixture(&ed, "")
	ed.cur = {0, 0}
	type_text(&ed, "abc")
	check_eq(whole(&ed.buf), "abc", "ordinary characters are inserted")
	check(len(ed.buf.undo) == 1, "and a run of them is one undo entry")
}


// ---------------------------------------------------------------------------
// Grouped undo
//
// Several carets typing one character is several replacements in several
// places. If undo took them back one at a time, multiple cursors would make
// the undo stack worse than not having them, so edits made together carry a
// group id and come back together.
// ---------------------------------------------------------------------------

test_grouped_undo :: proc() {
	b := Buffer{}
	load_text(&b, "aa\nbb\ncc")

	g := buf_group(&b)
	check(g != 0, "a group id is never zero, which is what 'on its own' means")
	check(buf_group(&b) != g, "and ids are never handed out twice")

	// Bottom-up, which is the order the caret code applies them in.
	g = buf_group(&b)
	buf_apply(&b, {2, 0}, {2, 0}, "X", {2, 0}, .No, g)
	buf_apply(&b, {1, 0}, {1, 0}, "X", {1, 0}, .No, g)
	buf_apply(&b, {0, 0}, {0, 0}, "X", {0, 0}, .No, g)
	check_eq(whole(&b), "Xaa\nXbb\nXcc", "three grouped edits all landed")
	check(len(b.undo) == 3, "as three entries on the stack")

	_, ok := buf_undo(&b)
	check(ok, "undo acts")
	check_eq(whole(&b), "aa\nbb\ncc", "and one undo takes back the whole group")
	check(len(b.undo) == 0, "leaving nothing behind")

	_, rok := buf_redo(&b)
	check(rok, "redo acts")
	check_eq(whole(&b), "Xaa\nXbb\nXcc", "and one redo puts the whole group back")
	check(len(b.undo) == 3, "with the stack as it was")

	// An ungrouped edit next to a group must not be swept up with it.
	buf_apply(&b, {0, 0}, {0, 0}, "Z", {0, 0}, .No)
	buf_undo(&b)
	check_eq(whole(&b), "Xaa\nXbb\nXcc", "an ungrouped edit undoes on its own")
	buf_undo(&b)
	check_eq(whole(&b), "aa\nbb\ncc", "and the group still goes in one step")

	// Two groups in a row undo one at a time, not both at once.
	load_text(&b, "a\nb")
	g1 := buf_group(&b)
	buf_apply(&b, {1, 0}, {1, 0}, "1", {1, 0}, .No, g1)
	buf_apply(&b, {0, 0}, {0, 0}, "1", {0, 0}, .No, g1)
	g2 := buf_group(&b)
	buf_apply(&b, {1, 0}, {1, 0}, "2", {1, 0}, .No, g2)
	buf_apply(&b, {0, 0}, {0, 0}, "2", {0, 0}, .No, g2)
	check_eq(whole(&b), "21a\n21b", "two groups applied")
	buf_undo(&b)
	check_eq(whole(&b), "1a\n1b", "the second group came back on its own")
	buf_undo(&b)
	check_eq(whole(&b), "a\nb", "and then the first")

	// Coalescing must not run across a group boundary, or a group would grow
	// edits that were never part of it.
	load_text(&b, "x")
	cur := Pos{0, 1}
	cur = buf_apply(&b, cur, cur, "a", cur, .Type)
	gg := buf_group(&b)
	buf_apply(&b, cur, cur, "b", cur, .Type, gg)
	check(len(b.undo) == 2, "a grouped edit does not extend an ungrouped run of typing")
}

// ---------------------------------------------------------------------------
// Multiple cursors
// ---------------------------------------------------------------------------

carets_fixture :: proc(ed: ^Editor, text: string) {
	load_text(&ed.buf, text)
	ed.lang = .Plain
	ed.cols = 100
	ed.rows = 20
	ed.wrap = false
	ed.cur = {0, 0}
	ed.anchor = {0, 0}
	ed.has_sel = false
	clear(&ed.extra)
	ed.type_run = 0
}

// place puts carets at a list of positions, primary first.
place :: proc(ed: ^Editor, positions: ..Pos) {
	list := make([dynamic]Caret, 0, len(positions), context.temp_allocator)
	for q in positions {
		append(&list, Caret{q, q, false, disp_of(buf_line(&ed.buf, q.line), q.col)})
	}
	carets_store(ed, list[:])
}

test_carets :: proc() {
	ed := Editor{}

	// Gathering and scattering, including the rule that keeps the whole thing
	// honest: two carets in one place are one caret. If both survived, the
	// next keystroke would be applied twice there.
	carets_fixture(&ed, "one\ntwo\nthree")
	place(&ed, {0, 1}, {2, 1}, {1, 1})
	check(carets_count(&ed) == 3, "three carets")
	got := carets_gather(&ed)
	check(len(got) == 3 && pos_eq(got[0].cur, {0, 1}), "gathered in document order")
	check(pos_eq(got[2].cur, {2, 1}), "down to the last one")
	place(&ed, {1, 1}, {1, 1}, {0, 0})
	check(carets_count(&ed) == 2, "two carets in one place are one caret")

	// Typing at every caret, as one undo step.
	carets_fixture(&ed, "aa\nbb\ncc")
	place(&ed, {0, 0}, {1, 0}, {2, 0})
	before := len(ed.buf.undo)
	carets_edit(&ed, .Insert, "X")
	check_eq(whole(&ed.buf), "Xaa\nXbb\nXcc", "one keystroke typed at three carets")
	check(carets_count(&ed) == 3, "and all three carets survived it")
	check(pos_eq(ed.cur, {0, 1}), "each having moved past what it typed")
	check(len(ed.buf.undo) == before + 3, "three edits went on the stack")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "aa\nbb\ncc", "and one undo took the keystroke back")

	// The bottom-up rule, tested where it actually matters: carets on the
	// same line, where an edit at one really does move the other.
	carets_fixture(&ed, "abcdef")
	place(&ed, {0, 1}, {0, 3}, {0, 5})
	carets_edit(&ed, .Insert, "-")
	check_eq(whole(&ed.buf), "a-bc-de-f", "three carets on one line each got their own")
	g := carets_gather(&ed)
	check(
		pos_eq(g[0].cur, {0, 2}) && pos_eq(g[1].cur, {0, 5}) && pos_eq(g[2].cur, {0, 8}),
		"and every caret ended after the character it typed",
	)

	// Backspace at every caret.
	carets_fixture(&ed, "aXa\nbXb\ncXc")
	place(&ed, {0, 2}, {1, 2}, {2, 2})
	carets_edit(&ed, .Backspace)
	check_eq(whole(&ed.buf), "aa\nbb\ncc", "backspace at three carets")
	check(carets_count(&ed) == 3, "which are still three")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "aXa\nbXb\ncXc", "and it undoes in one step")

	// Backspace that joins lines, which is the case that moves other carets
	// onto a line that no longer exists.
	carets_fixture(&ed, "a\nb\nc")
	place(&ed, {1, 0}, {2, 0})
	carets_edit(&ed, .Backspace)
	check_eq(whole(&ed.buf), "abc", "two line joins at once")
	check(carets_count(&ed) == 2, "both carets survived the join")

	// Delete forward.
	carets_fixture(&ed, "aXa\nbXb")
	place(&ed, {0, 1}, {1, 1})
	carets_edit(&ed, .Delete)
	check_eq(whole(&ed.buf), "aa\nbb", "delete at two carets")

	// Return at every caret keeps the indent.
	carets_fixture(&ed, "\tone\n\ttwo")
	place(&ed, {0, 4}, {1, 4})
	carets_edit(&ed, .Newline)
	check_eq(whole(&ed.buf), "\tone\n\t\n\ttwo\n\t", "Return at two carets, each carrying its indent")

	// A selection at each caret is replaced, not inserted beside.
	carets_fixture(&ed, "aaa\nbbb")
	list := make([dynamic]Caret, 0, 2, context.temp_allocator)
	append(&list, Caret{{0, 3}, {0, 0}, true, 3})
	append(&list, Caret{{1, 3}, {1, 0}, true, 3})
	carets_store(&ed, list[:])
	carets_edit(&ed, .Insert, "Z")
	check_eq(whole(&ed.buf), "Z\nZ", "a selection at each caret is replaced")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "aaa\nbbb", "and that is one undo step too")

	// Moving them all.
	carets_fixture(&ed, "abcd\nefgh")
	place(&ed, {0, 0}, {1, 0})
	carets_move(&ed, .Right, false)
	gm := carets_gather(&ed)
	check(pos_eq(gm[0].cur, {0, 1}) && pos_eq(gm[1].cur, {1, 1}), "Right moves every caret")
	carets_move(&ed, .End, false)
	gm = carets_gather(&ed)
	check(pos_eq(gm[0].cur, {0, 4}) && pos_eq(gm[1].cur, {1, 4}), "End takes each to its own end")
	carets_move(&ed, .Home, false)
	gm = carets_gather(&ed)
	check(pos_eq(gm[0].cur, {0, 0}) && pos_eq(gm[1].cur, {1, 0}), "and Home back again")
	carets_move(&ed, .Right, true)
	gm = carets_gather(&ed)
	check(gm[0].has_sel && gm[1].has_sel, "Shift and a motion selects at every caret")

	// Two carets walking into each other merge rather than doubling up.
	carets_fixture(&ed, "ab")
	place(&ed, {0, 0}, {0, 1})
	carets_move(&ed, .End, false)
	check(carets_count(&ed) == 1, "carets that meet become one")

	// Adding a caret below, which is the column gesture.
	carets_fixture(&ed, "aaaa\nbbbb\ncccc")
	ed.cur = {0, 2}
	goal_set(&ed)
	caret_add_vert(&ed, 1)
	check(carets_count(&ed) == 2, "a second caret appeared")
	gv := carets_gather(&ed)
	check(pos_eq(gv[1].cur, {1, 2}), "directly below the first, in the same column")
	caret_add_vert(&ed, 1)
	gv = carets_gather(&ed)
	check(carets_count(&ed) == 3 && pos_eq(gv[2].cur, {2, 2}), "and a third below that")
	caret_add_vert(&ed, 1)
	check(carets_count(&ed) == 3, "there is no line below the last one to add to")
	carets_edit(&ed, .Insert, "|")
	check_eq(whole(&ed.buf), "aa|aa\nbb|bb\ncc|cc", "a column of carets types a column")

	// Add at the next match: the gesture multiple cursors exist for.
	carets_fixture(&ed, "foo bar\nfoo baz\nqux foo")
	ed.cur = {0, 1}
	caret_add_next(&ed)
	check(carets_count(&ed) == 1, "the first press only selects the word under the caret")
	check_eq(
		buf_text(&ed.buf, ed.anchor, ed.cur, context.temp_allocator),
		"foo",
		"which is the word it was in",
	)
	caret_add_next(&ed)
	check(carets_count(&ed) == 2, "the second press adds a caret at the next one")
	caret_add_next(&ed)
	check(carets_count(&ed) == 3, "and the third at the one after that")
	caret_add_next(&ed)
	check(carets_count(&ed) == 3, "there is no fourth, and it does not loop round")
	carets_edit(&ed, .Insert, "FOO")
	check_eq(whole(&ed.buf), "FOO bar\nFOO baz\nqux FOO", "typing renames all three")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "foo bar\nfoo baz\nqux foo", "in one undo step")

	// Every match at once.
	carets_fixture(&ed, "x = 1\ny = x\nz = x + x")
	ed.cur = {0, 0}
	caret_add_all(&ed)
	check(carets_count(&ed) == 4, "a caret on every x in the file")
	carets_edit(&ed, .Insert, "w")
	check_eq(whole(&ed.buf), "w = 1\ny = w\nz = w + w", "and all four renamed together")

	// Case matters: renaming `foo` must not touch `Foo`.
	carets_fixture(&ed, "foo Foo foo")
	ed.cur = {0, 0}
	caret_add_all(&ed)
	check(carets_count(&ed) == 2, "the match is case sensitive")

	// Collapsing.
	carets_fixture(&ed, "a\nb\nc")
	place(&ed, {0, 0}, {1, 0}, {2, 0})
	check(carets_multi(&ed), "several carets are up")
	carets_collapse(&ed)
	check(!carets_multi(&ed) && carets_count(&ed) == 1, "and Escape puts them away")
	check(pos_eq(ed.cur, {0, 0}), "leaving the first one where it was")

	// Nothing under the caret to match is said, not guessed at.
	carets_fixture(&ed, "   ")
	ed.cur = {0, 1}
	caret_add_all(&ed)
	check(carets_count(&ed) == 1, "whitespace is not a word to put carets on")

	// A run of typing at several carets is ONE undo step. Without this,
	// renaming twelve occurrences and pressing Ctrl-Z takes back one letter in
	// twelve places, which looks like a bug and is one — it is exactly what
	// the first recording of the demo showed.
	carets_fixture(&ed, "ctx a\nctx b")
	place(&ed, {0, 0}, {1, 0})
	for ch in ([?]string{"n", "e", "w"}) {
		carets_edit(&ed, .Insert, ch)
	}
	check_eq(whole(&ed.buf), "newctx a\nnewctx b", "three letters typed at two carets")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "ctx a\nctx b", "and one undo takes the whole run back")

	// Anything that is not more typing ends the run, so the next undo stops
	// at the right place.
	carets_fixture(&ed, "a\nb")
	place(&ed, {0, 0}, {1, 0})
	carets_edit(&ed, .Insert, "1")
	carets_move(&ed, .Right, false)
	carets_edit(&ed, .Insert, "2")
	check_eq(whole(&ed.buf), "1a2\n1b2", "typed, moved, typed again")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "1a\n1b", "the second run undoes on its own")
	buf_undo(&ed.buf)
	check_eq(whole(&ed.buf), "a\nb", "and then the first")

	// Whole-word matching: renaming `ctx` must not put a caret inside
	// `context`, which the first recording of the demo also got wrong.
	carets_fixture(&ed, "ctx\ncontext\nctx_held\nctx")
	ed.cur = {0, 1}
	caret_add_all(&ed)
	check(carets_count(&ed) == 2, "only the whole words match, not context or ctx_held")
	carets_edit(&ed, .Insert, "w")
	check_eq(whole(&ed.buf), "w\ncontext\nctx_held\nw", "and only those two were renamed")

	check(is_word_run("abc_1"), "a run of word characters is a word")
	check(!is_word_run("a b"), "a space is not")
	check(!is_word_run(""), "and nothing is not a word either")

	// A selection that is a fragment is matched literally, because a fragment
	// is what was asked for.
	carets_fixture(&ed, "context context")
	ed.anchor = {0, 0}
	ed.cur = {0, 3}
	ed.has_sel = true
	caret_add_all(&ed)
	check(carets_count(&ed) == 2, "a fragment selection matches inside words")

	// The clipboard: one line per caret, in document order.
	carets_fixture(&ed, "one\ntwo\nthree")
	place(&ed, {2, 0}, {0, 0})
	check_eq(carets_text(&ed), "one\nthree", "copying with two carets takes both lines in order")
}
