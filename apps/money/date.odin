// Dates, as integer day numbers.
//
// The civil-from-days pair is Howard Hinnant's, the same algorithm the
// calendar app in this repo (`apps/calendar/date.odin`) uses — read rather
// than reinvented, and deliberately not edited there. Everything else is
// integer arithmetic on the day number, which is right for leap years and the
// century rules by construction and makes "is this transaction in March" a
// comparison of two integers.
//
// A statement arrives with dates in whatever form the bank felt like:
// `31/01/2026`, `31/01/26`, `2026-01-31`, `20260131`. All of them land here.
package main

import "core:strconv"
import "core:strings"

Date :: struct {
	y: int,
	m: int, // 1..12
	d: int, // 1..31
}

date_is_leap :: proc(y: int) -> bool {
	return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

DATE_MONTH_DAYS := [?]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

days_in_month :: proc(y, m: int) -> int {
	if m == 2 {
		return date_is_leap(y) ? 29 : 28
	}
	if m < 1 || m > 12 {
		return 0
	}
	return DATE_MONTH_DAYS[m - 1]
}

// days_from_civil is the number of days since 1970-01-01, negative before it.
days_from_civil :: proc(date: Date) -> int {
	y := date.y
	m := date.m
	d := date.d
	y -= m <= 2 ? 1 : 0
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

civil_from_days :: proc(days: int) -> Date {
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + (mp < 10 ? 3 : -9)
	return Date{y + (m <= 2 ? 1 : 0), m, d}
}

// date_valid is a real calendar check, not a range check: 30 February fails,
// and 29 February passes only in a leap year. An importer that accepts
// 31/02/2026 has silently moved a transaction.
date_valid :: proc(d: Date) -> bool {
	if d.y < 1900 || d.y > 2200 {
		return false
	}
	if d.m < 1 || d.m > 12 {
		return false
	}
	return d.d >= 1 && d.d <= days_in_month(d.y, d.m)
}

date_cmp :: proc(a, b: Date) -> int {
	x := days_from_civil(a)
	y := days_from_civil(b)
	return x < y ? -1 : (x > y ? 1 : 0)
}

date_eq :: proc(a, b: Date) -> bool {
	return a.y == b.y && a.m == b.m && a.d == b.d
}

date_less :: proc(a, b: Date) -> bool {
	if a.y != b.y {
		return a.y < b.y
	}
	if a.m != b.m {
		return a.m < b.m
	}
	return a.d < b.d
}

// date_within is inclusive at both ends, because a user who types a range
// from the 1st to the 31st means the whole month.
date_within :: proc(d, lo, hi: Date) -> bool {
	return !date_less(d, lo) && !date_less(hi, d)
}

date_add :: proc(d: Date, days: int) -> Date {
	return civil_from_days(days_from_civil(d) + days)
}

// date_month_add moves by whole months and clamps the day, so 31 January plus
// one month is 28 or 29 February and never 3 March. A subscription billed on
// the 31st is exactly this case.
date_month_add :: proc(d: Date, months: int) -> Date {
	total := d.y * 12 + (d.m - 1) + months
	y := total / 12
	m := total % 12
	if m < 0 {
		m += 12
		y -= 1
	}
	return Date{y, m + 1, min(d.d, days_in_month(y, m + 1))}
}

// date_month_index is the count of months since year 0, which turns "same
// month" and "the month after" into integer equality and +1.
date_month_index :: proc(d: Date) -> int {
	return d.y * 12 + (d.m - 1)
}

month_start :: proc(d: Date) -> Date {
	return Date{d.y, d.m, 1}
}

month_end :: proc(d: Date) -> Date {
	return Date{d.y, d.m, days_in_month(d.y, d.m)}
}

MONTHS_FR := [?]string {
	"janvier",
	"février",
	"mars",
	"avril",
	"mai",
	"juin",
	"juillet",
	"août",
	"septembre",
	"octobre",
	"novembre",
	"décembre",
}

MONTHS_FR_SHORT := [?]string {
	"janv.",
	"févr.",
	"mars",
	"avr.",
	"mai",
	"juin",
	"juil.",
	"août",
	"sept.",
	"oct.",
	"nov.",
	"déc.",
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

Date_Format :: enum {
	Auto,
	DMY, // 31/01/2026, 31-01-2026, 31.01.2026
	MDY, // 01/31/2026 — rare in a French export, but a QFX from a US tool has it
	YMD, // 2026-01-31 or 20260131
}

// date_text is `31/01/2026`, which is the form every French bank prints.
date_text :: proc(d: Date, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	two(&b, d.d)
	strings.write_byte(&b, '/')
	two(&b, d.m)
	strings.write_byte(&b, '/')
	strings.write_int(&b, d.y)
	return strings.to_string(b)
}

// date_text_long is `31 janvier 2026`, for a header where the month name
// reads better than a number.
date_text_long :: proc(d: Date, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, d.d)
	strings.write_byte(&b, ' ')
	if d.m >= 1 && d.m <= 12 {
		strings.write_string(&b, MONTHS_FR[d.m - 1])
	}
	strings.write_byte(&b, ' ')
	strings.write_int(&b, d.y)
	return strings.to_string(b)
}

// month_text is `janvier 2026`.
month_text :: proc(y, m: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if m >= 1 && m <= 12 {
		strings.write_string(&b, MONTHS_FR[m - 1])
	}
	strings.write_byte(&b, ' ')
	strings.write_int(&b, y)
	return strings.to_string(b)
}

// date_iso is `2026-01-31`, which is what gets written to disk: it sorts as
// text, so a store file stays readable and diffable.
date_iso :: proc(d: Date, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, d.y)
	strings.write_byte(&b, '-')
	two(&b, d.m)
	strings.write_byte(&b, '-')
	two(&b, d.d)
	return strings.to_string(b)
}

@(private = "file")
two :: proc(b: ^strings.Builder, v: int) {
	if v < 10 && v >= 0 {
		strings.write_byte(b, '0')
	}
	strings.write_int(b, v)
}

// date_parse reads a date in any of the forms above.
//
// `.Auto` distinguishes DMY from YMD by where the four-digit field is, and
// from MDY by whether the first field can be a day — which is a genuine
// ambiguity for 03/04/2026, so an importer that knows its bank passes the
// format explicitly rather than relying on the guess.
date_parse :: proc(text: string, fmt_: Date_Format = .Auto) -> (d: Date, ok: bool) {
	s := strings.trim_space(text)
	if s == "" {
		return {}, false
	}
	// A timestamp: keep the date part. OFX writes 20260131120000.000[-5:EST].
	if i := strings.index_byte(s, 'T'); i == 8 || i == 10 {
		s = s[:i]
	}
	if i := strings.index_byte(s, ' '); i >= 8 {
		s = s[:i]
	}
	if i := strings.index_byte(s, '['); i > 0 {
		s = s[:i]
	}

	// A run of 8 or 14 digits with no separators.
	all_digits := len(s) > 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			all_digits = false
			break
		}
	}
	if all_digits {
		if len(s) >= 8 {
			y, _ := strconv.parse_int(s[0:4])
			m, _ := strconv.parse_int(s[4:6])
			dd, _ := strconv.parse_int(s[6:8])
			out := Date{y, m, dd}
			return out, date_valid(out)
		}
		return {}, false
	}

	// Split on the first separator character found.
	sep: u8 = 0
	for ch in ([?]u8{'/', '-', '.', ' '}) {
		if strings.index_byte(s, ch) >= 0 {
			sep = ch
			break
		}
	}
	if sep == 0 {
		return {}, false
	}
	sep_buf := [1]u8{sep}
	parts := strings.split(s, string(sep_buf[:]), context.temp_allocator)
	if len(parts) != 3 {
		return {}, false
	}
	a, oka := strconv.parse_int(strings.trim_space(parts[0]))
	b, okb := strconv.parse_int(strings.trim_space(parts[1]))
	c, okc := strconv.parse_int(strings.trim_space(parts[2]))
	if !oka || !okb || !okc {
		return {}, false
	}

	use := fmt_
	if use == .Auto {
		switch {
		case len(strings.trim_space(parts[0])) == 4:
			use = .YMD
		case a > 12:
			use = .DMY
		case c > 12 && len(strings.trim_space(parts[2])) <= 2:
			use = .DMY // 01/02/31 — the year is last whatever else is true
		case:
			use = .DMY // the French default; an importer says otherwise
		}
	}

	out: Date
	switch use {
	case .YMD:
		out = Date{a, b, c}
	case .DMY, .Auto:
		out = Date{c, b, a}
	case .MDY:
		out = Date{c, a, b}
	}
	// A two-digit year: 00..69 is this century, 70..99 the last. Every bank
	// export with a two-digit year is recent, so the window is generous in
	// the right direction.
	if out.y < 100 {
		out.y += out.y < 70 ? 2000 : 1900
	}
	return out, date_valid(out)
}
