package palm

// palm -- the Palmframe package manager.
//
//	palm add <pkg>...         install, and record in world
//	palm del <pkg>...         remove, drop from world, and remove orphans
//	palm update               fetch and verify every repository index
//	palm upgrade              upgrade everything to the newest available
//	palm search <text>        search names and descriptions
//	palm info <pkg>           details; -L lists files; --who-owns <path>
//	palm list [--installed|--upgradable|--available]
//	palm verify [<pkg>...]    check installed files against recorded sha256
//	palm fix [<pkg>...]       reinstall packages with broken or missing files
//	palm build <dir> -o <outdir>          build a package from <dir>/PALMBUILD
//	palm index <dir> [--key <secret>]     write and sign <dir>/PALMINDEX
//	palm keygen <name>                    write <name>.sec and <name>.pub
//	palm --selftest
//
//	global: --root <dir>  --initdb  --repo <url|path> (repeatable)
//	        --keys-dir <dir>  --allow-untrusted  --no-cache  --json  --yes
//	        --dry-run
//
// Alpine's apk is the model, and the parts worth copying are copied: a world
// file that is the whole statement of intent, every transaction a fresh
// resolution of it, signed indexes over plain http, --root for assembling an
// image from the outside. The interfaces are fixed by distro/CONTRACT.md.
//
// What it does not have is install scripts. None, of any kind -- see
// install.odin for why that is the point rather than a missing feature.
//
// `palm` is also the name of the command surface (apps/palm: `palm notes
// list`, `palm schema`, ...). On a Palmframe system that binary lives at
// /usr/lib/palm/palm-surface, and any first word that is not one of the verbs
// above is handed to it, argv untouched, by exec. So both work:
//
//	palm add term          this program
//	palm notes list        the command surface
//
// Exit codes, shared with the rest of the palm surface:
//	0 ok   1 verify found problems   2 usage   3 not found
//	4 refused (a check failed, or it needs --yes)   6 unavailable   7 failed

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

VERSION :: "0.2.0"

SURFACE_PATH :: "/usr/lib/palm/palm-surface"

Opts :: struct {
	root:            string,
	initdb:          bool,
	repos:           [dynamic]string,
	keys_dir:        string,
	allow_untrusted: bool,
	no_cache:        bool,
	json:            bool,
	yes:             bool,
	dry_run:         bool,
	refresh:         bool, // -U: refresh the indexes first (add, upgrade)
	// verb options
	list_files:      bool,
	who_owns:        string,
	installed:       bool,
	upgradable:      bool,
	available:       bool,
	out_dir:         string,
	key:             string,
	verb:            string,
	args:            [dynamic]string,
}

VERBS :: [?]string{"add", "del", "update", "upgrade", "search", "info", "list", "verify", "fix", "build", "index", "keygen", "help", "version"}

is_verb :: proc(s: string) -> bool {
	for v in VERBS {
		if v == s {
			return true
		}
	}
	return false
}

USAGE :: `palm -- the Palmframe package manager

  palm add <pkg>...         install (and record in world); a ./file.palm needs --allow-untrusted
  palm del <pkg>...         remove (and drop from world), and orphans
  palm update               fetch and verify every repository index
  palm upgrade              upgrade everything to the newest available
  palm search <text>        search names and descriptions
  palm info <pkg>           details; -L lists files; --who-owns <path>
  palm list [--installed|--upgradable|--available]
  palm verify [<pkg>...]    check installed files against recorded sha256
  palm fix [<pkg>...]       reinstall broken/missing files
  palm build <dir> -o <outdir>          build a package from <dir>/PALMBUILD
  palm index <dir> [--key <secret>]     write and sign <dir>/PALMINDEX
  palm keygen <name>                    write <name>.sec and <name>.pub
  palm --selftest

global: --root <dir>  --initdb  --repo <url|path> (repeatable, overrides repositories)
        --keys-dir <dir>  --allow-untrusted  --no-cache  --json  --yes  --dry-run

Any other first word is passed to the command surface (` + SURFACE_PATH + `).
`

main :: proc() {
	args := os.args
	if v, found := os.lookup_env("PALM_HTTP_TRACE", context.temp_allocator); found && v != "" && v != "0" {
		g_http_trace = true
	}
	if len(args) >= 2 {
		first := args[1]
		if first == "--selftest" || first == "--self-test" {
			selftest()
			return
		}
		if !strings.has_prefix(first, "-") && !is_verb(first) {
			passthrough(args)
		}
	}
	os.exit(dispatch(args[1:]))
}

// passthrough hands the whole argv to the command surface. It does not
// return unless the exec fails.
passthrough :: proc(args: []string) {
	path := SURFACE_PATH
	if v, found := os.lookup_env("PALM_SURFACE", context.temp_allocator); found && v != "" {
		path = v
	}
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args {
		argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	argv[len(args)] = nil
	c_execv(strings.clone_to_cstring(path, context.temp_allocator), raw_data(argv))
	fmt.eprintf("palm: %q is not a palm verb, and the command surface (%s) could not be run\n", args[1], path)
	os.exit(EXIT_USAGE)
}

parse_args :: proc(args: []string) -> (o: Opts, e: Err) {
	o.root = "/"
	need :: proc(args: []string, i: ^int, flag: string) -> (string, Err) {
		if i^ + 1 >= len(args) {
			return "", fail(EXIT_USAGE, "%s needs a value", flag)
		}
		i^ += 1
		return args[i^], Err{}
	}
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		// --flag=value is accepted for every flag that takes a value
		val := ""
		has_val := false
		if strings.has_prefix(a, "--") {
			if eq := strings.index_byte(a, '='); eq > 0 {
				val = a[eq + 1:]
				a = a[:eq]
				has_val = true
			}
		}
		take :: proc(args: []string, i: ^int, a, val: string, has_val: bool) -> (string, Err) {
			if has_val {
				return val, Err{}
			}
			return need(args, i, a)
		}
		v: string
		switch a {
		case "--root":
			v, e = take(args, &i, a, val, has_val)
			o.root = v
		case "--repo", "-X", "--repository":
			v, e = take(args, &i, a, val, has_val)
			append(&o.repos, v)
		case "--keys-dir":
			v, e = take(args, &i, a, val, has_val)
			o.keys_dir = v
		case "-o", "--output":
			v, e = take(args, &i, a, val, has_val)
			o.out_dir = v
		case "--key":
			v, e = take(args, &i, a, val, has_val)
			o.key = v
		case "--who-owns", "-W":
			v, e = take(args, &i, a, val, has_val)
			o.who_owns = v
		case "--initdb":
			o.initdb = true
		case "--allow-untrusted":
			o.allow_untrusted = true
		case "--no-cache":
			o.no_cache = true
		case "--json":
			o.json = true
		case "--yes", "-y":
			o.yes = true
		case "-U", "--update-cache":
			o.refresh = true
		case "--dry-run", "-s", "--simulate":
			o.dry_run = true
		case "-L", "--contents":
			o.list_files = true
		case "--installed", "-I":
			o.installed = true
		case "--upgradable", "-u":
			o.upgradable = true
		case "--available", "-a":
			o.available = true
		case "-h", "--help":
			o.verb = "help"
		case "--version":
			o.verb = "version"
		case:
			if strings.has_prefix(a, "-") && len(a) > 1 {
				return o, fail(EXIT_USAGE, "unknown option %s", a)
			}
			if o.verb == "" {
				o.verb = a
			} else {
				append(&o.args, a)
			}
		}
		if !ok(e) {
			return
		}
	}
	if o.root == "" {
		o.root = "/"
	}
	if o.root != "/" {
		abs, aerr := os.get_absolute_path(o.root, context.allocator)
		if aerr == nil {
			o.root = abs
		}
	}
	return
}

// dispatch runs one command and returns its exit code. It never exits, so
// the selftest can drive it the way a person would, by argv.
dispatch :: proc(args: []string) -> int {
	o, e := parse_args(args)
	if !ok(e) {
		fmt.eprintf("palm: %s\n", e.msg)
		return e.code
	}
	saved_quiet := g_quiet
	saved_progress := g_progress_json
	if o.json {
		// The selftest is already quiet; it drives --json for the document
		// and does not want progress lines on its stderr.
		g_progress_json = !g_quiet
		g_quiet = true
	}
	defer {
		g_quiet = saved_quiet
		g_progress_json = saved_progress
		http_close_all()
	}

	switch o.verb {
	case "", "help":
		fmt.print(USAGE)
		return o.verb == "" ? EXIT_USAGE : EXIT_OK
	case "version":
		fmt.printf("palm %s\n", VERSION)
		return EXIT_OK
	case "add":
		e = cmd_add(&o)
	case "del":
		e = cmd_del(&o)
	case "update":
		e = cmd_update(&o)
	case "upgrade":
		e = cmd_upgrade(&o)
	case "search":
		e = cmd_search(&o)
	case "info":
		e = cmd_info(&o)
	case "list":
		e = cmd_list(&o)
	case "verify":
		e = cmd_verify(&o)
	case "fix":
		e = cmd_fix(&o)
	case "build":
		e = cmd_build(&o)
	case "index":
		e = cmd_index(&o)
	case "keygen":
		e = cmd_keygen(&o)
	case:
		e = fail(EXIT_USAGE, "unknown verb %q (see palm help)", o.verb)
	}
	if !ok(e) {
		if o.json && e.msg != "" {
			fmt.printf("{{\"ok\":false,\"code\":%d,\"error\":%s}}\n", e.code, json_str(e.msg))
		} else if e.msg != "" {
			fmt.eprintf("palm: %s\n", e.msg)
		}
		return e.code
	}
	return EXIT_OK
}

// ---------------------------------------------------------------------------
// Transactions: add, del, upgrade
// ---------------------------------------------------------------------------

// transact resolves `world`, shows the plan, and carries it out. It is the
// one path by which anything gets installed or removed.
@(private = "file")
transact :: proc(o: ^Opts, db: ^DB, repos: []^Repo, world: []string, upgrade: bool) -> Err {
	u := build_universe(db, repos)
	if upgrade {
		find_replacements(u, db)
	}
	res, e := resolve(u, world, upgrade)
	if !ok(e) {
		return e
	}
	plan := make_plan(db, res)
	if o.json {
		fmt.println(plan_json(plan, o.dry_run))
	} else if plan_empty(plan) {
		say(upgrade ? "nothing to upgrade: every installed package is the newest the indexes offer" : "nothing to do")
	} else {
		plan_print(plan)
	}
	if o.dry_run {
		return Err{}
	}
	if len(plan.remove) > 0 && !o.yes && stdin_is_tty() && !o.json {
		fmt.printf("remove %d package(s)? [y/N] ", len(plan.remove))
		buf: [16]byte
		n, _ := os.read(os.stdin, buf[:])
		answer := strings.trim_space(string(buf[:max(n, 0)]))
		if answer != "y" && answer != "Y" && answer != "yes" {
			return fail(EXIT_REFUSED, "not confirmed; nothing changed (--yes skips the question)")
		}
	}
	t := txn_begin(o, db)
	if re := run_plan(t, plan); !ok(re) {
		return re
	}
	clear(&db.world)
	append(&db.world, ..world)
	if we := world_save(db); !ok(we) {
		return we
	}
	if !plan_empty(plan) {
		say("OK: %s; %d packages installed", plan_summary(plan_totals(plan), true), len(db.pkgs))
	}
	return Err{}
}

// repo_mode is how far a changing verb goes for indexes: the cached ones,
// or fresh ones with -U.
@(private = "file")
repo_mode :: proc(o: ^Opts) -> Repo_Mode {
	return o.refresh ? .Refresh : .Cached
}

@(private = "file")
cmd_add :: proc(o: ^Opts) -> Err {
	if len(o.args) == 0 {
		return fail(EXIT_USAGE, "add: name at least one package")
	}
	db, e := db_open(o)
	if !ok(e) {return e}
	repos: []^Repo
	repos, _, e = open_repos(o, repo_mode(o))
	if !ok(e) {return e}
	extra := make([dynamic]^Repo)
	append(&extra, ..repos)
	world := make([dynamic]string)
	append(&world, ..db.world[:])
	for a in o.args {
		entry := a
		if strings.has_suffix(a, ".palm") && os.exists(a) {
			r, le := local_file_repo(o, a)
			if !ok(le) {return le}
			append(&extra, r)
			entry = r.pkgs[0].name
		} else if _, okc := parse_constraint(a); !okc {
			return fail(EXIT_USAGE, "%q is not a package name or constraint", a)
		}
		name := world_name(entry)
		for i := len(world) - 1; i >= 0; i -= 1 {
			if world_name(world[i]) == name {
				ordered_remove(&world, i)
			}
		}
		append(&world, entry)
	}
	return transact(o, db, extra[:], world[:], false)
}

@(private = "file")
cmd_del :: proc(o: ^Opts) -> Err {
	if len(o.args) == 0 {
		return fail(EXIT_USAGE, "del: name at least one package")
	}
	db, e := db_open(o)
	if !ok(e) {return e}
	// Removing needs no repository, but resolving the remaining world must
	// not fail because a mirror is down: repositories are best effort here.
	repos, _, re := open_repos(o, .Cached)
	if !ok(re) {
		warn("%s; resolving against installed packages only", re.msg)
		repos = nil
	}
	world := make([dynamic]string)
	for w in db.world {
		drop := false
		for a in o.args {
			if world_name(w) == a {drop = true}
		}
		if !drop {append(&world, w)}
	}
	for a in o.args {
		in_world := false
		for w in db.world {
			if world_name(w) == a {in_world = true}
		}
		if !in_world {
			if db_find(db, a) == nil {
				return fail(EXIT_NOT_FOUND, "%s is not installed", a)
			}
			warn("%s is not in world (it was installed as a dependency)", a)
		}
	}
	// Pass a universe of installed packages first: del should not upgrade
	// anything as a side effect, and installed packages are preferred.
	u := build_universe(db, repos)
	res, rerr := resolve(u, world[:], false)
	if ok(rerr) {
		for a in o.args {
			if p, still := res.chosen[a]; still {
				who := make([dynamic]string, context.temp_allocator)
				for q in res.order {
					for d in q.depends {
						if c, _ := parse_constraint(d); c.name == a {append(&who, q.name)}
					}
				}
				warn("%s stays installed: still required by %s", p.name, strings.join(who[:], ", ", context.temp_allocator))
			}
		}
	}
	return transact(o, db, repos, world[:], false)
}

// cmd_upgrade resolves the world preferring the newest versions. A world
// entry naming a package that an available package replaces is renamed to
// the replacement, so a renamed project follows its new name.
@(private = "file")
cmd_upgrade :: proc(o: ^Opts) -> Err {
	db, e := db_open(o)
	if !ok(e) {return e}
	repos: []^Repo
	skipped: []string
	repos, skipped, e = open_repos(o, repo_mode(o))
	if !ok(e) {return e}
	if len(skipped) > 0 && o.refresh {
		warn("%d repositories could not be refreshed; upgrading from what was cached", len(skipped))
	}
	if !o.json {
		for r in repos {
			if !r.remote {continue}
			fi, err := os.stat(fmt.tprintf("%s/PALMINDEX", r.cache), context.temp_allocator)
			if err == nil {
				age := time.since(fi.modification_time)
				if age > 24 * time.Hour && !o.refresh {
					say("note: the index of %s was fetched %d days ago; `palm upgrade -U` (or `palm update`) gets the current one", r.url, int(age / (24 * time.Hour)))
				}
			}
		}
	}
	u := build_universe(db, repos)
	find_replacements(u, db)
	world := make([dynamic]string)
	for w in db.world {
		name := world_name(w)
		if by, has := u.replaced[name]; has && db_find(db, name) != nil {
			say("%s is replaced by %s", name, by.name)
			if !slice.contains(world[:], by.name) {append(&world, by.name)}
			continue
		}
		append(&world, w)
	}
	return transact(o, db, repos, world[:], true)
}

@(private = "file")
cmd_update :: proc(o: ^Opts) -> Err {
	lines := repo_lines(o)
	if len(lines) == 0 {
		return fail(EXIT_NOT_FOUND, "no repositories configured (%s or --repo)", rooted(o.root, "/etc/palm/repositories", context.temp_allocator))
	}
	repos, skipped, e := open_repos(o, .Refresh)
	if !ok(e) {return e}
	db, _ := db_open(o)
	upgradable := 0
	if db != nil {
		avail := newest_available(repos)
		for p in db.pkgs {
			if a, has := avail[p.name]; has && version_compare(a.version, p.version) > 0 {upgradable += 1}
		}
	}
	if o.json {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{\"repositories\":[")
		for r, i in repos {
			if i > 0 {strings.write_byte(&b, ',')}
			fmt.sbprintf(&b, "{{\"url\":%s,\"base\":%s,\"packages\":%d,\"signed_by\":%s,\"generated\":%d}}", json_str(r.url), json_str(r.base), len(r.pkgs), json_str(r.signed_by), r.generated)
		}
		fmt.sbprintf(&b, "],\"upgradable\":%d}}", upgradable)
		fmt.println(strings.to_string(b))
	} else {
		for r in repos {
			signer := r.signed_by != "" ? fmt.tprintf("signed by %s", r.signed_by) : "UNTRUSTED"
			from := ""
			if r.remote && !strings.has_prefix(r.base, strings.trim_right(r.url, "/")) {
				from = fmt.tprintf(" (from mirror %s)", r.base)
			}
			say("%s: %d packages, %s, published %s%s", r.url, len(r.pkgs), signer, format_date(r.generated), from)
		}
		if db != nil && upgradable > 0 {
			say("%d installed package(s) can be upgraded: palm upgrade", upgradable)
		}
	}
	if len(skipped) > 0 {
		return fail(EXIT_UNAVAILABLE, "%d of %d repositories could not be reached: %s", len(skipped), len(lines), strings.join(skipped, "; ", context.temp_allocator))
	}
	return Err{}
}

// ---------------------------------------------------------------------------
// Queries: search, info, list
// ---------------------------------------------------------------------------

// newest_available returns the highest version of each package name across
// every repository.
newest_available :: proc(repos: []^Repo) -> map[string]^Pkg {
	m := make(map[string]^Pkg)
	for r in repos {
		for &p in r.pkgs {
			if q, has := m[p.name]; !has || version_compare(p.version, q.version) > 0 {
				m[p.name] = &p
			}
		}
	}
	return m
}

@(private = "file")
open_for_query :: proc(o: ^Opts) -> (^DB, []^Repo, Err) {
	db, e := db_open(o)
	if !ok(e) {
		// Querying a repository needs no installed database.
		db = new(DB)
		db.root = o.root
	}
	// Queries never touch the network: they read the indexes `palm update`
	// cached (and local repositories), and a repository not yet fetched is
	// simply not in the answer.
	repos, _, re := open_repos(o, .Offline)
	if !ok(re) {
		return nil, nil, re
	}
	return db, repos, Err{}
}

// pkg_json writes one package. `db` supplies what only the installed side
// knows: whether the package is in world (`explicit`: asked for, rather than
// pulled in as a dependency). A store needs that to say "installed by you"
// and to know that removing a dependency is really a question about whoever
// needs it.
@(private = "file")
pkg_json :: proc(b: ^strings.Builder, p: ^Pkg, installed: ^Pkg, db: ^DB) {
	fmt.sbprintf(b, "{{\"name\":%s,\"version\":%s,\"description\":%s,\"license\":%s,\"url\":%s,\"size\":%d,\"csize\":%d", json_str(p.name), json_str(p.version), json_str(p.desc), json_str(p.license), json_str(p.url), p.size, p.csize)
	fmt.sbprintf(b, ",\"category\":%s,\"icon\":%s,\"details\":%s", json_str(p.category), json_str(p.icon), json_str(p.details))
	strings.write_string(b, ",\"depends\":[")
	for d, i in p.depends {
		if i > 0 {strings.write_byte(b, ',')}
		strings.write_string(b, json_str(d))
	}
	strings.write_string(b, "],\"provides\":[")
	for d, i in p.provides {
		if i > 0 {strings.write_byte(b, ',')}
		strings.write_string(b, json_str(d))
	}
	strings.write_string(b, "]")
	for list, k in ([2][]string{p.conflicts, p.replaces}) {
		strings.write_string(b, k == 0 ? ",\"conflicts\":[" : ",\"replaces\":[")
		for d, i in list {
			if i > 0 {strings.write_byte(b, ',')}
			strings.write_string(b, json_str(d))
		}
		strings.write_string(b, "]")
	}
	if installed != nil {
		fmt.sbprintf(b, ",\"installed\":%s,\"installed_size\":%d", json_str(installed.version), installed.size)
		explicit := false
		if db != nil {
			for w in db.world {
				if world_name(w) == p.name {explicit = true}
			}
		}
		fmt.sbprintf(b, ",\"explicit\":%v", explicit)
	} else {
		strings.write_string(b, ",\"installed\":null,\"explicit\":false")
	}
	strings.write_string(b, "}")
}

// required_by names the installed packages that depend on `p`, by its name
// or by anything it provides -- what `palm del p` would have to keep it for.
@(private = "file")
required_by :: proc(db: ^DB, p: ^Pkg) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for q in db.pkgs {
		if q.name == p.name {continue}
		for d in q.depends {
			c, okc := parse_constraint(d)
			if okc && pkg_satisfies(p, c) {
				append(&out, q.name)
				break
			}
		}
	}
	slice.sort(out[:])
	return out[:]
}

@(private = "file")
cmd_search :: proc(o: ^Opts) -> Err {
	if len(o.args) == 0 {
		return fail(EXIT_USAGE, "search: give some text to search for")
	}
	db, repos, e := open_for_query(o)
	if !ok(e) {return e}
	all := newest_available(repos)
	for p in db.pkgs {
		if p.name not_in all {all[p.name] = p}
	}
	names := make([dynamic]string, context.temp_allocator)
	for n, p in all {
		hay := strings.to_lower(fmt.tprintf("%s %s", p.name, p.desc), context.temp_allocator)
		match := true
		for a in o.args {
			if !strings.contains(hay, strings.to_lower(a, context.temp_allocator)) {match = false}
		}
		if match {append(&names, n)}
	}
	slice.sort(names[:])
	if o.json {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for n, i in names {
			if i > 0 {strings.write_byte(&b, ',')}
			pkg_json(&b, all[n], db_find(db, n), db)
		}
		strings.write_byte(&b, ']')
		fmt.println(strings.to_string(b))
	} else {
		for n in names {
			p := all[n]
			fmt.printf("%s-%s  %s\n", p.name, p.version, p.desc)
		}
	}
	if len(names) == 0 {
		return Err{EXIT_NOT_FOUND, ""}
	}
	return Err{}
}

@(private = "file")
cmd_info :: proc(o: ^Opts) -> Err {
	if o.who_owns != "" {
		db, e := db_open(o)
		if !ok(e) {return e}
		p, _ := clean_pkg_path(o.who_owns, context.temp_allocator)
		owners := who_owns(db, p)
		if o.json {
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "{{\"path\":%s,\"owners\":[", json_str(p))
			for n, i in owners {
				if i > 0 {strings.write_byte(&b, ',')}
				strings.write_string(&b, json_str(n))
			}
			strings.write_string(&b, "]}")
			fmt.println(strings.to_string(b))
		} else if len(owners) > 0 {
			fmt.printf("%s is owned by %s\n", p, strings.join(owners, ", ", context.temp_allocator))
		}
		if len(owners) == 0 {
			return fail(EXIT_NOT_FOUND, "%s is not owned by any package", p)
		}
		return Err{}
	}
	if len(o.args) == 0 {
		return fail(EXIT_USAGE, "info: name a package (or --who-owns <path>)")
	}
	db, repos, e := open_for_query(o)
	if !ok(e) {return e}
	avail := newest_available(repos)
	b := strings.builder_make(context.temp_allocator)
	if o.json {strings.write_byte(&b, '[')}
	for name, i in o.args {
		inst := db_find(db, name)
		p := inst
		if p == nil {
			p = avail[name]
		}
		if p == nil {
			return fail(EXIT_NOT_FOUND, "%s: no such package", name)
		}
		files := p.files
		if o.list_files && inst == nil {
			// Not installed: read the file list out of the package itself.
			// This is the one query that may download: the list is in the
			// package and nowhere else. From the cache or a local
			// repository it stays offline.
			fetched, fe := fetch_package(o, p)
			if !ok(fe) {return fe}
			data, rerr := os.read_entire_file_from_path(fetched.path, context.temp_allocator)
			remove_temp_downloads({fetched})
			if rerr != nil {return fail(EXIT_FAILED, "cannot read %s", fetched.path)}
			raw, _ := gzip_decompress(data, context.temp_allocator)
			entries, _ := tar_read(raw, context.temp_allocator)
			recs := make([dynamic]File_Rec, context.temp_allocator)
			for en in entries {
				if en.path != ".PKGINFO" {append(&recs, File_Rec{path = en.path, type = en.type})}
			}
			files = recs[:]
		}
		if o.json {
			if i > 0 {strings.write_byte(&b, ',')}
			pkg_json(&b, p, inst, db)
			{
				// required_by goes in before the closing brace, like files
				s := strings.to_string(b)
				strings.builder_reset(&b)
				strings.write_string(&b, s[:len(s) - 1])
				strings.write_string(&b, ",\"required_by\":[")
				for n, k in required_by(db, p) {
					if k > 0 {strings.write_byte(&b, ',')}
					strings.write_string(&b, json_str(n))
				}
				strings.write_string(&b, "]}")
			}
			if o.list_files {
				// splice the file list in before the closing brace
				s := strings.to_string(b)
				strings.builder_reset(&b)
				strings.write_string(&b, s[:len(s) - 1])
				strings.write_string(&b, ",\"files\":[")
				for f, k in files {
					if k > 0 {strings.write_byte(&b, ',')}
					strings.write_string(&b, json_str(f.path))
				}
				strings.write_string(&b, "]}")
			}
			continue
		}
		if o.list_files {
			for f in files {
				if f.type != .Dir {fmt.println(f.path)}
			}
			continue
		}
		fmt.printf("%s-%s\n", p.name, p.version)
		if p.desc != "" {fmt.printf("  description: %s\n", p.desc)}
		if p.license != "" {fmt.printf("  license:     %s\n", p.license)}
		if p.url != "" {fmt.printf("  url:         %s\n", p.url)}
		if p.category != "" {fmt.printf("  category:    %s\n", p.category)}
		fmt.printf("  size:        %s\n", human_size(p.size))
		if len(p.depends) > 0 {fmt.printf("  depends:     %s\n", strings.join(p.depends, " ", context.temp_allocator))}
		if len(p.provides) > 0 {fmt.printf("  provides:    %s\n", strings.join(p.provides, " ", context.temp_allocator))}
		if len(p.conflicts) > 0 {fmt.printf("  conflicts:   %s\n", strings.join(p.conflicts, " ", context.temp_allocator))}
		if len(p.replaces) > 0 {fmt.printf("  replaces:    %s\n", strings.join(p.replaces, " ", context.temp_allocator))}
		if inst != nil {
			fmt.printf("  installed:   %s (%d files)\n", inst.version, len(inst.files))
			if a, has := avail[name]; has && version_compare(a.version, inst.version) > 0 {
				fmt.printf("  available:   %s\n", a.version)
			}
		} else {
			fmt.printf("  installed:   no\n")
		}
	}
	if o.json {
		strings.write_byte(&b, ']')
		fmt.println(strings.to_string(b))
	}
	return Err{}
}

@(private = "file")
cmd_list :: proc(o: ^Opts) -> Err {
	db, repos, e := open_for_query(o)
	if !ok(e) {return e}
	avail := newest_available(repos)
	names := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for n in avail {
		if !seen[n] {append(&names, n); seen[n] = true}
	}
	for p in db.pkgs {
		if !seen[p.name] {append(&names, p.name); seen[p.name] = true}
	}
	slice.sort(names[:])
	any_filter := o.installed || o.upgradable || o.available
	b := strings.builder_make(context.temp_allocator)
	if o.json {strings.write_byte(&b, '[')}
	count := 0
	for n in names {
		inst := db_find(db, n)
		a := avail[n]
		upgradable := inst != nil && a != nil && version_compare(a.version, inst.version) > 0
		if any_filter {
			show := (o.installed && inst != nil) || (o.upgradable && upgradable) || (o.available && a != nil)
			if !show {continue}
		}
		p := a != nil ? a : inst
		if o.json {
			if count > 0 {strings.write_byte(&b, ',')}
			pkg_json(&b, p, inst, db)
		} else {
			status := ""
			switch {
			case upgradable:
				status = fmt.tprintf(" [upgradable from: %s]", inst.version)
			case inst != nil:
				status = " [installed]"
			}
			fmt.printf("%s-%s%s\n", p.name, p.version, status)
		}
		count += 1
	}
	if o.json {
		strings.write_byte(&b, ']')
		fmt.println(strings.to_string(b))
	}
	return Err{}
}

// ---------------------------------------------------------------------------
// verify and fix
// ---------------------------------------------------------------------------

Problem :: struct {
	pkg:  string,
	path: string,
	what: string,
	// a changed config under /etc is reported but is not a failure
	soft: bool,
}

verify_packages :: proc(o: ^Opts, db: ^DB, only: []string) -> []Problem {
	out := make([dynamic]Problem)
	t := txn_begin(o, db)
	for p in db.pkgs {
		if len(only) > 0 && !slice.contains(only, p.name) {continue}
		for f in p.files {
			host, he := host_path(t, f.path)
			if !ok(he) {
				append(&out, Problem{p.name, f.path, he.msg, false})
				continue
			}
			fi, err := os.stat_do_not_follow_links(host, context.temp_allocator)
			if err != nil {
				append(&out, Problem{p.name, f.path, "missing", false})
				continue
			}
			switch f.type {
			case .Dir:
				if fi.type != .Directory && fi.type != .Symlink {
					append(&out, Problem{p.name, f.path, "not a directory", false})
				}
			case .Symlink:
				if fi.type != .Symlink {
					append(&out, Problem{p.name, f.path, "not a symlink", false})
				} else if target, _ := os.read_link(host, context.temp_allocator); target != f.sha {
					// Retargeting a link under /etc (/etc/localtime) is a
					// configuration change, reported like an edited file.
					etc := strings.has_prefix(f.path, "/etc/")
					what := etc ? fmt.aprintf("modified (config): points to %s, not %s", target, f.sha) : fmt.aprintf("points to %s, not %s", target, f.sha)
					append(&out, Problem{p.name, f.path, what, etc})
				}
			case .File, .Hardlink:
				if fi.type != .Regular {
					append(&out, Problem{p.name, f.path, "not a regular file", false})
					continue
				}
				if f.type == .Hardlink {continue}
				sum, _ := sha256_file_hex(host, context.temp_allocator)
				if sum != f.sha {
					etc := strings.has_prefix(f.path, "/etc/")
					append(&out, Problem{p.name, f.path, etc ? "modified (config)" : "sha256 mismatch", etc})
				} else if disk_mode(host) != f.mode & 0o7777 {
					// The setuid, setgid and sticky bits count: a lost setuid
					// bit breaks doas as surely as a changed byte.
					append(&out, Problem{p.name, f.path, fmt.aprintf("mode %04o, want %04o", disk_mode(host), f.mode & 0o7777), false})
				}
			}
		}
	}
	return out[:]
}

@(private = "file")
cmd_verify :: proc(o: ^Opts) -> Err {
	db, e := db_open(o)
	if !ok(e) {return e}
	for a in o.args {
		if db_find(db, a) == nil {return fail(EXIT_NOT_FOUND, "%s is not installed", a)}
	}
	problems := verify_packages(o, db, o.args[:])
	hard := 0
	for p in problems {
		if !p.soft {hard += 1}
	}
	if o.json {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "{{\"ok\":%v,\"packages\":%d,\"problems\":[", hard == 0, len(db.pkgs))
		for p, i in problems {
			if i > 0 {strings.write_byte(&b, ',')}
			fmt.sbprintf(&b, "{{\"package\":%s,\"path\":%s,\"problem\":%s,\"config\":%v}}", json_str(p.pkg), json_str(p.path), json_str(p.what), p.soft)
		}
		strings.write_string(&b, "]}")
		fmt.println(strings.to_string(b))
	} else {
		for p in problems {
			fmt.printf("%s: %s: %s\n", p.pkg, p.path, p.what)
		}
		if hard == 0 {
			say("OK: %d packages verified", len(db.pkgs))
		}
	}
	if hard > 0 {
		return fail(EXIT_FAILED_GENERIC, "%d problem(s) found; `palm fix` reinstalls the affected packages", hard)
	}
	return Err{}
}

@(private = "file")
cmd_fix :: proc(o: ^Opts) -> Err {
	db, e := db_open(o)
	if !ok(e) {return e}
	repos: []^Repo
	repos, _, e = open_repos(o, repo_mode(o))
	if !ok(e) {return e}
	targets := make([dynamic]string, context.temp_allocator)
	if len(o.args) > 0 {
		for a in o.args {
			if db_find(db, a) == nil {return fail(EXIT_NOT_FOUND, "%s is not installed", a)}
			append(&targets, a)
		}
	} else {
		for p in verify_packages(o, db, nil) {
			if !p.soft && !slice.contains(targets[:], p.pkg) {append(&targets, p.pkg)}
		}
	}
	if len(targets) == 0 {
		say("nothing to fix")
		return Err{}
	}
	plan: Plan
	for name in targets {
		inst := db_find(db, name)
		found: ^Pkg
		for r in repos {
			for &p in r.pkgs {
				if p.name == name && p.version == inst.version {
					if found == nil || p.sha256 == inst.sha256 {found = &p}
				}
			}
		}
		if found == nil {
			return fail(EXIT_NOT_FOUND, "no repository has %s-%s to reinstall from", name, inst.version)
		}
		append(&plan.changes, Change{inst, found})
	}
	if o.json {
		fmt.println(plan_json(plan, o.dry_run))
	} else {
		plan_print(plan)
	}
	if o.dry_run {return Err{}}
	t := txn_begin(o, db)
	return run_plan(t, plan)
}

// ---------------------------------------------------------------------------
// Building: build, index, keygen
// ---------------------------------------------------------------------------

@(private = "file")
cmd_build :: proc(o: ^Opts) -> Err {
	if len(o.args) != 1 {
		return fail(EXIT_USAGE, "build: palm build <dir> -o <outdir>")
	}
	out_dir := o.out_dir != "" ? o.out_dir : "."
	path, e := build_package(o.args[0], out_dir)
	if !ok(e) {return e}
	if o.json {
		fmt.printf("{{\"package\":%s}}\n", json_str(path))
	} else {
		say("%s", path)
	}
	return Err{}
}

@(private = "file")
cmd_index :: proc(o: ^Opts) -> Err {
	if len(o.args) != 1 {
		return fail(EXIT_USAGE, "index: palm index <dir> --key <secret>")
	}
	n, e := build_index(o.args[0], o.key)
	if !ok(e) {return e}
	say("%s/PALMINDEX: %d packages%s", o.args[0], n, o.key != "" ? ", signed" : ", UNSIGNED")
	return Err{}
}

@(private = "file")
cmd_keygen :: proc(o: ^Opts) -> Err {
	if len(o.args) != 1 {
		return fail(EXIT_USAGE, "keygen: palm keygen <name>")
	}
	return keygen(o.args[0])
}
