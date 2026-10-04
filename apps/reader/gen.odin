// Book generators: a real EPUB and a real MOBI, written by this program so
// that reading them back is a round trip rather than a hope.
//
// This is the part of the test suite that no downloaded book can replace. A
// book off the internet tells you "it opened"; a book you wrote tells you the
// spine came back in the order you put it in, that chapter three holds exactly
// the bytes you gave it, that the TOC entry you wrote resolves to the
// paragraph you meant, and that the metadata survived.
//
// The ZIP writer deliberately does *both* storage methods. Stored entries are
// trivial; the deflated ones are written as fixed-Huffman literal blocks,
// which means the reader's inflate path — the real Huffman decoder, not a
// memcpy — is what reads them back. A deflate *compressor* is not needed for
// that: fixed-Huffman literals are a valid deflate stream that happens not to
// compress, and they exercise exactly the code a real book's entries go
// through.
package main

import "core:hash"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// A bit writer, LSB first, which is deflate's bit order
// ---------------------------------------------------------------------------

Bits :: struct {
	out:  [dynamic]u8,
	acc:  u32,
	n:    u32,
}

bits_put :: proc(b: ^Bits, value: u32, count: u32) {
	v := value
	for i in 0 ..< count {
		if v & (1 << i) != 0 {
			b.acc |= 1 << b.n
		}
		b.n += 1
		if b.n == 8 {
			append(&b.out, u8(b.acc))
			b.acc, b.n = 0, 0
		}
	}
}

// bits_put_code writes a Huffman code, which deflate packs most significant
// bit first even though everything else in the format is LSB first.
bits_put_code :: proc(b: ^Bits, code: u32, count: u32) {
	for i := int(count) - 1; i >= 0; i -= 1 {
		bits_put(b, (code >> u32(i)) & 1, 1)
	}
}

bits_flush :: proc(b: ^Bits) {
	if b.n > 0 {
		append(&b.out, u8(b.acc))
		b.acc, b.n = 0, 0
	}
}

// deflate_fixed is a raw deflate stream of `data`, encoded with the fixed
// Huffman tables and no matches. Valid deflate, inflates to exactly `data`,
// and makes the decoder do real work.
deflate_fixed :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	b := Bits {
		out = make([dynamic]u8, 0, len(data) + len(data) / 8 + 16, context.temp_allocator),
	}
	bits_put(&b, 1, 1) // BFINAL
	bits_put(&b, 1, 2) // BTYPE = 01, fixed Huffman
	for c in data {
		if c <= 143 {
			bits_put_code(&b, 0x30 + u32(c), 8)
		} else {
			bits_put_code(&b, 0x190 + u32(c) - 144, 9)
		}
	}
	bits_put_code(&b, 0, 7) // end of block
	bits_flush(&b)
	res := make([]u8, len(b.out), allocator)
	copy(res, b.out[:])
	return res
}

// ---------------------------------------------------------------------------
// ZIP writer
// ---------------------------------------------------------------------------

Zip_Out_Entry :: struct {
	name:     string,
	method:   u16,
	crc:      u32,
	csize:    u32,
	usize:    u32,
	hdr_off:  u32,
}

Zip_Out :: struct {
	buf:     [dynamic]u8,
	entries: [dynamic]Zip_Out_Entry,
}

zip_out_init :: proc(z: ^Zip_Out) {
	z^ = {}
	z.buf = make([dynamic]u8, 0, 4096)
	z.entries = make([dynamic]Zip_Out_Entry, 0, 16)
}

zip_out_destroy :: proc(z: ^Zip_Out) {
	delete(z.buf)
	for e in z.entries {
		delete(e.name)
	}
	delete(z.entries)
	z^ = {}
}

@(private = "file")
w16 :: proc(z: ^[dynamic]u8, v: u16) {
	append(z, u8(v), u8(v >> 8))
}

@(private = "file")
w32 :: proc(z: ^[dynamic]u8, v: u32) {
	append(z, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

// zip_out_add writes one member. `deflated` picks the storage method, which is
// how one archive comes to hold both.
zip_out_add :: proc(z: ^Zip_Out, name: string, data: []u8, deflated: bool) {
	payload := data
	method := u16(0)
	if deflated {
		payload = deflate_fixed(data, context.temp_allocator)
		method = 8
	}
	e := Zip_Out_Entry {
		name    = strings.clone(name),
		method  = method,
		crc     = hash.crc32(data),
		csize   = u32(len(payload)),
		usize   = u32(len(data)),
		hdr_off = u32(len(z.buf)),
	}
	w32(&z.buf, ZIP_LOC)
	w16(&z.buf, 20) // version needed
	w16(&z.buf, 0) // flags
	w16(&z.buf, method)
	w16(&z.buf, 0) // time
	w16(&z.buf, 0) // date
	w32(&z.buf, e.crc)
	w32(&z.buf, e.csize)
	w32(&z.buf, e.usize)
	w16(&z.buf, u16(len(name)))
	w16(&z.buf, 0) // extra
	append(&z.buf, name)
	append(&z.buf, ..payload)
	append(&z.entries, e)
}

zip_out_finish :: proc(z: ^Zip_Out) -> []u8 {
	cd_off := u32(len(z.buf))
	for e in z.entries {
		w32(&z.buf, ZIP_CEN)
		w16(&z.buf, 20) // version made by
		w16(&z.buf, 20) // version needed
		w16(&z.buf, 0) // flags
		w16(&z.buf, e.method)
		w16(&z.buf, 0)
		w16(&z.buf, 0)
		w32(&z.buf, e.crc)
		w32(&z.buf, e.csize)
		w32(&z.buf, e.usize)
		w16(&z.buf, u16(len(e.name)))
		w16(&z.buf, 0) // extra
		w16(&z.buf, 0) // comment
		w16(&z.buf, 0) // disk
		w16(&z.buf, 0) // internal attrs
		w32(&z.buf, 0) // external attrs
		w32(&z.buf, e.hdr_off)
		append(&z.buf, e.name)
	}
	cd_size := u32(len(z.buf)) - cd_off
	w32(&z.buf, ZIP_EOCD)
	w16(&z.buf, 0)
	w16(&z.buf, 0)
	w16(&z.buf, u16(len(z.entries)))
	w16(&z.buf, u16(len(z.entries)))
	w32(&z.buf, cd_size)
	w32(&z.buf, cd_off)
	w16(&z.buf, 0) // comment length
	return z.buf[:]
}

// ---------------------------------------------------------------------------
// A generated EPUB
// ---------------------------------------------------------------------------

Gen_Chapter :: struct {
	file:  string,
	title: string,
	body:  string, // XHTML body content
}

Gen_Book :: struct {
	title:    string,
	author:   string,
	language: string,
	ident:    string,
	chapters: []Gen_Chapter,
	// A deliberately missing spine item, for the hostile case.
	ghost_spine: bool,
	// Give some entries method 0 and some method 8.
	mixed:    bool,
	cover_png: []u8,
}

gen_epub_bytes :: proc(g: Gen_Book, allocator := context.allocator) -> []u8 {
	z: Zip_Out
	zip_out_init(&z)
	defer zip_out_destroy(&z)

	// The mimetype must be first and stored, which is the one rule a writer
	// has to follow for the file to be recognisable by signature.
	zip_out_add(&z, "mimetype", transmute([]u8)string("application/epub+zip"), false)

	container := `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`
	zip_out_add(&z, "META-INF/container.xml", transmute([]u8)container, false)

	css := `body { font-family: serif; }
h1 { font-weight: bold; text-align: center; page-break-before: always; }
p.first { text-indent: 0em; }
.tiny { font-size: 0.8em }
blockquote p { font-style: italic }
pre, code { font-family: monospace }
`
	zip_out_add(&z, "OEBPS/style.css", transmute([]u8)css, true)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<?xml version="1.0" encoding="UTF-8"?>`)
	strings.write_string(
		&sb,
		"\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\">\n",
	)
	strings.write_string(&sb, "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
	strings.write_string(&sb, tfmt("    <dc:title>%s</dc:title>\n", xml_escape(g.title)))
	strings.write_string(&sb, tfmt("    <dc:creator>%s</dc:creator>\n", xml_escape(g.author)))
	strings.write_string(
		&sb,
		tfmt("    <dc:language>%s</dc:language>\n", g.language == "" ? "en" : g.language),
	)
	strings.write_string(
		&sb,
		tfmt("    <dc:identifier id=\"bookid\">%s</dc:identifier>\n", xml_escape(g.ident)),
	)
	strings.write_string(&sb, "    <dc:publisher>palmy reader selftest</dc:publisher>\n")
	if len(g.cover_png) > 0 {
		strings.write_string(&sb, "    <meta name=\"cover\" content=\"coverimg\"/>\n")
	}
	strings.write_string(&sb, "  </metadata>\n  <manifest>\n")
	strings.write_string(
		&sb,
		"    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n",
	)
	strings.write_string(
		&sb,
		"    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n",
	)
	strings.write_string(&sb, "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n")
	if len(g.cover_png) > 0 {
		strings.write_string(
			&sb,
			"    <item id=\"coverimg\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>\n",
		)
	}
	for c, i in g.chapters {
		strings.write_string(
			&sb,
			tfmt(
				"    <item id=\"c%d\" href=\"%s\" media-type=\"application/xhtml+xml\"/>\n",
				i,
				c.file,
			),
		)
	}
	strings.write_string(&sb, "  </manifest>\n  <spine toc=\"ncx\">\n")
	for _, i in g.chapters {
		strings.write_string(&sb, tfmt("    <itemref idref=\"c%d\"/>\n", i))
	}
	if g.ghost_spine {
		// A spine entry the manifest never defines. A real book does this
		// when it is edited by hand; the reader must note it and carry on.
		strings.write_string(&sb, "    <itemref idref=\"chapter-that-does-not-exist\"/>\n")
	}
	strings.write_string(&sb, "  </spine>\n</package>\n")
	zip_out_add(&z, "OEBPS/content.opf", transmute([]u8)strings.to_string(sb), true)

	// The EPUB 3 nav document.
	nb := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&nb,
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n<head><title>Contents</title></head>\n<body>\n<nav epub:type=\"toc\" id=\"toc\">\n<h1>Contents</h1>\n<ol>\n",
	)
	for c in g.chapters {
		strings.write_string(
			&nb,
			tfmt("<li><a href=\"%s\">%s</a></li>\n", c.file, xml_escape(c.title)),
		)
	}
	strings.write_string(&nb, "</ol>\n</nav>\n</body>\n</html>\n")
	zip_out_add(&z, "OEBPS/nav.xhtml", transmute([]u8)strings.to_string(nb), true)

	// And an EPUB 2 NCX, so both TOC readers have something to read.
	xb := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&xb,
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n<head/>\n<docTitle><text>",
	)
	strings.write_string(&xb, xml_escape(g.title))
	strings.write_string(&xb, "</text></docTitle>\n<navMap>\n")
	for c, i in g.chapters {
		strings.write_string(
			&xb,
			tfmt(
				"<navPoint id=\"np%d\" playOrder=\"%d\"><navLabel><text>%s</text></navLabel><content src=\"%s\"/></navPoint>\n",
				i,
				i + 1,
				xml_escape(c.title),
				c.file,
			),
		)
	}
	strings.write_string(&xb, "</navMap>\n</ncx>\n")
	zip_out_add(&z, "OEBPS/toc.ncx", transmute([]u8)strings.to_string(xb), false)

	if len(g.cover_png) > 0 {
		zip_out_add(&z, "OEBPS/cover.png", g.cover_png, false)
	}

	for c, i in g.chapters {
		cb := strings.builder_make(context.temp_allocator)
		strings.write_string(
			&cb,
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head>\n<title>",
		)
		strings.write_string(&cb, xml_escape(c.title))
		strings.write_string(
			&cb,
			"</title>\n<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>\n</head>\n<body>\n",
		)
		strings.write_string(&cb, c.body)
		strings.write_string(&cb, "\n</body>\n</html>\n")
		// Alternate the method, so the archive genuinely mixes the two.
		zip_out_add(
			&z,
			tfmt("OEBPS/%s", c.file),
			transmute([]u8)strings.to_string(cb),
			g.mixed ? (i % 2 == 0) : true,
		)
	}

	raw := zip_out_finish(&z)
	out := make([]u8, len(raw), allocator)
	copy(out, raw)
	return out
}

gen_epub_file :: proc(path: string, g: Gen_Book) -> bool {
	data := gen_epub_bytes(g, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

xml_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "<>&\"") {
		return s
	}
	b := strings.builder_make(allocator)
	for c in transmute([]u8)s {
		switch c {
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '&':
			strings.write_string(&b, "&amp;")
		case '"':
			strings.write_string(&b, "&quot;")
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// A generated MOBI
// ---------------------------------------------------------------------------

// palmdoc_compress is the LZ77 variant Mobipocket uses. It is written here for
// the same reason as the ZIP writer: so that the decompressor is tested
// against data that really went through the encoding, including the two cases
// that are easy to get wrong — a space followed by a letter folded into one
// byte, and an overlapping back-reference.
palmdoc_compress :: proc(src: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src), context.temp_allocator)
	i := 0
	for i < len(src) {
		// Look for a back-reference: 3..10 bytes within 2047 behind.
		best_len, best_dist := 0, 0
		if i >= 1 && i + 3 <= len(src) {
			lo := max(0, i - 2047)
			for j := i - 1; j >= lo; j -= 1 {
				l := 0
				for l < 10 && i + l < len(src) && src[j + l] == src[i + l] {
					l += 1
				}
				if l > best_len {
					best_len, best_dist = l, i - j
				}
				if best_len == 10 {
					break
				}
			}
		}
		if best_len >= 3 {
			m := u16(0x8000) | u16(best_dist) << 3 | u16(best_len - 3)
			append(&out, u8(m >> 8), u8(m))
			i += best_len
			continue
		}

		c := src[i]
		// A space followed by a printable ASCII letter is one byte.
		if c == ' ' && i + 1 < len(src) {
			d := src[i + 1]
			if d >= 0x40 && d < 0x80 {
				append(&out, d | 0x80)
				i += 2
				continue
			}
		}
		if c == 0 || (c >= 0x09 && c < 0x80) {
			append(&out, c)
			i += 1
			continue
		}
		// Anything else is escaped as a literal run.
		j := i
		for j < len(src) && j - i < 8 {
			e := src[j]
			if e == 0 || (e >= 0x09 && e < 0x80) {
				break
			}
			j += 1
		}
		n := max(1, j - i)
		append(&out, u8(n))
		append(&out, ..src[i:i + n])
		i += n
	}
	res := make([]u8, len(out), allocator)
	copy(res, out[:])
	return res
}

Gen_Mobi :: struct {
	title:    string,
	author:   string,
	html:     string,
	compress: bool, // false writes record compression 1, uncompressed
	truncate_last: bool, // cut the final text record short, for the hostile case
}

MOBI_REC_SIZE :: 4096

gen_mobi_bytes :: proc(g: Gen_Mobi, allocator := context.allocator) -> []u8 {
	text := transmute([]u8)g.html

	// Split the text into 4096-byte records and compress each one.
	recs := make([dynamic][]u8, 0, 16, context.temp_allocator)
	for at := 0; at < len(text); at += MOBI_REC_SIZE {
		chunk := text[at:min(at + MOBI_REC_SIZE, len(text))]
		if g.compress {
			append(&recs, palmdoc_compress(chunk, context.temp_allocator))
		} else {
			append(&recs, chunk)
		}
	}
	if len(recs) == 0 {
		append(&recs, []u8{})
	}
	if g.truncate_last && len(recs) > 0 {
		last := recs[len(recs) - 1]
		if len(last) > 4 {
			recs[len(recs) - 1] = last[:len(last) / 2]
		}
	}

	// Record 0: PalmDOC header, MOBI header, EXTH, then the full name.
	r0 := make([dynamic]u8, 0, 1024, context.temp_allocator)
	be16 :: proc(b: ^[dynamic]u8, v: u16) {
		append(b, u8(v >> 8), u8(v))
	}
	be32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}

	be16(&r0, g.compress ? 2 : 1) // compression
	be16(&r0, 0)
	be32(&r0, u32(len(text))) // text length
	be16(&r0, u16(len(recs))) // record count
	be16(&r0, MOBI_REC_SIZE)
	be16(&r0, 0) // encryption: none
	be16(&r0, 0)

	// The MOBI header is written at a fixed 0xE8 bytes so that the extra-data
	// flags field at 0xF2 of the record falls inside it, which is where a
	// reader looks for it.
	MOBI_LEN :: 0xE8
	mobi_start := len(r0)
	be32(&r0, 0x4d4f4249) // "MOBI"
	be32(&r0, MOBI_LEN)
	be32(&r0, 2) // mobi type: book
	be32(&r0, 65001) // UTF-8
	be32(&r0, 0xdeadbeef) // unique id
	be32(&r0, 6) // file version
	for _ in 0 ..< 10 {
		be32(&r0, 0xffffffff) // index fields: none
	}
	be32(&r0, u32(len(recs) + 1)) // first non-book index
	full_name_off_at := len(r0)
	be32(&r0, 0) // full name offset, patched below
	be32(&r0, u32(len(g.title)))
	be32(&r0, 9) // locale: en
	be32(&r0, 0) // input language
	be32(&r0, 0) // output language
	be32(&r0, 6) // min version
	be32(&r0, 0xffffffff) // first image index
	be32(&r0, 0) // huff record offset
	be32(&r0, 0) // huff record count
	be32(&r0, 0) // datp
	be32(&r0, 0)
	be32(&r0, 0x40) // exth flags: EXTH present
	for len(r0) - mobi_start < MOBI_LEN {
		append(&r0, 0)
	}

	// EXTH.
	exth := make([dynamic]u8, 0, 256, context.temp_allocator)
	add_exth :: proc(b: ^[dynamic]u8, kind: u32, val: string) {
		append(b, u8(kind >> 24), u8(kind >> 16), u8(kind >> 8), u8(kind))
		n := u32(len(val) + 8)
		append(b, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
		append(b, val)
	}
	add_exth(&exth, 100, g.author) // author
	add_exth(&exth, 101, "palmy reader selftest") // publisher
	add_exth(&exth, 503, g.title) // updated title
	nrec := 3

	be32(&r0, 0x45585448) // "EXTH"
	be32(&r0, u32(12 + len(exth)))
	be32(&r0, u32(nrec))
	append(&r0, ..exth[:])
	for len(r0) % 4 != 0 {
		append(&r0, 0)
	}

	name_off := u32(len(r0))
	append(&r0, g.title)
	append(&r0, 0, 0)
	for len(r0) % 4 != 0 {
		append(&r0, 0)
	}
	// Patch the full-name offset now that it is known.
	r0[full_name_off_at + 0] = u8(name_off >> 24)
	r0[full_name_off_at + 1] = u8(name_off >> 16)
	r0[full_name_off_at + 2] = u8(name_off >> 8)
	r0[full_name_off_at + 3] = u8(name_off)

	// Assemble the PalmDB.
	all := make([dynamic][]u8, 0, len(recs) + 1, context.temp_allocator)
	append(&all, r0[:])
	for r in recs {
		append(&all, r)
	}

	out := make([dynamic]u8, 0, 4096, context.temp_allocator)
	name := g.title
	if len(name) > 31 {
		name = name[:31]
	}
	append(&out, name)
	for len(out) < 32 {
		append(&out, 0)
	}
	be16(&out, 0) // attributes
	be16(&out, 0) // version
	be32(&out, 0) // created
	be32(&out, 0) // modified
	be32(&out, 0) // backed up
	be32(&out, 0) // modification number
	be32(&out, 0) // app info
	be32(&out, 0) // sort info
	be32(&out, 0x424f4f4b) // "BOOK"
	be32(&out, 0x4d4f4249) // "MOBI"
	be32(&out, 0) // unique id seed
	be32(&out, 0) // next record list
	be16(&out, u16(len(all)))

	// Record info entries, then a two-byte gap, then the records.
	data_start := len(out) + 8 * len(all) + 2
	off := data_start
	for r, i in all {
		be32(&out, u32(off))
		append(&out, 0) // attributes
		append(&out, 0, 0, u8(i)) // unique id
		off += len(r)
	}
	be16(&out, 0)
	for r in all {
		append(&out, ..r)
	}

	res := make([]u8, len(out), allocator)
	copy(res, out[:])
	return res
}

gen_mobi_file :: proc(path: string, g: Gen_Mobi) -> bool {
	data := gen_mobi_bytes(g, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

// ---------------------------------------------------------------------------
// A large book, for the performance numbers
//
// The fixture book is small on purpose: it is there to be asserted on, not to
// be heavy. A reader's performance claims have to be made against something
// the size of an actual novel, so this writes one — chapters of real
// paragraphs with varied word lengths, because wrapping cost depends on how
// often a line break has to be looked for and uniform text would flatter it.
// ---------------------------------------------------------------------------

GEN_WORDS := [?]string {
	"the", "measure", "of", "a", "line", "is", "how", "far", "it", "may", "run",
	"before", "the", "eye", "must", "return", "and", "find", "its", "place",
	"again", "which", "typographers", "have", "argued", "about", "since",
	"Gutenberg", "without", "ever", "quite", "agreeing", "on", "an", "answer",
	"though", "most", "settle", "somewhere", "between", "sixty", "and",
	"seventy-five", "characters", "counting", "spaces", "because", "beyond",
	"that", "the", "return", "sweep", "becomes", "unreliable", "and", "below",
	"it", "the", "rhythm", "of", "reading", "breaks", "into", "fragments",
	"shorter", "than", "a", "thought", "constantly", "interrupted",
	"antidisestablishmentarianism", "notwithstanding",
}

// gen_big_body builds the chapters; gen_big_epub packs them into an EPUB and
// gen_big_mobi concatenates them into the single HTML stream a MOBI is.
gen_big_chapters :: proc(
	chapters, paras_per: int,
	allocator := context.temp_allocator,
) -> (
	chs: []Gen_Chapter,
	bytes: int,
) {
	out := make([]Gen_Chapter, chapters, allocator)
	seed := u64(0x2545F4914F6CDD1D)
	next :: proc(s: ^u64) -> u64 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 7
		s^ ~= s^ << 17
		return s^
	}
	total := 0
	for c in 0 ..< chapters {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, tfmt("<h1 id=\"c%d\">Chapter %d</h1>\n", c + 1, c + 1))
		for pi in 0 ..< paras_per {
			switch next(&seed) % 24 {
			case 0:
				strings.write_string(&b, tfmt("<h2>Section %d.%d</h2>\n", c + 1, pi))
			case 1:
				strings.write_string(&b, "<blockquote><p>")
			case 2:
				strings.write_string(&b, "<ul><li>")
			case:
				strings.write_string(&b, "<p>")
			}
			words := 40 + int(next(&seed) % 120)
			for w in 0 ..< words {
				if w > 0 {
					strings.write_byte(&b, ' ')
				}
				word := GEN_WORDS[next(&seed) % u64(len(GEN_WORDS))]
				switch next(&seed) % 40 {
				case 0:
					strings.write_string(&b, tfmt("<em>%s</em>", word))
				case 1:
					strings.write_string(&b, tfmt("<strong>%s</strong>", word))
				case 2:
					strings.write_string(&b, tfmt("<a href=\"ch%d.xhtml#c%d\">%s</a>", 1, 1, word))
				case:
					strings.write_string(&b, word)
				}
			}
			strings.write_string(&b, ".")
			strings.write_string(&b, "</p>\n")
			if false {
			}
		}
		body := strings.to_string(b)
		total += len(body)
		out[c] = {
			file = strings.clone(tfmt("ch%d.xhtml", c + 1), allocator),
			title = strings.clone(tfmt("Chapter %d", c + 1), allocator),
			body = body,
		}
	}
	chs = out
	_ = 0
	return chs, total
}

gen_big_epub :: proc(path: string, chapters, paras_per: int) -> (ok: bool, bytes: int) {
	chs, total := gen_big_chapters(chapters, paras_per, context.temp_allocator)
	g := Gen_Book {
		title = "A Large Generated Novel",
		author = "L. Fixture",
		language = "en",
		ident = "urn:uuid:palmy-reader-large-0001",
		chapters = chs,
		mixed = true,
	}
	return gen_epub_file(path, g), total
}

gen_big_mobi :: proc(path: string, chapters, paras_per: int) -> (ok: bool, bytes: int) {
	chs, total := gen_big_chapters(chapters, paras_per, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<html><head><title>A Large Generated Novel</title></head><body>\n")
	for c in chs {
		strings.write_string(&b, c.body)
		strings.write_string(&b, "<mbp:pagebreak/>\n")
	}
	strings.write_string(&b, "</body></html>\n")
	html := strings.to_string(b)
	return gen_mobi_file(
		path,
		{title = "A Large Generated Novel", author = "L. Fixture", html = html, compress = true},
	), total
}
