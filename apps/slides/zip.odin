// A ZIP container, written by hand.
//
// A .pptx is a ZIP of XML parts, and this is the ZIP half of it. Odin's core
// library has a deflate *decompressor* but no compressor, and taking a
// dependency on one in order to save a slide deck would be absurd, so every
// entry goes out with method 0 — "stored", uncompressed. That is not a
// shortcut around the format: method 0 is the first method ZIP ever had and
// every reader must support it. The headers, the central directory and the
// CRC-32 are the parts that have to be right, and they are written in full.
//
// Reading came later, with .pptx import: somebody else's package is deflated
// (method 8), which Odin's core inflater handles. The reader is the one
// apps/sheets uses for .xlsx, copied rather than shared because applications
// do not import each other.
package main

import "core:bytes"
import "core:compress/zlib"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// CRC-32, the IEEE 802.3 polynomial reflected — the one ZIP specifies.
// A wrong CRC is the single most common way a hand-written ZIP is rejected,
// so this is the first thing the test suite checks against a known vector.
// ---------------------------------------------------------------------------

@(private = "file")
crc_table: [256]u32
@(private = "file")
crc_ready: bool

crc32_of :: proc(data: []u8) -> u32 {
	if !crc_ready {
		for i in 0 ..< 256 {
			c := u32(i)
			for _ in 0 ..< 8 {
				c = (c & 1) != 0 ? 0xedb88320 ~ (c >> 1) : c >> 1
			}
			crc_table[i] = c
		}
		crc_ready = true
	}
	c := u32(0xffff_ffff)
	for b in data {
		c = crc_table[(c ~ u32(b)) & 0xff] ~ (c >> 8)
	}
	return c ~ 0xffff_ffff
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

Zip_Entry :: struct {
	name:   string,
	crc:    u32,
	size:   int,
	offset: int, // where this entry's local header starts
}

Zip :: struct {
	b:       strings.Builder,
	entries: [dynamic]Zip_Entry,
}

// A fixed timestamp, so the same document always produces the same bytes.
// 2026-01-01 00:00:00 in the MS-DOS packed form.
ZIP_DOS_DATE :: u16((2026 - 1980) << 9 | 1 << 5 | 1)
ZIP_DOS_TIME :: u16(0)

zip_make :: proc(allocator := context.allocator) -> Zip {
	return {b = strings.builder_make(allocator), entries = make([dynamic]Zip_Entry, allocator)}
}

zip_destroy :: proc(z: ^Zip) {
	strings.builder_destroy(&z.b)
	delete(z.entries)
}

@(private = "file")
put16 :: proc(b: ^strings.Builder, v: u16) {
	strings.write_byte(b, u8(v))
	strings.write_byte(b, u8(v >> 8))
}

@(private = "file")
put32 :: proc(b: ^strings.Builder, v: u32) {
	strings.write_byte(b, u8(v))
	strings.write_byte(b, u8(v >> 8))
	strings.write_byte(b, u8(v >> 16))
	strings.write_byte(b, u8(v >> 24))
}

// zip_add stores one entry. `name` is the path inside the archive and always
// uses forward slashes, which the format requires.
zip_add :: proc(z: ^Zip, name: string, data: []u8) {
	crc := crc32_of(data)
	off := strings.builder_len(z.b)
	b := &z.b
	put32(b, 0x0403_4b50) // local file header
	put16(b, 20) // version needed
	put16(b, 0) // flags: no encryption, sizes known up front
	put16(b, 0) // method 0: stored
	put16(b, ZIP_DOS_TIME)
	put16(b, ZIP_DOS_DATE)
	put32(b, crc)
	put32(b, u32(len(data))) // compressed size == uncompressed size
	put32(b, u32(len(data)))
	put16(b, u16(len(name)))
	put16(b, 0) // extra field length
	strings.write_string(b, name)
	strings.write_bytes(b, data)
	append(&z.entries, Zip_Entry{name = name, crc = crc, size = len(data), offset = off})
}

zip_add_string :: proc(z: ^Zip, name: string, text: string) {
	zip_add(z, name, transmute([]u8)text)
}

// zip_finish appends the central directory and the end-of-central-directory
// record, and returns the whole archive.
zip_finish :: proc(z: ^Zip) -> []u8 {
	b := &z.b
	cd_start := strings.builder_len(z.b)
	for e in z.entries {
		put32(b, 0x0201_4b50) // central directory header
		put16(b, 20) // version made by
		put16(b, 20) // version needed
		put16(b, 0)
		put16(b, 0) // stored
		put16(b, ZIP_DOS_TIME)
		put16(b, ZIP_DOS_DATE)
		put32(b, e.crc)
		put32(b, u32(e.size))
		put32(b, u32(e.size))
		put16(b, u16(len(e.name)))
		put16(b, 0) // extra
		put16(b, 0) // comment
		put16(b, 0) // disk number start
		put16(b, 0) // internal attributes
		put32(b, 0) // external attributes
		put32(b, u32(e.offset))
		strings.write_string(b, e.name)
	}
	cd_size := strings.builder_len(z.b) - cd_start
	put32(b, 0x0605_4b50) // end of central directory
	put16(b, 0) // this disk
	put16(b, 0) // disk with the central directory
	put16(b, u16(len(z.entries)))
	put16(b, u16(len(z.entries)))
	put32(b, u32(cd_size))
	put32(b, u32(cd_start))
	put16(b, 0) // archive comment length
	return transmute([]u8)strings.to_string(z.b)
}

zip_write_file :: proc(z: ^Zip, path: string) -> bool {
	return os.write_entire_file(path, zip_finish(z)) == nil
}

// ---------------------------------------------------------------------------
// Reading
//
// The central directory is the authority on what an archive contains, so it is
// what is walked — not the chain of local headers, which a writer is allowed
// to pad.
// ---------------------------------------------------------------------------

Zip_File :: struct {
	name: string,
	data: []u8, // decompressed; borrowed from the input when stored
}

@(private = "file")
get16 :: proc(d: []u8, at: int) -> int {
	if at + 1 >= len(d) {
		return 0
	}
	return int(d[at]) | int(d[at + 1]) << 8
}

@(private = "file")
get32 :: proc(d: []u8, at: int) -> int {
	if at + 3 >= len(d) {
		return 0
	}
	return int(d[at]) | int(d[at + 1]) << 8 | int(d[at + 2]) << 16 | int(d[at + 3]) << 24
}

zip_read :: proc(raw: []u8, allocator := context.allocator) -> (files: [dynamic]Zip_File, ok: bool) {
	files = make([dynamic]Zip_File, allocator)
	if len(raw) < 22 {
		return files, false
	}
	// Find the end-of-central-directory record by scanning back from the end;
	// it is the last thing in the file, bar an optional comment.
	eocd := -1
	lo := max(0, len(raw) - 65557)
	for i := len(raw) - 22; i >= lo; i -= 1 {
		if get32(raw, i) == 0x0605_4b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return files, false
	}
	n := get16(raw, eocd + 10)
	cd := get32(raw, eocd + 16)

	at := cd
	for _ in 0 ..< n {
		if at + 46 > len(raw) || get32(raw, at) != 0x0201_4b50 {
			return files, false
		}
		method := get16(raw, at + 10)
		csize := get32(raw, at + 20)
		usize := get32(raw, at + 24)
		nlen := get16(raw, at + 28)
		elen := get16(raw, at + 30)
		clen := get16(raw, at + 32)
		lho := get32(raw, at + 42)
		if at + 46 + nlen > len(raw) {
			return files, false
		}
		name := string(raw[at + 46:at + 46 + nlen])
		at += 46 + nlen + elen + clen

		// The local header repeats the name and extra field, and only it knows
		// how long *its* extra field is.
		if lho + 30 > len(raw) || get32(raw, lho) != 0x0403_4b50 {
			return files, false
		}
		lnlen := get16(raw, lho + 26)
		lelen := get16(raw, lho + 28)
		start := lho + 30 + lnlen + lelen
		if start + csize > len(raw) {
			return files, false
		}
		payload := raw[start:start + csize]

		switch method {
		case 0:
			append(&files, Zip_File{name = name, data = payload})
		case 8:
			buf: bytes.Buffer
			if zlib.inflate(payload, &buf, true, usize) != nil {
				bytes.buffer_destroy(&buf)
				return files, false
			}
			out := make([]u8, len(buf.buf), allocator)
			copy(out, buf.buf[:])
			bytes.buffer_destroy(&buf)
			append(&files, Zip_File{name = name, data = out})
		case:
			// Anything else (bzip2, LZMA) is not something a spreadsheet
			// writer produces; failing loudly beats guessing.
			return files, false
		}
	}
	return files, true
}

zip_find :: proc(files: [dynamic]Zip_File, name: string) -> ([]u8, bool) {
	for f in files {
		if f.name == name {
			return f.data, true
		}
	}
	return nil, false
}
