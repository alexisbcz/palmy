package call

// ---------------------------------------------------------------------------
// The session: one UDP socket, one peer, one state machine.
//
// Both media streams and signalling share a single socket bound to
// 127.0.0.1. Binding to the loopback address specifically, rather than to
// 0.0.0.0, is deliberate and is checked in the self-test: this program
// carries a camera and a microphone and has no business being reachable from
// the network.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:net"
import "core:time"

LOOPBACK :: net.IP4_Address{127, 0, 0, 1}

Call_State :: enum {
	Idle,       // nothing happening
	Dialing,    // we invited, waiting for an answer
	Ringing,    // they invited, waiting for us
	Connecting, // answered, media starting, nothing received yet
	Connected,  // media flowing
	Ended,      // over, with a reason
}

state_label :: proc(s: Call_State) -> string {
	switch s {
	case .Idle:
		return "Ready"
	case .Dialing:
		return "Calling"
	case .Ringing:
		return "Incoming call"
	case .Connecting:
		return "Connecting"
	case .Connected:
		return "Connected"
	case .Ended:
		return "Call ended"
	}
	return ""
}

// Timings, all in seconds. Stated here rather than scattered as literals.
INVITE_REPEAT :: 0.4
STATE_REPEAT :: 0.5
DIAL_TIMEOUT :: 30.0
RING_TIMEOUT :: 45.0
PEER_TIMEOUT :: 5.0 // silence from a connected peer before giving up

Session :: struct {
	sock:      net.UDP_Socket,
	open:      bool,
	bind_port: int,
	peer:      net.Endpoint,
	name:      string,
	peer_name: string,

	state:     Call_State,
	reason:    string,
	t:         f64, // seconds since the app started, updated per frame
	state_at:  f64, // when the current state began
	connected_at: f64,

	last_invite:    f64,
	last_state_tx:  f64,
	last_peer_rx:   f64,

	// What the peer says about itself.
	peer_muted:   bool,
	peer_cam_off: bool,

	// Video codec negotiation. `codecs` is what we can decode and advertise on
	// every control message; `peer_codecs` is what came back. A peer that has
	// never said anything is assumed to speak MJPEG and nothing else, which is
	// the correct reading of silence — see `read_control`.
	codecs:      u8,
	peer_codecs: u8,

	// Counters.
	tx_packets: int,
	rx_packets: int,
	tx_bytes:   int,
	rx_bytes:   int,
	rx_bad:     int,

	// Bitrate, sampled once a second.
	rate_at:    f64,
	rate_tx0:   int,
	rate_rx0:   int,
	tx_kbps:    f32,
	rx_kbps:    f32,

	// Deliberate loss, for exercising the H.264 keyframe path on a transport
	// that has none of its own. `--loss N` drops N of every thousand outgoing
	// *video* fragments; signalling is left alone, because a test of the video
	// loss path should not also be a test of the state machine. The generator
	// is a fixed-seed xorshift, so a run is reproducible.
	drop_permille: int,
	drop_state:    u64,
	tx_dropped:    int,
	drop_until:    f64, // --loss-until: the deliberate loss stops here (0 = never)

	// End-to-end encryption of media (e2ee.odin).
	e2ee: E2ee,

	// Adaptive bitrate (rate.odin): what we measure about the peer's stream,
	// what we report, and the controller that acts on the peer's reports.
	adapt:        bool,
	rate:         Rate_Ctl,
	rx_seq_audio: Seq_Count,
	rx_seq_video: Seq_Count,
	rx_media_w:   int, // video bytes received in the current window
	last_fb_tx:   f64,
	fb_peer_ts:   u64, // capture timestamp of the peer's last FEEDBACK
	fb_peer_at:   u64, // when it arrived, on our clock
	rtt_ms:       f64, // the last round trip measured, -1 before any
	rx_loss:      f64, // the loss we measured over the last window
	peer_loss:    f64, // the loss the peer last reported of our stream
	peer_kbps:    f64,
	fb_rx:        int,
	rate_log:     [dynamic]Rate_Event,

	// --link-kbps: an emulated bottleneck on everything this end sends.
	link:   Link,
	link_q: [dynamic]Link_Packet,

	seq_audio: u16,
	seq_video: u16,
	seq_ctrl:  u16,
	frame_audio: u32,
	frame_video: u32,

	txbuf: [MAX_PACKET]u8,

	// Set in SFU mode (`--sfu`). The capture engines are the same ones the
	// two-party call uses; what changes is where their frames go, and this
	// pointer is that switch: `send_media` hands everything to the room,
	// which encrypts, frames as PCP2 and sends to the SFU instead.
	room: ^Room,
}

// now_us is CLOCK_MONOTONIC_RAW in microseconds. Two processes on one machine
// read the same clock, which is what makes the latency figures in this app
// measurements rather than estimates: the sender's timestamp and the
// receiver's reading are directly comparable with no clock sync at all.
now_us :: proc() -> u64 {
	return u64(time.tick_now()._nsec / 1000)
}

session_open :: proc(s: ^Session, bind_port, peer_port: int, name: string) -> string {
	sock, err := net.make_bound_udp_socket(LOOPBACK, bind_port)
	if err != nil {
		return fmt.aprintf("cannot bind 127.0.0.1:%d (%v)", bind_port, err)
	}
	net.set_blocking(sock, false)
	// A 480p JPEG is ~30 fragments; a stall of a few frames must not be a
	// loss, so ask for a megabyte of kernel receive buffer.
	net.set_option(sock, .Receive_Buffer_Size, 1 << 20)
	net.set_option(sock, .Send_Buffer_Size, 1 << 20)

	s.sock = sock
	s.open = true
	s.bind_port = bind_port
	s.peer = net.Endpoint{LOOPBACK, peer_port}
	s.name = name
	// Cloned, not a literal: `handle_control` replaces this string when the
	// peer announces its name, and freeing a literal is a crash.
	s.peer_name = clone_string("Peer")
	s.codecs = CODEC_ALL
	s.drop_state = 0x5DEECE66D
	s.peer_codecs = CODEC_MJPEG
	s.state = .Idle
	e2ee_init(&s.e2ee)
	s.adapt = true
	rate_init(&s.rate, f64(v_bitrate_kbps))
	s.rtt_ms = -1
	return ""
}

// Rate_Event is one move of the bitrate controller, kept for the summary.
Rate_Event :: struct {
	t:      f64,
	kbps:   f64,
	reason: Rate_Reason,
	loss:   f64,
	rtt_ms: f64,
	applied: bool,
}

// Link_Packet is a datagram inside the emulated link, waiting to leave.
Link_Packet :: struct {
	at:  f64,
	n:   int,
	buf: [MAX_PACKET]u8,
}

session_close :: proc(s: ^Session) {
	if s.open {
		net.close(s.sock)
		s.open = false
	}
	delete(s.peer_name)
	s.peer_name = ""
	e2ee_destroy(&s.e2ee)
	delete(s.rate_log)
	delete(s.link_q)
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

send_datagram :: proc(s: ^Session, dg: []u8) {
	if !s.open || len(dg) == 0 {
		return
	}
	if s.link.kbps > 0 {
		// Through the emulated bottleneck: queued with the time it would
		// leave the far end of the link, or dropped at the tail.
		at, ok := link_admit(&s.link, s.t, len(dg) + 28)
		if ok && len(s.link_q) < 512 {
			append(&s.link_q, Link_Packet{at = at, n = len(dg)})
			copy(s.link_q[len(s.link_q) - 1].buf[:], dg)
		}
		return
	}
	send_now(s, dg)
}

// link_flush sends whatever the emulated link has finished carrying.
link_flush :: proc(s: ^Session) {
	if len(s.link_q) == 0 {
		return
	}
	i := 0
	for i < len(s.link_q) && s.link_q[i].at <= s.t {
		send_now(s, s.link_q[i].buf[:s.link_q[i].n])
		i += 1
	}
	if i > 0 {
		remove_range(&s.link_q, 0, i)
	}
}

@(private = "file")
send_now :: proc(s: ^Session, dg: []u8) {
	n, err := net.send_udp(s.sock, dg, s.peer)
	if err != nil {
		return
	}
	s.tx_packets += 1
	s.tx_bytes += n
}

// send_media fragments a payload and sends every piece. One sequence counter
// per stream, so audio loss and video loss are independently measurable.
// `extra_flags` is header flags that belong to the frame rather than to the
// fragment — today that is FLAG_KEYFRAME, which goes on every fragment of the
// frame so that losing the first one does not lose the fact.
send_media :: proc(
	s: ^Session,
	ptype: Payload_Type,
	data: []u8,
	ts_us: u64,
	extra_flags: u8 = 0,
	layer: u8 = 0,
	level: u8 = 127,
) {
	if s.room != nil {
		room_send_media(s.room, ptype, data, ts_us, extra_flags, layer, level)
		return
	}
	if s.e2ee.required && !e2ee_ready(&s.e2ee) {
		// No key for the peer yet: the frame is held back, never sent in
		// the clear. In practice this is the first frame or two of a call.
		s.e2ee.tx_no_key += 1
		return
	}
	frame: u32
	switch ptype {
	case .Audio_Opus, .Audio_PCM:
		s.frame_audio += 1
		frame = s.frame_audio
	case .Video_JPEG, .Video_H264:
		s.frame_video += 1
		frame = s.frame_video
	case .Control:
		return
	}
	data := data
	extra_flags := extra_flags
	if e2ee_ready(&s.e2ee) {
		// The whole frame is sealed before it is cut up, as SFrame says:
		// the reassembled frame is what authenticates.
		data = e2ee_seal(&s.e2ee, ptype, extra_flags & FLAG_KEYFRAME != 0, ts_us, frame, data)
		extra_flags |= FLAG_E2EE
	}
	nf := fragment_count(len(data))
	for i in 0 ..< nf {
		seq: u16
		if is_video(ptype) {
			seq = s.seq_video
			s.seq_video += 1
		} else {
			seq = s.seq_audio
			s.seq_audio += 1
		}
		dg := fragment_into(s.txbuf[:], data, i, ptype, seq, ts_us, frame, extra_flags)
		if s.drop_permille > 0 && is_video(ptype) && (s.drop_until <= 0 || s.t < s.drop_until) && draw_permille(s) < s.drop_permille {
			// Dropped on purpose, and counted. The sequence number and the
			// frame id are already spent, which is exactly what a real loss
			// looks like to the far end.
			s.tx_dropped += 1
			continue
		}
		send_datagram(s, dg)
	}
}

send_control :: proc(s: ^Session, kind: Control_Kind, muted, cam_off: bool, fb: ^Feedback = nil) {
	body: [CONTROL_MAX]u8
	flags: u8
	if muted {
		flags |= CTRL_MUTED
	}
	if cam_off {
		flags |= CTRL_CAM_OFF
	}
	c := Control{kind = kind, flags = flags, name = s.name, codecs = s.codecs}
	// Our public key rides every message that can open or carry a call.
	if s.e2ee.required {
		switch kind {
		case .Hello, .Invite, .Ringing, .Accept, .State:
			c.has_pub = true
			c.pub = s.e2ee.kp.public
		case .Decline, .Bye, .Keyframe, .Feedback:
		}
	}
	if fb != nil {
		c.has_fb = true
		c.fb = fb^
	}
	payload := write_control(body[:], c)
	if payload == nil {
		return
	}
	h := Header {
		ptype = .Control,
		flags = FLAG_MARKER,
		seq   = s.seq_ctrl,
		ts_us = now_us(),
		frame = 0,
		frag  = 0,
		nfrag = 1,
	}
	s.seq_ctrl += 1
	write_header(s.txbuf[:], h)
	copy(s.txbuf[HDR:], payload)
	send_datagram(s, s.txbuf[:HDR + len(payload)])
}

// ---------------------------------------------------------------------------
// The state machine
// ---------------------------------------------------------------------------

set_state :: proc(s: ^Session, st: Call_State, reason := "") {
	if s.state == st {
		return
	}
	s.state = st
	s.state_at = s.t
	s.reason = reason
	if st == .Connected && s.connected_at == 0 {
		s.connected_at = s.t
	}
	if st == .Idle || st == .Ended {
		s.connected_at = 0
		// The call is over: its keys go with it, and the next call gets a
		// keypair of its own.
		if s.e2ee.required {
			e2ee_new_call(&s.e2ee)
		}
		// So does the rate: each call starts at the ceiling again.
		if s.adapt {
			rate_init(&s.rate, s.rate.max_kbps)
		}
		s.rx_seq_audio, s.rx_seq_video = {}, {}
		s.fb_peer_ts, s.fb_peer_at = 0, 0
	}
}

call_active :: proc(s: ^Session) -> bool {
	return s.state == .Connecting || s.state == .Connected
}

call_duration :: proc(s: ^Session) -> f64 {
	if s.connected_at == 0 {
		return 0
	}
	return s.t - s.connected_at
}

dial :: proc(s: ^Session, muted, cam_off: bool) {
	if s.state != .Idle && s.state != .Ended {
		return
	}
	set_state(s, .Dialing)
	s.last_invite = 0
	send_control(s, .Invite, muted, cam_off)
}

accept_call :: proc(s: ^Session, muted, cam_off: bool) {
	if s.state != .Ringing {
		return
	}
	send_control(s, .Accept, muted, cam_off)
	set_state(s, .Connecting)
	s.last_peer_rx = s.t
}

decline_call :: proc(s: ^Session) {
	if s.state != .Ringing {
		return
	}
	send_control(s, .Decline, false, false)
	set_state(s, .Ended, "Declined")
}

hang_up :: proc(s: ^Session) {
	switch s.state {
	case .Dialing:
		send_control(s, .Bye, false, false)
		set_state(s, .Ended, "Cancelled")
	case .Ringing:
		decline_call(s)
	case .Connecting, .Connected:
		// Three copies: this is the one message whose loss leaves the other
		// end staring at a frozen picture for PEER_TIMEOUT seconds.
		for _ in 0 ..< 3 {
			send_control(s, .Bye, false, false)
		}
		set_state(s, .Ended, "You hung up")
	case .Idle, .Ended:
	}
}

reset_call :: proc(s: ^Session) {
	set_state(s, .Idle)
	s.reason = ""
	s.peer_muted = false
	s.peer_cam_off = false
}

// session_tick runs the timers. Called once per frame.
session_tick :: proc(s: ^Session, t: f64, muted, cam_off: bool) {
	s.t = t
	link_flush(s)

	if s.rate_at == 0 {
		s.rate_at = t
		s.rate_tx0 = s.tx_bytes
		s.rate_rx0 = s.rx_bytes
	} else if t - s.rate_at >= 1.0 {
		dt := f32(t - s.rate_at)
		s.tx_kbps = f32(s.tx_bytes - s.rate_tx0) * 8 / 1000 / dt
		s.rx_kbps = f32(s.rx_bytes - s.rate_rx0) * 8 / 1000 / dt
		s.rate_at = t
		s.rate_tx0 = s.tx_bytes
		s.rate_rx0 = s.rx_bytes
	}

	switch s.state {
	case .Dialing:
		if t - s.last_invite >= INVITE_REPEAT {
			s.last_invite = t
			send_control(s, .Invite, muted, cam_off)
		}
		if t - s.state_at > DIAL_TIMEOUT {
			set_state(s, .Ended, "No answer")
		}
	case .Ringing:
		if t - s.state_at > RING_TIMEOUT {
			set_state(s, .Ended, "Missed call")
		}
	case .Connecting, .Connected:
		if t - s.last_state_tx >= STATE_REPEAT {
			s.last_state_tx = t
			send_control(s, .State, muted, cam_off)
		}
		if t - s.last_fb_tx >= RATE_FEEDBACK_EVERY {
			send_feedback(s, t)
		}
		if t - s.last_peer_rx > PEER_TIMEOUT {
			set_state(s, .Ended, "Peer stopped responding")
		}
	case .Idle, .Ended:
	}
}

// ---------------------------------------------------------------------------
// Receiving
//
// handle_control folds a signalling message into the state machine; the media
// branches are driven by the audio and video engines, which is why receive
// lives in app.odin rather than here.
// ---------------------------------------------------------------------------

// send_feedback is the receiver report: what we got of the peer's stream in
// the window just ended, and the echo that lets the peer time a round trip.
send_feedback :: proc(s: ^Session, t: f64) {
	dt := s.last_fb_tx > 0 ? t - s.last_fb_tx : RATE_FEEDBACK_EVERY
	s.last_fb_tx = t
	ea, ra := seq_count_window(&s.rx_seq_audio)
	ev, rv := seq_count_window(&s.rx_seq_video)
	// The worse of the two streams: the controller adapts video, and a
	// video loss figure diluted by fifty clean audio packets a second would
	// hide exactly the loss it needs to see.
	la := ea > 0 ? max(0, 1 - f64(ra) / f64(ea)) : 0
	lv := ev > 0 ? max(0, 1 - f64(rv) / f64(ev)) : 0
	s.rx_loss = max(la, lv)
	fb := Feedback {
		loss_permille = u16(clamp(s.rx_loss * 1000, 0, 1000)),
		recv_kbps     = u16(clamp(f64(s.rx_media_w) * 8 / 1000 / max(dt, 0.1), 0, 65535)),
	}
	s.rx_media_w = 0
	if s.fb_peer_ts != 0 {
		fb.echo_ts = s.fb_peer_ts
		fb.hold_us = u32(min(now_us() - s.fb_peer_at, u64(max(u32))))
	}
	send_control(s, .Feedback, false, false, &fb)
}

// session_on_feedback folds a peer's report into the controller. Returns the
// encoder rate to apply now, if there is one.
session_on_feedback :: proc(s: ^Session, c: Control, sent_ts: u64) -> (kbps: int, apply: bool) {
	if !c.has_fb {
		return 0, false
	}
	now := now_us()
	s.fb_rx += 1
	s.fb_peer_ts = sent_ts
	s.fb_peer_at = now
	if c.fb.echo_ts != 0 && now > c.fb.echo_ts + u64(c.fb.hold_us) {
		s.rtt_ms = f64(now - c.fb.echo_ts - u64(c.fb.hold_us)) / 1000
		rate_on_rtt(&s.rate, s.rtt_ms)
	}
	s.peer_loss = f64(c.fb.loss_permille) / 1000
	s.peer_kbps = f64(c.fb.recv_kbps)
	if !s.adapt {
		return 0, false
	}
	before := s.rate.kbps
	reason := rate_on_feedback(&s.rate, s.t, s.peer_loss, s.peer_kbps)
	kbps, apply = rate_should_apply(&s.rate, s.t)
	if s.rate.kbps != before || apply {
		append(&s.rate_log, Rate_Event{t = s.t, kbps = s.rate.kbps, reason = reason, loss = s.peer_loss, rtt_ms = s.rtt_ms, applied = apply})
	}
	return
}

handle_control :: proc(s: ^Session, c: Control, muted, cam_off: bool) {
	if c.name != "" && c.kind != .Bye {
		if s.peer_name != c.name {
			delete(s.peer_name)
			s.peer_name = clone_string(c.name)
		}
	}
	if c.kind == .State || c.kind == .Invite || c.kind == .Accept {
		s.peer_muted = c.flags & CTRL_MUTED != 0
		s.peer_cam_off = c.flags & CTRL_CAM_OFF != 0
	}
	// Every signalling message carries the offer, so by the time the state
	// machine reaches `Connecting` — which cannot happen without an INVITE or
	// an ACCEPT — both ends have each other's and the choice is already made.
	// A keyframe request is deliberately excluded: it is sent in a hurry, and
	// a peer's codec set is not what it is about.
	switch c.kind {
	case .Hello, .Invite, .Ringing, .Accept, .State:
		s.peer_codecs = c.codecs
	case .Decline, .Bye, .Keyframe, .Feedback:
	}

	switch c.kind {
	case .Invite:
		switch s.state {
		case .Idle, .Ended:
			set_state(s, .Ringing)
			send_control(s, .Ringing, muted, cam_off)
		case .Dialing:
			// Both ends dialled at once. The lower port concedes and answers,
			// which resolves glare without another round trip.
			if s.bind_port < s.peer.port {
				send_control(s, .Accept, muted, cam_off)
				set_state(s, .Connecting)
				s.last_peer_rx = s.t
			}
		case .Ringing:
			send_control(s, .Ringing, muted, cam_off) // retransmitted invite
		case .Connecting, .Connected:
			send_control(s, .Accept, muted, cam_off) // our accept was lost
		}
	case .Ringing:
		// Informational: the peer's phone is ringing. Keeps `Dialing` from
		// timing out on a slow user without inventing a separate state.
		if s.state == .Dialing {
			s.reason = "Ringing"
		}
	case .Accept:
		if s.state == .Dialing || s.state == .Connecting {
			set_state(s, .Connecting)
			s.last_peer_rx = s.t
		}
	case .Decline:
		if s.state == .Dialing {
			set_state(s, .Ended, "Declined")
		}
	case .Bye:
		if s.state != .Idle {
			set_state(s, .Ended, "Peer hung up")
		}
	case .Feedback:
		// A receiver report; the bitrate controller's, not the state
		// machine's (`app_on_feedback`).
	case .Keyframe:
		// A PLI equivalent. It says nothing about the call's state and must
		// not be mistaken for a keepalive from a peer we are not talking to;
		// `pump_receive` hands it to the video engine.
	case .Hello, .State:
		switch s.state {
		case .Connecting:
			// Media or a keepalive from the peer: the call is really up.
			set_state(s, .Connected)
		case .Idle, .Ended:
			// The peer believes it is in a call we do not have — we restarted,
			// or our BYE was lost. Say so now rather than let it stare at a
			// frozen picture until its own 5 s timeout.
			if c.kind == .State {
				send_control(s, .Bye, false, false)
			}
		case .Dialing, .Ringing, .Connected:
		}
	}

	// The peer's key, taken only once the message has put us in a call:
	// the key of a call is pinned for its length (e2ee.odin), and a stray
	// from a call that is over must not pin the next one.
	if c.has_pub && s.e2ee.required && s.state != .Idle && s.state != .Ended {
		switch c.kind {
		case .Invite, .Ringing, .Accept, .State:
			e2ee_on_peer_key(&s.e2ee, c.pub)
		case .Hello, .Decline, .Bye, .Keyframe, .Feedback:
		}
	}
}

// draw_permille returns 0..999 from a fixed-seed xorshift, so a run with
// `--loss` drops the same fragments every time.
draw_permille :: proc(s: ^Session) -> int {
	s.drop_state ~= s.drop_state << 13
	s.drop_state ~= s.drop_state >> 7
	s.drop_state ~= s.drop_state << 17
	return int(s.drop_state % 1000)
}

clone_string :: proc(sv: string) -> string {
	b := make([]u8, len(sv))
	copy(b, sv)
	return string(b)
}
