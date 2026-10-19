package login

// palm-login — Palmframe's login daemon.
//
// It is greetd, as far as a greeter can tell: the greetd IPC protocol on a
// unix socket (ipc.odin), so apps/greeter talks to it unchanged. Behind the
// socket it is much smaller than greetd, because Palmframe has no PAM, no
// logind and no NSS: passwords are checked against /etc/shadow with SHA-512
// crypt implemented here (crypt.odin, accounts.odin), and a session is a
// fork that drops to the user (session.odin).
//
// The loop is the one in distro/CONTRACT.md:
//
//	1. start the greeter session as `greeter`:  wm --drm --kiosk --exec greeter
//	2. the greeter authenticates and sends start_session{cmd, env}
//	3. when the greeter session exits, start cmd as that user
//	4. when the user session exits, back to 1
//
// PALM_AUTOLOGIN=<user> (palm-init passes palm.autologin= from the kernel
// command line) skips 1–2 for the first session only: logging out of an
// autologin session lands on the greeter, not in a loop.
//
// Two more variables, for images and tests rather than for users:
// PALM_GREETER_CMD replaces the greeter session's command line, and
// PALM_DEFAULT_SESSION the command an autologin session runs (both split on
// spaces, no shell). PALM_SESSION_D replaces /etc/palm/session.d, the
// directory whose executables run beside every user session (session.odin).
//
//	palm-login                                   the daemon; must be root
//	palm-login --test --sock PATH --shadow F [--passwd F] [--group F]
//	                                             the protocol only, unprivileged:
//	                                             sessions are reported, never started
//	    [--session-sock PATH [--session-user U --session-uid N --session-leader PID]
//	     [--vt-active F] [--utmp F]]
//	                                             ...and the session socket, answering
//	                                             for a pretend session (session_ipc.odin)
//	palm-login --selftest                        crypt vectors, parsers, IPC round trip
//	palm-login --hash PASSWORD [--salt S] [--rounds N]
//	                                             a $6$ hash for /etc/shadow

import "auth"
import "core:sys/posix"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

SOCK_PATH :: "/run/palm-login.sock"
GREETER_USER :: "greeter"
GREETER_CMD :: "wm --drm --kiosk --exec greeter"
DEFAULT_SESSION := []string{"wm", "--drm"}

// After start_session the greeter is expected to exit on its own (the
// greeter quits, and wm --kiosk follows it). If it has not after this long it
// is asked to, and then told to.
GREETER_GRACE :: 8 * time.Second
KILL_GRACE :: 3 * time.Second

Child_Kind :: enum u8 {
	None,
	Greeter,
	User,
}

Daemon :: struct {
	paths:          Paths,
	sock_path:      string,
	test:           bool,
	listen_fd:      linux.Fd,
	conns:          [dynamic]^Conn,
	handler:        Handler,

	greeter_cmd:    []string,

	// The one child session, if any.
	child:          linux.Pid,
	child_kind:     Child_Kind,
	child_user:     string,
	child_started:  time.Tick,
	// The tty lent to the session, given back to root when it ends.
	vt_lent:        bool,

	// What the greeter asked for, waiting for the greeter to get out of the
	// way. Set by start_session; consumed when the greeter session ends.
	pending:        Maybe(Start_Request),
	pending_at:     time.Tick,
	term_sent:      bool,
	kill_sent:      bool,

	// A greeter that dies straight away is restarted with a growing delay,
	// rather than in a tight loop that would hide the log under restarts.
	quick_deaths:   int,
	next_start:     time.Tick,

	// Failed attempts, per account and for the seat (accounts.odin).
	limits:         Limits,
	// utmp, wtmp and lastlog; empty paths in --test mode, which records
	// nothing.
	utmp:           auth.Utmp_Paths,

	// The session socket (session_ipc.odin): who it answers for, and a
	// power action waiting for the session to end. -1 when there is none.
	session_listen_fd: linux.Fd,
	session_sock_path: string,
	seat:           Seat_Session,
	power_after:    string,
	power_at:       time.Tick,
	// Where the other logins are read from (utmp), and the unlock tally:
	// /run/faillock on the system; in memory in --test mode.
	others_utmp:    string,
	faillock_dir:   string,
	test_tally:     auth.Tally,
}

// The graphical seat's line in utmp and wtmp, and its utmp slot id.
SEAT_LINE :: "seat0"
SEAT_ID :: "s0"

// The virtual terminal every graphical session (the greeter's and the
// user's, one after the other) runs on. wm switches VTs itself when it may
// open the tty (apps/wm/vt.odin): the tty is lent to the session's user, as
// login(1) lends a console, and XDG_VTNR says which one it is.
SESSION_VT :: 1

@(private = "file")
stop_requested: i32

@(private = "file")
on_term :: proc "c" (sig: posix.Signal) {
	intrinsics.volatile_store(&stop_requested, 1)
}

main :: proc() {
	d := new(Daemon)
	d.paths = SYSTEM_PATHS
	d.sock_path = SOCK_PATH
	d.session_listen_fd = -1
	d.faillock_dir = auth.FAILLOCK_DIR
	d.others_utmp = auth.UTMP_PATH
	test_seat: struct {
		user:   string,
		uid:    int,
		leader: int,
	}
	test_seat.uid = -1
	session_sock := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		value :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			if i^ >= len(args) {
				fmt.eprintfln("palm-login: %s needs a value", args[i^ - 1])
				os.exit(2)
			}
			return args[i^]
		}
		switch args[i] {
		case "--test":
			d.test = true
		case "--sock":
			d.sock_path = value(args, &i)
		case "--shadow":
			d.paths.shadow = value(args, &i)
		case "--passwd":
			d.paths.passwd = value(args, &i)
		case "--group":
			d.paths.group = value(args, &i)
		case "--session-sock":
			session_sock = value(args, &i)
		case "--session-user":
			// --test only: pretend palm-login started a session as this
			// user, uid and leader pid, so the session socket's refusals
			// can be exercised without root.
			test_seat.user = value(args, &i)
		case "--session-uid":
			test_seat.uid, _ = strconv.parse_int(value(args, &i))
		case "--session-leader":
			test_seat.leader, _ = strconv.parse_int(value(args, &i))
		case "--vt-active":
			d.paths.vt_active = value(args, &i)
		case "--utmp":
			d.others_utmp = value(args, &i)
		case "--selftest":
			os.exit(selftest())
		case "--hash":
			// What the image builder uses to write /etc/shadow, so the hashes
			// on the disk come from the same code that checks them.
			pw := value(args, &i)
			salt, rounds := "", 0
			for i + 1 < len(args) {
				if args[i + 1] == "--salt" {
					i += 1
					salt = value(args, &i)
				} else if args[i + 1] == "--rounds" {
					i += 1
					rounds, _ = strconv.parse_int(value(args, &i))
				} else {
					break
				}
			}
			h, ok := auth.make_hash(pw, salt, rounds)
			if !ok {
				fmt.eprintln("palm-login: could not hash (salt must be [./0-9A-Za-z], at most 16)")
				os.exit(1)
			}
			fmt.println(h)
			return
		case "-h", "--help":
			fmt.println(
				"palm-login                     the login daemon (root only)\n" +
				"palm-login --test --sock PATH --shadow FILE [--passwd FILE] [--group FILE]\n" +
				"                               serve the protocol unprivileged; never starts a session\n" +
				"    [--session-sock PATH [--session-user U --session-uid N --session-leader PID] [--vt-active F] [--utmp F]]\n" +
				"                               ...and the session socket, for a pretend session\n" +
				"palm-login --selftest          crypt vectors, account parsers, an IPC round trip\n" +
				"palm-login --hash PASSWORD [--salt S] [--rounds N]\n" +
				"                               print a $6$ hash for /etc/shadow",
			)
			return
		case:
			fmt.eprintfln("palm-login: unknown argument %q", args[i])
			os.exit(2)
		}
	}

	if !d.test && linux.geteuid() != 0 {
		fmt.eprintln("palm-login: must run as root (use --test to exercise the protocol unprivileged)")
		os.exit(1)
	}
	if d.test && d.sock_path == SOCK_PATH {
		fmt.eprintln("palm-login: --test needs its own --sock, not the system socket")
		os.exit(2)
	}
	if d.test {
		// Nothing of the system's in test mode unless named.
		if d.paths.vt_active == VT_ACTIVE_PATH {
			d.paths.vt_active = ""
		}
		if d.others_utmp == auth.UTMP_PATH {
			d.others_utmp = ""
		}
		if session_sock == SESSION_SOCK_PATH {
			fmt.eprintln("palm-login: --test needs its own --session-sock")
			os.exit(2)
		}
	} else {
		if session_sock == "" {
			session_sock = SESSION_SOCK_PATH
		}
		if test_seat.user != "" {
			fmt.eprintln("palm-login: --session-user is for --test mode only")
			os.exit(2)
		}
	}
	d.session_sock_path = session_sock

	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	posix.signal(.SIGTERM, on_term)
	posix.signal(.SIGINT, on_term)
	posix.signal(.SIGHUP, on_term)

	if hooks := os.get_env("PALM_SESSION_D", context.allocator); hooks != "" {
		d.paths.session_d = hooks
	}
	cmdline := os.get_env("PALM_GREETER_CMD", context.allocator)
	d.greeter_cmd = strings.fields(cmdline != "" ? cmdline : GREETER_CMD)

	// Every grant and failure goes to syslog (authpriv) and, as before, to
	// stderr, which palm-init keeps as /var/log/palm-login.log. --test mode
	// stays out of the host's syslog.
	auth.log_open("palm-login", to_syslog = !d.test, echo = true)

	fail_delay := d.test ? 150 * time.Millisecond : 1500 * time.Millisecond
	d.limits.base = fail_delay
	d.handler = Handler {
		authenticate = proc(h: ^Handler, user, password: string) -> Auth_Result {
			d := (^Daemon)(h.data)
			return check_login(d.paths, &d.limits, user, password)
		},
		change_password = proc(h: ^Handler, user, password: string) -> string {
			d := (^Daemon)(h.data)
			return set_password(d.paths, user, password)
		},
		start        = d.test ? test_start : daemon_start,
		power        = d.test ? test_power : daemon_power,
		fail_delay   = fail_delay,
		data         = d,
	}
	if !d.test {
		d.utmp = auth.SYSTEM_UTMP
		record_boot_once(d)
	}

	fd, err := listen_unix(d.sock_path)
	if err != "" {
		fmt.eprintfln("palm-login: %s", err)
		os.exit(1)
	}
	d.listen_fd = fd
	secure_socket(d)
	fmt.eprintfln("palm-login: listening on %s%s", d.sock_path, d.test ? " (test mode: no sessions are started)" : "")
	if d.session_sock_path != "" {
		sfd, serr := listen_unix(d.session_sock_path)
		if serr != "" {
			fmt.eprintfln("palm-login: %s (no session socket: Lock and power from the session will not work)", serr)
		} else {
			d.session_listen_fd = sfd
			// root's, 0600, until a session is running (seat_begin).
			cpath := strings.clone_to_cstring(d.session_sock_path, context.temp_allocator)
			if !d.test {
				linux.chown(cpath, 0, 0)
			}
			linux.chmod(cpath, {.IRUSR, .IWUSR})
			fmt.eprintfln("palm-login: session socket on %s", d.session_sock_path)
		}
	}
	if d.test && test_seat.user != "" {
		seat_begin(d, test_seat.user, u32(max(test_seat.uid, 0)), u32(max(test_seat.uid, 0)), linux.Pid(test_seat.leader), d.paths.vt_active != "")
	}

	if !d.test {
		if user := autologin_user(); user != "" {
			fmt.eprintfln("palm-login: autologin as %q", user)
			session := DEFAULT_SESSION
			if c := os.get_env("PALM_DEFAULT_SESSION", context.allocator); c != "" {
				session = strings.fields(c)
			}
			d.pending = Start_Request {
				user = strings.clone(user),
				cmd  = session,
			}
		}
	}

	run(d)

	shutdown(d)
}

// record_boot_once writes the "reboot" record `last` shows, once per boot:
// /run is a fresh tmpfs at every boot, so a marker there says whether this
// boot has one yet, and a restarted palm-login does not add a second.
BOOT_MARKER :: "/run/palm-login.boot"

record_boot_once :: proc(d: ^Daemon) {
	fd, e := linux.open(BOOT_MARKER, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return
	}
	linux.close(fd)
	up: i64 = 0
	if text, ok := read_text("/proc/uptime"); ok {
		if f := strings.fields(text, context.temp_allocator); len(f) > 0 {
			v, _ := strconv.parse_f64(f[0])
			up = i64(v)
		}
	}
	auth.record_boot(d.utmp, up)
}

// secure_socket gives the socket to the greeter: only root and members of the
// greeter group may speak to the daemon at all.
secure_socket :: proc(d: ^Daemon) {
	cpath := strings.clone_to_cstring(d.sock_path, context.temp_allocator)
	if d.test {
		linux.chmod(cpath, {.IRUSR, .IWUSR})
		return
	}
	gid := u32(0)
	if text, ok := read_text(d.paths.group); ok {
		if g, found := auth.group_id(text, GREETER_USER); found {
			gid = g
		}
	}
	linux.chown(cpath, 0, linux.Gid(gid))
	linux.chmod(cpath, {.IRUSR, .IWUSR, .IRGRP, .IWGRP})
}

// autologin_user is PALM_AUTOLOGIN, or palm.autologin= read straight off the
// kernel command line if palm-init did not pass it on.
autologin_user :: proc() -> string {
	if u := os.get_env("PALM_AUTOLOGIN", context.temp_allocator); u != "" {
		return u
	}
	text, ok := read_text("/proc/cmdline")
	if !ok {
		return ""
	}
	for word in strings.fields(text, context.temp_allocator) {
		if strings.has_prefix(word, "palm.autologin=") {
			return word[len("palm.autologin="):]
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

run :: proc(d: ^Daemon) {
	for intrinsics.volatile_load(&stop_requested) == 0 {
		free_all(context.temp_allocator)

		if !d.test {
			supervise(d)
		}

		fds := make([dynamic]linux.Poll_Fd, context.temp_allocator)
		append(&fds, linux.Poll_Fd{fd = d.listen_fd, events = {.IN}})
		// Always polled, so the indexes below stay fixed; -1 is ignored.
		append(&fds, linux.Poll_Fd{fd = d.session_listen_fd, events = {.IN}})
		for c in d.conns {
			append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
		}
		// Short, so held replies, child exits and the greeter's grace period
		// are all noticed promptly without a signalfd.
		_, pe := linux.poll(fds[:], 100)
		if pe != .NONE && pe != .EINTR {
			fmt.eprintfln("palm-login: poll: %v", pe)
			time.sleep(100 * time.Millisecond)
			continue
		}

		if .IN in fds[0].revents {
			for {
				cfd, ae := linux.accept(d.listen_fd, (^linux.Sock_Addr_Un)(nil), {.CLOEXEC})
				if ae != .NONE {
					break
				}
				c := new(Conn)
				c.fd = cfd
				append(&d.conns, c)
			}
		}
		if .IN in fds[1].revents {
			for {
				cfd, ae := linux.accept(d.session_listen_fd, (^linux.Sock_Addr_Un)(nil), {.CLOEXEC})
				if ae != .NONE {
					break
				}
				c := new(Conn)
				c.fd = cfd
				c.session = true
				c.peer, c.has_peer = peer_cred(cfd)
				append(&d.conns, c)
			}
		}

		// Walk backwards so closing a connection does not skip the next one.
		for i := len(d.conns) - 1; i >= 0; i -= 1 {
			c := d.conns[i]
			readable := false
			if i + 2 < len(fds) && fds[i + 2].fd == c.fd {
				r := fds[i + 2].revents
				readable = .IN in r || .HUP in r || .ERR in r
			}
			if !conn_service(&d.handler, c, readable) {
				conn_close(c)
				ordered_remove(&d.conns, i)
			}
		}
	}
}

// supervise reaps the session, and starts the next one when there is none.
supervise :: proc(d: ^Daemon) {
	// Reap everything that has exited. Only the session leader matters; the
	// rest are whatever else was ours.
	for {
		status: u32
		pid, e := linux.wait4(-1, &status, {.WNOHANG}, nil)
		if e != .NONE || pid <= 0 {
			break
		}
		if pid == d.child {
			session_ended(d, status)
		}
	}

	// The greeter was told to go and has not.
	if d.child_kind == .Greeter && d.pending != nil {
		waited := time.tick_since(d.pending_at)
		if !d.term_sent && waited > GREETER_GRACE {
			fmt.eprintln("palm-login: the greeter is still running after start_session; sending SIGTERM")
			signal_session(d.child, .SIGTERM)
			d.term_sent = true
		} else if d.term_sent && !d.kill_sent && waited > GREETER_GRACE + KILL_GRACE {
			signal_session(d.child, .SIGKILL)
			d.kill_sent = true
		}
	}

	// The session asked for a power action and has not left yet.
	if d.child_kind == .User && d.power_after != "" {
		waited := time.tick_since(d.power_at)
		if !d.term_sent && waited > POWER_GRACE {
			fmt.eprintfln("palm-login: the session is still running %v after asking for %s; sending SIGTERM", POWER_GRACE, d.power_after)
			signal_session(d.child, .SIGTERM)
			d.term_sent = true
		} else if d.term_sent && !d.kill_sent && waited > POWER_GRACE + KILL_GRACE {
			signal_session(d.child, .SIGKILL)
			d.kill_sent = true
		}
	}

	if d.child_kind != .None {
		return
	}
	if req, ok := d.pending.?; ok {
		d.pending = nil
		start_user_session(d, req)
		if d.child_kind != .None {
			return
		}
	}
	if d.next_start != {} && time.tick_diff(time.tick_now(), d.next_start) > 0 {
		return
	}
	start_greeter(d)
}

session_ended :: proc(d: ^Daemon, status: u32) {
	ran := time.tick_since(d.child_started)
	fmt.eprintfln(
		"palm-login: %s session of %q ended (%s) after %v",
		d.child_kind == .Greeter ? "greeter" : "user",
		d.child_user,
		describe_status(status),
		ran,
	)
	// Whatever the session left behind in its process group goes with it.
	signal_session(d.child, .SIGHUP)
	signal_session(d.child, .SIGTERM)
	if d.child_kind == .User {
		auth.record_logout(d.utmp, i32(d.child), SEAT_LINE, SEAT_ID)
		auth.logf(.Info, "session of %q closed", d.child_user)
		seat_end(d)
	}
	vt_return(d)

	if d.child_kind == .Greeter && d.pending == nil {
		if ran < 3 * time.Second {
			d.quick_deaths += 1
			delay := time.Duration(min(d.quick_deaths * 2, 30)) * time.Second
			fmt.eprintfln("palm-login: the greeter exited quickly; next start in %v", delay)
			d.next_start = time.tick_add(time.tick_now(), delay)
		} else {
			d.quick_deaths = 0
		}
	}
	if d.child_kind == .User {
		d.quick_deaths = 0
		d.next_start = {}
		if d.power_after != "" {
			// The session's teardown is done (utmp, the tty, its process
			// group); now the machine. The greeter comes back only if that
			// fails to happen within a minute.
			auth.logf(.Notice, "the session has ended; running %s", d.power_after)
			if why := run_power(d.power_after); why != "" {
				fmt.eprintfln("palm-login: %s: %s", d.power_after, why)
			} else {
				d.next_start = time.tick_add(time.tick_now(), 60 * time.Second)
			}
			delete(d.power_after)
			d.power_after = ""
		}
	}
	d.child = 0
	d.child_kind = .None
	delete(d.child_user)
	d.child_user = ""
}

describe_status :: proc(status: u32) -> string {
	sig := status & 0x7f
	if sig == 0 {
		return fmt.tprintf("exit %d", (status >> 8) & 0xff)
	}
	return fmt.tprintf("signal %d", sig)
}

start_greeter :: proc(d: ^Daemon) {
	acct, ok := lookup_account(d.paths, GREETER_USER, context.temp_allocator)
	if !ok {
		fmt.eprintfln("palm-login: no %q account in %s; retrying in 10s", GREETER_USER, d.paths.passwd)
		d.next_start = time.tick_add(time.tick_now(), 10 * time.Second)
		return
	}
	groups := user_groups(d, acct)
	env := [?]string {
		fmt.tprintf("GREETD_SOCK=%s", d.sock_path),
		// The greeter only wires its power buttons to /sbin/poweroff and
		// /sbin/reboot when it knows it is the installed login screen.
		"PALM_LOGIN=1",
	}
	launch(d, .Greeter, acct, groups, d.greeter_cmd, env[:])
}

start_user_session :: proc(d: ^Daemon, req: Start_Request) {
	acct, ok := lookup_account(d.paths, req.user, context.temp_allocator)
	if !ok {
		fmt.eprintfln("palm-login: %q has no passwd entry; back to the greeter", req.user)
		return
	}
	launch(d, .User, acct, user_groups(d, acct), req.cmd, req.env)
}

user_groups :: proc(d: ^Daemon, acct: auth.Account) -> []u32 {
	text, _ := read_text(d.paths.group)
	return auth.parse_groups(text, acct.name, acct.gid, context.temp_allocator)
}

launch :: proc(d: ^Daemon, kind: Child_Kind, acct: auth.Account, groups: []u32, cmd, env: []string) {
	// The system's language (and, rarely, TZ) under whatever the caller
	// adds: the greeter may ask for its own LANG in start_session, and that
	// request wins, as greetd's would. See locale.odin.
	full := make([dynamic]string, context.temp_allocator)
	append(&full, ..system_locale_env(d.paths, context.temp_allocator))
	if vt_lend(d, acct) {
		append(&full, fmt.tprintf("XDG_VTNR=%d", SESSION_VT))
	}
	if kind == .User && d.session_listen_fd >= 0 {
		// Where the session's wm asks for Lock's password check and for
		// Restart and Shut down (session_ipc.odin).
		append(&full, fmt.tprintf("PALM_SESSION_SOCK=%s", d.session_sock_path))
	}
	append(&full, ..env)
	spec := Session_Spec {
		acct   = acct,
		groups = groups,
		cmd    = cmd,
		env    = full[:],
		log    = fmt.tprintf("/var/log/session-%s.log", acct.name),
		// Only a user's session: the greeter needs no sound or anything
		// else a package might want running for a person.
		hooks  = kind == .User ? session_hooks(d.paths.session_d, context.temp_allocator) : nil,
	}
	if len(spec.hooks) > 0 {
		fmt.eprintfln("palm-login: session hooks for %q: %v", acct.name, spec.hooks)
	}
	pid, err := spawn_session(spec)
	if err != "" {
		vt_return(d)
		fmt.eprintfln("palm-login: could not start %v for %q: %s", cmd, acct.name, err)
		// Without a delay a missing `wm` would spin here forever.
		d.quick_deaths += 1
		d.next_start = time.tick_add(time.tick_now(), time.Duration(min(d.quick_deaths * 2, 30)) * time.Second)
		return
	}
	fmt.eprintfln("palm-login: started %v as %q (pid %d)", cmd, acct.name, pid)
	if kind == .User {
		auth.record_login(d.utmp, i32(pid), SEAT_LINE, SEAT_ID, acct.name, acct.uid)
		auth.logf(.Info, "session opened for %q (uid %d) on %s", acct.name, acct.uid, SEAT_LINE)
		seat_begin(d, acct.name, acct.uid, acct.gid, pid, d.vt_lent)
	}
	d.child = pid
	d.child_kind = kind
	d.child_user = strings.clone(acct.name)
	d.child_started = time.tick_now()
	d.term_sent = false
	d.kill_sent = false
}

// vt_lend gives /dev/tty<SESSION_VT> to the session's user (owner the user,
// group tty, 0620), so wm may open it, make it its controlling terminal and
// switch VTs. It is false when the tty cannot be lent (no such tty, or not
// allowed, as in the e2e namespace), and the session then runs without VT
// switching, as it did before.
vt_lend :: proc(d: ^Daemon, acct: auth.Account) -> bool {
	if d.test {
		return false
	}
	path := fmt.ctprintf("/dev/tty%d", SESSION_VT)
	if linux.chown(path, linux.Uid(acct.uid), linux.Gid(tty_gid(d))) != .NONE {
		return false
	}
	linux.chmod(path, {.IRUSR, .IWUSR, .IWGRP})
	d.vt_lent = true
	return true
}

// vt_return gives the tty back to root:tty 0620 once the session is over.
vt_return :: proc(d: ^Daemon) {
	if !d.vt_lent {
		return
	}
	path := fmt.ctprintf("/dev/tty%d", SESSION_VT)
	linux.chown(path, 0, linux.Gid(tty_gid(d)))
	linux.chmod(path, {.IRUSR, .IWUSR, .IWGRP})
	d.vt_lent = false
}

tty_gid :: proc(d: ^Daemon) -> u32 {
	if text, ok := read_text(d.paths.group); ok {
		if g, found := auth.group_id(text, "tty"); found {
			return g
		}
	}
	return 5
}

// daemon_start is the real start_session: remember the request and let the
// greeter exit. The session itself starts in `supervise` once it has.
daemon_start :: proc(h: ^Handler, req: Start_Request) -> string {
	d := (^Daemon)(h.data)
	if d.pending != nil {
		return "a session is already waiting to start"
	}
	if d.child_kind == .User {
		return "a user session is already running"
	}
	if _, found := find_program(req.cmd[0], context.temp_allocator); !found {
		return fmt.tprintf("%s: no such program", req.cmd[0])
	}
	d.pending = clone_request(req)
	d.pending_at = time.tick_now()
	fmt.eprintfln("palm-login: start_session for %q: %v", req.user, req.cmd)
	return ""
}

// test_start reports the session it would have started, on stdout, and
// starts nothing.
test_start :: proc(h: ^Handler, req: Start_Request) -> string {
	fmt.printfln("palm-login: test: would start %v for %q with env %v", req.cmd, req.user, req.env)
	return ""
}

// daemon_power runs busybox's /sbin/poweroff or /sbin/reboot as root. Those
// signal palm-init, which stops every service — this daemon included — and
// takes the machine down; the reply goes out before that happens. From the
// greeter's socket only while no user session runs: the session has its
// own way, with its own rules (session_ipc.odin).
daemon_power :: proc(h: ^Handler, action: string) -> string {
	d := (^Daemon)(h.data)
	if d.child_kind == .User {
		return "a user session is running"
	}
	fmt.eprintfln("palm-login: the greeter asked for %s", action)
	return run_power(action)
}

test_power :: proc(h: ^Handler, action: string) -> string {
	fmt.printfln("palm-login: test: would run /sbin/%s", action)
	return ""
}

clone_request :: proc(req: Start_Request) -> Start_Request {
	out := Start_Request {
		user = strings.clone(req.user),
		cmd  = make([]string, len(req.cmd)),
		env  = make([]string, len(req.env)),
	}
	for s, i in req.cmd {
		out.cmd[i] = strings.clone(s)
	}
	for s, i in req.env {
		out.env[i] = strings.clone(s)
	}
	return out
}

// shutdown is SIGTERM from palm-init: end the session cleanly, then go.
shutdown :: proc(d: ^Daemon) {
	fmt.eprintln("palm-login: stopping")
	if d.child > 0 {
		signal_session(d.child, .SIGTERM)
		deadline := time.tick_now()
		for time.tick_since(deadline) < 2 * time.Second {
			status: u32
			pid, _ := linux.wait4(d.child, &status, {.WNOHANG}, nil)
			if pid == d.child {
				break
			}
			time.sleep(50 * time.Millisecond)
		}
		signal_session(d.child, .SIGKILL)
		if d.child_kind == .User {
			auth.record_logout(d.utmp, i32(d.child), SEAT_LINE, SEAT_ID)
		}
		vt_return(d)
	}
	for c in d.conns {
		conn_close(c)
	}
	linux.close(d.listen_fd)
	linux.unlink(strings.clone_to_cstring(d.sock_path, context.temp_allocator))
	if d.session_listen_fd >= 0 {
		linux.close(d.session_listen_fd)
		linux.unlink(strings.clone_to_cstring(d.session_sock_path, context.temp_allocator))
	}
}
