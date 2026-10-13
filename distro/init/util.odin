package main

// Small things the rest of palm-init leans on: talking to the console, reading
// whole files, listing directories, and a monotonic clock.
//
// palm-init deliberately goes through core:sys/linux for all of this rather
// than core:os. It is PID 1: it runs before /proc exists, it must never
// allocate a file handle it cannot account for, and every failure has to turn
// into a console line rather than a panic. The raw syscalls make each of those
// failures visible as an Errno at the call site.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// say writes one "palm-init: ..." line to the console. Init's fds 1 and 2 are
// /dev/console (the kernel opens it for us, and boot reopens it once devtmpfs
// is mounted), so this is what appears on the serial line and on tty0.
say :: proc(format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	line := fmt.tprintf("palm-init: %s\n", msg)
	write_all(2, transmute([]u8)line)
}

write_all :: proc(fd: linux.Fd, data: []u8) {
	rest := data
	for len(rest) > 0 {
		n, err := linux.write(fd, rest)
		if err == .EINTR {continue}
		if err != .NONE || n <= 0 {return}
		rest = rest[n:]
	}
}

// read_file returns the whole file, read until EOF. /proc and /sys files report
// a size of zero, so the size is never trusted; we just read until read(2)
// says there is no more.
read_file :: proc(path: string, allocator := context.allocator) -> (text: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.CLOEXEC})
	if err != .NONE {return "", false}
	defer linux.close(fd)

	buf := make([dynamic]u8, 0, 4096, allocator)
	chunk: [4096]u8
	for {
		n, rerr := linux.read(fd, chunk[:])
		if rerr == .EINTR {continue}
		if rerr != .NONE {
			delete(buf)
			return "", false
		}
		if n == 0 {break}
		append(&buf, ..chunk[:n])
	}
	return string(buf[:]), true
}

// write_file replaces (or creates) a file. Used for the few /proc and /sys
// knobs init turns.
write_file :: proc(path: string, data: string, mode: u32 = 0o644) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, transmute(linux.Mode)mode)
	if err != .NONE {return false}
	defer linux.close(fd)
	write_all(fd, transmute([]u8)data)
	return true
}

// list_dir returns the names in a directory, without "." and "..". The names
// are allocated in the temp allocator: callers use them within one pass.
list_dir :: proc(path: string) -> (names: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.DIRECTORY, .CLOEXEC})
	if err != .NONE {return names, false}
	defer linux.close(fd)

	buf: [8192]u8
	for {
		n, derr := linux.getdents(fd, buf[:])
		if derr != .NONE || n <= 0 {break}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {continue}
			append(&names, strings.clone(name, context.temp_allocator))
		}
	}
	return names, true
}

exists :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return linux.access(cpath) == .NONE
}

is_executable :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: linux.Stat
	if linux.stat(cpath, &st) != .NONE {return false}
	if (u32(transmute(u32)st.mode) & 0o170000) != 0o100000 {return false}
	return linux.access(cpath, linux.X_OK) == .NONE
}

mkdir_p :: proc(path: string, mode: u32 = 0o755) {
	// Walk the path one component at a time; EEXIST is the common answer.
	for i := 1; i <= len(path); i += 1 {
		if i == len(path) || path[i] == '/' {
			part := strings.clone_to_cstring(path[:i], context.temp_allocator)
			linux.mkdir(part, transmute(linux.Mode)mode)
		}
	}
}

// now_ms is milliseconds on the monotonic clock: restart backoff and the
// shutdown grace period must not jump when the wall clock is set.
now_ms :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

sleep_ms :: proc(ms: i64) {
	ts := linux.Time_Spec{time_sec = uint(ms / 1000), time_nsec = uint((ms % 1000) * 1_000_000)}
	linux.nanosleep(&ts, nil)
}

// trim_comment drops a `#` comment: at the start of a line, or after
// whitespace, so `env = COLOR=#fff` keeps its value but
// `cmd = /usr/bin/x   # why` loses the note.
trim_comment :: proc(line: string) -> string {
	for i in 0 ..< len(line) {
		if line[i] == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t') {
			return line[:i]
		}
	}
	return line
}

// split_fields splits on runs of spaces and tabs, the way the service file's
// `cmd` and the kernel command line are split.
split_fields :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {i += 1}
		start := i
		for i < len(s) && !(s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {i += 1}
		if i > start {append(&out, s[start:i])}
	}
	return out[:]
}
