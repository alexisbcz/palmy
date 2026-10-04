// The frame: the note list, the writing pane, the reading pane, the dialogs.
package main

import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

frame :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	header(ui, nt)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	list_pane(ui, nt)
	p.col(ui, "flex-1 min-w-0 h-full relative overflow-hidden")
	if _, ok := selected(nt); ok {
		note_header(ui, nt)
		if nt.preview {
			reading_pane(ui, nt)
		} else {
			writing_pane(ui, nt)
		}
	} else {
		empty_editor(ui, nt)
	}
	p.end(ui)
	p.end(ui)

	status(ui, nt)

	switch nt.mode {
	case .Help:
		help_sheet(ui, nt)
	case .Rename:
		rename_dialog(ui, nt)
	case .Confirm_Delete:
		delete_dialog(ui, nt)
	case .Normal, .Search:
	}
	toast(ui, nt)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-b border-border",
			HEADER_H,
		),
	)
	defer p.end(ui)

	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-background border border-border")
	p.icon(ui, ICON_NOTEBOOK_PEN, "size-4 text-muted-foreground")
	p.end(ui)

	p.col(ui, "gap-px min-w-0 shrink-0")
	p.text(ui, "Notes", "text-[14] font-semibold whitespace-nowrap")
	p.textf(
		ui,
		"text-[11] text-muted-foreground whitespace-nowrap",
		"%d note%s in %s",
		len(nt.all),
		len(nt.all) == 1 ? "" : "s",
		short_home(nt.dir),
	)
	p.end(ui)

	p.spacer(ui, "flex-1")
	search_field(ui, nt)

	toolbar_button(ui, "new", ICON_PLUS, "New", nt)
	toolbar_mode(ui, nt)

	p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
	sc.kbd(ui, "F1")
	p.text(ui, "keys", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

short_home :: proc(path: string) -> string {
	if i := strings.index(path, "/.local/share/"); i > 0 {
		return tfmt("~%s", path[i:])
	}
	return path
}

toolbar_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, label: string, nt: ^Notes) {
	p.key(ui, key)
	idx := p.row(
		ui,
		"h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer",
	)
	if p.clickable(ui, idx) {
		create(nt)
	}
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

toolbar_mode :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	defer p.end(ui)

	seg :: proc(ui: ^p.Ctx, nt: ^Notes, key: string, ic: p.Icon, preview: bool) {
		p.key(ui, key)
		on := nt.preview == preview
		idx := p.div(ui, "flex-row h-6 w-8 items-center justify-center rounded-md transition cursor-pointer")
		p.apply(
			ui,
			on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
			idx,
		)
		if p.clickable(ui, idx) {
			nt.preview = preview
		}
		p.icon(ui, ic, "size-3.5")
		p.end(ui)
	}
	seg(ui, nt, "write", ICON_PENCIL, false)
	seg(ui, nt, "read", ICON_EYE, true)
}

search_field :: proc(ui: ^p.Ctx, nt: ^Notes) {
	focus := nt.mode == .Search
	idx := p.row(
		ui,
		"h-7 w-[240] shrink-0 items-center gap-1.5 px-2 rounded-lg border border-input bg-background cursor-text transition",
	)
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	if p.clickable(ui, idx) {
		nt.mode = .Search
		nt.swallow = true
	}
	defer p.end(ui)

	p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
	q := string(nt.query[:])
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	p.text(
		ui,
		q == "" ? "Search every note" : q,
		q == "" \
		? "text-[12.5] text-muted-foreground whitespace-nowrap shrink-0" \
		: "text-[12.5] text-foreground whitespace-nowrap shrink-0",
	)
	if focus {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[14] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

list_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(
		ui,
		tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border overflow-hidden", LIST_W),
	)
	defer p.end(ui)

	q := string(nt.query[:])
	p.row(ui, "h-[30] shrink-0 w-full items-center gap-2 px-3")
	p.text(
		ui,
		q == "" ? "ALL NOTES" : "MATCHES",
		"text-[10] font-semibold tracking-wide text-muted-foreground/70 whitespace-nowrap shrink-0",
	)
	p.spacer(ui, "flex-1")
	p.textf(
		ui,
		"text-[10.5] text-muted-foreground whitespace-nowrap shrink-0",
		"%d",
		len(nt.vis),
	)
	p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-2 pb-2 gap-1")
	list_id := p.node_id(ui, list)
	defer p.end(ui)

	if len(nt.vis) == 0 {
		p.col(ui, "w-full items-center justify-center gap-2 py-12 px-6")
		p.div(ui, "flex-row size-10 items-center justify-center rounded-xl bg-muted shrink-0")
		p.icon(ui, q == "" ? ICON_NOTEBOOK_PEN : ICON_SEARCH, "size-4.5 text-muted-foreground")
		p.end(ui)
		p.text(ui, q == "" ? "No notes yet" : "Nothing matches", "text-[13] font-medium")
		p.text(
			ui,
			q == "" \
			? "Press F4 to write the first one." \
			: tfmt("No note contains \"%s\".", q),
			"max-w-[220] text-center text-[11.5] text-muted-foreground",
		)
		p.end(ui)
		return
	}

	for vi, i in nt.vis {
		n := nt.all[vi]
		on := i == nt.sel
		focus := on && nt.pane == .List

		p.key(ui, n.path)
		idx := p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5 rounded-lg transition cursor-pointer")
		switch {
		case focus:
			p.apply(ui, "bg-accent-blue", idx)
		case on:
			p.apply(ui, "bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent/70", idx)
		}
		if p.clickable(ui, idx) {
			nt.sel = i
			open_sel(nt)
			nt.pane = .List
		}
		if focus {
			p.scroll_into_view(ui, list_id, p.node_id(ui, idx), 8)
		}

		p.row(ui, "w-full items-center gap-2")
		p.text(
			ui,
			n.title,
			focus \
			? "flex-1 min-w-0 truncate text-[13] font-semibold text-white" \
			: "flex-1 min-w-0 truncate text-[13] font-semibold text-foreground",
		)
		if n.path == nt.open_path && nt.pending {
			p.div(ui, "size-1.5 rounded-full shrink-0 bg-amber-500")
			p.end(ui)
		}
		p.text(
			ui,
			human_date(n.mtime, nt.now, nt.tz),
			focus \
			? "text-[10.5] text-white/70 whitespace-nowrap shrink-0" \
			: "text-[10.5] text-muted-foreground whitespace-nowrap shrink-0",
		)
		p.end(ui)

		line := q == "" ? "" : match_line(n.body, q)
		body := line != "" ? line : n.preview
		if body != "" {
			p.text(
				ui,
				body,
				focus \
				? "w-full truncate text-[11.5] text-white/75" \
				: "w-full truncate text-[11.5] text-muted-foreground",
			)
		}

		p.row(ui, "w-full items-center gap-2")
		p.textf(
			ui,
			focus \
			? "text-[10] text-white/60 whitespace-nowrap shrink-0" \
			: "text-[10] text-muted-foreground/70 whitespace-nowrap shrink-0",
			"%d words",
			n.words,
		)
		if line != "" {
			p.text(
				ui,
				"matched in body",
				focus \
				? "text-[10] text-white/60 whitespace-nowrap shrink-0" \
				: "text-[10] text-accent-blue whitespace-nowrap shrink-0",
			)
		}
		p.end(ui)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The open note
// ---------------------------------------------------------------------------

note_header :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-3 px-6 border-b border-border")
	defer p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(
		ui,
		title_of(buf_line(&nt.buf, 0), context.temp_allocator),
		"w-full truncate text-[16] font-semibold",
	)
	p.row(ui, "items-center gap-2 min-w-0")
	p.text(
		ui,
		base_of(nt.open_path),
		"truncate text-[11] text-muted-foreground font-mono max-w-[320]",
	)
	p.text(ui, "·", "text-[11] text-muted-foreground/50 shrink-0")
	p.text(
		ui,
		nt.pending ? "saving…" : "saved",
		nt.pending \
		? "text-[11] text-amber-600 whitespace-nowrap shrink-0" \
		: "text-[11] text-emerald-600 whitespace-nowrap shrink-0",
	)
	p.end(ui)
	p.end(ui)

	sc.badge(ui, nt.preview ? "Reading" : "Writing", .Secondary)
}

base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

writing_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	outer := p.col(ui, "flex-1 min-h-0 w-full relative overflow-hidden px-6 py-4")
	defer p.end(ui)
	if p.clickable(ui, outer) {
		r := p.rect_of(ui, p.node_id(ui, outer))
		m := p.mouse_pos(ui)
		row := clamp(nt.top + int((m.y - r.y - 16) / BODY_LH), 0, max(0, len(nt.wrap.rows) - 1))
		nt.cur = pos_clamp(&nt.buf, col_at(&nt.wrap, ui, &nt.buf, row, m.x - r.x - 24))
		nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
		ed_clear_sel(nt)
		nt.pane = .Editor
	}

	wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)
	rows := nt.wrap.rows[:]
	nt.top = clamp(nt.top, 0, max(0, len(rows) - 1))

	sel_lo, sel_hi, has_sel := ed_sel(nt)
	cur_row := row_of(&nt.wrap, nt.cur)
	caret_on := math.mod(f64(p.elapsed(ui)), 1.06) < 0.62
	if nt.pane == .Editor {
		p.redraw(ui)
	}

	last := min(nt.top + nt.rows, len(rows))
	for ri := nt.top; ri < last; ri += 1 {
		r := rows[ri]
		src := buf_line(&nt.buf, r.line)
		seg := src[r.from:r.to]

		p.key(ui, tfmt("r%d", ri))
		p.row(ui, tfmt("h-[%d] w-full shrink-0 relative items-center", BODY_LH))

		// Selection first, so the text sits on top of it.
		if has_sel {
			a, b := -1, -1
			if sel_lo.line < r.line || (sel_lo.line == r.line && sel_lo.col <= r.from) {
				a = r.from
			} else if sel_lo.line == r.line && sel_lo.col <= r.to {
				a = sel_lo.col
			}
			if sel_hi.line > r.line || (sel_hi.line == r.line && sel_hi.col >= r.to) {
				b = r.to
			} else if sel_hi.line == r.line && sel_hi.col >= r.from {
				b = sel_hi.col
			}
			if a >= 0 && b > a {
				x0 := text_w(ui, src[r.from:a])
				x1 := text_w(ui, src[r.from:b])
				band(ui, x0, x1 - x0)
			}
		}

		p.text(ui, seg, "text-[14] leading-[23] text-foreground whitespace-nowrap shrink-0")

		if ri == cur_row && caret_on && nt.pane == .Editor {
			x := caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
			cb := p.div(ui, "absolute w-[2] rounded-[1] bg-accent-blue")
			cs := p.style(ui, cb)
			cs.inset[p.LEFT] = p.px(x)
			cs.inset[p.TOP] = p.px(2)
			cs.h = p.px(BODY_LH - 4)
			p.end(ui)
		}
		p.end(ui)
	}

	scroll_hint(ui, len(rows), nt.rows, nt.top)
}

band :: proc(ui: ^p.Ctx, x, w: f32) {
	idx := p.div(ui, "absolute rounded-[2] bg-accent-blue/25")
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(x)
	s.inset[p.TOP] = p.px(0)
	s.w = p.px(max(3, w))
	s.h = p.px(BODY_LH)
	s.no_hit = true
	p.end(ui)
}

scroll_hint :: proc(ui: ^p.Ctx, total, rows, top: int) {
	if total <= rows {
		return
	}
	view_h := f32(rows * BODY_LH)
	h := max(28, view_h * f32(rows) / f32(total))
	t := f32(top) / f32(max(1, total - rows))
	sb := p.div(ui, "absolute right-[4] w-[5] rounded-full bg-foreground/20")
	s := p.style(ui, sb)
	s.inset[p.TOP] = p.px((view_h - h) * t + 16)
	s.h = p.px(h - 4)
	p.end(ui)
}

reading_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-6 py-4")
	defer p.end(ui)

	p.col(ui, "w-full max-w-[720] gap-0")
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< buf_lines(&nt.buf) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(&nt.buf, i))
	}
	md_render(ui, strings.to_string(sb), nt.space_w)
	p.end(ui)
}

empty_editor :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-3 px-10")
	defer p.end(ui)

	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ICON_NOTEBOOK_PEN, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, len(nt.all) == 0 ? "No notes yet" : "Nothing selected", "text-[15] font-semibold")
	p.text(
		ui,
		"Notes are Markdown files on disk. Press F4 to start one.",
		"max-w-[360] text-center text-[12.5] text-muted-foreground",
	)
	p.row(ui, "items-center gap-2 pt-1")
	sc.kbd(ui, "F4")
	p.text(ui, "new note", "text-[11.5] text-muted-foreground")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(
		ui,
		tfmt(
			"h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border",
			STATUS_H,
		),
	)
	defer p.end(ui)

	label := nt.pane == .List ? "Notes" : (nt.preview ? "Reading" : "Writing")
	if nt.mode == .Search {
		label = "Search"
	}
	p.text(ui, label, "text-[11.5] font-medium whitespace-nowrap shrink-0")
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")

	switch {
	case nt.mode == .Search:
		hint(ui, "Up Down", "pick")
		hint(ui, "Enter", "open")
		hint(ui, "Esc", "clear")
	case nt.pane == .List:
		hint(ui, "Enter", "edit")
		hint(ui, "F4", "new")
		hint(ui, "F2", "rename")
		hint(ui, "Delete", "remove")
	case:
		hint(ui, "F3", "read")
		hint(ui, "Esc", "list")
		hint(ui, "Ctrl Z", "undo")
	}

	p.spacer(ui, "flex-1")

	if n, ok := selected(nt); ok {
		if !nt.preview && nt.pane == .Editor {
			p.textf(
				ui,
				"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
				"Ln %d, Col %d",
				nt.cur.line + 1,
				nt.cur.col + 1,
			)
			p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
		}
		p.textf(
			ui,
			"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
			"%d words",
			n.words,
		)
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	}
	p.text(
		ui,
		nt.pending ? "unsaved" : "all saved",
		nt.pending \
		? "text-[11.5] text-amber-600 whitespace-nowrap shrink-0" \
		: "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
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
// Dialogs
// ---------------------------------------------------------------------------

sheet_open :: proc(ui: ^p.Ctx, w: int, top: f32) -> int {
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", w))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - f32(w)) / 2))
	s.inset[p.TOP] = p.px(top)
	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	return wrap
}

sheet_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

scrim :: proc(ui: ^p.Ctx, nt: ^Notes) {
	s := p.div(ui, "absolute inset-0 z-40 bg-foreground/15")
	if p.clickable(ui, s) {
		nt.mode = .Normal
	}
	p.end(ui)
}

rename_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 480, max(8, win.y / 2 - 140))
	defer sheet_close(ui)

	p.col(ui, "w-full px-5 pt-5 pb-4 gap-3")
	p.col(ui, "gap-1")
	p.text(ui, "Rename note", "text-[15] font-semibold")
	p.text(
		ui,
		"The title is the note's first line, and the file on disk is renamed to match.",
		"text-[12] text-muted-foreground",
	)
	p.end(ui)

	idx := p.row(
		ui,
		"h-9 w-full items-center gap-1 px-3 rounded-lg border border-ring ring-3 ring-ring/40 bg-background overflow-hidden",
	)
	_ = idx
	v := string(nt.rename[:])
	p.text(
		ui,
		v == "" ? "Untitled" : v,
		v == "" \
		? "text-[13.5] text-muted-foreground/60 whitespace-nowrap shrink-0" \
		: "text-[13.5] text-foreground whitespace-nowrap shrink-0",
	)
	p.redraw(ui)
	if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
		p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ICON_FILE_TEXT, "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		tfmt("%s.md", slug(v == "" ? "untitled" : v)),
		"flex-1 min-w-0 truncate text-[11.5] font-mono text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", "rename")
	p.end(ui)
}

delete_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	n, _ := selected(nt)
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 150))
	defer sheet_close(ui)

	p.col(ui, "w-full items-center px-6 pt-6 pb-4 gap-4")
	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-red-100 shrink-0")
	p.icon(ui, ICON_TRASH, "size-4.5 text-destructive")
	p.end(ui)

	p.col(ui, "items-center gap-1.5 w-full")
	p.text(ui, "Delete this note?", "text-[16] font-semibold")
	p.text(
		ui,
		tfmt("\"%s\" will be removed from disk. This cannot be undone.", n.title),
		"max-w-[340] text-center text-[12.5] text-muted-foreground",
	)
	p.text(ui, base_of(n.path), "text-[11] font-mono text-muted-foreground/70")
	p.end(ui)

	p.row(ui, "w-full gap-2 pt-1")
	for label, i in ([?]string{"Keep it", "Delete"}) {
		on := (i == 1) == nt.sel_confirm
		p.key(ui, label)
		idx := p.row(ui, "flex-1 h-[34] items-center justify-center rounded-lg border border-border transition cursor-pointer")
		switch {
		case on && i == 1:
			p.apply(ui, "bg-destructive border-destructive text-white ring-3 ring-destructive/25", idx)
		case on:
			p.apply(ui, "bg-secondary border-ring ring-3 ring-ring/30", idx)
		case:
			p.apply(ui, "bg-background hover:bg-accent", idx)
		}
		if p.clickable(ui, idx) {
			nt.sel_confirm = i == 1
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
	{"Tab", "move between the list and the note"},
	{"Up / Down", "pick a note, or move the caret"},
	{"Enter", "open the note for writing"},
	{"F2", "rename the note"},
	{"F3", "switch writing and reading"},
	{"F4", "new note"},
	{"F5", "re-read the folder"},
	{"Delete", "delete the selected note"},
	{"Ctrl F  or  /", "search every note's body"},
	{"Ctrl S", "save now (it also saves itself)"},
	{"Ctrl Z / Ctrl Y", "undo, redo"},
	{"Ctrl X / C / V", "cut, copy, paste"},
	{"Ctrl A", "select the whole note"},
	{"Escape", "back to the list"},
	{"Ctrl Q", "quit, saving first"},
}

MD_ROWS := [?][2]string {
	{"# ## ###", "headings"},
	{"**bold**", "bold"},
	{"*emphasis*", "emphasis"},
	{"`code`", "inline code"},
	{"- item", "bullet, and Return continues it"},
	{"1. item", "numbered list"},
	{"- [ ] / - [x]", "tasks"},
	{"> quote", "quotation"},
	{"---", "a rule"},
}

help_sheet :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 680, max(8, (win.y - 560) / 2))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3")
	p.icon(ui, ICON_KEYBOARD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, "Notes, from the keyboard", "text-[15] font-semibold")
	p.text(ui, "Nothing here needs the pointer.", "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full px-5 pb-5 gap-7 items-start")
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	p.text(ui, "KEYS", "text-[10] font-semibold tracking-wide text-muted-foreground/70 pb-0.5")
	for row in HELP_ROWS {
		p.row(ui, "w-full items-center gap-2.5")
		p.row(ui, "w-[116] shrink-0 justify-end")
		sc.kbd(ui, row[0])
		p.end(ui)
		p.text(ui, row[1], "flex-1 min-w-0 text-[11.5] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "w-[260] shrink-0 gap-1.5")
	p.text(ui, "MARKDOWN", "text-[10] font-semibold tracking-wide text-muted-foreground/70 pb-0.5")
	for row in MD_ROWS {
		p.row(ui, "w-full items-center gap-2.5")
		p.text(ui, row[0], "w-[96] shrink-0 text-right font-mono text-[11.5] text-foreground")
		p.text(ui, row[1], "flex-1 min-w-0 text-[11.5] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center justify-end gap-2 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "close")
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if nt.toast == "" {
		return
	}
	if nt.toast_at == 0 {
		nt.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - nt.toast_at > 2.6 {
		delete(nt.toast)
		nt.toast = ""
		nt.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(
		ui,
		"absolute z-30 right-[16] bottom-[40] max-w-[420] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg",
	)
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-accent-blue")
	p.text(ui, nt.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
