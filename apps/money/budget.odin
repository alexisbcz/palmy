// Budgets: one envelope per category per month.
//
// The arithmetic is deliberately plain — limit minus spent, in centimes — and
// the two things that make a budget tool trustworthy are both here.
//
// The first is that the boundary is exact. Spending exactly the limit is not
// over budget; one centime more is. There is no epsilon, because there are no
// floats, so "did I go over" has an answer rather than a rounding.
//
// The second is **rollover**. An envelope that does not carry forward is not
// an envelope: if 300 € is budgeted for groceries and 280 € is spent, the
// 20 € is still there in April. Rollover is per budget line and the carry is
// computed by walking back through the earlier months, bounded, so a long
// history cannot turn a frame into a loop. A category whose rollover is off
// simply starts each month at its limit, which is what a fixed charge wants.
package main

import "core:slice"

Budget :: struct {
	category: int, // an account index, always an Expense or Income account
	year:     int,
	month:    int, // 1..12
	limit:    Cents, // positive: the size of the envelope
	rollover: bool,
}

// ROLLOVER_DEPTH bounds the walk back through previous months. Two years is
// more carry than any envelope means anything over, and it stops a corrupt
// store from spinning.
ROLLOVER_DEPTH :: 24

Budget_Line :: struct {
	category:  int,
	limit:     Cents, // this month's allocation
	carry:     Cents, // brought forward; can be negative after an overspend
	available: Cents, // limit + carry
	spent:     Cents, // positive
	left:      Cents, // available - spent; negative when over
	over:      bool,
	pct:       int, // spent as a percentage of available, 0 when there is none
	count:     int, // how many transactions
}

budget_find :: proc(app: ^App, category, y, m: int) -> int {
	for b, i in app.budgets {
		if b.category == category && b.year == y && b.month == m {
			return i
		}
	}
	return -1
}

// budget_set creates, updates or (with a limit of zero) removes an envelope.
budget_set :: proc(app: ^App, category, y, m: int, limit: Cents, rollover := true) {
	i := budget_find(app, category, y, m)
	if limit <= 0 {
		if i >= 0 {
			ordered_remove(&app.budgets, i)
		}
		return
	}
	if i >= 0 {
		app.budgets[i].limit = limit
		app.budgets[i].rollover = rollover
		return
	}
	append(&app.budgets, Budget{category, y, m, limit, rollover})
}

budget_limit :: proc(app: ^App, category, y, m: int) -> (limit: Cents, rollover: bool, ok: bool) {
	i := budget_find(app, category, y, m)
	if i < 0 {
		return 0, false, false
	}
	return app.budgets[i].limit, app.budgets[i].rollover, true
}

// category_spent is what left the category's envelope in one month.
//
// An expense category's entries are positive when money is spent, so the sum
// is returned as-is and a refund — a negative entry on the category — reduces
// it, which is the behaviour a user expects when a shop refunds them.
// Transfers are excluded entirely.
category_spent :: proc(app: ^App, category, y, m: int) -> (total: Cents, count: int) {
	lo := Date{y, m, 1}
	hi := Date{y, m, days_in_month(y, m)}
	l := &app.led
	for &t in l.txns {
		if t.dead || !date_within(t.date, lo, hi) || txn_is_transfer(l, &t) {
			continue
		}
		for e in t.entries {
			if e.account == category {
				total += e.amount
				count += 1
			}
		}
	}
	return
}

// budget_carry is what an envelope brings forward from the month before.
//
// It recurses backwards while the previous month also had a rollover budget,
// which is what makes a chain of months behave like one envelope. The walk is
// depth-limited and the limit is a real stop, not an assertion: a store that
// claims a thousand months of history gets twenty-four of carry and a correct
// answer for this month.
budget_carry :: proc(app: ^App, category, y, m: int, depth := ROLLOVER_DEPTH) -> Cents {
	if depth <= 0 {
		return 0
	}
	prev := date_month_add(Date{y, m, 1}, -1)
	limit, rollover, ok := budget_limit(app, category, prev.y, prev.m)
	if !ok || !rollover {
		return 0
	}
	spent, _ := category_spent(app, category, prev.y, prev.m)
	carry := budget_carry(app, category, prev.y, prev.m, depth - 1)
	return limit + carry - spent
}

// budget_line is one envelope, resolved.
budget_line :: proc(app: ^App, category, y, m: int) -> (line: Budget_Line, ok: bool) {
	limit, rollover, found := budget_limit(app, category, y, m)
	if !found {
		return {}, false
	}
	spent, count := category_spent(app, category, y, m)
	carry: Cents = 0
	if rollover {
		carry = budget_carry(app, category, y, m)
	}
	available := limit + carry
	left := available - spent
	pct := 0
	if available > 0 {
		// Integer percent, truncated: 99,9 % of an envelope reads as 99 %, so
		// a bar that shows 100 % really is full.
		pct = int((i64(spent) * 100) / i64(available))
		if pct < 0 {
			pct = 0
		}
	} else if spent > 0 {
		pct = 100
	}
	return Budget_Line {
			category = category,
			limit = limit,
			carry = carry,
			available = available,
			spent = spent,
			left = left,
			over = spent > available,
			pct = pct,
			count = count,
		},
		true
}

// budget_month is every envelope for a month, worst first — the view that
// answers "what is about to go wrong" without reading a single number.
budget_month :: proc(app: ^App, y, m: int, allocator := context.temp_allocator) -> []Budget_Line {
	out := make([dynamic]Budget_Line, allocator)
	for b in app.budgets {
		if b.year != y || b.month != m {
			continue
		}
		if line, ok := budget_line(app, b.category, y, m); ok {
			append(&out, line)
		}
	}
	slice.sort_by(out[:], proc(a, b: Budget_Line) -> bool {
		// Over budget first, then by how full the envelope is.
		if a.over != b.over {
			return a.over
		}
		if a.pct != b.pct {
			return a.pct > b.pct
		}
		return a.category < b.category
	})
	return out[:]
}

Budget_Totals :: struct {
	available: Cents,
	spent:     Cents,
	left:      Cents,
	over:      int, // how many envelopes are over
	lines:     int,
}

budget_totals :: proc(app: ^App, y, m: int) -> (tot: Budget_Totals) {
	for line in budget_month(app, y, m) {
		tot.available += line.available
		tot.spent += line.spent
		tot.left += line.left
		tot.lines += 1
		if line.over {
			tot.over += 1
		}
	}
	return
}

// budget_copy_month carries a whole month's envelopes to another month, which
// is how a budget is actually set up: once, and then every month after.
budget_copy_month :: proc(app: ^App, from_y, from_m, to_y, to_m: int) -> (n: int) {
	// Copy to a temporary first: appending to app.budgets while iterating it
	// would both reallocate under the loop and copy the new entries again.
	src := make([dynamic]Budget, 0, len(app.budgets), context.temp_allocator)
	for b in app.budgets {
		if b.year == from_y && b.month == from_m {
			append(&src, b)
		}
	}
	for b in src {
		budget_set(app, b.category, to_y, to_m, b.limit, b.rollover)
		n += 1
	}
	return
}

// budget_suggest proposes an envelope from history: the average of what this
// category actually cost over the last `months` months that have any
// spending, rounded up to the nearest 5 €. A suggestion rounded to the
// centime would be false precision.
budget_suggest :: proc(app: ^App, category, y, m: int, months := 6) -> Cents {
	total: Cents = 0
	n := 0
	for k in 1 ..= months {
		prev := date_month_add(Date{y, m, 1}, -k)
		spent, count := category_spent(app, category, prev.y, prev.m)
		if count == 0 {
			continue
		}
		total += spent
		n += 1
	}
	if n == 0 {
		return 0
	}
	avg := i64(total) / i64(n)
	if avg <= 0 {
		return 0
	}
	// Up to the next 5 €.
	step := i64(500)
	return Cents(((avg + step - 1) / step) * step)
}
