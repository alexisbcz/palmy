// A small multi-line text buffer for the composer.
//
// palmy gives a single-line `text_field` and the two measurements a real
// editor needs (`text_index_at`, `text_width_upto`); the line model, the
// cursor arithmetic and undo are the app's to own, so here they are. Lines are
// byte arrays and every move is rune-safe, which is what makes a unicode
// subject or an accented name editable rather than merely displayable.
package main

import "core:strings"

Pos :: struct {
	line: int,
	col:  int, // byte offset within the line
}

UNDO_LIMIT :: 96

Buffer :: struct {
	lines: [dynamic][dynamic]u8,
	cur:   Pos,
	// A composer body is kilobytes, so whole-text snapshots are the honest
	// trade: undo is exact and the code has no edge cases.
	undo:  [dynamic]Snapshot,
	redo:  [dynamic]Snapshot,
	dirty: bool,
}

Snapshot :: struct {
	text: string,
	cur:  Pos,
}

buf_init :: proc(b: ^Buffer, text := "") {
	buf_free(b)
	b.lines = make([dynamic][dynamic]u8, 0, 8)
	b.undo = make([dynamic]Snapshot, 0, 8)
	b.redo = make([dynamic]Snapshot, 0, 8)
	buf_set_text(b, text)
	b.cur = {0, 0}
	b.dirty = false
}

buf_free :: proc(b: ^Buffer) {
	for &l in b.lines {
		delete(l)
	}
	delete(b.lines)
	for s in b.undo {
		delete(s.text)
	}
	delete(b.undo)
	for s in b.redo {
		delete(s.text)
	}
	delete(b.redo)
	b.lines = nil
	b.undo = nil
	b.redo = nil
}

buf_set_text :: proc(b: ^Buffer, text: string) {
	for &l in b.lines {
		delete(l)
	}
	clear(&b.lines)
	rest := text
	// split_lines_iterator drops a trailing empty line, which a text buffer
	// must keep: "a\n" is two lines, the second empty.
	start := 0
	for i in 0 ..< len(rest) {
		if rest[i] == '\n' {
			buf_push_line(b, strings.trim_right(rest[start:i], "\r"))
			start = i + 1
		}
	}
	buf_push_line(b, strings.trim_right(rest[start:], "\r"))
	b.cur = buf_clamp(b, b.cur)
}

buf_push_line :: proc(b: ^Buffer, s: string) {
	l := make([dynamic]u8, 0, max(16, len(s)))
	append(&l, ..transmute([]u8)s)
	append(&b.lines, l)
}

buf_line_count :: proc(b: ^Buffer) -> int {
	return max(1, len(b.lines))
}

buf_line :: proc(b: ^Buffer, i: int) -> string {
	if i < 0 || i >= len(b.lines) {
		return ""
	}
	return string(b.lines[i][:])
}

buf_text :: proc(b: ^Buffer, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(b.lines) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(b, i))
	}
	return strings.to_string(sb)
}

buf_clamp :: proc(b: ^Buffer, at: Pos) -> Pos {
	q := at
	q.line = clamp(q.line, 0, max(0, len(b.lines) - 1))
	q.col = clamp(q.col, 0, len(buf_line(b, q.line)))
	// Never leave the cursor inside a multi-byte rune.
	line := buf_line(b, q.line)
	for q.col > 0 && q.col < len(line) && line[q.col] & 0xc0 == 0x80 {
		q.col -= 1
	}
	return q
}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

buf_checkpoint :: proc(b: ^Buffer) {
	append(&b.undo, Snapshot{buf_text(b), b.cur})
	if len(b.undo) > UNDO_LIMIT {
		delete(b.undo[0].text)
		ordered_remove(&b.undo, 0)
	}
	for s in b.redo {
		delete(s.text)
	}
	clear(&b.redo)
}

buf_undo :: proc(b: ^Buffer) -> bool {
	if len(b.undo) == 0 {
		return false
	}
	append(&b.redo, Snapshot{buf_text(b), b.cur})
	s := pop(&b.undo)
	buf_set_text(b, s.text)
	b.cur = buf_clamp(b, s.cur)
	delete(s.text)
	b.dirty = true
	return true
}

buf_redo :: proc(b: ^Buffer) -> bool {
	if len(b.redo) == 0 {
		return false
	}
	append(&b.undo, Snapshot{buf_text(b), b.cur})
	s := pop(&b.redo)
	buf_set_text(b, s.text)
	b.cur = buf_clamp(b, s.cur)
	delete(s.text)
	b.dirty = true
	return true
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

// buf_insert inserts text at the cursor, splitting the line on each newline.
buf_insert :: proc(b: ^Buffer, text: string) {
	if text == "" {
		return
	}
	b.cur = buf_clamp(b, b.cur)
	start := 0
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			buf_insert_run(b, text[start:i])
			buf_split_line(b)
			start = i + 1
		}
	}
	buf_insert_run(b, text[start:])
	b.dirty = true
}

@(private = "file")
buf_insert_run :: proc(b: ^Buffer, run: string) {
	if run == "" {
		return
	}
	if len(b.lines) == 0 {
		buf_push_line(b, "")
	}
	l := &b.lines[b.cur.line]
	inject_at_elems(l, b.cur.col, ..transmute([]u8)run)
	b.cur.col += len(run)
}

@(private = "file")
buf_split_line :: proc(b: ^Buffer) {
	if len(b.lines) == 0 {
		buf_push_line(b, "")
	}
	tail := strings.clone(buf_line(b, b.cur.line)[b.cur.col:], context.temp_allocator)
	resize(&b.lines[b.cur.line], b.cur.col)
	nl := make([dynamic]u8, 0, max(16, len(tail)))
	append(&nl, ..transmute([]u8)tail)
	inject_at(&b.lines, b.cur.line + 1, nl)
	b.cur.line += 1
	b.cur.col = 0
}

buf_newline :: proc(b: ^Buffer) {
	buf_checkpoint(b)
	b.cur = buf_clamp(b, b.cur)
	buf_split_line(b)
	b.dirty = true
}

// buf_backspace deletes the rune before the cursor, joining lines at column 0.
buf_backspace :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	if b.cur.col > 0 {
		line := buf_line(b, b.cur.line)
		n := rune_bytes_back(line, b.cur.col)
		remove_range(&b.lines[b.cur.line], b.cur.col - n, b.cur.col)
		b.cur.col -= n
		b.dirty = true
		return
	}
	if b.cur.line == 0 {
		return
	}
	buf_checkpoint(b)
	prev := b.cur.line - 1
	at := len(buf_line(b, prev))
	tail := strings.clone(buf_line(b, b.cur.line), context.temp_allocator)
	delete(b.lines[b.cur.line])
	ordered_remove(&b.lines, b.cur.line)
	append(&b.lines[prev], ..transmute([]u8)tail)
	b.cur = {prev, at}
	b.dirty = true
}

buf_delete_forward :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	line := buf_line(b, b.cur.line)
	if b.cur.col < len(line) {
		n := rune_bytes_forward(line, b.cur.col)
		remove_range(&b.lines[b.cur.line], b.cur.col, b.cur.col + n)
		b.dirty = true
		return
	}
	if b.cur.line + 1 >= len(b.lines) {
		return
	}
	buf_checkpoint(b)
	tail := strings.clone(buf_line(b, b.cur.line + 1), context.temp_allocator)
	delete(b.lines[b.cur.line + 1])
	ordered_remove(&b.lines, b.cur.line + 1)
	append(&b.lines[b.cur.line], ..transmute([]u8)tail)
	b.dirty = true
}

// buf_kill_to_end is Ctrl-K: clear to end of line, or join when already there.
buf_kill_to_end :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	if b.cur.col < len(buf_line(b, b.cur.line)) {
		buf_checkpoint(b)
		resize(&b.lines[b.cur.line], b.cur.col)
		b.dirty = true
		return
	}
	buf_delete_forward(b)
}

// buf_kill_to_start is Ctrl-U.
buf_kill_to_start :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	if b.cur.col == 0 {
		return
	}
	buf_checkpoint(b)
	remove_range(&b.lines[b.cur.line], 0, b.cur.col)
	b.cur.col = 0
	b.dirty = true
}

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

rune_bytes_back :: proc(s: string, at: int) -> int {
	n := 1
	for at - n > 0 && s[at - n] & 0xc0 == 0x80 {
		n += 1
	}
	return n
}

rune_bytes_forward :: proc(s: string, at: int) -> int {
	n := 1
	for at + n < len(s) && s[at + n] & 0xc0 == 0x80 {
		n += 1
	}
	return n
}

buf_left :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	if b.cur.col > 0 {
		b.cur.col -= rune_bytes_back(buf_line(b, b.cur.line), b.cur.col)
		return
	}
	if b.cur.line > 0 {
		b.cur.line -= 1
		b.cur.col = len(buf_line(b, b.cur.line))
	}
}

buf_right :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	line := buf_line(b, b.cur.line)
	if b.cur.col < len(line) {
		b.cur.col += rune_bytes_forward(line, b.cur.col)
		return
	}
	if b.cur.line + 1 < len(b.lines) {
		b.cur.line += 1
		b.cur.col = 0
	}
}

buf_up :: proc(b: ^Buffer) {
	if b.cur.line > 0 {
		b.cur.line -= 1
		b.cur = buf_clamp(b, b.cur)
	} else {
		b.cur.col = 0
	}
}

buf_down :: proc(b: ^Buffer) {
	if b.cur.line + 1 < len(b.lines) {
		b.cur.line += 1
		b.cur = buf_clamp(b, b.cur)
	} else {
		b.cur.col = len(buf_line(b, b.cur.line))
	}
}

buf_home :: proc(b: ^Buffer) {
	b.cur.col = 0
}

buf_end_of_line :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	b.cur.col = len(buf_line(b, b.cur.line))
}

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' ||
		(c >= '0' && c <= '9') ||
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		c >= 0x80
}

buf_word_left :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	if b.cur.col == 0 {
		buf_left(b)
		return
	}
	line := buf_line(b, b.cur.line)
	i := b.cur.col
	for i > 0 && !is_word_byte(line[i - 1]) {
		i -= 1
	}
	for i > 0 && is_word_byte(line[i - 1]) {
		i -= 1
	}
	b.cur.col = i
}

buf_word_right :: proc(b: ^Buffer) {
	b.cur = buf_clamp(b, b.cur)
	line := buf_line(b, b.cur.line)
	if b.cur.col >= len(line) {
		buf_right(b)
		return
	}
	i := b.cur.col
	for i < len(line) && is_word_byte(line[i]) {
		i += 1
	}
	for i < len(line) && !is_word_byte(line[i]) {
		i += 1
	}
	b.cur.col = i
}

buf_byte_len :: proc(b: ^Buffer) -> int {
	n := 0
	for i in 0 ..< len(b.lines) {
		n += len(b.lines[i]) + 1
	}
	return max(0, n - 1)
}

// ---------------------------------------------------------------------------
// Line_Edit — a single-line field the app drives itself.
//
// palmy's `text_field` owns its own focus through the Tab order, which fights
// a pane model and, more practically, cannot be driven by the recorder (it
// cannot click). So the header fields and the search box are edited here, with
// a byte cursor and rune-safe motion, and drawn with a caret positioned by
// `p.text_width_upto`.
// ---------------------------------------------------------------------------

Line_Edit :: struct {
	buf: [dynamic]u8,
	cur: int,
}

le_text :: proc(e: ^Line_Edit) -> string {
	return string(e.buf[:])
}

le_set :: proc(e: ^Line_Edit, text: string) {
	clear(&e.buf)
	append(&e.buf, ..transmute([]u8)text)
	e.cur = len(e.buf)
}

le_clear :: proc(e: ^Line_Edit) {
	clear(&e.buf)
	e.cur = 0
}

le_insert :: proc(e: ^Line_Edit, text: string) {
	if text == "" {
		return
	}
	e.cur = clamp(e.cur, 0, len(e.buf))
	inject_at_elems(&e.buf, e.cur, ..transmute([]u8)text)
	e.cur += len(text)
}

le_backspace :: proc(e: ^Line_Edit) -> bool {
	e.cur = clamp(e.cur, 0, len(e.buf))
	if e.cur == 0 {
		return false
	}
	n := rune_bytes_back(le_text(e), e.cur)
	remove_range(&e.buf, e.cur - n, e.cur)
	e.cur -= n
	return true
}

le_delete :: proc(e: ^Line_Edit) -> bool {
	e.cur = clamp(e.cur, 0, len(e.buf))
	if e.cur >= len(e.buf) {
		return false
	}
	n := rune_bytes_forward(le_text(e), e.cur)
	remove_range(&e.buf, e.cur, e.cur + n)
	return true
}

le_left :: proc(e: ^Line_Edit) {
	e.cur = clamp(e.cur, 0, len(e.buf))
	if e.cur > 0 {
		e.cur -= rune_bytes_back(le_text(e), e.cur)
	}
}

le_right :: proc(e: ^Line_Edit) {
	e.cur = clamp(e.cur, 0, len(e.buf))
	if e.cur < len(e.buf) {
		e.cur += rune_bytes_forward(le_text(e), e.cur)
	}
}

le_home :: proc(e: ^Line_Edit) {
	e.cur = 0
}

le_end :: proc(e: ^Line_Edit) {
	e.cur = len(e.buf)
}

le_free :: proc(e: ^Line_Edit) {
	delete(e.buf)
	e.buf = nil
	e.cur = 0
}
