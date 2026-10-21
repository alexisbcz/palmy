package main

// The command-line front end of the music player.
//
// What the window knows about a track, the command line knows the same way:
// `library` is `scan_dir` / `scan_library`, the readers the playlist is built
// from; `probe` is `probe_file`, the ffprobe reader behind the tags and the
// status bar; `analyze` is the analysis the waveform strip and the spectrum are
// drawn from — `analysis_start`, then `peaks` and `spectrum` over the decoded
// samples. None of it is reimplemented here.
//
// Every command reads files and changes nothing, apart from `shot`, which
// writes the PNG it is given. Two things are absent on purpose:
//
//   * playback. Playing a track from a command would put sound on somebody's
//     speakers with no window to stop it from, and the command would last as
//     long as the album. The transport stays in the window.
//   * recording. This is a player; nothing in it opens a source, and the
//     self-test asserts that no command here so much as starts pw-cat.
//
// The old spellings keep working (main.odin): `audio FILE|DIR` opens the
// window there, `--shot OUT [SECONDS] [KEYS]` renders it, and `--gap-test A B`
// measures a track boundary.

import "core:math"
import "core:os"
import "core:time"
import kit "kit:."
import sc "shadcn:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "library",
		summary = "the audio files in a folder, or in the library the window opens on",
		effect = .Read,
		args = {{name = "dir", kind = .Path, help = "a folder; the library (~/Music, ~/Downloads, $PALMY_MEDIA_DIR, here) by default"}},
		flags = {{name = "probe", kind = .Bool, help = "read each file's tags and duration too (one ffprobe per file)"}},
		out = LIBRARY_FIELDS,
		examples = {"audio library --json", "audio library ~/Music --probe"},
		run = cmd_library,
	},
	{
		verb = "probe",
		summary = "a file's tags, duration and stream, as ffprobe reads them",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "an audio file", required = true}},
		out = PROBE_FIELDS,
		examples = {"audio probe song.mp3 --json"},
		run = cmd_probe,
	},
	{
		verb = "analyze",
		summary = "decode a file and print the waveform envelope and the spectrum the window draws",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "an audio file", required = true}},
		flags = {
			{name = "columns", kind = .Int, help = "how many columns of peak envelope", def = "64"},
			{name = "at", kind = .Float, help = "where the spectrum is taken, in seconds", def = "0"},
		},
		out = ANALYZE_FIELDS,
		examples = {"audio analyze song.mp3 --at 30 --json"},
		run = cmd_analyze,
	},
	{
		verb = "shot",
		summary = "render the window offscreen to a PNG, without playing anything",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, help = "the PNG to write", required = true}},
		flags = {
			{name = "dir", kind = .Path, help = "the folder to show; the library by default"},
			{name = "select", kind = .Int, help = "the row to select", def = "0"},
		},
		out = {{name = "path", kind = .String, help = "the file written"}, {name = "tracks", kind = .Int}},
		examples = {"audio shot /tmp/audio.png", "audio shot /tmp/audio.png --dir ~/Music --select 2"},
		run = cmd_shot,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "audio",
			summary    = "a music player: the library, tags, and the picture of the sound",
			gui        = true,
			takes_path = true,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Everything here reads files. There is no play verb — sound on the speakers
belongs to the window, where it can be stopped — and nothing here records.
Output devices and volume are the mixer's: palm mixer.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

LIBRARY_FIELDS := []kit.Field {
	{
		name = "tracks",
		kind = .Array,
		of = {
			{name = "path", kind = .String},
			{name = "name", kind = .String},
			{name = "dir", kind = .String},
			{name = "size", kind = .Int, help = "bytes"},
			{name = "title", kind = .String, help = "with --probe; the file name otherwise", opt = true},
			{name = "artist", kind = .String, opt = true},
			{name = "duration", kind = .Float, help = "seconds, with --probe", opt = true},
		},
	},
	{name = "count", kind = .Int},
}

PROBE_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "duration", kind = .Float, help = "seconds"},
	{name = "size", kind = .Int},
	{name = "bitrate", kind = .Int},
	{name = "container", kind = .String},
	{name = "codec", kind = .String},
	{name = "channels", kind = .Int},
	{name = "sample_rate", kind = .Int},
	{name = "title", kind = .String},
	{name = "artist", kind = .String},
	{name = "album", kind = .String},
	{name = "date", kind = .String},
	{name = "has_cover", kind = .Bool},
	{name = "has_video", kind = .Bool},
	{name = "chapters", kind = .Array, help = "the container's chapter marks, in time order", of = {
		{name = "start", kind = .Float, help = "seconds"},
		{name = "end", kind = .Float, help = "seconds"},
		{name = "title", kind = .String, help = "\"Chapter N\" when the file gives none"},
	}},
}

ANALYZE_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "samples", kind = .Int, help = "of the 16 kHz mono copy the envelope is drawn from"},
	{name = "seconds", kind = .Float},
	{name = "decode_ms", kind = .Float},
	{name = "gain", kind = .Float, help = "how far the envelope was lifted to fill the strip"},
	{name = "peaks", kind = .Array, of = {{kind = .Float}}, help = "0..1, one per column"},
	{name = "spectrum", kind = .Array, of = {{kind = .Float}}, help = "the analyser's bars at --at, low to high"},
	{name = "loudest_bar", kind = .Int},
	{name = "loudest_hz", kind = .Float, help = "the centre of the loudest bar"},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

cli_selftest :: proc() -> int {
	run_selftest()
	return failures == 0 ? 0 : 1
}

@(private = "file")
cmd_library :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	list: []Track
	if dir != "" {
		abs := absolute(dir)
		fi, err := os.stat(abs, context.temp_allocator)
		if err != nil || fi.type != .Directory {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not a folder", dir)
		}
		list = scan_dir(abs)
	} else {
		list = scan_library()
	}
	want_probe := kit.cli_bool(c, "probe")
	if want_probe && !kit.has_tool("ffprobe") {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffprobe is not installed (package ffmpeg)")
	}
	arr := kit.jarr()
	for &t in list {
		o := kit.jobj()
		kit.jset_str(o, "path", t.path)
		kit.jset_str(o, "name", t.name)
		kit.jset_str(o, "dir", t.dir)
		kit.jset_i64(o, "size", t.size)
		if want_probe {
			ensure_probed(&t)
			kit.jset_str(o, "title", track_title(&t))
			kit.jset_str(o, "artist", track_artist(&t))
			kit.jset_num(o, "duration", t.m.duration)
		}
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "tracks", arr)
	kit.jset_int(c.out, "count", len(list))
	return kit.EXIT_OK
}

// need_file refuses a path that is not a readable file (3), and a missing
// ffmpeg (6). It returns the code, EXIT_OK when the command may go on.
@(private = "file")
need_file :: proc(c: ^kit.Call, path: string, tool: string) -> int {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type == .Directory {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no audio file at %s", path)
	}
	if !kit.has_tool(tool) {
		return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "%s is not installed (package ffmpeg)", tool)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_probe :: proc(c: ^kit.Call) -> int {
	path := absolute(kit.cli_str(c, "file"))
	if code := need_file(c, path, "ffprobe"); code != kit.EXIT_OK {
		return code
	}
	m := probe_file(path)
	if !m.ok {
		return kit.cli_fail(c, kit.EXIT_FAILED, m.err == "" ? "ffprobe could not read it" : m.err)
	}
	kit.jset_str(c.out, "path", m.path)
	kit.jset_num(c.out, "duration", m.duration)
	kit.jset_i64(c.out, "size", m.size)
	kit.jset_i64(c.out, "bitrate", m.bitrate)
	kit.jset_str(c.out, "container", m.container)
	kit.jset_str(c.out, "codec", m.acodec)
	kit.jset_int(c.out, "channels", m.channels)
	kit.jset_int(c.out, "sample_rate", m.sample_rate)
	kit.jset_str(c.out, "title", m.title)
	kit.jset_str(c.out, "artist", m.artist)
	kit.jset_str(c.out, "album", m.album)
	kit.jset_str(c.out, "date", m.date)
	kit.jset_bool(c.out, "has_cover", m.has_cover)
	kit.jset_bool(c.out, "has_video", m.has_video)
	ca := kit.jarr()
	for ch in m.chapters {
		co := kit.jobj()
		kit.jset_num(co, "start", ch.start)
		kit.jset_num(co, "end", ch.end)
		kit.jset_str(co, "title", ch.title)
		kit.jpush(ca, co)
	}
	kit.jset(c.out, "chapters", ca)
	return kit.EXIT_OK
}

// bar_hz is the centre of analyser bar `k`, on the same logarithmic scale
// from 40 Hz to Nyquist that `spectrum` folds the transform into.
bar_hz :: proc(k: int) -> f64 {
	return math.sqrt(f64(bar_edge_hz(k)) * f64(bar_edge_hz(k + 1)))
}

@(private = "file")
cmd_analyze :: proc(c: ^kit.Call) -> int {
	path := absolute(kit.cli_str(c, "file"))
	if code := need_file(c, path, "ffmpeg"); code != kit.EXIT_OK {
		return code
	}
	cols := clamp(kit.cli_int(c, "columns", 64), 1, 4096)
	at := max(kit.cli_f64(c, "at", 0), 0)

	a: Analysis
	analysis_start(&a, path)
	defer analysis_stop(&a)
	ready, ok, ms, samples := false, false, f64(0), 0
	deadline := time.tick_now()
	for time.tick_since(deadline) < 120 * time.Second {
		ready, ok, ms, samples = analysis_ready(&a)
		if ready {break}
		time.sleep(5 * time.Millisecond)
	}
	if !ready {
		return kit.cli_fail(c, kit.EXIT_FAILED, "the decode did not finish in two minutes")
	}
	if !ok || samples == 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "ffmpeg could not decode %s", path)
	}

	env := make([]f32, cols, context.temp_allocator)
	gain := peaks(&a, env)
	bars: [BARS]f32
	spectrum(&a, at, bars[:])
	loudest := 0
	for k in 0 ..< BARS {
		if bars[k] > bars[loudest] {loudest = k}
	}

	kit.jset_str(c.out, "path", path)
	kit.jset_int(c.out, "samples", samples)
	kit.jset_num(c.out, "seconds", f64(samples) / f64(WAVE_RATE))
	kit.jset_num(c.out, "decode_ms", ms)
	kit.jset_num(c.out, "gain", f64(gain))
	pa := kit.jarr()
	for v in env {
		kit.jpush(pa, kit.jnum(f64(v)))
	}
	kit.jset(c.out, "peaks", pa)
	sa := kit.jarr()
	for v in bars {
		kit.jpush(sa, kit.jnum(f64(v)))
	}
	kit.jset(c.out, "spectrum", sa)
	kit.jset_int(c.out, "loudest_bar", loudest)
	kit.jset_num(c.out, "loudest_hz", bar_hz(loudest))
	return kit.EXIT_OK
}

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	out := kit.cli_str(c, "path")
	kit.jset_str(c.out, "path", out)
	dir := kit.cli_str(c, "dir")
	if dir != "" && !os.is_dir(absolute(dir)) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not a folder", dir)
	}
	if c.dry_run {
		kit.jset_int(c.out, "tracks", 0)
		return kit.EXIT_OK
	}

	// The window's own state, built as main builds it — minus the autoplay.
	sc.register_shadcn_theme()
	register_dark_theme()
	st := St {
		cur       = -1,
		cover_for = -1,
		wave_for  = -1,
		gain      = 1,
		an_for    = {-1, -1},
	}
	engine_init(&st.e)
	defer engine_stop(&st.e)
	defer analysis_stop(&st.an[0])
	defer analysis_stop(&st.an[1])
	st.list = dir != "" ? scan_dir(absolute(dir)) : scan_library()
	rebuild_order(&st)
	st.sel = clamp(kit.cli_int(c, "select", 0), 0, max(0, len(st.list) - 1))

	os.remove(out)
	run_shot(&st, out, 1.2, "")
	if !os.exists(out) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", out)
	}
	kit.jset_int(c.out, "tracks", len(st.list))
	return kit.EXIT_OK
}
