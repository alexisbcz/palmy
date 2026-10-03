// The NetworkManager side of the applet: everything that shells out to
// `nmcli`, parses its terse output, and hands the result to the UI thread.
//
// Two rules shape this file.
//
//  1. Only `nmcli -t -f <fields> ...` is ever run. The terse format is one
//     record per line with `:` between fields and `\:` for a literal colon, so
//     it parses deterministically. The human tables are never scraped.
//  2. Nothing blocking happens on the UI thread. A single worker thread drains
//     a job queue; results are published into `Store` under a mutex and the
//     frame loop reads them while it builds. A scan takes a couple of seconds
//     and the window stays live throughout.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import kit "kit:."

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

Dev_State :: enum {
	Unknown,
	Unmanaged,
	Unavailable,
	Disconnected,
	Connecting,
	Connected,
}

// Dev is one row of `nmcli device status`, enriched with the addressing from
// `nmcli device show`.
Dev :: struct {
	name:    string,
	kind:    string, // nmcli's own type word: wifi, ethernet, wireguard, ...
	state:   Dev_State,
	// NetworkManager says "connected (externally)" for a link something other
	// than NM brought up, such as a WireGuard tunnel.
	external: bool,
	conn:    string, // the connection profile the device is carrying
	hwaddr:  string,
	mtu:     string,
	speed:   string,
	ip4:     string,
	gw4:     string,
	dns:     string,
	ip6:     string,
	prefix:  string, // the /24 off the end of IP4.ADDRESS
}

// Ap is one entry of `nmcli device wifi list`, deduplicated by SSID.
Ap :: struct {
	ssid:     string,
	security: string,
	rate:     string,
	bssid:    string,
	band:     string,
	signal:   int,
	channel:  int,
	freq:     int,
	active:   bool,
	bssids:   int, // how many radios answered for this SSID
	hidden:   bool,
}

// Saved is one row of `nmcli connection show`.
Saved :: struct {
	name:        string,
	kind:        string, // prettified
	device:      string,
	uuid:        string,
	autoconnect: bool,
	active:      bool,
}

Msg_Kind :: enum {
	None,
	Info,
	Good,
	Bad,
}

Job_Kind :: enum {
	Refresh, // devices, details, saved profiles, radio state
	Wifi, // wifi list from the cache
	Rescan, // force a scan, then the list
	Radio_On,
	Radio_Off,
	Connect,
}

Job :: struct {
	kind: Job_Kind,
	ssid: string, // heap, owned by the worker once submitted
	pw:   string,
}

// Store is the shared state, under two locks that are never held together.
//
//	qmu  the job queue, the in-flight count and the label of the running job
//	mu   the parsed results the frame loop draws from
//
// They have to be separate: the frame loop holds `mu` for the whole frame it is
// building, and a keystroke handled inside that frame queues a job. One mutex
// for both would be a self-deadlock the moment a key asked for a rescan —
// `sync.Mutex` is not reentrant, and the window simply stops redrawing.
Store :: struct {
	qmu:      sync.Mutex,
	mu:       sync.Mutex,
	sem:      sync.Sema,
	queue:    [dynamic]Job,
	pending:  int, // jobs submitted but not finished
	busy:     string, // static label for the one running now
	devices:  [dynamic]Dev,
	aps:      [dynamic]Ap,
	saved:    [dynamic]Saved,
	radio_on: bool,
	loaded:   bool, // the first refresh has landed
	scanned:  bool, // at least one wifi list has landed
	message:  string, // heap
	msg_kind: Msg_Kind,
	scan_at:  string, // heap, wall clock of the last successful list
}

// progress reports what the worker is doing, without touching the data lock.
progress :: proc(s: ^Store) -> (busy: string, pending: int) {
	sync.mutex_lock(&s.qmu)
	busy, pending = s.busy, s.pending
	sync.mutex_unlock(&s.qmu)
	return
}

store_start :: proc(s: ^Store) {
	s.queue = make([dynamic]Job)
	s.devices = make([dynamic]Dev)
	s.aps = make([dynamic]Ap)
	s.saved = make([dynamic]Saved)
	t := thread.create(worker)
	t.data = s
	thread.start(t)
}

// submit queues a job. Safe from the frame loop: it never waits on nmcli.
submit :: proc(s: ^Store, kind: Job_Kind, ssid := "", pw := "") {
	j := Job {
		kind = kind,
		ssid = ssid == "" ? "" : strings.clone(ssid),
		pw   = pw == "" ? "" : strings.clone(pw),
	}
	sync.mutex_lock(&s.qmu)
	append(&s.queue, j)
	s.pending += 1
	sync.mutex_unlock(&s.qmu)
	sync.sema_post(&s.sem)
}

job_label :: proc(k: Job_Kind) -> string {
	switch k {
	case .Refresh:
		return "Reading interfaces"
	case .Wifi:
		return "Reading networks"
	case .Rescan:
		return "Scanning for networks"
	case .Radio_On:
		return "Enabling Wi-Fi"
	case .Radio_Off:
		return "Disabling Wi-Fi"
	case .Connect:
		return "Connecting"
	}
	return "Working"
}

// ---------------------------------------------------------------------------
// The worker thread
// ---------------------------------------------------------------------------

worker :: proc(t: ^thread.Thread) {
	s := (^Store)(t.data)

	// Odin's default temp allocator intermittently failed under this workload:
	// `kit.run` captures a child's output into `context.temp_allocator`, and
	// roughly half the time a command whose stdout was a reliable 975 bytes
	// came back empty, or with a non-nil allocator error. The same command run
	// against `context.allocator` never failed. Giving this thread an arena of
	// its own, reset between jobs, makes every capture reliable.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) == nil {
		context.temp_allocator = virtual.arena_allocator(&arena)
	}

	for {
		sync.sema_wait(&s.sem)

		sync.mutex_lock(&s.qmu)
		if len(s.queue) == 0 {
			sync.mutex_unlock(&s.qmu)
			continue
		}
		job := s.queue[0]
		ordered_remove(&s.queue, 0)
		s.busy = job_label(job.kind)
		sync.mutex_unlock(&s.qmu)

		switch job.kind {
		case .Refresh:
			do_refresh(s)
		case .Wifi:
			do_wifi(s, false)
		case .Rescan:
			do_wifi(s, true)
		case .Radio_On:
			do_radio(s, true)
		case .Radio_Off:
			do_radio(s, false)
		case .Connect:
			do_connect(s, job.ssid, job.pw)
		}

		if job.ssid != "" {delete(job.ssid)}
		if job.pw != "" {delete(job.pw)}
		free_all(context.temp_allocator)

		sync.mutex_lock(&s.qmu)
		s.busy = ""
		s.pending -= 1
		sync.mutex_unlock(&s.qmu)
	}
}

set_message :: proc(s: ^Store, kind: Msg_Kind, text: string) {
	msg := strings.clone(text)
	sync.mutex_lock(&s.mu)
	if s.message != "" {delete(s.message)}
	s.message = msg
	s.msg_kind = kind
	sync.mutex_unlock(&s.mu)
}

// dbg prints to stderr when NETWORK_DEBUG is set in the environment.
dbg :: proc(format: string, args: ..any) {
	@(static) checked: bool
	@(static) want: bool
	if !checked {
		checked = true
		want = os.get_env("NETWORK_DEBUG", context.allocator) != ""
	}
	if want {
		fmt.eprintf("[network] ")
		fmt.eprintfln(format, ..args)
	}
}

// nm_lines, nm_text and nm_do are the only three ways this app runs a command.
//
// They exist because an `os.process_exec` issued in the first second or so of
// this process's life occasionally comes back with *empty stdout and a zero
// exit status*, while the same command run a moment later returns its usual
// 975 bytes. It was reproduced with both the temp and the heap allocator and
// with a private arena for the worker, so it is not allocator related; the exit
// status is always correct, only the captured output is lost. Read-only
// queries therefore retry while the result is empty. Commands that change
// something run exactly once — their exit status is trustworthy and their
// output is only a message.
NM_TRIES :: 4

nm_lines :: proc(argv: []string) -> (lines: []string, ok: bool) {
	for attempt in 0 ..< NM_TRIES {
		free_all(context.temp_allocator)
		lines, ok = kit.run_lines(argv)
		if len(lines) > 0 {
			return
		}
		free_lines(lines)
		lines = nil
		if !ok {
			return nil, false // the command really failed
		}
		time.sleep(25 * time.Millisecond)
	}
	return nil, ok
}

nm_text :: proc(argv: []string) -> (out: string, ok: bool) {
	for attempt in 0 ..< NM_TRIES {
		free_all(context.temp_allocator)
		out, ok = kit.run(argv)
		if len(out) > 0 || !ok {
			return
		}
		nm_free(out)
		time.sleep(25 * time.Millisecond)
	}
	return "", ok
}

// nm_do runs a command for its effect and throws the output away.
nm_do :: proc(argv: []string) -> bool {
	free_all(context.temp_allocator)
	out, ok := kit.run(argv)
	nm_free(out)
	return ok
}

// nm_free is `delete` that tolerates kit.run's "" on a failed spawn, which is
// a literal rather than an allocation.
nm_free :: proc(s: string) {
	if len(s) > 0 {
		delete(s)
	}
}

free_lines :: proc(lines: []string) {
	for l in lines {
		delete(l)
	}
	delete(lines)
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

// The field list for `device show`, as one named constant. An inline `"a" +
// "b"` inside the argv composite literal below does not survive into the
// executed command, so it is spelled out here.
AP_FIELDS :: "ACTIVE,SSID,SIGNAL,SECURITY,RATE,CHAN,BSSID,FREQ"

DEVICE_FIELDS :: "GENERAL.DEVICE,GENERAL.HWADDR,GENERAL.MTU,CAPABILITIES.SPEED,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS"

do_refresh :: proc(s: ^Store) {
	devs := make([dynamic]Dev)

	// `device status` gives the canonical list, in NetworkManager's own order.
	status, _ := nm_lines({"nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"})
	defer free_lines(status)
	for line in status {
		f := split_terse(line, context.temp_allocator)
		if len(f) < 3 || f[0] == "" {
			continue
		}
		append(
			&devs,
			Dev {
				name = strings.clone(f[0]),
				kind = strings.clone(f[1]),
				state = parse_state(f[2]),
				external = strings.contains(f[2], "externally"),
				conn = len(f) > 3 ? strings.clone(f[3]) : "",
			},
		)
	}

	// `device show` with no argument prints every device as a blank-line
	// separated block of `FIELD:value`. Addresses are merged in by name.
	detail, _ := nm_lines({"nmcli", "-t", "-f", DEVICE_FIELDS, "device", "show"})
	defer free_lines(detail)
	cur := -1
	dns := make([dynamic]string, context.temp_allocator)
	flush_dns :: proc(devs: ^[dynamic]Dev, cur: int, dns: ^[dynamic]string) {
		if cur >= 0 && len(dns) > 0 {
			devs[cur].dns = strings.join(dns[:], ", ")
		}
		clear(dns)
	}
	for line in detail {
		key, val := split_once(line)
		switch {
		case key == "GENERAL.DEVICE":
			flush_dns(&devs, cur, &dns)
			cur = -1
			for &d, i in devs {
				if d.name == val {
					cur = i
					break
				}
			}
		case cur < 0:
		// a device `device status` did not list; ignore it
		case key == "GENERAL.HWADDR":
			devs[cur].hwaddr = strings.clone(val)
		case key == "GENERAL.MTU":
			// NetworkManager reports 0 for devices that have no link.
			devs[cur].mtu = val == "0" ? "" : strings.clone(val)
		case key == "CAPABILITIES.SPEED":
			devs[cur].speed = val == "unknown" ? "" : strings.clone(val)
		case key == "IP4.GATEWAY":
			devs[cur].gw4 = strings.clone(val)
		case strings.has_prefix(key, "IP4.ADDRESS"):
			if devs[cur].ip4 == "" {
				addr, pfx := split_slash(val)
				devs[cur].ip4 = strings.clone(addr)
				devs[cur].prefix = strings.clone(pfx)
			}
		case strings.has_prefix(key, "IP6.ADDRESS"):
			// Skip link-local: it is never the interesting one.
			if devs[cur].ip6 == "" && !strings.has_prefix(val, "fe80:") {
				addr, _ := split_slash(val)
				devs[cur].ip6 = strings.clone(addr)
			}
		case strings.has_prefix(key, "IP4.DNS"):
			if val != "" {
				append(&dns, val)
			}
		}
	}
	flush_dns(&devs, cur, &dns)

	// Saved profiles.
	saved := make([dynamic]Saved)
	profiles, _ := nm_lines({"nmcli", "-t", "-f", "NAME,TYPE,DEVICE,UUID,AUTOCONNECT", "connection", "show"})
	defer free_lines(profiles)
	for line in profiles {
		f := split_terse(line, context.temp_allocator)
		if len(f) < 2 || f[0] == "" {
			continue
		}
		dev := len(f) > 2 ? f[2] : ""
		append(
			&saved,
			Saved {
				name = strings.clone(f[0]),
				kind = pretty_type(f[1]),
				device = strings.clone(dev),
				uuid = len(f) > 3 ? strings.clone(f[3]) : "",
				autoconnect = len(f) > 4 && f[4] == "yes",
				active = dev != "",
			},
		)
	}

	radio, _ := nm_text({"nmcli", "radio", "wifi"})
	defer nm_free(radio)
	on := strings.trim_space(radio) == "enabled"

	dbg("refresh: %d devices, %d profiles, radio=%v", len(devs), len(saved), on)
	sync.mutex_lock(&s.mu)
	free_devices(&s.devices)
	free_saved(&s.saved)
	s.devices = devs
	s.saved = saved
	s.radio_on = on
	s.loaded = true
	sync.mutex_unlock(&s.mu)
}

do_wifi :: proc(s: ^Store, rescan: bool) {
	if rescan {
		// `device wifi rescan` kicks the scan off; `--rescan yes` below is what
		// waits for the fresh results. nmcli exits non-zero when a scan ran
		// moments ago, which is harmless.
		nm_do({"nmcli", "device", "wifi", "rescan"})
	}

	lines, ok := wifi_list(rescan)
	if !ok || len(lines) == 0 {
		// `--rescan yes` is refused when a scan ran moments ago; fall back to
		// whatever is already in NetworkManager's cache rather than blanking
		// the list.
		free_lines(lines)
		lines, ok = wifi_list(false)
	}
	defer free_lines(lines)

	aps := make([dynamic]Ap)
	for line in lines {
		f := split_terse(line, context.temp_allocator)
		if len(f) < 8 {
			continue
		}
		ssid := f[1]
		hidden := ssid == "" || ssid == "--"
		ap := Ap {
			ssid     = hidden ? "Hidden network" : strings.clone(ssid),
			security = strings.clone(f[3] == "" ? "Open" : f[3]),
			rate     = strings.clone(f[4]),
			bssid    = strings.clone(f[6]),
			signal   = atoi(f[2]),
			channel  = atoi(f[5]),
			freq     = atoi(f[7]),
			active   = f[0] == "yes",
			bssids   = 1,
			hidden   = hidden,
		}
		ap.band = band_of(ap.freq)

		// Several radios broadcast the same SSID; keep the strongest and count
		// the rest, which is what every desktop network list does.
		merged := false
		if !hidden {
			for &e in aps {
				if e.ssid != ap.ssid || e.hidden {
					continue
				}
				e.bssids += 1
				if ap.active {
					e.active = true
				}
				if ap.signal > e.signal {
					// The stronger radio wins the details.
					delete(e.security);delete(e.rate);delete(e.bssid)
					keep_ssid := e.ssid
					count := e.bssids
					was_active := e.active
					delete(ap.ssid)
					e = ap
					e.ssid = keep_ssid
					e.bssids = count
					e.active = was_active
				} else {
					delete(ap.ssid);delete(ap.security);delete(ap.rate);delete(ap.bssid)
				}
				merged = true
				break
			}
		}
		if !merged {
			append(&aps, ap)
		}
	}

	// Strongest first, which is what the panel claims and what a user scans by.
	slice.sort_by(aps[:], proc(a, b: Ap) -> bool {
		if a.signal != b.signal {
			return a.signal > b.signal
		}
		return a.ssid < b.ssid
	})

	now := time.now()
	hh, mm, ss := time.clock_from_time(now)
	stamp := fmt.aprintf("%02d:%02d:%02d", hh, mm, ss)

	dbg("wifi: %d networks (rescan=%v)", len(aps), rescan)
	sync.mutex_lock(&s.mu)
	free_aps(&s.aps)
	s.aps = aps
	s.scanned = true
	if s.scan_at != "" {delete(s.scan_at)}
	s.scan_at = stamp
	sync.mutex_unlock(&s.mu)

	if !ok {
		set_message(s, .Bad, "nmcli could not list networks — is the radio on?")
	} else if rescan {
		set_message(s, .Good, fmt.tprintf("Scan complete — %d networks in range", len(aps)))
	}
}

wifi_list :: proc(rescan: bool) -> ([]string, bool) {
	return nm_lines(
		{"nmcli", "-t", "-f", AP_FIELDS, "device", "wifi", "list", "--rescan", rescan ? "yes" : "no"},
	)
}

do_radio :: proc(s: ^Store, on: bool) {
	ok := nm_do({"nmcli", "radio", "wifi", on ? "on" : "off"})
	if !ok {
		set_message(s, .Bad, "nmcli refused to change the radio state")
	} else {
		set_message(s, .Info, on ? "Wi-Fi radio enabled" : "Wi-Fi radio disabled")
	}
	// Read the state back rather than assuming the write took.
	back, _ := nm_text({"nmcli", "radio", "wifi"})
	defer nm_free(back)
	real_on := strings.trim_space(back) == "enabled"
	sync.mutex_lock(&s.mu)
	s.radio_on = real_on
	sync.mutex_unlock(&s.mu)

	do_refresh(s)
	if real_on {
		do_wifi(s, false)
	} else {
		sync.mutex_lock(&s.mu)
		free_aps(&s.aps)
		s.aps = make([dynamic]Ap)
		sync.mutex_unlock(&s.mu)
	}
}

do_connect :: proc(s: ^Store, ssid, pw: string) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "nmcli", "device", "wifi", "connect", ssid)
	if pw != "" {
		append(&argv, "password", pw)
	}
	out, ok := nm_text(argv[:])
	defer nm_free(out)
	if ok {
		set_message(s, .Good, fmt.tprintf("Connected to %s", ssid))
	} else {
		text := strings.trim_space(out)
		if text == "" {
			text = "connection failed"
		}
		set_message(s, .Bad, text)
	}
	do_refresh(s)
	do_wifi(s, false)
}

// ---------------------------------------------------------------------------
// Parsing the terse format
// ---------------------------------------------------------------------------

// split_terse splits one `nmcli -t` record. Fields are separated by `:` and a
// literal colon inside a value is escaped as `\:`, which is how a BSSID like
// `50\:39\:2F\:37\:86\:30` survives being one field.
split_terse :: proc(line: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(line) {
		c := line[i]
		if c == '\\' && i + 1 < len(line) {
			strings.write_byte(&b, line[i + 1])
			i += 2
			continue
		}
		if c == ':' {
			append(&out, strings.clone(strings.to_string(b), allocator))
			strings.builder_reset(&b)
			i += 1
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	append(&out, strings.clone(strings.to_string(b), allocator))
	return out[:]
}

// split_once is for `nmcli device show`, whose keys never contain a colon but
// whose values (a MAC address) are not escaped.
split_once :: proc(line: string) -> (key, val: string) {
	if i := strings.index_byte(line, ':'); i >= 0 {
		return line[:i], strings.trim_space(line[i + 1:])
	}
	return line, ""
}

split_slash :: proc(s: string) -> (addr, prefix: string) {
	if i := strings.index_byte(s, '/'); i >= 0 {
		return s[:i], s[i:]
	}
	return s, ""
}

atoi :: proc(s: string) -> int {
	n, _ := strconv.parse_int(strings.trim_space(s), 10)
	return n
}

// `nmcli device status` reports e.g. "connected", "connected (externally)",
// "connecting (getting IP configuration)", "unavailable".
parse_state :: proc(s: string) -> Dev_State {
	switch {
	case strings.has_prefix(s, "connected"):
		return .Connected
	case strings.has_prefix(s, "connecting"):
		return .Connecting
	case strings.has_prefix(s, "disconnect"):
		return .Disconnected
	case strings.has_prefix(s, "unavailable"):
		return .Unavailable
	case strings.has_prefix(s, "unmanaged"):
		return .Unmanaged
	}
	return .Unknown
}

pretty_type :: proc(t: string) -> string {
	switch t {
	case "802-11-wireless":
		return strings.clone("Wi-Fi")
	case "802-3-ethernet":
		return strings.clone("Ethernet")
	case "wireguard":
		return strings.clone("WireGuard")
	case "loopback":
		return strings.clone("Loopback")
	case "vpn":
		return strings.clone("VPN")
	case "bridge":
		return strings.clone("Bridge")
	case "tun":
		return strings.clone("Tunnel")
	}
	return strings.clone(t)
}

band_of :: proc(mhz: int) -> string {
	switch {
	case mhz >= 5925:
		return "6 GHz"
	case mhz >= 4900:
		return "5 GHz"
	case mhz >= 2400:
		return "2.4 GHz"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Freeing
// ---------------------------------------------------------------------------

free_devices :: proc(list: ^[dynamic]Dev) {
	for d in list {
		for str in ([?]string {
			d.name,
			d.kind,
			d.conn,
			d.hwaddr,
			d.mtu,
			d.speed,
			d.ip4,
			d.gw4,
			d.dns,
			d.ip6,
			d.prefix,
		}) {
			if str != "" {delete(str)}
		}
	}
	delete(list^)
}

free_aps :: proc(list: ^[dynamic]Ap) {
	for a in list {
		for str in ([?]string{a.ssid, a.security, a.rate, a.bssid} ){
			if str != "" {delete(str)}
		}
	}
	delete(list^)
}

free_saved :: proc(list: ^[dynamic]Saved) {
	for v in list {
		for str in ([?]string{v.name, v.kind, v.device, v.uuid}) {
			if str != "" {delete(str)}
		}
	}
	delete(list^)
}
