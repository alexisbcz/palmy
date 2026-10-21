package main

// videoedit — a non-linear editor on palmy.
//
// The frame loop never waits on ffmpeg. Four worker threads do all the
// blocking work: the importer (ffprobe, thumbnails, waveforms), the preview
// decoder (raw frames into a cache), the exporter (one ffmpeg run, polled for
// progress) and the mixer's pump (mixed PCM into pw-cat). Each owns exactly
// one mutex and the rule is the same in all four: slow work happens with the
// lock released, the lock only guards a handoff of plain data, and no
// procedure that holds a lock calls one that takes it. See the header of
// media.odin, preview.odin, export.odin and audio.odin.
//
// The playhead is not advanced by wall time. While the preview plays it is
// *read off the audio clock* — the count of PCM bytes pw-cat has accepted —
// so the picture is presented against the sound rather than the two drifting
// apart. `audio_follow` is the whole of that, and it falls back to
// `delta_time` only when there is no sink to play into.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

Mode :: enum u8 {
	Normal,
	Typing, // a text field owns the keyboard
	Help,
}

Drag :: enum u8 {
	None,
	Scrub,
	Move,
	Trim_In,
	Trim_Out,
}

Field :: enum u8 {
	None,
	Export_Path,
	Project_Path,
	Caption_Path,
	Title_Text,
}

Editor :: struct {
	app:          ^p.App,
	// The font set the custom draw procedures measure and draw with. It is
	// the window's in normal use and the offscreen renderer's under --shot.
	fonts:        ^p.Fonts,
	pr:           Project,
	im:           Importer,
	pv:           Preview,
	ex:           Exporter,
	mx:           Mixer,
	sc:           Scrub, // sound while the playhead is dragged or stepped
	hist:         History,

	playhead:     f64,
	zoom:         f32, // pixels per second
	scroll:       f64, // leftmost visible second
	playing:      bool,
	sel:          int, // selected clip id, -1 for none
	cur_track:    int,
	bin_sel:      int,
	// Which title clip `buf_title` is currently holding the text of.
	title_buf_for: int,

	mode:         Mode,
	field:        Field,
	buf_export:   [dynamic]u8,
	buf_project:  [dynamic]u8,
	buf_caption:  [dynamic]u8,
	buf_title:    [dynamic]u8,

	// Timeline geometry, taken from the previous frame's layout.
	tl:           p.Rect,
	tl_id:        u64,

	drag:         Drag,
	drag_id:      int,
	drag_grab:    f64, // offset from the clip start to the grab point
	drag_track:   int,
	snap_at:      f64,
	snap_show:    bool,

	status:       string,
	status_until: f64,

	pending:      [dynamic]Import_Result,
	last_edit:    u64, // bumped on every timeline mutation
	edit_seen:    u64, // the value the preview cache was built against

	// Audio. `seek_req` is set by anything that moves the playhead on
	// purpose, as opposed to the playhead moving because the clock advanced;
	// it is what tells the mixer to flush and restart rather than carry on
	// from where it was. `mix_dirty` is the same signal for an edit that
	// changed *what* is audible.
	seek_req:     bool,
	mix_dirty:    bool,
	mix_built:    time.Time,
	audio_said:   bool, // the sink's failure has been reported once
	rate:         f64, // playback rate, timeline seconds per second; 0 means 1
	scrub_at:     f64, // where the scrubber last saw the playhead

	// How far the painted picture was from the audio clock, which is the
	// preview's presentation error. Counted while playing only.
	pres_sum:     f64,
	pres_max:     f64,
	pres_n:       int,
	pres_miss:    int,

	// Instrumentation for the stats line.
	draw_fps:     f32,
	shown:        int,
	starved:      int,
	verify:       Verify,
	verified:     bool,
	still:        p.Image,
	still_ok:     bool,

	// The shared file dialog, and what it was opened for. See pick.odin.
	pick:         kit.Pick,
	pick_use:     Pick_Use,
}

GUTTER :: f32(64) // track-name column inside the timeline
RULER_H :: f32(24)
TRACK_H :: f32(58)
CAPTION_H :: f32(30)

main :: proc() {
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" {
			selftest()
			return
		}
		if a == "--audiobench" || a == "--audiobench-loud" {
			secs := f64(6)
			if i + 1 < len(args) {
				if v, ok := strconv.parse_f64(args[i + 1]); ok {
					secs = v
				}
			}
			// Silent by default: the clock, the latency and the presentation
			// error are all properties of the byte flow, not of the amplitude,
			// so they can be measured exactly without filling the room. The
			// `-loud` form is there to confirm by ear that the mix is audible.
			audio_bench(secs, a == "--audiobench")
			return
		}
		if a == "--undobench" {
			undo_bench()
			return
		}
		if a == "--shot" && i + 1 < len(args) {
			at := f64(1.2)
			if i + 2 < len(args) {
				if v, ok := strconv.parse_f64(args[i + 2]); ok {
					at = v
				}
			}
			shot(args[i + 1], at)
			return
		}
	}

	// The command line is the other front end over the same project model:
	// see cli.odin. Anything that is not a command — no arguments, or a media
	// file or a project to open — falls through to the window.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	ed := new(Editor)
	defer free(ed)
	ed.zoom = 70
	ed.sel = -1
	ed.cur_track = 1
	project_init(&ed.pr)

	set_str(&ed.buf_export, default_export())
	set_str(&ed.buf_project, default_project())
	set_str(&ed.buf_caption, default_caption_path())
	set_str(&ed.buf_title, "VIDEOEDIT")

	importer_start(&ed.im)
	preview_start(&ed.pv)
	exporter_start(&ed.ex)
	mixer_init(&ed.mx)
	defer kit.pick_destroy(&ed.pick)
	defer {
		importer_stop(&ed.im)
		preview_stop(&ed.pv)
		exporter_stop(&ed.ex)
		scrub_destroy(&ed.sc)
		mixer_destroy(&ed.mx)
		history_destroy(&ed.hist)
		project_destroy(&ed.pr)
	}

	// Anything named on the command line is imported; otherwise the bundled
	// test clips are, so the window is never empty.
	imported := 0
	project_arg := ""
	for a in args {
		if strings.has_prefix(a, "--") {
			continue
		}
		// A project — one `videoedit new` wrote, say — opens as a project,
		// the way Ctrl-O would, rather than being probed as media.
		if strings.has_suffix(strings.to_lower(a, context.temp_allocator), ".vep") {
			project_arg = a
			continue
		}
		importer_push(&ed.im, a)
		imported += 1
	}
	if project_arg != "" {
		if res := project_load(&ed.pr, project_arg); res.ok {
			set_str(&ed.buf_project, project_arg)
			ed.playhead = res.playhead
			ed.zoom = res.zoom
			// Thumbnails and waveforms are derived, so rebuild them.
			for m in ed.pr.media {
				importer_push(&ed.im, m.path)
			}
			imported += 1
		} else {
			fmt.eprintfln("videoedit: %s: %s", project_arg, res.err)
		}
	}
	if imported == 0 {
		for f in discover_media() {
			importer_push(&ed.im, f)
		}
	}

	app, err := kit.start({title = "videoedit", width = 1500, height = 900}, true)
	if err != "" {
		fmt.eprintln("videoedit:", err)
		return
	}
	ed.app = app
	ed.fonts = &app.fonts
	defer p.destroy(app)

	auto_laid := false
	// wf-recorder captures on output damage, and an editor sitting still has
	// nothing to repaint — which is correct behaviour for a window on a
	// desktop and useless in front of a camera: a two-minute take came out
	// three frames long. VE_RECORD asks for a frame every tick so a recording
	// has something to record. It is off in normal use, where an idle editor
	// goes back to blocking in poll like any other palmy window.
	filming := os.get_env("VE_RECORD", context.temp_allocator) != ""

	for ui in p.frames(app) {
		if filming {
			p.redraw(ui)
		}
		ed.draw_fps = p.frames_per_second(ui)

		// 1. Collect anything the workers finished.
		clear(&ed.pending)
		importer_drain(&ed.im, &ed.pending)
		for r in ed.pending {
			// install_import takes ownership of the result, and frees the path
			// when the row already exists — so read the name before handing it
			// over, not after.
			name := strings.clone(base_name(r.path), context.temp_allocator)
			if install_import(&ed.pr, r) >= 0 {
				status(ed, ui, fmt.tprintf("imported %s", name))
			}
		}
		if len(ed.pending) > 0 {
			ed.last_edit += 1
		}
		if preview_collect(&ed.pv, ed.playhead) > 0 {
			p.redraw(ui) // new frames are only visible once they are painted
		}

		// A first-run convenience: lay the imported clips out so there is
		// something real on the timeline the moment the window opens.
		if !auto_laid && imported == 0 && len(ed.pr.media) >= 2 && !importer_busy(&ed.im) {
			auto_layout(ed)
			auto_laid = true
			// The first-run layout is not an edit the user made, so there is
			// nothing behind it worth being able to go back to.
			undo_reset(ed)
		}

		// 2. Advance the playhead — against the audio clock, not wall time.
		mixer_tick(&ed.mx)
		audio_follow(ed, ui)

		// 3. Input. The timeline's rectangle comes from the previous frame's
		// layout, which is the same geometry palmy's own hit testing uses.
		if ed.tl_id != 0 {
			ed.tl = p.rect_of(ui, ed.tl_id)
		}
		handle_keys(ed, ui)
		// The timeline reads the raw pointer against its own rectangle rather
		// than through palmy's hit testing, so it has to be told when the
		// file dialog is in front of it.
		if !kit.pick_active(&ed.pick) {
			handle_timeline_mouse(ed, ui)
		}
		if ed.drag != .Scrub {
			follow_playhead(ed)
		}

		// 4. Keep the decoder ahead of the playhead.
		force := ed.last_edit != ed.edit_seen
		if force {
			cache_drop_all(&ed.pv)
			ed.edit_seen = ed.last_edit
		}
		preview_follow(&ed.pr, &ed.pv, ed.playhead, force)

		// 5. Draw.
		draw_ui(ed, ui)

		// Keep asking for frames while anything is in flight; an idle editor
		// goes back to blocking in poll like any other palmy window.
		if importer_busy(&ed.im) {
			p.redraw(ui)
		}
		if _, _, busy := preview_stats(&ed.pv); busy {
			p.redraw(ui)
		}
		if st := exporter_status(&ed.ex); st.state == .Running {
			p.redraw(ui)
		}
	}
}

status :: proc(ed: ^Editor, ui: ^p.Ctx, msg: string) {
	delete(ed.status)
	ed.status = strings.clone(msg)
	ed.status_until = f64(p.elapsed(ui)) + 4
}

set_str :: proc(buf: ^[dynamic]u8, s: string) {
	clear(buf)
	append(buf, s)
}

buf_str :: proc(buf: ^[dynamic]u8) -> string {
	return string(buf[:])
}

// ---------------------------------------------------------------------------
// Discovery helpers
// ---------------------------------------------------------------------------

// Where the editor looks for media, writes its export and keeps its project.
// They used to be this checkout's absolute paths, which exist on exactly one
// machine. Now: $PALMY_VIDEOEDIT_MEDIA if set; else the checkout's bundled
// test media when run from the repository root (the selftest and the bench
// use it); else the user's videos folder, ~/Videos, or the home directory.
// The export and project paths stay absolute, because the app may be started
// from anywhere: a relative export path that silently lands in someone
// else's working directory is worse than a long one in the field.
CHECKOUT_MEDIA :: "apps/videoedit/media"
CHECKOUT_CAPTIONS :: "apps/captions"

media_dir :: proc() -> string {
	if d := os.get_env("PALMY_VIDEOEDIT_MEDIA", context.temp_allocator); d != "" {
		return d
	}
	if os.is_dir(CHECKOUT_MEDIA) {
		if abs, err := os.get_absolute_path(CHECKOUT_MEDIA, context.temp_allocator); err == nil {
			return abs
		}
	}
	return videos_dir()
}

// videos_dir is ~/Videos when it exists, else the home directory.
videos_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	v := fmt.tprintf("%s/Videos", home)
	return os.is_dir(v) ? v : home
}

default_export :: proc() -> string {
	return fmt.tprintf("%s/export.mp4", videos_dir())
}

default_project :: proc() -> string {
	return fmt.tprintf("%s/project.vep", videos_dir())
}

// captions_dir is where the captioning app's output turns up. It writes next
// to the media it transcribed, and its own working files land in the XDG
// cache directory, so those are searched too (default_caption_path) — the
// interop is "read the file it wrote", nothing more. Its development tree
// only when run from the checkout.
captions_dir :: proc() -> string {
	if d := os.get_env("PALMY_CAPTIONS_DIR", context.temp_allocator); d != "" {
		return d
	}
	return os.is_dir(CHECKOUT_CAPTIONS) ? CHECKOUT_CAPTIONS : ""
}

discover_media :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	infos, rerr := os.read_all_directory_by_path(media_dir(), context.temp_allocator)
	if rerr != nil {
		return out[:]
	}
	for info in infos {
		lower := strings.to_lower(info.name, context.temp_allocator)
		if strings.has_suffix(lower, ".mp4") ||
		   strings.has_suffix(lower, ".mkv") ||
		   strings.has_suffix(lower, ".mov") ||
		   strings.has_suffix(lower, ".webm") ||
		   strings.has_suffix(lower, ".wav") ||
		   strings.has_suffix(lower, ".mp3") {
			append(&out, strings.clone(info.fullpath, context.temp_allocator))
		}
	}
	// Stable order, so the demo is reproducible.
	for i in 1 ..< len(out) {
		v := out[i]
		j := i - 1
		for j >= 0 && out[j] > v {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = v
	}
	return out[:]
}

// default_caption_path prefers whatever the captioning app has produced, and
// falls back to the sample shipped alongside this editor.
default_caption_path :: proc() -> string {
	cache := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if cache == "" {
		cache = fmt.tprintf("%s/.cache", os.get_env("HOME", context.temp_allocator))
	}
	captions_cache := fmt.tprintf("%s/palmy-captions", cache)
	for dir in ([?]string{captions_dir(), captions_cache, media_dir()}) {
		if dir == "" {
			continue
		}
		infos, rerr := os.read_all_directory_by_path(dir, context.temp_allocator)
		if rerr != nil {
			continue
		}
		best := ""
		for info in infos {
			lower := strings.to_lower(info.name, context.temp_allocator)
			if strings.has_suffix(lower, ".srt") ||
			   strings.has_suffix(lower, ".vtt") ||
			   strings.has_suffix(lower, ".ass") {
				if best == "" || info.name < filepath.base(best) {
					best = info.fullpath
				}
			}
		}
		if best != "" {
			return strings.clone(best, context.temp_allocator)
		}
	}
	return "apps/videoedit/media/sample.srt"
}

// auto_layout drops the first two imported clips onto V1 with a dissolve and
// their audio onto A1, which is a reasonable thing to be looking at when the
// window opens.
auto_layout :: proc(ed: ^Editor) {
	auto_layout_project(&ed.pr)
	ed.last_edit += 1
}

// auto_layout_project is the layout itself, with no window: `videoedit new
// --layout` lays a new project out exactly as the window does on first run.
auto_layout_project :: proc(pr: ^Project) {
	if len(pr.media) == 0 {
		return
	}
	v := track_of_kind(pr, .Video, 1)
	a := track_of_kind(pr, .Audio, 0)
	n := min(3, len(pr.media))
	for i in 0 ..< n {
		m := pr.media[i]
		if !m.has_video {
			continue
		}
		dur := math.min(m.duration, 4)
		append_clip(pr, v, i, 0, dur)
		if m.has_audio {
			id := pr.tracks[v].clips[len(pr.tracks[v].clips) - 1].id
			_, ci := find_clip(pr, id)
			append_clip(pr, a, i, pr.tracks[v].clips[ci].src_in, pr.tracks[v].clips[ci].src_out)
			at := pr.tracks[v].clips[ci].start
			ai := len(pr.tracks[a].clips) - 1
			pr.tracks[a].clips[ai].start = at
			track_sort(&pr.tracks[a])
		}
	}
}

track_of_kind :: proc(pr: ^Project, kind: Track_Kind, nth: int) -> int {
	seen := 0
	for &t, i in pr.tracks {
		if t.kind == kind {
			if seen == nth {
				return i
			}
			seen += 1
		}
	}
	for &t, i in pr.tracks {
		if t.kind == kind {
			return i
		}
	}
	return 0
}
