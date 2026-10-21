#+build linux
// A keyboard that appears holding a key: the re-bind race on a seat whose
// keyboard capability comes and goes (headless sway with wtype, an on-screen
// keyboard, remote input). See "A keyboard that arrives holding a key" in
// palmy/wayland.odin. Driven through a socketpair standing in for the
// compositor, with palmy's own Wayland dispatch.
package palmy_tests

import "core:strings"
import "core:testing"
import "core:time"
import p "../palmy"

@(private = "file")
SEAT_CAPS :: 0
@(private = "file")
KBD_ENTER :: 1
@(private = "file")
KBD_LEAVE :: 2
@(private = "file")
KBD_KEY :: 3
@(private = "file")
KBD_MODS :: 4
@(private = "file")
KEY_A :: 30 // evdev
@(private = "file")
KEY_ENTER :: 28

// bind_keyboard announces the capabilities and returns the wl_keyboard id
// palmy asked for (0 if it asked for none).
@(private = "file")
announce :: proc(f: ^Fake_Wl, caps: u32) -> (kbd: u32) {
	fake_event(f, f.w.wl.seat, SEAT_CAPS, caps)
	p.window_pump(f.w)
	for r in fake_requests(f) {
		if r.id == f.w.wl.seat && r.opcode == 1 { // wl_seat.get_keyboard
			kbd = fake_arg(r, 0)
		}
	}
	return
}

@(private = "file")
seat_fake :: proc() -> ^Fake_Wl {
	f := fake_wl_open()
	f.w.wl.seat = p.new_id(&f.w.conn, .Seat)
	f.w.input.text = strings.builder_make()
	return f
}

@(private = "file")
seat_done :: proc(f: ^Fake_Wl) {
	strings.builder_destroy(&f.w.input.text)
	fake_wl_close(f)
}

// The press went to nobody, because the keyboard object did not exist yet;
// the enter lists the key as held and the release follows. That is a press.
@(test)
test_keyboard_appearing_with_a_key_held_delivers_it :: proc(t: ^testing.T) {
	f := seat_fake()
	defer seat_done(f)

	testing.expect_value(t, announce(f, 0), 0)
	kbd := announce(f, 2)
	testing.expect(t, kbd != 0, "a keyboard appearing is bound")

	fake_event(f, kbd, KBD_ENTER, ..fake_array_with(7, 0, KEY_A))
	fake_event(f, kbd, KBD_MODS, 8, 0, 0, 0, 0)
	fake_event(f, kbd, KBD_KEY, 9, 0, KEY_A, 0) // the release
	p.window_pump(f.w)

	testing.expect_value(t, strings.to_string(f.w.input.text), "a")
	testing.expect_value(t, len(f.w.input.keys), 1)
	if len(f.w.input.keys) == 1 {
		testing.expect_value(t, f.w.input.keys[0].sym, u32('a'))
	}

	// The capability goes and comes back: the next device's held key is
	// delivered too, once, and an ordinary press after it as usual.
	testing.expect_value(t, announce(f, 0), 0)
	kbd2 := announce(f, 2)
	testing.expect(t, kbd2 != 0)
	fake_event(f, kbd2, KBD_ENTER, ..fake_array_with(11, 0, 31)) // s
	fake_event(f, kbd2, KBD_MODS, 12, 0, 0, 0, 0)
	fake_event(f, kbd2, KBD_KEY, 13, 0, 31, 0)
	fake_event(f, kbd2, KBD_KEY, 14, 0, 32, 1) // d, pressed normally
	fake_event(f, kbd2, KBD_KEY, 15, 0, 32, 0)
	p.window_pump(f.w)
	testing.expect_value(t, strings.to_string(f.w.input.text), "asd")
}

// Held modifiers arrive in the modifiers event after the enter, and the key
// waits for them: Shift+a held across the re-bind types `A`.
@(test)
test_keyboard_appearing_keeps_the_held_modifiers :: proc(t: ^testing.T) {
	f := seat_fake()
	defer seat_done(f)
	announce(f, 0)
	kbd := announce(f, 2)
	fake_event(f, kbd, KBD_ENTER, ..fake_array_with(7, 0, 42, KEY_A)) // shift, a
	fake_event(f, kbd, KBD_MODS, 8, 1, 0, 0, 0)
	p.window_pump(f.w)
	testing.expect_value(t, strings.to_string(f.w.input.text), "A")
}

// The keys of an ordinary enter are not presses. A window opened while the
// Return that launched it is held, on a seat that always had a keyboard, must
// not receive a Return.
@(test)
test_ordinary_enter_keys_are_not_presses :: proc(t: ^testing.T) {
	f := seat_fake()
	defer seat_done(f)

	kbd := announce(f, 2) // a keyboard from the start: never absent
	testing.expect(t, kbd != 0)
	fake_event(f, kbd, KBD_ENTER, ..fake_array_with(7, 0, KEY_ENTER))
	fake_event(f, kbd, KBD_MODS, 8, 0, 0, 0, 0)
	p.window_pump(f.w)
	testing.expect_value(t, len(f.w.input.keys), 0)

	// Focus leaving and coming back with a key held (Alt+Tab) is no press
	// either, even on a seat whose keyboard once came and went.
	announce(f, 0)
	kbd2 := announce(f, 2)
	fake_event(f, kbd2, KBD_ENTER, ..fake_array_with(9, 0))
	fake_event(f, kbd2, KBD_LEAVE, 10, 0)
	fake_event(f, kbd2, KBD_ENTER, ..fake_array_with(11, 0, 15)) // tab
	fake_event(f, kbd2, KBD_MODS, 12, 0, 0, 0, 0)
	p.window_pump(f.w)
	testing.expect_value(t, len(f.w.input.keys), 0)
}

// A first enter that comes long after the keyboard appeared is focus moving
// in, not the device's first key.
@(test)
test_late_first_enter_is_not_a_press :: proc(t: ^testing.T) {
	f := seat_fake()
	defer seat_done(f)
	announce(f, 0)
	kbd := announce(f, 2)
	f.w.wl.kbd_bound_at = time.time_add(time.now(), -5 * time.Second)
	fake_event(f, kbd, KBD_ENTER, ..fake_array_with(7, 0, KEY_A))
	fake_event(f, kbd, KBD_MODS, 8, 0, 0, 0, 0)
	p.window_pump(f.w)
	testing.expect_value(t, len(f.w.input.keys), 0)
}

// fake_array_with is an enter's arguments: serial, surface, then the keys.
@(private = "file")
fake_array_with :: proc(serial, surface: u32, keys: ..u32) -> []u32 {
	out := make([dynamic]u32, 0, 3 + len(keys), context.temp_allocator)
	append(&out, serial, surface)
	append(&out, ..fake_array(..keys))
	return out[:]
}
