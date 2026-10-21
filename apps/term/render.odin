package main

import "core:math"
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// Drawing the grid.
//
// palmy rasterizes in software and repaints its whole tree every frame, so a
// terminal that hands it eighty by twenty-four glyphs per frame will spend all
// its time in the glyph cache. The way out is a pixel cache of the grid that
// outlives the frame: rows the terminal marked dirty are re-rendered into it,
// everything else is left alone, and the finished image is copied into the
// window. A copy is memory bandwidth; a glyph is rasterization, blending and
// a hash lookup per pixel.
//
// On a full-screen `cat` every row is dirty every frame and the cache saves
// nothing, which is the honest worst case. On a shell prompt one row is dirty
// and it saves everything.
// ---------------------------------------------------------------------------

Grid_Renderer :: struct {
	fonts:        ^p.Fonts,
	px:           []u32,
	w, h:         int,
	cell_w:       int,
	cell_h:       int,
	baseline:     int,
	cols, rows:   int,
	size:         f32,
	scale:        f32,
	// Forces the next render to redraw every row: after a resize, a theme
	// change, or a scroll of the view.
	full:         bool,
	// True when something on the screen is blinking, so the frame loop
	// knows it has to keep waking up and the whole grid has to repaint on
	// each phase. A terminal with nothing blinking -- which is almost all
	// of them, almost all the time -- costs nothing for the feature.
	has_blink:    bool,
	last_blink:   bool,
	last_offset:  int,
	last_cursor:  [2]int,
	// Counters the self-test and the benchmark read.
	rows_drawn:   u64,
	cells_drawn:  u64,
	frames:       u64,
}

Selection :: struct {
	active:    bool,
	dragging:  bool,
	// Absolute row indices into the scrollback-plus-screen space, and
	// columns. `a` is where the drag started, `b` where it is now.
	a, b:      [2]int,
	block:     bool,
}

// renderer_metrics picks the cell size for a font size. Everything else in the
// terminal is derived from it, so it is computed once and kept.
renderer_metrics :: proc(r: ^Grid_Renderer, size: f32, scale: f32) {
	r.size = size
	r.scale = scale
	dev := size * scale
	m := p.font_metrics(r.fonts, dev, .Mono)
	adv := p.text_width(r.fonts, "M", dev, .Mono)
	r.cell_w = max(1, int(math.round(adv)))
	line := m.ascent + m.descent
	r.cell_h = max(1, int(math.round(max(m.line, line * 1.15))))
	r.baseline = int(math.round(m.ascent + (f32(r.cell_h) - line) * 0.5))
}

// renderer_fit works out how many whole cells fit in a pixel rectangle.
renderer_fit :: proc(r: ^Grid_Renderer, w, h: int) -> (cols, rows: int) {
	if r.cell_w <= 0 || r.cell_h <= 0 {
		return 1, 1
	}
	return max(1, w / r.cell_w), max(1, h / r.cell_h)
}

renderer_resize :: proc(r: ^Grid_Renderer, cols, rows: int) {
	w := cols * r.cell_w
	h := rows * r.cell_h
	if w == r.w && h == r.h && r.px != nil {
		return
	}
	delete(r.px)
	r.px = make([]u32, max(w * h, 1))
	r.w, r.h = w, h
	r.cols, r.rows = cols, rows
	r.full = true
}

renderer_destroy :: proc(r: ^Grid_Renderer) {
	delete(r.px)
	r.px = nil
}

@(private = "file")
pack_rgb :: proc "contextless" (c: vt.Rgb) -> u32 {
	return 0xFF00_0000 | u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

@(private = "file")
to_color :: proc "contextless" (c: vt.Rgb) -> p.Color {
	return p.Color{c[0], c[1], c[2], 255}
}

// render draws the terminal into the pixel cache.
renderer_draw :: proc(
	r: ^Grid_Renderer,
	t: ^vt.Terminal,
	sel: Selection,
	focused: bool,
	blink_on: bool,
) {
	if r.px == nil {
		return
	}
	c := p.canvas_from(r.px, r.w, r.h, 1)
	p.reset_clip(&c)

	s := vt.screen(t)
	offset := t.view_offset
	full := r.full || offset != r.last_offset || sel.active
	if r.has_blink && blink_on != r.last_blink {
		full = true
	}
	r.last_blink = blink_on
	r.has_blink = false
	r.last_offset = offset
	r.full = false
	r.frames += 1

	total := vt.screen_total_rows(s)
	first := max(0, total - r.rows - offset)

	cur_x, cur_y := vt.terminal_cursor(t)
	// The row the cursor is on always repaints: the block has to be removed
	// from where it was as well as drawn where it is.
	cursor_rows := [2]int{r.last_cursor[1], cur_y}
	r.last_cursor = {cur_x, cur_y}

	for y in 0 ..< r.rows {
		src := vt.screen_row(s, first + y)
		if src == nil {
			continue
		}
		dirty := full || src.dirty
		if !dirty && offset == 0 {
			if y == cursor_rows[0] || y == cursor_rows[1] {
				dirty = true
			}
		}
		if !dirty {
			continue
		}
		src.dirty = false
		draw_row(r, &c, t, src^, y, sel, first + y, blink_on)
		r.rows_drawn += 1
	}

	// The cursor goes on last so it sits over the text.
	if t.modes.cursor_visible && offset == 0 && (blink_on || !t.modes.cursor_blink) {
		draw_cursor(r, &c, t, cur_x, cur_y, focused)
	}
}

@(private = "file")
draw_row :: proc(
	r: ^Grid_Renderer,
	c: ^p.Canvas,
	t: ^vt.Terminal,
	row: vt.Row,
	y: int,
	sel: Selection,
	abs_y: int,
	blink_on: bool,
) {
	s := vt.screen(t)
	top := f32(y * r.cell_h)
	bg_default := vt.terminal_bg(t)

	// Pass one: backgrounds, merged into runs so a themed line is one fill
	// rather than eighty.
	x := 0
	for x < r.cols {
		cell := cell_or_blank(row, x)
		bg := cell_bg(t, cell, sel_contains(sel, abs_y, x))
		run := x + 1
		for run < r.cols {
			nc := cell_or_blank(row, run)
			if cell_bg(t, nc, sel_contains(sel, abs_y, run)) != bg {
				break
			}
			run += 1
		}
		p.fill_rect(
			c,
			{f32(x * r.cell_w), top, f32((run - x) * r.cell_w), f32(r.cell_h)},
			to_color(bg),
		)
		x = run
	}
	_ = bg_default

	// Images below the text: negative z, which is every Sixel image and a
	// Kitty image placed with z<0. They cover the cell backgrounds and the
	// glyphs land on top, the way kitty draws them.
	if row.frags != nil {
		draw_frags(r, row, y, true)
	}
	defer if row.frags != nil {
		draw_frags(r, row, y, false)
	}

	// Pass two: glyphs.
	buf: [32]u8
	for i in 0 ..< r.cols {
		cell := cell_or_blank(row, i)
		if .Spacer in cell.attrs {
			continue
		}
		if cell.ch == 0 || cell.ch == ' ' {
			if cell.under == .None && .Strike not_in cell.attrs && .Overline not_in cell.attrs {
				continue
			}
		}
		if .Invisible in cell.attrs {
			continue
		}
		if .Blink in cell.attrs {
			r.has_blink = true
			if !blink_on {
				continue
			}
		}
		fg := cell_fg(t, cell, sel_contains(sel, abs_y, i))
		col := to_color(fg)
		if .Faint in cell.attrs {
			col.a = 150
		}

		n := 0
		if cell.ch != 0 {
			n = vt.utf8_encode(buf[:], cell.ch)
		}
		for g in vt.screen_grapheme(s, cell) {
			if n + 4 <= len(buf) {
				n += vt.utf8_encode(buf[n:], g)
			}
		}
		wt := p.Font_Weight.Regular
		if .Bold in cell.attrs {
			wt = .Bold
		}
		sl := p.Font_Slant.Upright
		if .Italic in cell.attrs {
			sl = .Italic
		}
		if n > 0 && cell.ch != ' ' {
			p.draw_text(
				c,
				r.fonts,
				string(buf[:n]),
				f32(i * r.cell_w),
				top + f32(r.baseline),
				r.size * r.scale,
				col,
				.Mono,
				wt,
				0,
				sl,
			)
		}

		// Decorations.
		ul_col := col
		if !vt.color_is_default(cell.ul) {
			ul_col = to_color(vt.terminal_resolve(t, cell.ul, true, cell.attrs))
		}
		if cell.under != .None {
			draw_underline(r, c, i, y, cell.under, ul_col)
		}
		if .Strike in cell.attrs {
			yy := top + f32(r.baseline) - f32(r.cell_h) * 0.25
			p.fill_rect(c, {f32(i * r.cell_w), yy, f32(r.cell_w), max(1, f32(r.cell_h) / 16)}, col)
		}
		if .Overline in cell.attrs {
			p.fill_rect(c, {f32(i * r.cell_w), top, f32(r.cell_w), max(1, f32(r.cell_h) / 16)}, col)
		}
	}
}

@(private = "file")
draw_underline :: proc(
	r: ^Grid_Renderer,
	c: ^p.Canvas,
	i, y: int,
	style: vt.Underline_Style,
	col: p.Color,
) {
	x0 := f32(i * r.cell_w)
	thick := max(1, f32(r.cell_h) / 16)
	base := f32(y * r.cell_h) + f32(r.baseline) + max(1, f32(r.cell_h) * 0.12)
	switch style {
	case .None:
	case .Single:
		p.fill_rect(c, {x0, base, f32(r.cell_w), thick}, col)
	case .Double:
		p.fill_rect(c, {x0, base, f32(r.cell_w), thick}, col)
		p.fill_rect(c, {x0, base + thick * 2, f32(r.cell_w), thick}, col)
	case .Dotted:
		for k := 0; k < r.cell_w; k += 2 {
			p.fill_rect(c, {x0 + f32(k), base, 1, thick}, col)
		}
	case .Dashed:
		p.fill_rect(c, {x0, base, f32(r.cell_w) * 0.6, thick}, col)
	case .Curly:
		// A sine, sampled per pixel column. It is what a spell checker's
		// squiggle looks like and what `ESC[4:3m` asks for.
		amp := max(1, f32(r.cell_h) * 0.06)
		for k in 0 ..< r.cell_w {
			phase := f32(k) / f32(r.cell_w) * math.TAU
			dy := math.sin(phase) * amp
			p.fill_rect(c, {x0 + f32(k), base + dy, 1, thick}, col)
		}
	}
}

@(private = "file")
cell_or_blank :: proc(row: vt.Row, i: int) -> vt.Cell {
	if i < len(row.cells) {
		return row.cells[i]
	}
	return vt.Cell{ch = ' '}
}

@(private = "file")
cell_fg :: proc(t: ^vt.Terminal, c: vt.Cell, selected: bool) -> vt.Rgb {
	fg := vt.terminal_resolve(t, c.fg, true, c.attrs)
	bg := vt.terminal_resolve(t, c.bg, false, c.attrs)
	if .Inverse in c.attrs != t.modes.reverse_video {
		fg = bg
	}
	if selected {
		return vt.terminal_bg(t)
	}
	return fg
}

@(private = "file")
cell_bg :: proc(t: ^vt.Terminal, c: vt.Cell, selected: bool) -> vt.Rgb {
	fg := vt.terminal_resolve(t, c.fg, true, c.attrs)
	bg := vt.terminal_resolve(t, c.bg, false, c.attrs)
	if .Inverse in c.attrs != t.modes.reverse_video {
		bg = fg
	}
	if selected {
		return {0x7D, 0xD3, 0xFC}
	}
	return bg
}

@(private = "file")
draw_cursor :: proc(r: ^Grid_Renderer, c: ^p.Canvas, t: ^vt.Terminal, x, y: int, focused: bool) {
	if x < 0 || y < 0 || x >= r.cols || y >= r.rows {
		return
	}
	col := to_color(t.default_cursor)
	rx := f32(x * r.cell_w)
	ry := f32(y * r.cell_h)
	if !focused {
		// An unfocused terminal shows a hollow box, which is how you tell at
		// a glance which of four tiled windows will get your keystrokes.
		p.stroke_round_rect(c, {rx, ry, f32(r.cell_w), f32(r.cell_h)}, {}, 1, col)
		return
	}
	p.fill_rect(c, {rx, ry, f32(r.cell_w), f32(r.cell_h)}, col)
	// Redraw the character in the background colour so it stays legible.
	s := vt.screen(t)
	row := vt.screen_row(s, vt.screen_total_rows(s) - r.rows + y)
	if row == nil {
		return
	}
	cell := cell_or_blank(row^, x)
	if cell.ch == 0 || cell.ch == ' ' {
		return
	}
	buf: [8]u8
	n := vt.utf8_encode(buf[:], cell.ch)
	p.draw_text(
		c,
		r.fonts,
		string(buf[:n]),
		rx,
		ry + f32(r.baseline),
		r.size * r.scale,
		to_color(vt.terminal_bg(t)),
		.Mono,
	)
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

// sel_press starts a selection at a cell. It is not active yet: a click
// that never leaves its cell selects nothing, where it used to leave a
// one-cell selection behind -- highlighted, and copied by the next Ctrl+Shift+C.
// What it does do is clear whatever was selected before.
sel_press :: proc(col, row: int) -> Selection {
	return Selection{dragging = true, a = {col, row}, b = {col, row}}
}

// sel_drag follows the pointer during a drag and reports whether anything
// changed. The selection becomes active the first time the pointer reaches
// another cell, and stays active if it comes back to the first one, which
// then selects that cell -- a deliberate one-cell selection.
sel_drag :: proc(s: ^Selection, col, row: int) -> bool {
	if !s.dragging {
		return false
	}
	nb := [2]int{col, row}
	if s.b == nb {
		return false
	}
	s.b = nb
	s.active = true
	return true
}

sel_normalized :: proc(s: Selection) -> (a, b: [2]int) {
	a, b = s.a, s.b
	if a[1] > b[1] || (a[1] == b[1] && a[0] > b[0]) {
		a, b = b, a
	}
	return
}

sel_contains :: proc(s: Selection, row, col: int) -> bool {
	if !s.active {
		return false
	}
	a, b := sel_normalized(s)
	if row < a[1] || row > b[1] {
		return false
	}
	if s.block {
		lo := min(a[0], b[0])
		hi := max(a[0], b[0])
		return col >= lo && col <= hi
	}
	if row == a[1] && col < a[0] {
		return false
	}
	if row == b[1] && col > b[0] {
		return false
	}
	return true
}

// blit copies the pixel cache into the window at `dst`.
// With `dim`, every pixel is pulled a third of the way towards the
// background, which is how an unfocused pane is drawn.
renderer_blit :: proc(r: ^Grid_Renderer, c: ^p.Canvas, dst: p.Rect, dim := false) {
	if r.px == nil {
		return
	}
	x0 := int(dst.x)
	y0 := int(dst.y)
	BG :: u32(0x0B1120)
	for y in 0 ..< r.h {
		dy := y0 + y
		if dy < 0 || dy >= c.h {
			continue
		}
		src := r.px[y * r.w:][:r.w]
		for x in 0 ..< r.w {
			dx := x0 + x
			if dx < 0 || dx >= c.w {
				continue
			}
			v := src[x]
			if dim {
				rr := ((v >> 16 & 0xFF) * 2 + (BG >> 16 & 0xFF)) / 3
				gg := ((v >> 8 & 0xFF) * 2 + (BG >> 8 & 0xFF)) / 3
				bb := ((v & 0xFF) * 2 + (BG & 0xFF)) / 3
				v = 0xFF00_0000 | rr << 16 | gg << 8 | bb
			}
			c.px[dy * c.w + dx] = v
		}
	}
}

// draw_frags paints the images on one text row into the pixel cache, scaled
// from the cell size they were placed at to the one in use now, nearest
// neighbour, with straight alpha blended over whatever is already there.
@(private = "file")
draw_frags :: proc(r: ^Grid_Renderer, row: vt.Row, y: int, below: bool) {
	for f in row.frags {
		pl := f.pl
		if (pl.z < 0) != below || pl.img == nil || pl.img.px == nil {
			continue
		}
		img := pl.img
		fx := f32(r.cell_w) / f32(max(pl.cw, 1))
		fy := f32(r.cell_h) / f32(max(pl.ch, 1))
		left := int(f.col) * r.cell_w
		cx0 := max(int(f.col + f.from) * r.cell_w, 0)
		cx1 := min(int(f.col + f.to) * r.cell_w, r.w)
		top := y * r.cell_h
		for dy in 0 ..< r.cell_h {
			if top + dy >= r.h {
				break
			}
			py := (f32(int(f.row) * r.cell_h + dy) + 0.5) / fy - f32(pl.oy)
			if py < 0 || py >= f32(pl.dh) {
				continue
			}
			sy := pl.sy + min(int(py * f32(pl.sh) / f32(pl.dh)), pl.sh - 1)
			src := img.px[sy * img.w:][:img.w]
			dst := r.px[(top + dy) * r.w:][:r.w]
			for dx in cx0 ..< cx1 {
				px := (f32(dx - left) + 0.5) / fx - f32(pl.ox)
				if px < 0 || px >= f32(pl.dw) {
					continue
				}
				sx := pl.sx + min(int(px * f32(pl.sw) / f32(pl.dw)), pl.sw - 1)
				v := src[sx]
				a := v >> 24
				switch a {
				case 0:
				case 255:
					dst[dx] = v
				case:
					d := dst[dx]
					ia := 255 - a
					rr := ((v >> 16 & 0xFF) * a + (d >> 16 & 0xFF) * ia) / 255
					gg := ((v >> 8 & 0xFF) * a + (d >> 8 & 0xFF) * ia) / 255
					bb := ((v & 0xFF) * a + (d & 0xFF) * ia) / 255
					dst[dx] = 0xFF00_0000 | rr << 16 | gg << 8 | bb
				}
			}
		}
	}
}
