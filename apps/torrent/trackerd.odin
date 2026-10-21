package main

// The tracker, served on loopback. `torrent --tracker` runs this.
//
// It exists because the end-to-end test needs a real tracker and this client is
// not allowed near a public one. It speaks the HTTP announce of BEP 3 and the
// UDP announce of BEP 15, keeps a swarm per info-hash, and answers compact peer
// lists. It also serves `/stats`, which the test reads to assert that both the
// seeder and the leecher really did announce — the tracker's own account of the
// exchange rather than the client's.
//
// It binds 127.0.0.1 and nothing else, through the same `sock_listen` gate the
// client uses. There is no configuration that would let it bind 0.0.0.0.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

TRACKER_INTERVAL :: 5 // seconds; short, because the test cannot wait 30 minutes
TRACKER_PEER_TTL :: 300.0 // a peer that has not announced in this long is dropped

Swarm_Peer :: struct {
	peer_id:    [20]u8,
	host:       string,
	port:       int,
	left:       i64,
	uploaded:   i64,
	downloaded: i64,
	seen:       f64,
	completed:  bool,
}

Swarm :: struct {
	info_hash: Hash20,
	peers:     [dynamic]Swarm_Peer,
	// Counters, for /stats.
	announces: int,
	started:   int,
	completed: int,
	stopped:   int,
}

Tracker_Conn :: struct {
	sock: Sock,
	buf:  [dynamic]u8,
	out:  [dynamic]u8,
	open: bool,
	born: f64,
}

Trackerd :: struct {
	listener:   Sock,
	http_port:  int,
	udp:        Udp,
	udp_port:   int,
	conns:      [dynamic]Tracker_Conn,
	swarms:     [dynamic]Swarm,
	// UDP connection ids we handed out, so an announce without a connect is
	// refused the way a real tracker refuses it.
	udp_ids:    [dynamic]struct {
		id:   u64,
		born: f64,
	},
	verbose:    bool,
	announce_log: [dynamic]string,
	stop:       bool,
}

trackerd_run :: proc(
	http_port, udp_port: int,
	ports_file: string,
	verbose: bool,
	run_for: f64 = 0,
	ports_out: ^[2]int = nil, // the ports actually bound, for a caller that asked for 0
) -> (
	err: string,
) {
	t := new(Trackerd)
	t.verbose = verbose
	t.conns = make([dynamic]Tracker_Conn, 0, 8)
	t.swarms = make([dynamic]Swarm, 0, 4)
	t.announce_log = make([dynamic]string, 0, 16)

	l, bound, lerr := sock_listen("127.0.0.1", http_port)
	if lerr != "" {
		return lerr
	}
	t.listener = l
	t.http_port = bound

	if uerr := udp_open(&t.udp, "127.0.0.1", udp_port); uerr != "" {
		return uerr
	}
	t.udp_port = t.udp.bound

	if ports_out != nil {
		ports_out^ = {t.http_port, t.udp_port}
	}
	// Progress, on stderr: stdout belongs to the command's result.
	fmt.eprintfln(
		"tracker: http://127.0.0.1:%d/announce  udp://127.0.0.1:%d  (loopback only)",
		t.http_port,
		t.udp_port,
	)
	if ports_file != "" {
		// Written only once both listeners are up, so its existence is the
		// readiness signal the test waits on.
		werr := write_file_string(
			ports_file,
			tsprint("http %d\nudp %d\n", t.http_port, t.udp_port),
		)
		if werr != "" {
			return werr
		}
	}

	// The temp allocator is reset every step, so a tracker left running for
	// half an hour does not grow. Nothing above lives in it once the ports
	// file is written, and the command line is the kit's (its own arena).
	started := now_s()
	for !t.stop {
		if run_for > 0 && now_s() - started > run_for {
			break
		}
		trackerd_step(t, 200)
		free_all(context.temp_allocator)
	}
	sock_close(t.listener)
	udp_close(&t.udp)
	return ""
}

trackerd_step :: proc(t: ^Trackerd, timeout_ms: i32) {
	fds := make([dynamic]linux.Poll_Fd, 0, len(t.conns) + 2, context.temp_allocator)
	append(&fds, linux.Poll_Fd{fd = linux.Fd(t.listener), events = {.IN}})
	append(&fds, linux.Poll_Fd{fd = t.udp.fd, events = {.IN}})
	// The connection count is taken BEFORE the accept below, because accepting
	// appends to `t.conns` and the pollfd array must stay in step with it.
	nconns := len(t.conns)
	for &c in t.conns {
		ev: linux.Fd_Poll_Events = {.IN}
		if len(c.out) > 0 {
			ev += {.OUT}
		}
		append(&fds, linux.Poll_Fd{fd = linux.Fd(c.sock), events = ev})
	}
	poll_wait(fds[:], timeout_ms)

	if .IN in fds[0].revents {
		for {
			s, host, port, ok := sock_accept(t.listener)
			if !ok {
				break
			}
			_, _ = host, port
			append(
				&t.conns,
				Tracker_Conn {
					sock = s,
					buf = make([dynamic]u8, 0, 2048),
					out = make([dynamic]u8, 0, 2048),
					open = true,
					born = now_s(),
				},
			)
		}
	}
	if .IN in fds[1].revents {
		trackerd_udp(t)
	}

	for i in 0 ..< nconns {
		c := &t.conns[i]
		rev := fds[2 + i].revents
		if .IN in rev {
			buf: [8192]u8
			for {
				n, st := sock_read(c.sock, buf[:])
				if st == .Ok {
					append(&c.buf, ..buf[:n])
					if len(c.buf) > 64 * 1024 {
						c.open = false
						break
					}
					continue
				}
				if st == .Again {
					break
				}
				c.open = false
				break
			}
			if bytes_index(c.buf[:], "\r\n\r\n") >= 0 && len(c.out) == 0 {
				trackerd_respond(t, c)
			}
		}
		if len(c.out) > 0 && (.OUT in rev || .IN in rev) {
			n, st := sock_write(c.sock, c.out[:])
			if st == .Ok {
				remove_range(&c.out, 0, n)
				if len(c.out) == 0 {
					c.open = false // Connection: close
				}
			} else if st != .Again {
				c.open = false
			}
		}
		if .HUP in rev || .ERR in rev {
			if len(c.out) == 0 {
				c.open = false
			}
		}
		if now_s() - c.born > 30 {
			c.open = false
		}
	}
	// Reap.
	for i := len(t.conns) - 1; i >= 0; i -= 1 {
		if !t.conns[i].open {
			sock_close(t.conns[i].sock)
			delete(t.conns[i].buf)
			delete(t.conns[i].out)
			unordered_remove(&t.conns, i)
		}
	}
	trackerd_expire(t)
}

@(private = "file")
trackerd_expire :: proc(t: ^Trackerd) {
	now := now_s()
	for &sw in t.swarms {
		for i := len(sw.peers) - 1; i >= 0; i -= 1 {
			if now - sw.peers[i].seen > TRACKER_PEER_TTL {
				delete(sw.peers[i].host)
				unordered_remove(&sw.peers, i)
			}
		}
	}
	for i := len(t.udp_ids) - 1; i >= 0; i -= 1 {
		if now - t.udp_ids[i].born > 120 {
			unordered_remove(&t.udp_ids, i)
		}
	}
}

// ---------------------------------------------------------------------------
// Swarms
// ---------------------------------------------------------------------------

@(private = "file")
swarm_for :: proc(t: ^Trackerd, ih: Hash20) -> ^Swarm {
	for &sw in t.swarms {
		if hash20_eq(sw.info_hash, ih) {
			return &sw
		}
	}
	append(&t.swarms, Swarm{info_hash = ih, peers = make([dynamic]Swarm_Peer, 0, 4)})
	return &t.swarms[len(t.swarms) - 1]
}

// trackerd_record folds one announce into the swarm and returns the peer list
// to answer with, which excludes the announcing peer itself.
@(private = "file")
trackerd_record :: proc(
	t: ^Trackerd,
	ih: Hash20,
	peer_id: [20]u8,
	host: string,
	port: int,
	left, uploaded, downloaded: i64,
	event: string,
	numwant: int,
) -> (
	peers: []Peer_Addr,
	complete, incomplete: int,
) {
	sw := swarm_for(t, ih)
	sw.announces += 1
	switch event {
	case "started":
		sw.started += 1
	case "completed":
		sw.completed += 1
	case "stopped":
		sw.stopped += 1
	}
	append(
		&t.announce_log,
		asprint(
			"%s %s %s:%d left=%d up=%d down=%d",
			hash20_hex(ih, context.temp_allocator),
			peer_id_text(peer_id, context.temp_allocator),
			host,
			port,
			left,
			uploaded,
			downloaded,
		),
	)

	found := -1
	for &p, i in sw.peers {
		if p.peer_id == peer_id {
			found = i
			break
		}
	}
	if event == "stopped" {
		if found >= 0 {
			delete(sw.peers[found].host)
			unordered_remove(&sw.peers, found)
		}
	} else {
		if found < 0 {
			append(
				&sw.peers,
				Swarm_Peer{peer_id = peer_id, host = strings.clone(host), port = port},
			)
			found = len(sw.peers) - 1
		}
		p := &sw.peers[found]
		p.port = port
		p.left = left
		p.uploaded = uploaded
		p.downloaded = downloaded
		p.seen = now_s()
		if event == "completed" || left == 0 {
			p.completed = true
		}
	}

	want := numwant <= 0 ? 50 : min(numwant, 200)
	out := make([dynamic]Peer_Addr, 0, want, context.temp_allocator)
	for p in sw.peers {
		if p.left == 0 {
			complete += 1
		} else {
			incomplete += 1
		}
		if p.peer_id == peer_id {
			continue
		}
		if len(out) < want {
			append(&out, Peer_Addr{host = p.host, port = p.port})
		}
	}
	return out[:], complete, incomplete
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

@(private = "file")
http_reply :: proc(c: ^Tracker_Conn, status: int, reason: string, ctype: string, body: []u8) {
	head := tsprint(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		status,
		reason,
		ctype,
		len(body),
	)
	append(&c.out, ..transmute([]u8)head)
	append(&c.out, ..body)
}

@(private = "file")
bencode_failure :: proc(c: ^Tracker_Conn, why: string) {
	body := ben_encode(
		bdict({bp("failure reason", bstr(why))}, context.temp_allocator),
		context.temp_allocator,
	)
	http_reply(c, 200, "OK", "text/plain", body)
}

@(private = "file")
trackerd_respond :: proc(t: ^Trackerd, c: ^Tracker_Conn) {
	hdr_end := bytes_index(c.buf[:], "\r\n\r\n")
	head := string(c.buf[:hdr_end])
	nl := strings.index_byte(head, '\n')
	line := nl < 0 ? head : head[:nl]
	fields := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(fields) < 2 || fields[0] != "GET" {
		http_reply(c, 405, "Method Not Allowed", "text/plain", transmute([]u8)string("GET only\n"))
		return
	}
	target := fields[1]
	path := target
	query := ""
	if q := strings.index_byte(target, '?'); q >= 0 {
		path = target[:q]
		query = target[q + 1:]
	}

	switch path {
	case "/announce":
		trackerd_announce(t, c, query)
	case "/scrape":
		trackerd_scrape(t, c, query)
	case "/stats":
		trackerd_stats(t, c)
	case "/":
		http_reply(
			c,
			200,
			"OK",
			"text/plain",
			transmute([]u8)string("palmy-torrent tracker, loopback only\n/announce /scrape /stats\n"),
		)
	case:
		http_reply(c, 404, "Not Found", "text/plain", transmute([]u8)string("no\n"))
	}
	if t.verbose {
		fmt.eprintfln("tracker: GET %s", target)
	}
}

@(private = "file")
trackerd_announce :: proc(t: ^Trackerd, c: ^Tracker_Conn, query: string) {
	ihb, ihok := query_param(query, "info_hash", context.temp_allocator)
	if !ihok || len(ihb) != 20 {
		// This is the error a client with a UTF-8-mangled info_hash gets, and
		// saying the length makes the cause obvious rather than mysterious.
		bencode_failure(
			c,
			tsprint("info_hash must be 20 bytes; this request carried %d", len(ihb)),
		)
		return
	}
	pidb, pidok := query_param(query, "peer_id", context.temp_allocator)
	if !pidok || len(pidb) != 20 {
		bencode_failure(c, tsprint("peer_id must be 20 bytes; this request carried %d", len(pidb)))
		return
	}
	port := int(query_param_int(query, "port", 0))
	if port <= 0 || port > 65535 {
		bencode_failure(c, "port is missing or out of range")
		return
	}
	ih: Hash20
	copy(ih[:], ihb)
	pid: [20]u8
	copy(pid[:], pidb)

	left := query_param_int(query, "left", -1)
	up := query_param_int(query, "uploaded", 0)
	down := query_param_int(query, "downloaded", 0)
	event, _ := query_param_str(query, "event", context.temp_allocator)
	numwant := int(query_param_int(query, "numwant", 50))

	// The announcing peer's address is the source address of this connection,
	// which is 127.0.0.1 because that is the only interface bound.
	peers, complete, incomplete := trackerd_record(
		t,
		ih,
		pid,
		"127.0.0.1",
		port,
		left,
		up,
		down,
		event,
		numwant,
	)

	compact := encode_compact_peers(peers, context.temp_allocator)
	body := ben_encode(
		bdict(
			{
				bp("interval", bnum(TRACKER_INTERVAL)),
				bp("min interval", bnum(1)),
				bp("complete", bnum(i64(complete))),
				bp("incomplete", bnum(i64(incomplete))),
				bp("peers", bbytes(compact)),
			},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
	http_reply(c, 200, "OK", "text/plain", body)
}

@(private = "file")
trackerd_scrape :: proc(t: ^Trackerd, c: ^Tracker_Conn, query: string) {
	ihb, ihok := query_param(query, "info_hash", context.temp_allocator)
	files := make([dynamic]Ben_Pair, 0, len(t.swarms), context.temp_allocator)
	for &sw in t.swarms {
		h := sw.info_hash
		if ihok && len(ihb) == 20 {
			match := true
			for i in 0 ..< 20 {
				if h[i] != ihb[i] {match = false;break}
			}
			if !match {
				continue
			}
		}
		complete, incomplete := 0, 0
		for p in sw.peers {
			if p.left == 0 {complete += 1} else {incomplete += 1}
		}
		append(
			&files,
			Ben_Pair {
				key = h[:],
				val = bdict(
					{
						bp("complete", bnum(i64(complete))),
						bp("downloaded", bnum(i64(sw.completed))),
						bp("incomplete", bnum(i64(incomplete))),
					},
					context.temp_allocator,
				),
			},
		)
	}
	body := ben_encode(
		bdict({bp("files", bdict(files[:], context.temp_allocator))}, context.temp_allocator),
		context.temp_allocator,
	)
	http_reply(c, 200, "OK", "text/plain", body)
}

// trackerd_stats is this tracker's own account of what happened, in plain text
// so the end-to-end test can assert against it without a second parser.
@(private = "file")
trackerd_stats :: proc(t: ^Trackerd, c: ^Tracker_Conn) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "swarms %d", len(t.swarms))
	for &sw in t.swarms {
		complete, incomplete := 0, 0
		for p in sw.peers {
			if p.left == 0 {complete += 1} else {incomplete += 1}
		}
		fmt.sbprintfln(
			&b,
			"swarm %s announces %d started %d completed %d stopped %d complete %d incomplete %d peers %d",
			hash20_hex(sw.info_hash, context.temp_allocator),
			sw.announces,
			sw.started,
			sw.completed,
			sw.stopped,
			complete,
			incomplete,
			len(sw.peers),
		)
		for p in sw.peers {
			fmt.sbprintfln(
				&b,
				"peer %s %s:%d left %d up %d down %d",
				peer_id_text(p.peer_id, context.temp_allocator),
				p.host,
				p.port,
				p.left,
				p.uploaded,
				p.downloaded,
			)
		}
	}
	for line in t.announce_log {
		fmt.sbprintfln(&b, "announce %s", line)
	}
	http_reply(c, 200, "OK", "text/plain", transmute([]u8)strings.to_string(b))
}

// ---------------------------------------------------------------------------
// UDP
// ---------------------------------------------------------------------------

@(private = "file")
trackerd_udp :: proc(t: ^Trackerd) {
	buf: [2048]u8
	for {
		n, host, port, ok := udp_recv(&t.udp, buf[:], 0)
		if !ok {
			return
		}
		pkt := buf[:n]
		if n < 16 {
			continue
		}
		action := Udp_Action(be_u32(pkt[8:12]))
		if be_u64(pkt[0:8]) == UDP_PROTOCOL_ID && action == .Connect {
			txn := be_u32(pkt[12:16])
			id := xs_next(&udp_id_rng) | 1
			append(&t.udp_ids, struct {
					id:   u64,
					born: f64,
				}{id = id, born = now_s()})
			out: [16]u8
			put_be_u32(out[0:4], u32(Udp_Action.Connect))
			put_be_u32(out[4:8], txn)
			put_be_u64(out[8:16], id)
			udp_send_to(&t.udp, host, port, out[:])
			continue
		}
		// Anything else must carry a connection id we handed out.
		cid := be_u64(pkt[0:8])
		known := false
		for e in t.udp_ids {
			if e.id == cid {known = true;break}
		}
		txn := be_u32(pkt[12:16])
		if !known {
			udp_error(t, host, port, txn, "unknown connection id; send a connect first")
			continue
		}
		if action == .Scrape {
			// BEP 15 scrape: 16 bytes of header, then 20 per info-hash. The
			// answer is 12 bytes per hash in the order asked, with no hashes
			// in it, so the count for a torrent this tracker has never heard
			// of still has to occupy its slot — zeros, not an omission.
			body := pkt[16:]
			if len(body) == 0 || len(body) % 20 != 0 || len(body) / 20 > UDP_SCRAPE_MAX {
				udp_error(t, host, port, txn, "a scrape body must be 1..74 raw info-hashes")
				continue
			}
			out := make([dynamic]u8, 0, 8 + len(body) / 20 * 12, context.temp_allocator)
			append_be_u32(&out, u32(Udp_Action.Scrape))
			append_be_u32(&out, txn)
			for i := 0; i + 20 <= len(body); i += 20 {
				ih: Hash20
				copy(ih[:], body[i:i + 20])
				complete, incomplete, downloaded := 0, 0, 0
				for &sw in t.swarms {
					if !hash20_eq(sw.info_hash, ih) {
						continue
					}
					downloaded = sw.completed
					for pe in sw.peers {
						if pe.left == 0 {complete += 1} else {incomplete += 1}
					}
					break
				}
				append_be_u32(&out, u32(complete))
				append_be_u32(&out, u32(downloaded))
				append_be_u32(&out, u32(incomplete))
			}
			udp_send_to(&t.udp, host, port, out[:])
			continue
		}
		if action != .Announce || n < 98 {
			udp_error(t, host, port, txn, "only announce and scrape are implemented over UDP here")
			continue
		}
		ih: Hash20
		copy(ih[:], pkt[16:36])
		pid: [20]u8
		copy(pid[:], pkt[36:56])
		down := i64(be_u64(pkt[56:64]))
		left := i64(be_u64(pkt[64:72]))
		up := i64(be_u64(pkt[72:80]))
		ev := be_u32(pkt[80:84])
		nw := be_u32(pkt[92:96])
		pport := int(be_u16(pkt[96:98]))
		event := ""
		switch ev {
		case 1:
			event = "completed"
		case 2:
			event = "started"
		case 3:
			event = "stopped"
		}
		numwant := nw == 0xffffffff ? 50 : int(nw)
		peers, complete, incomplete := trackerd_record(
			t,
			ih,
			pid,
			"127.0.0.1",
			pport,
			left,
			up,
			down,
			event,
			numwant,
		)
		compact := encode_compact_peers(peers, context.temp_allocator)
		out := make([dynamic]u8, 0, 20 + len(compact), context.temp_allocator)
		append_be_u32(&out, u32(Udp_Action.Announce))
		append_be_u32(&out, txn)
		append_be_u32(&out, TRACKER_INTERVAL)
		append_be_u32(&out, u32(incomplete))
		append_be_u32(&out, u32(complete))
		append(&out, ..compact)
		udp_send_to(&t.udp, host, port, out[:])
	}
}

@(private = "file")
udp_id_rng := Xorshift{s = 0x5eed1234abcd}

@(private = "file")
udp_error :: proc(t: ^Trackerd, host: string, port: int, txn: u32, why: string) {
	out := make([dynamic]u8, 0, 8 + len(why), context.temp_allocator)
	append_be_u32(&out, u32(Udp_Action.Error))
	append_be_u32(&out, txn)
	append(&out, ..transmute([]u8)why)
	udp_send_to(&t.udp, host, port, out[:])
}
