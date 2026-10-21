// The frame loop's two failure modes that only showed on a real machine.
//
// poll_fds: on arm64 `core:sys/linux.poll` builds ppoll's timespec from the
// i32 by unsigned casts, so "wait forever" (-1) became EINVAL and every idle
// palmy window ended its loop and quit. These tests ask the kernel, so on
// arm64 they fail against the old call and pass against the new one.
//
// frame_step: a window whose frame callback is withheld (hidden, on a
// workspace that is not shown) used to run no code at all, so a due
// `wake_after` — a password manager's idle lock — never fired. These pin the
// policy that replaced it: a due wake or input runs a logic frame, paint-only
// reasons park without a timeout, and nothing spins.
package palmy_tests

import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import p "../palmy"

@(private = "file")
eventfd :: proc(t: ^testing.T) -> linux.Fd {
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, err, linux.Errno.NONE)
	return fd
}

@(private = "file")
poke :: proc(fd: linux.Fd) {
	one := u64(1)
	linux.write(fd, (cast([^]u8)&one)[:8])
}

@(test)
test_poll_forever_waits_for_the_event :: proc(t: ^testing.T) {
	fd := eventfd(t)
	defer linux.close(fd)

	// Nothing ready, no timeout: it must block until another thread writes,
	// not fail at once (which is what EINVAL looked like).
	writer := thread.create_and_start_with_poly_data(fd, proc(fd: linux.Fd) {
		time.sleep(150 * time.Millisecond)
		poke(fd)
	})
	pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
	start := time.tick_now()
	n, err := p.poll_fds(pfd[:], -1)
	took := time.duration_milliseconds(time.tick_since(start))
	thread.join(writer)
	thread.destroy(writer)

	testing.expect_value(t, err, linux.Errno.NONE)
	testing.expect_value(t, n, i32(1))
	testing.expect(t, .IN in pfd[0].revents, "the descriptor is reported readable")
	testing.expectf(t, took >= 120, "it waited for the write (%.0f ms)", took)

	// Any negative timeout is forever, and something already ready returns
	// at once.
	pfd[0].revents = {}
	start = time.tick_now()
	n, err = p.poll_fds(pfd[:], -7)
	testing.expect_value(t, err, linux.Errno.NONE)
	testing.expect_value(t, n, i32(1))
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 50, "ready means no wait")
}

@(test)
test_poll_timeouts_are_milliseconds :: proc(t: ^testing.T) {
	fd := eventfd(t)
	defer linux.close(fd)
	pfd := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}

	start := time.tick_now()
	n, err := p.poll_fds(pfd[:], 0)
	testing.expect_value(t, err, linux.Errno.NONE)
	testing.expect_value(t, n, i32(0))
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 50, "zero does not wait")

	// Both fields of the timespec: whole seconds and the remainder.
	for ms in ([]int{120, 1080}) {
		start = time.tick_now()
		n, err = p.poll_fds(pfd[:], ms)
		took := time.duration_milliseconds(time.tick_since(start))
		testing.expect_value(t, err, linux.Errno.NONE)
		testing.expect_value(t, n, i32(0))
		testing.expectf(t, took >= f64(ms) - 5 && took < f64(ms) + 400, "%d ms took %.0f ms", ms, took)
	}
}

// A window state that never touched a display server: zeroed buffers are free.
@(private = "file")
fake_app :: proc(backend: p.Backend) -> ^p.App {
	app := new(p.App)
	app.win.backend = backend
	app.win.last_present = time.now()
	return app
}

@(private = "file")
LONG_AGO :: 10 * time.Second

@(test)
test_frame_step_idle_parks_forever :: proc(t: ^testing.T) {
	for be in p.Backend {
		app := fake_app(be)
		defer free(app)
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
	}
}

@(test)
test_frame_step_ready_server_paints :: proc(t: ^testing.T) {
	app := fake_app(.Wayland)
	defer free(app)
	app.win.wake_pending = true
	testing.expect_value(t, p.frame_step(app).kind, p.Frame_Step_Kind.Frame)

	app.win.wake_pending = false
	app.win.paint_owed = true
	testing.expect_value(t, p.frame_step(app).kind, p.Frame_Step_Kind.Frame)
}

@(test)
test_frame_step_due_wake_runs_while_hidden :: proc(t: ^testing.T) {
	for be in p.Backend {
		app := fake_app(be)
		defer free(app)
		w := &app.win
		w.frame_pending = true // the callback (or completion) never came
		w.last_present = time.time_add(time.now(), -LONG_AGO)

		w.wake_pending = true
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Logic, 0})

		w.wake_pending = false
		w.input_dirty = true
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Logic, 0})
	}
}

@(test)
test_frame_step_no_free_buffer_is_not_ready :: proc(t: ^testing.T) {
	app := fake_app(.Wayland)
	defer free(app)
	w := &app.win
	w.buffers[0].busy = true
	w.buffers[1].busy = true
	w.last_present = time.time_add(time.now(), -LONG_AGO)
	w.wake_pending = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Logic, 0})
}

@(test)
test_frame_step_visible_window_waits_for_its_callback :: proc(t: ^testing.T) {
	// Just presented: the callback is a vsync away, so a wake waits for it
	// (at most the grace) rather than running the app twice.
	app := fake_app(.Wayland)
	defer free(app)
	w := &app.win
	w.frame_pending = true
	w.wake_pending = true
	s := p.frame_step(app)
	testing.expect_value(t, s.kind, p.Frame_Step_Kind.Wait)
	testing.expectf(t, s.timeout_ms > 0 && s.timeout_ms <= 50, "a short wait, not forever: %d", s.timeout_ms)
}

@(test)
test_frame_step_logic_frames_are_rate_limited :: proc(t: ^testing.T) {
	// An app that wakes itself every frame while hidden gets at most one
	// logic frame per grace period, not a busy loop.
	app := fake_app(.Wayland)
	defer free(app)
	w := &app.win
	w.frame_pending = true
	w.last_present = time.time_add(time.now(), -LONG_AGO)
	w.last_logic = time.now()
	w.wake_pending = true
	s := p.frame_step(app)
	testing.expect_value(t, s.kind, p.Frame_Step_Kind.Wait)
	testing.expectf(t, s.timeout_ms > 0 && s.timeout_ms <= 50, "timeout %d", s.timeout_ms)
}

@(test)
test_frame_step_hidden_paint_only_parks :: proc(t: ^testing.T) {
	// Animating, redraw, `always`, a paint owed after a logic frame: none of
	// them is a reason to run code, so a hidden Wayland window sleeps until
	// the callback — no timeout, no 20 Hz poll.
	app := fake_app(.Wayland)
	defer free(app)
	w := &app.win
	w.frame_pending = true
	w.last_present = time.time_add(time.now(), -LONG_AGO)

	app.ctx.animating = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
	app.ctx.animating = false
	app.ctx.redraw = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
	app.ctx.redraw = false
	app.cfg.always = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
	app.cfg.always = false
	w.paint_owed = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
}

@(test)
test_frame_step_x11_keeps_its_watchdog :: proc(t: ^testing.T) {
	// X11's acknowledgement can be lost; the loop must wake to give up on it.
	app := fake_app(.X11)
	defer free(app)
	app.win.frame_pending = true
	app.ctx.animating = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, 50})
}

@(test)
test_frame_step_direct_never_runs_logic_frames :: proc(t: ^testing.T) {
	// A direct_frames app writes pixels; a frame without a buffer is
	// meaningless to it.
	app := fake_app(.Wayland)
	defer free(app)
	app.direct = true
	app.win.frame_pending = true
	app.win.last_present = time.time_add(time.now(), -LONG_AGO)
	app.win.wake_pending = true
	testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
}

@(test)
test_frame_step_hidden_x11_window_parks :: proc(t: ^testing.T) {
	// X11 has no frame callback to withhold and acknowledges a put to a
	// window nobody can see, so an animating window kept painting at the
	// 16 ms floor while minimised (measured under openbox: ~50 frames a
	// second, 7% of a core). Unmapped or fully obscured, it parks like a
	// Wayland window whose callback is withheld.
	for hide in 0 ..< 2 {
		app := fake_app(.X11)
		defer free(app)
		w := &app.win
		w.last_present = time.time_add(time.now(), -LONG_AGO)
		w.x.mapped = hide != 0
		w.x.obscured = hide != 0

		app.ctx.animating = true
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})
		app.ctx.animating = false
		w.paint_owed = true
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Wait, -1})

		// A due wake still runs, as a logic frame.
		w.wake_pending = true
		testing.expect_value(t, p.frame_step(app), p.Frame_Step{.Logic, 0})
		w.wake_pending = false

		// Back in view, the owed frame is painted.
		w.x.mapped = true
		w.x.obscured = false
		testing.expect_value(t, p.frame_step(app).kind, p.Frame_Step_Kind.Frame)
	}
}

@(test)
test_frame_step_first_frame_paints_even_when_hidden :: proc(t: ^testing.T) {
	// The first frame is never a logic frame, so it must not wait for the
	// window to be seen either: an app started behind another window would
	// otherwise run no code at all.
	app := fake_app(.X11)
	defer free(app)
	app.first = true
	app.win.last_present = time.time_add(time.now(), -LONG_AGO)
	testing.expect_value(t, p.frame_step(app).kind, p.Frame_Step_Kind.Frame)
}
