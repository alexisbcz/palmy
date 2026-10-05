package main

// The extension protocol (BEP 10) and metadata exchange (BEP 9).
//
// WHY THIS IS NOT THE THING THAT WAS FORBIDDEN
//
// The note that used to sit on `handshake_encode` said the extension bit was
// left clear "because a peer that believes we speak them would send us
// addresses we are not allowed to use". That conflated two different things,
// and the conflation cost this client the ability to resolve a magnet at all:
//
//   * BEP 10 is a multiplexing layer. It says nothing about addresses. What it
//     carries is decided entirely by the `m` dictionary each side sends: an
//     extension the other end did not register cannot be addressed, because
//     there is no id for it.
//   * `ut_pex` (peer exchange) and the DHT are the two ways to learn an
//     address from a stranger, and they are the two things the safety rule is
//     about. Neither is here.
//
// So this client now advertises BEP 10 and registers exactly one extension:
//
//     m = { "ut_metadata": 2 }
//
// `ut_pex` is never registered, which means a conforming peer has no id to
// send PEX on. A non-conforming one that sends an extended message with an id
// this client never handed out is dropped by `ext_known_id`. And in the case
// where both of those failed, an address learned that way would still die in
// `sock_connect`, which is the only place a connection can happen and refuses
// anything outside 127.0.0.0/8. Three layers, the last of which is the one
// that actually has to hold.
//
// The DHT bit — bit 0 of reserved[7] — stays clear, and the only bit this
// client sets is bit 0x10 of reserved[5].
//
// THE WIRE
//
// An extended message is an ordinary peer-wire message with id 20. Its payload
// is one byte of *extended* message id followed by that extension's own bytes:
//
//     <len><20><ext_id><payload>
//
// `ext_id` 0 is the extension handshake, in both directions. Its payload is a
// bencoded dictionary:
//
//     d1:md11:ut_metadatai2ee13:metadata_sizei20480e1:v12:palmy 1.0.0e
//
// `m` maps an extension name to the id THIS side wants messages for that
// extension to arrive on. The ids are not symmetric: when we send ut_metadata
// to a peer we use the id *the peer* put in its `m`, not ours. Getting that
// backwards is the classic BEP 10 bug, and it is silent — the peer simply
// ignores a message on an id it never registered.
//
// `metadata_size` is the length in bytes of the bencoded `info` dictionary,
// which is exactly the byte range the info-hash is taken over. BEP 9 then
// moves it in 16 KiB pieces:
//
//     request  d8:msg_typei0e5:piecei0ee
//     data     d8:msg_typei1e5:piecei0e10:total_sizei20480ee<raw bytes>
//     reject   d8:msg_typei2e5:piecei0ee
//
// The raw bytes follow the bencoded dictionary with nothing between them, so
// the decoder has to parse a *prefix* and keep the tail. Every metadata piece
// but the last is exactly 16384 bytes; a client that sizes the last one wrong
// ends up with an info dictionary whose SHA-1 is not the info-hash, which is
// caught here rather than trusted.

import "core:strings"

// The reserved-byte bit for BEP 10.
EXT_RESERVED_BYTE :: 5
EXT_RESERVED_BIT :: u8(0x10)

// The DHT bit, named so the assertion that it stays clear can say what it is.
DHT_RESERVED_BYTE :: 7
DHT_RESERVED_BIT :: u8(0x01)

EXT_HANDSHAKE_ID :: u8(0)

// The id we ask peers to send ut_metadata on. 2 is what every client uses;
// nothing depends on the value, only on both sides reading the other's.
UT_METADATA_LOCAL_ID :: u8(2)

METADATA_PIECE_LEN :: 16 * 1024

// An info dictionary larger than this is refused rather than allocated. A
// torrent for a terabyte has roughly 20 MB of `pieces`; 32 MB is generous and
// still bounded, and the number comes from a hostile peer.
MAX_METADATA_SIZE :: 32 << 20

Ut_Metadata_Type :: enum u8 {
	Request = 0,
	Data    = 1,
	Reject  = 2,
}

ut_metadata_type_name :: proc(t: Ut_Metadata_Type) -> string {
	switch t {
	case .Request:
		return "request"
	case .Data:
		return "data"
	case .Reject:
		return "reject"
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// The reserved bytes
// ---------------------------------------------------------------------------

// ext_reserved_bytes builds the eight reserved bytes of the handshake.
//
// `metadata` sets the BEP 10 bit and nothing else. There is no argument that
// sets the DHT bit, deliberately: it is not a flag that was left false, it is
// a capability this client does not have.
ext_reserved_bytes :: proc(metadata: bool) -> (r: [8]u8) {
	if metadata {
		r[EXT_RESERVED_BYTE] |= EXT_RESERVED_BIT
	}
	return r
}

reserved_has_extensions :: proc(r: [8]u8) -> bool {
	return r[EXT_RESERVED_BYTE] & EXT_RESERVED_BIT != 0
}

reserved_has_dht :: proc(r: [8]u8) -> bool {
	return r[DHT_RESERVED_BYTE] & DHT_RESERVED_BIT != 0
}

// ---------------------------------------------------------------------------
// Framing an extended message
// ---------------------------------------------------------------------------

msg_extended :: proc(out: ^[dynamic]u8, ext_id: u8, payload: []u8) {
	append_be_u32(out, u32(2 + len(payload)))
	append(out, u8(Msg_Id.Extended))
	append(out, ext_id)
	append(out, ..payload)
}

// ---------------------------------------------------------------------------
// The extension handshake
// ---------------------------------------------------------------------------

Ext_Handshake :: struct {
	// The id the PEER asked us to send ut_metadata on. 0 means it did not
	// register ut_metadata, and 0 is never a valid target because 0 is the
	// handshake itself.
	ut_metadata:   int,
	metadata_size: int,
	client:        string,
	// Did the peer offer peer exchange? Recorded so the selftest can assert
	// that offering it changes nothing: we never register it, so we never get
	// an id for it, so we can never send one and never ask for one.
	offered_pex:   bool,
	// Every extension name the peer registered, for the peers tab.
	names:         []string,
}

ext_handshake_destroy :: proc(h: ^Ext_Handshake) {
	delete(h.client)
	for n in h.names {
		delete(n)
	}
	delete(h.names)
	h^ = {}
}

// ext_handshake_payload is what we send. `metadata_size` is 0 when we do not
// have the metadata ourselves, in which case the key is omitted entirely
// rather than sent as zero — a peer reading `metadata_size: 0` would conclude
// the torrent has an empty info dictionary.
ext_handshake_payload :: proc(metadata_size: int, allocator := context.allocator) -> []u8 {
	m := bdict({bp("ut_metadata", bnum(i64(UT_METADATA_LOCAL_ID)))}, context.temp_allocator)
	pairs := make([dynamic]Ben_Pair, 0, 3, context.temp_allocator)
	append(&pairs, bp("m", m))
	if metadata_size > 0 {
		append(&pairs, bp("metadata_size", bnum(i64(metadata_size))))
	}
	append(&pairs, bp("v", bstr(EXT_CLIENT_NAME)))
	return ben_encode(bdict(pairs[:], context.temp_allocator), allocator)
}

EXT_CLIENT_NAME :: "palmy 1.0.0"

ext_parse_handshake :: proc(
	payload: []u8,
	allocator := context.allocator,
) -> (
	h: Ext_Handshake,
	err: string,
) {
	root, derr := ben_decode(payload, context.temp_allocator)
	if derr != "" {
		return {}, tsprint("the extension handshake is not bencoded: %s", derr)
	}
	if root.kind != .Dict {
		return {}, "the extension handshake is not a dictionary"
	}
	if v, ok := ben_str_of(root, "v"); ok {
		h.client = strings.clone(v, allocator)
	}
	if s, ok := ben_int_of(root, "metadata_size"); ok {
		if s < 0 || s > MAX_METADATA_SIZE {
			return h, tsprint("a peer announced a metadata_size of %d; the cap is %d", s, MAX_METADATA_SIZE)
		}
		h.metadata_size = int(s)
	}
	mv, has_m := ben_get(root, "m")
	if !has_m {
		// A handshake with no `m` is legal: it registers nothing. It is also
		// how a peer says "I have dropped every extension", so it is not an
		// error.
		return h, ""
	}
	if mv.kind != .Dict {
		return h, "the extension handshake's `m` is not a dictionary"
	}
	names := make([dynamic]string, 0, len(mv.dict), allocator)
	for pair in mv.dict {
		name := string(pair.key)
		append(&names, strings.clone(name, allocator))
		if pair.val.kind != .Int {
			continue
		}
		switch name {
		case "ut_metadata":
			if pair.val.num > 0 && pair.val.num < 256 {
				h.ut_metadata = int(pair.val.num)
			}
		case "ut_pex":
			// Noted, never acted on. See the header: we do not register it,
			// so the peer has no id to send one on, and there is no code
			// anywhere in this program that reads a PEX payload.
			h.offered_pex = true
		}
	}
	h.names = names[:]
	return h, ""
}

// ext_known_id says whether an extended message id is one WE registered.
// Anything else is dropped: a peer cannot invent an extension for us.
ext_known_id :: proc(id: u8) -> bool {
	return id == EXT_HANDSHAKE_ID || id == UT_METADATA_LOCAL_ID
}

// ---------------------------------------------------------------------------
// ut_metadata messages
// ---------------------------------------------------------------------------

ut_metadata_request_payload :: proc(piece: int, allocator := context.allocator) -> []u8 {
	return ben_encode(
		bdict(
			{bp("msg_type", bnum(i64(Ut_Metadata_Type.Request))), bp("piece", bnum(i64(piece)))},
			context.temp_allocator,
		),
		allocator,
	)
}

ut_metadata_reject_payload :: proc(piece: int, allocator := context.allocator) -> []u8 {
	return ben_encode(
		bdict(
			{bp("msg_type", bnum(i64(Ut_Metadata_Type.Reject))), bp("piece", bnum(i64(piece)))},
			context.temp_allocator,
		),
		allocator,
	)
}

// ut_metadata_data_payload is the bencoded header immediately followed by the
// raw piece. There is no length prefix on the data: the dictionary ends where
// bencoding says it ends and everything after that is payload.
ut_metadata_data_payload :: proc(
	piece, total_size: int,
	data: []u8,
	allocator := context.allocator,
) -> []u8 {
	head := ben_encode(
		bdict(
			{
				bp("msg_type", bnum(i64(Ut_Metadata_Type.Data))),
				bp("piece", bnum(i64(piece))),
				bp("total_size", bnum(i64(total_size))),
			},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
	out := make([]u8, len(head) + len(data), allocator)
	copy(out, head)
	copy(out[len(head):], data)
	return out
}

Ut_Metadata_Msg :: struct {
	type:       Ut_Metadata_Type,
	piece:      int,
	total_size: int,
	data:       []u8, // aliases `payload`
}

ut_metadata_parse :: proc(payload: []u8) -> (m: Ut_Metadata_Msg, err: string) {
	root, used, derr := ben_decode_prefix(payload, context.temp_allocator)
	if derr != "" {
		return {}, tsprint("a ut_metadata message is not bencoded: %s", derr)
	}
	if root.kind != .Dict {
		return {}, "a ut_metadata message is not a dictionary"
	}
	mt, has_mt := ben_int_of(root, "msg_type")
	if !has_mt {
		return {}, "a ut_metadata message has no `msg_type`"
	}
	if mt < 0 || mt > 2 {
		return {}, tsprint("unknown ut_metadata msg_type %d", mt)
	}
	m.type = Ut_Metadata_Type(u8(mt))
	pc, has_pc := ben_int_of(root, "piece")
	if !has_pc {
		return {}, "a ut_metadata message has no `piece`"
	}
	if pc < 0 || pc > MAX_METADATA_SIZE / METADATA_PIECE_LEN {
		return {}, tsprint("implausible metadata piece %d", pc)
	}
	m.piece = int(pc)
	if ts, ok := ben_int_of(root, "total_size"); ok {
		if ts < 0 || ts > MAX_METADATA_SIZE {
			return {}, tsprint("a peer announced a total_size of %d; the cap is %d", ts, MAX_METADATA_SIZE)
		}
		m.total_size = int(ts)
	}
	m.data = payload[used:]
	if m.type == .Data && m.total_size == 0 {
		return {}, "a ut_metadata data message carries no `total_size`"
	}
	return m, ""
}

metadata_piece_count :: proc(size: int) -> int {
	if size <= 0 {
		return 0
	}
	return (size + METADATA_PIECE_LEN - 1) / METADATA_PIECE_LEN
}

// metadata_piece_span is the byte range of metadata piece `i`. The last piece
// is short, and sizing it as a full 16 KiB is how an info dictionary comes out
// with trailing zeros and fails its own hash.
metadata_piece_span :: proc(size, i: int) -> (lo, hi: int, ok: bool) {
	n := metadata_piece_count(size)
	if i < 0 || i >= n {
		return 0, 0, false
	}
	lo = i * METADATA_PIECE_LEN
	hi = min(lo + METADATA_PIECE_LEN, size)
	return lo, hi, true
}

// ---------------------------------------------------------------------------
// Assembling the metadata
// ---------------------------------------------------------------------------

// Metadata_Dl collects the pieces. It is deliberately not clever: the size is
// fixed by the first `metadata_size` we accept and a later peer claiming a
// different one is refused, because otherwise a hostile peer can resize the
// buffer under a transfer that is already half done.
Metadata_Dl :: struct {
	size: int,
	buf:  []u8,
	got:  Bitfield,
	n:    int, // pieces received
}

metadata_dl_begin :: proc(d: ^Metadata_Dl, size: int) -> (err: string) {
	if d.size != 0 {
		if d.size != size {
			return tsprint("a peer says the metadata is %d bytes; another said %d", size, d.size)
		}
		return ""
	}
	if size <= 0 || size > MAX_METADATA_SIZE {
		return tsprint("implausible metadata size %d", size)
	}
	d.size = size
	d.buf = make([]u8, size)
	d.got = bf_make(metadata_piece_count(size))
	d.n = 0
	return ""
}

metadata_dl_destroy :: proc(d: ^Metadata_Dl) {
	delete(d.buf)
	bf_destroy(&d.got)
	d^ = {}
}

metadata_dl_feed :: proc(d: ^Metadata_Dl, piece: int, data: []u8) -> (err: string) {
	if d.size == 0 {
		return "a metadata piece arrived before any metadata_size"
	}
	lo, hi, ok := metadata_piece_span(d.size, piece)
	if !ok {
		return tsprint("metadata piece %d is out of range for %d bytes", piece, d.size)
	}
	// Every piece but the last is a full 16 KiB. A peer that sends a short
	// one is either truncating or lying about the size.
	if len(data) != hi - lo {
		return tsprint(
			"metadata piece %d carries %d bytes; it must carry %d",
			piece,
			len(data),
			hi - lo,
		)
	}
	if bf_get(d.got, piece) {
		return "" // a duplicate is not an error; endgame produces them
	}
	copy(d.buf[lo:hi], data)
	bf_set(&d.got, piece, true)
	d.n += 1
	return ""
}

metadata_dl_complete :: proc(d: ^Metadata_Dl) -> bool {
	return d.size > 0 && d.n == metadata_piece_count(d.size)
}

// metadata_dl_missing is the first piece we still need, or -1.
metadata_dl_missing :: proc(d: ^Metadata_Dl) -> int {
	n := metadata_piece_count(d.size)
	for i in 0 ..< n {
		if !bf_get(d.got, i) {
			return i
		}
	}
	return -1
}

// metadata_dl_verify is the only thing standing between a stranger's bytes and
// a torrent this client will act on. The info-hash came from the magnet link;
// the bytes came from the peer; if SHA-1 over the bytes is not the hash, the
// peer sent something else and everything about it is discarded.
metadata_dl_verify :: proc(d: ^Metadata_Dl, want: Hash20) -> (ok: bool, got: Hash20) {
	if !metadata_dl_complete(d) {
		return false, {}
	}
	got = sha1_of(d.buf)
	return hash20_eq(got, want), got
}

// ---------------------------------------------------------------------------
// Building a .torrent around a verified info dictionary
// ---------------------------------------------------------------------------

// torrent_from_info splices the info bytes into a metainfo file WITHOUT
// re-encoding them.
//
// That is the whole reason this is written by hand instead of going through
// `ben_encode`: re-encoding would sort the info dictionary's keys, and a
// torrent whose info dictionary was not already sorted would come out with a
// different info-hash than the one we just verified. The bytes we hashed are
// the bytes we write.
//
// The top-level keys are emitted in sorted order — "announce",
// "announce-list", "info" — which is what bencoding requires.
torrent_from_info :: proc(
	info: []u8,
	trackers: []string,
	allocator := context.allocator,
) -> []u8 {
	out := make([dynamic]u8, 0, len(info) + 256, allocator)
	append(&out, 'd')
	if len(trackers) > 0 {
		ben_write(&out, bstr("announce"))
		ben_write(&out, bstr(trackers[0]))
		ben_write(&out, bstr("announce-list"))
		append(&out, 'l')
		for tr in trackers {
			append(&out, 'l')
			ben_write(&out, bstr(tr))
			append(&out, 'e')
		}
		append(&out, 'e')
	}
	ben_write(&out, bstr("info"))
	append(&out, ..info)
	append(&out, 'e')
	return out[:]
}
