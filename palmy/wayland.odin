#+build !darwin
package palmy

import "core:fmt"
import "core:sys/linux"
import "core:time"

// ---------------------------------------------------------------------------
// The Wayland backend.
//
// Request opcodes, taken from wayland.xml / xdg-shell.xml / xdg-decoration-v1
// / wlr-layer-shell-unstable-v1 / cursor-shape-v1.
// ---------------------------------------------------------------------------

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
// wl_pointer.release / wl_keyboard.release, both since interface version 3.
// The seat is bound up to version 7, so these are always available.
//
// These are *request* opcodes, which are numbered separately from events:
// wl_keyboard has exactly one request, so release is 0 even though `key` is
// event 3. Sending 3 here is an invalid request and the compositor drops the
// connection, which looks like the window simply vanishing.
WL_POINTER_RELEASE :: 1
WL_KEYBOARD_RELEASE :: 0

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
@(private)
DECORATION_SET_MODE :: 1

@(private)
SHM_FORMAT_XRGB8888 :: u32(1)

// Mouse buttons as reported by linux/input-event-codes.h.
@(private)
BTN_LEFT :: 0x110
@(private)
BTN_RIGHT :: 0x111
@(private)
BTN_MIDDLE :: 0x112

// Wl_State is every Wayland object this client owns, plus the shm pool that
// backs the two pixel buffers.
Wl_State :: struct {
	// Globals.
	registry:           u32,
	compositor:         u32,
	compositor_ver:     u32,
	shm:                u32,
	xdg_wm_base:        u32,
	xdg_wm_base_ver:    u32,
	seat:               u32,
	decor_manager:      u32,
	cursor_manager:     u32,
	cursor_manager_ver: u32,
	layer_shell:        u32,

	// Objects.
	surface:            u32,
	xdg_surface:        u32,
	xdg_toplevel:       u32,
	decoration:         u32,
	layer_surface:      u32,
	pointer:            u32,
	keyboard:           u32,
	cursor_device:      u32,
	pointer_serial:     u32,
	// The serial of the last button press, which a drag must start from.
	press_serial:       u32,
	// The serial of the last press of a button or a key, which a popup's
	// grab must name.
	grab_serial:        u32,
	// Where the surface the pointer is over has its (0, 0), in window
	// coordinates: zero for the window, a popup's position for a popup.
	pointer_origin:     [2]f32,
	frame_cb:           u32,

	// Keys held on a keyboard that appeared while the window was running,
	// waiting to be delivered as presses. See "A keyboard that arrives
	// holding a key" below.
	kbd_seen_absent:    bool,
	kbd_fresh:          bool,
	kbd_bound_at:       time.Time,
	held:               [16]u32,
	held_n:             int,
	sync_cb:            u32,
	sync_done:          bool,

	// Shared memory.
	pool:               u32,
	pool_fd:            linux.Fd,
	pool_mem:           []u8,
	pool_size:          int,
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

@(private)
wl_open :: proc(w: ^Window, decorate: bool) -> (err: string) {
	if e := conn_open(&w.conn); e != "" {
		return e
	}
	c := &w.conn

	w.wl.registry = new_id(c, .Registry)
	request(c, DISPLAY_ID, WL_DISPLAY_GET_REGISTRY, Obj(w.wl.registry))

	// One roundtrip is enough to see the whole global list.
	if e := roundtrip(w); e != "" {
		return e
	}

	if w.wl.compositor == 0 {
		return "the compositor does not advertise wl_compositor"
	}
	if w.wl.shm == 0 {
		return "the compositor does not advertise wl_shm"
	}
	if w.wl.xdg_wm_base == 0 && !w.use_layer {
		return "the compositor does not advertise xdg_wm_base (palmy needs xdg-shell)"
	}

	// The clipboard devices, when the compositor has the protocols.
	wl_clip_init(w)

	w.wl.surface = new_id(c, .Surface)
	request(c, w.wl.compositor, WL_COMPOSITOR_CREATE_SURFACE, Obj(w.wl.surface))

	if w.use_layer {
		// A layer surface is its own shell: no toplevel, no decorations, and
		// the compositor places it rather than the window manager.
		if w.wl.layer_shell == 0 {
			return "the compositor does not implement wlr-layer-shell"
		}
		w.wl.layer_surface = new_id(c, .Layer_Surface)
		request(
			c,
			w.wl.layer_shell,
			LAYER_SHELL_GET_LAYER_SURFACE,
			Obj(w.wl.layer_surface),
			Obj(w.wl.surface),
			Obj(0), // let the compositor pick the output
			u32(w.layer),
			w.app_id,
		)
		request(c, w.wl.layer_surface, LAYER_SURFACE_SET_SIZE, u32(w.width), u32(w.height))
		request(c, w.wl.layer_surface, LAYER_SURFACE_SET_ANCHOR, transmute(u32)w.anchor)
		request(c, w.wl.layer_surface, LAYER_SURFACE_SET_KEYBOARD, u32(w.keyboard_mode))
		request(c, w.wl.layer_surface, LAYER_SURFACE_SET_EXCLUSIVE_ZONE, i32(w.exclusive_zone))
		request(
			c,
			w.wl.layer_surface,
			LAYER_SURFACE_SET_MARGIN,
			i32(w.layer_margin[0]),
			i32(w.layer_margin[1]),
			i32(w.layer_margin[2]),
			i32(w.layer_margin[3]),
		)
		request(c, w.wl.surface, WL_SURFACE_COMMIT)
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

	w.wl.xdg_surface = new_id(c, .Xdg_Surface)
	request(c, w.wl.xdg_wm_base, XDG_WM_BASE_GET_XDG_SURFACE, Obj(w.wl.xdg_surface), Obj(w.wl.surface))

	w.wl.xdg_toplevel = new_id(c, .Xdg_Toplevel)
	request(c, w.wl.xdg_surface, XDG_SURFACE_GET_TOPLEVEL, Obj(w.wl.xdg_toplevel))
	request(c, w.wl.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, w.title)
	request(c, w.wl.xdg_toplevel, XDG_TOPLEVEL_SET_APP_ID, w.app_id)

	if decorate && w.wl.decor_manager != 0 {
		w.wl.decoration = new_id(c, .Decoration)
		request(
			c,
			w.wl.decor_manager,
			DECOR_MANAGER_GET_DECORATION,
			Obj(w.wl.decoration),
			Obj(w.wl.xdg_toplevel),
		)
		request(c, w.wl.decoration, DECORATION_SET_MODE, u32(2)) // server_side
	}

	request(c, w.wl.surface, WL_SURFACE_COMMIT)
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

@(private)
wl_close :: proc(w: ^Window) {
	c := &w.conn
	// Popups go first: a toplevel destroyed under a live popup is an error.
	wl_popups_close(w)
	wl_destroy_buffers(w)
	if w.wl.layer_surface != 0 {
		request(c, w.wl.layer_surface, LAYER_SURFACE_DESTROY)
	}
	if w.wl.xdg_toplevel != 0 {
		request(c, w.wl.xdg_toplevel, 0)
	}
	if w.wl.xdg_surface != 0 {
		request(c, w.wl.xdg_surface, 0)
	}
	if w.wl.surface != 0 {
		request(c, w.wl.surface, WL_SURFACE_DESTROY)
	}
	conn_flush(c)
}

@(private)
roundtrip :: proc(w: ^Window) -> (err: string) {
	c := &w.conn
	w.wl.sync_cb = new_id(c, .Callback)
	w.wl.sync_done = false
	request(c, DISPLAY_ID, WL_DISPLAY_SYNC, Obj(w.wl.sync_cb))
	conn_flush(c)

	start := time.now()
	for !w.wl.sync_done {
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
	request(c, w.wl.registry, WL_REGISTRY_BIND, name, iface, version, Obj(id))
	return id
}

// ---------------------------------------------------------------------------
// Event dispatch
// ---------------------------------------------------------------------------

@(private)
wl_on_event :: proc(w: ^Window, id: u32, opcode: u16, r: ^Reader) {
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
				w.wl.compositor_ver = v
				w.wl.compositor = bind_global(w, name, iface, v, .Compositor)
			case "wl_shm":
				w.wl.shm = bind_global(w, name, iface, 1, .Shm)
			case "xdg_wm_base":
				w.wl.xdg_wm_base_ver = min(version, 3)
				w.wl.xdg_wm_base = bind_global(w, name, iface, w.wl.xdg_wm_base_ver, .Xdg_Wm_Base)
			case "wl_seat":
				if w.wl.seat == 0 {
					w.wl.seat = bind_global(w, name, iface, min(version, 7), .Seat)
				}
			case "zxdg_decoration_manager_v1":
				w.wl.decor_manager = bind_global(w, name, iface, 1, .Decor_Manager)
			case "zwlr_layer_shell_v1":
				w.wl.layer_shell = bind_global(w, name, iface, min(version, 4), .Layer_Shell)
			case "wl_data_device_manager", "zwp_primary_selection_device_manager_v1", "ext_data_control_manager_v1", "zwlr_data_control_manager_v1":
				wl_clip_bind(w, name, iface, version)
			case "wp_cursor_shape_manager_v1":
				w.wl.cursor_manager_ver = min(version, 1)
				w.wl.cursor_manager = bind_global(w, name, iface, w.wl.cursor_manager_ver, .Cursor_Manager)
			}
		case 1:
			// global_remove: nothing we bind is hot-unpluggable in this version.
		}

	case .Callback:
		if id == w.wl.sync_cb {
			w.wl.sync_done = true
			retire_id(c, id)
			w.wl.sync_cb = 0
		}

	case .Frame_Callback:
		if id == w.wl.frame_cb {
			w.frame_pending = false
			w.frame_ready = true
			retire_id(c, id)
			w.wl.frame_cb = 0
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
			if caps & 1 != 0 && w.wl.pointer == 0 {
				w.wl.pointer = new_id(c, .Pointer)
				request(c, w.wl.seat, WL_SEAT_GET_POINTER, Obj(w.wl.pointer))

				// cursor-shape-v1 lets the compositor draw its own themed
				// cursor; without it we simply never set one.
				if w.wl.cursor_manager != 0 {
					w.wl.cursor_device = new_id(c, .Cursor_Device)
					request(
						c,
						w.wl.cursor_manager,
						CURSOR_MANAGER_GET_POINTER,
						Obj(w.wl.cursor_device),
						Obj(w.wl.pointer),
					)
				}
			}
			if caps & 2 != 0 && w.wl.keyboard == 0 {
				w.wl.keyboard = new_id(c, .Keyboard)
				request(c, w.wl.seat, WL_SEAT_GET_KEYBOARD, Obj(w.wl.keyboard))
				// A keyboard that was not there before: see "A keyboard that
				// arrives holding a key".
				w.wl.kbd_fresh = w.wl.kbd_seen_absent
				w.wl.kbd_bound_at = time.now()
				w.wl.held_n = 0
			}
			if caps & 2 == 0 {
				w.wl.kbd_seen_absent = true
			}

			// A capability can also go *away*, and dropping that on the floor
			// was a real bug: the object id stayed non-zero, so the `== 0`
			// guards above skipped re-binding when the capability came back,
			// and the window silently never received another key.
			//
			// It only shows up where the seat has no permanent keyboard. On a
			// headless compositor with no input devices, every `wtype` adds a
			// virtual keyboard and removes it again, so the capability
			// genuinely toggles -- the first invocation was delivered and
			// every one after it went nowhere, which broke multi-step
			// recordings and any on-screen keyboard, IME or remote-input tool
			// that attaches and detaches. On a machine with a real keyboard
			// the capability never clears and nothing looked wrong.
			if caps & 2 == 0 && w.wl.keyboard != 0 {
				request(c, w.wl.keyboard, WL_KEYBOARD_RELEASE)
				retire_id(c, w.wl.keyboard)
				w.wl.keyboard = 0
				// The seat is gone, so nothing will send a leave: clear the
				// input state by hand or a held modifier sticks forever.
				w.input.focused = false
				w.input.mods = {}
				w.repeat_key = 0
				w.repeat_sym = 0
			}
			if caps & 1 == 0 && w.wl.pointer != 0 {
				if w.wl.cursor_device != 0 {
					request(c, w.wl.cursor_device, 0) // destroy
					retire_id(c, w.wl.cursor_device)
					w.wl.cursor_device = 0
				}
				request(c, w.wl.pointer, WL_POINTER_RELEASE)
				retire_id(c, w.wl.pointer)
				w.wl.pointer = 0
				w.input.down = {}
				w.input.over_surface = false
			}
			conn_flush(c)
		}

	case .Pointer:
		w.input_dirty = true
		in_ := &w.input
		switch opcode {
		case 0:
			// enter(serial, surface, x, y)
			w.wl.pointer_serial = r_u32(r)
			// A popup's coordinates are its own; everything above this
			// layer works in the window's.
			w.wl.pointer_origin, _ = wl_popup_origin(w, r_u32(r))
			in_.mouse = [2]f32{r_fixed(r), r_fixed(r)} + w.wl.pointer_origin
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
			p := [2]f32{r_fixed(r), r_fixed(r)} + w.wl.pointer_origin
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
			w.clip.serial = serial
			in_.button_at = in_.mouse
			if state == 1 {
				in_.down[mb] = true
				in_.pressed[mb] = true
				in_.click_serial = serial
				w.wl.press_serial = serial
				w.wl.grab_serial = serial
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
			// Drop any repeat in flight: it was captured under the previous
			// keymap, and resolving its keycode against the new one would
			// deliver a different character. Virtual keyboards (wtype, remote
			// input) attach and detach constantly, re-sending the keymap each
			// time, so this is not a rare path.
			w.repeat_key = 0
			w.repeat_sym = 0
		case 1:
			// enter(serial, surface, keys)
			w.clip.serial = r_u32(r)
			r_u32(r)
			keys := r_array(r)
			w.input.focused = true
			wl_take_held(w, keys)
		case 2:
			wl_deliver_held(w)
			w.input.focused = false
			w.repeat_key = 0
			w.input.mods = {}
		case 3:
			// key(serial, time, key, state)
			wl_deliver_held(w)
			w.clip.serial = r_u32(r)
			r_u32(r)
			code := r_u32(r)
			state := r_u32(r)
			if state == 1 {
				w.wl.grab_serial = w.clip.serial
				wl_key_press(w, code)
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
			// The modifiers that go with an enter follow it, so held keys
			// wait for them: Shift+a held across a re-bind is an `A`.
			wl_deliver_held(w)
		case 5:
			w.repeat_rate = int(r_i32(r))
			w.repeat_delay = int(r_i32(r))
		}

	case .Data_Device, .Data_Source, .Data_Offer, .Primary_Device, .Primary_Source, .Primary_Offer, .Control_Device, .Control_Offer:
		wl_clip_event(w, kind_of(c, id), id, opcode, r)

	case .Drag_Source:
		dnd_source_event(w, id, opcode, r)

	case .Popup_Xdg_Surface, .Xdg_Popup, .Popup_Buffer:
		wl_popup_event(w, kind_of(c, id), id, opcode, r)

	case:
		// Interfaces we create but never listen to.
	}
}

// ---------------------------------------------------------------------------
// A keyboard that arrives holding a key
//
// On a seat with no permanent keyboard -- a headless compositor, or a machine
// driven by a virtual keyboard (wtype, an on-screen keyboard, remote input) --
// the keyboard capability comes and goes with the device. When it comes, the
// client has to ask for a wl_keyboard (above, in the seat's capabilities) and
// the compositor only starts talking to it once that request has arrived.
// The device does not wait for that: wtype attaches and presses its first key
// in the same breath, and a client that is in the middle of painting a frame
// asks for its keyboard a few milliseconds too late. The press went to nobody.
//
// It is not quite gone, though. When the new wl_keyboard is created for a
// focused window, its enter lists the keys the seat holds down, and the
// release follows as an ordinary key event. So the press is recoverable: a key
// held on a keyboard that did not exist when the seat last said "no keyboard"
// was pressed after that, which is exactly the press that was missed.
//
// What it cannot recover is a key pressed *and released* before the request
// for the keyboard reaches the compositor: then nothing anywhere says it
// happened. sway queues the capability for the client and only flushes it
// once its own loop goes idle -- a frame of software rendering, on a headless
// output -- while wtype's press and release land a few milliseconds apart. In
// sway's server-side log (WAYLAND_DEBUG=server) that is a get_keyboard
// arriving 25 ms after the capability was queued and 17 ms after the release.
// No client can win that, so a seat driven by short-lived virtual keyboards
// should keep one keyboard attached for its whole life, which is what
// apps/tools/headless-record.sh does. Measured on headless sway 1.9 in the
// arm64 VM, one `wtype <letter>` per key 150 ms apart, a busy VM: 79-82 of
// 100 keys lost before this, 14-18 of 100 after, and 0 of 200 -- with this
// or without it, even with no gap at all -- once a resident keyboard is held.
//
// The keys of an ordinary enter are NOT presses, and must never become them:
// a window that opens while the Return that launched it is still held, or
// that gains focus by Alt+Tab, would receive a Return or a Tab it was never
// meant to. So this applies only to the first enter on a keyboard bound
// because the capability *appeared* -- the seat must have reported no keyboard
// before -- and only within KBD_FRESH_MS of binding it. A seat with a real
// keyboard never loses the capability, so this never runs there.
// ---------------------------------------------------------------------------

@(private)
KBD_FRESH_MS :: 1000

@(private)
wl_take_held :: proc(w: ^Window, keys: []u8) {
	fresh := w.wl.kbd_fresh
	w.wl.kbd_fresh = false
	w.wl.held_n = 0
	if !fresh || time.duration_milliseconds(time.since(w.wl.kbd_bound_at)) > KBD_FRESH_MS {
		return
	}
	for i := 0; i + 4 <= len(keys) && w.wl.held_n < len(w.wl.held); i += 4 {
		w.wl.held[w.wl.held_n] = (^u32)(raw_data(keys[i:]))^
		w.wl.held_n += 1
	}
}

@(private)
wl_deliver_held :: proc(w: ^Window) {
	n := w.wl.held_n
	w.wl.held_n = 0
	for code in w.wl.held[:n] {
		wl_key_press(w, code)
	}
}

@(private)
wl_key_press :: proc(w: ^Window, code: u32) {
	feed_key(w, code, false)
	if keymap_repeats(&w.keymap, code) && w.repeat_rate > 0 {
		w.repeat_key = code
		w.repeat_at = time.time_add(time.now(), time.Duration(w.repeat_delay) * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------
// Shared memory buffers
// ---------------------------------------------------------------------------

@(private)
wl_destroy_buffers :: proc(w: ^Window) {
	c := &w.conn
	for &b in w.buffers {
		if b.id != 0 {
			request(c, b.id, WL_BUFFER_DESTROY)
			retire_id(c, b.id)
			b = {}
		}
	}
	if w.wl.pool != 0 {
		request(c, w.wl.pool, WL_SHM_POOL_DESTROY)
		retire_id(c, w.wl.pool)
		w.wl.pool = 0
	}
	if w.wl.pool_mem != nil {
		linux.munmap(raw_data(w.wl.pool_mem), uint(len(w.wl.pool_mem)))
		w.wl.pool_mem = nil
	}
	// The pool fd is NOT closed here. conn_flush closes every descriptor it
	// has passed over SCM_RIGHTS once the message is on the wire, which is the
	// right ownership rule for fd passing and which already covers this one.
	// Closing it a second time here freed a descriptor number the application
	// had since reused: resizing a window three seconds into a call closed the
	// audio capture pipe, and the only symptom was a level meter that stopped
	// moving. Keep the number for diagnostics and let the connection own it.
	w.wl.pool_fd = 0
}

@(private)
wl_alloc_buffers :: proc(w: ^Window) -> (err: string) {
	wl_destroy_buffers(w)
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

	// Recorded for diagnostics only; `request` below hands it to the
	// compositor and conn_flush closes our copy once it is sent.
	w.wl.pool_fd = fd
	w.wl.pool_mem = ([^]u8)(mem)[:total]
	w.wl.pool_size = total

	w.wl.pool = new_id(c, .Shm_Pool)
	request(c, w.wl.shm, WL_SHM_CREATE_POOL, Obj(w.wl.pool), Fd(fd), i32(total))

	for i in 0 ..< 2 {
		b := &w.buffers[i]
		b.offset = frame * i
		b.w, b.h = dw, dh
		b.busy = false
		b.id = new_id(c, .Buffer)
		b.px = (([^]u32)(raw_data(w.wl.pool_mem[b.offset:])))[:dw * dh]
		request(
			c,
			w.wl.pool,
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
	request(c, w.wl.compositor, WL_COMPOSITOR_CREATE_REGION, Obj(region))
	request(c, region, WL_REGION_ADD, i32(0), i32(0), i32(w.width), i32(w.height))
	request(c, w.wl.surface, WL_SURFACE_SET_OPAQUE_REGION, Obj(region))
	request(c, region, 0) // wl_region.destroy
	retire_id(c, region)

	if w.scale != 1 {
		request(c, w.wl.surface, WL_SURFACE_SET_BUFFER_SCALE, i32(w.scale))
	}
	return ""
}

// wl_present pushes a finished buffer to the compositor and asks for the next
// frame callback so that drawing stays paced to the display.
@(private)
wl_present :: proc(w: ^Window, b: ^Shm_Buffer, damage: []Damage_Rect) {
	c := &w.conn

	if w.need_configure_ack {
		if w.wl.layer_surface != 0 {
			request(c, w.wl.layer_surface, LAYER_SURFACE_ACK_CONFIGURE, w.configure_serial)
		} else {
			request(c, w.wl.xdg_surface, XDG_SURFACE_ACK_CONFIGURE, w.configure_serial)
			request(
				c,
				w.wl.xdg_surface,
				XDG_SURFACE_SET_WINDOW_GEOMETRY,
				i32(0),
				i32(0),
				i32(w.width),
				i32(w.height),
			)
		}
		w.need_configure_ack = false
	}

	w.wl.frame_cb = new_id(c, .Frame_Callback)
	request(c, w.wl.surface, WL_SURFACE_FRAME, Obj(w.wl.frame_cb))
	w.frame_pending = true

	request(c, w.wl.surface, WL_SURFACE_ATTACH, Obj(b.id), i32(0), i32(0))
	for r in damage {
		request(c, w.wl.surface, WL_SURFACE_DAMAGE_BUFFER, i32(r.x), i32(r.y), i32(r.w), i32(r.h))
	}
	request(c, w.wl.surface, WL_SURFACE_COMMIT)
	conn_flush(c)

	b.busy = true
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
wl_set_title :: proc(w: ^Window) {
	request(&w.conn, w.wl.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, w.title)
}

@(private)
wl_set_min_size :: proc(w: ^Window, width, height: int) {
	request(&w.conn, w.wl.xdg_toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, i32(width), i32(height))
}

@(private)
wl_set_fullscreen :: proc(w: ^Window, on: bool) {
	if on {
		request(&w.conn, w.wl.xdg_toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, Obj(0))
	} else {
		request(&w.conn, w.wl.xdg_toplevel, XDG_TOPLEVEL_UNSET_FULLSCREEN)
	}
}

// wl_set_cursor asks the compositor for a named pointer shape. It is a no-op
// when the compositor does not implement cursor-shape-v1.
@(private)
wl_set_cursor :: proc(w: ^Window, want: Cursor) {
	if w.wl.cursor_device == 0 || w.wl.pointer_serial == 0 || w.cursor_shape == want {
		return
	}
	w.cursor_shape = want
	request(
		&w.conn,
		w.wl.cursor_device,
		CURSOR_DEVICE_SET_SHAPE,
		w.wl.pointer_serial,
		cursor_shape_code(want),
	)
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
