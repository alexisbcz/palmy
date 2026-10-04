package call

// ---------------------------------------------------------------------------
// The jitter buffer.
//
// Audio is the part of a call that cannot be fudged. A packet that arrives
// late is worse than one that never arrives, because the playout clock has
// already moved past it, so the buffer's whole job is to trade a fixed, stated
// amount of delay for the right to reorder.
//
// Shape: a ring of `JB_DEPTH` slots, indexed by sequence number modulo the
// depth, with one explicit playout cursor. One slot is one 20 ms Opus frame.
//
//	JB_DEPTH    = 16 slots = 320 ms of capacity
//	JB_TARGET   =  2 slots =  40 ms before playout starts
//	JB_MAX_HOLD =  3 slots =  60 ms, a hard ceiling
//
// The target is 40 ms because the measured one-way wire delay on this
// transport is 0.2-4.4 ms: ten times the observed jitter is a cushion, and
// anything more is latency bought for nothing. On a link with real jitter this
// is the number to raise, and it is one constant.
//
// The ceiling exists because the whole chain is self-clocked — ffmpeg paces
// capture, pw-play paces playout — and two independent clocks accumulate.
// `jb_trim` discards the oldest frames to get back to the target and counts
// every one, which is the blunt version of the time-scale modification a
// production implementation would do instead.
//
// The counter is the sharpest diagnostic in the program. With the capture
// source paced by `ffmpeg -re`, which runs 5.9 % fast, the buffer sat at the
// ceiling and trimmed twenty frames in a thirty second call — twenty audible
// skips. Paced by the `arealtime` filter, which is within 0.4 %, it sits at
// 20-40 ms and trims nothing. A non-zero trim count means the capture clock
// is wrong, not that the buffer is.
//
// Playout does not begin until `JB_TARGET` frames are queued; after that the
// cursor advances once per pop, whatever arrived. Everything that can happen
// to a packet is counted, and every counter is on screen:
//
//	in order         stored, played in turn
//	reordered        stored at its own index, played in sequence order, so a
//	                 packet that overtakes its predecessor is put back. This
//	                 holds for the opening burst too: see `preroll`.
//	duplicate        the slot is already filled for that sequence: ignored
//	too late         sequence is behind the cursor: discarded and counted,
//	                 because the only alternative is to play it out of order
//	too far ahead    beyond the ring: the buffer resynchronises on the new
//	                 sequence rather than stalling forever
//
// Concealment for a frame that never arrived is Opus' own packet-loss
// concealment: `opus_decode` with a nil payload, which extrapolates the
// previous frame's spectral envelope and fades it. When Opus is unavailable
// and the call falls back to raw PCM, concealment is a 20 ms span of silence
// faded in from the previous sample over 2 ms, so the splice is a fade rather
// than a step — a gap that sounds like a gap and not like a click.
// ---------------------------------------------------------------------------

JB_DEPTH :: 16
JB_TARGET :: 2
JB_MAX_HOLD :: 3
JB_SLOT_BYTES :: 4096 // an Opus frame is ~80 B; a 20 ms PCM frame is 1920 B

Jitter_Slot :: struct {
	seq:   u16,
	ts_us: u64,
	size:  int,
	full:  bool,
	buf:   [JB_SLOT_BYTES]u8,
}

Jitter_Result :: enum {
	Frame,     // a real frame, play it
	Concealed, // the cursor's frame never arrived; conceal and move on
	Starved,   // nothing to play at all; the cursor holds
}

Jitter :: struct {
	slots:   [JB_DEPTH]Jitter_Slot,
	cursor:  u16, // the sequence number to play next
	primed:  bool,
	started: bool,
	// preroll is true from the first packet until the first pop. While it is
	// set the cursor follows the *oldest* sequence held rather than the first
	// one to arrive, because the first packet to arrive need not be the first
	// packet sent — and a buffer that fixed its cursor on arrival order would
	// discard the whole of a reordered opening burst as "late". Once playout
	// starts the cursor only ever moves forward.
	preroll: bool,
	count:   int, // slots currently filled

	// Counters.
	pushed:     int,
	played:     int,
	concealed:  int,
	duplicates: int,
	too_late:   int,
	resyncs:    int,
	starved:    int,
	trimmed:    int,
}

jb_reset :: proc(j: ^Jitter) {
	for i in 0 ..< JB_DEPTH {
		j.slots[i].full = false
	}
	j.count = 0
	j.primed = false
	j.started = false
	j.preroll = false
}

// jb_clear resets the counters as well, which is what starting a new call
// wants.
jb_clear :: proc(j: ^Jitter) {
	j^ = {}
}

// jb_push files a received frame. Returns false when the packet was discarded,
// with the reason recorded in the counters.
jb_push :: proc(j: ^Jitter, seq: u16, ts_us: u64, data: []u8) -> bool {
	if len(data) > JB_SLOT_BYTES {
		return false
	}
	if !j.started {
		j.started = true
		j.preroll = true
		j.cursor = seq
	} else if j.preroll && seq_newer_u16(j.cursor, seq) {
		// An older packet arrived after a newer one, before playout began.
		j.cursor = seq
	}

	ahead := int(i16(seq - j.cursor))
	if ahead < 0 {
		// Behind the playout cursor: the moment for this frame has passed.
		j.too_late += 1
		return false
	}
	if ahead >= JB_DEPTH {
		// A long outage, or the peer restarted its sequence. Keeping the old
		// cursor would conceal hundreds of frames one 20 ms step at a time;
		// resynchronise on what is actually arriving instead.
		for i in 0 ..< JB_DEPTH {
			j.slots[i].full = false
		}
		j.count = 0
		j.primed = false
		j.preroll = false
		j.cursor = seq
		j.resyncs += 1
		ahead = 0
	}

	s := &j.slots[int(seq) % JB_DEPTH]
	if s.full && s.seq == seq {
		j.duplicates += 1
		return false
	}
	s.seq = seq
	s.ts_us = ts_us
	s.size = len(data)
	copy(s.buf[:len(data)], data)
	if !s.full {
		j.count += 1
	}
	s.full = true
	j.pushed += 1
	if j.count >= JB_TARGET {
		j.primed = true
	}
	return true
}

// jb_pop takes the next frame for playout. `out` receives the payload when the
// result is .Frame.
jb_pop :: proc(j: ^Jitter, out: []u8) -> (n: int, ts_us: u64, res: Jitter_Result) {
	if !j.started || !j.primed {
		if j.started {
			j.starved += 1
		}
		return 0, 0, .Starved
	}

	s := &j.slots[int(j.cursor) % JB_DEPTH]
	if s.full && s.seq == j.cursor {
		n = min(s.size, len(out))
		copy(out[:n], s.buf[:n])
		ts_us = s.ts_us
		s.full = false
		j.count -= 1
		j.cursor += 1
		j.played += 1
		j.preroll = false
		if j.count == 0 {
			// Drained. Re-prime before playing again rather than ride the
			// edge of the buffer, which is where a stutter per packet comes
			// from.
			j.primed = false
		}
		return n, ts_us, .Frame
	}

	// The cursor's frame is missing. Only conceal it if something later has
	// arrived — otherwise we are merely early and should wait.
	if j.count == 0 {
		j.primed = false
		j.starved += 1
		return 0, 0, .Starved
	}
	j.cursor += 1
	j.concealed += 1
	return 0, 0, .Concealed
}

// jb_trim enforces the ceiling: when the buffer has crept above JB_MAX_HOLD,
// the oldest frames are discarded until it is back at the target. Called
// immediately before popping.
//
// Dropping the *oldest* is the point. Dropping the newest would keep the
// stale audio and throw away what the far end just said.
jb_trim :: proc(j: ^Jitter) {
	for j.count > JB_MAX_HOLD {
		s := &j.slots[int(j.cursor) % JB_DEPTH]
		if s.full && s.seq == j.cursor {
			s.full = false
			j.count -= 1
			j.trimmed += 1
		}
		j.cursor += 1
		if j.count == 0 {
			break
		}
	}
}

// jb_depth_ms is the buffering delay currently held, for the UI.
jb_depth_ms :: proc(j: ^Jitter, frame_ms: f32) -> f32 {
	return f32(j.count) * frame_ms
}

// jb_loss_percent is concealed frames as a share of everything the cursor has
// passed over.
jb_loss_percent :: proc(j: ^Jitter) -> f32 {
	total := j.played + j.concealed
	if total == 0 {
		return 0
	}
	return 100 * f32(j.concealed) / f32(total)
}
