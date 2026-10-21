package main

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// The rest of what term asks of the operating system, on macOS (see
// sys_linux.odin for the same set on Linux).
//
// The difference that matters is the waiting. On Linux the frame loop is kept
// animating and blocks at the top of the frame body in poll() over the display
// socket and the reader's pipe at once. A Cocoa window has no display
// descriptor (`conn.fd` is -1), so on macOS palmy's own loop does the
// blocking: the reader thread calls palmy.wake(app) when a terminal changed,
// and what wait_for_work used to sleep for becomes a wake_after.
// ---------------------------------------------------------------------------

LOOP_ANIMATES :: false

sys_pipe :: proc() -> (r, w: Fd, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return
	}
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	return fds[0], fds[1], true
}

sys_close :: proc(fd: Fd) {
	posix.close(fd)
}

sys_poke :: proc(fd: Fd) {
	b := [1]u8{1}
	posix.write(fd, raw_data(b[:]), 1)
}

sys_drain :: proc(fd: Fd) {
	buf: [256]u8
	for {
		if posix.read(fd, raw_data(buf[:]), len(buf)) <= 0 {
			return
		}
	}
}

sys_nap_20ms :: proc() {
	time.sleep(20 * time.Millisecond)
}

sys_poll_in :: proc(fds: []Fd, ready: []bool, timeout_ms: int) -> (n: int, fatal: bool) {
	pfds := make([]posix.pollfd, len(fds), context.temp_allocator)
	for fd, i in fds {
		pfds[i] = {fd = fd, events = {.IN}}
	}
	got := posix.poll(raw_data(pfds), posix.nfds_t(len(pfds)), c.int(timeout_ms))
	if got < 0 {
		return 0, posix.errno() != .EINTR
	}
	for pf, i in pfds {
		ready[i] = .IN in pf.revents || .HUP in pf.revents || .ERR in pf.revents
	}
	return int(got), false
}

// sys_wake_loop: the pipe is still written (wait_for_work drains it) and the
// frame loop is woken through palmy, which is safe from any thread.
sys_wake_loop :: proc(pump: ^Pump) {
	sys_poke(pump.wake_w)
	if pump.app != nil {
		p.wake(pump.app)
	}
}

wait_for_work :: proc(a: ^Term_App, timeout_ms: int) {
	switch {
	case timeout_ms == 0:
		p.wake(a.app)
	case timeout_ms > 0:
		p.wake_after(a.app, time.Duration(timeout_ms) * time.Millisecond)
	}
	pump_drain(&a.pump)
}

foreign import libsystem "system:System"

@(default_calling_convention = "c", private = "file")
foreign libsystem {
	// libproc: what /proc/<pid>/comm and /proc/<pid>/cwd are on Linux.
	proc_name :: proc(pid: c.int, buffer: rawptr, size: u32) -> c.int ---
	proc_pidinfo :: proc(pid: c.int, flavor: c.int, arg: u64, buffer: rawptr, size: c.int) -> c.int ---
}

sys_foreground_pgrp :: proc(master: Fd) -> i32 {
	pgrp := posix.tcgetpgrp(master)
	return pgrp > 0 ? i32(pgrp) : 0
}

sys_foreground_name :: proc(master: Fd) -> string {
	pgrp := sys_foreground_pgrp(master)
	if pgrp <= 0 {
		return ""
	}
	buf := make([]u8, 256, context.temp_allocator)
	n := proc_name(c.int(pgrp), raw_data(buf), u32(len(buf)))
	if n <= 0 {
		return ""
	}
	return string(buf[:n])
}

// PROC_PIDVNODEPATHINFO: struct proc_vnodepathinfo is two vnode_info_path,
// the current directory first; each is a 152-byte vnode_info and then a
// MAXPATHLEN path.
@(private = "file")
PROC_PIDVNODEPATHINFO :: 9
@(private = "file")
VNODE_INFO_SIZE :: 152
@(private = "file")
VNODE_PATH_SIZE :: 1024

sys_process_cwd :: proc(pid: i32, buf: []u8) -> string {
	info: [2 * (VNODE_INFO_SIZE + VNODE_PATH_SIZE)]u8
	if proc_pidinfo(c.int(pid), PROC_PIDVNODEPATHINFO, 0, &info, size_of(info)) != size_of(info) {
		return ""
	}
	path := string(cstring(&info[VNODE_INFO_SIZE]))
	if path == "" {
		return ""
	}
	return strings.clone(path, context.temp_allocator)
}

Sys_Read_Err :: enum {
	None,
	Intr,
	Other,
}

sys_open_nb :: proc(path: cstring) -> (fd: Fd, ok: bool) {
	f := posix.open(path, {.NOCTTY, .NONBLOCK, .CLOEXEC})
	return f, f >= 0
}

sys_regular_size :: proc(fd: Fd) -> (regular: bool, size: int, ok: bool) {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return false, 0, false
	}
	return posix.S_ISREG(st.st_mode), int(st.st_size), true
}

// F_GETPATH: the path the kernel opened, symlinks resolved.
sys_real_path :: proc(fd: Fd) -> string {
	buf := make([]u8, 1024, context.temp_allocator)
	if posix.fcntl(fd, posix.FCNTL_Cmd(50), raw_data(buf)) == -1 {
		return ""
	}
	return string(cstring(raw_data(buf)))
}

sys_seek :: proc(fd: Fd, off: int) -> bool {
	return posix.lseek(fd, posix.off_t(off), .SET) >= 0
}

sys_read :: proc(fd: Fd, buf: []u8) -> (n: int, err: Sys_Read_Err) {
	k := posix.read(fd, raw_data(buf), len(buf))
	if k >= 0 {
		return int(k), .None
	}
	if posix.errno() == .EINTR {
		return 0, .Intr
	}
	return 0, .Other
}

sys_unlink :: proc(path: cstring) {
	posix.unlink(path)
}

// For the self-test. There is no /proc, and no regular file under /dev, to
// make the symlink probe with.
SYMLINK_PROBE :: ""

sys_getpid :: proc() -> int {
	return int(posix.getpid())
}

sys_symlink :: proc(target, link: cstring) {
	posix.symlink(target, link)
}

sys_mkfifo :: proc(path: cstring) {
	posix.mkfifo(path, {.IRUSR, .IWUSR})
}
