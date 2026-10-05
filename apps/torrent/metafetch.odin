package main

// Resolving a magnet: BEP 9 against a peer we were given, not a stranger.
//
// WHAT CHANGED, AND WHAT DID NOT
//
// A magnet link is an info-hash and some tracker URLs. Turning it into a
// torrent needs two things:
//
//   1. an address to ask, and
//   2. a wire protocol to ask with.
//
// The old note in `ui.odin` said a magnet "needs BEP 9 over a DHT", and so
// refused the whole thing. Only the first half of that was ever the problem.
// (1) is where the safety rule lives: a DHT finds an address by asking
// strangers, and this client has no DHT and will not get one. (2) is just a
// wire format, and refusing it bought nothing.
//
// So a magnet now resolves through the addresses its own `tr=` trackers hand
// back — the same path an ordinary torrent's peers arrive on, through the same
// `sock_connect` gate, which means in practice through a tracker on 127.0.0.1
// and no other. A magnet whose trackers are real hosts gets as far as the gate
// and no further, and says so.
//
// The verification is the part that matters. The bytes come from a peer; the
// hash came from the user's own magnet link. `metadata_dl_verify` recomputes
// SHA-1 over the assembled info dictionary and compares. A peer that sends
// anything else — truncated, padded, a different torrent entirely — produces a
// different hash and the whole fetch is discarded. Nothing is written to disk
// and no torrent is added until that check passes.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// How long one peer gets before we give up on it and try the next.
METAFETCH_TIMEOUT_MS :: 8000

// How many metadata pieces to have outstanding at once. The whole info
// dictionary of a large torrent is a couple of megabytes, so this is not a
// throughput question; it is only here so a 100-piece fetch is not 100 round
// trips.
METAFETCH_PIPELINE :: 8

Metafetch_Trace :: struct {
	sent_handshake_ext: bool, // did we set the BEP 10 bit
	peer_ext:           bool, // did the peer set it back
	peer_ut_metadata:   int, // the id the peer registered
	peer_offered_pex:   bool,
	metadata_size:      int,
	pieces:             int,
	requests_sent:      int,
	rejects:            int,
	verified:           bool,
}

// metadata_fetch_from_peer runs the whole BEP 10 + BEP 9 exchange against one
// peer and returns the verified info dictionary.
//
// It is synchronous. That is the same judgement `tracker_announce` already
// makes and for the same reason: the only address it can reach is on the
// loopback interface, where a round trip is measured in microseconds. It is
// not called from the engine's poll loop.
metadata_fetch_from_peer :: proc(
	host: string,
	port: int,
	info_hash: Hash20,
	peer_id: [20]u8,
	timeout_ms: i32 = METAFETCH_TIMEOUT_MS,
	allocator := context.allocator,
	trace: ^Metafetch_Trace = nil,
) -> (
	info: []u8,
	err: string,
) {
	tr: Metafetch_Trace
	defer if trace != nil {
		trace^ = tr
	}

	// The gate. A magnet that named a routable peer dies on this line.
	s, cerr := sock_connect(host, port)
	if cerr != "" {
		return nil, cerr
	}
	defer sock_close(s)

	f: Framer
	framer_init(&f)
	defer framer_destroy(&f)

	out := make([dynamic]u8, 0, 4096, context.temp_allocator)
	hs := handshake_encode(info_hash, peer_id, context.temp_allocator, extended = true)
	append(&out, ..hs)
	tr.sent_handshake_ext = true

	dl: Metadata_Dl
	defer metadata_dl_destroy(&dl)

	deadline := now_s() + f64(timeout_ms) / 1000.0
	shook := false
	ext_sent := false
	peer_ut := 0
	requested := 0

	for {
		if werr := mf_flush(s, &out, deadline); werr != "" {
			return nil, werr
		}
		if now_s() > deadline {
			return nil, tsprint("%s:%d did not finish the metadata exchange in time", host, port)
		}
		// Only block for more bytes when there is nothing left to decode.
		// The fixture — and a real peer — routinely packs its handshake and
		// its extension handshake into one segment, and a reader that always
		// waits for a *new* segment after each message deadlocks on exactly
		// that.
		if rerr := mf_read(s, &f, deadline, framer_buffered(&f) == 0); rerr != "" {
			return nil, rerr
		}

		if !shook {
			h, st := framer_take_handshake(&f, info_hash)
			switch st {
			case .Incomplete:
				framer_compact(&f)
				continue
			case .Bad:
				return nil, f.err
			case .Ready:
				shook = true
				tr.peer_ext = reserved_has_extensions(h.reserved)
				if !tr.peer_ext {
					return nil, tsprint(
						"%s:%d does not speak the extension protocol, so it cannot send metadata",
						host,
						port,
					)
				}
			}
		}

		if shook && !ext_sent {
			// We have no metadata — that is why we are here — so no
			// `metadata_size` goes in our handshake.
			msg_extended(
				&out,
				EXT_HANDSHAKE_ID,
				ext_handshake_payload(0, context.temp_allocator),
			)
			ext_sent = true
			// No `continue`: whatever arrived in the same read as the
			// handshake is still in the framer and has to be drained now.
		}

		drained := false
		for {
			m, st := framer_next(&f)
			if st == .Incomplete {
				break
			}
			if st == .Bad {
				return nil, f.err
			}
			drained = true
			if m.id != .Extended {
				// Bitfields, haves, chokes: all legal here and all irrelevant
				// to a metadata fetch.
				continue
			}
			if len(m.payload) < 1 {
				return nil, "an extended message with no extended id"
			}
			ext_id := m.payload[0]
			body := m.payload[1:]
			if !ext_known_id(ext_id) {
				// An id we never registered. This is where a peer trying to
				// push peer exchange at us lands.
				continue
			}
			if ext_id == EXT_HANDSHAKE_ID {
				eh, eerr := ext_parse_handshake(body, context.temp_allocator)
				if eerr != "" {
					return nil, eerr
				}
				peer_ut = eh.ut_metadata
				tr.peer_ut_metadata = peer_ut
				tr.peer_offered_pex = eh.offered_pex
				tr.metadata_size = eh.metadata_size
				if peer_ut == 0 {
					return nil, tsprint("%s:%d does not offer ut_metadata", host, port)
				}
				if eh.metadata_size == 0 {
					return nil, tsprint("%s:%d has no metadata to give", host, port)
				}
				if berr := metadata_dl_begin(&dl, eh.metadata_size); berr != "" {
					return nil, berr
				}
				tr.pieces = metadata_piece_count(dl.size)
				continue
			}
			// ut_metadata, on the id we registered.
			um, uerr := ut_metadata_parse(body)
			if uerr != "" {
				return nil, uerr
			}
			switch um.type {
			case .Data:
				if ferr := metadata_dl_feed(&dl, um.piece, um.data); ferr != "" {
					return nil, ferr
				}
			case .Reject:
				tr.rejects += 1
				return nil, tsprint("%s:%d rejected metadata piece %d", host, port, um.piece)
			case .Request:
				// We have nothing to give; say so rather than going silent.
				msg_extended(
					&out,
					u8(peer_ut),
					ut_metadata_reject_payload(um.piece, context.temp_allocator),
				)
			}
		}

		if dl.size > 0 && peer_ut > 0 {
			total := metadata_piece_count(dl.size)
			for requested < total && requested - dl.n < METAFETCH_PIPELINE {
				msg_extended(
					&out,
					u8(peer_ut),
					ut_metadata_request_payload(requested, context.temp_allocator),
				)
				requested += 1
				tr.requests_sent += 1
			}
		}

		if metadata_dl_complete(&dl) {
			break
		}
		if !drained && len(out) == 0 && now_s() > deadline {
			return nil, tsprint("%s:%d went quiet mid-exchange", host, port)
		}
	}

	if werr := mf_flush(s, &out, deadline); werr != "" {
		return nil, werr
	}

	ok, got := metadata_dl_verify(&dl, info_hash)
	if !ok {
		return nil, tsprint(
			"the metadata from %s:%d hashes to %s, not %s — discarded",
			host,
			port,
			hash20_hex(got, context.temp_allocator),
			hash20_hex(info_hash, context.temp_allocator),
		)
	}
	tr.verified = true
	return clone_bytes(dl.buf, allocator), ""
}

@(private = "file")
mf_flush :: proc(s: Sock, out: ^[dynamic]u8, deadline: f64) -> (err: string) {
	for len(out) > 0 {
		n, st := sock_write(s, out[:])
		if st == .Ok {
			remove_range(out, 0, n)
			continue
		}
		if st == .Again {
			if now_s() > deadline {
				return "timed out writing to the peer"
			}
			fds := [1]linux.Poll_Fd{{fd = linux.Fd(s), events = {.OUT}}}
			poll_wait(fds[:], 50)
			continue
		}
		return "the connection failed while writing"
	}
	return ""
}

@(private = "file")
mf_read :: proc(s: Sock, f: ^Framer, deadline: f64, block := true) -> (err: string) {
	buf: [32 * 1024]u8
	got_any := false
	for {
		n, st := sock_read(s, buf[:])
		if st == .Ok {
			framer_feed(f, buf[:n])
			got_any = true
			if n < len(buf) {
				return ""
			}
			continue
		}
		if st == .Again {
			if got_any || !block {
				return ""
			}
			if now_s() > deadline {
				return "timed out waiting for the peer"
			}
			fds := [1]linux.Poll_Fd{{fd = linux.Fd(s), events = {.IN}}}
			poll_wait(fds[:], 20)
			if now_s() > deadline {
				return "timed out waiting for the peer"
			}
			continue
		}
		if st == .Closed {
			return "the peer closed the connection mid-exchange"
		}
		return "the connection failed while reading"
	}
}

// ---------------------------------------------------------------------------
// The whole magnet
// ---------------------------------------------------------------------------

Magnet_Resolution :: struct {
	torrent:   []u8, // the .torrent file, info bytes spliced in verbatim
	from_host: string,
	from_port: int,
	peers_seen: int,
	tried:     int,
	notes:     [dynamic]string, // every tracker and peer that was refused, and why
}

// The allocator must be the one `magnet_resolve` was given. Everything in the
// result comes from it, including the note strings — mixing the context
// allocator into one field of a temp-allocated struct is how a free() goes
// wrong a long way from where the mistake was made.
magnet_resolution_destroy :: proc(r: ^Magnet_Resolution, allocator := context.allocator) {
	delete(r.torrent, allocator)
	delete(r.from_host, allocator)
	for n in r.notes {
		delete(n, allocator)
	}
	delete(r.notes)
	r^ = {}
}

// magnet_resolve announces to the magnet's own trackers, then asks the peers
// they name for the metadata until one of them produces bytes that hash to the
// info-hash in the link.
//
// Every address it touches came from a tracker the user's own magnet named and
// went through `sock_connect`. There is no other source of addresses, and in
// particular nothing here asks a peer who else it knows.
magnet_resolve :: proc(
	mg: Magnet,
	peer_id: [20]u8,
	port: int = 0,
	timeout_ms: i32 = METAFETCH_TIMEOUT_MS,
	allocator := context.allocator,
) -> (
	res: Magnet_Resolution,
	err: string,
) {
	res.notes = make([dynamic]string, 0, 4, allocator)
	if len(mg.trackers) == 0 {
		return res, "this magnet names no trackers, so there is no address to ask and this client will not look for one"
	}

	// A tracker requires a port, and refuses 0. The engine passes its real
	// listening port; a caller that has none — the selftest, and anything
	// resolving a magnet before an engine exists — gets the conventional
	// 6881. Nothing listens there, which costs a peer one refused connection
	// and costs us nothing: a metadata fetch dials out, it is never dialled.
	announce_port := port > 0 ? port : 6881

	seen := make([dynamic]Peer_Addr, 0, 8, context.temp_allocator)
	for url in mg.trackers {
		req := Announce_Req {
			info_hash = mg.info_hash,
			peer_id   = peer_id,
			port      = announce_port,
			left      = 1, // we have nothing; we do not even know how much there is
			event     = .Started,
			numwant   = 50,
		}
		resp, aerr := tracker_announce(url, req, timeout_ms, context.temp_allocator)
		if aerr != "" {
			append(&res.notes, fmt.aprintf("%s: %s", url, aerr, allocator = allocator))
			continue
		}
		if resp.failure != "" {
			append(&res.notes, fmt.aprintf("%s: %s", url, resp.failure, allocator = allocator))
			continue
		}
		for pa in resp.peers {
			if pa.port == announce_port && pa.host == "127.0.0.1" {
				continue // the tracker handing us back our own announce
			}
			dup := false
			for e in seen {
				if e.host == pa.host && e.port == pa.port {
					dup = true
					break
				}
			}
			if !dup {
				append(&seen, pa)
			}
		}
	}
	res.peers_seen = len(seen)
	if len(seen) == 0 {
		return res, "no tracker this magnet names gave back a peer this client is allowed to contact"
	}

	for pa in seen {
		res.tried += 1
		info, ferr := metadata_fetch_from_peer(
			pa.host,
			pa.port,
			mg.info_hash,
			peer_id,
			timeout_ms,
			context.temp_allocator,
		)
		if ferr != "" {
			append(&res.notes, fmt.aprintf("%s:%d: %s", pa.host, pa.port, ferr, allocator = allocator))
			continue
		}
		res.torrent = torrent_from_info(info, mg.trackers, allocator)
		res.from_host = strings.clone(pa.host, allocator)
		res.from_port = pa.port
		return res, ""
	}
	return res, tsprint("none of the %d peer(s) produced metadata matching the info-hash", len(seen))
}
