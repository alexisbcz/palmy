package main

// `render --measure <size> <weight> <text>` prints palmy's advance width, so
// text metrics can be compared against the browser's directly.

import "core:fmt"
import "core:strconv"
import p "palmy:."

measure_text_cli :: proc(args: []string) {
	if len(args) < 3 {
		fmt.eprintln("usage: render --measure <px> <400|500|600|700> <text>")
		return
	}
	size, _ := strconv.parse_f32(args[0])
	w, _ := strconv.parse_int(args[1])

	wt: p.Font_Weight = .Regular
	switch w {
	case 500:
		wt = .Medium
	case 600:
		wt = .Semibold
	case 700:
		wt = .Bold
	}

	off := p.offscreen_create(10, 10, 1)
	defer p.offscreen_destroy(off)
	pin_fonts(&off.fonts)

	m := p.font_metrics(&off.fonts, size, .Sans, wt)
	fmt.printfln(
		"text=%q size=%.2f weight=%d width=%.4f ascent=%.3f descent=%.3f line=%.3f",
		args[2], size, w,
		p.text_width(&off.fonts, args[2], size, .Sans, wt),
		m.ascent, m.descent, m.line,
	)
}
