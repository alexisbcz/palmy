package call

// ---------------------------------------------------------------------------
// Self-tests for the echo canceller, the adaptive bitrate and end-to-end
// encryption of the direct call. Run as part of `call --self-test`.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:math"
import "core:net"
import "core:os"
import "core:time"
import "core:crypto/x25519"
import pcp "../../cloud/rtc/pcp"

// ---------------------------------------------------------------------------
// Echo cancellation
// ---------------------------------------------------------------------------

test_aec :: proc() {
	group("echo cancellation, in process, on a synthetic echo path")

	{
		f := fft_make(16)
		defer fft_destroy(&f)
		x: [16]complex64
		x[0] = 1
		fft_forward(&f, x[:])
		flat := true
		for v in x {
			if math.abs(real(v) - 1) > 1e-5 || math.abs(imag(v)) > 1e-5 {
				flat = false
			}
		}
		check(flat, "the FFT of an impulse is flat")
		y: [16]complex64
		for i in 0 ..< 16 {
			y[i] = complex(f32(i * i % 7) - 3, f32(i % 3))
		}
		z := y
		fft_forward(&f, z[:])
		fft_inverse(&f, z[:])
		worst: f32
		for i in 0 ..< 16 {
			worst = max(worst, abs(z[i] - y[i]))
		}
		check(worst < 1e-4, "forward then inverse is the identity (worst error %.2g)", worst)
	}

	// The frame interface is exactly one block late, no more.
	{
		a: Aec
		aec_init(&a)
		defer aec_destroy(&a)
		mic, far, out: [A_FRAME_SAMPLES]f32
		mic[10] = 0.5
		aec_frame(&a, mic[:], far[:], out[:])
		at := -1
		for v, i in out {
			if v != 0 {
				at = i
				break
			}
		}
		check_eq_int(at, AEC_N + 10, "the canceller's frame interface delays by one block (sample index)")
	}

	sc := AEC_SCENARIO_DEFAULT
	rep := aec_measure(sc)
	fmt.printfln("        synthetic voice, %v ms path at %v dB, %v ms room, %.0f ms tail:", sc.delay_ms, sc.gain_db, sc.room_ms, rep.tail_ms)
	fmt.printfln("        ERLE %.1f dB, echo removal %.1f dB, converged in %.0f ms; double talk %.1f dB (near/residual %.1f); after it %.1f; path moved %.1f",
		rep.erle_db, rep.echo_removal_db, rep.converge_ms, rep.dt_echo_removal_db, rep.dt_near_to_residual_db, rep.post_dt_erle_db, rep.reconverged_erle_db)
	check(rep.erle_db >= 20, "ERLE with the far end talking alone is at least 20 dB (%.1f)", rep.erle_db)
	check(rep.echo_removal_db >= 20, "the echo itself is at least 20 dB down (%.1f)", rep.echo_removal_db)
	check(rep.converge_ms > 0 && rep.converge_ms < 3000, "and it got there within 3 s of speech (%.0f ms)", rep.converge_ms)
	check(rep.dt_echo_removal_db >= 10, "double talk does not undo it: echo still %.1f dB down while both talk", rep.dt_echo_removal_db)
	check(rep.dt_near_to_residual_db >= 15, "and the near voice stands %.1f dB over what is left", rep.dt_near_to_residual_db)
	check(rep.post_dt_erle_db >= 18, "the model survives double talk: %.1f dB after it", rep.post_dt_erle_db)
	check(rep.reconverged_erle_db >= 10, "a moved echo path is re-learnt: %.1f dB 1.5 s after the move", rep.reconverged_erle_db)
	check(rep.cpu_ms_per_s < 200, "cheap enough for real time: %.1f ms per second of audio", rep.cpu_ms_per_s)

	// The same scoring with the canceller bypassed: what every assertion
	// above is measured against, and proof that they can fail.
	off := sc
	off.enabled = false
	base := aec_measure(off)
	check(math.abs(base.erle_db) < 0.5 && math.abs(base.echo_removal_db) < 0.5, "bypassed, the same score reads 0 dB (%.2f, %.2f)", base.erle_db, base.echo_removal_db)

	// ffmpeg's own generated sources: pink noise for the far end, a steady
	// tone for the near end. A stationary near end is the case a fixed step
	// gets wrong — it learns the tone during double talk and loses the echo
	// (measured with a fixed step of 0.7: -2.6 dB during, 1.3 dB after; with
	// speex's step and no pre-emphasis, a louder 440 Hz tone: -20 dB during).
	far, fok := lavfi_pcm("anoisesrc=color=pink:amplitude=0.2:seed=7:r=48000,volume=0.6", 12)
	near, nok := lavfi_pcm("sine=frequency=330:sample_rate=48000,volume=0.3", 12)
	if fok && nok {
		ff := sc
		ff.far, ff.near = far, near
		r2 := aec_measure(ff)
		fmt.printfln("        lavfi pink noise far, 330 Hz tone near: ERLE %.1f, double talk %.1f, after %.1f", r2.erle_db, r2.dt_echo_removal_db, r2.post_dt_erle_db)
		check(r2.erle_db >= 18, "on ffmpeg's pink noise: %.1f dB of ERLE", r2.erle_db)
		check(r2.dt_echo_removal_db >= 10, "a loud steady tone in double talk is not learnt as echo (%.1f dB)", r2.dt_echo_removal_db)
		check(r2.post_dt_erle_db >= 10, "and the model is intact after it (%.1f dB)", r2.post_dt_erle_db)
	} else {
		fmt.println("  SKIP  ffmpeg could not generate the lavfi sources")
	}
	delete(far)
	delete(near)
}

// lavfi_pcm renders `seconds` of an ffmpeg lavfi source to floats.
lavfi_pcm :: proc(src: string, seconds: int) -> (pcm: []f32, ok: bool) {
	argv := []string{"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", src,
		"-t", fmt.tprintf("%d", seconds), "-f", "s16le", "-ac", "1", "-ar", "48000", "-"}
	c, err := spawn_reader(argv)
	if err != "" {
		return nil, false
	}
	defer child_stop(&c)
	want := seconds * A_RATE * 2
	raw := make([]u8, want)
	defer delete(raw)
	got := 0
	deadline := time.tick_now()
	for got < want {
		n, eof := child_read(&c, raw[got:])
		got += n
		if eof {
			break
		}
		if n == 0 {
			time.sleep(time.Millisecond)
			if time.duration_seconds(time.tick_since(deadline)) > 20 {
				break
			}
		}
	}
	if got < want {
		return nil, false
	}
	pcm = make([]f32, want / 2)
	for i in 0 ..< len(pcm) {
		pcm[i] = f32(i16(u16(raw[2 * i]) | u16(raw[2 * i + 1]) << 8)) / 32768
	}
	return pcm, true
}

// ---------------------------------------------------------------------------
// Adaptive bitrate
// ---------------------------------------------------------------------------

test_rate :: proc() {
	group("adaptive bitrate: the controller, and against an emulated link")

	{
		c: Rate_Ctl
		rate_init(&c, 300)
		check(rate_on_feedback(&c, 1, 0, 290) == .Hold, "clean reports at the ceiling hold")
		check(c.kbps == 300, "at 300 kbit/s")
		check(rate_on_feedback(&c, 2, 0.20, 240) == .Loss, "20 %% loss is a loss decrease")
		check(math.abs(c.kbps - 270) < 0.01, "of loss/2: 300 -> %.0f", c.kbps)
		check(rate_on_feedback(&c, 2.5, 0.20, 240) == .Hold, "and not again within a second")
		// Queueing: the RTT rises 60 ms above the smallest seen.
		rate_on_rtt(&c, 20)
		for _ in 0 ..< 10 {
			rate_on_rtt(&c, 80)
		}
		check(rate_on_feedback(&c, 3.6, 0.0, 200) == .Delay, "a growing RTT is a delay decrease before any loss")
		check(math.abs(c.kbps - 170) < 0.01, "to 0.85 x what arrived: %.0f", c.kbps)
		for _ in 0 ..< 20 {
			rate_on_rtt(&c, 20)
		}
		check(rate_on_feedback(&c, 4.0, 0, 170) == .Hold, "clean again, but it holds for two seconds after a decrease")
		r := rate_on_feedback(&c, 5.7, 0, 170)
		check(r == .Increase, "then it probes upward (%s)", rate_reason_name(r))
		for i in 0 ..< 40 {
			rate_on_feedback(&c, 6 + f64(i) * 0.5, 0, c.kbps)
		}
		check(c.kbps == 300, "and climbs back to the ceiling, never past it (%.0f)", c.kbps)
		for i in 0 ..< 60 {
			rate_on_feedback(&c, 30 + f64(i), 0.5, 10)
		}
		check(c.kbps == RATE_MIN_KBPS, "and never under the floor (%.0f)", c.kbps)
	}
	{
		c: Rate_Ctl
		rate_init(&c, 300)
		c.kbps = 290
		_, apply := rate_should_apply(&c, 10)
		check(!apply, "a 3 %% change does not restart the encoder")
		c.kbps = 200
		k, apply2 := rate_should_apply(&c, 10)
		check(apply2 && k == 200, "a 33 %% drop does (%d)", k)
		c.kbps = 120
		_, apply3 := rate_should_apply(&c, 10.2)
		check(!apply3, "but not twice within half a second")
	}
	{
		s: Seq_Count
		for q in ([]u16{65533, 65534, 65535, 0, 1, 3, 4}) {
			seq_count_push(&s, q)
		}
		e, r := seq_count_window(&s)
		check(e == 8 && r == 7, "loss counting crosses the 16-bit wrap: %d expected, %d received", e, r)
	}

	// The whole loop on an emulated 200 kbit/s bottleneck with a quarter of
	// a second of droptail queue, sender starting at 300.
	fixed := rate_simulate({link_kbps = 200, base_rtt_ms = 20, start_kbps = 300, seconds = 40, adaptive = false})
	adapt := rate_simulate({link_kbps = 200, base_rtt_ms = 20, start_kbps = 300, seconds = 40, adaptive = true})
	fmt.printfln("        200 kbit/s link, last 10 s: fixed %.0f kbit/s, %.1f %% lost, rtt %.0f ms; adaptive %.0f kbit/s, %.1f %% lost, rtt %.0f ms, %d restarts",
		fixed.mean_kbps, fixed.loss_pct, fixed.rtt_ms, adapt.mean_kbps, adapt.loss_pct, adapt.rtt_ms, adapt.restarts)
	check(fixed.loss_pct > 15, "a fixed 300 kbit/s into 200 loses %.1f %% of its packets", fixed.loss_pct)
	check(adapt.loss_pct < 3, "adapting, the loss falls to %.1f %%", adapt.loss_pct)
	check(adapt.mean_kbps >= RATE_MIN_KBPS && adapt.mean_kbps < 200, "video at a rate under the link (%.0f kbit/s)", adapt.mean_kbps)
	check(adapt.goodput_kbps > 0.6 * 200, "and the link still used: %.0f of its 200 kbit/s arrive", adapt.goodput_kbps)
	check(adapt.rtt_ms < fixed.rtt_ms / 2, "with the queue drained: rtt %.0f ms against %.0f", adapt.rtt_ms, fixed.rtt_ms)

	// Random loss injected for 15 s, then none: down, then back.
	inj := rate_simulate({link_kbps = 10000, loss_pct = 15, loss_until = 15, base_rtt_ms = 20, start_kbps = 300, seconds = 45, adaptive = true}, true)
	defer delete(inj.trace)
	at14 := inj.trace[27] // report 28 is t = 14 s
	check(at14 < 200, "15 %% injected loss brings the rate down (%.0f kbit/s at 14 s)", at14)
	check(inj.final_kbps == 300, "and when it stops, the rate recovers to the ceiling (%.0f)", inj.final_kbps)
}

// ---------------------------------------------------------------------------
// End-to-end encryption of the direct call, through a relay
// ---------------------------------------------------------------------------

E2E_A :: 47981
E2E_B :: 47982
E2E_RA :: 47983 // the relay's face toward A
E2E_RB :: 47984 // the relay's face toward B

@(private = "file")
Relay :: struct {
	ra, rb: net.UDP_Socket,
	seen:   [dynamic][]u8, // every datagram that crossed, A to B
	last:   [MAX_PACKET]u8,
	last_n: int,
	// What a man in the middle would do to A's signalling.
	swap_pub: bool,
	mitm:     pcp.Keypair,
}

// relay_pump moves everything waiting in both directions, keeping a copy of
// what A sent.
@(private = "file")
relay_pump :: proc(r: ^Relay) {
	buf: [MAX_PACKET + 64]u8
	for _ in 0 ..< 400 {
		moved := false
		n, _, err := net.recv_udp(r.ra, buf[:])
		if err == nil && n > 0 {
			moved = true
			dg := buf[:n]
			if r.swap_pub {
				h, payload, ok := parse(dg)
				if ok && h.ptype == .Control {
					c, cok := read_control(payload)
					if cok && c.has_pub {
						c.pub = r.mitm.public
						body: [CONTROL_MAX]u8
						out := write_control(body[:], c)
						copy(dg[HDR:], out)
					}
				}
			}
			keep := make([]u8, n)
			copy(keep, dg)
			append(&r.seen, keep)
			copy(r.last[:], dg)
			r.last_n = n
			net.send_udp(r.rb, dg, {LOOPBACK, E2E_B})
		}
		n, _, err = net.recv_udp(r.rb, buf[:])
		if err == nil && n > 0 {
			moved = true
			net.send_udp(r.ra, buf[:n], {LOOPBACK, E2E_A})
		}
		if !moved {
			break
		}
	}
}

// session_pump is pump_receive without an App: control into the state
// machine, media into `got`.
@(private = "file")
session_pump :: proc(s: ^Session, got: ^[dynamic][]u8, v: ^Video = nil) {
	buf: [MAX_PACKET + 64]u8
	for _ in 0 ..< 400 {
		n, _, err := net.recv_udp(s.sock, buf[:])
		if err != nil || n <= 0 {
			break
		}
		h, payload, ok := parse(buf[:n])
		if !ok {
			continue
		}
		switch h.ptype {
		case .Control:
			c, cok := read_control(payload)
			if cok {
				handle_control(s, c, false, false)
			}
		case .Audio_Opus, .Audio_PCM:
			if !media_admit(s, h, n) {
				continue
			}
			pt, opened := e2ee_open(&s.e2ee, h, h.ts_us, payload)
			if opened && got != nil {
				keep := make([]u8, len(pt))
				copy(keep, pt)
				append(got, keep)
			}
		case .Video_JPEG, .Video_H264:
			if !media_admit(s, h, n) {
				continue
			}
			if v != nil {
				frame, ts, done := reasm_push(&v.reasm, h, payload)
				if done {
					pt, opened := e2ee_open(&s.e2ee, h, ts, frame)
					if opened && got != nil {
						keep := make([]u8, len(pt))
						copy(keep, pt)
						append(got, keep)
					}
				}
			}
		}
	}
}

@(private = "file")
settle :: proc(r: ^Relay, a, b: ^Session, got: ^[dynamic][]u8, v: ^Video = nil) {
	for _ in 0 ..< 20 {
		time.sleep(2 * time.Millisecond)
		relay_pump(r)
		time.sleep(1 * time.Millisecond)
		session_pump(b, got, v)
		session_pump(a, nil)
	}
}

test_e2ee_direct :: proc() {
	group("direct call end-to-end encryption, through a relay that reads everything")

	a, b: Session
	if e := session_open(&a, E2E_A, E2E_RA, "Alice"); e != "" {
		fmt.printfln("  SKIP  %s", e)
		return
	}
	defer session_close(&a)
	if e := session_open(&b, E2E_B, E2E_RB, "Bob"); e != "" {
		fmt.printfln("  SKIP  %s", e)
		return
	}
	defer session_close(&b)
	r: Relay
	ra, e1 := net.make_bound_udp_socket(LOOPBACK, E2E_RA)
	rb, e2 := net.make_bound_udp_socket(LOOPBACK, E2E_RB)
	if e1 != nil || e2 != nil {
		fmt.println("  SKIP  cannot bind the relay")
		return
	}
	net.set_blocking(ra, false)
	net.set_blocking(rb, false)
	r.ra, r.rb = ra, rb
	defer {
		net.close(ra)
		net.close(rb)
		for d in r.seen {
			delete(d)
		}
		delete(r.seen)
	}
	got: [dynamic][]u8
	defer {
		for g in got {
			delete(g)
		}
		delete(got)
	}

	check(a.e2ee.required && b.e2ee.required, "both ends require encryption by default")

	// Before any key: media is held back, not sent in the clear.
	secret := "the quick brown fox says the launch code is 0000"
	send_media(&a, .Audio_Opus, transmute([]u8)secret, now_us())
	check_eq_int(a.e2ee.tx_no_key, 1, "a frame with no peer key yet is held back")
	check_eq_int(a.tx_packets, 0, "and nothing was sent")

	dial(&a, false, false)
	settle(&r, &a, &b, &got)
	check(b.state == .Ringing, "Bob's phone rings (%v)", b.state)
	accept_call(&b, false, false)
	settle(&r, &a, &b, &got)
	check(a.state == .Connecting && b.state == .Connecting, "both are connecting (%v, %v)", a.state, b.state)
	check(e2ee_ready(&a.e2ee) && e2ee_ready(&b.e2ee), "both have keys, from the INVITE and the ACCEPT")
	check(a.e2ee.safety != "" && a.e2ee.safety == b.e2ee.safety, "and the same safety code (%s)", a.e2ee.safety)
	check(a.e2ee.kp.public != b.e2ee.kp.public, "from two different keypairs")

	// One audio frame, across the relay.
	got_before := len(got)
	seen_before := len(r.seen)
	send_media(&a, .Audio_Opus, transmute([]u8)secret, now_us())
	settle(&r, &a, &b, &got)
	check(len(got) == got_before + 1 && string(got[len(got) - 1]) == secret, "Bob opens Alice's frame")
	leaked := false
	flagged := 0
	for d in r.seen[seen_before:] {
		if bytes_contains(d, transmute([]u8)secret) || bytes_contains(d, transmute([]u8)secret[:12]) {
			leaked = true
		}
		h, _, ok := parse(d)
		if ok && h.ptype != .Control && h.flags & FLAG_E2EE != 0 {
			flagged += 1
		}
	}
	check(!leaked, "no byte the relay saw contains the plaintext, nor its first 12 bytes")
	check_eq_int(flagged, 1, "what crossed is flagged as SFrame ciphertext")

	// A passive observer with a key of its own opens nothing.
	{
		eve := pcp.keypair_generate()
		k: pcp.Sframe_Key
		shared: [32]u8
		pub := a.e2ee.kp.public
		_ = x25519_shared(shared[:], eve.secret[:], pub[:])
		base := e2ee_derive(shared[:], pub[:], eve.public[:])
		pcp.sframe_key_init(&k, E2EE_KID, base[:])
		defer pcp.sframe_key_clear(&k)
		h, payload, _ := parse(r.last[:r.last_n])
		md: [16]u8
		out := make([]u8, len(payload))
		defer delete(out)
		_, err := pcp.sframe_open(&k, e2ee_metadata(md[:], h.ptype, keyframed(h), h.ts_us, h.frame), payload, out)
		check(err == .Auth, "an observer's own key fails authentication (%v)", err)
	}

	// Replay: the relay sends the same datagram again.
	{
		before := b.e2ee.rx_replay
		net.send_udp(r.rb, r.last[:r.last_n], {LOOPBACK, E2E_B})
		settle(&r, &a, &b, &got)
		check_eq_int(b.e2ee.rx_replay - before, 1, "a replayed frame is refused by the window")
	}
	// Tampering: one ciphertext byte; the keyframe bit; the timestamp.
	tamper := []struct {
		what: string,
		at:   int,
		bit:  u8,
	}{{"a flipped ciphertext byte", HDR + 4, 0x01}, {"a keyframe bit set in flight", 5, FLAG_KEYFRAME}, {"a rewritten capture timestamp", 15, 0x40}}
	for t in tamper {
		send_media(&a, .Audio_Opus, transmute([]u8)secret, now_us())
		time.sleep(2 * time.Millisecond)
		buf: [MAX_PACKET + 64]u8
		n, _, err := net.recv_udp(r.ra, buf[:])
		if err != nil || n <= 0 {
			check(false, "the relay received the frame to tamper with")
			continue
		}
		buf[t.at] ~= t.bit
		before := b.e2ee.rx_auth
		opened := b.e2ee.opened
		net.send_udp(r.rb, buf[:n], {LOOPBACK, E2E_B})
		settle(&r, &a, &b, &got)
		check(b.e2ee.rx_auth == before + 1 && b.e2ee.opened == opened, "%s fails authentication and plays nothing", t.what)
	}
	// Injection in the clear.
	{
		before := b.e2ee.rx_clear
		out: [MAX_PACKET]u8
		dg := fragment_into(out[:], transmute([]u8)secret, 0, .Audio_Opus, 999, now_us(), 999, 0)
		net.send_udp(r.rb, dg, {LOOPBACK, E2E_B})
		settle(&r, &a, &b, &got)
		check_eq_int(b.e2ee.rx_clear - before, 1, "a clear frame injected into the call is refused")
	}
	// A video frame cut into five fragments reassembles, then opens.
	{
		v: Video
		video_init(&v)
		defer video_destroy(&v)
		frame := known_pattern(5000)
		defer delete(frame)
		n0 := len(got)
		send_media(&a, .Video_H264, frame, now_us(), FLAG_KEYFRAME)
		settle(&r, &a, &b, &got, &v)
		ok := len(got) == n0 + 1 && len(got[n0]) == 5000
		if ok {
			for x, i in got[n0] {
				if x != frame[i] {
					ok = false
				}
			}
		}
		check(ok, "a 5000-byte video frame in %d fragments reassembles and opens byte for byte", fragment_count(5000 + E2EE_OVERHEAD))
	}
	// The key is pinned for the call.
	{
		changes := b.e2ee.peer_key_changes_ignored
		rx := b.e2ee.rx
		other := pcp.keypair_generate()
		c := Control{kind = .State, name = "Alice", codecs = CODEC_ALL, has_pub = true, pub = other.public}
		handle_control(&b, c, false, false)
		check(b.e2ee.peer_key_changes_ignored == changes + 1 && b.e2ee.rx == rx, "a different key mid-call is ignored, not adopted")
	}
	// A new call is a new keypair.
	{
		old := a.e2ee.kp.public
		hang_up(&a)
		check(a.e2ee.kp.public != old && !e2ee_ready(&a.e2ee), "hanging up discards the call's keys; the next call has a fresh keypair")
	}

	// The man in the middle: the relay swaps Alice's key for its own on the
	// way to Bob. Media then would be readable by the relay, and the safety
	// codes are how a person finds out.
	{
		settle(&r, &a, &b, &got)
		reset_call(&a)
		reset_call(&b)
		r.swap_pub = true
		r.mitm = pcp.keypair_generate()
		dial(&a, false, false)
		settle(&r, &a, &b, &got)
		accept_call(&b, false, false)
		settle(&r, &a, &b, &got)
		check(b.e2ee.peer_pub == r.mitm.public, "with keys substituted in flight, Bob is keyed to the attacker")
		check(a.e2ee.safety != "" && b.e2ee.safety != "" && a.e2ee.safety != b.e2ee.safety, "and the two safety codes differ (%s / %s)", a.e2ee.safety, b.e2ee.safety)
	}
}

x25519_shared :: proc(dst, secret, pub: []u8) -> bool {
	x25519.scalarmult(dst, secret, pub)
	return true
}

known_pattern :: proc(n: int) -> []u8 {
	b := make([]u8, n)
	for i in 0 ..< n {
		b[i] = u8(i * 17 + (i >> 8) * 3 + 1)
	}
	return b
}

// ---------------------------------------------------------------------------
// The control extensions on the wire
// ---------------------------------------------------------------------------

test_control_ext :: proc() {
	group("control extensions: public key and receiver report")
	out: [CONTROL_MAX]u8
	kp := pcp.keypair_generate()
	c := Control{kind = .Feedback, name = "Alice", codecs = CODEC_ALL, has_pub = true, pub = kp.public, has_fb = true}
	c.fb = {loss_permille = 123, recv_kbps = 456, echo_ts = 0x0102030405060708, hold_us = 98765}
	b := write_control(out[:], c)
	got, ok := read_control(b)
	check(ok && got.kind == .Feedback && got.name == "Alice" && got.codecs == CODEC_ALL, "a FEEDBACK with both extensions round trips")
	check(got.has_pub && got.pub == kp.public, "the public key survives")
	check(got.has_fb && got.fb == c.fb, "the report survives")
	plain := write_control(out[:], {kind = .State, name = "Bob", codecs = CODEC_H264})
	check(len(plain) == 5 + 3, "a message with no extensions is exactly the old message (%d bytes)", len(plain))
	// An unknown extension is skipped by length; one that runs off the end
	// is refused.
	ext: [32]u8
	base := write_control(ext[:], {kind = .State, name = "Bob", codecs = CODEC_H264})
	n := len(base)
	ext[n], ext[n + 1], ext[n + 2], ext[n + 3] = 99, 2, 0xAA, 0xBB
	g2, ok2 := read_control(ext[:n + 4])
	check(ok2 && !g2.has_pub && g2.codecs == CODEC_H264, "an unknown extension is skipped")
	ext[n + 1] = 9
	_, ok3 := read_control(ext[:n + 4])
	check(!ok3, "an extension that claims more bytes than there are is refused")
	_ = os.args
}
