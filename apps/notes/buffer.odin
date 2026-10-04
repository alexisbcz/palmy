// The text buffer, shared in spirit with apps/editor: a line array of
// [dynamic]u8, with an undo stack of replacements. Odin packages are not
// shared between apps, so this is a copy rather than an import.
//
// The structure is a **line array**: a `[dynamic]Line`, each line its own
// `[dynamic]u8` of UTF-8 bytes with no terminator. The choice is deliberate.
//
// A gap buffer is cheaper for a long run of typing at one point, but every
// line-oriented question an editor actually asks — "what is on screen", "what
// is the line number", "how wide is the longest visible line" — is O(1) here
// and O(n) scanning there. Rendering a window of 40 lines out of half a million
// has to be 40 lookups, not a scan, and the gutter needs line numbers anyway.
//
// The costs the line array pays are bounded and measured:
//   - editing inside a line is a memmove of that line only;
//   - splitting or joining a line is one memmove of the line *descriptors*
//     (40 bytes each), not of the text;
//   - a multi-line insert opens the gap once with a single copy rather than
//     inject_at per line, so pasting 1000 lines is one memmove.
//
// Undo is a stack of replacements: each Edit is (position, text removed, text
// inserted) plus the cursor either side, so undo and redo are the same
// operation run in opposite directions. Consecutive typing and consecutive
// backspaces coalesce into one Edit so that undo steps feel like words rather
// than keystrokes.
package main

import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Pos is a caret location: a line index and a *byte* offset into that line.
// Byte offsets keep every edit a slice operation; the UI converts to columns
// for display, which is the only place a multi-byte rune matters.
Pos :: struct {
	line: int,
	col:  int,
}

Line :: struct {
	b: [dynamic]u8,
}

Coalesce :: enum {
	No, // start a new undo entry
	Type, // may extend a preceding insert
	Back, // may extend a preceding backwards delete
}

Edit :: struct {
	at:         Pos,
	removed:    string, // what was there (owned)
	added:      string, // what replaced it (owned)
	cur_before: Pos,
	cur_after:  Pos,
	kind:       Coalesce,
}

Eol :: enum {
	LF,
	CRLF,
}

Buffer :: struct {
	lines:     [dynamic]Line,
	path:      string, // "" for an unnamed buffer
	eol:       Eol,
	encoding:  string, // "UTF-8" or "Binary"
	final_nl:  bool, // the file ended with a newline
	undo:      [dynamic]Edit,
	redo:      [dynamic]Edit,
	save_mark: int, // len(undo) when last saved, -1 when unreachable
	open_ok:   bool, // the path existed and was read
}

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------

pos_eq :: proc(a, b: Pos) -> bool {
	return a.line == b.line && a.col == b.col
}

pos_less :: proc(a, b: Pos) -> bool {
	if a.line != b.line {
		return a.line < b.line
	}
	return a.col < b.col
}

pos_order :: proc(a, b: Pos) -> (lo, hi: Pos) {
	if pos_less(b, a) {
		return b, a
	}
	return a, b
}

// pos_advance is where a caret lands after `text` is inserted at `at`.
pos_advance :: proc(at: Pos, text: string) -> Pos {
	out := at
	last_nl := -1
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			out.line += 1
			last_nl = i
		}
	}
	if last_nl >= 0 {
		out.col = len(text) - last_nl - 1
	} else {
		out.col += len(text)
	}
	return out
}

buf_lines :: proc(b: ^Buffer) -> int {
	return len(b.lines)
}

buf_line :: proc(b: ^Buffer, i: int) -> string {
	if i < 0 || i >= len(b.lines) {
		return ""
	}
	return string(b.lines[i].b[:])
}

buf_end :: proc(b: ^Buffer) -> Pos {
	n := len(b.lines)
	if n == 0 {
		return {0, 0}
	}
	return {n - 1, len(b.lines[n - 1].b)}
}

pos_clamp :: proc(b: ^Buffer, p: Pos) -> Pos {
	out := p
	out.line = clamp(out.line, 0, max(0, len(b.lines) - 1))
	l := buf_line(b, out.line)
	out.col = clamp(out.col, 0, len(l))
	// Never leave the caret inside a rune.
	for out.col > 0 && out.col < len(l) && l[out.col] & 0xc0 == 0x80 {
		out.col -= 1
	}
	return out
}

// ---------------------------------------------------------------------------
// Line array mechanics
// ---------------------------------------------------------------------------

@(private = "file")
lines_gap :: proc(b: ^Buffer, at, n: int) {
	if n <= 0 {
		return
	}
	old := len(b.lines)
	resize(&b.lines, old + n)
	if at < old {
		// One memmove of the descriptors. The text itself never moves.
		copy(b.lines[at + n:], b.lines[at:old])
	}
	for i in at ..< at + n {
		b.lines[i] = Line{}
	}
}

@(private = "file")
lines_drop :: proc(b: ^Buffer, at, n: int) {
	if n <= 0 {
		return
	}
	for i in at ..< min(at + n, len(b.lines)) {
		delete(b.lines[i].b)
	}
	old := len(b.lines)
	if at + n < old {
		copy(b.lines[at:], b.lines[at + n:old])
	}
	resize(&b.lines, max(0, old - n))
}

@(private = "file")
line_set :: proc(l: ^Line, s: string) {
	clear(&l.b)
	append(&l.b, ..transmute([]u8)s)
}

// buf_text copies the text between two positions, newlines included.
buf_text :: proc(b: ^Buffer, from, to: Pos, allocator := context.allocator) -> string {
	lo, hi := pos_order(from, to)
	lo, hi = pos_clamp(b, lo), pos_clamp(b, hi)
	if pos_eq(lo, hi) {
		return strings.clone("", allocator)
	}
	sb := strings.builder_make(allocator)
	if lo.line == hi.line {
		strings.write_string(&sb, buf_line(b, lo.line)[lo.col:hi.col])
	} else {
		strings.write_string(&sb, buf_line(b, lo.line)[lo.col:])
		for i in lo.line + 1 ..< hi.line {
			strings.write_byte(&sb, '\n')
			strings.write_string(&sb, buf_line(b, i))
		}
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, buf_line(b, hi.line)[:hi.col])
	}
	return strings.to_string(sb)
}

// raw_delete removes a range and returns what it removed. No undo bookkeeping.
@(private = "file")
raw_delete :: proc(b: ^Buffer, from, to: Pos) -> string {
	lo, hi := pos_order(from, to)
	out := buf_text(b, lo, hi)
	if pos_eq(lo, hi) {
		return out
	}
	if lo.line == hi.line {
		remove_range(&b.lines[lo.line].b, lo.col, hi.col)
		return out
	}
	head := strings.clone(buf_line(b, lo.line)[:lo.col], context.temp_allocator)
	tail := strings.clone(buf_line(b, hi.line)[hi.col:], context.temp_allocator)
	line_set(&b.lines[lo.line], head)
	append(&b.lines[lo.line].b, ..transmute([]u8)tail)
	lines_drop(b, lo.line + 1, hi.line - lo.line)
	return out
}

// raw_insert puts text in at a position and returns where it ends.
@(private = "file")
raw_insert :: proc(b: ^Buffer, at: Pos, text: string) -> Pos {
	if len(text) == 0 {
		return at
	}
	if len(b.lines) == 0 {
		append(&b.lines, Line{})
	}
	p := pos_clamp(b, at)

	nl := strings.index_byte(text, '\n')
	if nl < 0 {
		inject_at_elems(&b.lines[p.line].b, p.col, ..transmute([]u8)text)
		return {p.line, p.col + len(text)}
	}

	segs := strings.split(text, "\n", context.temp_allocator)
	tail := strings.clone(buf_line(b, p.line)[p.col:], context.temp_allocator)

	resize(&b.lines[p.line].b, p.col)
	append(&b.lines[p.line].b, ..transmute([]u8)segs[0])

	extra := len(segs) - 1
	lines_gap(b, p.line + 1, extra)
	for i in 1 ..< len(segs) {
		line_set(&b.lines[p.line + i], segs[i])
	}
	last := p.line + extra
	end := Pos{last, len(b.lines[last].b)}
	append(&b.lines[last].b, ..transmute([]u8)tail)
	return end
}

// ---------------------------------------------------------------------------
// Edits, with undo
// ---------------------------------------------------------------------------

// The editor app caches per-line highlighting state here; notes has no
// highlighter, so this is the seam left open rather than a second copy of
// buf_apply that does not call it.
buf_invalidate :: proc(b: ^Buffer, from_line: int) {
}

// buf_apply replaces [from,to) with text, records it for undo, and returns the
// caret position after the change.
buf_apply :: proc(
	b: ^Buffer,
	from, to: Pos,
	text: string,
	cur_before: Pos,
	coalesce := Coalesce.No,
) -> Pos {
	lo, hi := pos_order(from, to)
	lo, hi = pos_clamp(b, lo), pos_clamp(b, hi)
	if pos_eq(lo, hi) && len(text) == 0 {
		return cur_before
	}

	removed := raw_delete(b, lo, hi)
	end := raw_insert(b, lo, text)
	buf_invalidate(b, lo.line)

	// Dropping the redo branch: a new edit after an undo is a new history.
	for e in b.redo {
		delete(e.removed)
		delete(e.added)
	}
	clear(&b.redo)

	if coalesce != .No && len(b.undo) > 0 {
		top := &b.undo[len(b.undo) - 1]
		if top.kind == coalesce {
			switch coalesce {
			case .Type:
				// Extend a run of typing: same insert point, nothing removed,
				// and the new text lands exactly where the last one ended.
				if len(top.removed) == 0 &&
				   len(removed) == 0 &&
				   strings.index_byte(text, '\n') < 0 &&
				   pos_eq(lo, pos_advance(top.at, top.added)) {
					joined := strings.concatenate({top.added, text})
					delete(top.added)
					top.added = joined
					top.cur_after = end
					delete(removed)
					return end
				}
			case .Back:
				// Extend a run of backspaces: each one removes the bytes
				// immediately before the previous removal.
				if len(top.added) == 0 && len(text) == 0 && pos_eq(hi, top.at) {
					joined := strings.concatenate({removed, top.removed})
					delete(top.removed)
					top.removed = joined
					top.at = lo
					top.cur_after = lo
					delete(removed)
					return lo
				}
			case .No:
			}
		}
	}

	if b.save_mark > len(b.undo) {
		b.save_mark = -1
	}
	append(
		&b.undo,
		Edit {
			at = lo,
			removed = removed,
			added = strings.clone(text),
			cur_before = cur_before,
			cur_after = end,
			kind = coalesce,
		},
	)
	return end
}

buf_undo :: proc(b: ^Buffer) -> (cursor: Pos, ok: bool) {
	if len(b.undo) == 0 {
		return {}, false
	}
	e := pop(&b.undo)
	end := pos_advance(e.at, e.added)
	raw_delete(b, e.at, end)
	raw_insert(b, e.at, e.removed)
	buf_invalidate(b, e.at.line)
	append(&b.redo, e)
	return pos_clamp(b, e.cur_before), true
}

buf_redo :: proc(b: ^Buffer) -> (cursor: Pos, ok: bool) {
	if len(b.redo) == 0 {
		return {}, false
	}
	e := pop(&b.redo)
	end := pos_advance(e.at, e.removed)
	raw_delete(b, e.at, end)
	raw_insert(b, e.at, e.added)
	buf_invalidate(b, e.at.line)
	append(&b.undo, e)
	return pos_clamp(b, e.cur_after), true
}

buf_dirty :: proc(b: ^Buffer) -> bool {
	return b.save_mark != len(b.undo)
}

// ---------------------------------------------------------------------------
// Loading and saving
// ---------------------------------------------------------------------------

buf_init_empty :: proc(b: ^Buffer) {
	b.lines = make([dynamic]Line, 0, 64)
	append(&b.lines, Line{})
	b.undo = make([dynamic]Edit)
	b.redo = make([dynamic]Edit)
	b.encoding = "UTF-8"
	b.eol = .LF
	b.final_nl = true
	b.save_mark = 0
}

buf_load :: proc(b: ^Buffer, path: string) -> (ok: bool) {
	buf_init_empty(b)
	b.path = strings.clone(path)

	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		b.open_ok = false
		return false
	}
	defer delete(data)
	b.open_ok = true

	text := string(data)
	b.encoding = utf8.valid_string(text) ? "UTF-8" : "Binary"
	b.eol = strings.contains(text, "\r\n") ? .CRLF : .LF
	b.final_nl = len(text) > 0 && text[len(text) - 1] == '\n'

	// One pass, splitting on '\n' by hand so that the whole file is never
	// duplicated into a slice of slices plus a second copy per line.
	clear(&b.lines)
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			seg := text[start:i]
			if len(seg) > 0 && seg[len(seg) - 1] == '\r' {
				seg = seg[:len(seg) - 1]
			}
			l := Line {
				b = make([dynamic]u8, 0, len(seg)),
			}
			append(&l.b, ..transmute([]u8)seg)
			append(&b.lines, l)
			start = i + 1
			if i == len(text) {
				break
			}
		}
	}
	// A trailing newline produced one empty line past the end; that is the
	// line the caret sits on in every editor, so it is kept — except when the
	// file is empty, where one line is the floor.
	if len(b.lines) == 0 {
		append(&b.lines, Line{})
	}
	b.save_mark = 0
	return true
}

buf_save :: proc(b: ^Buffer, path: string) -> (ok: bool) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
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
	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(sb)); werr != nil {
		return false
	}
	if b.path != path {
		delete(b.path)
		b.path = strings.clone(path)
	}
	b.save_mark = len(b.undo)
	// A fresh undo entry after saving, so coalescing cannot retroactively
	// change the edit the save mark points at.
	if len(b.undo) > 0 {
		b.undo[len(b.undo) - 1].kind = .No
	}
	return true
}

buf_byte_size :: proc(b: ^Buffer) -> int {
	n := 0
	for i in 0 ..< len(b.lines) {
		n += len(b.lines[i].b) + 1
	}
	return max(0, n - (b.final_nl ? 0 : 1))
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

Char_Class :: enum {
	Space,
	Word,
	Punct,
}

class_of :: proc(c: u8) -> Char_Class {
	switch {
	case c == ' ' || c == '\t' || c == '\r':
		return .Space
	case c == '_' || c >= 0x80 || (c >= '0' && c <= '9') || (c | 32 >= 'a' && c | 32 <= 'z'):
		return .Word
	}
	return .Punct
}

rune_left :: proc(s: string, at: int) -> int {
	i := at - 1
	for i > 0 && s[i] & 0xc0 == 0x80 {
		i -= 1
	}
	return max(0, i)
}

rune_right :: proc(s: string, at: int) -> int {
	i := at + 1
	for i < len(s) && s[i] & 0xc0 == 0x80 {
		i += 1
	}
	return min(i, len(s))
}

// word_left stops at the start of the word before the caret, the way Ctrl-Left
// does in a browser: skip whitespace, then take the whole run of one class.
word_left :: proc(b: ^Buffer, p: Pos) -> Pos {
	cur := p
	if cur.col == 0 {
		if cur.line == 0 {
			return cur
		}
		return {cur.line - 1, len(buf_line(b, cur.line - 1))}
	}
	l := buf_line(b, cur.line)
	i := cur.col
	for i > 0 && class_of(l[i - 1]) == .Space {
		i -= 1
	}
	if i > 0 {
		k := class_of(l[i - 1])
		for i > 0 && class_of(l[i - 1]) == k {
			i -= 1
		}
	}
	return {cur.line, i}
}

word_right :: proc(b: ^Buffer, p: Pos) -> Pos {
	l := buf_line(b, p.line)
	if p.col >= len(l) {
		if p.line + 1 >= len(b.lines) {
			return p
		}
		return {p.line + 1, 0}
	}
	i := p.col
	k := class_of(l[i])
	if k != .Space {
		for i < len(l) && class_of(l[i]) == k {
			i += 1
		}
	}
	for i < len(l) && class_of(l[i]) == .Space {
		i += 1
	}
	return {p.line, i}
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

fold :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

line_find :: proc(hay: string, needle: string, from: int, ci: bool) -> int {
	if len(needle) == 0 || len(needle) > len(hay) {
		return -1
	}
	if !ci {
		at := strings.index(hay[min(from, len(hay)):], needle)
		return at < 0 ? -1 : at + min(from, len(hay))
	}
	for i := min(from, len(hay)); i + len(needle) <= len(hay); i += 1 {
		match := true
		for j in 0 ..< len(needle) {
			if fold(hay[i + j]) != fold(needle[j]) {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

line_rfind :: proc(hay: string, needle: string, before: int, ci: bool) -> int {
	if len(needle) == 0 {
		return -1
	}
	best := -1
	i := 0
	for {
		at := line_find(hay, needle, i, ci)
		if at < 0 || at >= before {
			break
		}
		best = at
		i = at + 1
	}
	return best
}

// buf_search walks forward (or backward) from a position, wrapping once.
buf_search :: proc(
	b: ^Buffer,
	needle: string,
	from: Pos,
	ci: bool,
	backwards := false,
) -> (
	at: Pos,
	ok: bool,
) {
	if len(needle) == 0 || len(b.lines) == 0 {
		return {}, false
	}
	n := len(b.lines)
	if !backwards {
		for k in 0 ..= n {
			li := (from.line + k) % n
			start := k == 0 ? from.col : 0
			if c := line_find(buf_line(b, li), needle, start, ci); c >= 0 {
				if k == n && c >= from.col {
					break
				}
				return {li, c}, true
			}
		}
		return {}, false
	}
	for k in 0 ..= n {
		li := ((from.line - k) % n + n) % n
		limit := k == 0 ? from.col : len(buf_line(b, li))
		if c := line_rfind(buf_line(b, li), needle, limit, ci); c >= 0 {
			return {li, c}, true
		}
	}
	return {}, false
}

buf_count :: proc(b: ^Buffer, needle: string, ci: bool) -> int {
	if len(needle) == 0 {
		return 0
	}
	total := 0
	for i in 0 ..< len(b.lines) {
		l := buf_line(b, i)
		at := 0
		for {
			f := line_find(l, needle, at, ci)
			if f < 0 {
				break
			}
			total += 1
			at = f + len(needle)
		}
	}
	return total
}
