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
	stack:        [dynamic]^Toplevel, // bottom to top
	focus:        ^Toplevel,
	ptr_surf:     ^Surface,
	kbd_surf:     ^Surface,
	selection:    ^Data_Source,
	dirty:        bool,

	out_w, out_h: int,
	repeat_rate:  int,
	repeat_delay: int,
	mod_mask:     u32,
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

place_new_window :: proc(s: ^Server, t: ^Toplevel) {
	avail_h := s.out_h - BAR_H
	if t.w >= s.out_w - 40 || t.h >= avail_h - TITLE_H - 40 {
		// Something nearly screen sized: centre it and let it be.
		t.x = max(0, (s.out_w - t.w) / 2)
		t.y = max(BAR_H + TITLE_H, (s.out_h - t.h) / 2)
	} else {
		step := s.place_n % 6
		t.x = 56 + step * 44
		t.y = BAR_H + TITLE_H + 24 + step * 38
		s.place_n += 1
	}
	clamp_window(s, t)
}

clamp_window :: proc(s: ^Server, t: ^Toplevel) {
	t.x = min(t.x, s.out_w - 60)
	t.x = max(t.x, 60 - t.w)
	t.y = max(t.y, BAR_H + TITLE_H)
	t.y = min(t.y, s.out_h - 40)
}

raise_window :: proc(s: ^Server, t: ^Toplevel) {
	for w, i in s.stack {
		if w == t {
			ordered_remove(&s.stack, i)
			append(&s.stack, t)
			s.dirty = true
			return
		}
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

	if old := s.focus; old != nil && !old.client.dead {
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
	if old := s.kbd_surf; old != nil && !old.client.dead {
		for k in old.client.keyboards {
			event(old.client, k, 2, next_serial(s), old.id)
		}
	}
	s.kbd_surf = surf
	if surf != nil && !surf.client.dead {
		empty: []u8
		for k in surf.client.keyboards {
			event(surf.client, k, 1, next_serial(s), surf.id, empty)
			event(surf.client, k, 4, next_serial(s), s.mod_mask, u32(0), u32(0), u32(0))
		}
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

unmap_window :: proc(s: ^Server, t: ^Toplevel) {
	was := false
	for w, i in s.stack {
		if w == t {
			ordered_remove(&s.stack, i)
			was = true
			break
		}
	}
	t.mapped = false
	if s.drag_t == t {
		s.drag = .None
		s.drag_t = nil
	}
	if s.hover_t == t {
		s.hover_t = nil
	}
	if s.focus == t {
		s.focus = nil
		if t.xdg != nil && s.kbd_surf == t.xdg.surf {
			s.kbd_surf = nil
		}
		focus_window(s, topmost_other(s, t))
	}
	_ = was
	s.dirty = true
}

set_maximized :: proc(s: ^Server, t: ^Toplevel, on: bool) {
	if on == t.maximized {
		return
	}
	if on {
		t.saved = {t.x, t.y, t.req_w, t.req_h}
		t.maximized = true
		w := s.out_w - 2 * BORDER
		h := s.out_h - BAR_H - TITLE_H - BORDER
		t.req_w, t.req_h = w, h
		t.x, t.y = BORDER, BAR_H + TITLE_H
		t.anchor_x, t.anchor_y = false, false
		send_configure(s, t, w, h)
	} else {
		t.maximized = false
		t.x, t.y = t.saved[0], t.saved[1]
		t.req_w, t.req_h = t.saved[2], t.saved[3]
		send_configure(s, t, t.req_w, t.req_h)
	}
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

title_rect :: proc(t: ^Toplevel) -> p.Rect {
	return {f32(t.x - BORDER), f32(t.y - TITLE_H), f32(t.w + 2 * BORDER), f32(TITLE_H)}
}

frame_rect :: proc(t: ^Toplevel) -> p.Rect {
	return {
		f32(t.x - BORDER),
		f32(t.y - TITLE_H),
		f32(t.w + 2 * BORDER),
		f32(t.h + TITLE_H + BORDER),
	}
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
	if old := s.ptr_surf; old != nil && !old.client.dead {
		for ptr in old.client.pointers {
			event(old.client, ptr, 1, next_serial(s), old.id)
			event(old.client, ptr, 5)
		}
	}
	s.ptr_surf = surf
	if surf != nil && !surf.client.dead {
		for ptr in surf.client.pointers {
			event(surf.client, ptr, 0, next_serial(s), surf.id, fixed(f32(lx)), fixed(f32(ly)))
			event(surf.client, ptr, 5)
		}
	}
}

ptr_motion :: proc(s: ^Server, lx, ly: int) {
	surf := s.ptr_surf
	if surf == nil || surf.client.dead {
		return
	}
	for ptr in surf.client.pointers {
		event(surf.client, ptr, 2, now_ms(), fixed(f32(lx)), fixed(f32(ly)))
		event(surf.client, ptr, 5)
	}
}

ptr_button :: proc(s: ^Server, btn: u32, pressed: bool) {
	surf := s.ptr_surf
	if surf == nil || surf.client.dead {
		return
	}
	for ptr in surf.client.pointers {
		event(surf.client, ptr, 3, next_serial(s), now_ms(), btn, pressed ? u32(1) : u32(0))
		event(surf.client, ptr, 5)
	}
}

ptr_axis :: proc(s: ^Server, dx, dy: f32) {
	surf := s.ptr_surf
	if surf == nil || surf.client.dead {
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

	if !in_.over_surface {
		set_ptr_focus(s, nil, 0, 0)
		s.hover_t = nil
		s.hover_btn = 0
		return
	}

	// An in-progress drag owns the pointer.
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
		if in_.released[.Left] {
			if t.resizing {
				t.resizing = false
				send_configure(s, t, t.req_w, t.req_h)
			}
			s.drag = .None
			s.drag_t = nil
		}
		s.dirty = true
		return
	}

	t, region, edges := window_at(s, mp.x, mp.y)
	s.hover_t = t
	s.hover_btn = 0
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

	if in_.pressed[.Left] {
		switch region {
		case .Title:
			begin_move(s, t)
			note(s, fmt.tprintf("moving %s", title_of(t)))
		case .Edge:
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

send_mods :: proc(s: ^Server, mask: u32) {
	if mask == s.mod_mask {
		return
	}
	s.mod_mask = mask
	surf := s.kbd_surf
	if surf == nil || surf.client.dead {
		return
	}
	for k in surf.client.keyboards {
		event(surf.client, k, 4, next_serial(s), mask, u32(0), u32(0), u32(0))
	}
}

// forward_key turns a host keysym back into a keycode in the keymap we handed
// our clients, and sends press and release.
forward_key :: proc(s: ^Server, k: p.Key_Event) {
	surf := s.kbd_surf
	if surf == nil || surf.client.dead {
		return
	}
	rev, ok := keycode_for(&s.kt, k.sym)
	if !ok {
		return
	}
	send_mods(s, mods_mask(s, k.mods, rev.shift))
	t := now_ms()
	for kb in surf.client.keyboards {
		event(surf.client, kb, 3, next_serial(s), t, rev.code, u32(1))
		event(surf.client, kb, 3, next_serial(s), t + 1, rev.code, u32(0))
	}
}

SPAWN := [?]struct {
	sym:  u32,
	argv: []string,
	name: string,
}{
	{p.KEY_F1, {"/home/alex/Work/palmy/bin/counter"}, "counter"},
	{p.KEY_F2, {"/home/alex/Work/palmy/bin/gallery"}, "gallery"},
	{p.KEY_F3, {"/home/alex/Work/palmy/bin/todo"}, "todo"},
	{p.KEY_F4, {"/usr/bin/foot"}, "foot"},
	{p.KEY_F5, {"/home/alex/Work/palmy/bin/pixels"}, "pixels"},
}

KEY_F6 :: 0xffc3
KEY_F7 :: 0xffc4
KEY_F8 :: 0xffc5
KEY_F10 :: 0xffc7
KEY_F12 :: 0xffc9
KEY_PRIOR :: 0xff55
KEY_NEXT :: 0xff56

handle_keys :: proc(s: ^Server, app: ^p.App) {
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

// wm_shortcut handles the compositor's own bindings. It returns true when the
// key was consumed and must not reach the focused client.
//
// Everything has an unmodified function-key path as well as the conventional
// Alt-modified one, because the demo recorder can only synthesize bare keys.
wm_shortcut :: proc(s: ^Server, app: ^p.App, k: p.Key_Event) -> bool {
	alt := .Alt in k.mods
	ctrl := .Ctrl in k.mods
	shift := .Shift in k.mods

	if alt && ctrl && (k.sym == 'q' || k.sym == 'Q') {
		p.quit_app(app)
		return true
	}

	for sp in SPAWN {
		if k.sym == sp.sym || (alt && k.sym == u32('1' + rune_index(sp.sym))) {
			spawn(s, sp.argv)
			note(s, fmt.tprintf("launched %s", sp.name))
			return true
		}
	}

	switch k.sym {
	case KEY_F6:
		cycle_focus(s, false)
		return true
	case KEY_F7:
		cycle_focus(s, true)
		return true
	case KEY_F8:
		close_window(s, s.focus)
		return true
	case KEY_F10:
		s.wm_mode = !s.wm_mode
		note(s, s.wm_mode ? "window mode: arrows move, PgUp/PgDn resize" : "window mode off")
		return true
	case p.KEY_F11:
		if s.focus != nil {
			set_maximized(s, s.focus, !s.focus.maximized)
			note(s, s.focus.maximized ? "maximised" : "restored")
		}
		return true
	case KEY_F12:
		cascade_all(s)
		note(s, "re-cascaded every window")
		return true
	}

	if alt {
		switch k.sym {
		case p.KEY_TAB:
			cycle_focus(s, shift)
			return true
		case 'q', 'Q':
			close_window(s, s.focus)
			return true
		case 'm', 'M':
			if s.focus != nil {
				set_maximized(s, s.focus, !s.focus.maximized)
			}
			return true
		case p.KEY_LEFT, p.KEY_RIGHT, p.KEY_UP, p.KEY_DOWN:
			nudge(s, k.sym, shift)
			return true
		}
	}

	if s.wm_mode {
		switch k.sym {
		case p.KEY_LEFT, p.KEY_RIGHT, p.KEY_UP, p.KEY_DOWN:
			nudge(s, k.sym, false)
			return true
		case KEY_PRIOR:
			grow(s, 48)
			return true
		case KEY_NEXT:
			grow(s, -48)
			return true
		case p.KEY_ESCAPE:
			s.wm_mode = false
			note(s, "window mode off")
			return true
		}
	}
	return false
}

rune_index :: proc(sym: u32) -> rune {
	switch sym {
	case p.KEY_F1:
		return 0
	case p.KEY_F2:
		return 1
	case p.KEY_F3:
		return 2
	case p.KEY_F4:
		return 3
	case p.KEY_F5:
		return 4
	}
	return 9
}

nudge :: proc(s: ^Server, sym: u32, resize: bool) {
	t := s.focus
	if t == nil {
		return
	}
	step := 36
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
	resize_to(s, t, t.req_w + by, t.req_h + by * 3 / 4)
}

resize_to :: proc(s: ^Server, t: ^Toplevel, w, h: int) {
	nw := clamp(w, max(MIN_W, t.min_w), s.out_w)
	nh := clamp(h, max(MIN_H, t.min_h), s.out_h - BAR_H - TITLE_H)
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
	n := 0
	for t in s.stack {
		if !t.mapped {
			continue
		}
		t.minimized = false
		t.x = 56 + (n % 6) * 44
		t.y = BAR_H + TITLE_H + 24 + (n % 6) * 38
		clamp_window(s, t)
		n += 1
	}
	s.dirty = true
}

spawn :: proc(s: ^Server, argv: []string) {
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
	_, perr := os.process_start(
		{command = argv, env = env[:], stdout = os.stderr, stderr = os.stderr},
	)
	if perr != nil {
		note(s, fmt.tprintf("could not launch %s: %v", argv[0], perr))
	}
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
	for y := BAR_H + 16; y < h; y += 32 {
		for x := 16; x < w; x += 32 {
			p.blend(&bc, x, y, p.hex(0x2a3550), 0.5)
		}
	}
	// A soft glow behind the middle, so the desktop is not perfectly flat.
	p.drop_shadow(&bc, {f32(w) / 2 - 240, f32(h) / 2 - 150, 480, 300}, {180, 180, 180, 180}, 320, 0, {0, 0}, p.hexa(0x4338ca22))
}

draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	fonts := &app.fonts

	p.reset_clip(cv)
	build_desktop(s, cv.w, cv.h)
	copy(cv.px[:cv.w * cv.h], s.bg)

	draw_bar(s, app, cv)

	for t in s.stack {
		if !t.mapped || t.minimized {
			continue
		}
		draw_window(s, app, cv, t)
	}

	if len(s.stack) == 0 {
		draw_welcome(s, app, cv)
	}

	// Minimised windows get a small dock at the bottom.
	draw_dock(s, app, cv)
	_ = fonts
}

draw_bar :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	f := &app.fonts
	W := f32(cv.w)
	p.fill_rect(cv, {0, 0, W, BAR_H}, p.hex(BAR_BG))
	p.fill_rect(cv, {0, BAR_H - 1, W, 1}, p.hex(0x27272a))

	p.fill_round_rect(cv, {12, 10, 14, 14}, {4, 4, 4, 4}, p.hex(ACCENT))
	x := f32(34)
	x += p.draw_text(cv, f, "palmy wm", x, 22, 13, p.hex(TEXT_ON), .Sans, .Semibold)
	x += 10
	mapped := 0
	for t in s.stack {
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
		22,
		12,
		p.hex(TEXT_OFF),
	)

	if s.wm_mode {
		lbl := "WINDOW MODE"
		w := p.text_width(f, lbl, 11, .Sans, .Semibold) + 16
		p.fill_round_rect(cv, {x + 14, 8, w, 18}, {5, 5, 5, 5}, p.hex(ACCENT))
		p.draw_text(cv, f, lbl, x + 22, 21, 11, p.hex(0xffffff), .Sans, .Semibold)
		x += w + 18
	}

	// The key legend sits on the right; a transient status note replaces it so
	// the two never collide.
	hint := "F1 counter  F2 gallery  F3 todo  F4 foot  F5 pixels   F6/F7 focus  F8 close  F10 window mode  F11 max  F12 cascade"
	if s.status != "" && wall_now() - s.status_at < 3.0 {
		tw := p.text_width(f, s.status, 12, .Sans, .Medium)
		p.fill_round_rect(cv, {W - tw - 26, 7, tw + 20, 20}, {6, 6, 6, 6}, p.hex(0x1e1b4b))
		p.draw_text(cv, f, s.status, W - tw - 16, 21, 12, p.hex(0xc7d2fe), .Sans, .Medium)
	} else {
		hw := p.text_width(f, hint, 11)
		p.draw_text(cv, f, hint, W - hw - 12, 22, 11, p.hex(0x6b6b76))
	}
}

draw_welcome :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	f := &app.fonts
	cx := f32(cv.w) / 2
	cy := f32(cv.h) / 2
	lines := [?]struct {
		text: string,
		size: f32,
		wt:   p.Font_Weight,
		col:  u32,
	} {
		{"A Wayland compositor, nested", 26, .Bold, 0xe8e8ef},
		{fmt.tprintf("listening on %s", s.path), 13, .Regular, 0x8b8b93},
		{"press F1 to run a palmy app inside it, F4 for a terminal", 14, .Medium, 0xa5b4fc},
	}
	y := cy - 40
	for l in lines {
		w := p.text_width(f, l.text, l.size, .Sans, l.wt)
		p.draw_text(cv, f, l.text, cx - w / 2, y, l.size, p.hex(l.col), .Sans, l.wt)
		y += l.size + 18
	}
}

draw_dock :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	f := &app.fonts
	n := 0
	for t in s.stack {
		if t.mapped && t.minimized {n += 1}
	}
	if n == 0 {
		return
	}
	x := f32(16)
	y := f32(cv.h) - 38
	for t in s.stack {
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
	f := &app.fonts
	focused := s.focus == t
	fr := frame_rect(t)
	rad := p.Radius{9, 9, 0, 0}

	ring_shadow(
		cv,
		fr,
		{9, 9, 3, 3},
		focused ? 26 : 14,
		focused ? 2 : 0,
		{0, focused ? 10 : 5},
		p.hexa(focused ? 0x00000099 : 0x00000066),
	)

	// Frame plate. Only the title bar and the one pixel surround are painted:
	// the client's own pixels cover everything inside.
	plate := p.hex(focused ? FRAME_ON : FRAME_OFF)
	p.fill_round_rect(cv, {fr.x, fr.y, fr.w, TITLE_H + 10}, rad, plate)
	p.fill_rect(cv, {fr.x, f32(t.y), BORDER, f32(t.h) + BORDER}, plate)
	p.fill_rect(cv, {f32(t.x + t.w), f32(t.y), BORDER, f32(t.h) + BORDER}, plate)
	p.fill_rect(cv, {fr.x, f32(t.y + t.h), fr.w, BORDER}, plate)

	// Client pixels.
	cr := content_rect(t)
	p.push_clip(cv, cr)
	if t.xdg != nil && t.xdg.surf != nil {
		blit_surface(cv, t.xdg.surf, t.x, t.y)
	}
	p.pop_clip(cv)

	// Title.
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
	p.stroke_round_rect(cv, fr, {9, 9, 3, 3}, 1, p.hex(focused ? EDGE_ON : EDGE_OFF))
	if focused {
		p.stroke_round_rect(cv, p.rect_inset(fr, -1.5), {10, 10, 4, 4}, 1, p.hexa(0x6366f166))
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
	args := os.args[1:]
	for a, i in args {
		// `--shots <dir>` renders the compositor's output offscreen and writes
		// PNGs. No surface is opened and no socket is bound; the clients in
		// the picture are fabricated. See shot.odin.
		if a == "--shots" {
			os.exit(shots(i + 1 < len(args) ? args[i + 1] : "shots"))
		}
	}
	for a in args {
		switch {
		case a == "-v" || a == "--verbose":
			VERBOSE = true
		case a == "--overlay":
			overlay = true
		case strings.has_prefix(a, "--display="):
			display = a[len("--display="):]
		case strings.has_prefix(a, "--seconds="):
			seconds = atoi(a[len("--seconds="):])
		}
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

	if !keytable_build(&s.kt, p.host_keymap(app), host_layout()) {
		fmt.eprintfln("wm: no usable keymap; nested clients will have no keyboard")
	}
	if !make_keymap_fd(s, s.kt.text) {
		fmt.eprintfln("wm: could not publish the keymap; nested clients will have no keyboard")
	}

	if e := server_start(s, display); e != "" {
		fmt.eprintfln("wm: %s", e)
		os.exit(1)
	}
	defer server_stop(s)
	fmt.printfln("wm: listening on %s  (WAYLAND_DISPLAY=%s)", s.path, s.display_name)
	fmt.printfln("wm: keymap from %s, %d keysyms in the reverse table", s.kt.source, len(s.kt.rev))

	deadline := seconds > 0 ? wall_now() + f64(seconds) : 0
	for cv in p.direct_frames(app) {
		if deadline > 0 && wall_now() > deadline {
			p.quit_app(app)
		}
		s.out_w, s.out_h = cv.w, cv.h
		server_poll(s)
		handle_keys(s, app)
		handle_pointer(s, app, cv.scale)
		draw(s, app, cv)
		send_frames(s)
		flush_all(s)
	}

	for c in s.clients {
		client_flush(c)
	}
	fmt.println("wm: stopped")
}
