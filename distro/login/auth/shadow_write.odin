package auth

// Changing one line of /etc/shadow without ever leaving a broken one.
//
// The file is never edited in place. The new contents go to /etc/shadow+,
// which is fsynced, given the old file's owner and mode, and renamed over
// /etc/shadow: at every instant the path names either the whole old file or
// the whole new one. The previous version is kept as /etc/shadow-, a hard
// link, the way shadow-utils and busybox keep it.
//
// Two locks, because two families of tools edit these files:
//
//	/etc/.pwd.lock     an fcntl lock, lckpwdf(3)'s: shadow-utils and every
//	                   Palmframe tool take it. The kernel drops it when the
//	                   holder dies, so it can never go stale.
//	/etc/shadow+       created with O_EXCL: busybox's passwd, chpasswd and
//	                   adduser wait for it to disappear, and create it
//	                   themselves, so holding it keeps them out. A crash could
//	                   leave it behind; one older than a minute, found while
//	                   holding .pwd.lock, is taken to be such a leftover.
//
// While the new file is written every catchable signal is blocked, so a
// ctrl-C or a hang-up cannot stop the program between "written" and
// "renamed" — and the setuid callers have already made their real uid root,
// so the user who started them cannot SIGKILL them either. RLIMIT_FSIZE is
// lifted first (harden.odin): a limit inherited from the caller must not
// be able to truncate the file.

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

// Edit is handed the user's current line (found=false: there is none) and
// changes it; returning a non-empty string aborts with that reason.
Shadow_Edit :: #type proc(s: ^Shadow, found: bool, data: rawptr) -> string

Pwd_Lock :: struct {
	fd: linux.Fd,
}

// lock_pwd takes /etc/.pwd.lock (in the shadow file's directory), waiting up
// to `wait` for whoever has it.
lock_pwd :: proc(dir: string, wait := 15 * time.Second) -> (l: Pwd_Lock, err: string) {
	path := fmt.ctprintf("%s/.pwd.lock", dir)
	fd, e := linux.open(path, {.WRONLY, .CREAT, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return {}, fmt.tprintf("%s: %v", path, e)
	}
	fl := linux.FLock{type = .WRLCK, whence = .SET}
	start := time.tick_now()
	for {
		if linux.fcntl(fd, linux.F_SETLK, &fl) == .NONE {
			return {fd = fd}, ""
		}
		if time.tick_since(start) > wait {
			linux.close(fd)
			return {}, "the password files are locked by another program"
		}
		time.sleep(100 * time.Millisecond)
	}
}

unlock_pwd :: proc(l: ^Pwd_Lock) {
	if l.fd > 0 {
		linux.close(l.fd)
		l.fd = 0
	}
}

// update_shadow rewrites `path` with `user`'s line changed by `edit`.
update_shadow :: proc(path: string, user: string, edit: Shadow_Edit, data: rawptr) -> string {
	if !valid_name(user) {
		return "not a valid user name"
	}
	dir := path
	if i := strings.last_index_byte(path, '/'); i > 0 {
		dir = path[:i]
	} else {
		dir = "."
	}

	old_mask := block_signals()
	defer linux.rt_sigprocmask(.SIG_SETMASK, &old_mask, nil)

	pl, lerr := lock_pwd(dir)
	if lerr != "" {
		return lerr
	}
	defer unlock_pwd(&pl)

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	cnew := fmt.ctprintf("%s+", path)
	cold := fmt.ctprintf("%s-", path)

	// Take /etc/shadow+ (busybox's lock), clearing a leftover.
	newfd := linux.Fd(-1)
	cleared := false
	for tries := 0; ; tries += 1 {
		fd, e := linux.open(cnew, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
		if e == .NONE {
			newfd = fd
			break
		}
		if e != .EEXIST {
			return fmt.tprintf("%s+: %v", path, e)
		}
		if tries >= 50 {
			st: linux.Stat
			if !cleared && linux.lstat(cnew, &st) == .NONE {
				now := time.time_to_unix(time.now())
				if now - i64(st.mtime.time_sec) > 60 {
					linux.unlink(cnew)
					cleared = true
					continue
				}
			}
			return fmt.tprintf("%s+ exists: another program is changing it", path)
		}
		time.sleep(100 * time.Millisecond)
	}
	ok := false
	defer if !ok {
		linux.unlink(cnew)
	}
	defer linux.close(newfd)

	oldfd, oe := linux.open(cpath, {.RDWR, .NOFOLLOW, .CLOEXEC})
	if oe != .NONE {
		return fmt.tprintf("%s: %v", path, oe)
	}
	defer linux.close(oldfd)
	st: linux.Stat
	if linux.fstat(oldfd, &st) != .NONE || !linux.S_ISREG(st.mode) {
		return fmt.tprintf("%s is not a regular file", path)
	}
	// busybox locks the old file itself too; take it, best effort.
	fl := linux.FLock{type = .WRLCK, whence = .SET}
	linux.fcntl(oldfd, linux.F_SETLK, &fl)

	text, rerr := read_fd(oldfd, int(st.size))
	if rerr != "" {
		return fmt.tprintf("%s: %s", path, rerr)
	}

	out := strings.builder_make(context.temp_allocator)
	found := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, ":", context.temp_allocator)
		if found || len(f) < 2 || f[0] != user {
			strings.write_string(&out, line)
			strings.write_byte(&out, '\n')
			continue
		}
		found = true
		s, _, valid := parse_shadow_entry(line, user)
		if !valid {
			return fmt.tprintf("%s: the line for %s is damaged; fix it by hand", path, user)
		}
		if why := edit(&s, true, data); why != "" {
			return why
		}
		if why := check_entry(s); why != "" {
			return why
		}
		strings.write_string(&out, format_shadow(s))
		strings.write_byte(&out, '\n')
	}
	if !found {
		s := Shadow{name = user, lastchg = NONE, min = NONE, max = NONE, warn = NONE, inactive = NONE, expire = NONE}
		if why := edit(&s, false, data); why != "" {
			return why
		}
		if why := check_entry(s); why != "" {
			return why
		}
		strings.write_string(&out, format_shadow(s))
		strings.write_byte(&out, '\n')
	}

	body := transmute([]u8)strings.to_string(out)
	linux.fchown(newfd, st.uid, st.gid)
	linux.fchmod(newfd, st.mode & {.IRUSR, .IWUSR, .IRGRP, .IWGRP, .IROTH, .IWOTH})
	if !write_full(newfd, body) {
		return fmt.tprintf("%s+: write failed", path)
	}
	if linux.fsync(newfd) != .NONE {
		return fmt.tprintf("%s+: fsync failed", path)
	}

	linux.unlink(cold)
	linux.link(cpath, cold)

	if e := linux.rename(cnew, cpath); e != .NONE {
		return fmt.tprintf("rename %s+: %v", path, e)
	}
	ok = true
	if dfd, de := linux.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY, .CLOEXEC}); de == .NONE {
		linux.fsync(dfd)
		linux.close(dfd)
	}
	return ""
}

// check_entry refuses a line that would corrupt the file.
@(private = "file")
check_entry :: proc(s: Shadow) -> string {
	for f in ([]string{s.name, s.hash, s.flag}) {
		if strings.index_any(f, ":\n\r") >= 0 {
			return "refusing to write a field with ':' or a newline in it"
		}
	}
	return ""
}

read_fd :: proc(fd: linux.Fd, hint: int) -> (string, string) {
	buf := make([dynamic]u8, 0, max(hint, 4096), context.temp_allocator)
	chunk: [4096]u8
	off: i64 = 0
	for {
		n, e := linux.pread(fd, chunk[:], off)
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return "", fmt.tprintf("%v", e)
		}
		if n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
		off += i64(n)
		if len(buf) > 16 << 20 {
			return "", "too large"
		}
	}
	return string(buf[:]), ""
}

write_full :: proc(fd: linux.Fd, b: []u8) -> bool {
	off := 0
	for off < len(b) {
		n, e := linux.write(fd, b[off:])
		if e == .EINTR {
			continue
		}
		if e != .NONE || n <= 0 {
			return false
		}
		off += n
	}
	return true
}
