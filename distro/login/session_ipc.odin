package login

// The session socket: what the running session may ask of palm-login.
//
// The greeter's socket (ipc.odin) belongs to the greeter group and is the
// way *into* a session. Once someone is logged in, two things still need
// root, and palm-login is the only root process that knows who is sitting at
// the seat:
//
//	unlock{password}              is this the session user's password?
//	                              (the wm's lock screen; the wm runs as the
//	                              user and must never read /etc/shadow)
//	power{action, dry_run?, password?}
//	                              end the session, then /sbin/poweroff or
//	                              /sbin/reboot
//
// Same framing and replies as greetd (u32 length + JSON; success, or error
// with error_type and description). Nothing else is accepted here: no
// create_session, no start_session, no commands, no paths.
//
// Who may ask. The policy is logind's for the one-seat case, without polkit:
//
//   - the socket file is chown'd to the session's user (0600) for as long as
//     the session runs, and to root otherwise, so nobody else can connect;
//   - every request is checked again against SO_PEERCRED: the peer's uid
//     must be the uid palm-login itself started the current session as, and
//     the peer must be a process *of that session* — the session leader
//     palm-login forked, or a descendant of it. A process of the same user
//     that is not in the session (a serial-console login, anything started
//     outside it) is refused, as logind refuses a process outside the
//     session's cgroup. Root is not special: root runs poweroff itself;
//   - power is refused while the session is not in front (its VT switched
//     away), like logind's "active" — the person at the keyboard is
//     somewhere else;
//   - power is refused while anyone else is logged in (a live USER_PROCESS
//     in utmp on another line: root on ttyS0, say), unless the request
//     carries the password of a member of wheel — logind's
//     power-off-multiple-sessions, which polkit grants to admins with their
//     password. Turning the machine off under someone else's shell is not
//     something the person at the seat decides alone;
//   - without others, power needs no password: logind's default for the
//     active local session, and what every desktop does.
//
// Unlock passwords are rate limited with the shared auth package, on the
// same /run/faillock/<uid> tally doas and passwd use, so guesses through the
// lock screen and through doas count together; and a wrong one is answered
// late, as at the greeter.

import "auth"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

SESSION_SOCK_PATH :: "/run/palm-login.session.sock"
VT_ACTIVE_PATH :: "/sys/class/tty/tty0/active"

// After a power request the session gets this long to exit by itself (the
// wm closes its windows first, then exits) before it is ended for it.
POWER_GRACE :: 10 * time.Second

// Seat_Session is the user session the socket answers for.
Seat_Session :: struct {
	running: bool,
	user:    string,
	uid:     u32,
	gid:     u32,
	leader:  linux.Pid, // the session's first process, which palm-login forked
	vt:      bool, // a VT was lent; "in front" is read from VT_ACTIVE_PATH
}

Peer :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

// peer_cred reads SO_PEERCRED. The library's getsockopt passes the size of
// a pointer, not of the struct, so the syscall is made here.
peer_cred :: proc(fd: linux.Fd) -> (p: Peer, ok: bool) {
	size := u32(size_of(Peer))
	r := intrinsics.syscall(
		linux.SYS_getsockopt,
		uintptr(fd),
		1, // SOL_SOCKET
		uintptr(linux.Socket_Option.PEERCRED),
		uintptr(&p),
		uintptr(&size),
	)
	return p, int(r) == 0 && size == size_of(Peer)
}

// proc_ppid is the parent of `pid`, from /proc/<pid>/stat (field 4, after
// the command name, which may itself contain spaces and parentheses).
proc_ppid :: proc(pid: i32) -> (i32, bool) {
	text, ok := read_text(fmt.tprintf("/proc/%d/stat", pid))
	if !ok {
		return 0, false
	}
	rp := strings.last_index_byte(text, ')')
	if rp < 0 {
		return 0, false
	}
	f := strings.fields(text[rp + 1:], context.temp_allocator)
	if len(f) < 2 {
		return 0, false
	}
	v := 0
	for ch in f[1] {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		v = v * 10 + int(ch - '0')
	}
	return i32(v), true
}

// descends_from: is `pid` the process `leader`, or below it? Walks parents
// up to init. A process that was reparented (its parent died) is no longer
// below the session leader, and is refused — as it would have to be: what
// is left of a dead parent is not reliably the session's.
descends_from :: proc(pid: i32, leader: linux.Pid) -> bool {
	cur := pid
	for _ in 0 ..< 128 {
		if cur == i32(leader) {
			return true
		}
		if cur <= 1 {
			return false
		}
		next, ok := proc_ppid(cur)
		if !ok {
			return false
		}
		cur = next
	}
	return false
}

// session_refusal says why `c`'s peer may not ask, or "".
session_refusal :: proc(d: ^Daemon, c: ^Conn, for_power: bool) -> string {
	ss := &d.seat
	if !ss.running {
		return "no user session is running"
	}
	if d.power_after != "" {
		return "the session is already ending"
	}
	if !c.has_peer {
		return "the peer's credentials could not be read"
	}
	if c.peer.uid != ss.uid {
		return "only the session's own user may ask"
	}
	if !descends_from(c.peer.pid, ss.leader) {
		return "only a process of the running session may ask"
	}
	if for_power && ss.vt && !session_in_front(d) {
		return "the session is not the one on screen"
	}
	return ""
}

// session_in_front: is the session's VT the active one?
session_in_front :: proc(d: ^Daemon) -> bool {
	text, ok := read_text(d.paths.vt_active)
	if !ok {
		return true // no way to tell (no VT layer): there is only one seat
	}
	return strings.trim_space(text) == fmt.tprintf("tty%d", SESSION_VT)
}

// others_logged_in lists the logins on other lines, as "root on ttyS0".
others_logged_in :: proc(d: ^Daemon) -> []string {
	logins := auth.utmp_logins(d.others_utmp, SEAT_LINE, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for l in logins {
		append(&out, fmt.tprintf("%s on %s", auth.clean(l.user), auth.clean(l.line)))
	}
	return out[:]
}

user_in_wheel :: proc(d: ^Daemon) -> bool {
	text, ok := read_text(d.paths.group)
	if !ok {
		return false
	}
	wheel, found := auth.group_id(text, "wheel")
	if !found {
		return false
	}
	for g in auth.parse_groups(text, d.seat.user, d.seat.gid, context.temp_allocator) {
		if g == wheel {
			return true
		}
	}
	return false
}

// session_check_password is the rate-limited check for the session's user:
// the faillock file shared with doas and passwd on the real system, an
// in-memory tally in --test mode (which cannot make root-owned files).
session_check_password :: proc(d: ^Daemon, password: string) -> (r: Auth_Result) {
	user := d.seat.user
	now := auth.now_ms()
	base := d.limits.base

	fl: auth.Faillock
	tally: ^auth.Tally
	if d.test {
		tally = &d.test_tally
		auth.tally_refresh(tally, now)
	} else {
		err: string
		fl, err = auth.faillock_open(d.seat.uid, d.faillock_dir)
		if err != "" {
			auth.logf(.Err, "faillock: %s", err)
			return {wait = base} // refuse rather than check unlimited
		}
		tally = &fl.tally
	}
	defer if !d.test {
		auth.faillock_close(&fl)
	}

	if w := auth.tally_remaining(tally^, now, base); w > 0 {
		auth.logf(.Warning, "session: refused %q unchecked: too many failures, %s left", auth.clean(user), auth.wait_words(w))
		return {wait = w}
	}
	// Counted before the check, as doas does: parallel guesses all count.
	auth.tally_fail(tally, now)
	if !d.test {
		auth.faillock_store(&fl)
	}
	c, found := auth.load_credentials(d.paths.passwd, d.paths.shadow, user)
	if !auth.check_password(c, found, password) {
		n := tally.failures
		auth.logf(
			.Notice,
			"session: authentication failure for %q (%d in a row; next attempt in %s)",
			auth.clean(user),
			n,
			auth.wait_words(auth.tally_wait_for(n, base)),
		)
		return {}
	}
	tally^ = {}
	if !d.test {
		auth.faillock_store(&fl)
	}
	r.ok = true
	if c.has_shadow {
		r.status, r.days = auth.account_status(c.shadow, auth.today())
	}
	return r
}

// handle_session_request answers one request on the session socket.
handle_session_request :: proc(h: ^Handler, c: ^Conn, obj: json.Object) -> (reply: string, hold: bool, fatal: bool) {
	d := (^Daemon)(h.data)
	kind, _ := jstr(obj, "type")
	switch kind {
	case "unlock":
		if why := session_refusal(d, c, false); why != "" {
			session_log_refusal(c, kind, why)
			return reply_error("error", why), false, false
		}
		pw, _ := jstr(obj, "password")
		r := session_check_password(d, pw)
		if r.wait > 0 {
			return reply_error("auth_error", describe_wait(r.wait)), true, false
		}
		if !r.ok {
			return reply_error("auth_error", "The password was not accepted."), true, false
		}
		#partial switch r.status {
		case .Account_Expired, .Inactive:
			auth.logf(.Notice, "session: refused to unlock %q: %v", auth.clean(d.seat.user), r.status)
			return reply_error("auth_error", auth.status_message(r.status)), false, false
		}
		auth.logf(.Info, "session of %q unlocked", auth.clean(d.seat.user))
		return reply_success(), false, false

	case "power":
		action, _ := jstr(obj, "action")
		if action != "poweroff" && action != "reboot" {
			return reply_error("error", "power action must be \"poweroff\" or \"reboot\""), false, false
		}
		if why := session_refusal(d, c, true); why != "" {
			session_log_refusal(c, kind, why)
			return reply_error("error", why), false, false
		}
		dry := false
		if v, ok := obj["dry_run"]; ok {
			if b, is := v.(json.Boolean); is {
				dry = bool(b)
			}
		}
		pw, has_pw := jstr(obj, "password")
		if others := others_logged_in(d); len(others) > 0 {
			who := strings.join(others, ", ", context.temp_allocator)
			if !user_in_wheel(d) {
				session_log_refusal(c, kind, fmt.tprintf("others are logged in (%s)", who))
				return reply_error("error", fmt.tprintf(
					"Someone else is logged in (%s). Only an administrator can %s now.",
					who, action == "reboot" ? "restart" : "shut down",
				)), false, false
			}
			if !has_pw {
				return reply_error("auth_required", fmt.tprintf(
					"Someone else is logged in (%s). Enter your password to %s anyway.",
					who, action == "reboot" ? "restart" : "shut down",
				)), false, false
			}
			r := session_check_password(d, pw)
			if r.wait > 0 {
				return reply_error("auth_error", describe_wait(r.wait)), true, false
			}
			if !r.ok {
				return reply_error("auth_error", "The password was not accepted."), true, false
			}
			auth.logf(.Notice, "%q overrode the other logins (%s) with a password", auth.clean(d.seat.user), who)
		}
		if dry {
			return reply_success(), false, false
		}
		auth.logf(.Notice, "%q asked for %s from the session (pid %d)", auth.clean(d.seat.user), action, c.peer.pid)
		if d.test {
			fmt.printfln("palm-login: test: would end the session, then run /sbin/%s", action)
			return reply_success(), false, false
		}
		d.power_after = strings.clone(action)
		d.power_at = time.tick_now()
		d.term_sent = false
		d.kill_sent = false
		return reply_success(), false, false

	case "":
		return reply_error("error", "the request has no type"), false, true
	}
	session_log_refusal(c, kind, "not a session request")
	return reply_error("error", fmt.tprintf("the session socket does not take %q", kind)), false, false
}

session_log_refusal :: proc(c: ^Conn, kind, why: string) {
	auth.logf(.Warning, "session socket: refused %q from uid %d pid %d: %s", auth.clean(kind), c.peer.uid, c.peer.pid, why)
}

// session_socket_lend gives the socket file to the session's user for the
// length of the session, and back to root after it.
session_socket_lend :: proc(d: ^Daemon, uid: u32, gid: u32) {
	if d.session_listen_fd < 0 {
		return
	}
	cpath := strings.clone_to_cstring(d.session_sock_path, context.temp_allocator)
	linux.chown(cpath, linux.Uid(uid), linux.Gid(gid))
	linux.chmod(cpath, {.IRUSR, .IWUSR})
}

// seat_begin and seat_end bracket a user session.
seat_begin :: proc(d: ^Daemon, user: string, uid, gid: u32, leader: linux.Pid, vt: bool) {
	delete(d.seat.user)
	d.seat = {
		running = true,
		user    = strings.clone(user),
		uid     = uid,
		gid     = gid,
		leader  = leader,
		vt      = vt,
	}
	if !d.test {
		session_socket_lend(d, uid, gid)
	}
}

seat_end :: proc(d: ^Daemon) {
	delete(d.seat.user)
	d.seat = {}
	if !d.test {
		session_socket_lend(d, 0, 0)
	}
	// Connections the session left open answer to nobody now.
	for i := len(d.conns) - 1; i >= 0; i -= 1 {
		if d.conns[i].session {
			conn_close(d.conns[i])
			ordered_remove(&d.conns, i)
		}
	}
}

// run_power runs busybox's /sbin/poweroff or /sbin/reboot as root.
run_power :: proc(action: string) -> string {
	prog := action == "poweroff" ? cstring("/sbin/poweroff") : cstring("/sbin/reboot")
	argv := [2]cstring{prog, nil}
	envp := [1]cstring{nil}
	pid, e := linux.fork()
	if e != .NONE {
		return fmt.tprintf("fork: %v", e)
	}
	if pid == 0 {
		linux.execve(prog, raw_data(argv[:]), raw_data(envp[:]))
		linux.exit(127)
	}
	fmt.eprintfln("palm-login: running %s (pid %d)", prog, pid)
	return ""
}
