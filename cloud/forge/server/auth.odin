package main

// Who is calling, and with what session the database should see them.
//
// The server never decides access itself. It turns the request's credentials
// into a bearer token and forwards that token to PostgREST and Storage, where
// row-level security decides. Three cases:
//
//	no credentials          the anon key: public repositories only
//	a Supabase access token the person's own session (Bearer, or the password
//	                        of HTTP Basic), passed through untouched; PostgREST
//	                        verifies it
//	a personal access token `palmforge_...` (Bearer, or Basic password or
//	                        username), exchanged through forge_token_resolve
//	                        for a short JWT the server signs: role forge_pat,
//	                        palm_identity = the token's identity, forge_token =
//	                        the token id. The database re-checks the token row
//	                        on every statement, so revocation is immediate.
//
// An account password is never accepted over Basic auth: git credential
// helpers store whatever they are given, and the thing they store should be a
// revocable, scoped token, not the key to every identity of the account.

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"
import wire "forge:wire"

Auth_Kind :: enum {
	Anonymous,
	Session,
	Token,
}

Caller :: struct {
	kind:     Auth_Kind,
	bearer:   string, // what PostgREST and Storage see
	scope:    string, // token scope, "" for sessions
	identity: string, // token identity, "" for sessions
	token_id: string,
}

TOKEN_PREFIX :: "palmforge_"
TOKEN_TTL :: 10 * 60 // seconds; a git operation, or a CLI command, fits

b64url :: proc(data: []u8) -> string {
	s := base64.encode(data, base64.ENC_URL_TABLE, context.temp_allocator)
	return strings.trim_right(s, "=")
}

// mint_token signs a forge_pat session for one identity with the project's
// JWT secret (HS256). PostgREST and Storage accept it alongside GoTrue's own
// tokens.
mint_token :: proc(secret, user_id, identity_id, token_id: string, ttl := TOKEN_TTL) -> string {
	now := time.time_to_unix(time.now())
	head := `{"alg":"HS256","typ":"JWT"}`
	body := fmt.tprintf(
		`{{"iss":"palmforge","sub":%s,"aud":"authenticated","role":"forge_pat","palm_identity":%s,"forge_token":%s,"iat":%d,"exp":%d}}`,
		wire.q(user_id),
		wire.q(identity_id),
		wire.q(token_id),
		now,
		now + i64(ttl),
	)
	signing := fmt.tprintf("%s.%s", b64url(transmute([]u8)head), b64url(transmute([]u8)body))
	mac: [32]u8
	hmac.sum(hash.Algorithm.SHA256, mac[:], transmute([]u8)signing, transmute([]u8)secret)
	return fmt.tprintf("%s.%s", signing, b64url(mac[:]))
}

looks_like_jwt :: proc(s: string) -> bool {
	return strings.count(s, ".") == 2 && strings.has_prefix(s, "eyJ")
}

// exchange resolves a personal access token. False when it is wrong,
// revoked or expired.
exchange :: proc(token: string) -> (Caller, bool) {
	r := wire.rpc(cfg.supa, "", "forge_token_resolve", fmt.tprintf(`{{"presented":%s}}`, wire.q(token)))
	row, found := wire.first(r.value)
	if !wire.ok(r) || !found {
		return {}, false
	}
	c := Caller {
		kind     = .Token,
		scope    = wire.str(row, "scope"),
		identity = wire.str(row, "identity_id"),
		token_id = wire.str(row, "token_id"),
	}
	c.bearer = mint_token(cfg.jwt_secret, wire.str(row, "owner"), c.identity, c.token_id)
	return c, true
}

// authenticate reads the Authorization header. `bad` is true when
// credentials were presented and are not acceptable (401).
authenticate :: proc(req: ^Request) -> (c: Caller, bad: bool) {
	h := wire.header_get(req.headers, "authorization")
	if h == "" {
		return Caller{kind = .Anonymous}, false
	}
	secret := ""
	if v, ok := wire.cut_prefix(h, "Bearer "); ok {
		secret = strings.trim_space(v)
	} else if v2, ok2 := wire.cut_prefix(h, "Basic "); ok2 {
		raw, err := base64.decode(strings.trim_space(v2), allocator = context.temp_allocator)
		if err != nil {
			return {}, true
		}
		user, _, pass := strings.partition(string(raw), ":")
		secret = pass if pass != "" else user
	} else {
		return {}, true
	}
	if strings.has_prefix(secret, TOKEN_PREFIX) {
		tc, ok := exchange(secret)
		return tc, !ok
	}
	if looks_like_jwt(secret) {
		return Caller{kind = .Session, bearer = secret}, false
	}
	return {}, true
}

challenge :: proc() -> []wire.Header {
	h := make([]wire.Header, 1, context.temp_allocator)
	h[0] = {"WWW-Authenticate", `Basic realm="Palmframe forge (use a personal access token)"`}
	return h
}
