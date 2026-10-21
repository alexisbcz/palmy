package main

// The command-line front end of the editor.
//
// It edits files through the same procedures the window does: doc_open and
// doc_write (doc.odin) to load and save, buf_search and buf_replace_all for
// replace, buf_apply for any edit, lang_detect and the tokeniser for syntax,
// and the bracket matcher run against a real Editor value — there is nothing
// in an Editor that needs a window. So `editor replace foo bar -i` is the
// window's Find and Replace, F4, Save, and the self-test checks that the two
// leave the same bytes on disk.
//
// Positions are 1-based lines and 1-based characters (code points), which is
// what the status bar shows and what a person reads off a listing. Every
// command that changes a file prints the unified diff of what it changed, and
// under --dry-run prints that diff and writes nothing.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// What the commands print
// ---------------------------------------------------------------------------

INFO_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "exists", kind = .Bool},
	{name = "lines", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "language", kind = .String},
	{name = "highlighted", kind = .Bool, help = "the language has a highlighter"},
	{name = "eol", kind = .String, help = "lf or crlf"},
	{name = "encoding", kind = .String, help = "UTF-8 or Binary"},
	{name = "final_newline", kind = .Bool},
}

CAT_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "lines", kind = .Int},
	{name = "text", kind = .String},
}

LINE_ITEM :: []kit.Field {{name = "n", kind = .Int}, {name = "text", kind = .String}}

LINES_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "from", kind = .Int},
	{name = "to", kind = .Int},
	{name = "total", kind = .Int},
	{name = "lines", kind = .Array, of = LINE_ITEM},
}

SEARCH_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "needle", kind = .String},
	{name = "count", kind = .Int},
	{name = "truncated", kind = .Bool},
	{
		name = "matches",
		kind = .Array,
		of = {{name = "line", kind = .Int}, {name = "col", kind = .Int, help = "1-based character"}, {name = "text", kind = .String, help = "the whole line"}},
	},
}

CHANGE_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "changed", kind = .Bool},
	{name = "count", kind = .Int, help = "replacements, or 1 for an edit"},
	{name = "added", kind = .Int, help = "lines the diff adds"},
	{name = "removed", kind = .Int, help = "lines the diff removes"},
	{name = "diff", kind = .String, help = "unified diff of the change"},
	{name = "saved", kind = .Bool, help = "false under --dry-run, or when nothing changed"},
}

SAVE_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "bytes", kind = .Int},
	{name = "lines", kind = .Int},
	{name = "eol", kind = .String},
	{name = "final_newline", kind = .Bool},
	{name = "changed", kind = .Bool, help = "the bytes on disk are different now"},
}

TOKEN_ITEM :: []kit.Field {
	{name = "kind", kind = .String, help = "keyword, type, string, comment, number, …"},
	{name = "col", kind = .Int, help = "1-based character"},
	{name = "text", kind = .String},
}

SYNTAX_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "language", kind = .String},
	{name = "highlighted", kind = .Bool},
	{
		name = "lines",
		kind = .Array,
		of = {{name = "n", kind = .Int}, {name = "tokens", kind = .Array, of = TOKEN_ITEM}},
	},
}

MATCH_FIELDS :: []kit.Field {
	{name = "path", kind = .String},
	{name = "at", kind = .String, help = "the bracket, L:C"},
	{name = "bracket", kind = .String},
	{name = "match", kind = .String, help = "its partner, L:C"},
}

LANGS_FIELDS :: []kit.Field {
	{
		name = "languages",
		kind = .Array,
		of = {{name = "name", kind = .String}, {name = "extensions", kind = .Array, of = {{kind = .String}}}},
	},
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "a file as the status bar describes it: lines, bytes, language, line endings, encoding",
		effect = .Read,
		args = {{name = "file", kind = .Path, required = true}},
		out = INFO_FIELDS,
		examples = {"editor info /etc/hostname --json"},
		run = cmd_info,
	},
	{
		verb = "cat",
		summary = "the whole text, as the buffer holds it",
		effect = .Read,
		args = {{name = "file", kind = .Path, required = true}},
		out = CAT_FIELDS,
		examples = {"editor cat /etc/hostname --json"},
		run = cmd_cat,
	},
	{
		verb = "lines",
		summary = "a range of lines, numbered: 10:20, 10,+5, 40:$, or one line",
		effect = .Read,
		aliases = {"range"},
		args = {{name = "file", kind = .Path, required = true}, {name = "range", kind = .String, required = true}},
		out = LINES_FIELDS,
		examples = {"editor lines /etc/hostname 1:1 --json"},
		run = cmd_lines,
	},
	{
		verb = "search",
		summary = "every match of a string, with its line and column",
		effect = .Read,
		aliases = {"find"},
		args = {{name = "file", kind = .Path, required = true}, {name = "needle", kind = .String, required = true}},
		flags = {
			{name = "ignore-case", short = "i", kind = .Bool, help = "fold case, as the window's Find does"},
			{name = "limit", kind = .Int, def = "500", help = "at most this many; 0 is no limit"},
		},
		out = SEARCH_FIELDS,
		examples = {"editor search /etc/hostname a --json"},
		run = cmd_search,
	},
	{
		verb = "replace",
		summary = "replace every match (Find and Replace, then Save); --dry-run prints the diff and writes nothing",
		effect = .Mutate,
		args = {
			{name = "file", kind = .Path, required = true},
			{name = "needle", kind = .String, required = true},
			{name = "with", kind = .String, required = true, help = "the replacement; may be empty"},
		},
		flags = {
			{name = "ignore-case", short = "i", kind = .Bool, help = "fold case, as the window's replace does"},
			{name = "limit", kind = .Int, def = "0", help = "only the first N matches; 0 is all"},
		},
		out = CHANGE_FIELDS,
		examples = {"editor replace notes.txt teh the --dry-run --json", "editor replace main.odin old_name new_name --json"},
		run = cmd_replace,
	},
	{
		verb = "edit",
		summary = "apply one edit: replace --from..--to (or whole --lines) with --text; insert when there is no --to",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, required = true, help = "created if it does not exist, as the window does"}},
		flags = {
			{name = "from", kind = .String, help = "L or L:C, 1-based"},
			{name = "to", kind = .String, help = "L or L:C, exclusive; omit to insert at --from"},
			{name = "lines", kind = .String, help = "replace these whole lines instead: 3:5, 7, 2,+3"},
			{name = "text", kind = .String, help = "the new text; \\n is a newline"},
			{name = "text-file", kind = .Path, help = "read the new text from this file instead"},
		},
		out = CHANGE_FIELDS,
		examples = {"editor edit notes.txt --from 1:1 --text \"# Notes\\n\" --json", "editor edit main.odin --lines 10:12 --text \"\" --dry-run --json"},
		run = cmd_edit,
	},
	{
		verb = "save",
		summary = "load and write a file back through the editor: normalise line endings and the final newline, or save as",
		effect = .Idempotent,
		args = {{name = "file", kind = .Path, required = true}},
		flags = {
			{name = "to", kind = .Path, help = "save as this path instead (the original is left alone)"},
			{name = "eol", kind = .Enum, values = {"lf", "crlf"}, help = "line endings to write"},
			{name = "final-newline", kind = .Bool, help = "end with a newline (--no-final-newline to drop it)"},
		},
		out = SAVE_FIELDS,
		examples = {"editor save notes.txt --eol lf --json", "editor save draft.md --to final.md --json"},
		run = cmd_save,
	},
	{
		verb = "syntax",
		summary = "the language and the tokens the highlighter sees, per line",
		effect = .Read,
		args = {{name = "file", kind = .Path, required = true}},
		flags = {
			{name = "lines", kind = .String, def = "1:50", help = "which lines: 1:50, 10,+5, 40:$"},
			{name = "lang", kind = .Enum, values = {"plain", "odin", "c", "json", "markdown", "python", "shell"}, help = "override the detected language (Change Language)"},
		},
		out = SYNTAX_FIELDS,
		examples = {"editor syntax /etc/hostname --json"},
		run = cmd_syntax,
	},
	{
		verb = "match",
		summary = "the bracket matching the one at L:C, skipping brackets in strings and comments",
		effect = .Read,
		args = {{name = "file", kind = .Path, required = true}, {name = "at", kind = .String, required = true, help = "L:C, 1-based"}},
		out = MATCH_FIELDS,
		examples = {"editor match main.odin 12:20 --json"},
		run = cmd_match,
	},
	{
		verb = "langs",
		summary = "the languages the editor highlights, and the names it knows them by",
		effect = .Read,
		out = LANGS_FIELDS,
		examples = {"editor langs --json"},
		run = cmd_langs,
	},
	{
		verb = "shots",
		summary = "render the editor offscreen into PNGs, over a built-in sample file",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, required = true}},
		out = {{name = "dir", kind = .String}},
		examples = {"editor shots /tmp/editor-shots"},
		run = cmd_shots,
	},
	{
		verb = "bench",
		summary = "time the buffer on a file (load, edits, undo, search), as text",
		effect = .Read,
		hidden = true,
		aliases = {"--bench"},
		args = {{name = "file", kind = .Path, required = true}},
		out = {{name = "file", kind = .String}},
		examples = {"editor bench /etc/hostname"},
		run = cmd_bench,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "editor",
			summary    = "a text editor: read, search, replace and edit files, with the window's own buffer",
			gui        = true,
			takes_path = true,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Positions are 1-based: a line, or line:character. A change prints the
unified diff of what it did; --dry-run prints the diff and writes nothing. A bare
path opens the window on it, and a path that does not exist yet is a new file:
editor notes.txt`

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// open_existing loads a file a read command was pointed at.
// It answers the exit code: EXIT_OK, or the refusal it has recorded.
@(private = "file")
open_existing :: proc(c: ^kit.Call, b: ^Buffer) -> int {
	path := kit.cli_str(c, "file")
	if os.is_directory(path) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", path)
	}
	if !doc_open(b, path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	return kit.EXIT_OK
}

@(private = "file")
eol_name :: proc(b: ^Buffer) -> string {
	return b.eol == .CRLF ? "crlf" : "lf"
}

// unescape turns the two escapes a shell makes awkward into what they mean.
@(private = "file")
unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n')
				i += 1
				continue
			case 't':
				strings.write_byte(&sb, '\t')
				i += 1
				continue
			case '\\':
				strings.write_byte(&sb, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// finish is the end of every command that changes a file: diff the bytes the
// buffer would write against the bytes it was loaded from, write them through
// doc_write unless this is a dry run, and report.
@(private = "file")
finish :: proc(c: ^kit.Call, b: ^Buffer, before: string, count: int) -> int {
	after := buf_serialize(b, context.temp_allocator)
	name := base_of(b.path)
	diff, added, removed := unified_diff(before, after, fmt.tprintf("a/%s", name), fmt.tprintf("b/%s", name))
	changed := before != after
	saved := false
	if changed && !c.dry_run {
		if ok, why := doc_write(b, b.path); !ok {
			return kit.cli_fail(c, kit.EXIT_FAILED, why)
		}
		saved = true
	}
	kit.jset_str(c.out, "path", b.path)
	kit.jset_bool(c.out, "changed", changed)
	kit.jset_int(c.out, "count", count)
	kit.jset_int(c.out, "added", added)
	kit.jset_int(c.out, "removed", removed)
	kit.jset_str(c.out, "diff", diff)
	kit.jset_bool(c.out, "saved", saved)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	lang := doc_lang(&b)
	kit.jset_str(c.out, "path", b.path)
	kit.jset_bool(c.out, "exists", true)
	kit.jset_int(c.out, "lines", buf_line_count(&b))
	kit.jset_int(c.out, "bytes", buf_byte_size(&b))
	kit.jset_str(c.out, "language", lang_name(lang))
	kit.jset_bool(c.out, "highlighted", lang_highlights(lang))
	kit.jset_str(c.out, "eol", eol_name(&b))
	kit.jset_str(c.out, "encoding", b.encoding)
	kit.jset_bool(c.out, "final_newline", b.final_nl)
	return kit.EXIT_OK
}

@(private = "file")
cmd_cat :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	kit.jset_str(c.out, "path", b.path)
	kit.jset_int(c.out, "lines", buf_line_count(&b))
	kit.jset_str(c.out, "text", buf_serialize(&b, context.temp_allocator))
	return kit.EXIT_OK
}

@(private = "file")
cmd_lines :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	first, last, ok := parse_range(&b, kit.cli_str(c, "range"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a range of lines in a %d-line file", kit.cli_str(c, "range"), buf_line_count(&b))
	}
	arr := kit.jarr()
	for n in first ..= last {
		o := kit.jobj()
		kit.jset_int(o, "n", n)
		kit.jset_str(o, "text", buf_line(&b, n - 1))
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "path", b.path)
	kit.jset_int(c.out, "from", first)
	kit.jset_int(c.out, "to", last)
	kit.jset_int(c.out, "total", buf_line_count(&b))
	kit.jset(c.out, "lines", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	needle := unescape(kit.cli_str(c, "needle"))
	if strings.index_byte(needle, '\n') >= 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a search is within one line; the needle has a newline")
	}
	found, truncated := buf_find_all(&b, needle, kit.cli_bool(c, "ignore-case"), kit.cli_int(c, "limit", 500))
	arr := kit.jarr()
	for m in found {
		o := kit.jobj()
		line := buf_line(&b, m.at.line)
		kit.jset_int(o, "line", m.at.line + 1)
		kit.jset_int(o, "col", col_to_char(line, m.at.col))
		kit.jset_str(o, "text", line)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "path", b.path)
	kit.jset_str(c.out, "needle", needle)
	kit.jset_int(c.out, "count", len(found))
	kit.jset_bool(c.out, "truncated", truncated)
	kit.jset(c.out, "matches", arr)
	return kit.EXIT_OK
}

@(private = "file")
TOK_NAMES := [Tok]string {
	.Plain     = "plain",
	.Keyword   = "keyword",
	.Type      = "type",
	.Builtin   = "builtin",
	.Number    = "number",
	.Str       = "string",
	.Rune_Lit  = "rune",
	.Comment   = "comment",
	.Directive = "directive",
	.Punct     = "punctuation",
	.Call      = "call",
	.Decl      = "declaration",
	.Key       = "key",
	.Heading   = "heading",
	.Emph      = "emphasis",
	.Strong    = "strong",
	.Code      = "code",
	.Link      = "link",
	.Marker    = "marker",
}

@(private = "file")
LANG_FLAGS := [Lang]string {
	.Plain    = "plain",
	.Odin     = "odin",
	.C        = "c",
	.JSON     = "json",
	.Markdown = "markdown",
	.Python   = "python",
	.Shell    = "shell",
}

@(private = "file")
cmd_syntax :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	lang := doc_lang(&b)
	if kit.cli_has(c, "lang") {
		for name, l in LANG_FLAGS {
			if name == kit.cli_str(c, "lang") {
				lang = l
			}
		}
	}
	first, last, ok := parse_range(&b, kit.cli_str(c, "lines"))
	if !ok {
		// The default asks for 1:50 of whatever there is; a short file is fine.
		if f, l, ok2 := parse_range(&b, fmt.tprintf("1:%d", buf_line_count(&b))); ok2 && !kit.cli_has(c, "lines") {
			first, last = f, l
		} else {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a range of lines in a %d-line file", kit.cli_str(c, "lines"), buf_line_count(&b))
		}
	}
	arr := kit.jarr()
	toks := make([dynamic]Token, 0, 64, context.temp_allocator)
	for n in first ..= last {
		li := n - 1
		src := buf_line(&b, li)
		clear(&toks)
		// The entry state comes from the same per-line cache the window draws
		// from, so a line inside a block comment is lexed as one here too.
		lex_line(src, lex_state_at(&b, li, lang), &toks, lang)
		tarr := kit.jarr()
		for t in toks {
			o := kit.jobj()
			kit.jset_str(o, "kind", TOK_NAMES[t.kind])
			kit.jset_int(o, "col", col_to_char(src, t.from))
			kit.jset_str(o, "text", src[t.from:min(t.to, len(src))])
			kit.jpush(tarr, o)
		}
		lo := kit.jobj()
		kit.jset_int(lo, "n", n)
		kit.jset(lo, "tokens", tarr)
		kit.jpush(arr, lo)
	}
	kit.jset_str(c.out, "path", b.path)
	kit.jset_str(c.out, "language", lang_name(lang))
	kit.jset_bool(c.out, "highlighted", lang_highlights(lang))
	kit.jset(c.out, "lines", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_match :: proc(c: ^kit.Call) -> int {
	ed := Editor{}
	if code := open_existing(c, &ed.buf); code != kit.EXIT_OK {
		return code
	}
	ed.lang = doc_lang(&ed.buf)
	at, ok := parse_pos(&ed.buf, kit.cli_str(c, "at"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a position in this file (L:C, 1-based)", kit.cli_str(c, "at"))
	}
	// The window's Ctrl M, on an Editor with no window: the caret on the
	// bracket, the matcher asked for its pair.
	ed.cur = at
	a, m, found := bracket_pair_at_caret(&ed)
	if !found {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no bracket with a partner at that position")
	}
	pos_str :: proc(b: ^Buffer, q: Pos) -> string {
		return fmt.tprintf("%d:%d", q.line + 1, col_to_char(buf_line(b, q.line), q.col))
	}
	kit.jset_str(c.out, "path", ed.buf.path)
	kit.jset_str(c.out, "at", pos_str(&ed.buf, a))
	kit.jset_str(c.out, "bracket", buf_line(&ed.buf, a.line)[a.col:a.col + 1])
	kit.jset_str(c.out, "match", pos_str(&ed.buf, m))
	return kit.EXIT_OK
}

@(private = "file")
cmd_langs :: proc(c: ^kit.Call) -> int {
	arr := kit.jarr()
	for l in Lang {
		o := kit.jobj()
		kit.jset_str(o, "name", lang_name(l))
		exts := kit.jarr()
		for e in EXTENSIONS {
			if e.lang == l {
				kit.jpush(exts, kit.jstr(e.ext))
			}
		}
		for n in NAMED_FILES {
			if n.lang == l {
				kit.jpush(exts, kit.jstr(n.ext))
			}
		}
		kit.jset(o, "extensions", exts)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "languages", arr)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Changing
// ---------------------------------------------------------------------------

@(private = "file")
cmd_replace :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	needle := unescape(kit.cli_str(c, "needle"))
	with := unescape(kit.cli_str(c, "with"))
	if needle == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "nothing to replace: the needle is empty")
	}
	if strings.index_byte(needle, '\n') >= 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a search is within one line; the needle has a newline")
	}
	before := buf_serialize(&b, context.temp_allocator)
	n, _ := buf_replace_all(&b, needle, with, kit.cli_bool(c, "ignore-case"), {0, 0}, kit.cli_int(c, "limit"))
	if n == 0 {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%q does not occur in %s", needle, b.path)
		kit.cli_err_field(c, "needle", needle)
		return code
	}
	return finish(c, &b, before, n)
}

@(private = "file")
cmd_edit :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	if os.is_directory(path) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is a folder", path)
	}
	b: Buffer
	existed := doc_open(&b, path)
	before := existed ? buf_serialize(&b, context.temp_allocator) : ""
	if !existed {
		// A new file starts empty and gets a final newline, as the window's do.
		b.final_nl = true
	}

	text := unescape(kit.cli_str(c, "text"))
	if kit.cli_has(c, "text-file") {
		data, err := os.read_entire_file_from_path(kit.cli_str(c, "text-file"), context.temp_allocator)
		if err != nil {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", kit.cli_str(c, "text-file"))
		}
		text = string(data)
	} else if !kit.cli_has(c, "text") {
		return kit.cli_fail(c, kit.EXIT_USAGE, "edit needs --text or --text-file (\"\" deletes)")
	}
	// The buffer keeps \n inside; the file's own line ending goes back on at
	// save time, so a CRLF file stays CRLF.
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)

	switch {
	case kit.cli_has(c, "lines"):
		if kit.cli_has(c, "from") || kit.cli_has(c, "to") {
			return kit.cli_fail(c, kit.EXIT_USAGE, "--lines or --from/--to, not both")
		}
		first, last, ok := parse_range(&b, kit.cli_str(c, "lines"))
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a range of lines in a %d-line file", kit.cli_str(c, "lines"), buf_line_count(&b))
		}
		buf_replace_lines(&b, first, last, strings.trim_suffix(text, "\n"), {0, 0})
	case kit.cli_has(c, "from"):
		from, ok := parse_pos(&b, kit.cli_str(c, "from"))
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "--from %q is not in this file (L or L:C, 1-based)", kit.cli_str(c, "from"))
		}
		to := from
		if kit.cli_has(c, "to") {
			t, tok := parse_pos(&b, kit.cli_str(c, "to"))
			if !tok {
				return kit.cli_failf(c, kit.EXIT_USAGE, "--to %q is not in this file (L or L:C, 1-based)", kit.cli_str(c, "to"))
			}
			if pos_less(t, from) {
				return kit.cli_fail(c, kit.EXIT_USAGE, "--to is before --from")
			}
			to = t
		}
		buf_apply(&b, from, to, text, from, .No)
	case:
		return kit.cli_fail(c, kit.EXIT_USAGE, "edit needs --from (and maybe --to) or --lines")
	}
	return finish(c, &b, before, 1)
}

@(private = "file")
cmd_save :: proc(c: ^kit.Call) -> int {
	b: Buffer
	if code := open_existing(c, &b); code != kit.EXIT_OK {
		return code
	}
	src := b.path
	before := buf_serialize(&b, context.temp_allocator)
	if kit.cli_has(c, "eol") {
		b.eol = kit.cli_str(c, "eol") == "crlf" ? .CRLF : .LF
	}
	if kit.cli_has(c, "final-newline") {
		buf_set_final_newline(&b, kit.cli_bool(c, "final-newline"))
	}
	dest := src
	if kit.cli_has(c, "to") {
		dest = kit.cli_str(c, "to")
	}
	after := buf_serialize(&b, context.temp_allocator)
	on_disk := ""
	if dest != src {
		if data, err := os.read_entire_file_from_path(dest, context.temp_allocator); err == nil {
			on_disk = string(data)
		}
	} else {
		on_disk = before
	}
	changed := after != on_disk || (dest != src && !os.exists(dest))
	if !c.dry_run && changed {
		if ok, why := doc_write(&b, dest); !ok {
			return kit.cli_fail(c, kit.EXIT_FAILED, why)
		}
	}
	kit.jset_str(c.out, "path", dest)
	kit.jset_int(c.out, "bytes", len(after))
	kit.jset_int(c.out, "lines", buf_line_count(&b))
	kit.jset_str(c.out, "eol", eol_name(&b))
	kit.jset_bool(c.out, "final_newline", b.final_nl)
	kit.jset_bool(c.out, "changed", changed)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	if !c.dry_run && shots(dir) != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write PNGs into %s", dir)
	}
	kit.jset_str(c.out, "dir", dir)
	return kit.EXIT_OK
}

@(private = "file")
cmd_bench :: proc(c: ^kit.Call) -> int {
	run_bench(kit.cli_str(c, "file"))
	kit.jset_str(c.out, "file", kit.cli_str(c, "file"))
	return kit.EXIT_OK
}
