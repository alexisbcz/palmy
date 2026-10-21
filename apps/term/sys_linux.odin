package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import p "palmy:."

// ---------------------------------------------------------------------------
// The rest of what term asks of the operating system, on Linux: the reader
// thread's self-pipe and poll, waiting for work at the top of the frame body,
// and which process owns the terminal. sys_darwin.odin is the same set on
// macOS. These are the procedures pump.odin, ui.odin and tabs.odin used to
// spell with core:sys/linux inline; the bodies are unchanged.
// ---------------------------------------------------------------------------

// The frame loop is kept turning and the blocking happens in wait_for_work,
// over the display socket and the reader's pipe at once (see ui.odin).
LOOP_ANIMATES :: true

sys_pipe :: proc() -> (r, w: Fd, ok: bool) {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.NONBLOCK, .CLOEXEC}) != .NONE {
		return
	}
	return fds[0], fds[1], true
}

sys_close :: proc(fd: Fd) {
	linux.close(fd)
}

// sys_poke writes one byte to a non-blocking pipe; a full pipe already means
// a wakeup is pending, so EAGAIN is the right answer rather than an error.
sys_poke :: proc(fd: Fd) {
	b := [1]u8{1}
	linux.write(fd, b[:])
}

sys_drain :: proc(fd: Fd) {
	buf: [256]u8
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 {
			return
		}
	}
}

sys_nap_20ms :: proc() {
	ts := linux.Time_Spec{0, 20 * 1000 * 1000}
	linux.nanosleep(&ts, nil)
}

// sys_poll_in waits up to `timeout_ms` for any of `fds` to be readable (or
// hung up, or in error) and sets `ready` for those. n is how many; fatal is
// a poll that failed for a reason other than a signal.
sys_poll_in :: proc(fds: []Fd, ready: []bool, timeout_ms: int) -> (n: int, fatal: bool) {
	pfds := make([]linux.Poll_Fd, len(fds), context.temp_allocator)
	for fd, i in fds {
		pfds[i] = {fd = fd, events = {.IN}}
	}
	got, perr := linux.poll(pfds[:], i32(timeout_ms))
	if perr != .NONE && perr != .EINTR {
		return 0, true
	}
	if got <= 0 {
		return 0, false
	}
	for pf, i in pfds {
		ready[i] = .IN in pf.revents || .HUP in pf.revents || .ERR in pf.revents
	}
	return int(got), false
}

// sys_wake_loop is the reader thread telling the frame loop something
// changed: the self-pipe, which wait_for_work polls.
sys_wake_loop :: proc(pump: ^Pump) {
	sys_poke(pump.wake_w)
}

wait_for_work :: proc(a: ^Term_App, timeout_ms: int) {
	// A held key repeats on palmy's clock, not on any descriptor, so the
	// wait ends when the next repeat is due.
	timeout_ms := timeout_ms
	if r := p.key_repeat_timeout(a.app); r >= 0 && (timeout_ms < 0 || r < timeout_ms) {
		timeout_ms = r
	}
	pfds := [2]linux.Poll_Fd {
		{fd = a.pump.wake_r, events = {.IN}},
		{fd = a.app.win.conn.fd, events = {.IN}},
	}
	p.poll_fds(pfds[:], timeout_ms) // -1 must mean forever on arm64 too
	pump_drain(&a.pump)
}

// sys_foreground_pgrp is the process group that owns the terminal (TIOCGPGRP),
// or 0.
sys_foreground_pgrp :: proc(master: Fd) -> i32 {
	pgrp: i32
	if linux.ioctl(master, 0x540F, uintptr(&pgrp)) != 0 || pgrp <= 0 {
		return 0
	}
	return pgrp
}

// sys_foreground_name is what that process is called.
sys_foreground_name :: proc(master: Fd) -> string {
	pgrp := sys_foreground_pgrp(master)
	if pgrp <= 0 {
		return ""
	}
	path := fmt.tprintf("/proc/%d/comm", pgrp)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return ""
	}
	return strings.trim_space(string(data))
}

// sys_process_cwd is the directory a process is in, or "".
sys_process_cwd :: proc(pid: i32, buf: []u8) -> string {
	link := fmt.ctprintf("/proc/%d/cwd", pid)
	n, err := linux.readlink(link, buf)
	if err == .NONE && n > 0 {
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Reading a file a Kitty transfer names (images.odin decides what may be
// read; these are the calls it reads with).
// ---------------------------------------------------------------------------

Sys_Read_Err :: enum {
	None,
	Intr,
	Other,
}

// sys_open_nb opens for reading, non-blocking (a FIFO cannot hang the
// reader), without making a tty the controlling terminal.
sys_open_nb :: proc(path: cstring) -> (fd: Fd, ok: bool) {
	f, oerr := linux.open(path, {.NOCTTY, .NONBLOCK, .CLOEXEC})
	return f, oerr == .NONE
}

// sys_regular_size is whether an open file is a regular file, and its size.
sys_regular_size :: proc(fd: Fd) -> (regular: bool, size: int, ok: bool) {
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE {
		return false, 0, false
	}
	return st.mode & linux.S_IFMT == linux.S_IFREG, int(st.size), true
}

// sys_real_path is the path the kernel opened, symlinks resolved.
sys_real_path :: proc(fd: Fd) -> string {
	link := fmt.ctprintf("/proc/self/fd/%d", fd)
	buf := make([]u8, 4096, context.temp_allocator)
	n, err := linux.readlink(link, buf)
	if err != .NONE || n <= 0 {
		return ""
	}
	return string(buf[:n])
}

sys_seek :: proc(fd: Fd, off: int) -> bool {
	_, serr := linux.lseek(fd, i64(off), .SET)
	return serr == .NONE
}

sys_read :: proc(fd: Fd, buf: []u8) -> (n: int, err: Sys_Read_Err) {
	k, rerr := linux.read(fd, buf)
	#partial switch rerr {
	case .NONE:
		return k, .None
	case .EINTR:
		return 0, .Intr
	}
	return 0, .Other
}

sys_unlink :: proc(path: cstring) {
	linux.unlink(path)
}

// For the self-test: a symlink whose target is a regular file the transfer
// policy must refuse to read.
SYMLINK_PROBE :: "/proc/self/status"

sys_getpid :: proc() -> int {
	return int(linux.getpid())
}

sys_symlink :: proc(target, link: cstring) {
	linux.symlink(target, link)
}

sys_mkfifo :: proc(path: cstring) {
	linux.mknod(path, linux.S_IFIFO | {.IRUSR, .IWUSR}, 0)
}
