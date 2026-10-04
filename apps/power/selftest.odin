package main

// `power --selftest` — headless, no compositor, no window.
//
// Four groups:
//
//   * the readers, driven from canned text and from canned sysfs trees written
//     into a scratch directory. /proc/uptime, /proc/stat's btime line, cpufreq
//     policies, /sys/class/power_supply (including the battery this machine
//     does not have), hwmon, `loginctl show-session` and `upower --dump`, each
//     with malformed and truncated input alongside the real thing.
//
//   * the formatters.
//
//   * the intent log.
//
//   * and the one assertion in this program that matters more than anything a
//     screenshot could show: confirming Restart, Shut down, Log out, Suspend
//     and Lock screen in the real UI executes nothing at all.
//
//     That last one is checked rather than asserted by inspection. The test
//     puts a scratch directory at the front of PATH holding fakes called
//     systemctl, loginctl, reboot, poweroff, shutdown and systemd-run, each of
//     which appends its arguments to a sentinel file. It proves the trap works
//     by springing it deliberately, empties the sentinel, drives the whole
//     confirmation flow for all five actions through synthetic key presses,
//     and asserts the sentinel is still empty afterwards.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

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
eq_s :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", what, got, want)
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
near :: proc(a, b: f64, what: string, tol := 1e-6) {
	checks += 1
	if math.abs(a - b) > tol {
		failures += 1
		fmt.printf("  FAIL  %s: got %.6f, want %.6f\n", what, a, b)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("power self-test")

	test_uptime()
	test_btime()
	test_cpufreq()
	test_supplies()
	test_hwmon()
	test_sessions()
	test_upower()
	test_format()
	test_log()
	test_nothing_executes()

	// The canned sysfs trees and the fake PATH directory were the test's own
	// and go away with it.
	if g_root != "" {
		_ = os.remove_all(g_root)
	}

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// A scratch directory for the canned sysfs trees
// ---------------------------------------------------------------------------

@(private = "file")
g_root: string

@(private = "file")
scratch_root :: proc() -> string {
	if g_root == "" {
		g_root = fmt.aprintf("/tmp/palmy-power-selftest-%d", os.get_pid())
		_ = os.make_directory_all(g_root)
	}
	return g_root
}

@(private = "file")
mkdirp :: proc(path: string) {
	_ = os.make_directory_all(path)
}

@(private = "file")
put :: proc(path, text: string, perm := os.Permissions_Read_All + {.Write_User}) {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		mkdirp(path[:slash])
	}
	if err := os.write_entire_file(path, transmute([]u8)text, perm); err != nil {
		fmt.printf("  FAIL  could not write the fixture %s\n", path)
		failures += 1
	}
}

// ---------------------------------------------------------------------------
// /proc/uptime
// ---------------------------------------------------------------------------

test_uptime :: proc() {
	section("/proc/uptime")

	up, idle, ok := uptime_parse("328392.87 2592714.33\n")
	check(ok, "a normal /proc/uptime parses")
	near(up, 328392.87, "uptime", 1e-2)
	near(idle, 2592714.33, "idle", 1e-2)

	// Freshly booted: the kernel prints "0.00 0.00" for a moment.
	up2, _, ok2 := uptime_parse("0.00 0.00")
	check(ok2, "a zero uptime is still a reading")
	near(up2, 0, "zero uptime")

	// Truncated mid-number — no space yet, so there is no second field and
	// nothing can be trusted.
	_, _, ok3 := uptime_parse("3283")
	check(!ok3, "a truncated /proc/uptime is refused")
	_, _, ok4 := uptime_parse("")
	check(!ok4, "an empty /proc/uptime is refused")
	_, _, ok5 := uptime_parse("\n")
	check(!ok5, "a bare newline is refused")

	// Garbage where the numbers should be: the shape is right, so it parses,
	// but the values come back zero rather than wild.
	up6, idle6, ok6 := uptime_parse("banana pancakes")
	check(ok6, "two fields of nonsense have the right shape")
	near(up6, 0, "and parse to zero uptime")
	near(idle6, 0, "and zero idle")
}

test_btime :: proc() {
	section("/proc/stat btime")

	// The real file, abbreviated: btime is nowhere near the first line.
	stat := `cpu  5355772 15823 1653639 155294631 95905 388411 159594 0 0 0
cpu0 335060 1036 103477 9703422 6000 24207 20646 0 0 0
intr 1234567 0 0 0
ctxt 2841849293
btime 1759502983
processes 8273611
procs_running 2
procs_blocked 0
softirq 1 2 3
`
	secs, ok := btime_parse(stat)
	check(ok, "btime found in a full /proc/stat")
	check(secs == 1759502983, "btime is 1759502983, got %d", secs)

	_, missing := btime_parse("cpu  1 2 3\nctxt 4\n")
	check(!missing, "a /proc/stat with no btime line is refused")

	_, truncated := btime_parse("cpu 1 2 3\nbti")
	check(!truncated, "a /proc/stat truncated inside the word btime is refused")

	// "btime" with nothing after it. The line matches the prefix, but there is
	// no number, so the parse has to fail rather than report second zero.
	_, empty := btime_parse("btime \n")
	check(!empty, "btime with no value is refused")

	_, nan := btime_parse("btime not-a-number\n")
	check(!nan, "btime with a non-numeric value is refused")
}

// ---------------------------------------------------------------------------
// cpufreq, from a canned tree
// ---------------------------------------------------------------------------

test_cpufreq :: proc() {
	section("cpufreq")

	root := scratch_root()
	base := fmt.tprintf("%s/cpu", root)

	// Four cores. cpu2 disagrees about the governor, which is what `mixed`
	// exists to notice; cpu3 is present so the scan does not stop early.
	for i in 0 ..< 4 {
		d := fmt.tprintf("%s%d/cpufreq", base, i)
		put(fmt.tprintf("%s/scaling_cur_freq", d), fmt.tprintf("%d\n", 1200000 + i * 400000))
		put(
			fmt.tprintf("%s/scaling_governor", d),
			i == 2 ? "performance\n" : "powersave\n",
		)
	}
	put(fmt.tprintf("%s0/cpufreq/scaling_driver", base), "intel_pstate\n")
	put(fmt.tprintf("%s0/cpufreq/energy_performance_preference", base), "balance_performance\n")
	put(
		fmt.tprintf("%s0/cpufreq/energy_performance_available_preferences", base),
		"default performance balance_performance balance_power power\n",
	)
	put(fmt.tprintf("%s0/cpufreq/scaling_min_freq", base), "400000\n")
	put(fmt.tprintf("%s0/cpufreq/scaling_max_freq", base), "4600000\n")
	put(fmt.tprintf("%s0/cpufreq/cpuinfo_max_freq", base), "4600000\n")
	boost := fmt.tprintf("%s/boost", root)
	put(boost, "1\n")

	saved_cpu, saved_boost := g_cpu_root, g_boost_path
	g_cpu_root = strings.clone(base)
	g_boost_path = strings.clone(boost)
	defer {
		g_cpu_root, g_boost_path = saved_cpu, saved_boost
	}

	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_else panic("arena")
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	c := cpufreq_read(al)
	check(c.present, "the canned cpufreq tree was found")
	eq_i(c.n, 4, "four policies")
	check(c.cur[0] == 1200000, "cpu0 is at 1.2 GHz, got %d", c.cur[0])
	check(c.cur[3] == 2400000, "cpu3 is at 2.4 GHz, got %d", c.cur[3])
	eq_s(c.governor, "powersave", "cpu0's governor")
	eq_s(c.driver, "intel_pstate", "the scaling driver")
	eq_s(c.epp, "balance_performance", "the energy performance preference")
	check(c.mixed, "a core with a different governor sets `mixed`")
	eq_i(c.boost, 1, "boost")
	check(c.min_khz == 400000, "the policy floor, got %d", c.min_khz)
	check(c.max_khz == 4600000, "the policy ceiling, got %d", c.max_khz)

	// (1200 + 1600 + 2000 + 2400) / 4 = 1800 MHz
	check(cpufreq_avg(c) == 1800000, "the mean clock is 1.8 GHz, got %d", cpufreq_avg(c))
	eq_i(int(cpufreq_avg(Cpufreq{})), 0, "the mean of no policies is zero, not a divide by zero")

	// A machine with no cpufreq at all: cpu0 missing means the whole feature
	// is absent, and the reader must say so rather than report zero cores as
	// if it had looked.
	g_cpu_root = fmt.tprintf("%s/nonexistent-cpu", root)
	none := cpufreq_read(al)
	check(!none.present, "a machine without cpufreq reports nothing present")
	eq_i(none.n, 0, "and no policies")
	eq_i(none.boost, -1, "and boost unknown rather than off")

	// A gap in the middle: cpu0 and cpu1 exist, cpu2 does not. The scan stops
	// at the gap rather than skipping to cpu3.
	gap := fmt.tprintf("%s/gapcpu", root)
	for i in 0 ..< 2 {
		put(fmt.tprintf("%s%d/cpufreq/scaling_cur_freq", gap, i), "1000000\n")
		put(fmt.tprintf("%s%d/cpufreq/scaling_governor", gap, i), "schedutil\n")
	}
	put(fmt.tprintf("%s3/cpufreq/scaling_cur_freq", gap), "1000000\n")
	g_cpu_root = gap
	g2 := cpufreq_read(al)
	eq_i(g2.n, 2, "the core scan stops at the first gap")

	// Truncated and malformed numbers.
	bad := fmt.tprintf("%s/badcpu", root)
	put(fmt.tprintf("%s0/cpufreq/scaling_cur_freq", bad), "not-a-number\n")
	put(fmt.tprintf("%s0/cpufreq/scaling_governor", bad), "powersave\n")
	g_cpu_root = bad
	b := cpufreq_read(al)
	check(!b.present, "a non-numeric scaling_cur_freq is not a reading")
}

// ---------------------------------------------------------------------------
// /sys/class/power_supply
// ---------------------------------------------------------------------------

test_supplies :: proc() {
	section("power supplies")

	root := scratch_root()
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_else panic("arena")
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	saved := g_supply_root
	defer {g_supply_root = saved}

	// This machine: the directory exists and is empty. That is the finding the
	// whole applet is built around, so it is asserted rather than assumed.
	empty := fmt.tprintf("%s/supply-empty", root)
	mkdirp(empty)
	g_supply_root = strings.clone(empty)
	none := supplies_read(al)
	eq_i(len(none), 0, "an empty power_supply directory yields no supplies")

	// A directory that is not there at all, which is a different thing again.
	g_supply_root = fmt.tprintf("%s/supply-missing", root)
	gone := supplies_read(al)
	eq_i(len(gone), 0, "a missing power_supply directory yields no supplies")

	// A laptop, so the battery path is exercised even though this machine
	// cannot provide one.
	lap := fmt.tprintf("%s/supply-laptop", root)
	put(fmt.tprintf("%s/BAT0/type", lap), "Battery\n")
	put(fmt.tprintf("%s/BAT0/status", lap), "Discharging\n")
	put(fmt.tprintf("%s/BAT0/capacity", lap), "83\n")
	put(fmt.tprintf("%s/AC/type", lap), "Mains\n")
	put(fmt.tprintf("%s/AC/online", lap), "0\n")
	g_supply_root = strings.clone(lap)
	sup := supplies_read(al)
	eq_i(len(sup), 2, "two supplies on the canned laptop")
	bat := -1
	ac := -1
	for s, i in sup {
		if s.name == "BAT0" {bat = i}
		if s.name == "AC" {ac = i}
	}
	check(bat >= 0 && ac >= 0, "both supplies were named")
	if bat >= 0 {
		eq_s(sup[bat].type_, "Battery", "BAT0's type")
		eq_s(sup[bat].status, "Discharging", "BAT0's status")
		eq_i(sup[bat].pct, 83, "BAT0's charge")
	}
	if ac >= 0 {
		eq_s(sup[ac].type_, "Mains", "AC's type")
		// Mains has no capacity file, and -1 is how that is said. Zero would
		// read as a flat battery.
		eq_i(sup[ac].pct, -1, "mains has no percentage")
		eq_s(sup[ac].status, "", "mains has no status file here")
	}

	// A battery whose capacity file is garbage. -1, again, rather than 0.
	odd := fmt.tprintf("%s/supply-odd", root)
	put(fmt.tprintf("%s/BAT1/type", odd), "Battery\n")
	put(fmt.tprintf("%s/BAT1/capacity", odd), "\n")
	g_supply_root = strings.clone(odd)
	o := supplies_read(al)
	eq_i(len(o), 1, "the odd supply was still listed")
	if len(o) == 1 {
		eq_i(o[0].pct, -1, "an unreadable capacity is unknown, not empty")
	}
}

// ---------------------------------------------------------------------------
// hwmon
// ---------------------------------------------------------------------------

test_hwmon :: proc() {
	section("hwmon")

	root := scratch_root()
	base := fmt.tprintf("%s/hwmon", root)

	// hwmon0: two sensors, one with a label and a critical point, one without.
	put(fmt.tprintf("%s0/name", base), "coretemp\n")
	put(fmt.tprintf("%s0/temp1_input", base), "47000\n")
	put(fmt.tprintf("%s0/temp1_label", base), "Package id 0\n")
	put(fmt.tprintf("%s0/temp1_crit", base), "100000\n")
	put(fmt.tprintf("%s0/temp2_input", base), "85500\n")
	// hwmon1 has a gap at temp1 — hwmon numbers sensors from 1 but not
	// always densely, and a chip whose first sensor is temp3 is real.
	put(fmt.tprintf("%s1/name", base), "acpitz\n")
	put(fmt.tprintf("%s1/temp3_input", base), "27800\n")
	// hwmon2 is a fan controller with no temperature at all.
	put(fmt.tprintf("%s2/name", base), "nct6798\n")
	put(fmt.tprintf("%s2/fan1_input", base), "1200\n")

	saved := g_hwmon_root
	g_hwmon_root = strings.clone(base)
	defer {g_hwmon_root = saved}

	buf := make([]u8, 8192)
	defer delete(buf)
	ts := temp_sample(buf[:], context.allocator)
	defer {
		for t in ts {
			delete(t.chip)
			delete(t.label)
		}
		delete(ts)
	}

	eq_i(len(ts), 3, "three temperatures across the canned chips")
	if len(ts) == 3 {
		// Hottest first.
		near(f64(ts[0].c), 85.5, "the hottest sensor comes first", 1e-3)
		near(f64(ts[1].c), 47.0, "then the package", 1e-3)
		near(f64(ts[2].c), 27.8, "then the ACPI zone", 1e-3)
		eq_s(ts[1].label, "Package id 0", "a labelled sensor keeps its label")
		// An unlabelled sensor is named after its chip rather than left blank.
		eq_s(ts[0].label, "coretemp", "an unlabelled sensor falls back to the chip name")
		eq_s(ts[0].chip, "coretemp", "and belongs to that chip")
		near(f64(ts[1].crit), 100, "the critical point is read", 1e-3)
		near(f64(ts[0].crit), 0, "and is zero when the chip does not publish one", 1e-3)
	}

	g_hwmon_root = fmt.tprintf("%s/no-hwmon-here", root)
	ts2 := temp_sample(buf[:], context.allocator)
	eq_i(len(ts2), 0, "a machine with no hwmon reports no temperatures")
	delete(ts2)
}

// ---------------------------------------------------------------------------
// loginctl
// ---------------------------------------------------------------------------

test_sessions :: proc() {
	section("loginctl show-session")

	// Verbatim from this machine, reordered to prove order does not matter.
	block := `Id=2
Name=alex
Seat=seat0
TTY=tty2
Type=wayland
Class=user
State=active
Service=login
Timestamp=Sat 2026-10-04 09:13:28 CEST
Remote=no
Active=yes
IdleHint=no
LockedHint=no
CanLock=yes
Leader=1182
`
	s := Session{}
	session_parse_props(&s, block, context.allocator)
	eq_s(s.user, "alex", "the session's user")
	eq_s(s.seat, "seat0", "its seat")
	eq_s(s.tty, "tty2", "its tty")
	eq_s(s.type_, "wayland", "its type")
	eq_s(s.class, "user", "its class")
	eq_s(s.state, "active", "its state")
	eq_s(s.service, "login", "its service")
	eq_s(s.since, "Sat 2026-10-04 09:13:28 CEST", "the timestamp is kept whole")
	check(!s.remote, "it is not remote")
	check(s.active, "it is active")
	check(!s.idle, "it is not idle")
	check(!s.locked, "it is not locked")
	check(s.can_lock, "it can be locked")
	eq_i(s.leader, 1182, "the leader pid")

	// A locked, idle, remote session, which is the other half of every flag.
	s2 := Session{}
	session_parse_props(
		&s2,
		"Name=root\nRemote=yes\nActive=no\nIdleHint=yes\nLockedHint=yes\nCanLock=no\n",
		context.allocator,
	)
	check(s2.remote && s2.idle && s2.locked, "the yes flags all read as yes")
	check(!s2.active && !s2.can_lock, "the no flags all read as no")

	// Malformed input. A property with no '=' is skipped, an empty value is
	// kept as empty, and an unknown key is ignored rather than fatal.
	s3 := Session{}
	session_parse_props(
		&s3,
		"this line has no equals sign\nTTY=\nSomethingNew=1\nName=bob\nLeader=not-a-pid\n",
		context.allocator,
	)
	eq_s(s3.user, "bob", "a name after a junk line is still found")
	eq_s(s3.tty, "", "an empty value stays empty")
	eq_i(s3.leader, 0, "an unparseable leader is zero")

	// Truncated mid-key: nothing to take, and nothing breaks.
	s4 := Session{}
	session_parse_props(&s4, "Name=alex\nSeat", context.allocator)
	eq_s(s4.user, "alex", "the complete line before the truncation survives")
	eq_s(s4.seat, "", "the truncated one contributes nothing")
}

// ---------------------------------------------------------------------------
// upower
// ---------------------------------------------------------------------------

test_upower :: proc() {
	section("upower --dump")

	// This machine's real dump: a Bluetooth headset and the daemon block, with
	// no system battery anywhere in it.
	dump := `Device: /org/freedesktop/UPower/devices/headset_dev_AC_80_0A_51_2B_33
  native-path:          /org/bluez/hci0/dev_AC_80_0A_51_2B_33
  model:                WH-1000XM4
  power supply:         no
  updated:              Sat 04 Oct 2026 12:31:02 PM CEST (14 seconds ago)
  has history:          no
  has statistics:       no
  headset
    present:             yes
    rechargeable:        yes
    state:               discharging
    warning-level:       none
    percentage:          70%
    icon-name:          'battery-full-symbolic'

Device: /org/freedesktop/UPower/devices/DisplayDevice
  power supply:         yes
  updated:              Sat 04 Oct 2026 12:30:00 PM CEST (76 seconds ago)
  has history:          no
  has statistics:       no
  battery
    present:             yes
    state:               fully-charged
    warning-level:       none
    percentage:          100%

Daemon:
  daemon-version:  1.90.9
  on-battery:      no
  lid-is-closed:   no
  lid-is-present:  no
  critical-action: HybridSleep
`
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_else panic("arena")
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	u := upower_parse(dump, al)
	check(u.ok, "the dump parsed")
	eq_i(len(u.devs), 2, "two devices")
	if len(u.devs) == 2 {
		eq_s(u.devs[0].model, "WH-1000XM4", "the headset's model")
		eq_s(u.devs[0].kind, "headset", "its kind")
		eq_i(u.devs[0].pct, 70, "its charge")
		eq_s(u.devs[0].warn, "none", "its warning level")
		check(!u.devs[0].supply, "a headset is not a power supply")
		check(
			strings.has_suffix(u.devs[0].path, "headset_dev_AC_80_0A_51_2B_33"),
			"its object path, got %q",
			u.devs[0].path,
		)
		eq_s(u.devs[1].kind, "battery", "the display device is a battery")
		eq_i(u.devs[1].pct, 100, "charged")
		check(u.devs[1].supply, "and it is a power supply")
		// The model line is absent from the second device, which must not
		// inherit the first one's.
		eq_s(u.devs[1].model, "", "a device with no model line has no model")
	}
	eq_s(u.version, "1.90.9", "the daemon version")
	check(!u.on_battery, "not on battery")
	check(!u.lid_present, "no lid")
	eq_s(u.crit_action, "HybridSleep", "the critical action")

	// The Daemon block must flush the device in progress. A dump that ends at
	// the daemon without a blank line is the common shape.
	u2 := upower_parse(
		"Device: /dev/one\n  model: X\n  battery\n    percentage: 5%\nDaemon:\n  on-battery: yes\n",
		al,
	)
	eq_i(len(u2.devs), 1, "the device before the Daemon block is kept")
	if len(u2.devs) == 1 {
		eq_i(u2.devs[0].pct, 5, "its charge")
	}
	check(u2.on_battery, "on-battery: yes")

	// Truncated mid-device: whatever was complete is kept.
	u3 := upower_parse("Device: /dev/two\n  model:  Thing\n  perce", al)
	eq_i(len(u3.devs), 1, "a truncated dump still yields the device")
	if len(u3.devs) == 1 {
		eq_s(u3.devs[0].model, "Thing", "and the model it had got to")
		eq_i(u3.devs[0].pct, -1, "with an unknown charge rather than zero")
	}

	// Nonsense, and nothing at all.
	u4 := upower_parse("no colons here\njust words\n", al)
	eq_i(len(u4.devs), 0, "a dump with no devices yields none")
	u5 := upower_parse("", al)
	eq_i(len(u5.devs), 0, "an empty dump yields none")
	// A percentage with no % sign, and one that is not a number.
	u6 := upower_parse("Device: /d\n  percentage: 42\n", al)
	eq_i(u6.devs[0].pct, 42, "a percentage without its sign still parses")
	u7 := upower_parse("Device: /d\n  percentage: lots\n", al)
	eq_i(u7.devs[0].pct, -1, "a non-numeric percentage is unknown")
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

test_format :: proc() {
	section("formatting")

	eq_s(fmt_uptime(0), "0m 00s", "zero")
	eq_s(fmt_uptime(59), "0m 59s", "under a minute")
	eq_s(fmt_uptime(60), "1m 00s", "exactly a minute")
	eq_s(fmt_uptime(3599), "59m 59s", "just under an hour")
	eq_s(fmt_uptime(3600), "1h 00m 00s", "exactly an hour")
	eq_s(fmt_uptime(86399), "23h 59m 59s", "just under a day")
	eq_s(fmt_uptime(86400), "1d 00h 00m", "exactly a day")
	eq_s(fmt_uptime(328392.87), "3d 19h 13m", "this machine's uptime")

	eq_s(fmt_ghz(0), "—", "an unknown clock is a dash, not 0.00 GHz")
	eq_s(fmt_ghz(1200000), "1.20 GHz", "1.2 GHz")
	eq_s(fmt_ghz(4600000), "4.60 GHz", "4.6 GHz")

	eq_s(boot_label(0), "unknown", "no btime means no boot time")
	eq_s(boot_label(-1), "unknown", "and neither does a negative one")
	// 1759502983 = 2025-10-03 15:29:43 UTC
	eq_s(boot_label(1759502983), "2025-10-03 14:49 UTC", "a real btime")

	eq_s(chassis_label("3"), "Desktop", "chassis 3")
	eq_s(chassis_label("35"), "Mini PC", "chassis 35 — what this machine is")
	eq_s(chassis_label("10"), "Notebook", "chassis 10")
	eq_s(chassis_label(""), "Unknown", "an unreadable chassis type")
	eq_s(chassis_label("99"), "Chassis type 99", "an unmapped code prints itself")
}

// ---------------------------------------------------------------------------
// The intent log
// ---------------------------------------------------------------------------

test_log :: proc() {
	section("the intent log")

	before := g_log_count
	log_intent("systemctl reboot", "Restart")
	eq_i(g_log_count, before + 1, "one entry was added")
	r := log_recent(1)
	eq_i(len(r), 1, "log_recent(1) returns one")
	if len(r) == 1 {
		eq_s(r[0].cmd, "systemctl reboot", "the command, verbatim")
		eq_s(r[0].label, "Restart", "and its label")
		check(len(r[0].when_) == 8, "a hh:mm:ss stamp, got %q", r[0].when_)
	}

	// log_recent hands back a window of the ring in the order the intents
	// happened, oldest first, which is the order the log panel reads in.
	log_intent("systemctl poweroff", "Shut down")
	r2 := log_recent(2)
	eq_i(len(r2), 2, "two entries back")
	if len(r2) == 2 {
		eq_s(r2[0].cmd, "systemctl reboot", "oldest of the window first")
		eq_s(r2[1].cmd, "systemctl poweroff", "then the newest")
	}
	eq_i(len(log_recent(1000)), min(g_log_count, LOG_N), "asking for more than exists is clamped")

	// The ring wraps without going out of bounds or returning stale entries.
	for i in 0 ..< LOG_N + 5 {
		log_intent(fmt.tprintf("cmd-%d", i), "x")
	}
	full := log_recent(LOG_N)
	eq_i(len(full), LOG_N, "a wrapped ring still returns LOG_N entries")
	if len(full) == LOG_N {
		eq_s(
			full[LOG_N - 1].cmd,
			fmt.tprintf("cmd-%d", LOG_N + 4),
			"the newest entry after wrapping",
		)
		eq_s(
			full[0].cmd,
			fmt.tprintf("cmd-%d", 5),
			"and the oldest one still in the ring",
		)
		for e, i in full {
			check(e.used, "entry %d is live", i)
		}
	}

	// Every action's command is spelled out, and none of them is empty: the
	// log is the applet's whole output, so an action with no command would
	// silently do nothing and say nothing.
	for a in Action {
		info := ACTIONS[a]
		check(info.cmd != "", "%v has a command", a)
		check(info.label != "", "%v has a label", a)
		check(info.key != "", "%v has a key", a)
	}
	eq_s(ACTIONS[.Reboot].cmd, "systemctl reboot", "Restart's command")
	eq_s(ACTIONS[.Shutdown].cmd, "systemctl poweroff", "Shut down's command")
	eq_s(ACTIONS[.Suspend].cmd, "systemctl suspend", "Suspend's command")
	eq_s(ACTIONS[.Logout].cmd, "loginctl terminate-session self", "Log out's command")
	eq_s(ACTIONS[.Lock].cmd, "loginctl lock-session", "Lock screen's command")
}

// ---------------------------------------------------------------------------
// Nothing executes
// ---------------------------------------------------------------------------

@(private = "file")
FAKES := [?]string{"systemctl", "loginctl", "reboot", "poweroff", "shutdown", "halt", "systemd-run"}

@(private = "file")
step :: proc(off: ^p.Offscreen, m: ^Model) {
	ui := p.offscreen_begin(off)
	keys(ui, nil, m)
	build(ui, m)
	p.offscreen_end(off)
}

test_nothing_executes :: proc() {
	section("confirming an action executes nothing")

	root := scratch_root()
	bin := fmt.tprintf("%s/fakebin", root)
	mkdirp(bin)
	sentinel := fmt.aprintf("%s/fired", bin)
	defer delete(sentinel)
	os.remove(sentinel)

	// Each fake records that it ran and exits 0. None of them can reach the
	// real tool: the scratch directory is first on PATH and the scripts do not
	// re-exec anything.
	for name in FAKES {
		path := fmt.tprintf("%s/%s", bin, name)
		put(
			path,
			fmt.tprintf(
				"#!/bin/sh\nprintf '%%s %%s\\n' \"$0\" \"$*\" >> %s\nexit 0\n",
				sentinel,
			),
			os.Permissions_All,
		)
	}

	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	defer delete(old_path)
	_ = os.set_env("PATH", fmt.tprintf("%s:%s", bin, old_path))
	defer {_ = os.set_env("PATH", old_path)}

	// Spring the trap deliberately, so that the negative assertion below means
	// something. If this fails, PATH interception does not work on this build
	// and the rest of this section proves nothing.
	_, _, _, _ = os.process_exec({command = {"systemctl", "--version"}}, context.temp_allocator)
	check(os.exists(sentinel), "the fake systemctl on PATH is reached (the trap works)")
	os.remove(sentinel)
	check(!os.exists(sentinel), "the sentinel is clear before the applet is driven")

	// Now the real UI, with the real key handler and the real draw.
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.fast) or_else panic("fast arena")
	defer virtual.arena_destroy(&m.arena)
	defer virtual.arena_destroy(&m.fast)
	m.al = virtual.arena_allocator(&m.arena)
	// Everything the window shows, canned: no subprocess runs during this
	// section, which is the point of it.
	m.host = Host {
		hostname  = "selftest",
		kernel    = "7.2.5-3-omarchy",
		cpu_model = "AMD Ryzen 9 selftest",
		chassis   = "35",
		distro    = "Omarchy",
	}
	m.up, m.idle = 328392.87, 2592714.33
	m.btime = 1759502983
	m.loaded = true
	m.freq = Cpufreq {
		n        = 2,
		present  = true,
		governor = "powersave",
		driver   = "amd-pstate-epp",
		epp      = "balance_performance",
		boost    = 1,
		min_khz  = 400000,
		max_khz  = 4600000,
	}
	m.freq.cur[0], m.freq.cur[1] = 1200000, 2400000

	before := g_log_count

	// Two frames to settle the tree, then every action in turn: its key, Right
	// to move off Cancel onto the action button, Return to confirm.
	step(off, m)
	step(off, m)

	Case :: struct {
		key:  u32,
		a:    Action,
	}
	cases := [?]Case {
		{'b', .Reboot},
		{'p', .Shutdown},
		{'o', .Logout},
		{'s', .Suspend},
		{'l', .Lock},
	}
	for c in cases {
		p.press_key(off, c.key)
		step(off, m)
		check(m.confirm, "%v opened a confirmation", c.a)
		check(m.sel == c.a, "and armed %v, got %v", c.a, m.sel)
		eq_i(m.confirm_sel, 0, "with Cancel selected by default")

		p.press_key(off, p.KEY_RIGHT)
		step(off, m)
		eq_i(m.confirm_sel, 1, "Right moves onto the action button")

		p.press_key(off, p.KEY_RETURN)
		step(off, m)
		check(!m.confirm, "confirming closed the dialog")

		// The whole point.
		check(
			!os.exists(sentinel),
			"confirming %v executed NOTHING (no %s was run)",
			c.a,
			ACTIONS[c.a].cmd,
		)
	}

	// Five confirmations, five log entries, and the commands are exactly the
	// ones the rows advertise.
	eq_i(g_log_count - before, len(cases), "one logged intent per confirmation")
	recent := log_recent(len(cases))
	if len(recent) == len(cases) {
		for c, i in cases {
			// Oldest first, which is the order they were confirmed in.
			eq_s(recent[i].cmd, ACTIONS[c.a].cmd, fmt.tprintf("%v logged its command", c.a))
		}
	}

	// Cancelling runs nothing and logs nothing either.
	count_before := g_log_count
	p.press_key(off, 'b')
	step(off, m)
	check(m.confirm, "Restart armed again")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, m)
	check(!m.confirm, "Escape closed it")
	eq_i(g_log_count, count_before, "cancelling logs nothing")
	check(!os.exists(sentinel), "and still executes nothing")

	// Confirming with Cancel selected is also a cancel.
	p.press_key(off, 'p')
	step(off, m)
	p.press_key(off, p.KEY_RETURN)
	step(off, m)
	check(!m.confirm, "Return on Cancel closed the dialog")
	eq_i(g_log_count, count_before, "and logged nothing")
	check(!os.exists(sentinel), "and executed nothing")

	// The window drew something: a frame of solid background would mean the
	// assertions above were made against an interface that never rendered.
	check(ink(off) > 0.01, "the interface actually drew (ink %.3f)", ink(off))

	if shot := os.get_env("POWER_SELFTEST_PNG", context.temp_allocator); shot != "" {
		p.offscreen_write_png(off, shot)
		fmt.printf("  wrote %s\n", shot)
	}
}

// ---------------------------------------------------------------------------
// `power --shot out.png`
//
// The real model, read off the real machine, rendered through palmy's
// offscreen renderer at exactly the window size. On a shared desktop the
// window manager decides where a window goes and what sits on top of it;
// offscreen the frame is the same every time, which is what makes a layout
// change reviewable.
// ---------------------------------------------------------------------------

shot :: proc(path: string, keys_to_press: []u32 = nil) {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.fast) or_else panic("fast arena")
	m.al = virtual.arena_allocator(&m.arena)
	m.host = host_read(context.allocator)
	refresh_slow(m)
	refresh_fast(m)
	temps_kick()
	for _ in 0 ..< 200 {
		if !temps_busy() {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	pump_temps(m)

	step(off, m)
	step(off, m)
	for k in keys_to_press {
		p.press_key(off, k)
		step(off, m)
	}
	step(off, m)
	if p.offscreen_write_png(off, path) {
		fmt.eprintfln("[power] wrote %s", path)
	} else {
		fmt.eprintfln("[power] could not write %s", path)
	}
}

// ink is the fraction of pixels that are not the background colour, which is
// the cheapest way to assert that a frame is not blank.
@(private = "file")
ink :: proc(off: ^p.Offscreen) -> f32 {
	px := p.offscreen_pixels(off)
	if len(px) == 0 {
		return 0
	}
	bg := px[0]
	n := 0
	for v in px {
		if v != bg {
			n += 1
		}
	}
	return f32(n) / f32(len(px))
}

// load_selftest_fonts mirrors what kit.start does to a window's font set. kit
// only offers it attached to a real window, so an offscreen render has to
// repeat it.
FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"
MONO_CANDIDATES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

load_selftest_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_CANDIDATES {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}
