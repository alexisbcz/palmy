package auth

// utmp, wtmp and lastlog: who is logged in, who was, and when each user last
// came in.
//
// The records are glibc's `struct utmp` on x86_64, 384 bytes, because the
// readers are busybox's `who`, `users`, `w` and `last`, which are linked
// against glibc and read exactly that:
//
//	/run/utmp          (= /var/run/utmp)  one slot per login line, rewritten in
//	                   place: USER_PROCESS while a session runs, DEAD_PROCESS after
//	/var/log/wtmp      append-only history: a login record and a logout record
//	                   per session, plus a "reboot" record once per boot
//	/var/log/lastlog   struct lastlog (292 bytes) at offset uid*292: the time and
//	                   line of each user's last login; a sparse file
//
// The graphical session's line is "seat0" — there is no tty under it, and
// that is the name the seat has everywhere else. busybox's serial login
// writes its own records for ttyS0 the same way, so `who` and `last` show
// both.
//
// Every write takes an fcntl lock on the file first, as glibc's pututxline
// and updwtmp do, so a busybox login on the serial console at the same
// moment cannot interleave a half record.

import "core:strings"
import "core:sys/linux"
import "core:time"

UTMP_PATH :: "/run/utmp"
WTMP_PATH :: "/var/log/wtmp"
LASTLOG_PATH :: "/var/log/lastlog"

UT_EMPTY :: 0
UT_BOOT_TIME :: 2
UT_USER_PROCESS :: 7
UT_DEAD_PROCESS :: 8

Utmp :: struct #packed {
	type:     i16,
	_:        [2]u8,
	pid:      i32,
	line:     [32]u8,
	id:       [4]u8,
	user:     [32]u8,
	host:     [256]u8,
	exit:     [2]i16,
	session:  i32,
	tv_sec:   i32,
	tv_usec:  i32,
	addr_v6:  [4]i32,
	_:        [20]u8,
}
#assert(size_of(Utmp) == 384)

Lastlog :: struct #packed {
	time: i32,
	line: [32]u8,
	host: [256]u8,
}
#assert(size_of(Lastlog) == 292)

Utmp_Paths :: struct {
	utmp, wtmp, lastlog: string,
}

SYSTEM_UTMP :: Utmp_Paths{UTMP_PATH, WTMP_PATH, LASTLOG_PATH}

@(private = "file")
put :: proc(dst: []u8, s: string) {
	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	copy(dst, transmute([]u8)s)
}

// make_utmp fills a record with the current time.
make_utmp :: proc(type: i16, pid: i32, line, id, user: string) -> Utmp {
	r: Utmp
	r.type = type
	r.pid = pid
	r.session = pid
	put(r.line[:], line)
	put(r.id[:], id)
	put(r.user[:], user)
	ns := time.to_unix_nanoseconds(time.now())
	r.tv_sec = i32(ns / 1e9)
	r.tv_usec = i32((ns % 1e9) / 1000)
	return r
}

@(private = "file")
lock_whole :: proc(fd: linux.Fd, type: linux.FLock_Type) {
	fl := linux.FLock{type = type, whence = .SET}
	// Wait at most about a second for whoever holds it; a stuck lock must
	// not stop a login.
	for _ in 0 ..< 20 {
		if linux.fcntl(fd, linux.F_SETLK, &fl) == .NONE || type == .UNLCK {
			return
		}
		time.sleep(50 * time.Millisecond)
	}
}

@(private = "file")
open_record_file :: proc(path: string, flags: linux.Open_Flags) -> (linux.Fd, bool) {
	if path == "" {
		return -1, false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, e := linux.open(cpath, flags + {.CREAT, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if e != .NONE {
		return -1, false
	}
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE || !linux.S_ISREG(st.mode) {
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

// utmp_put writes `r` into utmp, over the slot with the same id (or line)
// if there is one, at the end otherwise — pututline(3)'s rule.
utmp_put :: proc(path: string, r: Utmp) -> bool {
	fd, ok := open_record_file(path, {.RDWR})
	if !ok {
		return false
	}
	defer linux.close(fd)
	lock_whole(fd, .WRLCK)
	defer lock_whole(fd, .UNLCK)

	rec := r
	slot: i64 = -1
	off: i64 = 0
	for {
		have: Utmp
		n, e := linux.pread(fd, ([^]u8)(&have)[:size_of(Utmp)], off)
		if e != .NONE || n < size_of(Utmp) {
			break
		}
		if have.type >= 5 && have.type <= 8 && have.id == rec.id {
			slot = off
			break
		}
		off += size_of(Utmp)
	}
	if slot < 0 {
		slot = off // the end, rounded down to a whole record
	}
	n, e := linux.pwrite(fd, ([^]u8)(&rec)[:size_of(Utmp)], slot)
	return e == .NONE && n == size_of(Utmp)
}

// wtmp_append adds `r` to the history.
wtmp_append :: proc(path: string, r: Utmp) -> bool {
	fd, ok := open_record_file(path, {.RDWR})
	if !ok {
		return false
	}
	defer linux.close(fd)
	lock_whole(fd, .WRLCK)
	defer lock_whole(fd, .UNLCK)
	st: linux.Stat
	linux.fstat(fd, &st)
	// A torn record left by a crash would shift every later one; start the
	// new record on a record boundary.
	end := i64(st.size) - i64(st.size) % size_of(Utmp)
	rec := r
	n, e := linux.pwrite(fd, ([^]u8)(&rec)[:size_of(Utmp)], end)
	if e == .NONE && n == size_of(Utmp) {
		linux.ftruncate(fd, end + size_of(Utmp))
		return true
	}
	return false
}

// lastlog_put records the last login of `uid`.
lastlog_put :: proc(path: string, uid: u32, line: string, when_sec: i32) -> bool {
	fd, ok := open_record_file(path, {.RDWR})
	if !ok {
		return false
	}
	defer linux.close(fd)
	r: Lastlog
	r.time = when_sec
	put(r.line[:], line)
	n, e := linux.pwrite(fd, ([^]u8)(&r)[:size_of(Lastlog)], i64(uid) * size_of(Lastlog))
	return e == .NONE && n == size_of(Lastlog)
}

// lastlog_get reads it back (0 when the user has never logged in).
lastlog_get :: proc(path: string, uid: u32) -> (r: Lastlog, ok: bool) {
	fd, e := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	if e != .NONE {
		return {}, false
	}
	defer linux.close(fd)
	n, re := linux.pread(fd, ([^]u8)(&r)[:size_of(Lastlog)], i64(uid) * size_of(Lastlog))
	return r, re == .NONE && n == size_of(Lastlog) && r.time != 0
}

// record_login is everything a login writes: utmp, wtmp and lastlog.
record_login :: proc(p: Utmp_Paths, pid: i32, line, id, user: string, uid: u32) {
	r := make_utmp(UT_USER_PROCESS, pid, line, id, user)
	utmp_put(p.utmp, r)
	wtmp_append(p.wtmp, r)
	lastlog_put(p.lastlog, uid, line, r.tv_sec)
}

// record_logout marks the line free again, and logs the logout.
record_logout :: proc(p: Utmp_Paths, pid: i32, line, id: string) {
	r := make_utmp(UT_DEAD_PROCESS, pid, line, id, "")
	utmp_put(p.utmp, r)
	wtmp_append(p.wtmp, r)
}

// record_boot writes the "reboot" record `last` shows as "system boot",
// dated when the kernel started, not when this ran.
record_boot :: proc(p: Utmp_Paths, uptime_sec: i64) {
	r := make_utmp(UT_BOOT_TIME, 0, "~", "~~", "reboot")
	r.tv_sec -= i32(uptime_sec)
	r.tv_usec = 0
	utmp_put(p.utmp, r)
	wtmp_append(p.wtmp, r)
}
