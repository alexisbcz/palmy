package main

// palmy video — a video player.
//
// palmy has no codecs, so ffmpeg does the decoding and hands over raw frames
// through a pipe; the app blits them straight into the canvas. Sound goes out
// through pw-cat, and the bytes it accepts are the master clock that the
// picture is scheduled against. engine.odin is where that lives.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1240
WIN_H :: 800

TOPBAR_H :: f32(56)
CTRL_H :: f32(96)
STATUS_H :: f32(30)
PANEL_W :: f32(300)

SEEK_STEP :: f64(5)
SEEK_BIG :: f64(60)

View :: enum u8 {
	Library,
	Player,
}

Entry :: struct {
	path:  string,
	name:  string,
	dir:   string,
	size:  i64,
	mtime: time.Time,
	probed: bool,
	m:     Media,
}

St :: struct {
	view:        View,
	e:           Engine,
	open:        bool,
	err:         string,

	lib:         []Entry,
	// Where the list came from, so the header can say so rather than reciting
	// every folder that might have been searched.
	lib_source:  string,
	sel:         int,
	lib_top:     int,
	lib_vis:     int,

	// Where the picture goes, in logical pixels, and the size we decode at.
	vrect:       p.Rect,
	want_w:      int,
	want_h:      int,
	resize_at:   f64,
	pending:     bool,

	// Chrome.
	info:        bool,
	stats:       bool,
	toast:       string,
	toast_t:     f64,
	scrubbing:   bool,
	scrub_at:    f64,
	seek_count:  int,
	seek_ms_sum: f64,
	ended:       bool,

	mouse:       [2]f32,
	moved:       bool,
	started:     bool,
}

main :: proc() {
	shot_out, shot_secs, shot_keys, want_shot := shot_requested()

	app: ^p.App
	if !want_shot {
		err: string
		app, err = kit.start(
			{
				title = "Video",
				app_id = "palmy",
				width = WIN_W,
				height = WIN_H,
				root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
			},
		)
		if err != "" {
			fmt.eprintfln("video: %s", err)
			os.exit(1)
		}
	} else {
		sc.register_shadcn_theme()
	}
	defer if app != nil {p.destroy(app)}
	register_dark_theme()

	st := St {
		info = true,
	}
	if want_shot {
		// Offscreen the window never resizes, so the picture box is known up
		// front and the engine can open on the first frame.
		st.vrect = {0, TOPBAR_H, f32(WIN_W) - PANEL_W - 1, f32(WIN_H) - TOPBAR_H - CTRL_H - STATUS_H}
	}

	target := ""
	for a in shot_strip(os.args[1:]) {
		if !strings.has_prefix(a, "-") {
			target = a
			break
		}
	}

	if target != "" {
		abs := absolute(target)
		if fi, serr := os.stat(abs, context.allocator); serr == nil && fi.type == .Directory {
			st.lib = scan_media(abs)
			st.lib_source = strings.clone(abs)
			st.view = .Library
		} else if serr == nil {
			st.lib = scan_media(dir_of(abs))
			st.lib_source = strings.clone(dir_of(abs))
			st.sel = index_of(st.lib, abs)
			if st.sel < 0 {
				// Something outside the folder scan — try it anyway: the
				// extension is a hint, ffprobe is the authority.
				st.lib = append_entry(st.lib, abs)
				st.sel = len(st.lib) - 1
			}
			start_playing(&st)
		} else {
			st.err = fmt.aprintf("%s: no such file", target)
			st.lib = scan_library()
			st.view = .Library
		}
	} else {
		st.lib = scan_library()
		st.view = .Library
	}
	defer engine_destroy(&st.e)

	if want_shot {
		run_shot(&st, shot_out, shot_secs, shot_keys)
		return
	}

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		if st.view == .Player {
			// The player is the one window that genuinely redraws every vsync;
			// without this the loop would sleep waiting for input and the
			// clock would only advance when the mouse moved.
			if !st.open || !engine_paused(&st.e) {
				p.redraw(ui)
			}
		}
		if st.view == .Player && st.open {
			engine_tick(&st.e)
			now := engine_clock(&st.e)
			engine_take(&st.e, now)
			if engine_finished(&st.e) && !st.ended {
				st.ended = true
				engine_pause(&st.e, true)
			}
			// A player is the one kind of window that genuinely has to redraw
			// every vsync.
			if !engine_paused(&st.e) || st.pending {
				p.redraw(ui)
			}
		}

		handle_keys(ui, app, &st)

		switch st.view {
		case .Library:
			build_library(ui, &st)
		case .Player:
			build_player(ui, &st)
		}

		apply_resize(&st, ui.now)

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			}
			p.redraw(ui)
		}
	}
}

register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x09090b))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x121214))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c1f))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x18181b))
	p.register_color("secondary", c(0x27272a))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1d1d20))
	p.register_color("muted-foreground", c(0xa1a1aa))
	p.register_color("accent", c(0x2e2e33))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xf87171))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x2a2a2e))
	p.register_color("input", c(0x2a2a2e))
	p.register_color("ring", c(0x8e8e93))
}

absolute :: proc(path: string) -> string {
	if strings.has_prefix(path, "/") {
		return strings.clone(path)
	}
	if strings.has_prefix(path, "~/") {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil {
			return fmt.aprintf("%s%s", home, path[1:])
		}
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.aprintf("%s/%s", cwd, path)
}

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

VIDEO_EXT := [?]string {
	".mp4",
	".mkv",
	".webm",
	".mov",
	".avi",
	".m4v",
	".ts",
	".mpg",
	".mpeg",
	".wmv",
	".flv",
	".ogv",
}

is_video :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for e in VIDEO_EXT {
		if strings.has_suffix(lower, e) {
			return true
		}
	}
	return false
}

scan_media :: proc(dir: string) -> []Entry {
	out := make([dynamic]Entry)
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		if fi.type == .Directory || !is_video(fi.name) {
			continue
		}
		append(
			&out,
			Entry {
				path = strings.clone(fi.fullpath),
				name = strings.clone(fi.name),
				dir = strings.clone(dir),
				size = fi.size,
				mtime = fi.modification_time,
			},
		)
	}
	slice.sort_by(out[:], proc(a, b: Entry) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator),
			strings.to_lower(b.name, context.temp_allocator)) < 0
	})
	return out[:]
}

// scan_library looks where videos live on a Linux desktop, plus whatever
// $PALMY_MEDIA_DIR points at, which is how the demo is pointed at its clips.
scan_library :: proc() -> []Entry {
	out := make([dynamic]Entry)
	seen := make(map[string]bool, context.temp_allocator)
	add_dir :: proc(out: ^[dynamic]Entry, seen: ^map[string]bool, dir: string) {
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		for e in scan_media(dir) {
			append(out, e)
		}
	}
	if extra := os.get_env("PALMY_MEDIA_DIR", context.temp_allocator); extra != "" {
		for part in strings.split(extra, ":", context.temp_allocator) {
			add_dir(&out, &seen, strings.trim_space(part))
		}
	}
	if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		add_dir(&out, &seen, fmt.tprintf("%s/Videos", home))
		add_dir(&out, &seen, fmt.tprintf("%s/Movies", home))
		add_dir(&out, &seen, fmt.tprintf("%s/Downloads", home))
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	add_dir(&out, &seen, cwd)
	return out[:]
}

append_entry :: proc(lib: []Entry, path: string) -> []Entry {
	out := make([dynamic]Entry)
	for e in lib {
		append(&out, e)
	}
	size := i64(0)
	mt: time.Time
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		size = fi.size
		mt = fi.modification_time
	}
	append(
		&out,
		Entry {
			path = strings.clone(path),
			name = strings.clone(base_of(path)),
			dir = strings.clone(dir_of(path)),
			size = size,
			mtime = mt,
		},
	)
	return out[:]
}

index_of :: proc(lib: []Entry, path: string) -> int {
	for e, i in lib {
		if e.path == path {
			return i
		}
	}
	return -1
}

current :: proc(st: ^St) -> ^Entry {
	if st.sel < 0 || st.sel >= len(st.lib) {
		return nil
	}
	return &st.lib[st.sel]
}

ensure_probed :: proc(en: ^Entry) {
	if en.probed {
		return
	}
	en.probed = true
	en.m = probe_file(en.path)
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

start_playing :: proc(st: ^St) {
	en := current(st)
	if en == nil {
		return
	}
	ensure_probed(en)
	if !en.m.ok {
		st.err = en.m.err != "" ? strings.clone(en.m.err) : "this file cannot be played"
		st.view = .Library
		st.open = false
		return
	}
	st.err = ""
	engine_destroy(&st.e)
	st.e = {}
	engine_init(&st.e, en.m)
	st.view = .Player
	st.open = false // opened on the first frame, when the picture box is known
	st.ended = false
	st.pending = false
	st.want_w, st.want_h = 0, 0
}

// decode_size is the size the picture will be drawn at, which is the size worth
// decoding at: ffmpeg scales for free and a 1:1 blit costs a memcpy.
decode_size :: proc(st: ^St) -> (int, int) {
	m := st.e.m
	if m.width <= 0 || m.height <= 0 || st.vrect.w < 8 || st.vrect.h < 8 {
		return 0, 0
	}
	r := p.fitted_rect(f32(m.width), f32(m.height), st.vrect, .Contain)
	w := clamp(int(r.w + 0.5), 16, 1920)
	h := clamp(int(r.h + 0.5), 16, 1200)
	return w & ~int(1), h & ~int(1)
}

// apply_resize restarts the pipeline when the window has settled at a new size.
// Decoding at the wrong size and rescaling every frame in software would cost
// more than the restart does.
apply_resize :: proc(st: ^St, now: f64) {
	if st.view != .Player || st.e.m.width <= 0 {
		return
	}
	w, h := decode_size(st)
	if w <= 0 {
		return
	}
	if !st.open {
		st.want_w, st.want_h = w, h
		engine_open(&st.e, 0, w, h)
		st.open = true
		return
	}
	// Restarting ffmpeg is the price of a 1:1 blit, so it is only worth paying
	// when the window has really changed size and has stopped moving. Anything
	// smaller is absorbed by scaling the frame on the way to the canvas.
	area_now := f32(st.e.w) * f32(st.e.h)
	area_new := f32(w) * f32(h)
	if area_now > 0 && abs(area_new - area_now) / area_now < 0.12 {
		st.pending = false
		return
	}
	if !st.pending || abs(w - st.want_w) > 8 || abs(h - st.want_h) > 8 {
		st.pending = true
		st.want_w, st.want_h = w, h
		st.resize_at = now + 0.8
		return
	}
	if now >= st.resize_at {
		st.pending = false
		at := engine_clock(&st.e)
		was := engine_paused(&st.e)
		engine_open(&st.e, at, st.want_w, st.want_h)
		engine_pause(&st.e, was)
	}
}

seek_to :: proc(st: ^St, t: f64) {
	if !st.open {
		return
	}
	was := engine_paused(&st.e)
	t0 := time.now()
	engine_open(&st.e, clamp(t, 0, max(0, st.e.m.duration - 0.1)), st.e.w, st.e.h)
	engine_pause(&st.e, was)
	st.ended = false
	st.seek_count += 1
	st.seek_ms_sum += time.duration_milliseconds(time.since(t0))
}

seek_by :: proc(st: ^St, d: f64) {
	seek_to(st, engine_clock(&st.e) + d)
}

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	st.toast = strings.clone(msg, context.allocator)
	st.toast_t = ui.now + 2.2
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if st.view == .Library {
		library_keys(ui, app, st)
		return
	}
	player_keys(ui, app, st)
}

library_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		p.quit_app(app)
		return
	}
	n := len(st.lib)
	if n == 0 {
		return
	}
	if p.key_pressed(ui, p.KEY_DOWN) || p.key_pressed(ui, 'j') {
		st.sel = min(st.sel + 1, n - 1)
	}
	if p.key_pressed(ui, p.KEY_UP) || p.key_pressed(ui, 'k') {
		st.sel = max(st.sel - 1, 0)
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {st.sel = min(st.sel + 8, n - 1)}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {st.sel = max(st.sel - 8, 0)}
	if p.key_pressed(ui, p.KEY_HOME) {st.sel = 0}
	if p.key_pressed(ui, p.KEY_END) {st.sel = n - 1}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) ||
	   p.key_pressed(ui, p.KEY_SPACE) {
		start_playing(st)
	}
	if sc := ui.input.scroll.y; sc != 0 {
		st.lib_top = max(0, st.lib_top - int(sc))
	}
}

player_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		engine_destroy(&st.e)
		st.e = {}
		st.open = false
		st.view = .Library
		return
	}

	if p.key_pressed(ui, p.KEY_SPACE) || p.key_pressed(ui, 'k') {
		if st.ended {
			seek_to(st, 0)
			engine_pause(&st.e, false)
		} else {
			engine_pause(&st.e, !engine_paused(&st.e))
		}
	}

	if !st.open {
		return
	}

	big := .Shift in ui.input.mods
	if p.key_pressed(ui, p.KEY_RIGHT) || p.key_pressed(ui, 'l') {
		seek_by(st, big ? SEEK_BIG : SEEK_STEP)
	}
	if p.key_pressed(ui, p.KEY_LEFT) || p.key_pressed(ui, 'h') {
		seek_by(st, big ? -SEEK_BIG : -SEEK_STEP)
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		seek_to(st, 0)
	}
	if p.key_pressed(ui, p.KEY_END) {
		seek_to(st, max(0, st.e.m.duration - 3))
	}
	// Digits jump by tenths, which is the one seek gesture every player shares.
	for d in 0 ..< 10 {
		if p.key_pressed(ui, u32('0' + d)) {
			seek_to(st, st.e.m.duration * f64(d) / 10)
		}
	}

	// Frame stepping. Forward is exact: pause and let one frame through.
	// Backwards has to re-seek, because a pipe only runs one way.
	if p.key_pressed(ui, '.') || p.key_pressed(ui, '>') {
		engine_pause(&st.e, true)
		step_frame(st, 1)
	}
	if p.key_pressed(ui, ',') || p.key_pressed(ui, '<') {
		engine_pause(&st.e, true)
		step_frame(st, -1)
	}

	if p.key_pressed(ui, p.KEY_UP) {
		engine_set_volume(&st.e, st.e.volume + 0.05)
		toast(st, ui, fmt.tprintf("Volume %d%%", int(st.e.volume * 100 + 0.5)))
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		engine_set_volume(&st.e, st.e.volume - 0.05)
		toast(st, ui, fmt.tprintf("Volume %d%%", int(st.e.volume * 100 + 0.5)))
	}
	if p.key_pressed(ui, 'm') {
		engine_mute(&st.e, !st.e.muted)
		toast(st, ui, st.e.muted ? "Muted" : "Unmuted")
	}
	if p.key_pressed(ui, 'i') {
		st.info = !st.info
	}
	if p.key_pressed(ui, 's') {
		st.stats = !st.stats
	}
	if p.key_pressed(ui, 'n') && st.sel + 1 < len(st.lib) {
		st.sel += 1
		start_playing(st)
	}
	if p.key_pressed(ui, 'p') && st.sel > 0 {
		st.sel -= 1
		start_playing(st)
	}
	if sc := ui.input.scroll.y; sc != 0 {
		engine_set_volume(&st.e, st.e.volume + f32(sc) * 0.05)
	}
}

// step_frame moves exactly one frame. Forward it waits for the next decoded
// frame rather than guessing; backwards it seeks to the previous frame's time.
step_frame :: proc(st: ^St, d: int) {
	fps := st.e.fps > 0 ? st.e.fps : 25
	if d > 0 {
		target := st.e.cur_pts + 1 / fps
		// Give the reader a moment; the ring is normally already ahead.
		for _ in 0 ..< 240 {
			if engine_take(&st.e, target + 1e-4) {
				return
			}
			time.sleep(1 * time.Millisecond)
		}
		return
	}
	seek_to(st, max(0, st.e.cur_pts - 1 / fps - 1e-4))
	// A seek starts paused-but-empty; pull the first frame so the picture
	// actually moves back.
	for _ in 0 ..< 600 {
		if engine_take(&st.e, st.e.base + 1e-4) {
			return
		}
		time.sleep(1 * time.Millisecond)
	}
}
