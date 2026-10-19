package main

// Verifying a Palmy account token.
//
// Two signing schemes are in use, and the gateway accepts both:
//
//   * ES256, with the key published at /auth/v1/.well-known/jwks.json. This is
//     what Supabase CLI 2.118 issues, and the shape a production project has.
//     The gateway holds only public keys, so it can verify a token and can
//     never make one.
//   * HS256 with the project's JWT secret (--jwt-secret / RTC_JWT_SECRET).
//     cloud/dev signs this way. A gateway holding that secret could forge
//     tokens, which is why it is optional and why ES256 is preferred.
//
// Only `role: authenticated` tokens are accepted. The anon key and the
// service-role key are both refused: neither is a person.

import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/json"
import "core:strings"
import "core:time"
import ck "../../apps/cloudkit"
import "pcp"

Jwk :: struct {
	kid: string,
	key: ecdsa.Public_Key,
}

Claims :: struct {
	sub:           string,
	role:          string,
	email:         string,
	session_id:    string,
	palm_identity: string, // "" for the person's own, unscoped session
	exp:           i64,
}

jwks: [dynamic]Jwk
jwt_secret: string

// jwks_load fetches the project's public keys. Called at startup, and again
// (at most every 30 s) when a token names a key id we do not have.
jwks_last_try: i64

jwks_load :: proc(api_url: string) -> (n: int, err: string) {
	jwks_last_try = time.time_to_unix(time.now())
	u, ok := ck.parse_url(api_url)
	if !ok {
		return 0, "bad --api URL"
	}
	resp, herr := ck.http_do(u, ck.Request{method = "GET", path = "/auth/v1/.well-known/jwks.json", timeout_ms = 5000})
	defer ck.response_destroy(&resp)
	if herr != "" {
		return 0, herr
	}
	if resp.status != 200 {
		return 0, "jwks: unexpected status"
	}
	v, perr := json.parse(transmute([]u8)resp.body, allocator = context.temp_allocator)
	if perr != nil {
		return 0, "jwks: not JSON"
	}
	keys, _ := v.(json.Object)["keys"].(json.Array)
	for k in keys {
		o, is := k.(json.Object)
		if !is {
			continue
		}
		if jstr(o, "kty") != "EC" || jstr(o, "crv") != "P-256" {
			continue
		}
		x, okx := pcp.b64url_decode(jstr(o, "x"), context.temp_allocator)
		y, oky := pcp.b64url_decode(jstr(o, "y"), context.temp_allocator)
		if !okx || !oky || len(x) != 32 || len(y) != 32 {
			continue
		}
		pt: [65]u8
		pt[0] = 0x04
		copy(pt[1:33], x)
		copy(pt[33:65], y)
		j := Jwk{kid = strings.clone(jstr(o, "kid"))}
		if !ecdsa.public_key_set_bytes(&j.key, .SECP256R1, pt[:]) {
			continue
		}
		replaced := false
		for &have in jwks {
			if have.kid == j.kid {
				have = j
				replaced = true
			}
		}
		if !replaced {
			append(&jwks, j)
		}
		n += 1
	}
	return n, ""
}

jwt_verify :: proc(token: string, api_url: string) -> (c: Claims, err: string) {
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 || len(token) > 8192 {
		return c, "not a JWT"
	}
	hraw, ok1 := pcp.b64url_decode(parts[0], context.temp_allocator)
	sig, ok2 := pcp.b64url_decode(parts[2], context.temp_allocator)
	praw, ok3 := pcp.b64url_decode(parts[1], context.temp_allocator)
	if !ok1 || !ok2 || !ok3 {
		return c, "not a JWT"
	}
	hv, he := json.parse(hraw, allocator = context.temp_allocator)
	if he != nil {
		return c, "not a JWT"
	}
	ho, _ := hv.(json.Object)
	signing := transmute([]u8)token[:len(parts[0]) + 1 + len(parts[1])]

	switch jstr(ho, "alg") {
	case "ES256":
		kid := jstr(ho, "kid")
		key := find_jwk(kid)
		if key == nil && time.time_to_unix(time.now()) - jwks_last_try > 30 && api_url != "" {
			jwks_load(api_url)
			key = find_jwk(kid)
		}
		if key == nil {
			return c, "unknown signing key"
		}
		if !ecdsa.verify_raw(key, .SHA256, signing, sig) {
			return c, "bad signature"
		}
	case "HS256":
		if jwt_secret == "" {
			return c, "HS256 tokens are not accepted by this gateway"
		}
		if len(sig) != 32 || !hmac.verify(.SHA256, sig, signing, transmute([]u8)jwt_secret) {
			return c, "bad signature"
		}
	case:
		return c, "unsupported JWT algorithm"
	}

	pv, pe := json.parse(praw, allocator = context.temp_allocator)
	if pe != nil {
		return c, "JWT payload is not JSON"
	}
	po, _ := pv.(json.Object)
	c.sub = strings.clone(jstr(po, "sub"))
	c.role = strings.clone(jstr(po, "role"))
	c.email = strings.clone(jstr(po, "email"))
	c.session_id = strings.clone(jstr(po, "session_id"))
	c.palm_identity = strings.clone(jstr(po, "palm_identity"))
	#partial switch e in po["exp"] {
	case json.Integer:
		c.exp = i64(e)
	case json.Float:
		c.exp = i64(e)
	}
	if c.role != "authenticated" || c.sub == "" {
		return c, "only a signed-in person's token is accepted"
	}
	if c.exp == 0 || c.exp < time.time_to_unix(time.now()) {
		return c, "token expired"
	}
	if c.palm_identity != "" && !is_uuid(c.palm_identity) {
		return c, "palm_identity is not a uuid"
	}
	if !is_uuid(c.sub) {
		return c, "sub is not a uuid"
	}
	return c, ""
}

find_jwk :: proc(kid: string) -> ^ecdsa.Public_Key {
	for &k in jwks {
		if k.kid == kid {
			return &k.key
		}
	}
	return nil
}

_ :: hash.Algorithm

jstr :: proc(o: json.Object, k: string) -> string {
	if s, ok := o[k].(json.String); ok {
		return string(s)
	}
	return ""
}

is_uuid :: proc(s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for i in 0 ..< 36 {
		ch := s[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if ch != '-' {
				return false
			}
			continue
		}
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
			return false
		}
	}
	return true
}
