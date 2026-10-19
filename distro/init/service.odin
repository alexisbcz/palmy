package main

// Services: the files in /etc/palm/services/ and the supervisor that keeps
// them running.
//
// One file per service, named after it, one `key = value` per line:
//
//	cmd     = /usr/bin/palm-login     # required; split on spaces, no shell
//	user    = root                    # default root
//	restart = always                  # always | never   (default always)
//	after   = network                 # another service's name
//	tty     = /dev/ttyS0              # stdin/out/err on that tty, own session
//	env     = KEY=value               # repeatable
//
// The lifecycle of a service:
//
//	Waiting ──(its `after` is satisfied)──▶ Running ──(exits)──▶ Backoff ─┐
//	   ▲                                       │  restart = never         │
//	   │                                       ▼                          │
//	   │                                     Done                         │
//	   └──────────────────────(the backoff delay elapses)─────────────────┘
//
// `after = X` is satisfied once X is running, for a long-lived X, or once X
// has exited, for a `restart = never` X — a one-shot is "after" when it has
// finished, a daemon when it has started. A service waiting on a name that
// does not exist starts at once with a warning, and one whose dependency has
// not come up within AFTER_TIMEOUT_MS starts anyway: a missing network is a
// reason to log, not a reason never to show a login prompt.
//
// Restarts back off: a service that dies within STABLE_MS of starting waits
// twice as long as last time before the next try (1 s, 2 s, 4 s ... 30 s); one
// that ran for longer than that is restarted after a second, as if new.
//
// The built-in service `network` runs `udhcpc` on eth0 when both exist, as a
// one-shot: udhcpc stays in the foreground until it has a lease (or has given
// up for now) and then forks itself into the background to renew it, so its
// foreground exit is exactly the moment `after = network` should mean. A file
// named `network` in /etc/palm/services replaces the built-in.
//
// A service is masked, never started, while a file of its name exists in
// /etc/palm/services.off/. That lets one package turn off another's service
// without deleting a file palm owns (so `palm verify` stays clean): the live
// installer's palmframe-live masks palmframe-base's palm-login and
// getty-ttyS0 this way. The mask also stops the built-in network.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/linux"

Restart :: enum u8 {
	Always,
	Never,
}

Service_State :: enum u8 {
	Waiting,
	Running,
	Backoff,
	Done,
	Stopping, // SIGTERM sent by a reload; SIGKILL at stop_at
}

Service :: struct {
	name:       string,
	cmd:        []string,
	user:       string,
	restart:    Restart,
	after:      string,
	tty:        string,
	env:        [dynamic]string,

	// supervisor state
	state:      Service_State,
	pid:        linux.Pid,
	started_at: i64,
	wait_since: i64,
	restart_at: i64,
	backoff_ms: i64,
	warned:     bool,
	builtin:    bool, // network, single: no file of its own
	stop_at:    i64,
	removing:   bool, // Stopping because its file is gone or masked
	pending:    ^Service, // Stopping to restart with this definition
}

AFTER_TIMEOUT_MS :: 30_000
STABLE_MS :: 10_000
BACKOFF_MIN_MS :: 1_000
BACKOFF_MAX_MS :: 30_000

SERVICE_DIR :: "/etc/palm/services"
MASK_DIR :: "/etc/palm/services.off"

// masked says whether /etc/palm/services.off/<name> exists (see the header).
masked :: proc(name: string, mask_dir := MASK_DIR) -> bool {
	return exists(strings.concatenate({mask_dir, "/", name}, context.temp_allocator))
}
DEFAULT_PATH :: "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

// parse_service reads one service file. An unknown key is an error rather
// than ignored, so a typo ("restrat = never") is reported at boot instead of
// silently meaning the default.
parse_service :: proc(name, text: string, allocator := context.allocator) -> (s: Service, err: string) {
	s.name = strings.clone(name, allocator)
	s.user = "root"
	s.restart = .Always
	s.env = make([dynamic]string, allocator)
	lineno := 0
	for raw in strings.split_lines(text, allocator) {
		lineno += 1
		line := strings.trim_space(trim_comment(raw))
		if line == "" {continue}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			return s, fmt.aprintf("line %d: expected key = value", lineno, allocator = allocator)
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		switch key {
		case "cmd":
			s.cmd = split_fields(val, allocator)
		case "user":
			s.user = val
		case "restart":
			switch val {
			case "always":
				s.restart = .Always
			case "never":
				s.restart = .Never
			case:
				return s, fmt.aprintf("line %d: restart must be always or never, not %q", lineno, val, allocator = allocator)
			}
		case "after":
			s.after = val
		case "tty":
			s.tty = val
		case "env":
			if strings.index_byte(val, '=') <= 0 {
				return s, fmt.aprintf("line %d: env must be KEY=value", lineno, allocator = allocator)
			}
			append(&s.env, val)
		case:
			return s, fmt.aprintf("line %d: unknown key %q", lineno, key, allocator = allocator)
		}
	}
	if len(s.cmd) == 0 {
		return s, "no cmd"
	}
	return s, ""
}

Supervisor :: struct {
	services:  [dynamic]^Service,
	users:     []Passwd_Entry,
	groups:    []Group_Entry,
	autologin: string,
	stopping:  bool,
}

sup: Supervisor

find_service :: proc(name: string) -> ^Service {
	for s in sup.services {
		if s.name == name {return s}
	}
	return nil
}

// Service_File is one entry of /etc/palm/services as read now: parsed, or
// the reason it could not be, or masked.
Service_File :: struct {
	name:   string,
	def:    ^Service,
	err:    string,
	masked: bool,
}

// read_service_files reads every file in the services directory. The parsed
// services keep slices of their text, so both live in the permanent
// allocator for as long as the service does.
read_service_files :: proc(dir := SERVICE_DIR, mask_dir := MASK_DIR) -> (files: [dynamic]Service_File, ok: bool) {
	files = make([dynamic]Service_File, context.temp_allocator)
	names, lok := list_dir(dir)
	if !lok {return files, false}
	slice.sort(names[:])
	for name in names {
		if strings.has_prefix(name, ".") || strings.has_suffix(name, "~") {continue}
		f := Service_File{name = name}
		if masked(name, mask_dir) {
			f.masked = true
			append(&files, f)
			continue
		}
		text, rok := read_file(strings.concatenate({dir, "/", name}, context.temp_allocator))
		if !rok {
			f.err = "cannot be read"
			append(&files, f)
			continue
		}
		parsed, err := parse_service(name, text)
		if err != "" {
			f.err = strings.clone(err, context.temp_allocator)
			append(&files, f)
			continue
		}
		f.def = new(Service)
		f.def^ = parsed
		append(&files, f)
	}
	return files, true
}

// load_services is the boot's first read of /etc/palm/services. A file named
// after a built-in (network) replaces it.
load_services :: proc() -> int {
	files, ok := read_service_files()
	if !ok {
		say("no %s; nothing to supervise", SERVICE_DIR)
		return 0
	}
	added := 0
	for f in files {
		switch {
		case f.masked:
			say("service %s is masked by %s/%s; not started", f.name, MASK_DIR, f.name)
		case f.err != "":
			say("service %s: %s — not started", f.name, f.err)
		case:
			if old := find_service(f.name); old != nil {remove_service(old)}
			f.def.wait_since = now_ms()
			append(&sup.services, f.def)
			added += 1
		}
	}
	return added
}

// --- reload (SIGHUP) -----------------------------------------------------------
//
// `kill -HUP 1` makes /etc/palm/services the truth again, for packages that
// add, change or remove a service:
//
//	a new file                       started
//	a definition that changed        restarted with the new one: SIGTERM to
//	                                 its process group, SIGKILL after 3 s,
//	                                 then started again. A one-shot that has
//	                                 already finished only takes the new
//	                                 definition; it is not run a second time.
//	a file removed, or masked        stopped the same way, and forgotten
//	a file that no longer parses     left running as it was, with a warning
//	the same definition              left alone (comments and spacing are
//	                                 not part of a definition)
//
// The built-in `network` is replaced or stopped only by a file (or a mask)
// of its name. In palm.single SIGHUP does nothing: there are no services.

Reload_Action :: enum u8 {
	Keep,
	Start,
	Change,
	Stop,
	Broken, // the file has an error: keep what runs
}

Reload_Step :: struct {
	name:   string,
	action: Reload_Action,
	def:    ^Service, // Start, Change
	err:    string, // Broken
}

same_definition :: proc(a, b: ^Service) -> bool {
	if a.user != b.user || a.restart != b.restart || a.after != b.after || a.tty != b.tty {return false}
	if len(a.cmd) != len(b.cmd) || len(a.env) != len(b.env) {return false}
	for c, i in a.cmd {if c != b.cmd[i] {return false}}
	for e, i in a.env {if e != b.env[i] {return false}}
	return true
}

// plan_reload compares what is supervised with what the files say. It only
// decides; apply_reload_step acts. Kept separate so the selftest can check
// every decision without forking anything.
plan_reload :: proc(current: []^Service, files: []Service_File, allocator := context.temp_allocator) -> []Reload_Step {
	steps := make([dynamic]Reload_Step, allocator)
	for s in current {
		file: ^Service_File = nil
		for &f in files {
			if f.name == s.name {file = &f}
		}
		switch {
		case file == nil:
			append(&steps, Reload_Step{name = s.name, action = s.builtin ? .Keep : .Stop})
		case file.masked:
			append(&steps, Reload_Step{name = s.name, action = .Stop})
		case file.err != "":
			append(&steps, Reload_Step{name = s.name, action = .Broken, err = file.err})
		case s.builtin || !same_definition(s, file.def):
			append(&steps, Reload_Step{name = s.name, action = .Change, def = file.def})
		case:
			append(&steps, Reload_Step{name = s.name, action = .Keep})
		}
	}
	for f in files {
		known := false
		for s in current {
			if s.name == f.name {known = true}
		}
		if known || f.masked {continue}
		if f.err != "" {
			append(&steps, Reload_Step{name = f.name, action = .Broken, err = f.err})
		} else {
			append(&steps, Reload_Step{name = f.name, action = .Start, def = f.def})
		}
	}
	return steps[:]
}

reload_services :: proc() {
	files, ok := read_service_files()
	if !ok {
		say("SIGHUP: no %s; nothing changed", SERVICE_DIR)
		return
	}
	steps := plan_reload(sup.services[:], files[:])
	counts: [Reload_Action]int
	for st in steps {
		counts[st.action] += 1
		apply_reload_step(st)
	}
	// Definitions read but not taken are freed.
	for f in files {
		if f.def == nil {continue}
		taken := false
		for st in steps {
			if st.def == f.def && (st.action == .Start || st.action == .Change) {taken = true}
		}
		if !taken {free(f.def)}
	}
	broken := counts[.Broken] > 0 ? fmt.tprintf(", %d with errors", counts[.Broken]) : ""
	say("SIGHUP: %d new, %d changed, %d removed, %d unchanged%s", counts[.Start], counts[.Change], counts[.Stop], counts[.Keep], broken)
}

apply_reload_step :: proc(st: Reload_Step) {
	now := now_ms()
	s := find_service(st.name)
	switch st.action {
	case .Keep:
	case .Broken:
		say("service %s: %s — %s", st.name, st.err, s != nil ? "kept as it was" : "not started")
	case .Start:
		st.def.wait_since = now
		append(&sup.services, st.def)
		say("service %s added", st.name)
	case .Stop:
		if s == nil {return}
		if s.pending != nil {
			free(s.pending)
			s.pending = nil
		}
		if (s.state == .Running || s.state == .Stopping) && s.pid > 0 {
			s.removing = true
			begin_stop(s)
		} else {
			say("service %s removed", st.name)
			remove_service(s)
		}
	case .Change:
		if s == nil {return}
		if (s.state == .Running || s.state == .Stopping) && s.pid > 0 {
			if s.pending != nil {free(s.pending)}
			s.pending = st.def
			s.removing = false
			begin_stop(s)
			return
		}
		was_done := s.state == .Done
		take_definition(s, st.def)
		if was_done && s.restart == .Never {
			say("service %s changed; it has already run, so it is not run again", st.name)
			return
		}
		say("service %s changed", st.name)
		s.state = .Waiting
		s.wait_since = now
		s.backoff_ms = 0
	}
}

// take_definition swaps in a new definition and keeps the supervisor state.
// The old definition's strings are not freed: a reload is rare, and they
// are small.
take_definition :: proc(s: ^Service, def: ^Service) {
	old := s^
	s^ = def^
	s.state = old.state
	s.pid = old.pid
	s.started_at = old.started_at
	s.wait_since = old.wait_since
	s.restart_at = old.restart_at
	s.backoff_ms = old.backoff_ms
	free(def)
}

begin_stop :: proc(s: ^Service) {
	if s.state == .Stopping {return}
	say("stopping %s (%s)", s.name, s.removing ? "removed" : "changed")
	s.state = .Stopping
	s.stop_at = now_ms() + 3000
	signal_service(s, .SIGTERM)
}

signal_service :: proc(s: ^Service, sig: linux.Signal) {
	if s.pid <= 0 {return}
	linux.kill(-s.pid, sig)
	linux.kill(s.pid, sig)
	if sig == .SIGTERM && s.tty != "" {
		// An interactive shell ignores SIGTERM but not a hangup, which is
		// what its terminal going away means anyway.
		linux.kill(-s.pid, .SIGHUP)
		linux.kill(-s.pid, .SIGCONT)
	}
}

remove_service :: proc(s: ^Service) {
	for x, i in sup.services {
		if x == s {
			ordered_remove(&sup.services, i)
			break
		}
	}
	if s.pending != nil {free(s.pending)}
	free(s)
}

// add_builtin_network registers the udhcpc one-shot when there is an eth0 and
// a udhcpc to run, and no service file of the same name.
add_builtin_network :: proc() {
	if find_service("network") != nil || masked("network") {return}
	s := new(Service)
	s.name = "network"
	s.user = "root"
	s.restart = .Never
	s.env = make([dynamic]string)
	s.wait_since = now_ms()
	s.builtin = true
	udhcpc := resolve_cmd("udhcpc")
	if exists("/sys/class/net/eth0") && udhcpc != "" {
		// -b: background after the first attempt even without a lease;
		// -t 5 -T 2: five discovers two seconds apart before that.
		s.cmd = slice.clone([]string{udhcpc, "-i", "eth0", "-b", "-t", "5", "-T", "2"})
	} else {
		// Nothing to do: the one-shot is born finished, so `after =
		// network` does not wait for a network that cannot come.
		s.state = .Done
		if !exists("/sys/class/net/eth0") {
			say("no eth0; skipping DHCP")
		} else {
			say("no udhcpc; skipping DHCP")
		}
	}
	append(&sup.services, s)
}

// add_single_shell is palm.single: a root shell on the console's real tty, and
// nothing else.
add_single_shell :: proc() {
	s := new(Service)
	s.name = "single"
	s.user = "root"
	s.restart = .Always
	s.builtin = true
	s.cmd = slice.clone([]string{"/bin/sh", "-l"})
	s.tty = console_tty()
	s.env = make([dynamic]string)
	append(&s.env, "TERM=linux")
	s.wait_since = now_ms()
	append(&sup.services, s)
}

// console_tty finds the device behind /dev/console. A shell on /dev/console
// itself cannot have a controlling terminal, so it gets no job control and
// ctrl-c does nothing; the last name in /sys/class/tty/console/active is the
// primary console (ttyS0 for console=ttyS0), and that can.
console_tty :: proc() -> string {
	if text, ok := read_file("/sys/class/tty/console/active", context.temp_allocator); ok {
		f := split_fields(text, context.temp_allocator)
		if len(f) > 0 {
			return strings.concatenate({"/dev/", f[len(f) - 1]})
		}
	}
	return "/dev/console"
}

resolve_cmd :: proc(prog: string) -> string {
	if strings.index_byte(prog, '/') >= 0 {
		return prog if is_executable(prog) else ""
	}
	for dir in strings.split(DEFAULT_PATH, ":", context.temp_allocator) {
		p := strings.concatenate({dir, "/", prog}, context.temp_allocator)
		if is_executable(p) {return strings.clone(p)}
	}
	return ""
}

// after_ready says whether a waiting service may start now.
after_ready :: proc(s: ^Service, now: i64) -> bool {
	if s.after == "" {return true}
	dep := find_service(s.after)
	if dep == nil {
		if !s.warned {
			say("%s: after = %s, which is not a service; starting anyway", s.name, s.after)
			s.warned = true
		}
		return true
	}
	// A dependency being restarted by a reload (Stopping) is not ready
	// until its new definition is up.
	switch dep.restart {
	case .Never:
		if dep.state == .Done {return true}
	case .Always:
		if dep.state == .Running || dep.state == .Backoff {return true}
	}
	if now - s.wait_since >= AFTER_TIMEOUT_MS {
		say("%s: %s is still not ready after %ds; starting anyway", s.name, s.after, AFTER_TIMEOUT_MS / 1000)
		return true
	}
	return false
}

// supervise starts whatever is due and returns how long the main loop may
// sleep before something else becomes due (-1: until a signal or uevent).
supervise :: proc() -> i64 {
	if sup.stopping {return -1}
	now := now_ms()
	next: i64 = -1
	due :: proc(next: ^i64, at: i64, now: i64) {
		d := max(at - now, 0)
		if next^ < 0 || d < next^ {next^ = d}
	}
	// Loop until nothing changes: starting a service can satisfy another's
	// `after` within the same pass.
	for changed := true; changed; {
		changed = false
		for s in sup.services {
			switch s.state {
			case .Waiting:
				if after_ready(s, now) {
					spawn(s)
					changed = true
				} else {
					due(&next, s.wait_since + AFTER_TIMEOUT_MS, now)
				}
			case .Backoff:
				if now >= s.restart_at {
					spawn(s)
					changed = true
				} else {
					due(&next, s.restart_at, now)
				}
			case .Stopping:
				if now >= s.stop_at {
					say("%s did not stop in 3s; SIGKILL", s.name)
					signal_service(s, .SIGKILL)
					s.stop_at = now + 1000
				}
				due(&next, s.stop_at, now)
			case .Running, .Done:
			}
		}
	}
	return next
}

// service_exited is called from the reaper with a service's exit status.
service_exited :: proc(s: ^Service, status: u32) {
	now := now_ms()
	s.pid = 0
	how := describe_status(status)
	if sup.stopping {
		s.state = .Done
		return
	}
	if s.state == .Stopping {
		if s.removing {
			say("%s stopped and removed", s.name)
			remove_service(s)
		} else if s.pending != nil {
			def := s.pending
			s.pending = nil
			take_definition(s, def)
			say("%s stopped; starting it with its new definition", s.name)
			s.state = .Waiting
			s.wait_since = now
			s.backoff_ms = 0
		} else {
			s.state = .Waiting
			s.wait_since = now
		}
		return
	}
	if s.restart == .Never {
		s.state = .Done
		say("%s finished (%s)", s.name, how)
		return
	}
	if now - s.started_at >= STABLE_MS {
		s.backoff_ms = BACKOFF_MIN_MS
	} else {
		s.backoff_ms = s.backoff_ms == 0 ? BACKOFF_MIN_MS : min(s.backoff_ms * 2, BACKOFF_MAX_MS)
	}
	s.restart_at = now + s.backoff_ms
	s.state = .Backoff
	say("%s exited (%s); restarting in %ds", s.name, how, s.backoff_ms / 1000)
}

describe_status :: proc(status: u32) -> string {
	sig := status & 0x7f
	if sig == 0 {
		return fmt.tprintf("status %d", (status >> 8) & 0xff)
	}
	return fmt.tprintf("killed by signal %d", sig)
}

// Prepared is everything the child needs, built before fork so the child does
// nothing but system calls between fork and exec.
Prepared :: struct {
	path:     cstring,
	argv:     [^]cstring,
	envp:     [^]cstring,
	uid:      linux.Uid,
	gid:      linux.Gid,
	groups:   []linux.Gid,
	home:     cstring,
	tty:      cstring,
	log:      cstring,
}

prepare :: proc(s: ^Service) -> (p: Prepared, err: string) {
	prog := resolve_cmd(s.cmd[0])
	if prog == "" {
		return p, fmt.tprintf("%s: not found or not executable", s.cmd[0])
	}

	user, ok := find_user(sup.users, s.user)
	if !ok {
		if s.user != "root" {
			return p, fmt.tprintf("user %q is not in /etc/passwd", s.user)
		}
		user = Passwd_Entry{name = "root", uid = 0, gid = 0, home = "/root", shell = "/bin/sh"}
	}
	gids := user_groups(sup.groups, user.name, user.gid, context.temp_allocator)
	p.groups = make([]linux.Gid, len(gids), context.temp_allocator)
	for g, i in gids {p.groups[i] = linux.Gid(g)}
	p.uid = linux.Uid(user.uid)
	p.gid = linux.Gid(user.gid)
	home := user.home if user.home != "" else "/"
	p.home = strings.clone_to_cstring(home, context.temp_allocator)

	argv := make([]cstring, len(s.cmd) + 1, context.temp_allocator)
	for a, i in s.cmd {argv[i] = strings.clone_to_cstring(a, context.temp_allocator)}
	p.argv = raw_data(argv)
	p.path = strings.clone_to_cstring(prog, context.temp_allocator)

	// The environment: the account's basics, then the service file's own
	// `env` lines, which win over the basics by coming later (we drop the
	// earlier duplicate so getenv sees only one).
	env := make([dynamic]string, context.temp_allocator)
	shell := user.shell if user.shell != "" else "/bin/sh"
	append(&env, "PATH=" + DEFAULT_PATH)
	append(&env, fmt.tprintf("HOME=%s", home))
	append(&env, fmt.tprintf("USER=%s", user.name))
	append(&env, fmt.tprintf("LOGNAME=%s", user.name))
	append(&env, fmt.tprintf("SHELL=%s", shell))
	append(&env, "TERM=linux")
	if sup.autologin != "" {
		append(&env, fmt.tprintf("PALM_AUTOLOGIN=%s", sup.autologin))
	}
	// The system language (locale.odin), before the service's own env lines
	// so that `env = LANG=...` in a service file still overrides it.
	append(&env, ..system_locale_env(context.temp_allocator))
	for e in s.env {
		key := e[:strings.index_byte(e, '=') + 1]
		for i := len(env) - 1; i >= 0; i -= 1 {
			if strings.has_prefix(env[i], key) {ordered_remove(&env, i)}
		}
		append(&env, e)
	}
	envp := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env {envp[i] = strings.clone_to_cstring(e, context.temp_allocator)}
	p.envp = raw_data(envp)

	if s.tty != "" {
		p.tty = strings.clone_to_cstring(s.tty, context.temp_allocator)
	} else {
		p.log = strings.clone_to_cstring(fmt.tprintf("/var/log/%s.log", s.name), context.temp_allocator)
	}
	return p, ""
}

TIOCSCTTY :: 0x540E
TCSBRK :: 0x5409

spawn :: proc(s: ^Service) {
	now := now_ms()
	s.started_at = now
	p, err := prepare(s)
	if err != "" {
		// A service that cannot even be prepared (missing binary, unknown
		// user) goes through the same backoff as one that crashes, so a
		// package installed later is picked up without a reboot.
		say("%s: %s", s.name, err)
		s.state = .Running
		service_exited(s, 127 << 8)
		return
	}

	pid, ferr := linux.fork()
	if ferr != .NONE {
		say("%s: fork failed (%v)", s.name, ferr)
		s.state = .Backoff
		s.restart_at = now + BACKOFF_MIN_MS
		return
	}
	if pid == 0 {
		child_exec(&p)
	}
	s.pid = pid
	s.state = .Running
	say("started %s (pid %d)", s.name, pid)
}

// child_exec runs in the forked child. Only system calls from here on: the
// prepared strings are already in memory, and a failure is reported on
// whatever stderr the child has and ends in exit(127).
child_exec :: proc(p: ^Prepared) -> ! {
	empty: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)

	// Every service is a session leader, so shutdown can signal its whole
	// process group and a tty service can take its terminal.
	linux.setsid()

	if p.tty != nil {
		fd, err := linux.open(p.tty, {.RDWR})
		if err != .NONE {child_fail("cannot open tty")}
		linux.ioctl(fd, TIOCSCTTY, 1)
		linux.dup2(fd, 0)
		linux.dup2(fd, 1)
		linux.dup2(fd, 2)
	} else {
		null, _ := linux.open("/dev/null", {.RDWR})
		linux.dup2(null, 0)
		log, err := linux.open(p.log, {.WRONLY, .CREAT, .APPEND}, transmute(linux.Mode)u32(0o640))
		if err != .NONE {log = null}
		linux.dup2(log, 1)
		linux.dup2(log, 2)
	}
	linux.close_range(3, max(linux.Fd), {})

	if linux.setgroups(p.groups) != .NONE {child_fail("setgroups failed")}
	if linux.setgid(p.gid) != .NONE {child_fail("setgid failed")}
	if linux.setuid(p.uid) != .NONE {child_fail("setuid failed")}
	if linux.chdir(p.home) != .NONE {linux.chdir("/")}

	linux.execve(p.path, p.argv, p.envp)
	child_fail("exec failed")
}

child_fail :: proc(msg: string) -> ! {
	write_all(2, transmute([]u8)msg)
	write_all(2, {'\n'})
	linux.exit(127)
}

// stop_all is the first half of shutdown: SIGTERM to every service's process
// group and then to everything else, three seconds to go quietly, SIGKILL for
// what is left.
stop_all :: proc() {
	sup.stopping = true
	for s in sup.services {
		if (s.state == .Running || s.state == .Stopping) && s.pid > 0 {
			say("stopping %s", s.name)
		}
	}
	// Let the console finish printing first: a getty shares the serial
	// line with the console, and the hangup below flushes whatever output
	// the line has not sent yet. TCSBRK with a non-zero argument is
	// tcdrain(3).
	linux.ioctl(2, TCSBRK, 1)
	for s in sup.services {
		if (s.state == .Running || s.state == .Stopping) && s.pid > 0 {
			// signal_service also hangs up a tty service: an interactive
			// shell ignores SIGTERM but not that.
			signal_service(s, .SIGTERM)
		}
	}
	linux.kill(-1, .SIGTERM)
	deadline := now_ms() + 3000
	for now_ms() < deadline {
		reap()
		if !anything_left() {break}
		sleep_ms(50)
	}
	if anything_left() {
		say("sending SIGKILL to what is left")
	}
	linux.kill(-1, .SIGKILL)
	sleep_ms(50)
	reap()
}

// anything_left asks the kernel whether init still has children at all:
// waitid(P_ALL, WNOHANG|WNOWAIT) peeks without reaping and says ECHILD only
// when there are none.
anything_left :: proc() -> bool {
	P_ALL :: 0
	WNOHANG :: 1
	WEXITED :: 4
	WNOWAIT :: 0x01000000
	info: [128]u8
	ret := linux.syscall(linux.SYS_waitid, P_ALL, 0, &info[0], WEXITED | WNOHANG | WNOWAIT, 0)
	return ret != -int(linux.Errno.ECHILD)
}

// reap collects every exited child, ours or an orphan reparented to init.
reap :: proc() {
	for {
		status: u32
		pid, err := linux.wait4(-1, &status, {.WNOHANG}, nil)
		if err == .EINTR {continue}
		if err != .NONE || pid <= 0 {return}
		for s in sup.services {
			if s.pid == pid {
				service_exited(s, status)
				break
			}
		}
	}
}
