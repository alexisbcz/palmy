package main

// The JMAP front end: a minimal HTTP/1.1 server plus RFC 8620 core and RFC
// 8621 mail methods.
//
// HTTP SUBSET IMPLEMENTED: GET and POST, absolute-path targets, Host,
// Authorization (Basic), Content-Length request bodies, keep-alive with
// Connection: close honoured, and Content-Length responses. No chunked
// requests, no HTTP/2, no TLS (that is the socat tunnel's job), no cookies, no
// compression, no CORS preflight. Both ends of this conversation are in this
// repository, so the subset is exactly what is used.
//
// JMAP METHODS: Core/echo, Mailbox/get, Email/query, Email/get, Email/set
// (update with keyword patches, and destroy), Email/changes, Thread/get.
//
// THE INTERESTING PART is `resolve_backrefs`. RFC 8620 3.7 lets any argument
// be replaced by `#name` holding a ResultReference — {resultOf, name, path} —
// which the SERVER must evaluate as a JSON pointer against an earlier call's
// result. That is the mechanism that makes a single round trip out of
// "Email/query then Email/get the ids it found", and a server that does not
// implement it cannot be used to test a client that does. The pointer
// evaluator here implements RFC 6901 plus JMAP's `*` map-and-flatten
// extension.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

Http_Req :: struct {
	method:  string,
	target:  string,
	path:    string,
	query:   string,
	headers: [][2]string,
	body:    []u8,
	close:   bool,
}

jmapd_serve :: proc(c: ^SConn, base: string, port: int) {
	for c.open {
		req, ok := httpd_read(c)
		if !ok {
			return
		}
		slog(c, "<- %s %s (%d octets)", req.method, req.target, len(req.body))
		keep := jmapd_route(c, &req, base, port)
		free_all(context.temp_allocator)
		if !keep || req.close {
			return
		}
	}
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

httpd_read :: proc(c: ^SConn) -> (req: Http_Req, ok: bool) {
	line, lok := sread_line(c)
	if !lok {
		return req, false
	}
	start := strings.clone(line, context.temp_allocator)
	f := strings.fields(start, context.temp_allocator)
	if len(f) < 3 {
		httpd_error(c, 400, "Bad Request", "malformed request line")
		return req, false
	}
	req.method = strings.to_upper(f[0], context.temp_allocator)
	req.target = f[1]
	req.path = req.target
	if q := strings.index_byte(req.target, '?'); q >= 0 {
		req.path = req.target[:q]
		req.query = req.target[q + 1:]
	}
	if f[2] == "HTTP/1.0" {
		req.close = true
	}

	hs := make([dynamic][2]string, 0, 16, context.temp_allocator)
	content_length := 0
	for i := 0; i < 128; i += 1 {
		hl, hok := sread_line(c)
		if !hok {
			return req, false
		}
		if hl == "" {
			break
		}
		h := strings.clone(hl, context.temp_allocator)
		colon := strings.index_byte(h, ':')
		if colon <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(h[:colon]), context.temp_allocator)
		val := strings.trim_space(h[colon + 1:])
		append(&hs, [2]string{name, val})
		switch name {
		case "content-length":
			content_length, _ = strconv.parse_int(val, 10)
		case "connection":
			if strings.equal_fold(val, "close") {req.close = true}
		case "transfer-encoding":
			httpd_error(c, 501, "Not Implemented", "this server does not accept chunked requests")
			return req, false
		}
	}
	req.headers = hs[:]
	if content_length > 0 {
		if content_length > 32 * 1024 * 1024 {
			httpd_error(c, 413, "Payload Too Large", "request body too large")
			return req, false
		}
		body, bok := sread_exact(c, content_length, context.temp_allocator)
		if !bok {
			return req, false
		}
		req.body = body
	}
	return req, true
}

httpd_get :: proc(req: ^Http_Req, name: string) -> (string, bool) {
	for h in req.headers {
		if h[0] == name {
			return h[1], true
		}
	}
	return "", false
}

httpd_respond :: proc(
	c: ^SConn,
	status: int,
	reason: string,
	content_type: string,
	body: []u8,
	close := false,
) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", status, reason)
	fmt.sbprintf(&sb, "Content-Type: %s\r\n", content_type)
	fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	strings.write_string(&sb, "Cache-Control: no-store\r\n")
	fmt.sbprintf(&sb, "Connection: %s\r\n", close ? "close" : "keep-alive")
	strings.write_string(&sb, "\r\n")
	swrite_str(c, strings.to_string(sb))
	swrite(c, body)
	slog(c, "-> %d %s (%d octets)", status, reason, len(body))
}

// httpd_error returns an RFC 7807 problem-details object, which is what RFC
// 8620 3.6.1 asks for.
httpd_error :: proc(c: ^SConn, status: int, reason: string, detail: string, type := "about:blank") {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"type":%s,"status":%d,"detail":%s}}`, jq(type), status, jq(detail))
	httpd_respond(c, status, reason, "application/problem+json", transmute([]u8)strings.to_string(sb), status >= 500)
}

// jq quotes a JSON string.
jq :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&sb, "\\\"")
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
			strings.write_string(&sb, "\\r")
		case '\t':
			strings.write_string(&sb, "\\t")
		case:
			if ch < 0x20 {
				fmt.sbprintf(&sb, "\\u%04x", int(ch))
			} else {
				strings.write_byte(&sb, ch)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

jmapd_auth :: proc(req: ^Http_Req) -> ^Account {
	v, ok := httpd_get(req, "authorization")
	if !ok || !strings.has_prefix(v, "Basic ") {
		return nil
	}
	raw := mm_b64_decode(transmute([]u8)v[6:], context.temp_allocator)
	s := string(raw)
	colon := strings.index_byte(s, ':')
	if colon < 0 {
		return nil
	}
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	a := store_account(s[:colon])
	if a == nil || a.password != s[colon + 1:] {
		return nil
	}
	return a
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

JMAP_API_PATH :: "/jmap/api"
JMAP_DOWNLOAD_PREFIX :: "/jmap/download/"
JMAP_UPLOAD_PREFIX :: "/jmap/upload/"

jmapd_route :: proc(c: ^SConn, req: ^Http_Req, base: string, port: int) -> bool {
	acct := jmapd_auth(req)
	if acct == nil {
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "HTTP/1.1 401 Unauthorized\r\n")
		fmt.sbprintf(&sb, "WWW-Authenticate: Basic realm=\"mailcore test server\"\r\n")
		fmt.sbprintf(&sb, "Content-Length: 0\r\nConnection: keep-alive\r\n\r\n")
		swrite_str(c, strings.to_string(sb))
		return true
	}

	switch {
	case req.path == "/.well-known/jmap" && req.method == "GET":
		body := jmapd_session(acct, base, port)
		httpd_respond(c, 200, "OK", "application/json; charset=utf-8", transmute([]u8)body)

	case req.path == JMAP_API_PATH && req.method == "POST":
		body, status := jmapd_api(acct, req.body)
		if status != 200 {
			httpd_respond(c, status, status == 400 ? "Bad Request" : "Error", "application/problem+json", transmute([]u8)body)
			return true
		}
		httpd_respond(c, 200, "OK", "application/json; charset=utf-8", transmute([]u8)body)

	case strings.has_prefix(req.path, JMAP_DOWNLOAD_PREFIX) && req.method == "GET":
		// /jmap/download/{accountId}/{blobId}/{name}
		rest := req.path[len(JMAP_DOWNLOAD_PREFIX):]
		segs := strings.split(rest, "/", context.temp_allocator)
		if len(segs) < 2 {
			httpd_error(c, 404, "Not Found", "the download URL needs an account and a blob")
			return true
		}
		blob := url_decode_min(segs[1], context.temp_allocator)
		sync.mutex_lock(&store.mu)
		data := jmapd_blob(acct, blob)
		sync.mutex_unlock(&store.mu)
		if data == nil {
			httpd_error(c, 404, "Not Found", fmt.tprintf("no blob %q", blob))
			return true
		}
		httpd_respond(c, 200, "OK", "message/rfc822", data)

	case req.path == "/":
		httpd_respond(
			c,
			200,
			"OK",
			"text/plain; charset=utf-8",
			transmute([]u8)string(
				"mailcore test server. JMAP session discovery is at /.well-known/jmap\n",
			),
		)

	case:
		httpd_error(c, 404, "Not Found", fmt.tprintf("no handler for %s %s", req.method, req.path))
	}
	return true
}

url_decode_min :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '%') < 0 {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); {
		if s[i] == '%' && i + 2 < len(s) {
			hi, o1 := mm_hex(s[i + 1])
			lo, o2 := mm_hex(s[i + 2])
			if o1 && o2 {
				strings.write_byte(&sb, hi << 4 | lo)
				i += 3
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

jmapd_blob :: proc(a: ^Account, blob: string) -> []u8 {
	for i in 0 ..< len(a.boxes) {
		for k in 0 ..< len(a.boxes[i].msgs) {
			m := &a.boxes[i].msgs[k]
			if m.blob_id == blob && !m.expunged {
				return m.raw
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// The session object (RFC 8620 2)
// ---------------------------------------------------------------------------

jmapd_session :: proc(a: ^Account, base: string, port: int) -> string {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	sb := strings.builder_make(context.temp_allocator)
	origin := fmt.tprintf("http://%s:%d", base, port)
	acct_id := fmt.tprintf("acct-%s", a.user)
	strings.write_byte(&sb, '{')
	fmt.sbprintf(&sb, `"username":%s,`, jq(a.email))
	fmt.sbprintf(&sb, `"apiUrl":%s,`, jq(fmt.tprintf("%s%s", origin, JMAP_API_PATH)))
	fmt.sbprintf(
		&sb,
		`"downloadUrl":%s,`,
		jq(fmt.tprintf("%s%s{{accountId}}/{{blobId}}/{{name}}?accept={{type}}", origin, JMAP_DOWNLOAD_PREFIX)),
	)
	fmt.sbprintf(&sb, `"uploadUrl":%s,`, jq(fmt.tprintf("%s%s{{accountId}}", origin, JMAP_UPLOAD_PREFIX)))
	fmt.sbprintf(&sb, `"eventSourceUrl":%s,`, jq(fmt.tprintf("%s/jmap/eventsource", origin)))
	strings.write_string(&sb, `"capabilities":{`)
	fmt.sbprintf(
		&sb,
		`"urn:ietf:params:jmap:core":{{"maxSizeUpload":50000000,"maxConcurrentUpload":4,"maxSizeRequest":10000000,"maxConcurrentRequests":4,"maxCallsInRequest":16,"maxObjectsInGet":500,"maxObjectsInSet":500,"collationAlgorithms":["i;ascii-casemap"]}},`,
	)
	strings.write_string(
		&sb,
		`"urn:ietf:params:jmap:mail":{"maxMailboxesPerEmail":1,"maxMailboxDepth":null,"maxSizeMailboxName":200,"maxSizeAttachmentsPerEmail":10000000,"emailQuerySortOptions":["receivedAt","subject","size"],"mayCreateTopLevelMailbox":false}`,
	)
	strings.write_string(&sb, `},`)
	fmt.sbprintf(&sb, `"accounts":{{%s:{{`, jq(acct_id))
	fmt.sbprintf(&sb, `"name":%s,"isPersonal":true,"isReadOnly":false,`, jq(a.email))
	strings.write_string(&sb, `"accountCapabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{}}`)
	strings.write_string(&sb, `}},`)
	fmt.sbprintf(
		&sb,
		`"primaryAccounts":{{"urn:ietf:params:jmap:core":%s,"urn:ietf:params:jmap:mail":%s}},`,
		jq(acct_id),
		jq(acct_id),
	)
	fmt.sbprintf(&sb, `"state":%s`, jq(account_state_string(a, context.temp_allocator)))
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

jmapd_account_id :: proc(a: ^Account) -> string {
	return fmt.tprintf("acct-%s", a.user)
}

// ---------------------------------------------------------------------------
// The API endpoint
// ---------------------------------------------------------------------------

Invocation :: struct {
	name: string,
	args: json.Value,
	id:   string,
}

jmapd_api :: proc(a: ^Account, body: []u8) -> (out: string, status: int) {
	v, perr := json.parse(body, .JSON, true, context.temp_allocator)
	if perr != nil {
		return fmt.tprintf(
			`{{"type":"urn:ietf:params:jmap:error:notJSON","status":400,"detail":%s}}`,
			jq(fmt.tprintf("%v", perr)),
		), 400
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"the request is not a JSON object"}`, 400
	}
	// `using` is mandatory (RFC 8620 3.3).
	using_arr, has_using := obj["using"]
	if !has_using {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"missing the \"using\" property"}`, 400
	}
	have_mail := false
	if ua, is := using_arr.(json.Array); is {
		for e in ua {
			if s, iss := e.(json.String); iss && string(s) == "urn:ietf:params:jmap:mail" {
				have_mail = true
			}
		}
	}

	calls_v, has_calls := obj["methodCalls"]
	calls_arr, calls_is := calls_v.(json.Array)
	if !has_calls || !calls_is {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"methodCalls must be an array"}`, 400
	}
	if len(calls_arr) > 16 {
		return `{"type":"urn:ietf:params:jmap:error:limit","status":400,"detail":"more than maxCallsInRequest method calls"}`, 400
	}

	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)

	// Results, so back-references can look them up by call id.
	res_ids := make([dynamic]string, 0, len(calls_arr), context.temp_allocator)
	res_names := make([dynamic]string, 0, len(calls_arr), context.temp_allocator)
	res_json := make([dynamic]string, 0, len(calls_arr), context.temp_allocator)
	res_vals := make([dynamic]json.Value, 0, len(calls_arr), context.temp_allocator)

	for cv in calls_arr {
		ca, is := cv.(json.Array)
		if !is || len(ca) < 3 {
			continue
		}
		name := jas(ca[0])
		args := ca[1]
		id := jas(ca[2])

		if !have_mail && strings.contains(name, "/") && !strings.has_prefix(name, "Core/") {
			append(&res_names, "error")
			append(&res_ids, id)
			append(
				&res_json,
				`{"type":"unknownCapability","description":"the request did not declare urn:ietf:params:jmap:mail"}`,
			)
			append(&res_vals, nil)
			continue
		}

		// Back-reference resolution happens BEFORE the method runs.
		resolved, rerr := resolve_backrefs(args, res_ids[:], res_names[:], res_vals[:])
		if rerr != "" {
			append(&res_names, "error")
			append(&res_ids, id)
			append(&res_json, fmt.tprintf(`{{"type":"invalidResultReference","description":%s}}`, jq(rerr)))
			append(&res_vals, nil)
			continue
		}

		rname, rjson := jmapd_method(a, name, resolved)
		append(&res_names, rname)
		append(&res_ids, id)
		append(&res_json, rjson)
		// Re-parse the rendered result so a later back-reference can point
		// into it. Round-tripping through JSON is slower than keeping a tree,
		// and it is also the only way to be sure the pointer sees exactly what
		// the client will see.
		rv, _ := json.parse(transmute([]u8)rjson, .JSON, true, context.temp_allocator)
		append(&res_vals, rv)
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"methodResponses":[`)
	for i in 0 ..< len(res_ids) {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "[%s,%s,%s]", jq(res_names[i]), res_json[i], jq(res_ids[i]))
	}
	fmt.sbprintf(&sb, `],"sessionState":%s}}`, jq(account_state_string(a, context.temp_allocator)))
	return strings.to_string(sb), 200
}

jas :: proc(v: json.Value) -> string {
	if s, is := v.(json.String); is {
		return string(s)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Back-references (RFC 8620 3.7)
// ---------------------------------------------------------------------------

// resolve_backrefs rewrites `{"#ids": {resultOf, name, path}}` into
// `{"ids": <the pointed-at value>}`.
//
// The rules it enforces, all of which RFC 8620 3.7 requires and all of which
// are easy to skip:
//
//   - `resultOf` must name an EARLIER call in the same request;
//   - `name` must match that call's method name, so a reference cannot
//     silently read the wrong result when the server reorders;
//   - the pointer must resolve, or the whole call fails with
//     `invalidResultReference` rather than with a missing argument;
//   - both `#x` and `x` present for the same `x` is an error.
resolve_backrefs :: proc(
	args: json.Value,
	ids: []string,
	names: []string,
	vals: []json.Value,
) -> (
	out: string,
	err: string,
) {
	obj, is := args.(json.Object)
	if !is {
		return render_json(args), ""
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	first := true
	for k, v in obj {
		if !strings.has_prefix(k, "#") {
			if !first {strings.write_byte(&sb, ',')}
			first = false
			fmt.sbprintf(&sb, "%s:%s", jq(k), render_json(v))
			continue
		}
		plain := k[1:]
		if _, clash := obj[plain]; clash {
			return "", fmt.tprintf("both %q and %q were given", k, plain)
		}
		result_of := jas_get(v, "resultOf")
		want_name := jas_get(v, "name")
		path := jas_get(v, "path")
		if result_of == "" || want_name == "" {
			return "", fmt.tprintf("the ResultReference for %q is incomplete", k)
		}
		idx := -1
		for id, i in ids {
			if id == result_of {
				idx = i
			}
		}
		if idx < 0 {
			return "", fmt.tprintf("%q refers to call %q, which has not run", k, result_of)
		}
		if names[idx] != want_name {
			return "", fmt.tprintf(
				"%q expects call %q to be %q but it was %q",
				k,
				result_of,
				want_name,
				names[idx],
			)
		}
		pointed, pok := json_pointer_eval(vals[idx], path)
		if !pok {
			return "", fmt.tprintf("the pointer %q does not resolve in the result of %q", path, result_of)
		}
		if !first {strings.write_byte(&sb, ',')}
		first = false
		fmt.sbprintf(&sb, "%s:%s", jq(plain), render_json(pointed))
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb), ""
}

jas_get :: proc(v: json.Value, key: string) -> string {
	o, is := v.(json.Object)
	if !is {
		return ""
	}
	e, has := o[key]
	if !has {
		return ""
	}
	return jas(e)
}

// json_pointer_eval is RFC 6901 plus JMAP's `*`.
json_pointer_eval :: proc(root: json.Value, pointer: string) -> (out: json.Value, ok: bool) {
	if pointer == "" {
		return root, true
	}
	if pointer[0] != '/' {
		return nil, false
	}
	cur := root
	rest := pointer[1:]
	for {
		slash := strings.index_byte(rest, '/')
		token := slash < 0 ? rest : rest[:slash]
		tail := slash < 0 ? "" : rest[slash:]
		tok := pointer_unescape(token)

		if tok == "*" {
			arr, is := cur.(json.Array)
			if !is {
				return nil, false
			}
			flat := make(json.Array, 0, len(arr), context.temp_allocator)
			for e in arr {
				sub, sok := json_pointer_eval(e, tail)
				if !sok {
					continue
				}
				if sa, isa := sub.(json.Array); isa {
					for x in sa {
						append(&flat, x)
					}
				} else {
					append(&flat, sub)
				}
			}
			return flat, true
		}

		switch t in cur {
		case json.Object:
			e, has := t[tok]
			if !has {
				return nil, false
			}
			cur = e
		case json.Array:
			i, iok := strconv.parse_int(tok, 10)
			if !iok || i < 0 || i >= len(t) {
				return nil, false
			}
			cur = t[i]
		case json.Null, json.Integer, json.Float, json.Boolean, json.String:
			return nil, false
		}
		if tail == "" {
			return cur, true
		}
		rest = tail[1:]
	}
}

pointer_unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '~') < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '~' && i + 1 < len(s) {
			if s[i + 1] == '0' {strings.write_byte(&sb, '~');i += 1;continue}
			if s[i + 1] == '1' {strings.write_byte(&sb, '/');i += 1;continue}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// render_json writes a parsed Value back out.
render_json :: proc(v: json.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	render_into(&sb, v)
	return strings.to_string(sb)
}

render_into :: proc(sb: ^strings.Builder, v: json.Value) {
	switch t in v {
	case json.Null:
		strings.write_string(sb, "null")
	case json.Integer:
		strings.write_i64(sb, i64(t))
	case json.Float:
		fmt.sbprintf(sb, "%v", f64(t))
	case json.Boolean:
		strings.write_string(sb, bool(t) ? "true" : "false")
	case json.String:
		strings.write_string(sb, jq(string(t)))
	case json.Array:
		strings.write_byte(sb, '[')
		for e, i in t {
			if i > 0 {strings.write_byte(sb, ',')}
			render_into(sb, e)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		strings.write_byte(sb, '{')
		first := true
		for k, e in t {
			if !first {strings.write_byte(sb, ',')}
			first = false
			strings.write_string(sb, jq(k))
			strings.write_byte(sb, ':')
			render_into(sb, e)
		}
		strings.write_byte(sb, '}')
	case:
		strings.write_string(sb, "null")
	}
}

// ---------------------------------------------------------------------------
// Methods
// ---------------------------------------------------------------------------

// jmapd_method dispatches one invocation. `args_json` is the already
// back-reference-resolved argument object, as rendered JSON.
jmapd_method :: proc(a: ^Account, name: string, args_json: string) -> (rname, rjson: string) {
	args, perr := json.parse(transmute([]u8)args_json, .JSON, true, context.temp_allocator)
	if perr != nil {
		return "error", `{"type":"invalidArguments","description":"arguments did not parse"}`
	}
	acct_id := jmapd_account_id(a)
	given := sstr(args, "accountId")
	if given != "" && given != acct_id {
		return "error", fmt.tprintf(
			`{{"type":"accountNotFound","description":%s}}`,
			jq(fmt.tprintf("this credential has no account %q", given)),
		)
	}

	// A method that cannot answer returns a problem object; RFC 8620 3.6.2
	// says that comes back as ["error", {...}, callId], NOT as the method's
	// own name, or a client cannot tell success from failure.
	as_result :: proc(name, js: string) -> (string, string) {
		if strings.has_prefix(js, `{"type":`) {
			return "error", js
		}
		return name, js
	}

	switch name {
	case "Core/echo":
		return name, args_json

	case "Mailbox/get":
		return as_result(name, jmapd_mailbox_get(a, args))

	case "Email/query":
		return as_result(name, jmapd_email_query(a, args))

	case "Email/get":
		return as_result(name, jmapd_email_get(a, args))

	case "Email/set":
		return as_result(name, jmapd_email_set(a, args))

	case "Email/changes":
		return as_result(name, jmapd_email_changes(a, args))

	case "Thread/get":
		return as_result(name, jmapd_thread_get(a, args))
	}
	return "error", fmt.tprintf(
		`{{"type":"unknownMethod","description":%s}}`,
		jq(fmt.tprintf("%q is not implemented by this test server", name)),
	)
}

sstr :: proc(v: json.Value, key: string) -> string {
	o, is := v.(json.Object)
	if !is {
		return ""
	}
	e, has := o[key]
	if !has {
		return ""
	}
	return jas(e)
}

sarr :: proc(v: json.Value, key: string) -> json.Array {
	o, is := v.(json.Object)
	if !is {
		return nil
	}
	e, has := o[key]
	if !has {
		return nil
	}
	arr, isa := e.(json.Array)
	if !isa {
		return nil
	}
	return arr
}

sobj :: proc(v: json.Value, key: string) -> (json.Object, bool) {
	o, is := v.(json.Object)
	if !is {
		return nil, false
	}
	e, has := o[key]
	if !has {
		return nil, false
	}
	oo, iso := e.(json.Object)
	return oo, iso
}

sint :: proc(v: json.Value, key: string, def := 0) -> int {
	o, is := v.(json.Object)
	if !is {
		return def
	}
	e, has := o[key]
	if !has {
		return def
	}
	switch t in e {
	case json.Integer:
		return int(t)
	case json.Float:
		return int(t)
	case json.Null, json.Boolean, json.String, json.Array, json.Object:
		return def
	}
	return def
}

sbool :: proc(v: json.Value, key: string) -> bool {
	o, is := v.(json.Object)
	if !is {
		return false
	}
	e, has := o[key]
	if !has {
		return false
	}
	b, isb := e.(json.Boolean)
	return isb && bool(b)
}

// sval returns the raw value for a key, so a caller can tell `null` from an
// EMPTY ARRAY. This matters: an empty `[dynamic]Value` has a nil data pointer,
// so `arr == nil` is true for `[]` as well as for a missing key, and a server
// that tests for nil treats "no ids" as "every id". That is a data-returning
// bug, not a cosmetic one.
sval :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, is := v.(json.Object)
	if !is {
		return nil, false
	}
	e, has := o[key]
	return e, has
}

// skey_is_null reports whether the key is present AND explicitly JSON null.
skey_is_null :: proc(v: json.Value, key: string) -> bool {
	e, has := sval(v, key)
	if !has {
		return false
	}
	_, isnull := e.(json.Null)
	return isnull
}

// skey_is_array reports whether the key is present and an array, and gives its
// length, which is the only reliable way to see an empty one.
skey_is_array :: proc(v: json.Value, key: string) -> (n: int, ok: bool) {
	e, has := sval(v, key)
	if !has {
		return 0, false
	}
	a, isa := e.(json.Array)
	if !isa {
		return 0, false
	}
	return len(a), true
}

skey_present :: proc(v: json.Value, key: string) -> bool {
	o, is := v.(json.Object)
	if !is {
		return false
	}
	_, has := o[key]
	return has
}

// --- Mailbox/get ------------------------------------------------------------

jmapd_mailbox_get :: proc(a: ^Account, args: json.Value) -> string {
	// RFC 8620 5.1: `ids: null` means every record; a LIST of ids (even an
	// empty one) means exactly those.
	want_all := skey_is_null(args, "ids") || !skey_present(args, "ids")
	want := sarr(args, "ids")
	_, is_list := skey_is_array(args, "ids")
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"accountId":%s,"state":%s,"list":[`, jq(jmapd_account_id(a)), jq(account_state_string(a, context.temp_allocator)))
	first := true
	not_found := make([dynamic]string, 0, 4, context.temp_allocator)
	if is_list {
		for e in want {
			id := jas(e)
			if account_box_by_jid(a, id) == nil {
				append(&not_found, id)
			}
		}
	}
	for i in 0 ..< len(a.boxes) {
		b := &a.boxes[i]
		if !want_all {
			hit := false
			for e in want {
				if jas(e) == b.jid {hit = true}
			}
			if !hit {
				continue
			}
		}
		if !first {strings.write_byte(&sb, ',')}
		first = false
		strings.write_byte(&sb, '{')
		fmt.sbprintf(&sb, `"id":%s,`, jq(b.jid))
		// JMAP mailbox names are leaf names; the hierarchy is parentId.
		leaf := b.name
		if dot := strings.last_index_byte(b.name, HIERARCHY_DELIM[0]); dot >= 0 {
			leaf = b.name[dot + 1:]
		}
		fmt.sbprintf(&sb, `"name":%s,`, jq(leaf))
		if b.parent_jid == "" {
			strings.write_string(&sb, `"parentId":null,`)
		} else {
			fmt.sbprintf(&sb, `"parentId":%s,`, jq(b.parent_jid))
		}
		if b.role == "" {
			strings.write_string(&sb, `"role":null,`)
		} else {
			fmt.sbprintf(&sb, `"role":%s,`, jq(b.role))
		}
		fmt.sbprintf(&sb, `"sortOrder":%d,`, i)
		fmt.sbprintf(&sb, `"totalEmails":%d,`, box_count(b))
		fmt.sbprintf(&sb, `"unreadEmails":%d,`, box_unseen(b))
		fmt.sbprintf(&sb, `"totalThreads":%d,`, box_count(b))
		fmt.sbprintf(&sb, `"unreadThreads":%d,`, box_unseen(b))
		strings.write_string(
			&sb,
			`"myRights":{"mayReadItems":true,"mayAddItems":true,"mayRemoveItems":true,"maySetSeen":true,"maySetKeywords":true,"mayCreateChild":false,"mayRename":false,"mayDelete":false,"maySubmit":true},`,
		)
		strings.write_string(&sb, `"isSubscribed":true`)
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, `],"notFound":[`)
	for id, i in not_found {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `]}`)
	return strings.to_string(sb)
}

// --- Email/query ------------------------------------------------------------

jmapd_email_query :: proc(a: ^Account, args: json.Value) -> string {
	in_mailbox := ""
	if f, ok := sobj(args, "filter"); ok {
		if e, has := f["inMailbox"]; has {
			in_mailbox = jas(e)
		}
	}
	// Collect, oldest first on receivedAt, which is the only sort this server
	// implements; a request for another property is answered, not refused,
	// because the test client only ever asks for this one.
	hits := make([dynamic]^Message, 0, 64, context.temp_allocator)
	for i in 0 ..< len(a.boxes) {
		b := &a.boxes[i]
		if in_mailbox != "" && b.jid != in_mailbox {
			continue
		}
		for k in 0 ..< len(b.msgs) {
			if !b.msgs[k].expunged {
				append(&hits, &b.msgs[k])
			}
		}
	}
	// Stable insertion sort on (received, uid).
	for x in 1 ..< len(hits) {
		v := hits[x]
		j := x - 1
		for j >= 0 &&
		    (hits[j].received > v.received ||
				    (hits[j].received == v.received && hits[j].uid > v.uid)) {
			hits[j + 1] = hits[j]
			j -= 1
		}
		hits[j + 1] = v
	}
	position := sint(args, "position", 0)
	limit := sint(args, "limit", 0)
	if position < 0 {position = 0}
	if position > len(hits) {position = len(hits)}
	window := hits[position:]
	if limit > 0 && limit < len(window) {
		window = window[:limit]
	}

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`{{"accountId":%s,"queryState":%s,"canCalculateChanges":false,"position":%d,"ids":[`,
		jq(jmapd_account_id(a)),
		jq(account_state_string(a, context.temp_allocator)),
		position,
	)
	for m, i in window {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(m.jid))
	}
	fmt.sbprintf(&sb, `],"total":%d}}`, len(hits))
	return strings.to_string(sb)
}

// --- Email/get --------------------------------------------------------------

jmapd_email_get :: proc(a: ^Account, args: json.Value) -> string {
	// `ids` absent is an error, `ids: null` is "every message", and an array
	// — INCLUDING an empty one — is exactly those messages. See `sval`.
	if !skey_present(args, "ids") {
		return `{"type":"invalidArguments","description":"Email/get requires an ids property (null for all)"}`
	}
	want_all := skey_is_null(args, "ids")
	if _, is_list := skey_is_array(args, "ids"); !is_list && !want_all {
		return `{"type":"invalidArguments","description":"ids must be an array of ids or null"}`
	}
	ids := sarr(args, "ids")
	fetch_text := sbool(args, "fetchTextBodyValues") || sbool(args, "fetchAllBodyValues")
	fetch_html := sbool(args, "fetchHTMLBodyValues") || sbool(args, "fetchAllBodyValues")
	max_bytes := sint(args, "maxBodyValueBytes", 0)

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`{{"accountId":%s,"state":%s,"list":[`,
		jq(jmapd_account_id(a)),
		jq(account_state_string(a, context.temp_allocator)),
	)
	not_found := make([dynamic]string, 0, 4, context.temp_allocator)
	first := true
	if want_all {
		for i in 0 ..< len(a.boxes) {
			for k in 0 ..< len(a.boxes[i].msgs) {
				m := &a.boxes[i].msgs[k]
				if m.expunged {
					continue
				}
				if !first {strings.write_byte(&sb, ',')}
				first = false
				jmapd_write_email(&sb, a, &a.boxes[i], m, fetch_text, fetch_html, max_bytes)
			}
		}
	} else {
		for e in ids {
			id := jas(e)
			b, m := account_message_by_jid(a, id)
			if m == nil {
				append(&not_found, id)
				continue
			}
			if !first {strings.write_byte(&sb, ',')}
			first = false
			jmapd_write_email(&sb, a, b, m, fetch_text, fetch_html, max_bytes)
		}
	}
	strings.write_string(&sb, `],"notFound":[`)
	for id, i in not_found {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `]}`)
	return strings.to_string(sb)
}

jmapd_write_body_part :: proc(sb: ^strings.Builder, p: Body_Part_Spec, blob: string) {
	strings.write_byte(sb, '{')
	if p.part_id == "" {
		strings.write_string(sb, `"partId":null,`)
	} else {
		fmt.sbprintf(sb, `"partId":%s,`, jq(p.part_id))
	}
	fmt.sbprintf(sb, `"blobId":%s,`, jq(blob))
	fmt.sbprintf(sb, `"size":%d,`, p.size)
	if p.name == "" {
		strings.write_string(sb, `"name":null,`)
	} else {
		fmt.sbprintf(sb, `"name":%s,`, jq(p.name))
	}
	fmt.sbprintf(sb, `"type":%s,`, jq(p.type == "" ? "application/octet-stream" : p.type))
	if p.charset == "" {
		strings.write_string(sb, `"charset":null,`)
	} else {
		fmt.sbprintf(sb, `"charset":%s,`, jq(p.charset))
	}
	if p.disposition == "" {
		strings.write_string(sb, `"disposition":null,`)
	} else {
		fmt.sbprintf(sb, `"disposition":%s,`, jq(p.disposition))
	}
	if p.cid == "" {
		strings.write_string(sb, `"cid":null,`)
	} else {
		fmt.sbprintf(sb, `"cid":%s,`, jq(p.cid))
	}
	strings.write_string(sb, `"language":null,"location":null`)
	if len(p.sub_parts) > 0 {
		strings.write_string(sb, `,"subParts":[`)
		for s, i in p.sub_parts {
			if i > 0 {strings.write_byte(sb, ',')}
			jmapd_write_body_part(sb, s, blob)
		}
		strings.write_byte(sb, ']')
	}
	strings.write_byte(sb, '}')
}

jmapd_write_email :: proc(
	sb: ^strings.Builder,
	a: ^Account,
	b: ^Mailbox,
	m: ^Message,
	fetch_text, fetch_html: bool,
	max_bytes: int,
) {
	d := m.decomp
	strings.write_byte(sb, '{')
	fmt.sbprintf(sb, `"id":%s,`, jq(m.jid))
	fmt.sbprintf(sb, `"blobId":%s,`, jq(m.blob_id))
	fmt.sbprintf(sb, `"threadId":%s,`, jq(m.thread_id))
	fmt.sbprintf(sb, `"mailboxIds":{{%s:true}},`, jq(b.jid))
	strings.write_string(sb, `"keywords":{`)
	for k, i in flags_to_keywords(m.flags, context.temp_allocator) {
		if i > 0 {strings.write_byte(sb, ',')}
		fmt.sbprintf(sb, `%s:true`, jq(k))
	}
	strings.write_string(sb, `},`)
	fmt.sbprintf(sb, `"size":%d,`, len(m.raw))
	fmt.sbprintf(sb, `"receivedAt":%s,`, jq(iso8601(m.received, context.temp_allocator)))
	fmt.sbprintf(sb, `"sentAt":%s,`, jq(d.sent_at == "" ? iso8601(m.received, context.temp_allocator) : d.sent_at))
	fmt.sbprintf(sb, `"subject":%s,`, jq(d.subject))
	if d.message_id == "" {
		strings.write_string(sb, `"messageId":null,`)
	} else {
		fmt.sbprintf(sb, `"messageId":[%s],`, jq(d.message_id))
	}
	write_ids :: proc(sb: ^strings.Builder, key: string, ids: []string) {
		if len(ids) == 0 {
			fmt.sbprintf(sb, `%s:null,`, jq(key))
			return
		}
		fmt.sbprintf(sb, `%s:[`, jq(key))
		for id, i in ids {
			if i > 0 {strings.write_byte(sb, ',')}
			strings.write_string(sb, jq(id))
		}
		strings.write_string(sb, `],`)
	}
	write_ids(sb, "inReplyTo", d.in_reply_to)
	write_ids(sb, "references", d.references)
	write_addr :: proc(sb: ^strings.Builder, key, name, email: string) {
		if email == "" {
			fmt.sbprintf(sb, `%s:null,`, jq(key))
			return
		}
		fmt.sbprintf(sb, `%s:[{{"name":`, jq(key))
		if name == "" {
			strings.write_string(sb, "null")
		} else {
			strings.write_string(sb, jq(name))
		}
		fmt.sbprintf(sb, `,"email":%s}}],`, jq(email))
	}
	write_addr(sb, "sender", d.from_name, d.from_email)
	write_addr(sb, "from", d.from_name, d.from_email)
	write_addr(sb, "to", d.to_name, d.to_email)
	strings.write_string(sb, `"cc":null,"bcc":null,"replyTo":null,`)
	fmt.sbprintf(sb, `"hasAttachment":%s,`, d.has_attachment ? "true" : "false")
	fmt.sbprintf(sb, `"preview":%s,`, jq(d.preview))

	strings.write_string(sb, `"bodyStructure":`)
	jmapd_write_body_part(sb, d.structure, m.blob_id)
	strings.write_byte(sb, ',')

	strings.write_string(sb, `"textBody":[`)
	for p, i in d.text_body {
		if i > 0 {strings.write_byte(sb, ',')}
		jmapd_write_body_part(sb, p, m.blob_id)
	}
	strings.write_string(sb, `],"htmlBody":[`)
	for p, i in d.html_body {
		if i > 0 {strings.write_byte(sb, ',')}
		jmapd_write_body_part(sb, p, m.blob_id)
	}
	strings.write_string(sb, `],"attachments":[`)
	for p, i in d.attachments {
		if i > 0 {strings.write_byte(sb, ',')}
		jmapd_write_body_part(sb, p, m.blob_id)
	}
	strings.write_string(sb, `],"bodyValues":{`)
	bfirst := true
	emit_value :: proc(sb: ^strings.Builder, first: ^bool, p: Body_Part_Spec, max_bytes: int) {
		if p.part_id == "" {
			return
		}
		if !first^ {strings.write_byte(sb, ',')}
		first^ = false
		val := p.value
		truncated := false
		if max_bytes > 0 && len(val) > max_bytes {
			val = val[:max_bytes]
			truncated = true
		}
		fmt.sbprintf(
			sb,
			`%s:{{"value":%s,"isEncodingProblem":false,"isTruncated":%s}}`,
			jq(p.part_id),
			jq(val),
			truncated ? "true" : "false",
		)
	}
	if fetch_text {
		for p in d.text_body {
			emit_value(sb, &bfirst, p, max_bytes)
		}
	}
	if fetch_html {
		for p in d.html_body {
			emit_value(sb, &bfirst, p, max_bytes)
		}
	}
	strings.write_string(sb, `}}`)
}

// --- Email/set --------------------------------------------------------------

jmapd_email_set :: proc(a: ^Account, args: json.Value) -> string {
	// RFC 8620 5.3: if the client supplied ifInState and it is not the
	// server's current state, the whole call MUST fail with stateMismatch —
	// otherwise two clients writing concurrently silently clobber each other.
	if skey_present(args, "ifInState") {
		want := sstr(args, "ifInState")
		have := account_state_string(a, context.temp_allocator)
		if want != have {
			return fmt.tprintf(
				`{{"type":"stateMismatch","description":%s}}`,
				jq(fmt.tprintf("ifInState was %q but this account is at %q", want, have)),
			)
		}
	}
	updated := make([dynamic]string, 0, 4, context.temp_allocator)
	not_updated := make([dynamic][2]string, 0, 4, context.temp_allocator)
	destroyed := make([dynamic]string, 0, 4, context.temp_allocator)
	not_destroyed := make([dynamic][2]string, 0, 4, context.temp_allocator)

	old_state := account_state_string(a, context.temp_allocator)

	if upd, ok := sobj(args, "update"); ok {
		for id, patch in upd {
			box, m := account_message_by_jid(a, id)
			if m == nil {
				append(&not_updated, [2]string{id, "notFound"})
				continue
			}
			po, is := patch.(json.Object)
			if !is {
				append(&not_updated, [2]string{id, "invalidPatch"})
				continue
			}
			bad := false
			for k, v in po {
				// RFC 8621 4.6: a patch key is a JSON pointer relative to the
				// object, so flags come in as "keywords/$seen".
				if strings.has_prefix(k, "keywords/") {
					kw := k[len("keywords/"):]
					fl, fok := keyword_to_flag(kw)
					if !fok {
						// A custom keyword this server cannot store.
						continue
					}
					switch t in v {
					case json.Boolean:
						if bool(t) {m.flags |= {fl}} else {m.flags &~= {fl}}
					case json.Null:
						m.flags &~= {fl}
					case json.Integer, json.Float, json.String, json.Array, json.Object:
						bad = true
					}
					continue
				}
				if k == "keywords" {
					if kobj, isk := v.(json.Object); isk {
						keep := m.flags & {.Recent}
						m.flags = keep
						for kw, kv in kobj {
							if bb, isb := kv.(json.Boolean); isb && bool(bb) {
								if fl, fok := keyword_to_flag(kw); fok {
									m.flags |= {fl}
								}
							}
						}
						continue
					}
					bad = true
					continue
				}
				// Anything else is immutable on an Email.
				bad = true
			}
			if bad {
				append(&not_updated, [2]string{id, "invalidProperties"})
				continue
			}
			box.version += 1
			account_bump(a, id, .Updated)
			append(&updated, id)
		}
	}

	for e in sarr(args, "destroy") {
		id := jas(e)
		box, m := account_message_by_jid(a, id)
		if m == nil {
			append(&not_destroyed, [2]string{id, "notFound"})
			continue
		}
		m.expunged = true
		box.version += 1
		account_bump(a, id, .Destroyed)
		append(&destroyed, id)
	}

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`{{"accountId":%s,"oldState":%s,"newState":%s,"created":null,"updated":{{`,
		jq(jmapd_account_id(a)),
		jq(old_state),
		jq(account_state_string(a, context.temp_allocator)),
	)
	for id, i in updated {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, `%s:null`, jq(id))
	}
	strings.write_string(&sb, `},"destroyed":[`)
	for id, i in destroyed {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `],"notCreated":null,"notUpdated":{`)
	for e, i in not_updated {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, `%s:{{"type":%s}}`, jq(e[0]), jq(e[1]))
	}
	strings.write_string(&sb, `},"notDestroyed":{`)
	for e, i in not_destroyed {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, `%s:{{"type":%s}}`, jq(e[0]), jq(e[1]))
	}
	strings.write_string(&sb, `}}`)
	return strings.to_string(sb)
}

// --- Email/changes ----------------------------------------------------------

jmapd_email_changes :: proc(a: ^Account, args: json.Value) -> string {
	since := sstr(args, "sinceState")
	max_changes := sint(args, "maxChanges", 256)
	if max_changes <= 0 {max_changes = 256}
	// The state token is "s<N>"; anything else is a state this server cannot
	// reason about, which RFC 8620 5.2 says must be answered with
	// cannotCalculateChanges.
	if !strings.has_prefix(since, "s") {
		return `{"type":"cannotCalculateChanges","description":"unrecognised state token"}`
	}
	n, ok := strconv.parse_int(since[1:], 10)
	if !ok || n > a.state {
		return `{"type":"cannotCalculateChanges","description":"state token is from the future"}`
	}
	created := make([dynamic]string, 0, 8, context.temp_allocator)
	updated := make([dynamic]string, 0, 8, context.temp_allocator)
	destroyed := make([dynamic]string, 0, 8, context.temp_allocator)
	has_more := false
	count := 0
	new_state := n
	for ch in a.changes {
		if ch.state <= n {
			continue
		}
		if count >= max_changes {
			has_more = true
			break
		}
		switch ch.kind {
		case .Created:
			append(&created, ch.jid)
		case .Updated:
			append(&updated, ch.jid)
		case .Destroyed:
			append(&destroyed, ch.jid)
		}
		new_state = ch.state
		count += 1
	}
	if !has_more {
		new_state = a.state
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`{{"accountId":%s,"oldState":%s,"newState":%s,"hasMoreChanges":%s,"created":[`,
		jq(jmapd_account_id(a)),
		jq(since),
		jq(fmt.tprintf("s%d", new_state)),
		has_more ? "true" : "false",
	)
	for id, i in created {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `],"updated":[`)
	for id, i in updated {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `],"destroyed":[`)
	for id, i in destroyed {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&sb, jq(id))
	}
	strings.write_string(&sb, `]}`)
	return strings.to_string(sb)
}

// --- Thread/get -------------------------------------------------------------

jmapd_thread_get :: proc(a: ^Account, args: json.Value) -> string {
	want := sarr(args, "ids")
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`{{"accountId":%s,"state":%s,"list":[`,
		jq(jmapd_account_id(a)),
		jq(account_state_string(a, context.temp_allocator)),
	)
	first := true
	for e in want {
		tid := jas(e)
		ids := make([dynamic]string, 0, 8, context.temp_allocator)
		for i in 0 ..< len(a.boxes) {
			for m in a.boxes[i].msgs {
				if !m.expunged && m.thread_id == tid {
					append(&ids, m.jid)
				}
			}
		}
		if len(ids) == 0 {
			continue
		}
		if !first {strings.write_byte(&sb, ',')}
		first = false
		fmt.sbprintf(&sb, `{{"id":%s,"emailIds":[`, jq(tid))
		for id, i in ids {
			if i > 0 {strings.write_byte(&sb, ',')}
			strings.write_string(&sb, jq(id))
		}
		strings.write_string(&sb, `]}`)
	}
	strings.write_string(&sb, `],"notFound":[]}`)
	return strings.to_string(sb)
}
