package main

// The picture of the sound.
//
// Everything drawn here comes from the file's own samples, decoded once per
// track on a worker thread with
//
//   ffmpeg -i FILE -f s16le -ac 1 -ar 48000 -
//
// and read as a stream, never held whole. Two things are built from it as it
// arrives:
//
//   - a 16 kHz mono copy (`pcm`), decimated 3:1 through a low-pass FIR, for
//     the peak envelope behind the scrub bar and the oscilloscope. Neither
//     needs more: the envelope is one peak per column, and the scope shows
//     150 ms. 32 KB per second, as before.
//   - a spectrogram (`spec`): every 33 ms, a 2048-point Hann-windowed FFT of
//     the full-rate signal, folded into the BARS log-spaced bars the analyser
//     draws and stored as one byte each. 1.7 KB per second.
//
// The spectrum used to be an FFT of the 16 kHz copy at the playhead, which put
// its ceiling at 8 kHz (and before that, at 8 kHz decoding, at 4). Decoding
// at 48 kHz for the spectrum alone would cost 96 KB per second held — 345 MB
// for an hour, twice while the next track is pre-decoded — to keep samples
// that are only ever looked at 56 numbers at a time. Precomputing those 56
// numbers is the proper rate at a fiftieth of the memory, and makes drawing a
// spectrum a table lookup. The analyser now reaches 24 kHz, past the top of
// human hearing.
//
// What it gives up: bins are 23.4 Hz wide (the 16 kHz transform's were 15.6)
// and the window is 43 ms (it was 64), so the lowest few bars share bins a
// little more; the spectrum is quantised to 33 ms steps, about two frames of
// the UI, which smooths the bars anyway; and to 1/255 of the 60 dB range.
// A 4096-point transform every 25 ms was tried first and cost 35 s of worker
// time for a 10-minute track (unoptimised build, VM under load) against 2.2 s
// for the 16 kHz decode alone. Pairing frames into one complex transform,
// precomputed twiddles and the smaller window are what bring it down.

import "core:math"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

WAVE_RATE :: 16000
SPEC_RATE :: 48000
// ffmpeg's `-ar` argument. It is spelled out rather than formatted because the
// analysis runs on a worker thread, and a worker has no business touching the
// temporary allocator for the lifetime of a decode.
SPEC_RATE_STR :: "48000"
#assert(SPEC_RATE == 48000) // keep SPEC_RATE_STR honest
DECIM :: SPEC_RATE / WAVE_RATE
#assert(DECIM * WAVE_RATE == SPEC_RATE)
FFT_N :: 2048
SPEC_HOP :: SPEC_RATE / 30 // 33 ms between spectrogram frames
BARS :: 56
// The display's lowest frequency; the highest is SPEC_RATE / 2.
SPEC_LO :: 40.0
// The oscilloscope window, in samples: 150 ms whatever the rate.
SCOPE_SPAN :: WAVE_RATE * 150 / 1000
#assert(FFT_N & (FFT_N - 1) == 0) // radix-2 needs a power of two
// Half-width of the decimation filter, in 48 kHz taps.
FIR_M :: 24
FIR_TAPS :: 2 * FIR_M + 1
// The FFT magnitudes are scaled to dB full scale: a Hann-windowed sine of
// amplitude A comes out of an N-point transform at A·N/4, so this makes a
// full-scale tone 0 dB, the top of the display, and the floor −60 dBFS. The
// old analyser used the raw magnitude, which put 0 dB at a tone 48 dB below
// full scale: anything louder pinned its bar at the top, so a sweep over pink
// noise was a wall of full bars with the sweep indistinguishable in it.
SPEC_SCALE :: 4.0 / f32(FFT_N)

Analysis :: struct {
	mu:     sync.Mutex,
	worker: ^thread.Thread,
	path:   string,
	pcm:    []i16, // 16 kHz mono
	spec:   []u8, // frames × BARS, 0…255 over the display's range
	frames: int,
	done:   bool,
	ok:     bool,
	cancel: bool,
	ms:     f64,
	bytes:  int, // 48 kHz PCM bytes decoded
}

analysis_start :: proc(a: ^Analysis, path: string) {
	analysis_stop(a)
	a.path = path
	a.done = false
	a.ok = false
	a.cancel = false
	a.worker = thread.create(analysis_main)
	a.worker.data = rawptr(a)
	thread.start(a.worker)
}

analysis_stop :: proc(a: ^Analysis) {
	if a.worker != nil {
		sync.lock(&a.mu)
		a.cancel = true
		sync.unlock(&a.mu)
		thread.join(a.worker)
		thread.destroy(a.worker)
		a.worker = nil
	}
	delete(a.pcm)
	delete(a.spec)
	a.pcm = nil
	a.spec = nil
	a.frames = 0
	a.done = false
	a.ok = false
}

@(private)
analysis_main :: proc(t: ^thread.Thread) {
	a := (^Analysis)(t.data)
	t0 := time.now()

	b := new(Wave_Builder)
	defer free(b)
	wb_init(b)
	defer wb_destroy(b)

	ok := false
	if r, w, perr := os.pipe(); perr == nil {
		ps, serr := os.process_start(
			{
				command = {
					"ffmpeg",
					"-hide_banner",
					"-loglevel",
					"error",
					"-i",
					a.path,
					"-vn",
					"-f",
					"s16le",
					"-acodec",
					"pcm_s16le",
					"-ac",
					"1",
					"-ar",
					SPEC_RATE_STR,
					"-",
				},
				stdout = w,
			},
		)
		os.close(w)
		if serr == nil {
			buf := make([]u8, 64 * 1024)
			defer delete(buf)
			carry := 0 // an odd byte left over from the last read
			cancelled := false
			for {
				sync.lock(&a.mu)
				cancelled = a.cancel
				sync.unlock(&a.mu)
				if cancelled {
					_ = os.process_kill(ps)
					break
				}
				n, rerr := os.read(r, buf[carry:])
				if n <= 0 || rerr != nil {
					break
				}
				have := carry + n
				even := have &~ 1
				wb_feed(b, (transmute([^]i16)raw_data(buf))[:even / 2])
				carry = have - even
				if carry == 1 {
					buf[0] = buf[even]
				}
			}
			state, _ := os.process_wait(ps)
			ok = !cancelled && state.exit_code == 0 && b.total > 0
		}
		os.close(r)
	}
	wb_finish(b)
	ms := time.duration_milliseconds(time.since(t0))

	sync.lock(&a.mu)
	if ok {
		a.pcm = wb_take_pcm(b)
		a.spec, a.frames = wb_take_spec(b)
	}
	a.bytes = int(b.total * 2)
	a.ok = ok
	a.ms = ms
	a.done = true
	sync.unlock(&a.mu)
}

analysis_ready :: proc(a: ^Analysis) -> (ready: bool, ok: bool, ms: f64, samples: int) {
	sync.lock(&a.mu)
	defer sync.unlock(&a.mu)
	return a.done, a.ok, a.ms, len(a.pcm)
}

// ---------------------------------------------------------------------------
// The builder: 48 kHz in, a 16 kHz copy and a spectrogram out
// ---------------------------------------------------------------------------

// Wave_Builder is fed the decode in whatever pieces the pipe hands over and
// keeps only the stretch of 48 kHz signal that a pending output still needs:
// at most a window plus a read.
Wave_Builder :: struct {
	hist:   [dynamic]f32, // 48 kHz samples, hist[0] is absolute index `base`
	base:   i64,
	total:  i64,
	next_k: i64, // next 16 kHz output sample
	next_f: i64, // next spectrogram frame
	pcm:    [dynamic]i16,
	spec:   [dynamic]u8,
	fir:    [FIR_TAPS]f32,
	win:    [FFT_N]f32,
	re, im: [FFT_N]f32,
	mag_a:  [FFT_N / 2 + 1]f32, // squared magnitudes of the two frames
	mag_b:  [FFT_N / 2 + 1]f32, // one transform computes
	tab:    Fft_Table,
	edges:  [BARS + 1]int, // first FFT bin of each bar, and one past the last
}

wb_init :: proc(b: ^Wave_Builder) {
	// A windowed sinc at 7.2 kHz, under the 8 kHz Nyquist of the copy, so
	// nothing above it folds back down into the envelope or the scope.
	fc := f32(7200) / f32(SPEC_RATE)
	sum := f32(0)
	for i in 0 ..< FIR_TAPS {
		x := f32(i - FIR_M)
		s := x == 0 ? 2 * fc : math.sin(2 * math.PI * fc * x) / (math.PI * x)
		// Blackman.
		w := 0.42 - 0.5 * math.cos(2 * math.PI * f32(i) / f32(FIR_TAPS - 1)) + 0.08 * math.cos(4 * math.PI * f32(i) / f32(FIR_TAPS - 1))
		b.fir[i] = s * w
		sum += b.fir[i]
	}
	for i in 0 ..< FIR_TAPS {
		b.fir[i] /= sum
	}
	for i in 0 ..< FFT_N {
		// Hann, so a tone lands in one bar instead of smearing across six.
		b.win[i] = 0.5 - 0.5 * math.cos(2 * math.PI * f32(i) / f32(FFT_N - 1))
	}
	fft_table_init(&b.tab)
	bin_hz := f32(SPEC_RATE) / f32(FFT_N)
	for k in 0 ..= BARS {
		b.edges[k] = int(bar_edge_hz(k) / bin_hz)
	}
}

wb_destroy :: proc(b: ^Wave_Builder) {
	delete(b.hist)
	delete(b.pcm)
	delete(b.spec)
}

// bar_edge_hz is where analyser bar `k` starts: log-spaced from SPEC_LO to
// Nyquist, so bar BARS is Nyquist itself.
bar_edge_hz :: proc(k: int) -> f32 {
	hi := f32(SPEC_RATE / 2)
	return f32(SPEC_LO) * math.pow(hi / f32(SPEC_LO), f32(k) / f32(BARS))
}

wb_feed :: proc(b: ^Wave_Builder, s: []i16) #no_bounds_check {
	old := len(b.hist)
	resize(&b.hist, old + len(s))
	for v, i in s {
		b.hist[old + i] = f32(v) * (1.0 / 32768)
	}
	b.total += i64(len(s))
	wb_drain(b, false)
}

wb_finish :: proc(b: ^Wave_Builder) {
	wb_drain(b, true)
	// Too short for one full window: no spectrum, rather than one made mostly
	// of the zeros it was padded with.
	if b.total < FFT_N {
		clear(&b.spec)
		b.next_f = 0
	}
}

// The signal at an absolute index, zero outside what has been decoded.
@(private = "file")
wb_at :: #force_inline proc(b: ^Wave_Builder, i: i64) -> f32 {
	if i < b.base || i >= b.total {
		return 0
	}
	return b.hist[i - b.base]
}

@(private = "file")
wb_drain :: proc(b: ^Wave_Builder, final: bool) #no_bounds_check {
	// The 16 kHz copy: output k is centred on input DECIM·k.
	for {
		c := i64(DECIM) * b.next_k
		if final ? c >= b.total : c + FIR_M >= b.total {
			break
		}
		y := f32(0)
		if c - FIR_M >= b.base && c + FIR_M < b.total {
			h := b.hist[c - FIR_M - b.base:]
			for i in 0 ..< FIR_TAPS {
				y += b.fir[i] * h[i]
			}
		} else {
			for i in 0 ..< FIR_TAPS {
				y += b.fir[i] * wb_at(b, c + i64(i - FIR_M))
			}
		}
		append(&b.pcm, i16(clamp(y * 32768, -32768, 32767)))
		b.next_k += 1
	}
	// The spectrogram: frame f's window is centred on SPEC_HOP·f. Frames go
	// through the transform two at a time, one as the real part and one as
	// the imaginary, which a real signal's symmetry lets us pull apart again.
	for wb_ready(b, b.next_f, final) {
		two := wb_ready(b, b.next_f + 1, final)
		if !two && !final {
			break
		}
		wb_frames(b, i64(SPEC_HOP) * b.next_f - FFT_N / 2, two)
		b.next_f += two ? 2 : 1
	}
	// Forget what neither output can reach back to any more.
	keep := min(i64(DECIM) * b.next_k - FIR_M, i64(SPEC_HOP) * b.next_f - FFT_N / 2)
	if drop := keep - b.base; drop > 1 << 16 {
		remove_range(&b.hist, 0, int(drop))
		b.base += drop
	}
}

@(private = "file")
wb_ready :: proc(b: ^Wave_Builder, f: i64, final: bool) -> bool {
	c := i64(SPEC_HOP) * f
	return final ? c < b.total : c + FFT_N / 2 <= b.total
}

// wb_frames transforms the window starting at `start` and, if `two`, the one
// a hop after it, and appends a row of bars for each.
@(private = "file")
wb_frames :: proc(b: ^Wave_Builder, start: i64, two: bool) #no_bounds_check {
	start2 := start + SPEC_HOP
	if two && start >= b.base && start2 + FFT_N <= b.total {
		ha := b.hist[start - b.base:]
		hb := b.hist[start2 - b.base:]
		for i in 0 ..< FFT_N {
			b.re[i] = ha[i] * b.win[i]
			b.im[i] = hb[i] * b.win[i]
		}
	} else {
		for i in 0 ..< FFT_N {
			b.re[i] = wb_at(b, start + i64(i)) * b.win[i]
			b.im[i] = two ? wb_at(b, start2 + i64(i)) * b.win[i] : 0
		}
	}
	fft_tab(b.re[:], b.im[:], &b.tab)
	// Z = A + iB with A and B real, so A[k] = (Z[k] + conj Z[N−k]) / 2 and
	// B[k] = (Z[k] − conj Z[N−k]) / 2i.
	for k in 0 ..= FFT_N / 2 {
		j := (FFT_N - k) & (FFT_N - 1)
		ar := (b.re[k] + b.re[j]) * 0.5
		ai := (b.im[k] - b.im[j]) * 0.5
		br := (b.im[k] + b.im[j]) * 0.5
		bi := (b.re[j] - b.re[k]) * 0.5
		b.mag_a[k] = ar * ar + ai * ai
		b.mag_b[k] = br * br + bi * bi
	}
	wb_fold(b, b.mag_a[:])
	if two {
		wb_fold(b, b.mag_b[:])
	}
}

@(private = "file")
wb_fold :: proc(b: ^Wave_Builder, mag2: []f32) #no_bounds_check {
	for k in 0 ..< BARS {
		b0 := clamp(b.edges[k], 1, FFT_N / 2 - 1)
		b1 := clamp(max(b.edges[k + 1], b0 + 1), 2, FFT_N / 2)
		if k == BARS - 1 {
			b1 = FFT_N / 2 + 1 // the top bar owns the Nyquist bin
		}
		m := f32(0)
		for bin in b0 ..< b1 {
			m = max(m, mag2[bin])
		}
		// Decibels of the magnitude (10·log10 of its square), mapped so −60 dB
		// is the floor and 0 dB the top.
		db := 10 * math.log10(max(m * SPEC_SCALE * SPEC_SCALE, 1e-12))
		v := clamp((db + 60) / 60, 0, 1)
		append(&b.spec, u8(v * 255 + 0.5))
	}
}

// The results, handed over: the builder forgets them.
wb_take_pcm :: proc(b: ^Wave_Builder) -> []i16 {
	out := b.pcm[:]
	b.pcm = {}
	return out
}

wb_take_spec :: proc(b: ^Wave_Builder) -> (spec: []u8, frames: int) {
	out := b.spec[:]
	b.spec = {}
	return out, len(out) / BARS
}

// ---------------------------------------------------------------------------
// Peak envelope
// ---------------------------------------------------------------------------

// peaks fills `out` with the loudest sample in each horizontal slice of the
// track, which is the shape a waveform scrubber is made of. The result is
// normalised to the track's own loudest moment — a quiet recording should still
// fill the strip, the way every editor draws one — but never amplified more
// than 12x, so true silence stays flat.
peaks :: proc(a: ^Analysis, out: []f32) -> (gain: f32) {
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	sync.lock(&a.mu)
	defer sync.unlock(&a.mu)
	n := len(a.pcm)
	if n == 0 || len(out) == 0 {
		return 1
	}
	for i in 0 ..< len(out) {
		s0 := i * n / len(out)
		s1 := max(s0 + 1, (i + 1) * n / len(out))
		mx := i16(0)
		// A stride keeps this O(columns) even for an hour-long file; a peak
		// meter does not need every sample to look right.
		step := max(1, (s1 - s0) / 64)
		for s := s0; s < s1; s += step {
			v := a.pcm[s]
			av := v < 0 ? -v : v
			if av > mx {mx = av}
		}
		out[i] = f32(mx) / 32768
	}

	loudest := f32(0)
	for v in out {
		if v > loudest {loudest = v}
	}
	g := f32(1)
	if loudest > 0.0005 {
		g = min(1 / loudest, 12)
		for i in 0 ..< len(out) {
			out[i] = min(out[i] * g, 1)
		}
	}
	return g
}

// ---------------------------------------------------------------------------
// Spectrum
// ---------------------------------------------------------------------------

// spectrum reads the spectrogram frame nearest `t` seconds into `out`, one
// value per bar, 0…1 over −60…0 dB. A playhead outside the track clamps to its
// first or last frame; a track too short for one window has none.
spectrum :: proc(a: ^Analysis, t: f64, out: []f32) -> bool {
	sync.lock(&a.mu)
	defer sync.unlock(&a.mu)
	if a.frames == 0 {
		return false
	}
	f := clamp(int(math.round(t * f64(SPEC_RATE) / f64(SPEC_HOP))), 0, a.frames - 1)
	row := a.spec[f * BARS:][:BARS]
	for k in 0 ..< len(out) {
		out[k] = k < BARS ? f32(row[k]) / 255 : 0
	}
	return true
}

// scope copies the raw samples around `t` into `out`, scaled to ±1 and lifted
// by `gain` so a quiet recording still draws a trace rather than a flat line.
scope :: proc(a: ^Analysis, t: f64, out: []f32, span: int, gain: f32 = 1) -> bool {
	sync.lock(&a.mu)
	defer sync.unlock(&a.mu)
	n := len(a.pcm)
	if n < span || len(out) == 0 {
		return false
	}
	start := clamp(int(t * WAVE_RATE) - span / 2, 0, n - span)
	for i in 0 ..< len(out) {
		s := start + i * span / len(out)
		out[i] = clamp(f32(a.pcm[clamp(s, 0, n - 1)]) / 32768 * gain, -1, 1)
	}
	return true
}

// fft is an in-place iterative radix-2 Cooley–Tukey transform. FFT_N is a power
// of two by construction, so there is no padding to worry about.
@(private)
fft :: proc(re, im: []f32) {
	n := len(re)
	// Bit reversal.
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	length := 2
	for length <= n {
		ang := -2 * math.PI / f32(length)
		wr := math.cos(ang)
		wi := math.sin(ang)
		for i := 0; i < n; i += length {
			cr := f32(1)
			ci := f32(0)
			for k in 0 ..< length / 2 {
				ur := re[i + k]
				ui := im[i + k]
				vr := re[i + k + length / 2] * cr - im[i + k + length / 2] * ci
				vi := re[i + k + length / 2] * ci + im[i + k + length / 2] * cr
				re[i + k] = ur + vr
				im[i + k] = ui + vi
				re[i + k + length / 2] = ur - vr
				im[i + k + length / 2] = ui - vi
				nr := cr * wr - ci * wi
				ci = cr * wi + ci * wr
				cr = nr
			}
		}
		length <<= 1
	}
}

// Fft_Table holds what `fft` recomputes on every call: the twiddles and the
// bit-reversal permutation for FFT_N. The spectrogram runs a transform every
// 67 ms of audio, thousands per track, so it uses the table form.
Fft_Table :: struct {
	tw_re, tw_im: [FFT_N / 2]f32,
	rev:          [FFT_N]u16,
}

fft_table_init :: proc(t: ^Fft_Table) {
	for k in 0 ..< FFT_N / 2 {
		a := -2 * math.PI * f64(k) / f64(FFT_N)
		t.tw_re[k] = f32(math.cos(a))
		t.tw_im[k] = f32(math.sin(a))
	}
	bits := 0
	for (1 << uint(bits)) < FFT_N {bits += 1}
	for i in 0 ..< FFT_N {
		r := 0
		for j in 0 ..< bits {
			if i & (1 << uint(j)) != 0 {r |= 1 << uint(bits - 1 - j)}
		}
		t.rev[i] = u16(r)
	}
}

// fft_tab is `fft` with its tables precomputed: the same transform, the same
// sign convention, checked against it in the self-test.
fft_tab :: proc(re, im: []f32, t: ^Fft_Table) #no_bounds_check {
	n := FFT_N
	assert(len(re) == n && len(im) == n)
	for i in 0 ..< n {
		j := int(t.rev[i])
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	length := 2
	for length <= n {
		half := length / 2
		step := n / length
		for i := 0; i < n; i += length {
			for k in 0 ..< half {
				wr := t.tw_re[k * step]
				wi := t.tw_im[k * step]
				a := i + k
				c := a + half
				vr := re[c] * wr - im[c] * wi
				vi := re[c] * wi + im[c] * wr
				re[c] = re[a] - vr
				im[c] = im[a] - vi
				re[a] += vr
				im[a] += vi
			}
		}
		length <<= 1
	}
}
