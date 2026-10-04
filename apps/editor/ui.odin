// The frame: title bar, gutter, text, prompt, status bar and the overlays.
package main

import "core:math"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// One line, ready to draw
//
// `exp` is the line with tabs expanded to spaces; `start[i]` is the byte offset
// of display cell i inside it and `kind[i]` the token that owns that cell. The
// renderer slices by cell, so horizontal scrolling costs nothing and a run of
// equally coloured cells becomes one text node.
// ---------------------------------------------------------------------------

Disp :: struct {
	exp:   []u8,
	start: []int,
	kind:  []Tok,
}

build_disp :: proc(ed: ^Editor, li: int) -> Disp {
	src := buf_line(&ed.buf, li)

	kinds := make([]Tok, len(src), context.temp_allocator)
	if ed.syntax && ed.odin {
		toks := make([dynamic]Token, 0, 48, context.temp_allocator)
		lex_line(src, lex_state_at(&ed.buf, li), &toks)
		for t in toks {
			for i in t.from ..< min(t.to, len(src)) {
				kinds[i] = t.kind
			}
		}
	}

	exp := make([dynamic]u8, 0, len(src) + 16, context.temp_allocator)
	start := make([dynamic]int, 0, len(src) + 17, context.temp_allocator)
	cell := make([dynamic]Tok, 0, len(src) + 16, context.temp_allocator)

	col := 0
	i := 0
	for i < len(src) {
		k := kinds[i]
		if src[i] == '\t' {
			n := TAB_W - col % TAB_W
			for _ in 0 ..< n {
				append(&start, len(exp))
				append(&cell, k)
				append(&exp, ' ')
				col += 1
			}
			i += 1
			continue
		}
		j := rune_right(src, i)
		append(&start, len(exp))
		append(&cell, k)
		append(&exp, ..transmute([]u8)src[i:j])
		col += 1
		i = j
	}
	append(&start, len(exp))
	return {exp[:], start[:], cell[:]}
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, ed: ^Editor) {
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	title_bar(ui, ed)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	gutter_pane(ui, ed)
	text_pane(ui, ed)
	p.end(ui)

	if ed.prompt != .None {
		prompt_bar(ui, ed)
	}
	status_bar(ui, ed)

	switch ed.mode {
	case .Palette:
		palette(ui, ed)
	case .Help:
		help_sheet(ui, ed)
	case .Confirm_Quit:
		quit_dialog(ui, ed)
	case .Edit, .Prompt:
	}
	toast(ui, ed)

	// Last, so it sits over everything, and inside the root that is already
	// `relative` so its absolute insets resolve against the window.
	pick_overlay(ui, ed)
}

// ---------------------------------------------------------------------------
// Title bar
// ---------------------------------------------------------------------------

title_bar :: proc(ui: ^p.Ctx, ed: ^Editor) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-b border-border",
			TITLE_H,
		),
	)
	defer p.end(ui)

	p.div(
		ui,
		"flex-row size-7 shrink-0 items-center justify-center rounded-md bg-background border border-border",
	)
	p.icon(ui, ed.odin ? ICON_CODE : ICON_FILE_TEXT, "size-3.5 text-muted-foreground")
	p.end(ui)

	name := ed.buf.path == "" ? "Untitled" : base_of(ed.buf.path)
	dir := dir_of(ed.buf.path)

	p.col(ui, "min-w-0 flex-1 gap-px")
	p.row(ui, "items-center gap-1.5 min-w-0")
	p.text(ui, name, "truncate text-[13.5] font-semibold text-foreground max-w-[420]")
	if buf_dirty(&ed.buf) {
		p.div(ui, "size-1.5 rounded-full bg-selection shrink-0")
		p.end(ui)
	}
	p.end(ui)
	p.text(
		ui,
		dir == "" ? "not saved anywhere yet" : dir,
		"truncate text-[11] text-muted-foreground",
	)
	p.end(ui)

	if ed.odin {
		sc.badge(ui, "Odin", .Secondary)
	}
	sc.badge(ui, ed.buf.encoding, .Outline)

	p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
	sc.kbd(ui, "Esc")
	p.text(ui, "commands", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Gutter and text
// ---------------------------------------------------------------------------

gutter_pane :: proc(ui: ^p.Ctx, ed: ^Editor) {
	p.col(
		ui,
		tfmt(
			"w-[%d] shrink-0 h-full bg-sidebar border-r border-border overflow-hidden",
			int(ed.gutter),
		),
	)
	defer p.end(ui)

	if !ed.numbers {
		return
	}
	n := buf_lines(&ed.buf)
	for row in 0 ..< ed.rows {
		li := ed.top + row
		if li >= n {
			break
		}
		here := li == ed.cur.line
		p.row(ui, tfmt("h-[%d] w-full shrink-0 items-center justify-end pr-2", LINE_H))
		p.textf(
			ui,
			here \
			? tfmt("%s text-foreground font-medium", MONO) \
			: tfmt("%s text-muted-foreground/70", MONO),
			"%d",
			li + 1,
		)
		p.end(ui)
	}
}

text_pane :: proc(ui: ^p.Ctx, ed: ^Editor) {
	idx := p.col(ui, "flex-1 min-w-0 h-full relative overflow-hidden pl-2")
	defer p.end(ui)
	if p.clickable(ui, idx) {
		// A click puts the caret where it landed, which is the one pointer
		// gesture a text editor cannot do without.
		r := p.rect_of(ui, p.node_id(ui, idx))
		m := p.mouse_pos(ui)
		li := clamp(ed.top + int((m.y - r.y) / LINE_H), 0, max(0, buf_lines(&ed.buf) - 1))
		dc := ed.left + int((m.x - r.x) / ed.cw + 0.5)
		ed.cur = pos_clamp(&ed.buf, {li, byte_of(buf_line(&ed.buf, li), max(0, dc))})
		ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
		clear_sel(ed)
	}

	needle := ed.prompt == .Find || ed.prompt == .Replace ? string(ed.find[:]) : ""
	sel_lo, sel_hi, has_sel := sel_range(ed)
	n := buf_lines(&ed.buf)
	caret_on := math.mod(f64(p.elapsed(ui)), 1.06) < 0.62
	if ed.mode == .Edit {
		p.redraw(ui)
	}

	for row in 0 ..< ed.rows {
		li := ed.top + row
		if li >= n {
			break
		}
		src := buf_line(&ed.buf, li)
		d := build_disp(ed, li)
		ncells := len(d.kind)

		p.key(ui, tfmt("ln:%d", li))
		lr := p.row(ui, tfmt("h-[%d] w-full shrink-0 relative items-center", LINE_H))
		if li == ed.cur.line && ed.mode != .Palette {
			p.apply(ui, "bg-muted/70", lr)
		}

		// Every match of the live search, as a field of highlights...
		if needle != "" {
			at := 0
			for {
				f := line_find(src, needle, at, true)
				if f < 0 {
					break
				}
				band(ui, ed, disp_of(src, f), disp_of(src, f + len(needle)), "bg-amber-300/70")
				at = f + max(1, len(needle))
			}
		}

		// ...and the selection on top of it, so the match the caret is on is
		// the one that looks selected.
		if has_sel && li >= sel_lo.line && li <= sel_hi.line {
			c0 := li == sel_lo.line ? disp_of(src, sel_lo.col) : 0
			c1 := li == sel_hi.line ? disp_of(src, sel_hi.col) : ncells + 1
			band(ui, ed, c0, c1, "bg-selection/30")
		}

		// The text itself, sliced to the visible cells and coalesced into one
		// node per run of a single token kind.
		p.row(ui, "h-full items-center shrink-0")
		from := min(ed.left, ncells)
		to := min(ed.left + ed.cols + 1, ncells)
		i := from
		for i < to {
			k := d.kind[i]
			j := i
			for j < to && d.kind[j] == k {
				j += 1
			}
			p.text(ui, string(d.exp[d.start[i]:d.start[j]]), tfmt("%s %s", MONO, tok_class(k)))
			i = j
		}
		p.end(ui)

		// The caret.
		if li == ed.cur.line && caret_on && ed.mode == .Edit {
			dc := disp_of(src, ed.cur.col)
			if dc >= ed.left && dc <= ed.left + ed.cols {
				cb := p.div(ui, "absolute w-[2] bg-selection rounded-[1]")
				cs := p.style(ui, cb)
				cs.inset[p.LEFT] = p.px(f32(dc - ed.left) * ed.cw)
				cs.inset[p.TOP] = p.px(1)
				cs.h = p.px(LINE_H - 2)
				p.end(ui)
			}
		}
		p.end(ui)
	}

	// The vertical scroll indicator. The list is virtual, so palmy's own
	// scroll container never sees the full height and this is drawn by hand.
	if n > ed.rows {
		view_h := f32(ed.rows * LINE_H)
		frac := f32(ed.rows) / f32(n)
		h := max(28, view_h * frac)
		t := f32(ed.top) / f32(max(1, n - ed.rows))
		sb := p.div(ui, "absolute right-[3] w-[5] rounded-full bg-foreground/20")
		s := p.style(ui, sb)
		s.inset[p.TOP] = p.px((view_h - h) * t + 2)
		s.h = p.px(h - 4)
		p.end(ui)
	}
}

// band draws one highlighted run of cells on the current line.
band :: proc(ui: ^p.Ctx, ed: ^Editor, c0, c1: int, class: string) {
	a := clamp(c0, ed.left, ed.left + ed.cols + 1)
	b := clamp(c1, ed.left, ed.left + ed.cols + 1)
	if b <= a {
		return
	}
	idx := p.div(ui, tfmt("absolute rounded-[2] %s", class))
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(f32(a - ed.left) * ed.cw)
	s.inset[p.TOP] = p.px(0)
	s.w = p.px(f32(b - a) * ed.cw)
	s.h = p.px(LINE_H)
	s.no_hit = true
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Prompt bar
// ---------------------------------------------------------------------------

prompt_bar :: proc(ui: ^p.Ctx, ed: ^Editor) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-muted/60 border-t border-border",
			FOOT_H,
		),
	)
	defer p.end(ui)

	switch ed.prompt {
	case .Find:
		p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
		mini(ui, "Find", string(ed.find[:]), true, 300)
		matches_label(ui, ed)
		p.spacer(ui, "flex-1")
		foot_hint(ui, "Enter", "next")
		foot_hint(ui, "Tab", "replace")
		foot_hint(ui, "Esc", "close")
	case .Replace:
		p.icon(ui, ICON_REPLACE, "size-3.5 shrink-0 text-muted-foreground")
		mini(ui, "Find", string(ed.find[:]), ed.field == .Primary, 220)
		mini(ui, "Replace with", string(ed.repl[:]), ed.field == .Secondary, 220)
		matches_label(ui, ed)
		p.spacer(ui, "flex-1")
		foot_hint(ui, "Enter", "replace")
		foot_hint(ui, "F4", "all")
		foot_hint(ui, "Tab", "field")
	case .Goto:
		p.icon(ui, ICON_HASH, "size-3.5 shrink-0 text-muted-foreground")
		mini(ui, tfmt("Line 1–%d", buf_lines(&ed.buf)), string(ed.target[:]), true, 180)
		p.spacer(ui, "flex-1")
		foot_hint(ui, "Enter", "go")
		foot_hint(ui, "Esc", "cancel")
	case .Save_As:
		p.icon(ui, ICON_SAVE, "size-3.5 shrink-0 text-muted-foreground")
		mini(ui, "Save as path", string(ed.target[:]), true, 520)
		p.spacer(ui, "flex-1")
		foot_hint(ui, "Enter", "save")
		foot_hint(ui, "Esc", "cancel")
	case .None:
	}
}

matches_label :: proc(ui: ^p.Ctx, ed: ^Editor) {
	if len(ed.find) == 0 {
		return
	}
	n := ed.matches
	p.text(
		ui,
		n == 0 ? "no matches" : tfmt("%d match%s", n, n == 1 ? "" : "es"),
		n == 0 \
		? "text-[11.5] text-destructive whitespace-nowrap shrink-0" \
		: "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
	)
}

// mini is a one-line field: palmy's text_field owns its own focus and caret,
// and this app drives focus from its mode, so the field is drawn here.
mini :: proc(ui: ^p.Ctx, label, value: string, active: bool, w: int) {
	idx := p.row(
		ui,
		tfmt(
			"h-[24] w-[%d] shrink-0 items-center gap-1 px-2 rounded-md border border-input bg-background overflow-hidden",
			w,
		),
	)
	if active {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	defer p.end(ui)

	if value == "" {
		p.text(ui, label, tfmt("%s text-muted-foreground/70", MONO))
	} else {
		p.text(ui, value, tfmt("%s text-foreground", MONO))
	}
	if active {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[14] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
}

foot_hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/80 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, ed: ^Editor) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border",
			STATUS_H,
		),
	)
	defer p.end(ui)

	line := buf_line(&ed.buf, ed.cur.line)
	seg(ui, tfmt("Ln %d, Col %d", ed.cur.line + 1, disp_of(line, ed.cur.col) + 1))

	if lo, hi, ok := sel_range(ed); ok {
		n := len(buf_text(&ed.buf, lo, hi, context.temp_allocator))
		lines := hi.line - lo.line + 1
		seg(ui, lines > 1 ? tfmt("%d selected, %d lines", n, lines) : tfmt("%d selected", n))
	}
	if buf_dirty(&ed.buf) {
		p.text(ui, "modified", "text-[11.5] text-selection font-medium whitespace-nowrap shrink-0")
	}

	p.spacer(ui, "flex-1")

	if ed.stats {
		p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0", "%.0f fps", p.frames_per_second(ui))
	}
	seg(ui, tfmt("%d lines", buf_lines(&ed.buf)))
	seg(ui, human_bytes(buf_byte_size(&ed.buf)))
	seg(ui, ed.buf.encoding)
	seg(ui, ed.buf.eol == .CRLF ? "CRLF" : "LF")
	seg(ui, tfmt("Tab %d", TAB_W))
	seg(ui, ed.odin && ed.syntax ? "Odin" : "Plain Text")
}

seg :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0")
}

human_bytes :: proc(n: int) -> string {
	switch {
	case n < 1024:
		return tfmt("%d B", n)
	case n < 1024 * 1024:
		return tfmt("%.1f kB", f64(n) / 1024)
	}
	return tfmt("%.1f MB", f64(n) / (1024 * 1024))
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

PAL_W :: 560
PAL_ROWS :: 9

palette :: proc(ui: ^p.Ctx, ed: ^Editor) {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-foreground/10")
	if p.clickable(ui, scrim) {
		ed.mode = .Edit
	}
	p.end(ui)

	items := palette_items(ed)
	ed.pal_sel = clamp(ed.pal_sel, 0, max(0, len(items) - 1))
	first := max(0, min(ed.pal_sel - PAL_ROWS / 2, len(items) - PAL_ROWS))
	last := min(first + PAL_ROWS, len(items))

	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", PAL_W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - PAL_W) / 2))
	s.inset[p.TOP] = p.px(72)
	defer p.end(ui)

	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	defer p.end(ui)

	// The filter row.
	p.row(ui, "h-[44] w-full shrink-0 items-center gap-2 px-3 border-b border-border")
	p.icon(ui, ICON_COMMAND, "size-4 shrink-0 text-muted-foreground")
	f := string(ed.pal_filter[:])
	p.text(
		ui,
		f == "" ? "Type a command" : f,
		f == "" \
		? "shrink-0 text-[13.5] text-muted-foreground/70 whitespace-nowrap" \
		: "shrink-0 text-[13.5] text-foreground whitespace-nowrap",
	)
	p.redraw(ui)
	if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
		p.div(ui, "w-px h-[16] bg-foreground shrink-0")
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	sc.kbd(ui, "Esc")
	p.end(ui)

	if len(items) == 0 {
		p.col(ui, "w-full items-center justify-center gap-1 py-8")
		p.icon(ui, ICON_SEARCH, "size-5 text-muted-foreground/60")
		p.text(ui, "No command matches", "text-[12.5] text-muted-foreground")
		p.end(ui)
		return
	}

	p.col(ui, "w-full p-1.5 gap-0.5")
	for k in first ..< last {
		it := items[k]
		on := k == ed.pal_sel
		p.key(ui, it.label)
		idx := p.row(ui, "h-[32] w-full shrink-0 items-center gap-2.5 px-2 rounded-md transition cursor-pointer")
		if on {
			p.apply(ui, "bg-selection text-white", idx)
		} else {
			p.apply(ui, "hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			ed.mode = .Edit
			run_cmd(ed, it.cmd)
		}
		p.icon(ui, it.icon, on ? "size-3.5 shrink-0 text-white" : "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, it.label, "flex-1 min-w-0 truncate text-[13] whitespace-nowrap")
		if it.keys != "" {
			p.text(
				ui,
				it.keys,
				on \
				? "text-[11] text-white/70 whitespace-nowrap shrink-0" \
				: "text-[11] text-muted-foreground whitespace-nowrap shrink-0",
			)
		}
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[28] w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-muted/40")
	p.textf(
		ui,
		"text-[11] text-muted-foreground whitespace-nowrap shrink-0",
		"%d of %d",
		ed.pal_sel + 1,
		len(items),
	)
	p.spacer(ui, "flex-1")
	foot_hint(ui, "Up Down", "move")
	foot_hint(ui, "Enter", "run")
	p.end(ui)
}

HELP := [?][2]string {
	{"Esc / Ctrl P", "command palette"},
	{"Ctrl S", "save"},
	{"Ctrl Shift S", "save as"},
	{"Ctrl F", "find"},
	{"F3", "find next"},
	{"Ctrl H", "find and replace"},
	{"Ctrl L", "go to line"},
	{"Ctrl Z / Ctrl Y", "undo, redo"},
	{"Ctrl X / C / V", "cut, copy, paste"},
	{"Ctrl A", "select all"},
	{"Ctrl D / Ctrl K", "duplicate, delete line"},
	{"Shift + motion", "extend the selection"},
	{"Ctrl Left/Right", "word left, word right"},
	{"Home / End", "line start, line end"},
	{"Ctrl Home / End", "file start, file end"},
	{"PgUp / PgDn", "page up, page down"},
	{"Tab / Shift Tab", "indent, outdent"},
	{"F5", "reload from disk"},
	{"F1", "this list"},
	{"Ctrl Q", "quit"},
}

help_sheet :: proc(ui: ^p.Ctx, ed: ^Editor) {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-foreground/15")
	if p.clickable(ui, scrim) {
		ed.mode = .Edit
	}
	p.end(ui)

	W :: 620
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - W) / 2))
	s.inset[p.TOP] = p.px(max(8, (win.y - 480) / 2))
	defer p.end(ui)

	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3")
	p.icon(ui, ICON_KEYBOARD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, "Keyboard", "text-[15] font-semibold")
	p.text(ui, "Every command has a key, and every key is listed.", "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full px-5 pb-5 gap-6 items-start")
	half := (len(HELP) + 1) / 2
	for c in 0 ..< 2 {
		p.col(ui, "flex-1 min-w-0 gap-1.5")
		lo := c == 0 ? 0 : half
		hi := c == 0 ? half : len(HELP)
		for i in lo ..< hi {
			p.row(ui, "w-full items-center gap-2")
			p.row(ui, "w-[130] shrink-0 justify-end")
			sc.kbd(ui, HELP[i][0])
			p.end(ui)
			p.text(ui, HELP[i][1], "flex-1 min-w-0 text-[12] text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center justify-end gap-2 px-5 border-t border-border bg-muted/40")
	foot_hint(ui, "Esc", "close")
	p.end(ui)
}

QUIT_BUTTONS := [?]string{"Save and quit", "Discard changes", "Cancel"}

quit_dialog :: proc(ui: ^p.Ctx, ed: ^Editor) {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-foreground/20")
	p.end(ui)

	W :: 440
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", W))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - W) / 2))
	s.inset[p.TOP] = p.px(max(8, win.y / 2 - 120))
	defer p.end(ui)

	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl p-6 gap-4 items-center")
	defer p.end(ui)

	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-amber-100 shrink-0")
	p.icon(ui, ICON_TRIANGLE_ALERT, "size-5 text-amber-600")
	p.end(ui)

	p.col(ui, "items-center gap-1.5 w-full")
	p.text(ui, "Unsaved changes", "text-[16] font-semibold")
	p.text(
		ui,
		tfmt(
			"%s has edits that are not on disk.",
			ed.buf.path == "" ? "This buffer" : base_of(ed.buf.path),
		),
		"max-w-[340] text-center text-[12.5] text-muted-foreground",
	)
	p.end(ui)

	p.col(ui, "w-full gap-1.5")
	for label, i in QUIT_BUTTONS {
		on := i == ed.quit_sel
		p.key(ui, label)
		idx := p.row(ui, "h-[34] w-full items-center justify-center rounded-lg border border-border transition cursor-pointer")
		switch {
		case on && i == 1:
			p.apply(ui, "bg-destructive/15 border-destructive text-destructive ring-3 ring-destructive/25", idx)
		case on:
			p.apply(ui, "bg-selection border-selection text-white ring-3 ring-selection/30", idx)
		case:
			p.apply(ui, "bg-background hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			ed.quit_sel = i
		}
		p.text(ui, label, "text-[13] font-medium whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "items-center gap-3 pt-1")
	foot_hint(ui, "Left Right", "choose")
	foot_hint(ui, "Enter", "confirm")
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, ed: ^Editor) {
	if ed.toast == "" {
		return
	}
	if ed.toast_at == 0 {
		ed.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - ed.toast_at > 2.8 {
		delete(ed.toast)
		ed.toast = ""
		ed.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(
		ui,
		"absolute z-30 right-[16] bottom-[40] max-w-[460] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg",
	)
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-selection")
	p.text(ui, ed.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
