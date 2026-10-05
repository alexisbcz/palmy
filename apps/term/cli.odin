package main

import "core:os"
import "core:time"
import kit "kit:."
import vt "./vt"

// ---------------------------------------------------------------------------
// The command-line surface.
//
// Built on the convention in apps/kit/cli.odin, so the terminal declares its
// commands and the kit does the parsing, the --help, the --json, the exit
// codes and the audit record.
//
// There are three, and they all exist because a terminal is useful to things
// that are not people. `run` is the important one: it runs a full-screen
// program on a real pty with no window and prints the grid that program drew,
// which is how an agent can look at a TUI.
// ---------------------------------------------------------------------------

@(private = "file")
run_args := [?]kit.Param {
	{
		name = "command",
		kind = .String,
		help = "the program to run, and its arguments",
		required = true,
		variadic = true,
	},
}

@(private = "file")
grid_flags := [?]kit.Param {
	{name = "cols", kind = .Int, help = "columns in the grid", def = "80"},
	{name = "rows", kind = .Int, help = "rows in the grid", def = "24"},
	{name = "term", kind = .String, help = "what to set TERM to", def = "xterm-256color"},
	{name = "timeout", kind = .Int, help = "seconds to wait for the program", def = "10"},
}

@(private = "file")
run_out := [?]kit.Field {
	{name = "cols", kind = .Int, help = "columns in the grid"},
	{name = "rows", kind = .Int, help = "rows in the grid"},
	{name = "title", kind = .String, help = "the title the program asked for", opt = true},
	{
		name = "lines",
		kind = .Array,
		help = "the grid, one string per row",
		of = []kit.Field{{kind = .String}},
	},
	{name = "exit_code", kind = .Int, help = "what the program exited with", opt = true},
}

@(private = "file")
bench_args := [?]kit.Param {
	{name = "file", kind = .Path, help = "a file to feed to the engine", required = true},
}

@(private = "file")
bench_flags := [?]kit.Param {
	{name = "cols", kind = .Int, help = "columns in the grid", def = "80"},
	{name = "rows", kind = .Int, help = "rows in the grid", def = "24"},
	{name = "scrollback", kind = .Int, help = "lines of history to keep", def = "10000"},
	{name = "font-size", kind = .Int, help = "point size for the render timings", def = "14"},
}

@(private = "file")
bench_out := [?]kit.Field {
	{name = "bytes", kind = .Int, help = "how much was fed in"},
	{name = "seconds", kind = .Float, help = "how long the engine took"},
	{name = "mb_per_second", kind = .Float, help = "throughput"},
	{name = "full_frame_ms", kind = .Float, help = "a frame with every cell dirty"},
	{name = "one_line_frame_ms", kind = .Float, help = "a frame with one row dirty"},
}

@(private = "file")
shots_args := [?]kit.Param {
	{name = "directory", kind = .Path, help = "where to write the PNGs", required = true},
}

@(private = "file")
shots_flags := [?]kit.Param {
	{name = "font-size", kind = .Int, help = "point size of the grid font", def = "14"},
}

@(private = "file")
shots_out := [?]kit.Field {
	{
		name = "files",
		kind = .Array,
		help = "the PNGs written",
		of = []kit.Field{{kind = .String}},
	},
}

@(private = "file")
commands := [?]kit.Command {
	{
		verb = "run",
		summary = "run a program on a pty with no window and print the screen it drew",
		effect = .Mutate,
		args = run_args[:],
		flags = grid_flags[:],
		out = run_out[:],
		examples = {"term run -- ls --color=always /usr", "term run --json --rows 40 -- htop -b -n 1"},
		run = cmd_run,
	},
	{
		verb = "bench",
		summary = "feed a file to the engine and report throughput and frame cost",
		effect = .Read,
		args = bench_args[:],
		flags = bench_flags[:],
		out = bench_out[:],
		examples = {"term bench /tmp/big.txt", "term bench --json --cols 200 --rows 50 /tmp/big.txt"},
		run = cmd_bench_cli,
	},
	{
		verb = "shots",
		summary = "render the documentation screenshots",
		effect = .Mutate,
		args = shots_args[:],
		flags = shots_flags[:],
		out = shots_out[:],
		examples = {"term shots docs"},
		run = cmd_shots_cli,
	},
}

term_surface :: proc() -> kit.Surface {
	return kit.Surface {
		noun = "term",
		summary = "a terminal emulator",
		commands = commands[:],
		selftest = selftest,
		gui = true,
		notes = WINDOW_NOTES,
	}
}

WINDOW_NOTES :: `With no command, term opens a window.

  term                      a window running $SHELL
  term -e CMD [ARG...]      a window running CMD instead
  --term NAME               what to set TERM to (default xterm-256color)
  --scrollback N            lines of history to keep (default 10000)
  --font-size N             point size of the grid font (default 14)
  --tabs                    always show the tab strip, even with one tab

In the window: ctrl+shift+t new tab, ctrl+shift+w close, ctrl+tab next,
ctrl+shift+tab previous, ctrl+shift+left/right move, alt+1..9 jump,
ctrl+shift+c/v copy and paste, shift+pgup/pgdn scroll, ctrl+plus/minus/0 size.`

// ---------------------------------------------------------------------------

@(private = "file")
cmd_run :: proc(c: ^kit.Call) -> int {
	argv := kit.cli_rest(c)
	if len(argv) == 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "no program to run")
	}
	opt := Options {
		term       = kit.cli_str(c, "term"),
		cols       = kit.cli_int(c, "cols", 80),
		rows       = kit.cli_int(c, "rows", 24),
		scrollback = 1000,
		argv       = argv,
	}
	timeout := time.Duration(max(kit.cli_int(c, "timeout", 10), 1)) * time.Second

	if c.dry_run {
		c.out = kit.jobj()
		kit.jset_int(c.out, "cols", opt.cols)
		kit.jset_int(c.out, "rows", opt.rows)
		kit.jset(c.out, "lines", kit.jarr())
		return kit.EXIT_OK
	}

	t: vt.Terminal
	vt.terminal_init(&t, opt.cols, opt.rows, opt.scrollback)
	defer vt.terminal_destroy(&t)

	env := child_env(opt.term, nil)
	pty, err := pty_spawn({argv = argv, env = env, cols = opt.cols, rows = opt.rows})
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	defer pty_close(&pty)

	buf: [64 * 1024]u8
	start := time.now()
	for time.since(start) < timeout {
		n, done := pty_read(&pty, buf[:])
		if n > 0 {
			vt.terminal_feed(&t, buf[:n])
			if out := vt.terminal_take_output(&t); out != nil {
				pty_write(&pty, out)
				delete(out)
			}
			continue
		}
		if done {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	pty_reap(&pty)

	o := kit.jobj()
	kit.jset_int(o, "cols", opt.cols)
	kit.jset_int(o, "rows", opt.rows)
	if t.title != "" {
		kit.jset_str(o, "title", t.title)
	}
	lines := kit.jarr()
	for y in 0 ..< opt.rows {
		kit.jpush(lines, kit.jstr(vt.terminal_line(&t, y, context.temp_allocator)))
	}
	kit.jset(o, "lines", lines)
	if code := pty_exit_code(&pty); code >= 0 {
		kit.jset_int(o, "exit_code", code)
	}
	c.out = o
	// The kit prints it, in whichever form was asked for. A command
	// produces one result and never two.
	return kit.EXIT_OK
}

@(private = "file")
cmd_bench_cli :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "file")
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no such file: %s", path)
	}
	opt := Options {
		cols       = kit.cli_int(c, "cols", 80),
		rows       = kit.cli_int(c, "rows", 24),
		scrollback = kit.cli_int(c, "scrollback", vt.DEFAULT_SCROLLBACK),
		font_size  = f32(kit.cli_int(c, "font-size", 14)),
		json       = c.json,
	}
	res, code := bench(path, opt, !c.json)
	if code != 0 {
		return kit.cli_fail(c, code)
	}
	o := kit.jobj()
	kit.jset_int(o, "bytes", res.bytes)
	kit.jset_num(o, "seconds", res.seconds)
	kit.jset_num(o, "mb_per_second", res.mb_per_second)
	kit.jset_num(o, "full_frame_ms", res.full_frame_ms)
	kit.jset_num(o, "one_line_frame_ms", res.one_line_frame_ms)
	c.out = o
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots_cli :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "directory")
	opt := Options {
		term       = "xterm-256color",
		cols       = 80,
		rows       = 24,
		scrollback = 2000,
		font_size  = f32(kit.cli_int(c, "font-size", 14)),
	}
	if c.dry_run {
		c.out = kit.jobj()
		kit.jset(c.out, "files", kit.jarr())
		return kit.EXIT_OK
	}
	files, code := shots(dir, opt, !c.json)
	if code != 0 {
		return kit.cli_failf(c, code, "could not write the screenshots to %s", dir)
	}
	o := kit.jobj()
	arr := kit.jarr()
	for f in files {
		kit.jpush(arr, kit.jstr(f))
	}
	kit.jset(o, "files", arr)
	c.out = o
	return kit.EXIT_OK
}
