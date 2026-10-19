// Compositing: Firefox's surfaces into the view's pixels, and the pixels to
// the chrome.
//
// Every commit copies the client's buffer into the surface's own image, so
// compositing never races the client. The view's picture is kept whole in
// `backing`; damaged rectangles are recomposed there, bottom to top
// (toplevel, its subsurfaces, then popups with theirs), and copied into the
// shared buffer the chrome maps -- with the same one-frame-in-flight rule as
// the CEF host, and the same FRAME/FRAME_ACK messages.
package gecko

import "core:sys/linux"
import pb "browser:pb"

Global :: struct {
	w, h:            int, // view size, logical
	scale:           int,
	serial:          u32,
	toplevel:        ^Xdg_Surface,
	toplevel_mapped: bool,
	popups:          [dynamic]^Xdg_Surface,
	need_compose:    bool,
	damage:          [dynamic]Rect, // device pixels
	backing:         []u32,
	bw, bh:          int,
	shm:             []u32,
	shm_fd:          linux.Fd,
	sw, sh:          int,
	inflight:        bool,
	frames_sent:     int,
	view:            int, // the chrome's view that is showing now
	pointer_focus:   ^Surface,
	kbd_focus:       ^Surface,
	chrome:          ^pb.Conn,
	focused:         bool,
	last_cb:         i64,
	cb_waiting:      bool, // callbacks are owed once FRAME_MS has passed
	start_ms:        i64,
}

g: Global

damage_all :: proc() {
	clear(&g.damage)
	append(&g.damage, Rect{0, 0, g.w * g.scale, g.h * g.scale})
	g.need_compose = true
}

add_damage :: proc(r: Rect) {
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, g.w * g.scale)
	y1 := min(r.y + r.h, g.h * g.scale)
	if x1 <= x0 || y1 <= y0 {
		return
	}
	nr := Rect{x0, y0, x1 - x0, y1 - y0}
	if len(g.damage) >= 16 {
		u := g.damage[0]
		for d in g.damage[1:] {
			u = union_rect(u, d)
		}
		clear(&g.damage)
		append(&g.damage, union_rect(u, nr))
		return
	}
	append(&g.damage, nr)
}

union_rect :: proc(a, b: Rect) -> Rect {
	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(a.x + a.w, b.x + b.w)
	y1 := max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

// surface_damage maps damage in a surface's buffer onto the view.
surface_damage :: proc(s: ^Surface, r: Rect) {
	if !surface_visible(s) {
		return
	}
	ox, oy := surface_origin(s)
	sc := g.scale
	add_damage({ox * sc + r.x, oy * sc + r.y, r.w, r.h})
}

surface_visible :: proc(s: ^Surface) -> bool {
	at := s
	for at != nil {
		if !at.mapped || at.destroyed {
			return false
		}
		if at.role == .Subsurface {
			at = at.parent
			continue
		}
		return at.role == .Toplevel || at.role == .Popup
	}
	return false
}

// draw_surface blends one surface and its subsurfaces into the backing,
// clipped to `clip`.
@(private = "file")
draw_tree :: proc(s: ^Surface, clip: Rect) {
	if !s.mapped || s.destroyed || s.img == nil {
		return
	}
	ox, oy := surface_origin(s)
	ox *= g.scale
	oy *= g.scale
	x0 := max(clip.x, ox, 0)
	y0 := max(clip.y, oy, 0)
	x1 := min(clip.x + clip.w, ox + s.w, g.bw)
	y1 := min(clip.y + clip.h, oy + s.h, g.bh)
	for y in y0 ..< y1 {
		src := s.img[(y - oy) * s.w:]
		dst := g.backing[y * g.bw:]
		for x in x0 ..< x1 {
			p := src[x - ox]
			a := p >> 24
			if a == 0xff {
				dst[x] = p
			} else if a != 0 {
				d := dst[x]
				ia := 255 - a
				rb := ((d & 0x00ff00ff) * ia >> 8) & 0x00ff00ff
				gg := ((d & 0x0000ff00) * ia >> 8) & 0x0000ff00
				dst[x] = 0xff000000 | ((p & 0x00ffffff) + rb + gg)
			}
		}
	}
	for ch in s.children {
		draw_tree(ch, clip)
	}
}

compose :: proc() {
	if !g.need_compose {
		return
	}
	g.need_compose = false
	dw, dh := g.w * g.scale, g.h * g.scale
	if dw <= 0 || dh <= 0 {
		return
	}
	if g.bw != dw || g.bh != dh {
		delete(g.backing)
		g.backing = make([]u32, dw * dh)
		g.bw = dw
		g.bh = dh
		damage_all()
	}
	if len(g.damage) == 0 {
		send_frame_callbacks()
		return
	}
	for d in g.damage {
		// the background shows only while Firefox has not drawn yet
		for y in d.y ..< d.y + d.h {
			row := g.backing[y * g.bw:]
			for x in d.x ..< d.x + d.w {
				row[x] = 0xffffffff
			}
		}
		if g.toplevel != nil && g.toplevel.surface != nil {
			draw_tree(g.toplevel.surface, d)
		}
		for p in g.popups {
			if p.surface != nil {
				draw_tree(p.surface, d)
			}
		}
	}
	flush()
}

// flush copies the damaged rows into the shared buffer and tells the chrome,
// unless a frame is still in flight; then the damage waits for the ack.
flush :: proc() {
	if g.chrome == nil || g.view == 0 {
		// nobody to show it to yet: let Firefox keep drawing regardless
		clear(&g.damage)
		send_frame_callbacks()
		return
	}
	if g.inflight || len(g.damage) == 0 || g.backing == nil {
		return
	}
	if g.shm == nil || g.sw != g.bw || g.sh != g.bh {
		if !shm_new() {
			return
		}
	}
	rects := make([dynamic]pb.Rect_I, context.temp_allocator)
	for d in g.damage {
		for y in d.y ..< d.y + d.h {
			copy(g.shm[y * g.sw + d.x:][:d.w], g.backing[y * g.bw + d.x:][:d.w])
		}
		append(&rects, pb.Rect_I{i32(d.x), i32(d.y), i32(d.w), i32(d.h)})
	}
	clear(&g.damage)
	m := pb.ev_frame(g.view, rects[:])
	pb.send(g.chrome, &m)
	g.inflight = true
	g.frames_sent += 1
	send_frame_callbacks()
}

frame_ack :: proc() {
	g.inflight = false
	flush()
	send_frame_callbacks()
}

shm_new :: proc() -> bool {
	if g.shm != nil {
		linux.munmap(raw_data(g.shm), uint(g.sw * g.sh * 4))
		linux.close(g.shm_fd)
		g.shm = nil
	}
	size := g.bw * g.bh * 4
	fd, err := linux.memfd_create("palm-browser-gecko", {.CLOEXEC})
	if err != .NONE {
		return false
	}
	if linux.ftruncate(fd, i64(size)) != .NONE {
		linux.close(fd)
		return false
	}
	ptr, merr := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		linux.close(fd)
		return false
	}
	g.shm = ([^]u32)(ptr)[:size / 4]
	g.shm_fd = fd
	g.sw = g.bw
	g.sh = g.bh
	copy(g.shm, g.backing)
	// the chrome gets its own descriptor; ours stays for remapping
	dup, derr := linux.dup(fd)
	if derr != .NONE {
		return false
	}
	m := pb.ev_buffer(g.view, g.sw, g.sh, g.sw * 4)
	pb.send(g.chrome, &m, dup)
	linux.close(dup)
	clear(&g.damage)
	append(&g.damage, Rect{0, 0, g.bw, g.bh})
	return true
}

// send_frame_callbacks tells Firefox it may draw again. Done once the chrome
// has taken the last frame, which paces Firefox to what the window shows.
// Firefox asks for a frame callback after every commit and drives its
// refresh from them, so answering at once would let it spin as fast as the
// CPU allows. Callbacks are answered at most once per 16 ms -- a 60 Hz
// display -- and not while the chrome still holds the last frame.
FRAME_MS :: 16

frames_due :: proc() -> bool {
	return now_ms() - g.last_cb >= FRAME_MS
}

send_frame_callbacks :: proc() {
	c := g_client
	if c == nil || g.inflight {
		return
	}
	if !frames_due() {
		g.cb_waiting = true
		return
	}
	g.cb_waiting = false
	g.last_cb = now_ms()
	now := u32(now_ms() - g.start_ms)
	cbs := make([dynamic]u32, context.temp_allocator)
	for _, o in c.objects {
		if o.kind != .Surface {
			continue
		}
		s := (^Surface)(o.ptr)
		append(&cbs, ..s.frames[:])
		clear(&s.frames)
	}
	for cb in cbs {
		event(c, cb, 0, now)
		destroyed(c, cb)
	}
}
