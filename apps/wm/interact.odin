// interact.odin — what the pointer does to windows.
//
// One state machine, run once a frame from the input palmy (nested) or
// evdev (bare metal) collected, in a fixed order of who may claim the pointer:
//
//   1. a drag-and-drop in flight (dnd.odin)
//   2. a lock screen or a layer surface above the windows (layer.odin)
//   3. the compositor's own overlays: a menu, the switcher, the overview,
//      the cheat sheet — each takes the pointer outright while it is open
//   4. an implicit grab: a button pressed in a client keeps sending that
//      client its motion and its release until every button is up, wherever
//      the pointer goes, as wl_pointer requires (UX.md P0-12)
//   5. a drag the window manager owns: armed, move, resize, split
//   6. a frame button held down, which fires on release over itself (P0-8)
//   7. the bar
//   8. ordinary hover and presses on windows and the desktop
//
// The rules it keeps (UX.md section 2): a click never re-tiles — a press on
// a title bar only *arms* a move, and nothing leaves the layout until the
// pointer has travelled 6 px (P0-1); buttons act on release; Escape during
// any drag puts everything back as it was when the drag began.
package wm

import "core:fmt"
import p "palmy:."

DRAG_THRESHOLD :: 6 // px of travel before a press on a title becomes a move
DBL_SLOP :: 4 // px two clicks may be apart and still be a double-click
SNAP_DWELL :: 0.08 // s the pointer rests in a zone before the preview shows
TIP_DELAY :: 0.6 // s of hover before a frame button's tooltip
REFLOW_GUARD :: 0.3 // s after a reflow during which a moved button ignores clicks
HOT_CORNER_DWELL :: 0.15

Ix_Mode :: enum u8 {
	None,
	Button, // a frame button is held
	Swallow, // eat everything until every button is up
	Grab, // implicit grab of a client surface
}

// Ix_Snapshot is everything a drag can change about a window, taken when
// the drag begins, so Escape can put it back exactly.
Ix_Snapshot :: struct {
	valid:     bool,
	t:         ^Toplevel,
	x, y:      int,
	w, h:      int,
	maximized: bool,
	saved:     [4]int,
	meta:      Ws_Win,
	in_layout: bool,
	free:      bool, // floating, unsnapped, unmaximized: its rect is a free rect
}

Interact :: struct {
	mode:           Ix_Mode,
	t:              ^Toplevel, // the window a held frame button belongs to
	btn_down:       Frame_Btn,
	drag_btn:       p.Mouse_Button, // which button is holding the drag
	press_at:       [2]int,
	grab_origin:    [2]int,

	// The move in progress.
	snap:           Snap,
	snap_since:     f64,
	snap_shown:     bool,
	preview_from:   p.Rect,
	preview_at:     f64,
	drop_t:         ^Toplevel,
	snapshot:       Ix_Snapshot,
	split_partner:  ^Toplevel,

	// Double-click detection on title bars (P0-2).
	last_click_t:   ^Toplevel,
	last_click_at:  f64,
	last_click_pos: [2]int,

	// Tooltips.
	tip_t:          ^Toplevel,
	tip_btn:        int,
	tip_since:      f64,

	// The reflow guard (P0-13): when a close or a minimize makes the layout
	// slide another window's button under a resting pointer, a click there
	// in the next 300 ms is not what the user aimed at.
	reflow_at:      f64,
	reflow_t:       ^Toplevel,
	reflow_btn:     int,

	// A tiled window focused from the keyboard while floating windows cover
	// it; those are drawn translucent until the pointer moves (P0-1).
	reveal_t:       ^Toplevel,

	// Focus policy inputs (P0-13): when the user last launched something and
	// last typed into a client.
	launch_at:      f64,
	typed_at:       f64,

	// A lone tap of Super opens the overview (P1-2).
	super_at:       f64,
	super_armed:    bool,

	// The top-left hot corner.
	corner_since:   f64,
	corner_fired:   bool,

	cursor:         Cursor_Shape,
	last_mp:        [2]int,
}

ix: Interact

// ix_forget drops every reference to a window that is going away.
ix_forget :: proc(s: ^Server, t: ^Toplevel) {
	if ix.t == t {
		ix.t = nil
		if ix.mode == .Button {
			ix.mode = .Swallow
		}
	}
	if ix.last_click_t == t {ix.last_click_t = nil}
	if ix.snapshot.t == t {ix.snapshot = {}}
	if ix.drop_t == t {ix.drop_t = nil}
	if ix.split_partner == t {ix.split_partner = nil}
	if ix.reveal_t == t {ix.reveal_t = nil}
	if ix.reflow_t == t {ix.reflow_t = nil}
	if ix.tip_t == t {ix.tip_t = nil}
	menu_forget(s, t)
	switcher_forget(s, t)
	overview_forget(s, t)
	anim_forget(t)
}

ix_note_reflow :: proc(s: ^Server) {
	ix.reflow_at = wall_now()
	ix.reflow_t = s.hover_t
	ix.reflow_btn = s.hover_btn
}

// ix_reveal marks a keyboard-focused tiled window that floating windows
// cover, so they are drawn see-through over it until the pointer moves.
ix_reveal :: proc(s: ^Server, t: ^Toplevel) {
	ix.reveal_t = nil
	if t == nil || !ws_in_layout(s, t) || t.maximized {
		return
	}
	fr := frame_rect(t)
	above := false
	for w in s.stack {
		if w == t {
			above = true
			continue
		}
		if above && w.mapped && !w.minimized && p.rect_overlaps(frame_rect(w), fr) {
			ix.reveal_t = t
			s.dirty = true
			return
		}
	}
}

// ix_veiled says whether a window is drawn translucent because it covers the
// window ix_reveal marked.
ix_veiled :: proc(s: ^Server, w: ^Toplevel) -> bool {
	t := ix.reveal_t
	if t == nil || w == t || s.focus != t {
		return false
	}
	if !p.rect_overlaps(frame_rect(w), frame_rect(t)) {
		return false
	}
	seen := false
	for x in s.stack {
		if x == t {
			seen = true
		}
		if x == w {
			return seen
		}
	}
	return false
}

// dbl_click_ok is the double-click test, pure: the same window, within the
// interval, within a few pixels.
dbl_click_ok :: proc(prev_t, t: ^Toplevel, prev_at, now: f64, prev_pos, pos: [2]int, interval_ms: int) -> bool {
	if prev_t == nil || prev_t != t {
		return false
	}
	if now - prev_at > f64(interval_ms) / 1000 || now < prev_at {
		return false
	}
	d := pos - prev_pos
	return abs(d.x) <= DBL_SLOP && abs(d.y) <= DBL_SLOP
}

// ---------------------------------------------------------------------------
// Drags
// ---------------------------------------------------------------------------

ix_take_snapshot :: proc(s: ^Server, t: ^Toplevel) {
	m := ws_win(t)
	ix.snapshot = Ix_Snapshot {
		valid     = true,
		t         = t,
		x         = t.x,
		y         = t.y,
		w         = t.req_w,
		h         = t.req_h,
		maximized = t.maximized,
		saved     = t.saved,
		meta      = m^,
		in_layout = ws_in_layout(s, t),
	}
	ix.snapshot.free = !ix.snapshot.in_layout && !t.maximized && m.snap == .None && !m.fullscreen
}

// ix_begin_drag starts a drag of any kind on a window.
ix_begin_drag :: proc(s: ^Server, t: ^Toplevel, kind: Drag, edges: Edges, btn := p.Mouse_Button.Left) {
	ix_take_snapshot(s, t)
	s.drag = kind
	s.drag_t = t
	s.drag_edges = edges
	s.drag_from = s_pointer
	s.drag_orig = {t.x, t.y, t.req_w, t.req_h}
	ix.drag_btn = btn
	ix.press_at = s_pointer
	ix.snap = .None
	ix.snap_shown = false
	ix.drop_t = nil
	ix.split_partner = nil
	if kind == .Resize {
		t.resizing = true
	}
	s.dirty = true
}

// ix_start_move turns an armed press (or a client's move request) into a
// move: a maximized, snapped or tiled window is restored to its free size
// under the pointer first (P0-4), and only now leaves the layout.
ix_start_move :: proc(s: ^Server, t: ^Toplevel) {
	ix_restore_for_move(s, t, s_pointer)
	m := ws_win(t)
	m.auto_float = false
	s.drag = .Move
	s.drag_from = s_pointer
	s.drag_orig = {t.x, t.y, t.req_w, t.req_h}
	ix.last_click_t = nil
	raise_window(s, t)
	s.dirty = true
}

// ix_cancel_drag is Escape during a drag: the window goes back to exactly
// what the snapshot recorded — position, size, maximized, snapped, tiled.
ix_cancel_drag :: proc(s: ^Server) {
	t := s.drag_t
	snap := ix.snapshot
	s.drag = .None
	s.drag_t = nil
	s.drag_edges = {}
	ix.snap = .None
	ix.snap_shown = false
	ix.drop_t = nil
	if t == nil || !snap.valid || snap.t != t || !ws_alive(s, t) {
		return
	}
	m := ws_win(t)
	m^ = snap.meta
	t.maximized = snap.maximized
	t.saved = snap.saved
	t.resizing = false
	t.x, t.y = snap.x, snap.y
	t.req_w, t.req_h = snap.w, snap.h
	t.anchor_x, t.anchor_y = false, false
	send_configure(s, t, snap.w, snap.h)
	t.last_cfg_w = -1
	ws_restack(s)
	s.needs_layout = true
	s.dirty = true
	ix.snapshot = {}
	ix.mode = .Swallow
}

// ix_drag_update runs a frame of the drag in progress. Returns once the
// drag has handled the pointer.
ix_drag_update :: proc(s: ^Server, in_: ^p.Input, mp: [2]int) {
	t := s.drag_t
	held := in_.down[ix.drag_btn]
	released := in_.released[ix.drag_btn] || !held
	d := mp - s.drag_from
	ctrl := .Ctrl in in_.mods

	switch s.drag {
	case .None:
	case .Armed:
		if abs(mp.x - ix.press_at.x) >= DRAG_THRESHOLD || abs(mp.y - ix.press_at.y) >= DRAG_THRESHOLD {
			ix_start_move(s, t)
			ix_move_to(s, t, mp, ctrl)
		}
	case .Move:
		ix_move_to(s, t, mp, ctrl)
	case .Resize:
		ix_resize_to(s, t, d)
	case .Split:
		ix_split_to(s, t, mp)
	}

	if released {
		ix_drag_release(s, t)
	}
	s.dirty = true
}

ix_move_to :: proc(s: ^Server, t: ^Toplevel, mp: [2]int, ctrl: bool) {
	d := mp - s.drag_from
	nx := s.drag_orig[0] + d.x
	ny := s.drag_orig[1] + d.y
	// Edge resistance (P1-9): the frame's edges stick to the work area and
	// to other windows' edges. Ctrl turns it off, with snapping.
	if !ctrl {
		bw := ws_border(t)
		th := ws_title_h(t)
		xs, ys := snap_resist_targets(s, t)
		fx, fy := snap_resist(nx - bw, ny - th, t.req_w + 2 * bw, t.req_h + th + bw, xs[:], ys[:])
		nx, ny = fx + bw, fy + th
	}
	t.x, t.y = nx, ny
	clamp_window(s, t)

	// The snap target under the pointer, and a drop target among the tiled
	// windows when this one came out of the layout.
	z := Snap.None
	if !ctrl && !win_fixed(t) {
		oi := ws_output_at(s, mp.x, mp.y)
		o := s.outputs[oi]
		z = snap_zone_at(mp.x, mp.y, {o.x, o.y, o.w, o.h}, ws_bar_h(s))
	}
	if z != ix.snap {
		ix.snap = z
		ix.snap_since = wall_now()
		ix.snap_shown = false
		ix.preview_from = {f32(mp.x), f32(mp.y), 1, 1}
	}
	if z != .None && !ix.snap_shown && wall_now() - ix.snap_since >= SNAP_DWELL {
		ix.snap_shown = true
		ix.preview_at = wall_now()
	}
	if z != .None && !ix.snap_shown {
		wake_at(ix.snap_since + SNAP_DWELL)
	}
	ix.drop_t = nil
	if z == .None && ix.snapshot.in_layout {
		#reverse for w in s.stack {
			if w == t || !w.mapped || w.minimized || !ws_in_layout(s, w) || w.maximized {
				continue
			}
			if p.rect_contains(frame_rect(w), f32(mp.x), f32(mp.y)) {
				ix.drop_t = w
				break
			}
		}
	}
}

ix_resize_to :: proc(s: ^Server, t: ^Toplevel, d: [2]int) {
	ow, oh := s.drag_orig[2], s.drag_orig[3]
	nw, nh := ow, oh
	if .Right in s.drag_edges {nw = ow + d.x}
	if .Left in s.drag_edges {nw = ow - d.x}
	if .Bottom in s.drag_edges {nh = oh + d.y}
	if .Top in s.drag_edges {nh = oh - d.y}
	nw = max(nw, max(MIN_W, t.min_w))
	nh = max(nh, max(MIN_H, t.min_h))
	if t.max_w > 0 {nw = min(nw, t.max_w)}
	if t.max_h > 0 {nh = min(nh, t.max_h)}
	t.anchor_x = .Left in s.drag_edges
	t.anchor_y = .Top in s.drag_edges
	t.anchor_right = s.drag_orig[0] + ow
	t.anchor_bottom = s.drag_orig[1] + oh
	if nw != t.last_cfg_w || nh != t.last_cfg_h {
		t.req_w, t.req_h = nw, nh
		send_configure(s, t, nw, nh)
	}
}

// ix_split_to drags a shared boundary: the master/stack edge of the master
// layout, or the boundary between two snapped windows (P1-10).
ix_split_to :: proc(s: ^Server, t: ^Toplevel, mp: [2]int) {
	if partner := ix.split_partner; partner != nil {
		lt, rt := t, partner
		if frame_rect(partner).x < frame_rect(t).x {
			lt, rt = partner, t
		}
		snap_group_drag(s, lt, rt, mp.x)
		return
	}
	idx := ws_index_of(s, t)
	if idx < 0 {
		return
	}
	w := &s.workspaces[idx]
	oi := w.output
	if oi < 0 || oi >= len(s.outputs) {
		oi = s.cur_out
	}
	area := tile_area(s, oi)
	g := s.cfg.gaps_in
	if area.w - g <= 0 {
		return
	}
	ratio := f32(mp.x - area.x - g / 2) / f32(area.w - g)
	ratio = clamp(ratio, 0.15, 0.85)
	if ratio != w.master_ratio {
		w.master_ratio = ratio
		s.needs_layout = true
	}
}

ix_drag_release :: proc(s: ^Server, t: ^Toplevel) {
	kind := s.drag
	s.drag = .None
	s.drag_t = nil
	s.drag_edges = {}
	if t == nil || !ws_alive(s, t) && s.listen != 0 {
		return
	}
	m := ws_win(t)
	switch kind {
	case .None, .Armed, .Split:
	case .Resize:
		if t.resizing {
			t.resizing = false
			send_configure(s, t, t.req_w, t.req_h)
		}
		if m.floating || !ws_in_layout(s, t) {
			m.float_rect = {t.x, t.y, t.req_w, t.req_h}
			m.have_float = true
		}
		m.snap = .None
	case .Move:
		switch {
		case ix.snap != .None:
			// The free rect to come back to is the one the window had before
			// the drag if it was free then, or the restored one it is being
			// dragged at.
			free := win_rect(t)
			if ix.snapshot.valid && ix.snapshot.t == t && ix.snapshot.free {
				free = {ix.snapshot.x, ix.snapshot.y, ix.snapshot.w, ix.snapshot.h}
			}
			z := ix.snap
			if z == .Maximize {
				t.x, t.y = free[0], free[1]
				t.req_w, t.req_h = free[2], free[3]
				set_maximized(s, t, true)
			} else if !win_fixed(t) {
				m.floating = !ws_in_layout(s, t) || m.floating
				m.floating = true
				m.pre_snap = free
				snap_place(s, t, z)
				snap_note(s, t, z)
			}
		case ix.drop_t != nil:
			// Dropped on a tiled window: take its place in the layout, and it
			// takes the place this one had.
			o := ws_win(ix.drop_t)
			a := ws_win(t)
			if ix.snapshot.valid && ix.snapshot.t == t && ix.snapshot.in_layout {
				a.seq, o.seq = o.seq, ix.snapshot.meta.seq
			} else {
				a.seq, o.seq = o.seq, a.seq
			}
			a.floating = false
			t.last_cfg_w = -1
			note(s, fmt.tprintf("%s swapped with %s", title_of(t), title_of(ix.drop_t)))
		case:
			if m.floating || !ws_in_layout(s, t) {
				m.float_rect = {t.x, t.y, t.req_w, t.req_h}
				m.have_float = true
			}
		}
		ws_restack(s)
	}
	ix.snap = .None
	ix.snap_shown = false
	ix.drop_t = nil
	ix.split_partner = nil
	ix.snapshot = {}
	s.needs_layout = true
	s.dirty = true
}

// ---------------------------------------------------------------------------
// The frame loop
// ---------------------------------------------------------------------------

handle_pointer :: proc(s: ^Server, app: ^p.App, scale: f32) {
	in_ := &app.win.input
	mp := [2]int{int(in_.mouse.x * scale), int(in_.mouse.y * scale)}
	s_pointer = mp
	moved := mp != ix.last_mp
	ix.last_mp = mp
	if moved {
		if ix.reveal_t != nil {
			ix.reveal_t = nil
			s.dirty = true
		}
		s.dirty = true
	}
	any_press := in_.pressed[.Left] || in_.pressed[.Right] || in_.pressed[.Middle]
	if any_press {
		ix.super_armed = false
	}
	any_down := in_.down[.Left] || in_.down[.Right] || in_.down[.Middle]

	// A drag owns the pointer outright, including off the surface: the drop
	// target is decided by where the cursor is, not by what we are hovering.
	if dnd_active() {
		dnd_update(s, mp.x, mp.y, any_down)
		ix.cursor = .Grabbing
		return
	}

	if !in_.over_surface {
		set_ptr_focus(s, nil, 0, 0)
		s.hover_t = nil
		s.hover_btn = 0
		return
	}

	// A lock surface, or a layer surface above the windows, owns the pointer
	// before the window manager's own hit testing gets a look.
	if ix.mode != .Grab && s.drag == .None && overlay_pointer(s, app, mp) {
		s.hover_t = nil
		s.hover_btn = 0
		ix.cursor = .Client
		return
	}

	// The compositor's overlays take the pointer while they are open.
	if menu_pointer(s, app, in_, mp) || cheat_pointer(s, app, in_, mp) || switcher_pointer(s, app, in_, mp) || overview_pointer(s, app, in_, mp) {
		set_ptr_focus(s, nil, 0, 0)
		s.hover_t = nil
		s.hover_btn = 0
		ix.cursor = .Default
		return
	}

	switch ix.mode {
	case .Swallow:
		if !any_down {
			ix.mode = .None
		}
		return
	case .Grab:
		ix_grab_frame(s, in_, mp)
		return
	case .Button:
		ix_button_frame(s, in_, mp)
		return
	case .None:
	}

	// An in-progress drag owns the pointer — unless the window it was
	// dragging has gone. A client that crashes mid-drag used to leave
	// `drag_t` pointing at freed memory and the next motion dereferenced it.
	if s.drag != .None && (s.drag_t == nil || (s.listen != 0 && !ws_alive(s, s.drag_t)) || !s.drag_t.mapped) {
		s.drag = .None
		s.drag_t = nil
		s.drag_edges = {}
	}
	if s.drag != .None && s.drag_t != nil {
		ix_drag_update(s, in_, mp)
		switch s.drag {
		case .Move:
			ix.cursor = .Move
		case .Resize:
			ix.cursor = cursor_for_edges(s.drag_edges)
		case .Split:
			ix.cursor = .EW
		case .Armed, .None:
			ix.cursor = .Default
		}
		return
	}

	s.cur_out = ws_output_at(s, mp.x, mp.y)

	// The hot corner (P1-2): the pointer pushed into the top-left pixel for
	// 150 ms opens the overview, once per visit.
	if s.cfg.hot_corner && !session.kiosk && !any_down {
		o := s.outputs[s.cur_out]
		if mp.x <= o.x && mp.y <= o.y {
			// Only a pointer that was pushed there counts: one that merely
			// starts at 0,0 (bare metal, before the first motion) does not.
			if ix.corner_since == 0 && moved {
				ix.corner_since = wall_now()
			}
			if ix.corner_since == 0 {
				ix.corner_fired = true
			}
			if !ix.corner_fired && wall_now() - ix.corner_since >= HOT_CORNER_DWELL {
				ix.corner_fired = true
				overview_toggle(s)
				return
			}
			wake_at(ix.corner_since + HOT_CORNER_DWELL)
		} else {
			ix.corner_since = 0
			ix.corner_fired = false
		}
	}

	// The bar.
	if bar_pointer(s, app, in_, mp) {
		set_ptr_focus(s, nil, 0, 0)
		s.hover_t = nil
		s.hover_btn = 0
		ix.cursor = .Default
		return
	}

	t, region, edges := window_at(s, mp.x, mp.y)
	s.hover_t = t
	s.hover_btn = int(btn_of_region(region))
	ix_tooltip_track(s, t, s.hover_btn)

	// The cursor follows what is under it; over a client, the client's own.
	switch region {
	case .Edge:
		ix.cursor = cursor_for_edges(edges)
		if t != nil && ws_in_layout(s, t) {
			ix.cursor = .EW
		}
	case .Content:
		ix.cursor = .Client
	case .None, .Title, .Close, .Maximise, .Minimise:
		ix.cursor = .Default
	}

	// Focus follows the mouse when the config says so, which is the one
	// setting people who have it never give up.
	if s.cfg.focus_follows_mouse && t != nil && t != s.focus && region != .None && moved {
		focus_window(s, t)
	}

	// Pointer focus for clients: only the content area forwards input.
	if region == .Content && t != nil && t.xdg != nil && t.xdg.surf != nil {
		surf, lx, ly := pick_surface(t.xdg.surf, t.x, t.y, mp.x, mp.y)
		if surf != nil {
			if surf != s.ptr_surf {
				set_ptr_focus(s, surf, lx, ly)
			} else if in_.mouse_delta != {0, 0} || moved {
				ptr_motion(s, lx, ly)
			}
			ix.grab_origin = mp - {lx, ly}
		} else {
			set_ptr_focus(s, nil, 0, 0)
		}
	} else {
		set_ptr_focus(s, nil, 0, 0)
	}

	// The drag modifier (P1-7): mod+left-drag moves from anywhere in the
	// window, mod+right-drag resizes from the nearest corner, mod+middle
	// lowers. Without this a window whose rule turned the title bar off
	// could not be moved at all.
	dm := s.cfg.drag_mod_set ? s.cfg.drag_mod : s.cfg.mod
	if t != nil && dm != {} && dm <= in_.mods && !session.kiosk {
		if in_.pressed[.Left] {
			focus_window(s, t)
			ix_begin_drag(s, t, .Armed, {})
			if in_.released[.Left] {
				ix_drag_release(s, t)
			}
			return
		}
		if in_.pressed[.Right] && !win_fixed(t) && !ws_fullscreen(t) {
			focus_window(s, t)
			if t.maximized {
				set_maximized(s, t, false)
			}
			ws_float_for_drag(s, t)
			e: Edges
			e += mp.x < t.x + t.w / 2 ? {.Left} : {.Right}
			e += mp.y < t.y + t.h / 2 ? {.Top} : {.Bottom}
			ix_begin_drag(s, t, .Resize, e, .Right)
			ix.cursor = cursor_for_edges(e)
			return
		}
		if in_.pressed[.Middle] {
			lower_window(s, t)
			ix.mode = .Swallow
			return
		}
	}

	if in_.pressed[.Left] {
		switch region {
		case .Title:
			now := wall_now()
			if dbl_click_ok(ix.last_click_t, t, ix.last_click_at, now, ix.last_click_pos, mp, s.cfg.double_click_ms) {
				// The second click of a double-click: toggle maximize, and
				// eat the rest of the press so it cannot start a move.
				ix.last_click_t = nil
				focus_window(s, t)
				if !win_fixed(t) {
					toggle_maximize(s, t)
				}
				ix.mode = .Swallow
				return
			}
			ix.last_click_t = t
			ix.last_click_at = now
			ix.last_click_pos = mp
			focus_window(s, t)
			ix_begin_drag(s, t, .Armed, {})
			if in_.released[.Left] {
				ix_drag_release(s, t)
			}
		case .Edge:
			focus_window(s, t)
			if ws_in_layout(s, t) {
				ix_begin_drag(s, t, .Split, edges)
			} else if partner := snap_partner(s, t); partner != nil && (edges == {.Right} || edges == {.Left}) && ix_edge_faces(t, partner, edges) {
				ix_begin_drag(s, t, .Split, edges)
				ix.split_partner = partner
			} else {
				ix_begin_drag(s, t, .Resize, edges)
			}
		case .Close, .Maximise, .Minimise:
			// The reflow guard: a button that slid under a resting pointer
			// because the layout just changed is not a target yet.
			if wall_now() - ix.reflow_at < REFLOW_GUARD && (ix.reflow_t != t || ix.reflow_btn != int(btn_of_region(region))) {
				ix.mode = .Swallow
				return
			}
			focus_window(s, t)
			b := btn_of_region(region)
			if !frame_btn_enabled(t, b) {
				ix.mode = .Swallow
				return
			}
			ix.mode = .Button
			ix.t = t
			ix.btn_down = b
			if in_.released[.Left] {
				ix_button_frame(s, in_, mp)
			}
		case .Content:
			focus_window(s, t)
			ix_grab_begin(s, in_, mp)
			return
		case .None:
		// The desktop. Focus stays where it was (UX.md P0-13): clicking
		// empty space must not silently disable every window shortcut.
		}
	}
	if in_.pressed[.Middle] {
		switch region {
		case .Title:
			lower_window(s, t)
			ix.mode = .Swallow
			return
		case .Content:
			ix_grab_begin(s, in_, mp)
			return
		case .None, .Edge, .Close, .Maximise, .Minimise:
		}
	}
	if in_.pressed[.Right] {
		switch region {
		case .Title, .Close, .Maximise, .Minimise:
			focus_window(s, t)
			menu_open_window(s, t, mp.x, mp.y)
			return
		case .Content:
			focus_window(s, t)
			ix_grab_begin(s, in_, mp)
			return
		case .None:
			if t == nil {
				menu_open_desktop(s, mp.x, mp.y)
				return
			}
		case .Edge:
		}
	}
	if in_.scroll != {0, 0} && region == .Content {
		ptr_axis(s, in_.scroll.x, in_.scroll.y)
	}
}

// ix_edge_faces says whether the edge being dragged is the one a snapped
// window shares with its partner (its right edge if the partner is to the
// right), rather than the screen-side edge.
ix_edge_faces :: proc(t, partner: ^Toplevel, edges: Edges) -> bool {
	right_of := frame_rect(partner).x > frame_rect(t).x
	return right_of ? .Right in edges : .Left in edges
}

// ---------------------------------------------------------------------------
// Implicit grab (P0-12)
// ---------------------------------------------------------------------------

ix_grab_begin :: proc(s: ^Server, in_: ^p.Input, mp: [2]int) {
	if s.ptr_surf == nil {
		return
	}
	ix.mode = .Grab
	ix_grab_frame(s, in_, mp)
}

// ix_grab_frame forwards a frame of pointer input to the grabbed surface:
// motion in its own coordinates (negative, or past its size, when the
// pointer has left it) and every button edge, until all buttons are up.
ix_grab_frame :: proc(s: ^Server, in_: ^p.Input, mp: [2]int) {
	if s.ptr_surf == nil {
		ix.mode = .Swallow
		return
	}
	ix.cursor = .Client
	local := mp - ix.grab_origin
	if in_.mouse_delta != {0, 0} {
		ptr_motion(s, local.x, local.y)
	}
	for pair in ([3]struct {
		b: p.Mouse_Button,
		c: u32,
	}{{.Left, BTN_LEFT}, {.Right, BTN_RIGHT}, {.Middle, BTN_MIDDLE}}) {
		if in_.pressed[pair.b] {
			ptr_button(s, pair.c, true)
		}
		if in_.released[pair.b] {
			ptr_button(s, pair.c, false)
		}
	}
	if in_.scroll != {0, 0} {
		ptr_axis(s, in_.scroll.x, in_.scroll.y)
	}
	if !(in_.down[.Left] || in_.down[.Right] || in_.down[.Middle]) {
		ix.mode = .None
	}
}

// ---------------------------------------------------------------------------
// Frame buttons (P0-8)
// ---------------------------------------------------------------------------

// ix_button_frame tracks a held frame button: it shows pressed while the
// pointer is over it, and acts only if released there.
ix_button_frame :: proc(s: ^Server, in_: ^p.Input, mp: [2]int) {
	t := ix.t
	if t == nil {
		ix.mode = .Swallow
		return
	}
	over := false
	if r, ok := frame_btn_rect(t, ix.btn_down); ok {
		over = p.rect_contains(r, f32(mp.x), f32(mp.y))
	}
	s.hover_t = over ? t : nil
	s.hover_btn = over ? int(ix.btn_down) : 0
	ix.cursor = .Default
	if !in_.released[.Left] && in_.down[.Left] {
		return
	}
	b := ix.btn_down
	ix.mode = .None
	ix.t = nil
	ix.btn_down = .None
	if !over {
		return // dragged off: cancelled
	}
	switch b {
	case .Close:
		close_window(s, t)
	case .Maximize:
		toggle_maximize(s, t)
	case .Minimize:
		minimize_window(s, t)
	case .None:
	}
	s.dirty = true
}

ix_tooltip_track :: proc(s: ^Server, t: ^Toplevel, btn: int) {
	if t != ix.tip_t || btn != ix.tip_btn {
		ix.tip_t = t
		ix.tip_btn = btn
		ix.tip_since = wall_now()
		if btn != 0 {
			wake_at(ix.tip_since + TIP_DELAY)
		}
	}
}

// ix_tooltip says which tooltip, if any, is due now.
ix_tooltip :: proc(s: ^Server) -> (string, p.Rect, bool) {
	t := ix.tip_t
	if t == nil || ix.tip_btn == 0 || ix.mode != .None || s.drag != .None {
		return "", {}, false
	}
	if wall_now() - ix.tip_since < TIP_DELAY || s.hover_t != t {
		return "", {}, false
	}
	b := Frame_Btn(ix.tip_btn)
	r, ok := frame_btn_rect(t, b)
	if !ok {
		return "", {}, false
	}
	return frame_btn_label(s, t, b), r, true
}

// ---------------------------------------------------------------------------
// Wakeups
// ---------------------------------------------------------------------------

// wake_due is the earliest time something on screen changes by itself (a
// tooltip appearing, a snap preview, a toast expiring), so the bare-metal
// loop can sleep exactly until then instead of a full second.
wake_due: f64

wake_at :: proc(t: f64) {
	if wake_due == 0 || t < wake_due {
		wake_due = t
	}
}

// wake_ms is how long the loop may sleep, or -1 for "no deadline".
wake_ms :: proc() -> int {
	if wake_due == 0 {
		return -1
	}
	left := wake_due - wall_now()
	if left <= 0 {
		wake_due = 0
		return 0
	}
	return int(left * 1000) + 1
}
