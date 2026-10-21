package palmy

import "core:fmt"
import "core:math"
import "core:os"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Popups: menus, selects, comboboxes and tooltips that can leave the window.
//
//	if st.open {
//		anchor := palmy.rect_of(ui, trigger_id)      // where the trigger was drawn
//		if palmy.popup_begin(ui, anchor, palmy.POPUP_MENU) {
//			st.open = false                           // clicked elsewhere
//		}
//		shadcn.menu_content_open(ui)
//		...items...
//		palmy.end(ui)
//		palmy.popup_end(ui)
//	}
//
// What is between popup_begin and popup_end is an ordinary subtree of the
// frame: it is built, laid out, hit tested and painted by the same code as
// everything else, and an application cannot tell where it ends up. Where it
// ends up is one of two places:
//
//   - **A real popup** (Wayland, xdg_popup). palmy measures the subtree, asks
//     the compositor for a popup of that size against the anchor through an
//     xdg_positioner -- with flip and slide, so a menu near the bottom edge of
//     the *screen* opens upwards -- and paints the subtree into that surface
//     at the position the compositor chose. It can extend past the window's
//     edges. Pointer events on it are mapped back into window coordinates, so
//     hit testing does not know the difference. A grabbing popup (menus,
//     selects) takes the keyboard and pointer grab; the compositor ends it
//     when the user clicks into another client, and palmy when they click
//     anywhere else in this one.
//
//   - **Drawn in the window**, as before: offscreen (tests, parity, renders),
//     on X11, on a layer surface, with PALMY_POPUPS=0, and on any compositor
//     without xdg_shell. palmy places the popup itself with the same anchor,
//     gravity, flip and slide rules as the positioner, against the window's
//     edges, and paints it after the rest of the frame so it is on top.
//
// `popup_begin` returns true once when the popup was dismissed -- a press
// outside every popup (in the window or, for a real popup, anywhere) while a
// grabbing popup is open. That press is consumed: it does not also reach what
// is under it, which is what makes "click the trigger again to close" and
// "click away to close" both work without the trigger reopening it. Escape is
// left to the application.
//
// Which widgets use it, and the X11 decision, are written down at the end of
// this file under "Decisions".
// ---------------------------------------------------------------------------

// Popup_Side is which side of the anchor the popup opens on.
Popup_Side :: enum u8 {
	Bottom,
	Top,
	Right,
	Left,
}

// Popup_Align lines the popup up with the anchor along that side: Start is
// the left (or top) edges together, End the right (or bottom) ones.
Popup_Align :: enum u8 {
	Start,
	Center,
	End,
}

Popup :: struct {
	side:        Popup_Side,
	align:       Popup_Align,
	// Distance from the anchor, in logical pixels.
	gap:         f32,
	// Take the keyboard and pointer grab, and be dismissed by a press
	// elsewhere: menus, selects, comboboxes. A tooltip does not grab.
	grab:        bool,
	// As wide as the anchor, or wider if the content insists (a select's
	// list under its trigger).
	match_width: bool,
}

POPUP_MENU :: Popup {
	side  = .Bottom,
	align = .Start,
	gap   = 4,
	grab  = true,
}

POPUP_SELECT :: Popup {
	side        = .Bottom,
	align       = .Start,
	gap         = 4,
	grab        = true,
	match_width = true,
}

POPUP_TOOLTIP :: Popup {
	side  = .Top,
	align = .Center,
	gap   = 6,
}

// The transparent margin around a real popup's visible box, which its shadow
// is drawn into. shadcn's popups are at most `shadow-lg`.
@(private)
POPUP_MARGIN :: 16

@(private)
Popup_Node :: struct {
	idx:     int, // the popup's root in ctx.nodes (in ctx.prev, a frame later)
	end:     int, // one past its last descendant
	id:      u64,
	anchor:  Rect,
	opts:    Popup,
	rect:    Rect, // where it was laid out, in window coordinates
	surface: bool, // it lives in its own surface this frame
	ready:   bool, // ...which has been configured at this size, so it paints
}

@(private)
Popup_Ctx :: struct {
	list:      [dynamic]Popup_Node,
	prev:      [dynamic]Popup_Node,
	dismissed: map[u64]bool,
}

// popup_begin opens a popup anchored to `anchor`, a rectangle in window
// coordinates (usually `rect_of` the trigger). Build its contents, then call
// `popup_end`. Returns true when the popup was dismissed since the last frame;
// the caller should stop opening it.
popup_begin :: proc(ctx: ^Ctx, anchor: Rect, opts := POPUP_MENU) -> (dismissed: bool) {
	idx := push_node(ctx, .Box, "flex-col")
	n := &ctx.nodes[idx]
	// Out of the main tree's layout, paint, hit testing and Tab order: the
	// popup pass below does all four for it.
	n.style.hidden = true
	n.style.position = .Absolute
	n.style.no_hit = true
	append(&ctx.stack, idx)
	append(&ctx.popups.list, Popup_Node{idx = idx, end = -1, id = n.id, anchor = anchor, opts = opts})
	if ctx.popups.dismissed[n.id] {
		delete_key(&ctx.popups.dismissed, n.id)
		return true
	}
	return false
}

// popup_end closes the popup opened by the matching `popup_begin`.
popup_end :: proc(ctx: ^Ctx) {
	#reverse for &pn in ctx.popups.list {
		if pn.end < 0 {
			pn.end = len(ctx.nodes)
			break
		}
	}
	end(ctx)
}

// popup_rect is where a popup was placed last frame, in window coordinates
// (it may lie partly outside the window when it is a real popup). Zero when
// the node is not an open popup.
popup_rect :: proc(ctx: ^Ctx, id: u64) -> Rect {
	for pn in ctx.popups.prev {
		if pn.id == id {
			return pn.rect
		}
	}
	return {}
}

// popup_place is where a popup of `size` goes against `anchor` when it has to
// fit inside `bounds`: the xdg_positioner rules with flip and slide. It is
// what palmy uses whenever no compositor places the popup for it.
popup_place :: proc(anchor: Rect, size: [2]f32, opts: Popup, bounds: Rect) -> Rect {
	place :: proc(anchor: Rect, size: [2]f32, side: Popup_Side, align: Popup_Align, gap: f32) -> [2]f32 {
		along :: proc(lo, len, size: f32, align: Popup_Align) -> f32 {
			switch align {
			case .Start:
				return lo
			case .Center:
				return lo + (len - size) / 2
			case .End:
				return lo + len - size
			}
			return lo
		}
		switch side {
		case .Bottom:
			return {along(anchor.x, anchor.w, size.x, align), anchor.y + anchor.h + gap}
		case .Top:
			return {along(anchor.x, anchor.w, size.x, align), anchor.y - gap - size.y}
		case .Right:
			return {anchor.x + anchor.w + gap, along(anchor.y, anchor.h, size.y, align)}
		case .Left:
			return {anchor.x - gap - size.x, along(anchor.y, anchor.h, size.y, align)}
		}
		return {}
	}
	opposite := [Popup_Side]Popup_Side {
		.Bottom = .Top,
		.Top    = .Bottom,
		.Right  = .Left,
		.Left   = .Right,
	}
	main := opts.side == .Bottom || opts.side == .Top ? 1 : 0
	cross := 1 - main
	lo := [2]f32{bounds.x, bounds.y}
	hi := [2]f32{bounds.x + bounds.w, bounds.y + bounds.h}
	overflow :: proc(p: [2]f32, size: [2]f32, lo, hi: [2]f32, axis: int) -> f32 {
		return max(0, lo[axis] - p[axis]) + max(0, p[axis] + size[axis] - hi[axis])
	}

	p := place(anchor, size, opts.side, opts.align, opts.gap)
	// Flip: to the other side when that overflows less along the main axis.
	if overflow(p, size, lo, hi, main) > 0 {
		q := place(anchor, size, opposite[opts.side], opts.align, opts.gap)
		if overflow(q, size, lo, hi, main) < overflow(p, size, lo, hi, main) {
			p = q
		}
	}
	// Slide: along the cross axis until it is inside, the start edge winning
	// when it cannot be.
	for a in ([2]int{cross, main}) {
		if p[a] + size[a] > hi[a] {
			p[a] = hi[a] - size[a]
		}
		if p[a] < lo[a] {
			p[a] = lo[a]
		}
	}
	return {math.round(p.x), math.round(p.y), size.x, size.y}
}

// ---------------------------------------------------------------------------
// The frame's popup pass
// ---------------------------------------------------------------------------

// popups_begin_frame runs at the top of a frame, after the node arrays have
// swapped: last frame's popups become what input is routed against.
@(private)
popups_begin_frame :: proc(ctx: ^Ctx) {
	p := &ctx.popups
	p.prev, p.list = p.list, p.prev
	clear(&p.list)
	if ctx.app != nil {
		for &wp in ctx.app.win.pop {
			if wp.done && !wp.reported {
				p.dismissed[wp.id] = true
				wp.reported = true
			}
		}
	}
}

@(private)
popups_destroy :: proc(ctx: ^Ctx) {
	delete(ctx.popups.list)
	delete(ctx.popups.prev)
	delete(ctx.popups.dismissed)
}

// popup_surfaces_ok says whether this frame's popups can be real ones.
@(private)
popup_surfaces_ok :: proc(ctx: ^Ctx) -> bool {
	if ctx.app == nil {
		return false
	}
	w := &ctx.app.win
	if w.backend != .Wayland || w.wl.xdg_wm_base == 0 || w.wl.xdg_surface == 0 {
		return false
	}
	return os.get_env("PALMY_POPUPS", context.temp_allocator) != "0"
}

// popups_layout measures and places every popup of the frame. It runs after
// the main tree's layout, in painted and logic frames alike.
@(private)
popups_layout :: proc(ctx: ^Ctx) {
	p := &ctx.popups
	surfaces := popup_surfaces_ok(ctx)
	view := Rect{0, 0, ctx.viewport.x, ctx.viewport.y}
	for &pn in p.list {
		if pn.end < 0 {
			pn.end = len(ctx.nodes)
		}
		n := &ctx.nodes[pn.idx]
		n.style.hidden = false
		avail := ctx.viewport
		if surfaces {
			// A real popup is not bounded by the window.
			avail = {max(avail.x, 640), max(avail.y, 640)}
		}
		if pn.opts.match_width {
			// Offered the anchor's width, so that `w-full` rows are as wide
			// as the trigger rather than as the screen.
			avail.x = max(pn.anchor.w, 1)
		}
		size := measure(ctx, pn.idx, avail)
		if pn.opts.match_width {
			size.x = max(size.x, pn.anchor.w)
		}
		size = {math.ceil(max(size.x, 1)), math.ceil(max(size.y, 1))}

		rect := popup_place(pn.anchor, size, pn.opts, view)
		clip := view
		pn.surface = surfaces
		if surfaces {
			wp := wl_popup_want(&ctx.app.win, pn.id, pn.anchor, size, pn.opts)
			if wp != nil && wp.configured && wp.cfg_size == {int(size.x), int(size.y)} {
				rect = {f32(wp.pos.x), f32(wp.pos.y), size.x, size.y}
				pn.ready = true
			}
			m := f32(POPUP_MARGIN)
			clip = {rect.x - m, rect.y - m, rect.w + 2 * m, rect.h + 2 * m}
		}
		arrange(ctx, pn.idx, rect, clip)
		n = &ctx.nodes[pn.idx]
		n.style.hidden = true
		pn.rect = rect
		for i in pn.idx ..< pn.end {
			nn := &ctx.nodes[i]
			wd := widget_of(ctx, nn.id)
			wd.rect = nn.rect
			wd.clip = nn.clip
			wd.text_want = nn.text_want
		}
	}
	if ctx.app != nil && ctx.app.win.backend == .Wayland {
		wl_popups_sweep(&ctx.app.win)
	}
}

// popups_paint paints the frame: the main tree without its popups, then each
// popup -- on top in the window, or into its own surface.
@(private)
popups_paint :: proc(ctx: ^Ctx, canvas: ^Canvas) {
	paint_tree(ctx, canvas)
	for pn in ctx.popups.list {
		if pn.surface {
			if pn.ready {
				wl_popup_paint(ctx, pn)
			}
			continue
		}
		ctx.nodes[pn.idx].style.hidden = false
		paint_node(ctx, canvas, pn.idx)
		ctx.nodes[pn.idx].style.hidden = true
	}
}

// popup_route hit tests last frame's popups before the main tree. A point
// inside a popup's box belongs to it whatever is under it; a press outside
// every popup while a grabbing one is open dismisses them and is consumed.
// Returns true when the main tree must not be tested.
@(private)
popup_route :: proc(ctx: ^Ctx, at: [2]f32, h: ^Hit) -> bool {
	p := &ctx.popups
	if len(p.prev) == 0 {
		return false
	}
	nodes := ctx.prev[:]
	#reverse for pn in p.prev {
		if pn.idx >= len(nodes) || !rect_contains(pn.rect, at.x, at.y) {
			continue
		}
		popup_hit_children(nodes, pn.idx, at, h)
		return true
	}
	in_ := ctx.input
	if in_.pressed != {} {
		grabbed := false
		for pn in p.prev {
			if pn.opts.grab {
				p.dismissed[pn.id] = true
				grabbed = true
			}
		}
		if grabbed {
			h^ = {}
			return true
		}
	}
	return false
}

@(private)
popup_hit_children :: proc(nodes: []Node, root: int, at: [2]f32, h: ^Hit) {
	kids := make([dynamic]int, 0, 8, context.temp_allocator)
	for k := nodes[root].first_child; k >= 0; k = nodes[k].next {
		append(&kids, k)
	}
	#reverse for k in kids {
		if hit_test(nodes, k, at, h) {
			return
		}
	}
}

// popup_deepest is `deepest_at` for a point inside a popup, for the cursor.
@(private)
popup_deepest :: proc(ctx: ^Ctx, at: [2]f32) -> (idx: int, inside: bool) {
	nodes := ctx.prev[:]
	#reverse for pn in ctx.popups.prev {
		if pn.idx >= len(nodes) || !rect_contains(pn.rect, at.x, at.y) {
			continue
		}
		kids := make([dynamic]int, 0, 8, context.temp_allocator)
		for k := nodes[pn.idx].first_child; k >= 0; k = nodes[k].next {
			append(&kids, k)
		}
		#reverse for k in kids {
			if d := deepest_at(nodes, k, at); d >= 0 {
				return d, true
			}
		}
		return pn.idx, true
	}
	return -1, false
}

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

// popup_anchor_gravity turns side and alignment into xdg_positioner's anchor
// (the point of the anchor rectangle) and gravity (the direction the popup
// extends from it). 1 top, 2 bottom, 3 left, 4 right, 5 top-left,
// 6 bottom-left, 7 top-right, 8 bottom-right.
popup_anchor_gravity :: proc(opts: Popup) -> (anchor, gravity: u32) {
	switch opts.side {
	case .Bottom:
		switch opts.align {
		case .Start:
			return 6, 8
		case .Center:
			return 2, 2
		case .End:
			return 8, 6
		}
	case .Top:
		switch opts.align {
		case .Start:
			return 5, 7
		case .Center:
			return 1, 1
		case .End:
			return 7, 5
		}
	case .Right:
		switch opts.align {
		case .Start:
			return 7, 8
		case .Center:
			return 4, 4
		case .End:
			return 8, 7
		}
	case .Left:
		switch opts.align {
		case .Start:
			return 5, 6
		case .Center:
			return 3, 3
		case .End:
			return 6, 5
		}
	}
	return 2, 2
}

@(private)
wl_popup_find :: proc(w: ^Window, id: u64) -> ^Wl_Popup {
	for &wp in w.pop {
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
		for i in 0 ..< len(w.pop) {
			if w.pop[i].id == id {
				ordered_remove(&w.pop, i)
				break
			}
		}
	}
	append(&w.pop, Wl_Popup{id = id, seen = true})
	wp = &w.pop[len(w.pop) - 1]
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
	for i := len(w.pop) - 1; i >= 0; i -= 1 {
		wp := &w.pop[i]
		if wp.seen {
			continue
		}
		if wp.grab {
			for j := len(w.pop) - 1; j > i; j -= 1 {
				if w.pop[j].grab && w.pop[j].popup != 0 {
					wl_popup_destroy(w, &w.pop[j])
					w.pop[j].done = true
				}
			}
		}
		wl_popup_destroy(w, wp)
		ordered_remove(&w.pop, i)
	}
	for &wp in w.pop {
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
	#reverse for &wp in w.pop {
		wl_popup_destroy(w, &wp)
	}
	delete(w.pop)
	w.pop = nil
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
			for &wp in w.pop {
				if wp.xdg == id {
					wp.serial = r_u32(r)
					wp.need_ack = true
					wp.configured = true
					w.input_dirty = true
				}
			}
		}
	case .Xdg_Popup:
		for &wp in w.pop {
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
			for &wp in w.pop {
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
	for wp in w.pop {
		if wp.surface == id && id != 0 {
			return {f32(wp.pos.x - POPUP_MARGIN), f32(wp.pos.y - POPUP_MARGIN)}, true
		}
	}
	return {}, false
}

@(private)
popup_debugf :: proc(format: string, args: ..any) {
	if os.get_env("PALMY_TRACE_POPUP", context.temp_allocator) != "" {
		fmt.eprintfln(format, ..args)
	}
}

// ---------------------------------------------------------------------------
// Decisions
//
// Which widgets open as real popups. Everything shadcn draws as floating
// content anchored to a trigger: dropdown and context menus, the menubar's
// menus, select and combobox lists (POPUP_SELECT: at least as wide as the
// trigger), popovers and hover cards (POPUP_MENU, grabbing: they hold
// controls and close on a click away), and tooltips (POPUP_TOOLTIP: no grab,
// above the trigger, centred). shadcn's `*_popup_begin` helpers pick these.
// Dialogs, sheets, alert dialogs and toasts are not popups: they belong to the
// window (a dialog is modal *to it*, a toast is placed against its corner) and
// stay in-window. A submenu is not supported yet: xdg_popup can nest, but
// palmy parents every popup on the toplevel, so a submenu opens as a sibling.
//
// X11 stays in-window. The equivalent there is an override-redirect window,
// and it buys less than it costs: without a compositing manager (the common
// X11 setup, and Xvfb + openbox here) there is no alpha, so the popup would
// lose its shadow and rounded corners and look worse than the in-window one;
// the window manager does not place it, so palmy would have to find the
// screen and its own window's absolute position itself; and dismissal needs
// an explicit pointer grab. What it gains -- extending past the window -- is
// worth that on Wayland, where the compositor does the placing and the alpha
// is free; on X11 the in-window popup with flip and slide is kept.
// ---------------------------------------------------------------------------
