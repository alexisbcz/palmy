package call

// ---------------------------------------------------------------------------
// SFU mode: a call with any number of people, through palm-sfu.
//
//	call --sfu 127.0.0.1:47900 --join-token TOKEN
//
// The two-party call in session.odin talks to one peer. This talks to an SFU
// and, through it, to everyone else in the call. What is shared with the
// two-party path, unchanged, is everything that touches a device or a codec:
// the capture processes, the Opus encoder, the H.264 encoder and its
// keyframe-by-restart, the jitter buffer, the reassembler and the H.264
// decoder child. What is new is here:
//
//  * PCP2 framing (cloud/rtc/pcp): a source id the SFU stamps, a simulcast
//    layer, and an RFC 6464 audio level byte.
//  * Two video encoders, one per simulcast layer: 640x360 @ 30 fps / 300
//    kbit/s and 320x180 @ 15 fps / 90 kbit/s. The SFU picks per receiver.
//  * One jitter buffer, Opus decoder, reassembler and H.264 decoder per
//    remote participant, and a mixer that sums everyone's decoded audio into
//    the one playback stream.
//  * SFrame end-to-end encryption of every frame, with per-sender keys
//    sealed pairwise over X25519 and rotated on every join and leave, and a
//    safety code to compare (cloud/rtc/pcp/keys.odin).
//  * Receiver feedback (loss, received rate) every 500 ms, which is what the
//    SFU's tier choice runs on.
//
// No database and no chat connection: the join token (minted by the chat
// gateway) is the whole of what this process knows about the call before the
// SFU tells it the rest.
// ---------------------------------------------------------------------------

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:strings"
import "core:time"
import p "palmy:."
import pcp "../../cloud/rtc/pcp"

ROOM_JOIN_REPEAT :: 0.4
ROOM_STATE_EVERY :: 0.5
ROOM_FEEDBACK_EVERY :: 0.5
ROOM_KEY_RESEND :: 1.0
ROOM_TIMEOUT :: 5.0
ROOM_JOIN_GIVE_UP :: 10.0

// The two simulcast layers.
LAYER_LO_W :: 320
LAYER_LO_H :: 180
LAYER_LO_FPS :: 15
LAYER_LO_KBPS :: 90

Room_State :: enum {
	Joining,
	Joined,
	Ended,
}

Spk_Mark :: struct {
	t:       f64, // seconds since join
	unix_ms: i64,
	src:     u16,
	name:    string,
}

Remote :: struct {
	src:      u16,
	id:       string,
	handle:   string,
	name:     string,
	color:    string,
	pub:      [32]u8,
	has_pub:  bool,
	muted:    bool,
	cam_off:  bool,
	present:  bool,

	// Audio.
	jb:       Jitter,
	dec:      ^Opus_Decoder,
	level:    f32, // meter, 0..1
	a_rx:     int,
	a_play:   Audio_Stats, // capture → played
	a_wire:   Audio_Stats, // capture → received
	jitter_us:    f64, // RFC 3550 interarrival jitter
	last_transit: f64,
	have_transit: bool,

	// Video.
	reasm:     Reassembler,
	h264:      H264_Decoder,
	img:       p.Image,
	has_img:   bool,
	need_kf:   bool,
	rx_frame:  u32,
	have_rx:   bool,
	layer:     u8,
	have_layer: bool,
	last_pli:  f64,
	v_frames:  int,
	v_layer_frames: [2]int,
	v_layer_bytes:  [2]int,
	v_lat:     Audio_Stats, // reused: capture → decoded, µs
	kf_rx:     int,
	fps_rx:    f32,
	fps_at:    f64,
	fps_n0:    int,

	// Loss accounting by sequence number, per stream (0 audio, 1 video L0,
	// 2 video L1), for this receiver's feedback.
	seq:       [3]u16,
	have_seq:  [3]bool,
	expected:  int,
	received:  int,
	lost:      int,

	// E2EE, as seen from here.
	no_key:      int,
	bad_auth:    int,
	replays:     int,
	wrong_src:   int,
}

Room :: struct {
	app:      ^App,
	sock:     net.UDP_Socket,
	sfu:      net.Endpoint,
	token:    string,
	me:       pcp.Join, // our own token's claims, read without verifying
	state:    Room_State,
	reason:   string,
	src:      u16,
	call:     string,
	e2ee:     bool,
	kp:       pcp.Keypair,
	pub_b64:  string,
	remotes:  [dynamic]^Remote,
	speaker:  u16,
	stage:    u16, // the last dominant speaker who is not us: who speaker view shows
	marks:    [dynamic]Spk_Mark,
	tier:     string,
	tier_est: f64,
	tier_log: [dynamic]string,

	// Sending.
	seq:      [4]u16, // audio, video L0, video L1, control
	frame:    [3]u32,
	txbuf:    [pcp.MAX_PACKET]u8,
	enc:      []u8,
	dec:      []u8, // decrypted frames land here: AES-GCM wants dst and ct to alias exactly or not at all

	// E2EE, our side. `cur` encrypts now; `next`, once distributed, takes
	// over at `switch_at`. Both are heap-allocated so their AEAD context
	// never moves.
	gen:       u16,
	cur:       ^pcp.Sframe_Key,
	cur_base:  [pcp.BASE_KEY_SIZE]u8,
	next:      ^pcp.Sframe_Key,
	next_base: [pcp.BASE_KEY_SIZE]u8,
	switch_at: f64,
	rotations: int,
	ring:      pcp.Keyring,
	keyed_srcs: [dynamic]u16, // who our current generation was sealed to
	safety:    string,
	last_key:  f64,
	frames_encrypted: int,

	// Timers.
	t:          f64,
	joined_at:  f64,
	started_at: f64,
	last_join:  f64,
	last_state: f64,
	last_fb:    f64,
	last_rx:    f64,

	// Receive-side link emulation (`--recv-cap`): a token bucket on what
	// arrives, so a constrained downlink can be measured on loopback. What it
	// drops is real loss as far as everything downstream is concerned.
	cap_kbps:    f64,
	bucket:      f64,
	bucket_t:    f64,
	cap_dropped: int,

	// Counters.
	tx_pkts, tx_bytes:   int,
	rx_pkts, rx_bytes:   int,
	rx_bad:              int,
	win_bytes:           int,
	rx_kbps:             f64,
	tx_kbps:             f64,
	rate_at:             f64,
	rate_tx0, rate_rx0:  int,

	mix: [A_FRAME_SAMPLES]i32,
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

room_open :: proc(app: ^App, sfu_addr, token: string, cap_kbps: f64) -> (r: ^Room, err: string) {
	ep, ok := net.parse_endpoint(sfu_addr)
	if !ok {
		return nil, fmt.aprintf("--sfu needs HOST:PORT, got %q", sfu_addr)
	}
	me, mok := pcp.token_peek(token)
	if !mok {
		return nil, "the join token is not readable"
	}
	sock, serr := net.make_bound_udp_socket(LOOPBACK, 0)
	if serr != nil {
		return nil, fmt.aprintf("cannot open a UDP socket: %v", serr)
	}
	net.set_blocking(sock, false)
	net.set_option(sock, .Receive_Buffer_Size, 2 << 20)
	net.set_option(sock, .Send_Buffer_Size, 1 << 20)

	r = new(Room)
	r.app = app
	r.sock = sock
	r.sfu = ep
	r.token = strings.clone(token)
	r.me = me
	r.kp = pcp.keypair_generate()
	r.pub_b64 = base64.encode(r.kp.public[:])
	r.enc = make([]u8, V_MAX_FRAME + pcp.SF_MAX_HEADER + pcp.SF_NT)
	r.dec = make([]u8, REASM_CAP)
	r.cap_kbps = cap_kbps
	r.tier = strings.clone("high")
	r.state = .Joining
	r.last_join = -100
	return r, ""
}

room_close :: proc(r: ^Room) {
	if r.state == .Joined {
		for _ in 0 ..< 3 {
			room_ctl(r, .Leave, "{}")
		}
	}
	for rm in r.remotes {
		remote_destroy(rm)
	}
	delete(r.remotes)
	pcp.keyring_destroy(&r.ring)
	if r.cur != nil {
		pcp.sframe_key_clear(r.cur)
		free(r.cur)
	}
	if r.next != nil {
		pcp.sframe_key_clear(r.next)
		free(r.next)
	}
	net.close(r.sock)
}

remote_new :: proc(src: u16) -> ^Remote {
	rm := new(Remote)
	rm.src = src
	e: i32
	rm.dec = opus_decoder_create(A_RATE, A_CHANNELS, &e)
	if e != 0 {
		rm.dec = nil
	}
	reasm_init(&rm.reasm)
	rm.h264.pending = make([dynamic]u8, 0, 64 * 1024)
	rm.name = strings.clone("…")
	rm.handle = strings.clone("")
	rm.id = strings.clone("")
	rm.color = strings.clone("zinc")
	return rm
}

remote_destroy :: proc(rm: ^Remote) {
	if rm.dec != nil {
		opus_decoder_destroy(rm.dec)
	}
	reasm_destroy(&rm.reasm)
	h264_dec_destroy(&rm.h264)
	if rm.has_img {
		p.image_destroy(&rm.img)
	}
	delete(rm.name)
	delete(rm.handle)
	delete(rm.id)
	delete(rm.color)
	free(rm)
}

find_remote :: proc(r: ^Room, src: u16) -> ^Remote {
	for rm in r.remotes {
		if rm.src == src {
			return rm
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

room_send_dg :: proc(r: ^Room, dg: []u8) {
	if dg == nil {
		return
	}
	n, err := net.send_udp(r.sock, dg, r.sfu)
	if err == nil {
		r.tx_pkts += 1
		r.tx_bytes += n
	}
}

room_ctl :: proc(r: ^Room, kind: pcp.Kind, body: string) {
	r.seq[3] += 1
	room_send_dg(r, pcp.control_into(r.txbuf[:], kind, body, r.seq[3], now_us()))
}

// room_level_byte is the RFC 6464 octet for one captured frame.
room_level_byte :: proc(pcm: []i16) -> u8 {
	acc: f64
	for s in pcm {
		v := f64(s) / 32768
		acc += v * v
	}
	return pcp.level_byte(math.sqrt(acc / f64(max(1, len(pcm)))))
}

// room_send_media is where the capture engines' frames end up in SFU mode:
// sealed as one SFrame ciphertext, then cut into PCP2 fragments.
room_send_media :: proc(
	r: ^Room,
	ptype: Payload_Type,
	data: []u8,
	ts_us: u64,
	extra_flags: u8,
	layer: u8,
	level: u8,
) {
	if r.state != .Joined || ptype == .Control {
		return
	}
	pt := pcp.Ptype(u8(ptype))
	stream := pcp.is_video(pt) ? 1 + int(min(layer, 1)) : 0
	if r.app.a.muted && stream == 0 {
		// Muted audio is encoded silence (see audio.odin); its level says so.
	}
	payload := data
	flags := extra_flags & FLAG_KEYFRAME
	if r.e2ee {
		if r.cur == nil {
			return // no key yet: send nothing rather than send it in the clear
		}
		mb: [16]u8
		md := pcp.frame_metadata(mb[:], pt, flags != 0, layer, ts_us)
		if len(data) + pcp.SF_MAX_HEADER + pcp.SF_NT > len(r.enc) {
			return
		}
		payload = pcp.sframe_seal(r.cur, md, data, r.enc)
		flags |= pcp.FLAG_E2EE
		r.frames_encrypted += 1
	}
	r.frame[stream] += 1
	h := pcp.Header {
		ptype = pt,
		flags = flags,
		ts_us = ts_us,
		frame = r.frame[stream],
		layer = layer,
		level = level,
	}
	nf := pcp.fragment_count(len(payload))
	for i in 0 ..< nf {
		h.seq = r.seq[stream]
		r.seq[stream] += 1
		room_send_dg(r, pcp.fragment_into(r.txbuf[:], payload, i, h))
	}
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

// room_seal_to sends one sealed copy of a base key to one participant.
room_seal_to :: proc(r: ^Room, rm: ^Remote, kid: u64, base: []u8) {
	if !rm.has_pub {
		return
	}
	sealed: [pcp.SEALED_SIZE]u8
	if !pcp.seal_base_key(&r.kp, rm.pub[:], kid, r.call, base, &sealed) {
		return
	}
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "to", i64(rm.src))
	pcp.obj_int(&o, "kid", i64(kid))
	pcp.obj_str(&o, "sealed", base64.encode(sealed[:], allocator = context.temp_allocator))
	room_ctl(r, .Key, pcp.obj_end(&o))
}

// room_keyed_set is who should hold our key right now: everyone present
// whose public key we know.
room_keyed_set :: proc(r: ^Room) -> []u16 {
	out := make([dynamic]u16, context.temp_allocator)
	for rm in r.remotes {
		if rm.present && rm.has_pub {
			append(&out, rm.src)
		}
	}
	return out[:]
}

same_set :: proc(a, b: []u16) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x in a {
		found := false
		for y in b {
			if x == y {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// room_rotate starts a new key generation: sealed to the current room, used
// for encryption ROTATE_DELAY later so the receivers have it first.
room_rotate :: proc(r: ^Room) {
	if !r.e2ee {
		return
	}
	r.gen += 1
	if r.next != nil {
		pcp.sframe_key_clear(r.next)
		free(r.next)
	}
	r.next = new(pcp.Sframe_Key)
	crypto_rand(r.next_base[:])
	kid := pcp.kid_of(r.src, r.gen)
	pcp.sframe_key_init(r.next, kid, r.next_base[:])
	set := room_keyed_set(r)
	clear(&r.keyed_srcs)
	append(&r.keyed_srcs, ..set)
	for rm in r.remotes {
		if rm.present {
			room_seal_to(r, rm, kid, r.next_base[:])
		}
	}
	// With nobody else in the room there is nobody to wait for.
	r.switch_at = len(set) == 0 ? r.t : r.t + pcp.ROTATE_DELAY
	r.rotations += 1
	room_update_safety(r)
}

room_keys_tick :: proc(r: ^Room) {
	if !r.e2ee || r.state != .Joined {
		return
	}
	// Membership changed since the current generation was sealed: rotate.
	set := room_keyed_set(r)
	if r.next == nil && !same_set(set, r.keyed_srcs[:]) {
		room_rotate(r)
	}
	if r.next != nil && r.t >= r.switch_at {
		if r.cur != nil {
			pcp.sframe_key_clear(r.cur)
			free(r.cur)
		}
		r.cur, r.next = r.next, nil
		r.cur_base = r.next_base
	}
	// Keys travel over UDP, so the current one is resent once a second. It
	// is sealed afresh each time (a new nonce) and is idempotent to receive.
	if r.t - r.last_key >= ROOM_KEY_RESEND {
		r.last_key = r.t
		if r.cur != nil {
			for rm in r.remotes {
				if rm.present {
					for s in r.keyed_srcs {
						if s == rm.src {
							room_seal_to(r, rm, r.cur.kid, r.cur_base[:])
						}
					}
				}
			}
		}
	}
	pcp.keyring_prune(&r.ring, r.t, set)
}

room_update_safety :: proc(r: ^Room) {
	entries := make([dynamic]pcp.Safety_Entry, context.temp_allocator)
	append(&entries, pcp.Safety_Entry{id = r.me.id, pub = r.kp.public})
	for rm in r.remotes {
		if rm.present && rm.has_pub {
			append(&entries, pcp.Safety_Entry{id = rm.id, pub = rm.pub})
		}
	}
	delete(r.safety)
	r.safety = pcp.safety_code(entries[:])
}

// ---------------------------------------------------------------------------
// Receiving
// ---------------------------------------------------------------------------

room_pump_receive :: proc(r: ^Room) {
	rx: [pcp.MAX_PACKET + 64]u8
	for _ in 0 ..< RX_BUDGET {
		n, from, err := net.recv_udp(r.sock, rx[:])
		if err != nil || n <= 0 {
			break
		}
		if from.port != r.sfu.port {
			r.rx_bad += 1
			continue
		}
		h, payload, ok := pcp.parse(rx[:n])
		if !ok {
			r.rx_bad += 1
			continue
		}
		if h.ptype != .Control && r.cap_kbps > 0 {
			// The emulated downlink: refill, then admit or drop.
			now := r.t
			rate := r.cap_kbps * 1000 / 8
			r.bucket = min(r.bucket + (now - r.bucket_t) * rate, rate * 0.25)
			r.bucket_t = now
			if r.bucket < f64(n) {
				r.cap_dropped += 1
				continue
			}
			r.bucket -= f64(n)
		}
		r.rx_pkts += 1
		r.rx_bytes += n
		r.win_bytes += n
		r.last_rx = r.t
		if h.ptype == .Control {
			kind, o, cok := pcp.control_parse(payload)
			if cok {
				room_control(r, kind, o)
			}
			continue
		}
		rm := find_remote(r, h.src)
		if rm == nil || !rm.present {
			continue
		}
		room_count_seq(rm, h)
		if pcp.is_audio(h.ptype) {
			room_rx_audio(r, rm, h, payload)
		} else {
			room_rx_video(r, rm, h, payload)
		}
	}
}

room_count_seq :: proc(rm: ^Remote, h: pcp.Header) {
	stream := pcp.is_video(h.ptype) ? 1 + int(min(h.layer, 1)) : 0
	if stream > 0 {
		// The SFU switches us between a sender's layers; the other layer's
		// counter is stale from the moment we leave it.
		other := stream == 1 ? 2 : 1
		rm.have_seq[other] = false
	}
	if !rm.have_seq[stream] {
		rm.have_seq[stream] = true
		rm.seq[stream] = h.seq
		rm.expected += 1
		rm.received += 1
		return
	}
	d := int(i16(h.seq - rm.seq[stream]))
	if d > 0 {
		rm.expected += d
		rm.lost += d - 1
		rm.seq[stream] = h.seq
	}
	rm.received += 1
}

// room_open_frame removes SFrame from a reassembled frame. A KID must belong
// to the source the SFU stamped: a frame that decrypts under someone else's
// key is someone else's frame, relabelled, and is refused.
room_open_frame :: proc(r: ^Room, rm: ^Remote, h: pcp.Header, ts: u64, frame: []u8, out: []u8) -> ([]u8, bool) {
	if h.flags & pcp.FLAG_E2EE == 0 {
		// A clear frame in an encrypted call is refused outright: accepting
		// it would let the SFU inject media.
		if r.e2ee {
			rm.bad_auth += 1
			return nil, false
		}
		return frame, true
	}
	kid, kok := pcp.sframe_peek(frame)
	if !kok {
		rm.bad_auth += 1
		return nil, false
	}
	if pcp.kid_src(kid) != rm.src {
		rm.wrong_src += 1
		return nil, false
	}
	k := pcp.keyring_find(&r.ring, kid)
	if k == nil {
		rm.no_key += 1
		return nil, false
	}
	mb: [16]u8
	md := pcp.frame_metadata(mb[:], h.ptype, pcp.keyframed(h), h.layer, ts)
	pt, err := pcp.sframe_open(k, md, frame, out)
	switch err {
	case .None:
		return pt, true
	case .Replay:
		rm.replays += 1
	case .Auth, .Malformed:
		rm.bad_auth += 1
	}
	return nil, false
}

room_rx_audio :: proc(r: ^Room, rm: ^Remote, h: pcp.Header, payload: []u8) {
	if h.nfrag != 1 {
		return
	}
	out: [A_MAX_PACKET]u8
	pt, ok := room_open_frame(r, rm, h, h.ts_us, payload, out[:])
	if !ok {
		return
	}
	rm.a_rx += 1
	now := f64(now_us())
	wire := now - f64(h.ts_us)
	rm.a_wire.wire_last_us = wire
	stat_add(&rm.a_wire, wire)
	// RFC 3550 §6.4.1 interarrival jitter, in microseconds.
	if rm.have_transit {
		d := abs(wire - rm.last_transit)
		rm.jitter_us += (d - rm.jitter_us) / 16
	}
	rm.last_transit = wire
	rm.have_transit = true
	jb_push(&rm.jb, h.seq, h.ts_us, pt)
}

room_rx_video :: proc(r: ^Room, rm: ^Remote, h: pcp.Header, payload: []u8) {
	if rm.have_layer && h.layer != rm.layer {
		// The SFU moved us to the other simulcast layer. It only does that at
		// a keyframe, so a fresh reassembler and decoder state is right.
		reasm_reset(&rm.reasm)
		rm.have_rx = false
		rm.need_kf = true
	}
	rm.layer = h.layer
	rm.have_layer = true
	ch := Header {
		ptype = Payload_Type(u8(h.ptype)),
		flags = h.flags & (FLAG_MARKER | FLAG_KEYFRAME),
		seq   = h.seq,
		ts_us = h.ts_us,
		frame = h.frame,
		frag  = h.frag,
		nfrag = h.nfrag,
	}
	frame, ts, done := reasm_push(&rm.reasm, ch, payload)
	if !done {
		return
	}
	kf := pcp.keyframed(h)
	if rm.have_rx && seq_newer_u32(h.frame, rm.rx_frame) && h.frame != rm.rx_frame + 1 {
		rm.need_kf = true
		room_request_keyframe(r, rm)
	}
	rm.rx_frame = h.frame
	rm.have_rx = true

	plain, ok := room_open_frame(r, rm, h, ts, frame, r.dec)
	if !ok {
		return
	}
	l := int(min(h.layer, 1))
	rm.v_layer_frames[l] += 1
	rm.v_layer_bytes[l] += len(frame)
	if kf {
		rm.kf_rx += 1
	}

	if h.ptype == .Video_H264 {
		if rm.need_kf {
			if !kf {
				room_request_keyframe(r, rm)
				return
			}
			rm.need_kf = false
		}
		if !rm.h264.ch.running {
			dw, dh := decoder_output_size(v_width, v_height)
			if !h264_dec_start(&rm.h264, dw, dh) {
				return
			}
			if !kf {
				rm.need_kf = true
				room_request_keyframe(r, rm)
				return
			}
		}
		if !h264_dec_push(&rm.h264, plain, ts) {
			rm.need_kf = true
			room_request_keyframe(r, rm)
		}
		return
	}
	if decode_into(&rm.img, &rm.has_img, plain) {
		room_count_decoded(rm, ts)
	}
}

room_count_decoded :: proc(rm: ^Remote, cap_ts: u64) {
	rm.v_frames += 1
	if cap_ts != 0 {
		stat_add(&rm.v_lat, f64(now_us() - cap_ts))
	}
}

room_request_keyframe :: proc(r: ^Room, rm: ^Remote) {
	if r.t - rm.last_pli < V_PLI_GAP {
		return
	}
	rm.last_pli = r.t
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_int(&o, "src", i64(rm.src))
	room_ctl(r, .Keyframe, pcp.obj_end(&o))
}

room_control :: proc(r: ^Room, kind: pcp.Kind, o: json.Object) {
	app := r.app
	#partial switch kind {
	case .Welcome:
		if r.state != .Joining {
			return
		}
		r.src = u16(pcp.oint(o, "src"))
		delete(r.call)
		r.call = strings.clone(pcp.ostr(o, "call"))
		r.e2ee = pcp.obool(o, "e2ee")
		r.state = .Joined
		r.joined_at = r.t
		log_line(app, "joined the call as source %d%s", r.src, r.e2ee ? ", end-to-end encrypted" : "")
		if r.e2ee {
			room_rotate(r)
		}
		room_start_media(app)
	case .Peer:
		src := u16(pcp.oint(o, "src"))
		if src == r.src || src == 0 {
			return
		}
		rm := find_remote(r, src)
		if rm == nil {
			rm = remote_new(src)
			append(&r.remotes, rm)
			rm.present = true
		}
		set_str :: proc(dst: ^string, v: string) {
			if dst^ != v {
				delete(dst^)
				dst^ = strings.clone(v)
			}
		}
		set_str(&rm.id, pcp.ostr(o, "id"))
		set_str(&rm.handle, pcp.ostr(o, "handle"))
		set_str(&rm.name, pcp.ostr(o, "name"))
		set_str(&rm.color, pcp.ostr(o, "color"))
		rm.muted = pcp.obool(o, "muted")
		rm.cam_off = pcp.obool(o, "cam_off")
		raw, derr := base64.decode(pcp.ostr(o, "pub"), allocator = context.temp_allocator)
		if derr == nil && len(raw) == 32 {
			was := rm.has_pub
			copy(rm.pub[:], raw)
			rm.has_pub = true
			if !was {
				room_update_safety(r)
			}
		}
	case .Roster:
		srcs := pcp.oarr(o, "srcs")
		for rm in r.remotes {
			rm.present = false
		}
		for v in srcs {
			src: u16
			#partial switch x in v {
			case json.Integer:
				src = u16(x)
			case json.Float:
				src = u16(x)
			}
			if src == r.src {
				continue
			}
			if rm := find_remote(r, src); rm != nil {
				rm.present = true
			}
		}
		for i := len(r.remotes) - 1; i >= 0; i -= 1 {
			rm := r.remotes[i]
			if !rm.present && rm.has_pub {
				log_line(app, "%s left the call", rm.name)
				remote_destroy(rm)
				ordered_remove(&r.remotes, i)
			}
		}
		room_update_safety(r)
		if sp := u16(pcp.oint(o, "speaker")); sp != 0 && r.speaker == 0 {
			room_set_speaker(r, sp)
		}
	case .Speaker:
		room_set_speaker(r, u16(pcp.oint(o, "src")))
	case .Keyframe:
		layer := pcp.oint(o, "layer")
		v := layer == 1 ? &app.v_lo : &app.v
		video_on_keyframe_request(v, r.t)
	case .Key:
		from := u16(pcp.oint(o, "from"))
		kid := u64(pcp.oint(o, "kid"))
		rm := find_remote(r, from)
		if rm == nil || !rm.has_pub || pcp.kid_src(kid) != from {
			return
		}
		if pcp.keyring_find(&r.ring, kid) != nil {
			return
		}
		sealed, derr := base64.decode(pcp.ostr(o, "sealed"), allocator = context.temp_allocator)
		if derr != nil {
			return
		}
		base: [pcp.BASE_KEY_SIZE]u8
		if pcp.open_base_key(&r.kp, rm.pub[:], kid, r.call, sealed, &base) {
			pcp.keyring_add(&r.ring, kid, base[:], r.t)
		}
	case .Tier:
		t := pcp.ostr(o, "tier")
		if t != r.tier {
			delete(r.tier)
			r.tier = strings.clone(t)
			r.tier_est = pcp.ofloat(o, "est")
			msg := fmt.aprintf("%.2fs tier -> %s (estimate %.0f kbit/s)", r.t - r.joined_at, t, r.tier_est)
			append(&r.tier_log, msg)
			log_line(app, "the SFU moved this receiver to %s", t)
		}
	case .Error:
		code := pcp.ostr(o, "code")
		r.reason = fmt.aprintf("%s", pcp.ostr(o, "msg"))
		log_line(app, "SFU: %s (%s)", r.reason, code)
		if r.state != .Ended {
			r.state = .Ended
			stop_media(app)
		}
	}
}

room_set_speaker :: proc(r: ^Room, src: u16) {
	if src == r.speaker {
		return
	}
	r.speaker = src
	if src != r.src {
		r.stage = src
	}
	name := "you"
	if rm := find_remote(r, src); rm != nil {
		name = rm.name
	}
	append(&r.marks, Spk_Mark{t = r.t - r.joined_at, unix_ms = time.time_to_unix_nano(time.now()) / 1e6, src = src, name = strings.clone(name)})
}

// ---------------------------------------------------------------------------
// Playout: every remote participant's audio, mixed.
// ---------------------------------------------------------------------------

room_flush :: proc(a: ^Audio) -> bool {
	if a.out_off >= a.out_n {
		return true
	}
	n, broken := child_write(&a.play, a.out[a.out_off:a.out_n])
	a.out_off += n
	if n > 0 {
		if a.play_t0 == 0 {
			a.play_t0 = now_us()
		}
		a.play_written += n
		update_play_queue(a)
	}
	if broken {
		a.play_error = "player closed the pipe"
		child_stop(&a.play)
		a.out_off = a.out_n
		return true
	}
	return a.out_off >= a.out_n
}

room_pump_playout :: proc(r: ^Room, dt: f32) {
	a := &r.app.a
	if !a.play.running {
		return
	}
	for rm in r.remotes {
		jb_trim(&rm.jb)
	}
	a.play_queue_us = play_queue_now(a)
	for _ in 0 ..< PLAYOUT_BURST {
		if !room_flush(a) {
			break
		}
		if play_primed(a) && a.play_queue_us > PLAYOUT_TARGET_US {
			break
		}
		for i in 0 ..< A_FRAME_SAMPLES {
			r.mix[i] = 0
		}
		any := false
		for rm in r.remotes {
			if !rm.present || rm.dec == nil {
				continue
			}
			pkt: [A_MAX_PACKET]u8
			n, ts, res := jb_pop(&rm.jb, pkt[:])
			if res == .Starved {
				meter_follow(&rm.level, 0, dt)
				continue
			}
			pcm: [A_FRAME_SAMPLES]i16
			got: i32
			if res == .Concealed {
				got = opus_decode(rm.dec, nil, 0, raw_data(pcm[:]), A_FRAME_SAMPLES, 0)
			} else {
				got = opus_decode(rm.dec, raw_data(pkt[:n]), i32(n), raw_data(pcm[:]), A_FRAME_SAMPLES, 0)
				if got > 0 {
					stat_add(&rm.a_play, f64(now_us() - ts))
				}
			}
			if got <= 0 {
				continue
			}
			for i in 0 ..< int(got) {
				r.mix[i] += i32(pcm[i])
			}
			meter_follow(&rm.level, frame_rms(pcm[:got]), dt)
			any = true
		}
		if !any {
			break
		}
		out := (cast([^]i16)raw_data(a.out[:]))[:A_FRAME_SAMPLES]
		for i in 0 ..< A_FRAME_SAMPLES {
			out[i] = i16(clamp(r.mix[i], -32768, 32767))
		}
		a.out_n = A_FRAME_BYTES
		a.out_off = 0
		a.frames_played += 1
		meter_follow(&a.rx_level, frame_rms(out), dt)
		if !room_flush(a) {
			break
		}
	}
}

room_pump_decoders :: proc(r: ^Room) {
	for rm in r.remotes {
		for {
			px, cap_ts, _, ok := h264_dec_pump(&rm.h264)
			if !ok {
				break
			}
			publish_bgra(&rm.img, &rm.has_img, px, rm.h264.w, rm.h264.h)
			room_count_decoded(rm, cap_ts)
		}
		if rm.fps_at == 0 {
			rm.fps_at = r.t
		} else if r.t - rm.fps_at >= 1 {
			rm.fps_rx = f32(rm.v_frames - rm.fps_n0) / f32(r.t - rm.fps_at)
			rm.fps_at = r.t
			rm.fps_n0 = rm.v_frames
		}
	}
	// Our own picture, for the self tile.
	for {
		px, _, _, ok := h264_dec_pump(&r.app.v.dec_self)
		if !ok {
			break
		}
		if !r.app.v.camera_off {
			publish_bgra(&r.app.v.local, &r.app.v.has_local, px, r.app.v.dec_self.w, r.app.v.dec_self.h)
		}
	}
}

// ---------------------------------------------------------------------------
// The step
// ---------------------------------------------------------------------------

room_start_media :: proc(app: ^App) {
	sink := sel_sink(&app.devs)
	src, cam := resolve_capture(app.allow_real, sel_source(&app.devs), sel_camera(&app.devs))
	if app.talk != "" {
		synth_tone = talk_expression(app.talk, app.talk_period, app.tone, app.epoch)
	}
	audio_start(&app.a, src, sink)
	codec := negotiate_video(app.v.offer, CODEC_ALL)
	app.v.room_mode = true
	app.v.layer = 0
	video_start(&app.v, cam, codec)
	app.v_lo.room_mode = true
	app.v_lo.no_self = true
	app.v_lo.layer = 1
	app.v_lo.enc_w, app.v_lo.enc_h = LAYER_LO_W, LAYER_LO_H
	app.v_lo.enc_fps, app.v_lo.enc_kbps = LAYER_LO_FPS, LAYER_LO_KBPS
	video_start(&app.v_lo, cam, codec)
	log_line(app, "publishing %s: %dx%d@%d and %dx%d@%d", video_codec_name(codec), v_width, v_height, v_fps, LAYER_LO_W, LAYER_LO_H, LAYER_LO_FPS)
}

// talk_expression builds the synthetic microphone for a scheduled talker:
// a tone of `freq` Hz, loud inside the windows of `spec` ("0-4,12-16"),
// repeating every `period` seconds, and 50 dB down outside them. `epoch` is
// a shared unix time, so several processes started a little apart still take
// their turns on the same clock.
talk_expression :: proc(spec: string, period: f64, freq: int, epoch: f64) -> string {
	off := 0.0
	if epoch > 0 {
		off = f64(time.time_to_unix_nano(time.now())) / 1e9 - epoch
	}
	cond := strings.builder_make(context.temp_allocator)
	for part, i in strings.split(spec, ",", context.temp_allocator) {
		dash := strings.index_byte(part, '-')
		if dash < 0 {
			continue
		}
		if i > 0 {
			strings.write_byte(&cond, '+')
		}
		// ffmpeg's mod() keeps the sign of its first argument, and the offset
		// is negative until the shared epoch arrives, so shift by whole
		// periods to keep it positive.
		shifted := period > 0 ? off + period * 1000 : off
		t := period > 0 ? fmt.tprintf("mod(t+%.3f\\,%.3f)", shifted, period) : fmt.tprintf("(t+%.3f)", off)
		fmt.sbprintf(&cond, "between(%s\\,%s\\,%s)", t, part[:dash], part[dash + 1:])
	}
	return fmt.aprintf(
		"aevalsrc=0.6*sin(2*PI*%d*t)*(0.003+0.997*(%s)):s=48000:c=mono,arealtime",
		freq,
		strings.to_string(cond),
	)
}

room_step :: proc(app: ^App, t: f64, dt: f32) {
	r := app.room
	r.t = t
	app.t = t
	app.dt = dt
	app.s.t = t
	if r.started_at == 0 {
		r.started_at = t
		r.bucket_t = t
	}
	room_pump_receive(r)

	switch r.state {
	case .Joining:
		if t - r.last_join >= ROOM_JOIN_REPEAT {
			r.last_join = t
			o: pcp.Obj
			pcp.obj_begin(&o)
			pcp.obj_str(&o, "token", r.token)
			pcp.obj_str(&o, "pub", r.pub_b64)
			room_ctl(r, .Join, pcp.obj_end(&o))
		}
		if t - r.started_at > ROOM_JOIN_GIVE_UP {
			r.state = .Ended
			r.reason = "the SFU did not answer"
		}
	case .Joined:
		if t - r.last_state >= ROOM_STATE_EVERY {
			r.last_state = t
			o: pcp.Obj
			pcp.obj_begin(&o)
			pcp.obj_bool(&o, "muted", app.a.muted)
			pcp.obj_bool(&o, "cam_off", app.v.camera_off)
			room_ctl(r, .State, pcp.obj_end(&o))
		}
		if t - r.last_fb >= ROOM_FEEDBACK_EVERY {
			room_feedback(r, t)
		}
		room_keys_tick(r)
		audio_pump_capture(&app.a, &app.s, dt)
		video_pump_capture(&app.v, &app.s, t)
		video_pump_capture(&app.v_lo, &app.s, t)
		room_pump_playout(r, dt)
		room_pump_decoders(r)
		supervise_room_media(app)
		if t - r.last_rx > ROOM_TIMEOUT && r.last_rx > 0 {
			r.state = .Ended
			r.reason = "lost the SFU"
			stop_media(app)
		}
	case .Ended:
	}

	if r.rate_at == 0 {
		r.rate_at = t
	} else if t - r.rate_at >= 1 {
		d := t - r.rate_at
		r.tx_kbps = f64(r.tx_bytes - r.rate_tx0) * 8 / 1000 / d
		r.rx_kbps = f64(r.rx_bytes - r.rate_rx0) * 8 / 1000 / d
		r.rate_at, r.rate_tx0, r.rate_rx0 = t, r.tx_bytes, r.rx_bytes
	}
}

supervise_room_media :: proc(app: ^App) {
	if app.a.cap.running && app.v.cap.running {
		return
	}
	if app.restarts >= RESTART_LIMIT || app.t - app.last_restart < RESTART_GAP {
		return
	}
	app.restarts += 1
	app.last_restart = app.t
	room_start_media(app)
}

// room_feedback is the receiver report the SFU's tier choice runs on: how
// much of what was sent to us arrived, and how fast.
room_feedback :: proc(r: ^Room, t: f64) {
	d := t - r.last_fb
	r.last_fb = t
	exp, got := 0, 0
	for rm in r.remotes {
		exp += rm.expected
		got += rm.received
		rm.expected, rm.received = 0, 0
	}
	loss := exp > 0 ? 100 * f64(max(0, exp - got)) / f64(exp) : 0
	kbps := d > 0 ? f64(r.win_bytes) * 8 / 1000 / d : 0
	r.win_bytes = 0
	o: pcp.Obj
	pcp.obj_begin(&o)
	pcp.obj_f(&o, "loss", loss)
	pcp.obj_f(&o, "kbps", kbps)
	pcp.obj_f(&o, "cap", 0) // the emulated cap is not declared: the SFU has to find it
	room_ctl(r, .Feedback, pcp.obj_end(&o))
}

// ---------------------------------------------------------------------------
// Headless run and report
// ---------------------------------------------------------------------------

room_headless_run :: proc(app: ^App, seconds: f64, json_out: string) {
	r := app.room
	fmt.printfln("call: SFU mode, %s, joining %s as %s", net.endpoint_to_string(r.sfu), short_call(r.me.call), r.me.name)
	start := time.tick_now()
	last := start
	report := 0.0
	for {
		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last, now)))
		last = now
		t := time.duration_seconds(time.tick_diff(start, now))
		room_step(app, t, clamp(dt, 0, 0.1))
		if t - report >= 1.0 {
			report = t
			room_print_stats(app)
		}
		if seconds > 0 && t > seconds {
			break
		}
		if r.state == .Ended && t - report > 0.5 {
			break
		}
		free_all(context.temp_allocator)
		time.sleep(HEADLESS_TICK)
	}
	room_print_summary(app)
	if json_out != "" {
		room_write_json(app, json_out)
	}
	stop_media(app)
	video_stop(&app.v_lo)
}

short_call :: proc(id: string) -> string {
	return len(id) > 8 ? id[:8] : id
}

room_print_stats :: proc(app: ^App) {
	r := app.room
	b := strings.builder_make(context.temp_allocator)
	for rm in r.remotes {
		fmt.sbprintf(&b, "  %s[L%d %.0ffps a%.1fms v%.1fms]", rm.handle, rm.layer, rm.fps_rx, rm.a_wire.last_us / 1000, rm.v_lat.last_us / 1000)
	}
	spk := "-"
	if r.speaker == r.src {
		spk = "me"
	} else if rm := find_remote(r, r.speaker); rm != nil {
		spk = rm.handle
	}
	fmt.printfln("%5.1fs %-7v tier %-5s speaker %-8s tx %.0f rx %.0f kbit/s%s", r.t, r.state, r.tier, spk, r.tx_kbps, r.rx_kbps, strings.to_string(b))
}

room_print_summary :: proc(app: ^App) {
	r := app.room
	fmt.println("")
	fmt.printfln("── %s, measured over the call ──", r.me.name)
	fmt.printfln("  state            %v%s", r.state, r.reason == "" ? "" : fmt.tprintf(" (%s)", r.reason))
	fmt.printfln("  e2ee             %v, %d key generations, %d frames encrypted, safety code %s", r.e2ee, r.gen, r.frames_encrypted, r.safety)
	fmt.printfln("  sent             %d pkt, %.2f MB; video L0 %d frames, L1 %d frames; audio %d frames",
		r.tx_pkts, f64(r.tx_bytes) / 1e6, app.v.frames_sent, app.v_lo.frames_sent, app.a.frames_sent)
	fmt.printfln("  received         %d pkt, %.2f MB, %d dropped by the emulated link, %d rejected", r.rx_pkts, f64(r.rx_bytes) / 1e6, r.cap_dropped, r.rx_bad)
	for line in r.tier_log {
		fmt.printfln("  tier             %s", line)
	}
	for m in r.marks {
		fmt.printfln("  speaker          %.2fs  %s", m.t, m.name)
	}
	for rm in r.remotes {
		fmt.printfln("  from %-10s audio %d rx, capture→received mean %.2f ms (max %.2f), jitter %.2f ms, capture→played mean %.2f ms",
			rm.handle, rm.a_rx, stat_mean(&rm.a_wire) / 1000, rm.a_wire.max_us / 1000, rm.jitter_us / 1000, stat_mean(&rm.a_play) / 1000)
		fmt.printfln("       %-10s video %d decoded (L0 %d, L1 %d frames, %.0f / %.0f KB), capture→decoded mean %.2f ms, %d keyframes",
			"", rm.v_frames, rm.v_layer_frames[0], rm.v_layer_frames[1], f64(rm.v_layer_bytes[0]) / 1024, f64(rm.v_layer_bytes[1]) / 1024, stat_mean(&rm.v_lat) / 1000, rm.kf_rx)
		fmt.printfln("       %-10s loss %d packets; e2ee: %d without a key yet, %d failed auth, %d replays, %d wrong source",
			"", rm.lost, rm.no_key, rm.bad_auth, rm.replays, rm.wrong_src)
	}
}

room_write_json :: proc(app: ^App, path: string) {
	r := app.room
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"name":"%s","handle":"%s","src":%d,"e2ee":%v,"generations":%d,"safety":"%s","tier":"%s","cap_dropped":%d,`,
		r.me.name, r.me.handle, r.src, r.e2ee, r.gen, r.safety, r.tier, r.cap_dropped)
	fmt.sbprintf(&b, `"sent":{{"l0":%d,"l1":%d,"audio":%d,"l0_kbps":%.1f,"l1_kbps":%.1f}},`,
		app.v.frames_sent, app.v_lo.frames_sent, app.a.frames_sent,
		f64(app.v.bytes_sent) * 8 / 1000 / max(0.001, r.t - r.joined_at),
		f64(app.v_lo.bytes_sent) * 8 / 1000 / max(0.001, r.t - r.joined_at))
	strings.write_string(&b, `"speakers":[`)
	for m, i in r.marks {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `{{"t":%.3f,"unix_ms":%d,"name":"%s"}}`, m.t, m.unix_ms, m.name)
	}
	strings.write_string(&b, `],"from":[`)
	for rm, i in r.remotes {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `{{"handle":"%s","audio_rx":%d,"wire_ms":%.3f,"wire_max_ms":%.3f,"jitter_ms":%.3f,"played_ms":%.3f,`,
			rm.handle, rm.a_rx, stat_mean(&rm.a_wire) / 1000, rm.a_wire.max_us / 1000, rm.jitter_us / 1000, stat_mean(&rm.a_play) / 1000)
		fmt.sbprintf(&b, `"video_frames":%d,"l0_frames":%d,"l1_frames":%d,"l0_kb":%.1f,"l1_kb":%.1f,"video_ms":%.3f,"lost":%d,"no_key":%d,"bad_auth":%d}}`,
			rm.v_frames, rm.v_layer_frames[0], rm.v_layer_frames[1], f64(rm.v_layer_bytes[0]) / 1024, f64(rm.v_layer_bytes[1]) / 1024,
			stat_mean(&rm.v_lat) / 1000, rm.lost, rm.no_key, rm.bad_auth)
	}
	strings.write_string(&b, "]}\n")
	_ = write_file(path, strings.to_string(b))
}
