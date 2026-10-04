package main

// Temperatures are the one reading here that is not cheap.
//
// /proc is a formatted snapshot of memory, so a pass over four hundred
// processes costs about 15 ms. A hwmon sensor is not: reading
// `/sys/class/hwmon/hwmon0/temp1_input` makes the kernel evaluate an ACPI
// method or talk to a chip over SMBus, and one pass over the seven devices on
// this machine measured 45 to 80 ms. That is three to five dropped frames,
// every second, for numbers that move by a degree a minute.
//
// So they are read on a worker thread on their own slower clock. The handshake
// is two atomic booleans and a slice: the thread owns the result until it sets
// `ready`, the frame owns it from the moment it takes it. One job can be in
// flight at a time and the frame never waits for it, so there is no lock here
// and nothing to deadlock on.

import "core:sync"
import "core:thread"

// How often the sensors are re-read. Slow on purpose.
TEMP_PERIOD :: 4.0

@(private = "file")
Temp_Job :: struct {
	running: bool, // atomic
	ready:   bool, // atomic
	out:     []Temp, // written by the thread, read once `ready` is seen
}

@(private = "file")
g_tj: Temp_Job

@(private = "file")
temp_worker :: proc() {
	// A thread-local scratch buffer: the shared one in sys.odin belongs to the
	// frame.
	buf := make([]u8, 8192)
	defer delete(buf)
	g_tj.out = temp_sample(buf, context.allocator)
	sync.atomic_store(&g_tj.ready, true)
}

// temps_kick starts a read unless one is already in flight.
temps_kick :: proc() -> bool {
	if sync.atomic_load(&g_tj.running) {
		return false
	}
	sync.atomic_store(&g_tj.ready, false)
	sync.atomic_store(&g_tj.running, true)
	thread.create_and_start(temp_worker, self_cleanup = true)
	return true
}

// temps_collect hands a finished reading over exactly once. The caller owns the
// slice and frees it with temps_free.
temps_collect :: proc() -> (out: []Temp, got: bool) {
	if !sync.atomic_load(&g_tj.running) || !sync.atomic_load(&g_tj.ready) {
		return nil, false
	}
	out = g_tj.out
	g_tj.out = nil
	sync.atomic_store(&g_tj.ready, false)
	sync.atomic_store(&g_tj.running, false)
	return out, true
}

// temps_free releases a reading the frame has finished with. Every Temp owns
// its own strings — see the clone in temp_sample — so each can be freed once.
temps_free :: proc(ts: []Temp) {
	for t in ts {
		delete(t.chip)
		delete(t.label)
	}
	delete(ts)
}

temps_busy :: proc() -> bool {
	return sync.atomic_load(&g_tj.running)
}
