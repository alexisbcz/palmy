package main

// The clipboard, which for a password manager is the most dangerous thing it
// does. Two rules:
//
//  1. The secret goes through a pipe, never through argv. `wl-copy -- <secret>`
//     puts the password in /proc/<pid>/cmdline, where every process running as
//     this user can read it for as long as wl-copy lives -- which is until
//     something else takes the selection.
//
//  2. It clears itself. A copy arms a timer; when it expires, the selection is
//     cleared, but only if it is still *ours* -- compared in constant time
//     against what was put there. If you have copied something else in the
//     meantime, that is yours and this app leaves it alone.
//
// palmy is a Wayland client and does not implement wl_data_device, so all of
// this is wl-clipboard, exactly as `kit` documents. The one thing not taken
// from kit is `clipboard_set`, because it passes the text as an argument.

import "core:crypto"
import "core:os"
import kit "kit:."

// g_test redirects every clipboard operation into a variable, so the self-test
// can assert on copying and clearing without reaching the real selection. A
// test run must leave the user's clipboard exactly as it found it.
g_test: bool
g_test_clip: string

clip_available :: proc() -> bool {
	if g_test {
		return true
	}
	return kit.has_tool("wl-copy") && kit.has_tool("wl-paste")
}

// clip_put hands the text to wl-copy on stdin.
clip_put :: proc(text: string) -> bool {
	if g_test {
		delete(g_test_clip)
		g_test_clip = clone_secret(text)
		return true
	}

	r, w, perr := os.pipe()
	if perr != nil {
		return false
	}
	// stdout and stderr are deliberately nil: wl-copy forks a daemon that
	// inherits whatever stdio it is given, and a pipe we then read to EOF
	// would not reach EOF until some other program took the selection.
	child, serr := os.process_start({command = {"wl-copy"}, stdin = r})
	os.close(r)
	if serr != nil {
		os.close(w)
		return false
	}
	off := 0
	bytes := transmute([]u8)text
	for off < len(bytes) {
		n, werr := os.write(w, bytes[off:])
		if werr != nil || n == 0 {
			break
		}
		off += n
	}
	os.close(w)
	state, werr := os.process_wait(child)
	return werr == nil && state.exit_code == 0 && off == len(bytes)
}

clip_clear :: proc() -> bool {
	if g_test {
		delete(g_test_clip)
		g_test_clip = ""
		return true
	}
	child, err := os.process_start({command = {"wl-copy", "--clear"}})
	if err != nil {
		return false
	}
	state, werr := os.process_wait(child)
	return werr == nil && state.exit_code == 0
}

// clip_is reports whether the selection still holds exactly `text`. The
// comparison is constant time -- it is comparing two secrets, and a length or
// timing answer about a password is still an answer about a password.
clip_is :: proc(text: string) -> bool {
	if g_test {
		return secret_eq(g_test_clip, text)
	}
	cur, ok := kit.clipboard_get(context.temp_allocator)
	if !ok {
		return false
	}
	return secret_eq(cur, text)
}

secret_eq :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	if len(a) == 0 {
		return true
	}
	// `compare_constant_time` returns 1 when the slices are equal, not 0.
	return crypto.compare_constant_time(transmute([]u8)a, transmute([]u8)b) == 1
}

clone_secret :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, transmute([]u8)s)
	return string(out)
}
