// A frame folds every pointer event since the previous one into one state.
// A release on a button followed, in the same batch, by a motion off it is a
// click on that button: it is hit tested where the button came up, not where
// the pointer went next. (Seen with a virtual pointer on headless sway, where
// `click` then `move` arrive together; a fast real mouse does the same.)
package palmy_tests

import "core:testing"
import p "../palmy"

@(private = "file")
button :: proc(ui: ^p.Ctx) -> bool {
	p.div(ui, "absolute left-[20] top-[20] w-[100] h-[40] bg-sky-600")
	hit := p.clickable(ui)
	p.end(ui)
	return hit
}

@(test)
test_release_then_motion_in_one_frame_is_a_click :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 200)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	button(ui)
	p.offscreen_end(off)

	p.move_pointer(off, 50, 40)
	p.press(off)
	ui = p.offscreen_begin(off)
	testing.expect(t, !button(ui), "a press alone is not a click")
	p.offscreen_end(off)

	// Up on the button, then away, before the next frame runs.
	p.release(off)
	p.move_pointer(off, 300, 150)
	ui = p.offscreen_begin(off)
	testing.expect(t, button(ui), "the release happened on the button")
	p.offscreen_end(off)
}

// And the other way round: a press that happened off the button is not made
// into one by a motion onto it in the same batch.
@(test)
test_press_off_then_motion_on_is_not_a_press_on_it :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 200)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	button(ui)
	p.offscreen_end(off)

	p.move_pointer(off, 300, 150)
	p.press(off)
	p.move_pointer(off, 50, 40)
	ui = p.offscreen_begin(off)
	button(ui)
	p.offscreen_end(off)
	p.release(off)
	ui = p.offscreen_begin(off)
	testing.expect(t, !button(ui), "pressed elsewhere, released on it: no click")
	p.offscreen_end(off)
}
