// The engine seam.
//
// The chrome knows one thing about whatever renders web pages: `Engine`. It
// has a name, a version, a set of views (one per tab), and it takes requests
// and produces events -- exactly the messages of engine/proto.h. The
// procedures below (engine_navigate, engine_key, ...) are the whole interface
// the rest of the browser uses; nothing outside this file knows there is a
// socket or a process.
//
// There is one transport today, a host process. Both engines use it:
//
//   Chromium  palm-browser-cef     CEF off-screen rendering
//   Firefox   browser --gecko-host Firefox in a private Wayland compositor,
//                                  steered over WebDriver BiDi
//
// An in-process engine (a Servo or NetSurf binding, say) would implement the
// same `transport` and nothing else here would change.
//
// Frames are the only traffic that never touches the UI thread on the way
// in: the reader thread copies damaged rows from the host's shared buffer into
// the view's own pixels under the view's lock, acknowledges at once (so the
// host can paint the next frame while this one is being composited) and wakes
// the window.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import pb "pb"
import p "palmy:."

View_Surface :: struct {
	lock:    sync.Mutex,
	px:      []u32, // device pixels, the chrome's own copy
	w, h:    int,
	stride:  int, // of the shared buffer, in pixels
	shm:     []u32, // the host's buffer, mapped read-only
	shm_len: int,
	frames:  int,
	dirty:   bool,
}

Engine :: struct {
	kind:      Engine_Kind,
	name:      string,
	version:   string,
	host_path: string,
	ok:        bool,
	error:     string,

	conn:      pb.Conn,
	process:   os.Process,
	reader:    ^thread.Thread,
	listen_fd: linux.Fd,
	sock_path: string,

	// filled by the reader thread, drained by the UI thread
	qlock:     sync.Mutex,
	queue:     [dynamic]pb.Event,
	surfaces:  map[int]^View_Surface,
	slock:     sync.Mutex,
	wake:      ^p.App, // nil when headless
	wake_proc: proc(e: ^Engine),
	dead:      bool,
}

// ---------------------------------------------------------------------------
// Finding an engine
// ---------------------------------------------------------------------------

exe_dir :: proc(allocator := context.temp_allocator) -> string {
	buf: [4096]u8
	n, err := linux.readlink("/proc/self/exe", buf[:])
	if err != .NONE || n <= 0 {
		return "."
	}
	s := string(buf[:n])
	if i := strings.last_index_byte(s, '/'); i >= 0 {
		return strings.clone(s[:i], allocator)
	}
	return "."
}

own_binary :: proc() -> string {
	buf: [4096]u8
	n, err := linux.readlink("/proc/self/exe", buf[:])
	if err != .NONE || n <= 0 {
		return "browser"
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Engine_Info describes what is installed, for the settings page and
// `browser engines`.
Engine_Info :: struct {
	kind:      Engine_Kind,
	available: bool,
	host:      string, // the host binary
	runtime:   string, // libcef.so, or the firefox binary
	detail:    string, // why not, when unavailable
}

find_on_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" {
			continue
		}
		cand := fmt.tprintf("%s/%s", dir, name)
		if os.exists(cand) {
			return strings.clone(cand, allocator)
		}
	}
	return ""
}

first_existing :: proc(cands: []string) -> string {
	for c in cands {
		if c != "" && os.exists(c) {
			return c
		}
	}
	return ""
}

engine_info :: proc(k: Engine_Kind) -> Engine_Info {
	info := Engine_Info {
		kind = k,
	}
	dir := exe_dir()
	switch k {
	case .Chromium:
		info.host = first_existing(
			{
				os.get_env("PALM_BROWSER_CEF_HOST", context.temp_allocator),
				fmt.tprintf("%s/cef/palm-browser-cef", dir),
				"/usr/lib/palm-browser/cef/palm-browser-cef",
			},
		)
		if info.host == "" {
			info.detail = "palm-browser-cef is not installed (palm add palm-browser-cef)"
			return info
		}
		lib := fmt.tprintf("%s/libcef.so", info.host[:strings.last_index_byte(info.host, '/')])
		if !os.exists(lib) {
			info.detail = fmt.tprintf("libcef.so is missing next to %s", info.host)
			return info
		}
		info.runtime = strings.clone(lib, context.temp_allocator)
		info.available = true
	case .Firefox:
		// the host is this binary (`browser --gecko-host`); the override
		// exists to run a separately built one while developing it
		info.host = first_existing({os.get_env("PALM_BROWSER_GECKO_HOST", context.temp_allocator), own_binary()})
		info.runtime = first_existing(
			{
				os.get_env("PALM_BROWSER_FIREFOX", context.temp_allocator),
				"/usr/lib/firefox/firefox",
				"/opt/firefox/firefox",
				find_on_path("firefox"),
			},
		)
		if info.runtime == "" {
			info.detail = "Firefox is not installed (palm add firefox)"
			return info
		}
		info.available = true
	}
	return info
}

// ---------------------------------------------------------------------------
// Starting and stopping
// ---------------------------------------------------------------------------

// engine_start launches the host for `kind` against the profile and waits for
// its HELLO. On failure `ok` is false and `error` says why, in a sentence the
// window can show.
engine_start :: proc(kind: Engine_Kind, prof: ^Profile, app: ^p.App, keymap := "") -> ^Engine {
	e := new(Engine)
	e.kind = kind
	e.wake = app
	e.listen_fd = -1
	e.name = engine_name(kind)

	info := engine_info(kind)
	if !info.available {
		e.error = strings.clone(info.detail)
		return e
	}
	e.host_path = strings.clone(info.host)
	profile_ensure(prof)

	runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime_dir == "" || !os.exists(runtime_dir) {
		runtime_dir = "/tmp"
	}
	@(static) counter: int
	counter += 1
	e.sock_path = fmt.aprintf("%s/palm-browser-%d-%d.sock", runtime_dir, os.get_pid(), counter)
	lfd, lok := pb.listen_unix(e.sock_path)
	if !lok {
		e.error = fmt.aprintf("cannot listen on %s", e.sock_path)
		return e
	}
	e.listen_fd = lfd

	engine_dir := prof.dir
	dl := downloads_dir(prof, context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, e.host_path)
	if kind == .Firefox && os.get_env("PALM_BROWSER_GECKO_HOST", context.temp_allocator) == "" {
		append(&args, "--gecko-host")
	}
	append(&args, fmt.tprintf("--socket=%s", e.sock_path))
	append(&args, fmt.tprintf("--profile=%s", engine_dir))
	append(&args, fmt.tprintf("--downloads=%s", dl))
	if kind == .Firefox {
		append(&args, fmt.tprintf("--firefox=%s", info.runtime))
	}
	log_path := profile_path(prof, fmt.tprintf("%s-host.log", e.name))
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc}, os.perm(0o600))
	desc := os.Process_Desc {
		command = args[:],
	}
	if lerr == nil {
		desc.stderr = logf
		desc.stdout = logf
	}
	proc_, perr := os.process_start(desc)
	if lerr == nil {
		os.close(logf)
	}
	if perr != nil {
		e.error = fmt.aprintf("could not start %s: %v", e.host_path, perr)
		return e
	}
	e.process = proc_
	// a host that started but did not come up must not linger: it would hold
	// the profile's lock and the next start would find the profile in use
	defer if !e.ok {
		_ = os.process_kill(e.process)
		_, _ = os.process_wait(e.process, 2 * time.Second)
	}

	// Wait for the host to connect: Chromium's first start on a new profile
	// takes a few seconds; Firefox's longer.
	timeout := kind == .Chromium ? 20 : 40
	n := poll_for(lfd, timeout * 1000)
	if n <= 0 {
		e.error = fmt.aprintf("%s did not connect within %d s (see %s)", e.name, timeout, log_path)
		_ = os.process_kill(e.process)
		return e
	}
	cfd, aerr := linux.accept(lfd, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC})
	if aerr != .NONE {
		e.error = fmt.aprintf("accept failed: %v", aerr)
		return e
	}
	linux.close(lfd)
	e.listen_fd = -1
	os.remove(e.sock_path)
	e.conn.fd = cfd

	// the first message is HELLO
	if poll_for(cfd, timeout * 1000) <= 0 {
		e.error = fmt.aprintf("%s connected but never said hello (see %s)", e.name, log_path)
		return e
	}
	raw, _, ok := pb.recv_one(&e.conn)
	if !ok {
		e.error = fmt.aprintf("%s hung up during start (see %s)", e.name, log_path)
		return e
	}
	ev, dok := pb.decode_event(raw)
	if !dok || ev.op != .Hello {
		e.error = fmt.aprintf("%s spoke an unexpected first message", e.name)
		return e
	}
	e.name = strings.clone(ev.str)
	e.version = strings.clone(ev.str2)
	pb.event_free(&ev)

	hello := pb.req_hello(engine_dir, dl, keymap)
	pb.send(&e.conn, &hello)

	e.ok = true
	e.reader = thread.create_and_start_with_data(e, reader_main)
	return e
}

// poll_for waits until `fd` is readable or the time is up, through signals:
// a child exiting (SIGCHLD) must not read as a timeout.
poll_for :: proc(fd: linux.Fd, ms: int) -> int {
	start := time.tick_now()
	for {
		left := ms - int(time.duration_milliseconds(time.tick_since(start)))
		if left <= 0 {
			return 0
		}
		fds := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, err := linux.poll(fds[:], i32(left))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return -1
		}
		return int(n)
	}
}

engine_stop :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	if e.ok {
		q := pb.req_simple(.Quit, 0)
		pb.send(&e.conn, &q)
		// give the host a moment to close its browsers cleanly
		deadline := time.tick_now()
		for time.tick_since(deadline) < 5 * time.Second {
			state, err := os.process_wait(e.process, 100 * time.Millisecond)
			if err == nil && state.exited {
				break
			}
		}
		_ = os.process_kill(e.process)
		_, _ = os.process_wait(e.process, 500 * time.Millisecond)
		pb.conn_close(&e.conn)
		if e.reader != nil {
			thread.join(e.reader)
			thread.destroy(e.reader)
		}
	}
	if e.listen_fd >= 0 {
		linux.close(e.listen_fd)
	}
	if e.sock_path != "" {
		os.remove(e.sock_path)
	}
}

// ---------------------------------------------------------------------------
// The reader thread
// ---------------------------------------------------------------------------

@(private = "file")
reader_main :: proc(data: rawptr) {
	e := (^Engine)(data)
	for {
		raw, fd, ok := pb.recv_one(&e.conn)
		if !ok {
			break
		}
		ev, dok := pb.decode_event(raw, fd)
		if !dok {
			pb.event_free(&ev)
			continue
		}
		#partial switch ev.op {
		case .Buffer:
			surface_map(e, ev.view, fd, int(ev.w), int(ev.h), int(ev.stride))
			pb.event_free(&ev)
			continue
		case .Frame:
			surface_copy(e, ev.view, ev.rects)
			ack := pb.req_simple(.Frame_Ack, ev.view)
			pb.send(&e.conn, &ack)
			pb.event_free(&ev)
			poke(e)
			continue
		}
		sync.mutex_lock(&e.qlock)
		append(&e.queue, ev)
		sync.mutex_unlock(&e.qlock)
		poke(e)
	}
	sync.mutex_lock(&e.qlock)
	e.dead = true
	sync.mutex_unlock(&e.qlock)
	poke(e)
}

@(private = "file")
poke :: proc(e: ^Engine) {
	if e.wake != nil {
		p.wake(e.wake)
	}
	if e.wake_proc != nil {
		e.wake_proc(e)
	}
}

surface_of :: proc(e: ^Engine, view: int) -> ^View_Surface {
	sync.mutex_lock(&e.slock)
	defer sync.mutex_unlock(&e.slock)
	s, ok := e.surfaces[view]
	if !ok {
		s = new(View_Surface)
		e.surfaces[view] = s
	}
	return s
}

@(private = "file")
surface_map :: proc(e: ^Engine, view: int, fd: int, w, h, stride: int) {
	s := surface_of(e, view)
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if s.shm != nil {
		linux.munmap(raw_data(s.shm), uint(s.shm_len))
		s.shm = nil
	}
	if fd < 0 {
		return
	}
	size := stride * h
	ptr, err := linux.mmap(0, uint(size), {.READ}, {.SHARED}, linux.Fd(fd), 0)
	linux.close(linux.Fd(fd))
	if err != .NONE {
		return
	}
	s.shm = ([^]u32)(ptr)[:size / 4]
	s.shm_len = size
	s.stride = stride / 4
	if s.w != w || s.h != h {
		delete(s.px)
		s.px = make([]u32, w * h)
		s.w = w
		s.h = h
	}
}

@(private = "file")
surface_copy :: proc(e: ^Engine, view: int, rects: []pb.Rect_I) {
	s := surface_of(e, view)
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if s.shm == nil || s.px == nil {
		return
	}
	for r in rects {
		x0 := clamp(int(r.x), 0, s.w)
		y0 := clamp(int(r.y), 0, s.h)
		x1 := clamp(int(r.x + r.w), 0, s.w)
		y1 := clamp(int(r.y + r.h), 0, s.h)
		if x1 <= x0 {
			continue
		}
		for y in y0 ..< y1 {
			copy(s.px[y * s.w + x0:y * s.w + x1], s.shm[y * s.stride + x0:y * s.stride + x1])
		}
	}
	s.frames += 1
	s.dirty = true
}

// engine_drain hands the UI thread every event that has arrived.
engine_drain :: proc(e: ^Engine, out: ^[dynamic]pb.Event) -> (alive: bool) {
	if e == nil || !e.ok {
		return false
	}
	sync.mutex_lock(&e.qlock)
	append(out, ..e.queue[:])
	clear(&e.queue)
	alive = !e.dead
	sync.mutex_unlock(&e.qlock)
	return
}

// ---------------------------------------------------------------------------
// The interface
// ---------------------------------------------------------------------------

@(private = "file")
send :: proc(e: ^Engine, m: pb.Msg) {
	m := m
	if e == nil || !e.ok {
		delete(m.b)
		return
	}
	pb.send(&e.conn, &m)
}

engine_create :: proc(e: ^Engine, view: int, w, h: int, scale: f32, url: string) {
	send(e, pb.req_create(view, w, h, scale, url))
}
engine_close :: proc(e: ^Engine, view: int) {
	send(e, pb.req_simple(.Close, view))
	if e != nil {
		sync.mutex_lock(&e.slock)
		if s, ok := e.surfaces[view]; ok {
			sync.mutex_lock(&s.lock)
			if s.shm != nil {
				linux.munmap(raw_data(s.shm), uint(s.shm_len))
			}
			delete(s.px)
			sync.mutex_unlock(&s.lock)
			free(s)
			delete_key(&e.surfaces, view)
		}
		sync.mutex_unlock(&e.slock)
	}
}
engine_navigate :: proc(e: ^Engine, view: int, url: string) {send(e, pb.req_str(.Navigate, view, url))}
engine_back :: proc(e: ^Engine, view: int) {send(e, pb.req_i32(.History, view, -1))}
engine_forward :: proc(e: ^Engine, view: int) {send(e, pb.req_i32(.History, view, 1))}
engine_reload :: proc(e: ^Engine, view: int, bypass_cache := false) {send(e, pb.req_flag(.Reload, view, bypass_cache))}
engine_stop_loading :: proc(e: ^Engine, view: int) {send(e, pb.req_simple(.Stop, view))}
engine_resize :: proc(e: ^Engine, view: int, w, h: int, scale: f32) {send(e, pb.req_resize(view, w, h, scale))}
engine_show :: proc(e: ^Engine, view: int, visible: bool) {send(e, pb.req_flag(.Show, view, visible))}
engine_focus :: proc(e: ^Engine, view: int, focused: bool) {send(e, pb.req_flag(.Focus, view, focused))}
engine_mouse :: proc(e: ^Engine, view: int, kind: pb.Mouse_Kind, button: pb.Button, clicks: int, mods: u32, x, y: f32) {
	send(e, pb.req_mouse(view, kind, button, clicks, mods, x, y))
}
engine_wheel :: proc(e: ^Engine, view: int, mods: u32, x, y, dx, dy: f32) {send(e, pb.req_wheel(view, mods, x, y, dx, dy))}
engine_key :: proc(e: ^Engine, view: int, kind: pb.Key_Kind, mods: u32, keysym, codepoint: u32) {
	send(e, pb.req_key(view, kind, mods, keysym, codepoint))
}
engine_zoom :: proc(e: ^Engine, view: int, factor: f32) {send(e, pb.req_zoom(view, factor))}
engine_find :: proc(e: ^Engine, view: int, text: string, forward, next: bool) {send(e, pb.req_find(view, text, forward, next))}
engine_dialog_reply :: proc(e: ^Engine, view: int, id: u32, ok: bool, text: string) {
	send(e, pb.req_dialog_reply(view, id, ok, text))
}
engine_menu_reply :: proc(e: ^Engine, view: int, id: u32, command: i32) {send(e, pb.req_menu_reply(view, id, command))}
engine_edit :: proc(e: ^Engine, view: int, action: pb.Edit_Action, text := "") {send(e, pb.req_edit(view, action, text))}
engine_theme :: proc(e: ^Engine, dark: bool) {send(e, pb.req_flag(.Theme, 0, dark))}
engine_download_cancel :: proc(e: ^Engine, id: u32) {send(e, pb.req_u32(.Download_Cancel, 0, id))}
