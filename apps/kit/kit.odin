// Shared setup for the palmy desktop apps: a window dressed in the shadcn
// theme, and the two things every one of them needs — running a command and
// launching one.
package kit

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

	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
	return app, ""
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
// palmy is a client and does not implement wl_data_device, so the clipboard
// goes through wl-clipboard. Every app needs it and none of them should have to
// discover this separately.
// ---------------------------------------------------------------------------

// clipboard_set copies text to the Wayland selection. Returns false when
// wl-copy is not installed.
//
// This must not capture wl-copy's output. wl-copy daemonises -- it keeps
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
	return run({"wl-paste", "--no-newline"}, allocator)
}

// has_tool reports whether a command line tool is on PATH, so an app can
// disable a menu item rather than fail when the user picks it.
has_tool :: proc(name: string) -> bool {
	_, ok := run({"sh", "-c", fmt.tprintf("command -v %s", name)}, context.temp_allocator)
	return ok
}
