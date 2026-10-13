package palm

// Dependency resolution: from the world file to an ordered set of packages.
//
// The world is the whole question. Every transaction -- add, del, upgrade --
// edits the world and then resolves it from scratch, and whatever is
// installed but not in the answer is removed. That is apk's model, and it is
// why `del` cleans up orphaned dependencies without a separate command: a
// dependency nobody in the world reaches is simply not in the answer.
//
// The resolver is greedy, with one repair:
//
//   - Each constraint is met by a package of that name if one satisfies it,
//     else by something that provides it.
//   - Among candidates, an installed package that satisfies wins (nothing
//     moves unless asked), except under `upgrade`, where the highest version
//     wins and an installed one only breaks ties.
//   - A package's dependencies are resolved before it is appended, so the
//     resulting order is install order: dependencies first. A cycle is cut
//     where it closes; with no install scripts, nothing depends on the order
//     inside a cycle.
//   - If a later constraint conflicts with an earlier choice (world has foo,
//     installed foo is 1.0, bar needs foo>=2), the constraint is pinned onto
//     that package name and resolution restarts, so the second pass chooses a
//     foo that satisfies both. A conflict that pinning cannot fix is reported
//     with both sides named.

import "core:fmt"
import "core:strings"

Universe :: struct {
	by_name:    map[string][dynamic]^Pkg,
	by_provide: map[string][dynamic]^Pkg,
}

universe_add :: proc(u: ^Universe, p: ^Pkg) {
	if p.name not_in u.by_name {
		u.by_name[p.name] = make([dynamic]^Pkg)
	}
	append(&u.by_name[p.name], p)
	for pr in p.provides {
		n, _ := provides_entry(pr)
		if n not_in u.by_provide {
			u.by_provide[n] = make([dynamic]^Pkg)
		}
		append(&u.by_provide[n], p)
	}
}

build_universe :: proc(db: ^DB, repos: []^Repo) -> ^Universe {
	u := new(Universe)
	for p in db.pkgs {
		universe_add(u, p)
	}
	for r in repos {
		for &p in r.pkgs {
			universe_add(u, &p)
		}
	}
	return u
}

Resolution :: struct {
	order:  [dynamic]^Pkg,
	chosen: map[string]^Pkg,
}

@(private = "file")
Resolver :: struct {
	u:       ^Universe,
	upgrade: bool,
	pins:    map[string][dynamic]Constraint,
	res:     Resolution,
	// set when a conflict can be repaired by a pin and a restart
	retry:   bool,
}

resolve :: proc(u: ^Universe, world: []string, upgrade: bool) -> (Resolution, Err) {
	r := Resolver {
		u       = u,
		upgrade = upgrade,
	}
	for attempt := 0; attempt < 64; attempt += 1 {
		r.res = Resolution{}
		r.retry = false
		failed := Err{}
		for w in world {
			c, okc := parse_constraint(w)
			if !okc {
				return {}, fail(EXIT_USAGE, "world entry %q is not a valid constraint", w)
			}
			if _, e := resolve_one(&r, c, "world"); !ok(e) {
				failed = e
				break
			}
		}
		if ok(failed) {
			return r.res, Err{}
		}
		if !r.retry {
			return {}, failed
		}
	}
	return {}, fail(EXIT_REFUSED, "dependency resolution did not settle")
}

@(private = "file")
pinned_ok :: proc(r: ^Resolver, p: ^Pkg) -> bool {
	if pins, has := r.pins[p.name]; has {
		for c in pins {
			if !pkg_satisfies(p, c) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
better :: proc(r: ^Resolver, a, b: ^Pkg) -> bool {
	// is a a better choice than b?
	if !r.upgrade && a.installed != b.installed {
		return a.installed
	}
	if c := version_compare(a.version, b.version); c != 0 {
		return c > 0
	}
	if a.installed != b.installed {
		return a.installed
	}
	return false // keep the first, which is repository order
}

@(private = "file")
resolve_one :: proc(r: ^Resolver, c: Constraint, wanted_by: string) -> (^Pkg, Err) {
	// Already met by an earlier choice?
	if p, has := r.res.chosen[c.name]; has && pkg_satisfies(p, c) {
		return p, Err{}
	}
	if provs, has := r.u.by_provide[c.name]; has {
		for p in provs {
			if q, chosen := r.res.chosen[p.name]; chosen && q == p && pkg_satisfies(p, c) {
				return p, Err{}
			}
		}
	}

	best: ^Pkg
	consider :: proc(r: ^Resolver, best: ^^Pkg, p: ^Pkg, c: Constraint) {
		if !pkg_satisfies(p, c) || !pinned_ok(r, p) {
			return
		}
		if q, chosen := r.res.chosen[p.name]; chosen && q.version != p.version {
			return
		}
		if best^ == nil || better(r, p, best^) {
			best^ = p
		}
	}
	if cands, has := r.u.by_name[c.name]; has {
		for p in cands {
			consider(r, &best, p, c)
		}
	}
	if best == nil {
		if provs, has := r.u.by_provide[c.name]; has {
			for p in provs {
				consider(r, &best, p, c)
			}
		}
	}
	if best == nil {
		// Is it a conflict with an earlier choice that a pin can repair?
		if q, chosen := r.res.chosen[c.name]; chosen {
			if !pin_has(r, c.name, c) && any_candidate(r, c) {
				append_pin(r, c.name, c)
				r.retry = true
			}
			return nil, fail(
				EXIT_REFUSED,
				"conflict: %s wants %s, but %s is already required",
				wanted_by,
				constraint_string(c),
				pkg_id(q),
			)
		}
		if c.op != .Any && (c.name in r.u.by_name || c.name in r.u.by_provide) {
			return nil, fail(EXIT_NOT_FOUND, "no version of %s satisfies %s (wanted by %s)", c.name, constraint_string(c), wanted_by)
		}
		return nil, fail(EXIT_NOT_FOUND, "nothing provides %s (wanted by %s)", constraint_string(c), wanted_by)
	}

	r.res.chosen[best.name] = best
	for d in best.depends {
		dc, okd := parse_constraint(d)
		if !okd {
			return nil, fail(EXIT_FAILED, "%s has an invalid dependency %q", pkg_id(best), d)
		}
		if _, e := resolve_one(r, dc, best.name); !ok(e) {
			return nil, e
		}
	}
	append(&r.res.order, best)
	return best, Err{}
}

@(private = "file")
pin_has :: proc(r: ^Resolver, name: string, c: Constraint) -> bool {
	if pins, has := r.pins[name]; has {
		for p in pins {
			if p == c {
				return true
			}
		}
	}
	return false
}

@(private = "file")
append_pin :: proc(r: ^Resolver, name: string, c: Constraint) {
	if name not_in r.pins {
		r.pins[name] = make([dynamic]Constraint)
	}
	append(&r.pins[name], c)
}

@(private = "file")
any_candidate :: proc(r: ^Resolver, c: Constraint) -> bool {
	if cands, has := r.u.by_name[c.name]; has {
		for p in cands {
			if pkg_satisfies(p, c) && pinned_ok(r, p) {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The plan: a resolution compared with what is installed
// ---------------------------------------------------------------------------

Change :: struct {
	old: ^Pkg, // nil for a new install
	new: ^Pkg,
}

Plan :: struct {
	changes: [dynamic]Change, // install order
	remove:  [dynamic]^Pkg,
}

make_plan :: proc(db: ^DB, res: Resolution) -> Plan {
	plan: Plan
	for p in res.order {
		old := db_find(db, p.name)
		if old == p {
			continue
		}
		if old != nil && old.version == p.version && old.sha256 == p.sha256 {
			continue
		}
		append(&plan.changes, Change{old, p})
	}
	for p in db.pkgs {
		if _, keep := res.chosen[p.name]; !keep {
			append(&plan.remove, p)
		}
	}
	return plan
}

plan_empty :: proc(plan: Plan) -> bool {
	return len(plan.changes) == 0 && len(plan.remove) == 0
}

plan_print :: proc(plan: Plan) {
	for c in plan.changes {
		if c.old == nil {
			say("  install   %s %s", c.new.name, c.new.version)
		} else {
			verb := version_compare(c.new.version, c.old.version) < 0 ? "downgrade" : (c.new.version == c.old.version ? "reinstall" : "upgrade")
			say("  %-10s%s %s -> %s", verb, c.new.name, c.old.version, c.new.version)
		}
	}
	for p in plan.remove {
		say("  remove    %s %s", p.name, p.version)
	}
}

plan_json :: proc(plan: Plan, dry_run: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"install\":[")
	n := 0
	for c in plan.changes {
		if c.old != nil {continue}
		if n > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"version\":%s}}", json_str(c.new.name), json_str(c.new.version))
		n += 1
	}
	strings.write_string(&b, "],\"upgrade\":[")
	n = 0
	for c in plan.changes {
		if c.old == nil {continue}
		if n > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"from\":%s,\"to\":%s}}", json_str(c.new.name), json_str(c.old.version), json_str(c.new.version))
		n += 1
	}
	strings.write_string(&b, "],\"remove\":[")
	for p, i in plan.remove {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"version\":%s}}", json_str(p.name), json_str(p.version))
	}
	fmt.sbprintf(&b, "],\"dry_run\":%v}}", dry_run)
	return strings.to_string(b)
}

json_str :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\t':
			strings.write_string(&b, "\\t")
		case '\r':
			strings.write_string(&b, "\\r")
		case:
			if c < 0x20 {
				fmt.sbprintf(&b, "\\u%04x", c)
			} else {
				strings.write_byte(&b, c)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
