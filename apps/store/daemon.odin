package main

// Changing the system: a conversation with palmd.
//
// Software runs as the user and cannot install anything itself. palmd
// (distro/palmd) does it for root and group wheel, over /run/palmd.sock with
// greetd's framing: a native-endian u32 length, then JSON. A change is always
// the same three steps, and the window shows each one:
//
//	plan      {"op":"plan","action":"add","packages":["track"]}
//	          <- {"type":"plan","plan_id":"...","plan":{install,upgrade,remove,...}}
//	          the confirmation dialog shows exactly that plan
//	apply     {"op":"apply",...,"plan_id":"..."}
//	          <- {"type":"progress",...}* {"type":"log",...}*
//	          <- {"type":"result","ok":...,"error":"..."}
//
// palmd plans again before applying and refuses if the plan changed, so what
// a person confirmed is what runs. Errors are palm's own words, shown as they
// arrive. The socket is non-blocking and polled once a frame, so the window
// keeps drawing -- and the progress bar keeps moving -- while palm works.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

PALMD_SOCK :: "/run/palmd.sock"

Action :: enum u8 {
	Add,
	Del,
	Upgrade,
	Update, // refresh the indexes: no plan, straight to running
}

action_word :: proc(a: Action) -> string {
	switch a {
	case .Add:
		return "add"
	case .Del:
		return "del"
	case .Upgrade:
		return "upgrade"
	case .Update:
		return "update"
	}
	return ""
}

Txn_Stage :: enum u8 {
	Idle,
	Planning, // waiting for palmd's plan
	Confirm, // the plan is on screen; nothing has happened yet
	Applying, // palm is running
	Done,
	Failed,
}

Plan_Item :: struct {
	name:    string,
	version: string,
	from:    string, // upgrades only
	size:    i64,
	csize:   i64,
}

Plan :: struct {
	install:     []Plan_Item,
	upgrade:     []Plan_Item,
	remove:      []Plan_Item,
	download:    i64,
	size_change: i64,
}

Txn :: struct {
	stage:    Txn_Stage,
	action:   Action,
	packages: []string,
	plan:     Plan,
	plan_id:  string,
	step:     int,
	steps:    int,
	current:  string, // what palm is doing, in words
	log:      [dynamic]string, // palm's warnings, verbatim
	error:    string, // palm's (or palmd's) message, verbatim
	code:     int,
	fd:       linux.Fd,
	inbuf:    [dynamic]u8,
	// --demo: no socket; demo.odin plays palmd's part
	demo:     bool,
	demo_at:  f64,
}

plan_empty :: proc(p: Plan) -> bool {
	return len(p.install) == 0 && len(p.upgrade) == 0 && len(p.remove) == 0
}

palmd_sock :: proc() -> string {
	if v := os.get_env("PALMD_SOCK", context.temp_allocator); v != "" {
		return v
	}
	return PALMD_SOCK
}

// txn_begin starts a change: a plan request, or for update the run itself.
txn_begin :: proc(t: ^Txn, action: Action, packages: []string) {
	txn_reset(t)
	t.action = action
	t.packages = clone_strings(packages)
	if t.demo {
		demo_begin(t)
		return
	}
	fd, why := dial_palmd(palmd_sock())
	if why != "" {
		txn_fail(t, why, 6)
		return
	}
	t.fd = fd
	req: string
	if action == .Update {
		req = `{"op":"update"}`
		t.stage = .Applying
		t.current = strings.clone("Checking the repositories")
	} else {
		req = request_json("plan", action, packages, "")
		t.stage = .Planning
	}
	if !send_frame(t.fd, req) {
		txn_fail(t, "palmd closed the connection", 6)
	}
}

// txn_confirm is the person saying yes to the plan on screen.
txn_confirm :: proc(t: ^Txn) {
	if t.stage != .Confirm {
		return
	}
	t.stage = .Applying
	t.step, t.steps = 0, 0
	t.current = strings.clone("Starting")
	if t.demo {
		demo_confirm(t)
		return
	}
	if !send_frame(t.fd, request_json("apply", t.action, t.packages, t.plan_id)) {
		txn_fail(t, "palmd closed the connection", 6)
	}
}

// txn_cancel closes a plan nobody confirmed. Nothing has changed: palmd only
// planned.
txn_cancel :: proc(t: ^Txn) {
	if t.stage == .Applying {
		return // palm is running; it finishes whether anyone watches or not
	}
	txn_reset(t)
}

txn_reset :: proc(t: ^Txn) {
	if t.fd > 0 {
		linux.close(t.fd)
	}
	demo := t.demo
	delete(t.log)
	delete(t.inbuf)
	t^ = {}
	t.demo = demo
}

txn_fail :: proc(t: ^Txn, msg: string, code: int) {
	t.stage = .Failed
	t.error = strings.clone(msg)
	t.code = code
	if t.fd > 0 {
		linux.close(t.fd)
		t.fd = 0
	}
}

// txn_busy: something is on screen that wants the frame loop running.
txn_busy :: proc(t: ^Txn) -> bool {
	return t.stage == .Planning || t.stage == .Applying
}

request_json :: proc(op: string, action: Action, packages: []string, plan_id: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"op":"%s","action":"%s","packages":[`, op, action_word(action))
	for n, i in packages {
		if i > 0 {strings.write_byte(&b, ',')}
		json_quote(&b, n)
	}
	strings.write_byte(&b, ']')
	if plan_id != "" {
		fmt.sbprintf(&b, `,"plan_id":"%s"`, plan_id)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

json_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		switch s[i] {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case:
			if s[i] < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", int(s[i]))
			} else {
				strings.write_byte(sb, s[i])
			}
		}
	}
	strings.write_byte(sb, '"')
}

clone_strings :: proc(in_: []string) -> []string {
	out := make([]string, len(in_))
	for s, i in in_ {
		out[i] = strings.clone(s)
	}
	return out
}

// ---------------------------------------------------------------------------
// The socket
// ---------------------------------------------------------------------------

dial_palmd :: proc(path: string) -> (fd: linux.Fd, why: string) {
	s, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return 0, fmt.tprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if ce := linux.connect(s, &addr); ce != .NONE {
		linux.close(s)
		if ce == .ENOENT || ce == .ECONNREFUSED {
			return 0, fmt.tprintf("palmd is not running (%s: %v). It is started by palm-init from /etc/palm/services/palmd.", path, ce)
		}
		return 0, fmt.tprintf("cannot reach palmd at %s: %v", path, ce)
	}
	// Non-blocking from here on: the frame loop polls, it never waits.
	fl, _ := linux.fcntl_getfl(s, .GETFL)
	linux.fcntl_setfl(s, .SETFL, fl + {.NONBLOCK})
	return s, ""
}

send_frame :: proc(fd: linux.Fd, payload: string) -> bool {
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	buf := make([]u8, 4 + len(payload), context.temp_allocator)
	copy(buf, hdr[:])
	copy(buf[4:], payload)
	off := 0
	for off < len(buf) {
		w, e := linux.send(fd, buf[off:], {.NOSIGNAL})
		if e == .EINTR || e == .EAGAIN {
			continue
		}
		if e != .NONE || w <= 0 {
			return false
		}
		off += w
	}
	return true
}

next_frame :: proc(buf: ^[dynamic]u8) -> (payload: string, ok: bool, bad: bool) {
	if len(buf) < 4 {
		return "", false, false
	}
	hdr: [4]u8
	copy(hdr[:], buf[:4])
	n := int(transmute(u32)hdr)
	if n <= 0 || n > 1 << 20 {
		return "", false, true
	}
	if len(buf) < 4 + n {
		return "", false, false
	}
	payload = strings.clone(string(buf[4:4 + n]), context.temp_allocator)
	remove_range(buf, 0, 4 + n)
	return payload, true, false
}

// txn_poll reads whatever palmd has said since the last frame. It returns
// true when the transaction just finished, so the caller reloads.
txn_poll :: proc(t: ^Txn, now: f64) -> (finished: bool) {
	if t.demo {
		return demo_poll(t, now)
	}
	if !txn_busy(t) || t.fd <= 0 {
		return false
	}
	for {
		// Ask first: the frame loop must never block on palmd, whatever
		// mode the socket is in.
		pfd := [1]linux.Poll_Fd{{fd = t.fd, events = {.IN}}}
		if r, _ := linux.poll(pfd[:], 0); r <= 0 {
			break
		}
		chunk: [4096]u8
		n, e := linux.read(t.fd, chunk[:])
		if e == .EAGAIN || e == .EINTR {
			break
		}
		if e != .NONE || n <= 0 {
			if t.stage == .Applying {
				txn_fail(t, "palmd closed the connection before palm finished; see /var/log/palmd.log", 7)
				return true
			}
			txn_fail(t, "palmd closed the connection", 6)
			return false
		}
		append(&t.inbuf, ..chunk[:n])
	}
	for {
		payload, got, bad := next_frame(&t.inbuf)
		if bad {
			txn_fail(t, "palmd sent a frame this version cannot read", 7)
			return false
		}
		if !got {
			return false
		}
		if txn_handle(t, payload) {
			return true
		}
	}
}

// txn_handle applies one reply. True when the transaction is over.
txn_handle :: proc(t: ^Txn, payload: string) -> bool {
	v, err := json.parse(transmute([]u8)payload, .JSON, true, context.temp_allocator)
	if err != nil {
		return false
	}
	obj, is := v.(json.Object)
	if !is {
		return false
	}
	kind, _ := obj["type"].(json.String)
	switch string(kind) {
	case "plan":
		id, _ := obj["plan_id"].(json.String)
		t.plan_id = strings.clone(string(id))
		if po, isp := obj["plan"].(json.Object); isp {
			t.plan = plan_from_json(po)
		}
		t.stage = .Confirm
	case "progress":
		ev, _ := obj["event"].(json.String)
		name, _ := obj["name"].(json.String)
		ver, _ := obj["version"].(json.String)
		t.step = int(num(obj, "step"))
		t.steps = int(num(obj, "steps"))
		delete(t.current)
		t.current = strings.clone(progress_words(string(ev), string(name), string(ver)))
	case "log":
		line, _ := obj["line"].(json.String)
		append(&t.log, strings.clone(string(line)))
	case "result":
		ok, _ := obj["ok"].(json.Boolean)
		if ok {
			t.stage = .Done
			if t.steps > 0 {t.step = t.steps}
		} else {
			msg, _ := obj["error"].(json.String)
			txn_fail(t, string(msg), int(num(obj, "code")))
			if po, isp := obj["plan"].(json.Object); isp {
				// palmd refused because the plan moved; show the new one so
				// the person can see why.
				t.plan = plan_from_json(po)
			}
		}
		if t.fd > 0 {
			linux.close(t.fd)
			t.fd = 0
		}
		return true
	case "error":
		msg, _ := obj["error"].(json.String)
		txn_fail(t, string(msg), int(num(obj, "code")))
		return true
	}
	return false
}

num :: proc(obj: json.Object, key: string) -> i64 {
	#partial switch v in obj[key] {
	case json.Integer:
		return i64(v)
	case json.Float:
		return i64(v)
	}
	return 0
}

plan_from_json :: proc(obj: json.Object) -> Plan {
	items :: proc(obj: json.Object, key: string) -> []Plan_Item {
		out := make([dynamic]Plan_Item)
		if arr, ok := obj[key].(json.Array); ok {
			for e in arr {
				o, is := e.(json.Object)
				if !is {continue}
				it: Plan_Item
				n, _ := o["name"].(json.String)
				it.name = strings.clone(string(n))
				if v, has := o["version"].(json.String); has {
					it.version = strings.clone(string(v))
				}
				if v, has := o["to"].(json.String); has {
					it.version = strings.clone(string(v))
				}
				if v, has := o["from"].(json.String); has {
					it.from = strings.clone(string(v))
				}
				it.size = num(o, "size")
				it.csize = num(o, "csize")
				append(&out, it)
			}
		}
		return out[:]
	}
	p: Plan
	p.install = items(obj, "install")
	p.upgrade = items(obj, "upgrade")
	p.remove = items(obj, "remove")
	p.download = num(obj, "download_size")
	p.size_change = num(obj, "size_change")
	return p
}

progress_words :: proc(event, name, version: string) -> string {
	v := version_short(version)
	switch event {
	case "fetch":
		return fmt.tprintf("Downloading %s %s", name, v)
	case "install":
		return fmt.tprintf("Installing %s %s", name, v)
	case "upgrade":
		return fmt.tprintf("Updating %s to %s", name, v)
	case "reinstall":
		return fmt.tprintf("Reinstalling %s %s", name, v)
	case "remove":
		return fmt.tprintf("Removing %s %s", name, v)
	}
	return fmt.tprintf("%s %s", event, name)
}

// plan_sentence is the plan in one line, for the dialog's description and
// the CLI: "will install track, emoji; will remove shop; download 1.2 MB".
plan_sentence :: proc(p: Plan) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	names :: proc(items: []Plan_Item) -> string {
		ns := make([dynamic]string, context.temp_allocator)
		for it in items {append(&ns, it.name)}
		return strings.join(ns[:], ", ", context.temp_allocator)
	}
	if len(p.install) > 0 {append(&parts, fmt.tprintf("will install %s", names(p.install)))}
	if len(p.upgrade) > 0 {append(&parts, fmt.tprintf("will update %s", names(p.upgrade)))}
	if len(p.remove) > 0 {append(&parts, fmt.tprintf("will remove %s", names(p.remove)))}
	if p.download > 0 {append(&parts, fmt.tprintf("download %s", human_size(p.download)))}
	if len(parts) == 0 {
		return "nothing to do"
	}
	return strings.join(parts[:], "; ", context.temp_allocator)
}
