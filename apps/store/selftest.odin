package main

// store --selftest
//
// What can be checked without a window or a root daemon:
//
//   - decoding palm's --json shapes, the new store fields included, and
//     surviving an older palm that has none of them;
//   - the catalogue's questions: categories, live search ranking, installed
//     and explicit, upgradable, reverse dependencies, Featured;
//   - the palmd conversation: request JSON, plan decoding, progress, palm's
//     error verbatim, a refused stale plan, over a real socketpair standing in
//     for /run/palmd.sock;
//   - the demo daemon's plan and its commit;
//   - every view and every dialog stage drawn offscreen without a crash.

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
g_fail := 0
@(private = "file")
g_count := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	g_count += 1
	if !ok {
		g_fail += 1
		fmt.printf("  FAIL: ")
		fmt.printfln(what, ..args)
	}
}

selftest :: proc() -> int {
	test_decode()
	test_catalog()
	test_protocol()
	test_demo()
	test_draw()
	fmt.printfln("store --selftest: %d assertions, %d failures", g_count, g_fail)
	return g_fail == 0 ? 0 : 1
}

// What `palm list --json` prints, store fields and all, for three packages.
LIST_JSON :: `[
{"name":"calc","version":"0.1.0-r0","description":"Calculator","license":"MIT","url":"","size":931416,"csize":402598,"category":"Accessories","icon":"calculator","details":"First paragraph.\nSecond.","depends":["glibc","fonts"],"provides":["cmd:calc"],"installed":"0.1.0-r0","installed_size":931416,"explicit":false},
{"name":"glibc","version":"2.44-r0","description":"GNU C Library runtime","license":"LGPL-2.1-or-later","url":"https://www.gnu.org/software/libc","size":3746560,"csize":1781430,"category":"System","icon":"binary","details":"","depends":["palmframe-base"],"provides":["so:libc.so.6"],"installed":"2.44-r0","installed_size":3746560,"explicit":false},
{"name":"track","version":"0.1.0-r0","description":"Time tracker","license":"MIT","url":"","size":890880,"csize":400000,"category":"Development","icon":"flag","details":"Issues as files.","depends":["glibc"],"provides":["cmd:track"],"installed":null,"explicit":false},
{"name":"palmframe","version":"0.1.0-r0","description":"The system","license":"MIT","url":"","size":0,"csize":900,"category":"System","icon":"monitor","details":"","depends":["glibc","calc"],"provides":[],"installed":"0.1.0-r0","installed_size":0,"explicit":true}
]`

// What an older palm printed: no category, icon, details, csize or explicit.
OLD_JSON :: `[{"name":"term","version":"0.1.0-r0","description":"The palmy terminal","license":"MIT","size":1843200,"depends":["glibc"],"provides":["cmd:term"],"installed":"0.1.0-r0"}]`

@(private = "file")
test_decode :: proc() {
	pkgs, ok := parse_package_list(LIST_JSON)
	check(ok && len(pkgs) == 4, "palm list --json decodes (%d)", len(pkgs))
	if len(pkgs) < 4 {return}
	c := pkgs[0]
	check(c.name == "calc" && c.category == "Accessories" && c.icon == "calculator", "store fields decode")
	check(c.details == "First paragraph.\nSecond.", "details keeps its paragraphs")
	check(c.size == 931416 && c.csize == 402598 && c.installed_size == 931416, "sizes decode")
	check(c.installed == "0.1.0-r0" && !c.explicit, "installed, as a dependency")
	check(pkgs[2].installed == "", "null installed is not installed")
	check(pkgs[3].explicit, "explicit decodes")
	check(command_of(&pkgs[0]) == "calc" && command_of(&pkgs[1]) == "", "Open needs cmd:<name>")

	old, ok2 := parse_package_list(OLD_JSON)
	check(ok2 && len(old) == 1, "an older palm's JSON still decodes")
	if len(old) == 1 {
		check(old[0].category == "" && old[0].icon == "" && old[0].csize == 0, "missing fields are empty, not errors")
	}
	// Every icon a recipe in distro/recipes names is drawn, not the package
	// fallback (the runtime packages and their applications brought these).
	for n in ([]string{"archive", "audio-lines", "bluetooth", "bot", "clapperboard", "clipboard", "cpu", "key-round", "layers", "mail", "network", "phone", "scan-text", "sliders-horizontal", "volume-2", "wifi"}) {
		check(icon_named(n).name == n, "Software draws the icon %q", n)
	}
	_, bad := parse_package_list(`{"ok":false,"code":6,"error":"x"}`)
	check(!bad, "an error object is not a package list")
	check(palm_failure({out = `{"ok":false,"code":3,"error":"nosuch: no such package"}`, code = 3, ok = true}) == "nosuch: no such package", "palm's error is taken verbatim")

	check(human_size(931416) == "931 kB", "931416 is 931 kB (%s)", human_size(931416))
	check(human_size(3746560) == "3.7 MB", "3746560 is 3.7 MB (%s)", human_size(3746560))
	check(human_size(512) == "512 B", "512 B")
	check(version_short("0.1.0-r0") == "0.1.0" && version_short("6.18.56") == "6.18.56", "the release is hidden for display")
	check(dep_name("libgui>=2") == "libgui" && dep_name("glibc") == "glibc" && dep_name("x~1.2") == "x", "constraints reduce to names")
}

@(private = "file")
test_catalog :: proc() {
	cat: Catalog
	pkgs, _ := parse_package_list(LIST_JSON)
	catalog_set(&cat, pkgs)
	check(cat.pkgs[0].name == "calc" && cat.pkgs[len(cat.pkgs) - 1].name == "track", "the catalogue is sorted by name")
	check(len(in_category(&cat, "System")) == 2, "two System packages")
	sys := in_category(&cat, "System")
	check(len(sys) == 2, "System shelf")
	check(len(installed(&cat, false)) == 3 && len(installed(&cat, true)) == 1, "installed, and installed by you")
	hits := search(&cat, "CALC")
	check(len(hits) == 1 && hits[0].name == "calc", "search ignores case")
	hits = search(&cat, "library gnu")
	check(len(hits) == 1 && hits[0].name == "glibc", "every word must match, in any order")
	hits = search(&cat, "development")
	check(len(hits) == 1 && hits[0].name == "track", "search reads the category")
	hits = search(&cat, "c")
	check(len(hits) > 1 && hits[0].name == "calc", "a name that starts with the query ranks first (%s)", len(hits) > 0 ? hits[0].name : "")
	check(len(search(&cat, "zzzz")) == 0, "no matches")

	calc := find(&cat, "calc")
	rd := rdeps_local(&cat, calc)
	check(len(rd) == 1 && rd[0] == "palmframe", "calc is required by palmframe (%v)", rd)
	glibc := find(&cat, "glibc")
	rd = rdeps_local(&cat, glibc)
	check(len(rd) == 2, "glibc is required by calc and palmframe (%v)", rd)
	feat := featured(&cat, 3)
	check(len(feat) >= 1 && feat[0].name == "track", "Featured prefers what is not installed")
	check(is_dir_entry("/usr/bin", {"/usr", "/usr/bin", "/usr/bin/calc"}) && !is_dir_entry("/usr/bin/calc", {"/usr/bin/calc"}), "parent directories are told from files")
}

@(private = "file")
frame_bytes :: proc(payload: string) -> []u8 {
	n := u32(len(payload))
	hdr := transmute([4]u8)n
	out := make([]u8, 4 + len(payload), context.temp_allocator)
	copy(out, hdr[:])
	copy(out[4:], payload)
	return out
}

@(private = "file")
test_protocol :: proc() {
	req := request_json("plan", .Add, {"track", "emo\"ji"}, "")
	check(req == `{"op":"plan","action":"add","packages":["track","emo\"ji"]}`, "plan request: %s", req)
	req = request_json("apply", .Del, {"track"}, "0123456789abcdef0123456789abcdef")
	check(strings.has_suffix(req, `"plan_id":"0123456789abcdef0123456789abcdef"}`), "apply carries the plan id")

	// A socketpair stands in for /run/palmd.sock: one end is the
	// transaction's, the other plays palmd.
	pair: [2]linux.Fd
	if linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair) != .NONE {
		check(false, "socketpair")
		return
	}
	defer linux.close(pair[1])
	fl, _ := linux.fcntl_getfl(pair[0], .GETFL)
	linux.fcntl_setfl(pair[0], .SETFL, fl + {.NONBLOCK})
	t: Txn
	t.fd = pair[0]
	t.stage = .Planning
	t.action = .Add
	t.packages = clone_strings({"track"})
	daemon :: proc(fd: linux.Fd, payload: string) {
		linux.write(fd, frame_bytes(payload))
	}
	daemon(pair[1], `{"type":"plan","plan_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","plan":{"install":[{"name":"fonts","version":"0.1.0-r0","size":6051219,"csize":3263113},{"name":"track","version":"0.1.0-r0","size":890880,"csize":400000}],"upgrade":[],"remove":[{"name":"shop","version":"0.1.0-r0","size":1000}],"download_size":3663113,"size_change":6941099,"dry_run":true}}`)
	txn_poll(&t, 0)
	check(t.stage == .Confirm, "a plan reply asks for confirmation (%v)", t.stage)
	check(t.plan_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "the plan id is kept")
	check(len(t.plan.install) == 2 && t.plan.install[1].name == "track" && len(t.plan.remove) == 1, "the plan's lists decode")
	check(t.plan.download == 3663113 && t.plan.size_change == 6941099, "the plan's sizes decode")
	s := plan_sentence(t.plan)
	check(s == "will install fonts, track; will remove shop; download 3.7 MB", "the plan in one line: %s", s)

	txn_confirm(&t)
	check(t.stage == .Applying, "confirming applies")
	buf: [512]u8
	n, _ := linux.read(pair[1], buf[:])
	sent := n > 4 ? string(buf[4:n]) : ""
	check(strings.contains(sent, `"op":"apply"`) && strings.contains(sent, `"plan_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`), "the apply names the plan that was shown: %s", sent)

	daemon(pair[1], `{"type":"progress","event":"fetch","name":"track","version":"0.1.0-r0","step":1,"steps":4}`)
	daemon(pair[1], `{"type":"log","line":"palm: warning: track expects the user \"nobody\""}`)
	txn_poll(&t, 0)
	check(t.step == 1 && t.steps == 4 && t.current == "Downloading track 0.1.0", "progress moves the bar: %q", t.current)
	check(len(t.log) == 1 && strings.contains(t.log[0], "expects the user"), "palm's warnings are kept verbatim")
	daemon(pair[1], `{"type":"result","ok":false,"code":4,"error":"track-0.1.0-r0.palm: sha256 mismatch; refusing"}`)
	finished := txn_poll(&t, 0)
	check(finished && t.stage == .Failed && t.code == 4, "a failed result fails the transaction")
	check(t.error == "track-0.1.0-r0.palm: sha256 mismatch; refusing", "palm's error is shown exactly: %q", t.error)
	check(t.fd == 0, "the connection is closed afterwards")

	// palmd refusing the connection outright.
	t2: Txn
	if linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair) == .NONE {
		t2.fd = pair[0]
		t2.stage = .Planning
		daemon(pair[1], `{"type":"error","error_type":"denied","code":4,"error":"palmd: only root and members of group wheel may change the system"}`)
		txn_poll(&t2, 0)
		check(t2.stage == .Failed && strings.contains(t2.error, "group wheel"), "a refusal reaches the dialog: %q", t2.error)
		linux.close(pair[1])
	}

	// No daemon at all.
	fd, why := dial_palmd("/nonexistent/palmd.sock")
	check(fd == 0 && strings.contains(why, "not running"), "a missing palmd is explained: %s", why)
}

@(private = "file")
test_demo :: proc() {
	cat := new(Catalog)
	demo_catalog(cat)
	demo_attach(cat)
	check(len(cat.pkgs) > 30, "the demo catalogue is a whole system (%d)", len(cat.pkgs))
	for c in CATEGORIES {
		check(len(in_category(cat, c)) > 0, "the demo has something on the %s shelf", c)
	}
	plan := demo_plan(cat, .Add, {"emoji"})
	check(len(plan.install) == 1 && plan.install[0].name == "emoji", "adding emoji installs emoji")
	up := demo_plan(cat, .Upgrade, nil)
	check(len(up.upgrade) == 2, "two updates are waiting (%d)", len(up.upgrade))
	demo_commit(cat, plan)
	e := find(cat, "emoji")
	check(e.installed != "" && e.explicit, "after the commit emoji is installed, by you")
	term := find(cat, "term")
	check(len(term.required_by) == 1 && term.required_by[0] == "palmframe", "term is part of palmframe")
}

// test_draw renders every view and every dialog stage once, offscreen.
@(private = "file")
test_draw :: proc() {
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	sc.register_shadcn_theme(false)
	p.register_color("selection", p.hex(SELECTION))
	st := new(State)
	st.demo = true
	state_init(st)
	draw :: proc(off: ^p.Offscreen, st: ^State) -> bool {
		ui := p.offscreen_begin(off)
		tick(ui, st)
		handle_keys(ui, st)
		frame(ui, st)
		n := len(ui.nodes)
		p.offscreen_end(off)
		return n > 20
	}
	views := [?]Nav{{view = .Discover}, {view = .Category, category = "Office"}, {view = .Installed}, {view = .Updates}, {view = .Package, pkg = "term"}, {view = .Package, pkg = "nosuch"}}
	for v in views {
		go(st, v)
		check(draw(off, st), "%v draws", v.view)
	}
	append(&st.query, ..transmute([]u8)string("calc"))
	sync_search(st)
	check(st.nav.view == .Search && draw(off, st), "search draws")
	clear(&st.query)
	sync_search(st)
	check(st.nav.view != .Search, "emptying the query leaves search")

	start_change(st, .Add, "emoji")
	check(st.txn.stage == .Confirm && draw(off, st), "the plan dialog draws")
	txn_confirm(&st.txn)
	check(draw(off, st), "the progress dialog draws")
	for _ in 0 ..< 400 {
		if st.txn.stage == .Done {break}
		draw(off, st)
	}
	check(st.txn.stage == .Done && draw(off, st), "the demo install finishes (%v)", st.txn.stage)
	check(find(&st.cat, "emoji").installed != "", "and emoji shows as installed")
	txn_reset(&st.txn)
	txn_fail(&st.txn, "an error", 7)
	check(draw(off, st), "the error dialog draws")
}
