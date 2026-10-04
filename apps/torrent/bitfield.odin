package main

// A bitfield over pieces.
//
// The wire format is big-endian within each byte: piece 0 is the HIGH bit of
// byte 0, not the low one. Getting that backwards produces a bitfield that
// looks plausible, downloads the wrong pieces, and fails every hash check.
//
// The final byte's spare bits — the ones past the last piece — MUST be zero.
// BEP 3 says a peer sending a bitfield with spare bits set should be dropped,
// and the reason is practical: those bits would otherwise claim pieces that do
// not exist, and a picker that trusted them would request past the end of the
// torrent.

Bitfield :: struct {
	bits: []u8,
	n:    int, // number of pieces; len(bits) == (n + 7) / 8
}

bf_bytes :: proc(n: int) -> int {
	return (n + 7) / 8
}

bf_make :: proc(n: int, allocator := context.allocator) -> Bitfield {
	return Bitfield{bits = make([]u8, bf_bytes(n), allocator), n = n}
}

// bf_destroy frees with the allocator the bitfield was made with. Getting this
// wrong is a free of arena memory by the heap allocator, which segfaults in
// libc rather than anywhere near the mistake.
bf_destroy :: proc(b: ^Bitfield, allocator := context.allocator) {
	delete(b.bits, allocator)
	b^ = {}
}

bf_clone :: proc(b: Bitfield, allocator := context.allocator) -> Bitfield {
	out := bf_make(b.n, allocator)
	copy(out.bits, b.bits)
	return out
}

// bf_from_wire adopts bytes received from a peer. It returns false when the
// length is wrong or a spare bit is set, which is a protocol violation.
bf_from_wire :: proc(
	data: []u8,
	n: int,
	allocator := context.allocator,
) -> (
	b: Bitfield,
	ok: bool,
) {
	if len(data) != bf_bytes(n) {
		return {}, false
	}
	out := bf_make(n, allocator)
	copy(out.bits, data)
	if !bf_spare_bits_clear(out) {
		bf_destroy(&out, allocator)
		return {}, false
	}
	return out, true
}

bf_get :: proc(b: Bitfield, i: int) -> bool {
	if i < 0 || i >= b.n {
		return false
	}
	return b.bits[i / 8] & (0x80 >> uint(i % 8)) != 0
}

bf_set :: proc(b: ^Bitfield, i: int, on := true) {
	if i < 0 || i >= b.n {
		return
	}
	mask := u8(0x80) >> uint(i % 8)
	if on {
		b.bits[i / 8] |= mask
	} else {
		b.bits[i / 8] &= ~mask
	}
}

bf_count :: proc(b: Bitfield) -> int {
	total := 0
	for v in b.bits {
		x := v
		for x != 0 {
			total += int(x & 1)
			x >>= 1
		}
	}
	return total
}

bf_complete :: proc(b: Bitfield) -> bool {
	return b.n > 0 && bf_count(b) == b.n
}

bf_empty :: proc(b: Bitfield) -> bool {
	for v in b.bits {
		if v != 0 {
			return false
		}
	}
	return true
}

bf_fill :: proc(b: ^Bitfield) {
	for i in 0 ..< len(b.bits) {
		b.bits[i] = 0xff
	}
	bf_clear_spare(b)
}

// bf_spare_bits_clear checks the rule: every bit past piece n-1 in the last
// byte must be zero.
bf_spare_bits_clear :: proc(b: Bitfield) -> bool {
	if len(b.bits) == 0 {
		return b.n == 0
	}
	spare := len(b.bits) * 8 - b.n
	if spare == 0 {
		return true
	}
	mask := u8(0xff) >> uint(8 - spare) // the low `spare` bits
	return b.bits[len(b.bits) - 1] & mask == 0
}

bf_clear_spare :: proc(b: ^Bitfield) {
	if len(b.bits) == 0 {
		return
	}
	spare := len(b.bits) * 8 - b.n
	if spare == 0 {
		return
	}
	mask := u8(0xff) >> uint(8 - spare)
	b.bits[len(b.bits) - 1] &= ~mask
}

// bf_first_missing is used by the resume check's progress reporting.
bf_first_missing :: proc(b: Bitfield) -> int {
	for i in 0 ..< b.n {
		if !bf_get(b, i) {
			return i
		}
	}
	return -1
}
