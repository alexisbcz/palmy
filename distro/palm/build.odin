package palm

// `palm build <dir> -o <outdir>` and `palm index <outdir> --key <secret>`.
//
// A recipe is a PALMBUILD file: declarations, not a script. It says what the
// package is called and where each file comes from and goes, and palm builds
// the archive from that alone -- no shell, no fakeroot, no build machine
// owners leaking in. The format is documented in PALMBUILD.md beside this
// file; in short:
//
//	pkgname = term
//	pkgver  = 0.1.0
//	pkgrel  = 0
//	pkgdesc = The palmy terminal
//	depend  = glibc palmframe-fonts
//	file    = ../../out/bin/term -> /usr/bin/term mode 0755
//	tree    = share -> /usr/share/term
//	dir     = /etc/term
//	symlink = /usr/bin/terminal -> term
//	owner   = /etc/term palm:palm
//
// Building does not compile anything. Compiling is the recipe tree's job
// (distro/recipes); a PALMBUILD only packs what already exists, which is what
// lets the same tool run on the host and inside the distribution.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// The accounts CONTRACT.md fixes, so a recipe may say `palm:palm` and get the
// right numbers in the archive without a passwd file to read them from.
@(private = "file")
Known_Id :: struct {
	name: string,
	id:   int,
}
@(private = "file")
KNOWN_USERS := [?]Known_Id{{"root", 0}, {"greeter", 900}, {"palm", 1000}}
@(private = "file")
KNOWN_GROUPS := [?]Known_Id {
	{"root", 0},
	{"tty", 5},
	{"wheel", 10},
	{"video", 39},
	{"audio", 63},
	{"input", 97},
	{"greeter", 900},
	{"palm", 1000},
}

@(private = "file")
Build_Entry :: struct {
	path:  string,
	type:  Entry_Type,
	mode:  u32,
	uid:   int,
	gid:   int,
	uname: string,
	gname: string,
	src:   string, // host file, for .File
	link:  string,
}

@(private = "file")
Recipe :: struct {
	dir:     string,
	pkg:     Pkg,
	pkgver:  string,
	pkgrel:  string,
	entries: map[string]^Build_Entry,
}

@(private = "file")
recipe_err :: proc(line: int, format: string, args: ..any) -> Err {
	return fail(EXIT_USAGE, "PALMBUILD line %d: %s", line, fmt.tprintf(format, ..args))
}

// expand_vars replaces ${NAME} with the environment's value, so a recipe can
// point at ${PALMY_OUT}/bin/term without hard-coding the checkout location.
@(private = "file")
expand_vars :: proc(s: string) -> (string, bool) {
	if !strings.contains(s, "${") {
		return s, true
	}
	b := strings.builder_make(context.temp_allocator)
	rest := s
	for {
		i := strings.index(rest, "${")
		if i < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:i])
		j := strings.index_byte(rest[i:], '}')
		if j < 0 {
			return "", false
		}
		name := rest[i + 2:i + j]
		v, found := os.lookup_env(name, context.temp_allocator)
		if !found {
			return "", false
		}
		strings.write_string(&b, v)
		rest = rest[i + j + 1:]
	}
	return strings.to_string(b), true
}

@(private = "file")
source_path :: proc(r: ^Recipe, s: string, line: int) -> (string, Err) {
	x, okv := expand_vars(s)
	if !okv {
		return "", recipe_err(line, "%q uses an unset variable", s)
	}
	if !strings.has_prefix(x, "/") {
		x = fmt.tprintf("%s/%s", r.dir, x)
	}
	return strings.clone(x), Err{}
}

// split_arrow splits "a -> b mode 0755" into a, b and the trailing options.
@(private = "file")
split_arrow :: proc(v: string) -> (lhs, rhs: string, mode: u32, has_mode: bool, okk: bool) {
	i := strings.index(v, " -> ")
	if i < 0 {
		return
	}
	lhs = strings.trim_space(v[:i])
	rhs = strings.trim_space(v[i + 4:])
	if j := strings.index(rhs, " mode "); j >= 0 {
		m, okm := parse_octal(strings.trim_space(rhs[j + 6:]))
		if !okm {
			return
		}
		mode, has_mode = m, true
		rhs = strings.trim_space(rhs[:j])
	}
	okk = lhs != "" && rhs != ""
	return
}

@(private = "file")
parse_id :: proc(s: string, known: []Known_Id) -> (name: string, id: int, okk: bool) {
	if i := strings.index_byte(s, '='); i > 0 {
		n, okn := parse_int_strict(s[i + 1:])
		return s[:i], n, okn && name_valid(s[:i])
	}
	if n, okn := parse_int_strict(s); okn {
		for k in known {
			if k.id == n {
				return k.name, n, true
			}
		}
		return "", n, true
	}
	for k in known {
		if k.name == s {
			return s, k.id, true
		}
	}
	return "", 0, false
}

@(private = "file")
add_entry :: proc(r: ^Recipe, e: Build_Entry, line: int) -> Err {
	if prev, has := r.entries[e.path]; has {
		if prev.type == .Dir && e.type == .Dir {
			prev.mode = e.mode
			return Err{}
		}
		return recipe_err(line, "%s is declared twice", e.path)
	}
	x := new(Build_Entry)
	x^ = e
	if x.uname == "" {x.uname = "root"}
	if x.gname == "" {x.gname = "root"}
	r.entries[x.path] = x
	return Err{}
}

@(private = "file")
dest_path :: proc(s: string, line: int) -> (string, Err) {
	if !strings.has_prefix(s, "/") {
		return "", recipe_err(line, "destination %q must be absolute", s)
	}
	p, okp := clean_pkg_path(s)
	if !okp || p == "/" {
		return "", recipe_err(line, "destination %q is not a usable path", s)
	}
	return p, Err{}
}

@(private = "file")
exec_mode :: proc(fi: os.File_Info) -> u32 {
	return (fi.mode & {.Execute_User, .Execute_Group, .Execute_Other}) != {} ? 0o755 : 0o644
}

@(private = "file")
add_tree :: proc(r: ^Recipe, src, dest: string, line: int) -> Err {
	infos, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {
		return recipe_err(line, "cannot read the directory %s", src)
	}
	if e := add_entry(r, Build_Entry{path = dest, type = .Dir, mode = 0o755}, line); !ok(e) {
		return e
	}
	for fi in infos {
		child_src := fmt.tprintf("%s/%s", src, fi.name)
		child_dest, okp := clean_pkg_path(fmt.tprintf("%s/%s", dest, fi.name))
		if !okp {
			return recipe_err(line, "%s has a name palm cannot package", child_src)
		}
		lfi, lerr := os.stat_do_not_follow_links(child_src, context.temp_allocator)
		if lerr != nil {
			return recipe_err(line, "cannot stat %s", child_src)
		}
		#partial switch lfi.type {
		case .Directory:
			if e := add_tree(r, child_src, child_dest, line); !ok(e) {
				return e
			}
		case .Symlink:
			target, rerr := os.read_link(child_src, context.allocator)
			if rerr != nil {
				return recipe_err(line, "cannot read the link %s", child_src)
			}
			if e := add_entry(r, Build_Entry{path = child_dest, type = .Symlink, mode = 0o777, link = target}, line); !ok(e) {
				return e
			}
		case .Regular:
			if e := add_entry(r, Build_Entry{path = child_dest, type = .File, mode = exec_mode(lfi), src = strings.clone(child_src)}, line); !ok(e) {
				return e
			}
		case:
			return recipe_err(line, "%s is not a file, directory or symlink", child_src)
		}
	}
	return Err{}
}

@(private = "file")
parse_recipe :: proc(dir: string) -> (^Recipe, Err) {
	path := fmt.tprintf("%s/PALMBUILD", dir)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, fail(EXIT_NOT_FOUND, "no PALMBUILD in %s", dir)
	}
	r := new(Recipe)
	abs, _ := os.get_absolute_path(dir, context.allocator)
	r.dir = abs
	r.pkgrel = "0"
	deps := make([dynamic]string)
	provs := make([dynamic]string)
	users := make([dynamic]string)
	Override :: struct {
		path:      string,
		recursive: bool,
		mode:      u32,
		is_mode:   bool,
		uid, gid:  int,
		uname:     string,
		gname:     string,
		line:      int,
	}
	overrides := make([dynamic]Override)

	recs := parse_records(string(data))
	for rec in recs {
		for kv in rec {
			v := kv.value
			switch kv.key {
			case "pkgname":
				r.pkg.name = v
			case "pkgver":
				r.pkgver = v
			case "pkgrel":
				r.pkgrel = v
			case "pkgdesc":
				r.pkg.desc = v
			case "license":
				r.pkg.license = v
			case "url":
				r.pkg.url = v
			case "category":
				if !category_valid(v) {
					return nil, recipe_err(kv.line, "category %q is not one of %v", v, CATEGORIES)
				}
				r.pkg.category = v
			case "icon":
				if !icon_valid(v) {
					return nil, recipe_err(kv.line, "icon %q is not a lowercase icon name", v)
				}
				r.pkg.icon = v
			case "details":
				r.pkg.details = r.pkg.details == "" ? v : fmt.aprintf("%s\n%s", r.pkg.details, v)
			case "arch":
				r.pkg.arch = v
			case "depend":
				for d in strings.fields(v) {
					if _, okc := parse_constraint(d); !okc {
						return nil, recipe_err(kv.line, "invalid dependency %q", d)
					}
					append(&deps, d)
				}
			case "provides":
				for d in strings.fields(v) {
					n, _ := provides_entry(d)
					if !name_valid(n) {
						return nil, recipe_err(kv.line, "invalid provides %q", d)
					}
					append(&provs, d)
				}
			case "install_user":
				append(&users, v)
			case "file":
				lhs, rhs, mode, has_mode, oka := split_arrow(v)
				if !oka {
					return nil, recipe_err(kv.line, "expected `file = <source> -> /dest [mode 0755]`")
				}
				src, se := source_path(r, lhs, kv.line)
				if !ok(se) {return nil, se}
				dest, de := dest_path(rhs, kv.line)
				if !ok(de) {return nil, de}
				fi, serr := os.stat(src, context.temp_allocator)
				if serr != nil || fi.type != .Regular {
					return nil, recipe_err(kv.line, "%s is not a readable file", src)
				}
				if !has_mode {mode = exec_mode(fi)}
				if e := add_entry(r, Build_Entry{path = dest, type = .File, mode = mode, src = src}, kv.line); !ok(e) {
					return nil, e
				}
			case "dir":
				d := v
				mode: u32 = 0o755
				if j := strings.index(v, " mode "); j >= 0 {
					m, okm := parse_octal(strings.trim_space(v[j + 6:]))
					if !okm {return nil, recipe_err(kv.line, "bad mode in %q", v)}
					mode = m
					d = strings.trim_space(v[:j])
				}
				dest, de := dest_path(d, kv.line)
				if !ok(de) {return nil, de}
				if e := add_entry(r, Build_Entry{path = dest, type = .Dir, mode = mode}, kv.line); !ok(e) {
					return nil, e
				}
			case "symlink":
				lhs, rhs, _, _, oka := split_arrow(v)
				if !oka {
					return nil, recipe_err(kv.line, "expected `symlink = /path -> target`")
				}
				dest, de := dest_path(lhs, kv.line)
				if !ok(de) {return nil, de}
				if strings.contains_any(rhs, "\t\n") {
					return nil, recipe_err(kv.line, "symlink target contains a tab or newline")
				}
				if e := add_entry(r, Build_Entry{path = dest, type = .Symlink, mode = 0o777, link = rhs}, kv.line); !ok(e) {
					return nil, e
				}
			case "tree":
				lhs, rhs, _, _, oka := split_arrow(v)
				if !oka {
					return nil, recipe_err(kv.line, "expected `tree = <source dir> -> /dest`")
				}
				src, se := source_path(r, lhs, kv.line)
				if !ok(se) {return nil, se}
				dest, de := dest_path(rhs, kv.line)
				if !ok(de) {return nil, de}
				if e := add_tree(r, src, dest, kv.line); !ok(e) {
					return nil, e
				}
			case "owner":
				f := strings.fields(v, context.temp_allocator)
				if len(f) != 2 {
					return nil, recipe_err(kv.line, "expected `owner = /path[/**] user:group`")
				}
				ov := Override {
					line = kv.line,
				}
				p := f[0]
				if strings.has_suffix(p, "/**") {
					ov.recursive = true
					p = p[:len(p) - 3]
				}
				dest, de := dest_path(p, kv.line)
				if !ok(de) {return nil, de}
				ov.path = dest
				ug := strings.split_n(f[1], ":", 2, context.temp_allocator)
				if len(ug) != 2 {
					return nil, recipe_err(kv.line, "owner %q must be user:group", f[1])
				}
				un, uid, oku := parse_id(ug[0], KNOWN_USERS[:])
				gn, gid, okg := parse_id(ug[1], KNOWN_GROUPS[:])
				if !oku || !okg {
					return nil, recipe_err(kv.line, "unknown owner %q (use a number, or name=number)", f[1])
				}
				ov.uid, ov.gid, ov.uname, ov.gname = uid, gid, un, gn
				append(&overrides, ov)
			case "mode":
				f := strings.fields(v, context.temp_allocator)
				if len(f) != 2 {
					return nil, recipe_err(kv.line, "expected `mode = /path 0755`")
				}
				dest, de := dest_path(f[0], kv.line)
				if !ok(de) {return nil, de}
				m, okm := parse_octal(f[1])
				if !okm {return nil, recipe_err(kv.line, "bad mode %q", f[1])}
				append(&overrides, Override{path = dest, mode = m, is_mode = true, line = kv.line})
			case:
				return nil, recipe_err(kv.line, "unknown key %q", kv.key)
			}
		}
	}
	if !name_valid(r.pkg.name) {
		return nil, fail(EXIT_USAGE, "PALMBUILD: pkgname %q is not valid", r.pkg.name)
	}
	if r.pkgver == "" || strings.contains(r.pkgver, "-") || !version_valid(r.pkgver) {
		return nil, fail(EXIT_USAGE, "PALMBUILD: pkgver %q is not a valid version (no -r here; that is pkgrel)", r.pkgver)
	}
	if _, okn := parse_int_strict(r.pkgrel); !okn {
		return nil, fail(EXIT_USAGE, "PALMBUILD: pkgrel %q is not a number", r.pkgrel)
	}
	r.pkg.version = fmt.aprintf("%s-r%s", r.pkgver, r.pkgrel)
	r.pkg.depends = deps[:]
	r.pkg.provides = provs[:]
	r.pkg.install_users = users[:]
	if r.pkg.arch == "" {r.pkg.arch = DEFAULT_ARCH}

	// Every parent directory is an entry, so a package carries its own
	// skeleton and removal knows which directories were its to remove.
	paths := make([dynamic]string, context.temp_allocator)
	for p in r.entries {append(&paths, p)}
	for p in paths {
		for d := parent_dir(p); d != "/"; d = parent_dir(d) {
			if _, has := r.entries[d]; !has {
				add_entry(r, Build_Entry{path = strings.clone(d), type = .Dir, mode = 0o755}, 0)
			}
		}
	}

	for ov in overrides {
		matched := false
		for p, e in r.entries {
			if p != ov.path && !(ov.recursive && strings.has_prefix(p, ov.path) && p[len(ov.path)] == '/') {
				continue
			}
			matched = true
			if ov.is_mode {
				e.mode = ov.mode
			} else {
				e.uid, e.gid = ov.uid, ov.gid
				e.uname = ov.uname != "" ? ov.uname : ""
				e.gname = ov.gname != "" ? ov.gname : ""
			}
		}
		if !matched {
			return nil, recipe_err(ov.line, "%s is not in the package", ov.path)
		}
	}
	return r, Err{}
}

// build_package builds <outdir>/<name>-<ver>-r<rel>.palm and returns its path.
build_package :: proc(dir, outdir: string) -> (string, Err) {
	r, e := parse_recipe(dir)
	if !ok(e) {
		return "", e
	}
	sorted := make([dynamic]^Build_Entry, context.temp_allocator)
	for _, x in r.entries {append(&sorted, x)}
	slice.sort_by(sorted[:], proc(a, b: ^Build_Entry) -> bool {return a.path < b.path})

	mtime: i64 = 0
	if v, found := os.lookup_env("SOURCE_DATE_EPOCH", context.temp_allocator); found {
		if n, okn := parse_int_strict(v); okn {mtime = i64(n)}
	}

	// Read every file first: the installed size goes into .PKGINFO, which
	// has to be the first member.
	contents := make([][]byte, len(sorted), context.temp_allocator)
	size: i64 = 0
	for x, i in sorted {
		if x.type != .File {continue}
		d, rerr := os.read_entire_file_from_path(x.src, context.allocator)
		if rerr != nil {
			return "", fail(EXIT_FAILED, "cannot read %s", x.src)
		}
		contents[i] = d
		size += i64(len(d))
	}
	r.pkg.size = size

	info := strings.builder_make(context.temp_allocator)
	pkg_write(&info, &r.pkg, .Pkginfo)
	tarball := make([dynamic]byte, 0, int(size) + 64 * 1024)
	tar_write(&tarball, Tar_Entry{path = ".PKGINFO", type = .File, mode = 0o644, uname = "root", gname = "root", mtime = mtime, data = transmute([]byte)strings.to_string(info)})
	for x, i in sorted {
		if x.uname == "" && x.uid != 0 {
			// a bare number with no known name: write the number as the name
			// too, so the reader's name lookup cannot pick someone else.
			x.uname = fmt.aprintf("%d", x.uid)
		}
		if x.gname == "" && x.gid != 0 {
			x.gname = fmt.aprintf("%d", x.gid)
		}
		tar_write(&tarball, Tar_Entry{path = x.path, type = x.type, mode = x.mode, uid = x.uid, gid = x.gid, uname = x.uname, gname = x.gname, mtime = mtime, link = x.link, data = contents[i]})
		delete(contents[i])
	}
	tar_finish(&tarball)
	gz := gzip_compress(tarball[:])
	delete(tarball)

	if !mkdir_p(outdir) {
		return "", fail(EXIT_FAILED, "cannot create %s", outdir)
	}
	out := fmt.aprintf("%s/%s", strings.trim_right(outdir, "/"), pkg_filename(&r.pkg, context.temp_allocator))
	if !write_file_atomic(out, gz) {
		return "", fail(EXIT_FAILED, "cannot write %s", out)
	}
	delete(gz)
	return out, Err{}
}

// build_index writes <dir>/PALMINDEX over every .palm in dir and, given a
// key, signs it into PALMINDEX.sig.
build_index :: proc(dir, key_path: string) -> (int, Err) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return 0, fail(EXIT_NOT_FOUND, "cannot read %s", dir)
	}
	pkgs := make([dynamic]Pkg)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".palm") || fi.type != .Regular {
			continue
		}
		data, rerr := os.read_entire_file_from_path(fi.fullpath, context.allocator)
		if rerr != nil {
			return 0, fail(EXIT_FAILED, "cannot read %s", fi.fullpath)
		}
		p, e := read_pkginfo(data)
		if !ok(e) {
			return 0, fail(e.code, "%s: %s", fi.name, e.msg)
		}
		p.sha256 = sha256_hex(data)
		p.csize = i64(len(data))
		p.filename = strings.clone(fi.name)
		delete(data)
		append(&pkgs, p)
	}
	text := index_write(pkgs[:])
	index_path := fmt.tprintf("%s/PALMINDEX", dir)
	sig_path := fmt.tprintf("%s/PALMINDEX.sig", dir)
	if !write_file_atomic(index_path, transmute([]byte)text) {
		return 0, fail(EXIT_FAILED, "cannot write %s", index_path)
	}
	if key_path == "" {
		_ = os.remove(sig_path)
		warn("no --key: %s is unsigned and clients will refuse it without --allow-untrusted", index_path)
		return len(pkgs), Err{}
	}
	priv, ke := load_secret(key_path)
	if !ok(ke) {
		return 0, ke
	}
	sig := sign_bytes(&priv, transmute([]byte)text, context.temp_allocator)
	if !write_file_atomic(sig_path, transmute([]byte)fmt.tprintf("%s\n", sig)) {
		return 0, fail(EXIT_FAILED, "cannot write %s", sig_path)
	}
	return len(pkgs), Err{}
}
