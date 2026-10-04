package main

// `ocr --shot out.png [file] [options]` renders the interface into a PNG with
// no compositor involved.
//
// Everything here is real: the file is really converted, the structure really
// recovered. Only the window is missing. It is the only way to check a layout
// on a machine whose tiling compositor decides the window size for you, and it
// is how the images in the report were made.
//
//   --view document|structure|notes
//   --convert            run the conversion before rendering
//   --consent            put the consent overlay up (nothing is ever sent)
//   --help-overlay       draw the key list
//   --size WxH

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import p "palmy:."
import sc "shadcn:."

shot_main :: proc(args: []string) -> int {
	out := ""
	src := ""
	view := View.Document
	do_convert := false
	do_consent := false
	do_help := false
	dark := true
	w, h := WIN_W, WIN_H

	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--shot":
			i += 1
			if i < len(args) {out = args[i]}
		case a == "--view":
			i += 1
			if i < len(args) {
				switch strings.to_lower(args[i], context.temp_allocator) {
				case "document":
					view = .Document
				case "structure":
					view = .Structure
				case "notes":
					view = .Notes
				}
			}
		case a == "--size":
			i += 1
			if i < len(args) {
				parts := strings.split(args[i], "x", context.temp_allocator)
				if len(parts) == 2 {
					w, _ = strconv.parse_int(parts[0], 10)
					h, _ = strconv.parse_int(parts[1], 10)
				}
			}
		case a == "--convert":
			do_convert = true
		case a == "--consent":
			do_consent = true
		case a == "--help-overlay":
			do_help = true
		case a == "--light":
			dark = false
		case !strings.has_prefix(a, "-"):
			src = a
		}
		i += 1
	}
	if out == "" {
		fmt.eprintln("ocr --shot wants an output path")
		return 2
	}

	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_ui_fonts(&off.fonts)

	m := new(App)
	defer free(m)
	app_init(m)
	defer app_destroy(m)
	m.view = view

	if src != "" {
		open_path(m, src)
	}
	if do_convert && m.src != "" {
		start_convert(m)
		for _ in 0 ..< 2400 {
			if !job_busy() {
				break
			}
			time.sleep(25 * time.Millisecond)
		}
		_ = sync.atomic_load(&g_job.finished)
	}
	if do_consent && m.src != "" {
		// The overlay is drawn from a plan, and building a plan sends
		// nothing: it stats the file and formats a sentence.
		m.backend = .Mistral
		ask_consent(m)
	}
	m.help = do_help

	// Two frames: the first lays out, the second has hover and transitions
	// settled.
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		tick(m)
		build(ui, m)
		p.offscreen_end(off)
	}
	if !p.offscreen_write_png(off, out) {
		fmt.eprintfln("ocr: cannot write %s", out)
		return 1
	}
	fmt.printfln("%s", out)
	_ = os.args
	return 0
}
