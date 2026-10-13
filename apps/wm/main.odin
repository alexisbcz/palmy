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

// Drag is what the pointer is doing to a window while a button is held.
// `Armed` is a press on a title bar that has not travelled far enough to be
// a move yet (UX.md P0-1): a click must never re-tile anything, so nothing
// changes until the pointer has moved. `Split` drags the boundary between
// tiled columns or snapped neighbours.
Drag :: enum u8 {
	None,
	Move,
	Resize,
	Armed,
	Split,
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
	toast:        string,
	toast_at:     f64,
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

	cursor_client_gone(c)
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

// place_new_window decides where a window first appears (UX.md P0-13): on
// the output under the pointer; centred when it is the first window of a
// floating workspace, otherwise cascaded 32 px down-right from the last one
// placed, wrapping before it reaches an edge; never under the bar, never off
// the screen. A window larger than the work area is shrunk to it — and asked
// to be that size — rather than centred off its edges.
place_new_window :: proc(s: ^Server, t: ^Toplevel) {
	ws_ensure(s)
	sane_size(s, t)
	s.cur_out = ws_output_at(s, s_pointer.x, s_pointer.y)
	ws_apply_rules(s, t)
	m := ws_win(t)

	oi := s.cur_out
	if r, ok := rule_output(s, t); ok {
		oi = r
	}
	wa := ws_work_area(s, oi)
	th := ws_title_h(t)
	bw := ws_border(t)

	// Shrink to the work area first: everything after this can assume the
	// frame fits.
	maxw := wa.w - 2 * bw
	maxh := wa.h - th - bw
	if t.req_w > maxw || t.req_h > maxh {
		nw := max(min(t.req_w, maxw), t.min_w)
		nh := max(min(t.req_h, maxh), t.min_h)
		t.req_w, t.req_h = nw, nh
		if ws_alive(s, t) {
			send_configure(s, t, nw, nh)
		}
	}
	fw := t.req_w + 2 * bw
	fh := t.req_h + th + bw

	placement := s.cfg.placement
	switch m.placement_rule {
	case 1:
		placement = .Center
	case 2:
		placement = .Pointer
	}
	first := true
	for o in s.stack {
		if o != t && o.mapped && !o.minimized && ws_floating_now(s, o) {
			first = false
			break
		}
	}
	fx, fy: int
	switch {
	case placement == .Center || (placement == .Cascade && first):
		fx = wa.x + (wa.w - fw) / 2
		fy = wa.y + (wa.h - fh) / 2
		s.cascade_at = {fx, fy}
	case placement == .Pointer:
		fx = s_pointer.x - fw / 2
		fy = s_pointer.y - th / 2
	case:
		step := 32
		fx = s.cascade_at.x + step
		fy = s.cascade_at.y + step
		// Wrap before any edge, back to the top-left of the work area, so a
		// tenth window does not end up half off the screen.
		if s.cascade_at == {} || fx + fw > wa.x + wa.w || fy + fh > wa.y + wa.h || fx < wa.x || fy < wa.y {
			s.place_n += 1
			fx = wa.x + 48 + (s.place_n % 4) * 24
			fy = wa.y + 32 + (s.place_n % 4) * 16
		}
		s.cascade_at = {fx, fy}
	}
	fx = clamp(fx, wa.x, max(wa.x, wa.x + wa.w - fw))
	fy = clamp(fy, wa.y, max(wa.y, wa.y + wa.h - fh))
	t.x = fx + bw
	t.y = fy + th
	s.needs_layout = true
}

// ws_floating_now says whether a window is placed by hand rather than by the
// layout, on the workspace the user is looking at.
ws_floating_now :: proc(s: ^Server, t: ^Toplevel) -> bool {
	return !ws_in_layout(s, t)
}

clamp_window :: proc(s: ^Server, t: ^Toplevel) {
	oi := ws_output_at(s, t.x + t.w / 2, t.y)
	ox, oy, ow, oh := ws_output_rect(s, oi)
	t.x = min(t.x, ox + ow - 60)
	t.x = max(t.x, ox + 60 - t.w)
	t.y = max(t.y, oy + ws_bar_h(s) + ws_title_h(t))
	t.y = min(t.y, oy + oh - 40)
}

// raise_window moves a window to the top of its stacking band (ws_layer):
// a tiled window rises above the other tiled ones but stays under every
// floating window, and nothing rises above an always-on-top one.
raise_window :: proc(s: ^Server, t: ^Toplevel) {
	for w, i in s.stack {
		if w != t {
			continue
		}
		ordered_remove(&s.stack, i)
		band := ws_layer(s, t)
		pos := len(s.stack)
		for other, j in s.stack {
			if ws_layer(s, other) > band {
				pos = j
				break
			}
		}
		inject_at(&s.stack, pos, t)
		s.dirty = true
		return
	}
}

// lower_window sends a window to the bottom of its band (middle-click on a
// title bar, UX.md P0-3).
lower_window :: proc(s: ^Server, t: ^Toplevel) {
	for w, i in s.stack {
		if w != t {
			continue
		}
		ordered_remove(&s.stack, i)
		band := ws_layer(s, t)
		pos := 0
		for other, j in s.stack {
			if ws_layer(s, other) >= band {
				pos = j
				break
			}
			pos = j + 1
		}
		inject_at(&s.stack, pos, t)
		s.dirty = true
		if s.focus == t {
			// Lowering the focused window hands focus to what is now on top,
			// or the window would keep the keyboard from under the others.
			if top := topmost_other(s, nil); top != nil && top != t {
				focus_window(s, top)
			}
		}
		return
	}
}

focus_mru: u64

focus_window :: proc(s: ^Server, t: ^Toplevel) {
	if t != nil {
		if t.minimized {
			t.minimized = false
			anim_restore(s, t)
			s.needs_layout = true
		}
		raise_window(s, t)
		m := ws_win(t)
		focus_mru += 1
		m.mru = focus_mru
		m.urgent = false
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

// map_focus is the focus decision for a window that has just mapped
// (UX.md P0-13, `focus_new`). A window the user did not just ask for, that
// maps while they are typing, opens behind the focused one with its taskbar
// entry marked instead of taking the rest of their sentence.
map_focus :: proc(s: ^Server, t: ^Toplevel) {
	m := ws_win(t)
	take := true
	switch s.cfg.focus_new {
	case .Always:
		take = true
	case .Never:
		take = s.focus == nil
	case .Smart:
		now := wall_now()
		launched := now - ix.launch_at < 2.0
		typing := now - ix.typed_at < 1.0
		take = s.focus == nil || launched || !typing
	}
	if m.no_focus {
		take = false
	}
	if take {
		focus_window(s, t)
		// A new tiled window under floating ones is shown through them, so
		// the window that just took the keyboard is never invisible.
		ix_reveal(s, t)
		return
	}
	// Behind the focused window: just under it in the same band, so it is
	// on screen but does not cover what the user is working in.
	m.urgent = true
	if f := s.focus; f != nil {
		raise_window(s, t)
		for w, i in s.stack {
			if w == t {
				ordered_remove(&s.stack, i)
				break
			}
		}
		for w, i in s.stack {
			if w == f {
				inject_at(&s.stack, i, t)
				break
			}
		}
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
	if t.mapped && ws_on_current(s, t) && !t.minimized {
		anim_close(s, t)
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
	ix_forget(s, t)
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
		focus_window(s, mru_next(s, t))
	}
	ix_note_reflow(s)
	s.needs_layout = true
	s.dirty = true
}

// mru_next is the window focus falls back to when the focused one goes
// away: the one used most recently, which is what the user was in before.
mru_next :: proc(s: ^Server, skip: ^Toplevel) -> ^Toplevel {
	best: ^Toplevel
	best_mru: u64
	for t in s.stack {
		if t == skip || !t.mapped || t.minimized {
			continue
		}
		m := ws_win(t)
		if best == nil || m.mru > best_mru {
			best, best_mru = t, m.mru
		}
	}
	if best == nil {
		return topmost_other(s, skip)
	}
	return best
}

// minimize_window hides a window to the taskbar, from any entry point (the
// button, Super+N, Super+Down, the window menu, the taskbar, the client).
minimize_window :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil || t.minimized {
		return
	}
	anim_minimize(s, t)
	t.minimized = true
	if s.drag_t == t {
		ws_cancel_drag(s)
	}
	if s.focus == t {
		focus_window(s, mru_next(s, t))
	}
	ix_note_reflow(s)
	s.needs_layout = true
	s.dirty = true
	note(s, fmt.tprintf("minimised %s", title_of(t)))
}

close_window :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		toast(s, "nothing to close")
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
	ix_reveal(s, live[next])
	note(s, fmt.tprintf("focus %s", title_of(live[next])))
}

// begin_move is xdg_toplevel.move: the client asked for an interactive move
// on a press it received, so the move starts at once, with no travel
// threshold. A maximized, snapped or tiled window is restored under the
// pointer first (P0-4).
begin_move :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	focus_window(s, t)
	ix_begin_drag(s, t, .Move, {})
	ix_start_move(s, t)
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
	focus_window(s, t)
	ws_float_for_drag(s, t)
	ix_begin_drag(s, t, .Resize, e)
}

// note records what the window manager just did. It is a log line and the
// debug HUD's last line, not a toast: most actions have a visible result,
// and announcing each one in the bar was noise (UX.md 1.22).
note :: proc(s: ^Server, msg: string) {
	delete(s.status)
	s.status = strings.clone(msg)
	s.status_at = wall_now()
	log_line("note: %s", msg)
}

// toast is for the few actions with no other visible result (a reload,
// "nothing to close", a command that is not installed): a small card under
// the bar for two seconds.
toast :: proc(s: ^Server, msg: string) {
	note(s, msg)
	delete(s.toast)
	s.toast = strings.clone(msg)
	s.toast_at = wall_now()
	s.dirty = true
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
		ix.launch_at = wall_now()
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
		toggle_maximize(s, s.focus)
	case .Minimize:
		minimize_window(s, s.focus)
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
	case .Move_To_Workspace_Follow:
		if t := s.focus; t != nil {
			ws_move_to(s, t, b.arg - 1)
			ws_switch(s, b.arg - 1)
			if ws_on_current(s, t) {
				focus_window(s, t)
			}
		}
	case .Move_To_Workspace_Rel:
		ws_move_rel(s, s.focus, b.arg)
	case .Cascade:
		cascade_all(s)
		note(s, "re-cascaded every window")
	case .Window_Mode:
		s.wm_mode = !s.wm_mode
		toast(s, s.wm_mode ? "window mode: arrows move, PgUp/PgDn resize, Esc leaves" : "window mode off")
	case .Reload:
		wm_reload(s)
	case .Quit:
		p.quit_app(app)
	case .Snap_Dir:
		snap_keyboard(s, Cfg_Dir(b.arg))
	case .Toggle_Fullscreen:
		toggle_fullscreen(s, s.focus)
	case .Toggle_On_Top:
		toggle_on_top(s, s.focus)
	case .Toggle_Sticky:
		toggle_sticky(s, s.focus)
	case .Lower:
		if s.focus != nil {
			lower_window(s, s.focus)
		}
	case .Switcher:
		switcher_open(s, b)
	case .Overview:
		overview_toggle(s)
	case .Cheat_Sheet:
		cheat_open(s)
	case .Window_Menu:
		if t := s.focus; t != nil {
			tr := title_rect(t)
			menu_open_window(s, t, int(tr.x) + 4, int(tr.y + tr.h))
			// Opened from the keyboard, so the keyboard starts on an item.
			menu.hover = 0
		}
	case .Debug_Hud:
		s.cfg.debug_hud = !s.cfg.debug_hud
		s.dirty = true
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
		toast(s, fmt.tprintf("%s: logged, not executed", name))
	}
}

// toggle_on_top pins a window above every ordinary one (P1-4).
toggle_on_top :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	m := ws_win(t)
	m.on_top = !m.on_top
	ws_restack(s)
	raise_window(s, t)
	note(s, fmt.tprintf("%s %s", title_of(t), m.on_top ? "always on top" : "no longer on top"))
}

// toggle_sticky shows a window on every workspace: it travels with each
// switch (ws_switch carries it over).
toggle_sticky :: proc(s: ^Server, t: ^Toplevel) {
	if t == nil {
		return
	}
	m := ws_win(t)
	m.sticky = !m.sticky
	if m.sticky && ws_in_layout(s, t) {
		// A window on every workspace cannot hold a cell in each layout.
		m.floating = true
		s.needs_layout = true
	}
	s.dirty = true
	note(s, fmt.tprintf("%s %s", title_of(t), m.sticky ? "on all workspaces" : "on this workspace only"))
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
		toast(s, fmt.tprintf("no %s — built-in defaults", s.cfg.path))
	case len(s.cfg.errors) > 0:
		toast(s, fmt.tprintf("config reloaded, %d problem(s)", len(s.cfg.errors)))
	case:
		toast(s, "config reloaded")
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
		toast(s, fmt.tprintf("%s is not installed", argv_in[0]))
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
		toast(s, fmt.tprintf("could not launch %s: %v", argv_in[0], perr))
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
		cursor_nested(s, app)
		send_frames(s)
		flush_all(s)
	}

	for c in s.clients {
		client_flush(c)
	}
	fmt.println("wm: stopped")
}
