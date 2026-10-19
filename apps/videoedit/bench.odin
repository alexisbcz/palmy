package main

// The two instruments.
//
//   videoedit --undobench            what a whole-document snapshot costs
//   videoedit --audiobench [secs]    the audio clock, measured
//
// Both run headless — no compositor, no window, no fonts — because the numbers
// they produce are the justification for two design decisions and a number you
// cannot reproduce is not a justification.
//
// `--audiobench` is **silent by default**. The clock, the sink's buffering and
// the presentation error are all properties of the byte flow: pw-cat accepts
// bytes at exactly the rate the device consumes them whatever the samples
// contain, so zeroing them changes nothing that is being measured and does not
// fill the room. `--audiobench-loud` plays the mix for real, which is how you
// confirm by ear that there is sound at all; the two runs produce the same
// numbers, which is itself the evidence that the silence is free.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// A reproducible edit sequence
// ---------------------------------------------------------------------------

// Rng is a 64-bit xorshift. It is here rather than `core:math/rand` so that
// the sequence of edits a failure came from is reproducible from the seed
// alone, across compilers and standard-library versions.
Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{s = seed == 0 ? 0x2545F4914F6CDD1D : seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	x := r.s
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.s = x
	return x
}

rng_int :: proc(r: ^Rng, n: int) -> int {
	if n <= 1 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

rng_f64 :: proc(r: ^Rng) -> f64 {
	return f64(rng_next(r) >> 11) / f64(1 << 53)
}

// random_edit performs one edit at random, through the same mark-then-mutate
// discipline the key handlers use — `undo_mark` first, the mutation second.
// That is deliberate: this is the thing being tested, so the test must not
// have its own private path to the model.
//
// Returning "" means nothing was done, which the caller does not count.
random_edit :: proc(ed: ^Editor, r: ^Rng) -> string {
	pr := &ed.pr
	// Pick a track that has clips, so most draws do something.
	switch rng_int(r, 12) {
	case 0:
		// Place a clip from the bin.
		if len(pr.media) == 0 {
			return ""
		}
		ed.bin_sel = rng_int(r, len(pr.media))
		undo_mark(ed, .Place, "place a clip")
		at := rng_f64(r) * 8
		mi := ed.bin_sel
		m := pr.media[mi]
		vt := track_of_kind(pr, m.has_video ? .Video : .Audio, rng_int(r, 2))
		id := insert_clip(pr, vt, mi, at, 0, math.min(m.duration, 1 + rng_f64(r) * 3))
		ed.sel = id
		ed.cur_track = vt
		edited(ed)
		return "place"
	case 1, 2:
		// Split under the playhead.
		ti := rng_int(r, len(pr.tracks))
		ed.cur_track = ti
		seek_to(ed, rng_f64(r) * 8)
		fresh := undo_mark(ed, .Split, "split")
		if _, ok := split_at(pr, ti, ed.playhead); !ok {
			if fresh {
				undo_drop(ed)
			}
			return ""
		}
		edited(ed)
		return "split"
	case 3:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_mark(ed, .Ripple, "ripple delete")
		ripple_delete(pr, t, i)
		ed.sel = -1
		edited(ed)
		return "ripple delete"
	case 4:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_mark(ed, .Lift, "delete")
		lift_delete(pr, t, i)
		ed.sel = -1
		edited(ed)
		return "lift delete"
	case 5, 6:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_break(ed) // each fuzz step is its own gesture
		was := pr.tracks[t].clips[i].start
		undo_mark(ed, .Move, "move a clip", ed.sel)
		id := pr.tracks[t].clips[i].id
		move_clip(pr, t, i, t, rng_f64(r) * 8)
		if _, ci := find_clip(pr, id); ci >= 0 && pr.tracks[t].clips[ci].start == was {
			undo_drop(ed)
			return ""
		}
		edited(ed)
		return "move"
	case 7:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_break(ed)
		if !trimmed(ed, .Trim_In, true, t, i, (rng_f64(r) - 0.5) * 1.5) {
			return ""
		}
		edited(ed)
		return "trim in"
	case 8:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_break(ed)
		if !trimmed(ed, .Trim_Out, false, t, i, (rng_f64(r) - 0.5) * 1.5) {
			return ""
		}
		edited(ed)
		return "trim out"
	case 9:
		t, i, ok := pick_clip(ed, r)
		if !ok {
			return ""
		}
		undo_break(ed)
		was := pr.tracks[t].clips[i].gain
		now := f32(rng_f64(r) * 2)
		if now == was {
			return ""
		}
		undo_mark(ed, .Gain, "change the gain", ed.sel)
		pr.tracks[t].clips[i].gain = now
		edited_audio(ed)
		return "gain"
	case 10:
		ti := rng_int(r, len(pr.tracks))
		undo_break(ed)
		undo_mark(ed, .Track_Flags, "mute a track", ti)
		if rng_int(r, 2) == 0 {
			pr.tracks[ti].mute = !pr.tracks[ti].mute
		} else {
			pr.tracks[ti].solo = !pr.tracks[ti].solo
		}
		edited(ed)
		return "track flags"
	case 11:
		v := track_of_kind(pr, .Video, 0)
		undo_mark(ed, .Title_Add, "add a title")
		ed.sel = insert_title(
			pr,
			v,
			rng_f64(r) * 8,
			0.5 + rng_f64(r) * 2,
			// Deliberately full of the characters the format has to escape.
			rng_int(r, 2) == 0 ? "a title" : "50% 'off': two  spaces\\and a backslash",
		)
		ed.cur_track = v
		edited(ed)
		return "title"
	}
	return ""
}

@(private = "file")
pick_clip :: proc(ed: ^Editor, r: ^Rng) -> (track, idx: int, ok: bool) {
	n := 0
	for &t in ed.pr.tracks {
		n += len(t.clips)
	}
	if n == 0 {
		return -1, -1, false
	}
	k := rng_int(r, n)
	for &t, ti in ed.pr.tracks {
		if k < len(t.clips) {
			ed.sel = t.clips[k].id
			ed.cur_track = ti
			return ti, k, true
		}
		k -= len(t.clips)
	}
	return -1, -1, false
}

// bench_editor builds an editor with a real timeline and no window. The media
// rows are fabricated rather than probed when `probe` is false, so the undo
// bench does not need ffprobe to say anything about snapshot cost.
bench_editor :: proc(probe: bool) -> ^Editor {
	ed := new(Editor)
	ed.zoom = 70
	ed.sel = -1
	ed.cur_track = 1
	ed.title_buf_for = -1
	project_init(&ed.pr)
	set_str(&ed.buf_title, "VIDEOEDIT")

	if !probe {
		for name in ([?]string{"bars.mp4", "fractal.mp4", "life.mp4", "smpte.mp4"}) {
			append(
				&ed.pr.media,
				Media {
					path = strings.clone(fmt.tprintf("%s/%s", media_dir(), name)),
					name = strings.clone(name),
					duration = 8,
					width = 1280,
					height = 720,
					fps = 30,
					has_video = true,
					has_audio = true,
					probed = true,
				},
			)
		}
		return ed
	}

	importer_start(&ed.im)
	for f in discover_media() {
		importer_push(&ed.im, f)
	}
	deadline := time.now()
	for importer_busy(&ed.im) && time.duration_seconds(time.since(deadline)) < 30 {
		time.sleep(30 * time.Millisecond)
		importer_drain(&ed.im, &ed.pending)
		for r in ed.pending {
			install_import(&ed.pr, r)
		}
		clear(&ed.pending)
	}
	importer_drain(&ed.im, &ed.pending)
	for r in ed.pending {
		install_import(&ed.pr, r)
	}
	clear(&ed.pending)
	importer_stop(&ed.im)
	return ed
}

bench_editor_destroy :: proc(ed: ^Editor) {
	history_destroy(&ed.hist)
	project_destroy(&ed.pr)
	delete(ed.pending)
	delete(ed.status)
	delete(ed.buf_title)
	delete(ed.buf_export)
	delete(ed.buf_project)
	delete(ed.buf_caption)
	free(ed)
}

// ---------------------------------------------------------------------------
// --undobench
// ---------------------------------------------------------------------------

undo_bench :: proc() {
	fmt.println("videoedit undo bench — a whole-document snapshot per edit")

	ed := bench_editor(false)
	defer bench_editor_destroy(ed)
	auto_layout(ed)
	undo_reset(ed)

	// 1. What one snapshot costs on a realistic timeline, and on a big one.
	for target in ([?]int{10, 50, 200, 800}) {
		r := rng_make(0xBEEF)
		for clips_total(&ed.pr) < target {
			_ = random_edit(ed, &r)
			undo_break(ed)
		}
		n := 40
		t0 := time.now()
		for _ in 0 ..< n {
			s := project_serialise(&ed.pr, ed.playhead, ed.zoom)
			delete(s)
		}
		ser := time.duration_milliseconds(time.since(t0)) / f64(n)
		body := project_serialise(&ed.pr, ed.playhead, ed.zoom)
		t1 := time.now()
		for _ in 0 ..< n {
			res := project_parse(&ed.pr, body, true)
			_ = res
		}
		par := time.duration_milliseconds(time.since(t1)) / f64(n)
		fmt.printf(
			"  %4d clips  %6d bytes   serialise %.3f ms   parse+restore %.3f ms\n",
			clips_total(&ed.pr),
			len(body),
			ser,
			par,
		)
		delete(body)
	}

	// 2. A long random sequence, every step checked for reversibility.
	fmt.println("\n  a random sequence, each edit undone and redone:")
	ed2 := bench_editor(false)
	defer bench_editor_destroy(ed2)
	auto_layout(ed2)
	undo_reset(ed2)
	r := rng_make(0xC0FFEE)
	edits, failures := 0, 0
	t0 := time.now()
	for _ in 0 ..< 400 {
		what := random_edit(ed2, &r)
		if what == "" {
			continue
		}
		edits += 1
		if ok, detail := undo_roundtrip_check(ed2); !ok {
			failures += 1
			if failures <= 3 {
				fmt.printf("    FAIL after %s: %s\n", what, detail)
			}
		}
	}
	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf(
		"  %d edits, %d reversibility failures, %.0f ms total (%.2f ms per edit incl. 2 restores)\n",
		edits,
		failures,
		ms,
		ms / f64(max(edits, 1)),
	)
	h := &ed2.hist
	fmt.printf(
		"  history: %d steps, %.1f KB held, %.3f ms mean snapshot over %d marks\n",
		len(h.undo),
		f64(h.bytes) / 1024,
		h.marks > 0 ? h.mark_ms / f64(h.marks) : 0,
		h.marks,
	)

	// 3. Walk the whole stack back to the start and forward again.
	first := ""
	for len(ed2.hist.undo) > 0 {
		undo_apply(ed2)
	}
	first = project_serialise(&ed2.pr, ed2.playhead, ed2.zoom, context.temp_allocator)
	depth := len(ed2.hist.redo)
	for len(ed2.hist.redo) > 0 {
		redo_apply(ed2)
	}
	for len(ed2.hist.undo) > 0 {
		undo_apply(ed2)
	}
	again := project_serialise(&ed2.pr, ed2.playhead, ed2.zoom, context.temp_allocator)
	fmt.printf(
		"  unwound %d steps to the start and back: %s\n",
		depth,
		first == again ? "byte-identical" : "DIFFERENT",
	)
	if failures > 0 || first != again {
		os.exit(1)
	}
}

clips_total :: proc(pr: ^Project) -> int {
	n := 0
	for &t in pr.tracks {
		n += len(t.clips)
	}
	return n
}

// ---------------------------------------------------------------------------
// --audiobench
// ---------------------------------------------------------------------------

audio_bench :: proc(secs: f64, silent: bool) {
	fmt.printf(
		"videoedit audio bench — %.1fs, %s\n",
		secs,
		silent ? "silent (the byte flow is identical; nothing is played)" : "AUDIBLE",
	)
	ed := bench_editor(true)
	defer bench_editor_destroy(ed)
	if len(ed.pr.media) == 0 {
		fmt.println("  no media in", media_dir(), "— nothing to measure")
		os.exit(1)
	}
	auto_layout(ed)
	undo_reset(ed)
	total := project_duration(&ed.pr)
	fmt.printf("  timeline %.2fs, %d clips, %d media\n", total, clips_total(&ed.pr), len(ed.pr.media))

	// --- 1. the resolution, shared with the export -----------------------
	srcs := resolve_audio_mix(&ed.pr, 0)
	plan := build_export(&ed.pr, {quality = .Draft, out_path = "/tmp/videoedit-audiobench.mp4"})
	fmt.printf(
		"  resolve_audio_mix(0) → %d contributions; the export plan built %d from the same list\n",
		len(srcs),
		plan.audio_srcs,
	)
	for s in srcs {
		fmt.printf(
			"    clip %-3d track %d  src %.2f→%.2f  at +%.2fs  gain %.2f  %s\n",
			s.clip,
			s.track,
			s.src_in,
			s.src_out,
			s.delay,
			s.gain,
			base_name(ed.pr.media[s.media].path),
		)
	}
	mid := total * 0.5
	midsrcs := resolve_audio_mix(&ed.pr, mid)
	fmt.printf(
		"  resolve_audio_mix(%.2f) → %d contributions, clipped to what is still ahead\n",
		mid,
		len(midsrcs),
	)

	// --- 2. does the preview mix the same sound the export writes? -------
	audio_fidelity(ed, plan)
	export_plan_destroy(&plan)

	// --- 3. the clock ----------------------------------------------------
	mixer_init(&ed.mx)
	ed.mx.silent = silent
	defer mixer_destroy(&ed.mx)
	preview_start(&ed.pv)
	defer preview_stop(&ed.pv)

	ed.playing = true
	wall0 := time.now()
	if !mixer_start(&ed.mx, &ed.pr, 0, total) {
		fmt.printf("  the pipeline would not start: %s\n", mixer_error(&ed.mx))
		os.exit(1)
	}

	tol := 1.0 / PREVIEW_FPS * 0.75
	// Drift is measured as *elapsed against elapsed* — how much timeline the
	// clock advanced versus how much wall time passed — not as an absolute
	// position, because the position carries the seek's base and a seek is not
	// drift.
	drift_max := f64(0)
	drift_last := f64(0)
	samples := 0
	clock0 := f64(-1)
	seek_done := false
	seek_at := f64(0)
	seek_resume_ms := f64(0)

	for time.duration_seconds(time.since(wall0)) < secs {
		mixer_tick(&ed.mx)
		clock := mixer_clock(&ed.mx)
		ed.playhead = clock

		// The picture, presented against the audio clock, exactly as
		// draw_preview does it.
		preview_collect(&ed.pv, ed.playhead)
		preview_follow(&ed.pr, &ed.pv, ed.playhead, false)
		if tr, ci := topmost_video_at(&ed.pr, clock); ci >= 0 {
			id := ed.pr.tracks[tr].clips[ci].id
			_, at, ok := cache_lookup(&ed.pv, id, clock, tol)
			audio_note_presentation(ed, at, clock, ok)
		}

		// Clock against wall clock. They should agree to within the sink's
		// buffering; a systematic divergence is the 5.9 % kind of bug.
		wall := time.duration_seconds(time.since(wall0))
		if wall > 1.0 {
			if clock0 < 0 {
				clock0 = clock
				wall0 = time.now()
			} else {
				d := (clock - clock0) - time.duration_seconds(time.since(wall0))
				drift_last = d
				drift_max = math.max(drift_max, abs(d))
				samples += 1
			}
		}

		// Half way through, seek. The pipeline is torn down and rebuilt, which
		// is the flush; the byte counter must restart from zero, or stale audio
		// would still be queued behind it.
		if !seek_done && wall > secs * 0.5 {
			seek_done = true
			seek_at = math.min(total - 1.0, clock + 2.0)
			b0, _ := mixer_bytes(&ed.mx)
			t0 := time.now()
			mixer_start(&ed.mx, &ed.pr, seek_at, total)
			b1, _ := mixer_bytes(&ed.mx)
			for {
				if b, _ := mixer_bytes(&ed.mx); b > 0 {
					break
				}
				if time.duration_seconds(time.since(t0)) > 2 {
					break
				}
				time.sleep(2 * time.Millisecond)
			}
			seek_resume_ms = time.duration_milliseconds(time.since(t0))
			fmt.printf(
				"\n  seek to %.2fs: the counter went %d → %d bytes (flushed: %v), sound again after %.0f ms\n",
				seek_at,
				b0,
				b1,
				b1 == 0,
				seek_resume_ms,
			)
			audio_reset_presentation(ed)
			// The drift window restarts with the pipeline.
			wall0 = time.now()
			clock0 = -1
			samples = 0
		}
		if mixer_done(&ed.mx) {
			fmt.println("\n  the pipeline reached the end of the timeline")
			break
		}
		time.sleep(16 * time.Millisecond) // one UI frame at 60 Hz
	}

	lat, locked := mixer_latency(&ed.mx)
	bytes, sum := mixer_bytes(&ed.mx)
	avg := ed.pres_n > 0 ? ed.pres_sum / f64(ed.pres_n) : 0
	drift_pct := samples > 0 && drift_last != 0 ? drift_last / math.max(1e-9, f64(samples) * 0.016) * 100 : 0
	fmt.println("\n  measured:")
	fmt.printf("    play to the first byte handed over      %.1f ms\n", mixer_startup_ms(&ed.mx))
	fmt.printf(
		"    sink buffering, counter to speaker      %.1f ms  %s\n",
		lat * 1000,
		locked ? "(locked)" : "(still converging, this is the initial estimate)",
	)
	fmt.printf(
		"    clock drift against wall clock          %+.1f ms, worst %.1f ms, over %d samples (%+.2f %%)\n",
		drift_last * 1000,
		drift_max * 1000,
		samples,
		drift_pct,
	)
	fmt.printf(
		"    presentation error, mean / worst        %.1f / %.1f ms over %d painted frames\n",
		avg * 1000,
		ed.pres_max * 1000,
		ed.pres_n,
	)
	fmt.printf("    frames the clock wanted and never got  %d\n", ed.pres_miss)
	fmt.printf(
		"    the %g fps grid's own quantisation       %.1f ms mean, %.1f ms worst — which is what the line above is\n",
		PREVIEW_FPS,
		1000.0 / PREVIEW_FPS / 4,
		1000.0 / PREVIEW_FPS / 2,
	)
	fmt.printf(
		"    PCM since the last start                %.2f s (%d bytes), mean |sample| %.0f of 32768\n",
		f64(bytes) / f64(MIX_BPS),
		bytes,
		bytes > 0 ? f64(sum) / f64(bytes / 2) : 0,
	)
	if bytes == 0 {
		fmt.println("  nothing was played at all")
		os.exit(1)
	}
}

// audio_fidelity renders the preview's mix to a raw file and the export to a
// real .mp4, decodes the export's audio back, and compares the two envelopes.
//
// This is the assertion that the shared resolution function is worth having.
// The two chains are not identical — the export resamples to 44.1 kHz and
// encodes to AAC, the preview stays at 48 kHz and goes straight out — so the
// samples cannot match bit for bit. The *envelope* can, and if a mute, a solo
// or a gain were being read differently by the two it would not.
@(private = "file")
audio_fidelity :: proc(ed: ^Editor, plan: Export_Plan) {
	if plan.err != "" {
		fmt.printf("  fidelity: the export plan did not build: %s\n", plan.err)
		return
	}
	dir := "/tmp/videoedit-audiobench"
	os.make_directory(dir)
	prev_raw := fmt.tprintf("%s/preview.raw", dir)
	exp_raw := fmt.tprintf("%s/export.raw", dir)

	// The preview's own graph, written to a file instead of the pipe.
	argv, _ := mix_argv(&ed.pr, 0, project_duration(&ed.pr), context.temp_allocator)
	a := make([dynamic]string, context.temp_allocator)
	append(&a, ..argv)
	a[len(a) - 1] = prev_raw
	append(&a, "-y")
	if _, ok := run_capture_bytes(a[:], context.temp_allocator); !ok {
		fmt.println("  fidelity: the preview mix would not render")
		return
	}

	// The real export, then its audio decoded back at the preview's rate.
	if st, _, serr, perr := os.process_exec({command = plan.argv}, context.temp_allocator);
	   perr != nil || st.exit_code != 0 {
		fmt.printf("  fidelity: the export failed: %s\n", strings.trim_space(string(serr)))
		return
	}
	out := plan.argv[len(plan.argv) - 1]
	if _, ok := run_capture_bytes(
		{
			"ffmpeg", "-y", "-v", "error", "-i", out,
			"-vn", "-f", "s16le", "-acodec", "pcm_s16le",
			"-ar", fmt.tprintf("%d", MIX_RATE), "-ac", fmt.tprintf("%d", MIX_CH), exp_raw,
		},
		context.temp_allocator,
	); !ok {
		fmt.println("  fidelity: the export's audio would not decode")
		return
	}

	pa, e1 := os.read_entire_file_from_path(prev_raw, context.temp_allocator)
	pb, e2 := os.read_entire_file_from_path(exp_raw, context.temp_allocator)
	if e1 != nil || e2 != nil {
		fmt.println("  fidelity: could not read the rendered PCM back")
		return
	}
	n := min(len(pa), len(pb)) / 2
	win := MIX_RATE * MIX_CH / 10 // 100 ms
	worst := f64(0)
	sum := f64(0)
	wins := 0
	for w := 0; w + win <= n; w += win {
		ra, rb := f64(0), f64(0)
		for i in w ..< w + win {
			va := f64(i16(u16(pa[i * 2]) | (u16(pa[i * 2 + 1]) << 8)))
			vb := f64(i16(u16(pb[i * 2]) | (u16(pb[i * 2 + 1]) << 8)))
			ra += va * va
			rb += vb * vb
		}
		ra = math.sqrt(ra / f64(win)) / 32768
		rb = math.sqrt(rb / f64(win)) / 32768
		d := abs(ra - rb)
		sum += d
		worst = math.max(worst, d)
		wins += 1
	}
	fmt.printf(
		"  fidelity: preview %.2fs vs export %.2fs; RMS envelope over %d 100 ms windows, mean |diff| %.4f, worst %.4f of full scale\n",
		f64(len(pa)) / f64(MIX_BPS),
		f64(len(pb)) / f64(MIX_BPS),
		wins,
		wins > 0 ? sum / f64(wins) : 0,
		worst,
	)
	for t in plan.temps {
		os.remove(t)
	}
	os.remove(plan.progress)
	os.remove(prev_raw)
	os.remove(exp_raw)
	os.remove(out)
}
