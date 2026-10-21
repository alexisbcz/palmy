// Notifications, for every app: `kit.notify(...)`.
//
// One call, no bus, no library: the session's notification service
// (palm-notifyd, apps/notify) listens on a unix socket and takes one JSON
// object per line. What happens to a notification after that -- a toast, the
// center, a digest, nothing because the identity is quiet -- is the policy's
// business, said in a sentence the person wrote, and never the app's. An app
// says *what* happened and *who* is behind it; it does not decide whether to
// interrupt.
//
//	kit.notify({
//		key      = fmt.tprintf("mail:%s", message_id), // the same object, the same key
//		app      = "mail",
//		class    = .Person,                            // a person wrote to you
//		title    = "Priya Shah",
//		body     = "Q4 roadmap: can you sign off by Friday?",
//		link     = fmt.tprintf("mail open %s", message_id),
//		actions  = {{key = "reply", label = "Reply", run = fmt.tprintf("mail reply %s", message_id)}},
//	})
//
// The rules that make "delivered once" work:
//
//   - **The key names the object, not the notification.** `mail:<Message-ID>`,
//     `event:<uid>@<start>`, `call:<call-id>`. Two apps announcing the same
//     object use the same key, and the second is an update, not a second
//     toast. Sending the same key again updates the words in place; it
//     interrupts again only with `renotify`.
//   - **Withdraw when it stops mattering**: the call was answered on the
//     phone, the mail was read in Mail. `kit.notify_withdraw(key)`.
//   - **The identity is yours unless you say otherwise.** Empty means the
//     process's own PALM_IDENTITY (the daemon reads it from the sender's
//     environment). Naming another identity from inside one is refused.
//
// Every call returns quickly and never blocks the frame: a missing daemon is
// `ok = false`, which an app should ignore -- a notification is not worth an
// error dialog.
package kit

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import p "palmy:."

Notify_Class :: enum u8 {
	Person, // a message addressed to you, a mention, a call: interrupts
	Time, // an event starting, a task due, an alarm: interrupts at its time
	Machine, // receipts, CI, sync, updates, downloads: never interrupts
}

Notify_Urgency :: enum u8 {
	Normal,
	Low,
	Critical, // an incoming call, an alarm: may break through quiet, if allowed
}

Notify_Action :: struct {
	key:   string, // "default" is the click on the body
	label: string, // what the button says
	run:   string, // a deep link, run as the notification's identity: "mail reply 42"
}

Notification :: struct {
	key:        string, // stable: names the object ("mail:<Message-ID>")
	app:        string, // the app's command name: "mail", "calendar"
	identity:   string, // "" = this process's PALM_IDENTITY
	class:      Notify_Class,
	urgency:    Notify_Urgency,
	category:   string, // freedesktop-style, optional: "call.incoming", "email.arrived"
	title:      string, // required: who or what, short
	body:       string,
	link:       string, // what a click on the body runs: "mail open 42"
	actions:    []Notify_Action,
	timeout_ms: int, // 0: by class
	renotify:   bool, // same key, and this really is news: interrupt again
}

Notify_Result :: struct {
	ok:       bool,
	id:       u32,
	delivery: string, // toast | center | digest | updated | none
	why:      string, // the policy's reason, in words; temp-allocated
	error:    string, // when !ok: "unavailable", "out of scope", "usage"
}

// notify_socket_path is where palm-notifyd listens.
notify_socket_path :: proc(allocator := context.temp_allocator) -> string {
	if p := os.get_env("PALM_NOTIFY_SOCKET", context.temp_allocator); p != "" {
		return strings.clone(p, allocator)
	}
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		rt = fmt.tprintf("/tmp/palm-%d", posix.getuid())
	}
	return fmt.aprintf("%s/palm/notify.sock", rt, allocator = allocator)
}

// notify_connect opens a connection to the daemon, or -1.
notify_connect :: proc() -> linux.Fd {
	path := notify_socket_path()
	// core:sys/posix rather than core:sys/linux: the same calls, and they
	// exist on macOS too.
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1
	}
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	addr := posix.sockaddr_un {
		sun_family = .UNIX,
	}
	if len(path) + 1 > len(addr.sun_path) {
		posix.close(fd)
		return -1
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = auto_cast path[i]
	}
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1
	}
	return linux.Fd(fd)
}

// notify_send_line writes one request line.
notify_send_line :: proc(fd: linux.Fd, line: string) -> bool {
	data := make([]u8, len(line) + 1, context.temp_allocator)
	copy(data, line)
	data[len(line)] = '\n'
	sent := 0
	for sent < len(data) {
		n := posix.send(posix.FD(fd), raw_data(data[sent:]), uint(len(data)) - uint(sent), {.NOSIGNAL})
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// notify_read_line reads one reply line, waiting at most timeout_ms (-1:
// forever, which only a watcher wants).
notify_read_line :: proc(fd: linux.Fd, buf: ^[dynamic]u8, timeout_ms: int, allocator := context.temp_allocator) -> (line: string, ok: bool) {
	for {
		for b, i in buf {
			if b == '\n' {
				line = strings.clone(string(buf[:i]), allocator)
				rest := len(buf) - i - 1
				copy(buf[:rest], buf[i + 1:])
				resize(buf, rest)
				return line, true
			}
		}
		// p.poll_fds, not linux.poll: on arm64 and riscv64 linux.poll turns
		// -1 into an invalid timespec and fails at once with EINVAL, which
		// made every watcher hang up the instant it started.
		pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, perr := p.poll_fds(pfd[:], timeout_ms)
		if perr == .EINTR {
			continue
		}
		if perr != .NONE || n == 0 {
			return "", false
		}
		chunk: [4096]u8
		got := int(posix.recv(posix.FD(fd), raw_data(chunk[:]), len(chunk), {}))
		if got < 0 && posix.errno() == .EINTR {
			continue
		}
		if got <= 0 {
			return "", false
		}
		append(buf, ..chunk[:got])
	}
}

// notify_request sends one request object and returns the reply line.
// Most apps want `notify`; the CLI and the toast surface use this.
notify_request :: proc(req: string, timeout_ms := 1500, allocator := context.temp_allocator) -> (reply: string, ok: bool) {
	fd := notify_connect()
	if fd < 0 {
		return "", false
	}
	defer posix.close(posix.FD(fd))
	if !notify_send_line(fd, req) {
		return "", false
	}
	buf := make([dynamic]u8, context.temp_allocator)
	return notify_read_line(fd, &buf, timeout_ms, allocator)
}

notify_class_name :: proc(c: Notify_Class) -> string {
	switch c {
	case .Person:
		return "person"
	case .Time:
		return "time"
	case .Machine:
		return "machine"
	}
	return "person"
}

notify_urgency_name :: proc(u: Notify_Urgency) -> string {
	switch u {
	case .Low:
		return "low"
	case .Normal:
		return "normal"
	case .Critical:
		return "critical"
	}
	return "normal"
}

// notify_json is the request `notify` sends, exposed for the CLI.
notify_json :: proc(n: Notification, source := "") -> string {
	o := jobj(context.temp_allocator)
	jset_str(o, "op", "send", context.temp_allocator)
	if source != "" {
		jset_str(o, "source", source, context.temp_allocator)
	}
	if n.renotify {
		jset_bool(o, "renotify", true, context.temp_allocator)
	}
	no := jobj(context.temp_allocator)
	if n.key != "" {
		jset_str(no, "key", n.key, context.temp_allocator)
	}
	jset_str(no, "app", n.app, context.temp_allocator)
	if n.identity != "" {
		jset_str(no, "identity", n.identity, context.temp_allocator)
	}
	jset_str(no, "class", notify_class_name(n.class), context.temp_allocator)
	jset_str(no, "urgency", notify_urgency_name(n.urgency), context.temp_allocator)
	if n.category != "" {
		jset_str(no, "category", n.category, context.temp_allocator)
	}
	jset_str(no, "title", n.title, context.temp_allocator)
	jset_str(no, "body", n.body, context.temp_allocator)
	if n.link != "" {
		jset_str(no, "link", n.link, context.temp_allocator)
	}
	if n.timeout_ms > 0 {
		jset_int(no, "timeout_ms", n.timeout_ms, context.temp_allocator)
	}
	arr := jarr(context.temp_allocator)
	for a in n.actions {
		ao := jobj(context.temp_allocator)
		jset_str(ao, "key", a.key, context.temp_allocator)
		jset_str(ao, "label", a.label, context.temp_allocator)
		if a.run != "" {
			jset_str(ao, "run", a.run, context.temp_allocator)
		}
		jpush(arr, ao)
	}
	jset(no, "actions", arr, context.temp_allocator)
	jset(o, "note", no, context.temp_allocator)
	return json_text(o, 0, context.temp_allocator)
}

// notify sends one notification. See the top of this file for what the
// fields mean and the rules about keys.
notify :: proc(n: Notification) -> Notify_Result {
	line, ok := notify_request(notify_json(n))
	if !ok {
		return {error = "unavailable"}
	}
	return notify_result(line)
}

notify_result :: proc(line: string) -> Notify_Result {
	v, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil {
		return {error = "failed"}
	}
	o, isobj := v.(json.Object)
	if !isobj {
		return {error = "failed"}
	}
	r: Notify_Result
	if b, has := o["ok"].(json.Boolean); has {
		r.ok = bool(b)
	}
	if s, has := o["delivery"].(json.String); has {
		r.delivery = string(s)
	}
	if s, has := o["why"].(json.String); has {
		r.why = string(s)
	}
	if s, has := o["error"].(json.String); has {
		r.error = string(s)
	}
	#partial switch x in o["id"] {
	case json.Integer:
		r.id = u32(x)
	case json.Float:
		r.id = u32(x)
	}
	return r
}

@(private = "file")
notify_simple :: proc(op, key: string) -> bool {
	o := jobj(context.temp_allocator)
	jset_str(o, "op", op, context.temp_allocator)
	jset_str(o, "key", key, context.temp_allocator)
	line, ok := notify_request(json_text(o, 0, context.temp_allocator))
	return ok && notify_result(line).ok
}

// notify_withdraw takes a notification back: it is no longer true or no
// longer matters (the call was answered elsewhere). It leaves the screen
// and the center, and the key cannot come back as new for a week.
notify_withdraw :: proc(key: string) -> bool {
	return notify_simple("withdraw", key)
}

// notify_read marks a notification read because the person saw the thing
// itself (opened the mail in Mail). It leaves the screen, stays in the
// center as read, and -- once cross-device sync is on -- is withdrawn on
// the person's other devices.
notify_read :: proc(key: string) -> bool {
	return notify_simple("read", key)
}

// ---------------------------------------------------------------------------
// Hearing clicks
//
// Most actions need no listener: an action with `run` is a deep link the
// daemon starts itself, as the right identity, whether or not the app is
// running. An app that wants a click delivered to its running process
// instead (Call's "Answer", which must reach the call already ringing) opens
// a listener and polls it from its frame loop or adds `fd` to its poll set.
//
//	l := kit.notify_listen("call")
//	for ev in kit.notify_next_action(&l) { if ev.action == "answer" { ... } }
// ---------------------------------------------------------------------------

Notify_Listener :: struct {
	fd:  linux.Fd,
	buf: [dynamic]u8,
}

Notify_Invoked :: struct {
	id:       u32,
	key:      string,
	app:      string,
	identity: string,
	action:   string,
}

notify_listen :: proc(app: string) -> Notify_Listener {
	l := Notify_Listener {
		fd = notify_connect(),
	}
	if l.fd < 0 {
		return l
	}
	o := jobj(context.temp_allocator)
	jset_str(o, "op", "watch", context.temp_allocator)
	jset_str(o, "role", "listener", context.temp_allocator)
	jset_str(o, "app", app, context.temp_allocator)
	if !notify_send_line(l.fd, json_text(o, 0, context.temp_allocator)) {
		posix.close(posix.FD(l.fd))
		l.fd = -1
	}
	return l
}

notify_listen_close :: proc(l: ^Notify_Listener) {
	if l.fd >= 0 {
		posix.close(posix.FD(l.fd))
	}
	delete(l.buf)
	l^ = {fd = -1}
}

// notify_next_action returns the next click, if one is waiting. It never
// blocks. Strings are temp-allocated.
notify_next_action :: proc(l: ^Notify_Listener) -> (ev: Notify_Invoked, ok: bool) {
	if l.fd < 0 {
		return {}, false
	}
	for {
		line, got := notify_read_line(l.fd, &l.buf, 0)
		if !got {
			return {}, false
		}
		v, err := json.parse_string(line, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		o, isobj := v.(json.Object)
		if !isobj {
			continue
		}
		if s, has := o["ev"].(json.String); !has || s != "action" {
			continue
		}
		get :: proc(o: json.Object, k: string) -> string {
			if s, has := o[k].(json.String); has {
				return string(s)
			}
			return ""
		}
		#partial switch x in o["id"] {
		case json.Integer:
			ev.id = u32(x)
		case json.Float:
			ev.id = u32(x)
		}
		ev.key = get(o, "key")
		ev.app = get(o, "app")
		ev.identity = get(o, "identity")
		ev.action = get(o, "action")
		return ev, true
	}
}
