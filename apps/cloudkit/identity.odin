package cloudkit

// Identities, devices and sessions: the accounts surface every app shares.
// The tables and functions are cloud/supabase/migrations/2026101911*.

import "core:fmt"
import "core:strings"

Identity :: struct {
	id:           string,
	handle:       string,
	display_name: string,
	kind:         string, // personal | work | public | project
	color:        string, // a Tailwind palette name: bg-<color>-500 works
	archived:     bool,
	created_at:   string,
}

identity_from :: proc(v: Value, allocator := context.allocator) -> Identity {
	return Identity {
		id = strings.clone(get_str(v, "id"), allocator),
		handle = strings.clone(get_str(v, "handle"), allocator),
		display_name = strings.clone(get_str(v, "display_name"), allocator),
		kind = strings.clone(get_str(v, "kind"), allocator),
		color = strings.clone(get_str(v, "color"), allocator),
		archived = !is_null(v, "archived_at"),
		created_at = strings.clone(get_str(v, "created_at"), allocator),
	}
}

identity_free :: proc(i: ^Identity, allocator := context.allocator) {
	delete(i.id, allocator)
	delete(i.handle, allocator)
	delete(i.display_name, allocator)
	delete(i.kind, allocator)
	delete(i.color, allocator)
	delete(i.created_at, allocator)
	i^ = {}
}

identities_free :: proc(xs: []Identity, allocator := context.allocator) {
	for &x in xs {
		identity_free(&x, allocator)
	}
	delete(xs, allocator)
}

// identities lists what this session can see: all of the person's, or the
// one a scoped session acts for. Archived identities are included.
identities :: proc(c: ^Client, allocator := context.allocator) -> (out: []Identity, e: Error) {
	v: Value
	v, e = select(c, "identities", "select=*&order=created_at.asc", context.temp_allocator)
	if !ok(e) {
		return nil, e
	}
	rows := array(v)
	out = make([]Identity, len(rows), allocator)
	for r, i in rows {
		out[i] = identity_from(r, allocator)
	}
	return out, {}
}

create_identity :: proc(c: ^Client, handle, display_name: string, kind := "personal", color := "indigo", allocator := context.allocator) -> (id: Identity, e: Error) {
	o := obj()
	put(&o, "handle", handle)
	put(&o, "display_name", display_name)
	put(&o, "kind", kind)
	put(&o, "color", color)
	return identity_rpc(c, "create_identity", obj_done(&o), allocator)
}

rename_identity :: proc(c: ^Client, target, display_name: string, allocator := context.allocator) -> (id: Identity, e: Error) {
	o := obj()
	put(&o, "target", target)
	put(&o, "display_name", display_name)
	return identity_rpc(c, "rename_identity", obj_done(&o), allocator)
}

set_identity_color :: proc(c: ^Client, target, color: string, allocator := context.allocator) -> (id: Identity, e: Error) {
	o := obj()
	put(&o, "target", target)
	put(&o, "color", color)
	return identity_rpc(c, "set_identity_color", obj_done(&o), allocator)
}

archive_identity :: proc(c: ^Client, target: string, allocator := context.allocator) -> (id: Identity, e: Error) {
	return identity_rpc(c, "archive_identity", one("target", target), allocator)
}

restore_identity :: proc(c: ^Client, target: string, allocator := context.allocator) -> (id: Identity, e: Error) {
	return identity_rpc(c, "restore_identity", one("target", target), allocator)
}

@(private)
identity_rpc :: proc(c: ^Client, fn, args: string, allocator := context.allocator) -> (id: Identity, e: Error) {
	v: Value
	v, e = rpc(c, fn, args, context.temp_allocator)
	if !ok(e) {
		return {}, e
	}
	if get_str(v, "id") == "" {
		// A security-invoker update that RLS filtered returns null.
		return {}, Error{kind = .Not_Found, message = strings.clone("no such identity, or not yours to change")}
	}
	return identity_from(v, allocator), {}
}

// find_identity looks an identity up by handle or id in a list.
find_identity :: proc(xs: []Identity, key: string) -> (Identity, bool) {
	for x in xs {
		if x.handle == key || x.id == key {
			return x, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Scoped sessions
// ---------------------------------------------------------------------------

Minted :: struct {
	device_id:  string,
	session_id: string,
	identity:   Identity,
	path:       string, // where the session was stored, "" if it was not
}

// Where scope_to keeps what it minted.
Scope_Store :: enum u8 {
	Machine, // scoped/<handle>.json: this machine's own session for the identity
	Delegated, // delegated/<handle>-<device>.json: to hand to one program, via PALM_CLOUD_SESSION
}

// scope_to mints a session that acts for one identity only, takes it up, and
// stores it as scoped/<handle>.json, where a process started with
// PALM_IDENTITY=<handle> will find it. Only the person's own unscoped session
// may do this; the server refuses anything else.
//
// `kind` is "device" or "assistant". `expires_in` is seconds, 0 for none.
// `store` says where it is kept: .Machine replaces this machine's session for
// the identity (what `accounts switch` does); .Delegated keeps it apart, so
// handing a session to an assistant never replaces the machine's own.
scope_to :: proc(c: ^Client, ident: Identity, device_name: string, kind := "device", expires_in := 0, store := Scope_Store.Machine) -> (m: Minted, e: Error) {
	if c.scope != "" {
		return {}, out_of_scope_local(c)
	}
	o := obj()
	put(&o, "target", ident.id)
	put(&o, "device_name", device_name)
	put(&o, "device_kind", kind)
	if expires_in > 0 {
		put(&o, "expires_in_seconds", i64(expires_in))
	}
	v: Value
	v, e = rpc(c, "mint_scoped_session", obj_done(&o), context.temp_allocator)
	if !ok(e) {
		return {}, e
	}
	tok: Value
	tok, e = exchange(c, get_str(v, "refresh_token"), context.temp_allocator)
	if !ok(e) {
		return {}, e
	}
	s := session_from_token_response(tok)
	defer session_free(&s)
	if s.identity_id != ident.id {
		return {}, Error{kind = .Failed, message = strings.clone("the minted token does not carry the identity it was minted for")}
	}
	s.handle = strings.clone(ident.handle)
	m.device_id = strings.clone(get_str(v, "device_id"))
	m.session_id = strings.clone(get_str(v, "session_id"))
	m.path = store == .Delegated ? delegated_path(c, ident.handle, m.device_id) : scoped_path(c, ident.handle)
	if se := save_scoped(c, s, m.path); !ok(se) {
		return {}, se
	}
	m.identity = ident
	return m, {}
}

Device :: struct {
	id:           string,
	identity_id:  string,
	name:         string,
	kind:         string,
	created_at:   string,
	expires_at:   string,
	last_seen_at: string,
	active:       bool, // its session still exists
}

devices :: proc(c: ^Client, allocator := context.allocator) -> (out: []Device, e: Error) {
	v: Value
	v, e = select(c, "devices", "select=*&order=created_at.desc", context.temp_allocator)
	if !ok(e) {
		return nil, e
	}
	rows := array(v)
	out = make([]Device, len(rows), allocator)
	for r, i in rows {
		out[i] = Device {
			id = strings.clone(get_str(r, "id"), allocator),
			identity_id = strings.clone(get_str(r, "identity_id"), allocator),
			name = strings.clone(get_str(r, "name"), allocator),
			kind = strings.clone(get_str(r, "kind"), allocator),
			created_at = strings.clone(get_str(r, "created_at"), allocator),
			expires_at = strings.clone(get_str(r, "expires_at"), allocator),
			last_seen_at = strings.clone(get_str(r, "last_seen_at"), allocator),
			active = !is_null(r, "session_id") && is_null(r, "revoked_at"),
		}
	}
	return out, {}
}

revoke_device :: proc(c: ^Client, device_id: string) -> Error {
	v, e := rpc(c, "revoke_device", one("device", device_id), context.temp_allocator)
	_ = v
	return e
}

Account_Session :: struct {
	session_id:   string,
	created_at:   string,
	refreshed_at: string,
	not_after:    string,
	user_agent:   string,
	ip:           string,
	identity_id:  string, // "" for an unscoped session
	device_id:    string,
	device_name:  string,
	device_kind:  string,
	current:      bool,
}

// sessions lists the account's GoTrue sessions. Unscoped: every one, which
// is every signed-in machine and every delegated device. Scoped: only itself.
sessions :: proc(c: ^Client, allocator := context.allocator) -> (out: []Account_Session, e: Error) {
	v: Value
	v, e = rpc(c, "list_sessions", "{}", context.temp_allocator)
	if !ok(e) {
		return nil, e
	}
	rows := array(v)
	out = make([]Account_Session, len(rows), allocator)
	for r, i in rows {
		out[i] = Account_Session {
			session_id = strings.clone(get_str(r, "session_id"), allocator),
			created_at = strings.clone(get_str(r, "created_at"), allocator),
			refreshed_at = strings.clone(get_str(r, "refreshed_at"), allocator),
			not_after = strings.clone(get_str(r, "not_after"), allocator),
			user_agent = strings.clone(get_str(r, "user_agent"), allocator),
			ip = strings.clone(get_str(r, "ip"), allocator),
			identity_id = strings.clone(get_str(r, "identity_id"), allocator),
			device_id = strings.clone(get_str(r, "device_id"), allocator),
			device_name = strings.clone(get_str(r, "device_name"), allocator),
			device_kind = strings.clone(get_str(r, "device_kind"), allocator),
			current = get_bool(r, "current"),
		}
	}
	return out, {}
}

end_session :: proc(c: ^Client, session_id: string) -> Error {
	_, e := rpc(c, "end_session", one("target", session_id), context.temp_allocator)
	return e
}

// whoami asks the server what this session is: the account, and the
// identity it is scoped to, if any.
whoami :: proc(c: ^Client, allocator := context.allocator) -> (v: Value, e: Error) {
	return rpc(c, "whoami", "{}", allocator)
}

// ---------------------------------------------------------------------------
// Profiles and avatars
// ---------------------------------------------------------------------------

AVATAR_BUCKET :: "avatars"

// set_avatar uploads an image as the identity's avatar and records it on
// the profile.
set_avatar :: proc(c: ^Client, identity_id, image_path: string) -> Error {
	ct := guess_content_type(image_path)
	ext := "png"
	switch ct {
	case "image/jpeg":
		ext = "jpg"
	case "image/webp":
		ext = "webp"
	case "image/png":
	case:
		return Error{kind = .Invalid, message = strings.clone("an avatar is a PNG, JPEG or WebP image")}
	}
	name := fmt.tprintf("%s/avatar.%s", identity_id, ext)
	if e := upload_file(c, AVATAR_BUCKET, name, image_path, ct, upsert = true); !ok(e) {
		return e
	}
	o := obj()
	put(&o, "avatar_path", name)
	_, e := update(c, "profiles", fmt.tprintf("identity_id=eq.%s", escape(identity_id)), obj_done(&o), context.temp_allocator)
	return e
}
