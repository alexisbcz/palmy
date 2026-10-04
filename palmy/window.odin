package palmy

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

// Request opcodes, taken from wayland.xml / xdg-shell.xml / xdg-decoration-v1.
@(private)
WL_DISPLAY_SYNC :: 0
@(private)
WL_DISPLAY_GET_REGISTRY :: 1
@(private)
WL_REGISTRY_BIND :: 0
@(private)
WL_COMPOSITOR_CREATE_SURFACE :: 0
@(private)
WL_COMPOSITOR_CREATE_REGION :: 1
@(private)
WL_SHM_CREATE_POOL :: 0
@(private)
WL_SHM_POOL_CREATE_BUFFER :: 0
@(private)
WL_SHM_POOL_DESTROY :: 1
@(private)
WL_SURFACE_DESTROY :: 0
@(private)
WL_SURFACE_ATTACH :: 1
@(private)
WL_SURFACE_FRAME :: 3
@(private)
WL_SURFACE_SET_OPAQUE_REGION :: 4
@(private)
WL_SURFACE_COMMIT :: 6
@(private)
WL_SURFACE_SET_BUFFER_SCALE :: 8
@(private)
WL_SURFACE_DAMAGE_BUFFER :: 9
@(private)
WL_BUFFER_DESTROY :: 0
@(private)
WL_REGION_ADD :: 1
@(private)
XDG_WM_BASE_GET_XDG_SURFACE :: 2
@(private)
XDG_WM_BASE_PONG :: 3
@(private)
XDG_SURFACE_GET_TOPLEVEL :: 1
@(private)
XDG_SURFACE_SET_WINDOW_GEOMETRY :: 3
@(private)
XDG_SURFACE_ACK_CONFIGURE :: 4
@(private)
XDG_TOPLEVEL_SET_TITLE :: 2
@(private)
XDG_TOPLEVEL_SET_APP_ID :: 3
@(private)
XDG_TOPLEVEL_SET_MAX_SIZE :: 7
@(private)
XDG_TOPLEVEL_SET_MIN_SIZE :: 8
@(private)
XDG_TOPLEVEL_SET_MAXIMIZED :: 9
@(private)
XDG_TOPLEVEL_SET_FULLSCREEN :: 11
@(private)
XDG_TOPLEVEL_UNSET_FULLSCREEN :: 12
@(private)
WL_SEAT_GET_POINTER :: 0
@(private)
WL_SEAT_GET_KEYBOARD :: 1
@(private)
DECOR_MANAGER_GET_DECORATION :: 1
@(private)
CURSOR_MANAGER_GET_POINTER :: 1
@(private)
CURSOR_DEVICE_SET_SHAPE :: 1
@(private)
LAYER_SHELL_GET_LAYER_SURFACE :: 0
@(private)
LAYER_SURFACE_SET_SIZE :: 0
@(private)
LAYER_SURFACE_SET_ANCHOR :: 1
@(private)
LAYER_SURFACE_SET_EXCLUSIVE_ZONE :: 2
@(private)
LAYER_SURFACE_SET_MARGIN :: 3
@(private)
LAYER_SURFACE_SET_KEYBOARD :: 4
@(private)
LAYER_SURFACE_ACK_CONFIGURE :: 6
@(private)
LAYER_SURFACE_DESTROY :: 7

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
@(private)
DECORATION_SET_MODE :: 1

@(private)
SHM_FORMAT_XRGB8888 :: u32(1)

// Mouse buttons as reported by linux/input-event-codes.h.
Mouse_Button :: enum {
	Left,
	Right,
	Middle,
}

@(private)
BTN_LEFT :: 0x110
@(private)
BTN_RIGHT :: 0x111
@(private)
BTN_MIDDLE :: 0x112

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

@(private)
Shm_Buffer :: struct {
	id:     u32,
	offset: int,
	busy:   bool,
	px:     []u32,
	w, h:   int,
}

Window :: struct {
	conn:              Conn,

	// Globals.
	registry:          u32,
	compositor:        u32,
	compositor_ver:    u32,
	shm:               u32,
	xdg_wm_base:       u32,
	seat:              u32,
	decor_manager:     u32,
	cursor_manager:    u32,
	cursor_manager_ver: u32,
	layer_shell:       u32,

	// Objects.
	surface:           u32,
	xdg_surface:       u32,
	xdg_toplevel:      u32,
	decoration:        u32,
	layer_surface:     u32,
	pointer:           u32,
	keyboard:          u32,
	cursor_device:     u32,
	pointer_serial:    u32,
	cursor_shape:      Cursor,
	frame_cb:          u32,
	sync_cb:           u32,
	sync_done:         bool,

	// Shared memory.
	pool:              u32,
	pool_fd:           linux.Fd,
	pool_mem:          []u8,
	pool_size:         int,
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

	// Set whenever an event arrives that should produce a new frame. Frame
	// callbacks deliberately do not set it, so an idle window stays idle.
	input_dirty:       bool,

	input:             Input,
	keymap:            Keymap,

	// Key repeat, driven by wl_keyboard.repeat_info.
	repeat_rate:       int,
	repeat_delay:      int,
	repeat_key:        u32,
	repeat_sym:        u32,
	repeat_at:         time.Time,

	title:             string,
	app_id:            string,

	// Layer surface configuration, applied when `use_layer` is set.
	use_layer:         bool,
	layer:             Layer,
	anchor:            Anchor,
	keyboard_mode:     Keyboard_Mode,
	exclusive_zone:    int,
	layer_margin:      [4]int, // top, right, bottom, left
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

	if e := conn_open(&w.conn); e != "" {
		return e
	}
	c := &w.conn

	w.registry = new_id(c, .Registry)
	request(c, DISPLAY_ID, WL_DISPLAY_GET_REGISTRY, Obj(w.registry))

	// One roundtrip is enough to see the whole global list.
	if e := roundtrip(w); e != "" {
		return e
	}

	if w.compositor == 0 {
		return "the compositor does not advertise wl_compositor"
	}
	if w.shm == 0 {
		return "the compositor does not advertise wl_shm"
	}
	if w.xdg_wm_base == 0 && !w.use_layer {
		return "the compositor does not advertise xdg_wm_base (palmy needs xdg-shell)"
	}

	w.surface = new_id(c, .Surface)
	request(c, w.compositor, WL_COMPOSITOR_CREATE_SURFACE, Obj(w.surface))

	if w.use_layer {
		// A layer surface is its own shell: no toplevel, no decorations, and
		// the compositor places it rather than the window manager.
		if w.layer_shell == 0 {
			return "the compositor does not implement wlr-layer-shell"
		}
		w.layer_surface = new_id(c, .Layer_Surface)
		request(
			c,
			w.layer_shell,
			LAYER_SHELL_GET_LAYER_SURFACE,
			Obj(w.layer_surface),
			Obj(w.surface),
			Obj(0), // let the compositor pick the output
			u32(w.layer),
			w.app_id,
		)
		request(c, w.layer_surface, LAYER_SURFACE_SET_SIZE, u32(width), u32(height))
		request(c, w.layer_surface, LAYER_SURFACE_SET_ANCHOR, transmute(u32)w.anchor)
		request(c, w.layer_surface, LAYER_SURFACE_SET_KEYBOARD, u32(w.keyboard_mode))
		request(c, w.layer_surface, LAYER_SURFACE_SET_EXCLUSIVE_ZONE, i32(w.exclusive_zone))
		request(
			c,
			w.layer_surface,
			LAYER_SURFACE_SET_MARGIN,
			i32(w.layer_margin[0]),
			i32(w.layer_margin[1]),
			i32(w.layer_margin[2]),
			i32(w.layer_margin[3]),
		)
		request(c, w.surface, WL_SURFACE_COMMIT)
		conn_flush(c)

		// Size may legitimately be 0 here; the configure below supplies the
		// real one before anything is drawn.
		deadline_layer := time.time_add(time.now(), 2 * time.Second)
		for !w.configured {
			if !window_wait(w, 100) {
				return w.conn.fatal != "" ? w.conn.fatal : "the compositor never configured the layer surface"
			}
			if time.since(deadline_layer) > 0 {
				return "timed out waiting for zwlr_layer_surface_v1.configure"
			}
		}
		return ""
	}

	w.xdg_surface = new_id(c, .Xdg_Surface)
	request(c, w.xdg_wm_base, XDG_WM_BASE_GET_XDG_SURFACE, Obj(w.xdg_surface), Obj(w.surface))

	w.xdg_toplevel = new_id(c, .Xdg_Toplevel)
	request(c, w.xdg_surface, XDG_SURFACE_GET_TOPLEVEL, Obj(w.xdg_toplevel))
	request(c, w.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, w.title)
	request(c, w.xdg_toplevel, XDG_TOPLEVEL_SET_APP_ID, w.app_id)

	if decorate && w.decor_manager != 0 {
		w.decoration = new_id(c, .Decoration)
		request(c, w.decor_manager, DECOR_MANAGER_GET_DECORATION, Obj(w.decoration), Obj(w.xdg_toplevel))
		request(c, w.decoration, DECORATION_SET_MODE, u32(2)) // server_side
	}

	request(c, w.surface, WL_SURFACE_COMMIT)
	conn_flush(c)

	// Wait for the first configure before we are allowed to attach a buffer.
	deadline := time.time_add(time.now(), 2 * time.Second)
	for !w.configured {
		if !window_wait(w, 100) {
			return w.conn.fatal != "" ? w.conn.fatal : "the compositor never configured the window"
		}
		if time.since(deadline) > 0 {
			return "timed out waiting for the first xdg_surface.configure"
		}
	}
	return ""
}

window_close :: proc(w: ^Window) {
	c := &w.conn
	destroy_buffers(w)
	if w.layer_surface != 0 {
		request(c, w.layer_surface, LAYER_SURFACE_DESTROY)
	}
	if w.xdg_toplevel != 0 {
		request(c, w.xdg_toplevel, 0)
	}
	if w.xdg_surface != 0 {
		request(c, w.xdg_surface, 0)
	}
	if w.surface != 0 {
		request(c, w.surface, WL_SURFACE_DESTROY)
	}
	conn_flush(c)
	keymap_destroy(&w.keymap)
	conn_close(c)
	delete(w.input.keys)
	strings.builder_destroy(&w.input.text)
	delete(w.title)
	delete(w.app_id)
}

@(private)
roundtrip :: proc(w: ^Window) -> (err: string) {
	c := &w.conn
	w.sync_cb = new_id(c, .Callback)
	w.sync_done = false
	request(c, DISPLAY_ID, WL_DISPLAY_SYNC, Obj(w.sync_cb))
	conn_flush(c)

	start := time.now()
	for !w.sync_done {
		if !window_wait(w, 200) {
			return c.fatal != "" ? c.fatal : "the compositor stopped responding"
		}
		if time.since(start) > 3 * time.Second {
			return "timed out waiting for wl_display.sync"
		}
	}
	return ""
}

@(private)
bind_global :: proc(w: ^Window, name: u32, iface: string, version: u32, kind: Obj_Kind) -> u32 {
	c := &w.conn
	id := new_id(c, kind)
	request(c, w.registry, WL_REGISTRY_BIND, name, iface, version, Obj(id))
	return id
}

// ---------------------------------------------------------------------------
// Event dispatch
// ---------------------------------------------------------------------------

on_event :: proc(w: ^Window, id: u32, opcode: u16, r: ^Reader) {
	c := &w.conn

	#partial switch kind_of(c, id) {
	case .Display:
		switch opcode {
		case 0:
			// wl_display.error
			obj := r_u32(r)
			code := r_u32(r)
			msg := r_string(r)
			c.fatal = fmt.aprintf("protocol error on object %d (code %d): %s", obj, code, msg)
		case 1:
			free_id(c, r_u32(r))
		}

	case .Registry:
		switch opcode {
		case 0:
			name := r_u32(r)
			iface := r_string(r)
			version := r_u32(r)
			switch iface {
			case "wl_compositor":
				v := min(version, 6)
				w.compositor_ver = v
				w.compositor = bind_global(w, name, iface, v, .Compositor)
			case "wl_shm":
				w.shm = bind_global(w, name, iface, 1, .Shm)
			case "xdg_wm_base":
				w.xdg_wm_base = bind_global(w, name, iface, min(version, 3), .Xdg_Wm_Base)
			case "wl_seat":
				if w.seat == 0 {
					w.seat = bind_global(w, name, iface, min(version, 7), .Seat)
				}
			case "zxdg_decoration_manager_v1":
				w.decor_manager = bind_global(w, name, iface, 1, .Decor_Manager)
			case "zwlr_layer_shell_v1":
				w.layer_shell = bind_global(w, name, iface, min(version, 4), .Layer_Shell)
			case "wp_cursor_shape_manager_v1":
				w.cursor_manager_ver = min(version, 1)
				w.cursor_manager = bind_global(w, name, iface, w.cursor_manager_ver, .Cursor_Manager)
			}
		case 1:
			// global_remove: nothing we bind is hot-unpluggable in this version.
		}

	case .Callback:
		if id == w.sync_cb {
			w.sync_done = true
			retire_id(c, id)
			w.sync_cb = 0
		}

	case .Frame_Callback:
		if id == w.frame_cb {
			w.frame_pending = false
			w.frame_ready = true
			retire_id(c, id)
			w.frame_cb = 0
		}

	case .Shm:
		// wl_shm.format: we only ever ask for XRGB8888, which is mandatory.

	case .Buffer:
		if opcode == 0 {
			for &b in w.buffers {
				if b.id == id {
					b.busy = false
				}
			}
		}

	case .Surface:
		switch opcode {
		case 2:
			// preferred_buffer_scale
			s := int(r_i32(r))
			if s >= 1 && s != w.pending_scale {
				w.pending_scale = s
				w.input_dirty = true
			}
		}

	case .Xdg_Wm_Base:
		if opcode == 0 {
			request(c, id, XDG_WM_BASE_PONG, r_u32(r))
			conn_flush(c)
		}

	case .Layer_Surface:
		switch opcode {
		case 0:
			// configure(serial, width, height)
			w.configure_serial = r_u32(r)
			cw := int(r_u32(r))
			ch := int(r_u32(r))
			if cw > 0 && ch > 0 {
				w.pending_width, w.pending_height = cw, ch
			}
			w.need_configure_ack = true
			w.configured = true
			w.input_dirty = true
		case 1:
			w.should_close = true
			w.input_dirty = true
		}

	case .Xdg_Surface:
		if opcode == 0 {
			w.configure_serial = r_u32(r)
			w.need_configure_ack = true
			w.configured = true
			w.input_dirty = true
		}

	case .Xdg_Toplevel:
		w.input_dirty = true
		switch opcode {
		case 0:
			cw := int(r_i32(r))
			ch := int(r_i32(r))
			states := r_array(r)
			w.maximized, w.fullscreen, w.activated = false, false, false
			for i := 0; i + 4 <= len(states); i += 4 {
				switch (^u32)(raw_data(states[i:]))^ {
				case 1:
					w.maximized = true
				case 2:
					w.fullscreen = true
				case 4:
					w.activated = true
				}
			}
			if cw > 0 && ch > 0 {
				w.pending_width, w.pending_height = cw, ch
			}
		case 1:
			w.should_close = true
		}

	case .Seat:
		switch opcode {
		case 0:
			caps := r_u32(r)
			if caps & 1 != 0 && w.pointer == 0 {
				w.pointer = new_id(c, .Pointer)
				request(c, w.seat, WL_SEAT_GET_POINTER, Obj(w.pointer))

				// cursor-shape-v1 lets the compositor draw its own themed
				// cursor; without it we simply never set one.
				if w.cursor_manager != 0 {
					w.cursor_device = new_id(c, .Cursor_Device)
					request(
						c,
						w.cursor_manager,
						CURSOR_MANAGER_GET_POINTER,
						Obj(w.cursor_device),
						Obj(w.pointer),
					)
				}
			}
			if caps & 2 != 0 && w.keyboard == 0 {
				w.keyboard = new_id(c, .Keyboard)
				request(c, w.seat, WL_SEAT_GET_KEYBOARD, Obj(w.keyboard))
			}
			conn_flush(c)
		}

	case .Pointer:
		w.input_dirty = true
		in_ := &w.input
		switch opcode {
		case 0:
			// enter(serial, surface, x, y)
			w.pointer_serial = r_u32(r)
			r_u32(r)
			in_.mouse = {r_fixed(r), r_fixed(r)}
			in_.over_surface = true
			// The shape has to be set again for every enter.
			shape := w.cursor_shape
			w.cursor_shape = .Inherit
			window_set_cursor(w, shape == .Inherit ? .Default : shape)
		case 1:
			in_.over_surface = false
		case 2:
			// motion(time, x, y)
			r_u32(r)
			p := [2]f32{r_fixed(r), r_fixed(r)}
			in_.mouse_delta += p - in_.mouse
			in_.mouse = p
			in_.over_surface = true
		case 3:
			// button(serial, time, button, state)
			serial := r_u32(r)
			r_u32(r)
			btn := r_u32(r)
			state := r_u32(r)
			mb: Mouse_Button
			switch btn {
			case BTN_LEFT:
				mb = .Left
			case BTN_RIGHT:
				mb = .Right
			case BTN_MIDDLE:
				mb = .Middle
			case:
				return
			}
			if state == 1 {
				in_.down[mb] = true
				in_.pressed[mb] = true
				in_.click_serial = serial
			} else {
				in_.down[mb] = false
				in_.released[mb] = true
			}
		case 4:
			// axis(time, axis, value)
			r_u32(r)
			axis := r_u32(r)
			v := r_fixed(r)
			if axis == 0 {
				in_.scroll.y += v
			} else {
				in_.scroll.x += v
			}
		}

	case .Keyboard:
		w.input_dirty = true
		switch opcode {
		case 0:
			// keymap(format, fd, size)
			format := r_u32(r)
			size := int(r_u32(r))
			if fd, ok := take_fd(c); ok {
				if format == 1 {
					keymap_load(&w.keymap, fd, size)
				}
				linux.close(fd)
			}
		case 1:
			w.input.focused = true
		case 2:
			w.input.focused = false
			w.repeat_key = 0
			w.input.mods = {}
		case 3:
			// key(serial, time, key, state)
			r_u32(r)
			r_u32(r)
			code := r_u32(r)
			state := r_u32(r)
			if state == 1 {
				feed_key(w, code, false)
				if keymap_repeats(&w.keymap, code) && w.repeat_rate > 0 {
					w.repeat_key = code
					w.repeat_at = time.time_add(time.now(), time.Duration(w.repeat_delay) * time.Millisecond)
				}
			} else {
				if w.repeat_key == code {
					w.repeat_key = 0
				}
			}
		case 4:
			// modifiers(serial, depressed, latched, locked, group)
			r_u32(r)
			depressed := r_u32(r)
			latched := r_u32(r)
			locked := r_u32(r)
			group := r_u32(r)
			keymap_update_mods(&w.keymap, depressed, latched, locked, group)
			w.input.mods = keymap_mods(&w.keymap)
		case 5:
			w.repeat_rate = int(r_i32(r))
			w.repeat_delay = int(r_i32(r))
		}

	case:
		// Interfaces we create but never listen to.
	}
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
// Shared memory buffers
// ---------------------------------------------------------------------------

@(private)
destroy_buffers :: proc(w: ^Window) {
	c := &w.conn
	for &b in w.buffers {
		if b.id != 0 {
			request(c, b.id, WL_BUFFER_DESTROY)
			retire_id(c, b.id)
			b = {}
		}
	}
	if w.pool != 0 {
		request(c, w.pool, WL_SHM_POOL_DESTROY)
		retire_id(c, w.pool)
		w.pool = 0
	}
	if w.pool_mem != nil {
		linux.munmap(raw_data(w.pool_mem), uint(len(w.pool_mem)))
		w.pool_mem = nil
	}
	if w.pool_fd != 0 {
		linux.close(w.pool_fd)
		w.pool_fd = 0
	}
}

@(private)
alloc_buffers :: proc(w: ^Window) -> (err: string) {
	destroy_buffers(w)
	c := &w.conn

	dw := w.width * w.scale
	dh := w.height * w.scale
	stride := dw * 4
	frame := stride * dh
	total := frame * 2

	fd, ferr := linux.memfd_create("palmy-surface", {.CLOEXEC})
	if ferr != .NONE {
		return fmt.tprintf("memfd_create failed: %v", ferr)
	}
	if terr := linux.ftruncate(fd, i64(total)); terr != .NONE {
		linux.close(fd)
		return fmt.tprintf("ftruncate failed: %v", terr)
	}

	mem, merr := linux.mmap(0, uint(total), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		linux.close(fd)
		return fmt.tprintf("mmap failed: %v", merr)
	}

	w.pool_fd = fd
	w.pool_mem = ([^]u8)(mem)[:total]
	w.pool_size = total

	w.pool = new_id(c, .Shm_Pool)
	request(c, w.shm, WL_SHM_CREATE_POOL, Obj(w.pool), Fd(fd), i32(total))

	for i in 0 ..< 2 {
		b := &w.buffers[i]
		b.offset = frame * i
		b.w, b.h = dw, dh
		b.busy = false
		b.id = new_id(c, .Buffer)
		b.px = (([^]u32)(raw_data(w.pool_mem[b.offset:])))[:dw * dh]
		request(
			c,
			w.pool,
			WL_SHM_POOL_CREATE_BUFFER,
			Obj(b.id),
			i32(b.offset),
			i32(dw),
			i32(dh),
			i32(stride),
			SHM_FORMAT_XRGB8888,
		)
	}

	// The surface is fully opaque, which lets the compositor skip blending.
	region := new_id(c, .Region)
	request(c, w.compositor, WL_COMPOSITOR_CREATE_REGION, Obj(region))
	request(c, region, WL_REGION_ADD, i32(0), i32(0), i32(w.width), i32(w.height))
	request(c, w.surface, WL_SURFACE_SET_OPAQUE_REGION, Obj(region))
	request(c, region, 0) // wl_region.destroy
	retire_id(c, region)

	if w.scale != 1 {
		request(c, w.surface, WL_SURFACE_SET_BUFFER_SCALE, i32(w.scale))
	}
	return ""
}

// next_buffer returns a buffer the compositor is not currently reading from.
@(private)
next_buffer :: proc(w: ^Window) -> ^Shm_Buffer {
	for &b in w.buffers {
		if !b.busy {
			return &b
		}
	}
	return nil
}

// apply_pending resizes the backing store when the compositor has asked for a
// new size or a new scale.
@(private)
apply_pending :: proc(w: ^Window) -> (resized: bool, err: string) {
	nw := w.pending_width if w.pending_width > 0 else w.width
	nh := w.pending_height if w.pending_height > 0 else w.height
	ns := w.pending_scale if w.pending_scale > 0 else w.scale

	if nw == w.width && nh == w.height && ns == w.scale && w.buffers[0].id != 0 {
		return false, ""
	}

	w.width, w.height, w.scale = nw, nh, ns
	if e := alloc_buffers(w); e != "" {
		return true, e
	}
	return true, ""
}

// present pushes a finished buffer to the compositor and asks for the next
// frame callback so that drawing stays paced to the display.
@(private)
present :: proc(w: ^Window, b: ^Shm_Buffer) {
	c := &w.conn

	if w.need_configure_ack {
		if w.layer_surface != 0 {
			request(c, w.layer_surface, LAYER_SURFACE_ACK_CONFIGURE, w.configure_serial)
		} else {
			request(c, w.xdg_surface, XDG_SURFACE_ACK_CONFIGURE, w.configure_serial)
			request(
				c,
				w.xdg_surface,
				XDG_SURFACE_SET_WINDOW_GEOMETRY,
				i32(0),
				i32(0),
				i32(w.width),
				i32(w.height),
			)
		}
		w.need_configure_ack = false
	}

	w.frame_cb = new_id(c, .Frame_Callback)
	request(c, w.surface, WL_SURFACE_FRAME, Obj(w.frame_cb))
	w.frame_pending = true

	request(c, w.surface, WL_SURFACE_ATTACH, Obj(b.id), i32(0), i32(0))
	request(c, w.surface, WL_SURFACE_DAMAGE_BUFFER, i32(0), i32(0), i32(b.w), i32(b.h))
	request(c, w.surface, WL_SURFACE_COMMIT)
	conn_flush(c)

	b.busy = true
}

// window_wait blocks until the compositor sends something, or until the
// timeout expires. A negative timeout waits forever.
window_wait :: proc(w: ^Window, timeout_ms: int) -> bool {
	c := &w.conn
	if c.fatal != "" {
		return false
	}
	conn_flush(c)

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
			c.fatal = "the compositor closed the connection"
			return false
		}
		if !conn_read(c) {
			return false
		}
		dispatch_pending(c, w)
	}
	return c.fatal == ""
}

// window_pump dispatches already-buffered events without blocking.
window_pump :: proc(w: ^Window) -> bool {
	return window_wait(w, 0)
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
set_title_window :: proc(w: ^Window, title: string) {
	delete(w.title)
	w.title = strings.clone(title)
	request(&w.conn, w.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, w.title)
}

@(private)
set_min_size_window :: proc(w: ^Window, width, height: int) {
	request(&w.conn, w.xdg_toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, i32(width), i32(height))
}

@(private)
set_fullscreen_window :: proc(w: ^Window, on: bool) {
	if on {
		request(&w.conn, w.xdg_toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, Obj(0))
	} else {
		request(&w.conn, w.xdg_toplevel, XDG_TOPLEVEL_UNSET_FULLSCREEN)
	}
}


// window_set_cursor asks the compositor for a named pointer shape. It is a no
// -op when the compositor does not implement cursor-shape-v1.
window_set_cursor :: proc(w: ^Window, shape: Cursor) {
	want := shape == .Inherit ? Cursor.Default : shape
	if w.cursor_device == 0 || w.pointer_serial == 0 || w.cursor_shape == want {
		return
	}
	w.cursor_shape = want
	request(&w.conn, w.cursor_device, CURSOR_DEVICE_SET_SHAPE, w.pointer_serial, cursor_shape_code(want))
}

// cursor_shape_code maps onto the wp_cursor_shape_device_v1.shape enum.
@(private)
cursor_shape_code :: proc(c: Cursor) -> u32 {
	switch c {
	case .Pointer:
		return 4
	case .Text:
		return 9
	case .Crosshair:
		return 8
	case .Move:
		return 13
	case .Wait:
		return 6
	case .Progress:
		return 5
	case .Help:
		return 3
	case .Not_Allowed:
		return 15
	case .Grab:
		return 16
	case .Grabbing:
		return 17
	case .Col_Resize:
		return 18
	case .Row_Resize:
		return 19
	case .Default, .Inherit:
		return 1
	}
	return 1
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

// set_min_size tells the compositor how small the window may get.
set_min_size :: proc {
	set_min_size_app,
	set_min_size_window,
}

// set_fullscreen asks the compositor to make the window fullscreen.
set_fullscreen :: proc {
	set_fullscreen_app,
	set_fullscreen_window,
}

// maximized, fullscreen and focused report the toplevel state the compositor
// last told us about.
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
