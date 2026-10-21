package main

// `pkg --selftest` -- headless, and it never touches this machine.
//
// The honest test of a package layer modifies a real system, so this one does
// not try. It proves the parts that decide what *would* be run:
//
//   * the declaration parser, including the name validation that stops a
//     declaration file from smuggling a flag into an argv,
//   * the pacman output parsers, against truncated and malformed text,
//   * the diff between declared and installed,
//   * the refusal rules, each one on its own,
//   * and the thing docs/PACKAGES.md cares most about: THE EXACT ARGV.
//
// The last three sections are the ones worth reading. They put a scratch
// directory at the front of PATH holding fake `pacman`, `yay`, `snapper` and
// `sudo`. The fakes never reach the real tools: they append their arguments to
// one of two files -- queries for read-only calls, and a sentinel named
// `fired` for anything that would change the machine -- and exit.
//
//   1. The trap is sprung deliberately first. If PATH interception does not
//      work on this build, the negative assertions below would pass by
//      accident and prove nothing, so the test fails loudly instead.
//   2. Every verb is then driven the way an agent would drive it, by argv,
//      and `fired` is asserted empty afterwards. Nothing an agent can type
//      without --yes changes anything.
//   3. Finally, with --yes, the mutating verbs are driven on purpose and
//      `fired` is asserted to hold EXACTLY the argv the planner said it would
//      -- snapshot first, then pacman. That is the step that proves the plan
//      is what reaches exec, rather than the plan being a pretty printout
//      next to some other command.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import kit "kit:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", fmt.tprintf(what, ..args), got, want)
	}
}

// eq_argv is the assertion this program exists for.
@(private = "file")
eq_argv :: proc(got: []string, want: []string, what: string, args: ..any) {
	checks += 1
	same := len(got) == len(want)
	if same {
		for i in 0 ..< len(got) {
			if got[i] != want[i] {
				same = false
				break
			}
		}
	}
	if !same {
		failures += 1
		fmt.printf(
			"  FAIL  %s\n        got  %v\n        want %v\n",
			fmt.tprintf(what, ..args),
			got,
			want,
		)
	}
}

// step_argv is indexing that reports instead of crashing. A deliberately
// broken build was the first thing to need it: when the planner refused a
// plan the test expected, the next assertion indexed step 1 of an empty plan
// and took the whole run down with it, hiding every failure after it.
@(private = "file")
step_argv :: proc(p: ^Plan, i: int) -> []string {
	if i < 0 || i >= len(p.steps) {
		return nil
	}
	return p.steps[i].argv
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

@(private = "file")
g_root: string

@(private = "file")
scratch_root :: proc() -> string {
	if g_root == "" {
		g_root = fmt.aprintf("/tmp/palmy-pkg-selftest-%d", os.get_pid())
		_ = os.make_directory_all(g_root)
	}
	return g_root
}

@(private = "file")
put :: proc(path, text: string, perm := os.Permissions_Read_All + {.Write_User}) {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
	if err := os.write_entire_file(path, transmute([]u8)text, perm); err != nil {
		fmt.printf("  FAIL  could not write the fixture %s\n", path)
		failures += 1
	}
}

@(private = "file")
read_lines :: proc(path: string) -> []string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	out := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(l)
		if t != "" {
			append(&out, t)
		}
	}
	return out[:]
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("pkg self-test")

	// Every non-read command the kit runs leaves an audit record. The
	// self-test drives dozens, and none of them belongs in the real log.
	_ = os.set_env("PALM_AUDIT", fmt.tprintf("%s/audit.jsonl", scratch_root()))

	test_names()
	test_decl_parse()
	test_decl_edit()
	test_parsers()
	test_partial_upgrade()
	test_plan_check()
	test_protected()
	test_dependants()
	test_argv()
	test_diff_and_sync()
	test_upgrade_and_rollback()
	test_noconfirm()
	test_scope()
	test_surface()
	test_nothing_executes()
	test_argv_that_runs()
	test_convention()

	if g_root != "" {
		_ = os.remove_all(g_root)
	}

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// Package names: the first fence
// ---------------------------------------------------------------------------

test_names :: proc() {
	section("package names")

	for good in ([?]string{"git", "ripgrep", "linux-lts", "gcc-libs", "lib32-glibc", "python3.12", "g++", "foo_bar", "a"}) {
		check(pkg_name_ok(good), "%q is a usable package name", good)
	}
	// Each of these is a way a declaration file could put something other than
	// a package into an argv.
	for bad in ([?]string{"-Sy", "--noconfirm", "", "../../etc/passwd", "foo bar", "foo;rm -rf /", "$(id)", "foo/bar", ".hidden", "foo\nbar", "`id`", "foo|bar"}) {
		check(!pkg_name_ok(bad), "%q is refused as a package name", bad)
	}
	long := strings.repeat("a", 300, context.temp_allocator)
	check(!pkg_name_ok(long), "a 300-character name is refused")
}

// ---------------------------------------------------------------------------
// The declaration
// ---------------------------------------------------------------------------

SAMPLE_DECL :: `# the work machine
identity work

[base]
git
ripgrep        # trailing comments are fine
repo fd

[work]
aur visual-studio-code-bin
docker
`

test_decl_parse :: proc() {
	section("the declaration parses")

	d := decl_parse(SAMPLE_DECL)
	eq_s(d.identity, "work", "the identity header")
	eq_i(len(d.problems), 0, "a clean file has no problems")
	eq_i(len(d.entries), 5, "five packages")
	eq_i(len(d.profiles), 2, "two profiles")
	check(decl_has_profile(&d, "base"), "the base profile is seen")
	check(decl_has_profile(&d, "work"), "the work profile is seen")

	names, sources := decl_wanted(&d, nil)
	eq_i(len(names), 5, "all profiles are wanted by default")
	eq_s(names[0], "docker", "wanted names come back sorted")
	check(sources["visual-studio-code-bin"] == .Aur, "the aur directive is carried")
	check(sources["fd"] == .Repo, "repo is the default source")

	only_base, _ := decl_wanted(&d, {"base"})
	eq_i(len(only_base), 3, "--profile base narrows to three")
	check(!slice.contains(only_base, "docker"), "docker is not in base")

	// Packages before any profile header land in `base`.
	d2 := decl_parse("git\nripgrep\n")
	eq_i(len(d2.entries), 2, "packages before a header still parse")
	eq_s(d2.entries[0].profile, DEFAULT_PROFILE, "they land in the default profile")

	// Every one of these is a problem, not a silently accepted line.
	bad := decl_parse(
		"[base]\n-Sy\n--noconfirm\ngit\ngit\n[bad profile]\nwhat is this\nidentity late\n[ok]\naur\n",
	)
	check(len(bad.problems) >= 6, "a hostile file produces a problem per line (%d)", len(bad.problems))
	for e in bad.entries {
		check(pkg_name_ok(e.name), "no entry survives parsing with an unusable name (%q)", e.name)
	}
	found_dup := false
	found_flag := false
	for p in bad.problems {
		if strings.contains(p.text, "declared twice") {
			found_dup = true
		}
		if strings.contains(p.text, "-Sy") {
			found_flag = true
		}
	}
	check(found_dup, "a duplicate declaration is reported")
	check(found_flag, "a line reading `-Sy` is reported as not a package name")

	empty := decl_parse("")
	eq_i(len(empty.entries), 0, "an empty declaration is empty, not an error")
	eq_i(len(empty.problems), 0, "and has no problems")

	comments := decl_parse("# only\n\n   \n# comments\n")
	eq_i(len(comments.entries), 0, "a file of comments declares nothing")
}

test_decl_edit :: proc() {
	section("declare and undeclare rewrite the file")

	text, added := decl_add(SAMPLE_DECL, {"htop", "git"}, "base", .Repo)
	eq_i(len(added), 1, "git is already in base, so only htop is added")
	eq_s(added[0], "htop", "and it is htop")
	d := decl_parse(text)
	eq_i(len(d.problems), 0, "the rewritten file still parses")
	eq_i(len(d.entries), 6, "one more entry")
	in_base := false
	for e in d.entries {
		if e.name == "htop" {
			in_base = e.profile == "base"
		}
	}
	check(in_base, "htop landed in base, not at the end of the file")
	check(strings.contains(text, "# the work machine"), "comments survive the rewrite")
	check(strings.contains(text, "aur visual-studio-code-bin"), "the other profile survives")

	// A profile that does not exist yet gets a header.
	t2, a2 := decl_add(SAMPLE_DECL, {"blender"}, "media", .Aur)
	eq_i(len(a2), 1, "one addition to a new profile")
	d2 := decl_parse(t2)
	check(decl_has_profile(&d2, "media"), "the new profile header was written")
	srcs: Source
	for e in d2.entries {
		if e.name == "blender" {
			srcs = e.source
		}
	}
	check(srcs == .Aur, "and it kept its aur source")

	t3, a3 := decl_add("", {"git"}, "base", .Repo)
	eq_i(len(a3), 1, "declaring into an empty file works")
	d3 := decl_parse(t3)
	eq_i(len(d3.entries), 1, "and produces one entry")

	t4, r4 := decl_remove(SAMPLE_DECL, {"fd", "visual-studio-code-bin", "never-declared"})
	eq_i(len(r4), 2, "two of the three named were actually declared")
	d4 := decl_parse(t4)
	eq_i(len(d4.entries), 3, "three entries remain")
	check(!strings.contains(t4, "visual-studio-code-bin"), "the aur line is gone")
	check(strings.contains(t4, "[work]"), "but its profile header stays")
}

// ---------------------------------------------------------------------------
// Reading pacman
// ---------------------------------------------------------------------------

QI_SAMPLE :: `Name            : libfoo
Version         : 1.2.3-1
Description     : A library
Depends On      : glibc
Required By     : foo-app  bar-app
Optional For    : None
Install Reason  : Installed as a dependency for another package

Name            : orphanpkg
Version         : 0.1-1
Description     : Nothing needs this
Required By     : None
Install Reason  : Explicitly installed
`

test_parsers :: proc() {
	section("reading pacman")

	names := parse_name_list("git\nripgrep\n\nbash\n")
	eq_i(len(names), 3, "a -Qq list parses")
	eq_s(names[2], "bash", "in order")

	// `pacman -Q` without -q is "name version".
	v := parse_name_list("git 2.4.5-1\nbash 5.3-1\n")
	eq_i(len(v), 2, "a -Q list parses")
	eq_s(v[0], "git", "and the version is dropped")

	// A truncated read must not put junk into a later argv.
	junk := parse_name_list("git\n-Sy\n../etc\nok-name\n")
	eq_i(len(junk), 2, "unusable names are dropped from a package list")
	eq_s(junk[1], "ok-name", "the usable ones survive")

	infos := parse_qi(QI_SAMPLE)
	eq_i(len(infos), 2, "two -Qi blocks")
	eq_s(infos[0].name, "libfoo", "the first name")
	eq_s(infos[0].version, "1.2.3-1", "the version")
	eq_i(len(infos[0].required_by), 2, "two dependants")
	eq_s(infos[0].required_by[1], "bar-app", "the second dependant")
	eq_i(len(infos[0].optional_for), 0, "`None` is no dependants, not one named None")
	eq_i(len(infos[1].required_by), 0, "orphanpkg has none")
	eq_s(infos[1].reason, "Explicitly installed", "the install reason")

	// Truncated mid-block: the block still yields what it had.
	trunc := parse_qi("Name            : libfoo\nVersion         : 1.2.3-1\nRequired By     : foo-app")
	eq_i(len(trunc), 1, "a truncated -Qi still yields the block")
	eq_i(len(trunc[0].required_by), 1, "with the dependants it managed to print")

	eq_i(len(parse_qi("")), 0, "empty -Qi output is no packages")
	eq_i(len(parse_qi("error: package 'nope' was not found\n")), 0, "an error message is not a package")

	hits := parse_search(
		"extra/ripgrep 14.1.1-1 [installed]\n    A search tool\ncore/git 2.4.5-1\n    The fast distributed VCS\n",
	)
	eq_i(len(hits), 2, "two search hits")
	eq_s(hits[0].name, "ripgrep", "the name")
	eq_s(hits[0].repo, "extra", "the repo")
	check(hits[0].installed, "the [installed] marker is read")
	check(!hits[1].installed, "and absent when it is absent")
	eq_s(hits[1].description, "The fast distributed VCS", "the indented description")

	snaps := parse_snapper_list(
		" # | Type   | Pre # | Date                     | User | Cleanup | Description          | Userdata\n---+--------+-------+--------------------------+------+---------+----------------------+---------\n0  | single |       |                          | root |         | current              |\n42 | single |       | Sun 05 Oct 2026 10:00:00 | root | number  | palm pkg install git |\n",
	)
	eq_i(len(snaps), 2, "two snapshots (the header row is not one)")
	eq_i(snaps[1].number, 42, "the number")
	eq_s(snaps[1].description, "palm pkg install git", "the description names the operation")
	check(snaps[1].from_palm, "and is recognised as palm's")
	check(!snaps[0].from_palm, "a snapshot palm did not take is not claimed")

	// snapper marks the default and the active snapshot in the number column.
	// The parser used to drop a marked row whole.
	marked := parse_snapper_list(
		" # | Type   | Pre # | Date | User | Cleanup | Description | Userdata\n---+--------+-------+------+------+---------+-------------+---------\n0  | single |       |      | root |         | current     |\n1* | single |       | now  | root |         | first root filesystem |\n5+ | single |       | now  | root | number  | writable copy of #3 |\n6- | single |       | now  | root | number  | palm pkg install git |\n",
	)
	eq_i(len(marked), 4, "rows marked +, - and * are snapshots too")
	if len(marked) == 4 {
		eq_i(marked[1].number, 1, "a `*` is read off the number")
		check(marked[1].is_default && marked[1].is_active, "and means default and active")
		check(marked[2].is_default && !marked[2].is_active, "`+` is the default subvolume only")
		check(!marked[3].is_default && marked[3].is_active, "`-` is the mounted one only")
		eq_s(marked[3].description, "palm pkg install git", "and a marked row keeps its description")
		check(marked[3].from_palm, "and is still recognised as palm's")
	}
	check(rollback_layout_ok(marked), "a default subvolume that is a snapshot is a layout snapper can roll back")
	check(!rollback_layout_ok(snaps), "and none marked default is not")
}

// ---------------------------------------------------------------------------
// Never a -Sy without a -u
// ---------------------------------------------------------------------------

test_partial_upgrade :: proc() {
	section("a refresh without an upgrade is detected")

	// Spring the trap first. If these do not come back true, every negative
	// assertion after them is worthless.
	for bad in ([?][]string {
		{"pacman", "-Sy"},
		{"pacman", "-Sy", "git"},
		{"sudo", "pacman", "-Syw", "git"},
		{"sudo", "pacman", "-Syy", "--needed", "--", "git"},
		{"yay", "-Sy", "--", "foo"},
		{"sudo", "pacman", "-S", "--refresh", "--", "git"},
		{"sudo", "pacman", "-S", "-y", "--", "git"},
	}) {
		check(
			argv_is_partial_upgrade(bad),
			"%s is caught as a partial upgrade",
			strings.join(bad, " ", context.temp_allocator),
		)
	}

	for ok in ([?][]string {
		{"sudo", "pacman", "-Syu"},
		{"sudo", "pacman", "-Syyuu"},
		{"sudo", "pacman", "-S", "--refresh", "--sysupgrade"},
		{"sudo", "pacman", "-S", "--needed", "--", "git"},
		{"sudo", "pacman", "-R", "--", "git"},
		{"yay", "-Syu"},
		{"sudo", "snapper", "--config", "root", "create"},
		// A package legitimately named with a y is not an operation.
		{"sudo", "pacman", "-S", "--needed", "--", "yay"},
		{"sudo", "pacman", "-S", "--needed", "--", "-Sy-not-a-flag-here"},
	}) {
		check(
			!argv_is_partial_upgrade(ok),
			"%s is not a partial upgrade",
			strings.join(ok, " ", context.temp_allocator),
		)
	}
}

test_plan_check :: proc() {
	section("plan_check refuses a plan no verb should have built")

	// Each of these is a hand-built plan that a future verb could produce by
	// accident. Springing them here is what makes plan_check worth having.
	bad_plans := [?]struct {
		name:   string,
		step:   Step,
		reason: string,
	} {
		{
			"a refresh without an upgrade",
			Step{what = "install", argv = {"sudo", "pacman", "-Sy", "--", "git"}, needs_root = true},
			"partial-upgrade",
		},
		{
			"a program that is not one of the four",
			Step{what = "install", argv = {"rm", "-rf", "--", "git"}, needs_root = false},
			"invariant",
		},
		{
			"a root change that does not go through sudo",
			Step{what = "install", argv = {"pacman", "-S", "--needed", "--", "git"}, needs_root = true},
			"invariant",
		},
		{
			"an operand list with no -- fence",
			Step{what = "install", argv = {"sudo", "pacman", "-S", "--needed", "git"}, needs_root = true},
			"invariant",
		},
		{
			"an empty fence",
			Step{what = "remove", argv = {"sudo", "pacman", "-R", "--"}, needs_root = true},
			"invariant",
		},
		{
			"a flag smuggled in as an operand",
			Step {
				what = "remove",
				argv = {"sudo", "pacman", "-R", "--", "--noconfirm"},
				needs_root = true,
			},
			"invariant",
		},
		{"an empty argv", Step{what = "install", argv = {}, needs_root = false}, "invariant"},
	}

	for bp in bad_plans {
		steps := []Step{bp.step}
		p := Plan {
			op    = "test",
			steps = steps,
		}
		reason, detail := plan_check(&p)
		eq_s(reason, bp.reason, "plan_check catches %s", bp.name)
		check(detail != "", "and says why (%s)", bp.name)

		// And the public door, plan_finish, turns it into a refusal rather
		// than handing the plan back.
		_, ref := plan_finish(p)
		check(ref.refused, "plan_finish refuses %s", bp.name)
		eq_i(ref.code, EXIT_FAILED, "with exit 7 (%s)", bp.name)
	}

	// A good plan passes.
	good := Plan {
		op = "install",
		steps = []Step {
			snapshot_step("install", {"git"}, context.temp_allocator),
			Step{what = "install", argv = {"sudo", "pacman", "-S", "--needed", "--", "git"}, needs_root = true},
		},
	}
	reason, _ := plan_check(&good)
	eq_s(reason, "", "a well-formed plan passes plan_check")
}

// ---------------------------------------------------------------------------
// The protected classes, each on its own
// ---------------------------------------------------------------------------

// These live at file scope on purpose. A slice of a compound literal inside
// canned_world would point at storage that goes away when it returns, and the
// first version of this test did exactly that: the dependants refusal came
// back with an empty detail and three assertions failed in a way that looked
// like a planner bug.
@(private = "file")
LIBFOO_DEPS := [?]string{"foo-app", "bar-app"}
@(private = "file")
SYSTEMD_DEPS := [?]string{"bash"}
@(private = "file")
FOO_APP_ONLY := [?]string{"foo-app"}

@(private = "file")
canned_world :: proc() -> World {
	w := world_make(context.temp_allocator)
	for n in ([?]string {
		"bash",
		"systemd",
		"linux",
		"linux-firmware",
		"limine",
		"sddm",
		"pacman",
		"git",
		"libfoo",
		"foo-app",
		"orphanpkg",
	}) {
		w.installed[n] = true
	}
	for n in ([?]string{"git", "foo-app", "orphanpkg", "linux", "limine", "sddm", "systemd"}) {
		w.explicit[n] = true
	}
	w.required_by["libfoo"] = LIBFOO_DEPS[:]
	w.required_by["foo-app"] = nil
	w.required_by["orphanpkg"] = nil
	w.required_by["git"] = nil
	w.required_by["linux"] = nil
	w.required_by["limine"] = nil
	w.required_by["sddm"] = nil
	w.required_by["systemd"] = SYSTEMD_DEPS[:]
	for n in ([?]string{"git", "ripgrep", "fd", "hello", "libfoo", "foo-app"}) {
		w.in_repo[n] = true
		w.repo_checked[n] = true
	}
	w.repo_checked["only-in-the-aur"] = true
	w.in_repo["only-in-the-aur"] = false
	w.loaded = true
	return w
}

test_protected :: proc() {
	section("the bootloader, the kernel, the display manager and init are each refused separately")

	// Classification first, so the refusals below are about the rule and not
	// about a lookup table being empty.
	for pair in ([?]struct {
		name:  string,
		guard: Guard,
	} {
		{"linux", .Kernel},
		{"linux-lts", .Kernel},
		{"linux-zen", .Kernel},
		{"linux-firmware", .Kernel},
		// The kernel this machine actually runs, which is not called `linux`.
		// A hard-coded list of kernel names would have missed it; the prefix
		// rule does not.
		{"linux-omarchy", .Kernel},
		{"linux-omarchy-headers", .Kernel},
		// Over-refused on purpose: a toolchain header set, not a kernel.
		{"linux-api-headers", .Kernel},
		{"linux-headers", .Kernel},
		{"amd-ucode", .Kernel},
		{"limine", .Bootloader},
		{"limine-snapper-sync", .Bootloader},
		{"grub", .Bootloader},
		{"efibootmgr", .Bootloader},
		{"mkinitcpio", .Bootloader},
		{"sddm", .Display_Manager},
		{"gdm", .Display_Manager},
		{"greetd", .Display_Manager},
		{"uwsm", .Display_Manager},
		{"systemd", .Init},
		{"systemd-libs", .Init},
		{"dbus-broker", .Init},
		{"pacman", .Core},
		{"glibc", .Core},
		{"sudo", .Core},
		{"snapper", .Core},
		{"git", .None},
		{"ripgrep", .None},
		{"linuxlogo", .None},
	}) {
		got := guard_of(pair.name)
		check(
			got == pair.guard,
			"%s is classified %q, want %q",
			pair.name,
			guard_name(got),
			guard_name(pair.guard),
		)
	}

	w := canned_world()

	// Four separate refusals, each naming its own class, each with --yes
	// already given -- so this is not the --yes rule in disguise.
	for pair in ([?]struct {
		name:   string,
		reason: string,
	} {
		{"linux", "protected:kernel"},
		{"limine", "protected:bootloader"},
		{"sddm", "protected:display-manager"},
		{"systemd", "protected:init"},
		{"pacman", "protected:core"},
	}) {
		_, ref := plan_remove(&w, {pair.name}, Remove_Opts{yes = true, snapshot = true})
		check(ref.refused, "removing %s is refused even with --yes", pair.name)
		eq_s(ref.reason, pair.reason, "removing %s names its own class", pair.name)
		eq_i(ref.code, EXIT_NEEDS_YES, "removing %s exits 4", pair.name)
		check(len(ref.subjects) == 1 && ref.subjects[0] == pair.name, "and names the package")
		check(
			strings.contains(ref.detail, "--allow-protected"),
			"and says what would be needed (%s)",
			pair.name,
		)
	}

	// The per-class override lets exactly one class through, and only that one.
	p, ref := plan_remove(
		&w,
		{"sddm"},
		Remove_Opts{yes = true, snapshot = true, allow = {.Display_Manager}},
	)
	check(!ref.refused, "--allow-protected display-manager lets sddm through")
	eq_i(len(p.steps), 2, "and plans a snapshot and a removal")

	_, ref2 := plan_remove(
		&w,
		{"linux"},
		Remove_Opts{yes = true, snapshot = true, allow = {.Display_Manager}},
	)
	eq_s(ref2.reason, "protected:kernel", "the display-manager override does not cover the kernel")

	_, ref3 := plan_remove(&w, {"sddm"}, Remove_Opts{yes = false, allow = {.Display_Manager}})
	check(ref3.refused, "the override alone, without --yes, is not enough")
	eq_s(ref3.reason, "protected:display-manager", "and it is still the protected refusal")

	// Protection is about removal. Installing a kernel is not the same act.
	w2 := canned_world()
	w2.installed["linux-lts"] = false
	w2.in_repo["linux-lts"] = true
	w2.repo_checked["linux-lts"] = true
	pi, refi := plan_install(&w2, {"linux-lts"}, Install_Opts{snapshot = true})
	check(!refi.refused, "installing a second kernel is allowed; it adds a way to boot")
	eq_i(len(pi.steps), 2, "and is snapshotted like any other install")
}

test_dependants :: proc() {
	section("a removal with dependants refuses without --yes")

	w := canned_world()

	_, ref := plan_remove(&w, {"libfoo"}, Remove_Opts{yes = false})
	check(ref.refused, "removing libfoo without --yes is refused")
	eq_s(ref.reason, "has-dependants", "and says so")
	eq_i(ref.code, EXIT_NEEDS_YES, "exit 4")
	check(strings.contains(ref.detail, "foo-app"), "naming the first dependant")
	check(strings.contains(ref.detail, "bar-app"), "and the second -- every one of them")

	// With --yes it proceeds, and the dependants are still named in the plan.
	p, ok := plan_remove(&w, {"libfoo"}, Remove_Opts{yes = true, snapshot = true})
	check(!ok.refused, "with --yes it plans")
	found := false
	for n in p.notes {
		if strings.contains(n, "foo-app") {
			found = true
		}
	}
	check(found, "and still names the dependants in the plan")

	// Something with no dependants still needs --yes, because remove is
	// destructive; it just gets the plainer reason.
	_, ref2 := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = false})
	check(ref2.refused, "removing an orphan without --yes is still refused")
	eq_s(ref2.reason, "needs-yes", "with the plain reason")

	// A dependant that is itself going away in the same removal is not a
	// reason to stop.
	w3 := canned_world()
	w3.required_by["libfoo"] = FOO_APP_ONLY[:]
	_, ref3 := plan_remove(&w3, {"libfoo", "foo-app"}, Remove_Opts{yes = false})
	eq_s(ref3.reason, "needs-yes", "removing a package together with its only dependant is not a dependants refusal")

	_, ref4 := plan_remove(&w, {"not-installed-at-all"}, Remove_Opts{yes = true})
	eq_s(ref4.reason, "not-installed", "removing something absent is a not-found")
	eq_i(ref4.code, EXIT_NOT_FOUND, "exit 3")

	_, ref5 := plan_remove(&w, {"--noconfirm"}, Remove_Opts{yes = true})
	eq_s(ref5.reason, "invalid-name", "a flag given as a package name is a usage error")
	eq_i(ref5.code, EXIT_USAGE, "exit 2")
}

// ---------------------------------------------------------------------------
// The exact argv
// ---------------------------------------------------------------------------

test_argv :: proc() {
	section("the exact argv that would be run")

	w := canned_world()

	p, ref := plan_install(&w, {"ripgrep", "fd"}, Install_Opts{snapshot = true})
	check(!ref.refused, "installing two repo packages plans cleanly")
	eq_i(len(p.steps), 2, "a snapshot and an install")
	eq_s(p.steps[0].what, "snapshot", "the snapshot comes first")
	eq_argv(
		step_argv(&p, 0),
		{
			"sudo",
			"snapper",
			"--config",
			"root",
			"create",
			"--type",
			"single",
			"--cleanup-algorithm",
			"number",
			"--description",
			"palm pkg install fd ripgrep",
			"--print-number",
		},
		"the snapshot argv, named for the operation",
	)
	eq_argv(
		step_argv(&p, 1),
		{"sudo", "pacman", "-S", "--needed", "--noconfirm", "--", "fd", "ripgrep"},
		"the install argv",
	)
	check(!slice.contains(step_argv(&p, 1), "-Sy"), "no -Sy anywhere in it")
	check(slice.contains(step_argv(&p, 1), "--noconfirm"), "and --noconfirm: --yes already confirmed it, and pacman's own question reads no answer as no")

	// Already installed: nothing to do, and no snapshot taken for nothing.
	p2, _ := plan_install(&w, {"git"}, Install_Opts{snapshot = true})
	eq_i(len(p2.steps), 0, "installing something already installed plans no steps")
	eq_s(p2.class, "idempotent", "and is idempotent, not a mutation")
	eq_i(len(p2.skipped), 1, "with git reported as skipped")

	// --refresh is the one flag that is refused outright.
	_, ref3 := plan_install(&w, {"ripgrep"}, Install_Opts{refresh = true, snapshot = true})
	check(ref3.refused, "install --refresh is refused")
	eq_s(ref3.reason, "partial-upgrade", "by name")
	check(strings.contains(ref3.detail, "-Sy"), "and the detail says why")

	// The AUR half is a separate step, and deliberately not under sudo.
	w4 := canned_world()
	srcs := make(map[string]Source, context.temp_allocator)
	srcs["only-in-the-aur"] = .Aur
	p4, ref4 := plan_install(
		&w4,
		{"ripgrep", "only-in-the-aur"},
		Install_Opts{snapshot = true, sources = srcs},
	)
	check(!ref4.refused, "a mixed repo/AUR install plans")
	eq_i(len(p4.steps), 3, "snapshot, pacman, yay")
	eq_argv(
		step_argv(&p4, 1),
		{"sudo", "pacman", "-S", "--needed", "--noconfirm", "--", "ripgrep"},
		"the repo half",
	)
	eq_argv(step_argv(&p4, 2), {"yay", "-S", "--needed", "--", "only-in-the-aur"}, "the AUR half")
	check(!p4.steps[2].needs_root, "yay is not run as root; it calls sudo itself")

	// An AUR-only name without --aur and without a declaration saying so is a
	// not-found rather than a silent AUR build.
	_, ref5 := plan_install(&w4, {"only-in-the-aur"}, Install_Opts{snapshot = true})
	eq_s(ref5.reason, "unknown-package", "an unknown name is not silently built from the AUR")
	eq_i(ref5.code, EXIT_NOT_FOUND, "exit 3")

	// Removal argv.
	p6, _ := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = true, snapshot = true})
	eq_argv(
		step_argv(&p6, 0),
		{
			"sudo",
			"snapper",
			"--config",
			"root",
			"create",
			"--type",
			"single",
			"--cleanup-algorithm",
			"number",
			"--description",
			"palm pkg remove orphanpkg",
			"--print-number",
		},
		"the removal snapshot argv",
	)
	eq_argv(step_argv(&p6, 1), {"sudo", "pacman", "-R", "--noconfirm", "--", "orphanpkg"}, "the removal argv")

	p7, _ := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = true, recursive = true, snapshot = true})
	eq_argv(
		step_argv(&p7, 1),
		{"sudo", "pacman", "-Rs", "--noconfirm", "--", "orphanpkg"},
		"--recursive is -Rs and nothing more",
	)

	// Every plan this program can build, checked for the one rule.
	for p in ([?]Plan{p, p2, p4, p6, p7}) {
		for s in p.steps {
			check(
				!argv_is_partial_upgrade(s.argv),
				"no planned step is a partial upgrade: %s",
				strings.join(s.argv, " ", context.temp_allocator),
			)
		}
	}
}

test_diff_and_sync :: proc() {
	section("diff and sync")

	w := canned_world()
	d := decl_parse("[base]\ngit\nripgrep\nfd\n")
	declared, sources := decl_wanted(&d, nil)
	df := diff_compute(&w, declared)

	eq_i(len(df.missing), 2, "two declared packages are missing")
	eq_s(df.missing[0], "fd", "sorted")
	eq_i(len(df.satisfied), 1, "git is satisfied")
	check(!df.in_sync, "so the machine is not in sync")
	// extra is measured against the explicit set, not everything installed:
	// a dependency pulled in by a declared package is not drift.
	check(!slice.contains(df.extra, "libfoo"), "a dependency is not drift")
	check(slice.contains(df.extra, "orphanpkg"), "an undeclared explicit package is drift")
	check(slice.contains(df.extra, "linux"), "and so is the kernel, until it is declared")

	// Install-only by default.
	p, ref := plan_sync(&w, df, Sync_Opts{snapshot = true, sources = sources})
	check(!ref.refused, "sync plans")
	eq_i(len(p.steps), 2, "a snapshot and one install")
	eq_argv(step_argv(&p, 1), {"sudo", "pacman", "-S", "--needed", "--noconfirm", "--", "fd", "ripgrep"}, "sync's install argv")
	eq_s(p.class, "mutate", "install-only sync is a mutation, not a destruction")
	pruneable := false
	for n in p.notes {
		if strings.contains(n, "--prune") {
			pruneable = true
		}
	}
	check(pruneable, "and it says what it is leaving alone")

	// --prune without --yes is refused, and the reason is the protected class
	// it would have hit first -- the kernel is in the extra set.
	_, ref2 := plan_sync(&w, df, Sync_Opts{prune = true, yes = false, snapshot = true, sources = sources})
	check(ref2.refused, "sync --prune without --yes is refused")
	eq_s(ref2.reason, "protected:kernel", "and the first thing it refuses is the kernel")

	// Declare the protected packages and the drift goes away.
	d2 := decl_parse("[base]\ngit\nfd\nripgrep\nlinux\nlimine\nsddm\nsystemd\nfoo-app\norphanpkg\n")
	declared2, sources2 := decl_wanted(&d2, nil)
	df2 := diff_compute(&w, declared2)
	eq_i(len(df2.extra), 0, "declaring everything explicit removes the drift")
	p3, ref3 := plan_sync(&w, df2, Sync_Opts{prune = true, yes = true, snapshot = true, sources = sources2})
	check(!ref3.refused, "and --prune then has nothing to remove")
	eq_i(len(p3.steps), 2, "just the snapshot and the install")

	// An in-sync machine plans nothing at all.
	w2 := canned_world()
	w2.installed["fd"] = true
	w2.installed["ripgrep"] = true
	w2.explicit["fd"] = true
	w2.explicit["ripgrep"] = true
	df3 := diff_compute(&w2, declared2)
	p4, _ := plan_sync(&w2, df3, Sync_Opts{snapshot = true, sources = sources2})
	eq_i(len(p4.steps), 0, "a converged machine plans no steps")
	eq_s(p4.class, "idempotent", "and sync is idempotent")
}

// test_noconfirm pins the one thing the first real pacman run changed: the
// steps --yes confirmed carry --noconfirm, ahead of the `--` fence, and the
// steps a person is meant to answer (upgrade, the AUR build) do not.
test_noconfirm :: proc() {
	section("--yes is the confirmation: pacman is not asked again")

	has_before_fence :: proc(argv: []string, flag: string) -> bool {
		for a in argv {
			if a == "--" {
				return false
			}
			if a == flag {
				return true
			}
		}
		return false
	}

	w := canned_world()
	pi, ri := plan_install(&w, {"ripgrep"}, Install_Opts{snapshot = true})
	check(!ri.refused, "install plans")
	check(has_before_fence(step_argv(&pi, 1), "--noconfirm"), "the install step says --noconfirm, before the fence")
	check(!slice.contains(step_argv(&pi, 0), "--noconfirm"), "the snapshot step has nothing to confirm")

	pr, rr := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = true, snapshot = true})
	check(!rr.refused, "remove plans")
	check(has_before_fence(step_argv(&pr, 1), "--noconfirm"), "the remove step says --noconfirm, before the fence")
	prs, _ := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = true, recursive = true})
	check(has_before_fence(step_argv(&prs, 0), "--noconfirm"), "and so does -Rs")

	// Without --yes there is no plan to carry the flag at all.
	_, rn := plan_remove(&w, {"orphanpkg"}, Remove_Opts{yes = false})
	eq_s(rn.reason, "needs-yes", "remove without --yes is still refused before any argv exists")

	pu, _ := plan_upgrade(Upgrade_Opts{interactive = true, aur = true, snapshot = true})
	for s in pu.steps {
		check(!slice.contains(s.argv, "--noconfirm"), "the upgrade's %s step leaves the questions to the person", s.what)
	}

	w2 := canned_world()
	srcs := make(map[string]Source, context.temp_allocator)
	srcs["only-in-the-aur"] = .Aur
	pa, _ := plan_install(&w2, {"only-in-the-aur"}, Install_Opts{sources = srcs})
	check(len(pa.steps) == 1 && !slice.contains(step_argv(&pa, 0), "--noconfirm"), "the AUR build is not silenced")

	// --noconfirm is a long flag; it must not upset the partial-upgrade rule
	// in either direction.
	check(!argv_is_partial_upgrade({"sudo", "pacman", "-S", "--needed", "--noconfirm", "--", "git"}), "install with --noconfirm is not a partial upgrade")
	check(argv_is_partial_upgrade({"sudo", "pacman", "-Sy", "--noconfirm", "--", "git"}), "and -Sy with --noconfirm still is")
}

test_upgrade_and_rollback :: proc() {
	section("upgrade and rollback need a person")

	_, ref := plan_upgrade(Upgrade_Opts{interactive = false, snapshot = true})
	check(ref.refused, "an unattended upgrade is refused")
	eq_s(ref.reason, "needs-a-person", "by name")
	eq_i(ref.code, EXIT_NEEDS_YES, "exit 4")
	check(strings.contains(ref.detail, "pacnew"), "and says what could stop it")

	p, ok := plan_upgrade(Upgrade_Opts{interactive = true, snapshot = true})
	check(!ok.refused, "with a terminal it plans")
	eq_i(len(p.steps), 2, "a snapshot and the upgrade")
	eq_argv(step_argv(&p, 1), {"sudo", "pacman", "-Syu"}, "the upgrade argv is -Syu, never -Sy")
	check(!argv_is_partial_upgrade(step_argv(&p, 1)), "and is not a partial upgrade")
	check(!slice.contains(step_argv(&p, 1), "--noconfirm"), "and does not silence pacman's questions")

	pa, _ := plan_upgrade(Upgrade_Opts{interactive = true, aur = true, snapshot = true})
	eq_i(len(pa.steps), 3, "--aur adds a third step")
	eq_argv(step_argv(&pa, 2), {"yay", "-Syu"}, "which is a full yay upgrade")

	_, rr := plan_rollback(42, Rollback_Opts{yes = true, interactive = false})
	eq_s(rr.reason, "needs-a-person", "an unattended rollback is refused")
	_, rr2 := plan_rollback(42, Rollback_Opts{yes = false, interactive = true})
	eq_s(rr2.reason, "needs-yes", "and a rollback without --yes is refused")
	_, rr3 := plan_rollback(0, Rollback_Opts{yes = true, interactive = true})
	eq_s(rr3.reason, "no-snapshot", "and a rollback with no snapshot named is a usage error")

	// When the list can be read, the layout and the number are checked
	// before any argv exists.
	plain := []Snapshot{{number = 0, description = "current"}, {number = 42, description = "palm pkg install git", from_palm = true}}
	_, rl := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, snapshots = plain, listed = true})
	eq_s(rl.reason, "rollback-layout", "on a plain-subvolume root a rollback is refused before snapper is asked")
	eq_i(rl.code, EXIT_SCOPE, "exit 5: this layout is out of scope for snapper rollback")
	check(strings.contains(rl.detail, "limine-snapper-restore"), "and the refusal names what does work there")
	suse := []Snapshot{{number = 0}, {number = 1, is_default = true, is_active = true}, {number = 42, from_palm = true}}
	ps, rs := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, snapshots = suse, listed = true})
	check(!rs.refused, "with the default subvolume a snapshot, it plans (%s)", rs.reason)
	eq_i(len(ps.steps), 1, "one step")
	_, ru := plan_rollback(99, Rollback_Opts{yes = true, interactive = true, snapshots = suse, listed = true})
	eq_s(ru.reason, "unknown-snapshot", "a number snapper does not have is refused by name")
	eq_i(ru.code, EXIT_NOT_FOUND, "exit 3")
	_, rp := plan_rollback(42, Rollback_Opts{yes = false, interactive = true, snapshots = plain, listed = true})
	eq_s(rp.reason, "needs-yes", "--yes is still asked for first")

	// Without the list (it needs root), the mount table answers the same
	// question: is / mounted from a snapper snapshot on btrfs.
	arch := parse_root_mount(
		"22 1 0:21 / /proc rw - proc proc rw\n25 1 0:24 /@ / rw,relatime shared:1 - btrfs /dev/nvme0n1p2 rw,subvol=/@\n26 25 0:24 /@home /home rw - btrfs /dev/nvme0n1p2 rw\n",
	)
	check(arch.known, "the root line of mountinfo is found")
	eq_s(arch.fstype, "btrfs", "its filesystem type, past the optional fields")
	eq_s(arch.subvol, "/@", "and its subvolume")
	check(!root_is_a_snapshot(arch), "/@ is the plain Arch layout")
	opensuse := parse_root_mount("60 1 0:30 /@/.snapshots/1/snapshot / rw - btrfs /dev/vda2 rw\n")
	check(root_is_a_snapshot(opensuse), "/@/.snapshots/1/snapshot is the openSUSE layout")
	check(!root_is_a_snapshot(Root_Mount{known = true, fstype = "ext4", subvol = "/.snapshots/1/snapshot"}), "and only on btrfs")
	check(!root_is_a_snapshot(Root_Mount{known = true, fstype = "btrfs", subvol = "/.snapshots/x/snapshot"}), "and only with a number")
	_, rm := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, root = arch})
	eq_s(rm.reason, "rollback-layout", "with no list, a /@ root is refused from the mount table alone")
	_, rm2 := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, root = opensuse})
	check(!rm2.refused, "and a snapshot root plans")
	_, rm3 := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, root = arch, snapshots = suse, listed = true})
	check(!rm3.refused, "the list, when it can be read, is what decides")

	// A refusal's subjects must outlive the planner's stack frame. The
	// planner is called one frame down and the stack is scribbled on before
	// the subjects are read, which is the order the real verb does it in.
	refused_far :: proc() -> (Refusal, Refusal, Refusal) {
		plain := []Snapshot{{number = 0}, {number = 42}}
		_, a := plan_rollback(42, Rollback_Opts{yes = true, interactive = true, snapshots = plain, listed = true})
		w := canned_world()
		_, b := plan_install(&w, {"-Sy"}, Install_Opts{})
		_, c := plan_remove(&w, {"--noconfirm"}, Remove_Opts{yes = true})
		return a, b, c
	}
	scribble :: proc() -> int {
		buf: [4096]u8
		for i in 0 ..< len(buf) {
			buf[i] = u8(i * 7)
		}
		return int(buf[1234])
	}
	ra, rb, rc := refused_far()
	_ = scribble()
	check(len(ra.subjects) == 1 && ra.subjects[0] == "42", "a refused rollback still names its snapshot after the planner returns (%v)", ra.subjects)
	check(len(rb.subjects) == 1 && rb.subjects[0] == "-Sy", "a refused install still names the bad name (%v)", rb.subjects)
	check(len(rc.subjects) == 1 && rc.subjects[0] == "--noconfirm", "a refused remove still names the bad name (%v)", rc.subjects)

	pr, pok := plan_rollback(42, Rollback_Opts{yes = true, interactive = true})
	check(!pok.refused, "with a person and --yes, and no list to read, it plans and snapper judges")
	eq_argv(
		step_argv(&pr, 0),
		{"sudo", "snapper", "--config", "root", "rollback", "42"},
		"the rollback argv",
	)
}

// ---------------------------------------------------------------------------
// Scope and surface
// ---------------------------------------------------------------------------

// drive runs pkg exactly as a caller would: argv through the shared parser,
// with whatever lands on file descriptor 1 read back. Under --json the kit
// pretty-prints; the document is compacted here so the assertions below can
// name a field as `"reason":"needs-yes"` whatever the indentation.
@(private = "file")
drive :: proc(args: []string) -> (code: int, out: string) {
	path := fmt.tprintf("%s/stdout-%d", scratch_root(), os.get_pid())
	saved := posix.dup(1)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR})
	posix.dup2(fd, 1)
	posix.close(fd)
	code = dispatch(args)
	posix.dup2(saved, 1)
	posix.close(saved)
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	os.remove(path)
	text := string(data)
	if strings.has_prefix(strings.trim_space(text), "{") {
		text = compact(text)
	}
	return code, text
}

// compact drops the whitespace between JSON tokens, leaving strings alone.
@(private = "file")
compact :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	in_str, esc := false, false
	for i in 0 ..< len(text) {
		ch := text[i]
		if in_str {
			strings.write_byte(&sb, ch)
			if esc {
				esc = false
			} else if ch == '\\' {
				esc = true
			} else if ch == '"' {
				in_str = false
			}
			continue
		}
		switch ch {
		case ' ', '\n', '\t', '\r':
			continue
		case '"':
			in_str = true
		}
		strings.write_byte(&sb, ch)
	}
	return strings.to_string(sb)
}

test_scope :: proc() {
	section("an identity may be narrowed, never widened")

	old := strings.clone(os.get_env("PALM_IDENTITY", context.temp_allocator), context.temp_allocator)
	defer {
		if old == "" {
			_ = os.unset_env("PALM_IDENTITY")
		} else {
			_ = os.set_env("PALM_IDENTITY", old)
		}
	}
	_ = os.set_env("PALM_IDENTITY", "work")

	code, text := drive({"diff", "--identity", "personal", "--json"})
	eq_i(code, EXIT_SCOPE, "asking for another identity exits 5")
	check(strings.contains(text, "out of scope"), "and says out of scope")
	check(strings.contains(text, "\"identity\":\"work\""), "naming the scope it is in")
	check(strings.contains(text, "\"requested\":\"personal\""), "and the one it was asked for")

	// Asking for the identity you already are is not widening.
	code2, _ := drive({"verbs", "--identity", "work", "--json"})
	eq_i(code2, EXIT_OK, "naming your own identity is fine")
}

test_surface :: proc() {
	section("the surface an agent reads")

	code, text := drive({"verbs", "--json"})
	eq_i(code, EXIT_OK, "verbs exits 0")
	check(strings.has_prefix(strings.trim_space(text), "{"), "and emits one JSON object on stdout")
	for v in surface().commands {
		check(strings.contains(text, fmt.tprintf("\"name\":\"%s\"", v.verb)), "verbs lists %s", v.verb)
		// Every verb it advertises is one the dispatcher actually has, and is
		// in the help a person reads.
		c, htext := drive({v.verb, "--help"})
		eq_i(c, EXIT_OK, "%s is reachable", v.verb)
		check(strings.contains(htext, v.verb), "and %s is in --help", v.verb)
	}
	check(strings.contains(text, "\"needs_yes\":4"), "the documented exit codes are in the surface")
	check(strings.contains(text, "display-manager"), "and the protected classes")

	c2, _ := drive({"no-such-verb"})
	eq_i(c2, EXIT_USAGE, "an unknown verb is a usage error")
	c3, _ := drive({"--no-such-flag"})
	eq_i(c3, EXIT_USAGE, "and so is an unknown flag")
	c4, _ := drive({})
	eq_i(c4, EXIT_USAGE, "and so is no verb at all")
	c5, _ := drive({"remove", "git", "--allow-protected", "nonsense"})
	eq_i(c5, EXIT_USAGE, "and so is an unknown protected class")
}

// ---------------------------------------------------------------------------
// Nothing executes
// ---------------------------------------------------------------------------

@(private = "file")
Fakes :: struct {
	bin:     string,
	fired:   string, // anything that would change the machine
	queries: string, // read-only calls
	fix:     string,
	decl:    string,
	old_path: string,
}

@(private = "file")
install_fakes :: proc() -> Fakes {
	root := scratch_root()
	f := Fakes {
		bin     = fmt.aprintf("%s/fakebin", root),
		fired   = fmt.aprintf("%s/fired", root),
		queries = fmt.aprintf("%s/queries", root),
		fix     = fmt.aprintf("%s/fixtures", root),
		decl    = fmt.aprintf("%s/decl", root),
	}
	_ = os.make_directory_all(f.bin)
	_ = os.make_directory_all(f.fix)
	_ = os.make_directory_all(f.decl)
	os.remove(f.fired)
	os.remove(f.queries)

	// The canned machine the fakes describe. It is the same shape as
	// canned_world(), so the plan the parsers produce can be compared against
	// the plan the pure planner produces.
	put(fmt.tprintf("%s/installed.txt", f.fix), "bash\nsystemd\nlinux\nlimine\nsddm\npacman\ngit\nlibfoo\nfoo-app\norphanpkg\n")
	put(fmt.tprintf("%s/explicit.txt", f.fix), "git\nfoo-app\norphanpkg\nlinux\nlimine\nsddm\nsystemd\n")
	put(fmt.tprintf("%s/repo.txt", f.fix), "git\nripgrep\nfd\nhello\nlibfoo\nfoo-app\n")
	put(
		fmt.tprintf("%s/qi-libfoo.txt", f.fix),
		"Name            : libfoo\nVersion         : 1.2.3-1\nRequired By     : foo-app  bar-app\n\n",
	)
	put(
		fmt.tprintf("%s/qi-orphanpkg.txt", f.fix),
		"Name            : orphanpkg\nVersion         : 0.1-1\nDescription     : Nothing needs this\nRequired By     : None\nInstall Reason  : Explicitly installed\n\n",
	)
	put(
		fmt.tprintf("%s/qi-git.txt", f.fix),
		"Name            : git\nVersion         : 2.4.5-1\nDescription     : the fast distributed VCS\nRequired By     : None\nInstall Reason  : Explicitly installed\n\n",
	)
	put(fmt.tprintf("%s/search.txt", f.fix), "extra/ripgrep 14.1.1-1\n    A search tool\n")
	put(
		fmt.tprintf("%s/snapshots.txt", f.fix),
		" # | Type   | Pre # | Date | User | Cleanup | Description | Userdata\n---+--------+-------+------+------+---------+-------------+---------\n0  | single |       |      | root |         | current     |\n7  | single |       | now  | root | number  | palm pkg install hello |\n",
	)
	put(fmt.tprintf("%s/default.pkgs", f.decl), "[base]\ngit\nripgrep\nfd\n")

	// pacman: read-only operations are answered from the fixtures and logged
	// to `queries`. Everything else -- which means everything that could
	// change a package -- goes to `fired` and runs nothing.
	put(
		fmt.tprintf("%s/pacman", f.bin),
		fmt.tprintf(
			`#!/bin/sh
FIX=%s
case "$1" in
  -Qq)  printf 'pacman %%s\n' "$*" >> %s; cat "$FIX/installed.txt"; exit 0 ;;
  -Qqe) printf 'pacman %%s\n' "$*" >> %s; cat "$FIX/explicit.txt"; exit 0 ;;
  -Qi)  printf 'pacman %%s\n' "$*" >> %s; shift; shift
        for n in "$@"; do [ -f "$FIX/qi-$n.txt" ] && cat "$FIX/qi-$n.txt"; done; exit 0 ;;
  -Si)  printf 'pacman %%s\n' "$*" >> %s; shift; shift; rc=0
        for n in "$@"; do
          if grep -Fxq "$n" "$FIX/repo.txt"; then printf 'Name            : %%s\nVersion         : 1.0\n\n' "$n"; else rc=1; fi
        done; exit $rc ;;
  -Ss)  printf 'pacman %%s\n' "$*" >> %s; cat "$FIX/search.txt"; exit 0 ;;
  *)    printf 'pacman %%s\n' "$*" >> %s; exit 0 ;;
esac
`,
			f.fix,
			f.queries,
			f.queries,
			f.queries,
			f.queries,
			f.queries,
			f.fired,
		),
		os.Permissions_All,
	)

	// sudo records and stops. It deliberately does not exec the rest of the
	// command line, so the real pacman cannot be reached even if the fake
	// pacman were missing.
	//
	// It also answers for pacman the way the real one did in the first real
	// run (apps/pkg/integration): a transaction without --noconfirm asks
	// "Proceed with installation? [Y/n]", and with nobody on stdin it reads
	// end-of-file as a no and exits 1. An upgrade is exempt here because the
	// self-test drives it as a person who is present and says yes.
	put(
		fmt.tprintf("%s/sudo", f.bin),
		fmt.tprintf(
			`#!/bin/sh
printf 'sudo %%s\n' "$*" >> %s
if [ "$1" = pacman ]; then
  case " $* " in *" --noconfirm "*) exit 0 ;; esac
  case "$2" in
    -Syu) exit 0 ;;
    -S*|-R*) echo ':: Proceed with installation? [Y/n] error: no answer on stdin' >&2; exit 1 ;;
  esac
fi
exit 0
`,
			f.fired,
		),
		os.Permissions_All,
	)
	put(
		fmt.tprintf("%s/yay", f.bin),
		fmt.tprintf(
			"#!/bin/sh\ncase \"$1\" in\n  -Ss|-Si|-Q*) printf 'yay %%s\\n' \"$*\" >> %s; exit 0 ;;\n  *) printf 'yay %%s\\n' \"$*\" >> %s; exit 0 ;;\nesac\n",
			f.queries,
			f.fired,
		),
		os.Permissions_All,
	)
	put(
		fmt.tprintf("%s/snapper", f.bin),
		fmt.tprintf(
			"#!/bin/sh\nfor a in \"$@\"; do\n  if [ \"$a\" = list ]; then printf 'snapper %%s\\n' \"$*\" >> %s; cat %s/snapshots.txt; exit 0; fi\ndone\nprintf 'snapper %%s\\n' \"$*\" >> %s\nexit 0\n",
			f.queries,
			f.fix,
			f.fired,
		),
		os.Permissions_All,
	)

	f.old_path = strings.clone(os.get_env("PATH", context.temp_allocator))
	_ = os.set_env("PATH", fmt.tprintf("%s:%s", f.bin, f.old_path))
	_ = os.set_env("PALM_PKG_DIR", f.decl)
	_ = os.set_env("PALM_PKG_NONINTERACTIVE", "1")
	_ = os.unset_env("PALM_IDENTITY")
	return f
}

@(private = "file")
remove_fakes :: proc(f: ^Fakes) {
	_ = os.set_env("PATH", f.old_path)
	_ = os.unset_env("PALM_PKG_DIR")
	_ = os.unset_env("PALM_PKG_NONINTERACTIVE")
}

// spring_the_trap proves PATH interception works before anything depends on
// it. If this fails, every "nothing executed" assertion below would pass for
// the wrong reason, so it also reports whether the rest may proceed.
@(private = "file")
spring_the_trap :: proc(f: ^Fakes) -> bool {
	ok := true

	// Resolution first: each tool must resolve inside the scratch directory.
	// Without this, a failed PATH override would send the lines below to the
	// real sudo and the real pacman.
	for tool in ([?]string{"sudo", "pacman", "yay", "snapper"}) {
		whereis, _ := run_query({"sh", "-c", fmt.tprintf("command -v %s", tool)})
		resolved := strings.trim_space(whereis)
		inside := strings.has_prefix(resolved, f.bin)
		check(inside, "%s resolves inside the fake directory (%q)", tool, resolved)
		if !inside {
			ok = false
		}
	}
	if !ok {
		fmt.println(
			"  the fake PATH is not in effect; refusing to drive anything that could reach a real pacman",
		)
		return false
	}

	// Now spring it: a mutation must land in `fired`, and a query must land in
	// `queries` and not in `fired`.
	os.remove(f.fired)
	os.remove(f.queries)
	_, _, _, _ = os.process_exec(
		{command = {"sudo", "pacman", "-S", "--", "nothing"}},
		context.temp_allocator,
	)
	check(os.exists(f.fired), "the fake sudo on PATH is reached (the mutation trap works)")
	fired := read_lines(f.fired)
	check(
		len(fired) == 1 && fired[0] == "sudo pacman -S -- nothing",
		"and it records the argv verbatim (%v)",
		fired,
	)

	_, _, _, _ = os.process_exec({command = {"pacman", "-Qq"}}, context.temp_allocator)
	q := read_lines(f.queries)
	check(len(q) == 1 && strings.has_prefix(q[0], "pacman -Qq"), "a read-only query is logged separately")
	eq_i(len(read_lines(f.fired)), 1, "and does not land in the mutation sentinel")

	// The fake answers pacman's question the way the real pacman did with no
	// terminal on stdin, or the --yes section below proves nothing about it.
	st1, _, _, _ := os.process_exec({command = {"sudo", "pacman", "-S", "--", "nothing"}}, context.temp_allocator)
	check(st1.exit_code == 1, "an unconfirmed pacman transaction with nobody on stdin fails, as the real one does (exit %d)", st1.exit_code)
	st2, _, _, _ := os.process_exec({command = {"sudo", "pacman", "-S", "--noconfirm", "--", "nothing"}}, context.temp_allocator)
	check(st2.exit_code == 0, "and the same transaction with --noconfirm goes through (exit %d)", st2.exit_code)

	os.remove(f.fired)
	os.remove(f.queries)
	check(!os.exists(f.fired), "the sentinel is clear before the verbs are driven")
	return true
}

// Every verb, driven the way an agent would drive it. None of them may change
// anything.
@(private = "file")
AGENT_DRIVEN := [?][]string {
	{"list", "--json"},
	{"list", "--explicit", "--json"},
	{"search", "ripgrep", "--json"},
	{"info", "git", "--json"},
	{"info", "no-such-package", "--json"},
	{"diff", "--json"},
	{"diff"},
	{"snapshots", "--json"},
	{"verbs", "--json"},
	{"declare", "htop", "--json"},
	{"undeclare", "htop", "--json"},
	{"install", "ripgrep", "--json"},
	{"install", "ripgrep", "--dry-run", "--json"},
	{"install", "ripgrep", "--refresh", "--yes", "--json"},
	{"install", "only-in-the-aur", "--yes", "--json"},
	{"remove", "libfoo", "--json"},
	{"remove", "../../etc/passwd", "--yes", "--json"},
	{"remove", "orphanpkg", "--json"},
	{"remove", "linux", "--yes", "--json"},
	{"remove", "limine", "--yes", "--json"},
	{"remove", "sddm", "--yes", "--json"},
	{"remove", "systemd", "--yes", "--json"},
	{"remove", "orphanpkg", "--yes", "--dry-run", "--json"},
	{"sync", "--json"},
	{"sync", "--dry-run", "--json"},
	{"sync", "--prune", "--json"},
	{"upgrade", "--json"},
	{"upgrade", "--dry-run", "--json"},
	{"rollback", "7", "--json"},
	{"rollback", "7", "--yes", "--json"},
}

test_nothing_executes :: proc() {
	section("every verb an agent can type, and nothing changes")

	f := install_fakes()
	defer remove_fakes(&f)

	if !spring_the_trap(&f) {
		failures += 1
		return
	}

	for args in AGENT_DRIVEN {
		code, text := drive(args)
		line := strings.join(args, " ", context.temp_allocator)
		if slice.contains(args, "--json") {
			check(
				strings.has_prefix(strings.trim_space(text), "{"),
				"`pkg %s` emits a JSON object and nothing else on stdout",
				line,
			)
		}
		check(code >= 0 && code <= 7, "`pkg %s` exits with a documented code (%d)", line, code)
		fired := read_lines(f.fired)
		check(len(fired) == 0, "`pkg %s` changed nothing (%v)", line, fired)
		if len(fired) > 0 {
			os.remove(f.fired)
		}
	}

	check(!os.exists(f.fired), "the sentinel is still empty after all of it")
	check(len(read_lines(f.queries)) > 0, "while the read-only queries did run")

	// A few of those exit codes are worth pinning down by name, driven through
	// the real dispatcher against the fake machine.
	expect := [?]struct {
		args:   []string,
		code:   int,
		reason: string,
	} {
		{{"install", "ripgrep", "--json"}, EXIT_NEEDS_YES, "needs-yes"},
		{{"install", "ripgrep", "--refresh", "--yes", "--json"}, EXIT_NEEDS_YES, "partial-upgrade"},
		{{"install", "only-in-the-aur", "--yes", "--json"}, EXIT_NOT_FOUND, "unknown-package"},
		// remove is declared destructive, so without --yes the shared parser
		// refuses before the body runs -- and asks the planner why
		// (on_refuse), so the refusal names the dependants as it always did.
		{{"remove", "libfoo", "--json"}, EXIT_NEEDS_YES, "has-dependants"},
		{{"remove", "libfoo", "--json"}, EXIT_NEEDS_YES, "kit:needs --yes"},
		{{"remove", "libfoo", "--dry-run", "--json"}, EXIT_NEEDS_YES, "has-dependants"},
		{{"remove", "orphanpkg", "--json"}, EXIT_NEEDS_YES, "needs-yes"},
		{{"remove", "orphanpkg", "--json"}, EXIT_NEEDS_YES, "kit:needs --yes"},
		{{"remove", "linux", "--json"}, EXIT_NEEDS_YES, "protected:kernel"},
		{{"remove", "orphanpkg", "--dry-run", "--json"}, EXIT_NEEDS_YES, "needs-yes"},
		{{"rollback", "7", "--json"}, EXIT_NEEDS_YES, "kit:needs --yes"},
		{{"remove", "linux", "--yes", "--json"}, EXIT_NEEDS_YES, "protected:kernel"},
		{{"remove", "limine", "--yes", "--json"}, EXIT_NEEDS_YES, "protected:bootloader"},
		{{"remove", "sddm", "--yes", "--json"}, EXIT_NEEDS_YES, "protected:display-manager"},
		{{"remove", "systemd", "--yes", "--json"}, EXIT_NEEDS_YES, "protected:init"},
		{{"remove", "pacman", "--yes", "--json"}, EXIT_NEEDS_YES, "protected:core"},
		{{"upgrade", "--json"}, EXIT_NEEDS_YES, "needs-a-person"},
		{{"rollback", "7", "--yes", "--json"}, EXIT_NEEDS_YES, "needs-a-person"},
		{{"info", "no-such-package", "--json"}, EXIT_NOT_FOUND, "unknown-package"},
		{{"remove", "../../etc/passwd", "--yes", "--json"}, EXIT_USAGE, "invalid-name"},
	}
	for e in expect {
		code, text := drive(e.args)
		line := strings.join(e.args, " ", context.temp_allocator)
		eq_i(code, e.code, "`pkg %s` exit code", line)
		want := fmt.tprintf("\"reason\":\"%s\"", e.reason)
		if strings.has_prefix(e.reason, "kit:") {
			want = fmt.tprintf("\"error\":\"%s\"", e.reason[4:])
		}
		check(
			strings.contains(text, want),
			"`pkg %s` refuses with reason %q (%s)",
			line,
			e.reason,
			strings.trim_space(text),
		)
		eq_i(len(read_lines(f.fired)), 0, "`pkg %s` still changed nothing", line)
	}

	// A flag given where a package name belongs never even reaches the
	// planner: the argument parser refuses an unknown flag first. Both fences
	// are real, and this is the outer one.
	cflag, _ := drive({"remove", "-Sy", "--yes", "--json"})
	eq_i(cflag, EXIT_USAGE, "`pkg remove -Sy` is refused by the argument parser")
	eq_i(len(read_lines(f.fired)), 0, "and changed nothing")

	// The dry runs print the argv, which is the whole point of them.
	_, dry := drive({"install", "ripgrep", "--dry-run", "--yes", "--json"})
	check(
		strings.contains(dry, "\"argv\":[\"sudo\",\"pacman\",\"-S\",\"--needed\",\"--noconfirm\",\"--\",\"ripgrep\"]"),
		"a dry run prints the exact install argv (%s)",
		strings.trim_space(dry),
	)
	check(strings.contains(dry, "\"what\":\"snapshot\""), "with the snapshot step in front of it")
	check(strings.contains(dry, "\"executed\":false"), "and says it executed nothing")
	eq_i(len(read_lines(f.fired)), 0, "and it really did execute nothing")

	_, dryu := drive({"upgrade", "--dry-run", "--json"})
	check(!strings.contains(dryu, "-Sy\""), "no verb's JSON ever contains a bare -Sy")

	// The refusal without --yes names every dependant, in the detail too.
	_, why := drive({"remove", "libfoo", "--json"})
	check(strings.contains(why, "foo-app"), "`pkg remove libfoo` without --yes names the dependants (%s)", why)
	eq_i(len(read_lines(f.fired)), 0, "and asking the planner why changed nothing")

	// The kit's guard is the second fence, for every other application: the
	// argv pkg plans would be refused from kit.run while a command runs. pkg
	// itself execs its plan directly, after --yes, so the guard does not stand
	// in its way -- the sentinel section below proves that argv still lands.
	for argv in ([?][]string {
			{"sudo", "pacman", "-S", "--needed", "--noconfirm", "--", "ripgrep"},
			{"sudo", "pacman", "-R", "--noconfirm", "--", "htop"},
			{"sudo", "snapper", "-c", "root", "create", "--description", "palm: install ripgrep"},
			{"snapper", "-c", "root", "create"},
			{"pacman", "-Syu"},
			{"yay", "-S", "--needed", "--", "only-in-the-aur"},
		}) {
		check(kit.cli_forbidden(argv) != "", "the kit's guard refuses `%s`", strings.join(argv, " ", context.temp_allocator))
	}
	for argv in ([?][]string{{"pacman", "-Qq"}, {"pacman", "-Si", "ripgrep"}, {"snapper", "-c", "root", "list"}}) {
		check(kit.cli_forbidden(argv) == "", "and lets the read-only `%s` through", strings.join(argv, " ", context.temp_allocator))
	}
}

// ---------------------------------------------------------------------------
// The argv that does run
// ---------------------------------------------------------------------------

// This is the other half of the trap. Above, nothing ran and the sentinel
// stayed empty; here the mutating verbs are driven on purpose, with --yes,
// and the sentinel is asserted to hold exactly the argv the planner printed.
// Without this section, "the sentinel is empty" could be true because the
// program cannot execute anything at all.
test_argv_that_runs :: proc() {
	section("with --yes, exactly the planned argv reaches exec and nothing else")

	f := install_fakes()
	defer remove_fakes(&f)
	if !spring_the_trap(&f) {
		failures += 1
		return
	}

	// install
	os.remove(f.fired)
	code, text := drive({"install", "hello", "--yes", "--json"})
	eq_i(code, EXIT_OK, "install --yes succeeds against the fake")
	check(strings.contains(text, "\"executed\":true"), "and says it executed")
	check(strings.contains(text, "\"steps_run\":2"), "both steps")
	fired := read_lines(f.fired)
	eq_i(len(fired), 2, "two commands reached exec")
	if len(fired) == 2 {
		eq_s(
			fired[0],
			"sudo snapper --config root create --type single --cleanup-algorithm number --description palm pkg install hello --print-number",
			"the snapshot ran first, named for the operation",
		)
		eq_s(fired[1], "sudo pacman -S --needed --noconfirm -- hello", "then exactly the planned install")
	}

	// remove
	os.remove(f.fired)
	code2, _ := drive({"remove", "orphanpkg", "--yes", "--json"})
	eq_i(code2, EXIT_OK, "remove --yes succeeds against the fake")
	fired2 := read_lines(f.fired)
	eq_i(len(fired2), 2, "two commands reached exec")
	if len(fired2) == 2 {
		eq_s(
			fired2[0],
			"sudo snapper --config root create --type single --cleanup-algorithm number --description palm pkg remove orphanpkg --print-number",
			"the removal snapshot ran first",
		)
		eq_s(fired2[1], "sudo pacman -R --noconfirm -- orphanpkg", "then exactly the planned removal")
	}

	// sync: the declaration asks for git, ripgrep and fd; git is installed.
	os.remove(f.fired)
	code3, _ := drive({"sync", "--yes", "--json"})
	eq_i(code3, EXIT_OK, "sync --yes succeeds against the fake")
	fired3 := read_lines(f.fired)
	eq_i(len(fired3), 2, "sync ran a snapshot and one install")
	if len(fired3) == 2 {
		eq_s(fired3[1], "sudo pacman -S --needed --noconfirm -- fd ripgrep", "converging installed exactly what was missing")
	}

	// upgrade, with a person declared present.
	os.remove(f.fired)
	_ = os.set_env("PALM_PKG_NONINTERACTIVE", "0")
	code4, _ := drive({"upgrade", "--json"})
	_ = os.set_env("PALM_PKG_NONINTERACTIVE", "1")
	eq_i(code4, EXIT_OK, "upgrade succeeds when a person is there")
	fired4 := read_lines(f.fired)
	eq_i(len(fired4), 2, "a snapshot and the upgrade")
	if len(fired4) == 2 {
		eq_s(fired4[1], "sudo pacman -Syu", "and it is -Syu, never -Sy")
	}

	// rollback, with a person declared present, against the fake snapper's
	// list, which has no default-subvolume mark: the plain-subvolume layout
	// the real run found. It is refused, and nothing runs.
	os.remove(f.fired)
	_ = os.set_env("PALM_PKG_NONINTERACTIVE", "0")
	code5, text5 := drive({"rollback", "7", "--yes", "--json"})
	code6, text6 := drive({"rollback", "99", "--yes", "--json"})
	_ = os.set_env("PALM_PKG_NONINTERACTIVE", "1")
	eq_i(code5, EXIT_SCOPE, "rollback on a plain-subvolume root is out of scope")
	check(strings.contains(text5, "rollback-layout"), "by name (%s)", text5)
	eq_i(code6, EXIT_NOT_FOUND, "and a snapshot snapper does not list is not found")
	check(strings.contains(text6, "unknown-snapshot"), "by name")
	eq_i(len(read_lines(f.fired)), 0, "neither ran anything")

	// The strongest form of the rule: across everything that ran in this
	// section, no command line refreshed without upgrading.
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..fired)
	append(&all, ..fired2)
	append(&all, ..fired3)
	append(&all, ..fired4)
	for line in all {
		check(
			!argv_is_partial_upgrade(strings.fields(line, context.temp_allocator)),
			"nothing that ran was a partial upgrade: %s",
			line,
		)
		// --noconfirm is on the steps --yes confirmed, and never on the
		// upgrade, whose questions are what the person is there for.
		f := strings.fields(line, context.temp_allocator)
		confirmed := len(f) > 2 && f[1] == "pacman" && (f[2] == "-S" || f[2] == "-R" || f[2] == "-Rs")
		check(
			strings.contains(line, "--noconfirm") == confirmed,
			"--noconfirm exactly on the install and remove steps: %s",
			line,
		)
		check(strings.has_prefix(line, "sudo "), "and everything that changed the machine went through sudo: %s", line)
	}
	check(len(all) == 8, "eight commands ran in total across the four verbs (%d)", len(all))
}

// ---------------------------------------------------------------------------
// The shared convention
// ---------------------------------------------------------------------------

// pkg's command line is the kit's (apps/kit/cli.odin). These are the
// assertions `palm --selftest` makes of every converted application, made
// here too so a regression shows up in pkg's own count -- run against the
// fake machine, so a read that would ask pacman asks the fixture instead.
test_convention :: proc() {
	section("the palm command-line convention")

	s := surface()
	schema := kit.json_text(kit.cli_schema_json(s), 0, context.temp_allocator)
	check(strings.contains(schema, "\"noun\":\"pkg\""), "--schema names the noun")
	eq_i(len(s.commands), 13, "thirteen verbs are declared")
	EFFECTS :: [?][2]string {
		{"list", "read"},
		{"search", "read"},
		{"info", "read"},
		{"diff", "read"},
		{"declare", "mutate"},
		{"undeclare", "mutate"},
		{"install", "mutate"},
		{"remove", "destructive"},
		{"sync", "idempotent"},
		{"upgrade", "mutate"},
		{"snapshots", "read"},
		{"rollback", "destructive"},
		{"verbs", "read"},
	}
	effect_of :: proc(verb: string) -> string {
		for e in EFFECTS {
			if e[0] == verb {
				return e[1]
			}
		}
		return "?"
	}
	for cmd in s.commands {
		check(len(cmd.out) > 0, "%s declares what it prints", cmd.verb)
		check(len(cmd.examples) > 0, "%s ships an example", cmd.verb)
		eq_s(kit.effect_name(cmd.effect), effect_of(cmd.verb), "%s's side-effect class", cmd.verb)
		for ex in cmd.examples {
			words := kit.cli_split_example(ex)
			check(len(words) > 1 && words[0] == "pkg", "the example %q is typed as the binary is named", ex)
			if len(words) < 2 {
				continue
			}
			_, code := kit.cli_bind(s, words[1:])
			eq_i(code, EXIT_OK, "the example %q parses", ex)
			if cmd.effect == .Destructive {
				check(strings.contains(ex, "--yes") || strings.contains(ex, "--dry-run"), "the destructive example %q says --yes or --dry-run", ex)
			}
		}
	}

	// The spellings pkg took before the convention, each still accepted.
	for line in ([?][]string {
		{"list", "--explicit", "--json"},
		{"search", "ripgrep", "--aur"},
		{"info", "git", "--json"},
		{"diff", "--profile", "base,dev", "--file", "/tmp/x.pkgs"},
		{"declare", "htop", "fd", "--profile", "dev", "--aur", "--dry-run"},
		{"undeclare", "htop", "--file", "/tmp/x.pkgs"},
		{"install", "ripgrep", "--refresh", "--aur", "--yes", "--json"},
		{"remove", "x", "--recursive", "--allow-protected", "kernel", "--allow-protected", "init", "--yes"},
		{"sync", "--prune", "--yes", "--dry-run", "--allow-protected", "core"},
		{"upgrade", "--aur", "--dry-run"},
		{"snapshots", "--json"},
		{"rollback", "7", "--yes"},
		{"verbs", "--identity", "personal", "--json"},
	}) {
		_, code := kit.cli_bind(s, line)
		eq_i(code, EXIT_OK, "`pkg %s` still parses", strings.join(line, " ", context.temp_allocator))
	}
	c_old, _ := drive({"pkg", "verbs", "--json"})
	eq_i(c_old, EXIT_OK, "and `pkg pkg verbs`, as palm once passed it, still works")

	f := install_fakes()
	defer remove_fakes(&f)
	if !spring_the_trap(&f) {
		failures += 1
		return
	}

	// Every destructive verb refuses without --yes, in the shared parser,
	// before the planner or any process is reached.
	for cmd in s.commands {
		if cmd.effect != .Destructive {
			continue
		}
		words := kit.cli_split_example(cmd.examples[0])
		without := make([dynamic]string, context.temp_allocator)
		for w in words[1:] {
			if w != "--yes" {
				append(&without, w)
			}
		}
		code, text := drive(without[:])
		eq_i(code, EXIT_NEEDS_YES, "`pkg %s` without --yes exits 4", cmd.verb)
		check(strings.contains(text, "\"error\":\"needs --yes\""), "with the documented token (%s)", strings.trim_space(text))
		eq_i(len(read_lines(f.fired)), 0, "and nothing reached exec")
		append(&without, "--parse-only")
		pcode, _ := drive(without[:])
		eq_i(pcode, EXIT_NEEDS_YES, "and --parse-only applies the same gate")
	}

	// Every read answers with the shape it declared.
	for cmd in s.commands {
		if cmd.effect != .Read {
			continue
		}
		words := kit.cli_split_example(cmd.examples[0])
		code, text := drive(words[1:])
		eq_i(code, EXIT_OK, "`%s` exits 0 against the fake machine", cmd.examples[0])
		problems := kit.cli_validate_output(text, cmd.out, context.temp_allocator)
		check(len(problems) == 0, "`%s` matches its declared schema%s", cmd.examples[0], len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
	}

	// A refusal is the documented error object, with pkg's reason beside it.
	{
		code, text := drive({"info", "no-such-package", "--json"})
		eq_i(code, EXIT_NOT_FOUND, "an unknown package is exit 3")
		problems := kit.cli_validate_output(
			text,
			{{name = "error", kind = .String}, {name = "code", kind = .Int}, {name = "command", kind = .String}, {name = "reason", kind = .String}},
			context.temp_allocator,
		)
		check(len(problems) == 0, "as the documented error object%s", len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
		check(strings.contains(text, "\"error\":\"not found\""), "with the token for exit 3")
	}
	{
		code, _ := drive({"install", "ripgrep", "--dry-run", "--json"})
		eq_i(code, EXIT_OK, "a dry run without --yes is accepted")
		eq_i(len(read_lines(f.fired)), 0, "and runs nothing")
	}

	// --allow-protected may repeat, as it always could: the first of two is
	// not dropped for the second.
	{
		code, text := drive({"remove", "linux", "--yes", "--allow-protected", "kernel", "--allow-protected", "init", "--dry-run", "--json"})
		eq_i(code, EXIT_OK, "two --allow-protected are both honoured (%s)", strings.trim_space(text))
		check(strings.contains(text, "\"executed\":false"), "and the dry run executed nothing")
		eq_i(len(read_lines(f.fired)), 0, "and nothing reached exec")
	}
	{
		code, text := drive({"remove", "x", "--allow-protected", "nonsense", "--yes", "--json"})
		eq_i(code, EXIT_USAGE, "an unknown protected class is a usage error")
		check(strings.contains(text, "\"error\":\"usage\""), "with the documented token")
	}

	// --parse-only validates and runs nothing.
	{
		code, _ := drive({"install", "ripgrep", "--yes", "--parse-only"})
		eq_i(code, EXIT_OK, "--parse-only accepts a valid line")
		eq_i(len(read_lines(f.fired)), 0, "and does not run it")
	}
	check(!os.exists(f.fired), "the sentinel is empty at the end of the convention checks")
}
