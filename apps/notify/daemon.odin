// palm-notifyd: one notification service per user session.
//
//	notify daemon [--clock HH:MM] [--no-bus] [--no-ui]
//
// It owns three doors and one store:
//
//   - a unix socket, $XDG_RUNTIME_DIR/palm/notify.sock, speaking one JSON
//     object per line. This is the native API: apps/kit/notify.odin, the CLI,
//     the toast surface and the center all use it. Why not D-Bus for our own
//     apps: Palmframe ships no session bus by default (distro/notes/
//     runtime.md), a palmy app should not need one to say "you have mail",
//     and SO_PEERCRED hands the daemon the sender's pid -- and through
//     /proc/<pid>/environ its PALM_IDENTITY -- without a bus round trip. The
//     objects on it are the same JSON `notify list --json` prints.
//   - org.freedesktop.Notifications on the session bus (fdo.odin), so
//     Firefox, Chromium and anything using libnotify work unchanged.
//   - the files: history and policies, rewritten when they change, and a
//     small state file the window manager's bar can read (count, quiet,
//     do-not-disturb) without speaking either protocol.
//
// It draws nothing. The toasts are a separate process (`notify toasts`,
// toasts.odin) that the daemon starts the first time something has to be
// shown and restarts if it dies: a crash in drawing must never lose a
// notification, and the daemon runs -- and is tested -- with no compositor.
package main

import "base:intrinsics"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import kit "kit:."
import "kit:dbus"

Client :: struct {
	fd:    linux.Fd,
	rx:    [dynamic]u8,
	watch: bool,
	role:  string, // "toasts", "center", "listener", ""
	app:   string, // a listener's app: it hears that app's action clicks
	pid:   i32,
	uid:   u32,
	scope: string, // the peer's PALM_IDENTITY; "" means unscoped
	dead:  bool,
}

Daemon :: struct {
	store:        Store,
	listen:       linux.Fd,
	sock_path:    string,
	clients:      [dynamic]^Client,
	bus:          ^dbus.Dbus_Conn,
	bus_owned:    bool,
	bus_retry_at: i64,
	bus_tries:    int,
	no_bus:       bool,
	no_ui:        bool,
	clock_offset: i64, // test clock: added to the wall clock
	test_clock:   bool,
	tz:           i64, // seconds east of UTC
	tz_checked:   i64,
	dirty:        bool,
	save_at:      i64,
	ui_pid:       linux.Pid,
	ui_started:   i64,
	ui_failures:  int,
	ui_retry_at:  i64,
	center_pid:   linux.Pid,
	sounds:       int,
	sound_cmd:    string,
	state_text:   string,
	last_rev:     u64,
	self_exe:     string,
	started:      i64,
}

g_quit: bool

@(private = "file")
on_signal :: proc "c" (sig: i32) {
	g_quit = true
}

wall_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

now_ms :: proc(d: ^Daemon) -> i64 {
	return wall_ms() + d.clock_offset
}

runtime_dir :: proc() -> string {
	if r := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); r != "" {
		return r
	}
	return fmt.tprintf("/tmp/palm-%d", linux.getuid())
}

socket_path :: proc() -> string {
	if p := os.get_env("PALM_NOTIFY_SOCKET", context.temp_allocator); p != "" {
		return p
	}
	return fmt.tprintf("%s/palm/notify.sock", runtime_dir())
}

// local_offset asks the system for the UTC offset, the way apps/calendar
// does: the timezone database is not linked in, and `date` follows
// /etc/localtime and TZ.
local_offset :: proc() -> i64 {
	if v := os.get_env("PALM_NOTIFY_TZ", context.temp_allocator); v != "" {
		return parse_offset(v)
	}
	state, out, _, err := os.process_exec({command = {"date", "+%z"}}, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		return 0
	}
	return parse_offset(strings.trim_space(string(out)))
}

parse_offset :: proc(s: string) -> i64 {
	if len(s) < 5 {
		return 0
	}
	sign := i64(s[0] == '-' ? -1 : 1)
	h := i64(s[1] - '0') * 10 + i64(s[2] - '0')
	m := i64(s[3] - '0') * 10 + i64(s[4] - '0')
	return sign * (h * 3600 + m * 60)
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

daemon_main :: proc(args: []string) -> int {
	d := new(Daemon)
	store_init(&d.store)
	for a, i in args {
		switch a {
		case "--no-bus":
			d.no_bus = true
		case "--no-ui":
			d.no_ui = true
		case "--clock":
			if i + 1 < len(args) {
				d.test_clock = true
				d.tz = local_offset()
				if m, ok := parse_time(args[i + 1]); ok {
					now := wall_ms()
					target := next_at(now, d.tz, m) - DAY_MS
					if target < now - DAY_MS {
						target += DAY_MS
					}
					d.clock_offset = target - now
				}
			}
		case "--test-clock":
			d.test_clock = true
		}
	}
	if os.get_env("PALM_NOTIFY_NO_UI", context.temp_allocator) != "" {
		d.no_ui = true
	}
	d.self_exe = exe_path()
	d.started = wall_ms()

	libc.signal(libc.SIGTERM, on_signal)
	libc.signal(libc.SIGINT, on_signal)
	libc.signal(1, on_signal) // SIGHUP: palm-login ends the session with it

	path := socket_path()
	if e := listen_on(d, path); e != "" {
		fmt.eprintfln("palm-notifyd: %s", e)
		return e == "already running" ? 0 : 1
	}
	d.sock_path = strings.clone(path)
	d.tz = local_offset()
	d.tz_checked = wall_ms()
	store_load(&d.store)
	sound_prepare(d)
	fmt.eprintfln(
		"palm-notifyd: listening on %s; %d notifications, %d policies; tz %+d s%s",
		path,
		len(d.store.notes),
		len(d.store.policies),
		d.tz,
		d.test_clock ? fmt.tprintf("; test clock at %s", hhmm(local_minute(now_ms(d), d.tz))) : "",
	)
	if !d.no_bus {
		bus_try(d)
	}

	for !g_quit {
		tick(d)
		poll_once(d)
		free_all(context.temp_allocator)
	}
	store_save(&d.store, now_ms(d), d.tz)
	_ = linux.unlink(strings.clone_to_cstring(d.sock_path, context.temp_allocator))
	if d.ui_pid > 0 {
		linux.kill(d.ui_pid, .SIGTERM)
	}
	fmt.eprintln("palm-notifyd: stopped")
	return 0
}

exe_path :: proc() -> string {
	buf: [4096]u8
	n, err := linux.readlink("/proc/self/exe", buf[:])
	if err != .NONE || n <= 0 {
		return strings.clone(os.args[0])
	}
	return strings.clone(string(buf[:n]))
}

@(private = "file")
listen_on :: proc(d: ^Daemon, path: string) -> string {
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir, os.perm_number(0o700))

	// Someone answering on the socket already is a running daemon: leave it.
	if fd, ok := connect_unix(path); ok {
		linux.close(fd)
		return "already running"
	}
	_ = linux.unlink(strings.clone_to_cstring(path, context.temp_allocator))

	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, linux.Protocol(0))
	if serr != .NONE {
		return "socket failed"
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) + 1 > len(addr.sun_path) {
		return "socket path too long"
	}
	copy(addr.sun_path[:], path)
	if e := linux.bind(fd, &addr); e != .NONE {
		return fmt.tprintf("cannot bind %s (%v)", path, e)
	}
	_ = linux.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR})
	if e := linux.listen(fd, 32); e != .NONE {
		return "listen failed"
	}
	d.listen = fd
	return ""
}

connect_unix :: proc(path: string) -> (linux.Fd, bool) {
	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	if serr != .NONE {
		return -1, false
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) + 1 > len(addr.sun_path) {
		linux.close(fd)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

@(private = "file")
poll_once :: proc(d: ^Daemon) {
	fds := make([dynamic]linux.Poll_Fd, context.temp_allocator)
	append(&fds, linux.Poll_Fd{fd = d.listen, events = {.IN}})
	bus_at := -1
	if d.bus != nil && dbus.dbus_alive(d.bus) {
		bus_at = len(fds)
		append(&fds, linux.Poll_Fd{fd = dbus.dbus_fd(d.bus), events = {.IN}})
	}
	first_client := len(fds)
	for c in d.clients {
		append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
	}
	// Ticks are cheap and the timers are minutes apart; a second is plenty,
	// and 250 ms while something is waiting to be saved or shown.
	timeout := i32(1000)
	if d.dirty {
		timeout = 250
	}
	n, err := linux.poll(fds[:], timeout)
	if err == .EINTR || n <= 0 {
		return
	}
	if .IN in fds[0].revents {
		accept_all(d)
	}
	if bus_at >= 0 && fds[bus_at].revents != {} {
		fdo_pump(d)
	}
	for i in first_client ..< len(fds) {
		c := d.clients[i - first_client]
		if fds[i].revents & {.IN, .HUP, .ERR} != {} {
			client_read(d, c)
		}
	}
	// Drop the dead after the pass, so indices above stayed valid.
	i := 0
	for i < len(d.clients) {
		c := d.clients[i]
		if c.dead {
			linux.close(c.fd)
			delete(c.rx)
			delete(c.scope)
			delete(c.role)
			delete(c.app)
			free(c)
			ordered_remove(&d.clients, i)
			continue
		}
		i += 1
	}
}

@(private = "file")
accept_all :: proc(d: ^Daemon) {
	for {
		addr: linux.Sock_Addr_Un
		fd, err := linux.accept(d.listen, &addr, {.CLOEXEC})
		if err != .NONE {
			return
		}
		c := new(Client)
		c.fd = fd
		peer_creds(c)
		if c.uid != u32(linux.getuid()) {
			// Only the session's own user. The socket is 0600 in a 0700
			// directory already; this is the second lock.
			linux.close(fd)
			free(c)
			continue
		}
		c.scope = strings.clone(proc_env(c.pid, "PALM_IDENTITY"))
		append(&d.clients, c)
	}
}

Ucred :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

peer_creds :: proc(c: ^Client) {
	cred: Ucred
	size := u32(size_of(Ucred))
	// SOL_SOCKET = 1, SO_PEERCRED = 17. Issued directly: the core wrapper
	// passes the size of the pointer, not of the struct.
	ret := int(intrinsics.syscall(linux.SYS_getsockopt, uintptr(c.fd), 1, 17, uintptr(rawptr(&cred)), uintptr(rawptr(&size))))
	if ret == 0 {
		c.pid, c.uid = cred.pid, cred.uid
	} else {
		c.uid = 0xffffffff
	}
}

// proc_env reads one variable from another process's environment. Same
// user only, which /proc enforces by itself.
proc_env :: proc(pid: i32, name: string) -> string {
	if pid <= 0 {
		return ""
	}
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
	if err != nil {
		return ""
	}
	prefix := fmt.tprintf("%s=", name)
	for entry in strings.split(string(data), "\x00", context.temp_allocator) {
		if strings.has_prefix(entry, prefix) {
			return entry[len(prefix):]
		}
	}
	return ""
}

proc_ppid :: proc(pid: i32) -> i32 {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil {
		return 0
	}
	s := string(data)
	// The command name is in parentheses and may itself contain spaces.
	close := strings.last_index_byte(s, ')')
	if close < 0 {
		return 0
	}
	fields := strings.fields(s[close + 1:], context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	v := i32(0)
	for ch in fields[1] {
		v = v * 10 + i32(ch - '0')
	}
	return v
}

// wm_identity asks the window manager which identity a process's window
// belongs to. The wm decides a window's identity (cloud/docs/shell.md); the
// file is the contract proposed to it in cloud/docs/notifications.md:
// $XDG_RUNTIME_DIR/palm/wm/clients, one "pid<TAB>identity<TAB>app_id" per
// line. Absent today, so this returns "" until the wm writes it. The parent
// chain is walked because a browser's notification comes from a helper
// process, not from the one holding the window.
wm_identity :: proc(pid: i32) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/palm/wm/clients", runtime_dir()), context.temp_allocator)
	if err != nil {
		return ""
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	p := pid
	for _ in 0 ..< 8 {
		if p <= 1 {
			break
		}
		for l in lines {
			f := strings.split(l, "\t", context.temp_allocator)
			if len(f) >= 2 && f[0] == fmt.tprintf("%d", p) {
				return f[1]
			}
		}
		p = proc_ppid(p)
	}
	return ""
}

// sender_identity is who a notification belongs to when it did not say:
// the sender's own PALM_IDENTITY, then the window manager's view.
sender_identity :: proc(pid: i32, scope: string) -> string {
	if scope != "" {
		return scope
	}
	return wm_identity(pid)
}

@(private = "file")
client_read :: proc(d: ^Daemon, c: ^Client) {
	buf: [8192]u8
	for {
		n, err := linux.recv(c.fd, buf[:], {.DONTWAIT})
		if err == .EAGAIN || err == .EINTR {
			break
		}
		if err != .NONE || n <= 0 {
			c.dead = true
			return
		}
		append(&c.rx, ..buf[:n])
		if len(c.rx) > 1 << 20 {
			c.dead = true
			return
		}
		if n < len(buf) {
			break
		}
	}
	for {
		nl := -1
		for b, i in c.rx {
			if b == '\n' {
				nl = i
				break
			}
		}
		if nl < 0 {
			break
		}
		line := strings.clone(string(c.rx[:nl]), context.temp_allocator)
		remaining := len(c.rx) - nl - 1
		copy(c.rx[:remaining], c.rx[nl + 1:])
		resize(&c.rx, remaining)
		if strings.trim_space(line) == "" {
			continue
		}
		reply := handle(d, c, line)
		if reply != nil {
			client_send(c, kit.json_text(reply, 0, context.temp_allocator))
		}
	}
}

client_send :: proc(c: ^Client, text: string) {
	if c.dead {
		return
	}
	data := make([]u8, len(text) + 1, context.temp_allocator)
	copy(data, text)
	data[len(text)] = '\n'
	sent := 0
	for sent < len(data) {
		n, err := linux.send(c.fd, data[sent:], {.NOSIGNAL})
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			// A watcher that stopped reading is not worth blocking the
			// daemon for; it will re-read everything on reconnect.
			pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
			if pn, _ := linux.poll(pfd[:], 200); pn <= 0 {
				c.dead = true
				return
			}
			continue
		}
		if err != .NONE || n <= 0 {
			c.dead = true
			return
		}
		sent += n
	}
}

broadcast :: proc(d: ^Daemon, ev: ^kit.Json) {
	text := kit.json_text(ev, 0, context.temp_allocator)
	for c in d.clients {
		if c.watch {
			client_send(c, text)
		}
	}
}

changed :: proc(d: ^Daemon) {
	d.dirty = true
	if d.save_at == 0 {
		d.save_at = wall_ms() + 500
	}
}

// ---------------------------------------------------------------------------
// Timers: digests, the end of quiet, do-not-disturb running out, saving
// ---------------------------------------------------------------------------

@(private = "file")
tick :: proc(d: ^Daemon) {
	now := now_ms(d)
	if wall_ms() - d.tz_checked > 10 * 60_000 && !d.test_clock {
		d.tz = local_offset()
		d.tz_checked = wall_ms()
	}
	s := &d.store

	// The person's do-not-disturb ran out: say what was held.
	if s.dnd && s.dnd_until > 0 && s.dnd_until <= now {
		s.dnd = false
		s.dnd_until = 0
		touch(s)
		fmt.eprintln("palm-notifyd: do not disturb ended")
	}

	// Each identity holding notifications releases them as a digest when its
	// hold lifts; machine notifications also go out at the daily time.
	idents := make(map[string]bool, allocator = context.temp_allocator)
	for n in s.notes {
		if n.held {
			idents[n.identity] = true
		}
	}
	for ident in idents {
		p := policy_for(s, ident)
		if hold_of(p, s.dnd, now, d.tz) != .None {
			continue
		}
		// What quiet or do-not-disturb held goes out the moment the hold
		// lifts. What waits for the daily digest waits for its time --
		// unless there is no daily digest any more, then it goes now.
		if has_held(s, ident, false) {
			release(d, ident, "while quiet", now, true)
		}
		if has_held(s, ident, true) {
			if p.digest_at < 0 {
				release(d, ident, "held for a digest", now, false)
			} else if digest_due(s, ident, p, now, d.tz) {
				release(d, ident, fmt.tprintf("in the %s digest", hhmm(p.digest_at)), now, false, next_at(now, d.tz, p.digest_at) - DAY_MS)
			}
		}
	}

	// A toast that nobody is showing (no compositor, the surface died) goes
	// by on its own, so `showing` never sticks.
	if !has_role(d, "toasts") {
		for n in s.notes {
			if n.showing && n.urgency != .Critical && now - n.updated > i64(toast_ms(n)) + 5000 {
				n.showing = false
				touch(s)
			}
		}
	}

	if s.rev != d.last_rev {
		d.last_rev = s.rev
		changed(d)
		ev := kit.jobj(context.temp_allocator)
		kit.jset_str(ev, "ev", "rev", context.temp_allocator)
		kit.jset_int(ev, "rev", int(s.rev), context.temp_allocator)
		broadcast(d, ev)
		write_state(d, now)
	}
	if d.dirty && wall_ms() >= d.save_at {
		store_save(s, now, d.tz)
		d.dirty = false
		d.save_at = 0
	}

	reap(d)
	ensure_ui(d)
	if !d.no_bus && (d.bus == nil || !dbus.dbus_alive(d.bus)) && wall_ms() >= d.bus_retry_at {
		bus_try(d)
	}
}

has_held :: proc(s: ^Store, ident: string, daily: bool) -> bool {
	for n in s.notes {
		if n.held && n.identity == ident && n.daily == daily {
			return true
		}
	}
	return false
}

// digest_due: the daily digest carries what arrived before its time. Its
// last occurrence (today's, once the clock is past it; else yesterday's) is
// the cut: anything held for the digest that arrived before it goes now, and
// what arrived after waits for the next one. A notification that turns up at
// 17:05 for a 17:00 digest is tomorrow's, not a digest of one.
digest_due :: proc(s: ^Store, ident: string, p: Policy, now, tz: i64) -> bool {
	if p.digest_at < 0 {
		return false
	}
	cut := next_at(now, tz, p.digest_at) - DAY_MS
	for n in s.notes {
		if n.held && n.daily && n.identity == ident && n.created <= cut {
			return true
		}
	}
	return false
}

// release builds the identity's digest and puts it on screen: it is the
// one interruption that stands for all of them.
release :: proc(d: ^Daemon, ident: string, reason: string, now: i64, only_hold: bool, before := max(i64)) {
	s := &d.store
	dg := digest_build(s, ident, reason, now, only_hold, before)
	if dg == nil {
		return
	}
	dg.delivery = .Toast
	dg.showing = true
	set_str(&dg.why, fmt.tprintf("%s: %s", ident_label(ident), reason))
	fmt.eprintfln("palm-notifyd: digest for %s: %s (%d)", ident != "" ? ident : "(none)", reason, dg.count)
	sound_play(d, dg)
}

has_role :: proc(d: ^Daemon, role: string) -> bool {
	for c in d.clients {
		if c.watch && c.role == role {
			return true
		}
	}
	return false
}

toast_ms :: proc(n: ^Note) -> int {
	if n.timeout_ms > 0 {
		return n.timeout_ms
	}
	switch {
	case n.urgency == .Critical:
		return 0
	case n.is_digest:
		return 12_000
	case n.class == .Person:
		return 8000
	case n.class == .Time:
		return 10_000
	}
	return 6000
}

// write_state is the window manager's view: a few lines it can read on the
// same once-a-second check it does for its config file. Rewritten only when
// something in it changed.
write_state :: proc(d: ^Daemon, now: i64) {
	s := &d.store
	sb := strings.builder_make(context.temp_allocator)
	unread, showing := 0, 0
	for n in s.notes {
		if !n.read && !n.held {
			unread += 1
		}
		if n.showing {
			showing += 1
		}
	}
	fmt.sbprintf(&sb, "unread %d\nshowing %d\ndnd %d\n", unread, showing, s.dnd ? 1 : 0)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	emit_ident :: proc(sb: ^strings.Builder, d: ^Daemon, ident: string, now: i64) {
		p := policy_for(&d.store, ident)
		hold := hold_of(p, d.store.dnd, now, d.tz)
		u := 0
		for n in d.store.notes {
			if n.identity == ident && !n.read && !n.held {
				u += 1
			}
		}
		h := hold == .None ? "none" : (hold == .Quiet ? "quiet" : "dnd")
		fmt.sbprintf(sb, "identity %s\t%s\t%d\t%s\n", ident, h, u, policy_sentence(p, now, d.tz))
	}
	for h in identity_handles() {
		seen[h] = true
		emit_ident(&sb, d, h, now)
	}
	for p in s.policies {
		if p.identity != "*" && !seen[p.identity] {
			seen[p.identity] = true
			emit_ident(&sb, d, p.identity, now)
		}
	}
	text := strings.to_string(sb)
	if text == d.state_text {
		return
	}
	delete(d.state_text)
	d.state_text = strings.clone(text)
	write_atomic(fmt.tprintf("%s/palm/notify.state", runtime_dir()), text)
}

// ---------------------------------------------------------------------------
// Children: the toast surface, the center, deep links
// ---------------------------------------------------------------------------

wayland_env :: proc() -> []string {
	env := make([dynamic]string, context.temp_allocator)
	have := false
	all_env, _ := os.environ(context.temp_allocator)
	for e in all_env {
		if strings.has_prefix(e, "WAYLAND_DISPLAY=") {
			have = true
		}
		append(&env, e)
	}
	if !have {
		// Started by palm-login before the window manager was: find its
		// socket. wm listens on wayland-palmy (apps/wm/main.odin).
		for name in ([?]string{"wayland-palmy", "wayland-0", "wayland-1"}) {
			if os.exists(fmt.tprintf("%s/%s", runtime_dir(), name)) {
				append(&env, fmt.tprintf("WAYLAND_DISPLAY=%s", name))
				have = true
				break
			}
		}
	}
	if !have {
		return nil
	}
	return env[:]
}

@(private = "file")
ensure_ui :: proc(d: ^Daemon) {
	if d.no_ui || d.ui_pid > 0 || wall_ms() < d.ui_retry_at {
		return
	}
	any := false
	for n in d.store.notes {
		if n.showing {
			any = true
			break
		}
	}
	if !any {
		return
	}
	env := wayland_env()
	if env == nil {
		d.ui_retry_at = wall_ms() + 2000
		return
	}
	proc_, err := os.process_start({command = {d.self_exe, "toasts"}, env = env})
	if err != nil {
		d.ui_failures += 1
		d.ui_retry_at = wall_ms() + 5000
		return
	}
	d.ui_pid = linux.Pid(proc_.pid)
	d.ui_started = wall_ms()
	fmt.eprintfln("palm-notifyd: toast surface started (pid %d)", d.ui_pid)
}

@(private = "file")
reap :: proc(d: ^Daemon) {
	for {
		status: u32
		pid, err := linux.wait4(-1, &status, {.WNOHANG}, nil)
		if err != .NONE || pid <= 0 {
			return
		}
		if pid == d.ui_pid {
			d.ui_pid = 0
			lived := wall_ms() - d.ui_started
			if lived < 3000 {
				// Dying at once (no layer shell, no fonts): back off rather
				// than spin.
				d.ui_failures += 1
				d.ui_retry_at = wall_ms() + i64(min(d.ui_failures, 6)) * 5000
				fmt.eprintfln("palm-notifyd: toast surface exited after %d ms (status %d); retrying later", lived, status)
			} else {
				d.ui_failures = 0
			}
		}
		if pid == d.center_pid {
			d.center_pid = 0
		}
	}
}

// split_command splits a deep link into argv: spaces separate, single and
// double quotes group. No shell is involved, so nothing in a link can
// expand, redirect or chain.
split_command :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	cur := strings.builder_make(allocator)
	quote: u8 = 0
	in_word := false
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
			} else {
				strings.write_byte(&cur, ch)
			}
			continue
		}
		switch ch {
		case '\'', '"':
			quote = ch
			in_word = true
		case ' ', '\t':
			if in_word {
				append(&out, strings.clone(strings.to_string(cur), allocator))
				strings.builder_reset(&cur)
				in_word = false
			}
		case:
			strings.write_byte(&cur, ch)
			in_word = true
		}
	}
	if in_word {
		append(&out, strings.clone(strings.to_string(cur), allocator))
	}
	return out[:]
}

// run_link starts a deep link as the notification's identity: a work
// notification opens the work mail, whoever clicked it.
run_link :: proc(d: ^Daemon, link: string, identity: string) -> bool {
	argv := split_command(link)
	if len(argv) == 0 {
		return false
	}
	if argv[0] == "notify" {
		argv[0] = d.self_exe
	}
	env := wayland_env()
	if env == nil {
		env, _ = os.environ(context.temp_allocator)
	}
	kept := make([dynamic]string, context.temp_allocator)
	for e in env {
		if !strings.has_prefix(e, "PALM_IDENTITY=") {
			append(&kept, e)
		}
	}
	if identity != "" {
		append(&kept, fmt.tprintf("PALM_IDENTITY=%s", identity))
	}
	p, err := os.process_start({command = argv, env = kept[:]})
	if err != nil {
		fmt.eprintfln("palm-notifyd: could not run %q: %v", link, err)
		return false
	}
	fmt.eprintfln("palm-notifyd: ran %q as %s (pid %d)", link, identity != "" ? identity : "(no identity)", p.pid)
	return true
}

open_center :: proc(d: ^Daemon, identity: string) {
	if d.center_pid > 0 {
		ev := kit.jobj(context.temp_allocator)
		kit.jset_str(ev, "ev", "center", context.temp_allocator)
		broadcast(d, ev)
		return
	}
	env := wayland_env()
	if env == nil {
		return
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, d.self_exe, "center")
	if identity != "" {
		append(&argv, "--identity", identity)
	}
	p, err := os.process_start({command = argv[:], env = env})
	if err == nil {
		d.center_pid = linux.Pid(p.pid)
	}
}

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

// Two short tones are synthesised once into the runtime directory, so the
// sound needs no asset and no package. They are played through PipeWire
// (pw-play) when its socket is there, else through a PulseAudio server
// (paplay), else not at all: a missing sound is never an error.
sound_prepare :: proc(d: ^Daemon) {
	if os.get_env("PALM_NOTIFY_SOUND", context.temp_allocator) == "off" {
		return
	}
	dir := fmt.tprintf("%s/palm", runtime_dir())
	_ = os.make_directory_all(dir)
	write_tone(fmt.tprintf("%s/notify-chime.wav", dir), {880, 1320}, 90)
	write_tone(fmt.tprintf("%s/notify-ring.wav", dir), {660, 880, 660, 880}, 160)
}

write_tone :: proc(path: string, freqs: []f64, ms_each: int) {
	RATE :: 48000
	per := RATE * ms_each / 1000
	total := per * len(freqs)
	data := make([]u8, 44 + total * 2, context.temp_allocator)
	put32 :: proc(b: []u8, off: int, v: u32) {
		b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put16 :: proc(b: []u8, off: int, v: u16) {
		b[off], b[off + 1] = u8(v), u8(v >> 8)
	}
	copy(data[0:], "RIFF")
	put32(data, 4, u32(36 + total * 2))
	copy(data[8:], "WAVEfmt ")
	put32(data, 16, 16)
	put16(data, 20, 1)
	put16(data, 22, 1)
	put32(data, 24, RATE)
	put32(data, 28, RATE * 2)
	put16(data, 32, 2)
	put16(data, 34, 16)
	copy(data[36:], "data")
	put32(data, 40, u32(total * 2))
	for f, k in freqs {
		for i in 0 ..< per {
			t := f64(i) / RATE
			// A soft attack and a long decay: a chime, not a beep.
			env := min(f64(i) / (0.004 * RATE), 1.0) * (1.0 - f64(i) / f64(per))
			v := 0.22 * env * sin_approx(2 * 3.141592653589793 * f * t)
			put16(data, 44 + (k * per + i) * 2, u16(i16(v * 32767)))
		}
	}
	_ = os.write_entire_file(path, data)
}

sin_approx :: proc(x: f64) -> f64 {
	// Range-reduce to [-pi, pi] and use a short Taylor series; good to a
	// few parts in a thousand, which no ear hears at this level.
	PI :: 3.141592653589793
	y := x - f64(i64(x / (2 * PI))) * 2 * PI
	if y > PI {
		y -= 2 * PI
	}
	y2 := y * y
	return y * (1 - y2 / 6 * (1 - y2 / 20 * (1 - y2 / 42 * (1 - y2 / 72))))
}

which :: proc(name: string) -> string {
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		p := fmt.tprintf("%s/%s", dir, name)
		if os.exists(p) {
			return p
		}
	}
	return ""
}

sound_play :: proc(d: ^Daemon, n: ^Note) {
	if os.get_env("PALM_NOTIFY_SOUND", context.temp_allocator) == "off" {
		return
	}
	file := fmt.tprintf("%s/palm/notify-%s.wav", runtime_dir(), is_call(n) ? "ring" : "chime")
	if !os.exists(file) {
		return
	}
	player := ""
	if os.exists(fmt.tprintf("%s/pipewire-0", runtime_dir())) {
		player = which("pw-play")
	}
	if player == "" && os.exists(fmt.tprintf("%s/pulse/native", runtime_dir())) {
		player = which("paplay")
	}
	if player == "" {
		return
	}
	if _, err := os.process_start({command = {player, file}}); err == nil {
		d.sounds += 1
		delete(d.sound_cmd)
		d.sound_cmd = strings.clone(fmt.tprintf("%s %s", player, file))
	}
}
