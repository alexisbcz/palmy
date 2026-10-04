// `calendar --selftest` checks the date arithmetic against dates whose answers
// are known independently. The month grid is only as correct as this is.
package main

import "core:fmt"

failures: int

check :: proc(ok: bool, what: string) {
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

run_selftest :: proc() {
	// Weekdays of dates whose day is a matter of record.
	check(weekday(Date{1970, 1, 1}) == 3, "1970-01-01 is a Thursday")
	check(weekday(Date{2000, 1, 1}) == 5, "2000-01-01 is a Saturday")
	check(weekday(Date{2024, 2, 29}) == 3, "2024-02-29 is a Thursday")
	check(weekday(Date{1900, 1, 1}) == 0, "1900-01-01 is a Monday")
	check(weekday(Date{2026, 10, 4}) == 6, "2026-10-04 is a Sunday")
	check(weekday(Date{1600, 2, 29}) == 1, "1600-02-29 is a Tuesday")

	// The century rule, which is the whole point of computing this.
	check(!is_leap(1900), "1900 is not a leap year")
	check(is_leap(2000), "2000 is a leap year")
	check(is_leap(2024), "2024 is a leap year")
	check(!is_leap(2100), "2100 is not a leap year")
	check(days_in_month(2024, 2) == 29, "February 2024 has 29 days")
	check(days_in_month(2023, 2) == 28, "February 2023 has 28 days")
	check(days_in_month(2000, 2) == 29, "February 2000 has 29 days")
	check(days_in_month(1900, 2) == 28, "February 1900 has 28 days")

	// ISO weeks, including the years where the week belongs to the other one.
	w, y := iso_week(Date{2021, 1, 1})
	check(w == 53 && y == 2020, "2021-01-01 is week 53 of 2020")
	w, y = iso_week(Date{2016, 1, 1})
	check(w == 53 && y == 2015, "2016-01-01 is week 53 of 2015")
	w, y = iso_week(Date{2015, 12, 31})
	check(w == 53 && y == 2015, "2015-12-31 is week 53 of 2015")
	w, y = iso_week(Date{2026, 1, 1})
	check(w == 1 && y == 2026, "2026-01-01 is week 1 of 2026")
	w, y = iso_week(Date{2020, 12, 31})
	check(w == 53 && y == 2020, "2020-12-31 is week 53 of 2020")
	w, y = iso_week(Date{2024, 12, 30})
	check(w == 1 && y == 2025, "2024-12-30 is week 1 of 2025")

	// Day-number round trip over four centuries, every day.
	bad := 0
	for n in days_from_civil(Date{1800, 1, 1}) ..= days_from_civil(Date{2200, 1, 1}) {
		d := civil_from_days(n)
		if days_from_civil(d) != n {
			bad += 1
		}
	}
	check(bad == 0, "civil <-> days round trips for every day 1800-2200")

	// Every month of those centuries starts on the weekday the sequence says.
	wrong := 0
	for yy in 1800 ..< 2200 {
		for mm in 1 ..= 12 {
			first := Date{yy, mm, 1}
			last := Date{yy, mm, days_in_month(yy, mm)}
			if date_add(last, 1).d != 1 {
				wrong += 1
			}
			if (weekday(first) + days_in_month(yy, mm) - 1) % 7 != weekday(last) {
				wrong += 1
			}
		}
	}
	check(wrong == 0, "month lengths and weekday progression agree 1800-2200")

	// Clamping when adding months.
	check(date_eq(month_add(Date{2024, 1, 31}, 1), Date{2024, 2, 29}), "31 Jan 2024 + 1 month is 29 Feb")
	check(date_eq(month_add(Date{2023, 1, 31}, 1), Date{2023, 2, 28}), "31 Jan 2023 + 1 month is 28 Feb")
	check(date_eq(month_add(Date{2024, 3, 15}, -3), Date{2023, 12, 15}), "15 Mar 2024 - 3 months is 15 Dec 2023")
	check(date_eq(month_add(Date{2024, 12, 1}, 1), Date{2025, 1, 1}), "1 Dec 2024 + 1 month is 1 Jan 2025")

	// Monday-of-week, for every weekday.
	for k in 0 ..< 7 {
		d := date_add(Date{2026, 10, 5}, k)
		check(weekday(monday_of(d)) == 0, "monday_of lands on a Monday")
	}

	// Parsing.
	_, ok := parse_iso("2024-02-30")
	check(!ok, "2024-02-30 is rejected")
	_, ok = parse_iso("2024-02-29")
	check(ok, "2024-02-29 is accepted")
	m, mok := parse_clock("9:05")
	check(mok && m == 545, "9:05 is 545 minutes")
	m, mok = parse_clock("0930")
	check(mok && m == 570, "0930 is 570 minutes")
	m, mok = parse_clock("")
	check(mok && m == -1, "an empty time means all day")
	_, mok = parse_clock("24:00")
	check(!mok, "24:00 is rejected")

	if failures == 0 {
		fmt.println("calendar selftest: all checks passed")
	} else {
		fmt.printfln("calendar selftest: %d failures", failures)
	}
}
