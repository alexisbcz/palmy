// Application state, and the filter that answers every question the
// transaction list asks.
//
// There is no index and no query planner here, and that is a measurement
// rather than an omission: filtering a few thousand transactions by date,
// amount, category, account and a substring of the label is a single linear
// pass over an array of structs, and `money --bench` reports what it costs.
// At the sizes a personal account reaches — a decade of statements is around
// twenty thousand rows — the pass is well under a millisecond, so the list
// re-filters on every keystroke and there is nothing to invalidate.
package main

import "core:fmt"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

View :: enum {
	Transactions,
	Budgets,
	Recurring,
	Charts,
	Reconcile,
}

view_title :: proc(v: View) -> string {
	switch v {
	case .Transactions:
		return "Opérations"
	case .Budgets:
		return "Budgets"
	case .Recurring:
		return "Récurrents"
	case .Charts:
		return "Graphiques"
	case .Reconcile:
		return "Rapprochement"
	}
	return ""
}

Modal :: enum {
	None,
	Category, // pick a category for the selected transaction
	Budget, // type an envelope amount
	Mapping, // adjust a bank's CSV column mapping
	Account, // add an account
	Help,
}

Range :: enum {
	All,
	This_Month,
	Last_Month,
	Last_90,
	This_Year,
	Custom,
}

range_label :: proc(r: Range) -> string {
	switch r {
	case .All:
		return "tout"
	case .This_Month:
		return "ce mois"
	case .Last_Month:
		return "mois dernier"
	case .Last_90:
		return "90 jours"
	case .This_Year:
		return "cette année"
	case .Custom:
		return "période"
	}
	return ""
}

Filter :: struct {
	account:   int, // -1: every account
	category:  int, // -1: every category
	method:    Method,
	by_method: bool,
	range:     Range,
	lo:        Date,
	hi:        Date,
	min:       Cents,
	max:       Cents,
	by_min:    bool,
	by_max:    bool,
	only_todo: bool, // uncategorised only
	only_open: bool, // not reconciled
}

App :: struct {
	fonts:        ^p.Fonts,
	led:          Ledger,
	cat:          Catalog,
	budgets:      [dynamic]Budget,
	recon:        [dynamic]Recon_Target,
	profiles:     [dynamic]Bank_Profile,
	today:        Date,
	dirty:        bool,

	// --- view -----------------------------------------------------------
	view:         View,
	filter:       Filter,
	search:       [dynamic]u8,
	rows:         [dynamic]int, // filtered transaction indexes, newest first
	sel:          int, // index into rows
	scroll:       f32,
	rows_visible: int,
	month:        Date, // which month the budget and chart views show
	chart:        int, // 0 spend by category, 1 balance over time
	status:       string,
	status_at:    f64,
	last_filter:  f64, // how long the last filter pass took, in milliseconds

	// --- modals ---------------------------------------------------------
	modal:        Modal,
	modal_sel:    int,
	entry:        [dynamic]u8, // the modal's text field
	modal_cat:    int, // which category the budget modal is editing
	modal_prof:   int, // which profile the mapping modal is editing
	focus_search: bool, // `/` was pressed; the header hands the field focus
	pick:         kit.Pick,

	// Chart data lives in the model, not on a frame's stack.
	//
	// `p.pixels` borrows its user pointer until the frame is *painted*, which
	// happens after the whole tree has been built — so a struct declared in
	// the drawing procedure is dangling by then and the painter reads freed
	// stack. It segfaults, and it segfaults later than the mistake, which is
	// why these live here.
	bars:         Bars_Data,
	line_data:    Line_Data,
	gauges:       [dynamic]Gauge_Data,
	// Where the import dialog opens. Empty means the dialog's own default
	// (the home directory, or wherever it was last). Set only by
	// `--start-dir`, which exists so a demo recording can point at the
	// fixtures without this program ever going looking for statements.
	start_dir:    string,
	recs:         []Recurrence,
	recs_stale:   bool,
}

app_init :: proc(app: ^App) {
	ledger_init(&app.led)
	catalog_init(&app.cat)
	app.budgets = make([dynamic]Budget)
	app.recon = make([dynamic]Recon_Target)
	app.profiles = make([dynamic]Bank_Profile)
	app.search = make([dynamic]u8)
	app.entry = make([dynamic]u8)
	app.rows = make([dynamic]int)
	app.gauges = make([dynamic]Gauge_Data)
	app.today = today_date()
	app.month = month_start(app.today)
	app.filter = Filter {
		account   = -1,
		category  = -1,
		range     = .All,
		by_method = false,
	}
	app.sel = 0
	app.recs_stale = true
	app.status = strings.clone("")
}

app_destroy :: proc(app: ^App) {
	ledger_destroy(&app.led)
	catalog_destroy(&app.cat)
	delete(app.budgets)
	delete(app.recon)
	for pr in app.profiles {
		delete(pr.name)
		delete(pr.fingerprint)
	}
	delete(app.profiles)
	delete(app.search)
	delete(app.entry)
	delete(app.rows)
	delete(app.gauges)
	delete(app.status)
	recs_free(app)
	kit.pick_destroy(&app.pick)
}

today_date :: proc() -> Date {
	now := time.now()
	y, m, d := time.date(now)
	return Date{y, int(m), d}
}

status :: proc(app: ^App, format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
	app.status_at = 0
	app.dirty = true
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

// ascii_fold_contains is a case-insensitive substring test over the ASCII
// range, which is what a bank label is. It does not allocate, which is why
// the search can run over every transaction on every keystroke.
ascii_fold_contains :: proc(haystack, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	fold :: proc(c: u8) -> u8 {
		return c >= 'a' && c <= 'z' ? c - 32 : c
	}
	n0 := fold(needle[0])
	outer: for i in 0 ..= len(haystack) - len(needle) {
		if fold(haystack[i]) != n0 {
			continue
		}
		for k in 1 ..< len(needle) {
			if fold(haystack[i + k]) != fold(needle[k]) {
				continue outer
			}
		}
		return true
	}
	return false
}

// filter_dates resolves a named range into two dates.
filter_dates :: proc(app: ^App) -> (lo, hi: Date, bounded: bool) {
	switch app.filter.range {
	case .All:
		return {}, {}, false
	case .This_Month:
		return month_start(app.today), month_end(app.today), true
	case .Last_Month:
		prev := date_month_add(app.today, -1)
		return month_start(prev), month_end(prev), true
	case .Last_90:
		return date_add(app.today, -89), app.today, true
	case .This_Year:
		return Date{app.today.y, 1, 1}, Date{app.today.y, 12, 31}, true
	case .Custom:
		return app.filter.lo, app.filter.hi, true
	}
	return {}, {}, false
}

// txn_matches is the whole predicate, in one place, so the list, the charts
// and the export cannot disagree about what is being shown.
txn_matches :: proc(app: ^App, t: ^Txn, needle: string, lo, hi: Date, bounded: bool) -> bool {
	l := &app.led
	if t.dead {
		return false
	}
	if bounded && !date_within(t.date, lo, hi) {
		return false
	}
	if app.filter.account >= 0 {
		found := false
		for e in t.entries {
			if e.account == app.filter.account {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	if app.filter.category >= 0 {
		found := false
		for e in t.entries {
			if e.account == app.filter.category {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	if app.filter.by_method && t.method != app.filter.method {
		return false
	}
	amount := txn_amount(l, t)
	mag := money_abs(amount)
	if app.filter.by_min && mag < app.filter.min {
		return false
	}
	if app.filter.by_max && mag > app.filter.max {
		return false
	}
	if app.filter.only_todo {
		// "To categorise" means the money is still sitting on the holding
		// account. A transaction a rule has already placed is categorised —
		// the user can disagree with it, but it is not outstanding work —
		// and neither a transfer nor an opening balance is work at all.
		if txn_category(l, t) >= 0 || txn_is_transfer(l, t) {
			return false
		}
		waiting := false
		for e in t.entries {
			if e.account == l.unallocated {
				waiting = true
			}
		}
		if !waiting {
			return false
		}
	}
	if app.filter.only_open && t.cleared {
		return false
	}
	if needle != "" {
		if ascii_fold_contains(t.label, needle) {
			return true
		}
		if t.note != "" && ascii_fold_contains(t.note, needle) {
			return true
		}
		// Searching for a category name is the other thing a person types.
		for e in t.entries {
			if ascii_fold_contains(l.accounts[e.account].name, needle) {
				return true
			}
		}
		// And an amount: `42,10` or `42.10` both find it.
		if v, ok := money_parse(needle); ok && mag == money_abs(v) {
			return true
		}
		return false
	}
	return true
}

// refilter rebuilds the visible list and times itself. The timing is reported
// by `--bench` and shown in the status bar, because a search box that is
// quietly slow is how an application becomes unpleasant without anyone
// deciding to make it so.
refilter :: proc(app: ^App) {
	start := time.now()
	needle := strings.trim_space(string(app.search[:]))
	lo, hi, bounded := filter_dates(app)
	clear(&app.rows)
	l := &app.led
	for &t, i in l.txns {
		if txn_matches(app, &t, needle, lo, hi, bounded) {
			append(&app.rows, i)
		}
	}
	sort_by_date(l, app.rows[:], true)
	app.last_filter = time.duration_milliseconds(time.since(start))
	if app.sel >= len(app.rows) {
		app.sel = max(0, len(app.rows) - 1)
	}
}

// rows_total is the sum of what is currently shown, which is the number a
// person actually wants when they filter to a merchant or a month.
rows_total :: proc(app: ^App) -> (out, in_: Cents) {
	l := &app.led
	for i in app.rows {
		a := txn_amount(l, &l.txns[i])
		if a < 0 {
			out += a
		} else {
			in_ += a
		}
	}
	return
}

selected_txn :: proc(app: ^App) -> (t: ^Txn, ok: bool) {
	if app.sel < 0 || app.sel >= len(app.rows) {
		return nil, false
	}
	return &app.led.txns[app.rows[app.sel]], true
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

// ensure_categories creates an account for every category the rule table can
// produce, so the category picker is populated before anything is imported.
ensure_categories :: proc(app: ^App) {
	for name in catalog_categories(&app.cat, context.temp_allocator) {
		income :=
			name == "Salaire" ||
			name == "Allocations" ||
			name == "Remboursements" ||
			name == "Revenus"
		account_get_or_add(&app.led, name, income ? .Income : .Expense)
	}
}

// category_list is every category account, expenses then income, in name
// order — the list the picker shows.
category_list :: proc(app: ^App, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for a, i in app.led.accounts {
		if a.kind == .Expense {
			append(&out, i)
		}
	}
	for a, i in app.led.accounts {
		if a.kind == .Income {
			append(&out, i)
		}
	}
	return out[:]
}

asset_list :: proc(app: ^App, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for a, i in app.led.accounts {
		if a.kind == .Asset && !a.archived {
			append(&out, i)
		}
	}
	return out[:]
}

// categorise_selected is the one action in the application that teaches it
// something: the category is applied and the merchant key becomes a learned
// rule, so the next statement arrives already sorted.
categorise_selected :: proc(app: ^App, category: int) -> bool {
	t, ok := selected_txn(app)
	if !ok {
		return false
	}
	return categorise_txn(app, t.id, category)
}

// categorise_txn is that action on a transaction named by its id, which is
// how the command line reaches it (`money categorize ID CATEGORY`). The
// window's picker goes through here too, so the rule learned from a choice
// is the same whichever front end made it.
categorise_txn :: proc(app: ^App, id: int, category: int) -> bool {
	t, ok := txn_get(&app.led, id)
	if !ok {
		return false
	}
	label := strings.clone(t.label, context.temp_allocator)
	if !txn_categorise(&app.led, id, category) {
		return false
	}
	catalog_learn(&app.cat, label, account_name(&app.led, category))
	app.dirty = true
	app.recs_stale = true
	refilter(app)
	return true
}

// rules_reapply runs the rule table over the book again — the `r` key, and
// `money apply-rules`.
rules_reapply :: proc(app: ^App) -> int {
	n := apply_rules(&app.led, &app.cat)
	app.recs_stale = true
	if n > 0 {
		app.dirty = true
	}
	refilter(app)
	return n
}

// budget_suggest_all proposes an envelope for every expense category with
// history that has none this month — the `s` key, and `money budget-suggest`.
budget_suggest_all :: proc(app: ^App, y, m: int) -> (n: int) {
	for c in category_list(app, context.temp_allocator) {
		if app.led.accounts[c].kind != .Expense {
			continue
		}
		if _, _, exists := budget_limit(app, c, y, m); exists {
			continue
		}
		if s := budget_suggest(app, c, y, m); s > 0 {
			budget_set(app, c, y, m, s, true)
			n += 1
		}
	}
	if n > 0 {
		app.dirty = true
	}
	return n
}

// import_account is the account a statement without a recognisable IBAN is
// booked into: the one the list is filtered to, else the first bank account.
import_account :: proc(app: ^App) -> int {
	account := app.filter.account
	if account < 0 {
		assets := asset_list(app, context.temp_allocator)
		account = len(assets) > 0 ? assets[0] : -1
	}
	return account
}

// import_book is the whole of an import as both front ends run it: book the
// file, then bring the derived state (recurrences, the visible list) up to
// date. The window adds a status line; the command line prints the report.
import_book :: proc(app: ^App, path: string, account: int) -> (rep: Import_Report, ok: bool) {
	rep, ok = import_file(app, path, account)
	app.recs_stale = true
	app.sel = 0
	refilter(app)
	if ok || rep.added > 0 {
		app.dirty = true
	}
	return
}

// recurrences keeps the detection result for the frame, recomputed only when
// the book has changed. The scan is O(n) with a sort per merchant group, so
// running it every frame over a decade of statements would be the one thing
// in this application that could drop a frame.
recurrences :: proc(app: ^App) -> []Recurrence {
	if app.recs_stale || app.recs == nil {
		recs_free(app)
		app.recs = find_recurrences(&app.led, app.today, context.allocator)
		app.recs_stale = false
	}
	return app.recs
}

// recs_free releases the previous scan. The strings and index slices are
// owned by the result, so recomputing without this would leak a copy of every
// merchant key each time a transaction was edited.
recs_free :: proc(app: ^App) {
	for r in app.recs {
		delete(r.key)
		delete(r.label)
		delete(r.txns)
	}
	delete(app.recs)
	app.recs = nil
}
