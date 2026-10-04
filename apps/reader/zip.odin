// A ZIP reader, which is the whole of what an EPUB container is.
//
// Only what a book needs: the central directory, stored (method 0) and
// deflated (method 8) entries. Odin's `core:compress/zlib` has a raw inflate,
// which is exactly the bitstream a ZIP member holds, so there is nothing to
// hand-roll below this file.
//
// Hostile input is the normal case here. Books in the wild carry mixed
// methods in one archive, local headers whose sizes are zero because a
// streaming writer deferred them to a data descriptor, ZIP64 extra fields on
// small files, and comments that make the end-of-central-directory record a
// search rather than a lookup. Every one of those is handled or reported; none
// of them aborts.
package main

import "core:bytes"
import "core:compress/zlib"
import "core:os"
import "core:strings"

ZIP_EOCD :: u32(0x06054b50)
ZIP_EOCD64 :: u32(0x06064b50)
ZIP_EOCD64_LOC :: u32(0x07064b50)
ZIP_CEN :: u32(0x02014b50)
ZIP_LOC :: u32(0x04034b50)

// A single archive member. `name` and the archive bytes are borrowed from the
// Zip, so the Zip must outlive any entry read out of it.
Zip_Entry :: struct {
	name:      string,
	method:    u16,
	crc:       u32,
	csize:     i64,
	usize:     i64,
	hdr_off:   i64,
	is_dir:    bool,
}

Zip :: struct {
	data:    []u8,
	owned:   bool,
	entries: [dynamic]Zip_Entry,
	index:   map[string]int, // exact name -> entry; built once
	err:     string,
}

zip_destroy :: proc(z: ^Zip) {
	if z.owned {
		delete(z.data)
	}
	for e in z.entries {
		delete(e.name)
	}
	delete(z.entries)
	delete(z.index)
	z^ = {}
}

zip_open :: proc(path: string) -> (z: Zip, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		z.err = "cannot read file"
		return z, false
	}
	z.owned = true
	return zip_from_bytes_owned(data)
}

// zip_from_bytes reads an archive already in memory. The bytes are borrowed.
zip_from_bytes :: proc(data: []u8) -> (z: Zip, ok: bool) {
	z.data = data
	z.owned = false
	return zip_parse(&z), zip_parse_ok(&z)
}

zip_from_bytes_owned :: proc(data: []u8) -> (z: Zip, ok: bool) {
	z.data = data
	z.owned = true
	return zip_parse(&z), zip_parse_ok(&z)
}

@(private = "file")
zip_parse_ok :: proc(z: ^Zip) -> bool {
	return z.err == ""
}

@(private = "file")
rd_u16 :: proc(b: []u8, at: i64) -> u16 {
	if at < 0 || at + 2 > i64(len(b)) {
		return 0
	}
	return u16(b[at]) | u16(b[at + 1]) << 8
}

@(private = "file")
rd_u32 :: proc(b: []u8, at: i64) -> u32 {
	if at < 0 || at + 4 > i64(len(b)) {
		return 0
	}
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

@(private = "file")
rd_u64 :: proc(b: []u8, at: i64) -> u64 {
	if at < 0 || at + 8 > i64(len(b)) {
		return 0
	}
	return u64(rd_u32(b, at)) | u64(rd_u32(b, at + 4)) << 32
}

@(private = "file")
zip_parse :: proc(z: ^Zip) -> Zip {
	n := i64(len(z.data))
	if n < 22 {
		z.err = "not a zip: too short"
		return z^
	}

	// The EOCD sits at the end, but a trailing comment of up to 65535 bytes
	// can push it back, so it is searched for rather than read at a fixed
	// offset. Scanning backwards finds the *last* candidate, which is the
	// right one when the comment itself happens to contain the signature.
	eocd := i64(-1)
	lo := max(i64(0), n - 22 - 65535)
	for at := n - 22; at >= lo; at -= 1 {
		if rd_u32(z.data, at) == ZIP_EOCD {
			eocd = at
			break
		}
	}
	if eocd < 0 {
		z.err = "not a zip: no end-of-central-directory record"
		return z^
	}

	count := i64(rd_u16(z.data, eocd + 10))
	cd_size := i64(rd_u32(z.data, eocd + 12))
	cd_off := i64(rd_u32(z.data, eocd + 16))

	// ZIP64: the 32-bit fields are saturated and the real ones live in a
	// separate record found through a locator just before the EOCD.
	if count == 0xffff || cd_off == 0xffffffff || cd_size == 0xffffffff {
		loc := eocd - 20
		if loc >= 0 && rd_u32(z.data, loc) == ZIP_EOCD64_LOC {
			rec := i64(rd_u64(z.data, loc + 8))
			if rec >= 0 && rec + 56 <= n && rd_u32(z.data, rec) == ZIP_EOCD64 {
				count = i64(rd_u64(z.data, rec + 32))
				cd_size = i64(rd_u64(z.data, rec + 40))
				cd_off = i64(rd_u64(z.data, rec + 48))
			}
		}
	}

	if cd_off < 0 || cd_off >= n {
		z.err = "zip central directory is outside the file"
		return z^
	}
	_ = cd_size

	z.entries = make([dynamic]Zip_Entry, 0, max(count, 8))
	at := cd_off
	read := i64(0)
	for read < count || count == 0 {
		if at + 46 > n || rd_u32(z.data, at) != ZIP_CEN {
			break
		}
		e := Zip_Entry {
			method  = rd_u16(z.data, at + 10),
			crc     = rd_u32(z.data, at + 16),
			csize   = i64(rd_u32(z.data, at + 20)),
			usize   = i64(rd_u32(z.data, at + 24)),
			hdr_off = i64(rd_u32(z.data, at + 42)),
		}
		nlen := i64(rd_u16(z.data, at + 28))
		elen := i64(rd_u16(z.data, at + 30))
		clen := i64(rd_u16(z.data, at + 32))
		if at + 46 + nlen > n {
			break
		}
		raw_name := string(z.data[at + 46:at + 46 + nlen])

		// ZIP64 extended information, extra-field id 0x0001. The fields are
		// present only for the ones that were saturated, in a fixed order.
		if e.usize == 0xffffffff || e.csize == 0xffffffff || e.hdr_off == 0xffffffff {
			ex := at + 46 + nlen
			ex_end := min(n, ex + elen)
			for ex + 4 <= ex_end {
				id := rd_u16(z.data, ex)
				sz := i64(rd_u16(z.data, ex + 2))
				if id == 0x0001 {
					q := ex + 4
					if e.usize == 0xffffffff {
						e.usize = i64(rd_u64(z.data, q));q += 8
					}
					if e.csize == 0xffffffff {
						e.csize = i64(rd_u64(z.data, q));q += 8
					}
					if e.hdr_off == 0xffffffff {
						e.hdr_off = i64(rd_u64(z.data, q));q += 8
					}
					break
				}
				ex += 4 + sz
			}
		}

		e.name = zip_clean_name(raw_name)
		e.is_dir = strings.has_suffix(e.name, "/") || (e.usize == 0 && e.csize == 0 && strings.has_suffix(raw_name, "/"))
		if !e.is_dir {
			append(&z.entries, e)
		} else {
			delete(e.name)
		}

		at += 46 + nlen + elen + clen
		read += 1
		if count == 0 && read > 1 << 20 {
			break
		}
	}

	if len(z.entries) == 0 {
		z.err = "zip holds no readable entries"
		return z^
	}

	z.index = make(map[string]int, len(z.entries))
	for e, i in z.entries {
		if _, dup := z.index[e.name]; !dup {
			z.index[e.name] = i
		}
	}
	return z^
}

// zip_clean_name normalises a member name: backslashes to slashes, a leading
// "./" or "/" removed, and ".."/"." segments resolved so a crafted archive
// cannot name a path above the root. The result is freshly allocated.
zip_clean_name :: proc(raw: string, allocator := context.allocator) -> string {
	s, _ := strings.replace_all(raw, "\\", "/", context.temp_allocator)
	for strings.has_prefix(s, "/") {
		s = s[1:]
	}
	segs := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in strings.split(s, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(segs) > 0 {
				pop(&segs)
			}
		case:
			append(&segs, part)
		}
	}
	trailing := strings.has_suffix(s, "/") && len(segs) > 0
	joined := strings.join(segs[:], "/", context.temp_allocator)
	if trailing {
		return strings.concatenate({joined, "/"}, allocator)
	}
	return strings.clone(joined, allocator)
}

zip_find :: proc(z: ^Zip, name: string) -> int {
	if i, ok := z.index[name]; ok {
		return i
	}
	// Fall back to a case-insensitive match. Some writers upper-case
	// META-INF, some do not, and a book should open either way.
	lower := strings.to_lower(name, context.temp_allocator)
	for e, i in z.entries {
		if strings.equal_fold(e.name, lower) || strings.equal_fold(e.name, name) {
			return i
		}
	}
	return -1
}

zip_has :: proc(z: ^Zip, name: string) -> bool {
	return zip_find(z, name) >= 0
}

// zip_read inflates one member. The returned bytes belong to the caller.
zip_read :: proc(z: ^Zip, name: string, allocator := context.allocator) -> (out: []u8, ok: bool) {
	i := zip_find(z, name)
	if i < 0 {
		return nil, false
	}
	return zip_read_at(z, i, allocator)
}

zip_read_at :: proc(z: ^Zip, i: int, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if i < 0 || i >= len(z.entries) {
		return nil, false
	}
	e := z.entries[i]
	n := i64(len(z.data))

	// The local header repeats the name and extra field, and its lengths are
	// the ones that say where the data starts. Its *sizes* are not trusted:
	// a streaming writer leaves them zero and puts them in a trailing data
	// descriptor, so the central directory's sizes win.
	h := e.hdr_off
	if h < 0 || h + 30 > n || rd_u32(z.data, h) != ZIP_LOC {
		return nil, false
	}
	nlen := i64(rd_u16(z.data, h + 26))
	elen := i64(rd_u16(z.data, h + 28))
	start := h + 30 + nlen + elen
	if start > n {
		return nil, false
	}

	csize := e.csize
	if csize <= 0 || start + csize > n {
		// No usable compressed size: give inflate the rest of the file and
		// let the deflate stream's own end-of-block stop it.
		csize = n - start
	}
	raw := z.data[start:start + csize]

	switch e.method {
	case 0:
		want := e.usize > 0 ? min(e.usize, csize) : csize
		buf := make([]u8, want, allocator)
		copy(buf, raw[:want])
		return buf, true
	case 8:
		hint := e.usize > 0 ? int(e.usize) : -1
		b: bytes.Buffer
		ierr := zlib.inflate_from_byte_array(raw, &b, true, hint)
		got := bytes.buffer_to_bytes(&b)
		if ierr != nil && len(got) == 0 {
			bytes.buffer_destroy(&b)
			return nil, false
		}
		// A truncated member still yields whatever inflated before the
		// stream broke, which is the difference between a chapter that
		// stops early and a book that will not open.
		buf := make([]u8, len(got), allocator)
		copy(buf, got)
		bytes.buffer_destroy(&b)
		return buf, true
	}
	return nil, false
}

// zip_read_string is zip_read for text, which is almost every member of an
// EPUB.
zip_read_string :: proc(z: ^Zip, name: string, allocator := context.allocator) -> (s: string, ok: bool) {
	b, good := zip_read(z, name, allocator)
	if !good {
		return "", false
	}
	return string(b), true
}
