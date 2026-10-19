package install_core

// Step 5: turn a freshly installed root into this person's system.
//
// palm has just installed palmy-base, whose /etc is the demo machine's:
// host name "palmy", users root and palm with the password "palm", US
// keyboard, UTC. This step rewrites exactly the files that carry those
// choices and nothing else, so `palm verify` afterwards reports them as
// "modified (config)" — /etc files the user owns now — and every other file
// still matches its package.
//
// Every file here is written into the target root, whatever directory that
// is: on the live system /mnt/target, in the selftest a scratch directory.
// Writes go to a temporary name and are renamed into place, so a crash never
// leaves a half-written /etc/shadow.
//
// Users: the demo account `palm` (uid 1000) is removed and the new user takes
// its place — uid 1000 unless something else holds it, its own group, and
// membership of wheel, video, input and audio as the CONTRACT gives palm.
// Its home is made from /etc/skel when the base package ships one, else from
// the demo user's home, which is then removed (notes/installer-core.md asks
// for /etc/skel). Passwords are hashed with SHA-512 crypt (crypt.odin)
// before they are written anywhere; the plain text never touches the disk.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

USER_GROUPS := [?]string{"wheel", "video", "input", "audio"}
DEMO_USER :: "palm"

@(private)
step_configure :: proc(c: ^Ctx) -> string {
	if e := load_parts(c); e != "" {
		return e
	}
	root := c.t.root
	p := c.p
	if c.o.dry_run {
		logf(c, "would write /etc/hostname, hosts, passwd, group, shadow, locale.conf, palm/keyboard, localtime, timezone, fstab under %s", root)
		return ""
	}
	if !os.is_file(join(root, "etc/passwd")) {
		return fmt.tprintf("%s has no /etc/passwd; were the packages installed?", root)
	}

	progress(c, 0.05, msg(.Setting_Hostname))
	if e := write_hostname(c, root, p.hostname); e != "" {return e}

	progress(c, 0.2, msg(.Creating_User))
	if e := write_accounts(c, root, p); e != "" {return e}

	progress(c, 0.5, msg(.Setting_Locale))
	if e := write_locale(c, root, p.language); e != "" {return e}
	if e := write_keyboard(c, root, p.keyboard); e != "" {return e}
	if e := write_timezone(c, root, p.timezone); e != "" {return e}

	if p.swap_bytes > 0 {
		progress(c, 0.6, msg(.Creating_Swap, human_size(p.swap_bytes)))
		if e := write_swapfile(c, root, p.swap_bytes); e != "" {return e}
	}

	progress(c, 0.8, msg(.Writing_Fstab))
	if e := write_fstab(c, root, c.parts, p.swap_bytes > 0); e != "" {return e}
	if e := write_repositories(c, root, p.repo); e != "" {return e}
	return ""
}

// -------------------------------------------------------------- host name --

@(private)
write_hostname :: proc(c: ^Ctx, root, hostname: string) -> string {
	if e := write_file(c, join(root, "etc/hostname"), fmt.tprintf("%s\n", hostname), 0o644); e != "" {
		return e
	}
	hosts := fmt.tprintf("127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t%s\n", hostname)
	return write_file(c, join(root, "etc/hosts"), hosts, 0o644)
}

// ---------------------------------------------------------------- accounts --

@(private)
write_accounts :: proc(c: ^Ctx, root: string, p: Plan) -> string {
	passwd_path := join(root, "etc/passwd")
	group_path := join(root, "etc/group")
	shadow_path := join(root, "etc/shadow")
	passwd := read_lines(passwd_path)
	group := read_lines(group_path)
	shadow := read_lines(shadow_path)

	user_hash, ok1 := make_hash(p.password, allocator = context.temp_allocator)
	root_hash, ok2 := make_hash(p.root_password != "" ? p.root_password : p.password, allocator = context.temp_allocator)
	if !ok1 || !ok2 {
		return "could not hash the password"
	}

	// passwd: drop the demo user and any older entry of the same name, then
	// find the uid: 1000 if free, else the next free one.
	gone := []string{DEMO_USER, p.user}
	kept := make([dynamic]string, context.temp_allocator)
	used := make(map[int]bool, context.temp_allocator)
	for l in passwd {
		f := strings.split(l, ":", context.temp_allocator)
		if len(f) >= 1 && slice.contains(gone, f[0]) {
			continue
		}
		if len(f) >= 3 {
			if n, ok := strconv.parse_int(f[2]); ok {used[n] = true}
		}
		append(&kept, l)
	}
	gused := make(map[int]bool, context.temp_allocator)
	for l in group {
		f := strings.split(l, ":", context.temp_allocator)
		if len(f) >= 3 && !slice.contains(gone, f[0]) {
			if n, ok := strconv.parse_int(f[2]); ok {gused[n] = true}
		}
	}
	uid := 1000
	for used[uid] || gused[uid] {
		uid += 1
	}
	home := fmt.tprintf("/home/%s", p.user)
	append(&kept, fmt.tprintf("%s:x:%d:%d:%s:%s:/bin/sh", p.user, uid, uid, p.full_name, home))
	if e := write_file(c, passwd_path, lines_text(kept[:]), 0o644); e != "" {
		return e
	}

	// group: drop the demo user's and any same-named group, take the demo
	// user out of every member list, put the new one into the four groups.
	gk := make([dynamic]string, context.temp_allocator)
	for l in group {
		f := strings.split(l, ":", context.temp_allocator)
		if len(f) < 4 {
			append(&gk, l)
			continue
		}
		if slice.contains(gone, f[0]) {
			continue
		}
		members := make([dynamic]string, context.temp_allocator)
		for m in strings.split(f[3], ",", context.temp_allocator) {
			if m != "" && !slice.contains(gone, m) {append(&members, m)}
		}
		if slice.contains(USER_GROUPS[:], f[0]) {
			append(&members, p.user)
		}
		append(&gk, fmt.tprintf("%s:%s:%s:%s", f[0], f[1], f[2], strings.join(members[:], ",", context.temp_allocator)))
	}
	append(&gk, fmt.tprintf("%s:x:%d:", p.user, uid))
	if e := write_file(c, group_path, lines_text(gk[:]), 0o644); e != "" {
		return e
	}

	// shadow: new hashes for root and the user; last change today (days
	// since the epoch), aging fields as the base system has them.
	days := time.time_to_unix(time.now()) / 86400
	sk := make([dynamic]string, context.temp_allocator)
	have_root := false
	for l in shadow {
		f := strings.split(l, ":", context.temp_allocator)
		if len(f) >= 1 && slice.contains(gone, f[0]) {
			continue
		}
		if len(f) >= 3 && f[0] == "root" {
			f[1] = root_hash
			f[2] = fmt.tprintf("%d", days)
			append(&sk, strings.join(f, ":", context.temp_allocator))
			have_root = true
			continue
		}
		append(&sk, l)
	}
	if !have_root {
		inject_at(&sk, 0, fmt.tprintf("root:%s:%d:0:99999:7:::", root_hash, days))
	}
	append(&sk, fmt.tprintf("%s:%s:%d:0:99999:7:::", p.user, user_hash, days))
	if e := write_file(c, shadow_path, lines_text(sk[:]), 0o600); e != "" {
		return e
	}
	logf(c, "user %s: uid %d, groups %s,%v; root password %s", p.user, uid, p.user, USER_GROUPS,
		p.root_password == "" || p.root_password == p.password ? "same as the user's" : "set separately")

	return make_home(c, root, p.user, home, uid)
}

@(private = "file")
make_home :: proc(c: ^Ctx, root, user, home: string, uid: int) -> string {
	dst := join(root, home)
	demo := join(root, "home", DEMO_USER)
	skel := join(root, "etc/skel")
	if user != DEMO_USER {
		src := os.is_dir(skel) ? skel : demo
		if os.is_dir(src) && !os.exists(dst) {
			if e := copy_tree(src, dst); e != "" {
				return e
			}
			logf(c, "home %s made from %s", home, src[len(root):])
		}
		if os.is_dir(demo) {
			_ = os.remove_all(demo)
			logf(c, "removed the demo user's home /home/%s", DEMO_USER)
		}
	}
	if e := mkdir_p(dst); e != nil {
		return fmt.tprintf("mkdir %s: %v", dst, e)
	}
	_ = os.chmod(dst, os.perm_number(0o700))
	chown_tree(c, dst, uid, uid)
	return ""
}

// copy_tree copies directories, regular files and symlinks with their modes.
@(private)
copy_tree :: proc(src, dst: string) -> string {
	st, err := os.stat_do_not_follow_links(src, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("stat %s: %v", src, err)
	}
	#partial switch st.type {
	case .Directory:
		if e := os.make_directory(dst, st.mode & {.Read_User, .Write_User, .Execute_User, .Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}); e != nil && e != .Exist {
			return fmt.tprintf("mkdir %s: %v", dst, e)
		}
		entries, _ := os.read_all_directory_by_path(src, context.temp_allocator)
		for fi in entries {
			if e := copy_tree(join(src, fi.name), join(dst, fi.name)); e != "" {
				return e
			}
		}
	case .Symlink:
		target, _ := os.read_link(src, context.temp_allocator)
		if e := os.symlink(target, dst); e != nil {
			return fmt.tprintf("symlink %s: %v", dst, e)
		}
	case:
		if e := os.copy_file(dst, src); e != nil {
			return fmt.tprintf("copy %s: %v", src, e)
		}
	}
	return ""
}

// chown_tree gives a home to its owner. On the build host (not root) chown
// fails with EPERM; that is expected there and only logged once.
@(private)
chown_tree :: proc(c: ^Ctx, path: string, uid, gid: int) {
	err := linux.lchown(strings.clone_to_cstring(path, context.temp_allocator), linux.Uid(uid), linux.Gid(gid))
	if err != .NONE {
		if linux.geteuid() != 0 && err == .EPERM {
			return
		}
		logf(c, "chown %s: %v", path, err)
	}
	st, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	if serr == nil && st.type == .Directory {
		entries, _ := os.read_all_directory_by_path(path, context.temp_allocator)
		for fi in entries {
			chown_tree(c, join(path, fi.name), uid, gid)
		}
	}
}

// ------------------------------------------------- language, keyboard, clock --

@(private)
write_locale :: proc(c: ^Ctx, root, language: string) -> string {
	lang := language
	if !strings.contains_rune(lang, '.') {
		lang = fmt.tprintf("%s.UTF-8", lang)
	}
	return write_file(c, join(root, "etc/locale.conf"), fmt.tprintf("LANG=%s\n", lang), 0o644)
}

// /etc/palm/keyboard is the wm's (INSTALLER.md): key = value, compiled from
// /usr/share/X11/xkb at start and re-read on change.
@(private)
write_keyboard :: proc(c: ^Ctx, root: string, kb: Keyboard) -> string {
	_ = mkdir_p(join(root, "etc/palm"))
	text := fmt.tprintf(
		"# The keyboard layout, chosen at installation. The window manager reads\n# this at start and again when it changes; XKB_DEFAULT_LAYOUT and\n# XKB_DEFAULT_VARIANT override it.\n%s",
		keyboard_settings(kb),
	)
	return write_file(c, join(root, "etc/palm/keyboard"), text, 0o644)
}

// A layout that cannot type Latin letters cannot type a user name either
// (they are a-z), nor most passwords people choose, nor a shell command. So,
// as Debian's installer does for Russian, such a layout gets US English
// beside it, first, with Alt+Shift switching between the two: the person
// logs in in Latin letters and switches to write in their own script.
NON_LATIN_LAYOUTS := [?]string {
	"af", "am", "ara", "bd", "bg", "bt", "by", "eg", "et", "ge", "gr", "il", "in", "iq", "ir",
	"kg", "kh", "kz", "la", "lk", "ma", "mk", "mm", "mn", "mv", "np", "pk", "rs", "ru", "sy",
	"th", "tj", "ua",
}

keyboard_needs_latin :: proc(layout: string) -> bool {
	return slice.contains(NON_LATIN_LAYOUTS[:], layout)
}

// keyboard_settings is the body of /etc/palm/keyboard for a choice: the
// `layout`, `variant` and `options` lines the window manager reads.
keyboard_settings :: proc(kb: Keyboard) -> string {
	if keyboard_needs_latin(kb.layout) {
		return fmt.tprintf("layout = us,%s\nvariant = ,%s\noptions = grp:alt_shift_toggle\n", kb.layout, kb.variant)
	}
	return fmt.tprintf("layout = %s\nvariant = %s\noptions =\n", kb.layout, kb.variant)
}

@(private)
write_timezone :: proc(c: ^Ctx, root, zone: string) -> string {
	link := join(root, "etc/localtime")
	target := fmt.tprintf("../usr/share/zoneinfo/%s", zone)
	_ = os.remove(link)
	if e := os.symlink(target, link); e != nil {
		return fmt.tprintf("symlink %s: %v", link, e)
	}
	if !os.exists(join(root, "usr/share/zoneinfo", zone)) {
		// glibc falls back to UTC; say so rather than fail an installation
		// over the clock.
		logf(c, "warning: %s is not in the installed tzdata; the clock will show UTC until tzdata is installed", zone)
	}
	return write_file(c, join(root, "etc/timezone"), fmt.tprintf("%s\n", zone), 0o644)
}

// ---------------------------------------------------------- fstab, repository --

// The root by PARTUUID — the kernel command line uses the same name, and it
// needs no blkid — and the ESP at /boot/efi. The base file's comment header
// is kept; entries for / and /boot/efi it may already have are replaced.
@(private)
write_fstab :: proc(c: ^Ctx, root: string, parts: Partition_Info, swap := false) -> string {
	path := join(root, "etc/fstab")
	kept := make([dynamic]string, context.temp_allocator)
	for l in read_lines(path) {
		f := strings.fields(l, context.temp_allocator)
		if len(f) >= 2 && !strings.has_prefix(f[0], "#") && (f[1] == "/" || f[1] == "/boot/efi" || f[0] == SWAPFILE) {
			continue
		}
		append(&kept, l)
	}
	if len(kept) == 0 {
		append(&kept, "# <device>  <mountpoint>  <type>  <options>  <dump>  <pass>")
	}
	append(&kept, fmt.tprintf("PARTUUID=%s\t/\text4\trw,relatime\t0 1", partuuid(parts.root_guid)))
	append(&kept, fmt.tprintf("PARTUUID=%s\t/boot/efi\tvfat\trw,relatime,fmask=0077,dmask=0077\t0 2", partuuid(parts.esp_guid)))
	if swap {
		append(&kept, fmt.tprintf("%s\tnone\tswap\tdefaults\t0 0", SWAPFILE))
	}
	return write_file(c, path, lines_text(kept[:]), 0o644)
}

// ------------------------------------------------------------- swap file --

// The swap file lives on the root file system rather than in a partition of
// its own: it can be resized or removed later without touching the table.
// ext4 takes a swap file only when it has no holes, so the blocks are
// allocated with fallocate(2) (zeros are written where that is not
// supported), and only root may read it: it holds pages of every process.
SWAPFILE :: "/swapfile"

@(private)
write_swapfile :: proc(c: ^Ctx, root: string, size: u64) -> string {
	path := join(root, SWAPFILE)
	_ = os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE {
		return fmt.tprintf("create %s: %v", path, err)
	}
	r := linux.syscall(linux.SYS_fallocate, fd, 0, 0, uintptr(size))
	if int(r) < 0 {
		logf(c, "fallocate %s: %v; writing zeros instead", path, linux.Errno(-int(r)))
		zero := make([]u8, 1 << 20, context.temp_allocator)
		for off: u64 = 0; off < size; off += u64(len(zero)) {
			n := min(u64(len(zero)), size - off)
			if e := pwrite_all(fd, zero[:n], i64(off)); e != "" {
				linux.close(fd)
				return fmt.tprintf("%s: %s", path, e)
			}
		}
	}
	linux.fchmod(fd, {.IRUSR, .IWUSR})
	linux.fsync(fd)
	linux.close(fd)
	if e := run(c, {"mkswap", path}); e != "" {
		return e
	}
	logf(c, "swap file %s, %s", SWAPFILE, human_size(size))
	return ""
}

// The installed system keeps palmy-base's network repository unless the
// installation itself came from one: the live medium's local repository is
// not on the new disk, so pointing there would leave `palm update` nowhere.
@(private)
write_repositories :: proc(c: ^Ctx, root, repo: string) -> string {
	if strings.has_prefix(repo, "http://") || strings.has_prefix(repo, "https://") {
		text := fmt.tprintf("# One repository per line: an http:// URL or an absolute path.\n# Written by palm-install: the repository this system was installed from.\n%s\n", repo)
		return write_file(c, join(root, "etc/palm/repositories"), text, 0o644)
	}
	logf(c, "repositories: keeping the base system's network repository (installed from %s)", repo)
	return ""
}

// partuuid is the form the kernel's root= and fstab expect: lower case.
partuuid :: proc(g: Guid) -> string {
	return strings.to_lower(guid_string(g, context.temp_allocator), context.temp_allocator)
}

// ----------------------------------------------------------------- helpers --

@(private)
read_lines :: proc(path: string) -> []string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	text := strings.trim_right(string(data), "\n")
	if text == "" {
		return nil
	}
	return strings.split(text, "\n", context.temp_allocator)
}

@(private)
lines_text :: proc(lines: []string) -> string {
	return fmt.tprintf("%s\n", strings.join(lines, "\n", context.temp_allocator))
}

// write_file writes to <path>.palm-install and renames it over <path>, with
// `mode` set before the rename so a 0600 file is never briefly readable.
@(private)
write_file :: proc(c: ^Ctx, path, content: string, mode: int) -> string {
	tmp := fmt.tprintf("%s.palm-install", path)
	_ = os.remove(tmp)
	if e := os.write_entire_file(tmp, content, os.perm_number(mode)); e != nil {
		return fmt.tprintf("write %s: %v", path, e)
	}
	_ = os.chmod(tmp, os.perm_number(mode))
	if e := os.rename(tmp, path); e != nil {
		_ = os.remove(tmp)
		return fmt.tprintf("rename %s: %v", path, e)
	}
	if c != nil {
		logf(c, "wrote %s", path)
	}
	return ""
}
