package palmy

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"

// Config describes the window to open. Everything has a usable default, so
// `palmy.create({title = "Hello"})` is a complete program's worth of setup.
Config :: struct {
	title:      string,
	app_id:     string,
	width:      int,
	height:     int,
	min_width:  int,
	min_height: int,

	// Classes applied to the root element. The default is a dark page that
	// fills the window; set it to anything you like.
	root_class: string,

	// Ask the compositor to draw a title bar when it is willing to.
	decorate:   bool,

	// Redraw every vsync instead of only when something changed. Leave this
	// off for UIs; turn it on for animations driven outside of palmy.
	always:     bool,

	// Open as a wlr-layer-shell surface instead of an ordinary window: an
	// overlay the compositor places itself, which is what a launcher, panel or
	// notification wants. Requires a compositor with zwlr_layer_shell_v1.
	layer:          bool,
	layer_level:    Layer,
	layer_anchor:   Anchor,
	layer_keyboard: Keyboard_Mode,
	exclusive_zone: int,
	layer_margin:   [4]int, // top, right, bottom, left
}

App :: struct {
	win:        Window,
	fonts:      Fonts,
	ctx:        Ctx,
	canvas:     Canvas,
	cfg:        Config,

	open:       bool,
	first:      bool,
	quit:       bool,
	last:       time.Tick,
	direct:     bool,
	frames_shown: u64,
	fps:        f32,
	fps_accum:  f32,
	fps_count:  int,
}

// create connects to the compositor, opens a window and gets it configured.
// The returned App is heap allocated so that the context pointers handed to
// your frame body stay valid.
create :: proc(cfg: Config) -> (app: ^App, err: string) {
	app = new(App)
	app.cfg = cfg
	// A layer surface uses 0 to mean "whatever the compositor gives me" — that
	// is how you ask to fill the output when anchored to opposing edges, and
	// the compositor answers with the real size in its configure. Only an
	// ordinary window needs a default.
	if !cfg.layer {
		if app.cfg.width <= 0 {
			app.cfg.width = 960
		}
		if app.cfg.height <= 0 {
			app.cfg.height = 640
		}
	}
	if app.cfg.title == "" {
		app.cfg.title = "palmy"
	}
	if app.cfg.app_id == "" {
		app.cfg.app_id = "palmy"
	}
	if app.cfg.root_class == "" {
		app.cfg.root_class = "w-full h-full bg-slate-950 text-slate-200"
	}

	app.win.use_layer = cfg.layer
	app.win.layer = cfg.layer_level
	app.win.anchor = cfg.layer_anchor
	app.win.keyboard_mode = cfg.layer_keyboard
	app.win.exclusive_zone = cfg.exclusive_zone
	app.win.layer_margin = cfg.layer_margin
	if cfg.layer && cfg.layer_keyboard == .None {
		// A layer surface with no keyboard is almost never what is wanted.
		app.win.keyboard_mode = .Exclusive
	}

	if e := window_open(
		&app.win,
		app.cfg.title,
		app.cfg.app_id,
		app.cfg.width,
		app.cfg.height,
		app.cfg.decorate,
	); e != "" {
		free(app)
		return nil, strings.clone(e)
	}
	if cfg.min_width > 0 || cfg.min_height > 0 {
		set_min_size_window(&app.win, cfg.min_width, cfg.min_height)
	}

	fonts_init(&app.fonts)
	ctx_init(&app.ctx)
	app.ctx.app = app
	app.ctx.fonts = &app.fonts
	app.ctx.input = &app.win.input
	app.first = true
	app.last = time.tick_now()
	return app, ""
}

destroy :: proc(app: ^App) {
	if app == nil {
		return
	}
	canvas_destroy(&app.canvas)
	ctx_destroy(&app.ctx)
	fonts_destroy(&app.fonts)
	window_close(&app.win)
	free(app)
}

// quit_app asks the frame loop to stop after the current frame.
quit_app :: proc(app: ^App) {
	app.quit = true
}

// redraw forces another frame even if nothing changed.
redraw :: proc(ctx: ^Ctx) {
	ctx.redraw = true
}

// ---------------------------------------------------------------------------
// The frame loop
// ---------------------------------------------------------------------------

// frames drives the whole application:
//
//	for ui in palmy.frames(app) {
//		palmy.text(ui, "Hello", "text-2xl font-bold")
//	}
//
// Each iteration is one presented frame. The call blocks while the window is
// idle, so a palmy app uses no CPU when nothing is happening.
frames :: proc(app: ^App) -> (ctx: ^Ctx, ok: bool) {
	if app.open {
		finish_frame(app)
		app.open = false
	}
	if !wait_for_frame(app) {
		return nil, false
	}
	begin_frame(app)
	app.open = true
	return &app.ctx, true
}

// direct_frames is the no-UI loop: it hands you the window's pixel buffer each
// vsync and presents whatever you wrote.
//
//	for c in palmy.direct_frames(app) {
//		palmy.clear_canvas(c, palmy.hex(0x101826))
//	}
direct_frames :: proc(app: ^App) -> (c: ^Canvas, ok: bool) {
	app.direct = true
	if app.open {
		present_direct(app)
		app.open = false
	}
	if !wait_for_frame(app) {
		return nil, false
	}
	if !prepare_canvas(app) {
		return nil, false
	}
	tick(app)
	app.open = true
	return &app.canvas, true
}

@(private)
tick :: proc(app: ^App) {
	now := time.tick_now()
	dt := f32(time.duration_seconds(time.tick_diff(app.last, now)))
	app.last = now
	app.ctx.dt = clamp(dt, 0, 0.1)
	app.ctx.now += f64(app.ctx.dt)

	app.fps_accum += dt
	app.fps_count += 1
	if app.fps_accum >= 0.5 {
		app.fps = f32(app.fps_count) / app.fps_accum
		app.fps_accum = 0
		app.fps_count = 0
	}
}

@(private)
wait_for_frame :: proc(app: ^App) -> bool {
	w := &app.win
	for {
		if app.quit || w.should_close || w.conn.fatal != "" {
			return false
		}

		frame_watchdog(w)

		want := app.first ||
			app.direct ||
			app.cfg.always ||
			app.ctx.redraw ||
			app.ctx.animating ||
			w.input_dirty ||
			w.need_configure_ack

		if want && !w.frame_pending && next_buffer(w) != nil {
			// Wayland paces frames with a frame callback. The X11 core
			// protocol has no vsync at all, so `frame_hold_ms` supplies the
			// floor that keeps an animating app from repainting as fast as
			// the server can swallow it.
			if hold := frame_hold_ms(w); hold > 0 {
				if !window_wait(w, hold) {
					return false
				}
				pump_key_repeat(app)
				continue
			}
			w.input_dirty = false
			app.ctx.redraw = false
			return true
		}

		timeout := -1
		if w.repeat_key != 0 && w.repeat_rate > 0 {
			ms := int(time.duration_milliseconds(time.diff(time.now(), w.repeat_at)))
			timeout = clamp(ms, 0, 1000)
		} else if want {
			// Waiting on a frame callback or a free buffer.
			timeout = 50
		}

		if !window_wait(w, timeout) {
			return false
		}
		pump_key_repeat(app)
	}
}

@(private)
pump_key_repeat :: proc(app: ^App) {
	w := &app.win
	if w.repeat_key == 0 || w.repeat_rate <= 0 {
		return
	}
	if time.since(w.repeat_at) < 0 {
		return
	}
	feed_key(w, w.repeat_key, true)
	w.input_dirty = true
	interval := time.Duration(1000 / max(w.repeat_rate, 1)) * time.Millisecond
	w.repeat_at = time.time_add(time.now(), interval)
}

@(private)
prepare_canvas :: proc(app: ^App) -> bool {
	w := &app.win
	if _, e := apply_pending(w); e != "" {
		w.conn.fatal = strings.clone(e)
		return false
	}
	b := next_buffer(w)
	if b == nil {
		return false
	}
	app.canvas.px = b.px
	app.canvas.w = b.w
	app.canvas.h = b.h
	app.canvas.scale = f32(w.scale)
	reset_clip(&app.canvas)
	return true
}

@(private)
begin_frame :: proc(app: ^App) {
	w := &app.win
	if !prepare_canvas(app) {
		return
	}
	tick(app)
	begin_ui(&app.ctx, &w.input, {f32(w.width), f32(w.height)}, app.cfg.root_class)
}

// begin_ui starts a frame: it recycles the arenas, routes last frame's input
// against last frame's tree, and opens the root element. The windowed loop and
// the offscreen renderer share it.
@(private)
begin_ui :: proc(ctx: ^Ctx, in_: ^Input, viewport: [2]f32, root_class: string) {
	ctx.input = in_
	ctx.frame += 1
	ctx.viewport = viewport
	ctx.mouse = in_.mouse
	ctx.animating = false

	// Swap the frame arenas: last frame's tree stays readable for hit testing
	// while this one is built.
	ctx.nodes, ctx.prev = ctx.prev, ctx.nodes
	ctx.arena, ctx.arena_old = ctx.arena_old, ctx.arena
	virtual.arena_free_all(&ctx.arena)
	ctx.alloc = virtual.arena_allocator(&ctx.arena)
	clear(&ctx.nodes)
	clear(&ctx.stack)
	clear(&ctx.seq)

	route_input(ctx)

	// The root element fills the viewport and seeds the inherited text style.
	root := push_node(ctx, .Box, root_class)
	ctx.nodes[root].style.w = px(viewport.x)
	ctx.nodes[root].style.h = px(viewport.y)
	append(&ctx.stack, root)

	if ctx.frame % 240 == 0 {
		sweep(ctx)
	}
}

// end_ui closes the frame: lay the tree out and paint it into `canvas`.
@(private)
end_ui :: proc(ctx: ^Ctx, canvas: ^Canvas) {
	clear(&ctx.stack)
	layout_tree(ctx, {0, 0, ctx.viewport.x, ctx.viewport.y})
	paint_tree(ctx, canvas)
}

@(private)
finish_frame :: proc(app: ^App) {
	w := &app.win
	ctx := &app.ctx

	b := next_buffer(w)
	if b == nil || app.canvas.px == nil {
		clear(&ctx.stack)
		return
	}
	end_ui(ctx, &app.canvas)
	present(w, b)
	app.frames_shown += 1

	clear_edges(&w.input)
	app.first = false

	// Layout, hit testing and painting all use the temp allocator for
	// per-frame scratch. Nothing outlives the frame it was built in, so it is
	// released here rather than growing for the life of the process.
	free_all(context.temp_allocator)
}

@(private)
present_direct :: proc(app: ^App) {
	w := &app.win
	b := next_buffer(w)
	if b == nil {
		return
	}
	present(w, b)
	app.frames_shown += 1
	clear_edges(&w.input)
	app.first = false
	free_all(context.temp_allocator)
}

@(private)
clear_edges :: proc(in_: ^Input) {
	in_.pressed = {}
	in_.released = {}
	in_.scroll = {}
	in_.mouse_delta = {}
	clear(&in_.keys)
	strings.builder_reset(&in_.text)
}

// sweep drops state for widgets that have not been seen for a while, so that
// long-lived apps with changing trees do not grow without bound.
@(private)
sweep :: proc(ctx: ^Ctx) {
	cutoff := ctx.frame > 600 ? ctx.frame - 600 : 0
	for id, w in ctx.widgets {
		if w.seen < cutoff {
			delete_key(&ctx.widgets, id)
		}
	}
	for id, slot in ctx.states {
		if slot.seen < cutoff {
			delete(slot.data)
			delete_key(&ctx.states, id)
		}
	}
}

// ---------------------------------------------------------------------------
// Hit testing and input routing
// ---------------------------------------------------------------------------

@(private)
Hit :: struct {
	id:        u64,
	focusable: bool,
	scroll_id: u64,
}

@(private)
hit_test :: proc(nodes: []Node, idx: int, p: [2]f32, out: ^Hit) -> bool {
	if idx < 0 || idx >= len(nodes) {
		return false
	}
	n := nodes[idx]
	if n.style.hidden || n.style.no_hit {
		return false
	}
	if !rect_contains(n.clip, p.x, p.y) {
		return false
	}
	inside := rect_contains(n.rect, p.x, p.y)
	if n.scrollable && inside {
		out.scroll_id = n.id
	}

	// Children paint later, so they win; walk them back to front.
	kids := make([dynamic]int, 0, 8, context.temp_allocator)
	for k := n.first_child; k >= 0; k = nodes[k].next {
		append(&kids, k)
	}
	for i in 1 ..< len(kids) {
		j := i
		for j > 0 && nodes[kids[j - 1]].style.z > nodes[kids[j]].style.z {
			kids[j - 1], kids[j] = kids[j], kids[j - 1]
			j -= 1
		}
	}
	#reverse for k in kids[:] {
		if hit_test(nodes, k, p, out) {
			return true
		}
	}

	if n.interactive && inside {
		out.id = n.id
		out.focusable = n.focusable
		return true
	}
	return false
}

// deepest_at finds the frontmost element containing a point, ignoring whether
// it takes input. The cursor is resolved from there.
@(private)
deepest_at :: proc(nodes: []Node, idx: int, p: [2]f32) -> int {
	if idx < 0 || idx >= len(nodes) {
		return -1
	}
	n := nodes[idx]
	if n.style.hidden || !rect_contains(n.clip, p.x, p.y) || !rect_contains(n.rect, p.x, p.y) {
		return -1
	}

	kids := make([dynamic]int, 0, 8, context.temp_allocator)
	for k := n.first_child; k >= 0; k = nodes[k].next {
		append(&kids, k)
	}
	for i in 1 ..< len(kids) {
		j := i
		for j > 0 && nodes[kids[j - 1]].style.z > nodes[kids[j]].style.z {
			kids[j - 1], kids[j] = kids[j], kids[j - 1]
			j -= 1
		}
	}
	#reverse for k in kids[:] {
		if d := deepest_at(nodes, k, p); d >= 0 {
			return d
		}
	}
	return idx
}

// cursor_at walks up from the deepest element under the pointer to the first
// one that asks for a particular cursor, the same way CSS inherits it.
@(private)
cursor_at :: proc(nodes: []Node, idx: int) -> Cursor {
	i := idx
	for i >= 0 {
		if nodes[i].style.cursor != .Inherit {
			return nodes[i].style.cursor
		}
		i = nodes[i].parent
	}
	return .Default
}

@(private)
route_input :: proc(ctx: ^Ctx) {
	in_ := ctx.input

	h: Hit
	if in_.over_surface && len(ctx.prev) > 0 {
		hit_test(ctx.prev[:], 0, in_.mouse, &h)
	}
	ctx.hot = h.id

	if ctx.app != nil && in_.over_surface && len(ctx.prev) > 0 {
		deepest := deepest_at(ctx.prev[:], 0, in_.mouse)
		shape := deepest >= 0 ? cursor_at(ctx.prev[:], deepest) : Cursor.Default
		window_set_cursor(&ctx.app.win, shape)
	}

	if in_.pressed[.Left] {
		ctx.active = ctx.hot
		if h.focusable {
			ctx.focus = ctx.hot
		} else {
			ctx.focus = 0
		}
	}
	ctx.clicked = 0
	if in_.released[.Left] {
		if ctx.active != 0 && ctx.active == ctx.hot {
			ctx.clicked = ctx.active
		}
		ctx.active = 0
	}
	if !in_.down[.Left] {
		ctx.active = 0
	}

	// Wheel scrolling applies to the innermost scrollable region under the
	// pointer, which is what every other toolkit does.
	if (in_.scroll.x != 0 || in_.scroll.y != 0) && h.scroll_id != 0 {
		w := widget_of(ctx, h.scroll_id)
		w.scroll.y += in_.scroll.y * 2.5
		w.scroll.x += in_.scroll.x * 2.5
	}

	// Tab moves keyboard focus through the focusable elements in tree order.
	if key_pressed(ctx, KEY_TAB) {
		cycle_focus(ctx, .Shift in in_.mods)
	}
}

@(private)
cycle_focus :: proc(ctx: ^Ctx, backwards: bool) {
	order := make([dynamic]u64, 0, 16, context.temp_allocator)
	collect :: proc(nodes: []Node, idx: int, out: ^[dynamic]u64) {
		if idx < 0 {
			return
		}
		n := nodes[idx]
		if n.style.hidden {
			return
		}
		if n.focusable {
			append(out, n.id)
		}
		for k := n.first_child; k >= 0; k = nodes[k].next {
			collect(nodes, k, out)
		}
	}
	if len(ctx.prev) > 0 {
		collect(ctx.prev[:], 0, &order)
	}
	if len(order) == 0 {
		return
	}

	at := -1
	for id, i in order {
		if id == ctx.focus {
			at = i
			break
		}
	}
	step := backwards ? -1 : 1
	next := at < 0 ? (backwards ? len(order) - 1 : 0) : (at + step + len(order)) % len(order)
	ctx.focus = order[next]
}

// ---------------------------------------------------------------------------
// Input queries
// ---------------------------------------------------------------------------

// key_pressed reports whether a keysym was pressed this frame. Use the KEY_*
// constants, or a character literal for printable keys.
//
// `include_repeat` decides whether auto-repeat counts. Leave it on for a
// movement key, where holding the key should keep moving; turn it off for a
// command, where one press must mean one action — a held Backspace that walks
// a file browser up three directories is this distinction going wrong.
//
// This answers "was it pressed", not "how many times". Several presses can
// land in one frame, and they collapse to a single `true` — two taps of `j`
// move one row, and synthetic input hits this immediately because a driver
// script sends keys far faster than a human. When one press must equal one
// step — navigation, a nudge, stepping a value — count with `key_count`
// instead.
key_pressed :: proc(ctx: ^Ctx, sym: u32, include_repeat := true) -> bool {
	for k in ctx.input.keys {
		if k.sym == sym && (include_repeat || !k.repeat) {
			return true
		}
	}
	return false
}

// key_count is how many times a key arrived this frame. Several presses can
// land in one frame, and a boolean cannot tell one from three.
key_count :: proc(ctx: ^Ctx, sym: u32, include_repeat := true) -> int {
	n := 0
	for k in ctx.input.keys {
		if k.sym == sym && (include_repeat || !k.repeat) {
			n += 1
		}
	}
	return n
}

// shortcut matches a key with modifiers, e.g. `shortcut(ui, 'q', {.Ctrl})`.
// Auto-repeat is excluded by default: a shortcut is a command, and holding it
// down should not fire it repeatedly.
shortcut :: proc(ctx: ^Ctx, sym: u32, mods: Modifiers, include_repeat := false) -> bool {
	for k in ctx.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == mods {
			if include_repeat || !k.repeat {
				return true
			}
		}
	}
	return false
}

// One wheel notch, in the units `Input.scroll` carries.
SCROLL_NOTCH :: f32(10)

// wheel is the wheel movement this frame in notches rather than raw units.
wheel :: proc(ctx: ^Ctx) -> [2]f32 {
	return ctx.input.scroll / SCROLL_NOTCH
}

// set_focus moves keyboard focus to an element, so an app that manages its own
// panes can take focus back from a widget that grabbed it.
set_focus :: proc(ctx: ^Ctx, id: u64) {
	ctx.focus = id
}

// focus_id is whatever currently holds keyboard focus.
focus_id :: proc(ctx: ^Ctx) -> u64 {
	return ctx.focus
}

// typed_text returns the characters produced this frame, after the keymap has
// had its say. Valid until the end of the frame.
//
// Order matters in a form: take the text *before* acting on keys. A password
// and the Return that submits it can arrive in the same frame, and handling
// Return first submits a truncated value.
typed_text :: proc(ctx: ^Ctx) -> string {
	return strings.to_string(ctx.input.text)
}

// mouse_pos is the pointer position in logical pixels.
mouse_pos :: proc(ctx: ^Ctx) -> [2]f32 {
	return ctx.input.mouse
}

mouse_down :: proc(ctx: ^Ctx, b := Mouse_Button.Left) -> bool {
	return ctx.input.down[b]
}

// size is the window's logical size.
size :: proc(ctx: ^Ctx) -> [2]f32 {
	return ctx.viewport
}

// delta_time is the seconds elapsed since the previous frame.
delta_time :: proc(ctx: ^Ctx) -> f32 {
	return ctx.dt
}

// elapsed is the seconds since the first frame, handy for animations.
elapsed :: proc(ctx: ^Ctx) -> f32 {
	return f32(ctx.now)
}

// frames_per_second is a smoothed frame rate, for debug overlays.
frames_per_second :: proc(ctx: ^Ctx) -> f32 {
	return ctx.app != nil ? ctx.app.fps : 0
}

// window_scale is the device pixels per logical pixel of the output the window
// is on, which palmy follows automatically.
window_scale :: proc(ctx: ^Ctx) -> int {
	return ctx.app != nil ? ctx.app.win.scale : 1
}

// The accessors below work outside of a frame body, which is what the direct
// pixel loop needs.

// app_elapsed is the seconds since the first frame.
app_elapsed :: proc(app: ^App) -> f32 {
	return f32(app.ctx.now)
}

// app_delta is the seconds the previous frame took.
app_delta :: proc(app: ^App) -> f32 {
	return app.ctx.dt
}

// pointer is the pointer position in logical pixels.
pointer :: proc(app: ^App) -> [2]f32 {
	return app.win.input.mouse
}

// pointer_down reports a held mouse button.
pointer_down :: proc(app: ^App, b := Mouse_Button.Left) -> bool {
	return app.win.input.down[b]
}

// pressed_key reports a keysym pressed since the previous frame.
pressed_key :: proc(app: ^App, sym: u32) -> bool {
	for k in app.win.input.keys {
		if k.sym == sym {
			return true
		}
	}
	return false
}

// host_keymap is the XKB keymap this process was given by the compositor.
// A nested compositor forwards it to its own clients.
host_keymap :: proc(app: ^App) -> string {
	return keymap_text(&app.win.keymap)
}

// describe returns a one-line summary of the backend, for diagnostics.
describe :: proc(app: ^App) -> string {
	return fmt.tprintf(
		"palmy: %s, %dx%d @%dx, sans=%s mono=%s",
		backend_name(app),
		app.win.width,
		app.win.height,
		app.win.scale,
		font_path(&app.fonts, .Sans, .Regular),
		font_path(&app.fonts, .Mono, .Regular),
	)
}
