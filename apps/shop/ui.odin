// The interface.
//
// One window, five views, no popups — palmy has no xdg_popup, so everything
// that overlays is drawn inside the window as an absolutely positioned layer.
//
// The result list is virtualised: only the rows inside the viewport are built,
// so a frame costs the same over six thousand products as over sixty. That is
// the claim the frame-time bench in uitest.odin measures.
//
// The footer says, on every view, that the catalogue is generated. Nobody
// should be able to mistake these for live prices.
package main

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

TOPBAR_H :: 56
STATUS_H :: 30
SIDEBAR_W :: 236
DETAIL_W :: 372
ROW_H :: 56

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	topbar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0")
	switch st.view {
	case .Catalogue:
		sidebar(ui, st)
		results(ui, st)
		detail(ui, st)
	case .Compare:
		sidebar(ui, st)
		compare_view(ui, st)
	case .Basket:
		basket_view(ui, st)
	case .List:
		list_view(ui, st)
	case .Prices:
		sidebar(ui, st)
		prices_view(ui, st)
	case .Import:
		import_view(ui, st)
	}
	p.end(ui)

	status(ui, st)

	if st.help_open {
		help_overlay(ui, st)
	}
	// The file dialog is a sibling of everything else, at the top level.
	pick_overlay(ui, st)
	if st.toast != "" && st.now - st.toast_at < 2.6 {
		toast_layer(ui, st)
	}
}

// measure works out how many rows fit before anything is drawn, because the
// keyboard and the wheel both need it.
measure :: proc(ui: ^p.Ctx, st: ^State) {
	win := p.size(ui)
	body := win.y - TOPBAR_H - STATUS_H
	st.rows = max(1, int((body - 44) / ROW_H))
	st.top = clamp(st.top, 0, max(0, len(st.vis) - st.rows))
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

@(private = "file")
topbar :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border bg-card")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 w-[200] shrink-0")
	p.icon(ui, kit.ICON_PACKAGE, "size-5 text-primary")
	p.col(ui, "gap-0")
	p.text(ui, "Comparateur", "text-sm font-semibold")
	p.text(ui, "France · 6 enseignes", "text-[10] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	// Search. The field owns the keyboard while it has focus, and `/` puts it
	// there from anywhere.
	field := p.row(ui, "flex-1 min-w-0 items-center gap-2 h-9 px-3 rounded-md border border-input bg-background")
	if st.searching {
		p.apply(ui, "ring-3 ring-ring/50 border-ring")
	}
	p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground shrink-0")
	// The field's element id is remembered so that `/` can put the keyboard
	// into it from anywhere, which is the one bit of focus this app drives
	// itself.
	at := p.node_count(ui)
	changed, _ := p.text_field(
		ui,
		&st.query,
		"Rechercher un produit, une marque, un rayon…   (/)",
		"flex-1 min-w-0 h-7 bg-transparent border-0 px-0 text-sm",
	)
	st.search_id = p.node_id(ui, at)
	if st.want_focus_search {
		p.set_focus(ui, st.search_id)
		st.want_focus_search = false
	}
	st.searching = p.focus_id(ui) == st.search_id
	if changed {
		refilter(st)
		st.sel = 0
		st.top = 0
	}
	if len(st.query) > 0 {
		clear_btn := p.div(ui, "size-5 rounded-sm items-center justify-center hover:bg-accent cursor-pointer")
		p.icon(ui, sc.ICON_X, "size-3.5 text-muted-foreground")
		if p.clickable(ui, clear_btn) {
			clear(&st.query)
			refilter(st)
		}
		p.end(ui)
	}
	_ = field
	p.end(ui)

	// Views.
	p.row(ui, "items-center gap-1 shrink-0 p-1 rounded-lg bg-muted")
	for v in View {
		if v == .Import {
			continue
		}
		label := view_label(v)
		idx := p.row(ui, "items-center gap-1.5 h-7 px-2.5 shrink-0 rounded-md cursor-pointer hover:bg-background/60 transition")
		if st.view == v {
			p.apply(ui, "bg-background shadow-sm")
		}
		p.text(ui, label, st.view == v ? "text-xs font-semibold whitespace-nowrap" : "text-xs text-muted-foreground whitespace-nowrap")
		switch v {
		case .Basket:
			if n := len(st.basket); n > 0 {
				count_chip(ui, n, "bg-primary text-primary-foreground")
			}
		case .List:
			if n := len(st.list); n > 0 {
				count_chip(ui, n, "bg-secondary text-secondary-foreground")
			}
		case .Prices:
			if n := alerts_firing(st); n > 0 {
				count_chip(ui, n, "bg-[#e63e11] text-white")
			}
		case .Catalogue, .Compare, .Import:
		}
		if p.clickable(ui, idx) {
			set_view(st, v)
		}
		p.end(ui)
	}
	p.end(ui)

	help := p.div(ui, "size-8 rounded-md items-center justify-center hover:bg-accent cursor-pointer shrink-0")
	p.icon(ui, kit.ICON_INFO, "size-4 text-muted-foreground")
	if p.clickable(ui, help) {
		st.help_open = !st.help_open
	}
	p.end(ui)
}

@(private = "file")
count_chip :: proc(ui: ^p.Ctx, n: int, class: string) {
	p.div(ui, p.concat(ui, "h-4 min-w-[16] px-1 rounded-full items-center justify-center ", class))
	p.textf(ui, "text-[10] font-semibold tabular-nums", "%d", n)
	p.end(ui)
}

set_view :: proc(st: ^State, v: View) {
	st.view = v
	if v == .Compare && st.compare_of < 0 {
		st.compare_of = selected_product(st)
	}
}

// ---------------------------------------------------------------------------
// Sidebar: the facets
// ---------------------------------------------------------------------------

@(private = "file")
sidebar :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-[236] shrink-0 h-full min-h-0 border-r border-border bg-card/40 overflow-scroll")
	defer p.end(ui)

	p.col(ui, "w-full p-3 gap-3")
	defer p.end(ui)

	// Department.
	facet_label(ui, "Rayon")
	p.row(ui, "w-full gap-1 p-1 rounded-md bg-muted")
	for d in Dept_Filter {
		name := d == .All ? "Tout" : (d == .Grocery ? "Courses" : "Mode")
		b := p.div(ui, "flex-1 h-7 items-center justify-center rounded-sm cursor-pointer hover:bg-background/60")
		if st.filter.dept == d {
			p.apply(ui, "bg-background shadow-sm")
		}
		p.text(ui, name, st.filter.dept == d ? "text-xs font-medium" : "text-xs text-muted-foreground")
		if p.clickable(ui, b) {
			st.filter.dept = d
			refilter(st)
		}
		p.end(ui)
	}
	p.end(ui)

	// Retailers.
	facet_label(ui, "Enseignes")
	for r in Retailer {
		if r == .None {
			continue
		}
		on := st.filter.retailers[r]
		row := p.row(ui, "w-full items-center gap-2 h-8 px-2 rounded-md cursor-pointer hover:bg-accent")
		if on {
			p.apply(ui, "bg-accent")
		}
		p.div(ui, p.concat(ui, "size-4 rounded-sm items-center justify-center ", on ? retailer_class(r) : "border border-input"))
		if on {
			p.icon(ui, sc.ICON_CHECK, "size-3")
		}
		p.end(ui)
		p.text(ui, retailer_name(r), "text-xs flex-1 min-w-0 truncate")
		n := 0
		for i in st.vis {
			if st.cat.products[i].retailer == r {
				n += 1
			}
		}
		p.textf(ui, "text-[10] text-muted-foreground tabular-nums", "%d", n)
		if p.clickable(ui, row) {
			st.filter.retailers[r] = !on
			refilter(st)
		}
		p.end(ui)
	}

	// Aisles.
	facet_label(ui, "Rayons du magasin")
	aisle_chip(ui, st, .None, "Tous les rayons")
	for a in Aisle {
		if a == .None {
			continue
		}
		aisle_chip(ui, st, a, aisle_name(a))
	}

	// Nutri-Score ceiling.
	facet_label(ui, "Nutri-Score au maximum")
	p.row(ui, "w-full gap-1")
	for g in ([?]Nutri{.None, .A, .B, .C, .D, .E}) {
		on := st.filter.nutri_max == g
		b := p.div(ui, "flex-1 h-7 items-center justify-center rounded-md cursor-pointer border border-border")
		if g == .None {
			p.apply(ui, on ? "bg-foreground text-background" : "hover:bg-accent")
			p.text(ui, "—", "text-xs font-semibold")
		} else {
			p.apply(ui, nutri_class(g))
			if !on {
				p.apply(ui, "opacity-40")
			}
			p.text(ui, nutri_letter(g), "text-xs font-bold")
		}
		if p.clickable(ui, b) {
			st.filter.nutri_max = g
			refilter(st)
		}
		p.end(ui)
	}
	p.end(ui)

	// Price ceiling.
	facet_label(ui, "Prix maximum")
	p.row(ui, "w-full gap-1 flex-wrap")
	for cap in ([?]Centimes{0, 100, 200, 500, 1000, 3000}) {
		on := st.filter.price_max == cap
		b := p.div(ui, "h-7 px-2 items-center justify-center rounded-md border border-border cursor-pointer hover:bg-accent")
		if on {
			p.apply(ui, "bg-foreground text-background border-foreground")
		}
		p.text(ui, cap == 0 ? "Tous" : fmt_money(cap, context.temp_allocator), "text-[11] tabular-nums")
		if p.clickable(ui, b) {
			st.filter.price_max = cap
			refilter(st)
		}
		p.end(ui)
	}
	p.end(ui)

	// My size, across every chain's own labelling.
	facet_label(ui, "Ma taille")
	p.row(ui, "w-full gap-1")
	for s in ([?]Size_System{.FR, .EU, .UK, .US, .Alpha}) {
		on := st.filter.size_system == s
		b := p.div(ui, "flex-1 h-6 items-center justify-center rounded-sm cursor-pointer border border-border hover:bg-accent")
		if on {
			p.apply(ui, "bg-foreground text-background border-foreground")
		}
		p.text(ui, size_system_label(s), "text-[10]")
		if p.clickable(ui, b) {
			st.filter.size_system = s
			refilter(st)
		}
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "w-full gap-1")
	for c in ([?]Size_Chart{.Women_Tops, .Men_Tops, .Kids}) {
		on := st.filter.size_chart == c
		label := c == .Women_Tops ? "Femme" : (c == .Men_Tops ? "Homme" : "Enfant")
		b := p.div(ui, "flex-1 h-6 items-center justify-center rounded-sm cursor-pointer border border-border hover:bg-accent")
		if on {
			p.apply(ui, "bg-foreground text-background border-foreground")
		}
		p.text(ui, label, "text-[10]")
		if p.clickable(ui, b) {
			st.filter.size_chart = on ? .None : c
			refilter(st)
		}
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "w-full gap-1 flex-wrap")
	chart := st.filter.size_chart == .None ? Size_Chart.Women_Tops : st.filter.size_chart
	for row in size_rows(chart) {
		label := size_cell(row, st.filter.size_system)
		if label == "" {
			continue
		}
		on := st.filter.size_label == label
		b := p.div(ui, "h-7 min-w-[34] px-1.5 items-center justify-center rounded-md border border-border cursor-pointer hover:bg-accent")
		if on {
			p.apply(ui, "bg-primary text-primary-foreground border-primary")
		}
		p.text(ui, label, "text-[11] tabular-nums")
		if p.clickable(ui, b) {
			delete(st.filter.size_label)
			st.filter.size_label = on ? "" : strings.clone(label)
			if !on && st.filter.size_chart == .None {
				st.filter.size_chart = chart
			}
			refilter(st)
			save_state(st)
		}
		p.end(ui)
	}
	p.end(ui)

	// Two switches.
	facet_toggle(ui, st, &st.filter.in_stock, "En stock seulement")
	facet_toggle(ui, st, &st.filter.promo_only, "En promotion")

	if filter_any(st.filter) || len(st.query) > 0 {
		b := p.row(ui, "w-full h-8 mt-1 items-center justify-center gap-1.5 rounded-md border border-border cursor-pointer hover:bg-accent")
		p.icon(ui, sc.ICON_X, "size-3.5")
		p.text(ui, "Effacer les filtres", "text-xs")
		if p.clickable(ui, b) {
			reset_filters(st)
		}
		p.end(ui)
	}
}

reset_filters :: proc(st: ^State) {
	delete(st.filter.size_label)
	f := Filter{}
	f.size_system = st.filter.size_system
	st.filter = f
	clear(&st.query)
	refilter(st)
}

@(private = "file")
facet_label :: proc(ui: ^p.Ctx, s: string) {
	p.text(ui, s, "w-full text-[10] font-semibold uppercase tracking-wide text-muted-foreground mt-1")
}

@(private = "file")
aisle_chip :: proc(ui: ^p.Ctx, st: ^State, a: Aisle, label: string) {
	on := st.filter.aisle == a
	row := p.row(ui, "w-full items-center h-7 px-2 rounded-md cursor-pointer hover:bg-accent")
	if on {
		p.apply(ui, "bg-primary/10 text-primary")
	}
	p.text(ui, label, on ? "text-xs font-medium flex-1 truncate" : "text-xs flex-1 truncate")
	if p.clickable(ui, row) {
		st.filter.aisle = on ? .None : a
		refilter(st)
	}
	p.end(ui)
}

@(private = "file")
facet_toggle :: proc(ui: ^p.Ctx, st: ^State, value: ^bool, label: string) {
	row := p.row(ui, "w-full items-center gap-2 h-8 px-2 rounded-md cursor-pointer hover:bg-accent")
	p.div(ui, p.concat(ui, "w-8 h-4.5 rounded-full shrink-0 justify-center ", value^ ? "bg-primary" : "bg-input"))
	p.div(ui, p.concat(ui, "size-3.5 rounded-full bg-background ", value^ ? "ml-auto mr-0.5" : "ml-0.5"))
	p.end(ui)
	p.end(ui)
	p.text(ui, label, "text-xs flex-1")
	if p.clickable(ui, row) {
		value^ = !value^
		refilter(st)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The result list
// ---------------------------------------------------------------------------

@(private = "file")
results :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0")
	defer p.end(ui)

	// The header doubles as the sort control.
	p.row(ui, "w-full h-[44] shrink-0 items-center gap-2 px-4 border-b border-border bg-card/60")
	p.textf(ui, "text-xs text-muted-foreground tabular-nums shrink-0 whitespace-nowrap", "%d résultats", len(st.vis))
	p.spacer(ui, "flex-1")
	p.text(ui, "Trier par", "text-[10] text-muted-foreground shrink-0")
	for s in ([?]Sort_Key{.Relevance, .Price_Up, .Unit_Up, .Discount, .Nutri}) {
		on := st.sort == s
		short := ""
		switch s {
		case .Relevance:
			short = "Pertinence"
		case .Price_Up:
			short = "Prix"
		case .Unit_Up:
			short = "Prix au kilo"
		case .Discount:
			short = "Promos"
		case .Nutri:
			short = "Nutri-Score"
		case .Price_Down, .Unit_Down, .Name:
		}
		b := p.div(ui, "h-7 px-2.5 items-center justify-center rounded-md cursor-pointer hover:bg-accent")
		if on {
			p.apply(ui, "bg-foreground text-background")
		}
		p.text(ui, short, "text-[11]")
		if p.clickable(ui, b) {
			st.sort = s
			refilter(st)
			save_state(st)
		}
		p.end(ui)
	}
	p.end(ui)

	if len(st.vis) == 0 {
		p.col(ui, "w-full flex-1 items-center justify-center gap-2")
		p.icon(ui, sc.ICON_SEARCH, "size-8 text-muted-foreground/40")
		p.text(ui, "Aucun produit ne correspond", "text-sm font-medium")
		p.text(ui, "Essayez un autre mot, ou effacez un filtre.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}

	// Virtualised: only the rows in view are built.
	list := p.col(ui, "w-full flex-1 min-h-0 overflow-hidden")
	last := min(st.top + st.rows + 1, len(st.vis))
	for row in st.top ..< last {
		product_row(ui, st, row)
	}
	p.spacer(ui, "flex-1")
	_ = list
	p.end(ui)
}

@(private = "file")
product_row :: proc(ui: ^p.Ctx, st: ^State, row: int) {
	idx := st.vis[row]
	pr := &st.cat.products[idx]
	sel := row == st.sel

	p.key(ui, pr.id)
	r := p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border/50 cursor-pointer hover:bg-accent/50 transition")
	if sel {
		p.apply(ui, "bg-accent")
	}
	defer p.end(ui)

	// The chain.
	p.div(ui, p.concat(ui, "w-[72] h-5 shrink-0 rounded-sm items-center justify-center ", retailer_class(pr.retailer)))
	p.text(ui, retailer_name(pr.retailer), "text-[10] font-semibold truncate")
	p.end(ui)

	// Title and the line under it.
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "items-center gap-2 min-w-0")
	p.text(ui, pr.title, "text-[13] font-medium truncate")
	if pr.avail != .In_Stock {
		p.div(ui, "h-4 px-1.5 rounded-sm bg-muted items-center justify-center shrink-0")
		p.text(ui, avail_label(pr.avail), "text-[9] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.row(ui, "items-center gap-1.5 min-w-0")
	brand := pr.brand == "" ? "Marque distributeur" : pr.brand
	p.text(ui, brand, "text-[11] text-muted-foreground shrink-0")
	if pr.qty.ok {
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.text(ui, fmt_quantity(pr.qty, context.temp_allocator), "text-[11] text-muted-foreground tabular-nums")
	}
	if pr.color != "" {
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.text(ui, pr.color, "text-[11] text-muted-foreground")
	}
	if len(pr.sizes) > 0 {
		p.text(ui, "·", "text-[11] text-muted-foreground/50")
		p.textf(
			ui,
			"text-[11] text-muted-foreground",
			"%s %s–%s",
			size_system_label(pr.size_system),
			pr.sizes[0],
			pr.sizes[len(pr.sizes) - 1],
		)
	}
	p.end(ui)
	p.end(ui)

	// Nutri-Score.
	if pr.nutri.grade != .None {
		p.div(ui, p.concat(ui, "size-6 shrink-0 rounded-sm items-center justify-center ", nutri_class(pr.nutri.grade)))
		p.text(ui, nutri_letter(pr.nutri.grade), "text-[11] font-bold")
		p.end(ui)
	} else {
		p.div(ui, "size-6 shrink-0")
		p.end(ui)
	}

	// The unit price, which is the honest column.
	p.col(ui, "w-[104] shrink-0 items-end gap-0")
	if pr.has_unit {
		p.text(ui, fmt_unit_price(pr.price, pr.qty, context.temp_allocator), "text-[12] font-medium tabular-nums")
		p.text(ui, unit_caption(pr.qty.kind), "text-[9] text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)

	// The price.
	p.col(ui, "w-[92] shrink-0 items-end gap-0")
	p.text(ui, fmt_money(pr.price, context.temp_allocator), "text-[14] font-semibold tabular-nums")
	if on_promo(pr^) {
		p.row(ui, "items-center gap-1")
		p.text(ui, fmt_money(pr.list_price, context.temp_allocator), "text-[10] line-through text-muted-foreground tabular-nums")
		p.div(ui, "h-3.5 px-1 rounded-sm bg-[#e63e11] items-center justify-center")
		p.textf(ui, "text-[9] font-bold text-white tabular-nums", "-%d%%", discount_tenths(pr^) / 10)
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)

	// Add to the basket, without leaving the row.
	add := p.div(ui, "size-7 shrink-0 rounded-md items-center justify-center border border-border hover:bg-primary hover:text-primary-foreground cursor-pointer")
	p.icon(ui, sc.ICON_PLUS, "size-3.5")
	if p.clickable(ui, add) {
		basket_add(st, idx)
		toast(st, fmt.tprintf("Ajouté au panier: %s", pr.title))
	}
	p.end(ui)

	if p.clickable(ui, r) {
		st.sel = row
		st.compare_of = idx
	}
}

// ---------------------------------------------------------------------------
// The detail pane
// ---------------------------------------------------------------------------

@(private = "file")
detail :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "w-[372] shrink-0 h-full min-h-0 border-l border-border bg-card/40 overflow-scroll")
	defer p.end(ui)

	idx := selected_product(st)
	if idx < 0 {
		p.col(ui, "w-full p-6 items-center justify-center gap-2")
		p.text(ui, "Aucun produit sélectionné", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	pr := &st.cat.products[idx]

	p.col(ui, "w-full p-4 gap-4")
	defer p.end(ui)

	// Heading.
	p.col(ui, "w-full gap-1.5")
	p.row(ui, "items-center gap-2")
	p.div(ui, p.concat(ui, "h-5 px-2 rounded-sm items-center justify-center ", retailer_class(pr.retailer)))
	p.text(ui, retailer_name(pr.retailer), "text-[10] font-semibold")
	p.end(ui)
	if pr.gtin != "" {
		p.text(ui, pr.gtin, "text-[10] font-mono text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, "sans code-barres", "text-[10] text-muted-foreground whitespace-nowrap")
	}
	p.end(ui)
	p.text(ui, pr.title, "text-base font-semibold")
	p.text(ui, pr.brand == "" ? "Marque distributeur" : pr.brand, "text-xs text-muted-foreground")
	p.end(ui)

	// Price, unit price, TVA.
	p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
	p.row(ui, "w-full items-end gap-2")
	p.text(ui, fmt_money(pr.price, context.temp_allocator), "text-2xl font-bold tabular-nums")
	if on_promo(pr^) {
		p.text(ui, fmt_money(pr.list_price, context.temp_allocator), "text-xs line-through text-muted-foreground tabular-nums mb-1")
		p.div(ui, "h-5 px-1.5 rounded-sm bg-[#e63e11] items-center justify-center mb-1")
		p.text(ui, fmt_pct(-discount_tenths(pr^), context.temp_allocator), "text-[10] font-bold text-white tabular-nums whitespace-nowrap")
		p.end(ui)
	}
	p.spacer(ui, "flex-1")
	p.text(ui, "TTC", "text-[10] text-muted-foreground mb-1")
	p.end(ui)

	if pr.has_unit {
		p.row(ui, "w-full items-center gap-2 py-1.5 px-2 rounded-md bg-primary/10")
		p.text(ui, fmt_unit_price(pr.price, pr.qty, context.temp_allocator), "text-sm font-semibold text-primary tabular-nums")
		p.text(ui, unit_caption(pr.qty.kind), "text-[10] text-primary/70 whitespace-nowrap")
		p.spacer(ui, "flex-1")
		p.text(ui, fmt_quantity(pr.qty, context.temp_allocator), "text-[11] tabular-nums text-muted-foreground")
		p.end(ui)
	}

	// HT / TVA / TTC, which is the breakdown the law puts on a receipt.
	p.divider(ui, "w-full h-px bg-border my-1")
	kv(ui, "Prix HT", fmt_money(price_ht(pr.price, pr.tva), context.temp_allocator))
	kv(ui, fmt.tprintf("TVA %s", tva_label(pr.tva)), fmt_money(price_tva(pr.price, pr.tva), context.temp_allocator))
	kv(ui, "Prix TTC", fmt_money(pr.price, context.temp_allocator))
	if pr.shipping > 0 {
		kv(ui, "Livraison", fmt_money(pr.shipping, context.temp_allocator))
	}
	p.end(ui)

	// Nutri-Score, with the working shown.
	if pr.nutri.grade != .None {
		p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
		p.row(ui, "w-full items-center gap-2")
		p.text(ui, "Nutri-Score", "text-xs font-semibold")
		p.spacer(ui, "flex-1")
		for g in ([?]Nutri{.A, .B, .C, .D, .E}) {
			on := pr.nutri.grade == g
			p.div(ui, p.concat(ui, "size-6 rounded-sm items-center justify-center ", nutri_class(g)))
			if !on {
				p.apply(ui, "opacity-30")
			}
			p.text(ui, nutri_letter(g), on ? "text-[11] font-bold" : "text-[10]")
			p.end(ui)
		}
		p.end(ui)
		if pr.nutrition.known {
			n := pr.nutri
			p.row(ui, "w-full items-center gap-1 flex-wrap")
			pts(ui, "énergie", n.pts_energy, false)
			pts(ui, "sucres", n.pts_sugars, false)
			pts(ui, "AGS", n.pts_satfat, false)
			pts(ui, "sodium", n.pts_sodium, false)
			pts(ui, "fruits", n.pts_fruit, true)
			pts(ui, "fibres", n.pts_fibre, true)
			pts(ui, "protéines", n.pts_protein, true)
			p.end(ui)
			p.row(ui, "w-full items-center gap-2")
			p.textf(ui, "text-[10] text-muted-foreground tabular-nums whitespace-nowrap shrink-0", "N %d − P %d = %d", n.negative, n.positive, n.score)
			if !n.protein_counted && n.pts_protein > 0 {
				p.text(ui, "protéines non comptées", "text-[10] text-amber-600 whitespace-nowrap shrink-0")
			}
			p.spacer(ui, "flex-1")
			p.text(ui, food_class_label(pr.nutrition.class), "text-[10] text-muted-foreground whitespace-nowrap shrink-0")
			p.end(ui)
		} else {
			p.text(ui, "Note publiée par l'enseigne, non recalculée ici.", "text-[10] text-muted-foreground")
		}
		p.end(ui)
	}

	// Sizes in every system.
	if len(pr.sizes) > 0 {
		p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
		p.row(ui, "w-full items-center gap-2")
		p.text(ui, "Tailles", "text-xs font-semibold")
		p.spacer(ui, "flex-1")
		p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap", "annoncées en %s · %s", size_system_label(pr.size_system), size_chart_label(pr.chart))
		p.end(ui)
		p.row(ui, "w-full gap-1 flex-wrap")
		for s in pr.sizes {
			mine := st.filter.size_label != "" &&
			        size_matches(pr.chart, {s}, pr.size_system, st.filter.size_label, st.filter.size_system)
			p.div(ui, "h-6 min-w-[30] px-1.5 rounded-sm border border-border items-center justify-center")
			if mine {
				p.apply(ui, "bg-primary text-primary-foreground border-primary")
			}
			p.text(ui, s, "text-[11] tabular-nums")
			p.end(ui)
		}
		p.end(ui)
		// The conversion, for the size the shopper actually knows.
		if len(pr.sizes) > 0 {
			ref := pr.sizes[min(3, len(pr.sizes) - 1)]
			p.text(ui, size_all(pr.chart, ref, pr.size_system, context.temp_allocator), "text-[10] text-muted-foreground tabular-nums")
		}
		p.end(ui)
	}

	// Price history.
	p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, "Historique", "text-xs font-semibold")
	p.spacer(ui, "flex-1")
	ch := history_change(pr^)
	p.text(
		ui,
		fmt_pct(ch, context.temp_allocator),
		ch <= 0 ? "text-[11] font-medium text-emerald-600 tabular-nums" : "text-[11] font-medium text-destructive tabular-nums",
	)
	p.end(ui)
	sparkline(ui, st, pr^)
	p.row(ui, "w-full items-center gap-3")
	p.textf(ui, "text-[10] text-muted-foreground tabular-nums", "min %s", fmt_money(history_min(pr^), context.temp_allocator))
	p.textf(ui, "text-[10] text-muted-foreground tabular-nums", "max %s", fmt_money(history_max(pr^), context.temp_allocator))
	if at_lowest(pr^) {
		p.div(ui, "h-4 px-1.5 rounded-sm bg-emerald-600 items-center justify-center")
		p.text(ui, "au plus bas", "text-[9] font-semibold text-white")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	// Actions.
	p.row(ui, "w-full gap-2")
	if act(ui, "Panier", sc.ICON_PLUS, true) {
		basket_add(st, idx)
		toast(st, "Ajouté au panier")
	}
	if act(ui, "Liste", sc.ICON_CHECK, false) {
		list_add(st, idx)
		toast(st, "Ajouté à la liste de courses")
	}
	armed := alert_find(st, idx) >= 0
	if act(ui, armed ? "Alerte ✓" : "Alerte", sc.ICON_BELL, false) {
		if armed {
			alert_clear(st, idx)
			toast(st, "Alerte retirée")
		} else {
			alert_set(st, idx)
			toast(st, fmt.tprintf("Alerte sous %s", fmt_money(st.alerts[len(st.alerts) - 1].threshold, context.temp_allocator)))
		}
	}
	p.end(ui)

	p.row(ui, "w-full gap-2")
	if act(ui, "Comparer les enseignes", kit.ICON_LIST, false) {
		st.compare_of = idx
		st.view = .Compare
	}
	p.end(ui)
}

// act draws an action button and reports a click. Kept separate so the action
// rows all read the same.
@(private = "file")
act :: proc(ui: ^p.Ctx, label: string, ic: p.Icon, primary: bool) -> bool {
	b := p.row(ui, "flex-1 h-9 items-center justify-center gap-1.5 rounded-md cursor-pointer transition")
	p.apply(ui, primary ? "bg-primary text-primary-foreground hover:bg-primary/90" : "border border-border hover:bg-accent")
	p.icon(ui, ic, "size-3.5")
	p.text(ui, label, "text-xs font-medium")
	clicked := p.clickable(ui, b)
	p.end(ui)
	return clicked
}

@(private = "file")
kv :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "w-full items-center")
	p.text(ui, k, "text-[11] text-muted-foreground flex-1")
	p.text(ui, v, "text-[11] font-medium tabular-nums")
	p.end(ui)
}

@(private = "file")
pts :: proc(ui: ^p.Ctx, label: string, n: int, positive: bool) {
	p.row(ui, "items-center gap-1 h-5 px-1.5 rounded-sm bg-muted")
	p.text(ui, label, "text-[9] text-muted-foreground")
	p.textf(ui, positive ? "text-[9] font-bold text-emerald-600 tabular-nums" : "text-[9] font-bold text-destructive tabular-nums",
		positive ? "+%d" : "%d", n)
	p.end(ui)
}

// unit_caption names the unit a price is quoted in, because "prix au kilo"
// under a figure in euros per litre is wrong in a way a shopper notices.
unit_caption :: proc(k: Unit_Kind) -> string {
	switch k {
	case .Mass:
		return "prix au kilo"
	case .Volume:
		return "prix au litre"
	case .Count:
		return "prix à la pièce"
	case .None:
		return ""
	}
	return ""
}

unit_preposition :: proc(k: Unit_Kind) -> string {
	switch k {
	case .Mass:
		return "au kilo"
	case .Volume:
		return "au litre"
	case .Count:
		return "à la pièce"
	case .None:
		return ""
	}
	return ""
}

food_class_label :: proc(c: Food_Class) -> string {
	switch c {
	case .Solid:
		return "table générale"
	case .Beverage:
		return "table boissons"
	case .Water:
		return "eau — A par règle"
	case .Cheese:
		return "table fromages"
	case .Added_Fat:
		return "table matières grasses"
	}
	return ""
}

// sparkline draws the price history as bars. Twelve divs, not a canvas: it is
// a dozen rectangles and the layout engine already positions rectangles.
@(private = "file")
sparkline :: proc(ui: ^p.Ctx, st: ^State, pr: Product) {
	lo := history_min(pr)
	hi := history_max(pr)
	span := i64(hi - lo)
	if span <= 0 {
		span = 1
	}
	p.row(ui, "w-full h-[46] items-end gap-[3]")
	defer p.end(ui)
	for v, i in pr.history {
		h := 6 + int(i64(v - lo) * 36 / span)
		col := p.col(ui, p.concat(ui, "flex-1 items-center gap-0.5 justify-end"))
		p.div(ui, fmt.tprintf("w-full h-[%d] rounded-sm %s", h, i == HISTORY_LEN - 1 ? "bg-primary" : "bg-muted-foreground/30"))
		p.end(ui)
		if i % 3 == 0 || i == HISTORY_LEN - 1 {
			p.text(ui, st.cat.weeks[i], "text-[8] text-muted-foreground")
		} else {
			p.text(ui, "", "text-[8]")
		}
		_ = col
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Compare
// ---------------------------------------------------------------------------

@(private = "file")
compare_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 overflow-scroll")
	defer p.end(ui)

	idx := st.compare_of
	if idx < 0 {
		idx = selected_product(st)
	}
	if idx < 0 || idx >= len(st.cat.products) {
		p.col(ui, "w-full flex-1 items-center justify-center")
		p.text(ui, "Sélectionnez un produit dans le catalogue, puis Entrée.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	pr := st.cat.products[idx]
	g := group_of(&st.cat, idx, context.temp_allocator)

	p.col(ui, "w-full p-5 gap-4")
	defer p.end(ui)

	p.col(ui, "w-full gap-1")
	p.text(ui, pr.title, "text-lg font-semibold")
	p.row(ui, "items-center gap-2")
	p.textf(ui, "text-xs text-muted-foreground", "%d offres comparées", len(g))
	p.text(ui, "·", "text-xs text-muted-foreground/50")
	p.text(
		ui,
		pr.gtin != "" ? fmt.tprintf("appariées sur le code-barres %s", pr.gtin) : "appariées sur le titre normalisé, faute de code-barres",
		"text-xs text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	// The point of the view, stated: the cheapest sticker and the cheapest
	// kilo are not always the same offer.
	cheap_price := -1
	cheap_unit := -1
	for i in g {
		q := st.cat.products[i]
		if q.avail != .In_Stock {
			continue
		}
		if cheap_price < 0 || q.price < st.cat.products[cheap_price].price {
			cheap_price = i
		}
		if q.has_unit && (cheap_unit < 0 || q.unit < st.cat.products[cheap_unit].unit) {
			cheap_unit = i
		}
	}
	if cheap_unit >= 0 && cheap_price >= 0 && cheap_unit != cheap_price {
		p.row(ui, "w-full items-center gap-2 p-3 rounded-lg border border-primary/40 bg-primary/10")
		p.icon(ui, kit.ICON_INFO, "size-4 text-primary shrink-0")
		cu := st.cat.products[cheap_unit]
		cp := st.cat.products[cheap_price]
		p.textf(
			ui,
			"text-xs text-primary",
			"Le prix affiché le plus bas est %s chez %s, mais le moins cher %s est %s chez %s (%s).",
			fmt_money(cp.price, context.temp_allocator),
			retailer_name(cp.retailer),
			unit_preposition(cu.qty.kind),
			fmt_money(cu.price, context.temp_allocator),
			retailer_name(cu.retailer),
			fmt_unit_price(cu.price, cu.qty, context.temp_allocator),
		)
		p.end(ui)
	}

	// The table.
	p.col(ui, "w-full rounded-lg border border-border overflow-hidden")
	p.row(ui, "w-full h-9 items-center px-3 gap-3 bg-muted/60 border-b border-border")
	head(ui, "Enseigne", "w-[96]")
	head(ui, "Produit", "flex-1 min-w-0")
	head(ui, "Quantité", "w-[96]")
	head(ui, "Nutri", "w-[44]")
	head(ui, "Prix", "w-[88] items-end")
	head(ui, "Prix au kilo", "w-[104] items-end")
	head(ui, "", "w-[64]")
	p.end(ui)

	for i, n in g {
		q := &st.cat.products[i]
		p.key(ui, q.id)
		row := p.row(ui, "w-full h-[52] items-center px-3 gap-3 border-b border-border/50 hover:bg-accent/40 cursor-pointer")
		if n % 2 == 1 {
			p.apply(ui, "bg-muted/20")
		}
		if i == cheap_unit {
			p.apply(ui, "bg-emerald-500/10")
		}
		if i == idx {
			p.apply(ui, "ring-2 ring-ring/40")
		}

		p.div(ui, p.concat(ui, "w-[96] h-5 shrink-0 rounded-sm items-center justify-center ", retailer_class(q.retailer)))
		p.text(ui, retailer_name(q.retailer), "text-[10] font-semibold truncate")
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, q.title, "text-xs font-medium truncate")
		p.row(ui, "items-center gap-1.5")
		p.text(ui, q.brand == "" ? "Marque distributeur" : q.brand, "text-[10] text-muted-foreground")
		if q.avail != .In_Stock {
			p.text(ui, avail_label(q.avail), "text-[10] text-destructive")
		}
		if len(q.sizes) > 0 {
			p.textf(ui, "text-[10] text-muted-foreground", "· %s %s–%s", size_system_label(q.size_system), q.sizes[0], q.sizes[len(q.sizes) - 1])
		}
		p.end(ui)
		p.end(ui)

		p.text(ui, q.qty.ok ? fmt_quantity(q.qty, context.temp_allocator) : "—", "w-[96] text-[11] tabular-nums text-muted-foreground")

		p.div(ui, "w-[44] items-start")
		if q.nutri.grade != .None {
			p.div(ui, p.concat(ui, "size-5 rounded-sm items-center justify-center ", nutri_class(q.nutri.grade)))
			p.text(ui, nutri_letter(q.nutri.grade), "text-[10] font-bold")
			p.end(ui)
		}
		p.end(ui)

		p.col(ui, "w-[88] items-end gap-0")
		p.text(ui, fmt_money(q.price, context.temp_allocator), "text-xs font-semibold tabular-nums")
		if on_promo(q^) {
			p.text(ui, fmt_money(q.list_price, context.temp_allocator), "text-[9] line-through text-muted-foreground tabular-nums")
		}
		p.end(ui)

		p.col(ui, "w-[104] items-end gap-0")
		if q.has_unit {
			p.text(
				ui,
				fmt_unit_price(q.price, q.qty, context.temp_allocator),
				i == cheap_unit ? "text-xs font-bold text-emerald-700 tabular-nums" : "text-xs font-medium tabular-nums",
			)
			if i == cheap_unit {
				p.text(ui, p.concat(ui, "meilleur ", unit_preposition(q.qty.kind)), "text-[9] text-emerald-700 whitespace-nowrap")
			}
		} else {
			p.text(ui, "—", "text-xs text-muted-foreground")
		}
		p.end(ui)

		add := p.div(ui, "w-[64] h-7 rounded-md items-center justify-center border border-border hover:bg-primary hover:text-primary-foreground cursor-pointer")
		p.icon(ui, sc.ICON_PLUS, "size-3.5")
		if p.clickable(ui, add) {
			basket_add(st, i)
			toast(st, "Ajouté au panier")
		}
		p.end(ui)

		if p.clickable(ui, row) {
			st.compare_of = i
		}
		p.end(ui)
	}
	p.end(ui)

	p.text(
		ui,
		"Les offres sont triées sur le prix au kilo ou au litre quand il existe, pas sur le prix affiché. Les produits en rupture sont placés après.",
		"text-[10] text-muted-foreground",
	)
}

@(private = "file")
head :: proc(ui: ^p.Ctx, label: string, class: string) {
	p.div(ui, p.concat(ui, "shrink-0 ", class))
	p.text(ui, label, "text-[10] font-semibold uppercase tracking-wide text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Basket
// ---------------------------------------------------------------------------

@(private = "file")
basket_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "flex-1 min-w-0 h-full min-h-0")
	defer p.end(ui)

	t := basket_totals(st)

	// Lines.
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 overflow-scroll")
	p.col(ui, "w-full p-5 gap-3")
	p.row(ui, "w-full items-center gap-2")
	p.text(ui, "Panier", "text-lg font-semibold whitespace-nowrap shrink-0")
	p.textf(ui, "text-xs text-muted-foreground tabular-nums whitespace-nowrap shrink-0", "%d articles sur %d lignes", t.items, t.lines)
	p.spacer(ui, "flex-1")
	p.text(ui, "Ce panier ne commande rien et ne paie rien.", "text-[10] text-muted-foreground")
	p.end(ui)

	if len(st.basket) == 0 {
		p.col(ui, "w-full py-16 items-center gap-2")
		p.icon(ui, kit.ICON_PACKAGE, "size-8 text-muted-foreground/40")
		p.text(ui, "Le panier est vide", "text-sm font-medium")
		p.text(ui, "Appuyez sur « a » sur un produit du catalogue.", "text-xs text-muted-foreground")
		p.end(ui)
	}

	for line, li in st.basket {
		pr := &st.cat.products[line.product]
		p.key(ui, pr.id)
		row := p.row(ui, "w-full h-[60] items-center gap-3 px-3 rounded-lg border border-border bg-card")
		if li == st.basket_sel {
			p.apply(ui, "ring-2 ring-ring/40")
		}

		p.div(ui, p.concat(ui, "w-[80] h-5 shrink-0 rounded-sm items-center justify-center ", retailer_class(pr.retailer)))
		p.text(ui, retailer_name(pr.retailer), "text-[10] font-semibold truncate")
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, pr.title, "text-xs font-medium truncate")
		p.row(ui, "items-center gap-1.5")
		p.textf(ui, "text-[10] text-muted-foreground", "%s · TVA %s", pr.brand == "" ? "MDD" : pr.brand, tva_label(pr.tva))
		if pr.has_unit {
			p.text(ui, fmt_unit_price(pr.price, pr.qty, context.temp_allocator), "text-[10] text-muted-foreground tabular-nums")
		}
		p.end(ui)
		p.end(ui)

		// Quantity stepper.
		p.row(ui, "items-center gap-1 shrink-0")
		minus := p.div(ui, "size-6 rounded-md border border-border items-center justify-center hover:bg-accent cursor-pointer")
		p.icon(ui, sc.ICON_MINUS, "size-3")
		if p.clickable(ui, minus) {
			basket_add(st, line.product, -1)
		}
		p.end(ui)
		p.textf(ui, "w-6 text-center text-xs font-semibold tabular-nums", "%d", line.qty)
		plus := p.div(ui, "size-6 rounded-md border border-border items-center justify-center hover:bg-accent cursor-pointer")
		p.icon(ui, sc.ICON_PLUS, "size-3")
		if p.clickable(ui, plus) {
			basket_add(st, line.product, 1)
		}
		p.end(ui)
		p.end(ui)

		p.col(ui, "w-[90] shrink-0 items-end gap-0")
		p.text(ui, fmt_money(Centimes(i64(pr.price) * i64(line.qty)), context.temp_allocator), "text-sm font-semibold tabular-nums")
		p.textf(ui, "text-[10] text-muted-foreground tabular-nums", "%s l'unité", fmt_money(pr.price, context.temp_allocator))
		p.end(ui)

		del := p.div(ui, "size-7 shrink-0 rounded-md items-center justify-center hover:bg-destructive/10 hover:text-destructive cursor-pointer")
		p.icon(ui, sc.ICON_TRASH, "size-3.5")
		if p.clickable(ui, del) {
			basket_remove(st, li)
		}
		p.end(ui)
		p.end(ui)
		_ = row
	}
	p.end(ui)
	p.end(ui)

	// Totals.
	p.col(ui, "w-[360] shrink-0 h-full min-h-0 border-l border-border bg-card/40 overflow-scroll")
	p.col(ui, "w-full p-4 gap-4")

	p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
	p.text(ui, "Sous-totaux par enseigne", "text-xs font-semibold")
	any := false
	for r in Retailer {
		if t.by_retailer[r] == 0 {
			continue
		}
		any = true
		p.row(ui, "w-full items-center gap-2")
		p.div(ui, p.concat(ui, "w-[80] h-4 rounded-sm items-center justify-center ", retailer_class(r)))
		p.text(ui, retailer_name(r), "text-[9] font-semibold truncate")
		p.end(ui)
		p.spacer(ui, "flex-1")
		p.text(ui, fmt_money(t.by_retailer[r], context.temp_allocator), "text-xs font-medium tabular-nums")
		p.end(ui)
	}
	if !any {
		p.text(ui, "—", "text-xs text-muted-foreground")
	}
	p.end(ui)

	// The TVA breakdown, by rate, with HT and the tax separated.
	p.col(ui, "w-full gap-2 p-3 rounded-lg border border-border bg-background")
	p.text(ui, "Détail de la TVA", "text-xs font-semibold")
	p.row(ui, "w-full h-5 items-center gap-2 border-b border-border")
	p.text(ui, "Taux", "w-[52] text-[9] uppercase tracking-wide text-muted-foreground")
	p.spacer(ui, "flex-1")
	p.text(ui, "HT", "w-[72] text-right text-[9] uppercase tracking-wide text-muted-foreground")
	p.text(ui, "TVA", "w-[66] text-right text-[9] uppercase tracking-wide text-muted-foreground")
	p.end(ui)
	for rate in Tva {
		if t.ht_by_tva[rate] == 0 && t.by_tva[rate] == 0 {
			continue
		}
		p.row(ui, "w-full h-6 items-center gap-2")
		p.text(ui, tva_label(rate), "w-[52] text-[11] tabular-nums")
		p.spacer(ui, "flex-1")
		p.text(ui, fmt_money(t.ht_by_tva[rate], context.temp_allocator), "w-[72] text-right text-[11] tabular-nums")
		p.text(ui, fmt_money(t.by_tva[rate], context.temp_allocator), "w-[66] text-right text-[11] tabular-nums")
		p.end(ui)
	}
	p.divider(ui, "w-full h-px bg-border my-1")
	kv(ui, "Total HT", fmt_money(t.ht, context.temp_allocator))
	kv(ui, "Total TVA", fmt_money(t.tva, context.temp_allocator))
	p.row(ui, "w-full items-center pt-1")
	p.text(ui, "Total TTC", "text-sm font-semibold flex-1")
	p.text(ui, fmt_money(t.ttc, context.temp_allocator), "text-base font-bold tabular-nums")
	p.end(ui)
	p.text(ui, "Sommes en centimes entiers; HT + TVA = TTC exactement.", "text-[9] text-muted-foreground")
	p.end(ui)

	if len(st.basket) > 0 {
		b := p.row(ui, "w-full h-9 items-center justify-center gap-1.5 rounded-md border border-border hover:bg-accent cursor-pointer")
		p.icon(ui, sc.ICON_TRASH, "size-3.5")
		p.text(ui, "Vider le panier", "text-xs")
		if p.clickable(ui, b) {
			clear(&st.basket)
			save_state(st)
		}
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The grocery list
// ---------------------------------------------------------------------------

@(private = "file")
list_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 overflow-scroll")
	defer p.end(ui)

	listed, best := list_total(st)
	grouped := list_by_aisle(st, context.temp_allocator)

	p.col(ui, "w-full p-5 gap-3")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-3")
	p.col(ui, "shrink-0 gap-0.5")
	p.text(ui, "Liste de courses", "text-lg font-semibold whitespace-nowrap")
	p.textf(ui, "text-xs text-muted-foreground tabular-nums whitespace-nowrap", "%d articles, groupés par rayon", len(st.list))
	p.end(ui)
	p.spacer(ui, "flex-1")
	p.col(ui, "items-end gap-0 shrink-0")
	p.text(ui, fmt_money(listed, context.temp_allocator), "text-base font-bold tabular-nums whitespace-nowrap")
	if best < listed {
		p.textf(
			ui,
			"text-[10] text-emerald-600 tabular-nums",
			"%s en choisissant la meilleure enseigne (soit %s de moins)",
			fmt_money(best, context.temp_allocator),
			fmt_money(listed - best, context.temp_allocator),
		)
	}
	p.end(ui)
	if len(st.list) > 0 {
		b := p.row(ui, "h-8 px-3 items-center gap-1.5 rounded-md border border-border hover:bg-accent cursor-pointer")
		p.icon(ui, sc.ICON_CHECK, "size-3.5")
		p.text(ui, "Retirer les cochés", "text-xs")
		if p.clickable(ui, b) {
			list_clear_done(st)
		}
		p.end(ui)
	}
	p.end(ui)

	if len(st.list) == 0 {
		p.col(ui, "w-full py-16 items-center gap-2")
		p.icon(ui, kit.ICON_LIST, "size-8 text-muted-foreground/40")
		p.text(ui, "La liste est vide", "text-sm font-medium")
		p.text(ui, "Appuyez sur « l » sur un produit du catalogue.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}

	current := Aisle.None
	first := true
	for gi, n in grouped {
		it := st.list[gi]
		pr := &st.cat.products[it.product]
		if first || pr.aisle != current {
			current = pr.aisle
			first = false
			p.row(ui, "w-full items-center gap-2 pt-2")
			p.text(ui, aisle_name(current), "text-[10] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap shrink-0")
			p.div(ui, "flex-1 h-px bg-border")
			p.end(ui)
			p.end(ui)
		}

		p.key(ui, pr.id)
		row := p.row(ui, "w-full h-[48] items-center gap-3 px-3 rounded-lg border border-border bg-card cursor-pointer hover:bg-accent/40")
		if n == st.list_sel {
			p.apply(ui, "ring-2 ring-ring/40")
		}
		box := p.div(ui, "size-5 shrink-0 rounded-sm border border-input items-center justify-center cursor-pointer")
		if it.done {
			p.apply(ui, "bg-primary border-primary text-primary-foreground")
			p.icon(ui, sc.ICON_CHECK, "size-3.5")
		}
		if p.clickable(ui, box) {
			list_toggle(st, gi)
		}
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, pr.title, it.done ? "text-xs font-medium line-through text-muted-foreground truncate" : "text-xs font-medium truncate")
		p.row(ui, "items-center gap-1.5")
		p.text(ui, retailer_name(pr.retailer), "text-[10] text-muted-foreground")
		if pr.has_unit {
			p.text(ui, "·", "text-[10] text-muted-foreground/50")
			p.text(ui, fmt_unit_price(pr.price, pr.qty, context.temp_allocator), "text-[10] text-muted-foreground tabular-nums")
		}
		if pr.nutri.grade != .None {
			p.div(ui, p.concat(ui, "size-4 rounded-sm items-center justify-center ", nutri_class(pr.nutri.grade)))
			p.text(ui, nutri_letter(pr.nutri.grade), "text-[8] font-bold")
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)

		p.textf(ui, "w-8 text-center text-xs tabular-nums text-muted-foreground", "×%d", it.qty)
		p.text(ui, fmt_money(Centimes(i64(pr.price) * i64(it.qty)), context.temp_allocator), "w-[76] text-right text-xs font-semibold tabular-nums")

		del := p.div(ui, "size-7 shrink-0 rounded-md items-center justify-center hover:bg-destructive/10 hover:text-destructive cursor-pointer")
		p.icon(ui, sc.ICON_X, "size-3.5")
		if p.clickable(ui, del) {
			ordered_remove(&st.list, gi)
			save_state(st)
		}
		p.end(ui)

		if p.clickable(ui, row) {
			st.list_sel = n
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Prices and alerts
// ---------------------------------------------------------------------------

@(private = "file")
prices_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 overflow-scroll")
	defer p.end(ui)

	p.col(ui, "w-full p-5 gap-4")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.col(ui, "gap-0.5 shrink-0")
	p.text(ui, "Prix et alertes", "text-lg font-semibold whitespace-nowrap")
	p.textf(
		ui,
		"text-xs text-muted-foreground",
		"%d relevés hebdomadaires du catalogue, du plus ancien au plus récent",
		HISTORY_LEN,
	)
	p.end(ui)
	p.spacer(ui, "flex-1")
	if n := alerts_firing(st); n > 0 {
		p.row(ui, "items-center gap-1.5 h-7 px-2.5 rounded-md bg-[#e63e11]")
		p.icon(ui, sc.ICON_BELL, "size-3.5 text-white")
		p.textf(ui, "text-[11] font-semibold text-white tabular-nums", "%d alerte(s) déclenchée(s)", n)
		p.end(ui)
	}
	p.end(ui)

	// Armed alerts.
	p.col(ui, "w-full gap-2")
	p.text(ui, "Mes alertes", "text-[10] font-semibold uppercase tracking-wide text-muted-foreground")
	if len(st.alerts) == 0 {
		p.text(ui, "Aucune alerte. Appuyez sur « b » sur un produit pour être prévenu sous un seuil.", "text-xs text-muted-foreground")
	}
	for a, ai in st.alerts {
		pr := &st.cat.products[a.product]
		hit := alert_hit(st, a)
		p.key(ui, pr.id)
		p.row(ui, "w-full h-[52] items-center gap-3 px-3 rounded-lg border border-border bg-card")
		if hit {
			p.apply(ui, "border-emerald-500/60 bg-emerald-500/10")
		}
		p.div(ui, p.concat(ui, "w-[80] h-5 shrink-0 rounded-sm items-center justify-center ", retailer_class(pr.retailer)))
		p.text(ui, retailer_name(pr.retailer), "text-[10] font-semibold truncate")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, pr.title, "text-xs font-medium truncate")
		p.textf(
			ui,
			"text-[10] text-muted-foreground tabular-nums",
			"seuil %s · prix actuel %s",
			fmt_money(a.threshold, context.temp_allocator),
			fmt_money(pr.price, context.temp_allocator),
		)
		p.end(ui)
		if hit {
			p.div(ui, "h-5 px-2 rounded-sm bg-emerald-600 items-center justify-center shrink-0")
			p.text(ui, "sous le seuil", "text-[9] font-semibold text-white")
			p.end(ui)
		}
		sp := p.div(ui, "w-[150] shrink-0")
		sparkline(ui, st, pr^)
		p.end(ui)
		_ = sp
		del := p.div(ui, "size-7 shrink-0 rounded-md items-center justify-center hover:bg-destructive/10 hover:text-destructive cursor-pointer")
		p.icon(ui, sc.ICON_X, "size-3.5")
		if p.clickable(ui, del) {
			alert_clear(st, a.product)
		}
		p.end(ui)
		p.end(ui)
		_ = ai
	}
	p.end(ui)

	// The biggest movers in the catalogue.
	p.col(ui, "w-full gap-2")
	p.text(ui, "Plus fortes baisses du catalogue", "text-[10] font-semibold uppercase tracking-wide text-muted-foreground")
	best := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(st.cat.products) {
		pr := st.cat.products[i]
		if pr.avail != .In_Stock {
			continue
		}
		if history_change(pr) > -80 {
			continue
		}
		append(&best, i)
		if len(best) > 400 {
			break
		}
	}
	// Order them by the size of the fall, then show a dozen.
	for i in 1 ..< len(best) {
		j := i
		for j > 0 && history_change(st.cat.products[best[j - 1]]) > history_change(st.cat.products[best[j]]) {
			best[j - 1], best[j] = best[j], best[j - 1]
			j -= 1
		}
	}
	shown := min(10, len(best))
	for k in 0 ..< shown {
		pr := &st.cat.products[best[k]]
		p.key(ui, pr.id)
		row := p.row(ui, "w-full h-[44] items-center gap-3 px-3 rounded-lg border border-border bg-card cursor-pointer hover:bg-accent/40")
		p.div(ui, p.concat(ui, "w-[80] h-5 shrink-0 rounded-sm items-center justify-center ", retailer_class(pr.retailer)))
		p.text(ui, retailer_name(pr.retailer), "text-[10] font-semibold truncate")
		p.end(ui)
		p.text(ui, pr.title, "flex-1 min-w-0 text-xs font-medium truncate")
		p.text(ui, fmt_pct(history_change(pr^), context.temp_allocator), "w-[64] text-right text-xs font-semibold text-emerald-600 tabular-nums")
		p.text(ui, fmt_money(pr.price, context.temp_allocator), "w-[80] text-right text-xs font-semibold tabular-nums")
		if p.clickable(ui, row) {
			st.compare_of = best[k]
			st.view = .Compare
		}
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

@(private = "file")
import_view :: proc(ui: ^p.Ctx, st: ^State) {
	p.col(ui, "flex-1 min-w-0 h-full min-h-0 overflow-scroll")
	defer p.end(ui)
	p.col(ui, "w-full p-6 gap-4 max-w-[760]")
	defer p.end(ui)

	p.text(ui, "Importer un flux produits", "text-lg font-semibold")
	p.text(
		ui,
		"Aucune donnée n'est récupérée en ligne. Déposez un flux produits que vous possédez déjà — le format Google Merchant Center (RSS 2.0, namespace g:) ou sa variante CSV/TSV — et il sera lu tel quel.",
		"text-xs text-muted-foreground",
	)
	b := p.row(ui, "h-9 px-4 w-fit items-center gap-2 rounded-md bg-primary text-primary-foreground cursor-pointer hover:bg-primary/90")
	p.icon(ui, kit.ICON_FOLDER_OPEN, "size-4")
	p.text(ui, "Choisir un fichier…", "text-xs font-medium whitespace-nowrap")
	p.text(ui, "(o)", "text-[10] opacity-70")
	if p.clickable(ui, b) {
		begin_pick(st)
	}
	p.end(ui)

	if st.import_msg != "" {
		p.row(ui, "w-full p-3 rounded-lg border border-border bg-card")
		p.text(ui, st.import_msg, "text-xs")
		p.end(ui)
	}
	p.col(ui, "w-full gap-1 p-3 rounded-lg border border-border bg-muted/30")
	p.text(ui, "Champs lus", "text-[10] font-semibold uppercase tracking-wide text-muted-foreground")
	for s in ([?]string {
		"g:id, g:title, g:brand, g:gtin — identité, appariement sur le code-barres (EAN-13 vérifié)",
		"g:price, g:sale_price — en centimes entiers; virgule décimale acceptée, devise autre que EUR refusée",
		"g:availability, g:product_type, g:color, g:size, g:size_system",
		"g:unit_pricing_measure — « 500 g », « 1,5 L », « lot de 6 x 33 cl »",
		"g:shipping/g:price, g:item_group_id (les tailles d'un même vêtement sont regroupées)",
		"shop:tva, shop:rayon, shop:enseigne et le bloc nutritionnel shop:* (extension locale)",
	}) {
		p.text(ui, s, "text-[11] text-muted-foreground")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Status bar, overlays
// ---------------------------------------------------------------------------

@(private = "file")
status :: proc(ui: ^p.Ctx, st: ^State) {
	p.row(ui, "w-full h-[30] shrink-0 items-center gap-3 px-4 border-t border-border bg-card")
	defer p.end(ui)

	// The provenance, on every view. This is generated data and must never be
	// mistaken for a live price.
	p.div(ui, "h-4 px-1.5 rounded-sm bg-amber-500/20 items-center justify-center shrink-0")
	p.text(ui, st.cat.generated ? "CATALOGUE GÉNÉRÉ" : "FLUX IMPORTÉ", "text-[9] font-bold text-amber-700")
	p.end(ui)
	p.text(
		ui,
		st.cat.generated ? "données de démonstration, pas de prix en direct — aucun accès réseau" : st.cat.source,
		"text-[10] text-muted-foreground truncate",
	)
	p.spacer(ui, "flex-1")
	p.textf(ui, "text-[10] text-muted-foreground tabular-nums shrink-0", "%d produits", len(st.cat.products))
	p.textf(ui, "text-[10] text-muted-foreground tabular-nums shrink-0", "filtre %.2f ms", st.filter_ms)
	p.textf(ui, "text-[10] text-muted-foreground tabular-nums shrink-0", "image %.2f ms", st.frame_ms)
	p.text(ui, "? aide", "text-[10] text-muted-foreground shrink-0")
}

@(private = "file")
toast :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = st.now
}

@(private = "file")
toast_layer :: proc(ui: ^p.Ctx, st: ^State) {
	p.div(ui, "absolute inset-0 z-40 items-center justify-end flex-col pb-10")
	defer p.end(ui)
	p.row(ui, "px-4 h-9 items-center rounded-lg bg-foreground shadow-lg")
	p.text(ui, st.toast, "text-xs text-background")
	p.end(ui)
}

@(private = "file")
help_overlay :: proc(ui: ^p.Ctx, st: ^State) {
	p.div(ui, "absolute inset-0 z-50 items-center justify-center bg-black/40")
	defer p.end(ui)

	p.col(ui, "w-[560] gap-3 p-5 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)

	p.row(ui, "w-full items-center")
	p.text(ui, "Raccourcis", "text-sm font-semibold flex-1")
	x := p.div(ui, "size-6 rounded-md items-center justify-center hover:bg-accent cursor-pointer")
	p.icon(ui, sc.ICON_X, "size-3.5")
	if p.clickable(ui, x) {
		st.help_open = false
	}
	p.end(ui)
	p.end(ui)

	for pair in ([?][2]string {
		{"/", "rechercher — accents et pluriels ignorés (creme trouve crème)"},
		{"↑ ↓ j k", "parcourir les résultats"},
		{"Page ↑ ↓ · Début · Fin", "défiler"},
		{"Entrée", "comparer ce produit entre enseignes, au prix au kilo"},
		{"a", "ajouter au panier"},
		{"l", "ajouter à la liste de courses"},
		{"Espace", "cocher une ligne de la liste"},
		{"b", "alerte de prix sous un seuil"},
		{"1 … 5", "catalogue · comparer · panier · liste · prix"},
		{"u", "trier par prix au kilo / au litre"},
		{"x", "trier par prix affiché"},
		{"s", "en stock seulement"},
		{"p", "promotions seulement"},
		{"n", "plafond de Nutri-Score"},
		{"e", "exporter le catalogue en flux Merchant (XML et CSV)"},
		{"o", "ouvrir un flux produits (Google Merchant RSS, CSV ou TSV)"},
		{"i", "voir le format d'import attendu"},
		{"Échap", "fermer, ou effacer la recherche"},
		{"Ctrl+Q", "quitter"},
	}) {
		p.row(ui, "w-full items-center gap-3")
		p.div(ui, "w-[150] shrink-0 items-start")
		p.div(ui, "h-5 px-1.5 rounded-sm bg-muted items-center justify-center")
		p.text(ui, pair[0], "text-[10] font-mono")
		p.end(ui)
		p.end(ui)
		p.text(ui, pair[1], "text-[11] text-muted-foreground flex-1")
		p.end(ui)
	}
	p.divider(ui, "w-full h-px bg-border my-1")
	p.text(
		ui,
		"Les données sont générées localement. Ce programme n'ouvre aucune connexion réseau, n'achète rien et n'écrit que dans ~/.local/share/palmy-shop.",
		"text-[10] text-muted-foreground",
	)
}
