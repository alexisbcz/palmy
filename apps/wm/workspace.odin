// Workspaces, tiling and outputs.
//
// Three things that are really one thing: a *workspace* is a stack of windows
// plus a layout, an *output* is a rectangle that owns a set of workspaces, and
// a *layout* is a pure function from a rectangle and a list of windows to a
// list of rectangles.
//
// `Server.stack` is still the list the drawing code walks, and it is still the
// bottom-to-top stacking order — it is now the *live copy of the current
// workspace's* stack. Switching workspaces hands the array back to the
// workspace it belongs to and takes the next one's. That keeps `focus_window`,
// `raise_window`, `cycle_focus`, `topmost_other` and `unmap_window` working on
// exactly the data they worked on before, and keeps `proto.odin`'s
// `append(&s.stack, t)` meaning "map onto the workspace the user is looking
// at", which is what it should mean.
//
// Per-window state lives in `ws_meta`, keyed by the `^Toplevel`, rather than
// in `Toplevel` itself: that struct belongs to `proto.odin`, which is owned by
// somebody else. `ws_prune` drops entries whose toplevel the client has
// destroyed, so a recycled heap address cannot inherit a dead window's state.
package wm

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:text/regex"
import p "palmy:."

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

Ws_Workspace :: struct {
	name:         string,
	output:       int,
	stack:        [dynamic]^Toplevel, // bottom to top; empty while this is the live one
	last_focus:   ^Toplevel,
	tiling:       bool,
	layout:       int,
	master_ratio: f32,
	master_count: int,
	tiled_in:     Tile_Rect, // the area the last layout pass filled (tile_area_ws)
}

// Ws_Output is a logical head. Today exactly one of these exists and it is
// the nested host's canvas; `drm.odin` and `output.odin` will add real ones.
// Nothing above this struct knows which kind it is looking at.
Ws_Output :: struct {
	name:         string,
	x, y, w, h:   int, // logical rectangle, in compositor pixels
	scale:        f32,
	active:       int, // index into Server.workspaces
	ws_lo, ws_hi: int, // inclusive range of workspace indices owned
	enabled:      bool,
	host:         bool, // tracks the nested host canvas rather than a real head
	focus:        ^Toplevel,
}

Ws_Win :: struct {
	// seq is the window's position in the *tiling* order, which is
	// deliberately not the stacking order: focusing a window raises it, and a
	// layout that reshuffled every time you clicked would be unusable. It is
	// assigned once, monotonically, so the oldest window is the master.
	seq:        int,
	floating:   bool,
	no_border:  bool,
	no_title:   bool,
	ruled:      bool,
	want_ws:    int, // 1-based, from a rule; applied on the next tick
	float_rect: [4]int,
	have_float: bool,

	// Where the window is when it is not where the user left it (snap.odin).
	// `snap` is the zone a floating window is snapped to, and `pre_snap` the
	// content rectangle it had before, which is what un-snapping returns to.
	// `max_snap` is the zone to go back to when a snapped window is maximized
	// and then restored: restore means "what it was", not "floating".
	snap:       Snap,
	pre_snap:   [4]int,
	max_snap:   Snap,
	// Snapped out of the layout from the keyboard (Super+Left/Right on a
	// tiled window). Restoring it returns it to its cell, not to a float
	// rect it never had: the keys are a detour, and undoing a detour is
	// being back where you were (principle 4).
	snap_tile:  bool,
	// Floated by the layout itself, because the client's minimum size did not
	// fit any cell. It goes back into the layout once it fits again.
	auto_float: bool,

	// Stacking and visibility (P1-4).
	on_top:     bool,
	sticky:     bool,
	fullscreen: bool,
	fs_saved:   [4]int,
	fs_was_max: bool,

	// Focus bookkeeping: `mru` is a stamp from the last time the window was
	// focused, which is the order the switcher lists windows in; `urgent` is
	// a window that mapped, or asked for attention, while the user was busy
	// elsewhere, and stays marked until it is focused.
	mru:        u64,
	urgent:     bool,

	// From rules (P1-11). Zero opacity means "unset", which is opaque.
	opacity:    f32,
	no_anim:    bool,
	no_focus:   bool,
	want_fullscreen: bool, // a rule asked for fullscreen; applied once mapped
	placement_rule: int, // 0 config default, 1 centre, 2 pointer
	output_rule: string, // a rule's `output NAME`, borrowed from the config
	rule_title: string, // the title the rules last matched against (rerule)
}

ws_meta: map[^Toplevel]^Ws_Win

ws_win :: proc(t: ^Toplevel) -> ^Ws_Win {
	if t == nil {
		@(static) scratch: Ws_Win
		scratch = {}
		return &scratch
	}
	if m, ok := ws_meta[t]; ok {
		return m
	}
	m := new(Ws_Win)
	ws_next_seq += 1
	m.seq = ws_next_seq
	ws_meta[t] = m
	return m
}

ws_next_seq: int

ws_peek :: proc(t: ^Toplevel) -> (^Ws_Win, bool) {
	if t == nil {
		return nil, false
	}
	m, ok := ws_meta[t]
	return m, ok
}

ws_forget :: proc(t: ^Toplevel) {
	if m, ok := ws_meta[t]; ok {
		delete(m.rule_title)
		free(m)
		delete_key(&ws_meta, t)
	}
}

// ws_alive asks the client's own object table whether this toplevel still
// exists. That is the only authority: a `^Toplevel` that has been freed may
// be handed straight back out by the allocator.
ws_alive :: proc(s: ^Server, t: ^Toplevel) -> bool {
	if t == nil || t.client == nil {
		return false
	}
	found := false
	for c in s.clients {
		if c == t.client {
			found = true
			break
		}
	}
	if !found {
		return false
	}
	o, ok := t.client.objs[t.id]
	return ok && o.kind == .Toplevel && o.p == rawptr(t)
}

// ws_prune runs once a frame. It is O(number of windows), not O(objects).
ws_prune :: proc(s: ^Server) {
	if s.listen == 0 {
		return // offscreen: the windows are fabricated and have no objects
	}
	if len(ws_meta) == 0 {
		return
	}
	dead := make([dynamic]^Toplevel, 0, 4, context.temp_allocator)
	for t in ws_meta {
		if !ws_alive(s, t) {
			append(&dead, t)
		}
	}
	for t in dead {
		ws_forget(t)
	}
}

// ---------------------------------------------------------------------------
// Per-window geometry, which the config can change per window
// ---------------------------------------------------------------------------

ws_title_h :: proc(t: ^Toplevel) -> int {
	if !server.cfg.title_bar {
		return 0
	}
	if m, ok := ws_peek(t); ok && (m.no_title || m.fullscreen) {
		return 0
	}
	return server.cfg.title_h
}

ws_border :: proc(t: ^Toplevel) -> int {
	if m, ok := ws_peek(t); ok && (m.no_border || m.fullscreen) {
		return 0
	}
	return server.cfg.border
}

ws_bar_h :: proc(s: ^Server) -> int {
	return s.cfg.bar ? s.cfg.bar_h : 0
}

ws_floating :: proc(t: ^Toplevel) -> bool {
	if m, ok := ws_peek(t); ok {
		return m.floating
	}
	return false
}

ws_fullscreen :: proc(t: ^Toplevel) -> bool {
	if m, ok := ws_peek(t); ok {
		return m.fullscreen
	}
	return false
}

// ws_in_layout says whether the layout engine places this window: it is on
// a tiling workspace and has not been floated. A maximized tiled window is
// still in the layout — it holds its cell — it is just drawn over it.
ws_in_layout :: proc(s: ^Server, t: ^Toplevel) -> bool {
	if t == nil || ws_floating(t) {
		return false
	}
	ws_ensure(s)
	idx := ws_index_of(s, t)
	if idx < 0 {
		idx = s.cur_ws
	}
	return s.workspaces[idx].tiling
}

// ws_layer is the stacking band a window lives in, bottom to top: tiled
// windows, then floating ones (maximized tiled windows among them, since they
// cover the layout), then always-on-top, then fullscreen. Raising and
// lowering only ever move a window within its band.
ws_layer :: proc(s: ^Server, t: ^Toplevel) -> int {
	m, ok := ws_peek(t)
	if ok && m.fullscreen {
		return 3
	}
	if ok && m.on_top {
		return 2
	}
	if !t.maximized && ws_in_layout(s, t) {
		return 0
	}
	return 1
}

// ws_restack restores the band order after a window changed band (floated,
// pinned on top, fullscreened). It is a stable sort, so the order inside each
// band — which is the user's stacking — survives.
ws_restack :: proc(s: ^Server) {
	for i in 1 ..< len(s.stack) {
		v := s.stack[i]
		k := ws_layer(s, v)
		j := i - 1
		for j >= 0 && ws_layer(s, s.stack[j]) > k {
			s.stack[j + 1] = s.stack[j]
			j -= 1
		}
		s.stack[j + 1] = v
	}
	s.dirty = true
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

// ws_ensure is idempotent and safe to call from anywhere, including the
// offscreen renderer, which never goes through `main`.
ws_ensure :: proc(s: ^Server) {
	if s.cfg.workspaces == 0 {
		cfg_scalars(&s.cfg)
		cfg_parse(&s.cfg, CFG_DEFAULT, "<built-in>")
	}
	if s.cfg.path == "" {
		s.cfg.path = cfg_path()
	}
	if len(s.outputs) == 0 {
		ws_outputs_from_cfg(s)
	}
	if len(s.workspaces) != s.cfg.workspaces {
		ws_build_workspaces(s)
	}
}

ws_outputs_from_cfg :: proc(s: ^Server) {
	if len(s.cfg.outputs) == 0 {
		// The single case the compositor can actually drive today: the nested
		// host's canvas, which resizes under us.
		append(
			&s.outputs,
			Ws_Output {
				name = strings.clone("HOST-1"),
				x = 0,
				y = 0,
				w = max(s.out_w, 1),
				h = max(s.out_h, 1),
				scale = 1,
				enabled = true,
				host = true,
			},
		)
		return
	}
	for co in s.cfg.outputs {
		append(
			&s.outputs,
			Ws_Output {
				name = strings.clone(co.name),
				x = co.x,
				y = co.y,
				w = max(co.w, 1),
				h = max(co.h, 1),
				scale = co.scale <= 0 ? 1 : co.scale,
				ws_lo = co.ws_lo,
				ws_hi = co.ws_hi,
				enabled = co.w > 0 && co.h > 0,
			},
		)
	}
	// Whatever the config says, one output has to track the host canvas or
	// nothing is visible when running nested.
	s.outputs[0].host = true
	s.outputs[0].enabled = true
}

ws_build_workspaces :: proc(s: ^Server) {
	// Windows that already exist must survive a reload that changes the
	// workspace count, so everything is gathered up and re-homed.
	orphans := make([dynamic]^Toplevel, 0, 8, context.temp_allocator)
	for &w in s.workspaces {
		for t in w.stack {
			append(&orphans, t)
		}
		delete(w.stack)
		delete(w.name)
	}
	clear(&s.workspaces)

	n := max(s.cfg.workspaces, 1)
	for i in 0 ..< n {
		append(
			&s.workspaces,
			Ws_Workspace {
				name = fmt.aprintf("%d", i + 1),
				output = 0,
				tiling = s.cfg.tiling,
				layout = s.cfg.layout,
				master_ratio = s.cfg.master_ratio,
				master_count = s.cfg.master_count,
			},
		)
	}
	// Hand each workspace to the output that claims it.
	for &o, oi in s.outputs {
		if o.ws_lo <= 0 || o.ws_hi <= 0 {
			continue
		}
		for i in o.ws_lo - 1 ..= min(o.ws_hi, n) - 1 {
			if i >= 0 && i < n {
				s.workspaces[i].output = oi
			}
		}
	}
	for &o, oi in s.outputs {
		o.active = ws_first_of_output(s, oi)
	}
	s.cur_ws = clamp(s.cur_ws, 0, n - 1)
	s.cur_out = clamp(s.cur_out, 0, max(len(s.outputs) - 1, 0))
	if len(s.outputs) > 0 {
		s.outputs[s.cur_out].active = s.cur_ws
	}
	for t in orphans {
		append(&s.stack, t)
	}
	s.needs_layout = true
}

ws_first_of_output :: proc(s: ^Server, oi: int) -> int {
	for w, i in s.workspaces {
		if w.output == oi {
			return i
		}
	}
	return 0
}

// ws_sync_host keeps the host-backed output the same size as the nested
// window. A real head never goes through here.
ws_sync_host :: proc(s: ^Server, w, h: int) {
	for &o in s.outputs {
		if o.host {
			if o.w != w || o.h != h {
				o.w, o.h = max(w, 1), max(h, 1)
				s.needs_layout = true
				s.dirty = true
			}
			return
		}
	}
}

// ---------------------------------------------------------------------------
// The seam `drm.odin` and `output.odin` are expected to use
//
// Neither may add fields to `Server`. Both describe heads through these four
// calls and read them back through `ws_output_rect` / `ws_output_count`.
// ---------------------------------------------------------------------------

ws_output_find :: proc(s: ^Server, name: string) -> int {
	for o, i in s.outputs {
		if o.name == name {
			return i
		}
	}
	return -1
}

// ws_output_upsert declares a head. Calling it again with the same name moves
// or rescales that head rather than creating a second one.
ws_output_upsert :: proc(s: ^Server, name: string, x, y, w, h: int, scale: f32) -> int {
	ws_ensure(s)
	if i := ws_output_find(s, name); i >= 0 {
		o := &s.outputs[i]
		if o.x != x || o.y != y || o.w != w || o.h != h || o.scale != scale {
			o.x, o.y, o.w, o.h = x, y, max(w, 1), max(h, 1)
			o.scale = scale <= 0 ? 1 : scale
			s.needs_layout = true
			s.dirty = true
		}
		o.enabled = true
		return i
	}
	append(
		&s.outputs,
		Ws_Output {
			name = strings.clone(name),
			x = x,
			y = y,
			w = max(w, 1),
			h = max(h, 1),
			scale = scale <= 0 ? 1 : scale,
			enabled = true,
		},
	)
	oi := len(s.outputs) - 1
	// A head that arrives after the workspaces were built gets the tail of the
	// set, unless the config already assigned it one.
	if ci := ws_cfg_output(s, name); ci >= 0 && s.cfg.outputs[ci].ws_lo > 0 {
		c := s.cfg.outputs[ci]
		s.outputs[oi].ws_lo, s.outputs[oi].ws_hi = c.ws_lo, c.ws_hi
		for i in c.ws_lo - 1 ..= min(c.ws_hi, len(s.workspaces)) - 1 {
			if i >= 0 && i < len(s.workspaces) {
				s.workspaces[i].output = oi
			}
		}
	}
	// Otherwise it takes the first workspace nobody is looking at and nothing
	// is on, the way i3 and sway hand one out, so a second monitor does not
	// show the first one's workspace again.
	owned := false
	for w in s.workspaces {
		if w.output == oi {
			owned = true
			break
		}
	}
	if !owned {
		for &w, i in s.workspaces {
			visible := false
			for o in s.outputs {
				if o.enabled && o.active == i {
					visible = true
				}
			}
			if !visible && i != s.cur_ws && len(w.stack) == 0 {
				w.output = oi
				break
			}
		}
	}
	s.outputs[oi].active = ws_first_of_output(s, oi)
	s.needs_layout = true
	s.dirty = true
	return oi
}

ws_cfg_output :: proc(s: ^Server, name: string) -> int {
	for o, i in s.cfg.outputs {
		if o.name == name {
			return i
		}
	}
	return -1
}

// ws_output_disable is what a head being unplugged looks like. Its windows
// are not destroyed: the workspaces move to the first surviving output, which
// is the only behaviour that does not lose work.
ws_output_disable :: proc(s: ^Server, name: string) {
	i := ws_output_find(s, name)
	if i < 0 {
		return
	}
	s.outputs[i].enabled = false
	fallback := -1
	for o, j in s.outputs {
		if j != i && o.enabled {
			fallback = j
			break
		}
	}
	if fallback < 0 {
		return
	}
	for &w in s.workspaces {
		if w.output == i {
			w.output = fallback
		}
	}
	if s.cur_out == i {
		s.cur_out = fallback
	}
	s.needs_layout = true
	s.dirty = true
}

ws_output_rect :: proc(s: ^Server, i: int) -> (x, y, w, h: int) {
	if i < 0 || i >= len(s.outputs) {
		return 0, 0, max(s.out_w, 1), max(s.out_h, 1)
	}
	o := s.outputs[i]
	// Layer-shell exclusive zones come off here, which is why nothing else in
	// the window manager has to know that a bar exists.
	return layer_work_area(s, o.x, o.y, o.w, o.h)
}

ws_output_count :: proc(s: ^Server) -> int {
	return len(s.outputs)
}

// ws_output_at maps a compositor-pixel point to the head under it.
ws_output_at :: proc(s: ^Server, x, y: int) -> int {
	for o, i in s.outputs {
		if !o.enabled {
			continue
		}
		if x >= o.x && y >= o.y && x < o.x + o.w && y < o.y + o.h {
			return i
		}
	}
	return s.cur_out
}

// ---------------------------------------------------------------------------
// Stacks
// ---------------------------------------------------------------------------

ws_stack :: proc(s: ^Server, idx: int) -> []^Toplevel {
	if idx == s.cur_ws {
		return s.stack[:]
	}
	if idx < 0 || idx >= len(s.workspaces) {
		return nil
	}
	return s.workspaces[idx].stack[:]
}

ws_active_of_output :: proc(s: ^Server, oi: int) -> int {
	if oi < 0 || oi >= len(s.outputs) {
		return s.cur_ws
	}
	a := s.outputs[oi].active
	if a < 0 || a >= len(s.workspaces) {
		return s.cur_ws
	}
	return a
}

ws_index_of :: proc(s: ^Server, t: ^Toplevel) -> int {
	for w in s.stack {
		if w == t {
			return s.cur_ws
		}
	}
	for ws, i in s.workspaces {
		for w in ws.stack {
			if w == t {
				return i
			}
		}
	}
	return -1
}

// ws_detach removes a toplevel from whichever workspace holds it. `unmap` and
// client teardown both go through here, so a window that dies on a workspace
// you are not looking at is still cleaned up.
ws_detach :: proc(s: ^Server, t: ^Toplevel) -> bool {
	for w, i in s.stack {
		if w == t {
			ordered_remove(&s.stack, i)
			return true
		}
	}
	for &ws in s.workspaces {
		for w, i in ws.stack {
			if w == t {
				ordered_remove(&ws.stack, i)
				return true
			}
		}
	}
	return false
}

ws_total_windows :: proc(s: ^Server) -> int {
	n := 0
	for t in s.stack {
		if t.mapped {n += 1}
	}
	for ws, i in s.workspaces {
		if i == s.cur_ws {
			continue
		}
		for t in ws.stack {
			if t.mapped {n += 1}
		}
	}
	return n
}

ws_count_on :: proc(s: ^Server, idx: int) -> int {
	n := 0
	for t in ws_stack(s, idx) {
		if t.mapped {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Switching
// ---------------------------------------------------------------------------

ws_switch :: proc(s: ^Server, idx: int) {
	ws_ensure(s)
	if idx < 0 || idx >= len(s.workspaces) || idx == s.cur_ws {
		return
	}
	cur := &s.workspaces[s.cur_ws]
	cur.last_focus = s.focus
	was_focus_sticky := false
	if m, ok := ws_peek(s.focus); ok && m.sticky {
		was_focus_sticky = true
		cur.last_focus = nil
	}

	// Hand the keyboard and the pointer back before the windows vanish; the
	// client must see a leave, not simply stop receiving events.
	focus_window(s, nil)
	set_ptr_focus(s, nil, 0, 0)
	s.hover_t = nil
	s.hover_btn = 0
	if s.drag != .None {
		ws_cancel_drag(s)
	}

	// Sticky windows (P1-4) travel with the switch: they leave the stack
	// being parked and join the one being shown, on top.
	travellers := make([dynamic]^Toplevel, 0, 2, context.temp_allocator)
	for i := len(s.stack) - 1; i >= 0; i -= 1 {
		if m, ok := ws_peek(s.stack[i]); ok && m.sticky && s.stack[i].mapped {
			inject_at(&travellers, 0, s.stack[i])
			ordered_remove(&s.stack, i)
		}
	}
	anim_ws_switch(s, s.cur_ws, idx)
	cur.stack = s.stack
	s.stack = s.workspaces[idx].stack
	s.workspaces[idx].stack = nil
	for t in travellers {
		append(&s.stack, t)
	}
	s.cur_ws = idx
	ws_restack(s)
	oi := s.workspaces[idx].output
	if oi >= 0 && oi < len(s.outputs) {
		s.cur_out = oi
		s.outputs[oi].active = idx
	}

	want := s.workspaces[idx].last_focus
	if len(travellers) > 0 && was_focus_sticky {
		want = travellers[len(travellers) - 1]
	}
	if !ws_on_current(s, want) {
		want = mru_next(s, nil)
	}
	focus_window(s, want)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("workspace %s", s.workspaces[idx].name))
}

ws_on_current :: proc(s: ^Server, t: ^Toplevel) -> bool {
	if t == nil {
		return false
	}
	for w in s.stack {
		if w == t {
			return t.mapped
		}
	}
	return false
}

ws_switch_rel :: proc(s: ^Server, delta: int) {
	ws_ensure(s)
	n := len(s.workspaces)
	if n == 0 {
		return
	}
	ws_switch(s, ((s.cur_ws + delta) % n + n) % n)
}

ws_move_to :: proc(s: ^Server, t: ^Toplevel, idx: int) {
	ws_ensure(s)
	if t == nil || idx < 0 || idx >= len(s.workspaces) || idx == s.cur_ws {
		return
	}
	was_focus := s.focus == t
	if s.drag_t == t {
		ws_cancel_drag(s)
	}
	if s.hover_t == t {
		s.hover_t = nil
		s.hover_btn = 0
	}
	if was_focus {
		focus_window(s, nil)
	}
	ws_drop_pointer(s, t)
	// A tiled window's rect is its cell: a narrow strip flush with the
	// screen edge. Taken to a workspace that does not tile, it gets the
	// size it floats at (as leaving tiling gives it), centred, and on top
	// of what is there — the window you just sent is the one to see.
	was_tiled := ws_in_layout(s, t) && !t.maximized
	float_r := snap_default_float(s, t)
	if !ws_detach(s, t) {
		return
	}
	append(&s.workspaces[idx].stack, t)
	if m, ok := ws_peek(t); ok {
		m.sticky = false // moving it somewhere means it lives there now
	}
	// It is the last thing done on that workspace, so going there focuses
	// it, rather than raising whatever had focus there over it.
	if !t.minimized {
		s.workspaces[idx].last_focus = t
	}
	if !ws_in_layout(s, t) && !t.maximized && !ws_fullscreen(t) {
		oi := s.workspaces[idx].output
		if oi < 0 || oi >= len(s.outputs) {
			oi = s.cur_out
		}
		if was_tiled {
			m := ws_win(t)
			m.snap = .None
			wa := ws_work_area(s, oi)
			w, h := float_r[2], float_r[3]
			win_set_rect(s, t, wa.x + (wa.w - w) / 2, wa.y + ws_title_h(t) + (wa.h - ws_title_h(t) - h) / 2, w, h)
		}
		win_fit_work_area(s, t, oi)
	}
	if was_focus {
		focus_window(s, mru_next(s, nil))
	}
	ix_note_reflow(s)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("%s → workspace %s", title_of(t), s.workspaces[idx].name))
}

ws_move_rel :: proc(s: ^Server, t: ^Toplevel, delta: int) {
	n := len(s.workspaces)
	if n == 0 || t == nil {
		return
	}
	ws_move_to(s, t, ((s.cur_ws + delta) % n + n) % n)
}

// ws_cancel_drag ends an interactive move or resize without touching the
// client. It is what a window disappearing mid-drag needs, and it is the one
// path the demo never exercised.
ws_cancel_drag :: proc(s: ^Server) {
	if t := s.drag_t; t != nil && t.resizing {
		t.resizing = false
		if ws_alive(s, t) {
			send_configure(s, t, t.req_w, t.req_h)
		}
	}
	s.drag = .None
	s.drag_t = nil
	s.drag_edges = {}
}

// ws_drop_pointer forgets a pointer focus that belongs to this window, so a
// surface that is about to be hidden or freed cannot be sent another motion.
ws_drop_pointer :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil || s.ptr_surf == nil || t.xdg == nil || t.xdg.surf == nil {
		return
	}
	if ws_surface_under(t.xdg.surf, s.ptr_surf) {
		s.ptr_surf = nil
	}
}

ws_surface_under :: proc(root, want: ^Surface) -> bool {
	if root == nil {
		return false
	}
	if root == want {
		return true
	}
	for ch in root.children {
		if ws_surface_under(ch, want) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

ws_apply_rules :: proc(s: ^Server, t: ^Toplevel) {
	m := ws_win(t)
	if m.ruled {
		return
	}
	m.ruled = true
	delete(m.rule_title)
	m.rule_title = strings.clone(t.title)
	for &r in s.cfg.rules {
		if !rule_matches(&r, t) {
			continue
		}
		if r.set_float {
			m.floating = r.float
		}
		if r.no_border {
			m.no_border = true
		}
		if r.no_title {
			m.no_title = true
		}
		if r.workspace > 0 {
			m.want_ws = r.workspace
		}
		if r.set_size {
			t.req_w, t.req_h = r.w, r.h
			send_configure(s, t, r.w, r.h)
		}
		if r.maximize {
			set_maximized(s, t, true)
		}
		if r.opacity > 0 {
			m.opacity = r.opacity
		}
		if r.on_top {
			m.on_top = true
		}
		if r.sticky {
			m.sticky = true
			m.floating = true
		}
		if r.placement != 0 {
			m.placement_rule = r.placement
		}
		if r.no_anim {
			m.no_anim = true
		}
		if r.no_focus {
			m.no_focus = true
		}
		if r.output != "" {
			m.output_rule = r.output
		}
		if r.fullscreen {
			m.want_fullscreen = true
		}
	}
}

// rule_matches is one rule against one window: every matcher the rule names
// must hold. app_id= is exact, title~ a substring, class~ a regular
// expression searched in the app_id.
rule_matches :: proc(r: ^Cfg_Rule, t: ^Toplevel) -> bool {
	if r.app_id != "" && r.app_id != t.app_id {
		return false
	}
	if r.title != "" && !strings.contains(t.title, r.title) {
		return false
	}
	if r.app_re != "" {
		re, err := regex.create(r.app_re, {}, context.temp_allocator, context.temp_allocator)
		if err != nil {
			return false
		}
		_, ok := regex.match_and_allocate_capture(re, t.app_id, context.temp_allocator, context.temp_allocator)
		if !ok {
			return false
		}
	}
	return true
}

// rule_output is the output a rule asked a window to open on, if any.
rule_output :: proc(s: ^Server, t: ^Toplevel) -> (int, bool) {
	m, ok := ws_peek(t)
	if !ok || m.output_rule == "" {
		return 0, false
	}
	i := ws_output_find(s, m.output_rule)
	if i < 0 || !s.outputs[i].enabled {
		return 0, false
	}
	return i, true
}

// ws_rerule runs the rules again for a window whose title changed, when a
// matching rule asked for it with `rerule` (a browser's title is the page,
// and the page is what the user wants to match).
ws_rerule :: proc(s: ^Server, t: ^Toplevel) {
	m, ok := ws_peek(t)
	if !ok || !m.ruled || m.rule_title == t.title {
		return
	}
	any := false
	for &r in s.cfg.rules {
		if r.rerule {
			any = true
			break
		}
	}
	if !any {
		return
	}
	m.ruled = false
	ws_apply_rules(s, t)
	ws_restack(s)
	s.needs_layout = true
}

// ---------------------------------------------------------------------------
// Layouts
//
// A layout is a function. Adding a second one is adding a function and one
// line to TILE_LAYOUTS, which is the whole point of the seam.
// ---------------------------------------------------------------------------

Tile_Rect :: struct {
	x, y, w, h: int,
}

// A layout returns nil when every window fits its cell, or the window whose
// minimum size could not be honoured however the cells were shared out. The
// caller floats that one and runs the layout again: overlapping two tiles is
// the one thing a tiling layout must never do (UX.md 1.7, P0-13).
Tile_Fn :: proc(s: ^Server, ws: ^Ws_Workspace, area: Tile_Rect, wins: []^Toplevel) -> ^Toplevel

Tile_Layout :: struct {
	name: string,
	fn:   Tile_Fn,
}

TILE_LAYOUTS := [?]Tile_Layout {
	{"master", tile_master_stack},
	{"monocle", tile_monocle},
	{"grid", tile_grid},
}

tile_layout_by_name :: proc(name: string) -> (int, bool) {
	for l, i in TILE_LAYOUTS {
		if strings.equal_fold(l.name, name) {
			return i, true
		}
	}
	return 0, false
}

tile_layout_name :: proc(i: int) -> string {
	if i < 0 || i >= len(TILE_LAYOUTS) {
		return "master"
	}
	return TILE_LAYOUTS[i].name
}

// tile_area is the usable rectangle of an output: the head, less the bar and
// the outer gap.
tile_area :: proc(s: ^Server, oi: int) -> Tile_Rect {
	ox, oy, ow, oh := ws_output_rect(s, oi)
	g := s.cfg.gaps_out
	bar := ws_bar_h(s)
	return Tile_Rect {
		x = ox + g,
		y = oy + bar + g,
		w = max(ow - 2 * g, MIN_W),
		h = max(oh - bar - 2 * g, MIN_H),
	}
}

// tile_area_ws is the rectangle a tiling workspace's layout fills: its
// output's tile_area, less the side a window snapped to a full-height half
// (or third) holds. Super+Left on a tile is meant to put two windows side by
// side; when the layout went on filling the whole output under the snapped
// window, the tile that became master sat entirely hidden behind it, and
// two keystrokes made a window disappear. So the layout yields that side and
// tiles into the rest. If too little would be left to tile into, it keeps
// the whole area — a window overlapped beats a window squeezed to nothing.
tile_area_ws :: proc(s: ^Server, idx, oi: int) -> Tile_Rect {
	area := tile_area(s, oi)
	l, r := area.x, area.x + area.w
	gap := s.cfg.gaps_in
	for t in ws_stack(s, idx) {
		m, ok := ws_peek(t)
		if !ok || !t.mapped || t.minimized || !m.floating || t.maximized || m.fullscreen {
			continue
		}
		fr := target_frame(t)
		cx := int(fr.x + fr.w / 2)
		if cx < area.x || cx >= area.x + area.w || int(fr.y + fr.h / 2) < area.y || int(fr.y + fr.h / 2) >= area.y + area.h {
			continue // on another output
		}
		#partial switch m.snap {
		case .Left, .Left_Third, .Left_Two_Thirds:
			l = max(l, int(fr.x + fr.w) + gap)
		case .Right, .Right_Third, .Right_Two_Thirds:
			r = min(r, int(fr.x) - gap)
		}
	}
	if r - l < 2 * MIN_W {
		return area
	}
	return {l, area.y, r - l, area.h}
}

// tile_place turns a cell — which contains the whole frame — into the content
// rectangle the client is configured with.
tile_place :: proc(s: ^Server, t: ^Toplevel, cell: Tile_Rect) {
	if t.maximized || ws_fullscreen(t) {
		return
	}
	th := ws_title_h(t)
	bw := ws_border(t)
	w := max(cell.w - 2 * bw, max(MIN_W, t.min_w))
	h := max(cell.h - th - bw, max(MIN_H, t.min_h))
	if t.max_w > 0 {w = min(w, t.max_w)}
	if t.max_h > 0 {h = min(h, t.max_h)}

	nx := cell.x + bw
	ny := cell.y + th
	// A client's minimum size can be larger than the cell the layout gave it
	// — a sidebar app in a narrow stack column, say. Honour the minimum, but
	// pull the window back onto the output rather than letting it run off the
	// edge, which is what it did before: overlapping is survivable, a window
	// half off the screen is not.
	{
		oi := ws_output_at(s, cell.x, cell.y)
		ox, oy, ow, oh := ws_output_rect(s, oi)
		g := s.cfg.gaps_out
		if nx + w + bw > ox + ow - g {
			nx = max(ox + g + bw, ox + ow - g - w - bw)
		}
		if ny + h + bw > oy + oh - g {
			ny = max(oy + ws_bar_h(s) + g + th, oy + oh - g - h - bw)
		}
	}
	// A tile that moves because the layout reflowed — a neighbour closed,
	// minimized, snapped out, or a new one arrived — glides to its new cell
	// (UX.md P1-6) instead of jumping there in one frame. Not while the
	// pointer is dragging a size: the cell then follows the pointer, and an
	// animation restarted every frame would only make it lag.
	if (t.x != nx || t.y != ny || w != t.req_w || h != t.req_h) && s.drag != .Resize && s.drag != .Split {
		anim_geom_begin(s, t)
	}
	if t.x != nx || t.y != ny {
		t.x, t.y = nx, ny
		s.dirty = true
	}
	t.anchor_x, t.anchor_y = false, false
	// Only configure when the request actually changes. A tiling WM that
	// re-sends a configure every frame makes every client repaint every frame.
	if w != t.req_w || h != t.req_h || w != t.last_cfg_w || h != t.last_cfg_h {
		t.req_w, t.req_h = w, h
		if ws_alive(s, t) || s.listen == 0 {
			send_configure(s, t, w, h)
		}
		s.dirty = true
	}
}

// tile_need_w / tile_need_h are the smallest cell, frame included, that
// holds a window at its client's minimum size.
tile_need_w :: proc(t: ^Toplevel) -> int {
	return max(MIN_W, t.min_w) + 2 * ws_border(t)
}

tile_need_h :: proc(t: ^Toplevel) -> int {
	return max(MIN_H, t.min_h) + ws_title_h(t) + ws_border(t)
}

// tile_share splits `total` pixels among cells with minimums, as evenly as
// the minimums allow: a cell whose minimum exceeds the even share gets its
// minimum, and the rest is shared again among the others. ok is false when
// the minimums alone do not fit, and `worst` is then the greediest cell.
// Pure, so the selftest can hold it to that.
tile_share :: proc(total: int, need: []int, out: []int) -> (ok: bool, worst: int) {
	n := len(need)
	worst = -1
	sum := 0
	for v, i in need {
		sum += v
		if worst < 0 || v > need[worst] {
			worst = i
		}
	}
	if n == 0 {
		return true, -1
	}
	if sum > total {
		return false, worst
	}
	fixed := make([]bool, n, context.temp_allocator)
	for {
		left := total
		free_n := 0
		for i in 0 ..< n {
			if fixed[i] {
				left -= need[i]
			} else {
				free_n += 1
			}
		}
		if free_n == 0 {
			break
		}
		each := left / free_n
		changed := false
		for i in 0 ..< n {
			if !fixed[i] && need[i] > each {
				fixed[i] = true
				changed = true
			}
		}
		if changed {
			continue
		}
		// Hand out the even share; the last free cell takes the remainder so
		// the column is filled to the pixel.
		rem := left - each * free_n
		for i in 0 ..< n {
			if fixed[i] {
				out[i] = need[i]
			} else {
				out[i] = each
			}
		}
		for i := n - 1; i >= 0; i -= 1 {
			if !fixed[i] {
				out[i] += rem
				break
			}
		}
		return true, -1
	}
	for i in 0 ..< n {
		out[i] = need[i]
	}
	out[n - 1] += total - sum
	return true, -1
}

// tile_split_v hands out n vertical slices of a column, with gaps between,
// each at least as tall as its window needs.
tile_split_v :: proc(s: ^Server, col: Tile_Rect, wins: []^Toplevel) -> ^Toplevel {
	n := len(wins)
	if n == 0 {
		return nil
	}
	g := s.cfg.gaps_in
	need := make([]int, n, context.temp_allocator)
	hs := make([]int, n, context.temp_allocator)
	for t, i in wins {
		need[i] = tile_need_h(t)
	}
	ok, worst := tile_share(col.h - g * (n - 1), need, hs)
	if !ok {
		return wins[worst]
	}
	y := col.y
	for t, i in wins {
		tile_place(s, t, {col.x, y, col.w, hs[i]})
		y += hs[i] + g
	}
	return nil
}

tile_master_stack :: proc(s: ^Server, ws: ^Ws_Workspace, area: Tile_Rect, wins: []^Toplevel) -> ^Toplevel {
	n := len(wins)
	if n == 0 {
		return nil
	}
	mc := clamp(ws.master_count, 1, n)
	widest :: proc(wins: []^Toplevel) -> (need: int, who: ^Toplevel) {
		for t in wins {
			if v := tile_need_w(t); v > need {
				need, who = v, t
			}
		}
		return
	}
	if n <= mc {
		if need, who := widest(wins); need > area.w {
			return who
		}
		return tile_split_v(s, area, wins)
	}
	g := s.cfg.gaps_in
	ratio := clamp(ws.master_ratio, 0.15, 0.85)
	mw := int(f32(area.w - g) * ratio)
	need_m, who_m := widest(wins[:mc])
	need_s, who_s := widest(wins[mc:])
	lo := max(MIN_W, need_m)
	hi := area.w - g - max(MIN_W, need_s)
	if lo > hi {
		// Both columns cannot have what they need. The greedier window goes.
		return need_m >= need_s ? who_m : who_s
	}
	// The ratio is what the user asked for; a minimum only overrides it as
	// far as it must.
	mw = clamp(mw, lo, hi)
	if who := tile_split_v(s, {area.x, area.y, mw, area.h}, wins[:mc]); who != nil {
		return who
	}
	return tile_split_v(s, {area.x + mw + g, area.y, area.w - mw - g, area.h}, wins[mc:])
}

tile_monocle :: proc(s: ^Server, ws: ^Ws_Workspace, area: Tile_Rect, wins: []^Toplevel) -> ^Toplevel {
	for t in wins {
		if tile_need_w(t) > area.w || tile_need_h(t) > area.h {
			return t
		}
	}
	for t in wins {
		tile_place(s, t, area)
	}
	return nil
}

tile_grid :: proc(s: ^Server, ws: ^Ws_Workspace, area: Tile_Rect, wins: []^Toplevel) -> ^Toplevel {
	n := len(wins)
	if n == 0 {
		return nil
	}
	g := s.cfg.gaps_in
	cols := int(math.ceil(math.sqrt(f32(n))))
	cols = max(cols, 1)
	rows := (n + cols - 1) / cols
	cw := (area.w - g * (cols - 1)) / cols
	ch := (area.h - g * (rows - 1)) / rows
	// Check every cell before placing any, so a window that does not fit is
	// found before its neighbours have been configured to sizes that are
	// about to change again.
	worst: ^Toplevel
	worst_over := 0
	for t, i in wins {
		cx := i % cols
		cy := i / cols
		w := cx == cols - 1 ? area.w - cx * (cw + g) : cw
		h := cy == rows - 1 ? area.h - cy * (ch + g) : ch
		over := max(tile_need_w(t) - w, 0) + max(tile_need_h(t) - h, 0)
		if over > worst_over {
			worst, worst_over = t, over
		}
	}
	if worst != nil {
		return worst
	}
	for t, i in wins {
		cx := i % cols
		cy := i / cols
		x := area.x + cx * (cw + g)
		y := area.y + cy * (ch + g)
		w := cx == cols - 1 ? area.x + area.w - x : cw
		// The last row stretches to fill whatever the integer division left.
		h := cy == rows - 1 ? area.y + area.h - y : ch
		tile_place(s, t, {x, y, max(w, MIN_W), max(h, MIN_H)})
	}
	return nil
}

// tile_windows is the ordered list a layout sees: mapped, not minimised, not
// floating, bottom-to-top, which makes the oldest window the master.
tile_windows :: proc(s: ^Server, idx: int, allocator := context.temp_allocator) -> []^Toplevel {
	out := make([dynamic]^Toplevel, 0, 8, allocator)
	for t in ws_stack(s, idx) {
		// A maximized window keeps its cell, so maximizing and restoring a
		// tiled window never moves the others (UX.md P0-2); tile_place leaves
		// its geometry alone while it is maximized.
		if !t.mapped || t.minimized || ws_floating(t) {
			continue
		}
		append(&out, t)
	}
	// Give any window that has no tiling position yet one, in stack order,
	// before sorting. Assigning it lazily inside the comparison meant the
	// order depended on which pair the sort happened to look at first, and
	// the master column was whichever window the sort touched soonest.
	for t in out {
		ws_win(t)
	}
	// Insertion sort on `seq`: the list is a handful of windows long, and the
	// order has to be stable under raising, focusing and restacking.
	for i in 1 ..< len(out) {
		v := out[i]
		k := ws_win(v).seq
		j := i - 1
		for j >= 0 && ws_win(out[j]).seq > k {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = v
	}
	return out[:]
}

// tile_apply lays out *every* workspace, not just the visible ones.
//
// Laying out only what is on screen was the obvious thing and it was wrong:
// a window moved to a hidden workspace kept the cell it had on the old one,
// and then visibly resized a beat after you switched to it. Configures are
// only sent when a size actually changes, so doing the whole set costs
// nothing and the switch is instant.
tile_apply :: proc(s: ^Server) {
	ws_ensure(s)
	for idx in 0 ..< len(s.workspaces) {
		w := &s.workspaces[idx]
		if !w.tiling {
			continue
		}
		oi := w.output
		if oi < 0 || oi >= len(s.outputs) || !s.outputs[oi].enabled {
			oi = s.cur_out
		}
		// A window the layout floated because it did not fit gets another
		// chance every pass: the output may have grown, or a neighbour gone.
		for t in ws_stack(s, idx) {
			if m, ok := ws_peek(t); ok && m.auto_float && m.floating && !m.sticky {
				m.floating = false
			}
		}
		area := tile_area_ws(s, idx, oi)
		w.tiled_in = area
		wins := tile_windows(s, idx)
		if len(wins) == 0 {
			continue
		}
		fn := TILE_LAYOUTS[clamp(w.layout, 0, len(TILE_LAYOUTS) - 1)].fn
		for _ in 0 ..< 32 {
			who := fn(s, w, area, wins)
			if who == nil {
				break
			}
			// Before floating it over everything, see whether the window
			// that does not fit would as the first window — the master
			// column, which can grow to nearly the full width. A gallery
			// with a 720x480 minimum opened next to a small counter fits as
			// master with the counter and a terminal stacked beside it,
			// where floating it centred covered both. The swap is of
			// tiling positions, so it holds on every later pass.
			if who != wins[0] {
				trial := make([]^Toplevel, len(wins), context.temp_allocator)
				copy(trial, wins)
				for x, i in trial {
					if x == who {
						trial[i] = trial[0]
					}
				}
				trial[0] = who
				if fn(s, w, area, trial) == nil {
					a, b := ws_win(who), ws_win(wins[0])
					a.seq, b.seq = b.seq, a.seq
					note(s, fmt.tprintf("%s made master: it fits nowhere else", title_of(who)))
					break
				}
			}
			tile_auto_float(s, who, area)
			wins = tile_windows(s, idx)
			if len(wins) == 0 {
				break
			}
		}
		for t in ws_stack(s, idx) {
			if m, ok := ws_peek(t); ok && m.auto_float && !m.floating {
				m.auto_float = false // it fits again, and is tiled like any other
			}
		}
	}
}

// tile_auto_float takes a window out of the layout because its minimum size
// fits no cell, and floats it centred at that minimum, on top of the layout
// rather than overlapping a tile.
tile_auto_float :: proc(s: ^Server, t: ^Toplevel, area: Tile_Rect) {
	m := ws_win(t)
	m.floating = true
	if m.auto_float {
		return // it was already floating this way: leave it where it is
	}
	m.auto_float = true
	w := min(max(t.req_w, t.min_w, MIN_W), area.w - 2 * ws_border(t))
	h := min(max(t.req_h, t.min_h, MIN_H), area.h - ws_title_h(t) - ws_border(t))
	w = max(w, t.min_w)
	h = max(h, t.min_h)
	t.x = area.x + max((area.w - w) / 2, 0)
	t.y = area.y + ws_title_h(t) + max((area.h - h - ws_title_h(t)) / 2, 0)
	if w != t.req_w || h != t.req_h {
		t.req_w, t.req_h = w, h
		if ws_alive(s, t) || s.listen == 0 {
			send_configure(s, t, w, h)
		}
	}
	raise_window(s, t)
	s.dirty = true
}

// ws_tick is the once-per-frame housekeeping: prune dead windows, honour any
// workspace a rule asked for, re-run the layout, and check the config file.
ws_tick :: proc(s: ^Server) {
	ws_ensure(s)
	ws_prune(s)
	popup_tick(s)

	// A rule may have asked for a workspace this window is not on yet.
	for {
		moved := false
		for t in s.stack {
			m, ok := ws_peek(t)
			if !ok || m.want_ws == 0 {
				continue
			}
			target := m.want_ws - 1
			m.want_ws = 0
			if target >= 0 && target < len(s.workspaces) && target != s.cur_ws {
				ws_move_to(s, t, target)
				moved = true
				break
			}
		}
		if !moved {
			break
		}
	}

	// A window snapped to a side, resized, moved off or closed changes the
	// room the layout has (tile_area_ws), whichever path changed it.
	if cw := &s.workspaces[s.cur_ws]; cw.tiling && len(s.stack) > 0 {
		oi := cw.output
		if oi < 0 || oi >= len(s.outputs) || !s.outputs[oi].enabled {
			oi = s.cur_out
		}
		if tile_area_ws(s, s.cur_ws, oi) != cw.tiled_in {
			s.needs_layout = true
		}
	}
	if s.needs_layout {
		s.needs_layout = false
		tile_apply(s)
	}
}

// ---------------------------------------------------------------------------
// Window-level operations the bindings call
// ---------------------------------------------------------------------------

ws_toggle_float :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	m := ws_win(t)
	m.floating = !m.floating
	m.auto_float = false
	m.snap = .None
	m.snap_tile = false
	if t.maximized {
		t.maximized = false
	}
	if m.floating {
		if m.have_float {
			t.x, t.y = m.float_rect[0], m.float_rect[1]
			resize_to(s, t, m.float_rect[2], m.float_rect[3])
		} else {
			// Shrink it off the grid so it reads as floating at a glance.
			w := max(t.w * 3 / 4, MIN_W)
			h := max(t.h * 3 / 4, MIN_H)
			t.x += (t.w - w) / 2
			t.y += (t.h - h) / 2
			resize_to(s, t, w, h)
		}
		raise_window(s, t)
	} else {
		m.float_rect = {t.x, t.y, t.req_w, t.req_h}
		m.have_float = true
		t.last_cfg_w = -1
	}
	ws_restack(s)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("%s %s", title_of(t), m.floating ? "floating" : "tiled"))
}

// ws_float_for_drag is what grabbing a tiled window means. Dragging a window
// the layout engine owns and watching it snap back is the single most
// irritating thing a tiling WM can do, so the grab floats it instead.
ws_float_for_drag :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	ws_ensure(s)
	if !s.workspaces[s.cur_ws].tiling {
		return
	}
	m := ws_win(t)
	if m.floating || t.maximized {
		return
	}
	m.floating = true
	m.float_rect = {t.x, t.y, t.req_w, t.req_h}
	m.have_float = true
	s.needs_layout = true
	note(s, fmt.tprintf("%s floating", title_of(t)))
}

ws_toggle_tiling :: proc(s: ^Server) {
	ws_ensure(s)
	w := &s.workspaces[s.cur_ws]
	w.tiling = !w.tiling
	if !w.tiling {
		// Leaving tiling: give each window back the size it had while
		// floating — or something clearly smaller than the screen if it has
		// never floated — and then cascade. Windows left at their tiled size
		// would otherwise all sit on top of each other full-bleed.
		_, _, ow, oh := ws_output_rect(s, s.cur_out)
		for t in s.stack {
			if !t.mapped {
				continue
			}
			m := ws_win(t)
			if m.have_float {
				resize_to(s, t, m.float_rect[2], m.float_rect[3])
			} else {
				resize_to(s, t, ow * 5 / 9, (oh - ws_bar_h(s)) * 5 / 8)
			}
		}
		cascade_all(s)
	}
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("workspace %s: %s", w.name, w.tiling ? tile_layout_name(w.layout) : "floating"))
}

ws_next_layout :: proc(s: ^Server) {
	ws_ensure(s)
	w := &s.workspaces[s.cur_ws]
	w.layout = (w.layout + 1) % len(TILE_LAYOUTS)
	w.tiling = true
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("layout: %s", tile_layout_name(w.layout)))
}

ws_master_ratio :: proc(s: ^Server, delta_pct: int) {
	ws_ensure(s)
	w := &s.workspaces[s.cur_ws]
	w.master_ratio = clamp(w.master_ratio + f32(delta_pct) / 100.0, 0.15, 0.85)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("master %.0f%%", w.master_ratio * 100))
}

ws_master_count :: proc(s: ^Server, delta: int) {
	ws_ensure(s)
	w := &s.workspaces[s.cur_ws]
	w.master_count = clamp(w.master_count + delta, 1, 8)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("%d in master", w.master_count))
}

// ws_swap_master promotes the focused window to the head of the tiled order,
// which is the one tiling gesture everybody uses.
ws_swap_master :: proc(s: ^Server) {
	t := s.focus
	if t == nil || ws_floating(t) {
		return
	}
	wins := tile_windows(s, s.cur_ws)
	if len(wins) < 2 || wins[0] == t {
		return
	}
	ws_win(t).seq = ws_win(wins[0]).seq - 1
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("%s to master", title_of(t)))
}

// ws_swap_dir reorders the tiled list. Left and Up move the focused window
// earlier (towards master); Right and Down move it later.
ws_swap_dir :: proc(s: ^Server, dir: Cfg_Dir) {
	t := s.focus
	if t == nil {
		return
	}
	wins := tile_windows(s, s.cur_ws)
	step := (dir == .Left || dir == .Up) ? -1 : 1
	for w, i in wins {
		if w != t {
			continue
		}
		j := i + step
		if j < 0 || j >= len(wins) {
			return
		}
		a := ws_win(t)
		b := ws_win(wins[j])
		a.seq, b.seq = b.seq, a.seq
		s.needs_layout = true
		s.dirty = true
		note(s, fmt.tprintf("%s moved %v", title_of(t), dir))
		return
	}
}

// ws_focus_dir picks the nearest window whose centre lies in that direction.
ws_focus_dir :: proc(s: ^Server, dir: Cfg_Dir) {
	cur := s.focus
	if cur == nil {
		cycle_focus(s, false)
		return
	}
	cx := cur.x + cur.w / 2
	cy := cur.y + cur.h / 2
	best: ^Toplevel
	best_d := max(int)
	for t in s.stack {
		if t == cur || !t.mapped || t.minimized {
			continue
		}
		tx := t.x + t.w / 2
		ty := t.y + t.h / 2
		dx := tx - cx
		dy := ty - cy
		ok := false
		switch dir {
		case .Left:
			ok = dx < 0 && abs(dx) >= abs(dy)
		case .Right:
			ok = dx > 0 && abs(dx) >= abs(dy)
		case .Up:
			ok = dy < 0 && abs(dy) > abs(dx)
		case .Down:
			ok = dy > 0 && abs(dy) > abs(dx)
		}
		if !ok {
			continue
		}
		d := dx * dx + dy * dy
		if d < best_d {
			best_d = d
			best = t
		}
	}
	if best != nil {
		focus_window(s, best)
		ix_reveal(s, best)
		note(s, fmt.tprintf("focus %s", title_of(best)))
	}
}

// ---------------------------------------------------------------------------
// Autostart
//
// Empty by default, on purpose: a compositor that runs commands nobody
// configured on its first launch is a footgun, not a feature.
// ---------------------------------------------------------------------------

ws_autostart :: proc(s: ^Server) {
	for argv in s.cfg.autostart {
		if len(argv) == 0 {
			continue
		}
		spawn(s, argv)
	}
	if len(s.cfg.autostart) > 0 {
		fmt.printfln("wm: autostart ran %d command(s) from %s", len(s.cfg.autostart), s.cfg.path)
	}
}

// ---------------------------------------------------------------------------
// `wm --ws-shots <dir>`: the layouts and the workspace strip, offscreen
//
// shot.odin fabricates clients for the floating desktop; this reuses exactly
// the same machinery to picture each tiling layout and each workspace state,
// because a layout that asserts correct and looks wrong is worth nothing.
// ---------------------------------------------------------------------------

Ws_Shot_Win :: struct {
	t:     ^Toplevel,
	paint: Painter,
}

ws_shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("wm: could not create %s", dir)
		return 1
	}
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	p.set_text_gamma(1.8)

	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height, app.win.scale = SHOT_W, SHOT_H, 1
	app.fonts = off.fonts
	app.fps = 60
	cv := p.offscreen_canvas(off)

	s := &server
	s.out_w, s.out_h = SHOT_W, SHOT_H
	s.path = "/run/user/1000/wayland-palmy"
	s.display_name = "wayland-palmy"
	ws_ensure(s)
	for _ in 0 ..< 4 {
		append(&s.clients, new(Client))
	}

	wins := make([dynamic]Ws_Shot_Win)
	add :: proc(
		s: ^Server,
		wins: ^[dynamic]Ws_Shot_Win,
		title, app_id: string,
		w, h: int,
		paint: Painter,
	) -> ^Toplevel {
		t := fake_window(s, title, app_id, 100, 120, w, h, paint)
		// fake_window gives the surface no client; the real map path always
		// does, and focus routing dereferences it.
		t.xdg.surf.client = t.client
		append(wins, Ws_Shot_Win{t, paint})
		return t
	}

	// Fabricated clients do not ack a configure, so this is what their commit
	// would be: take the size we asked for, and repaint at it.
	commit :: proc(wins: []Ws_Shot_Win) {
		for w in wins {
			if w.t.req_w > 0 && w.t.req_h > 0 && (w.t.w != w.t.req_w || w.t.h != w.t.req_h) {
				w.t.w, w.t.h = w.t.req_w, w.t.req_h
			}
			repaint(w.t, w.paint)
		}
	}
	settle :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, wins: []Ws_Shot_Win) {
		for _ in 0 ..< 3 {
			s.needs_layout = true
			ws_tick(s)
			commit(wins)
			draw(s, app, cv)
			free_all(context.temp_allocator)
		}
	}
	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	editor := add(s, &wins, "renderer.odin — Codex", "codex", 700, 520, paint_editor)
	term := add(s, &wins, "shellward: ~/src/palmy", "foot", 620, 400, paint_term)
	gallery := add(s, &wins, "Tessera — Library", "tessera", 680, 450, paint_gallery)
	s.focus = editor
	editor.activated = true

	w := &s.workspaces[s.cur_ws]
	w.tiling = true
	w.layout, _ = tile_layout_by_name("master")

	settle(s, app, cv, wins[:])
	shot(off, dir, "20-tile-master-3", &n)

	// A fourth and a fifth window, and the master column widened: the stack
	// column has to re-split without the master moving.
	meter := add(s, &wins, "Sentinel", "sentinel", 420, 300, paint_meter)
	notes := add(s, &wins, "notes.md", "notes", 500, 320, paint_editor)
	_ = meter
	_ = notes
	w.master_ratio = 0.62
	settle(s, app, cv, wins[:])
	shot(off, dir, "21-tile-master-5", &n)

	// Two in the master column.
	w.master_count = 2
	settle(s, app, cv, wins[:])
	shot(off, dir, "22-tile-master-2up", &n)

	w.master_count = 1
	w.layout, _ = tile_layout_by_name("grid")
	settle(s, app, cv, wins[:])
	shot(off, dir, "23-tile-grid", &n)

	w.layout, _ = tile_layout_by_name("monocle")
	s.focus = gallery
	editor.activated = false
	gallery.activated = true
	raise_window(s, gallery)
	settle(s, app, cv, wins[:])
	shot(off, dir, "24-tile-monocle", &n)

	// One window floated out of the grid: the tiled ones must close the hole.
	w.layout, _ = tile_layout_by_name("master")
	ws_win(term).floating = true
	term.x, term.y = 520, 420
	term.req_w, term.req_h = 560, 340
	settle(s, app, cv, wins[:])
	shot(off, dir, "25-tile-one-floating", &n)

	// Bigger gaps, which is the setting people actually change first.
	ws_win(term).floating = false
	s.cfg.gaps_in = 18
	s.cfg.gaps_out = 28
	settle(s, app, cv, wins[:])
	shot(off, dir, "26-tile-gaps", &n)
	s.cfg.gaps_in = 6
	s.cfg.gaps_out = 10

	// Workspaces: move two windows away, then switch to an empty one.
	ws_move_to(s, gallery, 1)
	ws_move_to(s, meter, 2)
	settle(s, app, cv, wins[:])
	shot(off, dir, "27-workspace-1-of-3", &n)

	ws_switch(s, 1)
	settle(s, app, cv, wins[:])
	shot(off, dir, "28-workspace-2", &n)

	ws_switch(s, 4)
	settle(s, app, cv, wins[:])
	shot(off, dir, "29-workspace-empty", &n)

	ws_switch(s, 0)
	// The toggle back to floating, through the same path a binding takes.
	ws_toggle_tiling(s)
	settle(s, app, cv, wins[:])
	shot(off, dir, "30-workspace-floating", &n)

	delete(wins)
	fmt.printfln("wm --ws-shots: %d PNGs in %s", n, dir)
	return 0
}

// ---------------------------------------------------------------------------
// `wm --selftest`: assertions for the parts that have no pixels
//
// The pictures cover what a layout looks like. These cover what it is: the
// arithmetic, the parser, and the teardown paths a demo never reaches — a
// client that dies mid-drag, a zero-sized surface, a workspace whose last
// window closes. Several of these exist because the behaviour was wrong the
// first time.
// ---------------------------------------------------------------------------

ws_test_pass: int
ws_test_fail: int

ws_check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		ws_test_pass += 1
		return
	}
	ws_test_fail += 1
	fmt.eprintfln("  FAIL %s", fmt.tprintf(what, ..args))
}

ws_eq :: proc(got, want: int, what: string) {
	if got == want {
		ws_test_pass += 1
		return
	}
	ws_test_fail += 1
	fmt.eprintfln("  FAIL %s: got %d, want %d", what, got, want)
}

ws_near :: proc(got, want, tol: int, what: string) {
	if abs(got - want) <= tol {
		ws_test_pass += 1
		return
	}
	ws_test_fail += 1
	fmt.eprintfln("  FAIL %s: got %d, want %d±%d", what, got, want, tol)
}

ws_test_client :: proc(s: ^Server) -> ^Client {
	c := new(Client)
	c.objs = make(map[u32]Object)
	append(&s.clients, c)
	return c
}

// ws_test_win fabricates a mapped toplevel with a surface but no pixels. It
// is the smallest thing the layout engine and the teardown paths accept.
ws_test_win :: proc(s: ^Server, c: ^Client, title, app_id: string, w, h: int) -> ^Toplevel {
	surf := new(Surface)
	surf.client = c
	surf.id = u32(len(s.surfaces) + 100)
	surf.iw, surf.ih, surf.scale = w, h, 1
	surf.role = .Xdg
	append(&s.surfaces, surf)

	x := new(Xdg_Surface)
	x.client = c
	x.surf = surf
	surf.xdg = x

	t := new(Toplevel)
	t.client = c
	t.id = u32(len(s.surfaces) + 500)
	t.xdg = x
	x.top = t
	t.title = strings.clone(title)
	t.app_id = strings.clone(app_id)
	t.w, t.h = w, h
	t.req_w, t.req_h = w, h
	t.mapped = true
	c.objs[t.id] = Object{kind = .Toplevel, ver = 1, p = rawptr(t)}
	return t
}

ws_test_reset :: proc(s: ^Server) {
	clear(&s.stack)
	for &w in s.workspaces {
		clear(&w.stack)
		w.last_focus = nil
		w.tiling = s.cfg.tiling
		w.layout = s.cfg.layout
		w.master_ratio = s.cfg.master_ratio
		w.master_count = s.cfg.master_count
	}
	s.cur_ws = 0
	s.cur_out = 0
	for &o in s.outputs {
		o.active = 0
	}
	s.focus = nil
	s.kbd_surf = nil
	s.ptr_surf = nil
	s.drag = .None
	s.drag_t = nil
	s.hover_t = nil
	for t in ws_meta {
		free(ws_meta[t])
	}
	clear(&ws_meta)
}

ws_selftest :: proc() -> int {
	s := &server
	s.out_w, s.out_h = 1600, 940
	s.listen = 0

	// --- the parser -------------------------------------------------------
	{
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, CFG_DEFAULT, "<built-in>")
		ws_eq(len(c.errors), 0, "the built-in default parses with no errors")
		ws_check(len(c.binds) > 40, "the default binds more than 40 chords (got %d)", len(c.binds))
		ws_eq(len(c.autostart), 0, "the default autostarts nothing")
		ws_eq(len(c.rules), 0, "the default has no window rules")
		ws_eq(int(c.border_focus), 0x6366f1, "a #rrggbb colour survives comment stripping")
		ws_check(c.mod == {.Super}, "the default modifier is SUPER")
		ws_eq(c.workspaces, 9, "nine workspaces by default")
		cfg_destroy(&c)
	}
	{
		// A colour is not a comment; a leading # is; an inline // is.
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(
			&c,
			"# a comment\nborder_focus = #22c55e\nborder = 3 // inline\ngaps_in = 4\n",
			"t",
		)
		ws_eq(len(c.errors), 0, "a file of colours and comments parses clean")
		ws_eq(int(c.border_focus), 0x22c55e, "border_focus reads a hex colour")
		ws_eq(c.border, 3, "an inline // comment is stripped from a number")
		ws_eq(c.gaps_in, 4, "a later setting still applies")
		cfg_destroy(&c)
	}
	{
		// A broken line costs that line and nothing else.
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, "nonsense = 1\nbind = $mod, Q, close\nbind = $mod, Z, floop\n", "t")
		ws_eq(len(c.errors), 2, "two bad lines produce two errors")
		ws_eq(len(c.binds), 1, "the good binding between them survives")
		ws_check(c.binds[0].act == .Close, "the surviving binding is the right one")
		cfg_destroy(&c)
	}
	{
		// A later bind on the same chord replaces the earlier one.
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, "bind = SUPER, Q, close\nbind = SUPER, Q, spawn foot\n", "t")
		ws_eq(len(c.binds), 1, "rebinding a chord does not duplicate it")
		ws_check(c.binds[0].act == .Spawn, "the last binding for a chord wins")
		ws_check(len(c.binds[0].argv) == 1 && c.binds[0].argv[0] == "foot", "spawn keeps its argv")
		cfg_destroy(&c)
	}
	{
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(
			&c,
			"mod = ALT\nbind = $mod SHIFT, 3, movetoworkspace 3\nbind = ANY, F6, focusnext\n",
			"t",
		)
		ws_eq(len(c.errors), 0, "$mod expands to the configured modifier")
		ws_check(c.binds[0].mods == {.Alt, .Shift}, "$mod SHIFT is Alt+Shift")
		ws_check(c.binds[0].act == .Move_To_Workspace && c.binds[0].arg == 3, "movetoworkspace 3")
		ws_check(c.binds[1].any_mods, "ANY binds whatever is held")
		cfg_destroy(&c)
	}
	{
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(
			&c,
			"rule = app_id=foot, float, noborder\nrule = title~Volume, workspace 4\nrule = float\n",
			"t",
		)
		ws_eq(len(c.rules), 2, "a rule with no matcher is rejected")
		ws_eq(len(c.errors), 1, "and says so")
		ws_check(c.rules[0].app_id == "foot" && c.rules[0].float && c.rules[0].no_border, "app_id rule")
		ws_check(c.rules[1].title == "Volume" && c.rules[1].workspace == 4, "title rule")
		cfg_destroy(&c)
	}
	{
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, "output = DP-2, 2560x1440+1920+0, scale=2, workspaces=6-9\n", "t")
		ws_eq(len(c.outputs), 1, "an output line is read")
		o := c.outputs[0]
		ws_check(o.name == "DP-2", "the connector name")
		ws_eq(o.w, 2560, "output width")
		ws_eq(o.h, 1440, "output height")
		ws_eq(o.x, 1920, "output x")
		ws_eq(o.y, 0, "output y")
		ws_check(o.scale == 2, "output scale")
		ws_eq(o.ws_lo, 6, "first workspace on that head")
		ws_eq(o.ws_hi, 9, "last workspace on that head")
		cfg_destroy(&c)
	}
	{
		// Session actions are intent only: they parse to .Session and carry a
		// name, and nothing in wm_do executes anything for them.
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, "bind = SUPER, X, reboot\nbind = SUPER, Y, exit\n", "t")
		ws_check(c.binds[0].act == .Session, "reboot is a session intent")
		ws_check(cfg_session_name(c.binds[0].arg) == "reboot", "and keeps its name")
		ws_check(c.binds[1].act == .Session, "exit is a session intent, not a quit")
		cfg_destroy(&c)
	}
	{
		argv := cfg_argv(`foot -e "sh -c" 'one two'`)
		ws_eq(len(argv), 4, "quoting keeps a word together")
		ws_check(argv[2] == "sh -c", "double quotes")
		ws_check(argv[3] == "one two", "single quotes")
		for a in argv {delete(a)}
		delete(argv)
	}
	{
		sym, ok := cfg_keysym("Return")
		ws_check(ok && sym == p.KEY_RETURN, "a named key")
		sym2, ok2 := cfg_keysym("Q")
		ws_check(ok2 && sym2 == 'q', "a letter is folded to lower case")
		ws_check(cfg_sym_matches('q', 'Q'), "and matches the shifted symbol the host sends")
		_, bad := cfg_keysym("Nonesuch")
		ws_check(!bad, "an unknown key name is rejected")
	}
	{
		// No command may be an absolute path compiled into this binary.
		_, found := cfg_which("sh")
		ws_check(found, "a command on $PATH resolves")
		_, missing := cfg_which("palmy-definitely-not-a-real-command")
		ws_check(!missing, "a command that does not exist does not resolve")
		ws_check(!strings.contains(CFG_DEFAULT, "/home/"), "no home directory is baked into the default config")
	}

	// --- layouts ----------------------------------------------------------
	cfg_scalars(&s.cfg)
	cfg_parse(&s.cfg, CFG_DEFAULT, "<built-in>")
	ws_ensure(s)
	c := ws_test_client(s)

	{
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		append(&s.stack, a)
		tile_apply(s)
		area := tile_area(s, 0)
		ws_eq(a.x, area.x + s.cfg.border, "one tiled window starts at the gap")
		ws_eq(a.y, area.y + s.cfg.title_h, "below the bar and its own title bar")
		ws_eq(a.req_w, area.w - 2 * s.cfg.border, "and fills the width")
		ws_eq(a.req_h, area.h - s.cfg.title_h - s.cfg.border, "and the height")
		ws_eq(area.x, s.cfg.gaps_out, "the outer gap is honoured on the left")
		ws_eq(area.y, s.cfg.bar_h + s.cfg.gaps_out, "and under the bar")
	}
	{
		ws_test_reset(s)
		wins: [3]^Toplevel
		for i in 0 ..< 3 {
			wins[i] = ws_test_win(s, c, "w", "app", 400, 300)
			append(&s.stack, wins[i])
		}
		tile_apply(s)
		area := tile_area(s, 0)
		ratio := s.workspaces[0].master_ratio
		ws_near(wins[0].req_w, int(f32(area.w - s.cfg.gaps_in) * ratio) - 2 * s.cfg.border, 2, "master width follows the ratio")
		ws_check(wins[1].x == wins[2].x, "the stack column shares an x")
		ws_check(wins[1].x > wins[0].x + wins[0].req_w, "and sits right of the master")
		ws_check(wins[2].y > wins[1].y + wins[1].req_h, "the stack splits vertically without overlapping")
		bottom := wins[2].y + wins[2].req_h + s.cfg.border
		ws_near(bottom, area.y + area.h, 2, "the last stack window reaches the bottom gap")
		// Raising a window must not reorder the layout.
		before := wins[0].x
		raise_window(s, wins[2])
		focus_window(s, wins[2])
		tile_apply(s)
		ws_eq(wins[0].x, before, "focusing a stacked window does not move the master")
	}
	{
		ws_test_reset(s)
		wins: [4]^Toplevel
		for i in 0 ..< 4 {
			wins[i] = ws_test_win(s, c, "w", "app", 400, 300)
			append(&s.stack, wins[i])
		}
		s.workspaces[0].master_count = 2
		tile_apply(s)
		ws_check(wins[0].x == wins[1].x, "two windows in the master column share an x")
		ws_check(wins[2].x == wins[3].x, "and two in the stack")
		ws_check(wins[1].y > wins[0].y, "the master column splits vertically")
		s.workspaces[0].master_count = 1

		s.workspaces[0].layout, _ = tile_layout_by_name("monocle")
		tile_apply(s)
		same := true
		for i in 1 ..< 4 {
			if wins[i].x != wins[0].x || wins[i].req_w != wins[0].req_w {
				same = false
			}
		}
		ws_check(same, "monocle gives every window the same rectangle")

		s.workspaces[0].layout, _ = tile_layout_by_name("grid")
		tile_apply(s)
		ws_check(wins[0].x == wins[2].x && wins[1].x == wins[3].x, "a four-window grid is two columns")
		ws_check(wins[2].y > wins[0].y, "and two rows")
		ws_check(wins[1].x > wins[0].x, "with the second window to the right of the first")

		s.workspaces[0].layout, _ = tile_layout_by_name("master")
		ws_win(wins[1]).floating = true
		wins[1].x, wins[1].y = 777, 555
		tile_apply(s)
		ws_eq(wins[1].x, 777, "a floating window is left alone by the layout")
		ws_eq(len(tile_windows(s, 0)), 3, "and is not counted by it")
	}
	{
		// Gaps come from the config, not from a constant.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a)
		append(&s.stack, b)
		s.cfg.gaps_in, s.cfg.gaps_out = 20, 40
		tile_apply(s)
		ws_eq(a.x - s.cfg.border, 40, "a wider outer gap moves the master")
		ws_eq(b.x - a.x - a.req_w - 2 * s.cfg.border, 20, "and a wider inner gap separates the columns")
		s.cfg.gaps_in, s.cfg.gaps_out = 6, 10
	}

	// --- workspaces -------------------------------------------------------
	{
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a)
		append(&s.stack, b)
		focus_window(s, b)
		ws_eq(ws_total_windows(s), 2, "two windows, one workspace")

		ws_move_to(s, b, 2)
		ws_eq(len(s.stack), 1, "moving a window takes it off this workspace")
		ws_eq(len(s.workspaces[2].stack), 1, "and puts it on that one")
		ws_eq(ws_total_windows(s), 2, "without losing it")
		ws_check(s.focus == a, "focus falls back to what is left")
		ws_eq(ws_index_of(s, b), 2, "and it can still be found")

		ws_switch(s, 2)
		ws_eq(s.cur_ws, 2, "switching changes the current workspace")
		ws_eq(len(s.stack), 1, "the live stack is the new workspace's")
		ws_check(s.stack[0] == b, "with the window that was moved there")
		ws_check(s.focus == b, "which takes focus")
		ws_eq(len(s.workspaces[0].stack), 1, "and the old one is parked")

		ws_switch(s, 0)
		ws_check(s.focus == a, "coming back restores the focus that was there")

		// The last window on a workspace closing leaves it genuinely empty.
		ws_switch(s, 2)
		unmap_window(s, b)
		ws_eq(len(s.stack), 0, "the last window closing empties the workspace")
		ws_check(s.focus == nil, "and leaves nothing focused")
		cycle_focus(s, false)
		ws_check(s.focus == nil, "cycling focus on an empty workspace does nothing")
		ws_switch(s, 0)
	}
	{
		// A window dying on a workspace you are not looking at.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a)
		append(&s.stack, b)
		ws_move_to(s, b, 3)
		unmap_window(s, b)
		ws_eq(len(s.workspaces[3].stack), 0, "a window unmapped on a hidden workspace is removed from it")
		ws_eq(ws_index_of(s, b), -1, "and is nowhere")
		ws_eq(ws_total_windows(s), 1, "leaving the one that is still alive")
	}
	{
		// Every workspace is laid out, not just the visible one: switching to
		// a workspace must not be followed by a visible resize.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		b := ws_test_win(s, c, "b", "app", 400, 300)
		append(&s.stack, a)
		append(&s.stack, b)
		tile_apply(s)
		narrow := b.req_w
		ws_move_to(s, b, 1)
		tile_apply(s)
		ws_check(b.req_w > narrow, "a window moved to an empty workspace is laid out there straight away")
		ws_eq(b.req_w, tile_area(s, 0).w - 2 * s.cfg.border, "at the full width of it")
	}

	// --- survival ---------------------------------------------------------
	{
		// A client that dies mid-drag.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		append(&s.stack, a)
		focus_window(s, a)
		begin_move(s, a)
		ws_check(s.drag == .Move && s.drag_t == a, "a move drag starts")
		unmap_window(s, a)
		ws_check(s.drag == .None, "and is cancelled when the window dies under it")
		ws_check(s.drag_t == nil, "with no dangling pointer")
	}
	{
		// A client that dies mid-resize, holding the pointer.
		ws_test_reset(s)
		a := ws_test_win(s, c, "a", "app", 400, 300)
		append(&s.stack, a)
		focus_window(s, a)
		begin_resize_edges(s, a, 10)
		ws_check(s.drag == .Resize && a.resizing, "a resize drag starts")
		s.ptr_surf = a.xdg.surf
		unmap_window(s, a)
		ws_check(s.drag == .None, "the resize is cancelled")
		ws_check(s.ptr_surf == nil, "and the pointer grab is released")
		ws_check(s.kbd_surf == nil, "and the keyboard focus with it")
	}
	{
		// xdg_toplevel.set_parent: a dialog floats, centred over its parent,
		// and comes up with it.
		ws_test_reset(s)
		par := ws_test_win(s, c, "editor", "app", 900, 600)
		place_new_window(s, par)
		par.mapped = true
		append(&s.stack, par)
		dlg := ws_test_win(s, c, "Save as", "app", 300, 200)
		dlg.parent = par
		place_new_window(s, dlg)
		dlg.mapped = true
		append(&s.stack, dlg)
		ws_check(ws_floating(dlg), "a dialog floats instead of taking a cell")
		pc := par.x + par.w / 2
		dc := dlg.x + dlg.w / 2
		ws_check(abs(pc - dc) <= 2, "and opens centred over its parent: %d vs %d", dc, pc)
		other := ws_test_win(s, c, "other", "app", 400, 300)
		ws_win(other).floating = true
		other.mapped = true
		append(&s.stack, other)
		raise_window(s, par)
		di, pi := -1, -1
		for w, i in s.stack {
			if w == dlg {di = i}
			if w == par {pi = i}
		}
		ws_check(di > pi, "raising the parent keeps the dialog above it (%d over %d)", di, pi)
		top_parent_gone(s, par)
		ws_check(dlg.parent == nil, "a parent that goes away is forgotten")
	}
	{
		// wl_subsurface: a synchronized child's commit waits for its parent's;
		// a desynchronized one shows at once; set_position waits too.
		ws_test_reset(s)
		sc := ws_test_client(s)
		mem := make([]u8, 2 * 2 * 4)
		defer delete(mem)
		pool := Pool{client = sc, mem = mem, refs = 1}
		buf := Buffer{client = sc, id = 900, pool = &pool, w = 2, h = 2, stride = 8, format = 1}
		paint :: proc(mem: []u8, v: u8) {
			for i in 0 ..< len(mem) {mem[i] = v}
		}
		par := new(Surface)
		par.client = sc
		par.p_scale = 1
		ch := new(Surface)
		ch.client = sc
		ch.p_scale = 1
		ch.role = .Sub
		ch.parent = par
		append(&par.children, ch)
		defer {
			delete(par.children)
			delete(par.img)
			delete(ch.img)
			delete(ch.c_img)
			delete(ch.frames)
			delete(ch.c_frames)
			free(par)
			free(ch)
		}

		paint(mem, 0x11)
		ch.p_buffer, ch.p_buffer_set = &buf, true
		surface_commit(s, ch)
		ws_check(ch.img == nil && ch.c_has, "a synchronized child's commit is cached, not shown")
		ch.p_sx, ch.p_sy, ch.p_pos_set = 7, 9, true
		ws_check(ch.sx == 0, "set_position waits for the parent")
		surface_commit(s, par)
		ws_check(ch.img != nil && ch.img[0] & 0xff == 0x11, "the parent's commit shows it")
		ws_check(ch.sx == 7 && ch.sy == 9, "and moves it")
		ws_check(!ch.c_has, "and empties the cache")

		ch.sub_desync = true
		paint(mem, 0x22)
		ch.p_buffer, ch.p_buffer_set = &buf, true
		surface_commit(s, ch)
		ws_check(ch.img[0] & 0xff == 0x22, "a desynchronized child shows its commit at once")

		ch.sub_desync = false
		paint(mem, 0x33)
		ch.p_buffer, ch.p_buffer_set = &buf, true
		surface_commit(s, ch)
		ws_check(ch.img[0] & 0xff == 0x22, "synchronized again: cached")
		ch.sub_desync = true
		if !sub_synced(ch) && ch.c_has {
			sub_apply_cache(s, ch)
		}
		ws_check(ch.img[0] & 0xff == 0x33, "set_desync shows what was cached")
		pop(&s.clients)
		free(sc)
	}
	{
		// Scrolling at the detail each wl_pointer version understands.
		ws_test_reset(s)
		sc := ws_test_client(s)
		surf := new(Surface)
		surf.client = sc
		defer free(surf)
		sc.objs[40] = Object{kind = .Pointer, ver = 8}
		sc.objs[41] = Object{kind = .Pointer, ver = 5}
		append(&sc.pointers, 40, 41)
		s.ptr_surf = surf
		saved_bare := session.bare
		session.bare = true
		axis_detail = {v120 = {240, 0}, source = 0}
		ptr_axis(s, 0, 30)
		axis_detail = {stop = {true, true}, source = 1}
		ptr_axis(s, 0, 0)
		axis_detail = {}
		session.bare = saved_bare
		ops := make([dynamic][2]u32, context.temp_allocator) // object, opcode
		for off := 0; off + 8 <= len(sc.out); {
			hdr := (^u32)(&sc.out[off + 4])^
			append(&ops, [2]u32{(^u32)(&sc.out[off])^, hdr & 0xffff})
			off += max(int(hdr >> 16), 8)
		}
		has :: proc(ops: [dynamic][2]u32, obj, op: u32) -> bool {
			for o in ops {
				if o == {obj, op} {return true}
			}
			return false
		}
		ws_check(has(ops, 40, 6) && has(ops, 40, 9) && has(ops, 40, 4) && has(ops, 40, 5), "v8: axis_source, axis_value120, axis, frame: %v", ops[:])
		ws_check(!has(ops, 40, 8), "v8 gets no axis_discrete")
		ws_check(has(ops, 41, 8) && !has(ops, 41, 9), "v5: axis_discrete instead of axis_value120")
		ws_check(has(ops, 40, 7) && has(ops, 41, 7), "a finger lifting sends axis_stop")
		s.ptr_surf = nil
		pop(&s.clients)
		delete(sc.out)
		free(sc)
	}
	{
		// A surface that maps at zero, and one that maps absurdly large.
		ws_test_reset(s)
		z := ws_test_win(s, c, "zero", "app", 0, 0)
		place_new_window(s, z)
		ws_check(z.w >= 1 && z.h >= 1, "a zero-sized surface is clamped to something reachable")
		big := ws_test_win(s, c, "big", "app", 100000, 100000)
		place_new_window(s, big)
		ws_check(big.w <= s.out_w * 4, "an absurd width is clamped")
		ws_check(big.h <= max(s.out_h * 4, 4096), "an absurd height is clamped")
		append(&s.stack, z)
		clamp_window(s, z)
		ws_check(z.x < s.out_w && z.y < s.out_h, "and the window stays on an output")
	}
	{
		// Per-window state must not outlive the window, or a recycled heap
		// address inherits it.
		ws_test_reset(s)
		s.listen = 1 // pretend we are live, so ws_prune does its work
		dc := ws_test_client(s)
		a := ws_test_win(s, dc, "a", "app", 400, 300)
		ws_win(a).floating = true
		ws_eq(len(ws_meta), 1, "a window has per-window state")
		delete_key(&dc.objs, a.id) // the client destroyed its toplevel
		ws_prune(s)
		ws_eq(len(ws_meta), 0, "which is dropped when the client destroys it")
		ws_check(!ws_alive(s, a), "and the window is no longer live")
		s.listen = 0
	}
	{
		// A rule applied at map time.
		ws_test_reset(s)
		append(&s.cfg.rules, Cfg_Rule{app_id = strings.clone("pixels"), set_float = true, float = true, no_border = true})
		append(&s.cfg.rules, Cfg_Rule{title = strings.clone("Volume"), workspace = 3})
		a := ws_test_win(s, c, "demo", "pixels", 400, 300)
		place_new_window(s, a)
		append(&s.stack, a)
		ws_check(ws_floating(a), "a float rule floats the window it matches")
		ws_eq(ws_border(a), 0, "a noborder rule removes its border")
		b := ws_test_win(s, c, "Volume Control", "pavu", 400, 300)
		place_new_window(s, b)
		append(&s.stack, b)
		ws_tick(s)
		ws_eq(ws_index_of(s, b), 2, "a workspace rule sends the window there")
		d := ws_test_win(s, c, "plain", "other", 400, 300)
		place_new_window(s, d)
		ws_check(!ws_floating(d), "a window that matches nothing is untouched")
	}

	// --- outputs ----------------------------------------------------------
	{
		ws_test_reset(s)
		n0 := ws_output_count(s)
		i := ws_output_upsert(s, "DP-9", 1600, 0, 2560, 1440, 1)
		ws_eq(ws_output_count(s), n0 + 1, "a new head is added")
		x, y, w, h := ws_output_rect(s, i)
		ws_check(x == 1600 && y == 0 && w == 2560 && h == 1440, "with the rectangle it was given")
		j := ws_output_upsert(s, "DP-9", 1600, 0, 1920, 1080, 2)
		ws_eq(j, i, "declaring it again moves it rather than duplicating it")
		_, _, w2, _ := ws_output_rect(s, i)
		ws_eq(w2, 1920, "with the new mode")
		ws_eq(ws_output_at(s, 2000, 100), i, "a point on that head maps to it")
		ws_eq(ws_output_at(s, 10, 10), 0, "and a point on the first one to the first")

		s.workspaces[5].output = i
		ws_output_disable(s, "DP-9")
		ws_eq(s.workspaces[5].output, 0, "unplugging a head re-homes its workspaces rather than losing them")

		// The host-backed output keeps tracking the nested surface.
		ws_sync_host(s, 1280, 720)
		_, _, hw, hh := ws_output_rect(s, 0)
		ws_check(hw == 1280 && hh == 720, "the host output follows the nested canvas")
		ws_sync_host(s, 1600, 940)
	}

	// --- the interaction model (ux_test.odin) -----------------------------
	ux_selftest(s, c)

	// --- xdg_positioner placement (popup.odin) ----------------------------
	{
		pp, pf := popup_selftest()
		ws_test_pass += pp
		ws_test_fail += pf
	}

	// --- the start menu, the shell's look, the shared app index -----------
	start_selftest(s)

	// --- the lock screen and the power dialog (locker_test.odin) -------------
	locker_selftest(s)

	fmt.printfln("wm --selftest: %d passed, %d failed", ws_test_pass, ws_test_fail)
	return ws_test_fail == 0 ? 0 : 1
}
