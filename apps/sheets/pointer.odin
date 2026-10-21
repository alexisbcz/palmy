// The pointer in the grid: click to select, drag to select a range, drag a
// chart to move it and its corner handle to resize it, drag a column's or a
// row's border in the headers to resize it.
//
// Everything here works in logical pixels against the geometry the grid was
// last drawn with (`app.grid_rect`, stored by `draw_grid`), through the same
// `grid_geom` the drawing uses, so a hit lands on exactly what is on screen:
// frozen columns, scrolled ones, merged cells and the gutter's width alike.
// The three entry points take a position rather than palmy's input, which is
// what lets the self-test drive them directly as well as through a real
// offscreen frame, and `pointer.sh` drive them through a real X server.
//
// A drag that changes the sheet is one undo step, taken on its first change —
// so a click on a chart that does not move it adds nothing to undo. In a
// shared document the change is handed to the CRDT once, on release, rather
// than on every frame of the drag: collaborators see the chart land, and it
// is one step of this person's undo there too.
package main

import p "palmy:."

Drag :: enum u8 {
	None,
	Cells, // extending the selection from the cell pressed
	Rows, // the same, from a row header
	Cols, // and from a column header
	Chart_Move,
	Chart_Size,
	Col_Size,
	Row_Size,
}

Pointer_State :: struct {
	drag:    Drag,
	index:   int, // the chart, column or row being dragged
	grab:    Addr, // Chart_Move: the cell under the pointer, relative to the chart's corner
	start:   f32, // Col_Size/Row_Size: the pointer coordinate the drag began at
	base:    f32, // and the size it began from
	changed: bool, // the drag has changed the sheet (and pushed its undo step)
}

// How close to a border or a handle counts as on it, in logical pixels.
BORDER_GRAB :: f32(4)
HANDLE_GRAB :: f32(7)

// pointer_geom is the grid's geometry in logical pixels, as last drawn.
pointer_geom :: proc(app: ^App) -> (Grid_Geom, bool) {
	r := app.grid_rect
	if r.w <= 1 || r.h <= 1 {
		return {}, false
	}
	return grid_geom(app, r, 1, header_width(app), HDR_H), true
}

Hit_Kind :: enum u8 {
	Outside,
	Corner, // the box where the two headers meet
	Col_Header,
	Row_Header,
	Col_Border, // the right edge of column `index`, in the header
	Row_Border, // the bottom edge of row `index`, in the header
	Cell,
	Chart,
	Chart_Handle,
}

Hit_Result :: struct {
	kind:  Hit_Kind,
	index: int, // column, row or chart
	cell:  Addr, // the cell under the pointer, clamped to what is on screen
}

// slot_at finds which of the laid-out spans holds `v`, clamping to the first
// or last one, so a drag that runs off the edge keeps hold of the edge.
@(private = "file")
slot_at :: proc(edges: []f32, v: f32) -> int {
	n := len(edges) - 1
	if n <= 0 {
		return -1
	}
	if v < edges[0] {
		return 0
	}
	for i in 0 ..< n {
		if v < edges[i + 1] {
			return i
		}
	}
	return n - 1
}

// pointer_cell is the cell under a point in the body, clamped to the visible
// grid.
pointer_cell :: proc(g: ^Grid_Geom, pos: [2]f32) -> (Addr, bool) {
	ci := slot_at(g.xs[:], pos.x)
	ri := slot_at(g.ys[:], pos.y)
	if ci < 0 || ri < 0 {
		return {}, false
	}
	return {g.rows[ri], g.cols[ci]}, true
}

// chart_box_logical is `chart_box` at scale 1.
@(private = "file")
chart_box_logical :: proc(app: ^App, g: ^Grid_Geom, i: int) -> (p.Rect, bool) {
	return chart_box(app, app.sh.charts[i], g)
}

pointer_hit :: proc(app: ^App, pos: [2]f32) -> Hit_Result {
	g, ok := pointer_geom(app)
	if !ok || !p.rect_contains(app.grid_rect, pos.x, pos.y) {
		return {kind = .Outside}
	}
	body := g.body
	in_cols := pos.y < body.y
	in_rows := pos.x < body.x
	cell, _ := pointer_cell(&g, pos)
	switch {
	case in_cols && in_rows:
		return {kind = .Corner, cell = cell}
	case in_cols:
		// The border nearest the pointer, if it is close enough: a border is
		// grabbed from either side of the line, as in every spreadsheet.
		for i in 0 ..< len(g.cols) {
			if abs(pos.x - g.xs[i + 1]) <= BORDER_GRAB {
				return {kind = .Col_Border, index = g.cols[i], cell = cell}
			}
		}
		return {kind = .Col_Header, index = cell.col, cell = cell}
	case in_rows:
		for i in 0 ..< len(g.rows) {
			if abs(pos.y - g.ys[i + 1]) <= BORDER_GRAB {
				return {kind = .Row_Border, index = g.rows[i], cell = cell}
			}
		}
		return {kind = .Row_Header, index = cell.row, cell = cell}
	}
	// Charts are on top of the cells, the last drawn topmost.
	for i := len(app.sh.charts) - 1; i >= 0; i -= 1 {
		box, bok := chart_box_logical(app, &g, i)
		if !bok {
			continue
		}
		corner := [2]f32{p.rect_right(box), p.rect_bottom(box)}
		if abs(pos.x - corner.x) <= HANDLE_GRAB && abs(pos.y - corner.y) <= HANDLE_GRAB {
			return {kind = .Chart_Handle, index = i, cell = cell}
		}
		if p.rect_contains(box, pos.x, pos.y) {
			return {kind = .Chart, index = i, cell = cell}
		}
	}
	return {kind = .Cell, cell = cell}
}

// pointer_cursor is the pointer shape a position asks for, as a class.
pointer_cursor :: proc(app: ^App, pos: [2]f32) -> string {
	#partial switch app.ptr.drag {
	case .Col_Size:
		return "cursor-col-resize"
	case .Row_Size:
		return "cursor-row-resize"
	case .Chart_Move:
		return "cursor-grabbing"
	case .Chart_Size:
		return "cursor-crosshair"
	}
	#partial switch pointer_hit(app, pos).kind {
	case .Col_Border:
		return "cursor-col-resize"
	case .Row_Border:
		return "cursor-row-resize"
	case .Chart:
		return "cursor-grab"
	case .Chart_Handle:
		return "cursor-crosshair"
	}
	return ""
}

// pointer_press starts whatever the press is on. It reports whether the
// press was in the grid at all.
pointer_press :: proc(app: ^App, pos: [2]f32, shift: bool) -> bool {
	h := pointer_hit(app, pos)
	if h.kind == .Outside {
		return false
	}
	if app.mode == .Edit {
		// A click elsewhere in the grid commits the edit, as Enter would,
		// and then selects as usual.
		commit_edit(app, 0, 0)
	}
	if app.mode != .Nav {
		return true
	}
	app.ptr = {}
	clear_status(app)
	switch h.kind {
	case .Outside:
	case .Corner:
		// The whole sheet, the convention for that box.
		app.anchor = {0, 0}
		app.cur = {MAX_ROWS - 1, MAX_COLS - 1}
		set_status(app, "Selected the whole sheet")
	case .Col_Header:
		// The whole column. The active cell is its top one, and the far
		// corner the bottom, so a later Shift+click or drag extends across
		// columns; nothing scrolls.
		if shift {
			app.anchor.row = MAX_ROWS - 1
		} else {
			app.anchor = {MAX_ROWS - 1, h.index}
		}
		app.cur = {0, h.index}
		app.ptr = {drag = .Cols}
	case .Row_Header:
		if shift {
			app.anchor.col = MAX_COLS - 1
		} else {
			app.anchor = {h.index, MAX_COLS - 1}
		}
		app.cur = {h.index, 0}
		app.ptr = {drag = .Rows}
	case .Col_Border:
		app.ptr = {drag = .Col_Size, index = h.index, start = pos.x, base = col_width(app.sh, h.index)}
	case .Row_Border:
		app.ptr = {drag = .Row_Size, index = h.index, start = pos.y, base = row_height(app.sh, h.index)}
	case .Chart, .Chart_Handle:
		ch := app.sh.charts[h.index]
		// The cursor goes onto the chart, which is what selects it for the
		// keyboard too (Alt+Shift+Arrows, Alt+D, Delete chart).
		app.cur = h.cell
		app.anchor = h.cell
		if h.kind == .Chart_Handle {
			app.ptr = {drag = .Chart_Size, index = h.index}
		} else {
			app.ptr = {drag = .Chart_Move, index = h.index, grab = {h.cell.row - ch.at.row, h.cell.col - ch.at.col}}
		}
	case .Cell:
		// A cell a merge swallows is the merge: the click lands on its
		// anchor, the only one of its cells that holds anything.
		a := h.cell
		if m, ok := merge_at(app.sh, a); ok && !shift {
			a = {m.r0, m.c0}
		}
		goto_cell(app, a, shift)
		app.ptr = {drag = .Cells}
	}
	return true
}

// pointer_first_change takes the drag's one undo step.
@(private = "file")
pointer_first_change :: proc(app: ^App) {
	if app.ptr.changed {
		return
	}
	app.ptr.changed = true
	if collab.on {
		app.modified = true // the CRDT is told on release
	} else {
		undo_push(app)
	}
}

// pointer_move continues a drag.
pointer_move :: proc(app: ^App, pos: [2]f32) {
	if app.ptr.drag == .None {
		return
	}
	g, ok := pointer_geom(app)
	if !ok {
		return
	}
	cell, cok := pointer_cell(&g, pos)
	sh := app.sh
	switch app.ptr.drag {
	case .None:
	case .Cells:
		// Still inside the merge the drag began on is still that cell.
		if m, mok := merge_at(sh, cell); cok && mok && rect_contains(m, app.anchor) {
			cell = app.anchor
		}
		if cok && cell != app.cur {
			app.cur = cell
			follow_cursor(app)
		}
	case .Cols:
		if cok {
			app.cur = {0, cell.col}
		}
	case .Rows:
		if cok {
			app.cur = {cell.row, 0}
		}
	case .Col_Size:
		w := clamp(app.ptr.base + (pos.x - app.ptr.start), 28, 520)
		if w != col_width(sh, app.ptr.index) {
			pointer_first_change(app)
			set_col_width(sh, app.ptr.index, w)
			set_status(app, "Column %s is %d px", col_name(app.ptr.index), int(w + 0.5))
		}
	case .Row_Size:
		h := clamp(app.ptr.base + (pos.y - app.ptr.start), 14, 200)
		if h != row_height(sh, app.ptr.index) {
			pointer_first_change(app)
			set_row_height(sh, app.ptr.index, h)
			set_status(app, "Row %d is %d px", app.ptr.index + 1, int(h + 0.5))
		}
	case .Chart_Move:
		i := app.ptr.index
		if !cok || i < 0 || i >= len(sh.charts) {
			return
		}
		ch := &sh.charts[i]
		at := Addr {
			clamp(cell.row - app.ptr.grab.row, 0, MAX_ROWS - max(ch.h, 1)),
			clamp(cell.col - app.ptr.grab.col, 0, MAX_COLS - max(ch.w, 1)),
		}
		if at != ch.at {
			pointer_first_change(app)
			ch = &sh.charts[i] // undo_push does not move charts, but be exact
			ch.at = at
			// The cursor rides along, so the chart stays the selected one.
			app.cur = {at.row + app.ptr.grab.row, at.col + app.ptr.grab.col}
			app.anchor = app.cur
			set_status(app, "Chart at %s", addr_name(at))
		}
	case .Chart_Size:
		i := app.ptr.index
		if !cok || i < 0 || i >= len(sh.charts) {
			return
		}
		ch := sh.charts[i]
		// The handle covers the cell it is dropped on.
		w := cell.col - ch.at.col + 1
		h := cell.row - ch.at.row + 1
		if clamp(w, CHART_MIN_W, CHART_MAX_W) != ch.w || clamp(h, CHART_MIN_H, CHART_MAX_H) != ch.h {
			pointer_first_change(app)
			if chart_resize(sh, i, w, h) {
				set_status(app, "Chart is %s cells", chart_size_text(sh.charts[i]))
			}
		}
	}
}

// pointer_release ends a drag.
pointer_release :: proc(app: ^App) {
	if app.ptr.changed && collab.on {
		collab_note_edit(app)
	}
	app.ptr = {}
}

// handle_pointer feeds a frame's pointer input to the three procedures
// above. A press and its release can arrive in one frame (a scripted click
// does exactly that), so each is handled in order, not as a state.
handle_pointer :: proc(ui: ^p.Ctx, app: ^App) {
	if app.mode == .Prompt || app.mode == .Palette || app.mode == .Help {
		app.ptr = {}
		return
	}
	pos := p.mouse_pos(ui)
	if ui.input.pressed[.Left] {
		if pointer_press(app, pos, .Shift in ui.input.mods) {
			p.redraw(ui)
		}
	}
	if app.ptr.drag != .None && (ui.input.down[.Left] || ui.input.released[.Left]) {
		pointer_move(app, pos)
		p.redraw(ui)
	}
	if ui.input.released[.Left] || (app.ptr.drag != .None && !ui.input.down[.Left]) {
		pointer_release(app)
	}
}
