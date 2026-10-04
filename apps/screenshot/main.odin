package main

// A screenshot tool for Wayland, drawn by palmy's software rasterizer.
//
// It drives `grim` and `slurp`, decodes the PNG that comes back through
// palmy's own image support, and shows the real capture in the window. That
// last part is the whole point: a screenshot tool that cannot show you what it
// just took is a button, not a tool.
//
// Nothing here is destructive. A capture lands in /tmp first; saving copies it
// into ~/Pictures, and the originals are removed when the window closes.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

HEADER_H :: 88
FOOTER_H :: 46
SIDE_W :: 336

Delay_Choices := [?]int{0, 3, 5, 10}

Phase :: enum {
	Idle,
	Counting, // the delay is running
	Working, // grim or slurp is in flight
	Decoding,
}

Shot :: struct {
	path:   string, // where it lives in /tmp
	saved:  string, // where it was copied to, "" until saved
	mode:   Mode,
	out:    string, // the output name, for a per-output capture
	w, h:   int,
	bytes:  i64,
	when_:  string, // wall clock, for the list
	copied: bool,
}

MAX_SHOTS :: 12

Model :: struct {
	outputs:      []Output,
	out_at:       int,
	mode:         Mode,
	delay_at:     int,

	phase:        Phase,
	count_until:  f64,
	status:       string,

	shots:        [MAX_SHOTS]Shot,
	n_shots:      int,
	sel:          int, // index into shots, -1 for none
	seq:          int,

	// The decoded image for the selection. Exactly one is held at a time: a
	// 1920x1080 RGBA frame is 8 MB, and twelve of them is not a preview, it is
	// a memory leak with a nice border.
	img:          p.Image,
	img_ok:       bool,
	img_for:      int, // which shot `img` belongs to
	zoom:         f32,

	have_grim:    bool,
	have_slurp:   bool,
	have_wlcopy:  bool,

	log_open:     bool,
	help_open:    bool,

	toast:        [192]u8,
	toast_len:    int,
	toast_until:  f64,
	toast_bad:    bool,
}

g_now: f64

main :: proc() {
	app, err := start_window()
	if err != "" {
		fmt.eprintfln("screenshot: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	m := new(Model)
	m.sel = -1
	m.img_for = -1
	m.zoom = 1
	m.mode = .Screen
	m.outputs = read_outputs()
	m.have_grim = have("grim")
	m.have_slurp = have("slurp")
	m.have_wlcopy = have("wl-copy")
	// A machine with one output has nothing to choose between, so the mode is
	// not offered as if it did.
	if len(m.outputs) > 1 {
		for o, i in m.outputs {
			if o.focused {
				m.out_at = i
			}
		}
	}
	defer cleanup(m)

	for ui in p.frames(app) {
		g_now = f64(p.elapsed(ui))

		// This window has nothing to animate while it is idle, so it only asks
		// for frames when a countdown is running or a command is in flight.
		// An idle screenshot tool should cost nothing at all.
		if m.phase != .Idle {
			p.redraw(ui)
		}

		if m.phase == .Counting && g_now >= m.count_until {
			fire(m)
		}
		if kind, path, out, ok, got := job_collect(); got {
			finish_job(m, kind, path, out, ok)
			delete(out)
		}

		keys(ui, app, m)
		build(ui, m)
	}
}

have :: proc(name: string) -> bool {
	state, sout, serr, err := os.process_exec(
		{command = {"sh", "-c", fmt.tprintf("command -v %s", name)}},
		context.temp_allocator,
	)
	_, _ = sout, serr
	return err == nil && state.exit_code == 0
}

cleanup :: proc(m: ^Model) {
	if m.img_ok {
		p.image_destroy(&m.img)
	}
	// The captures live in /tmp; anything the person asked to keep is already
	// copied into ~/Pictures.
	for i in 0 ..< m.n_shots {
		if m.shots[i].path != "" {
			os.remove(m.shots[i].path)
		}
	}
}

note :: proc(m: ^Model, s: string, bad := false) {
	n := min(len(s), len(m.toast))
	copy(m.toast[:], s[:n])
	m.toast_len = n
	m.toast_bad = bad
	m.toast_until = g_now + 6
}

delay_secs :: proc(m: ^Model) -> int {
	return Delay_Choices[m.delay_at % len(Delay_Choices)]
}

// ---------------------------------------------------------------------------
// Capturing
// ---------------------------------------------------------------------------

start_capture :: proc(m: ^Model) {
	if m.phase != .Idle {
		return
	}
	if !m.have_grim {
		note(m, "grim is not installed", true)
		return
	}
	if m.mode == .Region && !m.have_slurp {
		note(m, "slurp is not installed, so there is no way to pick a region", true)
		return
	}
	if m.mode == .Output && len(m.outputs) == 0 {
		note(m, "the compositor did not report any outputs", true)
		return
	}
	d := delay_secs(m)
	if d > 0 {
		m.phase = .Counting
		m.count_until = g_now + f64(d)
		m.status = fmt.tprintf("Capturing in %d seconds", d)
		return
	}
	fire(m)
}

// fire runs the capture. The window the tool lives in is part of the screen,
// so it will be in a full-screen shot — which is why the delay exists.
fire :: proc(m: ^Model) {
	path := temp_path(m.seq)
	m.seq += 1
	m.phase = .Working

	switch m.mode {
	case .Screen:
		m.status = "grim is reading every output"
		job_start(.Capture, path, argv_own("grim", path))
	case .Output:
		o := m.outputs[m.out_at % max(1, len(m.outputs))]
		m.status = fmt.tprintf("grim is reading %s", o.name)
		job_start(.Capture, path, argv_own("grim", "-o", o.name, path))
	case .Region:
		// slurp draws an overlay and blocks until a rectangle is dragged, so
		// the two run together in one shell and the whole thing waits on the
		// worker thread.
		m.status = "Drag a rectangle — slurp is waiting"
		job_start(
			.Capture,
			path,
			argv_own("sh", "-c", fmt.tprintf("grim -g \"$(slurp -d)\" %s", path)),
		)
	}
}

finish_job :: proc(m: ^Model, kind: Job_Kind, path, out: string, ok: bool) {
	m.phase = .Idle
	m.status = ""

	if kind == .Copy {
		if ok {
			if m.sel >= 0 {
				m.shots[m.sel].copied = true
			}
			note(m, "Copied to the clipboard as image/png")
		} else {
			note(m, "wl-copy failed", true)
		}
		return
	}

	if !ok || file_bytes(path) == 0 {
		os.remove(path)
		delete(path)
		// slurp exits non-zero when the selection is cancelled, which is not
		// an error worth shouting about.
		first := strings.trim_space(out)
		if nl := strings.index_byte(first, '\n'); nl > 0 {
			first = first[:nl]
		}
		note(m, first == "" ? "Capture cancelled" : first, first != "")
		return
	}

	w, h, _, got := p.image_size(path)
	s := Shot {
		path  = path,
		mode  = m.mode,
		w     = got ? w : 0,
		h     = got ? h : 0,
		bytes = file_bytes(path),
		when_ = clock_label(),
	}
	if m.mode == .Output && len(m.outputs) > 0 {
		s.out = m.outputs[m.out_at % len(m.outputs)].name
	}
	push_shot(m, s)
	note(m, fmt.tprintf("Captured %d x %d · %s", s.w, s.h, human_bytes(s.bytes)))
}

push_shot :: proc(m: ^Model, s: Shot) {
	if m.n_shots == MAX_SHOTS {
		// Drop the oldest, and its file with it.
		oldest := m.shots[MAX_SHOTS - 1]
		if oldest.path != "" && oldest.saved == "" {
			os.remove(oldest.path)
		}
		if oldest.path != "" {
			delete(oldest.path)
		}
		m.n_shots -= 1
	}
	// Newest first.
	for i := m.n_shots; i > 0; i -= 1 {
		m.shots[i] = m.shots[i - 1]
	}
	m.shots[0] = s
	m.n_shots += 1
	m.sel = 0
	m.img_for = -1 // force a decode
	m.zoom = 1
}

// ensure_decoded decodes the selected capture, once. palmy decodes through
// stb_image; a 1920x1080 PNG is about 80 ms, so it happens on a frame that is
// already showing a "decoding" state rather than silently stalling.
ensure_decoded :: proc(m: ^Model) {
	if m.sel < 0 || m.sel >= m.n_shots {
		return
	}
	if m.img_ok && m.img_for == m.sel {
		return
	}
	if m.img_ok {
		p.image_destroy(&m.img)
		m.img_ok = false
	}
	img, ok := p.load_image(m.shots[m.sel].path)
	m.img = img
	m.img_ok = ok
	m.img_for = m.sel
	if !ok {
		note(m, "palmy could not decode that PNG", true)
	}
}

clock_label :: proc() -> string {
	h, mi, sec := time.clock(time.now())
	return fmt.aprintf("%02d:%02d:%02d", h, mi, sec)
}

// ---------------------------------------------------------------------------
// Saving and copying
// ---------------------------------------------------------------------------

save_selected :: proc(m: ^Model) {
	if m.sel < 0 {
		note(m, "Nothing to save", true)
		return
	}
	s := &m.shots[m.sel]
	if s.saved != "" {
		note(m, fmt.tprintf("Already saved to %s", s.saved))
		return
	}
	dir := pictures_dir()
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {
			note(m, fmt.tprintf("%s does not exist and could not be created", dir), true)
			return
		}
	}
	name := stamp("screenshot")
	defer delete(name)
	dst := fmt.aprintf("%s/%s", dir, name)
	ok, err := save_copy(s.path, dst)
	log_cmd(fmt.tprintf("write %s", dst), ok)
	if !ok {
		delete(dst)
		note(m, err, true)
		return
	}
	s.saved = dst
	note(m, fmt.tprintf("Saved %s", dst))
}

copy_selected :: proc(m: ^Model) {
	if m.sel < 0 {
		note(m, "Nothing to copy", true)
		return
	}
	if !m.have_wlcopy {
		note(m, "wl-copy is not installed; palmy has no clipboard of its own", true)
		return
	}
	if job_busy() {
		return
	}
	s := m.shots[m.sel]
	m.phase = .Working
	m.status = "Putting the image on the clipboard"
	job_start(
		.Copy,
		"",
		argv_own("sh", "-c", fmt.tprintf("wl-copy --type image/png < %s", s.path)),
	)
}

discard_selected :: proc(m: ^Model) {
	if m.sel < 0 {
		return
	}
	s := m.shots[m.sel]
	if s.saved != "" {
		// Discard removes it from this window, never from ~/Pictures. Deleting
		// a file somebody asked to keep is not this tool's business.
		note(m, "Removed from the list; the saved copy in ~/Pictures is untouched")
	}
	if s.path != "" {
		os.remove(s.path)
		delete(s.path)
	}
	for i in m.sel ..< m.n_shots - 1 {
		m.shots[i] = m.shots[i + 1]
	}
	m.n_shots -= 1
	if m.n_shots == 0 {
		m.sel = -1
	} else {
		m.sel = clamp(m.sel, 0, m.n_shots - 1)
	}
	if m.img_ok {
		p.image_destroy(&m.img)
		m.img_ok = false
	}
	m.img_for = -1
	m.zoom = 1
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^Model) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
	}

	if m.help_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, '?') {
			m.help_open = false
		}
		return
	}
	if m.log_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'g') {
			m.log_open = false
		}
		return
	}

	if m.phase == .Counting {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			m.phase = .Idle
			m.status = ""
			note(m, "Countdown cancelled")
		}
		return
	}

	if p.key_pressed(ui, '1') {m.mode = .Screen}
	if p.key_pressed(ui, '2') {
		if len(m.outputs) == 0 {
			note(m, "No outputs reported", true)
		} else {
			m.mode = .Output
		}
	}
	if p.key_pressed(ui, '3') {m.mode = .Region}

	if p.key_pressed(ui, 'o') && len(m.outputs) > 1 {
		m.out_at = (m.out_at + 1) % len(m.outputs)
		m.mode = .Output
	}
	if p.key_pressed(ui, 't') {
		m.delay_at = (m.delay_at + 1) % len(Delay_Choices)
		note(
			m,
			delay_secs(m) == 0 \
			? "No delay" \
			: fmt.tprintf("%d second delay — time to switch away from this window", delay_secs(m)),
		)
	}

	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE) {
		start_capture(m)
	}

	if p.key_pressed(ui, p.KEY_DOWN) && m.n_shots > 0 {
		m.sel = clamp(m.sel + 1, 0, m.n_shots - 1)
		m.zoom = 1
	}
	if p.key_pressed(ui, p.KEY_UP) && m.n_shots > 0 {
		m.sel = clamp(m.sel - 1, 0, m.n_shots - 1)
		m.zoom = 1
	}

	if p.key_pressed(ui, 's') {save_selected(m)}
	if p.key_pressed(ui, 'c') {copy_selected(m)}
	if p.key_pressed(ui, 'x') {discard_selected(m)}
	if p.key_pressed(ui, 'g') {m.log_open = true}
	if p.key_pressed(ui, '?') {m.help_open = true}

	if p.key_pressed(ui, '=') || p.key_pressed(ui, '+') {
		m.zoom = clamp(m.zoom * 1.5, 1, 16)
	}
	if p.key_pressed(ui, '-') {
		m.zoom = clamp(m.zoom / 1.5, 1, 16)
	}
	if p.key_pressed(ui, 'f') {m.zoom = 1}
	if p.key_pressed(ui, 'r') {
		m.outputs = read_outputs()
		note(m, fmt.tprintf("%d output(s) reported by the compositor", len(m.outputs)))
	}
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

human_bytes :: proc(b: i64) -> string {
	f := f64(b)
	switch {
	case b >= 1 << 20:
		return fmt.tprintf("%.1f MB", f / f64(1 << 20))
	case b >= 1 << 10:
		return fmt.tprintf("%.0f kB", f / f64(1 << 10))
	}
	return fmt.tprintf("%d B", b)
}
