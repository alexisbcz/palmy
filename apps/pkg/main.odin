package main

// palm pkg -- the declarative layer over pacman. Not a package manager.
//
//	pkg list      [--explicit] [--json]
//	pkg search    <query> [--aur] [--json]
//	pkg info      <name> [--json]
//	pkg diff      [--json]                      read: how the machine has drifted
//	pkg declare   <names...> [--profile P] [--aur]
//	pkg undeclare <names...>
//	pkg install   <names...> [--aur] [--yes] [--dry-run] [--json]
//	pkg remove    <names...> --yes [--recursive] [--allow-protected CLASS]
//	pkg sync      [--prune --yes] [--dry-run] [--json]
//	pkg upgrade   [--aur]                       interactive by design
//	pkg snapshots [--json]
//	pkg rollback  <number> --yes                interactive by design
//	pkg verbs     [--json]                      the surface, for an agent
//	pkg --selftest
//
// WHY THIS IS NOT A PACKAGE MANAGER. pacman already does dependency solving,
// signature verification, mirror selection and atomic transactions, yay
// reaches the AUR, and rollback is here too: snapper is configured on / and
// limine-snapper-sync keeps the boot entries in step with the snapshots. A new
// package manager would begin with zero packages, which is not a smaller
// problem. What was missing is a file that says what the machine *should*
// have, a converge toward it, a diff that shows the drift, and an interface
// that does not require parsing prose. That is all this is.
//
// WHAT IT WILL NOT DO, each of which is a way a package layer breaks a machine:
//
//   - It cannot emit a `-Sy` without a `-u`. Not "does not"; cannot: every
//     plan goes through plan_check, which fails the plan.
//   - It will not remove something another package needs without naming every
//     dependant and being given --yes.
//   - It will not touch the kernel, the bootloader, the display manager or
//     init without a separate --allow-protected for that class.
//   - It will not start a full upgrade unattended. A .pacnew or a keyring
//     change needs a person, so upgrade refuses without a terminal.
//   - It never reads, stores or passes a sudo password. sudo asks the person.
//
// Exit codes, from docs/PALM-CLI.md:
//   0 ok   2 usage   3 not found   4 refused: needs --yes   5 out of scope
//   6 unavailable    7 failed

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import kit "kit:."

Opts :: struct {
	json:      bool,
	dry_run:   bool,
	yes:       bool,
	aur:       bool,
	recursive: bool,
	prune:     bool,
	refresh:   bool,
	explicit:  bool,
	identity:  string,
	profiles:  []string,
	file:      string,
	allow:     []Guard,
	args:      []string,
	verb:      string,
}

// The command line is parsed by the shared convention (apps/kit/cli.odin)
// from the declaration in cli.odin. With nothing on the line there is no
// window to open, so it is a usage error, as it always was.
main :: proc() {
	os.exit(dispatch(os.args[1:]))
}

// dispatch is main() without the exit, so the self-test can drive every verb
// the way an agent would -- by argv, through the same parser -- rather than
// by calling the internals.
dispatch :: proc(argv: []string) -> int {
	args := argv
	// Tolerate being reached as `palm pkg ...` as well as `pkg ...`.
	if len(args) > 0 && args[0] == "pkg" {
		args = args[1:]
	}
	code, handled := kit.cli_args(surface(), args)
	if !handled {
		fmt.eprint(kit.cli_help_text(surface()))
		return EXIT_USAGE
	}
	return code
}

// g_call is the command in progress. The verbs describe their result as a
// JSON tree; jw_emit and emit_refusal hand that tree to the call, and the kit
// prints it -- one document on stdout under --json, a refusal as the
// documented error object.
g_call: ^kit.Call

// jw_emit hands a verb's result to the command in progress.
jw_emit :: proc(w: ^JW) {
	if g_call != nil {
		g_call.out = w.root
		return
	}
	outln("%s", jw_text(w))
}

// ---------------------------------------------------------------------------
// Where the declaration lives
// ---------------------------------------------------------------------------

decl_dir :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("PALM_PKG_DIR", context.temp_allocator); d != "" {
		return strings.clone(d, allocator)
	}
	if d := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); d != "" {
		return fmt.aprintf("%s/palm/packages", d, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.config/palm/packages", home, allocator = allocator)
}

decl_path :: proc(o: ^Opts, allocator := context.allocator) -> string {
	if o.file != "" {
		return strings.clone(o.file, allocator)
	}
	return fmt.aprintf("%s/%s.pkgs", decl_dir(context.temp_allocator), o.identity, allocator = allocator)
}

load_decl :: proc(o: ^Opts) -> (d: Decl, path: string, existed: bool) {
	path = decl_path(o)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return decl_parse("", context.allocator), path, false
	}
	return decl_parse(string(data), context.allocator), path, true
}

// ---------------------------------------------------------------------------
// Emitting a plan or a refusal
// ---------------------------------------------------------------------------

emit_refusal :: proc(o: ^Opts, op: string, r: Refusal) -> int {
	// The documented error object (error, code, command) with pkg's own
	// stable reason token and the subjects beside it, so a caller can branch
	// on `has-dependants` as well as on exit 4.
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "error", kit.cli_exit_reason(r.code))
	jw_kint(&w, "code", r.code)
	jw_kstr(&w, "command", strings.trim_space(fmt.tprintf("pkg %s", op)))
	jw_kstr(&w, "op", op)
	jw_kbool(&w, "refused", true)
	jw_kstr(&w, "reason", r.reason)
	jw_kstr(&w, "detail", r.detail)
	jw_kstrs(&w, "subjects", r.subjects)
	jw_kint(&w, "exit", r.code)
	jw_obj_end(&w)
	if g_call != nil {
		g_call.err = w.root
		if !o.json {
			// A person reads a refusal on stderr; the kit prints the error
			// token and the detail, so the reason and subjects go there too.
			note("refused: %s", r.reason)
			if len(r.subjects) > 0 {
				note("  %s", strings.join(r.subjects, " ", context.temp_allocator))
			}
		}
		return r.code
	}
	if o.json {
		jw_emit(&w)
	} else {
		outln("refused: %s", r.reason)
		if len(r.subjects) > 0 {
			outln("  %s", strings.join(r.subjects, " ", context.temp_allocator))
		}
		if r.detail != "" {
			outln("  %s", r.detail)
		}
	}
	return r.code
}

emit_plan :: proc(o: ^Opts, p: ^Plan, executed: bool, ran: int) -> int {
	if o.json {
		w := jw_make(context.temp_allocator)
		jw_obj(&w)
		jw_kstr(&w, "op", p.op)
		jw_kstr(&w, "class", p.class)
		jw_kbool(&w, "dry_run", o.dry_run)
		jw_kbool(&w, "executed", executed)
		jw_kint(&w, "steps_run", ran)
		jw_kstrs(&w, "targets", p.targets)
		jw_kstrs(&w, "skipped", p.skipped)
		jw_key(&w, "steps")
		jw_arr(&w)
		for s in p.steps {
			jw_obj(&w)
			jw_kstr(&w, "what", s.what)
			jw_kbool(&w, "needs_root", s.needs_root)
			jw_kstrs(&w, "argv", s.argv)
			jw_obj_end(&w)
		}
		jw_arr_end(&w)
		jw_kstrs(&w, "notes", p.notes)
		jw_obj_end(&w)
		jw_emit(&w)
		return EXIT_OK
	}

	if len(p.steps) == 0 {
		for n in p.notes {
			outln("%s", n)
		}
		return EXIT_OK
	}
	outln("%s (%s)%s", p.op, p.class, executed ? "" : " -- would run:")
	for s, i in p.steps {
		mark := executed && i < ran ? "ran " : "    "
		outln("  %s%s", mark, strings.join(s.argv, " ", context.temp_allocator))
	}
	for n in p.notes {
		outln("  note: %s", n)
	}
	return EXIT_OK
}

// carry_out is the one path from a plan to the machine.
//
// A mutating verb runs only when it has been told to: --dry-run prints and
// stops, and a mutating verb without --yes refuses rather than prompting,
// because a pipeline that blocks on a TTY read is how agent tooling hangs.
carry_out :: proc(o: ^Opts, p: ^Plan, r: Refusal) -> int {
	if r.refused {
		return emit_refusal(o, p.op != "" ? p.op : o.verb, r)
	}
	if len(p.steps) == 0 {
		return emit_plan(o, p, false, 0)
	}
	if o.dry_run {
		return emit_plan(o, p, false, 0)
	}
	if !o.yes {
		return emit_refusal(
			o,
			p.op,
			refuse(
				EXIT_NEEDS_YES,
				"needs-yes",
				fmt.tprintf(
					"%s changes the machine and this never prompts. Re-run with --yes, or with --dry-run to see the argv.",
					p.op,
				),
				p.targets,
			),
		)
	}
	ran, code := exec_plan(p)
	emit_plan(o, p, true, ran)
	return exec_failed(o, code)
}

// exec_failed keeps the plan in the answer when a step failed: the error
// object carries the documented token beside steps_run, so a caller can see
// how far it got.
exec_failed :: proc(o: ^Opts, code: int) -> int {
	if code == EXIT_OK || g_call == nil {
		return code
	}
	e := g_call.out
	if e == nil || e.kind != .Object {
		e = kit.jobj()
	}
	kit.jset_str(e, "error", kit.cli_exit_reason(code))
	kit.jset_int(e, "code", code)
	kit.jset_str(e, "command", fmt.tprintf("pkg %s", o.verb))
	g_call.err = e
	return code
}

// have_tool says whether a program is on PATH, so a read on a machine with no
// pacman answers "unavailable" rather than "not found".
have_tool :: proc(name: string) -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir != "" && os.exists(fmt.tprintf("%s/%s", dir, name)) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

load_world :: proc() -> (World, bool) {
	w := world_make()
	if !world_load(&w) {
		return w, false
	}
	return w, true
}

unavailable :: proc(o: ^Opts, what: string) -> int {
	return emit_refusal(
		o,
		o.verb,
		refuse(EXIT_UNAVAILABLE, "unavailable", fmt.tprintf("could not reach %s", what)),
	)
}

verb_list :: proc(o: ^Opts) -> int {
	w, ok := load_world()
	if !ok {
		return unavailable(o, "pacman")
	}
	names := world_explicit_sorted(&w)
	all := make([dynamic]string, context.temp_allocator)
	for n in w.installed {
		append(&all, n)
	}
	slice.sort(all[:])
	show := o.explicit ? names : all[:]

	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "list")
		jw_kint(&jw, "installed", len(w.installed))
		jw_kint(&jw, "explicit", len(w.explicit))
		jw_key(&jw, "packages")
		jw_arr(&jw)
		for n in show {
			jw_obj(&jw)
			jw_kstr(&jw, "name", n)
			jw_kbool(&jw, "explicit", w.explicit[n])
			g := guard_of(n)
			if g != .None {
				jw_kstr(&jw, "protected", guard_name(g))
			}
			jw_obj_end(&jw)
		}
		jw_arr_end(&jw)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	for n in show {
		if w.explicit[n] {
			outln("%s\texplicit", n)
		} else {
			outln("%s\tdependency", n)
		}
	}
	outln("%d installed, %d explicit", len(w.installed), len(w.explicit))
	return EXIT_OK
}

verb_search :: proc(o: ^Opts) -> int {
	if len(o.args) == 0 {
		fmt.eprintln("[pkg] search needs a query")
		return EXIT_USAGE
	}
	q := o.args[0]
	if !have_tool("pacman") {
		return unavailable(o, "pacman")
	}
	text, ok := run_query({"pacman", "-Ss", "--", q})
	hits := parse_search(text)
	aur_hits: []Search_Hit
	if o.aur {
		atext, _ := run_query({"yay", "-Ss", "--aur", "--", q})
		aur_hits = parse_search(atext)
	}
	if !ok && len(hits) == 0 && len(aur_hits) == 0 {
		return emit_refusal(o, "search", refuse(EXIT_NOT_FOUND, "no-results", fmt.tprintf("nothing matches %q", q), {q}))
	}
	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "search")
		jw_kstr(&jw, "query", q)
		jw_key(&jw, "results")
		jw_arr(&jw)
		emit :: proc(jw: ^JW, h: Search_Hit) {
			jw_obj(jw)
			jw_kstr(jw, "name", h.name)
			jw_kstr(jw, "repo", h.repo)
			jw_kstr(jw, "version", h.version)
			jw_kstr(jw, "description", h.description)
			jw_kbool(jw, "installed", h.installed)
			jw_obj_end(jw)
		}
		for h in hits {
			emit(&jw, h)
		}
		for h in aur_hits {
			emit(&jw, h)
		}
		jw_arr_end(&jw)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	for h in hits {
		outln("%s/%s %s%s", h.repo, h.name, h.version, h.installed ? "  [installed]" : "")
		if h.description != "" {
			outln("    %s", h.description)
		}
	}
	for h in aur_hits {
		outln("aur/%s %s", h.name, h.version)
	}
	return EXIT_OK
}

verb_info :: proc(o: ^Opts) -> int {
	if len(o.args) == 0 {
		fmt.eprintln("[pkg] info needs a package name")
		return EXIT_USAGE
	}
	name := o.args[0]
	if !pkg_name_ok(name) {
		return emit_refusal(
			o,
			"info",
			refuse(EXIT_USAGE, "invalid-name", fmt.tprintf("%q is not a package name", name), {name}),
		)
	}
	if !have_tool("pacman") {
		return unavailable(o, "pacman")
	}
	text, ok := run_query({"pacman", "-Qi", "--", name})
	installed := true
	if !ok || strings.trim_space(text) == "" {
		text, ok = run_query({"pacman", "-Si", "--", name})
		installed = false
	}
	infos := parse_qi(text)
	if len(infos) == 0 {
		return emit_refusal(
			o,
			"info",
			refuse(EXIT_NOT_FOUND, "unknown-package", "no such package installed or in a repo", {name}),
		)
	}
	inf := infos[0]
	g := guard_of(inf.name)
	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "info")
		jw_kstr(&jw, "name", inf.name)
		jw_kstr(&jw, "version", inf.version)
		jw_kstr(&jw, "description", inf.description)
		jw_kbool(&jw, "installed", installed)
		jw_kstr(&jw, "install_reason", inf.reason)
		jw_kstrs(&jw, "required_by", inf.required_by)
		jw_kstrs(&jw, "optional_for", inf.optional_for)
		jw_kstr(&jw, "protected", guard_name(g))
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	outln("%s %s", inf.name, inf.version)
	outln("  %s", inf.description)
	outln("  installed: %v", installed)
	if len(inf.required_by) > 0 {
		outln("  required by: %s", strings.join(inf.required_by, " ", context.temp_allocator))
	}
	if g != .None {
		outln("  protected: %s -- %s", guard_name(g), guard_why(g))
	}
	return EXIT_OK
}

emit_problems :: proc(jw: ^JW, d: ^Decl) {
	jw_key(jw, "problems")
	jw_arr(jw)
	for p in d.problems {
		jw_obj(jw)
		jw_kint(jw, "line", p.line)
		jw_kstr(jw, "text", p.text)
		jw_obj_end(jw)
	}
	jw_arr_end(jw)
}

verb_diff :: proc(o: ^Opts) -> int {
	d, path, existed := load_decl(o)
	w, ok := load_world()
	if !ok {
		return unavailable(o, "pacman")
	}
	declared, _ := decl_wanted(&d, o.profiles)
	df := diff_compute(&w, declared)

	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "diff")
		jw_kstr(&jw, "class", "read")
		jw_kstr(&jw, "identity", o.identity)
		jw_kstr(&jw, "file", path)
		jw_kbool(&jw, "file_exists", existed)
		jw_kstrs(&jw, "profiles", d.profiles[:])
		jw_kint(&jw, "declared", len(declared))
		jw_kint(&jw, "installed_explicit", len(w.explicit))
		jw_kstrs(&jw, "missing", df.missing)
		jw_kstrs(&jw, "extra", df.extra)
		jw_kint(&jw, "satisfied", len(df.satisfied))
		jw_kbool(&jw, "in_sync", df.in_sync)
		emit_problems(&jw, &d)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}

	if !existed {
		outln("no declaration at %s", path)
		outln("`pkg declare <names...>` writes one; `pkg list --explicit` is a starting point")
	}
	for p in d.problems {
		outln("%s:%d: %s", path, p.line, p.text)
	}
	outln("declared %d, explicit on this machine %d", len(declared), len(w.explicit))
	for n in df.missing {
		outln("  + %s\tdeclared, not installed", n)
	}
	for n in df.extra {
		outln("  - %s\tinstalled, not declared", n)
	}
	if df.in_sync {
		outln("in sync")
	}
	return EXIT_OK
}

verb_declare :: proc(o: ^Opts, remove: bool) -> int {
	if len(o.args) == 0 {
		fmt.eprintfln("[pkg] %s needs at least one package name", o.verb)
		return EXIT_USAGE
	}
	for n in o.args {
		if !pkg_name_ok(n) {
			return emit_refusal(
				o,
				o.verb,
				refuse(EXIT_USAGE, "invalid-name", fmt.tprintf("%q is not a package name", n), {n}),
			)
		}
	}
	path := decl_path(o)
	old := ""
	if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
		old = string(data)
	}

	profile := DEFAULT_PROFILE
	if len(o.profiles) > 0 {
		profile = o.profiles[0]
	}

	new_text: string
	changed: []string
	if remove {
		new_text, changed = decl_remove(old, o.args)
	} else {
		new_text, changed = decl_add(old, o.args, profile, o.aur ? .Aur : .Repo)
	}

	wrote := false
	if !o.dry_run && len(changed) > 0 {
		if slash := strings.last_index_byte(path, '/'); slash > 0 {
			_ = os.make_directory_all(path[:slash])
		}
		if err := os.write_entire_file(path, transmute([]u8)new_text); err != nil {
			return emit_refusal(
				o,
				o.verb,
				refuse(EXIT_FAILED, "write-failed", fmt.tprintf("could not write %s: %v", path, err)),
			)
		}
		wrote = true
	}

	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", o.verb)
		jw_kstr(&jw, "class", "mutate")
		jw_kstr(&jw, "file", path)
		jw_kstr(&jw, "profile", profile)
		jw_kbool(&jw, "dry_run", o.dry_run)
		jw_kbool(&jw, "wrote", wrote)
		jw_kstrs(&jw, "changed", changed)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	if len(changed) == 0 {
		outln("no change to %s", path)
		return EXIT_OK
	}
	outln("%s %s in %s%s", remove ? "undeclared" : "declared", strings.join(changed, " ", context.temp_allocator), path, o.dry_run ? " (dry run, not written)" : "")
	if !remove {
		outln("nothing was installed; `pkg sync` is what converges the machine")
	}
	return EXIT_OK
}

verb_install :: proc(o: ^Opts) -> int {
	if len(o.args) == 0 {
		fmt.eprintln("[pkg] install needs at least one package name")
		return EXIT_USAGE
	}
	w, ok := load_world()
	if !ok {
		return unavailable(o, "pacman")
	}
	world_load_repo(&w, o.args)
	d, _, _ := load_decl(o)
	_, sources := decl_wanted(&d, o.profiles)
	p, r := plan_install(
		&w,
		o.args,
		Install_Opts{refresh = o.refresh, aur = o.aur, snapshot = true, sources = sources},
	)
	if r.refused {
		return emit_refusal(o, "install", r)
	}
	return carry_out(o, &p, r)
}

verb_remove :: proc(o: ^Opts) -> int {
	if len(o.args) == 0 {
		fmt.eprintln("[pkg] remove needs at least one package name")
		return EXIT_USAGE
	}
	w, ok := load_world()
	if !ok {
		return unavailable(o, "pacman")
	}
	world_load_dependants(&w, o.args)
	p, r := plan_remove(
		&w,
		o.args,
		Remove_Opts{yes = o.yes, recursive = o.recursive, snapshot = true, allow = o.allow},
	)
	if r.refused {
		return emit_refusal(o, "remove", r)
	}
	return carry_out(o, &p, r)
}

verb_sync :: proc(o: ^Opts) -> int {
	d, path, existed := load_decl(o)
	if !existed {
		return emit_refusal(
			o,
			"sync",
			refuse(EXIT_NOT_FOUND, "no-declaration", fmt.tprintf("no declaration at %s", path)),
		)
	}
	if len(d.problems) > 0 {
		subj := make([dynamic]string, context.temp_allocator)
		for p in d.problems {
			append(&subj, fmt.tprintf("line %d: %s", p.line, p.text))
		}
		return emit_refusal(
			o,
			"sync",
			refuse(
				EXIT_USAGE,
				"bad-declaration",
				"the declaration does not parse cleanly, and converging toward a half-read file is worse than not converging",
				subj[:],
			),
		)
	}
	w, ok := load_world()
	if !ok {
		return unavailable(o, "pacman")
	}
	declared, sources := decl_wanted(&d, o.profiles)
	df := diff_compute(&w, declared)
	world_load_repo(&w, df.missing)
	if o.prune {
		world_load_dependants(&w, df.extra)
	}
	p, r := plan_sync(
		&w,
		df,
		Sync_Opts {
			prune = o.prune,
			yes = o.yes,
			aur = o.aur,
			snapshot = true,
			allow = o.allow,
			sources = sources,
		},
	)
	if r.refused {
		return emit_refusal(o, "sync", r)
	}
	return carry_out(o, &p, r)
}

verb_upgrade :: proc(o: ^Opts) -> int {
	p, r := plan_upgrade(
		Upgrade_Opts{aur = o.aur, snapshot = true, interactive = is_a_person()},
	)
	if r.refused {
		return emit_refusal(o, "upgrade", r)
	}
	// An upgrade is interactive on purpose, so --yes is not what gates it; a
	// person at the terminal is, and pacman asks its own questions.
	if o.dry_run {
		return emit_plan(o, &p, false, 0)
	}
	note("a full upgrade can stop for a .pacnew or a keyring change; stay with it")
	ran, code := exec_plan(&p)
	emit_plan(o, &p, true, ran)
	return exec_failed(o, code)
}

verb_snapshots :: proc(o: ^Opts) -> int {
	text, ok := run_query({"snapper", "--config", "root", "list"})
	if !ok && strings.trim_space(text) == "" {
		return emit_refusal(
			o,
			"snapshots",
			refuse(
				EXIT_UNAVAILABLE,
				"unavailable",
				"could not read the snapper list; snapper usually needs root or an ALLOW_USERS entry for this",
			),
		)
	}
	snaps := parse_snapper_list(text)
	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "snapshots")
		jw_kstr(&jw, "class", "read")
		jw_key(&jw, "snapshots")
		jw_arr(&jw)
		for s in snaps {
			jw_obj(&jw)
			jw_kint(&jw, "number", s.number)
			jw_kstr(&jw, "type", s.kind)
			jw_kstr(&jw, "date", s.date)
			jw_kstr(&jw, "description", s.description)
			jw_kbool(&jw, "from_palm", s.from_palm)
			jw_obj_end(&jw)
		}
		jw_arr_end(&jw)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	for s in snaps {
		outln("%d\t%s\t%s\t%s", s.number, s.kind, s.date, s.description)
	}
	return EXIT_OK
}

verb_rollback :: proc(o: ^Opts) -> int {
	n := 0
	if len(o.args) > 0 {
		v, ok := strconv.parse_int(o.args[0])
		if !ok {
			fmt.eprintfln("[pkg] %q is not a snapshot number", o.args[0])
			return EXIT_USAGE
		}
		n = v
	}
	p, r := plan_rollback(n, Rollback_Opts{yes = o.yes, interactive = is_a_person()})
	if r.refused {
		return emit_refusal(o, "rollback", r)
	}
	if o.dry_run {
		return emit_plan(o, &p, false, 0)
	}
	ran, code := exec_plan(&p)
	emit_plan(o, &p, true, ran)
	return exec_failed(o, code)
}

// verb_verbs is the machine-readable surface pkg had before the shared
// convention, kept because agents already read it. It is generated from the
// same declaration `--schema` prints (cli.odin), so the two cannot drift.
verb_verbs :: proc(o: ^Opts) -> int {
	cmds := surface().commands
	if o.json {
		jw := jw_make(context.temp_allocator)
		jw_obj(&jw)
		jw_kstr(&jw, "op", "verbs")
		jw_key(&jw, "verbs")
		jw_arr(&jw)
		for v in cmds {
			jw_obj(&jw)
			jw_kstr(&jw, "name", v.verb)
			jw_kstr(&jw, "class", kit.effect_name(v.effect))
			jw_kstr(&jw, "help", v.summary)
			jw_obj_end(&jw)
		}
		jw_arr_end(&jw)
		jw_key(&jw, "exit_codes")
		jw_obj(&jw)
		jw_kint(&jw, "ok", EXIT_OK)
		jw_kint(&jw, "usage", EXIT_USAGE)
		jw_kint(&jw, "not_found", EXIT_NOT_FOUND)
		jw_kint(&jw, "needs_yes", EXIT_NEEDS_YES)
		jw_kint(&jw, "out_of_scope", EXIT_SCOPE)
		jw_kint(&jw, "unavailable", EXIT_UNAVAILABLE)
		jw_kint(&jw, "failed", EXIT_FAILED)
		jw_obj_end(&jw)
		jw_kstrs(
			&jw,
			"protected_classes",
			{"kernel", "bootloader", "display-manager", "init", "core"},
		)
		jw_obj_end(&jw)
		jw_emit(&jw)
		return EXIT_OK
	}
	for v in cmds {
		outln("%-10s %-12s %s", v.verb, kit.effect_name(v.effect), v.summary)
	}
	return EXIT_OK
}
