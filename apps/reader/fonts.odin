// Loading the same faces the windowed app uses, for the headless paths.
//
// `kit.start` does this as part of opening a window, which the selftest, the
// benchmark and the offscreen renders do not have. The list has to match
// kit's exactly, or a measurement taken headlessly would not be the one the
// window produces, and the whole point of asserting on reflow is that the
// assertion is about what the reader sees.
package main

import "core:fmt"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

READER_MONO := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

load_test_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in READER_MONO {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
}
