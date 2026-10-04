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
	}
}

run_selftest :: proc() {
	test_rate()
	test_timecode()
	test_sizes()
	test_paths()
	test_probe_json()
	test_decode_size()
	test_pipeline()

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
