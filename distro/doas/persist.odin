package doas

// `persist`: after one password, none for five minutes — on that terminal,
// in that login session, and nowhere else.
//
// OpenBSD keeps this in the kernel (TIOCSETVERAUTH). Linux has nothing like
// it, so it is a file per (user, terminal, session) in /run/doas, a
// directory only root can enter, named after
//
//	uid - terminal device - session id - start time of the session leader
//
// The start time is what makes a recycled session id a different key: a new
// shell that happens to get the old one's pid does not inherit its
// authentication. The file holds the CLOCK_BOOTTIME of the password, which
// cannot be set back; /run is emptied at every boot. Without a controlling
// terminal there is no key, and persist simply asks every time.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "../login/auth"

PERSIST_DIR :: "/run/doas"
PERSIST_FOR :: 5 * 60 * 1000 // ms

// proc_stat_fields returns the fields of /proc/<pid>/stat after the command
// name (which may itself hold spaces and parentheses, so the split is after
// the *last* ')'). Index 0 is the state, the third field of the file.
@(private = "file")
proc_stat_fields :: proc(pid: string) -> ([]string, bool) {
	text, ok := auth.read_text(fmt.tprintf("/proc/%s/stat", pid))
	if !ok {
		return nil, false
	}
	close := strings.last_index_byte(text, ')')
	if close < 0 || close + 2 > len(text) {
		return nil, false
	}
	return strings.fields(text[close + 2:], context.temp_allocator), true
}

// persist_key names this caller's file, or "" when there is none to have.
persist_key :: proc(uid: u32) -> string {
	self, ok := proc_stat_fields("self")
	// state ppid pgrp session tty_nr ... : session is [3], tty_nr [4].
	if !ok || len(self) < 5 {
		return ""
	}
	sid := self[3]
	tty := self[4]
	if tty == "0" || sid == "0" {
		return ""
	}
	leader, lok := proc_stat_fields(sid)
	// starttime is the 22nd field of the file, [19] here.
	if !lok || len(leader) < 20 {
		return ""
	}
	for s in ([]string{sid, tty, leader[19]}) {
		if _, nok := strconv.parse_i64(s); !nok {
			return ""
		}
	}
	return fmt.tprintf("%d-%s-%s-%s", uid, tty, sid, leader[19])
}

// persist_valid: was the password given on this key within five minutes?
persist_valid :: proc(key: string) -> bool {
	if key == "" || auth.ensure_private_dir(PERSIST_DIR) != "" {
		return false
	}
	path := fmt.ctprintf("%s/%s", PERSIST_DIR, key)
	fd, e := linux.open(path, {.NOFOLLOW, .CLOEXEC})
	if e != .NONE {
		return false
	}
	defer linux.close(fd)
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE || !linux.S_ISREG(st.mode) || st.uid != 0 {
		return false
	}
	buf: [32]u8
	n, _ := linux.read(fd, buf[:])
	if n <= 0 {
		return false
	}
	t, ok := strconv.parse_i64(strings.trim_space(string(buf[:n])))
	if !ok {
		return false
	}
	now := auth.now_ms()
	return now >= t && now - t < PERSIST_FOR
}

persist_set :: proc(key: string) {
	if key == "" || auth.ensure_private_dir(PERSIST_DIR) != "" {
		return
	}
	tmp := fmt.ctprintf("%s/.%s.%d", PERSIST_DIR, key, linux.getpid())
	fd, e := linux.open(tmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return
	}
	s := fmt.tprintf("%d\n", auth.now_ms())
	linux.write(fd, transmute([]u8)s)
	linux.close(fd)
	linux.rename(tmp, fmt.ctprintf("%s/%s", PERSIST_DIR, key))
}

// persist_clear is `doas -L`: forget this terminal's authentication.
persist_clear :: proc(key: string) {
	if key == "" || auth.ensure_private_dir(PERSIST_DIR) != "" {
		return
	}
	linux.unlink(fmt.ctprintf("%s/%s", PERSIST_DIR, key))
}
