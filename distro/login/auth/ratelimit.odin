package auth

// How fast a password may be guessed.
//
// Every failure is counted against a key (an account, or a seat). The first
// two failures in a row cost the base delay; from the third on, the wait
// before the next attempt is even *looked at* doubles, up to a minute:
//
//	failures   1     2     3     4     5     6      7      8+
//	wait       1.5s  1.5s  3s    6s    12s   24s    48s    60s     (base 1.5s)
//
// A success clears the count, and so does a quarter of an hour without a
// failure. An attempt made while the key is waiting is refused without the
// password being checked at all, so hammering does not get more guesses in.
//
// Time is CLOCK_BOOTTIME: it cannot be set back, not even by root, and it
// keeps counting through a suspend, so neither a clock change nor a sleep
// shortens a wait.
//
// palm-login keeps its counts in memory (it lives as long as the machine).
// doas and passwd are new processes each time, so their counts live in
// files under /run/faillock, one per user, root-only, gone at reboot; each
// attempt is written down *before* the password is checked, so several
// copies started at once all count.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

FREE_FAILURES :: 2
MAX_WAIT :: 60 * time.Second
QUIET_RESET :: 15 * time.Minute
FAILLOCK_DIR :: "/run/faillock"

Tally :: struct {
	failures: int,
	last:     i64, // CLOCK_BOOTTIME, milliseconds, of the last failure
}

now_ms :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.BOOTTIME)
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

// tally_wait_for is the wait that `failures` consecutive failures earn.
tally_wait_for :: proc(failures: int, base: time.Duration) -> time.Duration {
	if failures <= 0 {
		return 0
	}
	if failures <= FREE_FAILURES {
		return base
	}
	shift := min(failures - FREE_FAILURES, 16)
	return min(base * time.Duration(1 << uint(shift)), MAX_WAIT)
}

// tally_refresh forgets failures that are old enough.
tally_refresh :: proc(t: ^Tally, now: i64) {
	if t.failures > 0 && (now - t.last > i64(QUIET_RESET / time.Millisecond) || now < t.last) {
		t^ = {}
	}
}

// tally_remaining is how long until the key may try again; 0 means now.
tally_remaining :: proc(t: Tally, now: i64, base: time.Duration) -> time.Duration {
	if t.failures == 0 {
		return 0
	}
	until := t.last + i64(tally_wait_for(t.failures, base) / time.Millisecond)
	if now >= until {
		return 0
	}
	return time.Duration(until - now) * time.Millisecond
}

tally_fail :: proc(t: ^Tally, now: i64) {
	t.failures += 1
	t.last = now
}

// wait_words is a wait as a person reads it: "12 seconds", "1 minute".
wait_words :: proc(d: time.Duration) -> string {
	s := int((d + time.Second - 1) / time.Second)
	if s >= 60 && s % 60 == 0 {
		m := s / 60
		return fmt.tprintf("%d minute%s", m, m == 1 ? "" : "s")
	}
	return fmt.tprintf("%d second%s", s, s == 1 ? "" : "s")
}

// ---------------------------------------------------------------------------
// The files under /run/faillock (doas, passwd)
// ---------------------------------------------------------------------------

Faillock :: struct {
	fd:    linux.Fd,
	tally: Tally,
}

// faillock_open opens (creating) the tally of `uid` and takes an exclusive
// lock on it, held until faillock_close. Must run as root. The directory is
// checked to be root's and private before anything in it is trusted.
faillock_open :: proc(uid: u32, dir := FAILLOCK_DIR) -> (fl: Faillock, err: string) {
	if e := ensure_private_dir(dir); e != "" {
		return {}, e
	}
	path := fmt.ctprintf("%s/%d", dir, uid)
	fd, oe := linux.open(path, {.RDWR, .CREAT, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if oe != .NONE {
		return {}, fmt.tprintf("%s/%d: %v", dir, uid, oe)
	}
	st: linux.Stat
	if linux.fstat(fd, &st) == .NONE && st.uid == 0 && st.gid != 0 {
		linux.fchown(fd, 0, 0)
	}
	if linux.fstat(fd, &st) != .NONE || !linux.S_ISREG(st.mode) || st.uid != 0 {
		linux.close(fd)
		return {}, fmt.tprintf("%s/%d is not a root-owned file", dir, uid)
	}
	if fe := linux.flock(fd, {.EX}); fe != .NONE {
		linux.close(fd)
		return {}, fmt.tprintf("lock %s/%d: %v", dir, uid, fe)
	}
	fl.fd = fd
	buf: [64]u8
	n, _ := linux.pread(fd, buf[:], 0)
	if n > 0 {
		fields := strings.fields(string(buf[:n]), context.temp_allocator)
		if len(fields) == 2 {
			f, fok := strconv.parse_int(fields[0])
			l, lok := strconv.parse_i64(fields[1])
			if fok && lok && f >= 0 {
				fl.tally = {failures = f, last = l}
			}
		}
	}
	tally_refresh(&fl.tally, now_ms())
	return fl, ""
}

// faillock_store writes the tally back; the lock stays held.
faillock_store :: proc(fl: ^Faillock) {
	buf: [64]u8
	s := fmt.bprintf(buf[:], "%d %d\n", fl.tally.failures, fl.tally.last)
	linux.ftruncate(fl.fd, 0)
	linux.pwrite(fl.fd, transmute([]u8)s, 0)
	linux.fsync(fl.fd)
}

faillock_close :: proc(fl: ^Faillock) {
	if fl.fd > 0 {
		linux.close(fl.fd) // drops the flock
		fl.fd = 0
	}
}

// ensure_private_dir makes `dir` exist as a root-owned 0700 directory, or
// says why it is not one. A directory someone else could write into is
// never used: it would let them plant or remove the files kept there.
ensure_private_dir :: proc(dir: string) -> string {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	// Made by a setuid program, it would get the caller's gid: give it root's.
	if linux.mkdir(cdir, {.IRUSR, .IWUSR, .IXUSR}) == .NONE {
		linux.chown(cdir, 0, 0)
	}
	st: linux.Stat
	if e := linux.lstat(cdir, &st); e != .NONE {
		return fmt.tprintf("%s: %v", dir, e)
	}
	if !linux.S_ISDIR(st.mode) || st.uid != 0 || u32(transmute(u32)st.mode) & 0o077 != 0 {
		return fmt.tprintf("%s is not a private directory owned by root", dir)
	}
	return ""
}
