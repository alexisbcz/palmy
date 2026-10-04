// ZIP containers, written and read by hand.
//
// .docx and .odt are both ZIP archives of XML parts, so an exporter needs a
// ZIP writer. Odin's core has an inflate (`core:compress/zlib`) but no
// deflate, and taking a dependency on one is not worth it: **method 0,
// "stored", is a first-class ZIP entry** that every reader in existence
// accepts. The parts this app writes are a few kilobytes of XML, so the only
// thing compression would buy is a smaller file.
//
// Reading is the other half — a .docx import has to get `word/document.xml`
// back out of an archive that Word or LibreOffice wrote, and those are
// deflated, so the reader handles method 8 through `core:compress/zlib`.
//
// Two details that are easy to get wrong and fatal when you do:
//
//   * every local header's CRC-32 and sizes must agree with the central
//     directory entry, because readers trust the directory and then verify
//     against the header;
//   * `.odt` requires `mimetype` to be the *first* entry and stored, which is
//     automatic here since nothing is ever deflated on the way out.
package main

import "core:bytes"
import "core:compress/zlib"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// CRC-32 (IEEE 802.3, the polynomial ZIP uses)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

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
	z.buf = make([dynamic]u8, 0, 8192)
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

// A fixed timestamp — 1980-01-01 00:00, the earliest a DOS field can hold —
// so two exports of the same document are byte-identical. A reproducible
// artefact is worth more here than a true mtime.
ZIP_TIME :: u16(0)
ZIP_DATE :: u16(0x0021)

// zip_add appends one stored entry. `name` is the path inside the archive and
// must use forward slashes.
zip_add :: proc(z: ^Zip, name: string, data: []u8) {
	e := Zip_Entry {
		name   = strings.clone(name),
		crc    = crc32_bytes(data),
		size   = u32(len(data)),
		offset = u32(len(z.buf)),
	}
	put_u32(&z.buf, 0x04034b50) // local file header
	put_u16(&z.buf, 20) // version needed: 2.0
	put_u16(&z.buf, 0) // flags: none, so sizes are in this header
	put_u16(&z.buf, 0) // method 0 — stored
	put_u16(&z.buf, ZIP_TIME)
	put_u16(&z.buf, ZIP_DATE)
	put_u32(&z.buf, e.crc)
	put_u32(&z.buf, e.size) // compressed size == uncompressed size
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

// zip_finish writes the central directory and the end-of-central-directory
// record, and returns the whole archive. The slice stays owned by `z`.
zip_finish :: proc(z: ^Zip) -> []u8 {
	cd := u32(len(z.buf))
	for e in z.entries {
		put_u32(&z.buf, 0x02014b50) // central directory file header
		put_u16(&z.buf, 20) // version made by
		put_u16(&z.buf, 20) // version needed
		put_u16(&z.buf, 0)
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
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
rd_u16 :: proc(d: []u8, at: int) -> u16 {
	if at + 2 > len(d) {
		return 0
	}
	return u16(d[at]) | u16(d[at + 1]) << 8
}

@(private = "file")
rd_u32 :: proc(d: []u8, at: int) -> u32 {
	if at + 4 > len(d) {
		return 0
	}
	return u32(d[at]) | u32(d[at + 1]) << 8 | u32(d[at + 2]) << 16 | u32(d[at + 3]) << 24
}

// zip_read_entry pulls one named member out of an archive, inflating it if it
// was deflated. The returned bytes are allocated in `alloc`.
//
// The central directory is the authority on where members are, so this walks
// it from the end-of-central-directory record rather than scanning for local
// headers — which is what makes it work on archives with comments or on ones
// that were appended to.
zip_read_entry :: proc(
	archive: []u8,
	want: string,
	alloc := context.allocator,
) -> (
	out: []u8,
	ok: bool,
) {
	if len(archive) < 22 {
		return nil, false
	}
	// Find the EOCD: the signature within the last 64 KiB + 22 bytes.
	eocd := -1
	lo := max(0, len(archive) - 22 - 65535)
	for i := len(archive) - 22; i >= lo; i -= 1 {
		if rd_u32(archive, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return nil, false
	}
	count := int(rd_u16(archive, eocd + 10))
	at := int(rd_u32(archive, eocd + 16))

	for _ in 0 ..< count {
		if at + 46 > len(archive) || rd_u32(archive, at) != 0x02014b50 {
			return nil, false
		}
		method := rd_u16(archive, at + 10)
		csize := int(rd_u32(archive, at + 20))
		usize := int(rd_u32(archive, at + 24))
		nlen := int(rd_u16(archive, at + 28))
		elen := int(rd_u16(archive, at + 30))
		clen := int(rd_u16(archive, at + 32))
		off := int(rd_u32(archive, at + 42))
		name := at + 46 + nlen <= len(archive) ? string(archive[at + 46:at + 46 + nlen]) : ""

		if name == want {
			// The local header's own name and extra lengths give the data
			// offset; the directory's copy of them can differ.
			if off + 30 > len(archive) || rd_u32(archive, off) != 0x04034b50 {
				return nil, false
			}
			dn := int(rd_u16(archive, off + 26))
			de := int(rd_u16(archive, off + 28))
			start := off + 30 + dn + de
			if start + csize > len(archive) {
				return nil, false
			}
			raw := archive[start:start + csize]
			switch method {
			case 0:
				return slice.clone(raw, alloc), true
			case 8:
				buf: bytes.Buffer
				defer bytes.buffer_destroy(&buf)
				if zlib.inflate(raw, &buf, true, usize) != nil {
					return nil, false
				}
				return slice.clone(bytes.buffer_to_bytes(&buf), alloc), true
			case:
				return nil, false // a method nothing in the wild uses
			}
		}
		at += 46 + nlen + elen + clen
	}
	return nil, false
}

// zip_names lists the archive's members, for diagnostics and the self-test.
zip_names :: proc(archive: []u8, alloc := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, alloc)
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
		nlen := int(rd_u16(archive, at + 28))
		elen := int(rd_u16(archive, at + 30))
		clen := int(rd_u16(archive, at + 32))
		if at + 46 + nlen <= len(archive) {
			append(&out, strings.clone(string(archive[at + 46:at + 46 + nlen]), alloc))
		}
		at += 46 + nlen + elen + clen
	}
	return out[:]
}
