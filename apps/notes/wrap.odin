// The editor's layout: live Markdown formatting, soft wrap, and the caret's
// two coordinate systems.
//
// What you type is Markdown and stays Markdown — the file on disk is exactly
// the characters in the buffer — but it is *drawn* formatted while you write:
// a heading is large, **bold** is bold, *emphasis* is italic, `code` is mono
// on a tint, [[links]] and #tags are coloured, and a task's `[ ]` is a box you
// can click. The marks themselves stay on screen, faint, so the caret always
// has a character to sit beside and nothing jumps when it moves (Bear's choice
// rather than Obsidian's hide-and-reflow). The few marks that are replaced by
// a drawing — a bullet's dash, a task's brackets, a quote's chevron, a rule —
// keep their exact width, and show as text again on the caret's line.
//
// Because every character is still there at its own width, the caret maths
// stays what it was: a position is (line, byte), and x is the styled width of
// the row up to it. Each line has a kind (heading, task, code …) that sets its
// size and row height, and a list of segments that set each span's face. The
// whole note is styled and wrapped at once — notes are a few kilobytes — and
// the result is cached until the text or the width changes.
package main

import "core:strings"
import p "palmy:."

BODY_SIZE :: 15.0
BODY_LH :: 25
CODE_SIZE :: 13.5

Line_Kind :: enum u8 {
	Para,
	H1,
	H2,
	H3,
	Quote,
	Bullet,
	Number,
	Task,
	Done,
	Fence,
	Code,
	Rule,
	Blank,
}

Seg_Kind :: enum u8 {
	Text,
	Mark, // Markdown syntax, drawn faint
	Bold,
	Em,
	Bold_Em,
	Code,
	Strike,
	Link, // [text](url) text, or a bare URL
	Wiki, // [[a note of this identity]]
	Wiki_Out, // [[other-identity:…]] — a deliberate link out
	Tag,
	Box, // a task's [ ] or [x]
	Dash, // a bullet's - or *
	Chevron, // a quote's >
}

Seg :: struct {
	from, to: int,
	kind:     Seg_Kind,
}

Line_Style :: struct {
	kind:   Line_Kind,
	seg_lo: int, // into Wrapper.segs
	seg_hi: int,
}

Vis :: struct {
	line: int, // index into the buffer
	from: int, // byte range of this visual row within that line
	to:   int,
	last: bool, // the final visual row of its logical line
	h:    f32, // its height
}

Wrapper :: struct {
	rows:   [dynamic]Vis,
	styles: [dynamic]Line_Style,
	segs:   [dynamic]Seg,
	width:  f32,
	rev:    int,
	own:    string, // this identity's handle: [[own:…]] is an ordinary link
}

// text_w measures plain body text, the face of an unformatted paragraph.
text_w :: proc(ui: ^p.Ctx, s: string) -> f32 {
	return p.text_width(ui.fonts, s, BODY_SIZE, .Sans, .Regular)
}

line_size :: proc(k: Line_Kind) -> f32 {
	#partial switch k {
	case .H1:
		return 26
	case .H2:
		return 20.5
	case .H3:
		return 17
	case .Code, .Fence:
		return CODE_SIZE
	}
	return BODY_SIZE
}

line_height :: proc(k: Line_Kind) -> f32 {
	#partial switch k {
	case .H1:
		return 42
	case .H2:
		return 34
	case .H3:
		return 29
	case .Code, .Fence:
		return 21
	case .Blank:
		return 14
	}
	return BODY_LH
}

Face :: struct {
	size: f32,
	fam:  p.Font_Family,
	wt:   p.Font_Weight,
	sl:   p.Font_Slant,
}

face_of :: proc(lk: Line_Kind, sk: Seg_Kind) -> Face {
	f := Face{size = line_size(lk)}
	#partial switch lk {
	case .H1, .H2:
		f.wt = .Semibold
	case .H3:
		f.wt = .Semibold
	case .Code, .Fence:
		f.fam = .Mono
	}
	#partial switch sk {
	case .Bold:
		f.wt = .Bold if f.wt == .Semibold else .Semibold
	case .Em:
		f.sl = .Italic
	case .Bold_Em:
		f.wt = .Semibold
		f.sl = .Italic
	case .Code:
		f.fam = .Mono
		f.size = f.size - 1.5
	case .Mark, .Dash, .Chevron, .Box:
		if f.wt == .Semibold {
			f.wt = .Regular
		}
	}
	return f
}

seg_w :: proc(ui: ^p.Ctx, s: string, lk: Line_Kind, sk: Seg_Kind) -> f32 {
	if s == "" {
		return 0
	}
	f := face_of(lk, sk)
	return p.text_width(ui.fonts, s, f.size, f.fam, f.wt, 0, f.sl)
}

// styled_w is the drawn width of bytes [from, to) of a line.
styled_w :: proc(ui: ^p.Ctx, w: ^Wrapper, src: string, li: int, from, to: int) -> f32 {
	if li >= len(w.styles) {
		return text_w(ui, src[from:to])
	}
	st := w.styles[li]
	x: f32 = 0
	for si in st.seg_lo ..< st.seg_hi {
		sg := w.segs[si]
		a := max(sg.from, from)
		b := min(sg.to, to)
		if b > a {
			x += seg_w(ui, src[a:b], st.kind, sg.kind)
		}
	}
	return x
}

// ---------------------------------------------------------------------------
// Styling: line kinds and inline segments
// ---------------------------------------------------------------------------

indent_of :: proc(s: string) -> int {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	return i
}

// style_lines classifies every line and cuts it into segments.
style_lines :: proc(w: ^Wrapper, b: ^Buffer) {
	clear(&w.styles)
	clear(&w.segs)
	in_code := false
	for li in 0 ..< buf_lines(b) {
		src := buf_line(b, li)
		lo := len(w.segs)
		t := src[indent_of(src):]
		kind := Line_Kind.Para
		switch {
		case strings.has_prefix(t, "```"):
			kind = .Fence
			in_code = !in_code
			append(&w.segs, Seg{0, len(src), .Mark})
		case in_code:
			kind = .Code
			append(&w.segs, Seg{0, len(src), .Text})
		case strings.trim_space(src) == "":
			kind = .Blank
			append(&w.segs, Seg{0, len(src), .Text})
		case t == "---" || t == "***" || t == "___":
			kind = .Rule
			append(&w.segs, Seg{0, len(src), .Mark})
		case:
			kind = inline_line(w, src)
		}
		append(&w.styles, Line_Style{kind, lo, len(w.segs)})
	}
}

// inline_line handles a line that is not code: its block prefix, then its
// inline spans. Returns the line's kind.
@(private = "file")
inline_line :: proc(w: ^Wrapper, src: string) -> Line_Kind {
	ind := indent_of(src)
	t := src[ind:]
	kind := Line_Kind.Para
	start := 0
	push :: proc(w: ^Wrapper, from, to: int, k: Seg_Kind) {
		if to > from {
			append(&w.segs, Seg{from, to, k})
		}
	}
	switch {
	case strings.has_prefix(t, "### "):
		kind = .H3
		start = ind + 4
	case strings.has_prefix(t, "## "):
		kind = .H2
		start = ind + 3
	case strings.has_prefix(t, "# "):
		kind = .H1
		start = ind + 2
	case strings.has_prefix(t, "> "):
		kind = .Quote
		push(w, 0, ind, .Text)
		push(w, ind, ind + 1, .Chevron)
		push(w, ind + 1, ind + 2, .Text)
		start = ind + 2
		inline_spans(w, src, start)
		return kind
	case len(t) >= 6 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' ' && t[2] == '[' &&
	     (t[3] == ' ' || t[3] == 'x' || t[3] == 'X') && t[4] == ']' && (len(t) == 5 || t[5] == ' '):
		kind = t[3] == ' ' ? .Task : .Done
		push(w, 0, ind, .Text)
		push(w, ind, ind + 1, .Dash)
		push(w, ind + 1, ind + 2, .Text)
		push(w, ind + 2, ind + 5, .Box)
		start = min(len(src), ind + 5)
		inline_spans(w, src, start)
		return kind
	case len(t) >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' ':
		kind = .Bullet
		push(w, 0, ind, .Text)
		push(w, ind, ind + 1, .Dash)
		start = ind + 1
		inline_spans(w, src, start)
		return kind
	case is_ordered(t):
		kind = .Number
		dot := strings.index_byte(t, '.')
		push(w, 0, ind + dot + 1, .Mark)
		start = ind + dot + 1
		inline_spans(w, src, start)
		return kind
	}
	push(w, 0, start, .Mark)
	inline_spans(w, src, start)
	return kind
}

// inline_spans cuts [start:] of a line into styled runs.
@(private = "file")
inline_spans :: proc(w: ^Wrapper, src: string, start: int) {
	bold, em, strike := false, false, false
	run := start
	cur :: proc(bold, em, strike: bool) -> Seg_Kind {
		switch {
		case strike:
			return .Strike
		case bold && em:
			return .Bold_Em
		case bold:
			return .Bold
		case em:
			return .Em
		}
		return .Text
	}
	flush :: proc(w: ^Wrapper, from, to: int, k: Seg_Kind) {
		if to > from {
			append(&w.segs, Seg{from, to, k})
		}
	}
	i := start
	for i < len(src) {
		c := src[i]
		switch {
		case c == '\\' && i + 1 < len(src):
			i += 2
			continue
		case c == '`':
			if end := strings.index_byte(src[i + 1:], '`'); end >= 0 {
				flush(w, run, i, cur(bold, em, strike))
				flush(w, i, i + 1, .Mark)
				flush(w, i + 1, i + 1 + end, .Code)
				flush(w, i + 1 + end, i + 2 + end, .Mark)
				i += end + 2
				run = i
				continue
			}
		case c == '[' && i + 1 < len(src) && src[i + 1] == '[':
			if end := strings.index(src[i + 2:], "]]"); end > 0 {
				inner := src[i + 2:i + 2 + end]
				l, ok := parse_link(inner)
				if ok {
					flush(w, run, i, cur(bold, em, strike))
					flush(w, i, i + 2, .Mark)
					out := l.handle != "" && l.handle != w.own
					flush(w, i + 2, i + 2 + end, out ? .Wiki_Out : .Wiki)
					flush(w, i + 2 + end, i + 4 + end, .Mark)
					i += end + 4
					run = i
					continue
				}
			}
		case c == '[':
			close := strings.index_byte(src[i:], ']')
			if close > 0 && i + close + 1 < len(src) && src[i + close + 1] == '(' {
				if tail := strings.index_byte(src[i + close:], ')'); tail > 0 {
					flush(w, run, i, cur(bold, em, strike))
					flush(w, i, i + 1, .Mark)
					flush(w, i + 1, i + close, .Link)
					flush(w, i + close, i + close + tail + 1, .Mark)
					i += close + tail + 1
					run = i
					continue
				}
			}
		case c == '~' && i + 1 < len(src) && src[i + 1] == '~':
			flush(w, run, i, cur(bold, em, strike))
			flush(w, i, i + 2, .Mark)
			strike = !strike
			i += 2
			run = i
			continue
		case c == '*' && i + 1 < len(src) && src[i + 1] == '*':
			flush(w, run, i, cur(bold, em, strike))
			flush(w, i, i + 2, .Mark)
			bold = !bold
			i += 2
			run = i
			continue
		case c == '*' || c == '_':
			if c == '_' && i > 0 && is_word_byte(src[i - 1]) && i + 1 < len(src) && is_word_byte(src[i + 1]) {
				break
			}
			// A lone * with spaces on both sides is a multiplication, not emphasis.
			if c == '*' && (i + 1 >= len(src) || src[i + 1] == ' ') && !em {
				break
			}
			flush(w, run, i, cur(bold, em, strike))
			flush(w, i, i + 1, .Mark)
			em = !em
			i += 1
			run = i
			continue
		case c == '#' && (i == 0 || src[i - 1] == ' ' || src[i - 1] == '(') && i + 1 < len(src) &&
		     ((src[i + 1] | 32 >= 'a' && src[i + 1] | 32 <= 'z') || src[i + 1] >= 0x80):
			j := i + 1
			for j < len(src) && (is_word_byte(src[j]) || src[j] == '-' || src[j] == '/' || src[j] >= 0x80) {
				j += 1
			}
			flush(w, run, i, cur(bold, em, strike))
			flush(w, i, j, .Tag)
			i = j
			run = i
			continue
		case c == 'h' && (strings.has_prefix(src[i:], "https://") || strings.has_prefix(src[i:], "http://")) &&
		     (i == 0 || src[i - 1] == ' ' || src[i - 1] == '('):
			j := i
			for j < len(src) && src[j] != ' ' && src[j] != ')' {
				j += 1
			}
			flush(w, run, i, cur(bold, em, strike))
			flush(w, i, j, .Link)
			i = j
			run = i
			continue
		}
		i += 1
	}
	flush(w, run, len(src), cur(bold, em, strike))
}

// ---------------------------------------------------------------------------
// Wrapping
// ---------------------------------------------------------------------------

// wrap_rebuild recomputes the styles and the visual rows if anything they
// depend on moved.
wrap_rebuild :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, width: f32, rev: int) {
	if w.width == width && w.rev == rev && len(w.rows) > 0 {
		return
	}
	w.width = width
	w.rev = rev
	clear(&w.rows)
	style_lines(w, b)

	avail := max(40, width)
	for li in 0 ..< buf_lines(b) {
		src := buf_line(b, li)
		h := line_height(w.styles[li].kind)
		if src == "" || styled_w(ui, w, src, li, 0, len(src)) <= avail {
			append(&w.rows, Vis{li, 0, len(src), true, h})
			continue
		}
		// A wrapped list item or quote continues at the text's indent in a
		// real editor; here every row starts at the margin, which keeps one x
		// origin per row and the caret maths simple.
		start := 0
		last_space := -1
		i := 0
		for i <= len(src) {
			at_end := i == len(src)
			if !at_end && src[i] != ' ' {
				i += 1
				continue
			}
			if styled_w(ui, w, src, li, start, i) > avail && last_space > start {
				append(&w.rows, Vis{li, start, last_space, false, h})
				start = last_space + 1
				last_space = -1
				i = start
				continue
			}
			if at_end {
				append(&w.rows, Vis{li, start, len(src), true, h})
				break
			}
			last_space = i
			i += 1
		}
	}
	if len(w.rows) == 0 {
		append(&w.rows, Vis{0, 0, 0, true, BODY_LH})
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

// row_x is the x offset of byte `col` inside visual row `r`.
row_x :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, r: Vis, col: int) -> f32 {
	src := buf_line(b, r.line)
	return styled_w(ui, w, src, r.line, r.from, clamp(col, r.from, r.to))
}

// caret_x is the caret's horizontal offset inside its visual row.
caret_x :: proc(w: ^Wrapper, ui: ^p.Ctx, b: ^Buffer, at: Pos) -> f32 {
	r := w.rows[row_of(w, at)]
	return row_x(w, ui, b, r, at.col)
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
		d := abs(styled_w(ui, w, src, r.line, r.from, c) - x)
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

// row_y is the top of visual row `i`, measured from row `top`.
row_y :: proc(w: ^Wrapper, top, i: int) -> f32 {
	y: f32 = 0
	if i >= top {
		for k in top ..< i {
			y += w.rows[k].h
		}
	} else {
		for k in i ..< top {
			y -= w.rows[k].h
		}
	}
	return y
}

// rows_fitting is how many rows from `top` fit in `height` pixels.
rows_fitting :: proc(w: ^Wrapper, top: int, height: f32) -> int {
	y: f32 = 0
	n := 0
	for k := top; k < len(w.rows); k += 1 {
		y += w.rows[k].h
		if y > height {
			break
		}
		n += 1
	}
	return max(1, n)
}

// row_at_y is the row under a y offset from the top of row `top`.
row_at_y :: proc(w: ^Wrapper, top: int, y: f32) -> int {
	acc: f32 = 0
	for k := top; k < len(w.rows); k += 1 {
		if y < acc + w.rows[k].h {
			return k
		}
		acc += w.rows[k].h
	}
	return max(0, len(w.rows) - 1)
}

// line_kind_at is the kind of buffer line `li` as last styled.
line_kind_at :: proc(w: ^Wrapper, li: int) -> Line_Kind {
	if li < 0 || li >= len(w.styles) {
		return .Para
	}
	return w.styles[li].kind
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

	for marker in ([?]string{"- [ ] ", "- [x] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "}) {
		if !strings.has_prefix(rest, marker) {
			continue
		}
		if upto < i + len(marker) {
			return indent, false
		}
		if strings.trim_space(rest[len(marker):]) == "" {
			return "", true
		}
		m := marker
		if strings.has_suffix(marker, "[x] ") {
			m = tfmt("%c [ ] ", marker[0])
		}
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
