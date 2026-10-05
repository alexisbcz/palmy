package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// palmy-term: a terminal emulator.
//
// The engine is apps/term/vt, which knows nothing about windows and is tested
// headlessly and against libghostty-vt. This file is the front end: it parses
// the command line, and either runs one of the headless commands or opens a
// window.
// ---------------------------------------------------------------------------

VERSION :: "palmy-term 1.0"

Options :: struct {
	term:       string,
	scrollback: int,
	font_size:  f32,
	cols, rows: int,
	argv:       []string,
	json:       bool,
}

main :: proc() {
	// Two shapes of command line meet here. A terminal has always been
	// `term -e CMD`, and breaking that would be gratuitous; the kit's
	// convention is what an agent drives. They are told apart by the first
	// token: a verb, or --help, or --selftest anywhere, goes to the kit, and
	// everything else is a window.
	args := os.args[1:]
	surface := term_surface()
	if goes_to_cli(&surface, args) {
		code, handled := kit.cli(&surface)
		if handled {
			os.exit(code)
		}
	}
	opt, always_tabs, err := window_options(args)
	if err != "" {
		fmt.eprintfln("term: %s (try --help)", err)
		os.exit(2)
	}
	run_window(opt, always_tabs)
}

@(private = "file")
goes_to_cli :: proc(s: ^kit.Surface, args: []string) -> bool {
	for a in args {
		if a == "--selftest" || a == "--self-test" {
			return true
		}
	}
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "--help", "-h", "help", "--schema", "-t":
		return true
	}
	for cmd in s.commands {
		if args[0] == cmd.verb {
			return true
		}
	}
	return false
}

// window_options parses the flags that only mean something to a window.
@(private = "file")
window_options :: proc(args: []string) -> (opt: Options, always_tabs: bool, err: string) {
	opt = Options {
		term       = "xterm-256color",
		scrollback = vt.DEFAULT_SCROLLBACK,
		font_size  = 14,
		cols       = 80,
		rows       = 24,
	}
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--version":
			fmt.println(VERSION)
			os.exit(0)
		case "--tabs":
			always_tabs = true
		case "--term":
			i += 1
			if i < len(args) {opt.term = args[i]}
		case "--scrollback":
			i += 1
			if i < len(args) {opt.scrollback = atoi(args[i], opt.scrollback)}
		case "--font-size":
			i += 1
			if i < len(args) {opt.font_size = f32(atoi(args[i], 14))}
		case "-e", "--exec", "--":
			opt.argv = args[i + 1:]
			i = len(args)
		case:
			return opt, always_tabs, fmt.tprintf("unknown option %q", a)
		}
		i += 1
	}
	return opt, always_tabs, ""
}

atoi :: proc(s: string, def: int) -> int {
	v, ok := strconv.parse_int(s)
	return ok ? v : def
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

run_window :: proc(opt: Options, always_tabs: bool) {
	app, err := kit.start(
		{
			title = "Terminal",
			app_id = "palmy-term",
			width = 1000,
			height = 640,
			min_width = 320,
			min_height = 200,
			root_class = "w-full h-full bg-slate-950 text-slate-200",
		},
	)
	if err != "" {
		fmt.eprintfln("term: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	ta := Term_App {
		app         = app,
		font_size   = opt.font_size,
		always_tabs = always_tabs,
		blink_on    = true,
		blink_at    = time.now(),
	}
	ta.rend.fonts = &app.fonts
	ta.zombies = make([dynamic]^Tab)
	renderer_metrics(&ta.rend, ta.font_size, 1)

	shell := opt.argv
	if len(shell) == 0 {
		shell = default_shell()
	}
	session_init(&ta.sess, opt.cols, opt.rows, opt.scrollback, opt.term, shell)
	if _, e := tab_open(&ta.sess); e != "" {
		fmt.eprintfln("term: %s", e)
		os.exit(1)
	}
	if !pump_start(&ta.pump, &ta.sess) {
		fmt.eprintln("term: cannot start the reader thread")
		os.exit(1)
	}

	busy := false
	for ui in p.frames(app) {
		wait_for_work(&ta, idle_timeout(&ta, busy))
		before := ta.sess.tabs[0].bytes_in if len(ta.sess.tabs) > 0 else 0
		frame(&ta, ui)
		run_clipboard(&ta)
		busy = len(ta.sess.tabs) > 0 && ta.sess.tabs[0].bytes_in != before
		if ta.quit {
			p.quit_app(app)
		}
	}
	pump_stop(&ta.pump)
	// Hang up anything still running, the same way closing a tab does.
	for t in ta.sess.tabs {
		tab_request_close(t)
	}
	session_destroy(&ta.sess)
	renderer_destroy(&ta.rend)
}

// idle_timeout decides how long to sleep. Busy means the child is producing
// output and the next frame should start immediately; a blinking cursor needs
// a wakeup about twice a second; otherwise there is nothing to do until
// something arrives on a descriptor, and poll() will say so.
idle_timeout :: proc(a: ^Term_App, busy: bool) -> int {
	if busy {
		return 0
	}
	t := session_active(&a.sess)
	if t != nil && (t.term.modes.cursor_blink || a.rend.has_blink) && a.focused {
		return 120
	}
	if len(a.zombies) > 0 {
		return 100
	}
	if a.status != "" {
		return 250
	}
	// Nothing is moving. The reader thread will poke the wake pipe the
	// instant the child writes, and the compositor will make the display
	// socket readable the instant anything happens, so a long timeout here
	// costs nothing but saves a wakeup a second. It is not zero only
	// because palmy has no way yet to be told "there is nothing to draw".
	return 1000
}

// ---------------------------------------------------------------------------
// The headless work the CLI commands do
// ---------------------------------------------------------------------------

Bench_Result :: struct {
	bytes:             int,
	seconds:           f64,
	mb_per_second:     f64,
	full_frame_ms:     f64,
	one_line_frame_ms: f64,
}

// bench feeds a file straight into the engine and then times the renderer.
// There is no window and no compositor in the way, so the numbers are the
// engine's and the rasterizer's rather than the display server's.
bench :: proc(path: string, opt: Options, verbose: bool) -> (res: Bench_Result, code: int) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return {}, 3
	}
	defer delete(data)

	t: vt.Terminal
	vt.terminal_init(&t, opt.cols, opt.rows, opt.scrollback)
	defer vt.terminal_destroy(&t)

	start := time.now()
	chunk := 64 * 1024
	off := 0
	for off < len(data) {
		n := min(chunk, len(data) - off)
		vt.terminal_feed(&t, data[off:off + n])
		off += n
	}
	secs := time.duration_seconds(time.since(start))
	mb := f64(len(data)) / (1024 * 1024)

	// The second half is the part a software rasterizer has to answer for:
	// how long a frame takes with every cell dirty, and how long one takes
	// when a prompt redrew a single line. The first is what a full-screen
	// `cat` costs; the second is what sitting at a shell costs, and the gap
	// between them is what the pixel cache buys.
	fonts: p.Fonts
	p.fonts_init(&fonts)
	defer p.fonts_destroy(&fonts)
	r := Grid_Renderer {
		fonts = &fonts,
	}
	renderer_metrics(&r, opt.font_size <= 0 ? 14 : opt.font_size, 1)
	renderer_resize(&r, opt.cols, opt.rows)
	defer renderer_destroy(&r)

	N :: 60
	renderer_draw(&r, &t, {}, true, true) // warm the glyph cache

	full_start := time.now()
	for _ in 0 ..< N {
		r.full = true
		renderer_draw(&r, &t, {}, true, true)
	}
	full_ms := time.duration_milliseconds(time.since(full_start)) / N

	line_start := time.now()
	for _ in 0 ..< N {
		vt.terminal_feed(&t, transmute([]u8)string("\r\x1b[Kuser@host:~$ "))
		renderer_draw(&r, &t, {}, true, true)
	}
	line_ms := time.duration_milliseconds(time.since(line_start)) / N

	res = {
		bytes             = len(data),
		seconds           = secs,
		mb_per_second     = mb / secs,
		full_frame_ms     = full_ms,
		one_line_frame_ms = line_ms,
	}
	if verbose {
		fmt.printfln(
			"engine   %d bytes in %.1f ms = %.1f MB/s  (%dx%d, %d lines of scrollback)",
			res.bytes,
			secs * 1000,
			res.mb_per_second,
			opt.cols,
			opt.rows,
			opt.scrollback,
		)
		fmt.printfln(
			"render   every cell dirty: %.2f ms/frame (%.0f fps)",
			full_ms,
			1000 / max(full_ms, 0.0001),
		)
		fmt.printfln(
			"render   one line dirty:   %.3f ms/frame (%.0f fps)",
			line_ms,
			1000 / max(line_ms, 0.0001),
		)
		fmt.printfln(
			"         %.0fx cheaper when only the prompt changed",
			full_ms / max(line_ms, 0.0001),
		)
	}
	return res, 0
}
