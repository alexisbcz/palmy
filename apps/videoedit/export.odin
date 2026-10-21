package main

// Export: turning the timeline into one ffmpeg invocation.
//
// The graph
// ---------
// Video starts from a black `color` source the length of the timeline, and
// every video clip is `trim`med out of its source, scaled and padded into the
// output frame, shifted to its timeline position with `setpts=PTS+START/TB`
// and `overlay`ed onto whatever is below it. Tracks are walked bottom to top,
// so the last overlay is the topmost track — the same order the preview draws
// in. An `enable='between(t,A,B)'` on each overlay is what keeps a clip from
// smearing its last frame over the rest of the timeline.
//
// A cross-dissolve is not a separate filter: the incoming clip is overlapped
// with the outgoing one on the timeline and its alpha is ramped up with
// `fade=t=in:alpha=1`. Because overlay already composites it over the clip
// below, that *is* a dissolve, and it needs no `xfade` (which would force the
// whole timeline through a concat).
//
// Titles become `drawtext`, captions become `subtitles` reading a copy of the
// cue list with the user's nudge baked in (or a subtitle track, when this
// ffmpeg has no libass — see "What this ffmpeg can do"), and audio is
// `atrim` + `adelay` + `amix`. This whole file produces an argv; `exporter_run` is the only part
// that starts a process.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import kit "kit:."
import p "palmy:."

// The title card's font, for ffmpeg's drawtext: Geist SemiBold where the
// fonts package installs it, else in the checkout kit loads it from.
SYSTEM_GEIST :: "/usr/share/fonts/geist"

title_font :: proc() -> string {
	sys := SYSTEM_GEIST + "/Geist-600.ttf"
	return os.exists(sys) ? sys : fmt.tprintf("%s/Geist-600.ttf", kit.FONT_DIR)
}

Export_Quality :: enum u8 {
	Draft,
	Final,
}

Export_Settings :: struct {
	quality:  Export_Quality,
	out_path: string,
}

export_dims :: proc(pr: ^Project, q: Export_Quality) -> (w, h: int) {
	if q == .Final {
		return pr.out_w, pr.out_h
	}
	// A draft is half-height, rounded to even so yuv420p is happy.
	w = pr.out_w / 2
	h = pr.out_h / 2
	w -= w % 2
	h -= h % 2
	return max(w, 2), max(h, 2)
}

// ---------------------------------------------------------------------------
// Escaping, and how it is avoided
//
// A filtergraph is unescaped twice — once splitting the graph on `, ; [ ]`,
// once splitting a filter's options on `:` and `=` — and a `drawtext` value is
// then run through its own expansion pass for `%` and `{}`. Getting a user's
// title through all three correctly is a losing game: a title of
// `50% 'off': now, really` is enough to break a hand-rolled escaper, and when
// it breaks, ffmpeg does not write a file at all.
//
// So user text never goes into the graph. Each title is written to a temporary
// file and read back with `textfile=`, with `expansion=none` to switch off the
// `%` pass, and the captions were already a file. What is left in the graph is
// paths this program generated itself, which contain nothing but
// `[A-Za-z0-9/._-]`; `quote_path` wraps those in single quotes and handles an
// embedded quote the way ffmpeg documents, so a surprising TMPDIR cannot break
// the graph either.
// ---------------------------------------------------------------------------

quote_path :: proc(s: string, alloc := context.temp_allocator) -> string {
	sb := strings.builder_make(alloc)
	strings.write_byte(&sb, '\'')
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			// Close the quote, emit an escaped quote, reopen: ffmpeg's own
			// documented form, the same trick a shell uses.
			strings.write_string(&sb, "'\\''")
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	strings.write_byte(&sb, '\'')
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Building the command
// ---------------------------------------------------------------------------

Export_Plan :: struct {
	argv:       []string,
	progress:   string, // path ffmpeg writes progress to
	sub_path:   string, // temp SRT written for burn-in, "" if none
	temps:      []string, // every temporary file the run should delete
	duration:   f64,
	width:      int,
	height:     int,
	video_srcs: int,
	audio_srcs: int,
	captions:   Caption_Mode,
	titles_out: int, // titles left out because this ffmpeg cannot draw text
	notes:      string, // what was degraded and why, "" if nothing; owned
	err:        string,
}

// Caption_Mode is what happened to the caption track in an export.
Caption_Mode :: enum u8 {
	None, // there were no captions
	Burned, // drawn into the picture by `subtitles` (libass)
	Track, // written as a subtitle stream the player can switch on
	Left_Out, // neither was possible; the notes say why
}

caption_mode_name :: proc(m: Caption_Mode) -> string {
	switch m {
	case .None:
		return "none"
	case .Burned:
		return "burned"
	case .Track:
		return "track"
	case .Left_Out:
		return "left out"
	}
	return "none"
}

// ---------------------------------------------------------------------------
// What this ffmpeg can do
//
// The export leans on two filters that are not ffmpeg's own code: `subtitles`
// needs libass and `drawtext` needs libfreetype. Arch's ffmpeg and Ubuntu's
// have both. palmy's own does not — distro/recipes/runtime/src/ffmpeg.build
// builds with `--disable-autodetect` and links glibc, zlib, libopus and
// libx264 and nothing else — and without them the graph does not half-work,
// it fails to parse, and the export writes nothing at all.
//
// So the export asks once (`ffmpeg -filters`, `ffmpeg -encoders`) and degrades
// honestly instead of failing:
//   - no `subtitles`: the captions go into the file as a subtitle *stream*
//     (mov_text in .mp4/.mov, srt in .mkv, webvtt in .webm — encoders ffmpeg
//     always has), which every player can show, and the notes say they were
//     not burned in. If even that is impossible, they are left out and the
//     notes say so.
//   - no `drawtext`: titles are left out of the file, and the notes say how
//     many. They are still in the project and the preview.
// The notes reach the window's status line and `videoedit export --json`.
// ---------------------------------------------------------------------------

Ffmpeg_Caps :: struct {
	probed:    bool,
	subtitles: bool, // the libass filter
	drawtext:  bool, // the freetype filter
	mov_text:  bool, // subtitle encoders, for a soft track
	srt:       bool,
	webvtt:    bool,
}

@(private = "file")
g_caps: Ffmpeg_Caps
@(private = "file")
g_caps_mu: sync.Mutex

// caps_force replaces what the probe found, for the self-test; nil restores it.
caps_force: Maybe(Ffmpeg_Caps)

ffmpeg_caps :: proc() -> Ffmpeg_Caps {
	if f, ok := caps_force.?; ok {
		return f
	}
	sync.lock(&g_caps_mu)
	defer sync.unlock(&g_caps_mu)
	if !g_caps.probed {
		g_caps = probe_ffmpeg_caps()
	}
	return g_caps
}

// probe_ffmpeg_caps asks the ffmpeg on PATH. A line of `-filters` is
// `<flags> <name> <in->out> <description>` and a line of `-encoders` is
// `<flags> <name> <description>`, so the name is the second field of either.
probe_ffmpeg_caps :: proc() -> Ffmpeg_Caps {
	c := Ffmpeg_Caps{probed = true}
	if out, ok := run_capture({"ffmpeg", "-hide_banner", "-filters"}, context.temp_allocator); ok {
		body := out
		for line in strings.split_lines_iterator(&body) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) < 2 {
				continue
			}
			switch f[1] {
			case "subtitles":
				c.subtitles = true
			case "drawtext":
				c.drawtext = true
			}
		}
	}
	if out, ok := run_capture({"ffmpeg", "-hide_banner", "-encoders"}, context.temp_allocator); ok {
		body := out
		for line in strings.split_lines_iterator(&body) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) < 2 {
				continue
			}
			switch f[1] {
			case "mov_text":
				c.mov_text = true
			case "srt":
				c.srt = true
			case "webvtt":
				c.webvtt = true
			}
		}
	}
	return c
}

// soft_sub_codec is the subtitle encoder the output's container takes, or ""
// if this container has none this ffmpeg can write.
soft_sub_codec :: proc(out_path: string, caps: Ffmpeg_Caps) -> string {
	lower := strings.to_lower(out_path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".mp4") || strings.has_suffix(lower, ".mov") || strings.has_suffix(lower, ".m4v"):
		return caps.mov_text ? "mov_text" : ""
	case strings.has_suffix(lower, ".mkv"):
		return caps.srt ? "srt" : ""
	case strings.has_suffix(lower, ".webm"):
		return caps.webvtt ? "webvtt" : ""
	}
	return ""
}

// build_export assembles the whole invocation. It allocates into the given
// allocator and never starts anything.
build_export :: proc(
	pr: ^Project,
	set: Export_Settings,
	alloc := context.allocator,
) -> Export_Plan {
	context.allocator = alloc
	plan := Export_Plan{}
	total := project_duration(pr)
	if total <= 0.02 {
		plan.err = strings.clone("the timeline is empty")
		return plan
	}
	ow, oh := export_dims(pr, set.quality)
	fps := pr.out_fps > 0 ? pr.out_fps : 30
	plan.duration = total
	plan.width, plan.height = ow, oh

	// Refuse to write over a source. The user picks the path, so this is the
	// one check that has to be here rather than in the file dialog.
	for m in pr.media {
		if same_path(m.path, set.out_path) {
			plan.err = fmt.aprintf("refusing to overwrite the source media %s", m.name)
			return plan
		}
	}

	// One -i per distinct media path, in first-use order.
	inputs := make([dynamic]string, context.temp_allocator)
	input_of :: proc(inputs: ^[dynamic]string, path: string) -> int {
		for s, i in inputs {
			if s == path {
				return i
			}
		}
		append(inputs, path)
		return len(inputs) - 1
	}

	temps := make([dynamic]string)
	g := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&g, "color=c=black:s=%dx%d:r=%g:d=%.4f[vbase];", ow, oh, fps, total)

	// --- video ---------------------------------------------------------
	cur := "vbase"
	n := 0
	titles := make([dynamic]Clip, context.temp_allocator)

	// Bottom track first: the last overlay ends up on top.
	#reverse for &t, ti in pr.tracks {
		if t.kind != .Video || !track_enabled(pr, ti) {
			continue
		}
		for c in t.clips {
			if c.media < 0 {
				append(&titles, c)
				continue
			}
			if c.media >= len(pr.media) || !pr.media[c.media].has_video {
				continue
			}
			if clip_len(c) <= 1.0 / fps {
				continue
			}
			ii := input_of(&inputs, pr.media[c.media].path)
			start := c.start
			end := clip_end(c)
			fmt.sbprintf(
				&g,
				"[%d:v]trim=start=%.4f:end=%.4f,setpts=PTS-STARTPTS," +
				"scale=%d:%d:force_original_aspect_ratio=decrease," +
				"pad=%d:%d:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=%g",
				ii,
				c.src_in,
				c.src_out,
				ow,
				oh,
				ow,
				oh,
				fps,
			)
			if c.trans == .Dissolve && c.xfade > 0.01 {
				// Ramp alpha in over the overlap with the clip underneath.
				fmt.sbprintf(&g, ",format=yuva420p,fade=t=in:st=0:d=%.4f:alpha=1", c.xfade)
			}
			fmt.sbprintf(&g, "[c%d];", n)
			fmt.sbprintf(&g, "[c%d]setpts=PTS+%.4f/TB[s%d];", n, start, n)
			fmt.sbprintf(
				&g,
				"[%s][s%d]overlay=eof_action=pass:enable='between(t\\,%.4f\\,%.4f)'[o%d];",
				cur,
				n,
				start,
				end,
				n,
			)
			cur = fmt.tprintf("o%d", n)
			n += 1
			plan.video_srcs += 1
		}
	}

	// --- captions: burned in when this ffmpeg can, a track when not -----
	caps := ffmpeg_caps()
	notes := make([dynamic]string, context.temp_allocator)
	sub_codec := ""
	if len(pr.captions) > 0 {
		sub := fmt.aprintf("%s/videoedit-burn-%d.srt", tmp_dir(), os.get_pid())
		if write_shifted_srt(pr, sub) {
			plan.sub_path = sub
			append(&temps, strings.clone(sub))
			if caps.subtitles {
				fmt.sbprintf(
					&g,
					"[%s]subtitles=filename=%s:force_style='FontSize=%d'[vsub];",
					cur,
					quote_path(sub),
					set.quality == .Draft ? 14 : 22,
				)
				cur = "vsub"
				plan.captions = .Burned
			} else if sub_codec = soft_sub_codec(set.out_path, caps); sub_codec != "" {
				plan.captions = .Track
				append(&notes, fmt.tprintf("captions written as a %s subtitle track, not burned in: this ffmpeg has no libass (no subtitles filter)", sub_codec))
			} else {
				plan.captions = .Left_Out
				append(&notes, "captions left out: this ffmpeg has no libass to burn them in, and no subtitle encoder for this container")
			}
		}
	}

	// --- titles, as drawtext on top -----------------------------------
	for c, i in titles {
		if c.title == "" {
			continue
		}
		if !caps.drawtext {
			plan.titles_out += 1
			continue
		}
		size := int(f64(c.font_size) * f64(oh) / f64(math.max(1, pr.out_h)))
		// The title's text goes through a file, never through the graph.
		tf := fmt.aprintf("%s/videoedit-title-%d-%d.txt", tmp_dir(), os.get_pid(), i)
		if os.write_entire_file(tf, transmute([]u8)c.title) != nil {
			delete(tf)
			continue
		}
		append(&temps, tf)
		fmt.sbprintf(
			&g,
			"[%s]drawtext=fontfile=%s:textfile=%s:expansion=none:fontsize=%d:fontcolor=0x%06x:" +
			"x='max(12\\,min(w-text_w-12\\,w*%.4f-text_w/2))':" +
			"y='max(12\\,min(h-text_h-12\\,h*%.4f-text_h/2))':" +
			"box=1:boxcolor=black@0.45:boxborderw=10:" +
			"enable='between(t\\,%.4f\\,%.4f)'[t%d];",
			cur,
			quote_path(title_font()),
			quote_path(tf),
			max(8, size),
			c.color & 0xffffff,
			c.pos_x,
			c.pos_y,
			c.start,
			clip_end(c),
			i,
		)
		cur = fmt.tprintf("t%d", i)
	}
	if plan.titles_out > 0 {
		append(&notes, fmt.tprintf("%d title(s) left out: this ffmpeg has no drawtext (built without freetype)", plan.titles_out))
	}
	fmt.sbprintf(&g, "[%s]format=yuv420p[vout];", cur)

	// --- audio ---------------------------------------------------------
	// Which clips are audible, and at what gain, is not decided here: it is
	// decided by `resolve_audio_mix`, which the preview's mixer calls with the
	// same project. That is the only way the speakers and the file can be made
	// to agree about a muted track or a clip at 40 %. From `from = 0` the list
	// is the whole timeline, and each contribution's delay is its clip start.
	// See audio.odin.
	alabels := make([dynamic]string, context.temp_allocator)
	for ms in resolve_audio_mix(pr, 0, context.temp_allocator) {
		ii := input_of(&inputs, pr.media[ms.media].path)
		label := fmt.tprintf("a%d", len(alabels))
		mix_chain(&g, ms, ii, 44100, label)
		append(&alabels, label)
	}
	switch len(alabels) {
	case 0:
		fmt.sbprintf(&g, "anullsrc=channel_layout=stereo:sample_rate=44100[aout];")
	case 1:
		fmt.sbprintf(&g, "[%s]anull[aout];", alabels[0])
	case:
		for l in alabels {
			fmt.sbprintf(&g, "[%s]", l)
		}
		fmt.sbprintf(&g, "amix=inputs=%d:normalize=0:dropout_transition=0[aout];", len(alabels))
	}
	plan.audio_srcs = len(alabels)

	graph := strings.trim_suffix(strings.to_string(g), ";")

	// --- argv ------------------------------------------------------------
	plan.progress = fmt.aprintf("%s/videoedit-progress-%d.txt", tmp_dir(), os.get_pid())
	os.remove(plan.progress)
	plan.temps = temps[:]

	// Every element is cloned, so `export_plan_destroy` can free the lot
	// without having to know which ones were literals.
	argv := make([dynamic]string)
	arg :: proc(argv: ^[dynamic]string, items: ..string) {
		for s in items {
			append(argv, strings.clone(s))
		}
	}
	arg(&argv, "ffmpeg", "-y", "-v", "error", "-nostdin", "-nostats")
	arg(&argv, "-progress", plan.progress)
	for in_path in inputs {
		arg(&argv, "-i", in_path)
	}
	if plan.captions == .Track {
		// The SRT is one more input, after every media file, so its index is
		// the count of those.
		arg(&argv, "-i", plan.sub_path)
	}
	arg(&argv, "-filter_complex", graph)
	arg(&argv, "-map", "[vout]", "-map", "[aout]")
	if plan.captions == .Track {
		arg(&argv, "-map", fmt.tprintf("%d:s", len(inputs)), "-c:s", sub_codec)
		arg(&argv, "-metadata:s:s:0", "language=und")
	}
	arg(&argv, "-c:v", "libx264", "-pix_fmt", "yuv420p")
	if set.quality == .Draft {
		arg(&argv, "-preset", "ultrafast", "-crf", "30", "-b:a", "96k")
	} else {
		arg(&argv, "-preset", "medium", "-crf", "18", "-b:a", "192k")
	}
	arg(&argv, "-c:a", "aac", "-ar", "44100", "-ac", "2")
	arg(&argv, "-r", fmt.tprintf("%g", fps))
	arg(&argv, "-t", fmt.tprintf("%.4f", total))
	arg(&argv, "-movflags", "+faststart")
	arg(&argv, set.out_path)
	plan.argv = argv[:]
	plan.notes = strings.join(notes[:], "; ")
	return plan
}

// tmp_dir is $TMPDIR or /tmp, as a plain string — os.temp_dir returns an
// error too, and every caller here wants a path or the default.
tmp_dir :: proc() -> string {
	d, err := os.temp_dir(context.temp_allocator)
	if err != nil || d == "" {
		return "/tmp"
	}
	return strings.trim_suffix(d, "/")
}

same_path :: proc(a, b: string) -> bool {
	if a == b {
		return true
	}
	ra, ea := os.get_absolute_path(a, context.temp_allocator)
	rb, eb := os.get_absolute_path(b, context.temp_allocator)
	if ea != nil || eb != nil {
		return false
	}
	return ra == rb
}

// ---------------------------------------------------------------------------
// Running it
//
// Locking (one mutex, `Exporter.mu`): the UI thread writes `req` and reads
// `progress`/`state`/`message`; the worker reads `req` once and then only
// writes progress fields. ffmpeg's own progress file is polled by the worker
// between its timed waits, so the UI thread never does file I/O for it.
// ---------------------------------------------------------------------------

Export_State :: enum u8 {
	Idle,
	Running,
	Done,
	Failed,
}

Exporter :: struct {
	mu:       sync.Mutex,
	sem:      sync.Sema,
	quit:     bool,
	worker:   ^thread.Thread,

	// Request, written by the UI before posting the semaphore.
	req:      Export_Plan,
	has_req:  bool,

	// Progress, written by the worker.
	state:    Export_State,
	progress: f32,
	message:  string, // owned by the exporter
	out_path: string, // owned by the exporter
	elapsed:  f64,
}

exporter_start :: proc(ex: ^Exporter) {
	ex.worker = thread.create(exporter_main)
	ex.worker.data = rawptr(ex)
	thread.start(ex.worker)
}

exporter_stop :: proc(ex: ^Exporter) {
	sync.lock(&ex.mu)
	ex.quit = true
	sync.unlock(&ex.mu)
	sync.sema_post(&ex.sem)
	if ex.worker != nil {
		thread.join(ex.worker)
		thread.destroy(ex.worker)
		ex.worker = nil
	}
	delete(ex.message)
	delete(ex.out_path)
}

// exporter_submit hands over a built plan. The exporter owns it from here.
exporter_submit :: proc(ex: ^Exporter, plan: Export_Plan, out_path: string) -> bool {
	sync.lock(&ex.mu)
	if ex.state == .Running || ex.has_req {
		sync.unlock(&ex.mu)
		return false
	}
	ex.req = plan
	ex.has_req = true
	ex.state = .Running
	ex.progress = 0
	delete(ex.message)
	ex.message = strings.clone("starting ffmpeg")
	delete(ex.out_path)
	ex.out_path = strings.clone(out_path)
	sync.unlock(&ex.mu)
	sync.sema_post(&ex.sem)
	return true
}

Export_Status :: struct {
	state:    Export_State,
	progress: f32,
	message:  string, // valid until the next call; cloned into temp
	out_path: string,
	elapsed:  f64,
}

exporter_status :: proc(ex: ^Exporter) -> Export_Status {
	sync.lock(&ex.mu)
	defer sync.unlock(&ex.mu)
	return Export_Status {
		state = ex.state,
		progress = ex.progress,
		message = strings.clone(ex.message, context.temp_allocator),
		out_path = strings.clone(ex.out_path, context.temp_allocator),
		elapsed = ex.elapsed,
	}
}

exporter_clear :: proc(ex: ^Exporter) {
	sync.lock(&ex.mu)
	if ex.state == .Done || ex.state == .Failed {
		ex.state = .Idle
	}
	sync.unlock(&ex.mu)
}

@(private)
exporter_set :: proc(ex: ^Exporter, st: Export_State, prog: f32, msg: string, elapsed: f64) {
	cloned := strings.clone(msg)
	sync.lock(&ex.mu)
	ex.state = st
	ex.progress = prog
	old := ex.message
	ex.message = cloned
	ex.elapsed = elapsed
	sync.unlock(&ex.mu)
	delete(old)
}

@(private)
exporter_main :: proc(th: ^thread.Thread) {
	ex := (^Exporter)(th.data)
	for {
		free_all(context.temp_allocator)
		sync.lock(&ex.mu)
		if ex.quit {
			sync.unlock(&ex.mu)
			return
		}
		if !ex.has_req {
			sync.unlock(&ex.mu)
			sync.sema_wait(&ex.sem)
			continue
		}
		plan := ex.req
		ex.req = {}
		ex.has_req = false
		sync.unlock(&ex.mu)

		run_export(ex, plan)
		export_plan_destroy(&plan)
	}
}

export_plan_destroy :: proc(plan: ^Export_Plan) {
	for s in plan.argv {
		delete(s)
	}
	delete(plan.argv)
	delete(plan.progress)
	delete(plan.sub_path)
	for t in plan.temps {
		delete(t)
	}
	delete(plan.temps)
	delete(plan.err)
	delete(plan.notes)
	plan^ = {}
}

// run_export starts ffmpeg, then alternates a short timed wait with a read of
// the progress file. Nothing here blocks the UI: this is the worker thread,
// and the UI only ever reads the numbers this writes.
@(private)
run_export :: proc(ex: ^Exporter, plan: Export_Plan) {
	if plan.err != "" {
		exporter_set(ex, .Failed, 0, plan.err, 0)
		return
	}
	// ffmpeg's diagnostics go to a file so a failure can be reported with its
	// real reason rather than "exit 1".
	logp := fmt.tprintf("%s/videoedit-ffmpeg-%d.log", tmp_dir(), os.get_pid())
	logf, lerr := os.open(logp, {.Write, .Create, .Trunc})
	if lerr != nil {
		logf = nil
	}

	pr_, perr := os.process_start({command = plan.argv, stdout = nil, stderr = logf, stdin = nil})
	if logf != nil {
		os.close(logf)
	}
	if perr != nil {
		exporter_set(ex, .Failed, 0, fmt.tprintf("could not start ffmpeg: %v", perr), 0)
		return
	}
	exporter_set(ex, .Running, 0, "encoding", 0)

	secs := f64(0)
	for {
		state, werr := os.process_wait(pr_, 120 * 1_000_000) // 120 ms
		if werr == nil && state.exited {
			dt := read_progress(plan.progress)
			if state.exit_code == 0 {
				msg := plan.notes == "" ? "export finished" : fmt.tprintf("export finished; %s", plan.notes)
				exporter_set(ex, .Done, 1, msg, max(dt, secs))
			} else {
				msg := tail_of(logp, 400)
				if msg == "" {
					msg = fmt.tprintf("ffmpeg exited with %d", state.exit_code)
				}
				exporter_set(ex, .Failed, 0, msg, max(dt, secs))
			}
			break
		}
		secs = read_progress(plan.progress)
		pct := f32(0)
		if plan.duration > 0 {
			pct = f32(math.clamp(secs / plan.duration, 0, 0.999))
		}
		exporter_set(
			ex,
			.Running,
			pct,
			fmt.tprintf("encoding %.1fs of %.1fs", secs, plan.duration),
			secs,
		)
		if sync.guard(&ex.mu) {
			if ex.quit {
				_ = os.process_kill(pr_)
			}
		}
	}
	for t in plan.temps {
		os.remove(t)
	}
	os.remove(plan.progress)
	os.remove(logp)
}

// read_progress returns the latest encoded timestamp in seconds. ffmpeg
// appends a block of key=value lines per update, so the last `out_time_us` in
// the file is the current position. `out_time_ms` is really microseconds in
// some builds, so `out_time_us` is read first and `out_time` parsed as a
// timecode as the fallback.
read_progress :: proc(path: string) -> f64 {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	body := string(data)
	best := f64(0)
	for line in strings.split_lines_iterator(&body) {
		if v, ok := strings.has_prefix(line, "out_time_us="), true; v && ok {
			if n, good := strconv.parse_f64(strings.trim_space(line[len("out_time_us="):])); good {
				best = n / 1_000_000
			}
		} else if strings.has_prefix(line, "out_time=") {
			if n, good := parse_timecode(line[len("out_time="):]); good {
				best = max(best, n)
			}
		}
	}
	return best
}

tail_of :: proc(path: string, n: int) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) == 0 {
		return ""
	}
	s := strings.trim_space(string(data))
	if len(s) > n {
		s = s[len(s) - n:]
	}
	return strings.clone(s, context.temp_allocator)
}

// verify_output is the honesty check: after an export, read the file back.
Verify :: struct {
	ok:       bool,
	duration: f64,
	width:    int,
	height:   int,
	streams:  int,
	vcodec:   string,
	acodec:   string,
}

verify_output :: proc(path: string, alloc := context.allocator) -> Verify {
	pb := probe_media(path, alloc)
	v := Verify {
		ok       = pb.ok,
		duration = pb.duration,
		width    = pb.width,
		height   = pb.height,
		vcodec   = pb.vcodec,
		acodec   = pb.acodec,
	}
	if pb.has_video {
		v.streams += 1
	}
	if pb.has_audio {
		v.streams += 1
	}
	return v
}

// export_still pulls one frame out of a finished export so the result can be
// looked at rather than taken on trust.
export_still :: proc(path: string, at: f64) -> (p.Image, bool) {
	return extract_thumb(path, at, 320)
}
