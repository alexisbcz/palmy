package palmy

import "core:sys/linux"

// ---------------------------------------------------------------------------
// The Linux backends' names, as macOS sees them.
//
// wire.odin, wayland.odin, x11.odin, xauth.odin and clipboard.odin are built
// everywhere but Darwin (`#+build !darwin`). window.odin and app.odin still
// name a few of their types and procedures: the fields of `Window`, and the
// switches that `window_darwin.odin` steps in front of. Odin type-checks a
// procedure's code after a `when` that returned, so those names have to exist
// here — but nothing on macOS reaches them. `Window.backend` keeps its zero
// value (.Wayland) on Darwin, so the procedures a shared switch can still
// reach are harmless no-ops, and the rest refuse.
//
// `Conn` is the one that matters: `conn.fatal` is how the frame loop learns
// the window is gone on every backend, and window_darwin.odin sets it.
// ---------------------------------------------------------------------------

Conn :: struct {
	// There is no display socket on macOS: AppKit's events come over a
	// Mach port that poll(2) cannot see. -1, so a poll set that includes it
	// ignores it rather than failing.
	fd:    linux.Fd,
	rx:    [dynamic]u8,
	fatal: string,
}

@(private)
Wl_State :: struct {}

@(private)
X11_State :: struct {
	// app.odin's x11_visible reads these, behind `backend == .X11`.
	mapped:   bool,
	obscured: bool,
}

@(private)
DARWIN_NOT_HERE :: "palmy on macOS opens a Cocoa window; Wayland and X11 are not built here"

@(private)
conn_close :: proc(c: ^Conn) {
	delete(c.rx)
	c.rx = nil
	c.fd = -1
}

@(private)
conn_flush :: proc(c: ^Conn) {}

@(private)
conn_read :: proc(c: ^Conn) -> bool {
	return false
}

@(private)
wl_dispatch_pending :: proc(c: ^Conn, w: ^Window) {}
@(private)
x_dispatch_pending :: proc(w: ^Window) {}

@(private)
wl_open :: proc(w: ^Window, decorate: bool) -> string {return DARWIN_NOT_HERE}
@(private)
x_open :: proc(w: ^Window, decorate: bool) -> string {return DARWIN_NOT_HERE}
@(private)
wl_close :: proc(w: ^Window) {}
@(private)
x_close :: proc(w: ^Window) {}
@(private)
wl_destroy_buffers :: proc(w: ^Window) {}
@(private)
x_destroy_buffers :: proc(w: ^Window) {}
@(private)
wl_alloc_buffers :: proc(w: ^Window) -> string {return DARWIN_NOT_HERE}
@(private)
x_alloc_buffers :: proc(w: ^Window) -> string {return DARWIN_NOT_HERE}
@(private)
wl_present :: proc(w: ^Window, b: ^Shm_Buffer, damage: []Damage_Rect) {}
@(private)
x_present :: proc(w: ^Window, b: ^Shm_Buffer) {}
@(private)
wl_set_title :: proc(w: ^Window) {}
@(private)
x_set_title :: proc(w: ^Window) {}
@(private)
wl_set_min_size :: proc(w: ^Window, width, height: int) {}
@(private)
x_set_min_size :: proc(w: ^Window, width, height: int) {}
@(private)
wl_set_fullscreen :: proc(w: ^Window, on: bool) {}
@(private)
x_set_fullscreen :: proc(w: ^Window, on: bool) {}
@(private)
wl_set_cursor :: proc(w: ^Window, want: Cursor) {}
@(private)
x_set_cursor :: proc(w: ^Window, want: Cursor) {}
