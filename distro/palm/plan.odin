package palm

// The plan: a resolution compared with what is installed, and how it is
// shown before anything happens.

import "core:fmt"
import "core:strings"

Change :: struct {
	old: ^Pkg, // nil for a new install
	new: ^Pkg,
}

Plan :: struct {
	changes:  [dynamic]Change, // install order
	remove:   [dynamic]^Pkg,
	// For display: removed packages that a new one replaces (name -> by).
	replaced: map[string]string,
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
	for x in plan.remove {
		for c in plan.changes {
			if how, yes := conflicts_with(c.new, x); yes && how == "replaces" {
				plan.replaced[x.name] = c.new.name
			}
		}
	}
	return plan
}

plan_empty :: proc(plan: Plan) -> bool {
	return len(plan.changes) == 0 && len(plan.remove) == 0
}

Plan_Totals :: struct {
	installs, upgrades, downgrades, reinstalls, removes: int,
	download, growth:                                    i64,
}

plan_totals :: proc(plan: Plan) -> (t: Plan_Totals) {
	for c in plan.changes {
		t.download += c.new.csize
		if c.old == nil {
			t.installs += 1
			t.growth += c.new.size
			continue
		}
		t.growth += c.new.size - c.old.size
		switch v := version_compare(c.new.version, c.old.version); {
		case v > 0:
			t.upgrades += 1
		case v < 0:
			t.downgrades += 1
		case:
			t.reinstalls += 1
		}
	}
	for p in plan.remove {
		t.removes += 1
		t.growth -= p.size
	}
	return
}

// plan_summary is one line: "upgrade 3, install 1, remove 1".
plan_summary :: proc(t: Plan_Totals, past := false) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	add :: proc(parts: ^[dynamic]string, n: int, verb, done: string, past: bool) {
		if n > 0 {append(parts, fmt.tprintf("%s %d", past ? done : verb, n))}
	}
	add(&parts, t.upgrades, "upgrade", "upgraded", past)
	add(&parts, t.installs, "install", "installed", past)
	add(&parts, t.downgrades, "downgrade", "downgraded", past)
	add(&parts, t.reinstalls, "reinstall", "reinstalled", past)
	add(&parts, t.removes, "remove", "removed", past)
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private = "file")
signed_size :: proc(n: i64) -> string {
	if n < 0 {
		return fmt.tprintf("-%s", human_size(-n))
	}
	return fmt.tprintf("+%s", human_size(n))
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
		if by, has := plan.replaced[p.name]; has {
			say("  remove    %s %s (replaced by %s)", p.name, p.version, by)
		} else {
			say("  remove    %s %s", p.name, p.version)
		}
	}
	if !plan_empty(plan) {
		t := plan_totals(plan)
		say("%s; download %s, disk %s", plan_summary(t), human_size(t.download), signed_size(t.growth))
	}
}

plan_json :: proc(plan: Plan, dry_run: bool) -> string {
	// Sizes ride along so a front end can say "download 4.2 MB, uses 11 MB"
	// before anything happens: csize is what fetching costs (the .palm),
	// size what the files take once unpacked.
	t := plan_totals(plan)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"install\":[")
	n := 0
	for c in plan.changes {
		if c.old != nil {continue}
		if n > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"version\":%s,\"size\":%d,\"csize\":%d}}", json_str(c.new.name), json_str(c.new.version), c.new.size, c.new.csize)
		n += 1
	}
	strings.write_string(&b, "],\"upgrade\":[")
	n = 0
	for c in plan.changes {
		if c.old == nil {continue}
		if n > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"from\":%s,\"to\":%s,\"size\":%d,\"csize\":%d}}", json_str(c.new.name), json_str(c.old.version), json_str(c.new.version), c.new.size, c.new.csize)
		n += 1
	}
	strings.write_string(&b, "],\"remove\":[")
	for p, i in plan.remove {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":%s,\"version\":%s,\"size\":%d", json_str(p.name), json_str(p.version), p.size)
		if by, has := plan.replaced[p.name]; has {
			fmt.sbprintf(&b, ",\"replaced_by\":%s", json_str(by))
		}
		strings.write_byte(&b, '}')
	}
	fmt.sbprintf(&b, "],\"download_size\":%d,\"size_change\":%d,\"dry_run\":%v}}", t.download, t.growth, dry_run)
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
