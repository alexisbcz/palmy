// anim.odin — motion a software rasterizer can afford (UX.md P1-6).
//
// Every animation here interpolates a rectangle and an opacity, nothing
// else. The content is the window as it last drew — rendered once a frame
// into a scratch buffer at its real size, then scaled into the animated
// rectangle with nearest-neighbour sampling — so no client is ever asked to
// repaint per frame, and the cost is one scaled blit per animated window.
//
//   open         scale 0.95 → 1 about the centre, opacity 0 → 1   160 ms
//   close        scale 1 → 0.95, opacity 1 → 0, from a snapshot  120 ms
//   minimize     frame → its taskbar entry, then fades            200 ms
//   restore      taskbar entry → frame, opacity 0 → 1            200 ms
//   geometry     old frame rect → new (maximize, snap, tile)     160 ms
//   workspace    both workspaces slide by the output's width     200 ms
//
// A new animation on a window starts from wherever the current one is, so
// they can be interrupted. Input always goes to the final geometry: the
// animation is only how the window is drawn.
//
// `animations = on | off | reduced` (reduced: fades only, 100 ms). And the
// window manager watches itself: when the median time to draw an animated
// frame exceeds the 60 Hz budget, it drops to `reduced` for the session —
// motion that stutters is worse than none.
package wm

import "core:slice"
import p "palmy:."

Anim_Kind :: enum u8 {
	None,
	Open,
	Geometry,
	Minimize,
	Restore,
}

Win_Anim :: struct {
	kind: Anim_Kind,
	t0:   f64,
	dur:  f64,
	from: p.Rect, // frame rect the motion starts from
}

Ghost :: struct {
	px:   []u32,
	w, h: int,
	rect: p.Rect,
	t0:   f64,
	dur:  f64,
	ws:   int,
}

Anim_State :: struct {
	wins:         map[^Toplevel]Win_Anim,
	ghosts:       [dynamic]Ghost,
	scratch:      [dynamic]u32,
	ws_from:      int,
	ws_to:        int,
	ws_t0:        f64,
	ws_active:    bool,
	keep_going:   bool, // something on screen is still moving
	animated:     bool, // this frame drew an animation
	samples:      [dynamic]f64,
	draw_ms:      f64,
	auto_reduced: bool,
}

anim_state: Anim_State
anim_app: ^p.App

ANIM_OPEN :: 0.16
ANIM_CLOSE :: 0.12
ANIM_MIN :: 0.20
ANIM_GEOM :: 0.16
ANIM_WS :: 0.20
ANIM_REDUCED :: 0.10
ANIM_BUDGET_MS :: 16.7

// ease_out is a cubic ease-out: fast start, gentle landing.
ease_out :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

// ease_in is its mirror, for things leaving.
ease_in :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	return u * u * u
}

// ease_in_out is cubic both ways: a slow start, so the eye catches what is
// moving, and a slow landing.
ease_in_out :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	if u < 0.5 {
		return 4 * u * u * u
	}
	v := -2 * u + 2
	return 1 - v * v * v / 2
}

lerp_rect :: proc(a, b: p.Rect, k: f32) -> p.Rect {
	return {a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.w + (b.w - a.w) * k, a.h + (b.h - a.h) * k}
}

// scale_rect scales a rectangle about its centre.
scale_rect :: proc(r: p.Rect, k: f32) -> p.Rect {
	w := r.w * k
	h := r.h * k
	return {r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
}

anim_mode :: proc(s: ^Server) -> Cfg_Anim {
	if anim_state.auto_reduced && s.cfg.animations == .On {
		return .Reduced
	}
	return s.cfg.animations
}

anim_allowed :: proc(s: ^Server, t: ^Toplevel) -> bool {
	if anim_mode(s) == .Off || session.kiosk || s.listen == 0 {
		return false
	}
	if m, ok := ws_peek(t); ok && m.no_anim {
		return false
	}
	return true
}

anim_keep_going :: proc() {
	anim_state.keep_going = true
	anim_state.animated = true
}

// anim_busy says whether the next frame must be drawn even if nothing else
// happens: something is mid-motion.
anim_busy :: proc() -> bool {
	return anim_state.keep_going || len(anim_state.ghosts) > 0 || anim_state.ws_active || len(anim_state.wins) > 0
}

anim_has :: proc(t: ^Toplevel) -> bool {
	_, ok := anim_state.wins[t]
	return ok
}

anim_forget :: proc(t: ^Toplevel) {
	delete_key(&anim_state.wins, t)
}

// target_frame is where a window's frame is going: its requested geometry,
// which the client may not have committed yet.
target_frame :: proc(t: ^Toplevel) -> p.Rect {
	bw := f32(ws_border(t))
	th := f32(ws_title_h(t))
	return {f32(t.x) - bw, f32(t.y) - th, f32(t.req_w) + 2 * bw, f32(t.req_h) + th + bw}
}

// anim_current is where a window is drawn right now: mid-animation, the
// interpolated rect; otherwise its frame.
anim_current :: proc(t: ^Toplevel) -> (p.Rect, f32) {
	a, ok := anim_state.wins[t]
	if !ok {
		return frame_rect(t), 1
	}
	return anim_eval(t, a)
}

anim_eval :: proc(t: ^Toplevel, a: Win_Anim) -> (p.Rect, f32) {
	k := f32(clamp((wall_now() - a.t0) / max(a.dur, 0.001), 0, 1))
	reduced := anim_mode(&server) == .Reduced
	switch a.kind {
	case .None:
	case .Open:
		e := ease_out(k)
		if reduced {
			return target_frame(t), e
		}
		return scale_rect(target_frame(t), 0.95 + 0.05 * e), e
	case .Geometry:
		e := ease_out(k)
		return lerp_rect(a.from, target_frame(t), e), 1
	case .Minimize:
		e := ease_in_out(k)
		if reduced {
			return a.from, 1 - ease_out(k)
		}
		to, ok := bar_entry_rect(t)
		if !ok {
			to = scale_rect(a.from, 0.5)
		}
		// The window stays solid while it visibly shrinks toward its
		// taskbar entry, and only fades as it arrives. On a plain ease-out
		// it had covered most of the way, at a third of its opacity, within
		// 50 ms, and the motion was never seen.
		return lerp_rect(a.from, to, e), 1 - ease_in(k)
	case .Restore:
		e := ease_out(k)
		if reduced {
			return target_frame(t), e
		}
		return lerp_rect(a.from, target_frame(t), e), e
	}
	return frame_rect(t), 1
}

anim_start :: proc(s: ^Server, t: ^Toplevel, kind: Anim_Kind, from: p.Rect, dur: f64) {
	if !anim_allowed(s, t) {
		delete_key(&anim_state.wins, t)
		return
	}
	d := dur
	if anim_mode(s) == .Reduced {
		if kind == .Geometry {
			delete_key(&anim_state.wins, t)
			return
		}
		d = ANIM_REDUCED
	}
	anim_state.wins[t] = Win_Anim{kind = kind, t0 = wall_now(), dur = d, from = from}
	anim_keep_going()
}

anim_open :: proc(s: ^Server, t: ^Toplevel) {
	anim_start(s, t, .Open, frame_rect(t), ANIM_OPEN)
}

// anim_geom_begin is called just before the window manager changes a
// window's geometry: the motion starts from wherever it is drawn now.
anim_geom_begin :: proc(s: ^Server, t: ^Toplevel) {
	if !t.mapped || t.minimized || !ws_on_current(s, t) || s.drag_t == t && s.drag != .None {
		return
	}
	if a, ok := anim_state.wins[t]; ok && a.kind == .Open {
		return // still opening: let it finish where it lands
	}
	from, _ := anim_current(t)
	if from.w <= 1 || from.h <= 1 {
		return
	}
	anim_start(s, t, .Geometry, from, ANIM_GEOM)
}

anim_minimize :: proc(s: ^Server, t: ^Toplevel) {
	if !ws_on_current(s, t) {
		return
	}
	from, _ := anim_current(t)
	anim_start(s, t, .Minimize, from, ANIM_MIN)
}

anim_restore :: proc(s: ^Server, t: ^Toplevel) {
	if !ws_on_current(s, t) {
		return
	}
	from, ok := bar_entry_rect(t)
	if !ok {
		from = scale_rect(frame_rect(t), 0.5)
	}
	anim_start(s, t, .Restore, from, ANIM_MIN)
}

// anim_close takes a snapshot of a window that is about to disappear, and
// lets the snapshot fade and shrink where the window was.
anim_close :: proc(s: ^Server, t: ^Toplevel) {
	if !anim_allowed(s, t) || anim_app == nil || session.kiosk {
		return
	}
	px, w, h, ok := anim_render(s, anim_app, t)
	if !ok {
		return
	}
	snap := make([]u32, w * h)
	copy(snap, px)
	dur := anim_mode(s) == .Reduced ? ANIM_REDUCED : ANIM_CLOSE
	cur, _ := anim_current(t)
	append(&anim_state.ghosts, Ghost{px = snap, w = w, h = h, rect = cur, t0 = wall_now(), dur = dur, ws = s.cur_ws})
	delete_key(&anim_state.wins, t)
	anim_keep_going()
}

anim_ws_switch :: proc(s: ^Server, from, to: int) {
	if anim_mode(s) != .On || s.listen == 0 || from == to {
		anim_state.ws_active = false
		return
	}
	if s.workspaces[from].output != s.workspaces[to].output {
		return
	}
	anim_state.ws_from = from
	anim_state.ws_to = to
	anim_state.ws_t0 = wall_now()
	anim_state.ws_active = true
	anim_keep_going()
}

anim_ws_busy :: proc() -> bool {
	return anim_state.ws_active
}

// anim_ws_draw draws an output mid-switch: the old workspace sliding out,
// the new one sliding in. Returns false when no switch is in progress there.
anim_ws_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, oi, idx: int) -> bool {
	a := &anim_state
	if !a.ws_active || idx != a.ws_to {
		return false
	}
	k := f32(clamp((wall_now() - a.ws_t0) / ANIM_WS, 0, 1))
	if k >= 1 {
		a.ws_active = false
		return false
	}
	anim_keep_going()
	e := ease_out(k)
	w := f32(s.outputs[oi].w)
	dir := f32(a.ws_to > a.ws_from ? 1 : -1)
	draw_workspace(s, app, cv, a.ws_from, int(-dir * w * e))
	draw_workspace(s, app, cv, a.ws_to, int(dir * w * (1 - e)))
	return true
}

// anim_render draws a window, without its shadow, into the scratch buffer
// at its real size. The pixels are only valid until the next call.
anim_render :: proc(s: ^Server, app: ^p.App, t: ^Toplevel) -> ([]u32, int, int, bool) {
	fr := frame_rect(t)
	w := int(fr.w)
	h := int(fr.h)
	if w <= 0 || h <= 0 || w > 8192 || h > 8192 {
		return nil, 0, 0, false
	}
	resize(&anim_state.scratch, w * h)
	buf := anim_state.scratch[:]
	slice.zero(buf)
	scv := p.canvas_from(buf, w, h)
	defer p.canvas_destroy(&scv)
	ox, oy := int(fr.x), int(fr.y)
	t.x -= ox
	t.y -= oy
	draw_window(s, app, &scv, t, false)
	t.x += ox
	t.y += oy
	return buf, w, h, true
}

// draw_window_alpha draws a window at an opacity, through the scratch.
draw_window_alpha :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel, alpha: f32) {
	px, w, h, ok := anim_render(s, app, t)
	if !ok {
		return
	}
	blit_scaled(cv, px, w, h, frame_rect(t), alpha)
}

// anim_draw_window draws a window that is mid-animation. Returns false when
// it is not animating, and the caller draws it normally.
anim_draw_window :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel) -> bool {
	a, ok := anim_state.wins[t]
	if !ok {
		return false
	}
	if wall_now() - a.t0 >= a.dur {
		delete_key(&anim_state.wins, t)
		return t.minimized // a finished minimize draws nothing more
	}
	anim_keep_going()
	r, alpha := anim_eval(t, a)
	if m, mok := ws_peek(t); mok && m.opacity > 0 {
		alpha *= m.opacity
	}
	px, w, h, rok := anim_render(s, app, t)
	if !rok {
		return true
	}
	blit_scaled(cv, px, w, h, r, alpha)
	return true
}

// anim_draw_ghosts draws the closing snapshots on the workspace they left.
anim_draw_ghosts :: proc(s: ^Server, cv: ^p.Canvas, idx: int) {
	now := wall_now()
	for i := len(anim_state.ghosts) - 1; i >= 0; i -= 1 {
		g := &anim_state.ghosts[i]
		k := f32(clamp((now - g.t0) / g.dur, 0, 1))
		if k >= 1 {
			delete(g.px)
			ordered_remove(&anim_state.ghosts, i)
			continue
		}
		if g.ws != idx {
			continue
		}
		anim_keep_going()
		e := ease_in(k)
		r := g.rect
		if anim_mode(s) == .On {
			r = scale_rect(g.rect, 1 - 0.05 * e)
		}
		blit_scaled(cv, g.px, g.w, g.h, r, 1 - e)
	}
}

// anim_frame_done closes a frame's books: whether to keep animating, and
// the draw-time samples that decide automatic reduction.
anim_frame_done :: proc(s: ^Server, ms: f64) {
	a := &anim_state
	a.draw_ms = a.draw_ms * 0.8 + ms * 0.2
	if a.animated && s.cfg.animations == .On && !a.auto_reduced {
		append(&a.samples, ms)
		if len(a.samples) >= 30 {
			sorted := slice.clone(a.samples[:], context.temp_allocator)
			slice.sort(sorted)
			med := sorted[len(sorted) / 2]
			if med > ANIM_BUDGET_MS {
				a.auto_reduced = true
				log_line("animations: median frame %.1f ms over budget; reduced for this session", med)
				note(s, "animations reduced: frames over budget")
			}
			clear(&a.samples)
		}
	}
	// An animation that ran out on a window nobody drew this frame (it is on
	// a workspace out of sight) is dropped here, or it would keep the loop
	// awake forever.
	now := wall_now()
	stale := make([dynamic]^Toplevel, 0, 4, context.temp_allocator)
	for t, w in a.wins {
		if now - w.t0 >= w.dur {
			append(&stale, t)
		}
	}
	for t in stale {
		delete_key(&a.wins, t)
	}
	a.keep_going = a.animated
	a.animated = false
}

// blit_scaled composites a buffer (scratch pixels: 0 where nothing was
// drawn, opaque elsewhere) into dst at an opacity, nearest-neighbour.
blit_scaled :: proc(cv: ^p.Canvas, src: []u32, sw, sh: int, dst: p.Rect, alpha: f32) {
	if sw <= 0 || sh <= 0 || dst.w < 1 || dst.h < 1 || alpha <= 0.004 {
		return
	}
	clip := p.rect_intersect(dst, cv.clip)
	x0 := max(int(clip.x), 0)
	y0 := max(int(clip.y), 0)
	x1 := min(int(clip.x + clip.w + 0.999), cv.w)
	y1 := min(int(clip.y + clip.h + 0.999), cv.h)
	if x1 <= x0 || y1 <= y0 {
		return
	}
	ga := u32(clamp(alpha, 0, 1) * 256)
	fx := f32(sw) / dst.w
	fy := f32(sh) / dst.h
	// The source column for each destination column, once per blit.
	cols := make([]int, x1 - x0, context.temp_allocator)
	for x in x0 ..< x1 {
		cols[x - x0] = clamp(int((f32(x) + 0.5 - dst.x) * fx), 0, sw - 1)
	}
	for y in y0 ..< y1 {
		sy := clamp(int((f32(y) + 0.5 - dst.y) * fy), 0, sh - 1)
		srow := src[sy * sw:][:sw]
		drow := cv.px[y * cv.w:][:cv.w]
		for x in x0 ..< x1 {
			v := srow[cols[x - x0]]
			sa := v >> 24
			if sa == 0 {
				continue
			}
			a := (sa * ga) >> 8
			if a >= 255 {
				drow[x] = 0xff00_0000 | (v & 0xffffff)
				continue
			}
			d := drow[x]
			na := 255 - a
			r := (((v >> 16) & 0xff) * a + ((d >> 16) & 0xff) * na) / 255
			g := (((v >> 8) & 0xff) * a + ((d >> 8) & 0xff) * na) / 255
			b := ((v & 0xff) * a + (d & 0xff) * na) / 255
			drow[x] = 0xff00_0000 | (r << 16) | (g << 8) | b
		}
	}
}
