package install_core

// What makes a Plan acceptable, checked before anything is written.
//
// The rules are the ones the installed system will enforce or depend on:
// user names that busybox's login, palm-login and the CONTRACT's passwd
// format accept (and that do not collide with the system's own accounts and
// groups, since the user gets a group of its own name); host names that are
// valid DNS labels; a time zone tzdata has; a layout base.lst lists; a disk
// that exists, is writable, is big enough, is not the medium the running
// system came from, and has nothing mounted.
//
// Every problem is reported, not just the first, so a front end can mark
// all the fields at once. The messages are plain English sentences meant to
// be shown as they are (the GUI passes them through tr()).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

RESERVED_NAMES := [?]string {
	"root", "bin", "daemon", "adm", "lp", "sync", "shutdown", "halt", "mail",
	"news", "uucp", "operator", "man", "nobody", "nogroup", "greeter",
	"wheel", "video", "input", "audio", "tty", "users", "sshd", "disk", "kmem",
}

validate :: proc(p: Plan) -> (ok: bool, problems: []string) {
	return validate_with(p, default_options())
}

// validate_with is validate with the test paths: a disk image instead of a
// block device, and an explicit disk list (nil = list_disks()).
validate_with :: proc(p: Plan, o: Options, disks: []Disk = nil) -> (ok: bool, problems: []string) {
	out := make([dynamic]string)
	add :: proc(out: ^[dynamic]string, format: string, args: ..any) {
		append(out, fmt.aprintf(format, ..args))
	}
	q := normalise_plan(p)

	// user
	if e := check_user_name(p.user); e != "" {
		add(&out, "%s", e)
	}
	if strings.contains_any(q.full_name, ":\n") || len(q.full_name) > 128 {
		add(&out, "The full name may not contain ':' or line breaks, and has at most 128 characters.")
	}
	if p.password == "" {
		add(&out, "The password is empty.")
	} else if strings.contains_any(p.password, "\n\r\x00") {
		add(&out, "The password may not contain line breaks.")
	}
	if strings.contains_any(p.root_password, "\n\r\x00") {
		add(&out, "The root password may not contain line breaks.")
	}

	// host name
	if e := check_hostname(p.hostname); e != "" {
		add(&out, "%s", e)
	}

	// language
	if !valid_language(q.language) {
		add(&out, "The language %q is not a locale name like fr_FR.", q.language)
	}

	// keyboard: against base.lst when it is there to ask.
	if !valid_token(q.keyboard.layout) || (q.keyboard.variant != "" && !valid_token(q.keyboard.variant)) {
		add(&out, "The keyboard layout %q is not a valid name.", q.keyboard.layout)
	} else if layouts := list_layouts(); len(layouts) > 0 {
		found := false
		for k in layouts {
			if k.layout == q.keyboard.layout && k.variant == q.keyboard.variant {
				found = true
				break
			}
		}
		if !found {
			if q.keyboard.variant != "" {
				add(&out, "The keyboard layout %s has no variant %q.", q.keyboard.layout, q.keyboard.variant)
			} else {
				add(&out, "There is no keyboard layout %q.", q.keyboard.layout)
			}
		}
	}

	// time zone
	if q.timezone == "" || strings.has_prefix(q.timezone, "/") || strings.contains(q.timezone, "..") || strings.contains_any(q.timezone, " \n") {
		add(&out, "The time zone %q is not a zone name like Europe/Paris.", q.timezone)
	} else if os.is_dir("/usr/share/zoneinfo") && !os.is_file(join("/usr/share/zoneinfo", q.timezone)) {
		add(&out, "There is no time zone %q.", q.timezone)
	}

	// repository and packages
	if !(strings.has_prefix(q.repo, "http://") || strings.has_prefix(q.repo, "https://") || strings.has_prefix(q.repo, "file:///") || strings.has_prefix(q.repo, "/")) {
		add(&out, "The repository %q is neither an http:// URL nor an absolute path.", q.repo)
	}
	for pkg in q.packages {
		if !valid_package(pkg) {
			add(&out, "%q is not a package name.", pkg)
		}
	}

	// disk
	if e := check_disk(p.disk, o, disks); e != "" {
		add(&out, "%s", e)
	}
	return len(out) == 0, out[:]
}

check_user_name :: proc(name: string) -> string {
	if name == "" {
		return "The user name is empty."
	}
	if len(name) > 32 {
		return "The user name has more than 32 characters."
	}
	for ch, i in transmute([]u8)name {
		ok := (ch >= 'a' && ch <= 'z') || ch == '_' || (i > 0 && ((ch >= '0' && ch <= '9') || ch == '-'))
		if !ok {
			return fmt.tprintf("The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'.", name)
		}
	}
	if slice.contains(RESERVED_NAMES[:], name) {
		return fmt.tprintf("The user name %q is used by the system.", name)
	}
	return ""
}

check_hostname :: proc(h: string) -> string {
	if h == "" {
		return "The host name is empty."
	}
	if len(h) > 253 {
		return "The host name is longer than 253 characters."
	}
	for label in strings.split(h, ".", context.temp_allocator) {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label) - 1] == '-' {
			return fmt.tprintf("The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'.", h)
		}
		for ch in transmute([]u8)label {
			if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-') {
				return fmt.tprintf("The host name %q may contain only letters, digits and '-'.", h)
			}
		}
	}
	return ""
}

@(private = "file")
check_disk :: proc(path: string, o: Options, disks: []Disk) -> string {
	if path == "" {
		return "No disk is chosen."
	}
	if o.disk_image {
		if strings.has_prefix(path, "/dev/") {
			return fmt.tprintf("%s is a device; a disk image must be a plain file.", path)
		}
		st, err := os.stat(path, context.temp_allocator)
		if err != nil || st.type != .Regular {
			return fmt.tprintf("The disk image %s is not a plain file.", path)
		}
		if u64(st.size) < MIN_DISK_BYTES {
			return fmt.tprintf("The disk image %s holds %s; at least 4 GiB is needed.", path, human_size(u64(st.size)))
		}
		return ""
	}
	list := disks
	if list == nil {
		list = list_disks(context.temp_allocator)
	}
	for d in list {
		if d.path != path {continue}
		if d.is_live_medium {
			return fmt.tprintf("%s holds the running system; choose another disk.", path)
		}
		if d.readonly {
			return fmt.tprintf("%s is read-only.", path)
		}
		if d.size_bytes < MIN_DISK_BYTES {
			return fmt.tprintf("%s holds %s; at least 4 GiB is needed.", path, human_size(d.size_bytes))
		}
		if disks == nil && slice.contains(disks_in_use(), d.name) {
			return fmt.tprintf("%s has a mounted file system; unmount it first.", path)
		}
		return ""
	}
	return fmt.tprintf("There is no disk %s.", path)
}

@(private = "file")
valid_language :: proc(s: string) -> bool {
	// ll, lll, ll_CC, optionally .UTF-8 / .utf8
	base := s
	if i := strings.index_byte(s, '.'); i >= 0 {
		enc := strings.to_lower(s[i + 1:], context.temp_allocator)
		if enc != "utf-8" && enc != "utf8" {return false}
		base = s[:i]
	}
	lang := base
	cc := ""
	if i := strings.index_byte(base, '_'); i >= 0 {
		lang, cc = base[:i], base[i + 1:]
		if len(cc) != 2 {return false}
		for ch in transmute([]u8)cc {
			if ch < 'A' || ch > 'Z' {return false}
		}
	}
	if len(lang) < 2 || len(lang) > 3 {return false}
	for ch in transmute([]u8)lang {
		if ch < 'a' || ch > 'z' {return false}
	}
	return true
}

@(private = "file")
valid_token :: proc(s: string) -> bool {
	if s == "" || len(s) > 64 {return false}
	for ch in transmute([]u8)s {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
			return false
		}
	}
	return true
}

@(private = "file")
valid_package :: proc(s: string) -> bool {
	if s == "" || len(s) > 128 {return false}
	for ch, i in transmute([]u8)s {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || (i > 0 && (ch == '-' || ch == '_' || ch == '.' || ch == '+'))
		if !ok {return false}
	}
	return true
}
