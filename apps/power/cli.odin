package main

// The command-line front end of the power applet.
//
// This is the exemplar for the `intent` side-effect class, and the reason the
// class exists at all. Everything the window can do, `palm power` can do —
// except that what the window does for `Restart` is log the command and run
// nothing, so that is exactly what the CLI does too. The two front ends share
// `log_intent`, so there is no second implementation that could quietly grow
// teeth.
//
// Three things hold that shut, and none of them is a comment:
//
//  1. Every session action declares `effect = .Intent`, and `kit.cli_intent`
//     is its entire body. It writes the command to the intent log, to the
//     audit log and to stderr, and returns.
//
//  2. While an intent-class command runs, the kit arms a guard that makes
//     `kit.run`, `kit.run_lines` and `kit.launch` refuse to spawn anything at
//     all. A body that tried to execute would be stopped by the shared code,
//     not by review.
//
//  3. `power --selftest` puts fake `systemctl`, `loginctl`, `reboot`,
//     `poweroff`, `shutdown` and `systemd-run` binaries at the front of PATH,
//     each appending to a sentinel file, springs the trap deliberately to
//     prove it works, empties the sentinel, drives every action through both
//     front ends — the confirmation dialog in the window and these commands —
//     and asserts the sentinel is still empty. See test_nothing_executes in
//     selftest.odin.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// COMMANDS and the field lists below are package variables, and `surface`
// assembles them at call time rather than at load time. Odin does not promise
// the order it runs package initialisers in, and a declaration that was built
// before the field list it points at would advertise an empty output schema —
// a schema that lies, which is the one thing this convention exists to stop.
// Reading them inside a procedure means every initialiser has certainly run.
@(private = "file")
COMMANDS := []kit.Command{
		{
			verb = "status",
			summary = "uptime, sessions, CPU policy, temperatures, power supplies",
			effect = .Read,
			out = STATUS_FIELDS,
			examples = {"power status --json", "power status"},
			run = cmd_status,
		},
		{
			verb = "actions",
			summary = "the session actions, and the command each one would run",
			effect = .Read,
			out = ACTIONS_FIELDS,
			examples = {"power actions --json"},
			run = cmd_actions,
		},
		{
			verb = "lock",
			summary = "log the intent to lock the session",
			effect = .Intent,
			out = INTENT_FIELDS,
			examples = {"power lock --json"},
			run = cmd_lock,
		},
		{
			verb = "logout",
			summary = "log the intent to end the session",
			effect = .Intent,
			out = INTENT_FIELDS,
			examples = {"power logout --json"},
			run = cmd_logout,
		},
		{
			verb = "suspend",
			summary = "log the intent to sleep to RAM",
			effect = .Intent,
			out = INTENT_FIELDS,
			examples = {"power suspend --json"},
			run = cmd_suspend,
		},
		{
			verb = "reboot",
			summary = "log the intent to restart the machine",
			effect = .Intent,
			out = INTENT_FIELDS,
			examples = {"power reboot --json"},
			run = cmd_reboot,
		},
		{
			verb = "shutdown",
			summary = "log the intent to power the machine off",
			effect = .Intent,
			out = INTENT_FIELDS,
			examples = {"power shutdown --json"},
			run = cmd_shutdown,
		},
		{
			verb = "intents",
			summary = "the session actions logged in this process",
			effect = .Read,
			flags = {{name = "limit", kind = .Int, help = "how many, newest first", def = "32"}},
			out = INTENTS_FIELDS,
			examples = {"power intents --json"},
			run = cmd_intents,
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
			examples = {"power shot /tmp/power.png", "power shot /tmp/power-log.png c"},
			run = cmd_shot,
		},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "power",
			summary  = "power, session and thermal state — and session actions that log and do not run",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Every session action is intent class: it writes what it would have run to
the intent log and executes nothing. That is not a safety setting that can be
turned off — there is no code here that runs any of them, and the kit refuses
to spawn a process at all while an intent command is running.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

// Every one of these is a self-contained literal rather than a reference to
// another package variable. A slice that points at another global is built at
// load time, in declaration order, and COMMANDS above would then capture it
// before it was filled. Written out, it is static data the linker lays down
// once and the order stops mattering.
STATUS_FIELDS := []kit.Field {
	{
		name = "host",
		kind = .Object,
		of = {
			{name = "hostname", kind = .String},
			{name = "kernel", kind = .String},
			{name = "cpu_model", kind = .String},
			{name = "chassis", kind = .String},
			{name = "distro", kind = .String},
		},
	},
	{name = "uptime_seconds", kind = .Int},
	{name = "uptime", kind = .String},
	{name = "booted_at", kind = .String},
	{
		name = "cpu",
		kind = .Object,
		of = {
			{name = "present", kind = .Bool},
			{name = "policies", kind = .Int, help = "how many cpufreq policies were found"},
			{name = "governor", kind = .String},
			{name = "driver", kind = .String},
			{name = "epp", kind = .String, help = "energy performance preference"},
			{name = "mixed", kind = .Bool, help = "the policies do not agree with each other"},
			{name = "boost", kind = .Int, help = "-1 when the kernel does not publish the knob"},
			{name = "min_khz", kind = .Int},
			{name = "max_khz", kind = .Int},
			{name = "hw_max_khz", kind = .Int},
			{name = "cur_khz", kind = .Array, of = {{kind = .Int}}},
		},
	},
	{
		name = "sessions",
		kind = .Array,
		of = {
			{name = "id", kind = .String},
			{name = "user", kind = .String},
			{name = "seat", kind = .String},
			{name = "type", kind = .String},
			{name = "class", kind = .String},
			{name = "state", kind = .String},
			{name = "active", kind = .Bool},
			{name = "locked", kind = .Bool},
			{name = "remote", kind = .Bool},
		},
	},
	{
		name = "power_supplies",
		kind = .Array,
		help = "empty on this chassis, which has none",
		of = {
			{name = "name", kind = .String},
			{name = "type", kind = .String},
			{name = "status", kind = .String},
			{name = "percent", kind = .Int},
		},
	},
	{
		name = "temperatures",
		kind = .Array,
		of = {
			{name = "chip", kind = .String},
			{name = "label", kind = .String},
			{name = "celsius", kind = .Float},
			{name = "critical", kind = .Float},
		},
	},
	{
		name = "upower",
		kind = .Object,
		of = {
			{name = "available", kind = .Bool},
			{name = "version", kind = .String},
			{name = "on_battery", kind = .Bool},
			{name = "lid_present", kind = .Bool},
			{name = "lid_closed", kind = .Bool},
			{
				name = "devices",
				kind = .Array,
				of = {
					{name = "model", kind = .String},
					{name = "kind", kind = .String},
					{name = "percent", kind = .Int},
					{name = "supply", kind = .Bool},
				},
			},
		},
	},
}

ACTIONS_FIELDS := []kit.Field {
	{
		name = "actions",
		kind = .Array,
		of = {
			{name = "action", kind = .String},
			{name = "label", kind = .String},
			{name = "command", kind = .String, help = "what a real implementation would run"},
			{name = "effect", kind = .String, help = "always \"intent\""},
			{name = "executes", kind = .Bool, help = "always false"},
			{name = "severe", kind = .Bool},
			{name = "key", kind = .String, help = "the key that arms it in the window"},
		},
	},
}

INTENT_FIELDS := []kit.Field {
	{name = "intent", kind = .String, help = "the command that was NOT run"},
	{name = "label", kind = .String},
	{name = "executed", kind = .Bool, help = "always false"},
	{name = "effect", kind = .String, help = "always \"intent\""},
}

INTENTS_FIELDS := []kit.Field {
	{
		name = "intents",
		kind = .Array,
		of = {{name = "at", kind = .String}, {name = "command", kind = .String}, {name = "label", kind = .String}},
	},
	{name = "count", kind = .Int},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself when anything failed
	return 0
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	h := host_read(context.allocator)
	ho := kit.jobj()
	kit.jset_str(ho, "hostname", h.hostname)
	kit.jset_str(ho, "kernel", h.kernel)
	kit.jset_str(ho, "cpu_model", h.cpu_model)
	kit.jset_str(ho, "chassis", chassis_label(h.chassis))
	kit.jset_str(ho, "distro", h.distro)
	kit.jset(c.out, "host", ho)

	up, _, _ := uptime_read()
	btime, _ := btime_read()
	kit.jset_int(c.out, "uptime_seconds", int(up))
	kit.jset_str(c.out, "uptime", fmt_uptime(up))
	kit.jset_str(c.out, "booted_at", boot_label(btime))

	f := cpufreq_read(context.allocator)
	co := kit.jobj()
	kit.jset_bool(co, "present", f.present)
	kit.jset_int(co, "policies", f.n)
	kit.jset_str(co, "governor", f.governor)
	kit.jset_str(co, "driver", f.driver)
	kit.jset_str(co, "epp", f.epp)
	kit.jset_bool(co, "mixed", f.mixed)
	kit.jset_int(co, "boost", f.boost)
	kit.jset_i64(co, "min_khz", i64(f.min_khz))
	kit.jset_i64(co, "max_khz", i64(f.max_khz))
	kit.jset_i64(co, "hw_max_khz", i64(f.hw_max_khz))
	cur := kit.jarr()
	for i in 0 ..< f.n {
		kit.jpush(cur, kit.ji64(i64(f.cur[i])))
	}
	kit.jset(co, "cur_khz", cur)
	kit.jset(c.out, "cpu", co)

	ss := kit.jarr()
	for s in sessions_read(context.allocator) {
		o := kit.jobj()
		kit.jset_str(o, "id", s.id)
		kit.jset_str(o, "user", s.user)
		kit.jset_str(o, "seat", s.seat)
		kit.jset_str(o, "type", s.type_)
		kit.jset_str(o, "class", s.class)
		kit.jset_str(o, "state", s.state)
		kit.jset_bool(o, "active", s.active)
		kit.jset_bool(o, "locked", s.locked)
		kit.jset_bool(o, "remote", s.remote)
		kit.jpush(ss, o)
	}
	kit.jset(c.out, "sessions", ss)

	sup := kit.jarr()
	for s in supplies_read(context.allocator) {
		o := kit.jobj()
		kit.jset_str(o, "name", s.name)
		kit.jset_str(o, "type", s.type_)
		kit.jset_str(o, "status", s.status)
		kit.jset_int(o, "percent", s.pct)
		kit.jpush(sup, o)
	}
	kit.jset(c.out, "power_supplies", sup)

	// Synchronously here: the window reads sensors on a worker thread because
	// 45 to 80 ms would cost it frames, and a command that prints once and
	// exits has no frames to lose.
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

	u := upower_read(context.allocator)
	uo := kit.jobj()
	kit.jset_bool(uo, "available", u.ok)
	kit.jset_str(uo, "version", u.version)
	kit.jset_bool(uo, "on_battery", u.on_battery)
	kit.jset_bool(uo, "lid_present", u.lid_present)
	kit.jset_bool(uo, "lid_closed", u.lid_closed)
	du := kit.jarr()
	for d in u.devs {
		o := kit.jobj()
		kit.jset_str(o, "model", d.model)
		kit.jset_str(o, "kind", d.kind)
		kit.jset_int(o, "percent", d.pct)
		kit.jset_bool(o, "supply", d.supply)
		kit.jpush(du, o)
	}
	kit.jset(uo, "devices", du)
	kit.jset(c.out, "upower", uo)
	return kit.EXIT_OK
}

@(private = "file")
cmd_actions :: proc(c: ^kit.Call) -> int {
	arr := kit.jarr()
	for a in Action {
		info := ACTIONS[a]
		o := kit.jobj()
		kit.jset_str(o, "action", strings.to_lower(fmt.tprintf("%v", a), context.temp_allocator))
		kit.jset_str(o, "label", info.label)
		kit.jset_str(o, "command", info.cmd)
		kit.jset_str(o, "effect", "intent")
		kit.jset_bool(o, "executes", false)
		kit.jset_bool(o, "severe", info.severe)
		kit.jset_str(o, "key", info.key)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "actions", arr)
	return kit.EXIT_OK
}

// cli_perform is the CLI half of `perform` in main.odin. Both ends go through
// `log_intent`, so the window and the command leave the same record, and
// neither has a branch that executes anything.
@(private = "file")
cli_perform :: proc(c: ^kit.Call, a: Action) -> int {
	info := ACTIONS[a]
	log_intent(info.cmd, info.label)
	return kit.cli_intent(c, info.cmd, info.label, quiet = true)
}

@(private = "file")
cmd_lock :: proc(c: ^kit.Call) -> int {return cli_perform(c, .Lock)}
@(private = "file")
cmd_logout :: proc(c: ^kit.Call) -> int {return cli_perform(c, .Logout)}
@(private = "file")
cmd_suspend :: proc(c: ^kit.Call) -> int {return cli_perform(c, .Suspend)}
@(private = "file")
cmd_reboot :: proc(c: ^kit.Call) -> int {return cli_perform(c, .Reboot)}
@(private = "file")
cmd_shutdown :: proc(c: ^kit.Call) -> int {return cli_perform(c, .Shutdown)}

@(private = "file")
cmd_intents :: proc(c: ^kit.Call) -> int {
	n := kit.cli_int(c, "limit", 32)
	arr := kit.jarr()
	for e in log_recent(n, context.allocator) {
		o := kit.jobj()
		kit.jset_str(o, "at", e.when_)
		kit.jset_str(o, "command", e.cmd)
		kit.jset_str(o, "label", e.label)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "intents", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	keys_wanted := make([dynamic]u32, context.allocator)
	for extra in kit.cli_rest(c) {
		if len(extra) > 0 {
			append(&keys_wanted, u32(extra[0]))
		}
	}
	if c.dry_run {
		kit.jset_str(c.out, "path", path)
		return kit.EXIT_OK
	}
	shot(path, keys_wanted[:])
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", path)
	}
	kit.jset_str(c.out, "path", path)
	return kit.EXIT_OK
}

// cli_verb is the command that corresponds to an action in the window, so the
// self-test can drive both front ends from one list and the two cannot drift.
cli_verb :: proc(a: Action) -> string {
	switch a {
	case .Lock:
		return "lock"
	case .Logout:
		return "logout"
	case .Suspend:
		return "suspend"
	case .Reboot:
		return "reboot"
	case .Shutdown:
		return "shutdown"
	}
	return ""
}
