// The grid, drawn straight into the frame buffer through `p.pixels`.
//
// Only the visible cells are touched: the loop starts at the scroll position
// and stops as soon as it runs off the right or bottom edge, so a sheet with
// a million rows costs the same to draw as one with twenty.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

// Palette resolves the shadcn design tokens once, because the rasterizer
// wants colours and the class system is not involved down here.
Palette :: struct {
	bg:        p.Color,
	fg:        p.Color,
	muted:     p.Color,
	muted_fg:  p.Color,
	border:    p.Color,
	grid:      p.Color,
	primary:   p.Color,
	accent:    p.Color,
	sel_fill:  p.Color,
	sel_edge:  p.Color,
	hdr_bg:    p.Color,
	hdr_on:    p.Color,
	err:       p.Color,
	formula:   p.Color,
}

tok :: proc(name: string, fallback: u32) -> p.Color {
	if c, ok := p.parse_color(name); ok {
		return c
	}
	return p.hex(fallback)
}

palette_build :: proc() -> (pal: Palette) {
	pal.bg = tok("background", 0xffffff)
	pal.fg = tok("foreground", 0x0a0a0a)
	pal.muted = tok("muted", 0xf5f5f5)
	pal.muted_fg = tok("muted-foreground", 0x737373)
	pal.border = tok("border", 0xe5e5e5)
	pal.primary = tok("primary", 0x171717)
	pal.accent = tok("accent", 0xf5f5f5)
	pal.err = tok("destructive", 0xe7000b)
	// The grid rule is lighter than a component border: a full-strength line
	// every 22 pixels reads as a wall of grey.
	pal.grid = p.mix(pal.bg, pal.border, 0.85)
	pal.hdr_bg = pal.muted
	pal.hdr_on = p.mix(pal.muted, pal.primary, 0.18)
	pal.sel_fill = p.mix(pal.bg, pal.primary, 0.08)
	pal.sel_edge = pal.primary
	pal.formula = tok("blue-600", 0x2563eb)
	return
}

CELL_PAD :: f32(5)
CELL_TEXT :: f32(12.5)
HDR_TEXT :: f32(11)

// draw_grid is the `p.pixels` callback. `r` arrives in device pixels, so
// everything measured in logical pixels is scaled on the way in.
draw_grid :: proc(c: ^p.Canvas, r: p.Rect, app: ^App) {
	s := c.scale
	pal := app.pal
	p.fill_rect(c, r, pal.bg)

	hdr_w := header_width(app) * s
	hdr_h := HDR_H * s
	body := p.Rect{r.x + hdr_w, r.y + hdr_h, max(0, r.w - hdr_w), max(0, r.h - hdr_h)}
	sel := sel_rect(app)

	// Column edges, in device pixels, for the columns that can be seen.
	xs := make([dynamic]f32, 0, 64, context.temp_allocator)
	cols := make([dynamic]int, 0, 64, context.temp_allocator)
	x := body.x
	for col := app.left_col; col < MAX_COLS && x < p.rect_right(r); col += 1 {
		append(&xs, x)
		append(&cols, col)
		x += col_width(&app.sh, col) * s
	}
	append(&xs, x)

	ys := make([dynamic]f32, 0, 64, context.temp_allocator)
	rows := make([dynamic]int, 0, 64, context.temp_allocator)
	y := body.y
	for row := app.top_row; row < MAX_ROWS && y < p.rect_bottom(r); row += 1 {
		append(&ys, y)
		append(&rows, row)
		y += row_height(&app.sh, row) * s
	}
	append(&ys, y)

	// --- selection fill, behind everything ---
	p.push_clip(c, p.rect_intersect(c.clip, body))
	for row, ri in rows {
		if row < sel.r0 || row > sel.r1 {
			continue
		}
		for col, ci in cols {
			if col < sel.c0 || col > sel.c1 {
				continue
			}
			if row == app.cur.row && col == app.cur.col {
				continue // the active cell stays clear
			}
			p.fill_rect(c, {xs[ci], ys[ri], xs[ci + 1] - xs[ci], ys[ri + 1] - ys[ri]}, pal.sel_fill)
		}
	}

	// --- grid rules ---
	line := max(1, s * 0.75)
	for col, ci in cols {
		_ = col
		p.fill_rect(c, {xs[ci + 1] - line, body.y, line, body.h}, pal.grid)
	}
	for row, ri in rows {
		_ = row
		p.fill_rect(c, {body.x, ys[ri + 1] - line, body.w, line}, pal.grid)
	}

	// --- cell contents ---
	for row, ri in rows {
		for col, ci in cols {
			a := Addr{row, col}
			cell := cell_at(&app.sh, a)
			if cell == nil {
				continue
			}
			if app.mode == .Edit && !app.in_bar && a == app.cur {
				continue // the editor draws over it
			}
			cr := p.Rect{xs[ci], ys[ri], xs[ci + 1] - xs[ci], ys[ri + 1] - ys[ri]}
			text := format_value(cell.val, cell.fmt)
			if text == "" {
				continue
			}
			col_fg := cell.val.kind == .Error ? pal.err : pal.fg
			fam, wt := cell_face(cell.fmt)
			align := value_align(cell.val, cell.fmt)
			size := CELL_TEXT * s
			tw := p.text_width(app.fonts, text, size, fam, wt)
			avail := cr.w - 2 * CELL_PAD * s

			// Text that does not fit spills into the next cells while they
			// are empty, the way a spreadsheet does; a number that does not
			// fit shows #### instead of lying about its value.
			clip := cr
			if tw > avail {
				if cell.val.kind == .Number {
					// A number never spills: General drops decimals until it
					// fits, a fixed format that cannot fit shows ####, and
					// neither ever displays a truncated digit string.
					text = cell.fmt.num == .General \
						? fit_number(app, cell.val.num, avail, size, fam, wt) \
						: "####"
					tw = p.text_width(app.fonts, text, size, fam, wt)
				} else if cell.val.kind == .Text || cell.val.kind == .Error {
					k := ci + 1
					for k < len(cols) && cell_at(&app.sh, {row, cols[k]}) == nil {
						clip.w += xs[k + 1] - xs[k]
						k += 1
					}
				}
			}

			tx := cr.x + CELL_PAD * s
			switch align {
			case .Right:
				tx = p.rect_right(cr) - CELL_PAD * s - tw
			case .Center:
				tx = cr.x + (cr.w - tw) / 2
			case .Left, .Auto:
			}
			m := p.font_metrics(app.fonts, size, .Sans, wt)
			baseline := cr.y + (cr.h - (m.ascent + m.descent)) / 2 + m.ascent

			p.push_clip(c, p.rect_intersect(c.clip, p.rect_intersect(clip, body)))
			p.draw_text(c, app.fonts, text, tx, baseline, size, col_fg, fam, wt)
			p.pop_clip(c)
		}
	}

	// --- the cell being edited ---
	if app.mode == .Edit && !app.in_bar {
		ri := app.cur.row - app.top_row
		ci := app.cur.col - app.left_col
		if ri >= 0 && ri < len(rows) && ci >= 0 && ci < len(cols) {
			cr := p.Rect{xs[ci], ys[ri], xs[ci + 1] - xs[ci], ys[ri + 1] - ys[ri]}
			// Grow the box to the right so a long formula is readable while
			// it is being typed.
			size := CELL_TEXT * s
			tw := p.text_width(app.fonts, line_text(&app.edit), size, .Sans, .Regular)
			cr.w = max(cr.w, min(tw + 4 * CELL_PAD * s, p.rect_right(body) - cr.x))
			p.push_clip(c, p.rect_intersect(c.clip, body))
			p.fill_rect(c, cr, pal.bg)
			draw_line_edit(c, cr, app, &app.edit, "", pal.fg, true)
			p.stroke_round_rect(c, cr, {0, 0, 0, 0}, max(1, 2 * s), pal.sel_edge)
			p.pop_clip(c)
		}
	}

	// --- the active cell outline ---
	{
		ri := app.cur.row - app.top_row
		ci := app.cur.col - app.left_col
		if ri >= 0 && ri < len(rows) && ci >= 0 && ci < len(cols) && !(app.mode == .Edit && !app.in_bar) {
			cr := p.Rect{xs[ci], ys[ri], xs[ci + 1] - xs[ci], ys[ri + 1] - ys[ri]}
			p.push_clip(c, p.rect_intersect(c.clip, body))
			p.stroke_round_rect(c, cr, {0, 0, 0, 0}, max(1, 2 * s), pal.sel_edge)
			p.pop_clip(c)
		}
	}

	// --- the selection outline, when more than one cell is selected ---
	if sel.r0 != sel.r1 || sel.c0 != sel.c1 {
		x0 := edge_x(app, xs[:], cols[:], sel.c0, body, true)
		x1 := edge_x(app, xs[:], cols[:], sel.c1, body, false)
		y0 := edge_y(app, ys[:], rows[:], sel.r0, body, true)
		y1 := edge_y(app, ys[:], rows[:], sel.r1, body, false)
		if x1 > x0 && y1 > y0 {
			p.push_clip(c, p.rect_intersect(c.clip, body))
			p.stroke_round_rect(
				c,
				{x0, y0, x1 - x0, y1 - y0},
				{0, 0, 0, 0},
				max(1, s),
				p.fade(pal.sel_edge, 0.55),
			)
			p.pop_clip(c)
		}
	}
	p.pop_clip(c)

	// --- the frozen headers, drawn last so they sit on top ---
	p.fill_rect(c, {r.x, r.y, r.w, hdr_h}, pal.hdr_bg)
	p.fill_rect(c, {r.x, r.y, hdr_w, r.h}, pal.hdr_bg)
	p.fill_rect(c, {r.x, r.y + hdr_h - line, r.w, line}, pal.border)
	p.fill_rect(c, {r.x + hdr_w - line, r.y, line, r.h}, pal.border)

	hsize := HDR_TEXT * s
	hm := p.font_metrics(app.fonts, hsize, .Sans, .Medium)
	p.push_clip(c, p.rect_intersect(c.clip, {body.x, r.y, body.w, hdr_h}))
	for col, ci in cols {
		on := col >= sel.c0 && col <= sel.c1
		w := xs[ci + 1] - xs[ci]
		if on {
			p.fill_rect(c, {xs[ci], r.y, w - line, hdr_h - line}, pal.hdr_on)
		}
		name := col_name(col)
		tw := p.text_width(app.fonts, name, hsize, .Sans, on ? .Bold : .Medium)
		p.draw_text(
			c,
			app.fonts,
			name,
			xs[ci] + (w - tw) / 2,
			r.y + (hdr_h - (hm.ascent + hm.descent)) / 2 + hm.ascent,
			hsize,
			on ? pal.fg : pal.muted_fg,
			.Sans,
			on ? .Bold : .Medium,
		)
		p.fill_rect(c, {xs[ci + 1] - line, r.y, line, hdr_h}, pal.border)
	}
	p.pop_clip(c)

	p.push_clip(c, p.rect_intersect(c.clip, {r.x, body.y, hdr_w, body.h}))
	for row, ri in rows {
		on := row >= sel.r0 && row <= sel.r1
		h := ys[ri + 1] - ys[ri]
		if on {
			p.fill_rect(c, {r.x, ys[ri], hdr_w - line, h - line}, pal.hdr_on)
		}
		label := int_text(row + 1)
		tw := p.text_width(app.fonts, label, hsize, .Sans, on ? .Bold : .Medium)
		p.draw_text(
			c,
			app.fonts,
			label,
			r.x + (hdr_w - tw) / 2,
			ys[ri] + (h - (hm.ascent + hm.descent)) / 2 + hm.ascent,
			hsize,
			on ? pal.fg : pal.muted_fg,
			.Sans,
			on ? .Bold : .Medium,
		)
		p.fill_rect(c, {r.x, ys[ri + 1] - line, hdr_w, line}, pal.border)
	}
	p.pop_clip(c)
}

@(private = "file")
edge_x :: proc(app: ^App, xs: []f32, cols: []int, col: int, body: p.Rect, left: bool) -> f32 {
	for cc, i in cols {
		if cc == col {
			return left ? xs[i] : xs[i + 1]
		}
	}
	return col < app.left_col ? body.x : p.rect_right(body)
}

@(private = "file")
edge_y :: proc(app: ^App, ys: []f32, rows: []int, row: int, body: p.Rect, top: bool) -> f32 {
	for rr, i in rows {
		if rr == row {
			return top ? ys[i] : ys[i + 1]
		}
	}
	return row < app.top_row ? body.y : p.rect_bottom(body)
}

// fit_number drops significant digits until the number fits the column, the
// way a spreadsheet narrows a General cell rather than showing a lie.
fit_number :: proc(
	app: ^App,
	x: f64,
	avail, size: f32,
	fam: p.Font_Family,
	wt: p.Font_Weight,
) -> string {
	for d := 8; d >= 0; d -= 1 {
		t := trim_zeros(fmt.tprintf("%.*f", d, x))
		if p.text_width(app.fonts, t, size, fam, wt) <= avail {
			return t
		}
	}
	return "####"
}

int_text :: proc(v: int) -> string {
	buf: [24]u8
	n := 0
	x := v
	neg := x < 0
	if neg {
		x = -x
	}
	for {
		buf[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	if neg {
		buf[n] = '-'
		n += 1
	}
	out := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = buf[n - 1 - i]
	}
	return string(out)
}

// draw_line_edit renders one of the app's line editors with a solid caret.
// The caret position comes from `text_width_upto`, so it lands exactly where
// the glyphs do rather than on an estimate.
draw_line_edit :: proc(
	c: ^p.Canvas,
	r: p.Rect,
	app: ^App,
	l: ^Line,
	placeholder: string,
	col: p.Color,
	focused: bool,
) {
	s := c.scale
	size := CELL_TEXT * s
	text := line_text(l)
	m := p.font_metrics(app.fonts, size, .Sans, .Regular)
	baseline := r.y + (r.h - (m.ascent + m.descent)) / 2 + m.ascent
	pad := CELL_PAD * s

	// Scroll the text so the caret is always visible in a short box.
	caret_x := p.text_width_upto(app.fonts, text, clamp(l.caret, 0, len(text)), size)
	avail := max(r.w - 2 * pad, 1)
	off := f32(0)
	if caret_x > avail {
		off = caret_x - avail + size
	}

	p.push_clip(c, p.rect_intersect(c.clip, r))
	if text == "" && placeholder != "" {
		p.draw_text(c, app.fonts, placeholder, r.x + pad, baseline, size, app.pal.muted_fg)
	} else {
		// A formula reads as a formula: the leading `=` is coloured.
		if len(text) > 0 && text[0] == '=' {
			p.draw_text(c, app.fonts, text, r.x + pad - off, baseline, size, app.pal.formula)
		} else {
			p.draw_text(c, app.fonts, text, r.x + pad - off, baseline, size, col)
		}
	}
	if focused {
		cx := r.x + pad - off + caret_x
		p.fill_rect(c, {cx, r.y + 3 * s, max(1, s * 1.5), r.h - 6 * s}, app.pal.fg)
	}
	p.pop_clip(c)
}

_ :: strings
