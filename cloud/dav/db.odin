// Talking to the database: PostgREST, always with the caller's own token.
//
// The server never reads or writes a calendar row with elevated rights. A
// request runs as the person (a bearer token from GoTrue) or as one of their
// identities (a token minted here after an app password checked out), and
// every query goes through RLS. The service key is used for exactly one
// thing: dav_app_password_check, which a user session may not call.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import web "web"

Ident :: struct {
	id:           string,
	handle:       string,
	display_name: string,
	color:        string,
	kind:         string,
}

Ctx :: struct {
	token:    string, // bearer for PostgREST
	user:     string, // auth.users id
	scoped:   string, // identity id the session is scoped to, "" if unscoped
	idents:   []Ident, // identities the session can act as
	req:      ^web.Request,
	res:      ^web.Response,
	app_pw:   bool, // authenticated by app password
}

DB_Error :: struct {
	status:  int, // HTTP status from PostgREST, 0 if unreachable
	code:    string, // SQLSTATE or PostgREST code
	message: string,
}

db_ok :: proc(e: DB_Error) -> bool {
	return e.status >= 200 && e.status < 300
}

// rest calls PostgREST. `path` starts after /rest/v1.
rest :: proc(c: ^Ctx, method, path: string, body := "", prefer := "", service := false) -> (v: json.Value, e: DB_Error) {
	url := strings.concatenate({cfg.supabase, "/rest/v1", path})
	token := service ? cfg.service_key : c.token
	hs := make([dynamic]web.Header, 0, 5)
	append(&hs, web.Header{"apikey", service ? cfg.service_key : cfg.anon_key})
	append(&hs, web.Header{"Authorization", strings.concatenate({"Bearer ", token})})
	append(&hs, web.Header{"Accept", "application/json"})
	if body != "" {
		append(&hs, web.Header{"Content-Type", "application/json"})
	}
	if prefer != "" {
		append(&hs, web.Header{"Prefer", prefer})
	}
	res, err := web.request(method, url, hs[:], body)
	if err != "" {
		return nil, {0, "unavailable", err}
	}
	e.status = res.status
	if res.body != "" {
		parsed, jerr := json.parse(transmute([]u8)res.body, parse_integers = true)
		if jerr == nil {
			v = parsed
		}
	}
	if res.status >= 300 {
		if obj, ok := v.(json.Object); ok {
			e.code = jstr(obj, "code")
			e.message = jstr(obj, "message")
		} else {
			e.message = res.body
		}
		if cfg.log {
			fmt.eprintfln("  db %s %s -> %d %s %s", method, path, res.status, e.code, e.message)
		}
	}
	return v, e
}

rpc :: proc(c: ^Ctx, fn: string, body: string, service := false) -> (json.Value, DB_Error) {
	return rest(c, "POST", strings.concatenate({"/rpc/", fn}), body, service = service)
}

// http_status_of maps a database refusal to the HTTP status a DAV client
// understands.
http_status_of :: proc(e: DB_Error) -> int {
	switch e.code {
	case "P0412":
		return 412
	case "P0409":
		return 403 // CALDAV:no-uid-conflict / CARDDAV:no-uid-conflict
	case "42501":
		return 403
	case "23505":
		return 409
	case "PGRST301", "PGRST302", "PT401":
		return 401
	case "unavailable":
		return 503
	}
	if e.status == 401 || e.status == 403 || e.status == 404 || e.status == 409 {
		return e.status
	}
	return 500
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

jstr :: proc(o: json.Object, key: string) -> string {
	if v, ok := o[key]; ok {
		#partial switch x in v {
		case json.String:
			return string(x)
		case json.Integer:
			return fmt.tprintf("%d", x)
		case json.Float:
			return fmt.tprintf("%v", x)
		case json.Boolean:
			return x ? "true" : "false"
		}
	}
	return ""
}

jint :: proc(o: json.Object, key: string) -> i64 {
	if v, ok := o[key]; ok {
		#partial switch x in v {
		case json.Integer:
			return x
		case json.Float:
			return i64(x)
		case json.String:
			n, _ := strconv.parse_i64(string(x))
			return n
		}
	}
	return 0
}

jbool :: proc(o: json.Object, key: string) -> bool {
	if v, ok := o[key]; ok {
		if b, isb := v.(json.Boolean); isb {
			return bool(b)
		}
	}
	return false
}

jnull :: proc(o: json.Object, key: string) -> bool {
	v, ok := o[key]
	if !ok {
		return true
	}
	_, isnull := v.(json.Null)
	return isnull
}

jstrs :: proc(o: json.Object, key: string) -> []string {
	out := make([dynamic]string, 0, 4)
	if v, ok := o[key]; ok {
		if arr, isarr := v.(json.Array); isarr {
			for x in arr {
				if s, iss := x.(json.String); iss {
					append(&out, string(s))
				}
			}
		}
	}
	return out[:]
}

rows :: proc(v: json.Value) -> []json.Object {
	out := make([dynamic]json.Object, 0, 8)
	if arr, ok := v.(json.Array); ok {
		for x in arr {
			if o, iso := x.(json.Object); iso {
				append(&out, o)
			}
		}
	}
	return out[:]
}

// Builder for a JSON object body.
JB :: struct {
	sb:    strings.Builder,
	first: bool,
}

jb_make :: proc() -> JB {
	b := JB{sb = strings.builder_make(), first = true}
	strings.write_byte(&b.sb, '{')
	return b
}

@(private = "file")
jb_key :: proc(b: ^JB, key: string) {
	if !b.first {
		strings.write_byte(&b.sb, ',')
	}
	b.first = false
	web.json_string(&b.sb, key)
	strings.write_byte(&b.sb, ':')
}

jb_str :: proc(b: ^JB, key, v: string) {
	jb_key(b, key)
	web.json_string(&b.sb, v)
}

jb_null :: proc(b: ^JB, key: string) {
	jb_key(b, key)
	strings.write_string(&b.sb, "null")
}

jb_opt :: proc(b: ^JB, key, v: string) {
	if v == "" {
		jb_null(b, key)
	} else {
		jb_str(b, key, v)
	}
}

jb_raw :: proc(b: ^JB, key, raw: string) {
	jb_key(b, key)
	strings.write_string(&b.sb, raw)
}

jb_bool :: proc(b: ^JB, key: string, v: bool) {
	jb_raw(b, key, v ? "true" : "false")
}

jb_int :: proc(b: ^JB, key: string, v: i64) {
	jb_key(b, key)
	strings.write_i64(&b.sb, v)
}

jb_strs :: proc(b: ^JB, key: string, vs: []string) {
	jb_key(b, key)
	strings.write_byte(&b.sb, '[')
	for v, i in vs {
		if i > 0 {
			strings.write_byte(&b.sb, ',')
		}
		web.json_string(&b.sb, v)
	}
	strings.write_byte(&b.sb, ']')
}

jb_done :: proc(b: ^JB) -> string {
	strings.write_byte(&b.sb, '}')
	return strings.to_string(b.sb)
}

// pg_list is a PostgREST in.(...) list, each value quoted.
pg_list :: proc(vals: []string) -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, "(")
	for v, i in vals {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_byte(&sb, '"')
		for ch in transmute([]u8)v {
			if ch == '"' || ch == '\\' {
				strings.write_byte(&sb, '\\')
			}
			strings.write_byte(&sb, ch)
		}
		strings.write_byte(&sb, '"')
	}
	strings.write_string(&sb, ")")
	return web.query_encode(strings.to_string(sb))
}
