package main

// The editing core (doc.odin, diff.odin) with no window, the window's own
// commands over it, and the command line over both.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

checkf :: proc(ok: bool, format: string, args: ..any) {
	check(ok, fmt.tprintf(format, ..args))
}

test_doc_core :: proc() {
	// --- positions a person types ---------------------------------------------
	{
		b: Buffer
		load_text(&b, "héllo wörld\nsecond\n")
		b.final_nl = true
		check(char_to_col("héllo", 3) == 3, "char_to_col: é is one character, two bytes")
		check(col_to_char("héllo", 3) == 3, "col_to_char: and back")
		at, ok := parse_pos(&b, "1:8")
		check(ok && at == Pos{0, 8}, "parse_pos: 1:8 is past é and ö-free bytes")
		at, ok = parse_pos(&b, "2")
		check(ok && at == Pos{1, 0}, "parse_pos: a bare line is its start")
		_, ok = parse_pos(&b, "9:1")
		check(!ok, "parse_pos: a line past the end is refused")
		_, ok = parse_pos(&b, "0:1")
		check(!ok, "parse_pos: lines start at 1")
		check(buf_line_count(&b) == 2, "line count: the empty line after a final newline is not a line")
		f, l, rok := parse_range(&b, "1:$")
		check(rok && f == 1 && l == 2, "parse_range: 1:$")
		f, l, rok = parse_range(&b, "1,+1")
		check(rok && f == 1 && l == 2, "parse_range: 1,+1")
		f, l, rok = parse_range(&b, "2")
		check(rok && f == 2 && l == 2, "parse_range: one line")
		_, _, rok = parse_range(&b, "2:1")
		check(!rok, "parse_range: backwards is refused")
	}

	// --- search and replace ----------------------------------------------------
	{
		b: Buffer
		load_text(&b, "Teh cat and teh hat\nteh end")
		found, _ := buf_find_all(&b, "teh", false)
		check(len(found) == 2, "find_all: case-sensitive finds two")
		found, _ = buf_find_all(&b, "teh", true)
		check(len(found) == 3 && len(found) == buf_count(&b, "teh", true), "find_all: folded finds three, as the window's counter does")
		few, trunc := buf_find_all(&b, "teh", true, 2)
		check(len(few) == 2 && trunc, "find_all: a limit truncates and says so")

		n, _ := buf_replace_all(&b, "teh", "the", false, {0, 0})
		check(n == 2 && whole(&b) == "Teh cat and the hat\nthe end", "replace_all: case-sensitive leaves Teh")
		_, uok := buf_undo(&b)
		check(uok && whole(&b) == "Teh cat and teh hat\nteh end", "replace_all: one undo takes back every replacement")
		n, _ = buf_replace_all(&b, "TEH", "the", true, {0, 0}, 2)
		check(n == 2 && whole(&b) == "the cat and the hat\nteh end", "replace_all: --limit stops after two")
		buf_undo(&b)
		n, _ = buf_replace_all(&b, "teh", "a\nb", true, {0, 0})
		checkf(n == 3 && buf_lines(&b) == 5, "replace_all: a replacement with a newline moves past itself (%d lines)", buf_lines(&b))
		buf_undo(&b)
		n, _ = buf_replace_all(&b, "e", "ee", false, {0, 0})
		check(n == 4 && strings.count(whole(&b), "ee") == 4, "replace_all: a replacement containing the needle is not rescanned")

		load_text(&b, "foo bar foo")
		_, done := buf_replace_if_match(&b, {0, 0}, {0, 3}, "FOO", "x", true, {0, 0})
		check(done && whole(&b) == "x bar foo", "replace_if_match: the selection holds the needle")
		_, done = buf_replace_if_match(&b, {0, 2}, {0, 5}, "foo", "x", true, {0, 0})
		check(!done, "replace_if_match: it does not")
	}

	// --- line commands and the window's commands over them ------------------------
	{
		ed := Editor{}
		load_text(&ed.buf, "one\ntwo\nthree")
		ed.cur = {1, 2}
		run_cmd(&ed, .Dup_Line)
		check(whole(&ed.buf) == "one\ntwo\ntwo\nthree" && ed.cur == Pos{2, 2}, "Dup_Line: through buf_dup_line, the caret on the copy")
		run_cmd(&ed, .Del_Line)
		check(whole(&ed.buf) == "one\ntwo\nthree", "Del_Line: through buf_del_line")
		check(buf_goto_line(&ed.buf, 99) == Pos{2, 0}, "goto: clamps to the last line")

		b: Buffer
		load_text(&b, "a\nb\nc\nd")
		buf_replace_lines(&b, 2, 3, "X", {0, 0})
		check(whole(&b) == "a\nX\nd", "replace_lines: 2..3 become one line")
		buf_replace_lines(&b, 2, 2, "", {0, 0})
		check(whole(&b) == "a\n\nd", "replace_lines: empty text empties the line")
	}

	// The window's replace-all and the command's are one procedure: an Editor
	// driven the way the prompt drives it, against buf_replace_all on a copy.
	{
		ed := Editor{}
		load_text(&ed.buf, "Alpha alpha ALPHA beta")
		append(&ed.find, ..transmute([]u8)string("alpha"))
		append(&ed.repl, ..transmute([]u8)string("gamma"))
		replace_all(&ed)
		b: Buffer
		load_text(&b, "Alpha alpha ALPHA beta")
		buf_replace_all(&b, "alpha", "gamma", true, {0, 0})
		checkf(whole(&ed.buf) == whole(&b) && whole(&b) == "gamma gamma gamma beta", "window Replace All == buf_replace_all -i (%q)", whole(&ed.buf))
		checkf(strings.contains(ed.toast, "Replaced 3"), "and the window says how many (%q)", ed.toast)
	}

	// --- serialisation is exactly what save writes ------------------------------------
	{
		dir := fmt.tprintf("/tmp/editor-selftest-doc-%d", os.get_pid())
		_ = os.make_directory_all(dir)
		defer os.remove_all(dir)
		for text in ([?]string{"a\r\nb\r\n", "no newline", "x\n\ny\n", ""}) {
			path := fmt.tprintf("%s/f.txt", dir)
			_ = os.write_entire_file(path, transmute([]u8)text)
			b: Buffer
			check(doc_open(&b, path), "doc_open: an existing file")
			checkf(buf_serialize(&b, context.temp_allocator) == text, "serialize: %q round-trips", text)
			ok, _ := doc_write(&b, fmt.tprintf("%s/g.txt", dir))
			data, _ := os.read_entire_file_from_path(fmt.tprintf("%s/g.txt", dir), context.temp_allocator)
			checkf(ok && string(data) == text, "doc_write: writes those bytes (%q)", text)
		}
		b: Buffer
		check(!doc_open(&b, fmt.tprintf("%s/new.md", dir)) && buf_lines(&b) == 1 && b.path != "", "doc_open: a missing path is a new, named, empty buffer")
		check(doc_lang(&b) == .Markdown, "doc_lang: by name")
		ok, _ := doc_write(&b, dir)
		check(!ok, "doc_write: not over a folder")
	}

	// --- the diff -----------------------------------------------------------------------
	{
		d, _, _ := unified_diff("a\nb\n", "a\nb\n", "x", "y")
		check(d == "", "diff: equal texts have none")
		add, rem: int
		d, add, rem = unified_diff("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n", "a/f", "b/f")
		want := "--- a/f\n+++ b/f\n@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+FIVE\n 6\n 7\n 8\n"
		check_eq(d, want, "diff: one changed line, three lines of context")
		check(add == 1 && rem == 1, "diff: counts")
		d, _, _ = unified_diff("", "hello\n", "a/f", "b/f")
		check_eq(d, "--- a/f\n+++ b/f\n@@ -0,0 +1,1 @@\n+hello\n", "diff: a new file")
		d, _, _ = unified_diff("a\n1\n2\n3\n4\n5\n6\n7\n8\nb\n", "A\n1\n2\n3\n4\n5\n6\n7\n8\nB\n", "a/f", "b/f")
		check(strings.count(d, "@@ ") == 2, "diff: changes far apart are two hunks")
	}
}

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
run :: proc(dir: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, fmt.tprintf("cd %q && WAYLAND_DISPLAY= DISPLAY= PALM_AUDIT=%q/audit.jsonl", dir, dir))
	strings.write_string(&line, fmt.tprintf(" %q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(out: string, fields: []kit.Field) -> bool {
	return len(kit.cli_validate_output(out, fields, context.temp_allocator)) == 0
}

@(private = "file")
slurp :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

SAMPLE :: "package demo\n\nmain :: proc() {\n\tx := foo(1, [2]int{3, 4})\n\t// teh brace } in a comment\n\ts := \"teh ) string\"\n}\n"

test_cli :: proc() {
	dir := fmt.tprintf("/tmp/editor-selftest-cli-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	src := fmt.tprintf("%s/a.odin", dir)
	_ = os.write_entire_file(src, transmute([]u8)string(SAMPLE))

	sf := surface()
	check(sf.noun == "editor" && sf.gui && sf.takes_path && sf.selftest != nil, "cli: the surface is editor, with a window")
	for cmd in sf.commands {
		check(cmd.run != nil && cmd.summary != "" && len(cmd.out) > 0 && len(cmd.examples) > 0, fmt.tprintf("cli: %s is implemented, summarised, declares output, has an example", cmd.verb))
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {append(&args, w)}
			append(&args, "--parse-only")
			_, code := run(dir, ..args[:])
			check(words[0] == "editor" && code == 0, fmt.tprintf("cli: the example %q parses", ex))
		}
	}
	{
		out, code := run(dir, "--schema")
		_, perr := json.parse(transmute([]u8)out, .JSON, true, context.temp_allocator)
		check(code == 0 && perr == nil, "cli: --schema is JSON")
	}

	// --- reads -----------------------------------------------------------------
	{
		out, code := run(dir, "info", "a.odin", "--json")
		check(code == 0 && valid(out, INFO_FIELDS) && strings.contains(out, `"language": "Odin"`) && strings.contains(out, `"lines": 7`), "cli: info --json")
		out, code = run(dir, "cat", "a.odin", "--json")
		check(code == 0 && valid(out, CAT_FIELDS), "cli: cat --json")
		out, code = run(dir, "lines", "a.odin", "4:5", "--json")
		check(code == 0 && valid(out, LINES_FIELDS) && strings.contains(out, `"n": 5`) && !strings.contains(out, `"n": 6`), "cli: lines 4:5")
		_, code = run(dir, "lines", "a.odin", "9:12", "--json")
		check(code == kit.EXIT_USAGE, "cli: lines past the end is a usage error")
		out, code = run(dir, "search", "a.odin", "teh", "--json")
		check(code == 0 && valid(out, SEARCH_FIELDS) && strings.contains(out, `"count": 2`) && strings.contains(out, `"col": 5`), "cli: search, 1-based columns")
		out, code = run(dir, "syntax", "a.odin", "--lines", "5", "--json")
		check(code == 0 && valid(out, SYNTAX_FIELDS) && strings.contains(out, `"kind": "comment"`), "cli: syntax sees the comment")
		out, code = run(dir, "match", "a.odin", "3:16", "--json")
		checkf(code == 0 && valid(out, MATCH_FIELDS) && strings.contains(out, `"match": "7:1"`), "cli: match skips the } in the comment (%s)", strings.trim_space(out))
		out, code = run(dir, "langs", "--json")
		check(code == 0 && valid(out, LANGS_FIELDS) && strings.contains(out, `".odin"`), "cli: langs")
		_, code = run(dir, "info", "nope.txt", "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: a missing file exits 3")
		_, code = run(dir, "info", dir, "--json")
		check(code == kit.EXIT_USAGE, "cli: a folder is a usage error")
	}

	// --- changes ----------------------------------------------------------------
	{
		out, code := run(dir, "replace", "a.odin", "teh", "the", "--dry-run", "--json")
		check(code == 0 && valid(out, CHANGE_FIELDS) && slurp(src) == SAMPLE, "cli: replace --dry-run writes nothing")
		check(strings.contains(out, `-\t// teh brace`) && strings.contains(out, `+\t// the brace`), "cli: and prints the diff")
		check(strings.contains(out, `"saved": false`), "cli: and says it saved nothing")

		// The command and the window leave the same bytes on disk.
		twin := fmt.tprintf("%s/twin.odin", dir)
		_ = os.write_entire_file(twin, transmute([]u8)string(SAMPLE))
		ed := Editor{}
		doc_open(&ed.buf, twin)
		append(&ed.find, ..transmute([]u8)string("TEH"))
		append(&ed.repl, ..transmute([]u8)string("the"))
		replace_all(&ed)
		do_save(&ed, twin)
		out, code = run(dir, "replace", "a.odin", "TEH", "the", "-i", "--json")
		check(code == 0 && strings.contains(out, `"count": 2`) && strings.contains(out, `"saved": true`), "cli: replace -i")
		check(slurp(src) == slurp(twin) && strings.contains(slurp(src), "the ) string"), "cli: replace leaves the bytes the window's Replace All + Save leaves")

		_, code = run(dir, "replace", "a.odin", "zzz", "y", "--json")
		check(code == kit.EXIT_NOT_FOUND, "cli: replacing nothing is not found")

		out, code = run(dir, "edit", "a.odin", "--from", "4:2", "--to", "4:3", "--text", "y", "--json")
		check(code == 0 && strings.contains(slurp(src), "\ty := foo"), "cli: edit --from --to")
		out, code = run(dir, "edit", "a.odin", "--lines", "5:6", "--text", "\\t// gone", "--json")
		check(code == 0 && strings.contains(slurp(src), "\t// gone\n}") && strings.contains(out, `"removed": 2`), "cli: edit --lines, \\t unescaped")
		before := slurp(src)
		_, code = run(dir, "edit", "a.odin", "--from", "99", "--text", "x", "--json")
		check(code == kit.EXIT_USAGE && slurp(src) == before, "cli: an edit outside the file is refused and writes nothing")
		_, code = run(dir, "edit", "fresh.md", "--from", "1", "--text", "# Hi", "--json")
		check(code == 0 && slurp(fmt.tprintf("%s/fresh.md", dir)) == "# Hi\n", "cli: edit creates a new file, with a final newline")

		out, code = run(dir, "save", "a.odin", "--eol", "crlf", "--json")
		check(code == 0 && valid(out, SAVE_FIELDS) && strings.contains(slurp(src), "\r\n"), "cli: save --eol crlf")
		out, code = run(dir, "save", "a.odin", "--eol", "crlf", "--json")
		check(code == 0 && strings.contains(out, `"changed": false`), "cli: and again changes nothing (idempotent)")
		_, code = run(dir, "save", "a.odin", "--to", "b.odin", "--eol", "lf", "--no-final-newline", "--json")
		b2 := slurp(fmt.tprintf("%s/b.odin", dir))
		check(code == 0 && !strings.contains(b2, "\r") && !strings.has_suffix(b2, "\n") && strings.contains(slurp(src), "\r\n"), "cli: save --to leaves the original alone")
		out, code = run(dir, "edit", "a.odin", "--from", "1:1", "--text", "// top\n", "--json")
		check(code == 0 && strings.has_prefix(slurp(src), "// top\r\npackage"), "cli: an edit keeps the file's CRLF")

		audit := slurp(fmt.tprintf("%s/audit.jsonl", dir))
		check(strings.contains(audit, `"verb": "replace"`) && !strings.contains(audit, `"verb": "info"`), "cli: changes are audited, reads are not")
	}

	test_cli_carets(dir)

	// --- the old command line ---------------------------------------------------------
	{
		_, code := run(dir, "--shots", "x", "--parse-only")
		check(code == 0, "cli: --shots <dir> still routes")
		_, code = run(dir, "--shots=x", "--parse-only")
		check(code == 0, "cli: --shots=<dir> too")
		_, code = run(dir, "--bench", "a.odin", "--parse-only")
		check(code == 0, "cli: --bench <file> too")
		bout, bcode := run(dir, "bench", "a.odin", "--json")
		check(bcode == 0 && strings.has_prefix(strings.trim_space(bout), "{") && strings.contains(bout, `"file"`), "cli: bench --json keeps its report off stdout")
		_, code = run(dir, "lnes")
		check(code == kit.EXIT_USAGE, "cli: a mistyped verb is a usage error, not a new file in a window")
	}
}

CARETS_SAMPLE :: "alpha beta\nalphabet soup\nx\n  beta alpha\nalpha\n"

// test_cli_carets checks `editor carets` against the window doing the same
// thing with its own gestures, byte for byte on disk.
@(private = "file")
test_cli_carets :: proc(dir: string) {
	f := fmt.tprintf("%s/c.txt", dir)
	twin := fmt.tprintf("%s/c-twin.txt", dir)
	reset :: proc(paths: ..string) {
		for p in paths {
			_ = os.write_entire_file(p, transmute([]u8)string(CARETS_SAMPLE))
		}
	}
	// The window, typing: one carets_edit per character, as keystrokes are.
	type_at_carets :: proc(ed: ^Editor, text: string) {
		for r in text {
			carets_edit(ed, .Insert, fmt.tprintf("%r", r))
		}
	}

	// Every whole-word occurrence: Ctrl Shift L on the first, then typing.
	reset(f, twin)
	out, code := run(dir, "carets", "c.txt", "--word", "alpha", "--text", "omega", "--json")
	check(code == 0 && valid(out, CHANGE_FIELDS) && strings.contains(out, `"count": 3`), "cli: carets --word puts a caret on each whole word")
	check(slurp(f) == "omega beta\nalphabet soup\nx\n  beta omega\nomega\n", "cli: and replaces each, leaving alphabet alone")
	{
		ed := Editor{}
		doc_open(&ed.buf, twin)
		ed.cur = {0, 2}
		caret_add_all(&ed)
		type_at_carets(&ed, "omega")
		do_save(&ed, twin)
		check(slurp(f) == slurp(twin), "cli: carets --word leaves the bytes Ctrl Shift L, typing and Save leave")
	}

	// A column: a caret per line, at character 3, a short line's at its end.
	reset(f, twin)
	out, code = run(dir, "carets", "c.txt", "--lines", "1:5", "--column", "3", "--text", "|", "--json")
	check(code == 0 && strings.contains(out, `"count": 5`), "cli: carets --lines --column puts one caret per line")
	check(slurp(f) == "al|pha beta\nal|phabet soup\nx|\n  |beta alpha\nal|pha\n", "cli: and a shorter line gets its caret at its end")
	{
		ed := Editor{}
		doc_open(&ed.buf, twin)
		ed.cur = {0, 2}
		ed.anchor = ed.cur
		ed.goal = 2
		for _ in 0 ..< 4 {
			caret_add_vert(&ed, 1)
		}
		type_at_carets(&ed, "|")
		do_save(&ed, twin)
		check(slurp(f) == slurp(twin), "cli: carets --lines leaves the bytes Ctrl Alt Down four times, typing and Save leave")
	}
	reset(f)
	out, code = run(dir, "carets", "c.txt", "--lines", "1:2", "--column", "3", "--delete", "2", "--json")
	check(code == 0 && strings.has_prefix(slurp(f), "ala beta\nalabet soup\nx\n"), "cli: carets --delete presses Delete at every caret")
	reset(f)
	out, code = run(dir, "carets", "c.txt", "--lines", "1:2", "--column", "3", "--backspace", "2", "--dry-run", "--json")
	check(code == 0 && slurp(f) == CARETS_SAMPLE && strings.contains(out, `+pha beta`), "cli: carets --backspace under --dry-run prints the diff and writes nothing")

	// Carets that land in one place are one caret, as in the window.
	reset(f)
	out, code = run(dir, "carets", "c.txt", "--at", "2:1", "--at", "2:1", "--at", "4:3", "--text", "- ", "--json")
	check(code == 0 && strings.contains(out, `"count": 2`), "cli: two carets at one place are merged")
	check(slurp(f) == "alpha beta\n- alphabet soup\nx\n  - beta alpha\nalpha\n", "cli: and the text goes in once there")

	// Refusals.
	reset(f)
	_, code = run(dir, "carets", "c.txt", "--at", "1:1", "--word", "alpha", "--text", "x", "--json")
	check(code == kit.EXIT_USAGE, "cli: carets refuses two ways of placing carets")
	_, code = run(dir, "carets", "c.txt", "--at", "1:1", "--json")
	check(code == kit.EXIT_USAGE, "cli: carets refuses no keystroke")
	_, code = run(dir, "carets", "c.txt", "--at", "1:1", "--column", "2", "--text", "x", "--json")
	check(code == kit.EXIT_USAGE, "cli: --column without --lines is a usage error")
	_, code = run(dir, "carets", "c.txt", "--word", "zeta", "--text", "x", "--json")
	check(code == kit.EXIT_NOT_FOUND, "cli: a --word that is not there is not found")
	_, code = run(dir, "carets", "c.txt", "--at", "9:1", "--text", "x", "--json")
	check(code == kit.EXIT_USAGE && slurp(f) == CARETS_SAMPLE, "cli: a caret outside the file is refused and nothing is written")

	// The decision written beside cmd_carets: no auto-close on the command
	// line. Text given is text inserted, a lone bracket included.
	_, code = run(dir, "carets", "c.txt", "--at", "1:6", "--text", "(", "--json")
	check(code == 0 && strings.has_prefix(slurp(f), "alpha( beta\n"), "cli: carets inserts a lone ( as given, never ()")
	reset(f)
	_, code = run(dir, "edit", "c.txt", "--from", "1:6", "--text", "[", "--json")
	check(code == 0 && strings.has_prefix(slurp(f), "alpha[ beta\n"), "cli: and so does edit")
}
