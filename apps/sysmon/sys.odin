package main

// Everything this applet knows, read straight out of the kernel's own files.
// There is not a single subprocess here: /proc and /sys expose all of it, and
// shelling out to `top` or `df` would only put a text parser between us and
// numbers the kernel already hands over as text.
//
//   /proc/stat                      jiffy counters, per core
//   /proc/meminfo                   memory and swap
//   /proc/loadavg                   load average, runnable/total tasks
//   /proc/uptime                    seconds since boot, idle seconds
//   /proc/<pid>/{stat,status,cmdline}   one row per process
//   /proc/mounts + statvfs(3)       mounted filesystems
//   /proc/net/dev                   interface byte counters
//   /sys/class/hwmon/*/temp*_input  temperatures
//
// Counters are differences, so every rate needs two samples and the first one
// is thrown away. The UI says so rather than drawing a zero.

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// getconf CLK_TCK on this machine, and on every Linux/glibc build in practice.
// Asked of libc anyway at start-up rather than trusted.
g_hz: f64 = 100

hz_init :: proc() {
	if v := posix.sysconf(._CLK_TCK); v > 0 {
		g_hz = f64(v)
	}
}

// ---------------------------------------------------------------------------
// Reading small kernel files
//
// A /proc file reports st_size 0, so the generic "read the whole file" helpers
// fall back to a growing dynamic array: one allocation per chunk, and this
// applet reads about 1200 of these files a second. A caller-owned buffer and a
// direct read loop is both faster and allocation-free.
// ---------------------------------------------------------------------------

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

// slurp reads into the shared scratch buffer. The result is only valid until
// the next call, so copy anything that has to outlive it.
slurp :: proc(path: string) -> (text: string, ok: bool) {
	return slurp_into(path, g_buf[:])
}

// ---------------------------------------------------------------------------
// Paths
//
// /proc and /sys paths are assembled thousands of times a second. These build
// them into a caller-owned stack buffer, so nothing is allocated and nothing
// has to be freed.
// ---------------------------------------------------------------------------

// paths joins up to three pieces into `buf`.
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

// pathi is `paths` with a decimal integer in the middle, which is every
// per-pid and per-sensor path in this file.
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

// concat3 joins three strings into freshly allocated memory.
concat3 :: proc(al: mem.Allocator, a, b, c: string) -> string {
	out := make([]u8, len(a) + len(b) + len(c), al)
	copy(out[:], a)
	copy(out[len(a):], b)
	copy(out[len(a) + len(b):], c)
	return string(out)
}

read_u64 :: proc(path: string) -> (v: u64, ok: bool) {
	s, got := slurp(path)
	if !got {
		return 0, false
	}
	return strconv.parse_u64(strings.trim_space(s))
}

read_line :: proc(path: string, allocator := context.allocator) -> (s: string, ok: bool) {
	text, got := slurp(path)
	if !got {
		return "", false
	}
	t := strings.trim_space(text)
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = t[:nl]
	}
	return strings.clone(t, allocator), true
}

// ---------------------------------------------------------------------------
// Field walking
//
// /proc is whitespace-separated columns. `fields` would allocate a slice per
// line; an iterator over the same string does not.
// ---------------------------------------------------------------------------

next_field :: proc(s: ^string) -> (field: string, ok: bool) {
	i := 0
	for i < len(s^) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i += 1
	}
	if i >= len(s^) {
		s^ = ""
		return "", false
	}
	j := i
	for j < len(s^) && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' {
		j += 1
	}
	field = s[i:j]
	s^ = s[j:]
	return field, true
}

field_u64 :: proc(s: ^string) -> u64 {
	f, ok := next_field(s)
	if !ok {
		return 0
	}
	v, _ := strconv.parse_u64(f)
	return v
}

// ---------------------------------------------------------------------------
// CPU: /proc/stat
// ---------------------------------------------------------------------------

MAX_CORES :: 256

Cpu_Times :: struct {
	busy: u64, // user+nice+system+irq+softirq+steal
	idle: u64, // idle+iowait
}

Cpu :: struct {
	cores:     int,
	// Fraction busy since the previous sample, 0..1.
	agg:       f32,
	per_core:  [MAX_CORES]f32,
	prev:      [MAX_CORES + 1]Cpu_Times,
	have_prev: bool,
	// Totals since boot, for the header.
	ctxt:      u64,
	procs:     u64,
	intr:      u64,
}

// cpu_sample reads /proc/stat and turns the jiffy counters into the fraction
// of each core that was busy since the last call.
cpu_sample :: proc(c: ^Cpu) {
	text, ok := slurp("/proc/stat")
	if !ok {
		return
	}

	parse :: proc(rest: string) -> (t: Cpu_Times) {
		r := rest
		user := field_u64(&r)
		nice := field_u64(&r)
		sys := field_u64(&r)
		idle := field_u64(&r)
		iowait := field_u64(&r)
		irq := field_u64(&r)
		softirq := field_u64(&r)
		steal := field_u64(&r)
		t.busy = user + nice + sys + irq + softirq + steal
		t.idle = idle + iowait
		return
	}

	// Slot 0 is the aggregate "cpu" line, slot n+1 is "cpun".
	seen := [MAX_CORES + 1]Cpu_Times{}
	have := [MAX_CORES + 1]bool{}
	cores := 0

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "cpu") {
			tail := line[3:]
			slot := -1
			if len(tail) > 0 && tail[0] == ' ' {
				slot = 0
			} else {
				sp := strings.index_byte(tail, ' ')
				if sp > 0 {
					if n, good := strconv.parse_int(tail[:sp]); good && n < MAX_CORES {
						slot = n + 1
						cores = max(cores, n + 1)
						tail = tail[sp:]
					}
				}
			}
			if slot >= 0 {
				seen[slot] = parse(tail)
				have[slot] = true
			}
			continue
		}
		if strings.has_prefix(line, "ctxt ") {
			r := line[5:]
			c.ctxt = field_u64(&r)
		} else if strings.has_prefix(line, "processes ") {
			r := line[10:]
			c.procs = field_u64(&r)
		} else if strings.has_prefix(line, "intr ") {
			r := line[5:]
			c.intr = field_u64(&r)
		}
	}

	c.cores = cores
	if c.have_prev {
		frac :: proc(now, before: Cpu_Times) -> f32 {
			db := i64(now.busy) - i64(before.busy)
			di := i64(now.idle) - i64(before.idle)
			tot := db + di
			if tot <= 0 || db < 0 {
				return 0
			}
			return clamp(f32(db) / f32(tot), 0, 1)
		}
		if have[0] {
			c.agg = frac(seen[0], c.prev[0])
		}
		for i in 0 ..< cores {
			if have[i + 1] {
				c.per_core[i] = frac(seen[i + 1], c.prev[i + 1])
			}
		}
	}
	c.prev = seen
	c.have_prev = true
}

// ---------------------------------------------------------------------------
// Memory: /proc/meminfo
// ---------------------------------------------------------------------------

Mem :: struct {
	total, free, available, buffers, cached, sreclaimable, shmem: u64, // bytes
	swap_total, swap_free, swap_cached:                           u64,
	dirty, writeback, anon, mapped:                               u64,
	ok:                                                           bool,
}

// used is what a person means by "in use": everything but what the kernel is
// willing to hand back. htop's own definition.
mem_used :: proc(m: Mem) -> u64 {
	if m.total == 0 {
		return 0
	}
	cache := m.cached + m.sreclaimable - m.shmem
	used := m.total - m.free - m.buffers - cache
	if used > m.total {
		return m.total
	}
	return used
}

mem_sample :: proc(m: ^Mem) {
	text, ok := slurp("/proc/meminfo")
	if !ok {
		return
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		key := line[:colon]
		val := line[colon + 1:]
		kb := field_u64(&val)
		b := kb * 1024
		switch key {
		case "MemTotal":
			m.total = b
		case "MemFree":
			m.free = b
		case "MemAvailable":
			m.available = b
		case "Buffers":
			m.buffers = b
		case "Cached":
			m.cached = b
		case "SReclaimable":
			m.sreclaimable = b
		case "Shmem":
			m.shmem = b
		case "SwapTotal":
			m.swap_total = b
		case "SwapFree":
			m.swap_free = b
		case "SwapCached":
			m.swap_cached = b
		case "Dirty":
			m.dirty = b
		case "Writeback":
			m.writeback = b
		case "AnonPages":
			m.anon = b
		case "Mapped":
			m.mapped = b
		}
	}
	m.ok = m.total > 0
}

// ---------------------------------------------------------------------------
// Load and uptime
// ---------------------------------------------------------------------------

Load :: struct {
	avg:            [3]f32,
	running, total: int,
	last_pid:       int,
	ok:             bool,
}

load_sample :: proc(l: ^Load) {
	text, ok := slurp("/proc/loadavg")
	if !ok {
		return
	}
	r := text
	for i in 0 ..< 3 {
		f, got := next_field(&r)
		if !got {
			return
		}
		l.avg[i], _ = strconv.parse_f32(f)
	}
	if f, got := next_field(&r); got {
		if slash := strings.index_byte(f, '/'); slash > 0 {
			l.running, _ = strconv.parse_int(f[:slash])
			l.total, _ = strconv.parse_int(f[slash + 1:])
		}
	}
	if f, got := next_field(&r); got {
		l.last_pid, _ = strconv.parse_int(f)
	}
	l.ok = true
}

uptime_sample :: proc() -> (up, idle: f64, ok: bool) {
	text, got := slurp("/proc/uptime")
	if !got {
		return 0, 0, false
	}
	r := text
	a, _ := next_field(&r)
	b, _ := next_field(&r)
	up, _ = strconv.parse_f64(a)
	idle, _ = strconv.parse_f64(b)
	return up, idle, true
}

// ---------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------

Proc_Row :: struct {
	pid:      int,
	ppid:     int,
	name:     string, // comm, from /proc/<pid>/stat
	cmd:      string, // argv joined, or [comm] for a kernel thread
	user:     string,
	state:    u8,
	threads:  int,
	rss:      u64, // bytes
	vsz:      u64,
	cpu:      f32, // percent of one core over the sample interval
	ticks:    u64, // utime+stime, for the next delta
	start:    u64, // starttime, so a recycled pid is not mistaken for the old one
	nice:     int,
	kernel:   bool,
}

// A process's CPU use is a difference, so the previous reading has to be kept.
// Keyed by pid and start time together: a pid can be recycled, start time
// cannot.
Proc_Prev :: struct {
	start: u64,
	ticks: u64,
}

g_prev_ticks: map[int]Proc_Prev

// proc_sample reads every /proc/<pid> and returns one row per process.
// `dt` is the wall time since the previous call, in seconds; CPU percentages
// are only filled in when there was one.
proc_sample :: proc(dt: f64, al := context.allocator) -> []Proc_Row {
	if g_prev_ticks == nil {
		g_prev_ticks = make(map[int]Proc_Prev)
	}

	dir, derr := os.open("/proc")
	if derr != nil {
		return nil
	}
	defer os.close(dir)

	rows := make([dynamic]Proc_Row, 0, 512, al)

	it := os.read_directory_iterator_create(dir)
	defer os.read_directory_iterator_destroy(&it)

	// Names are copied out of a scratch buffer that the next read reuses, so
	// per-row strings are cloned into `al`.
	seen := make(map[int]bool, 512, context.temp_allocator)

	for fi in os.read_directory_iterator(&it) {
		if len(fi.name) == 0 || fi.name[0] < '0' || fi.name[0] > '9' {
			continue
		}
		pid, good := strconv.parse_int(fi.name)
		if !good {
			continue
		}
		row, ok := read_one_proc(pid, dt, al)
		if !ok {
			continue
		}
		append(&rows, row)
		seen[pid] = true
	}

	// Forget processes that have exited, so the map does not grow forever.
	if len(g_prev_ticks) > len(seen) * 2 + 64 {
		dead := make([dynamic]int, 0, 64, context.temp_allocator)
		for k in g_prev_ticks {
			if k not_in seen {
				append(&dead, k)
			}
		}
		for k in dead {
			delete_key(&g_prev_ticks, k)
		}
	}
	return rows[:]
}

@(private)
read_one_proc :: proc(pid: int, dt: f64, al: mem.Allocator) -> (row: Proc_Row, ok: bool) {
	// /proc/<pid>/stat. comm is parenthesised and may itself contain spaces and
	// parens, so everything after the *last* ')' is the field list.
	path_buf: [64]u8
	stat_path := pathi(path_buf[:], "/proc/", pid, "/stat")

	stat_buf: [4096]u8
	text, got := slurp_into(stat_path, stat_buf[:])
	if !got {
		return {}, false
	}
	lp := strings.index_byte(text, '(')
	rp := strings.last_index_byte(text, ')')
	if lp < 0 || rp <= lp {
		return {}, false
	}
	comm := text[lp + 1:rp]
	rest := text[rp + 1:]

	// Fields 3..; indices below are 0-based into what follows comm.
	f := [24]u64{}
	states: u8 = '?'
	if s, g := next_field(&rest); g && len(s) > 0 {
		states = s[0]
	}
	for i in 0 ..< 22 {
		f[i] = field_u64(&rest)
	}
	// f[0] ppid, f[9] utime, f[10] stime, f[13] priority, f[14] nice,
	// f[15] num_threads, f[17] starttime, f[18] vsize, f[19] rss(pages).
	ppid := int(f[0])
	utime := f[9]
	stime := f[10]
	nice := int(i64(f[14]))
	threads := int(f[15])
	start := f[17]
	vsz := f[18]
	rss := f[19] * 4096

	ticks := utime + stime
	cpu: f32 = 0
	if prev, have := g_prev_ticks[pid]; have && prev.start == start && dt > 0 {
		if ticks >= prev.ticks {
			secs := f64(ticks - prev.ticks) / g_hz
			cpu = f32(secs / dt * 100)
		}
	}
	g_prev_ticks[pid] = {start = start, ticks = ticks}

	// /proc/<pid>/status for the owning uid. The kernel also repeats Name here,
	// but stat's comm is the same string and we already have it.
	uid: u32 = 0xffff_ffff
	status_path := pathi(path_buf[:], "/proc/", pid, "/status")
	stbuf: [8192]u8
	if stext, sgot := slurp_into(status_path, stbuf[:]); sgot {
		srest := stext
		for line in strings.split_lines_iterator(&srest) {
			if strings.has_prefix(line, "Uid:") {
				r := line[4:]
				uid = u32(field_u64(&r))
				break
			}
		}
	}

	// /proc/<pid>/cmdline is NUL-separated argv. Empty means a kernel thread,
	// which is shown the way ps does it: in square brackets.
	cmd_path := pathi(path_buf[:], "/proc/", pid, "/cmdline")
	cmdbuf: [4096]u8
	cmd := ""
	kernel := true
	if ctext, cgot := slurp_into(cmd_path, cmdbuf[:]); cgot && len(ctext) > 0 {
		trimmed := ctext
		for len(trimmed) > 0 && trimmed[len(trimmed) - 1] == 0 {
			trimmed = trimmed[:len(trimmed) - 1]
		}
		if len(trimmed) > 0 {
			kernel = false
			// Replace the NUL separators with spaces in place; cmdbuf is ours.
			b := transmute([]u8)trimmed
			for &ch in b {
				if ch == 0 {
					ch = ' '
				}
			}
			cmd = strings.clone(string(b), al)
		}
	}
	if kernel {
		cmd = concat3(al, "[", comm, "]")
	}

	row = Proc_Row {
		pid     = pid,
		ppid    = ppid,
		name    = strings.clone(comm, al),
		cmd     = cmd,
		user    = user_name(uid),
		state   = states,
		threads = threads,
		rss     = rss,
		vsz     = vsz,
		cpu     = cpu,
		ticks   = ticks,
		start   = start,
		nice    = nice,
		kernel  = kernel,
	}
	return row, true
}

state_label :: proc(s: u8) -> string {
	switch s {
	case 'R':
		return "running"
	case 'S':
		return "sleeping"
	case 'D':
		return "disk wait"
	case 'I':
		return "idle"
	case 'Z':
		return "zombie"
	case 'T':
		return "stopped"
	case 't':
		return "traced"
	case 'X':
		return "dead"
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// uid -> name, from /etc/passwd, read once
// ---------------------------------------------------------------------------

g_users: map[u32]string

users_init :: proc() {
	g_users = make(map[u32]string)
	buf := make([]u8, 1 << 20)
	defer delete(buf)
	text, ok := slurp_into("/etc/passwd", buf)
	if !ok {
		return
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		// name:passwd:uid:gid:...
		c1 := strings.index_byte(line, ':')
		if c1 <= 0 {
			continue
		}
		r := line[c1 + 1:]
		c2 := strings.index_byte(r, ':')
		if c2 < 0 {
			continue
		}
		r = r[c2 + 1:]
		c3 := strings.index_byte(r, ':')
		if c3 <= 0 {
			continue
		}
		uid, good := strconv.parse_u64(r[:c3])
		if !good {
			continue
		}
		if u32(uid) not_in g_users {
			g_users[u32(uid)] = strings.clone(line[:c1])
		}
	}
}

user_name :: proc(uid: u32) -> string {
	if uid == 0xffff_ffff {
		return "?"
	}
	if n, ok := g_users[uid]; ok {
		return n
	}
	return "" // the caller prints the number
}

// ---------------------------------------------------------------------------
// Disks: /proc/mounts + statvfs(3)
// ---------------------------------------------------------------------------

Disk :: struct {
	source:  string,
	mount:   string,
	fstype:  string,
	extra:   string, // other mount points sharing this source
	total:   u64,
	free:    u64, // available to an unprivileged process
	ro:      bool,
	ok:      bool,
}

disk_sample :: proc(al := context.allocator) -> []Disk {
	buf := make([]u8, 256 * 1024, context.temp_allocator)
	text, got := slurp_into("/proc/mounts", buf)
	if !got {
		return nil
	}

	out := make([dynamic]Disk, 0, 16, al)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		r := line
		source, s1 := next_field(&r)
		mount, s2 := next_field(&r)
		fstype, s3 := next_field(&r)
		opts, _ := next_field(&r)
		if !s1 || !s2 || !s3 {
			continue
		}
		// Only real block devices. Pseudo-filesystems have no capacity worth
		// showing, and bind mounts of them would repeat it.
		if !strings.has_prefix(source, "/dev/") {
			continue
		}

		// btrfs subvolumes and bind mounts share a device, and statvfs returns
		// the same figures for each. Show the device once, and name the other
		// mount points beside it.
		if existing := find_disk(out[:], source); existing >= 0 {
			d := &out[existing]
			if len(d.mount) > len(mount) {
				d.extra = d.extra == "" ? d.mount : concat3(al, d.mount, ", ", d.extra)
				d.mount = strings.clone(mount, al)
			} else {
				d.extra = d.extra == "" \
					? strings.clone(mount, al) \
					: concat3(al, d.extra, ", ", mount)
			}
			continue
		}

		d := Disk {
			source = strings.clone(source, al),
			mount  = strings.clone(mount, al),
			fstype = strings.clone(fstype, al),
			ro     = strings.has_prefix(opts, "ro,") || opts == "ro",
		}
		cpath := strings.clone_to_cstring(mount, context.temp_allocator)
		vfs: posix.statvfs_t
		if posix.statvfs(cpath, &vfs) == .OK && vfs.f_blocks > 0 {
			unit := u64(vfs.f_frsize != 0 ? vfs.f_frsize : vfs.f_bsize)
			d.total = u64(vfs.f_blocks) * unit
			d.free = u64(vfs.f_bavail) * unit
			d.ok = true
		}
		append(&out, d)
	}
	return out[:]
}

@(private)
find_disk :: proc(ds: []Disk, source: string) -> int {
	for d, i in ds {
		if d.source == source {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Network: /proc/net/dev
// ---------------------------------------------------------------------------

MAX_IFS :: 24

Net_If :: struct {
	name:            string,
	rx, tx:          u64, // bytes since boot
	rx_rate, tx_rate: f64, // bytes per second over the last interval
	rx_pkts, tx_pkts: u64,
	drops:           u64,
	errs:            u64,
	up:              bool, // operstate, from /sys/class/net
	carrier:         bool,
}

Net :: struct {
	ifs:       [MAX_IFS]Net_If,
	n:         int,
	prev:      [MAX_IFS]struct {
		name:   string,
		rx, tx: u64,
	},
	prev_n:    int,
	have_prev: bool,
	// Machine totals, excluding loopback.
	rx_rate:   f64,
	tx_rate:   f64,
}

net_sample :: proc(nt: ^Net, dt: f64, al := context.allocator) {
	text, got := slurp("/proc/net/dev")
	if !got {
		return
	}
	n := 0
	nt.rx_rate, nt.tx_rate = 0, 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		name := strings.trim_space(line[:colon])
		if name == "" || n >= MAX_IFS {
			continue
		}
		r := line[colon + 1:]
		rx := field_u64(&r)
		rx_pkts := field_u64(&r)
		rx_errs := field_u64(&r)
		rx_drop := field_u64(&r)
		for _ in 0 ..< 4 {field_u64(&r)} 	// fifo frame compressed multicast
		tx := field_u64(&r)
		tx_pkts := field_u64(&r)
		tx_errs := field_u64(&r)
		tx_drop := field_u64(&r)

		e := &nt.ifs[n]
		e^ = Net_If {
			name    = strings.clone(name, al),
			rx      = rx,
			tx      = tx,
			rx_pkts = rx_pkts,
			tx_pkts = tx_pkts,
			errs    = rx_errs + tx_errs,
			drops   = rx_drop + tx_drop,
		}

		// operstate and carrier, so an interface with zero traffic can still
		// say whether it is down or merely quiet.
		sp := [128]u8{}
		nb: [512]u8
		if s, ok := slurp_into(paths(sp[:], "/sys/class/net/", name, "/operstate"), nb[:]); ok {
			e.up = strings.trim_space(s) == "up"
		}
		if s, ok := slurp_into(paths(sp[:], "/sys/class/net/", name, "/carrier"), nb[:]); ok {
			e.carrier = strings.trim_space(s) == "1"
		}

		if nt.have_prev && dt > 0 {
			for k in 0 ..< nt.prev_n {
				if nt.prev[k].name != name {
					continue
				}
				if rx >= nt.prev[k].rx {
					e.rx_rate = f64(rx - nt.prev[k].rx) / dt
				}
				if tx >= nt.prev[k].tx {
					e.tx_rate = f64(tx - nt.prev[k].tx) / dt
				}
				break
			}
			if name != "lo" {
				nt.rx_rate += e.rx_rate
				nt.tx_rate += e.tx_rate
			}
		}
		n += 1
	}
	nt.n = n

	// The previous sample's names outlive the frame arena, so they are kept in
	// fixed buffers rather than cloned.
	nt.prev_n = n
	for i in 0 ..< n {
		nt.prev[i].name = static_str(i, nt.ifs[i].name)
		nt.prev[i].rx = nt.ifs[i].rx
		nt.prev[i].tx = nt.ifs[i].tx
	}
	nt.have_prev = true
}

// static_str parks a short interface name in a fixed table so it survives the
// arena reset between samples.
@(private)
g_if_names: [MAX_IFS][24]u8
@(private)
g_if_lens: [MAX_IFS]int

@(private)
static_str :: proc(slot: int, s: string) -> string {
	n := min(len(s), len(g_if_names[slot]))
	copy(g_if_names[slot][:], s[:n])
	g_if_lens[slot] = n
	return string(g_if_names[slot][:n])
}

// ---------------------------------------------------------------------------
// Temperatures: /sys/class/hwmon/*/temp*_input
// ---------------------------------------------------------------------------

Temp :: struct {
	chip:  string,
	label: string,
	c:     f32,
	crit:  f32, // 0 when the chip does not publish one
}

temp_sample :: proc(al := context.allocator) -> []Temp {
	out := make([dynamic]Temp, 0, 16, al)
	pb: [160]u8
	np: [192]u8

	for h in 0 ..< 32 {
		base := pathi(pb[:], "/sys/class/hwmon/hwmon", h)
		chip, has_chip := read_line(paths(np[:], base, "/name"), al)
		if !has_chip {
			continue
		}
		for t in 1 ..= 16 {
			tb: [192]u8
			stem := paths(tb[:], base, "/temp")
			sb: [208]u8
			milli, ok := read_u64(pathi(sb[:], stem, t, "_input"))
			if !ok {
				continue
			}
			lb: [208]u8
			label, has_label := read_line(pathi(lb[:], stem, t, "_label"), al)
			if !has_label {
				label = chip
			}
			cb: [208]u8
			crit: f32 = 0
			if cv, cok := read_u64(pathi(cb[:], stem, t, "_crit")); cok {
				crit = f32(cv) / 1000
			}
			append(&out, Temp{chip = chip, label = label, c = f32(milli) / 1000, crit = crit})
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Machine identity, read once
// ---------------------------------------------------------------------------

Host :: struct {
	hostname:  string,
	kernel:    string,
	cpu_model: string,
	cores:     int,
	threads:   int,
	distro:    string,
}

host_read :: proc(al := context.allocator) -> (h: Host) {
	h.hostname, _ = read_line("/proc/sys/kernel/hostname", al)
	if h.hostname == "" {
		h.hostname = "localhost"
	}
	h.kernel, _ = read_line("/proc/sys/kernel/osrelease", al)

	if text, ok := slurp("/proc/cpuinfo"); ok {
		rest := text
		siblings, cpu_cores := 0, 0
		for line in strings.split_lines_iterator(&rest) {
			if h.cpu_model == "" && strings.has_prefix(line, "model name") {
				if c := strings.index_byte(line, ':'); c > 0 {
					h.cpu_model = strings.clone(strings.trim_space(line[c + 1:]), al)
				}
			} else if siblings == 0 && strings.has_prefix(line, "siblings") {
				if c := strings.index_byte(line, ':'); c > 0 {
					r := line[c + 1:]
					siblings = int(field_u64(&r))
				}
			} else if cpu_cores == 0 && strings.has_prefix(line, "cpu cores") {
				if c := strings.index_byte(line, ':'); c > 0 {
					r := line[c + 1:]
					cpu_cores = int(field_u64(&r))
				}
			}
		}
		h.cores = cpu_cores
		h.threads = siblings
	}
	if h.cpu_model == "" {
		h.cpu_model = "Unknown CPU"
	}

	if text, ok := slurp("/etc/os-release"); ok {
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, "PRETTY_NAME=") {
				v := strings.trim_space(line[12:])
				v = strings.trim(v, "\"")
				h.distro = strings.clone(v, al)
				break
			}
		}
	}
	return
}
