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

	seq_audio: u16,
	seq_video: u16,
	seq_ctrl:  u16,
	frame_audio: u32,
	frame_video: u32,

	txbuf: [MAX_PACKET]u8,
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
	s.state = .Idle
	return ""
}

session_close :: proc(s: ^Session) {
	if s.open {
		net.close(s.sock)
		s.open = false
	}
	delete(s.peer_name)
	s.peer_name = ""
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

send_datagram :: proc(s: ^Session, dg: []u8) {
	if !s.open || len(dg) == 0 {
		return
	}
	n, err := net.send_udp(s.sock, dg, s.peer)
	if err != nil {
		return
	}
	s.tx_packets += 1
	s.tx_bytes += n
}

// send_media fragments a payload and sends every piece. One sequence counter
// per stream, so audio loss and video loss are independently measurable.
send_media :: proc(s: ^Session, ptype: Payload_Type, data: []u8, ts_us: u64) {
	nf := fragment_count(len(data))
	frame: u32
	switch ptype {
	case .Audio_Opus, .Audio_PCM:
		s.frame_audio += 1
		frame = s.frame_audio
	case .Video_JPEG:
		s.frame_video += 1
		frame = s.frame_video
	case .Control:
		return
	}
	for i in 0 ..< nf {
		seq: u16
		if ptype == .Video_JPEG {
			seq = s.seq_video
			s.seq_video += 1
		} else {
			seq = s.seq_audio
			s.seq_audio += 1
		}
		dg := fragment_into(s.txbuf[:], data, i, ptype, seq, ts_us, frame)
		send_datagram(s, dg)
	}
}

send_control :: proc(s: ^Session, kind: Control_Kind, muted, cam_off: bool) {
	body: [96]u8
	flags: u8
	if muted {
		flags |= CTRL_MUTED
	}
	if cam_off {
		flags |= CTRL_CAM_OFF
	}
	payload := write_control(body[:], {kind = kind, flags = flags, name = s.name})
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
}

clone_string :: proc(sv: string) -> string {
	b := make([]u8, len(sv))
	copy(b, sv)
	return string(b)
}
