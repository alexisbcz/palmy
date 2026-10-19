// palm-sfu — the selective forwarding unit for Palmy calls.
//
// One UDP socket. A participant sends one copy of its media; the SFU forwards
// it to everyone else in the call, choosing per receiver which simulcast
// layer of each sender's video it gets, or none. It never decodes anything:
// with end-to-end encryption on (the default) it cannot, and it decides
// everything from the clear PCP2 header — the source it stamps itself, the
// layer, the keyframe bit, the audio level.
//
// Admission is a join token minted by the chat gateway (cloud/rtc/pcp,
// token.odin). The SFU holds the token secret and nothing else: no database,
// no account keys, and no media keys.
//
//	palm-sfu --secret-file FILE [--bind 127.0.0.1] [--port 47900]
//	         [--gateway 127.0.0.1:8790] [--stats] [--json-out FILE]
//	         [--quit-after SECONDS]
//	palm-sfu --mint-token --secret-file FILE --call ID --id IDENTITY
//	         --handle H --name N [--color C] [--ch CH] [--ttl S]
//	palm-sfu --selftest
//
// Concurrency: there is none. A single loop receives with a 5 ms timeout,
// handles each datagram to completion, and runs the timers between. At the
// sizes a call has (tens of participants, a few thousand datagrams a second)
// that is not the bottleneck, and it means no state in this file is shared.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import pcp "../pcp"
import w "../../../apps/chat/wire"

MAX_ROOM :: 16
PART_TIMEOUT :: 6.0 // seconds of silence before a participant is dropped
ROSTER_EVERY :: 1.0
KF_GAP :: 0.25 // minimum interval between keyframe requests to one sender layer

// WARMUP is how long after a join receiver reports are not acted on. The first
// second of a call is every sender's first keyframe at once, and loss measured
// then says more about the startup burst than about the link.
WARMUP :: 1.5

View :: struct {
	cur:       int, // layer being forwarded from that sender: -1 none, 0, 1
	switches:  int,
}

Part :: struct {
	src:       u16,
	ep:        net.Endpoint,
	room:      ^Room,
	id:        string,
	handle:    string,
	name:      string,
	color:     string,
	pub:       string, // base64 X25519 public key, opaque here
	muted:     bool,
	cam_off:   bool,
	joined_at: f64,
	last_rx:   f64,

	tier:      pcp.Tier_State,
	views:     map[u16]View,
	last_loss: f64,
	last_kbps: f64,

	// Counters.
	rx_pkts, rx_bytes:     int,
	tx_pkts, tx_bytes:     int,
	rx_audio, rx_video:    int,
	rx_layer_bytes:        [2]int,
	fwd_layer_bytes:       [2]int,
	kf_asked:              [2]f64, // when we last asked this sender for a keyframe of a layer
	kf_requests:           int,
	rate_at:               f64,
	rate_rx0, rate_tx0:    int,
	rx_kbps, tx_kbps:      f64,
}

Spk_Event :: struct {
	t:      f64,
	unix_ms: i64,
	src:    u16,
	handle: string,
}

Tier_Event :: struct {
	t:      f64,
	handle: string,
	tier:   pcp.Tier,
	est:    f64,
}

// Part_Summary is what is kept of a participant after it leaves, so the
// summary at exit can still say what each one sent and received.
Part_Summary :: struct {
	handle:           string,
	src:              u16,
	rx_kbps, tx_kbps: f64,
	rx_bytes, tx_bytes: int,
	secs:             f64,
	tier:             pcp.Tier,
	fwd:              [2]int,
	kf_requests:      int,
}

Room :: struct {
	departed:  [dynamic]Part_Summary,
	call:      string,
	ch:        string,
	e2ee:      bool,
	parts:     [dynamic]^Part,
	next_src:  u16,
	gen:       u32,
	spk:       pcp.Speaker_Detector,
	created:   f64,
	last_roster: f64,
	speakers:  [dynamic]Spk_Event,
	tiers:     [dynamic]Tier_Event,
	peak:      int,
}

Gateway :: struct {
	addr:     string,
	sock:     net.TCP_Socket,
	up:       bool,
	welcomed: bool,
	rd:       w.Reader,
	retry_at: f64,
	backoff:  f64,
	sent:     int,
}

Sfu :: struct {
	sock:      net.UDP_Socket,
	port:      int,
	secret:    []u8,
	rooms:     [dynamic]^Room,
	by_ep:     map[u64]^Part,
	gw:        Gateway,
	t0:        time.Tick,
	t:         f64,
	stats:     bool,
	quiet:     bool,
	rx:        [pcp.MAX_PACKET + 64]u8,
	tx:        [pcp.MAX_PACKET + 64]u8,
	ctl_seq:   u16,
	// Totals.
	rx_pkts, rx_bytes, tx_pkts, tx_bytes, rejected, bad_token: int,
	last_stats: f64,
	finished:  [dynamic]^Room, // rooms that emptied, kept for the summary
	warmup:    f64,
}

ep_key :: proc(ep: net.Endpoint) -> u64 {
	a, ok := ep.address.(net.IP4_Address)
	if !ok {
		return 0
	}
	return u64(a[0]) << 40 | u64(a[1]) << 32 | u64(a[2]) << 24 | u64(a[3]) << 16 | u64(ep.port)
}

now :: proc(s: ^Sfu) -> f64 {
	return time.duration_seconds(time.tick_since(s.t0))
}

note :: proc(s: ^Sfu, format: string, args: ..any) {
	if s.quiet {
		return
	}
	fmt.printf("sfu %7.3f  ", s.t)
	fmt.printfln(format, ..args)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
	args := os.args[1:]
	bind := "127.0.0.1"
	port := 47900
	secret_file := ""
	gateway := ""
	quit_after := 0.0
	json_out := ""
	s := new(Sfu)
	s.warmup = WARMUP
	mint := false
	mj: pcp.Join
	ttl := i64(pcp.TOKEN_TTL)

	for i := 0; i < len(args); i += 1 {
		a := args[i]
		val :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 >= len(args) {
				fmt.eprintfln("palm-sfu: %s needs a value", args[i^])
				os.exit(2)
			}
			i^ += 1
			return args[i^]
		}
		switch a {
		case "--selftest", "--self-test":
			os.exit(run_selftest())
		case "--bind":
			bind = val(args, &i)
		case "--port":
			port, _ = strconv.parse_int(val(args, &i))
		case "--secret-file":
			secret_file = val(args, &i)
		case "--gateway":
			gateway = val(args, &i)
		case "--stats":
			s.stats = true
		case "--quiet":
			s.quiet = true
		case "--json-out":
			json_out = val(args, &i)
		case "--quit-after":
			quit_after, _ = strconv.parse_f64(val(args, &i))
		case "--mint-token":
			mint = true
		case "--call":
			mj.call = val(args, &i)
		case "--ch":
			mj.ch = val(args, &i)
		case "--id":
			mj.id = val(args, &i)
		case "--handle":
			mj.handle = val(args, &i)
		case "--name":
			mj.name = val(args, &i)
		case "--color":
			mj.color = val(args, &i)
		case "--no-e2ee":
			mj.e2ee = false
		case "--ttl":
			ttl, _ = strconv.parse_i64(val(args, &i))
		case "-h", "--help":
			fmt.print(USAGE)
			return
		case:
			fmt.eprintfln("palm-sfu: unknown argument %q", a)
			os.exit(2)
		}
	}

	s.secret = load_secret(secret_file)
	if len(s.secret) == 0 {
		fmt.eprintln("palm-sfu: no secret (--secret-file FILE or RTC_SFU_SECRET)")
		os.exit(2)
	}

	if mint {
		mj.e2ee = true
		if mj.call == "" || mj.id == "" {
			fmt.eprintln("palm-sfu: --mint-token needs --call and --id")
			os.exit(2)
		}
		if mj.handle == "" {
			mj.handle = mj.id
		}
		if mj.name == "" {
			mj.name = mj.handle
		}
		if mj.color == "" {
			mj.color = "indigo"
		}
		mj.exp = time.time_to_unix(time.now()) + ttl
		fmt.println(pcp.token_mint(s.secret, mj))
		return
	}

	addr, aok := net.parse_ip4_address(bind)
	if !aok {
		fmt.eprintfln("palm-sfu: --bind takes an IPv4 address, got %q", bind)
		os.exit(2)
	}
	if err := sfu_open(s, addr, port); err != "" {
		fmt.eprintfln("palm-sfu: %s", err)
		os.exit(1)
	}
	if gateway != "" {
		s.gw.addr = gateway
		s.gw.backoff = 1
	}
	note(s, "listening on %s:%d (udp), gateway %s", bind, port, gateway == "" ? "none" : gateway)
	if bind != "127.0.0.1" {
		note(s, "bound beyond loopback: media is end-to-end encrypted, but a public deployment also needs TURN/TCP fallback (see PROTOCOL.md)")
	}

	for {
		sfu_step(s)
		if quit_after > 0 && s.t > quit_after {
			break
		}
	}
	if json_out != "" {
		write_summary(s, json_out)
	}
	print_summary(s)
}

USAGE :: `palm-sfu — selective forwarding unit for Palmy calls

  palm-sfu --secret-file FILE [--bind 127.0.0.1] [--port 47900]
           [--gateway HOST:PORT] [--stats] [--json-out FILE] [--quit-after S]
  palm-sfu --mint-token --secret-file FILE --call ID --id IDENTITY
           [--handle H] [--name N] [--color C] [--ch CH] [--ttl S]
  palm-sfu --selftest

The secret may also come from RTC_SFU_SECRET. It is the join-token secret
shared with the chat gateway, and nothing else.
`

load_secret :: proc(path: string) -> []u8 {
	if path != "" {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.eprintfln("palm-sfu: cannot read %s: %v", path, err)
			os.exit(2)
		}
		return transmute([]u8)strings.trim_space(string(data))
	}
	v := os.get_env("RTC_SFU_SECRET", context.allocator)
	return transmute([]u8)v
}

sfu_open :: proc(s: ^Sfu, addr: net.IP4_Address, port: int) -> string {
	sock, err := net.make_bound_udp_socket(addr, port)
	if err != nil {
		return fmt.aprintf("cannot bind %v:%d (%v)", addr, port, err)
	}
	net.set_option(sock, .Receive_Timeout, 5 * time.Millisecond)
	net.set_option(sock, .Receive_Buffer_Size, 4 << 20)
	net.set_option(sock, .Send_Buffer_Size, 4 << 20)
	s.sock = sock
	s.port = port
	s.t0 = time.tick_now()
	s.by_ep = make(map[u64]^Part)
	return ""
}

// sfu_step is one turn of the loop: drain what has arrived (up to a budget),
// then run the timers.
sfu_step :: proc(s: ^Sfu) {
	for _ in 0 ..< 2048 {
		n, from, err := net.recv_udp(s.sock, s.rx[:])
		s.t = now(s)
		if err != nil || n <= 0 {
			break
		}
		s.rx_pkts += 1
		s.rx_bytes += n
		handle_datagram(s, s.rx[:n], from)
		free_all(context.temp_allocator)
	}
	s.t = now(s)
	timers(s)
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

send_to :: proc(s: ^Sfu, p: ^Part, dg: []u8) {
	n, err := net.send_udp(s.sock, dg, p.ep)
	if err != nil {
		return
	}
	s.tx_pkts += 1
	s.tx_bytes += n
	p.tx_pkts += 1
	p.tx_bytes += n
}

send_ctl :: proc(s: ^Sfu, p: ^Part, kind: pcp.Kind, body: string) {
	s.ctl_seq += 1
	dg := pcp.control_into(s.tx[:], kind, body, s.ctl_seq, u64(time.tick_now()._nsec / 1000))
	if dg != nil {
		send_to(s, p, dg)
	}
}

send_ctl_ep :: proc(s: ^Sfu, ep: net.Endpoint, kind: pcp.Kind, body: string) {
	s.ctl_seq += 1
	dg := pcp.control_into(s.tx[:], kind, body, s.ctl_seq, 0)
	if dg != nil {
		net.send_udp(s.sock, dg, ep)
	}
}

peer_body :: proc(p: ^Part) -> string {
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "src", i64(p.src))
	pcp.obj_str(&o, "id", p.id)
	pcp.obj_str(&o, "handle", p.handle)
	pcp.obj_str(&o, "name", p.name)
	pcp.obj_str(&o, "color", p.color)
	pcp.obj_str(&o, "pub", p.pub)
	pcp.obj_bool(&o, "muted", p.muted)
	pcp.obj_bool(&o, "cam_off", p.cam_off)
	return pcp.obj_end(&o)
}

roster_body :: proc(r: ^Room) -> string {
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "gen", i64(r.gen))
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for p, i in r.parts {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%d", p.src)
	}
	strings.write_byte(&b, ']')
	pcp.obj_raw(&o, "srcs", strings.to_string(b))
	pcp.obj_int(&o, "speaker", i64(r.spk.current))
	return pcp.obj_end(&o)
}

broadcast_roster :: proc(s: ^Sfu, r: ^Room) {
	body := roster_body(r)
	for p in r.parts {
		send_ctl(s, p, .Roster, body)
	}
	r.last_roster = s.t
}

// ---------------------------------------------------------------------------
// Receiving
// ---------------------------------------------------------------------------

handle_datagram :: proc(s: ^Sfu, dg: []u8, from: net.Endpoint) {
	h, payload, ok := pcp.parse(dg)
	if !ok {
		s.rejected += 1
		return
	}
	key := ep_key(from)
	p := s.by_ep[key] or_else nil

	if h.ptype == .Control {
		kind, o, cok := pcp.control_parse(payload)
		if !cok {
			s.rejected += 1
			return
		}
		if kind == .Join {
			handle_join(s, from, o, p)
			return
		}
		if p == nil {
			// Not in a call: nothing but JOIN is accepted from an unknown
			// address, and nothing is said back, so the port is not an oracle.
			s.rejected += 1
			return
		}
		p.last_rx = s.t
		p.rx_pkts += 1
		p.rx_bytes += len(dg)
		handle_control(s, p, kind, o)
		return
	}

	if p == nil {
		s.rejected += 1
		return
	}
	p.last_rx = s.t
	p.rx_pkts += 1
	p.rx_bytes += len(dg)
	// The source is whoever this session is. Whatever the sender wrote is
	// overwritten, so nobody can put words in another participant's mouth.
	pcp.stamp_src(dg, p.src)
	h.src = p.src
	r := p.room

	if pcp.is_audio(h.ptype) {
		p.rx_audio += 1
		pcp.speaker_feed(&r.spk, p.src, h.level, s.t)
		for q in r.parts {
			if q != p {
				send_to(s, q, dg)
			}
		}
		return
	}

	// Video: pick per receiver.
	p.rx_video += 1
	layer := int(min(h.layer, 1))
	p.rx_layer_bytes[layer] += len(dg)
	for q in r.parts {
		if q == p {
			continue
		}
		want := tier_layer(q.tier.tier)
		v := q.views[p.src] or_else View{cur = -1}
		if want < 0 {
			v.cur = -1
		} else if layer == v.cur && layer == want {
			// steady state
		} else if layer == want {
			// Switch only where the new layer can be decoded from: the first
			// fragment of a keyframe. Until then the old layer keeps flowing.
			if pcp.keyframed(h) && h.frag == 0 {
				v.cur = want
				v.switches += 1
			} else {
				ask_keyframe(s, p, want)
			}
		}
		q.views[p.src] = v
		if v.cur == layer {
			q.fwd_layer_bytes[layer] += len(dg)
			send_to(s, q, dg)
		}
	}
}

tier_layer :: proc(t: pcp.Tier) -> int {
	switch t {
	case .High:
		return 0
	case .Low:
		return 1
	case .Audio:
		return -1
	}
	return -1
}

ask_keyframe :: proc(s: ^Sfu, sender: ^Part, layer: int) {
	if s.t - sender.kf_asked[layer] < KF_GAP {
		return
	}
	sender.kf_asked[layer] = s.t
	sender.kf_requests += 1
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "layer", i64(layer))
	send_ctl(s, sender, .Keyframe, pcp.obj_end(&o))
}

handle_join :: proc(s: ^Sfu, from: net.Endpoint, o: json.Object, existing: ^Part) {
	if existing != nil {
		// A retransmitted JOIN: the WELCOME was lost. Say it again.
		send_welcome(s, existing)
		return
	}
	j, terr := pcp.token_verify(s.secret, pcp.ostr(o, "token"), allocator = context.temp_allocator)
	if terr != .None {
		s.bad_token += 1
		eo: pcp.Obj
		pcp.obj_begin(&eo)
		pcp.obj_str(&eo, "code", terr == .Expired ? "token_expired" : "bad_token")
		pcp.obj_str(&eo, "msg", terr == .Expired ? "the join token has expired; ask the gateway for a new one" : "the join token was not accepted")
		send_ctl_ep(s, from, .Error, pcp.obj_end(&eo))
		note(s, "refused a join from %v: %v", from, terr)
		return
	}
	pub := pcp.ostr(o, "pub")
	if j.e2ee {
		raw, derr := base64.decode(pub, allocator = context.temp_allocator)
		if derr != nil || len(raw) != 32 {
			eo: pcp.Obj
			pcp.obj_begin(&eo)
			pcp.obj_str(&eo, "code", "bad_key")
			pcp.obj_str(&eo, "msg", "an end-to-end encrypted call needs a 32-byte X25519 public key")
			send_ctl_ep(s, from, .Error, pcp.obj_end(&eo))
			return
		}
	}

	r := find_room(s, j.call)
	if r == nil {
		r = new(Room)
		r.call = strings.clone(j.call)
		r.ch = strings.clone(j.ch)
		r.e2ee = j.e2ee
		r.created = s.t
		append(&s.rooms, r)
		note(s, "room %s opened", short_id(r.call))
	}
	// The same identity joining again (a restarted client) replaces its old
	// session rather than appearing twice.
	for q in r.parts {
		if q.id == j.id {
			remove_part(s, q, "rejoined")
			break
		}
	}
	if len(r.parts) >= MAX_ROOM {
		eo: pcp.Obj
		pcp.obj_begin(&eo)
		pcp.obj_str(&eo, "code", "room_full")
		pcp.obj_str(&eo, "msg", fmt.tprintf("a call holds at most %d participants", MAX_ROOM))
		send_ctl_ep(s, from, .Error, pcp.obj_end(&eo))
		return
	}

	p := new(Part)
	r.next_src += 1
	p.src = r.next_src
	p.ep = from
	p.room = r
	p.id = strings.clone(j.id)
	p.handle = strings.clone(j.handle)
	p.name = strings.clone(j.name)
	p.color = strings.clone(j.color)
	p.pub = strings.clone(pub)
	p.joined_at = s.t
	p.last_rx = s.t
	p.views = make(map[u16]View)
	pcp.tier_init(&p.tier)
	append(&r.parts, p)
	r.peak = max(r.peak, len(r.parts))
	r.gen += 1
	s.by_ep[ep_key(from)] = p
	note(s, "%s (%s) joined %s as src %d — %d in the call", p.name, p.handle, short_id(r.call), p.src, len(r.parts))

	send_welcome(s, p)
	body := peer_body(p)
	for q in r.parts {
		if q != p {
			send_ctl(s, q, .Peer, body)
		}
	}
	broadcast_roster(s, r)
	gw_room(s, r)
}

send_welcome :: proc(s: ^Sfu, p: ^Part) {
	r := p.room
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "src", i64(p.src))
	pcp.obj_str(&o, "call", r.call)
	pcp.obj_str(&o, "ch", r.ch)
	pcp.obj_bool(&o, "e2ee", r.e2ee)
	pcp.obj_int(&o, "gen", i64(r.gen))
	send_ctl(s, p, .Welcome, pcp.obj_end(&o))
	for q in r.parts {
		send_ctl(s, p, .Peer, peer_body(q))
	}
	send_ctl(s, p, .Roster, roster_body(r))
}

handle_control :: proc(s: ^Sfu, p: ^Part, kind: pcp.Kind, o: json.Object) {
	r := p.room
	#partial switch kind {
	case .State:
		muted, cam_off := pcp.obool(o, "muted"), pcp.obool(o, "cam_off")
		if muted != p.muted || cam_off != p.cam_off {
			p.muted, p.cam_off = muted, cam_off
			body := peer_body(p)
			for q in r.parts {
				send_ctl(s, q, .Peer, body)
			}
		}
	case .Leave:
		remove_part(s, p, "left")
	case .Keyframe:
		// A receiver lost something from `src`: ask that sender for a
		// keyframe of the layer this receiver is actually being sent.
		src := u16(pcp.oint(o, "src"))
		for q in r.parts {
			if q.src == src && q != p {
				v := p.views[src] or_else View{cur = 0}
				ask_keyframe(s, q, max(v.cur, 0))
			}
		}
	case .Feedback:
		loss, kbps, cap := pcp.ofloat(o, "loss"), pcp.ofloat(o, "kbps"), pcp.ofloat(o, "cap")
		p.last_loss, p.last_kbps = loss, kbps
		if s.t - p.joined_at < s.warmup {
			return
		}
		senders := 0
		for q in r.parts {
			if q != p && !q.cam_off {
				senders += 1
			}
		}
		if pcp.tier_update(&p.tier, loss, kbps, cap, senders, s.t) {
			note(s, "%s moved to the %s tier (estimate %.0f kbit/s, loss %.1f%%)", p.handle, pcp.TIER_NAMES[p.tier.tier], p.tier.est, loss)
			append(&r.tiers, Tier_Event{t = s.t - r.created, handle = p.handle, tier = p.tier.tier, est = p.tier.est})
			to: pcp.Obj
			pcp.obj_begin(&to)
			pcp.obj_str(&to, "tier", pcp.TIER_NAMES[p.tier.tier])
			pcp.obj_f(&to, "est", p.tier.est)
			send_ctl(s, p, .Tier, pcp.obj_end(&to))
			want := tier_layer(p.tier.tier)
			if want >= 0 {
				for q in r.parts {
					if q != p {
						ask_keyframe(s, q, want)
					}
				}
			}
		}
	case .Key:
		// Relay a sealed base key. The SFU cannot open it and does not try;
		// it only says who it came from, which it knows and the blob cannot
		// lie about without failing to open at the recipient.
		to := u16(pcp.oint(o, "to"))
		for q in r.parts {
			if q.src == to && q != p {
				ko: pcp.Obj
				pcp.obj_begin(&ko)
				pcp.obj_int(&ko, "from", i64(p.src))
				pcp.obj_int(&ko, "kid", pcp.oint(o, "kid"))
				pcp.obj_str(&ko, "sealed", pcp.ostr(o, "sealed"))
				send_ctl(s, q, .Key, pcp.obj_end(&ko))
			}
		}
	}
}

find_room :: proc(s: ^Sfu, call: string) -> ^Room {
	for r in s.rooms {
		if r.call == call {
			return r
		}
	}
	return nil
}

remove_part :: proc(s: ^Sfu, p: ^Part, why: string) {
	r := p.room
	for q, i in r.parts {
		if q == p {
			ordered_remove(&r.parts, i)
			break
		}
	}
	delete_key(&s.by_ep, ep_key(p.ep))
	pcp.speaker_forget(&r.spk, p.src)
	for q in r.parts {
		delete_key(&q.views, p.src)
	}
	r.gen += 1
	note(s, "%s left %s (%s) — %d remain", p.handle, short_id(r.call), why, len(r.parts))
	secs := max(0.001, s.t - p.joined_at)
	append(&r.departed, Part_Summary{
		handle = p.handle, src = p.src,
		rx_kbps = f64(p.rx_bytes) * 8 / 1000 / secs, tx_kbps = f64(p.tx_bytes) * 8 / 1000 / secs,
		rx_bytes = p.rx_bytes, tx_bytes = p.tx_bytes, secs = secs,
		tier = p.tier.tier, fwd = p.fwd_layer_bytes, kf_requests = p.kf_requests,
	})
	delete(p.views)
	free(p)

	if len(r.parts) == 0 {
		gw_end(s, r)
		for x, i in s.rooms {
			if x == r {
				ordered_remove(&s.rooms, i)
				break
			}
		}
		append(&s.finished, r)
		note(s, "room %s closed", short_id(r.call))
		return
	}
	broadcast_roster(s, r)
	gw_room(s, r)
}

// kick removes one identity from a call at the gateway's request — its
// membership was revoked mid-call. The participant is told, three times
// because it is UDP, and then it is gone; its keys rotate out at everyone
// else as soon as they see the new roster.
kick :: proc(s: ^Sfu, call, id: string) -> bool {
	r := find_room(s, call)
	if r == nil {
		return false
	}
	for p in r.parts {
		if p.id == id {
			o: pcp.Obj
			pcp.obj_begin(&o)
			pcp.obj_str(&o, "code", "kicked")
			pcp.obj_str(&o, "msg", "your access to this channel was removed")
			body := pcp.obj_end(&o)
			for _ in 0 ..< 3 {
				send_ctl(s, p, .Error, body)
			}
			remove_part(s, p, "removed by the gateway")
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

timers :: proc(s: ^Sfu) {
	for ri := len(s.rooms) - 1; ri >= 0; ri -= 1 {
		r := s.rooms[ri]
		// Silence: a participant that stopped sending (crashed, unplugged)
		// leaves on its own after PART_TIMEOUT.
		for i := len(r.parts) - 1; i >= 0; i -= 1 {
			if i < len(r.parts) && s.t - r.parts[i].last_rx > PART_TIMEOUT {
				remove_part(s, r.parts[i], "timed out")
				if find_room(s, r.call) == nil {
					break
				}
			}
		}
		if find_room(s, r.call) == nil {
			continue
		}
		if pcp.speaker_tick(&r.spk, s.t) {
			cur := r.spk.current
			handle := ""
			for p in r.parts {
				if p.src == cur {
					handle = p.handle
				}
			}
			append(&r.speakers, Spk_Event{t = s.t - r.created, unix_ms = time.time_to_unix_nano(time.now()) / 1e6, src = cur, handle = strings.clone(handle)})
			note(s, "dominant speaker in %s: %s (src %d)", short_id(r.call), handle, cur)
			o: pcp.Obj
			pcp.obj_begin(&o)
			pcp.obj_int(&o, "src", i64(cur))
			body := pcp.obj_end(&o)
			for p in r.parts {
				send_ctl(s, p, .Speaker, body)
			}
			gw_speaker(s, r, cur)
		}
		if s.t - r.last_roster >= ROSTER_EVERY {
			broadcast_roster(s, r)
		}
		for p in r.parts {
			if p.rate_at == 0 {
				p.rate_at = s.t
			} else if s.t - p.rate_at >= 1 {
				dt := s.t - p.rate_at
				p.rx_kbps = f64(p.rx_bytes - p.rate_rx0) * 8 / 1000 / dt
				p.tx_kbps = f64(p.tx_bytes - p.rate_tx0) * 8 / 1000 / dt
				p.rate_at, p.rate_rx0, p.rate_tx0 = s.t, p.rx_bytes, p.tx_bytes
			}
		}
	}
	if s.stats && s.t - s.last_stats >= 1 {
		s.last_stats = s.t
		for r in s.rooms {
			b := strings.builder_make(context.temp_allocator)
			for p in r.parts {
				fmt.sbprintf(&b, "  %s[%d] in %.0f out %.0f kbit/s tier %s", p.handle, p.src, p.rx_kbps, p.tx_kbps, pcp.TIER_NAMES[p.tier.tier])
			}
			fmt.printfln("sfu %7.3f  %s speaker %d%s", s.t, short_id(r.call), r.spk.current, strings.to_string(b))
		}
	}
	gw_pump(s)
}

short_id :: proc(id: string) -> string {
	return len(id) > 8 ? id[:8] : id
}

// ---------------------------------------------------------------------------
// The gateway link
// ---------------------------------------------------------------------------

gw_pump :: proc(s: ^Sfu) {
	g := &s.gw
	if g.addr == "" {
		return
	}
	if !g.up {
		if s.t < g.retry_at {
			return
		}
		ep, ok := net.parse_endpoint(g.addr)
		if !ok {
			g.retry_at = s.t + 30
			return
		}
		sock, err := net.dial_tcp(ep)
		if err != nil {
			g.retry_at = s.t + g.backoff
			g.backoff = min(g.backoff * 2, 10)
			return
		}
		net.set_option(sock, .Send_Timeout, 1 * time.Second)
		net.set_blocking(sock, false)
		g.sock = sock
		g.up = true
		g.welcomed = false
		clear(&g.rd.buf)
		g.rd.bad = false
		ts := time.time_to_unix(time.now())
		e: w.Enc
		w.enc_begin(&e, "sfu_hello")
		w.kv_int(&e, "ts", ts)
		w.kv_str(&e, "mac", pcp.sfu_hello_mac(s.secret, ts))
		w.kv_int(&e, "port", i64(s.port))
		gw_send(s, w.enc_done(&e))
		note(s, "gateway link up to %s", g.addr)
		// Whatever the gateway thought before, this is the truth now.
		for r in s.rooms {
			gw_room(s, r)
		}
		return
	}
	buf: [16 * 1024]u8
	for {
		n, err := net.recv_tcp(g.sock, buf[:])
		if err == .Would_Block || err == .Timeout {
			break
		}
		if err != nil || n == 0 {
			gw_drop(s)
			return
		}
		w.reader_feed(&g.rd, buf[:n])
		if n < len(buf) {
			break
		}
	}
	for {
		payload, ok := w.reader_next(&g.rd, context.temp_allocator)
		if !ok {
			break
		}
		o, good := w.parse_obj(payload, context.temp_allocator)
		if !good {
			continue
		}
		switch w.ostr(o, "t") {
		case "sfu_welcome":
			g.welcomed = true
			g.backoff = 1
		case "sfu_kick":
			if kick(s, w.ostr(o, "call"), w.ostr(o, "id")) {
				note(s, "gateway removed %s from %s", w.ostr(o, "id"), short_id(w.ostr(o, "call")))
			}
		case "error":
			note(s, "gateway refused the link: %s", w.ostr(o, "msg"))
			gw_drop(s)
			return
		}
	}
}

gw_drop :: proc(s: ^Sfu) {
	g := &s.gw
	if g.up {
		net.close(g.sock)
	}
	g.up = false
	g.retry_at = s.t + g.backoff
	g.backoff = min(g.backoff * 2, 10)
	note(s, "gateway link down; retrying in %.0f s", g.backoff)
}

gw_send :: proc(s: ^Sfu, payload: string) {
	if !s.gw.up {
		return
	}
	if !w.send_frame(s.gw.sock, payload) {
		gw_drop(s)
		return
	}
	s.gw.sent += 1
}

gw_room :: proc(s: ^Sfu, r: ^Room) {
	if !s.gw.up {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for p, i in r.parts {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		w.write_json_string(&b, p.id)
	}
	strings.write_byte(&b, ']')
	e: w.Enc
	w.enc_begin(&e, "sfu_room")
	w.kv_str(&e, "call", r.call)
	w.kv_raw(&e, "ids", strings.to_string(b))
	gw_send(s, w.enc_done(&e))
}

gw_end :: proc(s: ^Sfu, r: ^Room) {
	e: w.Enc
	w.enc_begin(&e, "sfu_end")
	w.kv_str(&e, "call", r.call)
	gw_send(s, w.enc_done(&e))
}

gw_speaker :: proc(s: ^Sfu, r: ^Room, src: u16) {
	for p in r.parts {
		if p.src == src {
			e: w.Enc
			w.enc_begin(&e, "sfu_speaker")
			w.kv_str(&e, "call", r.call)
			w.kv_str(&e, "id", p.id)
			gw_send(s, w.enc_done(&e))
		}
	}
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

all_rooms :: proc(s: ^Sfu) -> []^Room {
	out := make([dynamic]^Room, context.temp_allocator)
	append(&out, ..s.finished[:])
	append(&out, ..s.rooms[:])
	return out[:]
}

print_summary :: proc(s: ^Sfu) {
	fmt.println("")
	fmt.println("── palm-sfu summary ──")
	fmt.printfln("  datagrams        %d in (%.2f MB), %d out (%.2f MB), %d rejected, %d bad tokens",
		s.rx_pkts, f64(s.rx_bytes) / 1e6, s.tx_pkts, f64(s.tx_bytes) / 1e6, s.rejected, s.bad_token)
	for r in all_rooms(s) {
		fmt.printfln("  call %s  peak %d participants, e2ee %v", short_id(r.call), r.peak, r.e2ee)
		for e in r.speakers {
			fmt.printfln("    speaker  t=%6.2fs  %s", e.t, e.handle)
		}
		for e in r.tiers {
			fmt.printfln("    tier     t=%6.2fs  %s -> %s (est %.0f kbit/s)", e.t, e.handle, pcp.TIER_NAMES[e.tier], e.est)
		}
		for p in r.parts {
			fmt.printfln("    %-10s src %d  in %.0f kbit/s  out %.0f kbit/s  tier %s  layer0 fwd %.0f KB  layer1 fwd %.0f KB",
				p.handle, p.src, p.rx_kbps, p.tx_kbps, pcp.TIER_NAMES[p.tier.tier],
				f64(p.fwd_layer_bytes[0]) / 1024, f64(p.fwd_layer_bytes[1]) / 1024)
		}
		for p in r.departed {
			fmt.printfln("    %-10s src %d  %.1f s in the call, mean in %.0f kbit/s, out %.0f kbit/s, last tier %s, forwarded to it L0 %.0f KB / L1 %.0f KB",
				p.handle, p.src, p.secs, p.rx_kbps, p.tx_kbps, pcp.TIER_NAMES[p.tier], f64(p.fwd[0]) / 1024, f64(p.fwd[1]) / 1024)
		}
	}
}

write_summary :: proc(s: ^Sfu, path: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"rx_pkts":%d,"tx_pkts":%d,"rx_bytes":%d,"tx_bytes":%d,"rejected":%d,"bad_token":%d,"rooms":[`,
		s.rx_pkts, s.tx_pkts, s.rx_bytes, s.tx_bytes, s.rejected, s.bad_token)
	for r, ri in all_rooms(s) {
		if ri > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `{{"call":"%s","peak":%d,"e2ee":%v,"speakers":[`, r.call, r.peak, r.e2ee)
		for e, i in r.speakers {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"t":%.3f,"unix_ms":%d,"src":%d,"handle":"%s"}}`, e.t, e.unix_ms, e.src, e.handle)
		}
		strings.write_string(&b, `],"tiers":[`)
		for e, i in r.tiers {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"t":%.3f,"handle":"%s","tier":"%s","est":%.0f}}`, e.t, e.handle, pcp.TIER_NAMES[e.tier], e.est)
		}
		strings.write_string(&b, `],"parts":[`)
		n := 0
		for p in r.parts {
			if n > 0 {
				strings.write_byte(&b, ',')
			}
			n += 1
			fmt.sbprintf(&b, `{{"handle":"%s","src":%d,"rx_kbps":%.1f,"tx_kbps":%.1f,"tier":"%s","fwd_l0":%d,"fwd_l1":%d,"kf_requests":%d}}`,
				p.handle, p.src, p.rx_kbps, p.tx_kbps, pcp.TIER_NAMES[p.tier.tier], p.fwd_layer_bytes[0], p.fwd_layer_bytes[1], p.kf_requests)
		}
		for p in r.departed {
			if n > 0 {
				strings.write_byte(&b, ',')
			}
			n += 1
			fmt.sbprintf(&b, `{{"handle":"%s","src":%d,"rx_kbps":%.1f,"tx_kbps":%.1f,"tier":"%s","fwd_l0":%d,"fwd_l1":%d,"kf_requests":%d}}`,
				p.handle, p.src, p.rx_kbps, p.tx_kbps, pcp.TIER_NAMES[p.tier], p.fwd[0], p.fwd[1], p.kf_requests)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}\n")
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}
