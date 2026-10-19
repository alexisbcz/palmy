// bare.odin — the compositor on bare metal, and the session around it.
//
// Nested, main.odin's loop is `for cv in p.direct_frames(app)`: the host
// compositor hands over a canvas, the input it collected, and the pacing. On
// bare metal none of that exists. The canvas is a dumb buffer from drm.odin,
// the input is raw evdev from evdev.odin, the keymap is the one xkbcomp.odin
// compiled, and the pacing is the page-flip event. This file is the loop that
// ties those three to the same `draw`, `handle_keys` and `handle_pointer` the
// nested path runs — one compositor, two front ends.
//
// It is also the session half of the command line, which both front ends
// share: `--exec` spawns clients once the socket listens, `--kiosk` turns the
// desktop into a single fullscreen client (the greeter), and children are
// reaped here rather than left as zombies under a long-lived compositor.
//
// Seat. Palmframe has no logind. When the system bus answers and logind is on
// it, seat.odin brokers the devices (TakeDevice, PauseDevice) exactly as it
// was written to. When it does not, the devices are opened directly: the
// first process to open /dev/dri/card0 is DRM master by the kernel's own
// rule, and /dev/input/event* are root:input 0660, so a user in `video` and
// `input` — which is how palm-login starts a session — needs nothing more.
//
// SAFETY. `--drm` refuses to run inside a graphical session (WAYLAND_DISPLAY
// or DISPLAY set) unless PALMY_WM_DRM_LIVE=1 says otherwise, so typing it into
// a terminal on a live desktop is a no-op and not a stolen display.
package wm

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import kit "kit:."
import p "palmy:."

// ---------------------------------------------------------------------------
// The session: --exec, --kiosk, children
// ---------------------------------------------------------------------------

Session :: struct {
	kiosk:        bool,
	bare:         bool, // the DRM backend is driving the outputs
	execs:        [dynamic][]string,
	// The first --exec client. In kiosk mode the session ends with it, and a
	// pidfd makes its exit wake poll() instead of waiting for the next tick.
	first_pid:    linux.Pid,
	first_pidfd:  linux.Fd,
	first_gone:   bool,
	first_status: u32,
	children:     [dynamic]linux.Pid,
}

session: Session

// A signal only sets this; the loop reads it. SIGTERM is how palm-login ends
// a session, and leaving through the loop is what restores the CRTCs.
//
// SIGHUP is not among them: on bare metal it means "read /etc/palm/keyboard
// again" (keyboard.odin), which is what the installer sends when the user
// picks a layout. palm-login follows its SIGHUP to a finished session with a
// SIGTERM, so a session is still ended the way it always was.
session_stop_signal: i32

session_on_signal :: proc "c" (sig: linux.Signal) {
	session_stop_signal = i32(sig)
}

session_install_signals :: proc() {
	sa := linux.Sig_Action {
		handler = session_on_signal,
	}
	for sig in ([?]linux.Signal{.SIGTERM, .SIGINT}) {
		act := sa
		linux.rt_sigaction(sig, &act, nil)
	}
}

// session_kiosk_preset is what --kiosk does to the configuration, applied
// after every load so a reload cannot bring the desktop back: no bar, no
// frames, no gaps, the monocle layout so the client fills the output, no
// bindings that would let a greeter's user start a terminal, and no autostart.
session_kiosk_preset :: proc(c: ^Cfg) {
	c.bar = false
	c.title_bar = false
	c.border = 0
	c.gaps_in = 0
	c.gaps_out = 0
	c.tiling = true
	c.workspaces = 1
	for l, i in TILE_LAYOUTS {
		if l.name == "monocle" {
			c.layout = i
		}
	}
	clear(&c.binds)
	clear(&c.autostart)
	clear(&c.rules)
}

// session_spawn_execs runs every --exec command. Called once the socket is
// listening, so a client that connects the instant it starts finds it.
session_spawn_execs :: proc(s: ^Server) {
	for argv, i in session.execs {
		pid, ok := spawn(s, argv)
		if !ok {
			fmt.eprintfln("wm: --exec %s: could not start", argv[0])
			if i == 0 {
				// A kiosk whose only client cannot start is an empty screen
				// forever. Exit, and let whoever started us decide.
				session.first_gone = true
				session.first_status = 127 << 8
			}
			continue
		}
		append(&session.children, pid)
		if i == 0 {
			session.first_pid = pid
			if fd, e := linux.pidfd_open(pid, {}); e == .NONE {
				session.first_pidfd = linux.Fd(fd)
			} else {
				session.first_pidfd = -1
			}
		}
	}
}

// session_reap collects every exited child — --exec clients and anything the
// key bindings launched — so a long session does not fill with zombies.
session_reap :: proc() {
	for {
		status: u32
		pid, e := linux.wait4(-1, &status, {.WNOHANG}, nil)
		if e != .NONE || pid <= 0 {
			return
		}
		for c, i in session.children {
			if c == pid {
				unordered_remove(&session.children, i)
				break
			}
		}
		if pid == session.first_pid && session.first_pid > 0 {
			session.first_gone = true
			session.first_status = status
			fmt.printfln("wm: first --exec client (pid %d) exited, status 0x%x", pid, status)
		}
	}
}

// session_should_end is the kiosk rule: the session is the first client.
session_should_end :: proc() -> bool {
	if session_stop_signal != 0 {
		return true
	}
	return session.kiosk && session.first_gone
}

session_exit_code :: proc() -> int {
	if session.kiosk && session.first_gone {
		st := session.first_status
		if st & 0x7f == 0 {
			return int((st >> 8) & 0xff)
		}
		return 128 + int(st & 0x7f)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Picking the backend
// ---------------------------------------------------------------------------

// bare_auto says whether to drive the hardware when no flag chose: nothing to
// nest inside, and a KMS node to drive.
bare_auto :: proc() -> bool {
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
		return false
	}
	if os.get_env("DISPLAY", context.temp_allocator) != "" {
		return false
	}
	return os.exists("/dev/dri/card0")
}

// bare_refuse is the guard in front of everything that touches hardware.
bare_refuse :: proc() -> string {
	if os.get_env("PALMY_WM_DRM_LIVE", context.temp_allocator) == "1" {
		return ""
	}
	for v in ([?]string{"WAYLAND_DISPLAY", "DISPLAY"}) {
		if val := os.get_env(v, context.temp_allocator); val != "" {
			return fmt.tprintf(
				"--drm refused: %s=%s says a graphical session already owns this seat (set PALMY_WM_DRM_LIVE=1 to override on a spare VT)",
				v,
				val,
			)
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// The headless app
//
// draw() takes a `^p.App` for its font table, the fps readout and quit_app;
// handle_keys/handle_pointer read `app.win.input`. None of that needs a host
// window, so on bare metal the App is built by hand, as shot.odin does.
// ---------------------------------------------------------------------------

BARE_FONT_DIRS := [?]string{kit.FONT_DIR, "/usr/share/fonts/palmy", "/usr/share/fonts/geist", "/usr/share/fonts/TTF"}

bare_app :: proc(w, h: int) -> ^p.App {
	app := new(p.App)
	app.win.width, app.win.height, app.win.scale = w, h, 1
	app.win.input.text = strings.builder_make()
	app.win.input.over_surface = true
	app.win.input.focused = true
	app.fps = 60
	p.fonts_init(&app.fonts)
	// Geist where the toolkit expects it, or where the distribution puts it;
	// otherwise fonts_init's scan of /usr/share/fonts already chose a face.
	for dir in BARE_FONT_DIRS {
		if !os.exists(fmt.tprintf("%s/Geist-400.ttf", dir)) {
			continue
		}
		for pair in ([?]struct {
			file: string,
			wt:   p.Font_Weight,
		}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
			p.load_font(&app.fonts, fmt.tprintf("%s/%s", dir, pair.file), .Sans, pair.wt)
		}
		break
	}
	p.set_text_gamma(1.8)
	return app
}

// ---------------------------------------------------------------------------
// The software cursor
//
// There is no host cursor to lean on and no cursor plane in use, so the
// pointer is painted into every frame after everything else. Its shapes, and
// the client cursors drawn in their place, are cursor.odin's.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Keys
//
// The converged path is kept: evdev resolves each key through the compiled
// keymap into a keysym, ev_apply_to_input puts it in `p.Input`, wm_shortcut
// gets first refusal, and forward_key finds the keycode again through the
// reverse table built from the same keymap. What bare metal adds is that the
// modifiers sent to clients come from the real xkb state, held keys included.
// ---------------------------------------------------------------------------

bare_mono_ms :: proc() -> u32 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return u32(u64(ts.time_sec) * 1000 + u64(ts.time_nsec) / 1_000_000)
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Damage
//
// draw() paints the whole desktop. On bare metal it now paints only the part
// that changed, and only that part is written to the scanout buffer:
//
//   - The scene lives in ordinary memory (`bare_out.scene`, the whole layout,
//     without the cursor). Drawing reads what it blends over; reading a dumb
//     buffer, which on real hardware is write-combined video memory, is the
//     slowest thing a CPU compositor can do, so it is never read.
//   - Each frame's damage is one rectangle in layout space. Everything that
//     can change the picture either adds a rectangle (a client commit over
//     where that surface was last drawn, the pointer over a client) or asks
//     for everything (damage_all: anything the compositor itself draws
//     differently — a binding, a click, a title, an animation, a timer). When
//     unsure, everything; and everything at least once a second, so nothing
//     time-driven (the clock, a toast) can go stale.
//   - draw() runs with every clip it sets intersected with the damage
//     (wm_reset_clip), so pixels outside it are neither computed nor written.
//   - The cursor is not in the scene. It is laid over the scene just before
//     the copy and taken off again afterwards, so moving it over a client
//     costs two small rectangles and no draw() at all.
//   - Each head has three buffers, so the one being drawn into last saw a
//     frame two or three frames ago. A short history of damage rectangles
//     tells how much of it to bring up to date (the "buffer age" scheme).
//   - The no-flip path passes the rectangle to DIRTYFB, so a virtual GPU
//     copies only it to the host.
// ---------------------------------------------------------------------------

DMG_HISTORY :: 8

Bare_Out :: struct {
	scene:         []u32, // the whole layout, without the cursor
	cw, ch:        int,
	last_frame_ns: i64,
	heads:         int,
	full:          bool, // the next frame repaints everything
	dmg:           [4]int, // the damage so far (x, y, w, h); w == 0: none
	seq:           u64, // frames composed
	draws:         u64, // draw() calls (a cursor-only frame has none)
	hist:          [DMG_HISTORY][4]int, // hist[seq % N]: what frame seq changed
	cursor:        [4]int, // where the cursor was laid over the last frame
	cursor_dirty:  bool, // its image changed (a client cursor commit, a shape)
	last_full_ns:  i64,
	// The clip draw() works inside this frame; wm_reset_clip resets to it.
	base_clip:     p.Rect,
	clipping:      bool,
	// For the stats line (PALMY_WM_DRM_DEBUG): per period.
	st_frames:     int,
	st_full:       int,
	st_draw_px:    u64,
	st_copy_px:    u64,
	st_draw_ns:    i64,
	st_at:         i64,
	st_cpu_ns:     i64,
	st_commits:    int, // client commits that became damage, and their area
	st_commit_px:  u64,
	st_cursor:     int, // frames that only moved the cursor
}

bare_out: Bare_Out

// damage_all asks for the next frame to repaint every pixel.
damage_all :: proc(loc := #caller_location) {
	bare_out.full = true
	if bare_debug {
		// Which call sites ask for full repaints, for the stats line.
		key := fmt.tprintf("%s:%d", loc.file_path[strings.last_index_byte(loc.file_path, '/') + 1:], loc.line)
		if key not_in bare_why {
			key = strings.clone(key)
		}
		bare_why[key] += 1
	}
}

bare_why: map[string]int

// damage_add adds a rectangle, in layout pixels, to the next frame's damage.
damage_add :: proc(r: [4]int) {
	if r[2] <= 0 || r[3] <= 0 {
		return
	}
	bare_out.dmg = rect4_union(bare_out.dmg, r)
}

rect4_union :: proc(a, b: [4]int) -> [4]int {
	if a[2] <= 0 || a[3] <= 0 {
		return b
	}
	if b[2] <= 0 || b[3] <= 0 {
		return a
	}
	x0 := min(a[0], b[0])
	y0 := min(a[1], b[1])
	x1 := max(a[0] + a[2], b[0] + b[2])
	y1 := max(a[1] + a[3], b[1] + b[3])
	return {x0, y0, x1 - x0, y1 - y0}
}

rect4_clip :: proc(a: [4]int, w, h: int) -> [4]int {
	x0 := clamp(a[0], 0, w)
	y0 := clamp(a[1], 0, h)
	x1 := clamp(a[0] + a[2], 0, w)
	y1 := clamp(a[1] + a[3], 0, h)
	if x1 <= x0 || y1 <= y0 {
		return {}
	}
	return {x0, y0, x1 - x0, y1 - y0}
}

// wm_reset_clip is p.reset_clip for the compositor's own drawing: back to the
// whole canvas, or to this frame's damage when only that is being repainted.
wm_reset_clip :: proc(cv: ^p.Canvas) {
	p.reset_clip(cv)
	if bare_out.clipping {
		cv.clip = p.rect_intersect(cv.clip, bare_out.base_clip)
	}
}

// damage_commit is a client's commit, seen from the screen: the part of the
// surface that changed, where the surface was drawn last frame. A surface
// that was not on screen last frame (just mapped, or hidden), or whose size
// changed, can move other things, so that is everything.
damage_commit :: proc(s: ^Server, surf: ^Surface) {
	if !session.bare {
		return
	}
	if surf.cursor_seq != 0 && surf.cursor_seq == bare_out.seq {
		// The pointer's own image: it is laid over every frame anyway.
		bare_out.cursor_dirty = true
		return
	}
	w := surf.iw / max(surf.scale, 1)
	h := surf.ih / max(surf.scale, 1)
	// Drawn somewhere other than its place (a thumbnail, a scaled
	// animation), or not drawn last time, or a new size: everything.
	if ov.open || sw.open || anim_busy() || dnd_active() ||
	   surf.shown_draw == 0 || surf.shown_draw != bare_out.draws || w != surf.shown[2] || h != surf.shown[3] {
		damage_all()
		return
	}
	if r, any := surface_damage_bbox(surf); any {
		damage_add({surf.shown[0] + r[0], surf.shown[1] + r[1], r[2], r[3]})
		bare_out.st_commits += 1
		bare_out.st_commit_px += u64(r[2] * r[3])
	}
}

// cursor_rect is where the cursor will be drawn at x, y: its image's box.
cursor_rect :: proc(s: ^Server, x, y: int) -> [4]int {
	shape, cc := cursor_effective(s)
	switch shape {
	case .Hidden:
		return {}
	case .Client:
		if cc != nil && cc.surf != nil && cc.surf.img != nil {
			// The surface and its subsurfaces: give it room.
			sc := max(cc.surf.scale, 1)
			return {x - cc.hot.x - 2, y - cc.hot.y - 2, cc.surf.iw / sc + 4, cc.surf.ih / sc + 4}
		}
	case .Default, .Move, .Grab, .Grabbing, .N, .S, .E, .W, .NE, .NW, .SE, .SW, .EW, .NS, .NESW, .NWSE, .Text, .Pointer, .Not_Allowed, .Wait, .Crosshair:
	}
	return {x - CURSOR_SIZE, y - CURSOR_SIZE, CURSOR_SIZE * 2, CURSOR_SIZE * 2}
}

// bare_frame draws one frame on every head that can take one. Returns true
// when at least one head was presented, or when there was nothing to show
// (so the caller sends frame callbacks either way).
bare_frame :: proc(s: ^Server, app: ^p.App) -> bool {
	heads := drm_heads()
	ready := 0
	for h in heads {
		if drm_head_ready(h) {
			ready += 1
		}
	}
	if ready == 0 {
		return false
	}
	o := &bare_out
	W, H := s.out_w, s.out_h
	if o.cw != W || o.ch != H || len(o.scene) != W * H {
		delete(o.scene)
		o.scene = make([]u32, W * H)
		o.cw, o.ch = W, H
		o.full = true
	}
	now := bare_mono_ns()
	if now - o.last_full_ns >= 1_000_000_000 || bare_no_damage {
		o.full = true
	}
	cx, cy := int(ev_pointer[0]), int(ev_pointer[1])
	cur := rect4_clip(cursor_rect(s, cx, cy), W, H)

	dmg := o.full ? [4]int{0, 0, W, H} : rect4_clip(o.dmg, W, H)
	moved := cur != o.cursor || o.cursor_dirty
	if dmg[2] == 0 && !moved {
		// Nothing on screen changed: no draw, no copy, no flip.
		o.dmg = {}
		return true
	}

	o.seq += 1
	comp := p.canvas_from(o.scene, W, H)
	defer p.canvas_destroy(&comp)
	if dmg[2] == 0 {
		o.st_cursor += 1
	}
	if dmg[2] > 0 {
		t0 := bare_mono_ns()
		o.clipping = !o.full
		o.base_clip = {f32(dmg[0]), f32(dmg[1]), f32(dmg[2]), f32(dmg[3])}
		wm_reset_clip(&comp)
		o.draws += 1
		draw(s, app, &comp)
		o.clipping = false
		o.st_draw_ns += bare_mono_ns() - t0
		o.st_draw_px += u64(dmg[2] * dmg[3])
		if o.full {
			o.st_full += 1
			o.last_full_ns = now
		}
	}
	// What this frame changed on screen, the cursor's old and new boxes
	// included, for this head and for the buffers that see it later.
	changed := dmg
	if moved || dmg[2] > 0 {
		changed = rect4_union(changed, rect4_union(o.cursor, cur))
	}
	o.hist[o.seq % DMG_HISTORY] = o.full ? [4]int{0, 0, W, H} : changed
	o.full = false
	o.dmg = {}
	o.cursor = cur
	o.cursor_dirty = false

	// Lay the cursor over the scene, keeping what it covers.
	under: [dynamic]u32
	under.allocator = context.temp_allocator
	if cur[2] > 0 {
		resize(&under, cur[2] * cur[3])
		for y in 0 ..< cur[3] {
			copy(under[y * cur[2]:][:cur[2]], o.scene[(cur[1] + y) * W + cur[0]:][:cur[2]])
		}
		comp.clip = {0, 0, f32(W), f32(H)}
		cursor_draw(s, &comp, cx, cy)
		cursor_mark_shown(s)
	}

	shown := false
	for h in heads {
		if !drm_head_ready(h) {
			continue
		}
		fb := drm_back_fb(h)
		if fb == nil {
			continue
		}
		// Everything since this buffer last saw a frame.
		region: [4]int
		age := o.seq - fb.seq
		if fb.seq == 0 || age >= DMG_HISTORY {
			region = {h.x, h.y, fb.w, fb.h}
		} else {
			for k := fb.seq + 1; k <= o.seq; k += 1 {
				region = rect4_union(region, o.hist[k % DMG_HISTORY])
			}
		}
		// Into head coordinates, clipped to the head and to the layout.
		region = rect4_clip(region, W, H)
		local := rect4_clip({region[0] - h.x, region[1] - h.y, region[2], region[3]}, min(fb.w, W - h.x), min(fb.h, H - h.y))
		if local[2] > 0 {
			for y in 0 ..< local[3] {
				sy := h.y + local[1] + y
				copy(fb.px[(local[1] + y) * fb.stride_px + local[0]:][:local[2]], o.scene[sy * W + h.x + local[0]:][:local[2]])
			}
			o.st_copy_px += u64(local[2] * local[3])
		}
		fb.seq = o.seq
		if local[2] == 0 {
			// This head shows nothing that changed. Its buffer is current
			// as of this frame; no flip needed.
			continue
		}
		if drm_present_clip(h, local, false) {
			shown = true
		}
	}
	o.st_frames += 1

	if cur[2] > 0 {
		for y in 0 ..< cur[3] {
			copy(o.scene[(cur[1] + y) * W + cur[0]:][:cur[2]], under[y * cur[2]:][:cur[2]])
		}
	}
	return true
}

// bare_stats prints, every few seconds with PALMY_WM_DRM_DEBUG, what the
// compositor cost: CPU time, frames, how many of them were full repaints, and
// the pixels drawn and copied. This is how the damage tracking is measured.
bare_stats :: proc() {
	o := &bare_out
	now := bare_mono_ns()
	if o.st_at == 0 {
		o.st_at = now
		o.st_cpu_ns = bare_cpu_ns()
		return
	}
	if now - o.st_at < 5_000_000_000 {
		return
	}
	cpu := bare_cpu_ns()
	wall := f64(now - o.st_at) / 1e9
	fmt.printfln(
		"wm: stats: %.1fs cpu %.1f%% frames %d (full %d, cursor-only %d) draw %.1f ms, %d kpx drawn, %d kpx copied, %d dirtyfb, %d commits %d kpx",
		wall, f64(cpu - o.st_cpu_ns) / 1e7 / wall, o.st_frames, o.st_full, o.st_cursor,
		f64(o.st_draw_ns) / 1e6, o.st_draw_px / 1000, o.st_copy_px / 1000, drm_state.dirty_calls,
		o.st_commits, o.st_commit_px / 1000,
	)
	o.st_commits, o.st_commit_px, o.st_cursor = 0, 0, 0
	if len(bare_why) > 0 {
		b := strings.builder_make(context.temp_allocator)
		for k, v in bare_why {
			fmt.sbprintf(&b, " %s=%d", k, v)
		}
		fmt.printfln("wm: stats: full repaints asked by%s", strings.to_string(b))
		clear(&bare_why)
	}
	o.st_at, o.st_cpu_ns = now, cpu
	o.st_frames, o.st_full, o.st_draw_ns, o.st_draw_px, o.st_copy_px = 0, 0, 0, 0, 0
	drm_state.dirty_calls = 0
}

bare_cpu_ns :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.PROCESS_CPUTIME_ID)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

bare_mono_ns :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

// bare_pace_wait_ms is how long until the next frame may be drawn. The page
// flip is supposed to be the frame clock, but a virtual GPU has no vblank to
// wait for: virtio-gpu completes a flip as soon as the host has the pixels,
// and a client that redraws on every frame callback would then spin the
// compositor at hundreds of frames a second. So frames are also spaced by the
// fastest head's refresh period, which on real hardware the flip already
// enforces and on a virtual one is the only thing that does.
bare_pace_wait_ms :: proc() -> int {
	period := i64(1_000_000_000 / 60)
	for h in drm_heads() {
		if h.refresh_ns > 0 {
			period = min(period, h.refresh_ns)
		}
	}
	due := bare_out.last_frame_ns + period
	left := due - bare_mono_ns()
	if left <= 0 {
		return 0
	}
	return int((left + 999_999) / 1_000_000)
}

// bare_outputs gives the workspace layer one output per head, named after
// the connector, so each head has its own bar, its own workspace and its own
// tiling area. The output that stood in for the nested host window becomes
// the first head; a head that goes away is disabled, which moves its
// workspaces to a survivor (ws_output_disable).
bare_outputs :: proc(s: ^Server) {
	heads := drm_heads()
	if len(heads) == 0 {
		return
	}
	ws_ensure(s)
	for &o in s.outputs {
		if o.host {
			h := heads[0]
			delete(o.name)
			o.name = strings.clone(h.name)
			o.host = false
			s.needs_layout = true
		}
	}
	for h in heads {
		ws_output_upsert(s, h.name, h.x, h.y, int(h.mode.hdisplay), int(h.mode.vdisplay), 1)
	}
	for o in s.outputs {
		if !o.enabled {
			continue
		}
		present := false
		for h in heads {
			if h.name == o.name {
				present = true
			}
		}
		if !present {
			fmt.printfln("wm: output %s gone", o.name)
			ws_output_disable(s, o.name)
		}
	}
}

// bare_layout re-reads the head layout into the compositor's notion of the
// output. The workspace and layer code know one host-sized output; with one
// head that is exactly the head, and with several it is their bounding box.
bare_layout :: proc(s: ^Server, app: ^p.App) -> (changed: bool) {
	w, h := drm_layout_extent()
	w, h = max(w, 1), max(h, 1)
	n := len(drm_heads())
	bare_outputs(s)
	if w != s.out_w || h != s.out_h || n != bare_out.heads {
		s.out_w, s.out_h = w, h
		bare_out.heads = n
		app.win.width, app.win.height = w, h
		s.dirty = true
		changed = true
		fmt.printfln("wm: layout now %dx%d over %d head(s)", w, h, n)
	}
	ev_screen = {f64(w), f64(h)}
	return
}

bare_debug: bool
// PALMY_WM_DAMAGE=off repaints and copies everything every frame, which is
// what wm did before damage tracking; it is there to measure the difference.
bare_no_damage: bool

// bare_pointer is handle_pointer plus the damage question. The pointer moving
// over a client's content, with nothing of the compositor's open, changes
// only the cursor and what the client then commits; anything else (a click,
// a hover over a frame button or the bar, a drag, an overlay) may change
// what the compositor draws, so it repaints.
bare_pointer :: proc(s: ^Server, app: ^p.App) {
	in_ := &app.win.input
	@(static) last_mouse: [2]f32
	moved := in_.mouse != last_mouse
	last_mouse = in_.mouse
	buttons := false
	for b in p.Mouse_Button {
		if in_.pressed[b] || in_.released[b] {
			buttons = true
		}
	}
	scrolled := in_.scroll != {}
	// With several heads, a click on another head makes the workspace it
	// shows the current one, so the next window opens where the user is.
	if buttons && len(s.outputs) > 1 && !ov.open && !sw.open && !menu.open {
		mp := [2]int{int(in_.mouse.x), int(in_.mouse.y)}
		oi := ws_output_at(s, mp.x, mp.y)
		if oi >= 0 && oi < len(s.outputs) && s.outputs[oi].enabled {
			if act := s.outputs[oi].active; act != s.cur_ws && act >= 0 && act < len(s.workspaces) && s.workspaces[act].output == oi {
				ws_switch(s, act)
				damage_all()
			}
		}
	}
	before := s.ptr_surf
	hover_t, hover_btn, drag, dirty, focus := s.hover_t, s.hover_btn, s.drag, s.dirty, s.kbd_surf
	handle_pointer(s, app, 1)
	if !moved && !buttons && !scrolled {
		return
	}
	quiet := !buttons && before != nil && s.ptr_surf == before && s.drag == .None && drag == .None &&
		s.hover_t == hover_t && s.hover_btn == hover_btn && s.kbd_surf == focus &&
		!menu.open && !sw.open && !ov.open && !cheat.open && !dnd_active() && !anim_busy()
	if quiet {
		// handle_pointer marks every motion dirty; this one is not.
		s.dirty = dirty
	} else {
		damage_all()
	}
}

// bare_main runs the compositor on the hardware until the session ends.
bare_main :: proc(display, conf: string) -> int {
	if why := bare_refuse(); why != "" {
		fmt.eprintfln("wm: %s", why)
		return 2
	}
	session.bare = true
	bare_debug = os.get_env("PALMY_WM_DRM_DEBUG", context.temp_allocator) != ""
	bare_no_damage = os.get_env("PALMY_WM_DAMAGE", context.temp_allocator) == "off"
	session_install_signals()

	// The seat. logind when it is there, the device nodes when it is not.
	via_logind := false
	if seat_open() == .None {
		// --drm is the explicit consent PALMY_WM_SEAT_LIVE stands for.
		seat.live = true
		if seat_take_control() == .None {
			seat_bind_backends()
			via_logind = true
		} else {
			seat_close()
		}
	}
	fmt.printfln("wm: seat: %s", via_logind ? "logind (TakeDevice)" : "direct (no logind; opening /dev/dri and /dev/input ourselves)")

	// The VT, which logind would otherwise look after. Taken before the
	// first modeset so the console never draws over our first frame, and
	// given back after drm_shutdown (defers run in reverse).
	if !via_logind {
		if vt_open() {
			fmt.printfln("wm: vt: tty%d in graphics mode, VT_PROCESS (Ctrl+Alt+F1..F12 switch)", vt.num)
		} else {
			fmt.printfln("wm: vt: none (%s); no VT switching", vt.why)
		}
	}
	defer vt_close()

	drm_enable_live()
	if ok, err := drm_init({verbose = VERBOSE || os.get_env("PALMY_WM_DRM_DEBUG", context.temp_allocator) != "", hotplug = true}); !ok {
		fmt.eprintfln("wm: drm: %s", err)
		return 1
	}
	defer drm_shutdown()
	for h in drm_heads() {
		fmt.printfln(
			"wm: head %s on %s: %dx%d@%d.%03dHz at %d,%d (crtc %d)",
			h.name, h.card.path, h.mode.hdisplay, h.mode.vdisplay,
			drm_mode_refresh_mhz(h.mode) / 1000, drm_mode_refresh_mhz(h.mode) % 1000,
			h.x, h.y, h.crtc_id,
		)
	}

	s := &server
	w, h := drm_layout_extent()
	s.out_w, s.out_h = max(w, 1), max(h, 1)
	bare_out.heads = len(drm_heads())
	app := bare_app(s.out_w, s.out_h)
	s.repeat_rate = ev_cfg.repeat_rate
	s.repeat_delay = ev_cfg.repeat_delay

	if conf != "" {
		s.cfg.path = strings.clone(conf)
	}
	cfg_load(&s.cfg)
	for e in s.cfg.errors {
		fmt.eprintfln("wm: %s", e)
	}
	if session.kiosk {
		session_kiosk_preset(&s.cfg)
	}
	ws_ensure(s)
	bare_outputs(s)

	// The keyboard: /etc/palm/keyboard through our own XKB compiler, our own
	// keymap fd, no libxkbcommon; SIGHUP and changes to the file reload it.
	kbd_start(s)

	opened, found := ev_start()
	ev_screen = {f64(s.out_w), f64(s.out_h)}
	ev_pointer = {f64(s.out_w) / 2, f64(s.out_h) / 2}
	app.win.input.mouse = {f32(ev_pointer[0]), f32(ev_pointer[1])}
	defer ev_stop()
	ev_hotplug_start()
	defer ev_hotplug_stop()
	fmt.printfln("wm: input: %d of %d device(s) opened%s", opened, found, ev_hotplug_fd() >= 0 ? "; watching /dev/input for more" : "")
	for d in ev_devices {
		fmt.printfln("wm:   %s  %s  %v%s", d.path, d.name, d.kinds, d.opened ? "" : "  (could not open)")
	}

	wltouch_probe(s)
	if e := server_start(s, display); e != "" {
		fmt.eprintfln("wm: %s", e)
		return 1
	}
	defer server_stop(s)
	fmt.printfln("wm: listening on %s  (WAYLAND_DISPLAY=%s)", s.path, s.display_name)
	fmt.printfln("wm: keymap from %s, %d keysyms in the reverse table", s.kt.source, len(s.kt.rev))

	if !session.kiosk {
		ws_autostart(s)
	}
	session_spawn_execs(s)

	pfds := make([dynamic]linux.Poll_Fd, 0, 64)
	defer delete(pfds)
	want_frame := true
	frames_at := wall_now()
	frames_n := 0

	for !app.quit && !session_should_end() {
		// Wait for something: a client, a device, a flip, a child, a timer.
		clear(&pfds)
		append(&pfds, linux.Poll_Fd{fd = s.listen, events = {.IN}})
		for c in s.clients {
			if !c.dead {
				append(&pfds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
			}
		}
		dbuf: [16]linux.Poll_Fd
		drm_lo := len(pfds)
		for f in dbuf[:drm_poll_fds(dbuf[:])] {
			append(&pfds, f)
		}
		drm_hi := len(pfds)
		for d in ev_devices {
			if d.opened && !d.paused {
				append(&pfds, linux.Poll_Fd{fd = d.fd, events = {.IN}})
			}
		}
		if session.first_pidfd > 0 && !session.first_gone {
			append(&pfds, linux.Poll_Fd{fd = session.first_pidfd, events = {.IN}})
		}
		if via_logind && seat.conn != nil {
			append(&pfds, linux.Poll_Fd{fd = seat_fd(), events = {.IN}})
		}
		if kfd := kbd_poll_fd(); kfd > 0 {
			append(&pfds, linux.Poll_Fd{fd = kfd, events = {.IN}})
		}
		if hfd := ev_hotplug_fd(); hfd >= 0 {
			append(&pfds, linux.Poll_Fd{fd = hfd, events = {.IN}})
		}
		if vfd := vt_poll_fd(); vfd >= 0 {
			append(&pfds, linux.Poll_Fd{fd = vfd, events = {.IN}})
		}

		// A second is the longest anything waits: the bar's clock, a status
		// note expiring, children reaped. A pending frame with every head
		// idle means do not wait at all; one waiting on a flip waits for the
		// event, but never longer than the stall detector needs.
		timeout := i32(1000)
		timer_wake := true // the timeout, if it expires, is a timer (not pacing)
		awaiting := false
		for hd in drm_heads() {
			if hd.awaiting_flip {
				awaiting = true
			}
		}
		if want_frame {
			timeout = awaiting ? 100 : i32(max(bare_pace_wait_ms(), 0))
			timer_wake = false
		}
		if vt_inactive() {
			// Switched away: nothing to draw until the kernel says we are back.
			want_frame = false
			timeout = 1000
		}
		if rt := ev_next_timeout(bare_mono_ms()); rt >= 0 && i32(rt) < timeout {
			timeout = i32(rt)
			timer_wake = false // key repeat: the compositor's own, not drawn
		}
		// Something on screen changes by itself soon (a tooltip, a snap
		// preview, a toast running out): wake for it rather than a second
		// later. An animation in flight wants every frame.
		if anim_busy() && !vt_inactive() {
			want_frame = true
			timeout = awaiting ? 100 : i32(max(bare_pace_wait_ms(), 0))
			timer_wake = false
		}
		if wm := wake_ms(); wm >= 0 && i32(wm) <= timeout {
			timeout = i32(wm)
			timer_wake = true
			if wm == 0 {
				want_frame = true
			}
		}
		n, _ := linux.poll(pfds[:], timeout)

		// What woke us decides whether the screen is stale. A page-flip
		// completion on its own is not news — it only means a frame that was
		// asked for can now go out — so it does not ask for another, and an
		// idle desktop costs one frame a second rather than sixty.
		activity := n == 0 && timeout > 0
		if anim_busy() {
			activity = true
			damage_all()
		}
		if n == 0 && timeout > 0 && timer_wake {
			// A timer: the clock, a tooltip, a toast running out.
			damage_all()
		}
		for f, i in pfds {
			if f.revents != {} && (i < drm_lo || i >= drm_hi) {
				activity = true
			}
		}
		if activity {
			want_frame = true
		}

		// Devices first, so this frame's input is this frame's. Then the
		// keyboard layout: a reload or a group switch has to be in place
		// before those keys are handed on.
		if vt_pump(s) {
			want_frame = true
		}
		for d in ev_devices {
			if d.opened && !d.paused {
				ev_read_once(d)
			}
		}
		if ev_reap_gone() {
			want_frame = true
		}
		if ev_hotplug_pump() {
			want_frame = true
		}
		kbd_pump(s)
		// drm_dispatch says "redraw" for a flip completion as well as for a
		// hotplug; only the second changes what should be on screen, and
		// treating the first as news is a sixty-frames-a-second idle loop.
		drm_dispatch()
		if bare_layout(s, app) {
			want_frame = true
			damage_all()
		}
		if via_logind {
			seat_pump()
		}
		session_reap()

		server_poll(s)
		data_pump(s)
		ev_tick(bare_mono_ms())
		if len(ev_queue) > 0 {
			want_frame = true
		}
		ev_apply_to_input(&app.win.input)
		handle_keys(s, app)
		if kbd_wire.took {
			// The compositor acted on a key: anything may have changed.
			kbd_wire.took = false
			damage_all()
		}
		bare_pointer(s, app)

		if now := wall_now(); now - s.cfg_check_at > 1.0 {
			s.cfg_check_at = now
			if cfg_changed(&s.cfg) {
				wm_reload(s, quiet = true)
			}
			want_frame = true
		}
		ws_tick(s)
		state_publish(s)
		// Every place that changes what the compositor draws says so with
		// s.dirty; on bare metal that is a full repaint. Commits and the
		// pointer over a client have already added their own, smaller damage.
		if s.dirty {
			s.dirty = false
			damage_all()
		}
		if bare_debug {
			bare_stats()
		}

		// The flip paces how many frames go out; bare_frame decides how
		// much of each is drawn.
		if want_frame && !vt_inactive() && bare_pace_wait_ms() <= 0 && bare_frame(s, app) {
			bare_out.last_frame_ns = bare_mono_ns()
			want_frame = false
			frames_n += 1
			send_frames(s)
		}
		flush_all(s)

		if now := wall_now(); now - frames_at >= 1.0 {
			app.fps = f32(f64(frames_n) / (now - frames_at))
			frames_at, frames_n = now, 0
		}
		free_all(context.temp_allocator)
	}

	if session_stop_signal != 0 {
		fmt.printfln("wm: signal %d, stopping", session_stop_signal)
	}
	for c in s.clients {
		client_flush(c)
	}
	if via_logind {
		seat_unbind_backends()
		seat_release_control()
		seat_close()
	}
	fmt.println("wm: stopped")
	return session_exit_code()
}
