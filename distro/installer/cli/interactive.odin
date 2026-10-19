package palm_install

// palm-install's questions: what `palm-install` with no options does on a
// terminal (or `palm-install --interactive`). It is for the live system's
// serial console, where there is no screen for the graphical installer.
//
// It asks for the same things the graphical installer does, in the same
// order, with a default in brackets that Enter accepts, and checks each
// answer with install_core's own rules as it is given. Then it prints the
// same summary as the option-driven path and, because a whole disk is about
// to be erased, asks for the disk's name to be typed back. The plan then
// goes through the same validate and install as every other run.
//
// The questions are in English: the serial console has no font and no
// input method, so a translated prompt could not be relied on to display.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import core "install:core"

TCGETS :: 0x5401
TCSETS :: 0x5402
ECHO_FLAG :: 0o10

// termios as the kernel's TCGETS fills it (struct termios, 60 bytes on x86_64).
Termios :: struct {
	iflag, oflag, cflag, lflag: u32,
	line:                       u8,
	cc:                         [19]u8,
	ispeed, ospeed:             u32,
}

is_terminal :: proc(f: ^os.File) -> bool {
	t: Termios
	return int(linux.ioctl(linux.Fd(os.fd(f)), TCGETS, uintptr(&t))) == 0
}

// The languages' usual layout and zone, as the graphical installer's
// LANGUAGE_DEFAULTS (apps/installer/flow.odin) has them.
@(private = "file")
LANGUAGE_DEFAULTS := [?][3]string {
	{"en_US", "us", "UTC"},
	{"fr_FR", "fr", "Europe/Paris"},
	{"de_DE", "de", "Europe/Berlin"},
	{"es_ES", "es", "Europe/Madrid"},
	{"ar", "ara", "Africa/Cairo"},
	{"ja_JP", "jp", "Asia/Tokyo"},
}

@(private = "file")
Quit :: struct {}

interactive :: proc(a: ^Args) -> int {
	if !is_terminal(os.stdin) {
		return usage_error("--interactive needs a terminal; give the options instead")
	}
	if linux.geteuid() != 0 {
		return fail_code(EXIT_REFUSED, "installing to a disk needs root")
	}
	fmt.println()
	fmt.println("Palmframe installer")
	fmt.println("Each question shows its default in [brackets]; Enter takes it.")
	fmt.println("Ctrl+D stops here, and nothing is changed until the last question.")
	fmt.println()

	p := &a.plan
	for {
		// Disk
		disks := core.list_disks()
		usable := make([dynamic]core.Disk, context.temp_allocator)
		fmt.println("Disks:")
		for d in disks {
			why := ""
			switch {
			case d.is_live_medium: why = "the running system"
			case d.readonly: why = "read-only"
			case d.size_bytes < core.MIN_DISK_BYTES: why = "smaller than 4 GiB"
			}
			if why == "" {
				append(&usable, d)
				fmt.printf("  %d) %-14s %10s  %s\n", len(usable), d.path, core.human_size(d.size_bytes), d.model)
			} else {
				fmt.printf("  -  %-14s %10s  %s (%s)\n", d.path, core.human_size(d.size_bytes), d.model, why)
			}
		}
		if len(usable) == 0 {
			return fail_code(EXIT_NOT_FOUND, "no disk can take Palmframe (at least 4 GiB, writable, not the running system)")
		}
		def := "1"
		for d, i in usable {
			if d.path == p.disk {def = fmt.tprint(i + 1)}
		}
		for {
			ans, ok := ask("Disk to erase (number or path)", def)
			if !ok {return quit()}
			chosen := ""
			for d, i in usable {
				if ans == fmt.tprint(i + 1) || ans == d.path || ans == d.name {chosen = d.path}
			}
			if chosen != "" {
				p.disk = strings.clone(chosen)
				break
			}
			fmt.println("  That is not one of the numbered disks.")
		}

		// Language, which also suggests the layout and the zone.
		codes := make([dynamic]string, context.temp_allocator)
		for l in core.list_languages() {
			if l.available {append(&codes, l.code)}
		}
		for {
			ans, ok := ask(fmt.tprintf("Language (%s)", strings.join(codes[:], ", ", context.temp_allocator)), p.language)
			if !ok {return quit()}
			if slice.contains(codes[:], ans) {
				if ans != p.language {
					for d in LANGUAGE_DEFAULTS {
						if d[0] == ans {
							p.keyboard = {layout = d[1]}
							p.timezone = d[2]
						}
					}
				}
				p.language = strings.clone(ans)
				break
			}
			fmt.println("  Choose one of the languages listed.")
		}

		// Keyboard
		layouts := core.list_layouts()
		for {
			cur := p.keyboard.variant != "" ? fmt.tprintf("%s:%s", p.keyboard.layout, p.keyboard.variant) : p.keyboard.layout
			ans, ok := ask("Keyboard layout, as layout or layout:variant ('?' lists them, '?text' searches)", cur)
			if !ok {return quit()}
			if strings.has_prefix(ans, "?") {
				needle := strings.to_lower(ans[1:], context.temp_allocator)
				for k in layouts {
					code := k.variant != "" ? fmt.tprintf("%s:%s", k.layout, k.variant) : k.layout
					if needle == "" ? k.variant == "" : strings.contains(strings.to_lower(fmt.tprintf("%s %s", code, k.description), context.temp_allocator), needle) {
						fmt.printf("  %-24s %s\n", code, k.description)
					}
				}
				continue
			}
			layout, variant := ans, ""
			if i := strings.index_byte(ans, ':'); i >= 0 {
				layout, variant = ans[:i], ans[i + 1:]
			}
			found := len(layouts) == 0
			for k in layouts {
				if k.layout == layout && k.variant == variant {found = true}
			}
			if found {
				p.keyboard = {layout = strings.clone(layout), variant = strings.clone(variant)}
				break
			}
			fmt.println("  There is no such layout; '?' lists them.")
		}

		// Time zone
		zones := core.list_zones()
		for {
			ans, ok := ask("Time zone, as Region/City ('?text' searches)", p.timezone)
			if !ok {return quit()}
			if strings.has_prefix(ans, "?") {
				needle := strings.to_lower(ans[1:], context.temp_allocator)
				for z in zones {
					if strings.contains(strings.to_lower(fmt.tprintf("%s %s", z.name, z.country), context.temp_allocator), needle) {
						fmt.printf("  %-32s %s\n", z.name, z.country)
					}
				}
				continue
			}
			found := len(zones) == 0
			for z in zones {
				if z.name == ans {found = true}
			}
			if found {
				p.timezone = strings.clone(ans)
				break
			}
			fmt.println("  There is no such time zone; '?Paris' or '?France' searches.")
		}

		// Computer name
		for {
			ans, ok := ask("Computer name", p.hostname)
			if !ok {return quit()}
			if m := core.check_hostname(ans); m.id != .None {
				fmt.printf("  %s\n", core.message_text(m))
				continue
			}
			p.hostname = strings.clone(ans)
			break
		}

		// Account
		{
			ans, ok := ask("Your full name (optional)", p.full_name)
			if !ok {return quit()}
			p.full_name = strings.clone(ans)
		}
		for {
			def := p.user
			if def == "" {def = suggest_user(p.full_name)}
			ans, ok := ask("User name", def)
			if !ok {return quit()}
			if m := core.check_user_name(ans); m.id != .None {
				fmt.printf("  %s\n", core.message_text(m))
				continue
			}
			p.user = strings.clone(ans)
			break
		}
		{
			pw, ok := ask_password("Password", true)
			if !ok {return quit()}
			p.password = pw
		}
		{
			ans, ok := ask("Use the same password for root, the administrator? (yes/no)", "yes")
			if !ok {return quit()}
			p.root_password = ""
			if strings.has_prefix(strings.to_lower(ans, context.temp_allocator), "n") {
				pw, ok2 := ask_password("Root password", true)
				if !ok2 {return quit()}
				p.root_password = pw
			}
		}

		// Swap
		for {
			cur := "none"
			if p.swap_bytes > 0 {
				cur = p.swap_bytes % (1 << 30) == 0 ? fmt.tprintf("%dG", p.swap_bytes >> 30) : fmt.tprintf("%dM", p.swap_bytes >> 20)
			}
			ans, ok := ask("Swap file size (2G, 512M or none)", cur)
			if !ok {return quit()}
			n, sok := parse_size(ans)
			if !sok {
				fmt.printf("  %s\n", core.message_text(core.msg(.Swap_Invalid, ans)))
				continue
			}
			p.swap_bytes = n
			break
		}

		if strings.has_prefix(p.language, "ja") {
			p.packages = {"palmframe", "fonts-cjk"}
		}

		fmt.println()
		if code := check_plan(a); code != EXIT_OK {
			fmt.println("\nThe questions start again, with your answers as the defaults.\n")
			continue
		}
		print_summary(a)
		fmt.println()
		name := p.disk[strings.last_index_byte(p.disk, '/') + 1:]
		ans, ok := ask(fmt.tprintf("Type %s to erase it and install, or 'again' to change an answer", name), "")
		if !ok {return quit()}
		if ans == "again" {
			fmt.println()
			continue
		}
		if ans != name && ans != p.disk {
			fmt.println("Nothing was changed.")
			return EXIT_REFUSED
		}
		break
	}
	a.yes = true
	fmt.println()
	code := install(a)
	if code == EXIT_OK {
		fmt.println("Type `reboot` to restart into the new system.")
	}
	return code
}

@(private = "file")
quit :: proc() -> int {
	fmt.println("\nStopped; nothing was changed.")
	return EXIT_REFUSED
}

// ask prints "question [default]: " and reads a line. ok is false at the end
// of input.
@(private = "file")
ask :: proc(question, def: string) -> (string, bool) {
	if def != "" {
		fmt.printf("%s [%s]: ", question, def)
	} else {
		fmt.printf("%s: ", question)
	}
	line, ok := read_line()
	if !ok {
		return "", false
	}
	line = strings.trim_space(line)
	if line == "" {
		return def, true
	}
	return line, true
}

// ask_password reads twice without echo, until both match and are not empty.
@(private = "file")
ask_password :: proc(what: string, twice: bool) -> (string, bool) {
	for {
		fmt.printf("%s: ", what)
		a, ok := read_secret_line()
		if !ok {return "", false}
		if a == "" {
			fmt.println("  The password is empty.")
			continue
		}
		if strings.contains_any(a, "\r\x00") {
			fmt.println("  The password may not contain control characters.")
			continue
		}
		if !twice {return a, true}
		fmt.printf("%s again: ", what)
		b, ok2 := read_secret_line()
		if !ok2 {return "", false}
		if a != b {
			fmt.println("  The two passwords differ; once more.")
			continue
		}
		return a, true
	}
}

@(private = "file")
read_line :: proc() -> (string, bool) {
	buf := make([dynamic]u8)
	b: [1]u8
	for {
		n, err := os.read(os.stdin, b[:])
		if n <= 0 || err != nil {
			if len(buf) == 0 {return "", false}
			break
		}
		if b[0] == '\n' {break}
		append(&buf, b[0])
	}
	return strings.trim_right(string(buf[:]), "\r"), true
}

// read_secret_line turns the terminal's echo off for one line.
@(private = "file")
read_secret_line :: proc() -> (string, bool) {
	fd := linux.Fd(os.fd(os.stdin))
	old: Termios
	have := int(linux.ioctl(fd, TCGETS, uintptr(&old))) == 0
	if have {
		t := old
		t.lflag &~= ECHO_FLAG
		linux.ioctl(fd, TCSETS, uintptr(&t))
	}
	line, ok := read_line()
	if have {
		linux.ioctl(fd, TCSETS, uintptr(&old))
	}
	fmt.println()
	return line, ok
}

// suggest_user is the graphical installer's rule: the first word of the full
// name, lower case, letters only ("Ada Lovelace" -> ada).
suggest_user :: proc(full_name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(full_name, context.temp_allocator) {
		if r == ' ' {
			if strings.builder_len(sb) > 0 {break}
			continue
		}
		if r >= 'a' && r <= 'z' {
			strings.write_rune(&sb, r)
		}
	}
	return strings.to_string(sb)
}
