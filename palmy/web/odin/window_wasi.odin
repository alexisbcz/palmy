#+build wasi
package palmy

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// The web backend: palmy in a browser tab, drawing into a <canvas>.
//
// This file takes the place of window.odin, wayland.odin and x11.odin when
// palmy is built for WebAssembly (`apps/tools/web-build.sh`). Everything above
// the window -- layout, text, widgets, the rasterizer, the frame loop policy
// in app.odin -- is compiled unchanged. The neutral half of window.odin (the
// Layer/Anchor/Input/Key_Event types and the set_title/set_fullscreen
// wrappers) is not copied here either: the build script lifts it out of
// window.odin verbatim into the staged package, so there is one source.
//
// The six things a backend does, done by the browser:
//
//	open        the page owns the canvas; `palmy_web_open` sizes it
//	buffers     one []u32 in linear memory; no double buffering, because
//	            putImageData copies synchronously and the buffer is free
//	            again the moment present returns
//	present     the changed rows (damage.odin, exactly as on Wayland) are
//	            swizzled 0xAARRGGBB -> RGBA into an ImageData and put
//	wait        a JSPI-suspending import: the wasm stack parks on a Promise
//	            that settles on the next input event, the frame callback
//	            (requestAnimationFrame after a present), or a timeout
//	controls    document.title, canvas.style.cursor, requestFullscreen
//	input       DOM pointer, wheel, keyboard, focus and resize events,
//	            queued in JS and drained here as fixed-size records
//
// Because `wait` suspends rather than returns, `for ui in palmy.frames(app)`
// keeps its shape: an application does not know it is in a browser. That
// needs JavaScript Promise Integration (WebAssembly.Suspending), shipped in
// Chromium 137; elsewhere the page says so instead of running.
//
// Threads: none. A web build is single-threaded. Worker threads over a
// SharedArrayBuffer would need the page served cross-origin isolated
// (COOP/COEP) and an Odin runtime built with wasm atomics and a
// thread-spawning shim; nothing in the toolkit needs them, and the
// applications that spawn threads (clipboard pipes, term's pty reader) are
// the ones that cannot run here anyway. `wake_window` from the loop's own
// code still works: it is an atomic flag the next wait sees.
// ---------------------------------------------------------------------------

Backend :: enum {
	Wayland,
	X11,
	Web,
}

// Conn stands in for the display socket. Only `fatal` means anything here:
// it is how app.odin learns the loop has to end, as on the other backends.
@(private)
Conn :: struct {
	fd:    int,
	fatal: string,
}

// X11_State is read by app.odin's `x11_visible`, which never consults it for
// a backend other than X11.
@(private)
X11_State :: struct {
	mapped:   bool,
	obscured: bool,
}

Window :: struct {
	backend:           Backend,
	conn:              Conn,
	x:                 X11_State,

	buffers:           [2]Shm_Buffer,

	width:             int,
	height:            int,
	scale:             int,
	pending_width:     int,
	pending_height:    int,
	pending_scale:     int,
	configured:        bool,
	need_configure_ack: bool,

	should_close:      bool,
	maximized:         bool,
	fullscreen:        bool,
	activated:         bool,

	frame_pending:     bool,
	frame_ready:       bool,
	last_present:      time.Time,
	paint_owed:        bool,
	last_logic:        time.Time,

	damage:            Damage_State,
	input_dirty:       bool,

	wake_flag:         i32,
	wake_deadline:     i64,
	wake_pending:      bool,
	epoch:             time.Tick,

	cursor_shape:      Cursor,

	input:             Input,
	keymap:            Keymap,

	clip:              Clip_State,
	late:              Late_Input,

	// The browser repeats keys itself (KeyboardEvent.repeat), so palmy's
	// client-side repeat stays off, as on X11.
	repeat_rate:       int,
	repeat_delay:      int,
	repeat_key:        u32,
	repeat_sym:        u32,
	repeat_at:         time.Time,

	title:             string,
	app_id:            string,

	use_layer:         bool,
	layer:             Layer,
	anchor:            Anchor,
	keyboard_mode:     Keyboard_Mode,
	exclusive_zone:    int,
	layer_margin:      [4]int,

	// The web backend's own bookkeeping.
	web:               Web_State,
}

@(private)
Web_State :: struct {
	frames:   u64, // frames run, logic frames included: the number in the log
	painted:  bool, // this frame reached `present`
	log:      bool, // PALMY_WEB_LOG=1: one JSON line per frame
	log_buf:  strings.Builder,
	// The input edges dispatched since the last frame ended, kept apart from
	// `input` because the frame loop clears those before the log is written.
	edge:     Web_Edges,
	// What clipboard reads returned during this frame, for the log: the
	// replay has no clipboard of the page's to read.
	clip_log: [dynamic]Web_Clip_Read,
}

@(private)
Web_Edges :: struct {
	pressed, released: [Mouse_Button]bool,
	scroll, mouse_delta: [2]f32,
	keys: [dynamic]Key_Event,
	text: strings.Builder,
}

@(private)
Web_Clip_Read :: struct {
	kind: Clip_Kind,
	ok:   bool,
	text: string,
}

backend_name :: proc(app: ^App) -> string {
	return "web"
}

// ---------------------------------------------------------------------------
// The imports. `palmy_web_wait`, `palmy_web_clip_read` and
// `palmy_web_clip_write` are wrapped in WebAssembly.Suspending by the page.
// ---------------------------------------------------------------------------

@(private)
Web_Event :: struct {
	kind: i32,
	mods: i32,
	a, b, c, d: i32,
	x, y: f32,
}

@(private)
WEB_MOTION :: 1
@(private)
WEB_BUTTON :: 2
@(private)
WEB_WHEEL :: 3
@(private)
WEB_KEY :: 4
@(private)
WEB_TEXT :: 5
@(private)
WEB_RESIZE :: 6
@(private)
WEB_FOCUS :: 7
@(private)
WEB_LEAVE :: 8
@(private)
WEB_MODS :: 9
@(private)
WEB_ENTER :: 10

foreign import web "palmy_web"

@(default_calling_convention = "contextless", private)
foreign web {
	palmy_web_open :: proc(width, height: i32, title: [^]u8, title_len: i32, out_size: ^[3]i32) -> i32 ---
	palmy_web_buffer :: proc(dw, dh, lw, lh: i32) ---
	palmy_web_present :: proc(px: [^]u32, bw, bh: i32, rects: [^]Damage_Rect, nrects: i32, frame: i32) ---
	palmy_web_wait :: proc(timeout_ms: i32) -> i32 ---
	palmy_web_next_event :: proc(ev: ^Web_Event) -> i32 ---
	palmy_web_take_frame_done :: proc() -> i32 ---
	palmy_web_set_title :: proc(s: [^]u8, n: i32) ---
	palmy_web_set_cursor :: proc(shape: i32) ---
	palmy_web_set_fullscreen :: proc(on: i32) ---
	palmy_web_log :: proc(s: [^]u8, n: i32) ---
	palmy_web_clip_write :: proc(kind: i32, s: [^]u8, n: i32) -> i32 ---
	palmy_web_clip_read :: proc(kind: i32) -> i32 ---
	palmy_web_clip_take :: proc(dst: [^]u8, n: i32) ---
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

window_open :: proc(w: ^Window, title, app_id: string, width, height: int, decorate: bool) -> (err: string) {
	w.backend = .Web
	w.width, w.height = width, height
	w.scale = 1
	w.pending_scale = 1
	w.title = strings.clone(title)
	w.app_id = strings.clone(app_id)
	w.input.text = strings.builder_make()
	w.last_present = time.now()
	w.epoch = time.tick_now()
	w.conn.fd = 1 // "a connection exists", for clip_window
	w.web.log = os.get_env("PALMY_WEB_LOG", context.temp_allocator) == "1"

	if w.use_layer {
		return "a browser has no layer shell: this window cannot be a panel, launcher or overlay on the web backend"
	}

	size: [3]i32
	if palmy_web_open(i32(width), i32(height), raw_data(title), i32(len(title)), &size) == 0 {
		return "the page has no canvas for palmy to draw into"
	}
	w.width, w.height = max(int(size[0]), 1), max(int(size[1]), 1)
	w.scale = max(int(size[2]), 1)
	w.pending_width, w.pending_height, w.pending_scale = w.width, w.height, w.scale
	w.configured = true
	w.activated = true
	w.input.focused = true
	if e := alloc_buffers(w); e != "" {
		return e
	}
	return ""
}

window_close :: proc(w: ^Window) {
	destroy_buffers(w)
	damage_destroy(&w.damage)
	clip_destroy(w)
	delete(w.input.keys)
	strings.builder_destroy(&w.input.text)
	strings.builder_destroy(&w.web.log_buf)
	delete(w.web.edge.keys)
	strings.builder_destroy(&w.web.edge.text)
	for c in w.web.clip_log {
		delete(c.text)
	}
	delete(w.web.clip_log)
	delete(w.title)
	delete(w.app_id)
}

// ---------------------------------------------------------------------------
// The pixel store
// ---------------------------------------------------------------------------

@(private)
destroy_buffers :: proc(w: ^Window) {
	for &b in w.buffers {
		delete(b.px)
		b = {}
	}
}

// alloc_buffers sizes the one buffer the web backend draws into. The second
// half of the double buffer is never allocated: `next_buffer` finds the first
// free, and the first is always free.
@(private)
alloc_buffers :: proc(w: ^Window) -> (err: string) {
	destroy_buffers(w)
	dw, dh := w.width * w.scale, w.height * w.scale
	b := &w.buffers[0]
	b.px = make([]u32, dw * dh)
	if b.px == nil {
		return "out of memory for the frame buffer"
	}
	b.w, b.h = dw, dh
	// The second slot stays empty and marked busy so it is never chosen.
	w.buffers[1].busy = true
	palmy_web_buffer(i32(dw), i32(dh), i32(w.width), i32(w.height))
	return ""
}

@(private)
next_buffer :: proc(w: ^Window) -> ^Shm_Buffer {
	for &b in w.buffers {
		if !b.busy {
			return &b
		}
	}
	return nil
}

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

// present puts the rows that changed since the last frame on the canvas, and
// arms the frame callback: the next requestAnimationFrame after it. A frame
// identical to the last one is not put at all, and then -- as on Wayland,
// where it would get no frame callback either -- `frame_hold_ms` paces the
// loop for SKIP_HOLD_MS instead.
@(private)
present :: proc(w: ^Window, b: ^Shm_Buffer) -> bool {
	w.web.painted = true
	if !frame_damage(&w.damage, b.px, b.w, b.h) && !w.need_configure_ack {
		w.damage.skipped += 1
		w.damage.hold_until = time.time_add(time.now(), SKIP_HOLD_MS * time.Millisecond)
		return false
	}
	w.need_configure_ack = false
	rects := w.damage.rects[:]
	full := Damage_Rect{0, 0, b.w, b.h}
	if len(rects) == 0 {
		rects = ([^]Damage_Rect)(&full)[:1]
	}
	palmy_web_present(raw_data(b.px), i32(b.w), i32(b.h), raw_data(rects), i32(len(rects)), i32(w.web.frames + 1))
	w.frame_pending = true
	w.last_present = time.now()
	return true
}

@(private)
frame_watchdog :: proc(w: ^Window) {}

@(private)
frame_hold_ms :: proc(w: ^Window) -> int {
	left := time.diff(time.now(), w.damage.hold_until)
	if left <= 0 {
		return 0
	}
	return max(int(time.duration_milliseconds(left)), 1)
}

// ---------------------------------------------------------------------------
// Waking the frame loop. The same contract as window.odin's, without the
// eventfd: there is one thread, so a wake raised during a frame is a flag the
// next `window_wait` sees before it parks, and a deadline is a timeout.
// ---------------------------------------------------------------------------

@(private)
mono_ns :: proc(w: ^Window) -> i64 {
	return i64(time.tick_since(w.epoch))
}

wake_window :: proc(w: ^Window) {
	intrinsics.atomic_store(&w.wake_flag, 1)
}

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
		target = 1
	}
	cur := intrinsics.atomic_load(&w.wake_deadline)
	if cur != 0 && cur <= target {
		return
	}
	intrinsics.atomic_store(&w.wake_deadline, target)
}

wake_at_window :: proc(w: ^Window, at: time.Time) {
	wake_after_window(w, time.diff(time.now(), at))
}

wake_cancel_window :: proc(w: ^Window) {
	intrinsics.atomic_store(&w.wake_deadline, 0)
}

@(private)
WAKE_MAX_MS :: 24 * 60 * 60 * 1000

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

@(private)
drain_wake :: proc(w: ^Window) {
	if intrinsics.atomic_exchange(&w.wake_flag, 0) != 0 {
		w.wake_pending = true
	}
	if d := intrinsics.atomic_load(&w.wake_deadline); d != 0 && mono_ns(w) >= d {
		intrinsics.atomic_store(&w.wake_deadline, 0)
		w.wake_pending = true
	}
}

// ---------------------------------------------------------------------------
// Event pumping
// ---------------------------------------------------------------------------

// window_wait parks the wasm stack until the page has an input event, the
// frame callback fires, a wake comes due, or the timeout runs out. A negative
// timeout waits for one of the first three.
window_wait :: proc(w: ^Window, timeout_ms: int) -> bool {
	if w.conn.fatal != "" {
		return false
	}
	t := wake_cap(w, timeout_ms)
	if intrinsics.atomic_load(&w.wake_flag) != 0 {
		t = 0
	}
	palmy_web_wait(i32(t))
	if palmy_web_take_frame_done() != 0 {
		w.frame_pending = false
	}
	web_dispatch(w)
	drain_wake(w)
	return w.conn.fatal == ""
}

window_pump :: proc(w: ^Window) -> bool {
	return window_wait(w, 0)
}

@(private)
web_mods :: proc(m: i32) -> Modifiers {
	return transmute(Modifiers)u8(m & 0x1f)
}

@(private)
web_dispatch :: proc(w: ^Window) {
	in_ := &w.input
	ev: Web_Event
	for palmy_web_next_event(&ev) != 0 {
		in_.mods = web_mods(ev.mods)
		switch ev.kind {
		case WEB_MOTION, WEB_ENTER:
			p := [2]f32{ev.x, ev.y}
			if in_.over_surface {
				in_.mouse_delta += p - in_.mouse
				w.web.edge.mouse_delta += p - in_.mouse
			}
			in_.mouse = p
			in_.over_surface = true
			w.input_dirty = true
		case WEB_LEAVE:
			in_.over_surface = false
			w.input_dirty = true
		case WEB_BUTTON:
			mb: Mouse_Button
			switch ev.a {
			case 1:
				mb = .Right
			case 2:
				mb = .Middle
			case:
				mb = .Left
			}
			if ev.b != 0 {
				in_.down[mb] = true
				in_.pressed[mb] = true
				w.web.edge.pressed[mb] = true
				in_.click_serial += 1
			} else {
				in_.down[mb] = false
				in_.released[mb] = true
				w.web.edge.released[mb] = true
			}
			w.input_dirty = true
		case WEB_WHEEL:
			in_.scroll += {ev.x, ev.y}
			w.web.edge.scroll += {ev.x, ev.y}
			w.input_dirty = true
		case WEB_KEY:
			k := Key_Event{sym = u32(ev.a), mods = in_.mods, repeat = ev.c != 0, unshifted = u32(ev.b)}
			append(&in_.keys, k)
			if w.web.log {
				append(&w.web.edge.keys, k)
			}
			w.input_dirty = true
		case WEB_TEXT:
			buf: [4]u8
			if n := encode_rune_into(rune(ev.a), buf[:]); n > 0 {
				strings.write_string(&in_.text, string(buf[:n]))
				if w.web.log {
					strings.write_string(&w.web.edge.text, string(buf[:n]))
				}
			}
			w.input_dirty = true
		case WEB_MODS:
			w.input_dirty = true
		case WEB_RESIZE:
			w.pending_width = max(int(ev.a), 1)
			w.pending_height = max(int(ev.b), 1)
			w.pending_scale = max(int(ev.c), 1)
			if w.pending_width != w.width || w.pending_height != w.height || w.pending_scale != w.scale {
				w.need_configure_ack = true
				w.input_dirty = true
			}
		case WEB_FOCUS:
			w.activated = ev.a != 0
			in_.focused = w.activated
			if !w.activated {
				in_.mods = {}
				in_.down = {}
			}
			w.input_dirty = true
		}
	}
}

@(private)
feed_key :: proc(w: ^Window, code: u32, repeat: bool) {
	// The browser resolves keys itself and repeats them itself; nothing in
	// this backend arms palmy's repeat, so this is never reached with a code.
	append(&w.input.keys, Key_Event{sym = code, mods = w.input.mods, repeat = repeat})
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
set_title_window :: proc(w: ^Window, title: string) {
	delete(w.title)
	w.title = strings.clone(title)
	palmy_web_set_title(raw_data(w.title), i32(len(w.title)))
}

// A page decides how big its canvas may get, not the program in it.
@(private)
set_min_size_window :: proc(w: ^Window, width, height: int) {}

@(private)
set_fullscreen_window :: proc(w: ^Window, on: bool) {
	palmy_web_set_fullscreen(on ? 1 : 0)
	w.fullscreen = on
}

window_set_cursor :: proc(w: ^Window, shape: Cursor) {
	want := shape == .Inherit ? Cursor.Default : shape
	if want == w.cursor_shape {
		return
	}
	w.cursor_shape = want
	palmy_web_set_cursor(i32(want))
}

// ---------------------------------------------------------------------------
// The frame log: PALMY_WEB_LOG=1 writes, for every frame the loop runs --
// painted or, when the page was not ready for pixels, logic only -- everything
// the frame's code could have read -- the viewport,
// the clock, the pointer, the buttons, the wheel, the keys and the text. The
// native replay (palmy/web/demo/replay) feeds it to an offscreen renderer to
// produce the same frames natively for the byte comparison. Floats travel as
// their bit patterns so nothing is lost to formatting.
// ---------------------------------------------------------------------------

// web_frame_end runs at the end of every frame, logic frames included (it is
// reached through `restore_late`, which app.odin calls from both). Input only
// changes inside `window_wait`, between frames, so the level state now is
// what the frame saw, and its edges are what `web_dispatch` gathered since
// the previous frame ended.
@(private)
web_frame_end :: proc(w: ^Window) {
	w.web.frames += 1
	if w.web.log {
		web_log_frame(w)
	}
	e := &w.web.edge
	e.pressed, e.released, e.scroll, e.mouse_delta = {}, {}, {}, {}
	clear(&e.keys)
	strings.builder_reset(&e.text)
	w.web.painted = false
}

@(private)
web_log_frame :: proc(w: ^Window) {
	app := (^App)(uintptr(w) - offset_of(App, win))
	in_ := &w.input
	e := &w.web.edge
	b := &w.web.log_buf
	if b.buf == nil {
		w.web.log_buf = strings.builder_make()
	}
	strings.builder_reset(b)
	bits :: proc(f: f32) -> u32 {return transmute(u32)f}
	buttons :: proc(s: [Mouse_Button]bool) -> int {
		n := 0
		for v, i in s {
			if v {
				n |= 1 << uint(i)
			}
		}
		return n
	}
	fmt.sbprintf(
		b,
		`{{"n":%d,"paint":%d,"w":%d,"h":%d,"s":%d,"dt":%d,"now":%d,"mx":%d,"my":%d,"mdx":%d,"mdy":%d,"down":%d,"pr":%d,"re":%d,"sx":%d,"sy":%d,"over":%d,"focused":%d,"mods":%d,"serial":%d,"keys":[`,
		w.web.frames,
		w.web.painted ? 1 : 0,
		w.width,
		w.height,
		w.scale,
		bits(app.ctx.dt),
		transmute(u64)app.ctx.now,
		bits(in_.mouse.x),
		bits(in_.mouse.y),
		bits(e.mouse_delta.x),
		bits(e.mouse_delta.y),
		buttons(in_.down),
		buttons(e.pressed),
		buttons(e.released),
		bits(e.scroll.x),
		bits(e.scroll.y),
		in_.over_surface ? 1 : 0,
		in_.focused ? 1 : 0,
		transmute(u8)in_.mods,
		in_.click_serial,
	)
	for k, i in e.keys {
		fmt.sbprintf(b, "%s[%d,%d,%d,%d]", i > 0 ? "," : "", k.sym, transmute(u8)k.mods, k.repeat ? 1 : 0, k.unshifted)
	}
	strings.write_string(b, `],"text":[`)
	i := 0
	for r in strings.to_string(e.text) {
		fmt.sbprintf(b, "%s%d", i > 0 ? "," : "", r)
		i += 1
	}
	strings.write_string(b, `],"clip":[`)
	for c, ci in w.web.clip_log {
		fmt.sbprintf(b, "%s[%d,%d", ci > 0 ? "," : "", int(c.kind), c.ok ? 1 : 0)
		for r in c.text {
			fmt.sbprintf(b, ",%d", r)
		}
		strings.write_string(b, "]")
		delete(c.text)
	}
	clear(&w.web.clip_log)
	strings.write_string(b, "]}")
	s := strings.to_string(b^)
	palmy_web_log(raw_data(s), i32(len(s)))
}
