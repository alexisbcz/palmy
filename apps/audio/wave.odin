package main

// The picture of the sound.
//
// Everything drawn here comes from the file's own samples, decoded once per
// track with
//
//   ffmpeg -i FILE -f s16le -ac 1 -ar 16000 -
//
// which is 32 KB of PCM per second of audio — small enough to keep the whole
// track in memory and cheap enough to decode on a worker thread while the
// first sound is already playing. From that one buffer come three things: the
// peak envelope behind the scrub bar, a 1024-point FFT at the playhead for the
// spectrum, and the raw samples for the oscilloscope.
//
// The rate is 16 kHz rather than 8, so the analyser reaches 8 kHz instead of
// stopping at 4 and the top two octaves of a real recording are actually on
// the screen. Doubling the rate halves the frequency resolution of a fixed
// transform, so FFT_N doubles with it: bin width stays at 15.6 Hz and the
// window stays 64 ms long. The price is twice the memory — 32 KB per second,
// 115 MB for an hour-long track, and the player holds two of these while it
// is pre-decoding the next track.

import "core:math"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

WAVE_RATE :: 16000
FFT_N :: 1024
BARS :: 56
// The oscilloscope window, in samples: 150 ms whatever the rate.
SCOPE_SPAN :: WAVE_RATE * 150 / 1000
// ffmpeg's `-ar` argument. It is spelled out rather than formatted because the
// analysis runs on a worker thread, and a worker has no business touching the
// temporary allocator for the lifetime of a decode.
WAVE_RATE_STR :: "16000"
#assert(WAVE_RATE == 16000) // keep WAVE_RATE_STR honest
#assert(FFT_N & (FFT_N - 1) == 0) // radix-2 needs a power of two

Analysis :: struct {
	mu:     sync.Mutex,
	worker: ^thread.Thread,
	path:   string,
	pcm:    []i16,
	done:   bool,
	ok:     bool,
	ms:     f64,
	bytes:  int,
}

analysis_start :: proc(a: ^Analysis, path: string) {
	analysis_stop(a)
	a.path = path
	a.done = false
	a.ok = false
	a.worker = thread.create(analysis_main)
	a.worker.data = rawptr(a)
	thread.start(a.worker)
}

analysis_stop :: proc(a: ^Analysis) {
	if a.worker != nil {
		thread.join(a.worker)
		thread.destroy(a.worker)
		a.worker = nil
	}
	delete(a.pcm)
	a.pcm = nil
	a.done = false
	a.ok = false
}

@(private)
analysis_main :: proc(t: ^thread.Thread) {
	a := (^Analysis)(t.data)
	t0 := time.now()
	state, sout, serr, err := os.process_exec(
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
				WAVE_RATE_STR,
				"-",
			},
		},
		context.allocator,
	)
	delete(serr)
	ms := time.duration_milliseconds(time.since(t0))

	pcm: []i16
	ok := false
	if err == nil && state.exit_code == 0 && len(sout) >= 2 {
		n := len(sout) / 2
		pcm = (transmute([^]i16)raw_data(sout))[:n]
		ok = true
	}

	sync.lock(&a.mu)
	a.pcm = pcm
	a.bytes = len(sout)
	a.ok = ok
	a.ms = ms
	a.done = true
	sync.unlock(&a.mu)
	// `pcm` aliases `sout`, so the bytes are freed with the samples.
}

analysis_ready :: proc(a: ^Analysis) -> (ready: bool, ok: bool, ms: f64, samples: int) {
	sync.lock(&a.mu)
	defer sync.unlock(&a.mu)
	return a.done, a.ok, a.ms, len(a.pcm)
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

// spectrum computes an FFT_N-point FFT of the window at `t` seconds and folds it
// into logarithmically spaced bars, the way a real analyser is read.
spectrum :: proc(a: ^Analysis, t: f64, out: []f32) -> bool {
	re: [FFT_N]f32
	im: [FFT_N]f32

	sync.lock(&a.mu)
	n := len(a.pcm)
	if n < FFT_N {
		sync.unlock(&a.mu)
		return false
	}
	start := int(t * WAVE_RATE) - FFT_N / 2
	start = clamp(start, 0, n - FFT_N)
	for i in 0 ..< FFT_N {
		// Hann, so a tone lands in one bar instead of smearing across six.
		w := 0.5 - 0.5 * math.cos(2 * math.PI * f32(i) / f32(FFT_N - 1))
		re[i] = f32(a.pcm[start + i]) / 32768 * w
		im[i] = 0
	}
	sync.unlock(&a.mu)

	fft(re[:], im[:])

	// Bar k covers [f0, f1) on a log scale between 40 Hz and Nyquist.
	nb := len(out)
	lo := f32(40)
	hi := f32(WAVE_RATE / 2)
	bin_hz := f32(WAVE_RATE) / f32(FFT_N)
	for k in 0 ..< nb {
		f0 := lo * math.pow(hi / lo, f32(k) / f32(nb))
		f1 := lo * math.pow(hi / lo, f32(k + 1) / f32(nb))
		b0 := clamp(int(f0 / bin_hz), 1, FFT_N / 2 - 1)
		b1 := clamp(max(int(f1 / bin_hz), b0 + 1), 2, FFT_N / 2)
		m := f32(0)
		for b in b0 ..< b1 {
			v := math.sqrt(re[b] * re[b] + im[b] * im[b])
			if v > m {m = v}
		}
		// Decibels, mapped so −60 dB is the floor and 0 dB the top.
		db := 20 * math.log10(max(m, 1e-6))
		out[k] = clamp((db + 60) / 60, 0, 1)
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
