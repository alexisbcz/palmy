// JSON in and out: one notification, one policy, and the files the daemon
// keeps between sessions.
//
// The same objects travel on the socket (apps/kit/notify.odin speaks them),
// come out of `notify list --json`, and sit in the state files, so there is
// one spelling of a notification everywhere.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

note_json :: proc(n: ^Note, now: i64, allocator := context.temp_allocator) -> ^kit.Json {
	context.allocator = allocator
	o := kit.jobj()
	kit.jset_int(o, "id", int(n.id))
	kit.jset_str(o, "key", n.key)
	kit.jset_str(o, "app", n.app)
	kit.jset_str(o, "app_label", app_label(n.app))
	kit.jset_str(o, "identity", n.identity)
	kit.jset_str(o, "identity_name", identity_name(n.identity))
	kit.jset_str(o, "class", class_name(n.class))
	kit.jset_str(o, "urgency", urgency_name(n.urgency))
	if n.category != "" {
		kit.jset_str(o, "category", n.category)
	}
	kit.jset_str(o, "title", n.title)
	kit.jset_str(o, "body", n.body)
	if n.link != "" {
		kit.jset_str(o, "link", n.link)
	}
	acts := kit.jarr()
	for a in n.actions {
		ao := kit.jobj()
		kit.jset_str(ao, "key", a.key)
		kit.jset_str(ao, "label", a.label)
		if a.run != "" {
			kit.jset_str(ao, "run", a.run)
		}
		kit.jpush(acts, ao)
	}
	kit.jset(o, "actions", acts)
	kit.jset_str(o, "source", source_name(n.source))
	kit.jset_int(o, "created", int(n.created))
	kit.jset_int(o, "updated", int(n.updated))
	if n.timeout_ms != 0 {
		kit.jset_int(o, "timeout_ms", n.timeout_ms)
	}
	kit.jset_str(o, "delivery", delivery_name(n.delivery))
	kit.jset_str(o, "why", n.why)
	kit.jset_bool(o, "showing", n.showing)
	kit.jset_bool(o, "held", n.held)
	if n.digest != "" {
		kit.jset_str(o, "digest", n.digest)
	}
	kit.jset_bool(o, "read", n.read)
	if n.is_digest {
		kit.jset_bool(o, "is_digest", true)
		kit.jset_int(o, "count", n.count)
	}
	kit.jset_str(o, "spoken", spoken(n))
	if n.fdo_sender != "" {
		kit.jset_str(o, "fdo_sender", n.fdo_sender)
	}
	return o
}

// spoken is the accessible text of a notification: everything a screen
// reader needs, in the order a person would say it, with no colour and no
// icon carrying meaning on its own. It goes out with every notification
// (`spoken` in the JSON) and is what the toast surface announces.
spoken :: proc(n: ^Note) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if n.is_digest {
		fmt.sbprintf(&sb, "Digest")
	} else {
		switch n.class {
		case .Person:
			strings.write_string(&sb, is_call(n) ? "Incoming call" : "Message")
		case .Time:
			strings.write_string(&sb, "Reminder")
		case .Machine:
			strings.write_string(&sb, "Notice")
		}
	}
	fmt.sbprintf(&sb, " from %s", app_label(n.app))
	if n.identity != "" {
		fmt.sbprintf(&sb, ", %s identity", identity_name(n.identity))
	}
	if n.urgency == .Critical {
		strings.write_string(&sb, ", urgent")
	}
	fmt.sbprintf(&sb, ". %s.", strings.trim_right(n.title, "."))
	if n.body != "" {
		fmt.sbprintf(&sb, " %s", strings.trim_space(n.body))
		if !strings.has_suffix(strings.trim_space(n.body), ".") {
			strings.write_string(&sb, ".")
		}
	}
	labels := make([dynamic]string, context.temp_allocator)
	for a in n.actions {
		if a.key != "default" && a.label != "" {
			append(&labels, a.label)
		}
	}
	if len(labels) > 0 {
		fmt.sbprintf(&sb, " Actions: %s.", strings.join(labels[:], ", ", context.temp_allocator))
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

jv_str :: proc(o: json.Object, key: string) -> string {
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

jv_int :: proc(o: json.Object, key: string, def: i64 = 0) -> i64 {
	if v, ok := o[key]; ok {
		#partial switch x in v {
		case json.Integer:
			return x
		case json.Float:
			return i64(x)
		case json.String:
			n := i64(0)
			for ch in string(x) {
				if ch < '0' || ch > '9' {
					return def
				}
				n = n * 10 + i64(ch - '0')
			}
			return n
		}
	}
	return def
}

jv_bool :: proc(o: json.Object, key: string) -> bool {
	if v, ok := o[key]; ok {
		#partial switch x in v {
		case json.Boolean:
			return x
		case json.String:
			return x == "true"
		case json.Integer:
			return x != 0
		}
	}
	return false
}

jv_obj :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	if v, ok := o[key]; ok {
		if x, isobj := v.(json.Object); isobj {
			return x, true
		}
	}
	return nil, false
}

jv_arr :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	if v, ok := o[key]; ok {
		if x, isarr := v.(json.Array); isarr {
			return x, true
		}
	}
	return nil, false
}

// note_from_json reads what a sender sent into a temporary Note (strings
// point into the parsed document; store_add clones what it keeps).
note_from_json :: proc(o: json.Object) -> (n: Note, why: string) {
	n.key = jv_str(o, "key")
	n.app = jv_str(o, "app")
	n.identity = jv_str(o, "identity")
	n.category = jv_str(o, "category")
	n.title = jv_str(o, "title")
	n.body = jv_str(o, "body")
	n.link = jv_str(o, "link")
	n.timeout_ms = int(jv_int(o, "timeout_ms"))
	u, uok := urgency_parse(jv_str(o, "urgency"))
	if !uok {
		return n, "urgency is low, normal or critical"
	}
	n.urgency = u
	if c := jv_str(o, "class"); c != "" {
		cl, ok := class_parse(c)
		if !ok {
			return n, "class is person, time or machine"
		}
		n.class = cl
	} else {
		n.class = class_for_category(n.category, n.urgency)
	}
	n.actions = make([dynamic]Action, context.temp_allocator)
	if arr, ok := jv_arr(o, "actions"); ok {
		for v in arr {
			if a, isobj := v.(json.Object); isobj {
				append(&n.actions, Action{jv_str(a, "key"), jv_str(a, "label"), jv_str(a, "run")})
			}
		}
	}
	if n.title == "" {
		return n, "a notification needs a title"
	}
	if len(n.key) > 512 || len(n.title) > 1024 || len(n.body) > 8192 {
		return n, "too long"
	}
	return n, ""
}

// ---------------------------------------------------------------------------
// Policies as structured data
// ---------------------------------------------------------------------------

policy_json :: proc(p: Policy, now, tz: i64, allocator := context.temp_allocator) -> ^kit.Json {
	context.allocator = allocator
	o := kit.jobj()
	kit.jset_str(o, "identity", p.identity)
	kit.jset_str(o, "identity_name", p.identity == "*" ? "Everything else" : identity_name(p.identity))
	kit.jset_str(o, "sentence", policy_sentence(p, now, tz))
	q := kit.jobj()
	if p.quiet_from >= 0 {
		kit.jset_str(q, "from", hhmm(p.quiet_from))
		kit.jset_str(q, "to", hhmm(p.quiet_to))
	}
	kit.jset(o, "quiet_hours", p.quiet_from >= 0 ? q : kit.jnull())
	kit.jset_int(o, "quiet_until", int(p.quiet_until > now ? p.quiet_until : 0))
	kit.jset_int(o, "awake_until", int(p.awake_until > now ? p.awake_until : 0))
	kit.jset_int(o, "dnd_until", int(p.dnd_until == -1 || p.dnd_until > now ? p.dnd_until : 0))
	kit.jset_bool(o, "people_only", p.people_only)
	kit.jset(o, "digest_at", p.digest_at >= 0 ? kit.jstr(hhmm(p.digest_at)) : kit.jnull())
	br := kit.jarr()
	if .Calls in p.breaks {
		kit.jpush(br, kit.jstr("calls"))
	}
	if .Alarms in p.breaks {
		kit.jpush(br, kit.jstr("alarms"))
	}
	if .Reminders in p.breaks {
		kit.jpush(br, kit.jstr("reminders"))
	}
	kit.jset(o, "breaks_through", br)
	apps := kit.jobj()
	for r in p.apps {
		mode := "default"
		switch r.mode {
		case .Muted:
			mode = "muted"
		case .Digest:
			mode = "digest"
		case .Always:
			mode = "always"
		case .Default:
		}
		kit.jset_str(apps, r.app, mode)
	}
	kit.jset(o, "apps", apps)
	return o
}

policy_from_json :: proc(o: json.Object) -> Policy {
	p := policy_default(strings.clone(jv_str(o, "identity")))
	if q, ok := jv_obj(o, "quiet_hours"); ok {
		a, ga := parse_time(jv_str(q, "from"))
		b, gb := parse_time(jv_str(q, "to"))
		if ga && gb {
			p.quiet_from, p.quiet_to = a, b
		}
	}
	p.quiet_until = jv_int(o, "quiet_until")
	p.awake_until = jv_int(o, "awake_until")
	p.dnd_until = jv_int(o, "dnd_until")
	p.people_only = jv_bool(o, "people_only")
	if m, ok := parse_time(jv_str(o, "digest_at")); ok {
		p.digest_at = m
	}
	if br, ok := jv_arr(o, "breaks_through"); ok {
		p.breaks = {}
		for v in br {
			if s, iss := v.(json.String); iss {
				switch s {
				case "calls":
					p.breaks += {.Calls}
				case "alarms":
					p.breaks += {.Alarms}
				case "reminders":
					p.breaks += {.Reminders}
				}
			}
		}
	}
	p.apps = make([dynamic]App_Rule)
	if apps, ok := jv_obj(o, "apps"); ok {
		for k, v in apps {
			mode := App_Mode.Default
			if s, iss := v.(json.String); iss {
				switch s {
				case "muted":
					mode = .Muted
				case "digest":
					mode = .Digest
				case "always":
					mode = .Always
				}
			}
			if mode != .Default {
				append(&p.apps, App_Rule{strings.clone(k), mode})
			}
		}
	}
	return p
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

state_dir :: proc() -> string {
	if d := os.get_env("PALM_NOTIFY_STATE", context.temp_allocator); d != "" {
		return d
	}
	base := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if base == "" {
		base = fmt.tprintf("%s/.local/state", os.get_env("HOME", context.temp_allocator))
	}
	return fmt.tprintf("%s/palm/notify", base)
}

config_dir :: proc() -> string {
	if d := os.get_env("PALM_NOTIFY_CONFIG", context.temp_allocator); d != "" {
		return d
	}
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base == "" {
		base = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	return fmt.tprintf("%s/palm/notify", base)
}

write_atomic :: proc(path: string, text: string) -> bool {
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]u8)text) != nil {
		return false
	}
	return os.rename(tmp, path) == nil
}

// store_save writes the history (state) and the policies (configuration).
// The policy file is the one other programs may read: Home shows each
// identity's sentence from it, and it is meant to be readable by a person.
store_save :: proc(s: ^Store, now, tz: i64) {
	h := kit.jobj(context.temp_allocator)
	kit.jset_int(h, "version", 1, context.temp_allocator)
	kit.jset_int(h, "next_id", int(s.next_id), context.temp_allocator)
	kit.jset_bool(h, "dnd", s.dnd, context.temp_allocator)
	kit.jset_int(h, "dnd_until", int(s.dnd_until), context.temp_allocator)
	arr := kit.jarr(context.temp_allocator)
	for n in s.notes {
		kit.jpush(arr, note_json(n, now))
	}
	kit.jset(h, "notes", arr, context.temp_allocator)
	tomb := kit.jobj(context.temp_allocator)
	for k, v in s.tombstones {
		kit.jset_int(tomb, k, int(v), context.temp_allocator)
	}
	kit.jset(h, "tombstones", tomb, context.temp_allocator)
	write_atomic(fmt.tprintf("%s/history.json", state_dir()), kit.json_text(h, 1, context.temp_allocator))

	pol := kit.jobj(context.temp_allocator)
	kit.jset_int(pol, "version", 1, context.temp_allocator)
	parr := kit.jarr(context.temp_allocator)
	for p in s.policies {
		kit.jpush(parr, policy_json(p, now, tz))
	}
	kit.jset(pol, "policies", parr, context.temp_allocator)
	write_atomic(fmt.tprintf("%s/policies.json", config_dir()), kit.json_text(pol, 2, context.temp_allocator))
}

store_load :: proc(s: ^Store) {
	if data, err := os.read_entire_file(fmt.tprintf("%s/policies.json", config_dir()), context.temp_allocator); err == nil {
		if v, perr := json.parse(data, allocator = context.temp_allocator); perr == nil {
			if root, ok := v.(json.Object); ok {
				if arr, has := jv_arr(root, "policies"); has {
					for pv in arr {
						if po, isobj := pv.(json.Object); isobj {
							p := policy_from_json(po)
							if p.identity != "" {
								append(&s.policies, p)
							} else {
								policy_free(&p)
							}
						}
					}
				}
			}
		}
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/history.json", state_dir()), context.temp_allocator)
	if err != nil {
		return
	}
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		return
	}
	root, ok := v.(json.Object)
	if !ok {
		return
	}
	s.next_id = u32(max(jv_int(root, "next_id", 1), 1))
	s.dnd = jv_bool(root, "dnd")
	s.dnd_until = jv_int(root, "dnd_until")
	if arr, has := jv_arr(root, "notes"); has {
		for nv in arr {
			o, isobj := nv.(json.Object)
			if !isobj {
				continue
			}
			tmp, why := note_from_json(o)
			if why != "" {
				continue
			}
			tmp.id = u32(jv_int(o, "id"))
			tmp.why = jv_str(o, "why")
			tmp.digest = jv_str(o, "digest")
			tmp.fdo_sender = ""
			n := note_clone(&tmp)
			n.created = jv_int(o, "created")
			n.updated = jv_int(o, "updated")
			switch jv_str(o, "delivery") {
			case "toast":
				n.delivery = .Toast
			case "digest":
				n.delivery = .Digest
			case:
				n.delivery = .Center
			}
			switch jv_str(o, "source") {
			case "fdo":
				n.source = .Fdo
			case "cli":
				n.source = .Cli
			case "system":
				n.source = .System
			}
			n.held = jv_bool(o, "held")
			n.read = jv_bool(o, "read")
			n.is_digest = jv_bool(o, "is_digest")
			n.count = int(jv_int(o, "count"))
			// A toast from a previous session is not put back on screen: it
			// went by, and it is in the center.
			n.showing = false
			append(&s.notes, n)
			if n.id >= s.next_id {
				s.next_id = n.id + 1
			}
		}
	}
	if tomb, has := jv_obj(root, "tombstones"); has {
		for k, tv in tomb {
			until := i64(0)
			#partial switch x in tv {
			case json.Float:
				until = i64(x)
			case json.Integer:
				until = x
			}
			s.tombstones[strings.clone(k)] = until
		}
	}
}
