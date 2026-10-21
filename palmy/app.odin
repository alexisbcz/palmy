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
	logic:      bool, // this frame runs the app's code but paints nothing
	canvas_buf: ^Shm_Buffer, // the buffer `canvas` points into this frame
	reported:   bool, // the loop's fatal error has been written to stderr
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

	clip_attach(app)
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
	clip_detach(app)
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
//
// It is only valid from the frame loop's own thread, because it is a plain
// write to the frame state. A worker thread wants `wake` instead.
redraw :: proc(ctx: ^Ctx) {
	ctx.redraw = true
}

// ---------------------------------------------------------------------------
// Waking the loop
//
// `frames` blocks while the window is idle, which is the whole point of it:
// an idle palmy window costs nothing. The cost of that used to be paid by
// anything that happens *off* the display server — a token arriving on a
// socket in a worker thread, a countdown expiring, a file watcher firing — and
// it was paid by marking the UI permanently animating and repainting at the
// display rate in the hope of noticing.
//
//	wake(app)                  one more frame, from any thread
//	wake_after(app, 500 * time.Millisecond)   one frame, later
//	wake_at(app, deadline)                    the same, as an instant
//	wake_cancel(app)                          never mind
//
// The mechanism is in `palmy/window.odin`, above `window_wait`, and it is the
// same on both backends because the poll set is shared.
// ---------------------------------------------------------------------------

@(private)
wake_app :: proc(app: ^App) {
	if app != nil {
		wake_window(&app.win)
	}
}

@(private)
wake_ctx :: proc(ctx: ^Ctx) {
	if ctx != nil && ctx.app != nil {
		wake_window(&ctx.app.win)
	}
}

// wake asks for one more frame. Safe from any thread; see `wake_window`.
wake :: proc {
	wake_app,
	wake_ctx,
	wake_window,
}

@(private)
wake_after_app :: proc(app: ^App, delay: time.Duration) {
	if app != nil {
		wake_after_window(&app.win, delay)
	}
}

@(private)
wake_after_ctx :: proc(ctx: ^Ctx, delay: time.Duration) {
	if ctx != nil && ctx.app != nil {
		wake_after_window(&ctx.app.win, delay)
	}
}

// wake_after arms a one-shot that runs one frame after `delay` and then
// disarms itself. Arming is earliest-wins; see `wake_after_window`.
wake_after :: proc {
	wake_after_app,
	wake_after_ctx,
	wake_after_window,
}

@(private)
wake_at_app :: proc(app: ^App, at: time.Time) {
	if app != nil {
		wake_at_window(&app.win, at)
	}
}

@(private)
wake_at_ctx :: proc(ctx: ^Ctx, at: time.Time) {
	if ctx != nil && ctx.app != nil {
		wake_at_window(&ctx.app.win, at)
	}
}

// wake_at arms the one-shot for an instant rather than a delay.
wake_at :: proc {
	wake_at_app,
	wake_at_ctx,
	wake_at_window,
}

@(private)
wake_cancel_app :: proc(app: ^App) {
	if app != nil {
		wake_cancel_window(&app.win)
	}
}

@(private)
wake_cancel_ctx :: proc(ctx: ^Ctx) {
	if ctx != nil && ctx.app != nil {
		wake_cancel_window(&ctx.app.win)
	}
}

// wake_cancel disarms the one-shot.
wake_cancel :: proc {
	wake_cancel_app,
	wake_cancel_ctx,
	wake_cancel_window,
}

// frames_presented is how many frames this window has actually put on screen.
// An idle palmy window's count does not move, which is what makes "did that
// wake cost exactly one frame?" a question a test can ask.
frames_presented :: proc(app: ^App) -> u64 {
	return app == nil ? 0 : app.frames_shown
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
		report_loop_end(app)
		return nil, false
	}
	begin_frame(app)
	app.open = true
	return &app.ctx, true
}

// window_error is why the frame loop ended, when it ended because something
// went wrong rather than because the app or the user asked it to: a lost
// connection, a protocol error, a failed poll. Empty otherwise.
window_error :: proc(app: ^App) -> string {
	return app == nil ? "" : app.win.conn.fatal
}

// report_loop_end says on stderr why the loop stopped when the reason is an
// error. Without it a window that lost its display server, or whose poll
// failed, closed with nothing said and exit status 0, and looked exactly like
// a user closing it.
@(private)
report_loop_end :: proc(app: ^App) {
	if app.reported || app.quit || app.win.should_close || app.win.conn.fatal == "" {
		return
	}
	app.reported = true
	fmt.eprintfln("palmy: the event loop of window %q stopped: %s", app.cfg.title, app.win.conn.fatal)
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
		report_loop_end(app)
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

// ---------------------------------------------------------------------------
// Running on time without the server
//
// A frame is two things: the application's code (input, state, timers — the
// body of `for ui in frames(app)`) and the pixels it produces. The server
// paces the second: Wayland withholds the frame callback until it wants
// another buffer, X11 acknowledges each put with a completion event. Until
// both loops below learnt otherwise, they paced the first by the same clock.
//
// That is right for a visible window — the callback is a vsync away — and
// wrong for a hidden one. A compositor sends no frame callbacks to a surface
// nobody can see (sway, for a window on a workspace that is not shown), so a
// window that had just committed a frame ran no code at all until it was shown
// again, however long that was. A `wake_after` that fell due meanwhile — a
// password manager's idle lock, its clipboard clear — simply did not happen.
//
// So when the loop owes the application a frame for something it must see (a
// due wake, or input) and the server is not ready for pixels, it runs a
// *logic* frame: the body runs, the tree is laid out so that hit testing
// stays correct, and nothing is painted or committed. The window keeps showing
// its last frame and `paint_owed` asks for a real one the moment the server is
// ready. Paint-only reasons (animating, redraw, `always`) never start a logic
// frame, so a hidden animating window parks instead of spinning.
//
// A logic frame waits `LOGIC_GRACE_MS` after the last frame sent and after the
// last logic frame. A visible window's callback nearly always arrives inside
// that, so it pays nothing — no frame runs twice — and an app that wakes
// itself every frame cannot turn a hidden window into a busy loop. A window
// that has been hidden for longer than that runs a due wake immediately.
// ---------------------------------------------------------------------------

@(private)
LOGIC_GRACE_MS :: 50

// The longest the loop sleeps on X11 while a put is unacknowledged:
// `frame_watchdog` gives up on a completion that never comes, and has to be
// called to do it.
@(private)
X11_PENDING_POLL_MS :: 50

// Frame_Step is what the frame loop does next.
Frame_Step_Kind :: enum {
	Wait,  // poll for `timeout_ms` (negative: until something happens)
	Frame, // run the app's code and paint
	Logic, // run the app's code; the server is not ready for pixels
}

Frame_Step :: struct {
	kind:       Frame_Step_Kind,
	timeout_ms: int,
}

// frame_step decides what the loop does next from the window's state. It does
// not block or change anything; `wait_for_frame` acts on it. It is exported so
// that the policy can be tested without a display server.
frame_step :: proc(app: ^App) -> Frame_Step {
	w := &app.win

	// Reasons the pixels on screen may be stale.
	paint := app.first ||
		app.direct ||
		app.cfg.always ||
		app.ctx.redraw ||
		app.ctx.animating ||
		w.need_configure_ack ||
		w.paint_owed
	// Reasons the application's code has to run.
	run := w.wake_pending || w.input_dirty

	timeout := -1
	if w.repeat_key != 0 && w.repeat_rate > 0 {
		ms := int(time.duration_milliseconds(time.diff(time.now(), w.repeat_at)))
		timeout = clamp(ms, 0, 1000)
	}
	shorter :: proc(a, b: int) -> int {
		return b if a < 0 || (b >= 0 && b < a) else a
	}

	if !paint && !run {
		return {.Wait, timeout}
	}

	if !w.frame_pending && next_buffer(w) != nil {
		// Wayland paces frames with a frame callback. The X11 core protocol
		// has no vsync at all, so `frame_hold_ms` supplies the floor that
		// keeps an animating app from repainting as fast as the server can
		// swallow it.
		if hold := frame_hold_ms(w); hold > 0 {
			return {.Wait, shorter(timeout, hold)}
		}
		return {.Frame, 0}
	}

	// The server is not ready for pixels: a frame callback or a completion
	// is outstanding, or both buffers are still the server's.
	if run && !app.direct && !app.first {
		since := w.last_present
		if time.diff(since, w.last_logic) > 0 {
			since = w.last_logic
		}
		left := LOGIC_GRACE_MS - int(time.duration_milliseconds(time.since(since)))
		if left <= 0 {
			return {.Logic, 0}
		}
		timeout = shorter(timeout, left)
	}
	if w.backend == .X11 {
		timeout = shorter(timeout, X11_PENDING_POLL_MS)
	}
	// On Wayland the callback and the buffer release both arrive on the
	// socket, which wakes the poll; there is nothing to time out for.
	return {.Wait, timeout}
}

@(private)
wait_for_frame :: proc(app: ^App) -> bool {
	w := &app.win
	for {
		if app.quit || w.should_close || w.conn.fatal != "" {
			return false
		}

		frame_watchdog(w)
		// A repeat that came due while the app was busy elsewhere (term
		// blocks on its own descriptors between frames) is delivered now,
		// not only after palmy's own wait below.
		pump_key_repeat(app)

		step := frame_step(app)
		switch step.kind {
		case .Frame, .Logic:
			// The wake is spent on this frame, not on the next one too.
			w.wake_pending = false
			w.input_dirty = false
			app.ctx.redraw = false
			app.logic = step.kind == .Logic
			if app.logic {
				w.last_logic = time.now()
			}
			return true
		case .Wait:
			if !window_wait(w, step.timeout_ms) {
				return false
			}
			pump_key_repeat(app)
		}
	}
}

// key_repeat_timeout is how long an app that blocks on descriptors of its
// own between frames may sleep before a held key's next repeat is due, in
// milliseconds; -1 when no key is held. Such an app must wake by then, or
// held keys repeat only as often as something else wakes it.
key_repeat_timeout :: proc(app: ^App) -> int {
	w := &app.win
	if w.repeat_key == 0 || w.repeat_rate <= 0 {
		return -1
	}
	ms := time.duration_milliseconds(time.diff(time.now(), w.repeat_at))
	return clamp(int(ms + 0.999), 0, 1000)
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
	app.canvas_buf = nil
	b := next_buffer(w)
	if b == nil {
		return false
	}
	app.canvas_buf = b
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
	// A logic frame has no buffer to draw into and does not need one; a
	// pending resize waits for the frame that paints at the new size.
	if !app.logic && !prepare_canvas(app) {
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

	if app.logic {
		// Lay out, so that the next frame routes input against where things
		// are, but paint and send nothing: the server is not ready for it.
		clear(&ctx.stack)
		layout_tree(ctx, {0, 0, ctx.viewport.x, ctx.viewport.y})
		w.paint_owed = true
		app.logic = false
		clear_edges(&w.input)
		restore_late(w)
		free_all(context.temp_allocator)
		return
	}

	b := painted_buffer(app)
	if b == nil {
		clear(&ctx.stack)
		return
	}
	w.paint_owed = false
	end_ui(ctx, &app.canvas)
	if present(w, b) {
		app.frames_shown += 1
	}

	clear_edges(&w.input)
	restore_late(w)
	app.first = false

	// Layout, hit testing and painting all use the temp allocator for
	// per-frame scratch. Nothing outlives the frame it was built in, so it is
	// released here rather than growing for the life of the process.
	free_all(context.temp_allocator)
}

@(private)
present_direct :: proc(app: ^App) {
	w := &app.win
	b := painted_buffer(app)
	if b == nil {
		return
	}
	if present(w, b) {
		app.frames_shown += 1
	}
	clear_edges(&w.input)
	restore_late(w)
	app.first = false
	free_all(context.temp_allocator)
}

// painted_buffer is the buffer this frame was drawn into, which is the one to
// present — not whichever is free *now*. They differ when a release arrives
// mid-frame: a clipboard read on Wayland dispatches events while it waits, and
// a buffer the server has just let go of comes first in `next_buffer`. Asking
// again here used to present that other buffer, holding a frame from two
// frames ago, while the new pixels sat unsent in this one; an idle window then
// showed the stale frame until something else changed.
@(private)
painted_buffer :: proc(app: ^App) -> ^Shm_Buffer {
	b := app.canvas_buf
	app.canvas_buf = nil
	if b == nil || b.busy || app.canvas.px == nil || raw_data(b.px) != raw_data(app.canvas.px) {
		return nil
	}
	return b
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

	// A frame that consumed input gets one more after it. The tree is built
	// top to bottom in a single pass, so whatever a click or a key changes is
	// already stale in every element built before the code that handled it:
	// a form row that takes focus on click has drawn its predecessors
	// assuming the old focus. Without this the corrected picture waited for
	// the next event of any kind -- in practice the next nudge of the mouse,
	// which is why focusing a field felt like half a second, and with a
	// perfectly still pointer it never came at all. One extra frame per
	// input is what Dear ImGui does for the same reason.
	edge := in_.pressed != {} || in_.released != {} || len(in_.keys) > 0 ||
		strings.builder_len(in_.text) > 0 || in_.scroll != {} || in_.mouse_delta != {}
	if edge {
		ctx.redraw = true
	}
	if in_.pressed != {} || len(in_.keys) > 0 || strings.builder_len(in_.text) > 0 {
		ctx.caret_epoch = time.tick_now()
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
	// A text field reached with Tab puts its caret at the end, not wherever
	// it was last -- 0 for a field that was never clicked. Tabbing into a
	// prefilled "Computer name" and typing used to prepend. The field reads
	// and clears the flag the next time it is built.
	widget_of(ctx, ctx.focus).tab_in = true
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
