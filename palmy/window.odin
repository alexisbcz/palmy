package palmy

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

	cursor_shape:      Cursor,

	input:             Input,
	keymap:            Keymap,

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
// Event pumping
// ---------------------------------------------------------------------------

// window_wait blocks until the server sends something, or until the timeout
// expires. A negative timeout waits forever.
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

	pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
	n, perr := linux.poll(pfd[:], i32(timeout_ms))
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
