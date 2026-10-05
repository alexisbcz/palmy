package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// The pseudo-terminal.
//
// `forkpty` lives in libutil, and linking libutil would put a fourth line in
// this binary's ldd output. It is also about forty lines of ioctls, so it is
// written out here: open /dev/ptmx, ask the kernel which pts it gave us,
// unlock it, fork, and have the child make the slave its controlling
// terminal before it execs.
//
// The part that is easy to get wrong is the child side. Between fork and exec
// the child must call setsid() -- otherwise TIOCSCTTY fails and the shell
// never gets a controlling terminal, which means no job control, no Ctrl+C,
// and a vim that cannot read the window size.
// ---------------------------------------------------------------------------

TIOCGPTN :: 0x8004_5430
TIOCSPTLCK :: 0x4004_5431
TIOCSCTTY :: 0x0000_540E
TIOCSWINSZ :: 0x0000_5414
TIOCGWINSZ :: 0x0000_5413

Winsize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

Pty :: struct {
	master: linux.Fd,
	pid:    linux.Pid,
	// Set once the child has been reaped. `status` is the wait status.
	exited: bool,
	status: u32,
	name:   string,
}

Pty_Config :: struct {
	argv:   []string,
	env:    []string,
	cwd:    string,
	cols:   int,
	rows:   int,
}

pty_spawn :: proc(cfg: Pty_Config) -> (p: Pty, err: string) {
	// NONBLOCK is set here rather than with a later fcntl: it applies to
	// this file description only, so the child's slave side is unaffected.
	master, merr := linux.open("/dev/ptmx", {.RDWR, .NOCTTY, .NONBLOCK})
	if merr != .NONE {
		return {}, fmt.aprintf("cannot open /dev/ptmx: %v", merr)
	}

	n: i32
	if linux.ioctl(master, TIOCGPTN, uintptr(&n)) != 0 {
		linux.close(master)
		return {}, "the kernel would not say which pts it allocated"
	}
	unlock: i32 = 0
	if linux.ioctl(master, TIOCSPTLCK, uintptr(&unlock)) != 0 {
		linux.close(master)
		return {}, "cannot unlock the pts"
	}
	slave_path := fmt.aprintf("/dev/pts/%d", n)

	ws := Winsize {
		row = u16(max(cfg.rows, 1)),
		col = u16(max(cfg.cols, 1)),
	}
	linux.ioctl(master, TIOCSWINSZ, uintptr(&ws))

	// Everything the child needs has to be built before the fork: after it,
	// in a process that shares this one's heap, allocating is not safe.
	cargv := make([]cstring, len(cfg.argv) + 1, context.allocator)
	for a, i in cfg.argv {
		cargv[i] = strings.clone_to_cstring(a)
	}
	cargv[len(cfg.argv)] = nil
	cenv := make([]cstring, len(cfg.env) + 1, context.allocator)
	for e, i in cfg.env {
		cenv[i] = strings.clone_to_cstring(e)
	}
	cenv[len(cfg.env)] = nil
	cslave := strings.clone_to_cstring(slave_path)
	ccwd: cstring = nil
	if cfg.cwd != "" {
		ccwd = strings.clone_to_cstring(cfg.cwd)
	}

	pid, ferr := linux.fork()
	if ferr != .NONE {
		linux.close(master)
		return {}, fmt.aprintf("fork failed: %v", ferr)
	}

	if pid == 0 {
		// --- child ---------------------------------------------------
		linux.close(master)
		linux.setsid()
		slave, serr := linux.open(cslave, {.RDWR})
		if serr != .NONE {
			linux.exit(127)
		}
		// Claim it as the controlling terminal. Without this the shell has
		// no job control and Ctrl+C goes nowhere.
		linux.ioctl(slave, TIOCSCTTY, 0)
		linux.dup2(slave, linux.Fd(0))
		linux.dup2(slave, linux.Fd(1))
		linux.dup2(slave, linux.Fd(2))
		if slave > 2 {
			linux.close(slave)
		}
		if ccwd != nil {
			linux.chdir(ccwd)
		}
		linux.execve(cargv[0], raw_data(cargv), raw_data(cenv))
		// Only reached when exec failed. Say so on the terminal the parent
		// is about to show, because a silently empty window is a worse bug
		// report than a one-line error.
		msg := "term: cannot execute the shell\r\n"
		linux.write(linux.Fd(2), transmute([]u8)msg)
		linux.exit(127)
	}

	// --- parent ------------------------------------------------------
	return Pty{master = master, pid = pid, name = slave_path}, ""
}

pty_resize :: proc(p: ^Pty, cols, rows: int) {
	if p.master <= 0 {
		return
	}
	ws := Winsize {
		row = u16(max(rows, 1)),
		col = u16(max(cols, 1)),
	}
	linux.ioctl(p.master, TIOCSWINSZ, uintptr(&ws))
}

pty_read :: proc(p: ^Pty, buf: []u8) -> (n: int, done: bool) {
	if p.master <= 0 {
		return 0, true
	}
	got, err := linux.read(p.master, buf)
	#partial switch err {
	case .NONE:
		// A zero-length read on a pty master is the slave side closing.
		return got, got == 0
	case .EAGAIN, .EINTR:
		return 0, false
	}
	// EIO on a pty master means the last slave closed: the child is gone.
	return 0, true
}

pty_write :: proc(p: ^Pty, data: []u8) {
	if p.master <= 0 || len(data) == 0 {
		return
	}
	off := 0
	for off < len(data) {
		n, err := linux.write(p.master, data[off:])
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			// EAGAIN here means the child is not reading. Dropping the tail
			// is better than blocking the frame loop; a shell that is not
			// reading its input is not going to want it later either.
			return
		}
		off += n
	}
}

// pty_reap collects the child if it has finished, without blocking.
pty_reap :: proc(p: ^Pty) -> bool {
	if p.exited || p.pid <= 0 {
		return p.exited
	}
	status: u32
	got, err := linux.waitpid(p.pid, &status, {.WNOHANG}, nil)
	if err == .NONE && got == p.pid {
		p.exited = true
		p.status = status
	}
	return p.exited
}

// pty_signal sends a signal to the child's process group, which is what
// closing a tab with something still running needs.
pty_signal :: proc(p: ^Pty, sig: linux.Signal) {
	if p.pid > 0 {
		linux.kill(linux.Pid(-p.pid), sig)
	}
}

pty_close :: proc(p: ^Pty) {
	if p.master > 0 {
		linux.close(p.master)
		p.master = 0
	}
}

pty_exit_code :: proc(p: ^Pty) -> int {
	if !p.exited {
		return -1
	}
	if p.status & 0x7F == 0 {
		return int((p.status >> 8) & 0xFF)
	}
	return 128 + int(p.status & 0x7F)
}

// ---------------------------------------------------------------------------
// The environment the child gets
// ---------------------------------------------------------------------------

// child_env builds the environment for the shell: this process's, with the
// terminal variables set and the ones that would lie about the terminal
// removed.
child_env :: proc(term: string, extra: []string) -> []string {
	out := make([dynamic]string)
	drop := [?]string {
		"TERM=",
		"COLORTERM=",
		"TERM_PROGRAM=",
		"TERM_PROGRAM_VERSION=",
		"LINES=",
		"COLUMNS=",
		"TERMCAP=",
	}
	env, _ := os.environ(context.temp_allocator)
	outer: for e in env {
		for d in drop {
			if len(e) >= len(d) && e[:len(d)] == d {
				continue outer
			}
		}
		append(&out, strings.clone(e))
	}
	append(&out, strings.clone(fmt.tprintf("TERM=%s", term)))
	append(&out, strings.clone("COLORTERM=truecolor"))
	append(&out, strings.clone("TERM_PROGRAM=palmy-term"))
	for e in extra {
		append(&out, strings.clone(e))
	}
	return out[:]
}

// default_shell picks what to run. The order matters: an explicit argument
// wins, then $SHELL, then a shell that certainly exists.
default_shell :: proc() -> []string {
	out := make([]string, 1)
	if sh := os.get_env("SHELL", context.temp_allocator); sh != "" {
		out[0] = strings.clone(sh)
	} else {
		out[0] = strings.clone("/bin/sh")
	}
	return out
}
