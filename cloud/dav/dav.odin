// Routing, OPTIONS, PROPFIND, and every live property the server knows.
package main

import "core:fmt"
import "core:strings"
import ical "ical"
import web "web"
import x "xml"

Kind :: enum u8 {
	None,
	Root,
	Principals,
	Principal,
	Cal_Home,
	Calendar,
	Cal_Object,
	Inbox,
	Inbox_Item,
	Outbox,
	Book_Home,
	Book,
	Card,
}

// Res is one resource the request names or a listing contains.
Res :: struct {
	kind:  Kind,
	ident: ^Ident, // the identity in the URL
	coll:  Coll,
	obj:   Obj,
	item:  Itip,
	href:  string,
}

Itip :: struct {
	id:         string,
	method:     string,
	uid:        string,
	body:       string,
	sender:     string,
	created_at: string,
}

DAV_HEADER :: "1, 3, access-control, calendar-access, addressbook, extended-mkcol, calendar-auto-schedule, calendar-no-timezone"
ALLOW :: "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR, MOVE, POST"

home_href :: proc(kind: Kind, i: ^Ident) -> string {
	if kind == .Book_Home || kind == .Book || kind == .Card {
		return strings.concatenate({"/dav/addressbooks/", web.percent_encode(i.handle), "/"})
	}
	return strings.concatenate({"/dav/calendars/", web.percent_encode(i.handle), "/"})
}

principal_href :: proc(i: ^Ident) -> string {
	return strings.concatenate({"/dav/principals/", web.percent_encode(i.handle), "/"})
}

coll_href :: proc(i: ^Ident, col: Coll) -> string {
	k := col.kind == "addressbook" ? Kind.Book : Kind.Calendar
	return strings.concatenate({home_href(k, i), web.percent_encode(col.seg), "/"})
}

obj_href :: proc(i: ^Ident, col: Coll, name: string) -> string {
	return strings.concatenate({coll_href(i, col), web.percent_encode(name)})
}

// route resolves a request path. Collection lookups go to the database.
route :: proc(c: ^Ctx, path: string) -> (r: Res, found: bool) {
	p := path
	if p == "/" || p == "" || p == "/dav" || p == "/dav/" {
		return Res{kind = .Root, href = "/dav/"}, true
	}
	if !strings.has_prefix(p, "/dav/") {
		return {}, false
	}
	trimmed := strings.trim_right(p[len("/dav/"):], "/")
	segs := strings.split(trimmed, "/")
	if len(segs) == 0 {
		return {}, false
	}
	top := segs[0]
	if top == "principals" {
		if len(segs) == 1 {
			return Res{kind = .Principals, href = "/dav/principals/"}, true
		}
		i := ident_by_handle(c, segs[1])
		if i == nil || len(segs) > 2 {
			return {}, false
		}
		return Res{kind = .Principal, ident = i, href = principal_href(i)}, true
	}
	if top != "calendars" && top != "addressbooks" {
		return {}, false
	}
	cal := top == "calendars"
	if len(segs) < 2 {
		return {}, false
	}
	i := ident_by_handle(c, segs[1])
	if i == nil {
		return {}, false
	}
	ensure_defaults(c, i)
	if len(segs) == 2 {
		k := cal ? Kind.Cal_Home : Kind.Book_Home
		return Res{kind = k, ident = i, href = home_href(k, i)}, true
	}
	if cal && segs[2] == "inbox" {
		if len(segs) == 3 {
			return Res{kind = .Inbox, ident = i, href = strings.concatenate({home_href(.Cal_Home, i), "inbox/"})}, true
		}
		if len(segs) == 4 {
			id := strings.trim_suffix(segs[3], ".ics")
			item, ok := inbox_item(c, i, id)
			if !ok {
				return {}, false
			}
			return Res{kind = .Inbox_Item, ident = i, item = item, href = strings.concatenate({home_href(.Cal_Home, i), "inbox/", segs[3]})}, true
		}
		return {}, false
	}
	if cal && segs[2] == "outbox" && len(segs) == 3 {
		return Res{kind = .Outbox, ident = i, href = strings.concatenate({home_href(.Cal_Home, i), "outbox/"})}, true
	}
	col, ok := find_coll(c, i, cal ? "calendar" : "addressbook", segs[2])
	if !ok {
		// Not found, but the caller may be creating it (MKCALENDAR, MKCOL):
		// report the parent and segment through r.
		r.kind = .None
		r.ident = i
		r.coll.seg = segs[2]
		r.coll.kind = cal ? "calendar" : "addressbook"
		return r, false
	}
	if len(segs) == 3 {
		k := cal ? Kind.Calendar : Kind.Book
		return Res{kind = k, ident = i, coll = col, href = coll_href(i, col)}, true
	}
	if len(segs) == 4 {
		k := cal ? Kind.Cal_Object : Kind.Card
		r = Res{kind = k, ident = i, coll = col, href = obj_href(i, col, segs[3])}
		r.obj.name = segs[3]
		return r, true
	}
	return {}, false
}

is_collection :: proc(k: Kind) -> bool {
	#partial switch k {
	case .Cal_Object, .Card, .Inbox_Item, .None:
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// The request entry point
// ---------------------------------------------------------------------------

handle :: proc(req: ^web.Request, res: ^web.Response) {
	p := req.path
	if strings.has_prefix(p, "/.well-known/caldav") || strings.has_prefix(p, "/.well-known/carddav") {
		res.status = 301
		web.set_header(res, "Location", "/dav/")
		return
	}
	if req.method == "OPTIONS" {
		res.status = 200
		web.set_header(res, "DAV", DAV_HEADER)
		web.set_header(res, "Allow", ALLOW)
		return
	}
	c := Ctx{req = req, res = res}
	if !authenticate(&c) {
		return
	}
	load_mail_domain(&c)
	web.set_header(res, "DAV", DAV_HEADER)

	r, found := route(&c, p)
	// Looking at an identity's calendars is when its scheduling messages
	// are applied (see sched.odin).
	if found && r.ident != nil && (req.method == "PROPFIND" || req.method == "REPORT") {
		#partial switch r.kind {
		case .Cal_Home, .Calendar, .Inbox:
			process_inbox(&c, r.ident)
			if r.kind == .Calendar {
				// The collection may have moved on: re-read its sync state.
				if col, ok := find_coll(&c, r.ident, "calendar", r.coll.seg); ok {
					r.coll = col
				}
			}
		}
	}
	switch req.method {
	case "PROPFIND":
		if !found {
			not_found(&c)
			return
		}
		do_propfind(&c, &r)
	case "PROPPATCH":
		if !found {
			not_found(&c)
			return
		}
		do_proppatch(&c, &r)
	case "GET", "HEAD":
		if !found {
			not_found(&c)
			return
		}
		do_get(&c, &r)
	case "PUT":
		if !found {
			not_found(&c)
			return
		}
		do_put(&c, &r)
	case "DELETE":
		if !found {
			not_found(&c)
			return
		}
		do_delete(&c, &r)
	case "MKCALENDAR", "MKCOL":
		do_mkcol(&c, &r, found)
	case "REPORT":
		if !found {
			not_found(&c)
			return
		}
		do_report(&c, &r)
	case "MOVE":
		if !found {
			not_found(&c)
			return
		}
		do_move(&c, &r)
	case "POST":
		if !found {
			not_found(&c)
			return
		}
		do_post(&c, &r)
	case:
		res.status = 405
		web.set_header(res, "Allow", ALLOW)
	}
}

not_found :: proc(c: ^Ctx) {
	c.res.status = 404
	web.set_header(c.res, "Content-Type", "text/plain; charset=utf-8")
	c.res.body = "not found\n"
}

fail :: proc(c: ^Ctx, status: int, message: string) {
	c.res.status = status
	web.set_header(c.res, "Content-Type", "text/plain; charset=utf-8")
	c.res.body = strings.concatenate({message, "\n"})
}

// precondition answers with a DAV:error body naming the failed condition.
precondition :: proc(c: ^Ctx, status: int, ns, name: string, detail := "") {
	w := x.writer_make()
	x.open(&w, x.NS_DAV, "error")
	x.empty(&w, ns, name)
	if detail != "" {
		x.leaf(&w, x.NS_PALM, "detail", detail)
	}
	c.res.status = status
	web.set_header(c.res, "Content-Type", "application/xml; charset=utf-8")
	c.res.body = x.finish(&w)
}

// depth reads the Depth header: 0, 1, or infinity (treated as 1 here, which
// RFC 4918 section 9.1 allows a server to do by refusing infinity; most
// servers answer it as 1 and clients cope).
depth :: proc(c: ^Ctx, def := 1) -> int {
	d := strings.trim_space(web.header(c.req.headers, "Depth"))
	switch d {
	case "0":
		return 0
	case "1", "infinity":
		return 1
	}
	return def
}

// ---------------------------------------------------------------------------
// PROPFIND
// ---------------------------------------------------------------------------

Prop_Name :: struct {
	ns, name: string,
	el:       ^x.Element, // the request element (calendar-data may carry options)
}

// The set returned for <allprop/> (and an empty body): the common live
// properties, not the expensive ones.
ALLPROP := [?][2]string {
	{x.NS_DAV, "resourcetype"},
	{x.NS_DAV, "displayname"},
	{x.NS_DAV, "getetag"},
	{x.NS_DAV, "getcontenttype"},
	{x.NS_DAV, "getcontentlength"},
	{x.NS_DAV, "getlastmodified"},
	{x.NS_DAV, "current-user-principal"},
	{x.NS_CS, "getctag"},
	{x.NS_DAV, "sync-token"},
}

do_propfind :: proc(c: ^Ctx, r: ^Res) {
	names := make([dynamic]Prop_Name, 0, 16)
	propname := false
	if strings.trim_space(c.req.body) == "" {
		for p in ALLPROP {
			append(&names, Prop_Name{p[0], p[1], nil})
		}
	} else {
		root, err := x.parse(c.req.body)
		if err != "" || !x.is(root, x.NS_DAV, "propfind") {
			fail(c, 400, "the body is not a DAV:propfind")
			return
		}
		if prop := x.find(root, x.NS_DAV, "prop"); prop != nil {
			for el in prop.children {
				append(&names, Prop_Name{el.ns, el.name, el})
			}
		} else if x.find(root, x.NS_DAV, "propname") != nil {
			propname = true
			for p in ALLPROP {
				append(&names, Prop_Name{p[0], p[1], nil})
			}
		} else {
			for p in ALLPROP {
				append(&names, Prop_Name{p[0], p[1], nil})
			}
		}
	}

	if r.kind == .Cal_Object || r.kind == .Card {
		obj, ok := object(c, r.coll, r.obj.name, false)
		if !ok {
			not_found(c)
			return
		}
		r.obj = obj
	}

	w := x.writer_make()
	x.open(&w, x.NS_DAV, "multistatus")
	describe(c, &w, r, names[:], propname)
	if depth(c, 1) == 1 {
		for &child in children(c, r, false) {
			describe(c, &w, &child, names[:], propname)
		}
	}
	multistatus(c, &w)
}

multistatus :: proc(c: ^Ctx, w: ^x.Writer) {
	c.res.status = 207
	web.set_header(c.res, "Content-Type", "application/xml; charset=utf-8")
	c.res.body = x.finish(w)
}

// children lists a collection's members.
children :: proc(c: ^Ctx, r: ^Res, with_body: bool) -> []Res {
	out := make([dynamic]Res, 0, 8)
	#partial switch r.kind {
	case .Root:
		p := primary(c)
		append(&out, Res{kind = .Principals, href = "/dav/principals/"})
		_ = p
	case .Principals:
		for &i in c.idents {
			append(&out, Res{kind = .Principal, ident = &i, href = principal_href(&i)})
		}
	case .Cal_Home:
		for col in collections(c, r.ident, "calendar") {
			append(&out, Res{kind = .Calendar, ident = r.ident, coll = col, href = coll_href(r.ident, col)})
		}
		append(&out, Res{kind = .Inbox, ident = r.ident, href = strings.concatenate({r.href, "inbox/"})})
		append(&out, Res{kind = .Outbox, ident = r.ident, href = strings.concatenate({r.href, "outbox/"})})
	case .Book_Home:
		for col in collections(c, r.ident, "addressbook") {
			append(&out, Res{kind = .Book, ident = r.ident, coll = col, href = coll_href(r.ident, col)})
		}
	case .Calendar, .Book:
		k := r.kind == .Calendar ? Kind.Cal_Object : Kind.Card
		for o in objects(c, r.coll, with_body) {
			append(&out, Res{kind = k, ident = r.ident, coll = r.coll, obj = o, href = obj_href(r.ident, r.coll, o.name)})
		}
	case .Inbox:
		process_inbox(c, r.ident)
		for item in inbox_items(c, r.ident) {
			append(&out, Res{kind = .Inbox_Item, ident = r.ident, item = item,
				href = strings.concatenate({r.href, item.id, ".ics"})})
		}
	}
	return out[:]
}

// describe writes one <response> with a 200 propstat for what is known and
// a 404 propstat for what is not.
describe :: proc(c: ^Ctx, w: ^x.Writer, r: ^Res, names: []Prop_Name, propname := false) {
	x.open(w, x.NS_DAV, "response")
	x.leaf(w, x.NS_DAV, "href", r.href)
	missing := make([dynamic]Prop_Name, 0, 4)
	opened := false
	for n in names {
		probe := x.writer_make()
		probe.stack = make([dynamic]string, 0, 4)
		append(&probe.stack, "probe") // suppress the root namespace block
		strings.builder_reset(&probe.sb)
		if !write_prop(c, &probe, r, n) {
			append(&missing, n)
			continue
		}
		if !opened {
			x.open(w, x.NS_DAV, "propstat")
			x.open(w, x.NS_DAV, "prop")
			opened = true
		}
		if propname {
			x.empty(w, n.ns, n.name)
		} else {
			strings.write_string(&w.sb, strings.to_string(probe.sb))
			w.extra += probe.extra
		}
	}
	if opened {
		x.close(w)
		x.leaf(w, x.NS_DAV, "status", "HTTP/1.1 200 OK")
		x.close(w)
	}
	if len(missing) > 0 {
		x.open(w, x.NS_DAV, "propstat")
		x.open(w, x.NS_DAV, "prop")
		for n in missing {
			x.empty(w, n.ns, n.name)
		}
		x.close(w)
		x.leaf(w, x.NS_DAV, "status", "HTTP/1.1 404 Not Found")
		x.close(w)
	}
	x.close(w)
}

@(private = "file")
privileges :: proc(w: ^x.Writer, names: ..string) {
	x.open(w, x.NS_DAV, "current-user-privilege-set")
	for n in names {
		x.open(w, x.NS_DAV, "privilege")
		if n == "schedule-deliver" || n == "schedule-send" || n == "schedule-query-freebusy" || n == "read-free-busy" {
			x.empty(w, x.NS_CALDAV, n)
		} else {
			x.empty(w, x.NS_DAV, n)
		}
		x.close(w)
	}
	x.close(w)
}

@(private = "file")
hrefs :: proc(w: ^x.Writer, ns, name: string, list: ..string) {
	x.open(w, ns, name)
	for h in list {
		x.leaf(w, x.NS_DAV, "href", h)
	}
	x.close(w)
}

@(private = "file")
reports :: proc(w: ^x.Writer, list: ..[2]string) {
	x.open(w, x.NS_DAV, "supported-report-set")
	for r in list {
		x.open(w, x.NS_DAV, "supported-report")
		x.open(w, x.NS_DAV, "report")
		x.empty(w, r[0], r[1])
		x.close(w)
		x.close(w)
	}
	x.close(w)
}

SYNC_PREFIX :: "https://palmframe.dev/ns/sync/"

sync_token :: proc(col: Coll) -> string {
	return fmt.tprintf("%s%s/%d", SYNC_PREFIX, col.id, col.sync_seq)
}

// http_date formats a Postgres timestamp as an HTTP date.
http_date :: proc(iso: string) -> string {
	unix, ok := ical.parse_iso8601(iso)
	if !ok {
		return ""
	}
	t := ical.utc_dt(unix)
	days := ical.days_from_civil(t.y, t.m, t.d)
	DAYS := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s, %02d %s %04d %02d:%02d:%02d GMT", DAYS[ical.weekday_of_days(days)], t.d, MONTHS[t.m - 1], t.y, t.hh, t.mm, t.ss)
}

// write_prop writes one property's value, or returns false when the
// resource does not have it.
write_prop :: proc(c: ^Ctx, w: ^x.Writer, r: ^Res, n: Prop_Name) -> bool {
	switch n.ns {
	case x.NS_DAV:
		return dav_prop(c, w, r, n)
	case x.NS_CALDAV:
		return caldav_prop(c, w, r, n)
	case x.NS_CARDDAV:
		return carddav_prop(c, w, r, n)
	case x.NS_CS:
		switch n.name {
		case "getctag":
			if r.kind == .Calendar || r.kind == .Book {
				x.leaf(w, x.NS_CS, "getctag", fmt.tprintf("%d", r.coll.sync_seq))
				return true
			}
		case "email-address-set":
			if r.kind == .Principal {
				x.open(w, x.NS_CS, "email-address-set")
				x.leaf(w, x.NS_CS, "email-address", strings.concatenate({r.ident.handle, "@", mail_domain()}))
				x.close(w)
				return true
			}
		}
	case x.NS_APPLE:
		switch n.name {
		case "calendar-color":
			if r.kind == .Calendar {
				x.leaf(w, x.NS_APPLE, "calendar-color", r.coll.color)
				return true
			}
		case "calendar-order":
			if r.kind == .Calendar {
				x.leaf(w, x.NS_APPLE, "calendar-order", fmt.tprintf("%d", r.coll.sort_order))
				return true
			}
		}
	case x.NS_PALM:
		switch n.name {
		case "identity":
			if r.ident != nil {
				x.leaf(w, x.NS_PALM, "identity", r.ident.handle)
				return true
			}
		case "owner":
			if r.kind == .Calendar || r.kind == .Book {
				x.leaf(w, x.NS_PALM, "owner", r.coll.owner_handle)
				return true
			}
		case "access":
			if r.kind == .Calendar || r.kind == .Book {
				x.leaf(w, x.NS_PALM, "access", r.coll.access)
				return true
			}
		case "collection-id":
			// The row id, which a share (dav_grants) refers to.
			if r.kind == .Calendar || r.kind == .Book {
				x.leaf(w, x.NS_PALM, "collection-id", r.coll.id)
				return true
			}
		case "public-freebusy":
			if r.kind == .Calendar {
				x.leaf(w, x.NS_PALM, "public-freebusy", r.coll.public_freebusy ? "true" : "false")
				return true
			}
		}
	}
	return false
}

@(private = "file")
dav_prop :: proc(c: ^Ctx, w: ^x.Writer, r: ^Res, n: Prop_Name) -> bool {
	switch n.name {
	case "resourcetype":
		x.open(w, x.NS_DAV, "resourcetype")
		#partial switch r.kind {
		case .Root, .Principals, .Cal_Home, .Book_Home:
			x.empty(w, x.NS_DAV, "collection")
		case .Principal:
			x.empty(w, x.NS_DAV, "principal")
		case .Calendar:
			x.empty(w, x.NS_DAV, "collection")
			x.empty(w, x.NS_CALDAV, "calendar")
			if r.coll.access != "owner" {
				x.empty(w, x.NS_CS, "shared")
			}
		case .Book:
			x.empty(w, x.NS_DAV, "collection")
			x.empty(w, x.NS_CARDDAV, "addressbook")
		case .Inbox:
			x.empty(w, x.NS_DAV, "collection")
			x.empty(w, x.NS_CALDAV, "schedule-inbox")
		case .Outbox:
			x.empty(w, x.NS_DAV, "collection")
			x.empty(w, x.NS_CALDAV, "schedule-outbox")
		}
		x.close(w)
		return true
	case "displayname":
		#partial switch r.kind {
		case .Principal:
			x.leaf(w, x.NS_DAV, "displayname", r.ident.display_name)
		case .Calendar, .Book:
			name := r.coll.display_name
			if r.coll.access != "owner" {
				name = fmt.tprintf("%s (%s)", name, r.coll.owner_handle)
			}
			x.leaf(w, x.NS_DAV, "displayname", name)
		case .Inbox:
			x.leaf(w, x.NS_DAV, "displayname", "Inbox")
		case .Outbox:
			x.leaf(w, x.NS_DAV, "displayname", "Outbox")
		case:
			return false
		}
		return true
	case "getetag":
		#partial switch r.kind {
		case .Cal_Object, .Card:
			x.leaf(w, x.NS_DAV, "getetag", r.obj.etag)
			return true
		case .Inbox_Item:
			x.leaf(w, x.NS_DAV, "getetag", fmt.tprintf("\"%s\"", r.item.id))
			return true
		}
		return false
	case "getcontenttype":
		#partial switch r.kind {
		case .Cal_Object, .Inbox_Item:
			x.leaf(w, x.NS_DAV, "getcontenttype", "text/calendar; charset=utf-8; component=vevent")
			return true
		case .Card:
			x.leaf(w, x.NS_DAV, "getcontenttype", "text/vcard; charset=utf-8")
			return true
		}
		return false
	case "getcontentlength":
		#partial switch r.kind {
		case .Cal_Object, .Card:
			x.leaf(w, x.NS_DAV, "getcontentlength", fmt.tprintf("%d", r.obj.size))
			return true
		case .Inbox_Item:
			x.leaf(w, x.NS_DAV, "getcontentlength", fmt.tprintf("%d", len(r.item.body)))
			return true
		}
		return false
	case "getlastmodified":
		ts := ""
		#partial switch r.kind {
		case .Cal_Object, .Card:
			ts = r.obj.updated_at
		case .Calendar, .Book:
			ts = r.coll.updated_at
		case .Inbox_Item:
			ts = r.item.created_at
		}
		if ts == "" {
			return false
		}
		x.leaf(w, x.NS_DAV, "getlastmodified", http_date(ts))
		return true
	case "current-user-principal":
		hrefs(w, x.NS_DAV, "current-user-principal", principal_href(primary(c)))
		return true
	case "principal-URL":
		if r.kind != .Principal {
			return false
		}
		hrefs(w, x.NS_DAV, "principal-URL", r.href)
		return true
	case "principal-collection-set":
		hrefs(w, x.NS_DAV, "principal-collection-set", "/dav/principals/")
		return true
	case "owner":
		if r.ident == nil {
			return false
		}
		owner := r.ident
		hrefs(w, x.NS_DAV, "owner", principal_href(owner))
		return true
	case "sync-token":
		if r.kind != .Calendar && r.kind != .Book {
			return false
		}
		x.leaf(w, x.NS_DAV, "sync-token", sync_token(r.coll))
		return true
	case "supported-report-set":
		#partial switch r.kind {
		case .Calendar:
			reports(w, {x.NS_CALDAV, "calendar-multiget"}, {x.NS_CALDAV, "calendar-query"},
				{x.NS_CALDAV, "free-busy-query"}, {x.NS_DAV, "sync-collection"})
		case .Book:
			reports(w, {x.NS_CARDDAV, "addressbook-multiget"}, {x.NS_CARDDAV, "addressbook-query"},
				{x.NS_DAV, "sync-collection"})
		case .Inbox:
			reports(w, {x.NS_CALDAV, "calendar-multiget"}, {x.NS_CALDAV, "calendar-query"})
		case:
			reports(w)
		}
		return true
	case "current-user-privilege-set":
		#partial switch r.kind {
		case .Calendar, .Book, .Cal_Object, .Card:
			switch r.coll.access {
			case "owner":
				privileges(w, "read", "write", "write-properties", "write-content", "bind", "unbind",
					"read-acl", "read-current-user-privilege-set")
			case "read-write":
				privileges(w, "read", "write-content", "bind", "unbind", "read-current-user-privilege-set")
			case:
				privileges(w, "read", "read-current-user-privilege-set")
			}
		case .Inbox:
			privileges(w, "read", "unbind", "schedule-deliver", "read-current-user-privilege-set")
		case .Outbox:
			privileges(w, "read", "schedule-send", "schedule-query-freebusy", "read-current-user-privilege-set")
		case .Cal_Home, .Book_Home:
			privileges(w, "read", "bind", "unbind", "write-properties", "read-current-user-privilege-set")
		case:
			privileges(w, "read", "read-current-user-privilege-set")
		}
		return true
	case "quota-available-bytes", "quota-used-bytes":
		return false
	}
	return false
}

@(private = "file")
caldav_prop :: proc(c: ^Ctx, w: ^x.Writer, r: ^Res, n: Prop_Name) -> bool {
	switch n.name {
	case "calendar-home-set":
		if r.kind != .Principal {
			return false
		}
		// An unscoped session (the Palmframe app) may reach every identity's
		// home from its principal; a scoped one sees only its own.
		if c.scoped == "" && r.ident == primary(c) {
			list := make([dynamic]string, 0, len(c.idents))
			append(&list, home_href(.Cal_Home, r.ident))
			for &i in c.idents {
				if &i != r.ident {
					append(&list, home_href(.Cal_Home, &i))
				}
			}
			hrefs(w, x.NS_CALDAV, "calendar-home-set", ..list[:])
		} else {
			hrefs(w, x.NS_CALDAV, "calendar-home-set", home_href(.Cal_Home, r.ident))
		}
		return true
	case "calendar-user-address-set":
		if r.kind != .Principal {
			return false
		}
		hrefs(w, x.NS_CALDAV, "calendar-user-address-set", address_of(r.ident), principal_href(r.ident))
		return true
	case "calendar-user-type":
		if r.kind != .Principal {
			return false
		}
		x.leaf(w, x.NS_CALDAV, "calendar-user-type", "INDIVIDUAL")
		return true
	case "schedule-inbox-URL":
		if r.kind != .Principal {
			return false
		}
		hrefs(w, x.NS_CALDAV, "schedule-inbox-URL", strings.concatenate({home_href(.Cal_Home, r.ident), "inbox/"}))
		return true
	case "schedule-outbox-URL":
		if r.kind != .Principal {
			return false
		}
		hrefs(w, x.NS_CALDAV, "schedule-outbox-URL", strings.concatenate({home_href(.Cal_Home, r.ident), "outbox/"}))
		return true
	case "schedule-default-calendar-URL":
		if r.kind != .Inbox && r.kind != .Principal {
			return false
		}
		for col in collections(c, r.ident, "calendar") {
			if col.access == "owner" {
				hrefs(w, x.NS_CALDAV, "schedule-default-calendar-URL", coll_href(r.ident, col))
				return true
			}
		}
		return false
	case "calendar-description":
		if r.kind != .Calendar {
			return false
		}
		x.leaf(w, x.NS_CALDAV, "calendar-description", r.coll.description)
		return true
	case "calendar-timezone":
		// A VTIMEZONE needs its full definition; clients get the IANA name
		// from calendar-timezone-id (RFC 7809) instead.
		return false
	case "calendar-timezone-id":
		if r.kind != .Calendar {
			return false
		}
		x.leaf(w, x.NS_CALDAV, "calendar-timezone-id", r.coll.timezone)
		return true
	case "supported-calendar-component-set":
		if r.kind != .Calendar && r.kind != .Inbox && r.kind != .Outbox {
			return false
		}
		x.open(w, x.NS_CALDAV, "supported-calendar-component-set")
		comps := r.coll.components
		if r.kind != .Calendar {
			comps = {"VEVENT", "VTODO", "VFREEBUSY"}
		}
		for comp in comps {
			x.empty(w, x.NS_CALDAV, "comp", {"name", comp})
		}
		x.close(w)
		return true
	case "supported-calendar-data":
		if r.kind != .Calendar {
			return false
		}
		x.open(w, x.NS_CALDAV, "supported-calendar-data")
		x.empty(w, x.NS_CALDAV, "calendar-data", {"content-type", "text/calendar"}, {"version", "2.0"})
		x.close(w)
		return true
	case "max-resource-size":
		if r.kind != .Calendar {
			return false
		}
		x.leaf(w, x.NS_CALDAV, "max-resource-size", "10485760")
		return true
	case "schedule-calendar-transp":
		if r.kind != .Calendar {
			return false
		}
		x.open(w, x.NS_CALDAV, "schedule-calendar-transp")
		x.empty(w, x.NS_CALDAV, "opaque")
		x.close(w)
		return true
	case "schedule-tag":
		if r.kind != .Cal_Object || r.obj.schedule_tag == "" {
			return false
		}
		x.leaf(w, x.NS_CALDAV, "schedule-tag", r.obj.schedule_tag)
		return true
	case "calendar-data":
		#partial switch r.kind {
		case .Cal_Object:
			x.leaf(w, x.NS_CALDAV, "calendar-data", calendar_data(c, r, n.el))
			return true
		case .Inbox_Item:
			x.leaf(w, x.NS_CALDAV, "calendar-data", r.item.body)
			return true
		}
		return false
	}
	return false
}

@(private = "file")
carddav_prop :: proc(c: ^Ctx, w: ^x.Writer, r: ^Res, n: Prop_Name) -> bool {
	switch n.name {
	case "addressbook-home-set":
		if r.kind != .Principal {
			return false
		}
		if c.scoped == "" && r.ident == primary(c) {
			list := make([dynamic]string, 0, len(c.idents))
			append(&list, home_href(.Book_Home, r.ident))
			for &i in c.idents {
				if &i != r.ident {
					append(&list, home_href(.Book_Home, &i))
				}
			}
			hrefs(w, x.NS_CARDDAV, "addressbook-home-set", ..list[:])
		} else {
			hrefs(w, x.NS_CARDDAV, "addressbook-home-set", home_href(.Book_Home, r.ident))
		}
		return true
	case "principal-address":
		return false
	case "addressbook-description":
		if r.kind != .Book {
			return false
		}
		x.leaf(w, x.NS_CARDDAV, "addressbook-description", r.coll.description)
		return true
	case "supported-address-data":
		if r.kind != .Book {
			return false
		}
		x.open(w, x.NS_CARDDAV, "supported-address-data")
		x.empty(w, x.NS_CARDDAV, "address-data-type", {"content-type", "text/vcard"}, {"version", "3.0"})
		x.empty(w, x.NS_CARDDAV, "address-data-type", {"content-type", "text/vcard"}, {"version", "4.0"})
		x.close(w)
		return true
	case "max-resource-size":
		if r.kind != .Book {
			return false
		}
		x.leaf(w, x.NS_CARDDAV, "max-resource-size", "10485760")
		return true
	case "address-data":
		if r.kind != .Card {
			return false
		}
		x.leaf(w, x.NS_CARDDAV, "address-data", address_data(r.obj.body, n.el))
		return true
	}
	return false
}
