// Charts: the model, the reading of a cell range into series, and the drawing.
//
// A chart is a view of a rectangle of cells, not a copy of it. Nothing is
// cached: `chart_read` walks the range every time the chart is drawn, so a
// chart is never stale — the values it reads are the ones recalculation just
// settled on, because drawing happens after recalculation in the frame.
//
// The range is read the way a person would read it: if the first column is
// not numbers it holds the category labels, and if the first row is not
// numbers it holds the series names. Everything else is data.
package main

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."

Chart_Kind :: enum u8 {
	Bar,
	Line,
	Pie,
}

chart_kind_name :: proc(k: Chart_Kind) -> string {
	switch k {
	case .Bar:
		return "Bar"
	case .Line:
		return "Line"
	case .Pie:
		return "Pie"
	}
	return "Bar"
}

Chart :: struct {
	kind:  Chart_Kind,
	title: string, // owned
	sheet: string, // owned; the sheet the data lives on, "" = the chart's own
	rect:  Rect_I, // the data range
	at:    Addr, // the grid cell the chart's top-left corner sits on
	w:     int, // width in columns
	h:     int, // height in rows
	// Data labels: each bar, point or slice carries its value, formatted as
	// the cell it came from is. Excel's `<c:showVal>`.
	labels: bool,
}

CHART_DEF_W :: 6
CHART_DEF_H :: 12

// A chart is sized in whole cells — its frame is anchored to two cells, which
// is also how .xlsx anchors it — so these are columns and rows. The limits
// are the ones the loaders already clamped to.
CHART_MIN_W :: 2
CHART_MIN_H :: 3
CHART_MAX_W :: 60
CHART_MAX_H :: 120
MAX_CHART_SERIES :: 8
MAX_CHART_POINTS :: 64

chart_release :: proc(ch: Chart, allocator := context.allocator) {
	if ch.title != "" {
		delete(ch.title, allocator)
	}
	if ch.sheet != "" {
		delete(ch.sheet, allocator)
	}
}

// chart_data_sheet is the sheet a chart reads from, which is not necessarily
// the sheet it is drawn on.
chart_data_sheet :: proc(sh: ^Sheet, ch: Chart) -> ^Sheet {
	if ch.sheet == "" {
		return sh
	}
	if s := book_sheet(sh.book, book_find(sh.book, ch.sheet)); s != nil {
		return s
	}
	return sh
}

Series :: struct {
	name: string,
	vals: [dynamic]f64,
	have: [dynamic]bool,
	fmt:  Cell_Fmt, // the format of the series' first number, for its labels
}

Chart_Data :: struct {
	cats:    [dynamic]string,
	series:  [dynamic]Series,
	lo, hi:  f64,
	any:     bool,
	has_cat: bool, // the first column was labels
	has_hdr: bool, // the first row was series names
	// The resolved geometry, so the .xlsx writer can name the very cells the
	// drawing came from rather than guess at them again.
	rect:    Rect_I, // the range, clamped to what exists
	row0:    int, // the first data row
	col0:    int, // the first data column
	nrows:   int,
	ncols:   int,
}

@(private = "file")
is_numeric :: proc(sh: ^Sheet, a: Addr) -> bool {
	return value_at(sh, a).kind == .Number
}

// chart_read turns the range into categories and series. It allocates into
// the temp allocator: a chart is read once per frame and thrown away.
chart_read :: proc(sh: ^Sheet, ch: Chart) -> (d: Chart_Data) {
	ds := chart_data_sheet(sh, ch)
	r := ch.rect
	r.r1 = min(r.r1, max(ds.max_row, r.r0))
	r.c1 = min(r.c1, max(ds.max_col, r.c0))
	d.cats = make([dynamic]string, 0, 16, context.temp_allocator)
	d.series = make([dynamic]Series, 0, 4, context.temp_allocator)
	d.rect = r
	if r.r0 > r.r1 || r.c0 > r.c1 {
		return
	}

	// A header row, if the row below it is numeric where this one is not.
	d.has_hdr = false
	if r.r1 > r.r0 {
		text_count, num_count := 0, 0
		for col in r.c0 ..= r.c1 {
			v := value_at(ds, {r.r0, col})
			if v.kind == .Text {
				text_count += 1
			} else if v.kind == .Number {
				num_count += 1
			}
		}
		d.has_hdr = text_count > num_count
	}
	// A label column, if its cells are not numbers.
	d.has_cat = false
	if r.c1 > r.c0 {
		first_data_row := d.has_hdr ? r.r0 + 1 : r.r0
		if first_data_row <= r.r1 {
			text_count, num_count := 0, 0
			for row in first_data_row ..= r.r1 {
				v := value_at(ds, {row, r.c0})
				if v.kind == .Text {
					text_count += 1
				} else if v.kind == .Number {
					num_count += 1
				}
			}
			d.has_cat = text_count > num_count
		}
	}

	row0 := d.has_hdr ? r.r0 + 1 : r.r0
	col0 := d.has_cat ? r.c0 + 1 : r.c0
	if row0 > r.r1 || col0 > r.c1 {
		return
	}
	nrows := min(r.r1 - row0 + 1, MAX_CHART_POINTS)
	ncols := min(r.c1 - col0 + 1, MAX_CHART_SERIES)
	d.rect = r
	d.row0, d.col0, d.nrows, d.ncols = row0, col0, nrows, ncols

	for i in 0 ..< nrows {
		row := row0 + i
		if d.has_cat {
			append(&d.cats, display_at(ds, {row, r.c0}))
		} else {
			append(&d.cats, int_text(row + 1))
		}
	}
	for j in 0 ..< ncols {
		col := col0 + j
		name := d.has_hdr ? display_at(ds, {r.r0, col}) : col_name(col)
		se := Series {
			name = name,
			vals = make([dynamic]f64, 0, nrows, context.temp_allocator),
			have = make([dynamic]bool, 0, nrows, context.temp_allocator),
		}
		got_fmt := false
		for i in 0 ..< nrows {
			v := value_at(ds, {row0 + i, col})
			if v.kind == .Number {
				if !got_fmt {
					se.fmt, got_fmt = fmt_at(ds, {row0 + i, col}), true
				}
				append(&se.vals, v.num)
				append(&se.have, true)
				if !d.any {
					d.lo, d.hi, d.any = v.num, v.num, true
				} else {
					d.lo = min(d.lo, v.num)
					d.hi = max(d.hi, v.num)
				}
			} else {
				append(&se.vals, 0)
				append(&se.have, false)
			}
		}
		append(&d.series, se)
	}
	// A bar or line chart's value axis always includes zero, which is the
	// only honest way to draw a bar.
	if d.any && ch.kind != .Pie {
		d.lo = min(d.lo, 0)
		d.hi = max(d.hi, 0)
		if d.hi == d.lo {
			d.hi = d.lo + 1
		}
		// A label sits above the tallest bar (below the deepest negative
		// one), so leave it a little headroom inside the axis rather than
		// let it collide with the title.
		if ch.labels {
			pad := (d.hi - d.lo) * 0.1
			if d.hi > 0 {
				d.hi += pad
			}
			if d.lo < 0 {
				d.lo -= pad
			}
		}
	}
	return
}

// label_text is a data label: the value as its cell would show it.
label_text :: proc(se: Series, v: f64) -> string {
	return format_value(vnum(v), se.fmt)
}

// ---------------------------------------------------------------------------
// Drawing
//
// Straight into `p.pixels`, like the grid: a chart is one more thing painted
// over the cells, clipped to the grid body.
// ---------------------------------------------------------------------------

CHART_PAD :: f32(10)
CHART_AXIS_W :: f32(42)
CHART_AXIS_H :: f32(18)
CHART_LEGEND_H :: f32(16)
CHART_TITLE_H :: f32(18)

// The series palette, used both on screen and in the .xlsx. It is written
// into the chart part as explicit sRGB rather than left to the theme: a
// package with no theme part gets no theme colours, and a bar with no fill is
// an invisible bar — a chart that is structurally perfect and shows nothing.
SERIES_HEX := [?]u32 {
	0x2563eb,
	0xf97316,
	0x16a34a,
	0xdc2626,
	0x9333ea,
	0x0891b2,
	0xca8a04,
	0xdb2777,
}

series_color :: proc(pal: Palette, i, n: int) -> p.Color {
	return p.hex(SERIES_HEX[i %% len(SERIES_HEX)])
}

series_hex :: proc(i: int) -> string {
	return fmt.tprintf("%06X", SERIES_HEX[i %% len(SERIES_HEX)])
}

draw_chart :: proc(c: ^p.Canvas, app: ^App, ch: Chart, box: p.Rect) {
	s := c.scale
	pal := app.pal
	sh := app.sh
	d := chart_read(sh, ch)

	// The frame.
	p.fill_rect(c, box, pal.bg)
	p.stroke_round_rect(c, box, {6 * s, 6 * s, 6 * s, 6 * s}, max(1, s), pal.border)

	pad := CHART_PAD * s
	inner := p.Rect{box.x + pad, box.y + pad, max(box.w - 2 * pad, 1), max(box.h - 2 * pad, 1)}

	tsize := 11.5 * s
	if ch.title != "" {
		m := p.font_metrics(app.fonts, tsize, .Sans, .Bold)
		p.draw_text(
			c,
			app.fonts,
			ch.title,
			inner.x,
			inner.y + m.ascent,
			tsize,
			pal.fg,
			.Sans,
			.Bold,
		)
		inner.y += CHART_TITLE_H * s
		inner.h = max(inner.h - CHART_TITLE_H * s, 1)
	}

	if !d.any || len(d.series) == 0 {
		msize := 11 * s
		msg := "no numbers in the chart range"
		tw := p.text_width(app.fonts, msg, msize, .Sans, .Regular)
		p.draw_text(
			c,
			app.fonts,
			msg,
			inner.x + max(inner.w - tw, 0) / 2,
			inner.y + inner.h / 2,
			msize,
			pal.muted_fg,
		)
		return
	}

	// A legend, when more than one series is plotted.
	legend_h := f32(0)
	if len(d.series) > 1 || ch.kind == .Pie {
		legend_h = CHART_LEGEND_H * s
	}
	plot := p.Rect{inner.x, inner.y, inner.w, max(inner.h - legend_h, 1)}

	switch ch.kind {
	case .Bar:
		draw_chart_bars(c, app, d, plot, ch.labels)
	case .Line:
		draw_chart_lines(c, app, d, plot, ch.labels)
	case .Pie:
		draw_chart_pie(c, app, d, plot, ch.labels)
	}

	if legend_h > 0 {
		lsize := 9.5 * s
		m := p.font_metrics(app.fonts, lsize, .Sans, .Regular)
		y := p.rect_bottom(inner) - legend_h + (legend_h - (m.ascent + m.descent)) / 2 + m.ascent
		x := inner.x
		// A pie chart's legend names the slices; every other chart's names
		// the series.
		n := ch.kind == .Pie ? len(d.cats) : len(d.series)
		for i in 0 ..< n {
			label := ch.kind == .Pie ? d.cats[i] : d.series[i].name
			if label == "" {
				continue
			}
			sw := 7 * s
			tw := p.text_width(app.fonts, label, lsize, .Sans, .Regular)
			if x + sw + 4 * s + tw > p.rect_right(inner) {
				break
			}
			p.fill_rect(c, {x, y - m.ascent * 0.75, sw, sw}, series_color(pal, i, n))
			p.draw_text(c, app.fonts, label, x + sw + 4 * s, y, lsize, pal.muted_fg)
			x += sw + 4 * s + tw + 10 * s
		}
	}
}

// axis_ticks picks a round step for the value axis, the way a chart tool does:
// 1, 2 or 5 times a power of ten, so the labels read as numbers a person
// would write.
axis_ticks :: proc(lo, hi: f64) -> (start, step: f64, n: int) {
	span := hi - lo
	if span <= 0 {
		return lo, 1, 2
	}
	// Five intervals is the target: four is coarse enough that a 0..203 axis
	// would step by 100 and waste half its height.
	raw := span / 5
	mag := math.pow(10, math.floor(math.log10(raw)))
	norm := raw / mag
	unit := 1.0
	switch {
	case norm <= 1:
		unit = 1
	case norm <= 2:
		unit = 2
	case norm <= 5:
		unit = 5
	case:
		unit = 10
	}
	step = unit * mag
	start = math.floor(lo / step) * step
	n = int(math.ceil((hi - start) / step)) + 1
	return start, step, min(max(n, 2), 12)
}

@(private = "file")
plot_frame :: proc(
	c: ^p.Canvas,
	app: ^App,
	d: Chart_Data,
	box: p.Rect,
) -> (
	plot: p.Rect,
	y0: f64,
	y1: f64,
) {
	s := c.scale
	pal := app.pal
	start, step, n := axis_ticks(d.lo, d.hi)
	y0 = start
	y1 = start + step * f64(n - 1)
	if y1 <= y0 {
		y1 = y0 + 1
	}
	plot = p.Rect {
		box.x + CHART_AXIS_W * s,
		box.y,
		max(box.w - CHART_AXIS_W * s, 1),
		max(box.h - CHART_AXIS_H * s, 1),
	}

	// Gridlines and the value labels beside them.
	lsize := 9.5 * s
	m := p.font_metrics(app.fonts, lsize, .Sans, .Regular)
	line := max(1, s * 0.75)
	for i in 0 ..< n {
		v := start + step * f64(i)
		t := f32((v - y0) / (y1 - y0))
		y := p.rect_bottom(plot) - t * plot.h
		p.fill_rect(c, {plot.x, y, plot.w, line}, i == 0 ? pal.border : pal.grid)
		lab := general_text(round_sig(v, 10))
		tw := p.text_width(app.fonts, lab, lsize, .Sans, .Regular)
		p.draw_text(
			c,
			app.fonts,
			lab,
			plot.x - 5 * s - tw,
			y + (m.ascent - m.descent) / 2,
			lsize,
			pal.muted_fg,
		)
	}
	p.fill_rect(c, {plot.x, plot.y, line, plot.h}, pal.border)
	return
}

@(private = "file")
draw_cat_labels :: proc(c: ^p.Canvas, app: ^App, d: Chart_Data, plot: p.Rect, slot: f32) {
	s := c.scale
	lsize := 9.5 * s
	m := p.font_metrics(app.fonts, lsize, .Sans, .Regular)
	y := p.rect_bottom(plot) + (CHART_AXIS_H * s - (m.ascent + m.descent)) / 2 + m.ascent
	// Thin the labels out rather than overlap them.
	every := 1
	for every < len(d.cats) {
		if slot * f32(every) >= 28 * s {
			break
		}
		every += 1
	}
	for i in 0 ..< len(d.cats) {
		if i % every != 0 {
			continue
		}
		lab := d.cats[i]
		if lab == "" {
			continue
		}
		tw := p.text_width(app.fonts, lab, lsize, .Sans, .Regular)
		cx := plot.x + slot * (f32(i) + 0.5)
		if tw > slot * f32(every) {
			continue
		}
		p.draw_text(c, app.fonts, lab, cx - tw / 2, y, lsize, app.pal.muted_fg)
	}
}

// Data labels are drawn after every bar, line or slice, so no series paints
// over another's numbers. A label that would not fit — wider than its bar,
// crowding the previous point of its line, on a slice too thin to hold it —
// is left out rather than drawn over its neighbour; Excel draws them anyway
// and the result is a smear.
CHART_LABEL_SIZE :: f32(9)

draw_chart_bars :: proc(c: ^p.Canvas, app: ^App, d: Chart_Data, box: p.Rect, labels := false) {
	s := c.scale
	plot, y0, y1 := plot_frame(c, app, d, box)
	np := len(d.cats)
	ns := len(d.series)
	if np == 0 || ns == 0 {
		return
	}
	slot := plot.w / f32(np)
	gap := min(slot * 0.18, 6 * s)
	bw := max((slot - gap) / f32(ns), 1)
	zero := p.rect_bottom(plot) - f32((0 - y0) / (y1 - y0)) * plot.h

	for j in 0 ..< ns {
		col := series_color(app.pal, j, ns)
		for i in 0 ..< np {
			if !d.series[j].have[i] {
				continue
			}
			v := d.series[j].vals[i]
			y := p.rect_bottom(plot) - f32((v - y0) / (y1 - y0)) * plot.h
			x := plot.x + slot * f32(i) + gap / 2 + bw * f32(j)
			top := min(y, zero)
			hgt := max(abs(y - zero), max(1, s))
			p.fill_rect(c, {x, top, max(bw - max(1, s * 0.5), 1), hgt}, col)
		}
	}
	if labels {
		lsize := CHART_LABEL_SIZE * s
		m := p.font_metrics(app.fonts, lsize, .Sans, .Medium)
		for j in 0 ..< ns {
			for i in 0 ..< np {
				if !d.series[j].have[i] {
					continue
				}
				v := d.series[j].vals[i]
				lab := label_text(d.series[j], v)
				tw := p.text_width(app.fonts, lab, lsize, .Sans, .Medium)
				if tw > bw + gap * 0.9 {
					continue
				}
				y := p.rect_bottom(plot) - f32((v - y0) / (y1 - y0)) * plot.h
				cx := plot.x + slot * f32(i) + gap / 2 + bw * f32(j) + bw / 2
				// Above a positive bar, below a negative one.
				base := v >= 0 ? y - 3 * s - m.descent : y + 3 * s + m.ascent
				p.draw_text(c, app.fonts, lab, cx - tw / 2, base, lsize, app.pal.fg, .Sans, .Medium)
			}
		}
	}
	draw_cat_labels(c, app, d, plot, slot)
}

draw_chart_lines :: proc(c: ^p.Canvas, app: ^App, d: Chart_Data, box: p.Rect, labels := false) {
	s := c.scale
	plot, y0, y1 := plot_frame(c, app, d, box)
	np := len(d.cats)
	ns := len(d.series)
	if np == 0 || ns == 0 {
		return
	}
	slot := plot.w / f32(np)
	for j in 0 ..< ns {
		col := series_color(app.pal, j, ns)
		prev_x, prev_y := f32(0), f32(0)
		have_prev := false
		for i in 0 ..< np {
			if !d.series[j].have[i] {
				have_prev = false
				continue
			}
			v := d.series[j].vals[i]
			x := plot.x + slot * (f32(i) + 0.5)
			y := p.rect_bottom(plot) - f32((v - y0) / (y1 - y0)) * plot.h
			if have_prev {
				draw_thick_line(c, prev_x, prev_y, x, y, max(1.6 * s, 1), col)
			}
			// A marker, so a single point is still visible.
			r := max(2 * s, 1.5)
			p.fill_rect(c, {x - r, y - r, 2 * r, 2 * r}, col)
			prev_x, prev_y, have_prev = x, y, true
		}
	}
	if labels {
		lsize := CHART_LABEL_SIZE * s
		m := p.font_metrics(app.fonts, lsize, .Sans, .Medium)
		for j in 0 ..< ns {
			col := series_color(app.pal, j, ns)
			last_right := f32(-1e9)
			for i in 0 ..< np {
				if !d.series[j].have[i] {
					continue
				}
				v := d.series[j].vals[i]
				lab := label_text(d.series[j], v)
				tw := p.text_width(app.fonts, lab, lsize, .Sans, .Medium)
				x := plot.x + slot * (f32(i) + 0.5)
				y := p.rect_bottom(plot) - f32((v - y0) / (y1 - y0)) * plot.h
				lx := x - tw / 2
				if lx < last_right + 3 * s {
					continue // it would run into the previous one
				}
				// In the series' colour, so two lines' labels stay apart.
				p.draw_text(c, app.fonts, lab, lx, y - 5 * s - m.descent, lsize, col, .Sans, .Medium)
				last_right = lx + tw
			}
		}
	}
	draw_cat_labels(c, app, d, plot, slot)
}

// draw_thick_line walks the long axis one pixel at a time. palmy rasterises
// rectangles, not strokes, so a line is a run of short ones — which is
// exactly how a software rasterizer would draw it anyway.
draw_thick_line :: proc(c: ^p.Canvas, x0, y0, x1, y1, w: f32, col: p.Color) {
	dx := x1 - x0
	dy := y1 - y0
	steps := int(max(abs(dx), abs(dy))) + 1
	if steps <= 1 {
		p.fill_rect(c, {x0 - w / 2, y0 - w / 2, w, w}, col)
		return
	}
	for i in 0 ..= steps {
		t := f32(i) / f32(steps)
		p.fill_rect(c, {x0 + dx * t - w / 2, y0 + dy * t - w / 2, w, w}, col)
	}
}

// draw_chart_pie paints the slices by scanning the bounding box once and
// asking, for each pixel, which slice its angle falls in. At the size a chart
// is drawn that is a few thousand tests, and it gives a clean edge without a
// polygon rasteriser.
draw_chart_pie :: proc(c: ^p.Canvas, app: ^App, d: Chart_Data, box: p.Rect, labels := false) {
	s := c.scale
	if len(d.series) == 0 {
		return
	}
	se := d.series[0] // a pie plots one series
	total := 0.0
	for v, i in se.vals {
		if se.have[i] && v > 0 {
			total += v
		}
	}
	if total <= 0 {
		return
	}
	cx := box.x + box.w / 2
	cy := box.y + box.h / 2
	rad := max(min(box.w, box.h) / 2 - 4 * s, 2)

	// Slice boundaries as fractions of a turn, starting at twelve o'clock and
	// going clockwise, which is what every pie chart does.
	n := len(se.vals)
	ends := make([]f32, n, context.temp_allocator)
	acc := 0.0
	for i in 0 ..< n {
		if se.have[i] && se.vals[i] > 0 {
			acc += se.vals[i]
		}
		ends[i] = f32(acc / total)
	}

	x0 := int(math.floor(cx - rad))
	x1 := int(math.ceil(cx + rad))
	y0 := int(math.floor(cy - rad))
	y1 := int(math.ceil(cy + rad))
	for py in y0 ..= y1 {
		for px in x0 ..= x1 {
			fx := f32(px) + 0.5 - cx
			fy := f32(py) + 0.5 - cy
			if fx * fx + fy * fy > rad * rad {
				continue
			}
			// atan2 measured from twelve o'clock, clockwise, in turns.
			ang := math.atan2(fx, -fy) / (2 * math.PI)
			if ang < 0 {
				ang += 1
			}
			idx := 0
			for idx < n - 1 && ang > ends[idx] {
				idx += 1
			}
			p.fill_rect(c, {f32(px), f32(py), 1, 1}, series_color(app.pal, idx, n))
		}
	}
	if labels {
		// Inside each slice, two thirds of the way out along its middle,
		// in white: the slice colours are all dark enough to carry it.
		lsize := CHART_LABEL_SIZE * s
		m := p.font_metrics(app.fonts, lsize, .Sans, .Bold)
		start := f32(0)
		for i in 0 ..< n {
			frac := ends[i] - start
			mid := (start + ends[i]) / 2
			start = ends[i]
			if !se.have[i] || se.vals[i] <= 0 {
				continue
			}
			lab := label_text(se, se.vals[i])
			tw := p.text_width(app.fonts, lab, lsize, .Sans, .Bold)
			// The arc at that radius has to be wider than the text.
			arc := frac * 2 * math.PI * rad * 0.62
			if arc < tw * 0.9 {
				continue
			}
			a := mid * 2 * math.PI
			lx := cx + math.sin(a) * rad * 0.62
			ly := cy - math.cos(a) * rad * 0.62
			p.draw_text(c, app.fonts, lab, lx - tw / 2, ly + (m.ascent - m.descent) / 2, lsize, p.hex(0xffffff), .Sans, .Bold)
		}
	}
}

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------

// chart_box is where a chart lands in the grid, in device pixels, given the
// scroll position. It returns `ok = false` when the chart is scrolled out of
// sight entirely.
chart_box :: proc(app: ^App, ch: Chart, geom: ^Grid_Geom) -> (p.Rect, bool) {
	x0, okx := geom_col_x(geom, ch.at.col)
	y0, oky := geom_row_y(geom, ch.at.row)
	if !okx || !oky {
		return {}, false
	}
	w := f32(0)
	for i in 0 ..< max(ch.w, 1) {
		w += col_width(app.sh, ch.at.col + i) * geom.scale
	}
	h := f32(0)
	for i in 0 ..< max(ch.h, 1) {
		h += row_height(app.sh, ch.at.row + i) * geom.scale
	}
	return {x0, y0, w, h}, true
}

chart_summary :: proc(sh: ^Sheet, ch: Chart) -> string {
	return fmt.tprintf(
		"%s chart of %s%s:%s",
		chart_kind_name(ch.kind),
		sheet_prefix(ch.sheet),
		addr_name({ch.rect.r0, ch.rect.c0}),
		addr_name({ch.rect.r1, ch.rect.c1}),
	)
}

_ :: strings

// ---------------------------------------------------------------------------
// Inserting and removing
// ---------------------------------------------------------------------------

// insert_chart places a chart over the cells to the right of its data, which
// is where a person dragging one would put it, and leaves the cursor where it
// was so the data stays selected.
insert_chart :: proc(app: ^App, kind: Chart_Kind, sel_in: Rect_I) {
	sh := app.sh
	rect := sel_in
	if rect.r0 == rect.r1 && rect.c0 == rect.c1 {
		// One cell selected means "the sheet", the same convention the CSV
		// export uses.
		if sh.max_row < 0 {
			set_status(app, "Nothing to chart")
			return
		}
		rect = {0, 0, sh.max_row, sh.max_col}
	}
	rect.r1 = min(rect.r1, max(sh.max_row, rect.r0))
	rect.c1 = min(rect.c1, max(sh.max_col, rect.c0))

	undo_push(app)
	at := Addr{rect.r0, min(rect.c1 + 2, MAX_COLS - CHART_DEF_W - 1)}
	// Slide down past anything already drawn there, so a second chart on the
	// same data is readable instead of hidden under the first.
	for _ in 0 ..< 32 {
		clash := false
		for ch in sh.charts {
			if rects_overlap(
				{ch.at.row, ch.at.col, ch.at.row + max(ch.h, 1) - 1, ch.at.col + max(ch.w, 1) - 1},
				{at.row, at.col, at.row + CHART_DEF_H - 1, at.col + CHART_DEF_W - 1},
			) {
				at.row = ch.at.row + max(ch.h, 1) + 1
				clash = true
				break
			}
		}
		if !clash {
			break
		}
	}
	title := ""
	// A header row makes an obvious title: the name of the first series.
	if rect.c1 > rect.c0 && value_at(sh, {rect.r0, rect.c0 + 1}).kind == .Text {
		title = display_at(sh, {rect.r0, rect.c0 + 1})
	}
	append(
		&sh.charts,
		Chart {
			kind = kind,
			title = strings.clone(title, sh.heap),
			sheet = strings.clone("", sh.heap),
			rect = rect,
			at = at,
			w = CHART_DEF_W,
			h = CHART_DEF_H,
		},
	)
	set_status(
		app,
		"%s chart of %s at %s",
		chart_kind_name(kind),
		rect_text(rect),
		addr_name(at),
	)
}

chart_covers :: proc(ch: Chart, a: Addr) -> bool {
	return rect_contains(
		Rect_I {
			ch.at.row,
			ch.at.col,
			ch.at.row + max(ch.h, 1) - 1,
			ch.at.col + max(ch.w, 1) - 1,
		},
		a,
	)
}

delete_chart_at :: proc(sh: ^Sheet, a: Addr) -> bool {
	for i := len(sh.charts) - 1; i >= 0; i -= 1 {
		if chart_covers(sh.charts[i], a) {
			chart_release(sh.charts[i], sh.heap)
			ordered_remove(&sh.charts, i)
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Resizing and labelling
//
// The window reaches a chart by putting the cursor on a cell it covers — the
// same convention Delete-the-chart-here already used, because this program
// is driven from the keyboard and a pointer cannot be synthesised on its
// compositor. `sheets chart-set` reaches it by naming such a cell. Both then
// call the two procedures below, so there is one rule for what a size is.
// ---------------------------------------------------------------------------

// chart_at is the chart covering `a` — the topmost, i.e. the last drawn,
// when they overlap — or -1.
chart_at :: proc(sh: ^Sheet, a: Addr) -> int {
	for i := len(sh.charts) - 1; i >= 0; i -= 1 {
		if chart_covers(sh.charts[i], a) {
			return i
		}
	}
	return -1
}

// chart_resize sets a chart's size in columns and rows, clamped to what a
// chart can be, and reports whether anything changed. The top-left corner
// stays where it is, which is what dragging the bottom-right handle does.
chart_resize :: proc(sh: ^Sheet, i: int, w, h: int) -> bool {
	if i < 0 || i >= len(sh.charts) {
		return false
	}
	ch := &sh.charts[i]
	nw := clamp(w, CHART_MIN_W, min(CHART_MAX_W, MAX_COLS - ch.at.col))
	nh := clamp(h, CHART_MIN_H, min(CHART_MAX_H, MAX_ROWS - ch.at.row))
	if nw == ch.w && nh == ch.h {
		return false
	}
	ch.w, ch.h = nw, nh
	return true
}

chart_set_labels :: proc(sh: ^Sheet, i: int, on: bool) -> bool {
	if i < 0 || i >= len(sh.charts) || sh.charts[i].labels == on {
		return false
	}
	sh.charts[i].labels = on
	return true
}

// parse_chart_size reads `8x14`, `8 x 14` or `8,14`: columns, then rows.
parse_chart_size :: proc(s: string) -> (w, h: int, ok: bool) {
	t := strings.to_lower(strings.trim_space(s), context.temp_allocator)
	sep := -1
	for i in 0 ..< len(t) {
		if t[i] == 'x' || t[i] == ',' || t[i] == '*' || t[i] == ' ' {
			sep = i
			break
		}
	}
	if sep < 0 {
		return 0, 0, false
	}
	a, aok := parse_small_int(strings.trim_space(t[:sep]))
	b, bok := parse_small_int(strings.trim(t[sep + 1:], " x,*"))
	return a, b, aok && bok
}

@(private = "file")
parse_small_int :: proc(s: string) -> (int, bool) {
	if s == "" || len(s) > 6 {
		return 0, false
	}
	n := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(s[i] - '0')
	}
	return n, true
}

// chart_size_text is the status-bar and CLI spelling of a size.
chart_size_text :: proc(ch: Chart) -> string {
	return fmt.tprintf("%dx%d", ch.w, ch.h)
}
