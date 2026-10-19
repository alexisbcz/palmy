package auth

// What a setuid-root program does before anything else, and how it asks for
// a password.
//
// A setuid program inherits everything from a caller it must not trust:
// file descriptors, resource limits, the umask, signal dispositions, the
// environment. glibc already drops the dangerous environment variables
// (LD_PRELOAD and friends) for a setuid program; the rest is here.
//
//	- fds 0, 1 and 2 are made to exist. A caller who closes stdout would
//	  otherwise get the next file this program opens — /etc/shadow+ — as
//	  fd 1, and every message printed would land in it.
//	- RLIMIT_FSIZE is lifted (a low one would truncate the shadow file
//	  mid-write) and RLIMIT_CORE set to 0; the process is made
//	  non-dumpable, so no core or ptrace can read a password from memory.
//	- The umask is 022, whatever the caller's was.

import "core:crypto"
import "core:sys/linux"
import "core:sys/posix"

PR_SET_DUMPABLE :: 4
RLIM_INFINITY :: ~uint(0)

setuid_prologue :: proc() {
	for fd in 0 ..< 3 {
		if _, e := linux.fcntl(linux.Fd(fd), linux.F_GETFD); e == .EBADF {
			// The lowest free descriptor is the one that is missing.
			linux.open("/dev/null", {.RDWR})
		}
	}
	inf := linux.RLimit{RLIM_INFINITY, RLIM_INFINITY}
	linux.setrlimit(.FSIZE, &inf)
	zero := linux.RLimit{0, 0}
	linux.setrlimit(.CORE, &zero)
	// core:sys/linux.prctl indexes all four arguments, so all four are passed.
	linux.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)
	linux.umask({.IWGRP, .IWOTH})
}

// block_signals blocks every signal that can be blocked and returns the
// mask to restore.
block_signals :: proc() -> linux.Sig_Set {
	all: linux.Sig_Set
	for &w in all {
		w = max(uint)
	}
	old: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_BLOCK, &all, &old)
	return old
}

// ---------------------------------------------------------------------------
// Reading a password from the terminal
// ---------------------------------------------------------------------------

MAX_SECRET :: 1024

@(private = "file")
tty_fd: posix.FD = -1
@(private = "file")
tty_saved: posix.termios

// Ctrl-C at a password prompt must not leave the terminal without echo.
@(private = "file")
on_prompt_signal :: proc "c" (sig: posix.Signal) {
	if tty_fd >= 0 {
		posix.tcsetattr(tty_fd, .TCSAFLUSH, &tty_saved)
		posix.write(tty_fd, raw_data(string("\n")), 1)
	}
	posix._exit(1)
}

// read_secret asks `prompt` on the controlling terminal (/dev/tty, never
// stdin: a password does not come through a pipe) with echo off. The answer
// is written into `buf`; ok is false when there is no terminal, on end of
// input, or when the answer does not fit.
read_secret :: proc(prompt: string, buf: []u8) -> (secret: []u8, ok: bool) {
	fd, e := linux.open("/dev/tty", {.RDWR, .NOCTTY, .CLOEXEC})
	if e != .NONE {
		return nil, false
	}
	defer linux.close(fd)
	pfd := posix.FD(fd)
	if posix.tcgetattr(pfd, &tty_saved) != .OK {
		return nil, false
	}
	tty_fd = pfd
	sigs := [?]posix.Signal{.SIGINT, .SIGQUIT, .SIGTSTP, .SIGHUP, .SIGTERM, .SIGTTIN, .SIGTTOU}
	for s in sigs {
		posix.signal(s, on_prompt_signal)
	}
	defer {
		for s in sigs {
			posix.signal(s, auto_cast posix.SIG_DFL)
		}
	}

	quiet := tty_saved
	quiet.c_lflag -= {.ECHO, .ECHOE, .ECHOK}
	quiet.c_lflag += {.ECHONL, .ICANON}
	posix.tcsetattr(pfd, .TCSAFLUSH, &quiet)
	defer {
		posix.tcsetattr(pfd, .TCSAFLUSH, &tty_saved)
		tty_fd = -1
	}

	linux.write(fd, transmute([]u8)prompt)
	n := 0
	overflow := false
	for {
		c: [1]u8
		r, re := linux.read(fd, c[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE || r <= 0 {
			return nil, false
		}
		if c[0] == '\n' || c[0] == '\r' {
			break
		}
		if n < len(buf) {
			buf[n] = c[0]
			n += 1
		} else {
			overflow = true
		}
	}
	if overflow {
		zero_bytes(buf)
		return nil, false
	}
	return buf[:n], true
}

// zero_bytes wipes a buffer that held a secret, in a way the optimiser
// cannot drop.
zero_bytes :: proc(b: []u8) {
	if len(b) > 0 {
		crypto.zero_explicit(raw_data(b), len(b))
	}
}
