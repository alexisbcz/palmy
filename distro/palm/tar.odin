package palm

// ustar archives: the inside of every .palm.
//
// The writer emits POSIX ustar, using the 155-byte prefix field for long
// paths and a pax extended header ('x') only when a path or link target will
// not fit even so -- which keeps nearly every archive readable by the oldest
// tar there is. Owners are written both ways, numeric and by name, and come
// from the recipe, not the build machine: a package built by uid 1000 still
// says root:root unless its PALMBUILD says otherwise. Timestamps are
// SOURCE_DATE_EPOCH or zero, so two builds of the same recipe are the same
// bytes.
//
// The reader accepts ustar, pax per-file records and GNU long names (what
// `tar` on the host writes), validates every header checksum, and refuses any
// member whose path would leave the root once cleaned -- the reader is the
// fence, so nothing after it has to wonder about "../".

import "core:fmt"
import "core:strconv"
import "core:strings"

Entry_Type :: enum u8 {
	File,
	Dir,
	Symlink,
	Hardlink,
}

Tar_Entry :: struct {
	path:  string, // canonical, "/usr/bin/foo"; ".PKGINFO" stays bare
	type:  Entry_Type,
	mode:  u32, // permission bits including setuid/setgid/sticky
	uid:   int,
	gid:   int,
	uname: string,
	gname: string,
	mtime: i64,
	link:  string, // symlink target, or hardlink source path
	data:  []byte, // a view into the archive for files
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

@(private = "file")
put_octal :: proc(field: []byte, v: i64) {
	// width-1 digits, then NUL, as GNU and BSD tar both write.
	s := fmt.tprintf("%0*o", len(field) - 1, v)
	copy(field, s)
	field[len(field) - 1] = 0
}

@(private = "file")
put_str :: proc(field: []byte, s: string) {
	copy(field, s)
}

@(private = "file")
header_checksum :: proc(h: []byte) -> i64 {
	sum: i64 = 0
	for b, i in h {
		sum += (i >= 148 && i < 156) ? 32 : i64(b)
	}
	return sum
}

@(private = "file")
raw_header :: proc(out: ^[dynamic]byte, name, prefix: string, typeflag: byte, mode: u32, uid, gid: int, uname, gname: string, size, mtime: i64, link: string) {
	h: [512]byte
	put_str(h[0:100], name)
	put_octal(h[100:108], i64(mode & 0o7777))
	put_octal(h[108:116], i64(uid))
	put_octal(h[116:124], i64(gid))
	put_octal(h[124:136], size)
	put_octal(h[136:148], mtime)
	h[156] = typeflag
	put_str(h[157:257], link)
	put_str(h[257:263], "ustar\x00")
	put_str(h[263:265], "00")
	put_str(h[265:297], uname)
	put_str(h[297:329], gname)
	put_str(h[345:500], prefix)
	sum := header_checksum(h[:])
	s := fmt.tprintf("%06o", sum)
	copy(h[148:154], s)
	h[154] = 0
	h[155] = ' '
	append(out, ..h[:])
}

@(private = "file")
pad_block :: proc(out: ^[dynamic]byte) {
	for len(out) % 512 != 0 {
		append(out, 0)
	}
}

// split_ustar tries to fit a path into ustar's name/prefix pair.
@(private = "file")
split_ustar :: proc(p: string) -> (name, prefix: string, ok: bool) {
	if len(p) <= 100 {
		return p, "", true
	}
	for i := len(p) - 1; i > 0; i -= 1 {
		if p[i] == '/' && i <= 155 && len(p) - i - 1 <= 100 && len(p) - i - 1 > 0 {
			return p[i + 1:], p[:i], true
		}
	}
	return "", "", false
}

@(private = "file")
pax_record :: proc(b: ^strings.Builder, key, value: string) {
	// "%d %s=%s\n" where the length counts itself.
	body := len(key) + len(value) + 3
	n := body + 1
	for len(fmt.tprintf("%d", n)) + body != n {
		n += 1
	}
	fmt.sbprintf(b, "%d %s=%s\n", n, key, value)
}

// tar_write appends one entry. Paths are given canonical ("/usr/bin/x") and
// written relative ("usr/bin/x"); directories gain a trailing slash.
tar_write :: proc(out: ^[dynamic]byte, e: Tar_Entry) {
	name := strings.trim_left(e.path, "/")
	if e.type == .Dir && !strings.has_suffix(name, "/") {
		name = fmt.tprintf("%s/", name)
	}
	link := e.link
	if e.type == .Hardlink {
		link = strings.trim_left(link, "/")
	}
	typeflag: byte = '0'
	size: i64 = 0
	switch e.type {
	case .File:
		size = i64(len(e.data))
	case .Dir:
		typeflag = '5'
	case .Symlink:
		typeflag = '2'
	case .Hardlink:
		typeflag = '1'
	}
	uname := e.uname != "" ? e.uname : "root"
	gname := e.gname != "" ? e.gname : "root"

	short, prefix, fits := split_ustar(name)
	if !fits || len(link) > 100 {
		pb := strings.builder_make(context.temp_allocator)
		if !fits {
			pax_record(&pb, "path", name)
		}
		if len(link) > 100 {
			pax_record(&pb, "linkpath", link)
		}
		pax := strings.to_string(pb)
		raw_header(out, "././@PaxHeader", "", 'x', 0o644, 0, 0, "root", "root", i64(len(pax)), e.mtime, "")
		append(out, ..transmute([]byte)pax)
		pad_block(out)
		if !fits {
			short = name[max(0, len(name) - 100):]
			prefix = ""
		}
		if len(link) > 100 {
			link = link[:100]
		}
	}
	raw_header(out, short, prefix, typeflag, e.mode, e.uid, e.gid, uname, gname, size, e.mtime, link)
	if e.type == .File {
		append(out, ..e.data)
		pad_block(out)
	}
}

tar_finish :: proc(out: ^[dynamic]byte) {
	for _ in 0 ..< 1024 {
		append(out, 0)
	}
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
get_str :: proc(field: []byte) -> string {
	n := 0
	for n < len(field) && field[n] != 0 {
		n += 1
	}
	return string(field[:n])
}

@(private = "file")
get_octal :: proc(field: []byte) -> (i64, bool) {
	// GNU base-256 for large values: high bit of the first byte set.
	if len(field) > 0 && field[0] & 0x80 != 0 {
		v: i64 = i64(field[0] & 0x7f)
		for b in field[1:] {
			v = v << 8 | i64(b)
		}
		return v, true
	}
	s := strings.trim(get_str(field), " \x00")
	if s == "" {
		return 0, true
	}
	v, ok := strconv.parse_i64_of_base(s, 8)
	return v, ok
}

// tar_read parses a whole archive held in memory. The entries' data slices
// point into `archive`, which must outlive them.
tar_read :: proc(archive: []byte, allocator := context.allocator) -> ([]Tar_Entry, Err) {
	context.allocator = allocator
	entries := make([dynamic]Tar_Entry)
	pos := 0
	pax_path, pax_link := "", ""
	gnu_name, gnu_link := "", ""
	for {
		if pos + 512 > len(archive) {
			return nil, fail(EXIT_FAILED, "archive is truncated (no end marker)")
		}
		h := archive[pos:pos + 512]
		all_zero := true
		for b in h {
			if b != 0 {
				all_zero = false
				break
			}
		}
		if all_zero {
			break
		}
		want, ok1 := get_octal(h[148:156])
		if !ok1 || want != header_checksum(h) {
			return nil, fail(EXIT_FAILED, "archive header at offset %d has a bad checksum", pos)
		}
		size, ok2 := get_octal(h[124:136])
		if !ok2 || size < 0 || pos + 512 + int(size) > len(archive) {
			return nil, fail(EXIT_FAILED, "archive member at offset %d has a bad size", pos)
		}
		data := archive[pos + 512:pos + 512 + int(size)]
		pos += 512 + ((int(size) + 511) / 512) * 512
		typeflag := h[156]

		switch typeflag {
		case 'x':
			pax_path, pax_link = parse_pax(data)
			continue
		case 'g':
			continue
		case 'L':
			gnu_name = strings.clone(get_str(data))
			continue
		case 'K':
			gnu_link = strings.clone(get_str(data))
			continue
		}

		name := get_str(h[0:100])
		if string(h[257:262]) == "ustar" {
			if prefix := get_str(h[345:500]); prefix != "" {
				name = fmt.tprintf("%s/%s", prefix, name)
			}
		}
		link := get_str(h[157:257])
		if gnu_name != "" {name = gnu_name}
		if pax_path != "" {name = pax_path}
		if gnu_link != "" {link = gnu_link}
		if pax_link != "" {link = pax_link}
		pax_path, pax_link, gnu_name, gnu_link = "", "", "", ""

		e: Tar_Entry
		switch typeflag {
		case '0', 0, '7':
			e.type = .File
			e.data = data
		case '5':
			e.type = .Dir
		case '2':
			e.type = .Symlink
		case '1':
			e.type = .Hardlink
		case:
			return nil, fail(EXIT_FAILED, "archive member %q has an unsupported type %q", name, rune(typeflag))
		}
		mode, _ := get_octal(h[100:108])
		uid, _ := get_octal(h[108:116])
		gid, _ := get_octal(h[116:124])
		mtime, _ := get_octal(h[136:148])
		e.mode = u32(mode) & 0o7777
		e.uid = int(uid)
		e.gid = int(gid)
		e.mtime = mtime
		e.uname = strings.clone(get_str(h[265:297]))
		e.gname = strings.clone(get_str(h[297:329]))

		bare := strings.trim_right(name, "/")
		if bare == ".PKGINFO" || bare == "./.PKGINFO" {
			e.path = ".PKGINFO"
		} else {
			clean, ok := clean_pkg_path(name)
			if !ok {
				return nil, fail(EXIT_REFUSED, "archive member %q is not a safe path", name)
			}
			if clean == "/" {
				continue // "./", which GNU tar writes for the top directory
			}
			e.path = clean
		}
		if e.type == .Hardlink {
			clean, ok := clean_pkg_path(link)
			if !ok {
				return nil, fail(EXIT_REFUSED, "hard link %q points outside the package", name)
			}
			e.link = clean
		} else {
			e.link = strings.clone(link)
		}
		append(&entries, e)
	}
	return entries[:], Err{}
}

@(private = "file")
parse_pax :: proc(data: []byte) -> (path, link: string) {
	rest := string(data)
	for len(rest) > 0 {
		sp := strings.index_byte(rest, ' ')
		if sp <= 0 {
			break
		}
		n, ok := strconv.parse_int(rest[:sp])
		if !ok || n <= sp || n > len(rest) {
			break
		}
		rec := rest[sp + 1:n]
		rest = rest[n:]
		rec = strings.trim_right(rec, "\n")
		eq := strings.index_byte(rec, '=')
		if eq < 0 {
			continue
		}
		switch rec[:eq] {
		case "path":
			path = strings.clone(rec[eq + 1:])
		case "linkpath":
			link = strings.clone(rec[eq + 1:])
		}
	}
	return
}
