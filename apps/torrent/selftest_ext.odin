package main

// Assertions for BEP 10, BEP 9 and the scrape — and the loopback fixture peer
// they run against.
//
// WHAT IS TESTED WITHOUT A SOCKET, AND WHAT NEEDS ONE
//
// The wire shapes are asserted byte for byte from canned arrays, the same way
// `test_framing` does, because that is the only way to be sure a dictionary
// came out with its keys sorted and a piece came out the length it claims.
//
// The exchange itself needs two ends, so there is a fixture: a peer on
// 127.0.0.1 that speaks the handshake, advertises BEP 10, registers
// ut_metadata on an id of its own choosing, and serves the pieces. The real
// `metadata_fetch_from_peer` is driven against it. The fixture records what
// the client sent, so the assertions are about this client's bytes, not about
// the fixture's.
//
// The fixture registers `ut_pex` as well, in one of the cases. That is the
// point of it: a peer CAN offer peer exchange, and the assertion is that this
// client still registers only `ut_metadata`, never sends anything on the pex
// id, and ends up with exactly the same metadata. Offering it changes nothing.

import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// A synthetic info dictionary, big enough to need three metadata pieces
// ---------------------------------------------------------------------------

// FIXTURE_PIECES is chosen so the info dictionary is a little over 40 KB: two
// full 16 KiB metadata pieces and a short third one. A fixture that fits in
// one piece would not catch the off-by-one that sizes the last piece wrong,
// which is the bug this part of BEP 9 actually has.
FIXTURE_PIECES :: 2000
FIXTURE_PIECE_LEN :: 32768

fixture_info_bytes :: proc(allocator := context.allocator) -> []u8 {
	hashes := make([]u8, FIXTURE_PIECES * 20, context.temp_allocator)
	x := xs_init(0xBEEF9)
	xs_fill(&x, hashes)
	total := i64(FIXTURE_PIECES) * FIXTURE_PIECE_LEN - 100 // a short last piece
	return ben_encode(
		bdict(
			{
				bp("length", bnum(total)),
				bp("name", bstr("fixture-payload")),
				bp("piece length", bnum(FIXTURE_PIECE_LEN)),
				bp("pieces", bbytes(hashes)),
			},
			context.temp_allocator,
		),
		allocator,
	)
}

// ---------------------------------------------------------------------------
// The wire shapes, with no socket
// ---------------------------------------------------------------------------

test_extension_wire :: proc(t: ^T) {
	tsection(t, "the extension protocol (BEP 10) and metadata exchange (BEP 9)")

	// --- the reserved bytes -------------------------------------------------
	ih, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	pid := peer_id_new(77)

	plain := handshake_encode(ih, pid, context.temp_allocator)
	allzero := true
	for i in 20 ..< 28 {
		if plain[i] != 0 {allzero = false}
	}
	tcheck(
		t,
		"the bare handshake still advertises nothing at all",
		allzero,
		"this is the form `handshake_encode` produces by default",
	)

	ext := handshake_encode(ih, pid, context.temp_allocator, extended = true)
	teq_int(t, "the extended handshake is still 68 bytes", len(ext), HANDSHAKE_LEN)
	teq_int(t, "reserved byte 5 is 0x10 — BEP 10 and nothing else", int(ext[20 + 5]), 0x10)
	zeros_elsewhere := true
	for i in 0 ..< 8 {
		if i == 5 && ext[20 + i] == 0x10 {
			continue
		}
		if ext[20 + i] != 0 {zeros_elsewhere = false}
	}
	tcheck(
		t,
		"every other reserved byte is zero",
		zeros_elsewhere,
		"only one bit is set, and it is the extension protocol's",
	)
	tcheck(
		t,
		"the DHT bit of the last reserved byte is CLEAR",
		ext[20 + 7] & 0x01 == 0,
		"there is no DHT in this client and no argument that would set this bit",
	)
	r := ext_reserved_bytes(true)
	tcheck(t, "reserved_has_extensions reads it back", reserved_has_extensions(r))
	tcheck(t, "...and reserved_has_dht does not", !reserved_has_dht(r))
	tcheck(t, "a peer's DHT bit is recognised, so it can be ignored knowingly",
		reserved_has_dht([8]u8{0, 0, 0, 0, 0, 0, 0, 0x01}))

	// --- our extension handshake, byte for byte -----------------------------
	hp := ext_handshake_payload(20480, context.temp_allocator)
	tbytes(
		t,
		"our extension handshake registers ut_metadata and nothing else",
		hp,
		"d1:md11:ut_metadatai2ee13:metadata_sizei20480e1:v11:palmy 1.0.0e",
	)
	tcheck(
		t,
		"...and in particular contains no `ut_pex`",
		!strings.contains(string(hp), "ut_pex"),
		string(hp),
	)
	hp0 := ext_handshake_payload(0, context.temp_allocator)
	tbytes(
		t,
		"with no metadata of our own, `metadata_size` is omitted rather than sent as 0",
		hp0,
		"d1:md11:ut_metadatai2ee1:v11:palmy 1.0.0e",
	)

	// --- the framing of an extended message ---------------------------------
	fr := make([dynamic]u8, 0, 64, context.temp_allocator)
	msg_extended(&fr, 7, transmute([]u8)string("abc"))
	teq_int(t, "an extended message's length counts the id and the ext id", int(be_u32(fr[0:4])), 5)
	teq_int(t, "...its message id is 20", int(fr[4]), 20)
	teq_int(t, "...then the extended id", int(fr[5]), 7)
	teq(t, "...then the payload", string(fr[6:]), "abc")

	// It must come back out of the framer as one message.
	f: Framer
	framer_init(&f)
	defer framer_destroy(&f)
	framer_feed(&f, fr[:])
	m, st := framer_next(&f)
	tcheck(t, "the framer decodes it", st == .Ready)
	tcheck(t, "...as an extended message", m.id == .Extended)
	teq(t, "...with the ext id and payload intact", string(m.payload), "\x07abc")

	// --- parsing a peer's extension handshake -------------------------------
	peer_hs := ben_encode(
		bdict(
			{
				bp(
					"m",
					bdict(
						{bp("ut_metadata", bnum(7)), bp("ut_pex", bnum(1))},
						context.temp_allocator,
					),
				),
				bp("metadata_size", bnum(40100)),
				bp("v", bstr("qBittorrent 4.6.5")),
			},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
	eh, eerr := ext_parse_handshake(peer_hs, context.temp_allocator)
	teq(t, "a peer's extension handshake parses", eerr, "")
	teq_int(t, "...and ut_metadata is the id THE PEER asked for, not ours", eh.ut_metadata, 7)
	teq_int(t, "...which is not 2", UT_METADATA_LOCAL_ID == 7 ? 1 : 0, 0)
	teq_int(t, "...metadata_size is carried", eh.metadata_size, 40100)
	teq(t, "...and the client name", eh.client, "qBittorrent 4.6.5")
	tcheck(t, "a peer offering ut_pex is noticed", eh.offered_pex)
	tcheck(
		t,
		"...but there is no id for it, because we never registered one",
		!ext_known_id(1),
		"ext_known_id(1) must be false: 1 is the id the PEER chose for pex, and it is meaningless to us",
	)
	tcheck(t, "the only ids we answer on are 0 and 2", ext_known_id(0) && ext_known_id(2))
	for bad in ([?]u8{1, 3, 7, 16, 255}) {
		if bad == 2 {continue}
		tcheck(t, asprint("extended id %d is not one of ours", bad), !ext_known_id(bad))
	}

	_, nerr := ext_parse_handshake(transmute([]u8)string("not bencoded"), context.temp_allocator)
	tcheck(t, "a handshake that is not bencoded is refused", nerr != "")
	huge := ben_encode(
		bdict({bp("metadata_size", bnum(1 << 40))}, context.temp_allocator),
		context.temp_allocator,
	)
	_, herr := ext_parse_handshake(huge, context.temp_allocator)
	tcheck(t, "an absurd metadata_size is refused rather than allocated", herr != "", herr)

	// --- the three ut_metadata messages -------------------------------------
	tbytes(
		t,
		"a metadata request is msg_type 0",
		ut_metadata_request_payload(3, context.temp_allocator),
		"d8:msg_typei0e5:piecei3ee",
	)
	tbytes(
		t,
		"a reject is msg_type 2",
		ut_metadata_reject_payload(3, context.temp_allocator),
		"d8:msg_typei2e5:piecei3ee",
	)
	dp := ut_metadata_data_payload(1, 20480, transmute([]u8)string("XYZ"), context.temp_allocator)
	tbytes(
		t,
		"a data message is the bencoded header with the raw bytes straight after it",
		dp,
		"d8:msg_typei1e5:piecei1e10:total_sizei20480eeXYZ",
	)
	um, uerr := ut_metadata_parse(dp)
	teq(t, "...and it parses back", uerr, "")
	tcheck(t, "...as data", um.type == .Data)
	teq_int(t, "...for piece 1", um.piece, 1)
	teq_int(t, "...of 20480 bytes", um.total_size, 20480)
	teq(t, "...carrying the trailing bytes and nothing else", string(um.data), "XYZ")

	rq, rerr := ut_metadata_parse(ut_metadata_request_payload(9, context.temp_allocator))
	teq(t, "a request parses", rerr, "")
	tcheck(t, "...as a request", rq.type == .Request)
	teq_int(t, "...with no trailing data", len(rq.data), 0)

	_, derr := ut_metadata_parse(transmute([]u8)string("d8:msg_typei9e5:piecei0ee"))
	tcheck(t, "an unknown msg_type is refused", derr != "")
	_, derr2 := ut_metadata_parse(transmute([]u8)string("d5:piecei0ee"))
	tcheck(t, "a message with no msg_type is refused", derr2 != "")
	_, derr3 := ut_metadata_parse(transmute([]u8)string("d8:msg_typei1e5:piecei0ee"))
	tcheck(t, "a data message with no total_size is refused", derr3 != "")

	// --- piece geometry -----------------------------------------------------
	teq_int(t, "40100 bytes of metadata is 3 pieces", metadata_piece_count(40100), 3)
	teq_int(t, "16384 bytes is exactly 1", metadata_piece_count(16384), 1)
	teq_int(t, "16385 bytes is 2", metadata_piece_count(16385), 2)
	teq_int(t, "0 bytes is 0", metadata_piece_count(0), 0)
	lo, hi, ok0 := metadata_piece_span(40100, 0)
	tcheck(t, "piece 0 spans the first 16 KiB", ok0 && lo == 0 && hi == 16384, asprint("%d..%d", lo, hi))
	lo2, hi2, _ := metadata_piece_span(40100, 2)
	tcheck(
		t,
		"the LAST piece is short, not padded",
		lo2 == 32768 && hi2 == 40100,
		asprint("%d..%d (%d bytes)", lo2, hi2, hi2 - lo2),
	)
	_, _, ok3 := metadata_piece_span(40100, 3)
	tcheck(t, "a piece past the end does not exist", !ok3)

	// --- assembly and the verification that makes it safe -------------------
	info := fixture_info_bytes(context.temp_allocator)
	want := sha1_of(info)
	n := metadata_piece_count(len(info))
	teq_int(t, "the fixture's info dictionary needs three metadata pieces", n, 3)

	dl: Metadata_Dl
	teq(t, "a download begins", metadata_dl_begin(&dl, len(info)), "")
	tcheck(t, "...and is not complete yet", !metadata_dl_complete(&dl))
	teq_int(t, "...and wants piece 0 first", metadata_dl_missing(&dl), 0)
	// Out of order, because a real swarm does not deliver in order.
	for i in ([?]int{2, 0, 1}) {
		a, b, _ := metadata_piece_span(len(info), i)
		teq(t, asprint("metadata piece %d is accepted", i), metadata_dl_feed(&dl, i, info[a:b]), "")
	}
	tcheck(t, "the metadata is complete", metadata_dl_complete(&dl))
	vok, vgot := metadata_dl_verify(&dl, want)
	tcheck(t, "...and SHA-1 over it is the info-hash", vok, hash20_hex(vgot, context.temp_allocator))

	// One byte wrong anywhere and the whole thing is refused.
	dl2: Metadata_Dl
	metadata_dl_begin(&dl2, len(info))
	corrupt := clone_bytes(info, context.temp_allocator)
	corrupt[20000] ~= 0xff
	for i in 0 ..< n {
		a, b, _ := metadata_piece_span(len(info), i)
		metadata_dl_feed(&dl2, i, corrupt[a:b])
	}
	bad_ok, _ := metadata_dl_verify(&dl2, want)
	tcheck(
		t,
		"ONE flipped byte makes the metadata fail its own hash",
		!bad_ok,
		"this is the only thing standing between a peer's bytes and a torrent we act on",
	)
	metadata_dl_destroy(&dl)
	metadata_dl_destroy(&dl2)

	// A short piece that is not the last one is a lie about the size.
	dl3: Metadata_Dl
	metadata_dl_begin(&dl3, len(info))
	serr := metadata_dl_feed(&dl3, 0, info[0:100])
	tcheck(t, "a short non-final metadata piece is refused", serr != "", serr)
	oerr := metadata_dl_feed(&dl3, 99, info[0:16384])
	tcheck(t, "a metadata piece past the end is refused", oerr != "", oerr)
	metadata_dl_destroy(&dl3)

	// --- splicing a .torrent around verified info bytes ---------------------
	tor := torrent_from_info(
		info,
		{"http://127.0.0.1:6969/announce", "udp://127.0.0.1:6969/announce"},
		context.temp_allocator,
	)
	m2, m2err := metainfo_parse(clone_bytes(tor, context.temp_allocator), context.temp_allocator)
	teq(t, "the spliced .torrent parses", m2err, "")
	tcheck(
		t,
		"...and its info-hash is the one we verified — the info bytes were NOT re-encoded",
		hash20_eq(m2.info_hash, want),
		hash20_hex(m2.info_hash, context.temp_allocator),
	)
	teq(t, "...the name survived", m2.name, "fixture-payload")
	teq_int(t, "...and both trackers are in it", len(m2.announce_list), 2)
}

// ---------------------------------------------------------------------------
// The scrape
// ---------------------------------------------------------------------------

test_scrape_wire :: proc(t: ^T) {
	tsection(t, "the scrape (BEP 15 over UDP, BEP 48 over HTTP)")

	h1, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	h2, _ := hash20_from_hex("aabbccddeeff00112233445566778899aabbccdd")

	pkt, perr := udp_scrape_packet(0x1122334455667788, 0xFEEDFACE, {h1, h2}, context.temp_allocator)
	teq(t, "a scrape packet is built", perr, "")
	teq_int(t, "...and is 16 + 20 per hash", len(pkt), 16 + 40)
	tcheck(t, "it carries the connection id", be_u64(pkt[0:8]) == 0x1122334455667788)
	teq_int(t, "action 2 is scrape", int(be_u32(pkt[8:12])), 2)
	tcheck(t, "it carries the transaction id", be_u32(pkt[12:16]) == 0xFEEDFACE)
	h1v, h2v := h1, h2
	tcheck(t, "the first info-hash is 20 raw bytes at offset 16", slice.equal(pkt[16:36], h1v[:]))
	tcheck(t, "the second follows immediately at 36", slice.equal(pkt[36:56], h2v[:]))

	_, zerr := udp_scrape_packet(1, 2, {}, context.temp_allocator)
	tcheck(t, "a scrape with no info-hash is refused", zerr != "")
	many := make([]Hash20, UDP_SCRAPE_MAX + 1, context.temp_allocator)
	_, merr := udp_scrape_packet(1, 2, many, context.temp_allocator)
	tcheck(t, "a scrape of more than 74 info-hashes is refused", merr != "", merr)

	// The answer. The middle counter is `downloaded`, which is the one
	// everybody puts last.
	ans := make([dynamic]u8, 0, 32, context.temp_allocator)
	append_be_u32(&ans, 2) // action: scrape
	append_be_u32(&ans, 0xFEEDFACE)
	append_be_u32(&ans, 5) // complete   (seeders)
	append_be_u32(&ans, 91) // downloaded (ever)
	append_be_u32(&ans, 13) // incomplete (leechers)
	append_be_u32(&ans, 0)
	append_be_u32(&ans, 0)
	append_be_u32(&ans, 1)
	out, aerr := udp_parse_scrape(ans[:], 0xFEEDFACE, {h1, h2}, context.temp_allocator)
	teq(t, "the scrape answer parses", aerr, "")
	teq_int(t, "...with one entry per hash asked about", len(out), 2)
	teq_int(t, "5 seeders", out[0].complete, 5)
	teq_int(t, "91 completions, from the MIDDLE counter", out[0].downloaded, 91)
	teq_int(t, "13 leechers, from the last", out[0].incomplete, 13)
	tcheck(
		t,
		"the entries are matched to the hashes BY POSITION — the reply carries none",
		hash20_eq(out[0].info_hash, h1) && hash20_eq(out[1].info_hash, h2),
	)
	teq_int(t, "a torrent the tracker never heard of is zeros, not an omission", out[1].complete, 0)
	teq_int(t, "...and its leechers are the 1 in the last slot", out[1].incomplete, 1)

	_, terr := udp_parse_scrape(ans[:], 0x11111111, {h1, h2}, context.temp_allocator)
	tcheck(t, "a mismatched transaction id is refused", terr != "")
	_, rerr := udp_parse_scrape(ans[:len(ans) - 1], 0xFEEDFACE, {h1, h2}, context.temp_allocator)
	tcheck(t, "a body that is not a multiple of 12 is refused", rerr != "")
	_, oerr := udp_parse_scrape(ans[:], 0xFEEDFACE, {h1}, context.temp_allocator)
	tcheck(t, "an answer about more torrents than were asked about is refused", oerr != "", oerr)
	eans := make([dynamic]u8, 0, 16, context.temp_allocator)
	append_be_u32(&eans, 3) // error
	append_be_u32(&eans, 0xFEEDFACE)
	append(&eans, ..transmute([]u8)string("no such torrent"))
	_, xerr := udp_parse_scrape(eans[:], 0xFEEDFACE, {h1}, context.temp_allocator)
	tcheck(t, "an error action is refused", xerr != "")
	tcheck(t, "...and the tracker's words are reported", strings.contains(xerr, "no such torrent"), xerr)

	// The URL rewrite (BEP 48).
	s1, e1 := scrape_url_of("http://127.0.0.1:6969/announce", context.temp_allocator)
	teq(t, "an announce URL becomes a scrape URL", e1, "")
	teq(t, "...by replacing the last path component", s1, "http://127.0.0.1:6969/scrape")
	s2, e2 := scrape_url_of("http://127.0.0.1:6969/tr/announce?x=1", context.temp_allocator)
	teq(t, "a query string survives", e2, "")
	teq(t, "...and only the last component is replaced", s2, "http://127.0.0.1:6969/tr/scrape?x=1")
	_, e3 := scrape_url_of("http://127.0.0.1:6969/anno", context.temp_allocator)
	tcheck(
		t,
		"a path that does not end in `announce` has NO scrape endpoint and is not guessed at",
		e3 != "",
		e3,
	)
	s4, e4 := scrape_url_of("udp://127.0.0.1:6969/announce", context.temp_allocator)
	teq(t, "a UDP tracker's scrape is the same endpoint", e4, "")
	teq(t, "...unchanged", s4, "udp://127.0.0.1:6969/announce")

	// The bencoded HTTP form.
	body := ben_encode(
		bdict(
			{
				bp(
					"files",
					Ben {
						kind = .Dict,
						dict = {
							Ben_Pair {
								key = h1v[:],
								val = bdict(
									{
										bp("complete", bnum(2)),
										bp("downloaded", bnum(44)),
										bp("incomplete", bnum(3)),
									},
									context.temp_allocator,
								),
							},
						},
					},
				),
			},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
	hs, herr := scrape_parse(body, context.temp_allocator)
	teq(t, "an HTTP scrape parses", herr, "")
	teq_int(t, "...with one file", len(hs), 1)
	tcheck(t, "...keyed by the RAW 20-byte info-hash", hash20_eq(hs[0].info_hash, h1))
	teq_int(t, "...2 seeders", hs[0].complete, 2)
	teq_int(t, "...44 completions", hs[0].downloaded, 44)
	teq_int(t, "...3 leechers", hs[0].incomplete, 3)
}

// ---------------------------------------------------------------------------
// The loopback fixture peer
// ---------------------------------------------------------------------------

Meta_Fixture :: struct {
	listener:      Sock,
	port:          int,
	info:          []u8,
	info_hash:     Hash20,
	peer_id:       [20]u8,

	// How the fixture behaves.
	serve_ext_id:  int, // the ut_metadata id IT registers (deliberately not 2)
	offer_pex:     bool,
	corrupt:       bool, // serve bytes that do not hash to the info-hash
	lie_size:      int, // if non-zero, claim this metadata_size instead
	reject_all:    bool,

	// What it saw.
	mu:            sync.Mutex,
	saw_reserved:  [8]u8,
	saw_ext_hs:    []u8,
	saw_requests:  [dynamic]int,
	saw_ext_ids:   [dynamic]int,
	saw_pex_msgs:  int,
	served:        int,
	ran:           bool,
	note:          string,
}

fixture_start :: proc(fx: ^Meta_Fixture) -> (err: string) {
	l, bound, lerr := sock_listen("127.0.0.1", 0)
	if lerr != "" {
		return lerr
	}
	fx.listener = l
	fx.port = bound
	fx.saw_requests = make([dynamic]int, 0, 8)
	fx.saw_ext_ids = make([dynamic]int, 0, 8)
	if fx.serve_ext_id == 0 {
		fx.serve_ext_id = 7
	}
	copy(fx.peer_id[:], "-FX0001-fixturepeer!")
	return ""
}

fixture_destroy :: proc(fx: ^Meta_Fixture) {
	sock_close(fx.listener)
	delete(fx.saw_requests)
	delete(fx.saw_ext_ids)
	delete(fx.saw_ext_hs)
	delete(fx.note)
}

// fixture_serve runs on its own thread: accept one connection, speak the
// protocol, hang up.
fixture_serve :: proc(th: ^thread.Thread) {
	fx := (^Meta_Fixture)(th.data)
	deadline := now_s() + 15.0

	s: Sock = SOCK_INVALID
	for now_s() < deadline {
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(fx.listener), events = {.IN}}}
		if poll_wait(fds[:], 100) > 0 {
			c, _, _, ok := sock_accept(fx.listener)
			if ok {
				s = c
				break
			}
		}
	}
	if s == SOCK_INVALID {
		sync.lock(&fx.mu)
		fx.note = strings.clone("the fixture never saw a connection")
		sync.unlock(&fx.mu)
		return
	}
	defer sock_close(s)

	f: Framer
	framer_init(&f)
	defer framer_destroy(&f)
	out := make([dynamic]u8, 0, 4096)
	defer delete(out)

	size := len(fx.info)
	if fx.lie_size > 0 {
		size = fx.lie_size
	}
	shook := false
	sent_ext := false
	buf: [32 * 1024]u8

	for now_s() < deadline {
		// Write whatever is queued.
		for len(out) > 0 {
			n, st := sock_write(s, out[:])
			if st == .Ok {
				remove_range(&out, 0, n)
				continue
			}
			if st == .Again {
				break
			}
			return
		}
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(s), events = {.IN}}}
		poll_wait(fds[:], 50)
		for {
			n, st := sock_read(s, buf[:])
			if st != .Ok {
				break
			}
			framer_feed(&f, buf[:n])
			if n < len(buf) {
				break
			}
		}

		if !shook {
			h, st := framer_take_handshake(&f, fx.info_hash)
			if st == .Bad {
				return
			}
			if st == .Incomplete {
				framer_compact(&f)
				continue
			}
			shook = true
			sync.lock(&fx.mu)
			fx.saw_reserved = h.reserved
			sync.unlock(&fx.mu)
			hs := handshake_encode(fx.info_hash, fx.peer_id, context.temp_allocator, extended = true)
			append(&out, ..hs)
		}

		if shook && !sent_ext {
			pairs := make([dynamic]Ben_Pair, 0, 2, context.temp_allocator)
			append(&pairs, bp("ut_metadata", bnum(i64(fx.serve_ext_id))))
			if fx.offer_pex {
				// A peer offering peer exchange. This client must register
				// nothing for it and must never send on this id.
				append(&pairs, bp("ut_pex", bnum(1)))
			}
			body := make([dynamic]Ben_Pair, 0, 3, context.temp_allocator)
			append(&body, bp("m", bdict(pairs[:], context.temp_allocator)))
			append(&body, bp("metadata_size", bnum(i64(size))))
			append(&body, bp("v", bstr("fixture 0.1")))
			msg_extended(
				&out,
				EXT_HANDSHAKE_ID,
				ben_encode(bdict(body[:], context.temp_allocator), context.temp_allocator),
			)
			sent_ext = true
		}

		for {
			m, st := framer_next(&f)
			if st == .Incomplete {
				break
			}
			if st == .Bad {
				return
			}
			if m.id != .Extended || len(m.payload) < 1 {
				continue
			}
			eid := int(m.payload[0])
			sync.lock(&fx.mu)
			append(&fx.saw_ext_ids, eid)
			if fx.offer_pex && eid == 1 {
				fx.saw_pex_msgs += 1
			}
			sync.unlock(&fx.mu)

			if eid == int(EXT_HANDSHAKE_ID) {
				sync.lock(&fx.mu)
				delete(fx.saw_ext_hs)
				fx.saw_ext_hs = clone_bytes(m.payload[1:])
				sync.unlock(&fx.mu)
				continue
			}
			if eid != fx.serve_ext_id {
				continue
			}
			um, uerr := ut_metadata_parse(m.payload[1:])
			if uerr != "" || um.type != .Request {
				continue
			}
			sync.lock(&fx.mu)
			append(&fx.saw_requests, um.piece)
			sync.unlock(&fx.mu)
			if fx.reject_all {
				msg_extended(
					&out,
					u8(UT_METADATA_LOCAL_ID),
					ut_metadata_reject_payload(um.piece, context.temp_allocator),
				)
				continue
			}
			lo, hi, ok := metadata_piece_span(len(fx.info), um.piece)
			if !ok {
				continue
			}
			chunk := fx.info[lo:hi]
			if fx.corrupt {
				c := clone_bytes(chunk, context.temp_allocator)
				c[0] ~= 0xff
				chunk = c
			}
			// Answer on the id the CLIENT registered, which is
			// UT_METADATA_LOCAL_ID. A fixture that answered on its own id
			// would be testing nothing.
			msg_extended(
				&out,
				u8(UT_METADATA_LOCAL_ID),
				ut_metadata_data_payload(um.piece, len(fx.info), chunk, context.temp_allocator),
			)
			sync.lock(&fx.mu)
			fx.served += 1
			sync.unlock(&fx.mu)
		}
		free_all(context.temp_allocator)
	}
	sync.lock(&fx.mu)
	fx.ran = true
	sync.unlock(&fx.mu)
}

// ---------------------------------------------------------------------------
// BEP 9 against the fixture
// ---------------------------------------------------------------------------

test_metadata_loopback :: proc(t: ^T) {
	tsection(t, "BEP 9 against a loopback fixture peer")

	info := fixture_info_bytes(context.allocator)
	defer delete(info)
	ih := sha1_of(info)
	pid := peer_id_new(4242)

	// --- the happy path, with the fixture ALSO offering peer exchange -------
	{
		fx := Meta_Fixture {
			info      = info,
			info_hash = ih,
			offer_pex = true,
		}
		if !tcheck(t, "the fixture peer binds 127.0.0.1", fixture_start(&fx) == "") {
			return
		}
		defer fixture_destroy(&fx)
		th := thread.create(fixture_serve)
		th.data = &fx
		thread.start(th)
		defer {
			thread.join(th)
			thread.destroy(th)
		}

		trace: Metafetch_Trace
		got, gerr := metadata_fetch_from_peer(
			"127.0.0.1",
			fx.port,
			ih,
			pid,
			5000,
			context.temp_allocator,
			&trace,
		)
		teq(t, "the metadata is fetched over the wire", gerr, "")
		tcheck(t, "...and verified against the magnet's own info-hash", trace.verified)
		tcheck(
			t,
			"...and the bytes are the fixture's info dictionary, byte for byte",
			slice.equal(got, info),
			asprint("%d bytes against %d", len(got), len(info)),
		)
		teq_int(t, "...in three metadata pieces", trace.pieces, 3)
		teq_int(t, "...requested three times", trace.requests_sent, 3)

		sync.lock(&fx.mu)
		reserved := fx.saw_reserved
		ext_hs := clone_bytes(fx.saw_ext_hs, context.temp_allocator)
		reqs := slice.clone(fx.saw_requests[:], context.temp_allocator)
		ids := slice.clone(fx.saw_ext_ids[:], context.temp_allocator)
		pex := fx.saw_pex_msgs
		served := fx.served
		sync.unlock(&fx.mu)

		// What THIS CLIENT put on the wire, read back off the fixture.
		teq_int(t, "the client's handshake set reserved[5] = 0x10", int(reserved[5]), 0x10)
		tcheck(
			t,
			"...and left the DHT bit clear",
			reserved[7] & 0x01 == 0,
			"the fixture saw the actual bytes, not our encoder",
		)
		tbytes(
			t,
			"the client's extension handshake, as the fixture received it",
			ext_hs,
			"d1:md11:ut_metadatai2ee1:v11:palmy 1.0.0e",
		)
		tcheck(
			t,
			"the fixture OFFERED ut_pex and the client registered it anyway? no",
			!strings.contains(string(ext_hs), "ut_pex"),
			string(ext_hs),
		)
		teq_int(t, "the client never sent a single peer-exchange message", pex, 0)
		tints(t, "it asked for pieces 0, 1, 2 in order", reqs, {0, 1, 2})
		teq_int(t, "the fixture served three pieces", served, 3)
		// Every extended message the client sent went out on an id the
		// fixture registered: 0 for the handshake, then the fixture's own 7.
		all_known := true
		for id in ids {
			if id != 0 && id != fx.serve_ext_id {
				all_known = false
			}
		}
		tcheck(
			t,
			"every extended message went out on an id THE FIXTURE registered, not on ours",
			all_known,
			asprint("%v, with the fixture's ut_metadata id being %d", ids, fx.serve_ext_id),
		)
		tcheck(
			t,
			"...and the fixture's id is deliberately not 2, so a client reading its own `m` would fail here",
			fx.serve_ext_id != int(UT_METADATA_LOCAL_ID),
		)
		teq_int(t, "the peer's ut_metadata id was read back correctly", trace.peer_ut_metadata, fx.serve_ext_id)
		tcheck(t, "...and its ut_pex offer was noticed and ignored", trace.peer_offered_pex)
	}

	// --- a peer that sends the wrong bytes ----------------------------------
	{
		fx := Meta_Fixture {
			info      = info,
			info_hash = ih,
			corrupt   = true,
		}
		if !tcheck(t, "a second fixture binds", fixture_start(&fx) == "") {
			return
		}
		defer fixture_destroy(&fx)
		th := thread.create(fixture_serve)
		th.data = &fx
		thread.start(th)
		defer {
			thread.join(th)
			thread.destroy(th)
		}
		got, gerr := metadata_fetch_from_peer("127.0.0.1", fx.port, ih, pid, 5000, context.temp_allocator)
		tcheck(
			t,
			"A PEER THAT SENDS THE WRONG BYTES IS REFUSED",
			gerr != "",
			"this is the only check between a stranger's bytes and a torrent we would act on",
		)
		tcheck(t, "...and nothing is returned", len(got) == 0)
		tcheck(t, "...and the error names both hashes", strings.contains(gerr, "hashes to"), gerr)
	}

	// --- a peer that refuses ------------------------------------------------
	{
		fx := Meta_Fixture {
			info       = info,
			info_hash  = ih,
			reject_all = true,
		}
		if !tcheck(t, "a third fixture binds", fixture_start(&fx) == "") {
			return
		}
		defer fixture_destroy(&fx)
		th := thread.create(fixture_serve)
		th.data = &fx
		thread.start(th)
		defer {
			thread.join(th)
			thread.destroy(th)
		}
		_, gerr := metadata_fetch_from_peer("127.0.0.1", fx.port, ih, pid, 5000, context.temp_allocator)
		tcheck(t, "a peer that rejects every piece is reported, not retried forever", gerr != "", gerr)
	}

	// --- the gate still applies ---------------------------------------------
	{
		_, gerr := metadata_fetch_from_peer("8.8.8.8", 6881, ih, pid, 500, context.temp_allocator)
		tcheck(
			t,
			"a BEP 9 fetch from a ROUTABLE address is refused before a socket exists",
			gerr != "",
			gerr,
		)
		tcheck(t, "...by the loopback gate", strings.contains(gerr, "not loopback"), gerr)
		_, nerr := metadata_fetch_from_peer("router.bittorrent.com", 6881, ih, pid, 500, context.temp_allocator)
		tcheck(t, "...and a NAME is refused without a lookup", nerr != "", nerr)
	}

	// --- a magnet with no trackers has nowhere to ask -----------------------
	{
		mg := Magnet {
			info_hash = ih,
			have_hash = true,
		}
		res, rerr := magnet_resolve(mg, pid, 0, 500, context.temp_allocator)
		tcheck(
			t,
			"a magnet with no trackers is NOT resolved by looking for a stranger",
			rerr != "",
			rerr,
		)
		tcheck(t, "...and says why", strings.contains(rerr, "names no trackers"), rerr)
		magnet_resolution_destroy(&res, context.temp_allocator)
	}
	time.sleep(1 * time.Millisecond)
}
