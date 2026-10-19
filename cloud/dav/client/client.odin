// Package davclient is the CalDAV/CardDAV client the Palmframe apps share
// (apps/calendar, apps/contacts).
//
// Sign-in, the session, its refresh and the identity list are cloudkit's
// (apps/cloudkit); so is the transport, so these apps get TLS the day
// cloudkit does. What this adds is the DAV protocol and a local-first cache:
// every collection is a directory of .ics or .vcf files plus a small state
// file, the apps read and write only that directory, and `sync` reconciles
// it with the server in both directions — push local edits with If-Match,
// then pull with sync-collection (RFC 6578).
//
// Why CalDAV rather than PostgREST for the apps: there is then one write
// path, the server's, which validates iCalendar, indexes time ranges and
// does scheduling. An app writing rows directly would have to do all three
// itself or skip them. The apps are just better-integrated CalDAV clients.
package davclient

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../../../apps/cloudkit"
import x "../xml"

DEFAULT_DAV_URL :: "http://127.0.0.1:59580"

Account :: struct {
	cloud:    ^ck.Client,
	dav:      ck.Url,
	dav_text: string,
	idents:   []ck.Identity,
	cache:    string, // root of the local copies
}

Error :: struct {
	status:  int, // HTTP status, 0 when the server was not reached
	message: string,
}

ok :: proc(e: Error) -> bool {
	return e.status == 0 && e.message == ""
}

// open reads the cloudkit session (PALM_IDENTITY narrows it, as everywhere)
// and the DAV server's address ($PALM_DAV_URL). `scope` narrows to one identity
// handle, exactly as PALM_IDENTITY does (it can only narrow).
open :: proc(app := "calendar", dav_url := "", scope := "") -> (a: ^Account, err: Error) {
	a = new(Account)
	c, ce := ck.open(scope = scope, app = app)
	a.cloud = c
	if !ck.ok(ce) {
		return a, Error{0, ce.message}
	}
	u := dav_url
	if u == "" {
		u = os.get_env("PALM_DAV_URL", context.temp_allocator)
	}
	if u == "" {
		u = DEFAULT_DAV_URL
	}
	a.dav_text = strings.clone(u)
	parsed, pok := ck.parse_url(a.dav_text)
	if !pok {
		return a, Error{0, fmt.aprintf("not a URL: %s", u)}
	}
	a.dav = parsed
	root := os.get_env("PALM_DAV_CACHE", context.temp_allocator)
	if root == "" {
		home := os.get_env("HOME", context.temp_allocator)
		root = fmt.tprintf("%s/.local/share/palm/dav", home != "" ? home : "/tmp")
	}
	a.cache = strings.clone(root)
	return a, {}
}

signed_in :: proc(a: ^Account) -> bool {
	return a != nil && a.cloud != nil && ck.signed_in(a.cloud)
}

// load_identities asks the database which identities this session reaches.
load_identities :: proc(a: ^Account) -> Error {
	list, e := ck.identities(a.cloud)
	if !ck.ok(e) {
		return Error{e.status, e.message}
	}
	out := make([dynamic]ck.Identity, 0, len(list))
	for i in list {
		if !i.archived {
			append(&out, i)
		}
	}
	a.idents = out[:]
	return {}
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

Reply :: struct {
	status: int,
	body:   string,
	etag:   string,
}

request :: proc(a: ^Account, method, path: string, body := "", content_type := "", extra: []ck.Header = nil) -> (r: Reply, err: Error) {
	if fe := ck.ensure_fresh(a.cloud); !ck.ok(fe) {
		return {}, Error{fe.status, fe.message}
	}
	hs := make([dynamic]ck.Header, 0, 6, context.temp_allocator)
	append(&hs, ck.Header{"Authorization", fmt.tprintf("Bearer %s", a.cloud.session.access_token)})
	if content_type != "" {
		append(&hs, ck.Header{"Content-Type", content_type})
	}
	append(&hs, ..extra)
	full := strings.concatenate({a.dav.base, path}, context.temp_allocator)
	resp, terr := ck.http_do(a.dav, ck.Request{method = method, path = full, headers = hs[:], body = transmute([]u8)body}, a.cloud.user_agent)
	if terr != "" {
		return {}, Error{0, strings.clone(terr)}
	}
	defer ck.response_destroy(&resp)
	r.status = resp.status
	r.body = strings.clone(resp.body)
	r.etag = strings.clone(ck.response_header(&resp, "ETag"))
	if resp.status == 401 {
		return r, Error{401, "the DAV server refused the session"}
	}
	return r, {}
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

Remote :: struct {
	href:         string,
	kind:         string, // calendar | addressbook
	handle:       string, // whose home it is listed in
	seg:          string,
	display_name: string,
	color:        string,
	sync_token:   string,
	ctag:         string,
	access:       string, // owner | read | read-write
	owner:        string, // the owning identity's handle
	components:   []string,
}

PROPFIND_COLLECTIONS :: `<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/" xmlns:p="https://palmframe.dev/ns/dav">
<d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><d:sync-token/><cs:getctag/><p:access/><p:owner/><c:supported-calendar-component-set/></d:prop>
</d:propfind>`

// discover lists the calendars (kind "calendar") or address books
// ("addressbook") in an identity's home, its own and those shared with it.
discover :: proc(a: ^Account, handle, kind: string) -> (out: []Remote, err: Error) {
	home := kind == "addressbook" ? "addressbooks" : "calendars"
	path := fmt.tprintf("/dav/%s/%s/", home, handle)
	r, e := request(a, "PROPFIND", path, PROPFIND_COLLECTIONS, "application/xml; charset=utf-8", {{"Depth", "1"}})
	if !ok(e) {
		return nil, e
	}
	if r.status != 207 {
		return nil, Error{r.status, fmt.aprintf("PROPFIND %s returned %d", path, r.status)}
	}
	root, perr := x.parse(r.body)
	if perr != "" {
		return nil, Error{r.status, strings.clone(perr)}
	}
	list := make([dynamic]Remote, 0, 4)
	for resp in x.find_all(root, x.NS_DAV, "response") {
		href := text_of(x.find(resp, x.NS_DAV, "href"))
		prop := ok_prop(resp)
		if prop == nil {
			continue
		}
		rt := x.find(prop, x.NS_DAV, "resourcetype")
		is_cal := x.find(rt, x.NS_CALDAV, "calendar") != nil
		is_book := x.find(rt, x.NS_CARDDAV, "addressbook") != nil
		if (kind == "calendar" && !is_cal) || (kind == "addressbook" && !is_book) {
			continue
		}
		rm := Remote {
			href         = strings.clone(href),
			kind         = kind,
			handle       = strings.clone(handle),
			display_name = strings.clone(text_of(x.find(prop, x.NS_DAV, "displayname"))),
			color        = strings.clone(text_of(x.find(prop, x.NS_APPLE, "calendar-color"))),
			sync_token   = strings.clone(text_of(x.find(prop, x.NS_DAV, "sync-token"))),
			ctag         = strings.clone(text_of(x.find(prop, x.NS_CS, "getctag"))),
			access       = strings.clone(text_of(x.find(prop, x.NS_PALM, "access"))),
			owner        = strings.clone(text_of(x.find(prop, x.NS_PALM, "owner"))),
		}
		trimmed := strings.trim_right(href, "/")
		rm.seg = strings.clone(trimmed[strings.last_index_byte(trimmed, '/') + 1:])
		comps := make([dynamic]string, 0, 3)
		if set := x.find(prop, x.NS_CALDAV, "supported-calendar-component-set"); set != nil {
			for cmp in set.children {
				append(&comps, strings.clone(x.attr(cmp, "name")))
			}
		}
		rm.components = comps[:]
		if rm.access == "" {
			rm.access = "owner"
		}
		if rm.owner == "" {
			rm.owner = rm.handle
		}
		append(&list, rm)
	}
	return list[:], {}
}

@(private)
text_of :: proc(e: ^x.Element) -> string {
	return e == nil ? "" : strings.trim_space(e.text)
}

// ok_prop is the <prop> of a response's 200 propstat.
@(private)
ok_prop :: proc(resp: ^x.Element) -> ^x.Element {
	for ps in x.find_all(resp, x.NS_DAV, "propstat") {
		if strings.contains(text_of(x.find(ps, x.NS_DAV, "status")), " 200 ") {
			return x.find(ps, x.NS_DAV, "prop")
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

Item :: struct {
	name: string,
	etag: string,
	data: string,
}

Pull :: struct {
	changed: []Item,
	deleted: []string,
	token:   string,
	full:    bool, // the token was refused and this is everything
}

// pull asks what changed since `token` ("" for everything), with the data.
pull :: proc(a: ^Account, rm: Remote, token: string) -> (p: Pull, err: Error) {
	data_el := rm.kind == "addressbook" ? `<card:address-data/>` : `<cal:calendar-data/>`
	body := fmt.tprintf(`<?xml version="1.0" encoding="utf-8"?>
<d:sync-collection xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:card="urn:ietf:params:xml:ns:carddav">
<d:sync-token>%s</d:sync-token><d:sync-level>1</d:sync-level>
<d:prop><d:getetag/>%s</d:prop></d:sync-collection>`, x.escape(token), data_el)
	r, e := request(a, "REPORT", rm.href, body, "application/xml; charset=utf-8", {{"Depth", "0"}})
	if !ok(e) {
		return {}, e
	}
	if r.status == 403 && strings.contains(r.body, "valid-sync-token") && token != "" {
		p, err = pull(a, rm, "")
		p.full = true
		return
	}
	if r.status != 207 {
		return {}, Error{r.status, fmt.aprintf("sync-collection on %s returned %d", rm.href, r.status)}
	}
	root, perr := x.parse(r.body)
	if perr != "" {
		return {}, Error{r.status, strings.clone(perr)}
	}
	changed := make([dynamic]Item, 0, 8)
	deleted := make([dynamic]string, 0, 2)
	for resp in x.find_all(root, x.NS_DAV, "response") {
		href := text_of(x.find(resp, x.NS_DAV, "href"))
		name := href[strings.last_index_byte(href, '/') + 1:]
		name = percent_decode(name)
		if st := text_of(x.find(resp, x.NS_DAV, "status")); strings.contains(st, " 404 ") {
			append(&deleted, strings.clone(name))
			continue
		}
		prop := ok_prop(resp)
		if prop == nil {
			continue
		}
		data := x.find(prop, x.NS_CALDAV, "calendar-data")
		if data == nil {
			data = x.find(prop, x.NS_CARDDAV, "address-data")
		}
		append(&changed, Item{strings.clone(name), strings.clone(text_of(x.find(prop, x.NS_DAV, "getetag"))), data != nil ? strings.clone(data.text) : ""})
	}
	p.changed = changed[:]
	p.deleted = deleted[:]
	p.token = strings.clone(text_of(x.find(root, x.NS_DAV, "sync-token")))
	return p, {}
}

// put stores one object. `etag` "" creates (If-None-Match: *), otherwise it
// must match. Returns the new ETag ("" when the server rewrote the data,
// which happens when it stamps scheduling status).
put :: proc(a: ^Account, rm: Remote, name, data, etag: string) -> (new_etag: string, status: int, err: Error) {
	ctype := rm.kind == "addressbook" ? "text/vcard; charset=utf-8" : "text/calendar; charset=utf-8"
	pre := etag == "" ? ck.Header{"If-None-Match", "*"} : ck.Header{"If-Match", etag}
	r, e := request(a, "PUT", strings.concatenate({rm.href, percent_encode(name)}), data, ctype, {pre})
	if !ok(e) {
		return "", 0, e
	}
	return r.etag, r.status, {}
}

remove :: proc(a: ^Account, rm: Remote, name, etag: string) -> (status: int, err: Error) {
	extra := make([dynamic]ck.Header, 0, 1, context.temp_allocator)
	if etag != "" {
		append(&extra, ck.Header{"If-Match", etag})
	}
	r, e := request(a, "DELETE", strings.concatenate({rm.href, percent_encode(name)}), "", "", extra[:])
	if !ok(e) {
		return 0, e
	}
	return r.status, {}
}

// get fetches one object.
get :: proc(a: ^Account, href: string) -> (data, etag: string, err: Error) {
	r, e := request(a, "GET", href)
	if !ok(e) {
		return "", "", e
	}
	if r.status != 200 {
		return "", "", Error{r.status, fmt.aprintf("GET %s returned %d", href, r.status)}
	}
	return r.body, r.etag, {}
}

// ---------------------------------------------------------------------------
// The scheduling inbox
// ---------------------------------------------------------------------------

Invitation :: struct {
	href: string,
	data: string,
}

// inbox lists an identity's scheduling messages. Listing it also makes the
// server apply them to the identity's calendars.
inbox :: proc(a: ^Account, handle: string) -> (out: []Invitation, err: Error) {
	body := `<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop></d:propfind>`
	r, e := request(a, "PROPFIND", fmt.tprintf("/dav/calendars/%s/inbox/", handle), body, "application/xml; charset=utf-8", {{"Depth", "1"}})
	if !ok(e) {
		return nil, e
	}
	root, perr := x.parse(r.body)
	if perr != "" {
		return nil, Error{r.status, strings.clone(perr)}
	}
	list := make([dynamic]Invitation, 0, 2)
	for resp in x.find_all(root, x.NS_DAV, "response") {
		prop := ok_prop(resp)
		if prop == nil {
			continue
		}
		data := x.find(prop, x.NS_CALDAV, "calendar-data")
		if data == nil {
			continue
		}
		append(&list, Invitation{strings.clone(text_of(x.find(resp, x.NS_DAV, "href"))), strings.clone(data.text)})
	}
	return list[:], {}
}

dismiss :: proc(a: ^Account, href: string) -> Error {
	r, e := request(a, "DELETE", href)
	if !ok(e) {
		return e
	}
	if r.status != 204 && r.status != 404 {
		return Error{r.status, fmt.aprintf("DELETE %s returned %d", href, r.status)}
	}
	return {}
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

percent_encode :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '@', '+', '=':
			strings.write_byte(&sb, ch)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[ch >> 4])
			strings.write_byte(&sb, HEX[ch & 15])
		}
	}
	return strings.to_string(sb)
}

percent_decode :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '%') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	hexv :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && hexv(s[i + 1]) >= 0 && hexv(s[i + 2]) >= 0 {
			strings.write_byte(&sb, u8(hexv(s[i + 1]) * 16 + hexv(s[i + 2])))
			i += 2
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}
