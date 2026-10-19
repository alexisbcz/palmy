package pcp

// The two decisions an SFU makes per call, as pure functions over numbers so
// the self-test can drive them without sockets: who is speaking, and which
// video each receiver can afford.

// ---------------------------------------------------------------------------
// Dominant speaker
//
// A simplified form of Volfin & Cohen's dominant speaker identification
// (Computer Speech & Language, 2013), which is what Jitsi Videobridge and
// mediasoup's ActiveSpeakerObserver run: activity is scored over more than one
// time scale, from audio levels alone, and the speaker changes only when a
// challenger's activity beats the incumbent's convincingly *and for long
// enough*. The original scores three windows with a binomial speech-activity
// model; this keeps the shape — a short (200 ms) and a medium (1 s) window,
// a margin, and a hold time — and drops the statistics. It decides from the
// RFC 6464 level byte, so it works on encrypted audio.
// ---------------------------------------------------------------------------

SPK_RING :: 50 // 50 × 20 ms = 1 s
SPK_SHORT :: 10 // 200 ms
SPK_HOLD :: 0.40 // a challenger must lead this long
SPK_MARGIN :: 0.12 // ... by at least this much activity
SPK_STALE :: 0.5 // no audio for this long counts as silence

Spk :: struct {
	src:    u16,
	ring:   [SPK_RING]f32,
	idx:    int,
	n:      int,
	last_t: f64,
}

Speaker_Detector :: struct {
	parts:      [dynamic]Spk,
	current:    u16, // 0 = nobody yet
	challenger: u16,
	since:      f64,
	switches:   int,
}

// level_activity maps an RFC 6464 octet to 0..1: 0 when voice activity is
// not flagged, otherwise rising from the VAD threshold (-50 dBov) to -10.
level_activity :: proc(l: u8) -> f32 {
	if !level_vad(l) {
		return 0
	}
	db := level_dbov(l)
	return f32(clamp((db + 50) / 40, 0.05, 1))
}

speaker_feed :: proc(d: ^Speaker_Detector, src: u16, level: u8, t: f64) {
	p: ^Spk
	for &x in d.parts {
		if x.src == src {
			p = &x
			break
		}
	}
	if p == nil {
		append(&d.parts, Spk{src = src})
		p = &d.parts[len(d.parts) - 1]
	}
	p.ring[p.idx] = level_activity(level)
	p.idx = (p.idx + 1) % SPK_RING
	p.n = min(p.n + 1, SPK_RING)
	p.last_t = t
}

speaker_forget :: proc(d: ^Speaker_Detector, src: u16) {
	for x, i in d.parts {
		if x.src == src {
			ordered_remove(&d.parts, i)
			break
		}
	}
	if d.current == src {
		d.current = 0
	}
	if d.challenger == src {
		d.challenger = 0
	}
}

speaker_score :: proc(p: ^Spk, t: f64) -> f32 {
	if p.n == 0 || t - p.last_t > SPK_STALE {
		return 0
	}
	short, long: f32
	ns := min(p.n, SPK_SHORT)
	for i in 0 ..< p.n {
		v := p.ring[(p.idx - 1 - i + SPK_RING * 2) % SPK_RING]
		long += v
		if i < ns {
			short += v
		}
	}
	return 0.6 * short / f32(ns) + 0.4 * long / f32(SPK_RING)
}

// speaker_tick returns true when the dominant speaker changed.
speaker_tick :: proc(d: ^Speaker_Detector, t: f64) -> bool {
	best: u16
	best_s: f32
	cur_s: f32
	for &p in d.parts {
		s := speaker_score(&p, t)
		if p.src == d.current {
			cur_s = s
		}
		if s > best_s {
			best_s, best = s, p.src
		}
	}
	if best == 0 || best == d.current || best_s < 0.08 {
		d.challenger = 0
		return false
	}
	// Nobody yet: the first real activity takes the floor at once.
	if d.current == 0 {
		d.current = best
		d.switches += 1
		return true
	}
	if best_s < cur_s + SPK_MARGIN {
		d.challenger = 0
		return false
	}
	if d.challenger != best {
		d.challenger = best
		d.since = t
		return false
	}
	if t - d.since >= SPK_HOLD {
		d.current = best
		d.challenger = 0
		d.switches += 1
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Video tier per receiver
//
// Every sender publishes two simulcast layers: layer 0 at the call
// resolution and layer 1 at a quarter of the pixels and half the frame rate.
// For each receiver the SFU forwards one of them from every sender, or none.
//
//	High    layer 0 from everyone
//	Low     layer 1 from everyone (half the frame rate: this is the fps drop)
//	Audio   no video at all, when even Low does not fit
//
// The estimate is loss-based, as libwebrtc's loss controller is: when a
// receiver reports loss, what it *did* receive is close to what its link
// carries, so the estimate drops to that; while it reports none, the estimate
// creeps up, and an upgrade is tried only after a run of clean reports and an
// exponentially backed-off probe interval, so a link that cannot take High
// does not flap between High and Low every second.
// ---------------------------------------------------------------------------

Tier :: enum u8 {
	High,
	Low,
	Audio,
}

TIER_NAMES := [Tier]string {
	.High  = "high",
	.Low   = "low",
	.Audio = "audio",
}

// Per-sender costs in kbit/s, including PCP2 and UDP/IP overhead.
KBPS_HIGH :: 330
KBPS_LOW :: 115
KBPS_AUDIO :: 45

LOSS_BAD :: 5.0 // percent: back off
LOSS_GOOD :: 1.5 // percent: clean
PROBE_MIN :: 2.0 // seconds
PROBE_MAX :: 20.0

tier_need :: proc(t: Tier, senders: int) -> f64 {
	n := f64(max(senders, 1))
	switch t {
	case .High:
		return n * (KBPS_HIGH + KBPS_AUDIO)
	case .Low:
		return n * (KBPS_LOW + KBPS_AUDIO)
	case .Audio:
		return n * KBPS_AUDIO
	}
	return 0
}

Tier_State :: struct {
	tier:       Tier,
	est:        f64, // kbit/s
	clean:      int, // consecutive clean reports
	next_probe: f64,
	backoff:    f64,
	changes:    int,
}

tier_init :: proc(s: ^Tier_State) {
	s.tier = .High
	s.est = 1e9 // unknown: assume the best until told otherwise
	s.backoff = PROBE_MIN
}

// tier_update folds one receiver report into the state and returns true when
// the tier changed. `loss` is percent of expected media packets missing since
// the last report, `kbps` what arrived, `cap` a ceiling the receiver declares
// (0 = none), `senders` how many others are sending video.
tier_update :: proc(s: ^Tier_State, loss, kbps, cap: f64, senders: int, now: f64) -> bool {
	if s.backoff == 0 {
		tier_init(s)
	}
	if loss >= LOSS_BAD {
		s.est = max(kbps * 0.9, tier_need(.Audio, senders))
		s.clean = 0
		s.next_probe = now + s.backoff
		s.backoff = min(s.backoff * 2, PROBE_MAX)
	} else if loss <= LOSS_GOOD {
		s.clean += 1
		if s.est < kbps {
			s.est = kbps
		}
		if s.clean >= 3 && now >= s.next_probe && s.est < 1e8 {
			// Probe: allow the next tier up if it is within a quarter.
			s.est *= 1.25
			s.next_probe = now + s.backoff
		}
		if s.clean >= 10 {
			// A long clean run earns trust back.
			s.backoff = max(PROBE_MIN, s.backoff / 2)
		}
	}
	if cap > 0 && s.est > cap {
		s.est = cap
	}

	want := Tier.Audio
	if tier_need(.High, senders) <= s.est {
		want = .High
	} else if tier_need(.Low, senders) <= s.est {
		want = .Low
	}
	if want == s.tier {
		return false
	}
	// Down at once; up only after a clean run.
	if want > s.tier || s.clean >= 3 {
		s.tier = want
		s.changes += 1
		return true
	}
	return false
}
