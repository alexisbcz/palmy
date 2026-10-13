package install_core

// Running the programs the installer does not reimplement: mkfs.fat,
// mkfs.ext4 and palm.
//
// Each runs with stdout and stderr on one pipe that we read line by line, so
// every line lands in the log as it is written (a failed mkfs explains
// itself there) and a caller can turn lines into progress — palm says
// "installing <pkg> <ver>" once per package, after printing the plan.

import "core:fmt"
import "core:os"
import "core:strings"

// find_program looks a name up in PATH, then in the directories a root shell
// on Palmframe would have, so the installer works from a service with a
// minimal environment too. A name with a slash is taken as given.
find_program :: proc(name: string) -> string {
	if strings.contains_rune(name, '/') {
		return name
	}
	dirs := make([dynamic]string, context.temp_allocator)
	if path, ok := os.lookup_env("PATH", context.temp_allocator); ok {
		for d in strings.split(path, ":", context.temp_allocator) {
			if d != "" {append(&dirs, d)}
		}
	}
	append(&dirs, "/usr/bin", "/usr/sbin", "/bin", "/sbin")
	for d in dirs {
		p := join(d, name)
		if os.is_file(p) {
			return strings.clone(p, context.temp_allocator)
		}
	}
	return ""
}

// run executes argv, logging every line it prints and handing each to
// `on_line` if given. Returns "" on exit status 0, else a one-line reason
// that includes the program's last line of output.
@(private)
run :: proc(c: ^Ctx, argv: []string, on_line: proc(c: ^Ctx, line: string) = nil) -> string {
	logf(c, "$ %s", strings.join(argv, " ", context.temp_allocator))
	if c.o.dry_run {
		return ""
	}
	exe := find_program(argv[0])
	if exe == "" {
		return fmt.tprintf("%s: not found (is its package installed on this system?)", argv[0])
	}
	cmd := make([]string, len(argv), context.temp_allocator)
	copy(cmd, argv)
	cmd[0] = exe

	r, w, perr := os.pipe()
	if perr != nil {
		return fmt.tprintf("pipe: %v", perr)
	}
	null, _ := os.open("/dev/null", {.Read})
	defer if null != nil {os.close(null)}
	proc_, serr := os.process_start(os.Process_Desc{command = cmd, stdin = null, stdout = w, stderr = w})
	os.close(w)
	if serr != nil {
		os.close(r)
		return fmt.tprintf("%s: %v", argv[0], serr)
	}

	last := ""
	pending := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	emit :: proc(c: ^Ctx, line: string, on_line: proc(c: ^Ctx, line: string), last: ^string) {
		l := strings.trim_right(line, "\r")
		logf(c, "  %s", l)
		if strings.trim_space(l) != "" {
			last^ = strings.clone(l, context.temp_allocator)
		}
		if on_line != nil {
			on_line(c, l)
		}
	}
	for {
		n, rerr := os.read(r, buf[:])
		if n > 0 {
			append(&pending, ..buf[:n])
			for {
				i := -1
				for b, k in pending {
					if b == '\n' {i = k; break}
				}
				if i < 0 {break}
				emit(c, string(pending[:i]), on_line, &last)
				remove_range(&pending, 0, i + 1)
			}
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	if len(pending) > 0 {
		emit(c, string(pending[:]), on_line, &last)
	}
	os.close(r)
	state, werr := os.process_wait(proc_)
	if werr != nil {
		return fmt.tprintf("%s: %v", argv[0], werr)
	}
	if !state.exited || state.exit_code != 0 {
		if last != "" {
			return fmt.tprintf("%s exited with status %d: %s", argv[0], state.exit_code, last)
		}
		return fmt.tprintf("%s exited with status %d", argv[0], state.exit_code)
	}
	return ""
}
