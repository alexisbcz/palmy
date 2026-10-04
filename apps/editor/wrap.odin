// Soft wrap.
//
// `apps/notes/wrap.odin` already solved this for prose, and the approach is
// taken from there rather than invented again: a logical line becomes a list of
// visual rows, the caret lives in two coordinate systems at once, and the pair
// of conversions between them is the whole difficulty.
//
// Two things are different here, and both make it *easier* than it was in
// notes:
//
//   - The text is monospace and the editor already thinks in **display cells**
//     (`disp_of` / `byte_of` in main.odin, which expand tabs and count a
//     multi-byte rune as one cell). So a visual row is a half-open range of
//     cells, and the conversion the caret needs is `disp_of` and `byte_of` —
//     which the self-test already asserts invert each other. `caret_x` is
//     `(cell − row.c0) · cw`, and `col_at` is `byte_of(src, row.c0 + dx)`.
//     Nothing has to measure a string.
//
//   - A code file is not a note. Notes wraps the whole document up front and
//     caches it; a 500,001-line file cannot be wrapped at all. So nothing is
//     wrapped except the lines being looked at: the viewport is a logical line
//     plus a sub-row within it, every visible row is produced by wrapping at
//     most `rows` lines, and the caret's own line is wrapped on demand. The
//     cost of a keystroke stays bounded by the height of the window.
//
// The rule for which row a caret belongs to is notes': a caret at a soft break
// belongs to the row that *starts* there. A hard break — a word longer than the
// window, which prose does not have and minified JSON always does — drops no
// character, so the caret at the break is at the start of the next row.
package main

// Vis is one visual row: a half-open range of display cells inside a logical
// line. `last` marks the final row of its line, which is the only row where
// the caret may sit at `c1`.
Vis :: struct {
	line: int,
	sub:  int, // which row of its line, so the caret can find its own
	c0:   int,
	c1:   int,
	last: bool,
}

// wrap_rows fills `out` with the visual rows of logical line `li`. There is
// always at least one, so an empty line still occupies a row.
wrap_rows :: proc(ed: ^Editor, li: int, out: ^[dynamic]Vis) {
	clear(out)
	src := buf_line(&ed.buf, li)
	total := disp_of(src, len(src))

	if !ed.wrap {
		append(out, Vis{li, 0, 0, total, true})
		return
	}
	cols := max(8, ed.cols)
	if total <= cols {
		append(out, Vis{li, 0, 0, total, true})
		return
	}

	// Greedy word wrap, the same rule notes and palmy's own text layout use:
	// break at the last whitespace that still fits. The difference is the
	// fallback — a single word wider than the window is broken rather than
	// left to overflow, because with no horizontal scroll the overflow would
	// simply be invisible, and a 4000-column minified line is a real file.
	start := 0 // display cell this row begins at
	ws_from := -1 // where the last whitespace run began…
	ws_to := -1 // …and ended, so the break can drop it
	col := 0
	i := 0
	for i < len(src) {
		c := src[i]
		w := c == '\t' ? TAB_W - col % TAB_W : 1

		if col + w > start + cols && col > start {
			if ws_from > start {
				append(out, Vis{li, len(out), start, ws_from, false})
				start = ws_to
			} else {
				append(out, Vis{li, len(out), start, col, false})
				start = col
			}
			ws_from, ws_to = -1, -1
			// Re-test the same character against the row that just began.
			continue
		}

		if c == ' ' || c == '\t' {
			ws_from, ws_to = col, col + w
		}
		col += w
		i = c == '\t' ? i + 1 : rune_right(src, i)
	}
	append(out, Vis{li, len(out), start, col, true})
}

// wrap_count is how many visual rows a logical line occupies.
wrap_count :: proc(ed: ^Editor, li: int) -> int {
	if !ed.wrap {
		return 1
	}
	wrap_rows(ed, li, &ed.scratch)
	return max(1, len(ed.scratch))
}

// ---------------------------------------------------------------------------
// The two conversions
// ---------------------------------------------------------------------------

// sub_of is which of a line's visual rows holds the caret at display cell
// `cell`. This is the direction `caret_x` needs.
sub_of :: proc(rows: []Vis, cell: int) -> int {
	for i in 0 ..< len(rows) {
		r := rows[i]
		if cell < r.c1 {
			return i
		}
		if cell == r.c1 {
			// At a break. A dropped space leaves a gap before the next row
			// begins, and the caret before it belongs to this row; a hard
			// break has no gap, so the caret goes to the start of the next.
			if r.last || (i + 1 < len(rows) && rows[i + 1].c0 > r.c1) {
				return i
			}
			continue
		}
		// Inside the whitespace that the break swallowed.
		if i + 1 < len(rows) && cell < rows[i + 1].c0 {
			return i
		}
	}
	return max(0, len(rows) - 1)
}

// caret_vis is the caret in visual coordinates: which row of its line, and how
// many cells into that row.
caret_vis :: proc(ed: ^Editor, at: Pos) -> (sub: int, dx: int) {
	rows := make([dynamic]Vis, 0, 8, context.temp_allocator)
	wrap_rows(ed, at.line, &rows)
	cell := disp_of(buf_line(&ed.buf, at.line), at.col)
	sub = sub_of(rows[:], cell)
	return sub, max(0, cell - rows[sub].c0)
}

// col_at is the inverse: the byte offset in logical line `li` whose caret sits
// `dx` cells into visual row `sub`. Up, Down and a click all go through here,
// and `caret_vis(col_at(sub, dx)) == (sub, dx)` for every position a caret can
// actually occupy — which is what `--selftest` asserts.
col_at :: proc(ed: ^Editor, li, sub, dx: int) -> Pos {
	rows := make([dynamic]Vis, 0, 8, context.temp_allocator)
	wrap_rows(ed, li, &rows)
	r := rows[clamp(sub, 0, len(rows) - 1)]
	src := buf_line(&ed.buf, li)
	cell := clamp(r.c0 + max(0, dx), r.c0, r.c1)
	return pos_clamp(&ed.buf, {li, byte_of(src, cell)})
}

// ---------------------------------------------------------------------------
// Walking the viewport
//
// The top of the window is a logical line plus a sub-row inside it, which is
// how an editor scrolls through a file it has not wrapped. Everything here is
// bounded by the number of rows on screen.
// ---------------------------------------------------------------------------

// vis_step moves (line, sub) forward or backward one visual row and reports
// whether it could. The ends of the buffer are walls, not wraps.
vis_step :: proc(ed: ^Editor, line, sub: int, d: int) -> (int, int, bool) {
	if d > 0 {
		if sub + 1 < wrap_count(ed, line) {
			return line, sub + 1, true
		}
		if line + 1 >= buf_lines(&ed.buf) {
			return line, sub, false
		}
		return line + 1, 0, true
	}
	if sub > 0 {
		return line, sub - 1, true
	}
	if line == 0 {
		return line, sub, false
	}
	return line - 1, wrap_count(ed, line - 1) - 1, true
}

vis_advance :: proc(ed: ^Editor, line, sub: int, n: int) -> (int, int) {
	l, s := line, sub
	for _ in 0 ..< abs(n) {
		nl, ns, ok := vis_step(ed, l, s, n)
		if !ok {
			break
		}
		l, s = nl, ns
	}
	return l, s
}

// vis_before reports whether visual row (al, as) comes before (bl, bs).
vis_before :: proc(al, as_, bl, bs: int) -> bool {
	if al != bl {
		return al < bl
	}
	return as_ < bs
}

// vis_gap counts the visual rows from (al,as) to (bl,bs), giving up once the
// answer is at least `limit` — the caller only ever needs to know "is it off
// the bottom of the window", and a file is too long to count through.
vis_gap :: proc(ed: ^Editor, al, as_, bl, bs: int, limit: int) -> int {
	l, s := al, as_
	for n in 0 ..< limit {
		if l == bl && s == bs {
			return n
		}
		nl, ns, ok := vis_step(ed, l, s, 1)
		if !ok {
			return limit
		}
		l, s = nl, ns
	}
	return limit
}

// build_visible fills `ed.vis` with the rows the window shows, starting at
// (ed.top, ed.top_sub). Called once a frame, before the gutter and the text
// are drawn, so both panes iterate exactly the same list.
build_visible :: proc(ed: ^Editor) {
	clear(&ed.vis)
	n := buf_lines(&ed.buf)
	if n == 0 {
		return
	}
	ed.top = clamp(ed.top, 0, n - 1)
	rows := make([dynamic]Vis, 0, 8, context.temp_allocator)

	li := ed.top
	sub := ed.top_sub
	for li < n && len(ed.vis) < ed.rows {
		wrap_rows(ed, li, &rows)
		if sub >= len(rows) {
			// The line shrank under the viewport — a possibility after an
			// edit, and the only sane answer is the last row it still has.
			sub = max(0, len(rows) - 1)
			ed.top_sub = sub
		}
		for k in sub ..< len(rows) {
			if len(ed.vis) >= ed.rows {
				break
			}
			append(&ed.vis, rows[k])
		}
		sub = 0
		li += 1
	}
	if ed.top_sub >= wrap_count(ed, ed.top) {
		ed.top_sub = max(0, wrap_count(ed, ed.top) - 1)
	}
}
