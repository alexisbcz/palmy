// Calendars in the Palmframe cloud: the engine the window and the command
// line share.
//
// A *source* is one calendar the grid can show. Source 0 is always the
// calendar on this device (the tab-separated file in store.odin, which works
// with no account at all). Every other source is a CalDAV collection in some
// identity's home — its own, or one shared with it — kept as a local copy by
// davclient (cloud/dav/client) and synced in both directions. The window
// never talks to the server while drawing: it reads the copies, and `sync`
// reconciles them.
//
// Events in the cloud are iCalendar. The grid shows *instances*: every
// recurring object is expanded over the year being viewed by the same
// engine the server uses (cloud/dav/ical), so what the grid shows and what
// a calendar-query returns cannot disagree.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import ck "../cloudkit"
import dc "../../cloud/dav/client"
import ical "../../cloud/dav/ical"

Obj :: struct {
	name: string,
	text: string,
	cal:  ^ical.Component,
}

Source :: struct {
	key:        string, // "local", or "<handle>/<segment>"
	name:       string, // what the sidebar shows
	handle:     string, // the identity whose home lists it ("" for the device)
	owner:      string, // the owning identity's handle
	access:     string, // owner | read | read-write
	color:      u32,
	color_name: string, // the palmy colour registered for it: src0, src1...
	visible:    bool,
	device:     bool,
	events_ok:  bool, // takes VEVENT
	local:      ^dc.Local,
	objs:       [dynamic]Obj,
	arena:      virtual.Arena, // everything parsed from the copy
	has_arena:  bool,
}

Ident_Info :: struct {
	id:     string,
	handle: string,
	name:   string,
	kind:   string,
	color:  string,
}

Cloud :: struct {
	acct:    ^dc.Account,
	signed:  bool,
	online:  bool,
	email:   string,
	idents:  [dynamic]Ident_Info,
	sources: [dynamic]Source,
	inbox:   map[string][dynamic]dc.Invitation, // per handle, from the last sync
	zone:    ^ical.Zone, // the zone the grid is drawn in
	status:  string, // the last sync, in words
	scope:   string, // a handle the session is limited to ("" for all)
	fixture: bool, // --shots: in-process data, no account
}

writable :: proc(s: ^Source) -> bool {
	return s.device || s.access == "owner" || s.access == "read-write"
}

mail_domain :: proc() -> string {
	d := os.get_env("PALM_MAIL_DOMAIN", context.temp_allocator)
	return d != "" ? d : "palm.test"
}

address_of :: proc(handle: string) -> string {
	return fmt.tprintf("mailto:%s@%s", handle, mail_domain())
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

TAILWIND_500 := [?][2]string {
	{"slate", "64748b"}, {"gray", "6b7280"}, {"zinc", "71717a"}, {"neutral", "737373"}, {"stone", "78716c"},
	{"red", "ef4444"}, {"orange", "f97316"}, {"amber", "f59e0b"}, {"yellow", "eab308"}, {"lime", "84cc16"},
	{"green", "22c55e"}, {"emerald", "10b981"}, {"teal", "14b8a6"}, {"cyan", "06b6d4"}, {"sky", "0ea5e9"},
	{"blue", "3b82f6"}, {"indigo", "6366f1"}, {"violet", "8b5cf6"}, {"purple", "a855f7"}, {"fuchsia", "d946ef"},
	{"pink", "ec4899"}, {"rose", "f43f5e"},
}

// parse_color reads "#rrggbb", "#rrggbbaa" or a Tailwind name.
parse_color :: proc(s: string, fallback: u32 = ACCENT) -> u32 {
	v := strings.trim_space(s)
	for row in TAILWIND_500 {
		if row[0] == v {
			v = row[1]
			break
		}
	}
	v = strings.trim_prefix(v, "#")
	if len(v) == 8 {
		v = v[:6]
	}
	if len(v) != 6 {
		return fallback
	}
	n, ok := strconv.parse_u64_of_base(v, 16)
	if !ok {
		return fallback
	}
	return u32(n)
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

source_reset_objs :: proc(s: ^Source) {
	if s.has_arena {
		virtual.arena_destroy(&s.arena)
		s.has_arena = false
	}
	s.objs = {}
}

// source_parse reads the local copy into parsed objects.
source_parse :: proc(s: ^Source) {
	source_reset_objs(s)
	if s.local == nil {
		return
	}
	if virtual.arena_init_growing(&s.arena) != nil {
		return
	}
	s.has_arena = true
	alloc := virtual.arena_allocator(&s.arena)
	context.allocator = alloc
	s.objs = make([dynamic]Obj, 0, 16)
	for it in dc.local_items(s.local) {
		cal, _, ok := ical.parse_one(it.data)
		if !ok || ical.check(cal) != .None {
			continue
		}
		append(&s.objs, Obj{name = it.name, text = it.data, cal = cal})
	}
}

// add_source appends a cloud source, keeping its visibility if it existed.
@(private = "file")
add_source :: proc(cl: ^Cloud, rm: dc.Remote, ident: Ident_Info, was_hidden: map[string]bool) {
	s := Source{}
	s.key = strings.clone(fmt.tprintf("%s/%s", rm.handle, rm.seg))
	s.handle = strings.clone(rm.handle)
	s.owner = strings.clone(rm.owner != "" ? rm.owner : rm.handle)
	s.access = strings.clone(rm.access != "" ? rm.access : "owner")
	s.name = strings.clone(rm.display_name != "" ? rm.display_name : rm.seg)
	s.color = parse_color(rm.color, parse_color(ident.color))
	s.visible = !was_hidden[s.key]
	s.events_ok = len(rm.components) == 0
	for comp in rm.components {
		if comp == "VEVENT" {
			s.events_ok = true
		}
	}
	if cl.acct != nil {
		s.local = dc.local_open(dc.cache_dir(cl.acct, rm.handle, "calendar", rm.seg), rm)
	}
	append(&cl.sources, s)
}

// the device calendar, always first
@(private = "file")
device_source :: proc(visible := true) -> Source {
	return Source {
		key = "local",
		name = "On this device",
		access = "owner",
		color = ACCENT,
		visible = visible,
		device = true,
		events_ok = true,
	}
}

register_source_colors :: proc(cl: ^Cloud) {
	for &s, i in cl.sources {
		name := fmt.tprintf("src%d", i)
		p_register(name, s.color)
		delete(s.color_name)
		s.color_name = strings.clone(name)
	}
}

find_source :: proc(cl: ^Cloud, key: string) -> int {
	for s, i in cl.sources {
		if s.key == key {
			return i
		}
	}
	return -1
}

ident_of :: proc(cl: ^Cloud, handle: string) -> (Ident_Info, bool) {
	for i in cl.idents {
		if i.handle == handle {
			return i, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Opening and syncing
// ---------------------------------------------------------------------------

// cloud_open reads the session and the cached copies; it does not touch the
// network. `scope` limits everything to one identity (PALM_IDENTITY).
cloud_open :: proc(cl: ^Cloud, scope := "") {
	cl.scope = strings.clone(scope)
	cl.zone, _ = ical.zone_for(ical.local_zone_name(context.temp_allocator))
	if len(cl.sources) == 0 {
		append(&cl.sources, device_source())
	}
	a, err := dc.open("calendar")
	cl.acct = a
	cl.signed = dc.ok(err) && dc.signed_in(a)
	if cl.signed {
		cl.email = strings.clone(a.cloud.session.email)
		idents_load_cached(cl)
		rebuild_sources(cl, false)
	}
}

@(private = "file")
idents_path :: proc(cl: ^Cloud) -> string {
	return fmt.tprintf("%s/identities", cl.acct.cache)
}

@(private = "file")
idents_load_cached :: proc(cl: ^Cloud) {
	data, err := os.read_entire_file_from_path(idents_path(cl), context.temp_allocator)
	if err != nil {
		return
	}
	clear(&cl.idents)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		c := strings.split(line, "\t", context.temp_allocator)
		if len(c) < 5 {
			continue
		}
		if cl.scope != "" && c[1] != cl.scope {
			continue
		}
		append(&cl.idents, Ident_Info{strings.clone(c[0]), strings.clone(c[1]), strings.clone(c[2]), strings.clone(c[3]), strings.clone(c[4])})
	}
}

@(private = "file")
idents_save :: proc(cl: ^Cloud) {
	sb := strings.builder_make(context.temp_allocator)
	for i in cl.idents {
		fmt.sbprintf(&sb, "%s\t%s\t%s\t%s\t%s\n", i.id, i.handle, i.name, i.kind, i.color)
	}
	_ = os.make_directory_all(cl.acct.cache, os.perm(0o700))
	_ = os.write_entire_file(idents_path(cl), transmute([]u8)strings.to_string(sb))
}

// rebuild_sources makes the source list from the identities and the
// collection lists (fresh from the server when `online`, else cached).
rebuild_sources :: proc(cl: ^Cloud, online: bool) -> (errors: int) {
	hidden := make(map[string]bool, 8, context.temp_allocator)
	device_visible := true
	for &s in cl.sources {
		if !s.visible {
			hidden[strings.clone(s.key, context.temp_allocator)] = true
		}
		if s.device {
			device_visible = s.visible
		}
	}
	for &s in cl.sources {
		source_reset_objs(&s)
	}
	clear(&cl.sources)
	append(&cl.sources, device_source(device_visible))
	for ident in cl.idents {
		list: []dc.Remote
		if online {
			got, err := dc.discover(cl.acct, ident.handle, "calendar")
			if dc.ok(err) {
				list = got
				dc.remotes_save(cl.acct, ident.handle, "calendar", got)
			} else {
				errors += 1
				list = dc.remotes_load(cl.acct, ident.handle, "calendar")
			}
		} else {
			list = dc.remotes_load(cl.acct, ident.handle, "calendar")
		}
		for rm in list {
			add_source(cl, rm, ident, hidden)
		}
	}
	for &s in cl.sources {
		source_parse(&s)
	}
	return
}

Sync_Report :: struct {
	pushed, pulled, removed, conflicts, failed: int,
	invitations:                                int,
}

// cloud_sync talks to the server: identities, each identity's inbox (which
// is when the server applies invitations and replies), its calendars, and a
// two-way sync of every copy.
cloud_sync :: proc(cl: ^Cloud) -> (rep: Sync_Report, err: string) {
	if !cl.signed || cl.acct == nil {
		return {}, "not signed in"
	}
	if e := dc.load_identities(cl.acct); !dc.ok(e) {
		cl.online = false
		cl.status = strings.clone(fmt.tprintf("offline: %s", e.message))
		return {}, e.message
	}
	cl.online = true
	clear(&cl.idents)
	for i in cl.acct.idents {
		if cl.scope != "" && i.handle != cl.scope {
			continue
		}
		append(&cl.idents, Ident_Info{strings.clone(i.id), strings.clone(i.handle), strings.clone(i.display_name), strings.clone(i.kind), strings.clone(i.color)})
	}
	idents_save(cl)
	if cl.inbox == nil {
		cl.inbox = make(map[string][dynamic]dc.Invitation)
	}
	for ident in cl.idents {
		items, ie := dc.inbox(cl.acct, ident.handle)
		list := make([dynamic]dc.Invitation)
		if dc.ok(ie) {
			append(&list, ..items)
		}
		cl.inbox[strings.clone(ident.handle)] = list
	}
	rep.failed += rebuild_sources(cl, true)
	for &s in cl.sources {
		if s.local == nil {
			continue
		}
		st, se := dc.sync(cl.acct, s.local)
		if !dc.ok(se) {
			rep.failed += 1
			continue
		}
		rep.pushed += st.pushed
		rep.pulled += st.pulled
		rep.removed += st.removed
		rep.conflicts += st.conflicts
		source_parse(&s)
	}
	rep.invitations = len(pending_invitations(cl))
	cl.status = strings.clone(fmt.tprintf("synced %s · %d up, %d down%s", clock_now(), rep.pushed, rep.pulled + rep.removed,
		rep.conflicts > 0 ? fmt.tprintf(", %d conflict(s) kept as .conflict", rep.conflicts) : ""))
	return rep, ""
}

// sync_one pushes and pulls one source after an edit.
sync_one :: proc(cl: ^Cloud, si: int) -> string {
	s := &cl.sources[si]
	if s.local == nil || !cl.signed {
		return ""
	}
	_, e := dc.sync(cl.acct, s.local)
	source_parse(s)
	if !dc.ok(e) {
		cl.online = false
		return fmt.tprintf("saved here; the server said: %s", e.message)
	}
	cl.online = true
	return ""
}

clock_now :: proc() -> string {
	h, m, _ := time.clock(time.now())
	return fmt.tprintf("%02d:%02d UTC", h, m)
}

cloud_sign_in :: proc(cl: ^Cloud, email, password: string) -> string {
	if cl.acct == nil {
		a, err := dc.open("calendar")
		if !dc.ok(err) {
			return err.message
		}
		cl.acct = a
	}
	e := ck.sign_in(cl.acct.cloud, email, password)
	if !ck.ok(e) {
		return e.message != "" ? e.message : ck.error_kind_name(e.kind)
	}
	cl.signed = true
	cl.email = strings.clone(email)
	return ""
}

// ---------------------------------------------------------------------------
// Instances
// ---------------------------------------------------------------------------

// to_local turns a UTC instant into the grid's date and minute of day.
to_local :: proc(cl: ^Cloud, unix: i64) -> (Date, int) {
	off := ical.offset_at(cl.zone, unix)
	l := unix + off
	days := l / 86400
	sod := l % 86400
	if sod < 0 {
		sod += 86400
		days -= 1
	}
	y, m, d := ical.civil_from_days(days)
	return Date{y, m, d}, int(sod / 60)
}

// cloud_events expands every visible cloud source over [from, to) into grid
// events (allocated with `allocator`).
cloud_events :: proc(cl: ^Cloud, from, to: Date, allocator := context.allocator) -> [dynamic]Event {
	out := make([dynamic]Event, 0, 64, allocator)
	s_unix := ical.days_from_civil(from.y, from.m, from.d) * 86400 - 14 * 3600
	e_unix := ical.days_from_civil(to.y, to.m, to.d) * 86400 + 14 * 3600
	for &s, si in cl.sources {
		if s.device {
			continue
		}
		for &o in s.objs {
			kind := ical.main_kind(o.cal)
			if kind != "VEVENT" {
				continue
			}
			insts, _ := ical.expand(o.cal, kind, s_unix, e_unix, {floating = cl.zone, limit = 2000})
			for inst in insts {
				append_instance(cl, &out, si, &o, inst, allocator)
			}
		}
	}
	return out
}

@(private = "file")
append_instance :: proc(cl: ^Cloud, out: ^[dynamic]Event, si: int, o: ^Obj, inst: ical.Instance, allocator := context.allocator) {
	comp := inst.comp
	all_day := false
	if sp := ical.prop(comp, "DTSTART"); sp != nil {
		if t, ok := ical.prop_dt(sp); ok {
			all_day = t.is_date
		}
	}
	ev := Event {
		title = strings.clone(ical.text(comp, "SUMMARY"), allocator),
		place = strings.clone(ical.text(comp, "LOCATION"), allocator),
		src = si,
		obj = strings.clone(o.name, allocator),
		uid = strings.clone(ical.text(comp, "UID"), allocator),
		recurring = inst.recurring,
		rid = inst.rid,
		cancelled = strings.equal_fold(ical.value(comp, "STATUS"), "CANCELLED"),
		lidx = -1,
	}
	if ev.title == "" {
		ev.title = strings.clone("(no title)", allocator)
	}
	if all_day {
		// Whole days: one entry per day the event covers.
		d := Date{inst.rid.y, inst.rid.m, inst.rid.d}
		if sp := ical.prop(comp, "DTSTART"); sp != nil {
			if t, ok := ical.prop_dt(sp); ok {
				d = Date{t.y, t.m, t.d}
			}
		}
		days := max(1, int((inst.end - inst.start + 3600) / 86400))
		for k in 0 ..< min(days, 62) {
			e := ev
			e.date = date_add(d, k)
			e.start = -1
			if k > 0 {
				e.title = strings.clone(e.title, allocator)
				e.place = strings.clone(e.place, allocator)
				e.obj = strings.clone(e.obj, allocator)
				e.uid = strings.clone(e.uid, allocator)
			}
			append(out, e)
		}
		return
	}
	ev.date, ev.start = to_local(cl, inst.start)
	ev.mins = int((inst.end - inst.start) / 60)
	append(out, ev)
}

// ---------------------------------------------------------------------------
// Writing events
// ---------------------------------------------------------------------------

Recur :: enum u8 {
	None,
	Daily,
	Weekly,
	Monthly,
	Yearly,
}

RECUR_LABELS := [Recur]string {
	.None    = "Does not repeat",
	.Daily   = "Every day",
	.Weekly  = "Every week",
	.Monthly = "Every month",
	.Yearly  = "Every year",
}

RECUR_RULES := [Recur]string {
	.None    = "",
	.Daily   = "FREQ=DAILY",
	.Weekly  = "FREQ=WEEKLY",
	.Monthly = "FREQ=MONTHLY",
	.Yearly  = "FREQ=YEARLY",
}

recur_of :: proc(rrule: string) -> Recur {
	r, ok := ical.parse_rrule(rrule)
	if !ok {
		return .None
	}
	#partial switch r.freq {
	case .Daily: return .Daily
	case .Weekly: return .Weekly
	case .Monthly: return .Monthly
	case .Yearly: return .Yearly
	}
	return .None
}

Draft :: struct {
	date:      Date,
	start:     int, // -1: all day
	mins:      int,
	title:     string,
	place:     string,
	rrule:     string, // "" or FREQ=...
	attendees: []string, // plain addresses or mailto:
	organizer: string, // identity handle, used when there are attendees
}

new_uid :: proc() -> string {
	return fmt.aprintf("%x-%x@palmframe", time.time_to_unix_nano(time.now()), u32(os.get_pid()))
}

@(private = "file")
dt_line :: proc(sb: ^strings.Builder, name: string, d: Date, minutes: int, tzid: string) {
	if minutes < 0 {
		fmt.sbprintf(sb, "%s;VALUE=DATE:%04d%02d%02d\r\n", name, d.y, d.m, d.d)
		return
	}
	if tzid == "" || tzid == "UTC" {
		fmt.sbprintf(sb, "%s:%04d%02d%02dT%02d%02d00\r\n", name, d.y, d.m, d.d, minutes / 60, minutes % 60)
		return
	}
	fmt.sbprintf(sb, "%s;TZID=%s:%04d%02d%02dT%02d%02d00\r\n", name, tzid, d.y, d.m, d.d, minutes / 60, minutes % 60)
}

// build_vevent writes a whole calendar object for a new event.
build_vevent :: proc(uid: string, dr: Draft, tzid: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Palmframe//Calendar//EN\r\nCALSCALE:GREGORIAN\r\nBEGIN:VEVENT\r\n")
	fmt.sbprintf(&sb, "UID:%s\r\n", uid)
	fmt.sbprintf(&sb, "DTSTAMP:%s\r\n", ical.format_dt(ical.utc_dt(time.time_to_unix(time.now())), context.temp_allocator))
	write_times(&sb, dr, tzid)
	ical.fold_line(&sb, fmt.tprintf("SUMMARY:%s", ical.escape_text(dr.title)))
	if dr.place != "" {
		ical.fold_line(&sb, fmt.tprintf("LOCATION:%s", ical.escape_text(dr.place)))
	}
	if dr.rrule != "" {
		fmt.sbprintf(&sb, "RRULE:%s\r\n", dr.rrule)
	}
	if len(dr.attendees) > 0 && dr.organizer != "" {
		fmt.sbprintf(&sb, "ORGANIZER;CN=%s:%s\r\n", dr.organizer, address_of(dr.organizer))
		fmt.sbprintf(&sb, "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=CHAIR:%s\r\n", address_of(dr.organizer))
		for a in dr.attendees {
			addr := ical.address(a, context.temp_allocator)
			if addr == "" || addr == address_of(dr.organizer) {
				continue
			}
			fmt.sbprintf(&sb, "ATTENDEE;PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT;RSVP=TRUE:%s\r\n", addr)
		}
	}
	strings.write_string(&sb, "SEQUENCE:0\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
	return strings.to_string(sb)
}

@(private = "file")
write_times :: proc(sb: ^strings.Builder, dr: Draft, tzid: string) {
	if dr.start < 0 {
		dt_line(sb, "DTSTART", dr.date, -1, "")
		dt_line(sb, "DTEND", date_add(dr.date, max(1, dr.mins / (24 * 60))), -1, "")
		return
	}
	dt_line(sb, "DTSTART", dr.date, dr.start, tzid)
	end := dr.start + max(dr.mins, 0)
	dt_line(sb, "DTEND", date_add(dr.date, end / (24 * 60)), end % (24 * 60), tzid)
}

// edit_vevent rewrites the master of an existing object from a draft,
// keeping everything else (attendees, alarms, other clients' properties).
edit_vevent :: proc(text: string, dr: Draft, tzid: string, allocator := context.allocator) -> (string, bool) {
	cal, _, ok := ical.parse_one(text)
	if !ok {
		return "", false
	}
	master, _ := ical.masters_and_overrides(cal, "VEVENT")
	if master == nil {
		return "", false
	}
	tsb := strings.builder_make(context.temp_allocator)
	write_times(&tsb, dr, tzid)
	times, _, _ := ical.parse_one(fmt.tprintf("BEGIN:X\r\n%sEND:X\r\n", strings.to_string(tsb)))
	ical.remove_props(master, "DURATION")
	for p in times.props {
		ical.set_prop(master, p.name, p.value, p.params)
	}
	ical.set_prop(master, "SUMMARY", ical.escape_text(dr.title))
	if dr.place != "" {
		ical.set_prop(master, "LOCATION", ical.escape_text(dr.place))
	} else {
		ical.remove_props(master, "LOCATION")
	}
	if dr.rrule != "" {
		old := ical.value(master, "RRULE")
		if recur_of(old) != recur_of(dr.rrule) {
			ical.set_prop(master, "RRULE", dr.rrule)
		}
	} else {
		ical.remove_props(master, "RRULE")
		ical.remove_props(master, "EXDATE")
	}
	seq, _ := strconv.parse_int(ical.value(master, "SEQUENCE"))
	ical.set_prop(master, "SEQUENCE", fmt.tprintf("%d", seq + 1))
	ical.set_prop(master, "DTSTAMP", ical.format_dt(ical.utc_dt(time.time_to_unix(time.now())), context.temp_allocator))
	return ical.write(cal, allocator), true
}

// exclude_instance adds an EXDATE for one occurrence, written in the same
// form as DTSTART so every client matches it.
exclude_instance :: proc(text: string, rid: ical.DT, allocator := context.allocator) -> (string, bool) {
	cal, _, ok := ical.parse_one(text)
	if !ok {
		return "", false
	}
	master, overrides := ical.masters_and_overrides(cal, "VEVENT")
	if master == nil {
		return "", false
	}
	// Drop an override for that instance, if there is one.
	key := ical.format_dt(rid, context.temp_allocator)
	for ov in overrides {
		if ical.value(ov, "RECURRENCE-ID") == key {
			for ch, i in cal.children {
				if ch == ov {
					ordered_remove(&cal.children, i)
					break
				}
			}
		}
	}
	params: []ical.Param
	if rid.tzid != "" {
		params = make([]ical.Param, 1)
		vals := make([]string, 1)
		vals[0] = rid.tzid
		params[0] = ical.Param{name = "TZID", values = vals}
	} else if rid.is_date {
		params = make([]ical.Param, 1)
		vals := make([]string, 1)
		vals[0] = "DATE"
		params[0] = ical.Param{name = "VALUE", values = vals}
	}
	append(&master.props, ical.Prop{name = "EXDATE", value = strings.clone(key), params = params})
	return ical.write(cal, allocator), true
}

// target_source is the first owned calendar of `handle` that takes events.
target_source :: proc(cl: ^Cloud, handle: string) -> int {
	for s, i in cl.sources {
		if !s.device && s.handle == handle && s.access == "owner" && s.events_ok {
			return i
		}
	}
	return -1
}

cloud_create :: proc(cl: ^Cloud, si: int, dr: Draft) -> (name: string, err: string) {
	s := &cl.sources[si]
	if s.device {
		return "", "the device calendar is not iCalendar"
	}
	if !writable(s) {
		return "", fmt.tprintf("%q is shared with you read-only", s.name)
	}
	uid := new_uid()
	d := dr
	if len(d.attendees) > 0 && d.organizer == "" {
		d.organizer = s.handle
	}
	text := build_vevent(uid, d, cl.zone.name, context.temp_allocator)
	name = fmt.aprintf("%s.ics", uid)
	if !dc.local_write(s.local, name, text) {
		return "", "could not write the local copy"
	}
	source_parse(s)
	return name, sync_one(cl, si)
}

find_obj :: proc(s: ^Source, name: string) -> ^Obj {
	for &o in s.objs {
		if o.name == name {
			return &o
		}
	}
	return nil
}

cloud_edit :: proc(cl: ^Cloud, si: int, name: string, dr: Draft) -> string {
	s := &cl.sources[si]
	if !writable(s) {
		return fmt.tprintf("%q is shared with you read-only", s.name)
	}
	o := find_obj(s, name)
	if o == nil {
		return "the event is gone"
	}
	text, ok := edit_vevent(o.text, dr, cl.zone.name, context.temp_allocator)
	if !ok || !dc.local_write(s.local, name, text) {
		return "could not write the local copy"
	}
	source_parse(s)
	return sync_one(cl, si)
}

cloud_delete :: proc(cl: ^Cloud, si: int, name: string, only: Maybe(ical.DT) = nil) -> string {
	s := &cl.sources[si]
	if !writable(s) {
		return fmt.tprintf("%q is shared with you read-only", s.name)
	}
	if rid, one := only.?; one {
		o := find_obj(s, name)
		if o == nil {
			return "the event is gone"
		}
		text, ok := exclude_instance(o.text, rid, context.temp_allocator)
		if !ok || !dc.local_write(s.local, name, text) {
			return "could not write the local copy"
		}
	} else if !dc.local_delete(s.local, name) {
		return "the event is gone"
	}
	source_parse(s)
	return sync_one(cl, si)
}

// ---------------------------------------------------------------------------
// Invitations
// ---------------------------------------------------------------------------

Invite :: struct {
	src:       int,
	obj:       string,
	uid:       string,
	title:     string,
	handle:    string, // the invited identity
	organizer: string,
	start:     i64,
	partstat:  string,
	recurring: bool,
}

partstat_for :: proc(comp: ^ical.Component, who: string) -> (string, bool) {
	for p in ical.props(comp, "ATTENDEE") {
		if ical.address(p.value, context.temp_allocator) == who {
			ps := strings.to_upper(ical.param(p, "PARTSTAT"), context.temp_allocator)
			return ps == "" ? "NEEDS-ACTION" : ps, true
		}
	}
	return "", false
}

// pending_invitations: events in an identity's own calendars that another
// organizer invited it to and that it has not answered.
pending_invitations :: proc(cl: ^Cloud, allocator := context.allocator) -> []Invite {
	out := make([dynamic]Invite, 0, 4, allocator)
	for &s, si in cl.sources {
		if s.device || s.access != "owner" {
			continue
		}
		me := address_of(s.handle)
		for &o in s.objs {
			master, _ := ical.masters_and_overrides(o.cal, "VEVENT")
			if master == nil {
				continue
			}
			org := ""
			if op := ical.prop(master, "ORGANIZER"); op != nil {
				org = ical.address(op.value, context.temp_allocator)
			}
			if org == "" || org == me {
				continue
			}
			ps, here := partstat_for(master, me)
			if !here || ps != "NEEDS-ACTION" {
				continue
			}
			if strings.equal_fold(ical.value(master, "STATUS"), "CANCELLED") {
				continue
			}
			start: i64
			if t, ok := ical.prop_dt(ical.prop(master, "DTSTART")); ok {
				start = ical.instant(t, o.cal, cl.zone)
			}
			append(&out, Invite {
				src = si,
				obj = strings.clone(o.name, allocator),
				uid = strings.clone(ical.text(master, "UID"), allocator),
				title = strings.clone(ical.text(master, "SUMMARY"), allocator),
				handle = s.handle,
				organizer = strings.clone(strings.trim_prefix(org, "mailto:"), allocator),
				start = start,
				partstat = ps,
				recurring = ical.prop(master, "RRULE") != nil,
			})
		}
	}
	slice.sort_by(out[:], proc(a, b: Invite) -> bool {return a.start < b.start})
	return out[:]
}

// respond answers an invitation: PARTSTAT on this identity's ATTENDEE line
// in every instance, then the server sends the REPLY when the copy syncs.
respond :: proc(cl: ^Cloud, si: int, name, partstat: string) -> string {
	s := &cl.sources[si]
	o := find_obj(s, name)
	if o == nil {
		return "the invitation is gone"
	}
	me := address_of(s.handle)
	cal, _, ok := ical.parse_one(o.text)
	if !ok {
		return "the event does not parse"
	}
	found := false
	uid := ""
	for comp in cal.children {
		if comp.name != "VEVENT" {
			continue
		}
		uid = ical.text(comp, "UID")
		for &p in comp.props {
			if p.name == "ATTENDEE" && ical.address(p.value, context.temp_allocator) == me {
				ical.set_param(&p, "PARTSTAT", partstat)
				ical.remove_param(&p, "RSVP")
				found = true
			}
		}
	}
	if !found {
		return "this identity is not an attendee"
	}
	if !dc.local_write(s.local, name, ical.write(cal, context.temp_allocator)) {
		return "could not write the local copy"
	}
	source_parse(s)
	msg := sync_one(cl, si)
	// The inbox copy of the request has been answered: take it out.
	if cl.online {
		if items, has := cl.inbox[s.handle]; has {
			for it in items {
				if strings.contains(it.data, fmt.tprintf("UID:%s", uid)) {
					_ = dc.dismiss(cl.acct, it.href)
				}
			}
		}
	}
	return msg
}

// attendees_of lists (address, partstat, is organizer) for an event.
Person :: struct {
	address:   string,
	name:      string,
	partstat:  string,
	organizer: bool,
}

people_of :: proc(cl: ^Cloud, si: int, name: string, allocator := context.temp_allocator) -> []Person {
	out := make([dynamic]Person, 0, 4, allocator)
	if si <= 0 || si >= len(cl.sources) {
		return out[:]
	}
	o := find_obj(&cl.sources[si], name)
	if o == nil {
		return out[:]
	}
	master, _ := ical.masters_and_overrides(o.cal, "VEVENT")
	if master == nil {
		return out[:]
	}
	org := ""
	if op := ical.prop(master, "ORGANIZER"); op != nil {
		org = ical.address(op.value, allocator)
	}
	for p in ical.props(master, "ATTENDEE") {
		addr := ical.address(p.value, allocator)
		ps := strings.to_upper(ical.param(p, "PARTSTAT"), allocator)
		append(&out, Person{
			address = strings.trim_prefix(addr, "mailto:"),
			name = ical.param(p, "CN"),
			partstat = ps == "" ? "NEEDS-ACTION" : ps,
			organizer = addr == org,
		})
	}
	return out[:]
}
