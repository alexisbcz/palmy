package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// What a Kitty file transfer may read.
//
// The protocol lets a program name a file and have the terminal read it,
// which is how `kitten icat --transfer-mode=file` avoids pushing a large image
// through the pty. It is also a way for anything running in the terminal --
// including the far end of an ssh session -- to make it open a local path.
// The engine never touches the filesystem; this procedure is the whole policy,
// and it follows kitty's own:
//
//   - The file must be a regular file. A FIFO, a device or a directory is
//     refused before anything is read (it is opened non-blocking, so a FIFO
//     cannot hang the reader thread either).
//   - Its real path -- after every symlink -- must not be under /proc, /sys
//     or /dev. /proc/self/environ is a regular file and exactly the kind of
//     thing this is for.
//   - At most `limit` bytes are read (the image budget).
//   - A temporary file (t=t) is deleted after reading only if it lives in a
//     temporary directory and has `tty-graphics-protocol` in its name, as the
//     protocol requires; otherwise it is refused, so the terminal cannot be
//     made to delete anything else.
//   - Shared memory (t=s) is a POSIX shm name, read from /dev/shm and then
//     unlinked, which is what the protocol says the terminal must do.
//
// What leaks: whether a path exists and is a readable regular file, through
// the error reply. The contents never go back to the program -- they are
// decoded as an image or refused -- which is the same line kitty draws.
// ---------------------------------------------------------------------------

kitty_read_file :: proc(path_in: string, medium: u8, offset, size, limit: int) -> (data: []u8, err: string) {
	path := path_in
	if medium == 's' {
		name := strings.trim_left(path, "/")
		if name == "" || strings.contains_rune(name, '/') {
			return nil, "EINVAL:not a shared memory name"
		}
		path = fmt.tprintf("/dev/shm/%s", name)
	}
	if !strings.has_prefix(path, "/") {
		return nil, "EINVAL:the path is not absolute"
	}
	if medium == 't' && !is_temp_file(path) {
		return nil, "EPERM:a temporary file must be in a temporary directory and named tty-graphics-protocol"
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, oerr := linux.open(cpath, {.NOCTTY, .NONBLOCK, .CLOEXEC})
	if oerr != .NONE {
		return nil, "EBADF:the file cannot be opened"
	}
	defer linux.close(fd)

	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE {
		return nil, "EBADF:the file cannot be read"
	}
	if st.mode & linux.S_IFMT != linux.S_IFREG {
		return nil, "EBADF:not a regular file"
	}
	real := real_path(fd)
	if real == "" {
		return nil, "EBADF:the file cannot be read"
	}
	if medium != 's' {
		for bad in ([]string{"/proc", "/sys", "/dev"}) {
			if real == bad || strings.has_prefix(real, fmt.tprintf("%s/", bad)) {
				return nil, "EPERM:files under /proc, /sys and /dev are not read"
			}
		}
	} else if !strings.has_prefix(real, "/dev/shm/") {
		return nil, "EPERM:not in /dev/shm"
	}

	total := int(st.size)
	off := max(offset, 0)
	if off > total {
		return nil, "EINVAL:the offset is past the end of the file"
	}
	n := total - off
	if size > 0 {
		n = min(n, size)
	}
	if n > limit {
		return nil, "EFBIG:the file is larger than the image budget"
	}
	if off > 0 {
		if _, serr := linux.lseek(fd, i64(off), .SET); serr != .NONE {
			return nil, "EBADF:the file cannot be read"
		}
	}
	buf := make([]u8, n)
	got := 0
	for got < n {
		k, rerr := linux.read(fd, buf[got:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE || k <= 0 {
			break
		}
		got += k
	}
	if medium == 't' || medium == 's' {
		linux.unlink(cpath)
	}
	return buf[:got], ""
}

@(private = "file")
real_path :: proc(fd: linux.Fd) -> string {
	link := fmt.ctprintf("/proc/self/fd/%d", fd)
	buf := make([]u8, 4096, context.temp_allocator)
	n, err := linux.readlink(link, buf)
	if err != .NONE || n <= 0 {
		return ""
	}
	return string(buf[:n])
}

@(private = "file")
is_temp_file :: proc(path: string) -> bool {
	if !strings.contains(base_name(path), "tty-graphics-protocol") {
		return false
	}
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "/tmp/", "/dev/shm/", "/var/tmp/")
	if td := os.get_env("TMPDIR", context.temp_allocator); td != "" {
		append(&dirs, strings.has_suffix(td, "/") ? td : fmt.tprintf("%s/", td))
	}
	for d in dirs {
		if strings.has_prefix(path, d) && !strings.contains(path[len(d):], "/") && !strings.contains(path, "/../") {
			return true
		}
	}
	return false
}

// base64_encode is the other direction, for the screenshots and the self-test,
// which send Kitty transmissions of their own.
base64_encode :: proc(data: []u8, allocator := context.allocator) -> string {
	table := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	b := strings.builder_make(allocator)
	for i := 0; i < len(data); i += 3 {
		n := len(data) - i
		v := u32(data[i]) << 16
		if n > 1 {v |= u32(data[i + 1]) << 8}
		if n > 2 {v |= u32(data[i + 2])}
		strings.write_byte(&b, table[v >> 18 & 63])
		strings.write_byte(&b, table[v >> 12 & 63])
		strings.write_byte(&b, n > 1 ? table[v >> 6 & 63] : '=')
		strings.write_byte(&b, n > 2 ? table[v & 63] : '=')
	}
	return strings.to_string(b)
}
