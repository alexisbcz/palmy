// Recurrence sets: RRULE + RDATE - EXDATE, with overridden instances
// (components carrying RECURRENCE-ID) standing in for the ones they replace.
package ical

import "core:slice"
import "core:strings"

Instance :: struct {
	start:       i64, // UTC
	end:         i64, // UTC, >= start
	rid:         DT, // the recurrence id: the original start, in its own clock
	rid_utc:     i64,
	comp:        ^Component, // the master, or the override that replaces it
	overridden:  bool,
	recurring:   bool, // part of a recurrence set (has a RECURRENCE-ID to write)
}

// What an event's end is relative to its start, kept nominal for dates and
// zoned clocks so "one day" stays a day across a DST change.
Span :: struct {
	nominal_days: i64,
	exact_secs:   i64,
}

component_span :: proc(c: ^Component, start: DT, cal: ^Component, floating: ^Zone) -> Span {
	if e, ok := prop_dt(prop(c, c.name == "VTODO" ? "DUE" : "DTEND")); ok {
		if start.is_date && e.is_date {
			return {nominal_days = max(0, days_from_civil(e.y, e.m, e.d) - days_from_civil(start.y, start.m, start.d))}
		}
		// Same clock: nominal difference; different clocks: exact.
		if e.tzid == start.tzid && e.utc == start.utc {
			return {exact_secs = max(0, local_secs(e) - local_secs(start))}
		}
		return {exact_secs = max(0, instant(e, cal, floating) - instant(start, cal, floating))}
	}
	if d, ok := parse_duration(value(c, "DURATION")); ok {
		if d % 86400 == 0 && start.is_date {
			return {nominal_days = d / 86400}
		}
		return {exact_secs = max(0, d)}
	}
	if start.is_date {
		return {nominal_days = 1}
	}
	return {}
}

// instance_end applies a span to a start wall clock.
instance_end :: proc(start: DT, span: Span, cal: ^Component, floating: ^Zone) -> i64 {
	z := zone_of(start, cal, floating)
	l := local_secs(start)
	if span.nominal_days != 0 {
		return to_utc(z, l + span.nominal_days * 86400)
	}
	// Exact durations from a zoned wall clock: add to the instant (RFC 5545:
	// a duration of hours is exact time).
	return to_utc(z, l) + span.exact_secs
}

Expand_Options :: struct {
	floating:  ^Zone, // the zone floating and all-day times are read in
	limit:     int, // most instances to return (0: 10000)
}

// overlaps is RFC 4791 section 9.9 for VEVENT.
overlaps :: proc(start, end, range_start, range_end: i64) -> bool {
	if end > start {
		return start < range_end && end > range_start
	}
	return start >= range_start && start < range_end
}

// masters_and_overrides splits a VCALENDAR's components of one kind.
masters_and_overrides :: proc(cal: ^Component, kind: string) -> (master: ^Component, overrides: []^Component) {
	list := make([dynamic]^Component, 0, 2)
	for ch in cal.children {
		if ch.name != kind {
			continue
		}
		if prop(ch, "RECURRENCE-ID") != nil {
			append(&list, ch)
		} else if master == nil {
			master = ch
		}
	}
	return master, list[:]
}

// main_kind is the calendar object's component type (VEVENT, VTODO...).
main_kind :: proc(cal: ^Component) -> string {
	for ch in cal.children {
		switch ch.name {
		case "VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY":
			return ch.name
		}
	}
	return ""
}

// expand lists the instances of `kind` overlapping [range_start, range_end).
// A non-recurring component is one instance. truncated is set when the
// limit stopped the walk early.
expand :: proc(
	cal: ^Component,
	kind: string,
	range_start, range_end: i64,
	opts: Expand_Options = {},
) -> (out: []Instance, truncated: bool) {
	limit := opts.limit > 0 ? opts.limit : 10000
	list := make([dynamic]Instance, 0, 8)
	master, overrides := masters_and_overrides(cal, kind)

	// Overrides keyed by the instant they replace.
	over_at := make(map[i64]^Component, len(overrides), context.temp_allocator)
	for ov in overrides {
		rid, ok := prop_dt(prop(ov, "RECURRENCE-ID"))
		if !ok {
			continue
		}
		over_at[instant(rid, cal, opts.floating)] = ov
	}

	if master != nil {
		start, sok := prop_dt(prop(master, "DTSTART"))
		if !sok {
			// A VTODO without DTSTART: one instance spanning its DUE, or all time.
			if kind == "VTODO" {
				due, dok := prop_dt(prop(master, "DUE"))
				s, e := min(i64), max(i64)
				if dok {
					s = instant(due, cal, opts.floating)
					e = s
				}
				if !dok || overlaps(s, e, range_start, range_end) {
					append(&list, Instance{start = s, end = e, comp = master})
				}
			}
			return list[:], false
		}
		span := component_span(master, start, cal, opts.floating)
		zone := zone_of(start, cal, opts.floating)

		// EXDATEs, as instants (dates: as their local day start).
		ex := make(map[i64]bool, 4, context.temp_allocator)
		for ep in props(master, "EXDATE") {
			tz := param(ep, "TZID")
			for part in strings.split(ep.value, ",", context.temp_allocator) {
				t, ok := parse_dt(part, tz)
				if !ok {
					continue
				}
				if strings.equal_fold(param(ep, "VALUE"), "DATE") || t.is_date {
					t.is_date = start.is_date
					t.hh, t.mm, t.ss = start.hh, start.mm, start.ss
					t.tzid = start.tzid
					t.utc = start.utc
				}
				ex[instant(t, cal, opts.floating)] = true
			}
		}

		// The occurrence starts: RRULE (with DTSTART) and RDATEs, ascending.
		starts := make([dynamic]DT, 0, 16, context.temp_allocator)
		rrule_p := prop(master, "RRULE")
		recurring := rrule_p != nil || prop(master, "RDATE") != nil
		rule, rule_ok := RRule{}, false
		if rrule_p != nil {
			rule, rule_ok = parse_rrule(rrule_p.value)
		}
		// The walk ends once an occurrence starts past the range: nothing
		// after it can overlap. Dates need a day of slack for zones.
		stop_after := range_end == max(i64) ? max(i64) : range_end + 86400 * 2

		walked := 0
		if rule_ok {
			it := rrule_iter_make(rule, start, zone)
			for {
				occ, more := rrule_next(&it)
				if !more {
					break
				}
				if local_secs(occ) > stop_after {
					break
				}
				append(&starts, occ)
				walked += 1
				if walked > 200000 {
					truncated = true
					break
				}
			}
		} else {
			append(&starts, start)
		}
		for rp in props(master, "RDATE") {
			tz := param(rp, "TZID")
			for part in strings.split(rp.value, ",", context.temp_allocator) {
				// RDATE may be a PERIOD: start/end or start/duration.
				piece := part
				if slash := strings.index_byte(piece, '/'); slash >= 0 {
					piece = piece[:slash]
				}
				t, ok := parse_dt(piece, tz)
				if !ok {
					continue
				}
				if start.is_date {
					t.is_date = true
					t.hh, t.mm, t.ss = 0, 0, 0
				}
				append(&starts, t)
			}
		}
		slice.sort_by(starts[:], proc(a, b: DT) -> bool {return local_secs(a) < local_secs(b)})

		seen := make(map[i64]bool, len(starts), context.temp_allocator)
		for st in starts {
			at := instant(st, cal, opts.floating)
			if seen[at] || ex[at] {
				continue
			}
			seen[at] = true
			if ov, has := over_at[at]; has {
				_ = ov
				continue // emitted below, from the override's own times
			}
			e := instance_end(st, span, cal, opts.floating)
			if overlaps(at, e, range_start, range_end) {
				if len(list) >= limit {
					truncated = true
					break
				}
				append(&list, Instance{start = at, end = e, rid = st, rid_utc = at, comp = master, recurring = recurring})
			}
		}
	}

	// Overrides, by their own times (they may have moved into the range).
	for ov in overrides {
		rid, rok := prop_dt(prop(ov, "RECURRENCE-ID"))
		st, sok := prop_dt(prop(ov, "DTSTART"))
		if !rok {
			continue
		}
		if !sok {
			st = rid
		}
		span := component_span(ov, st, cal, opts.floating)
		at := instant(st, cal, opts.floating)
		e := instance_end(st, span, cal, opts.floating)
		if strings.equal_fold(value(ov, "STATUS"), "CANCELLED") && master != nil {
			// A cancelled instance is still an instance (clients show it
			// struck through); free/busy drops it separately.
		}
		if overlaps(at, e, range_start, range_end) {
			append(&list, Instance{
				start = at, end = e, rid = rid, rid_utc = instant(rid, cal, opts.floating),
				comp = ov, overridden = true, recurring = true,
			})
		}
	}
	slice.sort_by(list[:], proc(a, b: Instance) -> bool {return a.start < b.start})
	return list[:], truncated
}
