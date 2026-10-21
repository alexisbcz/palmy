package main

// `audio --selftest` checks the maths behind the picture of the sound — the
// FFT, the peak envelope and its normalisation, the oscilloscope window — plus
// the tag reader and the playlist ordering. A spectrum that is subtly wrong
// still looks like a spectrum, so these are checked against signals whose
// answers are known rather than against a screenshot.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

checks: int
failures: int

check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printfln("  FAIL  %s", what)
	}
}

run_selftest :: proc() {
	test_fft()
	test_peaks()
	test_spectrum()
	test_scope()
	test_segments()
	test_tags()
	test_formats()
	test_order()
	test_engine()
	test_gapless()
	test_cli()

	fmt.printfln("audio selftest: %d checks, %d failures", checks, failures)
}

// ---------------------------------------------------------------------------
// The transform
// ---------------------------------------------------------------------------

test_fft :: proc() {
	N :: FFT_N

	// A constant signal is all DC and nothing else.
	re: [N]f32
	im: [N]f32
	for i in 0 ..< N {
		re[i] = 1
		im[i] = 0
	}
	fft(re[:], im[:])
	check(abs(re[0] - f32(N)) < 0.01, "a constant signal puts all its energy in bin 0")
	off := f32(0)
	for b in 1 ..< N / 2 {
		off = max(off, math.sqrt(re[b] * re[b] + im[b] * im[b]))
	}
	check(off < 0.01, "and nothing anywhere else")

	// A cosine at exactly bin k must land in bin k and nowhere near its
	// neighbours. This is the property the whole analyser rests on.
	// The list reaches into the top octaves the 1024-point transform added:
	// bin 511 is the last one below Nyquist, which is where an off-by-one in
	// the butterfly would show up first.
	for k in ([?]int{1, 7, 32, 100, 255, 300, 400, 509, 511}) {
		for i in 0 ..< N {
			re[i] = math.cos(2 * math.PI * f32(k) * f32(i) / f32(N))
			im[i] = 0
		}
		fft(re[:], im[:])
		mags: [N / 2]f32
		peak := 0
		for b in 0 ..< N / 2 {
			mags[b] = math.sqrt(re[b] * re[b] + im[b] * im[b])
			if mags[b] > mags[peak] {
				peak = b
			}
		}
		check(peak == k, fmt.tprintf("a cosine at bin %d peaks at bin %d", k, k))
		// Leakage into the rest of the spectrum should be negligible.
		rest := f32(0)
		for b in 0 ..< N / 2 {
			if b != k && b != k - 1 && b != k + 1 {
				rest = max(rest, mags[b])
			}
		}
		check(rest < mags[peak] * 0.01, fmt.tprintf("bin %d does not leak", k))
	}

	// Parseval: the transform conserves energy, which catches a scaling slip.
	for i in 0 ..< N {
		re[i] = math.sin(2 * math.PI * 11 * f32(i) / f32(N)) * 0.5
		im[i] = 0
	}
	time_energy := f32(0)
	for i in 0 ..< N {
		time_energy += re[i] * re[i]
	}
	fft(re[:], im[:])
	freq_energy := f32(0)
	for b in 0 ..< N {
		freq_energy += re[b] * re[b] + im[b] * im[b]
	}
	check(
		abs(freq_energy / f32(N) - time_energy) < time_energy * 0.01,
		"Parseval holds, so the transform is correctly scaled",
	)
}

// ---------------------------------------------------------------------------
// The envelope
// ---------------------------------------------------------------------------

// bar_for is which spectrum bar holds a frequency — the same log mapping the
// drawing uses, so a test can say where a tone is supposed to appear.
bar_for :: proc(hz: f32) -> int {
	lo := f32(40)
	hi := f32(WAVE_RATE / 2)
	for k in 0 ..< BARS {
		f0 := lo * math.pow(hi / lo, f32(k) / f32(BARS))
		f1 := lo * math.pow(hi / lo, f32(k + 1) / f32(BARS))
		if hz >= f0 && hz < f1 {
			return k
		}
	}
	return -1
}

fake_analysis :: proc(pcm: []i16) -> Analysis {
	a: Analysis
	a.pcm = pcm
	a.done = true
	a.ok = true
	return a
}

test_peaks :: proc() {
	// Half silent, half full scale. Normalised, the loud half must reach 1 and
	// the quiet half must stay at 0.
	n := 8000
	pcm := make([]i16, n)
	defer delete(pcm)
	for i in 0 ..< n / 2 {
		pcm[i] = 0
	}
	for i in n / 2 ..< n {
		pcm[i] = i16(20000 * math.sin(f32(i) * 0.7))
	}
	a := fake_analysis(pcm)
	out := make([]f32, 100)
	defer delete(out)
	gain := peaks(&a, out)
	check(gain > 1 && gain <= 12, "a track below full scale is lifted, within the cap")
	check(out[0] < 0.01, "silence stays flat")
	check(out[49] < 0.01, "silence stays flat up to the halfway point")
	loud := f32(0)
	for i in 50 ..< 100 {
		loud = max(loud, out[i])
	}
	check(abs(loud - 1) < 0.01, "the loudest moment reaches the top of the strip")

	// Nothing at all must not be amplified into noise.
	quiet := make([]i16, 1000)
	defer delete(quiet)
	qa := fake_analysis(quiet)
	qout := make([]f32, 40)
	defer delete(qout)
	qgain := peaks(&qa, qout)
	check(qgain == 1, "pure silence is not amplified")
	flat := true
	for v in qout {
		if v != 0 {flat = false}
	}
	check(flat, "and stays flat")

	// A track that is already at full scale must not be touched.
	full := make([]i16, 2000)
	defer delete(full)
	for i in 0 ..< 2000 {
		full[i] = i % 2 == 0 ? 32767 : -32767
	}
	fa := fake_analysis(full)
	fout := make([]f32, 50)
	defer delete(fout)
	fgain := peaks(&fa, fout)
	check(abs(fgain - 1) < 0.01, "a track already at full scale gets unity gain")

	// The cap: a track 100x below full scale must stop at 12x, not 100x.
	tiny := make([]i16, 2000)
	defer delete(tiny)
	for i in 0 ..< 2000 {
		tiny[i] = i % 2 == 0 ? 300 : -300
	}
	ta := fake_analysis(tiny)
	tout := make([]f32, 50)
	defer delete(tout)
	check(peaks(&ta, tout) == 12, "the lift is capped at 12x")

	// An empty analysis must not divide by anything.
	ea := fake_analysis(nil)
	eout := make([]f32, 10)
	defer delete(eout)
	check(peaks(&ea, eout) == 1, "no samples, no gain")

	// Every column is in range whatever the input.
	bad := 0
	for v in out {
		if v < 0 || v > 1 {bad += 1}
	}
	check(bad == 0, "every column of the envelope is between 0 and 1")
}

test_spectrum :: proc() {
	// One second of a 1 kHz tone at the analysis rate.
	n := WAVE_RATE
	pcm := make([]i16, n)
	defer delete(pcm)
	for i in 0 ..< n {
		pcm[i] = i16(28000 * math.sin(2 * math.PI * 1000 * f32(i) / f32(WAVE_RATE)))
	}
	a := fake_analysis(pcm)
	bars: [BARS]f32
	check(spectrum(&a, 0.5, bars[:]), "a full window produces a spectrum")

	// Find which bar should hold 1 kHz, and check that it is the loudest.
	want := bar_for(1000)
	peak := 0
	for k in 0 ..< BARS {
		if bars[k] > bars[peak] {peak = k}
	}
	check(want >= 0, "1 kHz falls inside the plotted range")
	check(abs(peak - want) <= 1, "the loudest bar is the one holding 1 kHz")
	check(bars[peak] > 0.8, "a full-scale tone nearly fills its bar")

	bad := 0
	for v in bars {
		if v < 0 || v > 1 {bad += 1}
	}
	check(bad == 0, "every bar is between 0 and 1")

	// Silence sits on the floor rather than lighting everything up.
	quiet := make([]i16, n)
	defer delete(quiet)
	qa := fake_analysis(quiet)
	qbars: [BARS]f32
	check(spectrum(&qa, 0.5, qbars[:]), "silence still produces a spectrum")
	top := f32(0)
	for v in qbars {
		top = max(top, v)
	}
	check(top < 0.01, "silence leaves every bar on the floor")

	// The point of moving to 16 kHz: a tone the old rate could not represent
	// at all now lands in the right bar. 6 kHz was above the old 4 kHz
	// ceiling, so at 8 kHz it was not merely in the wrong bar — it was
	// outside the plotted range entirely.
	check(f32(WAVE_RATE / 2) > 4000, "the analyser reaches past the old 4 kHz ceiling")
	hi6 := make([]i16, n)
	defer delete(hi6)
	for i in 0 ..< n {
		hi6[i] = i16(28000 * math.sin(2 * math.PI * 6000 * f32(i) / f32(WAVE_RATE)))
	}
	ha := fake_analysis(hi6)
	hbars: [BARS]f32
	check(spectrum(&ha, 0.5, hbars[:]), "a 6 kHz tone produces a spectrum")
	w6 := bar_for(6000)
	check(w6 >= 0, "6 kHz falls inside the plotted range")
	hpeak := 0
	for k in 0 ..< BARS {
		if hbars[k] > hbars[hpeak] {hpeak = k}
	}
	check(abs(hpeak - w6) <= 1, "and the loudest bar is the one holding 6 kHz")
	check(hbars[hpeak] > 0.8, "a full-scale tone above 4 kHz nearly fills its bar")
	// It must not be mistaken for something low: an alias of 6 kHz at the old
	// rate would have landed down in the mids.
	low := f32(0)
	for k in 0 ..< BARS / 2 {
		low = max(low, hbars[k])
	}
	check(low < hbars[hpeak] * 0.5, "with nothing of it showing in the lower half")

	// The Nyquist edge: alternating full-scale samples are a tone at exactly
	// WAVE_RATE/2. It has to come out at the top of the display without
	// blowing anything up.
	nyq := make([]i16, n)
	defer delete(nyq)
	for i in 0 ..< n {
		nyq[i] = i % 2 == 0 ? 28000 : -28000
	}
	na := fake_analysis(nyq)
	nbars: [BARS]f32
	check(spectrum(&na, 0.5, nbars[:]), "a tone at Nyquist produces a spectrum")
	npeak := 0
	nbad := 0
	for k in 0 ..< BARS {
		if nbars[k] > nbars[npeak] {npeak = k}
		if nbars[k] < 0 || nbars[k] > 1 {nbad += 1}
	}
	check(nbad == 0, "every bar stays in range at the Nyquist edge")
	check(npeak >= BARS - 3, "and the energy shows in the topmost bars")

	// Too few samples to transform: refuse rather than read past the end.
	short := make([]i16, 64)
	defer delete(short)
	sa := fake_analysis(short)
	check(!spectrum(&sa, 0, bars[:]), "a buffer shorter than the window is refused")

	// A playhead past the end must clamp, not index out of range.
	check(spectrum(&a, 1e6, bars[:]), "a playhead past the end clamps into the buffer")
	check(spectrum(&a, -5, bars[:]), "and so does one before the start")
}

test_scope :: proc() {
	check(
		abs(f64(SCOPE_SPAN) / f64(WAVE_RATE) - 0.15) < 1e-9,
		"the oscilloscope still shows 150 ms of sound at the new rate",
	)
	n := 8000
	pcm := make([]i16, n)
	defer delete(pcm)
	for i in 0 ..< n {
		pcm[i] = i16(1000 * math.sin(f32(i) * 0.1))
	}
	a := fake_analysis(pcm)
	buf: [256]f32

	check(scope(&a, 0.25, buf[:], SCOPE_SPAN), "the scope reads a window")
	peak := f32(0)
	for v in buf {
		peak = max(peak, abs(v))
	}
	check(peak > 0.02 && peak < 0.04, "unity gain gives the samples' own amplitude")

	check(scope(&a, 0.25, buf[:], SCOPE_SPAN, 12), "the scope accepts a gain")
	gpeak := f32(0)
	for v in buf {
		gpeak = max(gpeak, abs(v))
	}
	check(gpeak > peak * 10, "the gain is applied")

	// However large the gain, the trace must stay inside the panel.
	check(scope(&a, 0.25, buf[:], SCOPE_SPAN, 10000), "an absurd gain is accepted")
	bad := 0
	for v in buf {
		if v < -1 || v > 1 {bad += 1}
	}
	check(bad == 0, "and clamped to the drawable range")

	check(!scope(&a, 0, buf[:], 100000), "a span longer than the track is refused")
	check(scope(&a, 1e6, buf[:], SCOPE_SPAN), "a playhead past the end clamps")
}

// ---------------------------------------------------------------------------
// The gapless clock
//
// `bytes` is a running total across several tracks, so "where are we" is no
// longer one subtraction. These are the two decisions the whole feature turns
// on, factored out of the engine so they can be asserted directly rather than
// inferred from a recording.
// ---------------------------------------------------------------------------

test_segments :: proc() {
	sec :: proc(s: f64) -> i64 {return i64(s * f64(BPS))}

	// Two tracks: a ten-second one, then a twenty-second one.
	segs := []Segment {
		{byte_start = 0, media_base = 0, track = 3, duration = 10},
		{byte_start = sec(10), media_base = 0, track = 7, duration = 20},
	}

	idx, t := seg_locate(segs, 0, 0)
	check(idx == 0 && t == 0, "nothing written yet is the start of the first track")
	check(segs[idx].track == 3, "and the first track is the one to display")

	idx, t = seg_locate(segs, sec(4), 0)
	check(idx == 0 && abs(t - 4) < 1e-9, "four seconds in is four seconds into track one")

	// The byte that begins a segment belongs to that segment, not the one
	// before it. Getting this wrong puts the display one track behind forever.
	idx, t = seg_locate(segs, sec(10), 0)
	check(idx == 1 && t == 0, "a byte exactly on a boundary is the start of the new track")
	idx, _ = seg_locate(segs, sec(10) - 1, 0)
	check(idx == 0, "and the byte before it is still the old one")

	// The pump is ahead of the speakers. Twenty milliseconds past the
	// boundary, with sixty milliseconds sitting in the sink, what is *audible*
	// is still the end of the previous track — which is why the UI follows
	// this and not the pump.
	lat := sec(0.06)
	idx, t = seg_locate(segs, sec(10) + sec(0.02), lat)
	check(idx == 0, "the sink's buffering pulls the answer back into the previous track")
	check(segs[idx].track == 3, "so the display stays on the track still coming out")
	check(abs(t - 9.96) < 1e-6, "at the right point near its end")

	// Half a second later the new track really is the audible one.
	idx, t = seg_locate(segs, sec(10) + sec(0.5), lat)
	check(idx == 1 && segs[idx].track == 7, "once the buffer has drained the new track is audible")
	check(abs(t - 0.44) < 1e-6, "and the clock reads the buffering back out of it")

	// A byte before the first segment clamps rather than running the clock
	// negative, which is what the first moments after a start look like.
	idx, t = seg_locate(segs, 0, sec(5))
	check(idx == 0 && t == 0, "a byte before the first segment clamps to its start")

	// A segment created by a seek starts part way into its track.
	sk := []Segment{{byte_start = 0, media_base = 90, track = 1, duration = 200}}
	_, t = seg_locate(sk, sec(2), 0)
	check(abs(t - 92) < 1e-9, "a segment started by a seek counts from its media base")
	_, t = seg_locate(sk, sec(500), 0)
	check(abs(t - 200) < 1e-9, "and the clock never runs past the end of the track")

	ni, _ := seg_locate(nil, 0, 0)
	check(ni == -1, "no segments, no answer")

	// The other decision: when to start the next decoder.
	one := Segment{byte_start = 0, media_base = 0, track = 0, duration = 100}
	check(!prefetch_due(sec(10), one, PREFETCH_LEAD), "a track with ninety seconds to run waits")
	check(!prefetch_due(sec(97.5), one, PREFETCH_LEAD), "and so does one with 2.5 s to run")
	check(prefetch_due(sec(98), one, PREFETCH_LEAD), "at two seconds left the next decoder starts")
	check(prefetch_due(sec(100), one, PREFETCH_LEAD), "and a track already finished is overdue")

	// It has to count within the segment, not from byte zero: after one
	// gapless join the second track starts ten seconds into the stream, and
	// after a seek it starts part way into its own timeline.
	two := Segment{byte_start = sec(10), media_base = 30, track = 1, duration = 40}
	check(!prefetch_due(sec(17), two, PREFETCH_LEAD), "the trigger counts from the segment's own base")
	check(prefetch_due(sec(18), two, PREFETCH_LEAD), "and fires at the right point inside it")

	// A stream of unknown length has no end to anticipate.
	unk := Segment{byte_start = 0, media_base = 0, track = 0, duration = 0}
	check(!prefetch_due(sec(1000), unk, PREFETCH_LEAD), "a track of unknown length never prefetches")
}

// ---------------------------------------------------------------------------
// Metadata and the playlist
// ---------------------------------------------------------------------------

test_tags :: proc() {
	doc := `{
	  "streams": [
	    { "codec_name": "flac", "codec_type": "audio", "channels": 2,
	      "sample_rate": "44100", "bit_rate": "900000",
	      "disposition": { "attached_pic": 0 } },
	    { "codec_name": "mjpeg", "codec_type": "video", "width": 1000,
	      "height": 1000, "disposition": { "attached_pic": 1 } }
	  ],
	  "format": { "format_name": "flac", "duration": "213.5", "size": "24000000",
	    "tags": { "TITLE": "A Song", "ARTIST": "A Band", "Album": "A Record", "date": "1979" } }
	}`
	m := parse_probe(doc, "/tmp/a.flac")
	check(m.ok, "a FLAC document parses")
	check(m.has_audio && !m.has_video, "a cover is not counted as video")
	check(m.has_cover, "the cover is noticed")
	// Vorbis comments are upper case; ID3 tends to be lower. Both must work.
	check(m.title == "A Song", "an upper-case TITLE is read")
	check(m.artist == "A Band", "an upper-case ARTIST is read")
	check(m.album == "A Record", "a mixed-case Album is read")
	check(m.date == "1979", "a lower-case date is read")
	check(abs(m.duration - 213.5) < 1e-6, "duration")
	check(m.channels == 2 && m.sample_rate == 44100, "layout")

	// A file with no tags at all must still play, falling back to the name.
	bare := parse_probe(
		`{"streams":[{"codec_type":"audio","codec_name":"mp3","channels":1,"sample_rate":"8000"}],"format":{"duration":"3"}}`,
		"/tmp/untitled-track.mp3",
	)
	check(bare.ok && bare.title == "", "a file with no tags still parses")
	t := Track{path = "/x/untitled-track.mp3", name = "untitled-track.mp3", probed = true, m = bare}
	check(track_title(&t) == "untitled-track", "the title falls back to the name without its extension")
	check(track_artist(&t) == "Unknown artist", "and the artist to a placeholder")

	t2 := Track{path = "/x/a.flac", name = "a.flac", probed = true, m = m}
	check(track_title(&t2) == "A Song", "a tagged track uses its tag")
	check(track_artist(&t2) == "A Band", "and its artist")

	check(path_key("/a/b") != path_key("/a/c"), "cover cache keys differ per path")
	check(path_key("/a/b") == path_key("/a/b"), "and are stable for one path")
}

test_formats :: proc() {
	check(is_audio("x.MP3"), "extensions are matched without case")
	check(is_audio("x.flac") && is_audio("x.opus") && is_audio("x.m4a"), "the common formats")
	check(!is_audio("x.mp4"), "video is not audio")
	check(!is_audio("x.mp3.bak"), "the extension has to be last")
	check(timecode(0) == "0:00", "zero")
	check(timecode(213) == "3:33", "minutes and seconds")
	check(timecode(3600) == "1:00:00", "an hour")
	check(human_rate(192_000) == "192 kb/s", "kilobits")
	check(base_of("/a/b.mp3") == "b.mp3", "base_of")
	check(dir_of("/a/b.mp3") == "/a", "dir_of")
}

test_order :: proc() {
	st := St{cur = -1, cover_for = -1, wave_for = -1, gain = 1}
	list := make([dynamic]Track)
	defer delete(list)
	for i in 0 ..< 12 {
		append(&list, Track{path = fmt.tprintf("/x/%02d.mp3", i)})
	}
	st.list = list[:]

	rebuild_order(&st)
	check(len(st.order) == 12, "the play order covers every track")
	seen: [12]bool
	for v in st.order {
		if v >= 0 && v < 12 {seen[v] = true}
	}
	missing := 0
	for s in seen {
		if !s {missing += 1}
	}
	check(missing == 0, "in order, every track appears exactly once")
	straight := true
	for v, i in st.order {
		if v != i {straight = false}
	}
	check(straight, "without shuffle the order is the list order")

	st.shuffle = true
	rebuild_order(&st)
	seen = {}
	for v in st.order {
		if v >= 0 && v < 12 {seen[v] = true}
	}
	missing = 0
	for s in seen {
		if !s {missing += 1}
	}
	check(missing == 0, "shuffled, every track still appears exactly once")

	// order_pos has to find a track wherever the shuffle put it.
	bad := 0
	for i in 0 ..< 12 {
		if st.order[order_pos(&st, i)] != i {
			bad += 1
		}
	}
	check(bad == 0, "order_pos finds each track's place in the shuffled order")
	delete(st.order)
}

// test_engine runs the real sound path on a generated file when ffmpeg is
// present: the analysis thread, and the pump whose byte count is the clock.
test_engine :: proc() {
	if !kit.has_tool("ffmpeg") || !kit.has_tool("ffprobe") {
		fmt.println("  skip  ffmpeg is not installed; engine checks not run")
		return
	}
	dir := fmt.tprintf("%s/palmy-audio-selftest", os.temp_dir(context.temp_allocator))
	_ = os.make_directory_all(dir)
	track := fmt.tprintf("%s/tone.mp3", dir)
	defer _ = os.remove_all(dir)

	_, made := kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "sine=frequency=1000:duration=3",
			"-metadata", "title=Selftest Tone", "-metadata", "artist=lavfi",
			"-b:a", "192k", track,
		},
		context.temp_allocator,
	)
	if !made || !os.exists(track) {
		fmt.println("  skip  could not generate a test track")
		return
	}

	m := probe_file(track)
	check(m.ok, "a generated track probes cleanly")
	check(m.title == "Selftest Tone", "its title tag survives the round trip")
	check(m.artist == "lavfi", "and its artist tag")
	check(abs(m.duration - 3) < 0.3, "and its duration")

	// The analysis decodes the whole track to 8 kHz mono on a worker thread.
	a: Analysis
	analysis_start(&a, track)
	ready, ok, ms, samples: = false, false, f64(0), 0
	for _ in 0 ..< 600 {
		ready, ok, ms, samples = analysis_ready(&a)
		if ready {break}
		kit_sleep(5)
	}
	check(ready, "the analysis finishes")
	check(ok, "and succeeds")
	check(
		abs(samples - 3 * WAVE_RATE) < WAVE_RATE / 2,
		"it yields about 16000 samples per second",
	)
	check(ms >= 0, "it reports how long it took")

	// The real signal must land where the synthetic one did.
	bars: [BARS]f32
	if ok {
		check(spectrum(&a, 1.5, bars[:]), "the decoded track produces a spectrum")
		peak := 0
		for k in 0 ..< BARS {
			if bars[k] > bars[peak] {peak = k}
		}
		lo := f32(40)
		hi := f32(WAVE_RATE / 2)
		f0 := lo * math.pow(hi / lo, f32(peak) / f32(BARS))
		f1 := lo * math.pow(hi / lo, f32(peak + 1) / f32(BARS))
		check(1000 >= f0 * 0.8 && 1000 <= f1 * 1.25, "a real 1 kHz tone peaks near 1 kHz")
	}
	analysis_stop(&a)

	// The sink: only run it where PipeWire is available.
	if !kit.has_tool("pw-cat") {
		fmt.println("  skip  pw-cat is not installed; sink checks not run")
		return
	}
	e: Engine
	engine_init(&e)
	engine_set_volume(&e, 0)  // a test should not make a noise
	engine_start(&e, m, 0)
	check(e.live, "the sink pipeline starts")
	check(e.err == "", "with no error")
	for _ in 0 ..< 400 {
		if engine_clock(&e) > 0.2 {break}
		kit_sleep(5)
	}
	t := engine_clock(&e)
	check(t > 0.1, "the byte-count clock advances")
	check(t < m.duration + 1, "and stays inside the track")
	engine_pause(&e, true)
	frozen := engine_clock(&e)
	kit_sleep(120)
	check(abs(engine_clock(&e) - frozen) < 0.02, "pausing freezes the clock")
	engine_stop(&e)
	check(!e.live, "stopping tears the pipeline down")
}

// test_gapless crosses a real track boundary with real processes and checks
// the two claims that cannot be made from pure arithmetic: that the sink was
// never restarted, and that it was never starved.
test_gapless :: proc() {
	if !kit.has_tool("ffmpeg") || !kit.has_tool("ffprobe") {
		fmt.println("  skip  ffmpeg is not installed; gapless checks not run")
		return
	}
	if !kit.has_tool("pw-cat") {
		fmt.println("  skip  pw-cat is not installed; gapless checks not run")
		return
	}
	dir := fmt.tprintf("%s/palmy-audio-gapless", os.temp_dir(context.temp_allocator))
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)
	one := fmt.tprintf("%s/one.mp3", dir)
	two := fmt.tprintf("%s/two.mp3", dir)
	ok1 := false
	ok2 := false
	_, ok1 = kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "sine=frequency=440:duration=5",
			"-b:a", "192k", one,
		},
		context.temp_allocator,
	)
	_, ok2 = kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "sine=frequency=660:duration=5",
			"-b:a", "192k", two,
		},
		context.temp_allocator,
	)
	if !ok1 || !ok2 || !os.exists(one) || !os.exists(two) {
		fmt.println("  skip  could not generate the two test tracks")
		return
	}
	ma := probe_file(one)
	mb := probe_file(two)
	if !ma.ok || !mb.ok {
		fmt.println("  skip  the test tracks would not probe")
		return
	}

	e: Engine
	engine_init(&e)
	engine_set_volume(&e, 0) // a test should not make a noise
	// Start three seconds from the end, so the prefetch has somewhere to fire.
	engine_start(&e, ma, max(0, ma.duration - 3), 0)
	check(e.live, "the gapless pipeline starts")
	check(e.err == "", "with no error")
	if !e.live {
		return
	}
	sink_pid := e.sproc.pid

	armed := false
	flipped := false
	for _ in 0 ..< 1600 {
		engine_tick(&e)
		if !armed && engine_prefetch_due(&e) {
			armed = engine_prefetch(&e, mb, 1)
		}
		if _, tr := engine_position(&e); tr == 1 {
			flipped = true
			break
		}
		if engine_eof(&e) {
			break
		}
		kit_sleep(5)
	}
	check(armed, "the next track's decoder is started about two seconds from the end")
	check(flipped, "and the audible track becomes the next one")
	_, joins := engine_stats(&e)
	check(joins == 1, "the boundary was crossed by promoting a decoder, not restarting one")
	check(!engine_eof(&e), "so the player was never told the stream ended")
	check(e.sproc.pid == sink_pid, "and the sink is the same process it was before the change")

	starve := engine_starvation(&e)
	check(starve >= 0, "the starvation at the boundary was measured")
	check(
		starve < 0.01,
		fmt.tprintf("and the sink went unfed for under 10 ms (%.3f ms)", starve * 1000),
	)
	check(starve < engine_buffered(&e), "which is less than the sink had buffered, so nothing was audible")
	check(engine_clock(&e) < 1.5, "the clock restarts inside the new track")

	// Written bytes keep running across the join rather than resetting.
	written, _ := engine_stats(&e)
	check(written > 3, "the byte count is a running total across both tracks")

	engine_stop(&e)
	check(!e.live && !e.sink_live, "an explicit stop does tear the sink down")
}

kit_sleep :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// ---------------------------------------------------------------------------
// The command surface
//
// Run as real child processes of this binary with a trap first on PATH: fake
// pw-cat, pw-play, pw-record, parec, arecord, paplay, aplay, ffplay, wpctl
// and pactl, each writing to a sentinel. ffmpeg and ffprobe stay real — they
// are how a file is read. Every command is run and the sentinel must stay
// empty: nothing here plays, records or touches a volume.
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
cli_run :: proc(env: []string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	for e in env {
		strings.write_string(&line, e)
		strings.write_byte(&line, ' ')
	}
	strings.write_string(&line, fmt.tprintf("%q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(out: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	check(len(problems) == 0, fmt.tprintf("%s matches its declared schema%s", what, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : ""))
}

test_cli :: proc() {
	fmt.println("the command surface")

	sf := surface()
	check(sf.noun == "audio", "the surface is named audio")
	check(sf.takes_path, "a bare file or folder still opens the window")
	for cmd in sf.commands {
		check(cmd.run != nil, fmt.tprintf("%q has an implementation", cmd.verb))
		check(len(cmd.out) > 0, fmt.tprintf("%q declares what it prints", cmd.verb))
		check(len(cmd.examples) > 0, fmt.tprintf("%q ships an example", cmd.verb))
		if cmd.verb == "shot" {
			check(cmd.effect == .Mutate, "shot is mutate (it writes the PNG it is given)")
		} else {
			check(cmd.effect == .Read, fmt.tprintf("%q is read class", cmd.verb))
		}
		for bad in ([?]string{"play", "record", "volume", "mute", "capture", "listen"}) {
			check(cmd.verb != bad, fmt.tprintf("there is no %q verb", bad))
		}
	}

	root := fmt.tprintf("/tmp/palmy-audio-cli-%d", os.get_pid())
	bin := fmt.tprintf("%s/fakebin", root)
	music := fmt.tprintf("%s/music", root)
	_ = os.make_directory_all(bin)
	_ = os.make_directory_all(music)
	defer _ = os.remove_all(root)
	sentinel := fmt.tprintf("%s/fired", root)
	trap := fmt.tprintf("#!/bin/sh\nprintf '%%s %%s\\n' \"$0\" \"$*\" >> %s\nexit 0\n", sentinel)
	for name in ([?]string{"pw-cat", "pw-play", "pw-record", "parec", "parecord", "arecord", "paplay", "aplay", "ffplay", "wpctl", "pactl"}) {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", bin, name), transmute([]u8)trap, os.Permissions_All)
	}
	path_env := fmt.tprintf("PATH=%s:%s", bin, os.get_env("PATH", context.temp_allocator))
	env := []string{path_env, fmt.tprintf("PALM_AUDIT=%s/audit.jsonl", root)}
	{
		_, _, _, err := os.process_exec({command = {"sh", "-c", fmt.tprintf("%s pw-cat --playback x", path_env)}}, context.temp_allocator)
		check(err == nil && os.exists(sentinel), "the fake pw-cat on PATH is reached (the trap works)")
		os.remove(sentinel)
	}

	{
		out, code := cli_run(env, "--schema")
		check(code == 0 && strings.contains(out, `"noun": "audio"`), "--schema answers")
	}
	for cmd in sf.commands {
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(len(words) > 0 && words[0] == "audio", fmt.tprintf("the example %q starts with the binary's name", ex))
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(env, ..args[:])
			check(code == 0, fmt.tprintf("the example %q parses", ex))
		}
	}

	// An empty folder, and refusals, need no ffmpeg.
	{
		out, code := cli_run(env, "library", music, "--json")
		check(code == 0, "audio library on an empty folder exits 0")
		valid(out, LIBRARY_FIELDS, "audio library --json")
		check(strings.contains(out, `"count": 0`), "and finds nothing")
	}
	{
		out, code := cli_run(env, "probe", fmt.tprintf("%s/nope.mp3", music), "--json")
		check(code == kit.EXIT_NOT_FOUND, "probing a file that is not there exits 3")
		check(strings.contains(out, `"error": "not found"`), "with the documented token")
		_, c2 := cli_run(env, "library", fmt.tprintf("%s/nope", music))
		check(c2 == kit.EXIT_NOT_FOUND, "listing a folder that is not there exits 3")
		_, c3 := cli_run(env, "play", "x.mp3")
		check(c3 != 0, "there is no play command to run")
	}

	if !kit.has_tool("ffmpeg") || !kit.has_tool("ffprobe") {
		fmt.println("  skip  ffmpeg is not installed; the file commands were not run")
		check(!os.exists(sentinel), "nothing played or recorded")
		return
	}
	track := fmt.tprintf("%s/tone.mp3", music)
	_, made := kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "sine=frequency=1000:duration=3",
			"-metadata", "title=CLI Tone", "-metadata", "artist=lavfi",
			"-b:a", "192k", track,
		},
		context.temp_allocator,
	)
	if !made || !os.exists(track) {
		fmt.println("  skip  could not generate a test track")
		return
	}
	_ = os.write_entire_file(fmt.tprintf("%s/notes.txt", music), transmute([]u8)string("not audio"))

	{
		out, code := cli_run(env, "library", music, "--probe", "--json")
		check(code == 0, "audio library --probe exits 0")
		valid(out, LIBRARY_FIELDS, "audio library --probe --json")
		check(strings.contains(out, `"count": 1`), "one track: the text file is not audio")
		check(strings.contains(out, `"title": "CLI Tone"`), "with its tag, read through the window's own prober")
	}
	{
		out, code := cli_run(env, "probe", track, "--json")
		check(code == 0, "audio probe exits 0")
		valid(out, PROBE_FIELDS, "audio probe --json")
		check(strings.contains(out, `"artist": "lavfi"`), "the artist tag")
		check(strings.contains(out, `"duration": 3.`), "about three seconds long")
	}
	{
		out, code := cli_run(env, "analyze", track, "--at", "1.5", "--columns", "16", "--json")
		check(code == 0, "audio analyze exits 0")
		valid(out, ANALYZE_FIELDS, "audio analyze --json")
		// The same check test_engine makes in-process, through the CLI: a
		// 1 kHz tone lands in the bar whose range holds 1 kHz.
		k := -1
		if i := strings.index(out, `"loudest_bar": `); i >= 0 {
			rest := out[i + len(`"loudest_bar": `):]
			k = 0
			for j in 0 ..< len(rest) {
				if rest[j] < '0' || rest[j] > '9' {break}
				k = k * 10 + int(rest[j] - '0')
			}
		}
		hz := bar_hz(k)
		check(k >= 0 && hz > 800 && hz < 1250, fmt.tprintf("the loudest bar is the one around 1 kHz (bar %d, %.0f Hz)", k, hz))
	}
	{
		png := fmt.tprintf("%s/shot.png", root)
		out, code := cli_run(env, "shot", png, "--dir", music, "--json")
		check(code == 0, "audio shot exits 0")
		check(strings.has_prefix(strings.trim_space(out), "{"), "and stdout is the document alone")
		check(os.exists(png), "the PNG was written")
		check(strings.contains(out, `"tracks": 1`), "showing the one track")
	}
	{
		// The window's own spelling still renders, without --json.
		png := fmt.tprintf("%s/legacy.png", root)
		_, code := cli_run(env, music, "--shot", png, "1")
		check(code == 0 && os.exists(png), "audio DIR --shot OUT SECONDS still renders")
	}
	check(!os.exists(sentinel), "no command played, recorded or touched a volume")
}
