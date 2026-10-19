package main

// Reading the machine. Every reader here is read-only and forgiving: a file
// that is missing or a tool that is not installed gives an empty answer and
// the page says so, never a crash and never a guess. The parsers take text,
// so the self-test feeds them fixtures.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import kit "kit:."

which :: proc(prog: string) -> bool {
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if dir != "" && os.exists(fmt.tprintf("%s/%s", dir, prog)) {
			return true
		}
	}
	return false
}

run_text :: proc(argv: []string) -> (string, bool) {
	if len(argv) == 0 || !which(argv[0]) {
		return "", false
	}
	return kit.run(argv, context.temp_allocator)
}

file_line :: proc(path: string) -> string {
	t, ok := read_text(path)
	if !ok {
		return ""
	}
	return strings.trim_space(t)
}

// ---------------------------------------------------------------------------
// Displays: what the wm drives ($XDG_RUNTIME_DIR/palmy-wm.json), and what
// the kernel sees (/sys/class/drm), for a session that is not under the wm.
// ---------------------------------------------------------------------------

Display :: struct {
	name, desc, make_, model: string,
	x, y, w, h:              int,
	mode_w, mode_h:          int,
	refresh_mhz:             int,
	scale:                   int,
	mm_w, mm_h:              int,
	connected:               bool,
	modes:                   []string, // from sysfs, "1920x1080"
}

Wm_State :: struct {
	ok:       bool,
	bare:     bool,
	config:   string,
	kbd_layout, kbd_rmlvo, kbd_from, kbd_file: string,
	kbd_fell_back: bool,
	displays: []Display,
}

wm_state_path :: proc() -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	return rt == "" ? "" : fmt.tprintf("%s/palmy-wm.json", rt)
}

parse_wm_state :: proc(text: string, allocator := context.allocator) -> Wm_State {
	Out :: struct {
		name, description, make, model: string,
		x, y, width, height, mode_width, mode_height, refresh_mhz, scale: int,
		physical_mm: [2]int,
	}
	Kbd :: struct {
		layout, rmlvo, from, file: string,
		fell_back: bool,
	}
	Doc :: struct {
		bare:     bool,
		config:   string,
		keyboard: Kbd,
		outputs:  []Out,
	}
	doc: Doc
	if json.unmarshal(transmute([]u8)text, &doc, allocator = allocator) != nil {
		return {}
	}
	st := Wm_State {
		ok            = true,
		bare          = doc.bare,
		config        = doc.config,
		kbd_layout    = doc.keyboard.layout,
		kbd_rmlvo     = doc.keyboard.rmlvo,
		kbd_from      = doc.keyboard.from,
		kbd_file      = doc.keyboard.file,
		kbd_fell_back = doc.keyboard.fell_back,
	}
	ds := make([]Display, len(doc.outputs), allocator)
	for o, i in doc.outputs {
		ds[i] = Display {
			name        = o.name,
			desc        = o.description,
			make_       = o.make,
			model       = o.model,
			x           = o.x,
			y           = o.y,
			w           = o.width,
			h           = o.height,
			mode_w      = o.mode_width > 0 ? o.mode_width : o.width,
			mode_h      = o.mode_height > 0 ? o.mode_height : o.height,
			refresh_mhz = o.refresh_mhz,
			scale       = max(o.scale, 1),
			mm_w        = o.physical_mm[0],
			mm_h        = o.physical_mm[1],
			connected   = true,
		}
	}
	st.displays = ds
	return st
}

read_wm_state :: proc(allocator := context.allocator) -> Wm_State {
	path := wm_state_path()
	if path == "" {
		return {}
	}
	text, ok := read_text(path)
	if !ok {
		return {}
	}
	return parse_wm_state(text, allocator)
}

// sysfs_modes lists the modes the kernel offers a connector, for each
// connected one: /sys/class/drm/card0-HDMI-A-1/{status,modes}.
sysfs_displays :: proc(allocator := context.allocator) -> []Display {
	out := make([dynamic]Display, allocator)
	infos, err := os.read_directory_by_path("/sys/class/drm", -1, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		dash := strings.index_byte(fi.name, '-')
		if !strings.has_prefix(fi.name, "card") || dash < 0 {
			continue
		}
		status := file_line(fmt.tprintf("/sys/class/drm/%s/status", fi.name))
		if status != "connected" {
			continue
		}
		d := Display{name = strings.clone(fi.name[dash + 1:], allocator), connected = true, scale = 1}
		modes := make([dynamic]string, allocator)
		if m, ok := read_text(fmt.tprintf("/sys/class/drm/%s/modes", fi.name)); ok {
			rest := m
			for line in strings.split_lines_iterator(&rest) {
				l := strings.trim_space(line)
				if l == "" || slice.contains(modes[:], l) {
					continue
				}
				append(&modes, strings.clone(l, allocator))
			}
		}
		d.modes = modes[:]
		if len(modes) > 0 {
			if x := strings.index_byte(modes[0], 'x'); x > 0 {
				d.mode_w, _ = strconv.parse_int(modes[0][:x])
				d.mode_h, _ = strconv.parse_int(strings.trim_right(modes[0][x + 1:], "i"))
				d.w, d.h = d.mode_w, d.mode_h
			}
		}
		append(&out, d)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Keyboard layouts: the "! layout" section of the XKB rules' .lst file.
// ---------------------------------------------------------------------------

Layout :: struct {
	code, name: string,
}

XKB_LST :: "/usr/share/X11/xkb/rules/evdev.lst"

parse_layouts :: proc(text: string, allocator := context.allocator) -> []Layout {
	out := make([dynamic]Layout, allocator)
	in_layouts := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "!") {
			in_layouts = strings.trim_space(line[1:]) == "layout"
			continue
		}
		if !in_layouts {
			continue
		}
		t := strings.trim_space(line)
		sp := strings.index_any(t, " \t")
		if sp <= 0 {
			continue
		}
		append(&out, Layout{strings.clone(t[:sp], allocator), strings.clone(strings.trim_space(t[sp:]), allocator)})
	}
	slice.sort_by(out[:], proc(a, b: Layout) -> bool {return a.name < b.name})
	return out[:]
}

read_layouts :: proc(allocator := context.allocator) -> []Layout {
	text, ok := read_text(XKB_LST)
	if !ok {
		// Without the XKB data the wm types with its built-in US map; say
		// so rather than offering layouts it cannot compile.
		out := make([]Layout, 1, allocator)
		out[0] = {"us", "English (US)"}
		return out
	}
	return parse_layouts(text, allocator)
}

// ---------------------------------------------------------------------------
// Sound: WirePlumber's wpctl, when PipeWire is running.
// ---------------------------------------------------------------------------

Sink :: struct {
	id:      int,
	name:    string,
	def:     bool,
	volume:  f32,
}

Sound :: struct {
	available: bool, // wpctl is installed
	running:   bool, // and it answered
	sinks:     []Sink,
	sources:   []Sink,
	volume:    f32,
	muted:     bool,
	mic_volume: f32,
	mic_muted: bool,
}

// parse_wpctl_status reads the Audio part of `wpctl status`:
//
//	Audio
//	 ├─ Devices: ...
//	 ├─ Sinks:
//	 │  *   46. Built-in Audio Analog Stereo        [vol: 0.40]
//	 ├─ Sources:
//	 │      47. Built-in Audio Analog Stereo        [vol: 1.00]
parse_wpctl_status :: proc(text: string, allocator := context.allocator) -> (sinks, sources: []Sink) {
	ks := make([dynamic]Sink, allocator)
	kr := make([dynamic]Sink, allocator)
	section := ""
	in_audio := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "Audio" {
			in_audio = true
			continue
		}
		if t == "Video" || t == "Settings" {
			in_audio = false
		}
		if !in_audio {
			continue
		}
		// Strip the tree drawing.
		u := strings.trim_left(t, "│├└─ ")
		if strings.has_suffix(u, ":") {
			section = u
			continue
		}
		if section != "Sinks:" && section != "Sources:" {
			continue
		}
		def := false
		if strings.has_prefix(u, "*") {
			def = true
			u = strings.trim_space(u[1:])
		}
		dot := strings.index_byte(u, '.')
		if dot <= 0 {
			continue
		}
		id, ok := strconv.parse_int(strings.trim_space(u[:dot]))
		if !ok {
			continue
		}
		name := strings.trim_space(u[dot + 1:])
		vol := f32(-1)
		if b := strings.index(name, "[vol:"); b >= 0 {
			vs := strings.trim_space(name[b + 5:])
			if e := strings.index_any(vs, " ]"); e > 0 {
				vs = vs[:e]
			}
			if v, vok := strconv.parse_f32(vs); vok {
				vol = v
			}
			name = strings.trim_space(name[:b])
		}
		s := Sink{id = id, name = strings.clone(name, allocator), def = def, volume = vol}
		if section == "Sinks:" {
			append(&ks, s)
		} else {
			append(&kr, s)
		}
	}
	return ks[:], kr[:]
}

// parse_wpctl_volume reads `wpctl get-volume`: "Volume: 0.40 [MUTED]".
parse_wpctl_volume :: proc(text: string) -> (vol: f32, muted: bool, ok: bool) {
	t := strings.trim_space(text)
	if !strings.has_prefix(t, "Volume:") {
		return
	}
	rest := strings.trim_space(t[len("Volume:"):])
	num := rest
	if sp := strings.index_byte(rest, ' '); sp > 0 {
		num = rest[:sp]
	}
	vol, ok = strconv.parse_f32(num)
	muted = strings.contains(rest, "MUTED")
	return
}

read_sound :: proc(allocator := context.allocator) -> Sound {
	s := Sound{available = which("wpctl")}
	if !s.available {
		return s
	}
	text, ok := run_text({"wpctl", "status"})
	if !ok {
		return s
	}
	s.running = true
	s.sinks, s.sources = parse_wpctl_status(text, allocator)
	if v, ok2 := run_text({"wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"}); ok2 {
		s.volume, s.muted, _ = parse_wpctl_volume(v)
	}
	if v, ok2 := run_text({"wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"}); ok2 {
		s.mic_volume, s.mic_muted, _ = parse_wpctl_volume(v)
	}
	return s
}

// ---------------------------------------------------------------------------
// Network: the interfaces, their addresses, and Wi-Fi from iwd.
// ---------------------------------------------------------------------------

Iface :: struct {
	name:     string,
	kind:     string, // "Ethernet", "Wi-Fi", "Loopback", ...
	state:    string, // operstate: up, down, dormant, unknown
	mac:      string,
	addrs:    []string,
	ssid:     string,
}

// parse_ip_addr reads `ip -o addr` lines: "2: eth0    inet 10.0.2.15/24 brd ...".
parse_ip_addr :: proc(text: string, name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 4 || strings.trim_right(f[1], ":") != name {
			continue
		}
		for w, i in f {
			if (w == "inet" || w == "inet6") && i + 1 < len(f) {
				if w == "inet6" && strings.has_prefix(f[i + 1], "fe80") {
					continue // link-local: true of every interface, says nothing
				}
				append(&out, strings.clone(f[i + 1], allocator))
			}
		}
	}
	return out[:]
}

read_ifaces :: proc(allocator := context.allocator) -> []Iface {
	out := make([dynamic]Iface, allocator)
	infos, err := os.read_directory_by_path("/sys/class/net", -1, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	addr_text, _ := run_text({"ip", "-o", "addr"})
	for fi in infos {
		if fi.name == "lo" {
			continue
		}
		base := fmt.tprintf("/sys/class/net/%s", fi.name)
		ifc := Iface {
			name  = strings.clone(fi.name, allocator),
			state = strings.clone(file_line(fmt.tprintf("%s/operstate", base)), allocator),
			mac   = strings.clone(file_line(fmt.tprintf("%s/address", base)), allocator),
		}
		switch {
		case os.exists(fmt.tprintf("%s/wireless", base)) || os.exists(fmt.tprintf("%s/phy80211", base)):
			ifc.kind = "Wi-Fi"
		case os.exists(fmt.tprintf("%s/device", base)):
			ifc.kind = "Ethernet"
		case:
			ifc.kind = "Virtual"
		}
		ifc.addrs = parse_ip_addr(addr_text, fi.name, allocator)
		if ifc.kind == "Wi-Fi" {
			if t, ok := run_text({"iwctl", "station", fi.name, "show"}); ok {
				rest := t
				for line in strings.split_lines_iterator(&rest) {
					l := strings.trim_space(line)
					if strings.has_prefix(l, "Connected network") {
						ifc.ssid = strings.clone(strings.trim_space(l[len("Connected network"):]), allocator)
					}
				}
			}
		}
		append(&out, ifc)
	}
	slice.sort_by(out[:], proc(a, b: Iface) -> bool {return a.name < b.name})
	return out[:]
}

// ---------------------------------------------------------------------------
// Time zones
// ---------------------------------------------------------------------------

ZONEINFO :: "/usr/share/zoneinfo"

parse_zone_tab :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "#") {
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) >= 3 && strings.contains(f[2], "/") {
			append(&out, strings.clone(f[2], allocator))
		}
	}
	append(&out, strings.clone("UTC", allocator))
	slice.sort(out[:])
	return out[:]
}

read_zones :: proc(allocator := context.allocator) -> []string {
	text, ok := read_text(ZONEINFO + "/zone1970.tab")
	if !ok {
		text, ok = read_text(ZONEINFO + "/zone.tab")
	}
	if !ok {
		return {}
	}
	return parse_zone_tab(text, allocator)
}

// system_zone is what /etc/localtime points at.
system_zone :: proc() -> string {
	buf: [512]u8
	n, err := linux.readlink("/etc/localtime", buf[:])
	if err != .NONE || n <= 0 {
		return "UTC"
	}
	t := string(buf[:n])
	if i := strings.index(t, "zoneinfo/"); i >= 0 {
		return strings.clone(t[i + len("zoneinfo/"):], context.temp_allocator)
	}
	return strings.clone(t, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

User :: struct {
	name, gecos, home, shell: string,
	uid, gid:                 int,
	groups:                   []string,
}

parse_passwd :: proc(passwd, group: string, allocator := context.allocator) -> []User {
	out := make([dynamic]User, allocator)
	rest := passwd
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, ":", context.temp_allocator)
		if len(f) < 7 {
			continue
		}
		uid, _ := strconv.parse_int(f[2])
		gid, _ := strconv.parse_int(f[3])
		if uid < 1000 || uid >= 60000 {
			continue
		}
		u := User {
			name  = strings.clone(f[0], allocator),
			gecos = strings.clone(strings.split(f[4], ",", context.temp_allocator)[0], allocator),
			home  = strings.clone(f[5], allocator),
			shell = strings.clone(f[6], allocator),
			uid   = uid,
			gid   = gid,
		}
		gs := make([dynamic]string, allocator)
		grest := group
		for gl in strings.split_lines_iterator(&grest) {
			g := strings.split(gl, ":", context.temp_allocator)
			if len(g) < 4 {
				continue
			}
			ggid, _ := strconv.parse_int(g[2])
			member := ggid == gid
			for m in strings.split(g[3], ",", context.temp_allocator) {
				if m == u.name {
					member = true
				}
			}
			if member {
				append(&gs, strings.clone(g[0], allocator))
			}
		}
		u.groups = gs[:]
		append(&out, u)
	}
	return out[:]
}

read_users :: proc(allocator := context.allocator) -> []User {
	pw, _ := read_text("/etc/passwd")
	gr, _ := read_text("/etc/group")
	return parse_passwd(pw, gr, allocator)
}

// ---------------------------------------------------------------------------
// Software: palm
// ---------------------------------------------------------------------------

Updates :: struct {
	available:  bool, // palm is installed
	installed:  int,
	upgradable: []string, // "name 0.1.0-r0 → 0.1.1-r0"
	system_ver: string, // the palmy package's version
	palm_ver:   string,
	checked:    i64, // unix seconds of the newest cached index, 0 unknown
}

// parse_palm_list reads `palm list` text: "name-1.2.3-r0 [installed]",
// "name-1.2.4-r0 [upgradable from: 1.2.3-r0]".
parse_palm_line :: proc(line: string) -> (name, ver, from: string, ok: bool) {
	t := strings.trim_space(line)
	sp := strings.index_byte(t, ' ')
	head := sp > 0 ? t[:sp] : t
	// The version starts at the first "-" followed by a digit.
	for i in 0 ..< len(head) - 1 {
		if head[i] == '-' && head[i + 1] >= '0' && head[i + 1] <= '9' {
			name, ver = head[:i], head[i + 1:]
			ok = true
			break
		}
	}
	if k := strings.index(t, "upgradable from: "); k >= 0 {
		from = strings.trim_right(t[k + len("upgradable from: "):], "]")
	}
	return
}

read_updates :: proc(allocator := context.allocator) -> Updates {
	u := Updates{available = which("palm")}
	if !u.available {
		return u
	}
	if v, ok := run_text({"palm", "version"}); ok {
		u.palm_ver = strings.clone(v, allocator)
	}
	if t, ok := run_text({"palm", "list", "--installed"}); ok {
		rest := t
		for line in strings.split_lines_iterator(&rest) {
			if name, ver, _, lok := parse_palm_line(line); lok {
				u.installed += 1
				if name == "palmy" {
					u.system_ver = strings.clone(ver, allocator)
				}
			}
		}
	}
	up := make([dynamic]string, allocator)
	if t, ok := run_text({"palm", "list", "--upgradable"}); ok {
		rest := t
		for line in strings.split_lines_iterator(&rest) {
			if name, ver, from, lok := parse_palm_line(line); lok {
				append(&up, fmt.aprintf("%s %s → %s", name, from, ver, allocator = allocator))
			}
		}
	}
	u.upgradable = up[:]
	if infos, err := os.read_directory_by_path("/var/cache/palm", -1, context.temp_allocator); err == nil {
		for fi in infos {
			t := time.to_unix_seconds(fi.modification_time)
			if t > u.checked {
				u.checked = t
			}
		}
	}
	return u
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

About :: struct {
	os_name, os_version: string,
	hostname:            string,
	kernel:              string,
	cpu:                 string,
	cores:               int,
	mem_total_kb:        int,
	disk_total, disk_free: u64,
	gpu:                 string,
	uptime_s:            int,
}

parse_os_release :: proc(text: string) -> (name, version: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq <= 0 {
			continue
		}
		v := strings.trim(line[eq + 1:], "\"")
		switch line[:eq] {
		case "NAME":
			if name == "" {name = v}
		case "PRETTY_NAME":
			name = v
		case "VERSION", "VERSION_ID":
			if version == "" {version = v}
		}
	}
	return
}

parse_cpuinfo :: proc(text: string) -> (model: string, cores: int) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "processor") {
			cores += 1
		}
		if model == "" && strings.has_prefix(line, "model name") {
			if c := strings.index_byte(line, ':'); c > 0 {
				model = strings.trim_space(line[c + 1:])
			}
		}
	}
	return
}

parse_meminfo_total :: proc(text: string) -> int {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "MemTotal:") {
			f := strings.fields(line, context.temp_allocator)
			if len(f) >= 2 {
				n, _ := strconv.parse_int(f[1])
				return n
			}
		}
	}
	return 0
}

read_about :: proc(allocator := context.allocator) -> About {
	a: About
	if t, ok := read_text("/etc/os-release"); ok {
		n, v := parse_os_release(t)
		a.os_name, a.os_version = strings.clone(n, allocator), strings.clone(v, allocator)
	}
	if a.os_name == "" {
		a.os_name = "Palmy"
	}
	a.hostname = strings.clone(file_line("/proc/sys/kernel/hostname"), allocator)
	a.kernel = strings.clone(file_line("/proc/sys/kernel/osrelease"), allocator)
	if t, ok := read_text("/proc/cpuinfo"); ok {
		m, c := parse_cpuinfo(t)
		a.cpu, a.cores = strings.clone(m, allocator), c
	}
	if t, ok := read_text("/proc/meminfo"); ok {
		a.mem_total_kb = parse_meminfo_total(t)
	}
	if t, ok := read_text("/proc/uptime"); ok {
		f := strings.fields(t, context.temp_allocator)
		if len(f) > 0 {
			v, _ := strconv.parse_f64(f[0])
			a.uptime_s = int(v)
		}
	}
	sf: linux.Stat_FS
	if linux.statfs("/", &sf) == .NONE {
		a.disk_total = u64(sf.blocks) * u64(sf.bsize)
		a.disk_free = u64(sf.bavail) * u64(sf.bsize)
	}
	// The GPU, by its kernel driver: /sys/class/drm/card0/device/driver.
	buf: [256]u8
	if n, err := linux.readlink("/sys/class/drm/card0/device/driver", buf[:]); err == .NONE && n > 0 {
		d := string(buf[:n])
		if sl := strings.last_index_byte(d, '/'); sl >= 0 {
			d = d[sl + 1:]
		}
		a.gpu = strings.clone(d, allocator)
	}
	return a
}

human_bytes :: proc(n: u64) -> string {
	units := [?]string{"B", "KB", "MB", "GB", "TB"}
	v := f64(n)
	u := 0
	for v >= 1000 && u < len(units) - 1 {
		v /= 1000
		u += 1
	}
	return u == 0 ? fmt.tprintf("%d B", n) : fmt.tprintf("%.1f %s", v, units[u])
}
