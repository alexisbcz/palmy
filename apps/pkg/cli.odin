package main

// The declaration of `pkg`'s command line, on the shared convention
// (apps/kit/cli.odin, docs/PALM-CLI.md).
//
// The kit parses and validates the line, generates --help, prints the result
// as JSON under --json, refuses a destructive verb without --yes, enforces
// identity scope and writes the audit record. The verbs themselves are the
// same procedures they always were (main.odin): each `run_*` below only turns
// the parsed call into the Opts those procedures take. One implementation,
// reached through one parser.
//
// Every spelling pkg accepted before still works: the verbs are the verbs,
// --json --dry-run --yes --identity are the kit's base flags, --selftest and
// --self-test are the kit's, and --aur --recursive --prune --refresh
// --explicit --profile --file --allow-protected are declared on the verbs
// they mean something to. `--profile` and `--allow-protected` may be given
// more than once, as before.
//
// SAFETY. Nothing here changes how a plan reaches the machine: carry_out and
// exec_plan are untouched, a mutating verb still refuses without --yes, and
// --dry-run still prints the argv and runs nothing. The kit's execution guard
// does not know pacman or sudo -- pkg's own planner is the fence, as it was.

import "core:strings"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "list",
		summary = "what is installed, and which of it was explicit",
		effect = .Read,
		flags = {{name = "explicit", kind = .Bool, help = "only what was installed explicitly"}},
		out = {
			{name = "op", kind = .String},
			{name = "installed", kind = .Int, help = "packages installed"},
			{name = "explicit", kind = .Int, help = "of which explicitly"},
			{
				name = "packages",
				kind = .Array,
				of = {
					{name = "name", kind = .String},
					{name = "explicit", kind = .Bool},
					{name = "protected", kind = .String, opt = true, help = "the protected class, if any"},
				},
			},
		},
		examples = {"pkg list --json", "pkg list --explicit --json"},
		run = run_list,
	},
	{
		verb = "search",
		summary = "repos, and the AUR with --aur",
		effect = .Read,
		args = {{name = "query", kind = .String, help = "what to look for", required = true}},
		flags = {{name = "aur", kind = .Bool, help = "search the AUR too, through yay"}},
		out = {
			{name = "op", kind = .String},
			{name = "query", kind = .String},
			{
				name = "results",
				kind = .Array,
				of = {
					{name = "name", kind = .String},
					{name = "repo", kind = .String},
					{name = "version", kind = .String},
					{name = "description", kind = .String},
					{name = "installed", kind = .Bool},
				},
			},
		},
		examples = {"pkg search ripgrep --json", "pkg search ripgrep --aur --json"},
		run = run_search,
	},
	{
		verb = "info",
		summary = "one package: version, why it is installed, what needs it",
		effect = .Read,
		args = {{name = "name", kind = .String, help = "a package name", required = true}},
		out = {
			{name = "op", kind = .String},
			{name = "name", kind = .String},
			{name = "version", kind = .String},
			{name = "description", kind = .String},
			{name = "installed", kind = .Bool},
			{name = "install_reason", kind = .String},
			{name = "required_by", kind = .Array, of = {{kind = .String}}},
			{name = "optional_for", kind = .Array, of = {{kind = .String}}},
			{name = "protected", kind = .String},
		},
		examples = {"pkg info git --json"},
		run = run_info,
	},
	{
		verb = "diff",
		summary = "how the machine differs from the declaration",
		effect = .Read,
		flags = {
			{name = "profile", kind = .String, help = "only these profiles, comma-separated; may repeat"},
			{name = "file", kind = .Path, help = "the declaration file, instead of the identity's"},
		},
		out = {
			{name = "op", kind = .String},
			{name = "class", kind = .String},
			{name = "identity", kind = .String},
			{name = "file", kind = .String},
			{name = "file_exists", kind = .Bool},
			{name = "profiles", kind = .Array, of = {{kind = .String}}},
			{name = "declared", kind = .Int},
			{name = "installed_explicit", kind = .Int},
			{name = "missing", kind = .Array, of = {{kind = .String}}, help = "declared, not installed"},
			{name = "extra", kind = .Array, of = {{kind = .String}}, help = "installed, not declared"},
			{name = "satisfied", kind = .Int},
			{name = "in_sync", kind = .Bool},
			{name = "problems", kind = .Array, of = {{name = "line", kind = .Int}, {name = "text", kind = .String}}},
		},
		examples = {"pkg diff --json", "pkg diff --profile base,dev --json"},
		run = run_diff,
	},
	{
		verb = "declare",
		summary = "add to the declaration without installing now",
		effect = .Mutate,
		args = {{name = "names", kind = .String, help = "package names", required = true, variadic = true}},
		flags = {
			{name = "profile", kind = .String, help = "the profile to file them under"},
			{name = "aur", kind = .Bool, help = "they come from the AUR"},
			{name = "file", kind = .Path, help = "the declaration file, instead of the identity's"},
		},
		out = DECLARE_FIELDS,
		examples = {"pkg declare htop ripgrep --json", "pkg declare htop --profile dev --dry-run --json"},
		run = run_declare,
	},
	{
		verb = "undeclare",
		summary = "drop from the declaration without removing now",
		effect = .Mutate,
		args = {{name = "names", kind = .String, help = "package names", required = true, variadic = true}},
		flags = {{name = "file", kind = .Path, help = "the declaration file, instead of the identity's"}},
		out = DECLARE_FIELDS,
		examples = {"pkg undeclare htop --json"},
		run = run_undeclare,
	},
	{
		verb = "install",
		summary = "install; snapshots first; never refreshes the database; refuses without --yes",
		effect = .Mutate,
		args = {{name = "names", kind = .String, help = "package names", required = true, variadic = true}},
		flags = {
			{name = "aur", kind = .Bool, help = "allow the AUR, through yay"},
			{name = "refresh", kind = .Bool, help = "asks for -Sy, which is always refused: a partial upgrade"},
			{name = "profile", kind = .String, help = "profiles whose sources apply"},
			{name = "file", kind = .Path, help = "the declaration file, instead of the identity's"},
		},
		out = PLAN_FIELDS,
		examples = {"pkg install ripgrep --dry-run --json", "pkg install ripgrep --yes --json"},
		run = run_install,
	},
	{
		verb = "remove",
		summary = "remove, naming every dependant; refuses without --yes",
		effect = .Destructive,
		args = {{name = "names", kind = .String, help = "package names", required = true, variadic = true}},
		flags = {
			{name = "recursive", kind = .Bool, help = "also remove what only these needed"},
			{
				name = "allow-protected",
				kind = .Enum,
				values = PROTECTED_CLASSES,
				help = "a protected class this removal may cross; may repeat",
			},
		},
		out = PLAN_FIELDS,
		examples = {"pkg remove htop --yes --json", "pkg remove htop --dry-run --json"},
		run = run_remove,
	},
	{
		verb = "sync",
		summary = "converge toward the declaration; refuses without --yes",
		effect = .Idempotent,
		flags = {
			{name = "prune", kind = .Bool, help = "also remove what is installed and not declared"},
			{name = "aur", kind = .Bool, help = "allow the AUR, through yay"},
			{name = "profile", kind = .String, help = "only these profiles, comma-separated; may repeat"},
			{name = "file", kind = .Path, help = "the declaration file, instead of the identity's"},
			{name = "allow-protected", kind = .Enum, values = PROTECTED_CLASSES, help = "a protected class --prune may remove; may repeat"},
		},
		out = PLAN_FIELDS,
		examples = {"pkg sync --dry-run --json", "pkg sync --prune --yes --json"},
		run = run_sync,
	},
	{
		verb = "upgrade",
		summary = "full -Syu; refuses without a person at a terminal",
		effect = .Mutate,
		flags = {{name = "aur", kind = .Bool, help = "the AUR too, through yay"}},
		out = PLAN_FIELDS,
		examples = {"pkg upgrade --dry-run --json"},
		run = run_upgrade,
	},
	{
		verb = "snapshots",
		summary = "the snapshots palm took",
		effect = .Read,
		out = {
			{name = "op", kind = .String},
			{name = "class", kind = .String},
			{
				name = "snapshots",
				kind = .Array,
				of = {
					{name = "number", kind = .Int},
					{name = "type", kind = .String},
					{name = "date", kind = .String},
					{name = "description", kind = .String},
					{name = "from_palm", kind = .Bool},
				},
			},
		},
		examples = {"pkg snapshots --json"},
		run = run_snapshots,
	},
	{
		verb = "rollback",
		summary = "back to before a named operation; needs --yes and a person",
		effect = .Destructive,
		args = {{name = "number", kind = .Int, help = "the snapshot number", required = true}},
		out = PLAN_FIELDS,
		examples = {"pkg rollback 7 --yes --json", "pkg rollback 7 --dry-run --json"},
		run = run_rollback,
	},
	{
		verb = "verbs",
		summary = "this surface in pkg's older shape, with the exit codes and protected classes",
		effect = .Read,
		out = {
			{name = "op", kind = .String},
			{
				name = "verbs",
				kind = .Array,
				of = {{name = "name", kind = .String}, {name = "class", kind = .String}, {name = "help", kind = .String}},
			},
			{name = "exit_codes", kind = .Object},
			{name = "protected_classes", kind = .Array, of = {{kind = .String}}},
		},
		examples = {"pkg verbs --json"},
		run = run_verbs,
	},
}

// The field lists shared by several verbs are procedures' worth of literal,
// not package variables pointing at each other: initialisers run in
// declaration order, and a list captured before it was filled would make the
// schema lie. Constants of slice literals are safe either way.
// The spellings guard_from_name accepts, so the shared parser rejects a typo
// before anything else runs -- including the --yes gate on remove.
@(private = "file")
PROTECTED_CLASSES :: []string{"kernel", "bootloader", "display-manager", "display_manager", "dm", "init", "core"}

@(private = "file")
DECLARE_FIELDS :: []kit.Field {
	{name = "op", kind = .String},
	{name = "class", kind = .String},
	{name = "file", kind = .String, help = "the declaration written"},
	{name = "profile", kind = .String},
	{name = "dry_run", kind = .Bool},
	{name = "wrote", kind = .Bool},
	{name = "changed", kind = .Array, of = {{kind = .String}}},
}

@(private = "file")
PLAN_FIELDS :: []kit.Field {
	{name = "op", kind = .String},
	{name = "class", kind = .String},
	{name = "dry_run", kind = .Bool},
	{name = "executed", kind = .Bool},
	{name = "steps_run", kind = .Int},
	{name = "targets", kind = .Array, of = {{kind = .String}}},
	{name = "skipped", kind = .Array, of = {{kind = .String}}},
	{
		name = "steps",
		kind = .Array,
		help = "the exact argv, in order; a snapshot first",
		of = {
			{name = "what", kind = .String},
			{name = "needs_root", kind = .Bool},
			{name = "argv", kind = .Array, of = {{kind = .String}}},
		},
	},
	{name = "notes", kind = .Array, of = {{kind = .String}}},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "pkg",
			summary  = "the declarative layer over pacman: a declaration, a diff, a converge",
			gui      = false,
			selftest = selftest_cli,
			commands = COMMANDS,
			notes    = `The declaration lives in $XDG_CONFIG_HOME/palm/packages/<identity>.pkgs
(override with PALM_PKG_DIR or --file).

Mutating verbs refuse without --yes and never prompt; --dry-run prints the
exact argv and runs nothing. Nothing ever emits -Sy without -u, and the
kernel, bootloader, display manager, init and core need their own
--allow-protected. pkg never reads, stores or passes a sudo password.`,
		}
	}
	return &g_surface
}

@(private = "file")
selftest_cli :: proc() -> int {
	selftest() // exits 1 itself on a failure
	return EXIT_OK
}

// every_value collects each occurrence of a flag that may be repeated
// (`--profile a --profile b`, `--allow-protected=kernel`), since the kit keeps
// only the last one.
@(private = "file")
every_value :: proc(c: ^kit.Call, name: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	flag := strings.concatenate({"--", name}, context.temp_allocator)
	prefix := strings.concatenate({flag, "="}, context.temp_allocator)
	for i := 0; i < len(c.argv); i += 1 {
		a := c.argv[i]
		if a == "--" {
			break
		}
		if a == flag && i + 1 < len(c.argv) {
			append(&out, c.argv[i + 1])
			i += 1
		} else if strings.has_prefix(a, prefix) {
			append(&out, a[len(prefix):])
		}
	}
	return out[:]
}

// opts_of turns a parsed call into the Opts the verbs have always taken.
@(private = "file")
opts_of :: proc(c: ^kit.Call) -> (o: Opts, code: int) {
	o.verb = c.cmd.verb
	o.json = c.json
	o.dry_run = c.dry_run
	o.yes = c.yes
	o.aur = kit.cli_bool(c, "aur")
	o.recursive = kit.cli_bool(c, "recursive")
	o.prune = kit.cli_bool(c, "prune")
	o.refresh = kit.cli_bool(c, "refresh")
	o.explicit = kit.cli_bool(c, "explicit")
	o.file = kit.cli_str(c, "file")
	o.identity = c.identity == "" ? "default" : c.identity

	profiles := make([dynamic]string, context.temp_allocator)
	for v in every_value(c, "profile") {
		for p in strings.split(v, ",", context.temp_allocator) {
			if t := strings.trim_space(p); t != "" {
				append(&profiles, t)
			}
		}
	}
	o.profiles = profiles[:]

	allow := make([dynamic]Guard, context.temp_allocator)
	for v in every_value(c, "allow-protected") {
		g, good := guard_from_name(v)
		if !good {
			kit.cli_err_field(c, "given", v)
			return o, kit.cli_failf(
				c,
				EXIT_USAGE,
				"unknown protected class %q: kernel, bootloader, display-manager, init, core",
				v,
			)
		}
		append(&allow, g)
	}
	o.allow = allow[:]

	args := make([dynamic]string, context.temp_allocator)
	if rest := kit.cli_rest(c); len(rest) > 0 {
		append(&args, ..rest)
	} else {
		for p in c.cmd.args {
			if kit.cli_has(c, p.name) {
				append(&args, kit.cli_str(c, p.name))
			}
		}
	}
	o.args = args[:]
	return o, EXIT_OK
}

@(private = "file")
run_with :: proc(c: ^kit.Call, body: proc(o: ^Opts) -> int) -> int {
	o, code := opts_of(c)
	if code != EXIT_OK {
		return code
	}
	g_call = c
	defer g_call = nil
	return body(&o)
}

@(private = "file")
run_list :: proc(c: ^kit.Call) -> int {return run_with(c, verb_list)}
@(private = "file")
run_search :: proc(c: ^kit.Call) -> int {return run_with(c, verb_search)}
@(private = "file")
run_info :: proc(c: ^kit.Call) -> int {return run_with(c, verb_info)}
@(private = "file")
run_diff :: proc(c: ^kit.Call) -> int {return run_with(c, verb_diff)}
@(private = "file")
run_declare :: proc(c: ^kit.Call) -> int {return run_with(c, proc(o: ^Opts) -> int {return verb_declare(o, false)})}
@(private = "file")
run_undeclare :: proc(c: ^kit.Call) -> int {return run_with(c, proc(o: ^Opts) -> int {return verb_declare(o, true)})}
@(private = "file")
run_install :: proc(c: ^kit.Call) -> int {return run_with(c, verb_install)}
@(private = "file")
run_remove :: proc(c: ^kit.Call) -> int {return run_with(c, verb_remove)}
@(private = "file")
run_sync :: proc(c: ^kit.Call) -> int {return run_with(c, verb_sync)}
@(private = "file")
run_upgrade :: proc(c: ^kit.Call) -> int {return run_with(c, verb_upgrade)}
@(private = "file")
run_snapshots :: proc(c: ^kit.Call) -> int {return run_with(c, verb_snapshots)}
@(private = "file")
run_rollback :: proc(c: ^kit.Call) -> int {return run_with(c, verb_rollback)}
@(private = "file")
run_verbs :: proc(c: ^kit.Call) -> int {return run_with(c, verb_verbs)}
