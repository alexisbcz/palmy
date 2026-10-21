package main

// The command-line front end of videoedit.
//
// The CLI works on project files (.vep) — the same format the window saves
// with Ctrl-S and opens with Ctrl-O — and nothing below re-implements an edit.
// Every verb loads the project with `project_load`, applies the model
// procedure the window's key for it calls (`split_at` for `s`, `ripple_delete`
// for `d`, `trim_in`/`trim_out` for q/w/e/r, `move_clip` for h/l/m,
// `toggle_dissolve` for `x`, `insert_title` for `t`, `load_captions` for `c`,
// `place_clip` for a/n), and writes it back with `project_save`. Importing
// goes through `import_media`, the importer thread's own body, and exporting
// through `export_submit`, which is what `p`/`P` call; the CLI then waits on
// the exporter where the window draws its progress bar. So a project edited
// here opens in the window as if the edits had been typed there.
//
// Clip ids are positional. `project_parse` numbers clips in file order on
// every load, so an id names a clip only until the next change; each
// mutating command prints the whole project afterwards, which is where the new
// ids are.
//
// What does not exist here: playback, scrubbing, the preview, undo (its
// history lives in the window's memory, not in the file) and the live mixer.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
PROJECT_ARG :: kit.Param{name = "project", kind = .Path, help = "a .vep project file", required = true}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "probe",
		summary = "what ffprobe says about a media file: duration, size, frame rate, codecs, streams",
		effect = .Read,
		args = {{name = "media", kind = .Path, help = "a video or audio file", required = true}},
		out = PROBE_FIELDS,
		examples = {"videoedit probe clip.mp4 --json"},
		run = cmd_probe,
	},
	{
		verb = "info",
		summary = "a project: its media bin, every track and clip, captions, length and output size",
		effect = .Read,
		args = {PROJECT_ARG},
		out = PROJECT_FIELDS,
		examples = {"videoedit info demo.vep --json"},
		run = cmd_info,
	},
	{
		verb = "new",
		summary = "write a new project, importing any media given; --layout lays it out as the window does on first run",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "media", kind = .Path, help = "media files to import into the bin", variadic = true}},
		flags = {
			{name = "layout", kind = .Bool, help = "put the first clips on V1 and their sound on A1"},
			{name = "force", kind = .Bool, help = "replace a project file that already exists"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit new demo.vep a.mp4 b.mp4 --layout --json"},
		run = cmd_new,
	},
	{
		verb = "add",
		summary = "import a media file and place it: picture on a video track, sound alongside on A1",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "media", kind = .Path, help = "the video or audio file", required = true}},
		flags = {
			{name = "track", kind = .String, help = "a video track by name (V1) or index", def = "V1"},
			{name = "at", kind = .Float, help = "timeline seconds; omitted, after the track's last clip"},
			{name = "in", kind = .Float, help = "source seconds to start from", def = "0"},
			{name = "out", kind = .Float, help = "source seconds to stop at; omitted, the end of the file"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit add demo.vep c.mp4 --at 4 --in 0.5 --out 2.5 --json"},
		run = cmd_add,
	},
	{
		verb = "split",
		summary = "cut the clip under a time in two (on one track, or on every track with a clip there)",
		effect = .Mutate,
		args = {PROJECT_ARG},
		flags = {
			{name = "at", kind = .Float, help = "timeline seconds", required = true},
			{name = "track", kind = .String, help = "a track by name or index; omitted, every track"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit split demo.vep --at 1.5 --json", "videoedit split demo.vep --at 1.5 --track V1 --json"},
		run = cmd_split,
	},
	{
		verb = "trim",
		summary = "move a clip's in point and/or out point by some seconds (clamped to the source)",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "clip", kind = .Int, help = "a clip id, from info", required = true}},
		flags = {
			{name = "in-by", kind = .Float, help = "seconds to move the in point (negative extends)"},
			{name = "out-by", kind = .Float, help = "seconds to move the out point (negative shortens)"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit trim demo.vep 2 --in-by 0.25 --out-by -0.5 --json"},
		run = cmd_trim,
	},
	{
		verb = "move",
		summary = "slide a clip to a timeline position, optionally onto another track",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "clip", kind = .Int, help = "a clip id, from info", required = true}},
		flags = {
			{name = "to", kind = .Float, help = "the new start, timeline seconds", required = true},
			{name = "track", kind = .String, help = "another track, by name or index"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit move demo.vep 2 --to 3.0 --track V2 --json"},
		run = cmd_move,
	},
	{
		verb = "delete",
		summary = "take a clip off the timeline, leaving a gap, or closing it with --ripple (the media file is untouched)",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "clip", kind = .Int, help = "a clip id, from info", required = true}},
		flags = {{name = "ripple", kind = .Bool, help = "pull the rest of the track back over the gap"}},
		out = PROJECT_FIELDS,
		examples = {"videoedit delete demo.vep 3 --ripple --json"},
		run = cmd_delete,
	},
	{
		verb = "dissolve",
		summary = "make a clip's join a cross-dissolve, or a cut again with --off",
		effect = .Idempotent,
		args = {PROJECT_ARG, {name = "clip", kind = .Int, help = "a clip id, from info", required = true}},
		flags = {{name = "off", kind = .Bool, help = "a hard cut instead"}},
		out = PROJECT_FIELDS,
		examples = {"videoedit dissolve demo.vep 2 --json"},
		run = cmd_dissolve,
	},
	{
		verb = "title",
		summary = "add a title card over the picture",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "text", kind = .String, help = "what it says", required = true}},
		flags = {
			{name = "at", kind = .Float, help = "timeline seconds", def = "0"},
			{name = "length", kind = .Float, help = "seconds on screen", def = "2.5"},
			{name = "track", kind = .String, help = "a video track; omitted, the top one"},
		},
		out = PROJECT_FIELDS,
		examples = {"videoedit title demo.vep \"Opening night\" --at 0.5 --length 2 --json"},
		run = cmd_title,
	},
	{
		verb = "captions",
		summary = "put an SRT, WebVTT or ASS file on the caption track, nudged by --offset",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "file", kind = .Path, help = "the subtitle file", required = true}},
		flags = {{name = "offset", kind = .Float, help = "seconds added to every cue", def = "0"}},
		out = PROJECT_FIELDS,
		examples = {"videoedit captions demo.vep talk.srt --offset -0.2 --json"},
		run = cmd_captions,
	},
	{
		verb = "export",
		summary = "render the timeline to a file with ffmpeg, wait for it, and read the result back",
		effect = .Mutate,
		args = {PROJECT_ARG, {name = "out", kind = .Path, help = "the file to write, e.g. out.mp4", required = true}},
		flags = {{name = "quality", kind = .Enum, values = {"draft", "final"}, def = "final", help = "draft is half size and fast"}},
		out = EXPORT_FIELDS,
		examples = {"videoedit export demo.vep out.mp4 --quality draft --json"},
		run = cmd_export,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "videoedit",
			summary    = "a non-linear video editor: projects, clips, titles, captions, export",
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
SURFACE_NOTES :: `A project is a .vep file: the window's Ctrl-S writes one, Ctrl-O opens one,
and "videoedit project.vep" opens it in the window. Media is referenced by
path, never copied. Clip ids come from "info" and are positional: they are
renumbered on every load, so read them again after a change (every mutating
command prints the project afterwards). Times are seconds.

"videoedit FILE..." with media files opens the window with them imported; the
older flags --shot, --audiobench and --undobench still work.`

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself on a failure
	return 0
}

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

PROBE_FIELDS := []kit.Field {
	{name = "path", kind = .String},
	{name = "duration", kind = .Float, help = "seconds"},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "fps", kind = .Float},
	{name = "vcodec", kind = .String},
	{name = "acodec", kind = .String},
	{name = "has_video", kind = .Bool},
	{name = "has_audio", kind = .Bool},
}

PROJECT_FIELDS := []kit.Field {
	{name = "project", kind = .String, help = "the project file"},
	{name = "saved", kind = .Bool, help = "false under --dry-run and for a read"},
	{name = "did", kind = .String, opt = true, help = "what the command changed, in words"},
	{name = "clip", kind = .Int, opt = true, help = "the clip the command made or acted on, by its id after the change"},
	{name = "duration", kind = .Float, help = "the timeline's length in seconds"},
	{name = "width", kind = .Int, help = "output width"},
	{name = "height", kind = .Int, help = "output height"},
	{name = "fps", kind = .Float, help = "output frame rate"},
	{
		name = "media",
		kind = .Array,
		of = {
			{name = "index", kind = .Int},
			{name = "name", kind = .String},
			{name = "path", kind = .String},
			{name = "exists", kind = .Bool},
			{name = "duration", kind = .Float},
			{name = "width", kind = .Int},
			{name = "height", kind = .Int},
			{name = "has_video", kind = .Bool},
			{name = "has_audio", kind = .Bool},
		},
	},
	{
		name = "tracks",
		kind = .Array,
		of = {
			{name = "index", kind = .Int},
			{name = "name", kind = .String},
			{name = "kind", kind = .String, help = "video or audio"},
			{name = "mute", kind = .Bool},
			{name = "solo", kind = .Bool},
			{
				name = "clips",
				kind = .Array,
				of = {
					{name = "id", kind = .Int},
					{name = "start", kind = .Float},
					{name = "end", kind = .Float},
					{name = "src_in", kind = .Float},
					{name = "src_out", kind = .Float},
					{name = "media", kind = .Int, help = "index into media, -1 for a title"},
					{name = "title", kind = .String},
					{name = "transition", kind = .String, help = "cut or dissolve"},
				},
			},
		},
	},
	{name = "captions", kind = .Int, help = "how many cues"},
	{name = "caption_source", kind = .String},
	{name = "caption_offset", kind = .Float},
}

EXPORT_FIELDS := []kit.Field {
	{name = "project", kind = .String},
	{name = "out", kind = .String},
	{name = "quality", kind = .String},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "timeline", kind = .Float, help = "the timeline's length in seconds"},
	{name = "exported", kind = .Bool, help = "false under --dry-run"},
	{name = "seconds", kind = .Float, help = "wall-clock time the export took"},
	{name = "verified", kind = .Bool, help = "ffprobe read the result back"},
	{name = "duration", kind = .Float, help = "the result's length as ffprobe reads it"},
	{name = "streams", kind = .Int},
	{name = "vcodec", kind = .String},
	{name = "acodec", kind = .String},
}

// ---------------------------------------------------------------------------
// Loading, saving, printing
// ---------------------------------------------------------------------------

@(private = "file")
Loaded :: struct {
	pr:   Project,
	path: string,
	view: Project_Load,
}

// load reads a project and re-probes its media, which is what the window does
// after Ctrl-O: the file stores sizes and durations but not whether a clip has
// sound, and placing or exporting needs to know. Only the probe runs — no
// thumbnails or waveforms, which only the window draws.
@(private = "file")
load :: proc(c: ^kit.Call, l: ^Loaded) -> int {
	l.path = kit.cli_str(c, "project")
	if !os.exists(l.path) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no project at %s", l.path)
		kit.cli_err_field(c, "project", l.path)
		return code
	}
	project_init(&l.pr)
	l.view = project_load(&l.pr, l.path)
	if !l.view.ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", l.path, l.view.err)
	}
	reprobe(&l.pr)
	return kit.EXIT_OK
}

@(private = "file")
reprobe :: proc(pr: ^Project) {
	for i in 0 ..< len(pr.media) {
		m := pr.media[i]
		if m.probed || !os.exists(m.path) {
			continue
		}
		install_import(pr, import_media(strings.clone(m.path), false))
	}
}

// save writes the project back unless this is a dry run, then prints it.
//
// Clip ids are renumbered first, the way `project_parse` will number them
// when anything next loads the file — tracks in order, each track's clips by
// start — so the ids printed here, and the `clip` this command reports, are
// the ids the next command will see.
@(private = "file")
save :: proc(c: ^kit.Call, l: ^Loaded, did: string, clip := -1) -> int {
	renamed := -1
	n := 1
	for &t in l.pr.tracks {
		for &cl in t.clips {
			if cl.id == clip {
				renamed = n
			}
			cl.id = n
			n += 1
		}
	}
	l.pr.next_id = n
	saved := false
	if !c.dry_run {
		if !project_save(&l.pr, l.path, l.view.playhead, l.view.zoom > 0 ? l.view.zoom : 70) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", l.path)
		}
		saved = true
	}
	project_json(c.out, &l.pr, l.path, saved)
	kit.jset_str(c.out, "did", did)
	if renamed >= 0 {
		kit.jset_int(c.out, "clip", renamed)
	}
	return kit.EXIT_OK
}

@(private = "file")
project_json :: proc(o: ^kit.Json, pr: ^Project, path: string, saved: bool) {
	kit.jset_str(o, "project", path)
	kit.jset_bool(o, "saved", saved)
	kit.jset_num(o, "duration", project_duration(pr))
	kit.jset_int(o, "width", pr.out_w)
	kit.jset_int(o, "height", pr.out_h)
	kit.jset_num(o, "fps", pr.out_fps)
	media := kit.jarr()
	for m, i in pr.media {
		mo := kit.jobj()
		kit.jset_int(mo, "index", i)
		kit.jset_str(mo, "name", m.name)
		kit.jset_str(mo, "path", m.path)
		kit.jset_bool(mo, "exists", os.exists(m.path))
		kit.jset_num(mo, "duration", m.duration)
		kit.jset_int(mo, "width", m.width)
		kit.jset_int(mo, "height", m.height)
		kit.jset_bool(mo, "has_video", m.has_video)
		kit.jset_bool(mo, "has_audio", m.has_audio)
		kit.jpush(media, mo)
	}
	kit.jset(o, "media", media)
	tracks := kit.jarr()
	for &t, ti in pr.tracks {
		to := kit.jobj()
		kit.jset_int(to, "index", ti)
		kit.jset_str(to, "name", t.name)
		kit.jset_str(to, "kind", t.kind == .Video ? "video" : "audio")
		kit.jset_bool(to, "mute", t.mute)
		kit.jset_bool(to, "solo", t.solo)
		clips := kit.jarr()
		for cl in t.clips {
			co := kit.jobj()
			kit.jset_int(co, "id", cl.id)
			kit.jset_num(co, "start", cl.start)
			kit.jset_num(co, "end", clip_end(cl))
			kit.jset_num(co, "src_in", cl.src_in)
			kit.jset_num(co, "src_out", cl.src_out)
			kit.jset_int(co, "media", cl.media)
			kit.jset_str(co, "title", cl.title)
			kit.jset_str(co, "transition", cl.trans == .Dissolve ? "dissolve" : "cut")
			kit.jpush(clips, co)
		}
		kit.jset(to, "clips", clips)
		kit.jpush(tracks, to)
	}
	kit.jset(o, "tracks", tracks)
	kit.jset_int(o, "captions", len(pr.captions))
	kit.jset_str(o, "caption_source", pr.caption_src)
	kit.jset_num(o, "caption_offset", pr.caption_offset)
}

// track_named resolves --track: a name such as V1 (any case) or an index.
@(private = "file")
track_named :: proc(c: ^kit.Call, pr: ^Project, want: string) -> (int, bool) {
	for t, i in pr.tracks {
		if strings.equal_fold(t.name, want) {
			return i, true
		}
	}
	if n, ok := strconv.parse_int(want, 10); ok && n >= 0 && n < len(pr.tracks) {
		return n, true
	}
	names := make([dynamic]string, context.temp_allocator)
	for t in pr.tracks {
		append(&names, t.name)
	}
	kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no track %q (there are %s)", want, strings.join(names[:], ", ", context.temp_allocator))
	kit.cli_err_field(c, "track", want)
	return -1, false
}

// clip_named resolves a clip id to its track and index.
@(private = "file")
clip_named :: proc(c: ^kit.Call, pr: ^Project) -> (t, i, id: int, ok: bool) {
	id = kit.cli_int(c, "clip", -1)
	t, i = find_clip(pr, id)
	if t < 0 {
		kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no clip %d in this project (ids come from info)", id)
		kit.cli_err_field(c, "clip", kit.cli_str(c, "clip"))
		return -1, -1, id, false
	}
	return t, i, id, true
}

@(private = "file")
no_ffprobe :: proc(c: ^kit.Call) -> int {
	return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffprobe is not installed, so media cannot be read")
}

@(private = "file")
have :: proc(tool: string) -> bool {
	_, ok := run_capture({"sh", "-c", fmt.tprintf("command -v %s", tool)}, context.temp_allocator)
	return ok
}

// absolute makes a path absolute without needing it to exist (an export's
// output does not yet). A project stores media paths as given, and the window
// may be started from anywhere, so a relative path would not survive.
@(private = "file")
absolute :: proc(path: string) -> string {
	if strings.has_prefix(path, "/") {
		return path
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		return path
	}
	return fmt.tprintf("%s/%s", cwd, strings.trim_prefix(path, "./"))
}

// bring_in puts a media file in the bin (or finds it there) through the
// importer's own body, and returns its index.
@(private = "file")
bring_in :: proc(c: ^kit.Call, pr: ^Project, path: string) -> (int, int) {
	if !os.exists(path) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no media at %s", path)
		kit.cli_err_field(c, "media", path)
		return -1, code
	}
	if !have("ffprobe") {
		return -1, no_ffprobe(c)
	}
	abs := absolute(path)
	r := import_media(strings.clone(abs), false)
	if !r.ok {
		install_import(pr, r) // frees it
		return -1, kit.cli_failf(c, kit.EXIT_FAILED, "ffprobe could not read %s", path)
	}
	return install_import(pr, r), kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

@(private = "file")
cmd_probe :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "media")
	if !os.exists(path) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no media at %s", path)
		kit.cli_err_field(c, "media", path)
		return code
	}
	if !have("ffprobe") {
		return no_ffprobe(c)
	}
	pb := probe_media(path, context.temp_allocator)
	if !pb.ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "ffprobe could not read %s", path)
	}
	kit.jset_str(c.out, "path", absolute(path))
	kit.jset_num(c.out, "duration", pb.duration)
	kit.jset_int(c.out, "width", pb.width)
	kit.jset_int(c.out, "height", pb.height)
	kit.jset_num(c.out, "fps", pb.fps)
	kit.jset_str(c.out, "vcodec", pb.vcodec)
	kit.jset_str(c.out, "acodec", pb.acodec)
	kit.jset_bool(c.out, "has_video", pb.has_video)
	kit.jset_bool(c.out, "has_audio", pb.has_audio)
	return kit.EXIT_OK
}

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	project_json(c.out, &l.pr, l.path, false)
	return kit.EXIT_OK
}

@(private = "file")
cmd_new :: proc(c: ^kit.Call) -> int {
	l: Loaded
	l.path = kit.cli_str(c, "project")
	if os.exists(l.path) && !kit.cli_bool(c, "force") {
		code := kit.cli_failf(c, kit.EXIT_FAILED, "%s already exists; pass --force to replace it", l.path)
		kit.cli_err_field(c, "project", l.path)
		return code
	}
	project_init(&l.pr)
	l.view = {zoom = 70, ok = true}
	for m in kit.cli_rest(c) {
		if _, code := bring_in(c, &l.pr, m); code != kit.EXIT_OK {
			return code
		}
	}
	if kit.cli_bool(c, "layout") {
		auto_layout_project(&l.pr)
	}
	return save(c, &l, fmt.tprintf("a new project with %d media file(s)", len(l.pr.media)))
}

@(private = "file")
cmd_add :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	vt, ok := track_named(c, &l.pr, kit.cli_str(c, "track"))
	if !ok {
		return kit.EXIT_NOT_FOUND
	}
	if l.pr.tracks[vt].kind != .Video {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is an audio track; the picture goes on a video track and its sound on A1", l.pr.tracks[vt].name)
	}
	mi, code := bring_in(c, &l.pr, kit.cli_str(c, "media"))
	if code != kit.EXIT_OK {
		return code
	}
	m := l.pr.media[mi]
	src_in := kit.cli_f64(c, "in", 0)
	src_out := kit.cli_has(c, "out") ? kit.cli_f64(c, "out") : m.duration
	if src_in < 0 || src_out > m.duration + 0.001 || src_out - src_in <= TIME_EPS {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--in %.3f --out %.3f is not a span of a %.3fs file", src_in, src_out, m.duration)
	}
	at := kit.cli_has(c, "at") ? kit.cli_f64(c, "at") : -1
	pl := place_clip(&l.pr, mi, vt, at, src_in, src_out)
	if pl.id < 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s has neither picture nor sound", m.name)
	}
	return save(c, &l, fmt.tprintf("placed %s at %s", m.name, timecode(pl.at, l.pr.out_fps)), pl.id)
}

@(private = "file")
cmd_split :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	at := kit.cli_f64(c, "at")
	only := -1
	if kit.cli_has(c, "track") {
		t, ok := track_named(c, &l.pr, kit.cli_str(c, "track"))
		if !ok {
			return kit.EXIT_NOT_FOUND
		}
		only = t
	}
	n := 0
	last := -1
	for ti in 0 ..< len(l.pr.tracks) {
		if only >= 0 && ti != only {
			continue
		}
		if id, ok := split_at(&l.pr, ti, at); ok {
			n += 1
			last = id
		}
	}
	if n == 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "nothing to split at %.3fs", at)
	}
	return save(c, &l, fmt.tprintf("split %d clip(s) at %s", n, timecode(at, l.pr.out_fps)), last)
}

@(private = "file")
cmd_trim :: proc(c: ^kit.Call) -> int {
	if !kit.cli_has(c, "in-by") && !kit.cli_has(c, "out-by") {
		return kit.cli_fail(c, kit.EXIT_USAGE, "trim needs --in-by, --out-by or both")
	}
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	t, i, id, ok := clip_named(c, &l.pr)
	if !ok {
		return kit.EXIT_NOT_FOUND
	}
	din, dout := 0.0, 0.0
	if kit.cli_has(c, "in-by") {
		din = trim_in(&l.pr, t, i, kit.cli_f64(c, "in-by"))
		_, i = find_clip(&l.pr, id) // trim_in re-sorts the track
	}
	if kit.cli_has(c, "out-by") {
		dout = trim_out(&l.pr, t, i, kit.cli_f64(c, "out-by"))
	}
	return save(c, &l, fmt.tprintf("trimmed clip %d: in %+.3fs, out %+.3fs", id, din, dout), id)
}

@(private = "file")
cmd_move :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	t, i, id, ok := clip_named(c, &l.pr)
	if !ok {
		return kit.EXIT_NOT_FOUND
	}
	to := t
	if kit.cli_has(c, "track") {
		nt, tok := track_named(c, &l.pr, kit.cli_str(c, "track"))
		if !tok {
			return kit.EXIT_NOT_FOUND
		}
		if l.pr.tracks[nt].kind != l.pr.tracks[t].kind {
			return kit.cli_failf(c, kit.EXIT_USAGE, "a clip moves between tracks of the same kind; %s is %v and %s is %v", l.pr.tracks[t].name, l.pr.tracks[t].kind, l.pr.tracks[nt].name, l.pr.tracks[nt].kind)
		}
		to = nt
	}
	nt, _ := move_clip(&l.pr, t, i, to, kit.cli_f64(c, "to"))
	return save(c, &l, fmt.tprintf("moved clip %d to %s on %s", id, timecode(kit.cli_f64(c, "to"), l.pr.out_fps), l.pr.tracks[nt].name), id)
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	t, i, id, ok := clip_named(c, &l.pr)
	if !ok {
		return kit.EXIT_NOT_FOUND
	}
	ripple := kit.cli_bool(c, "ripple")
	if ripple {
		ripple_delete(&l.pr, t, i)
	} else {
		lift_delete(&l.pr, t, i)
	}
	return save(c, &l, fmt.tprintf("deleted clip %d%s", id, ripple ? ", the gap closed" : ", gap left"))
}

@(private = "file")
cmd_dissolve :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	t, i, id, ok := clip_named(c, &l.pr)
	if !ok {
		return kit.EXIT_NOT_FOUND
	}
	want := kit.cli_bool(c, "off") ? Transition.Cut : Transition.Dissolve
	if l.pr.tracks[t].clips[i].trans != want {
		toggle_dissolve(&l.pr, t, i)
	}
	_, i = find_clip(&l.pr, id)
	got := l.pr.tracks[t].clips[i].trans
	if got != want {
		return kit.cli_failf(c, kit.EXIT_FAILED, "clip %d is too short to dissolve into", id)
	}
	return save(c, &l, want == .Dissolve ? fmt.tprintf("clip %d dissolves in over %.2fs", id, l.pr.tracks[t].clips[i].xfade) : fmt.tprintf("clip %d is a hard cut", id), id)
}

@(private = "file")
cmd_title :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	vt := track_of_kind(&l.pr, .Video, 0) // the window's `t` key
	if kit.cli_has(c, "track") {
		t, ok := track_named(c, &l.pr, kit.cli_str(c, "track"))
		if !ok {
			return kit.EXIT_NOT_FOUND
		}
		if l.pr.tracks[t].kind != .Video {
			return kit.cli_failf(c, kit.EXIT_USAGE, "a title goes on a video track, and %s is audio", l.pr.tracks[t].name)
		}
		vt = t
	}
	length := kit.cli_f64(c, "length", 2.5)
	if length <= TIME_EPS {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--length must be more than zero")
	}
	text := kit.cli_str(c, "text")
	id := insert_title(&l.pr, vt, max(0, kit.cli_f64(c, "at")), length, text)
	return save(c, &l, fmt.tprintf("title %q on %s", text, l.pr.tracks[vt].name), id)
}

@(private = "file")
cmd_captions :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	path := kit.cli_str(c, "file")
	if !os.exists(path) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no caption file at %s", path)
		kit.cli_err_field(c, "file", path)
		return code
	}
	n, f, ok := load_captions(&l.pr, absolute(path))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not read captions from %s", path)
	}
	l.pr.caption_offset = kit.cli_f64(c, "offset")
	return save(c, &l, fmt.tprintf("%d cues from %v, offset %+.2fs", n, f, l.pr.caption_offset))
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	l: Loaded
	if code := load(c, &l); code != kit.EXIT_OK {
		return code
	}
	if !have("ffmpeg") || !have("ffprobe") {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "ffmpeg and ffprobe are needed to export")
	}
	for m in l.pr.media {
		if !os.exists(m.path) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "the project's media %s is missing", m.path)
		}
	}
	out := absolute(kit.cli_str(c, "out"))
	q := kit.cli_str(c, "quality") == "draft" ? Export_Quality.Draft : Export_Quality.Final
	kit.jset_str(c.out, "project", l.path)
	kit.jset_str(c.out, "out", out)
	kit.jset_str(c.out, "quality", q == .Draft ? "draft" : "final")
	kit.jset_num(c.out, "timeline", project_duration(&l.pr))

	if c.dry_run {
		// The plan is built — that is where every refusal lives — and thrown
		// away without starting ffmpeg.
		plan := build_export(&l.pr, Export_Settings{quality = q, out_path = out}, context.temp_allocator)
		if plan.err != "" {
			return kit.cli_failf(c, kit.EXIT_FAILED, "%s", plan.err)
		}
		for t in plan.temps {
			os.remove(t)
		}
		kit.jset_int(c.out, "width", plan.width)
		kit.jset_int(c.out, "height", plan.height)
		kit.jset_bool(c.out, "exported", false)
		kit.jset_num(c.out, "seconds", 0)
		kit.jset_bool(c.out, "verified", false)
		kit.jset_num(c.out, "duration", 0)
		kit.jset_int(c.out, "streams", 0)
		kit.jset_str(c.out, "vcodec", "")
		kit.jset_str(c.out, "acodec", "")
		return kit.EXIT_OK
	}

	ex: Exporter
	exporter_start(&ex)
	defer exporter_stop(&ex)
	w, h, err := export_submit(&l.pr, &ex, out, q)
	if err != "" {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%s", err)
	}
	kit.cli_note(c, "exporting %dx%d to %s", w, h, out)
	t0 := time.now()
	st: Export_Status
	for {
		st = exporter_status(&ex)
		if st.state == .Done || st.state == .Failed {
			break
		}
		kit.cli_trace(c, "%3.0f%%  %s", st.progress * 100, st.message)
		time.sleep(100 * time.Millisecond)
	}
	secs := time.duration_seconds(time.since(t0))
	if st.state == .Failed {
		return kit.cli_failf(c, kit.EXIT_FAILED, "ffmpeg: %s", st.message)
	}
	v := verify_output(out, context.temp_allocator)
	kit.jset_int(c.out, "width", w)
	kit.jset_int(c.out, "height", h)
	kit.jset_bool(c.out, "exported", true)
	kit.jset_num(c.out, "seconds", secs)
	kit.jset_bool(c.out, "verified", v.ok)
	kit.jset_num(c.out, "duration", v.duration)
	kit.jset_int(c.out, "streams", v.streams)
	kit.jset_str(c.out, "vcodec", v.vcodec)
	kit.jset_str(c.out, "acodec", v.acodec)
	if !v.ok {
		return kit.cli_failf(c, kit.EXIT_FAILED, "ffprobe could not read %s back", out)
	}
	return kit.EXIT_OK
}
