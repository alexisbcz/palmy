package main

// Cloud mode: the same client speaking protocol v2 to palm-rtc
// (cloud/rtc), signed in with the Palmframe account and speaking as one
// identity.
//
//	PALM_IDENTITY=alice.northwind chat --cloud
//	chat --cloud --identity alice.northwind
//
// What changes from the loopback server is small on purpose, because v2 was
// designed so that it would be: a channel's key on the wire is its id (a
// uuid) instead of its name, and it carries a `label` to draw; a nickname is
// an identity's handle, and a message carries the author's name and colour.
// Threads, reactions, read cursors, attachments, typing and search are the
// same frames. What is new is here: which identity the window speaks as,
// spaces, invites, reconnect sync, read receipts and calls.
//
// The token comes from cloudkit's store (apps/accounts signs a machine in).
// With PALM_IDENTITY set, only the session scoped to that identity is used —
// cloudkit has no fallback, so a process started inside a scope cannot widen
// it. With only --identity, the person's own session is used and the gateway
// narrows it to that identity; it can never widen it.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."
import w "wire"

Ident_View :: struct {
	id, handle, name, color, kind: string,
}

Space :: struct {
	id, name, role, owner: string,
	members:               int,
}

Invite :: struct {
	id, space, space_name, ch, ch_name, role: string,
	from_name, from_handle, from_color:       string,
}

Who :: struct {
	nick, name, color: string,
}

Seen :: struct {
	nick: string,
	id:   i64,
}

Prompt_Kind :: enum u8 {
	None,
	Invite,
	New_Channel,
}

DEFAULT_RTC_PORT :: 8790

// cloud_token returns a fresh access token for this window's scope. A
// failure is said plainly in the footer; nothing falls back to another
// identity's session.
cloud_token :: proc(a: ^App) -> (token: string, ok: bool) {
	if a.ck == nil {
		scope := os.get_env("PALM_IDENTITY", context.temp_allocator)
		c, e := ck.open(scope = scope, app = "chat")
		if !ck.ok(e) {
			a.err_text = fmt.aprintf("cloud: %s", e.message)
			return "", false
		}
		if !ck.signed_in(c) && scope == "" {
			a.err_text = "not signed in — run `accounts signin` first"
			return "", false
		}
		a.ck = c
	}
	if !ck.signed_in(a.ck) {
		a.err_text = fmt.aprintf("no session for %s on this machine — run `accounts switch %s`", a.ck.scope, a.ck.scope)
		return "", false
	}
	if e := ck.ensure_fresh(a.ck); !ck.ok(e) {
		a.err_text = fmt.aprintf("cloud: %s", e.message)
		return "", false
	}
	return a.ck.session.access_token, true
}

cloud_hello :: proc(a: ^App) {
	token, ok := cloud_token(a)
	if !ok {
		net_drop(a, a.err_text)
		return
	}
	e: w.Enc
	w.enc_begin(&e, "hello")
	w.kv_str(&e, "token", token)
	if a.args.identity != "" {
		w.kv_str(&e, "identity", a.args.identity)
	}
	w.kv_str(&e, "presence", a.away ? "away" : "online")
	net_send(a, w.enc_done(&e))
	a.token_exp = a.ck.session.expires_at
}

// cloud_tick keeps the token ahead of its expiry, once a second at most.
cloud_tick :: proc(a: ^App) {
	if !a.cloud || a.link != .Online || a.ck == nil {
		return
	}
	if a.now < a.next_auth_check {
		return
	}
	a.next_auth_check = a.now + 1
	if a.token_exp - time.time_to_unix(time.now()) > 120 {
		return
	}
	token, ok := cloud_token(a)
	if !ok {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "auth")
	w.kv_str(&e, "token", token)
	net_send(a, w.enc_done(&e))
	a.token_exp = a.ck.session.expires_at
}

// cloud_resync asks, for every channel this client had loaded, for exactly
// the changes after the newest rev it saw: new messages, edits, deletions,
// reactions and reply counts, once each, in the order they were committed.
cloud_resync :: proc(a: ^App) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n := 0
	for &c in a.chans {
		if !c.loaded {
			continue
		}
		if n > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"ch":`)
		w.write_json_string(&b, c.name)
		strings.write_string(&b, fmt.tprint(`,"rev":`, c.rev, "}", sep = ""))
		n += 1
	}
	strings.write_byte(&b, ']')
	if n == 0 {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "sync")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_raw(&e, "chs", strings.to_string(b))
	net_send(a, w.enc_done(&e))
	a.syncing = true
}

note_rev :: proc(a: ^App, ch: string, rev: i64) {
	if i := find_chan(a, ch); i >= 0 && rev > a.chans[i].rev {
		a.chans[i].rev = rev
	}
}

// in_view says whether a channel belongs to the space on screen.
in_view :: proc(a: ^App, i: int) -> bool {
	if !a.cloud {
		return true
	}
	return i >= 0 && i < len(a.chans) && a.chans[i].space == a.cur_space
}

space_of :: proc(a: ^App, id: string) -> ^Space {
	for &s in a.spaces {
		if s.id == id {
			return &s
		}
	}
	return nil
}

switch_space :: proc(a: ^App, n: int) {
	if n < 0 || n >= len(a.spaces) {
		return
	}
	a.cur_space = strings.clone(a.spaces[n].id)
	for c, i in a.chans {
		if c.space == a.cur_space {
			a.cur = -1
			switch_to(a, i)
			return
		}
	}
	a.cur = -1
}

// apply_cloud handles the v2-only frames. Returns false for anything it does
// not know, so `apply` can carry on with the shared ones.
apply_cloud :: proc(a: ^App, o: json.Object) -> bool {
	switch w.ostr(o, "t") {
	case "welcome":
		a.err_text = ""
		if io, ok := w.as_obj(o["identity"] or_else nil); ok {
			a.me = Ident_View {
				id     = strings.clone(w.ostr(io, "id")),
				handle = strings.clone(w.ostr(io, "handle")),
				name   = strings.clone(w.ostr(io, "name")),
				color  = strings.clone(w.ostr(io, "color")),
				kind   = strings.clone(w.ostr(io, "kind")),
			}
			a.nick = a.me.handle
		}
		// Whatever was loaded before the link dropped is brought up to date
		// by rev rather than thrown away and fetched again.
		if a.was_online {
			cloud_resync(a)
		}
		a.was_online = true
		return true

	case "spaces":
		clear(&a.spaces)
		for v in w.oarr(o, "list") {
			so, ok := w.as_obj(v)
			if !ok {
				continue
			}
			append(&a.spaces, Space {
				id = strings.clone(w.ostr(so, "id")),
				name = strings.clone(w.ostr(so, "name")),
				role = strings.clone(w.ostr(so, "role")),
				owner = strings.clone(w.ostr(so, "owner")),
				members = int(w.oint(so, "members")),
			})
		}
		if space_of(a, a.cur_space) == nil {
			a.cur_space = len(a.spaces) > 0 ? strings.clone(a.spaces[0].id) : ""
		}
		return true

	case "invites":
		clear(&a.invites)
		for v in w.oarr(o, "list") {
			io, ok := w.as_obj(v)
			if !ok {
				continue
			}
			from, _ := w.as_obj(io["from"] or_else nil)
			append(&a.invites, Invite {
				id = strings.clone(w.ostr(io, "id")),
				space = strings.clone(w.ostr(io, "space")),
				space_name = strings.clone(w.ostr(io, "space_name")),
				ch = strings.clone(w.ostr(io, "ch")),
				ch_name = strings.clone(w.ostr(io, "ch_name")),
				role = strings.clone(w.ostr(io, "role")),
				from_name = strings.clone(w.ostr(from, "name")),
				from_handle = strings.clone(w.ostr(from, "handle")),
				from_color = strings.clone(w.ostr(from, "color")),
			})
		}
		a.sel_invite = clamp(a.sel_invite, 0, max(0, len(a.invites) - 1))
		if len(a.invites) > 0 && a.seen_invites < len(a.invites) {
			toast(a, fmt.tprintf("%s invited you to %s — F6", a.invites[len(a.invites) - 1].from_name, a.invites[len(a.invites) - 1].space_name))
		}
		a.seen_invites = len(a.invites)
		return true

	case "changes":
		ch := w.ostr(o, "ch")
		for v in w.oarr(o, "msgs") {
			mo, ok := w.as_obj(v)
			if !ok {
				continue
			}
			upsert_message(a, w.msg_from(mo, context.allocator))
		}
		note_rev(a, ch, w.oint(o, "rev"))
		return true

	case "synced":
		a.syncing = false
		if c := current(a); c != nil && a.pinned {
			mark_read(a)
		}
		return true

	case "resync":
		cloud_resync(a)
		return true

	case "removed":
		ch := w.ostr(o, "ch")
		if i := find_chan(a, ch); i >= 0 {
			toast(a, fmt.tprintf("You no longer have access to %s", chan_label(a, &a.chans[i])))
		}
		return true

	case "receipt":
		ch := w.ostr(o, "ch")
		if i := find_chan(a, ch); i >= 0 {
			c := &a.chans[i]
			nick := w.ostr(o, "nick")
			id := w.oint(o, "id")
			for &s in c.seen {
				if s.nick == nick {
					s.id = max(s.id, id)
					return true
				}
			}
			append(&c.seen, Seen{nick = strings.clone(nick), id = id})
		}
		return true

	case "call":
		ch := w.ostr(o, "ch")
		i := find_chan(a, ch)
		if i < 0 {
			return true
		}
		c := &a.chans[i]
		clear(&c.call_who)
		if w.ostr(o, "state") == "active" {
			c.call = strings.clone(w.ostr(o, "call"))
			for v in w.oarr(o, "who") {
				wo, ok := w.as_obj(v)
				if ok {
					append(&c.call_who, Who {
						nick = strings.clone(w.ostr(wo, "nick")),
						name = strings.clone(w.ostr(wo, "name")),
						color = strings.clone(w.ostr(wo, "color")),
					})
				}
			}
		} else {
			c.call = ""
		}
		return true

	case "call_token":
		launch_call(a, w.ostr(o, "sfu"), w.ostr(o, "token"))
		return true

	case "speaker":
		return true

	case "space", "invited", "accepted", "declined", "parted", "left_space", "removed_member", "authed", "posted", "call_left":
		switch w.ostr(o, "t") {
		case "invited":
			toast(a, "Invite sent")
		case "accepted":
			a.cur_space = strings.clone(w.ostr(o, "space"))
			toast(a, "Joined")
		case "space":
			a.cur_space = strings.clone(w.ostr(o, "id"))
		}
		return true

	case "joined":
		// The answer to `dm` and `create_channel`: open what was asked for.
		ch := w.ostr(o, "ch")
		if i := find_chan(a, ch); i >= 0 {
			switch_to(a, i)
		} else {
			a.pending_dm = strings.clone(ch, context.allocator)
		}
		return true
	}
	return false
}

// upsert_message files a message from a sync: new ones are inserted, ones
// already held are replaced by the server's current state.
upsert_message :: proc(a: ^App, m: w.Msg) {
	mm := m
	if old := locate(a, mm.ch, mm.id); old != nil {
		w.msg_destroy(old)
		old^ = mm
		return
	}
	take_message(a, mm)
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

start_call :: proc(a: ^App) {
	c := current(a)
	if c == nil || !a.cloud {
		toast(a, "Calls need the cloud: start chat with --cloud")
		return
	}
	e: w.Enc
	w.enc_begin(&e, "call_join")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_str(&e, "ch", c.name)
	net_send(a, w.enc_done(&e))
}

// launch_call starts the call app on the SFU with the token the gateway
// minted for this identity and this call. The call app needs nothing else:
// no database, no chat connection.
launch_call :: proc(a: ^App, sfu, token: string) {
	bin := a.args.call_bin
	if bin == "" {
		bin = "call"
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, bin, "--sfu", sfu, "--join-token", token, "--name", a.me.name)
	if !a.args.dark {
		append(&argv, "--light")
	}
	kit.launch(argv[:])
	toast(a, "Joining the call…")
}

accept_invite :: proc(a: ^App, accept: bool) {
	if a.sel_invite < 0 || a.sel_invite >= len(a.invites) {
		return
	}
	e: w.Enc
	w.enc_begin(&e, accept ? "accept" : "decline")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_str(&e, "id", a.invites[a.sel_invite].id)
	net_send(a, w.enc_done(&e))
	if len(a.invites) <= 1 {
		a.inv_open = false
	}
}

submit_prompt :: proc(a: ^App) {
	text := strings.trim_space(string(a.pbuf[:]))
	if text == "" {
		a.prompt = .None
		return
	}
	switch a.prompt {
	case .Invite:
		e: w.Enc
		w.enc_begin(&e, "invite")
		w.kv_int(&e, "rq", next_rq(a))
		w.kv_str(&e, "space", a.cur_space)
		if c := current(a); c != nil && c.private {
			w.kv_str(&e, "ch", c.name)
		}
		w.kv_str(&e, "handle", strings.trim_left(text, "@"))
		net_send(a, w.enc_done(&e))
	case .New_Channel:
		e: w.Enc
		w.enc_begin(&e, "create_channel")
		w.kv_int(&e, "rq", next_rq(a))
		w.kv_str(&e, "space", a.cur_space)
		priv := strings.has_suffix(text, " private")
		name := priv ? strings.trim_space(text[:len(text) - len(" private")]) : text
		w.kv_str(&e, "name", strings.trim_left(name, "#"))
		w.kv_bool(&e, "private", priv)
		net_send(a, w.enc_done(&e))
	case .None:
	}
	a.prompt = .None
	clear(&a.pbuf)
	a.pcaret = 0
}

open_dm_cloud :: proc(a: ^App, handle: string) {
	for c, i in a.chans {
		if c.kind == .DM && c.peer == handle && c.space == a.cur_space {
			switch_to(a, i)
			a.mode = .Compose
			return
		}
	}
	e: w.Enc
	w.enc_begin(&e, "dm")
	w.kv_int(&e, "rq", next_rq(a))
	w.kv_str(&e, "with", handle)
	if a.cur_space != "" {
		w.kv_str(&e, "space", a.cur_space)
	}
	net_send(a, w.enc_done(&e))
	a.mode = .Compose
}

// tint is the Tailwind colour class for an identity colour name, at a shade
// that reads on both themes. Unknown names fall back to the neutral primary.
tint :: proc(color: string, part := "bg", shade := "500") -> string {
	switch color {
	case "slate", "gray", "zinc", "neutral", "stone", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose":
		return fmt.tprintf("%s-%s-%s", part, color, shade)
	}
	return part == "bg" ? "bg-primary" : fmt.tprintf("%s-primary", part)
}

next_in_view :: proc(a: ^App, from, d: int) -> int {
	i := from
	for {
		i += d
		if i < 0 || i >= len(a.chans) {
			return from
		}
		if in_view(a, i) {
			return i
		}
	}
}

keys_prompt :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.prompt = .None
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		submit_prompt(a)
		return
	}
	edit_buffer(ui, a, &a.pbuf, &a.pcaret, false)
}

keys_invites :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.inv_open = false
		return
	}
	if p.key_pressed(ui, p.KEY_UP) {
		a.sel_invite = max(0, a.sel_invite - 1)
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		a.sel_invite = min(len(a.invites) - 1, a.sel_invite + 1)
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		accept_invite(a, true)
	}
	if p.key_pressed(ui, p.KEY_DELETE) {
		accept_invite(a, false)
	}
}

// display_name is the name to draw for a handle: the identity's own display
// name when the space has told us it, the handle otherwise.
display_name :: proc(a: ^App, nick: string) -> string {
	if nick == a.nick && a.me.name != "" {
		return a.me.name
	}
	for m in a.members {
		if m.nick == nick && m.name != "" {
			return m.name
		}
	}
	return nick
}

color_of :: proc(a: ^App, nick: string) -> string {
	if nick == a.nick {
		return a.me.color
	}
	for m in a.members {
		if m.nick == nick {
			return m.color
		}
	}
	return ""
}
