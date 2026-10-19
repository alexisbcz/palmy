package main

// A JMAP client: RFC 8620 (core) and RFC 8621 (mail).
//
// JMAP is structurally unlike IMAP and POP3. There is no session state on a
// socket, no command/response pairing, and no line framing: there is one HTTP
// endpoint that takes a `Request` object containing an *array* of method
// invocations and returns an array of responses. Everything interesting about
// the protocol follows from that.
//
// BATCHING. A `Request` is
//
//	{"using": [...capability URIs...],
//	 "methodCalls": [[name, arguments, callId], ...]}
//
// and the response pairs each result with the same client-supplied callId. The
// callId is not decoration: it is how a back-reference names an earlier call,
// and how a client matches results when the server reorders or inserts extra
// responses.
//
// BACK-REFERENCES are the point of the design, and the part that is usually
// skipped. Any argument may be replaced by `#argName` whose value is a
// ResultReference:
//
//	{"resultOf": "c0", "name": "Email/query", "path": "/ids"}
//
// The server evaluates the JSON pointer `path` against the result of call
// `c0` and substitutes it. That turns "list the message ids in this mailbox,
// then fetch those messages" from two round trips into one, with no
// client-side knowledge of the ids at all. `jmap_query_then_get` does exactly
// that, and the self-test asserts that the server resolved it rather than the
// client papering over it with a second request.
//
// The third thing JMAP does differently: an Email object is already
// *decomposed*. `textBody`, `htmlBody`, `attachments` and `bodyValues` arrive
// as structured data, so a JMAP client never has to parse MIME. That is a
// completely different code path from `parse_message`, which is why the
// cross-protocol test compares the two: `jmap_sync` downloads the raw blob for
// the Maildir (so the bytes on disk match what IMAP and POP3 write), and
// `jmap_check_decomposition` checks the server's decomposition against this
// engine's own parse of those same bytes.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

JMAP_CORE :: "urn:ietf:params:jmap:core"
JMAP_MAIL :: "urn:ietf:params:jmap:mail"

// One entry of the session's `accounts`. The Palmy fields come from the
// urn:palmy:params:jmap:identity account capability, where a Palmy
// server describes the identity behind an account; they are empty against
// any other server.
Jmap_Account :: struct {
	id:           string,
	name:         string,
	handle:       string,
	display_name: string,
	kind:         string, // personal, work, public, project
	color:        string,
	address:      string,
}

JMAP_PALM :: "urn:palmy:params:jmap:identity"

Jmap_Session :: struct {
	accounts:             []Jmap_Account,
	username:             string,
	api_url:              string,
	download_url:         string, // a URI template
	upload_url:           string,
	event_source_url:     string,
	state:                string,
	primary_mail_account: string,
	capabilities:         []string,
	max_calls_in_request: int,
	max_objects_in_get:   int,
}

Jmap_Mailbox :: struct {
	id:              string,
	name:            string,
	parent_id:       string,
	role:            string, // inbox, archive, sent, trash, drafts, junk
	sort_order:      int,
	total_emails:    int,
	unread_emails:   int,
	my_rights_may_read: bool,
}

Jmap_Addr :: struct {
	name:  string,
	email: string,
}

Jmap_Body_Part :: struct {
	part_id:     string,
	blob_id:     string,
	size:        int,
	type:        string,
	charset:     string,
	name:        string,
	disposition: string,
	cid:         string,
	sub_parts:   []Jmap_Body_Part,
}

Jmap_Email :: struct {
	id:             string,
	blob_id:        string,
	thread_id:      string,
	mailbox_ids:    []string,
	keywords:       []string,
	size:           int,
	received_at:    string,
	sent_at:        string,
	subject:        string,
	message_id:     []string,
	in_reply_to:    []string,
	references:     []string,
	from:           []Jmap_Addr,
	to:             []Jmap_Addr,
	cc:             []Jmap_Addr,
	text_body:      []Jmap_Body_Part,
	html_body:      []Jmap_Body_Part,
	attachments:    []Jmap_Body_Part,
	body_structure: Jmap_Body_Part,
	body_values:    map[string]string, // partId -> decoded UTF-8 text
	has_attachment: bool,
	preview:        string,
}

JMAP :: struct {
	host:        string,
	port:        int,
	auth:        string,
	session:     Jmap_Session,
	conn:        Conn,
	conn_open:   bool,
	opts:        Dial_Opts,
	alloc:       mem.Allocator,
	trace:       bool,
	// Facts the self-test asserts rather than assumes.
	requests_sent:  int,
	calls_sent:     int,
	backrefs_sent:  int,
	parsed:         [dynamic]json.Value, // kept alive for the Value tree
}

// The default properties RFC 8621 4.2 defines for Email/get, minus the ones
// that need a separate fetch.
JMAP_EMAIL_PROPS := []string {
	"id",
	"blobId",
	"threadId",
	"mailboxIds",
	"keywords",
	"size",
	"receivedAt",
	"messageId",
	"inReplyTo",
	"references",
	"sender",
	"from",
	"to",
	"cc",
	"bcc",
	"replyTo",
	"subject",
	"sentAt",
	"hasAttachment",
	"preview",
	"bodyStructure",
	"bodyValues",
	"textBody",
	"htmlBody",
	"attachments",
}

// RFC 8621 4.1.4's bodyProperties default set.
JMAP_BODY_PROPS := []string {
	"partId",
	"blobId",
	"size",
	"name",
	"type",
	"charset",
	"disposition",
	"cid",
	"language",
	"location",
}

jmap_log :: proc(j: ^JMAP, format: string, args: ..any) {
	if j.trace {
		fmt.eprintf("[jmap] ")
		fmt.eprintfln(format, ..args)
	}
}

// ---------------------------------------------------------------------------
// Session discovery
// ---------------------------------------------------------------------------

@(private = "file")
jmap_open_conn :: proc(j: ^JMAP) -> (err: string) {
	if j.conn_open && j.conn.open {
		return ""
	}
	if j.conn_open {
		conn_close(&j.conn)
		j.conn_open = false
	}
	if e := conn_dial(&j.conn, j.host, j.port, j.opts, "jmap"); e != "" {
		return e
	}
	j.conn_open = true
	return ""
}

// jmap_connect performs RFC 8620 2.2 session discovery: an authenticated GET
// of /.well-known/jmap, which returns the session object naming the API,
// download and upload endpoints and the accounts this credential can see.
jmap_connect :: proc(
	j: ^JMAP,
	host: string,
	port: int,
	user, password: string,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	return jmap_connect_auth(j, host, port, http_basic_auth(user, password, allocator), opts, allocator)
}

// jmap_connect_bearer authenticates with a bearer token (RFC 6750) instead of
// Basic: a Palmy server takes the Supabase access token this way.
jmap_connect_bearer :: proc(
	j: ^JMAP,
	host: string,
	port: int,
	token: string,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	return jmap_connect_auth(j, host, port, strings.concatenate({"Bearer ", token}, allocator), opts, allocator)
}

// jmap_use_account points every later call at one of the session's accounts,
// named by id or by name (a Palmy account's name is its address).
jmap_use_account :: proc(j: ^JMAP, want: string) -> (err: string) {
	for a in j.session.accounts {
		if a.id == want || strings.equal_fold(a.name, want) {
			j.session.primary_mail_account = a.id
			return ""
		}
	}
	return fmt.aprintf("the JMAP session has no account %q", want)
}

jmap_connect_auth :: proc(
	j: ^JMAP,
	host: string,
	port: int,
	auth: string,
	opts: Dial_Opts = {},
	allocator := context.allocator,
) -> (
	err: string,
) {
	j.host = strings.clone(host, allocator)
	j.port = port
	j.alloc = allocator
	j.trace = opts.trace
	j.opts = opts
	j.auth = auth
	j.parsed = make([dynamic]json.Value, 0, 8, allocator)

	if e := jmap_open_conn(j); e != "" {
		return e
	}
	target := "/.well-known/jmap"
	for redirects := 0; redirects < 3; redirects += 1 {
		resp, he := http_do(
			&j.conn,
			Http_Request {
				method = "GET",
				target = target,
				host = fmt.tprintf("%s:%d", host, port),
				headers = {
					{name = "Authorization", value = j.auth},
					{name = "Accept", value = "application/json"},
				},
			},
			allocator,
		)
		if he != "" {
			return fmt.aprintf("JMAP session discovery: %s", he)
		}
		if resp.status == 301 || resp.status == 302 || resp.status == 307 || resp.status == 308 {
			loc, ok := http_header(resp.headers, "location")
			if !ok {
				return "JMAP session discovery redirected with no Location"
			}
			// Only a same-origin path redirect is followed: a cross-origin one
			// would be a way out of the loopback gate.
			if strings.has_prefix(loc, "/") {
				target = loc
				continue
			}
			_, lhost, lport, ltarget, ue := url_split(loc)
			if ue != "" {
				return ue
			}
			if lhost != host || lport != port {
				return fmt.aprintf("refusing a cross-origin JMAP redirect to %q", loc)
			}
			target = ltarget
			continue
		}
		if resp.status == 401 {
			return "JMAP session discovery: 401, the credential was rejected"
		}
		if resp.status != 200 {
			return fmt.aprintf("JMAP session discovery: HTTP %d %s", resp.status, resp.reason)
		}
		return jmap_parse_session(j, resp.body)
	}
	return "JMAP session discovery redirected too many times"
}

@(private = "file")
jmap_parse_session :: proc(j: ^JMAP, body: []u8) -> (err: string) {
	v, pe := json.parse(body, .JSON, true, j.alloc)
	if pe != nil {
		return fmt.aprintf("JMAP session object is not valid JSON: %v", pe)
	}
	append(&j.parsed, v)

	s: Jmap_Session
	s.username = strings.clone(jv_str(v, "username"), j.alloc)
	s.api_url = strings.clone(jv_str(v, "apiUrl"), j.alloc)
	s.download_url = strings.clone(jv_str(v, "downloadUrl"), j.alloc)
	s.upload_url = strings.clone(jv_str(v, "uploadUrl"), j.alloc)
	s.event_source_url = strings.clone(jv_str(v, "eventSourceUrl"), j.alloc)
	s.state = strings.clone(jv_str(v, "state"), j.alloc)

	if caps, ok := jv_get(v, "capabilities"); ok {
		if o, is := caps.(json.Object); is {
			list := make([dynamic]string, 0, len(o), j.alloc)
			for k in o {
				append(&list, strings.clone(k, j.alloc))
			}
			s.capabilities = list[:]
		}
		if core, ok2 := jv_get(caps, JMAP_CORE); ok2 {
			s.max_calls_in_request = jv_int(core, "maxCallsInRequest")
			s.max_objects_in_get = jv_int(core, "maxObjectsInGet")
		}
	}
	// primaryAccounts maps a capability URI to the account id to use for it.
	if pa, ok := jv_get(v, "primaryAccounts"); ok {
		s.primary_mail_account = strings.clone(jv_str(pa, JMAP_MAIL), j.alloc)
	}
	if accts, ok := jv_get(v, "accounts"); ok {
		if o, is := accts.(json.Object); is {
			list := make([dynamic]Jmap_Account, 0, len(o), j.alloc)
			for k, av in o {
				a := Jmap_Account {
					id   = strings.clone(k, j.alloc),
					name = strings.clone(jv_str(av, "name"), j.alloc),
				}
				if caps, cok := jv_get(av, "accountCapabilities"); cok {
					if pc, pok := jv_get(caps, JMAP_PALM); pok {
						a.handle = strings.clone(jv_str(pc, "handle"), j.alloc)
						a.display_name = strings.clone(jv_str(pc, "displayName"), j.alloc)
						a.kind = strings.clone(jv_str(pc, "kind"), j.alloc)
						a.color = strings.clone(jv_str(pc, "color"), j.alloc)
						a.address = strings.clone(jv_str(pc, "address"), j.alloc)
					}
				}
				append(&list, a)
			}
			s.accounts = list[:]
		}
	}
	if s.primary_mail_account == "" {
		// Fall back to the first account that has the mail capability.
		if accts, ok := jv_get(v, "accounts"); ok {
			if o, is := accts.(json.Object); is {
				for k in o {
					s.primary_mail_account = strings.clone(k, j.alloc)
					break
				}
			}
		}
	}
	if s.api_url == "" {
		return "JMAP session object has no apiUrl"
	}
	if s.primary_mail_account == "" {
		return "JMAP session object names no account for urn:ietf:params:jmap:mail"
	}
	j.session = s
	jmap_log(
		j,
		"session: api=%s account=%s caps=%v",
		s.api_url,
		s.primary_mail_account,
		s.capabilities,
	)
	return ""
}

jmap_close :: proc(j: ^JMAP) {
	if j.conn_open {
		conn_close(&j.conn)
		j.conn_open = false
	}
}

jmap_has_cap :: proc(j: ^JMAP, uri: string) -> bool {
	for c in j.session.capabilities {
		if c == uri {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Making a request
// ---------------------------------------------------------------------------

// Jmap_Call is one invocation. `args` is a rendered JSON object, which is what
// lets a caller express a back-reference without this file knowing about every
// method's argument shape.
Jmap_Call :: struct {
	name: string,
	args: string,
	id:   string,
}

// jmap_backref renders a ResultReference as a complete JSON object.
jmap_backref :: proc(result_of, name, path: string, allocator := context.allocator) -> string {
	w := jw_make(allocator)
	jw_obj(&w)
	jw_kstr(&w, "resultOf", result_of)
	jw_kstr(&w, "name", name)
	jw_kstr(&w, "path", path)
	jw_obj_end(&w)
	return jw_string(&w)
}

Jmap_Response :: struct {
	root:          json.Value,
	session_state: string,
	// results, in the order the server returned them
	names:         []string,
	ids:           []string,
	args:          []json.Value,
}

jmap_result :: proc(r: Jmap_Response, call_id: string) -> (name: string, args: json.Value, ok: bool) {
	for id, i in r.ids {
		if id == call_id {
			return r.names[i], r.args[i], true
		}
	}
	return "", nil, false
}

// jmap_call sends one Request containing every invocation in `calls`.
jmap_call :: proc(
	j: ^JMAP,
	calls: []Jmap_Call,
	using_caps: []string = nil,
	allocator := context.allocator,
) -> (
	out: Jmap_Response,
	err: string,
) {
	if len(calls) == 0 {
		return out, "no method calls"
	}
	if j.session.max_calls_in_request > 0 && len(calls) > j.session.max_calls_in_request {
		return out, fmt.aprintf(
			"%d calls exceeds the server's maxCallsInRequest of %d",
			len(calls),
			j.session.max_calls_in_request,
		)
	}

	caps := using_caps
	if caps == nil {
		caps = []string{JMAP_CORE, JMAP_MAIL}
	}
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_key(&w, "using")
	jw_str_array(&w, caps)
	jw_key(&w, "methodCalls")
	jw_arr(&w)
	for c in calls {
		jw_arr(&w)
		jw_str(&w, c.name)
		jw_raw(&w, c.args)
		jw_str(&w, c.id)
		jw_arr_end(&w)
		if strings.contains(c.args, "\"resultOf\"") {
			j.backrefs_sent += 1
		}
	}
	jw_arr_end(&w)
	jw_obj_end(&w)
	body := jw_string(&w)

	_, _, _, target, ue := url_split(j.session.api_url)
	if ue != "" {
		return out, ue
	}
	if e := jmap_open_conn(j); e != "" {
		return out, e
	}
	jmap_log(j, "-> %s", body)
	resp, he := http_do(
		&j.conn,
		Http_Request {
			method = "POST",
			target = target,
			host = fmt.tprintf("%s:%d", j.host, j.port),
			headers = {
				{name = "Authorization", value = j.auth},
				{name = "Content-Type", value = "application/json; charset=utf-8"},
				{name = "Accept", value = "application/json"},
			},
			body = transmute([]u8)body,
		},
		allocator,
	)
	if he != "" {
		return out, he
	}
	j.requests_sent += 1
	j.calls_sent += len(calls)
	if resp.close {
		conn_close(&j.conn)
		j.conn_open = false
	}
	if resp.status != 200 {
		// RFC 8620 3.6.1: a request-level problem comes back as a JSON
		// problem-details object, which is far more useful than the code.
		if len(resp.body) > 0 {
			if pv, pe := json.parse(resp.body, .JSON, true, context.temp_allocator); pe == nil {
				t := jv_str(pv, "type")
				d := jv_str(pv, "detail")
				if t != "" {
					return out, fmt.aprintf("JMAP error %s: %s (HTTP %d)", t, d, resp.status)
				}
			}
		}
		return out, fmt.aprintf("JMAP HTTP %d %s", resp.status, resp.reason)
	}

	v, pe := json.parse(resp.body, .JSON, true, j.alloc)
	if pe != nil {
		return out, fmt.aprintf("JMAP response is not valid JSON: %v", pe)
	}
	append(&j.parsed, v)
	out.root = v
	out.session_state = strings.clone(jv_str(v, "sessionState"), allocator)

	mr := jv_arr(v, "methodResponses")
	names := make([dynamic]string, 0, len(mr), allocator)
	ids := make([dynamic]string, 0, len(mr), allocator)
	args := make([dynamic]json.Value, 0, len(mr), allocator)
	for e in mr {
		a, is := e.(json.Array)
		if !is || len(a) < 3 {
			continue
		}
		append(&names, strings.clone(jv_as_str(a[0]), allocator))
		append(&args, a[1])
		append(&ids, strings.clone(jv_as_str(a[2]), allocator))
	}
	out.names = names[:]
	out.ids = ids[:]
	out.args = args[:]
	jmap_log(j, "<- %d method responses", len(out.ids))

	// A method-level error comes back as ["error", {type: ...}, callId], which
	// must not be mistaken for a successful result.
	for n, i in out.names {
		if n == "error" {
			return out, fmt.aprintf(
				"JMAP %s failed: %s %s",
				out.ids[i],
				jv_str(out.args[i], "type"),
				jv_str(out.args[i], "description"),
			)
		}
	}
	return out, ""
}

// ---------------------------------------------------------------------------
// Mailbox/get
// ---------------------------------------------------------------------------

jmap_mailbox_get :: proc(
	j: ^JMAP,
	allocator := context.allocator,
) -> (
	boxes: []Jmap_Mailbox,
	err: string,
) {
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	jw_knull(&w, "ids")
	jw_obj_end(&w)

	r, e := jmap_call(j, {{name = "Mailbox/get", args = jw_string(&w), id = "m0"}}, nil, allocator)
	if e != "" {
		return nil, e
	}
	_, args, ok := jmap_result(r, "m0")
	if !ok {
		return nil, "no result for Mailbox/get"
	}
	list := jv_arr(args, "list")
	out := make([dynamic]Jmap_Mailbox, 0, len(list), allocator)
	for e2 in list {
		append(
			&out,
			Jmap_Mailbox {
				id = strings.clone(jv_str(e2, "id"), allocator),
				name = strings.clone(jv_str(e2, "name"), allocator),
				parent_id = strings.clone(jv_str(e2, "parentId"), allocator),
				role = strings.clone(jv_str(e2, "role"), allocator),
				sort_order = jv_int(e2, "sortOrder"),
				total_emails = jv_int(e2, "totalEmails"),
				unread_emails = jv_int(e2, "unreadEmails"),
				my_rights_may_read = true,
			},
		)
	}
	return out[:], ""
}

jmap_mailbox_by_role :: proc(boxes: []Jmap_Mailbox, role: string) -> (Jmap_Mailbox, bool) {
	for b in boxes {
		if strings.equal_fold(b.role, role) {
			return b, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Email/query and Email/get
// ---------------------------------------------------------------------------

@(private = "file")
email_query_args :: proc(
	j: ^JMAP,
	mailbox_id: string,
	limit: int,
	allocator := context.allocator,
) -> string {
	w := jw_make(allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	if mailbox_id != "" {
		jw_key(&w, "filter")
		jw_obj(&w)
		jw_kstr(&w, "inMailbox", mailbox_id)
		jw_obj_end(&w)
	}
	jw_key(&w, "sort")
	jw_arr(&w)
	jw_obj(&w)
	jw_kstr(&w, "property", "receivedAt")
	jw_kbool(&w, "isAscending", true)
	jw_obj_end(&w)
	jw_arr_end(&w)
	jw_kint(&w, "position", 0)
	if limit > 0 {
		jw_kint(&w, "limit", limit)
	}
	jw_kbool(&w, "calculateTotal", true)
	jw_obj_end(&w)
	return jw_string(&w)
}

jmap_email_query :: proc(
	j: ^JMAP,
	mailbox_id: string,
	limit := 0,
	allocator := context.allocator,
) -> (
	ids: []string,
	total: int,
	err: string,
) {
	args := email_query_args(j, mailbox_id, limit, context.temp_allocator)
	r, e := jmap_call(j, {{name = "Email/query", args = args, id = "q0"}}, nil, allocator)
	if e != "" {
		return nil, 0, e
	}
	_, res, ok := jmap_result(r, "q0")
	if !ok {
		return nil, 0, "no result for Email/query"
	}
	return jv_str_array(res, "ids", allocator), jv_int(res, "total"), ""
}

@(private = "file")
email_get_args :: proc(
	j: ^JMAP,
	ids_json: string,
	fetch_text: bool,
	allocator := context.allocator,
) -> string {
	w := jw_make(allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	// `ids_json` is either a rendered array of ids or a `#ids` back-reference,
	// which is why it arrives as raw JSON and is spliced rather than built.
	jw_raw(&w, ids_json)
	jw_key(&w, "properties")
	jw_str_array(&w, JMAP_EMAIL_PROPS)
	jw_key(&w, "bodyProperties")
	jw_str_array(&w, JMAP_BODY_PROPS)
	jw_kbool(&w, "fetchTextBodyValues", fetch_text)
	jw_kbool(&w, "fetchHTMLBodyValues", fetch_text)
	jw_kbool(&w, "fetchAllBodyValues", false)
	jw_kint(&w, "maxBodyValueBytes", 0)
	jw_obj_end(&w)
	return jw_string(&w)
}

jmap_email_get :: proc(
	j: ^JMAP,
	ids: []string,
	fetch_text := true,
	allocator := context.allocator,
) -> (
	emails: []Jmap_Email,
	err: string,
) {
	idw := jw_make(context.temp_allocator)
	jw_key(&idw, "ids")
	jw_str_array(&idw, ids)
	args := email_get_args(j, jw_string(&idw), fetch_text, context.temp_allocator)
	r, e := jmap_call(j, {{name = "Email/get", args = args, id = "g0"}}, nil, allocator)
	if e != "" {
		return nil, e
	}
	_, res, ok := jmap_result(r, "g0")
	if !ok {
		return nil, "no result for Email/get"
	}
	return decode_email_list(res, allocator), ""
}

// jmap_query_then_get is the batched, back-referenced form: ONE HTTP request
// carrying Email/query and an Email/get whose `ids` argument is a
// ResultReference into the query's `/ids`. The client never sees the id list.
//
// This is the call that proves the implementation is really JMAP and not two
// REST calls wearing a hat.
jmap_query_then_get :: proc(
	j: ^JMAP,
	mailbox_id: string,
	fetch_text := true,
	limit := 0,
	allocator := context.allocator,
) -> (
	emails: []Jmap_Email,
	query_ids: []string,
	err: string,
) {
	qargs := email_query_args(j, mailbox_id, limit, context.temp_allocator)
	backref := jmap_backref("q1", "Email/query", "/ids", context.temp_allocator)
	idw := jw_make(context.temp_allocator)
	jw_kraw(&idw, "#ids", backref)
	gargs := email_get_args(j, jw_string(&idw), fetch_text, context.temp_allocator)

	r, e := jmap_call(
		j,
		{
			{name = "Email/query", args = qargs, id = "q1"},
			{name = "Email/get", args = gargs, id = "g1"},
		},
		nil,
		allocator,
	)
	if e != "" {
		return nil, nil, e
	}
	_, qres, qok := jmap_result(r, "q1")
	if qok {
		query_ids = jv_str_array(qres, "ids", allocator)
	}
	_, gres, gok := jmap_result(r, "g1")
	if !gok {
		return nil, query_ids, "no result for the back-referenced Email/get"
	}
	return decode_email_list(gres, allocator), query_ids, ""
}

@(private = "file")
decode_addrs :: proc(v: json.Value, key: string, allocator: mem.Allocator) -> []Jmap_Addr {
	a := jv_arr(v, key)
	out := make([dynamic]Jmap_Addr, 0, len(a), allocator)
	for e in a {
		append(
			&out,
			Jmap_Addr {
				name = strings.clone(jv_str(e, "name"), allocator),
				email = strings.clone(jv_str(e, "email"), allocator),
			},
		)
	}
	return out[:]
}

@(private = "file")
decode_body_part :: proc(v: json.Value, allocator: mem.Allocator, depth := 0) -> Jmap_Body_Part {
	p := Jmap_Body_Part {
		part_id     = strings.clone(jv_str(v, "partId"), allocator),
		blob_id     = strings.clone(jv_str(v, "blobId"), allocator),
		size        = jv_int(v, "size"),
		type        = strings.clone(jv_str(v, "type"), allocator),
		charset     = strings.clone(jv_str(v, "charset"), allocator),
		name        = strings.clone(jv_str(v, "name"), allocator),
		disposition = strings.clone(jv_str(v, "disposition"), allocator),
		cid         = strings.clone(jv_str(v, "cid"), allocator),
	}
	if depth > MAX_MIME_DEPTH {
		return p
	}
	subs := jv_arr(v, "subParts")
	if len(subs) > 0 {
		kids := make([dynamic]Jmap_Body_Part, 0, len(subs), allocator)
		for s in subs {
			append(&kids, decode_body_part(s, allocator, depth + 1))
		}
		p.sub_parts = kids[:]
	}
	return p
}

@(private = "file")
decode_body_parts :: proc(v: json.Value, key: string, allocator: mem.Allocator) -> []Jmap_Body_Part {
	a := jv_arr(v, key)
	out := make([dynamic]Jmap_Body_Part, 0, len(a), allocator)
	for e in a {
		append(&out, decode_body_part(e, allocator))
	}
	return out[:]
}

@(private = "file")
decode_email_list :: proc(res: json.Value, allocator: mem.Allocator) -> []Jmap_Email {
	list := jv_arr(res, "list")
	out := make([dynamic]Jmap_Email, 0, len(list), allocator)
	for e in list {
		em := Jmap_Email {
			id             = strings.clone(jv_str(e, "id"), allocator),
			blob_id        = strings.clone(jv_str(e, "blobId"), allocator),
			thread_id      = strings.clone(jv_str(e, "threadId"), allocator),
			keywords       = jv_keys_true(e, "keywords", allocator),
			size           = jv_int(e, "size"),
			received_at    = strings.clone(jv_str(e, "receivedAt"), allocator),
			sent_at        = strings.clone(jv_str(e, "sentAt"), allocator),
			subject        = strings.clone(jv_str(e, "subject"), allocator),
			message_id     = jv_str_array(e, "messageId", allocator),
			in_reply_to    = jv_str_array(e, "inReplyTo", allocator),
			references     = jv_str_array(e, "references", allocator),
			has_attachment = jv_bool(e, "hasAttachment"),
			preview        = strings.clone(jv_str(e, "preview"), allocator),
			from           = decode_addrs(e, "from", allocator),
			to             = decode_addrs(e, "to", allocator),
			cc             = decode_addrs(e, "cc", allocator),
			text_body      = decode_body_parts(e, "textBody", allocator),
			html_body      = decode_body_parts(e, "htmlBody", allocator),
			attachments    = decode_body_parts(e, "attachments", allocator),
		}
		// mailboxIds is an {id: true} set, like keywords.
		em.mailbox_ids = jv_keys_true(e, "mailboxIds", allocator)
		if bs, ok := jv_get(e, "bodyStructure"); ok {
			em.body_structure = decode_body_part(bs, allocator)
		}
		em.body_values = make(map[string]string, 4, allocator)
		if bv, ok := jv_get(e, "bodyValues"); ok {
			if o, is := bv.(json.Object); is {
				for part_id, val in o {
					em.body_values[strings.clone(part_id, allocator)] = strings.clone(
						jv_str(val, "value"),
						allocator,
					)
				}
			}
		}
		append(&out, em)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Email/set — flags
// ---------------------------------------------------------------------------

// jmap_email_set_keywords patches the keyword set of one message. JMAP uses
// JSON Pointer patches (`keywords/$seen`) rather than a whole-object update,
// so two clients changing different flags do not clobber each other.
// `if_in_state`, when non-empty, is RFC 8620 5.3's optimistic concurrency
// check: the server must refuse the whole call with `stateMismatch` if its
// state has moved on since the caller last looked.
jmap_email_set_keywords :: proc(
	j: ^JMAP,
	id: string,
	add: []string,
	remove: []string,
	if_in_state := "",
	allocator := context.allocator,
) -> (
	err: string,
) {
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	if if_in_state != "" {
		jw_kstr(&w, "ifInState", if_in_state)
	}
	jw_key(&w, "update")
	jw_obj(&w)
	jw_key(&w, id)
	jw_obj(&w)
	for k in add {
		jw_kbool(&w, fmt.tprintf("keywords/%s", k), true)
	}
	for k in remove {
		jw_knull(&w, fmt.tprintf("keywords/%s", k))
	}
	jw_obj_end(&w)
	jw_obj_end(&w)
	jw_obj_end(&w)

	r, e := jmap_call(j, {{name = "Email/set", args = jw_string(&w), id = "s0"}}, nil, allocator)
	if e != "" {
		return e
	}
	_, res, ok := jmap_result(r, "s0")
	if !ok {
		return "no result for Email/set"
	}
	if nf, has := jv_get(res, "notUpdated"); has {
		if o, is := nf.(json.Object); is && len(o) > 0 {
			for k, v in o {
				return fmt.aprintf("Email/set refused %s: %s", k, jv_str(v, "type"))
			}
		}
	}
	return ""
}

jmap_email_destroy :: proc(
	j: ^JMAP,
	ids: []string,
	allocator := context.allocator,
) -> (
	destroyed: []string,
	err: string,
) {
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	jw_key(&w, "destroy")
	jw_str_array(&w, ids)
	jw_obj_end(&w)
	r, e := jmap_call(j, {{name = "Email/set", args = jw_string(&w), id = "d0"}}, nil, allocator)
	if e != "" {
		return nil, e
	}
	_, res, ok := jmap_result(r, "d0")
	if !ok {
		return nil, "no result for Email/set destroy"
	}
	return jv_str_array(res, "destroyed", allocator), ""
}

// ---------------------------------------------------------------------------
// Email/changes
// ---------------------------------------------------------------------------

Jmap_Changes :: struct {
	old_state:        string,
	new_state:        string,
	has_more_changes: bool,
	created:          []string,
	updated:          []string,
	destroyed:        []string,
}

// jmap_email_changes is JMAP's answer to IMAP's CONDSTORE: given the state
// token from a previous call, the server reports exactly what changed. This is
// the whole reason JMAP syncs are cheap.
jmap_email_changes :: proc(
	j: ^JMAP,
	since_state: string,
	max_changes := 256,
	allocator := context.allocator,
) -> (
	ch: Jmap_Changes,
	err: string,
) {
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	jw_kstr(&w, "sinceState", since_state)
	jw_kint(&w, "maxChanges", max_changes)
	jw_obj_end(&w)
	r, e := jmap_call(j, {{name = "Email/changes", args = jw_string(&w), id = "c0"}}, nil, allocator)
	if e != "" {
		return ch, e
	}
	_, res, ok := jmap_result(r, "c0")
	if !ok {
		return ch, "no result for Email/changes"
	}
	ch.old_state = strings.clone(jv_str(res, "oldState"), allocator)
	ch.new_state = strings.clone(jv_str(res, "newState"), allocator)
	ch.has_more_changes = jv_bool(res, "hasMoreChanges")
	ch.created = jv_str_array(res, "created", allocator)
	ch.updated = jv_str_array(res, "updated", allocator)
	ch.destroyed = jv_str_array(res, "destroyed", allocator)
	return ch, ""
}

jmap_email_state :: proc(j: ^JMAP, allocator := context.allocator) -> (state: string, err: string) {
	idw := jw_make(context.temp_allocator)
	jw_key(&idw, "ids")
	jw_str_array(&idw, {})
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	jw_raw(&w, jw_string(&idw))
	jw_obj_end(&w)
	r, e := jmap_call(j, {{name = "Email/get", args = jw_string(&w), id = "st"}}, nil, allocator)
	if e != "" {
		return "", e
	}
	_, res, ok := jmap_result(r, "st")
	if !ok {
		return "", "no result for the state probe"
	}
	return strings.clone(jv_str(res, "state"), allocator), ""
}

// ---------------------------------------------------------------------------
// Blob download
// ---------------------------------------------------------------------------

// jmap_download fetches a blob through the session's downloadUrl template
// (RFC 8620 6.2). The template variables are {accountId}, {blobId}, {type}
// and {name}, and they must be percent-encoded on substitution.
jmap_download :: proc(
	j: ^JMAP,
	blob_id: string,
	name := "message.eml",
	type := "message/rfc822",
	allocator := context.allocator,
) -> (
	data: []u8,
	err: string,
) {
	if j.session.download_url == "" {
		return nil, "the session object has no downloadUrl"
	}
	url := j.session.download_url
	url, _ = strings.replace_all(url, "{accountId}", url_encode_component(j.session.primary_mail_account, context.temp_allocator), context.temp_allocator)
	url, _ = strings.replace_all(url, "{blobId}", url_encode_component(blob_id, context.temp_allocator), context.temp_allocator)
	url, _ = strings.replace_all(url, "{name}", url_encode_component(name, context.temp_allocator), context.temp_allocator)
	url, _ = strings.replace_all(url, "{type}", url_encode_component(type, context.temp_allocator), context.temp_allocator)

	_, uhost, uport, target, ue := url_split(url)
	if ue != "" {
		return nil, ue
	}
	if uhost != j.host || uport != j.port {
		return nil, fmt.aprintf("refusing a downloadUrl that points elsewhere: %q", url)
	}
	if e := jmap_open_conn(j); e != "" {
		return nil, e
	}
	resp, he := http_do(
		&j.conn,
		Http_Request {
			method = "GET",
			target = target,
			host = fmt.tprintf("%s:%d", j.host, j.port),
			headers = {{name = "Authorization", value = j.auth}},
		},
		allocator,
	)
	if he != "" {
		return nil, he
	}
	if resp.close {
		conn_close(&j.conn)
		j.conn_open = false
	}
	if resp.status != 200 {
		return nil, fmt.aprintf("blob download: HTTP %d %s", resp.status, resp.reason)
	}
	return resp.body, ""
}

// ---------------------------------------------------------------------------
// Keywords <-> Maildir flags
// ---------------------------------------------------------------------------

// jmap_keywords_to_flags maps RFC 8621 4.1.1's keywords onto Maildir letters.
// Only the five with an agreed meaning are mapped; a custom keyword has no
// Maildir equivalent and is dropped rather than guessed at.
jmap_keywords_to_flags :: proc(keywords: []string) -> (f: Maildir_Flags) {
	for k in keywords {
		switch strings.to_lower(k, context.temp_allocator) {
		case "$seen":
			f |= {.Seen}
		case "$flagged":
			f |= {.Flagged}
		case "$answered":
			f |= {.Replied}
		case "$draft":
			f |= {.Draft}
		case "$forwarded":
			f |= {.Passed}
		}
	}
	return
}

maildir_flags_to_keywords :: proc(f: Maildir_Flags, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 5, allocator)
	if .Seen in f {append(&out, "$seen")}
	if .Flagged in f {append(&out, "$flagged")}
	if .Replied in f {append(&out, "$answered")}
	if .Draft in f {append(&out, "$draft")}
	if .Passed in f {append(&out, "$forwarded")}
	return out[:]
}

// ---------------------------------------------------------------------------
// Syncing into a Maildir
// ---------------------------------------------------------------------------

Jmap_Sync_Result :: struct {
	fetched:   int,
	bytes:     int,
	delivered: []string,
	folder:    string,
	state:     string,
}

// jmap_sync writes one JMAP mailbox into one Maildir folder.
//
// The Maildir gets the *raw* message, downloaded as a blob, not something
// re-serialised from the decomposed Email object. That matters: the bytes on
// disk then match exactly what the IMAP and POP3 syncs write, which is what
// makes the three-protocol comparison a real test instead of a coincidence.
// The decomposed fields are used only for the flags and for the cross-check in
// `jmap_check_decomposition`.
jmap_sync :: proc(
	j: ^JMAP,
	md: ^Maildir,
	mailbox_id: string,
	folder: string,
	allocator := context.allocator,
) -> (
	res: Jmap_Sync_Result,
	err: string,
) {
	res.folder = folder
	// Create the folder before fetching anything. A mailbox that exists on the
	// server must exist on disk even when it is empty, or a UI reading the
	// Maildir cannot show an empty Sent or Trash at all.
	if ee := maildir_ensure_folder(md, folder); ee != "" {
		return res, ee
	}
	emails, _, qe := jmap_query_then_get(j, mailbox_id, true, 0, allocator)
	if qe != "" {
		return res, qe
	}
	names := make([dynamic]string, 0, len(emails), allocator)
	for em in emails {
		raw, de := jmap_download(j, em.blob_id, "message.eml", "message/rfc822", allocator)
		if de != "" {
			return res, fmt.aprintf("downloading blob %s: %s", em.blob_id, de)
		}
		flags := jmap_keywords_to_flags(em.keywords)
		// JMAP *does* know whether a message has been read, so unlike POP3
		// the flags can be written straight into cur/.
		name, we := maildir_deliver(md, folder, raw, flags, flags == {}, allocator)
		if we != "" {
			return res, we
		}
		append(&names, name)
		res.fetched += 1
		res.bytes += len(raw)
	}
	res.delivered = names[:]
	if st, se := jmap_email_state(j, allocator); se == "" {
		res.state = st
	}
	return res, ""
}

// jmap_check_decomposition compares the server's structured Email object
// against this engine's own parse of the same raw bytes. A disagreement means
// one of the two is wrong, which is the whole value of having both.
Jmap_Decomp_Check :: struct {
	subject_match:    bool,
	from_match:       bool,
	text_match:       bool,
	msgid_match:      bool,
	attachment_match: bool,
	detail:           string,
}

jmap_check_decomposition :: proc(
	em: Jmap_Email,
	raw: []u8,
	allocator := context.allocator,
) -> Jmap_Decomp_Check {
	m := parse_message(raw, allocator)
	out: Jmap_Decomp_Check

	out.subject_match = m.subject == em.subject
	out.from_match =
		(len(m.from) == 0 && len(em.from) == 0) ||
		(len(m.from) > 0 && len(em.from) > 0 && m.from[0].email == em.from[0].email)
	out.msgid_match =
		(m.message_id == "" && len(em.message_id) == 0) ||
		(len(em.message_id) > 0 && em.message_id[0] == m.message_id)

	// JMAP's textBody values come with normalised line endings and may be
	// truncated by maxBodyValueBytes, so compare the trimmed prefix.
	jtext := ""
	if len(em.text_body) > 0 {
		if v, ok := em.body_values[em.text_body[0].part_id]; ok {
			jtext = v
		}
	}
	mine := strings.trim_space(m.text_plain)
	theirs := strings.trim_space(jtext)
	out.text_match = mine == theirs
	if !out.text_match && theirs != "" {
		// Accept a prefix match: a server may legitimately truncate.
		out.text_match = strings.has_prefix(mine, theirs) || strings.has_prefix(theirs, mine)
	}
	if mine == "" && theirs == "" {
		out.text_match = true
	}

	// Count only the real attachments: JMAP's `attachments` excludes the
	// bodies, and so does this engine's selection, so the counts line up.
	mine_atts := 0
	for a in m.attachments {
		if a.mime_type != "text/plain" && a.mime_type != "text/html" {
			mine_atts += 1
		} else if a.filename != "" {
			mine_atts += 1
		}
	}
	out.attachment_match = mine_atts == len(em.attachments)
	out.detail = fmt.aprintf(
		"subject(%v) from(%v) msgid(%v) text(%v) atts(mine=%d jmap=%d)",
		out.subject_match,
		out.from_match,
		out.msgid_match,
		out.text_match,
		mine_atts,
		len(em.attachments),
		allocator = allocator,
	)
	return out
}

// jmap_mailbox_get_ids fetches a specific set of mailboxes. An EMPTY slice
// means "none" — which is the distinction a JMAP server has to get right, and
// is therefore worth being able to ask for.
jmap_mailbox_get_ids :: proc(
	j: ^JMAP,
	ids: []string,
	allocator := context.allocator,
) -> (
	boxes: []Jmap_Mailbox,
	err: string,
) {
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "accountId", j.session.primary_mail_account)
	jw_key(&w, "ids")
	jw_str_array(&w, ids)
	jw_obj_end(&w)
	r, e := jmap_call(j, {{name = "Mailbox/get", args = jw_string(&w), id = "mi"}}, nil, allocator)
	if e != "" {
		return nil, e
	}
	_, args, ok := jmap_result(r, "mi")
	if !ok {
		return nil, "no result for Mailbox/get"
	}
	list := jv_arr(args, "list")
	out := make([dynamic]Jmap_Mailbox, 0, len(list), allocator)
	for e2 in list {
		append(
			&out,
			Jmap_Mailbox {
				id = strings.clone(jv_str(e2, "id"), allocator),
				name = strings.clone(jv_str(e2, "name"), allocator),
				parent_id = strings.clone(jv_str(e2, "parentId"), allocator),
				role = strings.clone(jv_str(e2, "role"), allocator),
				sort_order = jv_int(e2, "sortOrder"),
				total_emails = jv_int(e2, "totalEmails"),
				unread_emails = jv_int(e2, "unreadEmails"),
				my_rights_may_read = true,
			},
		)
	}
	return out[:], ""
}
