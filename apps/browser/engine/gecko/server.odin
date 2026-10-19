// A Wayland compositor with one window and no screen.
//
// Firefox is a Wayland client. Rather than embed Gecko -- which has no
// supported desktop embedding API -- this host gives Firefox a private
// compositor that exists only for the browser window: Firefox connects to it,
// draws into wl_shm buffers as it would on any desktop, and this process
// composites its toplevel, subsurfaces and popups into the view's shared
// buffer for the chrome. Input arrives from the chrome and leaves as
// wl_pointer and wl_keyboard events, so Firefox sees a real seat with real
// serials, which is what makes its popups (<select>, autocomplete) work.
//
// The protocol surface is the minimum Firefox 158 and GTK 3 need:
//   wl_compositor 5, wl_subcompositor 1, wl_shm 1, wl_seat 7, wl_output 4,
//   xdg_wm_base 3 (toplevel + popup + positioner), wl_data_device_manager 3
//   (stubbed), wp_cursor_shape_manager_v1 1.
package gecko

import "core:os"
import "core:strings"
import "core:sys/linux"

Kind :: enum u8 {
	None,
	Display,
	Registry,
	Callback,
	Compositor,
	Subcompositor,
	Surface,
	Region,
	Subsurface,
	Shm,
	Shm_Pool,
	Buffer,
	Seat,
	Pointer,
	Keyboard,
	Touch,
	Output,
	Wm_Base,
	Positioner,
	Xdg_Surface,
	Toplevel,
	Popup,
	Ddm,
	Data_Device,
	Data_Source,
	Shape_Manager,
	Shape_Device,
}

Object :: struct {
	kind:    Kind,
	version: u32,
	ptr:     rawptr,
}

Client :: struct {
	fd:      linux.Fd,
	rx:      [dynamic]u8,
	rx_fds:  [dynamic]linux.Fd,
	out:     [dynamic]u8,
	out_fds: [dynamic]linux.Fd,
	objects: map[u32]Object,
	dead:    bool,
	next_id: u32, // server-allocated ids
	pointers:  [dynamic]u32,
	keyboards: [dynamic]u32,
	outputs:   [dynamic]u32,
	shape_devices: [dynamic]u32,
}

Pool :: struct {
	fd:   linux.Fd,
	data: []u8,
	size: int,
	refs: int,
}

Buffer :: struct {
	id:     u32,
	pool:   ^Pool,
	offset: int,
	w, h:   int,
	stride: int,
	format: u32,
}

Rect :: struct {
	x, y, w, h: int,
}

Role :: enum u8 {
	None,
	Toplevel,
	Popup,
	Subsurface,
	Cursor,
}

Surface :: struct {
	id:            u32,
	role:          Role,
	// what the client has asked for, applied on commit
	pend_buffer:   ^Buffer,
	// the committed buffer: a commit with damage and no attach means "read
	// these rectangles of the same buffer again", which Firefox relies on
	cur_buffer:    ^Buffer,
	pend_attached: bool,
	pend_damage:   [dynamic]Rect,
	pend_frames:   [dynamic]u32,
	pend_scale:    int,
	pend_dx, pend_dy: int,
	// the committed picture, copied out of the client's buffer
	img:           []u32,
	w, h:          int, // buffer size, device pixels
	scale:         int,
	mapped:        bool,
	frames:        [dynamic]u32, // callbacks waiting for the next frame
	entered:       bool,
	// tree
	parent:        ^Surface,
	children:      [dynamic]^Surface, // subsurfaces, bottom to top
	sub_x, sub_y:  int, // position in the parent, logical
	sub_pend_x, sub_pend_y: int,
	// xdg
	xdg:           ^Xdg_Surface,
	destroyed:     bool,
}

Positioner :: struct {
	w, h:         int,
	ax, ay, aw, ah: int,
	anchor:       u32,
	gravity:      u32,
	adjust:       u32,
	off_x, off_y: int,
}

Xdg_Surface :: struct {
	id:         u32,
	surface:    ^Surface,
	role_id:    u32, // the toplevel or popup object
	is_popup:   bool,
	geom:       Rect, // window geometry, logical; zero means the whole buffer
	has_geom:   bool,
	configured: bool,
	// popups
	parent:     ^Xdg_Surface,
	pos:        Positioner,
	x, y:       int, // relative to the parent's window geometry, logical
	grab:       bool,
	title:      string,
}

g_client: ^Client

new_server_id :: proc(c: ^Client, kind: Kind, version: u32, ptr: rawptr = nil) -> u32 {
	c.next_id += 1
	id := 0xff000000 + c.next_id
	c.objects[id] = {kind, version, ptr}
	return id
}

GLOBALS := [?]struct {
	name:    u32,
	iface:   string,
	version: u32,
	kind:    Kind,
}{
	{1, "wl_compositor", 5, .Compositor},
	{2, "wl_subcompositor", 1, .Subcompositor},
	{3, "wl_shm", 1, .Shm},
	{4, "wl_seat", 7, .Seat},
	{5, "wl_output", 4, .Output},
	{6, "xdg_wm_base", 3, .Wm_Base},
	{7, "wl_data_device_manager", 3, .Ddm},
	{8, "wp_cursor_shape_manager_v1", 1, .Shape_Manager},
}

// destroyed tells the client an id it allocated is free again.
destroyed :: proc(c: ^Client, id: u32) {
	delete_key(&c.objects, id)
	if id < 0xff000000 {
		event(c, DISPLAY_ID, 1, id)
	}
}

surface_of :: proc(c: ^Client, id: u32) -> ^Surface {
	if o, ok := c.objects[id]; ok && o.kind == .Surface {
		return (^Surface)(o.ptr)
	}
	return nil
}

handle_request :: proc(c: ^Client, id: u32, op: u16, r: ^Reader) {
	obj, ok := c.objects[id]
	if !ok {
		// a request to an object already destroyed on our side: ignore
		return
	}
	switch obj.kind {
	case .None, .Callback, .Touch:
	case .Display:
		switch op {
		case 0: // sync
			cb := r_u32(r)
			event(c, cb, 0, g.serial)
			event(c, DISPLAY_ID, 1, cb)
		case 1: // get_registry
			reg := r_u32(r)
			c.objects[reg] = {.Registry, 1, nil}
			for gl in GLOBALS {
				event(c, reg, 0, gl.name, gl.iface, gl.version)
			}
		}
	case .Registry:
		if op == 0 {
			name := r_u32(r)
			_ = r_string(r)
			version := r_u32(r)
			nid := r_u32(r)
			for gl in GLOBALS {
				if gl.name == name {
					bind_global(c, gl.kind, nid, min(version, gl.version))
				}
			}
		}
	case .Compositor:
		switch op {
		case 0:
			sid := r_u32(r)
			s := new(Surface)
			s.id = sid
			s.scale = 1
			s.pend_scale = 0
			c.objects[sid] = {.Surface, obj.version, s}
		case 1:
			c.objects[r_u32(r)] = {.Region, 1, nil}
		}
	case .Region:
		if op == 0 {
			destroyed(c, id)
		}
	case .Surface:
		surface_request(c, id, (^Surface)(obj.ptr), op, r)
	case .Subcompositor:
		switch op {
		case 0:
			destroyed(c, id)
		case 1:
			nid := r_u32(r)
			s := surface_of(c, r_u32(r))
			parent := surface_of(c, r_u32(r))
			if s == nil || parent == nil {
				post_error(c, id, 0, "bad surface")
				return
			}
			s.role = .Subsurface
			s.parent = parent
			append(&parent.children, s)
			c.objects[nid] = {.Subsurface, 1, s}
		}
	case .Subsurface:
		s := (^Surface)(obj.ptr)
		switch op {
		case 0:
			if s.parent != nil {
				detach_child(s.parent, s)
			}
			s.parent = nil
			s.role = .None
			destroyed(c, id)
			damage_all()
		case 1:
			s.sub_pend_x = int(r_i32(r))
			s.sub_pend_y = int(r_i32(r))
			// applied with the parent's next commit; desync children are
			// positioned at once, which is what Firefox's content uses
			s.sub_x = s.sub_pend_x
			s.sub_y = s.sub_pend_y
		case 2, 3:
			sib := surface_of(c, r_u32(r))
			if s.parent != nil && sib != nil {
				restack(s, sib, op == 2)
			}
		case 4, 5:
		}
	case .Shm:
		switch op {
		case 0:
			nid := r_u32(r)
			fd, _ := take_fd(c)
			size := int(r_i32(r))
			pool := new(Pool)
			pool.fd = fd
			pool.size = size
			pool.refs = 1
			if size > 0 {
				ptr, err := linux.mmap(0, uint(size), {.READ}, {.SHARED}, fd, 0)
				if err == .NONE {
					pool.data = ([^]u8)(ptr)[:size]
				}
			}
			c.objects[nid] = {.Shm_Pool, 1, pool}
		case 1:
			destroyed(c, id)
		}
	case .Shm_Pool:
		pool := (^Pool)(obj.ptr)
		switch op {
		case 0:
			nid := r_u32(r)
			b := new(Buffer)
			b.id = nid
			b.pool = pool
			b.offset = int(r_i32(r))
			b.w = int(r_i32(r))
			b.h = int(r_i32(r))
			b.stride = int(r_i32(r))
			b.format = r_u32(r)
			pool.refs += 1
			c.objects[nid] = {.Buffer, 1, b}
		case 1:
			pool_unref(pool)
			destroyed(c, id)
		case 2:
			size := int(r_i32(r))
			if size > pool.size {
				if pool.data != nil {
					linux.munmap(raw_data(pool.data), uint(pool.size))
				}
				ptr, err := linux.mmap(0, uint(size), {.READ}, {.SHARED}, pool.fd, 0)
				if err == .NONE {
					pool.data = ([^]u8)(ptr)[:size]
					pool.size = size
				}
			}
		}
	case .Buffer:
		if op == 0 {
			b := (^Buffer)(obj.ptr)
			// a surface may still point at it as its pending buffer
			for _, o in c.objects {
				if o.kind == .Surface {
					s := (^Surface)(o.ptr)
					if s.pend_buffer == b {
						s.pend_buffer = nil
					}
					if s.cur_buffer == b {
						s.cur_buffer = nil
					}
				}
			}
			pool_unref(b.pool)
			free(b)
			destroyed(c, id)
		}
	case .Seat:
		switch op {
		case 0:
			nid := r_u32(r)
			c.objects[nid] = {.Pointer, obj.version, nil}
			append(&c.pointers, nid)
		case 1:
			nid := r_u32(r)
			c.objects[nid] = {.Keyboard, obj.version, nil}
			append(&c.keyboards, nid)
			keyboard_init(c, nid, obj.version)
		case 2:
			c.objects[r_u32(r)] = {.Touch, obj.version, nil}
		case 3:
			destroyed(c, id)
		}
	case .Pointer:
		switch op {
		case 0: // set_cursor: a surface image; the chrome draws its own cursor
			_ = r_u32(r)
			cs := surface_of(c, r_u32(r))
			if cs != nil {
				cs.role = .Cursor
			}
		case 1:
			remove_id(&c.pointers, id)
			destroyed(c, id)
		}
	case .Keyboard:
		if op == 0 {
			remove_id(&c.keyboards, id)
			destroyed(c, id)
		}
	case .Output:
		if op == 0 {
			remove_id(&c.outputs, id)
			destroyed(c, id)
		}
	case .Wm_Base:
		switch op {
		case 0:
			destroyed(c, id)
		case 1:
			c.objects[r_u32(r)] = {.Positioner, obj.version, new(Positioner)}
		case 2:
			nid := r_u32(r)
			s := surface_of(c, r_u32(r))
			if s == nil {
				post_error(c, id, 0, "no surface")
				return
			}
			x := new(Xdg_Surface)
			x.id = nid
			x.surface = s
			s.xdg = x
			c.objects[nid] = {.Xdg_Surface, obj.version, x}
		case 3:
		}
	case .Positioner:
		pos := (^Positioner)(obj.ptr)
		switch op {
		case 0:
			free(pos)
			destroyed(c, id)
		case 1:
			pos.w = int(r_i32(r))
			pos.h = int(r_i32(r))
		case 2:
			pos.ax = int(r_i32(r))
			pos.ay = int(r_i32(r))
			pos.aw = int(r_i32(r))
			pos.ah = int(r_i32(r))
		case 3:
			pos.anchor = r_u32(r)
		case 4:
			pos.gravity = r_u32(r)
		case 5:
			pos.adjust = r_u32(r)
		case 6:
			pos.off_x = int(r_i32(r))
			pos.off_y = int(r_i32(r))
		}
	case .Xdg_Surface:
		xs := (^Xdg_Surface)(obj.ptr)
		switch op {
		case 0:
			if xs.surface != nil {
				xs.surface.xdg = nil
			}
			destroyed(c, id)
		case 1:
			nid := r_u32(r)
			xs.role_id = nid
			xs.surface.role = .Toplevel
			c.objects[nid] = {.Toplevel, obj.version, xs}
			g.toplevel = xs
			g_client = c // the client with the window is the one input goes to
			logf("toplevel %d created (surface %d)", nid, xs.surface.id)
			configure_toplevel(c)
		case 2:
			nid := r_u32(r)
			pid := r_u32(r)
			posid := r_u32(r)
			xs.role_id = nid
			xs.is_popup = true
			xs.surface.role = .Popup
			if po, pok := c.objects[pid]; pok && po.kind == .Xdg_Surface {
				xs.parent = (^Xdg_Surface)(po.ptr)
			} else {
				xs.parent = g.toplevel
			}
			if po, pok := c.objects[posid]; pok && po.kind == .Positioner {
				xs.pos = (^Positioner)(po.ptr)^
			}
			c.objects[nid] = {.Popup, obj.version, xs}
			place_popup(xs)
			append(&g.popups, xs)
			event(c, nid, 0, i32(xs.x), i32(xs.y), i32(xs.pos.w), i32(xs.pos.h))
			g.serial += 1
			event(c, xs.id, 0, g.serial)
		case 3:
			xs.geom = {int(r_i32(r)), int(r_i32(r)), int(r_i32(r)), int(r_i32(r))}
			xs.has_geom = true
		case 4:
			xs.configured = true
		}
	case .Toplevel:
		xs := (^Xdg_Surface)(obj.ptr)
		switch op {
		case 0:
			logf("toplevel %d destroyed", xs.role_id)
			if g.toplevel == xs {
				g.toplevel = nil
			}
			xs.surface.role = .None
			destroyed(c, id)
			damage_all()
		case 2:
			delete(xs.title)
			xs.title = strings.clone(r_string(r))
			logf("toplevel %d title %q", xs.role_id, xs.title)
		case:
		}
	case .Popup:
		xs := (^Xdg_Surface)(obj.ptr)
		switch op {
		case 0:
			remove_popup(xs)
			destroyed(c, id)
		case 1:
			_ = r_u32(r)
			_ = r_u32(r)
			xs.grab = true
			keyboard_focus_update(c)
		case 2:
			posid := r_u32(r)
			token := r_u32(r)
			if po, pok := c.objects[posid]; pok && po.kind == .Positioner {
				xs.pos = (^Positioner)(po.ptr)^
			}
			place_popup(xs)
			event(c, xs.role_id, 2, token)
			event(c, xs.role_id, 0, i32(xs.x), i32(xs.y), i32(xs.pos.w), i32(xs.pos.h))
			g.serial += 1
			event(c, xs.id, 0, g.serial)
			damage_all()
		}
	case .Ddm:
		switch op {
		case 0:
			c.objects[r_u32(r)] = {.Data_Source, obj.version, nil}
		case 1:
			c.objects[r_u32(r)] = {.Data_Device, obj.version, nil}
		}
	case .Data_Source:
		if op == 1 {
			destroyed(c, id)
		}
	case .Data_Device:
		if op == 2 {
			destroyed(c, id)
		}
	case .Shape_Manager:
		switch op {
		case 0:
			destroyed(c, id)
		case 1:
			nid := r_u32(r)
			c.objects[nid] = {.Shape_Device, 1, nil}
			append(&c.shape_devices, nid)
		}
	case .Shape_Device:
		switch op {
		case 0:
			remove_id(&c.shape_devices, id)
			destroyed(c, id)
		case 1:
			_ = r_u32(r)
			cursor_shape(r_u32(r))
		}
	}
}

remove_id :: proc(list: ^[dynamic]u32, id: u32) {
	for x, i in list {
		if x == id {
			ordered_remove(list, i)
			return
		}
	}
}

bind_global :: proc(c: ^Client, kind: Kind, id: u32, version: u32) {
	c.objects[id] = {kind, version, nil}
	#partial switch kind {
	case .Shm:
		event(c, id, 0, u32(0)) // ARGB8888
		event(c, id, 0, u32(1)) // XRGB8888
	case .Seat:
		event(c, id, 0, u32(3)) // pointer | keyboard
		if version >= 2 {
			event(c, id, 1, "palm")
		}
	case .Output:
		append(&c.outputs, id)
		send_output(c, id, version)
	case .Wm_Base:
	}
}

send_output :: proc(c: ^Client, id: u32, version: u32) {
	event(c, id, 0, i32(0), i32(0), i32(g.w * 254 / 960), i32(g.h * 254 / 960), i32(0), "Palmy", "browser view", i32(0))
	event(c, id, 1, u32(3), i32(g.w * g.scale), i32(g.h * g.scale), i32(60000))
	if version >= 2 {
		event(c, id, 3, i32(g.scale))
	}
	if version >= 4 {
		event(c, id, 4, "PALM-1")
		event(c, id, 5, "Palmy browser view")
	}
	if version >= 2 {
		event(c, id, 2)
	}
}

pool_unref :: proc(p: ^Pool) {
	p.refs -= 1
	if p.refs <= 0 {
		if p.data != nil {
			linux.munmap(raw_data(p.data), uint(p.size))
		}
		linux.close(p.fd)
		free(p)
	}
}

detach_child :: proc(parent, child: ^Surface) {
	for x, i in parent.children {
		if x == child {
			ordered_remove(&parent.children, i)
			return
		}
	}
}

restack :: proc(s, sib: ^Surface, above: bool) {
	p := s.parent
	detach_child(p, s)
	if sib == p {
		if above {
			inject_at(&p.children, 0, s)
		} else {
			inject_at(&p.children, 0, s) // below the parent itself: not modelled
		}
		return
	}
	for x, i in p.children {
		if x == sib {
			inject_at(&p.children, above ? i + 1 : i, s)
			return
		}
	}
	append(&p.children, s)
}

remove_popup :: proc(xs: ^Xdg_Surface) {
	for x, i in g.popups {
		if x == xs {
			ordered_remove(&g.popups, i)
			break
		}
	}
	if xs.surface != nil {
		xs.surface.role = .None
		xs.surface.mapped = false
	}
	damage_all()
	keyboard_focus_update(g_client)
}

surface_request :: proc(c: ^Client, id: u32, s: ^Surface, op: u16, r: ^Reader) {
	switch op {
	case 0: // destroy
		s.destroyed = true
		if s.parent != nil {
			detach_child(s.parent, s)
		}
		for ch in s.children {
			ch.parent = nil
		}
		if s.xdg != nil && s.xdg.is_popup {
			remove_popup(s.xdg)
		}
		if g.pointer_focus == s {
			g.pointer_focus = nil
		}
		if g.kbd_focus == s {
			g.kbd_focus = nil
		}
		delete(s.img)
		s.img = nil
		damage_all()
		destroyed(c, id)
	case 1: // attach
		bid := r_u32(r)
		dx := int(r_i32(r))
		dy := int(r_i32(r))
		s.pend_attached = true
		s.pend_buffer = nil
		if o, ok := c.objects[bid]; ok && o.kind == .Buffer {
			s.pend_buffer = (^Buffer)(o.ptr)
		}
		s.pend_dx = dx
		s.pend_dy = dy
	case 2, 9: // damage (surface coords), damage_buffer (buffer coords)
		x := int(r_i32(r))
		y := int(r_i32(r))
		w := int(r_i32(r))
		h := int(r_i32(r))
		if op == 2 {
			sc := max(s.scale, 1)
			x, y, w, h = x * sc, y * sc, min(w, 1 << 20) * sc, min(h, 1 << 20) * sc
		}
		append(&s.pend_damage, Rect{x, y, w, h})
	case 3: // frame
		cb := r_u32(r)
		c.objects[cb] = {.Callback, 1, nil}
		append(&s.pend_frames, cb)
	case 4, 5: // opaque / input region
		_ = r_u32(r)
	case 6:
		surface_commit(c, s)
	case 7:
		_ = r_i32(r)
	case 8:
		s.pend_scale = int(r_i32(r))
	case 10:
		s.pend_dx = int(r_i32(r))
		s.pend_dy = int(r_i32(r))
	}
}

// surface_commit copies the attached buffer out (so the client can reuse it
// at once), applies the pending state and schedules a composite.
surface_commit :: proc(c: ^Client, s: ^Surface) {
	if TRACE && s.pend_attached && s.role == .Toplevel {
		pid: u32 = s.parent != nil ? s.parent.id : 0
		bw, bh := 0, 0
		if s.pend_buffer != nil {bw, bh = s.pend_buffer.w, s.pend_buffer.h}
		logf("commit surface %d role %v parent %d attached %v buffer %dx%d fmt %d at %d,%d scale %d children %d damage %v", s.id, s.role, pid, s.pend_attached, bw, bh, s.pend_buffer != nil ? s.pend_buffer.format : 99, s.sub_x, s.sub_y, s.pend_scale, len(s.children), len(s.pend_damage))
	}
	if s.pend_scale > 0 {
		s.scale = s.pend_scale
	}
	if s.pend_attached {
		s.pend_attached = false
		b := s.pend_buffer
		s.cur_buffer = b
		if b == nil {
			s.mapped = false
			damage_all()
		} else {
			full := s.w != b.w || s.h != b.h || s.img == nil
			if full {
				delete(s.img)
				s.img = make([]u32, b.w * b.h)
				s.w = b.w
				s.h = b.h
			}
			copy_damage(s, b, full)
			event(c, b.id, 0) // release: we have our own copy
			if !s.mapped {
				s.mapped = true
				damage_all()
			}
		}
	} else if s.cur_buffer != nil && len(s.pend_damage) > 0 {
		copy_damage(s, s.cur_buffer, false)
	}
	clear(&s.pend_damage)
	append(&s.frames, ..s.pend_frames[:])
	clear(&s.pend_frames)
	if !s.entered && len(c.outputs) > 0 {
		s.entered = true
		for o in c.outputs {
			event(c, s.id, 0, o)
		}
	}
	if s.role == .Toplevel && s.mapped && !g.toplevel_mapped {
		g.toplevel_mapped = true
		keyboard_focus_update(c)
	}
	g.need_compose = true
}

// copy_damage brings the damaged rectangles of a buffer into the surface's
// own image, and the view's damage along with them.
copy_damage :: proc(s: ^Surface, b: ^Buffer, full: bool) {
	if b.w != s.w || b.h != s.h || b.pool.data == nil || b.offset + b.stride * (b.h - 1) + b.w * 4 > len(b.pool.data) {
		return
	}
	opaque := b.format == 1
	rects := s.pend_damage[:]
	whole := [1]Rect{{0, 0, b.w, b.h}}
	if full || len(rects) == 0 {
		rects = whole[:]
	}
	for rr in rects {
		x0 := clamp(rr.x, 0, b.w)
		y0 := clamp(rr.y, 0, b.h)
		x1 := clamp(rr.x + rr.w, 0, b.w)
		y1 := clamp(rr.y + rr.h, 0, b.h)
		for y in y0 ..< y1 {
			src := ([^]u32)(raw_data(b.pool.data[b.offset + y * b.stride:]))
			dst := s.img[y * b.w:]
			if opaque {
				for x in x0 ..< x1 {
					dst[x] = src[x] | 0xff000000
				}
			} else {
				copy(dst[x0:x1], src[x0:x1])
			}
		}
		surface_damage(s, {x0, y0, x1 - x0, y1 - y0})
	}
}

configure_toplevel :: proc(c: ^Client) {
	xs := g.toplevel
	if xs == nil {
		return
	}
	states: [8]u8
	// activated (4) and fullscreen (2): no decorations, no shadow margin
	(^u32)(&states[0])^ = 4
	(^u32)(&states[4])^ = 2
	event(c, xs.role_id, 0, i32(g.w), i32(g.h), states[:])
	g.serial += 1
	event(c, xs.id, 0, g.serial)
}

// place_popup works out where a popup goes from its positioner: the anchor
// point on the anchor rectangle, the direction the gravity points, the
// offset, then flip and slide to keep it inside the view.
place_popup :: proc(xs: ^Xdg_Surface) {
	p := xs.pos
	ax := p.ax
	ay := p.ay
	switch p.anchor {
	case 1:
		ax += p.aw / 2 // top
	case 2:
		ax += p.aw / 2;ay += p.ah // bottom
	case 3:
		ay += p.ah / 2 // left
	case 4:
		ax += p.aw;ay += p.ah / 2 // right
	case 5: // top left
	case 6:
		ay += p.ah // bottom left
	case 7:
		ax += p.aw // top right
	case 8:
		ax += p.aw;ay += p.ah // bottom right
	case:
		ax += p.aw / 2;ay += p.ah / 2
	}
	x := ax
	y := ay
	switch p.gravity {
	case 1:
		x -= p.w / 2;y -= p.h // top
	case 2:
		x -= p.w / 2 // bottom
	case 3:
		x -= p.w;y -= p.h / 2 // left
	case 4:
		y -= p.h / 2 // right
	case 5:
		x -= p.w;y -= p.h // top left
	case 6:
		x -= p.w // bottom left
	case 7:
		y -= p.h // top right
	case 8: // bottom right
	case:
		x -= p.w / 2;y -= p.h / 2
	}
	x += p.off_x
	y += p.off_y
	// constrain against the view, in the parent's coordinates
	px, py := popup_parent_origin(xs)
	vx := px + x
	vy := py + y
	if vy + p.h > g.h && p.adjust & 8 != 0 {
		// flip y: put it above the anchor rectangle instead
		ny := py + p.ay - p.h - p.off_y
		if ny >= 0 {
			vy = ny
		}
	}
	if vx + p.w > g.w && p.adjust & 4 != 0 {
		nx := px + p.ax + p.aw - p.w - p.off_x
		if nx >= 0 {
			vx = nx
		}
	}
	if p.adjust & 1 != 0 {
		vx = clamp(vx, 0, max(0, g.w - p.w))
	}
	if p.adjust & 2 != 0 {
		vy = clamp(vy, 0, max(0, g.h - p.h))
	}
	xs.x = vx - px
	xs.y = vy - py
}

// popup_parent_origin is where the parent's window geometry starts, in view
// coordinates.
popup_parent_origin :: proc(xs: ^Xdg_Surface) -> (x, y: int) {
	par := xs.parent
	if par == nil {
		return 0, 0
	}
	if par.is_popup {
		px, py := popup_parent_origin(par)
		x = px + par.x
		y = py + par.y
	} else {
		x, y = toplevel_origin()
	}
	return
}

// toplevel_origin is where the toplevel's window geometry sits: at the
// view's corner, its shadow margin (if any) outside.
toplevel_origin :: proc() -> (x, y: int) {
	return 0, 0
}

// surface_origin is a surface's top-left corner in view coordinates
// (logical), following subsurface positions and popup placement.
surface_origin :: proc(s: ^Surface) -> (x, y: int) {
	if s.role == .Subsurface && s.parent != nil {
		px, py := surface_origin(s.parent)
		return px + s.sub_x, py + s.sub_y
	}
	if s.xdg != nil {
		gx, gy := 0, 0
		if s.xdg.has_geom {
			gx, gy = s.xdg.geom.x, s.xdg.geom.y
		}
		if s.xdg.is_popup {
			px, py := popup_parent_origin(s.xdg)
			return px + s.xdg.x - gx, py + s.xdg.y - gy
		}
		tx, ty := toplevel_origin()
		return tx - gx, ty - gy
	}
	return 0, 0
}
