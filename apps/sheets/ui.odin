// The chrome around the grid: a toolbar, the formula bar, the status bar, and
// the two overlays. Menus and dialogs are drawn inside the window because
// Wayland's xdg_popup is not available here.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

frame :: proc(ui: ^p.Ctx, app: ^App) {
	p.div(ui, "relative flex-col w-full h-full bg-background text-foreground overflow-hidden")
	defer p.end(ui)

	toolbar(ui, app)
	formula_bar(ui, app)

	p.pixels(ui, "flex-1 w-full overflow-hidden", app, draw_grid)

	status_bar(ui, app)

	if app.mode == .Prompt {
		prompt_overlay(ui, app)
	}
	if app.mode == .Palette {
		palette_overlay(ui, app)
	}
	if app.mode == .Help {
		help_overlay(ui, app)
	}
}

// ---------------------------------------------------------------------------

toolbar :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(
		ui,
		p.concat(
			ui,
			"shrink-0 items-center gap-2.5 px-3 border-b border-border bg-card overflow-hidden h-[",
			int_text(int(TOOLBAR_H)),
			"]",
		),
	)
	defer p.end(ui)

	p.icon(ui, sc.ICON_COLUMNS_3, "size-4 text-muted-foreground")
	p.text(ui, app.name != "" ? app.name : "Untitled sheet", "text-sm font-semibold whitespace-nowrap shrink-0")
	if app.modified {
		p.div(ui, "size-1.5 rounded-full bg-primary")
		p.end(ui)
	}
	sc.separator(ui, .Vertical, "h-4 mx-1")

	// What the active cell's format is, so the keys have visible feedback.
	f := fmt_at(&app.sh, app.cur)
	sc.badge(ui, num_format_name(f.num), .Outline)
	if f.dec > 0 && (f.num == .Fixed || f.num == .Percent || f.num == .Currency) {
		sc.badge(ui, fmt.tprintf("%d dp", f.dec), .Ghost)
	}
	if f.bold {
		sc.badge(ui, "Bold", .Secondary)
	}
	if f.italic {
		sc.badge(ui, "Italic", .Secondary)
	}

	p.spacer(ui)

	sel := sel_rect(app)
	if sel.r0 != sel.r1 || sel.c0 != sel.c1 {
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap shrink-0",
			"%d R x %d C",
			sel.r1 - sel.r0 + 1,
			sel.c1 - sel.c0 + 1,
		)
	}
	p.text(ui, "Keys", "text-xs text-muted-foreground whitespace-nowrap shrink-0")
	sc.kbd(ui, "F1")
}

// ---------------------------------------------------------------------------

formula_bar :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(
		ui,
		p.concat(
			ui,
			"shrink-0 items-center gap-2 px-3 border-b border-border overflow-hidden h-[",
			int_text(int(FORMULA_H)),
			"]",
		),
	)
	defer p.end(ui)

	// The name box, showing the active cell or the whole selection.
	sel := sel_rect(app)
	label :=
		(sel.r0 == sel.r1 && sel.c0 == sel.c1) \
		? addr_name(app.cur) \
		: fmt.tprintf("%s:%s", addr_name({sel.r0, sel.c0}), addr_name({sel.r1, sel.c1}))
	p.div(ui, "w-[104] h-6 px-2 items-center justify-center rounded-md border border-input bg-muted/50 shrink-0")
	p.text(ui, label, "text-xs font-mono font-medium whitespace-nowrap")
	p.end(ui)

	p.text(ui, "fx", "text-xs font-semibold text-muted-foreground italic shrink-0")

	// The input itself, drawn by hand so the caret lands on the glyph grid.
	p.div(ui, "flex-1 h-6 rounded-md border border-input overflow-hidden")
	if app.mode == .Edit && app.in_bar {
		p.apply(ui, "border-ring ring-3 ring-ring/50")
	}
	p.pixels(ui, "w-full h-full", app, draw_formula_line)
	p.end(ui)
}

// draw_formula_line shows the raw input of the active cell, and the live edit
// buffer while the formula bar has it.
draw_formula_line :: proc(c: ^p.Canvas, r: p.Rect, app: ^App) {
	if app.mode == .Edit {
		// The bar mirrors an in-cell edit, caret and all; the caret is only
		// drawn here when the bar is the one being typed into.
		draw_line_edit(c, r, app, &app.edit, "", app.pal.fg, app.in_bar)
		return
	}
	// A read-only view of the cell, which is a Line only so one drawing
	// routine serves both.
	tmp := Line{}
	defer delete(tmp.buf)
	line_set(&tmp, input_at(&app.sh, app.cur))
	tmp.caret = 0
	draw_line_edit(c, r, app, &tmp, "", app.pal.fg, false)
}

PALETTE_ROWS :: 11

palette_overlay :: proc(ui: ^p.Ctx, app: ^App) {
	p.div(ui, "absolute inset-0 z-50 bg-black/35 items-center justify-center")
	defer p.end(ui)

	p.col(ui, "w-[560] max-w-full gap-2 p-3 rounded-xl border border-border bg-popover shadow-2xl")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground")
	p.div(ui, "flex-1 h-6 overflow-hidden")
	p.pixels(ui, "w-full h-full", app, draw_palette_line)
	p.end(ui)
	p.end(ui)

	sc.separator(ui, .Horizontal)

	rows := make([dynamic]Cmd_Row, 0, len(COMMANDS), context.temp_allocator)
	palette_matches(app, &rows)
	if len(rows) == 0 {
		p.text(ui, "No command matches", "text-xs text-muted-foreground py-2")
		return
	}
	sel := clamp(app.pal_sel, 0, len(rows) - 1)
	// Only a window of the list is drawn, scrolled to keep the selection in it.
	first := clamp(sel - PALETTE_ROWS / 2, 0, max(0, len(rows) - PALETTE_ROWS))
	last := min(first + PALETTE_ROWS, len(rows))

	p.col(ui, "gap-0.5 w-full")
	defer p.end(ui)
	for i in first ..< last {
		row := rows[i]
		p.row(ui, "items-center gap-2 px-2 h-7 rounded-md w-full shrink-0")
		if i == sel {
			p.apply(ui, "bg-accent")
		}
		p.text(ui, row.label, i == sel ? "text-sm font-medium whitespace-nowrap" : "text-sm whitespace-nowrap")
		p.spacer(ui)
		sc.kbd(ui, row.keys)
		p.end(ui)
	}
	if last < len(rows) {
		p.textf(ui, "text-xs text-muted-foreground px-2", "%d more", len(rows) - last)
	}
}

draw_palette_line :: proc(c: ^p.Canvas, r: p.Rect, app: ^App) {
	draw_line_edit(c, r, app, &app.pline, "Type a command", app.pal.fg, true)
}

draw_prompt_line :: proc(c: ^p.Canvas, r: p.Rect, app: ^App) {
	draw_line_edit(c, r, app, &app.pline, "path or reference", app.pal.fg, true)
}

// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(
		ui,
		p.concat(
			ui,
			"shrink-0 items-center gap-4 px-3 border-t border-border bg-card overflow-hidden h-[",
			int_text(int(STATUS_H)),
			"]",
		),
	)
	defer p.end(ui)

	hint := ""
	switch app.mode {
	case .Edit:
		hint = "Edit  —  Enter commits, Tab commits right, Esc cancels"
	case .Prompt:
		hint = "Enter confirms, Esc cancels"
	case .Palette:
		hint = "Type to filter, arrows to choose, Enter runs it"
	case .Help, .Nav:
		hint = app.status
	}
	if hint != "" {
		p.text(ui, hint, "text-xs text-foreground whitespace-nowrap truncate max-w-[420] shrink-0")
		sc.separator(ui, .Vertical, "h-3")
	}

	st := selection_stats(&app.sh, sel_rect(app))
	if st.count > 0 {
		stat(ui, "Sum", general_text(round_sig(st.sum, 12)))
		stat(ui, "Average", general_text(round_sig(st.avg, 12)))
		stat(ui, "Min", general_text(round_sig(st.lo, 12)))
		stat(ui, "Max", general_text(round_sig(st.hi, 12)))
	}
	stat(ui, "Count", int_text(st.count))
	stat(ui, "Filled", int_text(st.counta))

	p.spacer(ui)
	if app.path != "" {
		p.text(ui, app.path, "text-xs text-muted-foreground whitespace-nowrap truncate max-w-[340] shrink-0")
	} else {
		p.text(ui, "not saved", "text-xs text-muted-foreground whitespace-nowrap shrink-0")
	}
}

stat :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	p.text(ui, label, "text-xs text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "text-xs font-medium font-mono whitespace-nowrap")
	p.end(ui)
}

// ---------------------------------------------------------------------------

prompt_overlay :: proc(ui: ^p.Ctx, app: ^App) {
	p.div(ui, "absolute inset-0 z-50 bg-black/35 items-center justify-center")
	defer p.end(ui)

	p.col(ui, "w-[560] max-w-full gap-3 p-4 rounded-xl border border-border bg-popover shadow-2xl")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	p.icon(ui, app.prompt == .Goto ? sc.ICON_SEARCH : sc.ICON_FILE_TEXT, "size-4 text-muted-foreground")
	p.text(ui, prompt_title(app.prompt), "text-sm font-semibold")
	p.end(ui)

	p.div(ui, "w-full h-8 rounded-lg border border-input border-ring ring-3 ring-ring/50 overflow-hidden")
	if app.pline_new {
		// Show the suggestion as a suggestion: it goes when you start typing.
		p.apply(ui, "bg-accent")
	}
	p.pixels(ui, "w-full h-full", app, draw_prompt_line)
	p.end(ui)

	p.row(ui, "items-center gap-2")
	sc.kbd(ui, "Enter")
	p.text(ui, "confirm", "text-xs text-muted-foreground")
	sc.kbd(ui, "Esc")
	p.text(ui, "cancel", "text-xs text-muted-foreground")
	p.spacer(ui)
	if app.prompt == .Export_CSV {
		p.text(
			ui,
			"the selection, or the whole sheet when one cell is active",
			"text-xs text-muted-foreground",
		)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------

Key_Row :: struct {
	keys: string,
	what: string,
}

HELP_NAV := [?]Key_Row {
	{"Arrows", "move the cursor"},
	{"Shift+Arrows", "extend the selection"},
	{"Ctrl+Arrows", "jump to the edge of the data"},
	{"Tab / Shift+Tab", "move right / left"},
	{"Home / Ctrl+Home", "first column / A1"},
	{"Ctrl+End", "last used cell"},
	{"PgUp / PgDn", "a screen at a time"},
	{"Ctrl+A", "select the used range"},
	{"Ctrl+G", "go to a reference"},
	{"F10", "the command palette"},
}

HELP_EDIT := [?]Key_Row {
	{"type", "replace the cell"},
	{"F2", "edit in the cell"},
	{"Ctrl+F2", "edit in the formula bar"},
	{"Enter / Tab", "commit and move"},
	{"Esc", "cancel"},
	{"Delete", "clear the selection"},
	{"Ctrl+C / X / V", "copy / cut / paste (TSV)"},
	{"Ctrl+Shift+V", "paste from another app"},
	{"Ctrl+D / Ctrl+R", "fill down / right"},
	{"Ctrl+Z / Ctrl+Y", "undo / redo"},
}

HELP_FORMAT := [?]Key_Row {
	{"Alt+0 .. Alt+5", "pick the number format"},
	{"Alt+. / Alt+,", "more / fewer decimals"},
	{"Ctrl+B / Ctrl+I", "bold / italic"},
	{"Alt+Arrows", "align left, right, centre, automatic"},
	{"Alt+Shift+Arrows", "column width / row height"},
}

HELP_DOC := [?]Key_Row {
	{"Alt+R / Alt+Shift+R", "insert / delete rows"},
	{"Alt+C / Alt+Shift+C", "insert / delete columns"},
	{"Ctrl+S / Ctrl+Shift+S", "save / save as (JSON)"},
	{"Ctrl+O", "open"},
	{"Ctrl+E / Ctrl+Shift+O", "export / import CSV"},
	{"Ctrl+N", "new sheet"},
	{"Ctrl+Q", "quit"},
}

help_overlay :: proc(ui: ^p.Ctx, app: ^App) {
	p.div(ui, "absolute inset-0 z-50 bg-black/45 items-center justify-center")
	defer p.end(ui)

	p.col(ui, "w-[880] max-w-full gap-3 p-5 rounded-xl border border-border bg-popover shadow-2xl")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	p.icon(ui, sc.ICON_COLUMNS_3, "size-4")
	p.text(ui, "Sheets — keyboard", "text-base font-semibold")
	p.spacer(ui)
	p.text(ui, "Esc closes", "text-xs text-muted-foreground")
	p.end(ui)

	sc.separator(ui, .Horizontal)

	p.row(ui, "gap-6 items-start")
	help_column(ui, "Navigate", HELP_NAV[:])
	help_column(ui, "Edit", HELP_EDIT[:])
	p.end(ui)

	sc.separator(ui, .Horizontal)

	p.row(ui, "gap-6 items-start")
	help_column(ui, "Format", HELP_FORMAT[:])
	help_column(ui, "Document", HELP_DOC[:])
	p.end(ui)

	sc.separator(ui, .Horizontal)
	p.text(
		ui,
		"Formulas: + - * / ^ % & = <> < <= > >=,  A1  $A$1  A1:B10  A:A,  and SUM AVERAGE MIN MAX COUNT COUNTA IF AND OR NOT ABS ROUND FLOOR CEILING SQRT POWER MOD CONCAT LEN LEFT RIGHT MID UPPER LOWER TRIM TODAY NOW DATE YEAR MONTH DAY VLOOKUP INDEX MATCH IFERROR IS*",
		"text-xs text-muted-foreground",
	)
}

help_column :: proc(ui: ^p.Ctx, title: string, rows: []Key_Row) {
	p.col(ui, "flex-1 gap-1.5 min-w-0")
	defer p.end(ui)
	p.text(ui, title, "text-xs font-semibold uppercase tracking-wide text-muted-foreground")
	for r in rows {
		p.row(ui, "items-center gap-2 min-w-0 w-full")
		p.div(ui, "w-[168] shrink-0")
		p.text(ui, r.keys, "text-xs font-mono whitespace-nowrap")
		p.end(ui)
		p.text(ui, r.what, "text-xs text-muted-foreground truncate")
		p.end(ui)
	}
}

_ :: strings
