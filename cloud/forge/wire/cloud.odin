// Package wire is what the forge server and the forge app share: Supabase
// calls that take the bearer token *per call*, and JSON helpers.
//
// The transport, the URL parsing and the error dialects are apps/cloudkit's
// (http_do, parse_url, error_from). What this adds is the one shape cloudkit's
// Client does not offer: its Client is bound to a token store, while the
// forge server forwards each incoming request's own credentials (a person's
// session, or a token session it minted) to PostgREST and Storage, and must
// never read or write anybody's store. The app uses cloudkit's Client for its
// session (sign-in, refresh, PALM_IDENTITY scoped sessions) and passes that
// session's access token here.
package wire

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import ck "../../../apps/cloudkit"

Header :: ck.Header

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
	code:   string, // PostgREST SQLSTATE, GoTrue or Storage error code
	kind:   ck.Error_Kind,
}

ok :: proc(r: Result) -> bool {
	return r.err == "" && r.status >= 200 && r.status < 300
}

header_get :: proc(headers: []Header, name: string) -> string {
	for h in headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

// cut_prefix is `s` without `prefix`, and whether it was there.
cut_prefix :: proc(s, prefix: string) -> (string, bool) {
	if strings.has_prefix(s, prefix) {
		return s[len(prefix):], true
	}
	return s, false
}

enc :: proc(s: string) -> string {
	return ck.escape(s)
}

USER_AGENT :: "palm-forge/0.1"

// request is one HTTP exchange through cloudkit's transport. `url` is a full
// http(s) URL with path and query.
request :: proc(method, url: string, headers: []Header = nil, body: []u8 = nil, timeout_ms := 60000) -> Result {
	scheme_end := strings.index(url, "://")
	if scheme_end < 0 {
		return {err = fmt.aprintf("not a URL: %s", url)}
	}
	slash := strings.index_byte(url[scheme_end + 3:], '/')
	base, path := url, "/"
	if slash >= 0 {
		base, path = url[:scheme_end + 3 + slash], url[scheme_end + 3 + slash:]
	}
	u, uok := ck.parse_url(base)
	if !uok {
		return {err = fmt.aprintf("not an http(s) URL: %s", url)}
	}
	resp, terr := ck.http_do(u, ck.Request{method = method, path = path, headers = headers, body = body, timeout_ms = timeout_ms}, USER_AGENT)
	if terr != "" {
		return {err = terr, kind = .Unavailable}
	}
	r := Result {
		status = resp.status,
		body   = transmute([]u8)resp.body,
	}
	if len(resp.body) > 0 && (resp.body[0] == '{' || resp.body[0] == '[' || resp.body[0] == '"' || resp.body[0] == 't' || resp.body[0] == 'f' || resp.body[0] == 'n') {
		r.value, _ = parse(transmute([]u8)resp.body)
	}
	if resp.status < 200 || resp.status >= 300 {
		e := ck.error_from(resp.status, r.value)
		r.err, r.code, r.kind = e.message, e.code, e.kind
		if msg := str(r.value, "error"); msg != "" && r.err == fmt.tprintf("HTTP %d", resp.status) {
			r.err = msg
		}
	}
	return r
}

// call sends a request to the Supabase gateway as `bearer` (the anon key when
// empty).
call :: proc(s: Supa, bearer, method, path: string, body: []u8 = nil, content_type := "application/json", extra: []Header = nil) -> Result {
	hs := make([dynamic]Header, context.temp_allocator)
	append(&hs, Header{"apikey", s.anon})
	append(&hs, Header{"Authorization", fmt.tprintf("Bearer %s", bearer if bearer != "" else s.anon)})
	if len(body) > 0 || method == "POST" || method == "PATCH" || method == "PUT" {
		append(&hs, Header{"Content-Type", content_type})
	}
	append(&hs, Header{"Accept", "application/json"})
	append(&hs, ..extra)
	return request(method, fmt.tprintf("%s%s", s.url, path), hs[:], body)
}

// rest calls PostgREST: `path` is the part after /rest/v1/, query included.
rest :: proc(s: Supa, bearer, method, path: string, body := "", prefer := "") -> Result {
	extra: [1]Header
	n := 0
	if prefer != "" {
		extra[0] = {"Prefer", prefer}
		n = 1
	}
	return call(s, bearer, method, fmt.tprintf("/rest/v1/%s", path), transmute([]u8)body, "application/json", extra[:n])
}

rpc :: proc(s: Supa, bearer, fn: string, args := "{}") -> Result {
	return rest(s, bearer, "POST", fmt.tprintf("rpc/%s", fn), args)
}

storage_put :: proc(s: Supa, bearer, bucket, path: string, data: []u8, content_type := "application/octet-stream") -> Result {
	extra := [1]Header{{"x-upsert", "true"}}
	return call(s, bearer, "POST", fmt.tprintf("/storage/v1/object/%s/%s", bucket, ck.escape(path, true)), data, content_type, extra[:])
}

storage_get :: proc(s: Supa, bearer, bucket, path: string) -> Result {
	return call(s, bearer, "GET", fmt.tprintf("/storage/v1/object/authenticated/%s/%s", bucket, ck.escape(path, true)))
}
