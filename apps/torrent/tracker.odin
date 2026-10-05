package main

// The tracker client: HTTP announce (BEP 3) and UDP announce (BEP 15).
//
// The announce is where a client says who it is and what it has, and gets back
// a list of peers and how long to wait before asking again. The three things
// that have to be exactly right:
//
//   * `info_hash` and `peer_id` are raw bytes, percent-encoded as bytes. See
//     the header of http.odin; this is the classic bug.
//   * `left` is how many bytes of the pieces we *want* are still missing, and
//     a tracker uses `left == 0` to decide you are a seeder. Reporting it
//     wrong means you are counted in the wrong half of the swarm.
//   * `interval` is not advice. Announcing more often than it says is how a
//     client gets its IP banned by a real tracker. It is honoured here even
//     though the only tracker this client can reach is one it started itself.
//
// `event` is sent once each: `started` on the first announce, `completed` the
// moment the last piece verifies, `stopped` on the way out — and `stopped` is
// the one everybody forgets, which is why trackers show swarms full of peers
// that left hours ago.

import "core:strings"

Announce_Event :: enum {
	None,
	Started,
	Completed,
	Stopped,
}

announce_event_name :: proc(e: Announce_Event) -> string {
	switch e {
	case .None:
		return ""
	case .Started:
		return "started"
	case .Completed:
		return "completed"
	case .Stopped:
		return "stopped"
	}
	return ""
}

Announce_Req :: struct {
	info_hash:  Hash20,
	peer_id:    [20]u8,
	port:       int,
	uploaded:   i64,
	downloaded: i64,
	left:       i64,
	event:      Announce_Event,
	numwant:    int,
	key:        u32,
	tracker_id: string,
}

Announce_Resp :: struct {
	interval:     int,
	min_interval: int,
	complete:     int, // seeders
	incomplete:   int, // leechers
	peers:        []Peer_Addr,
	tracker_id:   string,
	failure:      string,
	warning:      string,
}

announce_resp_destroy :: proc(r: ^Announce_Resp) {
	for p in r.peers {
		delete(p.host)
	}
	delete(r.peers)
	delete(r.tracker_id)
	delete(r.failure)
	delete(r.warning)
	r^ = {}
}

// ---------------------------------------------------------------------------
// The HTTP announce
// ---------------------------------------------------------------------------

// announce_query builds the query string. Separated from the request so the
// encoding can be asserted without a socket.
announce_query :: proc(
	base_target: string,
	req: Announce_Req,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, base_target)
	strings.write_byte(&b, strings.index_byte(base_target, '?') >= 0 ? '&' : '?')

	ih := req.info_hash
	pid := req.peer_id
	strings.write_string(&b, "info_hash=")
	strings.write_string(&b, url_encode_bytes(ih[:], context.temp_allocator))
	strings.write_string(&b, "&peer_id=")
	strings.write_string(&b, url_encode_bytes(pid[:], context.temp_allocator))
	strings.write_string(&b, "&port=")
	strings.write_int(&b, req.port)
	strings.write_string(&b, "&uploaded=")
	strings.write_i64(&b, req.uploaded)
	strings.write_string(&b, "&downloaded=")
	strings.write_i64(&b, req.downloaded)
	strings.write_string(&b, "&left=")
	strings.write_i64(&b, req.left)
	// compact=1 asks for the 6-bytes-per-peer form; no_peer_id goes with it.
	strings.write_string(&b, "&compact=1&no_peer_id=1&supportcrypto=0")
	strings.write_string(&b, "&numwant=")
	strings.write_int(&b, req.numwant <= 0 ? 50 : req.numwant)
	strings.write_string(&b, "&key=")
	strings.write_uint(&b, uint(req.key))
	if ev := announce_event_name(req.event); ev != "" {
		strings.write_string(&b, "&event=")
		strings.write_string(&b, ev)
	}
	if req.tracker_id != "" {
		strings.write_string(&b, "&trackerid=")
		strings.write_string(&b, url_encode(req.tracker_id, context.temp_allocator))
	}
	return strings.to_string(b)
}

// announce_parse reads a bencoded tracker response.
announce_parse :: proc(
	body: []u8,
	allocator := context.allocator,
) -> (
	r: Announce_Resp,
	err: string,
) {
	root, derr := ben_decode(body, context.temp_allocator)
	if derr != "" {
		return {}, tsprint("the tracker's answer is not bencoded: %s", derr)
	}
	if root.kind != .Dict {
		return {}, "the tracker's answer is not a dictionary"
	}
	if f, ok := ben_str_of(root, "failure reason"); ok {
		r.failure = strings.clone(f, allocator)
		return r, ""
	}
	if w, ok := ben_str_of(root, "warning message"); ok {
		r.warning = strings.clone(w, allocator)
	}
	if v, ok := ben_int_of(root, "interval"); ok {
		r.interval = int(v)
	}
	if v, ok := ben_int_of(root, "min interval"); ok {
		r.min_interval = int(v)
	}
	if v, ok := ben_int_of(root, "complete"); ok {
		r.complete = int(v)
	}
	if v, ok := ben_int_of(root, "incomplete"); ok {
		r.incomplete = int(v)
	}
	if v, ok := ben_str_of(root, "tracker id"); ok {
		r.tracker_id = strings.clone(v, allocator)
	}
	// `peers` is either the compact byte string or the old list of
	// dictionaries. Both are real; a client that only reads one of them fails
	// against half the trackers in existence.
	if pv, ok := ben_get(root, "peers"); ok {
		switch pv.kind {
		case .Str:
			peers, perr := parse_compact_peers(pv.str, allocator)
			if perr != "" {
				return r, perr
			}
			r.peers = peers
		case .List:
			out := make([dynamic]Peer_Addr, 0, len(pv.list), allocator)
			for e in pv.list {
				if e.kind != .Dict {
					continue
				}
				ip, iok := ben_str_of(e, "ip")
				port, pok := ben_int_of(e, "port")
				if !iok || !pok || port <= 0 || port > 65535 {
					continue
				}
				append(&out, Peer_Addr{host = strings.clone(ip, allocator), port = int(port)})
			}
			r.peers = out[:]
		case .Int, .Dict:
			return r, "the tracker's `peers` is neither a string nor a list"
		}
	}
	if r.interval <= 0 {
		r.interval = 1800
	}
	return r, ""
}

// tracker_announce_http performs the announce. `url` is the tracker URL from
// the metainfo; a URL naming a real host is refused by the gate inside
// `http_get` before any socket exists.
tracker_announce_http :: proc(
	url: string,
	req: Announce_Req,
	timeout_ms: i32 = 5000,
	allocator := context.allocator,
) -> (
	r: Announce_Resp,
	err: string,
) {
	u, uerr := url_split(url)
	if uerr != "" {
		return {}, uerr
	}
	if u.scheme != "http" {
		return {}, tsprint("%s is not an HTTP tracker", url)
	}
	target := announce_query(u.target, req, context.temp_allocator)
	status, body, gerr := http_get(u.host, u.port, target, timeout_ms, context.temp_allocator)
	if gerr != "" {
		return {}, gerr
	}
	if status != 200 {
		return {}, tsprint("the tracker answered HTTP %d", status)
	}
	return announce_parse(body, allocator)
}

// ---------------------------------------------------------------------------
// The UDP announce (BEP 15)
// ---------------------------------------------------------------------------
//
// UDP has no connection, so the protocol invents one: a `connect` exchange
// returns a 64-bit connection id valid for a minute, and every later packet
// carries it. Each request carries a random 32-bit transaction id and the
// answer must echo it — that is the whole anti-spoofing story, since a
// datagram's source address is not evidence of anything.

UDP_PROTOCOL_ID :: u64(0x41727101980)

Udp_Action :: enum u32 {
	Connect  = 0,
	Announce = 1,
	Scrape   = 2,
	Error    = 3,
}

// udp_connect_packet is 16 bytes: the magic protocol id, action 0, and the
// transaction id.
udp_connect_packet :: proc(txn: u32) -> [16]u8 {
	out: [16]u8
	put_be_u64(out[0:8], UDP_PROTOCOL_ID)
	put_be_u32(out[8:12], u32(Udp_Action.Connect))
	put_be_u32(out[12:16], txn)
	return out
}

udp_parse_connect :: proc(pkt: []u8, want_txn: u32) -> (conn_id: u64, err: string) {
	// The action and transaction id come first and are checked first: an error
	// answer is shorter than a connect answer, and refusing it for its length
	// would hide what the tracker said.
	if len(pkt) < 8 {
		return 0, tsprint("a connect answer of %d bytes is too short", len(pkt))
	}
	action := be_u32(pkt[0:4])
	txn := be_u32(pkt[4:8])
	if txn != want_txn {
		return 0, tsprint("connect answer has transaction id %d, expected %d", txn, want_txn)
	}
	if Udp_Action(action) == .Error {
		return 0, tsprint("the tracker refused the connect: %s", string(pkt[8:]))
	}
	if Udp_Action(action) != .Connect {
		return 0, tsprint("connect answer has action %d, expected 0", action)
	}
	if len(pkt) < 16 {
		return 0, tsprint("a connect answer of %d bytes carries no connection id", len(pkt))
	}
	return be_u64(pkt[8:16]), ""
}

// udp_announce_packet is the fixed 98-byte announce.
udp_announce_packet :: proc(conn_id: u64, txn: u32, req: Announce_Req, ip: u32 = 0) -> [98]u8 {
	out: [98]u8
	ih := req.info_hash
	pid := req.peer_id
	put_be_u64(out[0:8], conn_id)
	put_be_u32(out[8:12], u32(Udp_Action.Announce))
	put_be_u32(out[12:16], txn)
	copy(out[16:36], ih[:])
	copy(out[36:56], pid[:])
	put_be_u64(out[56:64], u64(req.downloaded))
	put_be_u64(out[64:72], u64(req.left))
	put_be_u64(out[72:80], u64(req.uploaded))
	// The event numbering is its own thing: 0 none, 1 completed, 2 started,
	// 3 stopped. It is NOT the order of the HTTP event names, and swapping
	// started and completed is a quiet way to tell a tracker you have finished
	// a download you just began.
	ev: u32 = 0
	switch req.event {
	case .None:
		ev = 0
	case .Completed:
		ev = 1
	case .Started:
		ev = 2
	case .Stopped:
		ev = 3
	}
	put_be_u32(out[80:84], ev)
	put_be_u32(out[84:88], ip) // 0 = "use the source address"
	put_be_u32(out[88:92], req.key)
	// numwant is signed: -1 means "the default".
	nw := req.numwant <= 0 ? u32(0xffffffff) : u32(req.numwant)
	put_be_u32(out[92:96], nw)
	put_be_u16(out[96:98], u16(req.port))
	return out
}

udp_parse_announce :: proc(
	pkt: []u8,
	want_txn: u32,
	allocator := context.allocator,
) -> (
	r: Announce_Resp,
	err: string,
) {
	if len(pkt) < 8 {
		return {}, tsprint("an announce answer of %d bytes is too short", len(pkt))
	}
	action := be_u32(pkt[0:4])
	txn := be_u32(pkt[4:8])
	if txn != want_txn {
		return {}, tsprint("announce answer has transaction id %d, expected %d", txn, want_txn)
	}
	if Udp_Action(action) == .Error {
		return {}, tsprint("the tracker refused the announce: %s", string(pkt[8:]))
	}
	if Udp_Action(action) != .Announce {
		return {}, tsprint("announce answer has action %d, expected 1", action)
	}
	if len(pkt) < 20 {
		return {}, "the announce answer has no header"
	}
	r.interval = int(be_u32(pkt[8:12]))
	r.incomplete = int(be_u32(pkt[12:16]))
	r.complete = int(be_u32(pkt[16:20]))
	peers, perr := parse_compact_peers(pkt[20:], allocator)
	if perr != "" {
		return r, perr
	}
	r.peers = peers
	if r.interval <= 0 {
		r.interval = 1800
	}
	return r, ""
}

// tracker_announce_udp does the two-step exchange. One retry, because a lost
// datagram is normal and a single timeout is not evidence the tracker is gone.
tracker_announce_udp :: proc(
	url: string,
	req: Announce_Req,
	timeout_ms: i32 = 3000,
	allocator := context.allocator,
) -> (
	r: Announce_Resp,
	err: string,
) {
	u, uerr := url_split(url)
	if uerr != "" {
		return {}, uerr
	}
	if u.scheme != "udp" {
		return {}, tsprint("%s is not a UDP tracker", url)
	}
	sock: Udp
	if oerr := udp_open(&sock, "127.0.0.1", 0); oerr != "" {
		return {}, oerr
	}
	defer udp_close(&sock)

	x := xs_init(u64(unix_now()) ~ u64(uintptr(rawptr(&sock))))
	buf := make([]u8, 2048, context.temp_allocator)

	conn_id: u64
	got_conn := false
	for attempt in 0 ..< 2 {
		txn := u32(xs_next(&x))
		pkt := udp_connect_packet(txn)
		if serr := udp_send_to(&sock, u.host, u.port, pkt[:]); serr != "" {
			return {}, serr
		}
		n, _, _, ok := udp_recv(&sock, buf, timeout_ms)
		if !ok {
			continue
		}
		id, cerr := udp_parse_connect(buf[:n], txn)
		if cerr != "" {
			if attempt == 1 {
				return {}, cerr
			}
			continue
		}
		conn_id = id
		got_conn = true
		break
	}
	if !got_conn {
		return {}, tsprint("the UDP tracker at %s:%d never answered a connect", u.host, u.port)
	}

	for attempt in 0 ..< 2 {
		txn := u32(xs_next(&x))
		pkt := udp_announce_packet(conn_id, txn, req)
		if serr := udp_send_to(&sock, u.host, u.port, pkt[:]); serr != "" {
			return {}, serr
		}
		n, _, _, ok := udp_recv(&sock, buf, timeout_ms)
		if !ok {
			continue
		}
		resp, aerr := udp_parse_announce(buf[:n], txn, allocator)
		if aerr != "" {
			if attempt == 1 {
				return {}, aerr
			}
			continue
		}
		return resp, ""
	}
	return {}, tsprint("the UDP tracker at %s:%d never answered an announce", u.host, u.port)
}

// tracker_announce dispatches on the URL's scheme.
tracker_announce :: proc(
	url: string,
	req: Announce_Req,
	timeout_ms: i32 = 5000,
	allocator := context.allocator,
) -> (
	r: Announce_Resp,
	err: string,
) {
	u, uerr := url_split(url)
	if uerr != "" {
		return {}, uerr
	}
	switch u.scheme {
	case "http":
		return tracker_announce_http(url, req, timeout_ms, allocator)
	case "udp":
		return tracker_announce_udp(url, req, timeout_ms, allocator)
	}
	return {}, tsprint("unsupported tracker scheme %q", u.scheme)
}

// ---------------------------------------------------------------------------
// Scrape (BEP 15 over UDP, BEP 48 over HTTP)
// ---------------------------------------------------------------------------
//
// An announce says "here I am, who else is there" and changes the tracker's
// idea of the swarm. A scrape asks only "how many" and changes nothing. That
// difference is the whole reason it exists: a client that wants to show swarm
// counts for twenty torrents it is not downloading can ask once, cheaply,
// without being counted in twenty swarms it is not in.
//
// Over UDP it is action 2 on the same connection id an announce uses: a
// 16-byte header followed by 20 raw bytes per info-hash, up to 74 of them,
// because 74 is what fits in a 1500-byte MTU alongside the header and a
// tracker is entitled to drop a datagram that fragments. The answer is a
// 8-byte header and then 12 bytes per hash, IN THE ORDER ASKED — there are no
// hashes in the reply, so a client that reorders its request loses track of
// which count belongs to which torrent.
//
// The three counters are, in wire order: `complete` (seeders now), `downloaded`
// (times the swarm has been completed, ever) and `incomplete` (leechers now).
// `downloaded` sitting in the middle is the trap; reading them as
// complete/incomplete/downloaded gives a plausible-looking answer that is
// wrong about two of the three.

// The cap from BEP 15. A client asking for more is asking for a truncated
// datagram.
UDP_SCRAPE_MAX :: 74

Scrape_Entry :: struct {
	info_hash:  Hash20,
	complete:   int, // seeders
	downloaded: int, // completed, ever
	incomplete: int, // leechers
}

// udp_scrape_packet is 16 bytes of header and then the hashes, raw.
udp_scrape_packet :: proc(
	conn_id: u64,
	txn: u32,
	hashes: []Hash20,
	allocator := context.allocator,
) -> (
	pkt: []u8,
	err: string,
) {
	if len(hashes) == 0 {
		return nil, "a scrape with no info-hash asks nothing"
	}
	if len(hashes) > UDP_SCRAPE_MAX {
		return nil, tsprint(
			"a UDP scrape carries at most %d info-hashes; %d were asked for",
			UDP_SCRAPE_MAX,
			len(hashes),
		)
	}
	out := make([dynamic]u8, 0, 16 + 20 * len(hashes), allocator)
	append_be_u64(&out, conn_id)
	append_be_u32(&out, u32(Udp_Action.Scrape))
	append_be_u32(&out, txn)
	for h in hashes {
		hh := h
		append(&out, ..hh[:])
	}
	return out[:], ""
}

// udp_parse_scrape reads the answer. `asked` is the list that was sent, in the
// order it was sent, because the reply carries no hashes of its own.
udp_parse_scrape :: proc(
	pkt: []u8,
	want_txn: u32,
	asked: []Hash20,
	allocator := context.allocator,
) -> (
	out: []Scrape_Entry,
	err: string,
) {
	if len(pkt) < 8 {
		return nil, tsprint("a scrape answer of %d bytes is too short", len(pkt))
	}
	action := be_u32(pkt[0:4])
	txn := be_u32(pkt[4:8])
	if txn != want_txn {
		return nil, tsprint("scrape answer has transaction id %d, expected %d", txn, want_txn)
	}
	if Udp_Action(action) == .Error {
		return nil, tsprint("the tracker refused the scrape: %s", string(pkt[8:]))
	}
	if Udp_Action(action) != .Scrape {
		return nil, tsprint("scrape answer has action %d, expected 2", action)
	}
	body := pkt[8:]
	if len(body) % 12 != 0 {
		return nil, tsprint("a scrape answer body of %d bytes is not a multiple of 12", len(body))
	}
	n := len(body) / 12
	// A tracker may answer about fewer torrents than were asked about — one it
	// has never heard of is simply absent — but never about more, and the ones
	// it does answer about are a prefix in the order asked.
	if n > len(asked) {
		return nil, tsprint("the tracker answered about %d torrents; %d were asked about", n, len(asked))
	}
	res := make([]Scrape_Entry, n, allocator)
	for i in 0 ..< n {
		b := body[i * 12:(i + 1) * 12]
		res[i] = Scrape_Entry {
			info_hash  = asked[i],
			complete   = int(be_u32(b[0:4])),
			downloaded = int(be_u32(b[4:8])),
			incomplete = int(be_u32(b[8:12])),
		}
	}
	return res, ""
}

// tracker_scrape_udp does connect-then-scrape, with the same one retry as the
// announce for the same reason: a lost datagram is normal.
tracker_scrape_udp :: proc(
	url: string,
	hashes: []Hash20,
	timeout_ms: i32 = 3000,
	allocator := context.allocator,
) -> (
	out: []Scrape_Entry,
	err: string,
) {
	u, uerr := url_split(url)
	if uerr != "" {
		return nil, uerr
	}
	if u.scheme != "udp" {
		return nil, tsprint("%s is not a UDP tracker", url)
	}
	sock: Udp
	if oerr := udp_open(&sock, "127.0.0.1", 0); oerr != "" {
		return nil, oerr
	}
	defer udp_close(&sock)

	x := xs_init(u64(unix_now()) ~ u64(uintptr(rawptr(&sock))) ~ 0x5c2a)
	buf := make([]u8, 2048, context.temp_allocator)

	conn_id: u64
	got_conn := false
	for attempt in 0 ..< 2 {
		txn := u32(xs_next(&x))
		pkt := udp_connect_packet(txn)
		if serr := udp_send_to(&sock, u.host, u.port, pkt[:]); serr != "" {
			return nil, serr
		}
		n, _, _, ok := udp_recv(&sock, buf, timeout_ms)
		if !ok {
			continue
		}
		id, cerr := udp_parse_connect(buf[:n], txn)
		if cerr != "" {
			if attempt == 1 {
				return nil, cerr
			}
			continue
		}
		conn_id = id
		got_conn = true
		break
	}
	if !got_conn {
		return nil, tsprint("the UDP tracker at %s:%d never answered a connect", u.host, u.port)
	}

	for attempt in 0 ..< 2 {
		txn := u32(xs_next(&x))
		pkt, perr := udp_scrape_packet(conn_id, txn, hashes, context.temp_allocator)
		if perr != "" {
			return nil, perr
		}
		if serr := udp_send_to(&sock, u.host, u.port, pkt); serr != "" {
			return nil, serr
		}
		n, _, _, ok := udp_recv(&sock, buf, timeout_ms)
		if !ok {
			continue
		}
		res, serr2 := udp_parse_scrape(buf[:n], txn, hashes, allocator)
		if serr2 != "" {
			if attempt == 1 {
				return nil, serr2
			}
			continue
		}
		return res, ""
	}
	return nil, tsprint("the UDP tracker at %s:%d never answered a scrape", u.host, u.port)
}

// scrape_url_of turns an announce URL into its scrape URL, the BEP 48 way: the
// LAST path component must be exactly `announce`, and only then is it replaced
// with `scrape`. A tracker whose path does not end in `announce` is declaring
// that it has no scrape endpoint, and guessing one at it is how a client gets
// a 404 on every torrent it shows.
scrape_url_of :: proc(url: string, allocator := context.allocator) -> (out: string, err: string) {
	u, uerr := url_split(url)
	if uerr != "" {
		return "", uerr
	}
	if u.scheme == "udp" {
		// UDP has no path to rewrite: a scrape is an action on the same
		// endpoint.
		return strings.clone(url, allocator), ""
	}
	q := strings.index_byte(u.target, '?')
	path := q >= 0 ? u.target[:q] : u.target
	query := q >= 0 ? u.target[q:] : ""
	slash := strings.last_index_byte(path, '/')
	if slash < 0 || path[slash + 1:] != "announce" {
		return "", tsprint("%s has no scrape endpoint: its path does not end in `announce`", url)
	}
	return asprint(
		"%s://%s:%d%s%s%s",
		u.scheme,
		u.host,
		u.port,
		path[:slash + 1],
		"scrape",
		query,
	), ""
}

// scrape_parse reads the bencoded answer of an HTTP scrape: a `files`
// dictionary keyed by the raw 20-byte info-hash.
scrape_parse :: proc(
	body: []u8,
	allocator := context.allocator,
) -> (
	out: []Scrape_Entry,
	err: string,
) {
	root, derr := ben_decode(body, context.temp_allocator)
	if derr != "" {
		return nil, tsprint("the tracker's scrape is not bencoded: %s", derr)
	}
	if root.kind != .Dict {
		return nil, "the tracker's scrape is not a dictionary"
	}
	if f, ok := ben_str_of(root, "failure reason"); ok {
		return nil, strings.clone(f, allocator)
	}
	files, has := ben_get(root, "files")
	if !has || files.kind != .Dict {
		return nil, "the tracker's scrape has no `files` dictionary"
	}
	res := make([dynamic]Scrape_Entry, 0, len(files.dict), allocator)
	for pair in files.dict {
		if len(pair.key) != 20 || pair.val.kind != .Dict {
			continue
		}
		e: Scrape_Entry
		copy(e.info_hash[:], pair.key)
		if v, ok := ben_int_of(pair.val, "complete"); ok {
			e.complete = int(v)
		}
		if v, ok := ben_int_of(pair.val, "downloaded"); ok {
			e.downloaded = int(v)
		}
		if v, ok := ben_int_of(pair.val, "incomplete"); ok {
			e.incomplete = int(v)
		}
		append(&res, e)
	}
	return res[:], ""
}

tracker_scrape_http :: proc(
	url: string,
	hashes: []Hash20,
	timeout_ms: i32 = 5000,
	allocator := context.allocator,
) -> (
	out: []Scrape_Entry,
	err: string,
) {
	surl, serr := scrape_url_of(url, context.temp_allocator)
	if serr != "" {
		return nil, serr
	}
	u, uerr := url_split(surl)
	if uerr != "" {
		return nil, uerr
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, u.target)
	first := strings.index_byte(u.target, '?') < 0
	for h in hashes {
		hh := h
		strings.write_byte(&b, first ? '?' : '&')
		first = false
		strings.write_string(&b, "info_hash=")
		strings.write_string(&b, url_encode_bytes(hh[:], context.temp_allocator))
	}
	status, body, gerr := http_get(
		u.host,
		u.port,
		strings.to_string(b),
		timeout_ms,
		context.temp_allocator,
	)
	if gerr != "" {
		return nil, gerr
	}
	if status != 200 {
		return nil, tsprint("the tracker answered HTTP %d to a scrape", status)
	}
	return scrape_parse(body, allocator)
}

// tracker_scrape dispatches on the announce URL's scheme.
tracker_scrape :: proc(
	url: string,
	hashes: []Hash20,
	timeout_ms: i32 = 5000,
	allocator := context.allocator,
) -> (
	out: []Scrape_Entry,
	err: string,
) {
	u, uerr := url_split(url)
	if uerr != "" {
		return nil, uerr
	}
	switch u.scheme {
	case "http":
		return tracker_scrape_http(url, hashes, timeout_ms, allocator)
	case "udp":
		return tracker_scrape_udp(url, hashes, timeout_ms, allocator)
	}
	return nil, tsprint("unsupported tracker scheme %q", u.scheme)
}
