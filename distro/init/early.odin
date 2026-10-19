package main

// Early boot: everything that has to be true before the first service runs.
//
//	/proc /sys /dev /dev/pts /dev/shm /run /tmp (before `/` is writable)
//	/dev/console reopened as fds 0 1 2, /dev/fd and friends
//	/var's directories and links, /etc/machine-id (once `/` is writable)
//	the hostname from /etc/hostname
//	lo up
//
// Each step reports failure on the console and carries on: an init that
// stops at the first EBUSY leaves a machine with no shell to find out why.

import "core:strings"
import "core:sys/linux"

Mount :: struct {
	source, target, fstype: cstring,
	flags:                  linux.Mount_Flags,
	data:                   cstring,
}

EARLY_MOUNTS := []Mount {
	{"proc", "/proc", "proc", {.NOSUID, .NODEV, .NOEXEC}, nil},
	{"sysfs", "/sys", "sysfs", {.NOSUID, .NODEV, .NOEXEC}, nil},
	{"devtmpfs", "/dev", "devtmpfs", {.NOSUID}, "mode=0755"},
	{"devpts", "/dev/pts", "devpts", {.NOSUID, .NOEXEC}, "gid=5,mode=0620,ptmxmode=0666"},
	{"shm", "/dev/shm", "tmpfs", {.NOSUID, .NODEV}, "mode=1777"},
	{"run", "/run", "tmpfs", {.NOSUID, .NODEV}, "mode=0755"},
	{"tmp", "/tmp", "tmpfs", {.NOSUID, .NODEV}, "mode=1777"},
}

mount_early :: proc() {
	for m in EARLY_MOUNTS {
		target := string(m.target)
		mkdir_p(target)
		if is_mounted(target) {continue}
		err := linux.mount(m.source, m.target, m.fstype, m.flags, rawptr(m.data))
		if err != .NONE && err != .EBUSY {
			say("cannot mount %s on %s (%v)", m.fstype, target, err)
		}
	}
	say("mounted /proc /sys /dev /dev/pts /dev/shm /run /tmp")

	// What udev would otherwise provide, and what shells and `bash <(...)`
	// expect to find.
	links := [][2]cstring {
		{"/proc/self/fd", "/dev/fd"},
		{"/proc/self/fd/0", "/dev/stdin"},
		{"/proc/self/fd/1", "/dev/stdout"},
		{"/proc/self/fd/2", "/dev/stderr"},
		{"/proc/kcore", "/dev/core"},
	}
	for l in links {linux.symlink(l[0], l[1])}
	mkdir_p("/run/lock", 0o1777)
	linux.chmod("/run/lock", transmute(linux.Mode)u32(0o1777))
}

// prepare_var runs once `/` is writable and fstab's filesystems (a separate
// /var among them) are mounted.
prepare_var :: proc() {
	// The tree under /var that services write into. /var/run and /var/lock
	// point into /run so their contents are gone at the next boot, which is
	// what every program that writes a pid file there assumes.
	mkdir_p("/var/log")
	mkdir_p("/var/tmp", 0o1777)
	linux.chmod("/var/tmp", transmute(linux.Mode)u32(0o1777))
	if !exists("/var/run") {linux.symlink("../run", "/var/run")}
	if !exists("/var/lock") {linux.symlink("../run/lock", "/var/lock")}
}

// machine_id writes /etc/machine-id on the first boot that finds it missing
// or empty: 32 lower-case hex digits from the kernel's random pool and a
// newline, the systemd format that D-Bus, browsers and journal readers
// expect. The image ships without one, so every copy of it gets its own.
machine_id :: proc() {
	if text, ok := read_file("/etc/machine-id", context.temp_allocator); ok && len(strings.trim_space(text)) == 32 {
		return
	}
	id: [16]u8
	if n, err := linux.getrandom(id[:], {}); err != .NONE || n != 16 {return}
	hex := "0123456789abcdef"
	out: [33]u8
	for b, i in id {
		out[2 * i] = hex[b >> 4]
		out[2 * i + 1] = hex[b & 15]
	}
	out[32] = '\n'
	if write_file("/etc/machine-id", string(out[:]), 0o444) {
		say("machine id %s", string(out[:32]))
	}
}

// is_mounted looks the target up in /proc/self/mounts. Before /proc is
// mounted there is no table, and the answer is "no": the only thing mounted
// that early is / itself (and /dev, if the kernel's devtmpfs automount ran —
// in which case mount says EBUSY and we treat that as success).
is_mounted :: proc(target: string) -> bool {
	text, ok := read_file("/proc/self/mounts", context.temp_allocator)
	if !ok {return false}
	for line in strings.split_lines(text, context.temp_allocator) {
		f := split_fields(line, context.temp_allocator)
		if len(f) >= 2 && f[1] == target {return true}
	}
	return false
}

// reopen_console points fds 0, 1 and 2 at /dev/console. The kernel opened it
// for us before exec if it existed in the root filesystem; now that devtmpfs
// is mounted it certainly does, so this also covers a root without a static
// /dev/console node.
reopen_console :: proc() {
	fd, err := linux.open("/dev/console", {.RDWR, .NOCTTY})
	if err != .NONE {return}
	linux.dup2(fd, 0)
	linux.dup2(fd, 1)
	linux.dup2(fd, 2)
	if fd > 2 {linux.close(fd)}
}

set_hostname :: proc() {
	name := "palmframe"
	if text, ok := read_file("/etc/hostname", context.temp_allocator); ok {
		t := strings.trim_space(text)
		if t != "" {name = t}
	}
	if err := linux.sethostname(name); err != .NONE {
		say("cannot set hostname (%v)", err)
		return
	}
	say("hostname %s", name)
}

// Interface flags through the classic SIOCGIFFLAGS / SIOCSIFFLAGS ioctls on
// any socket. struct ifreq is 40 bytes: a 16-byte name and a union whose
// first member, for these two requests, is a short of flags.
Ifreq :: struct {
	name:  [16]u8,
	flags: i16,
	_:     [22]u8,
}

SIOCGIFFLAGS :: 0x8913
SIOCSIFFLAGS :: 0x8914
IFF_UP :: 0x1

// link_up sets IFF_UP on an interface. For lo that is the whole job: the
// kernel gives the loopback device 127.0.0.1/8 and ::1 by itself as it comes
// up. eth0's address comes from udhcpc (the `network` service).
link_up :: proc(ifname: string) -> bool {
	ret := linux.syscall(linux.SYS_socket, 2 /*AF_INET*/, SOCK_DGRAM | SOCK_CLOEXEC, 0)
	if ret < 0 {return false}
	fd := linux.Fd(ret)
	defer linux.close(fd)
	req: Ifreq
	copy(req.name[:15], ifname)
	if i64(linux.ioctl(fd, SIOCGIFFLAGS, uintptr(&req))) < 0 {return false}
	req.flags |= IFF_UP
	return i64(linux.ioctl(fd, SIOCSIFFLAGS, uintptr(&req))) >= 0
}
