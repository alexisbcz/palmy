package main

// The worker thread.
//
// Three things in this application take longer than a frame: pulling the audio
// out of a video and reducing it to a waveform, transcribing, and burning
// captions into a new file. Measured here, `base.en` decodes about nine times
// faster than realtime, which still means a two-hour lecture is thirteen
// minutes of work. None of it may happen on the frame loop.
//
// So there is one job in flight at a time, started by the frame and run on a
// thread. The frame polls two atomics — a stage and a progress permille — plus
// a short mutex-guarded line of text, and draws a progress bar from them. The
// results are only read after `finished` is seen, which is the point at which
// the worker has stopped touching them.
//
// Preview frames get their own slot: they are requested several times a second
// while playing, and must never queue behind a transcription.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import kit "kit:."

Job_Kind :: enum {
	None,
	Import,
	Transcribe,
	Burn,
}

Stage :: enum i64 {
	Idle,
	Probing,
	Extracting_Audio,
	Reading_Waveform,
	Loading_Model,
	Transcribing,
	Encoding,
	Done,
}

stage_text :: proc(s: Stage) -> string {
	switch s {
	case .Idle:
		return "idle"
	case .Probing:
		return "probing the file"
	case .Extracting_Audio:
		return "extracting 16 kHz mono audio"
	case .Reading_Waveform:
		return "reading the waveform"
	case .Loading_Model:
		return "loading the model"
	case .Transcribing:
		return "transcribing"
	case .Encoding:
		return "encoding"
	case .Done:
		return "done"
	}
	return ""
}

Job :: struct {
	// --- set by the frame before the thread starts -------------------------
	kind:      Job_Kind,
	src:       string, // heap-owned
	out_path:  string, // heap-owned
	ass_text:  string, // heap-owned, for a burn-in
	opts:      Transcribe_Opts, // strings heap-owned
	duration:  f64, // for progress scaling

	// --- written by the thread, read once `finished` is seen ---------------
	info:      Media_Info,
	peaks:     Peaks,
	tr:        Transcript,
	ok:        bool,
	err:       string,
	seconds:   f64, // wall clock the job took
	media_sec: f64, // audio seconds processed, for the realtime factor

	// --- the handshake -----------------------------------------------------
	running:   bool,
	finished:  bool,
	cancel:    bool,
	stage:     Stage,
	permille:  i64,
	note_mu:   sync.Mutex,
	note_buf:  [192]u8,
	note_len:  int,
}

g_job: Job

job_busy :: proc() -> bool {
	return sync.atomic_load(&g_job.running)
}

job_kind :: proc() -> Job_Kind {
	if !job_busy() {
		return .None
	}
	return g_job.kind
}

job_stage :: proc() -> Stage {
	return Stage(sync.atomic_load(cast(^i64)&g_job.stage))
}

job_progress :: proc() -> f32 {
	return f32(sync.atomic_load(&g_job.permille)) / 1000
}

job_cancel :: proc() {
	sync.atomic_store(&g_job.cancel, true)
}

@(private = "file")
set_stage :: proc(s: Stage) {
	sync.atomic_store(cast(^i64)&g_job.stage, i64(s))
}

@(private = "file")
set_progress :: proc(f: f32) {
	sync.atomic_store(&g_job.permille, i64(clamp(f, 0, 1) * 1000))
}

// set_note publishes one short line for the UI — the segment whisper just
// emitted, or the frame ffmpeg just wrote. A fixed buffer under a mutex, so
// neither side allocates and the frame never reads a torn string.
@(private = "file")
set_note :: proc(s: string) {
	sync.mutex_lock(&g_job.note_mu)
	n := min(len(s), len(g_job.note_buf))
	copy(g_job.note_buf[:], s[:n])
	g_job.note_len = n
	sync.mutex_unlock(&g_job.note_mu)
}

// job_note copies the current line out for the frame to draw.
job_note :: proc(al := context.temp_allocator) -> string {
	sync.mutex_lock(&g_job.note_mu)
	out := strings.clone(string(g_job.note_buf[:g_job.note_len]), al)
	sync.mutex_unlock(&g_job.note_mu)
	return out
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

@(private = "file")
job_prepare :: proc(kind: Job_Kind) -> bool {
	if job_busy() {
		return false
	}
	g_job.kind = kind
	g_job.ok = false
	g_job.err = ""
	g_job.seconds = 0
	g_job.media_sec = 0
	g_job.info = {}
	g_job.peaks.ready = false
	g_job.tr = {}
	set_stage(.Idle)
	set_progress(0)
	set_note("")
	sync.atomic_store(&g_job.cancel, false)
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, true)
	return true
}

// start_import reads a media file: duration and streams, the 16 kHz mono WAV
// whisper needs, and the waveform.
start_import :: proc(path: string) -> bool {
	if !job_prepare(.Import) {
		return false
	}
	g_job.src = strings.clone(path)
	thread.create_and_start(import_worker, self_cleanup = true)
	return true
}

@(private = "file")
import_worker :: proc() {
	t0 := time.tick_now()
	defer {
		g_job.seconds = time.duration_seconds(time.tick_since(t0))
		set_stage(.Done)
		sync.atomic_store(&g_job.finished, true)
	}

	set_stage(.Probing)
	set_progress(0.05)
	info, err := probe(g_job.src, context.allocator)
	if err != "" {
		g_job.err = strings.clone(err)
		return
	}
	g_job.info = info

	set_stage(.Extracting_Audio)
	set_progress(0.2)
	wav := work_path("audio.wav", context.allocator)
	if ok, werr := extract_wav(g_job.src, wav); !ok {
		g_job.err = strings.clone(werr)
		return
	}
	g_job.out_path = wav // the 16 kHz copy, reused by the transcription

	set_stage(.Reading_Waveform)
	set_progress(0.6)
	raw := work_path("audio.raw", context.temp_allocator)
	if ok, perr := decode_peaks(g_job.src, raw, &g_job.peaks); !ok {
		// A missing waveform is a degraded view, not a failed import.
		set_note(perr)
	}

	set_progress(1)
	g_job.ok = true
}

// start_transcribe runs whisper-cli over the already-extracted WAV.
start_transcribe :: proc(opts: Transcribe_Opts, duration: f64) -> bool {
	if !job_prepare(.Transcribe) {
		return false
	}
	g_job.duration = duration
	g_job.opts = Transcribe_Opts {
		model      = strings.clone(opts.model),
		lang       = strings.clone(opts.lang),
		threads    = opts.threads,
		max_len    = opts.max_len,
		split_word = opts.split_word,
		translate  = opts.translate,
		vad        = opts.vad,
		vad_model  = strings.clone(opts.vad_model),
		wav        = strings.clone(opts.wav),
		out_prefix = strings.clone(opts.out_prefix),
		log        = strings.clone(opts.log),
	}
	thread.create_and_start(transcribe_worker, self_cleanup = true)
	return true
}

@(private = "file")
transcribe_worker :: proc() {
	t0 := time.tick_now()
	defer {
		g_job.seconds = time.duration_seconds(time.tick_since(t0))
		set_stage(.Done)
		sync.atomic_store(&g_job.finished, true)
	}

	o := g_job.opts
	os.remove(fmt.tprintf("%s.json", o.out_prefix))
	os.remove(o.log)

	set_stage(.Loading_Model)
	set_progress(0.01)

	argv := whisper_argv(o, context.temp_allocator)
	// whisper prints to stdout and stderr both; the log is the only channel
	// progress comes down, so both go to the same file.
	logf, lerr := os.open(o.log, {.Write, .Create, .Trunc}, os.perm_number(0o644))
	if lerr != nil {
		g_job.err = "could not open a log file for whisper's output"
		return
	}

	p, serr := os.process_start({command = argv, stdout = logf, stderr = logf, stdin = nil})
	if serr != nil {
		os.close(logf)
		g_job.err = fmt.aprintf(
			"could not start %s — is whisper.cpp installed? (%v)",
			WHISPER_BIN,
			serr,
		)
		return
	}

	exit_code := 0
	for {
		time.sleep(120 * time.Millisecond)
		free_all(context.temp_allocator)

		if sync.atomic_load(&g_job.cancel) {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			os.close(logf)
			g_job.err = "cancelled"
			return
		}

		if data, rerr := os.read_entire_file_from_path(o.log, context.temp_allocator);
		   rerr == nil {
			text := string(data)
			if f := progress_from_log(text, g_job.duration); f > 0 {
				set_stage(.Transcribing)
				set_progress(f)
			}
			if line := last_segment_line(text, context.temp_allocator); line != "" {
				set_note(line)
			}
		}

		state, werr := os.process_wait(p, 0)
		if werr == nil {
			exit_code = state.exit_code
			break
		}
	}
	os.close(logf)

	if exit_code != 0 {
		tail := ""
		if data, rerr := os.read_entire_file_from_path(o.log, context.temp_allocator);
		   rerr == nil {
			text := strings.trim_space(string(data))
			lines := strings.split_lines(text, context.temp_allocator)
			if len(lines) > 0 {
				tail = lines[len(lines) - 1]
			}
		}
		g_job.err = fmt.aprintf("whisper-cli exited %d: %s", exit_code, tail)
		return
	}

	set_progress(1)
	tr, perr := load_transcript(fmt.tprintf("%s.json", o.out_prefix), context.allocator)
	if perr != "" {
		g_job.err = strings.clone(perr)
		return
	}
	g_job.tr = tr
	g_job.media_sec = g_job.duration
	g_job.ok = true
}

// start_burn renders the captions into a new video file.
start_burn :: proc(src, ass_text, dst: string, duration: f64) -> bool {
	if !job_prepare(.Burn) {
		return false
	}
	g_job.src = strings.clone(src)
	g_job.ass_text = strings.clone(ass_text)
	g_job.out_path = strings.clone(dst)
	g_job.duration = duration
	thread.create_and_start(burn_worker, self_cleanup = true)
	return true
}

@(private = "file")
burn_worker :: proc() {
	t0 := time.tick_now()
	defer {
		g_job.seconds = time.duration_seconds(time.tick_since(t0))
		set_stage(.Done)
		sync.atomic_store(&g_job.finished, true)
	}

	if same_file(g_job.src, g_job.out_path) {
		g_job.err = "the output would overwrite the source file"
		return
	}

	ass_path := work_path("burn.ass", context.temp_allocator)
	if werr := os.write_entire_file(ass_path, transmute([]u8)g_job.ass_text); werr != nil {
		g_job.err = "could not write the ASS script for ffmpeg"
		return
	}

	log_path := work_path("burn.log", context.temp_allocator)
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc}, os.perm_number(0o644))
	if lerr != nil {
		g_job.err = "could not open a log file for ffmpeg's output"
		return
	}

	argv := burn_args(g_job.src, ass_path, g_job.out_path, context.temp_allocator)
	p, serr := os.process_start({command = argv, stdout = logf, stderr = logf, stdin = nil})
	if serr != nil {
		os.close(logf)
		g_job.err = fmt.aprintf("could not start ffmpeg (%v)", serr)
		return
	}

	set_stage(.Encoding)
	exit_code := 0
	for {
		time.sleep(160 * time.Millisecond)
		free_all(context.temp_allocator)

		if sync.atomic_load(&g_job.cancel) {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			os.close(logf)
			os.remove(g_job.out_path) // a half-encoded file is worse than none
			g_job.err = "cancelled"
			return
		}

		if data, rerr := os.read_entire_file_from_path(log_path, context.temp_allocator);
		   rerr == nil {
			if t, ok := ffmpeg_progress(string(data)); ok && g_job.duration > 0 {
				set_progress(f32(clamp(t / g_job.duration, 0, 1)))
				set_note(fmt.tprintf("%s of %s", clock(t), clock(g_job.duration)))
			}
		}

		state, werr := os.process_wait(p, 0)
		if werr == nil {
			exit_code = state.exit_code
			break
		}
	}
	os.close(logf)

	if exit_code != 0 || !os.exists(g_job.out_path) {
		tail := ""
		if data, rerr := os.read_entire_file_from_path(log_path, context.temp_allocator);
		   rerr == nil {
			lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
			for i := len(lines) - 1; i >= 0 && i >= len(lines) - 6; i -= 1 {
				l := strings.trim_space(lines[i])
				if l != "" && !strings.contains(l, "=") {
					tail = l
					break
				}
			}
		}
		g_job.err = fmt.aprintf("ffmpeg exited %d: %s", exit_code, tail)
		return
	}

	set_progress(1)
	g_job.ok = true
}

// ffmpeg_progress reads the last `out_time_us=` from `-progress pipe:1`, which
// is ffmpeg's machine-readable channel — far steadier than scraping `time=`
// out of the status line.
ffmpeg_progress :: proc(text: string) -> (t: f64, ok: bool) {
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "out_time_us=") {
			if v, good := strconv.parse_f64(l[len("out_time_us="):]); good && v >= 0 {
				t, ok = v / 1_000_000, true
			}
		} else if strings.has_prefix(l, "out_time_ms=") {
			if v, good := strconv.parse_f64(l[len("out_time_ms="):]); good && v >= 0 {
				// ffmpeg's out_time_ms is microseconds despite the name.
				t, ok = v / 1_000_000, true
			}
		}
	}
	return
}

// job_collect reports a finished job exactly once and releases its inputs.
// Everything in the returned view is owned by the caller from here on.
Job_Result :: struct {
	kind:      Job_Kind,
	ok:        bool,
	err:       string,
	info:      Media_Info,
	peaks:     ^Peaks,
	tr:        Transcript,
	wav:       string,
	out_path:  string,
	seconds:   f64,
	media_sec: f64,
}

job_collect :: proc() -> (res: Job_Result, got: bool) {
	if !sync.atomic_load(&g_job.running) || !sync.atomic_load(&g_job.finished) {
		return
	}
	res = Job_Result {
		kind      = g_job.kind,
		ok        = g_job.ok,
		err       = g_job.err,
		info      = g_job.info,
		peaks     = &g_job.peaks,
		tr        = g_job.tr,
		wav       = g_job.out_path,
		out_path  = g_job.out_path,
		seconds   = g_job.seconds,
		media_sec = g_job.media_sec,
	}
	got = true

	if g_job.ass_text != "" {
		delete(g_job.ass_text)
		g_job.ass_text = ""
	}
	if g_job.src != "" {
		delete(g_job.src)
		g_job.src = ""
	}
	if g_job.kind == .Transcribe {
		o := &g_job.opts
		for str in ([?]string{o.model, o.lang, o.vad_model, o.wav, o.out_prefix, o.log}) {
			if str != "" {
				delete(str)
			}
		}
		g_job.opts = {}
	}
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, false)
	g_job.kind = .None
	return
}

// ---------------------------------------------------------------------------
// Preview frames
//
// A separate slot, because these are asked for four times a second while the
// playhead moves and must not wait behind a transcription. Two output paths
// alternate so the main thread never decodes a half-written PNG.
// ---------------------------------------------------------------------------

Frame_Job :: struct {
	src:      string,
	t:        f64,
	width:    int,
	slot:     int,
	path:     string,
	running:  bool,
	finished: bool,
	ok:       bool,
}

g_frame: Frame_Job

frame_busy :: proc() -> bool {
	return sync.atomic_load(&g_frame.running)
}

// request_frame asks for the frame at `t`. It is a no-op while one is already
// in flight: the caller asks again next frame, which is the right behaviour —
// the request that lands is always the most recent one.
request_frame :: proc(src: string, t: f64, width: int) -> bool {
	if frame_busy() {
		return false
	}
	if g_frame.src != "" {
		delete(g_frame.src)
	}
	g_frame.src = strings.clone(src)
	g_frame.t = t
	g_frame.width = width
	g_frame.slot = 1 - g_frame.slot
	if g_frame.path != "" {
		delete(g_frame.path)
	}
	g_frame.path = work_path(
		g_frame.slot == 0 ? "preview-a.png" : "preview-b.png",
		context.allocator,
	)
	g_frame.ok = false
	sync.atomic_store(&g_frame.finished, false)
	sync.atomic_store(&g_frame.running, true)
	thread.create_and_start(frame_worker, self_cleanup = true)
	return true
}

@(private = "file")
frame_worker :: proc() {
	ok, _ := grab_frame(g_frame.src, g_frame.t, g_frame.path, g_frame.width)
	g_frame.ok = ok
	sync.atomic_store(&g_frame.finished, true)
}

// frame_collect hands over the path of a freshly written frame, once.
frame_collect :: proc() -> (path: string, t: f64, got: bool) {
	if !sync.atomic_load(&g_frame.running) || !sync.atomic_load(&g_frame.finished) {
		return
	}
	ok := g_frame.ok
	path = g_frame.path
	t = g_frame.t
	sync.atomic_store(&g_frame.finished, false)
	sync.atomic_store(&g_frame.running, false)
	return path, t, ok
}

// ---------------------------------------------------------------------------
// Time formatting for the UI
// ---------------------------------------------------------------------------

// clock is `M:SS.t` under an hour and `H:MM:SS.t` over it — a timecode a human
// reads, as distinct from the ones the file formats want.
clock :: proc(t: f64, al := context.temp_allocator) -> string {
	v := max(0, t)
	total := i64(v * 10)
	h := total / 36000
	m := (total % 36000) / 600
	s := (total % 600) / 10
	d := total % 10
	if h > 0 {
		return fmt.aprintf("%d:%02d:%02d.%d", h, m, s, d, allocator = al)
	}
	return fmt.aprintf("%d:%02d.%d", m, s, d, allocator = al)
}

// tool_check reports which of the external programs are present, so a missing
// one is a disabled button with an explanation rather than a silent failure.
Tools :: struct {
	ffmpeg:  bool,
	ffprobe: bool,
	ffplay:  bool,
	whisper: bool,
}

check_tools :: proc() -> Tools {
	return Tools {
		ffmpeg = kit.has_tool("ffmpeg"),
		ffprobe = kit.has_tool("ffprobe"),
		ffplay = kit.has_tool("ffplay"),
		whisper = kit.has_tool(WHISPER_BIN),
	}
}
