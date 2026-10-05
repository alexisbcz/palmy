// Outputs, and the protocols that describe them.
//
// `wl_output` used to be one fabricated global whose geometry was invented in
// `send_output`. A daily driver has heads: a list, each with a logical
// position, a logical size, a scale, a name and a description. That list lives
// here. `drm.odin` owns the real data model coming out of KMS and feeds this
// file through `out_set_heads` / `out_add` / `out_remove`; with no DRM backend
// at all `out_ensure_fallback` synthesises a single head the size of the
// nested surface, so everything above this layer is testable on its own.
//
// Also here, because they are all about how a surface maps onto a head:
// `zxdg_output_manager_v1`, `wp_viewporter` and `wp_fractional_scale_v1`.
package wm

import "core:fmt"
import "core:strings"

// Output globals get their own name range so the static GLOBALS table and the
// hot-pluggable heads can never collide.
OUT_GLOBAL_BASE :: u32(1000)
OUT_WL_VERSION :: u32(4)

// Out_Head is the seam with `drm.odin`: everything the compositor needs to
// know about one physical head, in compositor-logical pixels.
Out_Head :: struct {
	name:      string, // connector name, "eDP-1"
	desc:      string, // human readable, "Dell Inc. U2720Q"
	vendor:    string, // wl_output.geometry make
	model:     string,
	x, y:      int, // logical position in the global compositor space
	w, h:      int, // logical size, i.e. mode size divided by scale
	mode_w:    int, // physical mode, in device pixels
	mode_h:    int,
	pw, ph:    int, // physical size in millimetres
	refresh:   int, // mHz
	scale:     int, // integer buffer scale, >= 1
	transform: int, // wl_output.transform
}

Out_Output :: struct {
	using head: Out_Head,
	global:     u32,
	fallback:   bool, // synthesised because no backend supplied a head

	// Space on this head claimed by layer-shell exclusive zones: left, top,
	// right, bottom. layer.odin owns it; layer_work_area reads it.
	ins:        [4]int,
}

out_list: [dynamic]^Out_Output
out_next_global := OUT_GLOBAL_BASE

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

out_by_global :: proc(g: u32) -> ^Out_Output {
	for o in out_list {
		if o.global == g {
			return o
		}
	}
	return nil
}

out_primary :: proc() -> ^Out_Output {
	return len(out_list) > 0 ? out_list[0] : nil
}

out_at :: proc(x, y: int) -> ^Out_Output {
	for o in out_list {
		if x >= o.x && y >= o.y && x < o.x + o.w && y < o.y + o.h {
			return o
		}
	}
	return out_primary()
}

// out_bounds is the union of every head, which is the size of the compositor's
// coordinate space.
out_bounds :: proc() -> (x, y, w, h: int) {
	if len(out_list) == 0 {
		return 0, 0, 0, 0
	}
	x0, y0 := out_list[0].x, out_list[0].y
	x1, y1 := x0 + out_list[0].w, y0 + out_list[0].h
	for o in out_list[1:] {
		x0 = min(x0, o.x)
		y0 = min(y0, o.y)
		x1 = max(x1, o.x + o.w)
		y1 = max(y1, o.y + o.h)
	}
	return x0, y0, x1 - x0, y1 - y0
}

out_max_scale :: proc() -> int {
	sc := 1
	for o in out_list {
		sc = max(sc, o.scale)
	}
	return sc
}

// out_add registers a head and tells every connected client about it.
out_add :: proc(s: ^Server, h: Out_Head) -> ^Out_Output {
	o := new(Out_Output)
	o.head = h
	o.name = strings.clone(h.name)
	o.desc = strings.clone(h.desc)
	o.vendor = strings.clone(h.vendor)
	o.model = strings.clone(h.model)
	if o.scale < 1 {
		o.scale = 1
	}
	if o.mode_w == 0 {
		o.mode_w = o.w * o.scale
	}
	if o.mode_h == 0 {
		o.mode_h = o.h * o.scale
	}
	o.global = out_next_global
	out_next_global += 1
	append(&out_list, o)

	for c in s.clients {
		if c.dead {
			continue
		}
		for id, ob in c.objs {
			if ob.kind == .Registry {
				event(c, id, 0, o.global, "wl_output", OUT_WL_VERSION)
			}
		}
	}
	log_line("output %s added: %dx%d at %d,%d scale %d", o.name, o.w, o.h, o.x, o.y, o.scale)
	s.dirty = true
	return o
}

// out_remove retires a head. Client bindings resolve through the global name
// rather than a pointer, so any that outlive this simply stop resolving.
out_remove :: proc(s: ^Server, o: ^Out_Output) {
	idx := -1
	for x, i in out_list {
		if x == o {
			idx = i
			break
		}
	}
	if idx < 0 {
		return
	}
	ordered_remove(&out_list, idx)
	// Anything that asked to live on this head is told the head is gone. The
	// protocol's answer for a layer surface is `closed`; for a lock surface
	// the compositor simply stops drawing it, and `lock_maybe_locked` will
	// re-evaluate coverage against the shorter output list.
	for ls in layer_all {
		if ls.out_global == o.global {
			layer_close(s, ls)
		}
	}
	for c in s.clients {
		if c.dead {
			continue
		}
		for id, ob in c.objs {
			if ob.kind == .Registry {
				event(c, id, 1, o.global) // wl_registry.global_remove
			}
		}
	}
	log_line("output %s removed", o.name)
	delete(o.name)
	delete(o.desc)
	delete(o.vendor)
	delete(o.model)
	free(o)
	s.dirty = true
}

// out_changed re-sends every property of a head that already exists, which is
// what a mode switch or a move in the logical layout needs.
out_changed :: proc(s: ^Server, o: ^Out_Output) {
	for c in s.clients {
		if c.dead {
			continue
		}
		for id, ob in c.objs {
			#partial switch ob.kind {
			case .Output:
				if u32(uintptr(ob.p)) == o.global {
					out_send_wl(c, id, ob.ver, o, done = true)
				}
			case .Xdg_Output:
				if u32(uintptr(ob.p)) == o.global {
					out_send_xdg(c, id, ob.ver, o)
				}
			}
		}
	}
	s.dirty = true
}

// out_set_heads replaces the whole list in one go. This is the call `drm.odin`
// makes after enumerating or re-enumerating connectors.
out_set_heads :: proc(s: ^Server, heads: []Out_Head) {
	for i := len(out_list) - 1; i >= 0; i -= 1 {
		out_remove(s, out_list[i])
	}
	for h in heads {
		out_add(s, h)
	}
}

// out_sync is called once a frame from `layer_arrange`. It reconciles the
// protocol-facing list with whatever the compositor itself believes about its
// heads: `Server.outputs`, which workspace.odin fills from the nested host
// canvas and drm.odin fills from KMS. With nothing there at all it falls back
// to one synthetic head the size of the surface we are drawing into, so this
// file is complete and testable with no backend.
out_sync :: proc(s: ^Server) {
	if len(s.outputs) == 0 {
		out_ensure_fallback(s)
		return
	}

	// A real head exists, so the synthetic one must go.
	for i := len(out_list) - 1; i >= 0; i -= 1 {
		if out_list[i].fallback {
			out_remove(s, out_list[i])
		}
	}

	for w in s.outputs {
		if !w.enabled {
			continue
		}
		sc := max(int(w.scale + 0.5), 1)
		found: ^Out_Output
		for o in out_list {
			if o.name == w.name {
				found = o
				break
			}
		}
		if found == nil {
			out_add(
				s,
				Out_Head {
					name = w.name,
					desc = w.host ? "palmy nested output" : w.name,
					vendor = "palmy",
					model = w.host ? "nested" : "head",
					x = w.x,
					y = w.y,
					w = w.w,
					h = w.h,
					mode_w = w.w * sc,
					mode_h = w.h * sc,
					pw = 340,
					ph = 190,
					refresh = 60000,
					scale = sc,
				},
			)
			continue
		}
		if found.x == w.x && found.y == w.y && found.w == w.w && found.h == w.h && found.scale == sc {
			continue
		}
		found.x, found.y, found.w, found.h = w.x, w.y, w.w, w.h
		found.scale = sc
		found.mode_w, found.mode_h = w.w * sc, w.h * sc
		out_changed(s, found)
	}

	for i := len(out_list) - 1; i >= 0; i -= 1 {
		still := false
		for w in s.outputs {
			if w.enabled && w.name == out_list[i].name {
				still = true
				break
			}
		}
		if !still {
			out_remove(s, out_list[i])
		}
	}
}

// out_ensure_fallback keeps a single synthetic head in step with the nested
// surface, so the compositor is complete without any backend at all. A real
// head added by `drm.odin` replaces it.
out_ensure_fallback :: proc(s: ^Server) {
	if s.out_w <= 0 || s.out_h <= 0 {
		return
	}
	if len(out_list) > 0 {
		o := out_list[0]
		if o.fallback && (o.w != s.out_w || o.h != s.out_h) {
			o.w, o.h = s.out_w, s.out_h
			o.mode_w, o.mode_h = s.out_w, s.out_h
			out_changed(s, o)
		}
		return
	}
	o := out_add(
		s,
		Out_Head {
			name = "WL-1",
			desc = "palmy nested output",
			vendor = "palmy",
			model = "nested",
			w = s.out_w,
			h = s.out_h,
			pw = 340,
			ph = 190,
			refresh = 60000,
			scale = 1,
		},
	)
	o.fallback = true
}

// ---------------------------------------------------------------------------
// wl_output
// ---------------------------------------------------------------------------

out_send_globals :: proc(c: ^Client, reg: u32) {
	for o in out_list {
		event(c, reg, 0, o.global, "wl_output", OUT_WL_VERSION)
	}
}

out_bind :: proc(s: ^Server, c: ^Client, reg: u32, name: u32, iface: string, ver: u32, new: u32) -> bool {
	o := out_by_global(name)
	if o == nil {
		return false
	}
	if iface != "wl_output" {
		post_error(c, reg, 2, fmt.tprintf("global %d is wl_output, not %s", name, iface))
		return true
	}
	v := clamp(ver, 1, OUT_WL_VERSION)
	if obj_new(c, new, .Output, v, rawptr(uintptr(o.global))) {
		out_send_wl(c, new, v, o, done = true)
	}
	return true
}

out_send_wl :: proc(c: ^Client, id: u32, ver: u32, o: ^Out_Output, done: bool) {
	// geometry(x, y, phys_w, phys_h, subpixel, make, model, transform)
	event(
		c,
		id,
		0,
		i32(o.x),
		i32(o.y),
		i32(o.pw),
		i32(o.ph),
		i32(0),
		o.vendor,
		o.model,
		i32(o.transform),
	)
	// mode(flags = current | preferred, w, h, refresh)
	event(c, id, 1, u32(3), i32(o.mode_w), i32(o.mode_h), i32(o.refresh))
	if ver >= 2 {
		event(c, id, 3, i32(o.scale)) // scale
	}
	if ver >= 4 {
		event(c, id, 4, o.name) // name
		event(c, id, 5, o.desc) // description
	}
	if done && ver >= 2 {
		event(c, id, 2) // done
	}
}

// out_binding_id finds the wl_output object this client holds for a head, so
// wl_surface.enter can name the output the surface is actually on.
out_binding_id :: proc(c: ^Client, o: ^Out_Output) -> u32 {
	if o == nil {
		return 0
	}
	for id, ob in c.objs {
		if ob.kind == .Output && u32(uintptr(ob.p)) == o.global {
			return id
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// zxdg_output_manager_v1 / zxdg_output_v1
// ---------------------------------------------------------------------------

OUT_XDG_VERSION :: u32(3)

req_out_xdg_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_xdg_output(id, output)
		xid := r_u32(r)
		oid := r_u32(r)
		ob, ok := obj_get(c, oid)
		if !ok || ob.kind != .Output {
			post_error(c, id, 0, "zxdg_output_manager_v1.get_xdg_output on a non-output")
			return
		}
		head := out_by_global(u32(uintptr(ob.p)))
		if !obj_new(c, xid, .Xdg_Output, o.ver, ob.p) {
			return
		}
		if head == nil {
			return
		}
		out_send_xdg(c, xid, o.ver, head)
		// From version 3 the atomic update is terminated by wl_output.done.
		if o.ver >= 3 {
			if ob.ver >= 2 {
				event(c, oid, 2)
			}
		}
	}
}

out_send_xdg :: proc(c: ^Client, id: u32, ver: u32, o: ^Out_Output) {
	event(c, id, 0, i32(o.x), i32(o.y)) // logical_position
	event(c, id, 1, i32(o.w), i32(o.h)) // logical_size
	if ver >= 2 {
		event(c, id, 3, o.name) // name
		event(c, id, 4, o.desc) // description
	}
	if ver < 3 {
		event(c, id, 2) // done, deprecated from version 3
	}
}

// ---------------------------------------------------------------------------
// wp_viewporter / wp_viewport
//
// A viewport crops and scales a buffer. The compositor keeps its own copy of
// every client's pixels (see copy_buffer), so the crop and the resample happen
// once, at copy time, and nothing downstream of `Surface.img` has to know that
// a viewport exists at all.
// ---------------------------------------------------------------------------

req_out_viewporter :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_viewport(id, surface)
		vid := r_u32(r)
		sid := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "wp_viewporter.get_viewport on a non-surface")
			return
		}
		surf := (^Surface)(so.p)
		if surf.vp_obj != 0 {
			post_error(c, id, 0, "wp_viewporter.get_viewport: the surface already has a viewport")
			return
		}
		if !obj_new(c, vid, .Viewport, 1, surf) {
			return
		}
		surf.vp_obj = vid
	}
}

req_out_viewport :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	surf := (^Surface)(o.p)
	switch op {
	case 0:
		if surf != nil {
			surf.vp_obj = 0
			surf.vp_src_set = false
			surf.vp_dst_set = false
			surf.dmg_full = true
			s.dirty = true
		}
		obj_drop(c, id)
	case 1:
		// set_source(x, y, width, height), all wl_fixed
		x := r_fixed(r)
		y := r_fixed(r)
		w := r_fixed(r)
		h := r_fixed(r)
		if surf == nil {
			return
		}
		if w < 0 && h < 0 {
			surf.vp_src_set = false
		} else if w <= 0 || h <= 0 || x < 0 || y < 0 {
			post_error(c, id, 0, "wp_viewport.set_source with an invalid rectangle")
			return
		} else {
			surf.vp_src = {x, y, w, h}
			surf.vp_src_set = true
		}
		surf.dmg_full = true
		s.dirty = true
	case 2:
		// set_destination(width, height)
		w := int(r_i32(r))
		h := int(r_i32(r))
		if surf == nil {
			return
		}
		if w == -1 && h == -1 {
			surf.vp_dst_set = false
		} else if w <= 0 || h <= 0 {
			post_error(c, id, 0, "wp_viewport.set_destination with an invalid size")
			return
		} else {
			surf.vp_dst = {w, h}
			surf.vp_dst_set = true
		}
		surf.dmg_full = true
		s.dirty = true
	}
}

// ---------------------------------------------------------------------------
// wp_fractional_scale_v1
//
// We rasterise at integer scale, so the honest answer is the integer scale of
// the output the surface is on, expressed in the protocol's 120ths.
// ---------------------------------------------------------------------------

req_out_frac_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_fractional_scale(id, surface)
		fid := r_u32(r)
		sid := r_u32(r)
		so, ok := obj_get(c, sid)
		if !ok || so.kind != .Surface {
			post_error(c, id, 0, "wp_fractional_scale_manager_v1 on a non-surface")
			return
		}
		surf := (^Surface)(so.p)
		if surf.frac_obj != 0 {
			post_error(c, id, 0, "the surface already has a fractional scale object")
			return
		}
		if !obj_new(c, fid, .Frac_Scale, 1, surf) {
			return
		}
		surf.frac_obj = fid
		out_send_frac(c, fid, out_primary())
	}
}

out_send_frac :: proc(c: ^Client, id: u32, o: ^Out_Output) {
	sc := o != nil ? o.scale : 1
	event(c, id, 0, u32(120 * max(sc, 1))) // preferred_scale
}
