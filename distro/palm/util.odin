package palm

// The small things every other file leans on: exit codes, messages, hex and
// sha256, the `key = value` line format that every palm file shares, and the
// handful of libc calls that have to go through libc.
//
// WHY SOME CALLS GO THROUGH LIBC. Odin's core:os talks to the kernel with raw
// syscalls, which is usually what you want. It is not what you want for
// chown, chmod and geteuid, because the image builder runs palm under
// `fakeroot`, and fakeroot works by intercepting exactly those libc symbols
// with LD_PRELOAD. A raw syscall goes straight past it: the chown fails with
// EPERM, the ownership is never recorded, and the root filesystem ends up
// owned by whoever built it. So the calls that carry ownership and mode are
// declared here against libc by hand -- and so are unlink, rmdir and rename
// on installed files, because fakeroot keys what it remembers by inode and
// must hear when one is freed, or a later file reusing the inode inherits a
// stale owner. Everything else stays on core:os.

import "base:runtime"
import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "chmod")
	c_chmod :: proc(path: cstring, mode: u32) -> i32 ---
	@(link_name = "lchown")
	c_lchown :: proc(path: cstring, uid: u32, gid: u32) -> i32 ---
	@(link_name = "geteuid")
	c_geteuid :: proc() -> u32 ---
	@(link_name = "execv")
	c_execv :: proc(path: cstring, argv: [^]cstring) -> i32 ---
	@(link_name = "isatty")
	c_isatty :: proc(fd: i32) -> i32 ---
	@(link_name = "unlink")
	c_unlink :: proc(path: cstring) -> i32 ---
	@(link_name = "rmdir")
	c_rmdir :: proc(path: cstring) -> i32 ---
	@(link_name = "rename")
	c_rename :: proc(old, new: cstring) -> i32 ---
}

// Exit codes. The same table as the rest of the palm surface (docs/PALM-CLI.md)
// so an agent reads one set of numbers everywhere.
EXIT_OK :: 0
EXIT_FAILED_GENERIC :: 1 // verify found problems; nothing went wrong running
EXIT_USAGE :: 2
EXIT_NOT_FOUND :: 3
EXIT_REFUSED :: 4 // needs --yes, or a check refused the operation
EXIT_UNAVAILABLE :: 6 // a repository could not be reached
EXIT_FAILED :: 7

// Errors carry a code and a sentence. Every procedure that can fail returns
// one of these rather than printing, so the selftest can assert on the refusal
// itself instead of scraping stderr.
Err :: struct {
	code: int,
	msg:  string,
}

fail :: proc(code: int, format: string, args: ..any) -> Err {
	return Err{code, fmt.aprintf(format, ..args)}
}

ok :: proc(e: Err) -> bool {
	return e.code == 0
}

// g_quiet silences progress lines. --json sets it so stdout stays one
// document; the selftest sets it so its own output stays readable.
g_quiet := false

say :: proc(format: string, args: ..any) {
	if g_quiet {
		return
	}
	fmt.printf(format, ..args)
	fmt.print("\n")
}

warn :: proc(format: string, args: ..any) {
	if g_quiet {
		return
	}
	fmt.eprint("palm: warning: ")
	fmt.eprintf(format, ..args)
	fmt.eprint("\n")
}

// ---------------------------------------------------------------------------
// Hashing and hex
// ---------------------------------------------------------------------------

hex_encode :: proc(b: []byte, allocator := context.allocator) -> string {
	DIGITS := "0123456789abcdef"
	out := make([]byte, len(b) * 2, allocator)
	for x, i in b {
		out[i * 2] = DIGITS[x >> 4]
		out[i * 2 + 1] = DIGITS[x & 15]
	}
	return string(out)
}

hex_decode :: proc(text: string, allocator := context.allocator) -> ([]byte, bool) {
	s := strings.trim_space(text)
	if len(s) % 2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s) / 2, allocator)
	for i := 0; i < len(s); i += 2 {
		hi, ok1 := hex_nibble(s[i])
		lo, ok2 := hex_nibble(s[i + 1])
		if !ok1 || !ok2 {
			delete(out, allocator)
			return nil, false
		}
		out[i / 2] = hi << 4 | lo
	}
	return out, true
}

@(private = "file")
hex_nibble :: proc(c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	return hex_encode(digest[:], allocator)
}

sha256_file_hex :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return sha256_hex(data, allocator), true
}

// ---------------------------------------------------------------------------
// The `key = value` format
//
// .PKGINFO, PALMBUILD, PALMINDEX, the installed database and the service
// files palm-init reads all share it: one pair per line, `#` starts a comment
// only at the beginning of a line (a description may contain one), blank
// lines separate records where a file holds more than one.
// ---------------------------------------------------------------------------

KV :: struct {
	key:   string,
	value: string,
	line:  int,
}

// parse_records splits text into records at blank lines. A file with a single
// record (PALMBUILD, .PKGINFO) is simply one record.
parse_records :: proc(text: string, allocator := context.allocator) -> [][]KV {
	context.allocator = allocator
	records := make([dynamic][]KV)
	cur := make([dynamic]KV)
	lineno := 0
	rest := text
	for line_raw in strings.split_lines_iterator(&rest) {
		lineno += 1
		line := strings.trim_space(line_raw)
		if line == "" {
			if len(cur) > 0 {
				append(&records, cur[:])
				cur = make([dynamic]KV)
			}
			continue
		}
		if line[0] == '#' {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			append(&cur, KV{line, "", lineno})
			continue
		}
		append(&cur, KV{strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:]), lineno})
	}
	if len(cur) > 0 {
		append(&records, cur[:])
	}
	return records[:]
}

kv_get :: proc(rec: []KV, key: string) -> string {
	for kv in rec {
		if kv.key == key {
			return kv.value
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Paths under --root
// ---------------------------------------------------------------------------

// rooted joins the target root and an absolute in-package path. Package paths
// are validated when an archive is read (see tar.odin: no "..", no empty
// components), so this is only string work.
rooted :: proc(root, path: string, allocator := context.allocator) -> string {
	r := strings.trim_right(root, "/")
	p := strings.trim_left(path, "/")
	if p == "" {
		return strings.clone(r == "" ? "/" : r, allocator)
	}
	return strings.concatenate({r, "/", p}, allocator)
}

parent_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	if i <= 0 {
		return "/"
	}
	return path[:i]
}

base_name :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:]
}

// clean_pkg_path normalises a path from an archive or a recipe to the
// canonical "/a/b/c" form, and refuses anything that could land outside the
// root: "..", or characters the database's line format cannot carry.
clean_pkg_path :: proc(p: string, allocator := context.allocator) -> (string, bool) {
	if p == "" {
		return "", false
	}
	for c in transmute([]byte)p {
		if c == '\n' || c == '\t' || c == 0 || c == '\r' {
			return "", false
		}
	}
	parts := make([dynamic]string, context.temp_allocator)
	for comp in strings.split(p, "/", context.temp_allocator) {
		switch comp {
		case "", ".":
			continue
		case "..":
			return "", false
		}
		append(&parts, comp)
	}
	if len(parts) == 0 {
		return strings.clone("/", allocator), true
	}
	return strings.concatenate({"/", strings.join(parts[:], "/", context.temp_allocator)}, allocator), true
}

// is_root reports whether ownership can be applied. Through libc on purpose:
// under fakeroot this answers 0, and the chowns that follow are recorded.
is_root :: proc() -> bool {
	return c_geteuid() == 0
}

set_mode :: proc(path: string, mode: u32) -> bool {
	return c_chmod(strings.clone_to_cstring(path, context.temp_allocator), mode & 0o7777) == 0
}

set_owner :: proc(path: string, uid, gid: int) -> bool {
	return c_lchown(strings.clone_to_cstring(path, context.temp_allocator), u32(uid), u32(gid)) == 0
}

// remove_path unlinks a file or symlink, or removes an empty directory.
remove_path :: proc(path: string, dir: bool) -> bool {
	c := strings.clone_to_cstring(path, context.temp_allocator)
	return (dir ? c_rmdir(c) : c_unlink(c)) == 0
}

rename_path :: proc(old, new: string) -> bool {
	return c_rename(strings.clone_to_cstring(old, context.temp_allocator), strings.clone_to_cstring(new, context.temp_allocator)) == 0
}

stdin_is_tty :: proc() -> bool {
	return c_isatty(0) == 1
}

parse_octal :: proc(s: string) -> (u32, bool) {
	v, ok := strconv.parse_u64_of_base(s, 8)
	if !ok || v > 0o7777 {
		return 0, false
	}
	return u32(v), true
}

human_size :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30:
		return fmt.tprintf("%.1f GiB", f64(n) / f64(1 << 30))
	case n >= 1 << 20:
		return fmt.tprintf("%.1f MiB", f64(n) / f64(1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.1f KiB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

// write_file_atomic writes beside the destination and renames over it, so a
// reader -- or a crash -- sees the old file or the new one, never half.
write_file_atomic :: proc(path: string, data: []byte, mode: u32 = 0o644) -> bool {
	tmp := fmt.tprintf("%s.palm-tmp.%d", path, os.get_pid())
	if os.write_entire_file(tmp, data, os.perm_number(int(mode))) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

_ :: runtime

// mkdir_p is make_directory_all that counts an existing directory as success.
mkdir_p :: proc(path: string) -> bool {
	_ = os.make_directory_all(path)
	return os.is_directory(path)
}
