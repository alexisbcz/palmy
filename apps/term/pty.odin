package main

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// The pseudo-terminal.
//
// What is shared between the platforms: the types, the window size, the exit
// status, and the child's environment. Opening the pty and running the child
// is in pty_linux.odin (raw ioctls on /dev/ptmx) and pty_darwin.odin (openpty
// and login_tty from libutil); `Fd`, `Pid` and `Signal` come from there too.
// ---------------------------------------------------------------------------

Winsize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

Pty :: struct {
	master: Fd,
	pid:    Pid,
	// Set once the child has been reaped. `status` is the wait status.
	exited: bool,
	status: u32,
	name:   string,
}

Pty_Config :: struct {
	argv:   []string,
	env:    []string,
	cwd:    string,
	cols:   int,
	rows:   int,
	// The size of a cell in pixels, so TIOCGWINSZ can answer in pixels too.
	// Image programs (kitten icat, chafa) size their output from it.
	cell_w: int,
	cell_h: int,
}

// winsize is the size the child is told, in cells and in pixels.
winsize :: proc(cols, rows, cell_w, cell_h: int) -> Winsize {
	c := max(cols, 1)
	r := max(rows, 1)
	return Winsize {
		row = u16(min(r, 65535)),
		col = u16(min(c, 65535)),
		xpixel = u16(clamp(c * cell_w, 0, 65535)),
		ypixel = u16(clamp(r * cell_h, 0, 65535)),
	}
}

pty_exit_code :: proc(p: ^Pty) -> int {
	if !p.exited {
		return -1
	}
	if p.status & 0x7F == 0 {
		return int((p.status >> 8) & 0xFF)
	}
	return 128 + int(p.status & 0x7F)
}

// ---------------------------------------------------------------------------
// The environment the child gets
// ---------------------------------------------------------------------------

// child_env builds the environment for the shell: this process's, with the
// terminal variables set and the ones that would lie about the terminal
// removed.
child_env :: proc(term: string, extra: []string) -> []string {
	out := make([dynamic]string)
	drop := [?]string {
		"TERM=",
		"COLORTERM=",
		"TERM_PROGRAM=",
		"TERM_PROGRAM_VERSION=",
		"LINES=",
		"COLUMNS=",
		"TERMCAP=",
	}
	env, _ := os.environ(context.temp_allocator)
	outer: for e in env {
		for d in drop {
			if len(e) >= len(d) && e[:len(d)] == d {
				continue outer
			}
		}
		append(&out, strings.clone(e))
	}
	append(&out, strings.clone(fmt.tprintf("TERM=%s", term)))
	append(&out, strings.clone("COLORTERM=truecolor"))
	append(&out, strings.clone("TERM_PROGRAM=palmy-term"))
	for e in extra {
		append(&out, strings.clone(e))
	}
	return out[:]
}

// find_on_path is the executable a bare command name resolves to on $PATH,
// or "" when there is none.
find_on_path :: proc(name: string) -> string {
	path := os.get_env("PATH", context.temp_allocator)
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" {
			continue
		}
		full := fmt.tprintf("%s/%s", dir, name)
		if os.exists(full) && !os.is_dir(full) {
			return full
		}
	}
	return ""
}

// default_shell picks what to run. The order matters: an explicit argument
// wins, then $SHELL, then a shell that certainly exists.
default_shell :: proc() -> []string {
	out := make([]string, 1)
	if sh := os.get_env("SHELL", context.temp_allocator); sh != "" {
		out[0] = strings.clone(sh)
	} else {
		out[0] = strings.clone("/bin/sh")
	}
	return out
}
