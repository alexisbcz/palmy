// Fonts.
//
// palmy's font table is indexed by family and weight; there is no italic
// axis, and `kit.start` fills the four mono weights with the same upright
// face. Nothing in this app ever asks for bold or semibold monospace, so
// those two slots carry real italic faces instead and `cell_face` maps a
// cell's format onto them. That is a workaround for a missing axis, not a
// clever trick — see the report.
package main

import "core:fmt"
import kit "kit:."
import p "palmy:."

ITALIC_FACES := [?][2]string {
	{"/usr/share/fonts/liberation/LiberationSans-Italic.ttf", "/usr/share/fonts/liberation/LiberationSans-BoldItalic.ttf"},
	{"/usr/share/fonts/noto/NotoSans-Italic.ttf", "/usr/share/fonts/noto/NotoSans-BoldItalic.ttf"},
	{"/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf", "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf"},
}

MONO_FACES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

// load_sans loads the same Geist faces `kit.start` does, for the offscreen
// renderer, which has its own font table.
load_sans :: proc(f: ^p.Fonts) {
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
	for path in MONO_FACES {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			break
		}
	}
}

// load_italics puts the italic faces in the mono bold slots.
load_italics :: proc(f: ^p.Fonts) {
	for pair in ITALIC_FACES {
		if p.load_font(f, pair[0], .Mono, .Bold) {
			if !p.load_font(f, pair[1], .Mono, .Semibold) {
				p.load_font(f, pair[0], .Mono, .Semibold)
			}
			return
		}
	}
}

// cell_face maps a cell's bold/italic flags onto the faces that are loaded.
cell_face :: proc(f: Cell_Fmt) -> (p.Font_Family, p.Font_Weight) {
	if f.italic {
		return .Mono, f.bold ? .Semibold : .Bold
	}
	return .Sans, f.bold ? .Bold : .Regular
}
