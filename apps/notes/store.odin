// The store: notes are real files.
//
// One Markdown file per note under the identity's folder (ident.odin), named
// after its title so the directory is readable with `ls` and editable with any
// other editor. The title is the first line of the body, the way it is in every
// notes app worth using. A folder is a notebook; `.trash/` is the trash;
// `Shared/<owner>/` holds what other identities shared with this one.
//
// A small block of front matter (front.odin) carries the note's stable id,
// its tags and whether it is pinned. The editor never shows it: what you edit
// is the body, and the front matter is written back around it unchanged.
package main

import "core:hash"
import ck "../cloudkit"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

TRASH_DIR :: ".trash"
SHARED_DIR :: "Shared"
ATTACH_DIR :: "attachments"

Note :: struct {
	path:     string, // absolute
	rel:      string, // relative to the identity's folder
	title:    string, // first line of the body, trimmed of leading #
	preview:  string, // the next non-empty line
	body:     string, // the Markdown, without front matter
	meta:     Meta,
	notebook: string, // the folder, "" for the inbox; "Shared/<owner>" for a shared note
	tags:     [dynamic]string, // front matter tags and #hashtags in the body
	trashed:  bool,
	shared:   bool, // someone else's note, shared with this identity
	mtime:    time.Time,
	words:    int,
	bytes:    int,
	ident:    int, // which identity's folder it came from (an index the caller sets)
}

note_free :: proc(n: Note) {
	n := n
	delete(n.path)
	delete(n.rel)
	delete(n.title)
	delete(n.preview)
	delete(n.body)
	meta_free(&n.meta)
	delete(n.notebook)
	for t in n.tags {delete(t)}
	delete(n.tags)
}

notes_free :: proc(xs: ^[dynamic]Note) {
	for n in xs {note_free(n)}
	delete(xs^)
	xs^ = nil
}

// store_dir is the folder the window and the commands use when there is one
// notebook and no identities: $PALMY_NOTES_DIR, or the first identity's.
store_dir :: proc() -> string {
	if over := os.get_env("PALMY_NOTES_DIR", context.temp_allocator); over != "" {
		if !os.is_dir(over) {
			ck.make_dirs(over)
		}
		return strings.clone(over)
	}
	ids := idents_load(context.temp_allocator)
	if len(ids) > 0 {
		return strings.clone(ids[0].root)
	}
	return notes_home()
}

// title_of derives a note's title from its text: the first non-empty line,
// with Markdown heading marks and list bullets stripped. Front matter, if the
// text still has it, is skipped.
title_of :: proc(body: string, allocator := context.allocator) -> string {
	_, rest, _ := split_front(body)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		t = strings.trim_left(t, "#")
		t = strings.trim_left(t, ">")
		t = strings.trim_space(t)
		if t == "" {
			continue
		}
		if len(t) > 80 {
			t = t[:80]
		}
		return strings.clone(t, allocator)
	}
	return strings.clone("Untitled note", allocator)
}

preview_of :: proc(body: string, title: string, allocator := context.allocator) -> string {
	seen_title := false
	_, rest, _ := split_front(body)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		if !seen_title {
			seen_title = true
			continue
		}
		t = strings.trim_left(t, "#")
		t = strings.trim_left(t, ">")
		t = strings.trim_left(t, "-*")
		t = strings.trim_space(t)
		if strings.has_prefix(t, "[ ] ") || strings.has_prefix(t, "[x] ") {
			t = t[4:]
		}
		if t == "" {
			continue
		}
		if len(t) > 120 {
			t = t[:120]
		}
		return strings.clone(t, allocator)
	}
	return strings.clone("", allocator)
}

word_count :: proc(s: string) -> int {
	n := 0
	in_word := false
	for i in 0 ..< len(s) {
		c := s[i]
		space := c == ' ' || c == '\t' || c == '\n' || c == '\r'
		if !space && !in_word {
			n += 1
		}
		in_word = !space
	}
	return n
}

// slug turns a title into a file name: lowercase, words joined by hyphens.
slug :: proc(title: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	dash := false
	for i in 0 ..< len(title) {
		c := title[i]
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&sb, c + 32)
			dash = false
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_byte(&sb, c)
			dash = false
		case:
			if !dash && strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, '-')
				dash = true
			}
		}
		if strings.builder_len(sb) >= 48 {
			break
		}
	}
	out := strings.trim_right(strings.to_string(sb), "-")
	if out == "" {
		return strings.clone("untitled", allocator)
	}
	return out
}

fnv :: proc(s: string) -> u64 {
	return hash.fnv64a(transmute([]u8)s)
}

dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[:i]
	}
	return "."
}

base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

// note_from_text fills a Note from a file's text: front matter, body and
// everything derived from them. `rel` places it in its notebook.
note_from_text :: proc(path, rel, text: string, mtime: time.Time) -> Note {
	front, body, _ := split_front(text)
	n := Note {
		path  = strings.clone(path),
		rel   = strings.clone(rel),
		body  = strings.clone(body),
		meta  = parse_front(front),
		mtime = mtime,
		words = word_count(body),
		bytes = len(text),
	}
	n.title = title_of(n.body)
	n.preview = preview_of(n.body, n.title)
	folder := dir_of(rel)
	if folder == "." {
		folder = ""
	}
	if folder == TRASH_DIR || strings.has_prefix(folder, TRASH_DIR + "/") {
		n.trashed = true
		folder = strings.trim_prefix(strings.trim_prefix(folder, TRASH_DIR), "/")
	}
	if folder == SHARED_DIR || strings.has_prefix(folder, SHARED_DIR + "/") || n.meta.shared_from != "" {
		n.shared = true
	}
	n.notebook = strings.clone(folder)
	n.tags = make([dynamic]string)
	for t in n.meta.tags {add_tag(&n.tags, t)}
	inline_tags(n.body, &n.tags)
	return n
}

// store_load reads every note under an identity's folder, newest first,
// pinned notes first of all. Hidden folders are skipped except the trash.
store_load :: proc(dir: string) -> [dynamic]Note {
	out := make([dynamic]Note, 0, 32)
	walk(dir, "", &out, 0)
	slice.sort_by(out[:], proc(a, b: Note) -> bool {
		if a.meta.pinned != b.meta.pinned {
			return a.meta.pinned
		}
		return a.mtime._nsec > b.mtime._nsec
	})
	return out
}

@(private = "file")
walk :: proc(root, rel: string, out: ^[dynamic]Note, depth: int) {
	if depth > 8 {
		return
	}
	dir := rel == "" ? root : tfmt("%s/%s", root, rel)
	handle, err := os.open(dir)
	if err != nil {
		return
	}
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil {
		return
	}
	for info in infos {
		child := rel == "" ? strings.clone(info.name, context.temp_allocator) : tfmt("%s/%s", rel, info.name)
		if info.type == .Directory {
			if strings.has_prefix(info.name, ".") && !(rel == "" && info.name == TRASH_DIR) {
				continue
			}
			if rel == "" && info.name == ATTACH_DIR {
				continue
			}
			walk(root, child, out, depth + 1)
			continue
		}
		if !strings.has_suffix(info.name, ".md") || strings.has_prefix(info.name, ".") {
			continue
		}
		path := tfmt("%s/%s", root, child)
		data, ok := os.read_entire_file_from_path(path, context.temp_allocator)
		if ok != nil {
			continue
		}
		append(out, note_from_text(path, child, string(data), info.modification_time))
	}
}

// store_write saves a note's text, renaming the file when the title changed so
// the directory keeps reading like a list of titles. The note stays in its
// notebook. Text without front matter keeps the front matter the file had;
// a new file gets an id.
store_write :: proc(dir: string, path: string, body: string) -> (new_path: string, ok: bool) {
	front, text, has := split_front(body)
	meta: Meta
	if has {
		meta = parse_front(front, context.temp_allocator)
	} else if path != "" {
		if old, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
			f, _, _ := split_front(string(old))
			meta = parse_front(f, context.temp_allocator)
		}
	}
	if meta.id == "" {
		meta.id = new_id(context.temp_allocator)
	}
	folder := path != "" ? dir_of(path) : dir
	title := title_of(text, context.temp_allocator)
	want := unique_path(folder, slug(title), path)
	whole := compose(meta, text)

	if werr := os.write_entire_file(want, transmute([]u8)whole); werr != nil {
		return path, false
	}
	if want != path && path != "" && os.exists(path) {
		os.remove(path)
	}
	return strings.clone(want), true
}

// store_write_meta rewrites a note's front matter, leaving its body alone.
store_write_meta :: proc(path: string, meta: Meta) -> bool {
	old, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return false
	}
	_, body, _ := split_front(string(old))
	return os.write_entire_file(path, transmute([]u8)compose(meta, body)) == nil
}

// unique_path is `<dir>/<base>.md`, with a counter appended if that name is
// taken by a different note.
unique_path :: proc(dir, base, mine: string) -> string {
	first := tfmt("%s/%s.md", dir, base)
	if !os.exists(first) || first == mine {
		return first
	}
	for i in 2 ..< 500 {
		cand := tfmt("%s/%s-%d.md", dir, base, i)
		if !os.exists(cand) || cand == mine {
			return cand
		}
	}
	return mine == "" ? first : mine
}

store_create :: proc(dir: string) -> (path: string, ok: bool) {
	return store_create_in(dir, "", "New note\n\n")
}

// store_create_in writes a new note into a notebook folder of `root`.
store_create_in :: proc(root, notebook, body: string, id := "") -> (path: string, ok: bool) {
	folder := notebook == "" ? root : tfmt("%s/%s", root, notebook)
	if !os.is_dir(folder) {
		ck.make_dirs(folder)
	}
	meta := Meta {
		id = id != "" ? id : new_id(context.temp_allocator),
	}
	p := unique_path(folder, slug(title_of(body, context.temp_allocator)), "")
	if werr := os.write_entire_file(p, transmute([]u8)compose(meta, body)); werr != nil {
		return "", false
	}
	return strings.clone(p), true
}

store_delete :: proc(path: string) -> bool {
	if path == "" || !strings.has_suffix(path, ".md") {
		return false
	}
	return os.remove(path) == nil
}

// store_move puts a note into another folder of its identity: a notebook,
// the trash, or back out of it. The file keeps its name.
store_move :: proc(root, path, folder: string) -> (new_path: string, ok: bool) {
	dest := folder == "" ? root : tfmt("%s/%s", root, folder)
	if !os.is_dir(dest) {
		ck.make_dirs(dest)
	}
	name := strings.trim_suffix(base_name(path), ".md")
	want := unique_path(dest, name, path)
	if want == path {
		return strings.clone(path), true
	}
	if os.rename(path, want) != nil {
		return path, false
	}
	return strings.clone(want), true
}

// store_trash moves a note into `.trash/<its notebook>` so restoring it puts
// it back where it was; store_restore is the reverse.
store_trash :: proc(root: string, n: Note) -> (string, bool) {
	if n.trashed {
		return strings.clone(n.path), true
	}
	folder := n.notebook == "" ? TRASH_DIR : tfmt("%s/%s", TRASH_DIR, n.notebook)
	return store_move(root, n.path, folder)
}

store_restore :: proc(root: string, n: Note) -> (string, bool) {
	if !n.trashed {
		return strings.clone(n.path), true
	}
	return store_move(root, n.path, n.notebook)
}

// Notebook is a folder of an identity that holds notes, with a count.
Notebook :: struct {
	name:  string,
	count: int,
}

// notebooks_of lists one identity's notebooks, the inbox excluded. The trash
// and the shared folder are not notebooks.
notebooks_of :: proc(all: []Note, ident: int, allocator := context.temp_allocator) -> []Notebook {
	out := make([dynamic]Notebook, allocator)
	for n in all {
		if n.ident != ident || n.trashed || n.shared || n.notebook == "" {
			continue
		}
		found := false
		for &b in out {
			if b.name == n.notebook {
				b.count += 1
				found = true
			}
		}
		if !found {
			append(&out, Notebook{n.notebook, 1})
		}
	}
	slice.sort_by(out[:], proc(a, b: Notebook) -> bool {return a.name < b.name})
	return out[:]
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

contains_fold :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(hay) {
		return false
	}
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		hit := true
		for j in 0 ..< len(needle) {
			if fold(hay[i + j]) != fold(needle[j]) {
				hit = false
				break
			}
		}
		if hit {
			return true
		}
	}
	return false
}

// match_line is the line of the body that contains the query, for the result
// list — showing *where* a note matched is the difference between a search and
// a filter.
match_line :: proc(body, needle: string, allocator := context.temp_allocator) -> string {
	if needle == "" {
		return ""
	}
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		if contains_fold(line, needle) {
			t := strings.trim_space(line)
			if len(t) > 110 {
				t = t[:110]
			}
			return strings.clone(t, allocator)
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

local_offset :: proc() -> i64 {
	// The timezone database is not linked in, so the offset comes from the
	// difference the kernel already applied: `date +%z` is the one portable
	// way to ask without a dependency.
	out, ok := run_cmd({"date", "+%z"})
	if !ok || len(out) < 5 {
		return 0
	}
	sign := i64(out[0] == '-' ? -1 : 1)
	h := i64(out[1] - '0') * 10 + i64(out[2] - '0')
	m := i64(out[3] - '0') * 10 + i64(out[4] - '0')
	return sign * (h * 3600 + m * 60)
}

MONTHS := [?]string {
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
}

// human_date is "14:32" today, "Yesterday", a weekday this week, then a date.
human_date :: proc(t, now: time.Time, offset: i64, allocator := context.temp_allocator) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	lnow := time.Time{_nsec = now._nsec + offset * 1_000_000_000}
	y, m, d := time.date(local)
	ny, nm, nd := time.date(lnow)
	hh, mm, _ := time.clock(local)

	if y == ny && m == nm && d == nd {
		return strings.clone(tfmt("%02d:%02d", hh, mm), allocator)
	}
	yd := time.Time{_nsec = lnow._nsec - 86_400 * 1_000_000_000}
	yy, ym, ydd := time.date(yd)
	if y == yy && m == ym && d == ydd {
		return strings.clone("Yesterday", allocator)
	}
	if y == ny {
		return strings.clone(tfmt("%d %s", d, MONTHS[int(m) - 1]), allocator)
	}
	return strings.clone(tfmt("%d %s %d", d, MONTHS[int(m) - 1], y), allocator)
}
