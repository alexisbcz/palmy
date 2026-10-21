package call

// ---------------------------------------------------------------------------
// Acoustic echo cancellation, in process, with no library.
//
// THE DECISION, written down because the brief asks for one: this file is the
// echo canceller, rather than speexdsp or WebRTC's AEC3.
//
//  - The project prefers no dependencies, and this one would be the first C++
//    dependency in the tree: AEC3 lives in webrtc-audio-processing, which has
//    no C API, so it would need a C shim compiled and shipped beside the
//    binary. speexdsp has a C API, and its echo canceller is the design this
//    file follows (a multidelay block frequency-domain filter, Valin 2007),
//    but linking it to get ~600 lines of arithmetic is a poor trade.
//  - It has to be measurable here, on synthetic signals, with no microphone:
//    an in-process canceller can be fed a synthetic echo path sample-exactly
//    and scored (ERLE, in dB) in the self-test, which a PipeWire module in
//    another process cannot be.
//  - `--echo-cancel`, the PipeWire route to AEC3 through module-echo-cancel,
//    is kept. On real hardware with real loudspeakers AEC3's residual echo
//    suppressor and delay estimator are better than anything here, and the
//    flag costs nothing. The two are alternatives, not layers: `--aec` runs
//    this one, `--echo-cancel` asks the system's.
//
// THE ALGORITHM. A partitioned-block frequency-domain adaptive filter (PBFDAF,
// also called MDF), overlap-save, block N = 256 samples (5.3 ms at 48 kHz),
// FFT 2N, `parts` partitions — 32 by default, a 170 ms tail, which covers the
// player's queue plus a room. Per block:
//
//	X_k   far-end spectrum, k blocks ago (a ring of `parts`)
//	Y     = sum_k W_k X_k             echo estimate; y = last N of IFFT(Y)
//	e     = d - y                     the microphone with the echo removed
//	W_k  += mu(f) K prop_k conj(X_k) E / (sum_k |X_k|^2 + delta)
//
// — normalised LMS, with a per-partition share `prop_k` (proportionate, so
// the step goes where the echo is) and a per-bin step mu(f), and with the
// gradient constraint (zero the second half of w_k in time) applied to one
// partition per block in turn, as speex's AUMDF does.
//
// Double talk — both ends speaking at once — is what wrecks an adaptive
// filter: the near-end voice looks like an error, and adapting on it
// destroys the echo model. Two defences, both speex's, neither a
// double-talk *detector*:
//  - the step mu(f) is the estimated fraction of each bin's error that is
//    residual echo (Valin 2007), so it collapses when the error is mostly a
//    voice;
//  - two paths: a background filter adapts, a foreground filter produces the
//    output, and the background is promoted only when it is *significantly*
//    better — a reduction large against its own variance, which rises when
//    the near end talks. A background that drifts far is reset from the
//    foreground, the last model known to be good.
//
// WHAT IT DOES NOT DO, stated: no residual echo suppressor (non-linear
// processing), so residual echo is whatever the linear filter leaves — fine
// for a linear echo path, audible on a loudspeaker driven into distortion; no
// delay estimator, so a bulk delay longer than the tail is not cancelled; no
// clock-drift compensation between capture and playout, which matters only on
// real devices. Real devices are not opened in any measurement here, by rule,
// so its behaviour on a real room is untested; the synthetic echo path below
// is what it is measured on (`call aec`, and the self-test).
// ---------------------------------------------------------------------------

import "core:math"
import "core:math/rand"

AEC_N :: 256 // block, samples
AEC_M :: 2 * AEC_N // FFT size
AEC_B :: AEC_N + 1 // bins kept: a real signal's spectrum is Hermitian
AEC_PARTS :: 32 // 32 * 5.33 ms = 170 ms of tail

// The adaptive step's constants are speex's (mdf.c), in its units.
AEC_SPEC_AVG :: f32(f32(AEC_N) / f32(A_RATE))
AEC_BETA0 :: f32(2 * f32(AEC_N) / f32(A_RATE))
AEC_BETA_MAX :: f32(0.5 * f32(AEC_N) / f32(A_RATE))
AEC_MIN_LEAK :: f32(0.005)
AEC_PREEMPH :: f32(0.9)

// AEC_STEP_SCALE multiplies speex's step. Measured with `call aec` over five
// scenarios (the default room; a 90 ms delay with a 60 ms room; a -20 dB
// echo; a -50 dBFS noise floor; ffmpeg lavfi pink noise against a 330 Hz
// tone), as worst-case echo removal during double talk / ERLE after it:
//
//	x1.0   8.7 / 13.0      x1.4   2.5 / 8.5      x2.0   7.8 / 12.9
//	x3.0   14.1 / 11.0, but 3 dB less ERLE in the default room (22.1 vs 24.8)
//
// and for comparison a *fixed* step of 0.7, which is better on speech-like
// signals and collapses on a stationary near end: -2.6 / 1.3 against the
// tone. x2 is the choice.
AEC_STEP_SCALE :: f32(2.0)

// ---------------------------------------------------------------------------
// A radix-2 FFT, complex, in place. Small and plain: one size per instance,
// twiddles and the bit-reversal table precomputed.
// ---------------------------------------------------------------------------

Fft :: struct {
	n:   int,
	tw:  []complex64, // exp(-2 pi i k / n), k < n/2
	rev: []u32,
}

fft_make :: proc(n: int) -> (f: Fft) {
	assert(n >= 2 && n & (n - 1) == 0, "fft size must be a power of two")
	f.n = n
	f.tw = make([]complex64, n / 2)
	for k in 0 ..< n / 2 {
		a := -2 * math.PI * f64(k) / f64(n)
		f.tw[k] = complex(f32(math.cos(a)), f32(math.sin(a)))
	}
	f.rev = make([]u32, n)
	bits := 0
	for (1 << uint(bits)) < n {
		bits += 1
	}
	for i in 0 ..< n {
		r: u32
		for b in 0 ..< bits {
			if i & (1 << uint(b)) != 0 {
				r |= 1 << uint(bits - 1 - b)
			}
		}
		f.rev[i] = r
	}
	return
}

fft_destroy :: proc(f: ^Fft) {
	delete(f.tw)
	delete(f.rev)
	f^ = {}
}

// fft_forward is the unscaled DFT.
fft_forward :: proc(f: ^Fft, x: []complex64) {
	n := f.n
	for i in 0 ..< n {
		j := int(f.rev[i])
		if j > i {
			x[i], x[j] = x[j], x[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		half := size / 2
		step := n / size
		for start := 0; start < n; start += size {
			for j in 0 ..< half {
				t := f.tw[j * step] * x[start + j + half]
				u := x[start + j]
				x[start + j] = u + t
				x[start + j + half] = u - t
			}
		}
	}
}

// fft_inverse is the inverse DFT, scaled by 1/n so forward then inverse is the
// identity.
fft_inverse :: proc(f: ^Fft, x: []complex64) {
	for i in 0 ..< f.n {
		x[i] = conj(x[i])
	}
	fft_forward(f, x)
	s := 1 / f32(f.n)
	for i in 0 ..< f.n {
		x[i] = conj(x[i]) * complex(s, 0)
	}
}

// ---------------------------------------------------------------------------
// The canceller
// ---------------------------------------------------------------------------

Aec :: struct {
	parts: int,
	fft:   Fft,

	// Far-end spectra, a ring of `parts` blocks of AEC_B bins; partition k
	// (0 = newest) is slot (head - k) mod parts.
	X:     []complex64,
	head:  int,
	Wf:    []complex64, // foreground: what the output is made with
	Wb:    []complex64, // background: what adapts
	norm:  [AEC_B]f32,
	prop:  [128]f32, // per-partition step share; parts <= 128
	x_prev: [AEC_N]f32,
	cidx:  int, // which partition gets the constraint this block

	// Smoothed error energies of the two paths.
	sf, sb, sd: f32,
	davg1, davg2, dvar1, dvar2: f32, // the foreground-update statistics

	pre_x, pre_d, de_e: f32, // emphasis filter state

	// The adaptive step (see aec_block, step 3).
	eh, yh, rf, yf, step: [AEC_B]f32,
	pey, pyy, leak: f32,
	adapted:   bool,
	sum_adapt: f32,

	// The frame interface: blocks of 256 under frames of 960.
	fx, fd: [AEC_N]f32,
	fill:   int,
	outq:   [4 * AEC_N + A_FRAME_SAMPLES]f32,
	out_r, out_n: int,

	work, work2: [AEC_M]complex64,

	enabled: bool,

	// Counters, for the statistics panel and the measurement.
	blocks: int,
	copies: int, // background promoted to foreground
	resets: int, // background reset from foreground (it diverged)
}

aec_init :: proc(a: ^Aec, parts := AEC_PARTS) {
	aec_destroy(a)
	parts := clamp(parts, 1, 128)
	a.parts = parts
	a.fft = fft_make(AEC_M)
	a.X = make([]complex64, parts * AEC_B)
	a.Wf = make([]complex64, parts * AEC_B)
	a.Wb = make([]complex64, parts * AEC_B)
	// The frame interface has one block of latency: prime the output queue
	// with it, so every frame call can hand back a whole frame.
	a.out_r = 0
	a.out_n = AEC_N
	a.enabled = true
}

aec_destroy :: proc(a: ^Aec) {
	if a.parts == 0 {
		return
	}
	fft_destroy(&a.fft)
	delete(a.X)
	delete(a.Wf)
	delete(a.Wb)
	a^ = {}
}

aec_tail_ms :: proc(a: ^Aec) -> f32 {
	return f32(a.parts * AEC_N) * 1000 / f32(A_RATE)
}

@(private = "file")
part_slot :: proc(a: ^Aec, k: int) -> []complex64 {
	s := (a.head - k + a.parts) % a.parts
	return a.X[s * AEC_B:(s + 1) * AEC_B]
}

// mirror fills bins N+1..2N-1 of a Hermitian spectrum from bins 1..N-1.
@(private = "file")
mirror :: proc(x: []complex64) {
	for k in 1 ..< AEC_N {
		x[AEC_M - k] = conj(x[k])
	}
}

// echo_estimate writes y = last N samples of IFFT(sum_k W_k X_k) into `y`.
@(private = "file")
echo_estimate :: proc(a: ^Aec, W: []complex64, y: []f32) {
	acc := a.work[:]
	for i in 0 ..< AEC_M {
		acc[i] = 0
	}
	for k in 0 ..< a.parts {
		xk := part_slot(a, k)
		wk := W[k * AEC_B:(k + 1) * AEC_B]
		for i in 0 ..< AEC_B {
			acc[i] += wk[i] * xk[i]
		}
	}
	mirror(acc)
	fft_inverse(&a.fft, acc)
	for i in 0 ..< AEC_N {
		y[i] = real(acc[AEC_N + i])
	}
}

// aec_block cancels one block: `x` is the far end (what was played), `d` the
// microphone, and `e` receives the microphone with the echo removed. `x`, `d`
// and `e` are AEC_N samples, floats in -1..1.
//
// Inside, samples are on the 16-bit scale (x 32768), so the constants that
// follow speex's — energy floors of "1", "10", "1000" — mean what they mean
// there.
aec_block :: proc(a: ^Aec, x_in, d_in, e: []f32) {
	a.blocks += 1
	// Pre-emphasis, as speex: a first difference on both signals, undone on
	// the output. The canceller is linear, so cancelling the emphasised
	// echo cancels the echo — but the emphasised spectra are flatter, so a
	// loud low-frequency voice dominates the error less and the step stays
	// honest across the band.
	x, d: [AEC_N]f32
	for i in 0 ..< AEC_N {
		xv := x_in[i] * 32768
		dv := d_in[i] * 32768
		x[i] = xv - AEC_PREEMPH * a.pre_x
		d[i] = dv - AEC_PREEMPH * a.pre_d
		a.pre_x, a.pre_d = xv, dv
	}
	defer for i in 0 ..< AEC_N {
		v := e[i] + AEC_PREEMPH * a.de_e
		a.de_e = v
		e[i] = v / 32768
	}

	// 1. The newest far-end spectrum, from [previous block, this block].
	{
		buf := a.work[:]
		for i in 0 ..< AEC_N {
			buf[i] = complex(a.x_prev[i], 0)
			buf[AEC_N + i] = complex(x[i], 0)
		}
		fft_forward(&a.fft, buf)
		a.head = (a.head + 1) % a.parts
		dst := part_slot(a, 0)
		copy(dst, buf[:AEC_B])
		copy(a.x_prev[:], x[:AEC_N])
	}
	// The normaliser: far-end power per bin over the whole tail.
	mean: f32
	for i in 0 ..< AEC_B {
		a.norm[i] = 0
	}
	for k in 0 ..< a.parts {
		xk := part_slot(a, k)
		for i in 0 ..< AEC_B {
			v := xk[i]
			a.norm[i] += real(v) * real(v) + imag(v) * imag(v)
		}
	}
	for i in 0 ..< AEC_B {
		mean += a.norm[i]
	}
	mean /= AEC_B
	// A floor at -70 dBFS-ish of white noise over the tail, plus a fraction
	// of the mean so a spectral hole in the far end does not divide by ~0.
	delta := f32(a.parts) * AEC_M * 107 + mean * 0.01

	// 2. Both paths' echo estimates and errors.
	yf, yb, eb: [AEC_N]f32
	echo_estimate(a, a.Wf, yf[:])
	echo_estimate(a, a.Wb, yb[:])
	ef_en, eb_en, d_en: f32
	for i in 0 ..< AEC_N {
		d_en += d[i] * d[i]
		e[i] = d[i] - yf[i]
		eb[i] = d[i] - yb[i]
		ef_en += e[i] * e[i]
		eb_en += eb[i] * eb[i]
	}

	// 3. Adapt the background, proportionately:
	//
	//	W_k += mu * K * prop_k * conj(X_k) E / (sum_k |X_k|^2 + delta)
	//
	// prop_k is speex's "proportionate" weighting (after IPNLMS): each
	// partition's share of the step follows its share of the filter's
	// energy, plus a floor of a tenth of the largest so an empty partition
	// can still grow. An echo path is mostly a bulk delay followed by a
	// room, so most partitions are empty, and spending the step where the
	// echo actually is converges several times faster than a uniform one.
	// With a uniform prop (sum 0.99) this is plain normalised LMS.
	{
		prop := a.prop[:a.parts]
		mx: f32
		for k in 0 ..< a.parts {
			wk := a.Wb[k * AEC_B:(k + 1) * AEC_B]
			acc: f32
			for i in 0 ..< AEC_B {
				acc += real(wk[i]) * real(wk[i]) + imag(wk[i]) * imag(wk[i])
			}
			prop[k] = math.sqrt(acc)
			mx = max(mx, prop[k])
		}
		mx = max(mx, 1e-9)
		total: f32
		for k in 0 ..< a.parts {
			prop[k] += 0.1 * mx
			total += prop[k]
		}
		for k in 0 ..< a.parts {
			prop[k] = 0.99 * prop[k] / total * f32(a.parts)
		}

		// The step, per bin. This is speex's (Valin, "On adjusting the
		// learning rate in frequency domain echo cancellation with double
		// talk", 2007): the right step for a bin is the fraction of its error
		// that is *residual echo* — near 1 while the filter is far off, near
		// 0 when the error is mostly the near end talking. Residual echo is
		// estimated as leak * |Y|^2, where `leak` is how much of the echo
		// estimate's power still shows up in the error, found by regressing
		// the error's spectral fluctuations on the estimate's. During double
		// talk the error is dominated by the voice, so the step collapses and
		// the background cannot learn the voice. A fixed step cannot do that,
		// and measurably did not: with a fixed 0.7 a loud stationary near end
		// (a 330 Hz tone over a pink far end) was half-learnt within 100 ms
		// and echo removal during double talk fell to -3 dB.
		E := a.work[:]
		for i in 0 ..< AEC_N {
			E[i] = 0
			E[AEC_N + i] = complex(eb[i], 0)
		}
		fft_forward(&a.fft, E)
		Y := a.work2[:]
		for i in 0 ..< AEC_N {
			Y[i] = 0
			Y[AEC_N + i] = complex(yb[i], 0)
		}
		fft_forward(&a.fft, Y)
		sxx, syy, see, sey: f32
		for i in 0 ..< AEC_N {
			sxx += x[i] * x[i]
			syy += yb[i] * yb[i]
			see += eb[i] * eb[i]
			sey += eb[i] * yb[i]
		}
		see = max(see, 1)
		x0 := part_slot(a, 0)
		pey_b, pyy_b: f32
		for i in 0 ..< AEC_B {
			rf := real(E[i]) * real(E[i]) + imag(E[i]) * imag(E[i])
			yf := real(Y[i]) * real(Y[i]) + imag(Y[i]) * imag(Y[i])
			a.rf[i] = rf
			a.yf[i] = yf
			eh := rf - a.eh[i]
			yh := yf - a.yh[i]
			pey_b += eh * yh
			pyy_b += yh * yh
			a.eh[i] = (1 - AEC_SPEC_AVG) * a.eh[i] + AEC_SPEC_AVG * rf
			a.yh[i] = (1 - AEC_SPEC_AVG) * a.yh[i] + AEC_SPEC_AVG * yf
			xf := real(x0[i]) * real(x0[i]) + imag(x0[i]) * imag(x0[i])
			_ = xf
		}
		pyy_b = math.sqrt(pyy_b)
		if pyy_b > 0 {
			pey_b /= pyy_b
		}
		alpha := min(AEC_BETA0 * syy, AEC_BETA_MAX * see) / see
		a.pey = (1 - alpha) * a.pey + alpha * pey_b
		a.pyy = (1 - alpha) * a.pyy + alpha * pyy_b
		a.pyy = max(a.pyy, 1)
		a.pey = clamp(a.pey, AEC_MIN_LEAK * a.pyy, a.pyy)
		a.leak = a.pey / a.pyy
		rer := (0.0001 * sxx + 3 * a.leak * syy) / see
		rer = max(rer, sey * sey / (1 + see * syy))
		rer = min(rer, 0.5)
		if !a.adapted && a.sum_adapt > f32(a.parts) && a.leak > 0.03 {
			a.adapted = true
		}
		step := a.step[:]
		if a.adapted {
			for i in 0 ..< AEC_B {
				ee := a.rf[i] + 1
				r := min(a.leak * a.yf[i], ee / 2)
				r = 0.7 * r + 0.3 * rer * ee
				step[i] = AEC_STEP_SCALE * r / ee
			}
		} else {
			// Before the filter is any good the leak cannot be estimated, so
			// the step follows how loud the far end is against the error.
			rate: f32
			if sxx > AEC_N * 1000 {
				rate = min(0.25 * sxx, see / 4) / see
			}
			a.sum_adapt += rate
			for i in 0 ..< AEC_B {
				step[i] = AEC_STEP_SCALE * rate
			}
		}
		for i in 0 ..< AEC_B {
			E[i] *= complex(step[i] / (a.norm[i] + delta), 0)
		}
		for k in 0 ..< a.parts {
			xk := part_slot(a, k)
			wk := a.Wb[k * AEC_B:(k + 1) * AEC_B]
			pk := complex(prop[k], 0)
			for i in 0 ..< AEC_B {
				wk[i] += pk * conj(xk[i]) * E[i]
			}
		}
	}
	// The gradient constraint, on one partition per block: an unconstrained
	// frequency-domain filter is a circular convolution, and the half of its
	// impulse response that wraps around is error.
	{
		k := a.cidx
		a.cidx = (a.cidx + 1) % a.parts
		wk := a.Wb[k * AEC_B:(k + 1) * AEC_B]
		w := a.work2[:]
		copy(w[:AEC_B], wk)
		mirror(w)
		fft_inverse(&a.fft, w)
		for i in 0 ..< AEC_N {
			w[i] = complex(real(w[i]), 0)
			w[AEC_N + i] = 0
		}
		fft_forward(&a.fft, w)
		copy(wk, w[:AEC_B])
	}

	// 4. Two paths: is the background *significantly* better than the
	// foreground? This is speex's test, and its point is the word
	// "significantly". A plain comparison of error energies is fooled by
	// double talk: an adaptive filter with 170 ms of taps can always shave a
	// little off a loud near-end voice by fitting noise, so the background
	// "wins" and the foreground is overwritten by a model of the wrong thing.
	// Here the reduction (Sff - See) must be large against its own spread,
	// estimated as Sff * Dbf (Dbf: energy of the difference between the two
	// outputs) — and while the near end talks, Sff is large, so the bar rises
	// exactly when it should. Checked on this block and on two smoothed
	// windows, so a consistent small gain counts as well as a sudden one.
	a.sf = a.sf * 0.875 + ef_en * 0.125
	a.sb = a.sb * 0.875 + eb_en * 0.125
	a.sd = a.sd * 0.875 + d_en * 0.125
	dbf: f32
	for i in 0 ..< AEC_N {
		df := e[i] - eb[i]
		dbf += df * df
	}
	diff := ef_en - eb_en
	a.davg1 = 0.6 * a.davg1 + 0.4 * diff
	a.davg2 = 0.85 * a.davg2 + 0.15 * diff
	a.dvar1 = 0.36 * a.dvar1 + 0.16 * ef_en * dbf
	a.dvar2 = 0.7225 * a.dvar2 + 0.0225 * ef_en * dbf
	update := diff * math.abs(diff) > ef_en * dbf ||
		a.davg1 * math.abs(a.davg1) > 0.5 * a.dvar1 ||
		a.davg2 * math.abs(a.davg2) > 0.25 * a.dvar2
	if update {
		// The background is the better model of the echo: it becomes the one
		// that cancels, and this block's output is remade with it.
		copy(a.Wf, a.Wb)
		for i in 0 ..< AEC_N {
			e[i] = eb[i]
		}
		a.sf = a.sb
		a.davg1, a.davg2, a.dvar1, a.dvar2 = 0, 0, 0, 0
		a.copies += 1
	} else if -diff * math.abs(diff) > 4 * ef_en * dbf {
		// The background is significantly *worse*: it has drifted (double
		// talk, usually). Start it again from the model that works.
		copy(a.Wb, a.Wf)
		a.sb = a.sf
		a.davg1, a.davg2, a.dvar1, a.dvar2 = 0, 0, 0, 0
		a.resets += 1
	}
}

// aec_frame runs a 20 ms frame through the canceller: `mic` and `far` are
// A_FRAME_SAMPLES each, `out` receives the cancelled microphone. The output is
// one block (5.3 ms) behind the input, which is the cost of the block size.
aec_frame :: proc(a: ^Aec, mic, far, out: []f32) {
	for i in 0 ..< len(mic) {
		a.fd[a.fill] = mic[i]
		a.fx[a.fill] = far[i]
		a.fill += 1
		if a.fill == AEC_N {
			a.fill = 0
			e: [AEC_N]f32
			if a.enabled {
				aec_block(a, a.fx[:], a.fd[:], e[:])
			} else {
				copy(e[:], a.fd[:])
			}
			for s in e {
				w := (a.out_r + a.out_n) % len(a.outq)
				a.outq[w] = s
				a.out_n += 1
			}
		}
	}
	for i in 0 ..< len(out) {
		if a.out_n > 0 {
			out[i] = a.outq[a.out_r]
			a.out_r = (a.out_r + 1) % len(a.outq)
			a.out_n -= 1
		} else {
			out[i] = 0
		}
	}
}

// ---------------------------------------------------------------------------
// A synthetic echo path: what a loudspeaker, a room and a microphone do to the
// far end's voice, minus everything non-linear. A bulk delay (the player's
// queue, the converters, the air), then a decaying random impulse response
// (the room), scaled to an overall echo gain.
// ---------------------------------------------------------------------------

Echo_Path :: struct {
	delay:   int, // samples
	taps:    []f32, // the room, after the delay
	gain_db: f32,

	// The convolution runs the same way the canceller's filter does —
	// partitioned, in the frequency domain, overlap-save — because a direct
	// convolution of 3,000 taps at 48 kHz is 150 M multiply-adds a second,
	// which an unoptimised build cannot do in real time. This one is exact.
	fft:    Fft,
	parts:  int,
	H:      []complex64, // parts * AEC_B
	X:      []complex64,
	head:   int,
	x_prev: [AEC_N]f32,
	work:   [AEC_M]complex64,
	// The frame interface (echo_path_run): one block of latency, like the
	// canceller's — part of the room's delay, as far as anyone can tell.
	fin:    [AEC_N]f32,
	fill:   int,
	outq:   [4 * AEC_N + A_FRAME_SAMPLES]f32,
	out_r, out_n: int,
}

// echo_path_make builds a room: `delay_ms` of bulk delay, then `room_ms` of
// impulse response decaying by 60 dB across it, with energy gain `gain_db`.
echo_path_make :: proc(delay_ms, room_ms, gain_db: f32, seed: u64) -> (p: Echo_Path) {
	p.delay = int(delay_ms * f32(A_RATE) / 1000)
	n := max(1, int(room_ms * f32(A_RATE) / 1000))
	p.taps = make([]f32, n)
	p.gain_db = gain_db
	r := rand.create(seed)
	gen := rand.default_random_generator(&r)
	tau := f32(n) / 6.9 // e^(-n/tau) = -60 dB
	energy: f32
	for i in 0 ..< n {
		g := f32(rand.norm_float64(gen))
		env := math.exp(-f32(i) / tau)
		p.taps[i] = g * env
		if i == 0 {
			p.taps[i] = 2.5 * env // the direct path
		}
		energy += p.taps[i] * p.taps[i]
	}
	scale := math.pow(10, gain_db / 20) / math.sqrt(energy)
	for i in 0 ..< n {
		p.taps[i] *= scale
	}

	total := p.delay + n
	p.parts = (total + AEC_N - 1) / AEC_N
	p.fft = fft_make(AEC_M)
	p.H = make([]complex64, p.parts * AEC_B)
	p.X = make([]complex64, p.parts * AEC_B)
	for k in 0 ..< p.parts {
		for i in 0 ..< AEC_M {
			p.work[i] = 0
		}
		for i in 0 ..< AEC_N {
			t := k * AEC_N + i - p.delay
			if t >= 0 && t < n {
				p.work[i] = complex(p.taps[t], 0)
			}
		}
		fft_forward(&p.fft, p.work[:])
		copy(p.H[k * AEC_B:(k + 1) * AEC_B], p.work[:AEC_B])
	}
	p.out_n = AEC_N
	return
}

echo_path_destroy :: proc(p: ^Echo_Path) {
	if p.parts == 0 {
		return
	}
	delete(p.taps)
	delete(p.H)
	delete(p.X)
	fft_destroy(&p.fft)
	p^ = {}
}

// echo_path_block convolves one block of AEC_N samples, exactly, with no
// latency of its own.
echo_path_block :: proc(p: ^Echo_Path, x, y: []f32) {
	for i in 0 ..< AEC_N {
		p.work[i] = complex(p.x_prev[i], 0)
		p.work[AEC_N + i] = complex(x[i], 0)
	}
	fft_forward(&p.fft, p.work[:])
	p.head = (p.head + 1) % p.parts
	copy(p.X[p.head * AEC_B:(p.head + 1) * AEC_B], p.work[:AEC_B])
	copy(p.x_prev[:], x[:AEC_N])
	for i in 0 ..< AEC_M {
		p.work[i] = 0
	}
	for k in 0 ..< p.parts {
		s := (p.head - k + p.parts) % p.parts
		xk := p.X[s * AEC_B:(s + 1) * AEC_B]
		hk := p.H[k * AEC_B:(k + 1) * AEC_B]
		for i in 0 ..< AEC_B {
			p.work[i] += hk[i] * xk[i]
		}
	}
	for k in 1 ..< AEC_N {
		p.work[AEC_M - k] = conj(p.work[k])
	}
	fft_inverse(&p.fft, p.work[:])
	for i in 0 ..< AEC_N {
		y[i] = real(p.work[AEC_N + i])
	}
}

// echo_path_signal convolves a whole signal (a multiple of AEC_N long).
echo_path_signal :: proc(p: ^Echo_Path, far, echo: []f32) {
	for b := 0; b + AEC_N <= len(far); b += AEC_N {
		echo_path_block(p, far[b:b + AEC_N], echo[b:b + AEC_N])
	}
}

// echo_path_run is the frame interface: any length in, the same length out,
// one block late.
echo_path_run :: proc(p: ^Echo_Path, far, echo: []f32) {
	for i in 0 ..< len(far) {
		p.fin[p.fill] = far[i]
		p.fill += 1
		if p.fill == AEC_N {
			p.fill = 0
			y: [AEC_N]f32
			echo_path_block(p, p.fin[:], y[:])
			for v in y {
				p.outq[(p.out_r + p.out_n) % len(p.outq)] = v
				p.out_n += 1
			}
		}
	}
	for i in 0 ..< len(echo) {
		if p.out_n > 0 {
			echo[i] = p.outq[p.out_r]
			p.out_r = (p.out_r + 1) % len(p.outq)
			p.out_n -= 1
		} else {
			echo[i] = 0
		}
	}
}

// ---------------------------------------------------------------------------
// Synthetic voices. Not speech, but shaped like it where an echo canceller
// cares: a broadband, pink-ish spectrum with a voiced harmonic comb on top, a
// syllable-rate envelope and pauses between phrases. A pure tone would be the
// easy case — one frequency to model — and would flatter the result.
// ---------------------------------------------------------------------------

synth_voice :: proc(out: []f32, f0: f32, seed: u64, level := f32(0.25)) {
	r := rand.create(seed)
	gen := rand.default_random_generator(&r)
	b0, b1, b2: f32
	phase: f32
	for i in 0 ..< len(out) {
		t := f32(i) / f32(A_RATE)
		w := f32(rand.float64_range(-1, 1, gen))
		// Paul Kellet's economy pink filter.
		b0 = 0.99765 * b0 + w * 0.0990460
		b1 = 0.96300 * b1 + w * 0.2965164
		b2 = 0.57000 * b2 + w * 1.0526913
		pink := (b0 + b1 + b2 + w * 0.1848) * 0.2
		f := f0 * (1 + 0.06 * math.sin(2 * math.PI * 0.7 * t))
		phase += 2 * math.PI * f / f32(A_RATE)
		if phase > 2 * math.PI {
			phase -= 2 * math.PI
		}
		voiced: f32
		for h in 1 ..= 8 {
			voiced += math.sin(phase * f32(h)) / f32(h)
		}
		syl := math.sin(2 * math.PI * 3.3 * t)
		env := syl > 0 ? math.sqrt(syl) : 0
		// Phrases of 1.6 s with 0.4 s of pause.
		if math.mod(t, 2.0) > 1.6 {
			env = 0
		}
		out[i] = level * env * (0.6 * pink + 0.25 * voiced)
	}
}

// ---------------------------------------------------------------------------
// The measurement: ERLE on a synthetic echo path, scored phase by phase.
// ---------------------------------------------------------------------------

Aec_Report :: struct {
	seconds:          f32,
	tail_ms:          f32,
	path_delay_ms:    f32,
	path_gain_db:     f32,
	// ERLE as usually defined: microphone energy over output energy, far end
	// talking alone, after convergence. Bounded by the noise floor.
	erle_db:          f32,
	// Echo over residual echo: what the canceller removed, with the near
	// end's noise taken out of the score because here it is known exactly.
	echo_removal_db:  f32,
	// During double talk: echo removal, and the near-end voice over what was
	// left of the echo plus whatever the filter did to the voice.
	dt_echo_removal_db: f32,
	dt_near_to_residual_db: f32,
	// After double talk: the far end alone again — did the model survive?
	post_dt_erle_db:  f32,
	// After the echo path moves (another room, another delay).
	reconverged_erle_db: f32,
	converge_ms:      f32, // first time a 100 ms window reached 20 dB of echo removal
	copies, resets:   int,
	cpu_ms_per_s:     f32, // processing cost per second of audio
}

Aec_Scenario :: struct {
	delay_ms, room_ms, gain_db: f32,
	noise_db: f32, // near-end noise floor, dBFS
	enabled:  bool,
	parts:    int,
	near_always: bool, // the near end talks the whole time, not only 5-7 s
	far:      []f32, // optional: supplied far end (else synthetic)
	near:     []f32, // optional: supplied near end (else synthetic)
}

AEC_SCENARIO_DEFAULT :: Aec_Scenario {
	delay_ms = 40,
	room_ms  = 30,
	gain_db  = -6,
	noise_db = -65,
	enabled  = true,
	parts    = AEC_PARTS,
}

// Phases, in seconds.
AEC_T_CONVERGED :: 2.0 // far alone from 0; scored from here
AEC_T_DT :: 5.0 // near starts talking
AEC_T_DT_END :: 7.0
AEC_T_MOVE :: 9.0 // the echo path changes
AEC_T_END :: 12.0

aec_measure :: proc(sc: Aec_Scenario) -> (rep: Aec_Report) {
	n := int(AEC_T_END * f32(A_RATE))
	n -= n % AEC_N
	far := make([]f32, n)
	near := make([]f32, n)
	noise := make([]f32, n)
	echo := make([]f32, n)
	mic := make([]f32, n)
	out := make([]f32, n)
	defer {
		delete(far); delete(near); delete(noise); delete(echo); delete(mic); delete(out)
	}
	if sc.far != nil {
		copy(far, sc.far)
	} else {
		synth_voice(far, 118, 0xFA4)
	}
	nv := make([]f32, n)
	defer delete(nv)
	if sc.near != nil {
		copy(nv, sc.near)
	} else {
		synth_voice(nv, 205, 0x4EA4, 0.18)
	}
	dt0, dt1 := int(AEC_T_DT * f32(A_RATE)), int(AEC_T_DT_END * f32(A_RATE))
	if sc.near_always {
		dt0, dt1 = 0, n
	}
	for i in dt0 ..< min(dt1, n) {
		near[i] = nv[i]
	}
	{
		r := rand.create(0x7015E)
		gen := rand.default_random_generator(&r)
		amp := math.pow(10, sc.noise_db / 20)
		for i in 0 ..< n {
			noise[i] = amp * f32(rand.norm_float64(gen))
		}
	}
	move := int(AEC_T_MOVE * f32(A_RATE))
	p1 := echo_path_make(sc.delay_ms, sc.room_ms, sc.gain_db, 0xEC40)
	p2 := echo_path_make(sc.delay_ms + 15, sc.room_ms, sc.gain_db + 2, 0xEC41)
	defer {
		echo_path_destroy(&p1)
		echo_path_destroy(&p2)
	}
	echo_path_signal(&p1, far, echo)
	// The new room hears the same far end from the start, so its history is
	// full when it takes over — a moved microphone, not a new call.
	{
		tmp := make([]f32, n)
		defer delete(tmp)
		echo_path_signal(&p2, far, tmp)
		copy(echo[move:], tmp[move:])
	}
	for i in 0 ..< n {
		mic[i] = near[i] + echo[i] + noise[i]
	}

	a: Aec
	aec_init(&a, sc.parts > 0 ? sc.parts : AEC_PARTS)
	defer aec_destroy(&a)
	t0 := now_us()
	for b := 0; b + AEC_N <= n; b += AEC_N {
		if sc.enabled {
			aec_block(&a, far[b:b + AEC_N], mic[b:b + AEC_N], out[b:b + AEC_N])
		} else {
			copy(out[b:b + AEC_N], mic[b:b + AEC_N])
		}
	}
	cost := f32(now_us() - t0) / 1000

	db :: proc(num, den: f64) -> f32 {
		return f32(10 * math.log10(max(num, 1e-20) / max(den, 1e-20)))
	}
	span :: proc(t0, t1: f32, n: int) -> (int, int) {
		return int(t0 * f32(A_RATE)), min(n, int(t1 * f32(A_RATE)))
	}
	score :: proc(lo, hi: int, mic, out, echo, near, noise: []f32) -> (erle, removal, near_res: f32) {
		sd, se, sech, sres, snear: f64
		for i in lo ..< hi {
			sd += f64(mic[i]) * f64(mic[i])
			se += f64(out[i]) * f64(out[i])
			sech += f64(echo[i]) * f64(echo[i])
			r := f64(out[i]) - f64(near[i]) - f64(noise[i])
			sres += r * r
			snear += f64(near[i]) * f64(near[i])
		}
		return db(sd, se), db(sech, sres), db(snear, sres)
	}

	lo, hi := span(AEC_T_CONVERGED, AEC_T_DT, n)
	rep.erle_db, rep.echo_removal_db, _ = score(lo, hi, mic, out, echo, near, noise)
	lo, hi = span(AEC_T_DT, AEC_T_DT_END, n)
	_, rep.dt_echo_removal_db, rep.dt_near_to_residual_db = score(lo, hi, mic, out, echo, near, noise)
	lo, hi = span(AEC_T_DT_END, AEC_T_MOVE, n)
	rep.post_dt_erle_db, _, _ = score(lo, hi, mic, out, echo, near, noise)
	lo, hi = span(AEC_T_MOVE + 1.5, AEC_T_END, n)
	rep.reconverged_erle_db, _, _ = score(lo, hi, mic, out, echo, near, noise)

	rep.converge_ms = -1
	win := A_RATE / 10
	for s := 0; s + win <= int(AEC_T_DT * f32(A_RATE)); s += AEC_N {
		_, rem, _ := score(s, s + win, mic, out, echo, near, noise)
		if rem >= 20 {
			rep.converge_ms = f32(s + win) * 1000 / f32(A_RATE)
			break
		}
	}
	rep.seconds = f32(n) / f32(A_RATE)
	rep.tail_ms = aec_tail_ms(&a)
	rep.path_delay_ms = sc.delay_ms
	rep.path_gain_db = sc.gain_db
	rep.copies = a.copies
	rep.resets = a.resets
	rep.cpu_ms_per_s = cost / rep.seconds
	return
}

// aec_erle_estimate is the canceller's own running view of what it removes:
// microphone energy over output energy, smoothed over ~40 ms. Live, with no
// echo known separately, this is the only ERLE there is; it reads low while
// the near end talks, which is correct — it measures the output, not the echo.
aec_erle_estimate :: proc(a: ^Aec) -> f32 {
	if a.sf <= 0 || a.sd <= 0 {
		return 0
	}
	return 10 * math.log10(a.sd / a.sf)
}
