package main

import "core:c"
import "core:strings"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// The pseudo-terminal on macOS.
//
// There is no /dev/ptmx-and-ioctl recipe to write out by hand here: openpty
// and login_tty are in libutil, which on macOS is part of the system and
// costs nothing to link. openpty also takes the window size, which matters --
// a master from posix_openpt refuses TIOCSWINSZ until a slave is open.
// login_tty in the child does what the Linux side spells out: setsid, make
// the slave the controlling terminal (TIOCSCTTY), and dup it onto 0, 1, 2.
// ---------------------------------------------------------------------------

Fd :: posix.FD
Pid :: posix.pid_t
Signal :: posix.Signal

foreign import util "system:util"
foreign import libsystem "system:System"

@(default_calling_convention = "c", private = "file")
foreign util {
	openpty :: proc(amaster, aslave: ^c.int, name: [^]u8, termp: rawptr, winp: ^Winsize) -> c.int ---
	login_tty :: proc(fd: c.int) -> c.int ---
}

@(default_calling_convention = "c", private = "file")
foreign libsystem {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

// _IOW('t', 103, struct winsize)
@(private = "file")
TIOCSWINSZ_DARWIN :: c.ulong(0x80087467)

pty_spawn :: proc(cfg: Pty_Config) -> (p: Pty, err: string) {
	ws := winsize(cfg.cols, cfg.rows, cfg.cell_w, cfg.cell_h)
	pm, ps: c.int
	namebuf: [128]u8
	if openpty(&pm, &ps, raw_data(namebuf[:]), nil, &ws) != 0 {
		return {}, "openpty failed"
	}
	master, slave := Fd(pm), Fd(ps)
	// Non-blocking on the master's description only, as on Linux; neither
	// end leaks into the child's exec except as its terminal.
	flags := posix.fcntl(master, .GETFL)
	posix.fcntl(master, .SETFL, flags | c.int(posix.O_NONBLOCK))
	posix.fcntl(master, .SETFD, posix.FD_CLOEXEC)
	posix.fcntl(slave, .SETFD, posix.FD_CLOEXEC)
	slave_path := strings.clone(string(cstring(raw_data(namebuf[:]))))

	// Everything the child needs is built before the fork, as in
	// pty_linux.odin: after it, allocating is not safe.
	cargv := make([]cstring, len(cfg.argv) + 1, context.allocator)
	for a, i in cfg.argv {
		cargv[i] = strings.clone_to_cstring(a)
	}
	cargv[len(cfg.argv)] = nil
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
	ccwd: cstring = nil
	if cfg.cwd != "" {
		ccwd = strings.clone_to_cstring(cfg.cwd)
	}

	pid := posix.fork()
	if pid < 0 {
		posix.close(master)
		posix.close(slave)
		return {}, "fork failed"
	}
	if pid == 0 {
		// --- child ---------------------------------------------------
		posix.close(master)
		if login_tty(c.int(slave)) != 0 {
			posix._exit(127)
		}
		if ccwd != nil {
			posix.chdir(ccwd)
		}
		posix.execve(cpath, raw_data(cargv), raw_data(cenv))
		msg := "term: cannot execute the shell\r\n"
		posix.write(2, raw_data(msg), len(msg))
		posix._exit(127)
	}

	// --- parent ------------------------------------------------------
	posix.close(slave)
	return Pty{master = master, pid = pid, name = slave_path}, ""
}

pty_resize :: proc(p: ^Pty, cols, rows: int, cell_w := 0, cell_h := 0) {
	if p.master <= 0 {
		return
	}
	ws := winsize(cols, rows, cell_w, cell_h)
	ioctl(c.int(p.master), TIOCSWINSZ_DARWIN, &ws)
}

pty_read :: proc(p: ^Pty, buf: []u8) -> (n: int, done: bool) {
	if p.master <= 0 {
		return 0, true
	}
	got := posix.read(p.master, raw_data(buf), len(buf))
	if got > 0 {
		return int(got), false
	}
	if got == 0 {
		return 0, true
	}
	#partial switch posix.errno() {
	case .EAGAIN, .EINTR:
		return 0, false
	}
	// EIO: the last slave closed, the child is gone.
	return 0, true
}

pty_write :: proc(p: ^Pty, data: []u8) {
	if p.master <= 0 || len(data) == 0 {
		return
	}
	off := 0
	for off < len(data) {
		rest := data[off:]
		n := posix.write(p.master, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			// The child is not reading; drop the tail rather than block.
			return
		}
		off += int(n)
	}
}

pty_reap :: proc(p: ^Pty) -> bool {
	if p.exited || p.pid <= 0 {
		return p.exited
	}
	status: c.int
	if posix.waitpid(p.pid, &status, {.NOHANG}) == p.pid {
		p.exited = true
		p.status = u32(status)
	}
	return p.exited
}

pty_signal :: proc(p: ^Pty, sig: Signal) {
	if p.pid > 0 {
		posix.kill(-p.pid, sig)
	}
}

pty_close :: proc(p: ^Pty) {
	if p.master > 0 {
		posix.close(p.master)
		p.master = 0
	}
}
