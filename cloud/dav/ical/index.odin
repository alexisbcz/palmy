// What the database indexes about a calendar object, and the checks RFC 4791
// section 4.1 makes on one before it is stored.
package ical

import "core:strings"

Index :: struct {
	uid:         string,
	component:   string,
	dtstart:     i64,
	dtend:       i64,
	has_start:   bool,
	first_start: i64,
	last_end:    i64,
	unbounded:   bool, // last_end is not known: recurs forever
	all_day:     bool,
	rrule:       string,
	overrides:   int,
	summary:     string,
	location:    string,
	status:      string,
	organizer:   string, // lower-cased calendar user address
	attendees:   []string, // lower-cased
}

Check_Error :: enum u8 {
	None,
	Not_Calendar, // not iCalendar at all, or not one VCALENDAR
	No_Component, // nothing to store
	Mixed_Components, // CALDAV:valid-calendar-object-resource
	Mixed_UIDs,
	No_UID,
	Two_Masters,
}

check_error_text :: proc(e: Check_Error) -> string {
	switch e {
	case .None: return ""
	case .Not_Calendar: return "the body is not one VCALENDAR"
	case .No_Component: return "the calendar has no VEVENT, VTODO or VJOURNAL"
	case .Mixed_Components: return "a calendar object resource holds one kind of component"
	case .Mixed_UIDs: return "every component in a resource shares one UID"
	case .No_UID: return "the component has no UID"
	case .Two_Masters: return "more than one component without RECURRENCE-ID"
	}
	return "invalid"
}

// check validates a parsed calendar object resource.
check :: proc(cal: ^Component) -> Check_Error {
	if cal == nil || cal.name != "VCALENDAR" {
		return .Not_Calendar
	}
	kind := ""
	uid := ""
	masters := 0
	for ch in cal.children {
		switch ch.name {
		case "VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY":
		case:
			continue
		}
		if kind == "" {
			kind = ch.name
		} else if kind != ch.name {
			return .Mixed_Components
		}
		u := text(ch, "UID")
		if u == "" {
			return .No_UID
		}
		if uid == "" {
			uid = u
		} else if uid != u {
			return .Mixed_UIDs
		}
		if prop(ch, "RECURRENCE-ID") == nil {
			masters += 1
		}
	}
	if kind == "" {
		return .No_Component
	}
	if masters > 1 {
		return .Two_Masters
	}
	return .None
}

// address normalises a calendar user address for comparison.
address :: proc(v: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(v), allocator)
	if !strings.has_prefix(a, "mailto:") && strings.contains(a, "@") && !strings.contains(a, ":") {
		return strings.concatenate({"mailto:", a}, allocator)
	}
	return a
}

// index computes the database columns for a checked calendar object.
index :: proc(cal: ^Component, floating: ^Zone = nil) -> Index {
	ix: Index
	ix.component = main_kind(cal)
	master, overrides := masters_and_overrides(cal, ix.component)
	ix.overrides = len(overrides)
	src := master
	if src == nil && len(overrides) > 0 {
		src = overrides[0]
	}
	if src == nil {
		return ix
	}
	ix.uid = text(src, "UID")
	ix.summary = text(src, "SUMMARY")
	ix.location = text(src, "LOCATION")
	ix.status = strings.to_upper(value(src, "STATUS"))
	if op := prop(src, "ORGANIZER"); op != nil {
		ix.organizer = address(op.value)
	}
	seen := make(map[string]bool, 4, context.temp_allocator)
	atts := make([dynamic]string, 0, 4)
	for ch in cal.children {
		if ch.name != ix.component {
			continue
		}
		for ap in props(ch, "ATTENDEE") {
			a := address(ap.value)
			if !seen[a] {
				seen[a] = true
				append(&atts, a)
			}
		}
	}
	ix.attendees = atts[:]
	if rp := prop(src, "RRULE"); rp != nil && src == master {
		ix.rrule = rp.value
	}

	start, sok := prop_dt(prop(src, "DTSTART"))
	if !sok && ix.component == "VTODO" {
		start, sok = prop_dt(prop(src, "DUE"))
	}
	if !sok {
		// Undated (a VTODO with neither): it spans all time.
		ix.first_start = min(i64)
		ix.unbounded = true
		return ix
	}
	ix.has_start = true
	ix.all_day = start.is_date
	ix.dtstart = instant(start, cal, floating)
	ix.dtend = instance_end(start, component_span(src, start, cal, floating), cal, floating)

	insts, truncated := expand(cal, ix.component, min(i64), max(i64), {floating = floating, limit = 50000})
	ix.first_start = ix.dtstart
	ix.last_end = ix.dtend
	for inst in insts {
		ix.first_start = min(ix.first_start, inst.start)
		ix.last_end = max(ix.last_end, inst.end)
	}
	if master != nil {
		if rp := prop(master, "RRULE"); rp != nil {
			rule, ok := parse_rrule(rp.value)
			if ok && !bounded(rule) {
				ix.unbounded = true
			}
		}
	}
	if truncated {
		ix.unbounded = true
	}
	// Floating and all-day times move with the reader's zone: widen the
	// bounds by the largest offsets on earth so a query in any zone finds
	// them (RFC 4791 section 9.9 reads floating times in the query's zone).
	if is_floating(start) {
		ix.first_start -= 14 * 3600
		ix.last_end += 14 * 3600
	}
	return ix
}
