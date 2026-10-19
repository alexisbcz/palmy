// REPORT: calendar-query, calendar-multiget, free-busy-query,
// addressbook-query, addressbook-multiget, sync-collection, and the two
// principal reports clients probe.
package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import ical "ical"
import vcard "vcard"
import web "web"
import x "xml"

do_report :: proc(c: ^Ctx, r: ^Res) {
	root, err := x.parse(c.req.body)
	if err != "" {
		fail(c, 400, err)
		return
	}
	switch {
	case x.is(root, x.NS_CALDAV, "calendar-multiget"), x.is(root, x.NS_CARDDAV, "addressbook-multiget"):
		report_multiget(c, r, root)
	case x.is(root, x.NS_CALDAV, "calendar-query"):
		report_calendar_query(c, r, root)
	case x.is(root, x.NS_CARDDAV, "addressbook-query"):
		report_addressbook_query(c, r, root)
	case x.is(root, x.NS_DAV, "sync-collection"):
		report_sync(c, r, root)
	case x.is(root, x.NS_CALDAV, "free-busy-query"):
		report_freebusy(c, r, root)
	case x.is(root, x.NS_DAV, "principal-search-property-set"):
		w := x.writer_make()
		x.open(&w, x.NS_DAV, "principal-search-property-set")
		c.res.status = 200
		web.set_header(c.res, "Content-Type", "application/xml; charset=utf-8")
		c.res.body = x.finish(&w)
	case x.is(root, x.NS_DAV, "principal-property-search"), x.is(root, x.NS_DAV, "expand-property"):
		// Directory search is not offered: an identity is not a way to list
		// other people. An empty result is the honest answer.
		w := x.writer_make()
		x.open(&w, x.NS_DAV, "multistatus")
		multistatus(c, &w)
	case:
		precondition(c, 403, x.NS_DAV, "supported-report")
	}
}

@(private = "file")
requested_props :: proc(root: ^x.Element) -> []Prop_Name {
	out := make([dynamic]Prop_Name, 0, 4)
	if prop := x.find(root, x.NS_DAV, "prop"); prop != nil {
		for el in prop.children {
			append(&out, Prop_Name{el.ns, el.name, el})
		}
	} else {
		append(&out, Prop_Name{x.NS_DAV, "getetag", nil})
	}
	return out[:]
}

// href_name extracts the object name from an href inside this collection.
@(private = "file")
href_name :: proc(r: ^Res, href: string) -> (string, bool) {
	h := strings.trim_space(href)
	if u, ok := web.parse_url(h); ok {
		h = u.path
	}
	h = web.percent_decode(h)
	base := web.percent_decode(r.href)
	if !strings.has_prefix(h, base) {
		return "", false
	}
	name := h[len(base):]
	if name == "" || strings.contains(name, "/") {
		return "", false
	}
	return name, true
}

report_multiget :: proc(c: ^Ctx, r: ^Res, root: ^x.Element) {
	if r.kind != .Calendar && r.kind != .Book && r.kind != .Inbox {
		fail(c, 403, "multiget is a report on a collection")
		return
	}
	names := requested_props(root)
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	if r.kind == .Inbox {
		items := inbox_items(c, r.ident)
		for h in x.find_all(root, x.NS_DAV, "href") {
			found := false
			for item in items {
				if strings.has_suffix(web.percent_decode(h.text), strings.concatenate({item.id, ".ics"})) {
					res := Res{kind = .Inbox_Item, ident = r.ident, item = item, href = strings.trim_space(h.text)}
					describe(c, &w, &res, names)
					found = true
				}
			}
			if !found {
				missing(&w, h.text)
			}
		}
		multistatus(c, &w)
		return
	}
	wanted := make([dynamic]string, 0, 16)
	href_of := make(map[string]string)
	for h in x.find_all(root, x.NS_DAV, "href") {
		if name, ok := href_name(r, h.text); ok {
			append(&wanted, name)
			href_of[name] = strings.trim_space(h.text)
		} else {
			missing(&w, h.text)
		}
	}
	k := r.kind == .Calendar ? Kind.Cal_Object : Kind.Card
	got := make(map[string]bool)
	// Chunks of 100 keep the PostgREST URL short.
	for i := 0; i < len(wanted); i += 100 {
		part := wanted[i:min(i + 100, len(wanted))]
		for o in objects_named(c, r.coll, part, true) {
			res := Res{kind = k, ident = r.ident, coll = r.coll, obj = o, href = href_of[o.name]}
			describe(c, &w, &res, names)
			got[o.name] = true
		}
	}
	for name in wanted {
		if !got[name] {
			missing(&w, href_of[name])
		}
	}
	multistatus(c, &w)
}

@(private = "file")
missing :: proc(w: ^x.Writer, href: string) {
	x.open(w, x.NS_DAV, "response")
	x.leaf(w, x.NS_DAV, "href", strings.trim_space(href))
	x.leaf(w, x.NS_DAV, "status", "HTTP/1.1 404 Not Found")
	x.close(w)
}

// ---------------------------------------------------------------------------
// calendar-query (RFC 4791 7.8)
// ---------------------------------------------------------------------------

report_calendar_query :: proc(c: ^Ctx, r: ^Res, root: ^x.Element) {
	if r.kind != .Calendar && r.kind != .Cal_Object {
		fail(c, 403, "calendar-query is a report on a calendar")
		return
	}
	filter := x.find(root, x.NS_CALDAV, "filter")
	if filter == nil {
		precondition(c, 403, x.NS_CALDAV, "valid-filter")
		return
	}
	floating, _ := ical.zone_for(r.coll.timezone)
	if tzel := x.find(root, x.NS_CALDAV, "timezone"); tzel != nil {
		if cal, _, ok := ical.parse_one(tzel.text); ok {
			if tz := ical.child(cal, "VTIMEZONE"); tz != nil {
				floating, _ = ical.zone_for(ical.text(tz, "TZID"), cal)
			}
		}
	}

	// A prefilter in SQL from the outermost time-range on VEVENT/VTODO.
	sql := ""
	if vc := x.find(filter, x.NS_CALDAV, "comp-filter"); vc != nil {
		if inner := x.find(vc, x.NS_CALDAV, "comp-filter"); inner != nil {
			name := strings.to_upper(x.attr(inner, "name"))
			if name == "VEVENT" || name == "VTODO" || name == "VJOURNAL" {
				if x.find(inner, x.NS_CALDAV, "is-not-defined") == nil {
					sql = fmt.tprintf("&component=eq.%s", name)
				}
				if tr := x.find(inner, x.NS_CALDAV, "time-range"); tr != nil {
					if s, ok := parse_utc(x.attr(tr, "start")); ok {
						sql = fmt.tprintf("%s&or=(last_end.is.null,last_end.gt.%s)", sql, web.query_encode(ical.iso8601(s - 14 * 3600)))
					}
					if e, ok := parse_utc(x.attr(tr, "end")); ok {
						sql = fmt.tprintf("%s&first_start=lt.%s", sql, web.query_encode(ical.iso8601(e + 14 * 3600)))
					}
				}
			}
		}
	}
	names := requested_props(root)
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	list: []Obj
	if r.kind == .Cal_Object {
		if o, ok := object(c, r.coll, r.obj.name); ok {
			list = {o}
		}
	} else {
		list = objects(c, r.coll, true, sql)
	}
	for o in list {
		cal, _, ok := ical.parse_one(o.body)
		if !ok {
			continue
		}
		if !comp_matches(cal, x.find(filter, x.NS_CALDAV, "comp-filter"), cal, floating) {
			continue
		}
		res := Res{kind = .Cal_Object, ident = r.ident, coll = r.coll, obj = o, href = obj_href(r.ident, r.coll, o.name)}
		describe(c, &w, &res, names)
	}
	multistatus(c, &w)
}

// comp_matches evaluates a comp-filter against a component (RFC 4791 9.7.1).
comp_matches :: proc(comp: ^ical.Component, f: ^x.Element, cal: ^ical.Component, floating: ^ical.Zone) -> bool {
	if f == nil {
		return true
	}
	name := strings.to_upper(x.attr(f, "name"))
	if comp.name != name {
		return false
	}
	return comp_body_matches(comp, f, cal, floating)
}

@(private = "file")
comp_body_matches :: proc(comp: ^ical.Component, f: ^x.Element, cal: ^ical.Component, floating: ^ical.Zone) -> bool {
	for el in f.children {
		switch {
		case x.is(el, x.NS_CALDAV, "time-range"):
			s, sok := parse_utc(x.attr(el, "start"))
			e, eok := parse_utc(x.attr(el, "end"))
			if !sok {
				s = min(i64)
			}
			if !eok {
				e = max(i64)
			}
			if !component_in_range(comp, cal, s, e, floating) {
				return false
			}
		case x.is(el, x.NS_CALDAV, "comp-filter"):
			want := strings.to_upper(x.attr(el, "name"))
			undefined := x.find(el, x.NS_CALDAV, "is-not-defined") != nil
			any_ := false
			for ch in comp.children {
				if ch.name == want && (undefined || comp_body_matches(ch, el, cal, floating)) {
					any_ = true
					break
				}
			}
			if undefined {
				if any_ {
					return false
				}
			} else if !any_ {
				// For VCALENDAR > VEVENT, any one matching VEVENT (master or
				// override) is enough.
				return false
			}
		case x.is(el, x.NS_CALDAV, "prop-filter"):
			if !prop_filter(comp, el, cal, floating) {
				return false
			}
		}
	}
	return true
}

// component_in_range: a VEVENT/VTODO overlaps when any instance of the
// object does. Overrides are tested through the recurrence set of the
// whole object, which is what clients mean.
@(private = "file")
component_in_range :: proc(comp: ^ical.Component, cal: ^ical.Component, s, e: i64, floating: ^ical.Zone) -> bool {
	switch comp.name {
	case "VEVENT", "VTODO", "VJOURNAL":
		insts, _ := ical.expand(cal, comp.name, s, e, {floating = floating, limit = 1})
		return len(insts) > 0
	case "VALARM":
		return true
	}
	return true
}

@(private = "file")
prop_filter :: proc(comp: ^ical.Component, f: ^x.Element, cal: ^ical.Component, floating: ^ical.Zone) -> bool {
	name := strings.to_upper(x.attr(f, "name"))
	ps := ical.props(comp, name)
	if x.find(f, x.NS_CALDAV, "is-not-defined") != nil {
		return len(ps) == 0
	}
	if len(ps) == 0 {
		return false
	}
	tm := x.find(f, x.NS_CALDAV, "text-match")
	tr := x.find(f, x.NS_CALDAV, "time-range")
	for p in ps {
		ok := true
		if tm != nil {
			ok = text_match(ical.unescape_text(p.value), tm, "contains")
		}
		if ok && tr != nil {
			t, tok := ical.prop_dt(p)
			if !tok {
				ok = false
			} else {
				at := ical.instant(t, cal, floating)
				s, sok := parse_utc(x.attr(tr, "start"))
				e, eok := parse_utc(x.attr(tr, "end"))
				ok = (!sok || at >= s) && (!eok || at < e)
			}
		}
		if ok {
			for pf in x.find_all(f, x.NS_CALDAV, "param-filter") {
				pv := ical.param(p, strings.to_upper(x.attr(pf, "name")))
				if x.find(pf, x.NS_CALDAV, "is-not-defined") != nil {
					if pv != "" {
						ok = false
					}
				} else if ptm := x.find(pf, x.NS_CALDAV, "text-match"); ptm != nil {
					if !text_match(pv, ptm, "contains") {
						ok = false
					}
				} else if pv == "" {
					ok = false
				}
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// text_match: i;ascii-casemap or i;unicode-casemap (case-insensitive) by
// default, i;octet exact; CardDAV adds match-type.
text_match :: proc(value: string, tm: ^x.Element, default_type: string) -> bool {
	needle := tm.text
	collation := x.attr(tm, "collation")
	hay := value
	if collation != "i;octet" {
		needle = strings.to_lower(needle)
		hay = strings.to_lower(hay)
	}
	mt := x.attr(tm, "match-type")
	if mt == "" {
		mt = default_type
	}
	hit := false
	switch mt {
	case "equals":
		hit = hay == needle
	case "starts-with":
		hit = strings.has_prefix(hay, needle)
	case "ends-with":
		hit = strings.has_suffix(hay, needle)
	case:
		hit = strings.contains(hay, needle)
	}
	if x.attr(tm, "negate-condition") == "yes" {
		return !hit
	}
	return hit
}

// ---------------------------------------------------------------------------
// addressbook-query (RFC 6352 8.6)
// ---------------------------------------------------------------------------

report_addressbook_query :: proc(c: ^Ctx, r: ^Res, root: ^x.Element) {
	if r.kind != .Book {
		fail(c, 403, "addressbook-query is a report on an address book")
		return
	}
	filter := x.find(root, x.NS_CARDDAV, "filter")
	limit := max(int)
	if lim := x.find(root, x.NS_CARDDAV, "limit"); lim != nil {
		if n := x.find(lim, x.NS_CARDDAV, "nresults"); n != nil {
			if v, ok := strconv.parse_int(strings.trim_space(n.text)); ok && v > 0 {
				limit = v
			}
		}
	}
	names := requested_props(root)
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	count := 0
	truncated := false
	for o in objects(c, r.coll, true) {
		card, _, ok := ical.parse_one(o.body)
		if !ok || !card_matches(card, filter) {
			continue
		}
		if count >= limit {
			truncated = true
			break
		}
		res := Res{kind = .Card, ident = r.ident, coll = r.coll, obj = o, href = obj_href(r.ident, r.coll, o.name)}
		describe(c, &w, &res, names)
		count += 1
	}
	if truncated {
		x.open(&w, x.NS_DAV, "response")
		x.leaf(&w, x.NS_DAV, "href", r.href)
		x.leaf(&w, x.NS_DAV, "status", "HTTP/1.1 507 Insufficient Storage")
		x.open(&w, x.NS_DAV, "error")
		x.empty(&w, x.NS_DAV, "number-of-matches-within-limits")
		x.close(&w)
		x.close(&w)
	}
	multistatus(c, &w)
}

card_matches :: proc(card: ^ical.Component, filter: ^x.Element) -> bool {
	if filter == nil {
		return true
	}
	allof := x.attr(filter, "test") == "allof"
	pfs := x.find_all(filter, x.NS_CARDDAV, "prop-filter")
	if len(pfs) == 0 {
		return true
	}
	for pf in pfs {
		hit := card_prop_filter(card, pf)
		if allof && !hit {
			return false
		}
		if !allof && hit {
			return true
		}
	}
	return allof
}

@(private = "file")
card_prop_filter :: proc(card: ^ical.Component, pf: ^x.Element) -> bool {
	name := strings.to_upper(x.attr(pf, "name"))
	ps := ical.props(card, name)
	if x.find(pf, x.NS_CARDDAV, "is-not-defined") != nil {
		return len(ps) == 0
	}
	if len(ps) == 0 {
		return false
	}
	allof := x.attr(pf, "test") == "allof"
	tms := x.find_all(pf, x.NS_CARDDAV, "text-match")
	if len(tms) == 0 {
		return true
	}
	for p in ps {
		v := ical.unescape_text(p.value)
		ok := allof
		for tm in tms {
			hit := text_match(v, tm, "contains")
			if allof && !hit {
				ok = false
				break
			}
			if !allof && hit {
				ok = true
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// sync-collection (RFC 6578)
// ---------------------------------------------------------------------------

report_sync :: proc(c: ^Ctx, r: ^Res, root: ^x.Element) {
	if r.kind != .Calendar && r.kind != .Book {
		precondition(c, 403, x.NS_DAV, "supported-report")
		return
	}
	tok_el := x.find(root, x.NS_DAV, "sync-token")
	tok := tok_el != nil ? strings.trim_space(tok_el.text) : ""
	since := i64(-1)
	if tok != "" {
		rest_ := strings.trim_prefix(tok, SYNC_PREFIX)
		slash := strings.last_index_byte(rest_, '/')
		ok := false
		if strings.has_prefix(tok, SYNC_PREFIX) && slash > 0 && rest_[:slash] == r.coll.id {
			since, ok = strconv.parse_i64(rest_[slash + 1:])
		}
		if !ok {
			precondition(c, 403, x.NS_DAV, "valid-sync-token")
			return
		}
	}
	names := requested_props(root)
	k := r.kind == .Calendar ? Kind.Cal_Object : Kind.Card
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	current := r.coll.sync_seq
	if since < 0 {
		// Initial sync: every member, no tombstones.
		for o in objects(c, r.coll, true) {
			res := Res{kind = k, ident = r.ident, coll = r.coll, obj = o, href = obj_href(r.ident, r.coll, o.name)}
			describe(c, &w, &res, names)
		}
	} else {
		b := jb_make()
		jb_str(&b, "collection", r.coll.id)
		jb_int(&b, "since", since)
		v, e := rpc(c, "dav_sync", jb_done(&b))
		if !db_ok(e) {
			fail(c, http_status_of(e), "could not read the change log")
			return
		}
		changed := make([dynamic]string, 0, 8)
		for row in rows(v) {
			if jbool(row, "invalid") {
				precondition(c, 403, x.NS_DAV, "valid-sync-token")
				return
			}
			current = jint(row, "current")
			name := jstr(row, "name")
			if jbool(row, "deleted") && jnull(row, "etag") {
				missing(&w, obj_href(r.ident, r.coll, name))
			} else {
				append(&changed, name)
			}
		}
		for i := 0; i < len(changed); i += 100 {
			part := changed[i:min(i + 100, len(changed))]
			for o in objects_named(c, r.coll, part, true) {
				res := Res{kind = k, ident = r.ident, coll = r.coll, obj = o, href = obj_href(r.ident, r.coll, o.name)}
				describe(c, &w, &res, names)
			}
		}
	}
	coll := r.coll
	coll.sync_seq = current
	x.leaf(&w, x.NS_DAV, "sync-token", sync_token(coll))
	multistatus(c, &w)
}

// ---------------------------------------------------------------------------
// free-busy-query (RFC 4791 7.10)
// ---------------------------------------------------------------------------

Busy :: struct {
	start, end: i64,
	kind:       string, // BUSY, BUSY-TENTATIVE
}

report_freebusy :: proc(c: ^Ctx, r: ^Res, root: ^x.Element) {
	if r.kind != .Calendar {
		fail(c, 403, "free-busy-query is a report on a calendar")
		return
	}
	tr := x.find(root, x.NS_CALDAV, "time-range")
	s, sok := parse_utc(x.attr(tr, "start"))
	e, eok := parse_utc(x.attr(tr, "end"))
	if tr == nil || !sok || !eok {
		precondition(c, 403, x.NS_CALDAV, "valid-filter", "free-busy-query needs a time-range with start and end")
		return
	}
	floating, _ := ical.zone_for(r.coll.timezone)
	busy := make([dynamic]Busy, 0, 16)
	for o in objects(c, r.coll, true, "&component=eq.VEVENT") {
		cal, _, ok := ical.parse_one(o.body)
		if !ok {
			continue
		}
		collect_busy(cal, s, e, floating, &busy)
	}
	c.res.status = 200
	web.set_header(c.res, "Content-Type", "text/calendar; charset=utf-8")
	c.res.body = vfreebusy("", "", s, e, busy[:], "")
}

// collect_busy adds an object's opaque, non-cancelled instances.
collect_busy :: proc(cal: ^ical.Component, s, e: i64, floating: ^ical.Zone, out: ^[dynamic]Busy) {
	insts, _ := ical.expand(cal, "VEVENT", s, e, {floating = floating})
	for inst in insts {
		if strings.equal_fold(ical.value(inst.comp, "TRANSP"), "TRANSPARENT") {
			continue
		}
		status := strings.to_upper(ical.value(inst.comp, "STATUS"))
		if status == "CANCELLED" {
			continue
		}
		append(out, Busy{max(inst.start, s), min(inst.end, e), status == "TENTATIVE" ? "BUSY-TENTATIVE" : "BUSY"})
	}
}

vfreebusy :: proc(organizer, attendee: string, s, e: i64, busy: []Busy, method: string) -> string {
	slice.sort_by(busy, proc(a, b: Busy) -> bool {return a.start < b.start})
	sb := strings.builder_make()
	strings.write_string(&sb, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Palmy//DAV//EN\r\n")
	if method != "" {
		fmt.sbprintf(&sb, "METHOD:%s\r\n", method)
	}
	strings.write_string(&sb, "BEGIN:VFREEBUSY\r\n")
	fmt.sbprintf(&sb, "DTSTAMP:%s\r\n", ical.format_dt(ical.utc_dt(now_unix())))
	fmt.sbprintf(&sb, "DTSTART:%s\r\nDTEND:%s\r\n", ical.format_dt(ical.utc_dt(s)), ical.format_dt(ical.utc_dt(e)))
	if organizer != "" {
		fmt.sbprintf(&sb, "ORGANIZER:%s\r\n", organizer)
	}
	if attendee != "" {
		fmt.sbprintf(&sb, "ATTENDEE:%s\r\n", attendee)
	}
	// Merge overlapping periods of the same kind.
	i := 0
	for i < len(busy) {
		cur := busy[i]
		j := i + 1
		for j < len(busy) && busy[j].start <= cur.end && busy[j].kind == cur.kind {
			cur.end = max(cur.end, busy[j].end)
			j += 1
		}
		if cur.end > cur.start {
			fmt.sbprintf(&sb, "FREEBUSY;FBTYPE=%s:%s/%s\r\n", cur.kind, ical.format_dt(ical.utc_dt(cur.start)), ical.format_dt(ical.utc_dt(cur.end)))
		}
		i = j
	}
	strings.write_string(&sb, "END:VFREEBUSY\r\nEND:VCALENDAR\r\n")
	return strings.to_string(sb)
}

_ :: vcard
