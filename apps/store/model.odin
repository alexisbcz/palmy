package main

// What Software knows, and where it learns it.
//
// Everything read-only comes from palm itself, run as the user who is looking:
//
//	palm list --json                every package, installed or available
//	palm list --upgradable --json   the ones with something newer
//	palm info <pkg> --json          one package, with required_by
//	palm info -L <pkg> --json       its files
//
// There is no second copy of palm's database and no parser of its files: if
// palm can say it, Software asks palm, so the window can never disagree with
// the command line. Changes go the other way, through palmd (daemon.odin).
//
// `--demo` and `--shots` swap the source for fabricated data (demo.odin), so
// a screenshot of Software never shows the machine it was taken on.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

PALM :: "palm"

Package :: struct {
	name:           string,
	version:        string, // newest available, else the installed one
	summary:        string, // pkgdesc: one line
	details:        string, // paragraphs separated by '\n'
	license:        string,
	url:            string,
	category:       string,
	icon:           string,
	size:           i64, // installed size of `version`
	csize:          i64, // download size of `version`
	depends:        []string,
	provides:       []string,
	installed:      string, // installed version, "" if not installed
	installed_size: i64,
	explicit:       bool, // in world: the user asked for it
	upgradable:     bool,
	// filled in when the package's page is opened
	required_by:    []string,
	files:          []string,
	files_loaded:   bool,
	info_loaded:    bool,
}

// CATEGORIES is palm's closed list (distro/palm/PALMBUILD.md), in the order
// Discover shows its shelves.
CATEGORIES := [?]string{"Accessories", "Development", "Graphics", "Internet", "Multimedia", "Office", "Games", "System"}

Catalog :: struct {
	pkgs:      [dynamic]Package,
	error:     string, // why the last load failed, verbatim from palm
	loaded_at: f64,
}

// ---------------------------------------------------------------------------
// Running palm
// ---------------------------------------------------------------------------

Run_Result :: struct {
	out:  string,
	err:  string,
	code: int,
	ok:   bool, // it started at all
}

// palm_run runs palm and keeps stdout, stderr and the exit status apart.
// kit.run will not do here: `palm search` exits 3 when nothing matches, and
// that is an answer, not a failure.
palm_run :: proc(args: ..string) -> Run_Result {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, palm_binary())
	append(&argv, ..args)
	state, sout, serr, err := os.process_exec({command = argv[:]}, context.temp_allocator)
	if err != nil {
		return {err = fmt.tprintf("could not run %s: %v", argv[0], err), code = 127}
	}
	return {out = string(sout), err = string(serr), code = state.exit_code, ok = true}
}

// palm_binary is `palm`, or $STORE_PALM for tests that point at a fake.
palm_binary :: proc() -> string {
	if v := os.get_env("STORE_PALM", context.temp_allocator); v != "" {
		return v
	}
	return PALM
}

// palm_failure turns a failed run into the message palm itself gave.
palm_failure :: proc(r: Run_Result) -> string {
	if !r.ok {
		return r.err
	}
	if v, err := json.parse(transmute([]u8)strings.trim_space(r.out), .JSON, true, context.temp_allocator); err == nil {
		if obj, is := v.(json.Object); is {
			if e, has := obj["error"].(json.String); has {
				return string(e)
			}
		}
	}
	if e := strings.trim_space(r.err); e != "" {
		return e
	}
	return fmt.tprintf("palm exited with status %d", r.code)
}

// ---------------------------------------------------------------------------
// Decoding palm's JSON
// ---------------------------------------------------------------------------

@(private = "file")
jstr :: proc(obj: json.Object, key: string, allocator := context.allocator) -> string {
	if v, ok := obj[key].(json.String); ok {
		return strings.clone(string(v), allocator)
	}
	return ""
}

@(private = "file")
jint :: proc(obj: json.Object, key: string) -> i64 {
	#partial switch v in obj[key] {
	case json.Integer:
		return i64(v)
	case json.Float:
		return i64(v)
	}
	return 0
}

@(private = "file")
jbool :: proc(obj: json.Object, key: string) -> bool {
	if v, ok := obj[key].(json.Boolean); ok {
		return bool(v)
	}
	return false
}

@(private = "file")
jstrs :: proc(obj: json.Object, key: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if arr, ok := obj[key].(json.Array); ok {
		for e in arr {
			if s, is := e.(json.String); is {
				append(&out, strings.clone(string(s), allocator))
			}
		}
	}
	return out[:]
}

// package_from_json reads one object of palm's pkg_json shape.
package_from_json :: proc(obj: json.Object, allocator := context.allocator) -> Package {
	p: Package
	p.name = jstr(obj, "name", allocator)
	p.version = jstr(obj, "version", allocator)
	p.summary = jstr(obj, "description", allocator)
	p.details = jstr(obj, "details", allocator)
	p.license = jstr(obj, "license", allocator)
	p.url = jstr(obj, "url", allocator)
	p.category = jstr(obj, "category", allocator)
	p.icon = jstr(obj, "icon", allocator)
	p.size = jint(obj, "size")
	p.csize = jint(obj, "csize")
	p.depends = jstrs(obj, "depends", allocator)
	p.provides = jstrs(obj, "provides", allocator)
	p.installed = jstr(obj, "installed", allocator)
	p.installed_size = jint(obj, "installed_size")
	p.explicit = jbool(obj, "explicit")
	if _, has := obj["required_by"]; has {
		p.required_by = jstrs(obj, "required_by", allocator)
		p.info_loaded = true
	}
	if _, has := obj["files"]; has {
		p.files = jstrs(obj, "files", allocator)
		p.files_loaded = true
	}
	return p
}

// parse_package_list decodes the array `palm list|search|info --json` prints.
parse_package_list :: proc(text: string, allocator := context.allocator) -> (out: [dynamic]Package, ok: bool) {
	out = make([dynamic]Package, allocator)
	v, err := json.parse(transmute([]u8)strings.trim_space(text), .JSON, true, context.temp_allocator)
	if err != nil {
		return out, false
	}
	arr, is := v.(json.Array)
	if !is {
		return out, false
	}
	for e in arr {
		if obj, isobj := e.(json.Object); isobj {
			append(&out, package_from_json(obj, allocator))
		}
	}
	return out, true
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

// catalog_load asks palm for everything. Upgradability is a second question
// rather than a version comparison done here: palm's version order is apk's,
// and a second implementation of it is a second chance to get it wrong.
catalog_load :: proc(c: ^Catalog) {
	r := palm_run("list", "--json")
	if !r.ok || r.code != 0 {
		c.error = strings.clone(palm_failure(r))
		return
	}
	pkgs, ok := parse_package_list(r.out)
	if !ok {
		c.error = strings.clone("palm list --json printed something that is not a package list")
		return
	}
	up := palm_run("list", "--upgradable", "--json")
	if up.ok && up.code == 0 {
		if ups, uok := parse_package_list(up.out, context.temp_allocator); uok {
			for u in ups {
				for &p in pkgs {
					if p.name == u.name {p.upgradable = true}
				}
			}
		}
	}
	catalog_set(c, pkgs)
	c.error = ""
}

catalog_set :: proc(c: ^Catalog, pkgs: [dynamic]Package) {
	delete(c.pkgs)
	c.pkgs = pkgs
	slice.sort_by(c.pkgs[:], proc(a, b: Package) -> bool {return a.name < b.name})
}

// package_load_info fills in what only `palm info` says: who needs it.
package_load_info :: proc(p: ^Package) {
	if p.info_loaded {
		return
	}
	p.info_loaded = true
	r := palm_run("info", p.name, "--json")
	if !r.ok || r.code != 0 {
		return
	}
	if list, ok := parse_package_list(r.out, context.temp_allocator); ok && len(list) == 1 {
		p.required_by = slice.clone(list[0].required_by)
		for &s in p.required_by {s = strings.clone(s)}
		if p.details == "" {p.details = strings.clone(list[0].details)}
	}
}

// package_load_files reads the file list. For a package that is not
// installed palm has to fetch the .palm to read it, which is why this waits
// for the page to ask rather than happening for every package on load.
package_load_files :: proc(p: ^Package) -> string {
	if p.files_loaded {
		return ""
	}
	r := palm_run("info", "-L", p.name, "--json")
	if !r.ok || r.code != 0 {
		return palm_failure(r)
	}
	list, ok := parse_package_list(r.out, context.temp_allocator)
	if !ok || len(list) != 1 {
		return "palm info -L printed something unexpected"
	}
	files := make([dynamic]string)
	for f in list[0].files {
		// Directories are every package's skeleton; the page lists what the
		// package actually puts there.
		if is_dir_entry(f, list[0].files) {continue}
		append(&files, strings.clone(f))
	}
	p.files = files[:]
	p.files_loaded = true
	return ""
}

// is_dir_entry: palm's file list includes every parent directory; a path that
// is a prefix of another path in the list is one of those.
is_dir_entry :: proc(f: string, all: []string) -> bool {
	prefix := strings.concatenate({f, "/"}, context.temp_allocator)
	for g in all {
		if strings.has_prefix(g, prefix) {return true}
	}
	return false
}

// ---------------------------------------------------------------------------
// Questions the views ask
// ---------------------------------------------------------------------------

find :: proc(c: ^Catalog, name: string) -> ^Package {
	for &p in c.pkgs {
		if p.name == name {return &p}
	}
	return nil
}

// command_of is the program a package installs under its own name, which is
// what Open runs. A package without one has nothing to open.
command_of :: proc(p: ^Package) -> string {
	for pr in p.provides {
		if pr == fmt.tprintf("cmd:%s", p.name) {
			return p.name
		}
	}
	return ""
}

// is_app: a package that installs a program under its own name. Discover puts
// those ahead of libraries and data on every shelf.
is_app :: proc(p: ^Package) -> bool {
	return command_of(p) != ""
}

in_category :: proc(c: ^Catalog, cat: string, allocator := context.temp_allocator) -> []^Package {
	out := make([dynamic]^Package, allocator)
	for &p in c.pkgs {
		if p.category == cat {append(&out, &p)}
	}
	slice.sort_by(out[:], proc(a, b: ^Package) -> bool {
		if is_app(a) != is_app(b) {return is_app(a)}
		return a.name < b.name
	})
	return out[:]
}

// matches is the live search: every word must appear in the name, the
// summary or the category, case-insensitively -- what `palm search` does,
// done here so it can run on every keystroke without a process per letter.
matches :: proc(p: ^Package, query: string) -> bool {
	q := strings.trim_space(query)
	if q == "" {return true}
	hay := strings.to_lower(fmt.tprintf("%s %s %s", p.name, p.summary, p.category), context.temp_allocator)
	for w in strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator) {
		if !strings.contains(hay, w) {return false}
	}
	return true
}

search :: proc(c: ^Catalog, query: string, allocator := context.temp_allocator) -> []^Package {
	out := make([dynamic]^Package, allocator)
	for &p in c.pkgs {
		if matches(&p, query) {append(&out, &p)}
	}
	// A name that starts with the query is the answer people are looking for.
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	rank :: proc(p: ^Package, q: string) -> int {
		if p.name == q {return 0}
		if strings.has_prefix(p.name, q) {return 1}
		if strings.contains(p.name, q) {return 2}
		return 3
	}
	for i in 1 ..< len(out) {
		for j := i; j > 0; j -= 1 {
			a, b := out[j - 1], out[j]
			ra, rb := rank(a, q), rank(b, q)
			if ra > rb || (ra == rb && a.name > b.name) {
				out[j - 1], out[j] = b, a
			} else {
				break
			}
		}
	}
	return out[:]
}

installed :: proc(c: ^Catalog, explicit_only: bool, allocator := context.temp_allocator) -> []^Package {
	out := make([dynamic]^Package, allocator)
	for &p in c.pkgs {
		if p.installed == "" {continue}
		if explicit_only && !p.explicit {continue}
		append(&out, &p)
	}
	return out[:]
}

upgradable :: proc(c: ^Catalog, allocator := context.temp_allocator) -> []^Package {
	out := make([dynamic]^Package, allocator)
	for &p in c.pkgs {
		if p.upgradable {append(&out, &p)}
	}
	return out[:]
}

// featured is Discover's first shelf: a few applications worth installing
// that are not installed yet, falling back to installed ones so the shelf is
// never empty on a machine that has everything.
FEATURED := [?]string{"track", "emoji", "photoshop", "torrent", "sheets", "maps"}

featured :: proc(c: ^Catalog, n: int, allocator := context.temp_allocator) -> []^Package {
	out := make([dynamic]^Package, allocator)
	for pass in 0 ..< 2 {
		for name in FEATURED {
			p := find(c, name)
			if p == nil || len(out) >= n {continue}
			if (pass == 0) == (p.installed == "") {
				if !slice.contains(out[:], p) {append(&out, p)}
			}
		}
	}
	return out[:]
}

// rdeps_local is required_by computed from the catalog, for when palm info
// has not been asked yet (and for the demo).
rdeps_local :: proc(c: ^Catalog, p: ^Package, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for &q in c.pkgs {
		if q.installed == "" || q.name == p.name {continue}
		for d in q.depends {
			n := dep_name(d)
			if n == p.name || provided_by(p, n) {
				append(&out, q.name)
				break
			}
		}
	}
	return out[:]
}

// dep_name strips a constraint down to the name: "libgui>=2" -> "libgui".
dep_name :: proc(d: string) -> string {
	for c, i in transmute([]u8)d {
		switch c {
		case '<', '>', '=', '~':
			return d[:i]
		}
	}
	return d
}

provided_by :: proc(p: ^Package, name: string) -> bool {
	for pr in p.provides {
		n := pr
		if i := strings.index_byte(pr, '='); i > 0 {n = pr[:i]}
		if n == name {return true}
	}
	return false
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

human_size :: proc(n: i64) -> string {
	f := f64(n)
	switch {
	case n < 0:
		return fmt.tprintf("-%s", human_size(-n))
	case n < 1000:
		return fmt.tprintf("%d B", n)
	case n < 1000 * 1000:
		return fmt.tprintf("%.0f kB", f / 1000)
	case n < 10 * 1000 * 1000:
		return fmt.tprintf("%.1f MB", f / 1e6)
	case n < 1000 * 1000 * 1000:
		return fmt.tprintf("%.0f MB", f / 1e6)
	}
	return fmt.tprintf("%.1f GB", f / 1e9)
}

// version_short drops palm's packaging release for display: 0.1.0-r0 -> 0.1.0.
version_short :: proc(v: string) -> string {
	if i := strings.last_index(v, "-r"); i > 0 {
		return v[:i]
	}
	return v
}
