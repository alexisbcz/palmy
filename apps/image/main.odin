package main

// palmy image — an image viewer.
//
// Open a file and it shows that file, with the rest of the folder behind the
// thumbnail strip. Open nothing and it shows a library: the places on this
// machine that hold pictures, plus what you looked at last.
//
// Zoom, pan and rotate are done by the app rather than by palmy: `p.image`
// scales and centres, which is enough for a picture in a card and not enough
// for a viewer, so the canvas is driven directly through `p.pixels` and
// `p.draw_image`. Decoding is on a worker thread — see loader.odin.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1240
WIN_H :: 800

KEY_KP_ADD :: 0xffab
KEY_KP_SUB :: 0xffad

ZOOM_MIN :: f32(0.02)
ZOOM_MAX :: f32(40)
ZOOM_STEP :: f32(1.25)

STRIP_H :: 96
PANEL_W :: 288

View :: enum u8 {
	Library,
	Viewer,
	Grid,
}

// Place is a folder offered on the library screen.
Place :: struct {
	path:  string,
	label: string,
	count: int,
}

// Row is one selectable line on the library screen.
Row_Kind :: enum u8 {
	Header,
	Place,
	Recent,
}

Row :: struct {
	kind:  Row_Kind,
	text:  string,
	sub:   string,
	path:  string, // folder for Place, file for Recent
	count: int,
	ic:    p.Icon,
}

St :: struct {
	view:        View,
	dir:         string,
	shots:       []Shot,
	sel:         int,
	ld:          Loader,

	// The decoded image on screen, owned by the UI thread.
	cur:         p.Image,
	cur_idx:     int,
	cur_ok:      bool,
	cur_ms:      f64,
	cur_err:     string,

	// Rotation produces its own pixels, cached until `rot` or `cur` changes.
	rot:         int,
	rot_img:     p.Image,
	rot_owned:   bool,
	rot_for:     int,
	rot_of:      int,

	// View transform.
	fit:         bool,
	scale:       f32,
	pan:         [2]f32,
	view_rect:   p.Rect,
	drag:        bool,
	drag_from:   [2]f32,
	drag_pan:    [2]f32,

	// Chrome.
	shown:       p.Image,
	grid_rows:   int,
	info:        bool,
	strip:       bool,
	grid_cols:   int,
	grid_top:    int,
	toast:       string,
	toast_t:     f64,

	// Library.
	rows:        []Row,
	lib_sel:     int,
	lib_top:     int,
	lib_vis:     int,

	mouse:       [2]f32,
	moved:       bool,
	started:     bool,
	scale_px:    f32,

	// The shared Open dialog, and what it was opened for. See pick.odin.
	pick:        kit.Pick,
	pick_use:    Pick_Use,
}

main :: proc() {
	// The command line is the other front end over the same core (core.odin,
	// cli.odin). `--selftest` is routed by it, as it always was; a bare path
	// — and the older `<media> --shot out.png [seconds] [keys]` — comes back
	// here.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	shot_out, shot_secs, shot_keys, want_shot := shot_requested()
	// takes_path hands over any word that is not a verb (C3: the kit does not
	// check it). A word that names nothing is a mistyped command, not a
	// picture, and must not open a window.
	// A path that is merely missing still opens the library with "no such
	// file", as it always has.
	if first := first_target(shot_strip(os.args[1:])); first != "" && !os.exists(first) && strings.index_any(first, "./~") < 0 {
		fmt.eprintfln("image: %q is not a command or a file that exists", first)
		fmt.eprint(kit.cli_help_text(surface()))
		os.exit(kit.EXIT_USAGE)
	}

	app: ^p.App
	if !want_shot {
		err: string
		app, err = kit.start(
			{
				title = "Images",
				app_id = "palmy",
				width = WIN_W,
				height = WIN_H,
				root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
			},
		)
		if err != "" {
			fmt.eprintfln("image: %s", err)
			os.exit(1)
		}
	} else {
		sc.register_shadcn_theme()
	}
	defer if app != nil {p.destroy(app)}
	register_dark_theme()

	st := st_make()
	st_open(&st, first_target(shot_strip(os.args[1:])))
	defer loader_destroy(&st.ld)
	defer kit.pick_destroy(&st.pick)

	if want_shot {
		st.view_rect = shot_view_rect()
		run_shot(&st, shot_out, shot_secs, shot_keys)
		return
	}

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		st.scale_px = f32(p.window_scale(ui))

		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		pump(&st)
		handle_keys(ui, app, &st)
		pump(&st)

		switch st.view {
		case .Library:
			build_library_ui(ui, &st)
		case .Viewer:
			build_viewer(ui, &st)
		case .Grid:
			build_grid(ui, &st)
		}
		pick_overlay(ui, &st)

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			}
			p.redraw(ui)
		}
		if loader_busy(&st.ld) {
			p.redraw(ui)
		}
	}
}

// st_make is the viewer's starting state, for the window and for `image
// render` alike.
st_make :: proc() -> St {
	return St {
		cur_idx = -1,
		rot_for = -1,
		rot_of = -1,
		fit = true,
		scale = 1,
		strip = true,
		info = true,
		grid_cols = 5,
		scale_px = 1,
	}
}

// first_target is the first word on the line that is not a flag.
first_target :: proc(args: []string) -> string {
	for a in args {
		if !strings.has_prefix(a, "-") {
			return a
		}
	}
	return ""
}

// shot_view_rect is the canvas an offscreen render paints into: the window
// less its chrome, which the frame loop would otherwise measure.
shot_view_rect :: proc() -> p.Rect {
	return {0, TOPBAR_H, f32(WIN_W) - PANEL_W - 1, f32(WIN_H) - TOPBAR_H - STATUS_H - STRIP_H - 1}
}

// st_open decides where the viewer lands: a file opens in the viewer, a folder
// in the grid, nothing at all in the library.
st_open :: proc(st: ^St, target: string) {
	if target == "" {
		build_library(st)
		return
	}
	abs := absolute(target)
	fi, serr := os.stat(abs, context.allocator)
	if serr != nil {
		st.cur_err = fmt.aprintf("%s: no such file", target)
		build_library(st)
		st.view = .Library
		return
	}
	if fi.type == .Directory {
		open_folder(st, abs, "")
		st.view = .Grid
		return
	}
	open_folder(st, dir_of(abs), abs)
	st.view = .Viewer
	if st.sel < 0 || len(st.shots) == 0 {
		// Something that is not an image at all: say so, and stay on the
		// library so there is somewhere to go.
		st.cur_err = fmt.aprintf("%s is not an image palmy can decode", base_of(abs))
		build_library(st)
		st.view = .Library
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
	if path == "." || path == "./" {
		return strings.clone(cwd)
	}
	return fmt.aprintf("%s/%s", cwd, strings.trim_prefix(path, "./"))
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

open_folder :: proc(st: ^St, dir: string, select_path: string) {
	loader_destroy(&st.ld)
	drop_current(st)

	st.dir = strings.clone(dir)
	st.shots = scan_dir(dir)
	st.sel = 0
	if select_path != "" {
		found := false
		for s, i in st.shots {
			if s.path == select_path {
				st.sel = i
				found = true
				break
			}
		}
		if !found {
			st.sel = -1
		}
	}
	st.grid_top = 0
	st.rot = 0
	st.fit = true
	st.pan = {}
	if len(st.shots) > 0 {
		loader_start(&st.ld, st.shots)
		if st.sel >= 0 {
			loader_want(&st.ld, st.sel)
			loader_set_hint(&st.ld, st.sel)
		}
	}
}

drop_current :: proc(st: ^St) {
	if st.rot_owned {
		p.image_destroy(&st.rot_img)
	}
	st.rot_img = {}
	st.rot_owned = false
	st.rot_for = -1
	st.rot_of = -1
	if st.cur.w > 0 {
		p.image_destroy(&st.cur)
	}
	st.cur = {}
	st.cur_idx = -1
	st.cur_ok = false
}

// pump collects whatever the loader has finished and keeps the request in step
// with the selection.
pump :: proc(st: ^St) {
	if len(st.shots) == 0 || st.sel < 0 {
		return
	}
	if st.cur_idx != st.sel {
		loader_want(&st.ld, st.sel)
	}
	if img, ok, failed, ms := loader_take(&st.ld, st.sel); ok {
		if st.rot_owned {
			p.image_destroy(&st.rot_img)
		}
		st.rot_img = {}
		st.rot_owned = false
		st.rot_for = -1
		if st.cur.w > 0 {
			p.image_destroy(&st.cur)
		}
		st.cur = img
		st.cur_idx = st.sel
		st.cur_ok = !failed && img.w > 0
		st.cur_ms = ms
		probe(&st.shots[st.sel])
		// A fresh picture starts fitted; keeping a 400% zoom across a Right
		// press is disorienting.
		st.fit = true
		st.pan = {}
	}
}

// display is the image actually painted: the decode, turned by `rot`.
display :: proc(st: ^St) -> p.Image {
	if !st.cur_ok || st.cur.w <= 0 {
		return {}
	}
	q := ((st.rot % 4) + 4) % 4
	if q == 0 {
		return st.cur
	}
	if st.rot_for == q && st.rot_of == st.cur_idx && st.rot_img.w > 0 {
		return st.rot_img
	}
	if st.rot_owned {
		p.image_destroy(&st.rot_img)
	}
	img, owned := rotated(st.cur, q)
	st.rot_img = img
	st.rot_owned = owned
	st.rot_for = q
	st.rot_of = st.cur_idx
	return st.rot_img
}

current_shot :: proc(st: ^St) -> ^Shot {
	if st.sel < 0 || st.sel >= len(st.shots) {
		return nil
	}
	return &st.shots[st.sel]
}

// ---------------------------------------------------------------------------
// The view transform
// ---------------------------------------------------------------------------

fit_scale :: proc(st: ^St, img: p.Image) -> f32 {
	if img.w <= 0 || st.view_rect.w <= 0 {
		return 1
	}
	s := min(st.view_rect.w / f32(img.w), st.view_rect.h / f32(img.h))
	// Fitting never magnifies: a 32×32 icon should not fill the window.
	return min(s, 1)
}

effective_scale :: proc(st: ^St, img: p.Image) -> f32 {
	return st.fit ? fit_scale(st, img) : st.scale
}

set_zoom :: proc(st: ^St, s: f32) {
	img := display(st)
	st.scale = clamp(s, ZOOM_MIN, ZOOM_MAX)
	st.fit = false
	clamp_pan(st, img)
}

zoom_by :: proc(st: ^St, f: f32) {
	img := display(st)
	set_zoom(st, effective_scale(st, img) * f)
}

// clamp_pan keeps the picture anchored: an axis smaller than the viewport is
// centred and cannot be dragged, a larger one cannot be pulled past its edge.
clamp_pan :: proc(st: ^St, img: p.Image) {
	if img.w <= 0 {
		st.pan = {}
		return
	}
	s := effective_scale(st, img)
	w := f32(img.w) * s
	h := f32(img.h) * s
	mx := max(0, (w - st.view_rect.w) / 2)
	my := max(0, (h - st.view_rect.h) / 2)
	st.pan.x = clamp(st.pan.x, -mx, mx)
	st.pan.y = clamp(st.pan.y, -my, my)
}

// pannable reports whether the picture overflows its viewport, which is what
// decides whether the arrow keys pan or step to the next file.
pannable :: proc(st: ^St) -> bool {
	img := display(st)
	if img.w <= 0 {
		return false
	}
	s := effective_scale(st, img)
	return f32(img.w) * s > st.view_rect.w + 1 || f32(img.h) * s > st.view_rect.h + 1
}

step :: proc(st: ^St, d: int) {
	if len(st.shots) == 0 {
		return
	}
	n := len(st.shots)
	st.sel = ((st.sel + d) % n + n) % n
	st.rot = 0
	st.fit = true
	st.pan = {}
	loader_want(&st.ld, st.sel)
	loader_set_hint(&st.ld, st.sel)
}

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	st.toast = strings.clone(msg, context.allocator)
	st.toast_t = ui.now + 2.6
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// The file dialog owns the keyboard while it is up; it reads its own
	// input in `pick_overlay`, during the draw pass.
	if kit.pick_active(&st.pick) {
		return
	}
	// Open works from all three screens, which is the point of having it.
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(st, .File)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl, .Shift}) || p.shortcut(ui, 'O', {.Ctrl, .Shift}) {
		begin_pick(st, .Folder)
		return
	}

	switch st.view {
	case .Library:
		library_keys(ui, app, st)
	case .Grid:
		grid_keys(ui, app, st)
	case .Viewer:
		viewer_keys(ui, app, st)
	}
}

viewer_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		if len(st.shots) > 0 {
			st.view = .Grid
			keep_grid_visible(st)
		} else {
			p.quit_app(app)
		}
		return
	}
	if p.key_pressed(ui, 'g') {
		st.view = .Grid
		keep_grid_visible(st)
		return
	}
	if p.key_pressed(ui, 'b') || p.key_pressed(ui, p.KEY_BACKSPACE) {
		build_library(st)
		st.view = .Library
		return
	}

	if p.key_pressed(ui, 'i') {
		st.info = !st.info
	}
	if p.key_pressed(ui, 't') {
		st.strip = !st.strip
	}

	// Zoom.
	if p.key_pressed(ui, '+') || p.key_pressed(ui, '=') || p.key_pressed(ui, KEY_KP_ADD) {
		zoom_by(st, ZOOM_STEP)
	}
	if p.key_pressed(ui, '-') || p.key_pressed(ui, KEY_KP_SUB) {
		zoom_by(st, 1 / ZOOM_STEP)
	}
	if p.key_pressed(ui, '0') {
		st.fit = true
		st.pan = {}
	}
	if p.key_pressed(ui, '1') {
		set_zoom(st, 1)
		st.pan = {}
	}
	if p.key_pressed(ui, 'f') {
		// Fill the window: the other half of what a viewer means by "fit".
		img := display(st)
		if img.w > 0 && st.view_rect.w > 0 {
			set_zoom(st, max(st.view_rect.w / f32(img.w), st.view_rect.h / f32(img.h)))
			st.pan = {}
		}
	}

	// Rotate.
	if p.key_pressed(ui, 'r') {
		st.rot += 1
		st.pan = {}
		toast(st, ui, fmt.tprintf("Rotated to %d°", (((st.rot % 4) + 4) % 4) * 90))
	}
	if p.key_pressed(ui, 'R') {
		st.rot -= 1
		st.pan = {}
		toast(st, ui, fmt.tprintf("Rotated to %d°", (((st.rot % 4) + 4) % 4) * 90))
	}

	// Navigation, or panning when the picture is bigger than the window.
	pan_mode := pannable(st)
	nudge := f32(80)
	if .Shift in ui.input.mods {
		nudge = 280
	}
	if pan_mode {
		if p.key_pressed(ui, p.KEY_LEFT) {st.pan.x += nudge}
		if p.key_pressed(ui, p.KEY_RIGHT) {st.pan.x -= nudge}
		if p.key_pressed(ui, p.KEY_UP) {st.pan.y += nudge}
		if p.key_pressed(ui, p.KEY_DOWN) {st.pan.y -= nudge}
		clamp_pan(st, display(st))
	} else {
		if p.key_pressed(ui, p.KEY_LEFT) {step(st, -1)}
		if p.key_pressed(ui, p.KEY_RIGHT) {step(st, 1)}
	}
	if p.key_pressed(ui, 'n') || p.key_pressed(ui, p.KEY_PAGE_DOWN) || p.key_pressed(ui, p.KEY_SPACE) {
		step(st, 1)
	}
	if p.key_pressed(ui, 'p') || p.key_pressed(ui, p.KEY_PAGE_UP) {
		step(st, -1)
	}
	if p.key_pressed(ui, p.KEY_HOME) && len(st.shots) > 0 {
		st.sel = 0
		st.fit = true
		st.pan = {}
		loader_want(&st.ld, st.sel)
	}
	if p.key_pressed(ui, p.KEY_END) && len(st.shots) > 0 {
		st.sel = len(st.shots) - 1
		st.fit = true
		st.pan = {}
		loader_want(&st.ld, st.sel)
	}
	// Ctrl-S keeps what is on screen: a PNG copy next to the original, turned
	// the way it is shown, through the same encoder `image rotate` uses.
	if p.shortcut(ui, 's', {.Ctrl}) {
		if s := current_shot(st); s != nil {
			if out, ok, why := save_copy(st); ok {
				toast(st, ui, fmt.tprintf("Saved %s", base_of(out)))
			} else {
				toast(st, ui, fmt.tprintf("Not saved: %s", why))
			}
		}
	}
	if p.shortcut(ui, 'c', {.Ctrl}) {
		if s := current_shot(st); s != nil {
			if kit.clipboard_set(s.path) {
				toast(st, ui, "Path copied")
			} else {
				toast(st, ui, "wl-copy is not installed")
			}
		}
	}

	// Scroll wheel zooms, which is what every viewer does.
	if sc := ui.input.scroll.y; sc != 0 {
		zoom_by(st, sc > 0 ? ZOOM_STEP : 1 / ZOOM_STEP)
	}
}

grid_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		build_library(st)
		st.view = .Library
		return
	}
	if p.key_pressed(ui, 'b') || p.key_pressed(ui, p.KEY_BACKSPACE) {
		build_library(st)
		st.view = .Library
		return
	}
	if p.key_pressed(ui, 'g') || p.key_pressed(ui, p.KEY_RETURN) ||
	   p.key_pressed(ui, p.KEY_KP_ENTER) {
		if len(st.shots) > 0 {
			if st.sel < 0 {st.sel = 0}
			st.view = .Viewer
			st.fit = true
			st.pan = {}
			loader_want(&st.ld, st.sel)
		}
		return
	}
	if p.key_pressed(ui, 'i') {
		st.info = !st.info
	}

	n := len(st.shots)
	if n == 0 {
		return
	}
	cols := max(1, st.grid_cols)
	move :: proc(st: ^St, d: int) {
		st.sel = clamp(st.sel + d, 0, len(st.shots) - 1)
		loader_set_hint(&st.ld, st.sel)
	}
	if st.sel < 0 {st.sel = 0}
	if p.key_pressed(ui, p.KEY_LEFT) {move(st, -1)}
	if p.key_pressed(ui, p.KEY_RIGHT) {move(st, 1)}
	if p.key_pressed(ui, p.KEY_UP) {move(st, -cols)}
	if p.key_pressed(ui, p.KEY_DOWN) {move(st, cols)}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {move(st, -cols * 3)}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {move(st, cols * 3)}
	if p.key_pressed(ui, p.KEY_HOME) {move(st, -n)}
	if p.key_pressed(ui, p.KEY_END) {move(st, n)}
	if sc := ui.input.scroll.y; sc != 0 {
		st.grid_top = max(0, st.grid_top - int(sc))
	}
	keep_grid_visible(st)
}

library_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'q') {
		p.quit_app(app)
		return
	}
	if len(st.rows) == 0 {
		return
	}
	d := 0
	if p.key_pressed(ui, p.KEY_DOWN) || p.key_pressed(ui, 'j') {d = 1}
	if p.key_pressed(ui, p.KEY_UP) || p.key_pressed(ui, 'k') {d = -1}
	if d != 0 {
		i := st.lib_sel
		for _ in 0 ..< len(st.rows) {
			i = clamp(i + d, 0, len(st.rows) - 1)
			if st.rows[i].kind != .Header {
				st.lib_sel = i
				break
			}
			if i == 0 || i == len(st.rows) - 1 {
				break
			}
		}
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		st.lib_sel = first_selectable(st.rows)
	}
	if p.key_pressed(ui, p.KEY_END) {
		for i := len(st.rows) - 1; i >= 0; i -= 1 {
			if st.rows[i].kind != .Header {
				st.lib_sel = i
				break
			}
		}
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) ||
	   p.key_pressed(ui, p.KEY_SPACE) {
		open_row(st)
	}
	if sc := ui.input.scroll.y; sc != 0 {
		st.lib_top = max(0, st.lib_top - int(sc))
	}
}

open_row :: proc(st: ^St) {
	if st.lib_sel < 0 || st.lib_sel >= len(st.rows) {
		return
	}
	r := st.rows[st.lib_sel]
	switch r.kind {
	case .Header:
	case .Place:
		open_folder(st, r.path, "")
		st.view = .Grid
		st.cur_err = ""
	case .Recent:
		open_folder(st, dir_of(r.path), r.path)
		st.view = st.sel >= 0 ? .Viewer : .Grid
		st.cur_err = ""
		push_recent(r.path)
	}
}

first_selectable :: proc(rows: []Row) -> int {
	for r, i in rows {
		if r.kind != .Header {
			return i
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// The library screen's content
// ---------------------------------------------------------------------------

build_library :: proc(st: ^St) {
	rows := make([dynamic]Row)

	recents := load_recent()
	if len(recents) > 0 {
		append(&rows, Row{kind = .Header, text = "Recent"})
		for path in recents {
			if !os.exists(path) {
				continue
			}
			size := i64(0)
			if fi, err := os.stat(path, context.temp_allocator); err == nil {
				size = fi.size
			}
			w, h, _, ok := p.image_size(path)
			sub := ok \
				? fmt.aprintf("%s · %d × %d · %s", home_relative(dir_of(path)), w, h, human_bytes(size)) \
				: fmt.aprintf("%s · %s", home_relative(dir_of(path)), human_bytes(size))
			append(
				&rows,
				Row {
					kind = .Recent,
					text = strings.clone(base_of(path)),
					sub = sub,
					path = strings.clone(path),
					ic = IC_FILE_IMAGE,
				},
			)
		}
	}

	places := find_places()
	if len(places) > 0 {
		append(&rows, Row{kind = .Header, text = "Places"})
		for pl in places {
			append(
				&rows,
				Row {
					kind = .Place,
					text = pl.label,
					sub = fmt.aprintf("%s", home_relative(pl.path)),
					path = pl.path,
					count = pl.count,
					ic = IC_FOLDER,
				},
			)
		}
	}

	st.rows = rows[:]
	st.lib_sel = first_selectable(st.rows)
	st.lib_top = 0
}

find_places :: proc() -> []Place {
	out := make([dynamic]Place)
	home, herr := os.user_home_dir(context.temp_allocator)

	add :: proc(out: ^[dynamic]Place, path, label: string) {
		fi, err := os.stat(path, context.temp_allocator)
		if err != nil || fi.type != .Directory {
			return
		}
		n := count_images(path)
		if n == 0 {
			return
		}
		append(out, Place{path = strings.clone(path), label = strings.clone(label), count = n})
	}

	if herr == nil {
		add(&out, fmt.tprintf("%s/Pictures", home), "Pictures")
		add(&out, fmt.tprintf("%s/Downloads", home), "Downloads")
		add(&out, fmt.tprintf("%s/Desktop", home), "Desktop")
		add(&out, fmt.tprintf("%s/Documents", home), "Documents")
		add(&out, fmt.tprintf("%s/.cache/omarchy/image-selector", home), "Wallpaper cache")
	}
	if extra := os.get_env("PALMY_IMAGE_DIR", context.temp_allocator); extra != "" {
		add(&out, extra, base_of(extra))
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	add(&out, cwd, "Working directory")
	return out[:]
}

count_images :: proc(dir: string) -> int {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return 0
	}
	n := 0
	for fi in infos {
		if fi.type != .Directory && p.is_image_path(fi.name) {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Recents
// ---------------------------------------------------------------------------

RECENT_MAX :: 8

recent_path :: proc(allocator := context.allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.concatenate({home, "/.cache/palmy-image/recent"}, allocator)
}

load_recent :: proc() -> []string {
	out := make([dynamic]string)
	path := recent_path(context.temp_allocator)
	if path == "" {
		return out[:]
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l != "" && len(out) < RECENT_MAX {
			append(&out, strings.clone(l))
		}
	}
	return out[:]
}

push_recent :: proc(file: string) {
	path := recent_path(context.temp_allocator)
	if path == "" {
		return
	}
	old := load_recent()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, file)
	strings.write_byte(&b, '\n')
	n := 1
	for o in old {
		if o == file || n >= RECENT_MAX {
			continue
		}
		strings.write_string(&b, o)
		strings.write_byte(&b, '\n')
		n += 1
	}
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(b))
}
