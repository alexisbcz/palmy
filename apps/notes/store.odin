// The store: notes are real files.
//
// One Markdown file per note under ~/.local/share/palmy-notes, named after its
// title so the directory is readable with `ls` and editable with any other
// editor. The title is the first line, the way it is in every notes app worth
// using — there is no separate metadata file to fall out of sync.
package main

import "core:os"
import "core:strings"
import "core:time"

DIR_NAME :: "palmy-notes"

Note :: struct {
	path:     string,
	title:    string, // first line, trimmed of leading #
	preview:  string, // the next non-empty line
	body:     string, // the whole file, kept for searching
	mtime:    time.Time,
	words:    int,
	bytes:    int,
}

note_free :: proc(n: Note) {
	delete(n.path)
	delete(n.title)
	delete(n.preview)
	delete(n.body)
}

// store_dir makes sure the directory exists and returns it.
//
// $PALMY_NOTES_DIR moves the whole notebook, window and commands alike. It is
// what lets the self-test drive the real `notes write` and `notes delete`
// against a scratch directory, which is the only honest way to test a command
// that deletes files: anything less is testing a different program.
store_dir :: proc() -> string {
	if over := os.get_env("PALMY_NOTES_DIR", context.temp_allocator); over != "" {
		if !os.is_dir(over) {
			os.make_directory_all(over)
		}
		return strings.clone(over)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	base := tfmt("%s/.local/share", home)
	if !os.is_dir(base) {
		os.make_directory(base)
	}
	dir := tfmt("%s/%s", base, DIR_NAME)
	if !os.is_dir(dir) {
		os.make_directory(dir)
	}
	return strings.clone(dir)
}

// title_of derives a note's title from its text: the first non-empty line,
// with Markdown heading marks and list bullets stripped.
title_of :: proc(body: string, allocator := context.allocator) -> string {
	rest := body
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
	rest := body
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

// store_load reads every note in the directory, newest first.
store_load :: proc(dir: string) -> [dynamic]Note {
	out := make([dynamic]Note, 0, 32)

	handle, err := os.open(dir)
	if err != nil {
		return out
	}
	defer os.close(handle)
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return out
	}

	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".md") {
			continue
		}
		path := tfmt("%s/%s", dir, info.name)
		data, ok := os.read_entire_file_from_path(path, context.temp_allocator)
		if ok != nil {
			continue
		}
		body := string(data)
		n := Note {
			path  = strings.clone(path),
			body  = strings.clone(body),
			mtime = info.modification_time,
			words = word_count(body),
			bytes = len(body),
		}
		n.title = title_of(n.body)
		n.preview = preview_of(n.body, n.title)
		append(&out, n)
	}

	// Newest first, which is the order a notes list is useful in.
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && out[j].mtime._nsec > out[j - 1].mtime._nsec {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out
}

// store_write saves a note's text, renaming the file when the title changed so
// the directory keeps reading like a list of titles.
store_write :: proc(dir: string, path: string, body: string) -> (new_path: string, ok: bool) {
	title := title_of(body, context.temp_allocator)
	want := unique_path(dir, slug(title), path)

	if werr := os.write_entire_file(want, transmute([]u8)body); werr != nil {
		return path, false
	}
	if want != path && path != "" && os.exists(path) {
		os.remove(path)
	}
	return strings.clone(want), true
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
	body := "New note\n\n"
	p := unique_path(dir, "new-note", "")
	if werr := os.write_entire_file(p, transmute([]u8)body); werr != nil {
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
