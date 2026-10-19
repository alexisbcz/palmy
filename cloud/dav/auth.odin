// Who is asking: a bearer token from GoTrue, or Basic with an app password.
package main

import "core:encoding/json"
import "core:strings"
import web "web"

REALM :: `Basic realm="Palmframe calendars and contacts", charset="UTF-8"`

// authenticate fills c.token, c.user, c.scoped and c.idents, or answers 401.
authenticate :: proc(c: ^Ctx) -> bool {
	authz := web.header(c.req.headers, "Authorization")
	if tok, ok := web.bearer(authz); ok {
		claims, err := web.jwt_verify(tok, cfg.jwt_secret)
		if err != "" {
			return refuse(c, err)
		}
		c.token = tok
		c.user = claim(claims, "sub")
		c.scoped = claim(claims, "palm_identity")
		if c.user == "" || claim(claims, "role") != "authenticated" {
			return refuse(c, "the token is not a signed-in user's")
		}
	} else if user, pass, ok := web.basic_auth(authz); ok {
		b := jb_make()
		jb_str(&b, "username", user)
		jb_str(&b, "secret", strings.trim_space(pass))
		v, e := rpc(c, "dav_app_password_check", jb_done(&b), service = true)
		if e.status == 0 {
			c.res.status = 503
			c.res.body = "the database is not reachable"
			return false
		}
		rs := rows(v)
		if !db_ok(e) || len(rs) == 0 {
			return refuse(c, "unknown identity or app password")
		}
		c.user = jstr(rs[0], "owner")
		c.scoped = jstr(rs[0], "identity_id")
		c.app_pw = true
		// Five minutes is plenty for one request; the password is checked
		// again on the next, which is what makes revocation immediate.
		c.token = web.mint_jwt(cfg.jwt_secret, c.user, c.scoped, 300, `"dav_app_password":true`)
	} else {
		return refuse(c, "sign in with an identity handle and an app password")
	}

	// The identities this session may act as. RLS answers: an unscoped
	// session sees the person's identities, a scoped one sees one.
	v, e := rest(c, "GET", "/identities?select=id,handle,display_name,color,kind&archived_at=is.null&order=created_at")
	if !db_ok(e) {
		if e.status == 401 || e.status == 403 {
			return refuse(c, "the session was refused")
		}
		c.res.status = 503
		c.res.body = "the database is not reachable"
		return false
	}
	list := make([dynamic]Ident, 0, 4)
	for r in rows(v) {
		append(&list, Ident {
			id = jstr(r, "id"),
			handle = jstr(r, "handle"),
			display_name = jstr(r, "display_name"),
			color = jstr(r, "color"),
			kind = jstr(r, "kind"),
		})
	}
	c.idents = list[:]
	if len(c.idents) == 0 {
		return refuse(c, "this account has no identity")
	}
	return true
}

@(private = "file")
claim :: proc(o: json.Object, key: string) -> string {
	if v, ok := o[key].(json.String); ok {
		return string(v)
	}
	return ""
}

@(private = "file")
refuse :: proc(c: ^Ctx, why: string) -> bool {
	c.res.status = 401
	web.set_header(c.res, "WWW-Authenticate", REALM)
	web.set_header(c.res, "Content-Type", "text/plain; charset=utf-8")
	c.res.body = strings.concatenate({why, "\n"})
	return false
}

ident_by_handle :: proc(c: ^Ctx, handle: string) -> ^Ident {
	for &i in c.idents {
		if i.handle == handle {
			return &i
		}
	}
	return nil
}

ident_by_id :: proc(c: ^Ctx, id: string) -> ^Ident {
	for &i in c.idents {
		if i.id == id {
			return &i
		}
	}
	return nil
}

// primary is the identity a client sees as "me": the scoped one, else the
// first personal identity, else the first.
primary :: proc(c: ^Ctx) -> ^Ident {
	if c.scoped != "" {
		if i := ident_by_id(c, c.scoped); i != nil {
			return i
		}
	}
	for &i in c.idents {
		if i.kind == "personal" {
			return &i
		}
	}
	return &c.idents[0]
}

address_of :: proc(i: ^Ident) -> string {
	return strings.concatenate({"mailto:", i.handle, "@", mail_domain()})
}

@(private = "file")
g_domain: string

mail_domain :: proc() -> string {
	if g_domain != "" {
		return g_domain
	}
	return "palm.test"
}

// load_mail_domain asks the database once (dav_mail_domain reads mail's
// default domain).
load_mail_domain :: proc(c: ^Ctx) {
	if g_domain != "" {
		return
	}
	v, e := rpc(c, "dav_mail_domain", "{}")
	if db_ok(e) {
		if s, ok := v.(json.String); ok && s != "" {
			g_domain = strings.clone(string(s), heap())
		}
	}
}
