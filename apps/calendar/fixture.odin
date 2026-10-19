// In-process cloud data for --selftest and --shots: real local copies in a
// scratch directory, read through the same davclient cache and the same
// parser the synced app uses, with no account and no server.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import dc "../../cloud/dav/client"
import ical "../../cloud/dav/ical"

fixture_begin :: proc(cl: ^Cloud, zone: string) {
	cl.fixture = true
	cl.signed = false
	cl.zone, _ = ical.zone_for(zone)
	clear(&cl.sources)
	clear(&cl.idents)
	append(&cl.sources, Source{key = "local", name = "Local calendar", access = "owner", color = ACCENT, visible = true, device = true, events_ok = true})
}

fixture_ident :: proc(cl: ^Cloud, handle, name, kind, color: string) {
	append(&cl.idents, Ident_Info{id = handle, handle = strings.clone(handle), name = strings.clone(name), kind = kind, color = color})
}

// fixture_source makes a collection copy under `dir` and returns its index.
fixture_source :: proc(cl: ^Cloud, dir, handle, seg, name, color, access, owner: string) -> int {
	path := fmt.aprintf("%s/%s/calendar/%s", dir, handle, seg)
	_ = os.remove_all(path)
	// Heap, not a literal: a slice literal lives in this procedure's frame.
	comps := make([]string, 2)
	comps[0] = "VEVENT"
	comps[1] = "VTODO"
	rm := dc.Remote {
		href = fmt.aprintf("/dav/calendars/%s/%s/", handle, seg),
		kind = "calendar",
		handle = strings.clone(handle),
		seg = strings.clone(seg),
		display_name = strings.clone(name),
		color = strings.clone(color),
		access = access,
		owner = strings.clone(owner),
		components = comps,
	}
	s := Source {
		key = fmt.aprintf("%s/%s", handle, seg),
		name = rm.display_name,
		handle = rm.handle,
		owner = rm.owner,
		access = access,
		color = parse_color(color),
		visible = true,
		events_ok = true,
		local = dc.local_open(path, rm),
	}
	append(&cl.sources, s)
	return len(cl.sources) - 1
}

// fixture_put writes an object as if it had synced down (clean, with an
// etag), so pending changes stay empty.
fixture_put :: proc(cl: ^Cloud, si: int, name, text: string) {
	s := &cl.sources[si]
	dc.local_write(s.local, name, text)
	e := s.local.entries[name]
	e.state = .Clean
	e.etag = "\"fixture\""
	s.local.entries[name] = e
	dc.local_save(s.local)
}

fixture_end :: proc(cl: ^Cloud) {
	for &s in cl.sources {
		source_parse(&s)
	}
}

// vevent is a compact calendar object for fixtures.
vevent :: proc(uid, start, end, summary: string, extra := "", tz := "Europe/Paris") -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Palmframe//Fixture//EN\r\nBEGIN:VEVENT\r\n")
	fmt.sbprintf(&sb, "UID:%s\r\nDTSTAMP:20261001T080000Z\r\n", uid)
	if len(start) == 8 {
		fmt.sbprintf(&sb, "DTSTART;VALUE=DATE:%s\r\nDTEND;VALUE=DATE:%s\r\n", start, end)
	} else {
		fmt.sbprintf(&sb, "DTSTART;TZID=%s:%s\r\nDTEND;TZID=%s:%s\r\n", tz, start, tz, end)
	}
	fmt.sbprintf(&sb, "SUMMARY:%s\r\n", summary)
	if extra != "" {
		strings.write_string(&sb, extra)
	}
	strings.write_string(&sb, "END:VEVENT\r\nEND:VCALENDAR\r\n")
	return strings.to_string(sb)
}
