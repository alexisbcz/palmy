package main

// The command-line front end of the system monitor.
//
// It is the same sampler the window draws from, reached without a window:
// `sample` fills a Model exactly as the frame loop does, and `build_view`
// filters and sorts the process table exactly as the table on screen is
// filtered and sorted. There is no second reader of /proc here, so the
// numbers `sysmon status` prints and the numbers the window shows cannot
// disagree.
//
// Every command is `read`, apart from `shot`, which writes the PNG it was
// asked for. This monitor has no kill, no renice and no signal — in the
// window or here — and the self-test proves it rather than saying it: a child
// process is started, every command is run with fake `kill`, `pkill`,
// `killall` and `renice` binaries first on PATH, and the child is still alive
// and the sentinel those fakes write to is still empty afterwards.

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

// See apps/kit/cli.odin: the commands are a package variable and every field
// list is a self-contained literal, so nothing here is captured empty by the
// order package initialisers happen to run in.
@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "CPU, memory, load, network, disks and temperatures, from /proc and /sys",
		effect = .Read,
		flags = {
			{
				name = "interval",
				kind = .Float,
				help = "seconds between the two samples a rate needs",
				def = "0.5",
			},
		},
		out = STATUS_FIELDS,
		examples = {"sysmon status --json", "sysmon status --interval 1"},
		run = cmd_status,
	},
	{
		verb = "ps",
		summary = "the process table, filtered and sorted as the window does it",
		effect = .Read,
		flags = {
			{
				name = "sort",
				kind = .Enum,
				values = {"cpu", "mem", "pid", "name", "threads", "user"},
				help = "the column to sort on",
				def = "cpu",
			},
			{name = "asc", kind = .Bool, help = "ascending rather than descending"},
			{name = "filter", kind = .String, help = "name, user, command line or pid contains this"},
			{name = "kernel", kind = .Bool, help = "include kernel threads"},
			{name = "idle", kind = .Bool, help = "include processes under 0.05% CPU", def = "true"},
			{name = "limit", kind = .Int, help = "at most this many rows; 0 for all", def = "25"},
			{name = "interval", kind = .Float, help = "seconds between the two samples CPU% needs", def = "0.5"},
		},
		out = PS_FIELDS,
		examples = {
			"sysmon ps --json",
			"sysmon ps --sort mem --limit 10",
			"sysmon ps --filter sleep --no-idle --json",
		},
		run = cmd_ps,
	},
	{
		verb = "proc",
		summary = "one process, by pid",
		effect = .Read,
		args = {{name = "pid", kind = .Int, help = "the process id", required = true}},
		flags = {{name = "interval", kind = .Float, help = "seconds between the two samples CPU% needs", def = "0.5"}},
		out = PROC_FIELDS,
		examples = {"sysmon proc 1 --json"},
		run = cmd_proc,
	},
	{
		verb = "shot",
		summary = "render one frame offscreen to a PNG",
		effect = .Mutate,
		aliases = {"--shot"},
		args = {
			{name = "path", kind = .Path, help = "the PNG to write", required = true},
			{name = "keys", kind = .String, help = "keys to press first", variadic = true},
		},
		out = {{name = "path", kind = .String, help = "the file written"}},
		examples = {"sysmon shot /tmp/sysmon.png", "sysmon shot /tmp/sysmon-help.png ?"},
		run = cmd_shot,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "sysmon",
			summary  = "processes, memory, load, network and disks — read from the kernel, never changed",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Every number comes out of /proc and /sys through the same sampler the window
draws from. Rates (CPU%, network) are differences, so each command samples
twice, --interval seconds apart. There is no kill, renice or signal verb, in
this program or its window: a monitor that can only look cannot be the thing
that took a process down.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

STATUS_FIELDS := []kit.Field {
	{
		name = "host",
		kind = .Object,
		of = {
			{name = "hostname", kind = .String},
			{name = "kernel", kind = .String},
			{name = "cpu_model", kind = .String},
			{name = "cores", kind = .Int},
			{name = "threads", kind = .Int},
			{name = "distro", kind = .String},
		},
	},
	{name = "uptime_seconds", kind = .Float},
	{
		name = "cpu",
		kind = .Object,
		of = {
			{name = "cores", kind = .Int},
			{name = "busy_percent", kind = .Float, help = "all cores, over the interval"},
			{name = "per_core", kind = .Array, of = {{kind = .Float}}},
			{name = "context_switches", kind = .Int, help = "since boot"},
		},
	},
	{
		name = "memory",
		kind = .Object,
		of = {
			{name = "total", kind = .Int, help = "bytes"},
			{name = "used", kind = .Int, help = "bytes, htop's definition"},
			{name = "available", kind = .Int},
			{name = "free", kind = .Int},
			{name = "buffers", kind = .Int},
			{name = "cached", kind = .Int},
			{name = "swap_total", kind = .Int},
			{name = "swap_used", kind = .Int},
		},
	},
	{
		name = "load",
		kind = .Object,
		of = {
			{name = "avg1", kind = .Float},
			{name = "avg5", kind = .Float},
			{name = "avg15", kind = .Float},
			{name = "running", kind = .Int},
			{name = "tasks", kind = .Int},
		},
	},
	{
		name = "network",
		kind = .Object,
		of = {
			{name = "rx_rate", kind = .Float, help = "bytes per second, loopback excluded"},
			{name = "tx_rate", kind = .Float},
			{
				name = "interfaces",
				kind = .Array,
				of = {
					{name = "name", kind = .String},
					{name = "up", kind = .Bool},
					{name = "carrier", kind = .Bool},
					{name = "rx", kind = .Int, help = "bytes since boot"},
					{name = "tx", kind = .Int},
					{name = "rx_rate", kind = .Float},
					{name = "tx_rate", kind = .Float},
					{name = "drops", kind = .Int},
					{name = "errors", kind = .Int},
				},
			},
		},
	},
	{
		name = "disks",
		kind = .Array,
		of = {
			{name = "source", kind = .String},
			{name = "mount", kind = .String},
			{name = "fstype", kind = .String},
			{name = "total", kind = .Int},
			{name = "free", kind = .Int},
			{name = "read_only", kind = .Bool},
			{name = "answered", kind = .Bool, help = "false when statvfs did not answer"},
		},
	},
	{
		name = "temperatures",
		kind = .Array,
		of = {
			{name = "chip", kind = .String},
			{name = "label", kind = .String},
			{name = "celsius", kind = .Float},
			{name = "critical", kind = .Float, help = "0 when the chip publishes none"},
		},
	},
	{name = "processes", kind = .Int},
	{name = "sample_ms", kind = .Float, help = "how long the last sample took"},
}

PS_FIELDS := []kit.Field {
	{
		name = "processes",
		kind = .Array,
		of = {
			{name = "pid", kind = .Int},
			{name = "ppid", kind = .Int},
			{name = "name", kind = .String},
			{name = "user", kind = .String},
			{name = "state", kind = .String},
			{name = "cpu", kind = .Float, help = "percent of one core"},
			{name = "rss", kind = .Int, help = "bytes"},
			{name = "threads", kind = .Int},
			{name = "cmd", kind = .String},
		},
	},
	{name = "shown", kind = .Int},
	{name = "matched", kind = .Int, help = "rows that passed the filter, before --limit"},
	{name = "total", kind = .Int, help = "every process, before filtering"},
	{name = "sort", kind = .String},
	{name = "descending", kind = .Bool},
}

PROC_FIELDS := []kit.Field {
	{name = "pid", kind = .Int},
	{name = "ppid", kind = .Int},
	{name = "name", kind = .String},
	{name = "cmd", kind = .String},
	{name = "user", kind = .String},
	{name = "state", kind = .String},
	{name = "threads", kind = .Int},
	{name = "rss", kind = .Int},
	{name = "vsz", kind = .Int},
	{name = "cpu", kind = .Float},
	{name = "nice", kind = .Int},
	{name = "kernel", kind = .Bool},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself when anything failed
	return 0
}

// cli_model samples twice, `interval` apart, the way the window's first two
// frames do: the first sample primes the counters and the second is the one
// with rates in it.
@(private = "file")
cli_model :: proc(c: ^kit.Call) -> ^Model {
	hz_init()
	users_init()
	m := new(Model)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	m.al = virtual.arena_allocator(&m.arena)
	m.host = host_read()
	m.sort = .Cpu
	m.desc = true
	m.sel_pid = -1
	m.show_idle = true

	dt := kit.cli_f64(c, "interval", 0.5)
	dt = clamp(dt, 0.05, 10)
	sample(m, 0)
	time.sleep(time.Duration(dt * f64(time.Second)))
	sample(m, dt)
	return m
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	m := cli_model(c)

	h := kit.jobj()
	kit.jset_str(h, "hostname", m.host.hostname)
	kit.jset_str(h, "kernel", m.host.kernel)
	kit.jset_str(h, "cpu_model", m.host.cpu_model)
	kit.jset_int(h, "cores", m.host.cores)
	kit.jset_int(h, "threads", m.host.threads)
	kit.jset_str(h, "distro", m.host.distro)
	kit.jset(c.out, "host", h)
	kit.jset_num(c.out, "uptime_seconds", m.uptime)

	co := kit.jobj()
	kit.jset_int(co, "cores", m.cpu.cores)
	kit.jset_num(co, "busy_percent", f64(m.cpu.agg) * 100)
	pc := kit.jarr()
	for i in 0 ..< min(m.cpu.cores, MAX_CORES) {
		kit.jpush(pc, kit.jnum(f64(m.cpu.per_core[i]) * 100))
	}
	kit.jset(co, "per_core", pc)
	kit.jset_i64(co, "context_switches", i64(m.cpu.ctxt))
	kit.jset(c.out, "cpu", co)

	mo := kit.jobj()
	kit.jset_i64(mo, "total", i64(m.mem.total))
	kit.jset_i64(mo, "used", i64(mem_used(m.mem)))
	kit.jset_i64(mo, "available", i64(m.mem.available))
	kit.jset_i64(mo, "free", i64(m.mem.free))
	kit.jset_i64(mo, "buffers", i64(m.mem.buffers))
	kit.jset_i64(mo, "cached", i64(m.mem.cached))
	kit.jset_i64(mo, "swap_total", i64(m.mem.swap_total))
	swap_used := m.mem.swap_total >= m.mem.swap_free ? m.mem.swap_total - m.mem.swap_free : 0
	kit.jset_i64(mo, "swap_used", i64(swap_used))
	kit.jset(c.out, "memory", mo)

	lo := kit.jobj()
	kit.jset_num(lo, "avg1", f64(m.load.avg[0]))
	kit.jset_num(lo, "avg5", f64(m.load.avg[1]))
	kit.jset_num(lo, "avg15", f64(m.load.avg[2]))
	kit.jset_int(lo, "running", m.load.running)
	kit.jset_int(lo, "tasks", m.load.total)
	kit.jset(c.out, "load", lo)

	no := kit.jobj()
	kit.jset_num(no, "rx_rate", m.net.rx_rate)
	kit.jset_num(no, "tx_rate", m.net.tx_rate)
	ifs := kit.jarr()
	for i in 0 ..< m.net.n {
		f := m.net.ifs[i]
		o := kit.jobj()
		kit.jset_str(o, "name", f.name)
		kit.jset_bool(o, "up", f.up)
		kit.jset_bool(o, "carrier", f.carrier)
		kit.jset_i64(o, "rx", i64(f.rx))
		kit.jset_i64(o, "tx", i64(f.tx))
		kit.jset_num(o, "rx_rate", f.rx_rate)
		kit.jset_num(o, "tx_rate", f.tx_rate)
		kit.jset_i64(o, "drops", i64(f.drops))
		kit.jset_i64(o, "errors", i64(f.errs))
		kit.jpush(ifs, o)
	}
	kit.jset(no, "interfaces", ifs)
	kit.jset(c.out, "network", no)

	ds := kit.jarr()
	for d in m.disks {
		o := kit.jobj()
		kit.jset_str(o, "source", d.source)
		kit.jset_str(o, "mount", d.mount)
		kit.jset_str(o, "fstype", d.fstype)
		kit.jset_i64(o, "total", i64(d.total))
		kit.jset_i64(o, "free", i64(d.free))
		kit.jset_bool(o, "read_only", d.ro)
		kit.jset_bool(o, "answered", d.ok)
		kit.jpush(ds, o)
	}
	kit.jset(c.out, "disks", ds)

	// Synchronously: the window reads sensors on a worker thread so a slow
	// chip cannot cost it frames, and a command that prints once has none.
	buf := make([]u8, 8192, context.allocator)
	ts := kit.jarr()
	for t in temp_sample(buf, context.allocator) {
		o := kit.jobj()
		kit.jset_str(o, "chip", t.chip)
		kit.jset_str(o, "label", t.label)
		kit.jset_num(o, "celsius", f64(t.c))
		kit.jset_num(o, "critical", f64(t.crit))
		kit.jpush(ts, o)
	}
	kit.jset(c.out, "temperatures", ts)
	kit.jset_int(c.out, "processes", len(m.procs))
	kit.jset_num(c.out, "sample_ms", f64(m.sample_ms))
	return kit.EXIT_OK
}

// sort_key_of maps the --sort word onto the window's own sort key.
sort_key_of :: proc(word: string) -> Sort_Key {
	switch word {
	case "mem":
		return .Mem
	case "pid":
		return .Pid
	case "name":
		return .Name
	case "threads":
		return .Threads
	case "user":
		return .User
	}
	return .Cpu
}

@(private = "file")
proc_json :: proc(r: Proc_Row, o: ^kit.Json) {
	kit.jset_int(o, "pid", r.pid)
	kit.jset_int(o, "ppid", r.ppid)
	kit.jset_str(o, "name", r.name)
	kit.jset_str(o, "user", r.user)
	kit.jset_str(o, "state", state_label(r.state))
	kit.jset_num(o, "cpu", f64(r.cpu))
	kit.jset_i64(o, "rss", i64(r.rss))
	kit.jset_int(o, "threads", r.threads)
	kit.jset_str(o, "cmd", r.cmd)
}

@(private = "file")
cmd_ps :: proc(c: ^kit.Call) -> int {
	m := cli_model(c)
	m.sort = sort_key_of(kit.cli_str(c, "sort"))
	m.desc = !kit.cli_bool(c, "asc")
	m.show_kernel = kit.cli_bool(c, "kernel")
	m.show_idle = kit.cli_bool(c, "idle")
	for ch in transmute([]u8)kit.cli_str(c, "filter") {
		append(&m.filter, ch)
	}
	// build_view windows the table to the rows on screen; a command has no
	// screen, so every matching row is "visible".
	m.rows = len(m.procs) + 1
	v := build_view(m)

	limit := kit.cli_int(c, "limit", 25)
	n := len(v.rows)
	if limit > 0 && limit < n {
		n = limit
	}
	arr := kit.jarr()
	for i in v.rows[:n] {
		o := kit.jobj()
		proc_json(m.procs[i], o)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "processes", arr)
	kit.jset_int(c.out, "shown", n)
	kit.jset_int(c.out, "matched", len(v.rows))
	kit.jset_int(c.out, "total", v.total)
	kit.jset_str(c.out, "sort", strings.to_lower(sort_label(m.sort), context.temp_allocator))
	kit.jset_bool(c.out, "descending", m.desc)
	return kit.EXIT_OK
}

@(private = "file")
cmd_proc :: proc(c: ^kit.Call) -> int {
	pid := kit.cli_int(c, "pid", -1)
	if pid <= 0 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a process id", kit.cli_str(c, "pid"))
	}
	m := cli_model(c)
	for r in m.procs {
		if r.pid != pid {
			continue
		}
		proc_json(r, c.out)
		kit.jset_i64(c.out, "vsz", i64(r.vsz))
		kit.jset_int(c.out, "nice", r.nice)
		kit.jset_bool(c.out, "kernel", r.kernel)
		return kit.EXIT_OK
	}
	return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no process %d", pid)
}

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	kit.jset_str(c.out, "path", path)
	if c.dry_run {
		return kit.EXIT_OK
	}
	keys_wanted := make([dynamic]u32, context.allocator)
	for extra in kit.cli_rest(c) {
		if len(extra) > 0 {
			append(&keys_wanted, u32(extra[0]))
		}
	}
	os.remove(path)
	shot(path, keys_wanted[:])
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", path)
	}
	return kit.EXIT_OK
}
