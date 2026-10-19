// RRULE (RFC 5545 section 3.3.10) evaluated on wall-clock time.
//
// The iterator walks one period at a time — a year, a month, a week, a day,
// an hour... stepping by INTERVAL — and builds that period's whole candidate
// set from the BYxxx parts before applying BYSETPOS. Expansion and limiting
// (the table on RFC 5545 page 44) come out of one rule: a day belongs to the
// period's set when every BYxxx part present accepts it, and when a part is
// absent the value is taken from DTSTART exactly where the RFC says so. That
// is also how python-dateutil and libical read it, and the self-test holds
// it to the RFC's own examples.
//
// Everything is in "local seconds" (the wall clock as if it were UTC). The
// caller converts each occurrence to an instant in its zone; UNTIL is
// compared through the same zone when it is given in UTC.
package ical

import "core:slice"
import "core:strconv"
import "core:strings"

Freq :: enum u8 {
	None,
	Secondly,
	Minutely,
	Hourly,
	Daily,
	Weekly,
	Monthly,
	Yearly,
}

By_Day :: struct {
	ord: int, // 0 for every such weekday, else +n / -n
	wd:  int, // 0 = MO ... 6 = SU
}

RRule :: struct {
	freq:        Freq,
	interval:    int,
	count:       int, // 0: unbounded by count
	until:       DT,
	until_set:   bool,
	by_second:   []int,
	by_minute:   []int,
	by_hour:     []int,
	by_day:      []By_Day,
	by_monthday: []int,
	by_yearday:  []int,
	by_weekno:   []int,
	by_month:    []int,
	by_setpos:   []int,
	wkst:        int, // 0 = MO
}

WEEKDAY_CODES := [7]string{"MO", "TU", "WE", "TH", "FR", "SA", "SU"}

bounded :: proc(r: RRule) -> bool {
	return r.count > 0 || r.until_set
}

parse_rrule :: proc(s: string) -> (r: RRule, ok: bool) {
	r.interval = 1
	for part in strings.split(strings.trim_space(s), ";", context.temp_allocator) {
		eq := strings.index_byte(part, '=')
		if eq < 0 {
			if strings.trim_space(part) == "" {
				continue
			}
			return {}, false
		}
		key := strings.to_upper(strings.trim_space(part[:eq]), context.temp_allocator)
		val := strings.trim_space(part[eq + 1:])
		switch key {
		case "FREQ":
			switch strings.to_upper(val, context.temp_allocator) {
			case "SECONDLY": r.freq = .Secondly
			case "MINUTELY": r.freq = .Minutely
			case "HOURLY": r.freq = .Hourly
			case "DAILY": r.freq = .Daily
			case "WEEKLY": r.freq = .Weekly
			case "MONTHLY": r.freq = .Monthly
			case "YEARLY": r.freq = .Yearly
			case: return {}, false
			}
		case "INTERVAL":
			n, good := strconv.parse_int(val)
			if !good || n < 1 {
				return {}, false
			}
			r.interval = n
		case "COUNT":
			n, good := strconv.parse_int(val)
			if !good || n < 1 {
				return {}, false
			}
			r.count = n
		case "UNTIL":
			t, good := parse_dt(val)
			if !good {
				return {}, false
			}
			r.until = t
			r.until_set = true
		case "BYSECOND":
			r.by_second = int_list(val, 0, 60, false) or_return
		case "BYMINUTE":
			r.by_minute = int_list(val, 0, 59, false) or_return
		case "BYHOUR":
			r.by_hour = int_list(val, 0, 23, false) or_return
		case "BYMONTHDAY":
			r.by_monthday = int_list(val, 1, 31, true) or_return
		case "BYYEARDAY":
			r.by_yearday = int_list(val, 1, 366, true) or_return
		case "BYWEEKNO":
			r.by_weekno = int_list(val, 1, 53, true) or_return
		case "BYMONTH":
			r.by_month = int_list(val, 1, 12, false) or_return
		case "BYSETPOS":
			r.by_setpos = int_list(val, 1, 366, true) or_return
		case "WKST":
			wd, good := weekday_code(val)
			if !good {
				return {}, false
			}
			r.wkst = wd
		case "BYDAY":
			list := make([dynamic]By_Day, 0, 4)
			for item in strings.split(val, ",", context.temp_allocator) {
				it := strings.trim_space(item)
				if len(it) < 2 {
					return {}, false
				}
				wd, good := weekday_code(it[len(it) - 2:])
				if !good {
					return {}, false
				}
				ord := 0
				if len(it) > 2 {
					n, nok := strconv.parse_int(it[:len(it) - 2])
					if !nok || n == 0 || n < -53 || n > 53 {
						return {}, false
					}
					ord = n
				}
				append(&list, By_Day{ord, wd})
			}
			r.by_day = list[:]
		case:
		// X-names and unknown parts are ignored, as RFC 5545 allows.
		}
	}
	return r, r.freq != .None
}

@(private)
int_list :: proc(val: string, lo, hi: int, signed: bool) -> (out: []int, ok: bool) {
	list := make([dynamic]int, 0, 4)
	for item in strings.split(val, ",", context.temp_allocator) {
		n, good := strconv.parse_int(strings.trim_space(item))
		if !good {
			return nil, false
		}
		a := n < 0 ? -n : n
		if (n < 0 && !signed) || a < lo || a > hi || (n == 0 && lo > 0) {
			return nil, false
		}
		append(&list, n)
	}
	return list[:], true
}

weekday_code :: proc(s: string) -> (int, bool) {
	u := strings.to_upper(strings.trim_space(s), context.temp_allocator)
	for code, i in WEEKDAY_CODES {
		if code == u {
			return i, true
		}
	}
	return 0, false
}

format_rrule :: proc(r: RRule, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	names := [Freq]string {
		.None     = "",
		.Secondly = "SECONDLY",
		.Minutely = "MINUTELY",
		.Hourly   = "HOURLY",
		.Daily    = "DAILY",
		.Weekly   = "WEEKLY",
		.Monthly  = "MONTHLY",
		.Yearly   = "YEARLY",
	}
	strings.write_string(&b, "FREQ=")
	strings.write_string(&b, names[r.freq])
	if r.interval > 1 {
		strings.write_string(&b, ";INTERVAL=")
		strings.write_int(&b, r.interval)
	}
	if r.count > 0 {
		strings.write_string(&b, ";COUNT=")
		strings.write_int(&b, r.count)
	}
	if r.until_set {
		strings.write_string(&b, ";UNTIL=")
		strings.write_string(&b, format_dt(r.until, context.temp_allocator))
	}
	list :: proc(b: ^strings.Builder, key: string, v: []int) {
		if len(v) == 0 {
			return
		}
		strings.write_byte(b, ';')
		strings.write_string(b, key)
		strings.write_byte(b, '=')
		for n, i in v {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			strings.write_int(b, n)
		}
	}
	list(&b, "BYMONTH", r.by_month)
	list(&b, "BYWEEKNO", r.by_weekno)
	list(&b, "BYYEARDAY", r.by_yearday)
	list(&b, "BYMONTHDAY", r.by_monthday)
	if len(r.by_day) > 0 {
		strings.write_string(&b, ";BYDAY=")
		for d, i in r.by_day {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			if d.ord != 0 {
				strings.write_int(&b, d.ord)
			}
			strings.write_string(&b, WEEKDAY_CODES[d.wd])
		}
	}
	list(&b, "BYHOUR", r.by_hour)
	list(&b, "BYMINUTE", r.by_minute)
	list(&b, "BYSECOND", r.by_second)
	list(&b, "BYSETPOS", r.by_setpos)
	if r.wkst != 0 {
		strings.write_string(&b, ";WKST=")
		strings.write_string(&b, WEEKDAY_CODES[r.wkst])
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Iteration
// ---------------------------------------------------------------------------

RRule_Iter :: struct {
	rule:        RRule,
	start:       DT,
	start_local: i64,
	until_local: i64, // max(i64) when unbounded
	until_zone:  ^Zone, // non-nil: UNTIL is UTC and the clock is zoned
	period:      i64, // how many periods have been generated
	pending:     [dynamic]i64, // this period's occurrences, ascending
	emitted:     int,
	empty_run:   int,
	done:        bool,
	start_sent:  bool,
}

// rrule_iter_make starts at DTSTART. `zone` is the zone of DTSTART's wall
// clock, needed only when UNTIL is in UTC and DTSTART is not.
rrule_iter_make :: proc(rule: RRule, start: DT, zone: ^Zone = nil) -> RRule_Iter {
	it := RRule_Iter {
		rule        = rule,
		start       = start,
		start_local = local_secs(start),
		until_local = max(i64),
	}
	it.pending = make([dynamic]i64, 0, 16)
	if rule.until_set {
		u := rule.until
		if u.is_date && !start.is_date {
			// UNTIL as a date with a date-time start: through that whole day.
			it.until_local = local_secs(u) + 86399
		} else if u.utc && !start.utc && !start.is_date && zone != nil && zone.kind != .UTC {
			it.until_zone = zone
			it.until_local = local_secs(u) // an instant; compared in rrule_next
		} else {
			it.until_local = local_secs(u)
		}
	}
	return it
}

// rrule_next yields the next occurrence, DTSTART first.
rrule_next :: proc(it: ^RRule_Iter) -> (DT, bool) {
	if it.done {
		return {}, false
	}
	if it.rule.count > 0 && it.emitted >= it.rule.count {
		it.done = true
		return {}, false
	}
	if !it.start_sent {
		it.start_sent = true
		it.emitted += 1
		return it.start, true
	}
	for len(it.pending) == 0 {
		if it.done {
			return {}, false
		}
		fill_period(it)
	}
	v := it.pending[0]
	ordered_remove(&it.pending, 0)
	// UNTIL is inclusive.
	past := false
	if it.until_zone != nil {
		past = to_utc(it.until_zone, v) > it.until_local
	} else {
		past = v > it.until_local
	}
	if past {
		it.done = true
		clear(&it.pending)
		return {}, false
	}
	it.emitted += 1
	return dt_from_local(v, it.start), true
}

// The empty-period guard: a rule that can never match (BYMONTHDAY=30 with
// BYMONTH=2) must stop rather than spin. 28 years cover every weekday and
// leap combination of a yearly rule; the finer rules get as many periods.
@(private)
MAX_EMPTY :: 400

@(private)
fill_period :: proc(it: ^RRule_Iter) {
	r := &it.rule
	k := it.period
	it.period += 1
	cands := make([dynamic]i64, 0, 32, context.temp_allocator)
	s := it.start
	start_days := days_from_civil(s.y, s.m, s.d)

	switch r.freq {
	case .None:
		it.done = true
		return
	case .Yearly:
		y := s.y + int(k) * r.interval
		if y > 9999 {
			it.done = true
			return
		}
		if len(r.by_weekno) > 0 {
			w0 := week1_start(y, r.wkst)
			w1 := week1_start(y + 1, r.wkst)
			for d := w0; d < w1; d += 1 {
				day_candidates(it, d, y, &cands)
			}
		} else {
			first := days_from_civil(y, 1, 1)
			last := days_from_civil(y, 12, 31)
			for d := first; d <= last; d += 1 {
				day_candidates(it, d, y, &cands)
			}
		}
	case .Monthly:
		mi := i64(s.y) * 12 + i64(s.m - 1) + k * i64(r.interval)
		y := int(mi / 12)
		m := int(mi % 12) + 1
		if y > 9999 {
			it.done = true
			return
		}
		first := days_from_civil(y, m, 1)
		for d := first; d < first + i64(days_in_month(y, m)); d += 1 {
			day_candidates(it, d, y, &cands)
		}
	case .Weekly:
		ws := start_days - i64((weekday_of_days(start_days) - r.wkst + 7) % 7)
		ws += k * 7 * i64(r.interval)
		if ws > 3000000 {
			it.done = true
			return
		}
		for d := ws; d < ws + 7; d += 1 {
			yy, _, _ := civil_from_days(d)
			day_candidates(it, d, yy, &cands)
		}
	case .Daily:
		d := start_days + k * i64(r.interval)
		if d > 3000000 {
			it.done = true
			return
		}
		yy, _, _ := civil_from_days(d)
		day_candidates(it, d, yy, &cands)
	case .Hourly, .Minutely, .Secondly:
		step := i64(3600)
		if r.freq == .Minutely {
			step = 60
		} else if r.freq == .Secondly {
			step = 1
		}
		base := it.start_local - (r.freq == .Hourly ? it.start_local % 3600 : (r.freq == .Minutely ? it.start_local % 60 : 0))
		p := base + k * step * i64(r.interval)
		if p > 253402300799 {
			it.done = true
			return
		}
		sub_candidates(it, p, &cands)
	}

	slice.sort(cands[:])
	// Deduplicate.
	uniq := make([dynamic]i64, 0, len(cands), context.temp_allocator)
	for v, i in cands {
		if i == 0 || v != cands[i - 1] {
			append(&uniq, v)
		}
	}
	chosen := uniq[:]
	if len(r.by_setpos) > 0 {
		sel := make([dynamic]i64, 0, len(r.by_setpos), context.temp_allocator)
		for pos in r.by_setpos {
			idx := pos > 0 ? pos - 1 : len(chosen) + pos
			if idx >= 0 && idx < len(chosen) {
				append(&sel, chosen[idx])
			}
		}
		slice.sort(sel[:])
		chosen = sel[:]
	}
	added := 0
	for v in chosen {
		if v > it.start_local {
			append(&it.pending, v)
			added += 1
		}
	}
	if added == 0 {
		it.empty_run += 1
		limit := MAX_EMPTY
		if r.freq == .Hourly || r.freq == .Minutely || r.freq == .Secondly {
			limit = 200000
		}
		if it.empty_run > limit {
			it.done = true
		}
	} else {
		it.empty_run = 0
	}
	// Anything past UNTIL in the whole period means the rule is finished
	// after these; rrule_next stops at the first one past.
}

// week1_start is the first day of week 1 of `y`: the first week, starting
// on WKST, with at least four days in the year.
week1_start :: proc(y: int, wkst: int) -> i64 {
	jan1 := days_from_civil(y, 1, 1)
	off := i64((weekday_of_days(jan1) - wkst + 7) % 7)
	start := jan1 - off
	if off > 3 {
		start += 7
	}
	return start
}

@(private)
day_matches :: proc(it: ^RRule_Iter, d: i64, period_year: int) -> bool {
	r := &it.rule
	y, m, md := civil_from_days(d)
	wd := weekday_of_days(d)
	s := it.start

	if len(r.by_month) > 0 && !slice.contains(r.by_month, m) {
		return false
	}
	if len(r.by_weekno) > 0 && r.freq == .Yearly {
		w0 := week1_start(period_year, r.wkst)
		w1 := week1_start(period_year + 1, r.wkst)
		if d < w0 || d >= w1 {
			return false
		}
		wn := int((d - w0) / 7) + 1
		nweeks := int((w1 - w0) / 7)
		hit := false
		for w in r.by_weekno {
			if w == wn || (w < 0 && nweeks + 1 + w == wn) {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	if len(r.by_yearday) > 0 {
		yd := int(d - days_from_civil(y, 1, 1)) + 1
		ylen := is_leap(y) ? 366 : 365
		hit := false
		for v in r.by_yearday {
			if v == yd || (v < 0 && ylen + 1 + v == yd) {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	if len(r.by_monthday) > 0 {
		dim := days_in_month(y, m)
		hit := false
		for v in r.by_monthday {
			if v == md || (v < 0 && dim + 1 + v == md) {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	if len(r.by_day) > 0 {
		hit := false
		for bd in r.by_day {
			if bd.wd != wd {
				continue
			}
			if bd.ord == 0 || !(r.freq == .Monthly || r.freq == .Yearly) {
				hit = true
				break
			}
			// The nth such weekday in the month (MONTHLY, or YEARLY with
			// BYMONTH) or in the year.
			lo, hi: i64
			if r.freq == .Monthly || len(r.by_month) > 0 {
				lo = days_from_civil(y, m, 1)
				hi = lo + i64(days_in_month(y, m)) - 1
			} else {
				lo = days_from_civil(y, 1, 1)
				hi = days_from_civil(y, 12, 31)
			}
			if bd.ord > 0 {
				first := lo + i64((wd - weekday_of_days(lo) + 7) % 7)
				if d == first + i64(bd.ord - 1) * 7 {
					hit = true
					break
				}
			} else {
				last := hi - i64((weekday_of_days(hi) - wd + 7) % 7)
				if d == last + i64(bd.ord + 1) * 7 {
					hit = true
					break
				}
			}
		}
		if !hit {
			return false
		}
	}

	// Defaults from DTSTART where the RFC takes them.
	no_day_parts := len(r.by_yearday) == 0 && len(r.by_monthday) == 0 && len(r.by_day) == 0
	switch r.freq {
	case .Yearly:
		if no_day_parts && len(r.by_weekno) == 0 {
			if len(r.by_month) == 0 && m != s.m {
				return false
			}
			if md != s.d {
				return false
			}
		} else if no_day_parts && len(r.by_weekno) > 0 {
			if wd != weekday_of_days(days_from_civil(s.y, s.m, s.d)) {
				return false
			}
		}
	case .Monthly:
		if no_day_parts && md != s.d {
			return false
		}
	case .Weekly:
		if len(r.by_day) == 0 && len(r.by_monthday) == 0 && len(r.by_yearday) == 0 {
			if wd != weekday_of_days(days_from_civil(s.y, s.m, s.d)) {
				return false
			}
		}
	case .Daily, .Hourly, .Minutely, .Secondly, .None:
	}
	return true
}

@(private)
day_candidates :: proc(it: ^RRule_Iter, d: i64, period_year: int, out: ^[dynamic]i64) {
	if !day_matches(it, d, period_year) {
		return
	}
	r := &it.rule
	s := it.start
	base := d * 86400
	if s.is_date {
		append(out, base)
		return
	}
	hours := r.by_hour
	mins := r.by_minute
	secs := r.by_second
	one_h := [1]int{s.hh}
	one_m := [1]int{s.mm}
	one_s := [1]int{s.ss}
	if len(hours) == 0 {
		hours = one_h[:]
	}
	if len(mins) == 0 {
		mins = one_m[:]
	}
	if len(secs) == 0 {
		secs = one_s[:]
	}
	for h in hours {
		for mi in mins {
			for sc in secs {
				append(out, base + i64(h * 3600 + mi * 60 + min(sc, 59)))
			}
		}
	}
}

// Sub-daily periods: the period's instant, expanded by the finer BYxxx
// parts and limited by the coarser ones.
@(private)
sub_candidates :: proc(it: ^RRule_Iter, p: i64, out: ^[dynamic]i64) {
	r := &it.rule
	s := it.start
	d := p / 86400
	if p < 0 && p % 86400 != 0 {
		d -= 1
	}
	yy, _, _ := civil_from_days(d)
	if !day_matches(it, d, yy) {
		return
	}
	sod := int(p - d * 86400)
	h := sod / 3600
	mi := sod % 3600 / 60
	if len(r.by_hour) > 0 && !slice.contains(r.by_hour, h) {
		return
	}
	switch r.freq {
	case .Hourly:
		mins := r.by_minute
		secs := r.by_second
		one_m := [1]int{s.mm}
		one_s := [1]int{s.ss}
		if len(mins) == 0 {
			mins = one_m[:]
		}
		if len(secs) == 0 {
			secs = one_s[:]
		}
		for m2 in mins {
			for sc in secs {
				append(out, d * 86400 + i64(h * 3600 + m2 * 60 + min(sc, 59)))
			}
		}
	case .Minutely:
		if len(r.by_minute) > 0 && !slice.contains(r.by_minute, mi) {
			return
		}
		secs := r.by_second
		one_s := [1]int{s.ss}
		if len(secs) == 0 {
			secs = one_s[:]
		}
		for sc in secs {
			append(out, d * 86400 + i64(h * 3600 + mi * 60 + min(sc, 59)))
		}
	case .Secondly:
		if len(r.by_minute) > 0 && !slice.contains(r.by_minute, mi) {
			return
		}
		if len(r.by_second) > 0 && !slice.contains(r.by_second, sod % 60) {
			return
		}
		append(out, p)
	case .None, .Daily, .Weekly, .Monthly, .Yearly:
	}
}
