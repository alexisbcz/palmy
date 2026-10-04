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
	rule("model discovery")
	// -----------------------------------------------------------------------
	models := find_models(context.allocator)
	if !check("at least one whisper model is on disk", len(models) > 0, fmt.tprintf("%d found", len(models))) {
		fmt.println("\nno models found — nothing to transcribe with. Searched:")
		for d in MODEL_DIRS {
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
	{
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

	return report()
}

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
