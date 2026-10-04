// Finding the subscriptions.
//
// A statement is a few hundred rows a month and most of them are noise. The
// useful question is which of them repeat: the mobile contract, the
// insurance, the streaming service, the standing order to savings. Those are
// the charges a person has forgotten they pay, and the only way to find them
// is to look for the pattern.
//
// The pattern is a *merchant, an amount and a cadence*, together:
//
//   * **merchant** — the key from rules.odin, which is the label with the
//     dates, card suffixes and mandate references stripped off. Without that
//     step `PRLV SEPA EDF ECH 210926` and `PRLV SEPA EDF ECH 211026` are two
//     different merchants and nothing is ever found.
//   * **amount** — within a tolerance, because an energy bill moves by a few
//     centimes and an insurance premium is re-rated once a year. The
//     tolerance is the larger of 1 € and 8 % of the median, and the median is
//     used rather than the mean so one outlier cannot drag it.
//   * **cadence** — regular. Monthly is tested on *month indices*, not on
//     day counts: consecutive months differ by exactly one month index and
//     the day of month stays within a few days. Testing monthly in days
//     fails on February, and a tool that loses February is not useful.
//
// Three occurrences is the minimum. Two points define an interval, not a
// cadence, and a pair of identical charges a month apart is as likely to be
// coincidence as a subscription — so a pair is reported as nothing at all.
// The false-positive behaviour is asserted in the selftest: a series with
// irregular gaps, a series of two, and a series whose amounts vary by 40 %
// are each generated deliberately and must *not* be detected.
package main

import "core:slice"
import "core:strings"

Cadence :: enum {
	None,
	Weekly,
	Fortnightly,
	Monthly,
	Quarterly,
	Yearly,
}

cadence_label :: proc(c: Cadence) -> string {
	switch c {
	case .None:
		return "—"
	case .Weekly:
		return "hebdomadaire"
	case .Fortnightly:
		return "tous les 15 jours"
	case .Monthly:
		return "mensuel"
	case .Quarterly:
		return "trimestriel"
	case .Yearly:
		return "annuel"
	}
	return "—"
}

cadence_days :: proc(c: Cadence) -> int {
	switch c {
	case .None:
		return 0
	case .Weekly:
		return 7
	case .Fortnightly:
		return 14
	case .Monthly:
		return 30
	case .Quarterly:
		return 91
	case .Yearly:
		return 365
	}
	return 0
}

Recurrence :: struct {
	key:        string, // the merchant key
	label:      string, // the most recent label, for display
	category:   int, // the category the occurrences are in, -1 if mixed
	method:     Method,
	amount:     Cents, // the median; signed, so a debit is negative
	spread:     Cents, // how much the amounts vary, largest minus smallest
	cadence:    Cadence,
	count:      int,
	first:      Date,
	last:       Date,
	next:       Date, // when the next one is expected
	day:        int, // the usual day of the month
	confidence: int, // 0..100
	txns:       []int, // indexes into Ledger.txns, oldest first
}

// RECUR_MIN_COUNT is three. See the note at the top of the file: this is the
// single most important number here, and lowering it to two is what makes a
// recurrence detector produce nonsense.
RECUR_MIN_COUNT :: 3

// Amount tolerance: the larger of these two, so a 4,99 € subscription is held
// to 1 € and a 1 200 € rent to 96 €.
RECUR_TOL_ABS :: Cents(100)
RECUR_TOL_PCT :: 8

// RECUR_DAY_SPREAD is how far the day of the month may wander. A direct debit
// lands on a working day, so a charge due on the 15th arrives on the 15th,
// 16th or 17th depending on the weekend.
RECUR_DAY_SPREAD :: 4

@(private = "file")
Group :: struct {
	key:  string,
	idx:  [dynamic]int,
	sign: int,
}

// find_recurrences scans the whole book.
//
// Only transactions with an asset side count, and the sign is part of the
// grouping: a salary in and a payment out to the same name are two different
// recurrences, which is right — a refund from a shop you also buy from is
// not the same series as the purchases.
find_recurrences :: proc(
	l: ^Ledger,
	today: Date,
	allocator := context.temp_allocator,
) -> []Recurrence {
	groups := make(map[string]Group, context.temp_allocator)

	for &t, i in l.txns {
		if t.dead {
			continue
		}
		amount := txn_amount(l, &t)
		if amount == 0 {
			continue
		}
		key := merchant_key(t.label, context.temp_allocator)
		if key == "" {
			continue
		}
		sign := amount < 0 ? -1 : 1
		full := strings.concatenate(
			{key, sign < 0 ? " -" : " +"},
			context.temp_allocator,
		)
		g, exists := groups[full]
		if !exists {
			g = Group {
				key  = key,
				idx  = make([dynamic]int, context.temp_allocator),
				sign = sign,
			}
		}
		append(&g.idx, i)
		groups[full] = g
	}

	out := make([dynamic]Recurrence, allocator)
	for _, g in groups {
		if len(g.idx) < RECUR_MIN_COUNT {
			continue
		}
		if r, ok := classify_group(l, g.key, g.idx[:], today, allocator); ok {
			append(&out, r)
		}
	}
	slice.sort_by(out[:], proc(a, b: Recurrence) -> bool {
		// Biggest commitment first: a 40 € monthly charge matters more than
		// a 4 € one, and both matter more than something yearly.
		am := money_abs(monthly_equivalent(a))
		bm := money_abs(monthly_equivalent(b))
		if am != bm {
			return am > bm
		}
		return a.key < b.key
	})
	return out[:]
}

// monthly_equivalent normalises a recurrence to what it costs per month, so a
// yearly insurance premium and a monthly subscription can be compared and
// added up. A year is twelve months and a quarter is three; a week is
// 52/12 weeks per month, done in integers as 13/3.
// The sign is kept: a salary's monthly equivalent is positive and a charge's
// is negative, so a caller can add them up and get a net figure.
monthly_equivalent :: proc(r: Recurrence) -> Cents {
	a := r.amount
	switch r.cadence {
	case .Weekly:
		return money_percent(a, 13, 3)
	case .Fortnightly:
		return money_percent(a, 13, 6)
	case .Monthly:
		return a
	case .Quarterly:
		return money_percent(a, 1, 3)
	case .Yearly:
		return money_percent(a, 1, 12)
	case .None:
		return 0
	}
	return 0
}

@(private = "file")
classify_group :: proc(
	l: ^Ledger,
	key: string,
	idx_in: []int,
	today: Date,
	allocator := context.temp_allocator,
) -> (
	rec: Recurrence,
	ok: bool,
) {
	idx := slice.clone(idx_in, context.temp_allocator)
	ctx := Recur_Sort{l}
	slice.sort_by_with_data(idx, proc(a, b: int, data: rawptr) -> bool {
		c := (^Recur_Sort)(data)
		if !date_eq(c.l.txns[a].date, c.l.txns[b].date) {
			return date_less(c.l.txns[a].date, c.l.txns[b].date)
		}
		return c.l.txns[a].id < c.l.txns[b].id
	}, &ctx)

	// Amounts.
	amounts := make([]Cents, len(idx), context.temp_allocator)
	for i, k in idx {
		amounts[k] = txn_amount(l, &l.txns[i])
	}
	sorted := slice.clone(amounts, context.temp_allocator)
	slice.sort(sorted)
	median := sorted[len(sorted) / 2]
	spread := sorted[len(sorted) - 1] - sorted[0]

	tol := RECUR_TOL_ABS
	if pct := money_abs(money_percent(median, RECUR_TOL_PCT, 100)); pct > tol {
		tol = pct
	}
	for a in amounts {
		if money_abs(a - median) > tol {
			return {}, false // the amounts do not agree: not one charge
		}
	}

	// Cadence. Monthly, quarterly and yearly are tested on month indices;
	// weekly and fortnightly on day counts, where months do not come into it.
	//
	// The monthly tests run on a *collapsed* sequence — one occurrence per
	// month. A real statement has the odd extra charge from the same
	// merchant in one month (a second trip to the same shop, or an export
	// that overlaps a month already imported), and testing the raw sequence
	// makes the gap between those two zero months, which fails the test and
	// loses a subscription that is plainly there. This was found by running
	// the demo: importing September over a book that already had September
	// silently stopped two subscriptions being detected.
	monthly := collapse_months(l, idx, context.temp_allocator)
	// If collapsing threw away a lot, the series is not one charge a month;
	// it is a shop visited often, and calling that a subscription would be
	// a false positive.
	collapsed_ok := len(monthly) * 10 >= len(idx) * 6

	cad := Cadence.None
	switch {
	case collapsed_ok && months_apart(l, monthly, 1):
		cad = .Monthly
	case days_apart(l, idx, 7, 2):
		cad = .Weekly
	case days_apart(l, idx, 14, 3):
		cad = .Fortnightly
	case collapsed_ok && months_apart(l, monthly, 3):
		cad = .Quarterly
	case collapsed_ok && months_apart(l, monthly, 12):
		cad = .Yearly
	}
	if cad == .None {
		return {}, false
	}

	first := l.txns[idx[0]].date
	last := l.txns[idx[len(idx) - 1]].date

	// The expected next occurrence.
	next: Date
	switch cad {
	case .Monthly:
		next = date_month_add(last, 1)
	case .Quarterly:
		next = date_month_add(last, 3)
	case .Yearly:
		next = date_month_add(last, 12)
	case .Weekly:
		next = date_add(last, 7)
	case .Fortnightly:
		next = date_add(last, 14)
	case .None:
	}

	// Confidence: how many occurrences, how steady the amount, and whether
	// the series is still running. A subscription cancelled six months ago
	// should not be presented as a live commitment.
	conf := 40
	conf += min(len(idx) - RECUR_MIN_COUNT, 6) * 5 // up to +30 for a long run
	if spread == 0 {
		conf += 20
	} else if money_abs(spread) <= tol / 2 {
		conf += 10
	}
	gap := days_from_civil(today) - days_from_civil(last)
	expected := cadence_days(cad)
	if gap > expected * 2 {
		conf -= 25 // probably finished
	} else if gap <= expected + 7 {
		conf += 10
	}
	conf = clamp(conf, 0, 100)

	// The category, when every occurrence agrees on one.
	cat := txn_category(l, &l.txns[idx[0]])
	for i in idx {
		if txn_category(l, &l.txns[i]) != cat {
			cat = -1
			break
		}
	}

	return Recurrence {
			key = strings.clone(key, allocator),
			label = strings.clone(l.txns[idx[len(idx) - 1]].label, allocator),
			category = cat,
			method = l.txns[idx[len(idx) - 1]].method,
			amount = median,
			spread = spread,
			cadence = cad,
			count = len(idx),
			first = first,
			last = last,
			next = next,
			day = last.d,
			confidence = conf,
			txns = slice.clone(idx, allocator),
		},
		true
}

@(private = "file")
Recur_Sort :: struct {
	l: ^Ledger,
}

// collapse_months keeps one occurrence per month, the earliest, so that an
// extra charge in a month cannot break a monthly chain. The input is already
// sorted by date, so "earliest in the month" is simply the first one seen.
@(private = "file")
collapse_months :: proc(l: ^Ledger, idx: []int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(idx), allocator)
	last_month := -1 << 40
	for i in idx {
		m := date_month_index(l.txns[i].date)
		if m == last_month {
			continue
		}
		last_month = m
		append(&out, i)
	}
	return out[:]
}

// months_apart tests a monthly, quarterly or yearly cadence on month indices.
//
// Every consecutive pair must be exactly `step` months apart, and the day of
// the month must stay within RECUR_DAY_SPREAD — except where the earlier day
// is near the end of a short month, which is the 31st-of-the-month case: a
// charge due on the 31st falls on the 28th in February and that is the same
// subscription, not a different one.
@(private = "file")
months_apart :: proc(l: ^Ledger, idx: []int, step: int) -> bool {
	if len(idx) < RECUR_MIN_COUNT {
		return false
	}
	for k in 1 ..< len(idx) {
		a := l.txns[idx[k - 1]].date
		b := l.txns[idx[k]].date
		if date_month_index(b) - date_month_index(a) != step {
			return false
		}
		diff := abs(b.d - a.d)
		if diff <= RECUR_DAY_SPREAD {
			continue
		}
		// End-of-month: both dates within three days of their month's end.
		if a.d >= days_in_month(a.y, a.m) - 3 && b.d >= days_in_month(b.y, b.m) - 3 {
			continue
		}
		return false
	}
	return true
}

// days_apart tests a cadence measured in days, within a tolerance.
@(private = "file")
days_apart :: proc(l: ^Ledger, idx: []int, period, tol: int) -> bool {
	if len(idx) < RECUR_MIN_COUNT {
		return false
	}
	for k in 1 ..< len(idx) {
		a := days_from_civil(l.txns[idx[k - 1]].date)
		b := days_from_civil(l.txns[idx[k]].date)
		if abs(b - a - period) > tol {
			return false
		}
	}
	return true
}

// recurring_monthly_total is the standing cost of everything detected: the
// number a person wants when they ask where the money goes before they have
// spent any of it.
recurring_monthly_total :: proc(recs: []Recurrence, min_confidence := 50) -> (out, income: Cents) {
	for r in recs {
		if r.confidence < min_confidence {
			continue
		}
		m := money_abs(monthly_equivalent(r))
		if r.amount < 0 {
			out += m
		} else {
			income += m
		}
	}
	return
}

// upcoming is the recurrences expected within `days`, soonest first — the
// thing to show on a dashboard, because it answers "what is about to leave
// the account".
upcoming :: proc(
	recs: []Recurrence,
	today: Date,
	days := 31,
	allocator := context.temp_allocator,
) -> []Recurrence {
	out := make([dynamic]Recurrence, allocator)
	t := days_from_civil(today)
	for r in recs {
		if r.confidence < 50 {
			continue
		}
		n := days_from_civil(r.next)
		if n >= t - 3 && n <= t + days {
			append(&out, r)
		}
	}
	slice.sort_by(out[:], proc(a, b: Recurrence) -> bool {
		return date_less(a.next, b.next)
	})
	return out[:]
}
