// Soft wrap for the note editor.
//
// A code editor can get away with a horizontal scrollbar; prose cannot. So the
// note editor wraps, which means the caret has to live in two coordinate
// systems: the logical one the buffer uses (line, byte) and the visual one the
// screen uses (wrapped row, x in pixels). Everything that needs both goes
// through here.
//
// Notes are small — a few kilobytes — so the whole document is wrapped at once
// and the result cached until either the text or the width changes.
package main

import "core:strings"
import p "palmy:."

BODY_SIZE :: 14.0
BODY_LH :: 23

Vis :: struct {
	line: int, // index into the buffer
	from: int, // byte range of this visual row within that line
	to:   int,
	last: bool, // the final visual row of its logical line
}

Wrapper :: struct {
	rows:  [dynamic]Vis,
	width: f32,
	rev:   int,
}

text_w :: proc(ui: ^p.Ctx, s: string) -> f32 {
	return p.text_width(ui.fonts, s, BODY_SIZE, .Sans, .Regular)
}

// wrap_rebuild recomputes the visual rows if anything they depend on moved.
wrap_rebuild :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, width: f32, rev: int) {
	if w.width == width && w.rev == rev && len(w.rows) > 0 {
		return
	}
	w.width = width
	w.rev = rev
	clear(&w.rows)

	avail := max(40, width)
	for li in 0 ..< buf_lines(b) {
		src := buf_line(b, li)
		if src == "" || text_w(ui, src) <= avail {
			append(&w.rows, Vis{li, 0, len(src), true})
			continue
		}

		// Greedy word wrap, the same rule palmy's own text layout uses: break
		// at the last space that still fits, and let a single word that is
		// wider than the line overflow rather than be chopped.
		start := 0
		last_space := -1
		i := 0
		for i <= len(src) {
			at_end := i == len(src)
			if !at_end && src[i] != ' ' {
				i += 1
				continue
			}
			if text_w(ui, src[start:i]) > avail && last_space > start {
				append(&w.rows, Vis{li, start, last_space, false})
				start = last_space + 1
				last_space = -1
				i = start
				continue
			}
			if at_end {
				append(&w.rows, Vis{li, start, len(src), true})
				break
			}
			last_space = i
			i += 1
		}
	}
	if len(w.rows) == 0 {
		append(&w.rows, Vis{0, 0, 0, true})
	}
}

// row_of finds the visual row a caret sits on.
row_of :: proc(w: ^Wrapper, at: Pos) -> int {
	best := 0
	for r, i in w.rows {
		if r.line < at.line {
			best = i
			continue
		}
		if r.line > at.line {
			break
		}
		if at.col >= r.from {
			best = i
		}
		if at.col <= r.to && at.col >= r.from {
			// The caret at a soft break belongs to the row that starts there.
			if at.col == r.to && !r.last {
				continue
			}
			return i
		}
	}
	return best
}

// caret_x is the caret's horizontal offset inside its visual row.
caret_x :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, at: Pos) -> f32 {
	i := row_of(w, at)
	r := w.rows[i]
	src := buf_line(b, r.line)
	col := clamp(at.col, r.from, r.to)
	return text_w(ui, src[r.from:col])
}

// col_at is the byte offset in a visual row closest to an x offset: the
// inverse of caret_x, and what Up, Down and a click all need.
col_at :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, row: int, x: f32) -> Pos {
	i := clamp(row, 0, len(w.rows) - 1)
	r := w.rows[i]
	src := buf_line(b, r.line)
	best := r.from
	best_d := abs(x)
	c := r.from
	for c <= r.to {
		d := abs(text_w(ui, src[r.from:c]) - x)
		if d < best_d {
			best_d = d
			best = c
		}
		if c >= r.to {
			break
		}
		c = rune_right(src, c)
	}
	return {r.line, best}
}

// list_continue decides what pressing Return inside a list item does:
// `prefix` is what the new line starts with, and `clear_item` says the item
// was empty, which is how a list ends.
//
// The cursor position matters: Return pressed *before* the marker splits the
// line, it does not make a second bullet.
list_continue :: proc(src: string, upto: int) -> (prefix: string, clear_item: bool) {
	i := 0
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	indent := src[:min(i, max(0, upto))]
	rest := src[i:]

	for marker in ([?]string{"- [ ] ", "- [x] ", "- ", "* ", "> "}) {
		if !strings.has_prefix(rest, marker) {
			continue
		}
		if upto < i + len(marker) {
			return indent, false
		}
		if strings.trim_space(rest[len(marker):]) == "" {
			return "", true
		}
		m := marker == "- [x] " ? "- [ ] " : marker
		return tfmt("%s%s", src[:i], m), false
	}
	if is_ordered(rest) {
		dot := strings.index_byte(rest, '.')
		if upto < i + dot + 2 {
			return indent, false
		}
		if strings.trim_space(rest[dot + 1:]) == "" {
			return "", true
		}
		n := 0
		for k in 0 ..< dot {
			n = n * 10 + int(rest[k] - '0')
		}
		return tfmt("%s%d. ", src[:i], n + 1), false
	}
	return indent, false
}
