// Range operations: copy, cut, paste, fill, and the structural edits.
//
// Every one of these is a transform on the AST followed by writing the
// formula back out as source, which is why `ast_print` has to be faithful.
// Doing it on the text with a regular expression is how `$A$1` ends up
// drifting.
package main

import "core:strings"

Clip_Cell :: struct {
	drow, dcol: int,
	input:      string, // owned
	fmt:        Cell_Fmt,
}

Clipboard :: struct {
	cells: [dynamic]Clip_Cell,
	h, w:  int,
	cut:   bool,
	src:   Rect_I,
	live:  bool,
}

clip_reset :: proc(cb: ^Clipboard) {
	for c in cb.cells {
		delete(c.input)
	}
	clear(&cb.cells)
	cb.live = false
	cb.cut = false
}

// offset_formula re-renders a formula as if it had been written `drow`/`dcol`
// away from where it was. Relative components move, absolute ones do not.
offset_formula :: proc(input: string, drow, dcol: int, allocator := context.allocator) -> string {
	t := strings.trim_space(input)
	if len(t) > 1 && t[0] == '=' {
		if root, ok := parse_formula(t[1:]); ok {
			ast_offset(root, drow, dcol)
			s := ast_source(root, allocator)
			ast_free(root)
			return s
		}
	}
	return strings.clone(input, allocator)
}

copy_range :: proc(sh: ^Sheet, cb: ^Clipboard, rect: Rect_I, cut: bool) {
	clip_reset(cb)
	cb.src = rect
	cb.h = rect.r1 - rect.r0 + 1
	cb.w = rect.c1 - rect.c0 + 1
	cb.cut = cut
	cb.live = true
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			c := cell_at(sh, {row, col})
			if c == nil {
				continue
			}
			append(
				&cb.cells,
				Clip_Cell {
					drow = row - rect.r0,
					dcol = col - rect.c0,
					input = strings.clone(c.input),
					fmt = c.fmt,
				},
			)
		}
	}
}

// paste_clip writes the clipboard at `target`, tiling it when the destination
// selection is a whole multiple of the copied block — which is what makes
// "copy one formula, select the column, paste" behave.
paste_clip :: proc(sh: ^Sheet, cb: ^Clipboard, target: Rect_I) {
	if !cb.live || cb.h == 0 || cb.w == 0 {
		return
	}
	sel_h := target.r1 - target.r0 + 1
	sel_w := target.c1 - target.c0 + 1
	reps_r := (sel_h > cb.h && sel_h % cb.h == 0) ? sel_h / cb.h : 1
	reps_c := (sel_w > cb.w && sel_w % cb.w == 0) ? sel_w / cb.w : 1

	if cb.cut {
		for row in cb.src.r0 ..= cb.src.r1 {
			for col in cb.src.c0 ..= cb.src.c1 {
				clear_cell(sh, {row, col})
			}
		}
	}

	for rr in 0 ..< reps_r {
		for cc in 0 ..< reps_c {
			base := Addr{target.r0 + rr * cb.h, target.c0 + cc * cb.w}
			drow := base.row - cb.src.r0
			dcol := base.col - cb.src.c0
			// Clear the destination block first, so pasting over data does
			// not leave stale cells where the source was empty.
			for row in base.row ..< base.row + cb.h {
				for col in base.col ..< base.col + cb.w {
					clear_cell(sh, {row, col})
				}
			}
			for cell in cb.cells {
				dst := Addr{base.row + cell.drow, base.col + cell.dcol}
				if dst.row < 0 || dst.col < 0 || dst.row >= MAX_ROWS || dst.col >= MAX_COLS {
					continue
				}
				// A cut moves a formula without rewriting it; a copy offsets
				// its relative references.
				src := cb.cut ? strings.clone(cell.input, context.temp_allocator) : offset_formula(cell.input, drow, dcol, context.temp_allocator)
				set_input(sh, dst, src)
				set_cell_fmt(sh, dst, cell.fmt)
			}
		}
	}
	if cb.cut {
		clip_reset(cb)
	}
}

// fill_down and fill_right repeat the leading edge of a selection across it,
// offsetting references exactly as a copy would.
fill_down :: proc(sh: ^Sheet, rect: Rect_I) {
	if rect.r1 <= rect.r0 {
		return
	}
	for col in rect.c0 ..= rect.c1 {
		src := cell_at(sh, {rect.r0, col})
		if src == nil {
			for row in rect.r0 + 1 ..= rect.r1 {
				clear_cell(sh, {row, col})
			}
			continue
		}
		input := strings.clone(src.input, context.temp_allocator)
		f := src.fmt
		for row in rect.r0 + 1 ..= rect.r1 {
			s := offset_formula(input, row - rect.r0, 0, context.temp_allocator)
			set_input(sh, {row, col}, s)
			set_cell_fmt(sh, {row, col}, f)
		}
	}
}

fill_right :: proc(sh: ^Sheet, rect: Rect_I) {
	if rect.c1 <= rect.c0 {
		return
	}
	for row in rect.r0 ..= rect.r1 {
		src := cell_at(sh, {row, rect.c0})
		if src == nil {
			for col in rect.c0 + 1 ..= rect.c1 {
				clear_cell(sh, {row, col})
			}
			continue
		}
		input := strings.clone(src.input, context.temp_allocator)
		f := src.fmt
		for col in rect.c0 + 1 ..= rect.c1 {
			s := offset_formula(input, 0, col - rect.c0, context.temp_allocator)
			set_input(sh, {row, col}, s)
			set_cell_fmt(sh, {row, col}, f)
		}
	}
}

clear_rect :: proc(sh: ^Sheet, rect: Rect_I, keep_format := true) {
	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			if keep_format {
				set_input(sh, {row, col}, "")
			} else {
				clear_cell(sh, {row, col})
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Structural edits
//
// Two things happen at once: the cells move, and every formula anywhere in
// the sheet has its references fixed up. The reference fixup is done first,
// in the old coordinate system, because that is the system the references are
// written in.
// ---------------------------------------------------------------------------

structural_op :: proc(sh: ^Sheet, insert: bool, axis_row: bool, at, n: int) {
	if n <= 0 || at < 0 {
		return
	}
	bk := sh.book
	target := sh.index

	// 1. Fix up every formula in the *book* and write it back out as source.
	//
	// This is the part a single-sheet engine gets to skip. A reference is to
	// a sheet, not to a coordinate system, so inserting a row on this sheet
	// has to move `Sheet1!A5` written on Sheet2 while leaving the plain `A5`
	// written on Sheet2 exactly where it is. `ast_structural` is handed both
	// the sheet the formula lives on and the sheet that was edited, and only
	// touches references that resolve to the second.
	for s in bk.sheets {
		for _, c in s.cells {
			if c.ast == nil {
				continue
			}
			ast_structural(c.ast, insert, axis_row, at, n, bk, s.index, target)
			src := ast_source(c.ast, context.temp_allocator)
			context.allocator = s.heap
			delete(c.input)
			c.input = strings.clone(src, s.heap)
			c.state = .Dirty
		}
	}

	// 2. Move the cells themselves.
	context.allocator = sh.heap
	moved := make(map[Addr]^Cell, len(sh.cells), sh.heap)
	for a, c in sh.cells {
		idx := axis_row ? a.row : a.col
		na := a
		if insert {
			if idx >= at {
				if axis_row {na.row += n} else {na.col += n}
			}
		} else {
			if idx >= at && idx < at + n {
				cell_destroy(sh, c)
				continue
			}
			if idx >= at + n {
				if axis_row {na.row -= n} else {na.col -= n}
			}
		}
		if na.row >= MAX_ROWS || na.col >= MAX_COLS {
			cell_destroy(sh, c)
			continue
		}
		moved[na] = c
	}
	delete(sh.cells)
	sh.cells = moved

	// 3. Move the row heights / column widths with them.
	sizes := axis_row ? &sh.row_h : &sh.col_w
	ns := make(map[int]f32, len(sizes^), sh.heap)
	for i, v in sizes^ {
		j := i
		if insert {
			if i >= at {
				j = i + n
			}
		} else {
			if i >= at && i < at + n {
				continue
			}
			if i >= at + n {
				j = i - n
			}
		}
		ns[j] = v
	}
	delete(sizes^)
	sizes^ = ns

	// 4. And everything else that is addressed in grid coordinates: merges,
	// the frozen split, and the ranges and anchors of the charts.
	for i := len(sh.merges) - 1; i >= 0; i -= 1 {
		if r, ok := rect_structural(sh.merges[i], insert, axis_row, at, n); ok {
			sh.merges[i] = r
		} else {
			ordered_remove(&sh.merges, i)
		}
	}
	split := axis_row ? &sh.frz_rows : &sh.frz_cols
	if split^ > at {
		split^ = insert ? split^ + n : max(at, split^ - n)
	}
	for s in bk.sheets {
		for i in 0 ..< len(s.charts) {
			ch := &s.charts[i]
			// A chart's data range moves when its *data* sheet is edited.
			if resolve_sheet(bk, ch.sheet, s.index) == target {
				if r, ok := rect_structural(ch.rect, insert, axis_row, at, n); ok {
					ch.rect = r
				}
			}
			// Its anchor moves when the sheet it is drawn on is edited.
			if s.index == target {
				if r, ok := rect_structural(
					{ch.at.row, ch.at.col, ch.at.row, ch.at.col},
					insert,
					axis_row,
					at,
					n,
				); ok {
					ch.at = {r.r0, r.c0}
				}
			}
		}
	}

	refresh_bounds(sh)
	bk.graph_dirty = true
	book_recalc_all(bk)
}

// rect_structural maps a rectangle through an insert or a delete. A rectangle
// wholly inside a deleted block is gone, and one that straddles it is
// clamped — the same rule a range reference follows.
rect_structural :: proc(
	r_in: Rect_I,
	insert: bool,
	axis_row: bool,
	at, n: int,
) -> (
	Rect_I,
	bool,
) {
	r := r_in
	lo := axis_row ? r.r0 : r.c0
	hi := axis_row ? r.r1 : r.c1
	nlo, nhi := lo, hi
	if insert {
		if lo >= at {nlo = lo + n}
		if hi >= at {nhi = hi + n}
	} else {
		if at <= lo && at + n > hi {
			return r, false
		}
		nlo = lo < at ? lo : (lo >= at + n ? lo - n : at)
		nhi = hi < at ? hi : (hi >= at + n ? hi - n : at - 1)
	}
	if axis_row {
		r.r0, r.r1 = min(nlo, nhi), max(nlo, nhi)
	} else {
		r.c0, r.c1 = min(nlo, nhi), max(nlo, nhi)
	}
	return r, true
}

insert_rows :: proc(sh: ^Sheet, at, n: int) {structural_op(sh, true, true, at, n)}
delete_rows :: proc(sh: ^Sheet, at, n: int) {structural_op(sh, false, true, at, n)}
insert_cols :: proc(sh: ^Sheet, at, n: int) {structural_op(sh, true, false, at, n)}
delete_cols :: proc(sh: ^Sheet, at, n: int) {structural_op(sh, false, false, at, n)}

// ---------------------------------------------------------------------------
// Selection statistics, for the status bar
// ---------------------------------------------------------------------------

Sel_Stats :: struct {
	sum:     f64,
	avg:     f64,
	lo, hi:  f64,
	count:   int,
	counta:  int,
	has_num: bool,
}

STATS_SCAN_LIMIT :: 20000

selection_stats :: proc(sh: ^Sheet, rect_in: Rect_I) -> (st: Sel_Stats) {
	rect := rect_in
	rect.r1 = min(rect.r1, max(sh.max_row, rect.r0))
	rect.c1 = min(rect.c1, max(sh.max_col, rect.c0))
	area := (rect.r1 - rect.r0 + 1) * (rect.c1 - rect.c0 + 1)

	// Over a large selection it is cheaper to walk the cells that exist than
	// the addresses that might; the answer is the same either way.
	if area > STATS_SCAN_LIMIT {
		for addr, c in sh.cells {
			if rect_contains(rect, addr) {
				stats_add(&st, c.val)
			}
		}
		if st.count > 0 {
			st.avg = st.sum / f64(st.count)
		}
		return
	}

	for row in rect.r0 ..= rect.r1 {
		for col in rect.c0 ..= rect.c1 {
			c := cell_at(sh, {row, col})
			if c == nil {
				continue
			}
			stats_add(&st, c.val)
		}
	}
	if st.count > 0 {
		st.avg = st.sum / f64(st.count)
	}
	return
}

stats_add :: proc(st: ^Sel_Stats, v: Value) {
	{
		c := v
		switch c.kind {
		case .Number:
			st.counta += 1
			st.count += 1
			st.sum += c.num
			if !st.has_num {
				st.lo, st.hi, st.has_num = c.num, c.num, true
			} else {
				st.lo = min(st.lo, c.num)
				st.hi = max(st.hi, c.num)
			}
		case .Text, .Bool, .Error:
			st.counta += 1
		case .Empty:
		}
	}
}
