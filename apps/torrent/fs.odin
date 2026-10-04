package main

// The disk layer: paths, directory walking, and reads and writes at an offset.
//
// Every write in this program goes through `file_write_at` on a handle opened
// by `storage.odin` under the download directory the user chose, or under the
// state directory `~/.local/share/palmy-torrent`. Nothing else is written.

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

runtime_allocator :: runtime.Allocator

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

path_base :: proc(path: string) -> string {
	p := strings.trim_right(path, "/")
	if p == "" {
		return "/"
	}
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[i + 1:]
	}
	return p
}

path_dir :: proc(path: string) -> string {
	p := strings.trim_right(path, "/")
	if i := strings.last_index_byte(p, '/'); i > 0 {
		return p[:i]
	} else if i == 0 {
		return "/"
	}
	return "."
}

path_join :: proc(parts: ..string, allocator := context.allocator) -> string {
	keep := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for p in parts {
		t := strings.trim_right(p, "/")
		if t == "" {
			continue
		}
		append(&keep, t)
	}
	if len(keep) == 0 {
		return strings.clone("", allocator)
	}
	return strings.join(keep[:], "/", allocator)
}

path_is_dir :: proc(path: string) -> bool {
	return os.is_dir(path)
}

path_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

path_size :: proc(path: string) -> (size: i64, ok: bool) {
	st, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0, false
	}
	return st.size, true
}

make_dirs :: proc(path: string) -> (err: string) {
	if path == "" || path == "." || path == "/" {
		return ""
	}
	if os.is_dir(path) {
		return ""
	}
	if e := os.make_directory_all(path); e != nil {
		if os.is_dir(path) {
			return ""
		}
		return tsprint("cannot create %s: %v", path, e)
	}
	return ""
}

expand_home :: proc(path: string, allocator := context.allocator) -> string {
	if !strings.has_prefix(path, "~") {
		return strings.clone(path, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return strings.clone(path, allocator)
	}
	if path == "~" {
		return strings.clone(home, allocator)
	}
	if strings.has_prefix(path, "~/") {
		return path_join(home, path[2:], allocator = allocator)
	}
	return strings.clone(path, allocator)
}

// state_dir is the only directory outside the download directory this program
// writes to.
state_dir :: proc(allocator := context.allocator) -> string {
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {
		base = path_join(os.get_env("HOME", context.temp_allocator), ".local/share", allocator = context.temp_allocator)
	}
	return path_join(base, "palmy-torrent", allocator = allocator)
}

// ---------------------------------------------------------------------------
// Whole-file helpers
// ---------------------------------------------------------------------------

read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		return nil, false
	}
	return d, true
}

write_file :: proc(path: string, data: []u8) -> (err: string) {
	if e := make_dirs(path_dir(path)); e != "" {
		return e
	}
	if e := os.write_entire_file(path, data); e != nil {
		return tsprint("cannot write %s: %v", path, e)
	}
	return ""
}

write_file_string :: proc(path: string, text: string) -> (err: string) {
	return write_file(path, transmute([]u8)text)
}

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

File :: ^os.File

file_open_read :: proc(path: string) -> (f: File, err: string) {
	h, e := os.open(path, {.Read})
	if e != nil {
		return nil, tsprint("cannot open %s for reading: %v", path, e)
	}
	return h, ""
}

// file_open_rw creates the file and its parent directories if they are not
// there. This is the only procedure in the program that creates a file inside
// the download directory.
file_open_rw :: proc(path: string) -> (f: File, err: string) {
	if e := make_dirs(path_dir(path)); e != "" {
		return nil, e
	}
	h, e := os.open(path, {.Read, .Write, .Create}, os.Permissions_Default_File)
	if e != nil {
		return nil, tsprint("cannot open %s for writing: %v", path, e)
	}
	return h, ""
}

file_close :: proc(f: File) {
	if f != nil {
		os.close(f)
	}
}

file_read_at :: proc(f: File, buf: []u8, offset: i64) -> (n: int, err: string) {
	got := 0
	for got < len(buf) {
		k, e := os.read_at(f, buf[got:], offset + i64(got))
		if e != nil {
			if got > 0 {
				return got, ""
			}
			return got, tsprint("%v", e)
		}
		if k == 0 {
			break // short file: the caller sees fewer bytes than it asked for
		}
		got += k
	}
	return got, ""
}

file_write_at :: proc(f: File, buf: []u8, offset: i64) -> (err: string) {
	put := 0
	for put < len(buf) {
		k, e := os.write_at(f, buf[put:], offset + i64(put))
		if e != nil {
			return tsprint("%v", e)
		}
		if k <= 0 {
			return "short write"
		}
		put += k
	}
	return ""
}

file_truncate :: proc(f: File, size: i64) {
	os.truncate(f, size)
}

// ---------------------------------------------------------------------------
// Walking a tree, for `metainfo_create` and for the end-to-end comparison
// ---------------------------------------------------------------------------

Walk_Entry :: struct {
	rel:  string, // relative to the root, '/'-joined
	abs:  string,
	size: i64,
}

// walk_tree lists every regular file under `root`, sorted by relative path.
// Symbolic links are not followed: a torrent made from a tree with a link out
// of it would otherwise publish whatever it points at.
walk_tree :: proc(root: string, allocator := context.allocator) -> []Walk_Entry {
	out := make([dynamic]Walk_Entry, 0, 16, allocator)
	walk_into(root, "", &out, allocator)
	slice.sort_by(out[:], proc(a, b: Walk_Entry) -> bool {
		return a.rel < b.rel
	})
	return out[:]
}

@(private = "file")
walk_into :: proc(dir, prefix: string, out: ^[dynamic]Walk_Entry, allocator: runtime_allocator) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		name := info.name
		if name == "." || name == ".." {
			continue
		}
		abs := path_join(dir, name, allocator = context.temp_allocator)
		rel := prefix == "" ? name : path_join(prefix, name, allocator = context.temp_allocator)
		switch info.type {
		case .Directory:
			walk_into(abs, rel, out, allocator)
		case .Regular:
			append(
				out,
				Walk_Entry {
					rel = strings.clone(rel, allocator),
					abs = strings.clone(abs, allocator),
					size = info.size,
				},
			)
		case .Undetermined, .Symlink, .Named_Pipe, .Socket, .Character_Device, .Block_Device:
			// skipped on purpose
		}
	}
}

// files_identical compares two files byte for byte. This is what the end-to-end
// test's verdict rests on, so it reads both rather than comparing sizes and
// hashes and hoping.
files_identical :: proc(a, b: string) -> (same: bool, detail: string) {
	sa, oka := path_size(a)
	sb, okb := path_size(b)
	if !oka {
		return false, tsprint("%s is missing", a)
	}
	if !okb {
		return false, tsprint("%s is missing", b)
	}
	if sa != sb {
		return false, tsprint("%s is %d bytes, %s is %d", a, sa, b, sb)
	}
	fa, ea := file_open_read(a)
	if ea != "" {
		return false, ea
	}
	defer file_close(fa)
	fb, eb := file_open_read(b)
	if eb != "" {
		return false, eb
	}
	defer file_close(fb)

	CH :: 256 * 1024
	ba := make([]u8, CH, context.temp_allocator)
	bb := make([]u8, CH, context.temp_allocator)
	off: i64 = 0
	for off < sa {
		want := int(min(i64(CH), sa - off))
		na, _ := file_read_at(fa, ba[:want], off)
		nb, _ := file_read_at(fb, bb[:want], off)
		if na != want || nb != want {
			return false, tsprint("short read at offset %d", off)
		}
		if !slice.equal(ba[:want], bb[:want]) {
			for i in 0 ..< want {
				if ba[i] != bb[i] {
					return false, tsprint(
						"first difference at byte %d: 0x%02x vs 0x%02x",
						off + i64(i),
						ba[i],
						bb[i],
					)
				}
			}
		}
		off += i64(want)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Deterministic synthetic data
//
// Every byte this program ever downloads in a test came out of here. Nothing is
// fetched from anywhere: the payload is generated, the .torrent is made from
// the generated payload, and the expected bytes are therefore known exactly.
// ---------------------------------------------------------------------------

Xorshift :: struct {
	s: u64,
}

xs_init :: proc(seed: u64) -> Xorshift {
	return Xorshift{s = seed == 0 ? 0x9e3779b97f4a7c15 : seed}
}

xs_next :: proc(x: ^Xorshift) -> u64 {
	v := x.s
	v ~= v << 13
	v ~= v >> 7
	v ~= v << 17
	x.s = v
	return v
}

xs_fill :: proc(x: ^Xorshift, buf: []u8) {
	i := 0
	for i < len(buf) {
		v := xs_next(x)
		n := min(8, len(buf) - i)
		for j in 0 ..< n {
			buf[i + j] = u8(v >> uint(8 * j))
		}
		i += n
	}
}

// write_synthetic_file writes `size` deterministic bytes derived from `seed`.
write_synthetic_file :: proc(path: string, size: i64, seed: u64) -> (err: string) {
	if e := make_dirs(path_dir(path)); e != "" {
		return e
	}
	f, oerr := file_open_rw(path)
	if oerr != "" {
		return oerr
	}
	defer file_close(f)
	file_truncate(f, 0)
	x := xs_init(seed)
	CH :: 64 * 1024
	buf := make([]u8, CH, context.temp_allocator)
	off: i64 = 0
	for off < size {
		n := int(min(i64(CH), size - off))
		xs_fill(&x, buf[:n])
		if werr := file_write_at(f, buf[:n], off); werr != "" {
			return werr
		}
		off += i64(n)
	}
	return ""
}

rm_rf :: proc(path: string) {
	if path == "" || path == "/" {
		return
	}
	if !os.is_dir(path) {
		os.remove(path)
		return
	}
	infos, err := os.read_directory_by_path(path, -1, context.temp_allocator)
	if err == nil {
		for info in infos {
			if info.name == "." || info.name == ".." {
				continue
			}
			rm_rf(path_join(path, info.name, allocator = context.temp_allocator))
		}
	}
	os.remove(path)
}
