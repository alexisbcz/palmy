package main

// `videoedit --shot out.png` renders the whole interface through palmy's
// offscreen renderer and writes a PNG.
//
// This exists because verifying an editor means *looking* at it, and on a
// shared desktop the window manager decides where a window goes and what sits
// on top of it. Offscreen, the frame is exactly 1500x900 every time, so a
// change to the timeline's drawing can be compared against the previous run
// rather than against whatever else happened to be on screen.
//
// It drives the real thing: the same Editor, the same worker threads, the same
// draw_ui. Only the surface is different.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1500
SHOT_H :: 900

// Geist, where the fonts package installs it, else where kit loads it from
// in a checkout.
font_dir :: proc() -> string {
	return os.is_dir(SYSTEM_GEIST) ? SYSTEM_GEIST : kit.FONT_DIR
}
MONO_CANDIDATES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

// load_shot_fonts mirrors what kit.start does to a window's font set. kit only
// offers it attached to a real window, so an offscreen render has to repeat it.
load_shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", font_dir(), pair.file), .Sans, pair.wt)
	}
	for path in MONO_CANDIDATES {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

// bench reports the latency a scrub actually has: the plan is submitted, one
// ffmpeg starts, and the first frame for the new position has to arrive. The
// steady-state number — frames already in the cache — is a lookup and costs
// nothing, which is the whole point of the design.
bench :: proc(ed: ^Editor, off: ^p.Offscreen) {
	points := [?]f64{0.5, 6.4, 2.1, 9.7, 4.3, 11.2, 7.8, 1.3}
	if os.get_env("VE_BENCH", context.temp_allocator) == "fine" {
		ed.pv.quality = .Fine
	}
	total := f64(0)
	worst := f64(0)
	hits := 0
	tol := 1.0 / PREVIEW_FPS * 0.75

	for at in points {
		if _, ci := topmost_video_at(&ed.pr, at); ci < 0 {
			fmt.printf("bench: scrub to %5.2fs — a gap in the timeline, nothing to decode\n", at)
			continue
		}
		cache_drop_all(&ed.pv) // a cold scrub: nothing useful is held
		ed.playhead = at
		t0 := time.now()
		got := false
		for _ in 0 ..< 400 {
			preview_collect(&ed.pv, ed.playhead)
			preview_follow(&ed.pr, &ed.pv, ed.playhead, false)
			_, ci := topmost_video_at(&ed.pr, at)
			if ci >= 0 {
				tr, _ := topmost_video_at(&ed.pr, at)
				id := ed.pr.tracks[tr].clips[ci].id
				if _, _, ok := cache_lookup(&ed.pv, id, at, tol); ok {
					got = true
					break
				}
			}
			time.sleep(2 * time.Millisecond)
		}
		ms := time.duration_milliseconds(time.since(t0))
		if got {
			hits += 1
			total += ms
			worst = math.max(worst, ms)
		}
		fmt.printf("bench: scrub to %5.2fs — first frame in %6.1f ms%s\n", at, ms, got ? "" : " (never arrived)")
	}
	if hits > 0 {
		fmt.printf(
			"bench: %d cold scrubs served, mean %.1f ms, worst %.1f ms, preview %dpx at %g fps\n",
			hits,
			total / f64(hits),
			worst,
			preview_width(ed.pv.quality),
			PREVIEW_FPS,
		)
	}

	// Steady state: walk the playhead across a decoded window and count how
	// many frames come straight out of the cache.
	cache_drop_all(&ed.pv)
	ed.playhead = 0.5
	for _ in 0 ..< 200 {
		preview_collect(&ed.pv, ed.playhead)
		preview_follow(&ed.pr, &ed.pv, ed.playhead, false)
		if cache_count(&ed.pv) > 30 {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	ed.pv.hits, ed.pv.misses = 0, 0
	t1 := time.now()
	n := 0
	for i in 0 ..< 60 {
		ed.playhead = 0.5 + f64(i) / 60.0 * 2.0
		preview_collect(&ed.pv, ed.playhead)
		ui := p.offscreen_begin(off)
		draw_ui(ed, ui)
		p.offscreen_end(off)
		n += 1
	}
	ms := time.duration_milliseconds(time.since(t1))
	fmt.printf(
		"bench: %d full UI frames over a decoded window in %.0f ms (%.1f fps), cache %d hits / %d misses\n",
		n,
		ms,
		f64(n) / (ms / 1000),
		ed.pv.hits,
		ed.pv.misses,
	)

	// Stepping *backwards*, which used to leave the decoded window after nine
	// frames and pay for a fresh ffmpeg seek per step. The plan now starts
	// PREVIEW_BACK behind the playhead, so this should be cache hits.
	// Start cold, or the earlier phases of this bench have already filled the
	// cache with the frames the backward steps would be asking for and the
	// measurement means nothing.
	cache_drop_all(&ed.pv)
	ed.playhead = 2.6
	for _ in 0 ..< 200 {
		preview_collect(&ed.pv, ed.playhead)
		preview_follow(&ed.pr, &ed.pv, ed.playhead, false)
		if cache_count(&ed.pv) > 40 {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	ed.pv.hits, ed.pv.misses = 0, 0
	back_steps := 0
	t2 := time.now()
	for i in 0 ..< 30 {
		ed.playhead = 2.6 - f64(i) / PREVIEW_FPS
		if ed.playhead < 0 {
			break
		}
		preview_collect(&ed.pv, ed.playhead)
		preview_follow(&ed.pr, &ed.pv, ed.playhead, false)
		if tr, ci := topmost_video_at(&ed.pr, ed.playhead); ci >= 0 {
			id := ed.pr.tracks[tr].clips[ci].id
			if _, _, ok := cache_lookup(&ed.pv, id, ed.playhead, 1.0 / PREVIEW_FPS * 0.75); ok {
				back_steps += 1
			}
		}
	}
	bms := time.duration_milliseconds(time.since(t2))
	fmt.printf(
		"bench: 30 backward frame steps — %d served from the cache, %.2f ms each, %d misses\n",
		back_steps,
		bms / 30,
		ed.pv.misses,
	)
}

shot :: proc(out_path: string, at: f64) {
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)

	// VE_SIZE=WxH renders at another window size, which is how the layout is
	// checked against the sizes a tiling compositor actually hands out.
	w, h := SHOT_W, SHOT_H
	if spec := os.get_env("VE_SIZE", context.temp_allocator); spec != "" {
		if x := strings.index_byte(spec, 'x'); x > 0 {
			if a, ok := strconv.parse_int(spec[:x], 10); ok {
				w = a
			}
			if b, ok := strconv.parse_int(spec[x + 1:], 10); ok {
				h = b
			}
		}
	}
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_shot_fonts(&off.fonts)

	ed := new(Editor)
	defer free(ed)
	ed.fonts = &off.fonts
	ed.zoom = 70
	ed.sel = -1
	ed.cur_track = 1
	project_init(&ed.pr)
	// default_export and default_project are under the home directory of
	// whoever runs this, and the export and project fields render them in
	// full. A frame that goes into the documentation must not carry that
	// name, so a screenshot run can point them somewhere innocuous. Unset,
	// which is the normal case, nothing changes.
	set_str(&ed.buf_export, shot_path_env("PALMY_VIDEOEDIT_EXPORT", default_export()))
	set_str(&ed.buf_project, shot_path_env("PALMY_VIDEOEDIT_PROJECT", default_project()))
	set_str(&ed.buf_caption, shot_path_env("PALMY_VIDEOEDIT_CAPTION", default_caption_path()))
	set_str(&ed.buf_title, "VIDEOEDIT")

	importer_start(&ed.im)
	preview_start(&ed.pv)
	exporter_start(&ed.ex)
	mixer_init(&ed.mx)
	defer {
		importer_stop(&ed.im)
		preview_stop(&ed.pv)
		exporter_stop(&ed.ex)
		project_destroy(&ed.pr)
	}

	for f in discover_media() {
		importer_push(&ed.im, f)
	}

	// Wait for the probes, then build a timeline worth looking at.
	deadline := time.now()
	for importer_busy(&ed.im) && time.duration_seconds(time.since(deadline)) < 20 {
		time.sleep(50 * time.Millisecond)
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

	auto_layout(ed)
	// A dissolve on the second clip, a title, and the sample captions, so the
	// screenshot shows the features rather than an empty grid.
	v := track_of_kind(&ed.pr, .Video, 1)
	if len(ed.pr.tracks[v].clips) >= 2 {
		toggle_dissolve(ed, v, 1)
	}
	insert_title(&ed.pr, track_of_kind(&ed.pr, .Video, 0), 0.5, 2.5, "VIDEOEDIT")
	if n, _, ok := load_captions(&ed.pr, buf_str(&ed.buf_caption)); ok {
		fmt.printf("shot: %d caption cues loaded\n", n)
	}
	ed.playhead = at
	ed.sel = len(ed.pr.tracks[v].clips) > 1 ? ed.pr.tracks[v].clips[1].id : -1
	ed.cur_track = v
	if os.get_env("VE_SEL_TITLE", context.temp_allocator) != "" {
		tv := track_of_kind(&ed.pr, .Video, 0)
		if len(ed.pr.tracks[tv].clips) > 0 {
			ed.sel = ed.pr.tracks[tv].clips[0].id
			ed.cur_track = tv
		}
	}
	ed.last_edit += 1

	// Run frames until the preview cache has something at the playhead.
	for i in 0 ..< 240 {
		preview_collect(&ed.pv, ed.playhead)
		force := ed.last_edit != ed.edit_seen
		if force {
			cache_drop_all(&ed.pv)
			ed.edit_seen = ed.last_edit
		}
		preview_follow(&ed.pr, &ed.pv, ed.playhead, force)

		ui := p.offscreen_begin(off)
		// `ed.tl` normally comes from the previous frame's layout; offscreen
		// it is the same thing, just read a frame later.
		draw_ui(ed, ui)
		p.offscreen_end(off)

		if i > 30 && cache_count(&ed.pv) > 0 {
			// One more frame so the newly cached picture is the one painted.
			preview_collect(&ed.pv, ed.playhead)
			ui2 := p.offscreen_begin(off)
			draw_ui(ed, ui2)
			p.offscreen_end(off)
			break
		}
		time.sleep(16 * time.Millisecond)
	}

	DEBUG_RECTS = os.get_env("VE_DEBUG", context.temp_allocator) != ""
	ui3 := p.offscreen_begin(off)
	draw_ui(ed, ui3)
	p.offscreen_end(off)
	DEBUG_RECTS = false

	ok := p.offscreen_write_png(off, out_path)
	decoded, ms, _ := preview_stats(&ed.pv)
	fmt.printf(
		"shot: %s (%v) — %d media, %d cached frames, %d decoded in %.0f ms\n",
		out_path,
		ok,
		len(ed.pr.media),
		cache_count(&ed.pv),
		decoded,
		ms,
	)
	if !ok {
		os.exit(1)
	}

	// VE_BENCH measures what scrubbing actually costs: jump the playhead, then
	// time how long until a decoded frame for that instant is in the cache.
	if os.get_env("VE_BENCH", context.temp_allocator) != "" {
		bench(ed, off)
	}

	// VE_EXPORT runs a real export through the Exporter thread — the same path
	// the `p` key takes — so the threaded progress polling is exercised
	// without a compositor.
	out := os.get_env("VE_EXPORT", context.temp_allocator)
	if out == "" {
		return
	}
	plan := build_export(&ed.pr, {quality = .Draft, out_path = out})
	if plan.err != "" {
		fmt.printf("export: %s\n", plan.err)
		export_plan_destroy(&plan)
		os.exit(1)
	}
	fmt.printf("export: %d video segments, %d audio segments, %.2fs, %dx%d\n",
		plan.video_srcs, plan.audio_srcs, plan.duration, plan.width, plan.height)
	exporter_submit(&ed.ex, plan, out)
	last := f32(-1)
	for {
		st := exporter_status(&ed.ex)
		if st.state == .Done || st.state == .Failed {
			fmt.printf("export: %v — %s\n", st.state, st.message)
			break
		}
		if st.progress - last >= 0.1 {
			last = st.progress
			fmt.printf("export: %3.0f%%  %s\n", st.progress * 100, st.message)
		}
		time.sleep(60 * time.Millisecond)
	}
	vf := verify_output(out, context.temp_allocator)
	fmt.printf("ffprobe: ok=%v %.3fs %dx%d streams=%d %s/%s\n",
		vf.ok, vf.duration, vf.width, vf.height, vf.streams, vf.vcodec, vf.acodec)
	if !vf.ok {
		os.exit(1)
	}
	_ = strings.has_prefix
}

// shot_path_env reads an override for a path that is otherwise baked into the
// binary, falling back to the built-in default.
shot_path_env :: proc(name, fallback: string) -> string {
	if v := os.get_env(name, context.temp_allocator); v != "" {
		return v
	}
	return fallback
}
