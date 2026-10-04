package main

// The peer wire protocol (BEP 3), framed off a byte stream.
//
// FRAMING
//
// This is the part that has to be right, and it is the same lesson as an IMAP
// literal: TCP is a stream of bytes, not a sequence of messages. One `read`
// can return
//
//   * half of a message,
//   * a third of a message, then another third, then the rest,
//   * four whole messages at once,
//   * three whole messages and the first two bytes of a fifth.
//
// A client that assumes one read is one message works perfectly on loopback
// against a cooperative peer and then falls apart against a real swarm, where
// a 16 KiB piece message is split across however many segments the path MTU
// dictates. So `Framer` is a buffer with a cursor: bytes go in whenever they
// arrive, and `framer_next` hands out a message only when all of it is present,
// reporting `.Incomplete` otherwise. Every case above is asserted in
// `selftest.odin` from canned byte arrays with no socket involved at all.
//
// The wire shapes:
//
//   handshake  <19><"BitTorrent protocol"><8 reserved><20 info_hash><20 peer_id>
//              — 68 bytes, fixed, and NOT length-prefixed like the rest
//   keep-alive <0000>                       (a zero length, no id)
//   message    <length><id><payload>        length counts the id byte
//
// A length of zero is a keep-alive, not an error, and a client that treats it
// as a malformed message disconnects from every well-behaved peer after two
// minutes of idling.

import "core:strings"

PROTOCOL_NAME :: "BitTorrent protocol"
HANDSHAKE_LEN :: 68

// The largest message anyone may send us. A piece message is 9 bytes of header
// plus a block, and blocks are 16 KiB by convention; allow a 128 KiB block in
// case a peer uses a larger one, and refuse anything beyond that rather than
// allocating what a hostile length prefix asks for. A four-byte length can say
// 4 GiB, and a client that believes it is a one-packet denial of service.
MAX_MESSAGE :: 9 + 128 * 1024

Msg_Id :: enum i16 {
	Keep_Alive     = -1, // not a real id; a zero-length message
	Choke          = 0,
	Unchoke        = 1,
	Interested     = 2,
	Not_Interested = 3,
	Have           = 4,
	Bitfield       = 5,
	Request        = 6,
	Piece          = 7,
	Cancel         = 8,
	Port           = 9, // DHT; parsed so it can be ignored, never acted on
	Extended       = 20,
}

msg_id_name :: proc(id: Msg_Id) -> string {
	switch id {
	case .Keep_Alive:
		return "keep-alive"
	case .Choke:
		return "choke"
	case .Unchoke:
		return "unchoke"
	case .Interested:
		return "interested"
	case .Not_Interested:
		return "not interested"
	case .Have:
		return "have"
	case .Bitfield:
		return "bitfield"
	case .Request:
		return "request"
	case .Piece:
		return "piece"
	case .Cancel:
		return "cancel"
	case .Port:
		return "port"
	case .Extended:
		return "extended"
	}
	return "unknown"
}

// Msg is one decoded message. `payload` aliases the framer's buffer and is only
// valid until the next `framer_next`.
Msg :: struct {
	id:      Msg_Id,
	index:   u32, // have, request, piece, cancel
	begin:   u32, // request, piece, cancel
	length:  u32, // request, cancel
	payload: []u8, // bitfield bytes, piece block, extended payload
}

Frame_Status :: enum {
	Ready, // a message is in `out`
	Incomplete, // nothing yet; feed more bytes
	Bad, // protocol violation; drop the peer
}

Framer :: struct {
	buf:  [dynamic]u8,
	r:    int, // consumed prefix, compacted away lazily
	err:  string,
}

framer_init :: proc(f: ^Framer) {
	f.buf = make([dynamic]u8, 0, 32 * 1024)
	f.r = 0
}

framer_destroy :: proc(f: ^Framer) {
	delete(f.buf)
	f^ = {}
}

framer_feed :: proc(f: ^Framer, data: []u8) {
	append(&f.buf, ..data)
}

framer_buffered :: proc(f: ^Framer) -> int {
	return len(f.buf) - f.r
}

// framer_compact drops the consumed prefix. Called after each drain rather than
// after each message, so a read that delivered eight messages is copied once.
framer_compact :: proc(f: ^Framer) {
	if f.r == 0 {
		return
	}
	if f.r == len(f.buf) {
		clear(&f.buf)
		f.r = 0
		return
	}
	copy(f.buf[:], f.buf[f.r:])
	resize(&f.buf, len(f.buf) - f.r)
	f.r = 0
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

Handshake :: struct {
	reserved:  [8]u8,
	info_hash: Hash20,
	peer_id:   [20]u8,
}

handshake_encode :: proc(
	info_hash: Hash20,
	peer_id: [20]u8,
	allocator := context.allocator,
) -> []u8 {
	ih := info_hash
	pid := peer_id
	out := make([]u8, HANDSHAKE_LEN, allocator)
	out[0] = u8(len(PROTOCOL_NAME))
	copy(out[1:], PROTOCOL_NAME)
	// The eight reserved bytes are all zero. Each bit in them advertises an
	// extension; this client has none to advertise, and in particular bit 0 of
	// the last byte (DHT) and bit 0x10 of byte 5 (extension protocol, which
	// carries peer exchange) are deliberately left clear, because a peer that
	// believes we speak them would send us addresses we are not allowed to use.
	// Byte 0 is the name length and bytes 1..19 the name, so the reserved
	// block is 20..27, the info-hash 28..47 and the peer id 48..67.
	copy(out[28:], ih[:])
	copy(out[48:], pid[:])
	return out
}

// framer_take_handshake pulls the fixed 68-byte handshake off the front of the
// stream. `want` is the info-hash we expect; a mismatch is `.Bad`, because a
// peer handshaking for a different torrent on this connection is either
// confused or hostile.
framer_take_handshake :: proc(
	f: ^Framer,
	want: Hash20,
	check_hash := true,
) -> (
	h: Handshake,
	st: Frame_Status,
) {
	if framer_buffered(f) < HANDSHAKE_LEN {
		// Before giving up, reject a stream that cannot possibly be a
		// handshake, so a peer that sends garbage is dropped on the first byte
		// rather than after 68 of them.
		if framer_buffered(f) >= 1 && f.buf[f.r] != u8(len(PROTOCOL_NAME)) {
			f.err = tsprint(
				"the first byte of the handshake is %d, not %d",
				f.buf[f.r],
				len(PROTOCOL_NAME),
			)
			return {}, .Bad
		}
		return {}, .Incomplete
	}
	b := f.buf[f.r:f.r + HANDSHAKE_LEN]
	if int(b[0]) != len(PROTOCOL_NAME) || string(b[1:20]) != PROTOCOL_NAME {
		f.err = tsprint("handshake names the protocol %q", string(b[1:20]))
		return {}, .Bad
	}
	copy(h.reserved[:], b[20:28])
	copy(h.info_hash[:], b[28:48])
	copy(h.peer_id[:], b[48:68])
	if check_hash && !hash20_eq(h.info_hash, want) {
		f.err = tsprint(
			"handshake is for info-hash %s, not %s",
			hash20_hex(h.info_hash, context.temp_allocator),
			hash20_hex(want, context.temp_allocator),
		)
		return {}, .Bad
	}
	f.r += HANDSHAKE_LEN
	return h, .Ready
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

// framer_next decodes the next complete message, if there is one.
//
// It never partially consumes: on `.Incomplete` the cursor has not moved, so
// the caller can simply feed more bytes and call again.
framer_next :: proc(f: ^Framer) -> (m: Msg, st: Frame_Status) {
	avail := framer_buffered(f)
	if avail < 4 {
		return {}, .Incomplete
	}
	length := be_u32(f.buf[f.r:f.r + 4])
	if length == 0 {
		// Keep-alive. It carries no id and no payload.
		f.r += 4
		return Msg{id = .Keep_Alive}, .Ready
	}
	if length > MAX_MESSAGE {
		f.err = tsprint("a peer announced a %d byte message; the cap is %d", length, MAX_MESSAGE)
		return {}, .Bad
	}
	if avail < 4 + int(length) {
		return {}, .Incomplete
	}
	body := f.buf[f.r + 4:f.r + 4 + int(length)]
	raw_id := body[0]
	payload := body[1:]

	id := Msg_Id(i16(raw_id))
	out := Msg {
		id = id,
	}
	switch id {
	case .Choke, .Unchoke, .Interested, .Not_Interested:
		if len(payload) != 0 {
			f.err = tsprint("%s carries %d payload bytes; it must carry none", msg_id_name(id), len(payload))
			return {}, .Bad
		}
	case .Have:
		if len(payload) != 4 {
			f.err = tsprint("have carries %d bytes; it must carry 4", len(payload))
			return {}, .Bad
		}
		out.index = be_u32(payload)
	case .Bitfield:
		out.payload = payload
	case .Request, .Cancel:
		if len(payload) != 12 {
			f.err = tsprint("%s carries %d bytes; it must carry 12", msg_id_name(id), len(payload))
			return {}, .Bad
		}
		out.index = be_u32(payload[0:4])
		out.begin = be_u32(payload[4:8])
		out.length = be_u32(payload[8:12])
	case .Piece:
		if len(payload) < 8 {
			f.err = tsprint("piece carries %d bytes; it needs at least 8 of header", len(payload))
			return {}, .Bad
		}
		out.index = be_u32(payload[0:4])
		out.begin = be_u32(payload[4:8])
		out.payload = payload[8:]
		out.length = u32(len(out.payload))
	case .Port:
		if len(payload) != 2 {
			f.err = tsprint("port carries %d bytes; it must carry 2", len(payload))
			return {}, .Bad
		}
		out.index = u32(be_u16(payload))
	case .Extended:
		out.payload = payload
	case .Keep_Alive:
		// Id 255 would decode to this; treat it as unknown.
		out.id = Msg_Id(i16(raw_id))
		out.payload = payload
	case:
		// An unknown id is not an error. BEP 3 says ignore what you do not
		// understand, and clients do send ids this one has never heard of.
		out.payload = payload
	}
	f.r += 4 + int(length)
	return out, .Ready
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

msg_keep_alive :: proc(out: ^[dynamic]u8) {
	append_be_u32(out, 0)
}

msg_simple :: proc(out: ^[dynamic]u8, id: Msg_Id) {
	append_be_u32(out, 1)
	append(out, u8(id))
}

msg_have :: proc(out: ^[dynamic]u8, index: int) {
	append_be_u32(out, 5)
	append(out, u8(Msg_Id.Have))
	append_be_u32(out, u32(index))
}

msg_bitfield :: proc(out: ^[dynamic]u8, b: Bitfield) {
	append_be_u32(out, u32(1 + len(b.bits)))
	append(out, u8(Msg_Id.Bitfield))
	append(out, ..b.bits)
}

msg_request :: proc(out: ^[dynamic]u8, index, begin, length: int) {
	append_be_u32(out, 13)
	append(out, u8(Msg_Id.Request))
	append_be_u32(out, u32(index))
	append_be_u32(out, u32(begin))
	append_be_u32(out, u32(length))
}

msg_cancel :: proc(out: ^[dynamic]u8, index, begin, length: int) {
	append_be_u32(out, 13)
	append(out, u8(Msg_Id.Cancel))
	append_be_u32(out, u32(index))
	append_be_u32(out, u32(begin))
	append_be_u32(out, u32(length))
}

msg_piece :: proc(out: ^[dynamic]u8, index, begin: int, block: []u8) {
	append_be_u32(out, u32(9 + len(block)))
	append(out, u8(Msg_Id.Piece))
	append_be_u32(out, u32(index))
	append_be_u32(out, u32(begin))
	append(out, ..block)
}

// ---------------------------------------------------------------------------
// Peer ids
// ---------------------------------------------------------------------------

PEER_ID_PREFIX :: "-PY1000-" // Azureus style: client PY, version 1.0.0

// peer_id_new makes a 20-byte id: eight bytes of client tag and twelve of
// entropy from the deterministic generator, seeded differently per process.
peer_id_new :: proc(seed: u64) -> (id: [20]u8) {
	copy(id[:], PEER_ID_PREFIX)
	x := xs_init(seed)
	rest: [12]u8
	xs_fill(&x, rest[:])
	// Keep them printable so a log line is readable.
	alphabet := ALNUM36
	for i in 0 ..< 12 {
		id[8 + i] = alphabet[int(rest[i]) % 36]
	}
	return id
}

peer_id_text :: proc(id: [20]u8, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	ids := id
	for c in ids {
		if c >= 0x20 && c < 0x7f {
			strings.write_byte(&b, c)
		} else {
			strings.write_string(&b, "·")
		}
	}
	return strings.to_string(b)
}

// peer_client_name reads the Azureus-style prefix, so the peers tab can say
// what the other side is running.
peer_client_name :: proc(id: [20]u8, allocator := context.allocator) -> string {
	b := id
	if b[0] == '-' && b[7] == '-' {
		code := string(b[1:3])
		name := "unknown"
		switch code {
		case "PY":
			name = "palmy"
		case "qB":
			name = "qBittorrent"
		case "TR":
			name = "Transmission"
		case "lt", "LT":
			name = "libtorrent"
		case "UT":
			name = "µTorrent"
		case "DE":
			name = "Deluge"
		case "AZ":
			name = "Azureus"
		}
		return asprint("%s %c.%c.%c", name, rune(b[3]), rune(b[4]), rune(b[5]))
	}
	return strings.clone("unknown", allocator)
}

// ---------------------------------------------------------------------------
// Compact peer lists
// ---------------------------------------------------------------------------

Peer_Addr :: struct {
	host: string,
	port: int,
}

// parse_compact_peers reads the 6-bytes-per-peer form a tracker returns:
// four octets of IPv4 then two of port, big-endian.
//
// The addresses in here come from a stranger. Nothing is filtered at this
// level on purpose — the gate is in `sock_connect`, which is where it has to
// be, since that is the only place a connection can happen. The selftest feeds
// a routable address through this parser and then asserts the connect is
// refused.
parse_compact_peers :: proc(data: []u8, allocator := context.allocator) -> (out: []Peer_Addr, err: string) {
	if len(data) % 6 != 0 {
		return nil, tsprint("a compact peer list of %d bytes is not a multiple of 6", len(data))
	}
	peers := make([dynamic]Peer_Addr, 0, len(data) / 6, allocator)
	for i := 0; i + 6 <= len(data); i += 6 {
		host := asprint("%d.%d.%d.%d", data[i], data[i + 1], data[i + 2], data[i + 3])
		port := int(be_u16(data[i + 4:i + 6]))
		if port == 0 {
			delete(host)
			continue
		}
		dup := false
		for p in peers {
			if p.host == host && p.port == port {
				dup = true
				break
			}
		}
		if dup {
			delete(host)
			continue
		}
		append(&peers, Peer_Addr{host = host, port = port})
	}
	return peers[:], ""
}

encode_compact_peers :: proc(peers: []Peer_Addr, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(peers) * 6, allocator)
	for p in peers {
		a, err := loopback_address(p.host)
		if err != "" {
			continue
		}
		append(&out, a[0], a[1], a[2], a[3])
		append_be_u16(&out, u16(p.port))
	}
	return out[:]
}

peer_addrs_equal :: proc(a, b: []Peer_Addr) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i].host != b[i].host || a[i].port != b[i].port {
			return false
		}
	}
	return true
}
