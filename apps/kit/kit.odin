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
start :: proc(cfg: p.Config) -> (app: ^p.App, err: string) {
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

	sc.register_shadcn_theme()
	p.set_text_gamma(1.8)
	return app, ""
}

// run captures a command's output. Returns the trimmed stdout and whether the
// command both started and exited successfully.
//
//	out, ok := kit.run({"nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi"})
run :: proc(argv: []string, allocator := context.allocator) -> (out: string, ok: bool) {
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
	_, err := os.process_start({command = argv})
	return err == nil
}

// Common colours for status, so the applets agree with each other.
OK_CLASS :: "text-emerald-600"
WARN_CLASS :: "text-amber-600"
BAD_CLASS :: "text-destructive"
