package main

// Running things, and the two sinks everything writes through.
//
// stdout carries machine output and nothing else -- that is the rule from
// docs/PALM-CLI.md, and it is why a child process's stdout is pointed at
// stderr below. A pipeline reading `palm pkg diff --json` must never have to
// strip pacman's progress bars out of a JSON document.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"

// When set, out() and the JSON writer append here instead of printing. The
// self-test uses it to read back exactly what a verb emitted.
g_capture: ^strings.Builder

out :: proc(format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	if g_capture != nil {
		strings.write_string(g_capture, s)
		return
	}
	fmt.print(s)
}

outln :: proc(format: string = "", args: ..any) {
	out(format, ..args)
	out("\n")
}

// note goes to stderr: progress, warnings, anything a person wants and a
// parser does not.
note :: proc(format: string, args: ..any) {
	fmt.eprintf("[pkg] ")
	fmt.eprintfln(format, ..args)
}

// run_query runs a read-only command and returns its stdout. Nothing routed
// through here may change the machine; the planner owns everything that can.
run_query :: proc(argv: []string, allocator := context.allocator) -> (text: string, ok: bool) {
	state, sout, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil {
		return "", false
	}
	_ = serr
	return strings.clone(string(sout), allocator), state.exit_code == 0
}

// is_a_person reports whether there is a terminal on the other end, which is
// the condition `upgrade` and `rollback` require.
//
// PALM_PKG_NONINTERACTIVE overrides it -- "1" forces no, "0" forces yes -- so
// that both branches are reachable from a test and from CI. It cannot be used
// to skip a refusal that is about --yes; it only answers "is a person here".
is_a_person :: proc() -> bool {
	switch os.get_env("PALM_PKG_NONINTERACTIVE", context.temp_allocator) {
	case "1":
		return false
	case "0":
		return true
	}
	return terminal.is_terminal(os.stdin)
}

// exec_plan runs a plan's steps in order and stops at the first failure.
//
// The child inherits stdin so that sudo can ask for a password on the user's
// own terminal. This program never reads, stores, embeds or passes one: sudo
// talks to the person directly, and if it is not satisfied the step fails and
// the plan stops.
exec_plan :: proc(p: ^Plan) -> (ran: int, code: int) {
	for s, i in p.steps {
		line := strings.join(s.argv, " ", context.temp_allocator)
		note("running: %s", line)
		proc_h, err := os.process_start(
			os.Process_Desc {
				command = s.argv,
				stdin = os.stdin,
				// Child chatter goes to stderr so stdout stays machine-only.
				stdout = os.stderr,
				stderr = os.stderr,
			},
		)
		if err != nil {
			note("could not start %s: %v", s.argv[0], err)
			return i, EXIT_UNAVAILABLE
		}
		state, werr := os.process_wait(proc_h)
		if werr != nil {
			note("could not wait on %s: %v", s.argv[0], werr)
			return i, EXIT_FAILED
		}
		if state.exit_code != 0 {
			note("%s exited %d; stopping before the remaining %d step(s)", s.argv[0], state.exit_code, len(p.steps) - i - 1)
			return i, EXIT_FAILED
		}
	}
	return len(p.steps), EXIT_OK
}
