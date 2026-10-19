package main

// JMAP: RFC 8620 (core) and the RFC 8621 mail subset, over the identity
// schema.
//
// THE MAPPING. A JMAP *account* is a Palmy *identity*. The session object
// lists, as accounts, exactly the identities the bearer token can reach — all
// of a person's identities for an unscoped token, one for a token scoped with
// `palm_identity` — because the list comes from `mail_identities()`, which
// reads through RLS. `primaryAccounts` names the scoped identity, or else the
// person's first personal identity. Each account has one JMAP Identity (RFC
// 8621 6), the identity's own address; JMAP's word and Palmy's coincide.
//
// Every method runs its queries through PostgREST with the caller's token, so
// a request naming an accountId the token cannot reach finds nothing even
// before the explicit accountNotFound check below.
//
// METHODS: Core/echo; Mailbox/get, /changes, /set; Email/query, /get, /set
// (create from JSON for drafts, keyword and mailbox patches, destroy),
// /changes, /import; Thread/get, /changes; Identity/get;
// EmailSubmission/set (create, with onSuccessDestroyEmail and
// onSuccessUpdateEmail), /get. Upload and download endpoints. Result
// references (RFC 8620 3.7) and creation-id references.
//
// NOT IMPLEMENTED: */queryChanges, Mailbox/query, SearchSnippet/get,
// VacationResponse, EmailSubmission/query and /changes, Email/copy, push
// (EventSource and WebSocket), the OR and NOT filter operators, `anchor`,
// header:* properties. Each fails with the RFC's own error, not silently.

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

JMAP_API_PATH :: "/jmap/api"
JMAP_DOWNLOAD_PREFIX :: "/jmap/download/"
JMAP_UPLOAD_PREFIX :: "/jmap/upload/"
PALM_CAP :: "urn:palmy:params:jmap:identity"
MAX_OBJECTS :: 500

Identity :: struct {
	id:           string,
	handle:       string,
	display_name: string,
	kind:         string,
	color:        string,
	address:      string,
}

// identities_of lists the identities a token can reach for mail.
identities_of :: proc(token: string) -> ([]Identity, string) {
	r := rest_rpc(token, "mail_identities", "{}")
	if !rest_ok(r) {
		return nil, r.err
	}
	out := make([dynamic]Identity, 0, 4, context.temp_allocator)
	for e in r.value.(json.Array) or_else nil {
		append(
			&out,
			Identity {
				id = jstr(e, "id"),
				handle = jstr(e, "handle"),
				display_name = jstr(e, "display_name"),
				kind = jstr(e, "kind"),
				color = jstr(e, "color"),
				address = jstr(e, "address"),
			},
		)
	}
	return out[:], ""
}

Jctx :: struct {
	token:   string,
	claims:  Claims,
	ids:     []Identity,
	created: map[string]string, // creation id -> server id, for "#ref" ids
	extra:   [dynamic][2]string, // implicit responses (EmailSubmission's Email/set)
}

ctx_identity :: proc(x: ^Jctx, acct: string) -> ^Identity {
	for &i in x.ids {
		if i.id == acct {
			return &i
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// HTTP routing
// ---------------------------------------------------------------------------

jmapd_serve :: proc(c: ^SConn) {
	for c.open {
		req, ok := httpd_read(c)
		if !ok {
			return
		}
		slog(c, "<- %s %s (%d octets)", req.method, req.path, len(req.body))
		jmapd_route(c, &req)
		free_all(context.temp_allocator)
		if req.close {
			return
		}
	}
}

jmapd_auth :: proc(c: ^SConn, req: ^Http_Req) -> (x: Jctx, ok: bool) {
	v, has := httpd_get(req, "authorization")
	if !has || !strings.has_prefix(v, "Bearer ") {
		jmapd_unauthorized(c, "a Supabase access token is required: Authorization: Bearer <jwt>")
		return x, false
	}
	x.token = strings.trim_space(v[7:])
	cl, err := jwt_verify(x.token, cfg.jwt_secret)
	if err != "" {
		jmapd_unauthorized(c, err)
		return x, false
	}
	x.claims = cl
	// Ensure the standard mailboxes exist for every identity this session can
	// reach, then list them. Both run as the caller.
	rest_rpc(x.token, "mail_bootstrap", "{}")
	ids, ierr := identities_of(x.token)
	if ierr != "" {
		httpd_error(c, 503, "Service Unavailable", ierr)
		return x, false
	}
	x.ids = ids
	x.created = make(map[string]string, 8, context.temp_allocator)
	x.extra = make([dynamic][2]string, 0, 2, context.temp_allocator)
	return x, true
}

jmapd_unauthorized :: proc(c: ^SConn, why: string) {
	body := fmt.tprintf(`{{"type":"about:blank","status":401,"detail":%s}}`, jq(why))
	httpd_respond(c, 401, "Unauthorized", "application/problem+json", transmute([]u8)body, false, "WWW-Authenticate: Bearer realm=\"palmy\"\r\n")
}

jmapd_route :: proc(c: ^SConn, req: ^Http_Req) {
	if req.path == "/health" {
		httpd_respond(c, 200, "OK", "text/plain", transmute([]u8)string("ok\n"))
		return
	}
	x, ok := jmapd_auth(c, req)
	if !ok {
		return
	}
	switch {
	case req.path == "/.well-known/jmap" && req.method == "GET":
		body := session_json(&x)
		httpd_respond(c, 200, "OK", "application/json; charset=utf-8", transmute([]u8)body)

	case req.path == JMAP_API_PATH && req.method == "POST":
		body, status := jmap_api(&x, req.body)
		ctype := status == 200 ? "application/json; charset=utf-8" : "application/problem+json"
		httpd_respond(c, status, status == 200 ? "OK" : "Bad Request", ctype, transmute([]u8)body)

	case strings.has_prefix(req.path, JMAP_DOWNLOAD_PREFIX) && req.method == "GET":
		segs := strings.split(req.path[len(JMAP_DOWNLOAD_PREFIX):], "/", context.temp_allocator)
		if len(segs) < 2 {
			httpd_error(c, 404, "Not Found", "the download URL is /jmap/download/{accountId}/{blobId}/{name}")
			return
		}
		acct := url_decode(segs[0])
		if ctx_identity(&x, acct) == nil {
			httpd_error(c, 404, "Not Found", "no such account")
			return
		}
		data, ctype, derr := blob_bytes(&x, acct, url_decode(segs[1]))
		if derr != "" {
			httpd_error(c, 404, "Not Found", derr)
			return
		}
		if acc := query_param(req.query, "accept"); acc != "" {
			ctype = acc
		}
		httpd_respond(c, 200, "OK", ctype, data)

	case strings.has_prefix(req.path, JMAP_UPLOAD_PREFIX) && req.method == "POST":
		acct := url_decode(req.path[len(JMAP_UPLOAD_PREFIX):])
		if ctx_identity(&x, acct) == nil {
			httpd_error(c, 404, "Not Found", "no such account")
			return
		}
		ctype, _ := httpd_get(req, "content-type")
		body, status := upload(&x, acct, req.body, ctype)
		httpd_respond(c, status, status == 201 ? "Created" : "Error", "application/json", transmute([]u8)body)

	case req.path == "/":
		httpd_respond(c, 200, "OK", "text/plain; charset=utf-8", transmute([]u8)string("Palmy mail. JMAP session discovery is at /.well-known/jmap\n"))

	case:
		httpd_error(c, 404, "Not Found", fmt.tprintf("no handler for %s %s", req.method, req.path))
	}
}

query_param :: proc(q, name: string) -> string {
	rest := q
	for kv in strings.split_iterator(&rest, "&") {
		if eq := strings.index_byte(kv, '='); eq > 0 && kv[:eq] == name {
			return url_decode(kv[eq + 1:])
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

primary_account :: proc(x: ^Jctx) -> string {
	if x.claims.palm_identity != "" {
		return x.claims.palm_identity
	}
	for i in x.ids {
		if i.kind == "personal" {
			return i.id
		}
	}
	return len(x.ids) > 0 ? x.ids[0].id : ""
}

session_json :: proc(x: ^Jctx) -> string {
	sb := strings.builder_make(context.temp_allocator)
	origin := cfg.public_url
	strings.write_byte(&sb, '{')
	fmt.sbprintf(&sb, `"username":%s,`, jq(x.claims.email != "" ? x.claims.email : x.claims.sub))
	fmt.sbprintf(&sb, `"apiUrl":%s,`, jq(fmt.tprintf("%s%s", origin, JMAP_API_PATH)))
	fmt.sbprintf(&sb, `"downloadUrl":%s,`, jq(fmt.tprintf("%s%s{{accountId}}/{{blobId}}/{{name}}?accept={{type}}", origin, JMAP_DOWNLOAD_PREFIX)))
	fmt.sbprintf(&sb, `"uploadUrl":%s,`, jq(fmt.tprintf("%s%s{{accountId}}", origin, JMAP_UPLOAD_PREFIX)))
	strings.write_string(&sb, `"eventSourceUrl":null,`)
	strings.write_string(&sb, `"capabilities":{`)
	fmt.sbprintf(&sb, `"urn:ietf:params:jmap:core":{{"maxSizeUpload":%d,"maxConcurrentUpload":4,"maxSizeRequest":%d,"maxConcurrentRequests":4,"maxCallsInRequest":32,"maxObjectsInGet":%d,"maxObjectsInSet":%d,"collationAlgorithms":["i;ascii-casemap"]}},`, SMTP_MAX_SIZE, HTTP_MAX_BODY, MAX_OBJECTS, MAX_OBJECTS)
	strings.write_string(&sb, `"urn:ietf:params:jmap:mail":{},"urn:ietf:params:jmap:submission":{},`)
	fmt.sbprintf(&sb, `%s:{{}}`, jq(PALM_CAP))
	strings.write_string(&sb, `},"accounts":{`)
	state := strings.builder_make(context.temp_allocator)
	for i, k in x.ids {
		if k > 0 {strings.write_byte(&sb, ',')}
		strings.write_string(&state, i.id)
		fmt.sbprintf(&sb, `%s:{{"name":%s,"isPersonal":true,"isReadOnly":false,"accountCapabilities":{{`, jq(i.id), jq(i.address))
		fmt.sbprintf(&sb, `"urn:ietf:params:jmap:mail":{{"maxMailboxesPerEmail":null,"maxMailboxDepth":10,"maxSizeMailboxName":200,"maxSizeAttachmentsPerEmail":%d,"emailQuerySortOptions":["receivedAt","sentAt","size","subject"],"mayCreateTopLevelMailbox":true}},`, SMTP_MAX_SIZE)
		strings.write_string(&sb, `"urn:ietf:params:jmap:submission":{"maxDelayedSend":0,"submissionExtensions":{}},`)
		fmt.sbprintf(&sb, `%s:{{"handle":%s,"displayName":%s,"kind":%s,"color":%s,"address":%s}}}}}}`, jq(PALM_CAP), jq(i.handle), jq(i.display_name), jq(i.kind), jq(i.color), jq(i.address))
	}
	strings.write_string(&sb, `},`)
	p := primary_account(x)
	fmt.sbprintf(&sb, `"primaryAccounts":{{"urn:ietf:params:jmap:mail":%s,"urn:ietf:params:jmap:submission":%s,%s:%s}},`, jq_null(p), jq_null(p), jq(PALM_CAP), jq_null(p))
	fmt.sbprintf(&sb, `"state":%s}}`, jq(sha256_hex(transmute([]u8)strings.to_string(state))[:16]))
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The API endpoint
// ---------------------------------------------------------------------------

jmap_api :: proc(x: ^Jctx, body: []u8) -> (out: string, status: int) {
	v, perr := json.parse(body, .JSON, true, context.temp_allocator)
	if perr != nil {
		return fmt.tprintf(`{{"type":"urn:ietf:params:jmap:error:notJSON","status":400,"detail":%s}}`, jq(fmt.tprintf("%v", perr))), 400
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"the request is not a JSON object"}`, 400
	}
	using_v, has_using := obj["using"]
	if !has_using {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"missing \"using\""}`, 400
	}
	caps := make(map[string]bool, 8, context.temp_allocator)
	for e in using_v.(json.Array) or_else nil {
		s := jas(e)
		switch s {
		case "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission", PALM_CAP:
			caps[s] = true
		case:
			return fmt.tprintf(`{{"type":"urn:ietf:params:jmap:error:unknownCapability","status":400,"detail":%s}}`, jq(fmt.tprintf("unknown capability %q", s))), 400
		}
	}
	calls, calls_ok := obj["methodCalls"].(json.Array)
	if !calls_ok {
		return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"methodCalls must be an array"}`, 400
	}
	if len(calls) > 32 {
		return `{"type":"urn:ietf:params:jmap:error:limit","limit":"maxCallsInRequest","status":400}`, 400
	}
	// RFC 8620 3.3: createdIds comes back only when the request sent it.
	cids, echo_created := obj["createdIds"].(json.Object)
	if echo_created {
		for k, e in cids {
			x.created[k] = jas(e)
		}
	}

	res_ids := make([dynamic]string, 0, len(calls), context.temp_allocator)
	res_names := make([dynamic]string, 0, len(calls), context.temp_allocator)
	res_json := make([dynamic]string, 0, len(calls), context.temp_allocator)
	res_vals := make([dynamic]json.Value, 0, len(calls), context.temp_allocator)
	push :: proc(ids, names, jsons: ^[dynamic]string, vals: ^[dynamic]json.Value, id, name, js: string) {
		append(ids, id)
		append(names, name)
		append(jsons, js)
		rv, _ := json.parse(transmute([]u8)js, .JSON, true, context.temp_allocator)
		append(vals, rv)
	}

	for cv in calls {
		ca, is := cv.(json.Array)
		if !is || len(ca) != 3 {
			return `{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"each invocation is [name, arguments, callId]"}`, 400
		}
		name := jas(ca[0])
		id := jas(ca[2])
		need := "urn:ietf:params:jmap:mail"
		if strings.has_prefix(name, "Core/") {
			need = "urn:ietf:params:jmap:core"
		} else if strings.has_prefix(name, "EmailSubmission/") || strings.has_prefix(name, "Identity/") {
			need = "urn:ietf:params:jmap:submission"
		}
		if !caps[need] {
			push(&res_ids, &res_names, &res_json, &res_vals, id, "error", fmt.tprintf(`{{"type":"unknownMethod","description":%s}}`, jq(fmt.tprintf("%s needs %s in using", name, need))))
			continue
		}
		resolved, rerr := resolve_backrefs(ca[1], res_ids[:], res_names[:], res_vals[:])
		if rerr != "" {
			push(&res_ids, &res_names, &res_json, &res_vals, id, "error", fmt.tprintf(`{{"type":"invalidResultReference","description":%s}}`, jq(rerr)))
			continue
		}
		args, _ := json.parse(transmute([]u8)resolved, .JSON, true, context.temp_allocator)
		clear(&x.extra)
		rname, rjson := jmap_method(x, name, args)
		push(&res_ids, &res_names, &res_json, &res_vals, id, rname, rjson)
		for e in x.extra {
			push(&res_ids, &res_names, &res_json, &res_vals, id, e[0], e[1])
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"methodResponses":[`)
	for i in 0 ..< len(res_ids) {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, "[%s,%s,%s]", jq(res_names[i]), res_json[i], jq(res_ids[i]))
	}
	strings.write_string(&sb, `]`)
	if echo_created {
		strings.write_string(&sb, `,"createdIds":{`)
		first := true
		for k, val in x.created {
			if !first {strings.write_byte(&sb, ',')}
			first = false
			fmt.sbprintf(&sb, "%s:%s", jq(k), jq(val))
		}
		strings.write_byte(&sb, '}')
	}
	ss := session_json(x)
	sv, _ := json.parse(transmute([]u8)ss, .JSON, true, context.temp_allocator)
	fmt.sbprintf(&sb, `,"sessionState":%s}}`, jq(jstr(sv, "state")))
	return strings.to_string(sb), 200
}

merr :: proc(type: string, desc := "") -> (string, string) {
	if desc == "" {
		return "error", fmt.tprintf(`{{"type":%s}}`, jq(type))
	}
	return "error", fmt.tprintf(`{{"type":%s,"description":%s}}`, jq(type), jq(desc))
}

jmap_method :: proc(x: ^Jctx, name: string, args: json.Value) -> (string, string) {
	if name == "Core/echo" {
		return "Core/echo", render_json(args)
	}
	if _, is := args.(json.Object); !is {
		return merr("invalidArguments", "arguments must be an object")
	}
	acct := jstr(args, "accountId")
	if acct == "" {
		acct = primary_account(x)
	}
	if ctx_identity(x, acct) == nil {
		return merr("accountNotFound")
	}
	switch name {
	case "Mailbox/get":
		return mailbox_get(x, acct, args)
	case "Mailbox/changes":
		return changes_method(x, acct, "Mailbox", args)
	case "Mailbox/set":
		return mailbox_set(x, acct, args)
	case "Email/query":
		return email_query(x, acct, args)
	case "Email/get":
		return email_get(x, acct, args)
	case "Email/set":
		return email_set(x, acct, args)
	case "Email/changes":
		return changes_method(x, acct, "Email", args)
	case "Email/import":
		return email_import(x, acct, args)
	case "Thread/get":
		return thread_get(x, acct, args)
	case "Thread/changes":
		return changes_method(x, acct, "Thread", args)
	case "Identity/get":
		return identity_get(x, acct, args)
	case "EmailSubmission/set":
		return submission_set(x, acct, args)
	case "EmailSubmission/get":
		return submission_get(x, acct, args)
	case "EmailSubmission/changes":
		return changes_method(x, acct, "EmailSubmission", args)
	}
	return merr("unknownMethod", fmt.tprintf("%s is not implemented by this server", name))
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// A state string is the highest change-log sequence number for that type in
// that identity. It only moves forwards, which is all /changes needs.
state_of :: proc(x: ^Jctx, acct, type: string) -> string {
	r := rest_get(x.token, fmt.tprintf("/mail_changes?select=seq&identity_id=eq.%s&type=eq.%s&order=seq.desc&limit=1", acct, type))
	if a, ok := r.value.(json.Array); ok && len(a) > 0 {
		return fmt.tprintf("%d", jint(a[0], "seq"))
	}
	return "0"
}

changes_method :: proc(x: ^Jctx, acct, type: string, args: json.Value) -> (string, string) {
	since_s := jstr(args, "sinceState")
	since, ok := strconv.parse_i64(since_s, 10)
	if !ok {
		return merr("cannotCalculateChanges", "unknown sinceState")
	}
	max := int(jint(args, "maxChanges"))
	if max <= 0 || max > 5000 {
		max = 5000
	}
	// Thread changes are derived from Email changes: a thread changes when a
	// message joins or leaves it, and the thread rows themselves only record
	// creation and destruction.
	r := rest_get(x.token, fmt.tprintf("/mail_changes?select=seq,object_id,kind&identity_id=eq.%s&type=eq.%s&seq=gt.%d&order=seq&limit=%d", acct, type, since, max + 1))
	if !rest_ok(r) {
		return merr("serverFail", r.err)
	}
	rows := r.value.(json.Array) or_else nil
	more := len(rows) > max
	if more {
		resize(&rows, max)
	}
	first := make(map[string]string, len(rows), context.temp_allocator) // object -> first kind seen
	last := make(map[string]string, len(rows), context.temp_allocator)
	order := make([dynamic]string, 0, len(rows), context.temp_allocator)
	new_state := since
	for e in rows {
		oid := jstr(e, "object_id")
		if oid not_in first {
			first[oid] = jstr(e, "kind")
			append(&order, oid)
		}
		last[oid] = jstr(e, "kind")
		new_state = jint(e, "seq")
	}
	created := make([dynamic]string, 0, 8, context.temp_allocator)
	updated := make([dynamic]string, 0, 8, context.temp_allocator)
	destroyed := make([dynamic]string, 0, 8, context.temp_allocator)
	for oid in order {
		f, l := first[oid], last[oid]
		switch {
		case f == "created" && l == "destroyed":
		// born and gone inside the window: the client never needs to know
		case l == "destroyed":
			append(&destroyed, oid)
		case f == "created":
			append(&created, oid)
		case:
			append(&updated, oid)
		}
	}
	extra := type == "Mailbox" ? `,"updatedProperties":null` : ""
	return fmt.tprintf("%s/changes", type), fmt.tprintf(
		`{{"accountId":%s,"oldState":%s,"newState":%s,"hasMoreChanges":%v,"created":%s,"updated":%s,"destroyed":%s%s}}`,
		jq(acct), jq(since_s), jq(fmt.tprintf("%d", new_state)), more, jq_list(created[:]), jq_list(updated[:]), jq_list(destroyed[:]), extra,
	)
}

// ids_arg reads an `ids` argument: (list, present, null). Creation-id
// references ("#c1") are resolved; anything that is not a uuid afterwards is
// returned as-is so it lands in notFound.
ids_arg :: proc(x: ^Jctx, args: json.Value, key := "ids") -> (ids: []string, given: bool) {
	e, has := jget(args, key)
	if !has {
		return nil, false
	}
	if _, is_null := e.(json.Null); is_null {
		return nil, false
	}
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	for v in e.(json.Array) or_else nil {
		append(&out, resolve_id(x, jas(v)))
	}
	return out[:], true
}

resolve_id :: proc(x: ^Jctx, id: string) -> string {
	if strings.has_prefix(id, "#") {
		if v, ok := x.created[id[1:]]; ok {
			return v
		}
	}
	return id
}

uuid_list :: proc(ids: []string) -> (valid: []string, csv: string) {
	out := make([dynamic]string, 0, len(ids), context.temp_allocator)
	for i in ids {
		if is_uuid(i) {
			append(&out, strings.to_lower(i, context.temp_allocator))
		}
	}
	return out[:], strings.join(out[:], ",", context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Mailbox
// ---------------------------------------------------------------------------

mailbox_get :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	ids, given := ids_arg(x, args)
	path := fmt.tprintf("/mail_mailboxes?select=id,parent_id,name,role,sort_order&identity_id=eq.%s&order=sort_order,name", acct)
	if given {
		_, csv := uuid_list(ids)
		path = fmt.tprintf("%s&id=in.(%s)", path, csv)
	}
	r := rest_get(x.token, path)
	if !rest_ok(r) {
		return merr("serverFail", r.err)
	}
	cr := rest_rpc(x.token, "mail_mailbox_counts", fmt.tprintf(`{{"p_identity":%s}}`, jq(acct)))
	counts := make(map[string]json.Value, 16, context.temp_allocator)
	for e in cr.value.(json.Array) or_else nil {
		counts[jstr(e, "mailbox_id")] = e
	}
	sb := strings.builder_make(context.temp_allocator)
	found := make(map[string]bool, 16, context.temp_allocator)
	strings.write_byte(&sb, '[')
	for e, i in r.value.(json.Array) or_else nil {
		if i > 0 {strings.write_byte(&sb, ',')}
		id := jstr(e, "id")
		found[id] = true
		role := jstr(e, "role")
		c := counts[id]
		// `outbox` is not in the IANA mailbox role registry RFC 8621 draws
		// from, so it is not claimed as a role on the wire; the name says it.
		wire_role := role == "outbox" ? "" : role
		fmt.sbprintf(
			&sb,
			`{{"id":%s,"name":%s,"parentId":%s,"role":%s,"sortOrder":%d,"totalEmails":%d,"unreadEmails":%d,"totalThreads":%d,"unreadThreads":%d,"myRights":{{"mayReadItems":true,"mayAddItems":true,"mayRemoveItems":true,"maySetSeen":true,"maySetKeywords":true,"mayCreateChild":true,"mayRename":%v,"mayDelete":%v,"maySubmit":true}},"isSubscribed":true}}`,
			jq(id), jq(jstr(e, "name")), jq_null(jstr(e, "parent_id")), jq_null(wire_role), jint(e, "sort_order"),
			jint(c, "total_emails"), jint(c, "unread_emails"), jint(c, "total_threads"), jint(c, "unread_threads"),
			role == "", role == "",
		)
	}
	strings.write_byte(&sb, ']')
	nf := make([dynamic]string, 0, 0, context.temp_allocator)
	for i in ids {
		if !found[strings.to_lower(i, context.temp_allocator)] {append(&nf, i)}
	}
	return "Mailbox/get", fmt.tprintf(`{{"accountId":%s,"state":%s,"list":%s,"notFound":%s}}`, jq(acct), jq(state_of(x, acct, "Mailbox")), strings.to_string(sb), jq_list(nf[:]))
}

mailbox_set :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	old := state_of(x, acct, "Mailbox")
	created := strings.builder_make(context.temp_allocator)
	not_created := strings.builder_make(context.temp_allocator)
	updated := strings.builder_make(context.temp_allocator)
	not_updated := strings.builder_make(context.temp_allocator)
	destroyed := make([dynamic]string, 0, 4, context.temp_allocator)
	not_destroyed := strings.builder_make(context.temp_allocator)
	sep :: proc(sb: ^strings.Builder) {if strings.builder_len(sb^) > 0 {strings.write_byte(sb, ',')}}
	set_err :: proc(type, desc: string) -> string {return fmt.tprintf(`{{"type":%s,"description":%s}}`, jq(type), jq(desc))}

	if cr, ok := jget(args, "create"); ok {
		for cid, spec in cr.(json.Object) or_else nil {
			name := jstr(spec, "name")
			parent := resolve_id(x, jstr(spec, "parentId"))
			body := fmt.tprintf(`{{"identity_id":%s,"name":%s,"parent_id":%s,"sort_order":%d}}`, jq(acct), jq(name), jq_null(parent), jint(spec, "sortOrder"))
			r := rest_call(x.token, "POST", "/mail_mailboxes?select=id", body, "return=representation")
			if !rest_ok(r) {
				sep(&not_created)
				fmt.sbprintf(&not_created, "%s:%s", jq(cid), set_err("invalidProperties", r.err))
				continue
			}
			a := r.value.(json.Array) or_else nil
			id := len(a) > 0 ? jstr(a[0], "id") : ""
			x.created[cid] = strings.clone(id, context.temp_allocator)
			sep(&created)
			fmt.sbprintf(&created, `%s:{{"id":%s}}`, jq(cid), jq(id))
		}
	}
	if up, ok := jget(args, "update"); ok {
		for id, patch in up.(json.Object) or_else nil {
			if !is_uuid(id) {
				sep(&not_updated)
				fmt.sbprintf(&not_updated, "%s:%s", jq(id), set_err("notFound", ""))
				continue
			}
			parts := make([dynamic]string, 0, 3, context.temp_allocator)
			if v, has := jget(patch, "name"); has {append(&parts, fmt.tprintf(`"name":%s`, jq(jas(v))))}
			if v, has := jget(patch, "parentId"); has {append(&parts, fmt.tprintf(`"parent_id":%s`, jq_null(resolve_id(x, jas(v)))))}
			if _, has := jget(patch, "sortOrder"); has {append(&parts, fmt.tprintf(`"sort_order":%d`, jint(patch, "sortOrder")))}
			r := rest_call(x.token, "PATCH", fmt.tprintf("/mail_mailboxes?id=eq.%s&identity_id=eq.%s&role=is.null&select=id", id, acct), fmt.tprintf("{{%s}}", strings.join(parts[:], ",", context.temp_allocator)), "return=representation")
			if !rest_ok(r) || len(r.value.(json.Array) or_else nil) == 0 {
				sep(&not_updated)
				fmt.sbprintf(&not_updated, "%s:%s", jq(id), set_err(rest_ok(r) ? "notFound" : "invalidProperties", rest_ok(r) ? "no such mailbox, or it has a role and cannot be renamed" : r.err))
				continue
			}
			sep(&updated)
			fmt.sbprintf(&updated, "%s:null", jq(id))
		}
	}
	for id in jstrs(args, "destroy") {
		if !is_uuid(id) {
			sep(&not_destroyed)
			fmt.sbprintf(&not_destroyed, "%s:%s", jq(id), set_err("notFound", ""))
			continue
		}
		used := rest_get(x.token, fmt.tprintf("/mail_messages?select=id&identity_id=eq.%s&mailbox_ids=cs.{%s}&limit=1", acct, id))
		if len(used.value.(json.Array) or_else nil) > 0 {
			sep(&not_destroyed)
			fmt.sbprintf(&not_destroyed, "%s:%s", jq(id), set_err("mailboxHasEmail", "move or destroy its messages first"))
			continue
		}
		r := rest_call(x.token, "DELETE", fmt.tprintf("/mail_mailboxes?id=eq.%s&identity_id=eq.%s&role=is.null&select=id", id, acct), "", "return=representation")
		if !rest_ok(r) || len(r.value.(json.Array) or_else nil) == 0 {
			sep(&not_destroyed)
			fmt.sbprintf(&not_destroyed, "%s:%s", jq(id), set_err("forbidden", "no such mailbox, or it has a role and cannot be destroyed"))
			continue
		}
		append(&destroyed, id)
	}
	return "Mailbox/set", fmt.tprintf(
		`{{"accountId":%s,"oldState":%s,"newState":%s,"created":{{%s}},"notCreated":{{%s}},"updated":{{%s}},"notUpdated":{{%s}},"destroyed":%s,"notDestroyed":{{%s}}}}`,
		jq(acct), jq(old), jq(state_of(x, acct, "Mailbox")),
		strings.to_string(created), strings.to_string(not_created), strings.to_string(updated), strings.to_string(not_updated),
		jq_list(destroyed[:]), strings.to_string(not_destroyed),
	)
}

// ---------------------------------------------------------------------------
// Email/query
// ---------------------------------------------------------------------------

// pg_like makes a client's search text safe inside a PostgREST ilike value:
// the filter grammar's own characters are dropped, the rest is URL-encoded.
pg_like :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '*', ',', '(', ')', '"', '\\', '%', '_', '.', ':':
			strings.write_byte(&sb, ' ')
		case:
			strings.write_byte(&sb, s[i])
		}
	}
	return url_encode(strings.to_lower(strings.trim_space(strings.to_string(sb)), context.temp_allocator))
}

pg_time :: proc(s: string) -> string {
	// UTCDate from the client: only digits, '-', ':', 'T', 'Z' survive.
	for i in 0 ..< len(s) {
		ch := s[i]
		if !((ch >= '0' && ch <= '9') || ch == '-' || ch == ':' || ch == 'T' || ch == 'Z' || ch == '.') {
			return ""
		}
	}
	return s
}

filter_to_pg :: proc(x: ^Jctx, f: json.Value, sb: ^strings.Builder) -> string {
	if f == nil {
		return ""
	}
	if _, is_null := f.(json.Null); is_null {
		return ""
	}
	if op := jstr(f, "operator"); op != "" {
		if op != "AND" {
			return "only the AND filter operator is supported"
		}
		for c in jarr(f, "conditions") {
			if e := filter_to_pg(x, c, sb); e != "" {
				return e
			}
		}
		return ""
	}
	for k, v in f.(json.Object) or_else nil {
		switch k {
		case "inMailbox":
			id := resolve_id(x, jas(v))
			if !is_uuid(id) {return "inMailbox is not a mailbox id"}
			fmt.sbprintf(sb, "&mailbox_ids=cs.{{%s}}", id)
		case "inMailboxOtherThan":
			ids, csv := uuid_list(jstrs(f, k))
			if len(ids) > 0 {fmt.sbprintf(sb, "&mailbox_ids=not.cd.{{%s}}", csv)}
		case "hasKeyword":
			fmt.sbprintf(sb, "&keywords=cs.%s", url_encode(pg_array({strings.to_lower(jas(v), context.temp_allocator)})))
		case "notKeyword":
			fmt.sbprintf(sb, "&keywords=not.cs.%s", url_encode(pg_array({strings.to_lower(jas(v), context.temp_allocator)})))
		case "hasAttachment":
			b, _ := v.(json.Boolean)
			fmt.sbprintf(sb, "&has_attachment=is.%v", bool(b))
		case "before":
			fmt.sbprintf(sb, "&received_at=lt.%s", pg_time(jas(v)))
		case "after":
			fmt.sbprintf(sb, "&received_at=gte.%s", pg_time(jas(v)))
		case "minSize":
			fmt.sbprintf(sb, "&size=gte.%d", jint(f, k))
		case "maxSize":
			fmt.sbprintf(sb, "&size=lt.%d", jint(f, k))
		case "text", "from", "to", "cc", "bcc", "body":
			// All matched against the folded search column (subject, preview,
			// addresses). Coarser than the RFC asks for; stated in the header.
			fmt.sbprintf(sb, "&search=ilike.*%s*", pg_like(jas(v)))
		case "subject":
			fmt.sbprintf(sb, "&subject=ilike.*%s*", pg_like(jas(v)))
		case:
			return fmt.tprintf("the %q filter is not supported", k)
		}
	}
	return ""
}

email_query :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	if _, has := jget(args, "anchor"); has {
		if a := jstr(args, "anchor"); a != "" {
			return merr("unsupportedFilter", "anchor is not supported")
		}
	}
	fsb := strings.builder_make(context.temp_allocator)
	fv, _ := jget(args, "filter")
	if e := filter_to_pg(x, fv, &fsb); e != "" {
		return merr("unsupportedFilter", e)
	}
	order := strings.builder_make(context.temp_allocator)
	for s in jarr(args, "sort") {
		col := ""
		switch jstr(s, "property") {
		case "receivedAt":
			col = "received_at"
		case "sentAt":
			col = "sent_at"
		case "size":
			col = "size"
		case "subject":
			col = "subject"
		case:
			return merr("unsupportedSort", jstr(s, "property"))
		}
		asc := true
		if v, has := jget(s, "isAscending"); has {
			b, _ := v.(json.Boolean)
			asc = bool(b)
		}
		if strings.builder_len(order) > 0 {strings.write_byte(&order, ',')}
		fmt.sbprintf(&order, "%s.%s", col, asc ? "asc" : "desc")
	}
	if strings.builder_len(order) == 0 {
		strings.write_string(&order, "received_at.desc")
	}
	strings.write_string(&order, ",id")
	position := int(jint(args, "position"))
	if position < 0 {
		position = 0
	}
	limit := 256
	if _, has := jget(args, "limit"); has {
		limit = int(jint(args, "limit"))
	}
	if limit < 0 {
		return merr("invalidArguments", "limit must not be negative")
	}
	limit = min(limit, 1000)
	collapse := jbool(args, "collapseThreads")
	calc := jbool(args, "calculateTotal")

	base := fmt.tprintf("/mail_messages?select=id,thread_id&identity_id=eq.%s%s&order=%s", acct, strings.to_string(fsb), strings.to_string(order))
	ids := make([dynamic]string, 0, limit, context.temp_allocator)
	total := -1
	if collapse {
		r := rest_get(x.token, fmt.tprintf("%s&limit=5000", base))
		if !rest_ok(r) {
			return merr("serverFail", r.err)
		}
		seen := make(map[string]bool, 64, context.temp_allocator)
		all := make([dynamic]string, 0, 64, context.temp_allocator)
		for e in r.value.(json.Array) or_else nil {
			t := jstr(e, "thread_id")
			if seen[t] {continue}
			seen[t] = true
			append(&all, jstr(e, "id"))
		}
		total = len(all)
		for i in position ..< min(position + limit, len(all)) {
			append(&ids, all[i])
		}
	} else {
		r := rest_call(x.token, "GET", fmt.tprintf("%s&offset=%d&limit=%d", base, position, limit), "", calc ? "count=exact" : "")
		if !rest_ok(r) {
			return merr("serverFail", r.err)
		}
		for e in r.value.(json.Array) or_else nil {
			append(&ids, jstr(e, "id"))
		}
		for h in r.headers {
			if h[0] == "content-range" {
				if sl := strings.index_byte(h[1], '/'); sl >= 0 {
					total, _ = strconv.parse_int(h[1][sl + 1:], 10)
				}
			}
		}
	}
	total_s := calc && total >= 0 ? fmt.tprintf(`,"total":%d`, total) : ""
	return "Email/query", fmt.tprintf(
		`{{"accountId":%s,"queryState":%s,"canCalculateChanges":false,"position":%d,"ids":%s%s,"limit":%d}}`,
		jq(acct), jq(state_of(x, acct, "Email")), position, jq_list(ids[:]), total_s, limit,
	)
}

// ---------------------------------------------------------------------------
// Email/get
// ---------------------------------------------------------------------------

DEFAULT_EMAIL_PROPS := []string {
	"id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt", "messageId", "inReplyTo",
	"references", "sender", "from", "to", "cc", "bcc", "replyTo", "subject", "sentAt", "hasAttachment",
	"preview", "bodyValues", "textBody", "htmlBody", "attachments",
}

BODY_PROPS :: []string{"bodyStructure", "textBody", "htmlBody", "attachments", "bodyValues"}

// pg_ts turns PostgREST's "2026-10-19T09:49:20.123456+00:00" into a UTCDate.
pg_ts :: proc(s: string) -> string {
	if len(s) < 19 {
		return ""
	}
	rest := s[19:]
	off := 0
	if i := strings.index_any(rest, "+-Z"); i >= 0 && rest[i] != 'Z' && len(rest) >= i + 6 {
		hh, _ := strconv.parse_int(rest[i + 1:i + 3], 10)
		mm, _ := strconv.parse_int(rest[i + 4:i + 6], 10)
		off = (hh * 60 + mm) * 60
		if rest[i] == '-' {off = -off}
	}
	if off == 0 {
		return fmt.tprintf("%sZ", s[:19])
	}
	y, _ := strconv.parse_int(s[0:4], 10)
	mo, _ := strconv.parse_int(s[5:7], 10)
	d, _ := strconv.parse_int(s[8:10], 10)
	h, _ := strconv.parse_int(s[11:13], 10)
	mi, _ := strconv.parse_int(s[14:16], 10)
	se, _ := strconv.parse_int(s[17:19], 10)
	return iso8601(days_from_civil(y, mo, d) * 86400 + i64(h * 3600 + mi * 60 + se - off))
}

set_json :: proc(xs: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	for k, i in xs {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, "%s:true", jq(k))
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

addr_field :: proc(row: json.Value, key: string) -> string {
	v, ok := jget(row, key)
	if !ok {
		return "null"
	}
	if a, is := v.(json.Array); is && len(a) > 0 {
		return render_json(v)
	}
	return "null"
}

list_or_null :: proc(xs: []string) -> string {
	return len(xs) == 0 ? "null" : jq_list(xs)
}

email_get :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	ids, given := ids_arg(x, args)
	props := DEFAULT_EMAIL_PROPS
	if pv, has := jget(args, "properties"); has {
		if _, is_null := pv.(json.Null); !is_null {
			props = jstrs(args, "properties")
		}
	}
	need_body := false
	for p in props {
		switch p {
		case "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt", "messageId", "inReplyTo",
		     "references", "sender", "from", "to", "cc", "bcc", "replyTo", "subject", "sentAt", "hasAttachment", "preview":
		case "bodyStructure", "textBody", "htmlBody", "attachments", "bodyValues":
			need_body = true
		case:
			return merr("invalidArguments", fmt.tprintf("the %q property is not supported", p))
		}
	}
	fetch_text := jbool(args, "fetchTextBodyValues")
	fetch_html := jbool(args, "fetchHTMLBodyValues")
	fetch_all := jbool(args, "fetchAllBodyValues")
	max_bytes := int(jint(args, "maxBodyValueBytes"))

	path := fmt.tprintf("/mail_messages?select=id,thread_id,blob_id,mailbox_ids,keywords,size,received_at,sent_at,message_id,in_reply_to,references,subject,from,sender,reply_to,to,cc,bcc,preview,has_attachment&identity_id=eq.%s&order=received_at", acct)
	if given {
		if len(ids) > MAX_OBJECTS {
			return merr("requestTooLarge")
		}
		_, csv := uuid_list(ids)
		path = fmt.tprintf("%s&id=in.(%s)", path, csv)
	} else {
		path = fmt.tprintf("%s&limit=%d", path, MAX_OBJECTS)
	}
	r := rest_get(x.token, path)
	if !rest_ok(r) {
		return merr("serverFail", r.err)
	}
	rows := r.value.(json.Array) or_else nil

	raws := make(map[string][]u8, len(rows), context.temp_allocator)
	if need_body && len(rows) > 0 {
		blobs := make([dynamic]string, 0, len(rows), context.temp_allocator)
		for e in rows {append(&blobs, jstr(e, "blob_id"))}
		br := rest_get(x.token, fmt.tprintf("/mail_blobs?select=id,raw&identity_id=eq.%s&id=in.(%s)", acct, strings.join(blobs[:], ",", context.temp_allocator)))
		for e in br.value.(json.Array) or_else nil {
			if raw, ok := bytea_decode(jstr(e, "raw"), context.temp_allocator); ok {
				raws[jstr(e, "id")] = raw
			}
		}
	}

	by_id := make(map[string]json.Value, len(rows), context.temp_allocator)
	for e in rows {by_id[jstr(e, "id")] = e}
	order := ids
	if !given {
		o := make([dynamic]string, 0, len(rows), context.temp_allocator)
		for e in rows {append(&o, jstr(e, "id"))}
		order = o[:]
	}

	sb := strings.builder_make(context.temp_allocator)
	nf := make([dynamic]string, 0, 0, context.temp_allocator)
	strings.write_byte(&sb, '[')
	n := 0
	for want in order {
		row, ok := by_id[strings.to_lower(want, context.temp_allocator)]
		if !ok {
			append(&nf, want)
			continue
		}
		if n > 0 {strings.write_byte(&sb, ',')}
		n += 1
		blob := jstr(row, "blob_id")
		root: MM_Part
		split: Body_Split
		parsed := false
		if raw, has := raws[blob]; has {
			root = mm_parse(raw, "", 0, context.temp_allocator)
			split = split_body(&root)
			parsed = true
		}
		strings.write_byte(&sb, '{')
		fmt.sbprintf(&sb, `"id":%s`, jq(jstr(row, "id")))
		for p in props {
			if p == "id" {continue}
			fmt.sbprintf(&sb, ",%s:", jq(p))
			switch p {
			case "blobId":
				strings.write_string(&sb, jq(blob))
			case "threadId":
				strings.write_string(&sb, jq(jstr(row, "thread_id")))
			case "mailboxIds":
				strings.write_string(&sb, set_json(jstrs(row, "mailbox_ids")))
			case "keywords":
				strings.write_string(&sb, set_json(jstrs(row, "keywords")))
			case "size":
				fmt.sbprintf(&sb, "%d", jint(row, "size"))
			case "receivedAt":
				strings.write_string(&sb, jq(pg_ts(jstr(row, "received_at"))))
			case "sentAt":
				strings.write_string(&sb, jq_null(pg_ts(jstr(row, "sent_at"))))
			case "messageId":
				mid := jstr(row, "message_id")
				strings.write_string(&sb, mid == "" ? "null" : jq_list({mid}))
			case "inReplyTo":
				strings.write_string(&sb, list_or_null(jstrs(row, "in_reply_to")))
			case "references":
				strings.write_string(&sb, list_or_null(jstrs(row, "references")))
			case "sender", "from", "to", "cc", "bcc":
				strings.write_string(&sb, addr_field(row, p))
			case "replyTo":
				strings.write_string(&sb, addr_field(row, "reply_to"))
			case "subject":
				strings.write_string(&sb, jq(jstr(row, "subject")))
			case "hasAttachment":
				fmt.sbprintf(&sb, "%v", jbool(row, "has_attachment"))
			case "preview":
				strings.write_string(&sb, jq(jstr(row, "preview")))
			case "bodyStructure":
				if !parsed {strings.write_string(&sb, "null");continue}
				strings.write_string(&sb, part_json(&root, root.main == "multipart" ? "" : "1", blob, true))
			case "textBody", "htmlBody", "attachments":
				if !parsed {strings.write_string(&sb, "[]");continue}
				list := p == "textBody" ? split.text_body[:] : (p == "htmlBody" ? split.html_body[:] : split.attachments[:])
				strings.write_byte(&sb, '[')
				for l, i in list {
					if i > 0 {strings.write_byte(&sb, ',')}
					strings.write_string(&sb, part_json(l.part, l.id, blob, false))
				}
				strings.write_byte(&sb, ']')
			case "bodyValues":
				strings.write_byte(&sb, '{')
				if parsed {
					emitted := make(map[string]bool, 4, context.temp_allocator)
					k := 0
					emit :: proc(sb: ^strings.Builder, emitted: ^map[string]bool, k: ^int, l: Body_Leaf, max_bytes: int) {
						if emitted[l.id] || l.part.main != "text" {return}
						emitted[l.id] = true
						v := l.part.text
						trunc := false
						if max_bytes > 0 && len(v) > max_bytes {
							cut := max_bytes
							for cut > 0 && (v[cut] & 0xC0) == 0x80 {cut -= 1}
							v = v[:cut]
							trunc = true
						}
						if k^ > 0 {strings.write_byte(sb, ',')}
						k^ += 1
						fmt.sbprintf(sb, `%s:{{"value":%s,"isEncodingProblem":false,"isTruncated":%v}}`, jq(l.id), jq(v), trunc)
					}
					if fetch_text || fetch_all {for l in split.text_body {emit(&sb, &emitted, &k, l, max_bytes)}}
					if fetch_html || fetch_all {for l in split.html_body {emit(&sb, &emitted, &k, l, max_bytes)}}
				}
				strings.write_byte(&sb, '}')
			}
		}
		strings.write_byte(&sb, '}')
	}
	strings.write_byte(&sb, ']')
	return "Email/get", fmt.tprintf(`{{"accountId":%s,"state":%s,"list":%s,"notFound":%s}}`, jq(acct), jq(state_of(x, acct, "Email")), strings.to_string(sb), jq_list(nf[:]))
}

// ---------------------------------------------------------------------------
// Email/set
// ---------------------------------------------------------------------------

// apply_set_patch applies a JMAP patch for a set-valued property — the whole
// object (`keywords`) or one member (`keywords/$seen`) — to the current set.
apply_set_patch :: proc(x: ^Jctx, cur: []string, patch: json.Value, prop: string, fold: bool) -> (out: []string, touched: bool, err: string) {
	set := make([dynamic]string, 0, len(cur) + 2, context.temp_allocator)
	append(&set, ..cur)
	norm :: proc(s: string, fold: bool) -> string {return fold ? strings.to_lower(s, context.temp_allocator) : s}
	for k, v in patch.(json.Object) or_else nil {
		if k == prop {
			touched = true
			clear(&set)
			for m, val in v.(json.Object) or_else nil {
				if b, is := val.(json.Boolean); is && bool(b) {
					append(&set, norm(resolve_id(x, m), fold))
				}
			}
			continue
		}
		if strings.has_prefix(k, strings.concatenate({prop, "/"}, context.temp_allocator)) {
			touched = true
			member := norm(resolve_id(x, pointer_unescape(k[len(prop) + 1:])), fold)
			idx := -1
			for s, i in set {if s == member {idx = i}}
			_, is_null := v.(json.Null)
			b, is_bool := v.(json.Boolean)
			switch {
			case is_null || (is_bool && !bool(b)):
				if idx >= 0 {ordered_remove(&set, idx)}
			case is_bool && bool(b):
				if idx < 0 {append(&set, member)}
			case:
				return nil, true, fmt.tprintf("%s must be true or null", k)
			}
		}
	}
	return set[:], touched, ""
}

email_update :: proc(x: ^Jctx, acct, id: string, patch: json.Value) -> (err_type, err_desc: string) {
	if !is_uuid(id) {
		return "notFound", ""
	}
	for k in patch.(json.Object) or_else nil {
		if !(k == "keywords" || k == "mailboxIds" || strings.has_prefix(k, "keywords/") || strings.has_prefix(k, "mailboxIds/")) {
			return "invalidProperties", fmt.tprintf("%s cannot be changed", k)
		}
	}
	r := rest_get(x.token, fmt.tprintf("/mail_messages?select=keywords,mailbox_ids&identity_id=eq.%s&id=eq.%s", acct, id))
	rows := r.value.(json.Array) or_else nil
	if len(rows) == 0 {
		return "notFound", ""
	}
	kw, kt, ke := apply_set_patch(x, jstrs(rows[0], "keywords"), patch, "keywords", true)
	if ke != "" {
		return "invalidPatch", ke
	}
	mb, mt, me := apply_set_patch(x, jstrs(rows[0], "mailbox_ids"), patch, "mailboxIds", false)
	if me != "" {
		return "invalidPatch", me
	}
	parts := make([dynamic]string, 0, 2, context.temp_allocator)
	if kt {
		slice.sort(kw)
		append(&parts, fmt.tprintf(`"keywords":%s`, jq_list(kw)))
	}
	if mt {
		if len(mb) == 0 {
			return "invalidProperties", "an email must be in at least one mailbox"
		}
		for m in mb {
			if !is_uuid(m) {return "invalidProperties", "mailboxIds names something that is not a mailbox"}
		}
		append(&parts, fmt.tprintf(`"mailbox_ids":%s`, jq_list(mb)))
	}
	if len(parts) == 0 {
		return "", ""
	}
	u := rest_call(x.token, "PATCH", fmt.tprintf("/mail_messages?identity_id=eq.%s&id=eq.%s", acct, id), fmt.tprintf("{{%s}}", strings.join(parts[:], ",", context.temp_allocator)))
	if !rest_ok(u) {
		return "invalidProperties", u.err
	}
	return "", ""
}

email_destroy :: proc(x: ^Jctx, acct, id: string) -> bool {
	if !is_uuid(id) {
		return false
	}
	r := rest_call(x.token, "DELETE", fmt.tprintf("/mail_messages?identity_id=eq.%s&id=eq.%s&select=id", acct, id), "", "return=representation")
	return rest_ok(r) && len(r.value.(json.Array) or_else nil) > 0
}

// encode_header_word: RFC 2047 B-encoding when the value is not ASCII.
encode_header_word :: proc(s: string) -> string {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			return fmt.tprintf("=?UTF-8?B?%s?=", mm_b64_encode(transmute([]u8)s, context.temp_allocator))
		}
	}
	return s
}

addrs_header :: proc(v: json.Value) -> string {
	parts := make([dynamic]string, 0, 2, context.temp_allocator)
	for a in v.(json.Array) or_else nil {
		name := jstr(a, "name")
		email := jstr(a, "email")
		if strings.index_any(email, "\r\n<>,") >= 0 || email == "" {continue}
		if name == "" {
			append(&parts, email)
		} else {
			append(&parts, fmt.tprintf("%s <%s>", encode_header_word(strings.trim(name, "\r\n\"")), email))
		}
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

new_message_id :: proc() -> string {
	return fmt.tprintf("%s@%s", new_token_hex(12), cfg.domain)
}

// build_message renders an Email object from Email/set create — the subset a
// draft needs: addresses, subject, threading headers and a text/plain body.
build_message :: proc(x: ^Jctx, acct: string, spec: json.Value) -> (raw: []u8, err: string) {
	me := ctx_identity(x, acct)
	sb := strings.builder_make(context.temp_allocator)
	from := "null"
	if v, has := jget(spec, "from"); has {
		from = addrs_header(v)
	}
	if from == "null" || from == "" {
		from = fmt.tprintf("%s <%s>", encode_header_word(me.display_name), me.address)
	}
	fmt.sbprintf(&sb, "From: %s\r\n", from)
	for pair in ([][2]string{{"to", "To"}, {"cc", "Cc"}, {"bcc", "Bcc"}, {"replyTo", "Reply-To"}}) {
		if v, has := jget(spec, pair[0]); has {
			if h := addrs_header(v); h != "" {
				fmt.sbprintf(&sb, "%s: %s\r\n", pair[1], h)
			}
		}
	}
	subject := strings.trim(jstr(spec, "subject"), "\r\n")
	fmt.sbprintf(&sb, "Subject: %s\r\n", encode_header_word(subject))
	fmt.sbprintf(&sb, "Date: %s\r\n", rfc5322_date_now())
	fmt.sbprintf(&sb, "Message-ID: <%s>\r\n", new_message_id())
	clean_ids :: proc(xs: []string) -> string {
		out := make([dynamic]string, 0, len(xs), context.temp_allocator)
		for s in xs {
			if strings.index_any(s, "\r\n<> ") < 0 && s != "" {append(&out, fmt.tprintf("<%s>", s))}
		}
		return strings.join(out[:], " ", context.temp_allocator)
	}
	if irt := clean_ids(jstrs(spec, "inReplyTo")); irt != "" {
		fmt.sbprintf(&sb, "In-Reply-To: %s\r\n", irt)
	}
	if refs := clean_ids(jstrs(spec, "references")); refs != "" {
		fmt.sbprintf(&sb, "References: %s\r\n", refs)
	}
	text := ""
	if tb := jarr(spec, "textBody"); len(tb) > 0 {
		pid := jstr(tb[0], "partId")
		if bv, ok := jget(spec, "bodyValues"); ok {
			if v, ok2 := jget(bv, pid); ok2 {
				text = jstr(v, "value")
			}
		}
	}
	strings.write_string(&sb, "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n")
	b64 := mm_b64_encode(transmute([]u8)text, context.temp_allocator)
	for i := 0; i < len(b64); i += 76 {
		strings.write_string(&sb, b64[i:min(i + 76, len(b64))])
		strings.write_string(&sb, "\r\n")
	}
	return transmute([]u8)strings.to_string(sb), ""
}

// import_raw stores raw bytes into this identity through mail_import, and
// returns the created Email's {id, blobId, threadId, size}.
import_raw :: proc(x: ^Jctx, acct: string, raw: []u8, boxes, keywords: []string) -> (created: string, err: string) {
	kw := make([dynamic]string, 0, len(keywords), context.temp_allocator)
	for k in keywords {append(&kw, strings.to_lower(k, context.temp_allocator))}
	for b in boxes {
		if !is_uuid(b) {return "", "mailboxIds names something that is not a mailbox"}
	}
	args := fmt.tprintf(
		`{{"p_identity":%s,"p_raw":%s,"p_meta":%s,"p_boxes":%s,"p_keywords":%s}}`,
		jq(acct), jq(bytea_encode(raw)), summary_meta(summarise(raw)), jq_list(boxes), jq_list(kw[:]),
	)
	r := rest_rpc(x.token, "mail_import", args)
	if !rest_ok(r) {
		return "", r.err
	}
	id := jas(r.value)
	g := rest_get(x.token, fmt.tprintf("/mail_messages?select=id,blob_id,thread_id,size&identity_id=eq.%s&id=eq.%s", acct, id))
	rows := g.value.(json.Array) or_else nil
	if len(rows) == 0 {
		return "", "the imported message could not be read back"
	}
	return fmt.tprintf(`{{"id":%s,"blobId":%s,"threadId":%s,"size":%d}}`, jq(id), jq(jstr(rows[0], "blob_id")), jq(jstr(rows[0], "thread_id")), jint(rows[0], "size")), ""
}

set_keys :: proc(x: ^Jctx, v: json.Value, key: string) -> []string {
	out := make([dynamic]string, 0, 2, context.temp_allocator)
	if o, ok := jget(v, key); ok {
		for k, val in o.(json.Object) or_else nil {
			if b, is := val.(json.Boolean); is && bool(b) {append(&out, resolve_id(x, k))}
		}
	}
	return out[:]
}

email_set :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	old := state_of(x, acct, "Email")
	if s := jstr(args, "ifInState"); s != "" && s != old {
		return merr("stateMismatch")
	}
	created := strings.builder_make(context.temp_allocator)
	not_created := strings.builder_make(context.temp_allocator)
	updated := strings.builder_make(context.temp_allocator)
	not_updated := strings.builder_make(context.temp_allocator)
	destroyed := make([dynamic]string, 0, 4, context.temp_allocator)
	not_destroyed := strings.builder_make(context.temp_allocator)
	sep :: proc(sb: ^strings.Builder) {if strings.builder_len(sb^) > 0 {strings.write_byte(sb, ',')}}

	if cr, ok := jget(args, "create"); ok {
		for cid, spec in cr.(json.Object) or_else nil {
			raw, berr := build_message(x, acct, spec)
			obj := ""
			if berr == "" {
				obj, berr = import_raw(x, acct, raw, set_keys(x, spec, "mailboxIds"), set_keys(x, spec, "keywords"))
			}
			if berr != "" {
				sep(&not_created)
				fmt.sbprintf(&not_created, `%s:{{"type":"invalidProperties","description":%s}}`, jq(cid), jq(berr))
				continue
			}
			ov, _ := json.parse(transmute([]u8)obj, .JSON, true, context.temp_allocator)
			x.created[cid] = jstr(ov, "id")
			sep(&created)
			fmt.sbprintf(&created, "%s:%s", jq(cid), obj)
		}
	}
	if up, ok := jget(args, "update"); ok {
		for id, patch in up.(json.Object) or_else nil {
			real := resolve_id(x, id)
			if et, ed := email_update(x, acct, real, patch); et != "" {
				sep(&not_updated)
				fmt.sbprintf(&not_updated, `%s:{{"type":%s,"description":%s}}`, jq(id), jq(et), jq_null(ed))
				continue
			}
			sep(&updated)
			fmt.sbprintf(&updated, "%s:null", jq(id))
		}
	}
	for id in jstrs(args, "destroy") {
		if email_destroy(x, acct, resolve_id(x, id)) {
			append(&destroyed, id)
		} else {
			sep(&not_destroyed)
			fmt.sbprintf(&not_destroyed, `%s:{{"type":"notFound"}}`, jq(id))
		}
	}
	return "Email/set", fmt.tprintf(
		`{{"accountId":%s,"oldState":%s,"newState":%s,"created":{{%s}},"notCreated":{{%s}},"updated":{{%s}},"notUpdated":{{%s}},"destroyed":%s,"notDestroyed":{{%s}}}}`,
		jq(acct), jq(old), jq(state_of(x, acct, "Email")),
		strings.to_string(created), strings.to_string(not_created), strings.to_string(updated), strings.to_string(not_updated),
		jq_list(destroyed[:]), strings.to_string(not_destroyed),
	)
}

// ---------------------------------------------------------------------------
// Email/import, blobs, upload
// ---------------------------------------------------------------------------

// blob_bytes resolves a blobId: a mail_blobs id (the whole message), or
// <blob id>.<partId> (one decoded body part).
blob_bytes :: proc(x: ^Jctx, acct, blob_id: string) -> (data: []u8, ctype: string, err: string) {
	id := blob_id
	part := ""
	if dot := strings.index_byte(blob_id, '.'); dot > 0 {
		id = blob_id[:dot]
		part = blob_id[dot + 1:]
	}
	if !is_uuid(id) {
		return nil, "", "no such blob"
	}
	r := rest_get(x.token, fmt.tprintf("/mail_blobs?select=raw&identity_id=eq.%s&id=eq.%s", acct, id))
	rows := r.value.(json.Array) or_else nil
	if len(rows) == 0 {
		return nil, "", "no such blob"
	}
	raw, ok := bytea_decode(jstr(rows[0], "raw"), context.temp_allocator)
	if !ok {
		return nil, "", "blob is unreadable"
	}
	if part == "" {
		return raw, "message/rfc822", ""
	}
	root := mm_parse(raw, "", 0, context.temp_allocator)
	p := find_part(&root, part)
	if p == nil {
		return nil, "", "no such part"
	}
	return p.decoded, part_type(p), ""
}

upload :: proc(x: ^Jctx, acct: string, body: []u8, ctype: string) -> (string, int) {
	if len(body) > SMTP_MAX_SIZE {
		return `{"type":"urn:ietf:params:jmap:error:limit","limit":"maxSizeUpload"}`, 413
	}
	sha := sha256_hex(body)
	payload := fmt.tprintf(`{{"identity_id":%s,"sha256":%s,"size":%d,"raw":%s}}`, jq(acct), jq(sha), len(body), jq(bytea_encode(body)))
	r := rest_call(x.token, "POST", "/mail_blobs?on_conflict=identity_id,sha256&select=id", payload, "return=representation,resolution=merge-duplicates")
	rows := r.value.(json.Array) or_else nil
	if !rest_ok(r) || len(rows) == 0 {
		return fmt.tprintf(`{{"type":"about:blank","status":500,"detail":%s}}`, jq(r.err)), 500
	}
	return fmt.tprintf(`{{"accountId":%s,"blobId":%s,"type":%s,"size":%d}}`, jq(acct), jq(jstr(rows[0], "id")), jq(ctype == "" ? "application/octet-stream" : ctype), len(body)), 201
}

email_import :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	old := state_of(x, acct, "Email")
	created := strings.builder_make(context.temp_allocator)
	not_created := strings.builder_make(context.temp_allocator)
	sep :: proc(sb: ^strings.Builder) {if strings.builder_len(sb^) > 0 {strings.write_byte(sb, ',')}}
	em, _ := jget(args, "emails")
	for cid, spec in em.(json.Object) or_else nil {
		raw, _, berr := blob_bytes(x, acct, resolve_id(x, jstr(spec, "blobId")))
		obj := ""
		if berr == "" {
			obj, berr = import_raw(x, acct, raw, set_keys(x, spec, "mailboxIds"), set_keys(x, spec, "keywords"))
		}
		if berr != "" {
			sep(&not_created)
			fmt.sbprintf(&not_created, `%s:{{"type":"invalidProperties","description":%s}}`, jq(cid), jq(berr))
			continue
		}
		ov, _ := json.parse(transmute([]u8)obj, .JSON, true, context.temp_allocator)
		x.created[cid] = jstr(ov, "id")
		sep(&created)
		fmt.sbprintf(&created, "%s:%s", jq(cid), obj)
	}
	return "Email/import", fmt.tprintf(
		`{{"accountId":%s,"oldState":%s,"newState":%s,"created":{{%s}},"notCreated":{{%s}}}}`,
		jq(acct), jq(old), jq(state_of(x, acct, "Email")), strings.to_string(created), strings.to_string(not_created),
	)
}

// ---------------------------------------------------------------------------
// Thread/get, Identity/get
// ---------------------------------------------------------------------------

thread_get :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	ids, _ := ids_arg(x, args)
	valid, csv := uuid_list(ids)
	groups := make(map[string][dynamic]string, len(valid), context.temp_allocator)
	if len(valid) > 0 {
		r := rest_get(x.token, fmt.tprintf("/mail_messages?select=id,thread_id&identity_id=eq.%s&thread_id=in.(%s)&order=received_at,id", acct, csv))
		for e in r.value.(json.Array) or_else nil {
			t := jstr(e, "thread_id")
			if t not_in groups {
				groups[t] = make([dynamic]string, 0, 4, context.temp_allocator)
			}
			append(&groups[t], jstr(e, "id"))
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	nf := make([dynamic]string, 0, 0, context.temp_allocator)
	strings.write_byte(&sb, '[')
	n := 0
	for id in ids {
		g, ok := groups[strings.to_lower(id, context.temp_allocator)]
		if !ok {
			append(&nf, id)
			continue
		}
		if n > 0 {strings.write_byte(&sb, ',')}
		n += 1
		fmt.sbprintf(&sb, `{{"id":%s,"emailIds":%s}}`, jq(id), jq_list(g[:]))
	}
	strings.write_byte(&sb, ']')
	return "Thread/get", fmt.tprintf(`{{"accountId":%s,"state":%s,"list":%s,"notFound":%s}}`, jq(acct), jq(state_of(x, acct, "Email")), strings.to_string(sb), jq_list(nf[:]))
}

identity_get :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	me := ctx_identity(x, acct)
	ids, given := ids_arg(x, args)
	list := fmt.tprintf(`[{{"id":%s,"name":%s,"email":%s,"replyTo":null,"bcc":null,"textSignature":"","htmlSignature":"","mayDelete":false}}]`, jq(me.id), jq(me.display_name), jq(me.address))
	nf := make([dynamic]string, 0, 0, context.temp_allocator)
	if given {
		hit := false
		for i in ids {
			if i == me.id {hit = true} else {append(&nf, i)}
		}
		if !hit {list = "[]"}
	}
	return "Identity/get", fmt.tprintf(`{{"accountId":%s,"state":"0","list":%s,"notFound":%s}}`, jq(acct), list, jq_list(nf[:]))
}

// ---------------------------------------------------------------------------
// EmailSubmission
// ---------------------------------------------------------------------------

submission_set :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	me := ctx_identity(x, acct)
	old := state_of(x, acct, "EmailSubmission")
	created := strings.builder_make(context.temp_allocator)
	not_created := strings.builder_make(context.temp_allocator)
	sep :: proc(sb: ^strings.Builder) {if strings.builder_len(sb^) > 0 {strings.write_byte(sb, ',')}}
	sub_of := make(map[string]string, 4, context.temp_allocator) // "#creationId" -> emailId, for onSuccess*
	fail :: proc(sb: ^strings.Builder, cid, type, desc: string) {
		if strings.builder_len(sb^) > 0 {strings.write_byte(sb, ',')}
		fmt.sbprintf(sb, `%s:{{"type":%s,"description":%s}}`, jq(cid), jq(type), jq(desc))
	}

	cr, _ := jget(args, "create")
	for cid, spec in cr.(json.Object) or_else nil {
		ident := resolve_id(x, jstr(spec, "identityId"))
		if ident != me.id {
			fail(&not_created, cid, "invalidProperties", "identityId must be this account's identity")
			continue
		}
		email_id := resolve_id(x, jstr(spec, "emailId"))
		if !is_uuid(email_id) {
			fail(&not_created, cid, "invalidProperties", "emailId does not name an email")
			continue
		}
		g := rest_get(x.token, fmt.tprintf("/mail_messages?select=blob_id,to,cc,bcc&identity_id=eq.%s&id=eq.%s", acct, email_id))
		rows := g.value.(json.Array) or_else nil
		if len(rows) == 0 {
			fail(&not_created, cid, "invalidProperties", "no such email")
			continue
		}
		raw, _, berr := blob_bytes(x, acct, jstr(rows[0], "blob_id"))
		if berr != "" {
			fail(&not_created, cid, "serverFail", berr)
			continue
		}
		rcpts := make([dynamic]string, 0, 4, context.temp_allocator)
		if env, has := jget(spec, "envelope"); has {
			if _, is_null := env.(json.Null); !is_null {
				if mf, ok := jget(env, "mailFrom"); ok && strings.to_lower(jstr(mf, "email"), context.temp_allocator) != me.address {
					fail(&not_created, cid, "forbiddenMailFrom", "the envelope sender must be the identity's address")
					continue
				}
				for r in jarr(env, "rcptTo") {append(&rcpts, strings.to_lower(jstr(r, "email"), context.temp_allocator))}
			}
		}
		if len(rcpts) == 0 {
			for key in ([]string{"to", "cc", "bcc"}) {
				for a in jarr(rows[0], key) {append(&rcpts, strings.to_lower(jstr(a, "email"), context.temp_allocator))}
			}
		}
		if len(rcpts) == 0 {
			fail(&not_created, cid, "noRecipients", "")
			continue
		}
		raw = submission_fixup(raw, me.address)
		full := add_received(raw, "jmap", "HTTP", rcpts[0])
		sargs := fmt.tprintf(`{{"p_identity":%s,"p_raw":%s,"p_meta":%s,"p_rcpts":%s}}`, jq(acct), jq(bytea_encode(full)), summary_meta(summarise(full)), jq_list(rcpts[:]))
		r := rest_rpc(x.token, "mail_submit", sargs)
		if !rest_ok(r) {
			fail(&not_created, cid, r.code == "42501" ? "forbiddenFrom" : "forbiddenToSend", r.err)
			continue
		}
		sid := jstr(r.value, "submissionId")
		x.created[cid] = sid
		sub_of[fmt.tprintf("#%s", cid)] = email_id
		sep(&created)
		fmt.sbprintf(&created, `%s:{{"id":%s,"sendAt":%s,"undoStatus":"final"}}`, jq(cid), jq(sid), jq(iso8601(time_now_unix())))
	}

	// onSuccessUpdateEmail / onSuccessDestroyEmail: an implicit Email/set,
	// emitted as its own response right after this one (RFC 8621 7.5).
	upd, has_upd := jget(args, "onSuccessUpdateEmail")
	dst := jstrs(args, "onSuccessDestroyEmail")
	if (has_upd || len(dst) > 0) && len(sub_of) > 0 {
		ub := strings.builder_make(context.temp_allocator)
		strings.write_string(&ub, `{"update":{`)
		n := 0
		for k, patch in upd.(json.Object) or_else nil {
			if eid, ok := sub_of[k]; ok {
				if n > 0 {strings.write_byte(&ub, ',')}
				n += 1
				fmt.sbprintf(&ub, "%s:%s", jq(eid), render_json(patch))
			}
		}
		strings.write_string(&ub, `},"destroy":[`)
		n = 0
		for k in dst {
			if eid, ok := sub_of[k]; ok {
				if n > 0 {strings.write_byte(&ub, ',')}
				n += 1
				strings.write_string(&ub, jq(eid))
			}
		}
		strings.write_string(&ub, `]}`)
		sv, _ := json.parse(transmute([]u8)strings.to_string(ub), .JSON, true, context.temp_allocator)
		n2, j2 := email_set(x, acct, sv)
		append(&x.extra, [2]string{n2, j2})
	}
	return "EmailSubmission/set", fmt.tprintf(
		`{{"accountId":%s,"oldState":%s,"newState":%s,"created":{{%s}},"notCreated":{{%s}},"updated":{{}},"notUpdated":{{}},"destroyed":[],"notDestroyed":{{}}}}`,
		jq(acct), jq(old), jq(state_of(x, acct, "EmailSubmission")), strings.to_string(created), strings.to_string(not_created),
	)
}

submission_get :: proc(x: ^Jctx, acct: string, args: json.Value) -> (string, string) {
	ids, given := ids_arg(x, args)
	path := fmt.tprintf("/mail_submissions?select=id,email_id,mail_from,rcpt_to,created_at&identity_id=eq.%s&order=created_at.desc&limit=%d", acct, MAX_OBJECTS)
	if given {
		_, csv := uuid_list(ids)
		path = fmt.tprintf("%s&id=in.(%s)", path, csv)
	}
	r := rest_get(x.token, path)
	held := rest_get(x.token, fmt.tprintf("/mail_outbox?select=submission_id,rcpt,status,reason&identity_id=eq.%s", acct))
	held_of := make(map[string]json.Value, 8, context.temp_allocator)
	for e in held.value.(json.Array) or_else nil {
		held_of[fmt.tprintf("%s|%s", jstr(e, "submission_id"), jstr(e, "rcpt"))] = e
	}
	sb := strings.builder_make(context.temp_allocator)
	found := make(map[string]bool, 8, context.temp_allocator)
	strings.write_byte(&sb, '[')
	for e, i in r.value.(json.Array) or_else nil {
		if i > 0 {strings.write_byte(&sb, ',')}
		sid := jstr(e, "id")
		found[sid] = true
		rc := jstrs(e, "rcpt_to")
		env := strings.builder_make(context.temp_allocator)
		ds := strings.builder_make(context.temp_allocator)
		for a, k in rc {
			if k > 0 {strings.write_byte(&env, ',');strings.write_byte(&ds, ',')}
			fmt.sbprintf(&env, `{{"email":%s,"parameters":null}}`, jq(a))
			if h, is_held := held_of[fmt.tprintf("%s|%s", sid, strings.to_lower(a, context.temp_allocator))]; is_held {
				fmt.sbprintf(&ds, `%s:{{"smtpReply":%s,"delivered":"no","displayed":"unknown"}}`, jq(a), jq(fmt.tprintf("554 5.7.0 Not sent (%s): %s", jstr(h, "status"), jstr(h, "reason"))))
			} else {
				fmt.sbprintf(&ds, `%s:{{"smtpReply":"250 2.0.0 Delivered locally","delivered":"yes","displayed":"unknown"}}`, jq(a))
			}
		}
		fmt.sbprintf(
			&sb,
			`{{"id":%s,"identityId":%s,"emailId":%s,"threadId":null,"envelope":{{"mailFrom":{{"email":%s,"parameters":null}},"rcptTo":[%s]}},"sendAt":%s,"undoStatus":"final","deliveryStatus":{{%s}},"dsnBlobIds":[],"mdnBlobIds":[]}}`,
			jq(sid), jq(acct), jq(jstr(e, "email_id")), jq(jstr(e, "mail_from")), strings.to_string(env), jq(pg_ts(jstr(e, "created_at"))), strings.to_string(ds),
		)
	}
	strings.write_byte(&sb, ']')
	nf := make([dynamic]string, 0, 0, context.temp_allocator)
	for i in ids {
		if !found[strings.to_lower(i, context.temp_allocator)] {append(&nf, i)}
	}
	return "EmailSubmission/get", fmt.tprintf(`{{"accountId":%s,"state":%s,"list":%s,"notFound":%s}}`, jq(acct), jq(state_of(x, acct, "EmailSubmission")), strings.to_string(sb), jq_list(nf[:]))
}
