package main

// `sysmon --selftest` — headless, no compositor, no window.
//
// This program is a pile of /proc parsers with a picture on top, and the
// parsers are the part that can be wrong without anybody noticing: a delta
// that goes backwards across a counter reset, a comm with a bracket in it, a
// meminfo field that moved. Every one of them is driven here from canned text,
// including malformed and truncated text, because the kernel does produce both
// — a /proc file read is not atomic, and a process can exit halfway through
// one.
//
// The last section is a safety property rather than a parser: this monitor has
// no kill, no renice and no signal, and that is asserted by starting a child
// process, selecting it in the real interface, pressing every key the window
// takes, and checking it is still alive.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import kit "kit:."
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
eq_u :: proc(got, want: u64, what: string) {
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
nearf :: proc(a, b: f32, what: string, tol: f32 = 1e-5) {
	near(f64(a), f64(b), what, f64(tol))
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("sysmon self-test")
	hz_init()
	users_init()

	test_cpu()
	test_mem()
	test_load()
	test_uptime()
	test_proc_stat()
	test_net()
	test_disks()
	test_temps()
	test_series()
	test_filter_and_sort()
	test_format()
	test_no_signals()
	test_cli_surface()
	test_cli_no_signals()

	_ = os.remove_all(fmt.tprintf("/tmp/palmy-sysmon-selftest-%d", os.get_pid()))

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// /proc/stat
// ---------------------------------------------------------------------------

test_cpu :: proc() {
	section("/proc/stat")

	// Four columns of the real thing: user nice system idle iowait irq
	// softirq steal guest guest_nice.
	first := `cpu  1000 100 500 8000 200 50 50 0 0 0
cpu0 250 25 125 2000 50 12 13 0 0 0
cpu1 250 25 125 2000 50 13 12 0 0 0
cpu2 250 25 125 2000 50 12 13 0 0 0
cpu3 250 25 125 2000 50 13 12 0 0 0
intr 123456 1 2 3
ctxt 999999
btime 1759502983
processes 4242
procs_running 2
procs_blocked 0
`
	c := Cpu{}
	cpu_parse(&c, first)
	eq_i(c.cores, 4, "four cores")
	eq_u(c.ctxt, 999999, "the context switch counter")
	eq_u(c.procs, 4242, "the process counter")
	eq_u(c.intr, 123456, "the interrupt counter")
	// The first sample has nothing to subtract from, so it is not a reading.
	nearf(c.agg, 0, "the first sample reports no usage, because it cannot")
	check(c.have_prev, "but it is remembered for the next one")

	// Second sample. Aggregate: busy was 1000+100+500+50+50+0 = 1700,
	// idle was 8000+200 = 8200. Now busy 1700+300 = 2000, idle 8200+700.
	second := `cpu  1200 100 600 8600 300 50 50 0 0 0
cpu0 350 25 225 2000 50 12 13 0 0 0
cpu1 250 25 125 2200 250 13 12 0 0 0
cpu2 250 25 125 2000 50 12 13 0 0 0
cpu3 250 25 125 2000 50 13 12 0 0 0
intr 223456 1 2 3
ctxt 1999999
processes 4300
`
	cpu_parse(&c, second)
	// busy delta 300, idle delta 700, so 30% busy.
	nearf(c.agg, 0.3, "the aggregate is 30% busy", 1e-6)
	// cpu0: busy 250+25+125+12+13 = 425 -> 350+25+225+12+13 = 625, delta 200;
	// idle 2050 unchanged. 200/200 = fully busy.
	nearf(c.per_core[0], 1.0, "cpu0 was pinned")
	// cpu1: busy unchanged, idle +200. Entirely idle.
	nearf(c.per_core[1], 0.0, "cpu1 was idle")
	nearf(c.per_core[2], 0.0, "cpu2 did nothing at all")
	eq_u(c.ctxt, 1999999, "the counters moved")

	// A sample identical to the last one: no time passed as far as the jiffy
	// counters are concerned, which must be 0% rather than a divide by zero.
	cpu_parse(&c, second)
	nearf(c.agg, 0, "two identical samples are 0% busy, not NaN")

	// A counter that went backwards — a suspend-resume, or a container whose
	// /proc was remounted. The delta is negative and must not become a
	// negative or wrapped percentage.
	back := `cpu  10 0 10 20 0 0 0 0 0 0
cpu0 1 0 1 2 0 0 0 0 0 0
`
	cpu_parse(&c, back)
	nearf(c.agg, 0, "a counter that went backwards reports 0%, not a wrapped number")
	check(c.agg >= 0 && c.agg <= 1, "and stays inside 0..1")

	// Malformed: a cpu line with only two fields, a line that says "cpu" and
	// nothing else, a core number that is not a number.
	m := Cpu{}
	cpu_parse(
		&m,
		"cpu  5 5\ncpuX 1 2 3 4\ncpu\ncpu999999 1 2 3 4 5 6 7 8\nctxt\nprocesses\n",
	)
	check(m.cores >= 0, "a malformed /proc/stat does not crash")
	eq_u(m.ctxt, 0, "a ctxt line with no number is zero")

	// Truncated mid-line, which is what reading /proc/stat into a buffer that
	// is a little too small produces.
	t := Cpu{}
	cpu_parse(&t, "cpu  1000 100 500 8000 200 50 50 0 0 0\ncpu0 250 25 1")
	eq_i(t.cores, 1, "a truncated core line is still a core")
	check(t.have_prev, "and the sample is kept")

	// Nothing at all.
	e := Cpu{}
	cpu_parse(&e, "")
	eq_i(e.cores, 0, "an empty /proc/stat has no cores")

	// A machine with more cores than MAX_CORES must not write past the array.
	big := strings.builder_make(context.temp_allocator)
	strings.write_string(&big, "cpu  1 1 1 1 1 1 1 1\n")
	for i in 0 ..< MAX_CORES + 40 {
		fmt.sbprintf(&big, "cpu%d 1 1 1 1 1 1 1 1\n", i)
	}
	b := Cpu{}
	cpu_parse(&b, strings.to_string(big))
	check(b.cores <= MAX_CORES, "the core count is bounded, got %d", b.cores)
}

// ---------------------------------------------------------------------------
// /proc/meminfo
// ---------------------------------------------------------------------------

test_mem :: proc() {
	section("/proc/meminfo")

	text := `MemTotal:       32695192 kB
MemFree:         1174532 kB
MemAvailable:   22914180 kB
Buffers:          612344 kB
Cached:         21038900 kB
SwapCached:        12288 kB
Active:         18442716 kB
SReclaimable:    1133224 kB
Shmem:           1884160 kB
SwapTotal:       8388604 kB
SwapFree:        8290300 kB
Dirty:              2048 kB
Writeback:             0 kB
AnonPages:       9203316 kB
Mapped:          2277764 kB
HugePages_Total:       0
`
	m := Mem{}
	mem_parse(&m, text)
	check(m.ok, "the file parsed")
	eq_u(m.total, 32695192 * 1024, "MemTotal in bytes")
	eq_u(m.free, 1174532 * 1024, "MemFree")
	eq_u(m.available, 22914180 * 1024, "MemAvailable")
	eq_u(m.cached, 21038900 * 1024, "Cached")
	eq_u(m.shmem, 1884160 * 1024, "Shmem")
	eq_u(m.swap_total, 8388604 * 1024, "SwapTotal")
	eq_u(m.swap_free, 8290300 * 1024, "SwapFree")
	eq_u(m.anon, 9203316 * 1024, "AnonPages")

	// htop's definition: total minus free, buffers and reclaimable cache,
	// where shmem is *not* cache because it is really in use.
	cache := m.cached + m.sreclaimable - m.shmem
	want := m.total - m.free - m.buffers - cache
	eq_u(mem_used(m), want, "used is total minus free, buffers and cache")
	check(mem_used(m) < m.total, "and is less than the total")

	// Nothing read: zero, not a vast number from an underflow.
	eq_u(mem_used(Mem{}), 0, "used of an unread Mem is zero")

	// A machine where the cache is larger than what is left — the subtraction
	// underflows in unsigned arithmetic and must be caught.
	odd := Mem {
		total  = 1000,
		free   = 900,
		cached = 5000,
	}
	check(mem_used(odd) <= odd.total, "used never exceeds the total, got %d", mem_used(odd))

	// Missing fields, an empty value, a key with no colon, and a truncation.
	m2 := Mem{}
	mem_parse(&m2, "MemTotal:       100 kB\nMemFree\nCached:\nBuff")
	check(m2.ok, "a file with only MemTotal is still a reading")
	eq_u(m2.total, 100 * 1024, "the one field that was there")
	eq_u(m2.free, 0, "and the ones that were not are zero")

	m3 := Mem{}
	mem_parse(&m3, "")
	check(!m3.ok, "an empty /proc/meminfo is not a reading")

	m4 := Mem{}
	mem_parse(&m4, "MemTotal: not-a-number kB\n")
	check(!m4.ok, "a non-numeric MemTotal is not a reading")
}

test_load :: proc() {
	section("/proc/loadavg")

	l := Load{}
	load_parse(&l, "1.42 0.98 0.73 3/1842 1234567\n")
	check(l.ok, "the file parsed")
	nearf(l.avg[0], 1.42, "the one minute average", 1e-5)
	nearf(l.avg[1], 0.98, "the five minute average", 1e-5)
	nearf(l.avg[2], 0.73, "the fifteen minute average", 1e-5)
	eq_i(l.running, 3, "runnable tasks")
	eq_i(l.total, 1842, "total tasks")
	eq_i(l.last_pid, 1234567, "the last pid")

	// Truncated after the averages: the averages are still good.
	l2 := Load{}
	load_parse(&l2, "0.00 0.01 0.05")
	check(l2.ok, "three averages are a reading")
	nearf(l2.avg[2], 0.05, "the third one")
	eq_i(l2.running, 0, "with no task counts")

	// Truncated inside the averages: not a reading at all.
	l3 := Load{}
	load_parse(&l3, "0.00 0.01")
	check(!l3.ok, "two averages are not a reading")

	l4 := Load{}
	load_parse(&l4, "")
	check(!l4.ok, "and neither is nothing")

	// The task field with no slash in it.
	l5 := Load{}
	load_parse(&l5, "1 2 3 nonsense 99\n")
	check(l5.ok, "a malformed task field does not stop the parse")
	eq_i(l5.running, 0, "and contributes nothing")
	eq_i(l5.last_pid, 99, "while the field after it is still read")
}

test_uptime :: proc() {
	section("/proc/uptime")

	up, idle, ok := uptime_parse("328392.87 2592714.33\n")
	check(ok, "a normal reading")
	near(up, 328392.87, "uptime", 1e-2)
	near(idle, 2592714.33, "idle", 1e-2)

	up2, idle2, ok2 := uptime_parse("12.5")
	check(ok2, "one field is still a reading")
	near(up2, 12.5, "the uptime")
	near(idle2, 0, "with no idle figure")

	_, _, ok3 := uptime_parse("")
	check(ok3, "an empty read still returns, with zeros")
}

// ---------------------------------------------------------------------------
// /proc/<pid>/stat
// ---------------------------------------------------------------------------

test_proc_stat :: proc() {
	section("/proc/<pid>/stat")

	// A real line, from this machine's own shell. 52 fields; this parser
	// reads through field 24.
	line := "1182 (Hyprland) S 1 1182 1182 0 -1 4194560 184329 2204 1876 0 128034 36902 3 1 20 0 14 0 1843 4294967296 32768 18446744073709551615 1 1 0 0 0 0 0 4096 16386 0 0 0 17 6 0 0 0 0 0\n"
	st, ok := parse_proc_stat(line)
	check(ok, "a real stat line parses")
	eq_s(st.comm, "Hyprland", "the command name")
	check(st.state == 'S', "its state is S, got %c", rune(st.state))
	eq_i(st.ppid, 1, "its parent")
	eq_u(st.utime, 128034, "its user time")
	eq_u(st.stime, 36902, "its system time")
	eq_i(st.nice, 0, "its nice value")
	eq_i(st.threads, 14, "its thread count")
	eq_u(st.start, 1843, "its start time")
	eq_u(st.vsz, 4294967296, "its virtual size")
	eq_u(st.rss_pages, 32768, "its resident set, in pages")

	// A comm with spaces and parentheses in it. This is the field that breaks
	// every naive parser: `strings.split` on spaces puts "(Web" in comm and
	// shifts every numbered field by two.
	odd := "4242 (Web Content (x) )) R 100 1 1 0 -1 0 1 2 3 4 11 22 0 0 20 5 7 0 900 1024 64 0 0 0 0 0 0 0 0 0 0 0 0\n"
	st2, ok2 := parse_proc_stat(odd)
	check(ok2, "a comm with spaces and brackets parses")
	eq_s(st2.comm, "Web Content (x) )", "and keeps every character of it")
	check(st2.state == 'R', "the state after it is still found, got %c", rune(st2.state))
	eq_i(st2.ppid, 100, "and so is the parent")
	eq_u(st2.utime, 11, "and the user time")
	eq_i(st2.nice, 5, "and the nice value")
	eq_i(st2.threads, 7, "and the thread count")

	// A negative nice value. The field is read as unsigned and reinterpreted,
	// which is the only way a -20 survives.
	nice := "7 (x) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 -20 1 0 1 0 0 0 0 0 0 0 0 0 0\n"
	st3, _ := parse_proc_stat(nice)
	eq_i(st3.nice, -20, "a negative nice value survives the round trip")

	// A kernel thread: zero sizes, and a name in brackets once the UI gets
	// hold of it.
	kthread := "2 (kthreadd) S 0 0 0 0 -1 2129984 0 0 0 0 5 9 0 0 20 0 1 0 2 0 0 0 0 0 0 0 0 0 0\n"
	st4, ok4 := parse_proc_stat(kthread)
	check(ok4, "a kernel thread parses")
	eq_u(st4.vsz, 0, "with no virtual size")
	eq_u(st4.rss_pages, 0, "and no resident pages")
	eq_i(st4.threads, 1, "and one thread")

	// Truncated: everything up to the cut is read, the rest is zero. A
	// process that exits while /proc/<pid>/stat is being read does this.
	cut, ok5 := parse_proc_stat("99 (sleep) S 1 99 99 0 -1 0 0 0 0 0 7")
	check(ok5, "a truncated stat line still parses as far as it goes")
	eq_s(cut.comm, "sleep", "its name")
	eq_i(cut.ppid, 1, "its parent")
	eq_u(cut.utime, 7, "and the last complete field")
	eq_u(cut.stime, 0, "while the fields past the cut are zero, not garbage")
	eq_i(cut.threads, 0, "including the thread count")
	eq_u(cut.rss_pages, 0, "and the resident set")

	// No parentheses at all: there is no way to find the field list, so this
	// has to be refused rather than guessed at.
	_, bad := parse_proc_stat("1182 Hyprland S 1 1182")
	check(!bad, "a line with no parentheses is refused")
	_, bad2 := parse_proc_stat("")
	check(!bad2, "an empty read is refused")
	_, bad3 := parse_proc_stat("1182 (Hyprland")
	check(!bad3, "a line truncated inside the comm is refused")
	_, bad4 := parse_proc_stat(")(")
	check(!bad4, "a closing bracket before the opening one is refused")

	// An empty comm, which is legal: a process can set its name to "".
	st6, ok6 := parse_proc_stat("5 () S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n")
	check(ok6, "an empty comm parses")
	eq_s(st6.comm, "", "and is empty")

	eq_s(state_label('R'), "running", "R")
	eq_s(state_label('S'), "sleeping", "S")
	eq_s(state_label('D'), "disk wait", "D")
	eq_s(state_label('Z'), "zombie", "Z")
	eq_s(state_label('I'), "idle", "I")
	eq_s(state_label('t'), "traced", "lowercase t")
	eq_s(state_label('?'), "unknown", "a state the kernel does not document")
}

// ---------------------------------------------------------------------------
// /proc/net/dev
// ---------------------------------------------------------------------------

test_net :: proc() {
	section("/proc/net/dev")

	// The real header, then three interfaces. The columns are:
	// rx: bytes packets errs drop fifo frame compressed multicast
	// tx: bytes packets errs drop fifo colls carrier compressed
	first := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000000   5000    0    0    0     0          0         0  1000000    5000    0    0    0     0       0          0
 wlan0: 2000000  12000    3    7    0     0          0       100   500000    8000    1    2    0     0       0          0
  eth0:       0      0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
`
	// The real /sys/class/net is not where this test looks: the canned tree
	// below is, and it has no entries, so operstate reads as down. That is
	// deliberate — the point here is the counters.
	saved := g_net_root
	g_net_root = "/tmp/palmy-sysmon-selftest-no-such-net/"
	defer {g_net_root = saved}

	nt := Net{}
	net_parse(&nt, first, 1.0, context.allocator)
	eq_i(nt.n, 3, "three interfaces")
	eq_s(nt.ifs[0].name, "lo", "the first is loopback")
	eq_s(nt.ifs[1].name, "wlan0", "then wlan0")
	eq_u(nt.ifs[1].rx, 2000000, "wlan0's received bytes")
	eq_u(nt.ifs[1].tx, 500000, "its transmitted bytes")
	eq_u(nt.ifs[1].rx_pkts, 12000, "its received packets")
	eq_u(nt.ifs[1].tx_pkts, 8000, "its transmitted packets")
	eq_u(nt.ifs[1].errs, 4, "errors from both directions added")
	eq_u(nt.ifs[1].drops, 9, "and drops likewise")
	// No previous sample, so there is no rate yet.
	near(nt.ifs[1].rx_rate, 0, "the first sample has no rate")
	near(nt.rx_rate, 0, "and neither does the machine total")

	second := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1004000   5004    0    0    0     0          0         0  1004000    5004    0    0    0     0       0          0
 wlan0: 2500000  13000    3    7    0     0          0       100   600000    8500    1    2    0     0       0          0
  eth0:       0      0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
`
	net_parse(&nt, second, 2.0, context.allocator)
	// 500000 bytes over two seconds.
	near(nt.ifs[1].rx_rate, 250000, "wlan0's receive rate over two seconds", 1e-3)
	near(nt.ifs[1].tx_rate, 50000, "and its transmit rate", 1e-3)
	near(nt.ifs[0].rx_rate, 2000, "loopback has a rate of its own", 1e-3)
	// Loopback is excluded from the machine total: counting it would double
	// every byte an application sent to itself.
	near(nt.rx_rate, 250000, "the machine total excludes loopback", 1e-3)
	near(nt.tx_rate, 50000, "in both directions", 1e-3)

	// A counter that went backwards — an interface that was taken down and
	// brought back up resets its counters to zero.
	reset := `  lo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
 wlan0: 100 1 0 0 0 0 0 0 50 1 0 0 0 0 0 0
  eth0: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
`
	net_parse(&nt, reset, 1.0, context.allocator)
	near(nt.ifs[1].rx_rate, 0, "a counter reset reports no rate rather than a negative one")
	check(nt.rx_rate >= 0, "and the machine total stays non-negative")

	// An interface that was not in the previous sample gets no rate rather
	// than a rate measured against somebody else's counters.
	fresh := " usb0: 9999 9 0 0 0 0 0 0 8888 8 0 0 0 0 0 0\n"
	net_parse(&nt, fresh, 1.0, context.allocator)
	eq_i(nt.n, 1, "one interface now")
	near(nt.ifs[0].rx_rate, 0, "a newly appeared interface has no rate")

	// Malformed: lines with no colon, an empty name, and a truncation.
	nt2 := Net{}
	net_parse(&nt2, "garbage with no colon\n: 1 2 3\n  eth0: 1 2\n", 1.0, context.allocator)
	eq_i(nt2.n, 1, "only the one line that is an interface")
	eq_s(nt2.ifs[0].name, "eth0", "and it is eth0")
	eq_u(nt2.ifs[0].tx, 0, "whose truncated transmit counter is zero")

	// More interfaces than the fixed array holds.
	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< MAX_IFS + 10 {
		fmt.sbprintf(&big, " veth%d: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n", i)
	}
	nt3 := Net{}
	net_parse(&nt3, strings.to_string(big), 1.0, context.allocator)
	check(nt3.n <= MAX_IFS, "the interface count is bounded, got %d", nt3.n)
}

// ---------------------------------------------------------------------------
// /proc/mounts
// ---------------------------------------------------------------------------

test_disks :: proc() {
	section("/proc/mounts")

	// Real shapes: pseudo filesystems, a btrfs device mounted three times as
	// different subvolumes, and a read-only mount.
	text := `proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,size=3269520k 0 0
/dev/nvme0n1p2 / btrfs rw,relatime,ssd,subvol=/@ 0 0
/dev/nvme0n1p2 /home btrfs rw,relatime,ssd,subvol=/@home 0 0
/dev/nvme0n1p2 /var/log btrfs rw,relatime,ssd,subvol=/@log 0 0
/dev/nvme0n1p1 /boot vfat ro,relatime,fmask=0022 0 0
cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec 0 0
`
	ds := disk_parse(text, context.allocator)
	// Two devices: the btrfs one, folded into a single row, and /boot.
	eq_i(len(ds), 2, "two block devices")
	if len(ds) != 2 {
		return
	}
	eq_s(ds[0].source, "/dev/nvme0n1p2", "the root device")
	// The shortest mount point is the one shown, and the rest are named beside
	// it. "/" is shorter than "/home", so "/" wins.
	eq_s(ds[0].mount, "/", "its shortest mount point is the one shown")
	check(
		strings.contains(ds[0].extra, "/home") && strings.contains(ds[0].extra, "/var/log"),
		"and the others are listed beside it, got %q",
		ds[0].extra,
	)
	eq_s(ds[0].fstype, "btrfs", "its filesystem")
	check(!ds[0].ro, "it is writable")
	// statvfs ran against the real "/" mount point.
	check(ds[0].ok, "statvfs answered for /")
	check(ds[0].total > 0, "and reported a size")
	check(ds[0].free <= ds[0].total, "with free space no larger than the total")

	eq_s(ds[1].source, "/dev/nvme0n1p1", "the boot device")
	check(ds[1].ro, "which is mounted read-only")

	// Pseudo filesystems never appear: they have no capacity worth showing.
	for d in ds {
		check(strings.has_prefix(d.source, "/dev/"), "every row is a block device, got %q", d.source)
	}

	// Malformed: a line with two fields, an empty line, a truncation.
	ds2 := disk_parse("/dev/sda1 /mnt\n\n/dev/sdb1 /x ext4 rw 0 0\n/dev/sdc", context.allocator)
	eq_i(len(ds2), 1, "only the complete line is a mount")
	if len(ds2) == 1 {
		eq_s(ds2[0].mount, "/x", "and it is the one with three fields")
		// /x does not exist, so statvfs could not answer — which the UI shows
		// rather than hiding.
		check(!ds2[0].ok, "a mount point that is not there did not answer statvfs")
		eq_u(ds2[0].total, 0, "and has no size")
	}

	eq_i(len(disk_parse("", context.allocator)), 0, "an empty /proc/mounts has no disks")
}

// ---------------------------------------------------------------------------
// hwmon
// ---------------------------------------------------------------------------

test_temps :: proc() {
	section("hwmon")

	root := fmt.tprintf("/tmp/palmy-sysmon-selftest-%d/hwmon", os.get_pid())
	put :: proc(path, text: string) {
		if slash := strings.last_index_byte(path, '/'); slash > 0 {
			_ = os.make_directory_all(path[:slash])
		}
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	put(fmt.tprintf("%s0/name", root), "k10temp\n")
	put(fmt.tprintf("%s0/temp1_input", root), "79125\n")
	put(fmt.tprintf("%s0/temp1_label", root), "Tctl\n")
	put(fmt.tprintf("%s0/temp2_input", root), "45000\n")
	put(fmt.tprintf("%s0/temp2_label", root), "Tccd1\n")
	put(fmt.tprintf("%s0/temp2_crit", root), "95000\n")
	put(fmt.tprintf("%s1/name", root), "amdgpu\n")
	put(fmt.tprintf("%s1/temp1_input", root), "65000\n")
	// A chip with no temperatures at all, which must not stop the scan.
	put(fmt.tprintf("%s2/name", root), "nvme\n")
	put(fmt.tprintf("%s2/fan1_input", root), "900\n")

	saved := g_hwmon_root
	g_hwmon_root = root
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

	eq_i(len(ts), 3, "three temperatures")
	if len(ts) == 3 {
		// Hottest first: a list that opens with a 20 degree ACPI zone and
		// hides the 79 degree CPU in the overflow is not a thermal readout.
		nearf(ts[0].c, 79.125, "the hottest is first", 1e-3)
		nearf(ts[1].c, 65, "then the GPU", 1e-3)
		nearf(ts[2].c, 45, "then the core complex", 1e-3)
		eq_s(ts[0].label, "Tctl", "the hottest sensor's label")
		eq_s(ts[0].chip, "k10temp", "and its chip")
		nearf(ts[0].crit, 0, "it publishes no critical point", 1e-3)
		nearf(ts[2].crit, 95, "but Tccd1 does", 1e-3)
		eq_s(ts[1].label, "amdgpu", "an unlabelled sensor is named after its chip")
	}

	g_hwmon_root = "/tmp/palmy-sysmon-selftest-no-hwmon/hwmon"
	none := temp_sample(buf[:], context.allocator)
	eq_i(len(none), 0, "a machine with no hwmon reports no temperatures")
	delete(none)
}

// ---------------------------------------------------------------------------
// The graph history
// ---------------------------------------------------------------------------

test_series :: proc() {
	section("the graph rings")

	s := Series{}
	eq_i(series_count(&s), 0, "an empty series")
	nearf(series_at(&s, 0), 0, "reads zero")
	nearf(series_last(&s), 0, "and has no last value")
	nearf(series_peak(&s), 0, "and no peak")

	for i in 0 ..< 5 {
		series_push(&s, f32(i) / 10)
	}
	eq_i(series_count(&s), 5, "five samples")
	nearf(series_at(&s, 0), 0, "oldest first")
	nearf(series_at(&s, 4), 0.4, "newest last")
	nearf(series_last(&s), 0.4, "and series_last agrees")
	nearf(series_peak(&s), 0.4, "the peak of the window")

	// Wrap the ring. The window slides; the oldest sample still in it is the
	// one HIST pushes ago.
	for i in 5 ..< HIST + 7 {
		series_push(&s, f32(i))
	}
	eq_i(series_count(&s), HIST, "the ring is full and stays full")
	nearf(series_at(&s, 0), f32(7), "after wrapping, the oldest kept sample is first")
	nearf(series_at(&s, HIST - 1), f32(HIST + 6), "and the newest is last")
	nearf(series_last(&s), f32(HIST + 6), "which is what series_last returns")
	nearf(series_peak(&s), f32(HIST + 6), "the window peak followed it up")

	// `max` is the all-time high and does not fall back out of the window,
	// which is what keeps an axis from jumping about.
	check(s.max >= series_peak(&s), "the all-time high is at least the window peak")
	for _ in 0 ..< HIST {
		series_push(&s, 0)
	}
	nearf(series_peak(&s), 0, "the window peak follows the data down")
	check(s.max >= f32(HIST + 6), "but the all-time high does not, got %.1f", s.max)
}

// ---------------------------------------------------------------------------
// Filtering and sorting
// ---------------------------------------------------------------------------

@(private = "file")
ROWS := [?]Proc_Row {
		{pid = 1, name = "systemd", cmd = "/sbin/init", user = "root", cpu = 0.1, rss = 12 << 20, threads = 1, state = 'S'},
		{pid = 2, name = "kthreadd", cmd = "[kthreadd]", user = "root", cpu = 0, rss = 0, threads = 1, state = 'S', kernel = true},
		{pid = 1182, name = "Hyprland", cmd = "/usr/bin/Hyprland", user = "alex", cpu = 12.5, rss = 512 << 20, threads = 14, state = 'S'},
		{pid = 2048, name = "chrome", cmd = "/opt/chrome --type=renderer", user = "alex", cpu = 44.0, rss = 1 << 30, threads = 28, state = 'R'},
		{pid = 2049, name = "Chrome Helper", cmd = "/opt/chrome --type=gpu", user = "alex", cpu = 3.25, rss = 256 << 20, threads = 9, state = 'S'},
	{pid = 9999, name = "sleep", cmd = "sleep 30", user = "nobody", cpu = 0, rss = 1 << 20, threads = 1, state = 'S'},
}

@(private = "file")
rows :: proc() -> []Proc_Row {
	return ROWS[:]
}

test_filter_and_sort :: proc() {
	section("filtering and sorting")

	// --- icontains --------------------------------------------------------
	check(icontains("Hyprland", "hypr"), "case-insensitive, needle lowercase")
	check(icontains("hyprland", "HYPR"), "case-insensitive, needle uppercase")
	check(icontains("Hyprland", "land"), "a match at the end")
	check(icontains("Hyprland", "Hyprland"), "a whole-string match")
	check(icontains("Hyprland", ""), "an empty needle matches everything")
	check(!icontains("Hyprland", "wayland"), "a non-match")
	check(!icontains("hypr", "hyprland"), "a needle longer than the haystack")
	check(!icontains("", "x"), "an empty haystack matches nothing")
	check(icontains("", ""), "except an empty needle")
	// The naive loop restarts correctly after a partial match: "aab" has to
	// be found in "aaab" even though the first two characters match and the
	// third does not.
	check(icontains("aaab", "aab"), "a partial match does not consume the restart")

	// --- proc_matches -----------------------------------------------------
	rs := rows()
	check(proc_matches(rs[3], "chrome"), "a name match")
	check(proc_matches(rs[3], "renderer"), "a command line match")
	check(proc_matches(rs[3], "alex"), "a user match")
	check(proc_matches(rs[3], "2048"), "a pid match")
	check(proc_matches(rs[3], "204"), "a partial pid match")
	check(!proc_matches(rs[3], "firefox"), "a non-match")
	check(proc_matches(rs[3], ""), "an empty filter matches everything")

	// --- less_fold --------------------------------------------------------
	check(less_fold("alex", "bob"), "a before b")
	check(!less_fold("bob", "alex"), "and not the other way")
	check(less_fold("Alex", "bob"), "case does not decide it")
	check(less_fold("alex", "Bob"), "in either direction")
	check(less_fold("chrome", "chromium"), "a prefix sorts before what extends it")
	check(!less_fold("alex", "alex"), "equal strings are not less than each other")
	check(less_fold("", "a"), "the empty string sorts first")

	// --- sorting ----------------------------------------------------------
	m := new(Model)
	defer free(m)
	defer delete(m.filter)
	m.procs = rs
	m.rows = 20
	m.show_kernel = false
	m.show_idle = true

	m.sort = .Cpu
	m.desc = true
	v := build_view(m)
	// Kernel threads are hidden by default, so kthreadd is not in the view.
	eq_i(len(v.rows), 5, "five rows with kernel threads hidden")
	eq_i(m.procs[v.rows[0]].pid, 2048, "the busiest process is first")
	eq_i(m.procs[v.rows[1]].pid, 1182, "then the next busiest")
	eq_i(m.procs[v.rows[len(v.rows) - 1]].cpu == 0 ? 0 : 1, 0, "and an idle one is last")
	nearf(v.cpu_sum, 0.1 + 12.5 + 44.0 + 3.25, "the CPU total covers the visible rows", 1e-3)

	m.desc = false
	v2 := build_view(m)
	eq_i(m.procs[v2.rows[len(v2.rows) - 1]].pid, 2048, "ascending puts the busiest last")
	// A sort is a permutation: every row appears exactly once.
	seen := make(map[int]bool, 16, context.temp_allocator)
	for i in v2.rows {
		check(!seen[m.procs[i].pid], "pid %d appears once", m.procs[i].pid)
		seen[m.procs[i].pid] = true
	}
	eq_i(len(seen), len(v2.rows), "and every row is accounted for")

	m.sort = .Mem
	m.desc = true
	v3 := build_view(m)
	eq_i(m.procs[v3.rows[0]].pid, 2048, "sorted by memory, chrome is first")
	eq_i(m.procs[v3.rows[1]].pid, 1182, "then Hyprland")

	m.sort = .Pid
	m.desc = false
	v4 := build_view(m)
	eq_i(m.procs[v4.rows[0]].pid, 1, "sorted by pid, init is first")
	eq_i(m.procs[v4.rows[len(v4.rows) - 1]].pid, 9999, "and the largest pid last")

	m.sort = .Name
	m.desc = false
	v5 := build_view(m)
	eq_s(m.procs[v5.rows[0]].name, "chrome", "sorted by name, chrome is first")
	eq_s(m.procs[v5.rows[1]].name, "Chrome Helper", "then Chrome Helper — case does not split them")
	eq_s(m.procs[v5.rows[len(v5.rows) - 1]].name, "systemd", "and systemd is last")

	m.sort = .Threads
	m.desc = true
	v6 := build_view(m)
	eq_i(m.procs[v6.rows[0]].threads, 28, "sorted by threads")

	m.sort = .User
	m.desc = false
	v7 := build_view(m)
	eq_s(m.procs[v7.rows[0]].user, "alex", "sorted by user, alex first")

	// --- the filter -------------------------------------------------------
	m.sort = .Cpu
	m.desc = true
	append(&m.filter, "chrom"[0], "chrom"[1], "chrom"[2], "chrom"[3], "chrom"[4])
	v8 := build_view(m)
	eq_i(len(v8.rows), 2, "the filter leaves the two Chrome rows")
	eq_i(v8.total, len(rs), "while the total counts everything")
	clear(&m.filter)

	// --- kernel threads and idle processes --------------------------------
	m.show_kernel = true
	v9 := build_view(m)
	eq_i(len(v9.rows), 6, "showing kernel threads adds kthreadd")
	m.show_kernel = false
	m.show_idle = false
	v10 := build_view(m)
	// Only rows with cpu >= 0.05: systemd (0.1), Hyprland, chrome, helper.
	eq_i(len(v10.rows), 4, "hiding idle processes leaves the four using CPU")

	// --- the selection ----------------------------------------------------
	m.show_idle = true
	m.sel_pid = 1182
	v11 := build_view(m)
	eq_i(m.procs[v11.sel].pid, 1182, "the selection is found by pid")
	check(v11.at >= 0, "and has a position")
	move_sel(m, v11, 1)
	v12 := build_view(m)
	check(m.sel_pid != 1182, "Down moved it")
	eq_i(v12.at, v11.at + 1, "by exactly one row")
	move_sel(m, v12, -1 << 20)
	v13 := build_view(m)
	eq_i(v13.at, 0, "Home goes to the top")
	move_sel(m, v13, 1 << 20)
	v14 := build_view(m)
	eq_i(v14.at, len(v14.rows) - 1, "End goes to the bottom, not past it")

	// A selection whose process has exited falls back to the first row rather
	// than leaving the table pointing at nothing.
	m.sel_pid = 123456
	v15 := build_view(m)
	check(v15.sel >= 0, "a vanished selection falls back to a real row")
	eq_i(v15.at, 0, "the first one")

	// An empty table.
	m.procs = nil
	v16 := build_view(m)
	eq_i(len(v16.rows), 0, "no rows")
	eq_i(v16.sel, -1, "and no selection")
	move_sel(m, v16, 1)
	check(true, "moving the selection in an empty table does nothing")
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

test_format :: proc() {
	section("formatting")

	eq_s(fmt_bytes(0), "0 B", "nothing")
	eq_s(fmt_bytes(1023), "1023 B", "just under a kibibyte")
	eq_s(fmt_bytes(1024), "1 KiB", "a kibibyte")
	eq_s(fmt_bytes(1 << 20), "1 MiB", "a mebibyte")
	eq_s(fmt_bytes(1 << 30), "1.00 GiB", "a gibibyte")
	eq_s(fmt_bytes(3 * (u64(1) << 30) / 2), "1.50 GiB", "one and a half")
	eq_s(fmt_bytes(u64(1) << 40), "1.00 TiB", "a tebibyte")

	eq_s(fmt_bytes_short(0), "0", "short: nothing")
	eq_s(fmt_bytes_short(1 << 20), "1M", "short: a mebibyte")
	eq_s(fmt_bytes_short(u64(1) << 30), "1.0G", "short: a gibibyte")

	eq_s(fmt_rate(0), "0 B/s", "no traffic")
	eq_s(fmt_rate(512), "512 B/s", "a trickle")
	eq_s(fmt_rate(1024), "1 kB/s", "a kilobyte a second")
	eq_s(fmt_rate(f64(1 << 20)), "1.0 MB/s", "a megabyte a second")
	eq_s(fmt_rate(f64(1 << 30)), "1.00 GB/s", "a gigabyte a second")

	eq_s(fmt_uptime(0), "0m 0s", "zero")
	eq_s(fmt_uptime(59), "0m 59s", "under a minute")
	eq_s(fmt_uptime(3600), "1h 0m 0s", "an hour")
	eq_s(fmt_uptime(86400), "1d 0h 0m", "a day")
	eq_s(fmt_uptime(328392), "3d 19h 13m", "this machine")

	eq_s(truncate_mid("short", 20), "short", "nothing to truncate")
	eq_s(truncate_mid("abcdefghij", 10), "abcdefghij", "exactly the limit")
	long := truncate_mid("/usr/lib/chromium/chromium --type=renderer --enable-features=X", 24)
	runes := utf8.rune_count_in_string(long)
	check(runes == 24, "the truncation is 24 characters long, got %d in %q", runes, long)
	check(strings.contains(long, "…"), "and has an ellipsis in the middle, got %q", long)
	eq_s(truncate_mid("abcdefgh", 4), "abcd", "below eight characters it simply cuts")

	eq_s(sort_label(.Cpu), "CPU", "the CPU column")
	eq_s(sort_label(.Mem), "Memory", "the memory column")
	eq_s(sort_label(.Threads), "Threads", "the thread column")
}

// ---------------------------------------------------------------------------
// This monitor cannot kill anything
//
// There is no kill, no renice and no signal anywhere in this program, on
// purpose. That is asserted rather than claimed: a child process is started,
// selected in the real interface, and every key the window takes is pressed at
// it. It has to still be there afterwards.
// ---------------------------------------------------------------------------

@(private = "file")
step :: proc(off: ^p.Offscreen, m: ^Model) {
	ui := p.offscreen_begin(off)
	measure_rows(m, p.size(ui))
	v := build_view(m)
	keys(ui, nil, m, v)
	build(ui, m, build_view(m))
	p.offscreen_end(off)
}

test_no_signals :: proc() {
	section("nothing in this window can signal a process")

	// A child of our own to aim at. `sleep` is chosen because it does nothing,
	// exits by itself, and is unmistakable in a process table.
	child, cerr := os.process_start({command = {"sleep", "60"}})
	if cerr != nil {
		check(false, "could not start the child process to aim at")
		return
	}
	alive :: proc(pid: int) -> bool {
		text, ok := slurp(fmt.tprintf("/proc/%d/stat", pid))
		if !ok {
			return false
		}
		st, parsed := parse_proc_stat(text)
		// A zombie is a process that has been killed and not yet reaped, which
		// is emphatically not "still running".
		return parsed && st.state != 'Z' && st.state != 'X'
	}
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 0)
	}

	check(alive(child.pid), "the child process started")

	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	defer delete(m.filter)
	m.host = host_read(context.allocator)
	m.procs = proc_sample(0, context.allocator)
	m.show_kernel = false
	m.show_idle = true
	m.sort = .Pid
	m.sel_pid = child.pid

	// The child really is in the table, so the keys below are aimed at it and
	// not at nothing.
	found := false
	for r in m.procs {
		if r.pid == child.pid {
			found = true
			eq_s(r.name, "sleep", "and the monitor sees it")
			check(!r.kernel, "as a user process")
		}
	}
	check(found, "the child process is in the table")

	step(off, m)
	step(off, m)
	check(ink(off) > 0.01, "the window drew something (ink %.3f)", ink(off))
	v := build_view(m)
	eq_i(m.procs[v.sel].pid, child.pid, "and the child is the selected row")

	// Every key this window takes, and a few it does not, with the child
	// selected throughout. Ctrl is never held, so Ctrl-Q cannot quit.
	all := "abcdefghijklmnopqrstuvwxyz0123456789/?.,;'[]-=+_"
	for i in 0 ..< len(all) {
		p.press_key(off, u32(all[i]))
		step(off, m)
		// Any key may have opened an overlay; Escape closes it so the next
		// key reaches the table rather than the overlay.
		p.press_key(off, p.KEY_ESCAPE)
		step(off, m)
		m.sel_pid = child.pid
	}
	for k in ([?]u32 {
		p.KEY_RETURN,
		p.KEY_SPACE,
		p.KEY_DELETE,
		p.KEY_BACKSPACE,
		p.KEY_TAB,
		p.KEY_F1,
		p.KEY_LEFT,
		p.KEY_RIGHT,
		p.KEY_UP,
		p.KEY_DOWN,
		p.KEY_HOME,
		p.KEY_END,
		p.KEY_PAGE_UP,
		p.KEY_PAGE_DOWN,
	}) {
		p.press_key(off, k)
		step(off, m)
		p.press_key(off, p.KEY_ESCAPE)
		step(off, m)
		m.sel_pid = child.pid
	}
	// Space toggles pause; leave it running.
	m.paused = false

	check(alive(child.pid), "the selected process is still alive after every key")

	// And nothing else died either: the table is still the length it was.
	after := proc_sample(1, context.allocator)
	check(
		len(after) >= len(m.procs) - 20,
		"the process table is still intact: %d processes, was %d",
		len(after),
		len(m.procs),
	)
	check(alive(child.pid), "and the child is still there after a second sample")

	if shot := os.get_env("SYSMON_SELFTEST_PNG", context.temp_allocator); shot != "" {
		p.offscreen_write_png(off, shot)
		fmt.printf("  wrote %s\n", shot)
	}
}

// ---------------------------------------------------------------------------
// `sysmon --shot out.png`
// ---------------------------------------------------------------------------

shot :: proc(path: string, keys_to_press: []u32 = nil) {
	hz_init()
	users_init()
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	m.host = host_read(context.allocator)
	m.show_idle = false
	sample(m, 0)
	time.sleep(400 * time.Millisecond)
	sample(m, 0.4)
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
		fmt.eprintfln("[sysmon] wrote %s", path)
	}
}

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

// ---------------------------------------------------------------------------
// The command surface
//
// The commands are run as real child processes of this binary, because what
// has to hold is what a caller receives: the exit code, and stdout being one
// JSON document of the declared shape and nothing else.
// ---------------------------------------------------------------------------

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

// cli_run runs this binary again with `env` set for the child and hands back
// stdout and the exit code. The display variables are cleared, so a command
// that fell through to a window would fail rather than hang the test.
@(private = "file")
cli_run :: proc(env: []string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= ")
	for e in env {
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

test_cli_surface :: proc() {
	section("the command surface")

	sf := surface()
	check(sf.noun == "sysmon", "the surface is named sysmon")
	check(sf.selftest != nil, "--selftest is part of the declaration")
	for cmd in sf.commands {
		check(cmd.run != nil, "%q has an implementation", cmd.verb)
		check(cmd.summary != "", "%q has a summary", cmd.verb)
		check(len(cmd.out) > 0, "%q declares what it prints", cmd.verb)
		check(len(cmd.examples) > 0, "%q ships an example", cmd.verb)
		// A monitor looks. The only command that writes anything writes the
		// PNG it was asked for; nothing is mutate on the system, nothing is
		// destructive, and there is no signal verb to be intent class.
		if cmd.verb == "shot" {
			check(cmd.effect == .Mutate, "shot is mutate (it writes the file it is given)")
		} else {
			check(cmd.effect == .Read, "%q is read class", cmd.verb)
		}
		for bad in ([?]string{"kill", "signal", "renice", "stop", "terminate"}) {
			check(cmd.verb != bad, "there is no %q verb", bad)
		}
	}

	{
		out, code := cli_run(nil, "--schema")
		eq_i(code, 0, "--schema exits 0")
		problems := kit.cli_validate_output(
			out,
			{
				{name = "noun", kind = .String},
				{name = "commands", kind = .Array, of = {{name = "verb", kind = .String}, {name = "effect", kind = .String}}},
				{name = "exit_codes", kind = .Object},
			},
			context.temp_allocator,
		)
		check(len(problems) == 0, "--schema is one JSON document of the shape palm expects")
	}

	// Every example parses, through the real parser.
	for cmd in sf.commands {
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			check(len(words) > 0 && words[0] == "sysmon", "the example %q starts with the binary's name", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := cli_run(nil, ..args[:])
			eq_i(code, 0, fmt.tprintf("the example %q parses", ex))
		}
	}

	// The reads, run for real and held to their declarations.
	{
		out, code := cli_run(nil, "status", "--interval", "0.2", "--json")
		eq_i(code, 0, "sysmon status exits 0")
		problems := kit.cli_validate_output(out, STATUS_FIELDS, context.temp_allocator)
		check(len(problems) == 0, "sysmon status --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.has_prefix(strings.trim_space(out), "{"), "and stdout is the document")
	}

	child, cerr := os.process_start({command = {"sleep", "30"}})
	if cerr == nil {
		defer {
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 0)
		}
		{
			out, code := cli_run(nil, "ps", "--filter", "sleep", "--sort", "pid", "--limit", "0", "--interval", "0.2", "--json")
			eq_i(code, 0, "sysmon ps exits 0")
			problems := kit.cli_validate_output(out, PS_FIELDS, context.temp_allocator)
			check(len(problems) == 0, "sysmon ps --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
			check(strings.contains(out, fmt.tprintf(`"pid": %d,`, child.pid)), "and the filter finds the sleep this test started")
			check(strings.contains(out, `"sort": "pid"`), "sorted as asked")
		}
		{
			out, code := cli_run(nil, "proc", fmt.tprintf("%d", child.pid), "--interval", "0.1", "--json")
			eq_i(code, 0, "sysmon proc <pid> exits 0")
			problems := kit.cli_validate_output(out, PROC_FIELDS, context.temp_allocator)
			check(len(problems) == 0, "sysmon proc --json matches its schema%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
			check(strings.contains(out, `"name": "sleep"`), "and names the process")
		}
	} else {
		check(false, "could not start a child process for ps and proc to find")
	}

	// The documented refusals.
	{
		out, code := cli_run(nil, "proc", "999999999", "--interval", "0.05", "--json")
		eq_i(code, kit.EXIT_NOT_FOUND, "a pid that does not exist exits 3")
		check(strings.contains(out, `"error": "not found"`), "with the documented token")
	}
	{
		_, code := cli_run(nil, "ps", "--sort", "sideways")
		eq_i(code, kit.EXIT_USAGE, "a sort key that is not one exits 2")
	}
	{
		_, code := cli_run(nil, "teleport")
		eq_i(code, kit.EXIT_USAGE, "an unknown command exits 2")
	}
	{
		out, code := cli_run({"PALM_IDENTITY=work"}, "status", "--identity", "personal", "--json")
		eq_i(code, kit.EXIT_OUT_OF_SCOPE, "asking for another identity exits 5")
		check(strings.contains(out, `"error": "out of scope"`), "with the documented token")
	}
	{
		png := fmt.tprintf("/tmp/palmy-sysmon-selftest-%d/dry.png", os.get_pid())
		_ = os.make_directory_all(fmt.tprintf("/tmp/palmy-sysmon-selftest-%d", os.get_pid()))
		os.remove(png)
		out, code := cli_run(nil, "shot", png, "--dry-run", "--json")
		eq_i(code, 0, "a dry run of shot exits 0")
		check(strings.contains(out, `"dry_run": true`), "and says it was a dry run")
		check(!os.exists(png), "and wrote nothing")
	}
}

// test_cli_no_signals is test_no_signals for the other front end. Every
// command is run as a child with fake kill, pkill, killall, renice and
// friends first on PATH, each writing to a sentinel; a process of our own is
// alive throughout. The sentinel has to stay empty and the process alive.
test_cli_no_signals :: proc() {
	section("no command signals a process")

	root := fmt.tprintf("/tmp/palmy-sysmon-selftest-%d", os.get_pid())
	bin := fmt.tprintf("%s/fakebin", root)
	_ = os.make_directory_all(bin)
	sentinel := fmt.aprintf("%s/fired", bin)
	defer delete(sentinel)
	os.remove(sentinel)
	for name in ([?]string{"kill", "pkill", "killall", "renice", "ionice", "taskset", "systemctl", "loginctl"}) {
		path := fmt.tprintf("%s/%s", bin, name)
		script := fmt.tprintf("#!/bin/sh\nprintf '%%s %%s\\n' \"$0\" \"$*\" >> %s\nexit 0\n", sentinel)
		_ = os.write_entire_file(path, transmute([]u8)script, os.Permissions_All)
	}
	path_env := fmt.tprintf("PATH=%s:%s", bin, os.get_env("PATH", context.temp_allocator))

	// Spring the trap once so that "the sentinel is empty" means something.
	// (`kill` itself is a shell builtin, so the trap is sprung with pkill.)
	{
		_, _, _, err := os.process_exec({command = {"sh", "-c", fmt.tprintf("%s pkill --version", path_env)}}, context.temp_allocator)
		check(err == nil && os.exists(sentinel), "the fake pkill on PATH is reached (the trap works)")
	}
	os.remove(sentinel)

	child, cerr := os.process_start({command = {"sleep", "30"}})
	if cerr != nil {
		check(false, "could not start the child process to aim at")
		return
	}
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 0)
	}
	pid := fmt.tprintf("%d", child.pid)
	png := fmt.tprintf("%s/cli.png", root)
	for argv in ([][]string {
		{"status", "--interval", "0.05", "--json"},
		{"ps", "--filter", pid, "--interval", "0.05", "--json"},
		{"ps", "--sort", "mem", "--limit", "3", "--interval", "0.05"},
		{"proc", pid, "--interval", "0.05", "--json"},
		{"shot", png, "k"},
	}) {
		_, code := cli_run({path_env}, ..argv)
		eq_i(code, 0, fmt.tprintf("sysmon %s exits 0", argv[0]))
		check(!os.exists(sentinel), "sysmon %s ran no kill, renice or systemctl", argv[0])
	}
	check(os.exists(png), "and the shot was written")

	text, ok := slurp(fmt.tprintf("/proc/%d/stat", child.pid))
	st, parsed := parse_proc_stat(text)
	check(ok && parsed && st.state != 'Z' && st.state != 'X', "the process every command was aimed at is still alive")
}
