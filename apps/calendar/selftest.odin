// `calendar --selftest` checks the date arithmetic against dates whose answers
// are known independently. The month grid is only as correct as this is.
package main

import "core:fmt"
import "core:os"
import "core:strings"

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
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

	test_events()
	test_cloud()
	test_password_secret()

	if failures == 0 {
		fmt.printfln("calendar selftest: %d checks passed", checks)
	} else {
		fmt.printfln("calendar selftest: %d checks, %d FAILED", checks, failures)
	}
}

// ---------------------------------------------------------------------------
// The events file
//
// A calendar that loses an event is worse than no calendar, so the file format
// is asserted directly: what is written is what is read back, a title with a
// tab in it cannot break the record separator, and the order is the order the
// day pane shows.
// ---------------------------------------------------------------------------

check_eq :: proc(got, want, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printfln("  FAIL  %s\n        got  %q\n        want %q", what, got, want)
	}
}

test_events :: proc() {
	dir := "/tmp/palmy-calendar-selftest"
	if !os.is_dir(dir) {
		os.make_directory(dir)
	}
	os.remove(store_path(dir))

	empty := events_load(dir)
	check(len(empty) == 0, "a missing events file loads as no events")

	list := make([dynamic]Event, 0, 8, context.temp_allocator)
	append(&list, mk_event(Date{2026, 10, 4}, 14 * 60, 60, "Design review", "Studio"))
	append(&list, mk_event(Date{2026, 10, 4}, -1, 0, "Pay the bill", ""))
	append(&list, mk_event(Date{2026, 10, 4}, 9 * 60 + 30, 45, "Stand-up", "Jitsi"))
	append(&list, mk_event(Date{2024, 2, 29}, 0, 0, "Leap day", "Nowhere"))
	append(&list, mk_event(Date{2026, 10, 4}, 9 * 60 + 30, 30, "A tab\there and a\nnewline", "x"))
	events_sort(&list)

	check(date_eq(list[0].date, Date{2024, 2, 29}), "the earliest date sorts first")
	check(list[1].start == -1, "an all-day entry sorts before the timed ones on its day")
	check(list[2].start == 9 * 60 + 30, "and then the earliest time")
	check(list[4].start == 14 * 60, "with the latest time last")

	check(events_save(dir, list[:]), "the events file is written")
	raw, rerr := os.read_entire_file_from_path(store_path(dir), context.temp_allocator)
	check(rerr == nil, "and can be read back as bytes")
	text := string(raw)
	check(strings.count(text, "\n") == len(list) + 1, "one line per event, plus the header")
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" || line[0] == '#' {
			continue
		}
		checks += 1
		if strings.count(line, "\t") != 4 {
			failures += 1
			fmt.printfln("  FAIL  a record has the wrong number of fields: %q", line)
		}
	}

	back := events_load(dir)
	check(len(back) == len(list), "every event came back")
	same := len(back) == len(list)
	if same {
		for e, i in back {
			if !date_eq(e.date, list[i].date) || e.start != list[i].start || e.mins != list[i].mins {
				same = false
			}
		}
	}
	check(same, "the dates, times and durations survived the round trip")
	check_eq(back[0].title, "Leap day", "the first title came back")
	check_eq(back[0].place, "Nowhere", "and its location")
	check_eq(back[3].title, "A tab here and a newline", "a tab and a newline in a title became spaces")

	// A malformed line is skipped, not fatal.
	broken := "# header\nnot a date\tx\t0\tt\tp\n2026-13-99\t-\t0\tbad date\t\n2026-01-02\t08:15\t30\tGood\tHere\n"
	check(os.write_entire_file(store_path(dir), transmute([]u8)broken) == nil, "a hand-written events file is laid down")
	survivors := events_load(dir)
	check(len(survivors) == 1, "a broken line is skipped and the good one survives")
	check_eq(survivors[0].title, "Good", "and it is the right one")
	check(survivors[0].start == 8 * 60 + 15, "with its time parsed")

	os.remove(store_path(dir))
}
