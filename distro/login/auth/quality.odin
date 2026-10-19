package auth

// What a new password must be. Deliberately little: long enough not to be
// guessed in the minute-long waits of ratelimit.odin, not the old one, not
// the name. Composition rules ("one digit, one symbol") are left out — they
// make passwords harder to remember, not to guess.

import "core:strings"
import "core:unicode/utf8"

MIN_PASSWORD :: 6

// password_problem says what is wrong with `pw` as a new password for
// `user`, or "" when nothing is.
password_problem :: proc(pw, old, user: string) -> string {
	if pw == "" {
		return "The new password is empty."
	}
	if utf8.rune_count_in_string(pw) < MIN_PASSWORD {
		return "The new password is too short (at least 6 characters)."
	}
	if old != "" && pw == old {
		return "The new password is the same as the old one."
	}
	if strings.equal_fold(pw, user) {
		return "The new password is the user name."
	}
	for c in transmute([]u8)pw {
		if c < 0x20 || c == 0x7f {
			return "The new password has a control character in it."
		}
	}
	return ""
}
