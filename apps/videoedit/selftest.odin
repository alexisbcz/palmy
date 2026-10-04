package main

// `videoedit --selftest` — headless, no compositor, no window.
//
// Five groups: the timeline model asserted directly on the data structure, the
// three subtitle dialects including the timecodes that usually break a parser,
// the undo stack walked over a long random sequence of edits, the audio mix
// resolution the preview and the export share, and one real export of a
// generated timeline read back with ffprobe.
//
// The undo group is the one worth reading. It does not assert that a
// particular edit has a correct inverse — there are no inverses. It asserts
// that after any edit the project serialises to the same *bytes* once undone
// and redone, over 600 random edits, and that unwinding the whole stack and
// replaying it lands on the same bytes again. That is a stronger statement
// than any list of per-operation tests, and it is what buys the right to have
// no per-operation undo code.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

near :: proc(a, b: f64, what: string, tol := 1e-6) {
	checks += 1
	if math.abs(a - b) > tol {
		failures += 1
		fmt.printf("  FAIL  %s: got %.6f, want %.6f\n", what, a, b)
	}
}

section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("videoedit self-test")

	test_model()
	test_captions()
	test_project_roundtrip()
	test_serialise_fixpoint()
	test_undo()
	test_audio_mix()
	test_audio_live()
	test_reprobe()
	test_interaction()
	test_export()

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// The timeline model
// ---------------------------------------------------------------------------

@(private = "file")
fixture :: proc(pr: ^Project) {
	project_init(pr)
	append(
		&pr.media,
		Media {
			path = strings.clone("/tmp/a.mp4"),
			name = strings.clone("a.mp4"),
			duration = 10,
			width = 1280,
			height = 720,
			fps = 30,
			has_video = true,
			has_audio = true,
		},
	)
	append(
		&pr.media,
		Media {
			path = strings.clone("/tmp/b.mp4"),
			name = strings.clone("b.mp4"),
			duration = 8,
			width = 1280,
			height = 720,
			fps = 30,
			has_video = true,
			has_audio = true,
		},
	)
}

@(private = "file")
V :: 1 // the V1 track index from project_init

test_model :: proc() {
	section("timeline model")
	pr: Project
	fixture(&pr)
	defer project_destroy(&pr)

	// Two clips laid end to end: [0,4) from a, [4,7) from b.
	id_a := append_clip(&pr, V, 0, 1, 5) // 4s long
	id_b := append_clip(&pr, V, 1, 0, 3) // 3s long
	t := &pr.tracks[V]

	check(len(t.clips) == 2, "two clips on V1, got %d", len(t.clips))
	near(t.clips[0].start, 0, "first clip starts at 0")
	near(clip_end(t.clips[0]), 4, "first clip ends at 4")
	near(t.clips[1].start, 4, "second clip starts at 4")
	near(project_duration(&pr), 7, "timeline is 7s")
	check(clip_covers(t.clips[0], 3.9), "clip A covers 3.9")
	check(!clip_covers(t.clips[0], 4.0), "clip A does not cover its own end")

	// --- split -----------------------------------------------------------
	new_id, ok := split_at(&pr, V, 1.5)
	check(ok, "split at 1.5 succeeded")
	check(len(t.clips) == 3, "split made three clips, got %d", len(t.clips))
	near(t.clips[0].start, 0, "left half still starts at 0")
	near(clip_end(t.clips[0]), 1.5, "left half ends at the cut")
	near(t.clips[0].src_in, 1, "left half keeps the source in point")
	near(t.clips[0].src_out, 2.5, "left half's source out is at the cut")
	near(t.clips[1].start, 1.5, "right half starts at the cut")
	near(t.clips[1].src_in, 2.5, "right half's source in is at the cut")
	near(clip_end(t.clips[1]), 4, "right half still ends at 4")
	check(t.clips[1].id == id_a, "the right half keeps the original id")
	check(t.clips[0].id == new_id, "the left half is the new clip")
	near(project_duration(&pr), 7, "a split does not change the duration")

	_, bad := split_at(&pr, V, 1.5)
	check(!bad, "splitting exactly on a cut is refused")
	_, bad2 := split_at(&pr, V, 99)
	check(!bad2, "splitting past the end is refused")

	// --- trim ------------------------------------------------------------
	_, ci := find_clip(&pr, id_b)
	before := clip_len(t.clips[ci])
	d := trim_out(&pr, V, ci, -1)
	near(d, -1, "trim_out moved by a full second")
	near(clip_len(t.clips[ci]), before - 1, "the clip is a second shorter")
	near(t.clips[ci].start, 4, "trimming the out point leaves the start alone")

	// Trimming the out point past the source is clamped.
	d2 := trim_out(&pr, V, ci, 100)
	near(t.clips[ci].src_out, 8, "trim_out clamps to the source duration")
	check(d2 < 100, "trim_out reported the clamped delta")

	_, ai := find_clip(&pr, id_a)
	s_before := t.clips[ai].start
	in_before := t.clips[ai].src_in
	trim_in(&pr, V, ai, 0.5)
	_, ai = find_clip(&pr, id_a)
	near(t.clips[ai].start, s_before + 0.5, "trim_in moves the start with the in point")
	near(t.clips[ai].src_in, in_before + 0.5, "trim_in moved the source in point")

	// trim_in is clamped twice over: it can move neither before the source's
	// first frame nor before the timeline origin.
	_, li := find_clip(&pr, new_id)
	near(t.clips[li].start, 0, "the left half sits at the timeline origin")
	trim_in(&pr, V, li, -99)
	_, li = find_clip(&pr, new_id)
	near(t.clips[li].start, 0, "trim_in cannot push a clip before t=0")
	near(t.clips[li].src_in, 1, "and so the source in point does not move either")
	// With room on the timeline, the source origin is what binds.
	move_clip(&pr, V, li, V, 5)
	_, li = find_clip(&pr, new_id)
	trim_in(&pr, V, li, -99)
	_, li = find_clip(&pr, new_id)
	near(t.clips[li].src_in, 0, "trim_in clamps at the source origin")
	near(t.clips[li].start, 4, "and the start moved by exactly the source room available")

	// --- ripple delete ----------------------------------------------------
	pr2: Project
	fixture(&pr2)
	defer project_destroy(&pr2)
	t2 := &pr2.tracks[V]
	x := append_clip(&pr2, V, 0, 0, 2) // [0,2)
	y := append_clip(&pr2, V, 1, 0, 3) // [2,5)
	z := append_clip(&pr2, V, 0, 0, 1) // [5,6)
	_ = x
	_ = z
	near(project_duration(&pr2), 6, "three clips make 6s")
	_, yi := find_clip(&pr2, y)
	check(ripple_delete(&pr2, V, yi), "ripple delete removed the middle clip")
	check(len(t2.clips) == 2, "two clips remain, got %d", len(t2.clips))
	near(t2.clips[1].start, 2, "the trailing clip moved back by the deleted length")
	near(project_duration(&pr2), 3, "the timeline is 3s shorter")

	// lift leaves the hole.
	pr3: Project
	fixture(&pr3)
	defer project_destroy(&pr3)
	append_clip(&pr3, V, 0, 0, 2)
	q := append_clip(&pr3, V, 1, 0, 3)
	append_clip(&pr3, V, 0, 0, 1)
	_, qi := find_clip(&pr3, q)
	lift_delete(&pr3, V, qi)
	near(pr3.tracks[V].clips[1].start, 5, "lift delete leaves the following clip where it was")

	// --- snapping ---------------------------------------------------------
	pr4: Project
	fixture(&pr4)
	defer project_destroy(&pr4)
	a4 := append_clip(&pr4, V, 0, 0, 3) // [0,3)
	b4 := append_clip(&pr4, V, 1, 0, 2) // [3,5)
	_ = a4
	zoom := f32(100) // 100 px per second, so SNAP_PX is 0.1s
	s1, hit1 := snap_time(&pr4, 3.05, zoom, 9.0, b4)
	check(hit1, "3.05 snaps")
	near(s1, 3, "snapped to the neighbouring clip's edge")
	s2, hit2 := snap_time(&pr4, 2.5, zoom, 9.0, b4)
	check(!hit2, "2.5 is too far from anything to snap")
	near(s2, 2.5, "a miss returns the input unchanged")
	s3, hit3 := snap_time(&pr4, 9.04, zoom, 9.0, b4)
	check(hit3, "a time near the playhead snaps to it")
	near(s3, 9.0, "snapped to the playhead")
	// The clip being dragged must not snap to itself.
	s4, _ := snap_time(&pr4, 3.02, zoom, 100, b4)
	near(s4, 3, "the dragged clip's own edge is excluded, so it takes its neighbour's")
	// At a coarse zoom the same tolerance covers much more time.
	s5, hit5 := snap_time(&pr4, 3.5, 10, 100, b4)
	check(hit5, "at 10px/s a half second is inside the snap tolerance")
	near(s5, 3, "snapped to 3 at the coarse zoom")

	// --- move across tracks ------------------------------------------------
	other := track_of_kind(&pr4, .Video, 0)
	check(other != V, "there is a second video track")
	_, bi := find_clip(&pr4, b4)
	nt, _ := move_clip(&pr4, V, bi, other, 1.25)
	check(nt == other, "the clip changed track")
	_, bi2 := find_clip(&pr4, b4)
	near(pr4.tracks[other].clips[bi2].start, 1.25, "and landed at the new start")
	check(len(pr4.tracks[V].clips) == 1, "the old track lost it")

	// --- topmost wins ------------------------------------------------------
	tt, ti := topmost_video_at(&pr4, 1.5)
	check(tt == other, "the upper track wins where both cover the time")
	check(ti >= 0, "and a clip index came back")

	// --- mute and solo ------------------------------------------------------
	pr4.tracks[V].mute = true
	check(!track_enabled(&pr4, V), "a muted track is not audible")
	check(track_enabled(&pr4, other), "an unmuted track is")
	pr4.tracks[V].solo = true
	check(track_enabled(&pr4, V), "solo overrides mute on the soloed track")
	check(!track_enabled(&pr4, other), "and silences everything else")

	// --- timecode -----------------------------------------------------------
	check(timecode(0, 30) == "00:00:00:00", "timecode of zero, got %s", timecode(0, 30))
	check(timecode(3661.5, 30) == "01:01:01:15", "timecode at 1h1m1.5s, got %s", timecode(3661.5, 30))
}

// ---------------------------------------------------------------------------
// Captions
// ---------------------------------------------------------------------------

test_captions :: proc() {
	section("caption parsing")

	// --- timecodes ---------------------------------------------------------
	cases := [?]struct {
		text: string,
		want: f64,
	} {
		{"00:00:00,000", 0},
		{"00:00:00,500", 0.5},          // sub-second
		{"00:00:00.083", 0.083},        // two frames at 24fps
		{"00:00:01,000", 1},
		{"01:02:03,004", 3723.004},     // over an hour
		{"10:00:00,000", 36000},        // ten hours
		{"00:01.500", 1.5},             // VTT without hours
		{"1:02:03.45", 3723.45},        // ASS, one-digit hour, centiseconds
		{"0:00:00.07", 0.07},
		{"99:59:59,999", 359999.999},
	}
	for c in cases {
		got, ok := parse_timecode(c.text)
		check(ok, "parse %s", c.text)
		near(got, c.want, fmt.tprintf("timecode %s", c.text), 1e-4)
	}
	_, bad := parse_timecode("not a time")
	check(!bad, "garbage is rejected")
	_, bad2 := parse_timecode("")
	check(!bad2, "an empty string is rejected")

	// --- SRT -----------------------------------------------------------------
	srt := `1
00:00:00,250 --> 00:00:02,000
Hello <i>there</i>
second line

2
01:00:01,500 --> 01:00:04,750
Over an hour in
`
	cues, format, ok := parse_captions("x.srt", srt)
	defer {
		for c in cues {delete(c.text)}
		delete(cues)
	}
	check(ok, "SRT parsed")
	check(format == .SRT, "format detected as SRT")
	check(len(cues) == 2, "two SRT cues, got %d", len(cues))
	if len(cues) == 2 {
		near(cues[0].start, 0.25, "SRT sub-second start")
		near(cues[0].end, 2.0, "SRT end")
		check(cues[0].text == "Hello there\nsecond line", "SRT markup stripped and lines joined, got %q", cues[0].text)
		near(cues[1].start, 3601.5, "SRT over-an-hour start")
		near(cues[1].end, 3604.75, "SRT over-an-hour end")
	}

	// --- VTT -------------------------------------------------------------------
	vtt := "WEBVTT\r\n\r\nNOTE this is a comment\r\n\r\nintro\r\n00:00.120 --> 00:02.400 align:start position:10%\r\nFirst cue\r\n\r\n01:00:00.001 --> 01:00:02.000\r\n<v Speaker>Past the hour\r\n"
	vcues, vformat, vok := parse_captions("x.vtt", vtt)
	defer {
		for c in vcues {delete(c.text)}
		delete(vcues)
	}
	check(vok, "VTT parsed")
	check(vformat == .VTT, "format detected as VTT")
	check(len(vcues) == 2, "two VTT cues, got %d", len(vcues))
	if len(vcues) == 2 {
		near(vcues[0].start, 0.12, "VTT hour-less sub-second start")
		near(vcues[0].end, 2.4, "VTT end with cue settings after it")
		check(vcues[0].text == "First cue", "VTT text, got %q", vcues[0].text)
		near(vcues[1].start, 3600.001, "VTT millisecond past the hour", 1e-4)
		check(vcues[1].text == "Past the hour", "VTT voice tag stripped, got %q", vcues[1].text)
	}

	// --- ASS -------------------------------------------------------------------
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
	acues, aformat, aok := parse_captions("x.ass", ass)
	defer {
		for c in acues {delete(c.text)}
		delete(acues)
	}
	check(aok, "ASS parsed")
	check(aformat == .ASS, "format detected as ASS")
	check(len(acues) == 2, "two ASS cues, got %d", len(acues))
	if len(acues) == 2 {
		near(acues[0].start, 0.33, "ASS centisecond start")
		near(acues[0].end, 2.0, "ASS end")
		check(
			acues[0].text == "Styled, with a comma",
			"ASS override tags dropped and the comma in the text kept, got %q",
			acues[0].text,
		)
		near(acues[1].start, 5400.05, "ASS past 90 minutes")
		check(acues[1].text == "Line one\nLine two", "ASS \\N became a newline, got %q", acues[1].text)
	}

	// --- writing back ----------------------------------------------------------
	check(format_srt_time(0) == "00:00:00,000", "format zero, got %s", format_srt_time(0))
	check(format_srt_time(3723.004) == "01:02:03,004", "format over an hour, got %s", format_srt_time(3723.004))
	check(format_srt_time(0.5) == "00:00:00,500", "format sub-second, got %s", format_srt_time(0.5))
	// Round trip.
	for c in cases {
		if v, ok2 := parse_timecode(c.text); ok2 {
			again, ok3 := parse_timecode(format_srt_time(v))
			check(ok3, "re-parse of %s", c.text)
			near(again, v, fmt.tprintf("round trip of %s", c.text), 1e-3)
		}
	}

	// --- the other application's real output ----------------------------------
	// The captioning app writes SRT, WebVTT and ASS; if any of its files are on
	// this machine, parse them for real rather than only parsing fixtures.
	interop := 0
	for name in ([?]string{"selftest.srt", "selftest.vtt", "selftest.ass"}) {
		path := fmt.tprintf("%s/palmy-captions/%s", cache_dir(), name)
		body, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			continue
		}
		interop += 1
		cs, f2, ok2 := parse_captions(path, string(body))
		defer {
			for c in cs {delete(c.text)}
			delete(cs)
		}
		check(ok2, "parsed the captioning app's %s", name)
		check(f2 != .Unknown, "recognised the format of %s", name)
		check(len(cs) > 0, "%s produced cues, got %d", name, len(cs))
		if len(cs) > 0 {
			check(cs[0].end > cs[0].start, "%s first cue has a positive duration", name)
			check(cs[0].text != "", "%s first cue has text", name)
		}
	}
	if interop == 0 {
		fmt.println("  note: the captioning app has written no files on this machine yet")
	} else {
		fmt.printf("  parsed %d file(s) written by the captioning app\n", interop)
	}

	// The nudge is what gets burned in, so check it lands in the file.
	prx: Project
	project_init(&prx)
	defer project_destroy(&prx)
	append(&prx.captions, Caption{start = 1, end = 2, text = strings.clone("shifted")})
	prx.caption_offset = 2.5
	tmp := "/tmp/videoedit-selftest-shift.srt"
	check(write_shifted_srt(&prx, tmp), "wrote the shifted SRT")
	body, rerr := os.read_entire_file_from_path(tmp, context.temp_allocator)
	check(rerr == nil, "read the shifted SRT back")
	if rerr == nil {
		check(
			strings.contains(string(body), "00:00:03,500 --> 00:00:04,500"),
			"the nudge is baked into the burn-in file, got %q",
			string(body),
		)
	}
	os.remove(tmp)
}

// ---------------------------------------------------------------------------
// Project round trip
// ---------------------------------------------------------------------------

test_project_roundtrip :: proc() {
	section("project save / load")
	pr: Project
	fixture(&pr)
	defer project_destroy(&pr)

	append_clip(&pr, V, 0, 0.5, 3.25)
	bid := append_clip(&pr, V, 1, 1, 4)
	_, bi := find_clip(&pr, bid)
	pr.tracks[V].clips[bi].trans = .Dissolve
	pr.tracks[V].clips[bi].xfade = 0.75
	pr.tracks[V].clips[bi].gain = 0.6
	a := track_of_kind(&pr, .Audio, 0)
	append_clip(&pr, a, 0, 0, 2)
	pr.tracks[a].mute = true
	insert_title(&pr, 0, 1.0, 2.0, "A title with spaces")
	append(&pr.captions, Caption{start = 1.5, end = 2.5, text = strings.clone("line one\nline two")})
	pr.caption_offset = -0.25
	pr.caption_src = strings.clone("/tmp/caps.srt")

	path := "/tmp/videoedit-selftest.vep"
	check(project_save(&pr, path, 2.75, 85), "project saved")

	back: Project
	defer project_destroy(&back)
	res := project_load(&back, path)
	check(res.ok, "project loaded: %s", res.err)
	near(res.playhead, 2.75, "playhead round-tripped")
	near(f64(res.zoom), 85, "zoom round-tripped")
	check(len(back.tracks) == len(pr.tracks), "track count round-tripped")
	check(len(back.media) == len(pr.media), "media count round-tripped")
	check(len(back.captions) == 1, "caption count round-tripped")
	if len(back.captions) == 1 {
		check(back.captions[0].text == "line one\nline two", "the caption's newline survived, got %q", back.captions[0].text)
		near(back.caption_offset, -0.25, "the caption nudge round-tripped")
	}
	if len(back.tracks) == len(pr.tracks) {
		for &t, i in pr.tracks {
			bt := &back.tracks[i]
			check(bt.name == t.name, "track %d name", i)
			check(bt.kind == t.kind, "track %d kind", i)
			check(bt.mute == t.mute, "track %d mute", i)
			check(len(bt.clips) == len(t.clips), "track %d clip count", i)
			if len(bt.clips) != len(t.clips) {
				continue
			}
			for c, ci in t.clips {
				bc := bt.clips[ci]
				near(bc.start, c.start, fmt.tprintf("clip %d/%d start", i, ci))
				near(bc.src_in, c.src_in, fmt.tprintf("clip %d/%d in", i, ci))
				near(bc.src_out, c.src_out, fmt.tprintf("clip %d/%d out", i, ci))
				near(f64(bc.gain), f64(c.gain), fmt.tprintf("clip %d/%d gain", i, ci), 1e-5)
				check(bc.trans == c.trans, "clip %d/%d transition", i, ci)
				near(bc.xfade, c.xfade, fmt.tprintf("clip %d/%d xfade", i, ci))
				check(bc.media == c.media, "clip %d/%d media index", i, ci)
				check(bc.title == c.title, "clip %d/%d title %q vs %q", i, ci, bc.title, c.title)
			}
		}
	}
	near(project_duration(&back), project_duration(&pr), "the loaded timeline is the same length")
	os.remove(path)
}

// ---------------------------------------------------------------------------
// The serialiser is a fixed point
//
// Everything the undo stack promises rests on one property:
// `serialise(parse(x)) == x`, byte for byte. If it does not hold, undo and redo
// slowly rewrite the project under the user. It is asserted on its own, before
// the undo tests, so a failure says which of the two is broken.
// ---------------------------------------------------------------------------

test_serialise_fixpoint :: proc() {
	section("the serialiser is a fixed point")
	pr: Project
	fixture(&pr)
	defer project_destroy(&pr)
	append_clip(&pr, V, 0, 0.5, 3.25)
	bid := append_clip(&pr, V, 1, 1, 4)
	_, bi := find_clip(&pr, bid)
	pr.tracks[V].clips[bi].trans = .Dissolve
	pr.tracks[V].clips[bi].xfade = 0.75
	pr.tracks[V].clips[bi].gain = 0.6
	a := track_of_kind(&pr, .Audio, 0)
	append_clip(&pr, a, 0, 0, 2)
	pr.tracks[a].mute = true
	pr.tracks[a].solo = true
	// The characters the format has to survive: a percent sign, an apostrophe,
	// a colon, a comma, a backslash, a newline, and two spaces in a row — the
	// last of which `strings.fields` plus a re-join used to silently collapse.
	insert_title(&pr, 0, 1.0, 2.0, "50% 'off': two  spaces\\and a backslash")
	insert_title(&pr, 0, 4.0, 1.0, "") // an empty title still has to round-trip
	append(&pr.captions, Caption{start = 1.5, end = 2.5, text = strings.clone("line one\nline two")})
	pr.caption_offset = -0.25
	pr.caption_src = strings.clone("/tmp/caps with  two spaces.srt")

	a1 := project_serialise(&pr, 2.75, 85, context.temp_allocator)
	res := project_parse(&pr, a1, false)
	check(res.ok, "the serialisation parses back: %s", res.err)
	near(res.playhead, 2.75, "the playhead rode along in the text")
	near(f64(res.zoom), 85, "and the zoom")
	a2 := project_serialise(&pr, res.playhead, res.zoom, context.temp_allocator)
	check(a1 == a2, "serialise(parse(x)) == x (%d bytes vs %d)", len(a1), len(a2))
	// And again, because a one-pass fixed point is not the same as a stable one.
	res2 := project_parse(&pr, a2, false)
	a3 := project_serialise(&pr, res2.playhead, res2.zoom, context.temp_allocator)
	check(a2 == a3, "and stays a fixed point on a second pass")

	// The two-space path is the one that was broken, so it gets its own check.
	found := false
	for &t in pr.tracks {
		for c in t.clips {
			if strings.contains(c.title, "two  spaces") {
				found = true
			}
		}
	}
	check(found, "a title with two consecutive spaces survived the round trip")
	check(
		strings.contains(pr.caption_src, "with  two"),
		"so did a path with two, got %q",
		pr.caption_src,
	)

	// TIME_EPS is the format's resolution, and the model has to agree: a trim
	// too small to write down must report that it did nothing, or it would be
	// an edit the history cannot hold.
	pr5: Project
	fixture(&pr5)
	defer project_destroy(&pr5)
	append_clip(&pr5, V, 0, 1, 5)
	check(trim_out(&pr5, V, 0, TIME_EPS / 10) == 0, "a trim below the format's resolution is no trim")
	check(trim_in(&pr5, V, 0, TIME_EPS / 10) == 0, "and neither is one on the in point")
	check(trim_out(&pr5, V, 0, 0.5) == 0.5, "a trim above it still happens")
}

// ---------------------------------------------------------------------------
// Undo
//
// The representation is the whole document as a string, so there is nothing
// per-operation to test. What there is to test is the property: every edit is
// reversible, and undo-then-redo is byte-identical. That is asserted over a
// long random sequence rather than over a list somebody remembered to extend.
// ---------------------------------------------------------------------------

test_undo :: proc() {
	section("undo")
	ed := bench_editor(false)
	defer bench_editor_destroy(ed)
	auto_layout(ed)
	undo_reset(ed)

	u0, r0 := undo_depth(ed)
	check(u0 == 0 && r0 == 0, "a fresh editor has no history, got %d/%d", u0, r0)
	check(undo_label(ed) == "", "and nothing to say about what it would undo")
	if _, ok := undo_apply(ed); true {
		check(!ok, "undoing nothing is refused rather than crashing")
	}
	if _, ok := redo_apply(ed); true {
		check(!ok, "and so is redoing nothing")
	}

	// --- one edit, named, undone and redone --------------------------------
	// The playhead is part of the serialisation, so it is moved before the
	// baseline is taken — otherwise this would be comparing a different view
	// as well as a different timeline.
	ed.cur_track = V
	seek_to(ed, 1.0)
	base := strings.clone(
		project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator),
		context.temp_allocator,
	)
	undo_mark(ed, .Split, "split")
	_, sok := split_at(&ed.pr, V, 1.0)
	check(sok, "the fixture can be split at 1s")
	edited(ed)
	check(undo_label(ed) == "split", "the stack names the edit, got %q", undo_label(ed))
	check(redo_label(ed) == "", "and there is nothing to redo yet")
	after := strings.clone(
		project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator),
		context.temp_allocator,
	)
	check(after != base, "the split changed the project")

	label, uok := undo_apply(ed)
	check(uok, "the split undid")
	check(label == "split", "and said what it undid, got %q", label)
	back := project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator)
	check(back == base, "the project is byte-identical to before the split")
	check(redo_label(ed) == "split", "and the redo names the same edit")

	rlabel, rok := redo_apply(ed)
	check(rok, "the split redid")
	check(rlabel == "split", "and said so")
	again := project_serialise(&ed.pr, ed.playhead, ed.zoom, context.temp_allocator)
	check(again == after, "and landed back on the same bytes")

	// --- a new edit abandons the redo branch -------------------------------
	undo_apply(ed)
	_, rdepth := undo_depth(ed)
	check(rdepth == 1, "one step is available to redo, got %d", rdepth)
	undo_mark(ed, .Title_Add, "add a title")
	insert_title(&ed.pr, 0, 2.0, 1.0, "T")
	edited(ed)
	_, rdepth2 := undo_depth(ed)
	check(rdepth2 == 0, "a fresh edit threw the redo branch away, got %d", rdepth2)

	// --- the selection and the playhead come back --------------------------
	undo_reset(ed)
	id := ed.pr.tracks[V].clips[0].id
	ed.sel = id
	ed.cur_track = V
	seek_to(ed, 3.5)
	ed.scroll = 1.25
	sel_track, sel_idx := find_clip(&ed.pr, id)
	undo_mark(ed, .Move, "move a clip", id)
	move_clip(&ed.pr, V, 0, V, 6.0)
	edited(ed)
	ed.sel = -1 // the user clicked somewhere else after the edit
	seek_to(ed, 9.0)
	ed.scroll = 7.0
	undo_apply(ed)
	near(ed.playhead, 3.5, "the playhead went back to where the edit was made")
	near(ed.scroll, 1.25, "and so did the scroll")
	check(ed.cur_track == V, "and the focused track, got %d", ed.cur_track)
	st, si := find_clip(&ed.pr, ed.sel)
	check(
		st == sel_track && si == sel_idx,
		"and the selection, by position: wanted %d/%d, got %d/%d",
		sel_track,
		sel_idx,
		st,
		si,
	)

	// --- coalescing --------------------------------------------------------
	undo_reset(ed)
	mid := ed.pr.tracks[V].clips[0].id
	ed.sel = mid
	for i in 0 ..< 30 {
		// Sixty frames of one drag, which must be one undo step.
		undo_mark(ed, .Move, "move a clip", mid)
		_, ci := find_clip(&ed.pr, mid)
		move_clip(&ed.pr, V, ci, V, 1.0 + f64(i) * 0.05)
		edited(ed)
	}
	d1, _ := undo_depth(ed)
	check(d1 == 1, "thirty frames of one drag are one undo step, got %d", d1)
	undo_break(ed) // the mouse came up
	undo_mark(ed, .Move, "move a clip", mid)
	_, ci2 := find_clip(&ed.pr, mid)
	move_clip(&ed.pr, V, ci2, V, 5.0)
	edited(ed)
	d2, _ := undo_depth(ed)
	check(d2 == 2, "a second drag of the same clip is a second step, got %d", d2)
	// A different clip is a different gesture even without a break.
	other := ed.pr.tracks[V].clips[len(ed.pr.tracks[V].clips) - 1].id
	if other != mid {
		undo_mark(ed, .Move, "move a clip", other)
		_, ci3 := find_clip(&ed.pr, other)
		move_clip(&ed.pr, V, ci3, V, 2.5)
		edited(ed)
		d3, _ := undo_depth(ed)
		check(d3 == 3, "dragging another clip is another step, got %d", d3)
	}

	// --- a refused edit leaves no step -------------------------------------
	undo_reset(ed)
	ed.cur_track = V
	seek_to(ed, 500) // nothing there
	fresh := undo_mark(ed, .Split, "split")
	if _, ok := split_at(&ed.pr, V, 500); !ok {
		if fresh {
			undo_drop(ed)
		}
	}
	d4, _ := undo_depth(ed)
	check(d4 == 0, "a split with nothing under the playhead left no step, got %d", d4)

	// --- the media bin is not document content -----------------------------
	undo_reset(ed)
	nmedia := len(ed.pr.media)
	undo_mark(ed, .Title_Add, "add a title")
	insert_title(&ed.pr, 0, 1.0, 1.0, "X")
	edited(ed)
	// An import lands after the mark, as it would from the worker thread.
	append(
		&ed.pr.media,
		Media {
			path = strings.clone("/tmp/imported-after-the-mark.mp4"),
			name = strings.clone("imported-after-the-mark.mp4"),
			duration = 3,
			width = 640,
			height = 360,
			fps = 30,
			has_video = true,
			has_audio = true,
			probed = true,
		},
	)
	undo_apply(ed)
	check(
		len(ed.pr.media) == nmedia + 1,
		"undoing an edit did not un-import the file that arrived after it, got %d rows (was %d)",
		len(ed.pr.media),
		nmedia,
	)
	check(
		ed.pr.media[nmedia].path == "/tmp/imported-after-the-mark.mp4",
		"and the kept row sits above the ones the snapshot named",
	)
	// Derived data survives a restore, or every undo would blank the bin.
	ed.pr.media[0].thumb_ok = true
	ed.pr.media[0].peaks = make([]f32, 8)
	undo_mark(ed, .Title_Add, "add a title")
	insert_title(&ed.pr, 0, 2.0, 1.0, "Y")
	edited(ed)
	undo_apply(ed)
	check(ed.pr.media[0].thumb_ok, "a restore adopted the media row's thumbnail rather than dropping it")
	check(ed.pr.media[0].peaks != nil, "and its waveform")
	check(ed.pr.media[0].probed, "and left it marked probed")

	// --- the property, over a long random sequence -------------------------
	ed2 := bench_editor(false)
	defer bench_editor_destroy(ed2)
	auto_layout(ed2)
	undo_reset(ed2)
	r := rng_make(0x5EED)
	edits, bad := 0, 0
	first_detail := ""
	for _ in 0 ..< 600 {
		what := random_edit(ed2, &r)
		if what == "" {
			continue
		}
		edits += 1
		if ok, detail := undo_roundtrip_check(ed2); !ok {
			bad += 1
			if first_detail == "" {
				first_detail = fmt.aprintf("after %s: %s", what, detail, allocator = context.temp_allocator)
			}
		}
	}
	check(edits > 300, "the fuzzer produced a real sequence, got %d edits", edits)
	check(bad == 0, "every one of %d edits was reversible; %d were not (%s)", edits, bad, first_detail)

	// Unwind the whole stack and replay it.
	depth, _ := undo_depth(ed2)
	for len(ed2.hist.undo) > 0 {
		undo_apply(ed2)
	}
	start := strings.clone(
		project_serialise(&ed2.pr, ed2.playhead, ed2.zoom, context.temp_allocator),
		context.temp_allocator,
	)
	_, rd := undo_depth(ed2)
	check(rd == depth, "unwinding %d steps filled the redo stack, got %d", depth, rd)
	for len(ed2.hist.redo) > 0 {
		redo_apply(ed2)
	}
	for len(ed2.hist.undo) > 0 {
		undo_apply(ed2)
	}
	finish := project_serialise(&ed2.pr, ed2.playhead, ed2.zoom, context.temp_allocator)
	check(
		start == finish,
		"replaying %d steps and unwinding them again is byte-identical (%d vs %d bytes)",
		depth,
		len(start),
		len(finish),
	)
	fmt.printf("  %d random edits, all reversible; %d steps unwound and replayed\n", edits, depth)
}

// ---------------------------------------------------------------------------
// The audio mix
//
// One function decides what is audible and both the preview and the export
// build their filter chains from it, so these assertions are about that one
// function. If they pass, the speakers and the written file cannot disagree
// about a mute, a solo or a gain — and that is not something the export test
// below could show on its own, because it only ever looks at the file.
// ---------------------------------------------------------------------------

test_audio_mix :: proc() {
	section("the audio mix the preview and the export share")
	pr: Project
	fixture(&pr)
	defer project_destroy(&pr)
	a1 := track_of_kind(&pr, .Audio, 0)
	a2 := track_of_kind(&pr, .Audio, 1)
	check(a1 != a2, "there are two audio tracks")

	// Video on V1 with its audio alongside on A1, plus one on A2.
	append_clip(&pr, V, 0, 0, 4) // video, must not contribute audio
	c1 := append_clip(&pr, a1, 0, 0, 4) // [0,4)
	c2 := append_clip(&pr, a2, 1, 1, 3) // [0,2), source 1→3
	_, i2 := find_clip(&pr, c2)
	pr.tracks[a2].clips[i2].start = 2.0
	pr.tracks[a2].clips[i2].gain = 0.4
	track_sort(&pr.tracks[a2])

	m := resolve_audio_mix(&pr, 0)
	check(len(m) == 2, "two contributions: one per audio clip, the video clip's audio not counted twice, got %d", len(m))
	if len(m) == 2 {
		check(m[0].clip == c1, "the first is A1's clip")
		near(m[0].delay, 0, "placed at the timeline origin")
		near(m[0].src_in, 0, "from the source origin")
		near(m[0].src_out, 4, "to four seconds in")
		near(f64(m[0].gain), 1, "at unity")
		check(m[1].clip == c2, "the second is A2's clip")
		near(m[1].delay, 2.0, "delayed to its timeline position")
		near(m[1].src_in, 1.0, "with its own source window")
		near(m[1].src_out, 3.0, "both ends of it")
		near(f64(m[1].gain), 0.4, "and its own gain", 1e-6)
	}

	// The export builds its chain from this list and nothing else, so the
	// counts have to agree for every M/S configuration.
	cases := [?]struct {
		mute_a1, solo_a1, mute_a2, solo_a2: bool,
		want:                               int,
		what:                               string,
	} {
		{false, false, false, false, 2, "nothing muted"},
		{true, false, false, false, 1, "A1 muted"},
		{false, false, true, false, 1, "A2 muted"},
		{true, false, true, false, 0, "both muted"},
		{false, true, false, false, 1, "A1 soloed"},
		{false, true, false, true, 2, "both soloed"},
		{true, true, false, false, 1, "A1 muted and soloed — solo wins"},
	}
	for c in cases {
		pr.tracks[a1].mute, pr.tracks[a1].solo = c.mute_a1, c.solo_a1
		pr.tracks[a2].mute, pr.tracks[a2].solo = c.mute_a2, c.solo_a2
		got := resolve_audio_mix(&pr, 0)
		check(len(got) == c.want, "%s: %d audible clips, want %d", c.what, len(got), c.want)
		plan := build_export(&pr, {quality = .Draft, out_path = "/tmp/videoedit-mixtest.mp4"})
		check(
			plan.audio_srcs == len(got),
			"%s: the export built %d audio sources from a list of %d",
			c.what,
			plan.audio_srcs,
			len(got),
		)
		export_plan_destroy(&plan)
	}
	pr.tracks[a1].mute, pr.tracks[a1].solo = false, false
	pr.tracks[a2].mute, pr.tracks[a2].solo = false, false

	// --- starting part way in, which is what the preview does --------------
	// At from = 0 the list is the export's. Past that, a clip already behind
	// the playhead drops out and one straddling it has its source in point
	// moved forward by exactly as much as is behind.
	mid := resolve_audio_mix(&pr, 3.0)
	check(len(mid) == 2, "at 3s both clips are still partly ahead, got %d", len(mid))
	if len(mid) == 2 {
		near(mid[0].src_in, 3.0, "A1's clip starts 3s into its source")
		near(mid[0].src_out, 4.0, "and still ends where it did")
		near(mid[0].delay, 0, "with no delay: it is under the playhead")
		near(mid[1].src_in, 2.0, "A2's clip is 1s in, so 1s into its own window")
		near(mid[1].delay, 0, "and also under the playhead")
	}
	late := resolve_audio_mix(&pr, 4.5)
	check(len(late) == 0, "past the end of everything, nothing is audible, got %d", len(late))

	ahead := resolve_audio_mix(&pr, 1.0)
	check(len(ahead) == 2, "at 1s, got %d", len(ahead))
	if len(ahead) == 2 {
		near(ahead[0].src_in, 1.0, "the clip under the playhead is clipped")
		near(ahead[1].delay, 1.0, "the clip still ahead keeps its distance")
		near(ahead[1].src_in, 1.0, "and its source window untouched")
	}

	// A clip with zero gain is still a contribution: silence from a muted
	// *clip* is the export's business, and dropping it here would make the
	// two disagree about how many inputs the graph has.
	_, i1 := find_clip(&pr, c1)
	pr.tracks[a1].clips[i1].gain = 0
	z := resolve_audio_mix(&pr, 0)
	check(len(z) == 2, "a clip at zero gain is still in the graph, got %d", len(z))
	near(f64(z[0].gain), 0, "at zero")
	pr.tracks[a1].clips[i1].gain = 1

	// Media with no audio stream contributes nothing however it is placed.
	pr.media[1].has_audio = false
	noaudio := resolve_audio_mix(&pr, 0)
	check(len(noaudio) == 1, "a silent source contributes nothing, got %d", len(noaudio))
	pr.media[1].has_audio = true

	// --- the preview's argv ------------------------------------------------
	argv, n := mix_argv(&pr, 0, project_duration(&pr), context.temp_allocator)
	check(n == 2, "the preview graph carries both contributions, got %d", n)
	joined := strings.join(argv, " ", context.temp_allocator)
	check(strings.has_prefix(joined, "ffmpeg "), "it is an ffmpeg invocation")
	check(strings.contains(joined, "anullsrc"), "with a silent bed")
	check(
		strings.contains(joined, fmt.tprintf("d=%.4f", project_duration(&pr))),
		"the bed is the length of what is left of the timeline, so the graph ends there",
	)
	check(strings.contains(joined, "amix=inputs=3"), "and mixes the bed plus both clips")
	check(strings.contains(joined, "adelay=2000:all=1"), "with A2's clip delayed to 2s")
	check(strings.contains(joined, "volume=0.4000"), "and its gain in the graph, not in the pump")
	check(
		!strings.contains(joined, " -re") && !strings.contains(joined, "arealtime"),
		"and no pacing filter: pw-cat's back-pressure is the clock",
	)
	check(strings.contains(joined, "s16le"), "raw PCM out")
	check(argv[len(argv) - 1] == "-", "to stdout")

	// An empty timeline still produces a clock to run the playhead on.
	empty: Project
	project_init(&empty)
	defer project_destroy(&empty)
	eargv, en := mix_argv(&empty, 0, 5, context.temp_allocator)
	check(en == 0, "nothing audible on an empty timeline, got %d", en)
	ejoined := strings.join(eargv, " ", context.temp_allocator)
	check(
		strings.contains(ejoined, "amix=inputs=1"),
		"but the silent bed is still there, so the clock still runs: %s",
		ejoined,
	)
}

// ---------------------------------------------------------------------------
// The live mixer, and what a seek has to do to it
//
// This one starts the real pipeline — ffmpeg, pw-cat, the pump thread — but
// with `Mixer.silent` set, which zeroes the samples *after* they have been
// measured. The byte flow, and therefore the clock and the flush, are
// identical to a real playback; there is simply nothing to hear. Running a
// self-test must not play sound into the room, and it does not have to in
// order to assert any of this.
//
// What it is here for is the one audio behaviour that cannot be asserted on a
// pure function: a seek must *flush*. Scrubbing would otherwise play a burst
// of whatever was already queued in the pipe, in pw-cat and in PipeWire before
// the new position was heard.
// ---------------------------------------------------------------------------

test_audio_live :: proc() {
	section("the live mixer and the seek flush")
	src := fmt.tprintf("%s/bars.mp4", MEDIA_DIR)
	if _, err := os.stat(src, context.temp_allocator); err != nil {
		fmt.println("  skipped: the bundled test media is not present")
		return
	}
	if !have_tool("pw-cat") || !have_tool("ffmpeg") {
		fmt.println("  skipped: pw-cat or ffmpeg is not on PATH")
		return
	}

	pr: Project
	project_init(&pr)
	defer project_destroy(&pr)
	append(
		&pr.media,
		Media {
			path = strings.clone(src),
			name = strings.clone(base_name(src)),
			duration = 8,
			width = 1280,
			height = 720,
			fps = 30,
			has_video = true,
			has_audio = true,
			probed = true,
		},
	)
	a := track_of_kind(&pr, .Audio, 0)
	append_clip(&pr, a, 0, 0, 2.0)
	total := project_duration(&pr)
	near(total, 2.0, "the test timeline is two seconds")

	mx: Mixer
	mixer_init(&mx)
	mx.silent = true // measured, then zeroed: nothing is played
	defer mixer_destroy(&mx)

	check(!mixer_live(&mx), "a fresh mixer is not running")
	near(mixer_clock(&mx), 0, "and its clock sits at zero")
	check(mixer_start(&mx, &pr, 0, total), "the pipeline started: %s", mixer_error(&mx))
	check(mixer_live(&mx), "and reports itself live")

	// Wait for the first bytes to reach pw-cat.
	t0 := time.now()
	for {
		mixer_tick(&mx)
		if b, _ := mixer_bytes(&mx); b > 0 {
			break
		}
		if time.duration_seconds(time.since(t0)) > 8 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	b1, sum1 := mixer_bytes(&mx)
	check(b1 > 0, "pw-cat accepted PCM, got %d bytes", b1)
	check(sum1 > 0, "and the mix is sound rather than silence (mean |sample| over %d bytes)", b1)
	check(mixer_startup_ms(&mx) > 0, "the startup latency was measured, got %.1f ms", mixer_startup_ms(&mx))

	// The clock may never run backwards past where it was told to start, even
	// though the first `lat_est` seconds of audio are still in flight.
	for _ in 0 ..< 40 {
		mixer_tick(&mx)
		c := mixer_clock(&mx)
		check(c >= 0, "the clock never goes negative, got %.4f", c)
		check(c <= total + 0.25, "nor past the end of the timeline, got %.4f", c)
		time.sleep(5 * time.Millisecond)
	}
	before := mixer_clock(&mx)

	// --- the flush ---------------------------------------------------------
	// Restarting at a new position is the flush: the pipe, ffmpeg's buffer and
	// pw-cat's queue all go with the processes, so the byte counter — which is
	// the clock — must restart from zero. A counter that carried over would
	// mean audio for the old position still queued ahead of the new.
	check(mixer_start(&mx, &pr, 1.0, total), "the pipeline restarted at 1s")
	bflush, _ := mixer_bytes(&mx)
	check(bflush == 0, "the seek flushed the byte counter, got %d bytes still counted", bflush)
	near(mixer_clock(&mx), 1.0, "and the clock reads the new position", 0.01)
	check(mixer_clock(&mx) != before || before == 1.0, "which is not where it was")

	t1 := time.now()
	for {
		mixer_tick(&mx)
		if b, _ := mixer_bytes(&mx); b > 0 {
			break
		}
		if time.duration_seconds(time.since(t1)) > 8 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	b2, _ := mixer_bytes(&mx)
	check(b2 > 0, "and sound resumed after the seek, got %d bytes", b2)
	check(mixer_clock(&mx) >= 1.0, "from the new position, not the old one")
	resume := time.duration_milliseconds(time.since(t1))

	// --- the end of the timeline ------------------------------------------
	// The silent bed carries the timeline's own length, so running out is the
	// playhead reaching the end rather than a guess about it.
	t2 := time.now()
	for !mixer_done(&mx) && time.duration_seconds(time.since(t2)) < 10 {
		mixer_tick(&mx)
		time.sleep(10 * time.Millisecond)
	}
	check(mixer_done(&mx), "the pipeline ran out at the end of the timeline")
	bend, _ := mixer_bytes(&mx)
	played := f64(bend) / f64(MIX_BPS)
	near(played, total - 1.0, "and handed over exactly the timeline that was left", 0.1)

	lat, locked := mixer_latency(&mx)
	mixer_stop(&mx)
	check(!mixer_live(&mx), "stopping leaves nothing running")
	fmt.printf(
		"  %.0f ms to first sound, %.0f ms to resume after a seek, sink %.0f ms%s, %.2fs played\n",
		mixer_startup_ms(&mx),
		resume,
		lat * 1000,
		locked ? "" : " (estimate)",
		played,
	)
}

// ---------------------------------------------------------------------------
// Re-probing a loaded project
//
// A project file stores paths, not pictures. Loading one therefore leaves
// every media row without a thumbnail or a waveform, and the fix is to push
// the paths back through the importer — which only helps if `install_import`
// *adopts* the result into the existing row instead of discarding it as a
// duplicate. It discarded it, once.
// ---------------------------------------------------------------------------

test_reprobe :: proc() {
	section("re-probing a loaded project")
	src := fmt.tprintf("%s/bars.mp4", MEDIA_DIR)
	if _, err := os.stat(src, context.temp_allocator); err != nil {
		fmt.println("  skipped: the bundled test media is not present")
		return
	}

	pr: Project
	project_init(&pr)
	defer project_destroy(&pr)
	// What project_load leaves behind: a path, no thumbnail, not probed.
	append(
		&pr.media,
		Media {
			path = strings.clone(src),
			name = strings.clone(base_name(src)),
			width = 1280,
			height = 720,
			duration = 8,
		},
	)
	check(!pr.media[0].thumb_ok, "a loaded row starts with no thumbnail")
	check(pr.media[0].peaks == nil, "and no waveform")

	im: Importer
	importer_start(&im)
	defer importer_stop(&im)
	importer_push(&im, src)

	got: [dynamic]Import_Result
	defer delete(got)
	deadline := time.now()
	for len(got) == 0 && time.duration_seconds(time.since(deadline)) < 20 {
		importer_drain(&im, &got)
		if len(got) == 0 {
			time.sleep(20 * time.Millisecond)
		}
	}
	check(len(got) == 1, "the importer returned a result, got %d", len(got))
	if len(got) != 1 {
		return
	}
	idx := install_import(&pr, got[0])
	check(idx == 0, "the result landed on the existing row, got %d", idx)
	check(len(pr.media) == 1, "and did not duplicate it, got %d rows", len(pr.media))
	check(pr.media[0].thumb_ok, "the thumbnail was adopted")
	check(pr.media[0].thumb.w > 0 && pr.media[0].thumb.h > 0, "and has pixels")
	check(pr.media[0].peaks != nil, "the waveform was adopted")
	check(len(pr.media[0].peaks) > 100, "with enough peaks to draw, got %d", len(pr.media[0].peaks))
	check(pr.media[0].probed, "and the row is now marked probed")
	check(pr.media[0].vcodec == "h264", "with the real codec name, got %q", pr.media[0].vcodec)
}

// ---------------------------------------------------------------------------
// End-to-end export
// ---------------------------------------------------------------------------

test_export :: proc() {
	section("end-to-end export")
	if !have_tool("ffmpeg") || !have_tool("ffprobe") {
		fmt.println("  skipped: ffmpeg or ffprobe is not on PATH")
		return
	}

	dir := "/tmp/videoedit-selftest"
	os.make_directory(dir)
	src1 := fmt.tprintf("%s/src1.mp4", dir)
	src2 := fmt.tprintf("%s/src2.mp4", dir)
	out := fmt.tprintf("%s/out.mp4", dir)
	os.remove(out)

	// Two short generated sources, so the test depends on nothing downloaded.
	gen1 := []string {
		"ffmpeg", "-y", "-v", "error",
		"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
		"-f", "lavfi", "-i", "sine=frequency=440",
		"-t", "3", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
		"-c:a", "aac", src1,
	}
	gen2 := []string {
		"ffmpeg", "-y", "-v", "error",
		"-f", "lavfi", "-i", "smptebars=size=320x180:rate=30",
		"-f", "lavfi", "-i", "sine=frequency=880",
		"-t", "3", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
		"-c:a", "aac", src2,
	}
	_, g1 := run_capture(gen1, context.temp_allocator)
	_, g2 := run_capture(gen2, context.temp_allocator)
	check(g1, "generated the first source clip")
	check(g2, "generated the second source clip")
	if !g1 || !g2 {
		return
	}

	pr: Project
	project_init(&pr)
	defer project_destroy(&pr)
	pr.out_w, pr.out_h, pr.out_fps = 320, 180, 30

	for s in ([?]string{src1, src2}) {
		pb := probe_media(s)
		check(pb.ok, "probed %s", base_name(s))
		check(pb.width == 320 && pb.height == 180, "probe read %dx%d", pb.width, pb.height)
		check(pb.has_audio, "probe found the audio stream")
		near(pb.duration, 3, fmt.tprintf("probe duration of %s", base_name(s)), 0.2)
		append(
			&pr.media,
			Media {
				path = strings.clone(s),
				name = strings.clone(base_name(s)),
				duration = pb.duration,
				width = pb.width,
				height = pb.height,
				fps = pb.fps,
				vcodec = pb.vcodec,
				acodec = pb.acodec,
				has_video = pb.has_video,
				has_audio = pb.has_audio,
			},
		)
	}

	// [0,2) from src1, then [1.5,4) from src2 with a 0.5s dissolve, a title
	// over the first second, and captions on top. Total 4 seconds.
	append_clip(&pr, V, 0, 0, 2)
	second := append_clip(&pr, V, 1, 0, 2.5)
	_, si := find_clip(&pr, second)
	pr.tracks[V].clips[si].trans = .Dissolve
	pr.tracks[V].clips[si].xfade = 0.5
	pr.tracks[V].clips[si].start = 1.5
	track_sort(&pr.tracks[V])
	// A title full of the characters that break a filtergraph: a colon and a
	// comma are option and filter separators, an apostrophe quotes, and a
	// percent sign is a drawtext expansion.
	insert_title(&pr, 0, 0.2, 1.0, "50% 'off': now, really")

	a := track_of_kind(&pr, .Audio, 0)
	append_clip(&pr, a, 0, 0, 2)
	append_clip(&pr, a, 1, 0, 2)
	append(&pr.captions, Caption{start = 0.5, end = 1.5, text = strings.clone("a caption, with a comma")})
	append(&pr.captions, Caption{start = 2.0, end = 3.5, text = strings.clone("and a second one")})

	want := project_duration(&pr)
	near(want, 4.0, "the test timeline is 4 seconds")

	plan := build_export(&pr, {quality = .Draft, out_path = out})
	defer export_plan_destroy(&plan)
	check(plan.err == "", "the export plan built: %s", plan.err)
	check(plan.video_srcs == 2, "two video segments in the graph, got %d", plan.video_srcs)
	check(plan.audio_srcs == 2, "two audio segments — one per audio clip, and the video clips' audio is not counted twice, got %d", plan.audio_srcs)
	check(plan.sub_path != "", "a burn-in subtitle file was written")

	// A muted video track drops out of the graph entirely.
	pr.tracks[V].mute = true
	muted := build_export(&pr, {quality = .Draft, out_path = out})
	check(muted.video_srcs == 0, "a muted video track contributes nothing, got %d", muted.video_srcs)
	export_plan_destroy(&muted)
	pr.tracks[V].mute = false
	// Solo on A1 silences the other audio track but not the video.
	pr.tracks[a].solo = true
	soloed := build_export(&pr, {quality = .Draft, out_path = out})
	check(soloed.video_srcs == 0, "solo on an audio track leaves no video enabled, got %d", soloed.video_srcs)
	check(soloed.audio_srcs == 2, "and keeps the soloed track's audio, got %d", soloed.audio_srcs)
	export_plan_destroy(&soloed)
	pr.tracks[a].solo = false

	// Refusing to overwrite a source is part of the contract.
	bad := build_export(&pr, {quality = .Draft, out_path = src1})
	check(bad.err != "", "exporting over a source file is refused")
	export_plan_destroy(&bad)
	// …including by a path that only resolves to the same file.
	rel := build_export(&pr, {quality = .Draft, out_path = fmt.tprintf("%s/./%s", dir, "src1.mp4")})
	check(rel.err != "", "a different spelling of a source path is refused too")
	export_plan_destroy(&rel)

	// An empty timeline has nothing to export and says so.
	empty: Project
	project_init(&empty)
	ep := build_export(&empty, {quality = .Draft, out_path = out})
	check(ep.err != "", "an empty timeline is refused rather than producing a zero-length file")
	export_plan_destroy(&ep)
	project_destroy(&empty)

	// Run it synchronously; this is the self-test, not the UI.
	t0 := time.now()
	state, _, serr, perr := os.process_exec({command = plan.argv}, context.temp_allocator)
	ms := time.duration_milliseconds(time.since(t0))
	check(perr == nil, "ffmpeg started")
	check(
		state.exit_code == 0,
		"ffmpeg exited cleanly: %s",
		strings.trim_space(string(serr)),
	)
	for t in plan.temps {
		os.remove(t)
	}
	os.remove(plan.progress)
	if state.exit_code != 0 {
		return
	}

	v := verify_output(out, context.temp_allocator)
	check(v.ok, "ffprobe read the exported file")
	near(v.duration, want, "the export is as long as the timeline", 0.15)
	check(v.width == 160 && v.height == 90, "draft is half size, got %dx%d", v.width, v.height)
	check(v.streams == 2, "the export has a video and an audio stream, got %d", v.streams)
	check(v.vcodec == "h264", "video is h264, got %s", v.vcodec)
	check(v.acodec == "aac", "audio is aac, got %s", v.acodec)
	// The escaping held: a title with a colon, a comma, an apostrophe and a
	// percent sign went through drawtext without derailing the graph. If it
	// had not, ffmpeg would have failed above rather than written four
	// seconds of video.

	// And it decodes: pull a frame out and check it is the right size.
	img, iok := extract_thumb(out, want * 0.5, 160)
	check(iok, "a frame could be decoded out of the export")
	if iok {
		check(img.w == 160, "the decoded frame is 160 wide, got %d", img.w)
		check(img.h > 0, "the decoded frame has height, got %d", img.h)
		// Not a black frame: the timeline had picture on it.
		lum := 0
		for px in img.px {
			lum += int((px >> 16) & 0xff) + int((px >> 8) & 0xff) + int(px & 0xff)
		}
		avg := len(img.px) > 0 ? lum / (len(img.px) * 3) : 0
		check(avg > 8, "the exported frame is not black (mean level %d)", avg)
		im := img
		p.image_destroy(&im)
	}
	fmt.printf("  export took %.0f ms for %.1fs of timeline\n", ms, want)
}

@(private = "file")
cache_dir :: proc() -> string {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {
		base = fmt.tprintf("%s/.cache", os.get_env("HOME", context.temp_allocator))
	}
	return base
}

@(private = "file")
have_tool :: proc(name: string) -> bool {
	_, ok := run_capture({"sh", "-c", fmt.tprintf("command -v %s", name)}, context.temp_allocator)
	return ok
}

// ---------------------------------------------------------------------------
// Hit testing and dragging
//
// The timeline is drawn into a raw canvas, so palmy's own hit testing does not
// cover it: the mapping from a pointer position to a clip edge is this
// application's code and nothing else tests it. palmy renders and takes
// synthetic input without a compositor, so the whole gesture — press on a
// clip, move, release — runs here exactly as it does in the window.
// ---------------------------------------------------------------------------

@(private = "file")
step :: proc(ed: ^Editor, off: ^p.Offscreen) {
	ui := p.offscreen_begin(off)
	if ed.tl_id != 0 {
		ed.tl = p.rect_of(ui, ed.tl_id)
	}
	handle_timeline_mouse(ed, ui)
	draw_ui(ed, ui)
	p.offscreen_end(off)
}

test_interaction :: proc() {
	section("timeline hit testing and drag")
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(1280, 820, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_shot_fonts(&off.fonts)

	ed := new(Editor)
	defer free(ed)
	ed.fonts = &off.fonts
	ed.zoom = 100 // 100 px per second, so the snap tolerance is 0.1s
	ed.sel = -1
	ed.cur_track = V
	project_init(&ed.pr)
	defer project_destroy(&ed.pr)
	defer delete(ed.pending)
	defer delete(ed.status)
	defer preview_stop(&ed.pv) // frees any plan the follow code submitted
	append(
		&ed.pr.media,
		Media {
			path = strings.clone("/tmp/a.mp4"),
			name = strings.clone("a.mp4"),
			duration = 10,
			width = 1280,
			height = 720,
			fps = 30,
			has_video = true,
		},
	)
	a := append_clip(&ed.pr, V, 0, 0, 3) // [0, 3)
	b := append_clip(&ed.pr, V, 0, 0, 2) // [3, 5)

	// Three frames: one to build the tree, one for its geometry to be
	// readable, one with the rectangle in hand.
	step(ed, off)
	step(ed, off)
	step(ed, off)
	check(ed.tl.w > 0 && ed.tl.h > 0, "the timeline panel has a rectangle, got %v", ed.tl)
	if ed.tl.w <= 0 {
		return
	}

	// --- click a clip -----------------------------------------------------
	mid_y := track_y(ed, V) + TRACK_H / 2
	p.move_pointer(off, time_to_x(ed, 1.5), mid_y)
	p.press(off)
	step(ed, off)
	check(ed.sel == a, "pressing inside the first clip selected it")
	check(ed.drag == .Move, "and started a move, got %v", ed.drag)
	check(ed.cur_track == V, "and focused its track")

	// --- drag it ----------------------------------------------------------
	p.move_pointer(off, time_to_x(ed, 2.5), mid_y)
	step(ed, off)
	_, ai := find_clip(&ed.pr, a)
	near(ed.pr.tracks[V].clips[ai].start, 1.0, "dragging a second to the right moved it a second")
	near(clip_len(ed.pr.tracks[V].clips[ai]), 3.0, "and a move does not change its length")

	// --- the snap ---------------------------------------------------------
	// Aim for a start of 2.95: within the 10px tolerance of the next clip's
	// start at 3.0, so it should land exactly on the edge.
	p.move_pointer(off, time_to_x(ed, 2.95 + 1.5), mid_y)
	step(ed, off)
	_, ai = find_clip(&ed.pr, a)
	near(ed.pr.tracks[V].clips[ai].start, 3.0, "a near miss snapped to the neighbour's edge")
	check(ed.snap_show, "and the snap guide is showing")

	p.release(off)
	step(ed, off)
	check(ed.drag == .None, "releasing ended the drag")
	check(!ed.snap_show, "and hid the snap guide")

	// Put the first clip back at the origin. The snap left it starting exactly
	// where the second one does, and two clips sharing an edge is the one case
	// where "which clip is under the pointer" has no useful answer.
	_, ai = find_clip(&ed.pr, a)
	move_clip(&ed.pr, V, ai, V, 0)
	step(ed, off)

	// --- trim by the edge --------------------------------------------------
	_, bi := find_clip(&ed.pr, b)
	bstart := ed.pr.tracks[V].clips[bi].start
	p.move_pointer(off, time_to_x(ed, bstart) + 2, mid_y)
	p.press(off)
	step(ed, off)
	check(ed.sel == b, "pressing on the left edge selected that clip")
	check(ed.drag == .Trim_In, "and started an in-point trim, got %v", ed.drag)

	p.move_pointer(off, time_to_x(ed, bstart + 0.5), mid_y)
	step(ed, off)
	_, bi = find_clip(&ed.pr, b)
	near(ed.pr.tracks[V].clips[bi].src_in, 0.5, "trimming the in edge moved the source in point")
	near(ed.pr.tracks[V].clips[bi].start, bstart + 0.5, "and the clip start with it")
	p.release(off)
	step(ed, off)

	// --- the out edge ------------------------------------------------------
	_, bi = find_clip(&ed.pr, b)
	bend := clip_end(ed.pr.tracks[V].clips[bi])
	p.move_pointer(off, time_to_x(ed, bend) - 2, mid_y)
	p.press(off)
	step(ed, off)
	check(ed.drag == .Trim_Out, "pressing the right edge starts an out-point trim, got %v", ed.drag)
	p.move_pointer(off, time_to_x(ed, bend - 0.5), mid_y)
	step(ed, off)
	_, bi = find_clip(&ed.pr, b)
	near(clip_end(ed.pr.tracks[V].clips[bi]), bend - 0.5, "the out edge followed the pointer")
	p.release(off)
	step(ed, off)

	// --- drag to another track -----------------------------------------------
	_, ai = find_clip(&ed.pr, a)
	p.move_pointer(off, time_to_x(ed, 1.0), mid_y)
	p.press(off)
	step(ed, off)
	check(ed.sel == a, "picked the first clip up again")
	// V2 is the track above V1; dropping on it re-parents the clip.
	p.move_pointer(off, time_to_x(ed, 1.0), track_y(ed, 0) + TRACK_H / 2)
	step(ed, off)
	at, _ := find_clip(&ed.pr, a)
	check(at == 0, "dragging onto the upper video track moved it there, landed on %d", at)
	check(len(ed.pr.tracks[V].clips) == 1, "and the old track lost it")
	// An audio track must refuse a video clip rather than silently take it.
	p.move_pointer(off, time_to_x(ed, 1.0), track_y(ed, 2) + TRACK_H / 2)
	step(ed, off)
	at2, _ := find_clip(&ed.pr, a)
	check(at2 == 0, "an audio track refuses a video clip, it stayed on %d", at2)
	p.release(off)
	step(ed, off)

	// --- the M and S buttons in the name gutter -------------------------------
	check(!ed.pr.tracks[2].mute, "A1 starts unmuted")
	p.move_pointer(off, ed.tl.x + 16, track_y(ed, 2) + 33)
	p.press(off)
	step(ed, off)
	check(ed.pr.tracks[2].mute, "clicking M in the gutter muted the track")
	p.release(off)
	step(ed, off)
	p.move_pointer(off, ed.tl.x + 38, track_y(ed, 2) + 33)
	p.press(off)
	step(ed, off)
	check(ed.pr.tracks[2].solo, "clicking S soloed it")
	p.release(off)
	step(ed, off)
	ed.pr.tracks[2].mute, ed.pr.tracks[2].solo = false, false

	// --- the ruler scrubs ---------------------------------------------------
	p.move_pointer(off, time_to_x(ed, 2.0), ed.tl.y + RULER_H / 2)
	p.press(off)
	step(ed, off)
	check(ed.drag == .Scrub, "pressing the ruler scrubs, got %v", ed.drag)
	near(ed.playhead, 2.0, "and put the playhead where the pointer is", 0.02)
	p.move_pointer(off, time_to_x(ed, 4.0), ed.tl.y + RULER_H / 2)
	step(ed, off)
	near(ed.playhead, 4.0, "dragging the ruler carries the playhead", 0.02)
	p.release(off)
	step(ed, off)

	// --- empty track space also scrubs ---------------------------------------
	empty_y := track_y(ed, 3) + TRACK_H / 2 // A2 has nothing on it
	p.move_pointer(off, time_to_x(ed, 1.0), empty_y)
	p.press(off)
	step(ed, off)
	check(ed.drag == .Scrub, "pressing empty track space scrubs rather than selecting")
	near(ed.playhead, 1.0, "and moves the playhead there", 0.02)
	p.release(off)
	step(ed, off)
}
