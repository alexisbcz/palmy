package vt

// ---------------------------------------------------------------------------
// Resize, with reflow.
//
// This is the hardest thing in a terminal and the thing that separates one you
// can live in from one you cannot. When the window narrows, the text that was
// already on the screen has to be re-wrapped: a paragraph that was three lines
// at a hundred columns is five lines at sixty, and a terminal that instead
// truncates it has silently destroyed the output of the command you ran twenty
// minutes ago.
//
// Doing it correctly needs two things the grid already carries. Row.wrapped
// says whether a row ran off the right edge into the next one -- without it
// there is no way to tell a soft wrap from a line the program ended itself,
// and re-joining the wrong ones mangles anything with deliberate short lines.
// And the cell widths say where a wide character may not be split.
//
// The alternate screen is deliberately *not* reflowed. A full-screen program
// redraws it from scratch after SIGWINCH, and re-wrapping what is on it in the
// meantime produces a mess that then gets overwritten anyway.
// ---------------------------------------------------------------------------

// Logical_Pos is a position expressed against the unwrapped text, which is the
// only thing that stays meaningful across a resize.
@(private = "file")
Logical_Pos :: struct {
	line:  int, // index of the logical line
	off:   int, // cell offset within it
	found: bool,
}

terminal_resize :: proc(t: ^Terminal, cols_in, rows_in: int) {
	cols := max(cols_in, 1)
	rows := max(rows_in, 1)
	if cols == t.cols && rows == t.rows {
		return
	}

	reflow_primary(t, cols, rows)
	resize_plain(&t.alt, cols, rows, t.cursor.pen)

	t.cols = cols
	t.rows = rows
	resize(&t.tabs, cols)
	for i in 0 ..< cols {
		t.tabs[i] = i > 0 && i % 8 == 0
	}

	// A scroll region that no longer fits goes back to the whole screen,
	// which is what the program will set up again anyway.
	if t.bot >= rows || t.top >= t.bot {
		t.top = 0
		t.bot = rows - 1
	}
	t.cursor.x = clamp(t.cursor.x, 0, cols - 1)
	t.cursor.y = clamp(t.cursor.y, 0, rows - 1)
	t.cursor.pending = false
	t.view_offset = min(t.view_offset, max(0, screen_total_rows(&t.primary) - rows))
	screen_mark_all_dirty(&t.primary)
	screen_mark_all_dirty(&t.alt)
	t.damaged = true
}

// resize_plain is the alternate screen's resize: clip or pad, no re-wrapping.
@(private = "file")
resize_plain :: proc(s: ^Screen, cols, rows: int, pen: Pen) {
	for &r in s.lines {
		if len(r.cells) == cols {
			continue
		}
		cells := make([]Cell, cols)
		b := blank_cell(pen)
		for i in 0 ..< cols {
			cells[i] = i < len(r.cells) ? r.cells[i] : b
		}
		delete(r.cells)
		r.cells = cells
		r.dirty = true
	}
	for len(s.lines) > rows {
		delete(s.lines[len(s.lines) - 1].cells)
		pop(&s.lines)
	}
	for len(s.lines) < rows {
		append(&s.lines, make_row(cols, pen))
	}
	s.cols = cols
	s.rows = rows
}

@(private = "file")
reflow_primary :: proc(t: ^Terminal, cols, rows: int) {
	s := &t.primary

	// 1. Flatten everything into logical lines.
	Logical :: struct {
		cells:      [dynamic]Cell,
		// True when the original text really did end here, as opposed to
		// having been cut off by the right edge.
		hard_break: bool,
	}
	lines := make([dynamic]Logical, 0, screen_total_rows(s))
	defer {
		for &l in lines {
			delete(l.cells)
		}
		delete(lines)
	}

	cursor_pos := Logical_Pos{}
	cursor_abs := len(s.scrollback) + t.cursor.y

	flush := proc(lines: ^[dynamic]Logical) -> ^Logical {
		if len(lines) == 0 || lines[len(lines) - 1].hard_break {
			append(lines, Logical{cells = make([dynamic]Cell), hard_break = true})
		}
		return &lines[len(lines) - 1]
	}

	total := screen_total_rows(s)
	for i in 0 ..< total {
		r := screen_row(s, i)
		if r == nil {
			continue
		}
		// A row that is part of the active area keeps its full width so that
		// trailing spaces a program painted deliberately survive; a
		// scrollback row was already trimmed when it was pushed.
		n := len(r.cells)
		if i >= len(s.scrollback) {
			n = r.wrapped ? len(r.cells) : row_used(r^)
		}

		cur := flush(&lines)
		if i == cursor_abs {
			cursor_pos = {line = len(lines) - 1, off = len(cur.cells) + t.cursor.x, found = true}
		}
		for j in 0 ..< n {
			append(&cur.cells, r.cells[j])
		}
		cur.hard_break = !r.wrapped
	}
	if !cursor_pos.found {
		cursor_pos = {line = max(0, len(lines) - 1), off = t.cursor.x, found = true}
	}

	// 2. Re-wrap into rows of the new width.
	out := make([dynamic]Row)
	new_cursor_row := 0
	new_cursor_col := 0
	pen := t.cursor.pen

	for l, li in lines {
		start := 0
		first := true
		for first || start < len(l.cells) {
			first = false
			end := min(start + cols, len(l.cells))
			// Never split a two-cell character across the boundary.
			if end < len(l.cells) && end > start {
				if .Spacer in l.cells[end].attrs {
					end -= 1
				}
			}
			cells := make([]Cell, cols)
			b := blank_cell(pen)
			k := 0
			for j in start ..< end {
				cells[k] = l.cells[j]
				k += 1
			}
			for ; k < cols; k += 1 {
				cells[k] = b
			}
			soft := end < len(l.cells)
			if li == cursor_pos.line && cursor_pos.off >= start &&
			   (cursor_pos.off < end || !soft) {
				new_cursor_row = len(out)
				new_cursor_col = min(cursor_pos.off - start, cols - 1)
			}
			append(&out, Row{cells = cells, wrapped = soft, dirty = true})
			start = end
			if !soft {
				break
			}
		}
	}

	// 3. Split the result back into scrollback and active area, keeping the
	//    cursor's row on screen.
	for &r in s.lines {
		delete(r.cells)
	}
	clear(&s.lines)
	for &r in s.scrollback {
		delete(r.cells)
	}
	clear(&s.scrollback)

	// Trailing blank rows below the cursor are dropped rather than kept.
	// Without this, shrinking a window pushes the text that is on screen up
	// into the scrollback to make room for the empty rows underneath it, and
	// the window goes blank -- which is exactly the thing reflow exists to
	// prevent.
	last := len(out)
	for last > rows && last > new_cursor_row + 1 && row_used(out[last - 1]) == 0 {
		delete(out[last - 1].cells)
		last -= 1
	}
	resize(&out, last)

	// The active area is the last `rows` rows, extended if the cursor would
	// otherwise fall above it.
	first_active := max(0, len(out) - rows)
	if new_cursor_row < first_active {
		first_active = new_cursor_row
	}
	if first_active + rows > len(out) {
		// Pad with blanks so the active area is always exactly `rows` tall.
		for len(out) < first_active + rows {
			append(&out, make_row(cols, pen))
		}
	}

	for i in 0 ..< first_active {
		r := out[i]
		used := row_used(r)
		trimmed := make([]Cell, used)
		copy(trimmed, r.cells[:used])
		delete(r.cells)
		append(&s.scrollback, Row{cells = trimmed, wrapped = r.wrapped})
	}
	for i in first_active ..< first_active + rows {
		append(&s.lines, out[i])
	}
	delete(out)

	// Trim the scrollback back to its limit.
	if s.sb_limit > 0 && len(s.scrollback) > s.sb_limit {
		drop := len(s.scrollback) - s.sb_limit
		for i in 0 ..< drop {
			delete(s.scrollback[i].cells)
		}
		copy(s.scrollback[:], s.scrollback[drop:])
		resize(&s.scrollback, s.sb_limit)
	}

	s.cols = cols
	s.rows = rows
	t.cursor.y = clamp(new_cursor_row - first_active, 0, rows - 1)
	t.cursor.x = clamp(new_cursor_col, 0, cols - 1)
}
