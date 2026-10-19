package palm_install

// palm-install — install Palmy from the command line.
//
// The text front end of install_core (distro/installer/core): everything the
// graphical installer can do, from a serial console or a script. It builds
// the same Plan, asks the same validate(), and runs the same install(), so
// testing one tests the engine of both.
//
//	palm-install                  (on a terminal: asks the questions, interactive.odin)
//	palm-install --disk /dev/vdb --user alex --password-file - --timezone Europe/Paris --yes
//	palm-install --answers install.conf --yes --json
//	palm-install --list-disks | --list-layouts | --list-zones | --list-languages [--json]
//
// It erases a whole disk, so it refuses unless --yes is given, after
// printing what it is about to do; --dry-run shows every step and command
// and changes nothing. --json turns progress into one JSON object per line,
// for a program reading it.
//
// --disk-image FILE is the test path: the "disk" is a plain file (never
// /dev/*), partitioned and formatted in place, and the system is built into
// --target as an ordinary directory. With --efivars DIR the UEFI entry is
// written into a directory standing in for efivarfs. That is how the
// installer is exercised on a build host, without root and without going
// near the host's disks or firmware.
//
// Exit codes follow palm's: 0 ok, 2 usage, 3 not found, 4 refused (invalid
// plan, no --yes, not root), 7 failed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import core "install:core"

VERSION :: "0.1.0"

EXIT_OK :: 0
EXIT_USAGE :: 2
EXIT_NOT_FOUND :: 3
EXIT_REFUSED :: 4
EXIT_FAILED :: 7

USAGE :: `usage: palm-install [options]
       palm-install [--interactive]     ask each question on this terminal

install Palmy on a disk, erasing it (GPT: 512 MiB ESP + ext4 root, and a
BIOS boot partition so the disk starts under UEFI and under a BIOS)

  --disk <dev>                  the disk to erase, e.g. /dev/vda
  --language <ll_CC>            fr_FR (default en_US)
  --keyboard <layout[:variant]> fr, de:nodeadkeys (default us)
  --timezone <Region/City>      Europe/Paris (default UTC)
  --hostname <name>             (default palmy)
  --user <name>                 the account to create (required)
  --full-name <text>
  --password-file <file|->      the user's password, first line; - = stdin
  --root-password-file <file|-> root's password (default: the user's)
  --repo <path|url>             (default file:///usr/share/palm/repo)
  --package <name>              repeatable (default palmy)
  --swap <size>                 a swap file on the root: 2G, 512M (default none)
  --no-efi-entry                do not write a UEFI Boot#### variable
  --no-bios-boot                do not install limine's BIOS boot code
  --no-firmware                 install no firmware (default: linux-firmware,
                                or the parts of it the repository carries)
  --answers <file>              key = value lines with the same names as the
                                options (password = ... allowed); options win
  --yes                         really do it
  --dry-run                     show the steps and commands, change nothing
  --json                        progress as JSON lines
  --verbose                     print the log as it is written

  --list-disks | --list-layouts | --list-zones | --list-languages

test paths (build host):
  --disk-image <file>           partition and format a plain file; implies
                                --target and no mounting
  --target <dir>                where the system is built (default /mnt/target)
  --steps <a,b,...>             only these of partition,format,mount,packages,
                                configure,bootloader,unmount
  --efivars <dir>               a directory standing in for efivarfs
  --palm <path> --keys-dir <dir> --limine-dir <dir> --limine-tool <path> --log <file>
  --selftest | --version | --help
`

Args :: struct {
	plan:          core.Plan,
	opts:          core.Options,
	packages:      [dynamic]string,
	password_file: string,
	root_pw_file:  string,
	yes:           bool,
	json:          bool,
	verbose:       bool,
	target_given:  bool,
	efi_given:     bool,
	list:          string,
}

g_json := false

main :: proc() {
	os.exit(run(os.args[1:]))
}

run :: proc(argv: []string) -> int {
	a := Args {
		plan = core.default_plan(),
		opts = core.default_options(),
	}
	if len(argv) == 0 && is_terminal(os.stdin) {
		return interactive(&a)
	}
	if len(argv) == 1 {
		switch argv[0] {
		case "--interactive":
			return interactive(&a)
		case "--selftest":
			return selftest()
		case "--version":
			fmt.println("palm-install", VERSION)
			return EXIT_OK
		case "--help", "-h", "help":
			fmt.print(USAGE)
			return EXIT_OK
		}
	}

	// Pairs first, so --answers can be applied underneath the options
	// wherever it appears on the line.
	Pair :: struct {
		key, val: string,
		has_val:  bool,
	}
	pairs := make([dynamic]Pair)
	answers := ""
	for i := 0; i < len(argv); i += 1 {
		arg := argv[i]
		if !strings.has_prefix(arg, "--") {
			return usage_error("unexpected argument %q", arg)
		}
		key := arg[2:]
		val := ""
		has := false
		if eq := strings.index_byte(key, '='); eq >= 0 {
			key, val, has = key[:eq], key[eq + 1:], true
		} else if takes_value(key) {
			if i + 1 >= len(argv) {
				return usage_error("--%s needs a value", key)
			}
			i += 1
			val, has = argv[i], true
		}
		if key == "answers" {
			answers = val
			continue
		}
		append(&pairs, Pair{key, val, has})
	}
	for p in pairs {
		if p.key == "json" {
			a.json = true
			g_json = true
		}
	}

	if answers != "" {
		data, err := os.read_entire_file_from_path(answers, context.allocator)
		if err != nil {
			return fail_code(EXIT_NOT_FOUND, "cannot read %s: %v", answers, err)
		}
		for raw, n in strings.split_lines(string(data)) {
			line := strings.trim_space(raw)
			if line == "" || line[0] == '#' {continue}
			eq := strings.index_byte(line, '=')
			if eq < 0 {
				return usage_error("%s:%d: expected key = value", answers, n + 1)
			}
			key := strings.trim_space(line[:eq])
			val := strings.trim_space(line[eq + 1:])
			if code := apply(&a, key, val, true, true); code != EXIT_OK {
				return code
			}
		}
	}
	cli_packages := false
	for p in pairs {
		if p.key == "package" && !cli_packages {
			clear(&a.packages) // options replace the answers file's list
			cli_packages = true
		}
		if code := apply(&a, p.key, p.val, p.has_val, false); code != EXIT_OK {
			return code
		}
	}

	switch a.list {
	case "disks": return list_disks(a.json)
	case "layouts": return list_layouts(a.json)
	case "zones": return list_zones(a.json)
	case "languages": return list_languages(a.json)
	}

	if len(a.packages) > 0 {
		a.plan.packages = a.packages[:]
	}
	if a.opts.disk_image && !a.efi_given {
		a.plan.efi_boot_entry = false
	}
	if a.opts.disk_image && !a.target_given && a.opts.steps != {} && a.opts.steps - {.Partition, .Format} == {} {
		// partition/format only: no target needed
	} else if a.opts.disk_image && !a.target_given {
		return usage_error("--disk-image needs --target <dir> to build the system in")
	}

	// Passwords: from files or stdin, never from the command line, where
	// every user on the machine could read them in /proc.
	if a.password_file != "" {
		pw, code := read_secret(a.password_file, "password")
		if code != EXIT_OK {return code}
		a.plan.password = pw
	}
	if a.root_pw_file != "" {
		pw, code := read_secret(a.root_pw_file, "root password")
		if code != EXIT_OK {return code}
		a.plan.root_password = pw
	}

	if code := check_plan(&a); code != EXIT_OK {
		return code
	}
	if !a.json {
		print_summary(&a)
	}
	return install(&a)
}

// check_plan validates the whole plan for a full install, the relevant part
// for a test run that only does some steps, and prints the problems.
check_plan :: proc(a: ^Args) -> int {
	partial := a.opts.steps != {} && a.opts.steps != ~bit_set[core.Step]{}
	problems := core.validate_messages(a.plan, a.opts)
	relevant := problems
	if partial {
		relevant = filter_problems(problems, a.opts.steps)
	}
	if len(relevant) == 0 {
		return EXIT_OK
	}
	if a.json {
		// "problems" are the English sentences, as before; "codes" the
		// stable names of the same problems, in the same order.
		fmt.printf("{{\"event\":\"invalid\",\"problems\":[")
		for p, i in relevant {
			fmt.printf("%s%s", i > 0 ? "," : "", json_str(core.message_text(p)))
		}
		fmt.printf("],\"codes\":[")
		for p, i in relevant {
			fmt.printf("%s%s", i > 0 ? "," : "", json_str(core.message_code(p.id)))
		}
		fmt.println("]}")
	} else {
		fmt.eprintln("palm-install: the plan is not valid:")
		for p in relevant {
			fmt.eprintf("  - %s\n", core.message_text(p))
		}
	}
	return EXIT_REFUSED
}

// install asks for --yes (unless dry), then runs the plan.
install :: proc(a: ^Args) -> int {
	if !a.opts.dry_run {
		if !a.yes {
			return fail_code(EXIT_REFUSED, "refusing to erase %s without --yes", a.plan.disk)
		}
		if !a.opts.disk_image && linux.geteuid() != 0 && (a.opts.steps == {} || a.opts.steps & {.Partition, .Format, .Mount, .Unmount} != {}) {
			return fail_code(EXIT_REFUSED, "installing to a disk needs root")
		}
	}

	if a.verbose || a.opts.dry_run {
		a.opts.on_log = proc(line: string, user: rawptr) {
			if g_json {
				fmt.printf("{{\"event\":\"log\",\"line\":%s}}\n", json_str(line))
			} else {
				fmt.printf("    %s\n", line)
			}
		}
	}
	ok2, err := core.install_with(a.plan, a.opts, on_progress, a)
	if a.json {
		if ok2 {
			fmt.println("{\"event\":\"done\",\"ok\":true}")
		} else {
			fmt.printf("{{\"event\":\"done\",\"ok\":false,\"code\":%d,\"error\":%s}}\n", EXIT_FAILED, json_str(err))
		}
	} else {
		if ok2 {
			if a.opts.dry_run {
				fmt.println("palm-install: dry run finished; nothing was changed")
			} else {
				fmt.println("palm-install: Palmy is installed. Remove the installation medium and restart.")
			}
		} else {
			fmt.eprintf("palm-install: %s\n", err)
		}
	}
	return ok2 ? EXIT_OK : EXIT_FAILED
}

takes_value :: proc(key: string) -> bool {
	switch key {
	case "disk", "disk-image", "language", "keyboard", "timezone", "hostname", "user", "full-name",
	     "password-file", "root-password-file", "repo", "package", "answers", "target", "steps",
	     "efivars", "palm", "keys-dir", "limine-dir", "limine-tool", "log", "swap":
		return true
	}
	return false
}

// apply sets one option. `from_answers` also allows the keys that may only
// appear in an answers file (password, root-password).
apply :: proc(a: ^Args, key, val: string, has_val: bool, from_answers: bool) -> int {
	yes_no :: proc(v: string) -> (bool, bool) {
		switch strings.to_lower(v, context.temp_allocator) {
		case "", "yes", "true", "1", "on": return true, true
		case "no", "false", "0", "off": return false, true
		}
		return false, false
	}
	switch key {
	case "disk": a.plan.disk = val
	case "disk-image":
		a.plan.disk = val
		a.opts.disk_image = true
	case "language": a.plan.language = val
	case "keyboard":
		if i := strings.index_byte(val, ':'); i >= 0 {
			a.plan.keyboard = {layout = val[:i], variant = val[i + 1:]}
		} else {
			a.plan.keyboard = {layout = val}
		}
	case "timezone": a.plan.timezone = val
	case "hostname": a.plan.hostname = val
	case "user": a.plan.user = val
	case "full-name": a.plan.full_name = val
	case "password-file": a.password_file = val
	case "root-password-file": a.root_pw_file = val
	case "repo": a.plan.repo = val
	case "package":
		append(&a.packages, val)
	case "packages":
		for f in strings.fields(val) {append(&a.packages, f)}
	case "swap":
		n, ok := parse_size(val)
		if !ok {return usage_error("--swap: %s", core.message_text(core.msg(.Swap_Invalid, val)))}
		a.plan.swap_bytes = n
	case "no-bios-boot": a.opts.no_bios_boot = true
	case "no-firmware": a.plan.no_firmware = true
	case "limine-tool": a.opts.limine_tool = val
	case "no-efi-entry":
		a.plan.efi_boot_entry = false
		a.efi_given = true
	case "efi-entry":
		v, ok := yes_no(val)
		if !ok {return usage_error("efi-entry: expected yes or no, got %q", val)}
		a.plan.efi_boot_entry = v
		a.efi_given = true
	case "target":
		a.opts.target = val
		a.target_given = true
	case "steps":
		a.opts.steps = {}
		for s in strings.split(val, ",") {
			found := false
			for st in core.Step {
				if core.step_name(st) == strings.trim_space(s) && st != .Done {
					a.opts.steps += {st}
					found = true
				}
			}
			if !found {return usage_error("unknown step %q", s)}
		}
	case "efivars":
		a.opts.efivars = val
		if !a.efi_given {a.plan.efi_boot_entry = true}
	case "palm": a.opts.palm = val
	case "keys-dir": a.opts.keys_dir = val
	case "limine-dir": a.opts.limine_dir = val
	case "log": a.opts.log_path = val
	case "dry-run": a.opts.dry_run = true
	case "yes":
		v, ok := yes_no(val)
		if !ok {return usage_error("yes: expected yes or no")}
		a.yes = v
	case "json": a.json = true
	case "verbose": a.verbose = true
	case "list-disks": a.list = "disks"
	case "list-layouts": a.list = "layouts"
	case "list-zones": a.list = "zones"
	case "list-languages": a.list = "languages"
	case "password", "root-password":
		if !from_answers {
			return usage_error("--%s is not accepted on the command line (it would be visible to every user); use --%s-file", key, key)
		}
		if key == "password" {a.plan.password = val} else {a.plan.root_password = val}
	case:
		return usage_error("unknown option %q", key)
	}
	_ = has_val
	return EXIT_OK
}

// read_secret reads the first line of a file, or of stdin for "-".
read_secret :: proc(path, what: string) -> (string, int) {
	data: []u8
	if path == "-" {
		buf := make([dynamic]u8)
		b: [1]u8
		for {
			n, err := os.read(os.stdin, b[:])
			if n <= 0 || err != nil || b[0] == '\n' {break}
			append(&buf, b[0])
		}
		data = buf[:]
	} else {
		d, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			return "", fail_code(EXIT_NOT_FOUND, "cannot read the %s from %s: %v", what, path, err)
		}
		data = d
	}
	s := string(data)
	if i := strings.index_byte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.trim_right(s, "\r"), EXIT_OK
}

// parse_size reads "none", "0", "2G", "2GiB", "512M", "512MiB" or a number of
// bytes.
parse_size :: proc(s: string) -> (u64, bool) {
	t := strings.to_lower(strings.trim_space(s), context.temp_allocator)
	if t == "none" || t == "no" || t == "0" || t == "" {
		return 0, true
	}
	t = strings.trim_suffix(strings.trim_suffix(t, "ib"), "b")
	mult := u64(1)
	switch {
	case strings.has_suffix(t, "g"): mult, t = 1 << 30, t[:len(t) - 1]
	case strings.has_suffix(t, "m"): mult, t = 1 << 20, t[:len(t) - 1]
	case strings.has_suffix(t, "k"): mult, t = 1 << 10, t[:len(t) - 1]
	}
	n: u64
	if t == "" {return 0, false}
	for ch in transmute([]u8)t {
		if ch < '0' || ch > '9' {return 0, false}
		n = n * 10 + u64(ch - '0')
	}
	return n * mult, true
}

// filter_problems keeps what matters to the steps being run: a test that only
// partitions an image does not need a user name.
filter_problems :: proc(problems: []core.Message, steps: bit_set[core.Step]) -> []core.Message {
	out := make([dynamic]core.Message)
	for p in problems {
		disk := strings.has_prefix(core.message_code(p.id), "disk_")
		if disk && steps & {.Partition, .Format, .Mount} != {} {
			append(&out, p)
		} else if !disk && steps & {.Configure, .Packages} != {} {
			append(&out, p)
		}
	}
	return out[:]
}

print_summary :: proc(a: ^Args) {
	p := a.plan
	what := p.disk
	if !a.opts.disk_image {
		for d in core.list_disks(context.temp_allocator) {
			if d.path == p.disk {
				what = fmt.tprintf("%s (%s%s%s)", d.path, d.model, d.model != "" ? ", " : "", core.human_size(d.size_bytes))
			}
		}
	} else {
		what = fmt.tprintf("%s (disk image, system built in %s)", p.disk, a.opts.target)
	}
	pk := p.packages
	if len(pk) == 0 {pk = {"palmy"}}
	fmt.printf("Palmy will be installed on %s.\n", what)
	fmt.printf("  EVERYTHING ON %s WILL BE ERASED: a 512 MiB EFI partition and an ext4 root.\n", p.disk)
	fmt.printf("  boot: UEFI%s\n", a.opts.no_bios_boot ? " only (no BIOS boot code)" : " and BIOS")
	if p.swap_bytes > 0 {
		fmt.printf("  swap file: %s\n", core.human_size(p.swap_bytes))
	}
	kb := p.keyboard.layout
	if p.keyboard.variant != "" {kb = fmt.tprintf("%s:%s", kb, p.keyboard.variant)}
	fmt.printf("  language %s, keyboard %s, time zone %s\n", p.language, kb, p.timezone)
	fmt.printf("  user %s (%s), host name %s\n", p.user, p.full_name != "" ? p.full_name : p.user, p.hostname)
	fmt.printf("  packages %s from %s\n", strings.join(pk, " ", context.temp_allocator), p.repo)
	if p.no_firmware {
		fmt.printf("  firmware: none\n")
	} else if fw := core.firmware_for_repo(p.repo, context.temp_allocator); len(fw) > 0 {
		fmt.printf("  firmware: %s\n", strings.join(fw, " ", context.temp_allocator))
	}
	fmt.printf("  UEFI boot entry: %s\n", p.efi_boot_entry ? "yes" : "no")
}

@(private = "file")
last_msg: string

on_progress :: proc(pr: core.Progress, user: rawptr) {
	if g_json {
		fmt.printf("{{\"event\":\"progress\",\"step\":%s,\"fraction\":%.3f,\"message\":%s,\"code\":%s}}\n",
			json_str(core.step_name(pr.step)), pr.fraction, json_str(pr.message), json_str(core.message_code(pr.detail.id)))
		return
	}
	if pr.message == last_msg {return}
	delete(last_msg)
	last_msg = strings.clone(pr.message)
	fmt.printf("[%3d%%] %s\n", int(pr.fraction * 100 + 0.5), pr.message)
}

// ------------------------------------------------------------------ lists --

list_disks :: proc(json: bool) -> int {
	disks := core.list_disks()
	if json {
		fmt.print("[")
		for d, i in disks {
			fmt.printf("%s{{\"path\":%s,\"name\":%s,\"model\":%s,\"size_bytes\":%d,\"removable\":%v,\"readonly\":%v,\"has_partitions\":%v,\"is_live_medium\":%v}}",
				i > 0 ? "," : "", json_str(d.path), json_str(d.name), json_str(d.model), d.size_bytes,
				d.removable, d.readonly, d.has_partitions, d.is_live_medium)
		}
		fmt.println("]")
		return EXIT_OK
	}
	for d in disks {
		notes := make([dynamic]string, context.temp_allocator)
		if d.is_live_medium {append(&notes, "running system")}
		if d.readonly {append(&notes, "read-only")}
		if d.removable {append(&notes, "removable")}
		if d.has_partitions {append(&notes, "has partitions")}
		fmt.printf("%-16s %10s  %-28s %s\n", d.path, core.human_size(d.size_bytes), d.model, strings.join(notes[:], ", ", context.temp_allocator))
	}
	return EXIT_OK
}

list_layouts :: proc(json: bool) -> int {
	ls := core.list_layouts()
	if len(ls) == 0 {
		return fail_code(EXIT_NOT_FOUND, "no keyboard layouts (is xkeyboard-config installed?)")
	}
	if json {
		fmt.print("[")
		for k, i in ls {
			fmt.printf("%s{{\"layout\":%s,\"variant\":%s,\"description\":%s}}", i > 0 ? "," : "", json_str(k.layout), json_str(k.variant), json_str(k.description))
		}
		fmt.println("]")
		return EXIT_OK
	}
	for k in ls {
		code := k.variant != "" ? fmt.tprintf("  %s:%s", k.layout, k.variant) : k.layout
		fmt.printf("%-28s %s\n", code, k.description)
	}
	return EXIT_OK
}

list_zones :: proc(json: bool) -> int {
	zs := core.list_zones()
	if len(zs) == 0 {
		return fail_code(EXIT_NOT_FOUND, "no time zones (is tzdata installed?)")
	}
	if json {
		fmt.print("[")
		for z, i in zs {
			fmt.printf("%s{{\"name\":%s,\"region\":%s,\"city\":%s,\"country\":%s}}", i > 0 ? "," : "", json_str(z.name), json_str(z.region), json_str(z.city), json_str(z.country))
		}
		fmt.println("]")
		return EXIT_OK
	}
	for z in zs {
		fmt.printf("%-34s %s\n", z.name, z.country)
	}
	return EXIT_OK
}

list_languages :: proc(json: bool) -> int {
	ls := core.list_languages()
	if json {
		fmt.print("[")
		for l, i in ls {
			fmt.printf("%s{{\"code\":%s,\"native_name\":%s,\"english_name\":%s,\"rtl\":%v,\"available\":%v}}", i > 0 ? "," : "",
				json_str(l.code), json_str(l.native_name), json_str(l.english_name), l.rtl, l.available)
		}
		fmt.println("]")
		return EXIT_OK
	}
	for l in ls {
		fmt.printf("%-8s %-12s %-10s %s\n", l.code, l.native_name, l.english_name, l.available ? "" : "(not installed)")
	}
	return EXIT_OK
}

// ---------------------------------------------------------------- helpers --

json_str :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '"')
	for r in s {
		switch r {
		case '"': strings.write_string(&sb, "\\\"")
		case '\\': strings.write_string(&sb, "\\\\")
		case '\n': strings.write_string(&sb, "\\n")
		case '\r': strings.write_string(&sb, "\\r")
		case '\t': strings.write_string(&sb, "\\t")
		case:
			if r < 0x20 {
				fmt.sbprintf(&sb, "\\u%04x", int(r))
			} else {
				strings.write_rune(&sb, r)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

usage_error :: proc(format: string, args: ..any) -> int {
	msg := fmt.tprintf(format, ..args)
	if g_json {
		fmt.printf("{{\"event\":\"done\",\"ok\":false,\"code\":%d,\"error\":%s}}\n", EXIT_USAGE, json_str(msg))
	} else {
		fmt.eprintf("palm-install: %s\n(palm-install --help lists the options)\n", msg)
	}
	return EXIT_USAGE
}

fail_code :: proc(code: int, format: string, args: ..any) -> int {
	msg := fmt.tprintf(format, ..args)
	if g_json {
		fmt.printf("{{\"event\":\"done\",\"ok\":false,\"code\":%d,\"error\":%s}}\n", code, json_str(msg))
	} else {
		fmt.eprintf("palm-install: %s\n", msg)
	}
	return code
}
