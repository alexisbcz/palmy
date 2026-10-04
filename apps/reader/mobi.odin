// MOBI: a PalmDB container with Mobipocket headers inside it.
//
// The layout, outside in:
//
//   PalmDB        a 78-byte header, then one 8-byte entry per record giving
//                 its file offset. Records are delimited by the next entry's
//                 offset, which is why a truncated file still yields every
//                 record but the last.
//   record 0      the 16-byte PalmDOC header (compression, text length,
//                 record count, record size), then the MOBI header, then the
//                 EXTH metadata block, then the book's full title.
//   records 1..n  the text, in `record_size` chunks, each compressed on its
//                 own. Some of them carry trailing bytes that are not text at
//                 all and must be cut off first.
//   after that    images, one per record, addressed by `recindex` from the
//                 markup.
//
// Compression, and this is the part to be plain about:
//
//   1      no compression. Supported.
//   2      PalmDOC LZ77. Supported, and tested against this program's own
//          compressor in gen.odin, including the space-folding byte and
//          overlapping back-references.
//   17480  HUFF/CDIC. Supported: the HUFF record's two dispatch tables are
//          read, the CDIC records are loaded as a lazily-resolved phrase
//          dictionary, and the bitstream is decoded with the same algorithm
//          every other reader uses. It is *not* covered by a round trip,
//          because writing a HUFF/CDIC compressor is a much larger job than
//          reading one — so it is exercised against hand-built tables in the
//          selftest and against the structure checks here, and a file whose
//          tables do not validate is reported rather than decoded into
//          nonsense.
//
// Encryption is not supported and never will be: a DRM-ed book is reported as
// such and not opened.
package main

import "core:strings"

MOBI_NO_COMPRESSION :: 1
MOBI_PALMDOC :: 2
MOBI_HUFFCDIC :: 17480

Mobi :: struct {
	data:      []u8,
	offsets:   [dynamic]i64, // record i spans [offsets[i], offsets[i+1])
	compress:  u16,
	text_len:  int,
	rec_count: int,
	rec_size:  int,
	encrypted: bool,
	encoding:  u32,
	extra:     u16, // the extra-data flags
	first_img: int, // record index of the first image, -1 for none
	huff_off:  int,
	huff_cnt:  int,
	title:     string,
	author:    string,
	publisher: string,
	// The decompressed text, held because images are addressed into the
	// record list and because `filepos` links are offsets into it.
	html:      string,
	huff:      Huff,
}

mobi_destroy :: proc(m: ^Mobi) {
	delete(m.data)
	delete(m.offsets)
	delete(m.title)
	delete(m.author)
	delete(m.publisher)
	delete(m.html)
	huff_destroy(&m.huff)
	m^ = {}
}

@(private = "file")
be16 :: proc(b: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(b) {
		return 0
	}
	return u16(b[at]) << 8 | u16(b[at + 1])
}

@(private = "file")
be32 :: proc(b: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) {
		return 0
	}
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

@(private = "file")
be64 :: proc(b: []u8, at: int) -> u64 {
	return u64(be32(b, at)) << 32 | u64(be32(b, at + 4))
}

mobi_record :: proc(m: ^Mobi, i: int) -> []u8 {
	if i < 0 || i + 1 >= len(m.offsets) {
		return nil
	}
	a, b := m.offsets[i], m.offsets[i + 1]
	a = clamp(a, 0, i64(len(m.data)))
	b = clamp(b, a, i64(len(m.data)))
	return m.data[a:b]
}

// mobi_open reads the container and fills the Doc. The Mobi keeps the file
// bytes, because images are records and are decoded on demand.
mobi_open :: proc(m: ^Mobi, d: ^Doc, path: string) -> (ok: bool, err: string) {
	m.first_img = -1
	data, rerr := read_file(path)
	if rerr != "" {
		return false, rerr
	}
	m.data = data
	if len(m.data) < 80 {
		return false, "too short to be a PalmDB file"
	}

	typ := be32(m.data, 60)
	cre := be32(m.data, 64)
	// "BOOK"/"MOBI", or "TEXt"/"REAd" for a plain PalmDOC.
	is_mobi := typ == 0x424f4f4b && cre == 0x4d4f4249
	is_palm := typ == 0x54455874 && cre == 0x52456164
	if !is_mobi && !is_palm {
		return false, "not a Mobipocket or PalmDOC file (wrong type/creator)"
	}

	n := int(be16(m.data, 76))
	if n <= 0 || 78 + 8 * n > len(m.data) {
		return false, "the record list is missing or truncated"
	}
	m.offsets = make([dynamic]i64, 0, n + 1)
	prev := i64(-1)
	for i in 0 ..< n {
		off := i64(be32(m.data, 78 + 8 * i))
		// A record list that does not increase is corrupt; stop there rather
		// than reading the file backwards.
		if off < prev {
			doc_note(d, tfmt("record %d's offset goes backwards; stopped there", i))
			break
		}
		append(&m.offsets, clamp(off, 0, i64(len(m.data))))
		prev = off
	}
	append(&m.offsets, i64(len(m.data)))
	if len(m.offsets) < 2 {
		return false, "no records"
	}

	r0 := mobi_record(m, 0)
	if len(r0) < 16 {
		return false, "record 0 is too short to hold a PalmDOC header"
	}
	m.compress = be16(r0, 0)
	m.text_len = int(be32(r0, 4))
	m.rec_count = int(be16(r0, 8))
	m.rec_size = int(be16(r0, 10))
	if m.rec_size <= 0 {
		m.rec_size = 4096
	}
	enc := be16(r0, 12)
	m.encrypted = enc != 0
	if m.encrypted {
		return false, tfmt("the book is encrypted (DRM scheme %d) and cannot be opened", enc)
	}

	m.encoding = 1252
	// Every offset below is from the start of record 0, which is where the
	// format's own documentation counts from: the 16-byte PalmDOC header, then
	// the MOBI header at 16, so "First Non-book index at 0x50" means byte 80
	// of the record and not byte 80 of the MOBI header. Adding the 16 twice is
	// the classic way to read the output language as a name offset and come
	// away with no metadata at all.
	if is_mobi && len(r0) >= 24 && be32(r0, 16) == 0x4d4f4249 {
		hlen := int(be32(r0, 20))
		m.encoding = be32(r0, 28)
		fni := int(be32(r0, 0x50))
		name_off := int(be32(r0, 0x54))
		name_len := int(be32(r0, 0x58))
		fimg := int(be32(r0, 0x6c))
		m.huff_off = int(be32(r0, 0x70))
		m.huff_cnt = int(be32(r0, 0x74))
		exth_flags := be32(r0, 0x80)

		if fimg > 0 && fimg != 0xffffffff && fimg < len(m.offsets) {
			m.first_img = fimg
		} else if fni > 0 && fni < len(m.offsets) {
			// Some writers leave first_image_index unset but do set
			// first_non_book_index, which is where the images start anyway.
			m.first_img = fni
		}

		if name_off > 0 && name_len > 0 && name_off + name_len <= len(r0) {
			m.title = strings.clone(strings.trim_space(string(r0[name_off:name_off + name_len])))
		}

		// The extra-data flags live at a fixed byte in record 0, not at a
		// fixed place in the MOBI header, and only exist on a long enough
		// header. Getting this wrong puts index garbage at the end of every
		// chapter, which is the classic MOBI rendering bug.
		if hlen >= 0xE4 && len(r0) >= 0xF4 {
			m.extra = be16(r0, 0xF2)
		}

		if exth_flags & 0x40 != 0 {
			mobi_read_exth(m, d, r0, 16 + hlen)
		}
	}

	if m.title == "" {
		m.title = strings.clone(strings.trim_space(mobi_db_name(m.data)))
	}
	if m.title != "" && d.title == "" {
		d.title = strings.clone(m.title)
	}
	if m.author != "" && d.author == "" {
		d.author = strings.clone(m.author)
	}
	if m.publisher != "" && d.publisher == "" {
		d.publisher = strings.clone(m.publisher)
	}

	raw, derr := mobi_text(m, d)
	if derr != "" {
		return false, derr
	}
	m.html = raw
	if len(m.html) == 0 {
		return false, "the book decompressed to nothing"
	}

	// Parse it as one long HTML file.
	append(&d.chapters, Chapter{path = strings.clone(""), first = 0, count = 0})
	b: Doc_Builder
	builder_init(&b, d)
	defer builder_destroy(&b)
	b.chapter = 0
	css: Css
	css_init(&css)
	defer css_destroy(&css)
	title := html_parse(&b, m.html, {self_path = "", base_dir = "", css = &css, mobi = true})
	builder_flush(&b)
	d.chapters[0].count = len(d.blocks)
	d.chapters[0].title = strings.clone(title != "" ? title : (m.title != "" ? m.title : "Book"))
	if d.title == "" && title != "" {
		d.title = strings.clone(title)
	}

	if len(d.blocks) == 0 {
		return false, "the book parsed to no text"
	}

	// A MOBI has no spine, so a reader has to invent chapters. Headings are
	// the only structure the format leaves behind, so they become both the
	// chapter boundaries and the table of contents. A book with no headings
	// gets one chapter, which is honest: that is what the file says.
	mobi_split_chapters(m, d)
	return true, ""
}

@(private = "file")
mobi_db_name :: proc(data: []u8) -> string {
	end := 0
	for end < 32 && end < len(data) && data[end] != 0 {
		end += 1
	}
	return string(data[:end])
}

@(private = "file")
mobi_read_exth :: proc(m: ^Mobi, d: ^Doc, r0: []u8, at: int) {
	if at + 12 > len(r0) || be32(r0, at) != 0x45585448 {
		return
	}
	hlen := int(be32(r0, at + 4))
	count := int(be32(r0, at + 8))
	p := at + 12
	limit := min(len(r0), at + max(hlen, 12))
	for _ in 0 ..< min(count, 1024) {
		if p + 8 > limit {
			break
		}
		kind := be32(r0, p)
		rlen := int(be32(r0, p + 4))
		if rlen < 8 || p + rlen > limit {
			break
		}
		val := string(r0[p + 8:p + rlen])
		switch kind {
		case 100:
			if m.author == "" {m.author = strings.clone(strings.trim_space(val))}
		case 101:
			if m.publisher == "" {m.publisher = strings.clone(strings.trim_space(val))}
		case 104:
			if d.ident == "" {d.ident = strings.clone(strings.trim_space(val))}
		case 106:
			// publication date; kept out of the model, nothing shows it
		case 503:
			// The updated title wins over the one in record 0, which is
			// often a truncated or mangled file name.
			t := strings.trim_space(val)
			if t != "" {
				delete(m.title)
				m.title = strings.clone(t)
			}
		}
		p += rlen
	}
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

@(private = "file")
mobi_text :: proc(m: ^Mobi, d: ^Doc) -> (text: string, err: string) {
	out := make([dynamic]u8, 0, max(m.text_len, 4096))

	if m.compress == MOBI_HUFFCDIC {
		if m.huff_cnt <= 0 || m.huff_off <= 0 {
			delete(out)
			return "", "the book is HUFF/CDIC compressed but names no HUFF record"
		}
		if herr := huff_load(&m.huff, m, d); herr != "" {
			delete(out)
			return "", herr
		}
	}

	last := min(m.rec_count, len(m.offsets) - 2)
	if last <= 0 {
		// Some books understate the record count. Fall back to every record
		// before the images.
		last = m.first_img > 0 ? m.first_img - 1 : len(m.offsets) - 2
	}
	bad := 0
	for i in 1 ..= last {
		rec := mobi_record(m, i)
		if len(rec) == 0 {
			continue
		}
		rec = mobi_strip_trailing(rec, m.extra)
		if len(rec) == 0 {
			continue
		}
		switch m.compress {
		case MOBI_NO_COMPRESSION:
			append(&out, ..rec)
		case MOBI_PALMDOC:
			if !palmdoc_decompress(rec, &out) {
				bad += 1
			}
		case MOBI_HUFFCDIC:
			if !huff_unpack(&m.huff, rec, &out) {
				bad += 1
			}
		case:
			delete(out)
			return "", tfmt("unknown compression scheme %d", m.compress)
		}
	}
	if bad > 0 {
		doc_note(d, tfmt("%d of %d text records were truncated or corrupt", bad, last))
	}
	// The PalmDOC header says how long the text is. Coming up short is damage
	// even when every record decompressed without complaining, because a
	// record can be cut at a token boundary and stop cleanly.
	if m.text_len > 0 && len(out) < m.text_len {
		doc_note(
			d,
			tfmt(
				"the text is %d bytes short of the %d the header promises; the file looks truncated",
				m.text_len - len(out),
				m.text_len,
			),
		)
	}

	// The PalmDOC header says how long the text is. Trust it when it is
	// shorter than what came out, because the last record is padded.
	if m.text_len > 0 && m.text_len < len(out) {
		resize(&out, m.text_len)
	}

	if m.encoding == 1252 {
		s := cp1252_to_utf8(out[:])
		delete(out)
		return s, ""
	}
	res := strings.clone(string(out[:]))
	delete(out)
	return res, ""
}

// mobi_strip_trailing cuts the non-text bytes off the end of a record.
//
// Each set bit above the lowest in the extra-data flags means one
// backwards-encoded, variable-length entry at the tail; the lowest bit means
// the last two low bits of the final byte say how many bytes of a multi-byte
// character were carried over from the previous record. Every one of them has
// to go before the record is decompressed, or the text ends with garbage.
mobi_strip_trailing :: proc(rec: []u8, flags: u16) -> []u8 {
	size := len(rec)
	num := 0

	entry_size :: proc(rec: []u8, size: int) -> int {
		bitpos, result := u32(0), 0
		s := size
		if s <= 0 {
			return 0
		}
		for {
			if s <= 0 || s > len(rec) {
				return result
			}
			v := rec[s - 1]
			result |= int(u32(v & 0x7f) << bitpos)
			bitpos += 7
			s -= 1
			if v & 0x80 != 0 || bitpos >= 28 || s == 0 {
				return result
			}
		}
	}

	test := flags >> 1
	for test != 0 {
		if test & 1 != 0 {
			num += entry_size(rec, size - num)
			if num >= size {
				return nil
			}
		}
		test >>= 1
	}
	if flags & 1 != 0 {
		if size - num - 1 < 0 {
			return nil
		}
		num += int(rec[size - num - 1] & 0x3) + 1
	}
	if num >= size {
		return nil
	}
	return rec[:size - num]
}

// palmdoc_decompress is the LZ77 variant Mobipocket inherited from PalmDOC.
// Returns false when the record ends mid-token, which a truncated file does;
// everything decoded up to that point is kept.
palmdoc_decompress :: proc(src: []u8, out: ^[dynamic]u8) -> bool {
	i := 0
	for i < len(src) {
		c := src[i]
		i += 1
		switch {
		case c == 0:
			append(out, u8(0))
		case c >= 0x01 && c <= 0x08:
			// A run of literal bytes, used for anything the other cases
			// would otherwise claim.
			n := int(c)
			if i + n > len(src) {
				append(out, ..src[i:])
				return false
			}
			append(out, ..src[i:i + n])
			i += n
		case c < 0x80:
			append(out, c)
		case c >= 0xc0:
			// A space plus one letter, folded into a single byte.
			append(out, u8(' '), c ~ 0x80)
		case:
			// 0x80..0xbf: a back-reference, two bytes.
			if i >= len(src) {
				return false
			}
			m := u32(c) << 8 | u32(src[i])
			i += 1
			dist := int((m >> 3) & 0x07ff)
			n := int(m & 0x7) + 3
			if dist == 0 || dist > len(out) {
				return false
			}
			// Copied one byte at a time on purpose: the source and
			// destination overlap when dist < n, and that is how a run is
			// encoded.
			base := len(out) - dist
			for k in 0 ..< n {
				append(out, out[base + k])
			}
		}
	}
	return true
}

// cp1252_to_utf8 widens the 8-bit encoding most MOBI files declare. Bytes
// 0x00..0x7f pass through, 0x80..0x9f go through the Windows table, and the
// rest are Latin-1, which is also their Unicode code point.
cp1252_to_utf8 :: proc(src: []u8, allocator := context.allocator) -> string {
	HIGH := [32]rune {
		0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
		0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d, 0x017d, 0x8f,
		0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
		0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d, 0x017e, 0x0178,
	}
	b := strings.builder_make(allocator)
	strings.builder_grow(&b, len(src) + len(src) / 8)
	for c in src {
		if c < 0x80 {
			strings.write_byte(&b, c)
		} else if c < 0xa0 {
			strings.write_rune(&b, HIGH[c - 0x80])
		} else {
			strings.write_rune(&b, rune(c))
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Chapters and the table of contents
// ---------------------------------------------------------------------------

@(private = "file")
mobi_split_chapters :: proc(m: ^Mobi, d: ^Doc) {
	// Headings at the shallowest level present become the chapter breaks.
	level := Block_Kind.H1
	found := false
	for lvl in ([?]Block_Kind{.H1, .H2, .H3}) {
		for b in d.blocks {
			if b.kind == lvl {
				level = lvl
				found = true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		append(
			&d.toc,
			Toc_Entry{title = strings.clone(d.chapters[0].title), depth = 0, block = 0},
		)
		return
	}

	// Rebuild the chapter list around the headings.
	old_title := d.chapters[0].title
	old_path := d.chapters[0].path
	clear(&d.chapters)
	starts := make([dynamic]int, 0, 32, context.temp_allocator)
	for b, i in d.blocks {
		if b.kind == level && i > 0 {
			append(&starts, i)
		}
	}
	bounds := make([dynamic]int, 0, len(starts) + 2, context.temp_allocator)
	append(&bounds, 0)
	for s in starts {
		append(&bounds, s)
	}
	append(&bounds, len(d.blocks))

	for k in 0 ..< len(bounds) - 1 {
		first, last := bounds[k], bounds[k + 1]
		name := ""
		if d.blocks[first].kind == level {
			name = strings.trim_space(block_text(d, first))
		}
		if name == "" {
			name = k == 0 ? old_title : tfmt("Part %d", k + 1)
		}
		bytes := 0
		for bi in first ..< last {
			bytes += int(d.blocks[bi].n)
			d.blocks[bi].chapter = i32(k)
		}
		append(
			&d.chapters,
			Chapter {
				path = strings.clone(old_path),
				title = strings.clone(name),
				first = first,
				count = last - first,
				bytes = bytes,
			},
		)
		append(&d.toc, Toc_Entry{title = strings.clone(name), depth = 0, block = first})
	}
	delete(old_title)

	// Sub-headings become nested TOC entries, which is as close to a real
	// table of contents as a MOBI can get.
	for b, i in d.blocks {
		dep := 0
		switch {
		case b.kind == level:
			continue
		case b.kind == .H2 && level == .H1:
			dep = 1
		case b.kind == .H3 && (level == .H1 || level == .H2):
			dep = level == .H1 ? 2 : 1
		case:
			continue
		}
		t := strings.trim_space(block_text(d, i))
		if t == "" {
			continue
		}
		// Insert in reading order.
		at := len(d.toc)
		for k in 0 ..< len(d.toc) {
			if d.toc[k].block > i {
				at = k
				break
			}
		}
		inject_at(&d.toc, at, Toc_Entry{title = strings.clone(t), depth = dep, block = i})
	}
	_ = m
}

// mobi_image_record maps a markup `recindex` to a record index.
mobi_image_record :: proc(m: ^Mobi, recindex: int) -> int {
	if m.first_img < 0 || recindex <= 0 {
		return -1
	}
	i := m.first_img + recindex - 1
	if i + 1 >= len(m.offsets) {
		return -1
	}
	return i
}
