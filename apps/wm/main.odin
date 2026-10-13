// A floating, stacking window manager that is its own Wayland compositor.
//
// It runs as an ordinary palmy window on the host, and is itself a Wayland
// server: clients connect to $XDG_RUNTIME_DIR/wayland-palmy, their shm buffers
// are mapped and read straight out of the pool, and we draw the frames, the
// title bars and the stacking order ourselves. The host supplies the output
// surface and the input events; everything above that is here.
package wm

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import kit "kit:."
import p "palmy:."

// Geometry of the --overlay surface on the host, so the recorder knows where
// to point grim without asking the host for a window that does not exist.
OVERLAY_X :: 160
OVERLAY_Y :: 70
OVERLAY_W :: 1600
OVERLAY_H :: 940

TITLE_H :: 32
BORDER :: 1
GRAB :: 7
BAR_H :: 34
MIN_W :: 120
MIN_H :: 60

Edge :: enum u8 {
	Left,
	Right,
	Top,
	Bottom,
}
Edges :: bit_set[Edge;u8]

Drag :: enum u8 {
	None,
	Move,
	Resize,
}

Server :: struct {
	listen:       linux.Fd,
	path:         string,
	display_name: string,
	clients:      [dynamic]^Client,
	next_index:   int,
	serial:       u32,

	surfaces:     [dynamic]^Surface,

	// The live stacking order, bottom to top. It belongs to the workspace the
	// user is looking at: `ws_switch` hands it back and takes the next one's,
	// so every caller that walks `s.stack` keeps meaning what it meant when
	// there was only one. See workspace.odin.
	stack:        [dynamic]^Toplevel,
	workspaces:   [dynamic]Ws_Workspace,
	outputs:      [dynamic]Ws_Output,
	cur_ws:       int,
	cur_out:      int,
	needs_layout: bool,
	cfg:          Cfg,
	cfg_check_at: f64,

	focus:        ^Toplevel,
	ptr_surf:     ^Surface,
	kbd_surf:     ^Surface,
	selection:    ^Data_Source,
	dirty:        bool,

	out_w, out_h: int,
	repeat_rate:  int,
	repeat_delay: int,
	mod_mask:     u32,
	mod_group:    u32, // the XKB group last sent in wl_keyboard.modifiers
	kt:           Key_Table,
	keymap_fd:    linux.Fd,
	keymap_size:  int,

	// Interaction.
	drag:         Drag,
	drag_t:       ^Toplevel,
	drag_edges:   Edges,
	drag_from:    [2]int,
	drag_orig:    [4]int,
	hover_t:      ^Toplevel,
	hover_btn:    int, // 0 none, 1 close, 2 maximise, 3 minimise
	place_n:      int,
	wm_mode:      bool,

	// The desktop is static, so it is rasterized once and memcpy'd per frame.
	bg:           []u32,
	bg_w, bg_h:   int,

	status:       string,
	status_at:    f64,
	cascade_at:   [2]int,
}

server: Server

// ---------------------------------------------------------------------------
// Socket
// ---------------------------------------------------------------------------

server_start :: proc(s: ^Server, name: string) -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		return "XDG_RUNTIME_DIR is not set"
	}
	s.display_name = strings.clone(name)
	s.path = fmt.aprintf("%s/%s", rt, name)
	cpath := strings.clone_to_cstring(s.path, context.temp_allocator)

	// If something is already listening there, refuse rather than steal it.
	if probe, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0)); e == .NONE {
		addr := linux.Sock_Addr_Un{sun_family = .UNIX}
		copy(addr.sun_path[:], s.path)
		if linux.connect(probe, &addr) == .NONE {
			linux.close(probe)
			return fmt.tprintf("%s is already in use by another compositor", s.path)
		}
		linux.close(probe)
	}
	linux.unlink(cpath)

	fd, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, linux.Protocol(0))
	if serr != .NONE {
		return fmt.tprintf("socket() failed: %v", serr)
	}
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if len(s.path) >= len(addr.sun_path) {
		return "the socket path is too long"
	}
	copy(addr.sun_path[:], s.path)
	if berr := linux.bind(fd, &addr); berr != .NONE {
		linux.close(fd)
		return fmt.tprintf("bind(%s) failed: %v", s.path, berr)
	}
	if lerr := linux.listen(fd, 16); lerr != .NONE {
		linux.close(fd)
		return fmt.tprintf("listen() failed: %v", lerr)
	}
	s.listen = fd
	return ""
}

server_stop :: proc(s: ^Server) {
	if s.listen != 0 {
		linux.close(s.listen)
		s.listen = 0
	}
	if s.path != "" {
		linux.unlink(strings.clone_to_cstring(s.path, context.temp_allocator))
	}
}

accept_clients :: proc(s: ^Server) {
	for {
		addr: linux.Sock_Addr_Un
		fd, err := linux.accept(s.listen, &addr, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			return
		}
		c := new(Client)
		c.fd = fd
		s.next_index += 1
		c.index = s.next_index
		c.objs = make(map[u32]Object)
		c.objs[DISPLAY_ID] = Object{kind = .Display, ver = 1}
		append(&s.clients, c)
		log_line("client %d connected", c.index)
	}
}

client_free :: proc(s: ^Server, c: ^Client) {
	c.dead = true

	for _, o in c.objs {
		if o.kind == .Toplevel {
			t := (^Toplevel)(o.p)
			unmap_window(s, t)
			delete(t.title)
			delete(t.app_id)
			free(t)
		}
	}
	for _, o in c.objs {
		if o.kind == .Xdg_Surface {
			free((^Xdg_Surface)(o.p))
		}
	}
	for _, o in c.objs {
		if o.kind == .Surface {
			surf := (^Surface)(o.p)
			for i := len(s.surfaces) - 1; i >= 0; i -= 1 {
				if s.surfaces[i] == surf {
					ordered_remove(&s.surfaces, i)
				}
			}
			if s.ptr_surf == surf {s.ptr_surf = nil}
			if s.kbd_surf == surf {s.kbd_surf = nil}
			delete(surf.img)
			delete(surf.p_frames)
			delete(surf.frames)
			delete(surf.children)
			free(surf)
		}
	}
	for _, o in c.objs {
		if o.kind == .Data_Source {
			src := (^Data_Source)(o.p)
			if s.selection == src {
				s.selection = nil
			}
			for m in src.mimes {
				delete(m)
			}
			delete(src.mimes)
			free(src)
		}
		if o.kind == .Data_Device {
			free((^Data_Device)(o.p))
		}
		if o.kind == .Data_Offer {
			free((^Data_Offer)(o.p))
		}
	}
	for _, o in c.objs {
		if o.kind == .Buffer {
			b := (^Buffer)(o.p)
			pool_unref(b.pool)
			free(b)
		}
	}
	for _, o in c.objs {
		if o.kind == .Pool {
			pool := (^Pool)(o.p)
			if !pool.zombie {
				pool_unref(pool)
			}
		}
	}

	delete(c.objs)
	delete(c.out)
	delete(c.out_fds)
	delete(c.rx)
	for fd in c.rx_fds {
		linux.close(fd)
	}
	delete(c.rx_fds)
	delete(c.pointers)
	delete(c.keyboards)
	delete(c.wm_bases)
	delete(c.data_devices)
	linux.close(c.fd)
	log_line("client %d gone", c.index)
	free(c)
}

// server_poll accepts new connections and drains every client's socket. It
// never blocks: the compositor's own frame callback paces the loop.
server_poll :: proc(s: ^Server) {
	accept_clients(s)

	for c in s.clients {
		if c.dead {
			continue
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, perr := linux.poll(pfd[:], 0)
		if perr != .NONE || n <= 0 {
			continue
		}
		if !client_read(c) {
			log_line("client %d hung up", c.index)
			c.dead = true
			continue
		}
		client_dispatch(s, c)
	}

	for i := len(s.clients) - 1; i >= 0; i -= 1 {
		if s.clients[i].dead {
			c := s.clients[i]
			ordered_remove(&s.clients, i)
			client_free(s, c)
			s.dirty = true
		}
	}
}

flush_all :: proc(s: ^Server) {
	for c in s.clients {
		client_flush(c)
	}
}

// send_frames fires the wl_surface.frame callbacks collected since the last
// composite. Without this clients draw exactly one frame and then wait forever.
send_frames :: proc(s: ^Server) {
	// The surface has been painted, so its accumulated damage is spent. A
	// compositing loop that repaints only what changed reads
	// `surface_damage_rects` / `surface_damage_bbox` just before this.
	for surf in s.surfaces {
		if VERBOSE {
			if r, any := surface_damage_bbox(surf); any {
				log_line(
					"damage surface %d: %d,%d %dx%d rects=%d full=%v",
					surf.id, r[0], r[1], r[2], r[3],
					len(surface_damage_rects(surf)), surface_damage_full(surf),
				)
			}
		}
		surface_damage_reset(surf)
	}
	t := now_ms()
	for surf in s.surfaces {
		if len(surf.frames) == 0 {
			continue
		}
		for cb in surf.frames {
			event(surf.client, cb, 0, t)
			obj_drop(surf.client, cb)
		}
		clear(&surf.frames)
	}
}

make_keymap_fd :: proc(s: ^Server, text: string) -> bool {
	if text == "" {
		return false
	}
	fd, err := linux.memfd_create("palmy-wm-keymap", {.CLOEXEC})
	if err != .NONE {
		return false
	}
	size := len(text) + 1
	if linux.ftruncate(fd, i64(size)) != .NONE {
		linux.close(fd)
		return false
	}
	mem, merr := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		linux.close(fd)
		return false
	}
	dst := ([^]u8)(mem)[:size]
	copy(dst, text)
	dst[size - 1] = 0
	linux.munmap(mem, uint(size))
	s.keymap_fd = fd
	s.keymap_size = size
	return true
}

send_keymap :: proc(s: ^Server, c: ^Client, kid: u32) {
	if s.keymap_fd == 0 {
		return
	}
	dup, err := linux.dup(s.keymap_fd)
	if err != .NONE {
		return
	}
	// wl_keyboard.keymap(format = xkb_v1, fd, size)
	event(c, kid, 0, u32(1), Fd(dup), u32(s.keymap_size))
	client_flush(c)
}

// ---------------------------------------------------------------------------
// Window management
// ---------------------------------------------------------------------------

// sane_size keeps a client that commits a zero-sized or an absurd buffer from
// becoming a window nobody can reach. A surface can legitimately be bigger
// than the screen, but not sixteen times bigger, and never zero.
sane_size :: proc(s: ^Server, t: ^Toplevel) {
	_, _, ow, oh := ws_output_rect(s, s.cur_out)
	t.w = clamp(t.w, 1, max(ow * 4, 4096))
	t.h = clamp(t.h, 1, max(oh * 4, 4096))
	if t.req_w <= 0 {t.req_w = t.w}
	if t.req_h <= 0 {t.req_h = t.h}
	t.req_w = clamp(t.req_w, 1, max(ow * 4, 4096))
	t.req_h = clamp(t.req_h, 1, max(oh * 4, 4096))
}

place_new_window :: proc(s: ^Server, t: ^Toplevel) {
	ws_ensure(s)
	sane_size(s, t)
	ws_apply_rules(s, t)

	ox, oy, ow, oh := ws_output_rect(s, s.cur_out)
	top := oy + ws_bar_h(s) + ws_title_h(t)
	avail_h := oh - ws_bar_h(s)

	switch {
	case t.w >= ow - 40 || t.h >= avail_h - ws_title_h(t) - 40:
		// Something nearly screen sized: centre it and let it be.
		t.x = max(ox, ox + (ow - t.w) / 2)
		t.y = max(top, oy + (oh - t.h) / 2)
	case s.cfg.placement == .Center:
		t.x = ox + max(0, (ow - t.w) / 2)
		t.y = max(top, oy + (oh - t.h) / 2)
	case s.cfg.placement == .Pointer:
		t.x = s_pointer.x - t.w / 2
		t.y = s_pointer.y - t.h / 2
	case:
		step := s.place_n % 6
		t.x = ox + 56 + step * 44
		t.y = top + 24 + step * 38
		s.place_n += 1
	}
	clamp_window(s, t)
	s.needs_layout = true
}

clamp_window :: proc(s: ^Server, t: ^Toplevel) {
	oi := ws_output_at(s, t.x + t.w / 2, t.y)
	ox, oy, ow, oh := ws_output_rect(s, oi)
	t.x = min(t.x, ox + ow - 60)
	t.x = max(t.x, ox + 60 - t.w)
	t.y = max(t.y, oy + ws_bar_h(s) + ws_title_h(t))
	t.y = min(t.y, oy + oh - 40)
}

// raise_window moves a window to the top of the *stacking* order. Under a
// tiling layout the tiled windows do not overlap, so raising one of them must
// not lift it over the floating windows — those always stay on top.
raise_window :: proc(s: ^Server, t: ^Toplevel) {
	for w, i in s.stack {
		if w != t {
			continue
		}
		ordered_remove(&s.stack, i)
		if wm_tiled_now(s, t) {
			pos := len(s.stack)
			for other, j in s.stack {
				if ws_floating(other) {
					pos = j
					break
				}
			}
			inject_at(&s.stack, pos, t)
		} else {
			append(&s.stack, t)
		}
		s.dirty = true
		return
	}
}

focus_window :: proc(s: ^Server, t: ^Toplevel) {
	if t != nil {
		t.minimized = false
		raise_window(s, t)
	}
	if s.focus == t {
		if t != nil {
			set_kbd_focus(s, t.xdg != nil ? t.xdg.surf : nil)
		}
		return
	}

	if old := s.focus; old != nil && old.client != nil && !old.client.dead {
		old.activated = false
		send_configure(s, old, old.req_w, old.req_h)
	}
	s.focus = t
	if t != nil {
		t.activated = true
		send_configure(s, t, t.req_w, t.req_h)
		set_kbd_focus(s, t.xdg != nil ? t.xdg.surf : nil)
	} else {
		set_kbd_focus(s, nil)
	}
	s.dirty = true
}

set_kbd_focus :: proc(s: ^Server, surf: ^Surface) {
	if s.kbd_surf == surf {
		return
	}
	if old := s.kbd_surf; old != nil && old.client != nil && !old.client.dead {
		for k in old.client.keyboards {
			event(old.client, k, 2, next_serial(s), old.id)
		}
	}
	s.kbd_surf = surf
	if surf != nil && surf.client != nil && !surf.client.dead {
		empty: []u8
		for k in surf.client.keyboards {
			event(surf.client, k, 1, next_serial(s), surf.id, empty)
			event(surf.client, k, 4, next_serial(s), s.mod_mask, u32(0), u32(0), s.kt.group)
		}
		s.mod_group = s.kt.group
		// The clipboard follows keyboard focus, as the protocol requires.
		offer_selection(s, surf.client)
	}
}

topmost_other :: proc(s: ^Server, skip: ^Toplevel) -> ^Toplevel {
	#reverse for t in s.stack {
		if t != skip && t.mapped && !t.minimized {
			return t
		}
	}
	return nil
}

// unmap_window takes a window out of whichever workspace holds it — not just
// the one on screen — and drops every reference the rest of the compositor
// may be holding to it. A client that dies mid-drag, mid-resize or while it
// owns the pointer goes through here, and all three used to leave a dangling
// pointer behind because the demo never did any of them.
unmap_window :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	ws_detach(s, t)
	t.mapped = false
	t.resizing = false
	if s.drag_t == t {
		// Not ws_cancel_drag: that would configure a window that is going away.
		s.drag = .None
		s.drag_t = nil
		s.drag_edges = {}
	}
	if s.hover_t == t {
		s.hover_t = nil
		s.hover_btn = 0
	}
	ws_drop_pointer(s, t)
	for &w in s.workspaces {
		if w.last_focus == t {
			w.last_focus = nil
		}
	}
	for &o in s.outputs {
		if o.focus == t {
			o.focus = nil
		}
	}
	if s.focus == t {
		s.focus = nil
		if t.xdg != nil && s.kbd_surf == t.xdg.surf {
			s.kbd_surf = nil
		}
		focus_window(s, topmost_other(s, t))
	}
	s.needs_layout = true
	s.dirty = true
}

set_maximized :: proc(s: ^Server, t: ^Toplevel, on: bool) {
	if on == t.maximized {
		return
	}
	if on {
		t.saved = {t.x, t.y, t.req_w, t.req_h}
		t.maximized = true
		oi := ws_output_at(s, t.x + t.w / 2, t.y)
		ox, oy, ow, oh := ws_output_rect(s, oi)
		bw := ws_border(t)
		th := ws_title_h(t)
		w := ow - 2 * bw
		h := oh - ws_bar_h(s) - th - bw
		t.req_w, t.req_h = w, h
		t.x, t.y = ox + bw, oy + ws_bar_h(s) + th
		t.anchor_x, t.anchor_y = false, false
		send_configure(s, t, w, h)
	} else {
		t.maximized = false
		t.x, t.y = t.saved[0], t.saved[1]
		t.req_w, t.req_h = max(t.saved[2], MIN_W), max(t.saved[3], MIN_H)
		send_configure(s, t, t.req_w, t.req_h)
	}
	s.needs_layout = true
	s.dirty = true
}

close_window :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	event(t.client, t.id, 1) // xdg_toplevel.close
	client_flush(t.client)
	note(s, fmt.tprintf("closing %s", title_of(t)))
}

cycle_focus :: proc(s: ^Server, backwards: bool) {
	live := make([dynamic]^Toplevel, 0, 8, context.temp_allocator)
	for t in s.stack {
		if t.mapped {
			append(&live, t)
		}
	}
	if len(live) < 1 {
		return
	}
	at := -1
	for t, i in live {
		if t == s.focus {
			at = i
		}
	}
	step := backwards ? -1 : 1
	next := at < 0 ? (backwards ? len(live) - 1 : 0) : (at + step + len(live)) % len(live)
	focus_window(s, live[next])
	note(s, fmt.tprintf("focus %s", title_of(live[next])))
}

begin_move :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	ws_float_for_drag(s, t)
	s.drag = .Move
	s.drag_t = t
	s.drag_from = s_pointer
	s.drag_orig = {t.x, t.y, t.w, t.h}
	focus_window(s, t)
}

begin_resize_edges :: proc(s: ^Server, t: ^Toplevel, edges: u32) {
	e: Edges
	switch edges {
	case 1:
		e = {.Top}
	case 2:
		e = {.Bottom}
	case 4:
		e = {.Left}
	case 5:
		e = {.Top, .Left}
	case 6:
		e = {.Bottom, .Left}
	case 8:
		e = {.Right}
	case 9:
		e = {.Top, .Right}
	case 10:
		e = {.Bottom, .Right}
	case:
		return
	}
	ws_float_for_drag(s, t)
	s.drag = .Resize
	s.drag_t = t
	s.drag_edges = e
	s.drag_from = s_pointer
	s.drag_orig = {t.x, t.y, t.w, t.h}
	t.resizing = true
	focus_window(s, t)
}

note :: proc(s: ^Server, msg: string) {
	delete(s.status)
	s.status = strings.clone(msg)
	s.status_at = wall_now()
}

wall_now :: proc() -> f64 {
	return time.duration_seconds(time.diff(start_time, time.now()))
}

title_of :: proc(t: ^Toplevel) -> string {
	if t == nil {
		return "nothing"
	}
	if t.title != "" {
		return t.title
	}
	if t.app_id != "" {
		return t.app_id
	}
	return "untitled"
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

content_rect :: proc(t: ^Toplevel) -> p.Rect {
	return {f32(t.x), f32(t.y), f32(t.w), f32(t.h)}
}

// The title bar height and the border width come from the config, and a rule
// can switch either off for one application, so these are per window.
title_rect :: proc(t: ^Toplevel) -> p.Rect {
	bw := ws_border(t)
	th := ws_title_h(t)
	return {f32(t.x - bw), f32(t.y - th), f32(t.w + 2 * bw), f32(th)}
}

frame_rect :: proc(t: ^Toplevel) -> p.Rect {
	bw := ws_border(t)
	th := ws_title_h(t)
	return {f32(t.x - bw), f32(t.y - th), f32(t.w + 2 * bw), f32(t.h + th + bw)}
}

// The three frame buttons, right to left: close, maximise, minimise.
button_rect :: proc(t: ^Toplevel, which: int) -> p.Rect {
	tr := title_rect(t)
	size := f32(20)
	gap := f32(6)
	right := tr.x + tr.w - 8
	x := right - f32(which) * (size + gap) - size
	return {x, tr.y + (tr.h - size) / 2, size, size}
}

Region :: enum u8 {
	None,
	Title,
	Content,
	Close,
	Maximise,
	Minimise,
	Edge,
}

hit_window :: proc(s: ^Server, t: ^Toplevel, mx, my: int) -> (Region, Edges) {
	px := f32(mx)
	py := f32(my)
	fr := frame_rect(t)
	outer := p.rect_inset(fr, -GRAB)
	if !p.rect_contains(outer, px, py) {
		return .None, {}
	}
	if !p.rect_contains(fr, px, py) {
		e: Edges
		if px < fr.x + GRAB {e += {.Left}}
		if px > fr.x + fr.w - GRAB {e += {.Right}}
		if py < fr.y + GRAB {e += {.Top}}
		if py > fr.y + fr.h - GRAB {e += {.Bottom}}
		if e == {} {
			return .None, {}
		}
		return .Edge, e
	}
	// Inside the frame: the bottom and side strips are still resize grips.
	e: Edges
	if px < fr.x + GRAB {e += {.Left}}
	if px > fr.x + fr.w - GRAB {e += {.Right}}
	if py > fr.y + fr.h - GRAB {e += {.Bottom}}
	if py < fr.y + 3 {e += {.Top}}
	if e != {} {
		return .Edge, e
	}
	for i in 0 ..< 3 {
		if p.rect_contains(button_rect(t, i), px, py) {
			return i == 0 ? .Close : (i == 1 ? .Maximise : .Minimise), {}
		}
	}
	if p.rect_contains(title_rect(t), px, py) {
		return .Title, {}
	}
	return .Content, {}
}

window_at :: proc(s: ^Server, mx, my: int) -> (^Toplevel, Region, Edges) {
	#reverse for t in s.stack {
		if !t.mapped || t.minimized {
			continue
		}
		if r, e := hit_window(s, t, mx, my); r != .None {
			return t, r, e
		}
	}
	return nil, .None, {}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

s_pointer: [2]int

pick_surface :: proc(surf: ^Surface, ox, oy, mx, my: int) -> (^Surface, int, int) {
	sc := max(surf.scale, 1)
	#reverse for ch in surf.children {
		if ch.img == nil {
			continue
		}
		if r, lx, ly := pick_surface(ch, ox + ch.sx, oy + ch.sy, mx, my); r != nil {
			return r, lx, ly
		}
	}
	if surf.img == nil {
		return nil, 0, 0
	}
	w := surf.iw / sc
	h := surf.ih / sc
	if mx >= ox && my >= oy && mx < ox + w && my < oy + h {
		return surf, mx - ox, my - oy
	}
	return nil, 0, 0
}

set_ptr_focus :: proc(s: ^Server, surf: ^Surface, lx, ly: int) {
	if s.ptr_surf == surf {
		return
	}
	if old := s.ptr_surf; old != nil && old.client != nil && !old.client.dead {
		for ptr in old.client.pointers {
			event(old.client, ptr, 1, next_serial(s), old.id)
			event(old.client, ptr, 5)
		}
	}
	s.ptr_surf = surf
	pconf_update(s)
	if surf != nil && surf.client != nil && !surf.client.dead {
		for ptr in surf.client.pointers {
			event(surf.client, ptr, 0, next_serial(s), surf.id, fixed(f32(lx)), fixed(f32(ly)))
			event(surf.client, ptr, 5)
		}
	}
}

ptr_motion :: proc(s: ^Server, lx, ly: int) {
	surf := s.ptr_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for ptr in surf.client.pointers {
		event(surf.client, ptr, 2, now_ms(), fixed(f32(lx)), fixed(f32(ly)))
		event(surf.client, ptr, 5)
	}
}

ptr_button :: proc(s: ^Server, btn: u32, pressed: bool) {
	surf := s.ptr_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for ptr in surf.client.pointers {
		event(surf.client, ptr, 3, next_serial(s), now_ms(), btn, pressed ? u32(1) : u32(0))
		event(surf.client, ptr, 5)
	}
}

ptr_axis :: proc(s: ^Server, dx, dy: f32) {
	surf := s.ptr_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for ptr in surf.client.pointers {
		event(surf.client, ptr, 6, u32(0)) // axis_source(wheel)
		if dy != 0 {
			event(surf.client, ptr, 4, now_ms(), u32(0), fixed(dy))
		}
		if dx != 0 {
			event(surf.client, ptr, 4, now_ms(), u32(1), fixed(dx))
		}
		event(surf.client, ptr, 5)
	}
}

BTN_LEFT :: u32(0x110)
BTN_RIGHT :: u32(0x111)
BTN_MIDDLE :: u32(0x112)

handle_pointer :: proc(s: ^Server, app: ^p.App, scale: f32) {
	in_ := &app.win.input
	mp := [2]int{int(in_.mouse.x * scale), int(in_.mouse.y * scale)}
	s_pointer = mp

	// A drag owns the pointer outright, including off the surface: the drop
	// target is decided by where the cursor is, not by what we are hovering.
	if dnd_active() {
		dnd_update(s, mp.x, mp.y, in_.down[.Left] || in_.down[.Middle] || in_.down[.Right])
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
	if overlay_pointer(s, app, mp) {
		s.hover_t = nil
		s.hover_btn = 0
		return
	}

	// An in-progress drag owns the pointer — unless the window it was
	// dragging has gone. A client that crashes mid-drag used to leave
	// `drag_t` pointing at freed memory and the next motion dereferenced it.
	if s.drag != .None && (s.drag_t == nil || !ws_alive(s, s.drag_t) || !s.drag_t.mapped) {
		s.drag = .None
		s.drag_t = nil
		s.drag_edges = {}
	}
	if s.drag != .None && s.drag_t != nil {
		t := s.drag_t
		d := mp - s.drag_from
		if s.drag == .Move {
			t.x = s.drag_orig[0] + d.x
			t.y = s.drag_orig[1] + d.y
			clamp_window(s, t)
		} else {
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
		if in_.released[.Left] || !in_.down[.Left] {
			if t.resizing {
				t.resizing = false
				send_configure(s, t, t.req_w, t.req_h)
			}
			if m, ok := ws_peek(t); ok && m.floating {
				m.float_rect = {t.x, t.y, t.req_w, t.req_h}
				m.have_float = true
			}
			s.drag = .None
			s.drag_t = nil
			s.drag_edges = {}
		}
		s.dirty = true
		return
	}

	t, region, edges := window_at(s, mp.x, mp.y)
	s.hover_t = t
	s.hover_btn = 0
	s.cur_out = ws_output_at(s, mp.x, mp.y)

	// Focus follows the mouse when the config says so, which is the one
	// setting people who have it never give up.
	if s.cfg.focus_follows_mouse && t != nil && t != s.focus && region != .None {
		focus_window(s, t)
	}
	switch region {
	case .Close:
		s.hover_btn = 1
	case .Maximise:
		s.hover_btn = 2
	case .Minimise:
		s.hover_btn = 3
	case .None, .Title, .Content, .Edge:
	}

	// Pointer focus for clients: only the content area forwards input.
	if region == .Content && t != nil && t.xdg != nil && t.xdg.surf != nil {
		surf, lx, ly := pick_surface(t.xdg.surf, t.x, t.y, mp.x, mp.y)
		if surf != nil {
			if surf != s.ptr_surf {
				set_ptr_focus(s, surf, lx, ly)
			} else if in_.mouse_delta != {0, 0} {
				ptr_motion(s, lx, ly)
			}
		} else {
			set_ptr_focus(s, nil, 0, 0)
		}
	} else {
		set_ptr_focus(s, nil, 0, 0)
	}

	// mod+drag moves, mod+right-drag resizes. Without this a window whose
	// rule turned the title bar off could not be moved at all.
	if t != nil && s.cfg.mod <= in_.mods && s.cfg.mod != {} {
		if in_.pressed[.Left] {
			ws_float_for_drag(s, t)
			begin_move(s, t)
			return
		}
		if in_.pressed[.Right] {
			ws_float_for_drag(s, t)
			focus_window(s, t)
			s.drag = .Resize
			s.drag_t = t
			s.drag_edges = {.Right, .Bottom}
			s.drag_from = mp
			s.drag_orig = {t.x, t.y, t.w, t.h}
			t.resizing = true
			return
		}
	}

	if in_.pressed[.Left] {
		switch region {
		case .Title:
			ws_float_for_drag(s, t)
			begin_move(s, t)
			note(s, fmt.tprintf("moving %s", title_of(t)))
		case .Edge:
			ws_float_for_drag(s, t)
			focus_window(s, t)
			s.drag = .Resize
			s.drag_t = t
			s.drag_edges = edges
			s.drag_from = mp
			s.drag_orig = {t.x, t.y, t.w, t.h}
			t.resizing = true
			note(s, fmt.tprintf("resizing %s", title_of(t)))
		case .Close:
			focus_window(s, t)
			close_window(s, t)
		case .Maximise:
			focus_window(s, t)
			set_maximized(s, t, !t.maximized)
		case .Minimise:
			t.minimized = true
			if s.focus == t {
				focus_window(s, topmost_other(s, t))
			}
			s.needs_layout = true
			note(s, fmt.tprintf("minimised %s", title_of(t)))
		case .Content:
			focus_window(s, t)
			ptr_button(s, BTN_LEFT, true)
		case .None:
			focus_window(s, nil)
		}
	}
	if in_.released[.Left] && region == .Content {
		ptr_button(s, BTN_LEFT, false)
	}
	if in_.pressed[.Right] && region == .Content {
		focus_window(s, t)
		ptr_button(s, BTN_RIGHT, true)
	}
	if in_.released[.Right] && region == .Content {
		ptr_button(s, BTN_RIGHT, false)
	}
	if in_.pressed[.Middle] && region == .Content {
		ptr_button(s, BTN_MIDDLE, true)
	}
	if in_.released[.Middle] && region == .Content {
		ptr_button(s, BTN_MIDDLE, false)
	}
	if in_.scroll != {0, 0} {
		ptr_axis(s, in_.scroll.x, in_.scroll.y)
	}
}

// mods_mask turns palmy's modifier set into the bitmask wl_keyboard.modifiers
// carries, using this keymap's own modifier indices.
mods_mask :: proc(s: ^Server, m: p.Modifiers, extra_shift: bool) -> u32 {
	v := u32(0)
	if .Shift in m || extra_shift {v |= mod_bit(s.kt.m_shift)}
	if .Ctrl in m {v |= mod_bit(s.kt.m_ctrl)}
	if .Alt in m {v |= mod_bit(s.kt.m_alt)}
	if .Super in m {v |= mod_bit(s.kt.m_super)}
	if .Caps in m {v |= mod_bit(s.kt.m_caps)}
	return v
}

// send_mods announces the modifier mask and the XKB group. The group is
// part of it because a layout switch (several layouts in /etc/palm/keyboard)
// changes what every keycode means without any modifier changing.
send_mods :: proc(s: ^Server, mask: u32) {
	if mask == s.mod_mask && s.kt.group == s.mod_group {
		return
	}
	s.mod_mask = mask
	s.mod_group = s.kt.group
	surf := s.kbd_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for k in surf.client.keyboards {
		event(surf.client, k, 4, next_serial(s), mask, u32(0), u32(0), s.kt.group)
	}
}

// forward_key turns a host keysym back into a keycode in the keymap we handed
// our clients, and sends press and release.
forward_key :: proc(s: ^Server, k: p.Key_Event) {
	surf := s.kbd_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	rev, ok := keycode_for(&s.kt, k.sym)
	if !ok {
		return
	}
	// Caps Lock already uppercases a letter; adding Shift on top would turn
	// it back to lowercase in the client.
	shift := rev.shift && !(rev.lock_ok && .Caps in k.mods)
	mask := mods_mask(s, k.mods, shift)
	if rev.level3 {
		mask |= mod_bit(s.kt.m_level3)
	}
	send_mods(s, mask)
	t := now_ms()
	for kb in surf.client.keyboards {
		event(surf.client, kb, 3, next_serial(s), t, rev.code, u32(1))
		event(surf.client, kb, 3, next_serial(s), t + 1, rev.code, u32(0))
	}
}

handle_keys :: proc(s: ^Server, app: ^p.App) {
	if overlay_keys(s, app) {
		return
	}
	in_ := &app.win.input
	send_mods(s, mods_mask(s, in_.mods, false))

	for k in in_.keys {
		log_line("key sym 0x%x mods %v repeat %v", k.sym, k.mods, k.repeat)
		if wm_shortcut(s, app, k) {
			continue
		}
		forward_key(s, k)
	}
}

// wm_shortcut consults the binding table the configuration produced. It
// returns true when the key was consumed and must not reach the focused
// client.
//
// There is no hardcoded binding left except one: Ctrl+Alt+Q leaves the
// compositor. A config file that bound nothing at all would otherwise be a
// trap, because --overlay takes the host keyboard exclusively.
wm_shortcut :: proc(s: ^Server, app: ^p.App, k: p.Key_Event) -> bool {
	if .Alt in k.mods && .Ctrl in k.mods && (k.sym == 'q' || k.sym == 'Q') {
		p.quit_app(app)
		return true
	}

	mods := k.mods - {.Caps}
	if b := wm_bind_for(s, mods, k.sym); b != nil {
		wm_do(s, app, b^)
		return true
	}

	// Window mode is a sticky layer on top of the table: while it is on the
	// bare arrow keys belong to the compositor rather than to the client.
	if s.wm_mode {
		switch k.sym {
		case p.KEY_LEFT, p.KEY_RIGHT, p.KEY_UP, p.KEY_DOWN:
			nudge(s, k.sym, .Shift in k.mods)
			return true
		case p.KEY_PAGE_UP:
			grow(s, s.cfg.resize_step)
			return true
		case p.KEY_PAGE_DOWN:
			grow(s, -s.cfg.resize_step)
			return true
		case p.KEY_ESCAPE:
			s.wm_mode = false
			note(s, "window mode off")
			return true
		}
	}
	return false
}

// wm_bind_for prefers a binding whose modifiers match exactly. An `ANY`
// binding is the fallback, so `$mod, F11` and `ANY, F11` can coexist and the
// modified one wins when the modifier is actually held.
wm_bind_for :: proc(s: ^Server, mods: p.Modifiers, sym: u32) -> ^Cfg_Bind {
	fallback: ^Cfg_Bind
	for &b in s.cfg.binds {
		if !cfg_sym_matches(b.sym, sym) {
			continue
		}
		if b.any_mods {
			if fallback == nil {
				fallback = &b
			}
			continue
		}
		if b.mods == mods {
			return &b
		}
	}
	return fallback
}

dir_sym :: proc(d: Cfg_Dir) -> u32 {
	switch d {
	case .Left:
		return p.KEY_LEFT
	case .Right:
		return p.KEY_RIGHT
	case .Up:
		return p.KEY_UP
	case .Down:
		return p.KEY_DOWN
	}
	return p.KEY_LEFT
}

// ws_tiled_now says whether the focused window is under the layout engine's
// control, which is what decides whether a direction key nudges it in pixels
// or reorders it in the tree.
wm_tiled_now :: proc(s: ^Server, t: ^Toplevel) -> bool {
	if t == nil || ws_floating(t) || t.maximized {
		return false
	}
	ws_ensure(s)
	return s.workspaces[s.cur_ws].tiling
}

wm_do :: proc(s: ^Server, app: ^p.App, b: Cfg_Bind) {
	switch b.act {
	case .None:
	case .Spawn:
		spawn(s, b.argv)
	case .Close:
		close_window(s, s.focus)
	case .Focus_Next:
		cycle_focus(s, false)
	case .Focus_Prev:
		cycle_focus(s, true)
	case .Focus_Dir:
		ws_focus_dir(s, Cfg_Dir(b.arg))
	case .Move_Dir:
		if wm_tiled_now(s, s.focus) {
			ws_swap_dir(s, Cfg_Dir(b.arg))
		} else {
			nudge(s, dir_sym(Cfg_Dir(b.arg)), false)
		}
	case .Resize_Dir:
		d := Cfg_Dir(b.arg)
		if wm_tiled_now(s, s.focus) {
			switch d {
			case .Left:
				ws_master_ratio(s, -5)
			case .Right:
				ws_master_ratio(s, 5)
			case .Up:
				ws_master_count(s, 1)
			case .Down:
				ws_master_count(s, -1)
			}
		} else {
			nudge(s, dir_sym(d), true)
		}
	case .Toggle_Float:
		ws_toggle_float(s, s.focus)
	case .Toggle_Maximize:
		if s.focus != nil {
			set_maximized(s, s.focus, !s.focus.maximized)
			note(s, s.focus.maximized ? "maximised" : "restored")
		}
	case .Minimize:
		if t := s.focus; t != nil {
			t.minimized = true
			focus_window(s, topmost_other(s, t))
			s.needs_layout = true
			note(s, fmt.tprintf("minimised %s", title_of(t)))
		}
	case .Toggle_Tiling:
		ws_toggle_tiling(s)
	case .Next_Layout:
		ws_next_layout(s)
	case .Master_Ratio:
		ws_master_ratio(s, b.arg)
	case .Master_Count:
		ws_master_count(s, b.arg)
	case .Swap_Master:
		ws_swap_master(s)
	case .Workspace:
		ws_switch(s, b.arg - 1)
	case .Workspace_Rel:
		ws_switch_rel(s, b.arg)
	case .Move_To_Workspace:
		ws_move_to(s, s.focus, b.arg - 1)
	case .Move_To_Workspace_Rel:
		ws_move_rel(s, s.focus, b.arg)
	case .Cascade:
		cascade_all(s)
		note(s, "re-cascaded every window")
	case .Window_Mode:
		s.wm_mode = !s.wm_mode
		note(s, s.wm_mode ? "window mode: arrows move, PgUp/PgDn resize" : "window mode off")
	case .Reload:
		wm_reload(s)
	case .Quit:
		p.quit_app(app)
	case .Session:
		name := cfg_session_name(b.arg)
		// On bare metal this compositor *is* the session, and ending it is
		// how the user gets back to the greeter: palm-login is waiting on
		// our exit. Power actions stay intent-only — they belong to the
		// greeter, which runs them through palm-login's privileges.
		if session.bare && (name == "exit" || name == "logout") {
			fmt.printfln("wm: session %q — leaving", name)
			p.quit_app(app)
			return
		}
		// Intent only. Power and session changes are logged and never run:
		// nested, this compositor is a guest on a live desktop.
		fmt.printfln("wm: session intent %q — logged, not executed", name)
		log_line("session intent %q (not executed)", name)
		note(s, fmt.tprintf("%s: logged, not executed", name))
	}
}

// wm_reload re-reads the configuration while the compositor is running. A
// window manager you have to restart to retune is a window manager you stop
// retuning, so this is a first-class operation and not a debugging aid.
wm_reload :: proc(s: ^Server) {
	cfg_load(&s.cfg)
	if session.kiosk {
		session_kiosk_preset(&s.cfg)
	}
	if len(s.workspaces) != s.cfg.workspaces {
		ws_build_workspaces(s)
	}
	// Re-apply the layout settings to every workspace. Editing master_ratio
	// and watching it move is the whole point of live reload, so the file
	// wins over a runtime toggle rather than the other way round.
	for &w in s.workspaces {
		w.tiling = s.cfg.tiling
		w.layout = s.cfg.layout
		w.master_ratio = s.cfg.master_ratio
		w.master_count = s.cfg.master_count
	}
	// Heads named in the file take their geometry from it; the host-backed
	// one keeps tracking the nested window.
	for co in s.cfg.outputs {
		if i := ws_output_find(s, co.name); i >= 0 && !s.outputs[i].host {
			s.outputs[i].x, s.outputs[i].y = co.x, co.y
			s.outputs[i].w, s.outputs[i].h = max(co.w, 1), max(co.h, 1)
			s.outputs[i].scale = co.scale <= 0 ? 1 : co.scale
			s.outputs[i].enabled = co.w > 0 && co.h > 0
		}
	}
	s.bg_w, s.bg_h = -1, -1 // the wallpaper bakes in the bar height
	s.needs_layout = true
	s.dirty = true
	for e in s.cfg.errors {
		fmt.eprintfln("wm: %s", e)
	}
	switch {
	case !s.cfg.loaded:
		note(s, fmt.tprintf("no %s — built-in defaults", s.cfg.path))
	case len(s.cfg.errors) > 0:
		note(s, fmt.tprintf("config reloaded, %d problem(s)", len(s.cfg.errors)))
	case:
		note(s, "config reloaded")
	}
	fmt.printfln(
		"wm: config %s (%d bindings, %d rules, %d workspaces)",
		s.cfg.loaded ? s.cfg.path : "built-in defaults",
		len(s.cfg.binds),
		len(s.cfg.rules),
		len(s.workspaces),
	)
}

nudge :: proc(s: ^Server, sym: u32, resize: bool) {
	t := s.focus
	if t == nil {
		return
	}
	// Nudging a window the layout engine owns would only be undone on the
	// next pass, so it reorders the tree instead.
	if wm_tiled_now(s, t) {
		if resize {
			switch sym {
			case p.KEY_LEFT:
				ws_master_ratio(s, -5)
			case p.KEY_RIGHT:
				ws_master_ratio(s, 5)
			case p.KEY_UP:
				ws_master_count(s, 1)
			case p.KEY_DOWN:
				ws_master_count(s, -1)
			}
			return
		}
		switch sym {
		case p.KEY_LEFT:
			ws_swap_dir(s, .Left)
		case p.KEY_RIGHT:
			ws_swap_dir(s, .Right)
		case p.KEY_UP:
			ws_swap_dir(s, .Up)
		case p.KEY_DOWN:
			ws_swap_dir(s, .Down)
		}
		return
	}
	step := max(s.cfg.move_step, 1)
	if resize {
		step = max(s.cfg.resize_step, 1)
	}
	if resize {
		nw, nh := t.req_w, t.req_h
		switch sym {
		case p.KEY_LEFT:
			nw -= step
		case p.KEY_RIGHT:
			nw += step
		case p.KEY_UP:
			nh -= step
		case p.KEY_DOWN:
			nh += step
		}
		resize_to(s, t, nw, nh)
		return
	}
	switch sym {
	case p.KEY_LEFT:
		t.x -= step
	case p.KEY_RIGHT:
		t.x += step
	case p.KEY_UP:
		t.y -= step
	case p.KEY_DOWN:
		t.y += step
	}
	clamp_window(s, t)
	note(s, fmt.tprintf("%s at %d,%d", title_of(t), t.x, t.y))
	s.dirty = true
}

grow :: proc(s: ^Server, by: int) {
	t := s.focus
	if t == nil {
		return
	}
	if wm_tiled_now(s, t) {
		ws_master_ratio(s, by > 0 ? 5 : -5)
		return
	}
	resize_to(s, t, t.req_w + by, t.req_h + by * 3 / 4)
}

resize_to :: proc(s: ^Server, t: ^Toplevel, w, h: int) {
	oi := ws_output_at(s, t.x + t.w / 2, t.y)
	_, _, ow, oh := ws_output_rect(s, oi)
	nw := clamp(w, max(MIN_W, t.min_w), max(ow, MIN_W))
	nh := clamp(h, max(MIN_H, t.min_h), max(oh - ws_bar_h(s) - ws_title_h(t), MIN_H))
	if t.max_w > 0 {nw = min(nw, t.max_w)}
	if t.max_h > 0 {nh = min(nh, t.max_h)}
	if nw == t.req_w && nh == t.req_h {
		return
	}
	t.maximized = false
	t.anchor_x, t.anchor_y = false, false
	t.req_w, t.req_h = nw, nh
	send_configure(s, t, nw, nh)
	note(s, fmt.tprintf("%s resized to %dx%d", title_of(t), nw, nh))
	s.dirty = true
}

cascade_all :: proc(s: ^Server) {
	ws_ensure(s)
	ox, oy, _, _ := ws_output_rect(s, s.cur_out)
	n := 0
	for t in s.stack {
		if !t.mapped {
			continue
		}
		t.minimized = false
		t.x = ox + 56 + (n % 6) * 44
		t.y = oy + ws_bar_h(s) + ws_title_h(t) + 24 + (n % 6) * 38
		clamp_window(s, t)
		n += 1
	}
	s.dirty = true
}

// spawn runs a configured command. The command is resolved against $PATH —
// never against a path compiled into this binary — and nothing runs that the
// configuration (or the --exec command line) did not ask for. The child gets
// WAYLAND_DISPLAY pointing here and inherits XDG_RUNTIME_DIR, which is where
// the socket lives. The pid comes back so the session can watch it.
spawn :: proc(s: ^Server, argv_in: []string) -> (pid: linux.Pid, ok: bool) {
	if len(argv_in) == 0 {
		return
	}
	exe, found := cfg_which(argv_in[0])
	if !found {
		note(s, fmt.tprintf("%s: not found on $PATH", argv_in[0]))
		log_line("spawn %q: not on $PATH", argv_in[0])
		fmt.eprintfln("wm: %s: not found on $PATH", argv_in[0])
		return
	}
	argv := make([]string, len(argv_in), context.temp_allocator)
	copy(argv, argv_in)
	argv[0] = exe

	base, err := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(base) + 2, context.temp_allocator)
	if err == nil {
		for e in base {
			if strings.has_prefix(e, "WAYLAND_DISPLAY=") || strings.has_prefix(e, "WAYLAND_SOCKET=") {
				continue
			}
			append(&env, e)
		}
	}
	append(&env, fmt.tprintf("WAYLAND_DISPLAY=%s", s.display_name))
	proc_, perr := os.process_start(
		{command = argv, env = env[:], stdout = os.stderr, stderr = os.stderr},
	)
	if perr != nil {
		note(s, fmt.tprintf("could not launch %s: %v", argv_in[0], perr))
		fmt.eprintfln("wm: could not launch %s: %v", argv_in[0], perr)
		return
	}
	note(s, fmt.tprintf("launched %s", argv_in[0]))
	log_line("spawned %s as pid %d", exe, proc_.pid)
	return linux.Pid(proc_.pid), true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

DESK_TOP :: 0x0b1020
DESK_BOT :: 0x141c30
BAR_BG :: 0x0a0a0c
FRAME_ON :: 0x27272a
FRAME_OFF :: 0x18181b
EDGE_ON :: 0x52525b
EDGE_OFF :: 0x27272a
TEXT_ON :: 0xfafafa
TEXT_OFF :: 0x8b8b93
ACCENT :: 0x6366f1

// build_desktop rasterizes the wallpaper once per resize.
build_desktop :: proc(s: ^Server, w, h: int) {
	if s.bg_w == w && s.bg_h == h && s.bg != nil {
		return
	}
	delete(s.bg)
	s.bg = make([]u32, w * h)
	s.bg_w, s.bg_h = w, h
	bc := p.canvas_from(s.bg, w, h)
	defer p.canvas_destroy(&bc)
	p.fill_rect_paint(&bc, {0, 0, f32(w), f32(h)}, p.gradient(p.hex(DESK_TOP), p.hex(DESK_BOT), true))
	for y := ws_bar_h(s) + 16; y < h; y += 32 {
		for x := 16; x < w; x += 32 {
			p.blend(&bc, x, y, p.hex(0x2a3550), 0.5)
		}
	}
	// A soft glow behind the middle, so the desktop is not perfectly flat.
	p.drop_shadow(&bc, {f32(w) / 2 - 240, f32(h) / 2 - 150, 480, 300}, {180, 180, 180, 180}, 320, 0, {0, 0}, p.hexa(0x4338ca22))
}

// draw paints every enabled output in turn. With one output — which is all
// the nested host can give us — this is exactly what it did before: the
// output's rectangle is the whole canvas.
draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	ws_ensure(s)

	p.reset_clip(cv)
	build_desktop(s, cv.w, cv.h)
	copy(cv.px[:cv.w * cv.h], s.bg)

	layer_arrange(s)
	if lock_active() {
		lock_draw(s, app, cv)
		return
	}
	layer_draw(s, cv, false)

	for o, oi in s.outputs {
		if !o.enabled {
			continue
		}
		idx := ws_active_of_output(s, oi)
		p.reset_clip(cv)
		p.push_clip(cv, {f32(o.x), f32(o.y), f32(o.w), f32(o.h)})

		draw_bar(s, app, cv, oi, idx)

		stack := ws_stack(s, idx)
		for t in stack {
			if !t.mapped || t.minimized {
				continue
			}
			draw_window(s, app, cv, t)
		}
		if len(stack) == 0 && !session.kiosk {
			// The welcome card is for an empty *session*. A workspace you
			// have just switched to that happens to be empty, while three
			// windows run next door, gets a quiet label instead.
			if ws_total_windows(s) == 0 {
				draw_welcome(s, app, cv, o)
			} else {
				draw_empty_workspace(s, app, cv, o, idx)
			}
		}
		// Minimised windows get a small dock at the bottom.
		draw_dock(s, app, cv, idx, o)
		p.pop_clip(cv)
	}
	p.reset_clip(cv)
	layer_draw(s, cv, true)

	// The drag icon follows the cursor above everything, including overlays.
	dnd_draw(s, cv)
}

draw_bar :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, oi, ws_idx: int) {
	if !s.cfg.bar {
		return
	}
	f := &app.fonts
	o := s.outputs[oi]
	X := f32(o.x)
	Y := f32(o.y)
	W := f32(o.w)
	H := f32(s.cfg.bar_h)
	p.fill_rect(cv, {X, Y, W, H}, p.hex(BAR_BG))
	p.fill_rect(cv, {X, Y + H - 1, W, 1}, p.hex(0x27272a))

	mid := Y + H / 2 + 4.5
	p.fill_round_rect(cv, {X + 12, Y + H / 2 - 7, 14, 14}, {4, 4, 4, 4}, p.hex(ACCENT))
	x := X + 34
	x += p.draw_text(cv, f, "palmy wm", x, mid, 13, p.hex(TEXT_ON), .Sans, .Semibold)
	x += 12

	// The workspace strip. A daily driver has to answer "where am I and what
	// else is running" without being asked, so every workspace that exists is
	// drawn: filled when it is the one on screen, outlined when it holds
	// windows you cannot see, and dimmed when it is empty.
	for w, i in s.workspaces {
		if w.output != oi {
			continue
		}
		lw := max(p.text_width(f, w.name, 11, .Sans, .Semibold) + 14, 22)
		r := p.Rect{x, Y + H / 2 - 9, lw, 18}
		occupied := ws_count_on(s, i) > 0
		switch {
		case i == ws_idx:
			p.fill_round_rect(cv, r, {5, 5, 5, 5}, p.hex(ACCENT))
		case occupied:
			p.fill_round_rect(cv, r, {5, 5, 5, 5}, p.hex(0x1e1b4b))
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(0x4338ca))
		case:
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(0x27272a))
		}
		col := u32(i == ws_idx ? 0xffffff : (occupied ? 0xc7d2fe : 0x52525b))
		tw := p.text_width(f, w.name, 11, .Sans, .Semibold)
		p.draw_text(cv, f, w.name, r.x + (lw - tw) / 2, Y + H / 2 + 4, 11, p.hex(col), .Sans, .Semibold)
		x += lw + 4
	}
	x += 10

	// The layout badge: which automatic layout this workspace is running, or
	// that it is floating.
	ws := &s.workspaces[ws_idx]
	mode := ws.tiling ? tile_layout_name(ws.layout) : "floating"
	mw := p.text_width(f, mode, 11, .Sans, .Medium) + 14
	p.fill_round_rect(cv, {x, Y + H / 2 - 9, mw, 18}, {5, 5, 5, 5}, p.hex(0x18181b))
	p.stroke_round_rect(cv, {x, Y + H / 2 - 9, mw, 18}, {5, 5, 5, 5}, 1, p.hex(0x3f3f46))
	p.draw_text(cv, f, mode, x + 7, Y + H / 2 + 4, 11, p.hex(0xa5b4fc), .Sans, .Medium)
	x += mw + 10

	mapped := 0
	for t in ws_stack(s, ws_idx) {
		if t.mapped {mapped += 1}
	}
	x += p.draw_text(
		cv,
		f,
		fmt.tprintf(
			"%d window%s  %d client%s  %.0f fps",
			mapped,
			mapped == 1 ? "" : "s",
			len(s.clients),
			len(s.clients) == 1 ? "" : "s",
			app.fps,
		),
		x,
		mid,
		12,
		p.hex(TEXT_OFF),
	)

	if s.wm_mode {
		lbl := "WINDOW MODE"
		w := p.text_width(f, lbl, 11, .Sans, .Semibold) + 16
		p.fill_round_rect(cv, {x + 14, Y + H / 2 - 9, w, 18}, {5, 5, 5, 5}, p.hex(ACCENT))
		p.draw_text(cv, f, lbl, x + 22, Y + H / 2 + 4, 11, p.hex(0xffffff), .Sans, .Semibold)
		x += w + 18
	}

	// The clock is the rightmost thing, in local time (clock.odin); the
	// keyboard layout sits just left of it whenever it is not plain US, or
	// there is more than one to switch between, so a French keyboard is never
	// a surprise. The legend or a status note fills what is left.
	right := X + W
	{
		local, _ := clock_now()
		ct := clock_text(local)
		cw := p.text_width(f, ct, 12, .Sans, .Medium)
		p.draw_text(cv, f, ct, right - cw - 12, mid, 12, p.hex(TEXT_ON), .Sans, .Medium)
		right -= cw + 24
		if session.bare && (kbd.label != "us" || xkb_km.ngroups > 1) && kbd.label != "" {
			lbl := strings.to_upper(kbd.label, context.temp_allocator)
			lw := p.text_width(f, lbl, 11, .Sans, .Semibold) + 14
			r := p.Rect{right - lw, Y + H / 2 - 9, lw, 18}
			p.stroke_round_rect(cv, r, {5, 5, 5, 5}, 1, p.hex(0x3f3f46))
			p.draw_text(cv, f, lbl, r.x + 7, Y + H / 2 + 4, 11, p.hex(0xa5b4fc), .Sans, .Semibold)
			right -= lw + 10
		}
	}
	W = right - X
	if s.status != "" && wall_now() - s.status_at < 3.0 {
		tw := p.text_width(f, s.status, 12, .Sans, .Medium)
		p.fill_round_rect(cv, {right - tw - 26, Y + H / 2 - 10, tw + 20, 20}, {6, 6, 6, 6}, p.hex(0x1e1b4b))
		p.draw_text(cv, f, s.status, right - tw - 16, Y + H / 2 + 4, 12, p.hex(0xc7d2fe), .Sans, .Medium)
	} else {
		hint := bar_hint(s)
		hw := p.text_width(f, hint, 11)
		if hw < W - (x - X) - 24 {
			p.draw_text(cv, f, hint, right - hw - 12, mid, 11, p.hex(0x6b6b76))
		}
	}
}

// bar_hint is built from the live binding table rather than from a string
// literal, so it cannot describe keys the configuration no longer binds.
bar_hint :: proc(s: ^Server) -> string {
	b := strings.builder_make(context.temp_allocator)
	shown := 0
	for bind in s.cfg.binds {
		if !bind.any_mods {
			continue
		}
		name := ""
		for e in CFG_KEYNAMES {
			if e.sym == bind.sym {
				name = e.name
				break
			}
		}
		if name == "" {
			continue
		}
		if shown > 0 {
			strings.write_string(&b, "  ")
		}
		strings.write_string(&b, name)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, bind.label)
		shown += 1
	}
	if shown == 0 {
		return "no bindings configured"
	}
	return strings.to_string(b)
}

draw_welcome :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output) {
	f := &app.fonts
	cx := f32(o.x) + f32(o.w) / 2
	cy := f32(o.y) + f32(o.h) / 2
	first := "no bindings configured"
	// On bare metal every modifier reaches us, so the hint can name the real
	// binding — and it should name one whose program is actually installed.
	if session.bare {
		for bind in s.cfg.binds {
			if bind.act != .Spawn || len(bind.argv) == 0 || bind.any_mods {
				continue
			}
			if _, found := cfg_which(bind.argv[0]); !found {
				continue
			}
			key := ""
			for e in CFG_KEYNAMES {
				if e.sym == bind.sym {
					key = e.name
					break
				}
			}
			if key == "" {
				continue
			}
			mods := ""
			if .Super in bind.mods {mods = strings.concatenate({mods, "SUPER+"}, context.temp_allocator)}
			if .Ctrl in bind.mods {mods = strings.concatenate({mods, "CTRL+"}, context.temp_allocator)}
			if .Alt in bind.mods {mods = strings.concatenate({mods, "ALT+"}, context.temp_allocator)}
			if .Shift in bind.mods {mods = strings.concatenate({mods, "SHIFT+"}, context.temp_allocator)}
			first = fmt.tprintf("press %s%s to run %s", mods, key, bind.argv[0])
			break
		}
	}
	for bind in s.cfg.binds {
		if session.bare && first != "no bindings configured" {
			break
		}
		if bind.act == .Spawn && bind.any_mods {
			for e in CFG_KEYNAMES {
				if e.sym == bind.sym {
					first = fmt.tprintf("press %s to run %s inside it", e.name, bind.argv[0])
					break
				}
			}
			break
		}
	}
	lines := [?]struct {
		text: string,
		size: f32,
		wt:   p.Font_Weight,
		col:  u32,
	} {
		{session.bare ? "Palmframe" : "A Wayland compositor, nested", 26, .Bold, 0xe8e8ef},
		{fmt.tprintf("listening on %s", s.path), 13, .Regular, 0x8b8b93},
		{first, 14, .Medium, 0xa5b4fc},
		{
			s.cfg.loaded 			? fmt.tprintf("configuration: %s", s.cfg.path) 			: fmt.tprintf("no %s — built-in defaults", s.cfg.path),
			12,
			.Regular,
			0x6b6b76,
		},
	}
	y := cy - 48
	for l in lines {
		w := p.text_width(f, l.text, l.size, .Sans, l.wt)
		p.draw_text(cv, f, l.text, cx - w / 2, y, l.size, p.hex(l.col), .Sans, l.wt)
		y += l.size + 18
	}
}

draw_empty_workspace :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, o: Ws_Output, idx: int) {
	f := &app.fonts
	label := fmt.tprintf("workspace %s", s.workspaces[idx].name)
	w := p.text_width(f, label, 15, .Sans, .Medium)
	cx := f32(o.x) + f32(o.w) / 2
	cy := f32(o.y) + f32(o.h) / 2
	p.draw_text(cv, f, label, cx - w / 2, cy, 15, p.hex(0x4b4b57), .Sans, .Medium)
	sub := "empty"
	sw := p.text_width(f, sub, 12)
	p.draw_text(cv, f, sub, cx - sw / 2, cy + 22, 12, p.hex(0x3a3a44))
}

draw_dock :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, ws_idx: int, o: Ws_Output) {
	f := &app.fonts
	stack := ws_stack(s, ws_idx)
	n := 0
	for t in stack {
		if t.mapped && t.minimized {n += 1}
	}
	if n == 0 {
		return
	}
	x := f32(o.x) + 16
	y := f32(o.y + o.h) - 38
	for t in stack {
		if !t.mapped || !t.minimized {
			continue
		}
		label := title_of(t)
		w := min(p.text_width(f, label, 12, .Sans, .Medium) + 24, 220)
		p.fill_round_rect(cv, {x, y, w, 26}, {7, 7, 7, 7}, p.hex(0x1f1f25))
		p.stroke_round_rect(cv, {x, y, w, 26}, {7, 7, 7, 7}, 1, p.hex(0x3f3f46))
		p.push_clip(cv, {x + 10, y, w - 20, 26})
		p.draw_text(cv, f, label, x + 12, y + 17, 12, p.hex(0xc7c7cf), .Sans, .Medium)
		p.pop_clip(cv)
		x += w + 8
	}
}

draw_window :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, t: ^Toplevel) {
	// A kiosk client is the whole screen: no shadow, no ring, no frame.
	if session.kiosk {
		p.push_clip(cv, content_rect(t))
		if t.xdg != nil && t.xdg.surf != nil {
			blit_surface(cv, t.xdg.surf, t.x, t.y)
		}
		p.pop_clip(cv)
		return
	}
	f := &app.fonts
	focused := s.focus == t
	fr := frame_rect(t)
	th := f32(ws_title_h(t))
	bw := f32(ws_border(t))
	rad := p.Radius{th > 0 ? 9 : 4, th > 0 ? 9 : 4, 0, 0}

	ring_shadow(
		cv,
		fr,
		{rad[0], rad[1], 3, 3},
		focused ? 26 : 14,
		focused ? 2 : 0,
		{0, focused ? 10 : 5},
		p.hexa(focused ? 0x00000099 : 0x00000066),
	)

	// Frame plate. Only the title bar and the border are painted: the
	// client's own pixels cover everything inside.
	plate := p.hex(focused ? FRAME_ON : FRAME_OFF)
	if th > 0 {
		p.fill_round_rect(cv, {fr.x, fr.y, fr.w, th + 10}, rad, plate)
	}
	if bw > 0 {
		edge := p.hex(focused ? s.cfg.border_focus : s.cfg.border_unfocus)
		p.fill_rect(cv, {fr.x, f32(t.y), bw, f32(t.h) + bw}, edge)
		p.fill_rect(cv, {f32(t.x + t.w), f32(t.y), bw, f32(t.h) + bw}, edge)
		p.fill_rect(cv, {fr.x, f32(t.y + t.h), fr.w, bw}, edge)
		if th == 0 {
			p.fill_rect(cv, {fr.x, fr.y, fr.w, bw}, edge)
		}
	}

	// Client pixels.
	cr := content_rect(t)
	p.push_clip(cv, cr)
	if t.xdg != nil && t.xdg.surf != nil {
		blit_surface(cv, t.xdg.surf, t.x, t.y)
	}
	p.pop_clip(cv)

	// Title.
	if th <= 0 {
		p.stroke_round_rect(cv, fr, rad, 1, p.hex(focused ? s.cfg.border_focus : s.cfg.border_unfocus))
		if focused {
			p.stroke_round_rect(cv, p.rect_inset(fr, -1.5), rad, 1, p.hexa(s.cfg.border_focus << 8 | 0x66))
		}
		return
	}
	tr := title_rect(t)
	p.push_clip(cv, tr)
	if focused {
		p.fill_rect(cv, {tr.x, tr.y + tr.h - 1, tr.w, 1}, p.hex(0x3f3f46))
	}
	label := title_of(t)
	avail := tr.w - 120
	txt := label
	for p.text_width(f, txt, 12.5, .Sans, .Semibold) > avail && len(txt) > 1 {
		txt = txt[:len(txt) - 1]
	}
	if len(txt) < len(label) && len(txt) > 2 {
		txt = fmt.tprintf("%s...", txt[:len(txt) - 2])
	}
	p.draw_text(
		cv,
		f,
		txt,
		tr.x + 12,
		tr.y + tr.h / 2 + 4.5,
		12.5,
		p.hex(focused ? TEXT_ON : TEXT_OFF),
		.Sans,
		.Semibold,
	)
	p.pop_clip(cv)

	// Frame buttons.
	for i in 0 ..< 3 {
		br := button_rect(t, i)
		hot := s.hover_t == t && s.hover_btn == i + 1
		bg := u32(0)
		switch i {
		case 0:
			bg = hot ? 0xe7000b : 0x3f3f46
		case 1:
			bg = hot ? 0x16a34a : 0x3f3f46
		case 2:
			bg = hot ? 0xca8a04 : 0x3f3f46
		}
		if !focused && !hot {
			bg = 0x2a2a30
		}
		p.fill_circle(cv, br.x + br.w / 2, br.y + br.h / 2, br.w / 2 - 1, p.hex(bg))
		gl := p.hex(hot ? 0xffffff : (focused ? 0xd4d4d8 : 0x71717a))
		cxp := br.x + br.w / 2
		cyp := br.y + br.h / 2
		switch i {
		case 0:
			p.draw_line(cv, cxp - 3.5, cyp - 3.5, cxp + 3.5, cyp + 3.5, 1.4, gl)
			p.draw_line(cv, cxp + 3.5, cyp - 3.5, cxp - 3.5, cyp + 3.5, 1.4, gl)
		case 1:
			p.stroke_round_rect(cv, {cxp - 3.5, cyp - 3.5, 7, 7}, {1.5, 1.5, 1.5, 1.5}, 1.3, gl)
		case 2:
			p.draw_line(cv, cxp - 3.5, cyp, cxp + 3.5, cyp, 1.4, gl)
		}
	}

	// Outline last, so it sits over both the bar and the client pixels.
	p.stroke_round_rect(
		cv,
		fr,
		{rad[0], rad[1], 3, 3},
		1,
		p.hex(focused ? s.cfg.border_focus : s.cfg.border_unfocus),
	)
	if focused {
		// The halo is the focus colour, not a colour baked in here.
		p.stroke_round_rect(cv, p.rect_inset(fr, -1.5), {10, 10, 4, 4}, 1, p.hexa(s.cfg.border_focus << 8 | 0x66))
	}
}

// ring_shadow draws a drop shadow only in the band around a window.
//
// The interior is about to be covered by the client's own pixels, and the
// signed-distance evaluation is the expensive part of the frame, so skipping
// it there is most of the compositor's frame budget.
ring_shadow :: proc(cv: ^p.Canvas, r: p.Rect, rad: p.Radius, blur, spread: f32, offset: [2]f32, col: p.Color) {
	pad := blur + spread + 2
	o := p.Rect{r.x + offset.x - pad, r.y + offset.y - pad, r.w + 2 * pad, r.h + 2 * pad}
	in_ := p.rect_inset(r, 1)
	strips := [4]p.Rect {
		{o.x, o.y, o.w, in_.y - o.y},
		{o.x, in_.y + in_.h, o.w, p.rect_bottom(o) - (in_.y + in_.h)},
		{o.x, in_.y, in_.x - o.x, in_.h},
		{in_.x + in_.w, in_.y, p.rect_right(o) - (in_.x + in_.w), in_.h},
	}
	for st in strips {
		if st.w <= 0 || st.h <= 0 {
			continue
		}
		p.push_clip(cv, st)
		p.drop_shadow(cv, r, rad, blur, spread, offset, col)
		p.pop_clip(cv)
	}
}

// blit_surface copies a client's pixels into the output, then its subsurfaces.
blit_surface :: proc(cv: ^p.Canvas, surf: ^Surface, ox, oy: int) {
	if surf.img != nil {
		blit(cv, surf.img, surf.iw, surf.ih, max(surf.scale, 1), ox, oy, surf.opaque)
	}
	for ch in surf.children {
		blit_surface(cv, ch, ox + ch.sx, oy + ch.sy)
	}
}

blit :: proc(cv: ^p.Canvas, img: []u32, iw, ih, scale, ox, oy: int, opaque: bool) {
	clip := cv.clip
	x0 := max(ox, int(clip.x))
	y0 := max(oy, int(clip.y))
	x1 := min(ox + iw / scale, int(clip.x + clip.w))
	y1 := min(oy + ih / scale, int(clip.y + clip.h))
	x0 = max(x0, 0)
	y0 = max(y0, 0)
	x1 = min(x1, cv.w)
	y1 = min(y1, cv.h)
	if x1 <= x0 || y1 <= y0 {
		return
	}

	for y in y0 ..< y1 {
		sy := (y - oy) * scale
		if sy >= ih {
			break
		}
		src := img[sy * iw:][:iw]
		dst := cv.px[y * cv.w:][:cv.w]
		if opaque && scale == 1 {
			copy(dst[x0:x1], src[x0 - ox:x1 - ox])
			continue
		}
		for x in x0 ..< x1 {
			sx := (x - ox) * scale
			if sx >= iw {
				break
			}
			v := src[sx]
			a := v >> 24
			if a == 0 {
				continue
			}
			if a == 255 {
				dst[x] = 0xff00_0000 | (v & 0xffffff)
				continue
			}
			// The client's buffer is premultiplied, which is what argb8888
			// means on Wayland.
			d := dst[x]
			na := 255 - a
			r := ((v >> 16) & 0xff) + (((d >> 16) & 0xff) * na) / 255
			g := ((v >> 8) & 0xff) + (((d >> 8) & 0xff) * na) / 255
			b := (v & 0xff) + ((d & 0xff) * na) / 255
			dst[x] = 0xff00_0000 | (min(r, 255) << 16) | (min(g, 255) << 8) | min(b, 255)
		}
	}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

atoi :: proc(t: string) -> int {
	v := 0
	for ch in t {
		if ch < '0' || ch > '9' {
			break
		}
		v = v * 10 + int(ch - '0')
	}
	return v
}

// host_layout works out which XKB layout the user is actually typing on.
//
// palmy exposes the keymap the host handed it, but `keymap_load` frees the
// copy it keeps, so `host_keymap` comes back empty (see the report). Until
// that is fixed we ask the host compositor for its RMLVO description and
// compile the same layout ourselves, which keeps the keymap we hand to nested
// clients identical to the one producing the keysyms we receive.
host_layout :: proc() -> Rule_Names {
	get :: proc(opt: string) -> string {
		out, ok := kit.run({"hyprctl", "getoption", opt, "-j"}, context.temp_allocator)
		if !ok {
			return ""
		}
		// The payload is small and fixed in shape: "str": "<value>".
		key := "\"str\""
		i := strings.index(out, key)
		if i < 0 {
			return ""
		}
		rest := out[i + len(key):]
		a := strings.index_byte(rest, '"')
        if a < 0 {
			return ""
		}
		rest = rest[a + 1:]
		b := strings.index_byte(rest, '"')
		if b < 0 {
			return ""
		}
		return rest[:b]
	}
	pick :: proc(a, b, c: string) -> cstring {
		v := a
		if v == "" {v = b}
		if v == "" {v = c}
		if v == "" {
			return nil
		}
		return strings.clone_to_cstring(v)
	}
	env :: proc(name: string) -> string {
		return os.get_env(name, context.temp_allocator)
	}
	return Rule_Names {
		rules = pick(get("input:kb_rules"), env("XKB_DEFAULT_RULES"), ""),
		model = pick(get("input:kb_model"), env("XKB_DEFAULT_MODEL"), ""),
		layout = pick(get("input:kb_layout"), env("XKB_DEFAULT_LAYOUT"), "us"),
		variant = pick(get("input:kb_variant"), env("XKB_DEFAULT_VARIANT"), ""),
		options = pick(get("input:kb_options"), env("XKB_DEFAULT_OPTIONS"), ""),
	}
}


main :: proc() {
	start_time = time.now()
	display := "wayland-palmy"
	overlay := false
	seconds := 0
	conf := ""
	args := os.args[1:]
	for a, i in args {
		// `--shots <dir>` renders the compositor's output offscreen and writes
		// PNGs. No surface is opened and no socket is bound; the clients in
		// the picture are fabricated. See shot.odin.
		if a == "--shots" {
			os.exit(shots(i + 1 < len(args) ? args[i + 1] : "shots"))
		}
		// `--ws-shots <dir>` does the same for the tiling layouts and the
		// workspace strip. See ws_shots in workspace.odin.
		if a == "--selftest" {
			os.exit(ws_selftest())
		}
		if a == "--ws-shots" {
			os.exit(ws_shots(i + 1 < len(args) ? args[i + 1] : "shots"))
		}
	}
	use_drm, use_nested := false, false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "-v" || a == "--verbose":
			VERBOSE = true
		case a == "--overlay":
			overlay = true
		case a == "--drm":
			use_drm = true
		case a == "--nested":
			use_nested = true
		case a == "--kiosk":
			session.kiosk = true
		case a == "--exec" && i + 1 < len(args):
			// One argument, word-split the way a config `exec =` line is, so
			// `--exec "greeter --demo"` and `--exec term` both do the obvious.
			i += 1
			if argv := cfg_argv(args[i]); len(argv) > 0 {
				append(&session.execs, argv)
			}
		case strings.has_prefix(a, "--exec="):
			if argv := cfg_argv(a[len("--exec="):]); len(argv) > 0 {
				append(&session.execs, argv)
			}
		case strings.has_prefix(a, "--display="):
			display = a[len("--display="):]
		case strings.has_prefix(a, "--seconds="):
			seconds = atoi(a[len("--seconds="):])
		case strings.has_prefix(a, "--config="):
			conf = a[len("--config="):]
		}
	}

	// Bare metal when asked, or when there is nothing to nest inside and a
	// KMS node to drive — which is how palm-login starts a session. Nested
	// stays exactly what it was otherwise.
	if use_drm || (!use_nested && !overlay && bare_auto()) {
		os.exit(bare_main(display, conf))
	}

	// --overlay opens the compositor as a layer-shell surface instead of an
	// ordinary window: it sits above everything on the host and takes the
	// keyboard exclusively, which is the only way to record it without the
	// host's other windows drawing over the top of it.
	cfg := p.Config {
		title  = "palmy wm",
		app_id = "palmy-wm",
		width  = OVERLAY_W,
		height = OVERLAY_H,
	}
	if overlay {
		cfg.layer = true
		cfg.layer_level = .Overlay
		cfg.layer_keyboard = .Exclusive
		cfg.layer_anchor = {.Top, .Left}
		cfg.layer_margin = {OVERLAY_Y, 0, 0, OVERLAY_X}
	}
	app, err := kit.start(cfg)
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	// The host sends the keymap shortly after the keyboard appears; we need it
	// before any client can be told how to read a keycode.
	for i in 0 ..< 80 {
		if p.host_keymap(app) != "" {
			break
		}
		p.window_wait(&app.win, 20)
	}

	s := &server
	s.out_w = app.win.width * app.win.scale
	s.out_h = app.win.height * app.win.scale
	s.repeat_rate = max(app.win.repeat_rate, 25)
	s.repeat_delay = app.win.repeat_delay > 0 ? app.win.repeat_delay : 400

	// Configuration before anything else, because it decides how many
	// workspaces there are and what every key does.
	if conf != "" {
		s.cfg.path = strings.clone(conf)
	}
	cfg_load(&s.cfg)
	for e in s.cfg.errors {
		fmt.eprintfln("wm: %s", e)
	}
	ws_ensure(s)
	fmt.printfln(
		"wm: config %s — %d bindings, %d rules, %d workspaces, layout %s",
		s.cfg.loaded ? s.cfg.path : "built-in defaults (no file)",
		len(s.cfg.binds),
		len(s.cfg.rules),
		len(s.workspaces),
		s.cfg.tiling ? tile_layout_name(s.cfg.layout) : "floating",
	)

	if session.kiosk {
		session_kiosk_preset(&s.cfg)
	}
	if !keytable_build(&s.kt, p.host_keymap(app), host_layout()) {
		fmt.eprintfln("wm: no usable keymap; nested clients will have no keyboard")
	}
	if !make_keymap_fd(s, s.kt.text) {
		fmt.eprintfln("wm: could not publish the keymap; nested clients will have no keyboard")
	}

	wltouch_probe(s)
	if e := server_start(s, display); e != "" {
		fmt.eprintfln("wm: %s", e)
		os.exit(1)
	}
	defer server_stop(s)
	fmt.printfln("wm: listening on %s  (WAYLAND_DISPLAY=%s)", s.path, s.display_name)
	fmt.printfln("wm: keymap from %s, %d keysyms in the reverse table", s.kt.source, len(s.kt.rev))

	// Autostart runs only what the configuration asked for, and the default
	// configuration asks for nothing.
	if !session.kiosk {
		ws_autostart(s)
	}
	session_spawn_execs(s)

	deadline := seconds > 0 ? wall_now() + f64(seconds) : 0
	for cv in p.direct_frames(app) {
		if deadline > 0 && wall_now() > deadline {
			p.quit_app(app)
		}
		session_reap()
		if session_should_end() {
			p.quit_app(app)
		}
		s.out_w, s.out_h = cv.w, cv.h
		ws_sync_host(s, cv.w, cv.h)
		server_poll(s)
		data_pump(s)
		handle_keys(s, app)
		handle_pointer(s, app, cv.scale)

		// Live reload: one stat a second, which is cheap enough to leave on
		// and the difference between editing the config and restarting.
		if now := wall_now(); now - s.cfg_check_at > 1.0 {
			s.cfg_check_at = now
			if cfg_changed(&s.cfg) {
				wm_reload(s)
			}
		}

		ws_tick(s)
		draw(s, app, cv)
		send_frames(s)
		flush_all(s)
	}

	for c in s.clients {
		client_flush(c)
	}
	fmt.println("wm: stopped")
}
