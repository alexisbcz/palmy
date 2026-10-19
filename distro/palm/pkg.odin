package palm

// What a package is, in its three written forms.
//
// One struct, Pkg, describes a package wherever it appears; what differs is
// which fields are filled and how it is written down:
//
//	.PKGINFO      first member of every .palm: what the package says it is
//	PALMINDEX     one record per package: .PKGINFO plus where the .palm is
//	              and its sha256, the field that makes a download trustworthy
//	installed     one record per installed package: .PKGINFO plus the sha256
//	              of the .palm it came from and every file it put down
//
// All three are the shared `key = value` format with blank lines between
// records (util.odin), so `cat` is a sufficient tool for reading any of them.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

DEFAULT_ARCH :: "x86_64"

// CATEGORIES is the closed set a package's `category` may name. It is closed
// so a store can lay out a fixed set of shelves and a recipe's typo fails the
// build instead of opening a shelf of one.
CATEGORIES :: [?]string{"Accessories", "Development", "Graphics", "Internet", "Office", "System", "Multimedia", "Games"}

category_valid :: proc(s: string) -> bool {
	for c in CATEGORIES {
		if c == s {
			return true
		}
	}
	return false
}

// icon_valid keeps an icon name to what a front end can look up and what a
// record line can hold: lowercase words joined by '-'.
icon_valid :: proc(s: string) -> bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for c in transmute([]byte)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '-':
		case:
			return false
		}
	}
	return true
}

File_Rec :: struct {
	path:  string,
	type:  Entry_Type,
	mode:  u32,
	uid:   int,
	gid:   int,
	sha:   string, // sha256 for files, the target for symlinks and hard links
}

Pkg :: struct {
	name:          string,
	version:       string, // "1.2.3-r0"
	desc:          string,
	arch:          string,
	license:       string,
	url:           string,
	// What a graphical front end (apps/store) shows. All three are optional
	// and an older index simply has none of them: `category` is one of
	// CATEGORIES, `icon` names an icon the front end knows (a lucide name),
	// and `details` is longer prose than the one-line pkgdesc, one paragraph
	// per `details` line.
	category:      string,
	icon:          string,
	details:       string,
	size:          i64, // installed size
	csize:         i64, // size of the .palm
	sha256:        string, // of the .palm
	depends:       []string,
	provides:      []string,
	// conflicts: constraints no package installed beside this one may meet.
	// replaces: packages this one takes over (pacman's meaning: a rename or
	// a merge); `palm upgrade` installs it in their place, and like a
	// conflict it is never installed beside them.
	conflicts:     []string,
	replaces:      []string,
	install_users: []string,
	filename:      string, // in the repository
	repo:          ^Repo, // nil when only installed
	files:         []File_Rec, // installed packages only
	installed:     bool,
}

pkg_id :: proc(p: ^Pkg) -> string {
	return fmt.tprintf("%s-%s", p.name, p.version)
}

pkg_filename :: proc(p: ^Pkg, allocator := context.allocator) -> string {
	return fmt.aprintf("%s-%s.palm", p.name, p.version, allocator = allocator)
}

// pkg_from_record fills a Pkg from any of the three forms. Unknown keys are
// ignored, so a newer palm can add fields an older one still reads past.
pkg_from_record :: proc(rec: []KV, allocator := context.allocator) -> (Pkg, Err) {
	context.allocator = allocator
	p: Pkg
	deps := make([dynamic]string)
	provs := make([dynamic]string)
	users := make([dynamic]string)
	confl := make([dynamic]string)
	repl := make([dynamic]string)
	files := make([dynamic]File_Rec)
	paras := make([dynamic]string, context.temp_allocator)
	for kv in rec {
		v := strings.clone(kv.value)
		switch kv.key {
		case "pkgname":
			p.name = v
		case "pkgver":
			p.version = v
		case "pkgdesc":
			p.desc = v
		case "arch":
			p.arch = v
		case "license":
			p.license = v
		case "url":
			p.url = v
		case "category":
			p.category = v
		case "icon":
			p.icon = v
		case "details":
			append(&paras, v)
		case "size":
			p.size, _ = strconv.parse_i64(v)
		case "csize":
			p.csize, _ = strconv.parse_i64(v)
		case "sha256":
			p.sha256 = v
		case "depend":
			for d in strings.fields(v) {
				append(&deps, d)
			}
		case "provides":
			for d in strings.fields(v) {
				append(&provs, d)
			}
		case "conflicts":
			for d in strings.fields(v) {
				append(&confl, d)
			}
		case "replaces":
			for d in strings.fields(v) {
				append(&repl, d)
			}
		case "install_user":
			append(&users, v)
		case "filename":
			p.filename = v
		case "file":
			f, ok := parse_file_rec(v)
			if !ok {
				return p, fail(EXIT_FAILED, "line %d: malformed file record", kv.line)
			}
			append(&files, f)
		}
	}
	p.depends = deps[:]
	p.provides = provs[:]
	p.install_users = users[:]
	p.conflicts = confl[:]
	p.replaces = repl[:]
	p.files = files[:]
	if len(paras) > 0 {
		p.details = strings.join(paras[:], "\n")
	}
	if p.arch == "" {
		p.arch = DEFAULT_ARCH
	}
	if !name_valid(p.name) {
		return p, fail(EXIT_FAILED, "record has no valid pkgname (%q)", p.name)
	}
	if p.version == "" || !version_valid(p.version) {
		return p, fail(EXIT_FAILED, "%s: invalid pkgver %q", p.name, p.version)
	}
	for list in ([3][]string{p.depends, p.conflicts, p.replaces}) {
		for d in list {
			if _, ok := parse_constraint(d); !ok {
				return p, fail(EXIT_FAILED, "%s: invalid constraint %q", p.name, d)
			}
		}
	}
	return p, Err{}
}

// What gets written where.
Pkg_Form :: enum {
	Pkginfo,
	Index,
	Installed,
}

pkg_write :: proc(b: ^strings.Builder, p: ^Pkg, form: Pkg_Form) {
	fmt.sbprintf(b, "pkgname = %s\n", p.name)
	fmt.sbprintf(b, "pkgver = %s\n", p.version)
	if p.desc != "" {fmt.sbprintf(b, "pkgdesc = %s\n", p.desc)}
	fmt.sbprintf(b, "arch = %s\n", p.arch != "" ? p.arch : DEFAULT_ARCH)
	if p.license != "" {fmt.sbprintf(b, "license = %s\n", p.license)}
	if p.url != "" {fmt.sbprintf(b, "url = %s\n", p.url)}
	if p.category != "" {fmt.sbprintf(b, "category = %s\n", p.category)}
	if p.icon != "" {fmt.sbprintf(b, "icon = %s\n", p.icon)}
	if p.details != "" {
		for para in strings.split_lines(p.details, context.temp_allocator) {
			if para != "" {fmt.sbprintf(b, "details = %s\n", para)}
		}
	}
	fmt.sbprintf(b, "size = %d\n", p.size)
	if form != .Pkginfo {
		if form == .Index {fmt.sbprintf(b, "csize = %d\n", p.csize)}
		fmt.sbprintf(b, "sha256 = %s\n", p.sha256)
	}
	for d in p.depends {fmt.sbprintf(b, "depend = %s\n", d)}
	for d in p.provides {fmt.sbprintf(b, "provides = %s\n", d)}
	for d in p.conflicts {fmt.sbprintf(b, "conflicts = %s\n", d)}
	for d in p.replaces {fmt.sbprintf(b, "replaces = %s\n", d)}
	for u in p.install_users {fmt.sbprintf(b, "install_user = %s\n", u)}
	if form == .Index {
		fmt.sbprintf(b, "filename = %s\n", p.filename != "" ? p.filename : pkg_filename(p, context.temp_allocator))
	}
	if form == .Installed {
		for f in p.files {
			fmt.sbprintf(b, "file = %s\n", file_rec_string(f))
		}
	}
}

// A file record is five tab-separated fields, the path last:
//
//	f	0755	0:0	<sha256>	/usr/bin/foo
//	l	0777	0:0	usr/bin	/bin
//	d	0755	1000:1000	-	/home/palm
//	h	0755	0:0	/usr/bin/a	/usr/bin/b
//
// Tabs, because paths may contain spaces; package paths may not contain tabs
// or newlines, and the archive reader refuses any that do.
file_rec_string :: proc(f: File_Rec) -> string {
	t := "f"
	switch f.type {
	case .File:
		t = "f"
	case .Dir:
		t = "d"
	case .Symlink:
		t = "l"
	case .Hardlink:
		t = "h"
	}
	sha := f.sha != "" ? f.sha : "-"
	return fmt.tprintf("%s\t%04o\t%d:%d\t%s\t%s", t, f.mode, f.uid, f.gid, sha, f.path)
}

parse_file_rec :: proc(s: string) -> (File_Rec, bool) {
	parts := strings.split_n(s, "\t", 5, context.temp_allocator)
	if len(parts) != 5 {
		return {}, false
	}
	f: File_Rec
	switch parts[0] {
	case "f":
		f.type = .File
	case "d":
		f.type = .Dir
	case "l":
		f.type = .Symlink
	case "h":
		f.type = .Hardlink
	case:
		return {}, false
	}
	mode, ok := parse_octal(parts[1])
	if !ok {
		return {}, false
	}
	f.mode = mode
	ug := strings.split_n(parts[2], ":", 2, context.temp_allocator)
	if len(ug) != 2 {
		return {}, false
	}
	f.uid, _ = strconv.parse_int(ug[0])
	f.gid, _ = strconv.parse_int(ug[1])
	f.sha = parts[3] == "-" ? "" : strings.clone(parts[3])
	f.path = strings.clone(parts[4])
	return f, true
}

// provides_entry splits "so:libc.so.6=6" into its name and optional version.
provides_entry :: proc(s: string) -> (name, version: string) {
	if i := strings.index_byte(s, '='); i > 0 {
		return s[:i], s[i + 1:]
	}
	return s, ""
}

// pkg_satisfies: does p meet the constraint, by its own name or something it
// provides? A versionless provide satisfies only versionless constraints.
pkg_satisfies :: proc(p: ^Pkg, c: Constraint) -> bool {
	if p.name == c.name {
		return version_satisfies(p.version, c.op, c.version)
	}
	for pr in p.provides {
		n, v := provides_entry(pr)
		if n != c.name {
			continue
		}
		if c.op == .Any {
			return true
		}
		if v != "" && version_satisfies(v, c.op, c.version) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// PALMINDEX
// ---------------------------------------------------------------------------

INDEX_HEADER :: "# PALMINDEX format 1. Integrity: the detached ed25519 signature in PALMINDEX.sig.\n"

// index_write writes the index. `generated` (unix seconds) goes into the
// header comment, inside the signed bytes, where palm reads it back to refuse
// an index older than one it has already seen (repo.odin); a comment, so an
// older palm reads past it.
index_write :: proc(pkgs: []Pkg, generated: i64 = 0, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, INDEX_HEADER)
	if generated > 0 {
		fmt.sbprintf(&b, "# generated = %d\n", generated)
	}
	sorted := slice.clone(pkgs, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Pkg) -> bool {
		if a.name != b.name {
			return a.name < b.name
		}
		return version_compare(a.version, b.version) < 0
	})
	for &p in sorted {
		strings.write_byte(&b, '\n')
		pkg_write(&b, &p, .Index)
	}
	return strings.to_string(b)
}

index_parse :: proc(text: string, allocator := context.allocator) -> ([]Pkg, Err) {
	out := make([dynamic]Pkg, allocator)
	for rec in parse_records(text, context.temp_allocator) {
		p, e := pkg_from_record(rec, allocator)
		if !ok(e) {
			return nil, e
		}
		if p.sha256 == "" || p.filename == "" {
			return nil, fail(EXIT_FAILED, "index record for %s has no sha256 or filename", p.name)
		}
		if strings.contains(p.filename, "/") || strings.has_prefix(p.filename, ".") {
			return nil, fail(EXIT_REFUSED, "index record for %s names an unsafe file %q", p.name, p.filename)
		}
		append(&out, p)
	}
	return out[:], Err{}
}
