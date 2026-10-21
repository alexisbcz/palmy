package call

// ---------------------------------------------------------------------------
// PCP1 — the wire format.
//
// An RTP-shaped datagram header, cut down to the fields this application
// actually reads and widened where RTP's choices hurt. See PROTOCOL.md for the
// normative description; this file is the implementation.
//
//	 0                   1                   2                   3
//	 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|                      magic  "P" "C" "P" "1"                   |
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|   payload type |     flags     |         sequence (u16)        |
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|                 capture timestamp, microseconds                |
//	|                            (u64, hi then lo)                   |
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|                        frame id (u32)                          |
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|     fragment index (u16)      |     fragment count (u16)       |
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	|                           payload ...                          |
//
// Everything is big-endian, because that is what every other packet on a wire
// is and a hex dump should read the same way as the diagram.
// ---------------------------------------------------------------------------

HDR :: 24

// MTU_PAYLOAD keeps a datagram under the 1500-byte Ethernet MTU even though
// this only ever runs over loopback: a format that would need re-tuning to
// leave the machine is not a transport design, it is a demo.
MTU_PAYLOAD :: 1200
MAX_PACKET :: HDR + MTU_PAYLOAD

MAGIC :: [4]u8{'P', 'C', 'P', '1'}

Payload_Type :: enum u8 {
	Control    = 0,
	Audio_Opus = 1,
	Audio_PCM  = 2,
	Video_JPEG = 3,
	Video_H264 = 4,
}

is_video :: proc(t: Payload_Type) -> bool {
	return t == .Video_JPEG || t == .Video_H264
}

// FLAG_MARKER is RTP's marker bit: set on the last fragment of a frame, so a
// receiver knows a frame is complete without waiting for the next one.
FLAG_MARKER :: u8(0x01)

// FLAG_KEYFRAME says this frame can be decoded with no reference to any
// earlier frame. It is set on *every* fragment of the frame rather than only
// the first, so a receiver that lost the first fragment still knows what it
// lost.
//
// It is in the generic header rather than in a codec-specific descriptor
// because it is the one thing a codec-agnostic receiver genuinely needs to
// know: whether it may resume decoding after a gap. MJPEG sets it on every
// frame, which is the literal truth about MJPEG and is why the loss logic
// below needs no special case for it.
FLAG_KEYFRAME :: u8(0x02)

// FLAG_E2EE says the reassembled frame is an SFrame ciphertext (RFC 9605),
// not media: see `e2ee.odin`. The same bit PCP2 uses. A call whose two ends
// have exchanged keys sends nothing without it and accepts nothing without it.
FLAG_E2EE :: u8(0x04)

Header :: struct {
	ptype: Payload_Type,
	flags: u8,
	seq:   u16,
	ts_us: u64,
	frame: u32,
	frag:  u16,
	nfrag: u16,
}

marked :: proc(h: Header) -> bool {
	return h.flags & FLAG_MARKER != 0
}

keyframed :: proc(h: Header) -> bool {
	return h.flags & FLAG_KEYFRAME != 0
}

// ---------------------------------------------------------------------------
// Video codecs, and how two instances agree on one.
//
// The offer is a bitmask, not a list, because there are two codecs and a
// bitmask intersects in one instruction. MJPEG is bit 0 and is
// mandatory-to-implement: every instance decodes it, so the intersection is
// never empty and negotiation can never fail into "no video".
//
// Both ends run the same `negotiate_video` over the same two bitmasks and
// therefore reach the same answer with no extra round trip and no answer
// message. That is the whole protocol: an offer that rides every control
// message, and a pure function.
// ---------------------------------------------------------------------------

Video_Codec :: enum u8 {
	MJPEG = 0,
	H264  = 1,
}

CODEC_MJPEG :: u8(0x01)
CODEC_H264 :: u8(0x02)
CODEC_ALL :: CODEC_MJPEG | CODEC_H264

video_codec_name :: proc(c: Video_Codec) -> string {
	switch c {
	case .MJPEG:
		return "MJPEG"
	case .H264:
		return "H.264"
	}
	return "?"
}

video_codec_payload :: proc(c: Video_Codec) -> Payload_Type {
	return c == .H264 ? .Video_H264 : .Video_JPEG
}

// negotiate_video picks the best codec both ends offer. Preference order is
// H.264 then MJPEG; an empty intersection falls back to MJPEG, which every
// implementation is required to carry, so a peer that offers nothing
// recognisable still gets a picture rather than a black rectangle.
negotiate_video :: proc(mine, theirs: u8) -> Video_Codec {
	both := mine & theirs
	if both & CODEC_H264 != 0 {
		return .H264
	}
	return .MJPEG
}

// ---------------------------------------------------------------------------
// Big-endian scalars
// ---------------------------------------------------------------------------

put_u16 :: proc(b: []u8, v: u16) {
	b[0] = u8(v >> 8)
	b[1] = u8(v)
}

put_u32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v >> 24)
	b[1] = u8(v >> 16)
	b[2] = u8(v >> 8)
	b[3] = u8(v)
}

put_u64 :: proc(b: []u8, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> uint(56 - 8 * i))
	}
}

get_u16 :: proc(b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

get_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

get_u64 :: proc(b: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(b[i])
	}
	return v
}

// ---------------------------------------------------------------------------
// Encode / decode
// ---------------------------------------------------------------------------

// write_header lays a header into the first HDR bytes of `b`.
write_header :: proc(b: []u8, h: Header) -> bool {
	if len(b) < HDR {
		return false
	}
	m := MAGIC
	copy(b[0:4], m[:])
	b[4] = u8(h.ptype)
	b[5] = h.flags
	put_u16(b[6:8], h.seq)
	put_u64(b[8:16], h.ts_us)
	put_u32(b[16:20], h.frame)
	put_u16(b[20:22], h.frag)
	put_u16(b[22:24], h.nfrag)
	return true
}

// parse reads a datagram. A packet whose magic, type or fragment counters do
// not hold together is rejected rather than papered over: on a real network
// this port will receive scans and strays.
parse :: proc(b: []u8) -> (h: Header, payload: []u8, ok: bool) {
	if len(b) < HDR {
		return {}, nil, false
	}
	if b[0] != 'P' || b[1] != 'C' || b[2] != 'P' || b[3] != '1' {
		return {}, nil, false
	}
	if b[4] > u8(Payload_Type.Video_H264) {
		return {}, nil, false
	}
	h.ptype = Payload_Type(b[4])
	h.flags = b[5]
	h.seq = get_u16(b[6:8])
	h.ts_us = get_u64(b[8:16])
	h.frame = get_u32(b[16:20])
	h.frag = get_u16(b[20:22])
	h.nfrag = get_u16(b[22:24])
	if h.nfrag == 0 || h.frag >= h.nfrag {
		return {}, nil, false
	}
	// The marker bit must agree with the fragment counters.
	if marked(h) != (h.frag == h.nfrag - 1) {
		return {}, nil, false
	}
	return h, b[HDR:], true
}

// ---------------------------------------------------------------------------
// Fragmentation
//
// An audio frame is one datagram; a JPEG is ten to forty. `fragment_count`
// and `fragment_into` are the whole of the sender side.
// ---------------------------------------------------------------------------

fragment_count :: proc(n: int) -> int {
	if n <= 0 {
		return 1 // an empty payload still occupies one packet
	}
	return (n + MTU_PAYLOAD - 1) / MTU_PAYLOAD
}

// fragment_into writes fragment `i` of `data` into `out` and returns the slice
// of `out` that is the datagram.
fragment_into :: proc(
	out: []u8,
	data: []u8,
	i: int,
	ptype: Payload_Type,
	seq: u16,
	ts_us: u64,
	frame: u32,
	extra_flags: u8 = 0,
) -> []u8 {
	n := fragment_count(len(data))
	lo := i * MTU_PAYLOAD
	hi := min(lo + MTU_PAYLOAD, len(data))
	if lo > len(data) {
		lo = len(data)
	}
	h := Header {
		ptype = ptype,
		flags = extra_flags &~ FLAG_MARKER,
		seq   = seq,
		ts_us = ts_us,
		frame = frame,
		frag  = u16(i),
		nfrag = u16(n),
	}
	if i == n - 1 {
		h.flags |= FLAG_MARKER
	}
	write_header(out, h)
	copy(out[HDR:], data[lo:hi])
	return out[:HDR + (hi - lo)]
}

// ---------------------------------------------------------------------------
// Reassembly
//
// A ring of partial frames. Video frames arrive interleaved with audio and
// occasionally out of order, and a lost fragment must not strand the slot
// forever — so slots are reclaimed by frame-id distance, not by a timer.
// ---------------------------------------------------------------------------

REASM_SLOTS :: 4
REASM_MAX_FRAGS :: 64 // 64 * 1200 = 76.8 KB, far above a 480p JPEG
REASM_CAP :: REASM_MAX_FRAGS * MTU_PAYLOAD

Reasm_Slot :: struct {
	frame:    u32,
	active:   bool,
	nfrag:    u16,
	have:     u64, // bitmap, one bit per fragment
	got:      int,
	ts_us:    u64,
	size:     int,
	buf:      []u8,
}

Reassembler :: struct {
	slots:     [REASM_SLOTS]Reasm_Slot,
	next_free: int,

	// Counters, reported in the UI so a degraded link is visible rather than
	// merely felt.
	completed: int,
	dropped:   int, // slots evicted before every fragment arrived
	late:      int, // fragments for a frame already completed or evicted
	last_done: u32,
	have_done: bool,
}

reasm_init :: proc(r: ^Reassembler) {
	for i in 0 ..< REASM_SLOTS {
		r.slots[i].buf = make([]u8, REASM_CAP)
	}
}

// REASM_RESTART is how far behind a frame id has to be before it is read as a
// restart rather than a straggler. At 30 fps, 600 frames is twenty seconds —
// far longer than any reordering and far shorter than a wrap.
REASM_RESTART :: 600

// reasm_reset drops every partial frame and forgets what was delivered, which
// is what starting a new call needs.
reasm_reset :: proc(r: ^Reassembler) {
	for i in 0 ..< REASM_SLOTS {
		r.slots[i].active = false
	}
	r.have_done = false
	r.last_done = 0
	r.next_free = 0
}

reasm_destroy :: proc(r: ^Reassembler) {
	for i in 0 ..< REASM_SLOTS {
		delete(r.slots[i].buf)
		r.slots[i].buf = nil
	}
}

// seq_newer compares two wrapping counters the way RTP does: the difference
// taken in signed 32-bit space, so 0 is newer than 0xffffffff.
seq_newer_u32 :: proc(a, b: u32) -> bool {
	return i32(a - b) > 0
}

seq_newer_u16 :: proc(a, b: u16) -> bool {
	return i16(a - b) > 0
}

// reasm_push feeds a fragment in. When the frame completes it returns the
// assembled bytes, which alias the slot's buffer and stay valid until the slot
// is reused — the caller decodes immediately.
reasm_push :: proc(r: ^Reassembler, h: Header, payload: []u8) -> (frame: []u8, ts_us: u64, ok: bool) {
	if h.nfrag > REASM_MAX_FRAGS || h.frag >= h.nfrag {
		r.late += 1
		return nil, 0, false
	}
	if r.have_done && !seq_newer_u32(h.frame, r.last_done) {
		// Either a straggler for a frame already delivered, or the peer
		// restarted and its frame ids went back to 1. Without the second case
		// a reconnected peer's video would be discarded as "late" for the rest
		// of the session.
		if int(r.last_done - h.frame) > REASM_RESTART {
			reasm_reset(r)
		} else {
			r.late += 1
			return nil, 0, false
		}
	}

	slot := -1
	for i in 0 ..< REASM_SLOTS {
		if r.slots[i].active && r.slots[i].frame == h.frame {
			slot = i
			break
		}
	}
	if slot < 0 {
		// Take a free slot, else evict the oldest frame id.
		for i in 0 ..< REASM_SLOTS {
			if !r.slots[i].active {
				slot = i
				break
			}
		}
		if slot < 0 {
			oldest := 0
			for i in 1 ..< REASM_SLOTS {
				if seq_newer_u32(r.slots[oldest].frame, r.slots[i].frame) {
					oldest = i
				}
			}
			r.dropped += 1
			slot = oldest
		}
		s := &r.slots[slot]
		s.frame = h.frame
		s.active = true
		s.nfrag = h.nfrag
		s.have = 0
		s.got = 0
		s.ts_us = h.ts_us
		s.size = 0
	}

	s := &r.slots[slot]
	if s.nfrag != h.nfrag {
		// Two senders, or a corrupted header. Restart the slot.
		s.nfrag = h.nfrag
		s.have = 0
		s.got = 0
		s.size = 0
	}
	bit := u64(1) << uint(h.frag)
	if s.have & bit != 0 {
		return nil, 0, false // duplicate, silently absorbed
	}
	off := int(h.frag) * MTU_PAYLOAD
	n := min(len(payload), MTU_PAYLOAD)
	if off + n > len(s.buf) {
		return nil, 0, false
	}
	copy(s.buf[off:off + n], payload[:n])
	s.have |= bit
	s.got += 1
	// The last fragment is the only one allowed to be short, so it fixes the
	// total size; every earlier one is a full MTU payload.
	if h.frag == h.nfrag - 1 {
		s.size = off + n
	}
	if s.got == int(s.nfrag) && s.size > 0 {
		s.active = false
		r.completed += 1
		r.last_done = s.frame
		r.have_done = true
		return s.buf[:s.size], s.ts_us, true
	}
	return nil, 0, false
}

// ---------------------------------------------------------------------------
// Control messages
//
// Signalling rides the same socket as media, on payload type 0, because a
// second port for a second protocol buys nothing on a design this small.
// ---------------------------------------------------------------------------

Control_Kind :: enum u8 {
	Hello    = 0,
	Invite   = 1,
	Ringing  = 2,
	Accept   = 3,
	Decline  = 4,
	Bye      = 5,
	State    = 6,
	Keyframe = 7,
	// A receiver report: loss and received rate over the last 500 ms, and
	// an RTT echo. What the sender's bitrate controller runs on (rate.odin).
	Feedback = 8,
}

CTRL_MUTED :: u8(0x01)
CTRL_CAM_OFF :: u8(0x02)

Control :: struct {
	kind:   Control_Kind,
	flags:  u8,
	name:   string, // the peer's display name; borrows the receive buffer
	codecs: u8, // video codecs this peer can decode, as a CODEC_* bitmask

	// Extensions, each optional (see write_control).
	has_pub: bool,
	pub:     [32]u8, // the sender's X25519 public key for this call
	has_fb:  bool,
	fb:      Feedback,
}

// Feedback is the body of a FEEDBACK message.
Feedback :: struct {
	loss_permille: u16, // of the packets expected in the window, both streams
	recv_kbps:     u16, // video that arrived in the window, headers included
	// The RTT echo, as RTCP's LSR/DLSR: the capture timestamp of the last
	// FEEDBACK received from the peer, and how long it was held before this
	// one was sent. The peer subtracts both from its clock and has the round
	// trip without either end trusting the other's clock.
	echo_ts: u64,
	hold_us: u32,
	// The queueing delay this receiver sees on the sender's direction, ms:
	// its one-way delay over the window's minimum against the smallest seen.
	// Two more bytes; a 16-byte report (no queue) is still read.
	has_queue: bool,
	queue_ms:  u16,
}

EXT_PUB :: u8(1) // 32 bytes
EXT_FEEDBACK :: u8(2) // 16 bytes
FEEDBACK_BYTES :: 18
CONTROL_MAX :: 5 + 64 + 2 + 32 + 2 + FEEDBACK_BYTES

// write_control serialises into `out` and returns the used prefix.
//   0      kind
//   1      flags
//   2..3   name length
//   4..    name, UTF-8
//   4+n    video codec offer, a CODEC_* bitmask    <- optional extension
//
// The codec offer is appended *after* the variable-length name rather than
// given a fixed slot, so a receiver that has never heard of it reads the same
// message it always did and simply ignores a byte it did not consume. That is
// what makes it safe to add: `read_control` below validates only that the name
// fits, so the old parser accepts the new message, and the new parser reads a
// missing offer as "MJPEG only" — which is the correct reading of silence,
// because MJPEG is the one codec every version has carried.
//
// After the offer come extensions, each `type(1) length(1) value`, in any
// order; a reader skips a type it does not know by its length, so the same
// rule — append, never move — keeps holding:
//   type 1   32 bytes   X25519 public key (end-to-end encryption, e2ee.odin)
//   type 2   18 bytes   receiver report: loss u16, kbps u16, echo ts u64,
//                       hold u32, queue ms u16 (adaptive bitrate, rate.odin)
write_control :: proc(out: []u8, c: Control) -> []u8 {
	n := min(len(c.name), 64)
	need := 5 + n
	if c.has_pub {
		need += 2 + 32
	}
	if c.has_fb {
		need += 2 + FEEDBACK_BYTES
	}
	if len(out) < need {
		return nil
	}
	out[0] = u8(c.kind)
	out[1] = c.flags
	put_u16(out[2:4], u16(n))
	copy(out[4:4 + n], c.name[:n])
	out[4 + n] = c.codecs
	at := 5 + n
	if c.has_pub {
		out[at] = EXT_PUB
		out[at + 1] = 32
		pub := c.pub
		copy(out[at + 2:at + 34], pub[:])
		at += 34
	}
	if c.has_fb {
		out[at] = EXT_FEEDBACK
		out[at + 1] = FEEDBACK_BYTES
		b := out[at + 2:at + 2 + FEEDBACK_BYTES]
		put_u16(b[0:2], c.fb.loss_permille)
		put_u16(b[2:4], c.fb.recv_kbps)
		put_u64(b[4:12], c.fb.echo_ts)
		put_u32(b[12:16], c.fb.hold_us)
		put_u16(b[16:18], c.fb.queue_ms)
		at += 2 + FEEDBACK_BYTES
	}
	return out[:at]
}

read_control :: proc(b: []u8) -> (c: Control, ok: bool) {
	if len(b) < 4 {
		return {}, false
	}
	if b[0] > u8(Control_Kind.Feedback) {
		return {}, false
	}
	c.kind = Control_Kind(b[0])
	c.flags = b[1]
	n := int(get_u16(b[2:4]))
	if 4 + n > len(b) {
		return {}, false
	}
	c.name = string(b[4:4 + n])
	// A peer that sends no offer is a peer that only speaks MJPEG.
	c.codecs = CODEC_MJPEG
	if 4 + n < len(b) {
		c.codecs = b[4 + n]
	}
	at := 5 + n
	for at + 2 <= len(b) {
		t, l := b[at], int(b[at + 1])
		if at + 2 + l > len(b) {
			return {}, false // an extension that runs off the end is a lie
		}
		v := b[at + 2:at + 2 + l]
		switch t {
		case EXT_PUB:
			if l != 32 {
				return {}, false
			}
			copy(c.pub[:], v)
			c.has_pub = true
		case EXT_FEEDBACK:
			if l != 16 && l != FEEDBACK_BYTES {
				return {}, false
			}
			c.fb.loss_permille = get_u16(v[0:2])
			c.fb.recv_kbps = get_u16(v[2:4])
			c.fb.echo_ts = get_u64(v[4:12])
			c.fb.hold_us = get_u32(v[12:16])
			if l >= 18 {
				c.fb.queue_ms = get_u16(v[16:18])
				c.fb.has_queue = true
			}
			c.has_fb = true
		}
		at += 2 + l
	}
	return c, true
}
