package main

// `network --selftest` — headless, no window, and it changes no network.
//
// The point of this file is one property: nothing on the command line, and
// none of the window's gated jobs, runs a command that changes network state.
// It is checked with a trap rather than by reading the code. A private bin
// directory goes first on PATH holding a fake `nmcli` — which answers the
// reads from canned NetworkManager output and writes every *other* request to
// a sentinel file — and fake `rfkill`, `ip`, `iw`, `iwctl`, `busctl`,
// `dbus-send` and `systemctl`, which write to the sentinel whatever they are
// asked. The trap is sprung once on purpose so that an empty sentinel means
// something, and then every command is driven, as a real child process and,
// for the window's jobs, in this process.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", what, got, want)
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", what, got, want)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

@(private = "file")
g_root: string
@(private = "file")
g_sentinel: string
@(private = "file")
g_reads: string
@(private = "file")
g_path_env: string

selftest :: proc() -> int {
	fmt.println("network self-test")
	g_root = fmt.aprintf("/tmp/palmy-network-selftest-%d", os.get_pid())
	_ = os.make_directory_all(g_root)
	defer _ = os.remove_all(g_root)

	test_parsers()
	test_argv()
	make_trap()
	test_trap_works()
	test_window_gate()
	test_cli_reads()
	test_cli_intents()
	test_cli_surface()

	fmt.printf("\n%d assertions, %d failures\n", checks, failures)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// The terse-format parsers the reads depend on
// ---------------------------------------------------------------------------

test_parsers :: proc() {
	section("nmcli's terse format")

	f := split_terse(`yes:Home:82:WPA2:540 Mbit/s:36:AA\:BB\:CC\:DD\:EE\:01:5180`, context.temp_allocator)
	eq_i(len(f), 8, "an access point line is eight fields")
	if len(f) == 8 {
		eq_s(f[6], "AA:BB:CC:DD:EE:01", "an escaped colon stays inside its field")
		eq_s(f[1], "Home", "the SSID")
	}
	g := split_terse("eth0:ethernet:connected (externally):", context.temp_allocator)
	eq_i(len(g), 4, "a trailing empty field is still a field")
	check(parse_state("connected") == .Connected, "connected parses")
	check(parse_state("connected (externally)") == .Connected, "connected (externally) is connected")
	check(parse_state("unavailable") == .Unavailable, "unavailable parses")
	eq_s(band_of(5180), "5 GHz", "5180 MHz is 5 GHz")
	eq_s(band_of(2437), "2.4 GHz", "2437 MHz is 2.4 GHz")
}

// ---------------------------------------------------------------------------
// The gated commands are built in one place
// ---------------------------------------------------------------------------

test_argv :: proc() {
	section("the gated commands")

	j :: proc(a: []string) -> string {return strings.join(a, " ", context.temp_allocator)}
	eq_s(j(radio_argv(.Nm, "", false)), "nmcli radio wifi off", "radio off, NetworkManager")
	eq_s(j(radio_argv(.Nm, "", true)), "nmcli radio wifi on", "radio on, NetworkManager")
	eq_s(j(connect_argv(.Nm, "Cafe")), "nmcli device wifi connect Cafe", "connect, NetworkManager")
	eq_s(
		j(radio_argv(.Iwd, "/net/connman/iwd/0/3", false)),
		"dbus net.connman.iwd /net/connman/iwd/0/3 Properties.Set net.connman.iwd.Device Powered false",
		"radio off, iwd",
	)
	eq_s(j(connect_argv(.Iwd, "Cafe")), "dbus net.connman.iwd Network.Connect Cafe", "connect, iwd")

	// And the kit refuses every one of the NetworkManager forms outright,
	// so even a body that tried to run one under the CLI would be stopped.
	check(kit.cli_forbidden(radio_argv(.Nm, "", false)) != "", "the kit's denylist refuses nmcli radio wifi off")
	check(kit.cli_forbidden(connect_argv(.Nm, "Cafe")) != "", "and nmcli device wifi connect")
	check(kit.cli_forbidden({"nmcli", "device", "disconnect", "wlan0"}) != "", "and nmcli device disconnect")
	check(kit.cli_forbidden({"rfkill", "block", "wifi"}) != "", "and rfkill block")
	check(kit.cli_forbidden({"nmcli", "-t", "-f", AP_FIELDS, "device", "wifi", "list", "--rescan", "no"}) == "", "but not the read the wifi list is")
}

// ---------------------------------------------------------------------------
// The trap
// ---------------------------------------------------------------------------

// FAKE_NMCLI answers the reads from canned output shaped like this
// machine's, logs each to the read log, and sends anything else to the
// sentinel. Order matters in the case: "radio wifi on" must be caught before
// the bare "radio wifi" read.
@(private = "file")
FAKE_NMCLI :: `#!/bin/sh
args="$*"
case "$args" in
  *"radio wifi on"*|*"radio wifi off"*|*"wifi connect"*|*"device connect"*|*disconnect*|*"connection up"*|*"connection down"*|*"connection delete"*|*"networking off"*|*modify*)
    printf '%s %s\n' "$0" "$args" >> SENTINEL; exit 0 ;;
esac
echo "$args" >> READS
case "$args" in
  *"device status"*) printf 'wlan0:wifi:connected:Home\neth0:ethernet:unavailable:\nlo:loopback:connected (externally):lo\n' ;;
  *"device show"*) printf 'GENERAL.DEVICE:wlan0\nGENERAL.HWADDR:AA:BB:CC:DD:EE:FF\nGENERAL.MTU:1500\nIP4.ADDRESS[1]:192.168.1.20/24\nIP4.GATEWAY:192.168.1.1\nIP4.DNS[1]:1.1.1.1\nIP6.ADDRESS[1]:fe80::1/64\n\nGENERAL.DEVICE:eth0\nGENERAL.HWADDR:11:22:33:44:55:66\nGENERAL.MTU:0\n' ;;
  *"connection show"*) printf 'Home:802-11-wireless:wlan0:uuid-1:yes\nWork:802-11-wireless::uuid-2:no\n' ;;
  *"radio wifi"*) echo enabled ;;
  *"wifi rescan"*) exit 0 ;;
  *"wifi list"*) printf 'yes:Home:82:WPA2:540 Mbit/s:36:AA\\:BB\\:CC\\:DD\\:EE\\:01:5180\nno:Cafe:40::54 Mbit/s:6:AA\\:BB\\:CC\\:DD\\:EE\\:02:2437\nno:Home:30:WPA2:130 Mbit/s:1:AA\\:BB\\:CC\\:DD\\:EE\\:03:2412\n' ;;
  *) exit 0 ;;
esac
`

// FAKE_IP lets the reads through to the real `ip` — the iwd backend reads
// addresses with `ip -o addr` — and sends anything that would change a link,
// an address or a route to the sentinel.
@(private = "file")
FAKE_IP :: `#!/bin/sh
case " $* " in
  *" set "*|*" down "*|*" up "*|*" del "*|*" delete "*|*" add "*|*" flush "*|*" change "*|*" replace "*)
    printf '%s %s\n' "$0" "$*" >> SENTINEL; exit 0 ;;
esac
for d in /usr/sbin /usr/bin /sbin /bin; do [ -x "$d/ip" ] && exec "$d/ip" "$@"; done
exit 1
`

@(private = "file")
FAKE_ANY :: `#!/bin/sh
printf '%s %s\n' "$0" "$*" >> SENTINEL
exit 0
`

make_trap :: proc() {
	bin := fmt.tprintf("%s/fakebin", g_root)
	_ = os.make_directory_all(bin)
	g_sentinel = fmt.aprintf("%s/fired", g_root)
	g_reads = fmt.aprintf("%s/reads", g_root)
	nm, _ := strings.replace_all(FAKE_NMCLI, "SENTINEL", g_sentinel, context.temp_allocator)
	nm, _ = strings.replace_all(nm, "READS", g_reads, context.temp_allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/nmcli", bin), transmute([]u8)nm, os.Permissions_All)
	any, _ := strings.replace_all(FAKE_ANY, "SENTINEL", g_sentinel, context.temp_allocator)
	ipf, _ := strings.replace_all(FAKE_IP, "SENTINEL", g_sentinel, context.temp_allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/ip", bin), transmute([]u8)ipf, os.Permissions_All)
	for name in ([?]string{"rfkill", "iw", "iwctl", "busctl", "dbus-send", "systemctl", "wpa_cli", "ifconfig"}) {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", bin, name), transmute([]u8)any, os.Permissions_All)
	}
	g_path_env = fmt.aprintf("%s:%s", bin, os.get_env("PATH", context.temp_allocator))
}

@(private = "file")
fired :: proc() -> bool {
	return os.exists(g_sentinel)
}

test_trap_works :: proc() {
	section("the trap")
	_, _, _, err := os.process_exec(
		{command = {"sh", "-c", fmt.tprintf("PATH=%s nmcli radio wifi off; PATH=%s rfkill block wifi", g_path_env, g_path_env)}},
		context.temp_allocator,
	)
	check(err == nil && fired(), "the fake nmcli and rfkill on PATH are reached (the trap works)")
	text, _ := os.read_entire_file_from_path(g_sentinel, context.temp_allocator)
	check(strings.contains(string(text), "radio wifi off") && strings.contains(string(text), "block wifi"), "and both wrote to the sentinel")
	os.remove(g_sentinel)
	check(!fired(), "the sentinel is clear before anything is driven")
}

// ---------------------------------------------------------------------------
// The window's own gated jobs, in this process
// ---------------------------------------------------------------------------

test_window_gate :: proc() {
	section("the window's radio-off and connect execute nothing")

	old := strings.clone(os.get_env("PATH", context.temp_allocator))
	defer delete(old)
	_ = os.set_env("PATH", g_path_env)
	defer _ = os.set_env("PATH", old)

	s := new(Store)
	s.devices = make([dynamic]Dev)
	s.aps = make([dynamic]Ap)
	s.saved = make([dynamic]Saved)
	s.backend = .Nm

	run_job(s, .Refresh)
	check(s.loaded, "a refresh against the fake NetworkManager lands")
	eq_i(len(s.devices), 3, "three interfaces")
	if len(s.devices) > 0 {
		eq_s(s.devices[0].ip4, "192.168.1.20", "wlan0's address")
	}
	check(!fired(), "reading changed nothing")

	run_job(s, .Radio_Off)
	check(!fired(), "the window's radio-off job executed NOTHING")
	check(strings.contains(s.message, "disabled"), "and says so in the window (%s)", s.message)
	run_job(s, .Connect, "Cafe", "hunter2")
	check(!fired(), "the window's connect job executed NOTHING")
	check(strings.contains(s.message, "Cafe"), "and names the network it did not join")

	// The window's radio-on is the one write it makes (it can only restore
	// connectivity). It is not on the command line at all; it is shown here
	// so that the trap is known to catch a real write from the same job
	// runner, which is what makes the two empty-sentinel checks above mean
	// something.
	run_job(s, .Radio_On)
	check(fired(), "the window's radio-on does reach nmcli, and the trap catches it")
	os.remove(g_sentinel)
}

// ---------------------------------------------------------------------------
// The command line, as child processes
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// cli_run runs this binary with the trap on PATH and NetworkManager forced
// as the backend, so the reads have something to read. `extra` are further
// environment assignments.
@(private = "file")
cli_run :: proc(extra: []string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, fmt.tprintf("WAYLAND_DISPLAY= DISPLAY= PATH=%q PALM_AUDIT=%q ", g_path_env, fmt.tprintf("%s/audit.jsonl", g_root)))
	for e in extra {
		strings.write_string(&line, e)
		strings.write_byte(&line, ' ')
	}
	strings.write_string(&line, fmt.tprintf("%q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
NM :: "NETWORK_BACKEND=nm"

test_cli_reads :: proc() {
	section("the reads")

	{
		out, code := cli_run({NM}, "status", "--json")
		eq_i(code, 0, "network status exits 0")
		problems := kit.cli_validate_output(out, STATUS_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "network status --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(out, `"backend": "NetworkManager"`), "it names the backend")
		check(strings.contains(out, `"ip4": "192.168.1.20"`), "wlan0's address")
		check(strings.contains(out, `"hwaddr": "AA:BB:CC:DD:EE:FF"`), "and its hardware address (multiline mode does not escape colons)")
		check(strings.contains(out, `"name": "Work"`), "and the saved networks")
		check(!fired(), "network status executed nothing that changes state")
	}
	{
		out, code := cli_run({NM}, "wifi", "--json")
		eq_i(code, 0, "network wifi exits 0")
		problems := kit.cli_validate_output(out, WIFI_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "network wifi --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(out, `"ssid": "Home"`) && strings.contains(out, `"ssid": "Cafe"`), "both networks in range")
		check(strings.contains(out, `"radios": 2`), "Home's two access points merged into one row")
		check(strings.index(out, `"ssid": "Home"`) < strings.index(out, `"ssid": "Cafe"`), "strongest first")
		check(!fired(), "network wifi executed nothing that changes state")
	}
	{
		os.remove(g_reads)
		out, code := cli_run({NM}, "wifi", "--rescan", "--json")
		eq_i(code, 0, "network wifi --rescan exits 0")
		check(strings.contains(out, `"rescanned": true`), "and says it rescanned")
		log, _ := os.read_entire_file_from_path(g_reads, context.temp_allocator)
		check(strings.contains(string(log), "device wifi rescan"), "the rescan was asked for")
		check(!fired(), "and a rescan changes no connection")
	}
	{
		// Without the forced backend, on a machine with no iwd and no nmcli
		// in /usr/bin, the wired interfaces still come from the kernel; the
		// Wi-Fi list is unavailable, in the documented form.
		_, code := cli_run(nil, "status", "--json")
		check(code == 0 || code == kit.EXIT_UNAVAILABLE, "status with whatever backend this machine has answers 0 or 6 (got %d)", code)
		out, wcode := cli_run(nil, "wifi", "--json")
		if wcode != 0 {
			eq_i(wcode, kit.EXIT_UNAVAILABLE, "wifi with no backend reachable is unavailable")
			check(strings.contains(out, `"error": "unavailable"`), "with the documented token")
		}
		check(!fired(), "and neither changed anything")
	}
}

test_cli_intents :: proc() {
	section("radio and connect are intent: logged, never run")

	Case :: struct {
		args: []string,
		cmd:  string,
	}
	cases := [?]Case {
		{{"radio", "off", "--json"}, "nmcli radio wifi off"},
		{{"radio", "on", "--json"}, "nmcli radio wifi on"},
		{{"connect", "Cafe", "--json"}, "nmcli device wifi connect Cafe"},
		{{"connect", "Cafe Wi-Fi", "--json"}, "nmcli device wifi connect Cafe Wi-Fi"},
	}
	for cs in cases {
		out, code := cli_run({NM}, ..cs.args)
		eq_i(code, 0, fmt.tprintf("network %s %s exits 0", cs.args[0], cs.args[1]))
		problems := kit.cli_validate_output(out, INTENT_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "network %s --json matches the intent schema", cs.args[0])
		check(strings.contains(out, fmt.tprintf(`"intent": %q`, cs.cmd)), "it names %q", cs.cmd)
		check(strings.contains(out, `"executed": false`), "and says executed: false")
		check(!fired(), "network %s %s executed NOTHING", cs.args[0], cs.args[1])
	}
	// The iwd forms, which is what Palmy itself runs. With no iwd on the bus
	// the device is not known, and the intent says so rather than guessing.
	{
		out, code := cli_run({"NETWORK_BACKEND=iwd"}, "radio", "off", "--json")
		eq_i(code, 0, "network radio off exits 0 whatever the backend")
		check(strings.contains(out, `"executed": false`), "and executes nothing")
		check(!fired(), "the sentinel is still empty")
	}
	{
		audit, _ := os.read_entire_file_from_path(fmt.tprintf("%s/audit.jsonl", g_root), context.temp_allocator)
		check(strings.count(string(audit), `"intent"`) >= len(cases), "every intent left an audit record")
	}
	// No passphrase is taken at all: there is nowhere to put one.
	{
		_, code := cli_run({NM}, "connect", "Cafe", "--password", "hunter2")
		eq_i(code, kit.EXIT_USAGE, "connect takes no --password")
		_, code2 := cli_run({NM}, "radio", "sideways")
		eq_i(code2, kit.EXIT_USAGE, "a radio state that is not on|off exits 2")
		check(!fired(), "and neither refusal ran anything")
	}
}

test_cli_surface :: proc() {
	section("the command surface")

	sf := surface()
	eq_s(sf.noun, "net", "the surface is palm's noun, net")
	for cmd in sf.commands {
		check(cmd.run != nil, "%q has an implementation", cmd.verb)
		check(len(cmd.out) > 0, "%q declares what it prints", cmd.verb)
		check(len(cmd.examples) > 0, "%q ships an example", cmd.verb)
		// Networking is read-only: read or intent, nothing else, ever.
		check(cmd.effect == .Read || cmd.effect == .Intent, "%q is %v; networking is read or intent only", cmd.verb, cmd.effect)
		switch cmd.verb {
		case "radio", "connect":
			check(cmd.effect == .Intent, "%q is intent class", cmd.verb)
		}
		for f in cmd.flags {
			check(f.name != "password" && f.name != "psk" && f.name != "passphrase", "%q takes no secret", cmd.verb)
		}
	}
	{
		out, code := cli_run(nil, "--schema")
		eq_i(code, 0, "--schema exits 0")
		check(strings.contains(out, `"noun": "net"`), "and says it is net")
	}
	for cmd in sf.commands {
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(len(words) > 0 && words[0] == "network", "the example %q is typed as the binary is named", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run({NM}, ..args[:])
			eq_i(code, 0, fmt.tprintf("the example %q parses", ex))
		}
	}
	{
		_, code := cli_run(nil, "disconnect", "wlan0")
		eq_i(code, kit.EXIT_USAGE, "there is no disconnect verb")
	}
	check(!fired(), "after the whole surface, the sentinel is still empty")
}
