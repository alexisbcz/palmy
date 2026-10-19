package main

// `palm-init --selftest` checks every parser palm-init trusts at boot against
// inputs written out here, so a mistake shows up on the build host rather than
// as a machine that will not start its login screen:
//
//	service files      keys, defaults, inline comments, repeated env, errors
//	passwd / group     fields, members, initgroups' answer
//	kernel cmdline     palm.single, palm.autologin, quoted values
//	uevents            a real kernel datagram, a libudev one, garbage
//	device rules       which /dev names get which group and mode
//	locale.conf        which variables services get from /etc/locale.conf
//	mask               /etc/palm/services.off/<name> masks a service
//	reload             SIGHUP's decisions: start, change, stop, keep, errors
//	fstab              lines, octal escapes, mount options to flags + data
//	probe              ext4 / FAT16 / FAT32 / swap superblocks, tags
//	zram               /etc/palm/zram, the size, the swap header
//	GPT                CRC32, growing the last partition, both headers
//	hooks              early.d merging, masking and order
//
// It touches nothing on the machine and needs no privileges.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

failures := 0

check :: proc(name: string, ok: bool, detail := "") {
	fmt.printfln("%s  %-52s  %s", ok ? "pass" : "FAIL", name, detail)
	if !ok {failures += 1}
}

selftest :: proc() -> int {
	// --- service files ------------------------------------------------------
	{
		s, err := parse_service("palm-login", `
# the login manager
cmd     = /usr/bin/palm-login --verbose     # required
user    = root
restart = always
after   = network
env     = COLOR=#fff
env     = LANG=C.UTF-8
`)
		check("service: parses", err == "", err)
		check("service: cmd split on spaces", len(s.cmd) == 2 && s.cmd[0] == "/usr/bin/palm-login" && s.cmd[1] == "--verbose", fmt.tprint(s.cmd))
		check("service: after", s.after == "network")
		check("service: '#' inside a value is kept", len(s.env) == 2 && s.env[0] == "COLOR=#fff", fmt.tprint(s.env[:]))
		check("service: env is repeatable", len(s.env) == 2 && s.env[1] == "LANG=C.UTF-8")
	}
	{
		s, err := parse_service("getty", "cmd = /sbin/getty -L 115200 ttyS0 vt100\ntty = /dev/ttyS0\nrestart=never\n")
		check("service: defaults and no spaces round '='", err == "" && s.user == "root" && s.restart == .Never && s.tty == "/dev/ttyS0", err)
		check("service: default restart is always", func_default_restart())
	}
	{
		_, err := parse_service("bad", "user = palm\n")
		check("service: missing cmd is an error", err == "no cmd", err)
		_, err = parse_service("bad", "cmd = /bin/true\nrestrat = never\n")
		check("service: unknown key is an error", strings.contains(err, "unknown key"), err)
		_, err = parse_service("bad", "cmd = /bin/true\nrestart = sometimes\n")
		check("service: bad restart value is an error", strings.contains(err, "restart must be"), err)
		_, err = parse_service("bad", "cmd = /bin/true\nenv = NOEQUALS\n")
		check("service: env without '=' is an error", strings.contains(err, "env must be"), err)
		_, err = parse_service("bad", "cmd /bin/true\n")
		check("service: a line without '=' is an error", strings.contains(err, "line 1"), err)
	}

	// --- passwd / group -----------------------------------------------------
	{
		users := parse_passwd(`root:x:0:0:root:/root:/bin/sh
palm:x:1000:1000:Palm:/home/palm:/bin/sh
greeter:x:900:900:greeter:/var/lib/greeter:/sbin/nologin
broken:line
nobody:x:notanumber:65534::/:/sbin/nologin
`)
		check("passwd: well-formed lines only", len(users) == 3, fmt.tprint(len(users)))
		u, ok := find_user(users, "palm")
		check("passwd: palm", ok && u.uid == 1000 && u.gid == 1000 && u.home == "/home/palm" && u.shell == "/bin/sh")
		_, ok = find_user(users, "nobody")
		check("passwd: a bad uid is skipped", !ok)

		groups := parse_group(`root:x:0:root
tty:x:5:
wheel:x:10:palm
audio:x:63:palm
video:x:39:palm,greeter
input:x:97: palm , greeter
greeter:x:900:
palm:x:1000:
`)
		check("group: parses all lines", len(groups) == 8, fmt.tprint(len(groups)))
		gids := user_groups(groups, "palm", 1000)
		check("group: initgroups for palm", slice_eq(gids, {1000, 10, 63, 39, 97}), fmt.tprint(gids))
		gids = user_groups(groups, "greeter", 900)
		check("group: initgroups for greeter", slice_eq(gids, {900, 39, 97}), fmt.tprint(gids))
		gids = user_groups(groups, "root", 0)
		check("group: primary group is not repeated", slice_eq(gids, {0}), fmt.tprint(gids))
		gid, gok := find_group_gid(groups, "video")
		check("group: lookup by name", gok && gid == 39)
	}

	// --- kernel command line ------------------------------------------------
	{
		c := parse_cmdline("BOOT_IMAGE=/boot/vmlinuz root=/dev/vda2 ro console=ttyS0 palm.autologin=palm quiet\n")
		check("cmdline: autologin", c.autologin == "palm" && !c.single, c.autologin)
		c = parse_cmdline("console=ttyS0 palm.single")
		check("cmdline: single", c.single && c.autologin == "")
		parts := cmdline_split(`a=1 b="two words" "c=3"  d`)
		check("cmdline: quotes group words", len(parts) == 4 && parts[1] == "b=two words" && parts[2] == "c=3", fmt.tprint(parts))
		c = parse_cmdline("palm.singleuser palm.autologin")
		check("cmdline: near-misses are not matched", !c.single && c.autologin == "")
	}

	// --- uevents -------------------------------------------------------------
	{
		msg := "add@/devices/pci0000:00/0000:00:02.0/drm/card0\x00ACTION=add\x00DEVPATH=/devices/pci0000:00/0000:00:02.0/drm/card0\x00SUBSYSTEM=drm\x00DEVNAME=dri/card0\x00DEVTYPE=drm_minor\x00MAJOR=226\x00MINOR=0\x00SEQNUM=1234\x00"
		ev, ok := parse_uevent(transmute([]u8)msg)
		check("uevent: kernel add", ok && ev.action == "add" && ev.subsystem == "drm" && ev.devname == "dri/card0" && strings.has_suffix(ev.devpath, "card0"), fmt.tprint(ev))
		msg = "remove@/devices/virtual/input/input5/event5\x00ACTION=remove\x00SUBSYSTEM=input\x00DEVNAME=input/event5\x00"
		ev, ok = parse_uevent(transmute([]u8)msg)
		check("uevent: kernel remove", ok && ev.action == "remove" && ev.devname == "input/event5")
		msg = "add@/devices/virtual/net/lo\x00ACTION=add\x00SUBSYSTEM=net\x00INTERFACE=lo\x00"
		ev, ok = parse_uevent(transmute([]u8)msg)
		check("uevent: no DEVNAME for a netdev", ok && ev.devname == "")
		msg = "libudev\x00\xfe\xed\xca\xfe junk"
		_, ok = parse_uevent(transmute([]u8)msg)
		check("uevent: libudev messages are refused", !ok)
		_, ok = parse_uevent(transmute([]u8)string("not a uevent"))
		check("uevent: garbage is refused", !ok)
	}

	// --- device rules ----------------------------------------------------------
	{
		Case :: struct {
			name:  string,
			group: string,
			mode:  u32,
		}
		cases := []Case {
			{"dri/card0", "video", 0o660},
			{"dri/renderD128", "video", 0o660},
			{"input/event0", "input", 0o660},
			{"input/mice", "", 0},
			{"input/mouse0", "", 0},
			{"snd/controlC0", "audio", 0o660},
			{"tty1", "tty", 0o620},
			{"tty63", "tty", 0o620},
			{"tty", "", 0},
			{"ttyS0", "", 0},
			{"console", "", 0},
		}
		for c in cases {
			rule, ok := device_rule(c.name)
			want_ok := c.group != ""
			good := ok == want_ok && (!ok || (rule.group == c.group && rule.mode == c.mode))
			check(fmt.tprintf("device rule: %s", c.name), good, ok ? fmt.tprintf("%s %o", rule.group, rule.mode) : "no rule")
		}
	}

	// --- /etc/locale.conf ------------------------------------------------------
	{
		env := parse_locale_conf(`# written by palm-install
LANG="fr_FR.UTF-8"
LANGUAGE=fr:en
PATH=/tmp/evil
LC_TIME=has space
export LC_MESSAGES='de_DE.UTF-8'
`, context.temp_allocator)
		check(
			"locale.conf: LANG, LANGUAGE, LC_*, quotes stripped",
			len(env) == 3 && env[0] == "LANG=fr_FR.UTF-8" && env[1] == "LANGUAGE=fr:en" && env[2] == "LC_MESSAGES=de_DE.UTF-8",
			fmt.tprint(env),
		)
		again := parse_locale_conf("LANG=C.UTF-8\nLANG=ja_JP.UTF-8\n", context.temp_allocator)
		check("locale.conf: the last LANG wins", len(again) == 1 && again[0] == "LANG=ja_JP.UTF-8", fmt.tprint(again))
		check("locale.conf: empty file, nothing exported", len(parse_locale_conf("", context.temp_allocator)) == 0)
	}

	// --- helpers ---------------------------------------------------------------
	// --- masks (/etc/palm/services.off) ---------------------------------------
	{
		dir := "/tmp/palm-init-selftest-mask"
		mkdir_p(dir)
		write_file(strings.concatenate({dir, "/palm-login"}, context.temp_allocator), "")
		check("mask: a file in the mask directory masks its service", masked("palm-login", dir))
		check("mask: other services are not masked", !masked("getty-ttyS0", dir))
		linux.unlink(strings.clone_to_cstring(strings.concatenate({dir, "/palm-login"}, context.temp_allocator), context.temp_allocator))
		linux.rmdir(strings.clone_to_cstring(dir, context.temp_allocator))
		check("mask: no mask directory, nothing masked", !masked("palm-login", dir))
	}

	selftest_reload()
	selftest_fstab()
	selftest_probe()
	selftest_zram()
	selftest_gpt()
	selftest_hooks()
	{
		msg := "add@/devices/pci0000:00/0000:00:04.0/usb1/1-1\x00ACTION=add\x00SUBSYSTEM=usb\x00MODALIAS=usb:v0627p0001d0000dc00dsc00dp00ic03isc01ip01in00\x00"
		ev, ok := parse_uevent(transmute([]u8)msg)
		check("uevent: MODALIAS is read (for modprobe)", ok && strings.has_prefix(ev.modalias, "usb:v0627p0001"), ev.modalias)
	}

	check("trim_comment: leading #", trim_comment("# all comment") == "")
	check("split_fields: runs of blanks", len(split_fields("  a \t b  ")) == 2)

	fmt.println(strings.repeat("-", 72, context.temp_allocator))
	if failures == 0 {
		fmt.println("selftest: all passed")
		return 0
	}
	fmt.printfln("selftest: %d failed", failures)
	return 1
}

@(private = "file")
func_default_restart :: proc() -> bool {
	s, err := parse_service("x", "cmd = /bin/true")
	return err == "" && s.restart == .Always && s.user == "root"
}

@(private = "file")
slice_eq :: proc(a: []u32, b: []u32) -> bool {
	if len(a) != len(b) {return false}
	for v, i in a {
		if v != b[i] {return false}
	}
	return true
}
