package main

// The command-line front end of Captions.
//
// Nothing here re-implements the application. Every command builds the same
// App_State the window builds (`state_init`) and drives it through the same
// procedures a key press does: `open_path` to read a file (which starts the
// import job for media, or `load_subtitle` for an .srt/.vtt), `begin_transcribe`,
// `export_now`, `begin_burn` and `wrap_all`. Jobs run on the same worker thread
// as in the window; where the window polls `job_collect` once a frame, the
// command line polls it in `wait_job`, and both land the result through
// `apply_job_result`. A failure is whatever the model put in `m.status`, so the
// window's status bar and the command's error detail are the same sentence.
//
// What a command touches:
//
//   - reads (`tools`, `probe`, `show`, `lint`) open only the file named and
//     write nothing; `probe` runs ffprobe on it.
//   - `transcribe` and `burn` import the media, which writes the 16 kHz copy
//     and the waveform into the cache ($XDG_CACHE_HOME/palmy-captions), as
//     the window does, and then write the output named (or a sibling of the
//     source, never the source itself).
//   - `convert`, `shift` and `wrap` write one caption file.
//
// Media is only ever read from a file. Nothing here opens a camera or a
// microphone; the kit's guard would refuse it if anything tried.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "tools",
		summary = "which of ffmpeg, ffprobe, ffplay and whisper-cli are here, and the whisper models found",
		effect = .Read,
		out = TOOLS_FIELDS,
		examples = {"captions tools --json"},
		run = cmd_tools,
	},
	{
		verb = "probe",
		summary = "a media file's duration and streams, and whether it can be transcribed",
		effect = .Read,
		args = {{name = "media", kind = .Path, help = "a video or audio file", required = true}},
		out = PROBE_FIELDS,
		examples = {"captions probe talk.mp4 --json"},
		run = cmd_probe,
	},
	{
		verb = "show",
		summary = "every caption in an .srt or .vtt file, with its reading speed and warnings",
		effect = .Read,
		args = {{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true}},
		out = SHOW_FIELDS,
		examples = {"captions show talk.srt --json"},
		run = cmd_show,
	},
	{
		verb = "lint",
		summary = "only the problems: lines too long, too fast, too short, overlapping",
		effect = .Read,
		args = {{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true}},
		out = LINT_FIELDS,
		examples = {"captions lint talk.srt --json"},
		run = cmd_lint,
	},
	{
		verb = "convert",
		summary = "write a caption file in another format",
		effect = .Mutate,
		args = {{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true}},
		flags = {
			{name = "to", kind = .Enum, values = {"srt", "vtt", "ass", "txt"}, def = "vtt", help = "the format to write"},
			{name = "out", kind = .Path, help = "where to write it; default: beside the input with the new extension"},
		},
		out = WROTE_FIELDS,
		examples = {"captions convert talk.srt --to vtt --json", "captions convert talk.vtt --to srt --out /tmp/talk.srt --json"},
		run = cmd_convert,
	},
	{
		verb = "shift",
		summary = "move every caption by the same number of seconds (negative is earlier); in place unless --out",
		effect = .Mutate,
		args = {{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true}},
		flags = {
			{name = "by", kind = .Float, help = "seconds to add to every timing", required = true},
			{name = "out", kind = .Path, help = "write here instead of over the input"},
		},
		out = WROTE_FIELDS,
		examples = {"captions shift talk.srt --by 1.5 --json", "captions shift talk.srt --by -0.25 --out /tmp/talk.srt --json"},
		run = cmd_shift,
	},
	{
		verb = "wrap",
		summary = "re-break every caption at the line limit (42 characters, two lines); in place unless --out",
		effect = .Mutate,
		args = {{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true}},
		flags = {{name = "out", kind = .Path, help = "write here instead of over the input"}},
		out = WROTE_FIELDS,
		examples = {"captions wrap talk.srt --json"},
		run = cmd_wrap,
	},
	{
		verb = "transcribe",
		summary = "speech to captions with whisper.cpp, locally; writes a caption file beside the media",
		effect = .Mutate,
		args = {{name = "media", kind = .Path, help = "a video or audio file", required = true}},
		flags = {
			{name = "model", kind = .String, help = "a model's name (ggml-base.en) or path; default: the English-only one"},
			{name = "lang", kind = .String, help = "a language code, or auto; default en"},
			{name = "threads", kind = .Int, help = "whisper threads", def = "4"},
			{name = "format", kind = .Enum, values = {"srt", "vtt", "ass", "txt"}, def = "srt", help = "what to write"},
			{name = "out", kind = .Path, help = "where to write it; default: beside the media"},
		},
		out = TRANSCRIBE_FIELDS,
		examples = {"captions transcribe talk.mp4 --json", "captions transcribe interview.wav --lang fr --format vtt --json"},
		run = cmd_transcribe,
	},
	{
		verb = "burn",
		summary = "burn captions into a copy of a video (the source is never overwritten)",
		effect = .Mutate,
		args = {
			{name = "video", kind = .Path, help = "the video", required = true},
			{name = "captions", kind = .Path, help = "an .srt or .vtt file", required = true},
		},
		flags = {{name = "out", kind = .Path, help = "the new video; default: <video>.captioned.mp4"}},
		out = BURN_FIELDS,
		examples = {"captions burn talk.mp4 talk.srt --json", "captions burn talk.mp4 talk.srt --out /tmp/talk-captioned.mp4 --json"},
		run = cmd_burn,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "captions",
			summary    = "local speech to text with whisper.cpp, and a caption editor around it",
			gui        = true,
			takes_path = true, // `captions talk.mp4` opens it in the window
			selftest   = selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command the window opens; a bare file opens in it. Everything runs
on this machine: ffprobe and ffmpeg read the media, whisper-cli transcribes
against weights already on the disk (captions tools lists where it looked),
and nothing is uploaded. A missing tool or model answers 6, unavailable.

Media is only ever read from a file. The camera and the microphone are never
opened. The source is never written over: an output path that names it is
refused.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

TOOLS_FIELDS := []kit.Field {
	{name = "ffmpeg", kind = .Bool},
	{name = "ffprobe", kind = .Bool},
	{name = "ffplay", kind = .Bool, help = "playback only; the command line never plays anything"},
	{name = "whisper", kind = .Bool, help = "whisper-cli on PATH"},
	{
		name = "models",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "path", kind = .String},
			{name = "bytes", kind = .Int},
			{name = "multilingual", kind = .Bool},
		},
	},
	{name = "vad_model", kind = .String, help = "the voice-activity model, \"\" when there is none"},
	{name = "searched", kind = .Array, of = {{kind = .String}}, help = "where models were looked for"},
	{name = "can_transcribe", kind = .Bool},
}

PROBE_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "duration", kind = .Float, help = "seconds"},
	{name = "has_video", kind = .Bool},
	{name = "has_audio", kind = .Bool},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "vcodec", kind = .String},
	{name = "acodec", kind = .String},
	{name = "transcribable", kind = .Bool},
	{name = "problem", kind = .String, opt = true, help = "why it cannot be transcribed"},
}

SHOW_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "count", kind = .Int},
	{name = "duration", kind = .Float, help = "the last caption's end, in seconds"},
	{name = "problems", kind = .Int, help = "captions with at least one warning"},
	{
		name = "captions",
		kind = .Array,
		of = {
			{name = "index", kind = .Int, help = "1-based, as SRT numbers them"},
			{name = "start", kind = .Float},
			{name = "end", kind = .Float},
			{name = "text", kind = .String},
			{name = "cps", kind = .Float, help = "reading speed, characters per second"},
			{name = "lines", kind = .Int},
			{name = "warnings", kind = .Array, of = {{kind = .String}}},
		},
	},
}

LINT_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "count", kind = .Int},
	{name = "ok", kind = .Bool, help = "no warnings at all"},
	{
		name = "problems",
		kind = .Array,
		of = {
			{name = "index", kind = .Int},
			{name = "start", kind = .Float},
			{name = "warning", kind = .String, help = "empty, long_line, too_many_lines, too_fast, too_short, too_long, overlap, tight_gap"},
			{name = "detail", kind = .String},
		},
	},
}

WROTE_FIELDS := []kit.Field {
	{name = "from", kind = .String},
	{name = "path", kind = .String, help = "the file written"},
	{name = "format", kind = .String},
	{name = "count", kind = .Int},
	{name = "shifted_by", kind = .Float, opt = true, help = "shift: the amount applied, after clamping at zero"},
	{name = "rewrapped", kind = .Int, opt = true, help = "wrap: captions whose text changed"},
}

TRANSCRIBE_FIELDS := []kit.Field {
	{name = "media", kind = .String},
	{name = "path", kind = .String, help = "the caption file written"},
	{name = "format", kind = .String},
	{name = "model", kind = .String},
	{name = "language", kind = .String},
	{name = "count", kind = .Int},
	{name = "duration", kind = .Float, help = "media seconds"},
	{name = "seconds", kind = .Float, opt = true, help = "how long whisper took"},
	{name = "realtime", kind = .Float, opt = true, help = "media seconds per second of work"},
}

BURN_FIELDS := []kit.Field {
	{name = "video", kind = .String},
	{name = "captions", kind = .String},
	{name = "path", kind = .String, help = "the new video"},
	{name = "count", kind = .Int},
	{name = "seconds", kind = .Float, opt = true},
}

// ---------------------------------------------------------------------------
// The model, built the way the window builds it
// ---------------------------------------------------------------------------

// cli_state is the window's own App_State. The status line is not echoed to
// stderr: a failure is reported once, as the command's result.
@(private = "file")
cli_state :: proc() -> ^App_State {
	status_echo = false
	m := new(App_State)
	state_init(m)
	return m
}

// wait_job is the command line's frame loop: poll the job the way the window
// does once a frame, and land its result through the same procedure.
@(private = "file")
wait_job :: proc(c: ^kit.Call, m: ^App_State) {
	last := Stage.Idle
	for job_busy() {
		if res, got := job_collect(); got {
			apply_job_result(m, res)
			return
		}
		if st := job_stage(); st != last {
			kit.cli_trace(c, "captions: %s", stage_text(st))
			last = st
		}
		time.sleep(20 * time.Millisecond)
	}
}

@(private = "file")
not_found :: proc(c: ^kit.Call, path: string) -> int {
	code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no such file: %s", path)
	kit.cli_err_field(c, "path", path)
	return code
}

// load_captions_cli opens a caption file through `open_path`, exactly as
// typing its path into the window's import field does.
@(private = "file")
load_captions_cli :: proc(c: ^kit.Call, m: ^App_State, path: string) -> (code: int, ok: bool) {
	if !os.exists(path) {
		return not_found(c, path), false
	}
	if !is_subtitle_path(path) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is not an .srt or .vtt file", path), false
	}
	open_path(m, path)
	if m.status_bad || !m.transcribed {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status), false
	}
	return kit.EXIT_OK, true
}

@(private = "file")
format_of :: proc(word: string) -> Format {
	switch strings.to_lower(word, context.temp_allocator) {
	case "vtt", ".vtt":
		return .VTT
	case "ass", ".ass":
		return .ASS
	case "txt", ".txt":
		return .TXT
	}
	return .SRT
}

@(private = "file")
format_word :: proc(f: Format) -> string {
	return format_ext(f)
}

// write_out sets the export fields the window's Export pane sets and calls
// `export_now`, the procedure its button calls.
@(private = "file")
write_out :: proc(c: ^kit.Call, m: ^App_State, path: string, f: Format) -> (code: int, ok: bool) {
	clear(&m.out_buf)
	append(&m.out_buf, path)
	m.fmt_i = f
	export_now(m)
	if m.status_bad {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status), false
	}
	return kit.EXIT_OK, true
}

@(private = "file")
wrote :: proc(c: ^kit.Call, from, path: string, f: Format, n: int) {
	kit.jset_str(c.out, "from", from)
	kit.jset_str(c.out, "path", path)
	kit.jset_str(c.out, "format", format_word(f))
	kit.jset_int(c.out, "count", n)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_tools :: proc(c: ^kit.Call) -> int {
	m := cli_state()
	kit.jset_bool(c.out, "ffmpeg", m.tools.ffmpeg)
	kit.jset_bool(c.out, "ffprobe", m.tools.ffprobe)
	kit.jset_bool(c.out, "ffplay", m.tools.ffplay)
	kit.jset_bool(c.out, "whisper", m.tools.whisper)
	arr := kit.jarr()
	for mm in m.models {
		o := kit.jobj()
		kit.jset_str(o, "name", mm.name)
		kit.jset_str(o, "path", mm.path)
		kit.jset_int(o, "bytes", int(mm.bytes))
		kit.jset_bool(o, "multilingual", mm.multilingual)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "models", arr)
	kit.jset_str(c.out, "vad_model", m.has_vad ? m.vad_model : "")
	dirs := kit.jarr()
	for d in MODEL_DIRS {
		kit.jpush(dirs, kit.jstr(expand_path(d)))
	}
	kit.jset(c.out, "searched", dirs)
	kit.jset_bool(c.out, "can_transcribe", m.tools.whisper && m.tools.ffmpeg && m.tools.ffprobe && len(m.models) > 0)
	return kit.EXIT_OK
}

@(private = "file")
cmd_probe :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "media")
	if !os.exists(path) {
		return not_found(c, path)
	}
	if !kit.has_tool("ffprobe") {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffprobe is not installed")
	}
	// The procedure the import job's first stage calls.
	info, err := probe(path, context.allocator)
	if info.duration <= 0 {
		return kit.cli_fail(c, kit.EXIT_FAILED, err != "" ? err : "not a media file")
	}
	kit.jset_str(c.out, "path", normal_path(path))
	kit.jset_num(c.out, "duration", info.duration)
	kit.jset_bool(c.out, "has_video", info.has_video)
	kit.jset_bool(c.out, "has_audio", info.has_audio)
	kit.jset_int(c.out, "width", info.width)
	kit.jset_int(c.out, "height", info.height)
	kit.jset_str(c.out, "vcodec", info.vcodec)
	kit.jset_str(c.out, "acodec", info.acodec)
	kit.jset_bool(c.out, "transcribable", err == "")
	if err != "" {
		kit.jset_str(c.out, "problem", err)
	}
	return kit.EXIT_OK
}

@(private = "file")
warn_names :: proc(w: Warns, limits: Limits) -> ^kit.Json {
	arr := kit.jarr()
	for k in Warn_Kind {
		if k in w {
			kit.jpush(arr, kit.jstr(warn_text(k, limits)))
		}
	}
	return arr
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "captions")
	m := cli_state()
	if code, ok := load_captions_cli(c, m, path); !ok {
		return code
	}
	arr := kit.jarr()
	problems := 0
	last := 0.0
	for s, i in m.segs {
		w := seg_warnings(m.segs[:], i, m.limits)
		if w != {} {
			problems += 1
		}
		_, lines := longest_line(seg_text(s))
		o := kit.jobj()
		kit.jset_int(o, "index", i + 1)
		kit.jset_num(o, "start", s.start)
		kit.jset_num(o, "end", s.end)
		kit.jset_str(o, "text", seg_text(s))
		kit.jset_num(o, "cps", cps(s))
		kit.jset_int(o, "lines", lines)
		kit.jset(o, "warnings", warn_names(w, m.limits))
		kit.jpush(arr, o)
		last = max(last, s.end)
	}
	kit.jset_str(c.out, "path", normal_path(path))
	kit.jset_int(c.out, "count", len(m.segs))
	kit.jset_num(c.out, "duration", last)
	kit.jset_int(c.out, "problems", problems)
	kit.jset(c.out, "captions", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_lint :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "captions")
	m := cli_state()
	if code, ok := load_captions_cli(c, m, path); !ok {
		return code
	}
	arr := kit.jarr()
	for s, i in m.segs {
		w := seg_warnings(m.segs[:], i, m.limits)
		for k in Warn_Kind {
			if k not_in w {
				continue
			}
			o := kit.jobj()
			kit.jset_int(o, "index", i + 1)
			kit.jset_num(o, "start", s.start)
			kit.jset_str(o, "warning", strings.to_lower(fmt.tprintf("%v", k), context.temp_allocator))
			kit.jset_str(o, "detail", warn_text(k, m.limits))
			kit.jpush(arr, o)
		}
	}
	kit.jset_str(c.out, "path", normal_path(path))
	kit.jset_int(c.out, "count", len(m.segs))
	kit.jset_bool(c.out, "ok", kit.jlen(arr) == 0)
	kit.jset(c.out, "problems", arr)
	return kit.EXIT_OK
}

// target is where a rewrite goes: --out, or else the input itself.
@(private = "file")
target :: proc(c: ^kit.Call, input: string) -> (path: string, f: Format) {
	path = kit.cli_has(c, "out") ? kit.cli_str(c, "out") : input
	return path, format_of(filepath.ext(path))
}

@(private = "file")
cmd_convert :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "captions")
	f := format_of(kit.cli_str(c, "to"))
	out := kit.cli_str(c, "out")
	if out == "" {
		out = default_output(path, "", format_ext(f))
	}
	if same_file(out, path) {
		code := kit.cli_failf(c, kit.EXIT_USAGE, "converting %s to itself would overwrite it; pass --out", path)
		kit.cli_err_field(c, "path", path)
		return code
	}
	m := cli_state()
	if code, ok := load_captions_cli(c, m, path); !ok {
		return code
	}
	if !c.dry_run {
		if code, ok := write_out(c, m, out, f); !ok {
			return code
		}
	}
	wrote(c, normal_path(path), normal_path(out), f, len(m.segs))
	return kit.EXIT_OK
}

@(private = "file")
cmd_shift :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "captions")
	m := cli_state()
	if code, ok := load_captions_cli(c, m, path); !ok {
		return code
	}
	sort_segs(&m.segs)
	applied := shift_all(&m.segs, kit.cli_f64(c, "by"))
	m.dirty = true
	out, f := target(c, path)
	if !c.dry_run {
		if code, ok := write_out(c, m, out, f); !ok {
			return code
		}
	}
	wrote(c, normal_path(path), normal_path(out), f, len(m.segs))
	kit.jset_num(c.out, "shifted_by", applied)
	return kit.EXIT_OK
}

@(private = "file")
cmd_wrap :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "captions")
	m := cli_state()
	if code, ok := load_captions_cli(c, m, path); !ok {
		return code
	}
	changed := wrap_all(m)
	out, f := target(c, path)
	if !c.dry_run {
		if code, ok := write_out(c, m, out, f); !ok {
			return code
		}
	}
	wrote(c, normal_path(path), normal_path(out), f, len(m.segs))
	kit.jset_int(c.out, "rewrapped", changed)
	return kit.EXIT_OK
}

// import_media opens a media file through `open_path` and waits for the
// import job, which is what the window does when a file is chosen.
@(private = "file")
import_media :: proc(c: ^kit.Call, m: ^App_State, path: string) -> (code: int, ok: bool) {
	open_path(m, path)
	if m.status_bad {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status), false
	}
	wait_job(c, m)
	if !m.loaded {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status), false
	}
	return kit.EXIT_OK, true
}

@(private = "file")
cmd_transcribe :: proc(c: ^kit.Call) -> int {
	media := kit.cli_str(c, "media")
	if !os.exists(media) {
		return not_found(c, media)
	}
	if !is_media_path(media) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is not a media file this reads", media)
	}
	m := cli_state()
	switch {
	case !m.tools.ffmpeg || !m.tools.ffprobe:
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffmpeg and ffprobe are required to read media")
	case !m.tools.whisper:
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "whisper-cli is not on PATH; install whisper.cpp to transcribe")
	case len(m.models) == 0:
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "no whisper model on this disk; `captions tools` lists where it looked")
	}

	// The same three settings the Transcribe pane cycles through.
	if want := kit.cli_str(c, "model"); want != "" {
		found := -1
		for mm, i in m.models {
			if mm.name == want || mm.path == want || filepath.base(mm.path) == want {
				found = i
			}
		}
		if found < 0 {
			code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no model called %q", want)
			kit.cli_err_field(c, "model", want)
			return code
		}
		m.model_i = found
	}
	if lang := kit.cli_str(c, "lang"); lang != "" {
		found := -1
		for l, i in LANGUAGES {
			if l.code == lang {
				found = i
			}
		}
		if found < 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "unknown language %q", lang)
		}
		m.lang_i = found
	}
	m.threads = max(1, kit.cli_int(c, "threads", 4))
	f := format_of(kit.cli_str(c, "format"))
	out := kit.cli_str(c, "out")
	if out == "" {
		out = default_output(normal_path(media), "", format_ext(f))
	}
	if same_file(out, media) {
		return kit.cli_fail(c, kit.EXIT_USAGE, "that path is the media file itself")
	}
	model := m.models[m.model_i]
	kit.jset_str(c.out, "media", normal_path(media))
	kit.jset_str(c.out, "path", normal_path(out))
	kit.jset_str(c.out, "format", format_word(f))
	kit.jset_str(c.out, "model", model.name)
	if c.dry_run {
		kit.jset_str(c.out, "language", LANGUAGES[m.lang_i].code)
		kit.jset_int(c.out, "count", 0)
		kit.jset_num(c.out, "duration", 0)
		return kit.EXIT_OK
	}

	if code, ok := import_media(c, m, media); !ok {
		return code
	}
	begin_transcribe(m)
	if m.status_bad {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status)
	}
	wait_job(c, m)
	if m.status_bad || !m.transcribed {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status)
	}
	if code, ok := write_out(c, m, out, f); !ok {
		return code
	}
	kit.jset_str(c.out, "language", m.heard_lang != "" ? m.heard_lang : LANGUAGES[m.lang_i].code)
	kit.jset_int(c.out, "count", len(m.segs))
	kit.jset_num(c.out, "duration", m.info.duration)
	kit.jset_num(c.out, "seconds", m.decode_sec)
	kit.jset_num(c.out, "realtime", m.rtf)
	return kit.EXIT_OK
}

@(private = "file")
cmd_burn :: proc(c: ^kit.Call) -> int {
	video := kit.cli_str(c, "video")
	caps := kit.cli_str(c, "captions")
	if !os.exists(video) {
		return not_found(c, video)
	}
	if !os.exists(caps) {
		return not_found(c, caps)
	}
	m := cli_state()
	if !m.tools.ffmpeg || !m.tools.ffprobe {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffmpeg and ffprobe are required")
	}
	// The same default the window's begin_burn takes, computed here so the
	// result can name it.
	out := kit.cli_str(c, "out")
	if out == "" || is_subtitle_path(out) {
		out = default_output(normal_path(video), ".captioned", "mp4")
	}
	if same_file(out, video) {
		return kit.cli_fail(c, kit.EXIT_USAGE, "the output would overwrite the source")
	}
	if code, ok := import_media(c, m, video); !ok {
		return code
	}
	if !m.info.has_video {
		return kit.cli_fail(c, kit.EXIT_USAGE, "burn-in needs a video file")
	}
	if code, ok := load_captions_cli(c, m, caps); !ok {
		return code
	}
	kit.jset_str(c.out, "video", normal_path(video))
	kit.jset_str(c.out, "captions", normal_path(caps))
	kit.jset_str(c.out, "path", normal_path(out))
	kit.jset_int(c.out, "count", len(m.segs))
	if c.dry_run {
		return kit.EXIT_OK
	}
	clear(&m.out_buf)
	append(&m.out_buf, out)
	t0 := time.tick_now()
	begin_burn(m)
	if m.status_bad {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status)
	}
	wait_job(c, m)
	if m.status_bad || !os.exists(out) {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.status)
	}
	kit.jset_num(c.out, "seconds", time.duration_seconds(time.tick_since(t0)))
	return kit.EXIT_OK
}
