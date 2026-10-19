package palm

// The installed database and the world file.
//
//	/usr/lib/palm/db/installed   one record per installed package, every file
//	                             it put down with type, mode, owner and sha256
//	/etc/palm/world              what was asked for, one constraint per line
//
// The database lives under /usr because it describes /usr: a root filesystem
// image carries its own record of what is in it. Both files are rewritten
// whole, beside themselves, and renamed into place after every package of a
// transaction, so an interrupted `palm add` leaves a database that is true
// for every package it reached and silent about the rest.
//
// --initdb creates both in an empty root, which is how the image builder
// starts: `palm --root build/rootfs --initdb add palmy-base ...`.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

DB_PATH :: "/usr/lib/palm/db/installed"
WORLD_PATH :: "/etc/palm/world"

DB :: struct {
	root:  string,
	pkgs:  [dynamic]^Pkg,
	world: [dynamic]string,
}

db_open :: proc(o: ^Opts) -> (^DB, Err) {
	db := new(DB)
	db.root = o.root
	path := rooted(o.root, DB_PATH)
	if !os.exists(path) {
		if !o.initdb {
			return nil, fail(EXIT_NOT_FOUND, "no palm database at %s (use --initdb to create one)", path)
		}
		for d in ([?]string{"/etc/palm/keys", "/usr/lib/palm/db", "/var/cache/palm"}) {
			if !mkdir_p(rooted(o.root, d, context.temp_allocator)) {
				return nil, fail(EXIT_FAILED, "cannot create %s under %s", d, o.root)
			}
		}
		if !o.dry_run {
			if !write_file_atomic(path, nil) {
				return nil, fail(EXIT_FAILED, "cannot create %s", path)
			}
			wpath := rooted(o.root, WORLD_PATH, context.temp_allocator)
			if !os.exists(wpath) {
				write_file_atomic(wpath, nil)
			}
		}
	}
	data, _ := os.read_entire_file_from_path(path, context.allocator)
	for rec in parse_records(string(data), context.temp_allocator) {
		p := new(Pkg)
		e: Err
		p^, e = pkg_from_record(rec)
		if !ok(e) {
			return nil, fail(EXIT_FAILED, "%s: %s", path, e.msg)
		}
		p.installed = true
		append(&db.pkgs, p)
	}
	wdata, _ := os.read_entire_file_from_path(rooted(o.root, WORLD_PATH, context.temp_allocator), context.allocator)
	for line in strings.split_lines(string(wdata), context.temp_allocator) {
		l := strings.trim_space(line)
		if l != "" && l[0] != '#' {
			append(&db.world, l)
		}
	}
	return db, Err{}
}

db_find :: proc(db: ^DB, name: string) -> ^Pkg {
	for p in db.pkgs {
		if p.name == name {
			return p
		}
	}
	return nil
}

db_save :: proc(db: ^DB) -> Err {
	slice.sort_by(db.pkgs[:], proc(a, b: ^Pkg) -> bool {return a.name < b.name})
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# palm installed database -- written by palm, read by palm. Format: distro/palm/db.odin.\n")
	for p in db.pkgs {
		strings.write_byte(&b, '\n')
		pkg_write(&b, p, .Installed)
	}
	path := rooted(db.root, DB_PATH, context.temp_allocator)
	_ = os.make_directory_all(parent_dir(path))
	if !write_file_atomic(path, transmute([]byte)strings.to_string(b)) {
		return fail(EXIT_FAILED, "cannot write %s", path)
	}
	return Err{}
}

world_save :: proc(db: ^DB) -> Err {
	b := strings.builder_make(context.temp_allocator)
	sorted := slice.clone(db.world[:], context.temp_allocator)
	slice.sort(sorted)
	last := ""
	for w in sorted {
		if w != last {
			fmt.sbprintf(&b, "%s\n", w)
		}
		last = w
	}
	path := rooted(db.root, WORLD_PATH, context.temp_allocator)
	_ = os.make_directory_all(parent_dir(path))
	if !write_file_atomic(path, transmute([]byte)strings.to_string(b)) {
		return fail(EXIT_FAILED, "cannot write %s", path)
	}
	return Err{}
}

// world_name is the package name a world line refers to.
world_name :: proc(line: string) -> string {
	c, _ := parse_constraint(line)
	return c.name
}

// ---------------------------------------------------------------------------
// Users and groups of the target root
//
// Owners in an archive carry both a name and a number. The name wins when the
// target root knows it -- a package saying "palm" means whoever is palm on
// that system -- and the number is the fallback, for a root whose
// /etc/passwd has not been installed yet.
// ---------------------------------------------------------------------------

Id_Map :: struct {
	users:  map[string]int,
	groups: map[string]int,
}

load_ids :: proc(root: string, allocator := context.temp_allocator) -> Id_Map {
	m: Id_Map
	m.users = make(map[string]int, allocator)
	m.groups = make(map[string]int, allocator)
	read :: proc(path: string, into: ^map[string]int) {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			return
		}
		for line in strings.split_lines(string(data), context.temp_allocator) {
			f := strings.split(line, ":", context.temp_allocator)
			if len(f) < 3 || f[0] == "" {
				continue
			}
			id, okn := parse_int_strict(f[2])
			if okn {
				into[f[0]] = id
			}
		}
	}
	read(rooted(root, "/etc/passwd", context.temp_allocator), &m.users)
	read(rooted(root, "/etc/group", context.temp_allocator), &m.groups)
	return m
}

parse_int_strict :: proc(s: string) -> (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for c in transmute([]byte)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
		if n > 1 << 31 {
			return 0, false
		}
	}
	return n, true
}
