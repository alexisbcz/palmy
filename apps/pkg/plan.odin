package main

// The planner. Every verb that would change the machine produces a Plan -- an
// ordered list of argv -- or a Refusal, and nothing in this program builds an
// argv anywhere else.
//
// That single choke point is the whole safety argument. `plan_check` runs over
// every plan before it is printed or executed, and four of the rules in
// docs/PACKAGES.md are enforced there rather than at each call site, so a verb
// added later cannot forget them:
//
//   1. argv[0] is one of sudo, pacman, yay, snapper. Nothing else.
//   2. A step that needs root goes through `sudo`, which asks for a password.
//      No password is ever read, cached, embedded or passed by this program.
//   3. A step that names packages puts `--` in front of them, so a name can
//      never be read as a flag.
//   4. NEVER A REFRESH WITHOUT AN UPGRADE. `pacman -Sy <pkg>` installs a new
//      package against old libraries and is the documented way to break an
//      Arch system. Only `-Syu`, or no refresh at all.
//
// The planner is pure: it reads a World and an Opts and returns values. It
// runs no subprocess, so the self-test can drive it against canned machines
// (including machines this one is not, such as one with no kernel installed).

import "core:fmt"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Protected classes
// ---------------------------------------------------------------------------

// Guard names the four things docs/PACKAGES.md says must never be touched
// without an explicit, separate confirmation, plus the package tooling itself.
// They are separate values rather than one "protected" flag so that a refusal
// can say which line was crossed, and so each can be asserted on its own.
Guard :: enum u8 {
	None,
	Kernel,
	Bootloader,
	Display_Manager,
	Init,
	Core,
}

guard_name :: proc(g: Guard) -> string {
	switch g {
	case .Kernel:
		return "kernel"
	case .Bootloader:
		return "bootloader"
	case .Display_Manager:
		return "display-manager"
	case .Init:
		return "init"
	case .Core:
		return "core"
	case .None:
		return ""
	}
	return ""
}

guard_from_name :: proc(s: string) -> (Guard, bool) {
	switch s {
	case "kernel":
		return .Kernel, true
	case "bootloader":
		return .Bootloader, true
	case "display-manager", "display_manager", "dm":
		return .Display_Manager, true
	case "init":
		return .Init, true
	case "core":
		return .Core, true
	}
	return .None, false
}

guard_why :: proc(g: Guard) -> string {
	switch g {
	case .Kernel:
		return "removing it leaves the machine with no kernel to boot"
	case .Bootloader:
		return "removing it leaves the machine unable to find a kernel; limine and limine-snapper-sync are also what make rollback work here"
	case .Display_Manager:
		return "removing it leaves the machine with no way to log in graphically"
	case .Init:
		return "removing it leaves the machine with no init, which is unrecoverable without external media"
	case .Core:
		return "it is the package tooling or the C library; removing it means no further package operations are possible"
	case .None:
		return ""
	}
	return ""
}

@(private = "file")
BOOTLOADER := [?]string {
	"limine",
	"limine-snapper-sync",
	"limine-mkinitcpio-hook",
	"limine-entry-tool",
	"grub",
	"grub-btrfs",
	"refind",
	"syslinux",
	"efibootmgr",
	"efivar",
	"sbctl",
	"shim-signed",
	"mkinitcpio",
	"mkinitcpio-busybox",
	"booster",
	"dracut",
}

@(private = "file")
DISPLAY_MANAGER := [?]string {
	"sddm",
	"sddm-kcm",
	"gdm",
	"lightdm",
	"lxdm",
	"xdm",
	"ly",
	"emptty",
	"greetd",
	"greetd-tuigreet",
	"uwsm",
}

@(private = "file")
INIT := [?]string {
	"systemd",
	"systemd-libs",
	"systemd-sysvcompat",
	"systemd-resolvconf",
	"systemd-ukify",
	"dbus",
	"dbus-broker",
	"dbus-broker-units",
	"elogind",
	"openrc",
	"runit",
	"dinit",
	"s6",
	"s6-rc",
}

@(private = "file")
CORE := [?]string {
	"pacman",
	"pacman-mirrorlist",
	"pacman-contrib",
	"archlinux-keyring",
	"glibc",
	"gcc-libs",
	"bash",
	"coreutils",
	"filesystem",
	"base",
	"sudo",
	"btrfs-progs",
	"snapper",
	"snap-pac",
	"util-linux",
	"openssl",
	"ca-certificates",
}

// guard_of classifies a package name. The order of the tests is the order of
// severity, and the kernel test is a prefix match on purpose: `linux`,
// `linux-lts`, `linux-firmware`, `linux-headers` and anything else the kernel
// row of a future Arch grows are all refused. Over-refusing a package like
// `linux-api-headers`, which is a toolchain header set and not a kernel, is
// the safe direction for this to be wrong in: the cost is one extra flag on a
// command line, and the cost the other way is an unbootable machine.
guard_of :: proc(name: string) -> Guard {
	if name == "linux" || strings.has_prefix(name, "linux-") {
		return .Kernel
	}
	switch name {
	case "amd-ucode", "intel-ucode":
		return .Kernel
	}
	for n in BOOTLOADER {
		if n == name {
			return .Bootloader
		}
	}
	for n in DISPLAY_MANAGER {
		if n == name {
			return .Display_Manager
		}
	}
	for n in INIT {
		if n == name {
			return .Init
		}
	}
	for n in CORE {
		if n == name {
			return .Core
		}
	}
	return .None
}

// ---------------------------------------------------------------------------
// Plans and refusals
// ---------------------------------------------------------------------------

Step :: struct {
	what:       string, // snapshot | install | aur-install | remove | upgrade | aur-upgrade | rollback
	argv:       []string,
	needs_root: bool,
}

Plan :: struct {
	op:      string,
	class:   string, // read | idempotent | mutate | destructive | intent
	targets: []string,
	skipped: []string,
	steps:   []Step,
	notes:   []string,
}

Refusal :: struct {
	refused:  bool,
	code:     int,
	reason:   string, // a stable token, never prose
	detail:   string,
	subjects: []string,
}

EXIT_OK :: 0
EXIT_USAGE :: 2
EXIT_NOT_FOUND :: 3
EXIT_NEEDS_YES :: 4
EXIT_SCOPE :: 5
EXIT_UNAVAILABLE :: 6
EXIT_FAILED :: 7

refuse :: proc(code: int, reason, detail: string, subjects: []string = nil) -> Refusal {
	return Refusal{refused = true, code = code, reason = reason, detail = detail, subjects = subjects}
}

// ---------------------------------------------------------------------------
// The invariant that cannot be forgotten
// ---------------------------------------------------------------------------

// argv_is_partial_upgrade is the single assertion docs/PACKAGES.md cares most
// about, written so it can be called on any argv at all -- including one this
// program did not build, which is how the self-test proves the check can fail.
//
// It catches both spellings: the short cluster (`-Sy`, `-Syy`, `-Syw`) and the
// long flags (`--refresh` without `--sysupgrade`). `-Syu` and `-Syyuu` pass.
argv_is_partial_upgrade :: proc(argv: []string) -> bool {
	sync := false
	refresh := false
	upgrade := false
	for a in argv {
		if len(a) < 2 || a[0] != '-' {
			continue
		}
		if a == "--" {
			break // everything after the fence is an operand, not a flag
		}
		if strings.has_prefix(a, "--") {
			switch a {
			case "--sync":
				sync = true
			case "--refresh":
				refresh = true
			case "--sysupgrade":
				upgrade = true
			}
			continue
		}
		// A short cluster. The letters are read separately from whether this
		// is a sync operation at all, because `pacman -S -y` is the same
		// command as `pacman -Sy` and both have to be caught.
		for i in 1 ..< len(a) {
			switch a[i] {
			case 'S':
				sync = true
			case 'y':
				refresh = true
			case 'u':
				upgrade = true
			}
		}
	}
	return sync && refresh && !upgrade
}

@(private = "file")
ALLOWED_PROGRAMS := [?]string{"sudo", "pacman", "yay", "snapper"}

// plan_check runs over a finished plan. It returns a reason token, empty when
// the plan is clean. Every plan goes through it before it is printed, let
// alone run, so that a verb written later inherits the rules for free.
plan_check :: proc(p: ^Plan) -> (reason: string, detail: string) {
	for s, i in p.steps {
		if len(s.argv) == 0 {
			return "invariant", fmt.aprintf("step %d has an empty argv", i)
		}
		prog := s.argv[0]
		if !slice.contains(ALLOWED_PROGRAMS[:], prog) {
			return "invariant", fmt.aprintf("step %d runs %q, which is not one of sudo, pacman, yay, snapper", i, prog)
		}
		if s.needs_root && prog != "sudo" {
			return "invariant", fmt.aprintf("step %d changes the system but does not go through sudo", i)
		}
		if argv_is_partial_upgrade(s.argv) {
			return "partial-upgrade", fmt.aprintf(
				"step %d would refresh the package database without upgrading: %s",
				i,
				strings.join(s.argv, " ", context.temp_allocator),
			)
		}
		// Operand lists must be fenced, and every operand must be a package.
		if s.what == "install" || s.what == "aur-install" || s.what == "remove" {
			dd := -1
			for a, j in s.argv {
				if a == "--" {
					dd = j
					break
				}
			}
			if dd < 0 {
				return "invariant", fmt.aprintf("step %d names packages without a `--` fence", i)
			}
			if dd == len(s.argv) - 1 {
				return "invariant", fmt.aprintf("step %d fences an empty operand list", i)
			}
			for a in s.argv[dd + 1:] {
				if !pkg_name_ok(a) {
					return "invariant", fmt.aprintf("step %d passes %q as a package name", i, a)
				}
			}
		}
	}
	return "", ""
}

// plan_finish is the only way a Plan leaves this file.
plan_finish :: proc(p: Plan) -> (out: Plan, ref: Refusal) {
	q := p
	reason, detail := plan_check(&q)
	if reason != "" {
		return q, refuse(EXIT_FAILED, reason, detail)
	}
	return q, Refusal{}
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

// snapshot_step is the rollback half of the design: a snapper snapshot taken
// before the mutation and *named for the operation*, so `palm pkg rollback`
// has something to return to and a person reading `snapper list` can see what
// each snapshot was for.
//
// snapper is configured on / here and limine-snapper-sync keeps the boot
// entries in step with the snapshot list, so this reuses the machine's
// existing rollback rather than inventing one.
snapshot_step :: proc(op: string, targets: []string, allocator := context.allocator) -> Step {
	desc := fmt.aprintf(
		"palm pkg %s %s",
		op,
		strings.join(targets, " ", context.temp_allocator),
		allocator = allocator,
	)
	if len(targets) == 0 {
		desc = fmt.aprintf("palm pkg %s", op, allocator = allocator)
	}
	argv := make([dynamic]string, allocator)
	append(
		&argv,
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
		desc,
		"--print-number",
	)
	return Step{what = "snapshot", argv = argv[:], needs_root = true}
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

Install_Opts :: struct {
	refresh:   bool, // --refresh, which is refused: see below
	aur:       bool, // allow names that only the AUR has
	snapshot:  bool,
	sources:   map[string]Source, // from the declaration, when sync drives this
}

plan_install :: proc(
	w: ^World,
	names: []string,
	o: Install_Opts,
	allocator := context.allocator,
) -> (
	Plan,
	Refusal,
) {
	for n in names {
		if !pkg_name_ok(n) {
			return Plan{}, refuse(
				EXIT_USAGE,
				"invalid-name",
				fmt.aprintf("%q is not a package name; it would be read as a flag or a path", n),
				{n},
			)
		}
	}

	// The rule that this whole program exists to keep.
	if o.refresh {
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			"partial-upgrade",
			"refreshing the package database and then installing against it (`pacman -Sy <pkg>`) links new packages against old libraries and is the documented way to break an Arch system. Either install without a refresh, or run `palm pkg upgrade`, which is a full -Syu and which a person has to start.",
			names,
		)
	}

	todo := make([dynamic]string, allocator)
	aur := make([dynamic]string, allocator)
	skipped := make([dynamic]string, allocator)
	missing := make([dynamic]string, allocator)

	for n in names {
		if w.installed[n] {
			append(&skipped, n)
			continue
		}
		src := Source.Repo
		if s, had := o.sources[n]; had {
			src = s
		}
		if src == .Aur || (w.repo_checked[n] && !w.in_repo[n]) {
			if !o.aur && src != .Aur {
				append(&missing, n)
				continue
			}
			append(&aur, n)
		} else {
			append(&todo, n)
		}
	}

	if len(missing) > 0 {
		return Plan{}, refuse(
			EXIT_NOT_FOUND,
			"unknown-package",
			"no sync repository has these, and --aur was not given",
			missing[:],
		)
	}

	slice.sort(todo[:])
	slice.sort(aur[:])

	targets := make([dynamic]string, allocator)
	append(&targets, ..todo[:])
	append(&targets, ..aur[:])

	notes := make([dynamic]string, allocator)
	steps := make([dynamic]Step, allocator)

	if len(targets) == 0 {
		append(&notes, "nothing to do: everything named is already installed")
		return plan_finish(
			Plan {
				op = "install",
				class = "idempotent",
				targets = nil,
				skipped = skipped[:],
				steps = nil,
				notes = notes[:],
			},
		)
	}

	if o.snapshot {
		append(&steps, snapshot_step("install", targets[:], allocator))
	}

	if len(todo) > 0 {
		argv := make([dynamic]string, allocator)
		// No -y. `--needed` makes a repeat run a no-op, which is what makes
		// install idempotent and safe for `sync` to call.
		append(&argv, "sudo", "pacman", "-S", "--needed", "--")
		append(&argv, ..todo[:])
		append(&steps, Step{what = "install", argv = argv[:], needs_root = true})
	}
	if len(aur) > 0 {
		argv := make([dynamic]string, allocator)
		// yay runs sudo itself for the pacman half and must not be run as
		// root, so this step is deliberately not needs_root.
		append(&argv, "yay", "-S", "--needed", "--")
		append(&argv, ..aur[:])
		append(&steps, Step{what = "aur-install", argv = argv[:], needs_root = false})
		append(&notes, "the AUR half builds from source and can ask questions; it is not unattended")
	}

	append(&notes, "no database refresh: a -Sy without -u is a partial upgrade")
	return plan_finish(
		Plan {
			op = "install",
			class = "mutate",
			targets = targets[:],
			skipped = skipped[:],
			steps = steps[:],
			notes = notes[:],
		},
	)
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

Remove_Opts :: struct {
	yes:       bool,
	recursive: bool, // -Rs: also take dependencies that become orphans
	snapshot:  bool,
	allow:     []Guard,
}

plan_remove :: proc(
	w: ^World,
	names: []string,
	o: Remove_Opts,
	allocator := context.allocator,
) -> (
	Plan,
	Refusal,
) {
	for n in names {
		if !pkg_name_ok(n) {
			return Plan{}, refuse(
				EXIT_USAGE,
				"invalid-name",
				fmt.aprintf("%q is not a package name", n),
				{n},
			)
		}
	}

	absent := make([dynamic]string, context.temp_allocator)
	for n in names {
		if !w.installed[n] {
			append(&absent, n)
		}
	}
	if len(absent) > 0 {
		return Plan{}, refuse(
			EXIT_NOT_FOUND,
			"not-installed",
			"nothing to remove",
			slice.clone(absent[:], allocator),
		)
	}

	// Each protected class is checked and reported on its own, so a refusal
	// names the line that was crossed rather than saying "protected".
	for g in ([?]Guard{.Kernel, .Bootloader, .Display_Manager, .Init, .Core}) {
		hit := make([dynamic]string, allocator)
		for n in names {
			if guard_of(n) == g {
				append(&hit, n)
			}
		}
		if len(hit) == 0 {
			continue
		}
		if slice.contains(o.allow, g) && o.yes {
			continue
		}
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			fmt.aprintf("protected:%s", guard_name(g)),
			fmt.aprintf(
				"%s: %s. Removing it needs its own confirmation: --yes --allow-protected %s",
				guard_name(g),
				guard_why(g),
				guard_name(g),
			),
			hit[:],
		)
	}

	// Dependants. Named in full, every time, because "something depends on
	// this" without saying what is not information a person can act on.
	with_deps := make([dynamic]string, allocator)
	for n in names {
		deps := dependants_of(w, n)
		live := make([dynamic]string, context.temp_allocator)
		for d in deps {
			// A dependant that is itself being removed is not a reason to stop.
			if !slice.contains(names, d) {
				append(&live, d)
			}
		}
		if len(live) > 0 {
			append(&with_deps, n)
		}
	}

	if !o.yes {
		if len(with_deps) > 0 {
			return Plan{}, refuse(
				EXIT_NEEDS_YES,
				"has-dependants",
				strings.join(describe_dependants(w, with_deps[:], allocator), "; ", allocator),
				with_deps[:],
			)
		}
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			"needs-yes",
			"remove is destructive and never prompts; pass --yes",
			slice.clone(names, allocator),
		)
	}

	sorted := slice.clone(names, allocator)
	slice.sort(sorted)

	steps := make([dynamic]Step, allocator)
	if o.snapshot {
		append(&steps, snapshot_step("remove", sorted, allocator))
	}
	argv := make([dynamic]string, allocator)
	append(&argv, "sudo", "pacman", o.recursive ? "-Rs" : "-R", "--")
	append(&argv, ..sorted)
	append(&steps, Step{what = "remove", argv = argv[:], needs_root = true})

	notes := make([dynamic]string, allocator)
	if len(with_deps) > 0 {
		append(&notes, ..describe_dependants(w, with_deps[:], allocator))
	}
	if o.recursive {
		append(&notes, "-Rs also removes dependencies that become orphans")
	}
	return plan_finish(
		Plan {
			op = "remove",
			class = "destructive",
			targets = sorted,
			steps = steps[:],
			notes = notes[:],
		},
	)
}

// ---------------------------------------------------------------------------
// upgrade
// ---------------------------------------------------------------------------

Upgrade_Opts :: struct {
	aur:         bool,
	snapshot:    bool,
	interactive: bool,
}

// plan_upgrade is the one verb that is interactive by design.
//
// A full upgrade can need a person mid-way: a .pacnew to merge, a keyring that
// has to be refreshed before signatures verify, a kernel module mismatch that
// makes the running system unable to load anything until reboot. An agent that
// walks into one of those leaves a half-configured machine, so an agent does
// not start one. This refuses without a terminal, and --yes does not satisfy
// it: the requirement is a person, not a flag.
plan_upgrade :: proc(o: Upgrade_Opts, allocator := context.allocator) -> (Plan, Refusal) {
	if !o.interactive {
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			"needs-a-person",
			"a full upgrade can stop for a .pacnew, a keyring change or a kernel module mismatch, and an agent that hits one leaves a half-configured machine. Run `palm pkg upgrade` from a terminal. --yes does not substitute for a person.",
		)
	}
	steps := make([dynamic]Step, allocator)
	if o.snapshot {
		append(&steps, snapshot_step("upgrade", nil, allocator))
	}
	argv := make([dynamic]string, allocator)
	// -Syu, never -Sy. The 'u' is the whole point.
	append(&argv, "sudo", "pacman", "-Syu")
	append(&steps, Step{what = "upgrade", argv = argv[:], needs_root = true})
	if o.aur {
		a := make([dynamic]string, allocator)
		append(&a, "yay", "-Syu")
		append(&steps, Step{what = "aur-upgrade", argv = a[:], needs_root = false})
	}
	notes := make([dynamic]string, allocator)
	append(&notes, "full upgrade only; this program has no way to express a partial one")
	append(&notes, "pacman will ask its own questions on your terminal")
	return plan_finish(
		Plan{op = "upgrade", class = "mutate", steps = steps[:], notes = notes[:]},
	)
}

// ---------------------------------------------------------------------------
// diff and sync
// ---------------------------------------------------------------------------

Diff :: struct {
	declared:  []string,
	missing:   []string, // declared, not installed
	extra:     []string, // installed explicitly, not declared
	satisfied: []string,
	in_sync:   bool,
}

// diff_compute compares the declaration against the explicitly installed set.
// It deliberately compares against `-Qqe` and not against everything
// installed: a dependency pulled in by a declared package is not drift.
diff_compute :: proc(
	w: ^World,
	declared: []string,
	allocator := context.allocator,
) -> Diff {
	d := Diff{}
	missing := make([dynamic]string, allocator)
	satisfied := make([dynamic]string, allocator)
	extra := make([dynamic]string, allocator)

	want := make(map[string]bool, context.temp_allocator)
	for n in declared {
		want[n] = true
		if w.installed[n] {
			append(&satisfied, n)
		} else {
			append(&missing, n)
		}
	}
	for n in w.explicit {
		if !want[n] {
			append(&extra, n)
		}
	}
	slice.sort(missing[:])
	slice.sort(satisfied[:])
	slice.sort(extra[:])

	d.declared = declared
	d.missing = missing[:]
	d.satisfied = satisfied[:]
	d.extra = extra[:]
	d.in_sync = len(missing) == 0 && len(extra) == 0
	return d
}

Sync_Opts :: struct {
	prune:    bool, // also remove what is installed but not declared
	yes:      bool,
	aur:      bool,
	snapshot: bool,
	allow:    []Guard,
	sources:  map[string]Source,
}

// plan_sync converges the machine toward the declaration.
//
// Installing is the safe half and happens by default. Removing is not, so
// `sync` does not prune unless asked: a package missing from the declaration
// is far more often a declaration that has not caught up than a package that
// should go. With --prune it becomes destructive and takes the full removal
// treatment -- protected classes, dependants, --yes.
plan_sync :: proc(
	w: ^World,
	d: Diff,
	o: Sync_Opts,
	allocator := context.allocator,
) -> (
	Plan,
	Refusal,
) {
	steps := make([dynamic]Step, allocator)
	notes := make([dynamic]string, allocator)
	targets := make([dynamic]string, allocator)

	if len(d.missing) == 0 && (!o.prune || len(d.extra) == 0) {
		append(&notes, "nothing to do: the machine already matches the declaration")
		return plan_finish(
			Plan{op = "sync", class = "idempotent", steps = nil, notes = notes[:]},
		)
	}

	ip, iref := plan_install(
		w,
		d.missing,
		Install_Opts{aur = o.aur, snapshot = false, sources = o.sources},
		allocator,
	)
	if iref.refused {
		return Plan{}, iref
	}

	rp := Plan{}
	if o.prune && len(d.extra) > 0 {
		r, rref := plan_remove(
			w,
			d.extra,
			Remove_Opts{yes = o.yes, snapshot = false, allow = o.allow},
			allocator,
		)
		if rref.refused {
			return Plan{}, rref
		}
		rp = r
	}

	append(&targets, ..ip.targets)
	append(&targets, ..rp.targets)

	if o.snapshot && len(targets) > 0 {
		append(&steps, snapshot_step("sync", targets[:], allocator))
	}
	append(&steps, ..ip.steps)
	append(&steps, ..rp.steps)
	append(&notes, ..ip.notes)
	append(&notes, ..rp.notes)
	if !o.prune && len(d.extra) > 0 {
		append(
			&notes,
			fmt.aprintf(
				"%d packages are installed but not declared; `sync --prune --yes` would remove them, and `declare` would adopt them instead",
				len(d.extra),
			),
		)
	}

	class := o.prune && len(rp.steps) > 0 ? "destructive" : "mutate"
	return plan_finish(
		Plan {
			op = "sync",
			class = class,
			targets = targets[:],
			skipped = ip.skipped,
			steps = steps[:],
			notes = notes[:],
		},
	)
}

// ---------------------------------------------------------------------------
// rollback
// ---------------------------------------------------------------------------

Snapshot :: struct {
	number:      int,
	kind:        string,
	date:        string,
	description: string,
	from_palm:   bool,
}

// parse_snapper_list reads `snapper --config root list`, whose columns are
// separated by `|`.
parse_snapper_list :: proc(text: string, allocator := context.allocator) -> []Snapshot {
	out := make([dynamic]Snapshot, allocator)
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		if strings.index_byte(raw, '|') < 0 {
			continue
		}
		cols := strings.split(raw, "|", context.temp_allocator)
		if len(cols) < 2 {
			continue
		}
		num := strings.trim_space(cols[0])
		if num == "" || num == "#" {
			continue
		}
		n := 0
		ok := true
		for i in 0 ..< len(num) {
			if num[i] < '0' || num[i] > '9' {
				ok = false
				break
			}
			n = n * 10 + int(num[i] - '0')
		}
		if !ok {
			continue
		}
		s := Snapshot {
			number = n,
			kind   = strings.clone(strings.trim_space(cols[1]), allocator),
		}
		if len(cols) >= 4 {
			s.date = strings.clone(strings.trim_space(cols[3]), allocator)
		}
		if len(cols) >= 6 {
			s.description = strings.clone(strings.trim_space(cols[len(cols) - 2]), allocator)
		}
		s.from_palm = strings.has_prefix(s.description, "palm pkg ")
		append(&out, s)
	}
	return out[:]
}

Rollback_Opts :: struct {
	yes:         bool,
	interactive: bool,
}

// plan_rollback is as interactive as upgrade, and for a sharper reason: a
// snapper rollback on this machine swaps the root subvolume and needs a
// reboot, which limine-snapper-sync has already written boot entries for. An
// agent cannot be the thing that reboots the machine it is working on.
plan_rollback :: proc(
	number: int,
	o: Rollback_Opts,
	allocator := context.allocator,
) -> (
	Plan,
	Refusal,
) {
	if number <= 0 {
		return Plan{}, refuse(
			EXIT_USAGE,
			"no-snapshot",
			"name the snapshot to return to; `palm pkg snapshots` lists the ones palm took",
		)
	}
	if !o.interactive {
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			"needs-a-person",
			"a rollback replaces the root subvolume and needs a reboot to take effect. Run it from a terminal.",
		)
	}
	if !o.yes {
		return Plan{}, refuse(
			EXIT_NEEDS_YES,
			"needs-yes",
			"rollback is destructive: everything written to / since that snapshot goes. Pass --yes.",
		)
	}
	argv := make([dynamic]string, allocator)
	append(&argv, "sudo", "snapper", "--config", "root", "rollback", fmt.aprintf("%d", number))
	notes := make([dynamic]string, allocator)
	append(&notes, "takes effect at the next boot; limine-snapper-sync keeps the boot entries in step")
	steps := make([dynamic]Step, allocator)
	append(&steps, Step{what = "rollback", argv = argv[:], needs_root = true})
	return plan_finish(
		Plan{op = "rollback", class = "destructive", steps = steps[:], notes = notes[:]},
	)
}
