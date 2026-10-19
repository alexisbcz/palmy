package main

// The command line: `chat <verb>` (or `palm chat <verb>`), against the
// Palmy cloud. Every verb opens one connection to palm-rtc, says hello as
// one identity, makes the same requests the window makes, and prints what
// came back. Same wire, same gateway, same RLS: the window and the command
// line cannot disagree about who may see what (docs/PALM-CLI.md).
//
// Scope follows the convention. PALM_IDENTITY (narrowed by --identity)
// selects the session stored for that identity and nothing else; without
// PALM_IDENTITY, the person's own session is used and the gateway narrows it
// to --identity. A refusal for scope exits 5.
//
// The gateway is 127.0.0.1:$PALM_RTC_PORT (default 8790).

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ck "../cloudkit"
import kit "kit:."
import w "wire"

@(private = "file")
MSG_FIELDS :: []kit.Field {
	{name = "id", kind = .Int},
	{name = "ch", kind = .String},
	{name = "nick", kind = .String, help = "the author's handle"},
	{name = "text", kind = .String},
	{name = "ts", kind = .Int},
	{name = "seq", kind = .Int},
	{name = "rev", kind = .Int},
	{name = "ident", kind = .Object, help = "{id, handle, name, color}"},
	{name = "thread", kind = .Int, opt = true},
	{name = "replies", kind = .Int, opt = true},
	{name = "reacts", kind = .Array, opt = true},
	{name = "file", kind = .Object, opt = true},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "whoami",
		summary = "the identity this command speaks as, as the gateway sees it",
		effect = .Read,
		out = {{name = "identity", kind = .Object}, {name = "spaces", kind = .Int}, {name = "channels", kind = .Int}},
		examples = {"PALM_IDENTITY=alice.northwind chat whoami --json"},
		run = cmd_whoami,
	},
	{
		verb = "spaces",
		summary = "the spaces this identity is a member of",
		effect = .Read,
		out = {{name = "spaces", kind = .Array}},
		examples = {"chat spaces --identity alice.northwind --json"},
		run = cmd_spaces,
	},
	{
		verb = "channels",
		summary = "the channels and DMs this identity can read",
		effect = .Read,
		flags = {{name = "space", kind = .String, help = "only this space (name or id)"}},
		out = {{name = "channels", kind = .Array}},
		examples = {"chat channels --space Northwind --json"},
		run = cmd_channels,
	},
	{
		verb = "history",
		summary = "the newest messages of a channel, oldest first",
		effect = .Read,
		args = {{name = "channel", kind = .String, required = true, help = "#name, @handle for a DM, or an id"}},
		flags = {{name = "limit", kind = .Int, def = "20"}, {name = "space", kind = .String}},
		out = {{name = "messages", kind = .Array, of = MSG_FIELDS}, {name = "more", kind = .Bool}},
		examples = {"chat history '#general' --limit 5 --json"},
		run = cmd_history,
	},
	{
		verb = "post",
		summary = "post a message, or a reply inside a thread",
		effect = .Mutate,
		args = {{name = "channel", kind = .String, required = true}, {name = "text", kind = .String, required = true, variadic = true}},
		flags = {{name = "thread", kind = .Int, help = "the root message id"}, {name = "space", kind = .String}},
		out = {{name = "message", kind = .Object, of = MSG_FIELDS}},
		examples = {"chat post '#general' 'the deploy is on friday' --json", "chat post '#general' 'yes' --thread 41"},
		run = cmd_post,
	},
	{
		verb = "edit",
		summary = "change the text of one of this identity's messages",
		effect = .Idempotent,
		args = {{name = "id", kind = .Int, required = true}, {name = "text", kind = .String, required = true, variadic = true}},
		out = {{name = "id", kind = .Int}},
		examples = {"chat edit 41 'the deploy is on monday'"},
		run = cmd_edit,
	},
	{
		verb = "react",
		summary = "add (or with --off remove) a reaction",
		effect = .Idempotent,
		args = {
			{name = "id", kind = .Int, required = true},
			{name = "key", kind = .Enum, required = true, values = {"thumbsup", "heart", "party", "rocket", "fire", "grin", "eyes", "check"}},
		},
		flags = {{name = "off", kind = .Bool}},
		out = {{name = "id", kind = .Int}, {name = "key", kind = .String}, {name = "on", kind = .Bool}},
		examples = {"chat react 41 heart"},
		run = cmd_react,
	},
	{
		verb = "thread",
		summary = "a thread: its root and its replies",
		effect = .Read,
		args = {{name = "id", kind = .Int, required = true}},
		out = {{name = "root", kind = .Object}, {name = "replies", kind = .Array}, {name = "count", kind = .Int}},
		examples = {"chat thread 41 --json"},
		run = cmd_thread,
	},
	{
		verb = "search",
		summary = "full-text search over everything this identity can read",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true, variadic = true}},
		out = {{name = "messages", kind = .Array, of = MSG_FIELDS}},
		examples = {"chat search deploy --json"},
		run = cmd_search,
	},
	{
		verb = "sync",
		summary = "what changed in a channel after a rev: new, edited, deleted, reacted, replied",
		effect = .Read,
		args = {{name = "channel", kind = .String, required = true}},
		flags = {{name = "since", kind = .Int, def = "0"}, {name = "space", kind = .String}},
		out = {{name = "messages", kind = .Array, of = MSG_FIELDS}, {name = "rev", kind = .Int}},
		examples = {"chat sync '#general' --since 12 --json"},
		run = cmd_sync,
	},
	{
		verb = "create-space",
		summary = "make a space owned by this identity, with a #general",
		effect = .Mutate,
		args = {{name = "name", kind = .String, required = true}},
		out = {{name = "space", kind = .String}},
		examples = {"chat create-space Northwind --json"},
		run = cmd_create_space,
	},
	{
		verb = "create-channel",
		summary = "make a channel in a space",
		effect = .Mutate,
		args = {{name = "space", kind = .String, required = true}, {name = "name", kind = .String, required = true}},
		flags = {{name = "private", kind = .Bool}, {name = "topic", kind = .String}},
		out = {{name = "channel", kind = .String}},
		examples = {"chat create-channel Northwind design --private"},
		run = cmd_create_channel,
	},
	{
		verb = "invite",
		summary = "invite an identity, by handle, to a space or to one of its channels",
		effect = .Mutate,
		args = {{name = "space", kind = .String, required = true}, {name = "handle", kind = .String, required = true}},
		flags = {
			{name = "channel", kind = .String, help = "invite to this channel only (as a guest unless --role)"},
			{name = "role", kind = .Enum, values = {"admin", "member", "guest"}},
			{name = "note", kind = .String},
		},
		out = {{name = "invite", kind = .String}},
		examples = {"chat invite Northwind bob.northwind", "chat invite Northwind carol --channel '#design'"},
		run = cmd_invite,
	},
	{
		verb = "invites",
		summary = "invitations waiting for this identity",
		effect = .Read,
		out = {{name = "invites", kind = .Array}},
		examples = {"chat invites --json"},
		run = cmd_invites,
	},
	{
		verb = "accept",
		summary = "accept an invitation; it grants exactly what it names",
		effect = .Mutate,
		args = {{name = "invite", kind = .String, required = true, help = "an invite id, or the space's name"}},
		out = {{name = "space", kind = .String}},
		examples = {"chat accept Northwind"},
		run = cmd_accept,
	},
	{
		verb = "dm",
		summary = "open (or find) a direct message with someone who shares a space",
		effect = .Idempotent,
		args = {{name = "handle", kind = .String, required = true}},
		flags = {{name = "space", kind = .String}},
		out = {{name = "channel", kind = .String}},
		examples = {"chat dm bob.northwind"},
		run = cmd_dm,
	},
	{
		verb = "members",
		summary = "the members of a space, with roles and presence",
		effect = .Read,
		args = {{name = "space", kind = .String, required = true}},
		out = {{name = "members", kind = .Array}},
		examples = {"chat members Northwind --json"},
		run = cmd_members,
	},
	{
		verb = "remove",
		summary = "remove a member from a space (owner or admin)",
		effect = .Destructive,
		args = {{name = "space", kind = .String, required = true}, {name = "handle", kind = .String, required = true}},
		out = {{name = "removed", kind = .String}},
		examples = {"chat remove Northwind carol --yes"},
		run = cmd_remove,
	},
	{
		verb = "leave",
		summary = "leave a space; its channels and calls go with it",
		effect = .Destructive,
		args = {{name = "space", kind = .String, required = true}},
		out = {{name = "left", kind = .String}},
		examples = {"chat leave Northwind --yes"},
		run = cmd_leave,
	},
	{
		verb = "call",
		summary = "join (or start) the call in a channel: the SFU address and a 60 s join token",
		effect = .Mutate,
		args = {{name = "channel", kind = .String, required = true}},
		flags = {{name = "space", kind = .String}, {name = "launch", kind = .Bool, help = "start the call app with it"}},
		out = {{name = "call", kind = .String}, {name = "sfu", kind = .String}, {name = "token", kind = .String}, {name = "exp", kind = .Int}},
		examples = {"chat call '#general' --json", "chat call '#general' --launch"},
		run = cmd_call,
	},
	{
		verb = "watch",
		summary = "print messages as they arrive in the channels this identity can read",
		effect = .Read,
		flags = {{name = "seconds", kind = .Int, def = "10"}},
		out = {{name = "messages", kind = .Array, of = MSG_FIELDS}},
		examples = {"chat watch --seconds 30 --json"},
		run = cmd_watch,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "chat",
			summary  = "team chat in the Palmy cloud: spaces, channels, threads, calls",
			gui      = true,
			commands = COMMANDS,
			notes    = "The window is `chat --cloud` (or `chat --nick N` for the loopback server). Commands talk to palm-rtc on 127.0.0.1:$PALM_RTC_PORT (8790).",
		}
	}
	return &g_surface
}

is_cli_invocation :: proc(first: string) -> bool {
	switch first {
	case "help", "--schema":
		return true
	}
	for c in COMMANDS {
		if c.verb == first {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// One connection
// ---------------------------------------------------------------------------

Sess :: struct {
	sock:     net.TCP_Socket,
	rd:       w.Reader,
	pending:  [dynamic]json.Object,
	rq:       i64,
	welcome:  json.Object,
	channels: json.Array,
	spaces:   json.Array,
	invites:  json.Array,
}

@(private = "file")
open_sess :: proc(c: ^kit.Call) -> (s: ^Sess, code: int) {
	env := os.get_env("PALM_IDENTITY", context.temp_allocator)
	cl, e := ck.open(scope = env, app = "chat")
	if !ck.ok(e) || !ck.signed_in(cl) {
		if env != "" {
			return nil, kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "no session scoped to %s on this machine (accounts switch %s)", env, env)
		}
		return nil, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "not signed in (accounts signin)")
	}
	if fe := ck.ensure_fresh(cl); !ck.ok(fe) {
		return nil, kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "cloud: %s", fe.message)
	}
	port := DEFAULT_RTC_PORT
	if v := os.get_env("PALM_RTC_PORT", context.temp_allocator); v != "" {
		port, _ = strconv.parse_int(v)
	}
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if derr != nil {
		return nil, kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "palm-rtc is not running on 127.0.0.1:%d", port)
	}
	_ = net.set_option(sock, .Receive_Timeout, 100 * time.Millisecond)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	s = new(Sess)
	s.sock = sock
	e2 := sreq(s, "hello")
	w.kv_str(&e2, "token", cl.session.access_token)
	w.kv_str(&e2, "presence", "none") // a command is not the person arriving
	if c.identity != "" {
		w.kv_str(&e2, "identity", c.identity)
	}
	ssend(s, &e2)
	o, ok := swait(s, "welcome", 5000)
	if !ok {
		if err, has := swait(s, "error", 1); has {
			return nil, refused(c, err)
		}
		return nil, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no answer from palm-rtc")
	}
	s.welcome = o
	if x, okc := swait(s, "channels", 3000); okc {
		s.channels = w.oarr(x, "list")
	}
	if x, oks := swait(s, "spaces", 0); oks {
		s.spaces = w.oarr(x, "list")
	}
	if x, oki := swait(s, "invites", 3000); oki {
		s.invites = w.oarr(x, "list")
	}
	return s, kit.EXIT_OK
}

@(private = "file")
refused :: proc(c: ^kit.Call, err: json.Object) -> int {
	code := w.ostr(err, "code")
	detail := fmt.tprintf("%s: %s", code, w.ostr(err, "msg"))
	switch code {
	case "out_of_scope", "forbidden", "no_identity":
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, detail)
	case "no_channel", "not_found", "no_message", "no_file":
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, detail)
	case "unavailable":
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, detail)
	case "identity_required":
		return kit.cli_failf(c, kit.EXIT_USAGE, "say which identity with --identity (or PALM_IDENTITY): %s", w.ostr(err, "msg"))
	}
	return kit.cli_fail(c, kit.EXIT_FAILED, detail)
}

@(private = "file")
sreq :: proc(s: ^Sess, t: string) -> w.Enc {
	e: w.Enc
	w.enc_begin(&e, t, context.allocator)
	s.rq += 1
	w.kv_int(&e, "rq", s.rq)
	return e
}

@(private = "file")
ssend :: proc(s: ^Sess, e: ^w.Enc) {
	w.send_frame(s.sock, w.enc_done(e))
}

@(private = "file")
spump :: proc(s: ^Sess) {
	buf: [64 * 1024]u8
	n, err := net.recv_tcp(s.sock, buf[:])
	if err != nil || n == 0 {
		return
	}
	w.reader_feed(&s.rd, buf[:n])
	for {
		payload, ok := w.reader_next(&s.rd, context.allocator)
		if !ok {
			break
		}
		if o, good := w.parse_obj(payload, context.allocator); good {
			append(&s.pending, o)
		}
	}
}

// swait returns the first pending frame of type `t`. An `error` answering
// the newest request ends the wait, so a refusal is reported, not timed out.
@(private = "file")
swait :: proc(s: ^Sess, t: string, ms: int) -> (json.Object, bool) {
	start := time.tick_now()
	for {
		for o, i in s.pending {
			ty := w.ostr(o, "t")
			if ty == t {
				ordered_remove(&s.pending, i)
				return o, true
			}
			if ty == "error" && t != "error" && w.oint(o, "rq") == s.rq {
				return nil, false
			}
		}
		if time.duration_milliseconds(time.tick_since(start)) >= f64(ms) {
			return nil, false
		}
		spump(s)
	}
}

// answer waits for `t`, or turns the error that came instead into the exit.
@(private = "file")
answer :: proc(c: ^kit.Call, s: ^Sess, t: string, ms := 8000) -> (json.Object, int) {
	if o, ok := swait(s, t, ms); ok {
		return o, kit.EXIT_OK
	}
	if err, has := swait(s, "error", 1); has {
		return nil, refused(c, err)
	}
	return nil, kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "no %s from palm-rtc", t)
}

// find_space resolves a space by id or by name.
@(private = "file")
find_space :: proc(s: ^Sess, key: string) -> string {
	for v in s.spaces {
		so, _ := w.as_obj(v)
		if w.ostr(so, "id") == key || strings.equal_fold(w.ostr(so, "name"), key) {
			return w.ostr(so, "id")
		}
	}
	return ""
}

// find_channel resolves "#name", "name", "@handle" (a DM) or an id. With
// several spaces, --space disambiguates; otherwise the first match wins.
@(private = "file")
find_channel :: proc(c: ^kit.Call, s: ^Sess, key: string) -> string {
	space := kit.cli_has(c, "space") ? find_space(s, kit.cli_str(c, "space")) : ""
	want := strings.trim_left(key, "#")
	dm := strings.has_prefix(key, "@")
	for v in s.channels {
		co, _ := w.as_obj(v)
		if space != "" && w.ostr(co, "space") != space {
			continue
		}
		if w.ostr(co, "name") == key {
			return key
		}
		if dm && w.ostr(co, "kind") == "dm" && w.ostr(co, "peer") == key[1:] {
			return w.ostr(co, "name")
		}
		if !dm && w.ostr(co, "kind") != "dm" && strings.equal_fold(w.ostr(co, "label"), want) {
			return w.ostr(co, "name")
		}
	}
	return ""
}

@(private = "file")
need_channel :: proc(c: ^kit.Call, s: ^Sess, key: string) -> (string, int) {
	ch := find_channel(c, s, key)
	if ch == "" {
		return "", kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no channel %s visible to this identity", key)
	}
	return ch, kit.EXIT_OK
}

// to_kit turns a parsed wire value into the kit's output tree.
to_kit :: proc(v: json.Value) -> ^kit.Json {
	#partial switch x in v {
	case json.Object:
		o := kit.jobj()
		for k, val in x {
			kit.jset(o, k, to_kit(val))
		}
		return o
	case json.Array:
		a := kit.jarr()
		for val in x {
			kit.jpush(a, to_kit(val))
		}
		return a
	case json.String:
		return kit.jstr(string(x))
	case json.Integer:
		return kit.jint(int(x))
	case json.Float:
		if f64(i64(x)) == f64(x) {
			return kit.jint(int(x))
		}
		return kit.jnum(f64(x))
	case json.Boolean:
		return kit.jbool(bool(x))
	}
	return kit.jnull()
}

// The shapes the commands print. Flat objects with the same keys every
// time, so a person gets a table and an agent gets stable fields; the whole
// wire object is one `chat sync --json` away for anything not here.
flat_msgs :: proc(v: json.Value) -> ^kit.Json {
	arr := kit.jarr()
	list, _ := v.(json.Array)
	for x in list {
		mo, ok := w.as_obj(x)
		if ok {
			kit.jpush(arr, flat_one(mo))
		}
	}
	return arr
}

flat_one :: proc(mo: json.Object) -> ^kit.Json {
	{
		io, _ := w.as_obj(mo["ident"] or_else nil)
		o := kit.jobj()
		kit.jset_int(o, "id", int(w.oint(mo, "id")))
		kit.jset_int(o, "seq", int(w.oint(mo, "seq")))
		kit.jset_int(o, "rev", int(w.oint(mo, "rev")))
		kit.jset_str(o, "from", w.ostr(mo, "nick"))
		kit.jset_str(o, "name", w.ostr(io, "name"))
		kit.jset_str(o, "text", w.obool(mo, "deleted") ? "(deleted)" : w.ostr(mo, "text"))
		kit.jset_int(o, "thread", int(w.oint(mo, "thread")))
		kit.jset_int(o, "replies", int(w.oint(mo, "replies")))
		b := strings.builder_make(context.temp_allocator)
		for rv in w.oarr(mo, "reacts") {
			ro, _ := w.as_obj(rv)
			if strings.builder_len(b) > 0 {
				strings.write_string(&b, " ")
			}
			strings.write_string(&b, w.ostr(ro, "key"))
			for nv in w.oarr(ro, "nicks") {
				strings.write_string(&b, ":")
				strings.write_string(&b, w.as_str(nv))
			}
		}
		kit.jset_str(o, "reacts", strings.to_string(b))
		fo, _ := w.as_obj(mo["file"] or_else nil)
		kit.jset_str(o, "file", w.ostr(fo, "name"))
		kit.jset_bool(o, "edited", w.oint(mo, "edited") != 0)
		return o
	}
}

flat_channels :: proc(list: []json.Value) -> ^kit.Json {
	arr := kit.jarr()
	for x in list {
		co, ok := w.as_obj(x)
		if !ok {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "id", w.ostr(co, "name"))
		kind := w.ostr(co, "kind") == "dm" ? "dm" : w.obool(co, "private") ? "private" : "public"
		kit.jset_str(o, "kind", kind)
		kit.jset_str(o, "label", w.ostr(co, "label"))
		kit.jset_str(o, "space", w.ostr(co, "space"))
		kit.jset_str(o, "topic", w.ostr(co, "topic"))
		kit.jset_bool(o, "call", w.ostr(co, "call") != "")
		kit.jpush(arr, o)
	}
	return arr
}

flat_invites :: proc(list: []json.Value) -> ^kit.Json {
	arr := kit.jarr()
	for x in list {
		io, ok := w.as_obj(x)
		if !ok {
			continue
		}
		from, _ := w.as_obj(io["from"] or_else nil)
		o := kit.jobj()
		kit.jset_str(o, "id", w.ostr(io, "id"))
		kit.jset_str(o, "space", w.ostr(io, "space_name"))
		kit.jset_str(o, "channel", w.ostr(io, "ch_name"))
		kit.jset_str(o, "role", w.ostr(io, "role"))
		kit.jset_str(o, "from", w.ostr(from, "name"))
		kit.jset_str(o, "to", w.ostr(io, "to"))
		kit.jpush(arr, o)
	}
	return arr
}

// ---------------------------------------------------------------------------
// The verbs
// ---------------------------------------------------------------------------

cmd_whoami :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset(c.out, "identity", to_kit(s.welcome["identity"]))
	kit.jset_int(c.out, "spaces", len(s.spaces))
	kit.jset_int(c.out, "channels", len(s.channels))
	return kit.EXIT_OK
}

cmd_spaces :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset(c.out, "spaces", to_kit(s.spaces))
	return kit.EXIT_OK
}

cmd_channels :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := kit.cli_has(c, "space") ? find_space(s, kit.cli_str(c, "space")) : ""
	out := json.Array{}
	for v in s.channels {
		co, _ := w.as_obj(v)
		if space != "" && w.ostr(co, "space") != space {
			continue
		}
		append(&out, v)
	}
	kit.jset(c.out, "channels", flat_channels(out[:]))
	return kit.EXIT_OK
}

cmd_history :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	ch, cc := need_channel(c, s, kit.cli_str(c, "channel"))
	if cc != kit.EXIT_OK {
		return cc
	}
	e := sreq(s, "history")
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "limit", i64(kit.cli_int(c, "limit", 20)))
	ssend(s, &e)
	h, hc := answer(c, s, "history")
	if hc != kit.EXIT_OK {
		return hc
	}
	kit.jset(c.out, "messages", flat_msgs(h["msgs"]))
	kit.jset_bool(c.out, "more", w.obool(h, "more"))
	return kit.EXIT_OK
}

cmd_post :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	ch, cc := need_channel(c, s, kit.cli_str(c, "channel"))
	if cc != kit.EXIT_OK {
		return cc
	}
	text := strings.join(kit.cli_rest(c), " ", context.temp_allocator)
	if text == "" {
		text = kit.cli_str(c, "text")
	}
	if c.dry_run {
		kit.jset_str(c.out, "would_post", text)
		return kit.EXIT_OK
	}
	tag := fmt.tprintf("cli-%d", time.time_to_unix_nano(time.now()))
	e := sreq(s, "post")
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	w.kv_str(&e, "tag", tag)
	if kit.cli_has(c, "thread") {
		w.kv_int(&e, "thread", i64(kit.cli_int(c, "thread")))
	}
	ssend(s, &e)
	// "Posted" means the broadcast came back out of the database, not that
	// a write succeeded.
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < 8000 {
		m, ok := swait(s, "message", 200)
		if !ok {
			if err, has := swait(s, "error", 1); has {
				return refused(c, err)
			}
			continue
		}
		if w.ostr(m, "tag") == tag {
			mo, _ := w.as_obj(m["msg"])
			kit.jset(c.out, "message", flat_one(mo))
			return kit.EXIT_OK
		}
	}
	return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the message did not come back")
}

cmd_edit :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	id := i64(kit.cli_int(c, "id"))
	e := sreq(s, "edit")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "text", strings.join(kit.cli_rest(c), " ", context.temp_allocator))
	ssend(s, &e)
	_, ec := answer(c, s, "edit")
	if ec != kit.EXIT_OK {
		return ec
	}
	kit.jset_int(c.out, "id", int(id))
	return kit.EXIT_OK
}

cmd_react :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	id := i64(kit.cli_int(c, "id"))
	on := !kit.cli_bool(c, "off")
	e := sreq(s, "react")
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "key", kit.cli_str(c, "key"))
	w.kv_bool(&e, "on", on)
	ssend(s, &e)
	if _, ok := swait(s, "react", 3000); !ok {
		if err, has := swait(s, "error", 1); has {
			return refused(c, err)
		}
		// Already in that state: an idempotent no-op broadcasts nothing.
	}
	kit.jset_int(c.out, "id", int(id))
	kit.jset_str(c.out, "key", kit.cli_str(c, "key"))
	kit.jset_bool(c.out, "on", on)
	return kit.EXIT_OK
}

cmd_thread :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := sreq(s, "thread")
	w.kv_int(&e, "id", i64(kit.cli_int(c, "id")))
	ssend(s, &e)
	t, tc := answer(c, s, "thread")
	if tc != kit.EXIT_OK {
		return tc
	}
	kit.jset(c.out, "root", to_kit(t["root"]))
	kit.jset(c.out, "replies", flat_msgs(t["msgs"]))
	kit.jset_int(c.out, "count", int(w.oint(t, "replies")))
	return kit.EXIT_OK
}

cmd_search :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	q := strings.join(kit.cli_rest(c), " ", context.temp_allocator)
	if q == "" {
		q = kit.cli_str(c, "query")
	}
	e := sreq(s, "search")
	w.kv_str(&e, "q", q)
	ssend(s, &e)
	r, rc := answer(c, s, "results")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset(c.out, "messages", flat_msgs(r["msgs"]))
	return kit.EXIT_OK
}

cmd_sync :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	ch, cc := need_channel(c, s, kit.cli_str(c, "channel"))
	if cc != kit.EXIT_OK {
		return cc
	}
	e := sreq(s, "sync")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `[{"ch":`)
	w.write_json_string(&b, ch)
	strings.write_string(&b, `,"rev":`)
	strings.write_int(&b, kit.cli_int(c, "since"))
	strings.write_string(&b, `}]`)
	w.kv_raw(&e, "chs", strings.to_string(b))
	ssend(s, &e)
	r, rc := answer(c, s, "changes")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset(c.out, "messages", flat_msgs(r["msgs"]))
	kit.jset_int(c.out, "rev", int(w.oint(r, "rev")))
	return kit.EXIT_OK
}

cmd_create_space :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := sreq(s, "create_space")
	w.kv_str(&e, "name", kit.cli_str(c, "name"))
	ssend(s, &e)
	r, rc := answer(c, s, "space")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "space", w.ostr(r, "id"))
	return kit.EXIT_OK
}

cmd_create_channel :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := find_space(s, kit.cli_str(c, "space"))
	if space == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no space %s", kit.cli_str(c, "space"))
	}
	e := sreq(s, "create_channel")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "name", kit.cli_str(c, "name"))
	w.kv_str(&e, "topic", kit.cli_str(c, "topic"))
	w.kv_bool(&e, "private", kit.cli_bool(c, "private"))
	ssend(s, &e)
	r, rc := answer(c, s, "joined")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "channel", w.ostr(r, "ch"))
	return kit.EXIT_OK
}

cmd_invite :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := find_space(s, kit.cli_str(c, "space"))
	if space == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no space %s", kit.cli_str(c, "space"))
	}
	e := sreq(s, "invite")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "handle", kit.cli_str(c, "handle"))
	if kit.cli_has(c, "channel") {
		ch, cc := need_channel(c, s, kit.cli_str(c, "channel"))
		if cc != kit.EXIT_OK {
			return cc
		}
		w.kv_str(&e, "ch", ch)
	}
	if kit.cli_has(c, "role") {
		w.kv_str(&e, "role", kit.cli_str(c, "role"))
	}
	w.kv_str(&e, "note", kit.cli_str(c, "note"))
	ssend(s, &e)
	r, rc := answer(c, s, "invited")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "invite", w.ostr(r, "id"))
	return kit.EXIT_OK
}

cmd_invites :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	kit.jset(c.out, "invites", flat_invites(s.invites[:]))
	return kit.EXIT_OK
}

cmd_accept :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	key := kit.cli_str(c, "invite")
	id := ""
	for v in s.invites {
		io, _ := w.as_obj(v)
		if w.ostr(io, "id") == key || strings.equal_fold(w.ostr(io, "space_name"), key) {
			id = w.ostr(io, "id")
		}
	}
	if id == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no waiting invitation %s", key)
	}
	e := sreq(s, "accept")
	w.kv_str(&e, "id", id)
	ssend(s, &e)
	r, rc := answer(c, s, "accepted")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "space", w.ostr(r, "space"))
	return kit.EXIT_OK
}

cmd_dm :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	e := sreq(s, "dm")
	w.kv_str(&e, "with", kit.cli_str(c, "handle"))
	if kit.cli_has(c, "space") {
		w.kv_str(&e, "space", find_space(s, kit.cli_str(c, "space")))
	}
	ssend(s, &e)
	r, rc := answer(c, s, "joined")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "channel", w.ostr(r, "ch"))
	return kit.EXIT_OK
}

cmd_members :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := find_space(s, kit.cli_str(c, "space"))
	if space == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no space %s", kit.cli_str(c, "space"))
	}
	e := sreq(s, "members")
	w.kv_str(&e, "space", space)
	ssend(s, &e)
	r, rc := answer(c, s, "members")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset(c.out, "members", to_kit(r["list"]))
	return kit.EXIT_OK
}

cmd_remove :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := find_space(s, kit.cli_str(c, "space"))
	if space == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no space %s", kit.cli_str(c, "space"))
	}
	e := sreq(s, "remove")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "handle", kit.cli_str(c, "handle"))
	ssend(s, &e)
	_, rc := answer(c, s, "removed_member")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "removed", kit.cli_str(c, "handle"))
	return kit.EXIT_OK
}

cmd_leave :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	space := find_space(s, kit.cli_str(c, "space"))
	if space == "" {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no space %s", kit.cli_str(c, "space"))
	}
	e := sreq(s, "leave_space")
	w.kv_str(&e, "space", space)
	ssend(s, &e)
	_, rc := answer(c, s, "left_space")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "left", space)
	return kit.EXIT_OK
}

cmd_call :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	ch, cc := need_channel(c, s, kit.cli_str(c, "channel"))
	if cc != kit.EXIT_OK {
		return cc
	}
	e := sreq(s, "call_join")
	w.kv_str(&e, "ch", ch)
	ssend(s, &e)
	r, rc := answer(c, s, "call_token")
	if rc != kit.EXIT_OK {
		return rc
	}
	kit.jset_str(c.out, "call", w.ostr(r, "call"))
	kit.jset_str(c.out, "sfu", w.ostr(r, "sfu"))
	kit.jset_str(c.out, "token", w.ostr(r, "token"))
	kit.jset_int(c.out, "exp", int(w.oint(r, "exp")))
	if kit.cli_bool(c, "launch") {
		io, _ := w.as_obj(s.welcome["identity"])
		kit.launch({"call", "--sfu", w.ostr(r, "sfu"), "--join-token", w.ostr(r, "token"), "--name", w.ostr(io, "name")})
	}
	return kit.EXIT_OK
}

cmd_watch :: proc(c: ^kit.Call) -> int {
	s, code := open_sess(c)
	if code != kit.EXIT_OK {
		return code
	}
	got := json.Array{}
	start := time.tick_now()
	secs := f64(kit.cli_int(c, "seconds", 10))
	for time.duration_seconds(time.tick_since(start)) < secs {
		m, ok := swait(s, "message", 200)
		if !ok {
			continue
		}
		append(&got, m["msg"])
	}
	kit.jset(c.out, "messages", flat_msgs(got))
	return kit.EXIT_OK
}
