// Collections and objects, as the database returns them to this session.
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import ical "ical"
import vcard "vcard"
import web "web"

heap :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

Coll :: struct {
	id:              string,
	identity_id:     string,
	owner_handle:    string,
	kind:            string, // calendar | addressbook
	slug:            string,
	seg:             string, // the URL segment under the viewer's home
	display_name:    string,
	description:     string,
	color:           string,
	sort_order:      i64,
	components:      []string,
	timezone:        string,
	public_freebusy: bool,
	sync_seq:        i64,
	min_seq:         i64,
	access:          string, // owner | read | read-write
	updated_at:      string,
}

Obj :: struct {
	name:       string,
	uid:        string,
	etag:       string,
	component:  string,
	body:       string,
	size:       i64,
	updated_at: string,
	created_at: string,
}

coll_from :: proc(r: json.Object) -> Coll {
	c := Coll {
		id              = jstr(r, "id"),
		identity_id     = jstr(r, "identity_id"),
		owner_handle    = jstr(r, "owner_handle"),
		kind            = jstr(r, "kind"),
		slug            = jstr(r, "slug"),
		display_name    = jstr(r, "display_name"),
		description     = jstr(r, "description"),
		color           = jstr(r, "color"),
		sort_order      = jint(r, "sort_order"),
		components      = jstrs(r, "components"),
		timezone        = jstr(r, "timezone"),
		public_freebusy = jbool(r, "public_freebusy"),
		sync_seq        = jint(r, "sync_seq"),
		min_seq         = jint(r, "min_seq"),
		access          = jstr(r, "access"),
		updated_at      = jstr(r, "updated_at"),
	}
	c.seg = c.access == "owner" ? c.slug : strings.concatenate({c.owner_handle, "~", c.slug})
	return c
}

// The defaults are made once per identity per process.
@(private = "file")
g_defaults_lock: sync.Mutex
@(private = "file")
g_defaults: map[string]bool

ensure_defaults :: proc(c: ^Ctx, ident: ^Ident) {
	sync.mutex_lock(&g_defaults_lock)
	if g_defaults == nil {
		g_defaults = make(map[string]bool, 16, heap())
	}
	done := g_defaults[ident.id]
	sync.mutex_unlock(&g_defaults_lock)
	if done {
		return
	}
	b := jb_make()
	jb_str(&b, "target", ident.id)
	_, e := rpc(c, "dav_ensure_defaults", jb_done(&b))
	if db_ok(e) {
		sync.mutex_lock(&g_defaults_lock)
		g_defaults[strings.clone(ident.id, heap())] = true
		sync.mutex_unlock(&g_defaults_lock)
	}
}

// collections lists an identity's home: owned first, then shared with it.
collections :: proc(c: ^Ctx, ident: ^Ident, kind: string) -> []Coll {
	b := jb_make()
	jb_str(&b, "target", ident.id)
	jb_str(&b, "want_kind", kind)
	v, e := rpc(c, "dav_list_collections", jb_done(&b))
	out := make([dynamic]Coll, 0, 4)
	if !db_ok(e) {
		return out[:]
	}
	for r in rows(v) {
		append(&out, coll_from(r))
	}
	return out[:]
}

find_coll :: proc(c: ^Ctx, ident: ^Ident, kind, seg: string) -> (Coll, bool) {
	for col in collections(c, ident, kind) {
		if col.seg == seg {
			return col, true
		}
	}
	return {}, false
}

OBJ_META :: "name,uid,etag,component,size,updated_at,created_at"
OBJ_FULL :: "name,uid,etag,component,size,updated_at,created_at,body"

obj_from :: proc(r: json.Object) -> Obj {
	return Obj {
		name = jstr(r, "name"),
		uid = jstr(r, "uid"),
		etag = jstr(r, "etag"),
		component = jstr(r, "component"),
		body = jstr(r, "body"),
		size = jint(r, "size"),
		updated_at = jstr(r, "updated_at"),
		created_at = jstr(r, "created_at"),
	}
}

objects :: proc(c: ^Ctx, col: Coll, with_body: bool, extra_filter := "") -> []Obj {
	q := fmt.tprintf("/dav_objects?collection_id=eq.%s&select=%s&order=name%s", col.id, with_body ? OBJ_FULL : OBJ_META, extra_filter)
	v, e := rest(c, "GET", q)
	out := make([dynamic]Obj, 0, 16)
	if !db_ok(e) {
		return out[:]
	}
	for r in rows(v) {
		append(&out, obj_from(r))
	}
	return out[:]
}

objects_named :: proc(c: ^Ctx, col: Coll, names: []string, with_body: bool) -> []Obj {
	if len(names) == 0 {
		return nil
	}
	return objects(c, col, with_body, fmt.tprintf("&name=in.%s", pg_list(names)))
}

object :: proc(c: ^Ctx, col: Coll, name: string, with_body := true) -> (Obj, bool) {
	list := objects_named(c, col, {name}, with_body)
	if len(list) == 0 {
		return {}, false
	}
	return list[0], true
}

object_by_uid :: proc(c: ^Ctx, col: Coll, uid: string) -> (Obj, bool) {
	list := objects(c, col, true, fmt.tprintf("&uid=eq.%s", web.query_encode(uid)))
	if len(list) == 0 {
		return {}, false
	}
	return list[0], true
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

Put_Result :: struct {
	etag:    string,
	created: bool,
	status:  int, // HTTP status on failure, 0 on success
	code:    string, // the database error code
	message: string,
}

cal_index_json :: proc(ix: ical.Index) -> string {
	b := jb_make()
	jb_str(&b, "uid", ix.uid)
	jb_str(&b, "component", ix.component)
	if ix.has_start {
		jb_str(&b, "dtstart", ical.iso8601(ix.dtstart))
		jb_str(&b, "dtend", ical.iso8601(ix.dtend))
		jb_str(&b, "first_start", ical.iso8601(ix.first_start))
		if ix.unbounded {
			jb_null(&b, "last_end")
		} else {
			jb_str(&b, "last_end", ical.iso8601(ix.last_end))
		}
	} else {
		// Undated: matches every range.
		jb_str(&b, "first_start", "0001-01-01T00:00:00Z")
		jb_null(&b, "last_end")
	}
	jb_bool(&b, "all_day", ix.all_day)
	jb_opt(&b, "rrule", ix.rrule)
	jb_int(&b, "overrides", i64(ix.overrides))
	jb_opt(&b, "summary", ix.summary)
	jb_opt(&b, "location", ix.location)
	jb_opt(&b, "status", ix.status)
	jb_opt(&b, "organizer", ix.organizer)
	jb_strs(&b, "attendees", ix.attendees)
	return jb_done(&b)
}

card_index_json :: proc(ix: vcard.Index) -> string {
	b := jb_make()
	jb_str(&b, "uid", ix.uid)
	jb_str(&b, "component", "VCARD")
	jb_opt(&b, "fn", ix.fn)
	jb_opt(&b, "given_name", ix.given)
	jb_opt(&b, "family_name", ix.family)
	jb_opt(&b, "org", ix.org)
	jb_strs(&b, "emails", ix.emails)
	jb_strs(&b, "phones", ix.phones)
	jb_opt(&b, "card_kind", ix.kind)
	jb_strs(&b, "members", ix.members)
	return jb_done(&b)
}

put_object :: proc(c: ^Ctx, col: Coll, name, if_match: string, if_none_match: bool, index_json, body: string) -> Put_Result {
	b := jb_make()
	jb_str(&b, "collection", col.id)
	jb_str(&b, "obj_name", name)
	jb_opt(&b, "if_match", if_match)
	jb_bool(&b, "if_none_match", if_none_match)
	jb_raw(&b, "idx", index_json)
	jb_str(&b, "obj_body", body)
	v, e := rpc(c, "dav_put_object", jb_done(&b))
	if !db_ok(e) {
		return {status = http_status_of(e), message = e.message, code = e.code}
	}
	rs := rows(v)
	if len(rs) == 0 {
		return {status = 500, message = "no result"}
	}
	return {etag = jstr(rs[0], "etag"), created = jbool(rs[0], "created")}
}

delete_object :: proc(c: ^Ctx, col: Coll, name, if_match: string) -> (found: bool, status: int) {
	b := jb_make()
	jb_str(&b, "collection", col.id)
	jb_str(&b, "obj_name", name)
	jb_opt(&b, "if_match", if_match)
	v, e := rpc(c, "dav_delete_object", jb_done(&b))
	if !db_ok(e) {
		return false, http_status_of(e)
	}
	if bv, ok := v.(json.Boolean); ok {
		return bool(bv), 0
	}
	return false, 0
}

// put_calendar_text validates, indexes and stores an iCalendar text.
put_calendar_text :: proc(c: ^Ctx, col: Coll, name, if_match: string, if_none_match: bool, text: string) -> Put_Result {
	cal, perr, ok := ical.parse_one(text)
	if !ok {
		return {status = 400, message = perr.message}
	}
	if ce := ical.check(cal); ce != .None {
		return {status = 403, message = ical.check_error_text(ce)}
	}
	z, _ := ical.zone_for(col.timezone)
	ix := ical.index(cal, z)
	return put_object(c, col, name, if_match, if_none_match, cal_index_json(ix), text)
}
