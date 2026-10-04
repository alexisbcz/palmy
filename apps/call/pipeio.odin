package call

// ---------------------------------------------------------------------------
// Children on pipes.
//
// Capture and playback are processes: ffmpeg for synthetic and camera sources,
// pw-record for the microphone, pw-play for the speakers. palmy's frame loop
// is single threaded and must not block, so every pipe is O_NONBLOCK and every
// read and write tolerates a short result.
//
// The pipe size matters as much as the pacing does. A default 64 KiB pipe
// holds 680 ms of 48 kHz mono PCM; if the producer ever runs ahead, the
// consumer reads data that is two thirds of a second old and no amount of
// jitter buffering downstream recovers it. The capture pipes are therefore
// shrunk to a stated number of bytes, so the worst case backlog is bounded by
// construction rather than by hope.
//
// FD_FLOOR is a workaround for a bug outside this application. When the
// compositor resizes a palmy window, palmy reallocates its shared-memory pool
// and closes a descriptor it no longer owns; if the number it closes has since
// been handed to one of these pipes, the next read returns EBADF and the
// capture process is gone. It is reproducible: float and resize the window
// three seconds into a call and both ends lose their microphone, silently,
// with the meter simply ceasing to move.
//
// palmy's own descriptors are opened at startup and are low, so every pipe
// here is moved above FD_FLOOR immediately after the child has its copy. The
// supervisor in main.odin restarts a leg that dies anyway, because a capture
// process can also die for reasons that are nobody's bug.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

Child :: struct {
	proc_:   os.Process,
	running: bool,
	// Exactly one of these is live, depending on the direction. They are raw
	// descriptors above FD_FLOOR rather than `^os.File`, because the point of
	// the dance in `lift` is to get out of the range palmy recycles.
	read_fd:  linux.Fd,
	write_fd: linux.Fd,
	argv:     string, // kept for the UI and for error messages
	last_errno: linux.Errno,
}

FD_FLOOR :: linux.Fd(64)

// lift moves a descriptor above FD_FLOOR and closes the original, so a stale
// close of a low descriptor elsewhere in the process cannot take it. Returns
// the original unchanged if the kernel will not oblige.
lift :: proc(f: ^os.File) -> linux.Fd {
	old := linux.Fd(os.fd(f))
	hi, err := linux.fcntl_dupfd_cloexec(old, linux.F_DUPFD_CLOEXEC, FD_FLOOR)
	if err != .NONE || hi < 0 {
		return old
	}
	os.close(f)
	return hi
}

set_nonblocking :: proc(fd: linux.Fd) {
	fl, err := linux.fcntl_getfl(fd, linux.F_GETFL)
	if err != .NONE {
		return
	}
	fl |= {.NONBLOCK}
	linux.fcntl_setfl(fd, linux.F_SETFL, fl)
}

set_pipe_size :: proc(fd: linux.Fd, bytes: int) -> int {
	got, err := linux.fcntl_setpipe_sz(fd, linux.F_SETPIPE_SZ, i32(bytes))
	if err != .NONE {
		// The kernel refuses anything below one page and anything above
		// /proc/sys/fs/pipe-max-size for an unprivileged process; either way
		// the existing size stands.
		cur, _ := linux.fcntl_getpipe_sz(fd, linux.F_GETPIPE_SZ)
		return int(cur)
	}
	return int(got)
}

// spawn_reader starts `argv` with its stdout on a pipe we read.
spawn_reader :: proc(argv: []string, pipe_bytes := 0) -> (c: Child, err: string) {
	r, w, perr := os.pipe()
	if perr != nil {
		return {}, "pipe failed"
	}
	p, serr := os.process_start({command = argv, stdout = w, stderr = nil, stdin = nil})
	// The write end belongs to the child now; holding a copy would mean the
	// read end never reports EOF when the child exits.
	os.close(w)
	if serr != nil {
		os.close(r)
		return {}, fmt.aprintf("could not start %s", argv[0])
	}
	c.proc_ = p
	c.running = true
	// The child already has its copy of the write end; this moves ours out of
	// the range something else in this process may close.
	c.read_fd = lift(r)
	set_nonblocking(c.read_fd)
	if pipe_bytes > 0 {
		set_pipe_size(c.read_fd, pipe_bytes)
	}
	c.argv = strings.join(argv, " ")
	return c, ""
}

// spawn_writer starts `argv` with its stdin on a pipe we write.
spawn_writer :: proc(argv: []string, pipe_bytes := 0) -> (c: Child, err: string) {
	r, w, perr := os.pipe()
	if perr != nil {
		return {}, "pipe failed"
	}
	p, serr := os.process_start({command = argv, stdin = r, stdout = nil, stderr = nil})
	os.close(r)
	if serr != nil {
		os.close(w)
		return {}, fmt.aprintf("could not start %s", argv[0])
	}
	c.proc_ = p
	c.running = true
	c.write_fd = lift(w)
	set_nonblocking(c.write_fd)
	if pipe_bytes > 0 {
		set_pipe_size(c.write_fd, pipe_bytes)
	}
	c.argv = strings.join(argv, " ")
	return c, ""
}

// child_read fills as much of `buf` as is available right now. `eof` means the
// child closed its stdout, which is how a capture failure surfaces.
child_read :: proc(c: ^Child, buf: []u8) -> (n: int, eof: bool) {
	if !c.running || c.read_fd <= 0 {
		return 0, true
	}
	for n < len(buf) {
		got, err := linux.read(c.read_fd, buf[n:])
		if err == .EAGAIN || err == .EWOULDBLOCK {
			break
		}
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			// Worth distinguishing: EOF means the child exited, anything else
			// means the descriptor itself went wrong under us.
			c.last_errno = err
			return n, true
		}
		if got == 0 {
			c.last_errno = .NONE
			return n, true
		}
		n += got
	}
	return n, false
}

// child_write pushes what it can and reports how much. A short write is the
// normal case, not an error: it is the consumer saying its buffer is full,
// which for pw-play is the 48 kHz clock speaking. The caller keeps the
// remainder and offers it again on the next tick.
child_write :: proc(c: ^Child, buf: []u8) -> (n: int, broken: bool) {
	if !c.running {
		return 0, true
	}
	for n < len(buf) {
		put, err := linux.write(c.write_fd, buf[n:])
		if err == .EAGAIN || err == .EWOULDBLOCK {
			break
		}
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return n, true // EPIPE: the player died
		}
		if put == 0 {
			break
		}
		n += put
	}
	return n, false
}

// child_pending is how many bytes are queued on a read pipe, which is the
// capture backlog in bytes and therefore the capture latency.
child_pending :: proc(c: ^Child) -> int {
	if !c.running {
		return 0
	}
	n: i32
	FIONREAD :: 0x541B
	if i64(linux.ioctl(c.read_fd, FIONREAD, uintptr(&n))) < 0 {
		return 0
	}
	return int(n)
}

child_stop :: proc(c: ^Child) {
	if !c.running {
		return
	}
	// Closing our end makes ffmpeg see EPIPE and pw-play see EOF, which is a
	// cleaner exit than a signal; the kill is the backstop.
	if c.read_fd > 0 {
		linux.close(c.read_fd)
		c.read_fd = 0
	}
	if c.write_fd > 0 {
		linux.close(c.write_fd)
		c.write_fd = 0
	}
	_ = os.process_kill(c.proc_)
	// Reap it, or the app accumulates zombies every time a device changes.
	_, _ = os.process_wait(c.proc_)
	c.running = false
	delete(c.argv)
	c.argv = ""
}

// pipe_size reports the capacity the kernel actually gave a pipe, which is
// rounded up to a page and clamped by /proc/sys/fs/pipe-max-size.
pipe_size :: proc(fd: linux.Fd) -> int {
	n, err := linux.fcntl_getpipe_sz(fd, linux.F_GETPIPE_SZ)
	if err != .NONE {
		return 0
	}
	return int(n)
}
