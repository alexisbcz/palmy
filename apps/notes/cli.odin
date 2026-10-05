package main

// The command-line front end of Notes.
//
// Notes is the exemplar for an application that had an engine and no command
// line at all. Nothing below re-implements anything: `store_load`,
// `store_write`, `store_create`, `store_delete`, `title_of`, `preview_of`,
// `word_count` and `slug` are the same procedures the window calls, so a note
// written here is indistinguishable from a note typed in the editor — same
// file, same name, same title rule — and the two front ends cannot drift
// because there is only one store.
//
// The shape of the surface is the store's shape: a note is a Markdown file,
// and `read`, `write`, `rename` and `delete` mean what they mean in a
// directory of files.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "every note, newest first",
		effect = .Read,
		flags = {
			{name = "limit", kind = .Int, help = "how many, newest first", def = "0"},
			{name = "match", kind = .String, help = "only notes whose title or body contains this"},
		},
		out = LIST_FIELDS,
		examples = {"notes list --json", "notes list --limit 5 --json"},
		run = cmd_list,
	},
	{
		verb = "read",
		summary = "one note's text",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug or a path", required = true}},
		out = READ_FIELDS,
		examples = {"notes read welcome-to-notes --json"},
		run = cmd_read,
	},
	{
		verb = "search",
		summary = "notes whose title or body matches, with the matching lines",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "the text to look for", required = true}},
		flags = {{name = "limit", kind = .Int, help = "how many notes at most", def = "0"}},
		out = SEARCH_FIELDS,
		examples = {"notes search markdown --json"},
		run = cmd_search,
	},
	{
		verb = "path",
		summary = "where a note's file is, and where the notebook is",
		effect = .Read,
		args = {{name = "note", kind = .String, help = "a title, a slug or a path"}},
		out = PATH_FIELDS,
		examples = {"notes path --json", "notes path welcome-to-notes --json"},
		run = cmd_path,
	},
	{
		verb = "new",
		summary = "create a note",
		effect = .Mutate,
		args = {{name = "title", kind = .String, help = "its first line"}},
		flags = {{name = "text", kind = .String, help = "the body under the title"}},
		out = WROTE_FIELDS,
		examples = {"notes new \"Shopping list\" --json", "notes new Groceries --text \"milk\\neggs\" --json"},
		run = cmd_new,
	},
	{
		verb = "write",
		summary = "replace a note's text, creating it if it is not there",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug or a path", required = true}},
		flags = {
			{name = "text", kind = .String, help = "the new text"},
			{name = "file", kind = .Path, help = "read the new text from this file instead"},
		},
		out = WROTE_FIELDS,
		examples = {"notes write shopping-list --text \"# Shopping list\\n\\nmilk\" --json"},
		run = cmd_write,
	},
	{
		verb = "append",
		summary = "add a line to the end of a note",
		effect = .Mutate,
		args = {{name = "note", kind = .String, help = "a title, a slug or a path", required = true}},
		flags = {{name = "text", kind = .String, help = "the line to add", required = true}},
		out = WROTE_FIELDS,
		examples = {"notes append shopping-list --text \"- bread\" --json"},
		run = cmd_append,
	},
	{
		verb = "rename",
		summary = "change a note's title, which renames its file",
		effect = .Mutate,
		args = {
			{name = "note", kind = .String, help = "a title, a slug or a path", required = true},
			{name = "title", kind = .String, help = "the new title", required = true},
		},
		out = WROTE_FIELDS,
		examples = {"notes rename shopping-list \"Groceries\" --json"},
		run = cmd_rename,
	},
	{
		verb = "delete",
		summary = "remove a note from the notebook",
		effect = .Destructive,
		args = {{name = "note", kind = .String, help = "a title, a slug or a path", required = true}},
		out = DELETED_FIELDS,
		examples = {"notes delete scratch --yes --json"},
		run = cmd_delete,
	},
	{
		verb = "shots",
		summary = "render the interface offscreen into a directory of PNGs",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, help = "where to write the PNGs", required = true}},
		out = {{name = "dir", kind = .String}},
		examples = {"notes shots /tmp/notes-shots"},
		run = cmd_shots,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "notes",
			summary    = "a notebook of real Markdown files",
			gui        = true,
			takes_path = false,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `A note is a Markdown file under ~/.local/share/palmy-notes, titled by its
first line. $PALMY_NOTES_DIR points the whole application — window and
commands alike — at a different notebook, which is how the self-test runs
without going near the real one.

<note> is matched against a path, a file name, a slug, and then a title,
case-insensitively; an unambiguous prefix of a title is enough. Nothing
matching exits 3.`

// ---------------------------------------------------------------------------
// Declared output
//
// Written out rather than built from shared variables: a package variable that
// points at another package variable is filled at load time, in declaration
// order, and COMMANDS above would capture it before it had anything in it.
// ---------------------------------------------------------------------------


LIST_FIELDS := []kit.Field {
	{
		name = "notes",
		kind = .Array,
		of = {
			{name = "title", kind = .String},
			{name = "slug", kind = .String},
			{name = "path", kind = .String},
			{name = "preview", kind = .String},
			{name = "words", kind = .Int},
			{name = "bytes", kind = .Int},
			{name = "modified", kind = .String},
		},
	},
	{name = "count", kind = .Int},
	{name = "dir", kind = .String, help = "the notebook these came from"},
}

READ_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "slug", kind = .String},
	{name = "path", kind = .String},
	{name = "words", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "modified", kind = .String},
	{name = "text", kind = .String, help = "the whole file"},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{
		name = "matches",
		kind = .Array,
		of = {
			{name = "title", kind = .String},
			{name = "slug", kind = .String},
			{name = "path", kind = .String},
			{name = "in_title", kind = .Bool},
			{name = "hits", kind = .Int, help = "matching lines in the body"},
			{name = "first_line", kind = .String, help = "the first matching line, trimmed"},
		},
	},
	{name = "count", kind = .Int},
}

PATH_FIELDS := []kit.Field {
	{name = "dir", kind = .String, help = "the notebook"},
	{name = "path", kind = .String, opt = true, help = "the note, when one was named"},
	{name = "exists", kind = .Bool},
}

WROTE_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "slug", kind = .String},
	{name = "path", kind = .String},
	{name = "words", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "created", kind = .Bool, help = "true when the note did not exist before"},
}

DELETED_FIELDS := []kit.Field {
	{name = "title", kind = .String},
	{name = "path", kind = .String},
	{name = "deleted", kind = .Bool},
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

@(private = "file")
iso :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// slug_of_path is the file name without its extension, which is the stable
// short name a caller can hold on to between commands.
@(private = "file")
slug_of_path :: proc(path: string) -> string {
	base := path
	if i := strings.last_index_byte(base, '/'); i >= 0 {
		base = base[i + 1:]
	}
	return strings.trim_suffix(base, ".md")
}

@(private = "file")
note_summary :: proc(n: Note) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "title", n.title)
	kit.jset_str(o, "slug", slug_of_path(n.path))
	kit.jset_str(o, "path", n.path)
	kit.jset_str(o, "preview", n.preview)
	kit.jset_int(o, "words", n.words)
	kit.jset_int(o, "bytes", n.bytes)
	kit.jset_str(o, "modified", iso(n.mtime))
	return o
}

// resolve finds the note a caller meant. A path, a file name, a slug, an exact
// title, then an unambiguous case-insensitive prefix of one — in that order,
// so a precise reference always beats a fuzzy one.
@(private = "file")
resolve :: proc(dir, ref: string) -> (n: Note, found: bool) {
	all := store_load(dir)
	if len(all) == 0 {
		return Note{}, false
	}
	want_slug := slug_of_path(ref)
	for it in all {
		if it.path == ref {
			return it, true
		}
	}
	for it in all {
		if slug_of_path(it.path) == want_slug {
			return it, true
		}
	}
	for it in all {
		if it.title == ref {
			return it, true
		}
	}
	// A case-insensitive title match, and then a prefix of one, but only when
	// exactly one note matches. Two candidates is not found; it is ambiguous,
	// and guessing would be the wrong answer silently.
	hit := -1
	count := 0
	for it, i in all {
		if len(it.title) == len(ref) && contains_fold(it.title, ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return all[hit], true
	}
	hit, count = -1, 0
	for it, i in all {
		if len(it.title) >= len(ref) && contains_fold(it.title[:len(ref)], ref) {
			hit, count = i, count + 1
		}
	}
	if count == 1 {
		return all[hit], true
	}
	return Note{}, false
}

@(private = "file")
not_found :: proc(c: ^kit.Call, ref: string) -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no note matching %q", ref)
	kit.cli_err_field(c, "note", ref)
	return code
}

// wrote_result is what every mutating command prints: the note as it now
// stands on disk, which is also exactly what a dry run would have produced.
@(private = "file")
wrote_result :: proc(c: ^kit.Call, path, body: string, created: bool) {
	title := title_of(body, context.temp_allocator)
	kit.jset_str(c.out, "title", title)
	kit.jset_str(c.out, "slug", slug_of_path(path))
	kit.jset_str(c.out, "path", path)
	kit.jset_int(c.out, "words", word_count(body))
	kit.jset_int(c.out, "bytes", len(body))
	kit.jset_bool(c.out, "created", created)
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	limit := kit.cli_int(c, "limit", 0)
	match := kit.cli_str(c, "match")
	arr := kit.jarr()
	for n in store_load(dir) {
		if match != "" && !contains_fold(n.title, match) && !contains_fold(n.body, match) {
			continue
		}
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		kit.jpush(arr, note_summary(n))
	}
	kit.jset(c.out, "notes", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	kit.jset_str(c.out, "dir", dir)
	return kit.EXIT_OK
}

@(private = "file")
cmd_read :: proc(c: ^kit.Call) -> int {
	ref := kit.cli_str(c, "note")
	n, ok := resolve(store_dir(), ref)
	if !ok {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "slug", slug_of_path(n.path))
	kit.jset_str(c.out, "path", n.path)
	kit.jset_int(c.out, "words", n.words)
	kit.jset_int(c.out, "bytes", n.bytes)
	kit.jset_str(c.out, "modified", iso(n.mtime))
	kit.jset_str(c.out, "text", n.body)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	q := kit.cli_str(c, "query")
	limit := kit.cli_int(c, "limit", 0)
	kit.jset_str(c.out, "query", q)
	arr := kit.jarr()
	for n in store_load(store_dir()) {
		in_title := contains_fold(n.title, q)
		hits := 0
		first := ""
		rest := n.body
		for line in strings.split_lines_iterator(&rest) {
			if contains_fold(line, q) {
				hits += 1
				if first == "" {
					first = strings.trim_space(line)
				}
			}
		}
		if !in_title && hits == 0 {
			continue
		}
		if limit > 0 && kit.jlen(arr) >= limit {
			break
		}
		o := kit.jobj()
		kit.jset_str(o, "title", n.title)
		kit.jset_str(o, "slug", slug_of_path(n.path))
		kit.jset_str(o, "path", n.path)
		kit.jset_bool(o, "in_title", in_title)
		kit.jset_int(o, "hits", hits)
		kit.jset_str(o, "first_line", first)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "matches", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_path :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	kit.jset_str(c.out, "dir", dir)
	ref := kit.cli_str(c, "note")
	if ref == "" {
		kit.jset_bool(c.out, "exists", os.is_dir(dir))
		return kit.EXIT_OK
	}
	n, ok := resolve(dir, ref)
	if !ok {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "path", n.path)
	kit.jset_bool(c.out, "exists", os.exists(n.path))
	return kit.EXIT_OK
}

@(private = "file")
cmd_new :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	title := kit.cli_str(c, "title")
	text := unescape_newlines(kit.cli_str(c, "text"))
	body := title == "" ? "New note\n\n" : fmt.tprintf("# %s\n\n%s", title, text)
	if text != "" && !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	want := unique_path(dir, slug(title_of(body, context.temp_allocator)), "")
	if c.dry_run {
		wrote_result(c, want, body, true)
		return kit.EXIT_OK
	}
	if err := os.write_entire_file(want, transmute([]u8)body); err != nil {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", want)
	}
	wrote_result(c, want, body, true)
	return kit.EXIT_OK
}

@(private = "file")
cmd_write :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	ref := kit.cli_str(c, "note")
	text := kit.cli_str(c, "text")
	file := kit.cli_str(c, "file")
	if text == "" && file == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "notes write needs --text or --file")
	}
	if file != "" {
		data, err := os.read_entire_file_from_path(file, context.temp_allocator)
		if err != nil {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", file)
		}
		text = string(data)
	}
	// A literal \n in a shell argument is almost always meant as a line break;
	// a note is line-oriented and a single-line note is rarely what was meant.
	text = unescape_newlines(text)
	if !strings.has_suffix(text, "\n") {
		text = fmt.tprintf("%s\n", text)
	}

	existing, found := resolve(dir, ref)
	old_path := found ? existing.path : ""
	if c.dry_run {
		want := unique_path(dir, slug(title_of(text, context.temp_allocator)), old_path)
		wrote_result(c, want, text, !found)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(dir, old_path, text)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write into %s", dir)
	}
	wrote_result(c, new_path, text, !found)
	return kit.EXIT_OK
}

@(private = "file")
cmd_append :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	ref := kit.cli_str(c, "note")
	n, found := resolve(dir, ref)
	if !found {
		return not_found(c, ref)
	}
	line := unescape_newlines(kit.cli_str(c, "text"))
	body := n.body
	if body != "" && !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	body = fmt.tprintf("%s%s\n", body, line)
	if c.dry_run {
		wrote_result(c, n.path, body, false)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(dir, n.path, body)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", n.path)
	}
	wrote_result(c, new_path, body, false)
	return kit.EXIT_OK
}

@(private = "file")
cmd_rename :: proc(c: ^kit.Call) -> int {
	dir := store_dir()
	ref := kit.cli_str(c, "note")
	n, found := resolve(dir, ref)
	if !found {
		return not_found(c, ref)
	}
	want := kit.cli_str(c, "title")

	// The title is the first line, so renaming is an edit to the text, which
	// is exactly what F2 does in the window. The heading marks are kept.
	rest := n.body
	first := ""
	for line in strings.split_lines_iterator(&rest) {
		first = line
		break
	}
	keep := ""
	t := strings.trim_left(first, " \t")
	if strings.has_prefix(t, "#") {
		h := 0
		for h < len(t) && t[h] == '#' {
			h += 1
		}
		keep = fmt.tprintf("%s ", t[:h])
	}
	tail := len(first) < len(n.body) ? n.body[len(first):] : "\n"
	body := fmt.tprintf("%s%s%s", keep, want, tail)

	if c.dry_run {
		wrote_result(c, unique_path(dir, slug(want), n.path), body, false)
		return kit.EXIT_OK
	}
	new_path, ok := store_write(dir, n.path, body)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not rename %s", n.path)
	}
	wrote_result(c, new_path, body, false)
	return kit.EXIT_OK
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	// The kit has already refused this if --yes was not given; by the time a
	// destructive body runs, consent is a fact rather than a question, and
	// nothing here has read a terminal.
	ref := kit.cli_str(c, "note")
	n, found := resolve(store_dir(), ref)
	if !found {
		return not_found(c, ref)
	}
	kit.jset_str(c.out, "title", n.title)
	kit.jset_str(c.out, "path", n.path)
	if c.dry_run {
		kit.jset_bool(c.out, "deleted", false)
		return kit.EXIT_OK
	}
	if !store_delete(n.path) {
		kit.jset_bool(c.out, "deleted", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not delete %s", n.path)
	}
	kit.jset_bool(c.out, "deleted", true)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if code := shots(dir); code != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render into %s", dir)
	}
	return kit.EXIT_OK
}

// unescape_newlines turns the two characters \n into a line break. A shell
// argument cannot carry a real one without quoting gymnastics, and a note is
// line-oriented, so the escape is worth honouring.
@(private = "file")
unescape_newlines :: proc(s: string) -> string {
	if !strings.contains(s, "\\n") && !strings.contains(s, "\\t") {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if i + 1 < len(s) && s[i] == '\\' {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n')
				i += 2
				continue
			case 't':
				strings.write_byte(&sb, '\t')
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}
