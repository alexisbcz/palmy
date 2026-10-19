package main

// /etc/fstab: what `mount -a` and `swapon -a` would do, and the reverse at
// shutdown.
//
//	<device>   <mountpoint>  <type>  <options>              <dump>  <pass>
//	LABEL=palmframe   /           ext4  rw,relatime                0  1
//	LABEL=PALMESP     /boot/efi   vfat  rw,relatime,fmask=0077...  0  2
//	/swapfile         none        swap  sw,pri=10                  0  0
//
// The device is a path, or UUID=, LABEL=, PARTUUID= or PARTLABEL= (quotes
// allowed). PARTUUID and PARTLABEL come from the kernel's own uevent for the
// partition; UUID and LABEL are read from the filesystem's superblock
// (probe.odin: ext2/3/4, FAT and swap, what Palmframe makes). A device that
// is not there yet is waited for, up to DEVICE_WAIT_MS, once per boot.
//
// The order at boot (main.odin):
//
//	1. `/`: if the kernel mounted it read-only and its pass is not 0, it is
//	   checked (fsck.<type> -p) before palm-init remounts it with the
//	   options in its line (read-write unless they say `ro`).
//	2. every other line, in file order: swap lines are swapon(2)ed with
//	   their pri= and discard; the rest are checked when their pass is not
//	   0 and then mounted, the mount point created if missing.
//
// A checker is `fsck.<type>` in PATH, or e2fsck / fsck.fat for the ext and
// FAT families (e2fsprogs and dosfstools; the disk image installs both).
// When there is none the check is skipped with one line on the console:
// ext4's journal already makes a dirty shutdown harmless in the common case. The
// answer is read the way fsck(8) defines it: 0 and 1 are fine; 2 and 3 on
// `/` mean "reboot now", and palm-init does; 4 or more means errors were left,
// and the filesystem is not mounted (`/` stays read-only) so that a person can
// look at it on the serial console.
//
// Options are the usual ones. Those the kernel knows as flags (ro, nosuid,
// noatime, relatime, bind ...) become mount flags; noauto, nofail, user,
// _netdev, x-*, comment= and pri= are fstab's own and are dropped; everything
// else (fmask=0077, errors=remount-ro, size=...) is handed to the
// filesystem as its data string. Nothing stops the boot: a line that fails is
// reported, and `nofail` only makes the report quieter.
//
// Lines for what palm-init mounts before reading this file (/proc, /sys,
// /dev, /dev/pts, /dev/shm, /run, /tmp) are skipped, because those are
// already mounted.
//
// At shutdown, after the services are gone: swapoff everything in
// /proc/swaps, unmount every real filesystem in reverse mount order
// (remounting read-only whatever is still busy), then remount `/` read-only.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

FSTAB :: "/etc/fstab"
DEVICE_WAIT_MS :: 3_000

Fstab_Entry :: struct {
	spec, dir, type, options: string,
	freq, pass:               int,
}

Mount_Options :: struct {
	flags:        linux.Mount_Flags,
	data:         string, // what the filesystem gets, comma-separated
	noauto:       bool,
	nofail:       bool,
	swap_pri:     int, // -1: not given
	swap_discard: bool,
}

// unescape_octal undoes fstab's (and /proc/mounts') `\040` for a space.
unescape_octal :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '\\') < 0 {return s}
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) && is_octal(s[i + 1]) && is_octal(s[i + 2]) && is_octal(s[i + 3]) {
			v := (s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0')
			strings.write_byte(&b, v)
			i += 3
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private = "file")
is_octal :: proc(c: u8) -> bool {return c >= '0' && c <= '7'}

// parse_fstab returns the well-formed lines. A line needs at least the
// device, the mount point and the type; options default to `defaults`, dump
// and pass to 0, as mount(8) reads them.
parse_fstab :: proc(text: string, allocator := context.allocator) -> []Fstab_Entry {
	out := make([dynamic]Fstab_Entry, allocator)
	for raw in strings.split_lines(text, allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {continue}
		f := split_fields(line, allocator)
		if len(f) < 3 {continue}
		e := Fstab_Entry {
			spec    = unescape_octal(f[0], allocator),
			dir     = unescape_octal(f[1], allocator),
			type    = f[2],
			options = "defaults",
		}
		if len(f) >= 4 {e.options = f[3]}
		if len(f) >= 5 {e.freq, _ = strconv.parse_int(f[4], 10)}
		if len(f) >= 6 {e.pass, _ = strconv.parse_int(f[5], 10)}
		append(&out, e)
	}
	return out[:]
}

parse_mount_options :: proc(opts: string, allocator := context.allocator) -> (m: Mount_Options) {
	m.swap_pri = -1
	data := make([dynamic]string, context.temp_allocator)
	for o in strings.split(opts, ",", context.temp_allocator) {
		switch o {
		case "", "defaults", "auto", "user", "users", "nouser", "owner", "group", "_netdev", "sw", "rw":
			if o == "rw" {m.flags -= {.RDONLY}}
		case "noauto":
			m.noauto = true
		case "nofail":
			m.nofail = true
		case "ro":
			m.flags += {.RDONLY}
		case "nosuid":
			m.flags += {.NOSUID}
		case "suid":
			m.flags -= {.NOSUID}
		case "nodev":
			m.flags += {.NODEV}
		case "dev":
			m.flags -= {.NODEV}
		case "noexec":
			m.flags += {.NOEXEC}
		case "exec":
			m.flags -= {.NOEXEC}
		case "sync":
			m.flags += {.SYNCHRONOUS}
		case "async":
			m.flags -= {.SYNCHRONOUS}
		case "dirsync":
			m.flags += {.DIRSYNC}
		case "noatime":
			m.flags += {.NOATIME}
		case "atime":
			m.flags -= {.NOATIME}
		case "nodiratime":
			m.flags += {.NODIRATIME}
		case "diratime":
			m.flags -= {.NODIRATIME}
		case "relatime":
			m.flags += {.RELATIME}
		case "norelatime":
			m.flags -= {.RELATIME}
		case "strictatime":
			m.flags += {.STRICTATIME}
		case "lazytime":
			m.flags += {.LAZYTIME}
		case "nolazytime":
			m.flags -= {.LAZYTIME}
		case "mand":
			m.flags += {.MANDLOCK}
		case "nomand":
			m.flags -= {.MANDLOCK}
		case "silent":
			m.flags += {.SILENT}
		case "loud":
			m.flags -= {.SILENT}
		case "nosymfollow":
			m.flags += {.NOSYMFOLLOW}
		case "bind":
			m.flags += {.BIND}
		case "rbind":
			m.flags += {.BIND, .REC}
		case:
			switch {
			case strings.has_prefix(o, "x-"), strings.has_prefix(o, "comment="):
			case strings.has_prefix(o, "pri="):
				if v, ok := strconv.parse_int(o[4:], 10); ok && v >= 0 {m.swap_pri = min(v, 32767)}
			case o == "discard" || strings.has_prefix(o, "discard="):
				// ext4 takes `discard` as a data option too; swap takes
				// it as a swapon flag. Both get it.
				m.swap_discard = true
				append(&data, o)
			case:
				append(&data, o)
			}
		}
	}
	m.data = strings.join(data[:], ",", allocator)
	return
}

// Mount points palm-init has mounted by the time it reads fstab.
EARLY_TARGETS := []string{"/proc", "/sys", "/dev", "/dev/pts", "/dev/shm", "/run", "/tmp"}

load_fstab :: proc() -> []Fstab_Entry {
	text, ok := read_file(FSTAB)
	if !ok {return nil}
	return parse_fstab(text)
}

find_fstab_root :: proc(entries: []Fstab_Entry) -> (Fstab_Entry, bool) {
	for e in entries {
		if e.dir == "/" {return e, true}
	}
	return {}, false
}

// root_is_readonly reads `/`'s options in /proc/self/mounts. The last line
// for `/` wins: an initramfs root is "rootfs", and a later line is the real
// one if anything was mounted over it.
root_is_readonly :: proc() -> bool {
	text, ok := read_file("/proc/self/mounts", context.temp_allocator)
	if !ok {return false}
	ro := false
	for line in strings.split_lines(text, context.temp_allocator) {
		f := split_fields(line, context.temp_allocator)
		if len(f) >= 4 && f[1] == "/" {
			ro = strings.has_prefix(f[3], "ro,") || f[3] == "ro"
		}
	}
	return ro
}

Root_Check :: enum u8 {
	Fine,
	Reboot, // fsck repaired `/` and asks for a reboot
	Broken, // errors left: keep `/` read-only
}

// check_root runs before `/` is remounted read-write.
check_root :: proc(entries: []Fstab_Entry) -> Root_Check {
	e, ok := find_fstab_root(entries)
	if !ok || e.pass == 0 || !root_is_readonly() {return .Fine}
	dev, found := resolve_device(e.spec, false)
	if !found {
		say("fsck /: cannot find %s; not checked", e.spec)
		return .Fine
	}
	code := run_fsck(dev, e.type, "/")
	switch {
	case code == 2 || code == 3:
		return .Reboot
	case code >= 4:
		return .Broken
	}
	return .Fine
}

// remount_root makes `/` what its fstab line says (read-write by default).
// The kernel mounts the root read-only when the command line says `ro`
// (limine's entries do), and an initramfs root is writable already, where
// the remount is a no-op.
remount_root :: proc(entries: []Fstab_Entry) {
	opts := Mount_Options{}
	if e, ok := find_fstab_root(entries); ok {
		opts = parse_mount_options(e.options, context.temp_allocator)
	}
	flags := opts.flags + {.REMOUNT}
	data := strings.clone_to_cstring(opts.data, context.temp_allocator)
	err := linux.mount(nil, "/", nil, flags, opts.data == "" ? nil : rawptr(data))
	if err != .NONE && opts.data != "" {
		// A data option the filesystem refuses on remount: the flags alone.
		err = linux.mount(nil, "/", nil, flags, nil)
	}
	if err != .NONE {
		say("cannot remount / (%v)", err)
	} else if .RDONLY in opts.flags {
		say("/ stays read-only (fstab says ro)")
	}
}

// mount_fstab is `mount -a` and `swapon -a` for everything but `/`.
mount_fstab :: proc(entries: []Fstab_Entry) {
	mounted, swaps := 0, 0
	for e in entries {
		if e.dir == "/" {continue}
		opts := parse_mount_options(e.options, context.temp_allocator)
		if opts.noauto {continue}
		if e.type == "swap" {
			if swap_on(e.spec, opts) {swaps += 1}
			continue
		}
		early := false
		for t in EARLY_TARGETS {
			if e.dir == t {early = true}
		}
		if early || is_mounted(e.dir) {continue}

		source := e.spec
		if needs_device(e.type) || is_tag(e.spec) {
			dev, found := resolve_device(e.spec, true)
			if !found {
				say("fstab: %s for %s not found%s", e.spec, e.dir, opts.nofail ? " (nofail)" : "; not mounted")
				continue
			}
			source = dev
			if e.pass > 0 {
				if code := run_fsck(dev, e.type, e.dir); code >= 4 {
					say("fstab: %s has errors left; %s not mounted", dev, e.dir)
					continue
				}
			}
		}
		mkdir_p(e.dir)
		csrc := strings.clone_to_cstring(source, context.temp_allocator)
		cdir := strings.clone_to_cstring(e.dir, context.temp_allocator)
		ctype := strings.clone_to_cstring(e.type, context.temp_allocator)
		cdata := strings.clone_to_cstring(opts.data, context.temp_allocator)
		err := linux.mount(csrc, cdir, ctype, opts.flags, opts.data == "" ? nil : rawptr(cdata))
		if err != .NONE {
			say("fstab: cannot mount %s on %s (%s, %v)", source, e.dir, e.type, err)
			continue
		}
		say("mounted %s on %s (%s)", source, e.dir, e.type)
		mounted += 1
	}
	if mounted > 0 || swaps > 0 {
		say("fstab: %d mounted, %d swap", mounted, swaps)
	}
}

// needs_device says whether a filesystem type mounts a block device (and so
// is resolved, waited for and checked) rather than a name like `tmpfs`.
needs_device :: proc(fstype: string) -> bool {
	switch fstype {
	case "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "ramfs", "cgroup", "cgroup2", "securityfs", "debugfs", "tracefs", "configfs", "pstore", "efivarfs", "bpf", "mqueue", "hugetlbfs", "fusectl", "binfmt_misc", "autofs", "overlay", "nfs", "nfs4", "cifs", "9p", "virtiofs", "fuse", "none":
		return false
	}
	return true
}

is_tag :: proc(spec: string) -> bool {
	for t in ([]string{"UUID=", "LABEL=", "PARTUUID=", "PARTLABEL="}) {
		if strings.has_prefix(spec, t) {return true}
	}
	return false
}

swap_on :: proc(spec: string, opts: Mount_Options) -> bool {
	dev, found := resolve_device(spec, true)
	if !found {
		say("fstab: swap %s not found", spec)
		return false
	}
	flags: linux.Swap_Flags
	pri := opts.swap_pri
	if pri >= 0 {flags += {.PREFER}}
	if opts.swap_discard {flags += {.DISCARD}}
	// The priority is the low 15 bits of the same word as the flags.
	raw := transmute(u32)flags | (pri >= 0 ? u32(pri) & 0x7fff : 0)
	cdev := strings.clone_to_cstring(dev, context.temp_allocator)
	err := linux.swapon(cdev, transmute(linux.Swap_Flags)raw)
	if err == .EBUSY {return false} 	// already on
	if err != .NONE {
		say("fstab: swapon %s failed (%v)%s", dev, err, err == .EINVAL ? "; is it mkswap'd?" : "")
		return false
	}
	say("swap on %s", dev)
	return true
}

// run_fsck checks one filesystem with fsck.<type> -p and returns fsck(8)'s
// exit code, or 0 when there is no checker to run.
run_fsck :: proc(dev, fstype, dir: string) -> int {
	checker := resolve_cmd(fmt.tprintf("fsck.%s", fstype))
	if checker == "" {
		// dosfstools installs fsck.fat only; e2fsprogs has e2fsck under
		// every ext name, but a minimal install may not.
		switch fstype {
		case "vfat", "msdos", "fat":
			checker = resolve_cmd("fsck.fat")
		case "ext2", "ext3", "ext4":
			checker = resolve_cmd("e2fsck")
		}
	}
	if checker == "" {
		say("fsck %s: no fsck.%s; not checked", dir, fstype)
		return 0
	}
	say("checking %s (%s)", dir, dev)
	status, ran := run_program({checker, "-p", dev}, 0)
	if !ran {return 0}
	code := int((status >> 8) & 0xff)
	if status & 0x7f != 0 {code = 8}
	switch {
	case code == 0:
	case code == 1:
		say("fsck %s: errors corrected", dir)
	case code == 2 || code == 3:
		say("fsck %s: errors corrected; the system must reboot", dir)
	case:
		say("fsck %s: errors left (exit %d); run fsck.%s %s by hand", dir, code, fstype, dev)
	}
	return code
}

// --- shutdown -----------------------------------------------------------------

Mounted :: struct {
	source, dir, type: string,
}

read_mounts :: proc() -> []Mounted {
	out := make([dynamic]Mounted, context.temp_allocator)
	text, ok := read_file("/proc/self/mounts", context.temp_allocator)
	if !ok {return out[:]}
	for line in strings.split_lines(text, context.temp_allocator) {
		f := split_fields(line, context.temp_allocator)
		if len(f) < 3 {continue}
		append(&out, Mounted{unescape_octal(f[0], context.temp_allocator), unescape_octal(f[1], context.temp_allocator), f[2]})
	}
	return out[:]
}

// unmount_all is the second half of shutdown, after stop_all: swap off,
// every real filesystem unmounted (or read-only), then `/` read-only.
unmount_all :: proc() {
	if text, ok := read_file("/proc/swaps", context.temp_allocator); ok {
		lines := strings.split_lines(text, context.temp_allocator)
		for line in lines[1:] {
			f := split_fields(line, context.temp_allocator)
			if len(f) == 0 {continue}
			dev := unescape_octal(f[0], context.temp_allocator)
			if err := linux.swapoff(strings.clone_to_cstring(dev, context.temp_allocator)); err != .NONE {
				say("swapoff %s failed (%v)", dev, err)
			} else {
				say("swap off %s", dev)
			}
		}
	}
	mounts := read_mounts()
	for i := len(mounts) - 1; i >= 0; i -= 1 {
		m := mounts[i]
		if m.dir == "/" || !needs_device(m.type) {continue}
		cdir := strings.clone_to_cstring(m.dir, context.temp_allocator)
		if err := linux.umount2(cdir, {}); err == .NONE {
			say("unmounted %s", m.dir)
		} else if err != .EINVAL && err != .ENOENT {
			if rerr := linux.mount(nil, cdir, nil, {.REMOUNT, .RDONLY}, nil); rerr == .NONE {
				say("%s is busy; remounted read-only", m.dir)
			} else {
				say("cannot unmount %s (%v) or remount it read-only (%v)", m.dir, err, rerr)
			}
		}
	}
	linux.sync()
	if err := linux.mount(nil, "/", nil, {.REMOUNT, .RDONLY}, nil); err != .NONE {
		say("cannot remount / read-only (%v); synced anyway", err)
	} else {
		say("/ remounted read-only")
	}
}
