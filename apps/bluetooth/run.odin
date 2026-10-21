package main

// Every bluetoothctl call goes through here, with a deadline.
//
// bluetoothctl talks to bluetoothd over D-Bus, and when there is no
// bluetoothd — a container, a VM, a machine where the service is stopped —
// it does not fail: it prints "Waiting to connect to bluetoothd..." and waits
// forever. kit.run waits with it, so a `bluetooth status` or the window's
// first reload hung for good. bt_run starts the child itself, reads its
// output as it arrives, and kills it at the deadline. A call that times out
// is reported as BlueZ not answering — "unavailable", exit 6 on the command
// line, a status line in the window — rather than as an empty adapter.
//
// After one read times out, the reads that would follow in the same reload
// (`devices`, then `info` per device) are skipped instead of each waiting out
// its own deadline: `bluez_silent` is set by the timeout and cleared by the
// next call that answers. read_adapter's `show` always tries, so a reload
// after bluetoothd starts finds it again.

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import kit "kit:."

// A read normally answers in a few milliseconds; two seconds is two orders of
// magnitude of headroom for a loaded machine, and short enough that a window
// started without bluetoothd shows "not answering" before anyone wonders.
READ_TIMEOUT :: 2 * time.Second

// connect and pair block until BlueZ gives up on the device (about 30 s for a
// page timeout); a minute covers that without leaving a job in flight for
// ever. A scan carries its own --timeout, and gets this much past it.
JOB_TIMEOUT :: 60 * time.Second
SCAN_GRACE :: 10 * time.Second

g_bluez_silent: bool // atomic: the last bluetoothctl call timed out

bluez_silent :: proc() -> bool {
	return sync.atomic_load(&g_bluez_silent)
}

// bt_run is kit.run with a deadline. It consults the CLI guard exactly as
// kit.run does, so an intent-class command still executes nothing. `timed_out`
// is true when the child was killed at the deadline; `ok` is a clean exit 0.
bt_run :: proc(
	argv: []string,
	limit: time.Duration,
	allocator := context.allocator,
) -> (
	out: string,
	ok: bool,
	timed_out: bool,
) {
	if why := kit.cli_guard_check(argv); why != "" {
		// kit.run refuses, records and reports it exactly as the kit does
		// everywhere else, and spawns nothing.
		_, _ = kit.run(argv, context.temp_allocator)
		return "", false, false
	}
	r, w, perr := os.pipe()
	if perr != nil {
		return "", false, false
	}
	defer os.close(r)
	proc_, serr := os.process_start({command = argv, stdout = w})
	os.close(w)
	if serr != nil {
		return "", false, false
	}

	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	chunk: [4096]u8
	deadline := time.tick_add(time.tick_now(), limit)
	state: os.Process_State
	for {
		// Drain whatever is there, so a chatty child never blocks on a
		// full pipe while we wait for it to exit.
		for {
			has, herr := os.pipe_has_data(r)
			if herr != nil || !has {
				break
			}
			n, rerr := os.read(r, chunk[:])
			if n > 0 {
				append(&buf, ..chunk[:n])
			}
			if rerr != nil || n <= 0 {
				break
			}
		}
		st, werr := os.process_wait(proc_, 10 * time.Millisecond)
		if werr == nil && st.exited {
			state = st
			break
		}
		if werr != nil && werr != .Timeout {
			break
		}
		if time.tick_since(deadline) >= 0 {
			_ = os.process_kill(proc_)
			_, _ = os.process_wait(proc_)
			sync.atomic_store(&g_bluez_silent, true)
			return "", false, true
		}
	}
	// The child has exited; whatever is left in the pipe is the tail. Only
	// what is already there is read, so a grandchild that kept the pipe open
	// cannot turn this into the hang it replaces.
	for {
		has, herr := os.pipe_has_data(r)
		if herr != nil || !has {
			break
		}
		n, rerr := os.read(r, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	sync.atomic_store(&g_bluez_silent, false)
	text := strings.trim_space(string(buf[:]))
	return strings.clone(text, allocator), state.exit_code == 0, false
}

// bt_lines is kit.run_lines over bt_run, with the read deadline.
bt_lines :: proc(argv: []string, allocator := context.allocator) -> (lines: []string, ok: bool, timed_out: bool) {
	text, good, late := bt_run(argv, READ_TIMEOUT, context.temp_allocator)
	if late {
		return nil, false, true
	}
	if !good && text == "" {
		return nil, false, false
	}
	keep := make([dynamic]string, allocator)
	for l in strings.split_lines(text, context.temp_allocator) {
		t := strings.trim_space(l)
		if t != "" {
			append(&keep, strings.clone(t, allocator))
		}
	}
	return keep[:], good, false
}
