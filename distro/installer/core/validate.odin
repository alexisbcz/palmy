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
// all the fields at once. Each is a Message (message.odin): a stable code,
// an English format that is also the msgid a front end translates, and the
// values that fill it.

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
// block device, and an explicit disk list (nil = list_disks()). Its problems
// are English sentences; validate_messages has the same problems as
// Messages, for a front end that translates them.
validate_with :: proc(p: Plan, o: Options, disks: []Disk = nil) -> (ok: bool, problems: []string) {
	ms := validate_messages(p, o, disks)
	out := make([]string, len(ms))
	for m, i in ms {
		out[i] = message_text(m, context.allocator)
	}
	return len(out) == 0, out
}

// validate_messages returns every problem with the plan, as Messages (an id
// and its arguments; message.odin). The arguments are allocated with the
// context allocator.
validate_messages :: proc(p: Plan, o: Options, disks: []Disk = nil) -> []Message {
	out := make([dynamic]Message)
	add :: proc(out: ^[dynamic]Message, m: Message) {
		if m.id != .None {
			append(out, message_clone(m))
		}
	}
	q := normalise_plan(p)

	// user
	add(&out, check_user_name(p.user))
	if strings.contains_any(q.full_name, ":\n") || len(q.full_name) > 128 {
		add(&out, msg(.Full_Name_Invalid))
	}
	if p.password == "" {
		add(&out, msg(.Password_Empty))
	} else if strings.contains_any(p.password, "\n\r\x00") {
		add(&out, msg(.Password_Line_Break))
	}
	if strings.contains_any(p.root_password, "\n\r\x00") {
		add(&out, msg(.Root_Password_Line_Break))
	}

	// host name
	add(&out, check_hostname(p.hostname))

	// language
	if !valid_language(q.language) {
		add(&out, msg(.Language_Invalid, q.language))
	}

	// keyboard: against base.lst when it is there to ask.
	if !valid_token(q.keyboard.layout) || (q.keyboard.variant != "" && !valid_token(q.keyboard.variant)) {
		add(&out, msg(.Layout_Invalid, q.keyboard.layout))
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
				add(&out, msg(.Layout_No_Variant, q.keyboard.layout, q.keyboard.variant))
			} else {
				add(&out, msg(.Layout_Unknown, q.keyboard.layout))
			}
		}
	}

	// time zone
	if q.timezone == "" || strings.has_prefix(q.timezone, "/") || strings.contains(q.timezone, "..") || strings.contains_any(q.timezone, " \n") {
		add(&out, msg(.Timezone_Invalid, q.timezone))
	} else if os.is_dir("/usr/share/zoneinfo") && !os.is_file(join("/usr/share/zoneinfo", q.timezone)) {
		add(&out, msg(.Timezone_Unknown, q.timezone))
	}

	// repository and packages
	if !(strings.has_prefix(q.repo, "http://") || strings.has_prefix(q.repo, "https://") || strings.has_prefix(q.repo, "file:///") || strings.has_prefix(q.repo, "/")) {
		add(&out, msg(.Repo_Invalid, q.repo))
	}
	for pkg in q.packages {
		if !valid_package(pkg) {
			add(&out, msg(.Package_Invalid, pkg))
		}
	}

	// disk, and the swap file that has to fit on it beside the system
	disk_size, dm := check_disk(p.disk, o, disks)
	add(&out, dm)
	if p.swap_bytes > MAX_SWAP_BYTES {
		add(&out, msg(.Swap_Too_Big, human_size(p.swap_bytes), p.disk))
	} else if p.swap_bytes > 0 && dm.id == .None && disk_size > 0 && disk_size < MIN_DISK_BYTES + p.swap_bytes {
		add(&out, msg(.Swap_Too_Big, human_size(p.swap_bytes), p.disk))
	}
	return out[:]
}

check_user_name :: proc(name: string) -> Message {
	if name == "" {
		return msg(.User_Empty)
	}
	if len(name) > 32 {
		return msg(.User_Too_Long)
	}
	for ch, i in transmute([]u8)name {
		ok := (ch >= 'a' && ch <= 'z') || ch == '_' || (i > 0 && ((ch >= '0' && ch <= '9') || ch == '-'))
		if !ok {
			return msg(.User_Invalid, name)
		}
	}
	if slice.contains(RESERVED_NAMES[:], name) {
		return msg(.User_Reserved, name)
	}
	return {}
}

check_hostname :: proc(h: string) -> Message {
	if h == "" {
		return msg(.Hostname_Empty)
	}
	if len(h) > 253 {
		return msg(.Hostname_Too_Long)
	}
	for label in strings.split(h, ".", context.temp_allocator) {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label) - 1] == '-' {
			return msg(.Hostname_Label, h)
		}
		for ch in transmute([]u8)label {
			if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-') {
				return msg(.Hostname_Chars, h)
			}
		}
	}
	return {}
}

// check_disk also returns the disk's size when the disk is usable, for the
// swap check.
@(private = "file")
check_disk :: proc(path: string, o: Options, disks: []Disk) -> (u64, Message) {
	if path == "" {
		return 0, msg(.Disk_None)
	}
	if o.disk_image {
		if strings.has_prefix(path, "/dev/") {
			return 0, msg(.Disk_Image_Device, path)
		}
		st, err := os.stat(path, context.temp_allocator)
		if err != nil || st.type != .Regular {
			return 0, msg(.Disk_Image_Not_File, path)
		}
		if u64(st.size) < MIN_DISK_BYTES {
			return 0, msg(.Disk_Image_Small, path, human_size(u64(st.size)))
		}
		return u64(st.size), {}
	}
	list := disks
	if list == nil {
		list = list_disks(context.temp_allocator)
	}
	for d in list {
		if d.path != path {continue}
		if d.is_live_medium {
			return 0, msg(.Disk_Live_Medium, path)
		}
		if d.readonly {
			return 0, msg(.Disk_Readonly, path)
		}
		if d.size_bytes < MIN_DISK_BYTES {
			return 0, msg(.Disk_Small, path, human_size(d.size_bytes))
		}
		if disks == nil && slice.contains(disks_in_use(), d.name) {
			return 0, msg(.Disk_Mounted, path)
		}
		return d.size_bytes, {}
	}
	return 0, msg(.Disk_Missing, path)
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
