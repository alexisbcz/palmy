// snap.odin — where a window goes when it is not where the user left it.
//
// Maximize, edge snapping, fullscreen and the restore that undoes each of
// them are one mechanism, because the promise the window manager makes about
// them is one promise (UX.md, principle 4): every transition that changes a
// window's geometry records what it replaced, and undoing it returns to that
// exactly, pixel for pixel.
//
// The records live in the window's Ws_Win:
//
//   t.saved       the content rect before maximize (Toplevel's own field)
//   m.max_snap    the snap zone to go back to when that maximize is undone
//   m.snap        the zone a floating window is snapped to
//   m.pre_snap    the free-floating rect before it was snapped
//   m.fs_saved    the rect before fullscreen, and whether it was maximized
//
// A tiled window needs none of them: the layout already knows where it goes,
// and a maximized tiled window keeps its cell (workspace.odin, tile_windows),
// so restoring is clearing a flag.
//
// The zone and rectangle arithmetic is pure — rectangles in, rectangles out —
// so `wm --selftest` can pin it down without a screen.
package wm

import "core:fmt"

Snap :: enum u8 {
	None,
	Left,
	Right,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
	Left_Third,
	Left_Two_Thirds,
	Right_Third,
	Right_Two_Thirds,
	// Only ever a *target* while dragging: releasing in the top zone
	// maximizes, it does not snap.
	Maximize,
}

SNAP_EDGE :: 8 // pointer within this many px of an output edge
SNAP_CORNER :: 40 // ...and within this of a corner means a quarter

// snap_zone_at is the drag target for a pointer position on an output. The
// top zone starts at the top of the bar, so throwing a window at the top of
// the screen maximizes it whether or not the pointer stopped on the bar. The
// bottom edge alone does nothing: it is where the taskbar would be, and a
// window nudged down should not suddenly fill a half.
snap_zone_at :: proc(px, py: int, out: Tile_Rect, bar_h: int, edge := SNAP_EDGE, corner := SNAP_CORNER) -> Snap {
	left := px <= out.x + edge
	right := px >= out.x + out.w - 1 - edge
	top := py <= out.y + bar_h + edge
	bottom := py >= out.y + out.h - 1 - edge
	near_top := py <= out.y + bar_h + corner
	near_bottom := py >= out.y + out.h - 1 - corner
	near_left := px <= out.x + corner
	near_right := px >= out.x + out.w - 1 - corner
	switch {
	case left:
		return near_top ? .Top_Left : (near_bottom ? .Bottom_Left : .Left)
	case right:
		return near_top ? .Top_Right : (near_bottom ? .Bottom_Right : .Right)
	case top:
		return near_left ? .Top_Left : (near_right ? .Top_Right : .Maximize)
	case bottom:
		return near_left ? .Bottom_Left : (near_right ? .Bottom_Right : .None)
	}
	return .None
}

// snap_frame is the *frame* rectangle (title bar and border included) a zone
// gives a window inside `area`, the work area less the outer gaps; `gap` is
// the inner gap between two snapped neighbours. `full` is the work area with
// no gaps at all, which is what maximize fills.
snap_frame :: proc(z: Snap, area, full: Tile_Rect, gap: int) -> Tile_Rect {
	w2 := (area.w - gap) / 2
	h2 := (area.h - gap) / 2
	w3 := (area.w - 2 * gap) / 3
	rx := area.x + w2 + gap
	rw := area.w - w2 - gap
	by := area.y + h2 + gap
	bh := area.h - h2 - gap
	switch z {
	case .None:
		return area
	case .Maximize:
		return full
	case .Left:
		return {area.x, area.y, w2, area.h}
	case .Right:
		return {rx, area.y, rw, area.h}
	case .Top_Left:
		return {area.x, area.y, w2, h2}
	case .Top_Right:
		return {rx, area.y, rw, h2}
	case .Bottom_Left:
		return {area.x, by, w2, bh}
	case .Bottom_Right:
		return {rx, by, rw, bh}
	case .Left_Third:
		return {area.x, area.y, w3, area.h}
	case .Left_Two_Thirds:
		return {area.x, area.y, area.w - w3 - gap, area.h}
	case .Right_Third:
		return {area.x + area.w - w3, area.y, w3, area.h}
	case .Right_Two_Thirds:
		return {area.x + w3 + gap, area.y, area.w - w3 - gap, area.h}
	}
	return area
}

// snap_is_left / snap_is_right say which side of the screen a zone hugs,
// for the keyboard cycle and for snap groups (P1-10).
snap_is_left :: proc(z: Snap) -> bool {
	#partial switch z {
	case .Left, .Top_Left, .Bottom_Left, .Left_Third, .Left_Two_Thirds:
		return true
	}
	return false
}

snap_is_right :: proc(z: Snap) -> bool {
	#partial switch z {
	case .Right, .Top_Right, .Bottom_Right, .Right_Third, .Right_Two_Thirds:
		return true
	}
	return false
}

// snap_key is the keyboard snap table (UX.md P0-5), as a pure function from
// the current zone (and maximized flag) and an arrow to the next state.
// `restore` means "back to the free-floating rect", `minimize` is Super+Down
// on a window that is already free.
Snap_Key_Result :: struct {
	zone:     Snap, // .Maximize to maximize, .None with restore/minimize
	restore:  bool,
	minimize: bool,
}

snap_key :: proc(cur: Snap, maximized: bool, dir: Cfg_Dir) -> Snap_Key_Result {
	if maximized {
		switch dir {
		case .Left:
			return {zone = .Left}
		case .Right:
			return {zone = .Right}
		case .Up:
			return {zone = .Maximize}
		case .Down:
			return {restore = true}
		}
	}
	switch dir {
	case .Left:
		#partial switch cur {
		case .Left:
			return {zone = .Left_Third}
		case .Left_Third:
			return {zone = .Left_Two_Thirds}
		case .Left_Two_Thirds:
			return {zone = .Left}
		case .Top_Right:
			return {zone = .Top_Left}
		case .Bottom_Right:
			return {zone = .Bottom_Left}
		}
		if snap_is_right(cur) {
			return {restore = true}
		}
		return {zone = .Left}
	case .Right:
		#partial switch cur {
		case .Right:
			return {zone = .Right_Third}
		case .Right_Third:
			return {zone = .Right_Two_Thirds}
		case .Right_Two_Thirds:
			return {zone = .Right}
		case .Top_Left:
			return {zone = .Top_Right}
		case .Bottom_Left:
			return {zone = .Bottom_Right}
		}
		if snap_is_left(cur) {
			return {restore = true}
		}
		return {zone = .Right}
	case .Up:
		#partial switch cur {
		case .Left, .Left_Third, .Left_Two_Thirds, .Bottom_Left:
			return {zone = .Top_Left}
		case .Right, .Right_Third, .Right_Two_Thirds, .Bottom_Right:
			return {zone = .Top_Right}
		}
		return {zone = .Maximize}
	case .Down:
		#partial switch cur {
		case .Top_Left:
			return {zone = .Bottom_Left}
		case .Top_Right:
			return {zone = .Bottom_Right}
		case .None:
			return {minimize = true}
		}
		return {restore = true}
	}
	return {}
}

// ---------------------------------------------------------------------------
// Rectangles of a live window
// ---------------------------------------------------------------------------

// win_fixed is a window whose client pinned its size: no resize affordance,
// no maximize, no snapping to a zone it could not fill.
win_fixed :: proc(t: ^Toplevel) -> bool {
	return t.max_w > 0 && t.max_h > 0 && t.max_w == t.min_w && t.max_h == t.min_h
}

// ws_work_area is an output less the bar: what maximize fills.
ws_work_area :: proc(s: ^Server, oi: int) -> Tile_Rect {
	ox, oy, ow, oh := ws_output_rect(s, oi)
	bar := ws_bar_h(s)
	return {ox, oy + bar, ow, max(oh - bar, MIN_H)}
}

win_output :: proc(s: ^Server, t: ^Toplevel) -> int {
	return ws_output_at(s, t.x + t.w / 2, t.y)
}

// win_set_frame moves and sizes a window so its frame is `fr`, within the
// client's own limits, and configures it. The content rect follows from the
// frame through the window's own title and border sizes.
win_set_frame :: proc(s: ^Server, t: ^Toplevel, fr: Tile_Rect) {
	bw := ws_border(t)
	th := ws_title_h(t)
	win_set_rect(s, t, fr.x + bw, fr.y + th, fr.w - 2 * bw, fr.h - th - bw)
}

// win_set_rect is the one place a window's content rect is changed by the
// window manager on the user's behalf, so the animation of it (anim.odin)
// has one place to start from.
win_set_rect :: proc(s: ^Server, t: ^Toplevel, x, y, w, h: int) {
	nw := max(w, max(MIN_W, t.min_w))
	nh := max(h, max(MIN_H, t.min_h))
	if t.max_w > 0 {nw = min(nw, t.max_w)}
	if t.max_h > 0 {nh = min(nh, t.max_h)}
	anim_geom_begin(s, t)
	t.x, t.y = x, y
	t.anchor_x, t.anchor_y = false, false
	t.req_w, t.req_h = nw, nh
	if ws_alive(s, t) || s.listen == 0 {
		send_configure(s, t, nw, nh)
	}
	s.needs_layout = true
	s.dirty = true
}

win_rect :: proc(t: ^Toplevel) -> [4]int {
	return {t.x, t.y, t.req_w, t.req_h}
}

// ---------------------------------------------------------------------------
// Maximize
// ---------------------------------------------------------------------------

set_maximized :: proc(s: ^Server, t: ^Toplevel, on: bool) {
	if t == nil || on == t.maximized {
		return
	}
	m := ws_win(t)
	if on {
		if win_fixed(t) || m.fullscreen {
			return
		}
		t.saved = win_rect(t)
		m.max_snap = m.snap
		m.snap = .None
		t.maximized = true
		win_set_frame(s, t, ws_work_area(s, win_output(s, t)))
	} else {
		t.maximized = false
		switch {
		case ws_in_layout(s, t):
			// The layout still holds its cell; the next pass puts it back.
			// The configure is still needed: the maximized state changed.
			anim_geom_begin(s, t)
			if ws_alive(s, t) || s.listen == 0 {
				send_configure(s, t, t.req_w, t.req_h)
			}
			t.last_cfg_w = -1 // make tile_place configure it into the cell
		case m.max_snap != .None:
			z := m.max_snap
			m.max_snap = .None
			snap_place(s, t, z)
		case:
			r := t.saved
			win_set_rect(s, t, r[0], r[1], max(r[2], MIN_W), max(r[3], MIN_H))
		}
	}
	ws_restack(s)
	s.needs_layout = true
	s.dirty = true
}

toggle_maximize :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	set_maximized(s, t, !t.maximized)
}

// ---------------------------------------------------------------------------
// Snapping
// ---------------------------------------------------------------------------

// snap_apply snaps a window to a zone, recording what it replaces. A tiled
// window snapped from the keyboard or a drag leaves the layout: a snap is a
// floating arrangement by definition.
snap_apply :: proc(s: ^Server, t: ^Toplevel, z: Snap) {
	if t == nil || z == .None {
		return
	}
	if z == .Maximize {
		set_maximized(s, t, true)
		return
	}
	if win_fixed(t) {
		return
	}
	m := ws_win(t)
	switch {
	case t.maximized:
		// Snapping a maximized window: the free rect it returns to is the
		// one from before the maximize.
		t.maximized = false
		if m.max_snap == .None {
			m.pre_snap = t.saved
		}
		m.max_snap = .None
	case m.snap == .None && ws_in_layout(s, t):
		m.pre_snap = snap_default_float(s, t)
		m.floating = true
	case m.snap == .None:
		m.pre_snap = win_rect(t)
	}
	m.auto_float = false
	snap_place(s, t, z)
	ws_restack(s)
}

// snap_place gives a window a zone's rectangle, without touching pre_snap.
snap_place :: proc(s: ^Server, t: ^Toplevel, z: Snap) {
	m := ws_win(t)
	m.snap = z
	oi := win_output(s, t)
	win_set_frame(s, t, snap_frame(z, tile_area(s, oi), ws_work_area(s, oi), s.cfg.gaps_in))
}

// snap_release returns a snapped window to the rect it had before.
snap_release :: proc(s: ^Server, t: ^Toplevel) {
	m := ws_win(t)
	if m.snap == .None {
		return
	}
	m.snap = .None
	r := m.pre_snap
	win_set_rect(s, t, r[0], r[1], r[2], r[3])
}

// snap_default_float is the size a tiled window floats at when it has never
// floated before: its tile, unless the tile is most of the screen, in which
// case something clearly smaller, so that it reads as floating.
snap_default_float :: proc(s: ^Server, t: ^Toplevel) -> [4]int {
	m := ws_win(t)
	if m.have_float {
		return m.float_rect
	}
	_, _, ow, oh := ws_output_rect(s, win_output(s, t))
	w, h := t.req_w, t.req_h
	if w > ow * 2 / 3 || h > (oh - ws_bar_h(s)) * 2 / 3 {
		w = max(ow * 5 / 9, t.min_w)
		h = max((oh - ws_bar_h(s)) * 5 / 8, t.min_h)
	}
	return {t.x + (t.req_w - w) / 2, t.y + (t.req_h - h) / 2, w, h}
}

// snap_keyboard is Super+Left/Right/Up/Down (UX.md P0-5). On a floating
// window it walks the snap table; on a tiled one the keys keep their tiling
// meaning: Up maximizes, Down restores, Left and Right move focus.
snap_keyboard :: proc(s: ^Server, dir: Cfg_Dir) {
	t := s.focus
	if t == nil {
		return
	}
	m := ws_win(t)
	if ws_in_layout(s, t) {
		switch dir {
		case .Up:
			set_maximized(s, t, true)
		case .Down:
			if t.maximized {
				set_maximized(s, t, false)
			} else {
				minimize_window(s, t)
			}
		case .Left, .Right:
			if t.maximized {
				snap_apply(s, t, dir == .Left ? .Left : .Right)
			} else {
				ws_focus_dir(s, dir)
			}
		}
		return
	}
	r := snap_key(m.snap, t.maximized, dir)
	switch {
	case r.minimize:
		minimize_window(s, t)
	case r.restore:
		if t.maximized {
			set_maximized(s, t, false)
		}
		snap_release(s, t)
	case r.zone != .None:
		snap_apply(s, t, r.zone)
	}
}

// ---------------------------------------------------------------------------
// Restore under the pointer (UX.md P0-4)
// ---------------------------------------------------------------------------

// grab_restore_x is where a window's frame goes so that the pointer keeps its
// relative position across the title bar when the frame changes width from
// old_w to new_w: grabbed at 75% of a maximized title, still at 75% of the
// restored one. Clamped so the pointer stays on the title, clear of the
// buttons (`keep_l` on the left, `keep_r` on the right).
grab_restore_x :: proc(px, old_x, old_w, new_w, keep_l, keep_r: int) -> int {
	if old_w <= 0 {
		return px - new_w / 2
	}
	x := px - (px - old_x) * new_w / old_w
	x = min(x, px - keep_l)
	x = max(x, px - (new_w - keep_r))
	return x
}

// ix_restore_for_move is what the first pixel of a drag does to a window that
// is maximized, snapped or tiled: it gives it back its free-floating size and
// puts it under the pointer at the same relative grab point. Returns false
// when the window was already free and nothing changed.
ix_restore_for_move :: proc(s: ^Server, t: ^Toplevel, mp: [2]int) -> bool {
	m := ws_win(t)
	w, h: int
	switch {
	case t.maximized:
		if m.max_snap != .None {
			w, h = m.pre_snap[2], m.pre_snap[3]
		} else {
			w, h = t.saved[2], t.saved[3]
		}
		t.maximized = false
		m.max_snap = .None
		m.snap = .None
		if ws_in_layout(s, t) {
			m.floating = true
			r := snap_default_float(s, t)
			w, h = r[2], r[3]
		}
	case m.snap != .None:
		w, h = m.pre_snap[2], m.pre_snap[3]
		m.snap = .None
	case ws_in_layout(s, t):
		r := snap_default_float(s, t)
		w, h = r[2], r[3]
		m.floating = true
	case:
		return false
	}
	m.auto_float = false
	w = max(w, MIN_W, t.min_w)
	h = max(h, MIN_H, t.min_h)
	fr := frame_rect(t)
	bw := ws_border(t)
	th := ws_title_h(t)
	fw := w + 2 * bw
	_, bw_r := frame_buttons_extent(t)
	fx := grab_restore_x(mp.x, int(fr.x), int(fr.w), fw, 12, bw_r + 12)
	// Vertically, the pointer keeps its offset into the title bar.
	dy := clamp(mp.y - int(fr.y), 2, max(th - 2, 2))
	fy := mp.y - dy
	t.x, t.y = fx + bw, fy + th
	t.anchor_x, t.anchor_y = false, false
	t.req_w, t.req_h = w, h
	if ws_alive(s, t) || s.listen == 0 {
		send_configure(s, t, w, h)
	}
	ws_restack(s)
	raise_window(s, t)
	s.needs_layout = true
	s.dirty = true
	return true
}

// ---------------------------------------------------------------------------
// Fullscreen (P1-4)
// ---------------------------------------------------------------------------

set_fullscreen :: proc(s: ^Server, t: ^Toplevel, on: bool) {
	if t == nil {
		return
	}
	m := ws_win(t)
	if m.fullscreen == on {
		return
	}
	if on {
		m.fs_saved = win_rect(t)
		m.fs_was_max = t.maximized
		t.maximized = false
		m.fullscreen = true
		ox, oy, ow, oh := ws_output_rect(s, win_output(s, t))
		anim_geom_begin(s, t)
		t.x, t.y = ox, oy
		t.req_w, t.req_h = ow, oh
		t.anchor_x, t.anchor_y = false, false
		if ws_alive(s, t) || s.listen == 0 {
			send_configure(s, t, ow, oh)
		}
		raise_window(s, t)
	} else {
		m.fullscreen = false
		t.maximized = m.fs_was_max
		r := m.fs_saved
		win_set_rect(s, t, r[0], r[1], r[2], r[3])
		if ws_in_layout(s, t) {
			t.last_cfg_w = -1
		}
	}
	ws_restack(s)
	s.needs_layout = true
	s.dirty = true
}

toggle_fullscreen :: proc(s: ^Server, t: ^Toplevel) {
	if t != nil {
		set_fullscreen(s, t, !ws_fullscreen(t))
	}
}

// ---------------------------------------------------------------------------
// Edge resistance (P1-9)
// ---------------------------------------------------------------------------

// snap_resist nudges a proposed frame position so that an edge within `dist`
// px of a target edge lands on it exactly. `targets_x` are x positions a left
// or right frame edge may stick to, `targets_y` the same for top and bottom;
// the caller builds them from the work area and the other windows (each
// neighbour contributes its edge and its edge plus the inner gap, so two
// windows end up either touching or exactly one gap apart, never 1-5 px).
snap_resist :: proc(x, y, w, h: int, targets_x, targets_y: []int, dist := 8) -> (int, int) {
	best_dx := dist + 1
	for tx in targets_x {
		for edge in ([2]int{x, x + w}) {
			d := tx - edge
			if abs(d) <= dist && abs(d) < abs(best_dx) {
				best_dx = d
			}
		}
	}
	best_dy := dist + 1
	for ty in targets_y {
		for edge in ([2]int{y, y + h}) {
			d := ty - edge
			if abs(d) <= dist && abs(d) < abs(best_dy) {
				best_dy = d
			}
		}
	}
	nx, ny := x, y
	if abs(best_dx) <= dist {
		nx += best_dx
	}
	if abs(best_dy) <= dist {
		ny += best_dy
	}
	return nx, ny
}

// snap_resist_targets collects the edges a moving window may stick to.
snap_resist_targets :: proc(s: ^Server, t: ^Toplevel) -> (xs, ys: [dynamic]int) {
	xs = make([dynamic]int, 0, 16, context.temp_allocator)
	ys = make([dynamic]int, 0, 16, context.temp_allocator)
	wa := ws_work_area(s, win_output(s, t))
	g := s.cfg.gaps_in
	append(&xs, wa.x, wa.x + wa.w)
	append(&ys, wa.y, wa.y + wa.h)
	for o in s.stack {
		if o == t || !o.mapped || o.minimized {
			continue
		}
		fr := frame_rect(o)
		l, r := int(fr.x), int(fr.x + fr.w)
		tp, b := int(fr.y), int(fr.y + fr.h)
		append(&xs, l, r, l - g, r + g)
		append(&ys, tp, b, tp - g, b + g)
	}
	return
}

// ---------------------------------------------------------------------------
// Snap groups (P1-10)
// ---------------------------------------------------------------------------

// snap_partner finds the window sharing a vertical boundary with a snapped
// one: left half with right half, a left quarter with the right quarter in
// the same row. Dragging that boundary resizes both.
snap_partner :: proc(s: ^Server, t: ^Toplevel) -> ^Toplevel {
	m, ok := ws_peek(t)
	if !ok || m.snap == .None {
		return nil
	}
	want: Snap
	#partial switch m.snap {
	case .Left, .Left_Third, .Left_Two_Thirds:
		want = .Right
	case .Right, .Right_Third, .Right_Two_Thirds:
		want = .Left
	case .Top_Left:
		want = .Top_Right
	case .Top_Right:
		want = .Top_Left
	case .Bottom_Left:
		want = .Bottom_Right
	case .Bottom_Right:
		want = .Bottom_Left
	case:
		return nil
	}
	oi := win_output(s, t)
	for o in s.stack {
		if o == t || !o.mapped || o.minimized || win_output(s, o) != oi {
			continue
		}
		om, ook := ws_peek(o)
		if !ook {
			continue
		}
		if om.snap == want || (want == .Right && snap_is_right(om.snap) && (om.snap == .Right_Third || om.snap == .Right_Two_Thirds)) || (want == .Left && snap_is_left(om.snap) && (om.snap == .Left_Third || om.snap == .Left_Two_Thirds)) {
			return o
		}
	}
	return nil
}

// snap_group_drag moves the shared boundary of a snap pair to `bx` (an x in
// compositor pixels), within both windows' minimum widths.
snap_group_drag :: proc(s: ^Server, left, right: ^Toplevel, bx: int) {
	lf := frame_rect(left)
	rf := frame_rect(right)
	g := s.cfg.gaps_in
	lo := int(lf.x) + tile_need_w(left)
	hi := int(rf.x + rf.w) - tile_need_w(right) - g
	if lo > hi {
		return
	}
	b := clamp(bx - g / 2, lo, hi)
	lw := b - int(lf.x)
	rx := b + g
	rw := int(rf.x + rf.w) - rx
	lbw := ws_border(left)
	rbw := ws_border(right)
	nl := lw - 2 * lbw
	nr := rw - 2 * rbw
	if nl != left.req_w {
		left.req_w = nl
		send_configure(s, left, nl, left.req_h)
	}
	if nr != right.req_w || right.x != rx + rbw {
		right.x = rx + rbw
		right.req_w = nr
		send_configure(s, right, nr, right.req_h)
	}
	s.dirty = true
}

snap_note :: proc(s: ^Server, t: ^Toplevel, z: Snap) {
	note(s, fmt.tprintf("%s snapped %v", title_of(t), z))
}
