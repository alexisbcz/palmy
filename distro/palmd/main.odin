package palmd

// palmd -- the one thing in Palmy that changes the system for a user.
//
// Software (apps/store) runs as the user who logged in, and installing a
// package needs root. Palmy has no polkit, no D-Bus and no working su
// (busybox is not setuid), so instead there is this: a small root daemon,
// started by palm-init from /etc/palm/services/palmd, that listens on
// /run/palmd.sock and runs palm on behalf of root and of group wheel.
//
// It is narrow on purpose:
//
//   - three requests (proto.odin): plan an add, del or upgrade; apply a plan
//     that was shown; update the indexes. No queries -- the store runs palm
//     itself, unprivileged, to search and list.
//   - palm's argv is built here from a closed set of words and validated
//     package names; nothing a client sends becomes an option.
//   - who may ask is decided by SO_PEERCRED against /etc/group (auth.odin).
//   - one operation at a time: a second request while palm is running is
//     answered "busy" rather than queued, so nobody's click silently waits
//     behind someone else's upgrade.
//   - every request, with the peer's uid and pid, is logged.
//   - on its own, every REFRESH_EVERY (first REFRESH_FIRST after it starts,
//     once the network is likely up), it runs `palm update` when nothing
//     else is running, so the cached indexes Software reads are current and
//     a security update shows up under Updates without anyone asking for a
//     refresh. That is the only thing it does unasked: it never installs.
//
// An apply plans again first and refuses if the plan's id differs from the
// one the client confirmed, so the transaction that runs is the one a person
// read in the confirmation dialog.
//
//	palmd                                    the daemon; must be root
//	palmd --test --sock PATH [--palm P] [--passwd F] [--group F] [--log F]
//	                                         unprivileged, against a fake palm
//	palmd ... --refresh-every SECONDS        the index refresh period; 0 turns
//	                                         it off (the default under --test)
//	palmd --request JSON [--sock PATH]       send one request, print each reply
//	palmd --selftest

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

SOCK_PATH :: "/run/palmd.sock"

// The longest palm may run before palmd gives up on it. A whole-system
// upgrade over a slow link is minutes, not an hour.
JOB_LIMIT :: 30 * time.Minute

// The scheduled index refresh: how often, and how long after starting.
REFRESH_EVERY :: 6 * time.Hour
REFRESH_FIRST :: 2 * time.Minute

Daemon :: struct {
	sock_path:   string,
	palm:        string,
	passwd_path: string,
	group_path:  string,
	log_fd:      linux.Fd,
	test:        bool,
	listen_fd:   linux.Fd,
	conns:       [dynamic]^Conn,
	job:         ^Job, // the lock: at most one palm at a time
	refresh:     time.Duration, // 0: no scheduled refresh
	next_update: time.Time,
}

Conn :: struct {
	fd:    linux.Fd,
	inbuf: [dynamic]u8,
	peer:  Peer,
	user:  string,
}

Job_Phase :: enum u8 {
	Plan, // a dry run whose plan is the reply
	Check, // apply's dry run, compared against the confirmed plan id
	Run, // the real thing, streamed
}

Job :: struct {
	conn:    ^Conn, // nil once the client has gone; the job still finishes
	req:     Request,
	phase:   Job_Phase,
	pid:     linux.Pid,
	out_fd:  linux.Fd,
	err_fd:  linux.Fd,
	out:     [dynamic]u8,
	err:     [dynamic]u8, // all of stderr, for the error text
	errline: [dynamic]u8, // stderr's unfinished line, for streaming
	started: time.Tick,
	plan:    string, // the plan the Check phase confirmed, for the result
	who:     string, // uid=... for the log
}

@(private = "file")
stop_requested: i32

@(private = "file")
on_term :: proc "c" (sig: posix.Signal) {
	intrinsics.volatile_store(&stop_requested, 1)
}

main :: proc() {
	d := new(Daemon)
	d.sock_path = SOCK_PATH
	d.palm = PALM_PATH
	d.passwd_path = "/etc/passwd"
	d.group_path = "/etc/group"
	d.log_fd = 2
	request := ""
	log_path := ""
	refresh := -1

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		value :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			if i^ >= len(args) {
				fmt.eprintfln("palmd: %s needs a value", args[i^ - 1])
				os.exit(2)
			}
			return args[i^]
		}
		switch args[i] {
		case "--selftest", "--self-test":
			os.exit(selftest())
		case "--test":
			d.test = true
		case "--sock":
			d.sock_path = value(args, &i)
		case "--palm":
			d.palm = value(args, &i)
		case "--passwd":
			d.passwd_path = value(args, &i)
		case "--group":
			d.group_path = value(args, &i)
		case "--log":
			log_path = value(args, &i)
		case "--request":
			request = value(args, &i)
		case "--refresh-every":
			v := value(args, &i)
			n, okn := strconv.parse_int(v)
			if !okn || n < 0 {
				fmt.eprintfln("palmd: --refresh-every needs a number of seconds, not %q", v)
				os.exit(2)
			}
			refresh = n
		case "-h", "--help":
			fmt.println("usage: palmd | palmd --test --sock PATH [--palm P] [--passwd F] [--group F] [--log F] | palmd --request JSON [--sock PATH] | palmd --selftest")
			os.exit(0)
		case:
			fmt.eprintfln("palmd: unknown argument %q", args[i])
			os.exit(2)
		}
	}

	if request != "" {
		os.exit(client_request(d.sock_path, request))
	}

	if !d.test && linux.geteuid() != 0 {
		fmt.eprintln("palmd: must run as root (use --test to exercise it unprivileged)")
		os.exit(1)
	}
	if !d.test && (d.palm != PALM_PATH || d.passwd_path != "/etc/passwd" || d.group_path != "/etc/group") {
		// The overrides are for the selftest's fake palm and fixture files;
		// a root daemon pointed at another binary or another group file is a
		// configuration nobody should be able to reach by accident.
		fmt.eprintln("palmd: --palm, --passwd and --group are for --test only")
		os.exit(2)
	}
	if d.test && d.sock_path == SOCK_PATH {
		fmt.eprintln("palmd: --test needs its own --sock, not the system socket")
		os.exit(2)
	}
	if log_path != "" {
		fd, e := linux.open(strings.clone_to_cstring(log_path, context.temp_allocator), {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP})
		if e != .NONE {
			fmt.eprintfln("palmd: cannot open %s: %v", log_path, e)
			os.exit(1)
		}
		d.log_fd = fd
	}

	switch {
	case refresh > 0:
		d.refresh = time.Duration(refresh) * time.Second
		d.next_update = time.time_add(time.now(), d.refresh)
	case refresh < 0 && !d.test:
		d.refresh = REFRESH_EVERY
		d.next_update = time.time_add(time.now(), REFRESH_FIRST)
	}

	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	posix.signal(.SIGTERM, on_term)
	posix.signal(.SIGINT, on_term)
	posix.signal(.SIGHUP, on_term)

	fd, err := listen_unix(d.sock_path)
	if err != "" {
		fmt.eprintfln("palmd: %s", err)
		os.exit(1)
	}
	d.listen_fd = fd
	// 0666: anyone may connect; authorize() decides who is answered.
	linux.chmod(strings.clone_to_cstring(d.sock_path, context.temp_allocator), {.IRUSR, .IWUSR, .IRGRP, .IWGRP, .IROTH, .IWOTH})
	logf(d, "listening on %s (palm %s)%s", d.sock_path, d.palm, d.test ? ", test mode" : "")

	run(d)

	if d.job != nil && d.job.pid > 0 {
		// Stopping mid-transaction leaves palm's database true for every
		// package it reached; SIGTERM lets palm finish the file it is on.
		linux.kill(d.job.pid, .SIGTERM)
	}
	linux.unlink(strings.clone_to_cstring(d.sock_path, context.temp_allocator))
	logf(d, "stopped")
}

// logf writes one timestamped line to the log. palm-init sends a service's
// stderr to /var/log/<name>.log, which makes the default /var/log/palmd.log.
logf :: proc(d: ^Daemon, format: string, args: ..any) {
	now := time.now()
	y, mon, day := time.date(now)
	h, m, s := time.clock(now)
	line := fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ palmd: %s\n", y, int(mon), day, h, m, s, fmt.tprintf(format, ..args))
	linux.write(d.log_fd, transmute([]u8)line)
}

listen_unix :: proc(path: string) -> (fd: linux.Fd, err: string) {
	if len(path) >= 108 {
		return -1, fmt.aprintf("socket path %q is too long", path)
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)
	s, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if e != .NONE {
		return -1, fmt.aprintf("socket: %v", e)
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if be := linux.bind(s, &addr); be != .NONE {
		linux.close(s)
		return -1, fmt.aprintf("bind(%s): %v", path, be)
	}
	if le := linux.listen(s, 16); le != .NONE {
		linux.close(s)
		return -1, fmt.aprintf("listen(%s): %v", path, le)
	}
	return s, ""
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

run :: proc(d: ^Daemon) {
	for intrinsics.volatile_load(&stop_requested) == 0 {
		free_all(context.temp_allocator)

		fds := make([dynamic]linux.Poll_Fd, context.temp_allocator)
		append(&fds, linux.Poll_Fd{fd = d.listen_fd, events = {.IN}})
		for c in d.conns {
			append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
		}
		job_at := len(fds)
		if j := d.job; j != nil {
			append(&fds, linux.Poll_Fd{fd = j.out_fd, events = {.IN}})
			append(&fds, linux.Poll_Fd{fd = j.err_fd, events = {.IN}})
		}
		_, pe := linux.poll(fds[:], 200)
		if pe != .NONE && pe != .EINTR {
			logf(d, "poll: %v", pe)
			time.sleep(100 * time.Millisecond)
			continue
		}

		if .IN in fds[0].revents {
			for {
				cfd, ae := linux.accept(d.listen_fd, (^linux.Sock_Addr_Un)(nil), {.CLOEXEC, .NONBLOCK})
				if ae != .NONE {
					break
				}
				accept_conn(d, cfd)
			}
		}

		for i := len(d.conns) - 1; i >= 0; i -= 1 {
			c := d.conns[i]
			if i + 1 >= job_at || fds[i + 1].fd != c.fd {
				continue
			}
			r := fds[i + 1].revents
			if .IN in r || .HUP in r || .ERR in r {
				if !conn_read(d, c) {
					conn_close(d, c)
					ordered_remove(&d.conns, i)
				}
			}
		}

		if d.job != nil {
			job_service(d, len(fds) > job_at ? fds[job_at:] : nil)
		}

		if d.refresh > 0 && d.job == nil && time.diff(d.next_update, time.now()) >= 0 {
			// Nobody is waiting on this one; its result goes to the log only.
			d.next_update = time.time_add(time.now(), d.refresh)
			if err := job_start(d, nil, Request{op = .Update}, .Run, "palmd (scheduled refresh)"); err != "" {
				logf(d, "scheduled refresh: %s", err)
			}
		}
	}
}

accept_conn :: proc(d: ^Daemon, fd: linux.Fd) {
	peer, ok := peer_cred(fd)
	if !ok {
		logf(d, "connection refused: SO_PEERCRED failed")
		send_frame(fd, reply_error("denied", 4, "palmd could not tell who you are"))
		linux.close(fd)
		return
	}
	allowed, user, why := authorize(peer.uid, read_text(d.passwd_path), read_text(d.group_path))
	if !allowed {
		logf(d, "uid=%d (%s) pid=%d: refused: %s", peer.uid, user != "" ? user : "?", peer.pid, why)
		send_frame(fd, reply_error("denied", 4, fmt.tprintf("palmd: %s", why)))
		linux.close(fd)
		return
	}
	c := new(Conn)
	c.fd = fd
	c.peer = peer
	c.user = strings.clone(user)
	append(&d.conns, c)
}

conn_close :: proc(d: ^Daemon, c: ^Conn) {
	if d.job != nil && d.job.conn == c {
		// The client went away; palm does not. Half a transaction is worse
		// than one nobody is watching.
		logf(d, "%s: client disconnected; palm continues", d.job.who)
		d.job.conn = nil
	}
	linux.close(c.fd)
	delete(c.inbuf)
	delete(c.user)
	free(c)
}

// conn_read takes what has arrived and answers every complete request in it.
conn_read :: proc(d: ^Daemon, c: ^Conn) -> bool {
	chunk: [4096]u8
	n, e := linux.read(c.fd, chunk[:])
	if e == .EINTR || e == .EAGAIN {
		return true
	}
	if e != .NONE || n <= 0 {
		return false
	}
	append(&c.inbuf, ..chunk[:n])
	for {
		payload, got, bad := next_frame(&c.inbuf)
		if bad {
			logf(d, "uid=%d pid=%d: frame length out of range; closing", c.peer.uid, c.peer.pid)
			send_frame(c.fd, reply_error("invalid", 2, "frame length out of range"))
			return false
		}
		if !got {
			return true
		}
		if !handle(d, c, payload) {
			return false
		}
	}
}

// handle answers one request: validates it, logs it, and starts palm.
handle :: proc(d: ^Daemon, c: ^Conn, payload: string) -> bool {
	who := fmt.tprintf("uid=%d (%s) pid=%d", c.peer.uid, c.user, c.peer.pid)
	req, why := parse_request(payload)
	if why != "" {
		// The payload is logged quoted and cut short: it came from a client
		// and is evidence, not something to trust the shape of.
		shown := payload[:min(len(payload), 200)]
		logf(d, "%s: refused %q: %s", who, shown, why)
		return send_frame(c.fd, reply_error("invalid", 2, why))
	}
	desc := describe(req)
	if d.job != nil {
		logf(d, "%s: %s: busy (%s running)", who, desc, describe(d.job.req))
		return send_frame(c.fd, reply_error("busy", 6, fmt.tprintf("another operation is running (%s); try again when it has finished", describe(d.job.req))))
	}
	logf(d, "%s: %s", who, desc)
	phase := Job_Phase.Run
	switch req.op {
	case .Plan:
		phase = .Plan
	case .Apply:
		phase = .Check
	case .Update, .None:
	}
	if err := job_start(d, c, req, phase, who); err != "" {
		logf(d, "%s: %s: %s", who, desc, err)
		return send_frame(c.fd, reply_error("failed", 7, err))
	}
	return true
}

describe :: proc(r: Request) -> string {
	switch r.op {
	case .Update:
		return "update"
	case .Plan:
		return strings.trim_space(fmt.tprintf("plan %s %s", action_word(r.action), strings.join(r.packages, " ", context.temp_allocator)))
	case .Apply:
		what := strings.trim_space(fmt.tprintf("%s %s", action_word(r.action), strings.join(r.packages, " ", context.temp_allocator)))
		return fmt.tprintf("apply %s (plan %s)", what, r.plan_id)
	case .None:
	}
	return "?"
}

// ---------------------------------------------------------------------------
// Running palm
// ---------------------------------------------------------------------------

clone_request :: proc(r: Request) -> Request {
	out := r
	names := make([]string, len(r.packages))
	for n, i in r.packages {
		names[i] = strings.clone(n)
	}
	out.packages = names
	out.plan_id = strings.clone(r.plan_id)
	return out
}

job_start :: proc(d: ^Daemon, c: ^Conn, req: Request, phase: Job_Phase, who: string) -> string {
	j := new(Job)
	j.conn = c
	j.req = clone_request(req)
	j.phase = phase
	j.who = strings.clone(who)
	if err := job_spawn(d, j); err != "" {
		free(j)
		return err
	}
	d.job = j
	return ""
}

// job_spawn forks palm with stdout and stderr on two pipes and stdin on
// /dev/null. The environment is built from nothing: palm needs a PATH and a
// HOME, not whatever palm-init happened to have.
job_spawn :: proc(d: ^Daemon, j: ^Job) -> string {
	argv := palm_argv(d.palm, j.req, j.phase != .Run, context.temp_allocator)
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	env := [?]cstring{"PATH=/usr/bin:/bin", "HOME=/root", "LANG=C.UTF-8", nil}
	prog := cargv[0]

	outp, errp: [2]linux.Fd
	if e := linux.pipe2(&outp, {.CLOEXEC}); e != .NONE {
		return fmt.tprintf("pipe: %v", e)
	}
	if e := linux.pipe2(&errp, {.CLOEXEC}); e != .NONE {
		linux.close(outp[0])
		linux.close(outp[1])
		return fmt.tprintf("pipe: %v", e)
	}

	pid, fe := linux.fork()
	if fe != .NONE {
		linux.close(outp[0]); linux.close(outp[1])
		linux.close(errp[0]); linux.close(errp[1])
		return fmt.tprintf("fork: %v", fe)
	}
	if pid == 0 {
		// The child does nothing but system calls between fork and exec.
		posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
		posix.signal(.SIGTERM, auto_cast posix.SIG_DFL)
		posix.signal(.SIGINT, auto_cast posix.SIG_DFL)
		posix.signal(.SIGHUP, auto_cast posix.SIG_DFL)
		if null, e := linux.open("/dev/null", {}); e == .NONE {
			linux.dup2(null, 0)
		}
		linux.dup2(outp[1], 1)
		linux.dup2(errp[1], 2)
		linux.chdir("/")
		linux.execve(prog, raw_data(cargv), raw_data(env[:]))
		msg := "palmd: cannot execute palm\n"
		linux.write(2, transmute([]u8)msg)
		linux.exit(127)
	}
	linux.close(outp[1])
	linux.close(errp[1])
	j.pid = pid
	j.out_fd = outp[0]
	j.err_fd = errp[0]
	j.started = time.tick_now()
	clear(&j.out)
	clear(&j.err)
	clear(&j.errline)
	return ""
}

job_send :: proc(d: ^Daemon, j: ^Job, payload: string) {
	if j.conn != nil && !send_frame(j.conn.fd, payload) {
		logf(d, "%s: client stopped reading; palm continues", j.who)
		j.conn = nil
	}
}

// job_service drains palm's pipes, streams what it says during a Run, and
// finishes the job once palm has exited and both pipes are at end of file.
job_service :: proc(d: ^Daemon, fds: []linux.Poll_Fd) {
	j := d.job
	drain :: proc(fd: ^linux.Fd, into: ^[dynamic]u8) -> bool {
		if fd^ < 0 {
			return false
		}
		buf: [8192]u8
		n, e := linux.read(fd^, buf[:])
		if e == .EINTR || e == .EAGAIN {
			return false
		}
		if e != .NONE || n <= 0 {
			linux.close(fd^)
			fd^ = -1
			return false
		}
		append(into, ..buf[:n])
		return true
	}
	if len(fds) == 2 {
		if fds[0].revents != {} {
			drain(&j.out_fd, &j.out)
		}
		if fds[1].revents != {} {
			start := len(j.err)
			if drain(&j.err_fd, &j.err) {
				append(&j.errline, ..j.err[start:])
				stream_stderr(d, j)
			}
		}
	}

	if time.tick_since(j.started) > JOB_LIMIT && j.pid > 0 {
		logf(d, "%s: palm ran longer than %v; killing it", j.who, JOB_LIMIT)
		linux.kill(j.pid, .SIGKILL)
	}
	if j.out_fd >= 0 || j.err_fd >= 0 {
		return
	}
	status: u32
	pid, _ := linux.wait4(j.pid, &status, {.WNOHANG}, nil)
	if pid != j.pid {
		return
	}
	code := 128
	if status & 0x7f == 0 {
		code = int((status >> 8) & 0xff)
	}
	if len(j.errline) > 0 {
		append(&j.errline, '\n')
		stream_stderr(d, j)
	}
	job_finish(d, j, code)
}

// stream_stderr forwards each complete stderr line: palm's JSON progress
// objects as progress, anything else (a warning, a crash) as a log line.
// Only a Run streams; a plan's chatter stays in the log.
stream_stderr :: proc(d: ^Daemon, j: ^Job) {
	for {
		nl := -1
		for b, i in j.errline {
			if b == '\n' {
				nl = i
				break
			}
		}
		if nl < 0 {
			return
		}
		line := strings.clone(string(j.errline[:nl]), context.temp_allocator)
		remove_range(&j.errline, 0, nl + 1)
		if strings.trim_space(line) == "" || j.phase != .Run {
			continue
		}
		if msg, is := reply_progress(line); is {
			job_send(d, j, msg)
		} else {
			job_send(d, j, reply_log(line))
		}
	}
}

job_finish :: proc(d: ^Daemon, j: ^Job, code: int) {
	stdout := string(j.out[:])
	stderr := string(j.err[:])
	desc := describe(j.req)
	done := true

	switch j.phase {
	case .Plan:
		plan := palm_document(stdout)
		if code != 0 || plan == "" {
			why := palm_error(stdout, stderr, code)
			logf(d, "%s: %s: palm exit %d: %s", j.who, desc, code, why)
			job_send(d, j, reply_error("failed", code != 0 ? code : 7, why))
		} else {
			id := plan_id_of(j.req, plan, context.temp_allocator)
			logf(d, "%s: %s: plan %s", j.who, desc, id)
			job_send(d, j, fmt.tprintf(`{{"type":"plan","plan_id":"%s","plan":%s}}`, id, plan))
		}

	case .Check:
		plan := palm_document(stdout)
		if code != 0 || plan == "" {
			why := palm_error(stdout, stderr, code)
			logf(d, "%s: %s: planning again failed, palm exit %d: %s", j.who, desc, code, why)
			job_send(d, j, result_json(false, code != 0 ? code : 7, why, "plan", ""))
		} else if id := plan_id_of(j.req, plan, context.temp_allocator); id != j.req.plan_id {
			logf(d, "%s: %s: refused: the plan is now %s", j.who, desc, id)
			job_send(d, j, result_json(false, 4, "the plan has changed since it was shown; review it again", "plan", plan))
		} else {
			j.plan = strings.clone(plan)
			j.phase = .Run
			if err := job_spawn(d, j); err != "" {
				logf(d, "%s: %s: %s", j.who, desc, err)
				job_send(d, j, result_json(false, 7, err, "plan", plan))
			} else {
				done = false
			}
		}

	case .Run:
		key := j.req.op == .Update ? "update" : "plan"
		doc := j.req.op == .Update ? palm_document(stdout) : j.plan
		if code == 0 {
			logf(d, "%s: %s: done", j.who, desc)
			job_send(d, j, result_json(true, 0, "", key, doc))
		} else {
			why := palm_error(stdout, stderr, code)
			logf(d, "%s: %s: palm exit %d: %s", j.who, desc, code, why)
			job_send(d, j, result_json(false, code, why, key, doc))
		}
	}

	if done {
		delete(j.out)
		delete(j.err)
		delete(j.errline)
		free(j)
		d.job = nil
	}
}

result_json :: proc(ok: bool, code: int, err: string, key, doc: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"type":"result","ok":%v,"code":%d,"error":`, ok, code)
	json_quote(&sb, err)
	if doc != "" {
		fmt.sbprintf(&sb, `,"%s":%s`, key, doc)
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// A client, for the serial console and for tests
// ---------------------------------------------------------------------------

// client_request sends one request and prints every reply, one per line, until
// a plan, a result or an error arrives. The JSON is sent exactly as given --
// this is how a malicious request is tried against the daemon. Exit status:
// 0 for a plan or a successful result, else the reply's code (or 6 when the
// daemon cannot be reached).
client_request :: proc(sock, request: string) -> int {
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		fmt.eprintfln("palmd: socket: %v", e)
		return 6
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)sock)
	if ce := linux.connect(fd, &addr); ce != .NONE {
		fmt.eprintfln("palmd: connect(%s): %v", sock, ce)
		return 6
	}
	defer linux.close(fd)
	if !send_frame(fd, request) {
		fmt.eprintln("palmd: the daemon closed the connection")
		return 6
	}
	buf := make([dynamic]u8)
	for {
		payload, got, bad := next_frame(&buf)
		if bad {
			fmt.eprintln("palmd: bad frame from the daemon")
			return 7
		}
		if got {
			fmt.println(payload)
			switch {
			case strings.has_prefix(payload, `{"type":"plan"`):
				return 0
			case strings.has_prefix(payload, `{"type":"result","ok":true`):
				return 0
			case strings.has_prefix(payload, `{"type":"result"`), strings.has_prefix(payload, `{"type":"error"`):
				return reply_code(payload)
			}
			continue
		}
		chunk: [4096]u8
		n, re := linux.read(fd, chunk[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE || n <= 0 {
			fmt.eprintln("palmd: the daemon closed the connection")
			return 6
		}
		append(&buf, ..chunk[:n])
	}
}

reply_code :: proc(payload: string) -> int {
	i := strings.index(payload, `"code":`)
	if i < 0 {
		return 7
	}
	n := 0
	for c in transmute([]u8)payload[i + 7:] {
		if c < '0' || c > '9' {break}
		n = n * 10 + int(c - '0')
	}
	return n == 0 ? 7 : n
}
