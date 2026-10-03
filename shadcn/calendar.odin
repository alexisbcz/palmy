package shadcn

// Calendar, from app/components/ui/calendar.tsx (react-day-picker + Button).
//
// Every case in the registry is pinned to March 2026, which starts on a Sunday,
// so the month is exactly five rows of seven. The grid is a real table in the
// browser; here it is nested flex rows, which gives the same 28px cells because
// `--cell-size` is `--spacing(7)` and the month is 196px wide.
//
// Geometry note: Chromium lays the weekday row out at 19.1875px (line-height
// 19.2 truncated to a LayoutUnit) and then snaps every painted box to a whole
// device pixel, which turns the whole grid into integers: weekday row 20 tall,
// week rows at 80/116/152/188/224. Those integers are what this builds, so the
// snapped browser boxes and the palmy boxes coincide instead of sitting 0.4px
// apart all the way down.

import p "palmy:."

Calendar_Mode :: enum {
	Single,
	Range,
	Dropdown,
}

// Cell_Paint is the two stacked boxes of one day: the `td`, which carries the
// range highlight, and the day `button`, which carries the selection.
Cell_Paint :: struct {
	td_bg:      string,
	td_radius:  p.Radius,
	btn_bg:     string,
	btn_fg:     string,
	btn_radius: p.Radius,
}

CELL_R :: f32(8) // --cell-radius, --radius-md
BTN_R :: f32(10) // rounded-lg on the day button

// march_2026_cell describes cell `i` of the 35-cell grid.
@(private = "file")
march_2026_cell :: proc(i: int, mode: Calendar_Mode) -> (label: string, outside: bool, c: Cell_Paint) {
	LABELS := [35]string {
		"1", "2", "3", "4", "5", "6", "7",
		"8", "9", "10", "11", "12", "13", "14",
		"15", "16", "17", "18", "19", "20", "21",
		"22", "23", "24", "25", "26", "27", "28",
		"29", "30", "31", "1", "2", "3", "4",
	}
	label = LABELS[i]
	outside = i >= 31
	first := i % 7 == 0
	last := i % 7 == 6

	c.td_radius = {CELL_R, CELL_R, CELL_R, CELL_R}
	c.btn_radius = {BTN_R, BTN_R, BTN_R, BTN_R}

	day := i + 1 // 1-based day of March for i < 31

	if mode == .Range {
		if day < 10 || day > 18 {
			return
		}
		// `range_start` / `range_end` round the outer side of the cell and
		// square the inner one with an ::after bar; the net shape is the
		// radius below.
		switch day {
		case 10:
			c.td_bg = "bg-muted"
			c.td_radius = {CELL_R, 0, 0, CELL_R}
			c.btn_bg = "bg-primary"
			c.btn_fg = "text-primary-foreground"
			c.btn_radius = {CELL_R, CELL_R, CELL_R, CELL_R}
		case 18:
			c.td_bg = "bg-muted"
			c.td_radius = {0, CELL_R, CELL_R, 0}
			c.btn_bg = "bg-primary"
			c.btn_fg = "text-primary-foreground"
			c.btn_radius = {CELL_R, CELL_R, CELL_R, CELL_R}
		case:
			// `today` paints the cell itself and drops its rounding.
			if day == 15 {
				c.td_bg = "bg-muted"
			}
			c.td_radius = {}
			c.btn_bg = "bg-muted"
			c.btn_radius = {}
			if first {
				c.btn_radius[0], c.btn_radius[3] = CELL_R, CELL_R
			}
			if last {
				c.btn_radius[1], c.btn_radius[2] = CELL_R, CELL_R
			}
		}
		return
	}

	// Single selection: the 15th is both `today` and `selected`.
	if day == 15 {
		c.td_bg = "bg-muted"
		c.td_radius = {}
		c.btn_bg = "bg-primary"
		c.btn_fg = "text-primary-foreground"
		if first {
			c.btn_radius[0], c.btn_radius[3] = CELL_R, CELL_R
		}
		if last {
			c.btn_radius[1], c.btn_radius[2] = CELL_R, CELL_R
		}
	}
	return
}

WEEKDAYS := [7]string{"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"}

// nav_button is `buttonVariants({variant:"ghost"})` plus `size-(--cell-size)`.
@(private = "file")
nav_button :: proc(ui: ^p.Ctx, ic: p.Icon) {
	p.div(
		ui,
		"flex-row shrink-0 items-center justify-center rounded-lg " +
		"border border-transparent text-sm font-medium size-7 p-0 text-foreground",
	)
	p.icon(ui, ic, "size-4")
	p.end(ui)
}

// dropdown_label is one `caption_label` of the dropdown caption: the month or
// year name followed by a muted chevron.
@(private = "file")
dropdown_label :: proc(ui: ^p.Ctx, label: string, text_w: f32) {
	p.div(ui, "flex-row items-center gap-1 rounded-md text-sm font-medium h-5")
	defer p.end(ui)

	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	p.style(ui).w = p.px(text_w)
	p.icon(ui, ICON_CHEVRON_DOWN, "size-3.5 text-muted-foreground")
}

calendar :: proc(ui: ^p.Ctx, mode := Calendar_Mode.Single) -> int {
	root := p.div(ui, "w-fit bg-background p-2 text-sm")
	defer p.end(ui)

	// months
	p.div(ui, "relative flex-col gap-4")
	defer p.end(ui)

	// nav — absolute, inset-x-0 top-0, over the caption.
	p.div(ui, "flex-row w-full items-center justify-between gap-1 h-7")
	{
		st := p.style(ui)
		st.position = .Absolute
		st.inset[p.LEFT] = p.px(0)
		st.inset[p.RIGHT] = p.px(0)
		st.inset[p.TOP] = p.px(0)
		nav_button(ui, ICON_CHEVRON_LEFT)
		nav_button(ui, ICON_CHEVRON_RIGHT)
	}
	p.end(ui)

	// month
	p.div(ui, "flex-col w-full gap-4")
	defer p.end(ui)

	// month_caption
	p.div(ui, "flex-row h-7 w-full items-center justify-center px-7")
	if mode == .Dropdown {
		p.div(ui, "flex-row w-full h-full items-center justify-center gap-1.5 text-sm font-medium")
		dropdown_label(ui, "Mar", 25.89)
		dropdown_label(ui, "2026", 35.53)
		p.end(ui)
	} else {
		p.text(ui, "March 2026", "text-sm font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)

	// month_grid
	p.div(ui, "flex-col w-full")
	defer p.end(ui)

	// weekdays
	p.div(ui, "flex-row w-full h-5")
	for i in 0 ..< 7 {
		p.div(ui, "flex-1 h-full rounded-md")
		p.text(
			ui,
			WEEKDAYS[i],
			"w-full text-center text-[12.8] leading-[19] text-muted-foreground",
		)
		p.end(ui)
	}
	p.end(ui)

	// weeks
	for w in 0 ..< 5 {
		p.div(ui, "flex-row w-full h-7 mt-2")
		for d in 0 ..< 7 {
			i := w * 7 + d
			label, outside, c := march_2026_cell(i, mode)

			p.div(ui, "relative flex-1 h-full")
			if c.td_bg != "" {
				p.apply(ui, c.td_bg)
			}
			p.style(ui).radius = c.td_radius
			if outside {
				p.apply(ui, "text-muted-foreground")
			}

			p.div(ui, "flex-col w-full h-full items-center justify-center gap-1 text-sm")
			if c.btn_bg != "" {
				p.apply(ui, c.btn_bg)
			}
			if c.btn_fg != "" {
				p.apply(ui, c.btn_fg)
			}
			p.style(ui).radius = c.btn_radius
			p.text(ui, label, "leading-none whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)

			p.end(ui)
		}
		p.end(ui)
	}
	return root
}
