package main

// A unified diff, as `git diff` prints it, read into files and lines with
// both line numbers worked out — what the review view draws and what a line
// comment is anchored to (the new side's number, as on every forge).

import "core:strconv"
import "core:strings"

Diff_Kind :: enum u8 {
	Context,
	Add,
	Del,
	Hunk, // "@@ -a,b +c,d @@ section"
}

Diff_Line :: struct {
	kind:   Diff_Kind,
	old_no: int, // 0 when the line is not on that side
	new_no: int,
	text:   string,
}

Diff_File :: struct {
	old_path, new_path: string,
	status:             string, // modified | added | deleted | renamed | binary
	additions:          int,
	deletions:          int,
	lines:              [dynamic]Diff_Line,
}

// base_of is the file name of a path (syntax_lang.odin wants it; in
// apps/editor it lives in main.odin).
base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

diff_path :: proc(f: Diff_File) -> string {
	return f.old_path if f.status == "deleted" else f.new_path
}

// parse_diff never fails: what it does not recognise is skipped.
parse_diff :: proc(text: string, allocator := context.allocator) -> []Diff_File {
	context.allocator = allocator
	files := make([dynamic]Diff_File)
	cur: ^Diff_File
	old_no, new_no := 0, 0
	for line in strings.split_lines(text) {
		switch {
		case strings.has_prefix(line, "diff --git "):
			append(&files, Diff_File{status = "modified"})
			cur = &files[len(files) - 1]
			// "diff --git a/x b/x": a fallback when ---/+++ are absent (binary, mode-only)
			rest := line[len("diff --git "):]
			if sp := strings.index(rest, " b/"); sp >= 0 {
				cur.old_path = strings.trim_prefix(rest[:sp], "a/")
				cur.new_path = rest[sp + 3:]
			}
		case cur == nil:
			continue
		case strings.has_prefix(line, "new file mode"):
			cur.status = "added"
		case strings.has_prefix(line, "deleted file mode"):
			cur.status = "deleted"
		case strings.has_prefix(line, "rename from "):
			cur.status = "renamed"
			cur.old_path = line[len("rename from "):]
		case strings.has_prefix(line, "rename to "):
			cur.new_path = line[len("rename to "):]
		case strings.has_prefix(line, "Binary files "):
			cur.status = "binary"
		case strings.has_prefix(line, "--- "):
			if p := line[4:]; p != "/dev/null" {
				cur.old_path = strings.trim_prefix(p, "a/")
			}
		case strings.has_prefix(line, "+++ "):
			if p := line[4:]; p != "/dev/null" {
				cur.new_path = strings.trim_prefix(p, "b/")
			}
		case strings.has_prefix(line, "@@"):
			// @@ -12,7 +12,9 @@ optional section heading
			old_no, new_no = 0, 0
			fields := strings.fields(line, context.temp_allocator)
			for f in fields {
				if strings.has_prefix(f, "-") && old_no == 0 {
					n, _ := strconv.parse_int(strings.split_n(f[1:], ",", 2, context.temp_allocator)[0])
					old_no = n
				} else if strings.has_prefix(f, "+") && new_no == 0 {
					n, _ := strconv.parse_int(strings.split_n(f[1:], ",", 2, context.temp_allocator)[0])
					new_no = n
				}
			}
			append(&cur.lines, Diff_Line{kind = .Hunk, text = line})
		case strings.has_prefix(line, "+"):
			append(&cur.lines, Diff_Line{kind = .Add, new_no = new_no, text = line[1:]})
			new_no += 1
			cur.additions += 1
		case strings.has_prefix(line, "-"):
			append(&cur.lines, Diff_Line{kind = .Del, old_no = old_no, text = line[1:]})
			old_no += 1
			cur.deletions += 1
		case strings.has_prefix(line, " "):
			append(&cur.lines, Diff_Line{kind = .Context, old_no = old_no, new_no = new_no, text = line[1:]})
			old_no += 1
			new_no += 1
		case strings.has_prefix(line, "\\"):
			// "\ No newline at end of file"
		}
	}
	return files[:]
}
