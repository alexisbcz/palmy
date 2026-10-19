// The socket protocol: one JSON object per line in, one per line out.
//
//	{"op":"send","note":{...},"renotify":false}
//	{"op":"withdraw","key":"mail:<id>"}          {"op":"withdraw","id":7}
//	{"op":"read","id":7} | {"op":"read","identity":"x"} | {"op":"read","all":true}
//	{"op":"dismiss","id":7}      gone from the screen, read, stays in the center
//	{"op":"hide","id":7}         the toast timed out; still unread
//	{"op":"invoke","id":7,"action":"reply"}
//	{"op":"clear","identity":"x"} | {"op":"clear","id":7} | {"op":"clear","all":true}
//	{"op":"list","identity":"x","unread":true,"showing":true,"app":"mail"}
//	{"op":"policies"}
//	{"op":"quiet","identity":"x","mode":"set|add|clear|check","sentence":"after 18:00"}
//	{"op":"dnd","on":true,"minutes":60}
//	{"op":"status"}
//	{"op":"watch","role":"toasts|center|listener","app":"mail"}
//	{"op":"focus"}  {"op":"center","identity":"x"}  {"op":"digest","identity":"x"}
//	{"op":"clock","at":"18:30"}   only when started with --clock / --test-clock
//
// Every reply has "ok". A refusal carries the CLI's tokens (`error`, `code`)
// so the CLI can pass it through unchanged: 2 usage, 3 not found, 5 out of
// scope.
//
// Scope. A peer whose environment has PALM_IDENTITY is inside that identity:
// it may send only as that identity, sees only its notifications, and may
// change only its own policy. This is the same rule as docs/PALM-CLI.md's
// "narrowed, never widened". It is honest to say what it is not: a process
// of the same user can start a child with a different environment, so it is
// a guard against mistakes and confused agents, not a security boundary. The
// boundary between identities is the cloud's (cloud/CONTRACT.md).
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import kit "kit:."

reply_ok :: proc() -> ^kit.Json {
	o := kit.jobj(context.temp_allocator)
	kit.jset_bool(o, "ok", true, context.temp_allocator)
	return o
}

reply_err :: proc(code: int, detail: string) -> ^kit.Json {
	o := kit.jobj(context.temp_allocator)
	kit.jset_bool(o, "ok", false, context.temp_allocator)
	kit.jset_str(o, "error", kit.cli_exit_reason(code), context.temp_allocator)
	kit.jset_int(o, "code", code, context.temp_allocator)
	kit.jset_str(o, "detail", detail, context.temp_allocator)
	return o
}

// in_scope: may a peer scoped to `scope` touch `identity`?
in_scope :: proc(scope, identity: string) -> bool {
	return scope == "" || scope == identity
}

handle :: proc(d: ^Daemon, c: ^Client, line: string) -> ^kit.Json {
	context.allocator = context.temp_allocator
	v, perr := json.parse_string(line, allocator = context.temp_allocator)
	if perr != nil {
		return reply_err(kit.EXIT_USAGE, "not JSON")
	}
	o, isobj := v.(json.Object)
	if !isobj {
		return reply_err(kit.EXIT_USAGE, "not an object")
	}
	s := &d.store
	now := now_ms(d)
	op := jv_str(o, "op")
	switch op {
	case "hello":
		r := reply_ok()
		kit.jset_str(r, "server", "palm-notifyd")
		kit.jset_int(r, "rev", int(s.rev))
		kit.jset_str(r, "scope", c.scope)
		return r

	case "send":
		no, has := jv_obj(o, "note")
		if !has {
			return reply_err(kit.EXIT_USAGE, "send needs a note")
		}
		n, why := note_from_json(no)
		if why != "" {
			return reply_err(kit.EXIT_USAGE, why)
		}
		if n.identity == "" {
			n.identity = sender_identity(c.pid, c.scope)
		}
		if !in_scope(c.scope, n.identity) {
			r := reply_err(kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("a sender inside %q cannot notify as %q", c.scope, n.identity))
			kit.jset_str(r, "identity", c.scope)
			kit.jset_str(r, "requested", n.identity)
			return r
		}
		n.source = jv_str(o, "source") == "cli" ? .Cli : .Native
		if n.app == "" {
			n.app = "unknown"
		}
		r, _ := deliver(d, &n, jv_bool(o, "renotify"))
		return r

	case "withdraw":
		n := find_note(d, o)
		if n == nil {
			return reply_err(kit.EXIT_NOT_FOUND, "no such notification")
		}
		if !in_scope(c.scope, n.identity) {
			return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
		}
		_, idx := store_find_id(s, n.id)
		fdo_closed(d, n, 3)
		store_remove(s, idx, now)
		return reply_ok()

	case "read", "dismiss", "hide":
		if jv_bool(o, "all") || (jv_str(o, "identity") != "" && jv_str(o, "id") == "" && jv_str(o, "key") == "") {
			ident := jv_str(o, "identity")
			all := jv_bool(o, "all")
			if !all && !in_scope(c.scope, ident) {
				return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
			}
			k := 0
			for n in s.notes {
				if (all && in_scope(c.scope, n.identity)) || (!all && n.identity == ident) {
					if !n.read || n.showing {
						if n.showing {
							fdo_closed(d, n, 2)
						}
						store_mark_read(s, n)
						k += 1
					}
				}
			}
			r := reply_ok()
			kit.jset_int(r, "count", k)
			return r
		}
		n := find_note(d, o)
		if n == nil {
			return reply_err(kit.EXIT_NOT_FOUND, "no such notification")
		}
		if !in_scope(c.scope, n.identity) {
			return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
		}
		switch op {
		case "hide":
			if n.showing {
				n.showing = false
				touch(s)
			}
		case "dismiss":
			if n.showing {
				fdo_closed(d, n, 2)
			}
			store_mark_read(s, n)
		case:
			store_mark_read(s, n)
		}
		return reply_ok()

	case "invoke":
		n := find_note(d, o)
		if n == nil {
			return reply_err(kit.EXIT_NOT_FOUND, "no such notification")
		}
		if !in_scope(c.scope, n.identity) {
			return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
		}
		key := jv_str(o, "action")
		if key == "" {
			key = "default"
		}
		run := ""
		found := key == "default"
		for a in n.actions {
			if a.key == key {
				run = a.run
				found = true
			}
		}
		if !found {
			return reply_err(kit.EXIT_NOT_FOUND, fmt.tprintf("no action %q", key))
		}
		if run == "" && key == "default" {
			run = n.link
		}
		ran := false
		if run != "" {
			ran = run_link(d, run, n.identity)
		}
		fdo_action(d, n, key)
		ev := kit.jobj()
		kit.jset_str(ev, "ev", "action")
		kit.jset_int(ev, "id", int(n.id))
		kit.jset_str(ev, "key", n.key)
		kit.jset_str(ev, "app", n.app)
		kit.jset_str(ev, "identity", n.identity)
		kit.jset_str(ev, "action", key)
		for w in d.clients {
			if w.watch && w.role == "listener" && (w.app == "" || strings.equal_fold(w.app, n.app)) && in_scope(w.scope, n.identity) {
				client_send(w, kit.json_text(ev, 0))
			}
		}
		if n.showing {
			fdo_closed(d, n, 2)
		}
		store_mark_read(s, n)
		r := reply_ok()
		kit.jset_bool(r, "ran", ran)
		kit.jset_str(r, "run", run)
		return r

	case "clear":
		k := 0
		if jv_str(o, "id") != "" || jv_str(o, "key") != "" {
			n := find_note(d, o)
			if n == nil {
				return reply_err(kit.EXIT_NOT_FOUND, "no such notification")
			}
			if !in_scope(c.scope, n.identity) {
				return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
			}
			_, idx := store_find_id(s, n.id)
			fdo_closed(d, n, 2)
			store_remove(s, idx, now)
			k = 1
		} else {
			all := jv_bool(o, "all")
			ident := jv_str(o, "identity")
			if !all && !in_scope(c.scope, ident) {
				return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
			}
			i := 0
			for i < len(s.notes) {
				n := s.notes[i]
				hit := all ? in_scope(c.scope, n.identity) : n.identity == ident
				// A held notification is not "cleared" by clearing the list:
				// it has not been delivered yet.
				if hit && !n.held {
					fdo_closed(d, n, 2)
					store_remove(s, i, now)
					k += 1
					continue
				}
				i += 1
			}
		}
		r := reply_ok()
		kit.jset_int(r, "count", k)
		return r

	case "list":
		f := Filter {
			any_ident = true,
			app       = jv_str(o, "app"),
			unread    = jv_bool(o, "unread"),
			showing   = jv_bool(o, "showing"),
			held      = jv_bool(o, "held"),
		}
		if _, has := o["identity"]; has {
			f.identity = jv_str(o, "identity")
			f.any_ident = false
			if !in_scope(c.scope, f.identity) {
				r := reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
				kit.jset_str(r, "identity", c.scope)
				kit.jset_str(r, "requested", f.identity)
				return r
			}
		} else if c.scope != "" {
			f.identity = c.scope
			f.any_ident = false
		}
		arr := kit.jarr()
		unread := 0
		for n in store_select(s, f) {
			kit.jpush(arr, note_json(n, now))
			if !n.read {
				unread += 1
			}
		}
		r := reply_ok()
		kit.jset(r, "notifications", arr)
		kit.jset_int(r, "count", kit.jlen(arr))
		kit.jset_int(r, "unread", unread)
		kit.jset_int(r, "rev", int(s.rev))
		kit.jset_bool(r, "dnd", s.dnd)
		return r

	case "policies":
		return policies_reply(d, c, now)

	case "quiet":
		return quiet_op(d, c, o, now)

	case "dnd":
		if c.scope != "" {
			return reply_err(kit.EXIT_OUT_OF_SCOPE, "do not disturb is the whole person's; inside an identity, use `notify quiet set \"do not disturb\"`")
		}
		on := jv_bool(o, "on")
		if jv_str(o, "toggle") == "true" {
			on = !s.dnd
		}
		mins := jv_int(o, "minutes")
		s.dnd = on
		s.dnd_until = on && mins > 0 ? now + mins * 60_000 : 0
		if on {
			// Nothing stays on screen through do-not-disturb, except a call
			// a policy lets through.
			for n in s.notes {
				if n.showing && !(is_call(n) && .Calls in policy_for(s, n.identity).breaks) {
					n.showing = false
				}
			}
		}
		touch(s)
		r := reply_ok()
		kit.jset_bool(r, "dnd", s.dnd)
		kit.jset_int(r, "until", int(s.dnd_until))
		return r

	case "status":
		return status_reply(d, c, now)

	case "watch":
		c.watch = true
		delete(c.role)
		delete(c.app)
		c.role = strings.clone(jv_str(o, "role"), runtime.default_allocator())
		c.app = strings.clone(jv_str(o, "app"), runtime.default_allocator())
		r := reply_ok()
		kit.jset_str(r, "ev", "rev")
		kit.jset_int(r, "rev", int(s.rev))
		return r

	case "focus":
		// The keyboard shortcut. The toasts take the keyboard if any are
		// up; otherwise the center opens.
		if has_showing(s) && has_role(d, "toasts") {
			ev := kit.jobj()
			kit.jset_str(ev, "ev", "focus")
			broadcast(d, ev)
			r := reply_ok()
			kit.jset_str(r, "focused", "toasts")
			return r
		}
		open_center(d, "")
		r := reply_ok()
		kit.jset_str(r, "focused", "center")
		return r

	case "center":
		open_center(d, jv_str(o, "identity"))
		return reply_ok()

	case "digest":
		ident := jv_str(o, "identity")
		if !in_scope(c.scope, ident) {
			return reply_err(kit.EXIT_OUT_OF_SCOPE, "not this identity's")
		}
		release(d, ident, "on request", now, false)
		return reply_ok()

	case "clock":
		if !d.test_clock {
			return reply_err(kit.EXIT_USAGE, "the clock can only be set on a daemon started with --clock or --test-clock")
		}
		if m, ok := parse_time(jv_str(o, "at")); ok {
			wall := wall_ms()
			cur := wall + d.clock_offset
			// Forward to the next occurrence of that minute: time in a test
			// only ever moves on, like real time.
			target := next_at(cur, d.tz, m)
			d.clock_offset = target - wall
		} else if ms := jv_int(o, "advance_ms"); ms > 0 {
			d.clock_offset += ms
		} else {
			return reply_err(kit.EXIT_USAGE, "clock needs at HH:MM or advance_ms")
		}
		r := reply_ok()
		kit.jset_str(r, "now", hhmm(local_minute(now_ms(d), d.tz)))
		return r
	}
	return reply_err(kit.EXIT_USAGE, fmt.tprintf("unknown op %q", op))
}

has_showing :: proc(s: ^Store) -> bool {
	for n in s.notes {
		if n.showing {
			return true
		}
	}
	return false
}

find_note :: proc(d: ^Daemon, o: json.Object) -> ^Note {
	if id := jv_int(o, "id"); id > 0 {
		n, _ := store_find_id(&d.store, u32(id))
		return n
	}
	if k := jv_str(o, "key"); k != "" {
		n, _ := store_find_key(&d.store, k)
		return n
	}
	return nil
}

// deliver is the one path every notification takes in, whichever door it
// came through: dedupe, policy, sound, and the reply the sender gets.
deliver :: proc(d: ^Daemon, n: ^Note, renotify: bool) -> (^kit.Json, Arrival) {
	now := now_ms(d)
	a := store_add(&d.store, n, now, d.tz, renotify)
	r := reply_ok()
	if a.dropped {
		kit.jset_bool(r, "dropped", true)
		kit.jset_str(r, "delivery", "none")
		kit.jset_str(r, "why", "Already delivered once and put away")
		return r, a
	}
	if a.sound && !a.replaced || a.sound && renotify {
		sound_play(d, a.note)
	}
	fmt.eprintfln(
		"palm-notifyd: #%d %s %s/%s [%s] %q -> %s (%s)%s",
		a.note.id,
		a.replaced ? "updated" : "new",
		a.note.app,
		a.note.identity != "" ? a.note.identity : "-",
		class_name(a.note.class),
		a.note.title,
		delivery_name(a.note.delivery),
		a.note.why,
		a.replaced && !renotify ? " (same key: no second toast)" : "",
	)
	kit.jset_int(r, "id", int(a.note.id))
	kit.jset_str(r, "key", a.note.key)
	kit.jset_str(r, "identity", a.note.identity)
	kit.jset_str(r, "class", class_name(a.note.class))
	kit.jset_str(r, "delivery", a.replaced && !renotify ? "updated" : delivery_name(a.note.delivery))
	kit.jset_str(r, "why", a.note.why)
	kit.jset_bool(r, "replaced", a.replaced)
	kit.jset_bool(r, "showing", a.note.showing)
	return r, a
}

policies_reply :: proc(d: ^Daemon, c: ^Client, now: i64) -> ^kit.Json {
	s := &d.store
	arr := kit.jarr()
	seen := make(map[string]bool)
	add :: proc(arr: ^kit.Json, d: ^Daemon, ident: string, now: i64) {
		p := policy_for(&d.store, ident)
		p.identity = ident
		o := policy_json(p, now, d.tz)
		hold := hold_of(p, d.store.dnd, now, d.tz)
		kit.jset_str(o, "hold", hold == .None ? "none" : (hold == .Quiet ? "quiet" : "dnd"))
		if end := hold_ends(p, d.store.dnd, d.store.dnd_until, now, d.tz); end > 0 {
			kit.jset_str(o, "hold_ends", hhmm(local_minute(end, d.tz)))
		}
		kit.jset_str(o, "color", fmt.tprintf("#%06x", identity_color(ident, false)))
		kit.jpush(arr, o)
	}
	for h in identity_handles() {
		if in_scope(c.scope, h) && !seen[h] {
			seen[h] = true
			add(arr, d, h, now)
		}
	}
	for p in s.policies {
		if p.identity != "*" && in_scope(c.scope, p.identity) && !seen[p.identity] {
			seen[p.identity] = true
			add(arr, d, p.identity, now)
		}
	}
	for n in s.notes {
		if n.identity != "" && in_scope(c.scope, n.identity) && !seen[n.identity] {
			seen[n.identity] = true
			add(arr, d, n.identity, now)
		}
	}
	r := reply_ok()
	kit.jset(r, "policies", arr)
	kit.jset_bool(r, "dnd", s.dnd)
	kit.jset_int(r, "dnd_until", int(s.dnd_until))
	kit.jset_str(r, "now", hhmm(local_minute(now, d.tz)))
	return r
}

quiet_op :: proc(d: ^Daemon, c: ^Client, o: json.Object, now: i64) -> ^kit.Json {
	s := &d.store
	ident := jv_str(o, "identity")
	if ident == "" {
		ident = c.scope
	}
	if ident == "" {
		ident = "*"
	}
	if !in_scope(c.scope, ident) {
		r := reply_err(kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("a caller inside %q cannot change %q's policy", c.scope, ident))
		kit.jset_str(r, "identity", c.scope)
		kit.jset_str(r, "requested", ident)
		return r
	}
	mode := jv_str(o, "mode")
	sentence := jv_str(o, "sentence")
	cur := policy_for(s, ident)
	cur.identity = ident
	switch mode {
	case "get":
		r := reply_ok()
		kit.jset(r, "policy", policy_json(cur, now, d.tz))
		return r
	case "clear":
		p := policy_default(strings.clone(ident, runtime.default_allocator()))
		policy_put(s, p)
		r := reply_ok()
		kit.jset(r, "policy", policy_json(p, now, d.tz))
		return r
	case "set", "add", "check":
		base := mode == "add" ? cur : policy_default(ident)
		p, perr, ok := policy_parse(sentence, base, now, d.tz)
		if !ok {
			r := reply_err(kit.EXIT_USAGE, fmt.tprintf("could not read “%s”: %s", perr.clause, perr.hint))
			kit.jset_str(r, "clause", perr.clause)
			return r
		}
		// policy_parse cloned `base` onto the heap, identity included, so
		// the store can keep `p` as it is.
		r := reply_ok()
		kit.jset(r, "policy", policy_json(p, now, d.tz))
		if mode == "check" {
			policy_free(&p)
			return r
		}
		policy_put(s, p)
		fmt.eprintfln("palm-notifyd: %s: %s", ident, policy_sentence(p, now, d.tz))
		return r
	}
	return reply_err(kit.EXIT_USAGE, "quiet mode is get, set, add, clear or check")
}

status_reply :: proc(d: ^Daemon, c: ^Client, now: i64) -> ^kit.Json {
	s := &d.store
	r := reply_ok()
	total, unread, showing, held := 0, 0, 0, 0
	for n in s.notes {
		if !in_scope(c.scope, n.identity) {
			continue
		}
		total += 1
		if !n.read {
			unread += 1
		}
		if n.showing {
			showing += 1
		}
		if n.held {
			held += 1
		}
	}
	kit.jset_int(r, "total", total)
	kit.jset_int(r, "unread", unread)
	kit.jset_int(r, "showing", showing)
	kit.jset_int(r, "held", held)
	kit.jset_bool(r, "dnd", s.dnd)
	kit.jset_int(r, "dnd_until", int(s.dnd_until))
	kit.jset_str(r, "now", hhmm(local_minute(now, d.tz)))
	kit.jset_bool(r, "test_clock", d.test_clock)
	kit.jset_str(r, "socket", d.sock_path)
	bus := "off"
	if !d.no_bus {
		bus = d.bus == nil ? "no session bus" : (d.bus_owned ? "org.freedesktop.Notifications" : "on the bus, name taken by another server")
	}
	kit.jset_str(r, "bus", bus)
	kit.jset_bool(r, "toasts_running", d.ui_pid > 0 || has_role(d, "toasts"))
	kit.jset_int(r, "sounds_played", d.sounds)
	kit.jset_str(r, "last_sound", d.sound_cmd)
	kit.jset_int(r, "watchers", len(d.clients))
	kit.jset_str(r, "scope", c.scope)
	kit.jset_int(r, "rev", int(s.rev))
	return r
}
