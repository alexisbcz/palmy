package arabic_shot

// Renders the shaping corpus so it can be looked at rather than only asserted
// on. Writes one PNG per group to the directory given as the first argument.
//
//	odin run tools/arabic/shot -collection:palmy=$PWD/palmy -- /tmp/shots
//
// Three columns per line: the text as palmy draws it today with no shaping, the
// same text shaped, and the shaped text with its runes reversed. The reversal
// stands in for the bidi reordering pass, which lives in palmy/bidi.odin and is
// not this module's job -- without it a correct Arabic line still reads
// backwards, and only the third column can be read as Arabic.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import p "palmy:."

Line :: struct {
	label: string,
	text:  string,
}

GROUPS := [?]struct {
	name:  string,
	lines: []Line,
} {
	{
		"forms",
		{
			{"isolated", "ب"},
			{"initial+final", "بب"},
			{"+medial", "ببب"},
			{"two medials", "بببب"},
			{"bism", "بسم"},
			{"kitab", "كتاب"},
			{"baba", "بابا"},
		},
	},
	{
		"lam-alef",
		{
			{"lam alef", "لا"},
			{"salam", "سلام"},
			{"madda", "لآ"},
			{"hamza", "لأ"},
			{"al-islam", "الاسلام"},
			{"ahlan", "أهلا وسهلا"},
		},
	},
	{
		"marks",
		{
			{"bayt", "بَيت"},
			{"muhammad", "مُحَمَّد"},
			{"al-arabiyya", "الْعَرَبِيَّة"},
			{"lam fatha alef", "لَا"},
			{"bismi", "بِسْمِ"},
		},
	},
	{
		"mixed",
		{
			{"latin after", "مرحبا Hello"},
			{"latin before", "Hello مرحبا world"},
			{"digits", "عام 2024 م"},
			{"sentence", "بسم الله الرحمن الرحيم"},
			{"persian", "گفتگو پارسی"},
			{"urdu", "پاکستان اردو"},
		},
	},
}

reverse_runes :: proc(s: string) -> string {
	rs := utf8.string_to_runes(s, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for i := len(rs) - 1; i >= 0; i -= 1 {
		strings.write_rune(&b, rs[i])
	}
	return strings.to_string(b)
}

main :: proc() {
	dir := len(os.args) > 1 ? os.args[1] : "."
	for group in GROUPS {
		h := 70 + 52 * len(group.lines)
		off := p.offscreen_create(1180, h, 1, "w-full h-full bg-slate-950 text-slate-100 p-6")
		ui := p.offscreen_begin(off)
		p.col(ui, "gap-3 w-full")
		p.row(ui, "gap-6 w-full")
		p.text(ui, "label", "w-40 text-xs text-slate-500")
		p.text(ui, "unshaped", "w-72 text-xs text-slate-500")
		p.text(ui, "shaped", "w-72 text-xs text-slate-500")
		p.text(ui, "shaped, reversed (bidi stand-in)", "flex-1 text-xs text-slate-500")
		p.end(ui)
		for line in group.lines {
			shaped := p.shape_arabic(line.text, p.DEFAULT_SHAPE_OPTIONS, context.temp_allocator)
			p.row(ui, "gap-6 w-full items-center")
			p.text(ui, line.label, "w-40 text-xs text-slate-500")
			p.text(ui, line.text, "w-72 text-2xl text-slate-400")
			p.text(ui, shaped, "w-72 text-2xl text-amber-300")
			p.text(ui, reverse_runes(shaped), "flex-1 text-2xl text-emerald-300")
			p.end(ui)
		}
		p.end(ui)
		p.offscreen_end(off)
		path := fmt.tprintf("%s/arabic-%s.png", dir, group.name)
		ok := p.offscreen_write_png(off, path)
		fmt.printf("%s %v\n", path, ok)
		p.offscreen_destroy(off)
	}
}
