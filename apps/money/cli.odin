package main

// The command-line front end of Money.
//
// Nothing below re-implements anything. A book is read with `store_load_from`
// and written with `store_save_to`, the same reader and writer the window uses
// for its own store; the list is filtered by `refilter`/`txn_matches`, the
// one predicate the window's list and charts use; an import is `import_book`,
// categorising is `categorise_txn`, the rules are `rules_reapply`, envelopes
// are `budget_set`/`budget_suggest_all` and `budget_month` — each of them the
// procedure a key or a dialog in the window calls. Two front ends over one
// book cannot disagree about what is in it.
//
// Every command names its book — the reads as their first argument
// (`money accounts BOOK`), the commands that change one with --book. There is
// deliberately no default: a read run blind (which is how `palm --selftest`
// checks the surface) must not open anybody's real accounts, so the only way
// to reach the window's own store is to say so, with `default`. The examples point at the
// fictitious book committed in apps/money/testdata/, which `money demo`
// writes.
//
// The older spellings — `--import FILE`, `--fixtures DIR`, `--shot`,
// `--bench`, `--start-dir DIR` and a bare FILE to import at startup — are
// still accepted by main.odin exactly as before.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

DEMO_BOOK :: "apps/money/testdata/demo.money"

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "accounts",
		summary = "the bank accounts in a book, with their balances",
		effect = .Read,
		args = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		flags = {
			{name = "all", kind = .Bool, help = "categories and equity accounts too, not only bank accounts"},
		},
		out = {
			{name = "book", kind = .String},
			{name = "accounts", kind = .Array, of = {
				{name = "name", kind = .String},
				{name = "kind", kind = .String, help = "asset, expense, income or equity"},
				{name = "iban", kind = .String},
				{name = "bank", kind = .String},
				{name = "balance", kind = .Int, help = "in cents"},
				{name = "balance_text", kind = .String},
				{name = "entries", kind = .Int},
				{name = "archived", kind = .Bool},
			}},
			{name = "assets_total", kind = .Int, help = "in cents"},
			{name = "transactions", kind = .Int},
			{name = "balanced", kind = .Bool, help = "the double-entry check over the whole book"},
		},
		examples = {"money accounts apps/money/testdata/demo.money --json", "money accounts default"},
		run = cmd_accounts,
	},
	{
		verb = "transactions",
		summary = "transactions, newest first, through the window's own filter",
		effect = .Read,
		aliases = {"list"},
		args = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		flags = {
			{name = "account", kind = .String, help = "only this bank account, by name"},
			{name = "category", kind = .String, help = "only this category, by name"},
			{name = "match", kind = .String, help = "the search box: label, note, category or amount"},
			{name = "from", kind = .String, help = "first date, YYYY-MM-DD"},
			{name = "to", kind = .String, help = "last date, YYYY-MM-DD"},
			{name = "todo", kind = .Bool, help = "only what is still uncategorised"},
			{name = "limit", kind = .Int, help = "at most this many, 0 for all", def = "0"},
		},
		out = {
			{name = "count", kind = .Int, help = "how many matched, before --limit"},
			{name = "total_out", kind = .Int, help = "in cents, negative"},
			{name = "total_in", kind = .Int, help = "in cents"},
			{name = "transactions", kind = .Array, of = {
				{name = "id", kind = .Int},
				{name = "date", kind = .String},
				{name = "label", kind = .String},
				{name = "amount", kind = .Int, help = "in cents, signed"},
				{name = "amount_text", kind = .String},
				{name = "account", kind = .String},
				{name = "category", kind = .String, help = "\"\" when uncategorised"},
				{name = "method", kind = .String},
				{name = "cleared", kind = .Bool},
			}},
		},
		examples = {
			"money transactions apps/money/testdata/demo.money --limit 10 --json",
			"money transactions apps/money/testdata/demo.money --match MONOPRIX --json",
			"money list default --todo",
		},
		run = cmd_transactions,
	},
	{
		verb = "budget",
		summary = "one month's envelopes: limit, carry, spent, left",
		effect = .Read,
		args = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		flags = {
			{name = "month", kind = .String, help = "YYYY-MM; this month when omitted"},
		},
		out = {
			{name = "month", kind = .String},
			{name = "lines", kind = .Array, of = {
				{name = "category", kind = .String},
				{name = "limit", kind = .Int},
				{name = "carry", kind = .Int},
				{name = "available", kind = .Int},
				{name = "spent", kind = .Int},
				{name = "left", kind = .Int},
				{name = "over", kind = .Bool},
				{name = "pct", kind = .Int},
				{name = "count", kind = .Int},
			}},
			{name = "available", kind = .Int},
			{name = "spent", kind = .Int},
			{name = "left", kind = .Int},
			{name = "over", kind = .Int, help = "how many envelopes are over"},
		},
		examples = {"money budget apps/money/testdata/demo.money --json", "money budget default --month 2026-09"},
		run = cmd_budget,
	},
	{
		verb = "recurring",
		summary = "subscriptions and other recurring payments found in the history",
		effect = .Read,
		args = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		flags = {
			{name = "min-confidence", kind = .Int, help = "0..100", def = "0"},
		},
		out = {
			{name = "recurring", kind = .Array, of = {
				{name = "label", kind = .String},
				{name = "category", kind = .String},
				{name = "amount", kind = .Int, help = "the median, in cents"},
				{name = "cadence", kind = .String},
				{name = "count", kind = .Int},
				{name = "next", kind = .String},
				{name = "confidence", kind = .Int},
			}},
			{name = "monthly_out", kind = .Int},
			{name = "monthly_in", kind = .Int},
		},
		examples = {"money recurring apps/money/testdata/demo.money --json"},
		run = cmd_recurring,
	},
	{
		verb = "import",
		summary = "book a bank statement (CSV, OFX/QFX, CAMT.053) into a book",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, help = "the statement", required = true}},
		flags = {
			{name = "book", kind = .Path, help = "the book to import into; without it, a scratch book that is not saved"},
			{name = "account", kind = .String, help = "the account when the statement names no known IBAN"},
		},
		out = {
			{name = "file", kind = .String},
			{name = "format", kind = .String},
			{name = "added", kind = .Int},
			{name = "duplicates", kind = .Int},
			{name = "categorised", kind = .Int},
			{name = "rows_bad", kind = .Int},
			{name = "account", kind = .String},
			{name = "balance", kind = .Int, help = "the account's balance afterwards, in cents"},
			{name = "problem", kind = .String, opt = true},
			{name = "saved", kind = .Bool},
		},
		examples = {
			"money import releve.csv --book apps/money/testdata/demo.money --dry-run --json",
			"money import octobre.camt.xml --book default --account \"Compte courant\"",
		},
		run = cmd_import,
	},
	{
		verb = "categorize",
		summary = "put a transaction in a category, and learn its merchant as a rule",
		effect = .Idempotent,
		aliases = {"categorise"},
		args = {
			{name = "id", kind = .Int, help = "the transaction's id, from `money transactions`", required = true},
			{name = "category", kind = .String, help = "the category, by name", required = true},
		},
		flags = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		out = {
			{name = "id", kind = .Int},
			{name = "label", kind = .String},
			{name = "category", kind = .String},
			{name = "saved", kind = .Bool},
		},
		examples = {"money categorize 42 Courses --book default --json"},
		run = cmd_categorize,
	},
	{
		verb = "apply-rules",
		summary = "run the categorisation rules over the book again",
		effect = .Idempotent,
		flags = {{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true}},
		out = {{name = "moved", kind = .Int}, {name = "saved", kind = .Bool}},
		examples = {"money apply-rules --book default --dry-run --json"},
		run = cmd_apply_rules,
	},
	{
		verb = "budget-set",
		summary = "set a category's envelope for a month; 0 removes it",
		effect = .Idempotent,
		args = {
			{name = "category", kind = .String, help = "the category, by name", required = true},
			{name = "amount", kind = .String, help = "e.g. 250 or 1 234,56", required = true},
		},
		flags = {
			{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true},
			{name = "month", kind = .String, help = "YYYY-MM; this month when omitted"},
			{name = "rollover", kind = .Bool, help = "carry what is left into next month (--no-rollover to not)", def = "true"},
		},
		out = {
			{name = "category", kind = .String},
			{name = "month", kind = .String},
			{name = "limit", kind = .Int},
			{name = "rollover", kind = .Bool},
			{name = "saved", kind = .Bool},
		},
		examples = {"money budget-set Courses 400 --book default --json"},
		run = cmd_budget_set,
	},
	{
		verb = "budget-suggest",
		summary = "propose an envelope for every category with history and none this month",
		effect = .Idempotent,
		flags = {
			{name = "book", kind = .Path, help = "the book file; `default` is the window's own store", required = true},
			{name = "month", kind = .String, help = "YYYY-MM; this month when omitted"},
		},
		out = {{name = "month", kind = .String}, {name = "proposed", kind = .Int}, {name = "saved", kind = .Bool}},
		examples = {"money budget-suggest --book default --dry-run --json"},
		run = cmd_budget_suggest,
	},
	{
		verb = "fixtures",
		summary = "write the fictitious test statements to a directory",
		effect = .Idempotent,
		args = {{name = "dir", kind = .Path, help = "where to write them", required = true}},
		out = {{name = "dir", kind = .String}, {name = "written", kind = .Int}},
		examples = {"money fixtures /tmp/money-fixtures --json"},
		run = cmd_fixtures,
	},
	{
		verb = "demo",
		summary = "write the fictitious demo book, the one the window opens with on first run",
		effect = .Mutate,
		flags = {
			{name = "book", kind = .Path, help = "where to write it; it must not exist yet", required = true},
		},
		out = {
			{name = "book", kind = .String},
			{name = "accounts", kind = .Int},
			{name = "transactions", kind = .Int},
			{name = "saved", kind = .Bool},
		},
		examples = {"money demo --book /tmp/demo.money --json"},
		run = cmd_demo,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "money",
			summary    = "accounts, statement imports and budgets, read from files only",
			gui        = true,
			takes_path = true,
			// `money statement.csv` imports a file that is there; `money
			// lsit` is a typo, not an import of nothing.
			takes_word = kit.cli_word_is_path,
			selftest   = selftest_mode,
			commands   = COMMANDS,
			notes      = `Every command names its book: the reads as their first argument, the
commands that change one with --book. ` + "`default`" + ` is the window's own
store (~/.local/share/palmy-money/book.money). There is no network code in
this program: statements are files the bank exported.

Older spellings, still accepted: money --import FILE, money --fixtures DIR,
money --shot OUT.png [steps], money --bench [n], money --start-dir DIR,
money FILE (import FILE at startup, then open the window).`,
		}
	}
	return &g_surface
}

// ---------------------------------------------------------------------------
// Opening and saving a book
// ---------------------------------------------------------------------------

@(private = "file")
book_path :: proc(c: ^kit.Call) -> string {
	b := kit.cli_str(c, "book")
	if b == "default" {
		return store_path(context.allocator)
	}
	return b
}

// open_book loads the named book into a fresh App the way the window does at
// startup: read, make sure every category exists, filter.
@(private = "file")
open_book :: proc(c: ^kit.Call, must_exist := true) -> (app: ^App, code: int) {
	app = new(App)
	app_init(app)
	path := book_path(c)
	if path != "" {
		_, found := store_load_from(app, path)
		if !found && must_exist {
			return app, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no book at %s", path)
		}
	}
	ensure_categories(app)
	refilter(app)
	return app, kit.EXIT_OK
}

// save_book writes the book back unless this is a dry run, and says so.
@(private = "file")
save_book :: proc(c: ^kit.Call, app: ^App) -> (code: int) {
	path := book_path(c)
	if c.dry_run || path == "" {
		kit.jset_bool(c.out, "saved", false)
		return kit.EXIT_OK
	}
	if !store_save_to(app, path) {
		kit.jset_bool(c.out, "saved", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", path)
	}
	kit.jset_bool(c.out, "saved", true)
	return kit.EXIT_OK
}

@(private = "file")
find_named :: proc(l: ^Ledger, name: string, kinds: bit_set[Account_Kind]) -> (int, bool) {
	for a, i in l.accounts {
		if a.kind in kinds && a.name == name {
			return i, true
		}
	}
	for a, i in l.accounts {
		if a.kind in kinds && strings.equal_fold(a.name, name) {
			return i, true
		}
	}
	return -1, false
}

@(private = "file")
kind_name :: proc(k: Account_Kind) -> string {
	switch k {
	case .Asset:
		return "asset"
	case .Expense:
		return "expense"
	case .Income:
		return "income"
	case .Equity:
		return "equity"
	}
	return "asset"
}

// parse_month reads YYYY-MM, or answers this month for "".
@(private = "file")
parse_month :: proc(app: ^App, s: string) -> (y, m: int, ok: bool) {
	if s == "" {
		return app.month.y, app.month.m, true
	}
	if len(s) != 7 || s[4] != '-' {
		return 0, 0, false
	}
	yy, ok1 := strconv.parse_int(s[:4], 10)
	mm, ok2 := strconv.parse_int(s[5:], 10)
	if !ok1 || !ok2 || mm < 1 || mm > 12 {
		return 0, 0, false
	}
	return yy, mm, true
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

@(private = "file")
cmd_accounts :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	l := &app.led
	all := kit.cli_bool(c, "all")
	arr := kit.jarr()
	for a in l.accounts {
		if !all && a.kind != .Asset {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "name", a.name)
		kit.jset_str(o, "kind", kind_name(a.kind))
		kit.jset_str(o, "iban", a.iban)
		kit.jset_str(o, "bank", a.bank)
		kit.jset_i64(o, "balance", i64(a.balance))
		kit.jset_str(o, "balance_text", money_text(a.balance))
		kit.jset_int(o, "entries", a.entries)
		kit.jset_bool(o, "archived", a.archived)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "book", book_path(c))
	kit.jset(c.out, "accounts", arr)
	kit.jset_i64(c.out, "assets_total", i64(assets_total(l)))
	kit.jset_int(c.out, "transactions", txn_count(l))
	kit.jset_bool(c.out, "balanced", ledger_check(l).ok)
	return kit.EXIT_OK
}

@(private = "file")
txn_json :: proc(l: ^Ledger, t: ^Txn) -> ^kit.Json {
	o := kit.jobj()
	amount := txn_amount(l, t)
	acct, _, has_acct := txn_asset_side(l, t)
	cat := txn_category(l, t)
	kit.jset_int(o, "id", t.id)
	kit.jset_str(o, "date", date_iso(t.date))
	kit.jset_str(o, "label", t.label)
	kit.jset_i64(o, "amount", i64(amount))
	kit.jset_str(o, "amount_text", money_signed(amount))
	kit.jset_str(o, "account", has_acct ? account_name(l, acct) : "")
	kit.jset_str(o, "category", cat >= 0 ? account_name(l, cat) : "")
	kit.jset_str(o, "method", method_label(t.method))
	kit.jset_bool(o, "cleared", t.cleared)
	return o
}

@(private = "file")
cmd_transactions :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	l := &app.led
	if name := kit.cli_str(c, "account"); name != "" {
		i, ok := find_named(l, name, {.Asset})
		if !ok {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no account named %q", name)
		}
		app.filter.account = i
	}
	if name := kit.cli_str(c, "category"); name != "" {
		i, ok := find_named(l, name, {.Expense, .Income})
		if !ok {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no category named %q", name)
		}
		app.filter.category = i
	}
	from, to := kit.cli_str(c, "from"), kit.cli_str(c, "to")
	if from != "" || to != "" {
		app.filter.range = .Custom
		app.filter.lo = Date{1, 1, 1}
		app.filter.hi = Date{9999, 12, 31}
		if from != "" {
			d, ok := date_parse(from)
			if !ok {
				return kit.cli_failf(c, kit.EXIT_USAGE, "--from wants a date, got %q", from)
			}
			app.filter.lo = d
		}
		if to != "" {
			d, ok := date_parse(to)
			if !ok {
				return kit.cli_failf(c, kit.EXIT_USAGE, "--to wants a date, got %q", to)
			}
			app.filter.hi = d
		}
	}
	app.filter.only_todo = kit.cli_bool(c, "todo")
	clear(&app.search)
	append(&app.search, kit.cli_str(c, "match"))
	refilter(app)

	out, in_ := rows_total(app)
	limit := kit.cli_int(c, "limit")
	arr := kit.jarr()
	for i, n in app.rows {
		if limit > 0 && n >= limit {
			break
		}
		kit.jpush(arr, txn_json(l, &l.txns[i]))
	}
	kit.jset_int(c.out, "count", len(app.rows))
	kit.jset_i64(c.out, "total_out", i64(out))
	kit.jset_i64(c.out, "total_in", i64(in_))
	kit.jset(c.out, "transactions", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_budget :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	y, m, ok := parse_month(app, kit.cli_str(c, "month"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--month wants YYYY-MM")
	}
	l := &app.led
	arr := kit.jarr()
	for line in budget_month(app, y, m) {
		o := kit.jobj()
		kit.jset_str(o, "category", account_name(l, line.category))
		kit.jset_i64(o, "limit", i64(line.limit))
		kit.jset_i64(o, "carry", i64(line.carry))
		kit.jset_i64(o, "available", i64(line.available))
		kit.jset_i64(o, "spent", i64(line.spent))
		kit.jset_i64(o, "left", i64(line.left))
		kit.jset_bool(o, "over", line.over)
		kit.jset_int(o, "pct", line.pct)
		kit.jset_int(o, "count", line.count)
		kit.jpush(arr, o)
	}
	tot := budget_totals(app, y, m)
	kit.jset_str(c.out, "month", fmt.tprintf("%04d-%02d", y, m))
	kit.jset(c.out, "lines", arr)
	kit.jset_i64(c.out, "available", i64(tot.available))
	kit.jset_i64(c.out, "spent", i64(tot.spent))
	kit.jset_i64(c.out, "left", i64(tot.left))
	kit.jset_int(c.out, "over", tot.over)
	return kit.EXIT_OK
}

@(private = "file")
cmd_recurring :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	l := &app.led
	min_conf := kit.cli_int(c, "min-confidence")
	recs := recurrences(app)
	arr := kit.jarr()
	for r in recs {
		if r.confidence < min_conf {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "label", r.label)
		kit.jset_str(o, "category", r.category >= 0 ? account_name(l, r.category) : "")
		kit.jset_i64(o, "amount", i64(r.amount))
		kit.jset_str(o, "cadence", cadence_label(r.cadence))
		kit.jset_int(o, "count", r.count)
		kit.jset_str(o, "next", date_iso(r.next))
		kit.jset_int(o, "confidence", r.confidence)
		kit.jpush(arr, o)
	}
	mo, mi := recurring_monthly_total(recs, max(min_conf, 50))
	kit.jset(c.out, "recurring", arr)
	kit.jset_i64(c.out, "monthly_out", i64(mo))
	kit.jset_i64(c.out, "monthly_in", i64(mi))
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Changes
// ---------------------------------------------------------------------------

@(private = "file")
cmd_import :: proc(c: ^kit.Call) -> int {
	file := kit.cli_str(c, "file")
	if !os.is_file(file) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no statement at %s", file)
	}
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	l := &app.led
	account := -1
	if name := kit.cli_str(c, "account"); name != "" {
		i, ok := find_named(l, name, {.Asset})
		if !ok {
			// Naming a new account is how a first import creates one, as the
			// legacy `--import` always did with "Compte courant".
			i = account_add(l, name, .Asset)
		}
		account = i
	} else if book_path(c) == "" {
		account = account_add(l, "Compte courant", .Asset)
	} else {
		account = import_account(app)
	}
	rep, ok := import_book(app, file, account)
	kit.jset_str(c.out, "file", file)
	kit.jset_str(c.out, "format", format_name(rep.format))
	kit.jset_int(c.out, "added", rep.added)
	kit.jset_int(c.out, "duplicates", rep.duplicates)
	kit.jset_int(c.out, "categorised", rep.categorised)
	kit.jset_int(c.out, "rows_bad", rep.rows_bad)
	if rep.account >= 0 && rep.account < len(l.accounts) {
		kit.jset_str(c.out, "account", account_name(l, rep.account))
		kit.jset_i64(c.out, "balance", i64(l.accounts[rep.account].balance))
	} else {
		kit.jset_str(c.out, "account", "")
		kit.jset_i64(c.out, "balance", 0)
	}
	if rep.problem != "" {
		kit.jset_str(c.out, "problem", rep.problem)
	}
	if !ok && rep.added == 0 {
		kit.jset_bool(c.out, "saved", false)
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", file, rep.problem != "" ? rep.problem : "aucune opération lue")
	}
	return save_book(c, app)
}

@(private = "file")
cmd_categorize :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	l := &app.led
	id := kit.cli_int(c, "id", -1)
	t, found := txn_get(l, id)
	if !found {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no transaction %d", id)
	}
	name := kit.cli_str(c, "category")
	cat, ok := find_named(l, name, {.Expense, .Income})
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no category named %q", name)
	}
	label := strings.clone(t.label, context.temp_allocator)
	if !categorise_txn(app, id, cat) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "transaction %d cannot be categorised (a transfer or a split)", id)
	}
	kit.jset_int(c.out, "id", id)
	kit.jset_str(c.out, "label", label)
	kit.jset_str(c.out, "category", account_name(l, cat))
	return save_book(c, app)
}

@(private = "file")
cmd_apply_rules :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset_int(c.out, "moved", rules_reapply(app))
	return save_book(c, app)
}

@(private = "file")
cmd_budget_set :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	y, m, ok := parse_month(app, kit.cli_str(c, "month"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--month wants YYYY-MM")
	}
	l := &app.led
	name := kit.cli_str(c, "category")
	cat, found := find_named(l, name, {.Expense, .Income})
	if !found {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no category named %q", name)
	}
	v, vok := money_parse(kit.cli_str(c, "amount"))
	if !vok || v < 0 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not an amount", kit.cli_str(c, "amount"))
	}
	rollover := kit.cli_bool(c, "rollover")
	// The same call the window's envelope dialog makes; 0 removes it there too.
	budget_set(app, cat, y, m, v, rollover)
	app.dirty = true
	kit.jset_str(c.out, "category", account_name(l, cat))
	kit.jset_str(c.out, "month", fmt.tprintf("%04d-%02d", y, m))
	kit.jset_i64(c.out, "limit", i64(v))
	kit.jset_bool(c.out, "rollover", rollover)
	return save_book(c, app)
}

@(private = "file")
cmd_budget_suggest :: proc(c: ^kit.Call) -> int {
	app, code := open_book(c)
	defer drop_book(app)
	if code != kit.EXIT_OK {
		return code
	}
	y, m, ok := parse_month(app, kit.cli_str(c, "month"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--month wants YYYY-MM")
	}
	kit.jset_str(c.out, "month", fmt.tprintf("%04d-%02d", y, m))
	kit.jset_int(c.out, "proposed", budget_suggest_all(app, y, m))
	return save_book(c, app)
}

@(private = "file")
cmd_fixtures :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		kit.jset_int(c.out, "written", 0)
		return kit.EXIT_OK
	}
	n, err := fixtures_write(dir)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_int(c.out, "written", n)
	return kit.EXIT_OK
}

@(private = "file")
cmd_demo :: proc(c: ^kit.Call) -> int {
	path := book_path(c)
	if os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s already exists; the demo book is only ever written somewhere new", path)
	}
	app := new(App)
	app_init(app)
	defer drop_book(app)
	seed_demo(app)
	kit.jset_str(c.out, "book", path)
	kit.jset_int(c.out, "accounts", len(asset_list(app)))
	kit.jset_int(c.out, "transactions", txn_count(&app.led))
	return save_book(c, app)
}

@(private = "file")
drop_book :: proc(app: ^App) {
	app_destroy(app)
	free(app)
}
