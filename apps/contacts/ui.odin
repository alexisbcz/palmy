// The frame: header, the identity sidebar, the list, the card, the dialogs.
package main

import "core:strings"
import dc "../../cloud/dav/client"
import p "palmy:."
import sc "shadcn:."

HEADER_H :: 56
STATUS_H :: 26
SIDE_W :: 256
LIST_W :: 340

dc_signed :: proc(s: ^App_State) -> bool {
	return s.st.acct != nil && dc.signed_in(s.st.acct)
}

signed_out :: proc(s: ^App_State) -> bool {
	return s.mode == .Sign_In || (!s.fixture && !dc_signed(s))
}

frame :: proc(ui: ^p.Ctx, s: ^App_State) {
	build_side(s)
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	header(ui, s)
	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	sidebar(ui, s)
	list_pane(ui, s)
	detail(ui, s)
	p.end(ui)
	status(ui, s)

	switch s.mode {
	case .Edit:
		form_dialog(ui, s)
	case .Confirm_Delete:
		delete_dialog(ui, s)
	case .Groups:
		groups_dialog(ui, s)
	case .Group_Name:
		group_name_dialog(ui, s)
	case .Merge:
		merge_dialog(ui, s)
	case .Sign_In:
		signin_dialog(ui, s)
	case .Help:
		help_sheet(ui, s)
	case .Import, .Export:
		path_dialog(ui, s)
	case .Normal, .Search:
	}
	toast(ui, s)
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, s: ^App_State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-4 bg-sidebar border-b border-border", HEADER_H))
	defer p.end(ui)

	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-background border border-border")
	p.icon(ui, ICON_USERS, "size-4 text-muted-foreground")
	p.end(ui)
	p.col(ui, "gap-px min-w-0 w-[200] shrink-0")
	p.text(ui, "Contacts", "text-[17] font-semibold whitespace-nowrap")
	people := 0
	for c in s.st.contacts {
		if !is_group(c) {
			people += 1
		}
	}
	p.text(
		ui,
		tfmt("%d people · %d identit%s", people, len(s.st.idents), len(s.st.idents) == 1 ? "y" : "ies"),
		"text-[11] text-muted-foreground whitespace-nowrap",
	)
	p.end(ui)

	// The search box: "/" focuses it.
	searching := s.mode == .Search
	p.key(ui, "search")
	sb := p.row(ui, "w-[360] shrink-0 h-8 items-center gap-2 px-2.5 rounded-lg border bg-background overflow-hidden cursor-text")
	p.apply(ui, searching ? "border-ring ring-3 ring-ring/40" : "border-input", sb)
	if p.clickable(ui, sb) {
		s.mode = .Search
	}
	p.icon(ui, sc.ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
	q := string(s.query[:])
	p.text(
		ui,
		q == "" ? "Search names, email, phone, company" : q,
		q == "" ? "text-[12.5] text-muted-foreground/70 whitespace-nowrap shrink-0" : "text-[12.5] text-foreground whitespace-nowrap shrink-0",
	)
	if searching && p.caret_on(ui) {
		p.div(ui, "w-px h-[15] bg-foreground shrink-0")
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	sc.kbd(ui, "/")
	p.end(ui)

	p.spacer(ui, "flex-1")

	// Sync state.
	p.row(ui, "items-center gap-1.5 shrink-0")
	out := signed_out(s)
	online := (s.st.online || s.fixture) && !out
	p.icon(ui, online ? ICON_CLOUD : ICON_CLOUD_OFF, online || out ? "size-3.5 text-muted-foreground" : "size-3.5 text-destructive")
	label := out ? "signed out" : (s.fixture ? "synced" : (s.synced_at != "" ? s.synced_at : (online ? "online" : "offline")))
	p.text(ui, label, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.key(ui, "sync")
	sy := p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer")
	if p.clickable(ui, sy) {
		do_sync(s)
	}
	p.icon(ui, ICON_REFRESH_CW, "size-3.5 shrink-0 text-foreground")
	p.text(ui, "Sync", "text-[12] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.key(ui, "new")
	nb := p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-2.5 rounded-md bg-primary hover:bg-primary/90 transition cursor-pointer")
	if p.clickable(ui, nb) {
		open_form(s, -1)
	}
	p.icon(ui, sc.ICON_PLUS, "size-3.5 shrink-0 text-primary-foreground")
	p.text(ui, "New contact", "text-[12] font-medium text-primary-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
	sc.kbd(ui, "F1")
	p.text(ui, "keys", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Sidebar: identities, their address books, their groups
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, s: ^App_State) {
	p.key(ui, "sidebar")
	side := p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border overflow-scroll px-2 py-2.5 gap-0.5", SIDE_W))
	defer p.end(ui)
	focus := s.pane == .Sidebar && s.mode == .Normal

	p.text(ui, "IDENTITIES", "px-2 pb-1 text-[10] font-semibold tracking-wider text-muted-foreground/70")
	for it, k in s.side {
		on := k == s.side_sel
		p.key(ui, tfmt("side%d", k))
		pad := "pl-2"
		switch it.kind {
		case .All, .Ident:
		case .Book:
			pad = "pl-6"
		case .Group:
			pad = "pl-10"
		}
		if it.kind == .Ident && k > 0 {
			p.div(ui, "h-[6] shrink-0")
			p.end(ui)
		}
		row := p.row(ui, tfmt("w-full shrink-0 h-[30] items-center gap-2 %s pr-2 rounded-md cursor-pointer", pad))
		switch {
		case on && focus:
			p.apply(ui, "bg-primary/10 ring-1 ring-primary/25", row)
		case on:
			p.apply(ui, "bg-accent text-accent-foreground", row)
		case:
			p.apply(ui, "hover:bg-accent/60", row)
		}
		if p.clickable(ui, row) {
			s.side_sel = k
			s.list_sel = 0
			s.pane = .Sidebar
		}
		muted := "text-muted-foreground"
		count := 0
		switch it.kind {
		case .All:
			p.icon(ui, ICON_USERS, tfmt("size-3.5 shrink-0 %s", muted))
			p.text(ui, "All identities", "flex-1 min-w-0 truncate text-[12.5] font-medium")
			count = len(visible(s.st, Filter{book = -1, group = -1}))
		case .Ident:
			id := ident_of(s.st, it.handle)
			p.div(ui, tfmt("size-2.5 shrink-0 rounded-full bg-%s-500", ident_color(s, it.handle)))
			p.end(ui)
			p.text(ui, id != nil ? id.display_name : it.handle, "flex-1 min-w-0 truncate text-[12.5] font-semibold")
			count = len(visible(s.st, Filter{handle = it.handle, book = -1, group = -1}))
		case .Book:
			b := s.st.books[it.book]
			p.icon(ui, sc.ICON_BOOK_OPEN, tfmt("size-3.5 shrink-0 %s", muted))
			p.text(ui, book_label(s.st, it.book), "flex-1 min-w-0 truncate text-[12.5]")
			if b.readonly {
				p.icon(ui, ICON_LOCK, tfmt("size-3 shrink-0 %s", muted))
			} else if b.remote.access == "read-write" {
				p.icon(ui, ICON_LINK, tfmt("size-3 shrink-0 %s", muted))
			}
			count = len(visible(s.st, Filter{handle = it.handle, book = it.book, group = -1}))
		case .Group:
			p.icon(ui, ICON_TAG, tfmt("size-3 shrink-0 %s", muted))
			p.text(ui, display(s.st.contacts[it.group]), "flex-1 min-w-0 truncate text-[12]")
			count = len(visible(s.st, Filter{handle = it.handle, book = it.book, group = it.group}))
		}
		p.textf(ui, tfmt("text-[11] tabular-nums shrink-0 %s", muted), "%d", count)
		p.end(ui)
		if on && focus {
			p.scroll_into_view(ui, p.node_id(ui, side), p.node_id(ui, row), 8)
		}
	}
	if len(s.side) == 0 {
		p.col(ui, "w-full items-center gap-2 px-4 pt-10")
		p.icon(ui, ICON_CLOUD_OFF, "size-5 text-muted-foreground")
		p.text(ui, signed_out(s) ? "Not signed in" : "No address books yet", "text-[12.5] font-medium")
		p.text(ui, "Sign in with your Palmframe account to see each identity's contacts.", "max-w-[200] text-center text-[11.5] text-muted-foreground")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

avatar :: proc(ui: ^p.Ctx, c: Contact, color: string, size: string, text_size: string) {
	p.div(ui, tfmt("flex-row %s shrink-0 items-center justify-center rounded-full bg-%s-500", size, color))
	p.text(ui, initials(c), tfmt("%s font-semibold text-white", text_size))
	p.end(ui)
}

list_pane :: proc(ui: ^p.Ctx, s: ^App_State) {
	list := current_list(s)
	f := current_filter(s)
	p.col(ui, tfmt("w-[%d] shrink-0 h-full border-r border-border overflow-hidden", LIST_W))
	defer p.end(ui)

	// What the list is showing.
	p.row(ui, "w-full h-[40] shrink-0 items-center gap-2 px-4 border-b border-border")
	title := "All identities"
	if s.side_sel < len(s.side) {
		it := s.side[s.side_sel]
		switch it.kind {
		case .All:
		case .Ident:
			if id := ident_of(s.st, it.handle); id != nil {
				title = id.display_name
			}
		case .Book:
			title = book_label(s.st, it.book)
		case .Group:
			title = display(s.st.contacts[it.group])
		}
	}
	p.text(ui, title, "flex-1 min-w-0 truncate text-[13] font-semibold")
	p.textf(ui, "text-[11.5] text-muted-foreground shrink-0", "%d", len(list))
	p.end(ui)

	if len(list) == 0 {
		p.col(ui, "flex-1 min-h-0 w-full items-center justify-center gap-2.5 px-8")
		p.div(ui, "flex-row size-11 items-center justify-center rounded-2xl bg-muted shrink-0")
		p.icon(ui, f.query != "" ? sc.ICON_SEARCH : sc.ICON_USER, "size-5 text-muted-foreground")
		p.end(ui)
		p.text(ui, f.query != "" ? "No match" : "No contacts here", "text-[13.5] font-medium")
		p.text(
			ui,
			f.query != "" ? "Nothing in this view matches the search. Esc clears it." : "Press N to add someone, or I to import a .vcf file.",
			"max-w-[240] text-center text-[11.5] text-muted-foreground",
		)
		p.end(ui)
		return
	}

	s.list_sel = clamp(s.list_sel, 0, len(list) - 1)
	p.key(ui, "list")
	box := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll px-2 pb-3")
	defer p.end(ui)
	focus := s.pane == .List && (s.mode == .Normal || s.mode == .Search)
	last := ""
	for idx, k in list {
		c := s.st.contacts[idx]
		ini := initial(c)
		if ini != last {
			p.key(ui, tfmt("sec%s", ini))
			p.row(ui, "w-full h-[26] shrink-0 items-end px-2 pb-1")
			p.text(ui, ini, "text-[11] font-semibold text-muted-foreground")
			p.end(ui)
			last = ini
		}
		on := k == s.list_sel
		p.key(ui, tfmt("c%s", c.card.uid))
		row := p.row(ui, "w-full shrink-0 h-[48] items-center gap-2.5 px-2 rounded-lg cursor-pointer")
		switch {
		case on && focus:
			p.apply(ui, "bg-primary/10 ring-1 ring-primary/25", row)
		case on:
			p.apply(ui, "bg-accent", row)
		case:
			p.apply(ui, "hover:bg-accent/60", row)
		}
		if p.clickable(ui, row) {
			s.list_sel = k
			s.pane = .List
			s.sel_uid = c.card.uid
		}
		handle := s.st.books[c.book].handle
		avatar(ui, c, ident_color(s, handle), "size-8", "text-[11.5]")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, display(c), "w-full truncate text-[13] font-medium")
		sub := c.card.org
		if sub == "" && len(c.card.emails) > 0 {
			sub = c.card.emails[0].value
		}
		if sub == "" && len(c.card.phones) > 0 {
			sub = c.card.phones[0].value
		}
		p.text(ui, sub, "w-full truncate text-[11.5] text-muted-foreground")
		p.end(ui)
		if f.handle == "" && len(s.st.idents) > 1 {
			// The overlay: whose contact this is.
			p.row(ui, "shrink-0 items-center gap-1 pl-1")
			p.div(ui, tfmt("size-1.5 rounded-full bg-%s-500", ident_color(s, handle)))
			p.end(ui)
			p.text(ui, handle, "text-[10.5] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
		if on {
			p.scroll_into_view(ui, p.node_id(ui, box), p.node_id(ui, row), 30)
		}
	}
}

// ---------------------------------------------------------------------------
// The card
// ---------------------------------------------------------------------------

detail :: proc(ui: ^p.Ctx, s: ^App_State) {
	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	defer p.end(ui)
	i, ok := selected(s)
	if !ok {
		p.col(ui, "flex-1 w-full items-center justify-center gap-2")
		p.icon(ui, sc.ICON_USER, "size-6 text-muted-foreground/60")
		p.text(ui, "No contact selected", "text-[13] text-muted-foreground")
		p.end(ui)
		return
	}
	c := s.st.contacts[i]
	b := s.st.books[c.book]
	color := ident_color(s, b.handle)

	p.col(ui, "flex-1 min-h-0 w-full overflow-scroll")
	defer p.end(ui)

	// Head.
	p.row(ui, "w-full shrink-0 items-center gap-4 px-8 pt-7 pb-5")
	avatar(ui, c, color, "size-[64]", "text-[22]")
	p.col(ui, "flex-1 min-w-0 gap-1")
	p.text(ui, display(c), "w-full truncate text-[22] font-semibold")
	role := c.card.title
	if c.card.org != "" {
		role = role != "" ? tfmt("%s · %s", role, c.card.org) : c.card.org
	}
	if role != "" {
		p.text(ui, role, "w-full truncate text-[13] text-muted-foreground")
	}
	p.row(ui, "items-center gap-1.5 pt-1")
	id := ident_of(s.st, b.handle)
	p.row(ui, "h-[22] items-center gap-1.5 px-2 rounded-full border border-border shrink-0")
	p.div(ui, tfmt("size-2 rounded-full bg-%s-500", color))
	p.end(ui)
	p.text(ui, id != nil ? id.display_name : b.handle, "text-[11] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.row(ui, "h-[22] items-center gap-1.5 px-2 rounded-full bg-muted shrink-0")
	p.icon(ui, sc.ICON_BOOK_OPEN, "size-3 text-muted-foreground")
	p.text(ui, book_label(s.st, c.book), "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	if b.readonly {
		p.row(ui, "h-[22] items-center gap-1 px-2 rounded-full bg-amber-500/15 shrink-0")
		p.icon(ui, ICON_LOCK, "size-3 text-amber-600")
		p.text(ui, tfmt("read-only, shared by %s", b.remote.owner), "text-[11] text-amber-700 whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)

	p.div(ui, "w-full h-px shrink-0 bg-border")
	p.end(ui)

	p.col(ui, "w-full shrink-0 px-8 py-4 gap-5")
	if len(c.card.emails) > 0 {
		section(ui, sc.ICON_MAIL, "Email")
		for e in c.card.emails {
			field_row(ui, type_label(e.types, e.pref), e.value, true)
		}
		p.end(ui)
	}
	if len(c.card.phones) > 0 {
		section(ui, ICON_PHONE, "Phone")
		for ph in c.card.phones {
			field_row(ui, type_label(ph.types, ph.pref), ph.value, false)
		}
		p.end(ui)
	}
	if len(c.card.addresses) > 0 {
		section(ui, ICON_MAP_PIN, "Address")
		for a in c.card.addresses {
			lines := make([dynamic]string, 0, 4, context.temp_allocator)
			if a.street != "" {
				append(&lines, a.street)
			}
			city := strings.trim_space(tfmt("%s %s", a.postcode, a.locality))
			if a.region != "" {
				city = tfmt("%s, %s", city, a.region)
			}
			if city != "" {
				append(&lines, city)
			}
			if a.country != "" {
				append(&lines, a.country)
			}
			field_row(ui, type_label(a.types, a.pref), strings.join(lines[:], "\n", context.temp_allocator), false)
		}
		p.end(ui)
	}
	if c.card.bday != "" {
		section(ui, ICON_CALENDAR_DAYS, "Birthday")
		field_row(ui, "", pretty_date(c.card.bday), false)
		p.end(ui)
	}
	gs := groups_of(s.st, c.book, c.card.uid)
	section(ui, ICON_TAG, "Groups")
	p.row(ui, "w-full flex-wrap gap-1.5 pl-[92]")
	if len(gs) == 0 {
		p.text(ui, b.readonly ? "None" : "None — press G to add", "text-[12.5] text-muted-foreground")
	}
	for g in gs {
		p.row(ui, "h-[24] items-center gap-1 px-2.5 rounded-full bg-secondary shrink-0")
		p.text(ui, display(s.st.contacts[g]), "text-[11.5] font-medium text-secondary-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	if c.card.note != "" {
		section(ui, ICON_NOTEBOOK_PEN, "Note")
		p.row(ui, "w-full pl-[92]")
		p.text(ui, c.card.note, "flex-1 min-w-0 text-[12.5] text-foreground whitespace-pre-wrap")
		p.end(ui)
		p.end(ui)
	}
	p.row(ui, "w-full items-center gap-2 pt-2")
	p.text(ui, tfmt("vCard %s · %s", c.card.version != "" ? c.card.version : "4.0", c.card.uid), "flex-1 min-w-0 truncate text-[10.5] font-mono text-muted-foreground/60")
	p.end(ui)
	p.end(ui)
}

section :: proc(ui: ^p.Ctx, ic: p.Icon, title: string) {
	p.col(ui, "w-full gap-1.5")
	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, title, "text-[11] font-semibold tracking-wide text-muted-foreground")
	p.end(ui)
}

field_row :: proc(ui: ^p.Ctx, label, value: string, link: bool) {
	p.row(ui, "w-full items-start gap-3")
	p.text(ui, label, "w-[80] shrink-0 text-right text-[12] text-muted-foreground")
	p.text(ui, value, link ? "flex-1 min-w-0 text-[13] text-primary whitespace-pre-wrap" : "flex-1 min-w-0 text-[13] text-foreground whitespace-pre-wrap")
	p.end(ui)
}

type_label :: proc(types: []string, pref: bool) -> string {
	out := ""
	for t in types {
		if t == "voice" || t == "internet" {
			continue
		}
		out = t
		break
	}
	if out == "cell" {
		out = "mobile"
	}
	if pref {
		return out == "" ? "preferred" : tfmt("%s ★", out)
	}
	return out
}

pretty_date :: proc(b: string) -> string {
	v, _ := strings.replace_all(b, "-", "", context.temp_allocator)
	MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	if len(v) == 8 {
		m := int(v[4] - '0') * 10 + int(v[5] - '0')
		d := int(v[6] - '0') * 10 + int(v[7] - '0')
		if m >= 1 && m <= 12 {
			return tfmt("%d %s %s", d, MONTHS[m - 1], v[0:4])
		}
	}
	if len(v) == 4 {
		m := int(v[0] - '0') * 10 + int(v[1] - '0')
		d := int(v[2] - '0') * 10 + int(v[3] - '0')
		if m >= 1 && m <= 12 {
			return tfmt("%d %s", d, MONTHS[m - 1])
		}
	}
	return b
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status :: proc(ui: ^p.Ctx, s: ^App_State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-3 bg-sidebar border-t border-border", STATUS_H))
	defer p.end(ui)
	p.text(ui, s.pane == .Sidebar ? "Sidebar" : "List", "text-[11.5] font-medium whitespace-nowrap shrink-0")
	p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	if s.pane == .Sidebar {
		hint(ui, "Up Down", "view")
		hint(ui, "G", "new group")
		hint(ui, "R", "rename")
		hint(ui, "Tab", "list")
	} else {
		hint(ui, "Up Down", "contact")
		hint(ui, "E", "edit")
		hint(ui, "N", "new")
		hint(ui, "G", "groups")
		hint(ui, "M", "duplicates")
		hint(ui, "I X", "import, export")
	}
	p.spacer(ui, "flex-1")
	dirty := 0
	for b in s.st.books {
		if b.local == nil {
			continue
		}
		for _, e in b.local.entries {
			if e.state != .Clean {
				dirty += 1
			}
		}
	}
	if dirty > 0 {
		p.textf(ui, "text-[11.5] text-amber-600 whitespace-nowrap shrink-0", "%d change%s waiting to sync", dirty, dirty == 1 ? "" : "s")
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50 shrink-0")
	}
	p.text(ui, s.fixture ? "palm.test · CardDAV" : "CardDAV · ~/.local/share/palm/dav", "text-[11] font-mono text-muted-foreground/70 whitespace-nowrap shrink-0")
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
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px(max(8, (win.x - f32(w)) / 2))
	st.inset[p.TOP] = p.px(top)
	p.col(ui, "w-full rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
}

sheet_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

scrim :: proc(ui: ^p.Ctx, s: ^App_State, closable := true) {
	sm := p.div(ui, "absolute inset-0 z-40 bg-black/40")
	if closable && p.clickable(ui, sm) {
		s.mode = .Normal
	}
	p.end(ui)
}

sheet_title :: proc(ui: ^p.Ctx, ic: p.Icon, title, sub: string) {
	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-1")
	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-primary/10")
	p.icon(ui, ic, "size-4 text-primary")
	p.end(ui)
	p.col(ui, "gap-0.5 min-w-0 flex-1")
	p.text(ui, title, "text-[15] font-semibold")
	if sub != "" {
		p.text(ui, sub, "text-[11.5] text-muted-foreground")
	}
	p.end(ui)
	p.end(ui)
}

sheet_footer :: proc(ui: ^p.Ctx) {
	p.row(ui, "h-[44] w-full shrink-0 items-center justify-end gap-3 px-5 border-t border-border bg-muted/40")
}

input_box :: proc(ui: ^p.Ctx, value, placeholder: string, active: bool, mask := false) {
	idx := p.row(ui, "flex-1 min-w-0 h-9 items-center gap-1 px-3 rounded-lg border bg-background overflow-hidden cursor-text")
	p.apply(ui, active ? "border-ring ring-3 ring-ring/40" : "border-input", idx)
	shown := value
	if mask && value != "" {
		shown = strings.repeat("•", strings.rune_count(value), context.temp_allocator)
	}
	p.text(
		ui,
		shown == "" ? placeholder : shown,
		shown == "" ? "text-[13] text-muted-foreground/60 whitespace-nowrap shrink-0" : "text-[13] text-foreground whitespace-nowrap shrink-0",
	)
	if active && p.caret_on(ui) {
		p.div(ui, "w-px h-[16] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)
}

form_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	f := &s.form
	win := p.size(ui)
	h := f32(150 + 44 * len(f.rows) + 60)
	sheet_open(ui, 600, max(8, (win.y - h) / 2))
	defer sheet_close(ui)
	book := f.book >= 0 && f.book < len(s.st.books) ? tfmt("%s · %s", s.st.books[f.book].handle, book_label(s.st, f.book)) : "no address book"
	sheet_title(ui, f.editing < 0 ? sc.ICON_PLUS : ICON_PENCIL, f.editing < 0 ? "New contact" : "Edit contact", tfmt("Into %s. Tab moves, Enter saves.", book))

	p.col(ui, "w-full px-5 pt-3 pb-3 gap-2")
	for &row, k in f.rows {
		p.key(ui, tfmt("row%d", k))
		p.row(ui, "w-full items-center gap-3")
		label := ROW_LABELS[row.kind]
		p.text(ui, label, "w-[84] shrink-0 text-right text-[12] font-medium text-muted-foreground")
		input_box(ui, string(row.buf[:]), ROW_HINTS[row.kind], f.field == k)
		if row.kind == .Email || row.kind == .Phone {
			p.row(ui, "w-[64] h-9 shrink-0 items-center justify-center rounded-lg bg-muted")
			p.text(ui, row.type == "cell" ? "mobile" : row.type, "text-[11.5] font-medium text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
	}
	if f.err != "" {
		p.row(ui, "w-full items-center gap-2 pt-1 pl-[96]")
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, f.err, "flex-1 min-w-0 text-[12] text-destructive")
		p.end(ui)
	}
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Ctrl E", "email")
	hint(ui, "Ctrl P", "phone")
	hint(ui, "Ctrl T", "type")
	hint(ui, "Ctrl D", "remove")
	p.spacer(ui, "flex-1")
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", "save")
	p.end(ui)
}

delete_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	i, ok := selected(s)
	if !ok {
		return
	}
	c := s.st.contacts[i]
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 150))
	defer sheet_close(ui)
	p.col(ui, "w-full items-center px-6 pt-6 pb-4 gap-4")
	p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-destructive/10 shrink-0")
	p.icon(ui, sc.ICON_TRASH, "size-4.5 text-destructive")
	p.end(ui)
	p.col(ui, "items-center gap-1.5 w-full")
	p.text(ui, "Delete this contact?", "text-[16] font-semibold")
	p.text(ui, display(c), "max-w-[340] text-center text-[13] font-medium")
	p.text(ui, tfmt("From %s. It also leaves its groups, on every device.", book_label(s.st, c.book)), "max-w-[340] text-center text-[11.5] text-muted-foreground")
	p.end(ui)
	p.row(ui, "w-full gap-2 pt-1")
	for label, k in ([?]string{"Keep", "Delete"}) {
		on := (k == 1) == s.confirm
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
			s.confirm = k == 1
		}
		p.text(ui, label, "text-[13] font-medium whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Left Right", "choose")
	hint(ui, "Enter", "confirm")
	p.end(ui)
}

groups_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	i, ok := selected(s)
	if !ok {
		return
	}
	gs := groups_here(s)
	win := p.size(ui)
	sheet_open(ui, 460, max(8, win.y / 2 - 200))
	defer sheet_close(ui)
	sheet_title(ui, ICON_TAG, "Groups", tfmt("%s, in %s", display(s.st.contacts[i]), book_label(s.st, s.st.contacts[i].book)))
	p.col(ui, "w-full px-4 pt-3 pb-3 gap-1")
	if len(gs) == 0 {
		p.text(ui, "This address book has no groups yet. Press N to make one.", "px-2 py-3 text-[12.5] text-muted-foreground")
	}
	s.groups_sel = clamp(s.groups_sel, 0, max(0, len(gs) - 1))
	for g, k in gs {
		on := in_group(s.st, g, s.st.contacts[i])
		p.key(ui, tfmt("g%d", g))
		row := p.row(ui, "w-full h-[34] items-center gap-2.5 px-3 rounded-lg cursor-pointer")
		p.apply(ui, k == s.groups_sel ? "bg-accent" : "hover:bg-accent/60", row)
		if p.clickable(ui, row) {
			s.groups_sel = k
			toggle_group(s, g)
		}
		box := p.div(ui, "flex-row size-4 shrink-0 items-center justify-center rounded border")
		p.apply(ui, on ? "bg-primary border-primary" : "border-input bg-background", box)
		if on {
			p.icon(ui, sc.ICON_CHECK, "size-3 text-primary-foreground")
		}
		p.end(ui)
		p.text(ui, display(s.st.contacts[g]), "flex-1 min-w-0 truncate text-[13]")
		p.textf(ui, "text-[11] text-muted-foreground shrink-0", "%d", len(s.st.contacts[g].card.members))
		p.end(ui)
	}
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Space", "toggle")
	hint(ui, "N", "new group")
	hint(ui, "Esc", "done")
	p.end(ui)
}

group_name_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 120))
	defer sheet_close(ui)
	sheet_title(ui, ICON_TAG, s.name_group >= 0 ? "Rename group" : "New group", "Groups are vCard KIND:group cards; Apple and DAVx5 see them too.")
	p.row(ui, "w-full px-5 pt-3 pb-4")
	input_box(ui, string(s.name_buf[:]), "Climbing club", true)
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", s.name_group >= 0 ? "rename" : "create")
	p.end(ui)
}

merge_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	pairs := duplicates(s.st, Filter{handle = current_filter(s).handle, book = -1, group = -1})
	win := p.size(ui)
	sheet_open(ui, 760, max(8, (win.y - 560) / 2))
	defer sheet_close(ui)
	sheet_title(ui, ICON_LAYERS, "Duplicates", len(pairs) == 0 ? "Nothing looks duplicated." : tfmt("%d pair%s that look like the same person, within one address book.", len(pairs), len(pairs) == 1 ? "" : "s"))
	if len(pairs) == 0 {
		p.col(ui, "w-full items-center gap-2 px-6 py-10")
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-6 text-emerald-500")
		p.text(ui, "Every contact is distinct", "text-[13] font-medium")
		p.end(ui)
		sheet_footer(ui)
		hint(ui, "Esc", "close")
		p.end(ui)
		return
	}
	s.merge_sel = clamp(s.merge_sel, 0, len(pairs) - 1)
	p.row(ui, "w-full h-[300] items-stretch")
	// Pairs.
	p.col(ui, "w-[300] shrink-0 border-r border-border overflow-scroll px-3 py-3 gap-1")
	for d, k in pairs {
		on := k == s.merge_sel
		p.key(ui, tfmt("pair%d", k))
		row := p.col(ui, "w-full shrink-0 gap-0.5 px-3 py-2 rounded-lg cursor-pointer")
		p.apply(ui, on ? "bg-accent" : "hover:bg-accent/60", row)
		if p.clickable(ui, row) {
			s.merge_sel = k
		}
		p.row(ui, "w-full items-center gap-1.5")
		p.text(ui, display(s.st.contacts[d.a]), "flex-1 min-w-0 truncate text-[12.5] font-medium")
		p.row(ui, "h-[18] items-center px-1.5 rounded bg-muted shrink-0")
		p.text(ui, tfmt("same %s", d.reason), "text-[10] font-medium text-muted-foreground whitespace-nowrap")
		p.end(ui)
		p.end(ui)
		p.text(ui, tfmt("and %s", display(s.st.contacts[d.b])), "w-full truncate text-[11.5] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	// The chosen pair, side by side, and the result.
	d := pairs[s.merge_sel]
	keep, drop := d.a, d.b
	if s.merge_swap {
		keep, drop = drop, keep
	}
	p.col(ui, "flex-1 min-w-0 px-5 py-4 gap-3 overflow-scroll")
	p.row(ui, "w-full gap-3 items-stretch")
	merge_card(ui, s, keep, "Keep", true)
	merge_card(ui, s, drop, "Fold in", false)
	p.end(ui)
	res := merged(s.st.contacts[keep].card, s.st.contacts[drop].card)
	p.col(ui, "w-full gap-1 px-3 py-2.5 rounded-lg bg-primary/5 border border-primary/20")
	p.text(ui, "RESULT", "text-[10] font-semibold tracking-wider text-primary")
	p.text(ui, res.fn != "" ? res.fn : display(s.st.contacts[keep]), "text-[13] font-semibold")
	p.textf(ui, "text-[11.5] text-muted-foreground", "%d email%s · %d phone%s · groups move to the kept card", len(res.emails), len(res.emails) == 1 ? "" : "s", len(res.phones), len(res.phones) == 1 ? "" : "s")
	p.end(ui)
	p.end(ui)
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Up Down", "pair")
	hint(ui, "Left Right", "swap")
	hint(ui, "Enter", "merge")
	hint(ui, "Esc", "close")
	p.end(ui)
}

merge_card :: proc(ui: ^p.Ctx, s: ^App_State, i: int, label: string, keep: bool) {
	c := s.st.contacts[i]
	p.col(ui, "flex-1 min-w-0 gap-1.5 px-3 py-3 rounded-lg border")
	p.apply(ui, keep ? "border-primary" : "border-border")
	p.text(ui, label, keep ? "text-[10] font-semibold tracking-wider text-primary" : "text-[10] font-semibold tracking-wider text-muted-foreground")
	p.row(ui, "w-full items-center gap-2")
	avatar(ui, c, ident_color(s, s.st.books[c.book].handle), "size-7", "text-[10.5]")
	p.text(ui, display(c), "flex-1 min-w-0 truncate text-[13] font-medium")
	p.end(ui)
	for e in c.card.emails {
		p.text(ui, e.value, "w-full truncate text-[11.5] text-muted-foreground")
	}
	for ph in c.card.phones {
		p.text(ui, ph.value, "w-full truncate text-[11.5] text-muted-foreground")
	}
	if c.card.org != "" {
		p.text(ui, c.card.org, "w-full truncate text-[11.5] text-muted-foreground")
	}
	p.end(ui)
}

signin_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s, false)
	win := p.size(ui)
	sheet_open(ui, 440, max(8, win.y / 2 - 170))
	defer sheet_close(ui)
	sheet_title(ui, ICON_USERS, "Sign in to Palmframe", "Your contacts for every identity, synced over CardDAV.")
	p.col(ui, "w-full px-5 pt-3 pb-4 gap-2.5")
	p.row(ui, "w-full items-center gap-3")
	p.text(ui, "Email", "w-[70] shrink-0 text-right text-[12] font-medium text-muted-foreground")
	input_box(ui, string(s.email[:]), "you@example.org", s.signin_fld == 0)
	p.end(ui)
	p.row(ui, "w-full items-center gap-3")
	p.text(ui, "Password", "w-[70] shrink-0 text-right text-[12] font-medium text-muted-foreground")
	input_box(ui, string(s.password[:]), "••••••••", s.signin_fld == 1, mask = true)
	p.end(ui)
	if s.signin_err != "" {
		p.row(ui, "w-full items-center gap-2 pl-[82]")
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, s.signin_err, "flex-1 min-w-0 text-[12] text-destructive")
		p.end(ui)
	}
	p.end(ui)
	sheet_footer(ui)
	p.text(ui, "Same account as Accounts and Calendar", "flex-1 min-w-0 truncate text-[11] text-muted-foreground")
	hint(ui, "Tab", "next")
	hint(ui, "Enter", "sign in")
	p.end(ui)
}

path_dialog :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	win := p.size(ui)
	sheet_open(ui, 520, max(8, win.y / 2 - 140))
	defer sheet_close(ui)
	imp := s.mode == .Import
	b := target_book(s)
	where_ := b >= 0 ? tfmt("into %s · %s", s.st.books[b].handle, book_label(s.st, b)) : "no writable address book here"
	if imp {
		sheet_title(ui, sc.ICON_DOWNLOAD, "Import a .vcf", tfmt("vCard 3.0 and 4.0, %s. Same UID updates.", where_))
	} else {
		sheet_title(ui, sc.ICON_DOWNLOAD, "Export as .vcf", "Exactly what the list shows, with its groups.")
	}
	p.row(ui, "w-full px-5 pt-3 pb-4 gap-2")
	input_box(ui, string(s.path[:]), "~/contacts.vcf", true)
	if !imp {
		p.row(ui, "h-9 shrink-0 items-center px-3 rounded-lg bg-muted")
		p.text(ui, s.version3 ? "vCard 3.0" : "vCard 4.0", "text-[12] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	p.end(ui)
	sheet_footer(ui)
	if !imp {
		hint(ui, "Tab", "version")
	}
	hint(ui, "Esc", "cancel")
	hint(ui, "Enter", imp ? "import" : "export")
	p.end(ui)
}

HELP_ROWS := [?][2]string {
	{"Up / Down", "move in the sidebar or the list"},
	{"Tab", "switch between the sidebar and the list"},
	{"/", "search names, email, phone and company"},
	{"N", "new contact in the selected address book"},
	{"E  or  Enter", "edit the selected contact"},
	{"Delete  or  D", "delete it"},
	{"G", "its groups; in the sidebar, a new group"},
	{"R", "rename the selected group (sidebar)"},
	{"M", "find and merge duplicates"},
	{"I  /  X", "import or export a .vcf"},
	{"S  or  F5", "sync with the server now"},
	{"Ctrl Q", "quit"},
}

help_sheet :: proc(ui: ^p.Ctx, s: ^App_State) {
	scrim(ui, s)
	win := p.size(ui)
	sheet_open(ui, 560, max(8, (win.y - 470) / 2))
	defer sheet_close(ui)
	sheet_title(ui, ICON_KEYBOARD, "Contacts, from the keyboard", "Edits land in the local copy first and sync over CardDAV.")
	p.col(ui, "w-full px-5 pt-3 pb-5 gap-1.5")
	for row in HELP_ROWS {
		p.row(ui, "w-full items-center gap-3")
		p.row(ui, "w-[150] shrink-0 justify-end")
		sc.kbd(ui, row[0])
		p.end(ui)
		p.text(ui, row[1], "flex-1 min-w-0 text-[12] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	sheet_footer(ui)
	hint(ui, "Esc", "close")
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, s: ^App_State) {
	if s.toast == "" {
		return
	}
	if s.toast_at == 0 {
		s.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - s.toast_at > 2.8 {
		delete(s.toast)
		s.toast = ""
		s.toast_at = 0
		return
	}
	p.redraw(ui)
	idx := p.row(ui, "absolute z-30 left-[16] bottom-[40] max-w-[480] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg")
	p.style(ui, idx).no_hit = true
	p.icon(ui, sc.ICON_INFO, "size-3.5 shrink-0 text-primary")
	p.text(ui, s.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
