// Keysym to character, for the X11 backend and for apps/term's key encoder.
//
// Only Latin-1 and the 0x01000000-prefixed keysyms carry their character in
// their value. A Russian, Greek, Arabic or Hebrew layout on X11 hands out the
// legacy keysyms instead, which need the generated table.
package palmy_tests

import "core:testing"
import p "../palmy"

@(test)
test_legacy_keysyms_map_to_their_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, p.keysym_to_rune('q'), 'q')
	testing.expect_value(t, p.keysym_to_rune(0xfc), 'ü')
	testing.expect_value(t, p.keysym_to_rune(0x06d1), 'я') // Cyrillic_ya
	testing.expect_value(t, p.keysym_to_rune(0x07c1), 'Α') // Greek_ALPHA
	testing.expect_value(t, p.keysym_to_rune(0x05ea), 'ي') // Arabic_yeh
	testing.expect_value(t, p.keysym_to_rune(0x0cf9), 'ש') // hebrew_shin
	testing.expect_value(t, p.keysym_to_rune(0x20ac), '€') // EuroSign
	testing.expect_value(t, p.keysym_to_rune(0x0101f600), '😀')
	testing.expect_value(t, p.keysym_to_rune(0xff0d), 0) // Return
	testing.expect_value(t, p.keysym_to_rune(0xffb1), 0) // KP_1 is a key, not text here

	// keysym_utf8, which the X11 backend types with, adds the keypad.
	buf: [8]u8
	n := p.keysym_utf8(0x06c1, buf[:])
	testing.expect_value(t, string(buf[:n]), "а")
	n = p.keysym_utf8(0xffb1, buf[:])
	testing.expect_value(t, string(buf[:n]), "1")
}
