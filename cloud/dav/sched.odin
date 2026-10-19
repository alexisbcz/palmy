// Scheduling inside the platform (RFC 6638 implicit scheduling, iTIP RFC
// 5546 messages).
//
// Sending is a row: when an organizer stores an event with attendees, the
// server writes one dav_itip row per attendee, *as the organizer's
// identity*. The database routes it: a local address gets the attendee's
// identity, anything else is queued "not sent: outbound not enabled".
//
// Receiving is done by the recipient's own session. Whenever an identity's
// calendars are looked at (PROPFIND or REPORT on its home, a calendar or
// its inbox), unprocessed messages are applied to its calendars under its
// own RLS: a REQUEST becomes (or updates) an event in its default calendar
// with PARTSTAT=NEEDS-ACTION, a REPLY updates the organizer's copy, a
// CANCEL marks the event cancelled. Nothing ever writes into another
// identity's calendar — the only cross-identity thing is the message.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import ical "ical"
import web "web"
import x "xml"

now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

Sched_Role :: enum u8 {
	None,
	Organizer,
	Attendee,
}

Itip_Out :: struct {
	to:     string,
	method: string,
	uid:    string,
	body:   string,
}

Sched_Plan :: struct {
	role:     Sched_Role,
	out:      [dynamic]Itip_Out,
	modified: bool,
}

// The components of the scheduling kind (VEVENT or VTODO).
@(private = "file")
sched_comps :: proc(cal: ^ical.Component) -> []^ical.Component {
	kind := ical.main_kind(cal)
	return ical.children(cal, kind, context.allocator)
}

// is_scheduling_object: RFC 6638 calls a resource with an ORGANIZER one.
is_scheduling_object :: proc(cal: ^ical.Component) -> bool {
	return organizer_of(cal) != ""
}

@(private = "file")
organizer_of :: proc(cal: ^ical.Component) -> string {
	for comp in sched_comps(cal) {
		if p := ical.prop(comp, "ORGANIZER"); p != nil {
			return ical.address(p.value)
		}
	}
	return ""
}

// attendees_of lists the attendees the server schedules for (not the ones
// a client said it handles itself, SCHEDULE-AGENT=CLIENT or NONE).
@(private = "file")
attendees_of :: proc(cal: ^ical.Component, except: string) -> []string {
	seen := make(map[string]bool)
	out := make([dynamic]string, 0, 4)
	for comp in sched_comps(cal) {
		for p in ical.props(comp, "ATTENDEE") {
			agent := strings.to_upper(ical.param(p, "SCHEDULE-AGENT"))
			if agent == "CLIENT" || agent == "NONE" {
				continue
			}
			a := ical.address(p.value)
			if a == except || seen[a] || !strings.has_prefix(a, "mailto:") {
				continue
			}
			seen[a] = true
			append(&out, a)
		}
	}
	return out[:]
}

@(private = "file")
partstat_of :: proc(comp: ^ical.Component, who: string) -> (string, bool) {
	for p in ical.props(comp, "ATTENDEE") {
		if ical.address(p.value) == who {
			ps := strings.to_upper(ical.param(p, "PARTSTAT"))
			return ps == "" ? "NEEDS-ACTION" : ps, true
		}
	}
	return "", false
}

@(private = "file")
rid_key :: proc(comp: ^ical.Component) -> string {
	if p := ical.prop(comp, "RECURRENCE-ID"); p != nil {
		return p.value
	}
	return ""
}

// What makes a change worth re-sending (RFC 6638 3.2.8 leaves it to the
// server; these are the properties an attendee's answer depends on).
@(private = "file")
SIGNIFICANT := [?]string{"DTSTART", "DTEND", "DURATION", "DUE", "RRULE", "RDATE", "EXDATE", "SUMMARY", "LOCATION", "DESCRIPTION", "STATUS"}

@(private = "file")
significant_change :: proc(old, new_: ^ical.Component) -> bool {
	a := sched_comps(old)
	b := sched_comps(new_)
	if len(a) != len(b) {
		return true
	}
	for nb in b {
		var_match: ^ical.Component
		for na in a {
			if rid_key(na) == rid_key(nb) {
				var_match = na
			}
		}
		if var_match == nil {
			return true
		}
		for name in SIGNIFICANT {
			pa := ical.props(var_match, name)
			pb := ical.props(nb, name)
			if len(pa) != len(pb) {
				return true
			}
			for i in 0 ..< len(pa) {
				if pa[i].value != pb[i].value || ical.param(pa[i], "TZID") != ical.param(pb[i], "TZID") {
					return true
				}
			}
		}
		if len(attendees_of_comp(var_match)) != len(attendees_of_comp(nb)) {
			return true
		}
	}
	return false
}

@(private = "file")
attendees_of_comp :: proc(comp: ^ical.Component) -> []^ical.Prop {
	return ical.props(comp, "ATTENDEE")
}

// itip_message is the object with METHOD set and the per-attendee
// bookkeeping parameters removed.
@(private = "file")
itip_message :: proc(cal: ^ical.Component, method: string) -> string {
	msg := ical.clone(cal)
	ical.remove_props(msg, "METHOD")
	inject := make([dynamic]ical.Prop, 0, len(msg.props) + 1)
	for p in msg.props {
		append(&inject, p)
		if p.name == "VERSION" {
			append(&inject, ical.Prop{name = "METHOD", value = method})
		}
	}
	msg.props = inject
	if ical.prop(msg, "METHOD") == nil {
		append(&msg.props, ical.Prop{name = "METHOD", value = method})
	}
	for comp in sched_comps(msg) {
		for &p in comp.props {
			if p.name == "ATTENDEE" || p.name == "ORGANIZER" {
				ical.remove_param(&p, "SCHEDULE-STATUS")
				ical.remove_param(&p, "SCHEDULE-FORCE-SEND")
			}
		}
		if method == "CANCEL" {
			ical.set_prop(comp, "STATUS", "CANCELLED")
		}
	}
	return ical.write(msg)
}

// reply_message is an attendee's REPLY: each component reduced to what the
// organizer needs, with only this attendee.
@(private = "file")
reply_message :: proc(cal: ^ical.Component, me: string, force_partstat := "") -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Palmy//DAV//EN\r\nMETHOD:REPLY\r\n")
	for comp in sched_comps(cal) {
		mine: ^ical.Prop
		for p in ical.props(comp, "ATTENDEE") {
			if ical.address(p.value) == me {
				mine = p
			}
		}
		if mine == nil {
			continue
		}
		out := new(ical.Component)
		out.name = comp.name
		append(&out.props, ical.Prop{name = "UID", value = ical.value(comp, "UID")})
		append(&out.props, ical.Prop{name = "DTSTAMP", value = ical.format_dt(ical.utc_dt(now_unix()))})
		for name in ([]string{"RECURRENCE-ID", "DTSTART", "SEQUENCE", "SUMMARY", "ORGANIZER"}) {
			if p := ical.prop(comp, name); p != nil {
				append(&out.props, p^)
			}
		}
		att := mine^
		if force_partstat != "" {
			ical.set_param(&att, "PARTSTAT", force_partstat)
		}
		ical.remove_param(&att, "SCHEDULE-STATUS")
		ical.remove_param(&att, "RSVP")
		append(&out.props, att)
		ical.write_to(&sb, out)
	}
	strings.write_string(&sb, "END:VCALENDAR\r\n")
	return strings.to_string(sb)
}

@(private = "file")
is_local :: proc(c: ^Ctx, address: string) -> bool {
	b := jb_make()
	jb_str(&b, "address", address)
	v, e := rpc(c, "dav_resolve_address", jb_done(&b))
	if !db_ok(e) {
		return false
	}
	_, isnull := v.(json.Null)
	return v != nil && !isnull
}


// sched_plan decides what a PUT sends, and stamps SCHEDULE-STATUS on the
// stored copy. Only for the collection's owner: a delegate writing into a
// shared calendar does not speak for its owner.
sched_plan :: proc(c: ^Ctx, r: ^Res, old_body: string, cal: ^ical.Component) -> Sched_Plan {
	plan := Sched_Plan{out = make([dynamic]Itip_Out, 0, 4)}
	if r.coll.access != "owner" {
		return plan
	}
	me := strings.to_lower(address_of(r.ident))
	org := organizer_of(cal)
	if org == "" {
		return plan
	}
	uid := ""
	if comps := sched_comps(cal); len(comps) > 0 {
		uid = ical.text(comps[0], "UID")
	}
	old: ^ical.Component
	if old_body != "" {
		old, _, _ = ical.parse_one(old_body)
	}

	if org == me {
		plan.role = .Organizer
		now := attendees_of(cal, me)
		send := old == nil || significant_change(old, cal)
		local := make(map[string]bool)
		for a in now {
			local[a] = is_local(c, a)
		}
		if send {
			body := itip_message(cal, "REQUEST")
			for a in now {
				append(&plan.out, Itip_Out{a, "REQUEST", uid, body})
			}
			// Stamp what happened on each attendee (RFC 6638 3.2.9):
			// 1.2 delivered, 5.1 could not be delivered (outbound mail
			// is not enabled yet).
			for comp in sched_comps(cal) {
				for &p in comp.props {
					if p.name != "ATTENDEE" {
						continue
					}
					a := ical.address(p.value)
					if a == me {
						continue
					}
					if st, has := local[a]; has {
						ical.set_param(&p, "SCHEDULE-STATUS", st ? "1.2" : "5.1")
						plan.modified = true
					}
				}
			}
		}
		if old != nil {
			was := attendees_of(old, me)
			for a in was {
				still := false
				for b in now {
					if a == b {
						still = true
					}
				}
				if !still {
					append(&plan.out, Itip_Out{a, "CANCEL", uid, itip_message(old, "CANCEL")})
				}
			}
		}
		return plan
	}

	// An attendee answering.
	mine_now := false
	changed := old == nil
	for comp in sched_comps(cal) {
		ps, here := partstat_of(comp, me)
		if !here {
			continue
		}
		mine_now = true
		if old != nil {
			found := false
			for oc in sched_comps(old) {
				if rid_key(oc) == rid_key(comp) {
					found = true
					ops, _ := partstat_of(oc, me)
					if ops != ps {
						changed = true
					}
				}
			}
			if !found {
				changed = true
			}
		}
		_ = ps
	}
	if !mine_now || !changed {
		return plan
	}
	if ps, _ := partstat_of(sched_comps(cal)[0], me); ps == "NEEDS-ACTION" {
		return plan
	}
	plan.role = .Attendee
	append(&plan.out, Itip_Out{org, "REPLY", uid, reply_message(cal, me)})
	return plan
}

sched_send :: proc(c: ^Ctx, r: ^Res, plan: ^Sched_Plan) {
	if len(plan.out) == 0 {
		return
	}
	me := address_of(r.ident)
	for m in plan.out {
		b := jb_make()
		jb_str(&b, "identity_id", r.ident.id)
		jb_str(&b, "sender_address", me)
		jb_str(&b, "recipient_address", m.to)
		jb_str(&b, "method", m.method)
		jb_str(&b, "uid", m.uid)
		jb_str(&b, "body", m.body)
		_, e := rest(c, "POST", "/dav_itip", jb_done(&b))
		if !db_ok(e) && cfg.log {
			fmt.eprintfln("  itip %s to %s failed: %s", m.method, m.to, e.message)
		}
	}
}

// sched_on_delete: the organizer deleting cancels; an attendee deleting
// declines (unless the client says Schedule-Reply: F).
sched_on_delete :: proc(c: ^Ctx, r: ^Res, old_body: string) {
	if r.coll.access != "owner" {
		return
	}
	cal, _, ok := ical.parse_one(old_body)
	if !ok {
		return
	}
	me := strings.to_lower(address_of(r.ident))
	org := organizer_of(cal)
	if org == "" {
		return
	}
	plan := Sched_Plan{out = make([dynamic]Itip_Out, 0, 4)}
	uid := ""
	if comps := sched_comps(cal); len(comps) > 0 {
		uid = ical.text(comps[0], "UID")
	}
	if org == me {
		body := itip_message(cal, "CANCEL")
		for a in attendees_of(cal, me) {
			append(&plan.out, Itip_Out{a, "CANCEL", uid, body})
		}
	} else if strings.to_upper(web.header(c.req.headers, "Schedule-Reply")) != "F" &&
	   strings.to_upper(ical.value(sched_comps(cal)[0], "STATUS")) != "CANCELLED" {
		// Removing an event the organizer already cancelled says nothing.
		for comp in sched_comps(cal) {
			if _, here := partstat_of(comp, me); here {
				append(&plan.out, Itip_Out{org, "REPLY", uid, reply_message(cal, me, "DECLINED")})
				break
			}
		}
	}
	sched_send(c, r, &plan)
}

// ---------------------------------------------------------------------------
// The inbox
// ---------------------------------------------------------------------------

ITIP_COLS :: "id,method,uid,body,sender_address,created_at"

@(private = "file")
itip_from :: proc(row: json.Object) -> Itip {
	return Itip {
		id = jstr(row, "id"),
		method = jstr(row, "method"),
		uid = jstr(row, "uid"),
		body = jstr(row, "body"),
		sender = jstr(row, "sender_address"),
		created_at = jstr(row, "created_at"),
	}
}

inbox_items :: proc(c: ^Ctx, ident: ^Ident) -> []Itip {
	v, e := rest(c, "GET", fmt.tprintf("/dav_itip?recipient_identity=eq.%s&dismissed_at=is.null&select=%s&order=created_at", ident.id, ITIP_COLS))
	out := make([dynamic]Itip, 0, 4)
	if !db_ok(e) {
		return out[:]
	}
	for row in rows(v) {
		append(&out, itip_from(row))
	}
	return out[:]
}

inbox_item :: proc(c: ^Ctx, ident: ^Ident, id: string) -> (Itip, bool) {
	// The id comes from the URL and goes into a PostgREST query string:
	// nothing but a UUID gets that far.
	if len(id) != 36 {
		return {}, false
	}
	for ch, i in transmute([]u8)id {
		dash := i == 8 || i == 13 || i == 18 || i == 23
		hex := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
		if (dash && ch != '-') || (!dash && !hex) {
			return {}, false
		}
	}
	v, e := rest(c, "GET", fmt.tprintf("/dav_itip?recipient_identity=eq.%s&dismissed_at=is.null&id=eq.%s&select=%s", ident.id, id, ITIP_COLS))
	if !db_ok(e) {
		return {}, false
	}
	rs := rows(v)
	if len(rs) == 0 {
		return {}, false
	}
	return itip_from(rs[0]), true
}

// owned_object_by_uid finds an event by UID in any calendar the identity owns.
@(private = "file")
owned_object_by_uid :: proc(c: ^Ctx, ident: ^Ident, uid: string) -> (Coll, Obj, bool) {
	for col in collections(c, ident, "calendar") {
		if col.access != "owner" {
			continue
		}
		if o, ok := object_by_uid(c, col, uid); ok {
			return col, o, true
		}
	}
	return {}, {}, false
}

@(private = "file")
default_calendar :: proc(c: ^Ctx, ident: ^Ident) -> (Coll, bool) {
	first: Coll
	have := false
	for col in collections(c, ident, "calendar") {
		if col.access != "owner" {
			continue
		}
		has_event := false
		for comp in col.components {
			if comp == "VEVENT" {
				has_event = true
			}
		}
		if !has_event {
			continue
		}
		if col.slug == "default" {
			return col, true
		}
		if !have {
			first = col
			have = true
		}
	}
	return first, have
}

// safe_name turns a UID into a resource name.
safe_name :: proc(uid: string) -> string {
	sb := strings.builder_make()
	for ch in transmute([]u8)uid {
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '@':
			strings.write_byte(&sb, ch)
		case:
			strings.write_byte(&sb, '_')
		}
	}
	strings.write_string(&sb, ".ics")
	return strings.to_string(sb)
}

// process_inbox applies this identity's unprocessed scheduling messages.
process_inbox :: proc(c: ^Ctx, ident: ^Ident) {
	v, e := rest(c, "GET", fmt.tprintf("/dav_itip?recipient_identity=eq.%s&processed_at=is.null&select=%s&order=created_at", ident.id, ITIP_COLS))
	if !db_ok(e) {
		return
	}
	for row in rows(v) {
		item := itip_from(row)
		// Claim it first, so two requests never apply one message twice.
		claimed, ce := rest(c, "PATCH", fmt.tprintf("/dav_itip?id=eq.%s&processed_at=is.null", item.id),
			`{"processed_at":"now"}`, prefer = "return=representation")
		if !db_ok(ce) || len(rows(claimed)) == 0 {
			continue
		}
		apply_itip(c, ident, item)
	}
}

@(private = "file")
apply_itip :: proc(c: ^Ctx, ident: ^Ident, item: Itip) {
	msg, _, ok := ical.parse_one(item.body)
	if !ok {
		return
	}
	me := strings.to_lower(address_of(ident))
	ical.remove_props(msg, "METHOD")
	col, existing, found := owned_object_by_uid(c, ident, item.uid)

	switch item.method {
	case "REQUEST", "ADD":
		if found {
			// Keep this attendee's own answer where the event did not move.
			old, _, ook := ical.parse_one(existing.body)
			if ook {
				for comp in sched_comps(msg) {
					for oc in sched_comps(old) {
						if rid_key(oc) != rid_key(comp) {
							continue
						}
						moved := ical.value(oc, "DTSTART") != ical.value(comp, "DTSTART")
						ops, here := partstat_of(oc, me)
						if !here || moved {
							continue
						}
						for &p in comp.props {
							if p.name == "ATTENDEE" && ical.address(p.value) == me {
								ical.set_param(&p, "PARTSTAT", ops)
							}
						}
					}
				}
			}
			put_calendar_text(c, col, existing.name, "", false, ical.write(msg), new_schedule_tag())
		} else {
			target, has := default_calendar(c, ident)
			if !has {
				return
			}
			put_calendar_text(c, target, safe_name(item.uid), "", false, ical.write(msg), new_schedule_tag())
		}
	case "CANCEL":
		if !found {
			return
		}
		stored, _, sok := ical.parse_one(existing.body)
		if !sok {
			return
		}
		for comp in sched_comps(msg) {
			rid := rid_key(comp)
			for sc in sched_comps(stored) {
				if rid == "" || rid_key(sc) == rid {
					ical.set_prop(sc, "STATUS", "CANCELLED")
				}
			}
		}
		put_calendar_text(c, col, existing.name, "", false, ical.write(stored), new_schedule_tag())
	case "REPLY":
		if !found {
			return
		}
		stored, _, sok := ical.parse_one(existing.body)
		if !sok || organizer_of(stored) != me {
			return
		}
		changed := false
		for comp in sched_comps(msg) {
			rid := rid_key(comp)
			for ap in ical.props(comp, "ATTENDEE") {
				who := ical.address(ap.value)
				// Only the sender may answer for its own address.
				if who != strings.to_lower(item.sender) {
					continue
				}
				ps := ical.param(ap, "PARTSTAT")
				for sc in sched_comps(stored) {
					if rid_key(sc) != rid && !(rid != "" && rid_key(sc) == "") {
						continue
					}
					for &p in sc.props {
						if p.name == "ATTENDEE" && ical.address(p.value) == who {
							ical.set_param(&p, "PARTSTAT", ps)
							ical.set_param(&p, "SCHEDULE-STATUS", "2.0")
							changed = true
						}
					}
				}
			}
		}
		if changed {
			put_calendar_text(c, col, existing.name, "", false, ical.write(stored))
		}
	}
}

// ---------------------------------------------------------------------------
// The outbox: free/busy lookups (RFC 6638 5)
// ---------------------------------------------------------------------------

do_post :: proc(c: ^Ctx, r: ^Res) {
	if r.kind != .Outbox {
		fail(c, 405, "POST goes to a scheduling outbox")
		return
	}
	cal, _, ok := ical.parse_one(c.req.body)
	if !ok {
		precondition(c, 400, x.NS_CALDAV, "valid-calendar-data")
		return
	}
	fb := ical.child(cal, "VFREEBUSY")
	if fb == nil || strings.to_upper(ical.value(cal, "METHOD")) != "REQUEST" {
		// Implicit scheduling: events are sent by storing them, not by POST.
		precondition(c, 403, x.NS_CALDAV, "valid-scheduling-message", "the outbox accepts free/busy requests; invitations are sent by storing the event")
		return
	}
	sp, _ := ical.prop_dt(ical.prop(fb, "DTSTART"))
	ep, _ := ical.prop_dt(ical.prop(fb, "DTEND"))
	s := ical.instant(sp, cal)
	e := ical.instant(ep, cal)
	organizer := ""
	if op := ical.prop(fb, "ORGANIZER"); op != nil {
		organizer = op.value
	}
	w := x.writer_make()
	x.open(&w, x.NS_CALDAV, "schedule-response")
	for ap in ical.props(fb, "ATTENDEE") {
		who := ical.address(ap.value)
		x.open(&w, x.NS_CALDAV, "response")
		x.open(&w, x.NS_CALDAV, "recipient")
		x.leaf(&w, x.NS_DAV, "href", ap.value)
		x.close(&w)
		b := jb_make()
		jb_str(&b, "address", who)
		jb_str(&b, "range_start", ical.iso8601(s))
		jb_str(&b, "range_end", ical.iso8601(e))
		v, de := rpc(c, "dav_freebusy", jb_done(&b))
		local := is_local(c, who)
		if !db_ok(de) || !local {
			x.leaf(&w, x.NS_CALDAV, "request-status", local ? "5.1;Service unavailable" : "3.7;Invalid calendar user")
			x.close(&w)
			continue
		}
		busy := make([dynamic]Busy, 0, 8)
		for row in rows(v) {
			if jbool(row, "transparent") {
				continue
			}
			if body := jstr(row, "body"); body != "" {
				if ocal, _, cok := ical.parse_one(body); cok {
					collect_busy(ocal, s, e, nil, &busy)
				}
				continue
			}
			bs, _ := ical.parse_iso8601(jstr(row, "dtstart"))
			be, _ := ical.parse_iso8601(jstr(row, "dtend"))
			if be > s && bs < e {
				append(&busy, Busy{max(bs, s), min(be, e), "BUSY"})
			}
		}
		x.leaf(&w, x.NS_CALDAV, "request-status", "2.0;Success")
		x.leaf(&w, x.NS_CALDAV, "calendar-data", vfreebusy(organizer, ap.value, s, e, busy[:], "REPLY"))
		x.close(&w)
	}
	c.res.status = 200
	web.set_header(c.res, "Content-Type", "application/xml; charset=utf-8")
	c.res.body = x.finish(&w)
}
