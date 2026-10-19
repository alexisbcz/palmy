package call

// ---------------------------------------------------------------------------
// The audio path.
//
//	capture process  ──pipe──▶  20 ms framer  ──▶  Opus encoder  ──▶  UDP
//	UDP  ──▶  jitter buffer  ──▶  Opus decoder (or PLC)  ──▶  pipe  ──▶  pw-play
//
// 48 kHz mono, 20 ms frames, 960 samples, 1920 bytes of PCM, about 80 bytes of
// Opus at 32 kbit/s.
//
// Two decisions are worth stating because they are where audio goes wrong:
//
// *Nothing here owns a playout clock.* pw-play consumes its stdin at exactly
// 48 kHz, so the pipe is the clock: frames are popped from the jitter buffer
// only when the pipe accepts them, and when it stops accepting, popping stops.
// A clock of our own would drift against the sound card and the drift would
// come out as a click every few seconds.
//
// *Capture is a bounded queue, not a stream.* A pipe left at its 64 KiB
// default holds 680 ms of PCM, so a producer that ever runs ahead silently
// adds two thirds of a second of latency that no jitter buffer downstream can
// remove. The capture pipe is shrunk, and anything beyond CAP_BACKLOG_FRAMES
// is discarded at the framer with a counter, which is the honest trade: a
// dropped frame now beats a delayed one forever.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:math"
import "core:slice"

A_RATE :: 48000
A_CHANNELS :: 1
A_FRAME_MS :: 20
A_FRAME_SAMPLES :: A_RATE * A_FRAME_MS / 1000 // 960
A_FRAME_BYTES :: A_FRAME_SAMPLES * 2          // 1920
A_BITRATE :: 32000

// Capture backlog allowed before frames are discarded, in 20 ms frames.
CAP_BACKLOG_FRAMES :: 3

// How many frames may be handed to the player in one UI frame. At 60 fps the
// steady state is one, so three is headroom for a hitch, not a policy.
PLAYOUT_BURST :: 4

// Opus bounds its own packets well below this; the ceiling is for the raw-PCM
// fallback.
A_MAX_PACKET :: 4000

// PLAYOUT_TARGET_US is how much audio the player is allowed to be holding
// before this end stops feeding it. Two 20 ms frames of cushion plus the
// 20 ms pw-play was asked for; anything beyond that is latency with no
// resilience to show for it.
PLAYOUT_TARGET_US :: 40_000.0

Audio_Stats :: struct {
	// Capture-to-playout, measured against the sender's own clock. Both
	// processes read CLOCK_MONOTONIC_RAW, so this is a subtraction, not an
	// estimate.
	last_us: f64,
	min_us:  f64,
	max_us:  f64,
	sum_us:  f64,
	n:       int,

	// Capture-to-received, i.e. without the playout queue.
	wire_last_us: f64,
	wire_sum_us:  f64,
	wire_n:       int,
}

stat_add :: proc(st: ^Audio_Stats, us: f64) {
	st.last_us = us
	if st.n == 0 || us < st.min_us {
		st.min_us = us
	}
	if us > st.max_us {
		st.max_us = us
	}
	st.sum_us += us
	st.n += 1
}

stat_mean :: proc(st: ^Audio_Stats) -> f64 {
	if st.n == 0 {
		return 0
	}
	return st.sum_us / f64(st.n)
}

stat_wire_mean :: proc(st: ^Audio_Stats) -> f64 {
	if st.wire_n == 0 {
		return 0
	}
	return st.wire_sum_us / f64(st.wire_n)
}

Audio :: struct {
	cap:  Child,
	play: Child,
	enc:  ^Opus_Encoder,
	dec:  ^Opus_Decoder,

	// use_opus is false when libopus would not create a state, in which case
	// 1920-byte PCM frames go on the wire and the UI says so.
	use_opus: bool,
	codec:    string,

	jb: Jitter,

	// 20 ms framer over the capture pipe.
	acc:   [A_FRAME_BYTES]u8,
	acc_n: int,

	// Playout staging: one frame, written across however many ticks the pipe
	// needs to accept it.
	out:     [A_FRAME_BYTES]u8,
	out_n:   int,
	out_off: int,

	// Levels, 0..1, with a fast attack and a slow release so the meter reads
	// like a meter instead of flickering.
	tx_level: f32,
	rx_level: f32,
	tx_peak:  f32,
	rx_peak:  f32,

	muted:  bool,
	volume: f32,

	stats: Audio_Stats,

	// The player's own queue. pw-play drains its stdin at exactly 48 kHz, so
	// how much is still in flight is arithmetic over a known constant rate
	// rather than a guess: bytes written, minus the bytes that constant rate
	// has consumed since the first write. It is the one part of the path a
	// timestamp cannot reach, so it is computed and reported rather than
	// quietly left out of the latency figure.
	play_written: int,
	play_t0:      u64,
	play_queue_us: f64,
	play_queue_max_us: f64,
	// The mean skips the first second of writes: starting a PipeWire stream
	// primes its ring in one burst, and averaging that in would describe the
	// startup rather than the call.
	play_queue_sum_us: f64,
	play_queue_n:      int,

	frames_captured: int,
	frames_sent:     int,
	frames_played:   int,
	cap_backlog_drops: int,
	play_overruns:     int,

	source_label: string,
	sink_label:   string,
	cap_error:    string,
	play_error:   string,

	// The capture pipe size the kernel actually granted, in bytes, and the
	// backlog observed in it — the only latency on our side of the capture
	// timestamp, so it is measured rather than assumed.
	cap_pipe_bytes:  int,
	cap_backlog_us:  f64,
	cap_backlog_max_us: f64,
}

// ---------------------------------------------------------------------------
// Source and sink commands
// ---------------------------------------------------------------------------

// SYNTH_TONE is a 440 Hz tone whose amplitude swings over a 2.5 s cycle. A
// constant tone would make the level meter a static bar and prove nothing, so
// the synthetic source modulates: the meter has to move for the picture to be
// right.
//
// `arealtime` rather than `-re` is the pacing. `-re` gates on wall clock and
// overshoots: measured here it produced 8.48 s of audio in 8.01 s, 5.9 % fast.
// A capture clock running 5.9 % faster than the sound card means 5.9 % of the
// audio has to be thrown away somewhere, which the jitter buffer's ceiling
// duly did — twenty audible 20 ms skips in a thirty second call. `arealtime`
// paces on the sample count instead and lands within 0.5 %.
SYNTH_TONE ::
	"aevalsrc=0.75*sin(2*PI*440*t)*(0.55+0.45*sin(2*PI*0.4*t)):s=48000:c=mono,arealtime"

// synth_tone is what the synthetic microphone actually plays. SFU mode
// replaces it with a scheduled talker (`--talk`), so three headless
// participants can take turns and the dominant-speaker detector has turns to
// find.
synth_tone := SYNTH_TONE

// null_audio sends playout to a paced null sink instead of pw-play, so a
// headless multi-party measurement never makes a sound on this machine. The
// sink still consumes at exactly 48 kHz (`-re`), so the playout clock and the
// queue model behave as they do with a sound card.
null_audio := false

// Echo cancellation is the system's job here, not this program's. PipeWire's
// module-echo-cancel runs WebRTC's AEC3 (libspa-aec-webrtc, installed on
// this machine) between a virtual source and a virtual sink; an application
// that records from the one and plays into the other gets the far end's
// voice removed from its microphone. `--echo-cancel` makes the real-device
// path target those nodes by their default names. It changes nothing for the
// synthetic sources, which have no acoustic path to cancel, and nothing at
// all unless the module is loaded — Palmframe's PipeWire config is where that
// belongs (see apps/call/PROTOCOL.md, "Echo cancellation").
aec_nodes := false
AEC_SOURCE :: "echo-cancel-source"
AEC_SINK :: "echo-cancel-sink"

// Both argv builders allocate in the temp allocator, which palmy resets every
// frame. The strings outlive the `process_start` that copies them, which is
// all they have to do.
audio_capture_argv :: proc(dev: Device) -> []string {
	if dev.kind == .Synthetic {
		return slice.clone([]string{
			"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
			// Without pacing, ffmpeg emits the whole infinite stream as fast
			// as the pipe will take it — measured at 0.03 s to produce 2 s —
			// and every read returns stale audio. The `arealtime` filter in
			// SYNTH_TONE is the pacing; see the note there for why it is not
			// `-re`.
			"-f", "lavfi", "-i", synth_tone,
			"-f", "s16le", "-ar", "48000", "-ac", "1", "-",
		}, context.temp_allocator)
	}
	// A real microphone. pw-record is already realtime, so no pacing flag.
	return slice.clone([]string{
		"pw-record", "--raw",
		"--rate=48000", "--channels=1", "--format=s16", "--latency=20ms",
		aec_nodes ? "--target=" + AEC_SOURCE : fmt.tprintf("--target=%d", dev.id), "-",
	}, context.temp_allocator)
}

audio_playback_argv :: proc(dev: Device, volume: f32) -> []string {
	if null_audio {
		return slice.clone([]string{
			"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
			"-re", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", "-",
			"-f", "null", "-",
		}, context.temp_allocator)
	}
	if aec_nodes {
		return slice.clone([]string{
			"pw-play", "--raw",
			"--rate=48000", "--channels=1", "--format=s16", "--latency=10ms",
			fmt.tprintf("--volume=%.2f", volume),
			"--target=" + AEC_SINK, "-",
		}, context.temp_allocator)
	}
	if dev.id > 0 {
		return slice.clone([]string{
			"pw-play", "--raw",
			"--rate=48000", "--channels=1", "--format=s16", "--latency=10ms",
			fmt.tprintf("--volume=%.2f", volume),
			fmt.tprintf("--target=%d", dev.id), "-",
		}, context.temp_allocator)
	}
	return slice.clone([]string{
		"pw-play", "--raw",
		"--rate=48000", "--channels=1", "--format=s16", "--latency=10ms",
		fmt.tprintf("--volume=%.2f", volume), "-",
	}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

audio_init :: proc(a: ^Audio) {
	a.volume = 0.35
	e: i32
	// VOIP mode, which is the application's own preset for speech over a lossy
	// link: it biases the bit allocation toward intelligibility and keeps the
	// decoder's concealment well fed.
	a.enc = opus_encoder_create(A_RATE, A_CHANNELS, OPUS_APPLICATION_VOIP, &e)
	if a.enc != nil && e == 0 {
		opus_encoder_ctl(a.enc, OPUS_SET_BITRATE_REQUEST, i32(A_BITRATE))
		opus_encoder_ctl(a.enc, OPUS_SET_COMPLEXITY_REQUEST, i32(5))
		opus_encoder_ctl(a.enc, OPUS_SET_SIGNAL_REQUEST, i32(OPUS_SIGNAL_VOICE))
		// In-band FEC plus an expected loss figure makes Opus carry a coarse
		// copy of the previous frame, which is what lets the decoder rebuild a
		// single dropped packet rather than only conceal it.
		opus_encoder_ctl(a.enc, OPUS_SET_INBAND_FEC_REQUEST, i32(1))
		opus_encoder_ctl(a.enc, OPUS_SET_PACKET_LOSS_PERC_REQUEST, i32(5))
	} else {
		a.enc = nil
	}
	a.dec = opus_decoder_create(A_RATE, A_CHANNELS, &e)
	if e != 0 {
		a.dec = nil
	}
	a.use_opus = a.enc != nil && a.dec != nil
	if a.use_opus {
		a.codec = fmt.aprintf("Opus %d kbit/s  (%s)", A_BITRATE / 1000, opus_version())
	} else {
		a.codec = "PCM s16le 768 kbit/s  (libopus unavailable)"
	}
}

audio_destroy :: proc(a: ^Audio) {
	audio_stop(a)
	if a.enc != nil {
		opus_encoder_destroy(a.enc)
		a.enc = nil
	}
	if a.dec != nil {
		opus_decoder_destroy(a.dec)
		a.dec = nil
	}
}

audio_start :: proc(a: ^Audio, src, sink: Device) {
	audio_stop(a)
	jb_clear(&a.jb)
	a.acc_n = 0
	a.out_n = 0
	a.out_off = 0
	a.stats = {}

	argv := audio_capture_argv(src)
	// Four frames of slack. Anything more is latency we cannot get back.
	c, err := spawn_reader(argv, A_FRAME_BYTES * (CAP_BACKLOG_FRAMES + 1))
	if err != "" {
		a.cap_error = err
	} else {
		a.cap = c
		a.cap_error = ""
		a.cap_pipe_bytes = pipe_size(c.read_fd)
	}
	a.source_label = src.name

	a.play_written = 0
	a.play_t0 = 0
	a.play_queue_us = 0
	a.play_queue_max_us = 0

	pargv := audio_playback_argv(sink, a.volume)
	// One page, which is the kernel's floor: 4096 bytes is 2.1 frames, so the
	// pipe can hide at most 42 ms. A 64 KiB default would hide 680.
	pc, perr := spawn_writer(pargv, 4096)
	if perr != "" {
		a.play_error = perr
	} else {
		a.play = pc
		a.play_error = ""
	}
	a.sink_label = sink.name
}

audio_stop :: proc(a: ^Audio) {
	child_stop(&a.cap)
	child_stop(&a.play)
	a.tx_level = 0
	a.rx_level = 0
}

audio_running :: proc(a: ^Audio) -> bool {
	return a.cap.running || a.play.running
}

// ---------------------------------------------------------------------------
// Levels
// ---------------------------------------------------------------------------

// frame_rms returns the RMS of a 16-bit frame as a 0..1 meter reading on a
// 60 dB scale, which is how a mixer's input meter is scaled.
frame_rms :: proc(pcm: []i16) -> f32 {
	if len(pcm) == 0 {
		return 0
	}
	acc: f64
	for s in pcm {
		v := f64(s) / 32768
		acc += v * v
	}
	rms := math.sqrt(acc / f64(len(pcm)))
	if rms <= 0.000_001 {
		return 0
	}
	db := 20 * math.log10(f32(rms))
	return clamp((db + 60) / 60, 0, 1)
}

meter_follow :: proc(cur: ^f32, target: f32, dt: f32) {
	// 8 ms attack, 350 ms release.
	k := target > cur^ ? min(1, dt / 0.008) : min(1, dt / 0.35)
	cur^ += (target - cur^) * k
}

peak_follow :: proc(cur: ^f32, level: f32, dt: f32) {
	if level > cur^ {
		cur^ = level
	} else {
		cur^ = max(0, cur^ - dt * 0.35)
	}
}

// ---------------------------------------------------------------------------
// Capture, encode, send
// ---------------------------------------------------------------------------

audio_pump_capture :: proc(a: ^Audio, s: ^Session, dt: f32) {
	if !a.cap.running {
		meter_follow(&a.tx_level, 0, dt)
		return
	}

	// Discard whole frames beyond the allowed backlog before reading any, so
	// the frame we encode is the newest one available.
	pending := child_pending(&a.cap) + a.acc_n
	a.cap_backlog_us = f64(pending) / f64(A_RATE * 2) * 1_000_000
	if a.cap_backlog_us > a.cap_backlog_max_us {
		a.cap_backlog_max_us = a.cap_backlog_us
	}
	if pending > A_FRAME_BYTES * CAP_BACKLOG_FRAMES {
		excess := pending - A_FRAME_BYTES * CAP_BACKLOG_FRAMES
		drop := (excess / A_FRAME_BYTES) * A_FRAME_BYTES
		for drop > 0 {
			scratch: [A_FRAME_BYTES]u8
			want := min(drop, A_FRAME_BYTES)
			n, eof := child_read(&a.cap, scratch[:want])
			if n <= 0 || eof {
				break
			}
			drop -= n
			a.cap_backlog_drops += 1
		}
	}

	level: f32 = -1
	pkt: [A_MAX_PACKET]u8

	for {
		n, eof := child_read(&a.cap, a.acc[a.acc_n:])
		a.acc_n += n
		if eof {
			a.cap_error = a.cap.last_errno == .NONE \
				? "capture process exited" \
				: fmt.aprintf("capture read failed: %v", a.cap.last_errno)
			child_stop(&a.cap)
			break
		}
		if a.acc_n < A_FRAME_BYTES {
			break
		}

		pcm := (cast([^]i16)raw_data(a.acc[:]))[:A_FRAME_SAMPLES]
		a.frames_captured += 1
		level = frame_rms(pcm)

		// Timestamp at capture, not at send: the number this app reports as
		// latency is then capture-to-playout, which is the only figure a
		// listener can hear.
		ts := now_us()

		if a.muted {
			// Mute transmits encoded silence rather than nothing at all. A
			// stream that simply stops would starve the far jitter buffer and
			// make unmuting audible as a stutter; silence keeps the sequence
			// running and costs Opus about three bytes a frame.
			for i in 0 ..< A_FRAME_SAMPLES {
				pcm[i] = 0
			}
		}

		// The RFC 6464 level octet rides in the clear in SFU mode, where the
		// forwarder picks the dominant speaker from it without decoding.
		lvl := s.room != nil ? room_level_byte(pcm) : 127

		if a.use_opus {
			nb := opus_encode(a.enc, raw_data(pcm), A_FRAME_SAMPLES, raw_data(pkt[:]), A_MAX_PACKET)
			if nb > 0 {
				send_media(s, .Audio_Opus, pkt[:nb], ts, 0, 0, lvl)
				a.frames_sent += 1
			}
		} else {
			send_media(s, .Audio_PCM, a.acc[:A_FRAME_BYTES], ts)
			a.frames_sent += 1
		}

		a.acc_n = 0
		if n == 0 {
			break
		}
	}

	if level >= 0 {
		meter_follow(&a.tx_level, a.muted ? 0 : level, dt)
		peak_follow(&a.tx_peak, a.muted ? 0 : level, dt)
	} else {
		meter_follow(&a.tx_level, a.tx_level, dt)
		peak_follow(&a.tx_peak, 0, dt)
	}
}

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

audio_receive :: proc(a: ^Audio, h: Header, payload: []u8) {
	// Audio frames are never fragmented — an Opus frame is 80 bytes and a PCM
	// frame is 1920, both under the MTU — so the sequence number is the frame
	// number and the jitter buffer can index on it directly.
	if h.nfrag != 1 {
		return
	}
	wire := f64(now_us() - h.ts_us)
	a.stats.wire_last_us = wire
	a.stats.wire_sum_us += wire
	a.stats.wire_n += 1
	jb_push(&a.jb, h.seq, h.ts_us, payload)
}

// ---------------------------------------------------------------------------
// Decode and play
// ---------------------------------------------------------------------------

// flush_out pushes whatever the player's pipe will take, and does the
// accounting for the queue model in the one place bytes actually leave: a
// frame can be written across several ticks, and counting it at the call site
// would count the first part and lose the rest.
@(private = "file")
flush_out :: proc(a: ^Audio) -> bool {
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

audio_pump_playout :: proc(a: ^Audio, dt: f32) {
	if !a.play.running {
		meter_follow(&a.rx_level, 0, dt)
		return
	}

	// Enforce the jitter buffer's ceiling before taking anything out of it, so
	// a slow drift between the capture clock and the sound card's cannot turn
	// into unbounded latency.
	jb_trim(&a.jb)

	// Refresh the queue figure even on a tick that writes nothing: the player
	// keeps draining whether or not we feed it.
	a.play_queue_us = play_queue_now(a)

	level: f32 = -1
	for _ in 0 ..< PLAYOUT_BURST {
		if !flush_out(a) {
			// The pipe is full, which means pw-play has not consumed its
			// buffer yet. That is the clock saying "not now".
			break
		}

		// And stop before the pipe is full, once the player is holding the
		// target. A pipe will happily accept another frame and pw-play will
		// happily read it into its own ring, where it becomes latency nobody
		// asked for — measured at 90 ms of standing queue when this loop fed
		// as fast as the pipe would take it.
		if play_primed(a) && a.play_queue_us > PLAYOUT_TARGET_US {
			break
		}

		pkt: [A_MAX_PACKET]u8
		n, ts, res := jb_pop(&a.jb, pkt[:])
		if res == .Starved {
			break
		}

		pcm := (cast([^]i16)raw_data(a.out[:]))[:A_FRAME_SAMPLES]
		produced := 0

		if res == .Concealed {
			if a.use_opus {
				// Opus' own packet-loss concealment: extrapolate one frame
				// from the decoder's history and fade it.
				got := opus_decode(a.dec, nil, 0, raw_data(pcm), A_FRAME_SAMPLES, 0)
				produced = got > 0 ? int(got) : 0
			}
			if produced == 0 {
				// PCM fallback concealment: silence, ramped over 2 ms at each
				// end so the splice is not a click.
				conceal_silence(pcm)
				produced = A_FRAME_SAMPLES
			}
		} else if a.use_opus {
			got := opus_decode(a.dec, raw_data(pkt[:n]), i32(n), raw_data(pcm), A_FRAME_SAMPLES, 0)
			if got <= 0 {
				continue
			}
			produced = int(got)
			e2e := f64(now_us() - ts)
			stat_add(&a.stats, e2e)
		} else {
			if n < A_FRAME_BYTES {
				continue
			}
			copy(a.out[:A_FRAME_BYTES], pkt[:A_FRAME_BYTES])
			produced = A_FRAME_SAMPLES
			e2e := f64(now_us() - ts)
			stat_add(&a.stats, e2e)
		}

		a.out_n = produced * 2
		a.out_off = 0
		level = frame_rms(pcm[:produced])
		a.frames_played += 1
		if !flush_out(a) {
			a.play_overruns += 1
			break
		}
	}

	if level >= 0 {
		meter_follow(&a.rx_level, level, dt)
		peak_follow(&a.rx_peak, level, dt)
	} else {
		meter_follow(&a.rx_level, 0, dt)
		peak_follow(&a.rx_peak, 0, dt)
	}
}

// play_queue_now is how much audio is still in flight ahead of the DAC:
// everything written, minus what a constant 48 kHz has consumed since the
// first write. It is arithmetic over a known rate, not an estimate.
//
// It is a lower bound, because pw-play does not begin draining at the instant
// of the first write — it primes its stream first — so the subtraction credits
// it with slightly more than it has actually played.
play_queue_now :: proc(a: ^Audio) -> f64 {
	if a.play_t0 == 0 {
		return 0
	}
	drained_us := f64(now_us() - a.play_t0)
	written_us := f64(a.play_written) / f64(A_RATE * 2) * 1_000_000
	return max(0, written_us - drained_us)
}

// play_primed reports whether the player has been running long enough for the
// queue figure to mean anything. Starting a PipeWire stream fills its ring in
// one burst, and both the pacing and the average have to ignore that.
play_primed :: proc(a: ^Audio) -> bool {
	return a.play_t0 != 0 && now_us() - a.play_t0 > 1_000_000
}

// update_play_queue records the queue at the moment a frame was handed over,
// which is the delay that frame actually experiences.
update_play_queue :: proc(a: ^Audio) {
	a.play_queue_us = play_queue_now(a)
	if !play_primed(a) {
		return
	}
	if a.play_queue_us > a.play_queue_max_us {
		a.play_queue_max_us = a.play_queue_us
	}
	a.play_queue_sum_us += a.play_queue_us
	a.play_queue_n += 1
}

play_queue_mean_us :: proc(a: ^Audio) -> f64 {
	if a.play_queue_n == 0 {
		return 0
	}
	return a.play_queue_sum_us / f64(a.play_queue_n)
}

// PLAYER_LATENCY_MS is the buffer pw-play is asked for on its command line.
// It is the floor on the downstream tail: even when the modelled queue says we
// are feeding the player just in time, pw-play itself still holds this much.
PLAYER_LATENCY_MS :: 10.0

// audio_end_to_end_ms is the framer to the loudspeaker: the measured
// framer-to-handover figure plus everything still downstream.
//
// The modelled queue covers the pipe *and* pw-play's own ring, because it is
// written-minus-consumed at a rate that is exactly 48 kHz — there is nothing
// between that arithmetic and the DAC but the device buffer. What this figure
// does **not** include is the capture side's own latency inside ffmpeg, which
// is upstream of the timestamp; `cap_backlog_us` measures the part of that
// which is ours.
audio_end_to_end_ms :: proc(a: ^Audio) -> f64 {
	return stat_mean(&a.stats) / 1000 + max(play_queue_mean_us(a) / 1000, PLAYER_LATENCY_MS)
}

// conceal_silence is the raw-PCM fallback's concealment: a 20 ms gap, with the
// first and last 2 ms faded from and to the neighbouring samples so the splice
// is a fade rather than a step. Opus covers this case with its own PLC
// whenever libopus is available, which is the normal path.
conceal_silence :: proc(pcm: []i16) {
	RAMP :: A_RATE * 2 / 1000 // 96 samples
	head := pcm[0]
	for i in 0 ..< len(pcm) {
		pcm[i] = 0
	}
	for i in 0 ..< min(RAMP, len(pcm)) {
		g := 1 - f32(i) / f32(RAMP)
		pcm[i] = i16(f32(head) * g)
	}
}
