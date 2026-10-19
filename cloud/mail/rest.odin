package main

// PostgREST access, as the caller.
//
// Every read and write on behalf of a person goes through PostgREST with
// THAT PERSON'S token, so Postgres runs it as the `authenticated` role with
// their claims, and row-level security — can_access_identity — decides what
// it touches. The server never holds a connection that can see more than the
// caller can, except for the one MX entry point (`mail_deliver`), which it
// calls with a service-role token and which is a definer function that only
// ever inserts into inboxes.
//
// REPLACE WITH apps/cloudkit: this file is the server's private, minimal
// Supabase client (PostgREST and GoTrue over loopback HTTP). The accounts
// area is writing apps/cloudkit as the shared Odin client for auth,
// PostgREST and Storage; once it exists, `rest_call`, `rest_rpc` and
// `auth_password_grant` become calls into it, and nothing above this file
// needs to change.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Rest_Result :: struct {
	status:  int,
	headers: [][2]string,
	body:    []u8,
	value:   json.Value,
	code:   string, // the Postgres SQLSTATE PostgREST reports on failure
	err:    string,
}

rest_ok :: proc(r: Rest_Result) -> bool {
	return r.err == "" && r.status >= 200 && r.status < 300
}

rest_call :: proc(token, method, path: string, body := "", prefer := "") -> (r: Rest_Result) {
	headers := make([dynamic][2]string, 0, 6, context.temp_allocator)
	append(&headers, [2]string{"Authorization", strings.concatenate({"Bearer ", token}, context.temp_allocator)})
	append(&headers, [2]string{"Accept", "application/json"})
	if body != "" {
		append(&headers, [2]string{"Content-Type", "application/json"})
	}
	if prefer != "" {
		append(&headers, [2]string{"Prefer", prefer})
	}
	resp, err := http_call(cfg.rest_port, method, path, headers[:], transmute([]u8)body)
	if err != "" {
		r.err = fmt.tprintf("postgrest: %s", err)
		return
	}
	r.status = resp.status
	r.headers = resp.headers
	r.body = resp.body
	if len(resp.body) > 0 {
		v, pe := json.parse(resp.body, .JSON, true, context.temp_allocator)
		if pe == nil {
			r.value = v
		}
	}
	if resp.status >= 300 {
		r.code = jstr(r.value, "code")
		msg := jstr(r.value, "message")
		if msg == "" {
			msg = string(resp.body)
		}
		r.err = fmt.tprintf("postgrest %d %s: %s", resp.status, r.code, msg)
	}
	if cfg.trace {
		fmt.eprintfln("[rest] %s %s -> %d", method, path, resp.status)
	}
	return
}

rest_get :: proc(token, path: string) -> Rest_Result {
	return rest_call(token, "GET", path)
}

rest_rpc :: proc(token, fn: string, args: string) -> Rest_Result {
	return rest_call(token, "POST", strings.concatenate({"/rpc/", fn}, context.temp_allocator), args)
}

// bytea comes back from PostgREST as "\x<hex>".
bytea_decode :: proc(s: string, allocator := context.allocator) -> ([]u8, bool) {
	if !strings.has_prefix(s, "\\x") || len(s) % 2 != 0 {
		return nil, false
	}
	h := s[2:]
	out := make([]u8, len(h) / 2, allocator)
	for i in 0 ..< len(out) {
		hi, o1 := mm_hex(h[2 * i])
		lo, o2 := mm_hex(h[2 * i + 1])
		if !o1 || !o2 {
			return nil, false
		}
		out[i] = hi << 4 | lo
	}
	return out, true
}

bytea_encode :: proc(data: []u8) -> string {
	HEX := "0123456789abcdef"
	out := make([]u8, 2 + 2 * len(data), context.temp_allocator)
	out[0] = '\\'
	out[1] = 'x'
	for b, i in data {
		out[2 + 2 * i] = HEX[b >> 4]
		out[3 + 2 * i] = HEX[b & 15]
	}
	return string(out)
}

// ---------------------------------------------------------------------------
// GoTrue
// ---------------------------------------------------------------------------

// auth_password_grant signs in with an email and password and returns the
// access token. Used by the dev tooling; clients sign in themselves.
auth_password_grant :: proc(email, password: string) -> (token: string, err: string) {
	body := fmt.tprintf(`{{"email":%s,"password":%s}}`, jq(email), jq(password))
	resp, he := http_call(
		cfg.auth_port,
		"POST",
		"/token?grant_type=password",
		{{"Content-Type", "application/json"}},
		transmute([]u8)body,
	)
	if he != "" {
		return "", he
	}
	v, _ := json.parse(resp.body, .JSON, true, context.temp_allocator)
	if resp.status != 200 {
		return "", fmt.tprintf("sign-in failed: %d %s", resp.status, string(resp.body))
	}
	return strings.clone(jstr(v, "access_token")), ""
}
