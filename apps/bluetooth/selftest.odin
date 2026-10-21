package main

// `bluetooth --selftest` — headless, no window, and it touches no adapter.
//
// The parsers are driven from canned bluetoothctl text, and the command line
// is driven as real child processes with a trap first on PATH: a fake
// `bluetoothctl` that answers `show`, `devices` and `info` from canned output
// shaped like this machine's (a paired, connected headset; a nearby phone)
// and writes every other request — power, scan, connect, disconnect, pair,
// trust, remove — to a sentinel file, and a fake `rfkill` that answers `list`
// and sends `block` / `unblock` to the same sentinel. The trap is sprung once
// on purpose, so that the sentinel being empty after every intent command
// means something.

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
g_path_env: string

HEADSET :: "AC:80:0A:51:2B:33"
PHONE :: "5C:F3:70:11:22:44"

selftest :: proc() -> int {
	fmt.println("bluetooth self-test")
	g_root = fmt.aprintf("/tmp/palmy-bluetooth-selftest-%d", os.get_pid())
	_ = os.make_directory_all(g_root)
	defer _ = os.remove_all(g_root)

	test_parsers()
	test_action_words()
	make_trap()
	test_trap_works()
	test_cli_reads()
	test_cli_intents()
	test_cli_surface()

	fmt.printf("\n%d assertions, %d failures\n", checks, failures)
	return failures == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------

test_parsers :: proc() {
	section("bluetoothctl's text")

	v, ok := field("\tPowered: yes", "Powered")
	check(ok && v == "yes", "a tab-indented field is read")
	_, ok2 := field("\tPoweredState: yes", "Powered")
	check(!ok2, "a longer key with the same prefix is not mistaken for it")
	n, ok3 := paren_int("0xffffffab (-85)")
	check(ok3 && n == -85, "RSSI reads its decimal half")
	c, ok4 := hex_word("0x00240404 (2360324)")
	check(ok4 && c == 0x00240404, "Class reads its hex half")
	eq_s(paren_tag("Controller 00:1A:7D:DA:71:13 (public)"), "public", "the address type")
	check(same_hex("AC-80-0A-51-2B-33", HEADSET), "a dashed alias is the address itself")
	check(!same_hex("CMF Headphone Pro", HEADSET), "a real name is not")
	check(kind_from_class(0x00240404) == .Headset, "class 0x240404 is a headset")
	check(valid_addr(HEADSET), "a MAC address is a valid address")
	check(!valid_addr("AC:80:0A:51:2B:3"), "a short one is not")
	check(!valid_addr("AC:80:0A:51:2B:33; rm -rf ~"), "nor one with anything spliced onto it")
}

test_action_words :: proc() {
	section("every action's command is built in one place")

	j :: proc(w: []string) -> string {return strings.join(w, " ", context.temp_allocator)}
	eq_s(j(action_words(.Power, "", false)), "bluetoothctl power off", "power off")
	eq_s(j(action_words(.Power, "", true)), "bluetoothctl power on", "power on")
	eq_s(j(action_words(.Discoverable, "", true)), "bluetoothctl discoverable on", "discoverable on")
	eq_s(j(action_words(.Scan, "", true)), fmt.tprintf("bluetoothctl --timeout %d scan on", SCAN_SECS), "scan")
	eq_s(j(action_words(.Connect, HEADSET, true)), "bluetoothctl connect " + HEADSET, "connect")
	eq_s(j(action_words(.Disconnect, HEADSET, true)), "bluetoothctl disconnect " + HEADSET, "disconnect")
	eq_s(j(action_words(.Pair, PHONE, true)), "bluetoothctl pair " + PHONE, "pair")
	eq_s(j(action_words(.Trust, PHONE, true)), "bluetoothctl trust " + PHONE, "trust")
	// argv_own is what the window's job runs: the same words, on the heap.
	owned := argv_own(..action_words(.Disconnect, HEADSET, true))
	eq_s(j(owned), "bluetoothctl disconnect " + HEADSET, "the window's job runs exactly those words")
	for s in owned {delete(s)}
	delete(owned)
}

// ---------------------------------------------------------------------------
// The trap
// ---------------------------------------------------------------------------

@(private = "file")
FAKE_BLUETOOTHCTL :: `#!/bin/sh
case "$1" in
  show)
    printf 'Controller 00:1A:7D:DA:71:13 (public)\n\tName: rexgnome\n\tAlias: rexgnome\n\tClass: 0x007c010c (8126732)\n\tPowered: yes\n\tDiscoverable: no\n\tDiscoverableTimeout: 0x000000b4 (180)\n\tPairable: yes\n\tUUID: Audio Source (0000110a-0000-1000-8000-00805f9b34fb)\n\tDiscovering: no\n'
    exit 0 ;;
  devices)
    case "$2" in
      Paired|Connected|Trusted) printf 'Device AC:80:0A:51:2B:33 CMF Headphone Pro\n' ;;
      "") printf 'Device AC:80:0A:51:2B:33 CMF Headphone Pro\nDevice 5C:F3:70:11:22:44 5C-F3-70-11-22-44\n' ;;
    esac
    exit 0 ;;
  info)
    case "$2" in
      AC:80:0A:51:2B:33)
        printf 'Device AC:80:0A:51:2B:33 (public)\n\tName: CMF Headphone Pro\n\tAlias: CMF Headphone Pro\n\tClass: 0x00240404 (2360324)\n\tIcon: audio-headset\n\tPaired: yes\n\tBonded: yes\n\tTrusted: yes\n\tBlocked: no\n\tConnected: yes\n\tLegacyPairing: no\n\tUUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)\n\tBattery Percentage: 0x46 (70)\n' ;;
      5C:F3:70:11:22:44)
        printf 'Device 5C:F3:70:11:22:44 (random)\n\tAlias: 5C-F3-70-11-22-44\n\tPaired: no\n\tBonded: no\n\tTrusted: no\n\tBlocked: no\n\tConnected: no\n\tLegacyPairing: no\n\tRSSI: 0xffffffab (-85)\n' ;;
      *) printf 'Device %s not available\n' "$2" ;;
    esac
    exit 0 ;;
esac
printf '%s %s\n' "$0" "$*" >> SENTINEL
exit 0
`

@(private = "file")
FAKE_RFKILL :: `#!/bin/sh
case "$1" in
  list) printf '1: hci0: Bluetooth\n\tSoft blocked: no\n\tHard blocked: no\n'; exit 0 ;;
esac
printf '%s %s\n' "$0" "$*" >> SENTINEL
exit 0
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
	put :: proc(path, body: string) {
		text, _ := strings.replace_all(body, "SENTINEL", g_sentinel, context.temp_allocator)
		_ = os.write_entire_file(path, transmute([]u8)text, os.Permissions_All)
	}
	put(fmt.tprintf("%s/bluetoothctl", bin), FAKE_BLUETOOTHCTL)
	put(fmt.tprintf("%s/rfkill", bin), FAKE_RFKILL)
	for name in ([?]string{"btmgmt", "hciconfig", "busctl", "dbus-send", "systemctl", "wl-copy"}) {
		put(fmt.tprintf("%s/%s", bin, name), FAKE_ANY)
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
		{command = {"sh", "-c", fmt.tprintf("PATH=%s bluetoothctl power off; PATH=%s rfkill block bluetooth", g_path_env, g_path_env)}},
		context.temp_allocator,
	)
	text, _ := os.read_entire_file_from_path(g_sentinel, context.temp_allocator)
	check(err == nil && strings.contains(string(text), "power off"), "the fake bluetoothctl on PATH is reached (the trap works)")
	check(strings.contains(string(text), "block bluetooth"), "and so is the fake rfkill")
	os.remove(g_sentinel)
	check(!fired(), "the sentinel is clear before anything is driven")
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

@(private = "file")
cli_run :: proc(path: string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, fmt.tprintf("WAYLAND_DISPLAY= DISPLAY= PATH=%q PALM_AUDIT=%q ", path, fmt.tprintf("%s/audit.jsonl", g_root)))
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

test_cli_reads :: proc() {
	section("the reads")

	{
		out, code := cli_run(g_path_env, "status", "--json")
		eq_i(code, 0, "bluetooth status exits 0")
		problems := kit.cli_validate_output(out, STATUS_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "bluetooth status --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(out, `"address": "00:1A:7D:DA:71:13"`), "the adapter's address")
		check(strings.contains(out, `"powered": true`), "powered")
		check(strings.contains(out, `"soft_blocked": false`), "and not blocked")
	}
	{
		out, code := cli_run(g_path_env, "devices", "--json")
		eq_i(code, 0, "bluetooth devices exits 0")
		problems := kit.cli_validate_output(out, DEVICES_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "bluetooth devices --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(out, `"name": "CMF Headphone Pro"`), "the headset, by name")
		check(strings.contains(out, `"battery": 70`), "with its battery")
		check(strings.contains(out, `"name": "Unnamed device"`), "a placeholder alias is not shown as a name")
		check(strings.contains(out, `"count": 2`), "two devices")
		check(strings.index(out, HEADSET) < strings.index(out, PHONE), "paired first")
	}
	{
		out, code := cli_run(g_path_env, "devices", "--connected", "--json")
		eq_i(code, 0, "bluetooth devices --connected exits 0")
		check(strings.contains(out, `"count": 1`) && !strings.contains(out, PHONE), "only the connected headset")
	}
	{
		out, code := cli_run(g_path_env, "device", strings.to_lower(HEADSET, context.temp_allocator), "--json")
		eq_i(code, 0, "bluetooth device <addr> exits 0, whatever the case of the address")
		problems := kit.cli_validate_output(out, DEVICE_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "bluetooth device --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(out, `"kind": "Headset"`), "it is a headset")
		check(strings.contains(out, `"connected": true`), "and connected")
	}
	{
		out, code := cli_run(g_path_env, "device", "00:00:00:00:00:01", "--json")
		eq_i(code, kit.EXIT_NOT_FOUND, "a device BlueZ does not know exits 3")
		check(strings.contains(out, `"error": "not found"`), "with the documented token")
	}
	{
		// No bluetoothctl at all: unavailable, in the documented form.
		empty := fmt.tprintf("%s/empty", g_root)
		_ = os.make_directory_all(empty)
		out, code := cli_run(empty, "status", "--json")
		eq_i(code, kit.EXIT_UNAVAILABLE, "with no bluetoothctl, status exits 6")
		check(strings.contains(out, `"error": "unavailable"`), "with the documented token")
	}
	check(!fired(), "reading changed nothing: no power, scan, connect or block was run")
}

test_cli_intents :: proc() {
	section("every action is intent: logged, never run")

	Case :: struct {
		args: []string,
		cmd:  string,
	}
	cases := [?]Case {
		{{"power", "off", "--json"}, "bluetoothctl power off"},
		{{"power", "on", "--json"}, "bluetoothctl power on"},
		{{"discoverable", "on", "--json"}, "bluetoothctl discoverable on"},
		{{"scan", "--json"}, fmt.tprintf("bluetoothctl --timeout %d scan on", SCAN_SECS)},
		{{"connect", PHONE, "--json"}, "bluetoothctl connect " + PHONE},
		{{"disconnect", HEADSET, "--json"}, "bluetoothctl disconnect " + HEADSET},
		{{"pair", PHONE, "--json"}, "bluetoothctl pair " + PHONE},
		{{"trust", "5c:f3:70:11:22:44", "--json"}, "bluetoothctl trust " + PHONE},
	}
	for cs in cases {
		out, code := cli_run(g_path_env, ..cs.args)
		eq_i(code, 0, fmt.tprintf("bluetooth %s exits 0", strings.join(cs.args[:len(cs.args) - 1], " ", context.temp_allocator)))
		problems := kit.cli_validate_output(out, INTENT_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "bluetooth %s --json matches the intent schema", cs.args[0])
		check(strings.contains(out, fmt.tprintf(`"intent": %q`, cs.cmd)), "it names %q, the window's own command", cs.cmd)
		check(strings.contains(out, `"executed": false`), "and says executed: false")
		check(!fired(), "bluetooth %s executed NOTHING", cs.args[0])
	}
	{
		audit, _ := os.read_entire_file_from_path(fmt.tprintf("%s/audit.jsonl", g_root), context.temp_allocator)
		check(strings.count(string(audit), `"intent"`) >= len(cases), "every intent left an audit record")
	}
	{
		_, code := cli_run(g_path_env, "connect", "AC:80:0A:51:2B:33;reboot")
		eq_i(code, kit.EXIT_USAGE, "an address with anything spliced onto it is refused")
		_, code2 := cli_run(g_path_env, "power", "sideways")
		eq_i(code2, kit.EXIT_USAGE, "a power state that is not on|off exits 2")
		check(!fired(), "and neither refusal ran anything")
	}
}

test_cli_surface :: proc() {
	section("the command surface")

	sf := surface()
	eq_s(sf.noun, "bluetooth", "the surface is named bluetooth")
	for cmd in sf.commands {
		check(cmd.run != nil, "%q has an implementation", cmd.verb)
		check(len(cmd.out) > 0, "%q declares what it prints", cmd.verb)
		check(len(cmd.examples) > 0, "%q ships an example", cmd.verb)
		// Read-only by rule: read or intent, nothing else, ever.
		check(cmd.effect == .Read || cmd.effect == .Intent, "%q is %v; bluetooth is read or intent only", cmd.verb, cmd.effect)
		switch cmd.verb {
		case "status", "devices", "device":
			check(cmd.effect == .Read, "%q is read class", cmd.verb)
		case:
			check(cmd.effect == .Intent, "%q changes state, so it is intent class", cmd.verb)
		}
		for bad in ([?]string{"remove", "forget", "untrust", "block", "unpair"}) {
			check(cmd.verb != bad, "there is no %q verb", bad)
		}
	}
	{
		out, code := cli_run(g_path_env, "--schema")
		eq_i(code, 0, "--schema exits 0")
		check(strings.contains(out, `"noun": "bluetooth"`), "and names the noun")
	}
	for cmd in sf.commands {
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(len(words) > 0 && words[0] == "bluetooth", "the example %q starts with the binary's name", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(g_path_env, ..args[:])
			eq_i(code, 0, fmt.tprintf("the example %q parses", ex))
		}
	}
	check(!fired(), "after the whole surface, the sentinel is still empty")
}
