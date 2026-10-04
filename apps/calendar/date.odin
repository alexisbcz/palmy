// Calendar arithmetic, computed rather than borrowed.
//
// Everything here comes out of one pair of functions: the civil-from-days and
// days-from-civil conversions (Howard Hinnant's, the ones the C++ chrono
// proposal uses). A date becomes an integer day number, and every question —
// which weekday is this, how long is February, which ISO week is it, what is
// the Monday of this week — is then plain integer arithmetic that is right for
// leap years and century rules by construction.
//
// `core:time` is linked in for "what time is it now"; the grid itself is
// worked out here.
package main

import "core:time"

Date :: struct {
	y: int,
	m: int, // 1..12
	d: int, // 1..31
}

is_leap :: proc(y: int) -> bool {
	return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

MONTH_DAYS := [?]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

days_in_month :: proc(y, m: int) -> int {
	if m == 2 {
		return is_leap(y) ? 29 : 28
	}
	if m < 1 || m > 12 {
		return 30
	}
	return MONTH_DAYS[m - 1]
}

// days_from_civil is the number of days since 1970-01-01, negative before it.
days_from_civil :: proc(date: Date) -> int {
	y := date.y
	m := date.m
	d := date.d
	y -= m <= 2 ? 1 : 0
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400 // [0, 399]
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 // [0, 365]
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
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

// weekday is 0 for Monday through 6 for Sunday. 1970-01-01 was a Thursday,
// which is index 3, and the +3 below is exactly that fact.
weekday :: proc(date: Date) -> int {
	n := days_from_civil(date) + 3
	return ((n % 7) + 7) % 7
}

date_add :: proc(date: Date, days: int) -> Date {
	return civil_from_days(days_from_civil(date) + days)
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

// month_add moves by whole months, clamping the day — 31 January plus one
// month is 28 or 29 February, not 3 March.
month_add :: proc(date: Date, months: int) -> Date {
	total := date.y * 12 + (date.m - 1) + months
	y := total / 12
	m := total % 12
	if m < 0 {
		m += 12
		y -= 1
	}
	return Date{y, m + 1, min(date.d, days_in_month(y, m + 1))}
}

// iso_week is the ISO-8601 week number and the year that week belongs to,
// which is not always the year the date is in: 1 January 2021 is week 53 of
// 2020. The rule is that a week belongs to the year of its Thursday.
iso_week :: proc(date: Date) -> (week: int, year: int) {
	n := days_from_civil(date)
	thursday := n - weekday(date) + 3
	t := civil_from_days(thursday)
	jan1 := days_from_civil(Date{t.y, 1, 1})
	return (thursday - jan1) / 7 + 1, t.y
}

// monday_of is the Monday that starts this date's week.
monday_of :: proc(date: Date) -> Date {
	return date_add(date, -weekday(date))
}

MONTHS := [?]string {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

MONTHS_SHORT := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

DAYS_SHORT := [?]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
DAYS_NARROW := [?]string{"M", "T", "W", "T", "F", "S", "S"}
DAYS_LONG := [?]string {
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
	"Sunday",
}

month_name :: proc(m: int) -> string {
	return m >= 1 && m <= 12 ? MONTHS[m - 1] : "?"
}

// today reads the wall clock and shifts it into local time. The timezone
// database is not linked in, so the offset comes from `date +%z`.
today :: proc(offset: i64) -> (Date, int) {
	now := time.now()
	local := time.Time{_nsec = now._nsec + offset * 1_000_000_000}
	y, m, d := time.date(local)
	hh, mm, _ := time.clock(local)
	return Date{y, int(m), d}, hh * 60 + mm
}

date_iso :: proc(date: Date) -> string {
	return tfmt("%04d-%02d-%02d", date.y, date.m, date.d)
}

parse_iso :: proc(s: string) -> (Date, bool) {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return {}, false
	}
	n := proc(t: string) -> (int, bool) {
		v := 0
		for i in 0 ..< len(t) {
			if t[i] < '0' || t[i] > '9' {
				return 0, false
			}
			v = v * 10 + int(t[i] - '0')
		}
		return v, true
	}
	y, ok1 := n(s[0:4])
	m, ok2 := n(s[5:7])
	d, ok3 := n(s[8:10])
	if !ok1 || !ok2 || !ok3 || m < 1 || m > 12 || d < 1 || d > days_in_month(y, m) {
		return {}, false
	}
	return Date{y, m, d}, true
}

// parse_clock accepts "9:30", "09:30" and "0930", and an empty string for an
// all-day entry.
parse_clock :: proc(s: string) -> (minutes: int, ok: bool) {
	if s == "" {
		return -1, true
	}
	h, m := 0, 0
	digits := 0
	seen_colon := false
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ':' {
			if seen_colon {
				return 0, false
			}
			seen_colon = true
			h = digits
			digits = 0
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		digits = digits * 10 + int(c - '0')
	}
	if seen_colon {
		m = digits
	} else {
		switch len(s) {
		case 1, 2:
			h = digits
			m = 0
		case 3, 4:
			h = digits / 100
			m = digits % 100
		case:
			return 0, false
		}
	}
	if h > 23 || m > 59 {
		return 0, false
	}
	return h * 60 + m, true
}

clock_text :: proc(minutes: int) -> string {
	if minutes < 0 {
		return "all day"
	}
	return tfmt("%02d:%02d", minutes / 60, minutes % 60)
}

duration_text :: proc(mins: int) -> string {
	if mins <= 0 {
		return ""
	}
	if mins < 60 {
		return tfmt("%d min", mins)
	}
	if mins % 60 == 0 {
		return tfmt("%d h", mins / 60)
	}
	return tfmt("%d h %d min", mins / 60, mins % 60)
}
