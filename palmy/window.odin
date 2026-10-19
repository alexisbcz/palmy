package palmy

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// ---------------------------------------------------------------------------
// The window, and the seam between the two display-server backends.
//
// Everything above this file — layout, painting, input queries — is backend
// agnostic. `Window` holds the state both backends share (geometry, the
// double-buffered pixel store, input, the keymap) and delegates the six things
// that genuinely differ to `palmy/wayland.odin` or `palmy/x11.odin`:
//
//	open, close, allocate the buffers, present one, wait for events,
//	and the handful of toplevel controls (title, min size, fullscreen, cursor).
//
// An application cannot tell which one it is running on.
// ---------------------------------------------------------------------------

Backend :: enum {
	Wayland,
	X11,
}

// Layer picks which stratum of the compositor's scene the surface sits in.
Layer :: enum u32 {
	Background = 0,
	Bottom     = 1,
	Top        = 2,
	Overlay    = 3,
}

// Anchor_Edge pins a layer surface to screen edges. Anchoring opposite edges
// stretches the surface between them.
Anchor_Edge :: enum u32 {
	Top    = 0,
	Bottom = 1,
	Left   = 2,
	Right  = 3,
}

Anchor :: bit_set[Anchor_Edge; u32]

// Keyboard_Mode decides whether the compositor routes key events here. A
// launcher wants Exclusive; a panel usually wants On_Demand.
Keyboard_Mode :: enum u32 {
	None      = 0,
	Exclusive = 1,
	On_Demand = 2,
}

// Mouse buttons, named rather than numbered so the two backends' very
// different button codes never reach an application.
Mouse_Button :: enum {
	Left,
	Right,
	Middle,
}

Modifier :: enum {
	Shift,
	Ctrl,
	Alt,
	Super,
	Caps,
}

Modifiers :: bit_set[Modifier]

Key_Event :: struct {
	sym:    u32,
	mods:   Modifiers,
	repeat: bool,
}

// Input holds everything that happened since the previous frame. Edge state
// (pressed/released/keys/text) is cleared at the start of each frame; level
// state (position, held buttons, modifiers) persists.
Input :: struct {
	mouse:          [2]f32,
	mouse_delta:    [2]f32,
	down:           [Mouse_Button]bool,
	pressed:        [Mouse_Button]bool,
	released:       [Mouse_Button]bool,
	click_serial:   u32,
	scroll:         [2]f32,
	over_surface:   bool,
	mods:           Modifiers,
	keys:           [dynamic]Key_Event,
	text:           strings.Builder,
	focused:        bool,
}

// Shm_Buffer is one half of the double buffer. `px` is 0xAARRGGBB words, which
// is what the rasterizer writes and what both a wl_shm XRGB8888 buffer and an
// X11 depth-24 ZPixmap on a little-endian server expect, byte for byte.
@(private)
Shm_Buffer :: struct {
	id:     u32, // wl_buffer id on Wayland; unused on X11
	offset: int,
	busy:   bool,
	px:     []u32,
	w, h:   int,
}

Window :: struct {
	backend:           Backend,

	// The socket to the display server. Both backends frame their own
	// messages on top of it; only Wayland uses the object-id bookkeeping and
	// the SCM_RIGHTS fd queue.
	conn:              Conn,
	wl:                Wl_State,
	x:                 X11_State,

	// The double-buffered pixel store, backed by shared memory on both
	// backends when the server supports it.
	buffers:           [2]Shm_Buffer,

	// Geometry, in logical pixels, with `scale` device pixels per logical pixel.
	width:             int,
	height:            int,
	scale:             int,
	pending_width:     int,
	pending_height:    int,
	pending_scale:     int,
	configure_serial:  u32,
	configured:        bool,
	need_configure_ack: bool,

	// Toplevel state.
	should_close:      bool,
	maximized:         bool,
	fullscreen:        bool,
	activated:         bool,

	frame_pending:     bool,
	frame_ready:       bool,
	last_present:      time.Time,

	// Set whenever an event arrives that should produce a new frame. Frame
	// callbacks deliberately do not set it, so an idle window stays idle.
	input_dirty:       bool,

	// The wake-up descriptor: the second fd in the poll set, beside the
	// display socket. See "Waking the frame loop" below. `wake_flag` and
	// `wake_deadline` are written from any thread and so are only ever
	// touched atomically; `wake_pending` belongs to the loop's thread.
	wake_fd:           linux.Fd,
	wake_flag:         i32,
	wake_deadline:     i64,
	wake_pending:      bool,
	epoch:             time.Tick,

	cursor_shape:      Cursor,

	input:             Input,
	keymap:            Keymap,

	// The clipboard (palmy/clipboard.odin), and input that arrived while a
	// clipboard call waited on the server mid-frame.
	clip:              Clip_State,
	late:              Late_Input,

	// Client-side key repeat, driven by wl_keyboard.repeat_info. The X11
	// server generates its own repeats, so there `repeat_rate` stays 0 and
	// `pump_key_repeat` never fires.
	repeat_rate:       int,
	repeat_delay:      int,
	repeat_key:        u32,
	repeat_sym:        u32,
	repeat_at:         time.Time,

	title:             string,
	app_id:            string,

	// Layer surface configuration, applied when `use_layer` is set. Wayland
	// only: X11 has no equivalent and says so rather than opening a plain
	// window that would sit in the wrong place.
	use_layer:         bool,
	layer:             Layer,
	anchor:            Anchor,
	keyboard_mode:     Keyboard_Mode,
	exclusive_zone:    int,
	layer_margin:      [4]int, // top, right, bottom, left
}

// ---------------------------------------------------------------------------
// Backend selection
// ---------------------------------------------------------------------------

// pick_backend decides which server to talk to. PALMY_BACKEND overrides
// everything, which matters on a machine running both: a Wayland compositor
// with XWayland always exports DISPLAY as well, so the environment alone
// cannot express "I want to test the X11 path".
@(private)
pick_backend :: proc() -> (be: Backend, err: string) {
	switch os.get_env("PALMY_BACKEND", context.temp_allocator) {
	case "x11", "X11", "xcb", "xlib":
		return .X11, ""
	case "wayland", "Wayland", "wl":
		return .Wayland, ""
	case "":
	// Fall through to autodetection.
	case:
		return .Wayland, "PALMY_BACKEND must be either x11 or wayland"
	}

	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
		return .Wayland, ""
	}
	if os.get_env("DISPLAY", context.temp_allocator) != "" {
		return .X11, ""
	}
	return .Wayland, "neither WAYLAND_DISPLAY nor DISPLAY is set, so there is no display server to open a window on"
}

// backend_name is the backend in use, for diagnostics.
backend_name :: proc(app: ^App) -> string {
	return app.win.backend == .X11 ? "x11" : "wayland"
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

window_open :: proc(w: ^Window, title, app_id: string, width, height: int, decorate: bool) -> (err: string) {
	w.width, w.height = width, height
	w.scale = 1
	w.pending_scale = 1
	w.title = strings.clone(title)
	w.app_id = strings.clone(app_id)
	w.input.text = strings.builder_make()
	w.last_present = time.now()

	// Before the backend, so that the roundtrips inside `wl_open` and
	// `x_open` already poll a complete descriptor set.
	wake_init(w)

	be, berr := pick_backend()
	if berr != "" {
		return berr
	}
	w.backend = be

	switch be {
	case .Wayland:
		return wl_open(w, decorate)
	case .X11:
		return x_open(w, decorate)
	}
	return "no display server backend is available"
}

window_close :: proc(w: ^Window) {
	switch w.backend {
	case .Wayland:
		wl_close(w)
	case .X11:
		x_close(w)
	}
	keymap_destroy(&w.keymap)
	clip_destroy(w)
	wake_close(w)
	conn_close(&w.conn)
	delete(w.input.keys)
	strings.builder_destroy(&w.input.text)
	delete(w.title)
	delete(w.app_id)
}

// ---------------------------------------------------------------------------
// The pixel store
// ---------------------------------------------------------------------------

@(private)
destroy_buffers :: proc(w: ^Window) {
	switch w.backend {
	case .Wayland:
		wl_destroy_buffers(w)
	case .X11:
		x_destroy_buffers(w)
	}
}

@(private)
alloc_buffers :: proc(w: ^Window) -> (err: string) {
	switch w.backend {
	case .Wayland:
		return wl_alloc_buffers(w)
	case .X11:
		return x_alloc_buffers(w)
	}
	return ""
}

// next_buffer returns a buffer the server is not currently reading from.
@(private)
next_buffer :: proc(w: ^Window) -> ^Shm_Buffer {
	for &b in w.buffers {
		if !b.busy {
			return &b
		}
	}
	return nil
}

// apply_pending resizes the backing store when the server has asked for a new
// size or a new scale. On Wayland that request arrives as an xdg_surface or
// layer-surface configure; on X11 as ConfigureNotify. Both land in
// `pending_width`/`pending_height`, so the resize itself is shared.
@(private)
apply_pending :: proc(w: ^Window) -> (resized: bool, err: string) {
	nw := w.pending_width if w.pending_width > 0 else w.width
	nh := w.pending_height if w.pending_height > 0 else w.height
	ns := w.pending_scale if w.pending_scale > 0 else w.scale

	if nw == w.width && nh == w.height && ns == w.scale && w.buffers[0].px != nil {
		return false, ""
	}

	w.width, w.height, w.scale = nw, nh, ns
	if e := alloc_buffers(w); e != "" {
		return true, e
	}
	return true, ""
}

// present pushes a finished buffer to the server.
@(private)
present :: proc(w: ^Window, b: ^Shm_Buffer) {
	switch w.backend {
	case .Wayland:
		wl_present(w, b)
	case .X11:
		x_present(w, b)
	}
	w.last_present = time.now()
}

// frame_watchdog unsticks a frame that will never be acknowledged. On Wayland
// a compositor that stops sending frame callbacks is its own bug and the
// surface is meant to stall; on X11 the acknowledgement is a ShmCompletion
// event, and that one can genuinely be lost — a resize detaches the segment
// the completion would have referred to. Rather than freeze, give up on it.
@(private)
FRAME_WATCHDOG_MS :: 250

@(private)
frame_watchdog :: proc(w: ^Window) {
	if w.backend != .X11 || !w.frame_pending {
		return
	}
	if int(time.duration_milliseconds(time.since(w.last_present))) > FRAME_WATCHDOG_MS {
		w.frame_pending = false
		for &b in w.buffers {
			b.busy = false
		}
	}
}

// frame_hold_ms is how long the loop should wait before presenting again.
// Wayland paces frames with a frame callback, so it is always 0 there. X11 has
// no vsync in the core protocol, so without a floor an `always` app would
// repaint as fast as the server can swallow it.
@(private)
FRAME_INTERVAL_MS :: 16

@(private)
frame_hold_ms :: proc(w: ^Window) -> int {
	if w.backend != .X11 {
		return 0
	}
	elapsed := int(time.duration_milliseconds(time.since(w.last_present)))
	if elapsed >= FRAME_INTERVAL_MS {
		return 0
	}
	return FRAME_INTERVAL_MS - elapsed
}

// ---------------------------------------------------------------------------
// Waking the frame loop
//
// The loop parks in `poll(2)`. For a long time the only descriptor in that set
// was the display socket, so the only thing in the world that could end an
// idle sleep was the display server. A worker thread with a token to show, or
// a countdown that has to expire, had no way in — and ten applications worked
// around that by marking the UI permanently animating, which repaints a
// software-rasterised window at the display rate forever for the sake of an
// event that might arrive.
//
// The way in is a second descriptor, an `eventfd`, polled alongside the
// socket. Any thread may write to it without taking a lock; the loop drains it
// after poll and decides what the write meant:
//
//   - `wake` sets `wake_flag` *before* writing, and the drain turns that into
//     exactly one frame. One frame, not a mode: a thousand wakes delivered
//     while the loop is busy still collapse into the single frame that is
//     owed, because the counter is drained in one read.
//
//   - `wake_at` only moves `wake_deadline` in. Its write exists to make a loop
//     already parked on a longer timeout recompute it; by itself it does not
//     ask for a frame. The frame comes when the deadline passes.
//
// A wake raised while the loop is mid-frame is not lost: the eventfd counter
// is still non-zero when poll is next entered, so poll returns at once. That
// is also why the drain reads the descriptor *before* it consumes `wake_flag`
// — the other order has a window in which a concurrent wake's write is
// swallowed by a read while its flag is set too late to be seen, and the loop
// then sleeps on a wake that was already delivered.
// ---------------------------------------------------------------------------

@(private)
wake_init :: proc(w: ^Window) {
	w.epoch = time.tick_now()
	w.wake_flag = 0
	w.wake_deadline = 0
	w.wake_pending = false
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		// Not fatal. Without it the loop behaves exactly as it did before
		// this existed: it wakes for the display server and for nothing else.
		w.wake_fd = -1
		return
	}
	w.wake_fd = fd
}

@(private)
wake_close :: proc(w: ^Window) {
	if w.wake_fd > 0 {
		linux.close(w.wake_fd)
	}
	w.wake_fd = -1
}

// wake_poke makes a parked poll return. Descriptor 0 is this process's stdin
// and never an eventfd, so `> 0` doubles as "a wake descriptor exists" for a
// Window that was never opened.
@(private)
wake_poke :: proc(w: ^Window) {
	if w.wake_fd <= 0 {
		return
	}
	one := u64(1)
	buf := (cast([^]u8)&one)[:8]
	// The only failure a non-blocking eventfd can give is EAGAIN, at a
	// counter of 2^64-2 — which would mean the loop has not run for longer
	// than the universe has. Either way there is already a wake queued.
	linux.write(w.wake_fd, buf)
}

// mono_ns is nanoseconds on a monotonic clock since the window opened. A
// deadline cannot be kept on the wall clock: a one-shot that fires in 30
// seconds must not be moved by NTP stepping the time, and `time.now()` can go
// backwards.
@(private)
mono_ns :: proc(w: ^Window) -> i64 {
	return i64(time.tick_since(w.epoch))
}

// wake_window asks the frame loop to run one more frame.
//
// It is safe to call from any thread. It takes no lock, allocates nothing and
// never blocks — an atomic store and a write to an eventfd — so calling it
// while the loop is in the middle of drawing, from inside the loop itself, or
// from a signal handler, cannot deadlock.
//
// One call means at most one extra frame. The loop drains the descriptor, runs
// a single iteration and parks again; it does not start spinning.
wake_window :: proc(w: ^Window) {
	intrinsics.atomic_store(&w.wake_flag, 1)
	wake_poke(w)
}

// wake_after_window arms a one-shot: the loop sleeps at most `delay` and then
// runs a frame. It fires once and disarms itself — nothing repeats until it is
// armed again.
//
// Arming is earliest-wins. Two subsystems each asking for a wake both get
// served by the nearer deadline, and an already-armed nearer deadline is not
// pushed out by a later request. The natural way to use it is to re-arm every
// frame with whatever the next thing to happen is; the natural way to misuse
// it is to arm once for a far-off instant and expect a nearer, unrelated wake
// not to consume it.
//
// A delay of zero or less is the same as `wake`.
wake_after_window :: proc(w: ^Window, delay: time.Duration) {
	if delay <= 0 {
		wake_window(w)
		return
	}
	now := mono_ns(w)
	target := max(i64)
	if i64(delay) < max(i64) - now {
		target = now + i64(delay)
	}
	if target <= 0 {
		// Zero is the disarmed sentinel, so it cannot also be a deadline.
		target = 1
	}
	for {
		cur := intrinsics.atomic_load(&w.wake_deadline)
		if cur != 0 && cur <= target {
			return // Something nearer is already armed.
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(&w.wake_deadline, cur, target);
		   ok {
			break
		}
	}
	wake_poke(w)
}

// wake_at_window arms the one-shot for an instant rather than a delay.
wake_at_window :: proc(w: ^Window, at: time.Time) {
	wake_after_window(w, time.diff(time.now(), at))
}

// wake_cancel_window disarms the one-shot. A wake already turned into a
// pending frame is not taken back.
wake_cancel_window :: proc(w: ^Window) {
	intrinsics.atomic_store(&w.wake_deadline, 0)
}

// The longest poll this will ask for, in milliseconds: a little over a day.
// `poll` takes an i32, and a deadline far enough out to overflow one would
// otherwise wrap to a negative timeout, which means "wait forever" — the one
// answer a timer must never give. Capping instead costs a wakeup a day.
@(private)
WAKE_MAX_MS :: 24 * 60 * 60 * 1000

// wake_cap shortens a poll timeout so that an armed one-shot is not slept
// through. Rounding up is deliberate: waking a millisecond late costs nothing,
// and waking early would just mean polling again.
@(private)
wake_cap :: proc(w: ^Window, timeout_ms: int) -> int {
	d := intrinsics.atomic_load(&w.wake_deadline)
	if d == 0 {
		return min(timeout_ms, WAKE_MAX_MS) if timeout_ms >= 0 else timeout_ms
	}
	ms := 0
	if left := d - mono_ns(w); left > 0 {
		ms = int(min((left + 999_999) / 1_000_000, i64(WAKE_MAX_MS)))
	}
	if timeout_ms < 0 || ms < timeout_ms {
		return ms
	}
	return timeout_ms
}

// drain_wake folds whatever arrived on the wake descriptor into the loop's
// state. It runs after poll, on the loop's thread only.
@(private)
drain_wake :: proc(w: ^Window) {
	if w.wake_fd > 0 {
		// A non-semaphore eventfd empties its whole counter in one read, so
		// a thousand queued wakes become one frame. The second read is the
		// EAGAIN that proves it is empty.
		buf: [8]u8
		for {
			n, err := linux.read(w.wake_fd, buf[:])
			if err != .NONE || n <= 0 {
				break
			}
		}
	}

	if intrinsics.atomic_exchange(&w.wake_flag, 0) != 0 {
		w.wake_pending = true
	}

	// The deadline is checked whatever woke us, so a one-shot still fires when
	// poll happened to return early for an unrelated event.
	if d := intrinsics.atomic_load(&w.wake_deadline); d != 0 && mono_ns(w) >= d {
		if _, ok := intrinsics.atomic_compare_exchange_strong(&w.wake_deadline, d, 0); ok {
			w.wake_pending = true
		}
	}
}

// ---------------------------------------------------------------------------
// Event pumping
// ---------------------------------------------------------------------------

// window_wait blocks until the server sends something, until somebody wakes
// the window, until an armed one-shot comes due, or until the timeout expires.
// A negative timeout waits forever — or until one of the first three happens.
window_wait :: proc(w: ^Window, timeout_ms: int) -> bool {
	c := &w.conn
	if c.fatal != "" {
		return false
	}
	conn_flush(c)

	// X11 replies and events arrive in the same stream, so a synchronous
	// reply fetch can leave events buffered behind it. Drain them first.
	if w.backend == .X11 && len(c.rx) > 0 {
		x_dispatch_pending(w)
		if c.fatal != "" {
			return false
		}
	}

	pfd: [2]linux.Poll_Fd
	pfd[0] = {
		fd     = c.fd,
		events = {.IN},
	}
	nfds := 1
	if w.wake_fd > 0 {
		pfd[1] = {
			fd     = w.wake_fd,
			events = {.IN},
		}
		nfds = 2
	}

	n, perr := linux.poll(pfd[:nfds], i32(wake_cap(w, timeout_ms)))
	drain_wake(w)
	if perr == .EINTR {
		return true
	}
	if perr != .NONE {
		c.fatal = fmt.tprintf("poll failed: %v", perr)
		return false
	}
	if n > 0 {
		if .HUP in pfd[0].revents || .ERR in pfd[0].revents {
			c.fatal = "the display server closed the connection"
			return false
		}
		// Only the wake descriptor may have fired, and then there is nothing
		// on the socket to read.
		if .IN in pfd[0].revents {
			if !conn_read(c) {
				return false
			}
			switch w.backend {
			case .Wayland:
				wl_dispatch_pending(c, w)
			case .X11:
				x_dispatch_pending(w)
			}
		}
	}
	return c.fatal == ""
}

// window_pump dispatches already-buffered events without blocking.
window_pump :: proc(w: ^Window) -> bool {
	return window_wait(w, 0)
}

@(private)
feed_key :: proc(w: ^Window, code: u32, repeat: bool) {
	sym := keymap_sym(&w.keymap, code)
	append(&w.input.keys, Key_Event{sym = sym, mods = w.input.mods, repeat = repeat})

	// Printable input, resolved through the keymap so that layouts and dead
	// keys behave the way the rest of the desktop does.
	if .Ctrl not_in w.input.mods && .Super not_in w.input.mods {
		buf: [16]u8
		n := keymap_utf8(&w.keymap, code, buf[:])
		if n > 0 && !(n == 1 && buf[0] < 0x20) {
			strings.write_string(&w.input.text, string(buf[:n]))
		}
	}
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
set_title_window :: proc(w: ^Window, title: string) {
	delete(w.title)
	w.title = strings.clone(title)
	switch w.backend {
	case .Wayland:
		wl_set_title(w)
	case .X11:
		x_set_title(w)
	}
}

@(private)
set_min_size_window :: proc(w: ^Window, width, height: int) {
	switch w.backend {
	case .Wayland:
		wl_set_min_size(w, width, height)
	case .X11:
		x_set_min_size(w, width, height)
	}
}

@(private)
set_fullscreen_window :: proc(w: ^Window, on: bool) {
	switch w.backend {
	case .Wayland:
		wl_set_fullscreen(w, on)
	case .X11:
		x_set_fullscreen(w, on)
	}
}

// window_set_cursor asks the server for a named pointer shape. It is a no-op
// when the server offers no way to set one.
window_set_cursor :: proc(w: ^Window, shape: Cursor) {
	want := shape == .Inherit ? Cursor.Default : shape
	switch w.backend {
	case .Wayland:
		wl_set_cursor(w, want)
	case .X11:
		x_set_cursor(w, want)
	}
}

// App-level wrappers, so the window does not have to be reached through.
@(private)
set_title_app :: proc(app: ^App, title: string) {
	set_title_window(&app.win, title)
}

@(private)
set_min_size_app :: proc(app: ^App, width, height: int) {
	set_min_size_window(&app.win, width, height)
}

@(private)
set_fullscreen_app :: proc(app: ^App, on: bool) {
	set_fullscreen_window(&app.win, on)
}

// set_title renames the window.
set_title :: proc {
	set_title_app,
	set_title_window,
}

// set_min_size tells the server how small the window may get.
set_min_size :: proc {
	set_min_size_app,
	set_min_size_window,
}

// set_fullscreen asks the server to make the window fullscreen.
set_fullscreen :: proc {
	set_fullscreen_app,
	set_fullscreen_window,
}

// maximized, fullscreen and focused report the toplevel state the server last
// told us about.
is_maximized :: proc(app: ^App) -> bool {
	return app.win.maximized
}

is_fullscreen :: proc(app: ^App) -> bool {
	return app.win.fullscreen
}

// window_focused reports whether the window has keyboard focus, which is worth
// dimming inactive UI on.
window_focused :: proc(app: ^App) -> bool {
	return app.win.activated
}
