package login

// Starting a session: becoming the user, and nothing else.
//
// This is the part PAM does on other systems, done by hand in the order that
// cannot be got wrong: everything that needs root (the runtime directory, the
// log file, the supplementary groups) happens first, then setgid, then
// setuid, and only once the uid is checked to have actually changed does the
// session's command run. A session that cannot drop to its user does not
// start at all.

import "auth"
import "core:sys/posix"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

SESSION_PATH :: "/usr/local/bin:/usr/bin:/bin"

Session_Spec :: struct {
	acct:   auth.Account,
	groups: []u32,
	cmd:    []string,
	env:    []string, // added on top of the base environment, and wins
	log:    string, // stdout and stderr; "" keeps palm-login's own
}

// base_env is the environment the contract promises every session.
base_env :: proc(acct:   auth.Account, allocator := context.allocator) -> [dynamic]string {
	env := make([dynamic]string, allocator)
	shell := acct.shell == "" ? "/bin/sh" : acct.shell
	append(&env, fmt.aprintf("HOME=%s", acct.home, allocator = allocator))
	append(&env, fmt.aprintf("USER=%s", acct.name, allocator = allocator))
	append(&env, fmt.aprintf("LOGNAME=%s", acct.name, allocator = allocator))
	append(&env, fmt.aprintf("SHELL=%s", shell, allocator = allocator))
	append(&env, fmt.aprintf("PATH=%s", SESSION_PATH, allocator = allocator))
	append(&env, fmt.aprintf("XDG_RUNTIME_DIR=/run/user/%d", acct.uid, allocator = allocator))
	append(&env, strings.clone("XDG_SESSION_TYPE=wayland", allocator))
	append(&env, strings.clone("XDG_CURRENT_DESKTOP=palmframe", allocator))
	append(&env, strings.clone("XDG_SEAT=seat0", allocator))
	append(&env, strings.clone("LANG=C.UTF-8", allocator))
	return env
}

// merge_env sets each KEY=value of `extra` in `env`, replacing an existing
// KEY rather than appending a second one.
merge_env :: proc(env: ^[dynamic]string, extra: []string, allocator := context.allocator) {
	outer: for e in extra {
		eq := strings.index_byte(e, '=')
		if eq <= 0 {
			continue
		}
		key := e[:eq + 1]
		for &have in env {
			if strings.has_prefix(have, key) {
				have = strings.clone(e, allocator)
				continue outer
			}
		}
		append(env, strings.clone(e, allocator))
	}
}

// find_program resolves argv[0] against the session PATH, the way execvp
// would, so the exec in the child is a single execve with no surprises.
find_program :: proc(name: string, allocator := context.allocator) -> (string, bool) {
	if strings.index_byte(name, '/') >= 0 {
		return strings.clone(name, allocator), os.exists(name)
	}
	path := SESSION_PATH
	for dir in strings.split_iterator(&path, ":") {
		full := fmt.aprintf("%s/%s", dir, name, allocator = allocator)
		if os.exists(full) {
			return full, true
		}
		delete(full, allocator)
	}
	return "", false
}

// ensure_runtime_dir creates /run/user/<uid>, 0700 and owned by the user.
// An existing directory is re-owned and re-moded: whatever made it before is
// not trusted to have made it right.
ensure_runtime_dir :: proc(uid, gid: u32) -> string {
	linux.mkdir("/run/user", {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	path := fmt.ctprintf("/run/user/%d", uid)
	e := linux.mkdir(path, {.IRUSR, .IWUSR, .IXUSR})
	if e != .NONE && e != .EEXIST {
		return fmt.tprintf("mkdir %s: %v", path, e)
	}
	if ce := linux.chown(path, linux.Uid(uid), linux.Gid(gid)); ce != .NONE {
		return fmt.tprintf("chown %s: %v", path, ce)
	}
	linux.chmod(path, {.IRUSR, .IWUSR, .IXUSR})
	return ""
}

@(private = "file")
cstrings :: proc(list: []string) -> [^]cstring {
	out := make([]cstring, len(list) + 1, context.temp_allocator)
	for s, i in list {
		out[i] = strings.clone_to_cstring(s, context.temp_allocator)
	}
	out[len(list)] = nil
	return raw_data(out)
}

// spawn_session forks the session. The child is a new session and process
// group (setsid), so the whole session can be signalled as one with kill(-pid).
spawn_session :: proc(spec: Session_Spec) -> (pid: linux.Pid, err: string) {
	if len(spec.cmd) == 0 {
		return 0, "empty command"
	}
	prog, found := find_program(spec.cmd[0], context.temp_allocator)
	if !found {
		return 0, fmt.tprintf("%s: not found in %s", spec.cmd[0], SESSION_PATH)
	}

	if e := ensure_runtime_dir(spec.acct.uid, spec.acct.gid); e != "" {
		return 0, e
	}

	// The log is opened as root, then handed to the user, so they can read
	// their own session's output and nobody else's.
	log_fd := linux.Fd(-1)
	if spec.log != "" {
		// An existing log is opened without O_CREAT, and a new one is created
		// with O_EXCL: with fs.protected_regular, O_CREAT on a file someone
		// else owns is refused even to root when the directory is sticky.
		clog := strings.clone_to_cstring(spec.log, context.temp_allocator)
		fd, oe := linux.open(clog, {.WRONLY, .APPEND, .CLOEXEC, .NOFOLLOW})
		if oe == .ENOENT {
			fd, oe = linux.open(clog, {.WRONLY, .CREAT, .EXCL, .APPEND, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
		}
		if oe == .NONE {
			linux.fchown(fd, linux.Uid(spec.acct.uid), linux.Gid(spec.acct.gid))
			linux.fchmod(fd, {.IRUSR, .IWUSR})
			log_fd = fd
			msg := fmt.tprintf("\n--- palm-login: starting %v as %s ---\n", spec.cmd, spec.acct.name)
			linux.write(fd, transmute([]u8)msg)
		} else {
			// Not fatal: the session still starts, with palm-login's own
			// stdout and stderr (the service log) as its output.
			fmt.eprintfln("palm-login: cannot open %s: %v", spec.log, oe)
		}
	}
	defer if log_fd >= 0 {linux.close(log_fd)}

	env := base_env(spec.acct, context.temp_allocator)
	merge_env(&env, spec.env, context.temp_allocator)

	// Everything the child needs is built before the fork, so the child does
	// nothing but system calls between fork and exec.
	cprog := strings.clone_to_cstring(prog, context.temp_allocator)
	argv := cstrings(spec.cmd)
	envp := cstrings(env[:])
	gids := make([]linux.Gid, len(spec.groups), context.temp_allocator)
	for g, i in spec.groups {
		gids[i] = linux.Gid(g)
	}
	home := strings.clone_to_cstring(spec.acct.home, context.temp_allocator)
	uid := linux.Uid(spec.acct.uid)
	gid := linux.Gid(spec.acct.gid)

	child, fe := linux.fork()
	if fe != .NONE {
		return 0, fmt.tprintf("fork: %v", fe)
	}
	if child == 0 {
		child_exec(cprog, argv, envp, gids, uid, gid, home, log_fd)
	}
	return child, ""
}

// child_exec runs in the forked child and never returns. On any failure it
// writes one line to the session log (or palm-login's stderr) and exits 127.
@(private = "file")
child_exec :: proc(
	prog: cstring,
	argv, envp: [^]cstring,
	gids: []linux.Gid,
	uid: linux.Uid,
	gid: linux.Gid,
	home: cstring,
	log_fd: linux.Fd,
) -> ! {
	die :: proc(what: string, e: linux.Errno) -> ! {
		buf: [256]u8
		msg := fmt.bprintf(buf[:], "palm-login: session: %s: %v\n", what, e)
		linux.write(2, transmute([]u8)msg)
		linux.exit(127)
	}

	linux.setsid()

	// palm-login ignores SIGPIPE and handles SIGTERM; a session starts with
	// every disposition at its default.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
	posix.signal(.SIGTERM, auto_cast posix.SIG_DFL)
	posix.signal(.SIGINT, auto_cast posix.SIG_DFL)
	posix.signal(.SIGHUP, auto_cast posix.SIG_DFL)
	empty: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)

	if null, e := linux.open("/dev/null", {.RDWR}); e == .NONE {
		linux.dup2(null, 0)
		if null > 2 {
			linux.close(null)
		}
	}
	if log_fd >= 0 {
		linux.dup2(log_fd, 1)
		linux.dup2(log_fd, 2)
	}

	if e := linux.setgroups(gids); e != .NONE {
		die("setgroups", e)
	}
	if e := linux.setgid(gid); e != .NONE {
		die("setgid", e)
	}
	if e := linux.setuid(uid); e != .NONE {
		die("setuid", e)
	}
	// Belt and braces: if any of that silently did nothing, stop here rather
	// than run a user's session as root.
	if linux.getuid() != uid || linux.geteuid() != uid || (uid != 0 && linux.setuid(0) == .NONE) {
		die("dropping privileges did not stick", .EPERM)
	}

	if linux.chdir(home) != .NONE {
		linux.chdir("/")
	}
	e := linux.execve(prog, argv, envp)
	die("execve", e)
}

// signal_session sends `sig` to every process still in the session's process
// group. The leader may already be gone; its children are what this is for.
signal_session :: proc(pid: linux.Pid, sig: linux.Signal) {
	if pid > 0 {
		linux.kill(-pid, sig)
	}
}
