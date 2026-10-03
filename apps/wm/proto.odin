// The object model and the request handlers: wl_display, wl_registry,
// wl_compositor, wl_shm, wl_surface, wl_seat and xdg-shell, implemented
// server side.
package wm

import "core:fmt"
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
}

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

GLOBALS := [?]Global {
	{1, "wl_compositor", 5},
	{2, "wl_shm", 1},
	{3, "wl_seat", 5},
	{4, "wl_output", 3},
	{5, "xdg_wm_base", 3},
	{6, "wl_subcompositor", 1},
	{7, "zxdg_decoration_manager_v1", 1},
	{8, "wl_data_device_manager", 3},
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
		for g in GLOBALS {
			event(c, reg, 0, g.name, g.iface, g.ver)
		}
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
				event(c, new, 0, u32(3)) // pointer | keyboard
				if v >= 2 {
					event(c, new, 1, "seat0")
				}
			}
		case "wl_output":
			if obj_new(c, new, .Output, v, nil) {
				send_output(s, c, new, v)
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
		}
		return
	}
	post_error(c, id, 0, fmt.tprintf("no such global: %d", name))
}

send_output :: proc(s: ^Server, c: ^Client, id: u32, ver: u32) {
	// geometry(x, y, phys_w, phys_h, subpixel, make, model, transform)
	event(c, id, 0, i32(0), i32(0), i32(340), i32(190), i32(0), "palmy", "nested", i32(0))
	// mode(flags=current|preferred, w, h, refresh)
	event(c, id, 1, u32(3), i32(s.out_w), i32(s.out_h), i32(60000))
	if ver >= 2 {
		event(c, id, 3, i32(1)) // scale
		event(c, id, 2) // done
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
		// damage / damage_buffer: we re-copy the whole surface on commit, so
		// the damage rectangles are read and discarded.
		r_i32(r);r_i32(r);r_i32(r);r_i32(r)
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

	if surf.role == .Xdg && surf.xdg != nil {
		xdg_commit(s, surf.xdg)
	}
	s.dirty = true
}

// copy_buffer converts a client buffer into our own 0xAARRGGBB image.
copy_buffer :: proc(surf: ^Surface, b: ^Buffer) {
	n := b.w * b.h
	if len(surf.img) != n {
		delete(surf.img)
		surf.img = make([]u32, n)
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
			if oid := find_output(t.client); oid != 0 {
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
	for id, o in c.objs {
		if o.kind == .Output {
			return id
		}
	}
	return 0
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
				event(c, kid, 4, next_serial(s), s.mod_mask, u32(0), u32(0), u32(0))
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
