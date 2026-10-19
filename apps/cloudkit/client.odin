// Package cloudkit is the Odin client for the Palmy cloud: Supabase's
// GoTrue (auth), PostgREST (tables and functions) and Storage (files),
// behind one API gateway.
//
//	c, err := cloudkit.open()               // reads the token store
//	defer cloudkit.close(c)
//	if !cloudkit.signed_in(c) {
//		err = cloudkit.sign_in(c, email, password)
//	}
//	rows, err := cloudkit.select(c, "identities", "select=*&order=created_at")
//
// Scope is the point. A process started with PALM_IDENTITY=<handle> gets the
// session minted for that one identity, from scoped/<handle>.json, and never
// the person's unscoped session: there is no fallback, so code running inside
// a scope cannot widen it by accident. The database enforces the same thing
// again on every row (cloud/CONTRACT.md); this makes the client agree with it.
//
// The token store is ~/.local/share/palm/cloud (or $PALM_CLOUD_DIR):
//
//	config.json            {"url": ..., "anon_key": ...}, optional
//	session.json           the person's own session              0600
//	scoped/<handle>.json   this machine's session for one identity 0600
//	delegated/<name>.json  a session minted to hand to an assistant 0600
//	current                the identity the person last switched to
//
// $PALM_CLOUD_SESSION names one session file to use instead, which is how a
// delegated session is handed to the program that holds it. It must hold a
// scoped session; an unscoped one is refused rather than used.
//
// The directory is 0700. Files are written to a temporary name and renamed,
// so a crash never leaves half a token behind.
package cloudkit

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

DEFAULT_URL :: "http://127.0.0.1:54321"
// The local stack's anon key (cloud/dev). It is public by design: it only
// identifies the project, and RLS decides what it can reach.
DEFAULT_ANON_KEY :: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"

Error_Kind :: enum u8 {
	None,
	Unavailable, // the server could not be reached
	Not_Signed_In, // there is no session to use
	Unauthorized, // the session was refused (401): expired, revoked, wrong password
	Out_Of_Scope, // refused by policy (403): another identity's data, or a scoped session asking for account powers
	Not_Found, // 404
	Conflict, // 409, or a unique violation: that handle is taken
	Invalid, // 400/422: the request itself was wrong
	Failed, // anything else
}

Error :: struct {
	kind:    Error_Kind,
	status:  int, // HTTP status, 0 when the server was not reached
	code:    string, // GoTrue error_code, PostgREST SQLSTATE, or Storage error
	message: string,
}

ok :: proc(e: Error) -> bool {
	return e.kind == .None
}

error_kind_name :: proc(k: Error_Kind) -> string {
	switch k {
	case .None:
		return "ok"
	case .Unavailable:
		return "unavailable"
	case .Not_Signed_In:
		return "not signed in"
	case .Unauthorized:
		return "unauthorized"
	case .Out_Of_Scope:
		return "out of scope"
	case .Not_Found:
		return "not found"
	case .Conflict:
		return "conflict"
	case .Invalid:
		return "invalid"
	case .Failed:
		return "failed"
	}
	return "failed"
}

Session :: struct {
	access_token:  string,
	refresh_token: string,
	expires_at:    i64, // unix seconds
	user_id:       string,
	email:         string,
	identity_id:   string, // the palm_identity claim; "" for the person's own session
	handle:        string, // the identity's handle, for a scoped session
}

Client :: struct {
	url:        Url,
	url_text:   string,
	anon_key:   string,
	dir:        string, // the token store
	scope:      string, // PALM_IDENTITY at open, "" for the person
	session_file: string, // $PALM_CLOUD_SESSION, when a delegated session is in use
	session:    Session,
	has_session: bool,
	user_agent: string,
}

// open reads configuration and the session that matches the scope in force.
// Not being signed in is not an error; signed_in() says so.
//
// Overrides, in order: arguments, then $PALM_CLOUD_URL / $PALM_CLOUD_ANON_KEY
// / $PALM_CLOUD_DIR / $PALM_IDENTITY, then config.json, then the defaults.
open :: proc(url := "", anon_key := "", dir := "", scope := "", app := "cloudkit") -> (c: ^Client, err: Error) {
	c = new(Client)
	c.dir = strings.clone(dir != "" ? dir : store_dir(context.temp_allocator))
	c.scope = strings.clone(scope != "" ? scope : os.get_env("PALM_IDENTITY", context.temp_allocator))

	cfg_url, cfg_key := read_config(c.dir)
	u := first_nonempty(url, os.get_env("PALM_CLOUD_URL", context.temp_allocator), cfg_url, DEFAULT_URL)
	k := first_nonempty(anon_key, os.get_env("PALM_CLOUD_ANON_KEY", context.temp_allocator), cfg_key, DEFAULT_ANON_KEY)
	c.url_text = strings.clone(u)
	c.anon_key = strings.clone(k)
	parsed, pok := parse_url(c.url_text)
	if !pok {
		return c, Error{kind = .Invalid, message = fmt.aprintf("not an http(s) URL: %s", u)}
	}
	c.url = parsed
	host := machine_name()
	c.user_agent = fmt.aprintf("palm-%s/0.1 (%s)", app, host != "" ? host : "palmy")

	if c.scope != "" && !handle_ok(c.scope) {
		return c, Error{kind = .Invalid, message = fmt.aprintf("not an identity handle: %q", c.scope)}
	}
	if f := os.get_env("PALM_CLOUD_SESSION", context.temp_allocator); f != "" {
		c.session_file = strings.clone(f)
		c.session, c.has_session = session_load(f)
		if c.has_session && c.session.identity_id == "" {
			session_free(&c.session)
			c.has_session = false
			return c, Error{kind = .Out_Of_Scope, code = "palm_identity",
				message = fmt.aprintf("%s does not hold a scoped session; PALM_CLOUD_SESSION is only for sessions scoped to one identity", f)}
		}
		if c.has_session {
			if c.scope != "" && c.scope != c.session.handle {
				return c, Error{kind = .Out_Of_Scope, code = "palm_identity",
					message = fmt.aprintf("PALM_IDENTITY is %q but the session in %s acts for %q", c.scope, f, c.session.handle)}
			}
			if c.scope == "" {
				delete(c.scope)
				c.scope = strings.clone(c.session.handle)
			}
		}
		return c, {}
	}
	c.session, c.has_session = session_load(session_path(c, context.temp_allocator))
	return c, {}
}

close :: proc(c: ^Client) {
	if c == nil {
		return
	}
	session_free(&c.session)
	delete(c.url_text)
	delete(c.anon_key)
	delete(c.dir)
	delete(c.scope)
	delete(c.session_file)
	delete(c.user_agent)
	free(c)
}

signed_in :: proc(c: ^Client) -> bool {
	return c.has_session && c.session.refresh_token != ""
}

// scoped says whether the session in use acts for one identity only.
scoped :: proc(c: ^Client) -> bool {
	return c.session.identity_id != "" || c.scope != ""
}

// ---------------------------------------------------------------------------
// Auth (GoTrue)
// ---------------------------------------------------------------------------

sign_up :: proc(c: ^Client, email, password: string) -> Error {
	if c.scope != "" {
		return out_of_scope_local(c)
	}
	o := obj()
	put(&o, "email", email)
	put(&o, "password", password)
	v, e := call(c, "POST", "/auth/v1/signup", obj_done(&o), auth = false)
	defer value_destroy(v)
	if !ok(e) {
		return e
	}
	if get_str(v, "access_token") == "" {
		return Error{kind = .Invalid, status = 200, code = "confirmation_required",
			message = strings.clone("the account was created; confirm the email address, then sign in")}
	}
	return adopt_token_response(c, v)
}

sign_in :: proc(c: ^Client, email, password: string) -> Error {
	if c.scope != "" {
		return out_of_scope_local(c)
	}
	o := obj()
	put(&o, "email", email)
	put(&o, "password", password)
	v, e := call(c, "POST", "/auth/v1/token?grant_type=password", obj_done(&o), auth = false)
	defer value_destroy(v)
	if !ok(e) {
		return e
	}
	return adopt_token_response(c, v)
}

// refresh exchanges the refresh token for a new pair. GoTrue rotates refresh
// tokens, so the new one is saved before this returns.
refresh :: proc(c: ^Client) -> Error {
	if !signed_in(c) {
		return Error{kind = .Not_Signed_In, message = strings.clone("not signed in")}
	}
	v, e := exchange(c, c.session.refresh_token)
	defer value_destroy(v)
	if !ok(e) {
		if e.kind == .Unauthorized || e.kind == .Invalid {
			// The session is gone: revoked, signed out elsewhere, expired.
			forget(c)
		}
		return e
	}
	return adopt_token_response(c, v)
}

// ensure_fresh refreshes when the access token has under a minute left.
ensure_fresh :: proc(c: ^Client) -> Error {
	if !signed_in(c) {
		return Error{kind = .Not_Signed_In, message = strings.clone("not signed in")}
	}
	if c.session.expires_at - now_unix() > 60 {
		return {}
	}
	return refresh(c)
}

// sign_out ends this session on the server and forgets it locally. The
// local copy goes even when the server cannot be reached.
sign_out :: proc(c: ^Client) -> Error {
	e: Error
	if signed_in(c) {
		v: Value
		v, e = call(c, "POST", "/auth/v1/logout?scope=local", "", auth = true)
		value_destroy(v)
		if e.kind == .Unauthorized {
			e = {}
		}
	}
	forget(c)
	return e
}

// user is GoTrue's view of the account (id, email, created_at, ...).
user :: proc(c: ^Client, allocator := context.allocator) -> (v: Value, e: Error) {
	return call(c, "GET", "/auth/v1/user", "", auth = true, allocator = allocator)
}

// exchange trades any refresh token for a token response. Used by refresh,
// and to take up a scoped session minted elsewhere.
exchange :: proc(c: ^Client, refresh_token: string, allocator := context.allocator) -> (v: Value, e: Error) {
	o := obj()
	put(&o, "refresh_token", refresh_token)
	return call(c, "POST", "/auth/v1/token?grant_type=refresh_token", obj_done(&o), auth = false, allocator = allocator)
}

@(private)
adopt_token_response :: proc(c: ^Client, v: Value) -> Error {
	s := session_from_token_response(v)
	if s.access_token == "" || s.refresh_token == "" {
		session_free(&s)
		return Error{kind = .Failed, message = strings.clone("the token response had no tokens")}
	}
	// The claim decides, not the file name: a session whose token carries
	// palm_identity is scoped, wherever it is stored.
	if c.scope == "" && s.identity_id != "" {
		session_free(&s)
		return Error{kind = .Out_Of_Scope, message = strings.clone("a scoped token cannot be the person's session")}
	}
	if c.scope != "" {
		if s.identity_id == "" {
			session_free(&s)
			return Error{kind = .Out_Of_Scope, message = strings.clone("an unscoped token cannot be stored as a scoped session")}
		}
		s.handle = strings.clone(c.scope)
	}
	session_free(&c.session)
	c.session = s
	c.has_session = true
	return session_save(c)
}

session_from_token_response :: proc(v: Value) -> (s: Session) {
	s.access_token = strings.clone(get_str(v, "access_token"))
	s.refresh_token = strings.clone(get_str(v, "refresh_token"))
	s.expires_at = get_int(v, "expires_at")
	if s.expires_at == 0 {
		s.expires_at = now_unix() + max(get_int(v, "expires_in"), 60)
	}
	s.user_id = strings.clone(get_str(v, "user", "id"))
	s.email = strings.clone(get_str(v, "user", "email"))
	claims, cok := jwt_claims(s.access_token, context.temp_allocator)
	if cok {
		s.identity_id = strings.clone(get_str(claims, "palm_identity"))
		if s.user_id == "" {
			s.user_id = strings.clone(get_str(claims, "sub"))
		}
	}
	return
}

session_free :: proc(s: ^Session) {
	delete(s.access_token)
	delete(s.refresh_token)
	delete(s.user_id)
	delete(s.email)
	delete(s.identity_id)
	delete(s.handle)
	s^ = {}
}

// jwt_claims decodes a JWT's payload without verifying it. That is only ever
// for display and routing; the server verifies every token it is handed.
jwt_claims :: proc(token: string, allocator := context.allocator) -> (v: Value, ok: bool) {
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 {
		return nil, false
	}
	p := strings.builder_make(context.temp_allocator)
	for ch in parts[1] {
		switch ch {
		case '-':
			strings.write_byte(&p, '+')
		case '_':
			strings.write_byte(&p, '/')
		case:
			strings.write_rune(&p, ch)
		}
	}
	for strings.builder_len(p) % 4 != 0 {
		strings.write_byte(&p, '=')
	}
	raw, err := base64.decode(strings.to_string(p), allocator = context.temp_allocator)
	if err != nil {
		return nil, false
	}
	return parse(string(raw), allocator)
}

@(private)
out_of_scope_local :: proc(c: ^Client) -> Error {
	return Error{kind = .Out_Of_Scope, code = "palm_identity",
		message = fmt.aprintf("this process is scoped to %q (PALM_IDENTITY); account operations are refused", c.scope)}
}

// ---------------------------------------------------------------------------
// The one request path every API call goes through
// ---------------------------------------------------------------------------

// call sends a JSON request through the gateway and parses the answer. With
// auth, it refreshes a stale token first and retries once on a 401.
call :: proc(
	c: ^Client,
	method, path, body: string,
	auth := true,
	extra: []Header = nil,
	allocator := context.allocator,
) -> (
	v: Value,
	e: Error,
) {
	if auth {
		if !signed_in(c) {
			return nil, Error{kind = .Not_Signed_In, message = strings.clone("not signed in")}
		}
		if fe := ensure_fresh(c); !ok(fe) {
			return nil, fe
		}
	}
	for attempt in 0 ..< 2 {
		resp, terr := send(c, method, path, transmute([]u8)body, auth, extra)
		if terr != "" {
			return nil, Error{kind = .Unavailable, message = terr}
		}
		if resp.status == 401 && auth && attempt == 0 {
			response_destroy(&resp)
			if re := refresh(c); !ok(re) {
				return nil, re
			}
			continue
		}
		defer response_destroy(&resp)
		parsed, _ := parse(resp.body, allocator)
		if resp.status >= 200 && resp.status < 300 {
			return parsed, {}
		}
		e = error_from(resp.status, parsed)
		value_destroy(parsed, allocator)
		return nil, e
	}
	return nil, Error{kind = .Unauthorized, status = 401, message = strings.clone("the session was refused")}
}

@(private)
send :: proc(c: ^Client, method, path: string, body: []u8, auth: bool, extra: []Header) -> (Response, string) {
	headers := make([dynamic]Header, context.temp_allocator)
	append(&headers, Header{"apikey", c.anon_key})
	bearer := auth && c.has_session ? c.session.access_token : c.anon_key
	append(&headers, Header{"Authorization", fmt.tprintf("Bearer %s", bearer)})
	append(&headers, Header{"Accept", "application/json"})
	if len(body) > 0 || method == "POST" || method == "PATCH" || method == "PUT" {
		append(&headers, Header{"Content-Type", "application/json"})
	}
	append(&headers, ..extra)
	return http_do(c.url, Request{method = method, path = path, headers = headers[:], body = body}, c.user_agent)
}

// error_from reads the three error dialects: GoTrue {code, error_code, msg},
// PostgREST {code: SQLSTATE, message, hint}, Storage {statusCode, error, message}.
error_from :: proc(status: int, v: Value) -> Error {
	e := Error{status = status}
	code := get_str(v, "error_code")
	if code == "" {
		code = get_str(v, "code")
	}
	if code == "" {
		code = get_str(v, "error")
	}
	msg := get_str(v, "msg")
	if msg == "" {
		msg = get_str(v, "message")
	}
	if msg == "" {
		msg = get_str(v, "error_description")
	}
	if msg == "" {
		msg = fmt.tprintf("HTTP %d", status)
	}
	e.code = strings.clone(code)
	e.message = strings.clone(msg)
	// Storage reports policy refusals as 400 with statusCode "403".
	inner := get_str(v, "statusCode")
	switch {
	case status == 401 || inner == "401":
		e.kind = .Unauthorized
	case status == 403 || inner == "403" || code == "42501":
		e.kind = .Out_Of_Scope
	case status == 404 || inner == "404":
		e.kind = .Not_Found
	case status == 409 || inner == "409" || code == "23505" || code == "user_already_exists" || code == "email_exists":
		e.kind = .Conflict
	case code == "invalid_credentials":
		e.kind = .Unauthorized
	case status == 400 || status == 422:
		e.kind = .Invalid
	case:
		e.kind = .Failed
	}
	return e
}

// ---------------------------------------------------------------------------
// The token store
// ---------------------------------------------------------------------------

store_dir :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("PALM_CLOUD_DIR", context.temp_allocator); d != "" {
		return strings.clone(d, allocator)
	}
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {
		return pjoin({x, "palm", "cloud"}, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return pjoin({home, ".local", "share", "palm", "cloud"}, allocator)
}

session_path :: proc(c: ^Client, allocator := context.allocator) -> string {
	if c.session_file != "" {
		return strings.clone(c.session_file, allocator)
	}
	if c.scope != "" {
		return pjoin({c.dir, "scoped", fmt.tprintf("%s.json", c.scope)}, allocator)
	}
	return pjoin({c.dir, "session.json"}, allocator)
}

scoped_path :: proc(c: ^Client, handle: string, allocator := context.allocator) -> string {
	return pjoin({c.dir, "scoped", fmt.tprintf("%s.json", handle)}, allocator)
}

// handle_ok matches the contract's handle rule, which also keeps a handle
// safe to use as a file name.
handle_ok :: proc(h: string) -> bool {
	if len(h) < 2 || len(h) > 63 {
		return false
	}
	for ch, i in h {
		alnum := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
		if i == 0 && !alnum {
			return false
		}
		if !alnum && ch != '.' && ch != '_' && ch != '-' {
			return false
		}
	}
	return true
}

@(private)
session_load :: proc(path: string) -> (s: Session, found: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	v, pok := parse(string(data), context.temp_allocator)
	if !pok {
		return {}, false
	}
	s.access_token = strings.clone(get_str(v, "access_token"))
	s.refresh_token = strings.clone(get_str(v, "refresh_token"))
	s.expires_at = get_int(v, "expires_at")
	s.user_id = strings.clone(get_str(v, "user_id"))
	s.email = strings.clone(get_str(v, "email"))
	s.identity_id = strings.clone(get_str(v, "identity_id"))
	s.handle = strings.clone(get_str(v, "handle"))
	return s, s.refresh_token != ""
}

@(private)
session_text :: proc(s: Session) -> string {
	o := obj()
	put(&o, "access_token", s.access_token)
	put(&o, "refresh_token", s.refresh_token)
	put(&o, "expires_at", s.expires_at)
	put(&o, "user_id", s.user_id)
	put(&o, "email", s.email)
	put(&o, "identity_id", s.identity_id)
	put(&o, "handle", s.handle)
	return obj_done(&o)
}

@(private)
session_save :: proc(c: ^Client) -> Error {
	return write_private(session_path(c, context.temp_allocator), session_text(c.session))
}

delegated_path :: proc(c: ^Client, handle, device_id: string, allocator := context.allocator) -> string {
	short := device_id[:min(8, len(device_id))]
	return pjoin({c.dir, "delegated", fmt.tprintf("%s-%s.json", handle, short)}, allocator)
}

// save_scoped stores a scoped session under its handle, for a later process
// started with PALM_IDENTITY=<handle>, or at `path` when one is given.
save_scoped :: proc(c: ^Client, s: Session, path := "") -> Error {
	if !handle_ok(s.handle) {
		return Error{kind = .Invalid, message = strings.clone("a scoped session needs its identity's handle")}
	}
	if s.identity_id == "" {
		return Error{kind = .Out_Of_Scope, message = strings.clone("refusing to store an unscoped token as scoped")}
	}
	return write_private(path != "" ? path : scoped_path(c, s.handle, context.temp_allocator), session_text(s))
}

// forget drops the session in use, from memory and from disk.
forget :: proc(c: ^Client) {
	os.remove(session_path(c, context.temp_allocator))
	session_free(&c.session)
	c.has_session = false
}

// forget_scoped removes a stored scoped session (after revoking it).
forget_scoped :: proc(c: ^Client, handle: string) {
	if handle_ok(handle) {
		os.remove(scoped_path(c, handle, context.temp_allocator))
	}
}

// make_dirs creates a directory and whatever parents it lacks, like
// `mkdir -p`, without opening a single ancestor. core:os's
// make_directory_all opens every directory from `/` (or `.`) down and
// mkdirs relative to each; inside the assistant's Landlock sandbox, or under
// any ancestor that may be passed through but not read, that first open is
// refused and nothing is created. This finds the deepest parent that exists
// by stat alone and mkdirs each missing level by its full path, which needs
// only the right to make a directory where it is made. True when the
// directory exists afterwards.
make_dirs :: proc(path: string, perm := os.Permissions_Default_Directory) -> bool {
	if path == "" {
		return false
	}
	p := strings.trim_right(path, "/")
	if p == "" || os.is_dir(p) {
		return true // "/", or there already
	}
	missing := make([dynamic]string, context.temp_allocator)
	cur := p
	for cur != "" && cur != "." && cur != "/" && !os.is_dir(cur) {
		append(&missing, cur)
		i := strings.last_index_byte(cur, '/')
		if i < 0 {break}
		cur = cur[:i]
	}
	#reverse for d in missing {
		_ = os.make_directory(d, perm)
	}
	return os.is_dir(p)
}

// write_private writes a file only its owner can read, atomically, inside a
// directory only its owner can enter.
write_private :: proc(path, text: string) -> Error {
	dir := filepath.dir(path)
	if !make_dirs(dir, os.perm_number(0o700)) {
		return Error{kind = .Failed, message = fmt.aprintf("cannot create %s", dir)}
	}
	// make_dirs leaves existing directories alone, and the umask
	// can only narrow; tighten both levels explicitly.
	os.chmod(dir, os.perm_number(0o700))
	if b := filepath.base(dir); b == "scoped" || b == "delegated" {
		os.chmod(filepath.dir(dir), os.perm_number(0o700))
	}
	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if err := os.write_entire_file(tmp, transmute([]u8)text, os.perm_number(0o600)); err != nil {
		os.remove(tmp)
		return Error{kind = .Failed, message = fmt.aprintf("cannot write %s (%v)", tmp, err)}
	}
	os.chmod(tmp, os.perm_number(0o600))
	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		return Error{kind = .Failed, message = fmt.aprintf("cannot write %s (%v)", path, err)}
	}
	return {}
}

// The identity the person last switched to, by handle. This is a
// preference, not a scope: it says which identity the interface shows first.
current_identity :: proc(c: ^Client, allocator := context.allocator) -> string {
	data, err := os.read_entire_file_from_path(pjoin({c.dir, "current"}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return ""
	}
	h := strings.trim_space(string(data))
	if !handle_ok(h) {
		return ""
	}
	return strings.clone(h, allocator)
}

set_current_identity :: proc(c: ^Client, handle: string) -> Error {
	if handle != "" && !handle_ok(handle) {
		return Error{kind = .Invalid, message = fmt.aprintf("not an identity handle: %q", handle)}
	}
	return write_private(pjoin({c.dir, "current"}, context.temp_allocator), fmt.tprintf("%s\n", handle))
}

@(private)
read_config :: proc(dir: string) -> (url, key: string) {
	data, err := os.read_entire_file_from_path(pjoin({dir, "config.json"}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return "", ""
	}
	v, pok := parse(string(data), context.temp_allocator)
	if !pok {
		return "", ""
	}
	return get_str(v, "url"), get_str(v, "anon_key")
}

// machine_name is the kernel's hostname, which GoTrue records as the
// session's user agent and the devices list shows.
machine_name :: proc() -> string {
	data, err := os.read_entire_file_from_path("/proc/sys/kernel/hostname", context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

@(private)
pjoin :: proc(parts: []string, allocator := context.allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

@(private)
first_nonempty :: proc(xs: ..string) -> string {
	for x in xs {
		if x != "" {
			return x
		}
	}
	return ""
}

now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}
