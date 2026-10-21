package vt

// ---------------------------------------------------------------------------
// The grid.
//
// A terminal is two screens: the primary one, which keeps everything that
// scrolls off the top, and the alternate one, which does not and which is what
// a full-screen program like an editor runs on. Switching between them is how
// vim can take over the window and then give it back with the shell's history
// intact.
//
// Rows in the scrollback are trimmed to the length they actually use. A
// terminal with ten thousand lines of history is mostly storing short lines,
// and paying for eighty columns of blank cells on every one of them is the
// difference between a few megabytes and fifty.
// ---------------------------------------------------------------------------

// Color is packed into a word. The top byte says what the rest means, which
// keeps a cell small -- and a cell is the thing there are two million of.
Color :: distinct u32

COLOR_DEFAULT :: Color(0)

color_palette :: proc "contextless" (i: u8) -> Color {
	return Color(0x0100_0000 | u32(i))
}

color_rgb :: proc "contextless" (c: Rgb) -> Color {
	return Color(0x0200_0000 | u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2]))
}

color_is_default :: proc "contextless" (c: Color) -> bool {
	return u32(c) >> 24 == 0
}

color_is_palette :: proc "contextless" (c: Color) -> bool {
	return u32(c) >> 24 == 1
}

color_index :: proc "contextless" (c: Color) -> u8 {
	return u8(u32(c) & 0xFF)
}

color_value :: proc "contextless" (c: Color) -> Rgb {
	v := u32(c)
	return {u8(v >> 16), u8(v >> 8), u8(v)}
}

Attr :: enum u8 {
	Bold,
	Faint,
	Italic,
	Blink,
	Inverse,
	Invisible,
	Strike,
	Overline,
	// Underline needs three bits of style, kept beside the flags.
	Wide,      // this cell is the left half of a two-cell character
	Spacer,    // this cell is the right half, and holds no character
	Wrap,      // set on the last cell of a row that soft-wrapped
	Protected, // DECSCA, spared by selective erase
}

Attrs :: bit_set[Attr;u16]

Cell :: struct {
	ch:    rune,
	fg:    Color,
	bg:    Color,
	ul:    Color,
	attrs: Attrs,
	under: Underline_Style,
	// Index into Screen.graphemes of the combining marks that follow this
	// cell's base character, or 0 for the overwhelmingly common case of none.
	extra: u32,
	// Index into Screen.links of the hyperlink this cell belongs to, 0 for
	// none. OSC 8 is rare enough that the indirection costs nothing.
	link:  u32,
}

// Pen is the drawing state: what the next printed character will look like.
Pen :: struct {
	fg:    Color,
	bg:    Color,
	ul:    Color,
	attrs: Attrs,
	under: Underline_Style,
	link:  u32,
}

Row :: struct {
	cells:   []Cell,
	// True when this row ran off the right edge into the next one. Reflow
	// uses it to put the line back together, and a selection uses it to copy
	// one logical line rather than two.
	wrapped: bool,
	dirty:   bool,
	// The images on this row, if any: see graphics.odin. Nil for almost
	// every row, so a row of text pays one empty slice for the feature.
	frags:   []Frag,
}

Screen :: struct {
	cols:       int,
	rows:       int,
	lines:      [dynamic]Row,
	scrollback: [dynamic]Row,
	sb_limit:   int,
	// Combining marks, appended to and never compacted within a session.
	// Index 0 is reserved for "none".
	graphemes:  [dynamic][dynamic]rune,
	links:      [dynamic]string,
	pen:        Pen,
}

screen_init :: proc(s: ^Screen, cols, rows, sb_limit: int) {
	s.cols = max(cols, 1)
	s.rows = max(rows, 1)
	s.sb_limit = sb_limit
	s.lines = make([dynamic]Row, 0, s.rows)
	s.scrollback = make([dynamic]Row)
	s.graphemes = make([dynamic][dynamic]rune)
	append(&s.graphemes, [dynamic]rune{})
	s.links = make([dynamic]string)
	append(&s.links, "")
	for _ in 0 ..< s.rows {
		append(&s.lines, make_row(s.cols, s.pen))
	}
}

screen_destroy :: proc(s: ^Screen) {
	for &r in s.lines {
		row_free(&r)
	}
	for &r in s.scrollback {
		row_free(&r)
	}
	delete(s.lines)
	delete(s.scrollback)
	for &g in s.graphemes {
		delete(g)
	}
	delete(s.graphemes)
	delete(s.links)
}

blank_cell :: proc "contextless" (pen: Pen) -> Cell {
	// A blank keeps the background colour but nothing else. That is what
	// makes `clear` on a themed shell paint the whole window rather than
	// leaving a ragged edge where the text stopped.
	return Cell{ch = ' ', fg = pen.fg, bg = pen.bg}
}

make_row :: proc(cols: int, pen: Pen) -> Row {
	cells := make([]Cell, cols)
	b := blank_cell(pen)
	for i in 0 ..< cols {
		cells[i] = b
	}
	return Row{cells = cells, dirty = true}
}

// row_free releases everything a row owns: its cells and its images.
row_free :: proc(r: ^Row) {
	row_release(r)
	delete(r.cells)
	r.cells = nil
}

row_clear :: proc(r: ^Row, pen: Pen) {
	row_release(r)
	b := blank_cell(pen)
	for i in 0 ..< len(r.cells) {
		r.cells[i] = b
	}
	r.wrapped = false
	r.dirty = true
}

// row_used reports how many cells are worth keeping: everything up to the
// last one that is not a default blank.
row_used :: proc(r: Row) -> int {
	n := len(r.cells)
	for n > 0 {
		c := r.cells[n - 1]
		if c.ch != ' ' && c.ch != 0 {
			break
		}
		if !color_is_default(c.bg) || c.attrs != {} {
			break
		}
		n -= 1
	}
	return n
}

// screen_push_scrollback moves the top line of the active area into history.
@(private = "file")
push_scrollback :: proc(s: ^Screen, r: Row) {
	if s.sb_limit <= 0 {
		r := r
		row_free(&r)
		return
	}
	used := row_used(r)
	trimmed := make([]Cell, used)
	copy(trimmed, r.cells[:used])
	delete(r.cells)
	append(&s.scrollback, Row{cells = trimmed, wrapped = r.wrapped, frags = r.frags})
	if len(s.scrollback) > s.sb_limit {
		// Dropping from the front of a dynamic array is O(n), so drop a
		// block at a time: an eighth of the limit, amortised to nothing.
		drop := max(1, s.sb_limit / 8)
		drop = min(drop, len(s.scrollback))
		for i in 0 ..< drop {
			// This is where an image scrolled out of the history is let go.
			row_free(&s.scrollback[i])
		}
		copy(s.scrollback[:], s.scrollback[drop:])
		resize(&s.scrollback, len(s.scrollback) - drop)
	}
}

// scroll_up moves the contents of a region up by n lines, which is what
// happens when the cursor walks off the bottom. Lines leaving the top of a
// full-screen region go to the scrollback; lines leaving a smaller region are
// simply gone, which is what DECSTBM means.
screen_scroll_up :: proc(s: ^Screen, top, bot, n: int, pen: Pen, history: bool) {
	if n <= 0 || top > bot {
		return
	}
	count := min(n, bot - top + 1)
	for i in 0 ..< count {
		r := s.lines[top + i]
		if history && top == 0 {
			push_scrollback(s, r)
		} else {
			row_free(&r)
		}
	}
	// Shift the survivors up and fill the hole at the bottom.
	for i := top; i + count <= bot; i += 1 {
		s.lines[i] = s.lines[i + count]
		s.lines[i].dirty = true
	}
	for i := bot - count + 1; i <= bot; i += 1 {
		s.lines[i] = make_row(s.cols, pen)
	}
}

screen_scroll_down :: proc(s: ^Screen, top, bot, n: int, pen: Pen) {
	if n <= 0 || top > bot {
		return
	}
	count := min(n, bot - top + 1)
	for i in 0 ..< count {
		row_free(&s.lines[bot - i])
	}
	for i := bot; i - count >= top; i -= 1 {
		s.lines[i] = s.lines[i - count]
		s.lines[i].dirty = true
	}
	for i := top; i < top + count; i += 1 {
		s.lines[i] = make_row(s.cols, pen)
	}
}

// screen_grapheme_append attaches a combining mark to a cell, allocating a
// slot in the side table the first time.
screen_grapheme_append :: proc(s: ^Screen, c: ^Cell, r: rune) {
	if c.extra == 0 {
		append(&s.graphemes, make([dynamic]rune))
		c.extra = u32(len(s.graphemes) - 1)
	}
	g := &s.graphemes[c.extra]
	if len(g) < 8 {
		append(g, r)
	}
}

screen_grapheme :: proc(s: ^Screen, c: Cell) -> []rune {
	if c.extra == 0 || int(c.extra) >= len(s.graphemes) {
		return nil
	}
	return s.graphemes[c.extra][:]
}

screen_mark_all_dirty :: proc(s: ^Screen) {
	for &r in s.lines {
		r.dirty = true
	}
}

// screen_total_rows is the scrollback plus the active area, which is what a
// scrollbar measures against.
screen_total_rows :: proc(s: ^Screen) -> int {
	return len(s.scrollback) + len(s.lines)
}

// screen_row returns row `i` counted from the top of the scrollback.
screen_row :: proc(s: ^Screen, i: int) -> ^Row {
	if i < len(s.scrollback) {
		return &s.scrollback[i]
	}
	j := i - len(s.scrollback)
	if j < 0 || j >= len(s.lines) {
		return nil
	}
	return &s.lines[j]
}
