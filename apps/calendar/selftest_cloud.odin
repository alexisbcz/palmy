// The cloud half of `calendar --selftest`, offline: the event <-> VEVENT
// mapping, recurrence in the grid, read-only shares, invitations, and the
// local copies they go through.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import ical "../../cloud/dav/ical"
import kit "kit:."

// mk_event is the five fields the device file stores.
mk_event :: proc(d: Date, start, mins: int, title, place: string) -> Event {
	return Event{date = d, start = start, mins = mins, title = title, place = place}
}

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

test_cloud :: proc() {
	dir := "/tmp/palmy-calendar-selftest-cloud"
	_ = os.remove_all(dir)
	cl := Cloud{}
	fixture_begin(&cl, "Europe/Paris")
	fixture_ident(&cl, "alice", "Alice Martin", "personal", "indigo")
	fixture_ident(&cl, "bob", "Bob Okafor", "personal", "amber")
	mine := fixture_source(&cl, dir, "alice", "default", "Calendar", "#6366f1", "owner", "alice")
	shared := fixture_source(&cl, dir, "alice", "bob~default", "Bob's calendar", "#f59e0b", "read", "bob")

	// A draft becomes a VEVENT that parses back to the same thing.
	dr := Draft {
		date      = Date{2026, 10, 5},
		start     = 9 * 60 + 30,
		mins      = 45,
		title     = "Stand-up; planning, review",
		place     = "Room 2",
		rrule     = "FREQ=WEEKLY;COUNT=6",
		attendees = {"bob@palm.test", "carol@example.com"},
		organizer = "alice",
	}
	text := build_vevent("uid-1@test", dr, "Europe/Paris", context.temp_allocator)
	cal, _, ok := ical.parse_one(text)
	check(ok && ical.check(cal) == .None, "a new event is a valid calendar object")
	ev := ical.child(cal, "VEVENT")
	check_eq(ical.text(ev, "SUMMARY"), "Stand-up; planning, review", "the title survives iCalendar escaping")
	check_eq(ical.value(ev, "DTSTART"), "20261005T093000", "DTSTART is the local wall clock")
	check_eq(ical.param(ical.prop(ev, "DTSTART"), "TZID"), "Europe/Paris", "with the zone as a TZID")
	check_eq(ical.value(ev, "DTEND"), "20261005T101500", "DTEND is start plus the duration")
	check_eq(ical.value(ev, "RRULE"), "FREQ=WEEKLY;COUNT=6", "the repetition is an RRULE")
	check_eq(ical.value(ev, "ORGANIZER"), "mailto:alice@palm.test", "the organizer is the identity's address")
	check(len(ical.props(ev, "ATTENDEE")) == 3, "the organizer and two attendees are listed")
	ps, here := partstat_for(ev, "mailto:bob@palm.test")
	check(here && ps == "NEEDS-ACTION", "an invited attendee starts at NEEDS-ACTION")
	check(recur_of(ical.value(ev, "RRULE")) == .Weekly, "the form reads the repetition back")

	// Through the local copy, into the grid: Mondays from 5 October, six of
	// them, one excluded. 26 October is after the change to winter time and
	// must still be 09:30 on the wall.
	fixture_put(&cl, mine, "standup.ics", text)
	fixture_end(&cl)
	check(len(cl.sources[mine].objs) == 1, "the object is read from the local copy")
	out, eok := exclude_instance(cl.sources[mine].objs[0].text, ical.DT{y = 2026, m = 10, d = 19, hh = 9, mm = 30, tzid = "Europe/Paris"}, context.temp_allocator)
	check(eok && strings.contains(out, "EXDATE;TZID=Europe/Paris:20261019T093000"), "removing one occurrence writes an EXDATE in DTSTART's form")
	fixture_put(&cl, mine, "standup.ics", out)
	fixture_end(&cl)
	evs := cloud_events(&cl, Date{2026, 10, 1}, Date{2026, 11, 1}, context.temp_allocator)
	days := make([dynamic]int, 0, 4, context.temp_allocator)
	same_time := true
	for e in evs {
		append(&days, e.date.d)
		if e.start != 9 * 60 + 30 || e.mins != 45 {
			same_time = false
		}
	}
	check(len(days) == 3 && days[0] == 5 && days[1] == 12 && days[2] == 26, "October shows the 5th, 12th and 26th (the 19th excluded)")
	check(same_time, "every instance is 09:30-10:15 local, across the DST change")
	check(len(evs) > 0 && evs[0].recurring && evs[0].src == mine, "instances know their calendar and that they recur")
	all := cloud_events(&cl, Date{2026, 1, 1}, Date{2027, 1, 1}, context.temp_allocator)
	check(len(all) == 5, "COUNT=6 minus one exclusion is five in the year")

	// Editing keeps attendees and bumps SEQUENCE.
	dr2 := dr
	dr2.title = "Stand-up (moved)"
	dr2.start = 10 * 60
	edited, edok := edit_vevent(cl.sources[mine].objs[0].text, dr2, "Europe/Paris", context.temp_allocator)
	ecal, _, _ := ical.parse_one(edited)
	eev := ical.child(ecal, "VEVENT")
	check(edok && ical.value(eev, "SEQUENCE") == "1", "an edit bumps SEQUENCE")
	check(len(ical.props(eev, "ATTENDEE")) == 3, "an edit keeps the attendees")
	check(strings.contains(edited, "EXDATE"), "and the excluded occurrence")
	check_eq(ical.value(eev, "DTSTART"), "20261005T100000", "and moves the start")

	// Read-only shares refuse every write, before anything is attempted.
	fixture_put(&cl, shared, "bob.ics", vevent("bob-1", "20261006T120000", "20261006T130000", "Bob's lunch"))
	fixture_end(&cl)
	check(!writable(&cl.sources[shared]), "a read share is not writable")
	_, cerr := cloud_create(&cl, shared, dr)
	check(cerr != "", "creating in a read-only share is refused")
	check(cloud_edit(&cl, shared, "bob.ics", dr) != "", "editing in a read-only share is refused")
	check(cloud_delete(&cl, shared, "bob.ics") != "", "deleting in a read-only share is refused")
	check(len(cl.sources[shared].objs) == 1, "and the shared event is still there")
	for i in writable_sources_of(&cl) {
		check(i != shared, "a read-only share is never offered as a target")
	}

	// An invitation from bob to alice, then answered.
	inv := vevent("inv-1", "20261008T150000", "20261008T160000", "Design crit",
		"ORGANIZER:mailto:bob@palm.test\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:bob@palm.test\r\nATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alice@palm.test\r\n")
	fixture_put(&cl, mine, "inv-1.ics", inv)
	fixture_end(&cl)
	pend := pending_invitations(&cl, context.temp_allocator)
	check(len(pend) == 1 && pend[0].organizer == "bob@palm.test" && pend[0].handle == "alice", "an unanswered invitation is pending, with its organizer")
	check(respond(&cl, mine, "inv-1.ics", "ACCEPTED") == "", "accepting writes the local copy")
	check(len(pending_invitations(&cl, context.temp_allocator)) == 0, "and it is no longer pending")
	people := people_of(&cl, mine, "inv-1.ics")
	accepted := false
	for pp in people {
		if pp.address == "alice@palm.test" && pp.partstat == "ACCEPTED" {
			accepted = true
		}
	}
	check(accepted, "alice's line says ACCEPTED")
	check(cl.sources[mine].local.entries["inv-1.ics"].state == .Dirty, "and is queued to go to the server")

	// Colours.
	check(parse_color("#10b981") == 0x10b981, "a hex colour parses")
	check(parse_color("#F59E0BFF") == 0xf59e0b, "an RGBA colour drops its alpha")
	check(parse_color("emerald") == 0x10b981, "an identity's Tailwind colour maps to its 500 shade")
	_ = os.remove_all(dir)
}

writable_sources_of :: proc(cl: ^Cloud) -> []int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	for &s, i in cl.sources {
		if writable(&s) && s.events_ok {
			append(&out, i)
		}
	}
	return out[:]
}

// test_password_secret: --password is declared secret, so the audit log, the
// --json result and a refusal all carry <redacted> where it was. Run in
// process against a scratch HOME, so no real session is read.
test_password_secret :: proc() {
	dir := "/tmp/palmy-calendar-selftest-secret"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	audit := fmt.tprintf("%s/audit.jsonl", dir)
	keys := [?]string{"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "PALM_AUDIT"}
	old: [len(keys)]string
	for k, i in keys {
		old[i] = strings.clone(os.get_env(k, context.temp_allocator))
		_ = os.set_env(k, k == "PALM_AUDIT" ? audit : dir)
	}
	defer for k, i in keys {
		_ = os.set_env(k, old[i])
	}
	_, out, _ := kit.cli_capture(surface(), {"signin", "a@b.test", "--password", "hunter2-7319", "--dry-run", "--json"})
	raw, _ := os.read_entire_file_from_path(audit, context.temp_allocator)
	log := string(raw)
	check(strings.contains(log, `"verb":"signin"`), "signin is audited")
	check(!strings.contains(log, "hunter2-7319") && strings.contains(log, "<redacted>"), "but its --password is not: <redacted> in its place")
	check(!strings.contains(out, "hunter2-7319"), "nor is it in what signin prints")
}
