// The interface.
//
// One window, a sidebar of accounts, five views, and a keyboard path to
// everything. There is no login screen and no password field, because there
// is nothing to log in to: statements arrive as files the user picks.
//
// Two decisions are worth stating. The transaction list is windowed by hand
// rather than handed to `overflow-scroll` — only the rows that fit are built,
// so a book of twenty thousand transactions costs the same per frame as one
// of twenty, and the selected row can be kept in view by arithmetic instead
// of by chasing a scroll offset. And every number on screen comes from the
// same formatter: `money_text`, French convention, from the integer centimes
// in the ledger, so nothing can be displayed in a form the ledger does not
// hold.
package main

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SIDEBAR_W :: f32(248)
HEADER_H :: f32(56)
TABS_H :: f32(44)
STATUS_H :: f32(28)
ROW_H :: f32(34)

// Column widths for the transaction table. Fixed, because a money column that
// moves as the data changes is unreadable.
COL_DATE :: f32(92)
COL_METHOD :: f32(72)
COL_CAT :: f32(150)
COL_AMOUNT :: f32(124)
COL_BAL :: f32(118)

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, app: ^App) {
	size := p.size(ui)
	if len(app.rows) == 0 && txn_count(&app.led) > 0 && app.last_filter == 0 {
		refilter(app)
	}
	// How many rows fit, which the keyboard handler needs before it runs.
	app.rows_visible = max(int((size.y - HEADER_H - TABS_H - STATUS_H - 36) / ROW_H), 1)

	// The file dialog owns the keyboard while it is up.
	if kit.pick_active(&app.pick) {
		shell(ui, app)
		if res, done := kit.pick_draw(ui, &app.pick); done {
			defer kit.pick_result_free(res)
			if res.ok {
				do_import(app, res.path)
			}
		}
		return
	}

	if app.modal == .None {
		keys(ui, app)
	} else {
		modal_keys(ui, app)
	}
	shell(ui, app)
	if app.modal != .None {
		draw_modal(ui, app, size)
	}
}

@(private = "file")
shell :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	sidebar(ui, app)

	p.col(ui, "flex-1 h-full overflow-hidden")
	defer p.end(ui)

	header(ui, app)
	tabs(ui, app)

	p.div(ui, "flex-col flex-1 w-full overflow-hidden")
	switch app.view {
	case .Transactions:
		view_transactions(ui, app)
	case .Budgets:
		view_budgets(ui, app)
	case .Recurring:
		view_recurring(ui, app)
	case .Charts:
		view_charts(ui, app)
	case .Reconcile:
		view_reconcile(ui, app)
	}
	p.end(ui)

	status_bar(ui, app)
}

// ---------------------------------------------------------------------------
// Sidebar: the accounts, with their running balances
// ---------------------------------------------------------------------------

@(private = "file")
sidebar :: proc(ui: ^p.Ctx, app: ^App) {
	p.col(ui, "h-full border-r border-sidebar-border bg-sidebar overflow-hidden")
	p.style(ui).w = p.px(SIDEBAR_W)
	defer p.end(ui)

	// Net worth.
	p.col(ui, "px-4 pt-4 pb-3 gap-1")
	p.text(ui, "Patrimoine", "text-xs uppercase tracking-wide text-muted-foreground")
	total := assets_total(&app.led)
	p.text(
		ui,
		money_text(total, true, context.temp_allocator),
		fmt.tprintf(
			"text-2xl font-semibold tabular-nums %s",
			total < 0 ? "text-destructive" : "text-sidebar-foreground",
		),
	)
	p.end(ui)

	sc.separator(ui)

	p.col(ui, "flex-1 px-2 py-2 gap-0.5 overflow-scroll")
	defer p.end(ui)

	section_label(ui, "Comptes")
	// "All accounts" first, then each one.
	account_row(ui, app, -1, "Tous les comptes", assets_total(&app.led), -1)
	for i in asset_list(app, context.temp_allocator) {
		a := app.led.accounts[i]
		account_row(ui, app, i, a.name, a.balance, i)
	}

	// The categories that cost the most this month, which is the thing worth
	// seeing without changing view.
	lo := month_start(app.month)
	hi := month_end(app.month)
	tops := spend_by_category(&app.led, lo, hi, context.temp_allocator)
	if len(tops) > 0 {
		p.div(ui, "h-3")
		p.end(ui)
		section_label(ui, fmt.tprintf("Dépenses — %s", month_text(app.month.y, app.month.m, context.temp_allocator)))
		shown := min(len(tops), 6)
		for k in 0 ..< shown {
			t := tops[k]
			p.key(ui, fmt.tprintf("top%d", t.account))
			p.row(ui, "items-center gap-2 px-2 py-1.5 rounded-md hover:bg-sidebar-accent cursor-pointer")
			if p.clickable(ui) {
				app.filter.category = app.filter.category == t.account ? -1 : t.account
				app.view = .Transactions
				refilter(app)
			}
			p.div(ui, "size-2 rounded-full")
			p.style(ui).bg = p.flat(tint_of(app.led.accounts[t.account].tint))
			p.end(ui)
			p.text(ui, account_name(&app.led, t.account), "flex-1 text-xs truncate text-sidebar-foreground")
			p.text(
				ui,
				money_text(t.total, false, context.temp_allocator),
				"text-xs tabular-nums text-muted-foreground",
			)
			p.end(ui)
		}
	}
}

@(private = "file")
section_label :: proc(ui: ^p.Ctx, text: string) {
	p.text(ui, text, "px-2 py-1 text-xs uppercase tracking-wide text-muted-foreground truncate")
}

@(private = "file")
account_row :: proc(ui: ^p.Ctx, app: ^App, idx: int, name: string, balance: Cents, tint: int) {
	selected := app.filter.account == idx
	p.key(ui, fmt.tprintf("acct%d", idx))
	p.row(
		ui,
		fmt.tprintf(
			"items-center gap-2 px-2 py-2 rounded-md cursor-pointer transition %s",
			selected ? "bg-sidebar-accent" : "hover:bg-sidebar-accent",
		),
	)
	defer p.end(ui)
	if p.clickable(ui) {
		app.filter.account = idx
		app.sel = 0
		refilter(app)
	}
	p.focusable(ui)
	if p.activated(ui) {
		app.filter.account = idx
		refilter(app)
	}

	if tint < 0 {
		p.icon(ui, sc.ICON_HOUSE, "size-4 text-muted-foreground")
	} else {
		p.icon(ui, sc.ICON_CREDIT_CARD, "size-4 text-muted-foreground")
	}
	p.col(ui, "flex-1 overflow-hidden")
	p.text(
		ui,
		name,
		fmt.tprintf("text-sm truncate %s", selected ? "font-medium" : "text-sidebar-foreground"),
	)
	p.end(ui)
	p.text(
		ui,
		money_text(balance, false, context.temp_allocator),
		fmt.tprintf("text-xs tabular-nums %s", balance < 0 ? "text-destructive" : "text-muted-foreground"),
	)
}

// ---------------------------------------------------------------------------
// Header: search and the filter chips
// ---------------------------------------------------------------------------

@(private = "file")
header :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(ui, "w-full items-center gap-2 px-4 border-b border-border")
	p.style(ui).h = p.px(HEADER_H)
	defer p.end(ui)

	// Search.
	p.row(ui, "flex-1 items-center gap-2 h-9 px-3 rounded-md border border-input bg-background max-w-[460]")
	p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground")
	// `/` focuses this field. The focus has to be handed over by node id, and
	// the id only exists once the element is built — so the shortcut raises a
	// flag and this is where it is honoured, in the same frame.
	at := p.node_count(ui)
	changed, _ := p.text_field(
		ui,
		&app.search,
		"Rechercher un libellé, une catégorie, un montant…",
		"flex-1 h-7 bg-transparent border-0 text-sm",
	)
	if app.focus_search && at < len(ui.nodes) {
		p.set_focus(ui, ui.nodes[at].id)
		app.focus_search = false
	}
	if changed {
		app.sel = 0
		refilter(app)
	}
	p.end(ui)

	chip(ui, app, fmt.tprintf("Période: %s", range_label(app.filter.range)), false, proc(a: ^App) {
		a.filter.range = Range((int(a.filter.range) + 1) % len(Range))
		refilter(a)
	})
	chip(
		ui,
		app,
		app.filter.by_method ? fmt.tprintf("Type: %s", method_label(app.filter.method)) : "Type: tous",
		app.filter.by_method,
		proc(a: ^App) {
			cycle_method(a)
		},
	)
	chip(ui, app, "À catégoriser", app.filter.only_todo, proc(a: ^App) {
		a.filter.only_todo = !a.filter.only_todo
		a.sel = 0
		refilter(a)
	})
	if app.filter.category >= 0 {
		chip(ui, app, account_name(&app.led, app.filter.category), true, proc(a: ^App) {
			a.filter.category = -1
			refilter(a)
		})
	}

	p.spacer(ui)

	if icon_button(ui, sc.ICON_DOWNLOAD, "Importer un relevé  (Ctrl+O)") {
		open_import(app)
	}
	if icon_button(ui, sc.ICON_INFO, "Aide  (?)") {
		app.modal = .Help
	}
}

@(private = "file")
chip :: proc(ui: ^p.Ctx, app: ^App, label: string, on: bool, action: proc(a: ^App)) {
	p.row(
		ui,
		fmt.tprintf(
			"items-center h-8 px-3 rounded-full border text-xs whitespace-nowrap cursor-pointer transition %s",
			on ? "bg-primary text-primary-foreground border-primary" : "border-border hover:bg-accent",
		),
	)
	defer p.end(ui)
	if p.clickable(ui) {
		action(app)
	}
	p.focusable(ui)
	if p.activated(ui) {
		action(app)
	}
	p.text(ui, label, "")
}

@(private = "file")
icon_button :: proc(ui: ^p.Ctx, ic: p.Icon, tip: string) -> bool {
	p.div(ui, "size-9 items-center justify-center rounded-md hover:bg-accent cursor-pointer transition")
	defer p.end(ui)
	hit := p.clickable(ui)
	p.focusable(ui)
	act := p.activated(ui)
	p.icon(ui, ic, "size-4 text-muted-foreground")
	_ = tip
	return hit || act
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

@(private = "file")
tabs :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(ui, "w-full items-center gap-1 px-3 border-b border-border")
	p.style(ui).h = p.px(TABS_H)
	defer p.end(ui)

	for v in View {
		active := app.view == v
		p.key(ui, view_title(v))
		p.row(
			ui,
			fmt.tprintf(
				"items-center gap-2 h-8 px-3 rounded-md text-sm cursor-pointer transition %s",
				active ? "bg-secondary font-medium" : "text-muted-foreground hover:bg-accent",
			),
		)
		if p.clickable(ui) {
			app.view = v
		}
		p.focusable(ui)
		if p.activated(ui) {
			app.view = v
		}
		p.text(ui, fmt.tprintf("%d", int(v) + 1), "text-xs text-muted-foreground tabular-nums")
		p.text(ui, view_title(v), "")
		if v == .Transactions {
			sc.badge(ui, fmt.tprintf("%d", len(app.rows)), .Secondary)
		}
		if v == .Budgets {
			tot := budget_totals(app, app.month.y, app.month.m)
			if tot.over > 0 {
				sc.badge(ui, fmt.tprintf("%d", tot.over), .Destructive)
			}
		}
		p.end(ui)
	}

	p.spacer(ui)

	if app.view == .Budgets || app.view == .Charts {
		month_nav(ui, app)
	}
}

@(private = "file")
month_nav :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(ui, "items-center gap-1")
	defer p.end(ui)
	if icon_button(ui, sc.ICON_CHEVRON_LEFT, "Mois précédent") {
		app.month = date_month_add(app.month, -1)
	}
	p.text(
		ui,
		month_text(app.month.y, app.month.m, context.temp_allocator),
		"text-sm font-medium min-w-[128] text-center",
	)
	if icon_button(ui, sc.ICON_CHEVRON_RIGHT, "Mois suivant") {
		app.month = date_month_add(app.month, 1)
	}
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

@(private = "file")
view_transactions :: proc(ui: ^p.Ctx, app: ^App) {
	// Header row.
	p.row(ui, "w-full items-center gap-3 px-4 h-9 border-b border-border bg-muted/40")
	head_cell(ui, "Date", COL_DATE, false)
	head_cell(ui, "Type", COL_METHOD, false)
	p.text(ui, "Libellé", "flex-1 text-xs uppercase tracking-wide text-muted-foreground truncate")
	head_cell(ui, "Catégorie", COL_CAT, false)
	head_cell(ui, "Montant", COL_AMOUNT, true)
	p.end(ui)

	p.col(ui, "flex-1 w-full overflow-hidden")
	defer p.end(ui)

	if len(app.rows) == 0 {
		empty_state(
			ui,
			sc.ICON_INBOX,
			txn_count(&app.led) == 0 ? "Aucune opération" : "Aucune opération ne correspond",
			txn_count(&app.led) == 0 \
			? "Importez un relevé exporté depuis votre banque: Ctrl+O. Rien n'est connecté à une banque." \
			: "Modifiez la recherche ou les filtres (Échap efface).",
		)
		return
	}

	// The windowed list: build only the rows that fit.
	first := clamp(app.sel - app.rows_visible / 2, 0, max(len(app.rows) - app.rows_visible, 0))
	last := min(first + app.rows_visible, len(app.rows))
	l := &app.led

	for k in first ..< last {
		ti := app.rows[k]
		t := &l.txns[ti]
		selected := k == app.sel
		amount := txn_amount(l, t)
		cat := txn_category(l, t)

		p.key(ui, fmt.tprintf("row%d", t.id))
		p.row(
			ui,
			fmt.tprintf(
				"w-full items-center gap-3 px-4 border-b border-border/60 cursor-pointer transition %s",
				selected ? "bg-accent" : "hover:bg-accent/50",
			),
		)
		p.style(ui).h = p.px(ROW_H)
		if p.clickable(ui) {
			app.sel = k
		}

		p.text(ui, date_text(t.date, context.temp_allocator), "text-xs tabular-nums text-muted-foreground")
		p.style(ui).w = p.px(COL_DATE)

		p.div(ui, "items-start")
		p.style(ui).w = p.px(COL_METHOD)
		if t.method == .Unknown {
			p.text(ui, "—", "text-xs text-muted-foreground")
		} else {
			sc.badge(ui, method_label(t.method), .Outline)
		}
		p.end(ui)

		p.row(ui, "flex-1 items-center gap-2 overflow-hidden")
		p.text(ui, t.label, "text-sm truncate")
		if t.cleared {
			p.icon(ui, sc.ICON_CHECK, "size-3 text-emerald-600 shrink-0")
		}
		if txn_is_split(l, t) && !txn_is_transfer(l, t) {
			sc.badge(ui, "ventilé", .Secondary)
		}
		p.end(ui)

		p.div(ui, "items-start overflow-hidden")
		p.style(ui).w = p.px(COL_CAT)
		if txn_is_transfer(l, t) {
			sc.badge(ui, "virement", .Secondary)
		} else if cat >= 0 {
			p.row(ui, "items-center gap-1.5 overflow-hidden")
			p.div(ui, "size-2 rounded-full shrink-0")
			p.style(ui).bg = p.flat(tint_of(l.accounts[cat].tint))
			p.end(ui)
			p.text(
				ui,
				account_name(l, cat),
				fmt.tprintf("text-xs truncate %s", t.auto_cat ? "text-muted-foreground" : ""),
			)
			p.end(ui)
		} else {
			p.text(ui, "à catégoriser", "text-xs text-amber-600 truncate")
		}
		p.end(ui)

		p.text(
			ui,
			money_text(amount, true, context.temp_allocator),
			fmt.tprintf(
				"text-sm text-right tabular-nums font-medium %s",
				amount < 0 ? "" : "text-emerald-600",
			),
		)
		p.style(ui).w = p.px(COL_AMOUNT)
		p.end(ui)
	}

	p.spacer(ui)

	// A scroll position indicator, so a windowed list still says where it is.
	if len(app.rows) > app.rows_visible {
		p.row(ui, "w-full h-1 bg-muted")
		p.div(ui, "h-full bg-muted-foreground/40 rounded-full")
		p.style(ui).w = p.pct(100 * f32(app.rows_visible) / f32(len(app.rows)))
		p.end(ui)
		p.end(ui)
	}
}

@(private = "file")
head_cell :: proc(ui: ^p.Ctx, label: string, w: f32, right: bool) {
	p.text(
		ui,
		label,
		fmt.tprintf(
			"text-xs uppercase tracking-wide text-muted-foreground truncate %s",
			right ? "text-right" : "",
		),
	)
	p.style(ui).w = p.px(w)
}

@(private = "file")
empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-2 p-8")
	defer p.end(ui)
	p.icon(ui, ic, "size-8 text-muted-foreground")
	p.text(ui, title, "text-base font-medium")
	p.text(ui, body, "text-sm text-muted-foreground text-center max-w-[460]")
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

@(private = "file")
view_budgets :: proc(ui: ^p.Ctx, app: ^App) {
	lines := budget_month(app, app.month.y, app.month.m)
	tot := budget_totals(app, app.month.y, app.month.m)

	p.col(ui, "flex-1 w-full p-4 gap-4 overflow-scroll")
	defer p.end(ui)

	// The month's totals.
	p.row(ui, "w-full gap-3")
	stat(ui, "Budgété", money_text(tot.available, true, context.temp_allocator), "")
	stat(ui, "Dépensé", money_text(tot.spent, true, context.temp_allocator), "")
	stat(
		ui,
		"Restant",
		money_text(tot.left, true, context.temp_allocator),
		tot.left < 0 ? "text-destructive" : "text-emerald-600",
	)
	stat(
		ui,
		"Dépassements",
		fmt.tprintf("%d", tot.over),
		tot.over > 0 ? "text-destructive" : "",
	)
	p.end(ui)

	if len(lines) == 0 {
		empty_state(
			ui,
			sc.ICON_CIRCLE_ALERT,
			"Aucune enveloppe ce mois-ci",
			"Appuyez sur B pour en créer une à partir de la catégorie sélectionnée, ou sur S pour proposer un budget depuis l'historique.",
		)
		return
	}

	app.modal_sel = clamp(app.modal_sel, 0, max(len(lines) - 1, 0))
	ink := chart_ink()
	resize(&app.gauges, len(lines))
	for line, i in lines {
		selected := i == app.sel % max(len(lines), 1)
		p.key(ui, fmt.tprintf("bud%d", line.category))
		p.col(
			ui,
			fmt.tprintf(
				"w-full gap-2 p-3 rounded-lg border bg-card cursor-pointer transition %s",
				selected ? "border-ring" : "border-border hover:bg-accent/40",
			),
		)
		if p.clickable(ui) {
			app.sel = i
		}

		p.row(ui, "w-full items-center gap-2")
		p.div(ui, "size-2.5 rounded-full shrink-0")
		p.style(ui).bg = p.flat(tint_of(app.led.accounts[line.category].tint))
		p.end(ui)
		p.text(ui, account_name(&app.led, line.category), "text-sm font-medium flex-1 truncate")
		if line.over {
			sc.badge(ui, fmt.tprintf("dépassé de %s", money_text(-line.left, true, context.temp_allocator)), .Destructive)
		} else {
			p.text(
				ui,
				fmt.tprintf(
					"%s restant",
					money_text(line.left, true, context.temp_allocator),
				),
				"text-xs text-muted-foreground tabular-nums",
			)
		}
		p.end(ui)

		// The gauge, drawn so an overspend can show its overshoot.
		// The gauge data is kept in a per-frame array sized before any of it
		// is handed to `p.pixels`, so no append can reallocate under a
		// pointer the painter still holds.
		app.gauges[i] = Gauge_Data {
			line  = line,
			tint  = tint_of(app.led.accounts[line.category].tint),
			track = ink.track,
			over  = ink.bad,
			rule  = ink.fg,
		}
		p.pixels(
			ui,
			"w-full h-2 rounded-full overflow-hidden",
			&app.gauges[i],
			proc(c: ^p.Canvas, r: p.Rect, g: ^Gauge_Data) {
				draw_gauge(c, r, g)
			},
		)

		p.row(ui, "w-full items-center gap-2")
		p.text(
			ui,
			fmt.tprintf(
				"%s sur %s",
				money_text(line.spent, false, context.temp_allocator),
				money_text(line.available, true, context.temp_allocator),
			),
			"text-xs tabular-nums text-muted-foreground",
		)
		if line.carry != 0 {
			p.text(
				ui,
				fmt.tprintf(
					"(report %s)",
					money_text(line.carry, true, context.temp_allocator),
				),
				fmt.tprintf("text-xs tabular-nums %s", line.carry < 0 ? "text-destructive" : "text-emerald-600"),
			)
		}
		p.spacer(ui)
		p.text(ui, fmt.tprintf("%d %%", line.pct), "text-xs tabular-nums text-muted-foreground")
		p.text(ui, fmt.tprintf("%d op.", line.count), "text-xs tabular-nums text-muted-foreground")
		p.end(ui) // the figures row

		p.end(ui) // the envelope card
	}
}

@(private = "file")
stat :: proc(ui: ^p.Ctx, label, value, tint: string) {
	p.col(ui, "flex-1 gap-1 p-3 rounded-lg border border-border bg-card")
	defer p.end(ui)
	p.text(ui, label, "text-xs uppercase tracking-wide text-muted-foreground")
	p.text(ui, value, fmt.tprintf("text-lg font-semibold tabular-nums %s", tint))
}

// ---------------------------------------------------------------------------
// Recurring
// ---------------------------------------------------------------------------

@(private = "file")
view_recurring :: proc(ui: ^p.Ctx, app: ^App) {
	recs := recurrences(app)
	out, income := recurring_monthly_total(recs)

	p.col(ui, "flex-1 w-full p-4 gap-4 overflow-scroll")
	defer p.end(ui)

	p.row(ui, "w-full gap-3")
	stat(ui, "Charges récurrentes / mois", money_text(out, true, context.temp_allocator), "text-destructive")
	stat(ui, "Recettes récurrentes / mois", money_text(income, true, context.temp_allocator), "text-emerald-600")
	stat(
		ui,
		"Net récurrent",
		money_text(income - out, true, context.temp_allocator),
		income - out < 0 ? "text-destructive" : "text-emerald-600",
	)
	stat(ui, "Détectées", fmt.tprintf("%d", len(recs)), "")
	p.end(ui)

	if len(recs) == 0 {
		empty_state(
			ui,
			sc.ICON_LOADER_CIRCLE,
			"Aucune charge récurrente détectée",
			"Il faut au moins trois échéances au même marchand, à un montant stable et à une cadence régulière. Deux ne suffisent pas.",
		)
		return
	}

	p.row(ui, "w-full items-center gap-3 px-1 h-7")
	p.text(ui, "Marchand", "flex-1 text-xs uppercase tracking-wide text-muted-foreground")
	head_cell(ui, "Cadence", 140, false)
	head_cell(ui, "Montant", COL_AMOUNT, true)
	head_cell(ui, "Par mois", 110, true)
	head_cell(ui, "Prochaine", 110, true)
	head_cell(ui, "Confiance", 86, true)
	p.end(ui)

	for r, i in recs {
		p.key(ui, fmt.tprintf("rec%d", i))
		p.row(ui, "w-full items-center gap-3 px-1 py-2 border-b border-border/60 hover:bg-accent/40 cursor-pointer rounded-md")
		if p.clickable(ui) {
			// Show exactly the transactions that make up this recurrence.
			clear(&app.search)
			append(&app.search, r.key)
			app.filter.only_todo = false
			app.view = .Transactions
			app.sel = 0
			refilter(app)
		}

		p.col(ui, "flex-1 overflow-hidden")
		p.text(ui, r.key, "text-sm font-medium truncate")
		p.text(
			ui,
			fmt.tprintf(
				"%d échéances, depuis le %s",
				r.count,
				date_text(r.first, context.temp_allocator),
			),
			"text-xs text-muted-foreground truncate",
		)
		p.end(ui)

		p.div(ui, "items-start")
		p.style(ui).w = p.px(140)
		sc.badge(ui, cadence_label(r.cadence), .Secondary)
		p.end(ui)

		p.text(
			ui,
			money_text(r.amount, true, context.temp_allocator),
			fmt.tprintf(
				"text-sm text-right tabular-nums font-medium %s",
				r.amount < 0 ? "" : "text-emerald-600",
			),
		)
		p.style(ui).w = p.px(COL_AMOUNT)

		p.text(
			ui,
			money_text(monthly_equivalent(r), true, context.temp_allocator),
			"text-sm text-right tabular-nums text-muted-foreground",
		)
		p.style(ui).w = p.px(130)

		p.text(
			ui,
			date_text(r.next, context.temp_allocator),
			"text-xs text-right tabular-nums text-muted-foreground",
		)
		p.style(ui).w = p.px(110)

		p.text(
			ui,
			fmt.tprintf("%d %%", r.confidence),
			fmt.tprintf(
				"text-xs text-right tabular-nums %s",
				r.confidence >= 70 ? "text-emerald-600" : "text-muted-foreground",
			),
		)
		p.style(ui).w = p.px(86)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

@(private = "file")
view_charts :: proc(ui: ^p.Ctx, app: ^App) {
	p.col(ui, "flex-1 w-full p-4 gap-3 overflow-hidden")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	for name, i in ([?]string{"Dépenses par catégorie", "Solde dans le temps"}) {
		active := app.chart == i
		p.key(ui, name)
		p.row(
			ui,
			fmt.tprintf(
				"items-center h-8 px-3 rounded-md text-sm cursor-pointer transition %s",
				active ? "bg-secondary font-medium" : "text-muted-foreground hover:bg-accent",
			),
		)
		if p.clickable(ui) {
			app.chart = i
		}
		p.text(ui, name, "")
		p.end(ui)
	}
	p.spacer(ui)
	p.text(ui, "T bascule de graphique", "text-xs text-muted-foreground")
	p.end(ui) // the toolbar row

	if app.chart == 0 {
		lo := month_start(app.month)
		hi := month_end(app.month)
		items := spend_by_category(&app.led, lo, hi, context.temp_allocator)
		if len(items) == 0 {
			empty_state(ui, sc.ICON_COLUMNS_3, "Rien à montrer ce mois-ci", "Changez de mois avec [ et ].")
			return
		}
		mx := items[0].total
		total := Cents(0)
		for it in items {
			total += it.total
		}
		p.text(
			ui,
			fmt.tprintf(
				"%s — %s dépensés sur %d catégories",
				month_text(app.month.y, app.month.m, context.temp_allocator),
				money_text(total, true, context.temp_allocator),
				len(items),
			),
			"text-sm text-muted-foreground",
		)
		ink := chart_ink()
		app.bars = Bars_Data {
			app   = app,
			items = items,
			max   = mx,
			fg    = ink.fg,
			muted = ink.muted,
			grid  = ink.grid,
		}
		p.pixels(
			ui,
			"flex-1 w-full rounded-lg border border-border bg-card p-2",
			&app.bars,
			proc(c: ^p.Canvas, r: p.Rect, d: ^Bars_Data) {
				draw_bars(c, p.rect_inset(r, 10), d)
			},
		)
	} else {
		account := app.filter.account
		if account < 0 {
			assets := asset_list(app, context.temp_allocator)
			if len(assets) > 0 {
				account = assets[0]
			}
		}
		if account < 0 {
			empty_state(ui, sc.ICON_CREDIT_CARD, "Aucun compte", "Importez un relevé pour commencer.")
			return
		}
		lo := date_month_add(month_start(app.month), -11)
		hi := month_end(app.month)
		pts := balance_series(&app.led, account, lo, hi, context.temp_allocator)
		if len(pts) < 2 {
			empty_state(ui, sc.ICON_COLUMNS_3, "Pas assez d'historique", "Il faut au moins deux mouvements pour tracer une courbe.")
			return
		}
		p.text(
			ui,
			fmt.tprintf(
				"%s — du %s au %s, solde final %s",
				account_name(&app.led, account),
				date_text(pts[0].date, context.temp_allocator),
				date_text(pts[len(pts) - 1].date, context.temp_allocator),
				money_text(pts[len(pts) - 1].balance, true, context.temp_allocator),
			),
			"text-sm text-muted-foreground",
		)
		ink := chart_ink()
		app.line_data = Line_Data {
			app    = app,
			points = pts,
			lo     = lo,
			hi     = hi,
			fg     = ink.fg,
			muted  = ink.muted,
			grid   = ink.grid,
			accent = ink.accent,
			bad    = ink.bad,
		}
		p.pixels(
			ui,
			"flex-1 w-full rounded-lg border border-border bg-card",
			&app.line_data,
			proc(c: ^p.Canvas, r: p.Rect, d: ^Line_Data) {
				draw_balance(c, p.rect_inset(r, 12), d)
			},
		)
	}
}

// ---------------------------------------------------------------------------
// Reconciliation
// ---------------------------------------------------------------------------

@(private = "file")
view_reconcile :: proc(ui: ^p.Ctx, app: ^App) {
	account := app.filter.account
	if account < 0 {
		assets := asset_list(app, context.temp_allocator)
		if len(assets) > 0 {
			account = assets[0]
		}
	}
	p.col(ui, "flex-1 w-full p-4 gap-4 overflow-scroll")
	defer p.end(ui)

	if account < 0 {
		empty_state(ui, sc.ICON_CREDIT_CARD, "Aucun compte", "Importez un relevé pour commencer.")
		return
	}
	res := recon_check(app, account)

	p.text(
		ui,
		fmt.tprintf("Rapprochement — %s", account_name(&app.led, account)),
		"text-base font-medium",
	)
	if !res.has_target {
		empty_state(
			ui,
			sc.ICON_BADGE_CHECK,
			"Aucun solde de relevé enregistré",
			"Un relevé OFX, CAMT.053 ou un CSV avec colonne de solde fournit son solde de clôture à l'import: rien à ressaisir.",
		)
		return
	}

	p.row(ui, "w-full gap-3")
	stat(ui, "Solde du relevé", money_text(res.target, true, context.temp_allocator), "")
	stat(ui, "Solde du livre", money_text(res.book, true, context.temp_allocator), "")
	stat(
		ui,
		"Écart",
		money_text(res.diff, true, context.temp_allocator),
		res.agrees ? "text-emerald-600" : "text-destructive",
	)
	stat(ui, "Au", date_text(res.as_of, context.temp_allocator), "")
	p.end(ui)

	p.row(
		ui,
		fmt.tprintf(
			"w-full items-center gap-3 p-3 rounded-lg border %s",
			res.agrees ? "border-emerald-600/40 bg-emerald-600/10" : "border-destructive/40 bg-destructive/10",
		),
	)
	p.icon(
		ui,
		res.agrees ? sc.ICON_CIRCLE_CHECK : sc.ICON_TRIANGLE_ALERT,
		fmt.tprintf("size-5 %s", res.agrees ? "text-emerald-600" : "text-destructive"),
	)
	p.col(ui, "flex-1 gap-0.5")
	p.text(
		ui,
		res.agrees ? "Le livre concorde avec le relevé" : "Le livre ne concorde pas",
		"text-sm font-medium",
	)
	p.text(
		ui,
		res.agrees \
		? fmt.tprintf("%d opérations jusqu'au %s, dont %d non pointées", res.counted, date_text(res.as_of, context.temp_allocator), res.uncleared) \
		: res.explain,
		"text-xs text-muted-foreground",
	)
	p.end(ui)
	if res.agrees && res.uncleared > 0 {
		p.row(
			ui,
			"items-center h-8 px-3 rounded-md bg-primary text-primary-foreground text-sm cursor-pointer shrink-0",
		)
		hit := p.clickable(ui)
		p.focusable(ui)
		act := p.activated(ui)
		p.text(ui, "Pointer  (X)", "")
		p.end(ui)
		if hit || act {
			if n, ok := recon_mark_cleared(app, account); ok {
				status(app, "%d opérations pointées", n)
			}
		}
	}
	p.end(ui)

	// The suspects, when there is a difference.
	if !res.agrees && res.suspect_a > 0 {
		p.text(ui, "Opérations susceptibles d'expliquer l'écart", "text-sm font-medium")
		for id in ([?]int{res.suspect_a, res.suspect_b}) {
			if id <= 0 {
				continue
			}
			t, ok := txn_get(&app.led, id)
			if !ok {
				continue
			}
			p.key(ui, fmt.tprintf("sus%d", id))
			p.row(ui, "w-full items-center gap-3 p-2 rounded-md border border-border bg-card")
			p.text(ui, date_text(t.date, context.temp_allocator), "text-xs tabular-nums text-muted-foreground")
			p.style(ui).w = p.px(COL_DATE)
			p.text(ui, t.label, "flex-1 text-sm truncate")
			p.text(
				ui,
				money_text(txn_amount(&app.led, t), true, context.temp_allocator),
				"text-sm tabular-nums font-medium text-right",
			)
			p.style(ui).w = p.px(COL_AMOUNT)
			p.end(ui)
		}
	}

	// What is still outstanding.
	open := recon_uncleared(app, account, context.temp_allocator)
	p.text(
		ui,
		fmt.tprintf("Non pointées (%d)", len(open)),
		"text-sm font-medium",
	)
	p.col(ui, "w-full gap-0")
	defer p.end(ui)
	shown := min(len(open), 14)
	for k in 0 ..< shown {
		t := &app.led.txns[open[k]]
		p.key(ui, fmt.tprintf("open%d", t.id))
		p.row(ui, "w-full items-center gap-3 px-2 h-8 border-b border-border/60")
		p.text(ui, date_text(t.date, context.temp_allocator), "text-xs tabular-nums text-muted-foreground")
		p.style(ui).w = p.px(COL_DATE)
		p.text(ui, t.label, "flex-1 text-sm truncate")
		p.text(
			ui,
			money_text(txn_amount(&app.led, t), true, context.temp_allocator),
			"text-sm tabular-nums text-right",
		)
		p.style(ui).w = p.px(COL_AMOUNT)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

@(private = "file")
status_bar :: proc(ui: ^p.Ctx, app: ^App) {
	p.row(ui, "w-full items-center gap-4 px-4 border-t border-border bg-muted/30 overflow-hidden")
	p.style(ui).h = p.px(STATUS_H)
	p.style(ui).shrink = 0
	defer p.end(ui)

	out, in_ := rows_total(app)
	p.text(
		ui,
		fmt.tprintf("%d / %d opérations", len(app.rows), txn_count(&app.led)),
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
	p.text(
		ui,
		fmt.tprintf("sorties %s", money_text(out, true, context.temp_allocator)),
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
	p.text(
		ui,
		fmt.tprintf("entrées %s", money_text(in_, true, context.temp_allocator)),
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
	p.text(
		ui,
		fmt.tprintf("net %s", money_text(in_ + out, true, context.temp_allocator)),
		fmt.tprintf(
			"text-xs tabular-nums whitespace-nowrap %s",
			in_ + out < 0 ? "text-destructive" : "text-emerald-600",
		),
	)
	p.spacer(ui)

	if app.status != "" {
		p.text(ui, app.status, "text-xs text-foreground truncate max-w-[460] shrink")
	}
	// The invariant, on screen. If this ever says anything else, the book has
	// a bug and the user should know before they trust a number on it.
	pb := ledger_check(&app.led)
	p.text(
		ui,
		pb.ok ? "partie double: équilibrée" : fmt.tprintf("DÉSÉQUILIBRE: %s", pb.what),
		fmt.tprintf(
			"text-xs tabular-nums whitespace-nowrap %s",
			pb.ok ? "text-muted-foreground" : "text-destructive",
		),
	)
	p.text(
		ui,
		fmt.tprintf("filtre %.2f ms", app.last_filter),
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

@(private = "file")
keys :: proc(ui: ^p.Ctx, app: ^App) {
	// A text field has the keyboard when it is focused; only the shortcuts
	// that cannot be typed are read here.
	typing := p.focus_id(ui) != 0 && p.typed_text(ui) != ""

	if p.shortcut(ui, 'o', {.Ctrl}) || p.shortcut(ui, 'O', {.Ctrl}) {
		open_import(app)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) || p.shortcut(ui, 'S', {.Ctrl}) {
		if store_save(app) {
			status(app, "enregistré dans %s", store_path(context.temp_allocator))
		} else {
			status(app, "impossible d'enregistrer")
		}
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(app.search) > 0 {
			clear(&app.search)
			refilter(app)
		} else {
			app.filter = Filter{account = app.filter.account, category = -1, range = .All}
			refilter(app)
		}
		p.set_focus(ui, 0)
		return
	}

	// Row movement. `key_count` rather than `key_pressed`: several presses
	// can arrive in one frame, and under synthetic input they always do, so
	// one tap must equal one step.
	down := p.key_count(ui, p.KEY_DOWN) + p.key_count(ui, 'j')
	up := p.key_count(ui, p.KEY_UP) + p.key_count(ui, 'k')
	if !typing {
		app.sel += down - up
		if p.key_count(ui, p.KEY_PAGE_DOWN) > 0 {
			app.sel += app.rows_visible
		}
		if p.key_count(ui, p.KEY_PAGE_UP) > 0 {
			app.sel -= app.rows_visible
		}
		if p.key_pressed(ui, p.KEY_HOME) || p.key_pressed(ui, 'g') {
			app.sel = 0
		}
		if p.key_pressed(ui, p.KEY_END) || p.key_pressed(ui, 'G') {
			app.sel = max(len(app.rows) - 1, 0)
		}
	}
	app.sel = clamp(app.sel, 0, max(len(app.rows) - 1, 0))

	if typing {
		return
	}

	// Views.
	for v in View {
		if p.key_pressed(ui, u32('1' + int(v))) {
			app.view = v
		}
	}
	if p.key_pressed(ui, '/') {
		clear(&app.search)
		app.focus_search = true
		refilter(app)
		status(app, "recherche: tapez, Échap pour effacer")
	}

	switch {
	case p.key_pressed(ui, 'c'):
		if app.view == .Transactions {
			if _, ok := selected_txn(app); ok {
				app.modal = .Category
				app.modal_sel = 0
				clear(&app.entry)
			}
		}
	case p.key_pressed(ui, 'u'):
		app.filter.only_todo = !app.filter.only_todo
		app.sel = 0
		refilter(app)
	case p.key_pressed(ui, 'd'):
		app.filter.range = Range((int(app.filter.range) + 1) % len(Range))
		app.sel = 0
		refilter(app)
	case p.key_pressed(ui, 'm'):
		cycle_method(app)
	case p.key_pressed(ui, 'a'):
		assets := asset_list(app, context.temp_allocator)
		if len(assets) > 0 {
			cur := -1
			for a, i in assets {
				if a == app.filter.account {
					cur = i
				}
			}
			app.filter.account = cur + 1 >= len(assets) ? -1 : assets[cur + 1]
			app.sel = 0
			refilter(app)
		}
	case p.key_pressed(ui, 't'):
		app.chart = 1 - app.chart
	case p.key_pressed(ui, '['):
		app.month = date_month_add(app.month, -1)
	case p.key_pressed(ui, ']'):
		app.month = date_month_add(app.month, 1)
	case p.key_pressed(ui, 'b'):
		if app.view == .Budgets || app.view == .Transactions {
			cat := budget_target(app)
			if cat >= 0 {
				app.modal = .Budget
				app.modal_cat = cat
				clear(&app.entry)
				if limit, _, ok := budget_limit(app, cat, app.month.y, app.month.m); ok {
					append(&app.entry, money_text(limit, false, context.temp_allocator))
				}
			} else {
				status(app, "sélectionnez une catégorie ou une opération catégorisée")
			}
		}
	case p.key_pressed(ui, 's'):
		// Suggest envelopes for every category with history.
		n := budget_suggest_all(app, app.month.y, app.month.m)
		app.dirty = true
		status(app, "%d enveloppes proposées depuis l'historique", n)
	case p.key_pressed(ui, 'x'):
		if app.view == .Reconcile {
			account := app.filter.account
			if account < 0 {
				assets := asset_list(app, context.temp_allocator)
				if len(assets) > 0 {
					account = assets[0]
				}
			}
			if n, ok := recon_mark_cleared(app, account); ok {
				status(app, "%d opérations pointées", n)
			} else {
				status(app, "pointage refusé: le livre ne concorde pas avec le relevé")
			}
		}
	case p.key_pressed(ui, 'r'):
		n := rules_reapply(app)
		status(app, "%d opérations recatégorisées par les règles", n)
	case p.key_pressed(ui, '?'):
		app.modal = .Help
	case p.key_pressed(ui, 'p'):
		if len(app.profiles) > 0 {
			app.modal = .Mapping
			app.modal_prof = 0
			app.modal_sel = 0
		} else {
			status(app, "aucune cartographie bancaire enregistrée pour l'instant")
		}
	}
}

// budget_target is the category an envelope command applies to: the selected
// budget line in the budget view, or the selected transaction's category in
// the list.
@(private = "file")
budget_target :: proc(app: ^App) -> int {
	if app.view == .Budgets {
		lines := budget_month(app, app.month.y, app.month.m)
		if len(lines) > 0 {
			return lines[clamp(app.sel, 0, len(lines) - 1)].category
		}
		// No envelope yet: offer the biggest spend category.
		tops := spend_by_category(
			&app.led,
			month_start(app.month),
			month_end(app.month),
			context.temp_allocator,
		)
		if len(tops) > 0 {
			return tops[0].account
		}
		return -1
	}
	if t, ok := selected_txn(app); ok {
		return txn_category(&app.led, t)
	}
	return -1
}

@(private = "file")
cycle_method :: proc(app: ^App) {
	if !app.filter.by_method {
		app.filter.by_method = true
		app.filter.method = .Card
	} else if int(app.filter.method) + 1 >= len(Method) {
		app.filter.by_method = false
		app.filter.method = .Unknown
	} else {
		app.filter.method = Method(int(app.filter.method) + 1)
	}
	app.sel = 0
	refilter(app)
}

// ---------------------------------------------------------------------------
// Modals — drawn inside the window, because palmy has no xdg_popup
// ---------------------------------------------------------------------------

@(private = "file")
modal_keys :: proc(ui: ^p.Ctx, app: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		app.modal = .None
		clear(&app.entry)
		return
	}
	switch app.modal {
	case .Category:
		list := category_matches(app, context.temp_allocator)
		app.modal_sel += p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP)
		app.modal_sel = clamp(app.modal_sel, 0, max(len(list) - 1, 0))
		if p.key_pressed(ui, p.KEY_RETURN) && len(list) > 0 {
			if categorise_selected(app, list[app.modal_sel]) {
				status(
					app,
					"catégorisé en «%s» — la règle est apprise pour ce marchand",
					account_name(&app.led, list[app.modal_sel]),
				)
			}
			app.modal = .None
			clear(&app.entry)
		}
	case .Budget:
		if p.key_pressed(ui, p.KEY_RETURN) {
			commit_budget(app)
		}
	case .Mapping:
		// Tab moves between banks, Up/Down between the fields of one, and
		// Left/Right changes which column a field reads. That is the whole
		// editor: a CSV mapping is eight small integers, and anything more
		// elaborate would be in the way.
		if len(app.profiles) == 0 {
			break
		}
		if p.key_pressed(ui, p.KEY_TAB) {
			app.modal_prof = (app.modal_prof + 1) % len(app.profiles)
			app.modal_sel = 0
		}
		fields := mapping_fields(&app.profiles[app.modal_prof])
		app.modal_sel = clamp(
			app.modal_sel + p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP),
			0,
			len(fields) - 1,
		)
		step := p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT)
		if step != 0 {
			col := fields[app.modal_sel].col
			// -1 is "this bank has no such column", and it sits just below
			// column 0 rather than being a separate mode.
			col^ = clamp(col^ + step, -1, MAPPING_MAX_COL)
			app.profiles[app.modal_prof].learned = true
			app.dirty = true
		}
		for d in 0 ..= 9 {
			if p.key_pressed(ui, u32('0' + d)) {
				fields[app.modal_sel].col^ = d
				app.profiles[app.modal_prof].learned = true
				app.dirty = true
			}
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			status(
				app,
				"cartographie «%s» enregistrée: les prochains fichiers de cette banque la réutiliseront",
				app.profiles[app.modal_prof].name,
			)
			app.modal = .None
		}
	case .Account, .Help, .None:
		if p.key_pressed(ui, p.KEY_RETURN) {
			app.modal = .None
		}
	}
}

@(private = "file")
commit_budget :: proc(app: ^App) {
	text := strings.trim_space(string(app.entry[:]))
	if text == "" {
		budget_set(app, app.modal_cat, app.month.y, app.month.m, 0)
		status(app, "enveloppe supprimée")
	} else if v, ok := money_parse(text); ok && v > 0 {
		budget_set(app, app.modal_cat, app.month.y, app.month.m, v, true)
		status(
			app,
			"enveloppe «%s» fixée à %s pour %s",
			account_name(&app.led, app.modal_cat),
			money_text(v, true, context.temp_allocator),
			month_text(app.month.y, app.month.m, context.temp_allocator),
		)
	} else {
		status(app, "montant illisible: «%s»", text)
		return
	}
	app.dirty = true
	app.modal = .None
	clear(&app.entry)
}

// category_matches filters the category list by whatever has been typed,
// which is what makes the picker usable with forty categories.
@(private = "file")
category_matches :: proc(app: ^App, allocator := context.temp_allocator) -> []int {
	needle := strings.trim_space(string(app.entry[:]))
	out := make([dynamic]int, allocator)
	for c in category_list(app, context.temp_allocator) {
		if needle == "" || ascii_fold_contains(app.led.accounts[c].name, needle) {
			append(&out, c)
		}
	}
	return out[:]
}

@(private = "file")
draw_modal :: proc(ui: ^p.Ctx, app: ^App, size: [2]f32) {
	// The scrim. The colour is set directly rather than through a class: a
	// modal has to dim what is behind it by a definite amount, and this is
	// one place where naming the alpha is clearer than a utility.
	p.div(ui, "absolute inset-0 z-40")
	p.style(ui).bg = p.flat(p.Color{0, 0, 0, 110})
	if p.clickable(ui) {
		app.modal = .None
	}
	p.end(ui)

	p.col(ui, "absolute z-50 rounded-xl border border-border bg-popover shadow-2xl overflow-hidden")
	defer p.end(ui)
	w := min(size.x - 80, 560)
	h := min(size.y - 100, app.modal == .Help ? 520 : 440)
	p.style(ui).w = p.px(w)
	p.style(ui).h = p.px(h)
	p.style(ui).inset[p.LEFT] = p.px((size.x - w) / 2)
	p.style(ui).inset[p.TOP] = p.px((size.y - h) / 2)

	switch app.modal {
	case .Category:
		modal_category(ui, app)
	case .Budget:
		modal_budget(ui, app)
	case .Mapping:
		modal_mapping(ui, app)
	case .Help:
		modal_help(ui, app)
	case .Account, .None:
		app.modal = .None
	}
}

@(private = "file")
modal_head :: proc(ui: ^p.Ctx, title, subtitle: string) {
	p.col(ui, "w-full gap-1 px-4 pt-4 pb-3 border-b border-border")
	defer p.end(ui)
	p.text(ui, title, "text-base font-semibold")
	if subtitle != "" {
		p.text(ui, subtitle, "text-xs text-muted-foreground")
	}
}

@(private = "file")
modal_category :: proc(ui: ^p.Ctx, app: ^App) {
	t, ok := selected_txn(app)
	if !ok {
		app.modal = .None
		return
	}
	amount := txn_amount(&app.led, t)
	sug := suggest_category(&app.led, &app.cat, t.label, t.method, amount)

	modal_head(
		ui,
		"Catégoriser",
		fmt.tprintf("%s — %s", t.label, money_text(amount, true, context.temp_allocator)),
	)

	p.row(ui, "w-full items-center gap-2 px-4 py-2 border-b border-border")
	p.icon(ui, sc.ICON_SEARCH, "size-4 text-muted-foreground")
	changed, _ := p.text_field(ui, &app.entry, "Filtrer les catégories…", "flex-1 h-7 bg-transparent border-0 text-sm")
	if changed {
		app.modal_sel = 0
	}
	p.end(ui)

	if sug.category >= 0 {
		p.row(ui, "w-full items-center gap-2 px-4 py-2 bg-accent/40")
		p.icon(ui, sc.ICON_STAR, "size-3.5 text-amber-600")
		p.text(
			ui,
			fmt.tprintf(
				"suggestion: %s (%s%s)",
				account_name(&app.led, sug.category),
				sug.from,
				sug.count > 0 ? fmt.tprintf(", %d opérations", sug.count) : "",
			),
			"text-xs text-muted-foreground",
		)
		p.end(ui)
	}

	list := category_matches(app, context.temp_allocator)
	p.col(ui, "flex-1 w-full p-2 gap-0.5 overflow-scroll")
	defer p.end(ui)
	for c, i in list {
		selected := i == app.modal_sel
		p.key(ui, fmt.tprintf("cat%d", c))
		p.row(
			ui,
			fmt.tprintf(
				"w-full items-center gap-2 px-3 py-2 rounded-md cursor-pointer %s",
				selected ? "bg-accent" : "hover:bg-accent/50",
			),
		)
		if p.clickable(ui) {
			if categorise_selected(app, c) {
				status(app, "catégorisé en «%s»", account_name(&app.led, c))
			}
			app.modal = .None
			clear(&app.entry)
		}
		p.div(ui, "size-2.5 rounded-full shrink-0")
		p.style(ui).bg = p.flat(tint_of(app.led.accounts[c].tint))
		p.end(ui)
		p.text(ui, app.led.accounts[c].name, "flex-1 text-sm truncate")
		p.text(
			ui,
			app.led.accounts[c].kind == .Income ? "recette" : "dépense",
			"text-xs text-muted-foreground",
		)
		p.end(ui)
	}
}

@(private = "file")
modal_budget :: proc(ui: ^p.Ctx, app: ^App) {
	cat := app.modal_cat
	modal_head(
		ui,
		fmt.tprintf("Enveloppe — %s", account_name(&app.led, cat)),
		fmt.tprintf(
			"pour %s. Vide pour supprimer l'enveloppe.",
			month_text(app.month.y, app.month.m, context.temp_allocator),
		),
	)

	p.col(ui, "flex-1 w-full p-4 gap-3")
	defer p.end(ui)

	p.text(ui, "Montant mensuel", "text-xs uppercase tracking-wide text-muted-foreground")
	p.text_field(ui, &app.entry, "300,00", "w-full h-10 text-base tabular-nums")

	spent, count := category_spent(app, cat, app.month.y, app.month.m)
	p.text(
		ui,
		fmt.tprintf(
			"déjà dépensé ce mois: %s sur %d opérations",
			money_text(spent, true, context.temp_allocator),
			count,
		),
		"text-xs text-muted-foreground tabular-nums",
	)
	if s := budget_suggest(app, cat, app.month.y, app.month.m); s > 0 {
		p.row(ui, "items-center gap-2")
		p.text(
			ui,
			fmt.tprintf("suggestion depuis l'historique: %s", money_text(s, true, context.temp_allocator)),
			"text-xs text-muted-foreground tabular-nums",
		)
		p.row(ui, "items-center h-7 px-2 rounded-md border border-border text-xs cursor-pointer hover:bg-accent")
		if p.clickable(ui) {
			clear(&app.entry)
			append(&app.entry, money_text(s, false, context.temp_allocator))
		}
		p.text(ui, "utiliser", "")
		p.end(ui) // the "utiliser" button
		p.end(ui) // the suggestion row
	}

	p.spacer(ui)

	p.row(ui, "w-full items-center gap-2")
	defer p.end(ui)
	p.text(ui, "Entrée valide, Échap annule", "text-xs text-muted-foreground")
	p.spacer(ui)
	p.row(ui, "items-center h-9 px-4 rounded-md bg-primary text-primary-foreground text-sm cursor-pointer")
	hit := p.clickable(ui)
	p.focusable(ui)
	act := p.activated(ui)
	p.text(ui, "Enregistrer", "")
	p.end(ui)
	if hit || act {
		commit_budget(app)
	}
}

// MAPPING_MAX_COL bounds the column index an editor can reach. No bank
// export this importer has met has more than a couple of dozen columns, and
// an unbounded spinner is just a way to get lost.
MAPPING_MAX_COL :: 31

Mapping_Field :: struct {
	name: string,
	col:  ^int,
}

// mapping_fields is the editable part of a profile: which column plays which
// role. Pointers, so the editor writes straight into the stored profile.
mapping_fields :: proc(pr: ^Bank_Profile) -> [8]Mapping_Field {
	return [8]Mapping_Field {
		{"Date", &pr.col_date},
		{"Libellé", &pr.col_label},
		{"Libellé (suite)", &pr.col_label2},
		{"Montant signé", &pr.col_amount},
		{"Débit", &pr.col_debit},
		{"Crédit", &pr.col_credit},
		{"Solde", &pr.col_balance},
		{"Référence", &pr.col_ref},
	}
}

@(private = "file")
modal_mapping :: proc(ui: ^p.Ctx, app: ^App) {
	modal_head(
		ui,
		"Cartographies bancaires",
		"Une par en-tête de fichier. La première importation d'une banque la déduit; les suivantes la réutilisent. Tab: banque · ↑↓: champ · ←→ ou 0-9: colonne · Entrée: enregistrer.",
	)
	p.col(ui, "flex-1 w-full p-3 gap-2 overflow-scroll")
	defer p.end(ui)

	if len(app.profiles) == 0 {
		p.text(
			ui,
			"Aucune cartographie pour l'instant: importez un CSV et elle sera déduite puis gardée.",
			"text-sm text-muted-foreground",
		)
		return
	}
	app.modal_prof = clamp(app.modal_prof, 0, len(app.profiles) - 1)
	pr := &app.profiles[app.modal_prof]

	p.row(ui, "w-full items-center gap-2")
	p.text(ui, pr.name, "text-sm font-medium flex-1 truncate")
	sc.badge(ui, pr.learned ? "réglée" : "déduite", pr.learned ? .Default : .Secondary)
	sc.badge(ui, fmt.tprintf("%d / %d", app.modal_prof + 1, len(app.profiles)), .Outline)
	p.end(ui)
	p.text(ui, pr.fingerprint, "text-xs text-muted-foreground truncate")
	p.text(
		ui,
		fmt.tprintf(
			"délimiteur %q · %d ligne(s) de préambule · date %s · décimale %s",
			rune(pr.delim),
			pr.skip,
			pr.date_fmt == .YMD ? "aaaa-mm-jj" : "jj/mm/aaaa",
			pr.decimal == .Dot ? "point" : "virgule",
		),
		"text-xs text-muted-foreground",
	)

	fields := mapping_fields(pr)
	for f, i in fields {
		selected := i == app.modal_sel
		p.key(ui, f.name)
		p.row(
			ui,
			fmt.tprintf(
				"w-full items-center gap-3 px-3 h-9 rounded-md cursor-pointer %s",
				selected ? "bg-accent" : "hover:bg-accent/50",
			),
		)
		if p.clickable(ui) {
			app.modal_sel = i
		}
		p.text(ui, f.name, "flex-1 text-sm truncate")
		if f.col^ < 0 {
			p.text(ui, "absente", "text-xs text-muted-foreground tabular-nums")
		} else {
			p.text(
				ui,
				fmt.tprintf("colonne %d", f.col^),
				"text-sm tabular-nums font-medium",
			)
		}
		p.end(ui)
	}

	if !profile_complete(pr^) {
		p.text(
			ui,
			"Incomplète: il faut au minimum une date, un libellé et soit un montant signé, soit un couple débit/crédit.",
			"text-xs text-destructive",
		)
	}
}

HELP_KEYS := [?][2]string {
	{"1 … 5", "changer de vue"},
	{"j / k, ↓ / ↑", "parcourir la liste"},
	{"g / G", "début / fin"},
	{"Ctrl+O", "importer un relevé (CSV, OFX/QFX, CAMT.053)"},
	{"Ctrl+S", "enregistrer"},
	{"c", "catégoriser l'opération sélectionnée"},
	{"u", "n'afficher que ce qui reste à catégoriser"},
	{"d", "faire défiler les périodes"},
	{"m", "filtrer par type (CB, PRLV, VIR, CHQ, RETRAIT…)"},
	{"a", "changer de compte"},
	{"r", "réappliquer les règles de catégorisation"},
	{"b", "fixer l'enveloppe de la catégorie"},
	{"s", "proposer des enveloppes depuis l'historique"},
	{"[ / ]", "mois précédent / suivant"},
	{"t", "basculer de graphique"},
	{"x", "pointer le rapprochement"},
	{"p", "voir les cartographies bancaires"},
	{"Échap", "effacer la recherche et les filtres"},
	{"?", "cette aide"},
}

@(private = "file")
modal_help :: proc(ui: ^p.Ctx, app: ^App) {
	modal_head(
		ui,
		"Raccourcis",
		"Aucune connexion bancaire: les relevés sont des fichiers que vous choisissez.",
	)
	p.col(ui, "flex-1 w-full p-3 gap-0.5 overflow-scroll")
	defer p.end(ui)
	for row in HELP_KEYS {
		p.row(ui, "w-full items-center gap-3 px-2 py-1.5 rounded-md")
		p.text(ui, row[0], "text-xs font-mono text-muted-foreground min-w-[120]")
		p.text(ui, row[1], "flex-1 text-sm truncate")
		p.end(ui)
	}
	p.div(ui, "h-2")
	p.end(ui) // the spacer box
	p.text(
		ui,
		fmt.tprintf("Données: %s", store_path(context.temp_allocator)),
		"text-xs text-muted-foreground px-2 truncate",
	)
	_ = app
}

// ---------------------------------------------------------------------------
// Importing
// ---------------------------------------------------------------------------

IMPORT_FILTERS := [?]kit.Pick_Filter {
	{"Relevés bancaires", {"csv", "tsv", "ofx", "qfx", "xml"}},
	{"CSV", {"csv", "tsv"}},
	{"OFX / QFX", {"ofx", "qfx"}},
	{"CAMT.053 (XML)", {"xml"}},
	{"Tous les fichiers", nil},
}

open_import :: proc(app: ^App) {
	kit.pick_begin(
		&app.pick,
		.Open_File,
		{
			title = "Importer un relevé",
			confirm = "Importer",
			filters = IMPORT_FILTERS[:],
			dir = app.start_dir,
		},
	)
}

// do_import books a file the user picked. Nothing else in this program opens
// a file in the user's home directory.
do_import :: proc(app: ^App, path: string) {
	rep, ok := import_book(app, path, import_account(app))
	if !ok && rep.added == 0 {
		status(app, "échec de l'import: %s", rep.problem != "" ? rep.problem : "aucune opération lue")
		return
	}
	if rep.rows_bad > 0 {
		status(
			app,
			"%s: %d ajoutées, %d doublons, %d catégorisées, %d lignes refusées",
			format_name(rep.format),
			rep.added,
			rep.duplicates,
			rep.categorised,
			rep.rows_bad,
		)
	} else {
		status(
			app,
			"%s: %d ajoutées, %d doublons, %d catégorisées",
			format_name(rep.format),
			rep.added,
			rep.duplicates,
			rep.categorised,
		)
	}
}
