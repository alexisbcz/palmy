package main

// Supabase access tokens: HS256 JWTs.
//
// The server verifies a bearer token itself (signature and expiry) before it
// does anything with it, and then passes the same token through to PostgREST,
// which verifies it again and runs every query as that session — so RLS, and
// can_access_identity in particular, decides what the token can see. The
// server's own check exists so that an unauthenticated request is turned away
// at the door with a 401 rather than discovered as an empty mailbox.
//
// GAP: hosted Supabase projects are moving to asymmetric signing keys (ES256,
// published as a JWKS). This verifies HS256 with the project's shared secret
// only. apps/cloudkit, when it lands, is the place for a JWKS verifier.

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

Claims :: struct {
	sub:           string,
	role:          string,
	email:         string,
	palm_identity: string, // the identity a scoped session is limited to
	exp:           i64,
}

b64url_encode :: proc(data: []u8) -> string {
	s := base64.encode(data, base64.ENC_URL_TABLE, context.temp_allocator)
	return strings.trim_right(s, "=")
}

b64url_decode :: proc(s: string) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '-':
			strings.write_byte(&sb, '+')
		case '_':
			strings.write_byte(&sb, '/')
		case:
			strings.write_byte(&sb, s[i])
		}
	}
	return mm_b64_decode(transmute([]u8)strings.to_string(sb), context.temp_allocator)
}

// jwt_verify checks an HS256 token against `secret` and returns its claims.
jwt_verify :: proc(token, secret: string) -> (c: Claims, err: string) {
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 {
		return c, "not a JWT"
	}
	header := b64url_decode(parts[0])
	hv, he := json.parse(header, .JSON, true, context.temp_allocator)
	if he != nil || jstr(hv, "alg") != "HS256" {
		return c, "unsupported JWT algorithm (HS256 only)"
	}
	signing := token[:len(parts[0]) + 1 + len(parts[1])]
	want: [32]u8
	hmac.sum(.SHA256, want[:], transmute([]u8)signing, transmute([]u8)secret)
	got := b64url_decode(parts[2])
	if len(got) != 32 || !hmac.verify(.SHA256, got, transmute([]u8)signing, transmute([]u8)secret) {
		return c, "bad JWT signature"
	}
	payload := b64url_decode(parts[1])
	pv, pe := json.parse(payload, .JSON, true, context.temp_allocator)
	if pe != nil {
		return c, "JWT payload is not JSON"
	}
	c.sub = jstr(pv, "sub")
	c.role = jstr(pv, "role")
	c.email = jstr(pv, "email")
	c.palm_identity = jstr(pv, "palm_identity")
	c.exp = jint(pv, "exp")
	now := time.time_to_unix(time.now())
	if c.exp != 0 && c.exp < now {
		return c, "JWT expired"
	}
	if c.palm_identity != "" && !is_uuid(c.palm_identity) {
		return c, "palm_identity is not a uuid"
	}
	return c, ""
}

// jwt_mint signs a token. Used for the server's own service-role token and by
// the `mint` dev command, which makes the scoped tokens the accounts area
// will eventually issue through a custom access token hook.
jwt_mint :: proc(secret: string, sub, role, identity: string, ttl: i64 = 3600, allocator := context.allocator) -> string {
	now := time.time_to_unix(time.now())
	header := `{"alg":"HS256","typ":"JWT"}`
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"role":%s,"iat":%d,"exp":%d,"aud":"authenticated"`, jq(role), now, now + ttl)
	if sub != "" {
		fmt.sbprintf(&sb, `,"sub":%s`, jq(sub))
	}
	if identity != "" {
		fmt.sbprintf(&sb, `,"palm_identity":%s`, jq(identity))
	}
	strings.write_byte(&sb, '}')
	signing := strings.concatenate(
		{b64url_encode(transmute([]u8)string(header)), ".", b64url_encode(transmute([]u8)strings.to_string(sb))},
		context.temp_allocator,
	)
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], transmute([]u8)signing, transmute([]u8)secret)
	return strings.concatenate({signing, ".", b64url_encode(mac[:])}, allocator)
}

sha256_hex :: proc(data: []u8) -> string {
	d: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data, d[:])
	sb := strings.builder_make(context.temp_allocator)
	for b in d {
		fmt.sbprintf(&sb, "%02x", b)
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// json.Value accessors
// ---------------------------------------------------------------------------

jget :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, is := v.(json.Object)
	if !is {
		return nil, false
	}
	e, has := o[key]
	return e, has
}

jstr :: proc(v: json.Value, key: string) -> string {
	e, ok := jget(v, key)
	if !ok {
		return ""
	}
	if s, is := e.(json.String); is {
		return string(s)
	}
	return ""
}

jint :: proc(v: json.Value, key: string) -> i64 {
	e, ok := jget(v, key)
	if !ok {
		return 0
	}
	#partial switch t in e {
	case json.Integer:
		return i64(t)
	case json.Float:
		return i64(t)
	}
	return 0
}

jbool :: proc(v: json.Value, key: string) -> bool {
	e, ok := jget(v, key)
	if !ok {
		return false
	}
	if b, is := e.(json.Boolean); is {
		return bool(b)
	}
	return false
}

jarr :: proc(v: json.Value, key: string) -> json.Array {
	e, ok := jget(v, key)
	if !ok {
		return nil
	}
	if a, is := e.(json.Array); is {
		return a
	}
	return nil
}

jstrs :: proc(v: json.Value, key: string) -> []string {
	a := jarr(v, key)
	out := make([dynamic]string, 0, len(a), context.temp_allocator)
	for e in a {
		if s, is := e.(json.String); is {
			append(&out, string(s))
		}
	}
	return out[:]
}

jas :: proc(v: json.Value) -> string {
	if s, is := v.(json.String); is {
		return string(s)
	}
	return ""
}
