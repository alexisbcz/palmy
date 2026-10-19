package main

// Everything in this file runs with srv.mu held.

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import w "../../apps/chat/wire"
import ck "../../apps/cloudkit"
import "pcp"

rand_bytes :: proc(b: []u8) {
	crypto.rand_bytes(b)
}

REACTION_KEYS :: [?]string{"thumbsup", "heart", "party", "rocket", "fire", "grin", "eyes", "check"}
MAX_TEXT :: 4000

// ---------------------------------------------------------------------------
// Sessions: every statement for a client runs as that client's identity.
// ---------------------------------------------------------------------------

// scope_json is the claims a client's statements run under: the verified
// token's person, narrowed to one identity. Narrowing only removes access, so
// it is safe for the gateway to add; it never comes from the client.
scope_json :: proc(cl: Claims, identity: string) -> string {
	e: w.Enc
	w.enc_open(&e, context.allocator)
	w.kv_str(&e, "sub", cl.sub)
	w.kv_str(&e, "role", "authenticated")
	w.kv_str(&e, "aud", "authenticated")
	w.kv_int(&e, "exp", cl.exp)
	if cl.email != "" {
		w.kv_str(&e, "email", cl.email)
	}
	if cl.session_id != "" {
		w.kv_str(&e, "session_id", cl.session_id)
	}
	if identity != "" {
		w.kv_str(&e, "palm_identity", identity)
	}
	return w.enc_done(&e)
}

locked_begin :: proc(scope: string, tag := "") -> bool {
	if !db_simple(&srv.db, "begin") {
		db_simple(&srv.db, "rollback")
		if !db_simple(&srv.db, "begin") {
			return false
		}
	}
	r := db_q(
		&srv.db,
		"select set_config('role', 'authenticated', true), set_config('request.jwt.claims', $1, true), " +
		"set_config('rtc.origin', $2, true), set_config('rtc.tag', $3, true)",
		scope,
		srv.origin,
		tag,
	)
	if !r.ok {
		db_simple(&srv.db, "rollback")
		return false
	}
	return true
}

locked_finish :: proc(commit: bool) -> bool {
	if commit {
		if db_simple(&srv.db, "commit") {
			return true
		}
	}
	db_simple(&srv.db, "rollback")
	return false
}

// locked_as runs one statement as the client, in its own transaction.
locked_as :: proc(c: ^Conn, sql: string, params: ..string, tag := "") -> Result {
	if !locked_begin(c.scope, tag) {
		return Result{code = "08006", msg = "the database is unavailable"}
	}
	r := db_q(&srv.db, sql, ..params)
	if !locked_finish(r.ok) && r.ok {
		return Result{code = "40001", msg = "the change could not be committed"}
	}
	return r
}

// locked_db_err answers a failed statement with the protocol's error codes.
locked_db_err :: proc(c: ^Conn, rq: i64, r: Result, forbidden := "forbidden") {
	code := "failed"
	switch r.code {
	case "42501":
		code = forbidden
	case "P0002":
		code = "not_found"
	case "22023", "22P02", "23514":
		code = "invalid"
	case "23505":
		code = "conflict"
	case "08006", "40001":
		code = "unavailable"
	}
	locked_err(c, rq, code, r.msg)
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

locked_send :: proc(c: ^Conn, payload: string) {
	if c.dead {
		return
	}
	if !w.send_frame(c.sock, payload) {
		c.dead = true
		_ = net_shutdown(c)
	}
}

locked_err :: proc(c: ^Conn, rq: i64, code, msg: string) {
	e: w.Enc
	w.enc_begin(&e, "error")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "code", code)
	w.kv_str(&e, "msg", msg)
	locked_send(c, w.enc_done(&e))
}

// obj_frame turns a JSON object made by SQL into a frame of type `t`.
obj_frame :: proc(t: string, rq: i64, obj: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"t":`)
	w.write_json_string(&b, t)
	if rq != 0 {
		fmt.sbprintf(&b, `,"rq":%d`, rq)
	}
	body := strings.trim_space(obj)
	if len(body) > 2 && body[0] == '{' {
		strings.write_byte(&b, ',')
		strings.write_string(&b, body[1:])
	} else {
		strings.write_byte(&b, '}')
	}
	return strings.to_string(b)
}

list_frame :: proc(t: string, rq: i64, list: string) -> string {
	e: w.Enc
	w.enc_begin(&e, t)
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_raw(&e, "list", list != "" ? list : "[]")
	return w.enc_done(&e)
}

locked_broadcast :: proc(ch: string, payload: string, except := -1) {
	for cc in srv.conns {
		if cc.dead || !cc.hello || cc.id == except {
			continue
		}
		if ch != "" && !(ch in cc.visible) {
			continue
		}
		locked_send(cc, payload)
	}
}

locked_to_identity :: proc(ident: string, payload: string) {
	for cc in srv.conns {
		if !cc.dead && cc.hello && cc.ident.id == ident {
			locked_send(cc, payload)
		}
	}
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

locked_dispatch :: proc(c: ^Conn, t: string, o: json.Object, rq: i64, pre: ^Pre) {
	if c.is_sfu {
		locked_sfu(c, t, o)
		return
	}
	if t == "sfu_hello" {
		locked_sfu_hello(c, o)
		return
	}
	if t != "hello" && !c.hello {
		locked_drop_staged(c, pre)
		locked_err(c, rq, "no_hello", "send hello first")
		return
	}
	switch t {
	case "hello":
		locked_hello(c, o, rq, pre)
	case "auth":
		locked_auth(c, o, rq, pre)
	case "spaces":
		locked_lists(c, rq, {.Spaces})
	case "channels":
		locked_lists(c, rq, {.Channels})
	case "users":
		locked_lists(c, rq, {.Users})
	case "reads":
		locked_lists(c, rq, {.Reads})
	case "invites":
		locked_lists(c, rq, {.Invites})
	case "members":
		locked_members(c, o, rq)
	case "create_space":
		locked_create_space(c, o, rq)
	case "create_channel":
		locked_create_channel(c, o, rq)
	case "invite":
		locked_invite(c, o, rq)
	case "accept", "decline":
		locked_answer_invite(c, o, rq, t == "accept")
	case "remove":
		locked_remove(c, o, rq)
	case "leave_space":
		locked_leave_space(c, o, rq)
	case "part":
		locked_part(c, o, rq)
	case "dm":
		locked_dm(c, o, rq)
	case "join":
		locked_join(c, o, rq)
	case "leave":
		locked_ack(c, rq, "left", w.ostr(o, "ch"))
	case "post":
		locked_post(c, o, rq)
	case "history":
		locked_history(c, o, rq)
	case "thread":
		locked_thread(c, o, rq)
	case "sync":
		locked_sync(c, o, rq)
	case "edit":
		locked_edit(c, o, rq)
	case "delete":
		locked_delete(c, o, rq)
	case "react":
		locked_react(c, o, rq)
	case "typing":
		locked_typing(c, o)
	case "presence":
		locked_presence(c, o, rq)
	case "search":
		locked_search(c, o, rq)
	case "read":
		locked_read(c, o, rq)
	case "attach":
		locked_attach(c, o, rq, pre)
	case "fetch":
		locked_fetch(c, o, rq)
	case "call_join":
		locked_call_join(c, o, rq)
	case "call_leave":
		locked_call_leave(c, o, rq)
	case "ping":
		e: w.Enc
		w.enc_begin(&e, "pong")
		if rq != 0 {
			w.kv_int(&e, "rq", rq)
		}
		locked_send(c, w.enc_done(&e))
	case:
		locked_err(c, rq, "unknown_type", fmt.tprintf("no such message type %q", t))
	}
}

locked_ack :: proc(c: ^Conn, rq: i64, t: string, ch: string) {
	e: w.Enc
	w.enc_begin(&e, t)
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	if ch != "" {
		w.kv_str(&e, "ch", ch)
	}
	locked_send(c, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// hello / auth
// ---------------------------------------------------------------------------

locked_hello :: proc(c: ^Conn, o: json.Object, rq: i64, pre: ^Pre) {
	if c.hello {
		locked_err(c, rq, "already_hello", "hello was already sent on this connection")
		return
	}
	if pre.token_err != "" {
		locked_err(c, rq, "auth", pre.token_err)
		return
	}
	cl := pre.claims

	// Which identity this connection speaks as. A scoped token already says;
	// an unscoped one must be told, and is never defaulted (cloud/docs
	// product.md P3: nothing defaults across identities).
	want := strings.to_lower(strings.trim_space(w.ostr(o, "identity")), context.temp_allocator)
	base := scope_json(cl, cl.palm_identity)
	r := locked_as_scope(
		base,
		"select id::text, handle, display_name, color, kind from public.identities " +
		"where archived_at is null and ($1 = '' or id::text = $1 or handle = $1) order by created_at",
		want,
	)
	delete(base)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if len(r.rows) == 0 {
		if cl.palm_identity != "" && want != "" {
			locked_err(c, rq, "out_of_scope", "this session is scoped to another identity")
		} else {
			locked_err(c, rq, "no_identity", want == "" ? "this account has no identity yet" : "no such identity on this account")
		}
		return
	}
	if len(r.rows) > 1 {
		hs := make([dynamic]string, context.temp_allocator)
		for row in r.rows {
			append(&hs, row[1])
		}
		locked_err(c, rq, "identity_required", strings.join(hs[:], ", ", context.temp_allocator))
		return
	}
	row := r.rows[0]
	c.ident = Ident {
		id     = strings.clone(row[0]),
		handle = strings.clone(row[1]),
		name   = strings.clone(row[2]),
		color  = strings.clone(row[3]),
		kind   = strings.clone(row[4]),
	}
	c.claims = cl
	c.token = strings.clone(w.ostr(o, "token"))
	c.scope = scope_json(cl, c.ident.id)
	c.hello = true
	c.away = w.ostr(o, "presence") == "away"
	c.visible = make(map[string]bool)
	c.spaces = make(map[string]bool)
	c.peers = make(map[string]bool)

	locked_as(c, "select public.rtc_seed_reads($1)", c.ident.id)
	locked_refresh(c)

	// A command-line session is not a person arriving: it does not make the
	// identity online, and its leaving does not make it offline.
	c.passive = w.ostr(o, "presence") == "none"
	if !c.passive {
		srv.online[c.ident.id] = (srv.online[c.ident.id] or_else 0) + 1
		locked_store_presence(c, c.away ? "away" : "online")
	}

	e: w.Enc
	w.enc_begin(&e, "welcome")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_int(&e, "proto", PROTO_VERSION)
	w.kv_str(&e, "nick", c.ident.handle)
	w.kv_str(&e, "server", "palm-rtc")
	w.kv_raw(&e, "identity", locked_ident_json(c.ident))
	w.kv_int(&e, "exp", cl.exp)
	locked_send(c, w.enc_done(&e))
	locked_lists(c, 0, {.Spaces, .Channels, .Users, .Reads, .Invites, .Calls})
	if !c.passive {
		locked_broadcast_presence(c.ident, c.away ? "away" : "online")
	}
	note("%s (%s) said hello, %d channels visible", c.ident.handle, c.ident.id[:8], len(c.visible))
}

// locked_as_scope is locked_as for a scope that is not yet a connection's.
locked_as_scope :: proc(scope, sql: string, params: ..string) -> Result {
	if !locked_begin(scope) {
		return Result{code = "08006", msg = "the database is unavailable"}
	}
	r := db_q(&srv.db, sql, ..params)
	locked_finish(r.ok)
	return r
}

locked_ident_json :: proc(i: Ident) -> string {
	e: w.Enc
	w.enc_open(&e)
	w.kv_str(&e, "id", i.id)
	w.kv_str(&e, "handle", i.handle)
	w.kv_str(&e, "name", i.name)
	w.kv_str(&e, "color", i.color)
	w.kv_str(&e, "kind", i.kind)
	return w.enc_done(&e)
}

// auth replaces the token before it expires. It must be the same person and,
// if the new token is scoped, the same identity.
locked_auth :: proc(c: ^Conn, o: json.Object, rq: i64, pre: ^Pre) {
	if pre.token_err != "" {
		locked_err(c, rq, "auth", pre.token_err)
		return
	}
	cl := pre.claims
	if cl.sub != c.claims.sub || (cl.palm_identity != "" && cl.palm_identity != c.ident.id) {
		locked_err(c, rq, "out_of_scope", "a token for another person or identity")
		return
	}
	delete(c.token)
	delete(c.scope)
	c.claims = cl
	c.token = strings.clone(w.ostr(o, "token"))
	c.scope = scope_json(cl, c.ident.id)
	e: w.Enc
	w.enc_begin(&e, "authed")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_int(&e, "exp", cl.exp)
	locked_send(c, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// What a connection can see
// ---------------------------------------------------------------------------

// locked_refresh asks RLS again what this identity can see. Returns the
// channels it could see before and cannot now.
locked_refresh :: proc(c: ^Conn) -> (lost: [dynamic]string) {
	lost = make([dynamic]string, context.temp_allocator)
	if !locked_begin(c.scope) {
		return
	}
	chs := db_q(&srv.db, "select id::text from public.rtc_channels where archived_at is null")
	sps := db_q(&srv.db, "select id::text from public.rtc_spaces")
	prs := db_q(&srv.db, "select distinct identity_id::text from public.rtc_members")
	locked_finish(true)
	if !chs.ok || !sps.ok || !prs.ok {
		return
	}
	now := make(map[string]bool, context.temp_allocator)
	for row in chs.rows {
		now[row[0]] = true
	}
	for k in c.visible {
		if !(k in now) {
			append(&lost, strings.clone(k, context.temp_allocator))
		}
	}
	set_rows(&c.visible, chs.rows)
	set_rows(&c.spaces, sps.rows)
	set_rows(&c.peers, prs.rows)

	// A member removed from a channel mid-call leaves the call too.
	for ch in lost {
		for _, call in srv.calls {
			if call.ch != ch {
				continue
			}
			for id in call.ids {
				if id == c.ident.id {
					locked_sfu_kick(call.id, id)
				}
			}
		}
	}
	return
}

set_rows :: proc(m: ^map[string]bool, rows: [][]string) {
	for k in m {
		delete(k)
	}
	clear(m)
	for row in rows {
		m[strings.clone(row[0])] = true
	}
}

List :: enum {
	Spaces,
	Channels,
	Users,
	Reads,
	Invites,
	Calls,
}

locked_lists :: proc(c: ^Conn, rq: i64, which: bit_set[List]) {
	if !locked_begin(c.scope) {
		locked_err(c, rq, "unavailable", "the database is unavailable")
		return
	}
	defer locked_finish(true)
	if .Spaces in which {
		locked_send(c, list_frame("spaces", rq, one(db_q(&srv.db, "select public.rtc_spaces_json()::text"))))
	}
	if .Channels in which {
		locked_send(c, list_frame("channels", rq, one(db_q(&srv.db, "select public.rtc_channels_json()::text"))))
	}
	if .Users in which {
		locked_send(c, list_frame("users", rq, one(db_q(&srv.db, "select public.rtc_users_json()::text"))))
	}
	if .Reads in which {
		locked_send(c, list_frame("reads", rq, one(db_q(&srv.db, "select public.rtc_reads_json($1)::text", c.ident.id))))
	}
	if .Invites in which {
		locked_send(c, list_frame("invites", rq, one(db_q(&srv.db, "select public.rtc_invites_json()::text"))))
	}
	if .Calls in which {
		r := db_q(
			&srv.db,
			"select public.rtc_call_json(k.id)::text from public.rtc_calls k where k.ended_at is null",
		)
		for row in r.rows {
			locked_send(c, obj_frame("call", 0, row[0]))
		}
	}
}

locked_members :: proc(c: ^Conn, o: json.Object, rq: i64) {
	space := w.ostr(o, "space")
	if !is_uuid(space) {
		locked_err(c, rq, "not_found", "no such space")
		return
	}
	r := locked_as(c, "select public.rtc_members_json($1)::text", space)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	e: w.Enc
	w.enc_begin(&e, "members")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "space", space)
	w.kv_raw(&e, "list", one(r))
	locked_send(c, w.enc_done(&e))
}

// locked_refresh_identity re-asks for every connection of one identity and
// pushes the lists that may have changed.
locked_refresh_identity :: proc(ident: string) {
	for cc in srv.conns {
		if cc.dead || !cc.hello || cc.ident.id != ident {
			continue
		}
		lost := locked_refresh(cc)
		locked_lists(cc, 0, {.Spaces, .Channels, .Users, .Reads})
		for ch in lost {
			locked_ack(cc, 0, "removed", ch)
		}
	}
}

// ---------------------------------------------------------------------------
// Spaces, channels, invites
// ---------------------------------------------------------------------------

locked_create_space :: proc(c: ^Conn, o: json.Object, rq: i64) {
	name := strings.trim_space(w.ostr(o, "name"))
	r := locked_as(c, "insert into public.rtc_spaces (identity_id, name) values ($1, $2) returning id::text", c.ident.id, name)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	locked_as(c, "select public.rtc_seed_reads($1)", c.ident.id)
	locked_refresh_identity(c.ident.id)
	e: w.Enc
	w.enc_begin(&e, "space")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "id", one(r))
	locked_send(c, w.enc_done(&e))
}

locked_create_channel :: proc(c: ^Conn, o: json.Object, rq: i64) {
	space := w.ostr(o, "space")
	name := strings.trim_left(strings.trim_space(w.ostr(o, "name")), "#")
	kind := w.obool(o, "private") ? "private" : "public"
	if !is_uuid(space) {
		locked_err(c, rq, "not_found", "no such space")
		return
	}
	// The id is chosen here rather than returned: INSERT … RETURNING is
	// checked against the SELECT policy before the AFTER trigger has made
	// the creator a member of a private channel, so it would refuse to show
	// the creator the row it just made.
	id := new_uuid(context.temp_allocator)
	r := locked_as(
		c,
		"insert into public.rtc_channels (id, space_id, identity_id, kind, name, topic) values ($1, $2, $3, $4, $5, $6)",
		id,
		space,
		c.ident.id,
		kind,
		name,
		w.ostr(o, "topic"),
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	locked_as(c, "select public.rtc_seed_reads($1)", c.ident.id)
	locked_refresh_identity(c.ident.id)
	locked_ack(c, rq, "joined", id)
}

locked_invite :: proc(c: ^Conn, o: json.Object, rq: i64) {
	space, ch := w.ostr(o, "space"), w.ostr(o, "ch")
	if !is_uuid(space) || (ch != "" && !is_uuid(ch)) {
		locked_err(c, rq, "not_found", "no such space or channel")
		return
	}
	role := w.ostr(o, "role", ch != "" ? "guest" : "member")
	r := locked_as(
		c,
		"insert into public.rtc_invites (space_id, channel_id, identity_id, invitee_handle, role, note) " +
		"values ($1, nullif($2, '')::uuid, $3, $4, $5, $6) returning id::text",
		space,
		ch,
		c.ident.id,
		strings.trim_left(strings.trim_space(w.ostr(o, "handle")), "@"),
		role,
		w.ostr(o, "note"),
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	e: w.Enc
	w.enc_begin(&e, "invited")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "id", one(r))
	locked_send(c, w.enc_done(&e))
}

locked_answer_invite :: proc(c: ^Conn, o: json.Object, rq: i64, accept: bool) {
	id := w.ostr(o, "id")
	if !is_uuid(id) {
		locked_err(c, rq, "not_found", "no such invite")
		return
	}
	r := locked_as(c, accept ? "select public.rtc_accept_invite($1)::text" : "select public.rtc_decline_invite($1)::text", id)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if accept {
		locked_as(c, "select public.rtc_seed_reads($1)", c.ident.id)
		locked_refresh_identity(c.ident.id)
	}
	for cc in srv.conns {
		if !cc.dead && cc.hello && cc.ident.id == c.ident.id {
			locked_lists(cc, 0, {.Invites})
		}
	}
	e: w.Enc
	w.enc_begin(&e, accept ? "accepted" : "declined")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "id", id)
	if accept {
		w.kv_str(&e, "space", one(r))
	}
	locked_send(c, w.enc_done(&e))
}

locked_remove :: proc(c: ^Conn, o: json.Object, rq: i64) {
	space := w.ostr(o, "space")
	if !is_uuid(space) {
		locked_err(c, rq, "not_found", "no such space")
		return
	}
	r := locked_as(
		c,
		"delete from public.rtc_members where space_id = $1 and handle = $2 returning identity_id::text",
		space,
		strings.trim_left(w.ostr(o, "handle"), "@"),
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if len(r.rows) == 0 {
		locked_err(c, rq, "forbidden", "no such member, or you may not remove them")
		return
	}
	locked_ack(c, rq, "removed_member", "")
}

locked_leave_space :: proc(c: ^Conn, o: json.Object, rq: i64) {
	space := w.ostr(o, "space")
	if !is_uuid(space) {
		locked_err(c, rq, "not_found", "no such space")
		return
	}
	r := locked_as(c, "delete from public.rtc_members where space_id = $1 and identity_id = $2 returning 1", space, c.ident.id)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	locked_refresh_identity(c.ident.id)
	locked_ack(c, rq, "left_space", "")
}

locked_part :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel")
		return
	}
	r := locked_as(c, "delete from public.rtc_channel_members where channel_id = $1 and identity_id = $2 returning 1", ch, c.ident.id)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	locked_refresh_identity(c.ident.id)
	locked_ack(c, rq, "parted", ch)
}

locked_dm :: proc(c: ^Conn, o: json.Object, rq: i64) {
	with := strings.to_lower(strings.trim_left(strings.trim_space(w.ostr(o, "with")), "@"), context.temp_allocator)
	space := w.ostr(o, "space")
	if !locked_begin(c.scope) {
		locked_err(c, rq, "unavailable", "the database is unavailable")
		return
	}
	if space == "" {
		space = one(db_q(
			&srv.db,
			"select t.space_id::text from public.rtc_members t join public.rtc_members m on m.space_id = t.space_id " +
			"where t.handle = $1 and m.identity_id = $2 order by m.joined_at limit 1",
			with,
			c.ident.id,
		))
	}
	r := Result{code = "42501", msg = "you share no space with that person"}
	if is_uuid(space) {
		r = db_q(
			&srv.db,
			"select public.rtc_open_dm($1, $2, (select identity_id from public.rtc_members where space_id = $1 and handle = $3))::text",
			space,
			c.ident.id,
			with,
		)
	}
	locked_finish(r.ok)
	if !r.ok || one(r) == "" {
		locked_db_err(c, rq, r)
		return
	}
	locked_as(c, "select public.rtc_seed_reads($1)", c.ident.id)
	locked_refresh_identity(c.ident.id)
	locked_ack(c, rq, "joined", one(r))
}

locked_join :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel, or it is not visible to this identity")
		return
	}
	locked_ack(c, rq, "joined", ch)
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

locked_post :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	text := w.ostr(o, "text")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel")
		return
	}
	if strings.trim_space(text) == "" {
		locked_err(c, rq, "empty", "a message needs some text")
		return
	}
	if len(text) > MAX_TEXT {
		locked_err(c, rq, "too_long", fmt.tprintf("a message is at most %d bytes", MAX_TEXT))
		return
	}
	thread, reply := w.oint(o, "thread"), w.oint(o, "reply_to")
	r := locked_as(
		c,
		"insert into public.rtc_messages (channel_id, identity_id, body, reply_to, thread_root) " +
		"values ($1, $2, $3, nullif($4, '0')::bigint, nullif($5, '0')::bigint) returning id::text",
		ch,
		c.ident.id,
		text,
		itoa(reply),
		itoa(thread),
		tag = w.ostr(o, "tag"),
	)
	if !r.ok {
		locked_db_err(c, rq, r, "no_channel")
		return
	}
	if rq != 0 {
		e: w.Enc
		w.enc_begin(&e, "posted")
		w.kv_int(&e, "rq", rq)
		w.kv_str(&e, "ch", ch)
		w.kv_raw(&e, "id", one(r))
		locked_send(c, w.enc_done(&e))
	}
}

itoa :: proc(v: i64) -> string {
	return fmt.tprintf("%d", v)
}

locked_history :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel")
		return
	}
	r := locked_as(
		c,
		"select public.rtc_history_json($1, $2, $3)::text",
		ch,
		itoa(w.oint(o, "before")),
		itoa(w.oint(o, "limit", 50)),
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	f := obj_frame("history", rq, one(r))
	// The channel goes in front: history's object has msgs and more.
	locked_send(c, strings.concatenate({f[:len(f) - 1], `,"ch":"`, ch, `"}`}, context.temp_allocator))
}

locked_thread :: proc(c: ^Conn, o: json.Object, rq: i64) {
	r := locked_as(c, "select public.rtc_thread_json($1, $2)::text", itoa(w.oint(o, "id")), itoa(w.oint(o, "limit", 120)))
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if one(r) == "" {
		locked_err(c, rq, "no_message", "no such message")
		return
	}
	locked_send(c, obj_frame("thread", rq, one(r)))
}

// locked_sync answers a reconnecting client: for every channel it names, the
// messages whose rev is above the one it last saw, in rev order, then
// `synced`. A channel it does not name is not touched; a channel it can no
// longer see is answered with `removed`.
locked_sync :: proc(c: ^Conn, o: json.Object, rq: i64) {
	lim := itoa(w.oint(o, "limit", 500))
	for v in w.oarr(o, "chs") {
		x, ok := w.as_obj(v)
		if !ok {
			continue
		}
		ch := w.ostr(x, "ch")
		if !(ch in c.visible) {
			locked_ack(c, 0, "removed", ch)
			continue
		}
		r := locked_as(c, "select public.rtc_changes_json($1, $2, $3)::text", ch, itoa(w.oint(x, "rev")), lim)
		if r.ok {
			locked_send(c, obj_frame("changes", rq, one(r)))
		}
	}
	locked_ack(c, rq, "synced", "")
}

locked_edit :: proc(c: ^Conn, o: json.Object, rq: i64) {
	text := w.ostr(o, "text")
	if strings.trim_space(text) == "" || len(text) > MAX_TEXT {
		locked_err(c, rq, "empty", "an edit needs some text")
		return
	}
	r := locked_as(
		c,
		"update public.rtc_messages set body = $2 where id = $1 and identity_id = $3 returning id",
		itoa(w.oint(o, "id")),
		text,
		c.ident.id,
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if len(r.rows) == 0 {
		locked_err(c, rq, "not_yours", "only the author can edit a message")
	}
}

locked_delete :: proc(c: ^Conn, o: json.Object, rq: i64) {
	r := locked_as(
		c,
		"update public.rtc_messages set deleted_at = now() where id = $1 and identity_id = $2 and deleted_at is null returning id",
		itoa(w.oint(o, "id")),
		c.ident.id,
	)
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	if len(r.rows) == 0 {
		locked_err(c, rq, "not_yours", "only the author can delete a message")
	}
}

locked_react :: proc(c: ^Conn, o: json.Object, rq: i64) {
	key := w.ostr(o, "key")
	valid := false
	for k in REACTION_KEYS {
		if k == key {
			valid = true
		}
	}
	if !valid {
		locked_err(c, rq, "bad_reaction", fmt.tprintf("no such reaction %q", key))
		return
	}
	id := itoa(w.oint(o, "id"))
	r: Result
	if w.obool(o, "on", true) {
		r = locked_as(
			c,
			"insert into public.rtc_reactions (message_id, identity_id, key) values ($1, $2, $3) on conflict do nothing",
			id,
			c.ident.id,
			key,
		)
	} else {
		r = locked_as(
			c,
			"delete from public.rtc_reactions where message_id = $1 and identity_id = $2 and key = $3",
			id,
			c.ident.id,
			key,
		)
	}
	if !r.ok {
		locked_db_err(c, rq, r, "no_message")
	}
}

locked_typing :: proc(c: ^Conn, o: json.Object) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "typing")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "nick", c.ident.handle)
	w.kv_str(&e, "name", c.ident.name)
	w.kv_bool(&e, "on", w.obool(o, "on", true))
	locked_broadcast(ch, w.enc_done(&e), c.id)
}

locked_presence :: proc(c: ^Conn, o: json.Object, rq: i64) {
	state := w.ostr(o, "state")
	if state != "online" && state != "away" {
		locked_err(c, rq, "bad_state", "a connected client is online or away")
		return
	}
	c.away = state == "away"
	locked_store_presence(c, state)
	locked_broadcast_presence(c.ident, state)
}

locked_store_presence :: proc(c: ^Conn, state: string) {
	locked_as(
		c,
		"insert into public.rtc_presence (identity_id, state) values ($1, $2) " +
		"on conflict (identity_id) do update set state = excluded.state, updated_at = now()",
		c.ident.id,
		state,
	)
}

locked_broadcast_presence :: proc(i: Ident, state: string) {
	e: w.Enc
	w.enc_begin(&e, "presence")
	w.kv_str(&e, "nick", i.handle)
	w.kv_str(&e, "id", i.id)
	w.kv_str(&e, "state", state)
	f := w.enc_done(&e)
	for cc in srv.conns {
		if cc.dead || !cc.hello {
			continue
		}
		if cc.ident.id == i.id || i.id in cc.peers {
			locked_send(cc, f)
		}
	}
}

locked_search :: proc(c: ^Conn, o: json.Object, rq: i64) {
	q := w.ostr(o, "q")
	r := locked_as(c, "select public.rtc_search_json($1, $2)::text", q, itoa(w.oint(o, "limit", 40)))
	if !r.ok {
		locked_db_err(c, rq, r)
		return
	}
	e: w.Enc
	w.enc_begin(&e, "results")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "q", q)
	w.kv_raw(&e, "msgs", one(r))
	locked_send(c, w.enc_done(&e))
}

// locked_read moves this identity's cursor, tells every connection of the
// identity, and tells the channel's other members where it now is: that is
// the read receipt.
locked_read :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel")
		return
	}
	if !locked_begin(c.scope) {
		locked_err(c, rq, "unavailable", "the database is unavailable")
		return
	}
	up := db_q(
		&srv.db,
		"insert into public.rtc_reads (channel_id, identity_id, message_id) values ($1, $2, $3) " +
		"on conflict (channel_id, identity_id) do update set message_id = excluded.message_id",
		ch,
		c.ident.id,
		itoa(w.oint(o, "id")),
	)
	r := db_q(&srv.db, "select public.rtc_read_json($1, $2)::text", ch, c.ident.id)
	locked_finish(up.ok && r.ok)
	if !up.ok || !r.ok {
		locked_db_err(c, rq, up.ok ? r : up)
		return
	}
	for cc in srv.conns {
		if cc.dead || !cc.hello || cc.ident.id != c.ident.id {
			continue
		}
		locked_send(cc, obj_frame("read", cc.id == c.id ? rq : 0, one(r)))
	}
	cur := w.ostr(o, "id")
	if v, ok := w.parse_obj(one(r), context.temp_allocator); ok {
		e: w.Enc
		w.enc_begin(&e, "receipt")
		w.kv_str(&e, "ch", ch)
		w.kv_str(&e, "nick", c.ident.handle)
		w.kv_str(&e, "who", c.ident.id)
		w.kv_int(&e, "id", w.oint(v, "id"))
		f := w.enc_done(&e)
		for cc in srv.conns {
			if !cc.dead && cc.hello && cc.ident.id != c.ident.id && ch in cc.visible {
				locked_send(cc, f)
			}
		}
	}
	_ = cur
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

locked_drop_staged :: proc(c: ^Conn, pre: ^Pre) {
	if pre.path == "" {
		return
	}
	cl := storage_client(c.token, c.claims.exp)
	ck.remove(cl, "rtc", {pre.path})
	delete(pre.path)
	pre.path = ""
}

locked_attach :: proc(c: ^Conn, o: json.Object, rq: i64, pre: ^Pre) {
	if pre.code != "" {
		locked_err(c, rq, pre.code, pre.why)
		return
	}
	ch := w.ostr(o, "ch")
	name := w.safe_filename(w.ostr(o, "name"), context.temp_allocator)
	text := w.ostr(o, "text")
	if len(text) > MAX_TEXT {
		text = text[:MAX_TEXT]
	}
	r := locked_as(
		c,
		"insert into public.rtc_messages (channel_id, identity_id, body, thread_root, attachment) " +
		"values ($1, $2, $3, nullif($4, '0')::bigint, jsonb_build_object('path', $5::text, 'name', $6::text, 'mime', $7::text, 'size', $8::bigint)) returning id",
		ch,
		c.ident.id,
		text,
		itoa(w.oint(o, "thread")),
		pre.path,
		name,
		clean_mime(w.ostr(o, "mime")),
		itoa(i64(pre.size)),
		tag = w.ostr(o, "tag"),
	)
	if !r.ok {
		locked_drop_staged(c, pre)
		locked_db_err(c, rq, r, "no_channel")
		return
	}
	note("%s attached %s (%d bytes) as #%s", c.ident.handle, name, pre.size, one(r))
	delete(pre.path)
	pre.path = ""
}

// locked_fetch finds the object through RLS (the message must be readable),
// then downloads it as the person, so Storage checks the channel as well.
locked_fetch :: proc(c: ^Conn, o: json.Object, rq: i64) {
	id := w.oint(o, "id")
	r := locked_as(
		c,
		"select attachment ->> 'path', attachment ->> 'name', attachment ->> 'mime' from public.rtc_messages " +
		"where id = $1 and attachment is not null and deleted_at is null",
		itoa(id),
	)
	if !r.ok || len(r.rows) == 0 {
		locked_err(c, rq, "no_file", "no attachment with that id")
		return
	}
	row := r.rows[0]
	data, e := ck.download_bytes(storage_client(c.token, c.claims.exp), "rtc", row[0], context.temp_allocator)
	if !ck.ok(e) {
		locked_err(c, rq, "no_file", fmt.tprintf("storage: %s", e.message))
		return
	}
	b64, _ := base64.encode(data, allocator = context.temp_allocator)
	f: w.Enc
	w.enc_begin(&f, "file")
	if rq != 0 {
		w.kv_int(&f, "rq", rq)
	}
	w.kv_int(&f, "id", id)
	w.kv_str(&f, "name", row[1])
	w.kv_str(&f, "mime", row[2])
	w.kv_int(&f, "size", i64(len(data)))
	w.kv_str(&f, "data", b64)
	locked_send(c, w.enc_done(&f))
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

// locked_call_join decides admission to a call, as the identity: Postgres
// checks it may post in the channel (rtc_calls_insert and
// rtc_call_participants_insert both go through rtc_identity_can_post). Only
// then is a token minted, for this identity and this call.
locked_call_join :: proc(c: ^Conn, o: json.Object, rq: i64) {
	ch := w.ostr(o, "ch")
	if !(ch in c.visible) {
		locked_err(c, rq, "no_channel", "no such channel")
		return
	}
	if !locked_begin(c.scope) {
		locked_err(c, rq, "unavailable", "the database is unavailable")
		return
	}
	started := false
	call := one(db_q(
		&srv.db,
		"select id::text from public.rtc_calls where channel_id = $1 and ended_at is null order by started_at desc limit 1",
		ch,
	))
	r := Result{ok = true}
	if call == "" {
		r = db_q(
			&srv.db,
			"insert into public.rtc_calls (channel_id, identity_id, sfu) values ($1, $2, $3) returning id::text",
			ch,
			c.ident.id,
			srv.sfu_addr,
		)
		call = one(r)
		started = true
	}
	if r.ok {
		r = db_q(
			&srv.db,
			"insert into public.rtc_call_participants (call_id, identity_id) select $1, $2 " +
			"where not exists (select 1 from public.rtc_call_participants p where p.call_id = $1 and p.identity_id = $2 and p.left_at is null)",
			call,
			c.ident.id,
		)
	}
	if !locked_finish(r.ok) {
		locked_db_err(c, rq, r)
		return
	}
	j := pcp.Join {
		call   = call,
		ch     = ch,
		id     = c.ident.id,
		handle = c.ident.handle,
		name   = c.ident.name,
		color  = c.ident.color,
		e2ee   = true,
	}
	token := pcp.token_mint(srv.secret, j, context.temp_allocator)
	e: w.Enc
	w.enc_begin(&e, "call_token")
	if rq != 0 {
		w.kv_int(&e, "rq", rq)
	}
	w.kv_str(&e, "call", call)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "sfu", srv.sfu_addr)
	w.kv_str(&e, "token", token)
	w.kv_int(&e, "exp", time.time_to_unix(time.now()) + pcp.TOKEN_TTL)
	w.kv_bool(&e, "e2ee", true)
	locked_send(c, w.enc_done(&e))
	if started {
		note("%s started call %s in %s", c.ident.handle, call[:8], ch[:8])
	}
	locked_broadcast_call(call)
}

locked_call_leave :: proc(c: ^Conn, o: json.Object, rq: i64) {
	call := w.ostr(o, "call")
	if !is_uuid(call) {
		locked_err(c, rq, "not_found", "no such call")
		return
	}
	locked_as(
		c,
		"update public.rtc_call_participants set left_at = now() where call_id = $1 and identity_id = $2 and left_at is null",
		call,
		c.ident.id,
	)
	locked_ack(c, rq, "call_left", "")
	locked_broadcast_call(call)
}

locked_broadcast_call :: proc(call: string) {
	r := db_q(
		&srv.db,
		"select public.rtc_call_json(id)::text, channel_id::text from public.rtc_calls where id = $1",
		call,
	)
	if !r.ok || len(r.rows) == 0 {
		return
	}
	locked_broadcast(r.rows[0][1], obj_frame("call", 0, r.rows[0][0]))
}

// --- the SFU's control link -------------------------------------------------

locked_sfu_hello :: proc(c: ^Conn, o: json.Object) {
	ts := w.oint(o, "ts")
	now := time.time_to_unix(time.now())
	want := pcp.sfu_hello_mac(srv.secret, ts)
	got := w.ostr(o, "mac")
	if abs(now - ts) > 30 || len(got) != len(want) ||
	   crypto.compare_constant_time(transmute([]u8)got, transmute([]u8)want) != 1 {
		locked_err(c, 0, "auth", "bad SFU credentials")
		return
	}
	c.is_sfu = true
	e: w.Enc
	w.enc_begin(&e, "sfu_welcome")
	locked_send(c, w.enc_done(&e))
	note("an SFU connected")
}

locked_sfu :: proc(c: ^Conn, t: string, o: json.Object) {
	call := w.ostr(o, "call")
	if !is_uuid(call) {
		return
	}
	switch t {
	case "sfu_room":
		ids := make([dynamic]string, context.temp_allocator)
		for v in w.oarr(o, "ids") {
			if s := w.as_str(v); is_uuid(s) {
				append(&ids, s)
			}
		}
		arr := strings.concatenate({"{", strings.join(ids[:], ",", context.temp_allocator), "}"}, context.temp_allocator)
		ch := one(db_q(&srv.db, "select channel_id::text from public.rtc_calls where id = $1", call))
		if ch == "" {
			return
		}
		db_q(
			&srv.db,
			"update public.rtc_call_participants set left_at = now() where call_id = $1 and left_at is null " +
			"and not (identity_id = any($2::uuid[]))",
			call,
			arr,
		)
		k := srv.calls[call] or_else nil
		if k == nil {
			k = new(Call)
			k.id = strings.clone(call)
			k.ch = strings.clone(ch)
			srv.calls[k.id] = k
		}
		for s in k.ids {
			delete(s)
		}
		clear(&k.ids)
		for s in ids {
			append(&k.ids, strings.clone(s))
		}
		locked_broadcast_call(call)
	case "sfu_end":
		db_q(&srv.db, "update public.rtc_calls set ended_at = now() where id = $1 and ended_at is null", call)
		db_q(&srv.db, "update public.rtc_call_participants set left_at = now() where call_id = $1 and left_at is null", call)
		if k, found := srv.calls[call]; found {
			delete_key(&srv.calls, call)
			for s in k.ids {
				delete(s)
			}
			delete(k.ids)
			delete(k.ch)
			delete(k.id)
			free(k)
		}
		locked_broadcast_call(call)
	case "sfu_speaker":
		if k, found := srv.calls[call]; found {
			e: w.Enc
			w.enc_begin(&e, "speaker")
			w.kv_str(&e, "ch", k.ch)
			w.kv_str(&e, "call", call)
			w.kv_str(&e, "id", w.ostr(o, "id"))
			locked_broadcast(k.ch, w.enc_done(&e))
		}
	}
}

// locked_recheck_calls asks Postgres, for every participant of every live
// call, whether that identity still has the channel. This runs as the
// gateway's own role, not as anyone's session: it reads membership rows
// directly, the same rows rtc_identity_can_post reads.
locked_recheck_calls :: proc() {
	for _, k in srv.calls {
		for id in k.ids {
			r := db_q(
				&srv.db,
				"select exists (select 1 from public.rtc_channels c " +
				"join public.rtc_members m on m.space_id = c.space_id and m.identity_id = $2 " +
				"where c.id = $1 and c.archived_at is null and ((c.kind = 'public' and m.role <> 'guest') " +
				"or exists (select 1 from public.rtc_channel_members cm where cm.channel_id = c.id and cm.identity_id = $2)))::text",
				k.ch,
				id,
			)
			if r.ok && one(r) == "false" {
				locked_sfu_kick(k.id, id)
			}
		}
	}
}

locked_sfu_kick :: proc(call, id: string) {
	e: w.Enc
	w.enc_begin(&e, "sfu_kick")
	w.kv_str(&e, "call", call)
	w.kv_str(&e, "id", id)
	f := w.enc_done(&e)
	for cc in srv.conns {
		if cc.is_sfu && !cc.dead {
			locked_send(cc, f)
		}
	}
	note("asked the SFU to remove %s from call %s", id[:8], call[:8])
}

// ---------------------------------------------------------------------------
// Connections leaving, boot
// ---------------------------------------------------------------------------

locked_gone :: proc(c: ^Conn) {
	if !c.hello || c.passive {
		return
	}
	n := (srv.online[c.ident.id] or_else 1) - 1
	if n > 0 {
		srv.online[c.ident.id] = n
		return
	}
	delete_key(&srv.online, c.ident.id)
	locked_store_presence(c, "offline")
	locked_broadcast_presence(c.ident, "offline")
	note("%s went offline", c.ident.handle)
}

locked_boot :: proc() {
	// Presence is a property of live connections, and there are none yet.
	db_q(&srv.db, "update public.rtc_presence set state = 'offline' where state <> 'offline'")
}

// ---------------------------------------------------------------------------
// Events, from the notification stream, in commit order
// ---------------------------------------------------------------------------

locked_event :: proc(o: json.Object) {
	k := w.ostr(o, "k")
	ch := w.ostr(o, "ch")
	id := w.oint(o, "id")
	rev := w.oint(o, "rev")
	switch k {
	case "resync":
		for cc in srv.conns {
			if cc.hello && !cc.dead {
				locked_ack(cc, 0, "resync", "")
			}
		}
	case "msg":
		m := one(db_q(&srv.db, "select public.rtc_msg_json(m)::text from public.rtc_messages m where m.id = $1", itoa(id)))
		if m == "" {
			return
		}
		e: w.Enc
		w.enc_begin(&e, "message")
		w.kv_raw(&e, "msg", m)
		if tag := w.ostr(o, "tag"); tag != "" {
			w.kv_str(&e, "tag", tag)
		}
		locked_broadcast(ch, w.enc_done(&e))
	case "edit":
		r := db_q(
			&srv.db,
			"select body, coalesce(extract(epoch from edited_at)::bigint, 0)::text from public.rtc_messages where id = $1",
			itoa(id),
		)
		if len(r.rows) == 0 {
			return
		}
		e: w.Enc
		w.enc_begin(&e, "edit")
		w.kv_int(&e, "id", id)
		w.kv_str(&e, "ch", ch)
		w.kv_str(&e, "text", r.rows[0][0])
		w.kv_raw(&e, "edited", r.rows[0][1])
		w.kv_int(&e, "rev", rev)
		locked_broadcast(ch, w.enc_done(&e))
	case "del":
		e: w.Enc
		w.enc_begin(&e, "delete")
		w.kv_int(&e, "id", id)
		w.kv_str(&e, "ch", ch)
		w.kv_int(&e, "rev", rev)
		locked_broadcast(ch, w.enc_done(&e))
	case "replies":
		r := db_q(
			&srv.db,
			"select m.replies::text, coalesce(extract(epoch from m.last_reply_at)::bigint, 0)::text, " +
			"coalesce((select r.author_handle from public.rtc_messages r where r.thread_root = m.id order by r.id desc limit 1), '') " +
			"from public.rtc_messages m where m.id = $1",
			itoa(id),
		)
		if len(r.rows) == 0 {
			return
		}
		e: w.Enc
		w.enc_begin(&e, "replies")
		w.kv_int(&e, "id", id)
		w.kv_str(&e, "ch", ch)
		w.kv_raw(&e, "n", r.rows[0][0])
		w.kv_raw(&e, "last_reply", r.rows[0][1])
		w.kv_str(&e, "nick", r.rows[0][2])
		w.kv_int(&e, "rev", rev)
		locked_broadcast(ch, w.enc_done(&e))
	case "react":
		e: w.Enc
		w.enc_begin(&e, "react")
		w.kv_int(&e, "id", id)
		w.kv_str(&e, "ch", ch)
		w.kv_str(&e, "key", w.ostr(o, "key"))
		w.kv_str(&e, "nick", w.ostr(o, "nick"))
		w.kv_bool(&e, "on", w.obool(o, "on"))
		w.kv_int(&e, "rev", rev)
		locked_broadcast(ch, w.enc_done(&e))
	case "channel", "member", "chmember":
		// Whoever this can concern: everyone in the space, the identity it
		// names, and anyone who could see the channel.
		space, who := w.ostr(o, "space"), w.ostr(o, "identity")
		hit := make([dynamic]string, context.temp_allocator)
		for cc in srv.conns {
			if cc.dead || !cc.hello {
				continue
			}
			if (space != "" && space in cc.spaces) || (who != "" && cc.ident.id == who) || (ch != "" && ch in cc.visible) {
				already := false
				for h in hit {
					if h == cc.ident.id {
						already = true
					}
				}
				if !already {
					append(&hit, cc.ident.id)
				}
			}
		}
		for ident in hit {
			locked_refresh_identity(ident)
		}
		// Calls follow access, whether or not the person has a chat window
		// open: anyone in a live call who can no longer post in its channel
		// is dropped from it.
		if k != "channel" && !w.obool(o, "on", true) {
			locked_recheck_calls()
		}
	case "invite":
		who := w.ostr(o, "identity")
		for cc in srv.conns {
			if !cc.dead && cc.hello && cc.ident.id == who {
				locked_lists(cc, 0, {.Invites})
			}
		}
	}
}

_ :: strconv.parse_int
