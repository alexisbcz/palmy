// The window: start the engine for this profile, then run the frame loop.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import kit "kit:."
import pb "pb"
import p "palmy:."
import sc "shadcn:."

control_path :: proc(identity: string, allocator := context.temp_allocator) -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	return fmt.aprintf("%s/palm-browser-%s.ctl", dir, identity, allocator = allocator)
}

// remote_send asks a running window of this identity to do something. It
// returns the reply, or ok=false when no window is listening.
remote_send :: proc(identity, line: string) -> (reply: string, ok: bool) {
	fd, cok := pb.connect_unix(control_path(identity))
	if !cok {
		return "", false
	}
	defer linux.close(fd)
	msg := fmt.tprintf("%s\n", line)
	linux.send(fd, transmute([]u8)msg, {.NOSIGNAL})
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	for {
		n, err := linux.recv(fd, chunk[:], {})
		if err != .NONE || n <= 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	return strings.trim_space(string(buf[:])), true
}

@(private = "file")
control_main :: proc(data: rawptr) {
	s := (^State)(data)
	path := control_path(s.prof.identity, context.allocator)
	lfd, ok := pb.listen_unix(path)
	if !ok {
		return
	}
	for !s.quit {
		cfd, err := linux.accept(lfd, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC})
		if err != .NONE {
			continue
		}
		buf: [8192]u8
		n, _ := linux.recv(cfd, buf[:], {})
		line := n > 0 ? strings.trim_space(string(buf[:n])) : ""
		reply := "error"
		switch {
		case strings.has_prefix(line, "open "):
			sync.mutex_lock(&s.rlock)
			append(&s.remote, strings.clone(line[5:]))
			sync.mutex_unlock(&s.rlock)
			if s.app != nil {p.wake(s.app)}
			reply = "ok"
		case line == "tabs":
			sync.mutex_lock(&s.rlock)
			reply = strings.clone(s.snapshot, context.temp_allocator)
			sync.mutex_unlock(&s.rlock)
		case line == "ping":
			reply = "pong"
		}
		linux.send(cfd, transmute([]u8)reply, {.NOSIGNAL})
		linux.close(cfd)
		free_all(context.temp_allocator)
	}
	linux.close(lfd)
}

Gui_Options :: struct {
	identity:   string,
	urls:       []string,
	new_window: bool,
	restarted:  bool,
}

gui_main :: proc(opt: Gui_Options) -> int {
	identity := identity_of(opt.identity)
	if !identity_valid(identity) {
		fmt.eprintfln("browser: %q is not a usable identity name", identity)
		return 2
	}

	// one window per identity owns the control socket; a second start hands
	// its URLs to the first instead of starting another engine
	if opt.restarted {
		for _ in 0 ..< 50 {
			if _, ok := remote_send(identity, "ping"); !ok {break}
			time.sleep(100 * time.Millisecond)
		}
	} else if !opt.new_window {
		if _, ok := remote_send(identity, "ping"); ok {
			for u in opt.urls {
				remote_send(identity, fmt.tprintf("open %s", u))
			}
			if len(opt.urls) == 0 {
				remote_send(identity, "open palm://newtab")
			}
			return 0
		}
	}

	prof, pok := profile_open(identity)
	if !pok {
		return 2
	}
	profile_ensure(&prof)
	settings_save(&prof)

	s := new(State)
	g_state = s
	state_init(s, prof)

	app, err := kit.start(
		{
			title = fmt.tprintf("Browser — %s", identity),
			app_id = "palm.browser",
			width = 1360,
			height = 880,
			min_width = 640,
			min_height = 420,
		},
		s.dark,
	)
	if err != "" {
		fmt.eprintln("browser:", err)
		return 6
	}
	s.app = app
	s.scale = f32(max(app.win.scale, 1))

	s.engine = engine_start(s.engine_kind, &s.prof, app, p.host_keymap(app))
	engine_theme(s.engine, s.dark)
	af_init(s)

	// tabs: the command line's URLs, else the session, else a new tab
	if len(opt.urls) > 0 {
		for u in opt.urls {
			url, _ := resolve_input(u, search_engine(s.prof.settings.search))
			new_tab(s, url)
		}
	} else if s.prof.settings.restore_session && !opt.new_window {
		sess := session_load(profile_path(&s.prof, "session.json"))
		for st, i in sess.tabs {
			t := new_tab(s, st.url, -1, false, true)
			t.title = strings.clone(st.title)
			_ = i
		}
		if len(s.tabs) > 0 {
			activate_tab(s, clamp(sess.active, 0, len(s.tabs) - 1))
		}
	}
	if len(s.tabs) == 0 {
		new_tab(s, PAGE_URLS[.New_Tab])
	}

	ctl := thread.create_and_start_with_data(s, control_main)
	_ = ctl

	last_title := ""
	for ui in p.frames(app) {
		s.window_w = app.win.width
		if sc_ := f32(max(app.win.scale, 1)); sc_ != s.scale {
			s.scale = sc_
			for t in s.tabs {
				if t.has_view {engine_resize(s.engine, t.id, s.page_size.x, s.page_size.y, s.scale)}
			}
		}
		pump_engine(s)
		pump_remote(s)
		handle_input(ui, s)
		frame(ui, s)
		sync_view_size(ui, s)
		update_snapshot(s)

		t := active_tab(s)
		title := t != nil ? fmt.tprintf("%s — Browser (%s)", tab_title(t), s.prof.identity) : "Browser"
		if title != last_title {
			if os.get_env("PALM_BROWSER_VERBOSE", context.temp_allocator) != "" {fmt.eprintfln("title %q %v", title, transmute([]u8)title)}
			p.set_title(app, title)
			delete(last_title)
			last_title = strings.clone(title)
		}
		if t != nil && t.loading {
			p.wake_after(app, 120 * time.Millisecond)
		}
		if s.bookmarks.dirty {
			bookmarks_save(&s.bookmarks)
		}
		if s.quit {
			p.quit_app(app)
		}
	}
	if os.get_env("PALM_BROWSER_VERBOSE", context.temp_allocator) != "" {
		fmt.eprintfln("browser: frame loop ended (close %v, quit %v, fatal %q)", app.win.should_close, s.quit, app.win.conn.fatal)
	}
	state_shutdown(s)
	os.remove(control_path(s.prof.identity))
	if s.restart_wanted {
		args := []string{own_binary(), "--restarted", "--identity", s.prof.identity}
		kit.launch(args)
	}
	p.destroy(app)
	return 0
}

// sync_view_size tells the engine when the page area changed size.
sync_view_size :: proc(ui: ^p.Ctx, s: ^State) {
	t := active_tab(s)
	if t == nil || t.page != .Web {
		return
	}
	r := p.rect_of(ui, s.page_id)
	w, h := int(r.w), int(r.h)
	if w <= 0 || h <= 0 {
		return
	}
	if w != s.page_size.x || h != s.page_size.y {
		s.page_size = {w, h}
		for x in s.tabs {
			if x.has_view {
				engine_resize(s.engine, x.id, w, h, s.scale)
			}
		}
	}
}

@(private = "file")
_unused :: sc.Variant
