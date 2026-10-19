package wire

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Supa is a Supabase project as seen from a client: the gateway URL and the
// public (anon) key that every request carries as `apikey`.
Supa :: struct {
	url:  string, // http://127.0.0.1:58521
	anon: string,
}

Result :: struct {
	status: int,
	body:   []u8,
	value:  json.Value,
	err:    string, // transport failure, or the server's message on a non-2xx
	code:   string, // PostgREST / Postgres error code, e.g. "42501"
}

ok :: proc(r: Result) -> bool {
	return r.err == "" && r.status >= 200 && r.status < 300
}

// enc percent-encodes a query-string value.
enc :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&sb, c)
		case:
			fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	return strings.to_string(sb)
}

call :: proc(
	s: Supa,
	bearer, method, url: string,
	body: []u8 = nil,
	content_type := "application/json",
	extra: []Header = nil,
	allocator := context.allocator,
) -> Result {
	context.allocator = allocator
	hs := make([dynamic]Header, context.temp_allocator)
	append(&hs, Header{"apikey", s.anon})
	append(&hs, Header{"Authorization", fmt.tprintf("Bearer %s", bearer if bearer != "" else s.anon)})
	if len(body) > 0 || method == "POST" || method == "PATCH" || method == "PUT" {
		append(&hs, Header{"Content-Type", content_type})
	}
	append(&hs, Header{"Accept", "application/json"})
	for h in extra {
		append(&hs, h)
	}
	resp, err := request(method, url, hs[:], body)
	r := Result {
		status = resp.status,
		body   = resp.body,
		err    = err,
	}
	if err != "" {
		return r
	}
	if len(resp.body) > 0 && strings.has_prefix(header_get(resp.headers, "content-type"), "application/json") {
		r.value, _ = parse(resp.body)
	} else if len(resp.body) > 0 && (resp.body[0] == '{' || resp.body[0] == '[') {
		r.value, _ = parse(resp.body)
	}
	if resp.status < 200 || resp.status >= 300 {
		msg := str(r.value, "message")
		if msg == "" {
			msg = str(r.value, "msg")
		}
		if msg == "" {
			msg = str(r.value, "error_description")
		}
		if msg == "" {
			msg = str(r.value, "error")
		}
		if msg == "" {
			msg = fmt.aprintf("HTTP %d", resp.status)
		}
		r.err = msg
		r.code = str(r.value, "code")
	}
	return r
}

// rest calls PostgREST: `path` is the part after /rest/v1/, query included.
rest :: proc(s: Supa, bearer, method, path: string, body := "", prefer := "", allocator := context.allocator) -> Result {
	extra: [1]Header
	n := 0
	if prefer != "" {
		extra[0] = {"Prefer", prefer}
		n = 1
	}
	return call(s, bearer, method, fmt.tprintf("%s/rest/v1/%s", s.url, path), transmute([]u8)body, "application/json", extra[:n], allocator)
}

rpc :: proc(s: Supa, bearer, fn: string, args := "{}", allocator := context.allocator) -> Result {
	return rest(s, bearer, "POST", fmt.tprintf("rpc/%s", fn), args, "", allocator)
}

storage_put :: proc(s: Supa, bearer, bucket, path: string, data: []u8, content_type := "application/octet-stream", allocator := context.allocator) -> Result {
	extra := [1]Header{{"x-upsert", "true"}}
	return call(s, bearer, "POST", fmt.tprintf("%s/storage/v1/object/%s/%s", s.url, bucket, path), data, content_type, extra[:], allocator)
}

storage_get :: proc(s: Supa, bearer, bucket, path: string, allocator := context.allocator) -> Result {
	return call(s, bearer, "GET", fmt.tprintf("%s/storage/v1/object/authenticated/%s/%s", s.url, bucket, path), nil, "", nil, allocator)
}

Session :: struct {
	access_token:  string,
	refresh_token: string,
	user_id:       string,
	email:         string,
	expires_at:    int,
}

session_from :: proc(v: json.Value) -> Session {
	return Session {
		access_token = str(v, "access_token"),
		refresh_token = str(v, "refresh_token"),
		user_id = str(get(v, "user"), "id"),
		email = str(get(v, "user"), "email"),
		expires_at = num(v, "expires_at"),
	}
}

sign_in :: proc(s: Supa, email, password: string, allocator := context.allocator) -> (Session, string) {
	body := fmt.tprintf(`{{"email":%s,"password":%s}}`, q(email), q(password))
	r := call(s, "", "POST", fmt.tprintf("%s/auth/v1/token?grant_type=password", s.url), transmute([]u8)body, allocator = allocator)
	if !ok(r) {
		return {}, r.err
	}
	return session_from(r.value), ""
}

sign_up :: proc(s: Supa, email, password: string, allocator := context.allocator) -> (Session, string) {
	body := fmt.tprintf(`{{"email":%s,"password":%s}}`, q(email), q(password))
	r := call(s, "", "POST", fmt.tprintf("%s/auth/v1/signup", s.url), transmute([]u8)body, allocator = allocator)
	if !ok(r) {
		return {}, r.err
	}
	return session_from(r.value), ""
}

refresh :: proc(s: Supa, refresh_token: string, allocator := context.allocator) -> (Session, string) {
	body := fmt.tprintf(`{{"refresh_token":%s}}`, q(refresh_token))
	r := call(s, "", "POST", fmt.tprintf("%s/auth/v1/token?grant_type=refresh_token", s.url), transmute([]u8)body, allocator = allocator)
	if !ok(r) {
		return {}, r.err
	}
	return session_from(r.value), ""
}
