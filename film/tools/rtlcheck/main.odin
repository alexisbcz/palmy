// Render right-to-left text through palmy's own text path, for the film.
//
// The film's fourth chapter makes a claim about what the toolkit does and does
// not do with bidirectional text. A claim like that has to be *looked* at, not
// taken from a commit message, so this draws the cases the chapter talks about
// and writes them out. Two things follow from that:
//
//   * it is the verification. Run it, open the PNGs, and you can see whether
//     Arabic joins and whether Hebrew reorders, rather than believing a card;
//   * it is the footage. Chapter four holds these two frames, so the chapter
//     about the text renderer is drawn by the text renderer, with no
//     screenshot of a desktop and nothing from a home directory in it.
//
//   bash film/tools/rtlcheck/run.sh   ->  film/.work/rtl-wired.png
//                                         film/.work/rtl-gaps.png
//
// Rendered at the film's 1280x720 and scale 2, so a crash zoom has pixels to
// find. The palette is the film's: cream #F4D35E on black, red #E23A2E for the
// half that does not work yet.
package main

import "core:fmt"

import p "palmy:."

W :: 1280
H :: 720

CREAM :: "text-[#F4D35E]"
WHITE :: "text-[#F2EFE6]"
DIM :: "text-[#8A8578]"
RED :: "text-[#E23A2E]"

// A label and the sample it describes, as one block. The class string is
// built with `tprintf` rather than `+` because Odin only concatenates
// constants, and the size varies between the two frames.
sample :: proc(ui: ^p.Ctx, label: string, body: string, size: string) {
	p.col(ui, "gap-1 items-end")
	defer p.end(ui)
	p.text(ui, label, "text-[17px] " + DIM)
	p.text(ui, body, fmt.tprintf("%s %s", size, WHITE))
}

wired :: proc() {
	off := p.offscreen_create(W, H, 2, "flex-row gap-10 px-14 py-12 bg-black")
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)

	// Left: what was measured. Right: what it now draws.
	p.col(ui, "w-[420] h-full gap-3 justify-center")
	p.text(ui, "NOW WIRED IN", "text-2xl font-bold tracking-widest " + CREAM)
	p.text(ui, "bidi and shaping reach the text path", "text-[19px] " + WHITE)
	p.div(ui, "h-2")
	p.end(ui)
	p.text(ui, "4,564 cases", "text-2xl font-bold " + CREAM)
	p.text(ui, "105,801 expectations", "text-2xl font-bold " + CREAM)
	p.text(ui, "0 failures", "text-2xl font-bold " + CREAM)
	p.div(ui, "h-2")
	p.end(ui)
	p.text(ui, "checked against ICU and fribidi,", "text-[16px] " + DIM)
	p.text(ui, "which disagree with each other on four", "text-[16px] " + DIM)
	p.end(ui)

	p.col(ui, "flex-1 h-full gap-7 justify-center items-end")
	sample(ui, "Hebrew, reordered", "שלום עולם", "text-4xl")
	sample(ui, "Arabic, joined", "السلام عليكم", "text-4xl")
	sample(ui, "one line, two directions",
		"הקוד palmy נכתב", "text-4xl")
	p.end(ui)

	p.offscreen_end(off)
	p.offscreen_write_png(off, "film/.work/rtl-wired.png")
}

gaps :: proc() {
	off := p.offscreen_create(W, H, 2, "flex-row gap-10 px-14 py-12 bg-black")
	defer p.offscreen_destroy(off)
	ui := p.offscreen_begin(off)

	p.col(ui, "w-[480] h-full gap-3 justify-center")
	p.text(ui, "AND STILL WRONG", "text-2xl font-bold tracking-widest " + RED)
	p.div(ui, "h-2")
	p.end(ui)
	p.text(ui, "no GPOS, so marks sit on the advance", "text-[19px] " + WHITE)
	p.text(ui, "no Indic, Thai or Khmer shaping at all", "text-[19px] " + WHITE)
	p.text(ui, "truncate_to still cuts the logical prefix", "text-[19px] " + WHITE)
	p.text(ui, "288 joining letters have no presentation form", "text-[19px] " + WHITE)
	p.end(ui)

	p.col(ui, "flex-1 h-full gap-10 justify-center items-end")
	sample(ui, "vocalised Arabic — the marks are not attached",
		"بَيْتُكَ", "text-6xl")
	sample(ui, "Devanagari — not shaped, so the matra stays after its consonant",
		"हिन्दी", "text-6xl")
	p.end(ui)

	p.offscreen_end(off)
	p.offscreen_write_png(off, "film/.work/rtl-gaps.png")
}

main :: proc() {
	wired()
	gaps()
}
