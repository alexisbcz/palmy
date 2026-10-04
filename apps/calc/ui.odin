// The frame: the display, the pad, the history and the variables.
package main

import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

MONO :: "font-mono whitespace-nowrap shrink-0"

frame :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	header(ui, c)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	p.col(ui, "flex-1 min-w-0 h-full")
	display(ui, c)
	pad(ui, c)
	p.end(ui)
	side(ui, c)
	p.end(ui)

	status(ui, c)

	if c.help {
		help_sheet(ui, c)
	}
	toast(ui, c)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-4 bg-sidebar border-b border-border",
			HEADER_H,
		),
	)
	defer p.end(ui)

	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-background border border-border")
	p.icon(ui, ICON_CALCULATOR, "size-4 text-muted-foreground")
	p.end(ui)

	p.col(ui, "gap-px min-w-0")
	p.text(ui, "Calculator", "text-[14] font-semibold whitespace-nowrap")
	p.text(
		ui,
		"Precedence, parentheses, functions and variables",
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.end(ui)

	p.spacer(ui, "flex-1")

	// The angle mode, as a two-position segmented control.
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	seg(ui, c, "Rad", false)
	seg(ui, c, "Deg", true)
	p.end(ui)

	p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
	sc.kbd(ui, "F1")
	p.text(ui, "keys", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

seg :: proc(ui: ^p.Ctx, c: ^Calc, label: string, deg: bool) {
	on := c.deg == deg
	p.key(ui, label)
	idx := p.div(ui, "flex-row h-6 w-11 items-center justify-center rounded-md transition cursor-pointer")
	p.apply(
		ui,
		on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
		idx,
	)
	if p.clickable(ui, idx) && !on {
		c.deg = deg
		recompute(c)
	}
	p.text(ui, label, "text-[11.5] font-medium")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

display :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.col(ui, "w-full shrink-0 px-6 pt-5 pb-5 gap-3 border-b border-border bg-background")
	defer p.end(ui)

	p.text(ui, "EXPRESSION", "text-[10] font-semibold tracking-wide text-muted-foreground/70")

	// The input line. The caret sits between two runs rather than being
	// positioned by measurement, so it is exact at any font.
	idx := p.row(ui, "w-full items-center min-h-[30] overflow-hidden cursor-text")
	if p.clickable(ui, idx) {
		c.pane = .Input
	}
	text := string(c.input[:])
	if len(text) == 0 {
		p.text(ui, "type an expression", tfmt("%s text-[20] text-muted-foreground/50", MONO))
	} else {
		cur := clamp(c.cur, 0, len(text))
		p.text(ui, text[:cur], tfmt("%s text-[20] text-foreground", MONO))
		if c.pane == .Input {
			p.redraw(ui)
			on := math.mod(f64(p.elapsed(ui)), 1.06) < 0.62
			p.div(ui, on ? "w-[2] h-[22] bg-accent-blue shrink-0" : "w-[2] h-[22] shrink-0")
			p.end(ui)
		}
		p.text(ui, text[cur:], tfmt("%s text-[20] text-foreground", MONO))
	}
	if len(text) == 0 && c.pane == .Input {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-[2] h-[22] bg-accent-blue shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)

	// The answer, or the error with a caret under what caused it.
	if len(strings.trim_space(text)) == 0 {
		p.row(ui, "w-full items-center gap-2 h-[40]")
		p.text(ui, "=", tfmt("%s text-[24] text-muted-foreground/40", MONO))
		p.text(ui, "—", tfmt("%s text-[24] text-muted-foreground/40", MONO))
		p.end(ui)
		return
	}

	if c.live.ok {
		p.row(ui, "w-full items-baseline gap-3 h-[40]")
		p.text(ui, "=", tfmt("%s text-[24] text-muted-foreground/50", MONO))
		p.text(ui, fmt_num(c.live.value), tfmt("%s text-[28] font-semibold text-foreground truncate", MONO))
		if c.live.assign != "" {
			sc.badge(ui, tfmt("sets %s", c.live.assign), .Secondary)
		}
		p.end(ui)
		return
	}

	// The caret line is the same mono face at the same size as the input, so
	// the marker lands exactly under the offending character.
	e := c.live.err
	pad_n := clamp(e.pos, 0, len(text))
	marks := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< pad_n {
		strings.write_byte(&marks, ' ')
	}
	for _ in 0 ..< max(1, e.len) {
		strings.write_byte(&marks, '^')
	}

	p.col(ui, "w-full gap-1")
	p.text(ui, strings.to_string(marks), tfmt("%s text-[20] leading-[14] text-destructive", MONO))
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
	p.text(ui, e.msg, "text-[13] text-destructive truncate")
	p.text(
		ui,
		tfmt("at character %d", e.pos + 1),
		"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
	)
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Pad
// ---------------------------------------------------------------------------

pad :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.col(ui, "flex-1 min-h-0 w-full p-4 gap-2 bg-muted/30")
	defer p.end(ui)

	for r in 0 ..< PAD_ROWS {
		p.row(ui, "w-full flex-1 min-h-0 gap-2")
		for col in 0 ..< PAD_COLS {
			i := r * PAD_COLS + col
			k := PAD[i]
			on := c.pane == .Pad && c.pad == i

			p.key(ui, tfmt("pad%d", i))
			idx := p.div(
				ui,
				"flex-row flex-1 min-w-0 h-full items-center justify-center rounded-lg border transition cursor-pointer",
			)
			base := ""
			switch k.tone {
			case 0:
				base = "bg-background border-border text-foreground hover:bg-accent"
			case 1:
				base = "bg-secondary border-border text-foreground hover:bg-accent"
			case 2:
				base = "bg-background border-border text-[#6639ba] hover:bg-accent"
			case:
				base = "bg-accent-blue border-accent-blue text-white"
			}
			p.apply(ui, base, idx)
			if on {
				p.apply(ui, "ring-3 ring-accent-blue/40 border-accent-blue", idx)
			}
			if p.clickable(ui, idx) {
				c.pad = i
				press_pad(c, k)
			}
			p.text(
				ui,
				k.label,
				k.tone == 0 \
				? tfmt("%s text-[16] font-medium", MONO) \
				: tfmt("%s text-[13.5] font-medium", MONO),
			)
			p.end(ui)
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// History and variables
// ---------------------------------------------------------------------------

side :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.col(
		ui,
		tfmt("w-[%d] shrink-0 h-full bg-sidebar border-l border-border overflow-hidden", SIDE_W),
	)
	defer p.end(ui)

	p.row(ui, "h-[36] shrink-0 w-full items-center gap-2 px-3 border-b border-border")
	p.icon(ui, ICON_CLOCK, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "History", "text-[12] font-semibold whitespace-nowrap")
	p.spacer(ui, "flex-1")
	if len(c.hist) > 0 {
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap shrink-0",
			"%d",
			len(c.hist),
		)
	}
	p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll p-1.5 gap-1")
	list_id := p.node_id(ui, list)
	if len(c.hist) == 0 {
		p.col(ui, "w-full items-center justify-center gap-2 py-10 px-6")
		p.div(ui, "flex-row size-9 items-center justify-center rounded-xl bg-muted shrink-0")
		p.icon(ui, ICON_SIGMA, "size-4 text-muted-foreground")
		p.end(ui)
		p.text(ui, "Nothing yet", "text-[12.5] font-medium")
		p.text(
			ui,
			"Press Enter to work out what you have typed. Results land here.",
			"max-w-[220] text-center text-[11.5] text-muted-foreground",
		)
		p.end(ui)
	}
	for e, i in c.hist {
		on := i == c.hist_sel
		focus := on && c.pane == .History
		p.key(ui, tfmt("h%d", i))
		idx := p.col(ui, "w-full shrink-0 gap-0.5 px-2.5 py-2 rounded-lg transition cursor-pointer")
		switch {
		case focus:
			p.apply(ui, "bg-accent-blue", idx)
		case on:
			p.apply(ui, "bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent/70", idx)
		}
		if p.clickable(ui, idx) {
			c.hist_sel = i
			reuse(c, e)
		}
		if focus {
			p.scroll_into_view(ui, list_id, p.node_id(ui, idx), 6)
		}

		p.row(ui, "w-full items-center gap-1.5")
		p.text(
			ui,
			e.expr,
			focus \
			? tfmt("%s flex-1 min-w-0 truncate text-[11.5] text-white/75", MONO) \
			: tfmt("%s flex-1 min-w-0 truncate text-[11.5] text-muted-foreground", MONO),
		)
		if e.assign != "" {
			p.text(
				ui,
				tfmt("sets %s", e.assign),
				focus \
				? "text-[10] text-white/70 whitespace-nowrap shrink-0" \
				: "text-[10] text-muted-foreground/80 whitespace-nowrap shrink-0",
			)
		}
		p.end(ui)

		if e.ok {
			p.text(
				ui,
				e.out,
				focus \
				? tfmt("%s w-full truncate text-[15] font-semibold text-white", MONO) \
				: tfmt("%s w-full truncate text-[15] font-semibold text-foreground", MONO),
			)
		} else {
			p.row(ui, "w-full items-center gap-1.5")
			p.icon(
				ui,
				ICON_CIRCLE_ALERT,
				focus ? "size-3 shrink-0 text-white" : "size-3 shrink-0 text-destructive",
			)
			p.text(
				ui,
				e.msg,
				focus \
				? "flex-1 min-w-0 truncate text-[11.5] text-white" \
				: "flex-1 min-w-0 truncate text-[11.5] text-destructive",
			)
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	// Variables, including `ans`.
	p.col(ui, "w-full shrink-0 border-t border-border")
	p.row(ui, "h-[32] shrink-0 w-full items-center gap-2 px-3")
	p.icon(ui, ICON_VARIABLE, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Variables", "text-[12] font-semibold whitespace-nowrap")
	p.spacer(ui, "flex-1")
	p.text(ui, "name = value", "text-[10.5] text-muted-foreground/70 whitespace-nowrap shrink-0")
	p.end(ui)

	p.col(ui, "w-full max-h-[148] overflow-scroll px-3 pb-3 gap-1")
	for name in c.names {
		v, ok := c.vars[name]
		if !ok {
			continue
		}
		p.key(ui, name)
		p.row(ui, "w-full items-center gap-2 shrink-0")
		p.text(ui, name, tfmt("%s w-[64] shrink-0 truncate text-[12] font-medium text-foreground", MONO))
		p.text(ui, "=", tfmt("%s text-[12] text-muted-foreground/60", MONO))
		p.text(ui, fmt_num(v), tfmt("%s flex-1 min-w-0 truncate text-[12] text-muted-foreground", MONO))
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status :: proc(ui: ^p.Ctx, c: ^Calc) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border",
			STATUS_H,
		),
	)
	defer p.end(ui)

	label := ""
	switch c.pane {
	case .Input:
		label = "Input"
	case .Pad:
		label = "Keypad"
	case .History:
		label = "History"
	}
	p.text(ui, label, "text-[11.5] font-medium text-foreground whitespace-nowrap shrink-0")
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")

	switch c.pane {
	case .Input:
		hint(ui, "Enter", "evaluate")
		hint(ui, "Up Down", "recall")
		hint(ui, "Tab", "keypad")
	case .Pad:
		hint(ui, "Arrows", "move")
		hint(ui, "Enter", "press")
		hint(ui, "Tab", "history")
	case .History:
		hint(ui, "Enter", "reuse")
		hint(ui, "Delete", "remove")
		hint(ui, "Tab", "input")
	}

	p.spacer(ui, "flex-1")
	p.text(
		ui,
		c.deg ? "degrees" : "radians",
		"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
	)
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	p.textf(
		ui,
		"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
		"%d in history",
		len(c.hist),
	)
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/80 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------

HELP_KEYS := [?][2]string {
	{"Enter", "evaluate and keep the result"},
	{"Up / Down", "walk back through what you typed"},
	{"Tab", "input, keypad, history"},
	{"Escape", "clear the input"},
	{"F2", "switch degrees and radians"},
	{"Ctrl C", "copy the result"},
	{"Ctrl L", "clear the history"},
	{"Ctrl Q", "quit"},
}

HELP_SYNTAX := [?][2]string {
	{"+ - * / %", "add, subtract, multiply, divide, modulo"},
	{"^", "power, right associative: 2^3^2 is 512"},
	{"!", "factorial: 5! is 120"},
	{"( )", "grouping, nested as deep as you like"},
	{"x = expr", "assign a variable"},
	{"ans", "the previous result"},
	{"pi  e  tau", "constants"},
	{"sqrt cbrt abs", "roots and magnitude"},
	{"sin cos tan", "and asin acos atan, in the current angle mode"},
	{"ln log log2 exp", "logarithms and the exponential"},
	{"floor ceil round", "and trunc, sign"},
	{"min max hypot", "two or more arguments"},
}

help_sheet :: proc(ui: ^p.Ctx, c: ^Calc) {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-foreground/15")
	if p.clickable(ui, scrim) {
		c.help = false
	}
	p.end(ui)

	W :: 640
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - W) / 2))
	s.inset[p.TOP] = p.px(max(8, (win.y - 540) / 2))
	defer p.end(ui)

	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3")
	p.icon(ui, ICON_KEYBOARD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, "What this calculator understands", "text-[15] font-semibold")
	p.text(ui, "The parser, in one page.", "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-5 pb-4 gap-3")
	p.text(ui, "KEYS", "text-[10] font-semibold tracking-wide text-muted-foreground/70")
	for row in HELP_KEYS {
		p.row(ui, "w-full items-center gap-3")
		p.row(ui, "w-[110] shrink-0 justify-end")
		sc.kbd(ui, row[0])
		p.end(ui)
		p.text(ui, row[1], "flex-1 min-w-0 text-[12] text-muted-foreground")
		p.end(ui)
	}

	sc.separator(ui)

	p.text(ui, "SYNTAX", "text-[10] font-semibold tracking-wide text-muted-foreground/70")
	for row in HELP_SYNTAX {
		p.row(ui, "w-full items-center gap-3")
		p.text(ui, row[0], tfmt("%s w-[110] shrink-0 text-right text-[12] text-foreground", MONO))
		p.text(ui, row[1], "flex-1 min-w-0 text-[12] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center justify-end gap-2 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "close")
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, c: ^Calc) {
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
