// The frame: the month grid, the year view, the day pane and the dialogs.
package main

import p "palmy:."
import sc "shadcn:."

frame :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	header(ui, c)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	if c.view == .Month {
		month_grid(ui, c)
	} else {
		year_view(ui, c)
	}
	p.end(ui)
	day_pane(ui, c)
	p.end(ui)

	status(ui, c)

	switch c.mode {
	case .Form:
		form_dialog(ui, c)
	case .Confirm_Delete:
		delete_dialog(ui, c)
	case .Help:
		help_sheet(ui, c)
	case .Normal:
	}
	toast(ui, c)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-4 bg-sidebar border-b border-border",
			HEADER_H,
		),
	)
	defer p.end(ui)

	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-background border border-border")
	p.icon(ui, ICON_CALENDAR_DAYS, "size-4 text-muted-foreground")
	p.end(ui)

	p.col(ui, "gap-px min-w-0 w-[210] shrink-0")
	p.text(
		ui,
		c.view == .Month ? tfmt("%s %d", month_name(c.sel.m), c.sel.y) : tfmt("%d", c.sel.y),
		"text-[17] font-semibold whitespace-nowrap",
	)
	wk, wy := iso_week(c.sel)
	p.text(
		ui,
		c.view == .Month \
		? tfmt("week %d of %d · %d days", wk, wy, days_in_month(c.sel.y, c.sel.m)) \
		: tfmt("%s · %d days", is_leap(c.sel.y) ? "leap year" : "common year", is_leap(c.sel.y) ? 366 : 365),
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.end(ui)

	p.row(ui, "items-center gap-1 shrink-0")
	nav(ui, c, "prev", ICON_CHEVRON_LEFT, -1)
	nav(ui, c, "next", ICON_CHEVRON_RIGHT, 1)
	p.end(ui)

	p.key(ui, "today")
	tb := p.row(
		ui,
		"h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer",
	)
	if p.clickable(ui, tb) {
		c.sel = c.today
		c.ev_sel = 0
	}
	p.icon(ui, ICON_DOT, "size-3.5 shrink-0 text-accent-blue")
	p.text(ui, "Today", "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.spacer(ui, "flex-1")

	p.key(ui, "add")
	ab := p.row(
		ui,
		"h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md bg-accent-blue hover:bg-accent-blue/90 transition cursor-pointer",
	)
	if p.clickable(ui, ab) {
		open_form(c, -1)
	}
	p.icon(ui, ICON_PLUS, "size-3.5 shrink-0 text-white")
	p.text(ui, "New event", "text-[12] font-medium text-white whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	vseg(ui, c, "Month", .Month)
	vseg(ui, c, "Year", .Year)
	p.end(ui)

	p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
	sc.kbd(ui, "F1")
	p.text(ui, "keys", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

nav :: proc(ui: ^p.Ctx, c: ^Cal, key: string, ic: p.Icon, by: int) {
	p.key(ui, key)
	idx := p.div(
		ui,
		"flex-row size-7 shrink-0 items-center justify-center rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer",
	)
	if p.clickable(ui, idx) {
		if c.view == .Month {
			c.sel = month_add(c.sel, by)
		} else {
			c.sel = Date{c.sel.y + by, c.sel.m, 1}
		}
		c.ev_sel = 0
	}
	p.icon(ui, ic, "size-3.5 text-foreground")
	p.end(ui)
}

vseg :: proc(ui: ^p.Ctx, c: ^Cal, label: string, v: View) {
	on := c.view == v
	p.key(ui, label)
	idx := p.div(ui, "flex-row h-6 w-12 items-center justify-center rounded-md transition cursor-pointer")
	p.apply(
		ui,
		on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
		idx,
	)
	if p.clickable(ui, idx) {
		c.view = v
		c.year_sel = c.sel.m
	}
	p.text(ui, label, "text-[11.5] font-medium")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Month grid
// ---------------------------------------------------------------------------

WK_W :: 34

// grid_metrics works the week-row height out in pixels rather than leaving it
// to `flex-1`.
//
// palmy resolves `h-full` and a flex basis against the height the parent had
// *before* it was shrunk to fit, so a column of six rows whose natural content
// is taller than the window keeps that natural height and the last row falls
// off the bottom. Measuring the window and dividing is not a style choice here,
// it is the only way the sixth week is on screen.
grid_metrics :: proc(ui: ^p.Ctx) -> (row_h: f32, body_h: f32) {
	win := p.size(ui)
	// header, status bar, pt-2, pb-4, the weekday row and six 4px gaps.
	body_h = max(120, win.y - HEADER_H - STATUS_H - 8 - 16 - 26 - 4)
	row_h = max(28, (body_h - f32(WEEKS - 1) * 4) / f32(WEEKS))
	return
}

month_grid :: proc(ui: ^p.Ctx, c: ^Cal) {
	row_h, _ := grid_metrics(ui)
	p.col(ui, "w-full h-full min-h-0 overflow-hidden px-4 pb-4 pt-2 gap-1")
	defer p.end(ui)

	// Weekday header, with the week-number gutter aligned above the grid.
	p.row(ui, "w-full h-[26] shrink-0 items-center")
	p.row(ui, tfmt("w-[%d] shrink-0 items-center justify-center", WK_W))
	p.icon(ui, ICON_HASH, "size-3 text-muted-foreground/50")
	p.end(ui)
	for name, i in DAYS_SHORT {
		p.key(ui, name)
		p.row(ui, "flex-1 min-w-0 items-center justify-center")
		p.text(
			ui,
			name,
			i >= 5 \
			? "text-[11] font-semibold tracking-wide text-muted-foreground/60 whitespace-nowrap" \
			: "text-[11] font-semibold tracking-wide text-muted-foreground whitespace-nowrap",
		)
		p.end(ui)
	}
	p.end(ui)

	// Six rows always, so the grid does not jump height between months.
	first := Date{c.sel.y, c.sel.m, 1}
	start := date_add(first, -weekday(first))

	for w in 0 ..< WEEKS {
		p.row(ui, tfmt("w-full h-[%d] shrink-0 items-stretch gap-1", int(row_h)))

		wk_date := date_add(start, w * 7)
		wk, _ := iso_week(wk_date)
		p.col(ui, tfmt("w-[%d] shrink-0 items-center justify-start pt-2", WK_W))
		p.textf(ui, "text-[10.5] font-mono text-muted-foreground/60", "%d", wk)
		p.end(ui)

		for dow in 0 ..< 7 {
			d := date_add(start, w * 7 + dow)
			day_cell(ui, c, d, dow)
		}
		p.end(ui)
	}
}

day_cell :: proc(ui: ^p.Ctx, c: ^Cal, d: Date, dow: int) {
	in_month := d.m == c.sel.m && d.y == c.sel.y
	is_today := date_eq(d, c.today)
	on := date_eq(d, c.sel)
	focus := on && c.pane == .Grid

	p.key(ui, date_iso(d))
	idx := p.col(ui, "flex-1 min-w-0 h-full gap-1 px-1.5 pt-1 pb-1 rounded-lg border transition cursor-pointer overflow-hidden")
	switch {
	case focus:
		p.apply(ui, "bg-accent-blue/10 border-accent-blue ring-3 ring-accent-blue/20", idx)
	case on:
		p.apply(ui, "bg-accent border-border", idx)
	case in_month:
		p.apply(ui, "bg-background border-transparent hover:bg-accent/60", idx)
	case:
		p.apply(ui, "bg-muted/40 border-transparent hover:bg-accent/40", idx)
	}
	if p.clickable(ui, idx) {
		c.sel = d
		c.ev_sel = 0
		c.pane = .Grid
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-1 shrink-0")
	if is_today {
		p.div(ui, "flex-row size-[20] items-center justify-center rounded-full bg-accent-blue shrink-0")
		p.textf(ui, "text-[11.5] font-semibold text-white", "%d", d.d)
		p.end(ui)
	} else {
		p.row(ui, "size-[20] items-center justify-center shrink-0")
		p.textf(
			ui,
			in_month \
			? (dow >= 5 ? "text-[12] font-medium text-muted-foreground" : "text-[12] font-medium text-foreground") \
			: "text-[12] text-muted-foreground/40",
			"%d",
			d.d,
		)
		p.end(ui)
	}
	if d.d == 1 {
		p.text(
			ui,
			MONTHS_SHORT[d.m - 1],
			in_month \
			? "text-[10] text-muted-foreground whitespace-nowrap shrink-0" \
			: "text-[10] text-muted-foreground/40 whitespace-nowrap shrink-0",
		)
	}
	p.spacer(ui, "flex-1")
	n := day_count(c, d)
	if n > 2 {
		p.textf(ui, "text-[9.5] text-muted-foreground whitespace-nowrap shrink-0", "+%d", n - 2)
	}
	p.end(ui)

	// Up to two chips, so a busy day still shows what it is rather than a dot.
	list := day_events(c, d)
	shown := min(len(list), 2)
	for k in 0 ..< shown {
		e := c.events[list[k]]
		p.key(ui, tfmt("e%d", list[k]))
		p.row(
			ui,
			in_month \
			? "w-full h-[16] shrink-0 items-center gap-1 px-1 rounded overflow-hidden bg-accent-blue/15" \
			: "w-full h-[16] shrink-0 items-center gap-1 px-1 rounded overflow-hidden bg-accent-blue/10",
		)
		p.div(ui, "w-[3] h-[9] rounded-full shrink-0 bg-accent-blue")
		p.end(ui)
		if e.start >= 0 {
			p.text(
				ui,
				clock_text(e.start),
				in_month \
				? "text-[9.5] font-mono text-accent-blue whitespace-nowrap shrink-0" \
				: "text-[9.5] font-mono text-accent-blue/50 whitespace-nowrap shrink-0",
			)
		}
		p.text(
			ui,
			e.title,
			in_month \
			? "flex-1 min-w-0 truncate text-[10] text-foreground" \
			: "flex-1 min-w-0 truncate text-[10] text-muted-foreground/60",
		)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Year view
// ---------------------------------------------------------------------------

year_view :: proc(ui: ^p.Ctx, c: ^Cal) {
	// Same reasoning as the month grid: three rows of mini months, measured
	// rather than grown.
	win := p.size(ui)
	avail := max(150, win.y - HEADER_H - STATUS_H - 8 - 16 - 2 * 8)
	row_h := int(avail / 3)

	p.col(ui, "w-full h-full min-h-0 overflow-hidden px-4 pb-4 pt-2 gap-2")
	defer p.end(ui)

	for r in 0 ..< 3 {
		p.row(ui, tfmt("w-full h-[%d] shrink-0 gap-2 items-stretch", row_h))
		for col in 0 ..< 4 {
			m := r * 4 + col + 1
			mini_month(ui, c, c.sel.y, m)
		}
		p.end(ui)
	}
}

mini_month :: proc(ui: ^p.Ctx, c: ^Cal, y, m: int) {
	on := c.year_sel == m
	p.key(ui, tfmt("m%d", m))
	idx := p.col(ui, "flex-1 min-w-0 h-full gap-1 px-2 py-2 rounded-xl border transition cursor-pointer overflow-hidden")
	p.apply(
		ui,
		on \
		? "bg-accent-blue/8 border-accent-blue ring-3 ring-accent-blue/20" \
		: "bg-background border-border hover:bg-accent/50",
		idx,
	)
	if p.clickable(ui, idx) {
		c.year_sel = m
		c.sel = Date{y, m, min(c.sel.d, days_in_month(y, m))}
		c.view = .Month
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-1.5 shrink-0 pb-0.5")
	p.text(
		ui,
		MONTHS[m - 1],
		c.today.y == y && c.today.m == m \
		? "text-[12] font-semibold text-accent-blue whitespace-nowrap" \
		: "text-[12] font-semibold text-foreground whitespace-nowrap",
	)
	p.spacer(ui, "flex-1")
	if n := month_count(c, y, m); n > 0 {
		p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap shrink-0", "%d", n)
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0")
	for name in DAYS_NARROW {
		p.row(ui, "flex-1 min-w-0 items-center justify-center")
		p.text(ui, name, "text-[8.5] text-muted-foreground/60")
		p.end(ui)
	}
	p.end(ui)

	first := Date{y, m, 1}
	start := date_add(first, -weekday(first))
	for w in 0 ..< 6 {
		p.row(ui, "w-full flex-1 min-h-0")
		for dow in 0 ..< 7 {
			d := date_add(start, w * 7 + dow)
			here := d.m == m && d.y == y
			// Only mark today inside its own month: the same date also shows
			// as a trailing day of the month before, and a filled dot there
			// reads as a second "today".
			today_here := here && date_eq(d, c.today)
			p.col(ui, "flex-1 min-w-0 h-full items-center justify-center")
			if today_here {
				p.div(ui, "flex-row size-[15] items-center justify-center rounded-full bg-accent-blue shrink-0")
				p.textf(ui, "text-[9] font-semibold text-white", "%d", d.d)
				p.end(ui)
			} else {
				p.textf(
					ui,
					here \
					? (day_count(c, d) > 0 ? "text-[9.5] font-semibold text-accent-blue" : "text-[9.5] text-foreground") \
					: "text-[9.5] text-muted-foreground/25",
					"%d",
					d.d,
				)
			}
			p.end(ui)
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Day pane
// ---------------------------------------------------------------------------

day_pane :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.col(
		ui,
		tfmt("w-[%d] shrink-0 h-full bg-sidebar border-l border-border overflow-hidden", DAY_W),
	)
	defer p.end(ui)

	wk, wy := iso_week(c.sel)
	p.col(ui, "w-full shrink-0 px-4 pt-4 pb-3 gap-1 border-b border-border")
	p.row(ui, "w-full items-baseline gap-2")
	p.textf(ui, "text-[30] font-semibold leading-[34]", "%d", c.sel.d)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, DAYS_LONG[weekday(c.sel)], "text-[13] font-medium whitespace-nowrap")
	p.text(
		ui,
		tfmt("%s %d", month_name(c.sel.m), c.sel.y),
		"text-[11.5] text-muted-foreground whitespace-nowrap",
	)
	p.end(ui)
	if date_eq(c.sel, c.today) {
		sc.badge(ui, "Today", .Default)
	}
	p.end(ui)
	p.row(ui, "w-full items-center gap-2")
	p.text(
		ui,
		tfmt("ISO week %d of %d", wk, wy),
		"text-[11] text-muted-foreground whitespace-nowrap shrink-0",
	)
	p.text(ui, "·", "text-[11] text-muted-foreground/50 shrink-0")
	p.text(
		ui,
		tfmt("day %d of the year", days_from_civil(c.sel) - days_from_civil(Date{c.sel.y, 1, 1}) + 1),
		"text-[11] text-muted-foreground whitespace-nowrap shrink-0",
	)
	if date_eq(c.sel, c.today) {
		p.text(ui, "·", "text-[11] text-muted-foreground/50 shrink-0")
		p.text(
			ui,
			tfmt("now %s", clock_text(c.now_min)),
			"text-[11] font-mono text-accent-blue whitespace-nowrap shrink-0",
		)
	}
	p.end(ui)
	p.end(ui)

	list := day_events(c, c.sel)
	if len(list) == 0 {
		p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-2.5 px-8")
		p.div(ui, "flex-row size-11 items-center justify-center rounded-2xl bg-muted shrink-0")
		p.icon(ui, ICON_CALENDAR_PLUS, "size-5 text-muted-foreground")
		p.end(ui)
		p.text(ui, "Nothing planned", "text-[13.5] font-medium")
		p.text(
			ui,
			"This day is free. Press A to put something in it.",
			"max-w-[240] text-center text-[11.5] text-muted-foreground",
		)
		p.row(ui, "items-center gap-1.5 pt-1")
		sc.kbd(ui, "A")
		p.text(ui, "new event", "text-[11] text-muted-foreground")
		p.style(ui).shrink = 0
		p.end(ui)
		p.end(ui)
		return
	}

	c.ev_sel = clamp(c.ev_sel, 0, len(list) - 1)
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-2.5 gap-1.5")
	defer p.end(ui)

	for ei, k in list {
		e := c.events[ei]
		on := k == c.ev_sel
		focus := on && c.pane == .Day

		p.key(ui, tfmt("ev%d", ei))
		idx := p.row(ui, "w-full shrink-0 items-stretch gap-2.5 px-3 py-2.5 rounded-lg border transition cursor-pointer")
		switch {
		case focus:
			p.apply(ui, "bg-accent-blue border-accent-blue", idx)
		case on:
			p.apply(ui, "bg-accent border-border", idx)
		case:
			p.apply(ui, "bg-background border-border hover:bg-accent/60", idx)
		}
		if p.clickable(ui, idx) {
			c.ev_sel = k
			c.pane = .Day
		}

		p.div(ui, focus ? "w-[3] shrink-0 rounded-full bg-white/70" : "w-[3] shrink-0 rounded-full bg-accent-blue")
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-1")
		p.text(
			ui,
			e.title,
			focus \
			? "w-full truncate text-[13] font-semibold text-white" \
			: "w-full truncate text-[13] font-semibold text-foreground",
		)
		p.row(ui, "w-full items-center gap-1.5")
		p.icon(
			ui,
			e.start < 0 ? ICON_CALENDAR : ICON_CLOCK,
			focus ? "size-3 shrink-0 text-white/80" : "size-3 shrink-0 text-muted-foreground",
		)
		p.text(
			ui,
			e.start < 0 ? "All day" : tfmt("%s%s", clock_text(e.start), e.mins > 0 ? tfmt(" – %s", clock_text((e.start + e.mins) % (24 * 60))) : ""),
			focus \
			? "text-[11.5] font-mono text-white/85 whitespace-nowrap shrink-0" \
			: "text-[11.5] font-mono text-muted-foreground whitespace-nowrap shrink-0",
		)
		if d := duration_text(e.mins); d != "" && e.start >= 0 {
			p.text(ui, "·", focus ? "text-[11] text-white/50 shrink-0" : "text-[11] text-muted-foreground/50 shrink-0")
			p.text(
				ui,
				d,
				focus \
				? "text-[11] text-white/75 whitespace-nowrap shrink-0" \
				: "text-[11] text-muted-foreground whitespace-nowrap shrink-0",
			)
		}
		p.end(ui)
		if e.place != "" {
			p.row(ui, "w-full items-center gap-1.5")
			p.icon(ui, ICON_MAP_PIN, focus ? "size-3 shrink-0 text-white/80" : "size-3 shrink-0 text-muted-foreground")
			p.text(
				ui,
				e.place,
				focus \
				? "flex-1 min-w-0 truncate text-[11.5] text-white/85" \
				: "flex-1 min-w-0 truncate text-[11.5] text-muted-foreground",
			)
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status :: proc(ui: ^p.Ctx, c: ^Cal) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border",
			STATUS_H,
		),
	)
	defer p.end(ui)

	p.text(
		ui,
		c.view == .Year ? "Year" : (c.pane == .Grid ? "Grid" : "Day"),
		"text-[11.5] font-medium whitespace-nowrap shrink-0",
	)
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")

	if c.view == .Year {
		hint(ui, "Arrows", "month")
		hint(ui, "Enter", "open")
		hint(ui, "Y", "back")
	} else if c.pane == .Grid {
		hint(ui, "Arrows", "day")
		hint(ui, "PgUp PgDn", "month")
		hint(ui, "Enter", "events")
		hint(ui, "A", "new")
	} else {
		hint(ui, "Up Down", "event")
		hint(ui, "E", "edit")
		hint(ui, "Delete", "remove")
		hint(ui, "Esc", "grid")
	}

	p.spacer(ui, "flex-1")
	p.textf(
		ui,
		"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
		"%d event%s this month",
		month_count(c, c.sel.y, c.sel.m),
		month_count(c, c.sel.y, c.sel.m) == 1 ? "" : "s",
	)
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	p.textf(
		ui,
		"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
		"%d in total",
		len(c.events),
	)
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	p.text(ui, "~/.local/share/palmy-calendar", "text-[11] font-mono text-muted-foreground/70 whitespace-nowrap shrink-0")
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/80 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

sheet_open :: proc(ui: ^p.Ctx, w: int, top: f32) {
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", w))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - f32(w)) / 2))
	s.inset[p.TOP] = p.px(top)
	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
}

sheet_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

scrim :: proc(ui: ^p.Ctx, c: ^Cal) {
	s := p.div(ui, "absolute inset-0 z-40 bg-foreground/15")
	if p.clickable(ui, s) {
		c.mode = .Normal
	}
	p.end(ui)
}

FIELD_LABELS := [Field]string {
	.Date     = "Date",
	.Time     = "Start",
	.Duration = "Minutes",
	.Title    = "Title",
	.Place    = "Where",
}

FIELD_HINTS := [Field]string {
	.Date     = "YYYY-MM-DD",
	.Time     = "HH:MM, empty for all day",
	.Duration = "60",
	.Title    = "What is happening",
	.Place    = "Optional",
}

form_dialog :: proc(ui: ^p.Ctx, c: ^Cal) {
	scrim(ui, c)
	win := p.size(ui)
	sheet_open(ui, 520, max(8, win.y / 2 - 230))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-1")
	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-accent-blue/10")
	p.icon(ui, c.form.editing < 0 ? ICON_CALENDAR_PLUS : ICON_PENCIL, "size-4 text-accent-blue")
	p.end(ui)
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, c.form.editing < 0 ? "New event" : "Edit event", "text-[15] font-semibold")
	p.text(
		ui,
		"Tab moves between fields, Enter saves.",
		"text-[11.5] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-5 pt-3 pb-4 gap-2.5")
	for f in Field {
		p.key(ui, FIELD_LABELS[f])
		p.row(ui, "w-full items-center gap-3")
		p.text(
			ui,
			FIELD_LABELS[f],
			"w-[72] shrink-0 text-right text-[12] font-medium text-muted-foreground",
		)
		idx := p.row(
			ui,
			"flex-1 min-w-0 h-9 items-center gap-1 px-3 rounded-lg border border-input bg-background overflow-hidden cursor-text",
		)
		// Focus follows the press, as a browser's input does, and is settled
		// before the row is dressed so the frame that sees the press shows it.
		if p.clickable(ui, idx) || p.is_active(ui, idx) {
			c.form.field = f
		}
		active := c.form.field == f
		if active {
			p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
		}
		v := string(c.form.bufs[f][:])
		p.text(
			ui,
			v == "" ? FIELD_HINTS[f] : v,
			v == "" \
			? "text-[13] text-muted-foreground/60 whitespace-nowrap shrink-0" \
			: "text-[13] text-foreground whitespace-nowrap shrink-0",
		)
		if active && p.caret_on(ui) {
			p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
	}

	if c.form.err != "" {
		p.row(ui, "w-full items-center gap-2 pt-0.5")
		p.icon(ui, ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, c.form.err, "flex-1 min-w-0 text-[12] text-destructive")
		p.end(ui)
	} else if date, ok := parse_iso(string(c.form.bufs[.Date][:])); ok {
		wk, wy := iso_week(date)
		p.row(ui, "w-full items-center gap-2 pt-0.5")
		p.icon(ui, ICON_CALENDAR, "size-3.5 shrink-0 text-muted-foreground")
		p.text(
			ui,
			tfmt("%s, %d %s %d · week %d of %d", DAYS_LONG[weekday(date)], date.d, MONTHS[date.m - 1], date.y, wk, wy),
			"flex-1 min-w-0 text-[12] text-muted-foreground",
		)
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[44] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", c.form.editing < 0 ? "add" : "save")
	p.end(ui)
}

delete_dialog :: proc(ui: ^p.Ctx, c: ^Cal) {
	scrim(ui, c)
	i, ok := selected_event(c)
	if !ok {
		return
	}
	e := c.events[i]
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 150))
	defer sheet_close(ui)

	p.col(ui, "w-full items-center px-6 pt-6 pb-4 gap-4")
	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-red-100 shrink-0")
	p.icon(ui, ICON_TRASH, "size-4.5 text-destructive")
	p.end(ui)

	p.col(ui, "items-center gap-1.5 w-full")
	p.text(ui, "Delete this event?", "text-[16] font-semibold")
	p.text(ui, e.title, "max-w-[340] text-center text-[13] font-medium")
	p.text(
		ui,
		tfmt("%s %d %s · %s", DAYS_SHORT[weekday(e.date)], e.date.d, MONTHS[e.date.m - 1], clock_text(e.start)),
		"text-[11.5] text-muted-foreground",
	)
	p.end(ui)

	p.row(ui, "w-full gap-2 pt-1")
	for label, k in ([?]string{"Keep it", "Delete"}) {
		on := (k == 1) == c.confirm
		p.key(ui, label)
		idx := p.row(ui, "flex-1 h-[34] items-center justify-center rounded-lg border border-border transition cursor-pointer")
		switch {
		case on && k == 1:
			p.apply(ui, "bg-destructive border-destructive text-white ring-3 ring-destructive/25", idx)
		case on:
			p.apply(ui, "bg-secondary border-ring ring-3 ring-ring/30", idx)
		case:
			p.apply(ui, "bg-background hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			c.confirm = k == 1
		}
		p.text(ui, label, "text-[13] font-medium whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Left Right", "choose")
	hint(ui, "Enter", "confirm")
	p.end(ui)
}

HELP_ROWS := [?][2]string {
	{"Arrows", "move a day, or a month in the year view"},
	{"PgUp / PgDn", "previous and next month"},
	{"Shift PgUp / PgDn", "previous and next year"},
	{"Home / End", "Monday and Sunday of this week"},
	{"T", "jump to today"},
	{"Y", "switch the month and year views"},
	{"Tab", "move between the grid and the day"},
	{"Enter", "open the day, or edit the event"},
	{"A  or  N", "new event"},
	{"E", "edit the selected event"},
	{"Delete  or  D", "delete the selected event"},
	{"F1", "this list"},
	{"Ctrl Q", "quit"},
}

help_sheet :: proc(ui: ^p.Ctx, c: ^Cal) {
	scrim(ui, c)
	win := p.size(ui)
	sheet_open(ui, 560, max(8, (win.y - 480) / 2))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3")
	p.icon(ui, ICON_KEYBOARD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, "Calendar, from the keyboard", "text-[15] font-semibold")
	p.text(
		ui,
		"Events live in ~/.local/share/palmy-calendar/events.tsv.",
		"text-[12] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-5 pb-5 gap-1.5")
	for row in HELP_ROWS {
		p.row(ui, "w-full items-center gap-3")
		p.row(ui, "w-[150] shrink-0 justify-end")
		sc.kbd(ui, row[0])
		p.end(ui)
		p.text(ui, row[1], "flex-1 min-w-0 text-[12] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center justify-end gap-2 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "close")
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, c: ^Cal) {
	if c.toast == "" {
		return
	}
	if c.toast_at == 0 {
		c.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - c.toast_at > 2.6 {
		delete(c.toast)
		c.toast = ""
		c.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(
		ui,
		"absolute z-30 left-[16] bottom-[40] max-w-[420] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg",
	)
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-accent-blue")
	p.text(ui, c.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
