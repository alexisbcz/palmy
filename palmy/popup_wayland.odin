#+build linux
package palmy

import "core:math"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Wayland: xdg_popup
// ---------------------------------------------------------------------------

@(private)
XDG_WM_BASE_CREATE_POSITIONER :: 1
@(private)
XDG_POSITIONER_DESTROY :: 0
@(private)
XDG_POSITIONER_SET_SIZE :: 1
@(private)
XDG_POSITIONER_SET_ANCHOR_RECT :: 2
@(private)
XDG_POSITIONER_SET_ANCHOR :: 3
@(private)
XDG_POSITIONER_SET_GRAVITY :: 4
@(private)
XDG_POSITIONER_SET_CONSTRAINT_ADJUSTMENT :: 5
@(private)
XDG_POSITIONER_SET_OFFSET :: 6
@(private)
XDG_SURFACE_DESTROY :: 0
@(private)
XDG_SURFACE_GET_POPUP :: 2
@(private)
XDG_POPUP_DESTROY :: 0
@(private)
XDG_POPUP_GRAB :: 1
@(private)
XDG_POPUP_REPOSITION :: 2
@(private)
SHM_FORMAT_ARGB8888 :: u32(0)

// Constraint adjustments: slide on both axes, flip on both.
@(private)
POSITIONER_ADJUST :: u32(1 | 2 | 4 | 8)

// Wl_Popup is one xdg_popup and the buffers it is painted into.
@(private)
Wl_Popup :: struct {
	id:         u64, // the popup's node id
	seen:       bool,
	grab:       bool,
	surface:    u32,
	xdg:        u32,
	popup:      u32,
	anchor:     Rect,
	size:       [2]int, // the size asked for
	opts:       Popup,
	configured: bool,
	serial:     u32,
	need_ack:   bool,
	pos:        [2]int, // the visible box, relative to the parent's geometry
	cfg_size:   [2]int,
	token:      u32,
	done:       bool, // the compositor dismissed it
	reported:   bool,

	pool:       u32,
	pool_mem:   []u8,
	buffers:    [2]Shm_Buffer,
	buf_size:   [2]int, // device pixels, margin included
	scale:      int,
	canvas:     Canvas,
	last_hash:  u64,
}

// popup_positioner builds a positioner for a box of `size` against `anchor`.
@(private)
popup_positioner :: proc(w: ^Window, anchor: Rect, size: [2]int, opts: Popup) -> u32 {
	c := &w.conn
	pos := new_id(c, .Positioner)
	request(c, w.wl.xdg_wm_base, XDG_WM_BASE_CREATE_POSITIONER, Obj(pos))
	request(c, pos, XDG_POSITIONER_SET_SIZE, i32(size.x), i32(size.y))
	ax := i32(math.floor(anchor.x))
	ay := i32(math.floor(anchor.y))
	aw := max(i32(math.ceil(anchor.x + anchor.w)) - ax, 1)
	ah := max(i32(math.ceil(anchor.y + anchor.h)) - ay, 1)
	request(c, pos, XDG_POSITIONER_SET_ANCHOR_RECT, ax, ay, aw, ah)
	anc, grav := popup_anchor_gravity(opts)
	request(c, pos, XDG_POSITIONER_SET_ANCHOR, anc)
	request(c, pos, XDG_POSITIONER_SET_GRAVITY, grav)
	request(c, pos, XDG_POSITIONER_SET_CONSTRAINT_ADJUSTMENT, POSITIONER_ADJUST)
	g := i32(math.round(opts.gap))
	off := [2]i32{}
	switch opts.side {
	case .Bottom:
		off = {0, g}
	case .Top:
		off = {0, -g}
	case .Right:
		off = {g, 0}
	case .Left:
		off = {-g, 0}
	}
	request(c, pos, XDG_POSITIONER_SET_OFFSET, off.x, off.y)
	return pos
}

@(private)
wl_popup_find :: proc(w: ^Window, id: u64) -> ^Wl_Popup {
	for &wp in w.wl.pop {
		if wp.id == id {
			return &wp
		}
	}
	return nil
}

// wl_popup_want makes sure the popup `id` exists with this anchor and size,
// creating, moving or resizing it as needed, and returns it. Nil when it has
// been dismissed and must not come back until the application stops asking.
@(private)
wl_popup_want :: proc(w: ^Window, id: u64, anchor: Rect, size: [2]f32, opts: Popup) -> ^Wl_Popup {
	isz := [2]int{int(size.x), int(size.y)}
	wp := wl_popup_find(w, id)
	if wp != nil {
		wp.seen = true
		if wp.done {
			return nil
		}
		if wp.size == isz && rect_same(wp.anchor, anchor) && wp.opts == opts {
			return wp
		}
		if w.wl.xdg_wm_base_ver >= 3 && wp.grab == opts.grab {
			// Move it in place: the compositor answers with a configure and
			// `repositioned`, and until then the old placement stands.
			c := &w.conn
			pos := popup_positioner(w, anchor, isz, opts)
			wp.token += 1
			request(c, wp.popup, XDG_POPUP_REPOSITION, Obj(pos), wp.token)
			request(c, pos, XDG_POSITIONER_DESTROY)
			retire_id(c, pos)
			wp.anchor, wp.size, wp.opts = anchor, isz, opts
			return wp
		}
		// No reposition before xdg_wm_base v3 (sway 1.9 offers v2): a new
		// popup in its place.
		wl_popup_destroy(w, wp)
		for i in 0 ..< len(w.wl.pop) {
			if w.wl.pop[i].id == id {
				ordered_remove(&w.wl.pop, i)
				break
			}
		}
	}
	append(&w.wl.pop, Wl_Popup{id = id, seen = true})
	wp = &w.wl.pop[len(w.wl.pop) - 1]
	wl_popup_create(w, wp, anchor, isz, opts)
	return wp
}

@(private)
rect_same :: proc(a, b: Rect) -> bool {
	return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.w - b.w) < 0.5 && abs(a.h - b.h) < 0.5
}

@(private)
wl_popup_create :: proc(w: ^Window, wp: ^Wl_Popup, anchor: Rect, size: [2]int, opts: Popup) {
	c := &w.conn
	wp.anchor, wp.size, wp.opts, wp.grab = anchor, size, opts, opts.grab
	pos := popup_positioner(w, anchor, size, opts)
	wp.surface = new_id(c, .Popup_Surface)
	request(c, w.wl.compositor, WL_COMPOSITOR_CREATE_SURFACE, Obj(wp.surface))
	wp.xdg = new_id(c, .Popup_Xdg_Surface)
	request(c, w.wl.xdg_wm_base, XDG_WM_BASE_GET_XDG_SURFACE, Obj(wp.xdg), Obj(wp.surface))
	wp.popup = new_id(c, .Xdg_Popup)
	request(c, wp.xdg, XDG_SURFACE_GET_POPUP, Obj(wp.popup), Obj(w.wl.xdg_surface), Obj(pos))
	request(c, pos, XDG_POSITIONER_DESTROY)
	retire_id(c, pos)
	if opts.grab && w.wl.seat != 0 {
		// The grab must name the input event that opened it; the compositor
		// dismisses the popup at once when the serial is stale.
		request(c, wp.popup, XDG_POPUP_GRAB, Obj(w.wl.seat), w.wl.grab_serial)
	}
	request(c, wp.surface, WL_SURFACE_COMMIT)
	conn_flush(c)
}

// wl_popups_sweep destroys the popups nobody asked for this frame, newest
// first: a grabbing popup that is not the topmost cannot be destroyed, so a
// newer grabbing one goes with it.
@(private)
wl_popups_sweep :: proc(w: ^Window) {
	for i := len(w.wl.pop) - 1; i >= 0; i -= 1 {
		wp := &w.wl.pop[i]
		if wp.seen {
			continue
		}
		if wp.grab {
			for j := len(w.wl.pop) - 1; j > i; j -= 1 {
				if w.wl.pop[j].grab && w.wl.pop[j].popup != 0 {
					wl_popup_destroy(w, &w.wl.pop[j])
					w.wl.pop[j].done = true
				}
			}
		}
		wl_popup_destroy(w, wp)
		ordered_remove(&w.wl.pop, i)
	}
	for &wp in w.wl.pop {
		wp.seen = false
	}
	conn_flush(&w.conn)
}

@(private)
wl_popup_destroy :: proc(w: ^Window, wp: ^Wl_Popup) {
	c := &w.conn
	wl_popup_free_buffers(w, wp)
	if wp.popup != 0 {
		request(c, wp.popup, XDG_POPUP_DESTROY)
		retire_id(c, wp.popup)
		wp.popup = 0
	}
	if wp.xdg != 0 {
		request(c, wp.xdg, XDG_SURFACE_DESTROY)
		retire_id(c, wp.xdg)
		wp.xdg = 0
	}
	if wp.surface != 0 {
		request(c, wp.surface, WL_SURFACE_DESTROY)
		retire_id(c, wp.surface)
		wp.surface = 0
	}
	wp.configured = false
	canvas_destroy(&wp.canvas)
	wp.canvas = {}
}

// wl_popups_close destroys every popup, newest first, before the window.
@(private)
wl_popups_close :: proc(w: ^Window) {
	#reverse for &wp in w.wl.pop {
		wl_popup_destroy(w, &wp)
	}
	delete(w.wl.pop)
	w.wl.pop = nil
}

@(private)
wl_popup_free_buffers :: proc(w: ^Window, wp: ^Wl_Popup) {
	c := &w.conn
	for &b in wp.buffers {
		if b.id != 0 {
			request(c, b.id, WL_BUFFER_DESTROY)
			retire_id(c, b.id)
		}
		b = {}
	}
	if wp.pool != 0 {
		request(c, wp.pool, WL_SHM_POOL_DESTROY)
		retire_id(c, wp.pool)
		wp.pool = 0
	}
	if wp.pool_mem != nil {
		linux.munmap(raw_data(wp.pool_mem), uint(len(wp.pool_mem)))
		wp.pool_mem = nil
	}
	wp.buf_size = {}
}

// wl_popup_alloc gives the popup two ARGB buffers of `dw` x `dh` device
// pixels. The pool's descriptor is closed by conn_flush once it is sent, as
// for the window's own (see wl_destroy_buffers).
@(private)
wl_popup_alloc :: proc(w: ^Window, wp: ^Wl_Popup, dw, dh: int) -> bool {
	wl_popup_free_buffers(w, wp)
	c := &w.conn
	stride := dw * 4
	frame := stride * dh
	total := frame * 2
	fd, ferr := linux.memfd_create("palmy-popup", {.CLOEXEC})
	if ferr != .NONE {
		return false
	}
	if linux.ftruncate(fd, i64(total)) != .NONE {
		linux.close(fd)
		return false
	}
	mem, merr := linux.mmap(0, uint(total), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		linux.close(fd)
		return false
	}
	wp.pool_mem = ([^]u8)(mem)[:total]
	wp.pool = new_id(c, .Shm_Pool)
	request(c, w.wl.shm, WL_SHM_CREATE_POOL, Obj(wp.pool), Fd(fd), i32(total))
	for i in 0 ..< 2 {
		b := &wp.buffers[i]
		b.offset = frame * i
		b.w, b.h = dw, dh
		b.id = new_id(c, .Popup_Buffer)
		b.px = (([^]u32)(raw_data(wp.pool_mem[b.offset:])))[:dw * dh]
		request(c, wp.pool, WL_SHM_POOL_CREATE_BUFFER, Obj(b.id), i32(b.offset), i32(dw), i32(dh), i32(stride), SHM_FORMAT_ARGB8888)
	}
	wp.buf_size = {dw, dh}
	return true
}

// wl_popup_paint paints a popup's subtree into its surface and commits it.
//
// palmy's rasterizer only knows opaque pixels, and a popup needs transparent
// ones: around its rounded corners and under its shadow. So it is painted
// twice, onto black and onto white. Every compositing step is src-over,
// `out = src·a + dst·(1-a)`, so the two results differ by exactly `255·(1-a)`
// and the black one *is* the premultiplied colour ARGB8888 wants. Glyphs blend
// in linear light, which this does not invert, but they sit on the popup's own
// opaque background and come out identical on both.
@(private)
wl_popup_paint :: proc(ctx: ^Ctx, pn: Popup_Node) {
	w := &ctx.app.win
	wp := wl_popup_find(w, pn.id)
	if wp == nil || !wp.configured || wp.done {
		return
	}
	c := &w.conn
	m := POPUP_MARGIN
	scale := max(w.scale, 1)
	dw := (wp.cfg_size.x + 2 * m) * scale
	dh := (wp.cfg_size.y + 2 * m) * scale
	if wp.buf_size != {dw, dh} || wp.scale != scale {
		if !wl_popup_alloc(w, wp, dw, dh) {
			return
		}
		wp.scale = scale
		wp.last_hash = 0
		request(c, wp.surface, WL_SURFACE_SET_BUFFER_SCALE, i32(scale))
	}
	b: ^Shm_Buffer
	for &bb in wp.buffers {
		if !bb.busy {
			b = &bb
			break
		}
	}
	if b == nil {
		// Both still on screen: come back when one is released.
		ctx.redraw = true
		return
	}

	// Into the surface's coordinates, where the visible box starts at the
	// margin.
	d := [2]f32{f32(m) - pn.rect.x, f32(m) - pn.rect.y}
	shift :: proc(ctx: ^Ctx, from, to: int, d: [2]f32) {
		for i in from ..< to {
			n := &ctx.nodes[i]
			n.rect.x += d.x
			n.rect.y += d.y
			n.clip.x += d.x
			n.clip.y += d.y
		}
	}
	shift(ctx, pn.idx, pn.end, d)
	defer shift(ctx, pn.idx, pn.end, -d)
	ctx.nodes[pn.idx].style.hidden = false
	defer ctx.nodes[pn.idx].style.hidden = true

	// Transitions advance as they are painted; the second pass must see the
	// same colours as the first.
	anims := make([dynamic]Anim, 0, pn.end - pn.idx, context.temp_allocator)
	for i in pn.idx ..< pn.end {
		append(&anims, widget_of(ctx, ctx.nodes[i].id).anim)
	}

	wp.canvas.px, wp.canvas.w, wp.canvas.h, wp.canvas.scale = b.px, dw, dh, f32(scale)
	reset_clip(&wp.canvas)
	clear_canvas(&wp.canvas, Color{0, 0, 0, 255})
	paint_node(ctx, &wp.canvas, pn.idx)
	black := make([]u32, len(b.px), context.temp_allocator)
	copy(black, b.px)

	for i in pn.idx ..< pn.end {
		widget_of(ctx, ctx.nodes[i].id).anim = anims[i - pn.idx]
	}
	reset_clip(&wp.canvas)
	clear_canvas(&wp.canvas, Color{255, 255, 255, 255})
	paint_node(ctx, &wp.canvas, pn.idx)

	h := u64(FNV_OFFSET)
	for i in 0 ..< len(b.px) {
		k := black[i]
		wh := b.px[i]
		lift := max((wh >> 16 & 0xff) - (k >> 16 & 0xff), (wh >> 8 & 0xff) - (k >> 8 & 0xff), (wh & 0xff) - (k & 0xff))
		a := 255 - min(lift, 255)
		r := min(k >> 16 & 0xff, a)
		g := min(k >> 8 & 0xff, a)
		bl := min(k & 0xff, a)
		v := a << 24 | r << 16 | g << 8 | bl
		b.px[i] = v
		h = (h ~ u64(v)) * FNV_PRIME
	}

	if h == wp.last_hash && !wp.need_ack {
		return
	}
	wp.last_hash = h
	if wp.need_ack {
		request(c, wp.xdg, XDG_SURFACE_ACK_CONFIGURE, wp.serial)
		wp.need_ack = false
	}
	request(c, wp.xdg, XDG_SURFACE_SET_WINDOW_GEOMETRY, i32(m), i32(m), i32(wp.cfg_size.x), i32(wp.cfg_size.y))
	request(c, wp.surface, WL_SURFACE_ATTACH, Obj(b.id), i32(0), i32(0))
	request(c, wp.surface, WL_SURFACE_DAMAGE_BUFFER, i32(0), i32(0), i32(dw), i32(dh))
	request(c, wp.surface, WL_SURFACE_COMMIT)
	conn_flush(c)
	b.busy = true
}

// wl_popup_event handles the events of a popup's objects.
@(private)
wl_popup_event :: proc(w: ^Window, kind: Obj_Kind, id: u32, opcode: u16, r: ^Reader) {
	#partial switch kind {
	case .Popup_Xdg_Surface:
		if opcode == 0 {
			for &wp in w.wl.pop {
				if wp.xdg == id {
					wp.serial = r_u32(r)
					wp.need_ack = true
					wp.configured = true
					w.input_dirty = true
				}
			}
		}
	case .Xdg_Popup:
		for &wp in w.wl.pop {
			if wp.popup != id {
				continue
			}
			switch opcode {
			case 0:
				// configure(x, y, width, height), relative to the parent's
				// window geometry -- which is the window itself.
				wp.pos = {int(r_i32(r)), int(r_i32(r))}
				wp.cfg_size = {int(r_i32(r)), int(r_i32(r))}
			case 1:
				// popup_done: dismissed by the compositor.
				wp.done = true
			case 2:
			// repositioned(token): the configure that follows is for it.
			}
			w.input_dirty = true
		}
	case .Popup_Buffer:
		if opcode == 0 {
			for &wp in w.wl.pop {
				for &b in wp.buffers {
					if b.id == id {
						b.busy = false
					}
				}
			}
		}
	}
}

// wl_popup_origin is where the surface `id`'s (0, 0) lies in window
// coordinates, for mapping pointer events; ok is false for the window's own.
@(private)
wl_popup_origin :: proc(w: ^Window, id: u32) -> (origin: [2]f32, ok: bool) {
	for wp in w.wl.pop {
		if wp.surface == id && id != 0 {
			return {f32(wp.pos.x - POPUP_MARGIN), f32(wp.pos.y - POPUP_MARGIN)}, true
		}
	}
	return {}, false
}

