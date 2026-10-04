// HUFF/CDIC, Mobipocket's second compression scheme.
//
// It is a canonical Huffman code over a *phrase* dictionary rather than over
// bytes: a symbol decodes to a run of output, and a run may itself be a
// compressed bitstream that decodes to more output. Two records types carry it:
//
//   HUFF   two dispatch tables. The first is indexed by the top 8 bits of the
//          lookahead and gives, for the common case, the code length, whether
//          that length is final, and the largest code of that length. The
//          second holds min/max code per length 1..32, for when it is not.
//   CDIC   the phrase dictionary, in blocks. Each block starts with a count
//          and a code-length, then an array of 16-bit offsets into itself.
//          At each offset: a 16-bit length whose top bit says whether the
//          phrase is plain text or another bitstream.
//
// The nesting is why `huff_unpack` is recursive and why entries are resolved
// lazily and then cached: a phrase that is itself compressed is decoded once,
// however many times it is referenced.
//
// There is no round-trip test for this, because writing the compressor is a
// much bigger job than writing the decoder. What there is instead: the table
// loader validates every field it depends on and refuses a file whose tables
// are inconsistent, the selftest decodes a bitstream against tables built by
// hand, and a book that cannot be decoded says so.
package main

import "core:strings"

@(private = "file")
Cdic_Ent :: struct {
	raw:  []u8, // the phrase, header included, borrowed from the record
	val:  []u8, // resolved bytes; owned when `owned`
	done: bool,
	owned: bool,
}

Huff :: struct {
	ok:       bool,
	codelen:  [256]u8,
	term:     [256]bool,
	dmax:     [256]u64,
	mincode:  [33]u64,
	maxcode:  [33]u64,
	ents:     [dynamic]Cdic_Ent,
	depth_hit: bool,
}

huff_destroy :: proc(h: ^Huff) {
	for &e in h.ents {
		if e.owned {
			delete(e.val)
		}
	}
	delete(h.ents)
	h^ = {}
}

@(private = "file")
hb16 :: proc(b: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(b) {
		return 0
	}
	return u16(b[at]) << 8 | u16(b[at + 1])
}

@(private = "file")
hb32 :: proc(b: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) {
		return 0
	}
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

@(private = "file")
hb64 :: proc(b: []u8, at: int) -> u64 {
	return u64(hb32(b, at)) << 32 | u64(hb32(b, at + 4))
}

// huff_load reads the HUFF record and every CDIC after it.
huff_load :: proc(h: ^Huff, m: ^Mobi, d: ^Doc) -> (err: string) {
	hr := mobi_record(m, m.huff_off)
	if herr := huff_tables(h, hr); herr != "" {
		return herr
	}
	h.ents = make([dynamic]Cdic_Ent, 0, 4096)
	loaded := 0
	for k in 1 ..< m.huff_cnt {
		cr := mobi_record(m, m.huff_off + k)
		if n := huff_cdic(h, cr); n > 0 {
			loaded += 1
		}
	}
	if len(h.ents) == 0 {
		return "the HUFF/CDIC dictionary is empty"
	}
	if loaded + 1 != m.huff_cnt {
		doc_note(
			d,
			tfmt("%d of %d CDIC records were unreadable", m.huff_cnt - 1 - loaded, m.huff_cnt - 1),
		)
	}
	h.ok = true
	return ""
}

// huff_tables parses a HUFF record. Exposed so the selftest can hand it a
// record it built itself.
huff_tables :: proc(h: ^Huff, hr: []u8) -> (err: string) {
	if len(hr) < 24 || string(hr[0:4]) != "HUFF" {
		return "the HUFF record is missing or does not start with \"HUFF\""
	}
	off1 := int(hb32(hr, 8))
	off2 := int(hb32(hr, 12))
	if off1 < 0 || off1 + 256 * 4 > len(hr) {
		return "the HUFF record's first dispatch table is outside the record"
	}
	if off2 < 0 || off2 + 64 * 4 > len(hr) {
		return "the HUFF record's second dispatch table is outside the record"
	}

	for i in 0 ..< 256 {
		v := hb32(hr, off1 + 4 * i)
		cl := u8(v & 0x1f)
		if cl == 0 || cl > 32 {
			return "the HUFF table holds a zero or over-long code length"
		}
		h.codelen[i] = cl
		h.term[i] = v & 0x80 != 0
		h.dmax[i] = ((u64(v >> 8) + 1) << (32 - u64(cl))) - 1
	}
	for i in 0 ..< 32 {
		lo := u64(hb32(hr, off2 + 8 * i))
		hi := u64(hb32(hr, off2 + 8 * i + 4))
		h.mincode[i] = lo << (32 - u64(i))
		h.maxcode[i] = ((hi + 1) << (32 - u64(i))) - 1
	}
	h.mincode[32] = 0
	h.maxcode[32] = ~u64(0)
	return ""
}

// huff_cdic loads one dictionary block and returns how many phrases it added.
huff_cdic :: proc(h: ^Huff, cr: []u8) -> int {
	if len(cr) < 16 || string(cr[0:4]) != "CDIC" {
		return 0
	}
	phrases := int(hb32(cr, 8))
	bits := int(hb32(cr, 12))
	if bits < 0 || bits > 16 {
		return 0
	}
	want := min(1 << uint(bits), max(0, phrases - len(h.ents)))
	if want <= 0 {
		return 0
	}
	added := 0
	for i in 0 ..< want {
		at := 16 + 2 * i
		if at + 2 > len(cr) {
			break
		}
		off := int(hb16(cr, at))
		base := 16 + off
		if base + 2 > len(cr) {
			break
		}
		append(&h.ents, Cdic_Ent{raw = cr[base:]})
		added += 1
	}
	return added
}

// huff_begin_dict starts an empty phrase dictionary. The loader calls it; the
// selftest calls it too, because the Cdic_Ent type is deliberately private and
// a test should drive the same entry points a book does.
huff_begin_dict :: proc(h: ^Huff, allocator := context.allocator) {
	h.ents = make([dynamic]Cdic_Ent, 0, 4096, allocator)
}

// huff_arm marks the tables as usable, after huff_tables and huff_cdic have
// both been given something valid.
huff_arm :: proc(h: ^Huff) {
	h.ok = len(h.ents) > 0
}

// huff_phrase_count is how many phrases the dictionary holds.
huff_phrase_count :: proc(h: ^Huff) -> int {
	return len(h.ents)
}

// huff_unpack decodes one text record. Returns false when the bitstream runs
// out mid-symbol or the tables disagree with it; whatever decoded is kept.
huff_unpack :: proc(h: ^Huff, data: []u8, out: ^[dynamic]u8) -> bool {
	if !h.ok {
		return false
	}
	return huff_decode(h, data, out, 0)
}

@(private = "file")
huff_decode :: proc(h: ^Huff, data: []u8, out: ^[dynamic]u8, depth: int) -> bool {
	if depth > 32 {
		h.depth_hit = true
		return false
	}
	// The decoder reads an 8-byte window at a time, so the input is padded.
	pad := make([]u8, len(data) + 8, context.temp_allocator)
	copy(pad, data)

	bitsleft := len(data) * 8
	pos := 0
	x := hb64(pad, 0)
	n := 32
	good := true

	for {
		if n <= 0 {
			pos += 4
			if pos + 8 > len(pad) {
				break
			}
			x = hb64(pad, pos)
			n += 32
		}
		code := u32((x >> u64(n)) & 0xffffffff)
		idx := int(code >> 24)
		cl := int(h.codelen[idx])
		mx := h.dmax[idx]
		if !h.term[idx] {
			for cl <= 32 && u64(code) < h.mincode[cl] {
				cl += 1
			}
			if cl > 32 {
				good = false
				break
			}
			mx = h.maxcode[cl]
		}

		n -= cl
		bitsleft -= cl
		if bitsleft < 0 {
			break
		}

		r := int((mx - u64(code)) >> u64(32 - cl))
		if r < 0 || r >= len(h.ents) {
			good = false
			break
		}
		e := &h.ents[r]
		if !e.done {
			blen := hb16(e.raw, 0)
			ln := int(blen & 0x7fff)
			if 2 + ln > len(e.raw) {
				good = false
				break
			}
			slice := e.raw[2:2 + ln]
			if blen & 0x8000 != 0 {
				e.val = slice
				e.done = true
			} else {
				// The phrase is itself a bitstream.
				sub := make([dynamic]u8, 0, ln * 4)
				if !huff_decode(h, slice, &sub, depth + 1) {
					delete(sub)
					good = false
					break
				}
				e.val = sub[:]
				e.owned = true
				e.done = true
			}
		}
		append(out, ..e.val)
	}
	return good
}

// ---------------------------------------------------------------------------
// A hand-built HUFF/CDIC pair, for the selftest
//
// Writing a real compressor is out of scope, but a *minimal* encoder is not:
// with every symbol given the same code length, the canonical code is just the
// symbol index, and the two dispatch tables fall out of that in a few lines.
// That is enough to drive the decoder through its whole path — table lookup,
// the non-terminal fallback, phrase resolution and a nested bitstream.
// ---------------------------------------------------------------------------

Huff_Fixture :: struct {
	huff:  []u8,
	cdic:  []u8,
	// The encoded bitstream, and what it must decode to.
	bits:  []u8,
	want:  string,
}

// huff_encode writes a sequence of phrase indices as the bitstream the
// decoder reads: the code `m - i` for each index, `bits` wide, most
// significant bit first.
@(private = "file")
huff_encode :: proc(seq: []int, m: u32, bits: u8, allocator := context.allocator) -> []u8 {
	bs := make([dynamic]u8, 0, len(seq) + 8, context.temp_allocator)
	acc := u32(0)
	nb := u32(0)
	for idx in seq {
		code := m - u32(max(idx, 0))
		for k := int(bits) - 1; k >= 0; k -= 1 {
			acc = (acc << 1) | ((code >> u32(k)) & 1)
			nb += 1
			if nb == 8 {
				append(&bs, u8(acc))
				acc, nb = 0, 0
			}
		}
	}
	// A partial final byte is padded with zeros; the decoder's bit budget
	// stops it before those zeros can look like another symbol.
	if nb > 0 {
		acc <<= (8 - nb)
		append(&bs, u8(acc))
	}
	out := make([]u8, len(bs), allocator)
	copy(out, bs[:])
	return out
}

// huff_fixture builds a HUFF record, one CDIC record holding `phrases`, and a
// bitstream that selects them in `order`.
//
// The one thing to get right is which way the code-to-phrase mapping runs,
// because it is the opposite of the obvious guess. The decoder computes
//
//     r = (maxcode - code) >> (32 - codelen)
//
// and the loader stores maxcode as ((M + 1) << (32 - codelen)) - 1, so for a
// `codelen`-bit code C the dictionary index is
//
//     r = M - C
//
// The index *decreases* as the code increases. So with every code the same
// length and M set to the last phrase's index, phrase i is selected by the
// code M - i, and the encoder below emits exactly that.
// `nested` turns the *last* phrase into a bitstream of its own, selecting the
// indices it names, with the CDIC flag bit cleared. That is how a real
// HUFF/CDIC file encodes a phrase made of other phrases, and it is the one
// path in the decoder that recurses.
huff_fixture :: proc(
	phrases: []string,
	order: []int,
	nested: []int = nil,
	allocator := context.allocator,
) -> Huff_Fixture {
	// One code length wide enough for every phrase index.
	bits := u8(1)
	for (1 << uint(bits)) < len(phrases) {
		bits += 1
	}
	m := u32(len(phrases) - 1)

	// --- HUFF: dict1 at 0x18, dict2 immediately after.
	off1 := 0x18
	off2 := off1 + 256 * 4
	hr := make([dynamic]u8, 0, off2 + 64 * 4, context.temp_allocator)
	w32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}
	append(&hr, "HUFF")
	w32(&hr, 0x18) // header length
	w32(&hr, u32(off1))
	w32(&hr, u32(off2))
	for len(hr) < off1 {
		append(&hr, 0)
	}
	// Every entry says the same thing, because every code is the same length.
	// A code of eight bits or fewer is marked terminal, which is the common
	// path; a longer one is not, which sends the decoder through the second
	// table. Both are exercised by calling this with few or many phrases.
	for _ in 0 ..< 256 {
		v := (m << 8) | u32(bits)
		if bits <= 8 {
			v |= 0x80
		}
		w32(&hr, v)
	}
	for i in 0 ..< 32 {
		if i == int(bits) {
			w32(&hr, 0) // mincode: codes start at zero
			w32(&hr, m) // maxcode
		} else {
			w32(&hr, 0xffffffff)
			w32(&hr, 0)
		}
	}

	// --- CDIC: a phrase count, an index width, then offsets and phrases.
	cd := make([dynamic]u8, 0, 256, context.temp_allocator)
	append(&cd, "CDIC")
	w32(&cd, 0x10) // header length
	w32(&cd, u32(len(phrases)))
	w32(&cd, u32(bits))
	tbl := len(cd)
	for _ in phrases {
		append(&cd, 0, 0)
	}
	for ph, i in phrases {
		off := len(cd) - 16
		cd[tbl + 2 * i] = u8(off >> 8)
		cd[tbl + 2 * i + 1] = u8(off)
		body := transmute([]u8)ph
		flag := u16(0x8000) // the top bit means plain text
		if len(nested) > 0 && i == len(phrases) - 1 {
			body = huff_encode(nested, m, bits, context.temp_allocator)
			flag = 0 // not text: another bitstream
		}
		blen := u16(len(body)) | flag
		append(&cd, u8(blen >> 8), u8(blen))
		append(&cd, ..body)
	}

	// --- the bitstream, and what it must decode to.
	bs := huff_encode(order, m, bits, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	for idx in order {
		if idx < 0 || idx >= len(phrases) {
			continue
		}
		if len(nested) > 0 && idx == len(phrases) - 1 {
			for k in nested {
				if k >= 0 && k < len(phrases) {
					strings.write_string(&sb, phrases[k])
				}
			}
			continue
		}
		strings.write_string(&sb, phrases[idx])
	}

	out := Huff_Fixture{}
	out.huff = make([]u8, len(hr), allocator);copy(out.huff, hr[:])
	out.cdic = make([]u8, len(cd), allocator);copy(out.cdic, cd[:])
	out.bits = make([]u8, len(bs), allocator);copy(out.bits, bs[:])
	out.want = strings.clone(strings.to_string(sb), allocator)
	return out
}

huff_fixture_destroy :: proc(f: ^Huff_Fixture) {
	delete(f.huff)
	delete(f.cdic)
	delete(f.bits)
	delete(f.want)
	f^ = {}
}
