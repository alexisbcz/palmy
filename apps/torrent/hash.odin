package main

// SHA-1, which BitTorrent uses for the info-hash and for every piece.
//
// The implementation is `core:crypto/legacy/sha1` — Odin's standard library,
// pure Odin, no linkage. The wrapper exists so that the rest of the program
// speaks in `[20]u8` rather than in slices, and so there is one place to check
// the FIPS 180-1 known-answer vectors (`selftest.odin`, section "sha1"). A
// hash function that is wired up wrong fails silently: every piece verifies
// against the same wrong value, and the only symptom is that no real client
// will ever talk to you.

import "core:crypto/legacy/sha1"

Hash20 :: [20]u8

sha1_of :: proc(data: []u8) -> Hash20 {
	out: Hash20
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, data)
	sha1.final(&ctx, out[:])
	return out
}

// Sha1_Stream hashes a piece that is read in several chunks, which is what a
// piece spanning three files needs.
Sha1_Stream :: struct {
	ctx: sha1.Context,
}

sha1_begin :: proc(s: ^Sha1_Stream) {
	sha1.init(&s.ctx)
}

sha1_feed :: proc(s: ^Sha1_Stream, data: []u8) {
	sha1.update(&s.ctx, data)
}

sha1_end :: proc(s: ^Sha1_Stream) -> Hash20 {
	out: Hash20
	sha1.final(&s.ctx, out[:])
	return out
}

hash20_hex :: proc(h: Hash20, allocator := context.allocator) -> string {
	v := h
	return hex_encode(v[:], allocator)
}

hash20_from_hex :: proc(s: string) -> (h: Hash20, ok: bool) {
	b, good := hex_decode(s, context.temp_allocator)
	if !good || len(b) != 20 {
		return {}, false
	}
	copy(h[:], b)
	return h, true
}

hash20_eq :: proc(a, b: Hash20) -> bool {
	for i in 0 ..< 20 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
