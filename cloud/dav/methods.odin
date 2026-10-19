// GET, PUT, DELETE, MKCALENDAR/MKCOL, PROPPATCH, MOVE.
package main

import "core:fmt"
import "core:strings"
import ical "ical"
import vcard "vcard"
import web "web"
import x "xml"

// ---------------------------------------------------------------------------
// GET / HEAD
// ---------------------------------------------------------------------------

do_get :: proc(c: ^Ctx, r: ^Res) {
	#partial switch r.kind {
	case .Cal_Object, .Card:
		obj, ok := object(c, r.coll, r.obj.name)
		if !ok {
			not_found(c)
			return
		}
		body := obj.body
		ctype := "text/calendar; charset=utf-8"
		if r.kind == .Card {
			ctype = "text/vcard; charset=utf-8"
			// Accept: text/vcard; version=3.0 asks for the other version.
			accept := strings.to_lower(web.header(c.req.headers, "Accept"))
			want := ""
			if strings.contains(accept, "version=3.0") {
				want = "3.0"
			} else if strings.contains(accept, "version=4.0") {
				want = "4.0"
			}
			if want != "" {
				body = address_data(obj.body, nil, want)
			}
		}
		c.res.status = 200
		web.set_header(c.res, "Content-Type", ctype)
		if body == obj.body {
			web.set_header(c.res, "ETag", obj.etag)
		}
		if lm := http_date(obj.updated_at); lm != "" {
			web.set_header(c.res, "Last-Modified", lm)
		}
		c.res.body = body
	case .Inbox_Item:
		c.res.status = 200
		web.set_header(c.res, "Content-Type", "text/calendar; charset=utf-8")
		c.res.body = r.item.body
	case .Calendar:
		// The whole calendar as one iCalendar stream: what a subscription
		// (webcal) client reads, and the export the app offers.
		c.res.status = 200
		web.set_header(c.res, "Content-Type", "text/calendar; charset=utf-8")
		web.set_header(c.res, "Content-Disposition", fmt.tprintf("attachment; filename=\"%s.ics\"", r.coll.slug))
		c.res.body = export_calendar(c, r.coll)
	case .Book:
		c.res.status = 200
		web.set_header(c.res, "Content-Type", "text/vcard; charset=utf-8")
		web.set_header(c.res, "Content-Disposition", fmt.tprintf("attachment; filename=\"%s.vcf\"", r.coll.slug))
		sb := strings.builder_make()
		for o in objects(c, r.coll, true) {
			strings.write_string(&sb, o.body)
			if !strings.has_suffix(o.body, "\n") {
				strings.write_string(&sb, "\r\n")
			}
		}
		c.res.body = strings.to_string(sb)
	case:
		c.res.status = 200
		web.set_header(c.res, "Content-Type", "text/plain; charset=utf-8")
		c.res.body = "Palmframe CalDAV and CardDAV. Point a client at /dav/ or /.well-known/caldav.\n"
	}
}

// export_calendar merges every object's components under one VCALENDAR,
// each VTIMEZONE once.
export_calendar :: proc(c: ^Ctx, col: Coll) -> string {
	out := new(ical.Component)
	out.name = "VCALENDAR"
	append(&out.props, ical.Prop{name = "VERSION", value = "2.0"})
	append(&out.props, ical.Prop{name = "PRODID", value = "-//Palmframe//DAV//EN"})
	append(&out.props, ical.Prop{name = "X-WR-CALNAME", value = ical.escape_text(col.display_name)})
	seen_tz := make(map[string]bool)
	for o in objects(c, col, true) {
		cal, _, ok := ical.parse_one(o.body)
		if !ok {
			continue
		}
		for ch in cal.children {
			if ch.name == "VTIMEZONE" {
				id := ical.text(ch, "TZID")
				if seen_tz[id] {
					continue
				}
				seen_tz[id] = true
			}
			append(&out.children, ch)
		}
	}
	return ical.write(out)
}

// ---------------------------------------------------------------------------
// PUT
// ---------------------------------------------------------------------------

preconditions :: proc(c: ^Ctx) -> (if_match: string, if_none_match: bool) {
	im := strings.trim_space(web.header(c.req.headers, "If-Match"))
	inm := strings.trim_space(web.header(c.req.headers, "If-None-Match"))
	if strings.has_prefix(im, "W/") {
		im = im[2:]
	}
	return im, inm == "*"
}

do_put :: proc(c: ^Ctx, r: ^Res) {
	if r.kind != .Cal_Object && r.kind != .Card {
		fail(c, 405, "PUT goes to a resource inside a calendar or an address book")
		return
	}
	if r.coll.access == "read" {
		fail(c, 403, "this calendar is shared with you read-only")
		return
	}
	if_match, if_none := preconditions(c)
	if r.kind == .Card {
		put_card(c, r, if_match, if_none)
		return
	}
	cal, perr, ok := ical.parse_one(c.req.body)
	if !ok {
		precondition(c, 400, x.NS_CALDAV, "valid-calendar-data", perr.message)
		return
	}
	if ce := ical.check(cal); ce != .None {
		precondition(c, 403, x.NS_CALDAV, "valid-calendar-object-resource", ical.check_error_text(ce))
		return
	}
	kind := ical.main_kind(cal)
	supported := false
	for comp in r.coll.components {
		if comp == kind {
			supported = true
		}
	}
	if !supported {
		precondition(c, 403, x.NS_CALDAV, "supported-calendar-component", kind)
		return
	}
	// RFC 4791 4.1: a stored resource carries no METHOD.
	modified := false
	if ical.prop(cal, "METHOD") != nil {
		ical.remove_props(cal, "METHOD")
		modified = true
	}

	// Scheduling sees the old and new versions; it may stamp the new one
	// (SCHEDULE-STATUS on attendees), which counts as a modification.
	old, had_old := object(c, r.coll, r.obj.name)
	plan := sched_plan(c, r, had_old ? old.body : "", cal)
	if plan.modified {
		modified = true
	}
	text := modified ? ical.write(cal) : c.req.body

	z, _ := ical.zone_for(r.coll.timezone)
	ix := ical.index(cal, z)
	res := put_object(c, r.coll, r.obj.name, if_match, if_none, cal_index_json(ix), text)
	if res.status != 0 {
		put_failed(c, res, true, r)
		return
	}
	sched_send(c, r, &plan)
	c.res.status = res.created ? 201 : 204
	if !modified {
		// RFC 4791 5.3.4: an ETag only when what is stored is what was sent.
		web.set_header(c.res, "ETag", res.etag)
	}
}

put_failed :: proc(c: ^Ctx, res: Put_Result, calendar: bool, r: ^Res) {
	switch {
	case res.code == "42501":
		fail(c, 403, "this collection is shared with you read-only")
	case res.code == "P0409":
		// P0409: the UID is already used under another name.
		ns := calendar ? x.NS_CALDAV : x.NS_CARDDAV
		w := x.writer_make()
		x.open(&w, x.NS_DAV, "error")
		x.open(&w, ns, "no-uid-conflict")
		x.leaf(&w, x.NS_DAV, "href", obj_href(r.ident, r.coll, res.message))
		x.close(&w)
		c.res.status = 403
		web.set_header(c.res, "Content-Type", "application/xml; charset=utf-8")
		c.res.body = x.finish(&w)
	case:
		fail(c, res.status, res.message != "" ? res.message : "the write was refused")
	}
}

put_card :: proc(c: ^Ctx, r: ^Res, if_match: string, if_none: bool) {
	card, perr, ok := ical.parse_one(c.req.body)
	if !ok {
		precondition(c, 400, x.NS_CARDDAV, "valid-address-data", perr.message)
		return
	}
	if ve := vcard.check(card); ve != .None {
		precondition(c, 403, x.NS_CARDDAV, "valid-address-data", vcard.check_error_text(ve))
		return
	}
	ix := vcard.index(card)
	res := put_object(c, r.coll, r.obj.name, if_match, if_none, card_index_json(ix), c.req.body)
	if res.status != 0 {
		put_failed(c, res, false, r)
		return
	}
	c.res.status = res.created ? 201 : 204
	web.set_header(c.res, "ETag", res.etag)
}

// ---------------------------------------------------------------------------
// DELETE
// ---------------------------------------------------------------------------

do_delete :: proc(c: ^Ctx, r: ^Res) {
	if_match, _ := preconditions(c)
	#partial switch r.kind {
	case .Cal_Object, .Card:
		old, had := object(c, r.coll, r.obj.name)
		found, status := delete_object(c, r.coll, r.obj.name, if_match)
		if status != 0 {
			fail(c, status, status == 412 ? "the resource changed" : "the delete was refused")
			return
		}
		if !found {
			not_found(c)
			return
		}
		if had && r.kind == .Cal_Object {
			sched_on_delete(c, r, old.body)
		}
		c.res.status = 204
	case .Inbox_Item:
		b := jb_make()
		jb_raw(&b, "dismissed_at", "\"now()\"")
		_, e := rest(c, "PATCH", fmt.tprintf("/dav_itip?id=eq.%s", r.item.id), `{"dismissed_at":"now"}`)
		if !db_ok(e) {
			fail(c, http_status_of(e), "could not remove the message")
			return
		}
		c.res.status = 204
	case .Calendar, .Book:
		if r.coll.access != "owner" {
			// Deleting a share from your own home is declining it.
			_, e := rest(c, "DELETE", fmt.tprintf("/dav_grants?collection_id=eq.%s&grantee_identity=eq.%s", r.coll.id, r.ident.id))
			if !db_ok(e) {
				fail(c, http_status_of(e), "could not remove the share")
				return
			}
			c.res.status = 204
			return
		}
		_, e := rest(c, "DELETE", fmt.tprintf("/dav_collections?id=eq.%s", r.coll.id))
		if !db_ok(e) {
			fail(c, http_status_of(e), "could not delete the collection")
			return
		}
		c.res.status = 204
	case:
		fail(c, 403, "this resource cannot be deleted")
	}
}

// ---------------------------------------------------------------------------
// MKCALENDAR, MKCOL (RFC 4791 5.3.1, RFC 5689)
// ---------------------------------------------------------------------------

Coll_Props :: struct {
	display_name: Maybe(string),
	description:  Maybe(string),
	color:        Maybe(string),
	order:        Maybe(string),
	timezone:     Maybe(string),
	components:   [dynamic]string,
	freebusy:     Maybe(bool),
	calendar:     bool, // resourcetype says calendar
	addressbook:  bool,
}

// read_set collects the settable properties inside <set><prop>...
read_set :: proc(prop: ^x.Element, out: ^Coll_Props) -> (unknown: []^x.Element) {
	rest_ := make([dynamic]^x.Element, 0, 2)
	for el in prop.children {
		switch {
		case x.is(el, x.NS_DAV, "displayname"):
			out.display_name = strings.trim_space(el.text)
		case x.is(el, x.NS_CALDAV, "calendar-description"), x.is(el, x.NS_CARDDAV, "addressbook-description"):
			out.description = el.text
		case x.is(el, x.NS_APPLE, "calendar-color"):
			out.color = normalise_color(el.text)
		case x.is(el, x.NS_APPLE, "calendar-order"):
			out.order = strings.trim_space(el.text)
		case x.is(el, x.NS_CALDAV, "calendar-timezone-id"):
			out.timezone = strings.trim_space(el.text)
		case x.is(el, x.NS_CALDAV, "calendar-timezone"):
			// A VCALENDAR with one VTIMEZONE: keep its TZID if IANA knows it.
			if cal, _, ok := ical.parse_one(el.text); ok {
				if tz := ical.child(cal, "VTIMEZONE"); tz != nil {
					if name := ical.iana_name(ical.text(tz, "TZID")); name != "" {
						out.timezone = name
					}
				}
			}
		case x.is(el, x.NS_CALDAV, "supported-calendar-component-set"):
			for comp in el.children {
				if x.is(comp, x.NS_CALDAV, "comp") {
					append(&out.components, strings.to_upper(x.attr(comp, "name")))
				}
			}
		case x.is(el, x.NS_PALM, "public-freebusy"):
			out.freebusy = strings.trim_space(el.text) == "true"
		case x.is(el, x.NS_DAV, "resourcetype"):
			for t in el.children {
				if x.is(t, x.NS_CALDAV, "calendar") {
					out.calendar = true
				}
				if x.is(t, x.NS_CARDDAV, "addressbook") {
					out.addressbook = true
				}
			}
		case:
			append(&rest_, el)
		}
	}
	return rest_[:]
}

normalise_color :: proc(s: string) -> string {
	v := strings.trim_space(s)
	if len(v) == 7 || len(v) == 9 {
		if v[0] == '#' {
			return v
		}
	}
	return "#2563eb"
}

do_mkcol :: proc(c: ^Ctx, r: ^Res, exists: bool) {
	if exists {
		fail(c, 405, "a resource already exists here")
		return
	}
	if r.ident == nil || r.coll.seg == "" || strings.contains(r.coll.seg, "~") {
		fail(c, 403, "collections are made directly under a calendar or address book home")
		return
	}
	props := Coll_Props{}
	if strings.trim_space(c.req.body) != "" {
		root, err := x.parse(c.req.body)
		if err != "" {
			fail(c, 400, err)
			return
		}
		for set in x.find_all(root, x.NS_DAV, "set") {
			if prop := x.find(set, x.NS_DAV, "prop"); prop != nil {
				_ = read_set(prop, &props)
			}
		}
	}
	kind := r.coll.kind
	if c.req.method == "MKCALENDAR" {
		if kind != "calendar" {
			fail(c, 403, "MKCALENDAR goes under a calendar home")
			return
		}
	} else {
		// Extended MKCOL must say what it is making.
		if props.addressbook && kind == "addressbook" {
		} else if props.calendar && kind == "calendar" {
		} else {
			fail(c, 403, "MKCOL here needs a resourcetype of calendar or addressbook")
			return
		}
	}
	b := jb_make()
	jb_str(&b, "identity_id", r.ident.id)
	jb_str(&b, "kind", kind)
	jb_str(&b, "slug", r.coll.seg)
	name, has_name := props.display_name.?
	jb_str(&b, "display_name", has_name ? name : r.coll.seg)
	if d, ok := props.description.?; ok {
		jb_str(&b, "description", d)
	}
	if col, ok := props.color.?; ok {
		jb_str(&b, "color", col)
	}
	if tz, ok := props.timezone.?; ok {
		jb_str(&b, "timezone", tz)
	}
	if len(props.components) > 0 {
		jb_strs(&b, "components", props.components[:])
	}
	_, e := rest(c, "POST", "/dav_collections", jb_done(&b))
	if !db_ok(e) {
		fail(c, http_status_of(e), e.message)
		return
	}
	c.res.status = 201
}

// ---------------------------------------------------------------------------
// PROPPATCH
// ---------------------------------------------------------------------------

do_proppatch :: proc(c: ^Ctx, r: ^Res) {
	root, err := x.parse(c.req.body)
	if err != "" || !x.is(root, x.NS_DAV, "propertyupdate") {
		fail(c, 400, "the body is not a DAV:propertyupdate")
		return
	}
	props := Coll_Props{}
	touched := make([dynamic]^x.Element, 0, 4)
	for op in root.children {
		prop := x.find(op, x.NS_DAV, "prop")
		if prop == nil {
			continue
		}
		for el in prop.children {
			append(&touched, el)
		}
		if x.is(op, x.NS_DAV, "set") {
			_ = read_set(prop, &props)
		}
	}
	status := "HTTP/1.1 200 OK"
	if r.kind == .Calendar || r.kind == .Book {
		if r.coll.access != "owner" {
			status = "HTTP/1.1 403 Forbidden"
		} else {
			b := jb_make()
			any_ := false
			if v, ok := props.display_name.?; ok {
				jb_str(&b, "display_name", v)
				any_ = true
			}
			if v, ok := props.description.?; ok {
				jb_str(&b, "description", v)
				any_ = true
			}
			if v, ok := props.color.?; ok {
				jb_str(&b, "color", v)
				any_ = true
			}
			if v, ok := props.order.?; ok {
				n := 0
				for ch in transmute([]u8)v {
					if ch >= '0' && ch <= '9' {
						n = n * 10 + int(ch - '0')
					}
				}
				jb_int(&b, "sort_order", i64(n))
				any_ = true
			}
			if v, ok := props.timezone.?; ok {
				jb_str(&b, "timezone", v)
				any_ = true
			}
			if v, ok := props.freebusy.?; ok {
				jb_bool(&b, "public_freebusy", v)
				any_ = true
			}
			if any_ {
				_, e := rest(c, "PATCH", fmt.tprintf("/dav_collections?id=eq.%s", r.coll.id), jb_done(&b))
				if !db_ok(e) {
					status = fmt.tprintf("HTTP/1.1 %d %s", http_status_of(e), web.status_text(http_status_of(e)))
				}
			}
		}
	}
	// Properties this server does not keep (dead properties a client sets
	// for its own bookkeeping) are acknowledged and not stored; see the
	// protocol table in cloud/docs/calendar-contacts.md.
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	x.open(&w, x.NS_DAV, "response")
	x.leaf(&w, x.NS_DAV, "href", r.href)
	x.open(&w, x.NS_DAV, "propstat")
	x.open(&w, x.NS_DAV, "prop")
	for el in touched {
		x.empty(&w, el.ns, el.name)
	}
	x.close(&w)
	x.leaf(&w, x.NS_DAV, "status", status)
	multistatus(c, &w)
}

// ---------------------------------------------------------------------------
// MOVE: an event dragged from one calendar to another
// ---------------------------------------------------------------------------

do_move :: proc(c: ^Ctx, r: ^Res) {
	if r.kind != .Cal_Object && r.kind != .Card {
		fail(c, 403, "only calendar objects and cards move")
		return
	}
	dest := web.header(c.req.headers, "Destination")
	if u, ok := web.parse_url(dest); ok {
		dest = u.path
	}
	dest = web.percent_decode(dest)
	d, found := route(c, dest)
	if found {
		if strings.to_upper(web.header(c.req.headers, "Overwrite")) == "F" {
			fail(c, 412, "the destination exists")
			return
		}
	}
	if d.kind != r.kind && !(d.kind == .None && d.coll.seg != "") {
		fail(c, 409, "the destination is not inside a collection of the same kind")
		return
	}
	if d.kind == .None {
		fail(c, 409, "the destination collection does not exist")
		return
	}
	old, ok := object(c, r.coll, r.obj.name)
	if !ok {
		not_found(c)
		return
	}
	var_res: Put_Result
	if r.kind == .Cal_Object {
		var_res = put_calendar_text(c, d.coll, d.obj.name, "", false, old.body)
	} else {
		card, _, _ := ical.parse_one(old.body)
		var_res = put_object(c, d.coll, d.obj.name, "", false, card_index_json(vcard.index(card)), old.body)
	}
	if var_res.status != 0 {
		put_failed(c, var_res, r.kind == .Cal_Object, &d)
		return
	}
	if _, status := delete_object(c, r.coll, r.obj.name, ""); status != 0 {
		fail(c, status, "copied, but the original could not be removed")
		return
	}
	c.res.status = found ? 204 : 201
}

// ---------------------------------------------------------------------------
// Data selection: calendar-data (with CALDAV:expand) and address-data
// ---------------------------------------------------------------------------

calendar_data :: proc(c: ^Ctx, r: ^Res, el: ^x.Element) -> string {
	body := r.obj.body
	if body == "" {
		if o, ok := object(c, r.coll, r.obj.name); ok {
			body = o.body
		}
	}
	if el == nil {
		return body
	}
	exp := x.find(el, x.NS_CALDAV, "expand")
	if exp == nil {
		return body
	}
	s, sok := parse_utc(x.attr(exp, "start"))
	e, eok := parse_utc(x.attr(exp, "end"))
	if !sok || !eok {
		return body
	}
	cal, _, ok := ical.parse_one(body)
	if !ok {
		return body
	}
	z, _ := ical.zone_for(r.coll.timezone)
	return ical.write(expanded(cal, s, e, z))
}

// expanded rewrites a recurring object as its instances in [s, e), each a
// standalone component in UTC with a RECURRENCE-ID (RFC 4791 9.6.5).
expanded :: proc(cal: ^ical.Component, s, e: i64, floating: ^ical.Zone) -> ^ical.Component {
	out := new(ical.Component)
	out.name = "VCALENDAR"
	for p in cal.props {
		append(&out.props, p)
	}
	kind := ical.main_kind(cal)
	insts, _ := ical.expand(cal, kind, s, e, {floating = floating})
	for inst in insts {
		comp := ical.clone(inst.comp)
		for name in ([]string{"RRULE", "RDATE", "EXDATE", "RECURRENCE-ID", "DTSTART", "DTEND", "DURATION"}) {
			ical.remove_props(comp, name)
		}
		all_day := false
		if sp := ical.prop(inst.comp, "DTSTART"); sp != nil {
			if t, ok := ical.prop_dt(sp); ok {
				all_day = t.is_date
			}
		}
		if all_day {
			sd := ical.utc_dt(inst.start + 14 * 3600)
			sd.is_date = true
			ed := ical.utc_dt(inst.end + 14 * 3600)
			ed.is_date = true
			start_d := inst.rid
			start_d.is_date = true
			append(&comp.props, ical.Prop{name = "DTSTART", value = ical.format_dt(start_d), params = date_param()})
			end_days := (inst.end - inst.start + 3600) / 86400
			end_dt := ical.dt_from_local(ical.local_secs(start_d) + end_days * 86400, start_d)
			append(&comp.props, ical.Prop{name = "DTEND", value = ical.format_dt(end_dt), params = date_param()})
			if inst.recurring {
				append(&comp.props, ical.Prop{name = "RECURRENCE-ID", value = ical.format_dt(start_d), params = date_param()})
			}
		} else {
			append(&comp.props, ical.Prop{name = "DTSTART", value = ical.format_dt(ical.utc_dt(inst.start))})
			append(&comp.props, ical.Prop{name = "DTEND", value = ical.format_dt(ical.utc_dt(inst.end))})
			if inst.recurring {
				append(&comp.props, ical.Prop{name = "RECURRENCE-ID", value = ical.format_dt(ical.utc_dt(inst.rid_utc))})
			}
		}
		append(&out.children, comp)
	}
	return out
}

date_param :: proc() -> []ical.Param {
	v := make([]string, 1)
	v[0] = "DATE"
	ps := make([]ical.Param, 1)
	ps[0] = ical.Param{name = "VALUE", values = v}
	return ps
}

// parse_utc reads a CalDAV time-range attribute (20261019T000000Z).
parse_utc :: proc(s: string) -> (i64, bool) {
	if s == "" {
		return 0, false
	}
	t, ok := ical.parse_dt(s)
	if !ok {
		return 0, false
	}
	return ical.local_secs(t), true
}

address_data :: proc(body: string, el: ^x.Element, force_version := "") -> string {
	version := force_version
	if el != nil && version == "" {
		version = x.attr(el, "version")
	}
	if version != "3.0" && version != "4.0" {
		return body
	}
	card, _, ok := ical.parse_one(body)
	if !ok || strings.trim_space(ical.value(card, "VERSION")) == version {
		return body
	}
	return ical.write(vcard.convert(card, version))
}
