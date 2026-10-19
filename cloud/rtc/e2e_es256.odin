package main

// ES256 verification, offline. The cloud/dev stack signs HS256, so the path a
// production project (and Supabase CLI 2.118) takes — an ES256 token checked
// against a key from the JWKS — is exercised here with a key made for the
// test: one good token, then each way it must fail.

import "core:crypto/ecdsa"
import "core:fmt"
import "core:strings"
import "core:time"
import "pcp"

es256_checks :: proc() {
	section("token verification: ES256 against a JWKS key, as Supabase CLI and production sign")
	priv: ecdsa.Private_Key
	if !ecdsa.private_key_generate(&priv, .SECP256R1) {
		check(false, "generate a P-256 key")
		return
	}
	pub_bytes: [65]u8
	ecdsa.private_key_public_bytes(&priv, pub_bytes[:])
	k := Jwk{kid = "e2e-kid"}
	if !ecdsa.public_key_set_bytes(&k.key, .SECP256R1, pub_bytes[:]) {
		check(false, "load the public key")
		return
	}
	append(&jwks, k)

	mint :: proc(priv: ^ecdsa.Private_Key, kid: string, exp: i64, role := "authenticated") -> string {
		header := strings.concatenate({`{"alg":"ES256","typ":"JWT","kid":"`, kid, `"}`}, context.temp_allocator)
		payload := strings.concatenate({
			`{"sub":"7a3b2c1d-0000-4000-8000-000000000001","role":"`, role,
			`","aud":"authenticated","exp":`, fmt.tprint(exp), `,"palm_identity":"7a3b2c1d-0000-4000-8000-0000000000aa"}`,
		}, context.temp_allocator)
		signing := strings.concatenate({
			pcp.b64url_encode(transmute([]u8)header, context.temp_allocator), ".",
			pcp.b64url_encode(transmute([]u8)payload, context.temp_allocator),
		}, context.temp_allocator)
		sig: [64]u8
		_ = ecdsa.sign_raw(priv, .SHA256, transmute([]u8)signing, sig[:])
		return strings.concatenate({signing, ".", pcp.b64url_encode(sig[:], context.temp_allocator)}, context.temp_allocator)
	}

	now := time.time_to_unix(time.now())
	good := mint(&priv, "e2e-kid", now + 600)
	cl, err := jwt_verify(good, "")
	check(err == "" && cl.palm_identity == "7a3b2c1d-0000-4000-8000-0000000000aa", "an ES256 token signed by a JWKS key verifies, palm_identity intact %s", err)
	parts := strings.split(good, ".", context.temp_allocator)
	forged := strings.concatenate({
		parts[0], ".",
		pcp.b64url_encode(transmute([]u8)string(`{"sub":"7a3b2c1d-0000-4000-8000-000000000001","role":"authenticated","exp":9999999999}`), context.temp_allocator),
		".", parts[2],
	}, context.temp_allocator)
	_, e2 := jwt_verify(forged, "")
	check(e2 == "bad signature", "the same signature over a widened payload (palm_identity dropped) fails: %s", e2)
	_, e3 := jwt_verify(mint(&priv, "unknown-kid", now + 600), "")
	check(e3 == "unknown signing key", "a key id the JWKS does not have fails: %s", e3)
	_, e4 := jwt_verify(mint(&priv, "e2e-kid", now - 10), "")
	check(e4 == "token expired", "an expired token fails: %s", e4)
	_, e5 := jwt_verify(mint(&priv, "e2e-kid", now + 600, "service_role"), "")
	check(e5 != "", "a validly signed service-role token is still not a person: %s", e5)
}
