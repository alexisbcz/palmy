// The frame: the identity rail, the search bar, Today or the results, and
// the three sheets (palette, quick-create, carry).
//
// Two rules hold everywhere on screen, and they are the ones product.md asks
// every app to follow:
//
//   - Label when mixed, tint when single. Showing every identity, each item
//     carries a small coloured label with the identity's name. Inside one
//     identity the labels go, and the window itself is tinted instead.
//   - Colour is never alone. Every identity colour comes with its name or
//     its monogram, so the distinction survives colour blindness and a
//     greyscale screenshot.
package main

import "core:strings"
import p "palmy:."
import sc "shadcn:."

RAIL_W :: 252

frame :: proc(ui: ^p.Ctx, h: ^Home) {
	clear(&h.rows)
	p.col(ui, "w-full h-full bg-background text-foreground relative overflow-hidden")
	defer p.end(ui)

	tint_stripe(ui, h)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	rail(ui, h)
	p.col(ui, "flex-1 min-w-0 h-full")
	header(ui, h)
	body := p.col(ui, "flex-1 min-h-0 w-full overflow-scroll")
	if len(h.query) == 0 {
		today(ui, h)
	} else {
		results(ui, h)
	}
	p.end(ui)
	_ = body
	p.end(ui)
	p.end(ui)

	switch h.mode {
	case .Palette:
		palette(ui, h)
	case .Create:
		create_sheet(ui, h)
	case .Carry:
		carry_sheet(ui, h)
	case .Help:
		help_sheet(ui, h)
	case .Normal:
	}
	toast(ui, h)
}

// tint_stripe is the per-window identity tint: a hairline band across the
// top of the window in the identity's colour, or, showing all of them, in
// every identity's colour side by side.
tint_stripe :: proc(ui: ^p.Ctx, h: ^Home) {
	p.row(ui, "w-full h-[3] shrink-0")
	if h.ident >= 0 {
		p.div(ui, tfmt("flex-1 h-full bg-id-%d", h.ident))
		p.end(ui)
	} else {
		for _, i in h.store.identities {
			p.key(ui, tfmt("stripe%d", i))
			p.div(ui, tfmt("flex-1 h-full bg-id-%d/70", i))
			p.end(ui)
		}
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The identity rail
// ---------------------------------------------------------------------------

monogram :: proc(ui: ^p.Ctx, i: int, name: string, size := 8) {
	p.div(ui, tfmt("flex-row size-%d shrink-0 items-center justify-center rounded-lg bg-id-%d/15", size, i))
	p.text(ui, initials(name)[:1], tfmt("text-[%d] font-semibold text-id-%d", size >= 8 ? 13 : 11, i))
	p.end(ui)
}

waiting_count :: proc(h: ^Home, ident: int) -> int {
	n := 0
	for it in h.store.items {
		if it.waiting && (ident < 0 || it.ident == ident) {
			n += 1
		}
	}
	return n
}

rail :: proc(ui: ^p.Ctx, h: ^Home) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-sidebar-border", RAIL_W))
	defer p.end(ui)

	// The person, above every identity: the account owns them, it is not one.
	p.row(ui, "w-full items-center gap-3 px-5 pt-5 pb-4")
	p.div(ui, "flex-row size-9 shrink-0 items-center justify-center rounded-full bg-foreground")
	p.text(ui, initials(h.store.owner), "text-[12] font-semibold text-background")
	p.end(ui)
	p.col(ui, "min-w-0 gap-0.5")
	p.text(ui, h.store.owner, "text-[14] font-semibold truncate")
	p.text(ui, tr("Palmframe account"), "text-[11.5] text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	p.text(ui, tr("Identities"), "px-5 pt-2 pb-2 text-[11] font-semibold tracking-wide uppercase text-muted-foreground/80")

	p.col(ui, "w-full px-3 gap-0.5")
	rail_row(ui, h, -1)
	for _, i in h.store.identities {
		rail_row(ui, h, i)
	}
	p.end(ui)

	p.spacer(ui, "flex-1")

	// What notifications are doing, per identity, in words.
	p.col(ui, "w-full px-5 pb-4 gap-2")
	p.text(ui, tr("Notifications"), "text-[11] font-semibold tracking-wide uppercase text-muted-foreground/80")
	for id, i in h.store.identities {
		p.key(ui, tfmt("quiet%d", i))
		p.row(ui, "w-full items-center gap-2")
		p.icon(ui, id.quiet != "" ? ICON_BELL_OFF : ICON_BELL, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, id.name, "text-[12] font-medium shrink-0")
		p.text(ui, id.quiet != "" ? id.quiet : (h.store.source == .Device ? tr("People only (default)") : tr("People only")), "flex-1 min-w-0 text-[12] text-muted-foreground truncate")
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 h-[46] border-t border-sidebar-border")
	dev := h.store.source == .Device
	p.icon(ui, dev && !h.store.daemon ? ICON_CLOUD_OFF : ICON_CLOUD, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "flex-1 min-w-0")
	p.text(ui, h.store.synced, "text-[12] font-medium truncate")
	p.text(ui, dev && !h.store.daemon ? tr("The indexer is not running") : tr("Everything here works offline"), "text-[11] text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)
}

rail_row :: proc(ui: ^p.Ctx, h: ^Home, i: int) {
	on := h.ident == i
	p.key(ui, tfmt("rail%d", i))
	idx := p.row(ui, "w-full h-[52] items-center gap-3 px-2.5 rounded-xl transition cursor-pointer")
	p.apply(ui, on ? "bg-background shadow-sm border border-sidebar-border" : "border border-transparent hover:bg-sidebar-accent", idx)
	if p.clickable(ui, idx) {
		set_ident(h, i)
	}
	if i < 0 {
		p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-foreground/[0.06]")
		p.icon(ui, ICON_LAYERS, "size-4 text-foreground/70")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, tr("All identities"), "text-[13] font-medium truncate")
		p.text(ui, tfmt(tr("%d identities, labelled"), len(h.store.identities)), "text-[11.5] text-muted-foreground truncate")
		p.end(ui)
	} else {
		id := h.store.identities[i]
		monogram(ui, i, id.name)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, id.name, "text-[13] font-medium truncate")
		p.text(ui, id.address, "text-[11.5] text-muted-foreground truncate")
		p.end(ui)
	}
	n := waiting_count(h, i)
	if n > 0 {
		p.text(ui, tfmt("%d", n), on || i < 0 ? "text-[11.5] font-semibold tabular-nums text-foreground shrink-0" : "text-[11.5] font-medium tabular-nums text-muted-foreground shrink-0")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Header: search, new, commands
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, h: ^Home) {
	p.row(ui, "w-full h-[68] shrink-0 items-center gap-3 px-8")
	defer p.end(ui)

	q := string(h.query[:])
	box := p.row(ui, "w-[540] min-w-0 shrink h-10 items-center gap-2.5 px-3.5 rounded-xl border transition")
	p.apply(ui, q != "" ? "bg-background border-ring ring-3 ring-ring/25" : "bg-muted/70 border-transparent", box)
	p.icon(ui, ICON_SEARCH, "size-4 shrink-0 text-muted-foreground")
	if q == "" {
		p.text(ui, tr("Search mail, files, events, people…"), "text-[13.5] text-muted-foreground whitespace-nowrap truncate min-w-0")
		p.spacer(ui, "flex-1")
		p.text(ui, tr("just type"), "text-[11.5] text-muted-foreground/70 whitespace-nowrap shrink-0")
	} else {
		p.row(ui, "items-center shrink-0")
		p.text(ui, q, "text-[13.5] text-foreground whitespace-nowrap shrink-0")
		if p.caret_on(ui) && h.mode == .Normal {
			p.div(ui, "w-px h-[17] ml-px bg-foreground shrink-0")
			p.end(ui)
		}
		p.end(ui)
		p.spacer(ui, "flex-1")
		sc.kbd(ui, "Esc")
	}
	if h.ident >= 0 {
		id_chip(ui, h, h.ident, tfmt(tr("in %s"), h.store.identities[h.ident].name))
	}
	p.end(ui)

	p.spacer(ui, "flex-1")

	p.key(ui, "palette")
	pb := p.row(ui, "h-9 shrink-0 items-center gap-2 px-3 rounded-lg hover:bg-accent transition cursor-pointer")
	if p.clickable(ui, pb) {
		h.mode = .Palette
		clear(&h.pal_query)
		h.pal_sel = 0
	}
	p.icon(ui, ICON_COMMAND, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, tr("Commands"), "text-[13] font-medium whitespace-nowrap")
	p.text(ui, "Ctrl K", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)

	p.key(ui, "new")
	nb := p.row(ui, "h-9 shrink-0 items-center gap-2 px-3.5 rounded-lg bg-primary hover:bg-primary/90 transition cursor-pointer")
	if p.clickable(ui, nb) {
		open_create(h, .Mail, h.ident)
	}
	p.icon(ui, ICON_PLUS, "size-4 shrink-0 text-primary-foreground")
	p.text(ui, tr("New"), "text-[13] font-medium text-primary-foreground whitespace-nowrap")
	p.end(ui)
}

// id_chip is the identity label: a dot and a name in the identity's colour.
// It is the shape proposed for the shared kit component in shell.md.
id_chip :: proc(ui: ^p.Ctx, h: ^Home, i: int, label := "") {
	text := label != "" ? label : h.store.identities[i].name
	p.row(ui, tfmt("h-[22] shrink-0 items-center gap-1.5 px-2 rounded-full bg-id-%d/10", i))
	p.div(ui, tfmt("size-1.5 shrink-0 rounded-full bg-id-%d", i))
	p.end(ui)
	p.text(ui, text, tfmt("text-[11.5] font-medium whitespace-nowrap text-id-%d", i))
	p.end(ui)
}

// id_label is the quiet form for rows in a list: a dot and the name in the
// ordinary muted colour. A column of coloured pills reads as a dashboard; a
// column of small names reads as a list.
id_label :: proc(ui: ^p.Ctx, h: ^Home, i: int) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.div(ui, tfmt("size-[7] shrink-0 rounded-full bg-id-%d", i))
	p.end(ui)
	p.text(ui, h.store.identities[i].name, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Today
// ---------------------------------------------------------------------------

visible :: proc(h: ^Home, it: Item) -> bool {
	return h.ident < 0 || it.ident == h.ident
}

// selectable begins a row that Up/Down can land on and Enter opens.
selectable :: proc(ui: ^p.Ctx, h: ^Home, item: int, class: string) -> int {
	n := len(h.rows)
	append(&h.rows, item)
	p.key(ui, tfmt("row%d", item))
	idx := p.row(ui, class)
	on := h.mode == .Normal && h.sel == n
	p.apply(ui, on ? "bg-accent" : "hover:bg-accent/60", idx)
	if p.clickable(ui, idx) {
		h.sel = n
		open_item(h, item)
	}
	return idx
}

section_head :: proc(ui: ^p.Ctx, title: string, count: string = "") {
	p.row(ui, "w-full items-baseline gap-2 px-3 pb-1.5")
	p.text(ui, title, "text-[12] font-semibold tracking-wide uppercase text-muted-foreground")
	if count != "" {
		p.text(ui, count, "text-[12] text-muted-foreground/60")
	}
	p.end(ui)
}

count_words :: proc(n: int, one, many: string) -> string {
	WORDS := [?]string{"No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"}
	w := n < len(WORDS) ? WORDS[n] : tfmt("%d", n)
	return tfmt("%s %s", w, n == 1 ? one : many)
}

today :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	p.col(ui, "w-full px-8 pt-6 pb-10 gap-7")
	defer p.end(ui)

	events, waiting, due := 0, 0, 0
	next := -1
	for it, i in s.items {
		if !visible(h, it) {
			continue
		}
		if it.kind == .Event && it.day == 0 {
			events += 1
			if next < 0 && it.at > s.now_min {
				next = i
			}
		}
		if it.waiting {
			waiting += 1
		}
		if it.kind == .Task && !it.done && it.day <= 0 && (it.dated || s.source == .Fixtures) {
			due += 1
		}
	}
	if next < 0 {
		// Nothing left today: Next is tomorrow's first event.
		for it, i in s.items {
			if visible(h, it) && it.kind == .Event && it.day == 1 {
				next = i
				break
			}
		}
	}

	// The opening line: the day, then one sentence instead of a dashboard.
	p.col(ui, "w-full gap-1.5 px-3")
	p.text(ui, s.now_day, "text-[30] font-semibold tracking-tight")
	lead := h.ident >= 0 ? tfmt(tr("In %s: "), s.identities[h.ident].name) : greeting(s)
	ev := count_words(events, tr("event"), tr("events"))
	if h.ident >= 0 {
		ev = strings.to_lower(ev, context.temp_allocator)
	}
	p.text(
		ui,
		tfmt(
			"%s%s, %s waiting on you, %s due.",
			lead,
			ev,
			strings.to_lower(count_words(waiting, tr("person"), tr("people")), context.temp_allocator),
			strings.to_lower(count_words(due, tr("task"), tr("tasks")), context.temp_allocator),
		),
		"text-[15] text-muted-foreground",
	)
	p.end(ui)

	if next >= 0 {
		next_up(ui, h, next)
	}
	if s.source == .Device && len(s.identities) == 0 {
		p.col(ui, "w-full gap-1.5 px-5 py-4 rounded-2xl border border-border")
		p.text(ui, tr("Nothing is indexed on this device yet."), "text-[14] font-medium")
		p.text(ui, s.daemon ? tr("palm-indexd is reading your mail, files and calendars now. This fills in as it goes.") : tr("The indexer, palm-indexd, is not running. Start it, or run `index daemon`, and Today fills in."), "text-[12.5] text-muted-foreground")
		p.end(ui)
	}

	p.row(ui, "w-full gap-10 items-start")
	p.col(ui, "flex-1 min-w-0 gap-6")
	agenda(ui, h)
	tasks(ui, h)
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-6")
	waiting_on_you(ui, h)
	recent(ui, h)
	p.end(ui)
	p.end(ui)

	assistant_line(ui, h)
}

// assistant_line says where the assistant can look, in the place a person
// would reach for it. It never runs across identities, so in the mixed view
// it asks for one rather than quietly picking.
assistant_line :: proc(ui: ^p.Ctx, h: ^Home) {
	p.row(ui, "w-full items-center gap-3 px-4 py-3 rounded-xl border border-border")
	if h.ident >= 0 {
		name := h.store.identities[h.ident].name
		p.div(ui, tfmt("flex-row size-7 shrink-0 items-center justify-center rounded-lg bg-id-%d/12", h.ident))
		p.icon(ui, ICON_SPARKLES, tfmt("size-3.5 text-id-%d", h.ident))
		p.end(ui)
		p.text(ui, tfmt(tr("Ask the %s assistant"), name), "text-[13] font-medium shrink-0")
		p.text(ui, tfmt(tr("It reads %s's mail, files and calendar, and nothing else."), name), "flex-1 min-w-0 text-[12.5] text-muted-foreground truncate")
	} else {
		p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-lg bg-muted")
		p.icon(ui, ICON_SPARKLES, "size-3.5 text-muted-foreground")
		p.end(ui)
		p.text(ui, tr("The assistant works inside one identity."), "text-[13] font-medium shrink-0")
		p.text(ui, tfmt(tr("Choose one with Ctrl 1–%d to ask it something."), max(1, min(len(h.store.identities), 9))), "flex-1 min-w-0 text-[12.5] text-muted-foreground truncate")
	}
	p.text(ui, "Ctrl K", "shrink-0 text-[11.5] text-muted-foreground")
	p.end(ui)
}

next_up :: proc(ui: ^p.Ctx, h: ^Home, i: int) {
	it := h.store.items[i]
	in_min := it.at - h.store.now_min
	p.row(ui, tfmt("w-full items-center gap-4 px-5 py-4 rounded-2xl bg-id-%d/[0.07] border border-id-%d/15", it.ident, it.ident))
	p.div(ui, tfmt("w-[3] h-[40] shrink-0 rounded-full bg-id-%d", it.ident))
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-1")
	p.row(ui, "items-center gap-2")
	p.text(ui, tr("Next"), tfmt("text-[11.5] font-semibold uppercase tracking-wide text-id-%d", it.ident))
	when_ := in_min < 60 ? tfmt(tr("in %d min"), in_min) : tfmt(tr("at %s"), clock(it.at))
	if it.day == 1 {
		when_ = tfmt(tr("tomorrow at %s"), clock(it.at))
	}
	p.text(ui, when_, "text-[12] text-muted-foreground")
	p.end(ui)
	p.text(ui, it.title, "text-[17] font-semibold truncate")
	p.text(ui, tfmt("%s – %s · %s", clock(it.at), clock(it.at + it.mins), it.detail), "text-[12.5] text-muted-foreground truncate")
	p.end(ui)
	if h.ident < 0 {
		id_chip(ui, h, it.ident)
	}
	p.key(ui, "join")
	j := p.row(ui, "h-8 shrink-0 items-center gap-1.5 px-3 rounded-lg border border-border bg-background hover:bg-accent transition cursor-pointer")
	if p.clickable(ui, j) {
		open_item(h, i)
	}
	// The one most useful action: Join when there is a call, else Open.
	call := h.store.source == .Fixtures || strings.contains(strings.to_lower(it.detail, context.temp_allocator), "video") || strings.contains(it.detail, "://")
	p.icon(ui, call ? ICON_VIDEO : ICON_ARROW_UP_RIGHT, "size-3.5 text-foreground")
	p.text(ui, call ? tr("Join") : tr("Open"), "text-[12.5] font-medium")
	p.end(ui)
	p.end(ui)
}

agenda :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	p.col(ui, "w-full")
	defer p.end(ui)
	n := 0
	for it in s.items {
		if it.kind == .Event && it.day == 0 && visible(h, it) {
			n += 1
		}
	}
	section_head(ui, tr("Agenda"), tfmt("%d", n))
	if n == 0 {
		p.text(ui, tr("Nothing on the calendar today."), "px-3 py-2 text-[13] text-muted-foreground")
		return
	}
	drew_now := false
	for it, i in s.items {
		if it.kind != .Event || it.day != 0 || !visible(h, it) {
			continue
		}
		past := it.at + it.mins <= s.now_min
		if !drew_now && it.at > s.now_min {
			now_line(ui, s.now_min)
			drew_now = true
		}
		selectable(ui, h, i, "w-full items-center gap-3 px-3 py-2 rounded-lg transition cursor-pointer")
		p.text(ui, clock(it.at), past ? "w-[42] shrink-0 text-[12.5] tabular-nums text-muted-foreground/60" : "w-[42] shrink-0 text-[12.5] tabular-nums text-muted-foreground")
		p.div(ui, tfmt("w-[3] h-[32] shrink-0 rounded-full bg-id-%d%s", it.ident, past ? "/35" : ""))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, it.title, past ? "text-[13.5] text-muted-foreground truncate" : "text-[13.5] font-medium truncate")
		p.text(ui, tfmt("%d min · %s", it.mins, it.detail), past ? "text-[12] text-muted-foreground/60 truncate" : "text-[12] text-muted-foreground truncate")
		p.end(ui)
		if h.ident < 0 {
			id_label(ui, h, it.ident)
		}
		p.end(ui)
	}
	if !drew_now {
		now_line(ui, s.now_min)
	}
}

now_line :: proc(ui: ^p.Ctx, now: int) {
	p.row(ui, "w-full items-center gap-3 px-3 py-0.5")
	p.text(ui, clock(now), "w-[42] shrink-0 text-[11.5] font-semibold tabular-nums text-now")
	p.div(ui, "size-[7] shrink-0 rounded-full bg-now")
	p.end(ui)
	p.div(ui, "flex-1 h-px bg-now/50")
	p.end(ui)
	p.end(ui)
}

tasks :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	p.col(ui, "w-full")
	defer p.end(ui)
	n := 0
	for it in s.items {
		if it.kind == .Task && it.day <= 0 && visible(h, it) {
			n += 1
		}
	}
	section_head(ui, tr("Tasks"), tfmt("%d", n))
	for it, i in s.items {
		if it.kind != .Task || it.day > 0 || !visible(h, it) {
			continue
		}
		selectable(ui, h, i, "w-full items-center gap-3 px-3 py-2 rounded-lg transition cursor-pointer")
		p.icon(ui, it.done ? ICON_CIRCLE_CHECK : ICON_CIRCLE, it.done ? "size-[17] shrink-0 text-muted-foreground/60" : "size-[17] shrink-0 text-muted-foreground")
		p.text(ui, it.title, it.done ? "flex-1 min-w-0 text-[13.5] text-muted-foreground line-through truncate" : "flex-1 min-w-0 text-[13.5] truncate")
		overdue := it.day < 0 && !it.done && (it.dated || s.source == .Fixtures)
		p.text(ui, it.detail, overdue ? "shrink-0 text-[12] font-medium text-destructive" : "shrink-0 text-[12] text-muted-foreground")
		if h.ident < 0 {
			id_label(ui, h, it.ident)
		}
		p.end(ui)
	}
}

waiting_on_you :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	p.col(ui, "w-full")
	defer p.end(ui)
	n := 0
	for it in s.items {
		if it.waiting && visible(h, it) {
			n += 1
		}
	}
	section_head(ui, tr("Waiting on you"), tfmt("%d", n))
	if n == 0 {
		p.text(ui, tr("Nobody is waiting on you here."), "px-3 py-2 text-[13] text-muted-foreground")
		return
	}
	for it, i in s.items {
		if !it.waiting || !visible(h, it) {
			continue
		}
		selectable(ui, h, i, "w-full items-start gap-3 px-3 py-2.5 rounded-lg transition cursor-pointer")
		p.div(ui, tfmt("flex-row size-8 shrink-0 items-center justify-center rounded-full bg-id-%d/12 mt-0.5", it.ident))
		p.text(ui, initials(it.who), tfmt("text-[11] font-semibold text-id-%d", it.ident))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "w-full items-center gap-2")
		p.text(ui, it.who, "text-[13] font-semibold truncate min-w-0")
		p.spacer(ui, "flex-1")
		if h.ident < 0 {
			id_label(ui, h, it.ident)
		}
		p.text(ui, ago(s, it), "text-[11.5] text-muted-foreground tabular-nums shrink-0 whitespace-nowrap")
		p.end(ui)
		p.text(ui, it.title, it.unread ? "text-[13] font-medium truncate" : "text-[13] truncate")
		p.text(ui, it.detail, "text-[12] text-muted-foreground truncate")
		p.end(ui)
		p.end(ui)
	}
}

app_icon :: proc(it: Item) -> p.Icon {
	switch it.app {
	case "Sheets":
		return ICON_SHEET
	case "Slides":
		return ICON_PRESENTATION
	case "Docs":
		return ICON_FILE_TEXT
	}
	switch it.kind {
	case .Mail:
		return ICON_MAIL
	case .Event:
		return ICON_CALENDAR
	case .Task:
		return ICON_CIRCLE_CHECK
	case .Doc:
		return ICON_FILE_TEXT
	case .File:
		return ICON_FILE
	case .Note:
		return ICON_FILE_TEXT
	case .Chat:
		return ICON_MESSAGE_SQUARE
	case .Person:
		return ICON_USER
	case .Page:
		return ICON_GLOBE
	case .Issue:
		return ICON_SQUARE_CHECK
	}
	return ICON_FILE
}

recent :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	p.col(ui, "w-full")
	defer p.end(ui)
	section_head(ui, s.source == .Fixtures ? tr("Recently opened") : tr("Recently changed"))
	any := false
	for it, i in s.items {
		if !it.recent || !visible(h, it) {
			continue
		}
		any = true
		selectable(ui, h, i, "w-full items-center gap-3 px-3 py-2 rounded-lg transition cursor-pointer")
		p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted")
		p.icon(ui, app_icon(it), "size-4 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, it.title, "text-[13.5] font-medium truncate")
		who := it.who == "You" ? tr("you") : it.who
		if who == "" {
			p.text(ui, tfmt("%s · %s · %s", ago(s, it), it.app, it.detail), "text-[12] text-muted-foreground truncate")
		} else {
			p.text(ui, tfmt("%s · %s, edited by %s", ago(s, it), it.app, who), "text-[12] text-muted-foreground truncate")
		}
		p.end(ui)
		if h.ident < 0 {
			id_label(ui, h, it.ident)
		}
		p.end(ui)
	}
	if !any {
		p.text(ui, tr("Nothing opened recently."), "px-3 py-2 text-[13] text-muted-foreground")
	}
}

// ---------------------------------------------------------------------------
// Search results
// ---------------------------------------------------------------------------

results :: proc(ui: ^p.Ctx, h: ^Home) {
	s := &h.store
	text := string(h.query[:])
	r := search(s, text, h.ident)
	q := parse_query(s, text)
	if s.source == .Device {
		// Highlight what the index matched: its folded words.
		clear(&q.terms)
		for w in strings.fields(strings.to_lower(text, context.temp_allocator), context.temp_allocator) {
			if !strings.contains(w, ":") {
				append(&q.terms, strings.trim(w, "\"-"))
			}
		}
	}

	p.col(ui, "w-full px-8 pt-5 pb-10 gap-5")
	defer p.end(ui)

	// Which identities to look in, as chips with what each would find.
	p.row(ui, "w-full items-center gap-2 px-3 flex-wrap")
	total := 0
	for c in r.per_id {
		total += c
	}
	scope_chip(ui, h, -1, tfmt(tr("All identities  %d"), total), total)
	for id, i in s.identities {
		scope_chip(ui, h, i, tfmt("%s  %d", id.name, r.per_id[i]), r.per_id[i])
	}
	p.spacer(ui, "flex-1")
	for b in r.badges {
		p.key(ui, b)
		sc.badge(ui, b, .Secondary)
	}
	p.end(ui)

	if r.unknown != "" {
		p.row(ui, "w-full items-center gap-2 px-3")
		p.icon(ui, ICON_SPARKLES, "size-3.5 text-muted-foreground")
		p.text(ui, tfmt(tr("“%s” is not a filter Home knows: try in:work, type:mail, is:unread"), r.unknown), "text-[12.5] text-muted-foreground")
		p.end(ui)
	}
	if r.correction != "" {
		p.row(ui, "w-full items-center gap-2 px-3")
		p.icon(ui, ICON_SPARKLES, "size-3.5 text-muted-foreground")
		p.text(ui, tfmt(tr("Showing results for %s"), r.correction), "text-[12.5] text-muted-foreground")
		p.end(ui)
	}

	if len(r.hits) == 0 {
		p.col(ui, "w-full items-center gap-2 pt-16")
		p.icon(ui, ICON_SEARCH, "size-6 text-muted-foreground/60")
		p.text(ui, h.ident >= 0 ? tfmt(tr("Nothing in %s matches."), s.identities[h.ident].name) : tr("Nothing matches."), "text-[15] font-medium")
		if h.ident >= 0 && total > 0 {
			p.text(ui, tfmt(tr("%d results in other identities. Ctrl 0 shows them, labelled."), total), "text-[13] text-muted-foreground")
		}
		p.end(ui)
	} else {
		cur: Maybe(Kind)
		open := false
		for hit in r.hits {
			it := s.items[hit.item]
			if k, ok := cur.?; !ok || k != it.kind {
				if open {
					p.end(ui)
				}
				p.key(ui, KIND_PLURAL[it.kind])
				p.col(ui, "w-full")
				open = true
				cur = it.kind
				section_head(ui, tr(KIND_PLURAL[it.kind]), tfmt("%d", r.per_kind[it.kind]))
			}
			result_row(ui, h, hit.item, q.terms[:])
		}
		if open {
			p.end(ui)
		}
		// Home is the person's window, not a scope, so it may say that other
		// identities have matches. It never shows them without being asked.
		if elsewhere := total - len(r.hits); h.ident >= 0 && elsewhere > 0 {
			p.row(ui, "w-full items-center gap-2 px-3 py-2.5 rounded-lg bg-muted/60")
			p.icon(ui, ICON_LAYERS, "size-3.5 shrink-0 text-muted-foreground")
			p.text(ui, tfmt(tr("%d more in your other identities."), elsewhere), "text-[12.5] font-medium")
			p.text(ui, tr("Ctrl 0 shows them, each labelled."), "text-[12.5] text-muted-foreground")
			p.end(ui)
		}
	}

	p.row(ui, "w-full items-center gap-2 px-3 pt-2")
	p.icon(ui, ICON_LOCK, "size-3.5 shrink-0 text-muted-foreground/70")
	p.text(
		ui,
		s.source == .Device ? tfmt(tr("Searched %d items on this device, in %s, in %.1f ms. Nothing left the machine."), r.scanned, h.ident >= 0 ? s.identities[h.ident].name : tr("every identity"), f64(r.took_us) / 1000) : tfmt(tr("Searched %d items on this device, in %s. Nothing left the machine."), r.scanned, h.ident >= 0 ? s.identities[h.ident].name : tr("every identity")),
		"text-[12] text-muted-foreground/80",
	)
	p.end(ui)
}

scope_chip :: proc(ui: ^p.Ctx, h: ^Home, i: int, label: string, count: int) {
	on := h.ident == i
	p.key(ui, tfmt("scope%d", i))
	idx := p.row(ui, "h-7 shrink-0 items-center gap-1.5 px-3 rounded-full border transition cursor-pointer")
	if on {
		p.apply(ui, i < 0 ? "bg-foreground border-foreground" : tfmt("bg-id-%d border-id-%d", i, i), idx)
	} else {
		p.apply(ui, count == 0 ? "bg-background border-border opacity-50 hover:bg-accent" : "bg-background border-border hover:bg-accent", idx)
	}
	if p.clickable(ui, idx) {
		set_ident(h, i)
	}
	if i >= 0 && !on {
		p.div(ui, tfmt("size-1.5 shrink-0 rounded-full bg-id-%d", i))
		p.end(ui)
	}
	p.text(ui, label, on ? (i < 0 ? "text-[12] font-medium text-background whitespace-nowrap" : "text-[12] font-medium text-white whitespace-nowrap") : "text-[12] font-medium whitespace-nowrap")
	p.end(ui)
}

result_row :: proc(ui: ^p.Ctx, h: ^Home, item: int, terms: []string) {
	s := &h.store
	it := s.items[item]
	selectable(ui, h, item, "w-full items-center gap-3 px-3 py-2 rounded-lg transition cursor-pointer")
	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted")
	p.icon(ui, app_icon(it), "size-4 text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	// The title with the match drawn heavier.
	pre, mid, post := split_match(it.title, terms)
	p.row(ui, "w-full min-w-0 items-center overflow-hidden")
	if pre != "" {
		p.text(ui, pre, "text-[13.5] whitespace-nowrap shrink-0")
	}
	if mid != "" {
		p.text(ui, mid, "text-[13.5] font-semibold whitespace-nowrap shrink-0")
	}
	if post != "" {
		p.text(ui, post, "text-[13.5] whitespace-nowrap min-w-0 truncate")
	}
	p.end(ui)
	meta: string
	switch it.kind {
	case .Mail:
		meta = tfmt("%s — %s", it.who, it.detail)
	case .Event:
		meta = tfmt("%s · %s", it.day == 0 ? tr("Today") : tfmt(tr("in %d days"), it.day), it.detail)
		if it.day == 0 {
			meta = tfmt("%s %s · %s", tr("Today"), clock(it.at), it.detail)
		}
	case .Doc, .File:
		meta = tfmt("%s · %s", it.app, it.detail)
	case .Chat:
		meta = tfmt("%s: %s", it.who, it.detail)
	case .Task, .Person, .Note, .Page, .Issue:
		meta = it.detail
	}
	if it.kind == .Mail && h.store.source == .Device {
		meta = tfmt("%s — %s", first_person(it.who), it.detail)
	}
	p.text(ui, meta, "text-[12] text-muted-foreground truncate")
	snippet_line(ui, it)
	p.end(ui)
	// Always labelled in results: even inside one identity, a result list is
	// something people screenshot and paste.
	id_label(ui, h, it.ident)
	if it.kind != .Person && it.kind != .Task {
		when_ := ago(s, it)
		if it.kind == .Event {
			when_ = it.day == 0 ? clock(it.at) : it.day > 0 ? tfmt("+%dd", it.day) : ago(s, it)
		}
		p.text(ui, when_, "w-[64] shrink-0 text-right text-[11.5] text-muted-foreground tabular-nums whitespace-nowrap")
	} else {
		p.div(ui, "w-[64] shrink-0")
		p.end(ui)
	}
	p.end(ui)
}

// snippet_line draws the matched passage under a result, the first match
// in it heavier. Only where the body says more than the title.
snippet_line :: proc(ui: ^p.Ctx, it: Item) {
	if it.snippet == "" {
		return
	}
	#partial switch it.kind {
	case .Mail, .Doc, .File, .Note, .Page, .Issue:
	case:
		return
	}
	sn := one_line_snip(it.snippet)
	m := it.mark
	p.row(ui, "w-full min-w-0 items-center overflow-hidden")
	if m[0] >= 0 && m[1] <= len(sn) && m[0] < m[1] && len(sn) == len(it.snippet) {
		if m[0] > 0 {
			p.text(ui, sn[:m[0]], "text-[12] text-muted-foreground/80 whitespace-nowrap shrink-0")
		}
		p.text(ui, sn[m[0]:m[1]], "text-[12] font-semibold text-foreground/80 whitespace-nowrap shrink-0")
		p.text(ui, sn[m[1]:], "text-[12] text-muted-foreground/80 whitespace-nowrap min-w-0 truncate")
	} else {
		p.text(ui, sn, "text-[12] text-muted-foreground/80 whitespace-nowrap min-w-0 truncate")
	}
	p.end(ui)
}

// one_line_snip keeps a snippet's byte offsets (the marks point into it)
// but replaces line breaks with spaces.
one_line_snip :: proc(s: string) -> string {
	b := transmute([]u8)strings.clone(s, context.temp_allocator)
	for &c in b {
		if c == '\n' || c == '\r' || c == '\t' {
			c = ' '
		}
	}
	return string(b)
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

sheet_open :: proc(ui: ^p.Ctx, w: int, top: f32, border := "border-border") {
	win := p.size(ui)
	wrap := p.div(ui, tfmt("absolute z-50 w-[%d]", w))
	s := p.style(ui, wrap)
	s.inset[p.LEFT] = p.px(max(8, (win.x - f32(w)) / 2))
	s.inset[p.TOP] = p.px(top)
	p.col(ui, tfmt("w-full rounded-2xl border %s bg-popover shadow-2xl overflow-hidden", border))
}

sheet_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

scrim :: proc(ui: ^p.Ctx, h: ^Home) {
	s := p.div(ui, h.dark ? "absolute inset-0 z-40 bg-black/60" : "absolute inset-0 z-40 bg-black/25")
	if p.clickable(ui, s) {
		h.mode = .Normal
	}
	p.end(ui)
}

hint :: proc(ui: ^p.Ctx, key, what: string) {
	p.row(ui, "items-center gap-1.5 shrink-0")
	sc.kbd(ui, key)
	p.text(ui, what, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

action_icon :: proc(c: Command) -> p.Icon {
	switch c.action {
	case .Switch:
		return c.arg < 0 ? ICON_LAYERS : ICON_ARROW_LEFT_RIGHT
	case .New:
		switch c.kind {
		case .Mail:
			return ICON_MAIL
		case .Event:
			return ICON_CALENDAR_PLUS
		case .Task:
			return ICON_CIRCLE_CHECK
		case .Note:
			return ICON_NOTEBOOK_PEN
		case .Doc:
			return ICON_FILE_TEXT
		}
	case .Ask:
		return ICON_SPARKLES
	case .Quiet:
		return ICON_BELL_OFF
	case .Carry:
		return ICON_REPEAT
	case .Open_App:
		return ICON_ARROW_UP_RIGHT
	case .Theme:
		return ICON_MOON
	case .Help:
		return ICON_KEYBOARD
	}
	return ICON_COMMAND
}

palette :: proc(ui: ^p.Ctx, h: ^Home) {
	scrim(ui, h)
	sheet_open(ui, 620, 96)
	defer sheet_close(ui)

	q := string(h.pal_query[:])
	p.row(ui, "w-full h-[56] items-center gap-3 px-5 border-b border-border")
	p.icon(ui, ICON_COMMAND, "size-[18] shrink-0 text-muted-foreground")
	p.row(ui, "items-center shrink-0")
	if q != "" {
		p.text(ui, q, "text-[15] whitespace-nowrap shrink-0")
	}
	if p.caret_on(ui) {
		p.div(ui, "w-px h-[19] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	if q == "" {
		p.text(ui, tr("Type a command, an identity, an app…"), "text-[15] text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)
	p.spacer(ui, "flex-1")
	if h.ident >= 0 {
		id_chip(ui, h, h.ident, tfmt(tr("as %s"), h.store.identities[h.ident].name))
	} else {
		p.text(ui, tr("all identities"), "text-[12] text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)

	list := palette_filter(h)
	VISIBLE :: 9
	start := max(0, h.pal_sel - VISIBLE + 1)
	p.col(ui, "w-full p-2 gap-0.5")
	if len(list) == 0 {
		p.text(ui, tr("No command matches."), "px-3 py-3 text-[13] text-muted-foreground")
	}
	last_group := ""
	for c, n in list {
		if n < start || n >= start + VISIBLE {
			continue
		}
		if c.group != last_group {
			p.key(ui, tfmt("g%d", n))
			p.text(ui, c.group, "px-3 pt-2 pb-1 text-[11] font-semibold tracking-wide uppercase text-muted-foreground/80")
			last_group = c.group
		}
		p.key(ui, tfmt("c%d", n))
		idx := p.row(ui, "w-full h-[38] items-center gap-3 px-3 rounded-lg cursor-pointer")
		on := n == h.pal_sel
		p.apply(ui, on ? "bg-accent" : "hover:bg-accent/60", idx)
		if p.clickable(ui, idx) {
			run_command(h, c)
		}
		// A command that acts as an identity wears that identity's colour on
		// its icon; the name is already in the label.
		if c.arg >= 0 && (c.action == .Switch || c.action == .New || c.action == .Ask || c.action == .Quiet) {
			p.div(ui, tfmt("flex-row size-6 shrink-0 items-center justify-center rounded-md bg-id-%d/12", c.arg))
			p.icon(ui, action_icon(c), tfmt("size-3.5 text-id-%d", c.arg))
			p.end(ui)
		} else {
			p.div(ui, "flex-row size-6 shrink-0 items-center justify-center rounded-md")
			p.icon(ui, action_icon(c), "size-4 text-muted-foreground")
			p.end(ui)
		}
		p.text(ui, c.label, "flex-1 min-w-0 text-[13.5] truncate")
		if c.keys != "" {
			p.text(ui, c.keys, "shrink-0 text-[11.5] text-muted-foreground whitespace-nowrap")
		}
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "w-full h-[42] items-center gap-4 px-5 border-t border-border bg-muted/40")
	hint(ui, "↑↓", tr("choose"))
	hint(ui, "Enter", tr("run"))
	hint(ui, "Esc", tr("close"))
	p.spacer(ui, "flex-1")
	p.text(ui, tfmt(tr("%d commands"), len(list)), "text-[11.5] text-muted-foreground")
	p.end(ui)
}

create_sheet :: proc(ui: ^p.Ctx, h: ^Home) {
	scrim(ui, h)
	sheet_open(ui, 580, 120, h.new_ident >= 0 ? tfmt("border-id-%d/60", h.new_ident) : "border-border")
	defer sheet_close(ui)

	// The sheet wears the identity it will create in, before anything is
	// typed: its border, the From card, and the Enter hint all name it.
	chosen := h.new_ident >= 0

	p.row(ui, "w-full items-center gap-3 px-6 pt-5 pb-3")
	p.text(ui, tr("New"), "text-[17] font-semibold")
	p.spacer(ui, "flex-1")
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted")
	for k in Create_Kind {
		on := h.new_kind == k
		p.key(ui, CREATE_LABEL[k])
		idx := p.row(ui, "h-7 items-center px-2.5 rounded-md cursor-pointer")
		p.apply(ui, on ? "bg-background shadow-sm" : "hover:bg-background/60", idx)
		if p.clickable(ui, idx) {
			h.new_kind = k
		}
		p.text(ui, tr(CREATE_LABEL[k]), on ? "text-[12.5] font-medium" : "text-[12.5] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	// Who it is from: the line that decides everything else.
	p.col(ui, "w-full px-6 gap-2 pb-4")
	p.text(ui, h.new_kind == .Mail ? tr("From") : tr("In"), "text-[12] font-medium text-muted-foreground")
	if chosen {
		id := h.store.identities[h.new_ident]
		p.row(ui, tfmt("w-full h-[52] items-center gap-3 px-3 rounded-xl border border-id-%d/40 bg-id-%d/[0.06]", h.new_ident, h.new_ident))
		monogram(ui, h.new_ident, id.name)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, id.name, "text-[13.5] font-semibold")
		p.text(ui, h.new_kind == .Mail ? id.address : tfmt(tr("%s's calendar, files and tasks"), id.name), "text-[12] text-muted-foreground truncate")
		p.end(ui)
		hint(ui, "Tab", tr("change"))
		p.end(ui)
	} else {
		p.row(ui, "w-full h-[52] items-center gap-3 px-3 rounded-xl border border-dashed border-border")
		p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-muted")
		p.icon(ui, ICON_USER, "size-4 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, tr("Choose an identity"), "text-[13.5] font-semibold")
		p.text(ui, tr("Showing everything, so Home will not guess who this is from."), "text-[12] text-muted-foreground truncate")
		p.end(ui)
		hint(ui, "Tab", tr("choose"))
		p.end(ui)
		p.row(ui, "w-full items-center gap-1.5")
		for id, i in h.store.identities {
			p.key(ui, tfmt("pick%d", i))
			idx := p.row(ui, "cursor-pointer")
			if p.clickable(ui, idx) {
				h.new_ident = i
				h.new_err = ""
			}
			id_chip(ui, h, i, tfmt("%s  Ctrl %d", id.name, i + 1))
			p.end(ui)
		}
		p.end(ui)
	}

	p.text(ui, h.new_kind == .Mail ? tr("Subject") : tr("Title"), "pt-2 text-[12] font-medium text-muted-foreground")
	t := string(h.new_title[:])
	p.row(ui, "w-full h-10 items-center px-3 rounded-lg border border-ring ring-3 ring-ring/25 bg-background")
	if t != "" {
		p.text(ui, t, "text-[13.5] whitespace-nowrap shrink-0")
	}
	if p.caret_on(ui) {
		p.div(ui, "w-px h-[17] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	if t == "" {
		p.text(ui, h.new_kind == .Mail ? tr("What is it about?") : tr("Untitled"), "text-[13.5] text-muted-foreground/70 whitespace-nowrap")
	}
	p.end(ui)
	if h.new_err != "" {
		p.text(ui, h.new_err, "text-[12.5] font-medium text-destructive")
	}
	p.end(ui)

	p.row(ui, "w-full h-[44] items-center gap-4 px-6 border-t border-border bg-muted/40")
	hint(ui, "Tab", tr("identity"))
	hint(ui, "←→", tr("kind"))
	p.spacer(ui, "flex-1")
	hint(ui, "Esc", tr("cancel"))
	hint(ui, "Enter", chosen ? tfmt(tr("create in %s"), h.store.identities[h.new_ident].name) : tr("create"))
	p.end(ui)
}

carry_sheet :: proc(ui: ^p.Ctx, h: ^Home) {
	scrim(ui, h)
	sheet_open(ui, 560, 120)
	defer sheet_close(ui)
	it := h.store.items[h.carry_item]
	from := h.store.identities[it.ident]
	to := h.store.identities[h.carry_to]

	p.col(ui, "w-full px-6 pt-5 pb-4 gap-4")
	p.row(ui, "w-full items-center gap-2.5")
	p.icon(ui, ICON_REPEAT, "size-[18] text-foreground")
	p.text(ui, tr("Carry to another identity"), "text-[17] font-semibold")
	p.end(ui)

	p.row(ui, "w-full items-center gap-3 px-3 py-3 rounded-xl bg-muted/60")
	p.div(ui, "flex-row size-8 shrink-0 items-center justify-center rounded-lg bg-background")
	p.icon(ui, app_icon(it), "size-4 text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, it.title, "text-[13.5] font-medium truncate")
	p.text(ui, it.app != "" ? it.app : KIND_APP[it.kind], "text-[12] text-muted-foreground")
	p.end(ui)
	id_chip(ui, h, it.ident)
	p.end(ui)

	p.text(ui, tr("To"), "text-[12] font-medium text-muted-foreground")
	p.col(ui, "w-full gap-1")
	for id, i in h.store.identities {
		if i == it.ident {
			continue
		}
		on := i == h.carry_to
		p.key(ui, tfmt("to%d", i))
		idx := p.row(ui, "w-full h-[48] items-center gap-3 px-3 rounded-xl border cursor-pointer")
		p.apply(ui, on ? tfmt("border-id-%d/50 bg-id-%d/[0.06]", i, i) : "border-transparent hover:bg-accent", idx)
		if p.clickable(ui, idx) {
			h.carry_to = i
		}
		monogram(ui, i, id.name, 7)
		p.text(ui, id.name, "text-[13.5] font-medium")
		p.text(ui, id.address, "flex-1 min-w-0 text-[12] text-muted-foreground truncate")
		if on {
			p.icon(ui, ICON_CHECK, tfmt("size-4 shrink-0 text-id-%d", i))
		}
		p.end(ui)
	}
	p.end(ui)

	// The crossing, said once in colour and once in words.
	p.col(ui, "w-full gap-2.5 px-4 py-3.5 rounded-xl border border-border")
	p.row(ui, "items-center gap-2")
	id_chip(ui, h, it.ident)
	p.icon(ui, ICON_ARROW_RIGHT, "size-3.5 text-muted-foreground")
	id_chip(ui, h, h.carry_to)
	p.text(ui, tr("a copy, not a link"), "pl-1 text-[12] font-medium text-muted-foreground")
	p.end(ui)
	p.text(
		ui,
		tfmt(
			tr("%s keeps the original. %s gets its own copy, owned there. Nothing else moves: no thread, no sharing link, no history. Both identities' carry logs record it."),
			from.name,
			to.name,
		),
		"w-full text-[12.5] leading-relaxed text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.row(ui, "w-full h-[44] items-center gap-4 px-6 border-t border-border bg-muted/40")
	hint(ui, "Tab", tr("destination"))
	p.spacer(ui, "flex-1")
	hint(ui, "Esc", tr("cancel"))
	hint(ui, "Enter", tfmt(tr("carry to %s"), to.name))
	p.end(ui)
}

help_sheet :: proc(ui: ^p.Ctx, h: ^Home) {
	scrim(ui, h)
	sheet_open(ui, 480, 110)
	defer sheet_close(ui)
	p.col(ui, "w-full px-6 pt-5 pb-5 gap-1")
	p.text(ui, tr("Keys"), "text-[17] font-semibold pb-2")
	row :: proc(ui: ^p.Ctx, k, what: string) {
		p.key(ui, k)
		p.row(ui, "w-full h-8 items-center gap-3")
		p.text(ui, what, "flex-1 text-[13]")
		sc.kbd(ui, k)
		p.end(ui)
	}
	row(ui, tr("any letter"), tr("Search everything"))
	row(ui, "↑ ↓", tr("Move through Today or the results"))
	row(ui, "Enter", tr("Open where it lives, as its identity"))
	row(ui, "Ctrl K", tr("Commands"))
	row(ui, "Ctrl N", tr("New mail, event, task, note, document"))
	row(ui, "Ctrl 1 … 4", tr("Into one identity"))
	row(ui, "Ctrl 0", tr("All identities, labelled"))
	row(ui, "Ctrl Shift C", tr("Carry the selection to another identity"))
	row(ui, "Esc", tr("Clear the search"))
	p.end(ui)
}

toast :: proc(ui: ^p.Ctx, h: ^Home) {
	if h.toast == "" {
		return
	}
	if h.toast_at == 0 {
		h.toast_at = f64(p.elapsed(ui))
	}
	if f64(p.elapsed(ui)) - h.toast_at > 3.2 {
		delete(h.toast)
		h.toast = ""
		h.toast_at = 0
		return
	}
	p.redraw(ui)
	win := p.size(ui)
	W :: 520
	idx := p.row(ui, tfmt("absolute z-30 w-[%d] items-center gap-2.5 px-4 py-2.5 rounded-xl bg-foreground shadow-xl", W))
	st := p.style(ui, idx)
	st.no_hit = true
	st.inset[p.LEFT] = p.px(RAIL_W + (win.x - RAIL_W - W) / 2)
	st.inset[p.TOP] = p.px(win.y - 64)
	p.icon(ui, ICON_ARROW_UP_RIGHT, "size-4 shrink-0 text-background")
	p.text(ui, h.toast, "flex-1 min-w-0 text-[13] text-background truncate")
	p.end(ui)
}

// greeting is the opening of Today's sentence: the time of day and the
// person's first name.
greeting :: proc(s: ^Store) -> string {
	first := s.owner
	if sp := strings.index_byte(first, ' '); sp > 0 {
		first = first[:sp]
	}
	part := tr("Good morning")
	switch {
	case s.now_min >= 18 * 60:
		part = tr("Good evening")
	case s.now_min >= 12 * 60:
		part = tr("Good afternoon")
	case s.now_min < 5 * 60:
		part = tr("Good evening")
	}
	return tfmt("%s, %s. ", part, first)
}
