package main

// The clipboard, which for a password manager is the most dangerous thing it
// does. Three rules:
//
//  1. It goes through palmy's own clipboard client (palmy/clipboard.odin:
//     wl_data_device on Wayland, the ICCCM selection on X11), so a secret
//     never passes through another process at all. The selection is served
//     from this process's memory for as long as the window lives and nobody
//     else takes it; when the window closes, the selection goes with it.
//     wl-copy is only the fallback when there is no window to serve from (a
//     command-line path), and then the secret goes through a pipe, never
//     argv, where every process could read it in /proc/<pid>/cmdline.
//
//  2. It clears itself. A copy arms a timer; when it expires the selection is
//     cleared -- but only if it is still *ours*, compared in constant time
//     against what was put there. If you have copied something else in the
//     meantime, that is yours and this app leaves it alone.
//
//  3. It never reads anyone else's clipboard for its own sake. The one read
//     is that ownership check, which palmy answers from memory while we hold
//     the selection; apps/term refuses OSC 52 reads for the same reason this
//     is careful -- whatever was copied last is somebody's secret.

import "core:crypto"
import "core:os"
import kit "kit:."
import p "palmy:."

// g_test redirects every clipboard operation into a variable, so the self-test
// can assert on copying and clearing without reaching the real selection. A
// test run must leave the user's clipboard exactly as it found it.
g_test: bool
g_test_clip: string

clip_available :: proc() -> bool {
	if g_test {
		return true
	}
	return p.clipboard_available() || (kit.has_tool("wl-copy") && kit.has_tool("wl-paste"))
}

// clip_put offers the text as the clipboard selection.
clip_put :: proc(text: string) -> bool {
	if g_test {
		delete(g_test_clip)
		g_test_clip = clone_secret(text)
		return true
	}
	if p.clipboard_set(text) {
		return true
	}
	return wl_copy_put(text)
}

// wl_copy_put hands the text to wl-copy on stdin.
@(private = "file")
wl_copy_put :: proc(text: string) -> bool {
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
	if p.clipboard_set("") {
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
	cur, ok := p.clipboard_get(context.temp_allocator)
	if !ok {
		cur, ok = kit.clipboard_get(context.temp_allocator)
	}
	if !ok {
		return false
	}
	same := secret_eq(cur, text)
	if len(cur) > 0 {
		crypto.zero_explicit(raw_data(transmute([]u8)cur), len(cur))
	}
	return same
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
