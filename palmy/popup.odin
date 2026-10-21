package palmy

import "core:math"
import "core:os"

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
//     on X11, on a layer surface, with PALMY_POPUPS=0, on any compositor
//     without xdg_shell, and on macOS and the web for now. palmy places the popup itself with the same anchor,
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
	when ODIN_OS == .Linux {
		if ctx.app != nil {
			for &wp in ctx.app.win.wl.pop {
				if wp.done && !wp.reported {
					p.dismissed[wp.id] = true
					wp.reported = true
				}
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
	when ODIN_OS != .Linux {
		// macOS and the web draw them in the window (see "Decisions").
		return false
	} else {
		if ctx.app == nil {
			return false
		}
		w := &ctx.app.win
		if w.backend != .Wayland || w.wl.xdg_wm_base == 0 || w.wl.xdg_surface == 0 {
			return false
		}
		return os.get_env("PALMY_POPUPS", context.temp_allocator) != "0"
	}
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
			when ODIN_OS == .Linux {
				wp := wl_popup_want(&ctx.app.win, pn.id, pn.anchor, size, pn.opts)
				if wp != nil && wp.configured && wp.cfg_size == {int(size.x), int(size.y)} {
					rect = {f32(wp.pos.x), f32(wp.pos.y), size.x, size.y}
					pn.ready = true
				}
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
	when ODIN_OS == .Linux {
		if ctx.app != nil && ctx.app.win.backend == .Wayland {
			wl_popups_sweep(&ctx.app.win)
		}
	}
}

// popups_paint paints the frame: the main tree without its popups, then each
// popup -- on top in the window, or into its own surface.
@(private)
popups_paint :: proc(ctx: ^Ctx, canvas: ^Canvas) {
	paint_tree(ctx, canvas)
	for pn in ctx.popups.list {
		if pn.surface {
			when ODIN_OS == .Linux {
				if pn.ready {
					wl_popup_paint(ctx, pn)
				}
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
