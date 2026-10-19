// palm-indexd: one per person, keeping every enrolled identity's index in
// step with its data.
//
//	start      nice 19 and the idle I/O class; discover identities; queue a
//	           full scan of every source of every identity
//	watch      inotify on every folder the sources read, plus the parents
//	           (a new identity folder, a Maildir swapped by `palm sync`)
//	           and each index directory (a `rebuild` request)
//	debounce   an event marks (identity, source) dirty; it is rescanned
//	           DEBOUNCE_MS later, so a burst of writes is one rescan
//	batch      a rescan puts only what changed (signatures, sources.odin)
//	           and flushes once; a first build flushes every FLUSH_EVERY
//	           documents so search sees it fill in
//	idle       one merge step per idle second (index.odin, writer_merge)
//	battery    on battery, first builds and rebuilds wait for power; live
//	           changes are still indexed, batched every BATTERY_DEBOUNCE_MS
//	status     <index>/<handle>/status, JSON, after every scan
//
// The daemon is the only writer. Each identity has its own Writer over its
// own directory; a scan of identity A is handed A's Writer and A's folders
// and nothing else.
package indexfeed

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import ic "../core"
import ck "../../cloudkit"

DEBOUNCE_MS :: 300
BATTERY_DEBOUNCE_MS :: 30_000
FLUSH_EVERY :: 2000
WATCH_MASK :: linux.Inotify_Event_Mask{.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .CLOSE_WRITE, .DELETE_SELF, .MOVE_SELF}

// Job names one source of one identity by the identity's slot in
// Daemon.ids: map keys hash their bytes, so a string field would hash the
// pointer, not the handle.
Job :: struct {
	slot:   int,
	source: Source_Kind,
}

Watch :: struct {
	handle: string, // "" for a root-level watch
	source: Source_Kind,
	root:   bool, // a parent folder: a change means "rediscover"
	index:  bool, // an index directory: look for `rebuild`
	path:   string,
}

Source_State :: struct {
	last:      Scan_Stats,
	at:        i64,
	took_ms:   f64,
	scans:     int,
}

Daemon :: struct {
	paths:      Paths,
	scope:      string,
	ids:        [dynamic]Ident,
	writers:    map[string]^ic.Writer,
	mail:       map[string]^Mail_Cache,
	states:     map[string][Source_Kind]Source_State,
	ino:        linux.Fd,
	watches:    map[linux.Wd]Watch,
	by_path:    map[string]linux.Wd,
	due:        map[Job]i64, // ms
	bulk:       map[Job]bool, // a first build or a rebuild: waits for power
	battery:    bool,
	battery_at: i64,
	quit:       bool,
	verbose:    bool,
	once:       bool, // scan everything once and exit (index rebuild, tests)
	cloud:      []ic.Identity,
}

now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// lower_priority makes the daemon the last thing the machine does: CPU
// nice 19 and the idle I/O scheduling class.
lower_priority :: proc() {
	linux.setpriority(.PROCESS, 0, 19)
	IOPRIO_CLASS_IDLE :: 3
	linux.syscall(linux.SYS_ioprio_set, uintptr(1), uintptr(0), uintptr(IOPRIO_CLASS_IDLE << 13))
}

// on_battery reads /sys/class/power_supply: true when a battery reports
// Discharging and no mains supply is online. No battery = mains.
on_battery :: proc() -> bool {
	base := os.get_env("PALM_POWER_SUPPLY_DIR", context.temp_allocator)
	if base == "" {
		base = "/sys/class/power_supply"
	}
	entries, err := os.read_all_directory_by_path(base, context.temp_allocator)
	if err != nil {
		return false
	}
	discharging, mains := false, false
	for e in entries {
		read :: proc(path: string) -> string {
			d, err := os.read_entire_file_from_path(path, context.temp_allocator)
			return err == nil ? strings.trim_space(string(d)) : ""
		}
		typ := read(fmt.tprintf("%s/%s/type", base, e.name))
		switch typ {
		case "Battery":
			if read(fmt.tprintf("%s/%s/status", base, e.name)) == "Discharging" {
				discharging = true
			}
		case "Mains", "USB":
			if read(fmt.tprintf("%s/%s/online", base, e.name)) == "1" {
				mains = true
			}
		}
	}
	if os.get_env("PALM_INDEX_ON_BATTERY", context.temp_allocator) == "run" {
		return false
	}
	return discharging && !mains
}

// cloud_identities asks the account for its identities when this machine
// holds the person's own session. Best effort: offline is normal.
cloud_identities :: proc() -> []ic.Identity {
	if os.get_env("PALM_INDEX_NO_CLOUD", context.temp_allocator) != "" {
		return nil
	}
	c, err := ck.open(app = "indexd")
	defer ck.close(c)
	if !ck.ok(err) || !ck.signed_in(c) || ck.scoped(c) {
		return nil
	}
	ck.ensure_fresh(c)
	xs, e := ck.identities(c)
	if !ck.ok(e) {
		return nil
	}
	out := make([dynamic]ic.Identity)
	for x in xs {
		if x.archived {
			continue
		}
		append(&out, ic.Identity{id = strings.clone(x.id), handle = strings.clone(x.handle), name = strings.clone(x.display_name), kind = strings.clone(x.kind), color = strings.clone(x.color)})
	}
	ck.identities_free(xs)
	return out[:]
}

daemon_init :: proc(d: ^Daemon, p: Paths, scope := "") -> string {
	d.paths = p
	d.scope = scope
	os.make_directory_all(p.index, os.perm_number(0o700))
	fd, e := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if e != .NONE {
		return "inotify is not available"
	}
	d.ino = fd
	d.cloud = cloud_identities()
	daemon_discover(d)
	return ""
}

@(private)
watch_add :: proc(d: ^Daemon, path: string, w: Watch) {
	if path in d.by_path {
		return
	}
	cp := strings.clone_to_cstring(path, context.temp_allocator)
	wd, e := linux.inotify_add_watch(d.ino, cp, WATCH_MASK)
	if e != .NONE {
		return
	}
	w := w
	w.path = strings.clone(path)
	if old, ok := d.watches[wd]; ok {
		// The same directory reached by two paths: keep the first.
		_ = old
		return
	}
	d.watches[wd] = w
	d.by_path[w.path] = wd
}

@(private)
find_ident :: proc(d: ^Daemon, handle: string) -> ^Ident {
	for &x in d.ids {
		if x.handle == handle {
			return &x
		}
	}
	return nil
}

@(private)
slot_of :: proc(d: ^Daemon, handle: string) -> int {
	for x, i in d.ids {
		if x.handle == handle {
			return i
		}
	}
	return -1
}

// daemon_discover (re)reads which identities exist and opens a writer for
// each new one, queueing its first build.
daemon_discover :: proc(d: ^Daemon) {
	ids := discover(d.paths, d.scope, d.cloud)
	for x in ids {
		if find_ident(d, x.handle) != nil {
			// Refresh what may have changed (a name, a colour, the Maildir).
			cur := find_ident(d, x.handle)
			cur.info = x.info
			cur.mail_dir = x.mail_dir
			write_identity(d, cur^)
			continue
		}
		w, err := ic.writer_open(d.paths.index, x.handle)
		if w == nil {
			fmt.eprintfln("palm-indexd: %s: %s", x.handle, err)
			continue
		}
		append(&d.ids, x)
		d.writers[strings.clone(x.handle)] = w
		mc := new(Mail_Cache)
		d.mail[strings.clone(x.handle)] = mc
		d.states[strings.clone(x.handle)] = {}
		write_identity(d, x)
		for k in Source_Kind {
			j := Job{len(d.ids) - 1, k}
			d.due[j] = 0
			d.bulk[j] = true
		}
		watch_add(d, fmt.tprintf("%s/%s", d.paths.index, x.handle), Watch{handle = strings.clone(x.handle), index = true})
	}
	// Parents: a new identity folder, a Maildir swap, palmy.conf.
	for dir in ([?]string{d.paths.mail, d.paths.drive, d.paths.notes, d.paths.dav, d.paths.browser, d.paths.track}) {
		if os.is_dir(dir) {
			watch_add(d, dir, Watch{root = true})
		}
	}
}

@(private)
write_identity :: proc(d: ^Daemon, x: Ident) {
	path := fmt.tprintf("%s/%s/identity", d.paths.index, x.handle)
	text := identity_json(x.info)
	if old, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil && string(old) == text {
		return
	}
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]u8)text, os.perm_number(0o600)) == nil {
		os.rename(tmp, path)
	}
}

// The writer a scan is filling, for the yield callback.
@(private)
g_scan_writer: ^ic.Writer
@(private)
g_scan_count: int

@(private)
scan_yield :: proc() {
	g_scan_count += 1
	if g_scan_writer != nil && g_scan_writer.ops >= FLUSH_EVERY {
		ic.writer_flush(g_scan_writer)
	}
}

// run_job rescans one source of one identity and flushes.
run_job :: proc(d: ^Daemon, j: Job) {
	if j.slot < 0 || j.slot >= len(d.ids) {
		return
	}
	x := &d.ids[j.slot]
	w := d.writers[x.handle]
	if w == nil {
		return
	}
	t0 := time.tick_now()
	g_scan_writer = w
	mine := make([dynamic]string, context.temp_allocator)
	for y in d.ids {
		append(&mine, strings.to_lower(y.address, context.temp_allocator))
	}
	st := scan(w, x^, d.paths, j.source, d.mail[x.handle], scan_yield, mine[:])
	g_scan_writer = nil
	ic.writer_flush(w)
	for dir in st.dirs {
		watch_add(d, dir, Watch{handle = x.handle, source = j.source})
	}
	states := d.states[x.handle]
	s := &states[j.source]
	delete(s.last.dirs)
	s.last = st
	s.last.dirs = nil
	delete(st.dirs)
	s.at = time.to_unix_seconds(time.now())
	s.took_ms = time.duration_milliseconds(time.tick_since(t0))
	s.scans += 1
	d.states[x.handle] = states
	if d.verbose && (st.added > 0 || st.removed > 0 || s.scans == 1) {
		fmt.eprintfln("palm-indexd: %s/%s: %d seen, %d indexed, %d removed, %d unchanged (%.0f ms)", x.handle, SOURCE_NAME[j.source], st.seen, st.added, st.removed, st.skipped, s.took_ms)
	}
	write_status(d, x.handle, "")
}

// write_status records what the daemon knows about one identity.
write_status :: proc(d: ^Daemon, handle: string, state: string) {
	w := d.writers[handle]
	if w == nil {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	q :: proc(s: string) -> string {
		b, _ := json.marshal(s, allocator = context.temp_allocator)
		return string(b)
	}
	st := state
	if st == "" {
		st = "idle"
		slot := slot_of(d, handle)
		for j, _ in d.due {
			if j.slot == slot {
				st = d.battery && d.bulk[j] ? "paused: on battery" : "indexing"
			}
		}
	}
	per_kind: [ic.Kind]int
	for s in w.ix.segs {
		for r, i in s.docs {
			if !s.dead[i] {
				per_kind[r.kind] += 1
			}
		}
	}
	fmt.sbprintf(&sb, "{{\"pid\":%d,\"updated\":%d,\"state\":%s,\"docs\":%d,\"segments\":%d,\"bytes\":%d,\"generation\":%d,\"kinds\":{{", linux.getpid(), time.to_unix_seconds(time.now()), q(st), w.ix.ndocs, len(w.ix.segs), ic.index_bytes(w.ix), w.ix.gen)
	first := true
	for n, k in per_kind {
		if n == 0 {
			continue
		}
		fmt.sbprintf(&sb, "%s%s:%d", first ? "" : ",", q(ic.KIND_NAME[k]), n)
		first = false
	}
	strings.write_string(&sb, "},\"sources\":{")
	states := d.states[handle]
	first = true
	for k in Source_Kind {
		s := states[k]
		fmt.sbprintf(&sb, "%s%s:{{\"present\":%v,\"scans\":%d,\"last_scan\":%d,\"took_ms\":%.1f,\"seen\":%d,\"indexed\":%d,\"removed\":%d,\"unchanged\":%d,\"errors\":%d}}",
			first ? "" : ",", q(SOURCE_NAME[k]), s.last.present, s.scans, s.at, s.took_ms, s.last.seen, s.last.added, s.last.removed, s.last.skipped, s.last.errors)
		first = false
	}
	strings.write_string(&sb, "}}\n")
	path := fmt.tprintf("%s/%s/status", d.paths.index, handle)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(sb), os.perm_number(0o600)) == nil {
		os.rename(tmp, path)
	}
}

@(private)
mark :: proc(d: ^Daemon, j: Job, delay: i64) {
	at := now_ms() + delay
	if old, ok := d.due[j]; ok && old <= at {
		return
	}
	d.due[j] = at
}

// rebuild empties an identity's index and queues every source.
rebuild :: proc(d: ^Daemon, handle: string) {
	w := d.writers[handle]
	if w == nil {
		return
	}
	ic.writer_clear(w)
	if mc := d.mail[handle]; mc != nil {
		mail_cache_destroy(mc)
		mc^ = {}
	}
	slot := slot_of(d, handle)
	for k in Source_Kind {
		j := Job{slot, k}
		d.due[j] = 0
		d.bulk[j] = true
	}
	write_status(d, handle, "rebuilding")
}

@(private)
handle_events :: proc(d: ^Daemon) {
	buf: [16 * 1024]u8
	for {
		n, e := linux.read(d.ino, buf[:])
		if e != .NONE || n <= 0 {
			return
		}
		off := 0
		for off + size_of(linux.Inotify_Event) <= n {
			ev := (^linux.Inotify_Event)(&buf[off])
			name := ""
			if ev.len > 0 {
				raw := buf[off + size_of(linux.Inotify_Event):][:ev.len]
				end := 0
				for end < len(raw) && raw[end] != 0 {
					end += 1
				}
				name = string(raw[:end])
			}
			off += size_of(linux.Inotify_Event) + int(ev.len)
			if .Q_OVERFLOW in ev.mask {
				// Lost events: rescan everything (signatures make it cheap).
				for _, i in d.ids {
					for k in Source_Kind {
						mark(d, Job{i, k}, DEBOUNCE_MS)
					}
				}
				continue
			}
			w, ok := d.watches[ev.wd]
			if !ok {
				continue
			}
			if .IGNORED in ev.mask {
				delete_key(&d.by_path, w.path)
				delete_key(&d.watches, ev.wd)
				continue
			}
			delay := i64(d.battery ? BATTERY_DEBOUNCE_MS : DEBOUNCE_MS)
			switch {
			case w.index:
				if name == "rebuild" {
					os.remove(fmt.tprintf("%s/%s/rebuild", d.paths.index, w.handle))
					rebuild(d, w.handle)
				}
			case w.root:
				// A parent changed: maybe a new identity, maybe a swapped
				// Maildir. Rediscover, then rescan the matching sources.
				daemon_discover(d)
				for x, i in d.ids {
					if w.path == d.paths.mail {
						mark(d, Job{i, .Mail}, delay)
					} else if name == x.handle {
						for k in Source_Kind {
							mark(d, Job{i, k}, delay)
						}
					}
				}
			case:
				if strings.has_prefix(name, ".palm-drive-") || strings.has_suffix(name, ".tmp") {
					continue // a temporary, renamed into place later
				}
				if slot := slot_of(d, w.handle); slot >= 0 {
					mark(d, Job{slot, w.source}, delay)
				}
			}
		}
	}
}

// daemon_step runs what is due, or one merge when nothing is. Returns how
// long the loop may sleep, in ms.
daemon_step :: proc(d: ^Daemon) -> i32 {
	t := now_ms()
	if t - d.battery_at > 30_000 {
		d.battery = on_battery()
		d.battery_at = t
	}
	next := i64(-1)
	pick: Job
	found := false
	for j, at in d.due {
		if d.battery && d.bulk[j] {
			continue // waits for power
		}
		if at <= t && (!found || at < d.due[pick]) {
			pick = j
			found = true
		}
		if next < 0 || at < next {
			next = at
		}
	}
	if found {
		delete_key(&d.due, pick)
		delete_key(&d.bulk, pick)
		run_job(d, pick)
		free_all(context.temp_allocator)
		return 0
	}
	// Idle: one merge step.
	for x in d.ids {
		if w := d.writers[x.handle]; w != nil && ic.writer_merge(w) {
			write_status(d, x.handle, "")
			free_all(context.temp_allocator)
			return 0
		}
	}
	if d.once && len(d.due) == 0 {
		d.quit = true
		return 0
	}
	if next < 0 {
		return d.battery ? 30_000 : 5_000
	}
	return i32(clamp(next - t, 0, 5_000))
}

daemon_run :: proc(d: ^Daemon) {
	// The daemon's own scratch space, freed after every job: never the
	// caller's temp allocator, which may hold what it handed us.
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	context.temp_allocator = runtime.arena_allocator(&arena)
	for !d.quit {
		wait := daemon_step(d)
		if d.quit {
			break
		}
		if wait > 0 {
			fds := []linux.Poll_Fd{{fd = d.ino, events = {.IN}}}
			linux.poll(fds, wait)
		}
		handle_events(d)
	}
}

daemon_close :: proc(d: ^Daemon) {
	for _, w in d.writers {
		ic.writer_close(w)
	}
	for _, mc in d.mail {
		mail_cache_destroy(mc)
		free(mc)
	}
	linux.close(d.ino)
}

// ---------------------------------------------------------------------------
// One daemon per person: a lock and a pid file in the index root.
// ---------------------------------------------------------------------------

daemon_lock :: proc(root: string) -> (fd: linux.Fd, ok: bool) {
	os.make_directory_all(root, os.perm_number(0o700))
	p := strings.clone_to_cstring(fmt.tprintf("%s/daemon.lock", root), context.temp_allocator)
	f, e := linux.open(p, {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return -1, false
	}
	if linux.flock(f, {.EX, .NB}) != .NONE {
		linux.close(f)
		return -1, false
	}
	pid := fmt.tprintf("%d\n", linux.getpid())
	_ = os.write_entire_file(fmt.tprintf("%s/daemon.pid", root), transmute([]u8)pid, os.perm_number(0o600))
	return f, true
}

// daemon_pid says whether a daemon is running, and which.
daemon_pid :: proc(root: string) -> (pid: int, running: bool) {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/daemon.pid", root), context.temp_allocator)
	if err != nil {
		return 0, false
	}
	n := 0
	for c in strings.trim_space(string(data)) {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	if n <= 0 {
		return 0, false
	}
	// The lock is the truth: a pid file can outlive its process.
	p := strings.clone_to_cstring(fmt.tprintf("%s/daemon.lock", root), context.temp_allocator)
	f, e := linux.open(p, {.RDWR, .CLOEXEC})
	if e != .NONE {
		return n, false
	}
	defer linux.close(f)
	if linux.flock(f, {.EX, .NB}) == .NONE {
		linux.flock(f, {.UN})
		return n, false
	}
	return n, true
}

// daemon_main is palm-indexd: take the per-person lock, lower priority,
// discover, and run until killed (or once through, with `once`).
// Exit codes follow docs/PALM-CLI.md: 6 when another daemon holds the lock.
daemon_main :: proc(scope: string, once, verbose: bool) -> int {
	paths := paths_default()
	lock, ok := daemon_lock(paths.index)
	if !ok {
		fmt.eprintln("palm-indexd: another indexer is running for this person")
		return 6
	}
	_ = lock
	lower_priority()
	d: Daemon
	d.once = once
	d.verbose = verbose
	if err := daemon_init(&d, paths, scope); err != "" {
		fmt.eprintfln("palm-indexd: %s", err)
		return 6
	}
	if verbose {
		fmt.eprintfln("palm-indexd: %d identities, index in %s", len(d.ids), paths.index)
	}
	daemon_run(&d)
	daemon_close(&d)
	return 0
}
