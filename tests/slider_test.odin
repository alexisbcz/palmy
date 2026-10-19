// p.slider's knob stays on its track and its centre follows the value
// (TODO.md K2). It used to be offset with a negative margin, which an
// absolutely positioned child ignores: at 100 the knob sat entirely past the
// end of a 248px track.
package palmy_tests

import "core:fmt"
import "core:os"
import "core:testing"
import p "../palmy"

@(test)
test_slider_knob_stays_on_its_track :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 60, 1, "w-full h-full bg-slate-900")
	defer p.offscreen_destroy(off)

	for v in ([]f32{0, 25, 50, 100}) {
		value := v
		s: int
		for _ in 0 ..< 2 {
			ui := p.offscreen_begin(off)
			p.row(ui, "w-full h-full px-[26] items-center")
			s = p.node_count(ui)
			p.slider(ui, &value, 0, 100, "w-[248]")
			p.end(ui)
			p.offscreen_end(off)
		}
		ui := p.offscreen_begin(off)
		p.row(ui, "w-full h-full px-[26] items-center")
		s = p.node_count(ui)
		p.slider(ui, &value, 0, 100, "w-[248]")
		p.end(ui)
		p.offscreen_end(off)

		track := p.node_rect(ui, s)
		knob := p.node_rect(ui, s + 3)
		geom_eq(t, knob.w, 16, "the knob is the knob")
		testing.expectf(
			t,
			knob.x >= track.x - EPS && knob.x + knob.w <= track.x + track.w + EPS,
			"at %v the knob %s stays on the track %s",
			v,
			rect_str(knob),
			rect_str(track),
		)
		geom_eq(t, knob.x + 8, track.x + 8 + (track.w - 16) * v / 100, fmt.tprintf("at %v the knob's centre follows the value", v))
		testing.expectf(t, knob.y >= track.y - EPS && knob.y + knob.h <= track.y + track.h + EPS, "the knob is inside the control vertically")

		// Painted pixels: nothing knob-white right of the track's end.
		for x in int(track.x + track.w) + 1 ..< 300 {
			c := p.offscreen_pixel(off, x, int(track.y + track.h / 2))
			testing.expectf(t, !(c.r > 200 && c.g > 200 && c.b > 200), "at %v a white pixel at x=%d, past the track", v, x)
		}
		if dir := os.get_env("PALMY_SLIDER_PNG", context.temp_allocator); dir != "" {
			p.offscreen_write_png(off, fmt.tprintf("%s/slider-%v.png", dir, int(v)))
		}
	}
}
