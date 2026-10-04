// The ledger: double-entry, with the invariant asserted rather than hoped for.
//
// Every movement of money is a transaction holding two or more *entries*, each
// naming an account and a signed amount in centimes, and the entries of a
// transaction always sum to zero. A card purchase is −42,10 € on the current
// account and +42,10 € on the Courses category. A transfer is −200 € on one
// account and +200 € on the other. A split is one negative entry and several
// positive ones.
//
// Categories are accounts. That sounds like a technicality and is in fact the
// whole reason this model is worth the troub­le: with categories as accounts,
// "where did the money go" is a balance query, a budget is a comparison
// against one account's movement in a month, and the global invariant
//
//     the sum of every entry in the book is zero
//
// is strong enough to catch the bug this design exists to prevent — an edit
// that updates one side of a transaction and not the other. A single-sided
// model cannot catch it, because it has nothing to compare against.
//
// Two invariants are maintained and both are checked by `ledger_check`:
//
//   1. Every live transaction's entries sum to zero, so the book's total is
//      zero by construction.
//   2. Every account's cached balance equals the sum of the entries naming it.
//
// The second is the interesting one. Balances are cached because a UI that
// re-sums ten thousand entries per frame is a UI that stutters; a cache that
// drifts from the entries it summarises is exactly the silent corruption this
// file is written to make impossible. Every mutation goes through
// `apply_entries`, and the property test in selftest.odin re-derives all of it
// from scratch after every single operation.
package main

import "core:slice"
import "core:strings"

Account_Kind :: enum {
	Asset, // a real bank account: current, savings, cash
	Expense, // a spending category
	Income, // salary, refunds, interest
	Equity, // opening balances and the holding account for the uncategorised
}

Account :: struct {
	id:       int,
	name:     string,
	kind:     Account_Kind,
	iban:     string, // Asset only; "" when the user did not give one
	bank:     string, // which profile imported into it
	balance:  Cents, // cached; must equal the sum of this account's entries
	entries:  int, // how many entries name it, also cached
	tint:     int, // index into CATEGORY_TINTS, for the charts
	archived: bool,
}

Entry :: struct {
	account: int, // index into Ledger.accounts
	amount:  Cents,
}

// Method is the kind of payment, which a French bank label announces in its
// first word and which matters more here than it would elsewhere: a `PRLV` is
// a direct debit and therefore probably a subscription, a `CB` is a card
// purchase, a `RETRAIT` is cash leaving the system and can never be
// categorised from its label because the label says nothing about what the
// cash bought.
Method :: enum {
	Unknown,
	Card, // CB, CARTE, PAIEMENT CB
	Debit, // PRLV, PRELEVEMENT — a direct debit
	Transfer, // VIR, VIREMENT
	Cheque, // CHQ, CHEQUE
	Cash, // RETRAIT, RET DAB
	Fee, // COTISATION, FRAIS, COMMISSION
	Deposit, // REMISE, VERSEMENT
}

method_label :: proc(m: Method) -> string {
	switch m {
	case .Unknown:
		return "—"
	case .Card:
		return "CB"
	case .Debit:
		return "PRLV"
	case .Transfer:
		return "VIR"
	case .Cheque:
		return "CHQ"
	case .Cash:
		return "RETRAIT"
	case .Fee:
		return "FRAIS"
	case .Deposit:
		return "REMISE"
	}
	return "—"
}

Txn :: struct {
	id:       int, // stable; never reused, so a tombstone cannot be mistaken
	date:     Date, // the booking date, which is what a statement orders by
	value:    Date, // the value date, when the bank gives one
	label:    string, // the bank's own label, kept verbatim
	note:     string, // the user's annotation
	method:   Method,
	ext_id:   string, // FITID, NtryRef — the bank's own id, for de-duplication
	entries:  [dynamic]Entry,
	cleared:  bool, // reconciled against a statement balance
	auto_cat: bool, // the category came from a rule, not from the user
	dead:     bool, // deleted; kept so ids are never reused
}

Ledger :: struct {
	accounts:    [dynamic]Account,
	txns:        [dynamic]Txn,
	next_id:     int,
	by_ext:      map[string]int, // ext_id -> txn index, live transactions only
	by_id:       map[int]int, // txn id -> index
	unallocated: int, // the Equity account uncategorised money sits in
	opening:     int, // the Equity account opening balances come from
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

ledger_init :: proc(l: ^Ledger) {
	l.accounts = make([dynamic]Account)
	l.txns = make([dynamic]Txn)
	l.by_ext = make(map[string]int)
	l.by_id = make(map[int]int)
	l.next_id = 1
	l.unallocated = account_add(l, "Non catégorisé", .Equity)
	l.opening = account_add(l, "Solde initial", .Equity)
}

ledger_destroy :: proc(l: ^Ledger) {
	for &a in l.accounts {
		delete(a.name)
		delete(a.iban)
		delete(a.bank)
	}
	delete(l.accounts)
	for &t in l.txns {
		delete(t.label)
		delete(t.note)
		delete(t.ext_id)
		delete(t.entries)
	}
	delete(l.txns)
	delete(l.by_ext)
	delete(l.by_id)
}

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account_add :: proc(l: ^Ledger, name: string, kind: Account_Kind, iban := "", bank := "") -> int {
	id := len(l.accounts)
	append(
		&l.accounts,
		Account {
			id = id,
			name = strings.clone(name),
			kind = kind,
			iban = strings.clone(iban),
			bank = strings.clone(bank),
			tint = id,
		},
	)
	return id
}

account_find :: proc(l: ^Ledger, name: string) -> (idx: int, ok: bool) {
	for a, i in l.accounts {
		if a.name == name {
			return i, true
		}
	}
	return -1, false
}

// account_get_or_add is how the importer resolves a category name: it never
// invents a second account with the same name, which would split a category's
// history in two and make a budget wrong.
account_get_or_add :: proc(l: ^Ledger, name: string, kind: Account_Kind) -> int {
	if i, ok := account_find(l, name); ok {
		return i
	}
	return account_add(l, name, kind)
}

account_name :: proc(l: ^Ledger, idx: int) -> string {
	if idx < 0 || idx >= len(l.accounts) {
		return "?"
	}
	return l.accounts[idx].name
}

// account_by_iban matches on the normalised form, so `FR76 9999 ...` and
// `fr769999...` are the same account.
account_by_iban :: proc(l: ^Ledger, iban: string) -> (idx: int, ok: bool) {
	want := iban_normalize(iban, context.temp_allocator)
	if want == "" {
		return -1, false
	}
	for a, i in l.accounts {
		if a.iban == "" {
			continue
		}
		if iban_normalize(a.iban, context.temp_allocator) == want {
			return i, true
		}
	}
	return -1, false
}

assets_total :: proc(l: ^Ledger) -> (total: Cents) {
	for a in l.accounts {
		if a.kind == .Asset && !a.archived {
			total += a.balance
		}
	}
	return
}

// ---------------------------------------------------------------------------
// The one place balances change
// ---------------------------------------------------------------------------

@(private)
apply_entries :: proc(l: ^Ledger, entries: []Entry, sign: int) {
	for e in entries {
		if e.account < 0 || e.account >= len(l.accounts) {
			continue
		}
		if sign > 0 {
			l.accounts[e.account].balance += e.amount
			l.accounts[e.account].entries += 1
		} else {
			l.accounts[e.account].balance -= e.amount
			l.accounts[e.account].entries -= 1
		}
	}
}

entries_sum :: proc(entries: []Entry) -> (total: Cents) {
	for e in entries {
		total += e.amount
	}
	return
}

entries_balanced :: proc(entries: []Entry) -> bool {
	return len(entries) >= 2 && entries_sum(entries) == 0
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

Txn_Spec :: struct {
	date:    Date,
	value:   Date,
	label:   string,
	note:    string,
	method:  Method,
	ext_id:  string,
	entries: []Entry,
	auto:    bool,
}

// txn_add appends a transaction. It refuses an unbalanced one: there is no
// path in this application that can create a book that does not add up,
// which is the only way to be sure one never exists.
txn_add :: proc(l: ^Ledger, spec: Txn_Spec) -> (id: int, ok: bool) {
	if !entries_balanced(spec.entries) {
		return 0, false
	}
	for e in spec.entries {
		if e.account < 0 || e.account >= len(l.accounts) {
			return 0, false
		}
	}
	if spec.ext_id != "" {
		if _, dup := l.by_ext[spec.ext_id]; dup {
			return 0, false // the bank's own id; the caller counts it as a duplicate
		}
	}

	t := Txn {
		id       = l.next_id,
		date     = spec.date,
		value    = spec.value.y == 0 ? spec.date : spec.value,
		label    = strings.clone(spec.label),
		note     = strings.clone(spec.note),
		method   = spec.method,
		ext_id   = strings.clone(spec.ext_id),
		auto_cat = spec.auto,
		entries  = make([dynamic]Entry),
	}
	append(&t.entries, ..spec.entries)
	l.next_id += 1

	idx := len(l.txns)
	append(&l.txns, t)
	l.by_id[t.id] = idx
	if t.ext_id != "" {
		l.by_ext[t.ext_id] = idx
	}
	apply_entries(l, t.entries[:], +1)
	return t.id, true
}

txn_index :: proc(l: ^Ledger, id: int) -> (idx: int, ok: bool) {
	i, found := l.by_id[id]
	if !found || i < 0 || i >= len(l.txns) || l.txns[i].dead {
		return -1, false
	}
	return i, true
}

txn_get :: proc(l: ^Ledger, id: int) -> (t: ^Txn, ok: bool) {
	i, found := txn_index(l, id)
	if !found {
		return nil, false
	}
	return &l.txns[i], true
}

// txn_delete reverses the transaction's effect on every account it touched and
// leaves a tombstone, so the id can never be handed out again and a stale
// reference resolves to "gone" rather than to somebody else's transaction.
//
// The bank's id is released, so re-importing the same statement brings the
// row back. That is deliberate: a deletion is an edit of this book, not an
// assertion that the bank is wrong.
txn_delete :: proc(l: ^Ledger, id: int) -> bool {
	i, ok := txn_index(l, id)
	if !ok {
		return false
	}
	apply_entries(l, l.txns[i].entries[:], -1)
	if l.txns[i].ext_id != "" {
		if cur, has := l.by_ext[l.txns[i].ext_id]; has && cur == i {
			delete_key(&l.by_ext, l.txns[i].ext_id)
		}
	}
	l.txns[i].dead = true
	clear(&l.txns[i].entries)
	return true
}

// txn_replace_entries swaps a transaction's entries for a new balanced set,
// in one step. Every edit below is expressed through it, so there is exactly
// one function in this program that can change what a transaction says, and
// it cannot leave the book unbalanced: the new set is validated before the
// old one is reversed.
txn_replace_entries :: proc(l: ^Ledger, id: int, entries: []Entry) -> bool {
	i, ok := txn_index(l, id)
	if !ok {
		return false
	}
	if !entries_balanced(entries) {
		return false
	}
	for e in entries {
		if e.account < 0 || e.account >= len(l.accounts) {
			return false
		}
	}
	apply_entries(l, l.txns[i].entries[:], -1)
	clear(&l.txns[i].entries)
	append(&l.txns[i].entries, ..entries)
	apply_entries(l, l.txns[i].entries[:], +1)
	return true
}

// txn_asset_side is the entry naming a real bank account — the one the
// statement row came from. A transfer has two, and the first is taken as the
// source.
txn_asset_side :: proc(l: ^Ledger, t: ^Txn) -> (account: int, amount: Cents, ok: bool) {
	for e in t.entries {
		if l.accounts[e.account].kind == .Asset {
			return e.account, e.amount, true
		}
	}
	return -1, 0, false
}

// txn_amount is the signed amount as the account holder sees it: negative for
// money out. For a transfer between two of the user's own accounts it is the
// amount leaving the source.
txn_amount :: proc(l: ^Ledger, t: ^Txn) -> Cents {
	for e in t.entries {
		if l.accounts[e.account].kind == .Asset {
			return e.amount
		}
	}
	// No asset side (a pure category adjustment): report the first entry.
	return len(t.entries) > 0 ? t.entries[0].amount : 0
}

// txn_categories lists the non-asset accounts a transaction allocates to.
txn_categories :: proc(
	l: ^Ledger,
	t: ^Txn,
	allocator := context.temp_allocator,
) -> []Entry {
	out := make([dynamic]Entry, allocator)
	for e in t.entries {
		if l.accounts[e.account].kind != .Asset {
			append(&out, e)
		}
	}
	return out[:]
}

// txn_is_transfer: two asset entries and nothing else, which is a movement
// between the user's own accounts and must not count as either income or
// spending. A budget that counts a transfer as spending double-counts the
// money and the user cannot work out why.
txn_is_transfer :: proc(l: ^Ledger, t: ^Txn) -> bool {
	assets := 0
	for e in t.entries {
		if l.accounts[e.account].kind == .Asset {
			assets += 1
		}
	}
	return assets >= 2
}

txn_category :: proc(l: ^Ledger, t: ^Txn) -> int {
	for e in t.entries {
		k := l.accounts[e.account].kind
		if k == .Expense || k == .Income {
			return e.account
		}
	}
	return -1
}

txn_is_split :: proc(l: ^Ledger, t: ^Txn) -> bool {
	n := 0
	for e in t.entries {
		k := l.accounts[e.account].kind
		if k == .Expense || k == .Income || k == .Equity {
			n += 1
		}
	}
	return n > 1
}

// ---------------------------------------------------------------------------
// The editing operations, all of them built on txn_replace_entries
// ---------------------------------------------------------------------------

// txn_categorise moves the whole non-asset side to one category. The asset
// entry is untouched — the money that left the account did not change because
// the user decided what it was for.
txn_categorise :: proc(l: ^Ledger, id: int, category: int) -> bool {
	t, ok := txn_get(l, id)
	if !ok {
		return false
	}
	if category < 0 || category >= len(l.accounts) {
		return false
	}
	if l.accounts[category].kind == .Asset {
		return false // use txn_make_transfer for that
	}
	if txn_is_transfer(l, t) {
		return false
	}
	acct, amount, has := txn_asset_side(l, t)
	if !has {
		return false
	}
	ents := [2]Entry{{acct, amount}, {category, -amount}}
	if !txn_replace_entries(l, id, ents[:]) {
		return false
	}
	t2, _ := txn_get(l, id)
	t2.auto_cat = false
	return true
}

// txn_set_amount changes what the transaction was for — a correction, or the
// second half of a card authorisation settling at a different figure. The
// category side is rescaled so the transaction still balances exactly: a
// split of 60/40 stays 60/40, with the remainder centimes landing on the
// largest part rather than vanishing.
txn_set_amount :: proc(l: ^Ledger, id: int, amount: Cents) -> bool {
	t, ok := txn_get(l, id)
	if !ok {
		return false
	}
	// The asset entry is found by position, not by value: two entries can
	// legitimately carry the same account and amount, and dropping the wrong
	// one would change what the transaction says.
	side := -1
	for e, i in t.entries {
		if l.accounts[e.account].kind == .Asset {
			side = i
			break
		}
	}
	if side < 0 {
		return false
	}
	acct := t.entries[side].account
	old := t.entries[side].amount
	if old == 0 {
		return false
	}
	others := make([dynamic]Entry, 0, len(t.entries), context.temp_allocator)
	for e, i in t.entries {
		if i == side {
			continue
		}
		append(&others, e)
	}
	if len(others) == 0 {
		return false
	}

	ents := make([dynamic]Entry, 0, len(others) + 1, context.temp_allocator)
	append(&ents, Entry{acct, amount})
	// Rescale by integer arithmetic, then force the last (largest) part to
	// absorb the rounding so the sum is exact.
	rest := -amount
	placed: Cents = 0
	big := 0
	for e, i in others {
		if money_abs(e.amount) > money_abs(others[big].amount) {
			big = i
		}
		_ = i
	}
	for e, i in others {
		if i == big {
			append(&ents, Entry{e.account, 0}) // filled in below
			continue
		}
		scaled := money_percent(rest, i64(e.amount), i64(-old))
		append(&ents, Entry{e.account, scaled})
		placed += scaled
	}
	ents[big + 1].amount = rest - placed
	return txn_replace_entries(l, id, ents[:])
}

Split_Part :: struct {
	category: int,
	amount:   Cents, // same sign as the category side, i.e. positive for a spend
}

// txn_split replaces the category side with several parts. The parts must add
// up to the whole non-asset side; a split that does not is refused rather
// than quietly absorbed, because a silently absorbed centime is the beginning
// of a book that does not add up.
txn_split :: proc(l: ^Ledger, id: int, parts: []Split_Part) -> bool {
	t, ok := txn_get(l, id)
	if !ok || len(parts) == 0 {
		return false
	}
	if txn_is_transfer(l, t) {
		return false
	}
	acct, amount, has := txn_asset_side(l, t)
	if !has {
		return false
	}
	total: Cents = 0
	for p in parts {
		if p.category < 0 || p.category >= len(l.accounts) {
			return false
		}
		if l.accounts[p.category].kind == .Asset {
			return false
		}
		total += p.amount
	}
	if total != -amount {
		return false
	}
	ents := make([dynamic]Entry, 0, len(parts) + 1, context.temp_allocator)
	append(&ents, Entry{acct, amount})
	for p in parts {
		append(&ents, Entry{p.category, p.amount})
	}
	return txn_replace_entries(l, id, ents[:])
}

// txn_make_transfer turns a transaction into a movement between two of the
// user's own accounts, which is what a `VIR` to a savings account is. The
// category side disappears, because no money was spent.
txn_make_transfer :: proc(l: ^Ledger, id: int, other: int) -> bool {
	t, ok := txn_get(l, id)
	if !ok {
		return false
	}
	if other < 0 || other >= len(l.accounts) || l.accounts[other].kind != .Asset {
		return false
	}
	acct, amount, has := txn_asset_side(l, t)
	if !has || acct == other {
		return false
	}
	ents := [2]Entry{{acct, amount}, {other, -amount}}
	return txn_replace_entries(l, id, ents[:])
}

// transfer_add books a transfer directly, which is what the UI's own
// "transfer" command does.
transfer_add :: proc(l: ^Ledger, from, to: int, amount: Cents, date: Date, label: string) -> (id: int, ok: bool) {
	if from == to {
		return 0, false
	}
	ents := [2]Entry{{from, -amount}, {to, amount}}
	return txn_add(l, {date = date, label = label, method = .Transfer, entries = ents[:]})
}

// opening_balance books an account's starting balance against the equity
// account, so even the balance a statement begins at is double-entered and
// the book's total stays zero.
opening_balance :: proc(l: ^Ledger, account: int, amount: Cents, date: Date) -> (id: int, ok: bool) {
	ents := [2]Entry{{account, amount}, {l.opening, -amount}}
	return txn_add(l, {date = date, label = "Solde initial", entries = ents[:]})
}

// ---------------------------------------------------------------------------
// The invariant
// ---------------------------------------------------------------------------

Ledger_Problem :: struct {
	ok:      bool,
	what:    string,
	txn_id:  int,
	account: int,
}

// ledger_check re-derives everything from the entries and compares. It is
// cheap enough to run after every operation in the property test and after
// every import in the application, and it is the only thing standing between
// a cache bug and a balance that is quietly wrong.
ledger_check :: proc(l: ^Ledger) -> Ledger_Problem {
	// 1. Every live transaction balances, and the global total is zero.
	total: Cents = 0
	for &t in l.txns {
		if t.dead {
			if len(t.entries) != 0 {
				return {false, "a deleted transaction still has entries", t.id, -1}
			}
			continue
		}
		if len(t.entries) < 2 {
			return {false, "a transaction has fewer than two entries", t.id, -1}
		}
		s := entries_sum(t.entries[:])
		if s != 0 {
			return {false, "a transaction's entries do not sum to zero", t.id, -1}
		}
		for e in t.entries {
			if e.account < 0 || e.account >= len(l.accounts) {
				return {false, "an entry names an account that does not exist", t.id, e.account}
			}
			total += e.amount
		}
	}
	if total != 0 {
		return {false, "the sum of every entry in the book is not zero", -1, -1}
	}

	// 2. Every account's cached balance and entry count match the entries.
	sums := make([]Cents, len(l.accounts), context.temp_allocator)
	counts := make([]int, len(l.accounts), context.temp_allocator)
	for &t in l.txns {
		if t.dead {
			continue
		}
		for e in t.entries {
			sums[e.account] += e.amount
			counts[e.account] += 1
		}
	}
	for a, i in l.accounts {
		if a.balance != sums[i] {
			return {false, "an account's cached balance does not match its entries", -1, i}
		}
		if a.entries != counts[i] {
			return {false, "an account's cached entry count does not match its entries", -1, i}
		}
	}

	// 3. The indexes agree with the transactions.
	live := 0
	for &t, i in l.txns {
		if t.dead {
			if _, has := l.by_ext[t.ext_id]; has && t.ext_id != "" {
				if l.by_ext[t.ext_id] == i {
					return {false, "a deleted transaction is still in the id index", t.id, -1}
				}
			}
			continue
		}
		live += 1
		if j, has := l.by_id[t.id]; !has || j != i {
			return {false, "the transaction id index is wrong", t.id, -1}
		}
		if t.ext_id != "" {
			if j, has := l.by_ext[t.ext_id]; !has || j != i {
				return {false, "the bank id index is wrong", t.id, -1}
			}
		}
	}
	for ext, i in l.by_ext {
		if i < 0 || i >= len(l.txns) {
			return {false, "the bank id index points past the end", -1, -1}
		}
		if l.txns[i].dead || l.txns[i].ext_id != ext {
			return {false, "the bank id index points at the wrong transaction", -1, -1}
		}
	}
	return {ok = true}
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// account_movement is how much an account moved between two dates,
// inclusive. For a category that is the spending in that period; for a bank
// account it is the change in balance.
account_movement :: proc(l: ^Ledger, account: int, lo, hi: Date) -> (total: Cents) {
	for &t in l.txns {
		if t.dead || !date_within(t.date, lo, hi) {
			continue
		}
		for e in t.entries {
			if e.account == account {
				total += e.amount
			}
		}
	}
	return
}

// balance_at is the account's balance as of the end of a date, which is what
// a reconciliation compares against a statement.
balance_at :: proc(l: ^Ledger, account: int, as_of: Date) -> (total: Cents) {
	for &t in l.txns {
		if t.dead || date_less(as_of, t.date) {
			continue
		}
		for e in t.entries {
			if e.account == account {
				total += e.amount
			}
		}
	}
	return
}

// live_txns is the transactions that still exist, in the order they were
// added. The UI sorts a filtered copy; nothing re-orders this array, because
// `by_id` holds indexes into it.
live_txns :: proc(l: ^Ledger, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for &t, i in l.txns {
		if !t.dead {
			append(&out, i)
		}
	}
	return out[:]
}

txn_count :: proc(l: ^Ledger) -> (n: int) {
	for &t in l.txns {
		if !t.dead {
			n += 1
		}
	}
	return
}

// sort_by_date orders indexes newest first, with the transaction id breaking
// ties so the order is total and a list does not shuffle between frames.
sort_by_date :: proc(l: ^Ledger, idx: []int, newest_first := true) {
	ctx := Sort_Ctx{l, newest_first}
	slice.sort_by_with_data(idx, sort_cmp, &ctx)
}

@(private = "file")
Sort_Ctx :: struct {
	l:     ^Ledger,
	newer: bool,
}

@(private = "file")
sort_cmp :: proc(a, b: int, data: rawptr) -> bool {
	c := (^Sort_Ctx)(data)
	ta := &c.l.txns[a]
	tb := &c.l.txns[b]
	if !date_eq(ta.date, tb.date) {
		return c.newer ? date_less(tb.date, ta.date) : date_less(ta.date, tb.date)
	}
	return c.newer ? ta.id > tb.id : ta.id < tb.id
}
