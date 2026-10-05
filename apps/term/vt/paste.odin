package vt

import "core:strings"

// paste_is_safe reports whether a block of text can be pasted without the
// risk that it runs a command the person did not mean to run.
//
// Two things make a paste dangerous. A newline submits whatever came before
// it, so a copied line with a trailing newline executes the moment it lands.
// And the bracketed-paste end marker lets text that is being pasted claim the
// paste is over, after which the rest of it is typed into the shell as if by
// hand -- the trick that makes "copy this command from a web page" attacks
// work even in terminals that have bracketed paste turned on.
//
// The check is deliberately conservative and does not look at the terminal's
// current mode: unsafe text is unsafe whether or not bracketed paste happens
// to be enabled right now.
paste_is_safe :: proc(data: string) -> bool {
	if strings.index_byte(data, '\n') >= 0 {
		return false
	}
	if strings.contains(data, "\x1b[201~") {
		return false
	}
	return true
}
