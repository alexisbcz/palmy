#+build !darwin
package palmy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// ---------------------------------------------------------------------------
// The X11 backend.
//
// The core protocol, hand-rolled on the same unix socket machinery the Wayland
// side uses. A request is a 4-byte header (major opcode, one free byte, and a
// length in 32-bit words) followed by its arguments; a reply is 32 bytes plus
// `length` more words; an event is always 32 bytes. Replies, errors and events
// share one stream, so the dispatcher below walks records and routes them.
//
// Pixels reach the server through MIT-SHM when it has the extension — which
// maps onto palmy's existing double-buffered shared-memory design almost
// exactly, down to the completion event standing in for wl_buffer.release —
// and through chunked PutImage when it does not.
// ---------------------------------------------------------------------------

// Core request opcodes.
@(private)
X_CREATE_WINDOW :: 1
@(private)
X_CHANGE_WINDOW_ATTRIBUTES :: 2
@(private)
X_MAP_WINDOW :: 8
@(private)
X_CONFIGURE_WINDOW :: 12
@(private)
X_INTERN_ATOM :: 16
@(private)
X_CHANGE_PROPERTY :: 18
@(private)
X_GET_PROPERTY :: 20
@(private)
X_SEND_EVENT :: 25
@(private)
X_GET_INPUT_FOCUS :: 43
@(private)
X_OPEN_FONT :: 45
@(private)
X_CREATE_GC :: 55
@(private)
X_PUT_IMAGE :: 72
@(private)
X_CREATE_GLYPH_CURSOR :: 94
@(private)
X_QUERY_EXTENSION :: 98
@(private)
X_GET_KEYBOARD_MAPPING :: 101
@(private)
X_GET_MODIFIER_MAPPING :: 119

// MIT-SHM minor opcodes.
@(private)
SHM_QUERY_VERSION :: 0
@(private)
SHM_ATTACH :: 1
@(private)
SHM_DETACH :: 2
@(private)
SHM_PUT_IMAGE :: 3

// Event codes.
@(private)
X_KEY_PRESS :: 2
@(private)
X_KEY_RELEASE :: 3
@(private)
X_BUTTON_PRESS :: 4
@(private)
X_BUTTON_RELEASE :: 5
@(private)
X_MOTION_NOTIFY :: 6
@(private)
X_ENTER_NOTIFY :: 7
@(private)
X_LEAVE_NOTIFY :: 8
@(private)
X_FOCUS_IN :: 9
@(private)
X_FOCUS_OUT :: 10
@(private)
X_EXPOSE :: 12
@(private)
X_VISIBILITY_NOTIFY :: 15
@(private)
X_DESTROY_NOTIFY :: 17
@(private)
X_UNMAP_NOTIFY :: 18
@(private)
X_MAP_NOTIFY :: 19
@(private)
X_CONFIGURE_NOTIFY :: 22
@(private)
X_PROPERTY_NOTIFY :: 28
@(private)
X_CLIENT_MESSAGE :: 33
@(private)
X_MAPPING_NOTIFY :: 34
@(private)
X_GENERIC_EVENT :: 35

// Predefined atoms, from Xatom.h. Interning these would be a wasted
// roundtrip: every server has them at fixed values.
@(private)
XA_ATOM :: u32(4)
@(private)
XA_CARDINAL :: u32(6)
@(private)
XA_STRING :: u32(31)
@(private)
XA_WM_NAME :: u32(39)
@(private)
XA_WM_NORMAL_HINTS :: u32(40)
@(private)
XA_WM_SIZE_HINTS :: u32(41)
@(private)
XA_WM_CLASS :: u32(67)

// CreateWindow / ChangeWindowAttributes value-mask bits.
@(private)
CW_BACK_PIXEL :: u32(1 << 1)
@(private)
CW_BIT_GRAVITY :: u32(1 << 4)
@(private)
CW_EVENT_MASK :: u32(1 << 11)
@(private)
CW_CURSOR :: u32(1 << 14)

// The events palmy needs. Everything palmy's input model can express comes
// from this set.
@(private)
X_EVENT_MASK ::
	u32(1) | // KeyPress
	u32(2) | // KeyRelease
	u32(4) | // ButtonPress
	u32(8) | // ButtonRelease
	u32(0x10) | // EnterWindow
	u32(0x20) | // LeaveWindow
	u32(0x40) | // PointerMotion
	u32(0x8000) | // Exposure
	u32(0x10000) | // VisibilityChange
	u32(0x20000) | // StructureNotify
	u32(0x200000) | // FocusChange
	u32(0x400000) // PropertyChange

@(private)
X_ZPIXMAP :: u8(2)

@(private)
IPC_PRIVATE :: 0
@(private)
IPC_CREAT :: 0o1000
@(private)
IPC_RMID :: 0

X11_State :: struct {
	display:          string,
	screen:           int,

	// From the setup reply.
	id_base:          u32,
	id_mask:          u32,
	id_next:          u32,
	root:             u32,
	root_visual:      u32,
	root_depth:       u8,
	black_pixel:      u32,
	screen_w:         int,
	screen_h:         int,
	max_request:      int, // in bytes
	min_keycode:      u32,
	max_keycode:      u32,
	authed:           bool,

	// The sequence number of the last request written. Replies, errors and
	// events all carry the low 16 bits of one of these.
	seq:              u32,

	// The reply currently being waited for, if any.
	want_seq:         u32,
	reply:            [dynamic]u8,
	reply_ok:         bool,
	reply_done:       bool,
	in_sync:          int,

	window:           u32,
	gc:               u32,
	mapped:           bool,
	// VisibilityNotify said FullyObscured: another window covers all of this
	// one. Under a compositing manager the server never says so.
	obscured:         bool,

	// Interned atoms.
	a_wm_protocols:   u32,
	a_wm_delete:      u32,
	a_net_wm_name:    u32,
	a_utf8_string:    u32,
	a_net_wm_state:   u32,
	a_fullscreen:     u32,
	a_max_vert:       u32,
	a_max_horz:       u32,
	a_net_wm_pid:     u32,

	// MIT-SHM.
	shm_major:        u8,
	shm_first_event:  u8,
	shm_present:      bool,
	shm_in_use:       bool,
	shm_id:           int,
	shm_seg:          u32,
	shm_mem:          []u8,
	shm_size:         int,

	// The PutImage fallback owns its own memory instead.
	soft_mem:         []u32,

	// Cursors from the standard "cursor" font, created on first use.
	cursor_font:      u32,
	cursors:          [Cursor]u32,

	// Keyboard bookkeeping. `held` catches a server-generated repeat that
	// arrives without an intervening release.
	held:             [32]u8,
	repeat_pending:   u32,

	// Deferred work that must not run re-entrantly from the dispatcher.
	remap:            bool,
	state_dirty:      bool,

	debug:            bool,
}

// ---------------------------------------------------------------------------
// Byte plumbing
// ---------------------------------------------------------------------------

@(private)
xo8 :: proc(c: ^Conn, v: u8) {
	append(&c.out, v)
}

@(private)
xo16 :: proc(c: ^Conn, v: u16) {
	b := transmute([2]u8)v
	append(&c.out, ..b[:])
}

@(private)
xo32 :: proc(c: ^Conn, v: u32) {
	b := transmute([4]u8)v
	append(&c.out, ..b[:])
}

@(private)
xopad :: proc(c: ^Conn, n: int) {
	for _ in 0 ..< n {
		append(&c.out, 0)
	}
}

@(private)
xr8 :: proc(b: []u8, o: int) -> u8 {
	return o >= 0 && o < len(b) ? b[o] : 0
}

@(private)
xr16 :: proc(b: []u8, o: int) -> u16 {
	if o < 0 || o + 2 > len(b) {
		return 0
	}
	return u16(b[o]) | u16(b[o + 1]) << 8
}

@(private)
xri16 :: proc(b: []u8, o: int) -> int {
	return int(i16(xr16(b, o)))
}

@(private)
xr32 :: proc(b: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(b) {
		return 0
	}
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

// x_begin opens a request and x_end closes it, patching in the length the
// header could not know yet and returning the sequence number the server will
// answer under.
@(private)
x_begin :: proc(w: ^Window, opcode: u8, detail: u8 = 0) -> int {
	c := &w.conn
	start := len(c.out)
	xo8(c, opcode)
	xo8(c, detail)
	xo16(c, 0)
	return start
}

@(private)
x_end :: proc(w: ^Window, start: int) -> u32 {
	c := &w.conn
	for (len(c.out) - start) % 4 != 0 {
		append(&c.out, 0)
	}
	words := u16((len(c.out) - start) / 4)
	b := transmute([2]u8)words
	copy(c.out[start + 2:][:2], b[:])
	w.x.seq += 1
	return w.x.seq
}

@(private)
x_new_id :: proc(w: ^Window) -> u32 {
	id := w.x.id_base | (w.x.id_next & w.x.id_mask)
	w.x.id_next += 1
	return id
}

@(private)
x_debug :: proc(w: ^Window, format: string, args: ..any) {
	if !w.x.debug {
		return
	}
	fmt.eprintf("palmy/x11: ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\n")
}

// ---------------------------------------------------------------------------
// Connecting
// ---------------------------------------------------------------------------

// x_parse_display splits DISPLAY, which is `[host]:display[.screen]`.
@(private)
x_parse_display :: proc(s: string) -> (host, display: string, screen: int, ok: bool) {
	colon := strings.last_index_byte(s, ':')
	if colon < 0 {
		return "", "", 0, false
	}
	host = s[:colon]
	rest := s[colon + 1:]
	if rest == "" {
		return "", "", 0, false
	}
	if dot := strings.index_byte(rest, '.'); dot >= 0 {
		display = rest[:dot]
		for ch in rest[dot + 1:] {
			if ch < '0' || ch > '9' {
				screen = 0
				break
			}
			screen = screen * 10 + int(ch - '0')
		}
	} else {
		display = rest
	}
	if display == "" {
		return "", "", 0, false
	}
	return host, display, screen, true
}

// x_read_at_least blocks until the receive buffer holds `n` bytes. Only the
// connection handshake needs it; after that everything is event driven.
@(private)
x_read_at_least :: proc(w: ^Window, n: int) -> bool {
	c := &w.conn
	conn_flush(c)
	deadline := time.time_add(time.now(), 5 * time.Second)
	for len(c.rx) < n {
		if c.fatal != "" {
			return false
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		cnt, perr := poll_fds(pfd[:], 200)
		if perr != .NONE && perr != .EINTR {
			c.fatal = fmt.tprintf("poll on the X server socket failed: %v", perr)
			return false
		}
		if cnt > 0 && !conn_read(c) {
			return false
		}
		if time.since(deadline) > 0 {
			c.fatal = "the X server stopped responding during connection setup"
			return false
		}
	}
	return true
}

@(private)
x_connect :: proc(w: ^Window) -> (err: string) {
	disp := os.get_env("DISPLAY", context.temp_allocator)
	if disp == "" {
		return "DISPLAY is not set, so there is no X server to connect to"
	}
	host, num, screen, ok := x_parse_display(disp)
	if !ok {
		return fmt.tprintf("cannot make sense of DISPLAY=%q", disp)
	}
	if host != "" && host != "unix" && host != "localhost" {
		return fmt.tprintf(
			"DISPLAY=%q names a remote X server; palmy's X11 backend speaks only to a local one over /tmp/.X11-unix",
			disp,
		)
	}
	w.x.display = strings.clone(num)
	w.x.screen = screen

	path := fmt.tprintf("/tmp/.X11-unix/X%s", num)
	if e := conn_open_unix(&w.conn, path, "X server"); e != "" {
		return e
	}
	c := &w.conn

	// MIT-MAGIC-COOKIE-1, if this display has one. A server started without
	// access control (Xvfb's default) accepts an empty authorisation, so a
	// missing cookie is not by itself an error.
	auth := xauth_for_display(num, context.temp_allocator)
	w.x.authed = auth.name != ""
	x_debug(w, "connecting to %s, auth=%s (%d bytes)", path, auth.name, len(auth.data))

	append(&c.out, 'l', 0) // little-endian; palmy only builds for LE hosts
	xo16(c, 11) // protocol-major-version
	xo16(c, 0) // protocol-minor-version
	xo16(c, u16(len(auth.name)))
	xo16(c, u16(len(auth.data)))
	xo16(c, 0)
	append(&c.out, auth.name)
	xopad(c, (-len(auth.name)) & 3)
	append(&c.out, ..auth.data)
	xopad(c, (-len(auth.data)) & 3)

	if !x_read_at_least(w, 8) {
		return c.fatal != "" ? c.fatal : "the X server closed the connection without a setup reply"
	}
	status := c.rx[0]
	total := 8 + int(xr16(c.rx[:], 6)) * 4
	if !x_read_at_least(w, total) {
		return c.fatal != "" ? c.fatal : "the X server's setup reply was truncated"
	}
	body := c.rx[:total]

	switch status {
	case 0:
		n := int(xr8(body, 1))
		reason := string(body[8:min(8 + n, len(body))])
		if !w.x.authed {
			return fmt.tprintf(
				"the X server at %s refused the connection: %s (no MIT-MAGIC-COOKIE-1 entry for display %s was found in %s)",
				path,
				reason,
				num,
				xauth_path(context.temp_allocator),
			)
		}
		return fmt.tprintf("the X server at %s refused the connection: %s", path, reason)
	case 2:
		n := int(xr8(body, 1))
		return fmt.tprintf(
			"the X server at %s wants further authentication: %s",
			path,
			string(body[8:min(8 + n * 4, len(body))]),
		)
	case 1:
	// Success.
	case:
		return fmt.tprintf("the X server sent an unknown setup status %d", status)
	}

	x := &w.x
	x.id_base = xr32(body, 12)
	x.id_mask = xr32(body, 16)
	vendor_len := int(xr16(body, 24))
	max_words := int(xr16(body, 26))
	num_roots := int(xr8(body, 28))
	num_formats := int(xr8(body, 29))
	image_byte_order := xr8(body, 30)
	x.min_keycode = u32(xr8(body, 34))
	x.max_keycode = u32(xr8(body, 35))
	x.max_request = max_words * 4

	if image_byte_order != 0 {
		return "this X server stores images most-significant-byte first; palmy's rasterizer only produces little-endian BGRX words"
	}

	// The pixmap formats come first, then the screens.
	p := 40 + ((vendor_len + 3) & ~int(3))
	formats := p
	p += num_formats * 8

	if w.x.screen >= num_roots {
		return fmt.tprintf("DISPLAY asks for screen %d but the server has %d", w.x.screen, num_roots)
	}

	// Walk to the screen DISPLAY named: a SCREEN is variable length, because
	// its allowed depths and their visuals are inlined.
	depths_at := 0
	n_depths := 0
	for s in 0 ..< num_roots {
		if p + 40 > len(body) {
			return "the X server's setup reply ended inside its screen list"
		}
		if s == w.x.screen {
			x.root = xr32(body, p + 0)
			x.black_pixel = xr32(body, p + 12)
			x.screen_w = int(xr16(body, p + 20))
			x.screen_h = int(xr16(body, p + 22))
			x.root_visual = xr32(body, p + 32)
			x.root_depth = xr8(body, p + 38)
			n_depths = int(xr8(body, p + 39))
			depths_at = p + 40
		}
		d := int(xr8(body, p + 39))
		q := p + 40
		for _ in 0 ..< d {
			nv := int(xr16(body, q + 2))
			q += 8 + nv * 24
		}
		p = q
	}

	// The rasterizer writes one 32-bit word per pixel, so the server's format
	// for the root depth has to be 32 bits per pixel.
	bpp := u8(0)
	for i in 0 ..< num_formats {
		if xr8(body, formats + i * 8) == x.root_depth {
			bpp = xr8(body, formats + i * 8 + 1)
		}
	}
	if bpp != 32 {
		return fmt.tprintf(
			"the X server packs depth %d at %d bits per pixel; palmy needs 32 (a depth-24 or depth-32 TrueColor screen)",
			x.root_depth,
			bpp,
		)
	}

	// ...and the root visual has to put red, green and blue where the
	// rasterizer already puts them.
	found_visual := false
	q := depths_at
	for _ in 0 ..< n_depths {
		nv := int(xr16(body, q + 2))
		for v in 0 ..< nv {
			o := q + 8 + v * 24
			if xr32(body, o) != x.root_visual {
				continue
			}
			found_visual = true
			class := xr8(body, o + 4)
			red := xr32(body, o + 8)
			green := xr32(body, o + 12)
			blue := xr32(body, o + 16)
			if class != 4 && class != 5 {
				return "the root visual is not TrueColor; palmy does not do colormaps"
			}
			if red != 0x00ff0000 || green != 0x0000ff00 || blue != 0x000000ff {
				return fmt.tprintf(
					"the root visual's channel masks are r=%08x g=%08x b=%08x; palmy's buffers are 0xAARRGGBB",
					red,
					green,
					blue,
				)
			}
		}
		q += 8 + nv * 24
	}
	if !found_visual {
		return "the root visual is missing from the server's depth list"
	}

	// Consume the setup reply; everything after it is replies and events.
	remaining := len(c.rx) - total
	if remaining > 0 {
		copy(c.rx[:remaining], c.rx[total:])
	}
	resize(&c.rx, remaining)

	x_debug(
		w,
		"root=%x visual=%x depth=%d screen=%dx%d ids=%x/%x max_request=%d",
		x.root,
		x.root_visual,
		x.root_depth,
		x.screen_w,
		x.screen_h,
		x.id_base,
		x.id_mask,
		x.max_request,
	)
	return ""
}

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

// x_sync waits for the reply to one request. Events that arrive ahead of it
// are dispatched on the way past, so nothing is lost.
@(private)
x_sync :: proc(w: ^Window, seq: u32) -> (reply: []u8, ok: bool) {
	c := &w.conn
	x := &w.x
	x.want_seq = seq
	x.reply_done = false
	x.reply_ok = false
	clear(&x.reply)
	x.in_sync += 1
	defer x.in_sync -= 1

	conn_flush(c)
	deadline := time.time_add(time.now(), 5 * time.Second)
	for !x.reply_done {
		if c.fatal != "" {
			return nil, false
		}
		x_consume(w)
		if x.reply_done {
			break
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		cnt, perr := poll_fds(pfd[:], 200)
		if perr != .NONE && perr != .EINTR {
			c.fatal = fmt.tprintf("poll on the X server socket failed: %v", perr)
			return nil, false
		}
		if cnt > 0 && !conn_read(c) {
			return nil, false
		}
		if time.since(deadline) > 0 {
			c.fatal = fmt.tprintf("the X server never answered request %d", seq)
			return nil, false
		}
	}
	x.want_seq = 0
	return x.reply[:], x.reply_ok
}

// x_roundtrip is a no-op request whose reply proves the server has processed
// everything queued before it.
@(private)
x_roundtrip :: proc(w: ^Window) -> bool {
	s := x_begin(w, X_GET_INPUT_FOCUS)
	seq := x_end(w, s)
	_, ok := x_sync(w, seq)
	return ok
}

// x_consume walks every complete record in the receive buffer. A reply is 32
// bytes plus `length` words; an error and an event are always 32.
@(private)
x_consume :: proc(w: ^Window) {
	c := &w.conn
	x := &w.x
	at := 0
	for {
		avail := len(c.rx) - at
		if avail < 32 {
			break
		}
		rec := c.rx[at:]
		kind := rec[0]
		size := 32
		if kind == 1 || kind & 0x7f == X_GENERIC_EVENT {
			size = 32 + int(xr32(rec, 4)) * 4
		}
		if size > avail {
			break
		}
		seq := u32(xr16(rec, 2))

		switch {
		case kind == 1:
			if x.want_seq != 0 && seq == x.want_seq & 0xffff {
				resize(&x.reply, size)
				copy(x.reply[:], rec[:size])
				x.reply_ok = true
				x.reply_done = true
			}
		case kind == 0:
			code := xr8(rec, 1)
			if x.want_seq != 0 && seq == x.want_seq & 0xffff {
				x.reply_ok = false
				x.reply_done = true
			}
			x_debug(
				w,
				"error %d on request %d (major %d, minor %d, bad value %x)",
				code,
				seq,
				xr8(rec, 10),
				xr16(rec, 8),
				xr32(rec, 4),
			)
		case:
			n := x_event(w, c.rx[at:], avail)
			at += kind & 0x7f == X_GENERIC_EVENT ? size : n
			continue
		}
		at += size
	}

	if at > 0 {
		remaining := len(c.rx) - at
		if remaining > 0 {
			copy(c.rx[:remaining], c.rx[at:])
		}
		resize(&c.rx, remaining)
	}
}

// x_dispatch_pending is the event-loop entry point: drain the buffer, then run
// the work that could not be done from inside the dispatcher because it needs
// a reply of its own.
@(private)
x_dispatch_pending :: proc(w: ^Window) {
	x_consume(w)
	if w.x.in_sync > 0 {
		return
	}
	if w.x.remap {
		w.x.remap = false
		x_load_keymap(w)
	}
	if w.x.state_dirty {
		w.x.state_dirty = false
		x_refresh_wm_state(w)
	}
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

// x_event handles one event and returns how many bytes it consumed, which is
// 64 when it swallowed a release/press pair the server sent as auto-repeat.
@(private)
x_event :: proc(w: ^Window, rec: []u8, avail: int) -> int {
	x := &w.x
	in_ := &w.input
	kind := rec[0] & 0x7f

	switch int(kind) {
	case X_KEY_PRESS:
		w.clip.x_time = xr32(rec, 4)
		code := u32(xr8(rec, 1))
		in_.mods = keymap_x11_state(&w.keymap, u32(xr16(rec, 28)))
		repeat := x.repeat_pending == code || x_held(x, code)
		x.repeat_pending = 0
		x_hold(x, code, true)
		if code >= 8 {
			feed_key(w, code - 8, repeat)
		}
		w.input_dirty = true

	case X_KEY_RELEASE:
		code := u32(xr8(rec, 1))
		// X11 auto-repeat arrives as a release immediately followed by a
		// press with the same timestamp. palmy's own repeat timer is off on
		// this backend, so the pair is folded into one repeating press rather
		// than being delivered as a key that was let go and struck again.
		if avail >= 64 {
			nxt := rec[32:]
			if nxt[0] & 0x7f == X_KEY_PRESS &&
			   u32(xr8(nxt, 1)) == code &&
			   xr32(nxt, 4) == xr32(rec, 4) {
				x.repeat_pending = code
				x_event(w, rec[32:], avail - 32)
				return 64
			}
		}
		x_hold(x, code, false)
		in_.mods = keymap_x11_state(&w.keymap, u32(xr16(rec, 28)))
		w.input_dirty = true

	case X_BUTTON_PRESS:
		w.clip.x_time = xr32(rec, 4)
		btn := xr8(rec, 1)
		in_.mouse = {f32(xri16(rec, 24)), f32(xri16(rec, 26))}
		in_.mods = keymap_x11_state(&w.keymap, u32(xr16(rec, 28)))
		in_.over_surface = true
		switch btn {
		case 1, 2, 3:
			mb := x_button(btn)
			in_.button_at = in_.mouse
			in_.down[mb] = true
			in_.pressed[mb] = true
			in_.click_serial = u32(xr16(rec, 2))
		case 4:
			in_.scroll.y -= SCROLL_NOTCH
		case 5:
			in_.scroll.y += SCROLL_NOTCH
		case 6:
			in_.scroll.x -= SCROLL_NOTCH
		case 7:
			in_.scroll.x += SCROLL_NOTCH
		}
		w.input_dirty = true

	case X_BUTTON_RELEASE:
		btn := xr8(rec, 1)
		in_.mouse = {f32(xri16(rec, 24)), f32(xri16(rec, 26))}
		in_.mods = keymap_x11_state(&w.keymap, u32(xr16(rec, 28)))
		// A wheel notch is a press and a release; only the press carries it.
		if btn >= 1 && btn <= 3 {
			mb := x_button(btn)
			in_.button_at = in_.mouse
			in_.down[mb] = false
			in_.released[mb] = true
		}
		w.input_dirty = true

	case X_MOTION_NOTIFY:
		p := [2]f32{f32(xri16(rec, 24)), f32(xri16(rec, 26))}
		in_.mouse_delta += p - in_.mouse
		in_.mouse = p
		in_.over_surface = true
		w.input_dirty = true

	case X_ENTER_NOTIFY:
		in_.mouse = {f32(xri16(rec, 24)), f32(xri16(rec, 26))}
		in_.over_surface = true
		w.input_dirty = true

	case X_LEAVE_NOTIFY:
		in_.over_surface = false
		w.input_dirty = true

	case X_FOCUS_IN:
		in_.focused = true
		w.activated = true
		w.input_dirty = true

	case X_FOCUS_OUT:
		in_.focused = false
		w.activated = false
		in_.mods = {}
		x.held = {}
		w.input_dirty = true

	case X_EXPOSE:
		w.input_dirty = true

	case X_VISIBILITY_NOTIFY:
		// state: 0 Unobscured, 1 PartiallyObscured, 2 FullyObscured. Coming
		// back into view also brings Expose events; the frame is asked for
		// here as well so a server with backing store still gets the frame
		// the window owes it (see x_ready_for_pixels).
		was := x.obscured
		x.obscured = xr8(rec, 8) == 2
		if was && !x.obscured {
			w.input_dirty = true
		}

	case X_MAP_NOTIFY:
		x.mapped = true
		w.configured = true
		w.input_dirty = true

	case X_UNMAP_NOTIFY:
		// Iconified, on another desktop, or withdrawn: nothing of the window
		// is visible until MapNotify.
		x.mapped = false

	case X_DESTROY_NOTIFY:
		// Something destroyed the window out from under us — `xdotool
		// windowclose` and `xkill` both do. Without this the loop would keep
		// drawing into a drawable the server has forgotten.
		x.window = 0
		w.should_close = true
		w.input_dirty = true

	case X_CONFIGURE_NOTIFY:
		// This is the X11 resize path, and it lands in exactly the fields an
		// xdg_toplevel.configure would.
		cw := int(xr16(rec, 20))
		ch := int(xr16(rec, 22))
		if cw > 0 && ch > 0 && (cw != w.width || ch != w.height) {
			w.pending_width, w.pending_height = cw, ch
			w.input_dirty = true
		}
		w.configured = true

	case X_PROPERTY_NOTIFY:
		if xr32(rec, 8) == x.a_net_wm_state && x.a_net_wm_state != 0 {
			x.state_dirty = true
		}
		// The clipboard's INCR transfers, both ways.
		x_clip_property(w, rec)

	case X_CLIENT_MESSAGE:
		if xr32(rec, 8) == x.a_wm_protocols && xr32(rec, 12) == x.a_wm_delete {
			// Without WM_PROTOCOLS carrying WM_DELETE_WINDOW the window
			// manager would terminate the process instead of asking.
			w.should_close = true
			w.input_dirty = true
		}

	case X_SELECTION_CLEAR, X_SELECTION_REQUEST, X_SELECTION_NOTIFY:
		x_clip_event(w, rec)

	case X_MAPPING_NOTIFY:
		// Re-reading the mapping needs a reply, which cannot be waited for
		// from inside the dispatcher.
		x.remap = true

	case:
		if x_clip_xfixes_event(w, rec) {
			break
		}
		if int(kind) == int(x.shm_first_event) && x.shm_in_use {
			// ShmCompletion: the server has finished reading the buffer, which
			// is exactly what wl_buffer.release means on the other backend.
			off := int(xr32(rec, 16))
			for &b in w.buffers {
				if b.offset == off {
					b.busy = false
				}
			}
			w.frame_pending = false
			w.frame_ready = true
		}
	}
	return 32
}

@(private)
x_button :: proc(btn: u8) -> Mouse_Button {
	switch btn {
	case 2:
		return .Middle
	case 3:
		return .Right
	}
	return .Left
}

@(private)
x_held :: proc(x: ^X11_State, code: u32) -> bool {
	return code < 256 && x.held[code / 8] & (1 << (code % 8)) != 0
}

@(private)
x_hold :: proc(x: ^X11_State, code: u32, down: bool) {
	if code >= 256 {
		return
	}
	if down {
		x.held[code / 8] |= 1 << (code % 8)
	} else {
		x.held[code / 8] &= ~u8(1 << (code % 8))
	}
}

// ---------------------------------------------------------------------------
// Atoms and properties
// ---------------------------------------------------------------------------

@(private)
x_intern :: proc(w: ^Window, name: string) -> u32 {
	c := &w.conn
	s := x_begin(w, X_INTERN_ATOM, 0)
	xo16(c, u16(len(name)))
	xo16(c, 0)
	append(&c.out, name)
	seq := x_end(w, s)
	reply, ok := x_sync(w, seq)
	if !ok {
		return 0
	}
	return xr32(reply, 8)
}

@(private)
x_set_property :: proc(w: ^Window, prop, type: u32, format: u8, data: []u8) {
	c := &w.conn
	s := x_begin(w, X_CHANGE_PROPERTY, 0) // 0 = Replace
	xo32(c, w.x.window)
	xo32(c, prop)
	xo32(c, type)
	xo8(c, format)
	xopad(c, 3)
	units := len(data)
	switch format {
	case 16:
		units /= 2
	case 32:
		units /= 4
	}
	xo32(c, u32(units))
	append(&c.out, ..data)
	x_end(w, s)
}

@(private)
x_set_text_property :: proc(w: ^Window, prop, type: u32, text: string) {
	x_set_property(w, prop, type, 8, transmute([]u8)text)
}

@(private)
x_set_card32 :: proc(w: ^Window, prop, type: u32, values: []u32) {
	buf := make([]u8, len(values) * 4, context.temp_allocator)
	for v, i in values {
		b := transmute([4]u8)v
		copy(buf[i * 4:][:4], b[:])
	}
	x_set_property(w, prop, type, 32, buf)
}

// x_refresh_wm_state reads _NET_WM_STATE back so `is_maximized` and
// `is_fullscreen` report what the window manager actually did.
@(private)
x_refresh_wm_state :: proc(w: ^Window) {
	if w.x.a_net_wm_state == 0 {
		return
	}
	c := &w.conn
	s := x_begin(w, X_GET_PROPERTY, 0)
	xo32(c, w.x.window)
	xo32(c, w.x.a_net_wm_state)
	xo32(c, XA_ATOM)
	xo32(c, 0) // long-offset
	xo32(c, 64) // long-length
	seq := x_end(w, s)
	reply, ok := x_sync(w, seq)
	if !ok {
		return
	}
	n := int(xr32(reply, 16))
	w.maximized, w.fullscreen = false, false
	vert, horz := false, false
	for i in 0 ..< n {
		a := xr32(reply, 32 + i * 4)
		switch a {
		case w.x.a_fullscreen:
			w.fullscreen = true
		case w.x.a_max_vert:
			vert = true
		case w.x.a_max_horz:
			horz = true
		}
	}
	w.maximized = vert && horz
	w.input_dirty = true
}

// ---------------------------------------------------------------------------
// The keyboard
// ---------------------------------------------------------------------------

@(private)
x_load_keymap :: proc(w: ^Window) {
	c := &w.conn
	x := &w.x

	count := int(x.max_keycode - x.min_keycode + 1)
	if count <= 0 || count > 256 {
		return
	}

	s := x_begin(w, X_GET_KEYBOARD_MAPPING, 0)
	xo8(c, u8(x.min_keycode))
	xo8(c, u8(count))
	xo16(c, 0)
	seq := x_end(w, s)
	reply, ok := x_sync(w, seq)
	if ok {
		per := int(xr8(reply, 1))
		total := int(xr32(reply, 4))
		if per > 0 && total > 0 && 32 + total * 4 <= len(reply) {
			syms := make([]u32, total, context.temp_allocator)
			for i in 0 ..< total {
				syms[i] = xr32(reply, 32 + i * 4)
			}
			keymap_set_x11(&w.keymap, x.min_keycode, per, syms)
			x_debug(w, "keyboard mapping: %d keycodes x %d levels", count, per)
		}
	}

	// GetModifierMapping says which of the eight modifiers the server bound
	// Alt, Super and the level-3 shift to; Shift, Lock and Control are fixed.
	s2 := x_begin(w, X_GET_MODIFIER_MAPPING, 0)
	seq2 := x_end(w, s2)
	reply2, ok2 := x_sync(w, seq2)
	if !ok2 {
		return
	}
	per_mod := int(xr8(reply2, 1))
	alt, super, level3: u32
	for m in 0 ..< 8 {
		mask := u32(1) << u32(m)
		for i in 0 ..< per_mod {
			kc := u32(xr8(reply2, 32 + m * per_mod + i))
			if kc == 0 {
				continue
			}
			sym := x_first_sym(&w.keymap, kc)
			switch sym {
			case XK_ALT_L, XK_ALT_R, XK_META_L, XK_META_R:
				if alt == 0 {
					alt = mask
				}
			case XK_SUPER_L, XK_SUPER_R, XK_HYPER_L:
				if super == 0 {
					super = mask
				}
			case XK_MODE_SWITCH, XK_ISO_LEVEL3_SHIFT:
				if level3 == 0 {
					level3 = mask
				}
			}
		}
	}
	// Mod1 and Mod4 are where Alt and Super sit on every desktop Linux
	// keyboard; fall back to them if the map named neither.
	if alt == 0 {
		alt = 1 << 3
	}
	if super == 0 {
		super = 1 << 6
	}
	keymap_set_x11_mods(&w.keymap, alt, super, level3)
	x_debug(w, "modifiers: alt=%x super=%x level3=%x", alt, super, level3)
}

// x_first_sym is the unshifted keysym of an X11 keycode, used while reading the
// modifier map.
@(private)
x_first_sym :: proc(k: ^Keymap, keycode: u32) -> u32 {
	if k.x_per <= 0 || keycode < k.x_first {
		return 0
	}
	row := int(keycode - k.x_first) * k.x_per
	if row >= len(k.x_syms) {
		return 0
	}
	return k.x_syms[row]
}

// ---------------------------------------------------------------------------
// Opening the window
// ---------------------------------------------------------------------------

// x_open connects, creates the window, tells the window manager about it and
// waits for it to be mapped.
//
// `decorate` has no counterpart here and is deliberately ignored. On Wayland a
// client has to ask for server-side decorations because the default is to draw
// its own; on X11 the window manager decorates unless a client opts out with
// _MOTIF_WM_HINTS, so the default already is what `decorate = true` means and
// there is nothing to request.
@(private)
x_open :: proc(w: ^Window, decorate: bool) -> (err: string) {
	w.x.debug = os.get_env("PALMY_X11_DEBUG", context.temp_allocator) != ""
	w.x.reply = make([dynamic]u8, 0, 1024)

	if w.use_layer {
		return "a layer surface needs wlr-layer-shell, which X11 has no equivalent of; run this on a Wayland compositor, or open an ordinary window instead"
	}

	if e := x_connect(w); e != "" {
		return e
	}
	c := &w.conn
	x := &w.x

	// MIT-SHM, asked for rather than assumed.
	{
		s := x_begin(w, X_QUERY_EXTENSION, 0)
		name := "MIT-SHM"
		xo16(c, u16(len(name)))
		xo16(c, 0)
		append(&c.out, name)
		seq := x_end(w, s)
		forced_off := os.get_env("PALMY_X11_NO_SHM", context.temp_allocator) != ""
		if reply, ok := x_sync(w, seq); ok && xr8(reply, 8) != 0 && !forced_off {
			x.shm_major = xr8(reply, 9)
			x.shm_first_event = xr8(reply, 10)

			s2 := x_begin(w, x.shm_major, SHM_QUERY_VERSION)
			seq2 := x_end(w, s2)
			if v, vok := x_sync(w, seq2); vok {
				x.shm_present = true
				x_debug(
					w,
					"MIT-SHM %d.%d, major=%d first_event=%d",
					xr16(v, 8),
					xr16(v, 10),
					x.shm_major,
					x.shm_first_event,
				)
			}
		} else {
			x_debug(
				w,
				"%s; falling back to PutImage",
				forced_off ? "MIT-SHM disabled by PALMY_X11_NO_SHM" : "no MIT-SHM",
			)
		}
	}

	x.a_wm_protocols = x_intern(w, "WM_PROTOCOLS")
	x.a_wm_delete = x_intern(w, "WM_DELETE_WINDOW")
	x.a_net_wm_name = x_intern(w, "_NET_WM_NAME")
	x.a_utf8_string = x_intern(w, "UTF8_STRING")
	x.a_net_wm_state = x_intern(w, "_NET_WM_STATE")
	x.a_fullscreen = x_intern(w, "_NET_WM_STATE_FULLSCREEN")
	x.a_max_vert = x_intern(w, "_NET_WM_STATE_MAXIMIZED_VERT")
	x.a_max_horz = x_intern(w, "_NET_WM_STATE_MAXIMIZED_HORZ")
	x.a_net_wm_pid = x_intern(w, "_NET_WM_PID")
	x_clip_init(w)

	x.window = x_new_id(w)
	{
		s := x_begin(w, X_CREATE_WINDOW, x.root_depth)
		xo32(c, x.window)
		xo32(c, x.root)
		xo16(c, 0) // x
		xo16(c, 0) // y
		xo16(c, u16(w.width))
		xo16(c, u16(w.height))
		xo16(c, 0) // border width
		xo16(c, 1) // InputOutput
		xo32(c, x.root_visual)
		xo32(c, CW_BACK_PIXEL | CW_BIT_GRAVITY | CW_EVENT_MASK)
		xo32(c, x.black_pixel)
		xo32(c, 1) // NorthWestGravity, so a resize keeps the top-left
		xo32(c, X_EVENT_MASK)
		x_end(w, s)
	}

	// The properties a window manager reads. WM_CLASS is instance then class,
	// each NUL-terminated, and carries the same app id the Wayland side sets
	// with xdg_toplevel.set_app_id.
	x_set_text_property(w, XA_WM_NAME, XA_STRING, w.title)
	if x.a_net_wm_name != 0 && x.a_utf8_string != 0 {
		x_set_text_property(w, x.a_net_wm_name, x.a_utf8_string, w.title)
	}
	{
		cls := strings.concatenate({w.app_id, "\x00", w.app_id, "\x00"}, context.temp_allocator)
		x_set_text_property(w, XA_WM_CLASS, XA_STRING, cls)
	}
	if x.a_wm_protocols != 0 && x.a_wm_delete != 0 {
		x_set_card32(w, x.a_wm_protocols, XA_ATOM, []u32{x.a_wm_delete})
	}
	if x.a_net_wm_pid != 0 {
		x_set_card32(w, x.a_net_wm_pid, XA_CARDINAL, []u32{u32(linux.getpid())})
	}

	x.gc = x_new_id(w)
	{
		s := x_begin(w, X_CREATE_GC, 0)
		xo32(c, x.gc)
		xo32(c, x.window)
		xo32(c, 0x10000) // graphics-exposures
		xo32(c, 0) // off: a full-surface PutImage never needs them
		x_end(w, s)
	}

	{
		s := x_begin(w, X_MAP_WINDOW, 0)
		xo32(c, x.window)
		x_end(w, s)
	}
	conn_flush(c)

	x_load_keymap(w)

	// Wait for the window to be on screen. Without a window manager MapNotify
	// is all that arrives; with one, a ConfigureNotify usually precedes it and
	// may well have changed the size we asked for.
	deadline := time.time_add(time.now(), 2 * time.Second)
	for !x.mapped {
		if !window_wait(w, 100) {
			return c.fatal != "" ? c.fatal : "the X server never mapped the window"
		}
		if time.since(deadline) > 0 {
			return "timed out waiting for the window to be mapped"
		}
	}
	w.configured = true
	return ""
}

@(private)
x_close :: proc(w: ^Window) {
	c := &w.conn
	x_destroy_buffers(w)
	if w.x.window != 0 {
		s := x_begin(w, 4, 0) // DestroyWindow
		xo32(c, w.x.window)
		x_end(w, s)
		w.x.window = 0
	}
	conn_flush(c)
	delete(w.x.reply)
	delete(w.x.display)
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

// SysV shared memory, which is what MIT-SHM's ShmAttach takes. The FD-passing
// variant needs MIT-SHM 1.2 and is not universal, so this takes the path every
// server supports.
@(private)
shmget :: proc(size: int, flags: int) -> int {
	return linux.syscall(linux.SYS_shmget, IPC_PRIVATE, size, flags)
}

@(private)
shmat :: proc(id: int) -> rawptr {
	r := linux.syscall(linux.SYS_shmat, id, uintptr(0), 0)
	if r < 0 && r > -4096 {
		return nil
	}
	return rawptr(uintptr(r))
}

@(private)
shmdt :: proc(p: rawptr) {
	linux.syscall(linux.SYS_shmdt, p)
}

@(private)
shmrmid :: proc(id: int) {
	linux.syscall(linux.SYS_shmctl, id, IPC_RMID, uintptr(0))
}

@(private)
x_destroy_buffers :: proc(w: ^Window) {
	c := &w.conn
	x := &w.x

	if x.shm_in_use {
		if x.shm_seg != 0 {
			s := x_begin(w, x.shm_major, SHM_DETACH)
			xo32(c, x.shm_seg)
			x_end(w, s)
			x.shm_seg = 0
		}
		if x.shm_mem != nil {
			shmdt(raw_data(x.shm_mem))
			x.shm_mem = nil
		}
		x.shm_id = 0
		x.shm_in_use = false
	}
	if x.soft_mem != nil {
		delete(x.soft_mem)
		x.soft_mem = nil
	}
	for &b in w.buffers {
		b = {}
	}
	// Any ShmPutImage still in flight pointed at the segment just detached, so
	// its completion event will never arrive for these buffers.
	w.frame_pending = false
}

@(private)
x_alloc_buffers :: proc(w: ^Window) -> (err: string) {
	x_destroy_buffers(w)
	c := &w.conn
	x := &w.x

	dw := w.width * w.scale
	dh := w.height * w.scale
	frame := dw * dh * 4
	total := frame * 2
	if dw <= 0 || dh <= 0 {
		return "the window has no area to draw into"
	}

	if x.shm_present {
		id := shmget(total, IPC_CREAT | 0o600)
		if id >= 0 {
			if mem := shmat(id); mem != nil {
				x.shm_id = id
				x.shm_mem = ([^]u8)(mem)[:total]
				x.shm_size = total
				x.shm_seg = x_new_id(w)

				s := x_begin(w, x.shm_major, SHM_ATTACH)
				xo32(c, x.shm_seg)
				xo32(c, u32(id))
				xo8(c, 0) // not read-only: the server only reads, but a
				// writable segment is what every toolkit attaches
				xopad(c, 3)
				x_end(w, s)

				// The segment can only be released once the server holds its
				// own attachment, so prove that before marking it for
				// destruction. After this the kernel reclaims it when the last
				// process detaches, even if palmy crashes.
				if x_roundtrip(w) {
					shmrmid(id)
					x.shm_in_use = true
				} else {
					shmdt(mem)
					shmrmid(id)
					x.shm_mem = nil
					x.shm_seg = 0
					x_debug(w, "ShmAttach was refused; falling back to PutImage")
				}
			} else {
				shmrmid(id)
			}
		}
		if !x.shm_in_use {
			// Containers and hardened kernels can switch SysV shm off; that is
			// a reason to go slower, not to fail.
			x.shm_present = false
		}
	}

	if x.shm_in_use {
		for i in 0 ..< 2 {
			b := &w.buffers[i]
			b.offset = frame * i
			b.w, b.h = dw, dh
			b.busy = false
			b.px = (([^]u32)(raw_data(x.shm_mem[b.offset:])))[:dw * dh]
		}
	} else {
		x.soft_mem = make([]u32, dw * dh * 2)
		for i in 0 ..< 2 {
			b := &w.buffers[i]
			b.offset = frame * i
			b.w, b.h = dw, dh
			b.busy = false
			b.px = x.soft_mem[dw * dh * i:][:dw * dh]
		}
	}
	x_debug(w, "buffers: %dx%d, shm=%v", dw, dh, x.shm_in_use)
	return ""
}

@(private)
x_present :: proc(w: ^Window, b: ^Shm_Buffer) {
	c := &w.conn
	x := &w.x
	if x.window == 0 || b.px == nil {
		return
	}

	if x.shm_in_use {
		s := x_begin(w, x.shm_major, SHM_PUT_IMAGE)
		xo32(c, x.window)
		xo32(c, x.gc)
		xo16(c, u16(b.w)) // total width
		xo16(c, u16(b.h)) // total height
		xo16(c, 0) // src-x
		xo16(c, 0) // src-y
		xo16(c, u16(b.w))
		xo16(c, u16(b.h))
		xo16(c, 0) // dst-x
		xo16(c, 0) // dst-y
		xo8(c, x.root_depth)
		xo8(c, X_ZPIXMAP)
		xo8(c, 1) // send_event: the completion event frees the buffer again
		xopad(c, 1)
		xo32(c, x.shm_seg)
		xo32(c, u32(b.offset))
		x_end(w, s)
		b.busy = true
		w.frame_pending = true
		conn_flush(c)
		return
	}

	// PutImage carries the pixels inside the request, so it has to be chunked
	// to the server's maximum-request-length. The header is 24 bytes.
	stride := b.w * 4
	limit := x.max_request - 24
	rows := max(limit / max(stride, 1), 1)
	y := 0
	for y < b.h {
		n := min(rows, b.h - y)
		s := x_begin(w, X_PUT_IMAGE, X_ZPIXMAP)
		xo32(c, x.window)
		xo32(c, x.gc)
		xo16(c, u16(b.w))
		xo16(c, u16(n))
		xo16(c, 0) // dst-x
		xo16(c, u16(y)) // dst-y
		xo8(c, 0) // left-pad, which must be 0 for ZPixmap
		xo8(c, x.root_depth)
		xopad(c, 2)
		bytes := (transmute([^]u8)raw_data(b.px[y * b.w:]))[:n * stride]
		append(&c.out, ..bytes)
		x_end(w, s)
		conn_flush(c)
		y += n
	}
	w.frame_pending = false
	w.frame_ready = true
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
x_set_title :: proc(w: ^Window) {
	if w.x.window == 0 {
		return
	}
	x_set_text_property(w, XA_WM_NAME, XA_STRING, w.title)
	if w.x.a_net_wm_name != 0 && w.x.a_utf8_string != 0 {
		x_set_text_property(w, w.x.a_net_wm_name, w.x.a_utf8_string, w.title)
	}
	conn_flush(&w.conn)
}

// x_set_min_size writes WM_NORMAL_HINTS, the 18-word ICCCM size-hints
// structure. PMinSize is bit 4.
@(private)
x_set_min_size :: proc(w: ^Window, width, height: int) {
	if w.x.window == 0 {
		return
	}
	hints: [18]u32
	hints[0] = 1 << 4 // PMinSize
	hints[5] = u32(max(width, 1))
	hints[6] = u32(max(height, 1))
	x_set_card32(w, XA_WM_NORMAL_HINTS, XA_WM_SIZE_HINTS, hints[:])
	conn_flush(&w.conn)
}

// x_set_fullscreen asks the window manager through _NET_WM_STATE, which is how
// EWMH says a client requests it. With no window manager running there is
// nobody to ask and nothing happens, which is the honest outcome.
@(private)
x_set_fullscreen :: proc(w: ^Window, on: bool) {
	x := &w.x
	if x.window == 0 || x.a_net_wm_state == 0 || x.a_fullscreen == 0 {
		return
	}
	c := &w.conn
	s := x_begin(w, X_SEND_EVENT, 0) // propagate = false
	xo32(c, x.root)
	xo32(c, 0x80000 | 0x100000) // SubstructureNotify | SubstructureRedirect
	// A 32-byte ClientMessage, built by hand.
	xo8(c, X_CLIENT_MESSAGE)
	xo8(c, 32) // format
	xo16(c, 0) // sequence, filled in by the server
	xo32(c, x.window)
	xo32(c, x.a_net_wm_state)
	xo32(c, on ? 1 : 0) // _NET_WM_STATE_ADD / _REMOVE
	xo32(c, x.a_fullscreen)
	xo32(c, 0)
	xo32(c, 1) // source: a normal application
	xo32(c, 0)
	x_end(w, s)
	conn_flush(c)
}

// x_set_cursor uses the standard "cursor" font, which is the core protocol's
// only cursor source and is present on every server.
@(private)
x_set_cursor :: proc(w: ^Window, want: Cursor) {
	x := &w.x
	if x.window == 0 || w.cursor_shape == want {
		return
	}
	w.cursor_shape = want
	c := &w.conn

	if x.cursors[want] == 0 {
		if x.cursor_font == 0 {
			x.cursor_font = x_new_id(w)
			s := x_begin(w, X_OPEN_FONT, 0)
			xo32(c, x.cursor_font)
			name := "cursor"
			xo16(c, u16(len(name)))
			xo16(c, 0)
			append(&c.out, name)
			x_end(w, s)
		}
		glyph := x_cursor_glyph(want)
		id := x_new_id(w)
		s := x_begin(w, X_CREATE_GLYPH_CURSOR, 0)
		xo32(c, id)
		xo32(c, x.cursor_font) // source font
		xo32(c, x.cursor_font) // mask font
		xo16(c, glyph)
		xo16(c, glyph + 1) // the mask glyph always follows the shape
		xo16(c, 0)
		xo16(c, 0)
		xo16(c, 0) // foreground: black
		xo16(c, 0xffff)
		xo16(c, 0xffff)
		xo16(c, 0xffff) // background: white
		x_end(w, s)
		x.cursors[want] = id
	}

	s := x_begin(w, X_CHANGE_WINDOW_ATTRIBUTES, 0)
	xo32(c, x.window)
	xo32(c, CW_CURSOR)
	xo32(c, x.cursors[want])
	x_end(w, s)
}

// x_cursor_glyph maps palmy's cursors onto cursorfont.h glyph indices.
@(private)
x_cursor_glyph :: proc(c: Cursor) -> u16 {
	switch c {
	case .Pointer:
		return 60 // XC_hand2
	case .Text:
		return 152 // XC_xterm
	case .Crosshair:
		return 34 // XC_crosshair
	case .Move:
		return 52 // XC_fleur
	case .Wait, .Progress:
		return 150 // XC_watch
	case .Help:
		return 92 // XC_question_arrow
	case .Not_Allowed:
		return 0 // XC_X_cursor
	case .Grab, .Grabbing:
		return 58 // XC_hand1
	case .Col_Resize:
		return 108 // XC_sb_h_double_arrow
	case .Row_Resize:
		return 116 // XC_sb_v_double_arrow
	case .Default, .Inherit:
		return 68 // XC_left_ptr
	}
	return 68
}
