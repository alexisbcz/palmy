package palm

// Dependency resolution: from the world file to an ordered set of packages.
//
// The world is the whole question. Every transaction -- add, del, upgrade --
// edits the world and then resolves it from scratch, and whatever is
// installed but not in the answer is removed. That is apk's model, and it is
// why `del` cleans up orphaned dependencies without a separate command: a
// dependency nobody in the world reaches is simply not in the answer.
//
// The resolver is a depth-first search with backtracking:
//
//   - Goals are constraints: the world's entries, then the dependencies of
//     each package chosen, in the order they appear.
//   - A goal already met by a chosen package (by name or by something it
//     provides) is met. Otherwise its candidates are tried in order of
//     preference: packages of that name, then packages that provide it.
//     Among those, an installed package wins (nothing moves unless asked),
//     except under `upgrade`, where the highest version wins and an
//     installed one only breaks ties.
//   - A candidate is refused if another version of its name is already
//     chosen, or if it and a chosen package conflict: either names the other
//     in `conflicts` or `replaces` (replacing a package implies not being
//     installed beside it).
//   - When no candidate works, the search goes back to the most recent
//     choice that has another candidate and tries that. So "world has foo,
//     installed foo is 1.0, bar needs foo>=2" settles on foo 2.0, and two
//     providers of the same thing are tried one after the other.
//   - When nothing works, the error reported is the deepest failure the
//     search met, naming the constraint, who wanted it and what stood in its
//     way: the most specific explanation there is. A step budget keeps a
//     pathological repository from searching forever.
//   - Under `upgrade`, an installed package that an available package
//     `replaces` (pacman's meaning: the project was renamed or merged) is
//     tried last, after its replacement, so the replacement takes over.
//
// The answer is put in install order afterwards: dependencies first, the
// world's own entries in the order given; a cycle is cut where it closes,
// and with no install scripts nothing depends on the order inside one.

import "core:fmt"
import "core:slice"

Universe :: struct {
	by_name:    map[string][dynamic]^Pkg,
	by_provide: map[string][dynamic]^Pkg,
	// Installed packages that an available package `replaces` (filled for
	// upgrade only): their name -> the replacement.
	replaced:   map[string]^Pkg,
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

// find_replacements fills u.replaced: for each installed package, the newest
// available package of another name whose `replaces` matches it.
find_replacements :: proc(u: ^Universe, db: ^DB) {
	for x in db.pkgs {
		best: ^Pkg
		for _, cands in u.by_name {
			for y in cands {
				if y.installed || y.name == x.name {continue}
				for rep in y.replaces {
					c, okc := parse_constraint(rep)
					if okc && pkg_satisfies(x, c) && (best == nil || version_compare(y.version, best.version) > 0) {
						best = y
					}
				}
			}
		}
		if best != nil {
			u.replaced[x.name] = best
		}
	}
}

Resolution :: struct {
	order:  [dynamic]^Pkg,
	chosen: map[string]^Pkg,
}

// RESOLVE_BUDGET bounds the search: every goal looked at counts one.
RESOLVE_BUDGET :: 200_000

@(private = "file")
Goal :: struct {
	c:  Constraint,
	by: string,
}

@(private = "file")
Resolver :: struct {
	u:         ^Universe,
	upgrade:   bool,
	chosen:    map[string]^Pkg,
	chosen_by: map[string]string,
	steps:     int,
	aborted:   bool,
	err:       Err,
	err_depth: int,
}

resolve :: proc(u: ^Universe, world: []string, upgrade: bool) -> (Resolution, Err) {
	r := Resolver {
		u         = u,
		upgrade   = upgrade,
		err_depth = -1,
	}
	goals := make([dynamic]Goal, context.temp_allocator)
	for w in world {
		c, okc := parse_constraint(w)
		if !okc {
			return {}, fail(EXIT_USAGE, "world entry %q is not a valid constraint", w)
		}
		append(&goals, Goal{c, "world"})
	}
	if !solve(&r, &goals, 0, 0) {
		if r.aborted {
			return {}, fail(EXIT_REFUSED, "dependency resolution gave up after %d steps: too many alternatives to search", RESOLVE_BUDGET)
		}
		if ok(r.err) {
			return {}, fail(EXIT_REFUSED, "dependency resolution failed")
		}
		return {}, r.err
	}

	// Install order: depth-first over dependencies within the chosen set.
	res: Resolution
	res.chosen = r.chosen
	state := make(map[string]bool, context.temp_allocator)
	visit :: proc(r: ^Resolver, res: ^Resolution, state: ^map[string]bool, p: ^Pkg) {
		if p.name in state {return}
		state[p.name] = true
		for d in p.depends {
			c, okc := parse_constraint(d)
			if !okc {continue}
			if q := chosen_meeting(r, c); q != nil {
				visit(r, res, state, q)
			}
		}
		append(&res.order, p)
	}
	for g in goals {
		if q := chosen_meeting(&r, g.c); q != nil {
			visit(&r, &res, &state, q)
		}
	}
	return res, Err{}
}

// chosen_meeting returns the chosen package that meets c, by name first.
@(private = "file")
chosen_meeting :: proc(r: ^Resolver, c: Constraint) -> ^Pkg {
	if p, has := r.chosen[c.name]; has && pkg_satisfies(p, c) {
		return p
	}
	if provs, has := r.u.by_provide[c.name]; has {
		for p in provs {
			if q, chosen := r.chosen[p.name]; chosen && q == p && pkg_satisfies(p, c) {
				return p
			}
		}
	}
	return nil
}

@(private = "file")
better :: proc(r: ^Resolver, a, b: ^Pkg) -> bool {
	// is a a better choice than b?
	if r.upgrade {
		ar := a.name in r.u.replaced
		br := b.name in r.u.replaced
		if ar != br {
			return br // a package being replaced is the last resort
		}
	}
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
sort_candidates :: proc(r: ^Resolver, s: []^Pkg) {
	// insertion sort: stable, and the lists are short
	for i in 1 ..< len(s) {
		for j := i; j > 0 && better(r, s[j], s[j - 1]); j -= 1 {
			s[j], s[j - 1] = s[j - 1], s[j]
		}
	}
}

@(private = "file")
candidates :: proc(r: ^Resolver, c: Constraint) -> []^Pkg {
	named := make([dynamic]^Pkg, context.temp_allocator)
	if cands, has := r.u.by_name[c.name]; has {
		for p in cands {
			if pkg_satisfies(p, c) {append(&named, p)}
		}
	}
	provs := make([dynamic]^Pkg, context.temp_allocator)
	if ps, has := r.u.by_provide[c.name]; has {
		for p in ps {
			if p.name != c.name && pkg_satisfies(p, c) {append(&provs, p)}
		}
	}
	sort_candidates(r, named[:])
	sort_candidates(r, provs[:])
	out := make([dynamic]^Pkg, context.temp_allocator)
	if r.upgrade {
		// The replacement of a replaced package is tried before it.
		for p in named {
			if rep, has := r.u.replaced[p.name]; has && pkg_satisfies(rep, c) && !slice.contains(out[:], rep) {
				append(&out, rep)
			}
		}
	}
	for p in named {if !slice.contains(out[:], p) {append(&out, p)}}
	for p in provs {if !slice.contains(out[:], p) {append(&out, p)}}
	return out[:]
}

// conflicts_with: does a's conflicts or replaces list name b?
conflicts_with :: proc(a, b: ^Pkg) -> (how: string, yes: bool) {
	if a.name == b.name {return "", false}
	for s in a.conflicts {
		c, okc := parse_constraint(s)
		if okc && pkg_satisfies(b, c) {return "conflicts with", true}
	}
	for s in a.replaces {
		c, okc := parse_constraint(s)
		if okc && pkg_satisfies(b, c) {return "replaces", true}
	}
	return "", false
}

// clash explains why p cannot join the chosen set, or returns "".
@(private = "file")
clash :: proc(r: ^Resolver, p: ^Pkg) -> string {
	if q, has := r.chosen[p.name]; has && q != p {
		return fmt.tprintf("%s is already required by %s", pkg_id(q), r.chosen_by[q.name])
	}
	for _, q in r.chosen {
		if q == p {continue}
		if how, yes := conflicts_with(p, q); yes {
			return fmt.tprintf("%s %s %s (required by %s)", pkg_id(p), how, pkg_id(q), r.chosen_by[q.name])
		}
		if how, yes := conflicts_with(q, p); yes {
			return fmt.tprintf("%s (required by %s) %s %s", pkg_id(q), r.chosen_by[q.name], how, pkg_id(p))
		}
	}
	return ""
}

@(private = "file")
note_failure :: proc(r: ^Resolver, depth: int, e: Err) {
	if depth > r.err_depth {
		r.err = e
		r.err_depth = depth
	}
}

@(private = "file")
solve :: proc(r: ^Resolver, goals: ^[dynamic]Goal, i: int, depth: int) -> bool {
	if i == len(goals) {
		return true
	}
	r.steps += 1
	if r.steps > RESOLVE_BUDGET {
		r.aborted = true
		return false
	}
	g := goals[i]
	if chosen_meeting(r, g.c) != nil {
		return solve(r, goals, i + 1, depth)
	}
	cands := candidates(r, g.c)
	if len(cands) == 0 {
		if q, has := r.chosen[g.c.name]; has {
			note_failure(r, depth, fail(EXIT_REFUSED, "conflict: %s wants %s, but %s is already required by %s", g.by, constraint_string(g.c), pkg_id(q), r.chosen_by[q.name]))
		} else if g.c.op != .Any && (g.c.name in r.u.by_name || g.c.name in r.u.by_provide) {
			note_failure(r, depth, fail(EXIT_NOT_FOUND, "no version of %s satisfies %s (wanted by %s)", g.c.name, constraint_string(g.c), g.by))
		} else {
			note_failure(r, depth, fail(EXIT_NOT_FOUND, "nothing provides %s (wanted by %s)", constraint_string(g.c), g.by))
		}
		return false
	}
	for p in cands {
		if why := clash(r, p); why != "" {
			note_failure(r, depth, fail(EXIT_REFUSED, "conflict: %s wants %s, but %s", g.by, constraint_string(g.c), why))
			continue
		}
		bad_dep := ""
		for d in p.depends {
			if _, okd := parse_constraint(d); !okd {bad_dep = d}
		}
		if bad_dep != "" {
			note_failure(r, depth, fail(EXIT_FAILED, "%s has an invalid dependency %q", pkg_id(p), bad_dep))
			continue
		}
		r.chosen[p.name] = p
		r.chosen_by[p.name] = g.by
		n := len(goals)
		for d in p.depends {
			dc, _ := parse_constraint(d)
			append(goals, Goal{dc, p.name})
		}
		if solve(r, goals, i + 1, depth + 1) {
			return true
		}
		resize(goals, n)
		delete_key(&r.chosen, p.name)
		delete_key(&r.chosen_by, p.name)
		if r.aborted {
			return false
		}
	}
	return false
}
