package web

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:time"

// mint_jwt signs an HS256 token with the project's JWT secret.
//
// The DAV server mints exactly one kind: a short-lived token for one
// identity, after an app password checked out. It carries the same claims a
// GoTrue session scoped by the accounts area carries (sub, role, aud,
// palm_identity), so PostgREST and RLS cannot tell it from one — which is the
// point: the database, not this server, decides what it may touch.
mint_jwt :: proc(secret: string, sub, identity: string, ttl_secs: i64, extra_claim := "", allocator := context.allocator) -> string {
	now := time.time_to_unix(time.now())
	header := `{"alg":"HS256","typ":"JWT"}`
	pb := strings.builder_make(context.temp_allocator)
	strings.write_string(&pb, `{"sub":`)
	json_string(&pb, sub)
	strings.write_string(&pb, `,"role":"authenticated","aud":"authenticated","iss":"palmframe-dav","palm_identity":`)
	json_string(&pb, identity)
	strings.write_string(&pb, `,"iat":`)
	strings.write_i64(&pb, now)
	strings.write_string(&pb, `,"exp":`)
	strings.write_i64(&pb, now + ttl_secs)
	if extra_claim != "" {
		strings.write_byte(&pb, ',')
		strings.write_string(&pb, extra_claim)
	}
	strings.write_byte(&pb, '}')
	h64 := b64url(transmute([]u8)header)
	p64 := b64url(transmute([]u8)strings.to_string(pb))
	signing := strings.concatenate({h64, ".", p64}, context.temp_allocator)
	mac: [32]u8
	hmac.sum(hash.Algorithm.SHA256, mac[:], transmute([]u8)signing, transmute([]u8)secret)
	return strings.concatenate({signing, ".", b64url(mac[:])}, allocator)
}

b64url :: proc(data: []u8) -> string {
	enc := base64.encode(data, base64.ENC_URL_TABLE, context.temp_allocator)
	return strings.trim_right(enc, "=")
}

// jwt_claims decodes a token's payload without verifying it. Only for
// reading the caller's own claims (sub, palm_identity, exp); PostgREST does
// the verifying.
jwt_claims :: proc(token: string) -> (json.Object, bool) {
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 {
		return nil, false
	}
	p := parts[1]
	for len(p) % 4 != 0 {
		p = strings.concatenate({p, "="}, context.temp_allocator)
	}
	raw, err := base64.decode(p, base64.DEC_URL_TABLE, allocator = context.temp_allocator)
	if err != nil {
		return nil, false
	}
	v, jerr := json.parse(raw, allocator = context.temp_allocator)
	if jerr != nil {
		return nil, false
	}
	obj, ok := v.(json.Object)
	return obj, ok
}
