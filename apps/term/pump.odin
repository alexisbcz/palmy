package main

import "core:sync"
import "core:thread"
import pal "palmy:."
import vt "./vt"

// ---------------------------------------------------------------------------
// The reader thread.
//
// Reading the pty from the frame body caps throughput at the frame rate times
// the pty's buffer: measured at 1.9 MB/s against foot's 30 MB/s on the same
// `cat`, because a child that fills the kernel's pipe buffer then blocks until
// the next vsync lets us drain it. The child should never wait for the
// compositor.
//
// So the reading happens here, on its own thread, as fast as the child can
// write. The engine is fed under a mutex and the frame loop is nudged through
// a self-pipe, which is the one thing a sleeping poll() can be woken by
// without palmy's help.
//
// When `wake(app)` and `wake_at(app, when)` land in palmy/app.odin, the pipe
// goes away: `signal` calls `wake(app)` instead, the frame loop stops being
// marked animating, and `wait_for_work` disappears entirely. Nothing else in
// this file changes. That is the whole of what this terminal needs from the
// toolkit -- see the report.
// ---------------------------------------------------------------------------

Pump :: struct {
	mu:      sync.Mutex,
	sess:    ^Session,
	wake_r:  Fd,
	wake_w:  Fd,
	th:      ^thread.Thread,
	running: bool,
	// Set by the reader when a terminal changed, read and cleared by the
	// frame loop. Both are under the mutex.
	dirty:   bool,
	// The window, for sys_wake_loop on macOS, where there is no display
	// descriptor beside the pipe to poll and the reader wakes palmy instead.
	app:     ^pal.App,
}

pump_start :: proc(p: ^Pump, s: ^Session) -> bool {
	r, w, ok := sys_pipe()
	if !ok {
		return false
	}
	p.wake_r, p.wake_w = r, w
	p.sess = s
	p.running = true
	p.th = thread.create_and_start_with_poly_data(p, pump_loop)
	return p.th != nil
}

pump_stop :: proc(p: ^Pump) {
	if !p.running {
		return
	}
	sync.lock(&p.mu)
	p.running = false
	sync.unlock(&p.mu)
	pump_signal(p)
	if p.th != nil {
		thread.join(p.th)
		thread.destroy(p.th)
		p.th = nil
	}
	sys_close(p.wake_r)
	sys_close(p.wake_w)
}

// pump_signal makes the frame loop's poll() return. Writes are coalesced by
// the drain on the other side, and a full pipe means a wakeup is already
// pending, so the EAGAIN is the right answer rather than an error.
pump_signal :: proc(p: ^Pump) {
	sys_wake_loop(p)
}

pump_drain :: proc(p: ^Pump) {
	sys_drain(p.wake_r)
}

@(private = "file")
pump_loop :: proc(p: ^Pump) {
	// 64 KB at a time: big enough that the syscall overhead disappears,
	// small enough that the frame loop never waits long for the mutex.
	buf: [64 * 1024]u8
	pfds := make([dynamic]Fd)
	defer delete(pfds)
	ready := make([dynamic]bool)
	defer delete(ready)
	tabs := make([dynamic]^Pane)
	defer delete(tabs)

	for {
		sync.lock(&p.mu)
		if !p.running {
			sync.unlock(&p.mu)
			return
		}
		clear(&tabs)
		clear(&pfds)
		for t in p.sess.panes {
			if !t.dead && t.pty.master > 0 {
				append(&tabs, t)
				append(&pfds, t.pty.master)
			}
		}
		sync.unlock(&p.mu)

		if len(pfds) == 0 {
			// Nothing to read from. Wait a little rather than spinning; a
			// new tab will be along shortly or the app is shutting down.
			sys_nap_20ms()
			continue
		}

		resize(&ready, len(pfds))
		for &r in ready {
			r = false
		}
		n, fatal := sys_poll_in(pfds[:], ready[:], 50)
		if fatal {
			return
		}
		if n <= 0 {
			continue
		}

		changed := false
		for i in 0 ..< len(pfds) {
			if !ready[i] {
				continue
			}
			t := tabs[i]
			// Drain this descriptor completely. The child is writing as
			// fast as it can and the whole point of this thread is that it
			// never has to wait for us.
			//
			// The read happens under the mutex along with the feed: the
			// frame loop can close a tab at any moment, and a read from a
			// descriptor that has been closed and reused is the kind of bug
			// that shows up once a week as somebody else's bytes.
			for {
				sync.lock(&p.mu)
				if !tab_still_live(p.sess, t) || t.dead || t.pty.master <= 0 {
					sync.unlock(&p.mu)
					break
				}
				got, done := pty_read(&t.pty, buf[:])
				if got > 0 {
					vt.terminal_feed(&t.term, buf[:got])
					t.bytes_in += u64(got)
					if out := vt.terminal_take_output(&t.term); out != nil {
						pty_write(&t.pty, out)
						delete(out)
					}
				}
				if done {
					pane_mark_dead(t)
				}
				sync.unlock(&p.mu)
				if got > 0 {
					changed = true
					continue
				}
				if done {
					changed = true
				}
				break
			}
		}
		if changed {
			sync.lock(&p.mu)
			p.dirty = true
			sync.unlock(&p.mu)
			pump_signal(p)
		}
	}
}

// tab_still_live guards against a tab being closed by the frame loop between
// the poll and the read.
@(private = "file")
tab_still_live :: proc(s: ^Session, t: ^Pane) -> bool {
	for x in s.panes {
		if x == t {
			return true
		}
	}
	return false
}
