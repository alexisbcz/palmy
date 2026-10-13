// The object model and the request handlers: wl_display, wl_registry,
// wl_compositor, wl_shm, wl_surface, wl_seat and xdg-shell, implemented
// server side.
package wm

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

VERBOSE := false

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

Kind :: enum u8 {
	None,
	Display,
	Registry,
	Callback,
	Compositor,
	Shm,
	Pool,
	Buffer,
	Surface,
	Region,
	Wm_Base,
	Positioner,
	Xdg_Surface,
	Toplevel,
	Seat,
	Pointer,
	Keyboard,
	Touch,
	Output,
	Subcompositor,
	Subsurface,
	Decor_Mgr,
	Decoration,
	Data_Mgr,
	Data_Device,
	Data_Source,
	Data_Offer,
	// Every zwp_primary_selection_* object shares this kind and
	// discriminates on Prim_Obj.role. See clipboard.odin.
	Prim,

	// wlr-layer-shell, ext-session-lock, xdg-output and the smaller globals a
	// desktop session is actually built out of. See layer.odin, lock.odin and
	// output.odin.
	Layer_Shell,
	Layer_Surface,
	Lock_Mgr,
	Lock,
	Lock_Surface,
	Xdg_Output_Mgr,
	Xdg_Output,
	Viewporter,
	Viewport,
	Frac_Mgr,
	Frac_Scale,
	Activation,
	Act_Token,
	Relp_Mgr,
	Relp,
	Pconstraints,
	Locked_Pointer,
	Confined_Pointer,
	Idle_Mgr,
	Idle_Inhibitor,
}

Object :: struct {
	kind: Kind,
	ver:  u32,
	p:    rawptr,
}

Pool :: struct {
	client: ^Client,
	id:     u32,
	fd:     linux.Fd,
	mem:    []u8,
	refs:   int, // live wl_buffers plus one while the pool itself is alive
	zombie: bool,
}

Buffer :: struct {
	client:               ^Client,
	id:                   u32,
	pool:                 ^Pool,
	offset, w, h, stride: int,
	format:               u32,
	destroyed:            bool,
}

Surface_Role :: enum u8 {
	None,
	Xdg,
	Sub,
	Layer,
	Lock,
}

// How many damage rectangles we keep per surface before collapsing them into
// one bounding box. Sixteen covers a text caret, a scrolled region and a few
// dirty widgets; past that the union is cheaper than the bookkeeping.
DMG_MAX :: 16

Surface :: struct {
	client:       ^Client,
	id:           u32,

	// Double-buffered state, applied on commit.
	p_buffer:     ^Buffer,
	p_buffer_set: bool,
	p_scale:      int,
	p_frames:     [dynamic]u32,

	// Current state. `img` is our own copy of the client's pixels in
	// 0xAARRGGBB, so the client's buffer can be released straight away.
	img:          []u32,
	iw, ih:       int,
	scale:        int,
	opaque:       bool,
	frames:       [dynamic]u32,
	entered:      bool,

	role:         Surface_Role,
	xdg:          ^Xdg_Surface,

	// Subsurface state.
	parent:       ^Surface,
	sub_id:       u32,
	sx, sy:       int,
	children:     [dynamic]^Surface,

	// The other two roles a surface can take.
	layer:        ^Layer_Surface,
	lock:         ^Lock_Surface,

	// Accumulated damage in surface-local pixels, so the compositing loop can
	// repaint only what changed. Fixed arrays rather than slices: a surface is
	// freed in three different places and none of them should have to learn
	// about another allocation.
	p_dmg:        [DMG_MAX][4]int,
	p_dmg_n:      int,
	p_dmg_full:   bool,
	dmg:          [DMG_MAX][4]int,
	dmg_n:        int,
	dmg_full:     bool,

	// wp_viewport: a crop and a resample, applied when the client's pixels are
	// copied out of its buffer.
	vp_obj:       u32,
	vp_src:       [4]f32,
	vp_src_set:   bool,
	vp_dst:       [2]int,
	vp_dst_set:   bool,
	frac_obj:     u32,
}

Xdg_Surface :: struct {
	client:       ^Client,
	id:           u32,
	surf:         ^Surface,
	top:          ^Toplevel,
	initial_sent: bool,
	serial:       u32,
	acked:        u32,
	geom_set:     bool,
	gx, gy:       int,
	gw, gh:       int,
}

Toplevel :: struct {
	client:             ^Client,
	id:                 u32,
	xdg:                ^Xdg_Surface,
	title:              string,
	app_id:             string,

	// Content rectangle in compositor pixels. The title bar sits above it.
	x, y:               int,
	w, h:               int,
	req_w, req_h:       int,
	min_w, min_h:       int,
	max_w, max_h:       int,

	mapped:             bool,
	activated:          bool,
	maximized:          bool,
	minimized:          bool,
	saved:              [4]int,
	decoration:         u32,

	// While resizing from a left or top edge the opposite edge is the anchor,
	// so x/y follow whatever size the client actually commits.
	anchor_right:       int,
	anchor_bottom:      int,
	anchor_x:           bool,
	anchor_y:           bool,
	resizing:           bool,
	last_cfg_w:         int,
	last_cfg_h:         int,
}

Client :: struct {
	fd:         linux.Fd,
	index:      int,
	dead:       bool,
	out:        [dynamic]u8,
	out_fds:    [dynamic]linux.Fd,
	rx:         [dynamic]u8,
	rx_fds:     [dynamic]linux.Fd,
	objs:       map[u32]Object,
	next_sid:   u32,

	// Seat objects, so input can be routed without a search.
	pointers:   [dynamic]u32,
	keyboards:  [dynamic]u32,
	wm_bases:   [dynamic]u32,
	data_devices: [dynamic]u32,
	pid:        int,
}

Global :: struct {
	name:  u32,
	iface: string,
	ver:   u32,
}

// The singleton globals. wl_output is no longer among them: there is one per
// head and the list is hot-pluggable, so output.odin advertises those itself
// out of a separate name range (OUT_GLOBAL_BASE and up).
GLOBALS := [?]Global {
	{1, "wl_compositor", 5},
	{2, "wl_shm", 1},
	{3, "wl_seat", 5},
	{5, "xdg_wm_base", 3},
	{6, "wl_subcompositor", 1},
	{7, "zxdg_decoration_manager_v1", 1},
	{8, "wl_data_device_manager", 3},
	{9, "zwp_primary_selection_device_manager_v1", 1},
	{10, "zwlr_layer_shell_v1", 4},
	{11, "ext_session_lock_manager_v1", 1},
	{12, "zxdg_output_manager_v1", 3},
	{13, "wp_viewporter", 1},
	{14, "wp_fractional_scale_manager_v1", 1},
	{15, "xdg_activation_v1", 1},
	{16, "zwp_relative_pointer_manager_v1", 1},
	{17, "zwp_pointer_constraints_v1", 1},
	{18, "zwp_idle_inhibit_manager_v1", 1},
}

// ---------------------------------------------------------------------------
// Object table helpers
// ---------------------------------------------------------------------------

obj_get :: proc(c: ^Client, id: u32) -> (Object, bool) {
	o, ok := c.objs[id]
	return o, ok
}

// obj_new records a client-allocated id. The id space is split: anything the
// client sends us must be below SERVER_ID_BASE.
obj_new :: proc(c: ^Client, id: u32, kind: Kind, ver: u32, p: rawptr) -> bool {
	if id == 0 || id >= SERVER_ID_BASE {
		post_error(c, DISPLAY_ID, 0, fmt.tprintf("object id %d is outside the client id range", id))
		return false
	}
	if _, taken := c.objs[id]; taken {
		post_error(c, DISPLAY_ID, 0, fmt.tprintf("object id %d is already in use", id))
		return false
	}
	c.objs[id] = Object{kind = kind, ver = ver, p = p}
	return true
}

// obj_drop removes an object and tells the client its id may be reused. The
// protocol only allows reuse after wl_display.delete_id, so every destruction
// has to be acknowledged.
obj_drop :: proc(c: ^Client, id: u32) {
	if _, ok := c.objs[id]; !ok {
		return
	}
	delete_key(&c.objs, id)
	event(c, DISPLAY_ID, 1, id)
}

server_id :: proc(c: ^Client) -> u32 {
	if c.next_sid == 0 {
		c.next_sid = SERVER_ID_BASE
	}
	id := c.next_sid
	c.next_sid += 1
	return id
}

next_serial :: proc(s: ^Server) -> u32 {
	s.serial += 1
	return s.serial
}

now_ms :: proc() -> u32 {
	return u32(time.duration_milliseconds(time.diff(start_time, time.now())))
}

start_time: time.Time

// ---------------------------------------------------------------------------
// Request dispatch
// ---------------------------------------------------------------------------

handle_request :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	o, ok := obj_get(c, id)
	if !ok {
		post_error(c, id, 0, fmt.tprintf("request %d on unknown object %d", op, id))
		return
	}

	switch o.kind {
	case .None:
	case .Display:
		req_display(s, c, id, op, r)
	case .Registry:
		req_registry(s, c, id, op, r)
	case .Callback:
	case .Compositor:
		req_compositor(s, c, o, id, op, r)
	case .Shm:
		req_shm(s, c, id, op, r)
	case .Pool:
		req_pool(s, c, o, id, op, r)
	case .Buffer:
		if op == 0 {
			buffer_destroy(c, o, id)
		}
	case .Surface:
		req_surface(s, c, o, id, op, r)
	case .Region:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Wm_Base:
		req_wm_base(s, c, o, id, op, r)
	case .Positioner:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Xdg_Surface:
		req_xdg_surface(s, c, o, id, op, r)
	case .Toplevel:
		req_toplevel(s, c, o, id, op, r)
	case .Seat:
		req_seat(s, c, o, id, op, r)
	case .Pointer:
		switch op {
		case 0:
			// set_cursor: the host draws the pointer, so the client's cursor
			// surface is accepted and ignored.
			r_u32(r);r_u32(r);r_i32(r);r_i32(r)
		case 1:
			pointer_gone(s, c, id)
			obj_drop(c, id)
		}
	case .Keyboard:
		if op == 0 {
			keyboard_gone(s, c, id)
			obj_drop(c, id)
		}
	case .Touch:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Output:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Subcompositor:
		req_subcompositor(s, c, id, op, r)
	case .Subsurface:
		req_subsurface(s, c, o, id, op, r)
	case .Decor_Mgr:
		req_decor_mgr(s, c, id, op, r)
	case .Data_Mgr:
		req_data_mgr(s, c, o, id, op, r)
	case .Data_Device:
		req_data_device(s, c, o, id, op, r)
	case .Data_Source:
		req_data_source(s, c, o, id, op, r)
	case .Data_Offer:
		req_data_offer(s, c, o, id, op, r)
	case .Prim:
		req_prim(s, c, o, id, op, r)
	case .Layer_Shell:
		req_layer_shell(s, c, o, id, op, r)
	case .Layer_Surface:
		req_layer_surface(s, c, o, id, op, r)
	case .Lock_Mgr:
		req_lock_mgr(s, c, o, id, op, r)
	case .Lock:
		req_lock(s, c, o, id, op, r)
	case .Lock_Surface:
		req_lock_surface(s, c, o, id, op, r)
	case .Xdg_Output_Mgr:
		req_out_xdg_mgr(s, c, o, id, op, r)
	case .Xdg_Output:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Viewporter:
		req_out_viewporter(s, c, o, id, op, r)
	case .Viewport:
		req_out_viewport(s, c, o, id, op, r)
	case .Frac_Mgr:
		req_out_frac_mgr(s, c, o, id, op, r)
	case .Frac_Scale:
		if op == 0 {
			if surf := (^Surface)(o.p); surf != nil {
				surf.frac_obj = 0
			}
			obj_drop(c, id)
		}
	case .Activation:
		req_activation(s, c, o, id, op, r)
	case .Act_Token:
		req_act_token(s, c, o, id, op, r)
	case .Relp_Mgr:
		req_relp_mgr(s, c, o, id, op, r)
	case .Relp:
		if op == 0 {
			obj_drop(c, id)
		}
	case .Pconstraints:
		req_pconstraints(s, c, o, id, op, r)
	case .Locked_Pointer, .Confined_Pointer:
		req_pconstraint(s, c, o, id, op, r)
	case .Idle_Mgr:
		req_lock_idle_mgr(s, c, o, id, op, r)
	case .Idle_Inhibitor:
		req_lock_idle_inhibitor(s, c, o, id, op, r)
	case .Decoration:
		switch op {
		case 0:
			obj_drop(c, id)
		case 1, 2:
			if op == 1 {r_u32(r)}
			event(c, id, 0, u32(2)) // always server_side: we draw the frames
		}
	}

	if r.bad {
		post_error(c, id, 0, fmt.tprintf("truncated request %d", op))
	}
}

// --- wl_display -------------------------------------------------------------

req_display :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// sync(callback)
		cb := r_u32(r)
		if !obj_new(c, cb, .Callback, 1, nil) {
			return
		}
		event(c, cb, 0, next_serial(s))
		obj_drop(c, cb)
	case 1:
		// get_registry(registry)
		reg := r_u32(r)
		if !obj_new(c, reg, .Registry, 1, nil) {
			return
		}
		out_sync(s)
		for g in GLOBALS {
			event(c, reg, 0, g.name, g.iface, g.ver)
		}
		out_send_globals(c, reg)
	}
}

// --- wl_registry ------------------------------------------------------------

req_registry :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	if op != 0 {
		return
	}
	name := r_u32(r)
	iface := r_string(r)
	ver := r_u32(r)
	new := r_u32(r)
	if r.bad {
		return
	}

	for g in GLOBALS {
		if g.name != name {
			continue
		}
		if iface != g.iface {
			post_error(c, id, 2, fmt.tprintf("global %d is %s, not %s", name, g.iface, iface))
			return
		}
		v := min(ver, g.ver)
		if v == 0 {
			v = 1
		}
		switch g.iface {
		case "wl_compositor":
			obj_new(c, new, .Compositor, v, nil)
		case "wl_shm":
			if obj_new(c, new, .Shm, v, nil) {
				event(c, new, 0, u32(0)) // argb8888
				event(c, new, 0, u32(1)) // xrgb8888
			}
		case "wl_seat":
			if obj_new(c, new, .Seat, v, nil) {
				event(c, new, 0, wltouch_caps())
				if v >= 2 {
					event(c, new, 1, "seat0")
				}
			}
		case "xdg_wm_base":
			if obj_new(c, new, .Wm_Base, v, nil) {
				append(&c.wm_bases, new)
			}
		case "wl_subcompositor":
			obj_new(c, new, .Subcompositor, v, nil)
		case "zxdg_decoration_manager_v1":
			obj_new(c, new, .Decor_Mgr, v, nil)
		case "wl_data_device_manager":
			obj_new(c, new, .Data_Mgr, v, nil)
		case "zwp_primary_selection_device_manager_v1":
			prim_bind(c, new, v)
		case "zwlr_layer_shell_v1":
			obj_new(c, new, .Layer_Shell, v, nil)
		case "ext_session_lock_manager_v1":
			obj_new(c, new, .Lock_Mgr, v, nil)
		case "zxdg_output_manager_v1":
			obj_new(c, new, .Xdg_Output_Mgr, v, nil)
		case "wp_viewporter":
			obj_new(c, new, .Viewporter, v, nil)
		case "wp_fractional_scale_manager_v1":
			obj_new(c, new, .Frac_Mgr, v, nil)
		case "xdg_activation_v1":
			obj_new(c, new, .Activation, v, nil)
		case "zwp_relative_pointer_manager_v1":
			obj_new(c, new, .Relp_Mgr, v, nil)
		case "zwp_pointer_constraints_v1":
			obj_new(c, new, .Pconstraints, v, nil)
		case "zwp_idle_inhibit_manager_v1":
			obj_new(c, new, .Idle_Mgr, v, nil)
		}
		return
	}

	// Not a singleton: it may be one of the hot-pluggable wl_output globals.
	if out_bind(s, c, id, name, iface, ver, new) {
		return
	}
	post_error(c, id, 0, fmt.tprintf("no such global: %d", name))
}

// send_output used to invent a single head right here. It forwards to the real
// list in output.odin now; the procedure is kept because it is the name the
// rest of the tree knows.
send_output :: proc(s: ^Server, c: ^Client, id: u32, ver: u32) {
	out_ensure_fallback(s)
	if o := out_primary(); o != nil {
		out_send_wl(c, id, ver, o, done = true)
	}
}

// --- wl_compositor ----------------------------------------------------------

req_compositor :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// create_surface
		sid := r_u32(r)
		surf := new(Surface)
		surf.client = c
		surf.id = sid
		surf.scale = 1
		surf.p_scale = 1
		if !obj_new(c, sid, .Surface, o.ver, surf) {
			free(surf)
			return
		}
		append(&s.surfaces, surf)
	case 1:
		// create_region: we never clip input by region, so the object exists
		// only to satisfy the protocol.
		obj_new(c, r_u32(r), .Region, o.ver, nil)
	case 2:
		obj_drop(c, id)
	}
}

// --- wl_shm -----------------------------------------------------------------

req_shm :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		// create_pool(id, fd, size)
		pid := r_u32(r)
		size := int(r_i32(r))
		fd, got := take_fd(c)
		if !got {
			post_error(c, id, 2, "wl_shm.create_pool without a file descriptor")
			return
		}
		if size <= 0 {
			linux.close(fd)
			post_error(c, id, 1, "wl_shm.create_pool with a non-positive size")
			return
		}
		mem, merr := linux.mmap(0, uint(size), {.READ}, {.SHARED}, fd, 0)
		if merr != .NONE {
			linux.close(fd)
			post_error(c, id, 2, fmt.tprintf("could not map the shm pool: %v", merr))
			return
		}
		pool := new(Pool)
		pool.client = c
		pool.id = pid
		pool.fd = fd
		pool.mem = ([^]u8)(mem)[:size]
		pool.refs = 1
		if !obj_new(c, pid, .Pool, 1, pool) {
			linux.munmap(mem, uint(size))
			linux.close(fd)
			free(pool)
			return
		}
		log_line("client %d: shm pool %d, %d bytes", c.index, pid, size)
	case 1:
		obj_drop(c, id)
	}
}

pool_unref :: proc(p: ^Pool) {
	p.refs -= 1
	if p.refs > 0 {
		return
	}
	if p.mem != nil {
		linux.munmap(raw_data(p.mem), uint(len(p.mem)))
		p.mem = nil
	}
	if p.fd != 0 {
		linux.close(p.fd)
		p.fd = 0
	}
	free(p)
}

req_pool :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	pool := (^Pool)(o.p)
	switch op {
	case 0:
		// create_buffer(id, offset, width, height, stride, format)
		bid := r_u32(r)
		offset := int(r_i32(r))
		w := int(r_i32(r))
		h := int(r_i32(r))
		stride := int(r_i32(r))
		format := r_u32(r)
		if r.bad {
			return
		}
		if w <= 0 || h <= 0 || stride < w * 4 || offset < 0 || offset + stride * h > len(pool.mem) {
			post_error(c, id, 1, fmt.tprintf("wl_shm_pool.create_buffer out of range (%dx%d stride %d offset %d pool %d)", w, h, stride, offset, len(pool.mem)))
			return
		}
		if format != 0 && format != 1 {
			post_error(c, id, 0, fmt.tprintf("unsupported shm format 0x%x", format))
			return
		}
		b := new(Buffer)
		b.client = c
		b.id = bid
		b.pool = pool
		b.offset = offset
		b.w, b.h, b.stride = w, h, stride
		b.format = format
		if !obj_new(c, bid, .Buffer, 1, b) {
			free(b)
			return
		}
		pool.refs += 1
	case 1:
		// destroy: the mapping stays alive while buffers still reference it.
		pool.zombie = true
		obj_drop(c, id)
		pool_unref(pool)
	case 2:
		// resize(size)
		size := int(r_i32(r))
		if size <= len(pool.mem) || pool.fd == 0 {
			return
		}
		mem, merr := linux.mmap(0, uint(size), {.READ}, {.SHARED}, pool.fd, 0)
		if merr != .NONE {
			post_error(c, id, 2, fmt.tprintf("could not remap the shm pool: %v", merr))
			return
		}
		old := pool.mem
		pool.mem = ([^]u8)(mem)[:size]
		if old != nil {
			linux.munmap(raw_data(old), uint(len(old)))
		}
	}
}

buffer_destroy :: proc(c: ^Client, o: Object, id: u32) {
	b := (^Buffer)(o.p)
	b.destroyed = true
	obj_drop(c, id)
	pool_unref(b.pool)
	free(b)
}

// --- wl_surface -------------------------------------------------------------

req_surface :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	surf := (^Surface)(o.p)
	switch op {
	case 0:
		surface_destroy(s, c, surf, id)
	case 1:
		// attach(buffer, x, y)
		bid := r_u32(r)
		r_i32(r)
		r_i32(r)
		surf.p_buffer_set = true
		surf.p_buffer = nil
		if bid != 0 {
			if bo, ok := obj_get(c, bid); ok && bo.kind == .Buffer {
				surf.p_buffer = (^Buffer)(bo.p)
			}
		}
	case 2, 9:
		// damage / damage_buffer. Both are kept now. `damage` is in surface
		// coordinates and `damage_buffer` in buffer coordinates, so the second
		// is divided down by the buffer scale, rounding outwards so no partial
		// pixel is ever dropped.
		dx := int(r_i32(r))
		dy := int(r_i32(r))
		dw := int(r_i32(r))
		dh := int(r_i32(r))
		if dw > 0 && dh > 0 {
			if dx < 0 {dw += dx;dx = 0}
			if dy < 0 {dh += dy;dy = 0}
			if op == 9 {
				sc := max(surf.p_scale, 1)
				x1 := (dx + dw + sc - 1) / sc
				y1 := (dy + dh + sc - 1) / sc
				dx /= sc
				dy /= sc
				dw, dh = x1 - dx, y1 - dy
			}
			if dw > 0 && dh > 0 {
				surface_add_damage(surf, dx, dy, dw, dh)
			}
		}
	case 3:
		// frame(callback)
		cb := r_u32(r)
		if obj_new(c, cb, .Callback, 1, nil) {
			append(&surf.p_frames, cb)
		}
	case 4, 5:
		// set_opaque_region / set_input_region
		r_u32(r)
	case 6:
		surface_commit(s, surf)
	case 7:
		// set_buffer_transform
		r_i32(r)
	case 8:
		sc := int(r_i32(r))
		if sc >= 1 {
			surf.p_scale = sc
		}
	case 10:
		// offset(x, y)
		r_i32(r);r_i32(r)
	}
}

surface_destroy :: proc(s: ^Server, c: ^Client, surf: ^Surface, id: u32) {
	if surf.xdg != nil {
		surf.xdg.surf = nil
	}
	if surf.layer != nil {
		surf.layer.surf = nil
		surf.layer.mapped = false
		surf.layer = nil
	}
	if surf.lock != nil {
		surf.lock.surf = nil
		surf.lock.mapped = false
		surf.lock = nil
	}
	// A viewport or a fractional-scale object may outlive its surface; blank
	// the back-pointer rather than leave it dangling.
	for oid in ([2]u32{surf.vp_obj, surf.frac_obj}) {
		if oid == 0 {
			continue
		}
		if ob, ok := obj_get(c, oid); ok {
			c.objs[oid] = Object{kind = ob.kind, ver = ob.ver, p = nil}
		}
	}
	if surf.parent != nil {
		for ch, i in surf.parent.children {
			if ch == surf {
				ordered_remove(&surf.parent.children, i)
				break
			}
		}
		surf.parent = nil
	}
	for ch in surf.children {
		ch.parent = nil
	}
	for i := len(s.surfaces) - 1; i >= 0; i -= 1 {
		if s.surfaces[i] == surf {
			ordered_remove(&s.surfaces, i)
		}
	}
	if s.ptr_surf == surf {
		s.ptr_surf = nil
	}
	if s.kbd_surf == surf {
		s.kbd_surf = nil
	}
	obj_drop(c, id)
	delete(surf.img)
	delete(surf.p_frames)
	delete(surf.frames)
	delete(surf.children)
	free(surf)
	layer_arrange(s)
}

// surface_commit applies the pending state. The client's pixels are copied out
// of the shm pool here, which lets the buffer be released immediately and
// means a later redraw by the client cannot tear what we are compositing.
surface_commit :: proc(s: ^Server, surf: ^Surface) {
	surf.scale = surf.p_scale

	if surf.p_buffer_set {
		surf.p_buffer_set = false
		b := surf.p_buffer
		surf.p_buffer = nil
		if b == nil {
			delete(surf.img)
			surf.img = nil
			surf.iw, surf.ih = 0, 0
		} else if !b.destroyed && b.pool.mem != nil {
			copy_buffer(surf, b)
			event(b.client, b.id, 0) // wl_buffer.release
		}
	}

	for cb in surf.p_frames {
		append(&surf.frames, cb)
	}
	clear(&surf.p_frames)

	surface_apply_damage(surf)

	switch surf.role {
	case .Xdg:
		if surf.xdg != nil {
			xdg_commit(s, surf.xdg)
		}
	case .Layer:
		if surf.layer != nil {
			layer_commit(s, surf.layer)
		}
	case .Lock:
		if surf.lock != nil {
			lock_commit(s, surf.lock)
		}
	case .None, .Sub:
	}
	s.dirty = true
}

// ---------------------------------------------------------------------------
// Damage
//
// The compositing loop in main.odin re-copies every surface in full on every
// commit. These five procedures are the whole seam it needs in order to stop:
// the accumulated region lives here, in surface-local pixels, and
// `surface_damage_reset` is called once those pixels have been painted.
// ---------------------------------------------------------------------------

surface_add_damage :: proc(surf: ^Surface, x, y, w, h: int) {
	if surf.p_dmg_full {
		return
	}
	if surf.p_dmg_n >= DMG_MAX {
		// More rectangles than are worth tracking one by one.
		surf.p_dmg_full = true
		surf.p_dmg_n = 0
		return
	}
	surf.p_dmg[surf.p_dmg_n] = {x, y, w, h}
	surf.p_dmg_n += 1
}

// surface_apply_damage folds the pending region into the accumulated one. The
// accumulation is deliberate: a client may commit twice between two of our
// frames, and both commits have to be repainted.
surface_apply_damage :: proc(surf: ^Surface) {
	if surf.p_dmg_full || surf.dmg_full {
		surf.dmg_full = true
		surf.dmg_n = 0
	} else {
		for i in 0 ..< surf.p_dmg_n {
			if surf.dmg_n >= DMG_MAX {
				surf.dmg_full = true
				surf.dmg_n = 0
				break
			}
			surf.dmg[surf.dmg_n] = surf.p_dmg[i]
			surf.dmg_n += 1
		}
	}
	surf.p_dmg_full = false
	surf.p_dmg_n = 0
}

// surface_damage_rects is the accumulated region. It is empty when nothing
// changed, and meaningless when `surface_damage_full` is true.
surface_damage_rects :: proc(surf: ^Surface) -> [][4]int {
	return surf.dmg[:surf.dmg_n]
}

surface_damage_full :: proc(surf: ^Surface) -> bool {
	return surf.dmg_full
}

// surface_damage_bbox is the cheap answer: one rectangle covering everything
// that changed, clipped to the surface, and whether there is anything at all.
surface_damage_bbox :: proc(surf: ^Surface) -> ([4]int, bool) {
	w := surf.iw / max(surf.scale, 1)
	h := surf.ih / max(surf.scale, 1)
	if w <= 0 || h <= 0 {
		return {0, 0, 0, 0}, false
	}
	if surf.dmg_full {
		return {0, 0, w, h}, true
	}
	if surf.dmg_n == 0 {
		return {0, 0, 0, 0}, false
	}
	x0, y0 := surf.dmg[0][0], surf.dmg[0][1]
	x1, y1 := x0 + surf.dmg[0][2], y0 + surf.dmg[0][3]
	for i in 1 ..< surf.dmg_n {
		d := surf.dmg[i]
		x0 = min(x0, d[0])
		y0 = min(y0, d[1])
		x1 = max(x1, d[0] + d[2])
		y1 = max(y1, d[1] + d[3])
	}
	x0 = clamp(x0, 0, w)
	y0 = clamp(y0, 0, h)
	x1 = clamp(x1, 0, w)
	y1 = clamp(y1, 0, h)
	if x1 <= x0 || y1 <= y0 {
		return {0, 0, 0, 0}, false
	}
	return {x0, y0, x1 - x0, y1 - y0}, true
}

// surface_damage_reset is called by the compositing loop once the surface has
// been painted.
surface_damage_reset :: proc(surf: ^Surface) {
	surf.dmg_n = 0
	surf.dmg_full = false
}

// copy_buffer converts a client buffer into our own 0xAARRGGBB image.
copy_buffer :: proc(surf: ^Surface, b: ^Buffer) {
	if surf.vp_src_set || surf.vp_dst_set {
		copy_buffer_viewport(surf, b)
		return
	}
	n := b.w * b.h
	if len(surf.img) != n {
		delete(surf.img)
		surf.img = make([]u32, n)
		surf.dmg_full = true
	}
	if surf.iw != b.w || surf.ih != b.h {
		surf.dmg_full = true
	}
	surf.iw, surf.ih = b.w, b.h
	surf.opaque = b.format == 1

	base := b.offset
	for y in 0 ..< b.h {
		row := base + y * b.stride
		if row + b.w * 4 > len(b.pool.mem) {
			break
		}
		src := (([^]u32)(raw_data(b.pool.mem[row:])))[:b.w]
		dst := surf.img[y * b.w:][:b.w]
		if b.format == 1 {
			for x in 0 ..< b.w {
				dst[x] = 0xff00_0000 | (src[x] & 0x00ff_ffff)
			}
		} else {
			copy(dst, src)
		}
	}
}

// copy_buffer_viewport is the same copy with a wp_viewport applied: the source
// rectangle is cropped out of the buffer and resampled to the destination
// size. Doing it here means the destination size *is* the surface size, so
// nothing downstream — hit testing, blitting, damage — has to know a viewport
// exists. Nearest neighbour: this is a CPU rasteriser and a viewport is almost
// always an exact integer ratio in practice.
copy_buffer_viewport :: proc(surf: ^Surface, b: ^Buffer) {
	sc := f32(max(surf.scale, 1))
	rx, ry := f32(0), f32(0)
	rw, rh := f32(b.w), f32(b.h)
	if surf.vp_src_set {
		rx, ry = surf.vp_src[0] * sc, surf.vp_src[1] * sc
		rw, rh = surf.vp_src[2] * sc, surf.vp_src[3] * sc
	}
	rw = clamp(rw, 1, f32(b.w))
	rh = clamp(rh, 1, f32(b.h))

	dw, dh: int
	if surf.vp_dst_set {
		dw, dh = surf.vp_dst[0], surf.vp_dst[1]
	} else {
		dw, dh = int(rw / sc), int(rh / sc)
	}
	dw = max(dw, 1)
	dh = max(dh, 1)

	if len(surf.img) != dw * dh {
		delete(surf.img)
		surf.img = make([]u32, dw * dh)
	}
	// The destination is already in surface-local pixels, so the buffer scale
	// has been consumed here and must not be applied a second time.
	if surf.iw != dw || surf.ih != dh || surf.scale != 1 {
		surf.dmg_full = true
	}
	surf.iw, surf.ih = dw, dh
	surf.scale = 1
	surf.opaque = b.format == 1

	for j in 0 ..< dh {
		sy := int(ry + (f32(j) + 0.5) * rh / f32(dh))
		sy = clamp(sy, 0, b.h - 1)
		row := b.offset + sy * b.stride
		if row + b.w * 4 > len(b.pool.mem) {
			break
		}
		src := (([^]u32)(raw_data(b.pool.mem[row:])))[:b.w]
		dst := surf.img[j * dw:][:dw]
		for i in 0 ..< dw {
			sx := int(rx + (f32(i) + 0.5) * rw / f32(dw))
			sx = clamp(sx, 0, b.w - 1)
			v := src[sx]
			dst[i] = b.format == 1 ? (0xff00_0000 | (v & 0x00ff_ffff)) : v
		}
	}
}

// --- xdg_wm_base ------------------------------------------------------------

req_wm_base :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		for b, i in c.wm_bases {
			if b == id {
				ordered_remove(&c.wm_bases, i)
				break
			}
		}
		obj_drop(c, id)
	case 1:
		obj_new(c, r_u32(r), .Positioner, o.ver, nil)
	case 2:
		// get_xdg_surface(id, surface)
		xid := r_u32(r)
		sid := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "xdg_wm_base.get_xdg_surface on a non-surface")
			return
		}
		surf := (^Surface)(so.p)
		x := new(Xdg_Surface)
		x.client = c
		x.id = xid
		x.surf = surf
		if !obj_new(c, xid, .Xdg_Surface, o.ver, x) {
			free(x)
			return
		}
		surf.role = .Xdg
		surf.xdg = x
	case 3:
		// pong
		r_u32(r)
	}
}

req_xdg_surface :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	x := (^Xdg_Surface)(o.p)
	switch op {
	case 0:
		if x.surf != nil {
			x.surf.role = .None
			x.surf.xdg = nil
		}
		obj_drop(c, id)
		free(x)
	case 1:
		// get_toplevel(id)
		tid := r_u32(r)
		t := new(Toplevel)
		t.client = c
		t.id = tid
		t.xdg = x
		t.title = strings.clone("")
		t.app_id = strings.clone("")
		t.max_w, t.max_h = 0, 0
		if !obj_new(c, tid, .Toplevel, o.ver, t) {
			free(t)
			return
		}
		x.top = t
		log_line("client %d: toplevel %d created", c.index, tid)
	case 2:
		post_error(c, id, 0, "this compositor does not implement xdg_popup")
	case 3:
		// set_window_geometry(x, y, w, h)
		x.gx = int(r_i32(r))
		x.gy = int(r_i32(r))
		x.gw = int(r_i32(r))
		x.gh = int(r_i32(r))
		x.geom_set = x.gw > 0 && x.gh > 0
	case 4:
		x.acked = r_u32(r)
	}
}

// send_configure asks a toplevel to take a size. Width and height of zero let
// the client choose, which is what the first configure does.
send_configure :: proc(s: ^Server, t: ^Toplevel, w, h: int) {
	c := t.client
	states := make([dynamic]u8, 0, 16, context.temp_allocator)
	put_state :: proc(d: ^[dynamic]u8, v: u32) {
		b := transmute([4]u8)v
		append(d, ..b[:])
	}
	if t.maximized {
		put_state(&states, 1)
	}
	if t.resizing {
		put_state(&states, 3)
	}
	if t.activated {
		put_state(&states, 4)
	}
	event(c, t.id, 0, i32(w), i32(h), states[:])
	t.last_cfg_w, t.last_cfg_h = w, h
	t.xdg.serial = next_serial(s)
	event(c, t.xdg.id, 0, t.xdg.serial)
	t.xdg.initial_sent = true
}

xdg_commit :: proc(s: ^Server, x: ^Xdg_Surface) {
	t := x.top
	if t == nil {
		return
	}
	surf := x.surf

	if !x.initial_sent {
		t.activated = true
		send_configure(s, t, 0, 0)
		return
	}

	has := surf != nil && surf.img != nil && surf.iw > 0

	if has && !t.mapped {
		t.mapped = true
		t.w = surf.iw / max(surf.scale, 1)
		t.h = surf.ih / max(surf.scale, 1)
		t.req_w, t.req_h = t.w, t.h
		place_new_window(s, t)
		append(&s.stack, t)
		focus_window(s, t)
		log_line("mapped %q %dx%d at %d,%d", t.title, t.w, t.h, t.x, t.y)
		if !surf.entered {
			surf.entered = true
			// wl_surface.enter: tell the client which output it is on.
			if oid := out_binding_id(t.client, out_at(t.x, t.y)); oid != 0 {
				event(t.client, surf.id, 0, oid)
			}
		}
	} else if has && t.mapped {
		nw := surf.iw / max(surf.scale, 1)
		nh := surf.ih / max(surf.scale, 1)
		if nw != t.w || nh != t.h {
			if t.anchor_x {
				t.x = t.anchor_right - nw
			}
			if t.anchor_y {
				t.y = t.anchor_bottom - nh
			}
			t.w, t.h = nw, nh
		}
	} else if !has && t.mapped {
		unmap_window(s, t)
	}
}

find_output :: proc(c: ^Client) -> u32 {
	return out_binding_id(c, out_primary())
}

req_toplevel :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	t := (^Toplevel)(o.p)
	switch op {
	case 0:
		unmap_window(s, t)
		if t.xdg != nil {
			t.xdg.top = nil
		}
		obj_drop(c, id)
		delete(t.title)
		delete(t.app_id)
		free(t)
	case 1:
		r_u32(r)
	case 2:
		title := r_string(r)
		delete(t.title)
		t.title = strings.clone(title)
		s.dirty = true
	case 3:
		app := r_string(r)
		delete(t.app_id)
		t.app_id = strings.clone(app)
	case 4:
		r_u32(r);r_u32(r);r_i32(r);r_i32(r)
	case 5:
		// move(seat, serial): the client asks us to start an interactive move.
		r_u32(r);r_u32(r)
		if t.mapped {
			begin_move(s, t)
		}
	case 6:
		// resize(seat, serial, edges)
		r_u32(r);r_u32(r)
		edges := r_u32(r)
		if t.mapped {
			begin_resize_edges(s, t, edges)
		}
	case 7:
		t.max_w = int(r_i32(r))
		t.max_h = int(r_i32(r))
	case 8:
		t.min_w = int(r_i32(r))
		t.min_h = int(r_i32(r))
	case 9:
		set_maximized(s, t, true)
	case 10:
		set_maximized(s, t, false)
	case 11:
		r_u32(r)
		set_maximized(s, t, true)
	case 12:
		set_maximized(s, t, false)
	case 13:
		t.minimized = true
		if s.focus == t {
			focus_window(s, topmost_other(s, t))
		}
		s.dirty = true
	}
}

// --- wl_seat ----------------------------------------------------------------

req_seat :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		pid := r_u32(r)
		if obj_new(c, pid, .Pointer, o.ver, nil) {
			append(&c.pointers, pid)
		}
	case 1:
		kid := r_u32(r)
		if obj_new(c, kid, .Keyboard, o.ver, nil) {
			append(&c.keyboards, kid)
			send_keymap(s, c, kid)
			if o.ver >= 4 {
				event(c, kid, 5, i32(s.repeat_rate), i32(s.repeat_delay))
			}
			// If this client already holds focus, let it know straight away.
			if s.kbd_surf != nil && s.kbd_surf.client == c {
				keys: [dynamic]u8
				event(c, kid, 1, next_serial(s), s.kbd_surf.id, keys[:])
				delete(keys)
				event(c, kid, 4, next_serial(s), s.mod_mask, u32(0), u32(0), s.kt.group)
			}
		}
	case 2:
		obj_new(c, r_u32(r), .Touch, o.ver, nil)
	case 3:
		obj_drop(c, id)
	}
}

pointer_gone :: proc(s: ^Server, c: ^Client, id: u32) {
	for p, i in c.pointers {
		if p == id {
			ordered_remove(&c.pointers, i)
			return
		}
	}
}

keyboard_gone :: proc(s: ^Server, c: ^Client, id: u32) {
	for k, i in c.keyboards {
		if k == id {
			ordered_remove(&c.keyboards, i)
			return
		}
	}
}

// --- wl_subcompositor -------------------------------------------------------

req_subcompositor :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_subsurface(id, surface, parent)
		sub := r_u32(r)
		sid := r_u32(r)
		pid := r_u32(r)
		so, ok1 := obj_get(c, sid)
		po, ok2 := obj_get(c, pid)
		if !ok1 || !ok2 || so.kind != .Surface || po.kind != .Surface {
			post_error(c, id, 0, "wl_subcompositor.get_subsurface on a non-surface")
			return
		}
		child := (^Surface)(so.p)
		parent := (^Surface)(po.p)
		if !obj_new(c, sub, .Subsurface, 1, child) {
			return
		}
		child.role = .Sub
		child.parent = parent
		child.sub_id = sub
		append(&parent.children, child)
	}
}

req_subsurface :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	child := (^Surface)(o.p)
	switch op {
	case 0:
		if child.parent != nil {
			for ch, i in child.parent.children {
				if ch == child {
					ordered_remove(&child.parent.children, i)
					break
				}
			}
			child.parent = nil
		}
		child.role = .None
		obj_drop(c, id)
	case 1:
		child.sx = int(r_i32(r))
		child.sy = int(r_i32(r))
		s.dirty = true
	case 2, 3:
		// place_above / place_below: move the child within the parent's list.
		sib := r_u32(r)
		if child.parent == nil {
			return
		}
		so, ok := obj_get(c, sib)
		if !ok || so.kind != .Surface {
			return
		}
		target := (^Surface)(so.p)
		list := &child.parent.children
		at := -1
		ti := -1
		for ch, i in list {
			if ch == child {at = i}
			if ch == target {ti = i}
		}
		if at < 0 {
			return
		}
		ordered_remove(list, at)
		if ti < 0 {
			append(list, child)
			return
		}
		if at < ti {ti -= 1}
		idx := op == 2 ? ti + 1 : ti
		inject_at(list, clamp(idx, 0, len(list)), child)
	case 4, 5:
	}
}

// --- xdg-decoration ---------------------------------------------------------

req_decor_mgr :: proc(s: ^Server, c: ^Client, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		did := r_u32(r)
		tid := r_u32(r)
		if obj_new(c, did, .Decoration, 1, nil) {
			if to, ok := obj_get(c, tid); ok && to.kind == .Toplevel {
				(^Toplevel)(to.p).decoration = did
			}
			event(c, did, 0, u32(2)) // server_side
		}
	}
}

// ---------------------------------------------------------------------------
// wl_touch
//
// The seat used to advertise pointer|keyboard unconditionally. It now
// advertises touch as well when a touch device exists, and `wltouch_*` is the
// whole send side. `evdev.odin` owns the device itself: it calls
// `wltouch_set_present` once, then the four event procedures per contact.
// ---------------------------------------------------------------------------

WL_SEAT_POINTER :: u32(1)
WL_SEAT_KEYBOARD :: u32(2)
WL_SEAT_TOUCH :: u32(4)

wltouch_present: bool
wltouch_probed: bool

wltouch_caps :: proc() -> u32 {
	caps := WL_SEAT_POINTER | WL_SEAT_KEYBOARD
	if wltouch_present {
		caps |= WL_SEAT_TOUCH
	}
	return caps
}

// wltouch_set_present re-announces the seat capabilities to everyone. A
// touchscreen that is plugged in halfway through a session has to appear.
wltouch_set_present :: proc(s: ^Server, present: bool) {
	if present == wltouch_present {
		return
	}
	wltouch_present = present
	caps := wltouch_caps()
	for c in s.clients {
		if c.dead {
			continue
		}
		for id, o in c.objs {
			if o.kind == .Seat {
				event(c, id, 0, caps)
			}
		}
	}
	log_line("seat capabilities now 0x%x (touch %v)", caps, present)
}

// wltouch_probe is the zero-dependency answer to "is there a touchscreen".
// /proc/bus/input/devices lists each device's capability bitmaps; a device
// that reports ABS_MT_POSITION_X (0x35) is a multitouch digitiser. It runs
// once, and `evdev.odin` can override it at any time.
wltouch_probe :: proc(s: ^Server) {
	if wltouch_probed {
		return
	}
	wltouch_probed = true
	data, rerr := os.read_entire_file_from_path("/proc/bus/input/devices", context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if !strings.has_prefix(t, "B: ABS=") {
			continue
		}
		// The kernel prints the bitmap most significant word first, so the
		// last word holds bits 0..63 and ABS_MT_POSITION_X is in there.
		fields := strings.fields(t[len("B: ABS="):], context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		low := u64(0)
		for ch in fields[len(fields) - 1] {
			d: u64
			switch {
			case ch >= '0' && ch <= '9':
				d = u64(ch - '0')
			case ch >= 'a' && ch <= 'f':
				d = u64(ch-'a') + 10
			case ch >= 'A' && ch <= 'F':
				d = u64(ch-'A') + 10
			case:
				continue
			}
			low = low * 16 + d
		}
		if low & (u64(1) << 53) != 0 {
			wltouch_set_present(s, true)
			return
		}
	}
}

wltouch_down :: proc(s: ^Server, surf: ^Surface, tid: i32, lx, ly: f32) {
	if surf == nil || surf.client.dead {
		return
	}
	serial := next_serial(s)
	t := now_ms()
	for id, o in surf.client.objs {
		if o.kind == .Touch {
			event(surf.client, id, 0, serial, t, surf.id, tid, fixed(lx), fixed(ly))
		}
	}
}

wltouch_up :: proc(s: ^Server, surf: ^Surface, tid: i32) {
	if surf == nil || surf.client.dead {
		return
	}
	serial := next_serial(s)
	t := now_ms()
	for id, o in surf.client.objs {
		if o.kind == .Touch {
			event(surf.client, id, 1, serial, t, tid)
		}
	}
}

wltouch_motion :: proc(s: ^Server, surf: ^Surface, tid: i32, lx, ly: f32) {
	if surf == nil || surf.client.dead {
		return
	}
	t := now_ms()
	for id, o in surf.client.objs {
		if o.kind == .Touch {
			event(surf.client, id, 2, t, tid, fixed(lx), fixed(ly))
		}
	}
}

wltouch_frame :: proc(s: ^Server, surf: ^Surface) {
	if surf == nil || surf.client.dead {
		return
	}
	for id, o in surf.client.objs {
		if o.kind == .Touch {
			event(surf.client, id, 3)
		}
	}
}

wltouch_cancel :: proc(s: ^Server, surf: ^Surface) {
	if surf == nil || surf.client.dead {
		return
	}
	for id, o in surf.client.objs {
		if o.kind == .Touch {
			event(surf.client, id, 4)
		}
	}
}

// ---------------------------------------------------------------------------
// xdg_activation_v1
//
// A token is a one-shot capability to raise a window: a launcher asks for one,
// hands it to the process it starts, and that process presents it when its
// window appears instead of stealing focus unasked.
// ---------------------------------------------------------------------------

Act_Req :: struct {
	client:    ^Client,
	id:        u32,
	serial:    u32,
	app_id:    string,
	surf:      ^Surface,
	committed: bool,
}

act_reqs: [dynamic]Act_Req
act_tokens: [dynamic]string
act_counter: u32

ACT_TOKEN_MAX :: 32

act_find :: proc(c: ^Client, id: u32) -> int {
	for a, i in act_reqs {
		if a.client == c && a.id == id {
			return i
		}
	}
	return -1
}

req_activation :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_activation_token(id)
		tid := r_u32(r)
		if obj_new(c, tid, .Act_Token, o.ver, nil) {
			append(&act_reqs, Act_Req{client = c, id = tid})
		}
	case 2:
		// activate(token, surface)
		tok := r_string(r)
		sid := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			return
		}
		if !act_consume(tok) {
			log_line("client %d presented an unknown activation token", c.index)
			return
		}
		surf := (^Surface)(so.p)
		if surf.role == .Xdg && surf.xdg != nil && surf.xdg.top != nil && surf.xdg.top.mapped {
			focus_window(s, surf.xdg.top)
			log_line("activated %q by token", title_of(surf.xdg.top))
		}
	}
}

act_consume :: proc(tok: string) -> bool {
	for t, i in act_tokens {
		if t == tok {
			delete(t)
			ordered_remove(&act_tokens, i)
			return true
		}
	}
	return false
}

req_act_token :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	i := act_find(c, id)
	switch op {
	case 0:
		// set_serial(serial, seat)
		if i >= 0 {
			act_reqs[i].serial = r_u32(r)
		}
		r_u32(r)
	case 1:
		// set_app_id(app_id)
		app := r_string(r)
		if i >= 0 {
			delete(act_reqs[i].app_id)
			act_reqs[i].app_id = strings.clone(app)
		}
	case 2:
		// set_surface(surface)
		sid := r_u32(r)
		if so, ok := obj_get(c, sid); ok && so.kind == .Surface && i >= 0 {
			act_reqs[i].surf = (^Surface)(so.p)
		}
	case 3:
		// commit
		if i < 0 || act_reqs[i].committed {
			return
		}
		act_reqs[i].committed = true
		act_counter += 1
		tok := fmt.aprintf("palmy-%d-%d", act_counter, next_serial(s))
		append(&act_tokens, tok)
		for len(act_tokens) > ACT_TOKEN_MAX {
			delete(act_tokens[0])
			ordered_remove(&act_tokens, 0)
		}
		event(c, id, 0, tok) // done
	case 4:
		if i >= 0 {
			delete(act_reqs[i].app_id)
			ordered_remove(&act_reqs, i)
		}
		obj_drop(c, id)
	}
}

// ---------------------------------------------------------------------------
// zwp_relative_pointer_v1 and zwp_pointer_constraints_v1
//
// Together these are what a 3D viewport or a game needs: the pointer stops
// moving on screen and the application is handed unaccelerated deltas instead.
// The protocol objects and their state live here; `main.odin` owns the actual
// pointer, so it calls `pconf_update` when pointer focus changes and
// `relp_motion` with each delta, and consults `pconf_pointer_locked` before
// moving the cursor.
// ---------------------------------------------------------------------------

req_relp_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_relative_pointer(id, pointer)
		rid := r_u32(r)
		pid := r_u32(r)
		obj_new(c, rid, .Relp, o.ver, rawptr(uintptr(pid)))
	}
}

// relp_motion delivers one unaccelerated delta to whoever holds the pointer.
relp_motion :: proc(s: ^Server, surf: ^Surface, dx, dy: f32) {
	if surf == nil || surf.client.dead {
		return
	}
	us := u64(now_ms()) * 1000
	hi := u32(us >> 32)
	lo := u32(us & 0xffff_ffff)
	for id, o in surf.client.objs {
		if o.kind != .Relp {
			continue
		}
		event(surf.client, id, 0, hi, lo, fixed(dx), fixed(dy), fixed(dx), fixed(dy))
	}
}

Pconf :: struct {
	client:   ^Client,
	id:       u32,
	surf:     ^Surface,
	confine:  bool,
	lifetime: u32, // 1 oneshot, 2 persistent
	active:   bool,
	dead:     bool,
	hint:     [2]f32,
}

pconf_list: [dynamic]Pconf

req_pconstraints :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1, 2:
		// lock_pointer / confine_pointer(id, surface, pointer, region, lifetime)
		nid := r_u32(r)
		sid := r_u32(r)
		r_u32(r) // pointer
		r_u32(r) // region, we never clip input by region
		life := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "zwp_pointer_constraints_v1 on a non-surface")
			return
		}
		surf := (^Surface)(so.p)
		for pc in pconf_list {
			if pc.surf == surf && !pc.dead {
				post_error(c, id, 1, "that surface already has a pointer constraint")
				return
			}
		}
		kind: Kind = op == 1 ? .Locked_Pointer : .Confined_Pointer
		if !obj_new(c, nid, kind, o.ver, surf) {
			return
		}
		append(
			&pconf_list,
			Pconf{client = c, id = nid, surf = surf, confine = op == 2, lifetime = life},
		)
		pconf_update(s)
	}
}

req_pconstraint :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	idx := -1
	for pc, i in pconf_list {
		if pc.client == c && pc.id == id {
			idx = i
			break
		}
	}
	switch op {
	case 0:
		if idx >= 0 {
			ordered_remove(&pconf_list, idx)
		}
		obj_drop(c, id)
		pconf_update(s)
	case 1:
		// set_cursor_position_hint(x, y) on a locked pointer; set_region on a
		// confined one. Both are advisory here.
		if o.kind == .Locked_Pointer {
			x := r_fixed(r)
			y := r_fixed(r)
			if idx >= 0 {
				pconf_list[idx].hint = {x, y}
			}
		} else {
			r_u32(r)
		}
	case 2:
		r_u32(r) // set_region
	}
}

// pconf_update activates the constraint whose surface currently has the
// pointer and deactivates every other one, which is exactly the rule the
// protocol states.
pconf_update :: proc(s: ^Server) {
	for i := len(pconf_list) - 1; i >= 0; i -= 1 {
		pc := &pconf_list[i]
		alive := false
		for c in s.clients {
			if c == pc.client && !c.dead {
				alive = true
				break
			}
		}
		if !alive {
			ordered_remove(&pconf_list, i)
			continue
		}
		want := !lock_active() && pc.surf != nil && s.ptr_surf == pc.surf
		if want == pc.active {
			continue
		}
		pc.active = want
		// locked / confined is event 0, unlocked / unconfined is event 1.
		event(pc.client, pc.id, want ? u16(0) : u16(1))
		if !want && pc.lifetime == 1 {
			pc.dead = true
		}
	}
}

// pconf_pointer_locked reports whether the cursor must stay where it is.
pconf_pointer_locked :: proc(s: ^Server) -> bool {
	for pc in pconf_list {
		if pc.active && !pc.confine {
			return true
		}
	}
	return false
}

// pconf_confine_rect is the rectangle the cursor must stay inside, if any.
pconf_confine_rect :: proc(s: ^Server) -> ([4]int, bool) {
	for pc in pconf_list {
		if !pc.active || !pc.confine || pc.surf == nil {
			continue
		}
		surf := pc.surf
		if surf.role == .Xdg && surf.xdg != nil && surf.xdg.top != nil {
			t := surf.xdg.top
			return {t.x, t.y, t.w, t.h}, true
		}
	}
	return {0, 0, 0, 0}, false
}

// wm_purge_extras drops the bookkeeping these three protocols keep for clients
// that have gone away. `layer_arrange` calls it once a frame.
wm_purge_extras :: proc(s: ^Server) {
	alive :: proc(s: ^Server, c: ^Client) -> bool {
		for x in s.clients {
			if x == c && !x.dead {
				return true
			}
		}
		return false
	}
	for i := len(act_reqs) - 1; i >= 0; i -= 1 {
		if !alive(s, act_reqs[i].client) {
			delete(act_reqs[i].app_id)
			ordered_remove(&act_reqs, i)
		}
	}
	for i := len(pconf_list) - 1; i >= 0; i -= 1 {
		if !alive(s, pconf_list[i].client) {
			ordered_remove(&pconf_list, i)
		}
	}
}
