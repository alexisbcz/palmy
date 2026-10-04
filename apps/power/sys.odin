package main

// What this machine will actually tell you about its own power and session
// state.
//
// The important thing it will not tell you: there is no battery.
// /sys/class/power_supply is empty, because this is a desktop. A power applet
// that draws a battery gauge here would be drawing a number it invented, so
// this one says so plainly and shows what is really there instead:
//
//   /proc/uptime, /proc/stat btime         how long it has been up
//   /sys/devices/system/cpu/cpu*/cpufreq   governor, driver, frequency, boost
//   /sys/class/hwmon/*/temp*_input         thermal state
//   loginctl list-sessions / show-session  who is logged in
//   upower --dump                          anything with a battery that is
//                                          genuinely attached, such as a
//                                          Bluetooth headset

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

@(private)
g_buf: [64 * 1024]u8

slurp_into :: proc(path: string, buf: []u8) -> (text: string, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return "", false
	}
	defer os.close(f)
	total := 0
	for total < len(buf) {
		n, rerr := os.read(f, buf[total:])
		if n > 0 {
			total += n
		}
		if n <= 0 || rerr != nil {
			break
		}
	}
	return string(buf[:total]), total > 0
}

slurp :: proc(path: string) -> (string, bool) {
	return slurp_into(path, g_buf[:])
}

paths :: proc(buf: []u8, a: string, b: string = "", c: string = "") -> string {
	n := 0
	put :: proc(buf: []u8, n: ^int, s: string) {
		k := min(len(s), len(buf) - n^)
		copy(buf[n^:], s[:k])
		n^ += k
	}
	put(buf, &n, a)
	put(buf, &n, b)
	put(buf, &n, c)
	return string(buf[:n])
}

pathi :: proc(buf: []u8, a: string, v: int, c: string = "") -> string {
	d: [24]u8
	i := len(d)
	u := u64(v)
	if u == 0 {
		i -= 1
		d[i] = '0'
	}
	for u > 0 {
		i -= 1
		d[i] = u8('0' + u % 10)
		u /= 10
	}
	return paths(buf, a, string(d[i:]), c)
}

read_u64_into :: proc(path: string, buf: []u8) -> (v: u64, ok: bool) {
	s, got := slurp_into(path, buf)
	if !got {
		return 0, false
	}
	return strconv.parse_u64(strings.trim_space(s))
}

read_u64 :: proc(path: string) -> (u64, bool) {
	return read_u64_into(path, g_buf[:])
}

read_line_into :: proc(
	path: string,
	buf: []u8,
	al := context.allocator,
) -> (s: string, ok: bool) {
	text, got := slurp_into(path, buf)
	if !got {
		return "", false
	}
	t := strings.trim_space(text)
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = t[:nl]
	}
	return strings.clone(t, al), true
}

read_line :: proc(path: string, al := context.allocator) -> (string, bool) {
	return read_line_into(path, g_buf[:], al)
}

// ---------------------------------------------------------------------------
// Uptime
// ---------------------------------------------------------------------------

uptime_read :: proc() -> (up, idle: f64, ok: bool) {
	text, got := slurp("/proc/uptime")
	if !got {
		return 0, 0, false
	}
	return uptime_parse(text)
}

// uptime_parse is the whole of the above that is not I/O, split out so a test
// can hand it a line /proc never produces.
uptime_parse :: proc(text: string) -> (up, idle: f64, ok: bool) {
	r := strings.trim_space(text)
	sp := strings.index_byte(r, ' ')
	if sp <= 0 {
		return 0, 0, false
	}
	up, _ = strconv.parse_f64(r[:sp])
	idle, _ = strconv.parse_f64(strings.trim_space(r[sp:]))
	return up, idle, true
}

// btime is the wall clock second the kernel started, which is the only honest
// way to print a boot time.
btime_read :: proc() -> (secs: i64, ok: bool) {
	text, got := slurp("/proc/stat")
	if !got {
		return 0, false
	}
	return btime_parse(text)
}

btime_parse :: proc(text: string) -> (secs: i64, ok: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "btime ") {
			v, good := strconv.parse_u64(strings.trim_space(line[6:]))
			return i64(v), good
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// CPU frequency and governor
// ---------------------------------------------------------------------------

MAX_CPUS :: 128

Cpufreq :: struct {
	n:           int,
	cur:         [MAX_CPUS]u64, // kHz
	governor:    string,
	driver:      string,
	epp:         string,
	epp_choices: string,
	boost:       int, // -1 when the knob is not published
	min_khz:     u64,
	max_khz:     u64,
	hw_max_khz:  u64,
	present:     bool,
	// Governors vary per policy on some systems; say so rather than showing
	// cpu0's and implying it is the whole machine.
	mixed:       bool,
}

// The sysfs roots are variables rather than constants so the self-test can
// point them at a canned tree. Nothing but `--selftest` ever changes them.
g_cpu_root := "/sys/devices/system/cpu/cpu"
g_boost_path := "/sys/devices/system/cpu/cpufreq/boost"
g_supply_root := "/sys/class/power_supply"
g_hwmon_root := "/sys/class/hwmon/hwmon"

cpufreq_read :: proc(al := context.allocator) -> (c: Cpufreq) {
	pb: [128]u8
	c.boost = -1

	for i in 0 ..< MAX_CPUS {
		base := pathi(pb[:], g_cpu_root, i, "/cpufreq")
		nb: [160]u8
		khz, ok := read_u64_into(paths(nb[:], base, "/scaling_cur_freq"), g_buf[:])
		if !ok {
			// cpu0 missing means no cpufreq at all; a gap higher up means the
			// core list has ended.
			if i == 0 {
				return
			}
			break
		}
		c.cur[i] = khz
		c.n = i + 1
		c.present = true

		g, _ := read_line_into(paths(nb[:], base, "/scaling_governor"), g_buf[:], al)
		if i == 0 {
			c.governor = g
			c.driver, _ = read_line_into(paths(nb[:], base, "/scaling_driver"), g_buf[:], al)
			c.epp, _ = read_line_into(
				paths(nb[:], base, "/energy_performance_preference"),
				g_buf[:],
				al,
			)
			c.epp_choices, _ = read_line_into(
				paths(nb[:], base, "/energy_performance_available_preferences"),
				g_buf[:],
				al,
			)
			c.min_khz, _ = read_u64_into(paths(nb[:], base, "/scaling_min_freq"), g_buf[:])
			c.max_khz, _ = read_u64_into(paths(nb[:], base, "/scaling_max_freq"), g_buf[:])
			c.hw_max_khz, _ = read_u64_into(paths(nb[:], base, "/cpuinfo_max_freq"), g_buf[:])
		} else if g != c.governor {
			c.mixed = true
		}
	}

	if v, ok := read_u64(g_boost_path); ok {
		c.boost = int(v)
	}
	return
}

cpufreq_avg :: proc(c: Cpufreq) -> u64 {
	if c.n == 0 {
		return 0
	}
	sum: u64 = 0
	for i in 0 ..< c.n {
		sum += c.cur[i]
	}
	return sum / u64(c.n)
}

// ---------------------------------------------------------------------------
// Temperatures
// ---------------------------------------------------------------------------

Temp :: struct {
	chip:  string,
	label: string,
	c:     f32,
	crit:  f32,
}

temp_sample :: proc(buf: []u8, al := context.allocator) -> []Temp {
	out := make([dynamic]Temp, 0, 16, al)
	pb: [160]u8
	np: [192]u8

	misses := 0
	for h in 0 ..< 64 {
		base := pathi(pb[:], g_hwmon_root, h)
		chip, has_chip := read_line_into(paths(np[:], base, "/name"), buf, al)
		if !has_chip {
			misses += 1
			if misses >= 3 {
				break
			}
			continue
		}
		misses = 0
		defer delete(chip, al)
		tmiss := 0
		for t in 1 ..= 24 {
			tb: [192]u8
			stem := paths(tb[:], base, "/temp")
			sb: [208]u8
			milli, ok := read_u64_into(pathi(sb[:], stem, t, "_input"), buf)
			if !ok {
				tmiss += 1
				if tmiss >= 4 {
					break
				}
				continue
			}
			tmiss = 0
			lb: [208]u8
			label, has_label := read_line_into(pathi(lb[:], stem, t, "_label"), buf, al)
			if !has_label {
				label = strings.clone(chip, al)
			}
			cb: [208]u8
			crit: f32 = 0
			if cv, cok := read_u64_into(pathi(cb[:], stem, t, "_crit"), buf); cok {
				crit = f32(cv) / 1000
			}
			append(
				&out,
				Temp {
					chip = strings.clone(chip, al),
					label = label,
					c = f32(milli) / 1000,
					crit = crit,
				},
			)
		}
	}
	// Hottest first: a list that opens with the 20 degree ACPI zone and hides
	// the 85 degree CPU in the overflow is not a thermal readout.
	xs := out[:]
	for i in 1 ..< len(xs) {
		j := i
		for j > 0 && xs[j].c > xs[j - 1].c {
			xs[j], xs[j - 1] = xs[j - 1], xs[j]
			j -= 1
		}
	}
	return xs
}

// ---------------------------------------------------------------------------
// Power supplies
//
// On this machine the directory is empty. That is the finding, not an error.
// ---------------------------------------------------------------------------

Supply :: struct {
	name:   string,
	type_:  string,
	status: string,
	pct:    int,
}

supplies_read :: proc(al := context.allocator) -> []Supply {
	out := make([dynamic]Supply, 0, 4, al)
	dir, err := os.open(g_supply_root)
	if err != nil {
		return out[:]
	}
	defer os.close(dir)

	it := os.read_directory_iterator_create(dir)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		if fi.name == "." || fi.name == ".." {
			continue
		}
		pb: [256]u8
		base := paths(pb[:], g_supply_root, "/", fi.name)
		nb: [320]u8
		s := Supply {
			name = strings.clone(fi.name, al),
		}
		s.type_, _ = read_line_into(paths(nb[:], base, "/type"), g_buf[:], al)
		s.status, _ = read_line_into(paths(nb[:], base, "/status"), g_buf[:], al)
		if v, ok := read_u64_into(paths(nb[:], base, "/capacity"), g_buf[:]); ok {
			s.pct = int(v)
		} else {
			s.pct = -1
		}
		append(&out, s)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Sessions, through loginctl
// ---------------------------------------------------------------------------

Session :: struct {
	id:      string,
	user:    string,
	seat:    string,
	tty:     string,
	type_:   string,
	class:   string,
	state:   string,
	service: string,
	since:   string,
	remote:  bool,
	active:  bool,
	idle:    bool,
	locked:  bool,
	can_lock: bool,
	leader:  int,
}

sessions_read :: proc(al := context.allocator) -> []Session {
	out := make([dynamic]Session, 0, 4, al)
	lines, ok := kit.run_lines(
		{"loginctl", "list-sessions", "--no-legend"},
		context.temp_allocator,
	)
	if !ok {
		return out[:]
	}
	for line in lines {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 1 {
			continue
		}
		s := Session {
			id = strings.clone(f[0], al),
		}
		props, pok := kit.run(
			{
				"loginctl",
				"show-session",
				f[0],
				"-p",
				"Name",
				"-p",
				"Seat",
				"-p",
				"TTY",
				"-p",
				"Type",
				"-p",
				"Class",
				"-p",
				"State",
				"-p",
				"Service",
				"-p",
				"Timestamp",
				"-p",
				"Remote",
				"-p",
				"Active",
				"-p",
				"IdleHint",
				"-p",
				"LockedHint",
				"-p",
				"CanLock",
				"-p",
				"Leader",
			},
			context.temp_allocator,
		)
		if pok {
			session_parse_props(&s, props, al)
		}
		append(&out, s)
	}
	return out[:]
}

// session_parse_props folds one `loginctl show-session -p ...` block into a
// Session. Split out of the reader so the self-test can hand it a block.
session_parse_props :: proc(s: ^Session, props: string, al := context.allocator) {
	rest := props
	for pl in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(pl, '=')
		if eq <= 0 {
			continue
		}
		k := pl[:eq]
		v := pl[eq + 1:]
		switch k {
		case "Name":
			s.user = strings.clone(v, al)
		case "Seat":
			s.seat = strings.clone(v, al)
		case "TTY":
			s.tty = strings.clone(v, al)
		case "Type":
			s.type_ = strings.clone(v, al)
		case "Class":
			s.class = strings.clone(v, al)
		case "State":
			s.state = strings.clone(v, al)
		case "Service":
			s.service = strings.clone(v, al)
		case "Timestamp":
			s.since = strings.clone(v, al)
		case "Remote":
			s.remote = v == "yes"
		case "Active":
			s.active = v == "yes"
		case "IdleHint":
			s.idle = v == "yes"
		case "LockedHint":
			s.locked = v == "yes"
		case "CanLock":
			s.can_lock = v == "yes"
		case "Leader":
			s.leader, _ = strconv.parse_int(v)
		}
	}
}

// ---------------------------------------------------------------------------
// upower
//
// Nothing here is a system power supply, but a Bluetooth headset reports its
// charge through upower and that is a genuine, present reading.
// ---------------------------------------------------------------------------

Upower_Dev :: struct {
	path:    string,
	model:   string,
	kind:    string,
	pct:     int,
	warn:    string,
	updated: string,
	supply:  bool,
}

Upower :: struct {
	devs:         []Upower_Dev,
	version:      string,
	on_battery:   bool,
	lid_present:  bool,
	lid_closed:   bool,
	crit_action:  string,
	ok:           bool,
}

upower_read :: proc(al := context.allocator) -> (u: Upower) {
	text, ok := kit.run({"upower", "--dump"}, context.temp_allocator)
	if !ok || text == "" {
		return
	}
	return upower_parse(text, al)
}

// upower_parse is `upower --dump` turned into structs. It is separate from the
// subprocess so the self-test can feed it a dump, including a truncated one.
upower_parse :: proc(text: string, al := context.allocator) -> (u: Upower) {
	u.ok = true
	devs := make([dynamic]Upower_Dev, 0, 4, al)
	cur := Upower_Dev{pct = -1}
	have := false

	flush :: proc(devs: ^[dynamic]Upower_Dev, cur: ^Upower_Dev, have: ^bool) {
		if have^ && cur.path != "" {
			append(devs, cur^)
		}
		cur^ = Upower_Dev{pct = -1}
		have^ = false
	}

	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		switch {
		case strings.has_prefix(line, "Device:"):
			flush(&devs, &cur, &have)
			cur.path = strings.clone(strings.trim_space(line[7:]), al)
			have = true
		case strings.has_prefix(line, "Daemon:"):
			flush(&devs, &cur, &have)
		case strings.has_prefix(line, "model:"):
			cur.model = strings.clone(strings.trim_space(line[6:]), al)
		case strings.has_prefix(line, "power supply:"):
			cur.supply = strings.index(line, "yes") >= 0
		case strings.has_prefix(line, "percentage:"):
			v := strings.trim_space(line[11:])
			v = strings.trim_right(v, "%")
			if n, good := strconv.parse_int(v); good {
				cur.pct = n
			}
		case strings.has_prefix(line, "warning-level:"):
			cur.warn = strings.clone(strings.trim_space(line[14:]), al)
		case strings.has_prefix(line, "updated:"):
			cur.updated = strings.clone(strings.trim_space(line[8:]), al)
		case strings.has_prefix(line, "daemon-version:"):
			u.version = strings.clone(strings.trim_space(line[15:]), al)
		case strings.has_prefix(line, "on-battery:"):
			u.on_battery = strings.index(line, "yes") >= 0
		case strings.has_prefix(line, "lid-is-present:"):
			u.lid_present = strings.index(line, "yes") >= 0
		case strings.has_prefix(line, "lid-is-closed:"):
			u.lid_closed = strings.index(line, "yes") >= 0
		case strings.has_prefix(line, "critical-action:"):
			u.crit_action = strings.clone(strings.trim_space(line[16:]), al)
		case line == "headset":
			cur.kind = "headset"
		case line == "battery":
			cur.kind = "battery"
		case line == "mouse":
			cur.kind = "mouse"
		case line == "keyboard":
			cur.kind = "keyboard"
		case line == "unknown":
			cur.kind = "unknown"
		case line == "line-power":
			cur.kind = "line-power"
		}
	}
	flush(&devs, &cur, &have)
	u.devs = devs[:]
	return
}

// ---------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------

Host :: struct {
	hostname:  string,
	kernel:    string,
	cpu_model: string,
	chassis:   string,
	distro:    string,
}

host_read :: proc(al: mem.Allocator) -> (h: Host) {
	h.hostname, _ = read_line("/proc/sys/kernel/hostname", al)
	h.kernel, _ = read_line("/proc/sys/kernel/osrelease", al)
	if text, ok := slurp("/proc/cpuinfo"); ok {
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, "model name") {
				if c := strings.index_byte(line, ':'); c > 0 {
					h.cpu_model = strings.clone(strings.trim_space(line[c + 1:]), al)
				}
				break
			}
		}
	}
	// DMI says what kind of machine this is, which is the real reason there is
	// no battery.
	h.chassis, _ = read_line("/sys/class/dmi/id/chassis_type", al)
	if text, ok := slurp("/etc/os-release"); ok {
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, "PRETTY_NAME=") {
				h.distro = strings.clone(strings.trim(strings.trim_space(line[12:]), "\""), al)
				break
			}
		}
	}
	return
}

// chassis_label turns the SMBIOS chassis type into words. 3 is "Desktop",
// which is exactly why /sys/class/power_supply is empty here.
chassis_label :: proc(code: string) -> string {
	switch code {
	case "1":
		return "Other"
	case "2":
		return "Unknown"
	case "3":
		return "Desktop"
	case "4":
		return "Low profile desktop"
	case "6":
		return "Mini tower"
	case "7":
		return "Tower"
	case "8":
		return "Portable"
	case "9":
		return "Laptop"
	case "10":
		return "Notebook"
	case "11":
		return "Hand held"
	case "13":
		return "All in one"
	case "14":
		return "Sub notebook"
	case "17":
		return "Main server chassis"
	case "23":
		return "Rack mount chassis"
	case "30":
		return "Tablet"
	case "34":
		return "Embedded PC"
	case "35":
		return "Mini PC"
	case "36":
		return "Stick PC"
	case "31":
		return "Convertible"
	case "32":
		return "Detachable"
	}
	return code == "" ? "Unknown" : fmt.tprintf("Chassis type %s", code)
}
