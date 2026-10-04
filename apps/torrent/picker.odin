package main

// Which piece next, and which block of it.
//
// RAREST FIRST
//
// The piece to ask for is the one the fewest connected peers have. It is not an
// optimisation for the downloader — a random choice downloads at the same speed
// — it is what keeps the swarm alive: it pushes the rarest piece towards two
// copies before the common ones reach twenty, so the swarm survives the seed
// leaving. A client that downloads in order is the reason a torrent dies with
// everybody at 97%.
//
// `picker_order` is a pure function of (availability, what we have, what the
// peer has), which is why it can be asserted exactly in the selftest rather
// than observed to "look about right".
//
// ENDGAME
//
// Near the end, the last few blocks are all outstanding at one slow peer and
// the download stalls at 99.9% waiting for it. Endgame mode requests the
// remaining blocks from every peer at once and cancels the duplicates as they
// land. It wastes a little bandwidth and it is the difference between finishing
// and not.

import "core:slice"

// How many requests to keep outstanding per peer. One in flight means the
// download rate is capped at block size over round-trip time; a deeper pipe
// keeps the peer's send buffer busy. Real clients adapt this to the measured
// rate; this one keeps it fixed and generous, which on loopback is plenty.
PIPELINE_DEPTH :: 24

// Endgame starts when this many pieces or fewer are left to get.
ENDGAME_PIECES :: 4

// A block requested longer ago than this is considered lost and may be asked
// for again.
REQUEST_TIMEOUT :: 20.0

Block_State :: enum u8 {
	Missing,
	Requested,
	Have,
}

// Active_Piece is a piece being assembled in memory. It is only written to disk
// once every block is present and the SHA-1 matches.
Active_Piece :: struct {
	index:  int,
	buf:    []u8,
	blocks: []Block_State,
	asked:  []f64, // when each block was last requested, for the timeout
	got:    int, // blocks in hand
}

Picker :: struct {
	m:       ^Metainfo,
	avail:   []int, // connected peers holding each piece
	active:  [dynamic]Active_Piece,
	endgame: bool,
}

picker_init :: proc(pk: ^Picker, m: ^Metainfo) {
	pk.m = m
	pk.avail = make([]int, piece_count(m))
	pk.active = make([dynamic]Active_Piece, 0, 8)
}

picker_destroy :: proc(pk: ^Picker) {
	delete(pk.avail)
	for &a in pk.active {
		delete(a.buf)
		delete(a.blocks)
		delete(a.asked)
	}
	delete(pk.active)
	pk^ = {}
}

// ---------------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------------

picker_add_bitfield :: proc(pk: ^Picker, b: Bitfield) {
	for i in 0 ..< min(b.n, len(pk.avail)) {
		if bf_get(b, i) {
			pk.avail[i] += 1
		}
	}
}

picker_remove_bitfield :: proc(pk: ^Picker, b: Bitfield) {
	for i in 0 ..< min(b.n, len(pk.avail)) {
		if bf_get(b, i) && pk.avail[i] > 0 {
			pk.avail[i] -= 1
		}
	}
}

picker_add_have :: proc(pk: ^Picker, index: int) {
	if index >= 0 && index < len(pk.avail) {
		pk.avail[index] += 1
	}
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

// picker_order returns the pieces worth asking this peer for, rarest first,
// ties broken by index so the result is deterministic and assertable.
//
// A piece is a candidate when we do not have it, the peer does, and at least
// one peer has it (which the peer having it guarantees, but availability can
// lag a disconnect, so it is checked).
picker_order :: proc(
	avail: []int,
	have: Bitfield,
	peer_has: Bitfield,
	allocator := context.temp_allocator,
) -> []int {
	Cand :: struct {
		index: int,
		av:    int,
	}
	cands := make([dynamic]Cand, 0, len(avail), context.temp_allocator)
	for i in 0 ..< len(avail) {
		if bf_get(have, i) {
			continue
		}
		if !bf_get(peer_has, i) {
			continue
		}
		if avail[i] <= 0 {
			continue
		}
		append(&cands, Cand{index = i, av = avail[i]})
	}
	// `sort_by` is not stable, so the index is part of the comparison rather
	// than relied on as an incidental order.
	slice.sort_by(cands[:], proc(a, b: Cand) -> bool {
		if a.av != b.av {
			return a.av < b.av
		}
		return a.index < b.index
	})
	out := make([]int, len(cands), allocator)
	for c, i in cands {
		out[i] = c.index
	}
	return out
}

// ---------------------------------------------------------------------------
// Active pieces
// ---------------------------------------------------------------------------

picker_find :: proc(pk: ^Picker, index: int) -> ^Active_Piece {
	for &a in pk.active {
		if a.index == index {
			return &a
		}
	}
	return nil
}

picker_begin :: proc(pk: ^Picker, index: int) -> ^Active_Piece {
	if a := picker_find(pk, index); a != nil {
		return a
	}
	nb := blocks_in_piece(pk.m, index)
	append(
		&pk.active,
		Active_Piece {
			index = index,
			buf = make([]u8, int(piece_size(pk.m, index))),
			blocks = make([]Block_State, nb),
			asked = make([]f64, nb),
		},
	)
	return &pk.active[len(pk.active) - 1]
}

picker_drop :: proc(pk: ^Picker, index: int) {
	for i in 0 ..< len(pk.active) {
		if pk.active[i].index != index {
			continue
		}
		delete(pk.active[i].buf)
		delete(pk.active[i].blocks)
		delete(pk.active[i].asked)
		unordered_remove(&pk.active, i)
		return
	}
}

// picker_release_requests marks a peer's outstanding blocks as missing again,
// which is what has to happen when that peer disconnects or chokes us.
picker_release_timed_out :: proc(pk: ^Picker, now: f64) {
	for &a in pk.active {
		for i in 0 ..< len(a.blocks) {
			if a.blocks[i] == .Requested && now - a.asked[i] > REQUEST_TIMEOUT {
				a.blocks[i] = .Missing
			}
		}
	}
}

picker_mark_requested :: proc(a: ^Active_Piece, block: int, now: f64) {
	if block >= 0 && block < len(a.blocks) && a.blocks[block] != .Have {
		a.blocks[block] = .Requested
		a.asked[block] = now
	}
}

// picker_store_block copies a received block into the piece buffer. It returns
// whether the block was new, and whether the piece is now complete.
picker_store_block :: proc(
	pk: ^Picker,
	a: ^Active_Piece,
	begin: int,
	data: []u8,
) -> (
	fresh: bool,
	complete: bool,
	err: string,
) {
	if begin % BLOCK_SIZE != 0 {
		return false, false, tsprint("a block at offset %d is not block-aligned", begin)
	}
	bi := begin / BLOCK_SIZE
	if bi < 0 || bi >= len(a.blocks) {
		return false, false, tsprint("a block at offset %d is outside piece %d", begin, a.index)
	}
	want := block_size_at(pk.m, a.index, bi)
	if len(data) != want {
		return false, false, tsprint(
			"block %d of piece %d arrived as %d bytes, expected %d",
			bi,
			a.index,
			len(data),
			want,
		)
	}
	if a.blocks[bi] == .Have {
		// A duplicate, which endgame mode makes normal rather than an error.
		return false, a.got == len(a.blocks), ""
	}
	copy(a.buf[begin:begin + len(data)], data)
	a.blocks[bi] = .Have
	a.got += 1
	return true, a.got == len(a.blocks), ""
}

// picker_next_block finds a block of `a` to request. In endgame it will hand
// out a block that is already outstanding elsewhere; otherwise it will not.
picker_next_block :: proc(pk: ^Picker, a: ^Active_Piece, endgame: bool) -> (block: int, ok: bool) {
	for i in 0 ..< len(a.blocks) {
		switch a.blocks[i] {
		case .Missing:
			return i, true
		case .Requested:
			if endgame {
				return i, true
			}
		case .Have:
		}
	}
	return 0, false
}

picker_pieces_left :: proc(pk: ^Picker, have: Bitfield) -> int {
	return have.n - bf_count(have)
}

// picker_update_endgame turns endgame on near the finish and off again if a
// recheck or a new file priority puts more work back on the list.
picker_update_endgame :: proc(pk: ^Picker, have: Bitfield) {
	left := picker_pieces_left(pk, have)
	pk.endgame = left > 0 && left <= ENDGAME_PIECES
}
