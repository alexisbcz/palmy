package palmd

// The wire: greetd's framing, palmd's requests.
//
//	<payload-length> <payload>
//	  payload-length: u32, native byte order
//	  payload:        a UTF-8 JSON object
//
// The framing is greetd-ipc(7)'s, the same palm-login speaks
// (distro/login/ipc.odin) and apps/greeter reads, so Palmframe has one way of
// talking to a root daemon over a unix socket rather than two.
//
// Requests:
//
//	{"op":"plan",  "action":"add|del|upgrade", "packages":[...]}
//	{"op":"apply", "action":"add|del|upgrade", "packages":[...], "plan_id":"..."}
//	{"op":"update"}
//
// Replies:
//
//	{"type":"plan", "plan_id":"...", "plan":{...palm's --dry-run --json plan...}}
//	{"type":"progress", "event":"fetch|remove|install|upgrade|reinstall", ...}
//	{"type":"log", "line":"..."}                 anything palm said that was not JSON
//	{"type":"result", "ok":true|false, "code":N, "error":"...", "plan"|"update":{...}}
//	{"type":"error", "error_type":"invalid|denied|busy|failed", "code":N, "error":"..."}
//
// What a client may say is deliberately small. It names an action from a
// closed set and a list of package names; it never supplies a flag, a path, a
// repository or anything else that reaches palm's argv. palmd builds that argv
// itself (palm_argv), and a name is accepted only if it matches
// [a-z0-9][a-z0-9+._-]* -- which also means no name can begin with '-' and be
// read by palm as an option.
//
// Read-only questions (search, info, list) are not here at all: apps/store
// runs `palm ... --json` as the user for those, because a query needs no root
// and a daemon that answers fewer questions has fewer ways to be wrong.

import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

// A request is a verb and at most a few dozen names; anything bigger is not
// the store talking.
MAX_FRAME :: 64 * 1024
MAX_PACKAGES :: 64
MAX_NAME :: 128

PALM_PATH :: "/usr/bin/palm"

Op :: enum u8 {
	None,
	Plan,
	Apply,
	Update,
}

Action :: enum u8 {
	None,
	Add,
	Del,
	Upgrade,
}

action_word :: proc(a: Action) -> string {
	switch a {
	case .Add:
		return "add"
	case .Del:
		return "del"
	case .Upgrade:
		return "upgrade"
	case .None:
	}
	return ""
}

Request :: struct {
	op:       Op,
	action:   Action,
	packages: []string,
	plan_id:  string,
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

// name_valid is the whole of what palmd believes about a package name:
// [a-z0-9][a-z0-9+._-]*, at most MAX_NAME bytes. palm's own rule is the same
// (distro/palm/PALMBUILD.md); it is repeated here rather than trusted there,
// because this is the line between a user and root.
name_valid :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_NAME {
		return false
	}
	for c, i in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9':
		case '+', '.', '_', '-':
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return true
}

// plan_id_valid: what plan_id_of produces, 32 lowercase hex digits.
plan_id_valid :: proc(s: string) -> bool {
	if len(s) != 32 {
		return false
	}
	for c in transmute([]u8)s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

@(private = "file")
jstr :: proc(obj: json.Object, key: string) -> (string, bool) {
	if v, ok := obj[key]; ok {
		if s, is := v.(json.String); is {
			return string(s), true
		}
	}
	return "", false
}

// parse_request decodes and validates one payload. `why` is empty when the
// request is acceptable, and otherwise is what the client is told.
parse_request :: proc(payload: string, allocator := context.allocator) -> (r: Request, why: string) {
	v, err := json.parse(transmute([]u8)payload, .JSON, true, context.temp_allocator)
	if err != nil {
		return r, "the request is not valid JSON"
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return r, "the request is not a JSON object"
	}
	for key in obj {
		switch key {
		case "op", "action", "packages", "plan_id":
		case:
			// An unknown key is refused rather than ignored: a client that
			// thinks it can pass "root" or "repo" should learn it cannot.
			return r, fmt.aprintf("unknown field %q", key, allocator = allocator)
		}
	}

	op, _ := jstr(obj, "op")
	switch op {
	case "plan":
		r.op = .Plan
	case "apply":
		r.op = .Apply
	case "update":
		r.op = .Update
		if len(obj) != 1 {
			return r, "update takes no other fields"
		}
		return r, ""
	case "":
		return r, "the request has no op"
	case:
		return r, fmt.aprintf("unknown op %q (plan, apply or update)", op, allocator = allocator)
	}

	action, _ := jstr(obj, "action")
	switch action {
	case "add":
		r.action = .Add
	case "del":
		r.action = .Del
	case "upgrade":
		r.action = .Upgrade
	case:
		return r, fmt.aprintf("unknown action %q (add, del or upgrade)", action, allocator = allocator)
	}

	names := make([dynamic]string, allocator)
	if pv, has := obj["packages"]; has {
		arr, is_arr := pv.(json.Array)
		if !is_arr {
			return r, "packages must be a list of names"
		}
		if len(arr) > MAX_PACKAGES {
			return r, fmt.aprintf("at most %d packages at once", MAX_PACKAGES, allocator = allocator)
		}
		for e in arr {
			s, is := e.(json.String)
			if !is {
				return r, "packages must be a list of names"
			}
			if !name_valid(string(s)) {
				return r, fmt.aprintf("%q is not a package name ([a-z0-9][a-z0-9+._-]*)", string(s), allocator = allocator)
			}
			dup := false
			for n in names {
				if n == string(s) {dup = true}
			}
			if !dup {
				append(&names, strings.clone(string(s), allocator))
			}
		}
	}
	r.packages = names[:]
	switch r.action {
	case .Add, .Del:
		if len(r.packages) == 0 {
			return r, fmt.aprintf("%s needs at least one package", action, allocator = allocator)
		}
	case .Upgrade:
		// palm upgrade upgrades the whole world; naming packages would
		// suggest a partial upgrade palm does not do.
		if len(r.packages) != 0 {
			return r, "upgrade takes no packages: it upgrades everything"
		}
	case .None:
	}

	if r.op == .Apply {
		id, _ := jstr(obj, "plan_id")
		if !plan_id_valid(id) {
			return r, "apply needs the plan_id of a plan from this daemon"
		}
		r.plan_id = strings.clone(id, allocator)
	} else if _, has := obj["plan_id"]; has {
		return r, "plan_id belongs to apply"
	}
	return r, ""
}

// ---------------------------------------------------------------------------
// palm's argv
// ---------------------------------------------------------------------------

// palm_argv is the only place an argv for palm is made. Every word in it is
// either a constant or a name that passed name_valid; nothing a client sent
// is copied in any other way. `dry` makes it a plan, otherwise it carries
// --yes (palm would refuse a removal without it, since there is no terminal to
// ask on). --json keeps stdout one document and puts progress on stderr.
palm_argv :: proc(palm: string, r: Request, dry: bool, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	append(&out, palm)
	switch r.op {
	case .Update:
		append(&out, "update", "--json")
		return out[:]
	case .Plan, .Apply:
		append(&out, action_word(r.action), "--json", dry ? "--dry-run" : "--yes")
		for n in r.packages {
			append(&out, n)
		}
	case .None:
	}
	return out[:]
}

// plan_id_of names a plan: a hash of what was asked and of the plan palm
// answered with. apply carries it back, and palmd plans again before running
// anything; if the new plan's id differs -- the repository moved, someone
// else installed something -- the apply is refused and the store shows the new
// plan instead. What a person confirmed is therefore exactly what runs.
plan_id_of :: proc(r: Request, plan_json: string, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n", action_word(r.action))
	for n in r.packages {
		fmt.sbprintf(&b, "%s\n", n)
	}
	strings.write_string(&b, strings.trim_space(plan_json))
	digest := hash.hash_string(.SHA256, strings.to_string(b), context.temp_allocator)
	DIGITS := "0123456789abcdef"
	out := make([]u8, 32, allocator)
	for i in 0 ..< 16 {
		out[i * 2] = DIGITS[digest[i] >> 4]
		out[i * 2 + 1] = DIGITS[digest[i] & 15]
	}
	return string(out)
}

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

json_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case:
			if ch < 0x20 {
				fmt.sbprintf(sb, "\\u%04x", int(ch))
			} else {
				strings.write_byte(sb, ch)
			}
		}
	}
	strings.write_byte(sb, '"')
}

reply_error :: proc(error_type: string, code: int, msg: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"error","error_type":`)
	json_quote(&sb, error_type)
	fmt.sbprintf(&sb, `,"code":%d,"error":`, code)
	json_quote(&sb, msg)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

reply_log :: proc(line: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"type":"log","line":`)
	json_quote(&sb, line)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// reply_progress wraps one of palm's progress objects. palm wrote it, palm's
// json_str escaped it, and it is checked to be a JSON object before it is
// spliced in, so a client always receives well-formed JSON.
reply_progress :: proc(palm_line: string, allocator := context.temp_allocator) -> (string, bool) {
	l := strings.trim_space(palm_line)
	if !json_object(l) {
		return "", false
	}
	return fmt.aprintf(`{{"type":"progress",%s`, l[1:], allocator = allocator), true
}

// json_object: is s exactly one JSON object?
json_object :: proc(s: string) -> bool {
	if len(s) < 2 || s[0] != '{' || s[len(s) - 1] != '}' {
		return false
	}
	v, err := json.parse(transmute([]u8)s, .JSON, true, context.temp_allocator)
	if err != nil {
		return false
	}
	_, is := v.(json.Object)
	return is
}

// palm_error digs palm's own message out of what it printed. Under --json palm
// reports failure as {"ok":false,"code":N,"error":"..."} on stdout; that text
// is passed to the store verbatim. Failing that, the last line palm wrote to
// stderr, which is where a crash or a loader error lands.
palm_error :: proc(stdout, stderr: string, code: int) -> string {
	lines := strings.split_lines(strings.trim_space(stdout), context.temp_allocator)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		l := strings.trim_space(lines[i])
		if !json_object(l) {continue}
		v, _ := json.parse(transmute([]u8)l, .JSON, true, context.temp_allocator)
		if obj, is := v.(json.Object); is {
			if s, has := jstr(obj, "error"); has {
				return s
			}
		}
	}
	errs := strings.split_lines(strings.trim_space(stderr), context.temp_allocator)
	for i := len(errs) - 1; i >= 0; i -= 1 {
		l := strings.trim_space(errs[i])
		if l != "" && !json_object(l) {
			return l
		}
	}
	return fmt.tprintf("palm exited with status %d", code)
}

// palm_document is the first JSON object palm printed on stdout: the plan
// for add, del and upgrade, the repository list for update.
palm_document :: proc(stdout: string) -> string {
	for line in strings.split_lines(stdout, context.temp_allocator) {
		l := strings.trim_space(line)
		if json_object(l) && !strings.has_prefix(l, `{"ok":false`) {
			return l
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

write_all :: proc(fd: linux.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		// MSG_NOSIGNAL: a store that quits mid-reply must not take the
		// daemon down with SIGPIPE.
		n, e := linux.send(fd, buf[off:], {.NOSIGNAL})
		if e == .EINTR {
			continue
		}
		if e == .EAGAIN {
			// The socket is non-blocking and the client is slow; a progress
			// stream is small, so wait for room rather than drop a frame.
			pfd := [1]linux.Poll_Fd{{fd = fd, events = {.OUT}}}
			if _, pe := linux.poll(pfd[:], 2000); pe != .NONE && pe != .EINTR {
				return false
			}
			if .OUT not_in pfd[0].revents {
				return false
			}
			continue
		}
		if e != .NONE || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

send_frame :: proc(fd: linux.Fd, payload: string) -> bool {
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	return write_all(fd, hdr[:]) && write_all(fd, transmute([]u8)payload)
}

// next_frame takes one complete payload off the front of `buf`, if one has
// arrived. `bad` reports a length no client of ours would send.
next_frame :: proc(buf: ^[dynamic]u8, allocator := context.temp_allocator) -> (payload: string, ok: bool, bad: bool) {
	if len(buf) < 4 {
		return "", false, false
	}
	hdr: [4]u8
	copy(hdr[:], buf[:4])
	n := int(transmute(u32)hdr)
	if n <= 0 || n > MAX_FRAME {
		return "", false, true
	}
	if len(buf) < 4 + n {
		return "", false, false
	}
	payload = strings.clone(string(buf[4:4 + n]), allocator)
	remove_range(buf, 0, 4 + n)
	return payload, true, false
}
