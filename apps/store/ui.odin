package main

// The views: the toolbar and sidebar every view shares, then Discover, a
// category, search results, Installed, Updates and a package's page.
//
// The look is Files': a neutral window, a sidebar of places, 13 px type, and
// one accent. The confirmation and progress dialog is in dialog.odin.

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

tfmt :: fmt.tprintf

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

// category_tint is the colour of a category's icon tiles. Eight shelves, each
// recognisable at a glance, all quiet enough to sit next to each other.
category_tint :: proc(cat: string) -> (bg: string, fg: string) {
	switch cat {
	case "Accessories":
		return "bg-amber-500/15", "text-amber-600"
	case "Development":
		return "bg-indigo-500/15", "text-indigo-600"
	case "Graphics":
		return "bg-pink-500/15", "text-pink-600"
	case "Internet":
		return "bg-sky-500/15", "text-sky-600"
	case "Multimedia":
		return "bg-violet-500/15", "text-violet-600"
	case "Office":
		return "bg-emerald-500/15", "text-emerald-600"
	case "Games":
		return "bg-orange-500/15", "text-orange-600"
	}
	return "bg-slate-500/15", "text-slate-600"
}

category_icon :: proc(cat: string) -> p.Icon {
	switch cat {
	case "Accessories":
		return ICON_SCISSORS
	case "Development":
		return ICON_CODE
	case "Graphics":
		return ICON_PALETTE
	case "Internet":
		return ICON_GLOBE
	case "Multimedia":
		return ICON_FILM
	case "Office":
		return ICON_FILE_TEXT
	case "Games":
		return ICON_STAR
	case "System":
		return ICON_SETTINGS
	}
	return ICON_PACKAGE
}

// app_tile is a package's icon on its category's colour.
app_tile :: proc(ui: ^p.Ctx, pk: ^Package, size: int, radius := "rounded-xl") {
	bg, fg := category_tint(pk.category)
	p.div(ui, tfmt("flex-row size-[%d] shrink-0 items-center justify-center %s %s", size, radius, bg))
	p.icon(ui, icon_named(pk.icon), tfmt("size-[%d] %s", size / 2, fg))
	p.end(ui)
}

// button draws a shadcn button with an optional icon and reports a click.
button :: proc(ui: ^p.Ctx, key, label: string, ic: Maybe(p.Icon), v := sc.Variant.Default, size := sc.Size.SM, disabled := false, solid := false) -> bool {
	p.key(ui, key)
	idx := sc.button_open(ui, v, size, {disabled = disabled})
	if !disabled {
		hovered := p.is_hovered(ui, idx)
		p.apply(ui, sc.button_variant_class(v, {hover = hovered}), idx)
		p.apply(ui, "cursor-pointer", idx)
		if v == .Default {
			p.apply(ui, hovered ? "bg-selection/85 text-white" : "bg-selection text-white", idx)
		}
		if v == .Destructive && solid {
			// shadcn's destructive button is a tint, which reads as disabled
			// on the one button that confirms a removal.
			p.apply(ui, hovered ? "bg-destructive/85 text-white" : "bg-destructive text-white", idx)
		}
	}
	clicked := !disabled && p.clickable(ui, idx)
	if icon, has := ic.?; has {
		p.icon(ui, icon, "size-3.5 shrink-0")
	}
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	sc.button_end(ui)
	return clicked
}

// state_badge says where a package stands, in the corner of a card.
state_badge :: proc(ui: ^p.Ctx, pk: ^Package) {
	switch {
	case pk.upgradable:
		sc.badge_icon(ui, "Update", ICON_DOWNLOAD, .Secondary)
	case pk.installed != "":
		sc.badge_icon(ui, "Installed", ICON_CHECK, .Outline)
	}
}

section_heading :: proc(ui: ^p.Ctx, title: string, count: int, more_key := "") -> (more: bool) {
	p.row(ui, "w-full items-end gap-2 shrink-0")
	p.text(ui, title, "text-[15] font-semibold text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if count >= 0 {
		p.text(ui, tfmt("%d", count), "text-[12] text-muted-foreground pb-px")
	}
	p.spacer(ui, "flex-1")
	if more_key != "" {
		p.key(ui, more_key)
		idx := p.row(ui, "items-center gap-0.5 px-1.5 h-6 rounded-md cursor-pointer transition hover:bg-accent")
		more = p.clickable(ui, idx)
		p.text(ui, "See all", "text-[12] font-medium text-selection whitespace-nowrap")
		p.style(ui).shrink = 0
		p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 text-selection")
		p.end(ui)
	}
	p.end(ui)
	return
}

// scroll_body opens the scrolling part of a view. One per view, keyed by it,
// so each view remembers how far down it was.
scroll_body :: proc(ui: ^p.Ctx, key: string) {
	p.key(ui, tfmt("scroll:%s", key))
	p.col(ui, "flex-1 min-h-0 w-full overflow-y-auto")
	p.col(ui, "w-full px-7 pt-6 pb-8 gap-7")
}

scroll_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

view_header :: proc(ui: ^p.Ctx, title, subtitle: string, in_row := false) {
	p.col(ui, in_row ? "flex-1 min-w-0 gap-1" : "w-full gap-1 shrink-0")
	p.text(ui, title, "text-[22] font-semibold text-foreground tracking-tight")
	if subtitle != "" {
		p.text(ui, subtitle, "text-[13] text-muted-foreground")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

toolbar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-b border-border", TOOLBAR_H))
	defer p.end(ui)

	p.key(ui, "back")
	can_back := st.nav.view != .Discover || len(st.history) > 0
	idx := p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-md transition")
	if can_back {
		p.apply(ui, "hover:bg-accent text-foreground cursor-pointer", idx)
		if p.clickable(ui, idx) && st.txn.stage == .Idle {
			go_back(st)
		}
	} else {
		p.apply(ui, "text-muted-foreground/40", idx)
	}
	p.icon(ui, ICON_ARROW_LEFT, "size-4")
	p.end(ui)

	p.div(ui, "w-px h-5 mx-1 shrink-0 bg-border")
	p.end(ui)

	p.row(ui, "flex-1 min-w-0 items-center gap-1.5 overflow-hidden")
	p.icon(ui, ICON_PACKAGE, "size-4 shrink-0 text-selection")
	p.text(ui, "Software", "text-[13] font-semibold text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	crumb := ""
	switch st.nav.view {
	case .Discover:
		crumb = "Discover"
	case .Category:
		crumb = st.nav.category
	case .Search:
		crumb = "Search"
	case .Installed:
		crumb = "Installed"
	case .Updates:
		crumb = "Updates"
	case .Package:
		crumb = st.nav.pkg
	}
	p.icon(ui, ICON_CHEVRON_RIGHT, "size-3 shrink-0 text-muted-foreground/60")
	p.text(ui, crumb, "text-[13] text-muted-foreground truncate")
	p.end(ui)

	search_field(ui, st)

	p.key(ui, "reload")
	r := p.div(ui, "flex-row size-7 shrink-0 items-center justify-center rounded-md transition hover:bg-accent text-foreground cursor-pointer")
	if p.clickable(ui, r) && st.txn.stage == .Idle {
		reload(st)
		note(st, "Reloaded from palm")
	}
	p.icon(ui, ICON_REFRESH_CW, "size-4")
	p.end(ui)
}

search_field :: proc(ui: ^p.Ctx, st: ^State) {
	p.key(ui, "search")
	idx := p.row(ui, "h-7 w-[280] shrink-0 items-center gap-1.5 px-2 rounded-lg border border-input bg-background cursor-text transition")
	if st.searching {
		p.apply(ui, "border-ring ring-3 ring-ring/40", idx)
	}
	if p.clickable(ui, idx) && st.txn.stage == .Idle {
		st.searching = true
		st.swallow = true
	}
	defer p.end(ui)
	p.icon(ui, ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
	text := string(st.query[:])
	p.row(ui, "flex-1 min-w-0 items-center overflow-hidden")
	if text == "" {
		p.text(ui, "Search packages", "text-[13] text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, text, "text-[13] text-foreground whitespace-nowrap")
	}
	p.style(ui).shrink = 0
	if st.searching && p.caret_on(ui) {
		p.div(ui, "w-px h-[15] ml-px bg-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)
	if text != "" {
		x := p.div(ui, "flex-row size-4 shrink-0 items-center justify-center rounded-full bg-muted-foreground/25 hover:bg-muted-foreground/50 cursor-pointer transition")
		if p.clickable(ui, x) {
			clear(&st.query)
			sync_search(st)
		}
		p.icon(ui, ICON_X, "size-2.5 text-background")
		p.end(ui)
	} else if !st.searching {
		sc.kbd(ui, "/")
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

sidebar :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full bg-sidebar border-r border-border px-2 py-2.5 gap-px overflow-hidden", SIDEBAR_W))
	defer p.end(ui)

	n_inst := len(installed(&st.cat, false))
	n_up := len(upgradable(&st.cat))
	place(ui, st, "Discover", ICON_SPARKLES, {view = .Discover}, -1, false)
	place(ui, st, "Installed", ICON_HARD_DRIVE, {view = .Installed}, n_inst, false)
	place(ui, st, "Updates", ICON_DOWNLOAD, {view = .Updates}, n_up, n_up > 0)

	p.div(ui, "px-2 pt-4 pb-1.5")
	p.text(ui, "Categories", "text-[11] font-semibold text-muted-foreground/80 tracking-wide")
	p.end(ui)
	for c in CATEGORIES {
		n := len(in_category(&st.cat, c))
		if n == 0 {continue}
		place(ui, st, c, category_icon(c), {view = .Category, category = c}, n, false)
	}

	p.spacer(ui, "flex-1")
	p.col(ui, "px-2 pb-1 gap-1 shrink-0")
	hint(ui, "/", "search")
	hint(ui, "Esc", "back")
	p.end(ui)
}

place :: proc(ui: ^p.Ctx, st: ^State, label: string, ic: p.Icon, to: Nav, count: int, loud: bool) {
	on := st.nav.view == to.view && (to.view != .Category || st.nav.category == to.category)
	if st.nav.view == .Package && to.view == .Category {
		if pk := find(&st.cat, st.nav.pkg); pk != nil && pk.category == to.category {
			on = true
		}
	}
	p.key(ui, tfmt("place:%s", label))
	idx := p.row(ui, "h-[30] shrink-0 items-center gap-2 px-2 rounded-md transition cursor-pointer")
	p.apply(ui, on ? "bg-selection" : "hover:bg-accent/70", idx)
	if p.clickable(ui, idx) && st.txn.stage == .Idle {
		clear(&st.query)
		go(st, to)
	}
	p.icon(ui, ic, on ? "size-4 shrink-0 text-white" : "size-4 shrink-0 text-muted-foreground")
	p.text(ui, label, on ? "flex-1 min-w-0 truncate text-[13] font-medium text-white" : "flex-1 min-w-0 truncate text-[13] font-medium text-foreground")
	if count >= 0 {
		if loud {
			p.div(ui, on ? "flex-row h-[18] min-w-[18] px-1.5 items-center justify-center rounded-full bg-white" : "flex-row h-[18] min-w-[18] px-1.5 items-center justify-center rounded-full bg-selection")
			p.text(ui, tfmt("%d", count), on ? "text-[11] font-semibold text-selection" : "text-[11] font-semibold text-white")
			p.end(ui)
		} else {
			p.text(ui, tfmt("%d", count), on ? "text-[12] text-white/75" : "text-[12] text-muted-foreground")
		}
	}
	p.end(ui)
}

hint :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1.5")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground/70 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Discover and categories
// ---------------------------------------------------------------------------

discover_view :: proc(ui: ^p.Ctx, st: ^State) {
	scroll_body(ui, "discover")
	defer scroll_end(ui)

	avail := 0
	for q in st.cat.pkgs {
		if q.installed == "" {avail += 1}
	}
	view_header(ui, "Discover", tfmt("%d packages in the repository · %d installed · %d more to try", len(st.cat.pkgs), len(st.cat.pkgs) - avail, avail))

	feat := featured(&st.cat, 3)
	if len(feat) > 0 {
		p.col(ui, "w-full gap-3 shrink-0")
		section_heading(ui, "Featured", -1)
		p.row(ui, "w-full gap-4 shrink-0")
		for pk in feat {
			feature_card(ui, st, pk)
		}
		p.end(ui)
		p.end(ui)
	}

	for c in CATEGORIES {
		pkgs := in_category(&st.cat, c)
		if len(pkgs) == 0 {continue}
		p.col(ui, "w-full gap-3 shrink-0")
		if section_heading(ui, c, len(pkgs), len(pkgs) > 6 ? tfmt("more:%s", c) : "") {
			go(st, {view = .Category, category = c})
		}
		card_grid(ui, st, pkgs[:min(len(pkgs), 6)])
		p.end(ui)
	}
}

category_view :: proc(ui: ^p.Ctx, st: ^State) {
	scroll_body(ui, tfmt("cat:%s", st.nav.category))
	defer scroll_end(ui)
	pkgs := in_category(&st.cat, st.nav.category)
	p.row(ui, "w-full items-center gap-4 shrink-0")
	bg, fg := category_tint(st.nav.category)
	p.div(ui, tfmt("flex-row size-12 shrink-0 items-center justify-center rounded-2xl %s", bg))
	p.icon(ui, category_icon(st.nav.category), tfmt("size-6 %s", fg))
	p.end(ui)
	view_header(ui, st.nav.category, tfmt("%d packages", len(pkgs)), true)
	p.end(ui)
	card_grid(ui, st, pkgs)
}

feature_card :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package) {
	p.key(ui, tfmt("feat:%s", pk.name))
	idx := p.col(ui, "flex-1 min-w-0 h-[150] gap-3 p-4 rounded-xl border border-border bg-card transition cursor-pointer")
	p.apply(ui, p.is_hovered(ui, idx) ? "shadow-md border-foreground/20" : "shadow-sm", idx)
	clicked := p.clickable(ui, idx)
	p.row(ui, "w-full items-center gap-3")
	app_tile(ui, pk, 48)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, pk.name, "text-[15] font-semibold text-foreground truncate")
	p.text(ui, pk.category, "text-[12] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.text(ui, first_paragraph(pk), "w-full text-[12.5] text-muted-foreground leading-[18] max-h-[36] overflow-hidden")
	p.spacer(ui, "flex-1")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, human_size(pk.size), "text-[12] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui, "flex-1")
	action := primary_action(ui, st, pk, "feat")
	p.end(ui)
	p.end(ui)
	if clicked && !action {
		open_package(st, pk.name)
	}
}

// primary_action is the one button a card or row offers: Install, Update or
// Open. It reports whether it consumed the click.
primary_action :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package, where_: string) -> bool {
	switch {
	case pk.installed == "":
		if button(ui, tfmt("%s:install:%s", where_, pk.name), "Install", ICON_DOWNLOAD, .Default, .XS) {
			start_change(st, .Add, pk.name)
			return true
		}
	case pk.upgradable:
		if button(ui, tfmt("%s:update:%s", where_, pk.name), "Update", ICON_REFRESH_CW, .Secondary, .XS) {
			start_change(st, .Upgrade)
			return true
		}
	case command_of(pk) != "":
		if button(ui, tfmt("%s:open:%s", where_, pk.name), "Open", ICON_EXTERNAL_LINK, .Outline, .XS) {
			open_app(st, pk)
			return true
		}
	case:
		sc.badge_icon(ui, "Installed", ICON_CHECK, .Outline)
	}
	return false
}

first_paragraph :: proc(pk: ^Package) -> string {
	if pk.details != "" {
		if i := strings.index_byte(pk.details, '\n'); i > 0 {
			return pk.details[:i]
		}
		return pk.details
	}
	return pk.summary
}

card_grid :: proc(ui: ^p.Ctx, st: ^State, pkgs: []^Package) {
	COLS :: 3
	p.col(ui, "w-full gap-3 shrink-0")
	for i := 0; i < len(pkgs); i += COLS {
		p.row(ui, "w-full gap-3 shrink-0")
		for j in i ..< i + COLS {
			if j < len(pkgs) {
				app_card(ui, st, pkgs[j])
			} else {
				p.div(ui, "flex-1 min-w-0")
				p.end(ui)
			}
		}
		p.end(ui)
	}
	p.end(ui)
}

app_card :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package) {
	p.key(ui, tfmt("card:%s", pk.name))
	idx := p.row(ui, "flex-1 min-w-0 h-[72] items-center gap-3 px-3 rounded-xl border border-border bg-card transition cursor-pointer")
	p.apply(ui, p.is_hovered(ui, idx) ? "bg-accent/60 border-foreground/15" : "", idx)
	if p.clickable(ui, idx) {
		open_package(st, pk.name)
	}
	app_tile(ui, pk, 40)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "w-full items-center gap-1.5")
	p.text(ui, pk.name, "text-[13.5] font-semibold text-foreground truncate")
	p.end(ui)
	p.text(ui, pk.summary, "w-full text-[12] text-muted-foreground truncate")
	p.end(ui)
	state_badge(ui, pk)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

search_view :: proc(ui: ^p.Ctx, st: ^State) {
	q := string(st.query[:])
	hits := search(&st.cat, q)
	if len(hits) == 0 {
		empty_state(ui, ICON_SEARCH, "No matches", tfmt("No package's name, summary or category contains \"%s\".", q))
		return
	}
	scroll_body(ui, "search")
	defer scroll_end(ui)
	view_header(ui, tfmt("Results for \"%s\"", q), tfmt("%d %s", len(hits), len(hits) == 1 ? "package" : "packages"))
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden shrink-0")
	for pk, i in hits {
		package_row(ui, st, pk, i, "search")
	}
	p.end(ui)
}

// package_row is one line of a list: tile, name and summary, version, size,
// and the primary action.
package_row :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package, i: int, where_: string) {
	p.key(ui, tfmt("%s:row:%s", where_, pk.name))
	idx := p.row(ui, "w-full h-[58] items-center gap-3 px-4 transition cursor-pointer")
	if i > 0 {
		p.apply(ui, "border-t border-border", idx)
	}
	p.apply(ui, p.is_hovered(ui, idx) ? "bg-accent/60" : "bg-card", idx)
	clicked := p.clickable(ui, idx)
	app_tile(ui, pk, 36, "rounded-lg")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, pk.name, "text-[13.5] font-semibold text-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, pk.category, "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.text(ui, pk.summary, "w-full text-[12] text-muted-foreground truncate")
	p.end(ui)
	cell(ui, 96, version_short(pk.installed != "" ? pk.installed : pk.version), "text-[12] text-muted-foreground")
	cell(ui, 76, human_size(pk.installed != "" ? pk.installed_size : pk.size), "text-[12] text-muted-foreground", true)
	p.row(ui, "w-[92] shrink-0 items-center justify-end")
	action := primary_action(ui, st, pk, where_)
	p.end(ui)
	p.end(ui)
	if clicked && !action {
		open_package(st, pk.name)
	}
}

cell :: proc(ui: ^p.Ctx, w: int, value, class: string, right := false) {
	p.row(ui, tfmt("w-[%d] shrink-0 items-center overflow-hidden %s", w, right ? "justify-end" : ""))
	p.text(ui, value, tfmt("%s whitespace-nowrap", class))
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Installed
// ---------------------------------------------------------------------------

installed_view :: proc(ui: ^p.Ctx, st: ^State) {
	scroll_body(ui, "installed")
	defer scroll_end(ui)

	mine := installed(&st.cat, true)
	all := installed(&st.cat, false)
	total: i64 = 0
	for pk in all {total += pk.installed_size}
	p.row(ui, "w-full items-end gap-4 shrink-0")
	view_header(ui, "Installed", tfmt("%d packages using %s · %d installed by you, %d as dependencies", len(all), human_size(total), len(mine), len(all) - len(mine)), true)
	segmented(ui, st)
	p.end(ui)

	list := st.installed_all ? all : mine
	if len(list) == 0 {
		p.col(ui, "w-full items-center gap-2 py-10 shrink-0")
		p.text(ui, "Nothing installed by you yet", "text-[14] font-semibold text-foreground")
		p.text(ui, "Everything here came with the system. Packages you install from Discover appear in this list.", "text-[12.5] text-muted-foreground")
		p.end(ui)
		return
	}

	p.col(ui, "w-full rounded-xl border border-border overflow-hidden shrink-0")
	p.row(ui, "w-full h-[30] items-center gap-3 px-4 bg-muted/50 border-b border-border")
	p.text(ui, "Package", "flex-1 text-[11.5] font-medium text-muted-foreground")
	cell(ui, 132, "Installed", "text-[11.5] font-medium text-muted-foreground")
	cell(ui, 84, "Version", "text-[11.5] font-medium text-muted-foreground")
	cell(ui, 72, "Size", "text-[11.5] font-medium text-muted-foreground", true)
	p.div(ui, "w-[92] shrink-0")
	p.end(ui)
	p.end(ui)
	for pk, i in list {
		installed_row(ui, st, pk, i)
	}
	p.end(ui)
}

segmented :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "shrink-0 items-center gap-0.5 p-0.5 rounded-lg bg-muted border border-border")
	defer p.end(ui)
	seg :: proc(ui: ^p.Ctx, st: ^State, label: string, all: bool) {
		p.key(ui, tfmt("seg:%s", label))
		on := st.installed_all == all
		idx := p.div(ui, "flex-row h-6 px-2.5 items-center justify-center rounded-md transition cursor-pointer")
		p.apply(ui, on ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground", idx)
		if p.clickable(ui, idx) {
			st.installed_all = all
		}
		p.text(ui, label, "text-[12] font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}
	seg(ui, st, "Installed by you", false)
	seg(ui, st, "Everything", true)
}

installed_row :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package, i: int) {
	p.key(ui, tfmt("inst:row:%s", pk.name))
	idx := p.row(ui, "w-full h-[54] items-center gap-3 px-4 transition cursor-pointer")
	if i > 0 {
		p.apply(ui, "border-t border-border", idx)
	}
	p.apply(ui, p.is_hovered(ui, idx) ? "bg-accent/60" : "bg-card", idx)
	clicked := p.clickable(ui, idx)
	app_tile(ui, pk, 32, "rounded-lg")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, pk.name, "text-[13.5] font-semibold text-foreground truncate")
	p.text(ui, pk.summary, "w-full text-[12] text-muted-foreground truncate")
	p.end(ui)
	p.row(ui, "w-[132] shrink-0 items-center overflow-hidden")
	if pk.explicit {
		sc.badge_icon(ui, "By you", ICON_USER, .Secondary)
	} else if len(pk.required_by) > 0 {
		p.text(ui, tfmt("for %s", strings.join(pk.required_by, ", ", context.temp_allocator)), "text-[12] text-muted-foreground truncate")
	} else {
		p.text(ui, "dependency", "text-[12] text-muted-foreground")
	}
	p.end(ui)
	cell(ui, 84, version_short(pk.installed), "text-[12] text-muted-foreground")
	cell(ui, 72, pk.installed_size > 0 ? human_size(pk.installed_size) : "—", "text-[12] text-muted-foreground", true)
	p.row(ui, "w-[92] shrink-0 items-center justify-end")
	acted := false
	if removable(pk) {
		if button(ui, tfmt("inst:remove:%s", pk.name), "Remove", ICON_TRASH, .Ghost, .XS) {
			start_change(st, .Del, pk.name)
			acted = true
		}
	}
	p.end(ui)
	p.end(ui)
	if clicked && !acted {
		open_package(st, pk.name)
	}
}

// ---------------------------------------------------------------------------
// Updates
// ---------------------------------------------------------------------------

updates_view :: proc(ui: ^p.Ctx, st: ^State) {
	ups := upgradable(&st.cat)
	scroll_body(ui, "updates")
	defer scroll_end(ui)

	p.row(ui, "w-full items-end gap-3 shrink-0")
	dl: i64 = 0
	for pk in ups {dl += pk.csize}
	sub := len(ups) == 0 ? "Compared against the repository index palm last fetched." : tfmt("%d %s · download %s", len(ups), len(ups) == 1 ? "update" : "updates", human_size(dl))
	view_header(ui, "Updates", sub, true)
	if button(ui, "check", "Check for updates", ICON_REFRESH_CW, .Outline, .SM) {
		start_change(st, .Update)
	}
	if len(ups) > 0 {
		if button(ui, "update-all", "Update all", ICON_DOWNLOAD, .Default, .SM) {
			start_change(st, .Upgrade)
		}
	}
	p.end(ui)

	if len(ups) == 0 {
		p.col(ui, "w-full items-center gap-3 py-16 shrink-0")
		p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-emerald-500/15 shrink-0")
		p.icon(ui, ICON_CIRCLE_CHECK, "size-6 text-emerald-600")
		p.end(ui)
		p.text(ui, "Everything is up to date", "text-[14] font-semibold text-foreground")
		p.text(ui, "Check for updates fetches the newest index from the repository.", "text-[12.5] text-muted-foreground")
		p.end(ui)
		return
	}

	p.col(ui, "w-full rounded-xl border border-border overflow-hidden shrink-0")
	for pk, i in ups {
		p.key(ui, tfmt("up:row:%s", pk.name))
		idx := p.row(ui, "w-full h-[58] items-center gap-3 px-4 transition cursor-pointer")
		if i > 0 {p.apply(ui, "border-t border-border", idx)}
		p.apply(ui, p.is_hovered(ui, idx) ? "bg-accent/60" : "bg-card", idx)
		if p.clickable(ui, idx) {
			open_package(st, pk.name)
		}
		app_tile(ui, pk, 36, "rounded-lg")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, pk.name, "text-[13.5] font-semibold text-foreground truncate")
		p.text(ui, pk.summary, "w-full text-[12] text-muted-foreground truncate")
		p.end(ui)
		p.row(ui, "shrink-0 items-center gap-1.5")
		p.text(ui, version_short(pk.installed), "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.icon(ui, ICON_ARROW_RIGHT, "size-3 text-muted-foreground")
		p.text(ui, version_short(pk.version), "text-[12] font-semibold text-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
		cell(ui, 84, human_size(pk.csize), "text-[12] text-muted-foreground", true)
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// A package's page
// ---------------------------------------------------------------------------

package_view :: proc(ui: ^p.Ctx, st: ^State) {
	pk := find(&st.cat, st.nav.pkg)
	if pk == nil {
		empty_state(ui, ICON_PACKAGE, "Not in the catalogue", tfmt("%s is neither installed nor in any repository palm knows.", st.nav.pkg))
		return
	}
	scroll_body(ui, tfmt("pkg:%s", pk.name))
	defer scroll_end(ui)

	// The head: tile, name, summary, and what can be done.
	p.row(ui, "w-full items-center gap-5 shrink-0")
	app_tile(ui, pk, 76, "rounded-2xl")
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	p.text(ui, pk.name, "text-[24] font-semibold text-foreground tracking-tight truncate")
	p.text(ui, pk.summary, "w-full text-[13.5] text-muted-foreground")
	p.row(ui, "items-center gap-1.5 pt-0.5")
	sc.badge_icon(ui, pk.category != "" ? pk.category : "Uncategorised", category_icon(pk.category), .Secondary)
	if pk.installed != "" {
		sc.badge_icon(ui, pk.explicit ? "Installed by you" : "Installed", ICON_CHECK, .Outline)
	}
	if pk.upgradable {
		sc.badge_icon(ui, tfmt("Update to %s", version_short(pk.version)), ICON_DOWNLOAD, .Default)
	}
	p.end(ui)
	p.end(ui)
	p.row(ui, "shrink-0 items-center gap-2")
	if pk.installed == "" {
		if button(ui, "page:install", "Install", ICON_DOWNLOAD, .Default, .Default) {
			start_change(st, .Add, pk.name)
		}
	} else {
		if pk.upgradable {
			if button(ui, "page:update", "Update", ICON_REFRESH_CW, .Default, .Default) {
				start_change(st, .Upgrade)
			}
		}
		if button(ui, "page:remove", "Remove", ICON_TRASH, .Destructive, .Default, !removable(pk)) {
			start_change(st, .Del, pk.name)
		}
		if command_of(pk) != "" {
			if button(ui, "page:open", "Open", ICON_EXTERNAL_LINK, .Outline, .Default) {
				open_app(st, pk)
			}
		}
	}
	p.end(ui)
	p.end(ui)

	if protected(pk) {
		p.row(ui, "w-full items-center gap-2.5 px-3.5 py-2.5 rounded-lg bg-muted/60 border border-border shrink-0")
		p.icon(ui, ICON_SHIELD_CHECK, "size-4 shrink-0 text-muted-foreground")
		p.text(ui, "This is the system itself. Software will not remove it; palm del on a root console will, if you mean it.", "flex-1 text-[12.5] text-muted-foreground")
		p.end(ui)
	} else if pk.installed != "" && !pk.explicit && len(pk.required_by) > 0 {
		p.row(ui, "w-full items-center gap-2.5 px-3.5 py-2.5 rounded-lg bg-muted/60 border border-border shrink-0")
		p.icon(ui, ICON_INFO, "size-4 shrink-0 text-muted-foreground")
		p.text(ui, tfmt("Installed because %s %s it. Remove %s to remove this too.", strings.join(pk.required_by, ", ", context.temp_allocator), len(pk.required_by) == 1 ? "needs" : "need", len(pk.required_by) == 1 ? "that" : "those"), "flex-1 text-[12.5] text-muted-foreground")
		p.end(ui)
	}

	sc.separator(ui, .Horizontal, "shrink-0")

	p.row(ui, "w-full items-start gap-8 shrink-0")
	// Left: what it is, and what it puts on the disk.
	p.col(ui, "flex-1 min-w-0 gap-6")
	p.col(ui, "w-full gap-2.5")
	p.text(ui, "About", "text-[15] font-semibold text-foreground")
	details := pk.details != "" ? pk.details : pk.summary
	for para in strings.split_lines(details, context.temp_allocator) {
		if strings.trim_space(para) == "" {continue}
		p.text(ui, para, "w-full text-[13] text-foreground/85 leading-[20]")
	}
	p.end(ui)
	files_section(ui, st, pk)
	p.end(ui)

	// Right: the facts, as palm records them.
	p.col(ui, "w-[300] shrink-0 gap-0 rounded-xl border border-border bg-card px-4 py-2")
	fact(ui, "Version", version_short(pk.version), pk.version)
	if pk.installed != "" && pk.installed != pk.version {
		fact(ui, "Installed", version_short(pk.installed), pk.installed)
	}
	size := pk.installed != "" ? pk.installed_size : pk.size
	fact(ui, "Size", size > 0 ? human_size(size) : "no files of its own", "")
	if pk.csize > 0 {
		fact(ui, "Download", human_size(pk.csize), "")
	}
	fact(ui, "Licence", pk.license != "" ? pk.license : "not stated", "")
	if pk.url != "" {
		fact(ui, "Website", pk.url, "")
	}
	chips(ui, st, "Depends on", pk.depends, "dep")
	rdeps := pk.required_by
	if pk.installed == "" {
		rdeps = nil
	}
	chips(ui, st, "Required by", rdeps, "rdep")
	p.end(ui)
	p.end(ui)
}

// protected: the meta-package is the whole system. Removing it from a
// window would take the window, palmd and palm with it, so Software does not
// offer it; palm on the console still can.
PROTECTED := [?]string{"palmframe", "palmframe-base", "palm", "palmd", "glibc", "busybox", "linux", "palm-init", "palm-login"}

protected :: proc(pk: ^Package) -> bool {
	for n in PROTECTED {
		if n == pk.name {return true}
	}
	return false
}

// removable: installed, not the system, and not something an installed
// package still needs (palm would keep it, and the plan would be empty).
removable :: proc(pk: ^Package) -> bool {
	return pk.installed != "" && !protected(pk) && (pk.explicit || len(pk.required_by) == 0)
}

fact :: proc(ui: ^p.Ctx, label, value, aside: string) {
	p.row(ui, "w-full min-h-[34] items-center gap-3 border-b border-border/70")
	p.text(ui, label, "w-[86] shrink-0 text-[12] text-muted-foreground")
	p.text(ui, value, "flex-1 min-w-0 text-[12.5] text-foreground truncate")
	if aside != "" && aside != value {
		p.text(ui, aside, "text-[11.5] font-mono text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	p.end(ui)
}

// chips lists package names as links: a dependency is one click from its page.
chips :: proc(ui: ^p.Ctx, st: ^State, label: string, names: []string, key: string) {
	p.col(ui, "w-full gap-2 py-2.5")
	p.text(ui, label, "text-[12] text-muted-foreground")
	if len(names) == 0 {
		p.text(ui, "nothing", "text-[12.5] text-muted-foreground/70")
	} else {
		p.row(ui, "w-full flex-wrap gap-1.5")
		for n in names {
			name := dep_name(n)
			p.key(ui, tfmt("%s:%s", key, n))
			idx := p.row(ui, "h-6 items-center px-2 rounded-md border border-border bg-background transition cursor-pointer")
			known := find(&st.cat, name) != nil
			p.apply(ui, p.is_hovered(ui, idx) && known ? "bg-accent border-foreground/20" : "", idx)
			if p.clickable(ui, idx) && known {
				open_package(st, name)
			}
			p.text(ui, n, known ? "text-[12] font-mono text-foreground whitespace-nowrap" : "text-[12] font-mono text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)
}

files_section :: proc(ui: ^p.Ctx, st: ^State, pk: ^Package) {
	p.col(ui, "w-full gap-2.5")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, "Files", "text-[15] font-semibold text-foreground")
	if pk.files_loaded {
		p.text(ui, tfmt("%d", len(pk.files)), "text-[12] text-muted-foreground")
	}
	p.end(ui)
	switch {
	case st.files_error != "":
		p.text(ui, st.files_error, "w-full text-[12] font-mono text-destructive")
	case !pk.files_loaded:
		p.row(ui, "w-full items-center gap-3")
		p.text(ui, "palm reads the list from the package itself, which means downloading it.", "flex-1 text-[12.5] text-muted-foreground")
		if button(ui, "page:files", "Show files", ICON_FOLDER, .Outline, .XS) {
			if st.demo {
				demo_files(pk)
			} else if why := package_load_files(pk); why != "" {
				st.files_error = strings.clone(why)
			}
		}
		p.end(ui)
	case len(pk.files) == 0:
		p.text(ui, "This package installs no files of its own: it only pulls in others.", "text-[12.5] text-muted-foreground")
	case:
		p.col(ui, "w-full rounded-lg border border-border bg-muted/40 px-3 py-2 gap-1")
		SHOW :: 40
		for f, i in pk.files {
			if i >= SHOW {
				p.text(ui, tfmt("and %d more", len(pk.files) - SHOW), "text-[12] text-muted-foreground")
				break
			}
			p.text(ui, f, "w-full text-[12] font-mono text-foreground/85 truncate")
		}
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar, empty states, toast
// ---------------------------------------------------------------------------

status_bar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-2 px-3 bg-sidebar border-t border-border", STATUS_H))
	defer p.end(ui)
	inst := installed(&st.cat, false)
	p.text(ui, tfmt("%d packages · %d installed", len(st.cat.pkgs), len(inst)), "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	if st.cat.error != "" {
		p.text(ui, "·", "text-[11.5] text-muted-foreground/50")
		p.text(ui, st.cat.error, "truncate text-[11.5] text-destructive")
	}
	p.spacer(ui, "flex-1")
	p.text(ui, st.demo ? "demo data" : "palm --json · changes through palmd", "text-[11.5] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "w-full h-full items-center justify-center gap-3 px-10")
	defer p.end(ui)
	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-muted shrink-0")
	p.icon(ui, ic, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-[14] font-semibold text-foreground")
	p.text(ui, body, "max-w-[420] text-center text-[12.5] text-muted-foreground")
}

toast :: proc(ui: ^p.Ctx, st: ^State) {
	if st.toast == "" {
		return
	}
	if st.toast_at == 0 {
		st.toast_at = f64(p.elapsed(ui))
	}
	age := f64(p.elapsed(ui)) - st.toast_at
	if age > 2.6 {
		delete(st.toast)
		st.toast = ""
		st.toast_at = 0
		return
	}
	p.redraw(ui)
	idx := p.row(ui, "absolute z-30 right-[16] bottom-[40] max-w-[420] items-center gap-2 px-3 py-2 rounded-lg bg-popover border border-border shadow-lg")
	p.style(ui, idx).no_hit = true
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 text-selection")
	p.text(ui, st.toast, "truncate text-[12] text-foreground")
	p.end(ui)
}
