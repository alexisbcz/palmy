package call

// ---------------------------------------------------------------------------
// Adaptive bitrate for the two-party call, driven by measured loss and RTT.
//
// Before this, the H.264 encoder ran at a fixed 300 kbit/s whatever the link
// did. Multi-party calls already adapt — palm-sfu picks a simulcast layer per
// receiver from its loss reports (PROTOCOL.md, "Simulcast and bandwidth") —
// but a direct call has no SFU to do it, so the *sender* adapts, on what the
// receiver reports.
//
// The receiver measures, per 500 ms window: packets expected (by sequence
// number, both streams) against packets received, and the media rate that
// arrived. It sends both back in a FEEDBACK control message, which also
// carries an RTT echo — the timestamp of the last FEEDBACK it received and how
// long it held it — so each end measures the round trip the way RTCP's
// LSR/DLSR do, with no shared clock assumed.
//
// The controller is the shape of Google Congestion Control (the one in
// libwebrtc, draft-ietf-rmcat-gcc), simplified to what two signals can carry:
//
//	loss > 10 %                      decrease:  rate *= 1 - loss/2
//	queueing delay > 40 ms           decrease:  rate = 0.85 * received rate
//	loss < 2 % and queueing < 15 ms  increase:  rate *= 1.08 per report
//	otherwise                        hold
//
// "Queueing delay" is measured by the receiver, one way, on the sender's
// direction: the smallest (arrival - capture timestamp) of the window minus
// the smallest ever seen. No clock sync is needed — the offset between the
// two clocks cancels in the subtraction — and the window minimum means the
// burst of one keyframe is not mistaken for a standing queue. (The first
// version used RTT, which cannot say which direction is congested: with only
// Alice's uplink constrained, Bob cut his own rate to the floor too.) it is the *growth* of the RTT that
// says a queue is filling, and that signal arrives before any loss does — a
// droptail bottleneck only drops once its queue is full, by which time the
// call has a quarter of a second of extra latency. That is why delay comes
// first and loss is the backstop. Decreases are at most one a second (the
// queue needs that long to drain before the next report means anything), and
// an increase waits two seconds after a decrease.
//
// Applying a rate is not free here: ffmpeg's encoder takes its bitrate on the
// command line, so a new rate is a restart of the encoder (which is also how
// a keyframe is forced — see `video_on_keyframe_request`), costing a keyframe
// of 5-7 KB. So the encoder follows the controller's target only when the
// two differ by more than 15 %, and not more than once every two seconds on
// the way up (half a second on the way down: congestion is urgent, headroom is
// not). Opus follows too, without a restart — its bitrate is an encoder ctl:
// 32 kbit/s normally, 24 under 140 kbit/s of video, 16 under 90, and its
// expected-loss figure (which sizes in-band FEC) tracks the measured loss.
//
// Measured with `call rate` (the simulation below; the same controller and
// link run in a real call with --link-kbps): into a 200 kbit/s bottleneck, a
// fixed 300 kbit/s loses 70 % of its packets with a full 250 ms queue (RTT
// 297 ms); adapting, it settles at ~80 kbit/s of video, 147 kbit/s on the
// wire with audio, 0.2 % loss and RTT 52 ms. That is 73 % of the link: the
// headroom is the price of a 6 KB keyframe on every rate change, which near
// capacity takes seconds to drain. Restarting less often (25 %, 4 s) used
// 91 % of the link but held 151 ms of RTT and 2 % loss; a call is better
// served by the latency.
//
// MJPEG does not adapt: it is quality-targeted (-q:v), not rate-targeted, and
// it is the fallback codec. Its rate is reported, not controlled.
// ---------------------------------------------------------------------------

import "core:math"
import "core:math/rand"

RATE_FEEDBACK_EVERY :: 0.5 // seconds
RATE_MIN_KBPS :: 60.0
RATE_LOSS_HIGH :: 0.10
RATE_LOSS_LOW :: 0.02
RATE_QUEUE_HIGH_MS :: 40.0
RATE_QUEUE_LOW_MS :: 15.0
RATE_DECREASE_GAP :: 1.0
RATE_HOLD_AFTER_DECREASE :: 2.0
RATE_APPLY_DELTA :: 0.15
RATE_APPLY_UP_GAP :: 2.0
RATE_APPLY_DOWN_GAP :: 0.5

Rate_Reason :: enum u8 {
	None,
	Loss,
	Delay,
	Increase,
	Hold,
}

Rate_Ctl :: struct {
	kbps:     f64, // the controller's target
	min_kbps: f64,
	max_kbps: f64,

	rtt_ms:     f64, // smoothed
	min_rtt_ms: f64,
	// The last two samples. The queueing signal is the smaller of them: a
	// standing queue shows in both, while the burst of one keyframe — and
	// every rate change here costs one — shows in one at most.
	rtt_last:   [2]f64,
	have_rtt:   bool,
	last_loss:  f64,
	last_queue_ms: f64,
	// The receiver's own measure of the queue on *our* direction: its
	// one-way delay, the window's minimum over the smallest ever seen. Used
	// when the peer reports it, which this version always does; the RTT
	// rule above is the fallback, and it cannot tell which direction is
	// congested — measured: with only Alice's uplink constrained, Bob's RTT
	// rose too and Bob cut his own rate to the floor for nothing.
	queue_ms:   f64,
	have_queue: bool,
	last_reason: Rate_Reason,

	last_decrease: f64,

	// What the encoder is actually running at, and when that last changed.
	applied:    f64,
	applied_at: f64,

	increases, decreases, restarts: int,
}

rate_init :: proc(c: ^Rate_Ctl, start_kbps: f64, min_kbps := RATE_MIN_KBPS) {
	c^ = {}
	c.kbps = start_kbps
	c.max_kbps = start_kbps
	c.min_kbps = min(min_kbps, start_kbps)
	c.applied = start_kbps
	c.last_decrease = -100
	c.applied_at = -100
}

// rate_on_queue takes the queueing delay the receiver measured on our
// direction.
rate_on_queue :: proc(c: ^Rate_Ctl, q_ms: f64) {
	c.queue_ms = max(0, q_ms)
	c.have_queue = true
}

// rate_on_rtt folds one RTT sample in.
rate_on_rtt :: proc(c: ^Rate_Ctl, rtt_ms: f64) {
	if rtt_ms < 0 || rtt_ms > 10_000 {
		return
	}
	c.rtt_last[1] = c.rtt_last[0]
	c.rtt_last[0] = rtt_ms
	if !c.have_rtt {
		c.rtt_ms = rtt_ms
		c.min_rtt_ms = rtt_ms
		c.rtt_last[1] = rtt_ms
		c.have_rtt = true
		return
	}
	c.rtt_ms = 0.7 * c.rtt_ms + 0.3 * rtt_ms
	if rtt_ms < c.min_rtt_ms {
		c.min_rtt_ms = rtt_ms
	}
}

// rate_on_feedback is one receiver report: `loss` is a fraction (0..1) of the
// packets expected in the window, `recv_kbps` what arrived. Returns why the
// target moved, if it did.
rate_on_feedback :: proc(c: ^Rate_Ctl, now: f64, loss: f64, recv_kbps: f64) -> Rate_Reason {
	c.last_loss = loss
	queue := c.have_rtt ? min(c.rtt_last[0], c.rtt_last[1]) - c.min_rtt_ms : 0
	if c.have_queue {
		queue = c.queue_ms
	}
	c.last_queue_ms = queue
	reason := Rate_Reason.Hold
	target := c.kbps
	can_decrease := now - c.last_decrease >= RATE_DECREASE_GAP
	switch {
	case loss > RATE_LOSS_HIGH:
		if can_decrease {
			target = c.kbps * (1 - 0.5 * loss)
			reason = .Loss
		}
	case queue > RATE_QUEUE_HIGH_MS:
		if can_decrease {
			target = 0.85 * c.kbps
			if recv_kbps > 0 {
				target = min(target, 0.85 * recv_kbps)
			}
			reason = .Delay
		}
	case loss < RATE_LOSS_LOW && queue < RATE_QUEUE_LOW_MS:
		if now - c.last_decrease >= RATE_HOLD_AFTER_DECREASE {
			target = c.kbps * 1.08 + 1
			reason = .Increase
		}
	}
	target = clamp(target, c.min_kbps, c.max_kbps)
	if target < c.kbps {
		c.decreases += 1
		c.last_decrease = now
	} else if target > c.kbps {
		c.increases += 1
	} else if reason == .Increase {
		reason = .Hold // already at the ceiling
	}
	c.kbps = target
	c.last_reason = reason
	return reason
}

// rate_should_apply says whether the encoder should be restarted at the
// controller's target now, and if so updates what it is running at.
rate_should_apply :: proc(c: ^Rate_Ctl, now: f64) -> (kbps: int, apply: bool) {
	if c.applied <= 0 {
		return 0, false
	}
	rel := math.abs(c.kbps - c.applied) / c.applied
	at_floor := c.kbps == c.min_kbps && c.applied != c.min_kbps
	at_ceiling := c.kbps == c.max_kbps && c.applied != c.max_kbps
	if rel < RATE_APPLY_DELTA && !at_floor && !(at_ceiling && rel > 0.05) {
		return 0, false
	}
	gap := c.kbps < c.applied ? RATE_APPLY_DOWN_GAP : RATE_APPLY_UP_GAP
	if now - c.applied_at < gap {
		return 0, false
	}
	c.applied = c.kbps
	c.applied_at = now
	c.restarts += 1
	return int(c.kbps + 0.5), true
}

// rate_opus_bps is the audio bitrate that goes with a video target.
rate_opus_bps :: proc(video_kbps: f64) -> i32 {
	switch {
	case video_kbps < 90:
		return 16000
	case video_kbps < 140:
		return 24000
	}
	return A_BITRATE
}

rate_reason_name :: proc(r: Rate_Reason) -> string {
	switch r {
	case .None:
		return "none"
	case .Loss:
		return "loss"
	case .Delay:
		return "delay"
	case .Increase:
		return "increase"
	case .Hold:
		return "hold"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Receiver-side accounting: packets expected against received, per window.
// Sequence numbers wrap at 16 bits; the extended count is kept per stream.
// ---------------------------------------------------------------------------

Seq_Count :: struct {
	have:     bool,
	max_seq:  u16,
	expected: int, // extended highest - first + 1, cumulative
	received: int,
	// at the start of the current window
	w_expected: int,
	w_received: int,
}

seq_count_push :: proc(s: ^Seq_Count, seq: u16) {
	s.received += 1
	if !s.have {
		s.have = true
		s.max_seq = seq
		s.expected = 1
		return
	}
	d := i16(seq - s.max_seq)
	if d > 0 {
		s.expected += int(d)
		s.max_seq = seq
	}
}

// seq_count_window returns (expected, received) since the last call.
seq_count_window :: proc(s: ^Seq_Count) -> (expected, received: int) {
	expected = s.expected - s.w_expected
	received = s.received - s.w_received
	s.w_expected = s.expected
	s.w_received = s.received
	return
}

// ---------------------------------------------------------------------------
// An emulated bottleneck: a FIFO that drains at a fixed rate and drops at the
// tail once it holds more than `max_queue_ms` — what a home router's uplink
// does. Shared by the `rate` simulation and by `--link-kbps` in a real call.
// ---------------------------------------------------------------------------

Link :: struct {
	kbps:         f64,
	max_queue_ms: f64,
	busy_until:   f64, // seconds: when the link finishes what it has accepted
	dropped:      int,
	accepted:     int,
}

// link_admit decides one packet of `bytes` offered at `now`: dropped, or the
// time it leaves the far end of the link.
link_admit :: proc(l: ^Link, now: f64, bytes: int) -> (depart: f64, ok: bool) {
	start := max(now, l.busy_until)
	if (start - now) * 1000 > l.max_queue_ms {
		l.dropped += 1
		return 0, false
	}
	l.busy_until = start + f64(bytes * 8) / (l.kbps * 1000)
	l.accepted += 1
	return l.busy_until, true
}

link_queue_ms :: proc(l: ^Link, now: f64) -> f64 {
	return max(0, l.busy_until - now) * 1000
}

// ---------------------------------------------------------------------------
// The simulation behind `call rate`: the controller above, against the link
// above, with a sender that behaves like this application's — 30 frames a
// second of H.264 at the applied rate, a keyframe burst on every encoder
// restart, 50 Opus packets a second — and a receiver that reports every
// 500 ms. Time advances in 5 ms steps. Deterministic (fixed seed).
// ---------------------------------------------------------------------------

Rate_Sim :: struct {
	link_kbps, loss_pct, base_rtt_ms, start_kbps, seconds: f64,
	adaptive: bool,
	// Optional schedule: random loss applies only before this time (0 = whole run).
	loss_until: f64,
}

Rate_Result :: struct {
	final_kbps, mean_kbps, loss_pct, rtt_ms, goodput_kbps: f64,
	restarts, decreases, increases: int,
	// The target at each report, for the self-test's assertions on shape.
	trace: [dynamic]f64,
}

rate_simulate :: proc(cfg: Rate_Sim, keep_trace := false) -> (res: Rate_Result) {
	DT :: 0.005
	ctl: Rate_Ctl
	rate_init(&ctl, cfg.start_kbps)
	link := Link{kbps = cfg.link_kbps, max_queue_ms = 250}
	r := rand.create(0xB17)
	gen := rand.default_random_generator(&r)

	Inflight :: struct {
		at:    f64,
		bytes: int,
		video: bool,
	}
	q := make([dynamic]Inflight, 0, 4096, context.temp_allocator)
	sent_w, recv_w: [2]int // [audio, video]
	bytes_w: int
	next_fb := RATE_FEEDBACK_EVERY
	wq := f64(1e9) // the smallest queue a packet met in this window: one-way, as the receiver measures it
	next_video, next_audio := 0.0, 0.0
	pending_kf := 0
	last10 := cfg.seconds - 10
	sum_kbps, n_kbps, sum_rtt, n_rtt: f64
	sent10, recv10, bytes10: int

	if keep_trace {
		res.trace = make([dynamic]f64)
	}

	for t := 0.0; t < cfg.seconds; t += DT {
		send :: proc(link: ^Link, q: ^[dynamic]Inflight, t: f64, bytes: int, video: bool, lossy: bool, gen: rand.Generator, loss_pct: f64, wq: ^f64) -> bool {
			if lossy && rand.float64(gen) * 100 < loss_pct {
				return false
			}
			wq^ = min(wq^, link_queue_ms(link, t))
			dep, ok := link_admit(link, t, bytes)
			if ok {
				append(q, Inflight{dep, bytes, video})
			}
			return ok
		}
		lossy := cfg.loss_until <= 0 || t < cfg.loss_until
		// Video: one frame every 1/30 s, at the applied rate, cut into
		// 1200-byte fragments; a restart's keyframe is ~6 KB extra.
		if t >= next_video {
			next_video += 1.0 / 30
			frame := int(ctl.applied * 1000 / 8 / 30)
			frame += pending_kf
			pending_kf = 0
			for frame > 0 {
				b := min(frame, MTU_PAYLOAD) + HDR + 28
				frame -= MTU_PAYLOAD
				sent_w[1] += 1
				if t >= last10 {sent10 += 1}
				send(&link, &q, t, b, true, lossy, gen, cfg.loss_pct, &wq)
			}
		}
		if t >= next_audio {
			next_audio += 0.02
			sent_w[0] += 1
			if t >= last10 {sent10 += 1}
			opus := int(rate_opus_bps(ctl.applied)) / 8 / 50
			send(&link, &q, t, opus + HDR + 28, false, lossy, gen, cfg.loss_pct, &wq)
		}
		// Arrivals.
		for len(q) > 0 && q[0].at <= t {
			recv_w[q[0].video ? 1 : 0] += 1
			if q[0].video {
				bytes_w += q[0].bytes
			}
			if t >= last10 {
				recv10 += 1
				bytes10 += q[0].bytes
			}
			ordered_remove(&q, 0)
		}
		// The receiver's report, and the RTT its echo measures: the base RTT
		// plus whatever queue the link is holding now.
		if t >= next_fb {
			next_fb += RATE_FEEDBACK_EVERY
			// The worse of the two streams, as the real receiver reports.
			loss := 0.0
			for k in 0 ..< 2 {
				if sent_w[k] > 0 {
					loss = max(loss, 1 - f64(recv_w[k]) / f64(sent_w[k]))
				}
			}
			recv_kbps := f64(bytes_w) * 8 / 1000 / RATE_FEEDBACK_EVERY
			rtt := cfg.base_rtt_ms + link_queue_ms(&link, t)
			sent_w, recv_w, bytes_w = {}, {}, 0
			wq = 1e9
			if cfg.adaptive {
				rate_on_rtt(&ctl, rtt)
				if wq < 1e9 {
					rate_on_queue(&ctl, wq)
				}
				rate_on_feedback(&ctl, t, loss, recv_kbps)
				if _, apply := rate_should_apply(&ctl, t); apply {
					pending_kf += 6000
				}
			}
			if keep_trace {
				append(&res.trace, ctl.applied)
			}
			if t >= last10 {
				sum_kbps += ctl.applied
				n_kbps += 1
				sum_rtt += rtt
				n_rtt += 1
			}
		}
	}
	res.final_kbps = ctl.applied
	res.mean_kbps = n_kbps > 0 ? sum_kbps / n_kbps : 0
	res.loss_pct = sent10 > 0 ? max(0, 100 * (1 - f64(recv10) / f64(sent10))) : 0
	res.rtt_ms = n_rtt > 0 ? sum_rtt / n_rtt : 0
	span := min(10.0, cfg.seconds)
	res.goodput_kbps = f64(bytes10) * 8 / 1000 / span
	res.restarts = ctl.restarts
	res.decreases = ctl.decreases
	res.increases = ctl.increases
	return
}
