package palm

// DEFLATE compression, and the gzip framing around it.
//
// core:compress can read gzip but not write it, and a package manager that
// builds its own packages has to write it. This is the encoder: LZ77 over a
// 32 KiB window with hash chains and one step of lazy matching (zlib's
// "deflate_slow" shape), followed by dynamic Huffman blocks with
// length-limited codes. Each block is costed against a stored block and the
// smaller is written, so a package full of already-compressed fonts or PNGs
// grows by a few bytes per 64 KiB rather than by a Huffman table's worth.
//
// It is RFC 1951 and 1952 and nothing more: no dictionary, no flush points, a
// fixed effort level. The selftest checks every output against both Odin's
// own decoder and the system's `gzip -d`, which is the test that matters --
// a compressor is only correct relative to the decoders that read it.
//
// Decompression is core:compress/gzip, wrapped in gzip_decompress below.

import "core:bytes"
import "core:compress/gzip"
import "core:hash"
import "core:slice"

@(private = "file")
WSIZE :: 1 << 15
@(private = "file")
WMASK :: WSIZE - 1
@(private = "file")
HASH_BITS :: 15
@(private = "file")
MIN_MATCH :: 3
@(private = "file")
MAX_MATCH :: 258
@(private = "file")
MAX_CHAIN :: 96 // candidates tried per position; the speed/size dial
@(private = "file")
NICE_MATCH :: 160 // stop searching once a match is this long
@(private = "file")
MAX_LAZY :: 32 // do not look for a better match after one this long
@(private = "file")
BLOCK_TOKENS :: 1 << 15

@(private = "file")
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
// The order code-length code lengths are transmitted in (RFC 1951 3.2.7).
@(private = "file")
CL_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// A token is a literal byte (dist == 0) or a back-reference.
@(private = "file")
Token :: struct {
	len:  u16, // the literal byte when dist == 0
	dist: u16,
}

@(private = "file")
Bit_Writer :: struct {
	out: [dynamic]byte,
	acc: u64,
	n:   uint,
}

@(private = "file")
put_bits :: #force_inline proc(w: ^Bit_Writer, bits: u32, count: uint) {
	w.acc |= u64(bits) << w.n
	w.n += count
	for w.n >= 8 {
		append(&w.out, byte(w.acc))
		w.acc >>= 8
		w.n -= 8
	}
}

@(private = "file")
align_byte :: proc(w: ^Bit_Writer) {
	if w.n > 0 {
		append(&w.out, byte(w.acc))
	}
	w.acc = 0
	w.n = 0
}

// Code tables, built once: length (3..258) to length code, distance
// (1..32768) to distance code.
@(private = "file")
len_code_table: [MAX_MATCH + 1]u8
@(private = "file")
dist_code_table: [WSIZE + 1]u8
@(private = "file")
tables_ready := false

@(private = "file")
init_tables :: proc() {
	if tables_ready {
		return
	}
	for c in 0 ..< 29 {
		lo := int(LEN_BASE[c])
		hi := c == 28 ? 258 : int(LEN_BASE[c]) + (1 << LEN_EXTRA[c]) - 1
		for l in lo ..= hi {
			len_code_table[l] = u8(c)
		}
	}
	// 258 is its own code even though code 27 would also span it.
	len_code_table[258] = 28
	for c in 0 ..< 30 {
		lo := int(DIST_BASE[c])
		hi := lo + (1 << DIST_EXTRA[c]) - 1
		for d in lo ..= min(hi, WSIZE) {
			dist_code_table[d] = u8(c)
		}
	}
	tables_ready = true
}

// deflate compresses data into a raw RFC 1951 stream.
deflate :: proc(data: []byte, allocator := context.allocator) -> []byte {
	init_tables()
	w := Bit_Writer{out = make([dynamic]byte, 0, len(data) / 2 + 64, allocator)}

	n := len(data)
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator) // pos+1, 0 = empty
	prev := make([]i32, WSIZE, context.temp_allocator)
	tokens := make([dynamic]Token, 0, BLOCK_TOKENS, context.temp_allocator)

	block_start := 0 // first input byte the pending tokens cover
	covered := 0 // one past the last input byte the pending tokens cover

	insert :: #force_inline proc(data: []byte, head, prev: []i32, pos: int) {
		if pos + 2 >= len(data) {
			return
		}
		v := u32(data[pos]) | u32(data[pos + 1]) << 8 | u32(data[pos + 2]) << 16
		h := (v * 2654435761) >> (32 - HASH_BITS)
		prev[pos & WMASK] = head[h]
		head[h] = i32(pos + 1)
	}

	// longest_match finds a match at pos longer than `better_than`. The chain
	// starts at prev[pos] because pos itself has just been inserted.
	longest_match :: proc(data: []byte, prev: []i32, pos, better_than: int) -> (int, int) {
		limit := min(MAX_MATCH, len(data) - pos)
		best := max(better_than, MIN_MATCH - 1)
		if limit <= best {
			return MIN_MATCH - 1, 0
		}
		best_dist := 0
		chain := MAX_CHAIN
		if better_than >= 16 {
			chain >>= 2
		}
		cand := int(prev[pos & WMASK]) - 1
		for cand >= 0 && pos - cand <= WSIZE && chain > 0 {
			chain -= 1
			if data[cand + best] == data[pos + best] && data[cand] == data[pos] {
				l := 0
				for l < limit && data[cand + l] == data[pos + l] {
					l += 1
				}
				if l > best {
					best = l
					best_dist = pos - cand
					if l >= limit || l >= NICE_MATCH {
						break
					}
				}
			}
			next := int(prev[cand & WMASK]) - 1
			if next >= cand {
				break // the slot was reused by a newer position
			}
			cand = next
		}
		if best_dist == 0 {
			return MIN_MATCH - 1, 0
		}
		return best, best_dist
	}

	flush :: proc(w: ^Bit_Writer, tokens: ^[dynamic]Token, raw: []byte, final: bool) {
		write_block(w, tokens[:], raw, final)
		clear(tokens)
	}

	i := 0
	match_available := false
	prev_len := MIN_MATCH - 1
	prev_dist := 0
	for i < n {
		insert(data, head, prev, i)
		cur_len, cur_dist := MIN_MATCH - 1, 0
		if prev_len < MAX_LAZY {
			cur_len, cur_dist = longest_match(data, prev, i, prev_len)
		}
		if prev_len >= MIN_MATCH && cur_len <= prev_len {
			// The match found at i-1 is at least as good as anything at i.
			append(&tokens, Token{u16(prev_len), u16(prev_dist)})
			end := i - 1 + prev_len
			for p := i + 1; p < end; p += 1 {
				insert(data, head, prev, p)
			}
			covered = end
			i = end
			match_available = false
			prev_len = MIN_MATCH - 1
		} else if match_available {
			append(&tokens, Token{u16(data[i - 1]), 0})
			covered = i
			prev_len, prev_dist = cur_len, cur_dist
			i += 1
		} else {
			match_available = true
			prev_len, prev_dist = cur_len, cur_dist
			i += 1
		}
		if len(tokens) >= BLOCK_TOKENS {
			flush(&w, &tokens, data[block_start:covered], false)
			block_start = covered
		}
	}
	if match_available {
		append(&tokens, Token{u16(data[n - 1]), 0})
		covered = n
	}
	flush(&w, &tokens, data[block_start:covered], true)
	align_byte(&w)
	return w.out[:]
}

// write_block emits one block, dynamic Huffman or stored, whichever is
// smaller.
@(private = "file")
write_block :: proc(w: ^Bit_Writer, tokens: []Token, raw: []byte, final: bool) {
	lit_freq: [286]u32
	dist_freq: [30]u32
	for t in tokens {
		if t.dist == 0 {
			lit_freq[t.len] += 1
		} else {
			lit_freq[257 + int(len_code_table[t.len])] += 1
			dist_freq[dist_code_table[t.dist]] += 1
		}
	}
	lit_freq[256] = 1
	// Two used symbols per tree at least, so every code is complete: some
	// decoders refuse an incomplete code, and an unused code costs a bit.
	ensure_two(lit_freq[:])
	ensure_two(dist_freq[:])

	lit_len: [286]u8
	dist_len: [30]u8
	build_lengths(lit_freq[:], 15, lit_len[:])
	build_lengths(dist_freq[:], 15, dist_len[:])

	hlit := 286
	for hlit > 257 && lit_len[hlit - 1] == 0 {
		hlit -= 1
	}
	hdist := 30
	for hdist > 1 && dist_len[hdist - 1] == 0 {
		hdist -= 1
	}

	// Run-length encode the concatenated code lengths (RFC 1951 3.2.7).
	all := make([dynamic]u8, 0, hlit + hdist, context.temp_allocator)
	append(&all, ..lit_len[:hlit])
	append(&all, ..dist_len[:hdist])
	Cl :: struct {
		sym:   u8,
		extra: u8,
	}
	cls := make([dynamic]Cl, 0, len(all), context.temp_allocator)
	for k := 0; k < len(all); {
		v := all[k]
		run := 1
		for k + run < len(all) && all[k + run] == v {
			run += 1
		}
		k += run
		if v == 0 {
			for run >= 11 {
				r := min(run, 138)
				append(&cls, Cl{18, u8(r - 11)})
				run -= r
			}
			if run >= 3 {
				append(&cls, Cl{17, u8(run - 3)})
				run = 0
			}
		} else {
			append(&cls, Cl{v, 0})
			run -= 1
			for run >= 3 {
				r := min(run, 6)
				append(&cls, Cl{16, u8(r - 3)})
				run -= r
			}
		}
		for _ in 0 ..< run {
			append(&cls, Cl{v, 0})
		}
	}
	cl_freq: [19]u32
	for c in cls {
		cl_freq[c.sym] += 1
	}
	ensure_two(cl_freq[:])
	cl_len: [19]u8
	build_lengths(cl_freq[:], 7, cl_len[:])
	hclen := 19
	for hclen > 4 && cl_len[CL_ORDER[hclen - 1]] == 0 {
		hclen -= 1
	}

	// Cost both ways, in bits.
	dyn_bits := 3 + 5 + 5 + 4 + 3 * hclen
	for c in cls {
		dyn_bits += int(cl_len[c.sym])
		switch c.sym {
		case 16:
			dyn_bits += 2
		case 17:
			dyn_bits += 3
		case 18:
			dyn_bits += 7
		}
	}
	for sym in 0 ..< 286 {
		dyn_bits += int(lit_freq[sym]) * int(lit_len[sym])
		if sym >= 257 {
			dyn_bits += int(lit_freq[sym]) * int(LEN_EXTRA[sym - 257])
		}
	}
	for sym in 0 ..< 30 {
		dyn_bits += int(dist_freq[sym]) * (int(dist_len[sym]) + int(DIST_EXTRA[sym]))
	}
	chunks := max(1, (len(raw) + 65534) / 65535)
	stored_bits := len(raw) * 8 + chunks * (5 * 8 + 7)

	if stored_bits < dyn_bits {
		write_stored(w, raw, final)
		return
	}

	lit_code: [286]u16
	dist_code: [30]u16
	cl_code: [19]u16
	canonical_codes(lit_len[:], lit_code[:])
	canonical_codes(dist_len[:], dist_code[:])
	canonical_codes(cl_len[:], cl_code[:])

	put_bits(w, final ? 1 : 0, 1)
	put_bits(w, 2, 2) // dynamic Huffman
	put_bits(w, u32(hlit - 257), 5)
	put_bits(w, u32(hdist - 1), 5)
	put_bits(w, u32(hclen - 4), 4)
	for k in 0 ..< hclen {
		put_bits(w, u32(cl_len[CL_ORDER[k]]), 3)
	}
	for c in cls {
		put_bits(w, u32(cl_code[c.sym]), uint(cl_len[c.sym]))
		switch c.sym {
		case 16:
			put_bits(w, u32(c.extra), 2)
		case 17:
			put_bits(w, u32(c.extra), 3)
		case 18:
			put_bits(w, u32(c.extra), 7)
		}
	}
	for t in tokens {
		if t.dist == 0 {
			put_bits(w, u32(lit_code[t.len]), uint(lit_len[t.len]))
			continue
		}
		lc := int(len_code_table[t.len])
		put_bits(w, u32(lit_code[257 + lc]), uint(lit_len[257 + lc]))
		if LEN_EXTRA[lc] > 0 {
			put_bits(w, u32(t.len - LEN_BASE[lc]), uint(LEN_EXTRA[lc]))
		}
		dc := int(dist_code_table[t.dist])
		put_bits(w, u32(dist_code[dc]), uint(dist_len[dc]))
		if DIST_EXTRA[dc] > 0 {
			put_bits(w, u32(t.dist - DIST_BASE[dc]), uint(DIST_EXTRA[dc]))
		}
	}
	put_bits(w, u32(lit_code[256]), uint(lit_len[256]))
}

@(private = "file")
write_stored :: proc(w: ^Bit_Writer, raw: []byte, final: bool) {
	rest := raw
	for {
		chunk := rest[:min(len(rest), 65535)]
		rest = rest[len(chunk):]
		last := len(rest) == 0
		put_bits(w, (final && last) ? 1 : 0, 1)
		put_bits(w, 0, 2)
		align_byte(w)
		l := u16(len(chunk))
		append(&w.out, byte(l), byte(l >> 8), byte(~l), byte(~l >> 8))
		append(&w.out, ..chunk)
		if last {
			break
		}
	}
}

@(private = "file")
ensure_two :: proc(freq: []u32) {
	used := 0
	for f in freq {
		if f > 0 {
			used += 1
		}
	}
	for k := 0; used < 2 && k < len(freq); k += 1 {
		if freq[k] == 0 {
			freq[k] = 1
			used += 1
		}
	}
}

// build_lengths computes Huffman code lengths no longer than max_bits.
//
// A plain Huffman tree is built over the used symbols (the two-queue method on
// leaves sorted by frequency), then only its per-depth histogram is kept. The
// histogram is squeezed under max_bits the way miniz does it -- fold every
// over-long code into the limit, then repair the Kraft sum by splitting
// shorter codes -- and lengths are handed back out in frequency order, the
// most frequent symbols taking the shortest codes.
@(private = "file")
build_lengths :: proc(freq: []u32, max_bits: int, lens: []u8) {
	for &l in lens {
		l = 0
	}
	syms := make([dynamic]int, 0, len(freq), context.temp_allocator)
	for f, s in freq {
		if f > 0 {
			append(&syms, s)
		}
	}
	m := len(syms)
	if m == 0 {
		return
	}
	if m == 1 {
		lens[syms[0]] = 1
		return
	}
	// Odin comparators capture nothing, so sort (frequency, symbol) pairs.
	Pair :: struct {
		f: u32,
		s: int,
	}
	pairs := make([]Pair, m, context.temp_allocator)
	for s, k in syms {
		pairs[k] = Pair{freq[s], s}
	}
	slice.sort_by(pairs, proc(a, b: Pair) -> bool {
		if a.f != b.f {
			return a.f < b.f
		}
		return a.s < b.s
	})

	weight := make([]u64, 2 * m - 1, context.temp_allocator)
	parent := make([]int, 2 * m - 1, context.temp_allocator)
	for p, k in pairs {
		weight[k] = u64(p.f)
	}
	leaf, inner, next := 0, m, m
	pick :: proc(weight: []u64, leaf, inner: ^int, m, next: int) -> int {
		if leaf^ < m && (inner^ >= next || weight[leaf^] <= weight[inner^]) {
			leaf^ += 1
			return leaf^ - 1
		}
		inner^ += 1
		return inner^ - 1
	}
	for next < 2 * m - 1 {
		a := pick(weight, &leaf, &inner, m, next)
		b := pick(weight, &leaf, &inner, m, next)
		weight[next] = weight[a] + weight[b]
		parent[a] = next
		parent[b] = next
		next += 1
	}
	depth := make([]int, 2 * m - 1, context.temp_allocator)
	depth[2 * m - 2] = 0
	for k := 2 * m - 3; k >= 0; k -= 1 {
		depth[k] = depth[parent[k]] + 1
	}

	count: [64]int
	for k in 0 ..< m {
		count[min(depth[k], 63)] += 1
	}
	for d in max_bits + 1 ..< 64 {
		count[max_bits] += count[d]
		count[d] = 0
	}
	total: u64 = 0
	for d := max_bits; d > 0; d -= 1 {
		total += u64(count[d]) << uint(max_bits - d)
	}
	for total != 1 << uint(max_bits) {
		count[max_bits] -= 1
		for d := max_bits - 1; d > 0; d -= 1 {
			if count[d] > 0 {
				count[d] -= 1
				count[d + 1] += 2
				break
			}
		}
		total -= 1
	}

	j := m
	for d in 1 ..= max_bits {
		for _ in 0 ..< count[d] {
			j -= 1
			lens[pairs[j].s] = u8(d)
		}
	}
}

// canonical_codes assigns RFC 1951 canonical codes, bit-reversed because the
// stream is written least significant bit first.
@(private = "file")
canonical_codes :: proc(lens: []u8, codes: []u16) {
	bl_count: [16]u16
	for l in lens {
		bl_count[l] += 1
	}
	bl_count[0] = 0
	next_code: [16]u16
	code: u16 = 0
	for bits in 1 ..< 16 {
		code = (code + bl_count[bits - 1]) << 1
		next_code[bits] = code
	}
	for l, s in lens {
		if l == 0 {
			codes[s] = 0
			continue
		}
		c := next_code[l]
		next_code[l] += 1
		r: u16 = 0
		for _ in 0 ..< l {
			r = r << 1 | (c & 1)
			c >>= 1
		}
		codes[s] = r
	}
}

// gzip_compress wraps a deflate stream in an RFC 1952 member. The header has
// no name and a zero timestamp, so the same input always gives the same
// bytes -- a package's sha256 depends only on what is in it.
gzip_compress :: proc(data: []byte, allocator := context.allocator) -> []byte {
	body := deflate(data, context.temp_allocator)
	out := make([dynamic]byte, 0, len(body) + 18, allocator)
	append(&out, 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3)
	append(&out, ..body)
	crc := hash.crc32(data)
	size := u32(len(data))
	append(&out, byte(crc), byte(crc >> 8), byte(crc >> 16), byte(crc >> 24))
	append(&out, byte(size), byte(size >> 8), byte(size >> 16), byte(size >> 24))
	return out[:]
}

gzip_decompress :: proc(data: []byte, allocator := context.allocator) -> ([]byte, bool) {
	// Checked here rather than left to core:compress/gzip, which indexes
	// the trailer before checking the input is long enough to have one. The
	// sizes are not passed on either: ISIZE is a claim made by the file, and
	// a file should not get to choose how much palm allocates up front.
	if len(data) < 18 || data[0] != 0x1f || data[1] != 0x8b || data[2] != 8 {
		return nil, false
	}
	n := len(data)
	isize := int(u32(data[n - 4]) | u32(data[n - 3]) << 8 | u32(data[n - 2]) << 16 | u32(data[n - 1]) << 24)
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, clamp(isize, 4096, 64 << 20), allocator)
	if err := gzip.load_from_bytes(data, &buf, -1, -1, allocator); err != nil {
		bytes.buffer_destroy(&buf)
		return nil, false
	}
	out := bytes.buffer_to_bytes(&buf)
	if len(out) & 0xffff_ffff != isize {
		delete(out, allocator)
		return nil, false
	}
	return out, true
}
