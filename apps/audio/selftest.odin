package main

// `audio --selftest` checks the maths behind the picture of the sound — the
// FFT, the peak envelope and its normalisation, the oscilloscope window — plus
// the tag reader and the playlist ordering. A spectrum that is subtly wrong
// still looks like a spectrum, so these are checked against signals whose
// answers are known rather than against a screenshot.

import "core:fmt"
import "core:math"
import "core:os"
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
	test_tags()
	test_formats()
	test_order()
	test_engine()

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
	for k in ([?]int{1, 7, 32, 100, 255}) {
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
	lo := f32(40)
	hi := f32(WAVE_RATE / 2)
	want := -1
	for k in 0 ..< BARS {
		f0 := lo * math.pow(hi / lo, f32(k) / f32(BARS))
		f1 := lo * math.pow(hi / lo, f32(k + 1) / f32(BARS))
		if 1000 >= f0 && 1000 < f1 {
			want = k
		}
	}
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
	n := 4000
	pcm := make([]i16, n)
	defer delete(pcm)
	for i in 0 ..< n {
		pcm[i] = i16(1000 * math.sin(f32(i) * 0.1))
	}
	a := fake_analysis(pcm)
	buf: [256]f32

	check(scope(&a, 0.25, buf[:], 1200), "the scope reads a window")
	peak := f32(0)
	for v in buf {
		peak = max(peak, abs(v))
	}
	check(peak > 0.02 && peak < 0.04, "unity gain gives the samples' own amplitude")

	check(scope(&a, 0.25, buf[:], 1200, 12), "the scope accepts a gain")
	gpeak := f32(0)
	for v in buf {
		gpeak = max(gpeak, abs(v))
	}
	check(gpeak > peak * 10, "the gain is applied")

	// However large the gain, the trace must stay inside the panel.
	check(scope(&a, 0.25, buf[:], 1200, 10000), "an absurd gain is accepted")
	bad := 0
	for v in buf {
		if v < -1 || v > 1 {bad += 1}
	}
	check(bad == 0, "and clamped to the drawable range")

	check(!scope(&a, 0, buf[:], 100000), "a span longer than the track is refused")
	check(scope(&a, 1e6, buf[:], 1200), "a playhead past the end clamps")
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
	check(abs(samples - 3 * WAVE_RATE) < WAVE_RATE / 2, "it yields about 8000 samples per second")
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

kit_sleep :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}
