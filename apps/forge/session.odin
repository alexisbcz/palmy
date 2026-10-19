// The forge's core: every call the window and the command line make, in one
// place (session.odin, client.odin), so the two front ends cannot drift. Rows
// go to PostgREST directly with the caller's bearer token and row-level
// security decides; what needs the repository on disk goes to the forge
// server's JSON API with the same token.
//
// Who the caller is comes from apps/cloudkit's token store, shared with
// apps/accounts and every other Palmframe application:
//
//	FORGE_TOKEN=palmforge_...  a personal access token, exchanged at the
//	                           forge for a ten-minute session scoped to the
//	                           token's identity and confined to forge tables.
//	                           What an agent or a CI job should hold.
//	PALM_IDENTITY=<handle>     cloudkit's scoped session for that identity
//	(or --identity)            (minted by `accounts switch <handle>`). The
//	                           database sees palm_identity and shows nothing
//	                           of the account's other identities.
//	neither                    the person's own session (`accounts signin`),
//	                           which sees all of their identities.
//	no session at all          anonymous: public repositories only.
//
// The gateway is cloudkit's (PALM_CLOUD_URL, its config.json, or the
// default); API_URL and ANON_KEY override it. The forge server is FORGE_URL.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import ck "../cloudkit"
import wire "forge:wire"

DEFAULT_FORGE :: "http://127.0.0.1:58580"

Client :: struct {
	ck:             ^ck.Client,
	forge:          string,
	supa:           wire.Supa,
	bearer:         string, // what PostgREST, Storage and the forge see; "" is anonymous
	kind:           string, // "session" | "scoped" | "token" | "" (anonymous)
	scope:          string, // the identity handle a scoped session acts for
	email:          string,
	token_identity: string,
	token_scope:    string,
}

// client_open opens the caller's session. `scope` is the identity to act as
// ("" for the person's own session); there is no fallback from a scope to
// the unscoped session, so a scoped command cannot widen itself.
client_open :: proc(scope := "") -> (c: Client, err: string) {
	c.forge = os.get_env("FORGE_URL", context.allocator)
	if c.forge == "" {
		c.forge = DEFAULT_FORGE
	}
	tok := os.get_env("FORGE_TOKEN", context.allocator)
	cl, e := ck.open(url = os.get_env("API_URL", context.temp_allocator), anon_key = os.get_env("ANON_KEY", context.temp_allocator),
		scope = "" if tok != "" else scope, app = "forge")
	if !ck.ok(e) {
		return c, e.message
	}
	c.ck = cl
	c.supa = wire.Supa{cl.url_text, cl.anon_key}
	if tok != "" {
		return c, client_use_token(&c, tok)
	}
	if !ck.signed_in(cl) {
		if cl.scope != "" {
			return c, fmt.aprintf("no session for %q on this machine; run `accounts switch %s` first", cl.scope, cl.scope)
		}
		return c, "" // anonymous
	}
	if fe := ck.ensure_fresh(cl); !ck.ok(fe) {
		return c, fmt.aprintf("the session could not be refreshed (%s); sign in again with `accounts signin`", fe.message)
	}
	c.bearer = cl.session.access_token
	c.email = cl.session.email
	c.kind = "session"
	if cl.session.identity_id != "" {
		c.kind = "scoped"
		c.scope = cl.session.handle
	}
	return c, ""
}

// client_use_token exchanges a personal access token at the forge. The
// person's stored session is not read or touched.
client_use_token :: proc(c: ^Client, tok: string) -> string {
	h := []wire.Header{{"Authorization", fmt.tprintf("Bearer %s", tok)}}
	r := wire.request("POST", fmt.tprintf("%s/api/token/exchange", c.forge), h, nil)
	if r.status == 0 {
		return fmt.aprintf("the forge at %s is not reachable", c.forge)
	}
	if r.status != 200 {
		return "the token was refused (wrong, revoked or expired)"
	}
	c.bearer = wire.str(r.value, "access_token")
	c.token_identity = wire.str(r.value, "identity_id")
	c.token_scope = wire.str(r.value, "scope")
	c.kind = "token"
	return ""
}

my_identities :: proc(c: ^Client) -> wire.Result {
	if c.bearer == "" {
		return {status = 200, value = json.Array{}}
	}
	return wire.rpc(c.supa, c.bearer, "forge_my_identities")
}

// identity_by_handle finds one of the identities this session can act as.
identity_by_handle :: proc(c: ^Client, handle: string) -> (json.Value, bool) {
	r := my_identities(c)
	for row in wire.arr(r.value) {
		if wire.str(row, "handle") == handle {
			return row, true
		}
	}
	return nil, false
}
