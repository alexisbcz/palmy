// Shared setup for the palmy desktop apps: a window dressed in the shadcn
// theme, and the two things every one of them needs — running a command and
// launching one.
package kit

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"

@(private)
MONO_CANDIDATES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

// start opens a window with the shadcn theme registered and the Geist faces
// loaded, calibrated the same way the parity renderer is.
start :: proc(cfg: p.Config, dark := false) -> (app: ^p.App, err: string) {
	c := cfg
	if c.app_id == "" {
		c.app_id = "palmy"
	}
	if c.root_class == "" {
		c.root_class = "w-full h-full bg-background text-foreground"
	}

	app, err = p.create(c)
	if err != "" {
		return nil, err
	}
	// A window that opens is a recovery from whatever ended the last one
	// (the toasts reopen theirs after a compositor restart).
	g_window_error = ""

	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&app.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}

	// Geist ships four upright weights and no italic, so after that swap the
	// italic slots still hold whatever the system scan found -- measured here
	// as NotoSans-Italic at regular and DejaVuSans-BoldOblique at semibold.
	// Three typefaces in one paragraph reads as a bug, not as emphasis. A
	// sheared Geist is the same letterforms at a slant, which is what the
	// reader expects, so ask for the synthetic obliquing explicitly.
	//
	// Mono is deliberately left alone: the mono face loaded below ships a real
	// italic of its own family, and a real italic always beats a shear.
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&app.fonts, .Sans, wt)
	}

	// Without a mono face loaded, every `font-mono` class renders .notdef
	// boxes rather than falling back, so load one.
	for path in MONO_CANDIDATES {
		if p.load_font(&app.fonts, path, .Mono, .Regular) {
			p.load_font(&app.fonts, path, .Mono, .Medium)
			p.load_font(&app.fonts, path, .Mono, .Semibold)
			p.load_font(&app.fonts, path, .Mono, .Bold)
			break
		}
	}

	// An app that asks for dark is dark; otherwise it follows the theme the
	// person chose in Settings, so the shell and the apps agree.
	sc.register_shadcn_theme(dark || system_theme_dark())
	p.set_text_gamma(1.8)
	return app, ""
}

// ---------------------------------------------------------------------------
// The end of the loop
//
// palmy's frame loop ends for two kinds of reason: the person (or the app)
// closed the window, or the connection to the display server died — the
// compositor crashed, logged out, or killed the client for a protocol error.
// palmy says which on stderr and in `window_error(app)`, but the loop ends
// the same way either time, so an application that returns from main after
// it exits 0 whether it was closed or killed, and a session manager or a
// test cannot tell the two apart.
//
// `frames` is palmy's loop with that check: write `for ui in kit.frames(app)`
// instead of `for ui in p.frames(app)`. When the loop ends on an error the
// reason is kept, the application's own code after the loop still runs (a
// draft is still saved, a store still written), and when main returns the
// process exits EXIT_UNAVAILABLE (6) — the display server it talks to is not
// there — with the reason on stderr.
//
// Why not inside `start`, with no change to the application at all: palmy
// frees the App in `destroy`, which the application defers, so nothing the
// kit could look at survives to the end of main, and palmy has no hook that
// runs when the loop ends. With palmy keeping the last error past `destroy`
// the check below would read that instead and cover `p.frames` too; until
// then an application opts in with the one word.
// ---------------------------------------------------------------------------

@(private = "file")
g_window_error: string
@(private = "file")
g_window_title: string

// frames is `p.frames` that remembers why the loop ended, when it ended on an
// error. A drop-in: `for ui in kit.frames(app) { ... }`.
frames :: proc(app: ^p.App) -> (ui: ^p.Ctx, ok: bool) {
	ui, ok = p.frames(app)
	if !ok {
		window_loop_ended(app)
	}
	return
}

// window_loop_ended records why `app`'s loop stopped, if it stopped on an
// error. `frames` calls it; an application with a loop of its own (one that
// calls `p.frames` by hand, say to reopen the window) calls it where the loop
// ends, before it destroys the App.
window_loop_ended :: proc(app: ^p.App) {
	if app == nil {
		return
	}
	if e := p.window_error(app); e != "" {
		g_window_error = strings.clone(e, runtime.default_allocator())
		g_window_title = strings.clone(app.cfg.title, runtime.default_allocator())
	}
}

// window_exit is the exit status the window's end asks for: EXIT_OK and ""
// after a window that was closed, EXIT_UNAVAILABLE and the reason after one
// whose connection died (and no window has opened since).
window_exit :: proc() -> (code: int, why: string) {
	if g_window_error == "" {
		return EXIT_OK, ""
	}
	return EXIT_UNAVAILABLE, g_window_error
}

// window_exit_clear forgets a recorded end, as a window opening does.
window_exit_clear :: proc() {
	g_window_error = ""
}

// At the end of main: a window whose connection died is not a clean exit.
// An application that calls os.exit itself has chosen its status and does
// not come through here.
@(fini, private = "file")
window_exit_fini :: proc "contextless" () {
	if g_window_error == "" {
		return
	}
	context = runtime.default_context()
	code, why := window_exit()
	fmt.eprintfln("%s: the window ended because %s; exiting %d", g_window_title, why, code)
	os.exit(code)
}

// system_theme_dark reports the person's light/dark choice: PALMY_THEME if
// set, else the last `theme =` line in ~/.config/palmy/wm.conf, which
// Settings writes and the window manager reads. No explicit choice is light,
// what every app looked like before the setting existed.
system_theme_dark :: proc() -> bool {
	if env := os.get_env("PALMY_THEME", context.temp_allocator); env != "" {
		return strings.to_lower(strings.trim_space(env), context.temp_allocator) == "dark"
	}
	dir := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if dir == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			return false
		}
		dir = fmt.tprintf("%s/.config", home)
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/palmy/wm.conf", dir), context.temp_allocator)
	if err != nil {
		return false
	}
	dark := false
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "theme") {
			continue
		}
		rest := strings.trim_space(l[len("theme"):])
		if !strings.has_prefix(rest, "=") {
			continue
		}
		val := strings.to_lower(strings.trim_space(rest[1:]), context.temp_allocator)
		if i := strings.index_byte(val, '#'); i >= 0 {
			val = strings.trim_space(val[:i])
		}
		switch val {
		case "dark":
			dark = true
		case "light":
			dark = false
		}
	}
	return dark
}

// run captures a command's output. Returns the trimmed stdout and whether the
// command both started and exited successfully.
//
//	out, ok := kit.run({"nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi"})
run :: proc(argv: []string, allocator := context.allocator) -> (out: string, ok: bool) {
	// While a CLI command is running, the shared convention's guard decides
	// what may be spawned at all: an intent-class command executes nothing,
	// and the safety denylist in cli.odin refuses the handful of commands this
	// project has decided no application may run. Outside a CLI command the
	// guard is off and this behaves exactly as it always has.
	if why := cli_guard_check(argv); why != "" {
		cli_guard_refuse(argv, why)
		return "", false
	}
	state, sout, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil {
		return "", false
	}
	_ = serr
	text := strings.trim_space(string(sout))
	return strings.clone(text, allocator), state.exit_code == 0
}

// run_lines is `run` split into non-empty lines, which is how most of these
// command line tools are read.
run_lines :: proc(argv: []string, allocator := context.allocator) -> (lines: []string, ok: bool) {
	text, good := run(argv, context.temp_allocator)
	if !good && text == "" {
		return nil, false
	}
	parts := strings.split_lines(text, context.temp_allocator)
	keep := make([dynamic]string, allocator)
	for l in parts {
		t := strings.trim_space(l)
		if t != "" {
			append(&keep, strings.clone(t, allocator))
		}
	}
	return keep[:], good
}

// launch starts a detached process and does not wait for it, which is what a
// launcher wants when it opens an application.
launch :: proc(argv: []string) -> bool {
	if len(argv) == 0 {
		return false
	}
	if why := cli_guard_check(argv); why != "" {
		cli_guard_refuse(argv, why)
		return false
	}
	_, err := os.process_start({command = argv})
	return err == nil
}

// Common colours for status, so the applets agree with each other.
OK_CLASS :: "text-emerald-600"
WARN_CLASS :: "text-amber-600"
BAD_CLASS :: "text-destructive"

// ---------------------------------------------------------------------------
// Clipboard
//
// palmy owns the selection itself (palmy/clipboard.odin: wl_data_device, the
// primary selection, ICCCM selections), so that is tried first. wl-clipboard
// stays as the fallback for when palmy has no window, is called off the frame
// loop's thread, or the display server refuses. Every app needs this and none
// of them should have to discover it separately.
// ---------------------------------------------------------------------------

// clipboard_set copies text to the clipboard. Returns false when palmy could
// not and wl-copy is not installed.
//
// The wl-copy fallback must not capture wl-copy's output. wl-copy daemonises -- it keeps
// running to serve the selection until some other program takes it -- and the
// daemon inherits whatever stdio it was given. process_exec creates pipes and
// reads them to EOF, so the EOF never arrives and the call blocks until the
// *next* program copies something: measured at 45.9 seconds here, during which
// any app calling this from its frame loop is frozen.
//
// So spawn it with no pipes, the way `launch` does, and wait only on the
// direct child, which exits as soon as it has forked the daemon. That keeps
// the exit status (so a missing wl-copy is still reported) without inheriting
// the daemon's lifetime, and reaps the child (process_wait does that) rather than leaving
// a zombie per copy.
clipboard_set :: proc(text: string) -> bool {
	if p.clipboard_set(text) {
		return true
	}
	if why := cli_guard_check({"wl-copy"}); why != "" {
		cli_guard_refuse({"wl-copy"}, why)
		return false
	}
	child, err := os.process_start({command = {"wl-copy", "--", text}})
	if err != nil {
		return false
	}
	state, werr := os.process_wait(child)
	return werr == nil && state.exit_code == 0
}

// clipboard_get reads the current selection.
clipboard_get :: proc(allocator := context.allocator) -> (text: string, ok: bool) {
	if text, ok = p.clipboard_get(allocator); ok {
		return
	}
	return run({"wl-paste", "--no-newline"}, allocator)
}

// has_tool reports whether a command line tool is on PATH, so an app can
// disable a menu item rather than fail when the user picks it.
has_tool :: proc(name: string) -> bool {
	_, ok := run({"sh", "-c", fmt.tprintf("command -v %s", name)}, context.temp_allocator)
	return ok
}
