// `odin test cloud/dav/ical`: the RRULE engine against RFC 5545's own
// examples (section 3.8.5.3), zone conversion against known transitions,
// and the text layer against folding and escaping.
package ical

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// occurrences formats the first n occurrences of a rule from a start, as
// "YYYYMMDDTHHMMSS" wall-clock strings.
@(private = "file")
occurrences :: proc(rule_s, start_s: string, n: int, tzid := "America/New_York") -> []string {
	rule, ok := parse_rrule(rule_s)
	if !ok {
		return nil
	}
	start, _ := parse_dt(start_s, tzid)
	z, _ := zone_for(tzid)
	it := rrule_iter_make(rule, start, z)
	out := make([dynamic]string, 0, n, context.temp_allocator)
	for len(out) < n {
		occ, more := rrule_next(&it)
		if !more {
			break
		}
		append(&out, format_dt(occ, context.temp_allocator))
	}
	return out[:]
}

@(private = "file")
expect :: proc(t: ^testing.T, rule, start: string, want: []string, n := -1, loc := #caller_location) {
	count := n < 0 ? len(want) : n
	got := occurrences(rule, start, count)
	joined_got := strings.join(got, " ", context.temp_allocator)
	joined_want := strings.join(want, " ", context.temp_allocator)
	testing.expectf(t, joined_got == joined_want, "%s from %s\n  got  %s\n  want %s", rule, start, joined_got, joined_want, loc = loc)
}

@(test)
rfc5545_daily :: proc(t: ^testing.T) {
	// Daily for 10 occurrences.
	expect(t, "FREQ=DAILY;COUNT=10", "19970902T090000", {
		"19970902T090000", "19970903T090000", "19970904T090000", "19970905T090000", "19970906T090000",
		"19970907T090000", "19970908T090000", "19970909T090000", "19970910T090000", "19970911T090000",
	}, 20)
	// Every other day, forever (first 5).
	expect(t, "FREQ=DAILY;INTERVAL=2", "19970902T090000", {
		"19970902T090000", "19970904T090000", "19970906T090000", "19970908T090000", "19970910T090000",
	})
	// Every 10 days, 5 occurrences.
	expect(t, "FREQ=DAILY;INTERVAL=10;COUNT=5", "19970902T090000", {
		"19970902T090000", "19970912T090000", "19970922T090000", "19971002T090000", "19971012T090000",
	}, 9)
	// Daily until 24 Dec 1997 (UTC UNTIL, zoned start): last is 23 Dec.
	got := occurrences("FREQ=DAILY;UNTIL=19971224T000000Z", "19970902T090000", 500)
	testing.expect_value(t, len(got), 113)
	testing.expect_value(t, got[len(got) - 1], "19971223T090000")
	// Every day in January, for 3 years (two equivalent forms).
	a := occurrences("FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA", "19980101T090000", 500)
	b := occurrences("FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1", "19980101T090000", 500)
	testing.expect_value(t, len(a), 93)
	testing.expect_value(t, len(b), 93)
	testing.expect_value(t, a[92], "20000131T090000")
}

@(test)
rfc5545_weekly :: proc(t: ^testing.T) {
	// Weekly for 10 occurrences.
	expect(t, "FREQ=WEEKLY;COUNT=10", "19970902T090000", {
		"19970902T090000", "19970909T090000", "19970916T090000", "19970923T090000", "19970930T090000",
		"19971007T090000", "19971014T090000", "19971021T090000", "19971028T090000", "19971104T090000",
	}, 15)
	// Weekly on Tuesday and Thursday for five weeks.
	expect(t, "FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH", "19970902T090000", {
		"19970902T090000", "19970904T090000", "19970909T090000", "19970911T090000", "19970916T090000",
		"19970918T090000", "19970923T090000", "19970925T090000", "19970930T090000", "19971002T090000",
	}, 15)
	// Every other week on Monday, Wednesday and Friday until 24 Dec 1997.
	got := occurrences("FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR", "19970901T090000", 100)
	testing.expect_value(t, len(got), 25)
	testing.expect_value(t, got[0], "19970901T090000")
	testing.expect_value(t, got[24], "19971222T090000")
	// Every other week on Tuesday and Thursday, for 8 occurrences.
	expect(t, "FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH", "19970902T090000", {
		"19970902T090000", "19970904T090000", "19970916T090000", "19970918T090000",
		"19970930T090000", "19971002T090000", "19971014T090000", "19971016T090000",
	}, 12)
	// WKST changes the result: MO vs SU.
	expect(t, "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", "19970805T090000", {
		"19970805T090000", "19970810T090000", "19970819T090000", "19970824T090000",
	})
	expect(t, "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", "19970805T090000", {
		"19970805T090000", "19970817T090000", "19970819T090000", "19970831T090000",
	})
}

@(test)
rfc5545_monthly :: proc(t: ^testing.T) {
	// Monthly on the first Friday for 10 occurrences (DTSTART is itself a
	// first Friday).
	expect(t, "FREQ=MONTHLY;COUNT=10;BYDAY=1FR", "19970905T090000", {
		"19970905T090000", "19971003T090000", "19971107T090000", "19971205T090000", "19980102T090000",
		"19980206T090000", "19980306T090000", "19980403T090000", "19980501T090000", "19980605T090000",
	}, 12)
	// Every other month on the first and last Sunday, 10 occurrences.
	expect(t, "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", "19970907T090000", {
		"19970907T090000", "19970928T090000", "19971102T090000", "19971130T090000", "19980104T090000",
		"19980125T090000", "19980301T090000", "19980329T090000", "19980503T090000", "19980531T090000",
	}, 12)
	// Monthly on the second-to-last Monday for 6 months.
	expect(t, "FREQ=MONTHLY;COUNT=6;BYDAY=-2MO", "19970922T090000", {
		"19970922T090000", "19971020T090000", "19971117T090000", "19971222T090000", "19980119T090000",
		"19980216T090000",
	}, 8)
	// Monthly on the third-to-the-last day of the month (first 6).
	expect(t, "FREQ=MONTHLY;BYMONTHDAY=-3", "19970928T090000", {
		"19970928T090000", "19971029T090000", "19971128T090000", "19971229T090000", "19980129T090000",
		"19980226T090000",
	})
	// Monthly on the 2nd and 15th, 10 occurrences.
	expect(t, "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15", "19970902T090000", {
		"19970902T090000", "19970915T090000", "19971002T090000", "19971015T090000", "19971102T090000",
		"19971115T090000", "19971202T090000", "19971215T090000", "19980102T090000", "19980115T090000",
	}, 12)
	// Every Friday the 13th (first 5), DTSTART not itself matching: it is
	// still the first instance, as RFC 5545 says DTSTART always counts.
	expect(t, "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", "19970902T090000", {
		"19970902T090000", "19980213T090000", "19980313T090000", "19981113T090000", "19990813T090000",
		"20001013T090000",
	})
	// The first Saturday that follows the first Sunday of the month.
	expect(t, "FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13", "19970913T090000", {
		"19970913T090000", "19971011T090000", "19971108T090000", "19971213T090000", "19980110T090000",
	})
	// The third instance of Tu, We or Th, for the next 3 months.
	expect(t, "FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", "19970904T090000", {
		"19970904T090000", "19971007T090000", "19971106T090000",
	}, 5)
	// The second-to-last weekday of the month.
	expect(t, "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2", "19970929T090000", {
		"19970929T090000", "19971030T090000", "19971127T090000", "19971230T090000", "19980129T090000",
		"19980226T090000", "19980330T090000",
	})
	// An invalid date (the 30th of February) is skipped, not moved.
	expect(t, "FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5", "20070115T090000", {
		"20070115T090000", "20070130T090000", "20070215T090000", "20070315T090000", "20070330T090000",
	}, 7)
	// The 31st, monthly: only months that have one.
	expect(t, "FREQ=MONTHLY;COUNT=4", "20260131T100000", {
		"20260131T100000", "20260331T100000", "20260531T100000", "20260731T100000",
	}, 6)
}

@(test)
rfc5545_yearly :: proc(t: ^testing.T) {
	// Yearly in June and July for 10 occurrences.
	expect(t, "FREQ=YEARLY;COUNT=10;BYMONTH=6,7", "19970610T090000", {
		"19970610T090000", "19970710T090000", "19980610T090000", "19980710T090000", "19990610T090000",
		"19990710T090000", "20000610T090000", "20000710T090000", "20010610T090000", "20010710T090000",
	}, 12)
	// Every third year on the 1st, 100th and 200th day for 10 occurrences.
	expect(t, "FREQ=YEARLY;INTERVAL=3;COUNT=10;BYYEARDAY=1,100,200", "19970101T090000", {
		"19970101T090000", "19970410T090000", "19970719T090000", "20000101T090000", "20000409T090000",
		"20000718T090000", "20030101T090000", "20030410T090000", "20030719T090000", "20060101T090000",
	}, 12)
	// Every 20th Monday of the year.
	expect(t, "FREQ=YEARLY;BYDAY=20MO", "19970519T090000", {
		"19970519T090000", "19980518T090000", "19990517T090000",
	})
	// Monday of week 20 (ISO week numbering).
	expect(t, "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", "19970512T090000", {
		"19970512T090000", "19980511T090000", "19990517T090000",
	})
	// Every Thursday in March.
	expect(t, "FREQ=YEARLY;BYMONTH=3;BYDAY=TH", "19970313T090000", {
		"19970313T090000", "19970320T090000", "19970327T090000", "19980305T090000", "19980312T090000",
		"19980319T090000", "19980326T090000",
	})
	// Every Thursday, only during June, July and August (first 6).
	expect(t, "FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8", "19970605T090000", {
		"19970605T090000", "19970612T090000", "19970619T090000", "19970626T090000", "19970703T090000",
		"19970710T090000",
	})
	// US presidential election day: every 4 years, the first Tuesday after
	// a Monday in November.
	expect(t, "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8", "19961105T090000", {
		"19961105T090000", "20001107T090000", "20041102T090000",
	})
	// 29 February, yearly: only in leap years.
	expect(t, "FREQ=YEARLY;COUNT=3", "20240229T080000", {
		"20240229T080000", "20280229T080000", "20320229T080000",
	})
}

@(test)
rfc5545_hourly :: proc(t: ^testing.T) {
	// Every 3 hours from 9:00 to 17:00 on a specific day.
	expect(t, "FREQ=HOURLY;INTERVAL=3;UNTIL=19970902T170000", "19970902T090000", {
		"19970902T090000", "19970902T120000", "19970902T150000",
	}, 6)
	// Every 15 minutes for 6 occurrences.
	expect(t, "FREQ=MINUTELY;INTERVAL=15;COUNT=6", "19970902T090000", {
		"19970902T090000", "19970902T091500", "19970902T093000", "19970902T094500", "19970902T100000",
		"19970902T101500",
	}, 8)
	// Every 20 minutes from 9:00 to 16:40 every day (first 4 of day 2).
	got := occurrences("FREQ=DAILY;BYHOUR=9,10,11,12,13,14,15,16;BYMINUTE=0,20,40", "19970902T090000", 30)
	testing.expect_value(t, got[23], "19970902T164000")
	testing.expect_value(t, got[24], "19970903T090000")
}

@(test)
rrule_roundtrip :: proc(t: ^testing.T) {
	r, ok := parse_rrule("FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU")
	testing.expect(t, ok)
	testing.expect_value(t, format_rrule(r, context.temp_allocator), "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU")
	_, bad := parse_rrule("FREQ=FORTNIGHTLY")
	testing.expect(t, !bad)
	_, bad2 := parse_rrule("FREQ=DAILY;BYHOUR=25")
	testing.expect(t, !bad2)
}

// ---------------------------------------------------------------------------
// Zones
// ---------------------------------------------------------------------------

@(private = "file")
utc_of :: proc(local, tzid: string) -> string {
	d, _ := parse_dt(local, tzid)
	return format_dt(utc_dt(instant(d)), context.temp_allocator)
}

@(test)
zones_iana :: proc(t: ^testing.T) {
	// Paris: CET in winter, CEST in summer; DST from 29 March 2026 02:00.
	testing.expect_value(t, utc_of("20260115T120000", "Europe/Paris"), "20260115T110000Z")
	testing.expect_value(t, utc_of("20260715T120000", "Europe/Paris"), "20260715T100000Z")
	testing.expect_value(t, utc_of("20260329T013000", "Europe/Paris"), "20260329T003000Z")
	testing.expect_value(t, utc_of("20260329T033000", "Europe/Paris"), "20260329T013000Z")
	// The gap: 02:30 does not exist; it is read as 03:30 CEST.
	testing.expect_value(t, utc_of("20260329T023000", "Europe/Paris"), "20260329T013000Z")
	// The fold: 02:30 on 25 October 2026 happens twice; the first wins.
	testing.expect_value(t, utc_of("20261025T023000", "Europe/Paris"), "20261025T003000Z")
	// New York, far beyond any listed transition (the footer rule).
	testing.expect_value(t, utc_of("20900704T120000", "America/New_York"), "20900704T160000Z")
	testing.expect_value(t, utc_of("20901225T120000", "America/New_York"), "20901225T170000Z")
	// Southern hemisphere: Sydney is +11 in January, +10 in July.
	testing.expect_value(t, utc_of("20270115T120000", "Australia/Sydney"), "20270115T010000Z")
	testing.expect_value(t, utc_of("20270715T120000", "Australia/Sydney"), "20270715T020000Z")
	// Half-hour zones, and a zone that left DST behind.
	testing.expect_value(t, utc_of("20260601T120000", "Asia/Kolkata"), "20260601T063000Z")
	// Mozilla's prefixed TZIDs and Windows names resolve to IANA.
	testing.expect_value(t, utc_of("20260715T120000", "/mozilla.org/20050126_1/Europe/Paris"), "20260715T100000Z")
	testing.expect_value(t, utc_of("20260715T120000", "Romance Standard Time"), "20260715T100000Z")
	testing.expect_value(t, utc_of("20260715T120000", "W. Europe Standard Time"), "20260715T100000Z")
}

@(test)
zones_vtimezone :: proc(t: ^testing.T) {
	// A zone the database does not know, defined only in the object.
	text := "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:Custom/Somewhere\r\n" +
		"BEGIN:DAYLIGHT\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nDTSTART:19700329T020000\r\n" +
		"RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\n" +
		"BEGIN:STANDARD\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nDTSTART:19701025T030000\r\n" +
		"RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
		"BEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Custom/Somewhere:20260715T120000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
	cal, _, ok := parse_one(text)
	testing.expect(t, ok)
	ev := child(cal, "VEVENT")
	start, _ := prop_dt(prop(ev, "DTSTART"))
	testing.expect_value(t, format_dt(utc_dt(instant(start, cal)), context.temp_allocator), "20260715T100000Z")
	start.m = 1
	testing.expect_value(t, format_dt(utc_dt(instant(start, cal)), context.temp_allocator), "20260115T110000Z")
	z, zok := zone_for("Custom/Somewhere", cal)
	testing.expect(t, zok && z.kind == .Defined)
}

@(test)
posix_rules :: proc(t: ^testing.T) {
	r := parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3")
	testing.expect(t, r.valid && r.has_dst)
	testing.expect_value(t, r.std_offset, i64(3600))
	testing.expect_value(t, r.dst_offset, i64(7200))
	r2 := parse_posix_tz("<+0530>-5:30")
	testing.expect(t, r2.valid && !r2.has_dst)
	testing.expect_value(t, r2.std_offset, i64(19800))
	r3 := parse_posix_tz("EST5EDT,M3.2.0,M11.1.0")
	// 2026-03-08 07:00Z is 02:00 EST: DST begins.
	at := days_from_civil(2026, 3, 8) * 86400 + 7 * 3600
	testing.expect_value(t, posix_offset_at(r3, at - 1), i64(-5 * 3600))
	testing.expect_value(t, posix_offset_at(r3, at), i64(-4 * 3600))
}

// ---------------------------------------------------------------------------
// Expansion
// ---------------------------------------------------------------------------

@(test)
expansion_with_exceptions :: proc(t: ^testing.T) {
	text := "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
		"BEGIN:VEVENT\r\nUID:standup\r\nDTSTART;TZID=Europe/Paris:20261019T093000\r\n" +
		"DTEND;TZID=Europe/Paris:20261019T094500\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=9\r\n" +
		"EXDATE;TZID=Europe/Paris:20261021T093000\r\nSUMMARY:Stand-up\r\nEND:VEVENT\r\n" +
		"BEGIN:VEVENT\r\nUID:standup\r\nRECURRENCE-ID;TZID=Europe/Paris:20261023T093000\r\n" +
		"DTSTART;TZID=Europe/Paris:20261023T110000\r\nDTEND;TZID=Europe/Paris:20261023T113000\r\n" +
		"SUMMARY:Stand-up (moved)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
	cal, _, ok := parse_one(text)
	testing.expect(t, ok)
	testing.expect_value(t, check(cal), Check_Error.None)
	all, _ := expand(cal, "VEVENT", min(i64), max(i64))
	// 9 occurrences, one excluded.
	testing.expect_value(t, len(all), 8)
	// 19 Oct 09:30 CEST = 07:30Z; the moved one is 23 Oct 11:00 CEST = 09:00Z.
	testing.expect_value(t, format_dt(utc_dt(all[0].start), context.temp_allocator), "20261019T073000Z")
	testing.expect_value(t, format_dt(utc_dt(all[1].start), context.temp_allocator), "20261023T090000Z")
	testing.expect(t, all[1].overridden)
	testing.expect_value(t, text_of(all[1].comp), "Stand-up (moved)")
	// After the 25 October change to CET, 09:30 local is 08:30Z.
	testing.expect_value(t, format_dt(utc_dt(all[2].start), context.temp_allocator), "20261026T083000Z")
	// A window: the week of 26 October.
	s := days_from_civil(2026, 10, 26) * 86400
	week, _ := expand(cal, "VEVENT", s, s + 7 * 86400)
	testing.expect_value(t, len(week), 3)
	ix := index(cal)
	testing.expect_value(t, ix.uid, "standup")
	testing.expect(t, !ix.unbounded)
	testing.expect_value(t, ix.overrides, 1)
	testing.expect_value(t, format_dt(utc_dt(ix.last_end), context.temp_allocator), "20261106T084500Z")
}

@(private = "file")
text_of :: proc(c: ^Component) -> string {
	return text(c, "SUMMARY")
}

@(test)
all_day_span :: proc(t: ^testing.T) {
	text := "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART;VALUE=DATE:20261024\r\nDTEND;VALUE=DATE:20261026\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
	cal, _, _ := parse_one(text)
	z, _ := zone_for("Europe/Paris")
	all, _ := expand(cal, "VEVENT", min(i64), max(i64), {floating = z})
	testing.expect_value(t, len(all), 1)
	// Two whole local days across the DST change: 49 hours.
	testing.expect_value(t, all[0].end - all[0].start, i64(49 * 3600))
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(test)
text_layer :: proc(t: ^testing.T) {
	long := strings.repeat("é", 60, context.temp_allocator)
	c := new(Component, context.temp_allocator)
	c.name = "VEVENT"
	append(&c.props, Prop{name = "SUMMARY", value = escape_text(fmt.tprintf("%s, with; and\nnewline", long))})
	out := write(c, context.temp_allocator)
	for line in strings.split(out, "\r\n", context.temp_allocator) {
		testing.expectf(t, len(line) <= 75, "a folded line is %d octets", len(line))
		testing.expect(t, utf8.valid_string(line) || line == "", "folding split a character")
	}
	back, _, ok := parse_one(out)
	testing.expect(t, ok)
	testing.expect_value(t, text(back, "SUMMARY"), fmt.tprintf("%s, with; and\nnewline", long))

	p, pok := parse_line(`ATTENDEE;CN="Doe, Jane";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:jane@example.com`)
	testing.expect(t, pok)
	testing.expect_value(t, param(&p, "CN"), "Doe, Jane")
	testing.expect_value(t, p.value, "mailto:jane@example.com")
	testing.expect_value(t, prop_line(&p), `ATTENDEE;CN="Doe, Jane";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:jane@example.com`)

	_, _, bad := parse_one("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VCALENDAR\r\n")
	testing.expect(t, !bad)
	d, _ := parse_duration("-P1DT2H30M")
	testing.expect_value(t, d, i64(-(86400 + 2 * 3600 + 30 * 60)))
	testing.expect_value(t, format_duration(90 * 60, context.temp_allocator), "PT1H30M")
	testing.expect_value(t, format_duration(14 * 86400, context.temp_allocator), "P2W")
}

@(test)
object_checks :: proc(t: ^testing.T) {
	mixed := "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20260101T000000Z\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:b\r\nDTSTART:20260101T000000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
	cal, _, _ := parse_one(mixed)
	testing.expect_value(t, check(cal), Check_Error.Mixed_UIDs)
	todo := "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t\r\nSUMMARY:x\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
	cal2, _, _ := parse_one(todo)
	testing.expect_value(t, check(cal2), Check_Error.None)
	ix := index(cal2)
	testing.expect(t, ix.unbounded)
}
