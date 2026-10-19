package client

// The account side of a collaborative window: which person is signed in
// (cloudkit's token store), which identity this window acts as, and the
// document calls that go straight to PostgREST rather than through the sync
// server — creating, listing, sharing, history.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ck "../../../apps/cloudkit"

Account :: struct {
	c:  ^ck.Client,
	me: ck.Identity,
}

// account_open opens the token store and settles the identity: a scoped
// session (PALM_IDENTITY) is its identity and nothing else; an unscoped one
// acts as `handle`, or as the identity last switched to.
account_open :: proc(dir := "", handle := "") -> (a: Account, err: string) {
	c, e := ck.open(dir = dir, app = "collab")
	if !ck.ok(e) {
		return {}, fmt.aprintf("cannot open the account: %s", e.message)
	}
	a.c = c
	if !ck.signed_in(c) {
		return a, "not signed in (sign in with the Accounts app or `palm-collab-cli signin`)"
	}
	if fe := ck.ensure_fresh(c); !ck.ok(fe) {
		return a, fmt.aprintf("the session could not be refreshed: %s", fe.message)
	}
	ids, ie := ck.identities(c)
	if !ck.ok(ie) {
		return a, fmt.aprintf("cannot list identities: %s", ie.message)
	}
	want := handle
	if want == "" {
		want = ck.current_identity(c, context.temp_allocator)
	}
	if c.session.identity_id != "" {
		want = c.session.identity_id
	}
	if want == "" && len(ids) > 0 {
		want = ids[0].handle
	}
	found, ok := ck.find_identity(ids, want)
	if !ok {
		return a, fmt.aprintf("no identity %q on this account", want)
	}
	a.me = found
	return a, ""
}

account_token :: proc(a: ^Account) -> string {
	_ = ck.ensure_fresh(a.c)
	return a.c.session.access_token
}

// server_address reads PALM_COLLAB_URL (ws://host:port), defaulting to the
// local development server.
server_address :: proc() -> (host: string, port: int) {
	u := os.get_env("PALM_COLLAB_URL", context.temp_allocator)
	if u == "" {
		return "127.0.0.1", 8790
	}
	rest := u
	if strings.has_prefix(rest, "ws://") {
		rest = rest[5:]
	}
	if i := strings.index_byte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	host = rest
	port = 80
	if i := strings.last_index_byte(rest, ':'); i >= 0 {
		host = rest[:i]
		p, ok := strconv.parse_int(rest[i + 1:])
		if ok {port = p}
	}
	return strings.clone(host), port
}

// doc_create makes a new document owned by the account's identity.
doc_create :: proc(a: ^Account, kind, title: string) -> (id: string, err: string) {
	o := ck.obj()
	ck.put(&o, "identity_id", a.me.id)
	ck.put(&o, "kind", kind)
	ck.put(&o, "title", title)
	v, e := ck.insert(a.c, "collab_documents", ck.obj_done(&o))
	defer ck.value_destroy(v)
	if !ck.ok(e) {
		return "", fmt.aprintf("cannot create: %s", e.message)
	}
	arr := ck.array(v)
	if len(arr) == 0 {
		return "", "the server returned nothing"
	}
	return strings.clone(ck.get_str(arr[0], "id")), ""
}

doc_share :: proc(a: ^Account, doc, handle, role: string) -> string {
	o := ck.obj()
	ck.put(&o, "p_doc", doc)
	ck.put(&o, "p_handle", handle)
	ck.put(&o, "p_role", role)
	v, e := ck.rpc(a.c, "collab_share", ck.obj_done(&o))
	ck.value_destroy(v)
	if !ck.ok(e) {
		return fmt.aprintf("cannot share: %s", e.message)
	}
	return ""
}

doc_revoke :: proc(a: ^Account, doc, grantee_id: string) -> string {
	v, e := ck.update(
		a.c,
		"collab_grants",
		fmt.tprintf("doc_id=eq.%s&grantee_identity=eq.%s&revoked_at=is.null", doc, grantee_id),
		`{"revoked_at":"now()"}`,
	)
	ck.value_destroy(v)
	if !ck.ok(e) {
		return fmt.aprintf("cannot revoke: %s", e.message)
	}
	return ""
}

Grant :: struct {
	grantee: string,
	handle:  string,
	name:    string,
	color:   string,
	role:    string,
}

// doc_grants lists live grants on a document (the owner sees them all).
doc_grants :: proc(a: ^Account, doc: string, allocator := context.allocator) -> (out: [dynamic]Grant, err: string) {
	v, e := ck.select(
		a.c,
		"collab_grants",
		fmt.tprintf("select=grantee_identity,role&doc_id=eq.%s&revoked_at=is.null", doc),
	)
	defer ck.value_destroy(v)
	if !ck.ok(e) {
		return nil, fmt.aprintf("%s", e.message)
	}
	out = make([dynamic]Grant, allocator)
	for g in ck.array(v) {
		append(&out, Grant{grantee = strings.clone(ck.get_str(g, "grantee_identity"), allocator), role = strings.clone(ck.get_str(g, "role"), allocator)})
	}
	return out, ""
}

doc_make_link :: proc(a: ^Account, doc, role: string) -> (token: string, err: string) {
	o := ck.obj()
	ck.put(&o, "p_doc", doc)
	ck.put(&o, "p_role", role)
	v, e := ck.rpc(a.c, "collab_make_link", ck.obj_done(&o))
	defer ck.value_destroy(v)
	if !ck.ok(e) {
		return "", fmt.aprintf("cannot make a link: %s", e.message)
	}
	if s, ok := v.(json.String); ok {
		return strings.clone(s), ""
	}
	return "", "unexpected reply"
}

// rpc_raw calls a function and returns the parsed value; the caller frees it.
rpc_raw :: proc(a: ^Account, fn, args: string) -> (v: ck.Value, err: string) {
	r, e := ck.rpc(a.c, fn, args)
	if !ck.ok(e) {
		return nil, fmt.aprintf("%s", e.message)
	}
	return r, ""
}
