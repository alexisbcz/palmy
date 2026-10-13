package main

// The command-line face of Software, under the shared convention
// (apps/kit/cli.odin): `store search x --json`, `store install track --yes`.
//
// The reading commands are the window's catalogue (model.odin) printed
// instead of drawn. The changing commands are the window's dialog without a
// window: they ask palmd for a plan, print it, and -- unless --dry-run --
// apply it, with palm's progress on stderr. `remove` is destructive and so
// needs --yes, by the convention; `install` and `upgrade` show the plan they
// ran in their output, so an agent can see what a yes cost.

import "core:fmt"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "search",
		summary = "packages whose name, summary or category contains every word",
		effect = .Read,
		args = {{name = "text", kind = .String, help = "words to look for", required = true, variadic = true}},
		out = {{name = "results", kind = .Array, of = {{name = "name", kind = .String}, {name = "version", kind = .String}, {name = "summary", kind = .String}, {name = "category", kind = .String}, {name = "installed", kind = .String}}}},
		examples = {"store search terminal --json", "store search office"},
		run = cmd_search,
	},
	{
		verb = "info",
		summary = "one package: summary, details, sizes, licence, dependencies and what needs it",
		effect = .Read,
		args = {{name = "package", kind = .String, help = "a package name", required = true}},
		out = {
			{name = "name", kind = .String},
			{name = "version", kind = .String},
			{name = "summary", kind = .String},
			{name = "details", kind = .String},
			{name = "category", kind = .String},
			{name = "license", kind = .String},
			{name = "size", kind = .Int},
			{name = "download_size", kind = .Int},
			{name = "installed", kind = .String},
			{name = "explicit", kind = .Bool, help = "in world: installed because someone asked for it"},
			{name = "depends", kind = .Array, of = {{kind = .String}}},
			{name = "required_by", kind = .Array, of = {{kind = .String}}},
		},
		examples = {"store info track --json"},
		run = cmd_info,
	},
	{
		verb = "list",
		summary = "the catalogue, or what is installed, or what can be updated",
		effect = .Read,
		flags = {
			{name = "installed", kind = .Bool, help = "only installed packages"},
			{name = "upgradable", kind = .Bool, help = "only packages with an update"},
		},
		out = {{name = "packages", kind = .Array, of = {{name = "name", kind = .String}, {name = "version", kind = .String}, {name = "installed", kind = .String}, {name = "category", kind = .String}, {name = "explicit", kind = .Bool}, {name = "size", kind = .Int}}}},
		examples = {"store list --installed --json", "store list --upgradable"},
		run = cmd_list,
	},
	{
		verb = "plan",
		summary = "what palmd would do for add, del or upgrade, changing nothing",
		effect = .Read,
		args = {
			{name = "action", kind = .Enum, values = {"add", "del", "upgrade"}, help = "what to plan", required = true},
			{name = "packages", kind = .String, help = "package names (none for upgrade)", variadic = true},
		},
		out = PLAN_FIELDS,
		examples = {"store plan add track --json", "store plan upgrade"},
		run = cmd_plan,
	},
	{
		verb = "install",
		summary = "install packages through palmd, after printing palm's plan",
		effect = .Mutate,
		args = {{name = "packages", kind = .String, help = "package names", required = true, variadic = true}},
		out = PLAN_FIELDS,
		examples = {"store install track", "store install track --dry-run --json"},
		run = cmd_install,
	},
	{
		verb = "remove",
		summary = "remove packages through palmd (and whatever only they needed)",
		effect = .Destructive,
		args = {{name = "packages", kind = .String, help = "package names", required = true, variadic = true}},
		out = PLAN_FIELDS,
		examples = {"store remove track --yes", "store remove track --dry-run"},
		run = cmd_remove,
	},
	{
		verb = "upgrade",
		summary = "update every package that has a newer version, through palmd",
		effect = .Mutate,
		out = PLAN_FIELDS,
		examples = {"store upgrade --dry-run --json", "store upgrade"},
		run = cmd_upgrade,
	},
	{
		verb = "update",
		summary = "fetch and verify the repository indexes, through palmd",
		effect = .Idempotent,
		out = {{name = "ok", kind = .Bool}},
		examples = {"store update"},
		run = cmd_update,
	},
}

PLAN_FIELDS := []kit.Field {
	{name = "summary", kind = .String, help = "the plan in one line"},
	{name = "plan_id", kind = .String},
	{name = "install", kind = .Array, of = {{kind = .String}}},
	{name = "upgrade", kind = .Array, of = {{kind = .String}}},
	{name = "remove", kind = .Array, of = {{kind = .String}}},
	{name = "download_size", kind = .Int},
	{name = "size_change", kind = .Int},
	{name = "applied", kind = .Bool, help = "false for plan and --dry-run"},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "store",
			summary  = "Software: find, install and update packages (palm to read, palmd to change)",
			gui      = true,
			selftest = selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Reading commands run palm as you. Changing commands go through palmd on
/run/palmd.sock, which answers root and members of group wheel only, and
always plan before they apply: the plan printed is the plan that runs.`

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

@(private = "file")
load_or_fail :: proc(c: ^kit.Call, cat: ^Catalog) -> int {
	catalog_load(cat)
	if cat.error != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, cat.error)
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	cat: Catalog
	if code := load_or_fail(c, &cat); code != 0 {return code}
	// The variadic tail holds every word, the first included.
	hits := search(&cat, strings.join(kit.cli_rest(c), " ", context.temp_allocator))
	arr := kit.jarr()
	for pk in hits {
		o := kit.jobj()
		kit.jset_str(o, "name", pk.name)
		kit.jset_str(o, "version", pk.version)
		kit.jset_str(o, "summary", pk.summary)
		kit.jset_str(o, "category", pk.category)
		kit.jset_str(o, "installed", pk.installed)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "results", arr)
	if len(hits) == 0 {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no package matches")
	}
	return kit.EXIT_OK
}

@(private = "file")
strs :: proc(list: []string) -> ^kit.Json {
	arr := kit.jarr()
	for s in list {kit.jpush(arr, kit.jstr(s))}
	return arr
}

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	cat: Catalog
	if code := load_or_fail(c, &cat); code != 0 {return code}
	name := kit.cli_str(c, "package")
	pk := find(&cat, name)
	if pk == nil {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s: no such package", name)
	}
	package_load_info(pk)
	kit.jset_str(c.out, "name", pk.name)
	kit.jset_str(c.out, "version", pk.version)
	kit.jset_str(c.out, "summary", pk.summary)
	kit.jset_str(c.out, "details", pk.details)
	kit.jset_str(c.out, "category", pk.category)
	kit.jset_str(c.out, "license", pk.license)
	kit.jset_int(c.out, "size", int(pk.size))
	kit.jset_int(c.out, "download_size", int(pk.csize))
	kit.jset_str(c.out, "installed", pk.installed)
	kit.jset_bool(c.out, "explicit", pk.explicit)
	kit.jset(c.out, "depends", strs(pk.depends))
	kit.jset(c.out, "required_by", strs(pk.required_by))
	return kit.EXIT_OK
}

@(private = "file")
cmd_list :: proc(c: ^kit.Call) -> int {
	cat: Catalog
	if code := load_or_fail(c, &cat); code != 0 {return code}
	only_inst := kit.cli_bool(c, "installed")
	only_up := kit.cli_bool(c, "upgradable")
	arr := kit.jarr()
	for &pk in cat.pkgs {
		if only_inst && pk.installed == "" {continue}
		if only_up && !pk.upgradable {continue}
		o := kit.jobj()
		kit.jset_str(o, "name", pk.name)
		kit.jset_str(o, "version", pk.version)
		kit.jset_str(o, "installed", pk.installed)
		kit.jset_str(o, "category", pk.category)
		kit.jset_bool(o, "explicit", pk.explicit)
		kit.jset_int(o, "size", int(pk.installed != "" ? pk.installed_size : pk.size))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "packages", arr)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Changing, through palmd
// ---------------------------------------------------------------------------

// wait_for runs the transaction's poll loop until it reaches one of `stages`,
// with palm's progress on stderr as it arrives.
@(private = "file")
wait_for :: proc(c: ^kit.Call, t: ^Txn, stages: bit_set[Txn_Stage]) {
	last := ""
	start := time.tick_now()
	for !(t.stage in stages) {
		txn_poll(t, time.duration_seconds(time.tick_since(start)))
		if t.current != last && t.current != "" {
			if t.steps > 0 {
				kit.cli_note(c, "store: [%d/%d] %s", t.step, t.steps, t.current)
			} else {
				kit.cli_note(c, "store: %s", t.current)
			}
			last = strings.clone(t.current, context.temp_allocator)
		}
		for len(t.log) > 0 {
			kit.cli_note(c, "palm: %s", t.log[0])
			ordered_remove(&t.log, 0)
		}
		if t.stage in stages {break}
		time.sleep(30 * time.Millisecond)
	}
}

@(private = "file")
plan_out :: proc(c: ^kit.Call, t: ^Txn, applied: bool) {
	names :: proc(items: []Plan_Item) -> ^kit.Json {
		arr := kit.jarr()
		for it in items {kit.jpush(arr, kit.jstr(it.name))}
		return arr
	}
	kit.jset_str(c.out, "summary", plan_sentence(t.plan))
	kit.jset_str(c.out, "plan_id", t.plan_id)
	kit.jset(c.out, "install", names(t.plan.install))
	kit.jset(c.out, "upgrade", names(t.plan.upgrade))
	kit.jset(c.out, "remove", names(t.plan.remove))
	kit.jset_int(c.out, "download_size", int(t.plan.download))
	kit.jset_int(c.out, "size_change", int(t.plan.size_change))
	kit.jset_bool(c.out, "applied", applied)
}

@(private = "file")
change :: proc(c: ^kit.Call, action: Action, names: []string, apply: bool) -> int {
	t: Txn
	txn_begin(&t, action, names)
	wait_for(c, &t, {.Confirm, .Failed, .Done})
	if t.stage == .Failed {
		return kit.cli_fail(c, t.code == 6 ? kit.EXIT_UNAVAILABLE : (t.code == 4 ? kit.EXIT_NEEDS_YES : kit.EXIT_FAILED), t.error)
	}
	kit.cli_note(c, "store: palm's plan: %s", plan_sentence(t.plan))
	if !apply || plan_empty(t.plan) {
		plan_out(c, &t, false)
		txn_reset(&t)
		return kit.EXIT_OK
	}
	txn_confirm(&t)
	wait_for(c, &t, {.Done, .Failed})
	if t.stage == .Failed {
		plan_out(c, &t, false)
		return kit.cli_fail(c, kit.EXIT_FAILED, t.error)
	}
	plan_out(c, &t, true)
	txn_reset(&t)
	return kit.EXIT_OK
}

@(private = "file")
packages_of :: proc(c: ^kit.Call) -> []string {
	return kit.cli_rest(c)
}

@(private = "file")
cmd_plan :: proc(c: ^kit.Call) -> int {
	action := Action.Add
	switch kit.cli_str(c, "action") {
	case "del":
		action = .Del
	case "upgrade":
		action = .Upgrade
	}
	return change(c, action, packages_of(c), false)
}

@(private = "file")
cmd_install :: proc(c: ^kit.Call) -> int {
	return change(c, .Add, packages_of(c), !c.dry_run)
}

@(private = "file")
cmd_remove :: proc(c: ^kit.Call) -> int {
	return change(c, .Del, packages_of(c), !c.dry_run)
}

@(private = "file")
cmd_upgrade :: proc(c: ^kit.Call) -> int {
	return change(c, .Upgrade, nil, !c.dry_run)
}

@(private = "file")
cmd_update :: proc(c: ^kit.Call) -> int {
	if c.dry_run {
		kit.jset_bool(c.out, "ok", true)
		return kit.EXIT_OK
	}
	t: Txn
	txn_begin(&t, .Update, nil)
	wait_for(c, &t, {.Done, .Failed})
	if t.stage == .Failed {
		return kit.cli_fail(c, t.code == 6 ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED, t.error)
	}
	kit.jset_bool(c.out, "ok", true)
	_ = fmt.tprintf
	return kit.EXIT_OK
}
