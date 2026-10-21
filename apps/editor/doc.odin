// The editing core, with no window.
//
// buffer.odin already was a core — a line array with undo — but the things an
// editor *does* with it lived in main.odin, wired to the Editor and its
// prompts: open a path that might not exist, replace every match, duplicate or
// delete a line, go to a line, decide the language. They are here now, over a
// Buffer and nothing else, and both front ends call them: the window from its
// commands and prompts, the command line (cli.odin) from `editor replace`,
// `editor edit`, `editor info` and the rest. A replacement made by `editor
// replace` is therefore the same edit, through the same search, as Ctrl-H F4
// in the window — and the self-test holds the two to that.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Opening and describing
// ---------------------------------------------------------------------------

// doc_open loads `path` into `b`. A path that does not exist yet is a new,
// empty buffer that will be written there — not an error — which is what the
// window has always done with `editor new-file.txt`.
doc_open :: proc(b: ^Buffer, path: string) -> (existed: bool) {
	if buf_load(b, path) {
		return true
	}
	buf_init_empty(b)
	b.path = strings.clone(path)
	return false
}

// doc_lang is the language the window picks for a buffer: the name first, then
// the shebang.
doc_lang :: proc(b: ^Buffer) -> Lang {
	return lang_detect(b.path, buf_line(b, 0))
}

// buf_serialize is exactly the bytes buf_save writes: the buffer's own line
// ending between lines, and the final newline if the file had one.
buf_serialize :: proc(b: ^Buffer, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	nl := b.eol == .CRLF ? "\r\n" : "\n"
	for i in 0 ..< len(b.lines) {
		if i > 0 {
			strings.write_string(&sb, nl)
		}
		strings.write_string(&sb, buf_line(b, i))
	}
	if b.final_nl && len(b.lines) > 0 && len(b.lines[len(b.lines) - 1].b) > 0 {
		strings.write_string(&sb, nl)
	}
	return strings.to_string(sb)
}

// buf_line_count is the number of lines a person would count: the empty line
// past a final newline is where the caret sits, not a line of the file.
buf_line_count :: proc(b: ^Buffer) -> int {
	n := len(b.lines)
	if n > 1 && b.final_nl && len(b.lines[n - 1].b) == 0 {
		return n - 1
	}
	return n
}

// ---------------------------------------------------------------------------
// Positions a person types: 1-based lines, 1-based characters
// ---------------------------------------------------------------------------

// char_to_col turns a 1-based character index on a line into a byte column.
// Past the end lands at the end; a character is a code point, not a byte, so
// `é` is one column whatever its encoding.
char_to_col :: proc(line: string, char1: int) -> int {
	want := max(0, char1 - 1)
	col := 0
	for k := 0; k < want && col < len(line); k += 1 {
		col = rune_right(line, col)
	}
	return col
}

// col_to_char is the other way: a byte column to a 1-based character.
col_to_char :: proc(line: string, col: int) -> int {
	return utf8.rune_count_in_string(line[:clamp(col, 0, len(line))]) + 1
}

// parse_pos reads `L` or `L:C` (1-based) into a buffer position. A line one
// past the last is the end of the buffer, so text can be appended.
parse_pos :: proc(b: ^Buffer, s: string) -> (at: Pos, ok: bool) {
	ls, cs := s, ""
	if i := strings.index_byte(s, ':'); i >= 0 {
		ls, cs = s[:i], s[i + 1:]
	}
	line, lok := parse_uint(ls)
	if !lok || line < 1 {
		return {}, false
	}
	char := 1
	if cs != "" {
		c, cok := parse_uint(cs)
		if !cok || c < 1 {
			return {}, false
		}
		char = c
	}
	if line > len(b.lines) {
		if line == len(b.lines) + 1 && char == 1 {
			return buf_end(b), true
		}
		return {}, false
	}
	l := buf_line(b, line - 1)
	return {line - 1, char_to_col(l, char)}, true
}

// parse_range reads `A:B`, `A-B`, `A,+N` or a single `A` as 1-based inclusive
// lines, clamped to the buffer. `B` may be `$` for the last line.
parse_range :: proc(b: ^Buffer, s: string) -> (first, last: int, ok: bool) {
	n := buf_line_count(b)
	sep := strings.index_any(s, ":-,")
	if sep < 0 {
		a, aok := parse_uint(s)
		if !aok || a < 1 || a > n {
			return 0, 0, false
		}
		return a, a, true
	}
	as_, bs := s[:sep], s[sep + 1:]
	a, aok := parse_uint(as_)
	if !aok || a < 1 {
		return 0, 0, false
	}
	z := n
	switch {
	case bs == "$" || bs == "":
	case strings.has_prefix(bs, "+"):
		k, kok := parse_uint(bs[1:])
		if !kok {
			return 0, 0, false
		}
		z = a + k
	case:
		zz, zok := parse_uint(bs)
		if !zok {
			return 0, 0, false
		}
		z = zz
	}
	z = min(z, n)
	if a > n || z < a {
		return 0, 0, false
	}
	return a, z, true
}

parse_uint :: proc(s: string) -> (int, bool) {
	if s == "" || len(s) > 9 {
		return 0, false
	}
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, true
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

Match :: struct {
	at:  Pos, // byte position of the start
	end: Pos,
}

// buf_find_all lists every match in document order, non-overlapping, the same
// way buf_count counts them — which is what the window's match counter shows.
buf_find_all :: proc(b: ^Buffer, needle: string, ci: bool, limit := 0, allocator := context.temp_allocator) -> (out: [dynamic]Match, truncated: bool) {
	out = make([dynamic]Match, allocator)
	if len(needle) == 0 || strings.index_byte(needle, '\n') >= 0 {
		return out, false
	}
	for i in 0 ..< len(b.lines) {
		l := buf_line(b, i)
		at := 0
		for {
			f := line_find(l, needle, at, ci)
			if f < 0 {
				break
			}
			if limit > 0 && len(out) >= limit {
				return out, true
			}
			append(&out, Match{{i, f}, {i, f + len(needle)}})
			at = f + len(needle)
		}
	}
	return out, false
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

// buf_replace_all replaces every match, front to back, as one undo step: one
// Ctrl-Z takes back the whole replace, which is what a person who just pressed
// "replace all" means by undo. It returns how many were replaced and where a
// caret at `cur` ends up.
buf_replace_all :: proc(b: ^Buffer, needle, with: string, ci: bool, cur: Pos, limit := 0) -> (n: int, cur_after: Pos) {
	cur_after = cur
	if needle == "" {
		return 0, cur
	}
	with := strings.clone(with, context.temp_allocator)
	group := buf_group(b)
	at := Pos{0, 0}
	for {
		if limit > 0 && n >= limit {
			break
		}
		found, ok := buf_search(b, needle, at, ci)
		// buf_search wraps; a match before where we are is the wrap.
		if !ok || pos_less(found, at) {
			break
		}
		end := Pos{found.line, found.col + len(needle)}
		buf_apply(b, found, end, with, cur, .No, group)
		at = pos_advance(found, with)
		n += 1
		if n > 200_000 {
			break
		}
	}
	return n, pos_clamp(b, cur)
}

// buf_replace_if_match replaces [lo,hi) with `with` when it holds `needle`,
// which is the window's Enter in the replace prompt: replace the match the
// selection is on, then move to the next.
buf_replace_if_match :: proc(b: ^Buffer, lo, hi: Pos, needle, with: string, ci: bool, cur: Pos) -> (end: Pos, replaced: bool) {
	got := buf_text(b, lo, hi, context.temp_allocator)
	same := ci ? strings.equal_fold(got, needle) : got == needle
	if !same || needle == "" {
		return cur, false
	}
	return buf_apply(b, lo, hi, with, cur, .No), true
}

// buf_dup_line copies line `li` below itself; the caret goes with the copy.
buf_dup_line :: proc(b: ^Buffer, li: int, cur: Pos) -> Pos {
	l := buf_line(b, li)
	at := Pos{li, len(l)}
	end := buf_apply(b, at, at, fmt.tprintf("\n%s", l), cur, .No)
	return Pos{end.line, min(cur.col, len(buf_line(b, end.line)))}
}

// buf_del_line removes line `li`, its newline with it.
buf_del_line :: proc(b: ^Buffer, li: int, cur: Pos) -> Pos {
	from := Pos{li, 0}
	to := li + 1 < buf_lines(b) ? Pos{li + 1, 0} : Pos{li, len(buf_line(b, li))}
	return buf_apply(b, from, to, "", cur, .No)
}

// buf_goto_line is the caret position for a 1-based line number, clamped.
buf_goto_line :: proc(b: ^Buffer, n: int) -> Pos {
	return pos_clamp(b, {clamp(n - 1, 0, buf_lines(b) - 1), 0})
}

// buf_replace_lines replaces whole lines [first,last] (1-based) with `text`,
// which may be several lines or none. It is `editor edit --lines`.
buf_replace_lines :: proc(b: ^Buffer, first, last: int, text: string, cur: Pos) -> Pos {
	from := Pos{first - 1, 0}
	to := Pos{last - 1, len(buf_line(b, last - 1))}
	return buf_apply(b, from, to, text, cur, .No)
}

// buf_set_final_newline decides whether the file ends with a newline. The
// buffer holds a final newline as an empty last line, so turning it off has to
// take that line away, not only clear the flag.
buf_set_final_newline :: proc(b: ^Buffer, on: bool) {
	n := len(b.lines)
	if !on && n > 1 && len(b.lines[n - 1].b) == 0 {
		prev := Pos{n - 2, len(b.lines[n - 2].b)}
		buf_apply(b, prev, Pos{n - 1, 0}, "", prev, .No)
	}
	b.final_nl = on
}

// ---------------------------------------------------------------------------
// Writing it out
// ---------------------------------------------------------------------------

// doc_write saves through buf_save, the window's own save. It is the only way
// either front end writes a file.
doc_write :: proc(b: ^Buffer, path: string) -> (ok: bool, why: string) {
	if path == "" {
		return false, "this buffer has no name yet"
	}
	if os.is_directory(path) {
		return false, fmt.tprintf("%s is a folder", path)
	}
	if !buf_save(b, path) {
		return false, fmt.tprintf("could not write %s", path)
	}
	return true, ""
}
