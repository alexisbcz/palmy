package main

// The BlueZ layer: everything this applet knows about the adapter and the
// devices around it comes from four commands, parsed here.
//
//	rfkill list bluetooth           soft/hard radio block
//	bluetoothctl show               the default adapter
//	bluetoothctl devices [Paired]   the address/name lists
//	bluetoothctl info <MAC>         one device in full
//
// Nothing in this file blocks for long: every one of those calls returns in a
// few milliseconds when bluetoothd is there, and every bluetoothctl call has a
// deadline (run.odin) for when it is not. The one command that does block —
// `bluetoothctl --timeout N scan on` — is run on a worker thread in jobs.odin,
// never from the frame.

import "core:mem"
import "core:strconv"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

Kind :: enum {
	Generic,
	Headphones,
	Headset,
	Speaker,
	Keyboard,
	Mouse,
	Gamepad,
	Phone,
	Computer,
	Tablet,
	Watch,
	Display,
	Printer,
	Car,
	Network,
}

Adapter :: struct {
	present:      bool,
	silent:       bool, // bluetoothctl did not answer by its deadline: no bluetoothd
	addr:         string,
	addr_type:    string,
	name:         string,
	alias:        string,
	class:        u32,
	powered:      bool,
	discoverable: bool,
	pairable:     bool,
	discovering:  bool,
	disc_timeout: int,
	soft_block:   bool,
	hard_block:   bool,
	services:     int,
}

Device :: struct {
	addr:      string,
	addr_type: string, // public / random
	name:      string, // from `bluetoothctl devices`, or Name:
	alias:     string,
	icon_name: string, // BlueZ's own Icon: hint
	class:     u32,
	has_class: bool,
	paired:    bool,
	bonded:    bool,
	trusted:   bool,
	blocked:   bool,
	connected: bool,
	legacy:    bool,
	battery:   int, // -1 when not reported
	rssi:      int, // 0 when not reported
	has_rssi:  bool,
	rssi_old:  bool, // remembered from an earlier scan, not reported now
	tx_power:  int,
	has_tx:    bool,
	services:  int,
	modalias:  string,
	reachable: bool, // `bluetoothctl info` answered at all
	kind:      Kind,
}

// ---------------------------------------------------------------------------
// Small parsing helpers
// ---------------------------------------------------------------------------

// field matches one of bluetoothctl's tab-indented `Key: value` lines.
field :: proc(line, key: string) -> (val: string, ok: bool) {
	t := strings.trim_space(line)
	if len(t) <= len(key) || t[len(key)] != ':' {
		return "", false
	}
	if t[:len(key)] != key {
		return "", false
	}
	return strings.trim_space(t[len(key) + 1:]), true
}

// paren_int reads the decimal bluetoothctl prints beside a hex value, as in
// `Class: 0x00240404 (2360324)` or `RSSI: 0xffffffab (-85)`.
paren_int :: proc(s: string) -> (v: int, ok: bool) {
	o := strings.index_byte(s, '(')
	c := strings.last_index_byte(s, ')')
	if o < 0 || c <= o + 1 {
		return 0, false
	}
	return strconv.parse_int(strings.trim_space(s[o + 1:c]))
}

// hex_word reads the `0x00240404` half of the same line.
hex_word :: proc(s: string) -> (v: u32, ok: bool) {
	t := s
	if sp := strings.index_byte(t, ' '); sp > 0 {
		t = t[:sp]
	}
	if !strings.has_prefix(t, "0x") {
		return 0, false
	}
	n, good := strconv.parse_u64_of_base(t[2:], 16)
	return u32(n), good
}

yesno :: proc(s: string) -> bool {
	return s == "yes"
}

// paren_tag pulls the `(public)` off the end of a `Device <MAC> (public)` or
// `Controller <MAC> (public)` header line.
paren_tag :: proc(s: string) -> string {
	o := strings.last_index_byte(s, '(')
	c := strings.last_index_byte(s, ')')
	if o >= 0 && c > o + 1 {
		return s[o + 1:c]
	}
	return ""
}

// ---------------------------------------------------------------------------
// Device class
//
// A 24-bit Class of Device packs a service bitmap, a 5-bit major class and a
// 6-bit minor class. BlueZ usually hands us its own `Icon:` string as well,
// which is more reliable for LE devices, so that is tried first.
// ---------------------------------------------------------------------------

major_of :: proc(class: u32) -> u32 {return (class >> 8) & 0x1f}
minor_of :: proc(class: u32) -> u32 {return (class >> 2) & 0x3f}

kind_from_icon :: proc(icon: string) -> (Kind, bool) {
	switch icon {
	case "audio-headset":
		return .Headset, true
	case "audio-headphones":
		return .Headphones, true
	case "audio-card", "multimedia-player", "audio-speakers":
		return .Speaker, true
	case "input-keyboard":
		return .Keyboard, true
	case "input-mouse":
		return .Mouse, true
	case "input-gaming":
		return .Gamepad, true
	case "input-tablet":
		return .Tablet, true
	case "phone":
		return .Phone, true
	case "computer":
		return .Computer, true
	case "video-display", "tv":
		return .Display, true
	case "printer", "scanner":
		return .Printer, true
	case "network-wireless", "modem":
		return .Network, true
	}
	return .Generic, false
}

kind_from_class :: proc(class: u32) -> Kind {
	switch major_of(class) {
	case 1:
		return .Computer
	case 2:
		return .Phone
	case 3:
		return .Network
	case 4:
		switch minor_of(class) {
		case 1, 2:
			return .Headset
		case 6:
			return .Headphones
		case 5, 7, 10:
			return .Speaker
		case 8:
			return .Car
		case 9, 14, 15, 16:
			return .Display
		case 18:
			return .Gamepad
		}
		return .Speaker
	case 5:
		// Bits 4-5 of the minor class are the keyboard / pointer flags.
		switch (minor_of(class) >> 4) & 0x3 {
		case 1:
			return .Keyboard
		case 2:
			return .Mouse
		case 3:
			return .Keyboard
		}
		switch minor_of(class) & 0xf {
		case 2:
			return .Gamepad
		case 3:
			return .Gamepad
		case 5:
			return .Tablet
		}
		return .Mouse
	case 6:
		return .Printer
	case 7:
		return .Watch
	case 8:
		return .Gamepad
	}
	return .Generic
}

// class_label is the human reading of the major/minor pair, the same words the
// Bluetooth assigned-numbers document uses.
class_label :: proc(d: Device) -> string {
	if !d.has_class {
		if d.icon_name != "" {
			return d.icon_name
		}
		return "Low Energy"
	}
	maj: string
	switch major_of(d.class) {
	case 0:
		maj = "Miscellaneous"
	case 1:
		maj = "Computer"
	case 2:
		maj = "Phone"
	case 3:
		maj = "Network"
	case 4:
		maj = "Audio / Video"
	case 5:
		maj = "Peripheral"
	case 6:
		maj = "Imaging"
	case 7:
		maj = "Wearable"
	case 8:
		maj = "Toy"
	case 9:
		maj = "Health"
	case:
		maj = "Uncategorised"
	}
	min_: string
	switch d.kind {
	case .Headphones:
		min_ = "Headphones"
	case .Headset:
		min_ = "Headset"
	case .Speaker:
		min_ = "Loudspeaker"
	case .Keyboard:
		min_ = "Keyboard"
	case .Mouse:
		min_ = "Pointing device"
	case .Gamepad:
		min_ = "Game controller"
	case .Phone:
		min_ = "Smartphone"
	case .Computer:
		min_ = "Computer"
	case .Tablet:
		min_ = "Tablet"
	case .Watch:
		min_ = "Wristwatch"
	case .Display:
		min_ = "Display"
	case .Printer:
		min_ = "Printer"
	case .Car:
		min_ = "Car audio"
	case .Network:
		min_ = "Access point"
	case .Generic:
		min_ = ""
	}
	if min_ == "" {
		return maj
	}
	return strings.concatenate({maj, " · ", min_}, context.temp_allocator)
}

kind_label :: proc(k: Kind) -> string {
	switch k {
	case .Headphones:
		return "Headphones"
	case .Headset:
		return "Headset"
	case .Speaker:
		return "Speaker"
	case .Keyboard:
		return "Keyboard"
	case .Mouse:
		return "Mouse"
	case .Gamepad:
		return "Controller"
	case .Phone:
		return "Phone"
	case .Computer:
		return "Computer"
	case .Tablet:
		return "Tablet"
	case .Watch:
		return "Watch"
	case .Display:
		return "Display"
	case .Printer:
		return "Printer"
	case .Car:
		return "Car"
	case .Network:
		return "Network"
	case .Generic:
		return "Device"
	}
	return "Device"
}

// ---------------------------------------------------------------------------
// Reading the adapter
// ---------------------------------------------------------------------------

read_adapter :: proc(al: mem.Allocator) -> (a: Adapter) {
	a.disc_timeout = -1

	if lines, ok := kit.run_lines({"rfkill", "list", "bluetooth"}, context.temp_allocator); ok {
		for l in lines {
			if v, got := field(l, "Soft blocked"); got {
				a.soft_block = yesno(v)
			}
			if v, got := field(l, "Hard blocked"); got {
				a.hard_block = yesno(v)
			}
		}
	}

	lines, ok, late := bt_lines({"bluetoothctl", "show"}, context.temp_allocator)
	if late {
		a.silent = true
		return
	}
	if !ok || len(lines) == 0 {
		return
	}

	for l in lines {
		t := strings.trim_space(l)
		if strings.has_prefix(t, "Controller ") {
			rest := t[len("Controller "):]
			if sp := strings.index_byte(rest, ' '); sp > 0 {
				a.addr = strings.clone(rest[:sp], al)
			} else {
				a.addr = strings.clone(rest, al)
			}
			a.addr_type = strings.clone(paren_tag(t), al)
			a.present = true
			continue
		}
		if v, got := field(t, "Name"); got {
			a.name = strings.clone(v, al)
		}
		if v, got := field(t, "Alias"); got {
			a.alias = strings.clone(v, al)
		}
		if v, got := field(t, "Powered"); got {
			a.powered = yesno(v)
		}
		if v, got := field(t, "Discoverable"); got {
			a.discoverable = yesno(v)
		}
		if v, got := field(t, "Pairable"); got {
			a.pairable = yesno(v)
		}
		if v, got := field(t, "Discovering"); got {
			a.discovering = yesno(v)
		}
		if v, got := field(t, "DiscoverableTimeout"); got {
			if n, good := paren_int(v); good {
				a.disc_timeout = n
			}
		}
		if v, got := field(t, "Class"); got {
			if n, good := hex_word(v); good {
				a.class = n
			}
		}
		if _, got := field(t, "UUID"); got {
			a.services += 1
		}
	}
	if a.alias == "" {
		a.alias = a.name
	}
	return
}

// ---------------------------------------------------------------------------
// Reading devices
// ---------------------------------------------------------------------------

// device_list parses `bluetoothctl devices [filter]` into addresses and the
// short names that listing carries.
device_list :: proc(
	filter: string,
	al: mem.Allocator,
) -> (
	addrs: [dynamic]string,
	names: [dynamic]string,
) {
	addrs = make([dynamic]string, al)
	names = make([dynamic]string, al)

	argv := filter == "" \
		? []string{"bluetoothctl", "devices"} \
		: []string{"bluetoothctl", "devices", filter}
	if bluez_silent() {
		return
	}
	lines, ok, _ := bt_lines(argv, context.temp_allocator)
	if !ok {
		return
	}
	for l in lines {
		t := strings.trim_space(l)
		if !strings.has_prefix(t, "Device ") {
			continue
		}
		rest := t[len("Device "):]
		sp := strings.index_byte(rest, ' ')
		if sp <= 0 {
			append(&addrs, strings.clone(rest, al))
			append(&names, "")
			continue
		}
		append(&addrs, strings.clone(rest[:sp], al))
		append(&names, strings.clone(strings.trim_space(rest[sp + 1:]), al))
	}
	return
}

contains_addr :: proc(list: []string, addr: string) -> bool {
	for a in list {
		if a == addr {
			return true
		}
	}
	return false
}

// read_device runs `bluetoothctl info <MAC>` and fills in everything it reports.
read_device :: proc(addr, list_name: string, al: mem.Allocator) -> (d: Device) {
	d.addr = strings.clone(addr, al)
	d.name = strings.clone(list_name, al)
	d.battery = -1

	if bluez_silent() {
		return
	}
	lines, _, _ := bt_lines({"bluetoothctl", "info", addr}, context.temp_allocator)
	for l in lines {
		t := strings.trim_space(l)
		if strings.has_prefix(t, "Device ") {
			if strings.has_suffix(t, "not available") {
				continue
			}
			d.reachable = true
			d.addr_type = strings.clone(paren_tag(t), al)
			continue
		}
		if v, got := field(t, "Name"); got {
			d.name = strings.clone(v, al)
		}
		if v, got := field(t, "Alias"); got {
			d.alias = strings.clone(v, al)
		}
		if v, got := field(t, "Icon"); got {
			d.icon_name = strings.clone(v, al)
		}
		if v, got := field(t, "Class"); got {
			if n, good := hex_word(v); good {
				d.class = n
				d.has_class = true
			}
		}
		if v, got := field(t, "Paired"); got {d.paired = yesno(v)}
		if v, got := field(t, "Bonded"); got {d.bonded = yesno(v)}
		if v, got := field(t, "Trusted"); got {d.trusted = yesno(v)}
		if v, got := field(t, "Blocked"); got {d.blocked = yesno(v)}
		if v, got := field(t, "Connected"); got {d.connected = yesno(v)}
		if v, got := field(t, "LegacyPairing"); got {d.legacy = yesno(v)}
		if v, got := field(t, "Modalias"); got {
			d.modalias = strings.clone(v, al)
		}
		if v, got := field(t, "Battery Percentage"); got {
			if n, good := paren_int(v); good {
				d.battery = n
			}
		}
		if v, got := field(t, "RSSI"); got {
			if n, good := paren_int(v); good {
				d.rssi = n
				d.has_rssi = true
			}
		}
		if v, got := field(t, "TxPower"); got {
			if n, good := paren_int(v); good {
				d.tx_power = n
				d.has_tx = true
			}
		}
		if _, got := field(t, "UUID"); got {
			d.services += 1
		}
	}

	if d.alias == "" {
		d.alias = d.name
	}
	if d.name == "" {
		d.name = d.alias
	}

	if k, ok := kind_from_icon(d.icon_name); ok {
		d.kind = k
	} else if d.has_class {
		d.kind = kind_from_class(d.class)
	} else {
		d.kind = .Generic
	}
	return
}

// read_devices is the whole picture: every device BlueZ currently knows,
// cross-referenced against the Paired and Connected filters so a stale `info`
// cannot disagree with the lists.
read_devices :: proc(al: mem.Allocator) -> []Device {
	all_addrs, all_names := device_list("", context.temp_allocator)
	paired, _ := device_list("Paired", context.temp_allocator)
	connected, _ := device_list("Connected", context.temp_allocator)
	trusted, _ := device_list("Trusted", context.temp_allocator)

	out := make([dynamic]Device, 0, len(all_addrs), al)
	for addr, i in all_addrs {
		d := read_device(addr, all_names[i], al)
		d.paired = d.paired || contains_addr(paired[:], addr)
		d.connected = d.connected || contains_addr(connected[:], addr)
		d.trusted = d.trusted || contains_addr(trusted[:], addr)
		append(&out, d)
	}
	return out[:]
}

// display_name is what the row shows. A device that never advertised a name
// has its dashed address as an alias, which is noise, so it is replaced.
display_name :: proc(d: Device) -> (label: string, named: bool) {
	n := d.alias != "" ? d.alias : d.name
	if n == "" {
		return "Unnamed device", false
	}
	// `AA-BB-CC-DD-EE-FF` is BlueZ standing in for a missing name.
	if same_hex(n, d.addr) {
		return "Unnamed device", false
	}
	return n, true
}

// same_hex compares two strings ignoring separators and case, which is how the
// placeholder alias `AA-BB-CC-DD-EE-FF` is recognised as the address itself.
same_hex :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for {
		for i < len(a) && (a[i] == '-' || a[i] == ':') {i += 1}
		for j < len(b) && (b[j] == '-' || b[j] == ':') {j += 1}
		if i >= len(a) || j >= len(b) {
			return i >= len(a) && j >= len(b)
		}
		ca, cb := a[i], b[j]
		if ca >= 'a' && ca <= 'z' {ca -= 32}
		if cb >= 'a' && cb <= 'z' {cb -= 32}
		if ca != cb {
			return false
		}
		i += 1
		j += 1
	}
}

// bars maps RSSI in dBm onto a four-bar signal meter.
bars_for_rssi :: proc(rssi: int) -> int {
	switch {
	case rssi >= -55:
		return 4
	case rssi >= -67:
		return 3
	case rssi >= -80:
		return 2
	case rssi >= -95:
		return 1
	}
	return 0
}
