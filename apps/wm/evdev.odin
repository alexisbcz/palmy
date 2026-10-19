// Raw Linux input.
//
// Nested, the compositor gets its input second-hand: the host delivers palmy
// events and `handle_keys` / `handle_pointer` translate them. On bare metal
// there is no host, and the only thing underneath us is `/dev/input/event*`
// and a stream of 24-byte `struct input_event` records.
//
// This file is that layer. It decodes the records, classifies the devices it
// finds under `/sys/class/input`, and turns kernel-shaped input into the same
// normalized shape the nested path already produces, so the two converge at
// `handle_keys` / `handle_pointer` rather than forking into two compositors.
//
// It deliberately does *not* open the device nodes itself when it can avoid
// it. `/dev/input/event*` is root:input, and the right way to get an fd is
// logind's TakeDevice over D-Bus. That lives in seat.odin; the seam is the two
// function pointers `ev_open_device` / `ev_close_device` plus `ev_pause_all` /
// `ev_resume_all`. The default implementations just open() the node, which
// works when the process happens to have permission (a seat session with the
// device ACL, or root) and fails cleanly when it does not.
//
// On Palmy the direct open *is* the path: there is no logind, and a
// session user is in `input`. It has run inside QEMU (apps/wm/qemu-test.sh)
// against virtio-keyboard, virtio-tablet — which needed the Abs_Pointer kind,
// because it advertises BTN_TOUCH and was being taken for a touchpad — and the
// PS/2 keyboard and mouse the machine also has.
package wm

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import p "palmy:."

// ---------------------------------------------------------------------------
// Kernel ABI
// ---------------------------------------------------------------------------

// Ev_Input_Event is `struct input_event` on a 64-bit kernel: a struct timeval
// of two longs, then type, code and value. 24 bytes, and the whole decoder
// turns on getting that number right.
Ev_Input_Event :: struct {
	sec:   i64,
	usec:  i64,
	type:  u16,
	code:  u16,
	value: i32,
}

EV_EVENT_SIZE :: 24

EV_SYN :: 0x00
EV_KEY :: 0x01
EV_REL :: 0x02
EV_ABS :: 0x03
EV_MSC :: 0x04
EV_SW :: 0x05
EV_LED :: 0x11
EV_SND :: 0x12
EV_REP :: 0x14
EV_FF :: 0x15

EV_SYN_REPORT :: 0
EV_SYN_DROPPED :: 3

EV_REL_X :: 0x00
EV_REL_Y :: 0x01
EV_REL_HWHEEL :: 0x06
EV_REL_DIAL :: 0x07
EV_REL_WHEEL :: 0x08
EV_REL_WHEEL_HI_RES :: 0x0b
EV_REL_HWHEEL_HI_RES :: 0x0c

EV_ABS_X :: 0x00
EV_ABS_Y :: 0x01
EV_ABS_PRESSURE :: 0x18
EV_ABS_MT_SLOT :: 0x2f
EV_ABS_MT_TOUCH_MAJOR :: 0x30
EV_ABS_MT_TOUCH_MINOR :: 0x31
EV_ABS_MT_ORIENTATION :: 0x34
EV_ABS_MT_POSITION_X :: 0x35
EV_ABS_MT_POSITION_Y :: 0x36
EV_ABS_MT_TOOL_TYPE :: 0x37
EV_ABS_MT_TRACKING_ID :: 0x39
EV_ABS_MT_PRESSURE :: 0x3a
EV_ABS_MAX :: 0x3f

// Button codes. main.odin already owns the unprefixed BTN_LEFT / BTN_RIGHT /
// BTN_MIDDLE names for the Wayland wire, and this is one package, so these
// carry the prefix even though the values are identical.
EV_BTN_LEFT :: 0x110
EV_BTN_RIGHT :: 0x111
EV_BTN_MIDDLE :: 0x112
EV_BTN_SIDE :: 0x113
EV_BTN_EXTRA :: 0x114
EV_BTN_TOOL_PEN :: 0x140
EV_BTN_TOOL_FINGER :: 0x145
EV_BTN_TOUCH :: 0x14a
EV_BTN_STYLUS :: 0x14b
EV_BTN_TOOL_DOUBLETAP :: 0x14d
EV_BTN_TOOL_TRIPLETAP :: 0x14e
EV_BTN_TOOL_QUADTAP :: 0x14f
EV_BTN_TOOL_QUINTTAP :: 0x148

EV_KEY_ESC :: 1
EV_KEY_Q :: 16
EV_KEY_P :: 25
EV_KEY_A :: 30
EV_KEY_L :: 38
EV_KEY_Z :: 44
EV_KEY_M :: 50
EV_KEY_SPACE :: 57
EV_KEY_LEFTSHIFT :: 42
EV_KEY_LEFTCTRL :: 29
EV_KEY_LEFTALT :: 56
EV_KEY_LEFTMETA :: 125
EV_KEY_CAPSLOCK :: 58
EV_KEY_MAX :: 0x2ff

EV_INPUT_PROP_POINTER :: 0
EV_INPUT_PROP_DIRECT :: 1
EV_INPUT_PROP_BUTTONPAD :: 2
EV_INPUT_PROP_SEMI_MT :: 3
EV_INPUT_PROP_TOPBUTTONPAD :: 4

// The evdev-to-X11 keycode offset. A keycode on the wire to a Wayland client
// is the evdev code; the same key in an xkb keymap is that plus eight. Getting
// this backwards is the classic way to ship a keyboard that types gibberish.
EV_XKB_OFFSET :: 8

// ioctl request encoding: _IOC(dir, type, nr, size).
ev_ioc :: proc "contextless" (dir, typ, nr, size: u32) -> u32 {
	return (dir << 30) | (size << 16) | (typ << 8) | nr
}
EV_IOC_READ :: 2
EV_IOC_WRITE :: 1

ev_ioc_gname :: proc "contextless" (n: u32) -> u32 {return ev_ioc(EV_IOC_READ, 'E', 0x06, n)}
ev_ioc_gprop :: proc "contextless" (n: u32) -> u32 {return ev_ioc(EV_IOC_READ, 'E', 0x09, n)}
ev_ioc_gbit :: proc "contextless" (ev, n: u32) -> u32 {return ev_ioc(EV_IOC_READ, 'E', 0x20 + ev, n)}
ev_ioc_gabs :: proc "contextless" (a: u32) -> u32 {return ev_ioc(EV_IOC_READ, 'E', 0x40 + a, 24)}
EV_IOC_GID :: 0x80084502 // _IOR('E', 0x02, struct input_id)
EV_IOC_GRAB :: 0x40044590 // _IOW('E', 0x90, int)
EV_IOC_SCLOCKID :: 0x400445a0 // _IOW('E', 0xa0, int)

// ---------------------------------------------------------------------------
// Capability bitmaps
// ---------------------------------------------------------------------------

Ev_Caps :: struct {
	ev:   [1]u64,
	key:  [12]u64, // KEY_MAX is 0x2ff, so 768 bits
	rel:  [1]u64,
	abs:  [1]u64,
	msc:  [1]u64,
	sw:   [1]u64,
	led:  [1]u64,
	prop: [1]u64,
}

ev_bit :: proc(bits: []u64, i: int) -> bool {
	w := i / 64
	if i < 0 || w >= len(bits) {
		return false
	}
	return bits[w] & (u64(1) << uint(i % 64)) != 0
}

ev_set_bit :: proc(bits: []u64, i: int) {
	w := i / 64
	if i < 0 || w >= len(bits) {
		return
	}
	bits[w] |= u64(1) << uint(i % 64)
}

ev_clear_bit :: proc(bits: []u64, i: int) {
	w := i / 64
	if i < 0 || w >= len(bits) {
		return
	}
	bits[w] &~= u64(1) << uint(i % 64)
}

// ev_parse_bitmap reads the format sysfs uses for capability files: hex words
// most-significant first, space separated, with the *last* token holding bits
// 0..63. "ffff0000 0 0 0 0" is bits 16..31 of word 4.
ev_parse_bitmap :: proc(text: string, out: []u64) {
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	toks := strings.fields(strings.trim_space(text), context.temp_allocator)
	n := len(toks)
	for i in 0 ..< n {
		w := n - 1 - i // last token is word 0
		if w >= len(out) {
			continue
		}
		v, ok := strconv.parse_u64_of_base(toks[i], 16)
		if ok {
			out[w] = v
		}
	}
}

Ev_Kind :: enum u8 {
	Keyboard,
	Mouse,
	Touchpad,
	Touchscreen,
	Tablet,
	Switch,
	Joystick,
	// An absolute pointer that is not a touch surface: QEMU's virtio-tablet,
	// a KVM switch's emulated mouse, a VNC console. ABS_X/ABS_Y name a point
	// on the screen, scaled by absinfo, and the buttons are mouse buttons.
	Abs_Pointer,
}
Ev_Kinds :: bit_set[Ev_Kind;u8]

// ev_classify is the whole of device detection, and it runs off bitmaps alone
// so it can be driven either from EVIOCGBIT on a real fd or from the sysfs
// capability files, which need no privilege at all. That is what lets the
// classification be tested against this machine's real hardware without ever
// opening a device node.
ev_classify :: proc(c: ^Ev_Caps, name: string) -> Ev_Kinds {
	k := Ev_Kinds{}
	has_ev :: proc(c: ^Ev_Caps, t: int) -> bool {return ev_bit(c.ev[:], t)}

	abs_x := ev_bit(c.abs[:], EV_ABS_X) && ev_bit(c.abs[:], EV_ABS_Y)
	mt := ev_bit(c.abs[:], EV_ABS_MT_POSITION_X) && ev_bit(c.abs[:], EV_ABS_MT_POSITION_Y)
	direct := ev_bit(c.prop[:], EV_INPUT_PROP_DIRECT)
	pointer_prop := ev_bit(c.prop[:], EV_INPUT_PROP_POINTER)
	buttonpad := ev_bit(c.prop[:], EV_INPUT_PROP_BUTTONPAD)
	pen := ev_bit(c.key[:], EV_BTN_TOOL_PEN) || ev_bit(c.key[:], EV_BTN_STYLUS)
	finger := ev_bit(c.key[:], EV_BTN_TOOL_FINGER)
	touch := ev_bit(c.key[:], EV_BTN_TOUCH)

	if has_ev(c, EV_ABS) && (abs_x || mt) {
		mouse_btn := ev_bit(c.key[:], EV_BTN_LEFT) || ev_bit(c.key[:], EV_BTN_RIGHT)
		switch {
		case pen:
			k += {.Tablet}
		case !mt && !finger && !buttonpad && !direct && mouse_btn:
			// No fingers, no MT, just a position and mouse buttons: this is
			// a pointer that reports where it is rather than how far it
			// moved. QEMU's virtio-tablet also advertises BTN_TOUCH, so the
			// touch bit cannot rule it out. Treating it as a touchpad would
			// turn every jump into a swipe.
			k += {.Abs_Pointer}
		case direct && touch:
			k += {.Touchscreen}
		case finger || buttonpad || pointer_prop:
			k += {.Touchpad}
		case touch && !direct:
			// A touch surface that says nothing else about itself. Treat an
			// absolute touch device with no DIRECT property as a touchpad:
			// that is the conservative choice, because a touchscreen handled
			// as a touchpad is merely odd, while the reverse warps the cursor.
			k += {.Touchpad}
		}
	}

	if has_ev(c, EV_REL) && ev_bit(c.rel[:], EV_REL_X) && ev_bit(c.rel[:], EV_REL_Y) {
		if ev_bit(c.key[:], EV_BTN_LEFT) || ev_bit(c.key[:], EV_BTN_RIGHT) || ev_bit(c.key[:], EV_BTN_MIDDLE) {
			k += {.Mouse}
		}
	}

	// A keyboard is a device that can type. Requiring the whole of a row
	// rejects the power buttons, lid switches and consumer-control endpoints
	// that all advertise EV_KEY with a handful of codes.
	if has_ev(c, EV_KEY) {
		typing := 0
		for code in ([?]int{EV_KEY_Q, EV_KEY_P, EV_KEY_A, EV_KEY_L, EV_KEY_Z, EV_KEY_M, EV_KEY_SPACE, EV_KEY_ESC}) {
			if ev_bit(c.key[:], code) {
				typing += 1
			}
		}
		if typing >= 7 {
			k += {.Keyboard}
		}
	}

	if has_ev(c, EV_SW) && c.sw[0] != 0 {
		k += {.Switch}
	}
	if ev_bit(c.key[:], 0x120) { // BTN_TRIGGER
		k += {.Joystick}
	}

	// A handful of touchpads and trackpoints identify themselves only by name.
	lname := strings.to_lower(name, context.temp_allocator)
	if strings.contains(lname, "touchpad") || strings.contains(lname, "trackpad") {
		if has_ev(c, EV_ABS) {
			k += {.Touchpad}
			k -= {.Touchscreen}
		}
	}
	return k
}

// ---------------------------------------------------------------------------
// Normalized events
// ---------------------------------------------------------------------------

Ev_Kind_Of_Event :: enum u8 {
	Key,
	Pointer_Motion,
	Pointer_Motion_Absolute,
	Button,
	Axis,
	Axis_Stop,
	Touch_Down,
	Touch_Motion,
	Touch_Up,
	Gesture_Begin,
	Gesture_Update,
	Gesture_End,
	Device_Added,
	Device_Removed,
}

Ev_Axis_Kind :: enum u8 {
	Vertical,
	Horizontal,
}

Ev_Axis_Source :: enum u8 {
	Wheel,
	Finger,
	Continuous,
}

Ev_Gesture :: enum u8 {
	None,
	Swipe,
	Pinch,
	Hold,
}

// Ev_Event is one normalized input event. It is deliberately a single fat
// struct rather than a union: every consumer in this package switches on
// `kind` anyway, and a flat record replays and compares trivially in a test.
Ev_Event :: struct {
	kind:           Ev_Kind_Of_Event,
	time_ms:        u32,
	device:         ^Ev_Device,

	// Key
	keycode:        u32, // evdev code, i.e. the Wayland keycode
	sym:            u32, // resolved keysym, 0 when no keymap
	down:           bool,
	repeat:         bool,
	mods:           p.Modifiers,
	mods_depressed: u32,
	mods_latched:   u32,
	mods_locked:    u32,
	group:          u32,

	// Pointer
	dx, dy:         f64, // accelerated delta, in pixels
	udx, udy:       f64, // unaccelerated delta, in device units
	x, y:           f64, // absolute position, in pixels
	button:         u32, // EV_BTN_*

	// Axis
	axis:           Ev_Axis_Kind,
	value:          f64, // continuous scroll, in pixels
	v120:           i32, // 120 per wheel detent, as the kernel reports it
	source:         Ev_Axis_Source,

	// Touch and gestures
	slot:           i32,
	tracking_id:    i32,
	gesture:        Ev_Gesture,
	fingers:        int,
	scale:          f64,
}

// ev_xkb_keycode is the keycode this event carries when it is looked up in an
// xkb keymap, which is eight higher than the one that goes on the wire.
ev_xkb_keycode :: proc(e: Ev_Event) -> u32 {return e.keycode + EV_XKB_OFFSET}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

Ev_Accel_Profile :: enum u8 {
	Flat,
	Adaptive,
}

Ev_Config :: struct {
	// Pointer. Raw unaccelerated mouse input feels broken at any sensible
	// sensitivity, so the curve is always on; `accel_speed` in -1..1 is the
	// one knob a user turns.
	accel_profile:      Ev_Accel_Profile,
	accel_speed:        f64, // -1 slow .. 0 default .. 1 fast
	accel_min:          f64, // factor at rest
	accel_max:          f64, // factor at full tilt
	accel_threshold:    f64, // device units per millisecond at the knee
	left_handed:        bool,
	middle_emulation:   bool,

	// Scrolling
	natural_scroll:     bool,
	scroll_factor:      f64, // pixels per wheel detent
	touchpad_scroll_mm: f64, // pixels per millimetre of two-finger travel
	scroll_start_mm:    f64, // travel before two-finger scroll engages

	// Touchpad
	touchpad_dpi:       f64, // pixels per millimetre of one-finger travel
	tap_to_click:       bool,
	tap_and_drag:       bool,
	tap_timeout_ms:     u32,
	tap_move_mm:        f64,
	drag_timeout_ms:    u32,
	two_finger_scroll:  bool,
	clickfinger:        bool, // clickpad: finger count picks the button
	palm_touch_major:   i32, // 0 disables
	palm_pressure:      i32, // 0 disables
	disable_while_typing: bool,
	dwt_timeout_ms:     u32,

	// Keyboard
	repeat_rate:        int, // keys per second
	repeat_delay:       int, // milliseconds before the first repeat
	grab_devices:       bool,
}

ev_cfg := Ev_Config {
	accel_profile        = .Adaptive,
	accel_speed          = 0.0,
	accel_min            = 1.0,
	accel_max            = 2.5,
	accel_threshold      = 1.0,
	natural_scroll       = false,
	scroll_factor        = 15.0,
	touchpad_scroll_mm   = 18.0,
	scroll_start_mm      = 1.2,
	touchpad_dpi         = 11.0,
	tap_to_click         = true,
	tap_and_drag         = true,
	tap_timeout_ms       = 180,
	tap_move_mm          = 2.5,
	drag_timeout_ms      = 300,
	two_finger_scroll    = true,
	clickfinger          = true,
	palm_touch_major     = 700,
	palm_pressure        = 0,
	disable_while_typing = true,
	dwt_timeout_ms       = 400,
	repeat_rate          = 25,
	repeat_delay         = 400,
	grab_devices         = true,
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

EV_MAX_SLOTS :: 10

Ev_Abs_Info :: struct {
	value:      i32,
	minimum:    i32,
	maximum:    i32,
	fuzz:       i32,
	flat:       i32,
	resolution: i32, // units per millimetre, 0 when the kernel does not say
}

Ev_Slot :: struct {
	used:        bool,
	tracking_id: i32,
	x, y:        i32,
	px, py:      i32,
	has_prev:    bool,
	major:       i32,
	pressure:    i32,
	palm:        bool,
	lifted:      bool,
	down_ms:     u32,
	sx, sy:      i32,
	moved:       bool,
}

Ev_Device :: struct {
	path:         string,
	sysfs:        string,
	name:         string,
	fd:           linux.Fd,
	opened:       bool,
	paused:       bool,
	synthetic:    bool,
	gone:         bool, // read() said ENODEV: unplugged, waiting to be removed
	typed:        bool, // a key has come from it (logged once)
	kinds:        Ev_Kinds,
	caps:         Ev_Caps,
	bus:          u16,
	vendor:       u16,
	product:      u16,
	version:      u16,
	absinfo:      [EV_ABS_MAX + 1]Ev_Abs_Info,
	has_abs:      [EV_ABS_MAX + 1]bool,

	// Partial-read carry. A read() on an evdev fd can return any number of
	// bytes, including a count that splits a record down the middle.
	carry:        [EV_EVENT_SIZE]u8,
	carry_n:      int,

	// Per-frame accumulation, flushed on SYN_REPORT.
	rel:          [2]f64,
	have_rel:     bool,
	wheel:        [2]i32, // detents this frame
	wheel_hi:     [2]i32, // 120ths this frame
	have_hi:      [2]bool,
	frame_ms:     u32,
	last_frame_ms: u32,

	// Touchpad and touchscreen.
	slots:        [EV_MAX_SLOTS]Ev_Slot,
	cur_slot:     int,
	fingers:      int,
	prev_fingers: int,
	scroll_acc:   [2]f64,
	scrolling:    bool,
	touch_start_ms: u32,
	tap_fingers:  int,
	tap_valid:    bool,
	tap_pending_ms: u32,
	tap_pending:  bool,
	drag_held:    bool,
	gesture_kind: Ev_Gesture,
	gesture_on:   bool,
	gesture_fingers: int,
	clicked_btn:  u32,

	// Absolute pointer: an ABS_X or ABS_Y arrived this frame.
	abs_dirty:    bool,

	// What this device is holding down right now, so that unplugging it in
	// the middle of a chord releases exactly its own keys and buttons.
	keys_down:    [(EV_KEY_MAX + 64) / 64]u64,
}

// Package-level state. The package already uses this idiom (`server` in
// main.odin), and the brief forbids growing the Server struct.
ev_devices: [dynamic]^Ev_Device
ev_queue: [dynamic]Ev_Event
ev_pointer: [2]f64
ev_screen: [2]f64 = {1920, 1080}
ev_buttons: bit_set[Ev_Button_Slot;u8]
ev_last_key_ms: u32
ev_ready: bool
// Every device is paused because the session is not on the active VT (or
// logind paused it). A device that appears meanwhile is opened on resume.
ev_paused_all: bool

Ev_Button_Slot :: enum u8 {
	Left,
	Right,
	Middle,
}

// ---------------------------------------------------------------------------
// The seat seam
//
// seat.odin owns logind. All this file needs from it is: hand me an fd for
// this node, tell me when it is paused and when it comes back. It installs
// itself by assigning these two pointers; until it does, we fall back to
// opening the node directly, which succeeds only when the process already has
// permission.
// ---------------------------------------------------------------------------

Ev_Open_Proc :: #type proc(path: string) -> (linux.Fd, bool)
Ev_Close_Proc :: #type proc(path: string, fd: linux.Fd)

ev_open_device: Ev_Open_Proc = ev_open_direct
ev_close_device: Ev_Close_Proc = ev_close_direct

// ev_use_seat is the one line seat.odin (or main.odin) needs to hand this
// backend a logind-acquired fd instead of an open() of the device node:
//
//	ev_use_seat(
//	  proc(node: string) -> (linux.Fd, bool) {
//	      fd, _, err := seat_take_node(node)
//	      return fd, err == .None
//	  },
//	  proc(node: string, fd: linux.Fd) { ... ReleaseDevice ... },
//	)
//
// This file deliberately does not name seat.odin's procedures, so neither
// file has to exist for the other to compile.
ev_use_seat :: proc(open: Ev_Open_Proc, close: Ev_Close_Proc) {
	if open != nil {
		ev_open_device = open
	}
	if close != nil {
		ev_close_device = close
	}
}

ev_open_direct :: proc(path: string) -> (linux.Fd, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.NONBLOCK, .CLOEXEC})
	if err != .NONE {
		return 0, false
	}
	return fd, true
}

ev_close_direct :: proc(path: string, fd: linux.Fd) {
	_ = path
	linux.close(fd)
}

// ev_pause_all / ev_resume_all are what seat.odin calls on logind's
// PauseDevice and ResumeDevice signals: on a VT switch the fds stay open but
// stop delivering, and anything held down has to be released or the next
// session inherits a stuck modifier.
ev_pause_all :: proc() {
	ev_paused_all = true
	for d in ev_devices {
		d.paused = true
		ev_device_reset(d)
		d.keys_down = {}
	}
	ev_release_all()
}

ev_resume_all :: proc() {
	ev_paused_all = false
	for d in ev_devices {
		d.paused = false
		d.carry_n = 0
	}
}

// ev_grab_all takes (or gives back) exclusive use of every open device. A
// session that is switched away from must let go: EVIOCGRAB also keeps the
// kernel's own console keyboard handler from seeing keys, so a VT switched
// to while we hold the grab would get no keyboard at all, including the
// Ctrl+Alt+Fn that would switch back.
ev_grab_all :: proc(grab: bool) {
	if !ev_cfg.grab_devices {
		return
	}
	v := i32(grab ? 1 : 0)
	for d in ev_devices {
		if d.opened {
			linux.ioctl(d.fd, EV_IOC_GRAB, uintptr(v))
		}
	}
}

// ev_flush_all throws away whatever the devices queued while paused: those
// keys were typed into another VT.
ev_flush_all :: proc() {
	buf: [EV_EVENT_SIZE * 64]u8
	for d in ev_devices {
		if !d.opened {
			continue
		}
		for {
			n, err := linux.read(d.fd, buf[:])
			if err != .NONE || n < len(buf) {
				break
			}
		}
		d.carry_n = 0
	}
}

// ev_open_pending opens the devices that appeared while paused.
ev_open_pending :: proc() {
	for d in ev_devices {
		if !d.opened && ev_device_open(d) {
			fmt.printfln("wm: input: added %s  %s  %v", d.path, d.name, d.kinds)
		}
	}
}

// ev_reap_gone removes devices whose read() reported ENODEV.
ev_reap_gone :: proc() -> (changed: bool) {
	for i := len(ev_devices) - 1; i >= 0; i -= 1 {
		if ev_devices[i].gone {
			ev_device_remove(ev_devices[i])
			changed = true
		}
	}
	return
}

// ev_device_reset drops every scrap of per-frame and per-touch state. It runs
// on SYN_DROPPED (the kernel's buffer overflowed and the stream is no longer
// self-consistent) and on pause.
ev_device_reset :: proc(d: ^Ev_Device) {
	d.carry_n = 0
	d.rel = {}
	d.have_rel = false
	d.wheel = {}
	d.wheel_hi = {}
	d.have_hi = {}
	for i in 0 ..< EV_MAX_SLOTS {
		d.slots[i] = {}
	}
	d.cur_slot = 0
	d.fingers = 0
	d.prev_fingers = 0
	d.scroll_acc = {}
	d.scrolling = false
	d.tap_valid = false
	d.tap_pending = false
	d.gesture_on = false
}

// ev_release_all synthesises the releases for everything currently held, so a
// pause or a device loss cannot leave a key or a button stuck down.
ev_release_all :: proc() {
	t := now_ms()
	for b in Ev_Button_Slot {
		if b in ev_buttons {
			ev_buttons -= {b}
			append(&ev_queue, Ev_Event{kind = .Button, time_ms = t, button = ev_button_code(b), down = false})
		}
	}
	if ev_repeat.active {
		ev_repeat.active = false
	}
	xkb_release_all()
}

ev_button_code :: proc(b: Ev_Button_Slot) -> u32 {
	switch b {
	case .Left:
		return EV_BTN_LEFT
	case .Right:
		return EV_BTN_RIGHT
	case .Middle:
		return EV_BTN_MIDDLE
	}
	return EV_BTN_LEFT
}

ev_button_slot :: proc(code: u32) -> (Ev_Button_Slot, bool) {
	switch code {
	case EV_BTN_LEFT:
		return .Left, true
	case EV_BTN_RIGHT:
		return .Right, true
	case EV_BTN_MIDDLE:
		return .Middle, true
	}
	return .Left, false
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

ev_read_file :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// ev_scan walks /sys/class/input and builds an Ev_Device for every event node,
// classified from the sysfs capability files. Nothing is opened here: scanning
// needs no privilege, so the compositor can know exactly what hardware exists
// before it has an fd for any of it.
ev_scan :: proc() -> []^Ev_Device {
	out := make([dynamic]^Ev_Device)
	dir, derr := os.open("/sys/class/input")
	if derr != nil {
		return out[:]
	}
	defer os.close(dir)
	entries, rerr := os.read_dir(dir, -1, context.temp_allocator)
	if rerr != nil {
		return out[:]
	}
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if strings.has_prefix(e.name, "event") {
			append(&names, strings.clone(e.name, context.temp_allocator))
		}
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		return atoi(a[5:]) < atoi(b[5:])
	})
	for n in names {
		append(&out, ev_scan_one(n))
	}
	return out[:]
}

// ev_scan_one builds the Ev_Device for one event node ("event3") from sysfs.
// Nothing is opened. Hotplug calls it for a node that has just appeared.
ev_scan_one :: proc(n: string) -> ^Ev_Device {
	base := fmt.tprintf("/sys/class/input/%s/device", n)
	d := new(Ev_Device)
	d.path = fmt.aprintf("/dev/input/%s", n)
	d.sysfs = strings.clone(base)
	if s, ok := ev_read_file(fmt.tprintf("%s/name", base), context.temp_allocator); ok {
		d.name = strings.clone(strings.trim_space(s))
	}
	ev_caps_from_sysfs(&d.caps, base)
	if s, ok := ev_read_file(fmt.tprintf("%s/id/bustype", base), context.temp_allocator); ok {
		d.bus = u16(ev_parse_hex(strings.trim_space(s)))
	}
	if s, ok := ev_read_file(fmt.tprintf("%s/id/vendor", base), context.temp_allocator); ok {
		d.vendor = u16(ev_parse_hex(strings.trim_space(s)))
	}
	if s, ok := ev_read_file(fmt.tprintf("%s/id/product", base), context.temp_allocator); ok {
		d.product = u16(ev_parse_hex(strings.trim_space(s)))
	}
	d.kinds = ev_classify(&d.caps, d.name)
	return d
}

ev_parse_hex :: proc(s: string) -> u64 {
	v, _ := strconv.parse_u64_of_base(s, 16)
	return v
}

ev_caps_from_sysfs :: proc(c: ^Ev_Caps, base: string) {
	read :: proc(base, which: string, out: []u64) {
		if s, ok := ev_read_file(fmt.tprintf("%s/capabilities/%s", base, which), context.temp_allocator); ok {
			ev_parse_bitmap(s, out)
		}
	}
	read(base, "ev", c.ev[:])
	read(base, "key", c.key[:])
	read(base, "rel", c.rel[:])
	read(base, "abs", c.abs[:])
	read(base, "msc", c.msc[:])
	read(base, "sw", c.sw[:])
	read(base, "led", c.led[:])
	if s, ok := ev_read_file(fmt.tprintf("%s/properties", base), context.temp_allocator); ok {
		ev_parse_bitmap(s, c.prop[:])
	}
}

// ev_caps_from_fd is the same information taken from the device itself. It is
// what runs once seat.odin has handed us an fd; the sysfs path above is what
// runs before that, and the two must agree.
ev_caps_from_fd :: proc(c: ^Ev_Caps, fd: linux.Fd) {
	get :: proc(fd: linux.Fd, ev: u32, out: []u64) {
		n := u32(len(out) * 8)
		linux.ioctl(fd, ev_ioc_gbit(ev, n), uintptr(raw_data(out)))
	}
	get(fd, 0, c.ev[:])
	get(fd, EV_KEY, c.key[:])
	get(fd, EV_REL, c.rel[:])
	get(fd, EV_ABS, c.abs[:])
	get(fd, EV_MSC, c.msc[:])
	get(fd, EV_SW, c.sw[:])
	get(fd, EV_LED, c.led[:])
	linux.ioctl(fd, ev_ioc_gprop(8), uintptr(raw_data(c.prop[:])))
}

// ev_device_open acquires the fd through the seat seam and fills in everything
// that needs the device itself: name, ids, and the absinfo for each axis.
ev_device_open :: proc(d: ^Ev_Device) -> bool {
	if d.opened {
		return true
	}
	fd, ok := ev_open_device(d.path)
	if !ok {
		return false
	}
	d.fd = fd
	d.opened = true

	// Timestamp in CLOCK_MONOTONIC, which is what every other clock in the
	// compositor uses. Failure is survivable; we fall back to our own clock.
	clk := i32(1)
	linux.ioctl(fd, EV_IOC_SCLOCKID, uintptr(&clk))

	buf: [256]u8
	if linux.ioctl(fd, ev_ioc_gname(256), uintptr(&buf[0])) < 0x8000_0000_0000_0000 {
		n := 0
		for n < len(buf) && buf[n] != 0 {n += 1}
		if n > 0 && d.name == "" {
			d.name = strings.clone(string(buf[:n]))
		}
	}
	id: [4]u16
	linux.ioctl(fd, EV_IOC_GID, uintptr(&id[0]))
	d.bus, d.vendor, d.product, d.version = id[0], id[1], id[2], id[3]

	ev_caps_from_fd(&d.caps, fd)
	d.kinds = ev_classify(&d.caps, d.name)

	for a in 0 ..= EV_ABS_MAX {
		if !ev_bit(d.caps.abs[:], a) {
			continue
		}
		ai: Ev_Abs_Info
		linux.ioctl(fd, ev_ioc_gabs(u32(a)), uintptr(&ai))
		d.absinfo[a] = ai
		d.has_abs[a] = true
	}

	// Grabbing stops the kernel from also feeding these events to anything
	// else on the seat; a compositor that does not grab shares its keyboard
	// with whatever is on the VT underneath it.
	if ev_cfg.grab_devices {
		one := i32(1)
		linux.ioctl(fd, EV_IOC_GRAB, uintptr(&one))
	}
	return true
}

ev_device_close :: proc(d: ^Ev_Device) {
	if !d.opened {
		return
	}
	ev_close_device(d.path, d.fd)
	d.opened = false
	d.fd = 0
	ev_device_reset(d)
}

// ev_start enumerates, keeps the devices worth listening to, and opens what it
// can. It never fails: a compositor with no input is still a compositor, and
// the user may be about to plug a keyboard in.
ev_start :: proc() -> (opened: int, found: int) {
	found_devs := ev_scan()
	for d in found_devs {
		if d.kinds == {} {
			continue
		}
		append(&ev_devices, d)
		found += 1
		if ev_device_open(d) {
			opened += 1
		}
	}
	ev_ready = true
	return
}

ev_stop :: proc() {
	for d in ev_devices {
		ev_device_close(d)
	}
	clear(&ev_devices)
	ev_ready = false
}


// ---------------------------------------------------------------------------
// Hotplug
//
// /dev/input is watched with inotify rather than a netlink uevent socket, for
// one reason: permissions. The kernel announces a new device before devtmpfs
// has finished with the node and long before palm-init has chown'd it to
// root:input 0660, so an open() on the uevent fails with EACCES for a user
// session. inotify reports the node's creation (IN_CREATE) and then the
// ownership change (IN_ATTRIB); the open that fails on the first succeeds on
// the second. Removal is IN_DELETE, or ENODEV from read() if that comes first;
// both end in ev_device_remove, which is idempotent.
// ---------------------------------------------------------------------------

ev_hot_fd: linux.Fd = -1

// ev_hotplug_start watches /dev/input. Without it the devices found at start
// are all there will ever be, which is how wm behaved before.
ev_hotplug_start :: proc() -> bool {
	if ev_hot_fd >= 0 {
		return true
	}
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {
		fmt.eprintfln("wm: input: inotify unavailable (%v); devices plugged in later are not seen", err)
		return false
	}
	if _, werr := linux.inotify_add_watch(fd, "/dev/input", {.CREATE, .ATTRIB, .DELETE, .MOVED_TO, .MOVED_FROM}); werr != .NONE {
		fmt.eprintfln("wm: input: cannot watch /dev/input (%v); devices plugged in later are not seen", werr)
		linux.close(fd)
		return false
	}
	ev_hot_fd = fd
	return true
}

ev_hotplug_stop :: proc() {
	if ev_hot_fd >= 0 {
		linux.close(ev_hot_fd)
		ev_hot_fd = -1
	}
}

ev_hotplug_fd :: proc() -> linux.Fd {
	return ev_hot_fd
}

ev_find :: proc(path: string) -> (^Ev_Device, int) {
	for d, i in ev_devices {
		if d.path == path {
			return d, i
		}
	}
	return nil, -1
}

// ev_hotplug_pump drains the inotify queue and adds or removes devices.
// Returns true when the set of open devices changed.
ev_hotplug_pump :: proc() -> (changed: bool) {
	if ev_hot_fd < 0 {
		return false
	}
	buf: [4096]u8
	for {
		n, err := linux.read(ev_hot_fd, buf[:])
		if err != .NONE || n <= 0 {
			break
		}
		off := 0
		for off + size_of(linux.Inotify_Event) <= n {
			ev := (^linux.Inotify_Event)(&buf[off])
			name := ""
			if ev.len > 0 {
				raw := buf[off + size_of(linux.Inotify_Event):][:ev.len]
				name = strings.truncate_to_byte(string(raw), 0)
			}
			off += size_of(linux.Inotify_Event) + int(ev.len)
			if .Q_OVERFLOW in ev.mask {
				// Lost events: reconcile against what is there now.
				if ev_hotplug_rescan() {
					changed = true
				}
				continue
			}
			if !strings.has_prefix(name, "event") {
				continue
			}
			if .DELETE in ev.mask || .MOVED_FROM in ev.mask {
				if ev_node_removed(name) {
					changed = true
				}
			} else if ev_node_added(name) {
				changed = true
			}
		}
	}
	return
}

// ev_node_added opens a node that appeared or whose permissions changed.
ev_node_added :: proc(name: string) -> bool {
	path := fmt.tprintf("/dev/input/%s", name)
	d, _ := ev_find(path)
	if d == nil {
		d = ev_scan_one(name)
		if d.kinds == {} {
			// A node with nothing we act on (a power button, a lid switch,
			// the PC speaker). Forget it; an IN_ATTRIB will bring it back
			// here and it will be forgotten again, which costs a sysfs read.
			ev_device_free(d)
			return false
		}
		append(&ev_devices, d)
		if ev_paused_all {
			// The session is on another VT. Open it when we come back.
			fmt.printfln("wm: input: %s (%s) appeared while inactive", d.path, d.name)
			return false
		}
	}
	if d.opened || ev_paused_all {
		return false
	}
	if !ev_device_open(d) {
		// Usually EACCES between devtmpfs creating the node and palm-init
		// giving it to the input group; the IN_ATTRIB that follows retries.
		return false
	}
	fmt.printfln("wm: input: added %s  %s  %v", d.path, d.name, d.kinds)
	return true
}

// ev_node_removed closes a node that went away.
ev_node_removed :: proc(name: string) -> bool {
	d, _ := ev_find(fmt.tprintf("/dev/input/%s", name))
	if d == nil {
		return false
	}
	ev_device_remove(d)
	return true
}

// ev_device_remove releases whatever the device was holding — as events, so
// clients see the keys come up — closes it and forgets it.
ev_device_remove :: proc(d: ^Ev_Device) {
	_, i := ev_find(d.path)
	if i < 0 {
		return
	}
	t := now_ms()
	for code in 0 ..= EV_KEY_MAX {
		if ev_bit(d.keys_down[:], code) {
			ev_key_event(d, Ev_Input_Event{type = EV_KEY, code = u16(code), value = 0}, t)
		}
	}
	if ev_repeat.device == d {
		ev_repeat.active = false
		ev_repeat.device = nil
	}
	fmt.printfln("wm: input: removed %s  %s", d.path, d.name)
	ordered_remove(&ev_devices, i)
	ev_device_close(d)
	ev_device_free(d)
}

ev_device_free :: proc(d: ^Ev_Device) {
	delete(d.path)
	delete(d.sysfs)
	delete(d.name)
	free(d)
}

// ev_hotplug_rescan reconciles the device list with /sys/class/input after
// the inotify queue overflowed: new nodes are added, vanished ones removed.
ev_hotplug_rescan :: proc() -> (changed: bool) {
	present := make(map[string]bool, 16, context.temp_allocator)
	if dir, derr := os.open("/sys/class/input"); derr == nil {
		if entries, rerr := os.read_dir(dir, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if strings.has_prefix(e.name, "event") {
					present[fmt.tprintf("/dev/input/%s", e.name)] = true
					if ev_node_added(e.name) {
						changed = true
					}
				}
			}
		}
		os.close(dir)
	}
	for i := len(ev_devices) - 1; i >= 0; i -= 1 {
		d := ev_devices[i]
		if !d.synthetic && !present[d.path] {
			ev_device_remove(d)
			changed = true
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

ev_le_u16 :: proc(b: []u8) -> u16 {return u16(b[0]) | u16(b[1]) << 8}
ev_le_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}
ev_le_u64 :: proc(b: []u8) -> u64 {
	return u64(ev_le_u32(b[0:4])) | u64(ev_le_u32(b[4:8])) << 32
}

ev_decode :: proc(b: []u8) -> Ev_Input_Event {
	return Ev_Input_Event {
		sec = i64(ev_le_u64(b[0:8])),
		usec = i64(ev_le_u64(b[8:16])),
		type = ev_le_u16(b[16:18]),
		code = ev_le_u16(b[18:20]),
		value = i32(ev_le_u32(b[20:24])),
	}
}

ev_encode :: proc(e: Ev_Input_Event, b: []u8) {
	put64 :: proc(b: []u8, v: u64) {
		for i in 0 ..< 8 {b[i] = u8(v >> uint(8 * i))}
	}
	put64(b[0:8], u64(e.sec))
	put64(b[8:16], u64(e.usec))
	b[16] = u8(e.type)
	b[17] = u8(e.type >> 8)
	b[18] = u8(e.code)
	b[19] = u8(e.code >> 8)
	v := u32(e.value)
	for i in 0 ..< 4 {b[20 + i] = u8(v >> uint(8 * i))}
}

// ev_feed is the partial-read boundary. A read() on an evdev fd may land
// anywhere, including inside a record, so bytes that do not complete one are
// carried into the next call. Everything downstream can then assume whole
// events and whole SYN_REPORT frames.
ev_feed :: proc(d: ^Ev_Device, data: []u8) {
	buf := data
	// Finish the record we were in the middle of, if any.
	if d.carry_n > 0 {
		need := EV_EVENT_SIZE - d.carry_n
		take := min(need, len(buf))
		copy(d.carry[d.carry_n:], buf[:take])
		d.carry_n += take
		buf = buf[take:]
		if d.carry_n < EV_EVENT_SIZE {
			return
		}
		d.carry_n = 0
		ev_handle(d, ev_decode(d.carry[:]))
	}
	for len(buf) >= EV_EVENT_SIZE {
		ev_handle(d, ev_decode(buf[:EV_EVENT_SIZE]))
		buf = buf[EV_EVENT_SIZE:]
	}
	if len(buf) > 0 {
		copy(d.carry[:], buf)
		d.carry_n = len(buf)
	}
}

ev_event_ms :: proc(d: ^Ev_Device, e: Ev_Input_Event) -> u32 {
	if e.sec == 0 && e.usec == 0 {
		return now_ms()
	}
	return u32(u64(e.sec) * 1000 + u64(e.usec) / 1000)
}

ev_handle :: proc(d: ^Ev_Device, e: Ev_Input_Event) {
	t := ev_event_ms(d, e)
	d.frame_ms = t
	switch e.type {
	case EV_SYN:
		switch e.code {
		case EV_SYN_REPORT:
			ev_frame(d, t)
		case EV_SYN_DROPPED:
			// The kernel queue overflowed. Everything buffered since the last
			// good frame is a lie; throw it away rather than act on it.
			ev_device_reset(d)
		}
	case EV_KEY:
		ev_key_event(d, e, t)
	case EV_REL:
		ev_rel_event(d, e)
	case EV_ABS:
		ev_abs_event(d, e, t)
	case EV_MSC, EV_SW, EV_LED, EV_SND, EV_REP, EV_FF:
	// Not input we act on.
	}
}

// ---------------------------------------------------------------------------
// Keyboards
// ---------------------------------------------------------------------------

Ev_Repeat :: struct {
	active:  bool,
	keycode: u32,
	device:  ^Ev_Device,
	next_ms: u32,
	started: bool,
}

ev_repeat: Ev_Repeat

ev_key_event :: proc(d: ^Ev_Device, e: Ev_Input_Event, t: u32) {
	code := u32(e.code)

	// Buttons live in the same EV_KEY space as keys. Anything a pointer or a
	// touch device emits in BTN_* range is a button, not a key.
	if code >= 0x100 && code < 0x160 {
		if e.value != 2 && int(code) <= EV_KEY_MAX {
			if e.value != 0 {ev_set_bit(d.keys_down[:], int(code))} else {ev_clear_bit(d.keys_down[:], int(code))}
		}
		ev_button_event(d, code, e.value != 0, t)
		return
	}
	if e.value == 2 {
		// Kernel autorepeat. We drive repeat ourselves off the compositor's
		// timer, because the kernel's rate is global and cannot be changed
		// per-seat without writing to the device.
		return
	}
	down := e.value == 1
	if down && !d.typed && !d.synthetic {
		d.typed = true
		fmt.printfln("wm: input: first key from %s (%s)", d.path, d.name)
	}
	if int(code) <= EV_KEY_MAX {
		if down {ev_set_bit(d.keys_down[:], int(code))} else {ev_clear_bit(d.keys_down[:], int(code))}
	}

	xkb_update_key(code, down)
	sym := xkb_sym_for(code)
	mods := xkb_mods_now()
	dep, lat, lock, grp := xkb_serialize()

	append(
		&ev_queue,
		Ev_Event {
			kind = .Key,
			time_ms = t,
			device = d,
			keycode = code,
			sym = sym,
			down = down,
			mods = mods,
			mods_depressed = dep,
			mods_latched = lat,
			mods_locked = lock,
			group = grp,
		},
	)

	if down {
		ev_last_key_ms = t
		if xkb_repeats(code) && ev_cfg.repeat_rate > 0 {
			ev_repeat = Ev_Repeat {
				active  = true,
				keycode = code,
				device  = d,
				next_ms = t + u32(ev_cfg.repeat_delay),
				started = false,
			}
		} else {
			ev_repeat.active = false
		}
	} else if ev_repeat.active && ev_repeat.keycode == code {
		ev_repeat.active = false
	}
}

// ev_tick is the compositor's timer calling in. Key repeat is generated here,
// not by the kernel, so the rate follows the compositor's configuration and
// stops cleanly the moment focus or the session changes.
ev_tick :: proc(now: u32) {
	if !ev_repeat.active {
		return
	}
	interval := u32(1000 / max(ev_cfg.repeat_rate, 1))
	for ev_repeat.active && now >= ev_repeat.next_ms {
		dep, lat, lock, grp := xkb_serialize()
		append(
			&ev_queue,
			Ev_Event {
				kind = .Key,
				time_ms = ev_repeat.next_ms,
				device = ev_repeat.device,
				keycode = ev_repeat.keycode,
				sym = xkb_sym_for(ev_repeat.keycode),
				down = true,
				repeat = true,
				mods = xkb_mods_now(),
				mods_depressed = dep,
				mods_latched = lat,
				mods_locked = lock,
				group = grp,
			},
		)
		ev_repeat.started = true
		ev_repeat.next_ms += max(interval, 1)
	}
}

// ev_next_timeout is what the compositor's poll() should wait for, in
// milliseconds, so the repeat fires on time instead of on the next unrelated
// event. -1 means "nothing pending".
ev_next_timeout :: proc(now: u32) -> int {
	if !ev_repeat.active {
		return -1
	}
	if now >= ev_repeat.next_ms {
		return 0
	}
	return int(ev_repeat.next_ms - now)
}

// ---------------------------------------------------------------------------
// Pointers
// ---------------------------------------------------------------------------

ev_button_event :: proc(d: ^Ev_Device, code: u32, down: bool, t: u32) {
	btn := code

	// A clickpad has one physical button under the whole surface, so the
	// finger count at the moment of the click is what picks left, right or
	// middle. Without this a touchpad has no right button at all.
	if down && ev_cfg.clickfinger && .Touchpad in d.kinds && btn == EV_BTN_LEFT {
		switch d.fingers {
		case 2:
			btn = EV_BTN_RIGHT
		case 3:
			btn = EV_BTN_MIDDLE
		}
		d.clicked_btn = btn
	} else if !down && .Touchpad in d.kinds && btn == EV_BTN_LEFT && d.clicked_btn != 0 {
		btn = d.clicked_btn
		d.clicked_btn = 0
	}

	if ev_cfg.left_handed {
		if btn == EV_BTN_LEFT {btn = EV_BTN_RIGHT} else if btn == EV_BTN_RIGHT {btn = EV_BTN_LEFT}
	}

	if slot, ok := ev_button_slot(btn); ok {
		if down {
			ev_buttons += {slot}
		} else {
			ev_buttons -= {slot}
		}
	}
	append(&ev_queue, Ev_Event{kind = .Button, time_ms = t, device = d, button = btn, down = down})
}

ev_rel_event :: proc(d: ^Ev_Device, e: Ev_Input_Event) {
	switch e.code {
	case EV_REL_X:
		d.rel[0] += f64(e.value)
		d.have_rel = true
	case EV_REL_Y:
		d.rel[1] += f64(e.value)
		d.have_rel = true
	case EV_REL_WHEEL:
		d.wheel[0] += e.value
	case EV_REL_HWHEEL:
		d.wheel[1] += e.value
	case EV_REL_WHEEL_HI_RES:
		d.wheel_hi[0] += e.value
		d.have_hi[0] = true
	case EV_REL_HWHEEL_HI_RES:
		d.wheel_hi[1] += e.value
		d.have_hi[1] = true
	}
}

// ev_accel is the pointer acceleration curve. A flat profile is a constant
// multiplier; the adaptive one ramps from `accel_min` at rest towards
// `accel_max`, saturating smoothly around `accel_threshold` device units per
// millisecond. It is not libinput's curve, but it is a curve, and a daily
// driver needs one: 1:1 raw input makes a mouse feel broken at both ends.
ev_accel :: proc(dx, dy: f64, dt_ms: f64) -> (f64, f64) {
	tune := 1.0 + ev_cfg.accel_speed * 0.5
	if ev_cfg.accel_profile == .Flat {
		return dx * tune, dy * tune
	}
	dist := math.sqrt(dx * dx + dy * dy)
	if dist == 0 {
		return 0, 0
	}
	dt := max(dt_ms, 1.0)
	speed := dist / dt
	s := speed / max(ev_cfg.accel_threshold, 0.0001)
	f := ev_cfg.accel_min + (ev_cfg.accel_max - ev_cfg.accel_min) * (s / (1 + s))
	f *= tune
	return dx * f, dy * f
}

ev_emit_motion :: proc(d: ^Ev_Device, dx, dy, udx, udy: f64, t: u32) {
	if dx == 0 && dy == 0 {
		return
	}
	ev_pointer[0] = clamp(ev_pointer[0] + dx, 0, max(ev_screen[0] - 1, 0))
	ev_pointer[1] = clamp(ev_pointer[1] + dy, 0, max(ev_screen[1] - 1, 0))
	append(
		&ev_queue,
		Ev_Event {
			kind = .Pointer_Motion,
			time_ms = t,
			device = d,
			dx = dx,
			dy = dy,
			udx = udx,
			udy = udy,
			x = ev_pointer[0],
			y = ev_pointer[1],
		},
	)
}

// ev_emit_absolute maps an absolute pointer's ABS_X/ABS_Y onto the output
// layout. The axis range comes from the device's absinfo — QEMU's tablet says
// 0..32767 — and the far end of the range is the last pixel, not one past it.
// Relative mice share `ev_pointer`, so moving one after the other picks up
// where the other left the cursor.
ev_emit_absolute :: proc(d: ^Ev_Device, t: u32) {
	ax, ay := d.absinfo[EV_ABS_X], d.absinfo[EV_ABS_Y]
	spanx := f64(max(ax.maximum - ax.minimum, 1))
	spany := f64(max(ay.maximum - ay.minimum, 1))
	x := f64(d.slots[0].x - ax.minimum) / spanx * max(ev_screen[0] - 1, 0)
	y := f64(d.slots[0].y - ay.minimum) / spany * max(ev_screen[1] - 1, 0)
	x = clamp(x, 0, max(ev_screen[0] - 1, 0))
	y = clamp(y, 0, max(ev_screen[1] - 1, 0))
	dx, dy := x - ev_pointer[0], y - ev_pointer[1]
	if dx == 0 && dy == 0 {
		return
	}
	ev_pointer = {x, y}
	append(
		&ev_queue,
		Ev_Event {
			kind = .Pointer_Motion_Absolute,
			time_ms = t,
			device = d,
			dx = dx,
			dy = dy,
			x = x,
			y = y,
		},
	)
}

ev_emit_axis :: proc(d: ^Ev_Device, axis: Ev_Axis_Kind, value: f64, v120: i32, src: Ev_Axis_Source, t: u32) {
	v := value
	n := v120
	if ev_cfg.natural_scroll {
		v = -v
		n = -n
	}
	append(
		&ev_queue,
		Ev_Event {
			kind = .Axis,
			time_ms = t,
			device = d,
			axis = axis,
			value = v,
			v120 = n,
			source = src,
		},
	)
}

// ---------------------------------------------------------------------------
// Touchpads
// ---------------------------------------------------------------------------

ev_abs_event :: proc(d: ^Ev_Device, e: Ev_Input_Event, t: u32) {
	switch e.code {
	case EV_ABS_MT_SLOT:
		if e.value >= 0 && int(e.value) < EV_MAX_SLOTS {
			d.cur_slot = int(e.value)
		} else {
			d.cur_slot = EV_MAX_SLOTS - 1 // park out-of-range slots harmlessly
		}
		return
	}
	s := &d.slots[d.cur_slot]
	switch e.code {
	case EV_ABS_MT_TRACKING_ID:
		if e.value < 0 {
			// Keep the slot until the frame ends: the touch-up event is
			// emitted at SYN_REPORT, and by then the contact has to still be
			// distinguishable from a slot that was never used.
			s.used = false
			s.lifted = true
		} else {
			s^ = {}
			s.used = true
			s.tracking_id = e.value
			s.down_ms = t
		}
	case EV_ABS_MT_POSITION_X:
		s.x = e.value
		if !s.has_prev {s.sx = e.value}
	case EV_ABS_MT_POSITION_Y:
		s.y = e.value
		if !s.has_prev {s.sy = e.value}
	case EV_ABS_MT_TOUCH_MAJOR:
		s.major = e.value
	case EV_ABS_MT_PRESSURE:
		s.pressure = e.value
	case EV_ABS_X:
		// Single-touch fallback for devices with no MT protocol at all.
		if !ev_bit(d.caps.abs[:], EV_ABS_MT_POSITION_X) {
			d.slots[0].x = e.value
			d.slots[0].used = true
		}
		d.abs_dirty = true
	case EV_ABS_Y:
		if !ev_bit(d.caps.abs[:], EV_ABS_MT_POSITION_Y) {
			d.slots[0].y = e.value
			d.slots[0].used = true
		}
		d.abs_dirty = true
	case EV_ABS_PRESSURE:
		d.slots[0].pressure = e.value
	}
}

// ev_units_per_mm reads the kernel's declared resolution for an axis. When the
// device does not report one, a plausible physical size is assumed: being
// wrong by a factor of two is survivable, dividing by zero is not.
ev_units_per_mm :: proc(d: ^Ev_Device, axis: int, fallback_mm: f64) -> f64 {
	if d.has_abs[axis] {
		ai := d.absinfo[axis]
		if ai.resolution > 0 {
			return f64(ai.resolution)
		}
		if ai.maximum > ai.minimum && fallback_mm > 0 {
			return f64(ai.maximum - ai.minimum) / fallback_mm
		}
	}
	return 1
}

// ev_palm decides whether a contact is a palm rather than a finger. Contact
// width is the strong signal where the device reports it; pressure is the
// fallback. A contact once judged a palm stays one until it lifts, so a palm
// that happens to narrow mid-stroke does not suddenly start moving the cursor.
ev_palm :: proc(d: ^Ev_Device, s: ^Ev_Slot) -> bool {
	if s.palm {
		return true
	}
	if ev_cfg.palm_touch_major > 0 && s.major > ev_cfg.palm_touch_major {
		return true
	}
	if ev_cfg.palm_pressure > 0 && s.pressure > ev_cfg.palm_pressure {
		return true
	}
	return false
}

ev_live_slots :: proc(d: ^Ev_Device) -> int {
	n := 0
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if s.used && !s.palm {
			n += 1
		}
	}
	return n
}

// ev_invalidate_prev drops every finger's previous position. It runs whenever
// the finger count changes, which is the single most important line in the
// touchpad code: without it, the moment a second finger lands, the average of
// the contacts jumps by half the distance between them and the view leaps.
ev_invalidate_prev :: proc(d: ^Ev_Device) {
	for i in 0 ..< EV_MAX_SLOTS {
		d.slots[i].has_prev = false
	}
	d.scroll_acc = {}
}

ev_frame :: proc(d: ^Ev_Device, t: u32) {
	defer {
		d.last_frame_ms = t
		d.rel = {}
		d.have_rel = false
		d.wheel = {}
		d.wheel_hi = {}
		d.have_hi = {}
		d.abs_dirty = false
	}

	dt := f64(t - d.last_frame_ms)
	if d.last_frame_ms == 0 || dt <= 0 || dt > 200 {
		dt = 8
	}

	if .Touchpad in d.kinds || .Touchscreen in d.kinds {
		ev_touch_frame(d, t, dt)
	}

	if d.have_rel {
		dx, dy := ev_accel(d.rel[0], d.rel[1], dt)
		ev_emit_motion(d, dx, dy, d.rel[0], d.rel[1], t)
	}

	if d.abs_dirty && .Abs_Pointer in d.kinds {
		ev_emit_absolute(d, t)
	}

	for ax in 0 ..< 2 {
		kind: Ev_Axis_Kind = ax == 0 ? .Vertical : .Horizontal
		// A modern mouse sends both REL_WHEEL and REL_WHEEL_HI_RES for the
		// same motion. Taking both double-counts every detent, so the
		// high-resolution axis wins whenever it is present.
		if d.have_hi[ax] {
			if d.wheel_hi[ax] == 0 {
				continue
			}
			// Positive upwards like REL_WHEEL, so the vertical axis flips.
			hi := d.wheel_hi[ax]
			if ax == 0 {hi = -hi}
			frac := f64(hi) / 120.0
			ev_emit_axis(d, kind, frac * ev_cfg.scroll_factor, hi, .Wheel, t)
		} else if d.wheel[ax] != 0 {
			// The kernel's REL_WHEEL is positive upwards; Wayland's vertical
			// axis is positive downwards.
			v := d.wheel[ax]
			if ax == 0 {v = -v}
			ev_emit_axis(d, kind, f64(v) * ev_cfg.scroll_factor, v * 120, .Wheel, t)
		}
	}
}

ev_touch_frame :: proc(d: ^Ev_Device, t: u32, dt: f64) {
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if s.used && ev_palm(d, s) {
			s.palm = true
		}
	}

	fingers := ev_live_slots(d)
	d.fingers = fingers
	changed := fingers != d.prev_fingers

	if .Touchscreen in d.kinds {
		ev_touchscreen_frame(d, t, fingers, changed)
		d.prev_fingers = fingers
		ev_touch_store_prev(d)
		return
	}

	// Disable-while-typing. The palm of a hand resting while the other hand
	// types is the single most common way a touchpad ruins a sentence.
	typing := ev_cfg.disable_while_typing && t >= ev_last_key_ms && (t - ev_last_key_ms) < ev_cfg.dwt_timeout_ms

	ux := ev_units_per_mm(d, EV_ABS_MT_POSITION_X, 100)
	uy := ev_units_per_mm(d, EV_ABS_MT_POSITION_Y, 70)

	if changed {
		ev_touch_tap_transition(d, t, fingers)
		ev_invalidate_prev(d)
		if d.scrolling && fingers != 2 {
			append(&ev_queue, Ev_Event{kind = .Axis_Stop, time_ms = t, device = d, source = .Finger})
			d.scrolling = false
		}
		if d.gesture_on && fingers != d.gesture_fingers {
			append(
				&ev_queue,
				Ev_Event {
					kind = .Gesture_End,
					time_ms = t,
					device = d,
					gesture = d.gesture_kind,
					fingers = d.gesture_fingers,
				},
			)
			d.gesture_on = false
		}
	}

	// Movement, for the tap test: a tap is a touch that did not travel.
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if !s.used || s.palm {
			continue
		}
		mx := f64(s.x - s.sx) / ux
		my := f64(s.y - s.sy) / uy
		if math.sqrt(mx * mx + my * my) > ev_cfg.tap_move_mm {
			s.moved = true
			d.tap_valid = false
		}
	}

	if !typing {
		switch {
		case fingers == 1:
			ev_touch_pointer(d, t, dt, ux, uy)
		case fingers == 2 && ev_cfg.two_finger_scroll:
			ev_touch_scroll(d, t, ux, uy)
		case fingers >= 3:
			ev_touch_gesture(d, t, fingers, ux, uy)
		}
	}

	d.prev_fingers = fingers
	ev_touch_store_prev(d)
	ev_touch_tap_timeout(d, t)
}

ev_touch_store_prev :: proc(d: ^Ev_Device) {
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if s.lifted {
			s^ = {}
			continue
		}
		if s.used {
			s.px, s.py = s.x, s.y
			s.has_prev = true
		} else {
			s.has_prev = false
		}
	}
}

ev_touch_pointer :: proc(d: ^Ev_Device, t: u32, dt: f64, ux, uy: f64) {
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if !s.used || s.palm || !s.has_prev {
			continue
		}
		mx := f64(s.x - s.px) / ux
		my := f64(s.y - s.py) / uy
		if mx == 0 && my == 0 {
			return
		}
		px := mx * ev_cfg.touchpad_dpi
		py := my * ev_cfg.touchpad_dpi
		dx, dy := ev_accel(px, py, dt)
		ev_emit_motion(d, dx, dy, mx, my, t)
		return
	}
}

// ev_touch_scroll is two-finger scrolling. Only contacts that were present in
// the previous frame contribute, the average of their travel is what scrolls,
// and a short dead zone has to be crossed before scrolling engages so that a
// two-finger tap does not nudge the page.
ev_touch_scroll :: proc(d: ^Ev_Device, t: u32, ux, uy: f64) {
	sum_x, sum_y := 0.0, 0.0
	n := 0
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if !s.used || s.palm || !s.has_prev {
			continue
		}
		sum_x += f64(s.x - s.px) / ux
		sum_y += f64(s.y - s.py) / uy
		n += 1
	}
	if n == 0 {
		return
	}
	mx := sum_x / f64(n)
	my := sum_y / f64(n)
	if mx == 0 && my == 0 {
		return
	}
	d.scroll_acc[0] += mx
	d.scroll_acc[1] += my

	if !d.scrolling {
		dist := math.sqrt(d.scroll_acc[0] * d.scroll_acc[0] + d.scroll_acc[1] * d.scroll_acc[1])
		if dist < ev_cfg.scroll_start_mm {
			return
		}
		d.scrolling = true
		// Spend the dead zone rather than dumping it into the first event.
		d.scroll_acc = {mx, my}
		d.tap_valid = false
	}

	// Vertical: fingers moving down the pad scroll the view down, which is
	// Wayland's positive direction. `natural_scroll` inverts both axes inside
	// ev_emit_axis.
	if my != 0 {
		ev_emit_axis(d, .Vertical, my * ev_cfg.touchpad_scroll_mm, i32(my * ev_cfg.touchpad_scroll_mm * 8), .Finger, t)
	}
	if mx != 0 {
		ev_emit_axis(d, .Horizontal, mx * ev_cfg.touchpad_scroll_mm, i32(mx * ev_cfg.touchpad_scroll_mm * 8), .Finger, t)
	}
}

// ev_touch_gesture reports three- and four-finger swipes. The finger count and
// the averaged travel are real; pinch and rotate are *not* implemented — a
// two-finger pinch is indistinguishable here from a two-finger scroll without
// a distance-change term, and that is left undone deliberately rather than
// faked. See the report.
ev_touch_gesture :: proc(d: ^Ev_Device, t: u32, fingers: int, ux, uy: f64) {
	sum_x, sum_y := 0.0, 0.0
	n := 0
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if !s.used || s.palm || !s.has_prev {
			continue
		}
		sum_x += f64(s.x - s.px) / ux
		sum_y += f64(s.y - s.py) / uy
		n += 1
	}
	if !d.gesture_on {
		d.gesture_on = true
		d.gesture_kind = .Swipe
		d.gesture_fingers = fingers
		append(
			&ev_queue,
			Ev_Event{kind = .Gesture_Begin, time_ms = t, device = d, gesture = .Swipe, fingers = fingers},
		)
		return
	}
	if n == 0 {
		return
	}
	append(
		&ev_queue,
		Ev_Event {
			kind = .Gesture_Update,
			time_ms = t,
			device = d,
			gesture = .Swipe,
			fingers = fingers,
			dx = sum_x / f64(n) * ev_cfg.touchpad_dpi,
			dy = sum_y / f64(n) * ev_cfg.touchpad_dpi,
			scale = 1,
		},
	)
}

ev_touch_tap_transition :: proc(d: ^Ev_Device, t: u32, fingers: int) {
	if !ev_cfg.tap_to_click {
		return
	}
	if d.prev_fingers == 0 && fingers > 0 {
		// A touch beginning inside the drag window continues the previous tap
		// as a held button rather than starting a new one.
		if ev_cfg.tap_and_drag && d.tap_pending && t - d.tap_pending_ms <= ev_cfg.drag_timeout_ms {
			d.tap_pending = false
			d.drag_held = true
			ev_button_event(d, EV_BTN_LEFT, true, t)
		}
		d.touch_start_ms = t
		d.tap_fingers = fingers
		d.tap_valid = !(ev_cfg.disable_while_typing && t >= ev_last_key_ms && (t - ev_last_key_ms) < ev_cfg.dwt_timeout_ms)
		return
	}
	if fingers > d.tap_fingers {
		d.tap_fingers = fingers
	}
	if fingers == 0 && d.prev_fingers > 0 {
		if d.drag_held {
			d.drag_held = false
			ev_button_event(d, EV_BTN_LEFT, false, t)
			d.tap_valid = false
			return
		}
		if d.tap_valid && t - d.touch_start_ms <= ev_cfg.tap_timeout_ms {
			btn := u32(EV_BTN_LEFT)
			switch d.tap_fingers {
			case 2:
				btn = EV_BTN_RIGHT
			case 3:
				btn = EV_BTN_MIDDLE
			}
			if ev_cfg.tap_and_drag && d.tap_fingers == 1 {
				// Hold the click back for one drag window: if a finger comes
				// straight back down it becomes a drag instead.
				d.tap_pending = true
				d.tap_pending_ms = t
			} else {
				ev_button_event(d, btn, true, t)
				ev_button_event(d, btn, false, t)
			}
		}
		d.tap_valid = false
		d.tap_fingers = 0
	}
}

ev_touch_tap_timeout :: proc(d: ^Ev_Device, t: u32) {
	if d.tap_pending && t - d.tap_pending_ms > ev_cfg.drag_timeout_ms {
		d.tap_pending = false
		ev_button_event(d, EV_BTN_LEFT, true, t)
		ev_button_event(d, EV_BTN_LEFT, false, t)
	}
}

// ev_tap_flush is the timer half of tap-and-drag: with no further touchpad
// traffic the pending tap has to be released by the clock, not by the next
// event that happens along.
ev_tap_flush :: proc(now: u32) {
	for d in ev_devices {
		ev_touch_tap_timeout(d, now)
	}
}

ev_touchscreen_frame :: proc(d: ^Ev_Device, t: u32, fingers: int, changed: bool) {
	ax := d.has_abs[EV_ABS_MT_POSITION_X] ? d.absinfo[EV_ABS_MT_POSITION_X] : d.absinfo[EV_ABS_X]
	ay := d.has_abs[EV_ABS_MT_POSITION_Y] ? d.absinfo[EV_ABS_MT_POSITION_Y] : d.absinfo[EV_ABS_Y]
	spanx := f64(max(ax.maximum - ax.minimum, 1))
	spany := f64(max(ay.maximum - ay.minimum, 1))
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if !s.used {
			continue
		}
		x := f64(s.x - ax.minimum) / spanx * ev_screen[0]
		y := f64(s.y - ay.minimum) / spany * ev_screen[1]
		kind: Ev_Kind_Of_Event = s.has_prev ? .Touch_Motion : .Touch_Down
		if kind == .Touch_Motion && s.x == s.px && s.y == s.py {
			continue
		}
		append(
			&ev_queue,
			Ev_Event {
				kind = kind,
				time_ms = t,
				device = d,
				slot = i32(i),
				tracking_id = s.tracking_id,
				x = x,
				y = y,
			},
		)
	}
	// Lifted contacts, which ev_touch_store_prev clears once the frame ends.
	for i in 0 ..< EV_MAX_SLOTS {
		s := &d.slots[i]
		if s.lifted {
			append(&ev_queue, Ev_Event{kind = .Touch_Up, time_ms = t, device = d, slot = i32(i)})
		}
	}
}

// ---------------------------------------------------------------------------
// Reading and dispatch
// ---------------------------------------------------------------------------

ev_read_once :: proc(d: ^Ev_Device) -> bool {
	if !d.opened || d.paused {
		return false
	}
	buf: [EV_EVENT_SIZE * 64]u8
	any := false
	for {
		n, err := linux.read(d.fd, buf[:])
		if err == .ENODEV {
			d.gone = true
			break
		}
		if err != .NONE || n <= 0 {
			break
		}
		ev_feed(d, buf[:n])
		any = true
		if n < len(buf) {
			break
		}
	}
	return any
}

// ev_pump polls every open device and decodes whatever is ready. The
// compositor can use this directly, or fold ev_fds() into its own poll set and
// call ev_read_once() per ready fd; the second is what main.odin will want,
// because it has a display fd to wait on as well.
ev_pump :: proc(timeout_ms: int) -> int {
	fds := make([dynamic]linux.Poll_Fd, 0, len(ev_devices), context.temp_allocator)
	devs := make([dynamic]^Ev_Device, 0, len(ev_devices), context.temp_allocator)
	for d in ev_devices {
		if d.opened && !d.paused {
			append(&fds, linux.Poll_Fd{fd = d.fd, events = {.IN}})
			append(&devs, d)
		}
	}
	if len(fds) == 0 {
		return 0
	}
	n, err := linux.poll(fds[:], i32(timeout_ms))
	if err != .NONE || n <= 0 {
		return 0
	}
	count := 0
	for f, i in fds {
		if .IN in f.revents {
			ev_read_once(devs[i])
			count += 1
		}
	}
	return count
}

ev_fds :: proc(allocator := context.allocator) -> []linux.Fd {
	out := make([dynamic]linux.Fd, 0, len(ev_devices), allocator)
	for d in ev_devices {
		if d.opened && !d.paused {
			append(&out, d.fd)
		}
	}
	return out[:]
}

ev_drain :: proc() -> []Ev_Event {
	out := ev_queue[:]
	ev_queue = nil
	return out
}

// ev_apply_to_input folds the normalized stream into the same `p.Input` the
// nested path fills in. This is the convergence point the brief asks for:
// bare metal and nested both end up calling handle_keys / handle_pointer on a
// p.Input, so there is one compositor rather than two.
//
// `scale` converts the pointer's pixel position back into the logical units
// p.Input carries.
ev_apply_to_input :: proc(in_: ^p.Input, scale: f32 = 1) {
	in_.pressed = {}
	in_.released = {}
	in_.scroll = {}
	in_.mouse_delta = {}
	clear(&in_.keys)
	clear(&key_codes)
	clear(&key_evs)
	axis_detail = {}
	in_.over_surface = true
	in_.focused = true

	for e in ev_queue {
		switch e.kind {
		case .Key:
			in_.mods = e.mods
			idx := -1
			if e.down {
				idx = len(in_.keys)
				append(&in_.keys, p.Key_Event{sym = e.sym, mods = e.mods, repeat = e.repeat})
				// The keycode rides alongside, so bindings can match the key
				// the user pressed and not only what it typed (keys.odin).
				append(&key_codes, e.keycode)
			}
			// And the whole stream, releases included, in order, for the
			// clients (keys.odin, handle_keys_bare).
			append(&key_evs, Key_Ev{
				code = e.keycode, time = e.time_ms, down = e.down, repeat = e.repeat, idx = idx,
				dep = e.mods_depressed, lat = e.mods_latched, lock = e.mods_locked, grp = e.group,
			})
		case .Pointer_Motion, .Pointer_Motion_Absolute:
			in_.mouse_delta += {f32(e.dx), f32(e.dy)}
			in_.mouse = {f32(e.x) / scale, f32(e.y) / scale}
		case .Button:
			slot, ok := ev_button_slot(e.button)
			if !ok {
				continue
			}
			b: p.Mouse_Button = .Left
			switch slot {
			case .Left:
				b = .Left
			case .Right:
				b = .Right
			case .Middle:
				b = .Middle
			}
			if e.down {
				in_.down[b] = true
				in_.pressed[b] = true
			} else {
				in_.down[b] = false
				in_.released[b] = true
			}
		case .Axis:
			ai := 0
			if e.axis == .Vertical {
				in_.scroll.y += f32(e.value)
			} else {
				in_.scroll.x += f32(e.value)
				ai = 1
			}
			axis_detail.v120[ai] += e.v120
			switch e.source {
			case .Wheel:
				axis_detail.source = 0
			case .Finger:
				axis_detail.source = 1
			case .Continuous:
				axis_detail.source = 2
			}
		case .Axis_Stop:
			// A finger lifted off a two-finger scroll: kinetic scrolling in
			// the client starts from here.
			axis_detail.stop = {true, true}
			axis_detail.source = 1
		case .Touch_Down, .Touch_Motion, .Touch_Up,
		     .Gesture_Begin, .Gesture_Update, .Gesture_End,
		     .Device_Added, .Device_Removed:
		// Not representable in p.Input; the keycode-level consumer takes these.
		}
	}
	clear(&ev_queue)
}

// ---------------------------------------------------------------------------
// Self test
//
// Nothing below runs in the compositor. It exists because the process cannot
// open /dev/input/event* — alex is not in the `input` group, and that is
// deliberate — so the only honest way to exercise the decoder is to build the
// byte buffers the kernel would have produced and push them through it.
// ---------------------------------------------------------------------------

ev_test_pass := 0
ev_test_fail := 0

ev_check :: proc(cond: bool, format: string, args: ..any) {
	if cond {
		ev_test_pass += 1
	} else {
		ev_test_fail += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(format, ..args))
	}
}

ev_near :: proc(a, b, tol: f64) -> bool {return math.abs(a - b) <= tol}

// Ev_Rec is one line of a recorded-looking event stream.
Ev_Rec :: struct {
	type:  u16,
	code:  u16,
	value: i32,
	ms:    u32,
}

ev_bytes :: proc(recs: []Ev_Rec, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(recs) * EV_EVENT_SIZE, allocator)
	for r, i in recs {
		e := Ev_Input_Event {
			sec   = i64(r.ms / 1000),
			usec  = i64(u64(r.ms % 1000) * 1000),
			type  = r.type,
			code  = r.code,
			value = r.value,
		}
		ev_encode(e, out[i * EV_EVENT_SIZE:][:EV_EVENT_SIZE])
	}
	return out
}

ev_fake_keyboard :: proc() -> ^Ev_Device {
	d := new(Ev_Device)
	d.name = "Synthetic Keyboard"
	d.synthetic = true
	ev_set_bit(d.caps.ev[:], EV_KEY)
	ev_set_bit(d.caps.ev[:], EV_SYN)
	for c in ([?]int{EV_KEY_ESC, EV_KEY_Q, EV_KEY_P, EV_KEY_A, EV_KEY_L, EV_KEY_Z, EV_KEY_M, EV_KEY_SPACE, EV_KEY_LEFTSHIFT, EV_KEY_LEFTCTRL, EV_KEY_LEFTALT, EV_KEY_LEFTMETA, EV_KEY_CAPSLOCK}) {
		ev_set_bit(d.caps.key[:], c)
	}
	d.kinds = ev_classify(&d.caps, d.name)
	return d
}

ev_fake_mouse :: proc() -> ^Ev_Device {
	d := new(Ev_Device)
	d.name = "Synthetic Mouse"
	d.synthetic = true
	ev_set_bit(d.caps.ev[:], EV_KEY)
	ev_set_bit(d.caps.ev[:], EV_REL)
	ev_set_bit(d.caps.rel[:], EV_REL_X)
	ev_set_bit(d.caps.rel[:], EV_REL_Y)
	ev_set_bit(d.caps.rel[:], EV_REL_WHEEL)
	ev_set_bit(d.caps.rel[:], EV_REL_WHEEL_HI_RES)
	ev_set_bit(d.caps.key[:], EV_BTN_LEFT)
	ev_set_bit(d.caps.key[:], EV_BTN_RIGHT)
	ev_set_bit(d.caps.key[:], EV_BTN_MIDDLE)
	d.kinds = ev_classify(&d.caps, d.name)
	return d
}

// A clickpad shaped like the common Synaptics/Elan part: 1216x680 units at
// 12 units per millimetre, so about 101mm by 57mm.
ev_fake_touchpad :: proc() -> ^Ev_Device {
	d := new(Ev_Device)
	d.name = "Synthetic Touchpad"
	d.synthetic = true
	ev_set_bit(d.caps.ev[:], EV_KEY)
	ev_set_bit(d.caps.ev[:], EV_ABS)
	ev_set_bit(d.caps.key[:], EV_BTN_LEFT)
	ev_set_bit(d.caps.key[:], EV_BTN_TOUCH)
	ev_set_bit(d.caps.key[:], EV_BTN_TOOL_FINGER)
	ev_set_bit(d.caps.key[:], EV_BTN_TOOL_DOUBLETAP)
	ev_set_bit(d.caps.key[:], EV_BTN_TOOL_TRIPLETAP)
	ev_set_bit(d.caps.prop[:], EV_INPUT_PROP_POINTER)
	ev_set_bit(d.caps.prop[:], EV_INPUT_PROP_BUTTONPAD)
	for a in ([?]int{EV_ABS_X, EV_ABS_Y, EV_ABS_PRESSURE, EV_ABS_MT_SLOT, EV_ABS_MT_POSITION_X, EV_ABS_MT_POSITION_Y, EV_ABS_MT_TRACKING_ID, EV_ABS_MT_TOUCH_MAJOR, EV_ABS_MT_PRESSURE}) {
		ev_set_bit(d.caps.abs[:], a)
		d.has_abs[a] = true
	}
	d.absinfo[EV_ABS_MT_POSITION_X] = {minimum = 0, maximum = 1216, resolution = 12}
	d.absinfo[EV_ABS_MT_POSITION_Y] = {minimum = 0, maximum = 680, resolution = 12}
	d.absinfo[EV_ABS_X] = d.absinfo[EV_ABS_MT_POSITION_X]
	d.absinfo[EV_ABS_Y] = d.absinfo[EV_ABS_MT_POSITION_Y]
	d.absinfo[EV_ABS_MT_TOUCH_MAJOR] = {minimum = 0, maximum = 1023}
	d.kinds = ev_classify(&d.caps, d.name)
	return d
}

ev_fake_touchscreen :: proc() -> ^Ev_Device {
	d := new(Ev_Device)
	d.name = "Synthetic Touchscreen"
	d.synthetic = true
	ev_set_bit(d.caps.ev[:], EV_KEY)
	ev_set_bit(d.caps.ev[:], EV_ABS)
	ev_set_bit(d.caps.key[:], EV_BTN_TOUCH)
	ev_set_bit(d.caps.prop[:], EV_INPUT_PROP_DIRECT)
	for a in ([?]int{EV_ABS_X, EV_ABS_Y, EV_ABS_MT_SLOT, EV_ABS_MT_POSITION_X, EV_ABS_MT_POSITION_Y, EV_ABS_MT_TRACKING_ID}) {
		ev_set_bit(d.caps.abs[:], a)
		d.has_abs[a] = true
	}
	d.absinfo[EV_ABS_MT_POSITION_X] = {minimum = 0, maximum = 3199}
	d.absinfo[EV_ABS_MT_POSITION_Y] = {minimum = 0, maximum = 1799}
	d.kinds = ev_classify(&d.caps, d.name)
	return d
}

ev_q_reset :: proc() {clear(&ev_queue)}

ev_count :: proc(k: Ev_Kind_Of_Event) -> int {
	n := 0
	for e in ev_queue {
		if e.kind == k {n += 1}
	}
	return n
}

ev_first :: proc(k: Ev_Kind_Of_Event) -> (Ev_Event, bool) {
	for e in ev_queue {
		if e.kind == k {return e, true}
	}
	return {}, false
}

ev_axis_total :: proc(a: Ev_Axis_Kind) -> f64 {
	v := 0.0
	for e in ev_queue {
		if e.kind == .Axis && e.axis == a {v += e.value}
	}
	return v
}

// ev_play feeds a recorded sequence through the decoder in one read.
ev_play :: proc(d: ^Ev_Device, recs: []Ev_Rec) {
	b := ev_bytes(recs, context.temp_allocator)
	ev_feed(d, b)
}

// Touch helpers that write the MT protocol the way a real pad does.
ev_touch_down_rec :: proc(buf: ^[dynamic]Ev_Rec, slot: int, id: i32, x, y: i32, ms: u32) {
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_SLOT, i32(slot), ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_TRACKING_ID, id, ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_POSITION_X, x, ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_POSITION_Y, y, ms})
}

ev_touch_move_rec :: proc(buf: ^[dynamic]Ev_Rec, slot: int, x, y: i32, ms: u32) {
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_SLOT, i32(slot), ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_POSITION_X, x, ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_POSITION_Y, y, ms})
}

ev_touch_up_rec :: proc(buf: ^[dynamic]Ev_Rec, slot: int, ms: u32) {
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_SLOT, i32(slot), ms})
	append(buf, Ev_Rec{EV_ABS, EV_ABS_MT_TRACKING_ID, -1, ms})
}

ev_syn_rec :: proc(buf: ^[dynamic]Ev_Rec, ms: u32) {
	append(buf, Ev_Rec{EV_SYN, EV_SYN_REPORT, 0, ms})
}

ev_selftest :: proc() -> int {
	ev_test_pass = 0
	ev_test_fail = 0
	saved := ev_cfg
	defer ev_cfg = saved

	// The keyboard half needs a keymap to resolve keysyms and modifiers, and
	// getting one is xkbcomp.odin's job.
	xkb_init_default()

	fmt.println("input backend self test")
	fmt.println()

	// --- Decoding -----------------------------------------------------------
	fmt.println("struct input_event")
	ev_check(size_of(Ev_Input_Event) == EV_EVENT_SIZE, "input_event is %d bytes, expected 24", size_of(Ev_Input_Event))
	{
		e := Ev_Input_Event{sec = 0x1122334455667788, usec = 0x99aabbcc, type = EV_KEY, code = 30, value = 1}
		b: [EV_EVENT_SIZE]u8
		ev_encode(e, b[:])
		g := ev_decode(b[:])
		ev_check(g == e, "round trip: got %v", g)
		ev_check(b[16] == 1 && b[17] == 0, "type is little-endian at offset 16")
		ev_check(b[18] == 30, "code is at offset 18")
	}

	// --- Partial reads ------------------------------------------------------
	fmt.println("partial reads")
	{
		kb := ev_fake_keyboard()
		ev_q_reset()
		xkb_state_reset()
		recs := [?]Ev_Rec {
			{EV_KEY, EV_KEY_A, 1, 1000},
			{EV_SYN, EV_SYN_REPORT, 0, 1000},
			{EV_KEY, EV_KEY_A, 0, 1050},
			{EV_SYN, EV_SYN_REPORT, 0, 1050},
			{EV_KEY, EV_KEY_SPACE, 1, 1100},
			{EV_SYN, EV_SYN_REPORT, 0, 1100},
		}
		b := ev_bytes(recs[:], context.temp_allocator)
		// Splits chosen to land inside a record, on a boundary, and inside the
		// next one: 7 bytes, then 13, then one byte at a time, then the rest.
		ev_feed(kb, b[0:7])
		ev_check(len(ev_queue) == 0, "nothing decoded from 7 bytes, got %d", len(ev_queue))
		ev_feed(kb, b[7:20])
		ev_check(len(ev_queue) == 0, "still nothing from 20 bytes, got %d", len(ev_queue))
		ev_feed(kb, b[20:24])
		ev_check(len(ev_queue) == 1, "one key event once 24 bytes have arrived, got %d", len(ev_queue))
		for i in 24 ..< len(b) {
			ev_feed(kb, b[i:i + 1])
		}
		ev_check(len(ev_queue) == 3, "three key events from the whole buffer, got %d", len(ev_queue))
		ev_check(ev_queue[0].keycode == EV_KEY_A && ev_queue[0].down, "first is A down")
		ev_check(ev_queue[1].keycode == EV_KEY_A && !ev_queue[1].down, "second is A up")
		ev_check(ev_queue[2].keycode == EV_KEY_SPACE, "third is space")
		ev_check(kb.carry_n == 0, "no bytes left over, got %d", kb.carry_n)
		ev_check(ev_xkb_keycode(ev_queue[0]) == EV_KEY_A + 8, "xkb keycode is evdev + 8")
	}

	// --- Keys with modifiers ------------------------------------------------
	fmt.println("keys and modifiers")
	{
		kb := ev_fake_keyboard()
		ev_q_reset()
		xkb_state_reset()
		recs := [?]Ev_Rec {
			{EV_KEY, EV_KEY_LEFTSHIFT, 1, 2000},
			{EV_SYN, EV_SYN_REPORT, 0, 2000},
			{EV_KEY, EV_KEY_A, 1, 2010},
			{EV_SYN, EV_SYN_REPORT, 0, 2010},
			{EV_KEY, EV_KEY_A, 0, 2060},
			{EV_SYN, EV_SYN_REPORT, 0, 2060},
			{EV_KEY, EV_KEY_LEFTSHIFT, 0, 2080},
			{EV_SYN, EV_SYN_REPORT, 0, 2080},
		}
		ev_play(kb, recs[:])
		ev_check(len(ev_queue) == 4, "four key events, got %d", len(ev_queue))
		if len(ev_queue) == 4 {
			ev_check(.Shift in ev_queue[1].mods, "shift is held on the A press, mods %v", ev_queue[1].mods)
			ev_check(ev_queue[1].mods_depressed != 0, "depressed mask is non-zero")
			ev_check(.Shift not_in ev_queue[3].mods, "shift is gone after release, mods %v", ev_queue[3].mods)
			if xkb_km.ok {
				ev_check(ev_queue[1].sym != 0, "the A press resolved to a keysym")
			}
		}
	}

	// --- Key repeat ---------------------------------------------------------
	fmt.println("key repeat")
	{
		kb := ev_fake_keyboard()
		ev_q_reset()
		xkb_state_reset()
		ev_cfg.repeat_delay = 400
		ev_cfg.repeat_rate = 25 // one every 40ms
		recs := [?]Ev_Rec{{EV_KEY, EV_KEY_A, 1, 3000}, {EV_SYN, EV_SYN_REPORT, 0, 3000}}
		ev_play(kb, recs[:])
		ev_check(ev_repeat.active, "repeat armed after a press")
		ev_check(ev_next_timeout(3000) == 400, "poll timeout is the repeat delay, got %d", ev_next_timeout(3000))
		ev_tick(3300)
		ev_check(len(ev_queue) == 1, "nothing repeats before the delay, got %d", len(ev_queue))
		ev_tick(3400)
		ev_check(len(ev_queue) == 2, "one repeat at the delay, got %d", len(ev_queue))
		ev_check(ev_queue[1].repeat && ev_queue[1].down, "the repeat is a down event marked repeat")
		ev_tick(3500)
		ev_check(len(ev_queue) == 2 + 2, "two more repeats 100ms later at 25/s, got %d", len(ev_queue) - 2)
		up := [?]Ev_Rec{{EV_KEY, EV_KEY_A, 0, 3520}, {EV_SYN, EV_SYN_REPORT, 0, 3520}}
		ev_play(kb, up[:])
		ev_check(!ev_repeat.active, "repeat disarmed on release")
		n := len(ev_queue)
		ev_tick(4000)
		ev_check(len(ev_queue) == n, "nothing repeats after release")
		// The kernel's own autorepeat must be ignored, or every key repeats twice.
		ev_q_reset()
		auto := [?]Ev_Rec{{EV_KEY, EV_KEY_A, 2, 4100}, {EV_SYN, EV_SYN_REPORT, 0, 4100}}
		ev_play(kb, auto[:])
		ev_check(len(ev_queue) == 0, "kernel autorepeat (value 2) is dropped, got %d", len(ev_queue))
		ev_cfg = saved
	}

	// --- Pointer ------------------------------------------------------------
	fmt.println("pointer motion and acceleration")
	{
		m := ev_fake_mouse()
		ev_q_reset()
		ev_pointer = {100, 100}
		ev_cfg.accel_profile = .Flat
		ev_cfg.accel_speed = 0
		recs := [?]Ev_Rec{{EV_REL, EV_REL_X, 10, 5000}, {EV_REL, EV_REL_Y, -4, 5000}, {EV_SYN, EV_SYN_REPORT, 0, 5000}}
		ev_play(m, recs[:])
		e, ok := ev_first(.Pointer_Motion)
		ev_check(ok, "a motion event came out")
		ev_check(ev_near(e.dx, 10, 0.001) && ev_near(e.dy, -4, 0.001), "flat profile is 1:1, got %v %v", e.dx, e.dy)
		ev_check(ev_near(e.udx, 10, 0.001), "the unaccelerated delta is preserved, got %v", e.udx)
		ev_check(ev_near(ev_pointer[0], 110, 0.001) && ev_near(ev_pointer[1], 96, 0.001), "the pointer moved, at %v", ev_pointer)

		ev_q_reset()
		ev_cfg.accel_profile = .Adaptive
		slow := [?]Ev_Rec{{EV_REL, EV_REL_X, 1, 5100}, {EV_SYN, EV_SYN_REPORT, 0, 5100}}
		ev_play(m, slow[:])
		s, _ := ev_first(.Pointer_Motion)
		ev_q_reset()
		fast := [?]Ev_Rec{{EV_REL, EV_REL_X, 60, 5110}, {EV_SYN, EV_SYN_REPORT, 0, 5110}}
		ev_play(m, fast[:])
		f, _ := ev_first(.Pointer_Motion)
		ev_check(s.dx / 1.0 < f.dx / 60.0, "a fast flick is accelerated more than a slow nudge (%.3f vs %.3f per unit)", s.dx, f.dx / 60)
		ev_check(s.dx >= 1.0, "the slow nudge is never attenuated below 1:1, got %.3f", s.dx)
		ev_cfg = saved

		// The pointer must not escape the screen.
		ev_q_reset()
		ev_pointer = {5, 5}
		ev_screen = {1920, 1080}
		huge := [?]Ev_Rec{{EV_REL, EV_REL_X, -500, 5200}, {EV_SYN, EV_SYN_REPORT, 0, 5200}}
		ev_play(m, huge[:])
		ev_check(ev_pointer[0] == 0, "the pointer clamps at the left edge, at %v", ev_pointer[0])
	}

	// --- Absolute pointer ---------------------------------------------------
	// QEMU's virtio-tablet, as its sysfs capabilities describe it: ABS_X and
	// ABS_Y over 0..32767, the three mouse buttons, a wheel, no contact and
	// no MT axes. It must classify as an absolute pointer, land on the pixel
	// the axis value names, and click where it stands.
	fmt.println("absolute pointer (virtio-tablet)")
	{
		d := new(Ev_Device)
		d.name = "QEMU Virtio Tablet"
		d.synthetic = true
		ev_set_bit(d.caps.ev[:], EV_KEY)
		ev_set_bit(d.caps.ev[:], EV_REL)
		ev_set_bit(d.caps.ev[:], EV_ABS)
		ev_set_bit(d.caps.rel[:], EV_REL_WHEEL)
		ev_set_bit(d.caps.abs[:], EV_ABS_X)
		ev_set_bit(d.caps.abs[:], EV_ABS_Y)
		// The real device's key bitmap is `30400 1f0000 0 0 0 0`: the five
		// mouse buttons, and BTN_TOUCH plus the two gear buttons.
		for b in ([?]int{EV_BTN_LEFT, EV_BTN_RIGHT, EV_BTN_MIDDLE, EV_BTN_SIDE, EV_BTN_EXTRA, EV_BTN_TOUCH, 0x150, 0x151}) {
			ev_set_bit(d.caps.key[:], b)
		}
		for a in ([?]int{EV_ABS_X, EV_ABS_Y}) {
			d.absinfo[a] = {minimum = 0, maximum = 32767}
			d.has_abs[a] = true
		}
		d.kinds = ev_classify(&d.caps, d.name)
		ev_check(d.kinds == {.Abs_Pointer}, "classified as an absolute pointer only, got %v", d.kinds)

		saved_screen := ev_screen
		ev_screen = {1281, 801}
		ev_pointer = {0, 0}
		ev_q_reset()
		mid := [?]Ev_Rec{{EV_ABS, EV_ABS_X, 16384, 7000}, {EV_ABS, EV_ABS_Y, 32767, 7000}, {EV_SYN, EV_SYN_REPORT, 0, 7000}}
		ev_play(d, mid[:])
		e, ok := ev_first(.Pointer_Motion_Absolute)
		ev_check(ok, "an absolute motion came out")
		ev_check(ev_near(e.x, 640.0, 0.1) && ev_near(e.y, 800, 0.001), "scaled to the output, got %v,%v", e.x, e.y)
		ev_check(ev_near(e.dx, e.x, 0.001), "the delta is from where the pointer was")

		ev_q_reset()
		click := [?]Ev_Rec{{EV_KEY, EV_BTN_LEFT, 1, 7010}, {EV_SYN, EV_SYN_REPORT, 0, 7010}}
		ev_play(d, click[:])
		ev_check(ev_count(.Pointer_Motion_Absolute) == 0, "a click without motion does not move the pointer")
		b, bok := ev_first(.Button)
		ev_check(bok && b.button == EV_BTN_LEFT && b.down, "and is a left press")

		in_: p.Input
		ev_q_reset()
		again := [?]Ev_Rec{{EV_ABS, EV_ABS_X, 0, 7020}, {EV_SYN, EV_SYN_REPORT, 0, 7020}}
		ev_play(d, again[:])
		ev_apply_to_input(&in_)
		ev_check(in_.mouse == {0, 800}, "p.Input carries the absolute position, got %v", in_.mouse)
		ev_check(in_.mouse_delta.x < 0, "with a delta, so the compositor sends wl_pointer.motion")
		delete(in_.keys)
		ev_screen = saved_screen
		ev_buttons = {}
		free(d)
	}

	// --- Wheel --------------------------------------------------------------
	fmt.println("wheel")
	{
		m := ev_fake_mouse()
		ev_q_reset()
		// One detent reported both ways in the same frame. Counting both is
		// the classic double-scroll bug.
		both := [?]Ev_Rec {
			{EV_REL, EV_REL_WHEEL, -1, 6000},
			{EV_REL, EV_REL_WHEEL_HI_RES, -120, 6000},
			{EV_SYN, EV_SYN_REPORT, 0, 6000},
		}
		ev_play(m, both[:])
		ev_check(ev_count(.Axis) == 1, "one axis event per detent, got %d", ev_count(.Axis))
		a, _ := ev_first(.Axis)
		// The kernel counts the wheel positive upwards; Wayland's vertical
		// axis is positive downwards. -1 / -120 is one notch down: +120.
		ev_check(a.v120 == 120, "v120 is +120 for one notch down, got %d", a.v120)
		ev_check(a.source == .Wheel, "the source is a wheel")

		ev_q_reset()
		part := [?]Ev_Rec{{EV_REL, EV_REL_WHEEL_HI_RES, 30, 6100}, {EV_SYN, EV_SYN_REPORT, 0, 6100}}
		ev_play(m, part[:])
		p1, _ := ev_first(.Axis)
		ev_check(p1.v120 == -30, "a quarter notch up survives as v120 -30, got %d", p1.v120)
		ev_check(ev_near(p1.value, -ev_cfg.scroll_factor / 4, 0.001), "and as a quarter of a detent in pixels, got %v", p1.value)

		ev_q_reset()
		lo := [?]Ev_Rec{{EV_REL, EV_REL_WHEEL, 1, 6200}, {EV_SYN, EV_SYN_REPORT, 0, 6200}}
		ev_play(m, lo[:])
		l, _ := ev_first(.Axis)
		ev_check(l.value < 0, "kernel wheel up becomes a negative Wayland axis, got %v", l.value)

		ev_q_reset()
		ev_cfg.natural_scroll = true
		ev_play(m, lo[:])
		nat, _ := ev_first(.Axis)
		ev_check(nat.value > 0, "natural scroll inverts it, got %v", nat.value)
		ev_cfg = saved
	}

	// --- Buttons ------------------------------------------------------------
	fmt.println("buttons")
	{
		m := ev_fake_mouse()
		ev_q_reset()
		ev_buttons = {}
		recs := [?]Ev_Rec {
			{EV_KEY, EV_BTN_LEFT, 1, 7000},
			{EV_SYN, EV_SYN_REPORT, 0, 7000},
			{EV_KEY, EV_BTN_LEFT, 0, 7100},
			{EV_SYN, EV_SYN_REPORT, 0, 7100},
		}
		ev_play(m, recs[:])
		ev_check(ev_count(.Button) == 2, "a press and a release, got %d", ev_count(.Button))
		ev_check(ev_queue[0].button == EV_BTN_LEFT && ev_queue[0].down, "left down first")
		ev_check(ev_buttons == {}, "nothing is held afterwards")

		ev_q_reset()
		ev_cfg.left_handed = true
		down := [?]Ev_Rec{{EV_KEY, EV_BTN_LEFT, 1, 7200}, {EV_SYN, EV_SYN_REPORT, 0, 7200}}
		ev_play(m, down[:])
		ev_check(ev_queue[0].button == EV_BTN_RIGHT, "left handed swaps the buttons, got %x", ev_queue[0].button)
		ev_cfg = saved
		ev_buttons = {}
	}

	// --- Touchpad: two-finger scroll ---------------------------------------
	fmt.println("touchpad: two-finger scroll")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		ev_last_key_ms = 0
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		// Both fingers land in the same frame, 20mm apart.
		ev_touch_down_rec(&buf, 0, 1, 400, 300, 8000)
		ev_touch_down_rec(&buf, 1, 2, 640, 300, 8000)
		ev_syn_rec(&buf, 8000)
		ev_play(tp, buf[:])
		ev_check(ev_count(.Pointer_Motion) == 0, "two fingers landing move nothing, got %d", ev_count(.Pointer_Motion))
		ev_check(tp.fingers == 2, "two fingers are tracked, got %d", tp.fingers)

		// Drag both down the pad by 5mm, 60 units at 12/mm, in five steps.
		clear(&buf)
		y := i32(300)
		ms := u32(8000)
		for i in 0 ..< 5 {
			y += 12
			ms += 10
			ev_touch_move_rec(&buf, 0, 400, y, ms)
			ev_touch_move_rec(&buf, 1, 640, y, ms)
			ev_syn_rec(&buf, ms)
		}
		ev_play(tp, buf[:])
		vert := ev_axis_total(.Vertical)
		horiz := ev_axis_total(.Horizontal)
		ev_check(ev_count(.Axis) > 0, "two-finger travel scrolls, got %d axis events", ev_count(.Axis))
		ev_check(vert > 0, "fingers moving down scroll down by default, got %v", vert)
		ev_check(horiz == 0, "nothing leaks into the horizontal axis, got %v", horiz)
		ev_check(ev_count(.Pointer_Motion) == 0, "and the pointer never moves while scrolling, got %d", ev_count(.Pointer_Motion))
		// 5mm of travel minus the 1.2mm dead zone, at 18px/mm.
		want := (5.0 - ev_cfg.scroll_start_mm) * ev_cfg.touchpad_scroll_mm
		ev_check(ev_near(vert, want, want * 0.35), "the distance is about %.1fpx, got %.1f", want, vert)

		// Natural scrolling flips the sign and nothing else.
		tp2 := ev_fake_touchpad()
		ev_q_reset()
		ev_cfg.natural_scroll = true
		b2 := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&b2, 0, 1, 400, 300, 9000)
		ev_touch_down_rec(&b2, 1, 2, 640, 300, 9000)
		ev_syn_rec(&b2, 9000)
		yy := i32(300)
		mm := u32(9000)
		for i in 0 ..< 5 {
			yy += 12
			mm += 10
			ev_touch_move_rec(&b2, 0, 400, yy, mm)
			ev_touch_move_rec(&b2, 1, 640, yy, mm)
			ev_syn_rec(&b2, mm)
		}
		ev_play(tp2, b2[:])
		ev_check(ev_axis_total(.Vertical) < 0, "natural scroll inverts the touchpad too, got %v", ev_axis_total(.Vertical))
		ev_cfg = saved
	}

	// --- Touchpad: a third finger must not jolt the view --------------------
	fmt.println("touchpad: finger count changes")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 400, 300, 10000)
		ev_touch_down_rec(&buf, 1, 2, 640, 300, 10000)
		ev_syn_rec(&buf, 10000)
		for i in 0 ..< 6 {
			ev_touch_move_rec(&buf, 0, 400, 300 + i32(12 * (i + 1)), 10010 + u32(i * 10))
			ev_touch_move_rec(&buf, 1, 640, 300 + i32(12 * (i + 1)), 10010 + u32(i * 10))
			ev_syn_rec(&buf, 10010 + u32(i * 10))
		}
		ev_play(tp, buf[:])
		ev_check(tp.scrolling, "scrolling is engaged")
		before := len(ev_queue)
		// A third finger arrives a long way from the other two.
		clear(&buf)
		ev_touch_down_rec(&buf, 2, 3, 100, 100, 10100)
		ev_syn_rec(&buf, 10100)
		ev_play(tp, buf[:])
		ev_check(!tp.scrolling, "scrolling stops when the finger count changes")
		stop := false
		for e in ev_queue[before:] {
			if e.kind == .Axis_Stop {stop = true}
			ev_check(e.kind != .Axis, "no axis event is emitted on the transition")
			ev_check(e.kind != .Pointer_Motion, "and no pointer jump either")
		}
		ev_check(stop, "an axis stop is emitted so the client ends its kinetic scroll")
		g, gok := ev_first(.Gesture_Begin)
		ev_check(gok && g.fingers == 3, "a three-finger gesture begins, fingers %d", g.fingers)
	}

	// --- Touchpad: drag across slots ---------------------------------------
	fmt.println("touchpad: a finger lifting mid-drag")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 400, 300, 11000)
		ev_syn_rec(&buf, 11000)
		ev_touch_move_rec(&buf, 0, 436, 300, 11010)
		ev_syn_rec(&buf, 11010)
		ev_play(tp, buf[:])
		first, _ := ev_first(.Pointer_Motion)
		ev_check(first.dx > 0, "one finger moves the pointer, got %v", first.dx)

		// A second finger lands in slot 1 at the far side, then the first one
		// lifts. The pointer must pick up slot 1 where it is, not leap to it.
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 1, 2, 900, 500, 11020)
		ev_syn_rec(&buf, 11020)
		ev_touch_up_rec(&buf, 0, 11030)
		ev_syn_rec(&buf, 11030)
		ev_play(tp, buf[:])
		ev_check(ev_count(.Pointer_Motion) == 0, "no motion while the hand-off happens, got %d", ev_count(.Pointer_Motion))
		ev_q_reset()
		clear(&buf)
		ev_touch_move_rec(&buf, 1, 912, 500, 11040)
		ev_syn_rec(&buf, 11040)
		ev_play(tp, buf[:])
		m2, ok2 := ev_first(.Pointer_Motion)
		ev_check(ok2, "the surviving finger drives the pointer")
		ev_check(ok2 && m2.dx > 0 && m2.dx < 40, "by its own 1mm, not the 500 units between the fingers, got %v", m2.dx)
	}

	// --- Touchpad: tap ------------------------------------------------------
	fmt.println("touchpad: tap to click")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		ev_last_key_ms = 0
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 12000)
		ev_syn_rec(&buf, 12000)
		ev_touch_up_rec(&buf, 0, 12070)
		ev_syn_rec(&buf, 12070)
		ev_play(tp, buf[:])
		// Tap-and-drag holds the click back for one drag window.
		ev_check(ev_count(.Button) == 0, "the click waits to see if a drag follows, got %d", ev_count(.Button))
		ev_tap_flush(12500)
		ev_check(ev_count(.Button) == 0, "flushing a device that is not registered does nothing")
		ev_touch_tap_timeout(tp, 12500)
		ev_check(ev_count(.Button) == 2, "then it clicks, got %d button events", ev_count(.Button))
		if ev_count(.Button) == 2 {
			ev_check(ev_queue[0].button == EV_BTN_LEFT && ev_queue[0].down, "left press")
			ev_check(!ev_queue[1].down, "then release")
		}

		// A two-finger tap is a right click, and it is immediate.
		tp2 := ev_fake_touchpad()
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 13000)
		ev_touch_down_rec(&buf, 1, 2, 620, 350, 13000)
		ev_syn_rec(&buf, 13000)
		ev_touch_up_rec(&buf, 0, 13060)
		ev_touch_up_rec(&buf, 1, 13060)
		ev_syn_rec(&buf, 13060)
		ev_play(tp2, buf[:])
		b, bok := ev_first(.Button)
		ev_check(bok && b.button == EV_BTN_RIGHT, "a two-finger tap is a right click, got %x", b.button)

		// A tap that travelled is a move, not a click.
		tp3 := ev_fake_touchpad()
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 14000)
		ev_syn_rec(&buf, 14000)
		ev_touch_move_rec(&buf, 0, 620, 350, 14030)
		ev_syn_rec(&buf, 14030)
		ev_touch_up_rec(&buf, 0, 14050)
		ev_syn_rec(&buf, 14050)
		ev_play(tp3, buf[:])
		ev_touch_tap_timeout(tp3, 14600)
		ev_check(ev_count(.Button) == 0, "a travelling touch is not a tap, got %d", ev_count(.Button))
		ev_check(ev_count(.Pointer_Motion) > 0, "it moved the pointer instead")

		// Tap, then a finger straight back down: that is a drag, and the
		// button stays held until the finger lifts.
		tp4 := ev_fake_touchpad()
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 15000)
		ev_syn_rec(&buf, 15000)
		ev_touch_up_rec(&buf, 0, 15060)
		ev_syn_rec(&buf, 15060)
		ev_touch_down_rec(&buf, 0, 2, 500, 350, 15100)
		ev_syn_rec(&buf, 15100)
		ev_touch_move_rec(&buf, 0, 560, 350, 15150)
		ev_syn_rec(&buf, 15150)
		ev_play(tp4, buf[:])
		bd, bdok := ev_first(.Button)
		ev_check(bdok && bd.down && bd.button == EV_BTN_LEFT, "the second touch presses and holds")
		ev_check(ev_count(.Button) == 1, "and does not release yet, got %d", ev_count(.Button))
		ev_check(ev_count(.Pointer_Motion) > 0, "the drag moves the pointer")
		clear(&buf)
		ev_touch_up_rec(&buf, 0, 15300)
		ev_syn_rec(&buf, 15300)
		ev_play(tp4, buf[:])
		ev_check(ev_count(.Button) == 2 && !ev_queue[len(ev_queue) - 1].down, "lifting ends the drag")
	}

	// --- Touchpad: palm rejection -------------------------------------------
	fmt.println("touchpad: palm rejection")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		ev_last_key_ms = 0
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 300, 500, 16000)
		append(&buf, Ev_Rec{EV_ABS, EV_ABS_MT_TOUCH_MAJOR, 900, 16000}) // wide contact
		ev_syn_rec(&buf, 16000)
		ev_touch_move_rec(&buf, 0, 500, 560, 16050)
		ev_syn_rec(&buf, 16050)
		ev_touch_up_rec(&buf, 0, 16100)
		ev_syn_rec(&buf, 16100)
		ev_play(tp, buf[:])
		ev_touch_tap_timeout(tp, 16600)
		ev_check(ev_count(.Pointer_Motion) == 0, "a palm does not move the pointer, got %d", ev_count(.Pointer_Motion))
		ev_check(ev_count(.Button) == 0, "a palm does not click, got %d", ev_count(.Button))

		// A palm resting beside a real finger must not be counted into the
		// finger total, or one finger would read as two and scroll.
		tp2 := ev_fake_touchpad()
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 0, 1, 200, 600, 17000)
		append(&buf, Ev_Rec{EV_ABS, EV_ABS_MT_TOUCH_MAJOR, 900, 17000})
		ev_touch_down_rec(&buf, 1, 2, 700, 300, 17000)
		append(&buf, Ev_Rec{EV_ABS, EV_ABS_MT_TOUCH_MAJOR, 120, 17000})
		ev_syn_rec(&buf, 17000)
		ev_touch_move_rec(&buf, 1, 736, 300, 17020)
		ev_syn_rec(&buf, 17020)
		ev_play(tp2, buf[:])
		ev_check(tp2.fingers == 1, "the palm is not a finger, count is %d", tp2.fingers)
		ev_check(ev_count(.Axis) == 0, "so nothing scrolls, got %d", ev_count(.Axis))
		ev_check(ev_count(.Pointer_Motion) == 1, "and the real finger still moves the pointer, got %d", ev_count(.Pointer_Motion))

		// Once a palm, always a palm: a contact that narrows mid-stroke must
		// not suddenly grab the cursor.
		clear(&buf)
		append(&buf, Ev_Rec{EV_ABS, EV_ABS_MT_SLOT, 0, 17040})
		append(&buf, Ev_Rec{EV_ABS, EV_ABS_MT_TOUCH_MAJOR, 50, 17040})
		ev_syn_rec(&buf, 17040)
		ev_play(tp2, buf[:])
		ev_check(tp2.slots[0].palm, "the palm flag is sticky")
	}

	// --- Touchpad: disable while typing -------------------------------------
	fmt.println("touchpad: disable while typing")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		ev_last_key_ms = 18000
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 18050)
		ev_syn_rec(&buf, 18050)
		ev_touch_move_rec(&buf, 0, 560, 350, 18080)
		ev_syn_rec(&buf, 18080)
		ev_touch_up_rec(&buf, 0, 18100)
		ev_syn_rec(&buf, 18100)
		ev_play(tp, buf[:])
		ev_touch_tap_timeout(tp, 18700)
		ev_check(ev_count(.Pointer_Motion) == 0, "the pad is deaf while typing, got %d", ev_count(.Pointer_Motion))
		ev_check(ev_count(.Button) == 0, "and does not tap, got %d", ev_count(.Button))

		// Past the timeout it wakes up again.
		tp2 := ev_fake_touchpad()
		ev_q_reset()
		clear(&buf)
		ev_touch_down_rec(&buf, 0, 1, 500, 350, 18600)
		ev_syn_rec(&buf, 18600)
		ev_touch_move_rec(&buf, 0, 560, 350, 18630)
		ev_syn_rec(&buf, 18630)
		ev_play(tp2, buf[:])
		ev_check(ev_count(.Pointer_Motion) > 0, "and wakes up after the timeout, got %d", ev_count(.Pointer_Motion))
		ev_last_key_ms = 0
	}

	// --- Clickpad -----------------------------------------------------------
	fmt.println("touchpad: clickpad buttons")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 400, 300, 19000)
		ev_touch_down_rec(&buf, 1, 2, 640, 300, 19000)
		ev_syn_rec(&buf, 19000)
		ev_play(tp, buf[:])
		ev_q_reset()
		clear(&buf)
		append(&buf, Ev_Rec{EV_KEY, EV_BTN_LEFT, 1, 19050})
		ev_syn_rec(&buf, 19050)
		append(&buf, Ev_Rec{EV_KEY, EV_BTN_LEFT, 0, 19120})
		ev_syn_rec(&buf, 19120)
		ev_play(tp, buf[:])
		ev_check(ev_count(.Button) == 2, "a press and a release, got %d", ev_count(.Button))
		ev_check(ev_queue[0].button == EV_BTN_RIGHT, "two fingers on a clickpad is a right click, got %x", ev_queue[0].button)
		ev_check(ev_queue[1].button == EV_BTN_RIGHT, "and the release matches the press, got %x", ev_queue[1].button)
		ev_buttons = {}
	}

	// --- SYN_DROPPED --------------------------------------------------------
	fmt.println("SYN_DROPPED")
	{
		tp := ev_fake_touchpad()
		ev_q_reset()
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 400, 300, 20000)
		ev_syn_rec(&buf, 20000)
		ev_play(tp, buf[:])
		ev_check(tp.fingers == 1, "one finger down")
		clear(&buf)
		append(&buf, Ev_Rec{EV_SYN, EV_SYN_DROPPED, 0, 20010})
		ev_play(tp, buf[:])
		ev_check(tp.fingers == 0, "a dropped frame throws the slot state away, got %d", tp.fingers)
		ev_check(tp.carry_n == 0, "and any half-read record with it")
	}

	// --- Touchscreen --------------------------------------------------------
	fmt.println("touchscreen")
	{
		ts := ev_fake_touchscreen()
		ev_screen = {1920, 1080}
		ev_q_reset()
		buf := make([dynamic]Ev_Rec, context.temp_allocator)
		ev_touch_down_rec(&buf, 0, 1, 1600, 900, 21000)
		ev_syn_rec(&buf, 21000)
		ev_play(ts, buf[:])
		td, tok := ev_first(.Touch_Down)
		ev_check(tok, "a touch down came out")
		ev_check(ev_near(td.x, 1600.0 / 3199.0 * 1920.0, 1), "scaled to the screen, x %v", td.x)
		ev_q_reset()
		clear(&buf)
		ev_touch_up_rec(&buf, 0, 21100)
		ev_syn_rec(&buf, 21100)
		ev_play(ts, buf[:])
		ev_check(ev_count(.Touch_Up) == 1, "and a touch up, got %d", ev_count(.Touch_Up))
	}

	// --- Pause and resume ---------------------------------------------------
	fmt.println("pause and resume")
	{
		ev_q_reset()
		ev_buttons = {.Left}
		ev_pause_all()
		ev_check(ev_count(.Button) == 1 && !ev_queue[0].down, "pausing releases a held button")
		ev_buttons = {}
		ev_q_reset()
	}

	// --- Classification against synthetic hardware --------------------------
	fmt.println("classification")
	{
		ev_check(ev_fake_keyboard().kinds == {.Keyboard}, "a keyboard is a keyboard, got %v", ev_fake_keyboard().kinds)
		ev_check(ev_fake_mouse().kinds == {.Mouse}, "a mouse is a mouse, got %v", ev_fake_mouse().kinds)
		ev_check(.Touchpad in ev_fake_touchpad().kinds, "a clickpad is a touchpad, got %v", ev_fake_touchpad().kinds)
		ev_check(.Touchscreen not_in ev_fake_touchpad().kinds, "and not a touchscreen")
		ev_check(.Touchscreen in ev_fake_touchscreen().kinds, "INPUT_PROP_DIRECT makes it a touchscreen, got %v", ev_fake_touchscreen().kinds)
		ev_check(.Touchpad not_in ev_fake_touchscreen().kinds, "and not a touchpad")

		// A real Synaptics clickpad bitmap, taken from the format
		// /sys/class/input/*/capabilities/ uses.
		syn: Ev_Caps
		ev_parse_bitmap("1b", syn.ev[:]) // SYN, KEY, ABS, MSC
		ev_parse_bitmap("e520 10000 0 0 0 0", syn.key[:])
		ev_parse_bitmap("260800000000003", syn.abs[:])
		ev_parse_bitmap("5", syn.prop[:]) // POINTER | BUTTONPAD
		k := ev_classify(&syn, "SynPS/2 Synaptics TouchPad")
		ev_check(.Touchpad in k, "the Synaptics bitmap classifies as a touchpad, got %v", k)
		ev_check(.Keyboard not_in k, "and not as a keyboard")

		// Bit order: "ffff0000 0 0 0 0" is bits 16..31 of word four.
		var: [12]u64
		ev_parse_bitmap("ffff0000 0 0 0 0", var[:])
		ev_check(var[4] == 0xffff0000, "the leftmost word is the highest, got %x", var[4])
		ev_check(ev_bit(var[:], 4 * 64 + 16), "so bit 272 is set")
		ev_check(!ev_bit(var[:], 4 * 64 + 15), "and bit 271 is not")
	}

	// --- Classification against this machine's real hardware ----------------
	fmt.println()
	fmt.println("this machine, read from /sys/class/input (no device opened):")
	found := ev_scan()
	nk, nm, ntp := 0, 0, 0
	for d in found {
		if d.kinds == {} {
			continue
		}
		fmt.printf("  %-14s %-40s %v\n", d.path[len("/dev/input/"):], d.name, d.kinds)
		if .Keyboard in d.kinds {nk += 1}
		if .Mouse in d.kinds {nm += 1}
		if .Touchpad in d.kinds {ntp += 1}
	}
	ev_check(len(found) > 0, "sysfs enumeration found something at all")
	ev_check(nk >= 1, "at least one keyboard on this machine, found %d", nk)
	ev_check(nm >= 1, "at least one mouse on this machine, found %d", nm)

	fmt.println()
	fmt.printf("evdev: %d passed, %d failed\n", ev_test_pass, ev_test_fail)
	return ev_test_fail
}

// ---------------------------------------------------------------------------
// Entry points
//
// main.odin is owned by another agent, so the self-test flags hook in through
// an @(init) procedure rather than its argument loop. --input-selftest and
// --xkb-dump never open a socket, never open a device, and exit before main.
// ---------------------------------------------------------------------------

@(init)
ev_init_flags :: proc "contextless" () {
	context = runtime.default_context()
	args := os.args
	for a, i in args {
		switch {
		case a == "--input-selftest":
			fail := ev_selftest()
			fmt.println()
			fail += xkb_selftest()
			os.exit(fail == 0 ? 0 : 1)
		case a == "--xkb-dump":
			layout := i + 1 < len(args) ? args[i + 1] : ""
			os.exit(xkb_dump(layout))
		}
	}
}
