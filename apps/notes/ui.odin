// The frame: identities and notebooks, the list, the note, the dialogs.
//
// The identity treatment is the product's (cloud/docs/product.md P2,
// cloud/docs/shell.md §3): a 3 px band in the identity's colour across the
// top, the identity chip where the window says what it is in, the colour on
// the primary action, and in mixed lists — All identities, search — a label
// on every row. Colour is never alone: every coloured mark has a name or a
// monogram beside it.
package main

import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

BACKLINKS_H :: 132

ID_TOKENS := [8]string{"id-0", "id-1", "id-2", "id-3", "id-4", "id-5", "id-6", "id-7"}

// on_identity is the text colour on a fill of an identity's colour: white on
// the light theme's deep hues, near-black on the dark theme's light ones.
on_identity :: proc(nt: ^Notes) -> string {
	return nt.dark ? "text-black/85" : "text-white"
}

id_tok :: proc(i: int) -> string {
	if i < 0 {
		return "muted-foreground"
	}
	return ID_TOKENS[i % len(ID_TOKENS)]
}

register_identity_colors :: proc(nt: ^Notes) {
	for id, i in nt.ids {
		if i >= len(ID_TOKENS) {break}
		p.register_color(ID_TOKENS[i], p.hex(identity_hex(id.color, nt.dark)))
	}
}

frame :: proc(ui: ^p.Ctx, nt: ^Notes) {
	register_identity_colors(nt)
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	band(ui, nt)
	header(ui, nt)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch relative")
	switch nt.layout {
	case .Three:
		if !nt.hide_sidebar {
			sidebar(ui, nt)
		}
		list_pane(ui, nt)
		editor_pane(ui, nt)
	case .Two:
		list_pane(ui, nt)
		editor_pane(ui, nt)
	case .One:
		if nt.pane == .Editor && nt.open_path != "" {
			editor_pane(ui, nt)
		} else {
			list_pane(ui, nt)
		}
	}
	if nt.drawer && nt.layout != .Three {
		s := p.div(ui, "absolute inset-0 z-20 bg-foreground/10")
		if p.clickable(ui, s) {
			nt.drawer = false
		}
		p.end(ui)
		d := p.col(ui, "absolute z-30 h-full shadow-2xl")
		p.style(ui, d).inset[p.LEFT] = p.px(0)
		sidebar(ui, nt)
		p.end(ui)
	}
	p.end(ui)

	status(ui, nt)

	switch nt.mode {
	case .Help:
		help_sheet(ui, nt)
	case .Rename:
		rename_dialog(ui, nt)
	case .Confirm_Delete:
		delete_dialog(ui, nt)
	case .Styles:
		prose_styles_sheet(ui, nt)
	case .Share:
		share_dialog(ui, nt)
	case .Carry:
		carry_dialog(ui, nt)
	case .Choose_Identity:
		choose_dialog(ui, nt)
	case .Move:
		move_dialog(ui, nt)
	case .Normal, .Search:
	}
	toast(ui, nt)

	// Last, over everything, inside the root that is already `relative`.
	pick_overlay(ui, nt)
}

// band is the 3 px identity band: the identity the window is in, or every
// identity's colour side by side in All identities.
band :: proc(ui: ^p.Ctx, nt: ^Notes) {
	i := nt.view.ident
	if i >= 0 {
		p.div(ui, tfmt("h-[3] w-full shrink-0 bg-%s", id_tok(i)))
		p.end(ui)
		return
	}
	p.row(ui, "h-[3] w-full shrink-0")
	for _, k in nt.ids {
		p.div(ui, tfmt("h-full flex-1 bg-%s", id_tok(k)))
		p.end(ui)
	}
	if len(nt.ids) == 0 {
		p.div(ui, "h-full flex-1 bg-border")
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Identity marks
// ---------------------------------------------------------------------------

monogram :: proc(ui: ^p.Ctx, nt: ^Notes, i: int, size := 22) {
	name := i >= 0 && i < len(nt.ids) ? nt.ids[i].name : "?"
	box := p.div(ui, tfmt("flex-row size-[%d] shrink-0 items-center justify-center rounded-full bg-%s/15", size, id_tok(i)))
	_ = box
	p.text(ui, monogram_of(name), tfmt("text-[%d] font-semibold text-%s", size > 26 ? 13 : 11, id_tok(i)))
	p.end(ui)
}

// id_label is a dot and the name, muted: the mark for rows in mixed lists.
id_label :: proc(ui: ^p.Ctx, nt: ^Notes, i: int, on_dark := false) {
	p.row(ui, "items-center gap-1 shrink-0")
	p.div(ui, tfmt("size-[7] rounded-full shrink-0 bg-%s", id_tok(i)))
	p.end(ui)
	p.text(ui, nt.ids[i].name, "text-[10.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// id_chip states the scope: a dot and the name on a wash of the colour.
id_chip :: proc(ui: ^p.Ctx, nt: ^Notes, i: int, small := false) {
	if i < 0 {
		p.row(ui, "h-6 shrink-0 items-center gap-1.5 px-2 rounded-full bg-muted")
		for _, k in nt.ids {
			p.div(ui, tfmt("size-[7] rounded-full bg-%s", id_tok(k)))
			p.end(ui)
		}
		p.text(ui, "All identities", "text-[11.5] font-medium whitespace-nowrap")
		p.end(ui)
		return
	}
	p.row(ui, tfmt("%s shrink-0 items-center gap-1.5 pl-1 pr-2 rounded-full bg-%s/10", small ? "h-[22]" : "h-6", id_tok(i)))
	monogram(ui, nt, i, small ? 16 : 18)
	p.text(ui, nt.ids[i].name, tfmt("text-[11.5] font-medium whitespace-nowrap text-%s", id_tok(i)))
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2.5 px-3 bg-sidebar border-b border-border", HEADER_H))
	defer p.end(ui)

	if nt.layout != .Three || nt.hide_sidebar || true {
		p.key(ui, "sidebar-toggle")
		t := p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg hover:bg-accent transition cursor-pointer")
		if p.clickable(ui, t) {
			toggle_sidebar(nt)
		}
		p.icon(ui, ICON_PANEL_LEFT, "size-4 text-muted-foreground")
		p.end(ui)
	}
	p.row(ui, "items-center gap-2 shrink-0")
	p.icon(ui, ICON_NOTEBOOK_PEN, "size-4 text-foreground")
	p.text(ui, "Notes", "text-[14] font-semibold whitespace-nowrap")
	p.end(ui)
	if nt.layout != .One {
		id_chip(ui, nt, nt.view.ident)
	}

	p.spacer(ui, "flex-1")
	search_field(ui, nt)
	p.spacer(ui, "flex-1")

	if nt.layout != .One {
		sync_pill(ui, nt)
	}
	new_button(ui, nt)
}

toggle_sidebar :: proc(nt: ^Notes) {
	if nt.layout == .Three {
		nt.hide_sidebar = !nt.hide_sidebar
	} else {
		nt.drawer = !nt.drawer
		if nt.drawer {
			nt.pane = .Sidebar
		}
	}
}

sync_pill :: proc(ui: ^p.Ctx, nt: ^Notes) {
	text, tone := sync_line(nt)
	dot := "bg-muted-foreground/50"
	switch tone {
	case "ok":
		dot = "bg-emerald-500"
	case "warn":
		dot = "bg-amber-500"
	case "bad":
		dot = "bg-red-500"
	}
	p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-full border border-border bg-background")
	p.div(ui, tfmt("size-[7] rounded-full shrink-0 %s", dot))
	p.end(ui)
	p.text(ui, text, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// new_button is the primary action, in the identity's colour; neutral in All
// identities, where it asks which identity first.
new_button :: proc(ui: ^p.Ctx, nt: ^Notes) {
	i := nt.view.ident
	p.key(ui, "new")
	cls := i >= 0 ? tfmt("bg-%s hover:bg-%s/90 %s", id_tok(i), id_tok(i), on_identity(nt)) : "bg-primary hover:bg-primary/90 text-primary-foreground"
	idx := p.row(ui, tfmt("h-8 shrink-0 items-center gap-1.5 px-3 rounded-lg transition cursor-pointer %s", cls))
	if p.clickable(ui, idx) {
		create(nt)
	}
	p.icon(ui, ICON_PLUS, "size-3.5 shrink-0")
	p.text(ui, nt.layout == .One ? "New" : "New note", "text-[12.5] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

search_field :: proc(ui: ^p.Ctx, nt: ^Notes) {
	focus := nt.mode == .Search
	idx := p.row(ui, "h-8 w-[340] min-w-[120] shrink items-center gap-2 px-2.5 rounded-lg border border-input bg-background cursor-text transition")
	if focus {
		p.apply(ui, "border-ring ring-3 ring-ring/30", idx)
	}
	if p.clickable(ui, idx) {
		nt.mode = .Search
		nt.pane = .List
		nt.swallow = true
	}
	defer p.end(ui)

	p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
	q := string(nt.query[:])
	hint := nt.view.ident >= 0 ? tfmt("Search %s", nt.ids[nt.view.ident].name) : "Search every identity"
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	p.text(ui, q == "" ? hint : q, q == "" ? "text-[12.5] text-muted-foreground whitespace-nowrap shrink-0" : "text-[12.5] text-foreground whitespace-nowrap shrink-0")
	if focus {
		p.redraw(ui)
		if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
			p.div(ui, "w-px h-[14] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
	}
	p.end(ui)
	if q == "" && !focus {
		sc.kbd(ui, "/")
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

section_icon :: proc(s: Section) -> p.Icon {
	switch s {
	case .All:
		return ICON_LAYERS
	case .Inbox:
		return ICON_INBOX
	case .Pinned:
		return ICON_PIN
	case .Notebook:
		return ICON_FOLDER
	case .Tag:
		return ICON_HASH
	case .Shared:
		return ICON_USERS
	case .Trash:
		return ICON_TRASH
	}
	return ICON_FOLDER
}

sidebar :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border overflow-hidden", SIDEBAR_W))
	defer p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-2 pt-3 pb-2 gap-px")
	list_id := p.node_id(ui, list)
	p.text(ui, "IDENTITIES", "px-2 pb-1.5 text-[10] font-semibold tracking-wide text-muted-foreground/70")
	tags_head := false
	for it, i in nt.side {
		on := it.view.ident == nt.view.ident && it.view.section == nt.view.section && it.view.name == nt.view.name
		focus := nt.pane == .Sidebar && i == nt.side_sel
		if it.view.section == .Tag && !tags_head {
			tags_head = true
			p.text(ui, "TAGS", "px-2 pt-3 pb-1 text-[10] font-semibold tracking-wide text-muted-foreground/70")
		}
		if it.head && i > 0 {
			p.div(ui, "h-[6] shrink-0")
			p.end(ui)
		}
		p.key(ui, tfmt("side-%d-%d-%s", it.view.ident, int(it.view.section), it.view.name))
		row := p.row(ui, "w-full h-[30] shrink-0 items-center gap-2 pr-2 rounded-md transition cursor-pointer")
		st := p.style(ui, row)
		st.pad[p.LEFT] = f32(8 + it.depth * 14)
		switch {
		case on:
			p.apply(ui, "bg-accent", row)
		case:
			p.apply(ui, "hover:bg-accent/60", row)
		}
		if focus {
			p.apply(ui, "ring-2 ring-ring/50", row)
			p.scroll_into_view(ui, list_id, p.node_id(ui, row), 8)
		}
		if p.clickable(ui, row) {
			nt.side_sel = i
			set_view(nt, it.view)
			build_side(nt)
			set_view(nt, it.view)
			open_sel(nt)
			nt.pane = .List
			nt.drawer = false
		}
		if it.head {
			if it.view.ident < 0 {
				p.div(ui, "flex-row size-[20] shrink-0 items-center justify-center rounded-full bg-muted")
				p.icon(ui, ICON_LAYERS, "size-3 text-muted-foreground")
				p.end(ui)
			} else {
				monogram(ui, nt, it.view.ident, 20)
			}
			p.text(ui, it.label, on ? "flex-1 min-w-0 truncate text-[13] font-semibold" : "flex-1 min-w-0 truncate text-[13] font-medium")
		} else {
			p.icon(ui, section_icon(it.view.section), on ? "size-3.5 shrink-0 text-foreground" : "size-3.5 shrink-0 text-muted-foreground")
			p.text(ui, it.label, on ? "flex-1 min-w-0 truncate text-[12.5] font-medium" : "flex-1 min-w-0 truncate text-[12.5] text-foreground/85")
		}
		if it.count > 0 || it.view.section == .Inbox {
			p.textf(ui, "text-[11] text-muted-foreground/80 tabular-nums shrink-0", "%d", it.count)
		}
		p.end(ui)
	}
	p.end(ui)

	// The account, in one line: who, and whether the cloud is in reach.
	p.col(ui, "w-full shrink-0 px-3 py-2.5 gap-0.5 border-t border-border")
	text, _ := sync_line(nt)
	p.row(ui, "items-center gap-1.5")
	p.icon(ui, nt.sync.online ? ICON_CLOUD : ICON_CLOUD_OFF, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, text, "text-[11] text-muted-foreground truncate")
	p.end(ui)
	p.text(ui, "Everything here works offline.", "text-[10.5] text-muted-foreground/70 whitespace-nowrap")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

view_title :: proc(nt: ^Notes) -> string {
	if len(nt.query) > 0 {
		return "Results"
	}
	switch nt.view.section {
	case .All:
		return nt.view.ident < 0 ? "All notes" : "Notes"
	case .Inbox:
		return "Inbox"
	case .Pinned:
		return "Pinned"
	case .Notebook:
		return nt.view.name
	case .Tag:
		return tfmt("#%s", nt.view.name)
	case .Shared:
		return "Shared with me"
	case .Trash:
		return "Trash"
	}
	return "Notes"
}

list_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	w := nt.layout == .One ? "flex-1 min-w-0" : tfmt("w-[%d] shrink-0", LIST_W)
	p.col(ui, tfmt("%s h-full bg-background border-r border-border overflow-hidden", w))
	defer p.end(ui)

	q := string(nt.query[:])
	mixed := nt.view.ident < 0
	p.row(ui, "h-[40] shrink-0 w-full items-center gap-2 px-4")
	p.text(ui, view_title(nt), "text-[13.5] font-semibold whitespace-nowrap truncate")
	p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0", "%d", len(nt.vis))
	p.spacer(ui, "flex-1")
	if nt.view.section == .Trash {
		p.text(ui, "Enter restores", "text-[11] text-muted-foreground/80 whitespace-nowrap shrink-0")
	}
	p.end(ui)

	list := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-2 pb-2 gap-0.5")
	list_id := p.node_id(ui, list)
	defer p.end(ui)

	if len(nt.vis) == 0 {
		p.col(ui, "w-full items-center justify-center gap-2 py-14 px-6")
		p.div(ui, "flex-row size-10 items-center justify-center rounded-xl bg-muted shrink-0")
		p.icon(ui, q == "" ? section_icon(nt.view.section) : ICON_SEARCH, "size-4.5 text-muted-foreground")
		p.end(ui)
		who := nt.view.ident >= 0 ? nt.ids[nt.view.ident].name : "any identity"
		switch {
		case q != "":
			p.text(ui, "Nothing matches", "text-[13] font-medium")
			p.text(ui, tfmt("No note in %s contains \"%s\".", who, q), "max-w-[230] text-center text-[11.5] text-muted-foreground")
		case nt.view.section == .Trash:
			p.text(ui, "The trash is empty", "text-[13] font-medium")
		case nt.view.section == .Shared:
			p.text(ui, "Nothing shared with you", "text-[13] font-medium")
			p.text(ui, tfmt("When someone shares a note with %s, it appears here.", who), "max-w-[230] text-center text-[11.5] text-muted-foreground")
		case:
			p.text(ui, tfmt("Nothing in %s yet", nt.view.section == .Notebook ? nt.view.name : who), "text-[13] font-medium")
			p.text(ui, "Ctrl+N writes the first one.", "max-w-[220] text-center text-[11.5] text-muted-foreground")
		}
		p.end(ui)
	}

	for vi, i in nt.vis {
		n := nt.all[vi]
		on := i == nt.sel
		focus := on && nt.pane == .List

		p.key(ui, n.path)
		idx := p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5 rounded-lg transition cursor-pointer relative")
		switch {
		case on:
			p.apply(ui, "bg-accent", idx)
		case:
			p.apply(ui, "hover:bg-accent/50", idx)
		}
		if focus {
			p.apply(ui, "ring-2 ring-ring/45", idx)
			p.scroll_into_view(ui, list_id, p.node_id(ui, idx), 8)
		}
		if p.clickable(ui, idx) {
			nt.sel = i
			open_sel(nt)
			nt.pane = nt.layout == .One ? .Editor : .List
		}

		p.row(ui, "w-full items-center gap-1.5")
		if n.meta.pinned {
			p.icon(ui, ICON_PIN, "size-3 shrink-0 text-muted-foreground")
		}
		if n.shared {
			p.icon(ui, ICON_USERS, "size-3 shrink-0 text-muted-foreground")
		}
		p.text(ui, n.title, "flex-1 min-w-0 truncate text-[13] font-semibold text-foreground")
		if n.path == nt.open_path && nt.pending {
			p.div(ui, "size-1.5 rounded-full shrink-0 bg-amber-500")
			p.end(ui)
		}
		p.text(ui, human_date(n.mtime, nt.now, nt.tz), "text-[10.5] text-muted-foreground whitespace-nowrap shrink-0")
		p.end(ui)

		line := q == "" ? "" : match_line(n.body, first_word(q))
		if line != "" && contains_fold(n.title, first_word(q)) && strings.contains(line, n.title) {
			line = ""
		}
		body := line != "" ? line : n.preview
		if body != "" {
			p.text(ui, plain_md(body), "w-full truncate text-[11.5] text-muted-foreground")
		}

		p.row(ui, "w-full items-center gap-2 min-w-0")
		// In a mixed list every row says whose it is (P2); inside one identity
		// the window already does.
		if mixed || (q != "" && nt.view.ident < 0) {
			id_label(ui, nt, n.ident)
		}
		if n.shared && n.meta.shared_from != "" {
			p.text(ui, tfmt("from %s · %s", n.meta.shared_from, n.meta.access != "" ? n.meta.access : "read"), "text-[10.5] text-muted-foreground/80 whitespace-nowrap shrink-0")
		} else if n.notebook != "" && (nt.view.section != .Notebook || n.notebook != nt.view.name) {
			p.row(ui, "items-center gap-1 shrink-0")
			p.icon(ui, ICON_FOLDER, "size-3 text-muted-foreground/70")
			p.text(ui, n.notebook, "text-[10.5] text-muted-foreground/80 whitespace-nowrap")
			p.end(ui)
		}
		for t, k in n.tags {
			if k >= 2 {break}
			p.text(ui, tfmt("#%s", t), "text-[10.5] text-accent-blue/90 whitespace-nowrap shrink-0")
		}
		p.end(ui)
		p.end(ui)
	}

	if q != "" {
		p.col(ui, "w-full px-3 pt-3 pb-1 gap-1")
		if nt.other_hits > 0 {
			p.text(ui, tfmt("%d more in your other identities. Ctrl+0 shows them, each labelled.", nt.other_hits), "text-[11] text-muted-foreground")
		}
		p.text(ui, tfmt("Searched %d notes on this device. Nothing left the machine.", len(nt.all)), "text-[11] text-muted-foreground/70")
		p.end(ui)
	}
}

first_word :: proc(q: string) -> string {
	for w in strings.fields(q, context.temp_allocator) {
		if !strings.contains(w, ":") && !strings.has_prefix(w, "#") {
			return w
		}
	}
	return ""
}

// plain_md strips the commonest marks from a preview line.
plain_md :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '*' || c == '`' || (c == '[' && i + 1 < len(s) && s[i + 1] == '[') || (c == ']' && i + 1 < len(s) && s[i + 1] == ']') {
			i += (c == '[' || c == ']') ? 2 : 1
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The open note
// ---------------------------------------------------------------------------

editor_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "flex-1 min-w-0 h-full relative overflow-hidden bg-background")
	if nt.open_path != "" {
		note_header(ui, nt)
		if read_only(nt) {
			p.row(ui, "w-full shrink-0 items-center gap-2 px-6 py-1.5 bg-muted/60 border-b border-border")
			p.icon(ui, ICON_LOCK, "size-3.5 text-muted-foreground shrink-0")
			p.text(ui, tfmt("Shared with you by %s to read. Your edits would not be kept, so the note is locked here.", nt.open_owner), "text-[11.5] text-muted-foreground truncate")
			p.end(ui)
		}
		if nt.preview {
			reading_pane(ui, nt)
		} else {
			writing_pane(ui, nt)
		}
		prose_explain_strip(ui, nt)
		if nt.backlinks {
			backlinks_panel(ui, nt)
		}
	} else {
		empty_editor(ui, nt)
	}
	p.end(ui)
	prose_report_panel(ui, nt)
}

note_header :: proc(ui: ^p.Ctx, nt: ^Notes) {
	n, has := open_note(nt)
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-2 px-5 border-b border-border")
	defer p.end(ui)

	if nt.layout == .One {
		p.key(ui, "back")
		b := p.row(ui, "h-7 shrink-0 items-center gap-1 pr-2 rounded-md hover:bg-accent cursor-pointer")
		if p.clickable(ui, b) {
			flush(nt)
			nt.pane = .List
		}
		p.icon(ui, ICON_CHEVRON_LEFT, "size-4 text-muted-foreground")
		p.text(ui, "Notes", "text-[12.5] text-muted-foreground")
		p.end(ui)
	}

	// Where this note is: identity › notebook, or whose it is.
	p.row(ui, "flex-1 min-w-0 items-center gap-1.5 overflow-hidden")
	if nt.layout == .One {
		monogram(ui, nt, nt.open_ident, 20)
	} else {
		id_chip(ui, nt, nt.open_ident, true)
	}
	if has {
		crumb :: proc(ui: ^p.Ctx, text: string) {
			p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
			p.text(ui, text, "text-[12] text-muted-foreground whitespace-nowrap truncate")
		}
		switch {
		case n.shared:
			crumb(ui, tfmt("Shared by %s", n.meta.shared_from))
		case n.trashed:
			crumb(ui, "Trash")
		case n.notebook != "":
			parts := strings.split(n.notebook, "/", context.temp_allocator)
			for part, k in parts {
				if nt.layout == .One && k < len(parts) - 1 {continue}
				crumb(ui, part)
			}
		case:
			crumb(ui, "Inbox")
		}
		if n.meta.pinned {
			p.icon(ui, ICON_PIN, "size-3 shrink-0 text-muted-foreground ml-1")
		}
		if n.meta.carried_from != "" {
			p.text(ui, tfmt("· carried from %s", n.meta.carried_from[:max(0, strings.index_byte(n.meta.carried_from, '/'))]), "text-[11] text-muted-foreground/80 whitespace-nowrap shrink-0")
		}
	}
	p.end(ui)

	presence(ui, nt)
	text, tone := "", ""
	if nt.live.s != nil {
		text, tone = sync_line(nt)
	}
	_ = text
	_ = tone

	icon_button :: proc(ui: ^p.Ctx, key: string, ic: p.Icon, tip: string) -> bool {
		p.key(ui, key)
		b := p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-md hover:bg-accent transition cursor-pointer")
		hit := p.clickable(ui, b)
		p.icon(ui, ic, "size-4 text-muted-foreground")
		p.end(ui)
		return hit
	}
	if has && !n.shared && nt.layout != .One {
		if icon_button(ui, "pin", ICON_PIN, "Pin") {
			toggle_pin(nt)
		}
		if len(nt.ids) > 1 && icon_button(ui, "carry", ICON_COPY_PLUS, "Carry") {
			open_carry(nt)
		}
	}
	if has && !n.shared && ident_bound(nt.ids[nt.open_ident]) {
		// Share is the primary action, in the identity's colour (P2).
		p.key(ui, "share")
		i := nt.open_ident
		sb := p.row(ui, tfmt("h-8 shrink-0 items-center gap-1.5 px-3 rounded-lg bg-%s hover:bg-%s/90 %s transition cursor-pointer", id_tok(i), id_tok(i), on_identity(nt)))
		if p.clickable(ui, sb) {
			open_share(nt)
		}
		p.icon(ui, ICON_USER_PLUS, "size-3.5 shrink-0")
		p.text(ui, "Share", "text-[12.5] font-medium whitespace-nowrap")
		p.end(ui)
	}
}

// presence draws the people in this note right now, in their identities'
// colours, with their names (colour is never alone).
presence :: proc(ui: ^p.Ctx, nt: ^Notes) {
	peers := live_peers(nt)
	if len(peers) == 0 {
		return
	}
	p.row(ui, "items-center gap-1 shrink-0 pr-1")
	for pe in peers {
		hex := identity_hex(pe.color, nt.dark)
		p.row(ui, "h-6 items-center gap-1 pl-0.5 pr-2 rounded-full border border-border bg-background")
		dot := p.div(ui, "flex-row size-[18] rounded-full items-center justify-center")
		p.style(ui, dot).bg = p.flat(p.hex(hex))
		p.text(ui, monogram_of(pe.name), "text-[10] font-semibold text-white")
		p.end(ui)
		p.text(ui, pe.name, "text-[11] whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
}

writing_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	outer := p.col(ui, "flex-1 min-h-0 w-full relative overflow-hidden items-center pt-5")
	defer p.end(ui)
	colw := nt.body_w
	page := p.col(ui, "h-full relative")
	p.style(ui, page).w = p.px(colw)
	defer p.end(ui)

	wrap_rebuild(&nt.wrap, ui, &nt.buf, nt.body_w, nt.rev)
	rows := nt.wrap.rows[:]
	nt.top = clamp(nt.top, 0, max(0, len(rows) - 1))
	nt.rows = rows_fitting(&nt.wrap, nt.top, nt.view_h)

	if p.clickable(ui, outer) {
		r := p.rect_of(ui, p.node_id(ui, page))
		m := p.mouse_pos(ui)
		row := row_at_y(&nt.wrap, nt.top, m.y - r.y)
		nt.cur = pos_clamp(&nt.buf, col_at(&nt.wrap, ui, &nt.buf, row, m.x - r.x))
		nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
		ed_clear_sel(nt)
		nt.pane = .Editor
		prose_select_at(nt)
	}

	sel_lo, sel_hi, has_sel := ed_sel(nt)
	cur_row := row_of(&nt.wrap, nt.cur)
	caret_on := math.mod(f64(p.elapsed(ui)), 1.06) < 0.62
	if nt.pane == .Editor {
		p.redraw(ui)
	}

	// Other people's carets, as buffer positions.
	Peer_Pos :: struct {
		at:    Pos,
		name:  string,
		color: u32,
	}
	peers := make([dynamic]Peer_Pos, context.temp_allocator)
	for pe in live_peers(nt) {
		append(&peers, Peer_Pos{doc_pos(nt, pe.caret), pe.name, identity_hex(pe.color, nt.dark)})
	}

	line_off := line_offset(nt, rows[nt.top].line)
	prev_line := rows[nt.top].line
	y: f32 = 0
	for ri := nt.top; ri < len(rows); ri += 1 {
		r := rows[ri]
		if y > nt.view_h + 40 {
			break
		}
		y += r.h
		src := buf_line(&nt.buf, r.line)
		for l in prev_line ..< r.line {
			line_off += len(buf_line(&nt.buf, l)) + 1
		}
		prev_line = r.line
		st := nt.wrap.styles[r.line]
		caret_line := nt.cur.line == r.line && nt.pane == .Editor

		p.key(ui, tfmt("r%d", ri))
		p.row(ui, tfmt("h-[%v] w-full shrink-0 relative items-center", r.h))

		// Code blocks get a tint across the column, behind everything.
		if st.kind == .Code || st.kind == .Fence {
			bgk := p.div(ui, "absolute bg-muted")
			bs := p.style(ui, bgk)
			bs.inset[p.LEFT] = p.px(-10)
			bs.inset[p.TOP] = p.px(0)
			bs.w = p.px(colw + 20)
			bs.h = p.px(r.h)
			bs.no_hit = true
			p.end(ui)
		}
		if st.kind == .Quote && r.from == 0 {
			// handled with the chevron below
		}

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
				x0 := row_x(&nt.wrap, ui, &nt.buf, r, a)
				x1 := row_x(&nt.wrap, ui, &nt.buf, r, b)
				band_at(ui, x0, x1 - x0, r.h)
			} else if a >= 0 && b == a && r.to == r.from && sel_hi.line > r.line {
				band_at(ui, 0, 6, r.h)
			}
		}

		// Marks under the text, caret over it.
		prose_marks_for_row(ui, nt, r, line_off)

		draw_segments(ui, nt, src, r, st, caret_line)

		for pp in peers {
			if row_of(&nt.wrap, pp.at) != ri {continue}
			x := caret_x(&nt.wrap, ui, &nt.buf, pp.at)
			pc := p.div(ui, "absolute w-[2] rounded-[1]")
			ps := p.style(ui, pc)
			ps.bg = p.flat(p.hex(pp.color))
			ps.inset[p.LEFT] = p.px(x)
			ps.inset[p.TOP] = p.px(2)
			ps.h = p.px(r.h - 4)
			ps.no_hit = true
			p.end(ui)
			flag := p.row(ui, "absolute h-[16] px-1.5 rounded-[4] items-center")
			fs := p.style(ui, flag)
			fs.bg = p.flat(p.hex(pp.color))
			fs.inset[p.LEFT] = p.px(x)
			fs.inset[p.TOP] = p.px(-13)
			fs.no_hit = true
			p.text(ui, pp.name, "text-[10] font-medium text-white whitespace-nowrap")
			p.end(ui)
		}

		if ri == cur_row && caret_on && nt.pane == .Editor && !read_only(nt) {
			x := caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
			ci := view_ident(nt)
			cb := p.div(ui, tfmt("absolute w-[2] rounded-[1] bg-%s", ci >= 0 ? id_tok(ci) : "accent-blue"))
			cs := p.style(ui, cb)
			cs.inset[p.LEFT] = p.px(x)
			cs.inset[p.TOP] = p.px(3)
			cs.h = p.px(r.h - 6)
			p.end(ui)
		}
		p.end(ui)
	}

	scroll_hint(ui, nt)
}

// draw_segments draws one visual row's text, styled. The marks that are
// replaced by a drawing (a task's box, a bullet, a quote bar, a rule) are
// transparent text of the same width, so the caret maths never changes; on
// the caret's line they show as the characters they are.
draw_segments :: proc(ui: ^p.Ctx, nt: ^Notes, src: string, r: Vis, st: Line_Style, caret_line: bool) {
	x: f32 = 0
	for si in st.seg_lo ..< st.seg_hi {
		sg := nt.wrap.segs[si]
		a := max(sg.from, r.from)
		b := min(sg.to, r.to)
		if b <= a {
			continue
		}
		text := src[a:b]
		w := seg_w(ui, text, st.kind, sg.kind)
		f := face_of(st.kind, sg.kind)
		cls := strings.builder_make(context.temp_allocator)
		strings.write_string(&cls, tfmt("text-[%v] whitespace-nowrap shrink-0", f.size))
		if f.fam == .Mono {
			strings.write_string(&cls, " font-mono")
		}
		switch f.wt {
		case .Medium:
			strings.write_string(&cls, " font-medium")
		case .Semibold:
			strings.write_string(&cls, " font-semibold")
		case .Bold:
			strings.write_string(&cls, " font-bold")
		case .Regular:
		}
		if f.sl == .Italic {
			strings.write_string(&cls, " italic")
		}
		done := st.kind == .Done && sg.from >= st.seg_lo && a > 0
		replaced := !caret_line && (sg.kind == .Box || sg.kind == .Dash || sg.kind == .Chevron || st.kind == .Rule)
		switch {
		case replaced:
			strings.write_string(&cls, " text-transparent")
		case sg.kind == .Mark || sg.kind == .Box || sg.kind == .Dash || sg.kind == .Chevron:
			strings.write_string(&cls, " text-muted-foreground/45")
		case sg.kind == .Code:
			strings.write_string(&cls, nt.dark ? " text-rose-300 bg-muted rounded-[3]" : " text-rose-600 bg-muted rounded-[3]")
		case sg.kind == .Wiki:
			strings.write_string(&cls, " text-accent-blue font-medium")
		case sg.kind == .Wiki_Out:
			strings.write_string(&cls, nt.dark ? " text-amber-400 italic" : " text-amber-600 italic")
		case sg.kind == .Link:
			strings.write_string(&cls, " text-accent-blue underline")
		case sg.kind == .Tag:
			strings.write_string(&cls, " text-accent-blue bg-accent-blue/10 rounded-[3]")
		case sg.kind == .Strike:
			strings.write_string(&cls, " text-muted-foreground line-through")
		case st.kind == .Quote:
			strings.write_string(&cls, " text-muted-foreground")
		case done:
			strings.write_string(&cls, " text-muted-foreground line-through")
		case st.kind == .Code || st.kind == .Fence:
			strings.write_string(&cls, " text-foreground/90")
		case:
			strings.write_string(&cls, " text-foreground")
		}
		p.text(ui, text, strings.to_string(cls))

		if replaced {
			switch {
			case sg.kind == .Box:
				on := st.kind == .Done
				p.key(ui, tfmt("box-%d", r.line))
				bx := p.div(ui, "absolute flex-row size-[15] items-center justify-center rounded-[4] border cursor-pointer")
				bst := p.style(ui, bx)
				bst.inset[p.LEFT] = p.px(x + (w - 15) / 2)
				bst.inset[p.TOP] = p.px((r.h - 15) / 2)
				ci := view_ident(nt)
				p.apply(ui, on ? tfmt("bg-%s border-%s", id_tok(ci), id_tok(ci)) : "bg-background border-input hover:border-foreground/50", bx)
				if p.clickable(ui, bx) && !read_only(nt) {
					toggle_task_at(nt, r.line)
				}
				if on {
					p.icon(ui, ICON_CHECK, tfmt("size-2.5 %s", on_identity(nt)))
				}
				p.end(ui)
			case sg.kind == .Dash && (st.kind == .Task || st.kind == .Done):
				// A task's dash is the box's: nothing drawn.
			case sg.kind == .Dash:
				d := p.div(ui, "absolute size-[5] rounded-full bg-foreground/60")
				ds := p.style(ui, d)
				ds.inset[p.LEFT] = p.px(x + w / 2 - 2.5)
				ds.inset[p.TOP] = p.px(r.h / 2 - 2.5)
				ds.no_hit = true
				p.end(ui)
			case sg.kind == .Chevron:
				q := p.div(ui, "absolute w-[3] rounded-full bg-border")
				qs := p.style(ui, q)
				qs.inset[p.LEFT] = p.px(x + 1)
				qs.inset[p.TOP] = p.px(2)
				qs.h = p.px(r.h - 4)
				qs.no_hit = true
				p.end(ui)
			case st.kind == .Rule:
				l := p.div(ui, "absolute h-px bg-border")
				ls := p.style(ui, l)
				ls.inset[p.LEFT] = p.px(0)
				ls.inset[p.TOP] = p.px(r.h / 2)
				ls.w = p.px(nt.body_w)
				ls.no_hit = true
				p.end(ui)
			}
		}
		x += w
	}
}

band_at :: proc(ui: ^p.Ctx, x, w, h: f32) {
	idx := p.div(ui, "absolute rounded-[2] bg-accent-blue/25")
	s := p.style(ui, idx)
	s.inset[p.LEFT] = p.px(x)
	s.inset[p.TOP] = p.px(0)
	s.w = p.px(max(3, w))
	s.h = p.px(h)
	s.no_hit = true
	p.end(ui)
}

scroll_hint :: proc(ui: ^p.Ctx, nt: ^Notes) {
	total := len(nt.wrap.rows)
	if total <= nt.rows {
		return
	}
	view_h := nt.view_h
	h := max(28, view_h * f32(nt.rows) / f32(total))
	t := f32(nt.top) / f32(max(1, total - nt.rows))
	sb := p.div(ui, "absolute right-[-16] w-[5] rounded-full bg-foreground/15")
	s := p.style(ui, sb)
	s.inset[p.TOP] = p.px((view_h - h) * t)
	s.h = p.px(h - 4)
	p.end(ui)
}

// toggle_task_at ticks or unticks the task on buffer line `li`.
toggle_task_at :: proc(nt: ^Notes, li: int) {
	src := buf_line(&nt.buf, li)
	ind := indent_of(src)
	if len(src) < ind + 5 || src[ind + 2] != '[' {
		return
	}
	at := ind + 3
	ch := src[at] == ' ' ? "x" : " "
	nt.cur = buf_apply(&nt.buf, {li, at}, {li, at + 1}, ch, nt.cur, .No)
	nt.pending = true
	nt.rev += 1
	live_edit(nt)
}

reading_pane :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll items-center py-5")
	defer p.end(ui)
	c := p.col(ui, "gap-0")
	p.style(ui, c).w = p.px(nt.body_w)
	md_render(ui, buffer_text(nt), nt.space_w)
	p.end(ui)
}

// backlinks_panel lists the notes of this identity that link here, with the
// line that mentions it, and this note's links out of the identity.
backlinks_panel :: proc(ui: ^p.Ctx, nt: ^Notes) {
	self := -1
	for n, i in nt.all {
		if n.path == nt.open_path {self = i}
	}
	if self < 0 {
		return
	}
	n := nt.all[self]
	own := nt.ids[n.ident].handle
	back := backlinks(nt.all[:], self, own)
	outs := make([dynamic]Link, context.temp_allocator)
	unresolved := 0
	for l in links_in(buffer_text(nt)) {
		k, _ := link_resolve(nt.all[:], n.ident, own, l)
		switch k {
		case .Elsewhere:
			append(&outs, l)
		case .Unresolved:
			unresolved += 1
		case .Resolved:
		}
	}
	p.col(ui, tfmt("w-full h-[%d] shrink-0 border-t border-border bg-sidebar/60 px-6 py-3 gap-1.5 overflow-hidden", BACKLINKS_H))
	defer p.end(ui)
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ICON_LINK, "size-3.5 text-muted-foreground shrink-0")
	p.textf(ui, "text-[10.5] font-semibold tracking-wide text-muted-foreground", "LINKED FROM %d", len(back))
	if unresolved > 0 {
		p.textf(ui, "text-[10.5] text-muted-foreground/70 whitespace-nowrap", "· %d link%s to notes not written yet", unresolved, unresolved == 1 ? "" : "s")
	}
	p.spacer(ui, "flex-1")
	sc.kbd(ui, "Ctrl Alt B")
	p.text(ui, "hide", "text-[10.5] text-muted-foreground/70")
	p.end(ui)
	if len(back) == 0 && len(outs) == 0 {
		p.text(ui, tfmt("No note in %s links here yet. Write [[%s]] in one.", nt.ids[n.ident].name, n.title), "text-[11.5] text-muted-foreground/80 truncate")
	}
	for bi, k in back {
		if k >= 3 {break}
		src := nt.all[bi]
		ctx := ""
		for l in links_in(src.body) {
			kk, at := link_resolve(nt.all[:], src.ident, own, l)
			if kk == .Resolved && at == self {
				ctx = link_context(src.body, l)
				break
			}
		}
		p.key(ui, tfmt("bl-%s", src.path))
		row := p.row(ui, "w-full items-center gap-2 px-2 py-1 rounded-md hover:bg-accent cursor-pointer min-w-0")
		if p.clickable(ui, row) {
			goto_note(nt, bi)
		}
		p.icon(ui, ICON_FILE_TEXT, "size-3.5 text-muted-foreground shrink-0")
		p.text(ui, src.title, "text-[12] font-medium whitespace-nowrap shrink-0")
		p.text(ui, plain_md(ctx), "flex-1 min-w-0 truncate text-[11.5] text-muted-foreground")
		p.end(ui)
	}
	for l in outs {
		ti := ident_find(nt.ids[:], l.handle)
		p.row(ui, "w-full items-center gap-2 px-2 py-1 min-w-0")
		p.icon(ui, ICON_ARROW_UP_RIGHT, "size-3.5 text-amber-600 shrink-0")
		p.text(ui, tfmt("Links out to %s: %s", ti >= 0 ? nt.ids[ti].name : l.handle, l.target), "text-[11.5] text-muted-foreground truncate")
		p.text(ui, "opens there, never here", "text-[10.5] text-muted-foreground/70 whitespace-nowrap shrink-0")
		p.end(ui)
	}
}

goto_note :: proc(nt: ^Notes, idx: int) {
	target := nt.all[idx]
	path := strings.clone(target.path, context.temp_allocator)
	if !in_view(nt, target) {
		set_view(nt, View{ident = target.ident, section = .All})
		build_side(nt)
		set_view(nt, View{ident = target.ident, section = .All})
	}
	clear(&nt.query)
	refilter(nt)
	for v, i in nt.vis {
		if nt.all[v].path == path {
			nt.sel = i
		}
	}
	open_sel(nt)
	nt.pane = .Editor
}

empty_editor :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-3 px-10")
	defer p.end(ui)

	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ICON_NOTEBOOK_PEN, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, len(nt.all) == 0 ? "No notes yet" : "No note open", "text-[15] font-semibold")
	p.text(ui, "Notes are Markdown files on disk, one folder per identity. Ctrl+N starts one.", "max-w-[380] text-center text-[12.5] text-muted-foreground")
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status :: proc(ui: ^p.Ctx, nt: ^Notes) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border overflow-hidden", STATUS_H))
	defer p.end(ui)

	label := nt.pane == .List ? "Notes" : (nt.pane == .Sidebar ? "Identities" : (nt.preview ? "Reading" : "Writing"))
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
	case nt.pane == .Sidebar:
		hint(ui, "Up Down", "choose")
		hint(ui, "Enter", "show")
		hint(ui, "Ctrl 0-9", "identity")
	case nt.pane == .List:
		hint(ui, "Enter", "edit")
		hint(ui, "Ctrl N", "new")
		hint(ui, "Delete", nt.view.section == .Trash ? "restore" : "trash")
		hint(ui, "Ctrl Alt K", "share")
	case:
		hint(ui, "Ctrl Enter", "tick")
		hint(ui, "Alt Enter", "follow link")
		hint(ui, "Ctrl Alt K", "share")
		hint(ui, "F1", "keys")
	}

	p.spacer(ui, "flex-1")

	if n, ok := open_note(nt); ok {
		if !nt.preview && nt.pane == .Editor {
			p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0", "Ln %d, Col %d", nt.cur.line + 1, nt.cur.col + 1)
			p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
		}
		p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0", "%d words", n.words)
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
		if nt.pr.on {
			p.textf(ui, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0", "%s · %d issue%s", prose_style_name(nt), len(nt.pr.alerts), len(nt.pr.alerts) == 1 ? "" : "s")
			p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
		}
	}
	p.text(ui, nt.pending ? "saving…" : "saved", nt.pending ? "text-[11.5] text-amber-600 whitespace-nowrap shrink-0" : "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0")
	if nt.layout == .One {
		text, _ := sync_line(nt)
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
		p.text(ui, text, "text-[11.5] text-muted-foreground whitespace-nowrap shrink-0")
	}
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
	ww := min(f32(w), win.x - 16)
	wrap := p.div(ui, "absolute z-50")
	s := p.style(ui, wrap)
	s.w = p.px(ww)
	s.inset[p.LEFT] = p.px(max(8, (win.x - ww) / 2))
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

field_box :: proc(ui: ^p.Ctx, value, placeholder: string) {
	p.row(ui, "h-9 w-full items-center gap-1 px-3 rounded-lg border border-ring ring-3 ring-ring/30 bg-background overflow-hidden")
	p.text(ui, value == "" ? placeholder : value, value == "" ? "text-[13.5] text-muted-foreground/60 whitespace-nowrap shrink-0" : "text-[13.5] text-foreground whitespace-nowrap shrink-0")
	p.redraw(ui)
	if math.mod(f64(p.elapsed(ui)), 1.06) < 0.62 {
		p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)
}

// from_card leads every share and carry: who is acting, in their colour,
// before anything else (product.md P2).
from_card :: proc(ui: ^p.Ctx, nt: ^Notes, i: int, verb: string) {
	p.row(ui, tfmt("w-full items-center gap-3 px-3 py-2.5 rounded-lg bg-%s/8 border border-%s/25", id_tok(i), id_tok(i)))
	monogram(ui, nt, i, 30)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, tfmt("%s %s", verb, nt.ids[i].name), tfmt("text-[13] font-semibold text-%s", id_tok(i)))
	p.text(ui, tfmt("%s · %s", nt.ids[i].handle, nt.ids[i].kind != "" ? nt.ids[i].kind : "local"), "text-[11.5] text-muted-foreground truncate")
	p.end(ui)
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
	p.text(ui, "The title is the note's first line, and the file on disk is renamed to match.", "text-[12] text-muted-foreground")
	p.end(ui)
	v := string(nt.rename[:])
	field_box(ui, v, "Untitled")
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ICON_FILE_TEXT, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, tfmt("%s.md", slug(v == "" ? "untitled" : v)), "flex-1 min-w-0 truncate text-[11.5] font-mono text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", "rename")
	p.end(ui)
}

move_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 460, max(8, win.y / 2 - 170))
	defer sheet_close(ui)
	p.col(ui, "w-full px-5 pt-5 pb-4 gap-3")
	p.text(ui, "File in a notebook", "text-[15] font-semibold")
	p.text(ui, tfmt("A notebook is a folder of %s's notes. Leave it empty for the inbox; a / nests one.", nt.ids[nt.open_ident].name), "text-[12] text-muted-foreground")
	field_box(ui, string(nt.move_to[:]), "Inbox")
	books := notebooks_of(nt.all[:], nt.open_ident)
	if len(books) > 0 {
		p.row(ui, "w-full flex-wrap gap-1.5")
		for b in books {
			p.row(ui, "h-6 items-center gap-1 px-2 rounded-md bg-muted")
			p.icon(ui, ICON_FOLDER, "size-3 text-muted-foreground")
			p.text(ui, b.name, "text-[11.5] whitespace-nowrap")
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", "move")
	p.end(ui)
}

delete_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	n, _ := selected(nt)
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 150))
	defer sheet_close(ui)

	p.col(ui, "w-full items-center px-6 pt-6 pb-4 gap-4")
	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-red-500/12 shrink-0")
	p.icon(ui, ICON_TRASH, "size-4.5 text-destructive")
	p.end(ui)
	p.col(ui, "items-center gap-1.5 w-full")
	p.text(ui, "Delete for good?", "text-[16] font-semibold")
	p.text(ui, tfmt("\"%s\" will be removed from this device and, once synced, from every device of %s. The trash is the way to keep it recoverable.", n.title, n.ident < len(nt.ids) ? nt.ids[n.ident].name : ""), "max-w-[360] text-center text-[12.5] text-muted-foreground")
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

// share_dialog: the From card, who to share with and at what level, and who
// has it now. A share is a row the owner can revoke.
share_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 520, max(8, win.y / 2 - 230))
	defer sheet_close(ui)
	n, _ := open_note(nt)
	p.col(ui, "w-full px-5 pt-5 pb-4 gap-3.5")
	p.col(ui, "gap-1")
	p.text(ui, tfmt("Share \"%s\"", n != nil ? n.title : ""), "text-[15] font-semibold truncate")
	p.text(ui, tfmt("Give one identity — someone else's, or another of yours — this note, to read or to edit. Nothing else of %s comes with it, and you can revoke it.", nt.ids[nt.open_ident].name), "text-[12] text-muted-foreground")
	p.end(ui)
	from_card(ui, nt, nt.open_ident, "Sharing as")
	p.row(ui, "w-full items-center gap-2")
	p.col(ui, "flex-1 min-w-0")
	field_box(ui, string(nt.share_handle[:]), "an identity's handle, e.g. bob.okafor")
	p.end(ui)
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	for label, k in ([?]string{"Read", "Edit"}) {
		on := (k == 1) == nt.share_edit
		p.key(ui, tfmt("acc-%s", label))
		seg := p.div(ui, "flex-row h-7 px-3 items-center justify-center rounded-md transition cursor-pointer")
		p.apply(ui, on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground", seg)
		if p.clickable(ui, seg) {
			nt.share_edit = k == 1
		}
		p.text(ui, label, "text-[12] font-medium")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	if nt.share_msg != "" {
		p.text(ui, nt.share_msg, "text-[11.5] text-muted-foreground")
	}
	p.text(ui, "WHO HAS IT", "pt-1 text-[10] font-semibold tracking-wide text-muted-foreground/70")
	if len(nt.people) == 0 {
		p.text(ui, "Only you.", "text-[12] text-muted-foreground")
	}
	for pe, k in nt.people {
		on := k == nt.share_sel
		p.row(ui, "w-full h-9 items-center gap-2.5 px-2 rounded-md")
		if on {
			p.apply(ui, "bg-accent")
		}
		hex := identity_hex(pe.color, nt.dark)
		dot := p.div(ui, "flex-row size-[22] rounded-full items-center justify-center")
		p.style(ui, dot).bg = p.flat(p.hex(hex))
		p.text(ui, monogram_of(pe.name), "text-[10.5] font-semibold text-white")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-px")
		p.text(ui, pe.name, "text-[12.5] font-medium truncate")
		p.text(ui, pe.handle, "text-[11] text-muted-foreground truncate")
		p.end(ui)
		p.text(ui, pe.access == "owner" ? "owner" : (pe.access == "edit" ? "can edit" : "can read"), "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "Tab", "read / edit")
	hint(ui, "Enter", "share")
	hint(ui, "Up Down Delete", "revoke")
	hint(ui, "Esc", "close")
	p.end(ui)
}

// carry_dialog: a copy into another of your identities, stated in both
// colours and in words before it happens.
carry_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 540, max(8, win.y / 2 - 200))
	defer sheet_close(ui)
	n, _ := open_note(nt)
	src := nt.open_ident
	p.col(ui, "w-full px-5 pt-5 pb-4 gap-3.5")
	p.col(ui, "gap-1")
	p.text(ui, tfmt("Carry \"%s\"", n != nil ? n.title : ""), "text-[15] font-semibold truncate")
	p.text(ui, "A carry makes a copy in another of your identities. It belongs to that identity from then on; the original stays where it is.", "text-[12] text-muted-foreground")
	p.end(ui)
	from_card(ui, nt, src, "From")
	p.text(ui, "TO", "text-[10] font-semibold tracking-wide text-muted-foreground/70")
	p.row(ui, "w-full flex-wrap gap-2")
	k := 0
	for id, i in nt.ids {
		if i == src {continue}
		k += 1
		on := i == nt.carry_to
		p.key(ui, tfmt("carry-%s", id.handle))
		c := p.row(ui, "h-9 items-center gap-2 pl-1.5 pr-3 rounded-lg border transition cursor-pointer")
		p.apply(ui, on ? tfmt("border-%s bg-%s/10 ring-2 ring-%s/30", id_tok(i), id_tok(i), id_tok(i)) : "border-border hover:bg-accent", c)
		if p.clickable(ui, c) {
			nt.carry_to = i
		}
		monogram(ui, nt, i, 24)
		p.text(ui, id.name, "text-[12.5] font-medium whitespace-nowrap")
		sc.kbd(ui, tfmt("%d", k))
		p.end(ui)
	}
	p.end(ui)
	if nt.carry_to >= 0 && nt.carry_to < len(nt.ids) {
		p.row(ui, "w-full items-center gap-2 px-3 py-2.5 rounded-lg bg-muted/60")
		p.div(ui, tfmt("size-[8] rounded-full bg-%s", id_tok(src)))
		p.end(ui)
		p.text(ui, nt.ids[src].name, tfmt("text-[12.5] font-medium text-%s", id_tok(src)))
		p.icon(ui, ICON_ARROW_RIGHT, "size-3.5 text-muted-foreground")
		p.div(ui, tfmt("size-[8] rounded-full bg-%s", id_tok(nt.carry_to)))
		p.end(ui)
		p.text(ui, nt.ids[nt.carry_to].name, tfmt("text-[12.5] font-medium text-%s", id_tok(nt.carry_to)))
		p.text(ui, "· a copy, not a link", "text-[12] text-muted-foreground")
		p.end(ui)
		p.text(ui, tfmt("Both carry logs record it: %s's as out, %s's as in, with when, from which device, and a hash of the text.", nt.ids[src].name, nt.ids[nt.carry_to].name), "text-[11.5] text-muted-foreground")
	}
	p.end(ui)
	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	hint(ui, "1-9", "choose")
	hint(ui, "Enter", "carry")
	hint(ui, "Esc", "cancel")
	p.end(ui)
}

// choose_dialog asks which identity a new note belongs to. It refuses Enter
// until one is chosen: nothing defaults across identities (P3).
choose_dialog :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 460, max(8, win.y / 2 - 150))
	defer sheet_close(ui)
	p.col(ui, "w-full px-5 pt-5 pb-4 gap-3")
	p.text(ui, "New note, as whom?", "text-[15] font-semibold")
	p.text(ui, "You are looking at every identity. A note belongs to exactly one.", "text-[12] text-muted-foreground")
	for id, i in nt.ids {
		on := i == nt.choose_sel
		p.key(ui, tfmt("choose-%s", id.handle))
		c := p.row(ui, "w-full h-11 items-center gap-2.5 px-2.5 rounded-lg border transition cursor-pointer")
		p.apply(ui, on ? tfmt("border-%s bg-%s/10", id_tok(i), id_tok(i)) : "border-border hover:bg-accent", c)
		if p.clickable(ui, c) {
			nt.choose_sel = i
		}
		monogram(ui, nt, i, 26)
		p.col(ui, "flex-1 min-w-0 gap-px")
		p.text(ui, id.name, "text-[13] font-medium")
		p.text(ui, id.handle, "text-[11] text-muted-foreground")
		p.end(ui)
		sc.kbd(ui, tfmt("%d", i + 1))
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "h-[42] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
	if nt.choose_sel < 0 {
		p.text(ui, "Choose an identity first", "text-[11.5] text-muted-foreground")
		p.spacer(ui, "flex-1")
	}
	hint(ui, "1-9", "choose")
	hint(ui, "Enter", "create")
	p.end(ui)
}

HELP_ROWS := [?][2]string {
	{"Ctrl N  or  F4", "new note, in this identity"},
	{"Ctrl F  or  /", "search, on this device"},
	{"Ctrl 1-9 / Ctrl 0", "one identity / all identities"},
	{"Tab / Shift Tab", "list, note, sidebar"},
	{"Ctrl \\", "show or hide the sidebar"},
	{"Ctrl Enter", "tick the task on this line"},
	{"Alt Enter", "follow a [[link]]"},
	{"Ctrl B / Ctrl I", "bold, italic"},
	{"Ctrl Alt K", "share with an identity"},
	{"Ctrl Shift C", "carry a copy elsewhere"},
	{"Ctrl Alt M", "file in a notebook"},
	{"Ctrl Alt P", "pin or unpin"},
	{"Ctrl Alt B", "the backlinks panel"},
	{"Ctrl Alt O", "work offline, then reconnect"},
	{"Delete", "to the trash, or back"},
	{"Shift Delete", "delete for good"},
	{"F2", "rename"},
	{"F3", "writing or reading"},
	{"F5", "sync now"},
	{"F6 / F7 / F8", "writing report, style, issue"},
	{"Ctrl Z / Ctrl Y", "undo, redo (yours only)"},
	{"Ctrl O / Ctrl Shift S", "import, export"},
	{"Ctrl Q", "quit, saving first"},
}

MD_ROWS := [?][2]string {
	{"# ## ###", "headings"},
	{"**bold**", "bold"},
	{"*emphasis*", "emphasis"},
	{"`code`", "inline code"},
	{"[[Title]]", "link a note here"},
	{"[[work:Title]]", "a link out, never resolved here"},
	{"#tag", "a tag"},
	{"- item", "bullet; Return continues it"},
	{"- [ ] / - [x]", "tasks"},
	{"> quote", "quotation"},
	{"---", "a rule"},
}

help_sheet :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 1040, max(8, (win.y - 450) / 2))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-3")
	p.icon(ui, ICON_KEYBOARD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, "Notes, from the keyboard", "text-[15] font-semibold")
	p.text(ui, "Nothing here needs the pointer. Quick capture from anywhere: the shell runs `notes capture`.", "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full px-5 pb-5 gap-6 items-start")
	half := (len(HELP_ROWS) + 1) / 2
	for col in 0 ..< 2 {
		p.col(ui, "flex-1 min-w-0 gap-1.5")
		p.text(ui, col == 0 ? "KEYS" : " ", "text-[10] font-semibold tracking-wide text-muted-foreground/70 pb-0.5")
		lo := col == 0 ? 0 : half
		hi := col == 0 ? half : len(HELP_ROWS)
		for row in HELP_ROWS[lo:hi] {
			p.row(ui, "w-full items-center gap-2.5")
			p.row(ui, "w-[128] shrink-0 justify-end")
			sc.kbd(ui, row[0])
			p.end(ui)
			p.text(ui, row[1], "flex-1 min-w-0 text-[11.5] text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
	}

	p.col(ui, "w-[250] shrink-0 gap-1.5")
	p.text(ui, "MARKDOWN", "text-[10] font-semibold tracking-wide text-muted-foreground/70 pb-0.5")
	for row in MD_ROWS {
		p.row(ui, "w-full items-center gap-2.5")
		p.text(ui, row[0], "w-[104] shrink-0 text-right font-mono text-[11] text-foreground")
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
	if f64(p.elapsed(ui)) - nt.toast_at > 3.2 {
		delete(nt.toast)
		nt.toast = ""
		nt.toast_at = 0
		return
	}
	p.redraw(ui)

	idx := p.row(ui, "absolute z-30 right-[16] bottom-[40] max-w-[460] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg")
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-accent-blue")
	p.text(ui, nt.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
