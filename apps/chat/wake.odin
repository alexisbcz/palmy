package main

// Waking the window instead of drawing at vsync.
//
// The client used to open its window with `always = true` and service the
// socket once per frame, because palmy's loop blocked in `poll` on the display
// socket alone and nothing else could end that sleep. That cost roughly 40%
// of a core for as long as the window was open, idle or not. palmy now has
// `wake`, safe from any thread, and `wake_after`, so the loop sleeps and is
// woken by the things that actually change what is on screen:
//
//   - data on the socket, noticed by `Sock_Watch` below, a thread that polls
//     the socket and wakes the loop when it becomes readable;
//   - deadlines, collected each frame by `schedule_wakes` on a real monotonic
//     clock: the reconnect countdown, a typing indicator expiring, going
//     away after 150 s idle, the token refresh, the toast.
//
// Everything is still *done* on the frame thread, exactly as before; the
// watcher only says when to look.

import "core:math"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import p "palmy:."

// START_TICK anchors `a.now` in a window. `ui.now` cannot be used: palmy clamps
// each frame's `dt` to 0.1 s, so once the loop sleeps between events it falls
// behind real time, and a five-second reconnect would take fifty frames.
START_TICK := time.tick_now()

mono :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(START_TICK))
}

// secs turns a number of seconds into a wake delay, plus a millisecond so the
// frame lands just after the deadline rather than just before it.
secs :: proc(s: f64) -> time.Duration {
	return time.Duration(max(s, 0) * f64(time.Second)) + time.Millisecond
}

// ---------------------------------------------------------------------------
// The socket watcher
// ---------------------------------------------------------------------------

// The longest single poll, in milliseconds. Finite on purpose: arm64 has no
// `poll` syscall, Odin's `linux.poll` turns -1 into an invalid `ppoll`
// timespec there, and the call fails with EINVAL.
WATCH_POLL_MS :: 5000

Sock_Watch :: struct {
	app:   ^p.App,
	th:    ^thread.Thread,
	kick:  linux.Fd, // eventfd: the socket changed, or stop
	fd:    i32,      // the socket to watch, -1 for none (atomic)
	armed: bool,     // the frame has drained what the last wake was for (atomic)
	arm:   sync.Sema,
	stop:  bool,     // atomic
	last:  i32,      // the frame thread's copy of `fd`
}

watch_start :: proc(w: ^Sock_Watch, app: ^p.App) -> bool {
	kick, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		return false
	}
	w.app = app
	w.kick = kick
	w.fd = -1
	w.last = -1
	w.armed = true
	w.th = thread.create_and_start_with_data(w, watch_run)
	return w.th != nil
}

watch_stop :: proc(w: ^Sock_Watch) {
	if w.th == nil {
		return
	}
	sync.atomic_store(&w.stop, true)
	watch_kick(w)
	sync.sema_post(&w.arm)
	thread.join(w.th)
	thread.destroy(w.th)
	w.th = nil
	linux.close(w.kick)
}

@(private = "file")
watch_kick :: proc(w: ^Sock_Watch) {
	one := u64(1)
	linux.write(w.kick, (cast([^]u8)&one)[:8])
}

// watch_frame is called by the frame after `net_pump` has drained the socket:
// it tells the watcher which socket is current and that it may watch again.
watch_frame :: proc(w: ^Sock_Watch, a: ^App) {
	if w.th == nil {
		return
	}
	fd := i32(-1)
	if a.link == .Online {
		fd = i32(a.sock)
	}
	if fd != w.last {
		w.last = fd
		sync.atomic_store(&w.fd, fd)
		watch_kick(w)
	}
	if !sync.atomic_load(&w.armed) {
		sync.atomic_store(&w.armed, true)
		sync.sema_post(&w.arm)
	}
}

@(private = "file")
watch_run :: proc(data: rawptr) {
	w := (^Sock_Watch)(data)
	for !sync.atomic_load(&w.stop) {
		if !sync.atomic_load(&w.armed) {
			// Woke the loop already; wait until a frame has drained it, or
			// a readable socket would wake it again and again meanwhile.
			sync.sema_wait(&w.arm)
			continue
		}
		pfd: [2]linux.Poll_Fd
		pfd[0] = {fd = w.kick, events = {.IN}}
		nfds := 1
		if fd := sync.atomic_load(&w.fd); fd >= 0 {
			pfd[1] = {fd = linux.Fd(fd), events = {.IN}}
			nfds = 2
		}
		n, err := linux.poll(pfd[:nfds], WATCH_POLL_MS)
		if err != .NONE || n <= 0 {
			continue
		}
		if pfd[0].revents != {} {
			// The socket changed (or we are stopping): drain and look again.
			buf: [8]u8
			linux.read(w.kick, buf[:])
			continue
		}
		if nfds == 2 && pfd[1].revents != {} {
			sync.atomic_store(&w.armed, false)
			p.wake(w.app)
		}
	}
}

// ---------------------------------------------------------------------------
// Deadlines
// ---------------------------------------------------------------------------

// schedule_wakes arms one wake for the nearest thing that will change the
// screen or needs doing on a clock. `wake_after` keeps the earliest of
// several requests, so each candidate is simply asked for.
schedule_wakes :: proc(ui: ^p.Ctx, a: ^App) {
	at :: proc(ui: ^p.Ctx, a: ^App, t: f64) {
		p.wake_after(ui, secs(t - a.now))
	}

	switch a.link {
	case .Offline:
		// The reconnect, and the "retrying in Ns" countdown, which reads
		// differently each time the remaining wait crosses a whole second.
		at(ui, a, a.retry_at)
		if wait := a.retry_at - a.now; wait > 0 {
			p.wake_after(ui, secs(wait - math.floor(wait)))
		}
	case .Connecting:
	case .Online:
		if !a.away && a.last_key > 0 {
			at(ui, a, a.last_key + 150) // goes away after 150 s without a key
		}
		if a.cloud && a.ck != nil {
			// The token is refreshed two minutes before it expires; while
			// that is failing, try once a second as cloud_tick always has.
			due := f64(a.token_exp - time.time_to_unix(time.now()) - 120)
			p.wake_after(ui, secs(max(due, 1)))
		}
	}

	if a.typing_on {
		at(ui, a, a.typing_at + 5) // the indicator we send stops claiming typing
	}
	for t in a.typers {
		at(ui, a, t.at + 6) // someone else's indicator expires
	}
	if a.toast != "" {
		at(ui, a, a.toast_t)
	}
}
