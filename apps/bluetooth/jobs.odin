package main

// One background command at a time, and a log of everything this applet has
// run.
//
// Every read in bt.odin returns in milliseconds, so it happens inside the
// frame. Two things do not: `bluetoothctl --timeout N scan on` blocks for the
// whole scan, and `connect` / `pair` block until BlueZ gives up. Those go
// through here: a worker thread runs the command, the frame loop polls one
// atomic, and the UI stays at 60fps with a spinner the entire time.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import kit "kit:."

Job_Kind :: enum {
	None,
	Scan,
	Power,
	Discoverable,
	Connect,
	Disconnect,
	Pair,
	Trust,
	Copy,
}

Job :: struct {
	// Written by the frame before the thread starts, read by the thread.
	argv:     []string,
	kind:     Job_Kind,
	label:    string,
	subject:  string, // the device address a device action applies to

	// Written by the thread, read by the frame once `finished` is seen.
	out:      string,
	ok:       bool,

	// The handshake. Only these two are touched atomically.
	running:  bool,
	finished: bool,
}

g_job: Job

// A short scrollback of what has actually been executed, which doubles as the
// applet's activity feed.
Log_Entry :: struct {
	cmd:  string,
	note: string,
	ok:   bool,
	used: bool,
}

LOG_N :: 48
g_log: [LOG_N]Log_Entry
g_log_at: int
g_log_count: int

log_command :: proc(argv: []string, note: string, ok: bool) {
	cmd := strings.join(argv, " ")
	e := &g_log[g_log_at % LOG_N]
	if e.used {
		delete(e.cmd)
		delete(e.note)
	}
	e^ = {cmd = cmd, note = strings.clone(note), ok = ok, used = true}
	g_log_at += 1
	g_log_count += 1
	// Also to stderr, so a run from a terminal leaves an auditable trail of
	// every command the applet issued.
	fmt.eprintfln("[bluetooth] %s%s", cmd, ok ? "" : "   (failed)")
}

// log_recent returns the last `n` entries, newest last.
log_recent :: proc(n: int, al := context.temp_allocator) -> []Log_Entry {
	count := min(n, min(g_log_count, LOG_N))
	out := make([]Log_Entry, count, al)
	for i in 0 ..< count {
		out[count - 1 - i] = g_log[(g_log_at - 1 - i + LOG_N * 4) % LOG_N]
	}
	return out
}

job_busy :: proc() -> bool {
	return sync.atomic_load(&g_job.running)
}

job_kind :: proc() -> Job_Kind {
	if !job_busy() {
		return .None
	}
	return g_job.kind
}

@(private = "file")
job_worker :: proc() {
	out, ok := kit.run(g_job.argv, context.allocator)
	g_job.out = out
	g_job.ok = ok
	sync.atomic_store(&g_job.finished, true)
}

// job_start takes ownership of a heap-allocated argv. It refuses while another
// job is in flight, so there is never more than one bluetoothctl in the air.
job_start :: proc(kind: Job_Kind, label, subject: string, argv: []string) -> bool {
	if job_busy() {
		for s in argv {delete(s)}
		delete(argv)
		return false
	}
	g_job.argv = argv
	g_job.kind = kind
	g_job.label = label
	g_job.subject = subject
	g_job.out = ""
	g_job.ok = false
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, true)
	thread.create_and_start(job_worker, self_cleanup = true)
	return true
}

// job_collect reports a finished job exactly once and clears it.
job_collect :: proc() -> (kind: Job_Kind, label, subject, out: string, ok: bool, got: bool) {
	if !sync.atomic_load(&g_job.running) || !sync.atomic_load(&g_job.finished) {
		return
	}
	kind = g_job.kind
	label = g_job.label
	subject = g_job.subject
	out = g_job.out
	ok = g_job.ok
	got = true

	log_command(g_job.argv, label, ok)

	for s in g_job.argv {delete(s)}
	delete(g_job.argv)
	g_job.argv = nil
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, false)
	return
}

// argv_own clones the words of a command onto the heap, because the worker
// thread outlives the frame arena they were built in.
argv_own :: proc(words: ..string) -> []string {
	out := make([]string, len(words))
	for w, i in words {
		out[i] = strings.clone(w)
	}
	return out
}

// ---------------------------------------------------------------------------
// Signal memory
//
// BlueZ only reports RSSI while discovery is running, and drops it the moment
// a scan ends — but it keeps the device in its cache for a while longer. The
// last strength each address advertised is remembered here so the list does
// not go blank the second the spinner stops.
// ---------------------------------------------------------------------------

SEEN_N :: 128

Seen :: struct {
	addr: [20]u8,
	n:    int,
	rssi: int,
	used: bool,
}

g_seen: [SEEN_N]Seen
g_seen_at: int

seen_note :: proc(addr: string, rssi: int) {
	for &e in g_seen {
		if e.used && string(e.addr[:e.n]) == addr {
			e.rssi = rssi
			return
		}
	}
	e := &g_seen[g_seen_at % SEEN_N]
	g_seen_at += 1
	n := min(len(addr), len(e.addr))
	copy(e.addr[:], addr[:n])
	e.n = n
	e.rssi = rssi
	e.used = true
}

seen_get :: proc(addr: string) -> (rssi: int, ok: bool) {
	for &e in g_seen {
		if e.used && string(e.addr[:e.n]) == addr {
			return e.rssi, true
		}
	}
	return 0, false
}
