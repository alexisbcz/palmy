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

Bare_Out :: struct {
	composite:     []u32, // the whole layout, when there is more than one head
	cw, ch:        int,
	last_frame_ns: i64,
	heads:         int,
	full:          bool, // the next frame repaints everything
}

bare_out: Bare_Out

// damage_all asks for the next frame to repaint every pixel.
damage_all :: proc() {
	bare_out.full = true
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

// bare_layout re-reads the head layout into the compositor's notion of the
// output. The workspace and layer code know one host-sized output; with one
// head that is exactly the head, and with several it is their bounding box.
bare_layout :: proc(s: ^Server, app: ^p.App) -> (changed: bool) {
	w, h := drm_layout_extent()
	w, h = max(w, 1), max(h, 1)
	n := len(drm_heads())
	if w != s.out_w || h != s.out_h || n != bare_out.heads {
		s.out_w, s.out_h = w, h
		bare_out.heads = n
		app.win.width, app.win.height = w, h
		ws_sync_host(s, w, h)
		s.dirty = true
		changed = true
		fmt.printfln("wm: layout now %dx%d over %d head(s)", w, h, n)
	}
	ev_screen = {f64(w), f64(h)}
	return
}

// bare_frame draws one frame on every head that can take one. Returns true
// when at least one head was presented.
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
	cx, cy := int(ev_pointer[0]), int(ev_pointer[1])

	single := len(heads) == 1 && heads[0].x == 0 && heads[0].y == 0
	if single {
		h := heads[0]
		cv := drm_begin_frame(h)
		if cv == nil {
			return false
		}
		draw(s, app, cv)
		cursor_draw(s, cv, cx, cy)
		return drm_present(h)
	}

	// Several heads: composite the whole layout once, then copy each head's
	// rectangle into its own buffer. draw() thinks in one coordinate space and
	// stays that way.
	if bare_out.cw != s.out_w || bare_out.ch != s.out_h {
		delete(bare_out.composite)
		bare_out.composite = make([]u32, s.out_w * s.out_h)
		bare_out.cw, bare_out.ch = s.out_w, s.out_h
	}
	comp := p.canvas_from(bare_out.composite, bare_out.cw, bare_out.ch)
	defer p.canvas_destroy(&comp)
	draw(s, app, &comp)
	cursor_draw(s, &comp, cx, cy)
	shown := false
	for h in heads {
		if !drm_head_ready(h) {
			continue
		}
		cv := drm_begin_frame(h)
		if cv == nil {
			continue
		}
		for y in 0 ..< cv.h {
			sy := h.y + y
			if sy >= comp.h {
				break
			}
			n := min(cv.w, comp.w - h.x)
			if n <= 0 {
				break
			}
			copy(cv.px[y * cv.w:][:n], comp.px[sy * comp.w + h.x:][:n])
		}
		if drm_present(h) {
			shown = true
		}
	}
	return shown
}

// bare_main runs the compositor on the hardware until the session ends.
bare_main :: proc(display, conf: string) -> int {
	if why := bare_refuse(); why != "" {
		fmt.eprintfln("wm: %s", why)
		return 2
	}
	session.bare = true
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
	ws_sync_host(s, s.out_w, s.out_h)

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
		awaiting := false
		for hd in drm_heads() {
			if hd.awaiting_flip {
				awaiting = true
			}
		}
		if want_frame {
			timeout = awaiting ? 100 : i32(max(bare_pace_wait_ms(), 0))
		}
		if vt_inactive() {
			// Switched away: nothing to draw until the kernel says we are back.
			want_frame = false
			timeout = 1000
		}
		if rt := ev_next_timeout(bare_mono_ms()); rt >= 0 {
			timeout = min(timeout, i32(rt))
		}
		// Something on screen changes by itself soon (a tooltip, a snap
		// preview, a toast running out): wake for it rather than a second
		// later. An animation in flight wants every frame.
		if anim_busy() && !vt_inactive() {
			want_frame = true
			timeout = awaiting ? 100 : i32(max(bare_pace_wait_ms(), 0))
		}
		if wm := wake_ms(); wm >= 0 {
			timeout = min(timeout, i32(wm))
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
		handle_pointer(s, app, 1)

		if now := wall_now(); now - s.cfg_check_at > 1.0 {
			s.cfg_check_at = now
			if cfg_changed(&s.cfg) {
				wm_reload(s)
			}
			want_frame = true
		}
		ws_tick(s)

		// Anything that woke us may have changed what is on screen — a
		// commit, a motion, a title — and draw() repaints everything anyway,
		// so there is no finer question to ask. The flip paces how many go out.
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
