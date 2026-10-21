// `sheets --selftest`, the pointer. Every case runs real frames through
// palmy's offscreen path — `handle_pointer`, `frame`, `draw_grid` — with a
// synthetic pointer, so what is asserted is what a click in the window does;
// the geometry each click aims at comes from `pointer_geom`, the same one
// the hit test uses. `pointer.sh` drives the same thing through a real X
// server.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
Rig :: struct {
	off: ^p.Offscreen,
	app: ^App,
}

@(private = "file")
rig_make :: proc() -> Rig {
	r: Rig
	r.off = p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
	load_sans(&r.off.fonts)
	sc.register_shadcn_theme()
	r.app = new(App)
	app_init(r.app)
	r.app.fonts = &r.off.fonts
	r.app.pal = palette_build()
	r.app.name = strings.clone("Untitled")
	seed_demo(r.app)
	step(&r)
	step(&r)
	return r
}

@(private = "file")
rig_free :: proc(r: ^Rig) {
	delete(r.app.name)
	app_destroy(r.app)
	free(r.app)
	p.offscreen_destroy(r.off)
}

@(private = "file")
step :: proc(r: ^Rig) {
	ui := p.offscreen_begin(r.off)
	measure_viewport(r.app, p.size(ui))
	handle_keys(ui, r.app)
	handle_pointer(ui, r.app)
	frame(ui, r.app)
	p.offscreen_end(r.off)
	r.off.input.mods = {}
}

// centre is the middle of a cell on screen, in logical pixels.
@(private = "file")
centre :: proc(r: ^Rig, a: Addr) -> [2]f32 {
	g, _ := pointer_geom(r.app)
	cr, _ := geom_cell(r.app, &g, a)
	return {cr.x + cr.w / 2, cr.y + cr.h / 2}
}

@(private = "file")
drag :: proc(r: ^Rig, from, to: [2]f32, mods: p.Modifiers = {}) {
	p.move_pointer(r.off, from.x, from.y)
	step(r)
	r.off.input.mods = mods
	p.press(r.off)
	step(r)
	mid := (from + to) / 2
	p.move_pointer(r.off, mid.x, mid.y)
	step(r)
	p.move_pointer(r.off, to.x, to.y)
	step(r)
	p.release(r.off)
	step(r)
}

@(private = "file")
click :: proc(r: ^Rig, at: [2]f32, mods: p.Modifiers = {}) {
	p.move_pointer(r.off, at.x, at.y)
	step(r)
	r.off.input.mods = mods
	// Press and release in one frame, the way a scripted click arrives.
	p.press(r.off)
	p.release(r.off)
	step(r)
}

@(private = "file")
same_color :: proc(a, b: p.Color) -> bool {
	return abs(int(a.r) - int(b.r)) < 24 && abs(int(a.g) - int(b.g)) < 24 && abs(int(a.b) - int(b.b)) < 24
}

t_pointer :: proc(tc: ^TC) {
	// --- cells -------------------------------------------------------------
	{
		r := rig_make()
		defer rig_free(&r)
		app := r.app
		ok_mark(tc, app.grid_rect.w > 100 && app.grid_rect.h > 100, "the grid records where it was drawn")

		click(&r, centre(&r, {4, 2}))
		ok_mark(tc, app.cur == Addr{4, 2} && app.anchor == app.cur, fmt.tprintf("a click selects the cell under it (%v)", app.cur))

		drag(&r, centre(&r, {2, 1}), centre(&r, {5, 3}))
		ok_mark(tc, sel_rect(app) == Rect_I{2, 1, 5, 3}, fmt.tprintf("a drag selects the range it covers (%v)", sel_rect(app)))

		click(&r, centre(&r, {7, 2}), {.Shift})
		ok_mark(tc, sel_rect(app) == Rect_I{2, 1, 7, 2}, fmt.tprintf("Shift+click extends it (%v)", sel_rect(app)))

		// The frozen strip (Sales freezes two rows and a column) is hit like
		// any other cell, and a merged title is clicked onto its anchor.
		click(&r, centre(&r, {0, 0}))
		ok_mark(tc, app.cur == Addr{0, 0} && app.anchor == app.cur, fmt.tprintf("a click on the merged title in the frozen corner lands on A1 (%v %v)", app.cur, app.anchor))

		// Headers.
		g, _ := pointer_geom(app)
		ci := geom_col_slot(&g, 2)
		click(&r, {(g.xs[ci] + g.xs[ci + 1]) / 2, g.body.y - HDR_H / 2})
		sel := sel_rect(app)
		ok_mark(tc, sel.c0 == 2 && sel.c1 == 2 && sel.r0 == 0 && sel.r1 == MAX_ROWS - 1, fmt.tprintf("a column header selects the column (%v)", sel))
		ok_mark(tc, app.cur == Addr{0, 2}, "with its top cell active, and nothing scrolled")
		// (The geometry lives in the frame's temporary memory: measure again.)
		g, _ = pointer_geom(app)
		ri := geom_row_slot(&g, 4)
		click(&r, {g.body.x - 10, (g.ys[ri] + g.ys[ri + 1]) / 2})
		sel = sel_rect(app)
		ok_mark(tc, sel.r0 == 4 && sel.r1 == 4 && sel.c0 == 0 && sel.c1 == MAX_COLS - 1, fmt.tprintf("a row header selects the row (%v)", sel))

		// A click while typing commits what was typed.
		click(&r, centre(&r, {12, 1}))
		app.mode = .Edit
		app.in_bar = false
		line_set(&app.edit, "42")
		click(&r, centre(&r, {13, 2}))
		ok_mark(tc, app.mode == .Nav && input_at(app.sh, {12, 1}) == "42" && app.cur == Addr{13, 2}, "a click during an edit commits it and moves")
	}

	// --- column and row borders ---------------------------------------------
	{
		r := rig_make()
		defer rig_free(&r)
		app := r.app
		g, _ := pointer_geom(app)
		ci := geom_col_slot(&g, 1) // B
		edge := g.xs[ci + 1]
		hy := g.body.y - HDR_H / 2
		ok_mark(tc, pointer_hit(app, {edge + 2, hy}).kind == .Col_Border, "the line between two column headers is a border")
		ok_mark(tc, pointer_cursor(app, {edge - 2, hy}) == "cursor-col-resize", "and asks for the resize pointer")
		before := col_width(app.sh, 1)
		undos := len(app.undo.past)
		drag(&r, {edge, hy}, {edge + 40, hy})
		ok_mark(tc, abs(col_width(app.sh, 1) - (before + 40)) < 0.5, fmt.tprintf("dragging it widens the column by the distance (%v -> %v)", before, col_width(app.sh, 1)))
		ok_mark(tc, len(app.undo.past) == undos + 1, "as one undo step")
		drag(&r, {edge + 40, hy}, {edge - 400, hy})
		ok_mark(tc, col_width(app.sh, 1) == 28, "and never narrower than a column can be")
		do_undo(app)
		ok_mark(tc, abs(col_width(app.sh, 1) - (before + 40)) < 0.5, "undo takes back the last drag whole")

		g, _ = pointer_geom(app)
		ri := geom_row_slot(&g, 3)
		redge := g.ys[ri + 1]
		hx := g.body.x - 10
		ok_mark(tc, pointer_hit(app, {hx, redge - 1}).kind == .Row_Border, "the line between two row headers is a border")
		rbefore := row_height(app.sh, 3)
		drag(&r, {hx, redge}, {hx, redge + 30})
		ok_mark(tc, abs(row_height(app.sh, 3) - (rbefore + 30)) < 0.5, fmt.tprintf("dragging it makes the row taller (%v)", row_height(app.sh, 3)))
	}

	// --- charts ---------------------------------------------------------------
	{
		r := rig_make()
		defer rig_free(&r)
		app := r.app
		use_sheet(app, 1) // Summary: a 7x14 bar chart at D1
		step(&r)
		step(&r)
		ch := app.sh.charts[0]
		ok_mark(tc, ch.at == Addr{0, 3} && ch.w == 7 && ch.h == 14, "the demo chart is where the demo puts it")

		// A click on it selects it, and changes nothing.
		undos := len(app.undo.past)
		click(&r, centre(&r, {5, 6}))
		ok_mark(tc, chart_at(app.sh, app.cur) == 0, "a click on a chart puts the cursor on it")
		ok_mark(tc, len(app.undo.past) == undos && app.sh.charts[0].at == ch.at, "and a click that does not move it is not an edit")
		ok_mark(tc, pointer_cursor(app, centre(&r, {5, 6})) == "cursor-grab", "the pointer over a chart is a hand")

		// Dragging moves it by whole cells, the grab point kept.
		drag(&r, centre(&r, {5, 6}), centre(&r, {8, 8}))
		ok_mark(tc, app.sh.charts[0].at == Addr{3, 5}, fmt.tprintf("dragging a chart moves it by the cells dragged (%v)", app.sh.charts[0].at))
		ok_mark(tc, chart_at(app.sh, app.cur) == 0, "and it stays selected")
		ok_mark(tc, len(app.undo.past) == undos + 1, "as one undo step, however many frames the drag took")
		do_undo(app)
		ok_mark(tc, app.sh.charts[0].at == Addr{0, 3}, "which undo takes back")

		// Off the top-left edge it stops at A1.
		drag(&r, centre(&r, {1, 4}), centre(&r, {0, 0}))
		ok_mark(tc, app.sh.charts[0].at == Addr{0, 0}, fmt.tprintf("a chart dragged past the edge stops at it (%v)", app.sh.charts[0].at))

		// The corner handle resizes it, the top-left corner fixed.
		g, _ := pointer_geom(app)
		box, _ := chart_box(app, app.sh.charts[0], &g)
		corner := [2]f32{p.rect_right(box), p.rect_bottom(box)}
		ok_mark(tc, pointer_hit(app, corner + {-3, -3}).kind == .Chart_Handle, "the corner handle is hit from inside the chart")
		drag(&r, corner + {-2, -2}, centre(&r, {9, 5}))
		c2 := app.sh.charts[0]
		ok_mark(tc, c2.at == Addr{0, 0} && c2.w == 6 && c2.h == 10, fmt.tprintf("dragging the handle onto F10 makes it A1:F10 (%v %dx%d)", c2.at, c2.w, c2.h))
		ok_mark(tc, chart_at(app.sh, app.cur) == 0, "and the chart is still the selected one")
		g, _ = pointer_geom(app)
		box, _ = chart_box(app, app.sh.charts[0], &g)
		drag(&r, {p.rect_right(box) - 2, p.rect_bottom(box) - 2}, centre(&r, {0, 0}))
		c3 := app.sh.charts[0]
		ok_mark(tc, c3.w == CHART_MIN_W && c3.h == CHART_MIN_H, "and never smaller than a chart can be")
	}

	// --- the frozen-pane line and a chart ---------------------------------------
	// Sales freezes two rows and a column. A chart dragged over the split
	// covers the line; the line goes on below and beside it.
	{
		r := rig_make()
		defer rig_free(&r)
		app := r.app
		append(&app.sh.charts, Chart{kind = .Bar, title = strings.clone("", app.sh.heap), sheet = strings.clone("", app.sh.heap), rect = {2, 0, 6, 1}, at = {6, 3}, w = 4, h = 6})
		step(&r)
		n := len(app.sh.charts) - 1
		drag(&r, centre(&r, {7, 4}), centre(&r, {1, 0}))
		ch := app.sh.charts[n]
		ok_mark(tc, ch.at == Addr{0, 0}, fmt.tprintf("the chart is dragged over both frozen edges (%v)", ch.at))
		step(&r)
		g, _ := pointer_geom(app)
		box, _ := chart_box(app, ch, &g)
		edge := app.pal.sel_edge
		x := int(g.split_x) - 1
		y := int(g.split_y) - 1
		inside_v := p.offscreen_pixel(r.off, x, int(box.y + box.h / 2))
		inside_h := p.offscreen_pixel(r.off, int(box.x + box.w / 2), y)
		below := p.offscreen_pixel(r.off, x, int(p.rect_bottom(box) + 30))
		beside := p.offscreen_pixel(r.off, int(p.rect_right(box) + 30), y)
		ok_mark(tc, !same_color(inside_v, edge) && !same_color(inside_h, edge), fmt.tprintf("neither frozen line is drawn across the chart (%v %v)", inside_v, inside_h))
		ok_mark(tc, same_color(below, edge) && same_color(beside, edge), fmt.tprintf("and both are drawn where it is not (%v %v)", below, beside))
		hdr := p.offscreen_pixel(r.off, x, int(g.body.y - HDR_H / 2))
		ok_mark(tc, same_color(hdr, edge), "the split still marks the column header")
	}
}
