// Reconciliation: does this book agree with the statement?
//
// The question is narrow and the answer has to be exact. The bank prints a
// closing balance as of a date; the book has its own balance as of the same
// date; if they differ by so much as a centime something is missing, doubled
// or mistyped, and the difference itself is the clue — a difference equal to
// one transaction's amount means that transaction is the problem, and a
// difference equal to twice an amount means it was imported twice.
//
// So this does three things: compute the difference, mark everything up to
// the statement date as cleared when it agrees, and when it does not, look
// for the single transaction — or the pair — that would explain the gap.
// That last part is what turns "you are 42,10 € out" into "you are 42,10 €
// out, and here is a 42,10 € row dated the 21st".
package main

import "core:slice"

Recon_Target :: struct {
	account: int,
	balance: Cents, // what the statement says
	as_of:   Date,
	set:     bool,
}

recon_target :: proc(app: ^App, account: int) -> (t: Recon_Target, ok: bool) {
	for r in app.recon {
		if r.account == account && r.set {
			return r, true
		}
	}
	return {}, false
}

// recon_note_statement records a statement's own closing balance, which is
// what an OFX `<LEDGERBAL>`, a CAMT `CLBD` balance and a CSV with a running
// balance column all give for free. The user never has to type it.
recon_note_statement :: proc(app: ^App, account: int, balance: Cents, as_of: Date) {
	for &r in app.recon {
		if r.account == account {
			r.balance = balance
			r.as_of = as_of
			r.set = true
			return
		}
	}
	append(&app.recon, Recon_Target{account, balance, as_of, true})
}

recon_clear_target :: proc(app: ^App, account: int) {
	for &r in app.recon {
		if r.account == account {
			r.set = false
		}
	}
}

Recon_Result :: struct {
	account:     int,
	has_target:  bool,
	target:      Cents,
	book:        Cents, // the book's balance at the statement date
	diff:        Cents, // target - book; zero is agreement
	agrees:      bool,
	as_of:       Date,
	counted:     int, // transactions up to the date
	uncleared:   int, // of those, not yet marked cleared
	after:       int, // transactions after the date, not part of this check
	explain:     string, // what the difference looks like, "" when it agrees
	suspect_a:   int, // a transaction id that would explain it, -1 if none
	suspect_b:   int,
}

// recon_check compares and, when it does not agree, tries to say why.
recon_check :: proc(app: ^App, account: int) -> Recon_Result {
	res := Recon_Result {
		account   = account,
		suspect_a = -1,
		suspect_b = -1,
	}
	tgt, ok := recon_target(app, account)
	if !ok {
		return res
	}
	res.has_target = true
	res.target = tgt.balance
	res.as_of = tgt.as_of

	l := &app.led
	res.book = balance_at(l, account, tgt.as_of)
	res.diff = tgt.balance - res.book
	res.agrees = res.diff == 0

	for &t in l.txns {
		if t.dead {
			continue
		}
		acct, _, has := txn_asset_side(l, &t)
		if !has || acct != account {
			continue
		}
		if date_less(tgt.as_of, t.date) {
			res.after += 1
			continue
		}
		res.counted += 1
		if !t.cleared {
			res.uncleared += 1
		}
	}

	if res.agrees {
		return res
	}
	explain_difference(app, &res)
	return res
}

// explain_difference looks for the transaction that accounts for the gap.
//
// Four cases, in the order they are worth checking:
//
//   * a transaction whose amount is exactly the difference — it is in the
//     book but not on the statement (or the reverse);
//   * a transaction whose amount is exactly *minus* the difference — the
//     same, the other way round;
//   * a pair of identical transactions summing to the difference — the
//     classic double import;
//   * two transactions whose amounts differ by the difference — digits
//     transposed when typing, 45,00 € entered as 54,00 €.
@(private = "file")
explain_difference :: proc(app: ^App, res: ^Recon_Result) {
	l := &app.led
	ids := make([dynamic]int, context.temp_allocator)
	amounts := make([dynamic]Cents, context.temp_allocator)
	for &t in l.txns {
		if t.dead {
			continue
		}
		acct, amount, has := txn_asset_side(l, &t)
		if !has || acct != res.account || date_less(res.as_of, t.date) {
			continue
		}
		append(&ids, t.id)
		append(&amounts, amount)
	}

	for a, i in amounts {
		if a == res.diff {
			res.explain = "une opération de ce montant manque au relevé"
			res.suspect_a = ids[i]
			return
		}
		if -a == res.diff {
			res.explain = "une opération de ce montant est en trop dans le livre"
			res.suspect_a = ids[i]
			return
		}
	}
	// A doubled import: two equal amounts whose single value is -diff.
	for a, i in amounts {
		for b, j in amounts {
			if j <= i || a != b {
				continue
			}
			if -a == res.diff {
				res.explain = "une opération semble importée deux fois"
				res.suspect_a = ids[i]
				res.suspect_b = ids[j]
				return
			}
		}
	}
	if res.diff > 0 {
		res.explain = "le relevé est plus élevé: une recette manque au livre"
	} else {
		res.explain = "le relevé est plus bas: une dépense manque au livre"
	}
}

// recon_mark_cleared marks every transaction on the account up to the
// statement date. It is only offered when the balances agree: marking rows
// cleared while the difference is non-zero records an agreement that does not
// exist, and then nobody can find the error later.
recon_mark_cleared :: proc(app: ^App, account: int) -> (n: int, ok: bool) {
	res := recon_check(app, account)
	if !res.has_target || !res.agrees {
		return 0, false
	}
	l := &app.led
	for &t in l.txns {
		if t.dead || t.cleared {
			continue
		}
		acct, _, has := txn_asset_side(l, &t)
		if !has || acct != account || date_less(res.as_of, t.date) {
			continue
		}
		t.cleared = true
		n += 1
	}
	return n, true
}

// recon_uncleared lists what has not been reconciled, oldest first — the
// working list when a balance does not come out.
recon_uncleared :: proc(app: ^App, account: int, allocator := context.temp_allocator) -> []int {
	l := &app.led
	out := make([dynamic]int, allocator)
	for &t, i in l.txns {
		if t.dead || t.cleared {
			continue
		}
		acct, _, has := txn_asset_side(l, &t)
		if !has || acct != account {
			continue
		}
		append(&out, i)
	}
	sort_by_date(l, out[:], false)
	return out[:]
}

// ---------------------------------------------------------------------------
// Balance over time, which the chart draws and the reconciliation reads
// ---------------------------------------------------------------------------

Balance_Point :: struct {
	date:    Date,
	balance: Cents,
}

// balance_series is the account's balance after each day on which something
// happened, oldest first. One point per day rather than per transaction: a
// chart of a thousand transactions over a year wants 365 points at most, and
// the intra-day order of two card payments is not information.
balance_series :: proc(
	l: ^Ledger,
	account: int,
	lo, hi: Date,
	allocator := context.temp_allocator,
) -> []Balance_Point {
	// Start from the balance carried into the window, so the line does not
	// begin at zero when the account has a history.
	running := balance_at(l, account, date_add(lo, -1))

	days := make([dynamic]Balance_Point, allocator)
	idx := make([dynamic]int, context.temp_allocator)
	for &t, i in l.txns {
		if t.dead || !date_within(t.date, lo, hi) {
			continue
		}
		for e in t.entries {
			if e.account == account {
				append(&idx, i)
				break
			}
		}
	}
	sort_by_date(l, idx[:], false)

	append(&days, Balance_Point{date_add(lo, -1), running})
	for k := 0; k < len(idx); {
		d := l.txns[idx[k]].date
		for k < len(idx) && date_eq(l.txns[idx[k]].date, d) {
			for e in l.txns[idx[k]].entries {
				if e.account == account {
					running += e.amount
				}
			}
			k += 1
		}
		append(&days, Balance_Point{d, running})
	}
	return days[:]
}

_ :: slice
