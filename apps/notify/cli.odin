// The command line: `notify <verb>`, or `palm notify <verb>`.
//
// Every verb is a request to the daemon over the socket apps use, so the CLI
// cannot drift from what an app gets. Scope follows docs/PALM-CLI.md:
// PALM_IDENTITY, narrowed by --identity, and the daemon applies it again on
// its side from the caller's environment.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import kit "kit:."

@(private = "file")
NOTE_FIELDS :: []kit.Field {
	{name = "id", kind = .Int},
	{name = "key", kind = .String, help = "stable across apps: the same object, the same key"},
	{name = "app", kind = .String},
	{name = "app_label", kind = .String},
	{name = "identity", kind = .String, help = "a handle, or \"\" when nobody could say"},
	{name = "identity_name", kind = .String},
	{name = "class", kind = .String, help = "person, time or machine"},
	{name = "urgency", kind = .String, help = "low, normal or critical"},
	{name = "category", kind = .String, opt = true},
	{name = "title", kind = .String},
	{name = "body", kind = .String},
	{name = "link", kind = .String, opt = true, help = "the deep link a click runs"},
	{name = "actions", kind = .Array, help = "key, label, run"},
	{name = "source", kind = .String, help = "native, fdo, cli or system"},
	{name = "created", kind = .Int, help = "unix ms"},
	{name = "updated", kind = .Int, help = "unix ms"},
	{name = "timeout_ms", kind = .Int, opt = true},
	{name = "delivery", kind = .String, help = "what the policy decided: toast, center or digest"},
	{name = "why", kind = .String, help = "the policy's reason, in words"},
	{name = "showing", kind = .Bool, help = "on screen as a toast now"},
	{name = "held", kind = .Bool, help = "waiting for a digest"},
	{name = "digest", kind = .String, opt = true, help = "the key of the digest it went out in"},
	{name = "read", kind = .Bool},
	{name = "is_digest", kind = .Bool, opt = true},
	{name = "count", kind = .Int, opt = true},
	{name = "spoken", kind = .String, help = "the accessible text: what a screen reader says"},
	{name = "fdo_sender", kind = .String, opt = true},
}

@(private = "file")
POLICY_FIELDS :: []kit.Field {
	{name = "identity", kind = .String, help = "a handle; * is everything without one"},
	{name = "identity_name", kind = .String},
	{name = "sentence", kind = .String, help = "the policy, as it is shown"},
	{name = "quiet_hours", kind = .Any, help = "{from, to} or null"},
	{name = "quiet_until", kind = .Int, help = "unix ms of a one-off quiet; 0 when none"},
	{name = "dnd_until", kind = .Int, help = "-1 until turned off; unix ms; 0 when off"},
	{name = "people_only", kind = .Bool},
	{name = "digest_at", kind = .Any, help = "HH:MM or null"},
	{name = "breaks_through", kind = .Array, help = "calls, alarms, reminders"},
	{name = "apps", kind = .Object, help = "app -> muted | digest | always"},
	{name = "hold", kind = .String, opt = true, help = "none, quiet or dnd, right now"},
	{name = "hold_ends", kind = .String, opt = true},
	{name = "color", kind = .String, opt = true},
}

COMMANDS := []kit.Command {
	{
		verb = "send",
		summary = "send a notification (as the identity in scope)",
		effect = .Mutate,
		args = {{name = "title", kind = .String, required = true}, {name = "body", kind = .String}},
		flags = {
			{name = "class", kind = .Enum, values = {"person", "time", "machine"}, def = "person"},
			{name = "urgency", kind = .Enum, values = {"low", "normal", "critical"}, def = "normal"},
			{name = "app", kind = .String, def = "cli", help = "the app it is from"},
			{name = "key", kind = .String, help = "stable key: the same key is delivered once"},
			{name = "link", kind = .String, help = "deep link a click runs, e.g. \"mail open 42\""},
			{name = "action", kind = .String, help = "key=Label[=run], several separated by |"},
			{name = "category", kind = .String, help = "freedesktop category, e.g. call.incoming"},
			{name = "timeout", kind = .Int, help = "toast time in ms; 0 by class"},
			{name = "renotify", kind = .Bool, help = "same key, but interrupt again"},
		},
		out = {
			{name = "id", kind = .Int, opt = true},
			{name = "key", kind = .String, opt = true},
			{name = "identity", kind = .String, opt = true},
			{name = "class", kind = .String, opt = true},
			{name = "delivery", kind = .String, help = "toast, center, digest, updated or none"},
			{name = "why", kind = .String},
			{name = "replaced", kind = .Bool, opt = true},
			{name = "showing", kind = .Bool, opt = true},
			{name = "dropped", kind = .Bool, opt = true},
		},
		examples = {
			`notify send --identity work --class person "Priya Shah" "Q4 roadmap: can you sign off?"`,
			`notify send --class machine --app forge "CI passed" "main @ 4f2a1c"`,
			`notify send --class person --urgency critical --category call.incoming --app call "Ines Roux" "Incoming call" --action "answer=Answer|decline=Decline"`,
		},
		run = cmd_send,
	},
	{
		verb = "list",
		summary = "the notifications in the center, newest first",
		effect = .Read,
		flags = {
			{name = "unread", kind = .Bool},
			{name = "showing", kind = .Bool, help = "only those on screen now"},
			{name = "held", kind = .Bool, help = "only those waiting for a digest"},
			{name = "app", kind = .String},
		},
		out = {
			{name = "notifications", kind = .Array, of = NOTE_FIELDS},
			{name = "count", kind = .Int},
			{name = "unread", kind = .Int},
			{name = "dnd", kind = .Bool},
		},
		examples = {"notify list --json", "notify list --identity work --unread --json"},
		run = cmd_list,
	},
	{
		verb = "read",
		summary = "mark read: one (id or key), an identity's (--identity), or all",
		effect = .Idempotent,
		args = {{name = "target", kind = .String, help = "an id, a key, or all"}},
		out = {{name = "count", kind = .Int, opt = true}},
		examples = {"notify read 12", "notify read all", "notify read --identity work"},
		run = cmd_simple,
	},
	{
		verb = "dismiss",
		summary = "take a toast off the screen; it stays in the center, read",
		effect = .Idempotent,
		args = {{name = "target", kind = .String, required = true, help = "an id or a key"}},
		out = {{name = "count", kind = .Int, opt = true}},
		examples = {"notify dismiss 12"},
		run = cmd_simple,
	},
	{
		verb = "withdraw",
		summary = "the sender takes a notification back; its key will not come back as new",
		effect = .Idempotent,
		args = {{name = "target", kind = .String, required = true, help = "a key or an id"}},
		out = {{name = "count", kind = .Int, opt = true}},
		examples = {"notify withdraw call:7f3a"},
		run = cmd_simple,
	},
	{
		verb = "invoke",
		summary = "press an action (default: a click on the body)",
		effect = .Mutate,
		args = {{name = "target", kind = .String, required = true}, {name = "action", kind = .String, def = "default"}},
		out = {{name = "ran", kind = .Bool}, {name = "run", kind = .String}},
		examples = {"notify invoke 12 reply"},
		run = cmd_invoke,
	},
	{
		verb = "clear",
		summary = "remove from the center: one, an identity's (--identity), or all",
		effect = .Destructive,
		args = {{name = "target", kind = .String, help = "an id, a key, or all"}},
		out = {{name = "count", kind = .Int}},
		examples = {"notify clear all --yes", "notify clear --identity work --yes"},
		run = cmd_clear,
	},
	{
		verb = "quiet",
		summary = "an identity's policy, as a sentence: get, set, add, clear, check, list",
		effect = .Idempotent,
		args = {
			{name = "verb", kind = .Enum, values = {"get", "set", "add", "clear", "check", "list"}, def = "list"},
			{name = "sentence", kind = .String, variadic = true, help = "e.g. \"after 18:00\" or \"Daily digest at 17:00. Calls break through\""},
		},
		out = {{name = "policy", kind = .Object, opt = true, of = POLICY_FIELDS}, {name = "policies", kind = .Array, opt = true, of = POLICY_FIELDS}, {name = "dnd", kind = .Bool, opt = true}, {name = "now", kind = .String, opt = true}},
		examples = {
			`notify quiet set --identity work "after 18:00"`,
			`notify quiet add --identity work "daily digest at 17:00. calls break through"`,
			`notify quiet check "quiet 22:00-07:00, mute chromium"`,
			"notify quiet list --json",
		},
		run = cmd_quiet,
	},
	{
		verb = "dnd",
		summary = "do not disturb, for the whole person: on, off, toggle, status",
		effect = .Idempotent,
		args = {{name = "state", kind = .Enum, values = {"on", "off", "toggle", "status"}, def = "status"}},
		flags = {{name = "minutes", kind = .Int, help = "on for this long"}},
		out = {{name = "dnd", kind = .Bool}, {name = "until", kind = .Int, opt = true}},
		examples = {"notify dnd on", "notify dnd on --minutes 45", "notify dnd off"},
		run = cmd_dnd,
	},
	{
		verb = "status",
		summary = "the daemon: counts, do-not-disturb, the bus, sound",
		effect = .Read,
		out = {
			{name = "total", kind = .Int},
			{name = "unread", kind = .Int},
			{name = "showing", kind = .Int},
			{name = "held", kind = .Int},
			{name = "dnd", kind = .Bool},
			{name = "dnd_until", kind = .Int},
			{name = "now", kind = .String},
			{name = "test_clock", kind = .Bool},
			{name = "socket", kind = .String},
			{name = "bus", kind = .String},
			{name = "toasts_running", kind = .Bool},
			{name = "sounds_played", kind = .Int},
			{name = "last_sound", kind = .String},
			{name = "watchers", kind = .Int},
			{name = "scope", kind = .String},
			{name = "rev", kind = .Int},
		},
		examples = {"notify status --json"},
		run = cmd_status,
	},
	{
		verb = "digest",
		summary = "send an identity's held notifications as a digest now",
		effect = .Mutate,
		out = {{name = "identity", kind = .String, help = "whose held notifications went out"}},
		examples = {"notify digest --identity work"},
		run = cmd_digest,
	},
	{
		verb = "focus",
		summary = "the keyboard shortcut: focus the toasts, or open the center",
		effect = .Idempotent,
		out = {{name = "focused", kind = .String}},
		examples = {"notify focus"},
		run = cmd_focus,
	},
	{
		verb = "center",
		summary = "open the notification center",
		effect = .Read,
		flags = {{name = "window", kind = .Bool, help = "an ordinary window, not a panel"}, {name = "dark", kind = .Bool}},
		out = {{name = "shown", kind = .Bool, help = "the center was shown, and has been closed"}},
		examples = {"notify center", "notify center --identity work"},
		run = cmd_center,
	},
	{
		verb = "daemon",
		summary = "run the session's notification service (palm-notifyd)",
		effect = .Mutate,
		flags = {
			{name = "clock", kind = .String, help = "test clock: start at this local time (HH:MM) and allow `notify clock`"},
			{name = "test-clock", kind = .Bool, help = "allow `notify clock` without moving the start"},
			{name = "no-bus", kind = .Bool, help = "do not serve org.freedesktop.Notifications"},
			{name = "no-ui", kind = .Bool, help = "never start the toast surface"},
		},
		out = {{name = "stopped", kind = .Bool, help = "the service ran and has stopped"}},
		examples = {"notify daemon", "notify daemon --clock 17:58 --no-ui"},
		run = cmd_daemon,
	},
	{
		verb = "clock",
		summary = "move a test daemon's clock forward to HH:MM",
		effect = .Mutate,
		args = {{name = "at", kind = .String, required = true}},
		out = {{name = "now", kind = .String}},
		examples = {"notify clock 18:30"},
		hidden = true,
		run = cmd_clock,
	},
}

// ---------------------------------------------------------------------------

// ask sends one request and turns the reply into the call's output, or into
// the refusal the daemon gave (its error tokens are the CLI's).
@(private = "file")
ask :: proc(c: ^kit.Call, req: ^kit.Json) -> (o: json.Object, code: int) {
	line, ok := kit.notify_request(kit.json_text(req, 0, context.temp_allocator), 4000)
	if !ok {
		return nil, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, fmt.tprintf("palm-notifyd is not running (no answer on %s)", kit.notify_socket_path()))
	}
	v, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil {
		return nil, kit.cli_fail(c, kit.EXIT_FAILED, "the daemon's reply did not parse")
	}
	o, _ = v.(json.Object)
	if !jv_bool(o, "ok") {
		code = int(jv_int(o, "code", i64(kit.EXIT_FAILED)))
		kit.cli_fail(c, code, jv_str(o, "detail"))
		for k in ([?]string{"identity", "requested", "clause"}) {
			if s := jv_str(o, k); s != "" {
				kit.cli_err_field(c, k, s)
			}
		}
		return o, code
	}
	return o, kit.EXIT_OK
}

// from_value turns a parsed JSON value back into the kit's builder, so a
// reply can be passed through as the command's output.
@(private = "file")
from_value :: proc(v: json.Value) -> ^kit.Json {
	context.allocator = context.temp_allocator
	#partial switch x in v {
	case json.Null:
		return kit.jnull()
	case json.Boolean:
		return kit.jbool(bool(x))
	case json.Integer:
		return kit.ji64(i64(x))
	case json.Float:
		if f64(i64(x)) == f64(x) {
			return kit.ji64(i64(x))
		}
		return kit.jnum(f64(x))
	case json.String:
		return kit.jstr(string(x))
	case json.Array:
		a := kit.jarr()
		for e in x {
			kit.jpush(a, from_value(e))
		}
		return a
	case json.Object:
		o := kit.jobj()
		// Keep a stable, readable order: the daemon writes keys in a fixed
		// order, but the parsed map has none.
		keys := make([dynamic]string)
		for k in x {
			append(&keys, k)
		}
		order_keys(keys[:])
		for k in keys {
			kit.jset(o, k, from_value(x[k]))
		}
		return o
	}
	return kit.jnull()
}

@(private = "file")
KEY_ORDER := [?]string{"ok", "id", "key", "identity", "identity_name", "app", "app_label", "class", "urgency", "title", "body", "delivery", "why", "sentence"}

@(private = "file")
order_keys :: proc(keys: []string) {
	rank :: proc(k: string) -> int {
		for o, i in KEY_ORDER {
			if o == k {
				return i
			}
		}
		return len(KEY_ORDER)
	}
	// Insertion sort: a handful of keys.
	for i in 1 ..< len(keys) {
		j := i
		for j > 0 && (rank(keys[j - 1]) > rank(keys[j]) || rank(keys[j - 1]) == rank(keys[j]) && keys[j - 1] > keys[j]) {
			keys[j - 1], keys[j] = keys[j], keys[j - 1]
			j -= 1
		}
	}
}

@(private = "file")
pass :: proc(c: ^kit.Call, o: json.Object, keys: ..string) {
	c.out = kit.jobj(context.temp_allocator)
	for k in keys {
		if v, has := o[k]; has {
			kit.jset(c.out, k, from_value(v), context.temp_allocator)
		}
	}
}

@(private = "file")
req :: proc(op: string) -> ^kit.Json {
	o := kit.jobj(context.temp_allocator)
	kit.jset_str(o, "op", op, context.temp_allocator)
	return o
}

// target puts an id or a key into a request.
@(private = "file")
target :: proc(r: ^kit.Json, t: string) {
	is_num := len(t) > 0
	for ch in t {
		if ch < '0' || ch > '9' {
			is_num = false
		}
	}
	if is_num {
		kit.jset_str(r, "id", t, context.temp_allocator)
	} else {
		kit.jset_str(r, "key", t, context.temp_allocator)
	}
}

@(private = "file")
cmd_send :: proc(c: ^kit.Call) -> int {
	n := kit.Notification {
		key      = kit.cli_str(c, "key"),
		app      = kit.cli_str(c, "app"),
		identity = c.identity,
		title    = kit.cli_str(c, "title"),
		body     = kit.cli_str(c, "body"),
		link     = kit.cli_str(c, "link"),
		category = kit.cli_str(c, "category"),
		timeout_ms = kit.cli_int(c, "timeout"),
		renotify = kit.cli_bool(c, "renotify"),
	}
	switch kit.cli_str(c, "class") {
	case "time":
		n.class = .Time
	case "machine":
		n.class = .Machine
	}
	switch kit.cli_str(c, "urgency") {
	case "low":
		n.urgency = .Low
	case "critical":
		n.urgency = .Critical
	}
	acts := make([dynamic]kit.Notify_Action, context.temp_allocator)
	if spec := kit.cli_str(c, "action"); spec != "" {
		for one in strings.split(spec, "|", context.temp_allocator) {
			parts := strings.split_n(one, "=", 3, context.temp_allocator)
			a := kit.Notify_Action {
				key = strings.trim_space(parts[0]),
			}
			a.label = len(parts) > 1 ? strings.trim_space(parts[1]) : a.key
			if len(parts) > 2 {
				a.run = strings.trim_space(parts[2])
			}
			if a.key == "" {
				return kit.cli_fail(c, kit.EXIT_USAGE, "an action is key=Label[=run]")
			}
			append(&acts, a)
		}
	}
	n.actions = acts[:]
	if c.dry_run {
		c.out = kit.jobj(context.temp_allocator)
		kit.jset_str(c.out, "delivery", "none", context.temp_allocator)
		kit.jset_str(c.out, "why", "dry run: nothing sent", context.temp_allocator)
		return kit.EXIT_OK
	}
	line, ok := kit.notify_request(kit.notify_json(n, "cli"), 4000)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, fmt.tprintf("palm-notifyd is not running (no answer on %s)", kit.notify_socket_path()))
	}
	v, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil {
		return kit.cli_fail(c, kit.EXIT_FAILED, "the daemon's reply did not parse")
	}
	o, _ := v.(json.Object)
	if !jv_bool(o, "ok") {
		code := int(jv_int(o, "code", i64(kit.EXIT_FAILED)))
		kit.cli_fail(c, code, jv_str(o, "detail"))
		for k in ([?]string{"identity", "requested"}) {
			if s := jv_str(o, k); s != "" {
				kit.cli_err_field(c, k, s)
			}
		}
		return code
	}
	pass(c, o, "id", "key", "identity", "class", "delivery", "why", "replaced", "showing", "dropped")
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	r := req("list")
	if c.identity != "" {
		kit.jset_str(r, "identity", c.identity, context.temp_allocator)
	}
	for f in ([?]string{"unread", "showing", "held"}) {
		if kit.cli_bool(c, f) {
			kit.jset_bool(r, f, true, context.temp_allocator)
		}
	}
	if a := kit.cli_str(c, "app"); a != "" {
		kit.jset_str(r, "app", a, context.temp_allocator)
	}
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	if c.json {
		pass(c, o, "notifications", "count", "unread", "dnd")
		return kit.EXIT_OK
	}
	// For a person: one line each, identity first, then why it did or did
	// not interrupt.
	c.out = kit.jobj(context.temp_allocator)
	rows := kit.jarr(context.temp_allocator)
	if arr, has := jv_arr(o, "notifications"); has {
		for v in arr {
			n, _ := v.(json.Object)
			row := kit.jobj(context.temp_allocator)
			kit.jset_str(row, "id", jv_str(n, "id"), context.temp_allocator)
			ident := jv_str(n, "identity_name")
			kit.jset_str(row, "identity", ident != "" ? ident : "-", context.temp_allocator)
			kit.jset_str(row, "app", jv_str(n, "app_label"), context.temp_allocator)
			kit.jset_str(row, "class", jv_str(n, "class"), context.temp_allocator)
			state := jv_bool(n, "held") ? "held" : (jv_bool(n, "showing") ? "on screen" : (jv_bool(n, "read") ? "read" : "unread"))
			kit.jset_str(row, "state", state, context.temp_allocator)
			kit.jset_str(row, "title", jv_str(n, "title"), context.temp_allocator)
			kit.jset_str(row, "why", jv_str(n, "why"), context.temp_allocator)
			kit.jpush(rows, row)
		}
	}
	kit.jset(c.out, "notifications", rows, context.temp_allocator)
	kit.jset_int(c.out, "unread", int(jv_int(o, "unread")), context.temp_allocator)
	return kit.EXIT_OK
}

@(private = "file")
cmd_simple :: proc(c: ^kit.Call) -> int {
	r := req(c.cmd.verb)
	t := kit.cli_str(c, "target")
	switch {
	case t == "all":
		if c.identity != "" {
			kit.jset_str(r, "identity", c.identity, context.temp_allocator)
		} else {
			kit.jset_bool(r, "all", true, context.temp_allocator)
		}
	case t != "":
		target(r, t)
	case c.identity != "":
		kit.jset_str(r, "identity", c.identity, context.temp_allocator)
	case:
		return kit.cli_fail(c, kit.EXIT_USAGE, "say which: an id, a key, all, or --identity")
	}
	if c.dry_run {
		c.out = kit.jobj(context.temp_allocator)
		return kit.EXIT_OK
	}
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "count")
	return kit.EXIT_OK
}

@(private = "file")
cmd_clear :: proc(c: ^kit.Call) -> int {
	return cmd_simple(c)
}

@(private = "file")
cmd_invoke :: proc(c: ^kit.Call) -> int {
	r := req("invoke")
	target(r, kit.cli_str(c, "target"))
	kit.jset_str(r, "action", kit.cli_str(c, "action"), context.temp_allocator)
	if c.dry_run {
		c.out = kit.jobj(context.temp_allocator)
		return kit.EXIT_OK
	}
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "ran", "run")
	return kit.EXIT_OK
}

@(private = "file")
cmd_quiet :: proc(c: ^kit.Call) -> int {
	verb := kit.cli_str(c, "verb")
	// The variadic positional's words are all in `rest`; `sentence` alone is
	// the case where only one was given.
	sentence := kit.cli_str(c, "sentence")
	if len(c.rest) > 0 {
		sentence = strings.join(c.rest, " ", context.temp_allocator)
	}
	if verb == "list" {
		o, code := ask(c, req("policies"))
		if code != kit.EXIT_OK {
			return code
		}
		if c.json {
			pass(c, o, "policies", "dnd", "now")
			return kit.EXIT_OK
		}
		c.out = kit.jobj(context.temp_allocator)
		rows := kit.jarr(context.temp_allocator)
		if arr, has := jv_arr(o, "policies"); has {
			for v in arr {
				p, _ := v.(json.Object)
				row := kit.jobj(context.temp_allocator)
				kit.jset_str(row, "identity", jv_str(p, "identity_name"), context.temp_allocator)
				kit.jset_str(row, "policy", jv_str(p, "sentence"), context.temp_allocator)
				hold := jv_str(p, "hold")
				if e := jv_str(p, "hold_ends"); e != "" && hold != "none" {
					hold = fmt.tprintf("%s until %s", hold, e)
				}
				kit.jset_str(row, "now", hold, context.temp_allocator)
				kit.jpush(rows, row)
			}
		}
		kit.jset(c.out, "policies", rows, context.temp_allocator)
		if jv_bool(o, "dnd") {
			kit.jset_str(c.out, "do_not_disturb", "on", context.temp_allocator)
		}
		return kit.EXIT_OK
	}
	if (verb == "set" || verb == "add" || verb == "check") && strings.trim_space(sentence) == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, fmt.tprintf("quiet %s needs a sentence, e.g. \"after 18:00\"", verb))
	}
	r := req("quiet")
	kit.jset_str(r, "mode", c.dry_run && verb != "get" ? "check" : verb, context.temp_allocator)
	kit.jset_str(r, "sentence", sentence, context.temp_allocator)
	if c.identity != "" {
		kit.jset_str(r, "identity", c.identity, context.temp_allocator)
	}
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	if c.json {
		pass(c, o, "policy")
		return kit.EXIT_OK
	}
	c.out = kit.jobj(context.temp_allocator)
	if p, has := jv_obj(o, "policy"); has {
		kit.jset_str(c.out, "identity", jv_str(p, "identity_name"), context.temp_allocator)
		kit.jset_str(c.out, "policy", jv_str(p, "sentence"), context.temp_allocator)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_dnd :: proc(c: ^kit.Call) -> int {
	state := kit.cli_str(c, "state")
	if state == "status" {
		o, code := ask(c, req("status"))
		if code != kit.EXIT_OK {
			return code
		}
		c.out = kit.jobj(context.temp_allocator)
		kit.jset_bool(c.out, "dnd", jv_bool(o, "dnd"), context.temp_allocator)
		kit.jset_int(c.out, "until", int(jv_int(o, "dnd_until")), context.temp_allocator)
		return kit.EXIT_OK
	}
	if c.identity != "" {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "do not disturb is the whole person's; for one identity use: notify quiet add \"do not disturb\"")
	}
	r := req("dnd")
	switch state {
	case "on":
		kit.jset_bool(r, "on", true, context.temp_allocator)
	case "toggle":
		kit.jset_str(r, "toggle", "true", context.temp_allocator)
	}
	if m := kit.cli_int(c, "minutes"); m > 0 {
		kit.jset_int(r, "minutes", m, context.temp_allocator)
	}
	if c.dry_run {
		c.out = kit.jobj(context.temp_allocator)
		kit.jset_bool(c.out, "dnd", state == "on", context.temp_allocator)
		return kit.EXIT_OK
	}
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "dnd", "until")
	return kit.EXIT_OK
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	o, code := ask(c, req("status"))
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "total", "unread", "showing", "held", "dnd", "dnd_until", "now", "test_clock", "socket", "bus", "toasts_running", "sounds_played", "last_sound", "watchers", "scope", "rev")
	return kit.EXIT_OK
}

@(private = "file")
cmd_digest :: proc(c: ^kit.Call) -> int {
	r := req("digest")
	kit.jset_str(r, "identity", c.identity, context.temp_allocator)
	if c.dry_run {
		c.out = kit.jobj(context.temp_allocator)
		return kit.EXIT_OK
	}
	_, code := ask(c, r)
	if code == kit.EXIT_OK {
		c.out = kit.jobj(context.temp_allocator)
		kit.jset_str(c.out, "identity", c.identity, context.temp_allocator)
	}
	return code
}

@(private = "file")
cmd_focus :: proc(c: ^kit.Call) -> int {
	o, code := ask(c, req("focus"))
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "focused")
	return kit.EXIT_OK
}

@(private = "file")
cmd_center :: proc(c: ^kit.Call) -> int {
	args := make([dynamic]string, context.temp_allocator)
	if kit.cli_bool(c, "window") {
		append(&args, "--window")
	}
	if kit.cli_bool(c, "dark") {
		append(&args, "--dark")
	}
	if c.identity != "" {
		append(&args, "--identity", c.identity)
	}
	code := center_main(args[:])
	if code != kit.EXIT_OK {
		// center_main said why on stderr; the caller gets the documented
		// error object, not an empty document with a failing exit.
		return kit.cli_fail(c, code, code == kit.EXIT_UNAVAILABLE ? "palm-notifyd is not running" : "the center could not open")
	}
	c.out = kit.jobj(context.temp_allocator)
	kit.jset_bool(c.out, "shown", true, context.temp_allocator)
	return code
}

@(private = "file")
cmd_daemon :: proc(c: ^kit.Call) -> int {
	args := make([dynamic]string, context.temp_allocator)
	if kit.cli_bool(c, "no-bus") {
		append(&args, "--no-bus")
	}
	if kit.cli_bool(c, "no-ui") {
		append(&args, "--no-ui")
	}
	if kit.cli_bool(c, "test-clock") {
		append(&args, "--test-clock")
	}
	if t := kit.cli_str(c, "clock"); t != "" {
		append(&args, "--clock", t)
	}
	code := daemon_main(args[:])
	if code != kit.EXIT_OK {
		return kit.cli_fail(c, code, "palm-notifyd stopped with an error")
	}
	c.out = kit.jobj(context.temp_allocator)
	kit.jset_bool(c.out, "stopped", true, context.temp_allocator)
	return code
}

@(private = "file")
cmd_clock :: proc(c: ^kit.Call) -> int {
	r := req("clock")
	kit.jset_str(r, "at", kit.cli_str(c, "at"), context.temp_allocator)
	o, code := ask(c, r)
	if code != kit.EXIT_OK {
		return code
	}
	pass(c, o, "now")
	return kit.EXIT_OK
}
