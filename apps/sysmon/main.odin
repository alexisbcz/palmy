package main

// A system monitor for Wayland, drawn by palmy's software rasterizer.
//
// Every number on screen comes out of /proc or /sys — see sys.odin. There is
// no subprocess anywhere in this program: the kernel publishes all of it as
// text files, and a sampler that reads them directly is both faster and
// honest about where the figures came from.
//
// Sampling is synchronous and takes a couple of milliseconds, so it happens
// inside the frame. There is no worker thread here at all, and therefore
// nothing to deadlock: the only thing that could ever block is a stuck NFS
// mount in statvfs, which is why the disk strip says when a mount did not
// answer rather than waiting for it.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"
import p "palmy:."

HEADER_H :: 92
STRIP_H :: 152
FOOTER_H :: 44
ROW_H :: 28

// How often the kernel is asked again. One second is the shortest interval at
// which a jiffy delta is meaningful at 100Hz: below it the quantisation noise
// is larger than the signal.
SAMPLE_DT :: 1.0

Sort_Key :: enum {
	Cpu,
	Mem,
	Pid,
	Name,
	Threads,
	User,
}

sort_label :: proc(k: Sort_Key) -> string {
	switch k {
	case .Cpu:
		return "CPU"
	case .Mem:
		return "Memory"
	case .Pid:
		return "PID"
	case .Name:
		return "Process"
	case .Threads:
		return "Threads"
	case .User:
		return "User"
	}
	return ""
}

Model :: struct {
	// Everything a sample allocates lives in this arena and is thrown away
	// whole at the next one.
	arena:        virtual.Arena,
	al:           mem.Allocator,
	host:         Host,

	cpu:          Cpu,
	mem:          Mem,
	load:         Load,
	net:          Net,
	procs:        []Proc_Row,
	disks:        []Disk,
	temps:        []Temp,
	uptime:       f64,
	idle_secs:    f64,

	// Graph history. Fixed-size rings, so they survive the arena reset.
	h_cpu:        Series,
	h_mem:        Series,
	h_swap:       Series,
	h_rx:         Series,
	h_tx:         Series,
	h_load:       Series,

	// Sampling.
	samples:      int,
	next_sample:  f64,
	last_sample:  f64,
	sample_ms:    f32, // how long the last sample took, shown in the footer
	proc_ms:      f32,
	paused:       bool,

	// The process table.
	sort:         Sort_Key,
	desc:         bool,
	filter:       [dynamic]u8,
	filter_focus: bool,
	filter_id:    u64,
	sel_pid:      int,
	top:          int,
	rows:         int,
	show_kernel:  bool,
	show_idle:    bool,

	// Drawing state handed to the `pixels` callbacks.
	g_cpu:        Graph,
	g_mem:        Graph,
	g_net:        Graph,
	cores_art:    Cores,

	help_open:    bool,
	detail_open:  bool,

	toast:        [160]u8,
	toast_len:    int,
	toast_until:  f64,
}

g_now: f64

main :: proc() {
	// A live monitor has something new to draw every frame the graphs move, so
	// unlike an applet it asks for a frame every vsync. PALMY_CONTINUOUS is
	// honoured for symmetry with the other apps but changes nothing here.
	_ = os.get_env("PALMY_CONTINUOUS", context.temp_allocator)

	app, err := start_window()
	if err != "" {
		fmt.eprintfln("sysmon: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	hz_init()
	users_init()

	m := new(Model)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	m.al = virtual.arena_allocator(&m.arena)
	m.host = host_read()
	m.sort = .Cpu
	m.desc = true
	m.sel_pid = -1
	m.show_kernel = false
	m.show_idle = true

	// Prime the counters. Nothing on screen is a rate yet, and the UI says so.
	sample(m, 0)
	// A second sample a third of a second later means the first picture a
	// person sees is real rather than a row of zeros.
	m.next_sample = 0.35

	for ui in p.frames(app) {
		now := f64(p.elapsed(ui))
		g_now = now
		p.redraw(ui)

		if !m.paused && now >= m.next_sample {
			dt := m.last_sample > 0 ? now - m.last_sample : SAMPLE_DT
			sample(m, dt)
			m.last_sample = now
			m.next_sample = now + SAMPLE_DT
		}

		measure_rows(m, p.size(ui))
		v := build_view(m)
		keys(ui, app, m, v)
		// The view is rebuilt after the keys, so the frame that follows a
		// keypress already shows its effect.
		build(ui, m, build_view(m))
	}
}

note :: proc(m: ^Model, s: string) {
	n := min(len(s), len(m.toast))
	copy(m.toast[:], s[:n])
	m.toast_len = n
	m.toast_until = g_now + 4.0
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

sample :: proc(m: ^Model, dt: f64) {
	t0 := time.tick_now()

	// Fixed-size state is updated in place; the lists are rebuilt in the
	// arena, which is reset first.
	cpu_sample(&m.cpu)
	mem_sample(&m.mem)
	load_sample(&m.load)

	virtual.arena_free_all(&m.arena)
	m.al = virtual.arena_allocator(&m.arena)

	net_sample(&m.net, dt, m.al)
	m.disks = disk_sample(m.al)
	m.temps = temp_sample(m.al)
	m.uptime, m.idle_secs, _ = uptime_sample()

	t1 := time.tick_now()
	m.procs = proc_sample(dt, m.al)
	t2 := time.tick_now()

	m.samples += 1

	// The first sample has no deltas, so it is primed but not plotted.
	if m.samples > 1 {
		series_push(&m.h_cpu, m.cpu.agg * 100)
		if m.mem.total > 0 {
			series_push(&m.h_mem, f32(f64(mem_used(m.mem)) / f64(m.mem.total)) * 100)
		}
		if m.mem.swap_total > 0 {
			used := m.mem.swap_total - m.mem.swap_free
			series_push(&m.h_swap, f32(f64(used) / f64(m.mem.swap_total)) * 100)
		} else {
			series_push(&m.h_swap, 0)
		}
		series_push(&m.h_rx, f32(m.net.rx_rate))
		series_push(&m.h_tx, f32(m.net.tx_rate))
		series_push(&m.h_load, m.load.avg[0])
	}

	m.sample_ms = f32(time.duration_milliseconds(time.tick_diff(t0, t2)))
	m.proc_ms = f32(time.duration_milliseconds(time.tick_diff(t1, t2)))
}

// ---------------------------------------------------------------------------
// History
//
// A plain ring. Nothing here is allocated, so it outlives the arena reset that
// every sample performs.
// ---------------------------------------------------------------------------

HIST :: 300

Series :: struct {
	v:   [HIST]f32,
	n:   int, // total pushed, saturating at HIST for the read side
	at:  int,
	max: f32, // the largest value ever pushed, for a stable autoscale
}

series_push :: proc(s: ^Series, x: f32) {
	s.v[s.at] = x
	s.at = (s.at + 1) % HIST
	if s.n < HIST {
		s.n += 1
	}
	s.max = max(s.max, x)
}

// series_at reads the ring oldest-first, 0 ..< series_count.
series_at :: proc(s: ^Series, i: int) -> f32 {
	if s.n <= 0 {
		return 0
	}
	start := s.n < HIST ? 0 : s.at
	return s.v[(start + i) % HIST]
}

series_count :: proc(s: ^Series) -> int {
	return s.n
}

// series_peak is the largest value in the window currently on screen, which is
// what an autoscaling axis should follow.
series_peak :: proc(s: ^Series) -> f32 {
	out: f32 = 0
	for i in 0 ..< s.n {
		out = max(out, series_at(s, i))
	}
	return out
}

series_last :: proc(s: ^Series) -> f32 {
	if s.n == 0 {
		return 0
	}
	return s.v[(s.at - 1 + HIST) % HIST]
}

// ---------------------------------------------------------------------------
// The process view: filtered, sorted, windowed
// ---------------------------------------------------------------------------

View :: struct {
	rows:  []int, // indices into m.procs, in display order
	sel:   int, // index into m.procs, -1 for none
	at:    int, // position of the selection in `rows`
	total: int, // before filtering
	cpu_sum: f32,
	rss_sum: u64,
}

icontains :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(hay) {
		return false
	}
	low :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	outer: for i in 0 ..= len(hay) - len(needle) {
		for j in 0 ..< len(needle) {
			if low(hay[i + j]) != low(needle[j]) {
				continue outer
			}
		}
		return true
	}
	return false
}

proc_matches :: proc(r: Proc_Row, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if icontains(r.name, needle) || icontains(r.user, needle) || icontains(r.cmd, needle) {
		return true
	}
	// A bare number also matches a pid, which is how a person looks one up.
	pid_str := fmt.tprintf("%d", r.pid)
	return icontains(pid_str, needle)
}

build_view :: proc(m: ^Model) -> (v: View) {
	needle := string(m.filter[:])
	idx := make([dynamic]int, 0, len(m.procs), context.temp_allocator)
	for r, i in m.procs {
		v.total += 1
		if !m.show_kernel && r.kernel {
			continue
		}
		if !m.show_idle && r.cpu < 0.05 {
			continue
		}
		if !proc_matches(r, needle) {
			continue
		}
		append(&idx, i)
		v.cpu_sum += r.cpu
		v.rss_sum += r.rss
	}

	// Heap sort: the list is a few hundred entries and is re-sorted every
	// second, so an O(n log n) in-place sort with no allocation is right.
	sort_rows(m, idx[:])
	v.rows = idx[:]
	v.sel = -1
	v.at = -1
	for i, k in v.rows {
		if m.procs[i].pid == m.sel_pid {
			v.sel = i
			v.at = k
			break
		}
	}
	if v.at < 0 && len(v.rows) > 0 {
		v.sel = v.rows[0]
		v.at = 0
		m.sel_pid = m.procs[v.sel].pid
	}

	if v.at >= 0 {
		m.top = clamp(m.top, max(0, v.at - m.rows + 1), v.at)
	}
	m.top = clamp(m.top, 0, max(0, len(v.rows) - m.rows))
	return
}

proc_less :: proc(m: ^Model, a, b: int) -> bool {
	x, y := m.procs[a], m.procs[b]
	r: bool
	switch m.sort {
	case .Cpu:
		if x.cpu != y.cpu {
			r = x.cpu < y.cpu
		} else {
			r = x.rss < y.rss
		}
	case .Mem:
		if x.rss != y.rss {
			r = x.rss < y.rss
		} else {
			r = x.cpu < y.cpu
		}
	case .Pid:
		r = x.pid < y.pid
	case .Name:
		r = less_fold(x.name, y.name)
	case .Threads:
		if x.threads != y.threads {
			r = x.threads < y.threads
		} else {
			r = x.pid < y.pid
		}
	case .User:
		if x.user != y.user {
			r = less_fold(x.user, y.user)
		} else {
			r = x.cpu < y.cpu
		}
	}
	return m.desc ? !r : r
}

less_fold :: proc(a, b: string) -> bool {
	low :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	n := min(len(a), len(b))
	for i in 0 ..< n {
		ca, cb := low(a[i]), low(b[i])
		if ca != cb {
			return ca < cb
		}
	}
	return len(a) < len(b)
}

sort_rows :: proc(m: ^Model, xs: []int) {
	n := len(xs)
	if n < 2 {
		return
	}
	sift :: proc(m: ^Model, xs: []int, start, count: int) {
		root := start
		for {
			child := root * 2 + 1
			if child >= count {
				return
			}
			if child + 1 < count && proc_less(m, xs[child], xs[child + 1]) {
				child += 1
			}
			if !proc_less(m, xs[root], xs[child]) {
				return
			}
			xs[root], xs[child] = xs[child], xs[root]
			root = child
		}
	}
	for i := n / 2 - 1; i >= 0; i -= 1 {
		sift(m, xs, i, n)
	}
	for i := n - 1; i > 0; i -= 1 {
		xs[0], xs[i] = xs[i], xs[0]
		sift(m, xs, 0, i)
	}
}

move_sel :: proc(m: ^Model, v: View, delta: int) {
	if len(v.rows) == 0 {
		return
	}
	at := v.at < 0 ? 0 : clamp(v.at + delta, 0, len(v.rows) - 1)
	m.sel_pid = m.procs[v.rows[at]].pid
}

// ---------------------------------------------------------------------------
// Keyboard
//
// Sorting and filtering are both keyboard-driven: this compositor cannot
// synthesise a pointer click, and a monitor is a keyboard tool anyway.
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^Model, v: View) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
	}

	if m.help_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) ||
		   p.key_pressed(ui, '?') ||
		   p.key_pressed(ui, p.KEY_F1) {
			m.help_open = false
		}
		return
	}

	// Navigation works whether or not the filter has the keyboard: the arrows
	// are not text.
	if p.key_pressed(ui, p.KEY_DOWN) {move_sel(m, v, 1)}
	if p.key_pressed(ui, p.KEY_UP) {move_sel(m, v, -1)}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {move_sel(m, v, max(1, m.rows - 1))}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {move_sel(m, v, -max(1, m.rows - 1))}

	if m.filter_focus {
		// While typing, letters belong to the field. Escape gives them back.
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			if len(m.filter) > 0 {
				clear(&m.filter)
			} else {
				p.set_focus(ui, 0)
			}
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			p.set_focus(ui, 0)
		}
		return
	}

	if p.key_pressed(ui, p.KEY_HOME) {move_sel(m, v, -1 << 20)}
	if p.key_pressed(ui, p.KEY_END) {move_sel(m, v, 1 << 20)}

	// Sort column: letters pick one directly, arrows walk the header.
	set_sort :: proc(m: ^Model, k: Sort_Key) {
		if m.sort == k {
			m.desc = !m.desc
		} else {
			m.sort = k
			// Numbers read largest-first, names read A to Z.
			m.desc = k != .Name && k != .User
		}
		m.top = 0
		note(m, fmt.tprintf("Sorted by %s, %s", sort_label(k), m.desc ? "descending" : "ascending"))
	}
	if p.key_pressed(ui, 'c') {set_sort(m, .Cpu)}
	if p.key_pressed(ui, 'm') {set_sort(m, .Mem)}
	if p.key_pressed(ui, 'p') {set_sort(m, .Pid)}
	if p.key_pressed(ui, 'n') {set_sort(m, .Name)}
	if p.key_pressed(ui, 't') {set_sort(m, .Threads)}
	if p.key_pressed(ui, 'u') {set_sort(m, .User)}

	cycle :: proc(m: ^Model, d: int) {
		count := int(max(Sort_Key)) + 1
		k := (int(m.sort) + d + count) % count
		m.sort = Sort_Key(k)
		m.desc = m.sort != .Name && m.sort != .User
		m.top = 0
		note(m, fmt.tprintf("Sorted by %s", sort_label(m.sort)))
	}
	if p.key_pressed(ui, p.KEY_RIGHT) {cycle(m, 1)}
	if p.key_pressed(ui, p.KEY_LEFT) {cycle(m, -1)}

	if p.key_pressed(ui, 'r') {
		m.desc = !m.desc
		note(m, m.desc ? "Descending" : "Ascending")
	}
	if p.key_pressed(ui, 'k') {
		m.show_kernel = !m.show_kernel
		note(m, m.show_kernel ? "Showing kernel threads" : "Hiding kernel threads")
	}
	if p.key_pressed(ui, 'i') {
		m.show_idle = !m.show_idle
		note(m, m.show_idle ? "Showing idle processes" : "Only processes using CPU")
	}
	if p.key_pressed(ui, p.KEY_SPACE) {
		m.paused = !m.paused
		note(m, m.paused ? "Sampling paused" : "Sampling resumed")
		if !m.paused {
			m.next_sample = g_now
			m.last_sample = g_now
		}
	}
	if p.key_pressed(ui, 'd') {
		m.detail_open = !m.detail_open
	}
	if p.key_pressed(ui, '?') || p.key_pressed(ui, p.KEY_F1) {
		m.help_open = true
	}
	if p.key_pressed(ui, '/') {
		m.filter_focus = true
		p.set_focus(ui, m.filter_id)
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(m.filter) > 0 {
			clear(&m.filter)
			note(m, "Filter cleared")
		}
	}
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fmt_bytes :: proc(b: u64) -> string {
	f := f64(b)
	switch {
	case b >= 1 << 40:
		return fmt.tprintf("%.2f TiB", f / f64(u64(1) << 40))
	case b >= 1 << 30:
		return fmt.tprintf("%.2f GiB", f / f64(1 << 30))
	case b >= 1 << 20:
		return fmt.tprintf("%.0f MiB", f / f64(1 << 20))
	case b >= 1 << 10:
		return fmt.tprintf("%.0f KiB", f / f64(1 << 10))
	}
	return fmt.tprintf("%d B", b)
}

fmt_bytes_short :: proc(b: u64) -> string {
	f := f64(b)
	switch {
	case b >= 1 << 40:
		return fmt.tprintf("%.1fT", f / f64(u64(1) << 40))
	case b >= 1 << 30:
		return fmt.tprintf("%.1fG", f / f64(1 << 30))
	case b >= 1 << 20:
		return fmt.tprintf("%.0fM", f / f64(1 << 20))
	case b >= 1 << 10:
		return fmt.tprintf("%.0fK", f / f64(1 << 10))
	}
	return fmt.tprintf("%d", b)
}

fmt_rate :: proc(bps: f64) -> string {
	switch {
	case bps >= f64(1 << 30):
		return fmt.tprintf("%.2f GB/s", bps / f64(1 << 30))
	case bps >= f64(1 << 20):
		return fmt.tprintf("%.1f MB/s", bps / f64(1 << 20))
	case bps >= f64(1 << 10):
		return fmt.tprintf("%.0f kB/s", bps / f64(1 << 10))
	}
	return fmt.tprintf("%.0f B/s", bps)
}

fmt_uptime :: proc(secs: f64) -> string {
	s := int(secs)
	d := s / 86400
	h := (s % 86400) / 3600
	mi := (s % 3600) / 60
	sec := s % 60
	if d > 0 {
		return fmt.tprintf("%dd %dh %dm", d, h, mi)
	}
	if h > 0 {
		return fmt.tprintf("%dh %dm %ds", h, mi, sec)
	}
	return fmt.tprintf("%dm %ds", mi, sec)
}

truncate_mid :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	if n < 8 {
		return s[:n]
	}
	head := n / 2 - 1
	tail := n - head - 1
	return fmt.tprintf("%s…%s", s[:head], s[len(s) - tail:])
}
