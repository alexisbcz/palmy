// Copy and paste in palmy's own text widgets.
//
// The wire protocols (wl_data_device, the primary selection, ICCCM
// selections) need a display server and are exercised against sway, Hyprland
// and Xvfb by hand; see `palmy/clipboard.odin`. An offscreen frame has a
// process-local clipboard instead, which is what lets the widgets' side be
// asserted here.
package palmy_tests

import "core:testing"
import p "../palmy"

@(private = "file")
Bufs :: struct {
	area:  [dynamic]u8,
	field: [dynamic]u8,
	clip:  string, // the clipboard at the end of the last frame
}

// Every frame builds the whole tree: Tab moves focus through last frame's.
@(private = "file")
draw :: proc(off: ^p.Offscreen, b: ^Bufs) {
	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full p-2 gap-2")
	p.text_area(ui, &b.area, "", "w-full h-[80]")
	p.text_field(ui, &b.field, "", "w-full")
	p.end(ui)
	delete(b.clip)
	b.clip, _ = p.clipboard_get(ui, context.allocator)
	p.offscreen_end(off)
}

@(private = "file")
key :: proc(off: ^p.Offscreen, b: ^Bufs, sym: u32, mods: p.Modifiers = {}) {
	p.press_key(off, sym, mods)
	draw(off, b)
}

@(test)
test_text_area_copy_cut_and_paste_into_a_field :: proc(t: ^testing.T) {
	off := p.offscreen_create(400, 200)
	defer p.offscreen_destroy(off)

	b: Bufs
	defer delete(b.area)
	defer delete(b.field)
	defer delete(b.clip)
	append(&b.area, "first line\nsecond")
	draw(off, &b)
	draw(off, &b)

	// Into the area, select everything, copy.
	key(off, &b, p.KEY_TAB)
	key(off, &b, 'a', {.Ctrl, .Shift})
	key(off, &b, 'c', {.Ctrl})
	testing.expectf(t, b.clip == "first line\nsecond", "clipboard %q", b.clip)
	testing.expectf(t, string(b.area[:]) == "first line\nsecond", "area %q", string(b.area[:]))

	// Into the field: one line, the newline becomes a space.
	key(off, &b, p.KEY_TAB)
	key(off, &b, 'v', {.Ctrl})
	testing.expect_value(t, string(b.field[:]), "first line second")

	// Back into the area: cut empties it, Ctrl+V and Shift+Insert paste.
	key(off, &b, p.KEY_TAB)
	key(off, &b, 'a', {.Ctrl, .Shift})
	key(off, &b, 'x', {.Ctrl})
	testing.expectf(t, string(b.area[:]) == "", "area after cut %q", string(b.area[:]))
	key(off, &b, 'v', {.Ctrl})
	key(off, &b, p.KEY_INSERT, {.Shift})
	testing.expectf(
		t,
		string(b.area[:]) == "first line\nsecondfirst line\nsecond",
		"area after two pastes %q",
		string(b.area[:]),
	)

	// Copy with nothing selected leaves the clipboard alone.
	key(off, &b, 'c', {.Ctrl})
	testing.expectf(t, b.clip == "first line\nsecond", "clipboard %q", b.clip)
}

// Without a window there is no clipboard, and the default-window overloads
// say so rather than pretending: a command line caller falls back on false.
@(test)
test_no_window_means_no_clipboard :: proc(t: ^testing.T) {
	testing.expect(t, !p.clipboard_set("x"), "no window, no clipboard")
	_, ok := p.clipboard_get(context.temp_allocator)
	testing.expect(t, !ok, "and nothing to paste")
	testing.expect(t, !p.clipboard_available(), "and none available")
}
