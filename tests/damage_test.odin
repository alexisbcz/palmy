// A palmy window tells the compositor what changed in each frame
// (palmy/damage.odin) instead of damaging its whole surface, and does not send
// a frame identical to the last. The wm on bare metal repaints only damage,
// so whole-surface damage cost it most of a repaint for every keystroke.
package palmy_tests

import "core:testing"
import p "../palmy"

@(test)
test_damage_is_what_changed :: proc(t: ^testing.T) {
	W :: 100
	H :: 50
	d: p.Damage_State
	defer p.damage_destroy(&d)
	px := make([]u32, W * H)
	defer delete(px)

	testing.expect(t, p.frame_damage(&d, px, W, H), "the first frame is new")
	testing.expect_value(t, len(d.rects), 1)
	testing.expect_value(t, d.rects[0], p.Damage_Rect{0, 0, W, H})

	testing.expect(t, !p.frame_damage(&d, px, W, H), "an identical frame has no damage")
	testing.expect_value(t, len(d.rects), 0)

	// Two far-apart changes are two rectangles, each exactly the pixels.
	px[5 * W + 10] = 0xffffffff
	px[40 * W + 80] = 0xff00ff00
	px[40 * W + 82] = 0xff00ff00
	testing.expect(t, p.frame_damage(&d, px, W, H), "changed")
	testing.expect_value(t, len(d.rects), 2)
	testing.expect_value(t, d.rects[0], p.Damage_Rect{10, 5, 1, 1})
	testing.expect_value(t, d.rects[1], p.Damage_Rect{80, 40, 3, 1})
	testing.expect(t, !p.frame_damage(&d, px, W, H), "and then it is the last frame")

	// Rows a few apart join one rectangle: the union of their spans.
	px[20 * W + 30] = 1
	px[24 * W + 60] = 1
	testing.expect(t, p.frame_damage(&d, px, W, H), "changed")
	testing.expect_value(t, len(d.rects), 1)
	testing.expect_value(t, d.rects[0], p.Damage_Rect{30, 20, 31, 5})

	// Many scattered rows collapse into their union.
	for y := 0; y < H; y += 10 {
		px[y * W + y] += 1
	}
	for y := 1; y < H; y += 10 {
		px[y * W] += 1
	}
	testing.expect(t, p.frame_damage(&d, px, W, H), "changed")
	testing.expect(t, len(d.rects) <= 16, "a bounded number of rectangles")

	// A new size is all new.
	big := make([]u32, 2 * W * H)
	defer delete(big)
	testing.expect(t, p.frame_damage(&d, big, 2 * W, H), "resized")
	testing.expect_value(t, d.rects[0], p.Damage_Rect{0, 0, 2 * W, H})
}
