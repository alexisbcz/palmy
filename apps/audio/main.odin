package main

// palmy audio — a music player.
//
// ffmpeg decodes, pw-cat plays, and the position comes back as a byte count
// (engine.odin). Separately the whole track is decoded once to 8 kHz mono so
// the waveform, the spectrum and the oscilloscope are drawn from the real
// samples rather than from an animation (wave.odin).

import "core:fmt"
import "core:math/rand"
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
STATUS_H :: f32(30)
LIST_W :: f32(360)
WAVE_H :: f32(72)
TRANSPORT_H :: f32(88)

Vis_Mode :: enum u8 {
	Spectrum,
	Scope,
}

Track :: struct {
	path:   string,
	name:   string,
	dir:    string,
	size:   i64,
	mtime:  time.Time,
	probed: bool,
	m:      Media,
}

St :: struct {
	e:          Engine,
	a:          Analysis,

	list:       []Track,
	order:      []int, // play order, shuffled or not
	cur:        int, // index into list, -1 when nothing is loaded
	sel:        int,
	top:        int,
	vis:        int,
	err:        string,

	cover:      p.Image,
	cover_for:  int,
	cover_ok:   bool,

	bars:       [BARS]f32,
	scope_buf:  [512]f32,
	wave:       []f32,
	wave_cols:  int,
	wave_for:   int,
	wave_ready: bool,
	// How much the envelope had to be lifted to fill the strip; the
	// oscilloscope borrows it so both views agree about how loud the track is.
	gain:       f32,
	vis_mode:   Vis_Mode,

	repeat:     bool,
	shuffle:    bool,
	scrubbing:  bool,
	scrub_at:   f64,
	now:        f64,
	toast:      string,
	toast_t:    f64,

	mouse:      [2]f32,
	moved:      bool,
	started:    bool,
}

main :: proc() {
	for a in os.args[1:] {
		if a == "--selftest" {
			run_selftest()
			os.exit(failures == 0 ? 0 : 1)
		}
	}

	shot_out, shot_secs, shot_keys, want_shot := shot_requested()

	app: ^p.App
	if !want_shot {
		err: string
		app, err = kit.start(
			{
				title = "Audio",
				app_id = "palmy",
				width = WIN_W,
				height = WIN_H,
				root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
			},
		)
		if err != "" {
			fmt.eprintfln("audio: %s", err)
			os.exit(1)
		}
	} else {
		sc.register_shadcn_theme()
	}
	defer if app != nil {p.destroy(app)}
	register_dark_theme()

	st := St {
		cur       = -1,
		cover_for = -1,
		wave_for  = -1,
		gain      = 1,
	}
	engine_init(&st.e)

	target := ""
	for a in shot_strip(os.args[1:]) {
		if !strings.has_prefix(a, "-") {
			target = a
			break
		}
	}
	autoplay := ""
	if target != "" {
		abs := absolute(target)
		if fi, serr := os.stat(abs, context.allocator); serr == nil && fi.type == .Directory {
			st.list = scan_dir(abs)
		} else if serr == nil {
			st.list = scan_dir(dir_of(abs))
			if is_audio(abs) {
				autoplay = abs
			} else {
				st.err = fmt.aprintf("%s is not an audio file", base_of(abs))
			}
		} else {
			st.err = fmt.aprintf("%s: no such file", target)
			st.list = scan_library()
		}
	} else {
		st.list = scan_library()
	}
	rebuild_order(&st)
	if autoplay != "" {
		for t, i in st.list {
			if t.path == autoplay {
				st.sel = i
				play(&st, i)
				break
			}
		}
	}
	defer engine_stop(&st.e)
	defer analysis_stop(&st.a)

	if want_shot {
		run_shot(&st, shot_out, shot_secs, shot_keys)
		return
	}

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		if st.e.live {
			engine_tick(&st.e)
			st.now = engine_clock(&st.e)
			if engine_eof(&st.e) {
				advance(&st, 1, true)
			}
			if !engine_paused(&st.e) {
				p.redraw(ui)
			}
		}

		update_vis(&st)
		handle_keys(ui, app, &st)
		build(ui, &st)

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			}
			p.redraw(ui)
		}
		if ready, _, _, _ := analysis_ready(&st.a); !ready {
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

AUDIO_EXT := [?]string {
	".mp3",
	".flac",
	".ogg",
	".oga",
	".opus",
	".m4a",
	".aac",
	".wav",
	".wma",
	".aiff",
	".aif",
	".ape",
	".mka",
}

is_audio :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for e in AUDIO_EXT {
		if strings.has_suffix(lower, e) {
			return true
		}
	}
	return false
}

scan_dir :: proc(dir: string) -> []Track {
	out := make([dynamic]Track)
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		if fi.type == .Directory || !is_audio(fi.name) {
			continue
		}
		append(
			&out,
			Track {
				path = strings.clone(fi.fullpath),
				name = strings.clone(fi.name),
				dir = strings.clone(dir),
				size = fi.size,
				mtime = fi.modification_time,
			},
		)
	}
	slice.sort_by(out[:], proc(a, b: Track) -> bool {
		return strings.compare(
			strings.to_lower(a.name, context.temp_allocator),
			strings.to_lower(b.name, context.temp_allocator),
		) < 0
	})
	return out[:]
}

scan_library :: proc() -> []Track {
	out := make([dynamic]Track)
	seen := make(map[string]bool, context.temp_allocator)
	add :: proc(out: ^[dynamic]Track, seen: ^map[string]bool, dir: string) {
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		for t in scan_dir(dir) {
			append(out, t)
		}
	}
	if extra := os.get_env("PALMY_MEDIA_DIR", context.temp_allocator); extra != "" {
		for part in strings.split(extra, ":", context.temp_allocator) {
			add(&out, &seen, strings.trim_space(part))
		}
	}
	if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		add(&out, &seen, fmt.tprintf("%s/Music", home))
		add(&out, &seen, fmt.tprintf("%s/Downloads", home))
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	add(&out, &seen, cwd)
	return out[:]
}

// ensure_probed reads a track's tags the first time it is needed, so a folder
// of five hundred files does not cost five hundred ffprobe runs on open.
ensure_probed :: proc(t: ^Track) {
	if t.probed {
		return
	}
	t.probed = true
	t.m = probe_file(t.path)
}

track_title :: proc(t: ^Track) -> string {
	ensure_probed(t)
	if t.m.title != "" {
		return t.m.title
	}
	name := t.name
	if i := strings.last_index_byte(name, '.'); i > 0 {
		return name[:i]
	}
	return name
}

track_artist :: proc(t: ^Track) -> string {
	ensure_probed(t)
	return t.m.artist != "" ? t.m.artist : "Unknown artist"
}

current :: proc(st: ^St) -> ^Track {
	if st.cur < 0 || st.cur >= len(st.list) {
		return nil
	}
	return &st.list[st.cur]
}

selected :: proc(st: ^St) -> ^Track {
	if st.sel < 0 || st.sel >= len(st.list) {
		return nil
	}
	return &st.list[st.sel]
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

rebuild_order :: proc(st: ^St) {
	order := make([]int, len(st.list))
	for i in 0 ..< len(st.list) {
		order[i] = i
	}
	if st.shuffle {
		rand.shuffle(order)
	}
	delete(st.order)
	st.order = order
}

order_pos :: proc(st: ^St, idx: int) -> int {
	for v, i in st.order {
		if v == idx {
			return i
		}
	}
	return 0
}

play :: proc(st: ^St, idx: int, at: f64 = 0) {
	if idx < 0 || idx >= len(st.list) {
		return
	}
	t := &st.list[idx]
	ensure_probed(t)
	if !t.m.ok {
		st.err = fmt.aprintf("%s: %s", t.name, t.m.err)
		return
	}
	st.err = ""
	st.cur = idx
	engine_start(&st.e, t.m, at)
	if st.e.err != "" {
		st.err = strings.clone(st.e.err)
	}
	analysis_start(&st.a, t.path)
	st.wave_for = -1
	st.wave_ready = false
	load_cover(st, idx)
}

advance :: proc(st: ^St, d: int, auto := false) {
	if len(st.list) == 0 {
		return
	}
	if auto && st.repeat {
		play(st, st.cur, 0)
		return
	}
	pos := order_pos(st, st.cur) + d
	if pos < 0 {
		pos = len(st.order) - 1
	}
	if pos >= len(st.order) {
		if auto && !st.repeat {
			engine_stop(&st.e)
			return
		}
		pos = 0
	}
	nxt := st.order[pos]
	st.sel = nxt
	play(st, nxt, 0)
}

seek_to :: proc(st: ^St, t: f64) {
	cur := current(st)
	if cur == nil {
		return
	}
	was := engine_paused(&st.e)
	engine_start(&st.e, cur.m, clamp(t, 0, max(0, cur.m.duration - 0.1)))
	engine_pause(&st.e, was)
}

load_cover :: proc(st: ^St, idx: int) {
	if st.cover_for == idx {
		return
	}
	if st.cover.w > 0 {
		p.image_destroy(&st.cover)
	}
	st.cover = {}
	st.cover_ok = false
	st.cover_for = idx
	t := &st.list[idx]
	if !t.m.has_cover {
		return
	}
	path := extract_cover(t.path, path_key(t.path))
	if path == "" {
		return
	}
	img, ok := p.load_image(path)
	if ok {
		st.cover = img
		st.cover_ok = true
	}
}

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	st.toast = strings.clone(msg, context.allocator)
	st.toast_t = ui.now + 2.2
}

// ---------------------------------------------------------------------------
// The picture of the sound
// ---------------------------------------------------------------------------

update_vis :: proc(st: ^St) {
	ready, ok, _, _ := analysis_ready(&st.a)
	if !ready || !ok {
		for i in 0 ..< BARS {
			st.bars[i] *= 0.85
		}
		return
	}

	t := st.now
	playing := st.e.live && !engine_paused(&st.e)

	if st.vis_mode == .Spectrum {
		next: [BARS]f32
		if spectrum(&st.a, t, next[:]) && playing {
			for i in 0 ..< BARS {
				// Fast attack, slow release: the way an analyser is read.
				st.bars[i] = next[i] > st.bars[i] \
					? st.bars[i] + (next[i] - st.bars[i]) * 0.55 \
					: st.bars[i] * 0.86
			}
		} else if !playing {
			for i in 0 ..< BARS {
				st.bars[i] *= 0.90
			}
		}
	} else {
		if !scope(&st.a, t, st.scope_buf[:], 1200, st.gain) {
			for i in 0 ..< len(st.scope_buf) {
				st.scope_buf[i] = 0
			}
		}
	}
}

// ensure_wave recomputes the envelope only when the track or the width changes.
ensure_wave :: proc(st: ^St, cols: int) {
	ready, ok, _, _ := analysis_ready(&st.a)
	if !ready || !ok || cols <= 0 {
		return
	}
	if st.wave_for == st.cur && st.wave_cols == cols && st.wave_ready {
		return
	}
	if len(st.wave) != cols {
		delete(st.wave)
		st.wave = make([]f32, cols)
	}
	st.gain = peaks(&st.a, st.wave)
	st.wave_cols = cols
	st.wave_for = st.cur
	st.wave_ready = true
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		p.quit_app(app)
		return
	}

	n := len(st.list)
	if n > 0 {
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
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			play(st, st.sel)
		}
	}

	if p.key_pressed(ui, p.KEY_SPACE) {
		if !st.e.live {
			play(st, st.sel)
		} else {
			engine_pause(&st.e, !engine_paused(&st.e))
		}
	}
	if p.key_pressed(ui, 'n') {
		advance(st, 1)
	}
	if p.key_pressed(ui, 'p') {
		advance(st, -1)
	}
	if st.e.live {
		big := .Shift in ui.input.mods
		if p.key_pressed(ui, p.KEY_RIGHT) || p.key_pressed(ui, 'l') {
			seek_to(st, st.now + (big ? 30 : 5))
		}
		if p.key_pressed(ui, p.KEY_LEFT) || p.key_pressed(ui, 'h') {
			seek_to(st, st.now - (big ? 30 : 5))
		}
		for d in 0 ..< 10 {
			if p.key_pressed(ui, u32('0' + d)) {
				if c := current(st); c != nil {
					seek_to(st, c.m.duration * f64(d) / 10)
				}
			}
		}
	}
	if p.key_pressed(ui, '+') || p.key_pressed(ui, '=') {
		engine_set_volume(&st.e, st.e.volume + 0.05)
		toast(st, ui, fmt.tprintf("Volume %d%%", int(st.e.volume * 100 + 0.5)))
	}
	if p.key_pressed(ui, '-') {
		engine_set_volume(&st.e, st.e.volume - 0.05)
		toast(st, ui, fmt.tprintf("Volume %d%%", int(st.e.volume * 100 + 0.5)))
	}
	if p.key_pressed(ui, 'm') {
		engine_mute(&st.e, !st.e.muted)
		toast(st, ui, st.e.muted ? "Muted" : "Unmuted")
	}
	if p.key_pressed(ui, 'r') {
		st.repeat = !st.repeat
		toast(st, ui, st.repeat ? "Repeat one" : "Repeat off")
	}
	if p.key_pressed(ui, 's') {
		st.shuffle = !st.shuffle
		rebuild_order(st)
		toast(st, ui, st.shuffle ? "Shuffle on" : "Shuffle off")
	}
	if p.key_pressed(ui, 'v') {
		st.vis_mode = st.vis_mode == .Spectrum ? .Scope : .Spectrum
		toast(st, ui, st.vis_mode == .Spectrum ? "Spectrum" : "Oscilloscope")
	}
	if sc := ui.input.scroll.y; sc != 0 {
		st.top = max(0, st.top - int(sc))
	}
}
