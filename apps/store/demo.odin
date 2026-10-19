package main

// `store --demo` and `store --shots`: fabricated data, and a stand-in palmd.
//
// The catalogue below is shaped like a fresh Palmy machine -- the
// default applications installed as part of `palmy`, a few more in the
// repository, two updates waiting -- so the screenshots show what a real
// first look at Software is like. A handful of entries (audio, video,
// solitaire) are there only so every shelf in Discover has something on it.
// None of it is read from the machine the demo runs on.
//
// The stand-in daemon plans from this catalogue and plays the progress back
// on a clock, so the confirmation dialog and the progress bar can be seen
// and driven without root, palmd or a repository.

import "core:fmt"
import "core:slice"
import "core:strings"

@(private = "file")
Demo_Pkg :: struct {
	name, cat, icon, summary, details: string,
	size:                              i64,
	deps:                              string,
	installed:                         bool,
	explicit:                          bool,
	upgrade_to:                        string,
	app:                               bool,
}

@(private = "file")
DEMO := [?]Demo_Pkg {
	{"palmy", "System", "monitor", "The Palmy system: kernel, init, login, window manager and the default applications", "Everything a Palmy machine has after installation.", 0, "palmy-base linux busybox glibc palm palm-init palm-login palmd palmy-wm greeter fonts term launcher files editor notes calc sysmon image docs sheets slides calendar reader photoshop maps money torrent store", true, true, "", false},
	{"palmy-base", "System", "hard-drive", "The Palmy filesystem layout, users and base configuration", "The skeleton every other package stands on.", 4_934, "", true, false, "", false},
	{"linux", "System", "server", "The Linux kernel, Palmy configuration", "Linux 6.18 LTS with everything built in: no modules, no initramfs.", 14_764_000, "", true, false, "", false},
	{"busybox", "System", "terminal", "Tiny versions of many common UNIX utilities in a single static binary", "The shell and the command-line userland in one statically linked program.", 2_538_648, "palmy-base", true, false, "", false},
	{"glibc", "System", "binary", "GNU C Library runtime (from the build host)", "The C library and dynamic loader every palmy program links against.", 3_746_560, "palmy-base", true, false, "", false},
	{"palm", "System", "package", "The Palmy package manager", "palm installs, removes and upgrades packages from signed repositories.", 1_402_112, "palmy-base glibc", true, false, "0.1.1-r0", true},
	{"palm-init", "System", "activity", "Palmy's init and service supervisor", "PID 1: mounts, device permissions, services and shutdown.", 1_210_480, "palmy-base busybox", true, false, "", false},
	{"palm-login", "System", "lock-keyhole", "Palmy's login manager (greetd protocol)", "Runs the login screen and starts your session.", 1_640_224, "palmy-base glibc", true, false, "", false},
	{"palmd", "System", "shield-check", "Lets members of wheel install and remove software", "The root daemon behind Software: it answers only root and group wheel.", 702_976, "palmy-base glibc palm", true, false, "", true},
	{"palmy-wm", "System", "layout-grid", "The palmy Wayland window manager", "A tiling and floating Wayland compositor.", 3_102_448, "glibc fonts", true, false, "", false},
	{"greeter", "System", "user", "The palmy login screen", "The screen you log in on.", 2_240_512, "glibc fonts", true, false, "", true},
	{"fonts", "System", "type", "Geist, JetBrains Mono and DejaVu Sans: the fonts every palmy application uses", "palmy finds fonts by walking /usr/share/fonts.", 6_051_219, "", true, false, "", false},
	{"fonts-emoji", "System", "sparkles", "Noto Color Emoji", "Colour emoji for every palmy application.", 10_784_256, "", false, false, "", false},
	{"term", "System", "square-terminal", "The palmy terminal", "A terminal with tabs. It runs your shell, follows the system theme, and was checked against ghostty cell by cell.", 1_884_160, "glibc fonts busybox", true, false, "0.1.1-r0", true},
	{"launcher", "System", "layout-grid", "Application launcher", "Type a few letters of an application's name and press Return.", 1_011_712, "glibc fonts", true, false, "", true},
	{"sysmon", "System", "activity", "System monitor", "CPU, memory, disks and processes, read straight from /proc and /sys.", 1_232_896, "glibc fonts", true, false, "", true},
	{"store", "System", "package", "Find, install and update software", "Discover applications by category, search, install and remove them, and keep the system up to date.", 1_525_760, "glibc fonts palm palmd", true, false, "", true},
	{"files", "Accessories", "folder", "File manager", "Browse folders in a list or as icons, with a sidebar of places, breadcrumbs, live filtering and an inspector for the selected file.", 1_392_640, "glibc fonts", true, false, "", true},
	{"calc", "Accessories", "calculator", "Calculator", "A calculator that shows the whole expression as you type it, and keeps a history of what you worked out.", 931_416, "glibc fonts", true, false, "", true},
	{"maps", "Accessories", "map-pin", "Maps", "Explore a generated city offline: pan, zoom and search its streets.", 1_101_824, "glibc fonts", true, false, "", true},
	{"emoji", "Accessories", "sparkles", "Emoji picker", "Browse and search every emoji by name. Pair it with fonts-emoji for colour.", 1_204_224, "glibc fonts", false, false, "", true},
	{"editor", "Development", "code", "Text editor", "A plain-text editor for code and notes, with syntax colouring.", 1_474_560, "glibc fonts", true, false, "", true},
	{"track", "Development", "flag", "Time tracker", "Issues kept as plain files in a directory, with a command line for agents and people alike.", 890_880, "glibc fonts", true, true, "", true},
	{"pickdemo", "Development", "calendar-days", "Date and colour picker demo", "A demonstration of palmy's date, colour and file pickers.", 1_150_976, "glibc fonts", false, false, "", true},
	{"image", "Graphics", "image", "Image viewer", "Open PNG, JPEG and other images, zoom, and step through the rest of the folder.", 1_036_288, "glibc fonts", true, false, "", true},
	{"photoshop", "Graphics", "palette", "Image editor", "A raster image editor with layers, brushes and selections.", 2_105_344, "glibc fonts", true, false, "", true},
	{"torrent", "Internet", "download", "BitTorrent client", "Download and share files over BitTorrent, with magnet links and per-file progress.", 1_683_456, "glibc fonts", true, false, "", true},
	{"shop", "Internet", "tag", "Shop demo", "A demonstration storefront: a catalogue, a basket and a checkout that sells nothing.", 1_048_576, "glibc fonts", false, false, "", true},
	{"audio", "Multimedia", "music", "Music player", "Play your music library. Needs ffmpeg and PipeWire, which Palmy does not ship yet.", 1_310_720, "glibc fonts", false, false, "", true},
	{"video", "Multimedia", "film", "Video player", "Play video files. Needs ffmpeg and PipeWire, which Palmy does not ship yet.", 1_441_792, "glibc fonts", false, false, "", true},
	{"solitaire", "Games", "star", "Klondike solitaire", "The card game, drawn with palmy. (A placeholder in the demo catalogue.)", 655_360, "glibc fonts", false, false, "", true},
	{"notes", "Office", "notebook-pen", "Markdown notes", "Markdown notes kept as plain files under your home directory.", 1_253_376, "glibc fonts", true, false, "", true},
	{"docs", "Office", "file-text", "Documents", "A word processor for writing documents, with a prose checker that suggests plainer wording.", 2_621_440, "glibc fonts prose", true, false, "", true},
	{"prose", "Office", "type", "The prose engine behind docs (command line)", "The engine behind the docs app's prose checker, as a command.", 1_835_008, "glibc", true, false, "", true},
	{"sheets", "Office", "file-spreadsheet", "Spreadsheets", "A spreadsheet with formulas, formatting and CSV import and export.", 1_966_080, "glibc fonts", true, false, "", true},
	{"slides", "Office", "presentation", "Presentations", "Make presentations from simple slides, and present them full screen.", 1_572_864, "glibc fonts", true, false, "", true},
	{"calendar", "Office", "calendar", "Calendar", "Your events by day, week and month, stored locally.", 1_179_648, "glibc fonts", true, false, "", true},
	{"reader", "Office", "book-open", "PDF and e-book reader", "Read EPUB books and plain text, with your place remembered.", 1_376_256, "glibc fonts", true, false, "", true},
	{"money", "Office", "credit-card", "Personal finance", "A personal ledger: accounts, transactions and where the money went.", 1_138_688, "glibc fonts", true, false, "", true},
}

demo_catalog :: proc(c: ^Catalog) {
	pkgs := make([dynamic]Package)
	for d in DEMO {
		p: Package
		p.name = d.name
		p.version = d.upgrade_to != "" ? d.upgrade_to : (d.name == "linux" ? "6.18.56-r0" : (d.name == "busybox" ? "1.37.0-r0" : (d.name == "glibc" ? "2.44-r0" : "0.1.0-r0")))
		p.summary = d.summary
		p.details = d.details
		p.license = d.name == "linux" || d.name == "busybox" ? "GPL-2.0-only" : (d.name == "glibc" ? "LGPL-2.1-or-later" : (d.name == "fonts" ? "OFL-1.1 AND Bitstream-Vera" : "MIT"))
		p.url = d.name == "linux" ? "https://kernel.org" : ""
		p.category = d.cat
		p.icon = d.icon
		p.size = d.size
		p.csize = d.size * 45 / 100
		p.depends = strings.fields(d.deps)
		if d.app {
			p.provides = slice.clone([]string{fmt.aprintf("cmd:%s", d.name)})
		}
		if d.installed {
			p.installed = d.upgrade_to != "" ? "0.1.0-r0" : p.version
			p.installed_size = d.size
			p.explicit = d.explicit
			p.upgradable = d.upgrade_to != ""
		}
		if d.name == "track" || d.name == "calc" {
			files := make([dynamic]string)
			append(&files, fmt.aprintf("/usr/bin/%s", d.name))
			if d.name == "calc" {
				append(&files, "/usr/share/applications/calc.desktop")
			}
			p.files = files[:]
			p.files_loaded = true
		}
		append(&pkgs, p)
	}
	catalog_set(c, pkgs)
	for &p in c.pkgs {
		p.required_by = slice.clone(rdeps_local(c, &p))
		for &s in p.required_by {s = strings.clone(s)}
		p.info_loaded = true
	}
}

// demo_files is what `palm info -L` would say for the demo's packages.
demo_files :: proc(p: ^Package) {
	if p.files_loaded {return}
	files := make([dynamic]string)
	if command_of(p) != "" {
		append(&files, fmt.aprintf("/usr/bin/%s", p.name))
		append(&files, fmt.aprintf("/usr/share/applications/%s.desktop", p.name))
	} else {
		append(&files, fmt.aprintf("/usr/share/%s/README", p.name))
	}
	p.files = files[:]
	p.files_loaded = true
}

// ---------------------------------------------------------------------------
// The stand-in palmd
// ---------------------------------------------------------------------------

@(private = "file")
g_demo_catalog: ^Catalog

demo_attach :: proc(c: ^Catalog) {
	g_demo_catalog = c
}

// demo_plan resolves the way palm would, near enough for a picture: an add
// brings in whatever it depends on that is not installed, a del removes the
// package, an upgrade is every upgradable package.
demo_plan :: proc(c: ^Catalog, action: Action, names: []string) -> Plan {
	install := make([dynamic]Plan_Item)
	upgrade := make([dynamic]Plan_Item)
	remove := make([dynamic]Plan_Item)
	seen := make(map[string]bool, context.temp_allocator)
	add :: proc(c: ^Catalog, name: string, seen: ^map[string]bool, out: ^[dynamic]Plan_Item) {
		if seen[name] {return}
		seen[name] = true
		p := find(c, name)
		if p == nil || p.installed != "" {return}
		for d in p.depends {add(c, dep_name(d), seen, out)}
		append(out, Plan_Item{name = p.name, version = p.version, size = p.size, csize = p.csize})
	}
	switch action {
	case .Add:
		for n in names {add(c, n, &seen, &install)}
	case .Del:
		for n in names {
			if p := find(c, n); p != nil && p.installed != "" {
				append(&remove, Plan_Item{name = p.name, version = p.installed, size = p.installed_size})
			}
		}
	case .Upgrade:
		for p in upgradable(c) {
			append(&upgrade, Plan_Item{name = p.name, version = p.version, from = p.installed, size = p.size, csize = p.csize})
		}
	case .Update:
	}
	plan := Plan{install = install[:], upgrade = upgrade[:], remove = remove[:]}
	for it in plan.install {
		plan.download += it.csize
		plan.size_change += it.size
	}
	for it in plan.upgrade {
		plan.download += it.csize
	}
	for it in plan.remove {
		plan.size_change -= it.size
	}
	return plan
}

demo_begin :: proc(t: ^Txn) {
	if t.action == .Update {
		t.stage = .Applying
		t.current = strings.clone("Checking the repositories")
		t.demo_at = -1
		return
	}
	t.plan = demo_plan(g_demo_catalog, t.action, t.packages)
	t.plan_id = strings.clone("0123456789abcdef0123456789abcdef")
	t.stage = .Confirm
}

demo_confirm :: proc(t: ^Txn) {
	t.steps = 2 * (len(t.plan.install) + len(t.plan.upgrade)) + len(t.plan.remove)
	t.demo_at = -1
}

// demo_poll advances the fake transaction by one step every half second.
demo_poll :: proc(t: ^Txn, now: f64) -> bool {
	if t.stage != .Applying {
		return false
	}
	if t.demo_at < 0 {
		t.demo_at = now
	}
	if t.action == .Update {
		if now - t.demo_at > 0.8 {
			t.stage = .Done
			return true
		}
		return false
	}
	want := int((now - t.demo_at) / 0.5) + 1
	changes := make([dynamic]Plan_Item, context.temp_allocator)
	append(&changes, ..t.plan.install)
	append(&changes, ..t.plan.upgrade)
	for t.step < min(want, t.steps) {
		t.step += 1
		s := t.step
		n := len(changes)
		switch {
		case s <= n:
			t.current = strings.clone(progress_words("fetch", changes[s - 1].name, changes[s - 1].version))
		case s <= n + len(t.plan.remove):
			it := t.plan.remove[s - n - 1]
			t.current = strings.clone(progress_words("remove", it.name, it.version))
		case:
			it := changes[s - n - len(t.plan.remove) - 1]
			t.current = strings.clone(progress_words(it.from != "" ? "upgrade" : "install", it.name, it.version))
		}
	}
	if t.step >= t.steps && now - t.demo_at > 0.5 * f64(t.steps) + 0.3 {
		demo_commit(g_demo_catalog, t.plan)
		t.stage = .Done
		return true
	}
	return false
}

// demo_commit makes the catalogue say what palm would say afterwards.
demo_commit :: proc(c: ^Catalog, plan: Plan) {
	for it in plan.install {
		if p := find(c, it.name); p != nil {
			p.installed = p.version
			p.installed_size = p.size
			p.explicit = true
		}
	}
	for it in plan.upgrade {
		if p := find(c, it.name); p != nil {
			p.installed = p.version
			p.upgradable = false
		}
	}
	for it in plan.remove {
		if p := find(c, it.name); p != nil {
			p.installed = ""
			p.explicit = false
		}
	}
	for &p in c.pkgs {
		p.required_by = slice.clone(rdeps_local(c, &p))
	}
}
