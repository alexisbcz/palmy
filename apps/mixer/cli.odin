package main

// The command-line front end of the mixer.
//
// Reading goes through `audio_read`, the same reader the window refreshes
// from, so `mixer status` and the window agree about every device and stream.
//
// Writing does not happen here at all. In the window, Left/Right, M and D
// change the real audio graph — a person is looking at the result and has U
// to put it back. A command has neither, and nothing can prove from here that
// the node an agent names is a synthetic sink rather than somebody's
// headphones, so `volume`, `mute` and `default` are intent class: each prints
// and logs the exact `wpctl` command the window would run for it — built by
// the same `volume_argv` / `mute_argv` / `default_argv` the window's writes
// use — and executes nothing. The kit's guard backs that up: while an intent
// command runs, its process helpers refuse to spawn anything at all.
//
// The input meter is absent from this surface, not gated. It works by
// recording from a source, and a command that opens the microphone is not one
// this project ships.

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "outputs, inputs and streams, with volume, mute and the defaults",
		effect = .Read,
		out = STATUS_FIELDS,
		examples = {"mixer status --json", "mixer status"},
		run = cmd_status,
	},
	{
		verb = "volume",
		summary = "log the wpctl command that would set a volume, and run nothing",
		effect = .Intent,
		args = {
			{name = "target", kind = .String, help = "a node id, `default` (the default output) or `default-input`", required = true},
			{name = "level", kind = .Float, help = "0 to 1; clamped to 1, as the window clamps it", required = true},
		},
		out = INTENT_FIELDS,
		examples = {"mixer volume default 0.4 --json", "mixer volume 51 0.25"},
		run = cmd_volume,
	},
	{
		verb = "mute",
		summary = "log the wpctl command that would mute or unmute, and run nothing",
		effect = .Intent,
		args = {
			{name = "target", kind = .String, help = "a node id, `default` or `default-input`", required = true},
			{name = "state", kind = .Enum, values = {"on", "off"}, help = "on mutes", required = true},
		},
		out = INTENT_FIELDS,
		examples = {"mixer mute default on --json"},
		run = cmd_mute,
	},
	{
		verb = "default",
		summary = "log the wpctl command that would make a device the default, and run nothing",
		effect = .Intent,
		args = {{name = "node", kind = .Int, help = "the device's node id", required = true}},
		out = INTENT_FIELDS,
		examples = {"mixer default 62 --json"},
		run = cmd_default,
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
		examples = {"mixer shot /tmp/mixer.png", "mixer shot /tmp/mixer-help.png ?"},
		run = cmd_shot,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "mixer",
			summary  = "output and input levels — read here; changes are intent only",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `volume, mute and default are intent class: each prints the exact wpctl
command the window would run and executes nothing, because a command cannot
see whose ears are on the other end of the node it names. The window changes
the real graph, with the state at launch kept and restorable on U. There is
no level meter here: it records from a source, and nothing on this surface
opens a microphone.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

STATUS_FIELDS := []kit.Field {
	{name = "default_output", kind = .String, help = "the default sink's node name"},
	{name = "default_input", kind = .String},
	{
		name = "outputs",
		kind = .Array,
		of = {
			{name = "node", kind = .Int, help = "the PipeWire object id wpctl takes"},
			{name = "name", kind = .String},
			{name = "description", kind = .String},
			{name = "volume", kind = .Float, help = "0..1, averaged over the channels"},
			{name = "muted", kind = .Bool},
			{name = "channels", kind = .Int},
			{name = "state", kind = .String},
			{name = "port", kind = .String},
			{name = "bus", kind = .String},
			{name = "default", kind = .Bool},
		},
	},
	{
		name = "inputs",
		kind = .Array,
		of = {
			{name = "node", kind = .Int},
			{name = "name", kind = .String},
			{name = "description", kind = .String},
			{name = "volume", kind = .Float},
			{name = "muted", kind = .Bool},
			{name = "channels", kind = .Int},
			{name = "state", kind = .String},
			{name = "port", kind = .String},
			{name = "bus", kind = .String},
			{name = "default", kind = .Bool},
		},
	},
	{
		name = "streams",
		kind = .Array,
		of = {
			{name = "node", kind = .Int},
			{name = "app", kind = .String},
			{name = "media", kind = .String},
			{name = "volume", kind = .Float},
			{name = "muted", kind = .Bool},
			{name = "corked", kind = .Bool},
			{name = "recording", kind = .Bool, help = "a source-output: it is listening, not playing"},
		},
	},
}

INTENT_FIELDS := []kit.Field {
	{name = "intent", kind = .String, help = "the command that was NOT run"},
	{name = "label", kind = .String},
	{name = "executed", kind = .Bool, help = "always false"},
	{name = "effect", kind = .String, help = "always \"intent\""},
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself when anything failed
	return 0
}

@(private = "file")
dev_json :: proc(d: Dev) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_int(o, "node", d.node)
	kit.jset_str(o, "name", d.name)
	kit.jset_str(o, "description", d.desc)
	kit.jset_num(o, "volume", f64(d.vol))
	kit.jset_bool(o, "muted", d.mute)
	kit.jset_int(o, "channels", d.chans)
	kit.jset_str(o, "state", d.state)
	kit.jset_str(o, "port", d.port)
	kit.jset_str(o, "bus", d.bus)
	kit.jset_bool(o, "default", d.default)
	return o
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	if !kit_has("pactl") {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "pactl is not installed (package pipewire-pulse)")
	}
	arena, scratch: virtual.Arena
	virtual.arena_init_growing(&arena) or_else panic("arena")
	virtual.arena_init_growing(&scratch) or_else panic("scratch")
	a := audio_read(virtual.arena_allocator(&arena), virtual.arena_allocator(&scratch))
	if !a.ok {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, a.err)
	}
	kit.jset_str(c.out, "default_output", strings.trim_space(a.default_out))
	kit.jset_str(c.out, "default_input", strings.trim_space(a.default_in))
	outs := kit.jarr()
	for d in a.outs {
		kit.jpush(outs, dev_json(d))
	}
	kit.jset(c.out, "outputs", outs)
	ins := kit.jarr()
	for d in a.ins {
		kit.jpush(ins, dev_json(d))
	}
	kit.jset(c.out, "inputs", ins)
	ss := kit.jarr()
	for s in a.streams {
		o := kit.jobj()
		kit.jset_int(o, "node", s.node)
		kit.jset_str(o, "app", s.app)
		kit.jset_str(o, "media", s.media)
		kit.jset_num(o, "volume", f64(s.vol))
		kit.jset_bool(o, "muted", s.mute)
		kit.jset_bool(o, "corked", s.corked)
		kit.jset_bool(o, "recording", s.record)
		kit.jpush(ss, o)
	}
	kit.jset(c.out, "streams", ss)
	return kit.EXIT_OK
}

// target_id turns what a caller typed into what wpctl takes: a node id stays
// a node id, and the two defaults become wpctl's own names for them. Nothing
// is looked up — an intent command may not run a process, not even a read —
// so a name is refused rather than resolved.
target_id :: proc(word: string) -> (id: string, ok: bool) {
	switch word {
	case "default", "default-output", "@DEFAULT_AUDIO_SINK@":
		return "@DEFAULT_AUDIO_SINK@", true
	case "default-input", "@DEFAULT_AUDIO_SOURCE@":
		return "@DEFAULT_AUDIO_SOURCE@", true
	}
	if n, good := strconv.parse_int(word); good && n >= 0 {
		return fmt.tprintf("%d", n), true
	}
	return "", false
}

@(private = "file")
intent :: proc(c: ^kit.Call, argv: []string, label: string) -> int {
	return kit.cli_intent(c, strings.join(argv, " ", context.temp_allocator), label)
}

@(private = "file")
cmd_volume :: proc(c: ^kit.Call) -> int {
	id, ok := target_id(kit.cli_str(c, "target"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a node id, default or default-input", kit.cli_str(c, "target"))
	}
	level := kit.cli_f64(c, "level", -1)
	if level < 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a volume is between 0 and 1")
	}
	argv := volume_argv(id, f32(level))
	return intent(c, argv, fmt.tprintf("set %s to %s", id, argv[3]))
}

@(private = "file")
cmd_mute :: proc(c: ^kit.Call) -> int {
	id, ok := target_id(kit.cli_str(c, "target"))
	if !ok {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a node id, default or default-input", kit.cli_str(c, "target"))
	}
	on := kit.cli_str(c, "state") == "on"
	return intent(c, mute_argv(id, on), fmt.tprintf("%s %s", on ? "mute" : "unmute", id))
}

@(private = "file")
cmd_default :: proc(c: ^kit.Call) -> int {
	node := kit.cli_int(c, "node", -1)
	if node < 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a node id is a whole number")
	}
	id := fmt.tprintf("%d", node)
	return intent(c, default_argv(id), fmt.tprintf("make %s the default", id))
}

// SHOT_REFUSED_KEYS are the window's writing keys, lower case.
SHOT_REFUSED_KEYS :: "mdlu"

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	kit.jset_str(c.out, "path", path)
	if c.dry_run {
		return kit.EXIT_OK
	}
	keys_wanted := make([dynamic]u32, context.allocator)
	for extra in kit.cli_rest(c) {
		if len(extra) == 0 {
			continue
		}
		// The keys that write in the window — M mutes, D changes the default,
		// U restores, L opens the microphone for the meter — are refused
		// here, before anything is drawn. A screenshot is not a way around
		// the intent rule, and it is certainly not a way to record a source.
		if strings.index_byte(SHOT_REFUSED_KEYS, extra[0] | 0x20) >= 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "the key %q changes real audio state in the window, so a shot will not press it", extra[:1])
		}
		append(&keys_wanted, u32(extra[0]))
	}
	os.remove(path)
	shot(path, keys_wanted[:])
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", path)
	}
	return kit.EXIT_OK
}
