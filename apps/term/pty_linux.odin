package main

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// The pseudo-terminal on Linux.
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

Fd :: linux.Fd
Pid :: linux.Pid
Signal :: linux.Signal

TIOCGPTN :: 0x8004_5430
TIOCSPTLCK :: 0x4004_5431
TIOCSCTTY :: 0x0000_540E
TIOCSWINSZ :: 0x0000_5414
TIOCGWINSZ :: 0x0000_5413

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

	ws := winsize(cfg.cols, cfg.rows, cfg.cell_w, cfg.cell_h)
	linux.ioctl(master, TIOCSWINSZ, uintptr(&ws))

	// Everything the child needs has to be built before the fork: after it,
	// in a process that shares this one's heap, allocating is not safe.
	cargv := make([]cstring, len(cfg.argv) + 1, context.allocator)
	for a, i in cfg.argv {
		cargv[i] = strings.clone_to_cstring(a)
	}
	cargv[len(cfg.argv)] = nil
	// execve does not search $PATH, so `term -e htop` -- and the launcher's
	// `term -e sh -c CMD` -- ran nothing. The search happens here, before
	// the fork, for the same reason as everything else above.
	cpath := cargv[0]
	if len(cfg.argv) > 0 && !strings.contains_rune(cfg.argv[0], '/') {
		if found := find_on_path(cfg.argv[0]); found != "" {
			cpath = strings.clone_to_cstring(found)
		}
	}
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
		linux.execve(cpath, raw_data(cargv), raw_data(cenv))
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

pty_resize :: proc(p: ^Pty, cols, rows: int, cell_w := 0, cell_h := 0) {
	if p.master <= 0 {
		return
	}
	ws := winsize(cols, rows, cell_w, cell_h)
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

