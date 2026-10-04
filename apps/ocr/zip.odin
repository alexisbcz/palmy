package main

// A ZIP writer, by hand, stored entries only.
//
// Odin's core has an inflate (`core:compress/zlib`) and no deflate, so there
// is no compressor to reach for. That turns out not to matter: **method 0,
// "stored", is a first-class ZIP entry** that every reader accepts, and an
// EPUB's XHTML is a few kilobytes a chapter. The file is bigger than it needs
// to be and correct, which is the right trade for a format whose first entry
// is *required* to be uncompressed anyway.
//
// EPUB 3 adds one rule on top of ZIP, from OCF 3.3 §3.4: the archive's first
// entry must be the file `mimetype`, holding exactly `application/epub+zip`,
// stored with no extra field. A reader is allowed to identify the format by
// reading bytes 30..60 of the file, so an EPUB whose first entry is deflated,
// or carries an extra field, or is not first, is not an EPUB. Writing nothing
// deflated makes the first half automatic; `zip_add_mimetype` does the rest by
// being the only way to add that entry and by refusing to be second.
//
// The two details that are fatal when wrong:
//
//   * every local header's CRC-32 and sizes must agree with the central
//     directory entry, because readers trust the directory and then verify
//     against the header;
//   * the central directory's offsets are from the start of the file, so
//     entries have to be appended in the order they were written.

import "core:strings"

@(private = "file")
crc_table: [256]u32
@(private = "file")
crc_ready: bool

crc32_bytes :: proc(data: []u8) -> u32 {
	if !crc_ready {
		for i in 0 ..< 256 {
			c := u32(i)
			for _ in 0 ..< 8 {
				c = (c >> 1) ~ (0xedb88320 if c & 1 != 0 else 0)
			}
			crc_table[i] = c
		}
		crc_ready = true
	}
	c := ~u32(0)
	for b in data {
		c = crc_table[(c ~ u32(b)) & 0xff] ~ (c >> 8)
	}
	return ~c
}

Zip_Entry :: struct {
	name:   string,
	crc:    u32,
	size:   u32,
	offset: u32,
}

Zip :: struct {
	buf:     [dynamic]u8,
	entries: [dynamic]Zip_Entry,
}

zip_init :: proc(z: ^Zip) {
	z.buf = make([dynamic]u8, 0, 16384)
	z.entries = make([dynamic]Zip_Entry, 0, 16)
}

zip_destroy :: proc(z: ^Zip) {
	delete(z.buf)
	for e in z.entries {
		delete(e.name)
	}
	delete(z.entries)
	z^ = {}
}

@(private = "file")
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

@(private = "file")
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

// A fixed 1980-01-01 timestamp, the earliest a DOS date field can hold, so two
// conversions of the same scan produce byte-identical EPUBs. Reproducibility
// is worth more here than a true mtime: it is how the self-test can assert
// that a second run changed nothing.
ZIP_TIME :: u16(0)
ZIP_DATE :: u16(0x0021)

zip_add :: proc(z: ^Zip, name: string, data: []u8) {
	e := Zip_Entry {
		name   = strings.clone(name),
		crc    = crc32_bytes(data),
		size   = u32(len(data)),
		offset = u32(len(z.buf)),
	}
	put_u32(&z.buf, 0x04034b50) // local file header
	put_u16(&z.buf, 20) // version needed: 2.0
	put_u16(&z.buf, 0) // flags: none, so the sizes in this header are real
	put_u16(&z.buf, 0) // method 0 — stored
	put_u16(&z.buf, ZIP_TIME)
	put_u16(&z.buf, ZIP_DATE)
	put_u32(&z.buf, e.crc)
	put_u32(&z.buf, e.size) // compressed == uncompressed
	put_u32(&z.buf, e.size)
	put_u16(&z.buf, u16(len(name)))
	put_u16(&z.buf, 0) // no extra field: `mimetype` must have none
	append(&z.buf, ..transmute([]u8)name)
	append(&z.buf, ..data)
	append(&z.entries, e)
}

zip_add_string :: proc(z: ^Zip, name: string, text: string) {
	zip_add(z, name, transmute([]u8)text)
}

// zip_add_mimetype writes the one entry EPUB constrains. It must be first, so
// it refuses when anything has been written already — a loud failure beats an
// archive that unzips cleanly and opens nowhere.
zip_add_mimetype :: proc(z: ^Zip) -> bool {
	if len(z.entries) != 0 {
		return false
	}
	zip_add_string(z, "mimetype", EPUB_MIMETYPE)
	return true
}

zip_finish :: proc(z: ^Zip) -> []u8 {
	cd := u32(len(z.buf))
	for e in z.entries {
		put_u32(&z.buf, 0x02014b50) // central directory file header
		put_u16(&z.buf, 20) // version made by
		put_u16(&z.buf, 20) // version needed
		put_u16(&z.buf, 0) // flags
		put_u16(&z.buf, 0) // stored
		put_u16(&z.buf, ZIP_TIME)
		put_u16(&z.buf, ZIP_DATE)
		put_u32(&z.buf, e.crc)
		put_u32(&z.buf, e.size)
		put_u32(&z.buf, e.size)
		put_u16(&z.buf, u16(len(e.name)))
		put_u16(&z.buf, 0) // extra
		put_u16(&z.buf, 0) // comment
		put_u16(&z.buf, 0) // disk number
		put_u16(&z.buf, 0) // internal attributes
		put_u32(&z.buf, 0) // external attributes
		put_u32(&z.buf, e.offset)
		append(&z.buf, ..transmute([]u8)e.name)
	}
	size := u32(len(z.buf)) - cd

	put_u32(&z.buf, 0x06054b50) // end of central directory
	put_u16(&z.buf, 0)
	put_u16(&z.buf, 0)
	put_u16(&z.buf, u16(len(z.entries)))
	put_u16(&z.buf, u16(len(z.entries)))
	put_u32(&z.buf, size)
	put_u32(&z.buf, cd)
	put_u16(&z.buf, 0) // no archive comment
	return z.buf[:]
}

// ---------------------------------------------------------------------------
// Reading, only as much as the self-test needs
// ---------------------------------------------------------------------------

@(private = "file")
rd_u16 :: proc(d: []u8, at: int) -> u16 {
	if at + 2 > len(d) {return 0}
	return u16(d[at]) | u16(d[at + 1]) << 8
}

@(private = "file")
rd_u32 :: proc(d: []u8, at: int) -> u32 {
	if at + 4 > len(d) {return 0}
	return u32(d[at]) | u32(d[at + 1]) << 8 | u32(d[at + 2]) << 16 | u32(d[at + 3]) << 24
}

Zip_Member :: struct {
	name:   string, // borrowed from the archive bytes
	method: u16,
	data:   []u8, // borrowed; valid only for method 0
}

// zip_list walks the central directory and returns every member in directory
// order, with a slice over the stored bytes. Nothing is copied and nothing is
// inflated: this reads archives this program wrote, which are all stored.
zip_list :: proc(archive: []u8, allocator := context.allocator) -> []Zip_Member {
	out := make([dynamic]Zip_Member, allocator)
	if len(archive) < 22 {
		return out[:]
	}
	eocd := -1
	lo := max(0, len(archive) - 22 - 65535)
	for i := len(archive) - 22; i >= lo; i -= 1 {
		if rd_u32(archive, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return out[:]
	}
	count := int(rd_u16(archive, eocd + 10))
	at := int(rd_u32(archive, eocd + 16))
	for _ in 0 ..< count {
		if at + 46 > len(archive) || rd_u32(archive, at) != 0x02014b50 {
			break
		}
		method := rd_u16(archive, at + 10)
		csize := int(rd_u32(archive, at + 20))
		nlen := int(rd_u16(archive, at + 28))
		elen := int(rd_u16(archive, at + 30))
		clen := int(rd_u16(archive, at + 32))
		off := int(rd_u32(archive, at + 42))
		name := at + 46 + nlen <= len(archive) ? string(archive[at + 46:at + 46 + nlen]) : ""
		m := Zip_Member {
			name   = name,
			method = method,
		}
		if off + 30 <= len(archive) && rd_u32(archive, off) == 0x04034b50 {
			dn := int(rd_u16(archive, off + 26))
			de := int(rd_u16(archive, off + 28))
			start := off + 30 + dn + de
			if method == 0 && start + csize <= len(archive) {
				m.data = archive[start:start + csize]
			}
		}
		append(&out, m)
		at += 46 + nlen + elen + clen
	}
	return out[:]
}

zip_member :: proc(members: []Zip_Member, name: string) -> (Zip_Member, bool) {
	for m in members {
		if m.name == name {
			return m, true
		}
	}
	return {}, false
}
