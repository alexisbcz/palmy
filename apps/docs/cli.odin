package main

// The command-line front end of Docs.
//
// Nothing below re-implements the word processor. A document is read through
// doc_read and written through doc_export (main.odin), which are what the
// window's Open, Save and Export entries call; pages are counted from the
// same layout the window draws, built by headless_open with the window's font
// table; `find` is the find bar's own walk (find_set, find_all) and `replace`
// is its Replace All (replace_all), one undo step and all; `lint` is the same
// vale run the prose panel makes. So `docs replace` and pressing F12 in the
// window cannot drift, because there is only one replace.
//
// The older spellings --convert, --export-png, --shots, --lint and --bench are
// aliases of the commands of the same name, so every invocation that worked
// before still does (`apps/reader`'s self-test runs `docs --convert md pdf`).
//
// Where a read command is given no file it reads the document a fresh window
// opens with, so every read works on a machine with no documents on it — which
// is also what makes them testable without touching anybody's files.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// Declared output. Declared before COMMANDS, because package initialisers run
// in declaration order and a command pointing at a list declared after it
// would capture it empty.
// ---------------------------------------------------------------------------

INFO_FIELDS := []kit.Field {
	{name = "file", kind = .String, help = "the file read, or \"(welcome)\" for the built-in document"},
	{name = "format", kind = .String, help = "json, markdown, docx, odt or rtf"},
	{name = "title", kind = .String, help = "the first heading, or the file name"},
	{name = "paragraphs", kind = .Int, help = "top-level paragraphs, a table or a picture counting as one"},
	{name = "blocks", kind = .Int, help = "text blocks, counting each paragraph inside a table cell"},
	{name = "words", kind = .Int},
	{name = "characters", kind = .Int},
	{name = "lines", kind = .Int, help = "laid-out lines, as the window wraps them"},
	{name = "pages", kind = .Int, help = "A4 pages, as the window paginates them"},
	{name = "tables", kind = .Int},
	{name = "images", kind = .Int},
	{
		name = "headings",
		kind = .Array,
		help = "the outline",
		of = {
			{name = "level", kind = .Int, help = "1, 2 or 3"},
			{name = "text", kind = .String},
			{name = "para", kind = .Int, help = "its paragraph index"},
		},
	},
}

TEXT_FIELDS := []kit.Field {
	{name = "file", kind = .String},
	{name = "format", kind = .String, help = "plain or markdown"},
	{name = "text", kind = .String},
}

FIND_FIELDS := []kit.Field {
	{name = "file", kind = .String},
	{name = "pattern", kind = .String},
	{name = "mode", kind = .String, help = "the find bar's own mode label: .* regex, Aa case, W whole words, — none"},
	{name = "count", kind = .Int, help = "every match in the document, what the find bar would show"},
	{
		name = "matches",
		kind = .Array,
		help = "in reading order, up to --limit",
		of = {
			{name = "para", kind = .Int, help = "top-level paragraph"},
			{name = "row", kind = .Int, help = "table row, 0 outside a table"},
			{name = "col", kind = .Int, help = "table column, 0 outside a table"},
			{name = "cpara", kind = .Int, help = "paragraph inside the cell, 0 outside a table"},
			{name = "from", kind = .Int, help = "byte offset in the block"},
			{name = "to", kind = .Int},
			{name = "match", kind = .String},
			{name = "context", kind = .String, help = "the block's text around the match"},
		},
	},
}

REPLACE_FIELDS := []kit.Field {
	{name = "file", kind = .String},
	{name = "out", kind = .String, help = "where the result was (or would be) written"},
	{name = "pattern", kind = .String},
	{name = "replacement", kind = .String},
	{name = "mode", kind = .String},
	{name = "replaced", kind = .Int},
	{name = "written", kind = .Bool, help = "false under --dry-run or when nothing matched"},
}

CONVERT_FIELDS := []kit.Field {
	{name = "from", kind = .String},
	{name = "to", kind = .String},
	{name = "format", kind = .String, help = "the format written"},
	{name = "paragraphs", kind = .Int},
	{name = "pages", kind = .Int},
	{name = "written", kind = .Bool},
}

NEW_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "format", kind = .String},
	{name = "title", kind = .String},
	{name = "paragraphs", kind = .Int},
	{name = "written", kind = .Bool},
}

PNG_FIELDS := []kit.Field {
	{name = "file", kind = .String},
	{name = "base", kind = .String},
	{name = "pages", kind = .Int},
	{name = "written", kind = .Array, of = {{kind = .String}}},
}

LINT_FIELDS := []kit.Field {
	{name = "file", kind = .String},
	{name = "engine", kind = .String, help = "vale"},
	{name = "config", kind = .String, help = "the .vale.ini that applied"},
	{name = "style", kind = .String, help = "Palm for the built-in package, \"\" for a project's own"},
	{name = "blocks", kind = .Int},
	{name = "blocks_unchecked", kind = .Int, help = "code, pictures and grids, which are not prose"},
	{
		name = "counts",
		kind = .Object,
		of = {
			{name = "error", kind = .Int},
			{name = "warning", kind = .Int},
			{name = "suggestion", kind = .Int},
		},
	},
	{
		name = "alerts",
		kind = .Array,
		of = {
			{name = "rule", kind = .String},
			{name = "severity", kind = .String},
			{name = "message", kind = .String},
			{name = "match", kind = .String},
			{name = "para", kind = .Int},
			{name = "row", kind = .Int},
			{name = "col", kind = .Int},
			{name = "cpara", kind = .Int},
			{name = "from", kind = .Int},
			{name = "to", kind = .Int},
			{name = "line", kind = .Int, help = "vale's coordinates in the text it was given"},
			{name = "column", kind = .Int},
			{name = "replacement", kind = .String, opt = true},
		},
	},
}

SHOTS_FIELDS := []kit.Field {
	{name = "dir", kind = .String},
	{name = "written", kind = .Array, of = {{kind = .String}}},
}

BENCH_FIELDS := []kit.Field {
	{name = "paragraphs", kind = .Int},
	{name = "words", kind = .Int},
	{name = "characters", kind = .Int},
	{name = "lines", kind = .Int},
	{name = "pages", kind = .Int},
	{name = "runs", kind = .Int},
	{name = "first_layout_ms", kind = .Float},
	{name = "warm_layout_ms", kind = .Float},
	{name = "keystroke_ms", kind = .Float, help = "one typed key plus a relayout"},
	{name = "keys", kind = .Int},
	{name = "undo_ms", kind = .Float},
	{name = "undos", kind = .Int},
	{name = "draw_ms", kind = .Float},
	{name = "draw_size", kind = .String},
}

FORMATS_FIELDS := []kit.Field {
	{
		name = "formats",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "extensions", kind = .Array, of = {{kind = .String}}},
			{name = "read", kind = .Bool},
			{name = "write", kind = .Bool},
		},
	},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "a document's counts, pages and outline, as the window lays it out",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = ".json .md .docx .odt or .rtf; the welcome document when absent"}},
		out = INFO_FIELDS,
		examples = {"docs info --json", "docs info report.docx --json"},
		run = cmd_info,
	},
	{
		verb = "text",
		summary = "a document's text, plain or as Markdown",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "the document; the welcome document when absent"}},
		flags = {{name = "format", kind = .Enum, values = {"plain", "markdown"}, def = "plain", help = "how to write it out"}},
		out = TEXT_FIELDS,
		examples = {"docs text --json", "docs text report.docx --format markdown --json"},
		run = cmd_text,
	},
	{
		verb = "find",
		summary = "every match of a term, with the find bar's options",
		effect = .Read,
		args = {
			{name = "pattern", kind = .String, help = "the term, or a regular expression with --regex", required = true},
			{name = "file", kind = .Path, help = "the document; the welcome document when absent"},
		},
		flags = {
			{name = "regex", kind = .Bool, help = "the pattern is a regular expression; \\1..\\9 in a replacement are its groups"},
			{name = "case", kind = .Bool, help = "match case"},
			{name = "word", kind = .Bool, help = "whole words only"},
			{name = "limit", kind = .Int, def = "0", help = "list at most this many; count still counts them all"},
		},
		out = FIND_FIELDS,
		examples = {"docs find pagination --json", "docs find \"\\bpage\\w*\" --regex --json", "docs find colour report.md --word --json"},
		run = cmd_find,
	},
	{
		verb = "replace",
		summary = "Replace All, as the window does it, then save",
		effect = .Mutate,
		args = {
			{name = "pattern", kind = .String, help = "the term, or a regular expression with --regex", required = true},
			{name = "with", kind = .String, help = "the replacement; \\1..\\9 are groups under --regex", required = true},
			{name = "file", kind = .Path, help = "the document to change", required = true},
		},
		flags = {
			{name = "regex", kind = .Bool, help = "the pattern is a regular expression; \\1..\\9 in a replacement are its groups"},
			{name = "case", kind = .Bool, help = "match case"},
			{name = "word", kind = .Bool, help = "whole words only"},
			{name = "out", kind = .Path, help = "write the result here instead of over the file; the format follows its extension"},
		},
		out = REPLACE_FIELDS,
		examples = {
			"docs replace colour color notes.md --json",
			"docs replace \"(\\w+)@example\" \"\\1@example.org\" notes.md --regex --dry-run --json",
			"docs replace Draft Final report.docx --out final.docx --json",
		},
		run = cmd_replace,
	},
	{
		verb = "convert",
		summary = "read one file and write another; each format follows its extension",
		effect = .Mutate,
		args = {
			{name = "in", kind = .Path, help = ".json .md .docx .odt .rtf", required = true},
			{name = "out", kind = .Path, help = ".json .md .html .pdf .docx .odt .rtf", required = true},
		},
		out = CONVERT_FIELDS,
		examples = {"docs convert notes.md notes.pdf --json", "docs --convert report.docx report.md"},
		aliases = {"--convert"},
		run = cmd_convert,
	},
	{
		verb = "new",
		summary = "write a new document from Markdown text, in any writable format",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, help = "where to write it; the format follows the extension", required = true}},
		flags = {
			{name = "markdown", kind = .String, help = "the content, as Markdown (\\n for a new line)"},
			{name = "file", kind = .Path, help = "read the Markdown from this file instead"},
			{name = "force", kind = .Bool, help = "overwrite a file that is already there"},
		},
		out = NEW_FIELDS,
		examples = {"docs new memo.docx --markdown \"# Memo\\n\\nThe meeting moved to Tuesday.\" --json"},
		run = cmd_new,
	},
	{
		verb = "export-png",
		summary = "render every page to <base>-pN.png",
		effect = .Mutate,
		args = {
			{name = "file", kind = .Path, help = "the document", required = true},
			{name = "base", kind = .String, help = "the path prefix for the images", required = true},
		},
		out = PNG_FIELDS,
		examples = {"docs export-png report.md /tmp/report --json", "docs --export-png report.md /tmp/report"},
		aliases = {"--export-png"},
		run = cmd_export_png,
	},
	{
		verb = "lint",
		summary = "prose problems, through vale, mapped back onto the document",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "the document; the welcome document when absent"}},
		flags = {{name = "strict", kind = .Bool, help = "exit 7 when there is an error-level alert, as --lint used to"}},
		out = LINT_FIELDS,
		examples = {"docs lint --json", "docs lint report.md --json", "docs --lint report.md --json"},
		aliases = {"--lint"},
		run = cmd_lint,
	},
	{
		verb = "formats",
		summary = "what can be read and written",
		effect = .Read,
		out = FORMATS_FIELDS,
		examples = {"docs formats --json"},
		run = cmd_formats,
	},
	{
		verb = "shots",
		summary = "render the interface offscreen to PNGs; no window, nothing on screen",
		effect = .Mutate,
		args = {{name = "dir", kind = .Path, help = "where to write them", def = "docs-shots"}},
		out = SHOTS_FIELDS,
		examples = {"docs shots /tmp/docs-shots --json", "docs --shots /tmp/docs-shots"},
		aliases = {"--shots"},
		run = cmd_shots,
	},
	{
		verb = "bench",
		summary = "layout, typing, undo and drawing throughput over a generated document",
		effect = .Read,
		args = {{name = "paragraphs", kind = .Int, help = "how long a document", def = "400"}},
		out = BENCH_FIELDS,
		examples = {"docs bench --json", "docs bench 2000 --json", "docs --bench 400"},
		aliases = {"--bench"},
		run = cmd_bench,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "docs",
			summary    = "a word processor with a headless converter",
			gui        = true,
			// `docs report.docx` opens the file in the window.
			takes_path = true,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command, docs opens a window; a path opens that file in it, and
--collab <id|new> [--as NAME] [--offline] joins a shared document.
The older spellings --convert, --export-png, --shots, --lint and --bench are
aliases of the commands of the same name and keep working.

A read command given no file reads the document a fresh window opens with.
Formats: .json (native), .md, .docx, .odt and .rtf are read; those plus .html
and .pdf are written. Run with ulimit -s unlimited for --selftest: its
regular-expression section recurses past the default 8 MB stack.`

cli_selftest :: proc() -> int {
	return run_selftest() ? 0 : 1
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

WELCOME_LABEL :: "(welcome)"

// cli_open reads the named file — or, given none, the document a fresh window
// opens with — into a headless State laid out exactly as the window would.
@(private = "file")
cli_open :: proc(c: ^kit.Call, st: ^State, name: string) -> (label: string, code: int) {
	path := kit.cli_str(c, name)
	if path == "" {
		headless_open(st, doc_from_markdown(SEED))
		return WELCOME_LABEL, kit.EXIT_OK
	}
	if !os.exists(path) {
		return path, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	if !FORMAT_READS[format_of_path(path)] {
		return path, kit.cli_failf(c, kit.EXIT_USAGE, "%s is written, never read", FORMAT_NAMES[format_of_path(path)])
	}
	d, ok := doc_read(path)
	if !ok {
		return path, kit.cli_failf(c, kit.EXIT_FAILED, "cannot read %s", path)
	}
	headless_open(st, d)
	return path, kit.EXIT_OK
}

@(private = "file")
src_format :: proc(label: string) -> string {
	return label == WELCOME_LABEL ? "markdown" : FORMAT_NAMES[format_of_path(label)]
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	st := State{}
	label, code := cli_open(c, &st, "file")
	if code != kit.EXIT_OK {
		return code
	}
	defer state_destroy(&st)
	words, chars := doc_counts(&st.doc)
	tables, images := 0, 0
	heads := kit.jarr()
	for &pa, i in st.doc.paras {
		level := 0
		#partial switch pa.kind {
		case .H1:
			level = 1
		case .H2:
			level = 2
		case .H3:
			level = 3
		case .Table:
			tables += 1
		case .Image:
			images += 1
		}
		if level > 0 {
			h := kit.jobj()
			kit.jset_int(h, "level", level)
			kit.jset_str(h, "text", strings.trim_space(para_text(&pa, context.temp_allocator)))
			kit.jset_int(h, "para", i)
			kit.jpush(heads, h)
		}
	}
	kit.jset_str(c.out, "file", label)
	kit.jset_str(c.out, "format", src_format(label))
	kit.jset_str(c.out, "title", doc_display_title(&st.doc, label == WELCOME_LABEL ? "Untitled" : base_name(label)))
	kit.jset_int(c.out, "paragraphs", len(st.doc.paras))
	kit.jset_int(c.out, "blocks", len(doc_blocks(&st.doc, context.temp_allocator)))
	kit.jset_int(c.out, "words", words)
	kit.jset_int(c.out, "characters", chars)
	kit.jset_int(c.out, "lines", len(st.lay.lines))
	kit.jset_int(c.out, "pages", st.lay.pages)
	kit.jset_int(c.out, "tables", tables)
	kit.jset_int(c.out, "images", images)
	kit.jset(c.out, "headings", heads)
	return kit.EXIT_OK
}

@(private = "file")
cmd_text :: proc(c: ^kit.Call) -> int {
	st := State{}
	label, code := cli_open(c, &st, "file")
	if code != kit.EXIT_OK {
		return code
	}
	defer state_destroy(&st)
	format := kit.cli_str(c, "format")
	text: string
	if format == "markdown" {
		text = doc_to_markdown(&st.doc, context.temp_allocator)
	} else {
		b := strings.builder_make(context.temp_allocator)
		first := true
		for blk in doc_blocks(&st.doc, context.temp_allocator) {
			pa := blk_para(&st.doc, blk)
			if pa == nil || !text_kind(pa.kind) {
				continue
			}
			if !first {
				strings.write_byte(&b, '\n')
			}
			first = false
			strings.write_string(&b, para_text(pa, context.temp_allocator))
		}
		text = strings.to_string(b)
	}
	kit.jset_str(c.out, "file", label)
	kit.jset_str(c.out, "format", format)
	kit.jset_str(c.out, "text", text)
	return kit.EXIT_OK
}

// cli_find_setup puts the pattern and options into the find box.
@(private = "file")
cli_find_setup :: proc(c: ^kit.Call, st: ^State, repl: string) -> int {
	pattern := kit.cli_str(c, "pattern")
	if err := find_set(st, pattern, repl, kit.cli_bool(c, "case"), kit.cli_bool(c, "word"), kit.cli_bool(c, "regex")); err != "" {
		kit.cli_failf(c, kit.EXIT_USAGE, "the pattern does not compile: %s", err)
		kit.cli_err_field(c, "pattern", pattern)
		return kit.EXIT_USAGE
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_find :: proc(c: ^kit.Call) -> int {
	st := State{}
	label, code := cli_open(c, &st, "file")
	if code != kit.EXIT_OK {
		return code
	}
	defer state_destroy(&st)
	if e := cli_find_setup(c, &st, ""); e != kit.EXIT_OK {
		return e
	}
	limit := kit.cli_int(c, "limit")
	matches := kit.jarr()
	for h in find_all(&st, limit) {
		t := para_text(blk_para(&st.doc, h.blk), context.temp_allocator)
		m := kit.jobj()
		kit.jset_int(m, "para", h.blk.para)
		kit.jset_int(m, "row", h.blk.row)
		kit.jset_int(m, "col", h.blk.col)
		kit.jset_int(m, "cpara", h.blk.cpara)
		kit.jset_int(m, "from", h.lo)
		kit.jset_int(m, "to", h.hi)
		kit.jset_str(m, "match", t[h.lo:h.hi])
		kit.jset_str(m, "context", context_around(t, h.lo, h.hi))
		kit.jpush(matches, m)
	}
	kit.jset_str(c.out, "file", label)
	kit.jset_str(c.out, "pattern", kit.cli_str(c, "pattern"))
	kit.jset_str(c.out, "mode", find_mode_label(&st))
	kit.jset_int(c.out, "count", st.find_hits)
	kit.jset(c.out, "matches", matches)
	return kit.EXIT_OK
}

// context_around is up to 30 bytes either side of a match, cut on rune
// boundaries so the excerpt is always valid UTF-8.
@(private = "file")
context_around :: proc(t: string, lo, hi: int) -> string {
	a := max(0, lo - 30)
	for a > 0 && a < len(t) && (t[a] & 0xc0) == 0x80 {
		a -= 1
	}
	b := min(len(t), hi + 30)
	for b < len(t) && (t[b] & 0xc0) == 0x80 {
		b += 1
	}
	return t[a:b]
}

@(private = "file")
cmd_replace :: proc(c: ^kit.Call) -> int {
	st := State{}
	label, code := cli_open(c, &st, "file")
	if code != kit.EXIT_OK {
		return code
	}
	defer state_destroy(&st)
	if e := cli_find_setup(c, &st, kit.cli_str(c, "with")); e != kit.EXIT_OK {
		return e
	}
	out := kit.cli_has(c, "out") ? kit.cli_str(c, "out") : label
	n := replace_all(&st)
	written := false
	if n > 0 && !c.dry_run {
		f := format_of_path(out)
		if !doc_export(&st, out, f, doc_display_title(&st.doc, base_name(out))) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", out)
		}
		written = true
	}
	kit.jset_str(c.out, "file", label)
	kit.jset_str(c.out, "out", out)
	kit.jset_str(c.out, "pattern", kit.cli_str(c, "pattern"))
	kit.jset_str(c.out, "replacement", kit.cli_str(c, "with"))
	kit.jset_str(c.out, "mode", find_mode_label(&st))
	kit.jset_int(c.out, "replaced", n)
	kit.jset_bool(c.out, "written", written)
	return kit.EXIT_OK
}

@(private = "file")
cmd_convert :: proc(c: ^kit.Call) -> int {
	in_path, out_path := kit.cli_str(c, "in"), kit.cli_str(c, "out")
	if !os.exists(in_path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", in_path)
	}
	paras, pages, err := convert_file(in_path, out_path, c.dry_run)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.cli_trace(c, "%s -> %s (%d paragraphs)", in_path, out_path, paras)
	kit.jset_str(c.out, "from", in_path)
	kit.jset_str(c.out, "to", out_path)
	kit.jset_str(c.out, "format", FORMAT_NAMES[format_of_path(out_path)])
	kit.jset_int(c.out, "paragraphs", paras)
	kit.jset_int(c.out, "pages", pages)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

// unescape_newlines lets a one-line argument carry paragraphs: `\n` is a new
// line, `\\` a backslash.
@(private = "file")
unescape_newlines :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private = "file")
cmd_new :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	if os.exists(path) && !kit.cli_bool(c, "force") {
		kit.cli_failf(c, kit.EXIT_USAGE, "%s is already there; pass --force to overwrite it", path)
		return kit.EXIT_USAGE
	}
	md := unescape_newlines(kit.cli_str(c, "markdown"))
	if kit.cli_has(c, "file") {
		data, err := os.read_entire_file_from_path(kit.cli_str(c, "file"), context.temp_allocator)
		if err != nil {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", kit.cli_str(c, "file"))
		}
		md = string(data)
	}
	f := format_of_path(path)
	st := State{}
	headless_open(&st, doc_from_markdown(md))
	defer state_destroy(&st)
	title := doc_display_title(&st.doc, base_name(path))
	if !c.dry_run && !doc_export(&st, path, f, title) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", path)
	}
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "format", FORMAT_NAMES[f])
	kit.jset_str(c.out, "title", title)
	kit.jset_int(c.out, "paragraphs", len(st.doc.paras))
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_export_png :: proc(c: ^kit.Call) -> int {
	file, base := kit.cli_str(c, "file"), kit.cli_str(c, "base")
	if !os.exists(file) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", file)
	}
	n, pages, err := export_png_file(file, base, c.dry_run)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	written := kit.jarr()
	for i in 0 ..< n {
		kit.jpush(written, kit.jstr(fmt.tprintf("%s-p%d.png", base, i + 1)))
	}
	kit.jset_str(c.out, "file", file)
	kit.jset_str(c.out, "base", base)
	kit.jset_int(c.out, "pages", pages)
	kit.jset(c.out, "written", written)
	return kit.EXIT_OK
}

@(private = "file")
cmd_lint :: proc(c: ^kit.Call) -> int {
	st := State{}
	label, code := cli_open(c, &st, "file")
	if code != kit.EXIT_OK {
		return code
	}
	defer state_destroy(&st)
	r, err, unavailable := lint_document(&st.doc, label == WELCOME_LABEL ? "" : label)
	if unavailable {
		// The failure that matters: the linter did not run. An empty list
		// here would read as a clean document, the one answer this command
		// must never give by accident.
		kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
		kit.cli_err_field(c, "engine", "vale")
		return kit.EXIT_UNAVAILABLE
	}
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	counts := kit.jobj()
	kit.jset_int(counts, "error", r.errors)
	kit.jset_int(counts, "warning", r.warnings)
	kit.jset_int(counts, "suggestion", r.suggestions)
	alerts := kit.jarr()
	for &a in r.alerts {
		o := kit.jobj()
		kit.jset_str(o, "rule", a.check)
		kit.jset_str(o, "severity", prose_sev_label(a.sev))
		kit.jset_str(o, "message", a.message)
		kit.jset_str(o, "match", a.match)
		kit.jset_int(o, "para", a.blk.para)
		kit.jset_int(o, "row", a.blk.row)
		kit.jset_int(o, "col", a.blk.col)
		kit.jset_int(o, "cpara", a.blk.cpara)
		kit.jset_int(o, "from", a.from)
		kit.jset_int(o, "to", a.to)
		kit.jset_int(o, "line", a.line)
		kit.jset_int(o, "column", a.col)
		if a.fix != "" {
			kit.jset_str(o, "replacement", a.fix)
		}
		kit.jpush(alerts, o)
	}
	kit.jset_str(c.out, "file", label)
	kit.jset_str(c.out, "engine", "vale")
	kit.jset_str(c.out, "config", r.config)
	kit.jset_str(c.out, "style", r.style)
	kit.jset_int(c.out, "blocks", r.blocks)
	kit.jset_int(c.out, "blocks_unchecked", r.skipped)
	kit.jset(c.out, "counts", counts)
	kit.jset(c.out, "alerts", alerts)
	if kit.cli_bool(c, "strict") && r.errors > 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", prose_plural(r.errors, "error-level alert"))
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_formats :: proc(c: ^kit.Call) -> int {
	exts := [Doc_Format][]string {
		.Json     = {".json"},
		.Markdown = {".md", ".markdown"},
		.Html     = {".html", ".htm"},
		.Pdf      = {".pdf"},
		.Docx     = {".docx"},
		.Odt      = {".odt"},
		.Rtf      = {".rtf"},
	}
	list := kit.jarr()
	for f in Doc_Format {
		o := kit.jobj()
		kit.jset_str(o, "name", FORMAT_NAMES[f])
		e := kit.jarr()
		for x in exts[f] {
			kit.jpush(e, kit.jstr(x))
		}
		kit.jset(o, "extensions", e)
		kit.jset_bool(o, "read", FORMAT_READS[f])
		kit.jset_bool(o, "write", true)
		kit.jpush(list, o)
	}
	kit.jset(c.out, "formats", list)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	written := kit.jarr()
	if !c.dry_run {
		clear(&shots_written)
		if shots(dir) != 0 {
			return kit.cli_failf(c, kit.EXIT_FAILED, "could not render the shots into %s", dir)
		}
		for w in shots_written {
			kit.jpush(written, kit.jstr(w))
		}
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset(c.out, "written", written)
	return kit.EXIT_OK
}

@(private = "file")
cmd_bench :: proc(c: ^kit.Call) -> int {
	n := kit.cli_int(c, "paragraphs", 400)
	if n < 1 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "paragraphs must be at least 1")
	}
	r := run_bench(n)
	kit.jset_int(c.out, "paragraphs", r.paragraphs)
	kit.jset_int(c.out, "words", r.words)
	kit.jset_int(c.out, "characters", r.chars)
	kit.jset_int(c.out, "lines", r.lines)
	kit.jset_int(c.out, "pages", r.pages)
	kit.jset_int(c.out, "runs", r.runs)
	kit.jset_num(c.out, "first_layout_ms", r.first_ms)
	kit.jset_num(c.out, "warm_layout_ms", r.warm_ms)
	kit.jset_num(c.out, "keystroke_ms", r.key_ms)
	kit.jset_int(c.out, "keys", r.keys)
	kit.jset_num(c.out, "undo_ms", r.undo_ms)
	kit.jset_int(c.out, "undos", r.undos)
	kit.jset_num(c.out, "draw_ms", r.draw_ms)
	kit.jset_str(c.out, "draw_size", fmt.tprintf("%dx%d", r.draw_w, r.draw_h))
	return kit.EXIT_OK
}
