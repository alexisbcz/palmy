package main

// The command-line front end of the reader.
//
// Nothing here re-implements the reader. A book is opened by `book_open`, put
// in the library by `library_open_book`, searched by `book_search`, and its
// position, bookmarks and highlights are recorded by `library_set_position`
// and the `marks_*` procedures in store.odin — the same calls the window makes
// when a person turns a page, presses B or highlights a sentence. What the
// window works out from the screen (the page under the reader's eyes, the
// words under a drag) the command line takes from its arguments.
//
// Reads never write. `library`, `info`, `text`, `search`, `position`, `marks`
// and `settings` open the store read-only and do not even create its
// directory, so running every read blind — which `palm --selftest` does —
// leaves no trace on a machine that has never opened the reader.
//
// The store is ~/.local/share/palmy-reader, or $PALMY_READER_HOME, which is
// how the self-test runs without going near a real library. The books
// themselves are only ever read; `remove` forgets an entry and its marks and
// never touches the file.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "library",
		summary = "every book in the library, most recently opened first, with where you are in it",
		effect = .Read,
		flags = {{name = "limit", kind = .Int, help = "how many at most", def = "0"}},
		out = LIBRARY_FIELDS,
		examples = {"reader library --json", "reader library --limit 5 --json"},
		run = cmd_library,
	},
	{
		verb = "add",
		summary = "put books in the library without opening the window (EPUB, MOBI, PDF, DjVu)",
		effect = .Mutate,
		aliases = {"--add"},
		args = {{name = "files", kind = .Path, help = "the book files", required = true, variadic = true}},
		out = ADD_FIELDS,
		examples = {"reader add ~/Books/novel.epub --json", "reader --add a.epub b.pdf"},
		run = cmd_add,
	},
	{
		verb = "info",
		summary = "a book's metadata, size and table of contents; a library entry or any book file",
		effect = .Read,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		out = INFO_FIELDS,
		examples = {"reader info generated.epub --json"},
		run = cmd_info,
	},
	{
		verb = "text",
		summary = "the plain text of one chapter (EPUB, MOBI) or one page (PDF, DjVu, through its text layer)",
		effect = .Read,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		flags = {
			{name = "chapter", kind = .Int, help = "0-based chapter of a reflowable book; default where you are"},
			{name = "page", kind = .Int, help = "1-based page of a fixed document; default where you are"},
		},
		out = TEXT_FIELDS,
		examples = {"reader text generated.epub --chapter 1 --json"},
		run = cmd_text,
	},
	{
		verb = "search",
		summary = "every place a phrase occurs in a book, with a line of context",
		effect = .Read,
		args = {
			{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true},
			{name = "query", kind = .String, help = "at least two characters, case-insensitive", required = true},
		},
		flags = {{name = "limit", kind = .Int, help = "how many hits at most", def = "0"}},
		out = SEARCH_FIELDS,
		examples = {"reader search generated.epub marker --json"},
		run = cmd_search,
	},
	{
		verb = "position",
		summary = "where you are in a library book, and how far through",
		effect = .Read,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		out = POSITION_FIELDS,
		examples = {"reader position generated.epub --json"},
		run = cmd_position,
	},
	{
		verb = "seek",
		summary = "move your place in a library book: a chapter, a block, a page or a percentage",
		effect = .Idempotent,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		flags = {
			{name = "chapter", kind = .Int, help = "0-based chapter (reflowable)"},
			{name = "block", kind = .Int, help = "a block index, as `search` reports it (reflowable)"},
			{name = "page", kind = .Int, help = "1-based page (fixed)"},
			{name = "percent", kind = .Float, help = "0-100 through the book"},
		},
		out = POSITION_FIELDS,
		examples = {"reader seek generated.epub --chapter 2 --json", "reader seek generated.epub --percent 50 --json"},
		run = cmd_seek,
	},
	{
		verb = "marks",
		summary = "a library book's bookmarks and highlights",
		effect = .Read,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		out = MARKS_FIELDS,
		examples = {"reader marks generated.epub --json"},
		run = cmd_marks,
	},
	{
		verb = "bookmark",
		summary = "bookmark a place (default: where you are), or --off to remove the bookmark there",
		effect = .Idempotent,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		flags = {
			{name = "chapter", kind = .Int, help = "0-based chapter (reflowable)"},
			{name = "block", kind = .Int, help = "a block index (reflowable)"},
			{name = "page", kind = .Int, help = "1-based page (fixed)"},
			{name = "off", kind = .Bool, help = "remove the bookmark instead"},
		},
		out = MARK_FIELDS,
		examples = {"reader bookmark generated.epub --json", "reader bookmark generated.epub --chapter 1 --off --json"},
		run = cmd_bookmark,
	},
	{
		verb = "highlight",
		summary = "highlight the first occurrence of a phrase, or a byte range of a block; --off removes it",
		effect = .Idempotent,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		flags = {
			{name = "text", kind = .String, help = "the words to highlight; the first place they occur"},
			{name = "block", kind = .Int, help = "a block index, with --from and --to"},
			{name = "from", kind = .Int, help = "byte offset into the block"},
			{name = "to", kind = .Int, help = "byte offset into the block, exclusive"},
			{name = "off", kind = .Bool, help = "remove the highlight there instead"},
		},
		out = MARK_FIELDS,
		examples = {"reader highlight generated.epub --text \"second chapter\" --json"},
		run = cmd_highlight,
	},
	{
		verb = "remove",
		summary = "forget a book: its library entry, cover and marks go; the book file is never touched",
		effect = .Destructive,
		args = {{name = "book", kind = .String, help = "an id, a path, a file name or a title", required = true}},
		out = REMOVE_FIELDS,
		examples = {"reader remove generated.epub --yes --json"},
		run = cmd_remove,
	},
	{
		verb = "settings",
		summary = "the reading settings: type size, line height, margins, theme, mode, fit and zoom",
		effect = .Read,
		out = SETTINGS_FIELDS,
		examples = {"reader settings --json"},
		run = cmd_settings,
	},
	{
		verb = "set",
		summary = "change reading settings, within the same limits as the window's controls",
		effect = .Idempotent,
		flags = {
			{name = "size", kind = .Float, help = "body type size in px (11-40)"},
			{name = "line", kind = .Float, help = "line height multiplier (1.08-2.4)"},
			{name = "margin", kind = .Float, help = "side margin as a fraction of the width (0.03-0.3)"},
			{name = "theme", kind = .Enum, values = {"light", "sepia", "dark"}, help = "the page colours"},
			{name = "justify", kind = .Bool, help = "justify text (--no-justify turns it off)"},
			{name = "para", kind = .Enum, values = {"indented", "spaced"}, help = "paragraph style"},
			{name = "mode", kind = .Enum, values = {"paged", "continuous"}, help = "turn pages or scroll"},
			{name = "fit", kind = .Enum, values = {"width", "page", "zoom"}, help = "how a fixed page fits"},
			{name = "zoom", kind = .Float, help = "zoom for fixed pages (0.3-5); implies --fit zoom"},
		},
		out = SETTINGS_FIELDS,
		examples = {"reader set --theme sepia --size 19 --json"},
		run = cmd_set,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "reader",
			summary    = "an e-book reader: EPUB, MOBI, PDF and DjVu, with a library that remembers your place",
			gui        = true,
			takes_path = true,
			takes_word = kit.cli_word_is_path, // a file opens; a typo is a usage error
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The library lives in ~/.local/share/palmy-reader ($PALMY_READER_HOME moves
it): library.tsv, settings.tsv, covers/ and marks/. Books are read where they
are and never written; nothing outside the store is scanned.

<book> is matched against an id, a path, a file name and then a title (an
unambiguous prefix is enough). info, text and search also take any book file
that is not in the library. Nothing matching exits 3.

A position in a reflowable book (EPUB, MOBI) is a chapter and a block — a
paragraph, as search reports it — so it survives a change of type size; in a
fixed one (PDF, DjVu) it is a page. reader <file> opens the window on a book.`

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself on any failure
	return 0
}

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

LIBRARY_FIELDS := []kit.Field {
	{
		name = "books",
		kind = .Array,
		of = {
			{name = "id", kind = .String},
			{name = "title", kind = .String},
			{name = "author", kind = .String},
			{name = "format", kind = .String},
			{name = "path", kind = .String},
			{name = "missing", kind = .Bool, help = "the file is no longer where it was"},
			{name = "progress", kind = .Float, help = "0..1 through the book"},
			{name = "chapter", kind = .Int},
			{name = "page", kind = .Int},
			{name = "marks", kind = .Int, help = "bookmarks and highlights"},
			{name = "opened", kind = .Int, help = "unix seconds"},
		},
	},
	{name = "count", kind = .Int},
	{name = "dir", kind = .String},
}

ADD_FIELDS := []kit.Field {
	{
		name = "added",
		kind = .Array,
		of = {
			{name = "id", kind = .String},
			{name = "title", kind = .String},
			{name = "author", kind = .String},
			{name = "format", kind = .String},
			{name = "path", kind = .String},
		},
	},
	{name = "failed", kind = .Array, of = {{name = "path", kind = .String}, {name = "error", kind = .String}}},
	{name = "count", kind = .Int},
}

INFO_FIELDS := []kit.Field {
	{name = "id", kind = .String, help = "the library id, or what it would be"},
	{name = "in_library", kind = .Bool},
	{name = "path", kind = .String},
	{name = "title", kind = .String},
	{name = "author", kind = .String},
	{name = "language", kind = .String},
	{name = "publisher", kind = .String},
	{name = "format", kind = .String},
	{name = "reflowable", kind = .Bool},
	{name = "chapters", kind = .Int, help = "1 for a fixed document"},
	{name = "pages", kind = .Int, help = "pages of a fixed document, 0 for a reflowable one"},
	{name = "blocks", kind = .Int, help = "paragraphs, headings and pictures of a reflowable book"},
	{name = "toc", kind = .Array, of = {{name = "title", kind = .String}, {name = "depth", kind = .Int}, {name = "block", kind = .Int, help = "a block, or a 1-based page of a fixed document; -1 if the target is missing"}}},
	{name = "warnings", kind = .Array, of = {{kind = .String}}},
}

TEXT_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "format", kind = .String},
	{name = "chapter", kind = .Int, opt = true, help = "reflowable books"},
	{name = "chapters", kind = .Int, opt = true},
	{name = "chapter_title", kind = .String, opt = true},
	{name = "first_block", kind = .Int, opt = true},
	{name = "page", kind = .Int, opt = true, help = "fixed documents"},
	{name = "pages", kind = .Int, opt = true},
	{name = "text_layer", kind = .Bool, opt = true, help = "false when the page has no extractable text"},
	{name = "text", kind = .String},
}

SEARCH_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "query", kind = .String},
	{
		name = "hits",
		kind = .Array,
		of = {
			{name = "chapter", kind = .Int},
			{name = "block", kind = .Int},
			{name = "page", kind = .Int},
			{name = "start", kind = .Int},
			{name = "end", kind = .Int},
			{name = "line", kind = .String},
		},
	},
	{name = "count", kind = .Int},
	{name = "truncated", kind = .Bool, help = "the search stops at 500 hits"},
}

POSITION_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "format", kind = .String},
	{name = "chapter", kind = .Int},
	{name = "block", kind = .Int},
	{name = "offset", kind = .Int},
	{name = "page", kind = .Int},
	{name = "pages", kind = .Int, help = "chapters of a reflowable book, pages of a fixed one"},
	{name = "progress", kind = .Float, help = "0..1 through the book"},
}

MARKS_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{
		name = "marks",
		kind = .Array,
		of = {
			{name = "kind", kind = .String, help = "bookmark or highlight"},
			{name = "chapter", kind = .Int},
			{name = "block", kind = .Int},
			{name = "from", kind = .Int},
			{name = "to", kind = .Int},
			{name = "page", kind = .Int},
			{name = "text", kind = .String},
			{name = "added", kind = .Int},
		},
	},
	{name = "count", kind = .Int},
}

MARK_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "kind", kind = .String},
	{name = "present", kind = .Bool, help = "whether the mark is there now"},
	{name = "changed", kind = .Bool, help = "false when it already was (or was not)"},
	{name = "chapter", kind = .Int},
	{name = "block", kind = .Int},
	{name = "page", kind = .Int},
	{name = "text", kind = .String},
	{name = "count", kind = .Int, help = "marks on the book now"},
}

REMOVE_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "title", kind = .String},
	{name = "path", kind = .String},
	{name = "removed", kind = .Bool},
	{name = "file_kept", kind = .Bool, help = "always true: the book file is never touched"},
}

SETTINGS_FIELDS := []kit.Field {
	{name = "size", kind = .Float},
	{name = "line", kind = .Float},
	{name = "margin", kind = .Float},
	{name = "theme", kind = .String},
	{name = "justify", kind = .Bool},
	{name = "para", kind = .String},
	{name = "mode", kind = .String},
	{name = "fit", kind = .String},
	{name = "zoom", kind = .Float},
	{name = "changed", kind = .Bool, opt = true},
}

// ---------------------------------------------------------------------------
// The store, the fonts, and finding a book
// ---------------------------------------------------------------------------

// library_read_only loads the library without creating anything: no
// directory, no file. A read must leave no trace.
@(private = "file")
library_read_only :: proc(l: ^Library) {
	l^ = {}
	l.dir = store_dir()
	l.books = make([dynamic]Lib_Entry, 0, 16)
	library_load(l)
}

// library_writable is library_init then library_load: what the window does.
@(private = "file")
library_writable :: proc(l: ^Library) -> bool {
	library_init(l)
	if l.err != "" {
		return false
	}
	library_load(l)
	return true
}

// cli_fonts is the face set a reflowable book measures with, loaded the way
// the headless paths always have: an offscreen target and the kit's faces.
@(private = "file")
g_off: ^p.Offscreen

@(private = "file")
cli_fonts :: proc() -> ^p.Fonts {
	if g_off == nil {
		g_off = p.offscreen_create(800, 600)
		load_test_fonts(&g_off.fonts)
	}
	return &g_off.fonts
}

@(private = "file")
cli_opts :: proc(l: ^Library) -> Reflow_Opts {
	s := settings_load(l)
	return Reflow_Opts{size = s.size, line = s.line, measure = 620, page_h = 640, justify = s.justify, para = s.para}
}

@(private = "file")
abs_path :: proc(path: string) -> string {
	abs := path
	if strings.has_prefix(abs, "~/") {
		abs = tfmt("%s%s", os.get_env("HOME", context.temp_allocator), abs[1:])
	}
	if !strings.has_prefix(abs, "/") {
		if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
			abs = tfmt("%s/%s", cwd, abs)
		}
	}
	return path_normalize_abs(abs, context.temp_allocator)
}

// resolve_entry finds the library entry a caller meant: an id, a path, a file
// name, an exact title, then an unambiguous prefix of one — in that order, so
// a precise reference always beats a fuzzy one. Two candidates is not found:
// guessing would be the wrong answer, silently.
resolve_entry :: proc(l: ^Library, ref: string) -> int {
	if ref == "" {
		return -1
	}
	abs := abs_path(ref)
	for e, i in l.books {
		if e.id == ref || e.path == ref || e.path == abs {
			return i
		}
	}
	hit, count := -1, 0
	for e, i in l.books {
		if path_base(e.path) == ref {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return hit
	}
	hit, count = -1, 0
	for e, i in l.books {
		if strings.equal_fold(e.title, ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return hit
	}
	hit, count = -1, 0
	for e, i in l.books {
		if len(e.title) >= len(ref) && strings.equal_fold(e.title[:len(ref)], ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return hit
	}
	return -1
}

@(private = "file")
not_found :: proc(c: ^kit.Call, ref: string, what := "no book in the library matching") -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s %q", what, ref)
	kit.cli_err_field(c, "book", ref)
	return code
}

// open_ref opens a library entry, or for the commands that allow it any book
// file. The library is not touched: opening to read is not opening to read
// in the window, and does not move "last opened".
@(private = "file")
open_ref :: proc(c: ^kit.Call, l: ^Library, b: ^Book, ref: string, files_too: bool) -> (idx: int, path: string, code: int) {
	idx = resolve_entry(l, ref)
	switch {
	case idx >= 0:
		path = l.books[idx].path
	case files_too && os.is_file(abs_path(ref)):
		path = abs_path(ref)
	case:
		return -1, "", not_found(c, ref)
	}
	if !os.is_file(path) {
		return idx, path, not_found(c, path, "the book file is missing:")
	}
	if !book_open(b, path, cli_fonts(), library_cache_dir(l), cli_opts(l)) {
		return idx, path, kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", path_base(path), b.err)
	}
	return idx, path, kit.EXIT_OK
}

@(private = "file")
entry_id :: proc(l: ^Library, idx: int, path: string) -> string {
	if idx >= 0 {
		return l.books[idx].id
	}
	return book_id(path, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_library :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	limit := kit.cli_int(c, "limit", 0)
	order := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(l.books) {
		append(&order, i)
	}
	// Most recently opened first, which is the order the window's grid uses.
	for i in 1 ..< len(order) {
		j := i
		for j > 0 && l.books[order[j]].opened > l.books[order[j - 1]].opened {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}
	arr := kit.jarr()
	for i in order {
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		e := &l.books[i]
		marks_load(&l, i)
		o := kit.jobj()
		kit.jset_str(o, "id", e.id)
		kit.jset_str(o, "title", e.title)
		kit.jset_str(o, "author", e.author)
		kit.jset_str(o, "format", format_name(e.format))
		kit.jset_str(o, "path", e.path)
		kit.jset_bool(o, "missing", e.missing)
		kit.jset_num(o, "progress", round3(f64(e.frac)))
		kit.jset_int(o, "chapter", e.chapter)
		kit.jset_int(o, "page", e.page)
		kit.jset_int(o, "marks", len(e.marks))
		kit.jset_int(o, "opened", int(e.opened))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "books", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	kit.jset_str(c.out, "dir", l.dir)
	return kit.EXIT_OK
}

@(private = "file")
cmd_add :: proc(c: ^kit.Call) -> int {
	files := kit.cli_rest(c)
	added := kit.jarr()
	failed := kit.jarr()
	l: Library
	if c.dry_run {
		library_read_only(&l)
	} else if !library_writable(&l) {
		return kit.cli_fail(c, kit.EXIT_FAILED, l.err)
	}
	missing := 0
	for f in files {
		abs := abs_path(f)
		fail :: proc(arr: ^kit.Json, path, why: string) {
			o := kit.jobj()
			kit.jset_str(o, "path", path)
			kit.jset_str(o, "error", why)
			kit.jpush(arr, o)
		}
		if !os.is_file(abs) {
			fail(failed, abs, "no such file")
			missing += 1
			continue
		}
		b: Book
		i := -1
		ok := false
		if c.dry_run {
			ok = book_open(&b, abs, cli_fonts(), library_cache_dir(&l), cli_opts(&l))
		} else {
			// The window's own call: open, record, cover, marks.
			i, ok = library_open_book(&l, &b, abs, cli_fonts(), cli_opts(&l))
		}
		if !ok {
			fail(failed, abs, b.err)
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "id", i >= 0 ? l.books[i].id : book_id(abs, context.temp_allocator))
		kit.jset_str(o, "title", book_title(&b))
		kit.jset_str(o, "author", book_author(&b))
		kit.jset_str(o, "format", format_name(b.format))
		kit.jset_str(o, "path", abs)
		kit.jpush(added, o)
		kit.cli_trace(c, "added %s (%s)", book_title(&b), format_name(b.format))
		book_close(&b)
	}
	if !c.dry_run && kit.jlen(added) > 0 && !library_save(&l) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s/library.tsv", l.dir)
	}
	if kit.jlen(added) == 0 {
		if missing == len(files) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no such file: %s", files[0] if len(files) > 0 else "")
		}
		first, _ := kit.jget(failed.items[0], "error")
		return kit.cli_failf(c, kit.EXIT_FAILED, "no book could be opened: %s", kit.json_scalar(first))
	}
	kit.jset(c.out, "added", added)
	kit.jset(c.out, "failed", failed)
	kit.jset_int(c.out, "count", kit.jlen(added))
	return kit.EXIT_OK
}

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	b: Book
	idx, path, code := open_ref(c, &l, &b, kit.cli_str(c, "book"), true)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)
	reflowable := format_is_reflowable(b.format)
	kit.jset_str(c.out, "id", entry_id(&l, idx, path))
	kit.jset_bool(c.out, "in_library", idx >= 0)
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "title", reflowable ? book_title(&b) : (b.fixed.title != "" ? b.fixed.title : book_title(&b)))
	kit.jset_str(c.out, "author", reflowable ? book_author(&b) : b.fixed.author)
	kit.jset_str(c.out, "language", b.doc.language)
	kit.jset_str(c.out, "publisher", b.doc.publisher)
	kit.jset_str(c.out, "format", format_name(b.format))
	kit.jset_bool(c.out, "reflowable", reflowable)
	kit.jset_int(c.out, "chapters", book_chapters(&b))
	kit.jset_int(c.out, "pages", reflowable ? 0 : b.fixed.pages)
	kit.jset_int(c.out, "blocks", len(b.doc.blocks))
	toc := kit.jarr()
	for t in book_toc(&b) {
		o := kit.jobj()
		kit.jset_str(o, "title", t.title)
		kit.jset_int(o, "depth", t.depth)
		kit.jset_int(o, "block", t.block)
		kit.jpush(toc, o)
	}
	kit.jset(c.out, "toc", toc)
	warn := kit.jarr()
	for n in b.doc.notes {
		kit.jpush(warn, kit.jstr(n))
	}
	if !reflowable && b.fixed.err != "" {
		kit.jpush(warn, kit.jstr(b.fixed.err))
	}
	kit.jset(c.out, "warnings", warn)
	return kit.EXIT_OK
}

@(private = "file")
cmd_text :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	b: Book
	idx, path, code := open_ref(c, &l, &b, kit.cli_str(c, "book"), true)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)
	kit.jset_str(c.out, "id", entry_id(&l, idx, path))
	kit.jset_str(c.out, "title", book_title(&b))
	kit.jset_str(c.out, "format", format_name(b.format))
	if format_is_reflowable(b.format) {
		d := &b.doc
		ch := idx >= 0 ? l.books[idx].chapter : 0
		if kit.cli_has(c, "chapter") {
			ch = kit.cli_int(c, "chapter")
		}
		if ch < 0 || ch >= len(d.chapters) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "chapter %d: the book has chapters 0 to %d", ch, len(d.chapters) - 1)
		}
		cp := d.chapters[ch]
		sb := strings.builder_make(context.temp_allocator)
		for bi in cp.first ..< cp.first + cp.count {
			t := block_text(d, bi)
			if t == "" {
				continue
			}
			if strings.builder_len(sb) > 0 {
				strings.write_string(&sb, "\n\n")
			}
			strings.write_string(&sb, t)
		}
		kit.jset_int(c.out, "chapter", ch)
		kit.jset_int(c.out, "chapters", len(d.chapters))
		kit.jset_str(c.out, "chapter_title", cp.title)
		kit.jset_int(c.out, "first_block", cp.first)
		kit.jset_str(c.out, "text", strings.to_string(sb))
		return kit.EXIT_OK
	}
	pg := idx >= 0 && l.books[idx].page > 0 ? l.books[idx].page : 1
	if kit.cli_has(c, "page") {
		pg = kit.cli_int(c, "page")
	}
	if pg < 1 || pg > b.fixed.pages {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "page %d: the document has pages 1 to %d", pg, b.fixed.pages)
	}
	// The same text layer search uses (pdftotext, djvutxt); a scan without
	// one answers with empty text and says so rather than failing.
	t := fixed_page_text(&b.fixed, pg)
	kit.jset_int(c.out, "page", pg)
	kit.jset_int(c.out, "pages", b.fixed.pages)
	kit.jset_bool(c.out, "text_layer", strings.trim_space(t) != "")
	kit.jset_str(c.out, "text", t)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	b: Book
	idx, path, code := open_ref(c, &l, &b, kit.cli_str(c, "book"), true)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)
	q := kit.cli_str(c, "query")
	if len(strings.trim_space(q)) < 2 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a query needs at least two characters")
	}
	s: Search
	defer search_destroy(&s)
	book_search(&b, &s, q) // the window's own search
	limit := kit.cli_int(c, "limit", 0)
	hits := kit.jarr()
	for h in s.hits {
		if limit > 0 && kit.jlen(hits) >= limit {
			break
		}
		o := kit.jobj()
		kit.jset_int(o, "chapter", h.chapter)
		kit.jset_int(o, "block", h.block)
		kit.jset_int(o, "page", h.page)
		kit.jset_int(o, "start", h.start)
		kit.jset_int(o, "end", h.end)
		kit.jset_str(o, "line", h.line)
		kit.jpush(hits, o)
	}
	kit.jset_str(c.out, "id", entry_id(&l, idx, path))
	kit.jset_str(c.out, "query", q)
	kit.jset(c.out, "hits", hits)
	kit.jset_int(c.out, "count", len(s.hits))
	kit.jset_bool(c.out, "truncated", len(s.hits) >= SEARCH_MAX)
	return kit.EXIT_OK
}

@(private = "file")
position_out :: proc(c: ^kit.Call, e: ^Lib_Entry) {
	kit.jset_str(c.out, "id", e.id)
	kit.jset_str(c.out, "title", e.title)
	kit.jset_str(c.out, "format", format_name(e.format))
	kit.jset_int(c.out, "chapter", e.chapter)
	kit.jset_int(c.out, "block", e.block)
	kit.jset_int(c.out, "offset", e.off)
	kit.jset_int(c.out, "page", e.page)
	kit.jset_int(c.out, "pages", e.pages)
	kit.jset_num(c.out, "progress", round3(f64(e.frac)))
}

@(private = "file")
cmd_position :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	ref := kit.cli_str(c, "book")
	i := resolve_entry(&l, ref)
	if i < 0 {
		return not_found(c, ref)
	}
	position_out(c, &l.books[i])
	return kit.EXIT_OK
}

@(private = "file")
cmd_seek :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	ref := kit.cli_str(c, "book")
	i := resolve_entry(&l, ref)
	if i < 0 {
		return not_found(c, ref)
	}
	if !kit.cli_has(c, "chapter") && !kit.cli_has(c, "block") && !kit.cli_has(c, "page") && !kit.cli_has(c, "percent") {
		return kit.cli_fail(c, kit.EXIT_USAGE, "say where: --chapter, --block, --page or --percent")
	}
	b: Book
	_, _, code := open_ref(c, &l, &b, ref, false)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)

	if format_is_reflowable(b.format) {
		d := &b.doc
		if len(d.chapters) == 0 {
			return kit.cli_fail(c, kit.EXIT_FAILED, "the book has no chapters")
		}
		block := -1
		switch {
		case kit.cli_has(c, "block"):
			block = kit.cli_int(c, "block")
			if block < 0 || block >= len(d.blocks) {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "block %d: the book has blocks 0 to %d", block, len(d.blocks) - 1)
			}
		case kit.cli_has(c, "chapter"):
			ch := kit.cli_int(c, "chapter")
			if ch < 0 || ch >= len(d.chapters) {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "chapter %d: the book has chapters 0 to %d", ch, len(d.chapters) - 1)
			}
			block = d.chapters[ch].first
		case kit.cli_has(c, "percent"):
			// The first block at or past that share of the book's text, by the
			// same byte measure the progress bar uses.
			want := clamp(kit.cli_f64(c, "percent"), 0, 100) / 100
			total := doc_total_bytes(d)
			acc := 0
			block = d.chapters[len(d.chapters) - 1].first
			found := false
			for cp in d.chapters {
				for bi in cp.first ..< cp.first + cp.count {
					if f64(acc) >= want * f64(total) {
						block, found = bi, true
						break
					}
					acc += len(block_text(d, bi))
				}
				if found {
					break
				}
			}
		case:
			return kit.cli_fail(c, kit.EXIT_USAGE, "--page is for fixed documents; use --chapter, --block or --percent")
		}
		ch := chapter_of_block(d, block)
		cp := d.chapters[ch]
		before := 0
		for bi in cp.first ..< block {
			before += len(block_text(d, bi))
		}
		within := cp.bytes > 0 ? f32(before) / f32(cp.bytes) : 0
		library_set_position(&l, i, true, ch, block, 0, 0, doc_progress(d, ch, within), len(d.chapters))
	} else {
		pages := b.fixed.pages
		pg := 1
		switch {
		case kit.cli_has(c, "page"):
			pg = kit.cli_int(c, "page")
			if pg < 1 || pg > pages {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "page %d: the document has pages 1 to %d", pg, pages)
			}
		case kit.cli_has(c, "percent"):
			pg = 1 + int(clamp(kit.cli_f64(c, "percent"), 0, 100) / 100 * f64(max(pages - 1, 0)) + 0.5)
		case:
			return kit.cli_fail(c, kit.EXIT_USAGE, "a fixed document has pages: use --page or --percent")
		}
		library_set_position(&l, i, false, 0, -1, 0, pg, fixed_progress(pg, pages), pages)
	}
	if !c.dry_run {
		if !library_writable_dir(&l) || !library_save(&l) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s/library.tsv", l.dir)
		}
	}
	position_out(c, &l.books[i])
	return kit.EXIT_OK
}

// library_writable_dir makes the store's directories for a library that was
// loaded read-only and is now about to be written.
@(private = "file")
library_writable_dir :: proc(l: ^Library) -> bool {
	tmp: Library
	library_init(&tmp)
	ok := tmp.err == ""
	library_destroy(&tmp)
	return ok
}

@(private = "file")
cmd_marks :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	ref := kit.cli_str(c, "book")
	i := resolve_entry(&l, ref)
	if i < 0 {
		return not_found(c, ref)
	}
	marks_load(&l, i)
	e := &l.books[i]
	arr := kit.jarr()
	for m in e.marks {
		o := kit.jobj()
		kit.jset_str(o, "kind", m.kind == .Highlight ? "highlight" : "bookmark")
		kit.jset_int(o, "chapter", m.chapter)
		kit.jset_int(o, "block", m.block)
		kit.jset_int(o, "from", m.off)
		kit.jset_int(o, "to", m.end)
		kit.jset_int(o, "page", m.page)
		kit.jset_str(o, "text", m.text)
		kit.jset_int(o, "added", int(m.added))
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "id", e.id)
	kit.jset_str(c.out, "title", e.title)
	kit.jset(c.out, "marks", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
mark_out :: proc(c: ^kit.Call, l: ^Library, i: int, kind: string, present, changed: bool, chapter, block, page: int, text: string) {
	kit.jset_str(c.out, "id", l.books[i].id)
	kit.jset_str(c.out, "kind", kind)
	kit.jset_bool(c.out, "present", present)
	kit.jset_bool(c.out, "changed", changed)
	kit.jset_int(c.out, "chapter", chapter)
	kit.jset_int(c.out, "block", block)
	kit.jset_int(c.out, "page", page)
	kit.jset_str(c.out, "text", text)
	kit.jset_int(c.out, "count", len(l.books[i].marks))
}

// The marks commands write a marks file inside the store; the directory is
// made first if this is the first write the store has ever had.
@(private = "file")
open_for_marks :: proc(c: ^kit.Call, l: ^Library, b: ^Book) -> (i: int, code: int) {
	library_read_only(l)
	ref := kit.cli_str(c, "book")
	i = resolve_entry(l, ref)
	if i < 0 {
		return -1, not_found(c, ref)
	}
	_, _, code = open_ref(c, l, b, ref, false)
	if code != kit.EXIT_OK {
		return i, code
	}
	marks_load(l, i)
	if !c.dry_run && !library_writable_dir(l) {
		book_close(b)
		return i, kit.cli_failf(c, kit.EXIT_FAILED, "cannot create %s", l.dir)
	}
	return i, kit.EXIT_OK
}

@(private = "file")
cmd_bookmark :: proc(c: ^kit.Call) -> int {
	l: Library
	b: Book
	i, code := open_for_marks(c, &l, &b)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)
	e := &l.books[i]
	reflowable := format_is_reflowable(b.format)
	chapter, block, off, page := e.chapter, e.block, e.off, e.page
	if reflowable {
		d := &b.doc
		if kit.cli_has(c, "block") {
			block, off = kit.cli_int(c, "block"), 0
			if block < 0 || block >= len(d.blocks) {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "block %d: the book has blocks 0 to %d", block, len(d.blocks) - 1)
			}
			chapter = chapter_of_block(d, block)
		} else if kit.cli_has(c, "chapter") {
			chapter = kit.cli_int(c, "chapter")
			if chapter < 0 || chapter >= len(d.chapters) {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "chapter %d: the book has chapters 0 to %d", chapter, len(d.chapters) - 1)
			}
			block, off = d.chapters[chapter].first, 0
		}
		if block < 0 || block >= len(d.blocks) {
			block = len(d.chapters) > 0 ? d.chapters[clamp(chapter, 0, len(d.chapters) - 1)].first : 0
		}
		page = 0
	} else {
		if kit.cli_has(c, "page") {
			page = kit.cli_int(c, "page")
		}
		page = page < 1 ? 1 : page
		if page > b.fixed.pages {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "page %d: the document has pages 1 to %d", page, b.fixed.pages)
		}
		chapter, block, off = 0, -1, 0
	}
	label := bookmark_label(&b, block, page)
	k := marks_find_bookmark(&l, i, reflowable, chapter, block, page)
	off_wanted := kit.cli_bool(c, "off")
	changed := false
	if off_wanted && k >= 0 {
		label = strings.clone(l.books[i].marks[k].text, context.temp_allocator)
		if !c.dry_run {
			marks_remove(&l, i, k)
		}
		changed = true
	} else if !off_wanted && k < 0 {
		if !c.dry_run {
			marks_add_bookmark(&l, i, chapter, block, off, page, label)
		}
		changed = true
	}
	mark_out(c, &l, i, "bookmark", !off_wanted, changed, chapter, block, page, label)
	return kit.EXIT_OK
}

@(private = "file")
cmd_highlight :: proc(c: ^kit.Call) -> int {
	l: Library
	b: Book
	i, code := open_for_marks(c, &l, &b)
	if code != kit.EXIT_OK {
		return code
	}
	defer book_close(&b)
	if !format_is_reflowable(b.format) {
		return kit.cli_fail(c, kit.EXIT_USAGE, "highlights need a reflowable book (EPUB or MOBI)")
	}
	d := &b.doc
	block, from, to := -1, 0, 0
	switch {
	case kit.cli_has(c, "text"):
		s: Search
		defer search_destroy(&s)
		book_search(&b, &s, kit.cli_str(c, "text"))
		if len(s.hits) == 0 {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%q does not occur in the book", kit.cli_str(c, "text"))
		}
		block, from, to = s.hits[0].block, s.hits[0].start, s.hits[0].end
	case kit.cli_has(c, "block"):
		block = kit.cli_int(c, "block")
		if block < 0 || block >= len(d.blocks) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "block %d: the book has blocks 0 to %d", block, len(d.blocks) - 1)
		}
		n := len(block_text(d, block))
		from = clamp(kit.cli_int(c, "from", 0), 0, n)
		to = clamp(kit.cli_int(c, "to", n), from, n)
		if to <= from {
			return kit.cli_fail(c, kit.EXIT_USAGE, "--to must be past --from")
		}
	case:
		return kit.cli_fail(c, kit.EXIT_USAGE, "say what: --text, or --block with --from and --to")
	}
	chapter := chapter_of_block(d, block)
	text := range_text(d, block, from, to, context.temp_allocator)
	k := marks_find_highlight(&l, i, block, from, to)
	off_wanted := kit.cli_bool(c, "off")
	changed := false
	if off_wanted && k >= 0 {
		text = strings.clone(l.books[i].marks[k].text, context.temp_allocator)
		if !c.dry_run {
			marks_remove(&l, i, k)
		}
		changed = true
	} else if !off_wanted && k < 0 {
		if !c.dry_run {
			marks_add_highlight(&l, i, chapter, block, from, to, text)
		}
		changed = true
	}
	mark_out(c, &l, i, "highlight", !off_wanted, changed, chapter, block, 0, text)
	return kit.EXIT_OK
}

@(private = "file")
cmd_remove :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	ref := kit.cli_str(c, "book")
	i := resolve_entry(&l, ref)
	if i < 0 {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "id", l.books[i].id)
	kit.jset_str(c.out, "title", l.books[i].title)
	kit.jset_str(c.out, "path", l.books[i].path)
	if !c.dry_run {
		// The window's own forget: entry, cover and marks file. The book
		// file is not touched.
		library_remove(&l, i)
		if !library_writable_dir(&l) || !library_save(&l) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s/library.tsv", l.dir)
		}
	}
	kit.jset_bool(c.out, "removed", !c.dry_run)
	kit.jset_bool(c.out, "file_kept", true)
	return kit.EXIT_OK
}

@(private = "file")
settings_out :: proc(c: ^kit.Call, s: Settings) {
	kit.jset_num(c.out, "size", round3(f64(s.size)))
	kit.jset_num(c.out, "line", round3(f64(s.line)))
	kit.jset_num(c.out, "margin", round3(f64(s.margin)))
	kit.jset_str(c.out, "theme", strings.to_lower(theme_name(s.theme), context.temp_allocator))
	kit.jset_bool(c.out, "justify", s.justify)
	kit.jset_str(c.out, "para", s.para == .Spaced ? "spaced" : "indented")
	kit.jset_str(c.out, "mode", s.mode == .Continuous ? "continuous" : "paged")
	kit.jset_str(c.out, "fit", s.fit == .Page ? "page" : (s.fit == .Zoom ? "zoom" : "width"))
	kit.jset_num(c.out, "zoom", round3(f64(s.zoom)))
}

@(private = "file")
cmd_settings :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	settings_out(c, settings_load(&l))
	return kit.EXIT_OK
}

@(private = "file")
cmd_set :: proc(c: ^kit.Call) -> int {
	l: Library
	library_read_only(&l)
	old := settings_load(&l)
	s := old
	f32_of :: proc(c: ^kit.Call, name: string, cur: f32) -> f32 {
		if !kit.cli_has(c, name) {
			return cur
		}
		v, _ := strconv.parse_f32(kit.cli_str(c, name))
		return v
	}
	s.size = f32_of(c, "size", s.size)
	s.line = f32_of(c, "line", s.line)
	s.margin = f32_of(c, "margin", s.margin)
	if kit.cli_has(c, "zoom") {
		s.zoom = f32_of(c, "zoom", s.zoom)
		s.fit = .Zoom // as the window's zoom keys do
	}
	if kit.cli_has(c, "justify") {
		s.justify = kit.cli_bool(c, "justify")
	}
	switch kit.cli_str(c, "theme") {
	case "light":
		s.theme = .Light
	case "sepia":
		s.theme = .Sepia
	case "dark":
		s.theme = .Dark
	}
	switch kit.cli_str(c, "para") {
	case "indented":
		s.para = .Indented
	case "spaced":
		s.para = .Spaced
	}
	switch kit.cli_str(c, "mode") {
	case "paged":
		s.mode = .Paged
	case "continuous":
		s.mode = .Continuous
	}
	switch kit.cli_str(c, "fit") {
	case "width":
		s.fit = .Width
	case "page":
		s.fit = .Page
	case "zoom":
		s.fit = .Zoom
	}
	s = settings_clamp(s)
	changed := s != old
	if changed && !c.dry_run {
		if !library_writable_dir(&l) || !settings_save(&l, s) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s/settings.tsv", l.dir)
		}
	}
	settings_out(c, s)
	kit.jset_bool(c.out, "changed", changed)
	return kit.EXIT_OK
}

// round3 keeps a stored f32 from printing as 1.6200000047683716: the setting
// is 1.62, and that is what an agent comparing it should read.
@(private = "file")
round3 :: proc(v: f64) -> f64 {
	return f64(i64(v * 1000 + (v < 0 ? -0.5 : 0.5))) / 1000
}
