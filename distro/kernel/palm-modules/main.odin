package main

// palm-modules: loads kernel modules, the part of kmod and udev Palmy
// needs.
//
//	palm-modules coldplug        load a driver for every device already in /sys
//	palm-modules watch           coldplug, then do the same for every device
//	                             the kernel announces later (the `modules`
//	                             service)
//	palm-modules load NAME...    load modules by name or alias, with what they
//	                             need (modprobe)
//	palm-modules -q -- NAME      how the kernel itself asks for a module
//	                             (CONFIG_MODPROBE_PATH points here)
//	palm-modules lookup ALIAS... print the modules a name or modalias means
//
//	--dir DIR    the index to use instead of /usr/lib/modules/$(uname -r)
//	--dry-run    say what would be loaded, load nothing
//	--verbose    coldplug: say how many devices and modules (it is quiet
//	             otherwise, being palm-init's early hook)
//
//	modprobe [-abq] [--] NAME... is `load`, when installed as modprobe (or
//	given those options): palm-init runs `modprobe -b -q <MODALIAS>` for
//	every device the kernel adds.
//
// coldplug first loads what /usr/lib/modules-load.d/*.conf and
// /etc/modules-load.d/*.conf name, one module per line.
//
// Every device the kernel knows has a `modalias` file in /sys, such as
// pci:v00008086d0000A7A0sv...bc03sc00i00 for an Intel GPU; depmod's
// modules.alias says which module claims it (index.odin). Loading is one
// finit_module(2) per module: the kernel decompresses the .ko.zst itself
// (CONFIG_MODULE_DECOMPRESS) and reads any firmware the driver asks for
// straight from /usr/lib/firmware, so nothing else is needed in userspace.
//
// Coldplug loops: a loaded driver can make new devices (an I2C controller
// finds a touchpad, a USB hub finds a keyboard), so /sys is walked again
// until a walk finds no modalias it has not already seen. `watch` opens the
// kernel's uevent socket before its coldplug, so a device that appears in
// between is seen once rather than never.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

MODULE_INIT_COMPRESSED_FILE :: 4

State :: struct {
	ix:      Index,
	dry_run: bool,
	quiet:   bool,
	verbose: bool,
	blacklist_names: bool, // -b: a blacklisted module is not loaded even by name
	loaded:  map[string]bool, // tried this run, whatever the outcome
	count:   int, // newly inserted
	failed:  int,
}

st: State

main :: proc() {
	args := os.args[1:]
	dir := ""
	cmd := ""
	names: [dynamic]string
	modprobe_style := strings.has_suffix(os.args[0], "modprobe")
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--dir" && i + 1 < len(args):
			i += 1
			dir = args[i]
		case a == "--dry-run":
			st.dry_run = true
		case a == "--quiet":
			st.quiet = true
		case a == "--verbose":
			st.verbose = true
		case a == "--":
			// Everything after is a name, even if it starts with '-'.
			modprobe_style = true
			for n in args[i + 1:] {append(&names, n)}
			i = len(args)
		case a == "-h" || a == "--help":
			usage(0)
		case a == "--selftest":
			os.exit(selftest())
		case len(a) > 1 && a[0] == '-' && a[1] != '-':
			// modprobe's short options, as kmod and palm-init use them:
			// -q quiet, -b apply the blacklist to names too, -a every
			// argument is a module (the default here anyway).
			modprobe_style = true
			for c in a[1:] {
				switch c {
				case 'q':
					st.quiet = true
				case 'b':
					st.blacklist_names = true
				case 'a', 'v':
				case:
					fmt.eprintfln("palm-modules: unknown option -%c", c)
					usage(2)
				}
			}
		case cmd == "" && !modprobe_style && (a == "coldplug" || a == "watch" || a == "load" || a == "lookup"):
			cmd = a
		case strings.has_prefix(a, "-") && !modprobe_style:
			fmt.eprintfln("palm-modules: unknown option %s", a)
			usage(2)
		case:
			append(&names, a)
		}
	}
	if cmd == "" {
		if len(names) == 0 {usage(2)}
		cmd = "load"
	}

	if dir == "" {
		uts: linux.UTS_Name
		linux.uname(&uts)
		dir = join("/usr/lib/modules", string(cstring(&uts.release[0])))
	}
	ix, ok := index_load(dir)
	if !ok {
		// No modules for this kernel: nothing to load, which for coldplug
		// is not an error (an older kernel, or one with everything built in).
		if cmd == "coldplug" || cmd == "watch" {
			say("no module index in %s; nothing to load", dir)
			if cmd == "watch" {sleep_forever()}
			os.exit(0)
		}
		fmt.eprintfln("palm-modules: no module index in %s", dir)
		os.exit(1)
	}
	st.ix = ix

	switch cmd {
	case "lookup":
		for n in names {
			mods, builtin := lookup(&st.ix, n)
			if builtin {
				fmt.printfln("%s: built in", n)
			} else if len(mods) == 0 {
				fmt.printfln("%s: no module", n)
			} else {
				fmt.printfln("%s: %s", n, strings.join(mods[:], " ", context.temp_allocator))
			}
		}
	case "load":
		bad := 0
		for n in names {
			mods, builtin := lookup(&st.ix, n)
			if builtin {continue}
			if len(mods) == 0 {
				if !st.quiet {fmt.eprintfln("palm-modules: no module %s in %s", n, dir)}
				bad += 1
				continue
			}
			by_alias := !(module_name(n, context.temp_allocator) in st.ix.paths)
			for m in mods {
				if (by_alias || st.blacklist_names) && m in st.ix.blacklist {continue}
				if !load(m) {bad += 1}
			}
		}
		os.exit(1 if bad > 0 else 0)
	case "coldplug":
		// As palm-init's early hook it should be quiet unless something
		// failed (distro/notes/init.md); --verbose says what it did.
		devices := coldplug()
		if st.verbose || st.failed > 0 {
			say("%d device(s) with a modalias, %d module(s) loaded%s", devices, st.count, failed_note())
		}
	case "watch":
		sock := uevent_open()
		devices := coldplug()
		say("%d device(s) with a modalias, %d module(s) loaded%s; watching for new devices", devices, st.count, failed_note())
		if sock < 0 {sleep_forever()}
		watch(sock)
	}
}

usage :: proc(code: int) {
	fmt.eprintln("usage: palm-modules coldplug | watch | load NAME... | lookup NAME... [--dir DIR] [--dry-run]")
	os.exit(code)
}

failed_note :: proc() -> string {
	if st.failed == 0 {return ""}
	return fmt.tprintf(", %d failed", st.failed)
}

// load inserts one module after everything it needs; true if it is in the
// kernel afterwards (or would be, in a dry run).
load :: proc(name: string) -> bool {
	if name in st.loaded {return true}
	st.loaded[name] = true
	if name in st.ix.builtin {return true}
	for p in st.ix.pre[name] {load(p)}
	deps := st.ix.deps[name]
	for i := len(deps) - 1; i >= 0; i -= 1 {
		d := deps[i]
		if d in st.loaded {continue}
		st.loaded[d] = true
		if !insert(d) {
			report_failure(name, fmt.tprintf("needs %s, which failed", d))
			return false
		}
	}
	ok := insert(name)
	for p in st.ix.post[name] {load(p)}
	return ok
}

report_failure :: proc(name, why: string) {
	st.failed += 1
	if !st.quiet {fmt.eprintfln("palm-modules: %s: %s", name, why)}
}

// insert is one finit_module(2). EEXIST (already loaded, or being loaded by
// someone else right now) counts as success.
insert :: proc(name: string) -> bool {
	if is_loaded(name) {return true}
	rel, has := st.ix.paths[name]
	if !has {
		report_failure(name, "not in modules.dep")
		return false
	}
	path := join(st.ix.dir, rel)
	if st.dry_run {
		fmt.printfln("would load %s", path)
		st.count += 1
		return true
	}
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if err != .NONE {
		report_failure(name, fmt.tprintf("cannot open %s (%v)", path, err))
		return false
	}
	defer linux.close(fd)
	params := strings.clone_to_cstring(st.ix.options[name] or_else "", context.temp_allocator)
	flags := 0
	if !strings.has_suffix(rel, ".ko") {flags = MODULE_INIT_COMPRESSED_FILE}
	ret := linux.syscall(linux.SYS_finit_module, fd, rawptr(params), flags)
	switch {
	case ret == 0:
		st.count += 1
		return true
	case linux.Errno(-ret) == .EEXIST:
		return true
	case:
		// ENODEV and friends: a driver that matched an alias but found no
		// hardware it supports. Common, harmless, and kmod is quiet too.
		e := linux.Errno(-ret)
		if e == .ENODEV || e == .ENXIO {return false}
		report_failure(name, fmt.tprintf("%v", e))
		return false
	}
}

is_loaded :: proc(name: string) -> bool {
	_, ok := read_file(fmt.tprintf("/sys/module/%s/initstate", name), context.temp_allocator)
	return ok
}

// coldplug loads modules for the devices in /sys until a walk finds nothing
// new; it returns how many distinct modaliases it saw.
coldplug :: proc() -> int {
	load_listed()
	seen := make(map[string]bool)
	for pass in 0 ..< 8 {
		found := make([dynamic]string, context.temp_allocator)
		walk_modaliases("/sys/devices", &found, 0)
		fresh := 0
		for alias in found {
			if alias in seen {continue}
			seen[strings.clone(alias)] = true
			fresh += 1
			load_for_alias(alias)
		}
		free_all(context.temp_allocator)
		if fresh == 0 || st.dry_run {break}
		_ = pass
	}
	return len(seen)
}

// load_listed loads the modules named in modules-load.d, one per line, for
// what no device announces (a filesystem, a protocol, a tunnel).
load_listed :: proc() {
	for dir in ([]string{"/usr/lib/modules-load.d", "/etc/modules-load.d"}) {
		names, _ := list_dir(dir)
		for name in names {
			if !strings.has_suffix(name, ".conf") {continue}
			text, ok := read_file(join(dir, name, context.temp_allocator), context.temp_allocator)
			if !ok {continue}
			for line in strings.split_lines_iterator(&text) {
				l := strings.trim_space(line)
				if l == "" || l[0] == '#' || l[0] == ';' {continue}
				mods, builtin := lookup(&st.ix, l)
				if len(mods) == 0 && !builtin {
					report_failure(l, fmt.tprintf("named in %s/%s, but there is no such module", dir, name))
				}
				for m in mods {load(m)}
			}
		}
	}
}

load_for_alias :: proc(alias: string) {
	mods, _ := lookup(&st.ix, alias)
	for m in mods {
		if m in st.ix.blacklist {continue}
		load(m)
	}
}

// walk_modaliases collects the contents of every `modalias` file below dir,
// not following symlinks (sysfs is full of links back up the tree).
walk_modaliases :: proc(dir: string, out: ^[dynamic]string, depth: int) {
	if depth > 32 {return}
	fd, err := linux.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY, .CLOEXEC})
	if err != .NONE {return}
	defer linux.close(fd)
	buf: [8192]u8
	for {
		n, derr := linux.getdents(fd, buf[:])
		if derr != .NONE || n <= 0 {break}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {continue}
			#partial switch d.type {
			case .DIR:
				walk_modaliases(join(dir, name, context.temp_allocator), out, depth + 1)
			case .REG:
				if name != "modalias" {continue}
				text, ok := read_file(join(dir, name, context.temp_allocator), context.temp_allocator)
				text = strings.trim_space(text)
				if ok && text != "" {append(out, text)}
			}
		}
	}
}

AF_NETLINK :: 16
NETLINK_KOBJECT_UEVENT :: 15
SOCK_DGRAM :: 2
SOCK_CLOEXEC :: 0o2000000

Sockaddr_Nl :: struct {
	family: u16,
	pad:    u16,
	pid:    u32,
	groups: u32,
}

// uevent_open subscribes to the kernel's uevent broadcast, as palm-init does
// for device permissions; both get every message.
uevent_open :: proc() -> linux.Fd {
	ret := linux.syscall(linux.SYS_socket, AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT)
	if ret < 0 {
		say("cannot open a uevent socket (errno %d); devices added later get no driver", -ret)
		return -1
	}
	fd := linux.Fd(ret)
	addr := Sockaddr_Nl{family = AF_NETLINK, groups = 1}
	if r := linux.syscall(linux.SYS_bind, fd, &addr, size_of(Sockaddr_Nl)); r < 0 {
		say("cannot bind the uevent socket (errno %d)", -r)
		linux.close(fd)
		return -1
	}
	size: i32 = 1 << 20
	linux.syscall(linux.SYS_setsockopt, fd, 1 /*SOL_SOCKET*/, 33 /*SO_RCVBUFFORCE*/, &size, size_of(i32))
	return fd
}

// watch loads a module for every "add" uevent that carries a MODALIAS.
watch :: proc(sock: linux.Fd) {
	buf: [8192]u8
	for {
		n := linux.syscall(linux.SYS_recvfrom, sock, &buf[0], len(buf), 0, 0, 0)
		if n <= 0 {
			if linux.Errno(-n) == .ENOBUFS {
				// Messages were dropped: catch up with a walk.
				coldplug()
			}
			continue
		}
		text := string(buf[:n])
		if strings.has_prefix(text, "libudev") {continue}
		action, alias := "", ""
		for part in strings.split_iterator(&text, "\x00") {
			if strings.has_prefix(part, "ACTION=") {action = part[7:]}
			if strings.has_prefix(part, "MODALIAS=") {alias = part[9:]}
		}
		if action != "add" || alias == "" {continue}
		before := st.count
		// A device can come back after a module was unloaded: try again.
		clear(&st.loaded)
		load_for_alias(alias)
		if st.count > before {say("%s: loaded %d module(s)", alias, st.count - before)}
		free_all(context.temp_allocator)
	}
}

sleep_forever :: proc() {
	for {
		ts := linux.Time_Spec{time_sec = 3600}
		linux.nanosleep(&ts, nil)
	}
}

say :: proc(format: string, args: ..any) {
	fmt.printfln("palm-modules: %s", fmt.tprintf(format, ..args))
}

join :: proc(a, b: string, allocator := context.allocator) -> string {
	if strings.has_suffix(a, "/") {return strings.concatenate({a, b}, allocator)}
	return strings.concatenate({a, "/", b}, allocator)
}

read_file :: proc(path: string, allocator := context.allocator) -> (text: string, ok: bool) {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if err != .NONE {return "", false}
	defer linux.close(fd)
	buf := make([dynamic]u8, 0, 4096, allocator)
	chunk: [65536]u8
	for {
		n, rerr := linux.read(fd, chunk[:])
		if rerr == .EINTR {continue}
		if rerr != .NONE {
			delete(buf)
			return "", false
		}
		if n == 0 {break}
		append(&buf, ..chunk[:n])
	}
	return string(buf[:]), true
}

list_dir :: proc(path: string) -> (names: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.DIRECTORY, .CLOEXEC})
	if err != .NONE {return names, false}
	defer linux.close(fd)
	buf: [8192]u8
	for {
		n, derr := linux.getdents(fd, buf[:])
		if derr != .NONE || n <= 0 {break}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {continue}
			append(&names, strings.clone(name, context.temp_allocator))
		}
	}
	return names, true
}
