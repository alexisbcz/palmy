package main

// `video --selftest` checks the parts that decide what gets played and when:
// the ffprobe JSON reader, the frame-rate parser, the timecode formatter, and
// the decode-size arithmetic the whole 1:1 blit depends on. If ffmpeg is on
// PATH it also runs one real clip end to end — generated here, nothing
// downloaded — because the JSON shape is the thing most likely to drift.

import "core:fmt"
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
	} else if verbose {
		fmt.printfln("  ok    %s", what)
	}
}

// PALMY_SELFTEST_VERBOSE=1 prints the passing checks too, with their numbers.
@(private = "file")
verbose: bool

run_selftest :: proc() {
	// The audio clock needs a device whose clock runs. A headless machine has
	// none, so unless the environment names a sink the engine runs against the
	// null sink (sink.odin), a child process that takes PCM at the rate a sound
	// card would.
	if os.get_env("PALMY_AUDIO_SINK", context.temp_allocator) == "" {
		os.set_env("PALMY_AUDIO_SINK", "null")
	}
	verbose = os.get_env("PALMY_SELFTEST_VERBOSE", context.temp_allocator) != ""
	fmt.printfln("the audio clock uses the %v sink", sink_kind())
	test_rate()
	test_timecode()
	test_sizes()
	test_paths()
	test_probe_json()
	test_decode_size()
	test_subs_timecodes()
	test_subs_srt()
	test_subs_vtt()
	test_subs_ass()
	test_cue_lookup()
	test_sidecars()
	test_sub_streams()
	test_chapters()
	test_clock_math()
	test_speed_grid()
	test_pipeline()
	test_container_subs()

	fmt.printfln("video selftest: %d checks, %d failures", checks, failures)
}

// ---------------------------------------------------------------------------

test_rate :: proc() {
	check(parse_rate("30/1") == 30, "30/1 is 30 fps")
	check(abs(parse_rate("30000/1001") - 29.97003) < 1e-4, "30000/1001 is 29.97 fps")
	check(abs(parse_rate("24000/1001") - 23.976) < 1e-3, "24000/1001 is 23.976 fps")
	check(parse_rate("0/0") == 0, "0/0 means unknown")
	check(parse_rate("") == 0, "an empty rate means unknown")
	check(parse_rate("25") == 25, "a bare number is a rate")
	check(parse_rate("1/0") == 0, "a zero denominator does not divide")
	check(parse_rate("nonsense") == 0, "nonsense is unknown, not a crash")
}

test_timecode :: proc() {
	check(timecode(0) == "0:00", "zero")
	check(timecode(9) == "0:09", "seconds are padded")
	check(timecode(61) == "1:01", "a minute and a second")
	check(timecode(599) == "9:59", "just under ten minutes")
	check(timecode(3600) == "1:00:00", "an hour grows a field")
	check(timecode(3661) == "1:01:01", "an hour, a minute and a second")
	check(timecode(-1) == "-:--", "a negative time is not a time")
	check(timecode_ms(1.5) == "0:01.500", "milliseconds")
	check(timecode_ms(3661.25) == "1:01:01.250", "milliseconds past an hour")
	// Truncation, not rounding: 59.999 is still in the 59th second.
	check(timecode(59.999) == "0:59", "a time is truncated to its second")
}

test_sizes :: proc() {
	check(human_bytes(0) == "0 B", "zero bytes")
	check(human_bytes(1023) == "1023 B", "just under a kilobyte")
	check(human_bytes(1024) == "1.0 KB", "a kilobyte")
	check(human_bytes(10 * 1024 * 1024) == "10.0 MB", "ten megabytes")
	check(strings.has_suffix(human_bytes(2 * 1024 * 1024 * 1024), "GB"), "gigabytes")
	check(human_rate(0) == "—", "an unknown bitrate is a dash")
	check(human_rate(128_000) == "128 kb/s", "kilobits")
	check(human_rate(3_500_000) == "3.5 Mb/s", "megabits")
}

test_paths :: proc() {
	check(base_of("/a/b/c.mp4") == "c.mp4", "base_of")
	check(dir_of("/a/b/c.mp4") == "/a/b", "dir_of")
	check(dir_of("c.mp4") == ".", "dir_of of a bare name")
	check(is_video("a.MP4"), "extensions are matched without case")
	check(is_video("a.mkv") && is_video("a.webm") && is_video("a.mov"), "the common containers")
	check(!is_video("a.mp3"), "audio is not video")
	check(!is_video("a.mp4.txt"), "the extension has to be last")
}

// test_probe_json feeds the reader the shape ffprobe actually emits, including
// the two things that bite: numbers delivered as strings, and a cover image
// that is technically a video stream.
test_probe_json :: proc() {
	doc := `{
	  "streams": [
	    { "index": 0, "codec_name": "h264", "codec_type": "video",
	      "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
	      "r_frame_rate": "30000/1001", "avg_frame_rate": "30000/1001",
	      "nb_frames": "900", "bit_rate": "3135982",
	      "disposition": { "attached_pic": 0 } },
	    { "index": 1, "codec_name": "aac", "codec_type": "audio",
	      "channels": 2, "sample_rate": "48000", "bit_rate": "128000",
	      "disposition": { "attached_pic": 0 },
	      "tags": { "title": "From the stream" } }
	  ],
	  "format": {
	    "format_name": "mov,mp4,m4a",
	    "duration": "30.016000", "size": "8036238", "bit_rate": "2141900",
	    "tags": { "TITLE": "Shouty Tag", "artist": "A Person", "date": "2026" }
	  }
	}`
	m := parse_probe(doc, "/tmp/x.mp4")
	check(m.ok, "a well-formed document parses")
	check(m.has_video && m.has_audio, "both streams are found")
	check(m.width == 1920 && m.height == 1080, "resolution comes from the video stream")
	check(abs(m.fps - 29.97003) < 1e-4, "the frame rate is a ratio, not a string")
	check(m.frames == 900, "nb_frames arrives as a string and is read as a number")
	check(abs(m.duration - 30.016) < 1e-6, "duration is read from the format block")
	check(m.size == 8036238, "size is read as a number")
	check(m.channels == 2 && m.sample_rate == 48000, "audio layout")
	check(m.vcodec == "h264" && m.acodec == "aac", "codec names")
	check(m.container == "mov,mp4,m4a", "container name")
	// `TITLE` is upper case here, which some muxers do and a naive reader misses.
	check(m.title == "Shouty Tag", "tags are matched without regard to case")
	check(m.artist == "A Person" && m.date == "2026", "the other tags")
	check(!m.has_cover, "no attached picture in this one")

	// A music file: one audio stream and a cover that must not be taken for video.
	cover := `{
	  "streams": [
	    { "codec_name": "mp3", "codec_type": "audio", "channels": 1,
	      "sample_rate": "44100", "disposition": { "attached_pic": 0 } },
	    { "codec_name": "mjpeg", "codec_type": "video", "width": 600,
	      "height": 600, "disposition": { "attached_pic": 1 } }
	  ],
	  "format": { "format_name": "mp3", "duration": "48.0", "size": "1168645" }
	}`
	c := parse_probe(cover, "/tmp/x.mp3")
	check(c.ok, "an audio-only file parses")
	check(!c.has_video, "an attached picture is not a video stream")
	check(c.has_cover, "it is reported as cover art instead")
	check(c.has_audio && c.channels == 1, "the audio stream is still found")

	// Degenerate inputs must produce an error, not a crash or a half-filled struct.
	bad := parse_probe("{}", "/tmp/x")
	check(!bad.ok && bad.err != "", "an empty document is an error")
	broken := parse_probe("not json at all", "/tmp/x")
	check(!broken.ok, "unparseable input is an error")
	none := parse_probe(`{"streams":[],"format":{"duration":"1"}}`, "/tmp/x")
	check(!none.ok && strings.contains(none.err, "no audio or video"), "a file with no streams")

	// A missing frame rate falls back rather than dividing by zero later.
	norate := parse_probe(
		`{"streams":[{"codec_type":"video","width":2,"height":2,"r_frame_rate":"0/0"}],"format":{"duration":"1"}}`,
		"/tmp/x",
	)
	check(norate.ok && norate.fps > 0, "an unknown frame rate falls back to something usable")
}

test_decode_size :: proc() {
	st := St{}
	st.e.m = Media {
		has_video = true,
		width     = 1920,
		height    = 1080,
	}

	// A 16:9 source in a 16:9 box fills it exactly.
	st.vrect = {0, 0, 960, 540}
	w, h := decode_size(&st)
	check(w == 960 && h == 540, "a matching aspect uses the whole box")

	// A taller box letterboxes: width wins.
	st.vrect = {0, 0, 960, 1000}
	w, h = decode_size(&st)
	check(w == 960, "the limiting axis is the width here")
	check(abs(h - 540) <= 2, "the height follows the aspect")

	// Every size is even, because chroma subsampling hates odd ones.
	bad := 0
	for width in 100 ..< 400 {
		st.vrect = {0, 0, f32(width), f32(width)}
		ww, hh := decode_size(&st)
		if ww % 2 != 0 || hh % 2 != 0 {
			bad += 1
		}
		if ww > 1920 || hh > 1200 {
			bad += 1
		}
	}
	check(bad == 0, "every decode size is even and inside the cap")

	// A box too small to be a picture is refused rather than asking ffmpeg for
	// a 0-pixel scale.
	st.vrect = {0, 0, 4, 4}
	w, h = decode_size(&st)
	check(w == 0 || (w >= 16 && h >= 16), "a tiny box is either refused or clamped up")

	// No stream, no size.
	st.e.m.width = 0
	st.vrect = {0, 0, 960, 540}
	w, h = decode_size(&st)
	check(w == 0 && h == 0, "a file with no video has no decode size")
}

// test_pipeline runs one real clip through ffmpeg, pw-cat and the engine. It is
// skipped when ffmpeg is missing, because the rest of the suite is pure.
test_pipeline :: proc() {
	if !kit.has_tool("ffmpeg") || !kit.has_tool("ffprobe") {
		fmt.println("  skip  ffmpeg is not installed; pipeline checks not run")
		return
	}
	dir := fmt.tprintf("%s/palmy-video-selftest", os.temp_dir(context.temp_allocator))
	_ = os.make_directory_all(dir)
	clip := fmt.tprintf("%s/bars.mp4", dir)
	defer _ = os.remove_all(dir)

	_, made := kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2",
			"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
			"-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
			"-c:a", "aac", "-shortest", clip,
		},
		context.temp_allocator,
	)
	if !made || !os.exists(clip) {
		fmt.println("  skip  could not generate a test clip")
		return
	}

	m := probe_file(clip)
	check(m.ok, "a generated clip probes cleanly")
	check(m.width == 320 && m.height == 180, "probe reports the real resolution")
	check(abs(m.fps - 25) < 0.01, "probe reports the real frame rate")
	check(m.has_audio, "probe finds the audio stream")
	check(abs(m.duration - 2) < 0.2, "probe reports the real duration")

	e: Engine
	engine_init(&e, m)
	defer engine_destroy(&e)
	engine_open(&e, 0, 320, 180)
	check(e.have_video, "the video pipeline starts")

	// Wait for a frame rather than assuming one: ffmpeg takes a moment to open.
	got := false
	for _ in 0 ..< 400 {
		if engine_take(&e, 1e9) {
			got = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	check(got, "a frame arrives through the pipe")

	px, fw, fh := engine_frame(&e)
	check(px != nil, "the frame has pixels")
	check(fw == 320 && fh == 180, "the frame is the size we asked ffmpeg for")
	if px != nil {
		// testsrc2 opens on saturated colour bars, so a decoded frame cannot
		// be uniform — and alpha must be opaque, or the blit would be a no-op.
		distinct_cols := 0
		seen: [8]u32
		for i in 0 ..< min(len(px), fw * fh) {
			v := px[i] & 0x00ffffff
			found := false
			for j in 0 ..< distinct_cols {
				if seen[j] == v {found = true}
			}
			if !found && distinct_cols < 8 {
				seen[distinct_cols] = v
				distinct_cols += 1
			}
		}
		check(distinct_cols > 1, "the decoded frame is not a flat colour")
		check(px[0] >> 24 == 0xff, "bgra gives an opaque alpha byte")
	}
	check(e.cur_pts >= 0 && e.cur_pts < m.duration + 1, "the frame carries a sane timestamp")
}

// ---------------------------------------------------------------------------
// Subtitles
// ---------------------------------------------------------------------------

test_subs_timecodes :: proc() {
	cases := [?]struct {
		text: string,
		want: f64,
	} {
		{"00:00:00,000", 0},
		{"00:00:00,500", 0.5}, // sub-second
		{"00:00:00.083", 0.083}, // two frames at 24 fps
		{"01:02:03,004", 3723.004}, // over an hour
		{"10:00:00,000", 36000},
		{"00:01.500", 1.5}, // VTT, no hours field
		{"1:02:03.45", 3723.45}, // ASS, one-digit hour, centiseconds
		{"0:00:00.07", 0.07},
		{"99:59:59,999", 359999.999},
	}
	for c in cases {
		got, ok := parse_timecode(c.text)
		check(ok && abs(got - c.want) < 1e-4, fmt.tprintf("timecode %s reads as %g", c.text, c.want))
	}
	_, bad := parse_timecode("not a time")
	check(!bad, "garbage is not a timecode")
	_, bad2 := parse_timecode("")
	check(!bad2, "an empty string is not a timecode")
	_, bad3 := parse_timecode("00:00:01,")
	check(!bad3, "a separator with no digits after it is not a timecode")
	check(format_srt_time(3723.004) == "01:02:03,004", "SRT time formats back")
	check(format_srt_time(0.5) == "00:00:00,500", "a sub-second SRT time formats back")
	// Round trip every case through the writer and the reader again.
	rt := 0
	for c in cases {
		if v, ok := parse_timecode(c.text); ok {
			if again, ok2 := parse_timecode(format_srt_time(v)); ok2 && abs(again - v) < 1e-3 {
				rt += 1
			}
		}
	}
	check(rt == len(cases), "every timecode round-trips through SRT")
}

test_subs_srt :: proc() {
	srt := `1
00:00:00,250 --> 00:00:02,000
Hello <i>there</i>
second line

2
01:00:01,500 --> 01:00:04,750
Over an hour in
`
	cues, format, ok := parse_subs("x.srt", srt)
	defer {
		for c in cues {delete(c.text)}
		delete(cues)
	}
	check(ok && format == .SRT, "SRT is detected and parsed")
	check(len(cues) == 2, "two SRT cues")
	if len(cues) != 2 {
		return
	}
	check(abs(cues[0].start - 0.25) < 1e-6, "an SRT sub-second start")
	check(abs(cues[0].end - 2.0) < 1e-6, "an SRT end")
	check(
		cues[0].text == "Hello there\nsecond line",
		fmt.tprintf("SRT markup stripped and lines kept, got %q", cues[0].text),
	)
	check(abs(cues[1].start - 3601.5) < 1e-6, "an SRT start over an hour in")
	check(abs(cues[1].end - 3604.75) < 1e-6, "an SRT end over an hour in")

	// A body with no cue at all is a failure, not an empty success.
	none, _, nok := parse_subs("x.srt", "this is not a subtitle file")
	delete(none)
	check(!nok, "a file with no cues does not parse")
}

test_subs_vtt :: proc() {
	// CRLF, a NOTE block, a cue identifier, cue settings after the end time,
	// and a <v Speaker> tag: everything a browser-written VTT puts in the way.
	vtt := "WEBVTT\r\n\r\nNOTE a comment\r\n\r\nintro\r\n00:00.120 --> 00:02.400 align:start position:10%\r\nFirst cue\r\n\r\n01:00:00.001 --> 01:00:02.000\r\n<v Speaker>Past the hour\r\n"
	cues, format, ok := parse_subs("x.vtt", vtt)
	defer {
		for c in cues {delete(c.text)}
		delete(cues)
	}
	check(ok && format == .VTT, "WebVTT is detected and parsed")
	check(len(cues) == 2, "two VTT cues")
	if len(cues) != 2 {
		return
	}
	check(abs(cues[0].start - 0.12) < 1e-6, "a VTT sub-second start with no hours field")
	check(abs(cues[0].end - 2.4) < 1e-6, "a VTT end with cue settings after it")
	check(cues[0].text == "First cue", fmt.tprintf("VTT text, got %q", cues[0].text))
	check(abs(cues[1].start - 3600.001) < 1e-4, "a VTT millisecond past the hour")
	check(
		cues[1].text == "Past the hour",
		fmt.tprintf("the VTT voice tag is stripped, got %q", cues[1].text),
	)

	// Sniffed rather than named: an embedded track arrives with no filename.
	sn, sf, sok := parse_subs("", vtt)
	defer {
		for c in sn {delete(c.text)}
		delete(sn)
	}
	check(sok && sf == .VTT, "VTT is recognised from its header with no filename")
}

test_subs_ass :: proc() {
	// The Format line reorders the columns, which is legal and which a reader
	// that assumes Start/End are fields 1 and 2 gets wrong.
	ass := `[Script Info]
Title: test

[V4+ Styles]
Format: Name, Fontname
Style: Default,Geist

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.33,0:00:02.00,Default,,0,0,0,,{\pos(10,10)}Styled, with a comma
Dialogue: 0,1:30:00.05,1:30:03.00,Default,,0,0,0,,Line one\NLine two
`
	cues, format, ok := parse_subs("x.ass", ass)
	defer {
		for c in cues {delete(c.text)}
		delete(cues)
	}
	check(ok && format == .ASS, "ASS is detected and parsed")
	check(len(cues) == 2, "two ASS cues")
	if len(cues) != 2 {
		return
	}
	check(abs(cues[0].start - 0.33) < 1e-6, "an ASS centisecond start")
	check(abs(cues[0].end - 2.0) < 1e-6, "an ASS end")
	check(
		cues[0].text == "Styled, with a comma",
		fmt.tprintf("the {\\pos} block goes and the comma stays, got %q", cues[0].text),
	)
	check(abs(cues[1].start - 5400.05) < 1e-6, "an ASS start past ninety minutes")
	check(
		cues[1].text == "Line one\nLine two",
		fmt.tprintf("ASS \\N is a newline, got %q", cues[1].text),
	)

	// A reordered Format line, to prove the columns are really looked up.
	re := `[Events]
Format: Text, Start, End
Dialogue: hello,0:00:01.00,0:00:02.00
`
	rc, _, rok := parse_subs("x.ass", re)
	defer {
		for c in rc {delete(c.text)}
		delete(rc)
	}
	check(rok && len(rc) == 1, "a reordered ASS Format line still parses")
	if len(rc) == 1 {
		check(abs(rc[0].start - 1) < 1e-6 && rc[0].text == "hello", "the columns came from the Format line")
	}

	// `.ssa` is the same dialect under an older name.
	sc_, sf, sok := parse_subs("x.ssa", ass)
	defer {
		for c in sc_ {delete(c.text)}
		delete(sc_)
	}
	check(sok && sf == .ASS, ".ssa is read as ASS")
}

// test_cue_lookup pins the one piece of subtitle code that runs sixty times a
// second: which cue covers a clock reading. The boundary cases are the whole
// point — a cue must appear exactly at its start, disappear exactly at its end,
// and a gap must really be empty.
test_cue_lookup :: proc() {
	cues := []Cue {
		{start = 1.0, end = 2.0, text = "one"},
		{start = 2.0, end = 3.0, text = "two"}, // butts against the first
		{start = 5.0, end = 6.0, text = "three"}, // after a two-second gap
	}
	md := cues_max_dur(cues)
	check(abs(md - 1.0) < 1e-9, "the longest cue is one second")

	check(cue_index_at(cues, 0.5, -1, md) == -1, "before the first cue there is nothing")
	check(cue_index_at(cues, 1.5, -1, md) == 0, "inside the first cue")
	// Exactly on a boundary: [start, end), so 2.0 belongs to the second cue and
	// only to the second cue.
	check(cue_index_at(cues, 1.0, -1, md) == 0, "exactly on a cue's start it is showing")
	check(cue_index_at(cues, 2.0, -1, md) == 1, "exactly on the shared boundary the later cue wins")
	check(cue_index_at(cues, 3.0, -1, md) == -1, "exactly on the last end it has gone")
	check(cue_index_at(cues, 4.0, -1, md) == -1, "in the gap between cues there is nothing")
	check(cue_index_at(cues, 5.5, -1, md) == 2, "inside the last cue")
	check(cue_index_at(cues, 99.0, -1, md) == -1, "past the end there is nothing")
	check(cue_index_at(nil, 1.0, -1, md) == -1, "an empty cue list answers nothing")

	// A stale hint must not be believed, and a good one must be.
	check(cue_index_at(cues, 5.5, 0, md) == 2, "a stale cursor is rechecked, not trusted")
	check(cue_index_at(cues, 1.5, 0, md) == 0, "a good cursor is believed")
	check(cue_index_at(cues, 1.5, 99, md) == 0, "a cursor out of range is ignored")

	// Overlapping cues: the one that started last is the one drawn, and the
	// lookback has to be long enough to find a cue that started well before.
	ov := []Cue {
		{start = 0.0, end = 10.0, text = "long"},
		{start = 4.0, end = 5.0, text = "short"},
	}
	ovd := cues_max_dur(ov)
	check(cue_index_at(ov, 4.5, -1, ovd) == 1, "the later of two overlapping cues wins")
	check(cue_index_at(ov, 8.0, -1, ovd) == 0, "a long cue is still found after a short one ended")

	// Every reading over a stepped sweep, with the cursor carried forward the
	// way the player carries it, must agree with a plain linear scan.
	cursor := -1
	mismatch := 0
	for i in 0 ..< 1400 {
		t := f64(i) * 0.005
		want := -1
		for c, ci in cues {
			if c.start <= t && t < c.end {
				want = ci
			}
		}
		got := cue_index_at(cues, t, cursor, md)
		cursor = got
		if got != want {
			mismatch += 1
		}
	}
	check(mismatch == 0, fmt.tprintf("the cached cursor agrees with a linear scan everywhere (%d off)", mismatch))
}

test_sidecars :: proc() {
	check(strip_ext("/a/b/movie.mkv") == "/a/b/movie", "strip_ext drops the extension")
	check(strip_ext("/a/b/movie") == "/a/b/movie", "strip_ext leaves a name with no extension")
	// A dot in the folder must not be mistaken for the file's extension.
	check(strip_ext("/a.b/movie") == "/a.b/movie", "strip_ext only looks at the basename")

	names := []string {
		"other.srt",
		"movie.en.srt",
		"movie.txt",
		"movie.vtt",
		"movie.srt",
		"movie.fr.vtt",
		"moviexsrt",
		"movie.ass",
	}
	got := sidecar_matches(names, "movie", context.temp_allocator)
	check(len(got) == 5, fmt.tprintf("five sidecars belong to this file, got %d", len(got)))
	if len(got) >= 3 {
		// Plain names first, and .srt ahead of .vtt ahead of .ass.
		check(got[0] == "movie.srt", fmt.tprintf("the plain .srt is preferred, got %s", got[0]))
		check(got[1] == "movie.vtt", fmt.tprintf("then the plain .vtt, got %s", got[1]))
		check(got[2] == "movie.ass", fmt.tprintf("then the plain .ass, got %s", got[2]))
	}
	tagged := 0
	for g in got {
		if g == "movie.en.srt" || g == "movie.fr.vtt" {
			tagged += 1
		}
	}
	check(tagged == 2, "the language-tagged sidecars are found too")
	for g in got {
		check(g != "other.srt" && g != "movie.txt" && g != "moviexsrt", fmt.tprintf("%s is not a sidecar for this file", g))
	}
	check(sub_lang_of("movie.en.srt", "movie") == "en", "the language comes out of the name")
	check(sub_lang_of("movie.srt", "movie") == "", "a plain sidecar has no language")

	// Bitmap codecs are the ones that cannot become text, and the check is
	// case-insensitive because ffprobe has not always been consistent.
	check(is_bitmap_sub("dvd_subtitle"), "dvd_subtitle is a bitmap format")
	check(is_bitmap_sub("hdmv_pgs_subtitle"), "hdmv_pgs_subtitle is a bitmap format")
	check(is_bitmap_sub("dvb_subtitle"), "dvb_subtitle is a bitmap format")
	check(is_bitmap_sub("DVD_SUBTITLE"), "the codec name is matched without case")
	check(!is_bitmap_sub("subrip"), "subrip is text")
	check(!is_bitmap_sub("ass") && !is_bitmap_sub("mov_text") && !is_bitmap_sub("webvtt"), "the text formats are text")

	// A bitmap track is refused before ffmpeg is ever asked, and says why.
	bt := Sub_Track {
		src    = .Embedded,
		index  = 3,
		codec  = "hdmv_pgs_subtitle",
		bitmap = true,
	}
	check(!subs_load(&bt), "a bitmap track refuses to load")
	check(strings.contains(bt.err, "bitmap"), fmt.tprintf("and says why, got %q", bt.err))
	check(len(bt.cues) == 0, "and produces no cues")
	delete(bt.err)

	// A track that is asked for twice is only attempted once: `tried` is what
	// stops a failing extraction being retried every frame.
	bt2 := Sub_Track {
		src    = .Embedded,
		codec  = "dvd_subtitle",
		bitmap = true,
	}
	check(!subs_load(&bt2) && bt2.tried, "a failed load is remembered")
	check(!subs_load(&bt2), "and is not retried")
	delete(bt2.err)
}

// test_speed_grid checks the stepping arithmetic without a pipeline: a speed
// off the grid snaps onto it, and the range is a hard clamp.
test_speed_grid :: proc() {
	e: Engine
	engine_init(&e, Media{duration = 10})
	check(engine_speed(&e) == 1, "a new engine plays at 1x")
	check(engine_set_speed(&e, 1.25) && abs(engine_speed(&e) - 1.25) < 1e-9, "a step up")
	check(engine_set_speed(&e, 0.5) && abs(engine_speed(&e) - 0.5) < 1e-9, "down to the floor")
	check(!engine_set_speed(&e, 0.2), "below the floor is not a change")
	check(abs(engine_speed(&e) - 0.5) < 1e-9, "and the floor holds")
	check(engine_set_speed(&e, 9) && abs(engine_speed(&e) - 2.0) < 1e-9, "above the ceiling clamps to 2x")
	// Off the grid: repeated nudges must not drift onto 1.1x and stay there.
	engine_set_speed(&e, 1.12)
	check(abs(engine_speed(&e) - 1.0) < 1e-9, fmt.tprintf("1.12x snaps to 1x, got %g", engine_speed(&e)))
	engine_set_speed(&e, 1.2)
	check(abs(engine_speed(&e) - 1.25) < 1e-9, fmt.tprintf("1.2x snaps to 1.25x, got %g", engine_speed(&e)))
	on_grid := 0
	for k in 0 ..= 8 {
		engine_set_speed(&e, SPEED_MIN + f64(k) * SPEED_STEP)
		v := engine_speed(&e)
		if abs(v / SPEED_STEP - f64(int(v / SPEED_STEP + 0.5))) < 1e-9 && v >= SPEED_MIN && v <= SPEED_MAX {
			on_grid += 1
		}
	}
	check(on_grid == 9, fmt.tprintf("every speed stays on the grid and in range (%d/9)", on_grid))
}

// test_sub_streams feeds the reader a container with four subtitle streams, one
// of which is a picture format that must be listed as unsupported rather than
// handed to ffmpeg and silently producing nothing.
test_sub_streams :: proc() {
	doc := `{
	  "streams": [
	    { "index": 0, "codec_name": "h264", "codec_type": "video",
	      "width": 1920, "height": 1080, "r_frame_rate": "30/1" },
	    { "index": 1, "codec_name": "aac", "codec_type": "audio",
	      "channels": 2, "sample_rate": "48000" },
	    { "index": 2, "codec_name": "subrip", "codec_type": "subtitle",
	      "tags": { "language": "eng", "title": "English" } },
	    { "index": 3, "codec_name": "ass", "codec_type": "subtitle",
	      "tags": { "LANGUAGE": "jpn" } },
	    { "index": 4, "codec_name": "hdmv_pgs_subtitle", "codec_type": "subtitle",
	      "tags": { "language": "eng", "title": "Forced" } },
	    { "index": 5, "codec_name": "mov_text", "codec_type": "subtitle" }
	  ],
	  "format": { "format_name": "matroska", "duration": "120.0", "size": "100" }
	}`
	m := parse_probe(doc, "/tmp/x.mkv")
	check(m.ok, "a document with subtitle streams parses")
	check(len(m.subs) == 4, fmt.tprintf("four subtitle streams, got %d", len(m.subs)))
	if len(m.subs) != 4 {
		return
	}
	check(m.subs[0].index == 2, "the stream index is the ffmpeg index, not the position in the list")
	check(m.subs[0].codec == "subrip" && m.subs[0].lang == "eng", "the codec and language")
	check(m.subs[0].title == "English", "the stream title")
	check(!m.subs[0].bitmap, "subrip is not a bitmap track")
	check(m.subs[1].lang == "jpn", "an upper-case LANGUAGE tag is still read")
	check(m.subs[1].title == "", "a stream with no title has none")
	check(m.subs[2].index == 4 && m.subs[2].bitmap, "the PGS stream is flagged as a bitmap track")
	check(m.subs[3].index == 5 && !m.subs[3].bitmap, "mov_text is text")

	// No subtitle streams at all is an empty list, not a nil surprise.
	plain := parse_probe(
		`{"streams":[{"index":0,"codec_type":"video","width":2,"height":2,"r_frame_rate":"25/1"}],"format":{"duration":"1"}}`,
		"/tmp/x.mp4",
	)
	check(plain.ok && len(plain.subs) == 0, "a file with no subtitle streams has an empty list")
}

// test_chapters feeds the chapter reader a document. The second chapter has no
// `start_time`, so the time base has to be used; the third has no title, so one
// has to be invented; and the list arrives out of order.
test_chapters :: proc() {
	doc := `{
	  "chapters": [
	    { "id": 0, "time_base": "1/1000", "start": 0, "end": 5000,
	      "start_time": "0.000000", "end_time": "5.000000",
	      "tags": { "title": "Opening" } },
	    { "id": 2, "time_base": "1/1000", "start": 12500, "end": 20000,
	      "start_time": "12.500000", "end_time": "20.000000" },
	    { "id": 1, "time_base": "1/1000", "start": 5000, "end": 12500,
	      "tags": { "TITLE": "The Middle" } }
	  ]
	}`
	chs := parse_chapters(doc)
	check(len(chs) == 3, fmt.tprintf("three chapters, got %d", len(chs)))
	if len(chs) != 3 {
		return
	}
	check(abs(chs[0].start) < 1e-9 && abs(chs[0].end - 5) < 1e-9, "the first chapter's times")
	check(chs[0].title == "Opening", fmt.tprintf("the first chapter's title, got %q", chs[0].title))
	// Sorted by start time, so the out-of-order middle chapter is second.
	check(abs(chs[1].start - 5) < 1e-9, "the chapters come back in time order")
	check(chs[1].title == "The Middle", fmt.tprintf("an upper-case TITLE tag is read, got %q", chs[1].title))
	check(abs(chs[1].end - 12.5) < 1e-9, "a chapter with no start_time falls back to the time base")
	check(chs[2].title == "Chapter 3", fmt.tprintf("an untitled chapter is numbered, got %q", chs[2].title))

	check(chapter_at(chs, 0) == 0, "time zero is in the first chapter")
	check(chapter_at(chs, 4.99) == 0, "just before the boundary")
	check(chapter_at(chs, 5.0) == 1, "exactly on the boundary is the next chapter")
	check(chapter_at(chs, 19) == 2, "inside the last chapter")
	check(chapter_at(chs, 1e6) == 2, "past the end is still the last chapter")

	// Jumping. Forward is the next start; back rewinds to this chapter's start
	// unless we only just entered it.
	t, ok := chapter_seek_target(chs, 1, 1)
	check(ok && abs(t - 5) < 1e-9, "next chapter from the first")
	t, ok = chapter_seek_target(chs, 19, 1)
	check(!ok, "there is no chapter after the last one")
	t, ok = chapter_seek_target(chs, 10, -1)
	check(ok && abs(t - 5) < 1e-9, "back rewinds to the current chapter's start")
	t, ok = chapter_seek_target(chs, 6, -1)
	check(ok && abs(t) < 1e-9, "back from just inside a chapter goes to the previous one")
	_, ok = chapter_seek_target(nil, 10, 1)
	check(!ok, "a file with no chapters cannot jump")

	// A file whose first chapter starts late: before it there is no chapter.
	late := parse_chapters(`{"chapters":[{"start_time":"2.0","end_time":"4.0","tags":{"title":"Late"}}]}`)
	check(len(late) == 1 && chapter_at(late, 1) == -1, "before the first chapter there is no chapter")

	check(len(parse_chapters(`{"format":{}}`)) == 0, "a document with no chapters block has no chapters")
	check(len(parse_chapters("not json")) == 0, "an unparseable document has no chapters")
}

// ---------------------------------------------------------------------------
// The clock
// ---------------------------------------------------------------------------

// test_clock_math asserts the one expression the whole player hangs on:
//
//	clock = base + (bytes / BPS − lat) · speed
//
// `bytes / BPS` and `lat` are both *output* seconds — atempo leaves the sample
// rate at 48 kHz, so the sound card drains them at one second per second no
// matter the speed — and one output second carries `speed` seconds of media.
// The scale therefore belongs outside the subtraction. The two plausible wrong
// versions are pinned here as well, because both are right at 1x and only
// diverge where it is hard to see.
test_clock_math :: proc() {
	one_sec := i64(AUDIO_BPS) // exactly one second of PCM
	check(abs(clock_from_bytes(0, 0, 0, 1) - 0) < 1e-12, "nothing played is the start")
	check(abs(clock_from_bytes(10, 0, 0, 2) - 10) < 1e-12, "nothing played is the start at 2x too")
	check(abs(clock_from_bytes(0, one_sec, 0, 1) - 1) < 1e-12, "a second of PCM is a second at 1x")
	check(abs(clock_from_bytes(0, one_sec, 0, 2) - 2) < 1e-12, "a second of PCM is two seconds at 2x")
	check(abs(clock_from_bytes(0, one_sec, 0, 0.5) - 0.5) < 1e-12, "a second of PCM is half a second at 0.5x")

	// With a measured 100 ms of sink buffering, from media position 10 s.
	lat := 0.100
	check(abs(clock_from_bytes(10, one_sec, lat, 1.0) - 10.9) < 1e-9, "1x with 100 ms of sink buffering")
	check(abs(clock_from_bytes(10, one_sec, lat, 2.0) - 11.8) < 1e-9, "2x with 100 ms of sink buffering")
	check(abs(clock_from_bytes(10, one_sec, lat, 0.5) - 10.45) < 1e-9, "0.5x with 100 ms of sink buffering")

	// The wrong one: scaling the bytes but not the latency. Right at 1x, 100 ms
	// out at 2x, 50 ms out the other way at 0.5x.
	wrong_a :: proc(base: f64, bytes: i64, lat, speed: f64) -> f64 {
		return base + f64(bytes) / f64(AUDIO_BPS) * speed - lat
	}
	check(
		abs(wrong_a(10, one_sec, lat, 1) - clock_from_bytes(10, one_sec, lat, 1)) < 1e-12,
		"leaving the latency unscaled is indistinguishable at 1x",
	)
	check(
		abs(wrong_a(10, one_sec, lat, 2) - clock_from_bytes(10, one_sec, lat, 2)) > 0.09,
		"leaving the latency unscaled is 100 ms wrong at 2x",
	)
	// The other wrong one: not scaling at all, which stalls the picture.
	wrong_b :: proc(base: f64, bytes: i64, lat, speed: f64) -> f64 {
		return base + f64(bytes) / f64(AUDIO_BPS) - lat
	}
	check(
		abs(wrong_b(10, one_sec, lat, 2) - clock_from_bytes(10, one_sec, lat, 2)) > 0.8,
		"not scaling at all is a second wrong after a second at 2x",
	)

	// Properties that have to hold at every speed on the grid.
	bad := 0
	for step in 2 ..= 8 {
		sp := f64(step) * 0.25
		// Monotonic in bytes: more sound accepted can never move the clock back.
		prev := clock_from_bytes(3, 0, lat, sp)
		for k in 1 ..= 40 {
			cur := clock_from_bytes(3, i64(k) * one_sec / 10, lat, sp)
			if cur < prev {
				bad += 1
			}
			prev = cur
		}
		// A second of wall time at the sink is `sp` seconds of media.
		d := clock_from_bytes(3, one_sec, lat, sp) - clock_from_bytes(3, 0, lat, sp)
		if abs(d - sp) > 1e-9 {
			bad += 1
		}
		// The clock at zero bytes is behind `base` by the buffering, in media
		// time: that is what stops the picture running ahead of the sound.
		if abs((3 - clock_from_bytes(3, 0, lat, sp)) - lat * sp) > 1e-9 {
			bad += 1
		}
	}
	check(bad == 0, fmt.tprintf("the clock holds its properties at every speed (%d violations)", bad))

	// Coasting: the bounded wall-clock fill between two byte-count updates.
	//
	// pw-cat accepts bytes in bursts, so the byte count stands still for tens
	// of milliseconds and then jumps several chunks. Scheduled straight
	// against that, a 60 fps picture finds no frame due on one poll and three
	// on the next — measured at 1x against a 60 Hz poll, 160 of 717 frames
	// discarded while the decoder delivered 60.2 fps. Coasting cut that to 32.
	//
	// What makes it safe is the cap, and these are the properties the cap has
	// to have.
	frame := 1.0 / 60
	check(abs(clock_coast(5, 0, 1, frame) - 5) < 1e-12, "no gap, no fill")
	check(
		abs(clock_coast(5, 0.004, 1, frame) - 5.004) < 1e-12,
		"a gap shorter than the cap is filled in full",
	)
	check(
		abs(clock_coast(5, 0.004, 2, frame) - 5.008) < 1e-12,
		"and wall seconds become media seconds at the speed",
	)
	check(
		abs(clock_coast(5, 10, 1, frame) - (5 + frame)) < 1e-12,
		"a long gap is capped at one frame, however long it is",
	)
	check(
		abs(clock_coast(5, 10, 2, frame) - (5 + frame)) < 1e-12,
		"the cap is in media time, so it is the same cap at 2x",
	)
	check(clock_coast(5, -1, 1, frame) == 5, "a gap that went backwards fills nothing")
	check(clock_coast(5, 1, 1, 0) == 5, "no cap, no coasting")

	// The property that matters more than any single value: coasting adds a
	// bounded offset and never a slope, so a clock left coasting cannot drift.
	// Ten minutes of gap is worth exactly as much as one frame of it.
	drift := 0
	for sp in ([?]f64{0.5, 1, 1.5, 2}) {
		short := clock_coast(0, 0.05, sp, frame)
		long := clock_coast(0, 600, sp, frame)
		if abs(short - long) > 1e-12 {
			drift += 1
		}
		if long > frame + 1e-12 {
			drift += 1
		}
	}
	check(drift == 0, "coasting is an offset, never a slope, at every speed")

	// And it can never put the picture more than one frame ahead of the sound,
	// which is the whole justification for doing it at all.
	ahead := 0
	for sp in ([?]f64{0.5, 1, 1.5, 2}) {
		for g in ([?]f64{0, 0.001, 0.008, 0.02, 0.5}) {
			if clock_coast(0, g, sp, frame) - 0 > frame + 1e-12 {
				ahead += 1
			}
		}
	}
	check(ahead == 0, "coasting never runs more than one frame ahead")

	// The grid the keys walk.
	check(SPEED_MIN == 0.5 && SPEED_MAX == 2.0 && SPEED_STEP == 0.25, "the speed range is 0.5x to 2x in quarters")
	steps := int((SPEED_MAX - SPEED_MIN) / SPEED_STEP) + 1
	check(steps == 7, fmt.tprintf("seven speeds on the grid, got %d", steps))
}

// ---------------------------------------------------------------------------

// test_container_subs builds a container that has everything the subtitle and
// chapter code has to survive — an embedded text track, a sidecar beside it and
// three chapters — and runs the real discovery, the real ffmpeg extraction and
// the real engine at a non-unity speed over it. Generated here; nothing
// downloaded, nothing of the user's.
test_container_subs :: proc() {
	if !kit.has_tool("ffmpeg") || !kit.has_tool("ffprobe") {
		fmt.println("  skip  ffmpeg is not installed; container checks not run")
		return
	}
	dir := fmt.tprintf("%s/palmy-video-subtest", os.temp_dir(context.temp_allocator))
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)

	srt := `1
00:00:00,500 --> 00:00:02,000
<i>Embedded</i> cue one

2
00:00:02,500 --> 00:00:04,000
Embedded cue two
`
	if os.write_entire_file(fmt.tprintf("%s/embed.srt", dir), transmute([]u8)srt) != nil {
		fmt.println("  skip  could not write the subtitle fixture")
		return
	}
	meta := `;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=6000
title=Closing
`
	_ = os.write_entire_file(fmt.tprintf("%s/meta.txt", dir), transmute([]u8)meta)

	clip := fmt.tprintf("%s/subs-clip.mkv", dir)
	_, made := kit.run(
		{
			"ffmpeg", "-y", "-v", "error",
			"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=6",
			"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
			"-i", fmt.tprintf("%s/embed.srt", dir),
			"-i", fmt.tprintf("%s/meta.txt", dir),
			"-map", "0:v", "-map", "1:a", "-map", "2:s", "-map_metadata", "3",
			"-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
			"-c:a", "aac", "-c:s", "srt",
			"-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English",
			"-shortest", clip,
		},
		context.temp_allocator,
	)
	if !made || !os.exists(clip) {
		fmt.println("  skip  could not build a clip with subtitles and chapters")
		return
	}

	// A sidecar beside it, in a different dialect so the two cannot be confused.
	vtt := "WEBVTT\n\n00:01.000 --> 00:03.000\nSidecar line\n"
	_ = os.write_entire_file(fmt.tprintf("%s/subs-clip.vtt", dir), transmute([]u8)vtt)

	m := probe_file(clip)
	check(m.ok, "the clip probes")
	check(len(m.subs) == 1, fmt.tprintf("one embedded subtitle stream, got %d", len(m.subs)))
	if len(m.subs) == 1 {
		check(m.subs[0].lang == "eng", fmt.tprintf("the stream language, got %q", m.subs[0].lang))
		check(!m.subs[0].bitmap, "a real srt stream is text")
	}
	check(len(m.chapters) == 3, fmt.tprintf("three chapters out of the real container, got %d", len(m.chapters)))
	if len(m.chapters) == 3 {
		check(m.chapters[0].title == "Opening", fmt.tprintf("the first chapter's title, got %q", m.chapters[0].title))
		check(abs(m.chapters[1].start - 2) < 0.05, "the second chapter starts where the metadata said")
		check(m.chapters[2].title == "Closing", "the last chapter's title")
	}

	subs: Subs
	subs_build(&subs, m)
	defer subs_free(&subs)
	check(len(subs.tracks) == 2, fmt.tprintf("the sidecar and the stream are both found, got %d", len(subs.tracks)))
	check(subs.active == 0, "the sidecar is selected first")
	if len(subs.tracks) == 2 {
		check(subs.tracks[0].src == .Sidecar, "the sidecar comes first")
		check(subs.tracks[1].src == .Embedded, "then the embedded stream")
		// The sidecar's cues, parsed off disk.
		txt, has := subs_text_at(&subs, 2.0)
		check(has && txt == "Sidecar line", fmt.tprintf("the sidecar's cue is live at 2 s, got %q", txt))
		_, gap := subs_text_at(&subs, 5.0)
		check(!gap, "and nothing after it ends")

		// Now the embedded one, which means a real `ffmpeg -f srt -` run.
		ok := subs_select(&subs, 1)
		check(ok, fmt.tprintf("the embedded track extracts and parses (%s)", subs.tracks[1].err))
		if ok {
			check(len(subs.tracks[1].cues) == 2, fmt.tprintf("two cues out of the container, got %d", len(subs.tracks[1].cues)))
			e1, h1 := subs_text_at(&subs, 1.0)
			check(h1 && strings.contains(e1, "Embedded cue one"), fmt.tprintf("the first embedded cue, got %q", e1))
			check(!strings.contains(e1, "<i>"), "and its markup was stripped")
			e2, h2 := subs_text_at(&subs, 3.0)
			check(h2 && strings.contains(e2, "cue two"), fmt.tprintf("the second embedded cue, got %q", e2))
			_, h3 := subs_text_at(&subs, 2.2)
			check(!h3, "and the gap between them is empty")
		}

		// Cycling walks every track and then off, so one key reaches all states.
		seen_off := false
		subs_select(&subs, 0)
		for _ in 0 ..< 3 {
			subs_cycle(&subs, 1)
			if subs.active < 0 {
				seen_off = true
			}
		}
		check(seen_off, "cycling reaches off")
		check(subs.active == 0, "and comes back round to the first track")
	}

	// And the engine, at 2x, over the same file: the atempo path really starts.
	e: Engine
	engine_init(&e, m)
	defer engine_destroy(&e)
	e.speed = 2
	engine_open(&e, 0, 320, 180)
	check(e.have_video, "the video pipeline starts at 2x")
	check(abs(engine_speed(&e) - 2) < 1e-9, "the engine reports 2x")
	got := false
	for _ in 0 ..< 600 {
		if engine_take(&e, 1e9) {
			got = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	check(got, "a frame arrives at 2x")
	if e.have_audio {
		// Give the sink a moment, then check the clock is running fast. A wide
		// band, because this is a real process starting on a real machine.
		t0 := time.now()
		c0 := engine_clock(&e)
		for time.duration_seconds(time.since(t0)) < 1.2 {
			engine_tick(&e)
			engine_take(&e, engine_clock(&e))
			time.sleep(2 * time.Millisecond)
		}
		wall := time.duration_seconds(time.since(t0))
		rate := (engine_clock(&e) - c0) / wall
		check(rate > 1.3, fmt.tprintf("the clock runs faster than wall time at 2x (%.2gx)", rate))
		check(rate < 2.7, fmt.tprintf("but not unboundedly (%.2gx)", rate))
	} else {
		fmt.println("  note: no audio sink on this machine, so the 2x clock rate was not checked")
	}

	// Changing speed on a running engine is a seek: the position must survive.
	e2: Engine
	engine_init(&e2, m)
	defer engine_destroy(&e2)
	engine_open(&e2, 0, 320, 180)
	for _ in 0 ..< 400 {
		if engine_take(&e2, 1e9) {break}
		time.sleep(5 * time.Millisecond)
	}
	before := engine_clock(&e2)
	check(engine_set_speed(&e2, 0.5), "the speed changes on a running engine")
	check(abs(engine_clock(&e2) - before) < 0.5, "and the clock keeps its position across the restart")
	check(abs(engine_speed(&e2) - 0.5) < 1e-9, "at the new speed")
}
