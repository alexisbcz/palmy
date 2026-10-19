package main

// Device permissions: the part of udev Palmy needs.
//
// devtmpfs already creates every device node, as root:root 0600 (or 0666 for
// the handful the kernel knows are public). What it cannot know is that the
// window manager, running as an ordinary user in groups `video` and `input`,
// should be able to open the GPU and the keyboard. So palm-init applies four
// rules, once over what already exists at boot (coldplug) and again for every
// device the kernel announces later (hotplug):
//
//	/dev/dri/*           root:video  0660
//	/dev/input/event*    root:input  0660
//	/dev/snd/*           root:audio  0660
//	/dev/tty[0-9]*       root:tty    0620
//
// Hotplug listens on a NETLINK_KOBJECT_UEVENT socket, the same broadcast udev
// reads. A kernel uevent datagram is a header line and then NUL-separated
// KEY=value pairs:
//
//	add@/devices/pci0000:00/.../drm/card0 \0 ACTION=add \0 DEVPATH=... \0
//	SUBSYSTEM=drm \0 DEVNAME=dri/card0 \0 DEVTYPE=drm_minor \0 MAJOR=226 ...
//
// DEVNAME is relative to /dev. devtmpfs creates the node before the uevent is
// sent, so by the time we read "add" the node is there to chown.
//
// The socket is opened before the coldplug walk, so a device that appears
// between the two is seen at least once rather than not at all.

import "core:strings"
import "core:sys/linux"

Device_Rule :: struct {
	group: string,
	mode:  u32,
}

// Fallback gids, the ones the CONTRACT fixes, for when /etc/group is missing
// or lacks the line.
DEFAULT_GIDS := [?]struct {
	name: string,
	gid:  u32,
}{{"tty", 5}, {"video", 39}, {"audio", 63}, {"input", 97}}

// device_rule says which rule covers a DEVNAME (a path relative to /dev).
device_rule :: proc(devname: string) -> (rule: Device_Rule, ok: bool) {
	switch {
	case strings.has_prefix(devname, "dri/"):
		return {"video", 0o660}, true
	case strings.has_prefix(devname, "input/event"):
		return {"input", 0o660}, true
	case strings.has_prefix(devname, "snd/"):
		return {"audio", 0o660}, true
	case strings.has_prefix(devname, "tty") && len(devname) > 3:
		for c in devname[3:] {
			if c < '0' || c > '9' {return {}, false}
		}
		return {"tty", 0o620}, true
	}
	return {}, false
}

Uevent :: struct {
	action:    string,
	devpath:   string,
	subsystem: string,
	devname:   string,
	modalias:  string,
}

// parse_uevent decodes one datagram. Messages re-broadcast by a udev daemon
// start with "libudev" and carry a binary header; there is no udev here, but
// they are refused rather than misread.
parse_uevent :: proc(msg: []u8) -> (ev: Uevent, ok: bool) {
	text := string(msg)
	if strings.has_prefix(text, "libudev") {return {}, false}
	first := true
	for part in strings.split_iterator(&text, "\x00") {
		if first {
			// "add@/devices/..." — the header must have the '@' shape.
			first = false
			if strings.index_byte(part, '@') < 0 {return {}, false}
			continue
		}
		eq := strings.index_byte(part, '=')
		if eq < 0 {continue}
		key, val := part[:eq], part[eq + 1:]
		switch key {
		case "ACTION":
			ev.action = val
		case "DEVPATH":
			ev.devpath = val
		case "SUBSYSTEM":
			ev.subsystem = val
		case "DEVNAME":
			ev.devname = val
		case "MODALIAS":
			ev.modalias = val
		}
	}
	return ev, ev.action != ""
}

Devices :: struct {
	gids: map[string]u32,
	sock: linux.Fd,
}

devices: Devices

devices_init :: proc(groups: []Group_Entry) {
	devices.gids = make(map[string]u32)
	for d in DEFAULT_GIDS {
		devices.gids[d.name] = d.gid
	}
	for g in groups {
		if g.name in devices.gids {devices.gids[g.name] = g.gid}
	}
	devices.sock = -1
}

// apply_rule chowns and chmods one node if a rule covers it.
apply_rule :: proc(devname: string) {
	rule, ok := device_rule(devname)
	if !ok {return}
	gid := devices.gids[rule.group]
	path := strings.clone_to_cstring(strings.concatenate({"/dev/", devname}, context.temp_allocator), context.temp_allocator)
	linux.chown(path, 0, linux.Gid(gid))
	linux.chmod(path, transmute(linux.Mode)rule.mode)
}

// coldplug walks the nodes that existed before palm-init was listening.
coldplug :: proc() {
	count := 0
	if names, ok := list_dir("/dev"); ok {
		for name in names {
			if _, covered := device_rule(name); covered {
				apply_rule(name)
				count += 1
			}
		}
	}
	for dir in ([]string{"dri", "input", "snd"}) {
		names, ok := list_dir(strings.concatenate({"/dev/", dir}, context.temp_allocator))
		if !ok {continue}
		for name in names {
			devname := strings.concatenate({dir, "/", name}, context.temp_allocator)
			if _, covered := device_rule(devname); covered {
				apply_rule(devname)
				count += 1
			}
		}
	}
	say("device permissions set on %d nodes", count)
}

AF_NETLINK :: 16
NETLINK_KOBJECT_UEVENT :: 15
SOCK_DGRAM :: 2
SOCK_NONBLOCK :: 0o4000
SOCK_CLOEXEC :: 0o2000000

Sockaddr_Nl :: struct {
	family: u16,
	pad:    u16,
	pid:    u32,
	groups: u32,
}

// hotplug_open subscribes to the kernel's uevent multicast group (group 1).
hotplug_open :: proc() -> bool {
	ret := linux.syscall(linux.SYS_socket, AF_NETLINK, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT)
	if ret < 0 {
		say("hotplug: cannot open a uevent socket (errno %d); devices added later keep default permissions", -ret)
		return false
	}
	fd := linux.Fd(ret)
	addr := Sockaddr_Nl{family = AF_NETLINK, groups = 1}
	if r := linux.syscall(linux.SYS_bind, fd, &addr, size_of(Sockaddr_Nl)); r < 0 {
		say("hotplug: cannot bind the uevent socket (errno %d)", -r)
		linux.close(fd)
		return false
	}
	// A burst of devices at boot can overflow the default receive buffer;
	// ask for more. Failure is harmless — coldplug covers the boot burst.
	size: i32 = 1 << 20
	linux.syscall(linux.SYS_setsockopt, fd, 1 /*SOL_SOCKET*/, 33 /*SO_RCVBUFFORCE*/, &size, size_of(i32))
	devices.sock = fd
	return true
}

// hotplug_drain reads every pending uevent and applies the rules to "add"s.
hotplug_drain :: proc() {
	buf: [8192]u8
	for {
		n := linux.syscall(linux.SYS_recvfrom, devices.sock, &buf[0], len(buf), 0, 0, 0)
		if n <= 0 {return}
		ev, ok := parse_uevent(buf[:n])
		if !ok {continue}
		if ev.action == "add" && ev.modalias != "" {
			hotplug_modprobe(ev.modalias)
		}
		if ev.devname == "" {continue}
		if ev.action == "add" || ev.action == "change" {
			apply_rule(ev.devname)
		}
	}
}
