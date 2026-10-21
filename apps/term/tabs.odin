package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:time"
import vt "./vt"

// ---------------------------------------------------------------------------
// Tabs.
//
// A tab is a terminal and the process behind it. Keeping the two together in
// one struct, with the UI holding only an index, is what makes the tab strip a
// seam rather than a special case: a split would be a tab holding two of
// these instead of one, and nothing above here would have to change.
// ---------------------------------------------------------------------------

Tab :: struct {
	term:      vt.Terminal,
	pty:       Pty,
	// The title the program asked for, via OSC 0/2. Empty means fall back to
	// the process name, which is what makes a tab say "vim" without the
	// program having to cooperate.
	osc_title: string,
	fallback:  string,
	// Set when the child is gone. The tab stays until it is closed by hand so
	// that whatever the command printed before it died is still readable.
	dead:      bool,
	exit_code: int,
	// When a close was asked for and the child was signalled, this is when.
	// If it is still alive a moment later it gets a harder signal.
	closing_at: time.Time,
	closing:   bool,
	// Per-tab read buffer, so a busy tab cannot starve the others.
	bytes_in:  u64,
	id:        int,
}

Session :: struct {
	tabs:       [dynamic]^Tab,
	active:     int,
	next_id:    int,
	cols, rows: int,
	scrollback: int,
	term_name:  string,
	shell:      []string,
	// The last directory a tab reported through OSC 7, used as the working
	// directory for the next new tab. Opening a tab in the directory you were
	// just in is the single most useful thing a tab strip can do.
	last_cwd:   string,
	// Text a program asked to put on the clipboard with OSC 52, picked up
	// by the frame loop. Reads are refused in the engine and never reach
	// here; see the note in terminal.odin.
	clipboard_request: string,
}

session_init :: proc(s: ^Session, cols, rows, scrollback: int, term_name: string, shell: []string) {
	s.tabs = make([dynamic]^Tab)
	s.cols = cols
	s.rows = rows
	s.scrollback = scrollback
	s.term_name = term_name
	s.shell = shell
}

session_destroy :: proc(s: ^Session) {
	for t in s.tabs {
		tab_destroy(t)
	}
	delete(s.tabs)
}

tab_open :: proc(s: ^Session, argv: []string = nil, cwd: string = "") -> (^Tab, string) {
	t := new(Tab)
	vt.terminal_init(&t.term, s.cols, s.rows, s.scrollback)
	t.term.gfx.load_file = kitty_read_file
	cmd := argv
	if len(cmd) == 0 {
		cmd = s.shell
	}
	dir := cwd
	if dir == "" {
		dir = s.last_cwd
	}
	if dir == "" {
		dir = os.get_env("HOME", context.temp_allocator)
	}
	env := child_env(s.term_name, nil)
	pty, err := pty_spawn(
		{argv = cmd, env = env, cwd = dir, cols = s.cols, rows = s.rows},
	)
	if err != "" {
		vt.terminal_destroy(&t.term)
		free(t)
		return nil, err
	}
	t.pty = pty
	t.fallback = strings.clone(base_name(cmd[0]))
	s.next_id += 1
	t.id = s.next_id
	append(&s.tabs, t)
	s.active = len(s.tabs) - 1
	return t, ""
}

tab_destroy :: proc(t: ^Tab) {
	pty_close(&t.pty)
	vt.terminal_destroy(&t.term)
	delete(t.osc_title)
	delete(t.fallback)
	free(t)
}

base_name :: proc(p: string) -> string {
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[i + 1:]
	}
	return p
}

// tab_title is what the strip shows: what the program asked for, or the name
// of whatever is running, or the shell.
tab_title :: proc(t: ^Tab) -> string {
	if t.dead {
		return fmt.tprintf("%s (exited)", t.fallback)
	}
	if t.osc_title != "" {
		return t.osc_title
	}
	if n := foreground_name(&t.pty); n != "" {
		return n
	}
	return t.fallback
}

// foreground_name asks the kernel which process currently owns the terminal,
// so a tab running `vim` says vim rather than the shell that launched it.
foreground_name :: proc(p: ^Pty) -> string {
	if p.master <= 0 {
		return ""
	}
	pgrp: i32
	// TIOCGPGRP
	if linux.ioctl(p.master, 0x540F, uintptr(&pgrp)) != 0 || pgrp <= 0 {
		return ""
	}
	path := fmt.tprintf("/proc/%d/comm", pgrp)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return ""
	}
	return strings.trim_space(string(data))
}

// ---------------------------------------------------------------------------
// Closing a tab that still has something running
//
// The decision, made deliberately: closing a tab hangs up the terminal the way
// unplugging a serial line would. The child's process group gets SIGHUP, which
// is what every shell is written to handle -- it writes its history out and
// exits, and anything it started under `nohup` or `disown` survives, which is
// exactly what those exist for. If the group is still there after a moment it
// gets SIGKILL, because a tab that will not close is worse than a process that
// did not get to clean up.
//
// The alternative -- silently orphaning the process -- was rejected: a build
// left running with nowhere to write its output is a thing that bites hours
// later, when the disk is full or the port is still bound.
// ---------------------------------------------------------------------------

CLOSE_GRACE :: 1500 * time.Millisecond

tab_request_close :: proc(t: ^Tab) {
	if t.dead {
		return
	}
	t.closing = true
	t.closing_at = time.now()
	pty_signal(&t.pty, .SIGHUP)
	// Closing the master makes the slave side report EIO, which wakes a
	// child that is blocked reading and ignoring signals.
	pty_close(&t.pty)
}

// tab_close_ready says whether a tab asked to close has actually gone.
tab_close_ready :: proc(t: ^Tab) -> bool {
	if t.dead {
		return true
	}
	if !t.closing {
		return false
	}
	if pty_reap(&t.pty) {
		return true
	}
	if time.since(t.closing_at) > CLOSE_GRACE {
		pty_signal(&t.pty, .SIGKILL)
		// One more chance to reap; if the process is unkillable it is in
		// uninterruptible sleep and nothing here can help.
		return pty_reap(&t.pty)
	}
	return false
}

session_close :: proc(s: ^Session, idx: int) {
	if idx < 0 || idx >= len(s.tabs) {
		return
	}
	t := s.tabs[idx]
	if !t.dead {
		tab_request_close(t)
	}
	tab_destroy(t)
	ordered_remove(&s.tabs, idx)
	if s.active >= len(s.tabs) {
		s.active = max(0, len(s.tabs) - 1)
	}
}

session_move :: proc(s: ^Session, from, to: int) {
	if from < 0 || from >= len(s.tabs) || to < 0 || to >= len(s.tabs) || from == to {
		return
	}
	t := s.tabs[from]
	ordered_remove(&s.tabs, from)
	inject_at(&s.tabs, to, t)
	s.active = to
}

session_select :: proc(s: ^Session, idx: int) {
	if idx >= 0 && idx < len(s.tabs) {
		s.active = idx
	}
}

session_next :: proc(s: ^Session) {
	if len(s.tabs) > 0 {
		s.active = (s.active + 1) % len(s.tabs)
	}
}

session_prev :: proc(s: ^Session) {
	if len(s.tabs) > 0 {
		s.active = (s.active + len(s.tabs) - 1) % len(s.tabs)
	}
}

session_active :: proc(s: ^Session) -> ^Tab {
	if s.active < 0 || s.active >= len(s.tabs) {
		return nil
	}
	return s.tabs[s.active]
}

session_resize :: proc(s: ^Session, cols, rows: int) {
	if cols == s.cols && rows == s.rows {
		return
	}
	s.cols = cols
	s.rows = rows
	for t in s.tabs {
		vt.terminal_resize(&t.term, cols, rows)
		pty_resize(&t.pty, cols, rows, t.term.gfx.cell_w, t.term.gfx.cell_h)
	}
}

READ_CHUNK :: 64 * 1024

// session_housekeeping is the part of the pump that belongs to the frame
// loop rather than the reader thread: titles, the working directory, and
// noticing that a child has gone. The bytes themselves are read in pump.odin,
// on its own thread, because the child must never wait for a frame.
session_housekeeping :: proc(s: ^Session) -> bool {
	changed := false
	for t in s.tabs {
		if t.term.title != "" && t.term.title != t.osc_title {
			delete(t.osc_title)
			t.osc_title = strings.clone(t.term.title)
			changed = true
		}
		if t.term.pwd != "" && t.term.pwd != s.last_cwd {
			delete(s.last_cwd)
			s.last_cwd = strings.clone(t.term.pwd)
		}
		if !t.dead && t.pty.master > 0 && pty_reap(&t.pty) {
			tab_mark_dead(t)
			changed = true
		}
		if t.term.clipboard_pending {
			t.term.clipboard_pending = false
			s.clipboard_request = strings.clone(t.term.clipboard_set)
		}
	}
	return changed
}

tab_mark_dead :: proc(t: ^Tab) {
	if t.dead {
		return
	}
	pty_reap(&t.pty)
	t.dead = true
	t.exit_code = pty_exit_code(&t.pty)
	pty_close(&t.pty)
	// Leave a line saying what happened. A window that simply goes blank
	// when a command dies is a window that loses the error message.
	msg := fmt.tprintf(
		"\r\n\x1b[2m[process exited with code %d — ctrl+shift+w to close]\x1b[0m\r\n",
		t.exit_code,
	)
	vt.terminal_feed(&t.term, transmute([]u8)msg)
}

session_write :: proc(s: ^Session, data: []u8) {
	t := session_active(s)
	if t == nil || t.dead {
		return
	}
	pty_write(&t.pty, data)
}

// session_fds collects the pty descriptors so the frame loop can wait on them
// alongside the display connection.
session_fds :: proc(s: ^Session, out: ^[dynamic]linux.Fd) {
	clear(out)
	for t in s.tabs {
		if !t.dead && t.pty.master > 0 {
			append(out, t.pty.master)
		}
	}
	slice.sort(out[:])
}
