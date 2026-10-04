// The charts, drawn into `p.pixels`.
//
// Two of them, because they answer the two questions a person actually has.
// "Where did it go" is a bar chart of spend by category, horizontal so the
// category names are readable at any length. "Am I going under" is the
// account balance over time, with a zero line that is drawn whenever zero is
// inside the range, because a balance chart whose axis starts at the minimum
// value hides the one thing it is for.
//
// A chart can be structurally correct and still unreadable, so the work here
// is mostly in the axes: a *nice* tick step rather than range/5, labels in
// French money formatting, a baseline, and gridlines light enough to read
// across without competing with the data. Both are drawn from the same
// integer centime values the ledger holds — nothing is converted to a float
// until it becomes a pixel coordinate.
package main

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."

// A palette with enough separation that neighbouring bars are tellable apart
// in both themes, cycled by category index.
CATEGORY_TINTS := [?]u32 {
	0x6366f1, // indigo
	0x10b981, // emerald
	0xf59e0b, // amber
	0xca8a04, // ochre — red is deliberately absent, it is reserved for "over budget"
	0x06b6d4, // cyan
	0xa855f7, // purple
	0xec4899, // pink
	0x84cc16, // lime
	0x0ea5e9, // sky
	0xf97316, // orange
	0x14b8a6, // teal
	0x8b5cf6, // violet
}

// Chart_Ink are the greys the charts draw their furniture in.
//
// palmy has no public way to read back a registered design token — the theme
// map is private — so the three shadcn values the charts need are repeated
// here rather than queried. That is a real gap and it is reported as one: if
// the theme is ever swapped, these three constants are the only thing in this
// application that would not follow.
Chart_Ink :: struct {
	fg:     p.Color,
	muted:  p.Color,
	grid:   p.Color,
	accent: p.Color,
	bad:    p.Color,
	good:   p.Color,
	track:  p.Color,
}

chart_ink :: proc(dark := false) -> Chart_Ink {
	if dark {
		return {
			fg = p.hex(0xfafafa),
			muted = p.hex(0xa1a1a1),
			grid = p.Color{255, 255, 255, 28},
			accent = p.hex(0x818cf8),
			bad = p.hex(0xf87171),
			good = p.hex(0x34d399),
			track = p.Color{255, 255, 255, 28},
		}
	}
	return {
		fg = p.hex(0x0a0a0a),
		muted = p.hex(0x737373),
		grid = p.Color{10, 10, 10, 24},
		accent = p.hex(0x6366f1),
		bad = p.hex(0xef4444),
		good = p.hex(0x059669),
		track = p.Color{10, 10, 10, 24},
	}
}

// text_top draws a run with `top` as the top of its line box rather than its
// baseline, which is what a layout thinks in. palmy's draw_text takes the
// baseline, and mixing the two up is how chart labels end up a few pixels out
// of their row.
text_top :: proc(
	c: ^p.Canvas,
	f: ^p.Fonts,
	s: string,
	x, top, size: f32,
	col: p.Color,
	wt := p.Font_Weight.Regular,
) {
	m := p.font_metrics(f, size, .Sans, wt)
	p.draw_text(c, f, s, x, top + m.ascent, size, col, .Sans, wt)
}

tint_of :: proc(i: int) -> p.Color {
	n := len(CATEGORY_TINTS)
	return p.hex(CATEGORY_TINTS[((i % n) + n) % n])
}

// nice_step rounds a raw step up to something a person reads without
// thinking: 1, 2, 2,50, 5 or 10 times a power of ten. An axis labelled every
// 1 373 € is arithmetically fine and useless.
nice_step :: proc(raw: i64) -> i64 {
	if raw <= 0 {
		return 1
	}
	pow := i64(1)
	for pow * 10 <= raw {
		pow *= 10
	}
	for mult in ([?]i64{1, 2, 25, 5, 10}) {
		// 25 stands for 2,5 at a tenth of the decade, which is the step that
		// makes 250 € and 2 500 € read well.
		cand := mult == 25 ? pow * 25 / 10 : pow * mult
		if cand >= raw {
			return cand
		}
	}
	return pow * 10
}

// axis_text is a money label short enough for an axis: whole euros, grouped,
// with a `k` suffix past ten thousand so the labels do not collide.
axis_text :: proc(c: Cents, allocator := context.temp_allocator) -> string {
	v := i64(c)
	neg := v < 0
	mag := neg ? -v : v
	b := strings.builder_make(allocator)
	if neg {
		strings.write_string(&b, "-")
	}
	// The `k` form only appears past a million euros. Mixing `10k €` with
	// `7 500 €` on the same axis reads as two different scales, so the
	// threshold is set where every label on an axis would take it.
	if mag >= 100_000_000_00 {
		strings.write_string(&b, fmt.tprintf("%d", mag / 100_000_00))
		strings.write_string(&b, "M")
	} else {
		euros := mag / 100
		digits := fmt.tprintf("%d", euros)
		for i in 0 ..< len(digits) {
			if i > 0 && (len(digits) - i) % 3 == 0 {
				strings.write_string(&b, NBSP)
			}
			strings.write_byte(&b, digits[i])
		}
	}
	strings.write_string(&b, NBSP)
	strings.write_string(&b, "€")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Spend by category
// ---------------------------------------------------------------------------

Bars_Data :: struct {
	app:   ^App,
	items: []Cat_Total,
	title: string,
	max:   Cents,
	fg:    p.Color,
	muted: p.Color,
	grid:  p.Color,
}

CHART_LABEL_W :: f32(150)
CHART_VALUE_W :: f32(96)
BAR_MIN_H :: f32(14)
BAR_MAX_H :: f32(44)
BAR_GAP_RATIO :: f32(0.42)

draw_bars :: proc(c: ^p.Canvas, r: p.Rect, d: ^Bars_Data) {
	if len(d.items) == 0 {
		return
	}
	fonts := d.app.fonts
	plot_x := r.x + CHART_LABEL_W
	plot_w := r.w - CHART_LABEL_W - CHART_VALUE_W
	if plot_w < 40 {
		return
	}

	step := nice_step(i64(d.max) / 4)
	// The axis top is the first tick at or above the largest bar, so the
	// longest bar never touches the right edge and the last gridline is
	// labelled.
	top := ((i64(d.max) + step - 1) / step) * step
	if top <= 0 {
		top = step
	}

	// Gridlines and their labels, along the top.
	ticks := int(top / step)
	for k in 0 ..= ticks {
		x := plot_x + plot_w * f32(k) / f32(ticks)
		p.draw_line(c, x, r.y + 16, x, r.y + r.h - 4, 1, d.grid)
		label := axis_text(Cents(step * i64(k)))
		w := p.text_width(fonts, label, 10)
		text_top(c, fonts, label, x - w / 2, r.y, 10, d.muted)
	}

	// The bars fill the panel: the slot is the space available divided by how
	// many there are, clamped so two categories do not become two slabs and
	// twenty do not become hairlines.
	avail := r.h - 28
	slot := clamp(avail / f32(max(len(d.items), 1)), BAR_MIN_H, BAR_MAX_H * (1 + BAR_GAP_RATIO))
	bar_h := clamp(slot / (1 + BAR_GAP_RATIO), BAR_MIN_H, BAR_MAX_H)
	gap := slot - bar_h

	// With only a few categories the bars would otherwise sit in the top
	// corner of a tall panel; centring the block vertically keeps the chart
	// looking like a chart rather than like a list that ran out.
	block := f32(len(d.items)) * slot - gap
	y := r.y + 24 + max((avail - block) / 2, 0)
	for item, i in d.items {
		if y + bar_h > r.y + r.h {
			break
		}
		name := account_name(&d.app.led, item.account)
		tint := tint_of(d.app.led.accounts[item.account].tint)

		// The label, right-aligned against the axis so the bars all start at
		// the same x whatever the name length.
		shown := name
		for p.text_width(fonts, shown, 12) > CHART_LABEL_W - 12 && len(shown) > 4 {
			shown = shown[:len(shown) - 1]
		}
		lw := p.text_width(fonts, shown, 12)
		text_top(c, fonts, shown, plot_x - 10 - lw, y + (bar_h - 14) / 2, 12, d.fg, .Medium)

		// The bar.
		frac := f32(i64(item.total)) / f32(top)
		frac = clamp(frac, 0, 1)
		bw := max(plot_w * frac, 2)
		rad := min(bar_h / 2, 4)
		p.fill_round_rect(c, {plot_x, y, bw, bar_h}, {rad, rad, rad, rad}, tint)

		// The value, to the right of the plot, in full French formatting.
		value := money_text(item.total, true, context.temp_allocator)
		text_top(c, fonts, value, plot_x + plot_w + 10, y + (bar_h - 14) / 2, 12, d.fg, .Medium)
		y += bar_h + gap
		_ = i
	}


	// The baseline the bars grow from.
	p.draw_line(c, plot_x, r.y + 16, plot_x, r.y + r.h - 4, 1, d.muted)
}

// ---------------------------------------------------------------------------
// Balance over time
// ---------------------------------------------------------------------------

Line_Data :: struct {
	app:    ^App,
	points: []Balance_Point,
	lo:     Date,
	hi:     Date,
	fg:     p.Color,
	muted:  p.Color,
	grid:   p.Color,
	accent: p.Color,
	bad:    p.Color,
}

PLOT_LEFT :: f32(74)
PLOT_BOTTOM :: f32(22)
PLOT_TOP :: f32(10)

draw_balance :: proc(c: ^p.Canvas, r: p.Rect, d: ^Line_Data) {
	if len(d.points) < 2 {
		return
	}
	fonts := d.app.fonts
	px := r.x + PLOT_LEFT
	py := r.y + PLOT_TOP
	pw := r.w - PLOT_LEFT - 12
	ph := r.h - PLOT_TOP - PLOT_BOTTOM
	if pw < 60 || ph < 40 {
		return
	}

	lo_v := d.points[0].balance
	hi_v := d.points[0].balance
	for pt in d.points {
		lo_v = min(lo_v, pt.balance)
		hi_v = max(hi_v, pt.balance)
	}
	// Zero is always in the range. A balance chart that hides the zero line
	// cannot answer the question it exists for.
	lo_v = min(lo_v, 0)
	hi_v = max(hi_v, 0)
	span := i64(hi_v - lo_v)
	if span == 0 {
		span = 100
	}
	step := nice_step(span / 4)
	axis_lo := (i64(lo_v) / step) * step
	if axis_lo > i64(lo_v) {
		axis_lo -= step
	}
	axis_hi := ((i64(hi_v) + step - 1) / step) * step
	if axis_hi <= axis_lo {
		axis_hi = axis_lo + step
	}
	range := f32(axis_hi - axis_lo)

	y_of :: proc(v: i64, axis_lo: i64, range, py, ph: f32) -> f32 {
		t := f32(v - axis_lo) / range
		return py + ph - t * ph
	}

	// Horizontal gridlines with money labels on the left.
	for v := axis_lo; v <= axis_hi; v += step {
		y := y_of(v, axis_lo, range, py, ph)
		is_zero := v == 0
		p.draw_line(c, px, y, px + pw, y, is_zero ? 1.5 : 1, is_zero ? d.muted : d.grid)
		label := axis_text(Cents(v))
		w := p.text_width(fonts, label, 10)
		text_top(c, fonts, label, px - 8 - w, y - 6, 10, d.muted)
	}

	// Date labels: the first, the middle and the last point, which is as
	// many as fit without overlapping and enough to read the span.
	day_lo := days_from_civil(d.points[0].date)
	day_hi := days_from_civil(d.points[len(d.points) - 1].date)
	if day_hi == day_lo {
		day_hi = day_lo + 1
	}
	x_of :: proc(day: int, day_lo, day_hi: int, px, pw: f32) -> f32 {
		t := f32(day - day_lo) / f32(day_hi - day_lo)
		return px + clamp(t, 0, 1) * pw
	}
	marks := [?]int{0, len(d.points) / 2, len(d.points) - 1}
	for mi, k in marks {
		pt := d.points[mi]
		x := x_of(days_from_civil(pt.date), day_lo, day_hi, px, pw)
		label := date_text(pt.date, context.temp_allocator)
		w := p.text_width(fonts, label, 10)
		tx := x - w / 2
		if k == 0 {
			tx = x
		}
		if k == len(marks) - 1 {
			tx = x - w
		}
		text_top(c, fonts, label, tx, py + ph + 5, 10, d.muted)
		p.draw_line(c, x, py + ph, x, py + ph + 3, 1, d.muted)
	}

	// The line itself, plus a soft fill down to the zero line so the shape
	// reads at a glance.
	zero_y := y_of(0, axis_lo, range, py, ph)
	prev_x := f32(0)
	prev_y := f32(0)
	for pt, i in d.points {
		x := x_of(days_from_civil(pt.date), day_lo, day_hi, px, pw)
		y := y_of(i64(pt.balance), axis_lo, range, py, ph)
		if i > 0 {
			// The fill: one vertical span per pixel column between the two
			// points, which is cheap and antialiases well enough under a
			// 2px line.
			// Half-open columns: each segment fills [prev, this), so two
			// consecutive segments never paint the same column twice. They
			// did at first, and a translucent fill drawn twice is visibly
			// darker — the chart came out striped once per transaction.
			x0 := int(math.round(prev_x))
			x1 := int(math.round(x))
			for xi in x0 ..< max(x1, x0 + 1) {
				t := x1 == x0 ? 0 : f32(xi - x0) / f32(x1 - x0)
				yy := prev_y + (y - prev_y) * t
				top := min(yy, zero_y)
				bot := max(yy, zero_y)
				p.fill_rect(
					c,
					{f32(xi), top, 1, bot - top},
					p.fade(yy > zero_y ? d.bad : d.accent, 0.14),
				)
			}
			p.draw_line(c, prev_x, prev_y, x, y, 2, d.accent)
		}
		prev_x = x
		prev_y = y
	}
	// A dot on the last point: where the balance is now.
	p.fill_circle(c, prev_x, prev_y, 3.5, d.accent)

	// The axes.
	p.draw_line(c, px, py, px, py + ph, 1, d.muted)
	p.draw_line(c, px, py + ph, px + pw, py + ph, 1, d.muted)
}

// ---------------------------------------------------------------------------
// A budget bar, drawn rather than composed, so the over-budget overshoot can
// be shown beyond the envelope instead of clipped at 100 %.
// ---------------------------------------------------------------------------

Gauge_Data :: struct {
	line:  Budget_Line,
	tint:  p.Color,
	track: p.Color,
	over:  p.Color,
	rule:  p.Color,
}

draw_gauge :: proc(c: ^p.Canvas, r: p.Rect, d: ^Gauge_Data) {
	rad := p.Radius{r.h / 2, r.h / 2, r.h / 2, r.h / 2}
	p.fill_round_rect(c, r, rad, d.track)
	if d.line.available <= 0 && d.line.spent <= 0 {
		return
	}

	// When the envelope is overspent the bar is scaled to the *spend*, so the
	// full width means "all of what was spent" and the envelope's own limit
	// is marked by a rule inside it. That shows how far over without the bar
	// having nowhere to go.
	denom := max(i64(d.line.available), i64(d.line.spent))
	if denom <= 0 {
		return
	}
	spent_frac := clamp(f32(i64(d.line.spent)) / f32(denom), 0, 1)
	if spent_frac > 0 {
		w := max(r.w * spent_frac, r.h)
		p.fill_round_rect(c, {r.x, r.y, w, r.h}, rad, d.line.over ? d.over : d.tint)
	}
	if d.line.over && d.line.available > 0 {
		x := r.x + r.w * clamp(f32(i64(d.line.available)) / f32(denom), 0, 1)
		p.draw_line(c, x, r.y - 2, x, r.y + r.h + 2, 1.5, d.rule)
	}
}
