// The chrome: two toolbar rows, the find bar, the status bar and the two
// overlays. palmy has no xdg_popup, so the help sheet and the path prompt are
// absolutely positioned inside the window — which is the documented way to do
// it here, not a workaround.
package main

import "core:fmt"
import p "palmy:."
import sc "shadcn:."

TOP1 :: f32(40)
TOP2 :: f32(38)
TABLEBAR :: f32(36)
FINDBAR :: f32(40)
STATUS :: f32(26)

chrome_top :: proc(st: ^State) -> f32 {
	h := TOP1 + TOP2 + 1 + (st.collab.on ? 3 : 0)
	if in_table(st) {
		h += TABLEBAR + 1
	}
	if st.mode == .Find {
		h += FINDBAR + 1
	}
	return h
}

// measure fixes the workspace rectangle before anything is built, because the
// keyboard and the pointer both need it in the same frame they are handled.
measure :: proc(ui: ^p.Ctx, st: ^State) {
	win := p.size(ui)
	top := chrome_top(st)
	// The problems panel takes its width out of the workspace, so the page
	// stays centred in what is left rather than hiding behind the panel.
	side := (st.prose.show ? PROSE_W + 1 : 0) + collab_side_w(st)
	st.view = {0, top, max(120, win.x - side), max(40, win.y - top - 1 - STATUS)}
	clamp_scroll(st)
}

frame :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	collab_band(ui, st)
	toolbar_top(ui, st)
	toolbar_format(ui, st)
	sc.separator(ui)

	// The table strip only exists while the caret is in a grid, which is both
	// how every word processor does it and the only way these nine commands
	// fit on a 1280px window alongside everything else.
	if in_table(st) {
		toolbar_table(ui, st)
		sc.separator(ui)
	}

	if st.mode == .Find {
		find_bar(ui, st)
		sc.separator(ui)
	}

	p.row(ui, "flex-1 w-full min-h-0 overflow-hidden")
	p.pixels(
		ui,
		"flex-1 h-full overflow-hidden cursor-text",
		st,
		proc(c: ^p.Canvas, r: p.Rect, s: ^State) {
			draw_workspace(c, r, s)
		},
	)
	if st.prose.show {
		// Vertical, explicitly: shadcn's separator defaults to horizontal and
		// applies `w-full` *after* the caller's class, which inside a row
		// takes the whole width and leaves both siblings at zero.
		sc.separator(ui, .Vertical)
		prose_panel(ui, st)
	}
	if st.collab.on && st.collab.panel != .None {
		sc.separator(ui, .Vertical)
		collab_panel(ui, st)
	}
	p.end(ui)

	sc.separator(ui)
	status_bar(ui, st)

	if st.mode == .Prompt {
		prompt_overlay(ui, st)
	}
	if st.help {
		help_overlay(ui, st)
	}
}

// ---------------------------------------------------------------------------
// Toolbar pieces
// ---------------------------------------------------------------------------

tool_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, on := false, enabled := true) -> bool {
	p.key(ui, key)
	idx := p.div(
		ui,
		"flex-row size-7 shrink-0 items-center justify-center rounded-md transition cursor-pointer",
	)
	fired := false
	if !enabled {
		p.apply(ui, "text-muted-foreground/35", idx)
	} else if on {
		p.apply(ui, "bg-primary text-primary-foreground", idx)
		fired = p.clickable(ui, idx)
	} else {
		p.apply(ui, "text-foreground hover:bg-accent", idx)
		fired = p.clickable(ui, idx)
	}
	p.icon(ui, ic, "size-4")
	p.end(ui)
	return fired && enabled
}

pill :: proc(ui: ^p.Ctx, key, label: string, width := "", chevron := true) -> bool {
	p.key(ui, key)
	idx := p.row(
		ui,
		"h-7 shrink-0 items-center gap-1 px-2 rounded-md border border-input bg-background hover:bg-accent transition cursor-pointer",
	)
	if width != "" {
		p.apply(ui, width, idx)
	}
	fired := p.clickable(ui, idx)
	p.text(ui, label, "text-[12.5] whitespace-nowrap")
	p.style(ui).shrink = 0
	if chevron {
		p.spacer(ui)
		p.icon(ui, ICON_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	}
	p.end(ui)
	return fired
}

// vrule is a short vertical separator. shadcn's `separator` applies its
// orientation sizing *after* the caller's class — that is faithful to the TSX,
// where the attribute selector outranks a utility — so `self-stretch` always
// wins and a caller cannot ask for a 16px rule. Nesting it in a fixed-height
// box gives it something short to stretch against.
// text_button is a labelled button that reports its click. shadcn's `button`
// draws one but returns nothing, so this wraps the same classes around
// `p.clickable` the way `tool_button` does for the icon buttons.
text_button :: proc(ui: ^p.Ctx, key, label: string, primary := false) -> bool {
	p.key(ui, key)
	idx := p.row(
		ui,
		"h-8 shrink-0 items-center justify-center px-3 rounded-md border transition cursor-pointer",
	)
	if primary {
		p.apply(ui, "bg-primary text-primary-foreground border-primary hover:bg-primary/90", idx)
	} else {
		p.apply(ui, "bg-background text-foreground border-input hover:bg-accent", idx)
	}
	fired := p.clickable(ui, idx)
	p.text(ui, label, "text-[12.5] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	return fired
}

vrule :: proc(ui: ^p.Ctx) {
	p.div(ui, "flex-row h-4 shrink-0 items-center mx-1")
	sc.separator(ui, .Vertical)
	p.end(ui)
}

swatch :: proc(ui: ^p.Ctx, key: string, rgb: u32, on: bool) -> bool {
	p.key(ui, key)
	idx := p.div(ui, "size-4 shrink-0 rounded-[3] border border-black/20 cursor-pointer transition")
	if on {
		p.apply(ui, "ring-2 ring-ring/70", idx)
	}
	p.style(ui, idx).bg = p.flat(p.hex(rgb))
	fired := p.clickable(ui, idx)
	p.end(ui)
	return fired
}

toolbar_top :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%.0f] w-full shrink-0 items-center gap-2 px-3", TOP1))
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-1.5")
	p.icon(ui, ICON_FILE_TEXT, "size-4 shrink-0 text-primary")
	p.text(ui, "Docs", "text-[13] font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	vrule(ui)

	if tool_button(ui, "open", ICON_FOLDER_OPEN) {
		open_prompt(st, .Open)
	}
	if tool_button(ui, "save", ICON_SAVE) {
		if st.path == "" {
			open_prompt(st, .Save_As)
		} else {
			do_save(st, st.path)
		}
	}
	if tool_button(ui, "md", ICON_DOWNLOAD) {
		open_prompt(st, .Export_Md)
	}
	if tool_button(ui, "pdf", ICON_PRINTER) {
		open_prompt(st, .Export_Pdf)
	}
	if tool_button(ui, "png", ICON_IMAGE) {
		open_prompt(st, .Export_Png)
	}

	vrule(ui)

	if tool_button(ui, "undo", ICON_ROTATE_CCW, false, st.collab.on ? crdt_can_undo(st) : history_can_undo(&st.hist)) {
		do_undo(st)
	}
	if tool_button(ui, "redo", ICON_ROTATE_CW, false, st.collab.on ? crdt_can_redo(st) : history_can_redo(&st.hist)) {
		do_redo(st)
	}

	p.spacer(ui)

	p.row(ui, "shrink-0 items-center gap-1.5")
	collab_identity_chip(ui, st)
	p.text(ui, doc_title(st), "text-[12.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if st.modified {
		p.div(ui, "size-1.5 rounded-full bg-primary shrink-0")
		p.end(ui)
	}
	p.end(ui)

	p.spacer(ui)

	if st.collab.on {
		collab_presence(ui, st)
		vrule(ui)
		collab_toolbar_buttons(ui, st)
		vrule(ui)
	}
	if tool_button(ui, "find", ICON_SEARCH, st.mode == .Find) {
		st.mode = st.mode == .Find ? .Doc : .Find
		st.find_hits = count_hits(st)
	}
	if tool_button(ui, "prose", ICON_CASE_SENSITIVE, st.prose.show) {
		prose_toggle(st)
	}
	if tool_button(ui, "help", ICON_KEYBOARD, st.help) {
		st.help = !st.help
	}
}

toolbar_format :: proc(ui: ^p.Ctx, st: ^State) {
	cs := effective_style(st)
	pa := &st.doc.paras[clamp(st.caret.para, 0, len(st.doc.paras) - 1)]

	p.row(ui, tfmt("h-[%.0f] w-full shrink-0 items-center gap-1 px-3", TOP2))
	defer p.end(ui)

	if pill(ui, "kind", kind_label(pa.kind), "w-[108]") {
		cycle_kind(st)
	}

	size_label := cs.size > 0 ? tfmt("%.0f", cs.size) : tfmt("%.0f", kind_metrics(pa.kind).size)
	if pill(ui, "size", size_label, "w-[58]") {
		cur := cs.size > 0 ? cs.size : kind_metrics(pa.kind).size
		next := SIZES[0]
		for s in SIZES {
			if s > cur {
				next = s
				break
			}
		}
		set_size(st, next)
	}

	vrule(ui)

	if tool_button(ui, "bold", ICON_BOLD, cs.bold) {toggle_bold(st)}
	if tool_button(ui, "ital", ICON_ITALIC, cs.italic) {toggle_italic(st)}
	if tool_button(ui, "undl", ICON_UNDERLINE, cs.underline) {toggle_underline(st)}
	if tool_button(ui, "mono", ICON_CODE, cs.mono) {toggle_mono(st)}

	vrule(ui)

	p.row(ui, "shrink-0 items-center gap-1")
	for rgb, i in PALETTE {
		on := (cs.color & 0xffffff) == rgb && (cs.color != 0 || rgb == 0)
		if swatch(ui, tfmt("sw%d", i), rgb, on) {
			set_color(st, i == 0 ? 0 : rgb)
		}
	}
	p.end(ui)

	vrule(ui)

	if tool_button(ui, "al", ICON_TEXT_ALIGN_START, pa.align == .Left) {set_align(st, .Left)}
	if tool_button(ui, "ac", ICON_TEXT_ALIGN_CENTER, pa.align == .Center) {set_align(st, .Center)}
	if tool_button(ui, "ar", ICON_TEXT_ALIGN_END, pa.align == .Right) {set_align(st, .Right)}
	if tool_button(ui, "aj", ICON_TEXT_ALIGN_JUSTIFY, pa.align == .Justify) {set_align(st, .Justify)}

	vrule(ui)

	if tool_button(ui, "ul", ICON_LIST, pa.list == .Bullet) {set_list(st, .Bullet)}
	if tool_button(ui, "ol", ICON_LIST_ORDERED, pa.list == .Numbered) {set_list(st, .Numbered)}
	if tool_button(ui, "quote", ICON_QUOTE, pa.kind == .Quote) {
		set_kind(st, pa.kind == .Quote ? .Body : .Quote)
	}

	vrule(ui)

	if tool_button(ui, "tbl", ICON_TABLE, in_table(st)) {
		if in_table(st) {
			delete_block(st)
		} else {
			open_prompt(st, .Insert_Table)
		}
	}
	if tool_button(ui, "img", ICON_IMAGE, pa.kind == .Image) {
		open_prompt(st, .Insert_Image)
	}

	p.spacer(ui)

	// Zoom.
	p.row(ui, "shrink-0 items-center gap-0.5")
	if tool_button(ui, "zo", ICON_ZOOM_OUT, false, st.zoom_i > 0) {
		set_zoom(st, st.zoom_i - 1)
	}
	p.div(ui, "flex-row w-[46] items-center justify-center shrink-0")
	p.text(ui, tfmt("%d%%", int(st.zoom * 100 + 0.5)), "text-[12] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	if tool_button(ui, "zi", ICON_ZOOM_IN, false, st.zoom_i < len(ZOOMS) - 1) {
		set_zoom(st, st.zoom_i + 1)
	}
	p.end(ui)
}

// toolbar_table is the strip that appears while the caret is inside a grid.
toolbar_table :: proc(ui: ^p.Ctx, st: ^State) {
	t := table_at(st)
	p.row(ui, tfmt("h-[%.0f] w-full shrink-0 items-center gap-1 px-3 bg-muted/35", TABLEBAR))
	defer p.end(ui)
	if t == nil {
		return
	}

	p.text(
		ui,
		tfmt("Table %dx%d — cell %c%d", len(t.rows), table_cols(t), rune('A' + st.caret.col), st.caret.row + 1),
		"text-[12] font-medium whitespace-nowrap",
	)
	p.style(ui).shrink = 0

	vrule(ui)

	if tool_button(ui, "rowa", ICON_ROWS) {table_row_cmd(st, false)}
	p.text(ui, "row", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if tool_button(ui, "rowb", ICON_ROWS) {table_row_cmd(st, true)}
	if tool_button(ui, "rowd", ICON_TRASH, false, len(t.rows) > 1) {table_delete_row_cmd(st)}

	vrule(ui)

	if tool_button(ui, "cola", ICON_COLUMNS) {table_col_cmd(st, false)}
	p.text(ui, "column", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if tool_button(ui, "colb", ICON_COLUMNS) {table_col_cmd(st, true)}
	if tool_button(ui, "cold", ICON_TRASH, false, table_cols(t) > 1) {table_delete_col_cmd(st)}

	vrule(ui)

	if tool_button(ui, "hdr", ICON_HEADING_1, t.header) {table_toggle_header(st)}
	if tool_button(ui, "brd", ICON_SQUARE, t.borders) {table_toggle_borders(st)}

	vrule(ui)

	if tool_button(ui, "narrow", ICON_CHEVRON_RIGHT, false, table_cols(t) > 1) {
		table_nudge_width(st, -24)
	}
	p.div(ui, "flex-row w-[52] items-center justify-center shrink-0")
	p.text(
		ui,
		tfmt("%.0f px", table_width(t, st.caret.col)),
		"text-[11.5] text-muted-foreground whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.end(ui)
	if tool_button(ui, "wide", ICON_CHEVRON_RIGHT, false, table_cols(t) > 1) {
		table_nudge_width(st, 24)
	}

	p.spacer(ui)

	hint(ui, "Tab", "next cell")
	if tool_button(ui, "tbldel", ICON_TRASH) {delete_block(st)}
}

// ---------------------------------------------------------------------------
// Find bar
// ---------------------------------------------------------------------------

mini_field :: proc(ui: ^p.Ctx, key, label, value, placeholder: string, focus: bool, elapsed: f32) {
	p.key(ui, key)
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)

	p.text(ui, label, "text-[12] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	idx := p.row(
		ui,
		"h-7 w-[180] shrink-0 items-center px-2 rounded-md border border-input bg-background overflow-hidden cursor-text",
	)
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	defer p.end(ui)

	if value == "" && !focus {
		p.text(ui, placeholder, "text-[12.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.text(ui, value, "text-[12.5] text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	if focus && blink_phase(elapsed) {
		p.div(ui, "w-px h-[14] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
}

find_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%.0f] w-full shrink-0 items-center gap-3 px-3 bg-muted/50", FINDBAR))
	defer p.end(ui)

	t := p.elapsed(ui)
	mini_field(ui, "f", "Find", string(st.find[:]), "text to find", st.find_field == 0, t)
	mini_field(ui, "r", "Replace", string(st.repl[:]), "replacement", st.find_field == 1, t)

	// A pattern that will not compile is named, not swallowed: "no matches"
	// for `a(b` would send somebody hunting through their document.
	if st.find_regex && st.rx_err != "" {
		p.text(ui, tfmt("bad pattern: %s", st.rx_err), "text-[12] text-destructive whitespace-nowrap")
	} else {
		p.text(
			ui,
			st.find_hits == 0 ? "no matches" : tfmt("%d match%s", st.find_hits, st.find_hits == 1 ? "" : "es"),
			"text-[12] text-muted-foreground whitespace-nowrap",
		)
	}
	p.style(ui).shrink = 0

	// The two depth switches, which is the whole difference between a find box
	// and a find box you can trust on a word like "art".
	if tool_button(ui, "mcase", ICON_CASE_SENSITIVE, st.find_case) {
		toggle_find_case(st)
	}
	if tool_button(ui, "mword", ICON_WHOLE_WORD, st.find_word) {
		toggle_find_word(st)
	}
	if tool_button(ui, "mrx", ICON_REGEX, st.find_regex) {
		toggle_find_regex(st)
	}

	vrule(ui)

	// The three actions, as buttons. The keys stay, and both paths call the
	// same procedures.
	if text_button(ui, "fnext", "Next", true) {
		find_next(st)
		st.find_hits = count_hits(st)
	}
	if text_button(ui, "frepl", "Replace") {
		replace_one(st)
		st.find_hits = count_hits(st)
	}
	if text_button(ui, "fall", "All") {
		replace_all(st)
		st.find_hits = count_hits(st)
	}
	if text_button(ui, "fclose", "Close") {
		st.mode = .Doc
	}

	p.spacer(ui)

	hint(ui, "Return", "next")
	hint(ui, "Tab", "field")
	hint(ui, "F5", "case")
	hint(ui, "F6", "word")
	hint(ui, "F7", "regex")
	hint(ui, "F11", "replace")
	hint(ui, "F12", "all")
}

hint :: proc(ui: ^p.Ctx, keyname, what: string) {
	p.key(ui, keyname)
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, keyname)
	p.text(ui, what, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^State) {
	words, chars := doc_counts(&st.doc)

	p.row(ui, tfmt("h-[%.0f] w-full shrink-0 items-center gap-3 px-3 bg-muted/40", STATUS))
	defer p.end(ui)

	p.text(
		ui,
		tfmt("Page %d of %d", current_page(st), st.lay.pages),
		"text-[11.5] font-medium whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	dot(ui)
	p.text(ui, tfmt("%d words", words), "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	dot(ui)
	p.text(ui, tfmt("%d characters", chars), "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	dot(ui)
	p.text(ui, tfmt("%d lines", len(st.lay.lines)), "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0

	if st.mark {
		dot(ui)
		sc.badge(ui, "MARK", .Secondary)
	}
	if t := table_at(st); t != nil {
		dot(ui)
		sc.badge(ui, tfmt("TABLE %dx%d", len(t.rows), table_cols(t)), .Secondary)
	}
	if im := image_at(st); im != nil {
		dot(ui)
		sc.badge(ui, tfmt("IMAGE %dx%d @ %d%%", im.w, im.h, int(im.scale * 100 + 0.5)), .Secondary)
	}

	p.spacer(ui)

	if st.toast != "" && st.toast_at < 3.2 {
		p.text(ui, st.toast, "text-[11.5] text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	} else {
		p.text(ui, "F1 shortcuts", "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
}

dot :: proc(ui: ^p.Ctx) {
	p.div(ui, "size-1 rounded-full bg-muted-foreground/40 shrink-0")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

prompt_overlay :: proc(ui: ^p.Ctx, st: ^State) {
	p.div(ui, "absolute inset-0 z-50 flex-col items-center justify-center bg-black/35")
	defer p.end(ui)

	p.col(ui, "w-[560] gap-3 p-5 rounded-xl bg-popover border border-border shadow-2xl")
	defer p.end(ui)

	p.text(ui, prompt_label(st.prompt), "text-[14] font-semibold")
	p.text(
		ui,
		"Type a path and press Return. Escape cancels.",
		"text-[12] text-muted-foreground",
	)

	idx := p.row(
		ui,
		"h-9 w-full items-center px-2.5 rounded-lg border border-ring ring-3 ring-ring/40 bg-background overflow-hidden",
	)
	_ = idx
	p.text(ui, string(st.prompt_buf[:]), "text-[13] font-mono whitespace-nowrap")
	p.style(ui).shrink = 0
	if blink_phase(p.elapsed(ui)) {
		p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)

	// A dialog with a text field and no buttons asks the reader to know a
	// keyboard shortcut to get out of it. These run the same two procedures
	// Return and Escape run.
	p.row(ui, "w-full items-center gap-2")
	p.spacer(ui)
	if text_button(ui, "pcancel", "Cancel") {
		cancel_prompt(st)
	}
	if text_button(ui, "pok", prompt_verb(st.prompt), true) {
		commit_prompt(st)
	}
	p.end(ui)
}

Shortcut :: struct {
	keys: string,
	what: string,
}

HELP_DEMO := [?]Shortcut {
	{"F2 / F3 / F4", "Bold, italic, underline"},
	{"F5", "Cycle paragraph style"},
	{"F6 / F7", "Bullet list, numbered list"},
	{"F8", "Cycle alignment"},
	{"F9", "Find and replace bar"},
	{"F5 / F6 / F7 in find", "Match case, whole words, regular expression"},
	{"F10", "Set mark, then arrows extend the selection"},
	{"F11 / F12", "Replace, replace all"},
	{"KP + / KP -", "Zoom in, zoom out"},
}

HELP_TABLE := [?]Shortcut {
	{"Ctrl Shift T", "Insert a table (rows x columns)"},
	{"Tab / Shift Tab", "Next cell, previous cell"},
	{"Alt R / Alt Shift R", "Row below, row above"},
	{"Alt C / Alt Shift C", "Column right, column left"},
	{"Alt Backspace", "Delete the row"},
	{"Alt Delete", "Delete the column"},
	{"Alt H / Alt B", "Header row, cell borders"},
	{"Alt Left / Alt Right", "Narrow, widen the column"},
	{"Alt K", "Delete the table or picture"},
	{"Ctrl Shift I", "Insert a picture"},
	{"Alt Up / Alt Down", "Scale the picture"},
}

HELP_EDIT := [?]Shortcut {
	{"Ctrl B / I / U / J", "Bold, italic, underline, code"},
	{"Ctrl 0 to 5", "Body, H1, H2, H3, Quote, Code"},
	{"Ctrl L / E / R", "Align left, centre, right"},
	{"Tab / Shift Tab", "Indent, outdent"},
	{"Ctrl A / C / X / V", "Select all, copy, cut, paste"},
	{"Ctrl Z / Ctrl Y", "Undo, redo"},
	{"Ctrl Space", "Clear character formatting"},
	{"Ctrl Return", "Hard page break"},
	{"Shift + arrows", "Extend the selection"},
	{"Ctrl G", "Check the prose (vale)"},
	{"Alt N / Alt P", "Next, previous problem"},
	{"Alt Y", "Accept the suggested replacement"},
	{"Alt X / Alt Shift X", "This rule off for the document, all back on"},
}

HELP_FILE := [?]Shortcut {
	{"Ctrl O / Ctrl S", "Open, save (native JSON)"},
	{"Ctrl Shift S", "Save as"},
	{"Ctrl M / Ctrl Shift M", "Export, import Markdown"},
	{"Ctrl Shift H", "Export HTML"},
	{"Ctrl P", "Export PDF (embedded, searchable)"},
	{"Ctrl D / Ctrl Shift D", "Export .docx, .odt"},
	{"Ctrl T", "Export .rtf"},
	{"Ctrl Shift O / Ctrl Alt O", "Import .docx, .odt"},
	{"Ctrl Alt T", "Import .rtf"},
	{"Ctrl Shift P", "Export every page as PNG"},
	{"Ctrl = / Ctrl -", "Zoom"},
	{"Ctrl Q", "Quit"},
}

help_overlay :: proc(ui: ^p.Ctx, st: ^State) {
	p.div(ui, "absolute inset-0 z-50 flex-col items-center justify-center bg-black/45")
	defer p.end(ui)

	p.col(ui, "w-[1160] gap-4 p-6 rounded-xl bg-popover border border-border shadow-2xl")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	p.icon(ui, ICON_FILE_TEXT, "size-4 text-primary shrink-0")
	p.text(ui, "Docs — keyboard", "text-[15] font-semibold")
	p.spacer(ui)
	p.text(
		ui,
		"A4 pages, 1 inch margins. Any key closes this.",
		"text-[12] text-muted-foreground",
	)
	p.end(ui)

	sc.separator(ui)

	p.row(ui, "w-full gap-6 items-start")
	defer p.end(ui)
	help_column(ui, "No modifiers", HELP_DEMO[:])
	help_column(ui, "Editing", HELP_EDIT[:])
	help_column(ui, "Tables and pictures", HELP_TABLE[:])
	help_column(ui, "Files and view", HELP_FILE[:])
}

help_column :: proc(ui: ^p.Ctx, title: string, rows: []Shortcut) {
	p.key(ui, title)
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	defer p.end(ui)

	p.text(ui, title, "text-[11] font-semibold uppercase tracking-wide text-muted-foreground")
	for r in rows {
		p.key(ui, r.keys)
		p.row(ui, "w-full items-center gap-2")
		sc.kbd(ui, r.keys)
		p.text(ui, r.what, "text-[12] text-foreground truncate")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Shared formatting helper
// ---------------------------------------------------------------------------

tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}
