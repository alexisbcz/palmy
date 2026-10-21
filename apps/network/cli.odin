package main

// The command-line front end of the network panel: `palm net`.
//
// Networking is read-only here, and that is a rule of this project rather
// than a setting: a command that drops the machine's connection takes the
// session doing the work offline with it. So the surface is two kinds of
// command and no third.
//
//   read     status and wifi run the window's own jobs (`run_job` with
//            .Refresh, .Wifi, .Rescan) on a Store of their own, with no
//            window and no worker thread, and print what landed in it.
//            A rescan asks the radio for fresh results; it changes no
//            connection, which is why it is a flag on a read.
//
//   intent   radio and connect log the command through nm_intent_only — the
//            same gate the window's radio-off and connect go through — with
//            the argv built by the same radio_argv / connect_argv, and run
//            nothing. That includes turning the radio *on*, which the window
//            does do: from here, nothing changes network state at all.
//
// `--status` and `--shots <dir>` keep working as they always have (main.odin).
// Rendering the panel to PNGs writes files and is therefore not a verb on a
// noun whose every command must be read or intent.

import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "the backend, the radio, every interface with its addressing, and saved networks",
		effect = .Read,
		out = STATUS_FIELDS,
		examples = {"network status --json", "network status"},
		run = cmd_status,
	},
	{
		verb = "wifi",
		summary = "the Wi-Fi networks in range, strongest first",
		effect = .Read,
		flags = {{name = "rescan", kind = .Bool, help = "ask the radio for a fresh scan first; changes no connection"}},
		out = WIFI_FIELDS,
		examples = {"network wifi --json", "network wifi --rescan"},
		run = cmd_wifi,
	},
	{
		verb = "radio",
		summary = "log the command that would switch the Wi-Fi radio, and run nothing",
		effect = .Intent,
		args = {{name = "state", kind = .Enum, values = {"on", "off"}, help = "the state asked for", required = true}},
		out = INTENT_FIELDS,
		examples = {"network radio off --json", "network radio on"},
		run = cmd_radio,
	},
	{
		verb = "connect",
		summary = "log the command that would join a network, and run nothing",
		effect = .Intent,
		args = {{name = "ssid", kind = .String, help = "the network's name", required = true}},
		out = INTENT_FIELDS,
		examples = {"network connect \"Cafe Wi-Fi\" --json"},
		run = cmd_connect,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "net",
			summary  = "network state — read-only, by rule; radio and connect are intent only",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Networking is read-only. radio and connect print the exact command the window's
gate logs for them and execute nothing — radio on included — and the kit
refuses to start any process while they run. No passphrase is accepted: a
secret does not belong on a command line or in a log.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

STATUS_FIELDS := []kit.Field {
	{name = "backend", kind = .String, help = "iwd or NetworkManager"},
	{name = "radio_on", kind = .Bool},
	{
		name = "devices",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "kind", kind = .String},
			{name = "state", kind = .String},
			{name = "connection", kind = .String},
			{name = "hwaddr", kind = .String},
			{name = "ip4", kind = .String},
			{name = "prefix", kind = .String},
			{name = "gateway", kind = .String},
			{name = "dns", kind = .String},
			{name = "ip6", kind = .String},
			{name = "mtu", kind = .String},
			{name = "speed", kind = .String},
		},
	},
	{
		name = "known",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "kind", kind = .String},
			{name = "device", kind = .String},
			{name = "autoconnect", kind = .Bool},
			{name = "active", kind = .Bool},
		},
	},
	{name = "message", kind = .String, help = "what the backend said, \"\" when nothing"},
}

WIFI_FIELDS := []kit.Field {
	{name = "backend", kind = .String},
	{name = "radio_on", kind = .Bool},
	{
		name = "networks",
		kind = .Array,
		of = {
			{name = "ssid", kind = .String},
			{name = "security", kind = .String},
			{name = "signal", kind = .Int, help = "percent"},
			{name = "active", kind = .Bool},
			{name = "radios", kind = .Int, help = "access points answering for this SSID"},
			{name = "channel", kind = .Int},
			{name = "band", kind = .String},
			{name = "rate", kind = .String},
			{name = "hidden", kind = .Bool},
		},
	},
	{name = "scanned_at", kind = .String, help = "wall clock of the list"},
	{name = "rescanned", kind = .Bool},
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

// cli_store is a Store with no worker thread: the jobs run on this thread,
// one after another, exactly as `--status` has always run them.
@(private = "file")
cli_store :: proc() -> ^Store {
	s := new(Store)
	s.devices = make([dynamic]Dev)
	s.aps = make([dynamic]Ap)
	s.saved = make([dynamic]Saved)
	s.backend = pick_backend()
	return s
}

state_word_cli :: proc(st: Dev_State) -> string {
	switch st {
	case .Unknown:
		return "unknown"
	case .Unmanaged:
		return "unmanaged"
	case .Unavailable:
		return "unavailable"
	case .Disconnected:
		return "disconnected"
	case .Connecting:
		return "connecting"
	case .Connected:
		return "connected"
	}
	return "unknown"
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	s := cli_store()
	run_job(s, .Refresh)
	if !s.loaded {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, s.message == "" ? "no backend answered" : s.message)
	}
	kit.jset_str(c.out, "backend", backend_name(s.backend))
	kit.jset_bool(c.out, "radio_on", s.radio_on)
	ds := kit.jarr()
	for d in s.devices {
		o := kit.jobj()
		kit.jset_str(o, "name", d.name)
		kit.jset_str(o, "kind", d.kind)
		kit.jset_str(o, "state", state_word_cli(d.state))
		kit.jset_str(o, "connection", d.conn)
		kit.jset_str(o, "hwaddr", d.hwaddr)
		kit.jset_str(o, "ip4", d.ip4)
		kit.jset_str(o, "prefix", d.prefix)
		kit.jset_str(o, "gateway", d.gw4)
		kit.jset_str(o, "dns", d.dns)
		kit.jset_str(o, "ip6", d.ip6)
		kit.jset_str(o, "mtu", d.mtu)
		kit.jset_str(o, "speed", d.speed)
		kit.jpush(ds, o)
	}
	kit.jset(c.out, "devices", ds)
	ks := kit.jarr()
	for v in s.saved {
		o := kit.jobj()
		kit.jset_str(o, "name", v.name)
		kit.jset_str(o, "kind", v.kind)
		kit.jset_str(o, "device", v.device)
		kit.jset_bool(o, "autoconnect", v.autoconnect)
		kit.jset_bool(o, "active", v.active)
		kit.jpush(ks, o)
	}
	kit.jset(c.out, "known", ks)
	kit.jset_str(c.out, "message", s.message)
	return kit.EXIT_OK
}

@(private = "file")
cmd_wifi :: proc(c: ^kit.Call) -> int {
	s := cli_store()
	rescan := kit.cli_bool(c, "rescan")
	run_job(s, .Refresh)
	run_job(s, rescan ? .Rescan : .Wifi)
	if !s.scanned {
		// iwd is not on the bus (or will not talk to this user): there is
		// no Wi-Fi to list, which is unavailable, not an empty list.
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, s.message == "" ? "no Wi-Fi backend answered" : s.message)
	}
	kit.jset_str(c.out, "backend", backend_name(s.backend))
	kit.jset_bool(c.out, "radio_on", s.radio_on)
	arr := kit.jarr()
	for a in s.aps {
		o := kit.jobj()
		kit.jset_str(o, "ssid", a.ssid)
		kit.jset_str(o, "security", a.security)
		kit.jset_int(o, "signal", a.signal)
		kit.jset_bool(o, "active", a.active)
		kit.jset_int(o, "radios", a.bssids)
		kit.jset_int(o, "channel", a.channel)
		kit.jset_str(o, "band", a.band)
		kit.jset_str(o, "rate", a.rate)
		kit.jset_bool(o, "hidden", a.hidden)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "networks", arr)
	kit.jset_str(c.out, "scanned_at", s.scan_at)
	kit.jset_bool(c.out, "rescanned", rescan)
	return kit.EXIT_OK
}

// cli_gate is the CLI half of nm_intent_only: the same line on stderr, and
// the intent record on stdout and in the audit log.
@(private = "file")
cli_gate :: proc(c: ^kit.Call, argv: []string, why: string) -> int {
	nm_intent_only(argv, why)
	return kit.cli_intent(c, strings.join(argv, " ", context.temp_allocator), why, quiet = true)
}

@(private = "file")
cmd_radio :: proc(c: ^kit.Call) -> int {
	on := kit.cli_str(c, "state") == "on"
	why := on ? WHY_RADIO_ON : WHY_RADIO_OFF
	b := pick_backend()
	if b == .Nm {
		return cli_gate(c, radio_argv(.Nm, "", on), why)
	}
	// iwd powers each Wi-Fi device separately. Finding them is a D-Bus read
	// in this process; it starts nothing, which is all the guard forbids.
	st, err := iwd_read(context.temp_allocator)
	if err != "" || len(st.devices) == 0 {
		return cli_gate(c, radio_argv(.Iwd, "<every Wi-Fi device>", on), why)
	}
	cmds := make([dynamic]string, context.temp_allocator)
	for wd in st.devices {
		argv := radio_argv(.Iwd, wd.path, on)
		nm_intent_only(argv, why)
		append(&cmds, strings.join(argv, " ", context.temp_allocator))
	}
	return kit.cli_intent(c, strings.join(cmds[:], "; ", context.temp_allocator), why, quiet = true)
}

@(private = "file")
cmd_connect :: proc(c: ^kit.Call) -> int {
	ssid := kit.cli_str(c, "ssid")
	if ssid == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a network has a name")
	}
	return cli_gate(c, connect_argv(pick_backend(), ssid), WHY_CONNECT)
}
