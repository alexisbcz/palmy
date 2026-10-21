package main

// The command-line front end of the Bluetooth panel.
//
// Bluetooth is read-only from here, by the same rule as networking: turning
// the radio off or disconnecting a device takes away something a person is
// using — the headset playing their audio, the keyboard they are typing on —
// and pairing changes what this machine trusts. So the surface is two kinds of
// command and no third.
//
//   read     status, devices and device read through `read_adapter` and
//            `read_devices`, the readers the window reloads from, so the
//            command line and the window agree about every device.
//
//   intent   power, discoverable, scan, connect, disconnect, pair and trust
//            print the exact command the window runs for that action — built
//            by the same `action_words` the window's jobs use — and execute
//            nothing. While they run the kit refuses to start any process.
//
// The window does carry those actions out, behind a key press and, for the
// ones that take something away, a confirmation; a command has neither, which
// is the whole difference. Forgetting a device is absent in both: it is the
// one Bluetooth operation that cannot be undone without the device in hand.
//
// `--shots <dir>` keeps working as it always has (main.odin). It writes files
// and so is not a verb on a noun whose every command must be read or intent.

import "core:mem/virtual"
import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "the adapter: powered, discoverable, blocked, and its address",
		effect = .Read,
		out = STATUS_FIELDS,
		examples = {"bluetooth status --json", "bluetooth status"},
		run = cmd_status,
	},
	{
		verb = "devices",
		summary = "every device BlueZ knows, paired first",
		effect = .Read,
		flags = {
			{name = "paired", kind = .Bool, help = "only paired devices"},
			{name = "connected", kind = .Bool, help = "only connected devices"},
		},
		out = DEVICES_FIELDS,
		examples = {"bluetooth devices --json", "bluetooth devices --connected"},
		run = cmd_devices,
	},
	{
		verb = "device",
		summary = "one device, by address",
		effect = .Read,
		args = {{name = "addr", kind = .String, help = "AA:BB:CC:DD:EE:FF", required = true}},
		out = DEVICE_FIELDS,
		examples = {"bluetooth device AC:80:0A:51:2B:33 --json"},
		run = cmd_device,
	},
	{
		verb = "power",
		summary = "log the command that would switch the adapter, and run nothing",
		effect = .Intent,
		args = {{name = "state", kind = .Enum, values = {"on", "off"}, required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth power off --json"},
		run = cmd_power,
	},
	{
		verb = "discoverable",
		summary = "log the command that would make the adapter visible or hidden, and run nothing",
		effect = .Intent,
		args = {{name = "state", kind = .Enum, values = {"on", "off"}, required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth discoverable on --json"},
		run = cmd_discoverable,
	},
	{
		verb = "scan",
		summary = "log the command that would start discovery, and run nothing",
		effect = .Intent,
		out = INTENT_FIELDS,
		examples = {"bluetooth scan --json"},
		run = cmd_scan,
	},
	{
		verb = "connect",
		summary = "log the command that would connect a device, and run nothing",
		effect = .Intent,
		args = {{name = "addr", kind = .String, help = "AA:BB:CC:DD:EE:FF", required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth connect AC:80:0A:51:2B:33 --json"},
		run = cmd_connect,
	},
	{
		verb = "disconnect",
		summary = "log the command that would disconnect a device, and run nothing",
		effect = .Intent,
		args = {{name = "addr", kind = .String, help = "AA:BB:CC:DD:EE:FF", required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth disconnect AC:80:0A:51:2B:33 --json"},
		run = cmd_disconnect,
	},
	{
		verb = "pair",
		summary = "log the command that would pair a device, and run nothing",
		effect = .Intent,
		args = {{name = "addr", kind = .String, help = "AA:BB:CC:DD:EE:FF", required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth pair AC:80:0A:51:2B:33 --json"},
		run = cmd_pair,
	},
	{
		verb = "trust",
		summary = "log the command that would trust a device, and run nothing",
		effect = .Intent,
		args = {{name = "addr", kind = .String, help = "AA:BB:CC:DD:EE:FF", required = true}},
		out = INTENT_FIELDS,
		examples = {"bluetooth trust AC:80:0A:51:2B:33 --json"},
		run = cmd_trust,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "bluetooth",
			summary  = "bluetooth devices — read-only, by rule; every action is intent only",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Every action is intent class: it prints the exact bluetoothctl command the
window runs for it and executes nothing, and the kit refuses to start any
process while it runs. There is no remove or forget, here or in the window.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

STATUS_FIELDS := []kit.Field {
	{name = "present", kind = .Bool, help = "a controller answered"},
	{name = "address", kind = .String},
	{name = "name", kind = .String},
	{name = "alias", kind = .String},
	{name = "powered", kind = .Bool},
	{name = "discoverable", kind = .Bool},
	{name = "pairable", kind = .Bool},
	{name = "discovering", kind = .Bool},
	{name = "soft_blocked", kind = .Bool},
	{name = "hard_blocked", kind = .Bool},
	{name = "services", kind = .Int},
}

DEVICES_FIELDS := []kit.Field {
	{
		name = "devices",
		kind = .Array,
		of = {
			{name = "address", kind = .String},
			{name = "name", kind = .String},
			{name = "kind", kind = .String},
			{name = "paired", kind = .Bool},
			{name = "trusted", kind = .Bool},
			{name = "connected", kind = .Bool},
			{name = "battery", kind = .Int, help = "-1 when the device reports none"},
			{name = "rssi", kind = .Int, help = "0 when not reported"},
		},
	},
	{name = "count", kind = .Int},
}

DEVICE_FIELDS := []kit.Field {
	{name = "address", kind = .String},
	{name = "address_type", kind = .String},
	{name = "name", kind = .String},
	{name = "alias", kind = .String},
	{name = "kind", kind = .String},
	{name = "class", kind = .String},
	{name = "paired", kind = .Bool},
	{name = "bonded", kind = .Bool},
	{name = "trusted", kind = .Bool},
	{name = "blocked", kind = .Bool},
	{name = "connected", kind = .Bool},
	{name = "battery", kind = .Int},
	{name = "rssi", kind = .Int},
	{name = "services", kind = .Int},
	{name = "reachable", kind = .Bool, help = "bluetoothctl info answered for it"},
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
	return selftest()
}

@(private = "file")
cli_arena :: proc() -> virtual.Arena {
	a: virtual.Arena
	virtual.arena_init_growing(&a) or_else panic("arena")
	return a
}

@(private = "file")
need_bluez :: proc(c: ^kit.Call) -> bool {
	if !kit.has_tool("bluetoothctl") {
		kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "bluetoothctl is not installed (package bluez)")
		return false
	}
	return true
}

// SILENT_DETAIL is what every read says when bluetoothctl ran out its
// deadline (run.odin): BlueZ is installed but nothing is serving it.
SILENT_DETAIL :: "bluetoothctl did not answer within 2 s: bluetoothd is not running"

@(private = "file")
bluez_answered :: proc(c: ^kit.Call) -> bool {
	if bluez_silent() {
		kit.cli_fail(c, kit.EXIT_UNAVAILABLE, SILENT_DETAIL)
		return false
	}
	return true
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	if !need_bluez(c) {
		return kit.EXIT_UNAVAILABLE
	}
	arena := cli_arena()
	a := read_adapter(virtual.arena_allocator(&arena))
	if !bluez_answered(c) {
		return kit.EXIT_UNAVAILABLE
	}
	kit.jset_bool(c.out, "present", a.present)
	kit.jset_str(c.out, "address", a.addr)
	kit.jset_str(c.out, "name", a.name)
	kit.jset_str(c.out, "alias", a.alias)
	kit.jset_bool(c.out, "powered", a.powered)
	kit.jset_bool(c.out, "discoverable", a.discoverable)
	kit.jset_bool(c.out, "pairable", a.pairable)
	kit.jset_bool(c.out, "discovering", a.discovering)
	kit.jset_bool(c.out, "soft_blocked", a.soft_block)
	kit.jset_bool(c.out, "hard_blocked", a.hard_block)
	kit.jset_int(c.out, "services", a.services)
	return kit.EXIT_OK
}

@(private = "file")
device_label :: proc(d: Device) -> string {
	label, _ := display_name(d)
	return label
}

@(private = "file")
cmd_devices :: proc(c: ^kit.Call) -> int {
	if !need_bluez(c) {
		return kit.EXIT_UNAVAILABLE
	}
	arena := cli_arena()
	devs := read_devices(virtual.arena_allocator(&arena))
	if !bluez_answered(c) {
		return kit.EXIT_UNAVAILABLE
	}
	only_paired := kit.cli_bool(c, "paired")
	only_connected := kit.cli_bool(c, "connected")
	arr := kit.jarr()
	// Paired first, then the rest, each in BlueZ's own order: the window's
	// two lists, one after the other.
	for pass in 0 ..< 2 {
		for d in devs {
			if d.paired != (pass == 0) {continue}
			if only_paired && !d.paired {continue}
			if only_connected && !d.connected {continue}
			o := kit.jobj()
			kit.jset_str(o, "address", d.addr)
			kit.jset_str(o, "name", device_label(d))
			kit.jset_str(o, "kind", kind_label(d.kind))
			kit.jset_bool(o, "paired", d.paired)
			kit.jset_bool(o, "trusted", d.trusted)
			kit.jset_bool(o, "connected", d.connected)
			kit.jset_int(o, "battery", d.battery)
			kit.jset_int(o, "rssi", d.has_rssi ? d.rssi : 0)
			kit.jpush(arr, o)
		}
	}
	kit.jset(c.out, "devices", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
cmd_device :: proc(c: ^kit.Call) -> int {
	if !need_bluez(c) {
		return kit.EXIT_UNAVAILABLE
	}
	want := kit.cli_str(c, "addr")
	arena := cli_arena()
	devs := read_devices(virtual.arena_allocator(&arena))
	if !bluez_answered(c) {
		return kit.EXIT_UNAVAILABLE
	}
	for d in devs {
		if !same_hex(d.addr, want) {
			continue
		}
		kit.jset_str(c.out, "address", d.addr)
		kit.jset_str(c.out, "address_type", d.addr_type)
		kit.jset_str(c.out, "name", device_label(d))
		kit.jset_str(c.out, "alias", d.alias)
		kit.jset_str(c.out, "kind", kind_label(d.kind))
		kit.jset_str(c.out, "class", d.has_class ? class_label(d) : "")
		kit.jset_bool(c.out, "paired", d.paired)
		kit.jset_bool(c.out, "bonded", d.bonded)
		kit.jset_bool(c.out, "trusted", d.trusted)
		kit.jset_bool(c.out, "blocked", d.blocked)
		kit.jset_bool(c.out, "connected", d.connected)
		kit.jset_int(c.out, "battery", d.battery)
		kit.jset_int(c.out, "rssi", d.has_rssi ? d.rssi : 0)
		kit.jset_int(c.out, "services", d.services)
		kit.jset_bool(c.out, "reachable", d.reachable)
		return kit.EXIT_OK
	}
	return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "BlueZ knows no device %s", want)
}

// valid_addr accepts a MAC address, so an intent never records a command
// with something else spliced into it.
valid_addr :: proc(s: string) -> bool {
	if len(s) != 17 {
		return false
	}
	for i in 0 ..< 17 {
		ch := s[i]
		if i % 3 == 2 {
			if ch != ':' {return false}
			continue
		}
		hex := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
		if !hex {return false}
	}
	return true
}

@(private = "file")
intent :: proc(c: ^kit.Call, kind: Job_Kind, addr: string, on: bool, label: string) -> int {
	words := action_words(kind, addr, on)
	line := strings.join(words, " ", context.temp_allocator)
	// The window's activity log is in memory and dies with the process; the
	// intent goes to stderr, stdout and the audit log through the kit.
	return kit.cli_intent(c, line, label)
}

@(private = "file")
device_intent :: proc(c: ^kit.Call, kind: Job_Kind, label: string) -> int {
	addr := kit.cli_str(c, "addr")
	if !valid_addr(addr) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a Bluetooth address (AA:BB:CC:DD:EE:FF)", addr)
	}
	return intent(c, kind, strings.to_upper(addr, context.temp_allocator), true, label)
}

@(private = "file")
cmd_power :: proc(c: ^kit.Call) -> int {
	on := kit.cli_str(c, "state") == "on"
	return intent(c, .Power, "", on, on ? "power the adapter on" : "power the adapter off, dropping every connection")
}

@(private = "file")
cmd_discoverable :: proc(c: ^kit.Call) -> int {
	on := kit.cli_str(c, "state") == "on"
	return intent(c, .Discoverable, "", on, on ? "become discoverable" : "stop being discoverable")
}

@(private = "file")
cmd_scan :: proc(c: ^kit.Call) -> int {
	return intent(c, .Scan, "", true, "discover nearby devices")
}

@(private = "file")
cmd_connect :: proc(c: ^kit.Call) -> int {return device_intent(c, .Connect, "connect")}
@(private = "file")
cmd_disconnect :: proc(c: ^kit.Call) -> int {return device_intent(c, .Disconnect, "disconnect")}
@(private = "file")
cmd_pair :: proc(c: ^kit.Call) -> int {return device_intent(c, .Pair, "pair")}
@(private = "file")
cmd_trust :: proc(c: ^kit.Call) -> int {return device_intent(c, .Trust, "trust")}
