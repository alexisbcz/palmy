// The iwd side of the applet: Palmy ships iwd, not NetworkManager
// (distro/notes/runtime.md), and iwd is reached over the system bus with the
// D-Bus client in kit:dbus. Wired and every other interface come from the
// kernel: /sys/class/net, /proc/net/route, `ip -o addr` and /etc/resolv.conf.
//
// The same rule as nm.odin, unchanged: everything here reads, except a scan
// (Station.Scan) and turning a radio ON (Device.Powered = true), which can
// only add connectivity. Turning a radio off and joining a network would
// drop the connection this machine is using, so they stay logged intents
// (nm_intent_only), never calls. iwd's bus policy lets root, wheel and netdev
// talk to it; anyone else sees "iwd is not reachable".
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "kit:dbus"
import kit "kit:."

Backend :: enum {
	Iwd, // the default: what Palmy ships
	Nm, // NetworkManager through nmcli, when iwd is not on the bus and nmcli exists
}

IWD :: "net.connman.iwd"
IWD_DEVICE :: "net.connman.iwd.Device"
IWD_STATION :: "net.connman.iwd.Station"
IWD_NETWORK :: "net.connman.iwd.Network"
IWD_KNOWN :: "net.connman.iwd.KnownNetwork"
IWD_DIAG :: "net.connman.iwd.StationDiagnostic"

// The worker's own connection, opened on first use and again after the bus
// or iwd went away.
@(private = "file")
iwd_bus: ^dbus.Dbus_Conn

// pick_backend: iwd when it owns its name on the system bus, else nmcli
// when it is installed, else iwd anyway, so the window says iwd is missing.
pick_backend :: proc() -> Backend {
	if os.get_env("NETWORK_BACKEND", context.temp_allocator) == "nm" {
		return .Nm
	}
	if iwd_running() {
		return .Iwd
	}
	for dir in ([]string{"/usr/bin", "/bin", "/usr/local/bin"}) {
		if os.exists(fmt.tprintf("%s/nmcli", dir)) {
			return .Nm
		}
	}
	return .Iwd
}

backend_name :: proc(b: Backend) -> string {
	return b == .Iwd ? "iwd" : "NetworkManager"
}

@(private = "file")
iwd_conn :: proc() -> ^dbus.Dbus_Conn {
	if iwd_bus != nil && !dbus.dbus_alive(iwd_bus) {
		dbus.dbus_close(iwd_bus)
		iwd_bus = nil
	}
	if iwd_bus == nil {
		c, e := dbus.dbus_connect()
		if e != .None {
			dbg("iwd: no system bus: %v", e)
			return nil
		}
		iwd_bus = c
	}
	return iwd_bus
}

iwd_running :: proc() -> bool {
	c := iwd_conn()
	if c == nil {
		return false
	}
	args := [1]dbus.Dbus_Value{dbus.dbus_s(IWD)}
	m, e := dbus.dbus_call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", args[:], 3000)
	defer if m != nil {dbus.dbus_msg_free(m)}
	return e == .None && len(m.args) == 1 && dbus.dbus_as_bool(m.args[0])
}

// ---------------------------------------------------------------------------
// iwd's objects
// ---------------------------------------------------------------------------

Iwd_Device :: struct {
	path:      string,
	name:      string,
	address:   string,
	powered:   bool,
	mode:      string,
	station:   bool, // has the Station interface (station mode)
	state:     string, // Station.State: connected, connecting, disconnected, roaming...
	connected: string, // Station.ConnectedNetwork path
}

Iwd_Network :: struct {
	path:      string,
	name:      string,
	kind:      string, // open, psk, 8021x, wep, hotspot
	device:    string, // path
	connected: bool,
	known:     string, // KnownNetwork path, "" if never joined
	bss:       int, // radios answering for it
}

Iwd_Known :: struct {
	path:        string,
	name:        string,
	kind:        string,
	autoconnect: bool,
	hidden:      bool,
}

Iwd_State :: struct {
	devices:  [dynamic]Iwd_Device,
	networks: [dynamic]Iwd_Network,
	known:    [dynamic]Iwd_Known,
}

// iwd_read is GetManagedObjects on "/", sorted into the three kinds the
// panel needs. Strings are cloned into `allocator`.
iwd_read :: proc(allocator := context.allocator) -> (st: Iwd_State, err: string) {
	// The call and its reply use the caller's allocator (the heap: the
	// connection queues messages across jobs); only the copies go to
	// `allocator`.
	c := iwd_conn()
	if c == nil {
		return {}, "the system bus is not reachable"
	}
	m, e := dbus.dbus_call(c, IWD, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", nil, 5000)
	defer if m != nil {dbus.dbus_msg_free(m)}
	if e != .None {
		if e == .Call_Failed && m != nil {
			return {}, fmt.aprintf("iwd refused: %s", m.err_name)
		}
		return {}, "iwd is not reachable"
	}
	if len(m.args) != 1 {
		return {}, "iwd answered something unexpected"
	}
	return iwd_objects(m.args[0], allocator), ""
}

// iwd_objects sorts GetManagedObjects' a{oa{sa{sv}}} into devices, networks
// and known networks, copying every string into `allocator`.
iwd_objects :: proc(root: dbus.Dbus_Value, allocator := context.allocator) -> (st: Iwd_State) {
	context.allocator = allocator
	st.devices = make([dynamic]Iwd_Device)
	st.networks = make([dynamic]Iwd_Network)
	st.known = make([dynamic]Iwd_Known)
	for obj in root.items {
		if obj.kind != '{' || len(obj.items) != 2 {
			continue
		}
		path := obj.items[0].str
		ifaces := obj.items[1]
		get :: proc(ifaces: dbus.Dbus_Value, iface: string) -> (dbus.Dbus_Value, bool) {
			for e in ifaces.items {
				if e.kind == '{' && len(e.items) == 2 && e.items[0].str == iface {
					return e.items[1], true
				}
			}
			return {}, false
		}
		str :: proc(props: dbus.Dbus_Value, key: string) -> string {
			v, ok := dbus.dbus_dict_get(props, key)
			return ok ? strings.clone(v.str) : ""
		}
		flag :: proc(props: dbus.Dbus_Value, key: string) -> bool {
			v, ok := dbus.dbus_dict_get(props, key)
			return ok && dbus.dbus_as_bool(v)
		}
		if props, ok := get(ifaces, IWD_DEVICE); ok {
			d := Iwd_Device {
				path    = strings.clone(path),
				name    = str(props, "Name"),
				address = str(props, "Address"),
				powered = flag(props, "Powered"),
				mode    = str(props, "Mode"),
			}
			if sp, has := get(ifaces, IWD_STATION); has {
				d.station = true
				d.state = str(sp, "State")
				d.connected = str(sp, "ConnectedNetwork")
			}
			append(&st.devices, d)
		}
		if props, ok := get(ifaces, IWD_NETWORK); ok {
			n := Iwd_Network {
				path      = strings.clone(path),
				name      = str(props, "Name"),
				kind      = str(props, "Type"),
				device    = str(props, "Device"),
				connected = flag(props, "Connected"),
				known     = str(props, "KnownNetwork"),
				bss       = 1,
			}
			if v, has := dbus.dbus_dict_get(props, "ExtendedServiceSet"); has && v.kind == 'a' {
				n.bss = max(len(v.items), 1)
			}
			append(&st.networks, n)
		}
		if props, ok := get(ifaces, IWD_KNOWN); ok {
			append(&st.known, Iwd_Known {
				path = strings.clone(path),
				name = str(props, "Name"),
				kind = str(props, "Type"),
				autoconnect = flag(props, "AutoConnect"),
				hidden = flag(props, "Hidden"),
			})
		}
	}
	slice.sort_by(st.devices[:], proc(a, b: Iwd_Device) -> bool {return a.name < b.name})
	return st
}

// iwd_ordered is Station.GetOrderedNetworks: each network the station sees
// and its signal, in 100 * dBm. The result is in the temp allocator.
iwd_ordered :: proc(station: string) -> (paths: []string, dbm100: []int) {
	c := iwd_conn()
	if c == nil {
		return nil, nil
	}
	m, e := dbus.dbus_call(c, IWD, station, IWD_STATION, "GetOrderedNetworks", "", nil, 5000)
	defer if m != nil {dbus.dbus_msg_free(m)}
	if e != .None || len(m.args) != 1 {
		return nil, nil
	}
	ps := make([dynamic]string, context.temp_allocator)
	ss := make([dynamic]int, context.temp_allocator)
	for it in m.args[0].items {
		if len(it.items) == 2 {
			append(&ps, strings.clone(it.items[0].str, context.temp_allocator))
			append(&ss, int(i16(u16(it.items[1].num))))
		}
	}
	return ps[:], ss[:]
}

// iwd_diagnostics is StationDiagnostic.GetDiagnostics for a connected
// station: the frequency and the transmit rate of the link in use.
iwd_diagnostics :: proc(station: string) -> (freq: int, rate: string) {
	c := iwd_conn()
	if c == nil {
		return 0, ""
	}
	m, e := dbus.dbus_call(c, IWD, station, IWD_DIAG, "GetDiagnostics", "", nil, 3000)
	defer if m != nil {dbus.dbus_msg_free(m)}
	if e != .None || len(m.args) != 1 {
		return 0, ""
	}
	if v, ok := dbus.dbus_dict_get(m.args[0], "Frequency"); ok {
		freq = int(v.num)
	}
	// TxBitrate is in units of 100 kbit/s.
	if v, ok := dbus.dbus_dict_get(m.args[0], "TxBitrate"); ok && v.num > 0 {
		rate = fmt.tprintf("%d Mbit/s", v.num / 10)
	}
	return
}

// iwd_security is what the panel calls each iwd network Type.
iwd_security :: proc(kind: string) -> string {
	switch kind {
	case "open":
		return "Open"
	case "psk":
		return "WPA2/WPA3"
	case "8021x":
		return "WPA Enterprise"
	case "wep":
		return "WEP"
	case "hotspot":
		return "Hotspot 2.0"
	}
	return kind == "" ? "Unknown" : kind
}

// dbm_percent maps iwd's 100 * dBm onto the 0-100 the signal bars use:
// -100 dBm and below is nothing, -50 dBm and above is full.
dbm_percent :: proc(dbm100: int) -> int {
	return clamp(2 * (dbm100 / 100 + 100), 0, 100)
}

channel_of :: proc(mhz: int) -> int {
	switch {
	case mhz == 2484:
		return 14
	case mhz >= 2412 && mhz < 2484:
		return (mhz - 2407) / 5
	case mhz >= 5955:
		return (mhz - 5950) / 5
	case mhz >= 5000:
		return (mhz - 5000) / 5
	}
	return 0
}

// ---------------------------------------------------------------------------
// The kernel's view: every interface, addressed or not
// ---------------------------------------------------------------------------

@(private = "file")
read_sys :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

// default_gateways reads /proc/net/route: interface -> its default gateway.
default_gateways :: proc(text: string, allocator := context.temp_allocator) -> map[string]string {
	out := make(map[string]string, allocator = allocator)
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if first {
			first = false
			continue
		}
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 3 || f[1] != "00000000" {
			continue
		}
		gw, ok := strconv.parse_u64(f[2], 16)
		if !ok || gw == 0 {
			continue
		}
		out[f[0]] = fmt.aprintf("%d.%d.%d.%d", gw & 0xff, (gw >> 8) & 0xff, (gw >> 16) & 0xff, (gw >> 24) & 0xff, allocator = allocator)
	}
	return out
}

// ip_addresses parses `ip -o addr` (busybox's and iproute2's agree on it):
// interface -> its first global address of each family, with the prefix.
ip_addresses :: proc(lines: []string, allocator := context.temp_allocator) -> (v4, v6: map[string]string) {
	v4 = make(map[string]string, allocator = allocator)
	v6 = make(map[string]string, allocator = allocator)
	for line in lines {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 4 {
			continue
		}
		name := strings.trim_suffix(f[1], ":")
		if i := strings.index_byte(name, '@'); i >= 0 {
			name = name[:i]
		}
		for w, i in f {
			if i + 1 >= len(f) {
				break
			}
			if w == "inet" && !(name in v4) {
				v4[strings.clone(name, allocator)] = strings.clone(f[i + 1], allocator)
			}
			if w == "inet6" && !(name in v6) && !strings.has_prefix(f[i + 1], "fe80:") {
				v6[strings.clone(name, allocator)] = strings.clone(f[i + 1], allocator)
			}
		}
	}
	return
}

nameservers :: proc(text: string) -> string {
	ns := make([dynamic]string, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) >= 2 && f[0] == "nameserver" {
			append(&ns, f[1])
		}
	}
	return strings.join(ns[:], ", ")
}

// kernel_devices lists /sys/class/net, addressed from `ip -o addr` and
// /proc/net/route, and named after what iwd says each Wi-Fi interface is
// connected to.
@(private = "file")
kernel_devices :: proc(st: Iwd_State) -> [dynamic]Dev {
	devs := make([dynamic]Dev)
	dir, err := os.open("/sys/class/net")
	if err != nil {
		return devs
	}
	infos, _ := os.read_dir(dir, -1, context.temp_allocator)
	os.close(dir)
	names := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		append(&names, fi.name)
	}
	slice.sort(names[:])

	lines4, _ := kit.run_lines({"ip", "-o", "-4", "addr"}, context.temp_allocator)
	lines6, _ := kit.run_lines({"ip", "-o", "-6", "addr"}, context.temp_allocator)
	v4, _ := ip_addresses(lines4)
	_, v6 := ip_addresses(lines6)
	gws := default_gateways(read_sys("/proc/net/route"))
	dns := nameservers(read_sys("/etc/resolv.conf"))

	for n in names {
		base := fmt.tprintf("/sys/class/net/%s", n)
		// The ARPHRD_* type in /sys says what the link is: 1 Ethernet, 772
		// loopback, 776 an IPv6-in-IPv4 tunnel (sit), 803 a radiotap monitor
		// (mac80211_hwsim's hwsim0), 65534 a tun device.
		kind := "other"
		switch {
		case n == "lo":
			kind = "loopback"
		case os.exists(fmt.tprintf("%s/wireless", base)) || os.exists(fmt.tprintf("%s/phy80211", base)):
			kind = "wifi"
		case os.exists(fmt.tprintf("%s/bridge", base)):
			kind = "bridge"
		case:
			switch read_sys(fmt.tprintf("%s/type", base)) {
			case "1":
				kind = "ethernet"
			case "776":
				kind = "tunnel"
			case "803":
				kind = "monitor"
			case "65534":
				kind = "tun"
			}
		}
		oper := read_sys(fmt.tprintf("%s/operstate", base))
		d := Dev {
			name   = strings.clone(n),
			kind   = strings.clone(kind),
			hwaddr = strings.clone(strings.to_upper(read_sys(fmt.tprintf("%s/address", base)), context.temp_allocator)),
			mtu    = strings.clone(read_sys(fmt.tprintf("%s/mtu", base))),
		}
		if sp := read_sys(fmt.tprintf("%s/speed", base)); sp != "" && sp != "-1" {
			d.speed = fmt.aprintf("%s Mb/s", sp)
		}
		if a, ok := v4[n]; ok {
			addr, pfx := split_slash(a)
			d.ip4 = strings.clone(addr)
			d.prefix = strings.clone(pfx)
		}
		if a, ok := v6[n]; ok {
			addr, _ := split_slash(a)
			d.ip6 = strings.clone(addr)
		}
		if g, ok := gws[n]; ok {
			d.gw4 = strings.clone(g)
			d.dns = strings.clone(dns)
		}
		up := oper == "up" || (oper == "unknown" && d.ip4 != "")
		d.state = up ? .Connected : (oper == "down" ? .Unavailable : .Disconnected)
		switch kind {
		case "loopback":
			d.conn = strings.clone("lo")
		case "wifi":
			d.state = .Disconnected
			for wd in st.devices {
				if wd.name != n {continue}
				if !wd.powered {
					d.state = .Unavailable
				}
				switch wd.state {
				case "connected", "roaming":
					d.state = .Connected
				case "connecting":
					d.state = .Connecting
				}
				for nw in st.networks {
					if nw.path == wd.connected {
						d.conn = strings.clone(nw.name)
					}
				}
			}
		case:
			if up && d.ip4 != "" {
				d.conn = strings.clone(kind == "ethernet" ? "Wired" : n)
			} else if !up {
				d.state = .Disconnected
			}
		}
		append(&devs, d)
	}
	return devs
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

iwd_refresh :: proc(s: ^Store) {
	st, err := iwd_read(context.temp_allocator)
	devs := kernel_devices(st)

	saved := make([dynamic]Saved)
	for k in st.known {
		active := false
		dev := ""
		for nw in st.networks {
			if nw.known == k.path && nw.connected {
				active = true
				for wd in st.devices {
					if wd.path == nw.device {dev = wd.name}
				}
			}
		}
		append(&saved, Saved {
			name = strings.clone(k.name),
			kind = strings.clone("Wi-Fi"),
			device = strings.clone(dev),
			autoconnect = k.autoconnect,
			active = active,
		})
	}
	on := false
	for wd in st.devices {
		if wd.powered {on = true}
	}

	dbg("iwd refresh: %d interfaces, %d wifi devices, %d known, radio=%v, err=%q", len(devs), len(st.devices), len(st.known), on, err)
	sync.mutex_lock(&s.mu)
	free_devices(&s.devices)
	free_saved(&s.saved)
	s.devices = devs
	s.saved = saved
	s.radio_on = on
	s.loaded = true
	sync.mutex_unlock(&s.mu)
	if err != "" {
		set_message(s, .Bad, fmt.tprintf("%s — Wi-Fi is not shown (wired interfaces are)", err))
	}
}

iwd_wifi :: proc(s: ^Store, rescan: bool) {
	st, err := iwd_read(context.temp_allocator)
	if err != "" {
		set_message(s, .Bad, err)
		return
	}
	if rescan {
		// Station.Scan starts a scan and returns; the networks it finds
		// replace the list once it is over (Station.Scanning goes false).
		scanned := 0
		for wd in st.devices {
			if !wd.station || !wd.powered {continue}
			m, e := dbus.dbus_call(iwd_conn(), IWD, wd.path, IWD_STATION, "Scan", "", nil, 5000)
			if m != nil {dbus.dbus_msg_free(m)}
			if e == .None || e == .Call_Failed {scanned += 1} // Busy: a scan is running already
		}
		if scanned > 0 {
			deadline := time.tick_now()
			for time.tick_since(deadline) < 6 * time.Second {
				time.sleep(500 * time.Millisecond)
				busy := false
				for wd in st.devices {
					if !wd.station {continue}
					v, m, e := dbus.dbus_get_property(iwd_conn(), IWD, wd.path, IWD_STATION, "Scanning")
					if e == .None && dbus.dbus_as_bool(v) {busy = true}
					if m != nil {dbus.dbus_msg_free(m)}
				}
				if !busy {break}
			}
			st, err = iwd_read(context.temp_allocator)
		}
	}

	aps := make([dynamic]Ap)
	for wd in st.devices {
		if !wd.station {continue}
		paths, signals := iwd_ordered(wd.path)
		freq, rate := 0, ""
		if wd.connected != "" {
			freq, rate = iwd_diagnostics(wd.path)
		}
		for path, i in paths {
			for nw in st.networks {
				if nw.path != path {continue}
				ap := Ap {
					ssid     = strings.clone(nw.name),
					security = strings.clone(iwd_security(nw.kind)),
					signal   = dbm_percent(signals[i]),
					active   = nw.connected,
					bssids   = nw.bss,
				}
				if nw.connected && freq > 0 {
					ap.freq = freq
					ap.channel = channel_of(freq)
					ap.band = band_of(freq)
					ap.rate = strings.clone(rate)
				}
				append(&aps, ap)
			}
		}
	}
	slice.sort_by(aps[:], proc(a, b: Ap) -> bool {
		if a.signal != b.signal {return a.signal > b.signal}
		return a.ssid < b.ssid
	})

	now := time.now()
	hh, mm, ss := time.clock_from_time(now)
	stamp := fmt.aprintf("%02d:%02d:%02d", hh, mm, ss)
	dbg("iwd wifi: %d networks (rescan=%v)", len(aps), rescan)
	sync.mutex_lock(&s.mu)
	free_aps(&s.aps)
	s.aps = aps
	s.scanned = true
	if s.scan_at != "" {delete(s.scan_at)}
	s.scan_at = stamp
	sync.mutex_unlock(&s.mu)
	if rescan {
		set_message(s, .Good, fmt.tprintf("Scan complete — %d networks in range", len(aps)))
	}
}

iwd_radio :: proc(s: ^Store, on: bool) {
	st, err := iwd_read(context.temp_allocator)
	if err != "" {
		set_message(s, .Bad, err)
		return
	}
	if !on {
		for wd in st.devices {
			nm_intent_only(radio_argv(.Iwd, wd.path, false), WHY_RADIO_OFF)
		}
		set_message(s, .Info, "Turning the radio off is disabled: it would take this machine offline")
	} else {
		// Turning a radio on can only restore connectivity: not gated, as
		// with nmcli.
		ok := len(st.devices) > 0
		for wd in st.devices {
			if wd.powered {continue}
			args := [3]dbus.Dbus_Value{dbus.dbus_s(IWD_DEVICE), dbus.dbus_s("Powered"), dbus.dbus_variant("b", dbus.dbus_b(true))}
			m, e := dbus.dbus_call(iwd_conn(), IWD, wd.path, "org.freedesktop.DBus.Properties", "Set", "ssv", args[:], 5000)
			if m != nil {dbus.dbus_msg_free(m)}
			dbus.dbus_free_values(args[2].items)
			if e != .None {ok = false}
		}
		set_message(s, ok ? .Good : .Bad, ok ? "Wi-Fi radio enabled" : "iwd refused to turn the radio on")
	}
	iwd_refresh(s)
	iwd_wifi(s, false)
}

iwd_connect :: proc(s: ^Store, ssid, pw: string) {
	// As with nmcli: joining a network drops the connection in use, so it is
	// a logged intent. The passphrase is never part of the logged line.
	_ = pw
	nm_intent_only(connect_argv(.Iwd, ssid), WHY_CONNECT)
	set_message(s, .Info, fmt.tprintf("Joining %s is disabled: it would drop the current connection", ssid))
	iwd_refresh(s)
	iwd_wifi(s, false)
}

// status prints what the backend reads, for `network --status`: the same
// jobs the window runs, on this thread, without a window.
status :: proc() -> int {
	s := new(Store)
	s.devices = make([dynamic]Dev)
	s.aps = make([dynamic]Ap)
	s.saved = make([dynamic]Saved)
	s.backend = pick_backend()
	fmt.printfln("backend %s", backend_name(s.backend))
	run_job(s, .Refresh)
	run_job(s, .Rescan)
	fmt.printfln("radio %s", s.radio_on ? "on" : "off")
	for d in s.devices {
		fmt.printfln("device %s %s %v conn=%q ip4=%s%s gw=%s hw=%s", d.name, d.kind, d.state, d.conn, d.ip4, d.prefix, d.gw4, d.hwaddr)
	}
	for a in s.aps {
		fmt.printfln("network %q %s signal=%d%% active=%v radios=%d ch=%d %s", a.ssid, a.security, a.signal, a.active, a.bssids, a.channel, a.rate)
	}
	for v in s.saved {
		fmt.printfln("known %q %s autoconnect=%v active=%v", v.name, v.kind, v.autoconnect, v.active)
	}
	if s.message != "" {
		fmt.printfln("message %s", s.message)
	}
	return s.loaded ? 0 : 1
}
