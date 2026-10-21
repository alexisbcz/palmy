package main

// palmy captions — local speech to text, and a caption editor around it.
//
// The pipeline is four external programs and no network:
//
//   ffprobe      duration, streams, resolution
//   ffmpeg       16 kHz mono WAV for whisper, 8 kHz PCM for the waveform,
//                single frames for the preview, and the burn-in
//   whisper-cli  whisper.cpp, against weights already on this disk
//   ffplay       audio playback with no window of its own
//
// Everything that takes longer than a frame runs on the worker thread in
// jobs.odin. The frame loop never blocks, which is why a two-hour file shows a
// moving progress bar instead of a frozen window.
//
// Keyboard first, throughout. The compositor this is developed against cannot
// synthesise pointer clicks, so every operation has a key — and that turned
// out to be the better interface anyway for work that is mostly "listen, fix
// the word, nudge the timing, next".

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import kit "kit:."
import p "palmy:."

WIN_W :: 1380
WIN_H :: 900

Pane :: enum {
	Transcribe,
	Captions,
	Style,
	Export,
}

pane_name :: proc(pn: Pane) -> string {
	switch pn {
	case .Transcribe:
		return "Transcribe"
	case .Captions:
		return "Captions"
	case .Style:
		return "Style"
	case .Export:
		return "Export"
	}
	return ""
}

// Focus is this application's own keyboard focus, rather than palmy's. There
// are only ever four places a keystroke can go, and keeping that in one enum
// is what makes the single-letter commands safe: they only fire when nothing
// is being typed into.
Focus :: enum {
	Browse,
	Caption,
	Path,
	Output,
}

Drag_What :: enum {
	None,
	Playhead,
	Seg_Start,
	Seg_End,
	Seg_Body,
}

App_State :: struct {
	tools:         Tools,
	models:        []Model,
	vad_model:     string,
	has_vad:       bool,

	// The media.
	info:          Media_Info,
	loaded:        bool,
	wav:           string,
	peaks:         ^Peaks,

	// Transcription settings.
	model_i:       int,
	lang_i:        int,
	threads:       int,
	max_len:       int,
	split_word:    bool,
	use_vad:       bool,
	translate:     bool,

	// Results.
	segs:          [dynamic]Seg,
	words:         [dynamic]Word,
	sel:           int,
	rtf:           f64,
	decode_sec:    f64,
	heard_lang:    string,
	transcribed:   bool,

	// Editing.
	focus:         Focus,
	caret:         int,
	limits:        Limits,
	dirty:         bool,

	// Playback.
	player:        Player,
	playing:       bool,
	pos:           f64, // the playhead, in media seconds
	clock_at:      f64, // app_elapsed when `pos` was last authoritative
	follow:        bool,

	// Preview.
	preview:       p.Image,
	preview_ok:    bool,
	preview_t:     f64,
	preview_asked: f64,
	preview_due:   f64,
	style:         Caption_Style,

	// Chrome.
	pane:          Pane,
	path_buf:      [dynamic]u8,
	path_caret:    int,
	out_buf:       [dynamic]u8,
	out_caret:     int,
	fmt_i:         Format,
	status:        string,
	status_bad:    bool,
	dir:           string,
	dir_files:     []string,
	file_sel:      int,

	// The waveform viewport, in seconds.
	view_from:     f64,
	view_span:     f64,
	drag:          Drag_What,
	drag_seg:      int,
	help:          bool,

	// `p.pixels` keeps these pointers until the tree is painted, which is
	// after the frame has been built — so they live with the model, not on
	// the stack of whatever built the element.
	prev_ctx:      Preview_Ctx,
	wave_ctx:      Wave_Ctx,
	warn_scratch:  [dynamic]bool,

	// Deferred structural edits — see `Act`.
	queue:         [dynamic]Act,

	// The shared file dialog, and what it was opened for. See pick.odin.
	pick:          kit.Pick,
	pick_use:      Pick_Use,
}

// Act is an edit that changes the *shape* of the caption list, queued rather
// than applied where the button was pressed.
//
// The waveform is drawn by `p.pixels`, which keeps a slice of `segs` until the
// tree is painted — after the whole frame has been built. A split pressed in
// the side panel would grow that dynamic array, move its backing store, and
// leave the painter reading freed memory a few milliseconds later. Anything
// that inserts, removes or reallocates therefore goes on this queue and is
// applied at the top of the next frame, before a single element exists.
//
// Edits that only move a number — nudging a timing, dragging an edge — are
// applied immediately, because they cannot move the array.
Act_Kind :: enum {
	Split,
	Merge,
	Delete,
	Insert,
	Wrap,
	Wrap_All,
	Open,
}

Act :: struct {
	kind: Act_Kind,
	i:    int,
	path: string, // heap-owned, for Open
}

queue_act :: proc(m: ^App_State, kind: Act_Kind, i: int = -1, path: string = "") {
	append(&m.queue, Act{kind = kind, i = i, path = path == "" ? "" : strings.clone(path)})
}

apply_queue :: proc(m: ^App_State) {
	if len(m.queue) == 0 {
		return
	}
	for a in m.queue {
		switch a.kind {
		case .Split:
			m.sel = a.i
			do_split(m)
		case .Merge:
			m.sel = a.i
			do_merge(m)
		case .Delete:
			if delete_seg(&m.segs, a.i) {
				m.dirty = true
				select_seg(m, min(a.i, len(m.segs) - 1))
			}
		case .Insert:
			at := insert_seg(&m.segs, a.i, 2)
			m.dirty = true
			select_seg(m, at)
			m.focus = .Caption
			m.caret = 0
		case .Wrap:
			if a.i >= 0 && a.i < len(m.segs) {
				auto_wrap(&m.segs[a.i], m.limits.max_cpl, m.limits.max_lines)
				m.dirty = true
			}
		case .Wrap_All:
			wrap_all(m)
		case .Open:
			open_path(m, a.path)
		}
		if a.path != "" {
			delete(a.path)
		}
	}
	clear(&m.queue)
}

main :: proc() {
	args := os.args[1:]
	// `--shot` predates the shared convention and takes its output path in a
	// shape the declaration does not describe, so it is looked for first.
	for a in args {
		if a == "--shot" {
			os.exit(shot_main(args))
		}
	}

	// The command line is the other front end over the same App_State: see
	// cli.odin. `--selftest`, `--help` and `--schema` are answered there. With
	// no command, or with a bare file, there is a window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	m := new(App_State)
	state_init(m)
	defer state_destroy(m)

	// A file on the command line is imported as if it had been typed in.
	for a in args {
		if strings.has_prefix(a, "-") {
			continue
		}
		if abs, aerr := filepath.abs(a, context.allocator); aerr == nil {
			clear(&m.path_buf)
			append(&m.path_buf, abs)
			m.path_caret = len(m.path_buf)
			open_path(m, abs)
			delete(abs)
		}
		break
	}

	app, err := kit.start({title = "Captions", width = WIN_W, height = WIN_H, decorate = true}, true)
	if err != "" {
		fmt.eprintfln("captions: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	defer kit.pick_destroy(&m.pick)
	p.set_min_size(app, 980, 620)

	for ui in p.frames(app) {
		tick(ui, app, m)
		draw(ui, &app.fonts, m)
	}

	player_stop(&m.player)
}

state_init :: proc(m: ^App_State) {
	m.tools = check_tools()
	m.models = find_models()
	m.vad_model, m.has_vad = find_vad_model()
	m.peaks = new(Peaks)
	m.segs = make([dynamic]Seg)
	m.words = make([dynamic]Word)
	m.limits = default_limits()
	m.style = default_style()
	m.threads = 4
	m.max_len = 42
	m.split_word = true
	m.follow = true
	m.sel = -1
	m.fmt_i = .SRT
	m.view_span = 0
	m.pane = .Transcribe
	m.path_buf = make([dynamic]u8)
	m.out_buf = make([dynamic]u8)
	m.warn_scratch = make([dynamic]bool)
	m.queue = make([dynamic]Act)

	// Prefer the small English model: it is the one that keeps up with a long
	// file, and the better one is a keypress away.
	for mm, i in m.models {
		if !mm.multilingual {
			m.model_i = i
			break
		}
	}
	m.lang_i = 1 // English

	cwd, _ := os.get_working_directory(context.allocator)
	if cwd == "" {
		cwd = strings.clone(".")
	}
	m.dir = cwd
	m.dir_files = list_media(cwd)

	if !m.tools.whisper {
		set_status(
			m,
			"whisper-cli is not on PATH — install whisper.cpp to transcribe",
			true,
		)
	} else if len(m.models) == 0 {
		set_status(m, "no whisper models found; press 4 to see where I looked", true)
	} else if !m.tools.ffmpeg || !m.tools.ffprobe {
		set_status(m, "ffmpeg and ffprobe are required to read media", true)
	} else {
		set_status(m, "open a video or audio file to begin", false)
	}
}

state_destroy :: proc(m: ^App_State) {
	player_stop(&m.player)
	for &s in m.segs {
		seg_destroy(&s)
	}
	delete(m.segs)
	delete(m.words)
	delete(m.warn_scratch)
	delete(m.queue)
	free(m.peaks)
	if m.preview_ok {
		p.image_destroy(&m.preview)
	}
}

// status_echo copies a failure to stderr for someone watching a terminal. The
// command line turns it off: there the failure is the command's own result,
// and a second copy of it on stderr is noise.
status_echo := true

set_status :: proc(m: ^App_State, text: string, bad: bool) {
	if m.status != "" {
		delete(m.status)
	}
	m.status = strings.clone(text)
	m.status_bad = bad
	if bad && status_echo {
		fmt.eprintfln("[captions] %s", text)
	}
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

open_path :: proc(m: ^App_State, path: string) {
	trimmed := strings.trim_space(path)
	if trimmed == "" {
		return
	}
	expanded := trimmed
	if strings.has_prefix(trimmed, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		expanded = fmt.tprintf("%s%s", home, trimmed[1:])
	}

	if !os.exists(expanded) {
		set_status(m, fmt.tprintf("no such file: %s", expanded), true)
		return
	}
	// Everything downstream — the default export path, the burn-in's refusal
	// to overwrite the source — reasons about directories, so the path is made
	// absolute once, here.
	expanded = normal_path(expanded, context.temp_allocator)

	// A directory just moves the picker.
	if fi, ferr := os.stat(expanded, context.temp_allocator); ferr == nil && fi.type == .Directory {
		set_dir(m, expanded)
		return
	}

	if is_subtitle_path(expanded) {
		load_subtitle(m, expanded)
		return
	}
	if !is_media_path(expanded) {
		set_status(m, "that is not a media or subtitle file I recognise", true)
		return
	}
	if job_busy() {
		set_status(m, "something else is still running", true)
		return
	}

	player_stop(&m.player)
	m.playing = false
	m.loaded = false
	m.transcribed = false
	m.peaks.ready = false
	m.pos = 0
	m.view_from = 0
	m.view_span = 0
	clear_segments(m)
	set_dir(m, strings.clone(filepath.dir(expanded)))
	start_import(expanded)
	set_status(m, fmt.tprintf("reading %s", filepath.base(expanded)), false)
}

set_dir :: proc(m: ^App_State, dir: string) {
	if m.dir != "" && m.dir != dir {
		delete(m.dir)
	}
	m.dir = dir
	if m.dir_files != nil {
		for f in m.dir_files {
			delete(f)
		}
		delete(m.dir_files)
	}
	m.dir_files = list_media(dir)
	m.file_sel = 0
}

load_subtitle :: proc(m: ^App_State, path: string) {
	segs, err := load_cues(path, context.allocator)
	if err != "" {
		set_status(m, fmt.tprintf("%s: %s", filepath.base(path), err), true)
		return
	}
	clear_segments(m)
	for s in segs {
		append(&m.segs, s)
	}
	delete(segs)
	m.sel = len(m.segs) > 0 ? 0 : -1
	m.pane = .Captions
	m.transcribed = true
	set_status(m, fmt.tprintf("read %d captions from %s", len(m.segs), filepath.base(path)), false)
}

clear_segments :: proc(m: ^App_State) {
	for &s in m.segs {
		seg_destroy(&s)
	}
	clear(&m.segs)
	clear(&m.words)
	m.sel = -1
	m.caret = 0
	m.focus = .Browse
	m.dirty = false
}

// ---------------------------------------------------------------------------
// Per-frame logic
// ---------------------------------------------------------------------------

tick :: proc(ui: ^p.Ctx, app: ^p.App, m: ^App_State) {
	apply_queue(m)
	collect_jobs(ui, m)
	advance_playhead(ui, app, m)
	refresh_preview(m)
	handle_keys(ui, app, m)

	// Anything in flight, or playing, means the next frame has new content;
	// palmy otherwise sleeps until input arrives.
	if job_busy() || frame_busy() || m.playing {
		p.redraw(ui)
	}
}

collect_jobs :: proc(ui: ^p.Ctx, m: ^App_State) {
	if res, got := job_collect(); got {
		apply_job_result(m, res)
		p.redraw(ui)
	}

	if path, t, got := frame_collect(); got {
		if path != "" && os.exists(path) {
			img, ok := p.load_image(path)
			if ok {
				if m.preview_ok {
					p.image_destroy(&m.preview)
				}
				m.preview = img
				m.preview_ok = true
				m.preview_t = t
			}
		}
		p.redraw(ui)
	}
}

// apply_job_result takes a finished job into the model. It is the one place
// an import, a transcription or a burn-in lands, for the window (collect_jobs,
// once a frame) and for the command line (wait_job, in a loop) alike.
apply_job_result :: proc(m: ^App_State, res: Job_Result) {
	switch res.kind {
	case .Import:
		if !res.ok {
			set_status(m, res.err, true)
			break
		}
		m.info = res.info
		m.loaded = true
		if m.wav != "" && m.wav != res.wav {
			delete(m.wav)
		}
		m.wav = res.wav
		m.peaks^ = res.peaks^
		m.view_from = 0
		m.view_span = m.info.duration
		m.pos = 0
		m.preview_asked = -1
		m.preview_due = 0
		streams := fmt.tprintf("audio only, %s", m.info.acodec)
		if m.info.has_video {
			streams = fmt.tprintf("%dx%d %s", m.info.width, m.info.height, m.info.vcodec)
		}
		set_status(
			m,
			fmt.tprintf(
				"%s · %s · %s",
				filepath.base(m.info.path),
				clock(m.info.duration),
				streams,
			),
			false,
		)
		if m.info.has_video {
			request_preview(m, 0)
		}
	case .Transcribe:
		if !res.ok {
			set_status(m, res.err, true)
			break
		}
		clear_segments(m)
		for s in res.tr.segs {
			append(&m.segs, s)
		}
		for w in res.tr.words {
			append(&m.words, w)
		}
		delete(res.tr.segs)
		delete(res.tr.words)
		m.heard_lang = res.tr.lang
		m.sel = len(m.segs) > 0 ? 0 : -1
		m.transcribed = true
		m.decode_sec = res.seconds
		m.rtf = res.media_sec / max(res.seconds, 0.0001)
		m.pane = .Captions
		set_status(
			m,
			fmt.tprintf(
				"%d captions in %.1fs — %.1fx realtime",
				len(m.segs),
				res.seconds,
				m.rtf,
			),
			false,
		)
	case .Burn:
		if !res.ok {
			set_status(m, res.err, true)
			break
		}
		set_status(
			m,
			fmt.tprintf("burned in to %s in %.0fs", filepath.base(res.out_path), res.seconds),
			false,
		)
	case .None:
	}
}

advance_playhead :: proc(ui: ^p.Ctx, app: ^p.App, m: ^App_State) {
	if !m.playing {
		return
	}
	// ffplay owns the audio clock; this is a parallel one, re-based at every
	// seek. It drifts by a frame or two over minutes, which the highlight does
	// not care about and the timecodes never see.
	m.pos += f64(p.delta_time(ui))
	if !player_alive(&m.player) || m.pos >= m.info.duration {
		m.playing = false
		m.pos = min(m.pos, m.info.duration)
		return
	}
	if m.follow {
		keep_playhead_visible(m)
	}
	if m.info.has_video && m.pos >= m.preview_due {
		request_preview(m, m.pos)
	}
}

// request_preview throttles the frame grabs: four a second while playing is
// enough to read as video and cheap enough that ffmpeg keeps up.
request_preview :: proc(m: ^App_State, t: f64) {
	if !m.loaded || !m.info.has_video {
		return
	}
	if frame_busy() {
		return
	}
	m.preview_asked = t
	m.preview_due = t + 0.25
	request_frame(m.info.path, t, 480)
}

refresh_preview :: proc(m: ^App_State) {
	if !m.loaded || !m.info.has_video || m.playing {
		return
	}
	// When paused, keep the frame on the playhead but only chase it once it
	// has really moved.
	if abs_f(m.pos - m.preview_asked) > 0.2 {
		request_preview(m, m.pos)
	}
}

abs_f :: proc(v: f64) -> f64 {
	return v < 0 ? -v : v
}

keep_playhead_visible :: proc(m: ^App_State) {
	if m.view_span <= 0 || m.view_span >= m.info.duration {
		return
	}
	if m.pos < m.view_from || m.pos > m.view_from + m.view_span {
		m.view_from = clamp(m.pos - m.view_span * 0.3, 0, max(0, m.info.duration - m.view_span))
	}
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

toggle_play :: proc(m: ^App_State) {
	if !m.loaded {
		return
	}
	if m.playing {
		player_stop(&m.player)
		m.playing = false
		return
	}
	if !m.tools.ffplay {
		set_status(m, "ffplay is not installed, so there is no playback", true)
		return
	}
	if m.pos >= m.info.duration - 0.05 {
		m.pos = 0
	}
	if !player_start(&m.player, m.info.path, m.pos) {
		set_status(m, "ffplay would not start", true)
		return
	}
	m.playing = true
}

seek_to :: proc(m: ^App_State, t: f64) {
	if !m.loaded {
		return
	}
	m.pos = clamp(t, 0, m.info.duration)
	if m.playing {
		player_start(&m.player, m.info.path, m.pos)
	}
	if m.follow {
		keep_playhead_visible(m)
	}
	if m.info.has_video {
		request_preview(m, m.pos)
	}
}

select_seg :: proc(m: ^App_State, i: int, and_seek := false) {
	if len(m.segs) == 0 {
		m.sel = -1
		return
	}
	m.sel = clamp(i, 0, len(m.segs) - 1)
	m.caret = min(m.caret, len(m.segs[m.sel].text))
	if and_seek {
		seek_to(m, m.segs[m.sel].start)
	}
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

begin_transcribe :: proc(m: ^App_State) {
	if !m.loaded {
		set_status(m, "open a media file first", true)
		return
	}
	if len(m.models) == 0 {
		set_status(m, "no whisper model to transcribe with", true)
		return
	}
	if !m.tools.whisper {
		set_status(m, "whisper-cli is not on PATH", true)
		return
	}
	if job_busy() {
		set_status(m, "something else is still running", true)
		return
	}

	mdl := m.models[clamp(m.model_i, 0, len(m.models) - 1)]
	lang := LANGUAGES[clamp(m.lang_i, 0, len(LANGUAGES) - 1)].code
	if !mdl.multilingual {
		lang = "en" // an .en model has no other option
	}

	opts := Transcribe_Opts {
		model      = mdl.path,
		lang       = lang,
		threads    = m.threads,
		max_len    = m.max_len,
		split_word = m.split_word,
		translate  = m.translate && mdl.multilingual,
		vad        = m.use_vad && m.has_vad,
		vad_model  = m.vad_model,
		wav        = m.wav,
		out_prefix = work_path("transcript", context.temp_allocator),
		log        = work_path("whisper.log", context.temp_allocator),
	}
	if start_transcribe(opts, m.info.duration) {
		set_status(m, fmt.tprintf("transcribing with %s", mdl.name), false)
	}
}

export_now :: proc(m: ^App_State) {
	if len(m.segs) == 0 {
		set_status(m, "there are no captions to export", true)
		return
	}
	path := strings.trim_space(string(m.out_buf[:]))
	if path == "" {
		path = default_output(
			m.loaded ? m.info.path : "captions",
			"",
			format_ext(m.fmt_i),
			context.temp_allocator,
		)
	}
	// Writing over the media would be a catastrophe, not an inconvenience.
	if m.loaded && same_file(path, m.info.path) {
		set_status(m, "that path is the media file itself", true)
		return
	}
	sorted := make([dynamic]Seg, context.temp_allocator)
	for s in m.segs {
		append(&sorted, s)
	}
	sort_segs(&sorted)
	ok, err := save_subtitles(
		path,
		m.fmt_i,
		sorted[:],
		m.style,
		m.info.width,
		m.info.height,
	)
	if ok {
		m.dirty = false
		set_status(m, fmt.tprintf("wrote %d captions to %s", len(m.segs), path), false)
	} else {
		set_status(m, fmt.tprintf("could not write %s: %s", path, err), true)
	}
}

begin_burn :: proc(m: ^App_State) {
	if !m.loaded || !m.info.has_video {
		set_status(m, "burn-in needs a video file", true)
		return
	}
	if len(m.segs) == 0 {
		set_status(m, "there are no captions to burn in", true)
		return
	}
	if job_busy() {
		set_status(m, "something else is still running", true)
		return
	}
	dst := strings.trim_space(string(m.out_buf[:]))
	if dst == "" || is_subtitle_path(dst) {
		dst = default_output(m.info.path, ".captioned", "mp4", context.temp_allocator)
	}
	if same_file(dst, m.info.path) {
		set_status(m, "the output would overwrite the source", true)
		return
	}
	sorted := make([dynamic]Seg, context.temp_allocator)
	for s in m.segs {
		append(&sorted, s)
	}
	sort_segs(&sorted)
	ass := write_ass(sorted[:], m.style, m.info.width, m.info.height, context.temp_allocator)
	if start_burn(m.info.path, ass, dst, m.info.duration) {
		set_status(m, fmt.tprintf("burning captions into %s", filepath.base(dst)), false)
	}
}

// wrap_all re-breaks every caption at the line limit. Shift+W, the panel's
// button and `captions wrap` all come here.
wrap_all :: proc(m: ^App_State) -> (changed: int) {
	for &sg in m.segs {
		before := strings.clone(seg_text(sg), context.temp_allocator)
		auto_wrap(&sg, m.limits.max_cpl, m.limits.max_lines)
		if seg_text(sg) != before {
			changed += 1
		}
	}
	m.dirty = true
	set_status(m, "re-wrapped every caption", false)
	return
}

do_split :: proc(m: ^App_State) {
	if m.sel < 0 || m.sel >= len(m.segs) {
		return
	}
	at := m.caret
	body := seg_text(m.segs[m.sel])
	if m.focus != .Caption {
		// Not editing: split at the word boundary nearest the middle.
		at = len(body) / 2
		for at < len(body) && body[at] != ' ' {
			at += 1
		}
	}
	if split_seg(&m.segs, m.sel, at, m.words[:]) {
		m.dirty = true
		m.caret = 0
		set_status(m, "split", false)
	} else {
		set_status(m, "nothing to split there", true)
	}
}

do_merge :: proc(m: ^App_State) {
	if m.sel < 0 || m.sel + 1 >= len(m.segs) {
		set_status(m, "no caption after this one to merge with", true)
		return
	}
	merge_segs(&m.segs, m.sel)
	m.dirty = true
	m.caret = min(m.caret, len(m.segs[m.sel].text))
	set_status(m, "merged with the next caption", false)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^App_State) {
	// The file dialog owns the keyboard while it is up; it reads its own
	// input in `pick_overlay`, during the draw pass.
	if kit.pick_active(&m.pick) {
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(m, .Media)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl, .Shift}) || p.shortcut(ui, 'S', {.Ctrl, .Shift}) {
		begin_pick(m, .Output)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		export_now(m)
		return
	}

	// Text entry takes precedence: a caption containing the letter `d` must
	// not delete the caption.
	switch m.focus {
	case .Path:
		edit_line(ui, &m.path_buf, &m.path_caret, false)
		if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) {
			m.focus = .Browse
			open_path(m, string(m.path_buf[:]))
		}
		if p.key_pressed(ui, p.KEY_ESCAPE, false) {
			m.focus = .Browse
		}
		return
	case .Output:
		edit_line(ui, &m.out_buf, &m.out_caret, false)
		if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) {
			m.focus = .Browse
		}
		if p.key_pressed(ui, p.KEY_ESCAPE, false) {
			m.focus = .Browse
		}
		return
	case .Caption:
		if m.sel >= 0 && m.sel < len(m.segs) {
			if p.shortcut(ui, 'k', {.Ctrl}) {
				do_split(m)
				return
			}
			changed := edit_line(ui, &m.segs[m.sel].text, &m.caret, true)
			if changed {
				m.dirty = true
			}
			// Up and Down move between visual lines of the caption; Ctrl with
			// them moves between captions.
			if p.shortcut(ui, p.KEY_UP, {.Ctrl}, true) {
				select_seg(m, m.sel - 1, true)
				m.caret = 0
			}
			if p.shortcut(ui, p.KEY_DOWN, {.Ctrl}, true) {
				select_seg(m, m.sel + 1, true)
				m.caret = 0
			}
		}
		if p.key_pressed(ui, p.KEY_ESCAPE, false) || p.key_pressed(ui, p.KEY_TAB, false) {
			m.focus = .Browse
		}
		return
	case .Browse:
	}

	// --- browse mode -------------------------------------------------------
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		if m.help {
			m.help = false
		} else if job_busy() {
			job_cancel()
			set_status(m, "cancelling…", false)
		}
	}
	if p.key_pressed(ui, '?', false) || p.shortcut(ui, '/', {.Shift}) {
		m.help = !m.help
	}

	for i in 0 ..< 4 {
		if p.key_pressed(ui, u32('1' + i), false) {
			m.pane = Pane(i)
		}
	}

	if p.key_pressed(ui, p.KEY_SPACE, false) {
		toggle_play(m)
	}
	if p.key_pressed(ui, 'k', false) {
		toggle_play(m)
	}

	shift := .Shift in ui.input.mods
	step := shift ? 10.0 : 2.0
	if p.key_pressed(ui, p.KEY_LEFT) {
		seek_to(m, m.pos - step)
	}
	if p.key_pressed(ui, p.KEY_RIGHT) {
		seek_to(m, m.pos + step)
	}
	if p.key_pressed(ui, p.KEY_UP) {
		select_seg(m, m.sel <= 0 ? 0 : m.sel - 1, true)
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		select_seg(m, m.sel + 1, true)
	}
	if p.key_pressed(ui, p.KEY_HOME, false) {
		select_seg(m, 0, true)
	}
	if p.key_pressed(ui, p.KEY_END, false) {
		select_seg(m, len(m.segs) - 1, true)
	}
	if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) {
		if m.sel >= 0 {
			m.focus = .Caption
			m.caret = len(m.segs[m.sel].text)
			m.pane = .Captions
		}
	}

	if p.key_pressed(ui, 'o', false) {
		m.focus = .Path
		m.path_caret = len(m.path_buf)
		m.pane = .Transcribe
	}
	if p.key_pressed(ui, 't', false) {
		begin_transcribe(m)
	}
	if p.key_pressed(ui, 'e', false) {
		export_now(m)
	}
	if p.key_pressed(ui, 'b', false) {
		begin_burn(m)
	}
	if p.key_pressed(ui, 'f', false) {
		m.fmt_i = Format((int(m.fmt_i) + 1) % len(Format))
		set_status(m, fmt.tprintf("export format: %s", format_name(m.fmt_i)), false)
	}
	if p.key_pressed(ui, 'g', false) {
		m.follow = !m.follow
		set_status(m, m.follow ? "following the playhead" : "not following the playhead", false)
	}

	// Editing the selection.
	if p.key_pressed(ui, 's', false) {
		do_split(m)
	}
	if p.key_pressed(ui, 'm', false) {
		do_merge(m)
	}
	if p.key_pressed(ui, 'd', false) {
		if m.sel >= 0 && delete_seg(&m.segs, m.sel) {
			m.dirty = true
			select_seg(m, min(m.sel, len(m.segs) - 1))
			set_status(m, "deleted", false)
		}
	}
	if p.key_pressed(ui, 'n', false) {
		at := insert_seg(&m.segs, m.sel, 2.0)
		m.dirty = true
		select_seg(m, at)
		m.focus = .Caption
		m.caret = 0
	}
	if p.key_pressed(ui, 'w', false) {
		if shift {
			wrap_all(m)
		} else if m.sel >= 0 {
			auto_wrap(&m.segs[m.sel], m.limits.max_cpl, m.limits.max_lines)
			m.dirty = true
		}
	}

	// Timings. The bracket pair moves the in point, comma and full stop the
	// out point, and the shifted versions slide the whole caption.
	nudge := shift ? 0.5 : 0.1
	if p.key_pressed(ui, '[') {
		nudge_start(&m.segs, m.sel, -nudge, m.limits)
		m.dirty = true
	}
	if p.key_pressed(ui, ']') {
		nudge_start(&m.segs, m.sel, nudge, m.limits)
		m.dirty = true
	}
	if p.key_pressed(ui, ',') {
		nudge_end(&m.segs, m.sel, -nudge, m.limits, m.info.duration)
		m.dirty = true
	}
	if p.key_pressed(ui, '.') {
		nudge_end(&m.segs, m.sel, nudge, m.limits, m.info.duration)
		m.dirty = true
	}
	if p.key_pressed(ui, '<') {
		shift_seg(&m.segs, m.sel, -nudge, m.info.duration)
		m.dirty = true
	}
	if p.key_pressed(ui, '>') {
		shift_seg(&m.segs, m.sel, nudge, m.info.duration)
		m.dirty = true
	}
	// Set an edge from the playhead, which is how timings are really fixed:
	// listen, then stamp.
	if p.key_pressed(ui, 'i', false) && m.sel >= 0 {
		set_seg_times(&m.segs, m.sel, m.pos, m.segs[m.sel].end, m.info.duration)
		m.dirty = true
		set_status(m, "in point set from the playhead", false)
	}
	if p.key_pressed(ui, 'u', false) && m.sel >= 0 {
		set_seg_times(&m.segs, m.sel, m.segs[m.sel].start, m.pos, m.info.duration)
		m.dirty = true
		set_status(m, "out point set from the playhead", false)
	}

	// The waveform viewport.
	if m.loaded {
		if p.key_pressed(ui, '=') || p.key_pressed(ui, '+') {
			zoom_view(m, 0.6)
		}
		if p.key_pressed(ui, '-') {
			zoom_view(m, 1 / 0.6)
		}
		if p.key_pressed(ui, '0', false) {
			m.view_from = 0
			m.view_span = m.info.duration
		}
	}

	// Styling, from the keyboard, so the demo can show it.
	if m.pane == .Style {
		if p.key_pressed(ui, 'j') {
			m.style.size = max(8, m.style.size - 2)
		}
		if p.key_pressed(ui, 'l') {
			m.style.size = min(200, m.style.size + 2)
		}
		if p.key_pressed(ui, 'c', false) {
			cycle_fill(m)
		}
		if p.key_pressed(ui, 'x', false) {
			m.style.box = !m.style.box
		}
		if p.key_pressed(ui, 'p', false) {
			m.style.pos = Position((int(m.style.pos) + 1) % len(Position))
		}
		if p.key_pressed(ui, 'y', false) {
			m.style.bold = !m.style.bold
		}
		if p.key_pressed(ui, 'h') {
			m.style.outline = max(0, m.style.outline - 0.5)
		}
		if p.key_pressed(ui, 'r') {
			m.style.outline = min(10, m.style.outline + 0.5)
		}
	}
	if m.pane == .Transcribe {
		if p.key_pressed(ui, 'j', false) {
			m.model_i = (m.model_i + 1) % max(1, len(m.models))
		}
		if p.key_pressed(ui, 'l', false) {
			m.lang_i = (m.lang_i + 1) % len(LANGUAGES)
		}
		if p.key_pressed(ui, 'v', false) && m.has_vad {
			m.use_vad = !m.use_vad
		}
		if p.key_pressed(ui, 'p', false) && len(m.dir_files) > 0 {
			m.file_sel = (m.file_sel + 1) % len(m.dir_files)
		}
		if p.key_pressed(ui, 'r', false) && len(m.dir_files) > 0 {
			name := m.dir_files[clamp(m.file_sel, 0, len(m.dir_files) - 1)]
			queue_act(m, .Open, 0, fmt.tprintf("%s/%s", m.dir, name))
		}
	}
}

FILL_SWATCHES := [?]u32{0xffffff, 0xffe066, 0x7dd3fc, 0x86efac, 0xfca5a5, 0x000000}

cycle_fill :: proc(m: ^App_State) {
	for c, i in FILL_SWATCHES {
		if c == m.style.fill {
			m.style.fill = FILL_SWATCHES[(i + 1) % len(FILL_SWATCHES)]
			return
		}
	}
	m.style.fill = FILL_SWATCHES[0]
}

zoom_view :: proc(m: ^App_State, factor: f64) {
	if !m.loaded {
		return
	}
	centre := clamp(m.pos, m.view_from, m.view_from + max(m.view_span, 0.001))
	span := clamp(m.view_span * factor, 0.5, m.info.duration)
	m.view_span = span
	m.view_from = clamp(centre - span / 2, 0, max(0, m.info.duration - span))
}

// ---------------------------------------------------------------------------
// A line editor
//
// palmy's `text_field` is a single-line widget that owns its own focus. The
// caption editor needs multi-line text, a caret this application can place
// from a click, and focus that follows the selected row — so the keystrokes
// are handled here and the drawing is in ui.odin, both against the same
// `[dynamic]u8` the model stores.
// ---------------------------------------------------------------------------

edit_line :: proc(
	ui: ^p.Ctx,
	buf: ^[dynamic]u8,
	caret: ^int,
	multiline: bool,
) -> (
	changed: bool,
) {
	caret^ = clamp(caret^, 0, len(buf))

	if typed := p.typed_text(ui); len(typed) > 0 {
		inject_at_elems(buf, caret^, ..transmute([]u8)typed)
		caret^ += len(typed)
		changed = true
	}

	for k in ui.input.keys {
		ctrl := .Ctrl in k.mods
		switch k.sym {
		case p.KEY_BACKSPACE:
			if caret^ > 0 {
				n := rune_back(buf[:], caret^)
				remove_range(buf, caret^ - n, caret^)
				caret^ -= n
				changed = true
			}
		case p.KEY_DELETE:
			if caret^ < len(buf) {
				n := rune_forward(buf[:], caret^)
				remove_range(buf, caret^, caret^ + n)
				changed = true
			}
		case p.KEY_LEFT:
			if ctrl {
				caret^ = word_left(buf[:], caret^)
			} else if caret^ > 0 {
				caret^ -= rune_back(buf[:], caret^)
			}
		case p.KEY_RIGHT:
			if ctrl {
				caret^ = word_right(buf[:], caret^)
			} else if caret^ < len(buf) {
				caret^ += rune_forward(buf[:], caret^)
			}
		case p.KEY_HOME:
			caret^ = line_start(buf[:], caret^)
		case p.KEY_END:
			caret^ = line_end(buf[:], caret^)
		case p.KEY_UP:
			if multiline && !ctrl {
				caret^ = move_line(buf[:], caret^, -1)
			}
		case p.KEY_DOWN:
			if multiline && !ctrl {
				caret^ = move_line(buf[:], caret^, +1)
			}
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if multiline {
				inject_at(buf, caret^, u8('\n'))
				caret^ += 1
				changed = true
			}
		case 'u':
			if ctrl {
				// Ctrl-U clears to the start of the line, as in a shell.
				st := line_start(buf[:], caret^)
				if caret^ > st {
					remove_range(buf, st, caret^)
					caret^ = st
					changed = true
				}
			}
		case 'a':
			if ctrl {
				caret^ = line_start(buf[:], caret^)
			}
		case 'e':
			if ctrl {
				caret^ = line_end(buf[:], caret^)
			}
		}
	}
	caret^ = clamp(caret^, 0, len(buf))
	return
}

rune_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && (b[i] & 0xc0) == 0x80 {
		i -= 1
	}
	return max(1, at - i)
}

rune_forward :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && (b[i] & 0xc0) == 0x80 {
		i += 1
	}
	return min(i, len(b)) - at
}

line_start :: proc(b: []u8, at: int) -> int {
	i := clamp(at, 0, len(b))
	for i > 0 && b[i - 1] != '\n' {
		i -= 1
	}
	return i
}

line_end :: proc(b: []u8, at: int) -> int {
	i := clamp(at, 0, len(b))
	for i < len(b) && b[i] != '\n' {
		i += 1
	}
	return i
}

move_line :: proc(b: []u8, at: int, dir: int) -> int {
	st := line_start(b, at)
	col := at - st
	if dir < 0 {
		if st == 0 {
			return 0
		}
		prev_start := line_start(b, st - 1)
		return min(prev_start + col, st - 1)
	}
	en := line_end(b, at)
	if en >= len(b) {
		return len(b)
	}
	next_end := line_end(b, en + 1)
	return min(en + 1 + col, next_end)
}

word_left :: proc(b: []u8, at: int) -> int {
	i := clamp(at, 0, len(b))
	for i > 0 && is_word_sep(b[i - 1]) {
		i -= 1
	}
	for i > 0 && !is_word_sep(b[i - 1]) {
		i -= 1
	}
	return i
}

word_right :: proc(b: []u8, at: int) -> int {
	i := clamp(at, 0, len(b))
	for i < len(b) && !is_word_sep(b[i]) {
		i += 1
	}
	for i < len(b) && is_word_sep(b[i]) {
		i += 1
	}
	return i
}

is_word_sep :: proc(c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\t' || c == ',' || c == '.' || c == '-'
}
