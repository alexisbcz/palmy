package main

// `captions --selftest` runs the whole pipeline with no compositor and no
// window: it synthesises speech with espeak-ng from a sentence it already
// knows, transcribes it with whisper.cpp, and checks the transcript against
// the ground truth — then checks every timecode edge case the three subtitle
// formats have.
//
// The speech is synthetic on purpose. This machine has a microphone, and a
// test that recorded from it would leave a recording of whoever was in the
// room in the cache directory. espeak-ng gives reproducible audio with known
// text, which is also the only way to assert on accuracy rather than eyeball
// it.
//
// Word errors are *reported, not hidden*. whisper hears "A quick brown fox"
// where the fixture said "The quick brown fox"; the test allows a word error
// rate up to a stated threshold and prints the rate it actually measured.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
pass_n: int
@(private = "file")
fail_n: int

@(private = "file")
check :: proc(name: string, ok: bool, detail: string = "") -> bool {
	if ok {
		pass_n += 1
	} else {
		fail_n += 1
	}
	if detail == "" {
		fmt.printfln("%s  %s", ok ? "pass" : "FAIL", name)
	} else {
		fmt.printfln("%s  %-52s  %s", ok ? "pass" : "FAIL", name, detail)
	}
	return ok
}

@(private = "file")
check_eq :: proc(name: string, got, want: string) -> bool {
	ok := got == want
	return check(name, ok, ok ? fmt.tprintf("%q", got) : fmt.tprintf("got %q want %q", got, want))
}

@(private = "file")
near :: proc(a, b, eps: f64) -> bool {
	return math.abs(a - b) <= eps
}

@(private = "file")
rule :: proc(title: string) {
	fmt.printfln("\n-- %s %s", title, strings.repeat("-", max(2, 60 - len(title)), context.temp_allocator))
}

// FIXTURE_TEXT is what espeak-ng is told to say. Three pangram-ish sentences,
// so the transcript has sentence boundaries to put segment breaks on.
FIXTURE_TEXT ::
	"The quick brown fox jumps over the lazy dog. " +
	"Pack my box with five dozen liquor jugs. " +
	"Bright vixens jump for quick waltz."

// WER_LIMIT is the accuracy bar. `base.en` on synthetic espeak speech scores
// well under this; the headroom is for the substitutions a small model always
// makes on function words.
WER_LIMIT :: 0.30

selftest :: proc() -> int {
	fmt.println("palmy captions — self test")
	fmt.println(strings.repeat("=", 72, context.temp_allocator))

	// -----------------------------------------------------------------------
	rule("timecode formatting")
	// -----------------------------------------------------------------------
	check_eq("SRT zero", srt_timecode(0), "00:00:00,000")
	check_eq("SRT one millisecond", srt_timecode(0.001), "00:00:00,001")
	check_eq("SRT sub-second rounds to nearest ms", srt_timecode(1.23456), "00:00:01,235")
	check_eq("SRT just under an hour", srt_timecode(3599.999), "00:59:59,999")
	check_eq("SRT exactly an hour", srt_timecode(3600), "01:00:00,000")
	check_eq("SRT over an hour", srt_timecode(3661.5), "01:01:01,500")
	check_eq("SRT just under a day", srt_timecode(86399.999), "23:59:59,999")
	check_eq("SRT past a day keeps the hour count", srt_timecode(90061.25), "25:01:01,250")
	check_eq("SRT clamps a negative to zero", srt_timecode(-5), "00:00:00,000")

	check_eq("VTT uses a period", vtt_timecode(3661.5), "01:01:01.500")
	check_eq("VTT zero", vtt_timecode(0), "00:00:00.000")

	check_eq("ASS one hour digit, centiseconds", ass_timecode(3661.5), "1:01:01.50")
	check_eq("ASS zero", ass_timecode(0), "0:00:00.00")
	check_eq("ASS rounds to centiseconds", ass_timecode(1.238), "0:00:01.24")
	check_eq("ASS just under a minute", ass_timecode(59.995), "0:01:00.00")

	// -----------------------------------------------------------------------
	rule("timecode round trip")
	// -----------------------------------------------------------------------
	for v in ([?]f64{0, 0.001, 0.5, 1.237, 59.999, 60, 3599.999, 3600, 3661.5, 86399.999}) {
		a, ok_a := parse_timecode(srt_timecode(v))
		b, ok_b := parse_timecode(vtt_timecode(v))
		check(
			fmt.tprintf("round trip %.3fs through SRT and VTT", v),
			ok_a && ok_b && near(a, v, 0.0006) && near(b, v, 0.0006),
			fmt.tprintf("srt=%.4f vtt=%.4f", a, b),
		)
	}
	{
		a, ok := parse_timecode(ass_timecode(3661.5))
		check("round trip through ASS centiseconds", ok && near(a, 3661.5, 0.005), fmt.tprintf("%.3f", a))
	}
	{
		// A bare MM:SS.mmm cue, which some writers emit.
		a, ok := parse_timecode("01:02.500")
		check("parses MM:SS.mmm", ok && near(a, 62.5, 0.001), fmt.tprintf("%.3f", a))
	}
	{
		_, ok := parse_timecode("not a timecode")
		check("rejects nonsense", !ok)
	}

	// -----------------------------------------------------------------------
	rule("escaping")
	// -----------------------------------------------------------------------
	check_eq(
		"VTT escapes the three XML entities",
		vtt_body("5 < 6 & 7 > 6"),
		"5 &lt; 6 &amp; 7 &gt; 6",
	)
	check_eq("VTT keeps a line break", vtt_body("one\ntwo"), "one\ntwo")
	check_eq("SRT collapses a blank line inside a cue", srt_body("one\n\n\ntwo"), "one\ntwo")
	check_eq("ASS line break becomes \\N", ass_body("one\ntwo"), "one\\Ntwo")
	check_eq("ASS escapes braces", ass_body("{i}talic{/i}"), "\\{i\\}talic\\{/i\\}")
	check_eq("ASS doubles a backslash", ass_body("a\\b"), "a\\\\b")
	check_eq("ASS hard-spaces the edges", ass_body(" hi "), "\\hhi")
	check_eq("ASS colour is &HAABBGGRR, alpha inverted", ass_colour(0xff8800, 1), "&H000088FF")
	check_eq("ASS colour at half opacity", ass_colour(0x000000, 0.5), "&H80000000")
	check_eq("ASS colour fully transparent", ass_colour(0xffffff, 0), "&HFFFFFFFF")

	// -----------------------------------------------------------------------
	rule("document shapes")
	// -----------------------------------------------------------------------
	segs := make([dynamic]Seg)
	append(&segs, seg_make(0, 2.5, "First caption"))
	append(&segs, seg_make(2.5, 5, "Second caption\nover two lines"))
	append(&segs, seg_make(3600, 3602.25, "An hour in, with < & >"))

	srt := write_srt(segs[:])
	{
		lines := strings.split_lines(srt, context.temp_allocator)
		check("SRT first line is the index 1", len(lines) > 0 && lines[0] == "1")
		check(
			"SRT second line is the timing",
			len(lines) > 1 && lines[1] == "00:00:00,000 --> 00:00:02,500",
			len(lines) > 1 ? lines[1] : "",
		)
		check("SRT separates cues with a blank line", strings.contains(srt, "\n\n"))
		check("SRT numbers all three cues", strings.contains(srt, "\n3\n"))
		check(
			"SRT writes the hour-plus cue",
			strings.contains(srt, "01:00:00,000 --> 01:00:02,250"),
		)
		check("SRT leaves the text unescaped", strings.contains(srt, "with < & >"))
		check("SRT keeps the in-cue line break", strings.contains(srt, "Second caption\nover two"))
	}

	vtt := write_vtt(segs[:])
	check("VTT starts with the WEBVTT header", strings.has_prefix(vtt, "WEBVTT\n\n"))
	check("VTT timings use a period", strings.contains(vtt, "00:00:00.000 --> 00:00:02.500"))
	check("VTT escapes the cue text", strings.contains(vtt, "with &lt; &amp; &gt;"))

	st := default_style()
	ass := write_ass(segs[:], st, 1920, 1080)
	check("ASS has a Script Info section", strings.contains(ass, "[Script Info]"))
	check("ASS declares the play resolution", strings.contains(ass, "PlayResX: 1920"))
	check("ASS has a V4+ Styles section", strings.contains(ass, "[V4+ Styles]"))
	check("ASS style Format line is the 23-field one", strings.contains(ass, "Format: Name, Fontname, Fontsize, PrimaryColour"))
	check("ASS has an Events section", strings.contains(ass, "[Events]"))
	check(
		"ASS event Format line ends with Text",
		strings.contains(ass, "Effect, Text"),
	)
	{
		n := strings.count(ass, "Dialogue: ")
		check("ASS writes one Dialogue per caption", n == 3, fmt.tprintf("%d", n))
		check(
			"ASS Dialogue carries the centisecond timing",
			strings.contains(ass, "Dialogue: 0,1:00:00.00,1:00:02.25,Default,,0,0,0,,"),
		)
		fields := 0
		for line in strings.split_lines(ass, context.temp_allocator) {
			if strings.has_prefix(line, "Style: ") {
				fields = len(strings.split(line[len("Style: "):], ",", context.temp_allocator))
				break
			}
		}
		check("ASS Style line has 23 fields", fields == 23, fmt.tprintf("%d fields", fields))
	}
	{
		boxed := st
		boxed.box = true
		boxed.box_rgb = 0x101010
		boxed.box_opacity = 0.5
		out := write_ass(segs[:], boxed, 1280, 720)
		check("ASS background box selects BorderStyle 3", strings.contains(out, ",3,6.0,0.0,"))
		// libass draws the BorderStyle-3 box in OutlineColour; BackColour is
		// the shadow. Verified by burning a script in and looking at a frame.
		check(
			"ASS box colour goes into OutlineColour",
			strings.contains(out, ",&H80101010,&H00000000,"),
			ass_style_line(out),
		)
		check("ASS play resolution follows the source", strings.contains(out, "PlayResY: 720"))
	}
	{
		plain := write_ass(segs[:], st, 1920, 1080)
		check(
			"without a box, OutlineColour is the outline and BackColour the shadow",
			strings.contains(plain, ",&H00FFFFFF,&H00000000,&H80000000,"),
			ass_style_line(plain),
		)
	}
	{
		top := st
		top.pos = .Top
		out := write_ass(segs[:], top, 1920, 1080)
		check("ASS top position is alignment 8", strings.contains(out, ",8,48,48,54,1"))
	}

	txt := write_txt(segs[:])
	check("plain text flattens an in-cue break to a space", strings.contains(txt, "Second caption over two lines"))
	check("plain text has one line per caption", len(strings.split_lines(strings.trim_space(txt), context.temp_allocator)) == 3)

	// -----------------------------------------------------------------------
	rule("re-reading what we wrote")
	// -----------------------------------------------------------------------
	{
		back, err := parse_cues(srt, context.allocator)
		check("SRT parses back", err == "" && len(back) == 3, fmt.tprintf("%d cues, %s", len(back), err))
		if len(back) == 3 {
			check(
				"SRT round trip keeps the times",
				near(back[0].start, 0, 0.0005) &&
				near(back[1].end, 5, 0.0005) &&
				near(back[2].start, 3600, 0.0005),
				fmt.tprintf("%.3f %.3f %.3f", back[0].start, back[1].end, back[2].start),
			)
			check_eq("SRT round trip keeps the text", seg_text(back[1]), "Second caption\nover two lines")
			check_eq("SRT round trip keeps the raw < & >", seg_text(back[2]), "An hour in, with < & >")
		}
		re := write_srt(back[:])
		check("writing the re-read cues is byte-identical", re == srt)
	}
	{
		back, err := parse_cues(vtt, context.allocator)
		check("VTT parses back", err == "" && len(back) == 3, fmt.tprintf("%d cues, %s", len(back), err))
		if len(back) == 3 {
			check_eq("VTT round trip unescapes the entities", seg_text(back[2]), "An hour in, with < & >")
		}
	}
	{
		// A WebVTT file with a header block, a cue identifier and cue settings.
		src :=
			"WEBVTT - with a title\n\nNOTE this is a comment\n\nintro\n" +
			"00:00:01.000 --> 00:00:03.000 line:90% align:middle\nHello there\n\n" +
			"00:00:04.000 --> 00:00:06.000\nSecond\n"
		back, err := parse_cues(src, context.allocator)
		check("VTT with ids, NOTE and cue settings parses", err == "" && len(back) == 2, fmt.tprintf("%d cues", len(back)))
		if len(back) == 2 {
			check("VTT cue settings do not corrupt the end time", near(back[0].end, 3, 0.001), fmt.tprintf("%.3f", back[0].end))
			check_eq("VTT cue text after an id", seg_text(back[0]), "Hello there")
		}
	}

	// -----------------------------------------------------------------------
	rule("editing")
	// -----------------------------------------------------------------------
	{
		ed := make([dynamic]Seg)
		append(&ed, seg_make(0, 4, "One two three four"))
		words := []Word {
			{0.0, 0.5, "One"},
			{0.6, 1.4, "two"},
			{1.5, 2.6, "three"},
			{2.7, 3.9, "four"},
		}
		ok := split_seg(&ed, 0, len("One two "), words)
		check("split makes two captions", ok && len(ed) == 2, fmt.tprintf("%d", len(ed)))
		if len(ed) == 2 {
			check_eq("split keeps the left text", seg_text(ed[0]), "One two")
			check_eq("split keeps the right text", seg_text(ed[1]), "three four")
			check(
				"split lands on the word boundary from the token times",
				near(ed[0].end, 1.5, 0.001) && near(ed[1].start, 1.5, 0.001),
				fmt.tprintf("%.3f / %.3f", ed[0].end, ed[1].start),
			)
			check("split leaves no gap", ed[0].end == ed[1].start)
			check("split preserves the outer span", ed[0].start == 0 && near(ed[1].end, 4, 0.001))
		}
		merge_segs(&ed, 0)
		check("merge restores one caption", len(ed) == 1)
		if len(ed) == 1 {
			check_eq("merge rejoins the text with a space", seg_text(ed[0]), "One two three four")
			check("merge restores the span", ed[0].start == 0 && near(ed[0].end, 4, 0.001))
		}
		check("split refuses to make an empty half", !split_seg(&ed, 0, 0, words))

		// Interpolation when there are no word timings at all.
		ed2 := make([dynamic]Seg)
		append(&ed2, seg_make(10, 20, "abcdefghij"))
		split_seg(&ed2, 0, 5, nil)
		check(
			"split interpolates without word data",
			len(ed2) == 2 && near(ed2[0].end, 15, 0.001),
			len(ed2) == 2 ? fmt.tprintf("%.3f", ed2[0].end) : "",
		)
	}
	{
		lim := default_limits()
		nd := make([dynamic]Seg)
		append(&nd, seg_make(0, 2, "a"))
		append(&nd, seg_make(3, 5, "b"))
		nudge_end(&nd, 0, +2, lim, 10)
		check("nudging an out point stops at the next in point", near(nd[0].end, 3, 0.001), fmt.tprintf("%.3f", nd[0].end))
		nudge_start(&nd, 1, -5, lim)
		check("nudging an in point stops at the previous out point", near(nd[1].start, 3, 0.001), fmt.tprintf("%.3f", nd[1].start))
		nudge_start(&nd, 1, +10, lim)
		check("nudging an in point keeps the minimum duration", near(nd[1].start, 5 - lim.min_dur, 0.001), fmt.tprintf("%.3f", nd[1].start))
		shift_seg(&nd, 1, +100, 10)
		check("shifting keeps the duration", near(seg_duration(nd[1]), lim.min_dur, 0.001), fmt.tprintf("%.3f", seg_duration(nd[1])))
	}
	{
		w := make([dynamic]Seg)
		append(&w, seg_make(0, 5, "The quick brown fox jumps over the lazy dog and keeps on running"))
		auto_wrap(&w[0], 42, 2)
		longest, lines := longest_line(seg_text(w[0]))
		check("auto wrap respects the character limit", longest <= 42, fmt.tprintf("longest %d", longest))
		check("auto wrap respects the line limit", lines <= 2, fmt.tprintf("%d lines", lines))
		check("auto wrap loses no words", len(strings.fields(seg_text(w[0]), context.temp_allocator)) == 13)
	}

	// -----------------------------------------------------------------------
	rule("reading-speed rules")
	// -----------------------------------------------------------------------
	{
		lim := default_limits()
		q := make([dynamic]Seg)
		append(&q, seg_make(0, 1, "This caption has far too many characters to read in a single second"))
		append(&q, seg_make(1.05, 1.2, "Blink"))
		append(&q, seg_make(5, 20, "Lingering"))
		append(&q, seg_make(19, 21, "Overlapping the one before"))

		check("characters per second is counted", near(cps(q[0]), 66, 1), fmt.tprintf("%.1f", cps(q[0])))
		check("line breaks are not counted as characters", visible_chars("ab\ncd") == 4)

		w0 := seg_warnings(q[:], 0, lim)
		check("a caption read too fast is flagged", .Too_Fast in w0)
		check("a caption over the line limit is flagged", .Long_Line in w0)
		check("a tight gap to the next caption is flagged", .Tight_Gap in w0)

		w1 := seg_warnings(q[:], 1, lim)
		check("a caption on screen too briefly is flagged", .Too_Short in w1)

		w2 := seg_warnings(q[:], 2, lim)
		check("a caption on screen too long is flagged", .Too_Long in w2)
		check("an overlap is flagged", .Overlap in w2)

		clean := make([dynamic]Seg)
		append(&clean, seg_make(0, 3, "A comfortable caption"))
		check("a caption inside every limit is not flagged", seg_warnings(clean[:], 0, lim) == {})

		three := make([dynamic]Seg)
		append(&three, seg_make(0, 4, "one\ntwo\nthree"))
		check("more lines than the limit is flagged", .Too_Many_Lines in seg_warnings(three[:], 0, lim))
	}

	// -----------------------------------------------------------------------
	rule("the whisper command line")
	// -----------------------------------------------------------------------
	{
		argv := whisper_argv(
			Transcribe_Opts {
				model = "/m/ggml-base.en.bin",
				lang = "en",
				threads = 4,
				max_len = 42,
				split_word = true,
				wav = "/w/a.wav",
				out_prefix = "/w/out",
			},
		)
		joined := strings.join(argv, " ", context.temp_allocator)
		check("asks for the full JSON with token timings", strings.contains(joined, "-ojf"))
		check("passes the model", strings.contains(joined, "-m /m/ggml-base.en.bin"))
		check("passes the line length and splits on words", strings.contains(joined, "-ml 42 -sow"))
		check("keeps whisper quiet but asks for progress", strings.contains(joined, "-np") && strings.contains(joined, "-pp"))
		check("makes no network request of any kind", !strings.contains(joined, "http"))
	}
	{
		// progress_from_log is what drives the bar on a long file.
		log :=
			"[00:00:00.000 --> 00:00:05.000]   One\n" +
			"[00:00:05.000 --> 00:00:30.000]   Two\n" +
			"whisper_print_progress_callback: progress =  25%\n"
		f := progress_from_log(log, 60)
		check("progress comes from the last segment end", near(f64(f), 0.5, 0.01), fmt.tprintf("%.3f", f))
		check_eq("the last decoded line is shown", last_segment_line(log), "Two")
		check("progress falls back to the percentage", near(f64(progress_from_log("progress =  40%", 0)), 0.4, 0.01))
	}
	{
		check("ffmpeg progress is read from out_time_us", func_ffmpeg_progress())
	}

	// -----------------------------------------------------------------------
	rule("burn-in safety")
	// -----------------------------------------------------------------------
	{
		args := burn_args("/v/in.mp4", "/w/burn.ass", "/v/in.captioned.mp4")
		joined := strings.join(args, " ", context.temp_allocator)
		check("burn-in uses the ass filter", strings.contains(joined, "-vf ass=/w/burn.ass"))
		check("burn-in copies the audio untouched", strings.contains(joined, "-c:a copy"))
		check("burn-in reports machine-readable progress", strings.contains(joined, "-progress pipe:1"))
		check("burn-in writes the chosen output last", strings.has_suffix(joined, "/v/in.captioned.mp4"))
		check("a source and a different output are not the same file", !same_file("/v/in.mp4", "/v/in.captioned.mp4"))
		check("the same path by two spellings is the same file", same_file("/v/in.mp4", "/v/./in.mp4"))
		check_eq("the default output never lands on the source", default_output("/v/in.mp4", ".captioned", "mp4"), "/v/in.captioned.mp4")
	}

	// -----------------------------------------------------------------------
	rule("karaoke: word timings on the caption's own text")
	// -----------------------------------------------------------------------
	{
		// whisper heard "Hello world again"; the user has since made it
		// "Hello, big world again." — a typed word and new punctuation.
		words := [?]Word{{0.1, 0.4, "Hello"}, {0.6, 0.9, "world"}, {1.2, 1.6, "again"}}
		sg := seg_make(0, 2, "Hello, big world again.")
		defer seg_destroy(&sg)
		sp := seg_word_spans(words[:], sg)
		check("four words in the caption's own text", len(sp) == 4, fmt.tprintf("%d", len(sp)))
		if len(sp) == 4 {
			check("\"Hello,\" matches whisper's Hello despite the comma", sp[0].timed && near(sp[0].start, 0.1, 1e-9))
			check("\"big\" was typed, so it is placed between its neighbours", !sp[1].timed && sp[1].start >= 0.4 - 1e-9 && sp[1].start <= 0.6 + 1e-9, fmt.tprintf("%.3f", sp[1].start))
			check("\"world\" and \"again.\" keep whisper's times", sp[2].timed && near(sp[2].start, 0.6, 1e-9) && sp[3].timed && near(sp[3].start, 1.2, 1e-9))
			check_eq("spans index the caption's bytes", seg_text(sg)[sp[2].lo:sp[2].hi], "world")
			check("before the first word nothing is sung", karaoke_sung(sp, 0.05) == 0)
			check_eq("at 0.7s the highlight runs through \"world\"", seg_text(sg)[:karaoke_sung(sp, 0.7)], "Hello, big world")
			check("after the last word starts, all of it", karaoke_sung(sp, 1.9) == len(seg_text(sg)))
		}
		// No word data: spread evenly, and flagged as such.
		bare := seg_make(10, 12, "one two three four")
		defer seg_destroy(&bare)
		even := seg_word_spans(nil, bare)
		mono := true
		for x, i in even {
			if x.timed || (i > 0 && x.start < even[i - 1].start) {
				mono = false
			}
		}
		check("without word data the words are spread over the caption, untimed", len(even) == 4 && mono && near(even[0].start, 10, 1e-9) && even[3].start < 12)

		// The ASS script: one \k per word plus the lead-in, summing to the
		// caption's length, and the karaoke colours in the style.
		kst := default_style()
		kst.karaoke = true
		segs1 := [?]Seg{sg}
		ass := write_ass(segs1[:], kst, 1920, 1080, context.temp_allocator, words[:])
		line := ""
		for l in strings.split_lines(ass, context.temp_allocator) {
			if strings.has_prefix(l, "Dialogue:") {
				line = l
			}
		}
		n_k := strings.count(line, "{\\k")
		check("a \\k tag per word, after a lead-in for the silence before the first", n_k == 5, line)
		total := 0
		rest := line
		for {
			at := strings.index(rest, "{\\k")
			if at < 0 {
				break
			}
			rest = rest[at + 3:]
			end := strings.index(rest, "}")
			v, _ := strconv.parse_int(rest[:end])
			total += v
		}
		check("the durations add up to the caption, in centiseconds", total == 200, fmt.tprintf("%d", total))
		check("the text survives between the tags", strings.contains(line, "Hello,") && strings.contains(line, " big") && strings.contains(line, " again."), line)
		sty := ass_style_line(ass)
		check(
			"karaoke: PrimaryColour is the highlight, SecondaryColour the fill",
			strings.contains(sty, fmt.tprintf("%s,%s", ass_colour(kst.karaoke_rgb, 1), ass_colour(kst.fill, 1))),
			sty,
		)
		plain := write_ass(segs1[:], default_style(), 1920, 1080, context.temp_allocator, words[:])
		check("without karaoke there are no \\k tags", !strings.contains(plain, "{\\k"))
		braces := seg_make(0, 1, "a {b}")
		defer seg_destroy(&braces)
		bk := ass_karaoke_body(braces, nil)
		check("a brace in the text is escaped, not taken for a tag", strings.contains(bk, "\\{b\\}"), bk)
	}

	// -----------------------------------------------------------------------
	rule("speaker turns")
	// -----------------------------------------------------------------------
	{
		// tinydiarize marks the segment *before* a change.
		js := `{"result":{"language":"en"},"transcription":[` +
			`{"offsets":{"from":0,"to":1000},"text":" Did you bring it?","speaker_turn_next":true},` +
			`{"offsets":{"from":1000,"to":2000},"text":" Yes, here.","speaker_turn_next":false},` +
			`{"offsets":{"from":2000,"to":3000},"text":" Thanks.","speaker_turn_next":true},` +
			`{"offsets":{"from":3000,"to":4000},"text":" ","speaker_turn_next":false},` +
			`{"offsets":{"from":4000,"to":5000},"text":" Any time."}]}`
		tr, err := parse_transcript(js, context.temp_allocator)
		check("the diarized JSON parses", err == "" && len(tr.segs) == 4, err)
		if len(tr.segs) == 4 {
			check("the caption after a marked one starts a turn", tr.segs[1].turn && !tr.segs[0].turn && !tr.segs[2].turn)
			check("a turn on an empty segment carries to the next caption", tr.segs[3].turn)
			srt := write_srt(tr.segs[:])
			check("SRT writes a turn as a leading dash", strings.contains(srt, "\n- Yes, here.\n") && strings.contains(srt, "\nDid you bring it?\n"), srt)
			tr.segs[1].text[0] = '-'
			check("and never doubles one the text already has", !strings.contains(write_srt(tr.segs[:]), "- -"))
			vtt := write_vtt(tr.segs[:])
			check("so does WebVTT", strings.contains(vtt, "\n- Any time.\n"))
		}
		argv := whisper_argv(Transcribe_Opts{model = "/m/ggml-small.en-tdrz.bin", diarize = true, translate = false, wav = "/w/a.wav", out_prefix = "/w/o"})
		check("diarizing passes -tdrz", slice_has(argv, "-tdrz"))
		argv2 := whisper_argv(Transcribe_Opts{model = "/m/ggml-base.bin", translate = true, wav = "/w/a.wav", out_prefix = "/w/o"})
		check("translating passes -tr and not -tdrz", slice_has(argv2, "-tr") && !slice_has(argv2, "-tdrz"))
	}

	// -----------------------------------------------------------------------
	rule("where models are looked for")
	// -----------------------------------------------------------------------
	{
		old := os.get_env(MODELS_ENV, context.temp_allocator)
		tmp := fmt.tprintf("%s/selftest-models-%d", work_dir(), os.get_pid())
		os.make_directory_all(tmp)
		fake := fmt.tprintf("%s/ggml-fake.en-tdrz.bin", tmp)
		_, made := kit.run({"truncate", "-s", "21M", fake}, context.temp_allocator)
		os.set_env(MODELS_ENV, tmp)
		dirs := model_dirs()
		check(fmt.tprintf("$%s is searched first", MODELS_ENV), len(dirs) > 0 && dirs[0] == tmp)
		found := false
		for mm in find_models(context.temp_allocator) {
			if mm.name == "fake.en-tdrz" {
				found = mm.diarize && !mm.multilingual
			}
		}
		check("a model there is found, and a -tdrz one is known to diarize", made && found)
		os.unset_env(MODELS_ENV)
		gone := true
		for mm in find_models(context.temp_allocator) {
			if mm.name == "fake.en-tdrz" {
				gone = false
			}
		}
		check("and unset, it is not searched", gone)
		if old != "" {
			os.set_env(MODELS_ENV, old)
		}
		os.remove(fake)
		os.remove(tmp)
	}

	// -----------------------------------------------------------------------
	rule("undo and redo")
	// -----------------------------------------------------------------------
	test_history()

	test_cli()

	// -----------------------------------------------------------------------
	rule("model discovery")
	// -----------------------------------------------------------------------
	models := find_models(context.allocator)
	if !check("at least one whisper model is on disk", len(models) > 0, fmt.tprintf("%d found", len(models))) {
		fmt.println("\nno models found — nothing to transcribe with. Searched:")
		for d in model_dirs() {
			fmt.printfln("  %s", expand_path(d))
		}
		return report()
	}
	for m in models {
		fmt.printfln("      %-22s %-9s %s", m.name, human_size(m.bytes), m.multilingual ? "multilingual" : "English only")
	}
	check("a model path is readable", os.exists(models[0].path))

	tools := check_tools()
	check("ffmpeg is installed", tools.ffmpeg)
	check("ffprobe is installed", tools.ffprobe)
	check("whisper-cli is installed", tools.whisper)
	if !kit.has_tool("espeak-ng") {
		check("espeak-ng is installed for the fixture", false)
		return report()
	}
	if !tools.ffmpeg || !tools.ffprobe || !tools.whisper {
		return report()
	}

	// -----------------------------------------------------------------------
	rule("transcribing a known fixture")
	// -----------------------------------------------------------------------
	dir := work_dir()
	fixture := fmt.tprintf("%s/selftest-fixture.wav", dir)
	wav16 := fmt.tprintf("%s/selftest-16k.wav", dir)
	prefix := fmt.tprintf("%s/selftest-out", dir)

	// espeak-ng, never the microphone: reproducible audio with known text, and
	// nothing from this room ends up on disk.
	_, spoke := kit.run({"espeak-ng", "-w", fixture, "-s", "140", FIXTURE_TEXT})
	if !check("espeak-ng synthesised the fixture", spoke && os.exists(fixture)) {
		return report()
	}

	info, perr := probe(fixture, context.allocator)
	if !check("ffprobe reads the fixture", perr == "" && info.duration > 1, fmt.tprintf("%.2fs %s", info.duration, perr)) {
		return report()
	}
	check("the fixture has audio and no video", info.has_audio && !info.has_video)

	if ok, werr := extract_wav(fixture, wav16); !check("16 kHz mono extraction", ok, werr) {
		return report()
	}
	{
		w16, _ := probe(wav16, context.allocator)
		check("the extracted copy has the same duration", near(w16.duration, info.duration, 0.1), fmt.tprintf("%.3f vs %.3f", w16.duration, info.duration))
	}

	peaks := new(Peaks)
	defer free(peaks)
	if ok, perr2 := decode_peaks(fixture, fmt.tprintf("%s/selftest.raw", dir), peaks); check("the waveform decodes", ok, perr2) {
		loud := 0
		for i in 0 ..< peaks.n {
			if peaks.hi[i] > 0.02 || peaks.lo[i] < -0.02 {
				loud += 1
			}
		}
		check("the waveform has signal in it", loud > peaks.n / 10, fmt.tprintf("%d of %d buckets", loud, peaks.n))
		check("the waveform stays inside full scale", peaks.hi[0] <= 1 && peaks.lo[0] >= -1)
	}

	// Prefer the English-only model: it is the fast one and the fixture is
	// English. Fall back to whatever was found.
	model := models[0]
	for m in models {
		if !m.multilingual {
			model = m
			break
		}
	}
	fmt.printfln("      transcribing %.2fs with %s", info.duration, model.name)

	t0 := time.tick_now()
	argv := whisper_argv(
		Transcribe_Opts {
			model = model.path,
			lang = model.multilingual ? "en" : "",
			threads = 4,
			max_len = 42,
			split_word = true,
			wav = wav16,
			out_prefix = prefix,
		},
		context.temp_allocator,
	)
	_, ran := kit.run(argv, context.temp_allocator)
	elapsed := time.duration_seconds(time.tick_since(t0))
	if !check("whisper-cli ran", ran) {
		return report()
	}
	rtf := info.duration / max(elapsed, 0.0001)
	fmt.printfln("      %.2fs of audio in %.2fs — %.1fx realtime", info.duration, elapsed, rtf)
	check("the realtime factor is above 1x on this machine", rtf > 1, fmt.tprintf("%.2fx", rtf))

	tr, terr := load_transcript(fmt.tprintf("%s.json", prefix), context.allocator)
	if !check("whisper's JSON parses", terr == "", terr) {
		return report()
	}
	check("there is at least one segment", len(tr.segs) > 0, fmt.tprintf("%d", len(tr.segs)))
	check("token timings came through as words", len(tr.words) > 5, fmt.tprintf("%d words", len(tr.words)))

	// --- timing assertions --------------------------------------------------
	monotonic := true
	in_range := true
	non_empty := true
	for s, i in tr.segs {
		if s.end < s.start {
			monotonic = false
		}
		if i > 0 && s.start < tr.segs[i - 1].start - 0.0001 {
			monotonic = false
		}
		if s.start < -0.0001 || s.end > info.duration + 0.5 {
			in_range = false
		}
		if strings.trim_space(seg_text(s)) == "" {
			non_empty = false
		}
	}
	check("segment timestamps are monotonic", monotonic)
	check("segment timestamps are inside the audio", in_range, fmt.tprintf("duration %.3f", info.duration))
	check("no segment is empty", non_empty)
	{
		words_mono := true
		for w, i in tr.words {
			if w.end < w.start - 0.0001 {
				words_mono = false
			}
			if i > 0 && w.start < tr.words[i - 1].start - 0.0001 {
				words_mono = false
			}
		}
		check("word timestamps are monotonic", words_mono)
	}
	{
		covered := f64(0)
		for s in tr.segs {
			covered += seg_duration(s)
		}
		check(
			"the segments cover most of the audio",
			covered > info.duration * 0.5,
			fmt.tprintf("%.2fs of %.2fs", covered, info.duration),
		)
	}

	// --- accuracy -----------------------------------------------------------
	b := strings.builder_make(context.temp_allocator)
	for s, i in tr.segs {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, seg_text(s))
	}
	heard := strings.to_string(b)
	rate, edits, ref_n := word_error_rate(FIXTURE_TEXT, heard)

	fmt.println("      said:  ", normalise(FIXTURE_TEXT))
	fmt.println("      heard: ", normalise(heard))
	fmt.printfln("      word error rate %.1f%% (%d edits over %d words)", rate * 100, edits, ref_n)
	check(
		fmt.tprintf("word error rate is under %.0f%%", WER_LIMIT * 100),
		rate <= WER_LIMIT,
		fmt.tprintf("%.1f%%", rate * 100),
	)
	{
		// The content words a small model should not miss.
		got := normalise(heard)
		for w in ([?]string{"quick", "brown", "fox", "lazy", "dog", "box", "dozen", "jugs"}) {
			check(fmt.tprintf("heard the word %q", w), strings.contains(got, w))
		}
	}

	// --- the full export path, on a real transcript -------------------------
	rule("exporting a real transcript")
	for f in ([?]Format{.SRT, .VTT, .ASS, .TXT}) {
		path := fmt.tprintf("%s/selftest.%s", dir, format_ext(f))
		ok, serr := save_subtitles(path, f, tr.segs[:], st, 1920, 1080)
		check(fmt.tprintf("%s is written", format_ext(f)), ok, serr)
	}
	{
		back, err := load_cues(fmt.tprintf("%s/selftest.srt", dir), context.allocator)
		check(
			"the exported SRT reads back with the same cue count",
			err == "" && len(back) == len(tr.segs),
			fmt.tprintf("%d vs %d", len(back), len(tr.segs)),
		)
		if err == "" && len(back) == len(tr.segs) {
			same := true
			for s, i in back {
				if !near(s.start, tr.segs[i].start, 0.0006) || !near(s.end, tr.segs[i].end, 0.0006) {
					same = false
				}
			}
			check("the exported SRT reads back with the same timings", same)
		}
	}
	{
		// The other half of this pair reads these files with ffmpeg, so let
		// ffprobe be the judge of whether each one is the format it claims.
		for pair in ([?][2]string{{"srt", "subrip"}, {"vtt", "webvtt"}, {"ass", "ass"}}) {
			path := fmt.tprintf("%s/selftest.%s", dir, pair[0])
			out, ok := kit.run(
				{
					"ffprobe",
					"-v",
					"error",
					"-show_entries",
					"stream=codec_name",
					"-of",
					"default=nw=1:nk=1",
					path,
				},
				context.temp_allocator,
			)
			check(
				fmt.tprintf("ffprobe identifies the %s as %s", pair[0], pair[1]),
				ok && strings.trim_space(out) == pair[1],
				fmt.tprintf("%q", strings.trim_space(out)),
			)
		}
		// And that a remux of the cues keeps every one of them, which is what
		// a video editor laying the track in actually does.
		for ext in ([?]string{"srt", "vtt"}) {
			out, ok := kit.run(
				{"ffmpeg", "-v", "error", "-i", fmt.tprintf("%s/selftest.%s", dir, ext), "-f", "srt", "-"},
				context.temp_allocator,
			)
			n := strings.count(out, " --> ")
			check(
				fmt.tprintf("ffmpeg remuxes every cue out of the %s", ext),
				ok && n == len(tr.segs),
				fmt.tprintf("%d of %d", n, len(tr.segs)),
			)
		}
	}
	if !tools.libass {
		fmt.println("      skipped the libass checks: this ffmpeg has no libass (it cannot burn in)")
	} else {
		// ffmpeg is the real consumer of the ASS, so let it be the judge.
		ass_path := fmt.tprintf("%s/selftest.ass", dir)
		probe_out := fmt.tprintf("%s/selftest-ass.mkv", dir)
		_, ok := kit.run(
			{
				"ffmpeg",
				"-v",
				"error",
				"-y",
				"-f",
				"lavfi",
				"-i",
				"color=c=black:s=320x180:d=1",
				"-vf",
				fmt.tprintf("ass=%s", ass_path),
				"-frames:v",
				"6",
				probe_out,
			},
			context.temp_allocator,
		)
		check("ffmpeg's ass filter accepts the script we wrote", ok && os.exists(probe_out))
		os.remove(probe_out)
	}

	// -----------------------------------------------------------------------
	rule("karaoke on a real transcript")
	// -----------------------------------------------------------------------
	{
		timed, total := 0, 0
		for s in tr.segs {
			for sp in seg_word_spans(tr.words[:], s) {
				total += 1
				if sp.timed {
					timed += 1
				}
			}
		}
		check("most of the transcript's words carry whisper's own time", total > 0 && f64(timed) >= 0.8 * f64(total), fmt.tprintf("%d of %d", timed, total))
		kst := default_style()
		kst.karaoke = true
		kst.size = 30
		ass := write_ass(tr.segs[:], kst, 640, 360, context.temp_allocator, tr.words[:])
		kpath := fmt.tprintf("%s/selftest-karaoke.ass", dir)
		_ = os.write_entire_file(kpath, transmute([]u8)ass)
		if !tools.libass {
			fmt.println("      skipped the burned frame: this ffmpeg has no libass")
		}
		// A frame from the middle of the first caption, burned by libass:
		// some of the line must be in the highlight and some still in the
		// fill. That is what "word by word" looks like in pixels.
		s0 := tr.segs[0]
		sp0 := seg_word_spans(tr.words[:], s0)
		at := s0.start + (s0.end - s0.start) * 0.5
		if len(sp0) >= 3 {
			at = (sp0[1].start + sp0[2].start) / 2 // after the second word starts
		}
		raw, ok := kit.run(
			{
				"sh", "-c",
				fmt.tprintf(
					"ffmpeg -v error -f lavfi -i color=c=black:s=640x360:d=%.2f -vf ass=%s -ss %.3f -frames:v 1 -f rawvideo -pix_fmt rgb24 - | od -An -v -tu1 -w3",
					info.duration,
					kpath,
					at,
				),
			},
			context.temp_allocator,
		)
		hi, fill := 0, 0
		if ok && tools.libass {
			body := raw
			for line in strings.split_lines_iterator(&body) {
				f := strings.fields(line, context.temp_allocator)
				if len(f) != 3 {
					continue
				}
				r, _ := strconv.parse_int(f[0])
				g, _ := strconv.parse_int(f[1])
				b, _ := strconv.parse_int(f[2])
				if r > 200 && g > 150 && b < 110 {
					hi += 1 // the karaoke yellow, 0xffe066
				} else if r > 200 && g > 200 && b > 200 {
					fill += 1 // still white
				}
			}
		}
		if tools.libass {
			check("libass draws the spoken words in the highlight", ok && hi > 50, fmt.tprintf("%d highlight pixels at %.2fs", hi, at))
			check("and the words still to come in the fill", fill > 50, fmt.tprintf("%d fill pixels", fill))
		}
	}

	// -----------------------------------------------------------------------
	rule("translation, end to end")
	// -----------------------------------------------------------------------
	// The largest multilingual model: measured on this fixture, base turns
	// espeak-ng's French into "Be careful! ... I'll see you later" and small
	// into "Today, we will talk about the meteor. It's going to rain
	// tomorrow, but the sun will come in the afternoon."
	ml := -1
	for mm, i in models {
		if mm.multilingual && (ml < 0 || mm.bytes > models[ml].bytes) {
			ml = i
		}
	}
	if ml < 0 {
		fmt.println("      skipped: no multilingual model here, and -tr needs one (an .en model cannot translate)")
	} else {
		fr := fmt.tprintf("%s/selftest-fr.wav", dir)
		fr16 := fmt.tprintf("%s/selftest-fr16.wav", dir)
		_, spoke_fr := kit.run({"espeak-ng", "-v", "fr", "-s", "125", "-w", fr, FRENCH_TEXT})
		ok16, _ := extract_wav(fr, fr16)
		check("espeak-ng spoke the French fixture", spoke_fr && ok16)
		fpre := fmt.tprintf("%s/selftest-tr", dir)
		t1 := time.tick_now()
		fargv := whisper_argv(
			Transcribe_Opts{model = models[ml].path, lang = "auto", threads = 8, max_len = 42, split_word = true, translate = true, wav = fr16, out_prefix = fpre},
			context.temp_allocator,
		)
		_, fran := kit.run(fargv, context.temp_allocator)
		ftr, ferr := load_transcript(fmt.tprintf("%s.json", fpre), context.allocator)
		check(fmt.tprintf("whisper -tr ran with %s", models[ml].name), fran && ferr == "", ferr)
		fb := strings.builder_make(context.temp_allocator)
		for s in ftr.segs {
			strings.write_string(&fb, seg_text(s))
			strings.write_byte(&fb, ' ')
		}
		heard_en := normalise(strings.to_string(fb))
		fmt.printfln("      said (fr): %s", FRENCH_TEXT)
		fmt.printfln("      heard (en): %s   [%.0fs]", heard_en, time.duration_seconds(time.tick_since(t1)))
		check_eq("whisper detected French", ftr.lang, "fr")
		en := 0
		for w in ([?]string{"weather", "rain", "tomorrow", "morning", "sun", "afternoon", "today", "talk"}) {
			if strings.contains(heard_en, w) {
				en += 1
			}
		}
		check("the captions are English: at least two of the content words came through", en >= 2, fmt.tprintf("%d of 8", en))
		fr_left := false
		for w in ([?]string{"demain", "pluie", "soleil", "aujourd", "bonjour", "parler"}) {
			if strings.contains(heard_en, w) {
				fr_left = true
			}
		}
		check("and none of the French is left", !fr_left)
	}

	// -----------------------------------------------------------------------
	rule("speaker turns, end to end")
	// -----------------------------------------------------------------------
	td := -1
	for mm, i in models {
		if mm.diarize {
			td = i
			break
		}
	}
	if td < 0 {
		fmt.println("      skipped: no tinydiarize model here (ggml-small.en-tdrz.bin)")
	} else {
		// Two synthetic voices taking turns. tinydiarize was trained on real
		// meetings and, measured, marks no turns between espeak-ng (or flite)
		// voices however different they are made; what is asserted here is
		// the pipeline — -tdrz accepted, the JSON read, the turns counted —
		// and the count is reported rather than asserted.
		parts := [?][2]string {
			{"en-us+m1", "Good morning. Did you bring the report about the river project?"},
			{"en+f5", "Yes, I finished it last night. The water levels are much higher than we expected."},
			{"en-us+m1", "That is worrying. We should call the engineers this afternoon."},
		}
		files := make([dynamic]string, context.temp_allocator)
		for part, i in parts {
			f := fmt.tprintf("%s/selftest-turn%d.wav", dir, i)
			_, _ = kit.run({"espeak-ng", "-v", part[0], "-s", "150", "-w", f, part[1]})
			append(&files, f)
		}
		dlg := fmt.tprintf("%s/selftest-dialog.wav", dir)
		cat := fmt.tprintf("ffmpeg -v error -y -i %s -i %s -i %s -filter_complex concat=n=3:v=0:a=1 -ar 16000 -ac 1 %s", files[0], files[1], files[2], dlg)
		_, cok := kit.run({"sh", "-c", cat})
		dpre := fmt.tprintf("%s/selftest-tdrz", dir)
		dargv := whisper_argv(Transcribe_Opts{model = models[td].path, threads = 8, diarize = true, wav = dlg, out_prefix = dpre}, context.temp_allocator)
		_, dran := kit.run(dargv, context.temp_allocator)
		dtr, derr := load_transcript(fmt.tprintf("%s.json", dpre), context.allocator)
		check(fmt.tprintf("whisper -tdrz ran with %s and its JSON parses", models[td].name), cok && dran && derr == "", derr)
		check("the dialogue came back as captions", len(dtr.segs) >= 3, fmt.tprintf("%d", len(dtr.segs)))
		turns := 0
		for s in dtr.segs {
			if s.turn {
				turns += 1
			}
		}
		fmt.printfln("      %d captions, %d speaker turns marked (synthetic voices; see the note above)", len(dtr.segs), turns)
	}

	return report()
}

// FRENCH_TEXT is the translation fixture: about the weather, so the English
// that comes back has content words that cannot be guessed from nothing.
FRENCH_TEXT :: "Bonjour à tous. Aujourd'hui, nous allons parler de la météo. Il va pleuvoir demain matin, mais le soleil reviendra l'après-midi."

// ass_style_line pulls the Style line out of a script, for an assertion's
// failure detail.
@(private = "file")
ass_style_line :: proc(script: string) -> string {
	for line in strings.split_lines(script, context.temp_allocator) {
		if strings.has_prefix(line, "Style: ") {
			return line
		}
	}
	return ""
}

// func_ffmpeg_progress keeps the ffmpeg progress parse assertion readable.
@(private = "file")
func_ffmpeg_progress :: proc() -> bool {
	log := "frame=10\nout_time_us=1500000\nprogress=continue\nout_time_us=4250000\nprogress=continue\n"
	t, ok := ffmpeg_progress(log)
	return ok && near(t, 4.25, 0.001)
}

@(private = "file")
report :: proc() -> int {
	fmt.println(strings.repeat("=", 72, context.temp_allocator))
	fmt.printfln("%d assertions: %d passed, %d failed", pass_n + fail_n, pass_n, fail_n)
	return fail_n == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// The command line
//
// The binary is run again as a child, the way an agent would run it, against a
// scratch directory: its own cache and audit log, a caption file written here,
// and a clip made by ffmpeg's lavfi sources — a test pattern and a sine tone,
// never a camera or a microphone. The display variables are cleared so a
// mistake in the dispatcher could never open a window and hang the run.
// ---------------------------------------------------------------------------

@(private = "file")
cli_dir: string

@(private = "file")
cli_run :: proc(args: ..string) -> (out: string, code: int) {
	exe, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil {
		exe = os.args[0]
	}
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&line,
		fmt.tprintf(
			"cd %q && WAYLAND_DISPLAY= DISPLAY= XDG_CACHE_HOME=%q PALM_AUDIT=%q %q",
			cli_dir,
			fmt.tprintf("%s/cache", cli_dir),
			fmt.tprintf("%s/audit.jsonl", cli_dir),
			exe,
		),
	)
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	strings.write_string(&line, " 2>/dev/null")
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
schema_ok :: proc(name: string, out: string, fields: []kit.Field) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	check(name, len(problems) == 0, len(problems) > 0 ? problems[0] : "")
}

@(private = "file")
test_cli :: proc() {
	rule("the command line")
	cli_dir = fmt.tprintf("/tmp/palmy-captions-cli-%d", os.get_pid())
	os.make_directory_all(cli_dir)
	defer os.remove_all(cli_dir)

	sf := surface()
	check_eq("the surface is named captions", sf.noun, "captions")
	for cmd in sf.commands {
		check(fmt.tprintf("%s is implemented and declares its output", cmd.verb), cmd.run != nil && len(cmd.out) > 0 && len(cmd.examples) > 0)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(..args[:])
			check(fmt.tprintf("the example parses: %s", ex), words[0] == "captions" && code == 0, fmt.tprintf("exit %d", code))
		}
	}

	{
		out, code := cli_run("tools", "--json")
		check("tools --json exits 0", code == 0)
		schema_ok("and matches its declared schema", out, TOOLS_FIELDS)
	}

	srt := fmt.tprintf("%s/t.srt", cli_dir)
	_ = os.write_entire_file(
		srt,
		transmute([]u8)string("1\n00:00:01,000 --> 00:00:02,500\nA line that runs on far past the forty-two character limit\n\n2\n00:00:02,500 --> 00:00:02,900\nShort\n\n3\n00:00:03,000 --> 00:00:04,000\nThird\n"),
	)
	{
		out, code := cli_run("show", "t.srt", "--json")
		check("show exits 0", code == 0)
		schema_ok("show matches its declared schema", out, SHOW_FIELDS)
		check("and lists every caption", strings.contains(out, `"count": 3`))
		check("with the window's own warnings", strings.contains(out, "line over the character limit"))
	}
	{
		out, code := cli_run("lint", "t.srt", "--json")
		check("lint exits 0 even with problems: it is a read", code == 0)
		schema_ok("lint matches its declared schema", out, LINT_FIELDS)
		check("and names the long line and the short caption", strings.contains(out, "long_line") && strings.contains(out, "too_short"))
	}
	{
		out, code := cli_run("show", "missing.srt", "--json")
		check("a missing file answers 3", code == kit.EXIT_NOT_FOUND)
		schema_ok("with the documented error object", out, {{name = "error", kind = .String}, {name = "code", kind = .Int}, {name = "command", kind = .String}})
	}
	{
		out, code := cli_run("convert", "t.srt", "--to", "vtt", "--json")
		check("convert exits 0", code == 0)
		schema_ok("convert matches its declared schema", out, WROTE_FIELDS)
		segs, err := load_cues(fmt.tprintf("%s/t.vtt", cli_dir), context.temp_allocator)
		check("the WebVTT it wrote reads back through the window's loader", err == "" && len(segs) == 3, err)
		if len(segs) == 3 {
			check("with the timings intact", near(segs[1].start, 2.5, 0.0005) && near(segs[2].end, 4, 0.0005))
		}
		_, same := cli_run("convert", "t.srt", "--to", "srt")
		check("converting a file onto itself is refused", same == kit.EXIT_USAGE)
	}
	{
		out, code := cli_run("shift", "t.srt", "--by", "1.5", "--out", "s.srt", "--json")
		check("shift exits 0", code == 0)
		schema_ok("shift matches its declared schema", out, WROTE_FIELDS)
		segs, _ := load_cues(fmt.tprintf("%s/s.srt", cli_dir), context.temp_allocator)
		check(
			"every caption moved by the same amount",
			len(segs) == 3 && near(segs[0].start, 2.5, 0.0005) && near(segs[1].start, 4, 0.0005) && near(segs[2].end, 5.5, 0.0005),
		)
		_, _ = cli_run("shift", "t.srt", "--by", "-5", "--out", "e.srt")
		early, _ := load_cues(fmt.tprintf("%s/e.srt", cli_dir), context.temp_allocator)
		check("a shift earlier stops at zero rather than going negative", len(early) == 3 && near(early[0].start, 0, 0.0005))
		orig, _ := load_cues(srt, context.temp_allocator)
		check("and --out left the input alone", len(orig) == 3 && near(orig[0].start, 1, 0.0005))
	}
	{
		out, code := cli_run("wrap", "t.srt", "--out", "w.srt", "--json")
		check("wrap exits 0", code == 0)
		check("wrap says what it changed", strings.contains(out, `"rewrapped": 1`))
		segs, _ := load_cues(fmt.tprintf("%s/w.srt", cli_dir), context.temp_allocator)
		check("the long caption is now two lines", len(segs) == 3 && strings.contains(seg_text(segs[0]), "\n"))
	}

	tools := check_tools()
	clip := fmt.tprintf("%s/clip.mp4", cli_dir)
	spoke := false
	if tools.ffmpeg && tools.ffprobe {
		// Synthetic only: a test pattern, and espeak-ng saying two words (a
		// tone when there is no espeak-ng). It used to be a tone always, and
		// the transcribe check below — which only runs where there is a
		// model — then failed on "no speech in this file", which was true.
		speech := fmt.tprintf("%s/hello.wav", cli_dir)
		_, spoke = kit.run({"espeak-ng", "-s", "150", "-w", speech, "Hello there."}, context.temp_allocator)
		audio_in := spoke ? []string{"-i", speech} : []string{"-f", "lavfi", "-i", "sine=frequency=440"}
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25")
		append(&argv, ..audio_in)
		append(&argv, "-af", "apad", "-t", "2", "-c:v", "libx264", "-c:a", "aac", clip)
		_, made := kit.run(argv[:], context.temp_allocator)
		if check("ffmpeg made a synthetic clip from lavfi sources", made && os.exists(clip)) {
			out, code := cli_run("probe", "clip.mp4", "--json")
			check("probe exits 0", code == 0)
			schema_ok("probe matches its declared schema", out, PROBE_FIELDS)
			check("and reports the clip's two seconds and both streams", strings.contains(out, `"duration": 2`) && strings.contains(out, `"has_video": true`) && strings.contains(out, `"has_audio": true`))

			bout, bcode := cli_run("burn", "clip.mp4", "t.srt", "--out", "burned.mp4", "--json")
			if tools.libass {
				check("burn exits 0", bcode == 0, bout)
				schema_ok("burn matches its declared schema", bout, BURN_FIELDS)
				info, perr := probe(fmt.tprintf("%s/burned.mp4", cli_dir), context.temp_allocator)
				check("the burned copy is a video of the same length", perr == "" && info.has_video && near(info.duration, 2, 0.1), perr)
			} else {
				// palmy's own ffmpeg: no libass, so no burn-in — said, not failed.
				check("without libass, burn answers 6, unavailable, and says why", bcode == kit.EXIT_UNAVAILABLE && strings.contains(bout, "libass"), fmt.tprintf("exit %d", bcode))
				check("and writes nothing", !os.exists(fmt.tprintf("%s/burned.mp4", cli_dir)))
			}
			_, over := cli_run("burn", "clip.mp4", "t.srt", "--out", "clip.mp4")
			check("burning over the source is refused", over == kit.EXIT_USAGE)
		}
	}
	{
		out, code := cli_run("transcribe", "clip.mp4", "--json")
		if len(find_models(context.temp_allocator)) == 0 || !tools.whisper {
			check("transcribe with no whisper or no model answers 6, unavailable", code == kit.EXIT_UNAVAILABLE, fmt.tprintf("exit %d", code))
			schema_ok("with the documented error object", out, {{name = "error", kind = .String}, {name = "code", kind = .Int}, {name = "command", kind = .String}})
		} else if spoke {
			check("transcribe exits 0", code == 0, out)
			schema_ok("transcribe matches its declared schema", out, TRANSCRIBE_FIELDS)
		} else {
			check("transcribe of a tone says there is no speech in it", code == kit.EXIT_FAILED && strings.contains(out, "no speech"), out)
		}
	}
	{
		// The new transcribe flags refuse what cannot work before looking for
		// a model, so these answer the same on any machine.
		_, both := cli_run("transcribe", "clip.mp4", "--translate", "--diarize", "--json")
		check("--translate with --diarize is a usage error (they need different models)", both == kit.EXIT_USAGE, fmt.tprintf("exit %d", both))
		_, kar := cli_run("transcribe", "clip.mp4", "--karaoke", "--json")
		check("--karaoke without --format ass is a usage error", kar == kit.EXIT_USAGE, fmt.tprintf("exit %d", kar))
		models := find_models(context.temp_allocator)
		has_ml, has_tdrz := false, false
		for mm in models {
			has_ml |= mm.multilingual
			has_tdrz |= mm.diarize
		}
		if tools.whisper && !has_tdrz {
			out, code := cli_run("transcribe", "clip.mp4", "--diarize", "--json")
			check("--diarize with no tinydiarize model answers 6 and names the model it needs", code == kit.EXIT_UNAVAILABLE && strings.contains(out, "tdrz"), fmt.tprintf("exit %d", code))
		}
		if tools.whisper && len(models) > 0 {
			name := strings.concatenate({"ggml-", models[0].name}, context.temp_allocator)
			_, code := cli_run("transcribe", "clip.mp4", "--model", name, "--dry-run", "--json")
			check(fmt.tprintf("--model takes the ggml- spelling the help shows (%s)", name), code == 0, fmt.tprintf("exit %d", code))
		}
		_ = has_ml
	}
	{
		_, code := cli_run("no-such-thing")
		check("a word that is neither a command nor a file is a usage error, not a window", code == kit.EXIT_USAGE)
	}
}

// ---------------------------------------------------------------------------
// Undo and redo, asserted the way videoedit's are: not per operation, but as
// a property. After any edit, undo must give back the bytes from before it
// and redo the bytes from after, over a long random sequence through the very
// procedures the keys call; then the whole stack unwinds to the start and
// replays to the end.
// ---------------------------------------------------------------------------

@(private = "file")
slice_has :: proc(a: []string, x: string) -> bool {
	for s in a {
		if s == x {
			return true
		}
	}
	return false
}

// hist_bytes is everything a snapshot is meant to restore, as text.
@(private = "file")
hist_bytes :: proc(m: ^App_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s in m.segs {
		fmt.sbprintf(&b, "%.6f|%.6f|%v|%.3f|%s\n", s.start, s.end, s.turn, s.conf, seg_text(s))
	}
	return strings.to_string(b)
}

@(private = "file")
Hrng :: struct {
	s: u64,
}

@(private = "file")
hnext :: proc(r: ^Hrng, n: int) -> int {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return int(r.s % u64(max(n, 1)))
}

// hist_frame is one frame of the window, as far as history is concerned: the
// deferred queue, then the tracker.
@(private = "file")
hist_frame :: proc(m: ^App_State) {
	apply_queue(m)
	history_track(m)
}

test_history :: proc() {
	m := new(App_State)
	defer free(m)
	m.segs = make([dynamic]Seg)
	m.words = make([dynamic]Word)
	m.queue = make([dynamic]Act)
	m.limits = default_limits()
	m.info.duration = 60
	status_echo = false
	defer {
		for &s in m.segs {
			seg_destroy(&s)
		}
		delete(m.segs)
		delete(m.words)
		delete(m.queue)
		history_destroy(m)
	}
	for i in 0 ..< 6 {
		sg := seg_make(f64(i) * 3, f64(i) * 3 + 2.5, fmt.tprintf("caption number %d has a few words in it", i))
		sg.turn = i == 3
		append(&m.segs, sg)
	}
	m.sel = 0
	hist_frame(m)
	start := strings.clone(hist_bytes(m), context.temp_allocator)

	// Typing a word into a caption, one key per frame, is one step.
	m.focus = .Caption
	m.sel = 2
	for ch in "hello" {
		append(&m.segs[2].text, u8(ch))
		hist_frame(m)
	}
	m.focus = .Browse
	check("five keystrokes in one caption are one undo step", len(m.hist.undo) == 1, fmt.tprintf("%d steps", len(m.hist.undo)))
	check_eq("and it is labelled as typing", undo_label(m), "type")
	queue_act(m, .Undo)
	hist_frame(m)
	check("undo takes the whole word back", hist_bytes(m) == start)
	queue_act(m, .Redo)
	hist_frame(m)
	check("redo puts it back", strings.contains(seg_text(m.segs[2]), "in ithello"))
	queue_act(m, .Undo)
	hist_frame(m)

	// A split through the procedure the `s` key calls, labelled by it.
	m.sel = 1
	do_split(m)
	hist_frame(m)
	check_eq("a split is its own step, by name", undo_label(m), "split")
	check("and makes seven captions", len(m.segs) == 7)
	queue_act(m, .Undo)
	hist_frame(m)
	check("undoing the split restores six, byte for byte", len(m.segs) == 6 && hist_bytes(m) == start)
	check("the turn mark survived the round trip", m.segs[3].turn)
	check_eq("and redo knows what it would redo", redo_label(m), "split")

	// Holding `]` walks the in point: one step, while it is one caption.
	history_break(m)
	m.sel = 4
	for _ in 0 ..< 4 {
		m.act_label = "nudge"
		nudge_start(&m.segs, m.sel, 0.1, m.limits)
		hist_frame(m)
	}
	before_nudges := len(m.hist.undo)
	m.sel = 5
	m.act_label = "nudge"
	nudge_start(&m.segs, m.sel, 0.1, m.limits)
	hist_frame(m)
	check("a run of nudges on one caption coalesces, a nudge on another does not", len(m.hist.undo) == before_nudges + 1, fmt.tprintf("%d then %d", before_nudges, len(m.hist.undo)))

	// A fresh edit after an undo throws the redo branch away.
	queue_act(m, .Undo)
	hist_frame(m)
	check("one step to redo after an undo", len(m.hist.redo) == 1)
	m.sel = 0
	if delete_seg(&m.segs, 0) {
		m.act_label = "delete"
	}
	hist_frame(m)
	check("a new edit drops the redo branch, as every editor does", len(m.hist.redo) == 0)

	// The property, over a long random sequence.
	r := Hrng{0x9E3779B97F4A7C15}
	edits, bad := 0, 0
	first_bad := ""
	for _ in 0 ..< 160 {
		history_break(m)
		before := strings.clone(hist_bytes(m), context.temp_allocator)
		n := len(m.segs)
		if n == 0 {
			queue_act(m, .Insert, -1)
			hist_frame(m)
			continue
		}
		m.sel = hnext(&r, n)
		m.caret = 0
		what := ""
		switch hnext(&r, 9) {
		case 0:
			queue_act(m, .Split, m.sel)
			what = "split"
		case 1:
			queue_act(m, .Merge, m.sel)
			what = "merge"
		case 2:
			if n > 3 {
				queue_act(m, .Delete, m.sel)
				what = "delete"
			}
		case 3:
			queue_act(m, .Insert, m.sel)
			what = "insert"
		case 4:
			m.act_label = "nudge"
			nudge_end(&m.segs, m.sel, hnext(&r, 2) == 0 ? -0.1 : 0.1, m.limits, m.info.duration)
			what = "nudge"
		case 5:
			m.act_label = "slide"
			shift_seg(&m.segs, m.sel, hnext(&r, 2) == 0 ? -0.5 : 0.5, m.info.duration)
			what = "slide"
		case 6:
			m.focus = .Caption
			append(&m.segs[m.sel].text, " and more")
			what = "type"
		case 7:
			m.segs[m.sel].turn = !m.segs[m.sel].turn
			what = "turn"
		case 8:
			queue_act(m, .Wrap, m.sel)
			what = "wrap"
		}
		hist_frame(m)
		m.focus = .Browse
		after := strings.clone(hist_bytes(m), context.temp_allocator)
		if after == before {
			continue // a refused edit (a merge at the end, a clamped nudge)
		}
		edits += 1
		queue_act(m, .Undo)
		hist_frame(m)
		u := hist_bytes(m) == before
		queue_act(m, .Redo)
		hist_frame(m)
		rd := hist_bytes(m) == after
		if !u || !rd {
			bad += 1
			if first_bad == "" {
				first_bad = fmt.tprintf("%s: undo %v redo %v", what, u, rd)
			}
		}
	}
	check(fmt.tprintf("over %d random edits, undo gives back the bytes from before and redo the bytes after", edits), bad == 0 && edits > 80, first_bad)
	final := strings.clone(hist_bytes(m), context.temp_allocator)
	depth := 0
	for len(m.hist.undo) > 0 {
		queue_act(m, .Undo)
		hist_frame(m)
		depth += 1
	}
	check(fmt.tprintf("unwinding all %d steps lands on the first state", depth), hist_bytes(m) == start, fmt.tprintf("cap %d", HIST_MAX))
	for len(m.hist.redo) > 0 {
		queue_act(m, .Redo)
		hist_frame(m)
	}
	check("and replaying them lands on the last, byte for byte", hist_bytes(m) == final)
}
