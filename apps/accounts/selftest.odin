package main

// `accounts --selftest`: the helpers, an offscreen render of every page, the
// cloudkit self-test, and — when cloud/dev is up — the app's own flows
// against it, in a throwaway token store and a throwaway account.

import "core:fmt"
import "core:math/rand"
import "core:os"
import ck "../cloudkit"
import p "palmy:."

@(private = "file")
pass, failed: int

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		pass += 1
		fmt.eprintfln("ok   %s", fmt.tprintf(what, ..args))
	} else {
		failed += 1
		fmt.eprintfln("FAIL %s", fmt.tprintf(what, ..args))
	}
}

cli_selftest :: proc() -> int {
	// Helpers.
	check(handle_from("Alex at Northwind") == "alex.at.northwind", "handle_from: spaces become dots")
	check(handle_from("  Émile -- O'Brien!! ") == "mile.obrien", "handle_from: drops what a handle cannot hold (%q)", handle_from("  Émile -- O'Brien!! "))
	check(initials("Alex Rivera") == "AR" && initials("bob") == "B" && initials("") == "?", "initials")
	check(short_time("2026-10-19T10:04:00Z") == "19 Oct, 10:04", "short_time (%s)", short_time("2026-10-19T10:04:00Z"))

	// Every page renders, signed out and in, without a network.
	{
		off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground overflow-hidden")
		defer p.offscreen_destroy(off)
		shot_fonts(off)
		st := new(St)
		st_init(st)
		st.fixture = true
		render :: proc(off: ^p.Offscreen, st: ^St) -> int {
			ui := p.offscreen_begin(off)
			frame(st, ui)
			nodes := len(ui.nodes)
			p.offscreen_end(off)
			return nodes
		}
		check(render(off, st) > 30, "the sign-in screen renders")
		fixture(st)
		for v in View {
			st.view = v
			render(off, st)
			check(render(off, st) > 40, "page %v renders", v)
		}
	}

	// cloudkit, offline and (if the stack is up) live.
	cp, cf := ck.selftest(quiet = true)
	check(cf == 0, "cloudkit self-test: %d passed, %d failed", cp, cf)

	live_flows()
	fmt.eprintfln("accounts selftest: %d passed, %d failed", pass, failed)
	return failed == 0 ? 0 : 1
}

@(private = "file")
live_flows :: proc() {
	dir := fmt.tprintf("/tmp/accounts-selftest-%d-%x", os.get_pid(), rand.uint32())
	defer os.remove_all(dir)
	st := new(St)
	st_init(st)
	c, _ := ck.open(dir = dir, scope = "", app = "accounts-selftest")
	st.c = c
	if _, e := ck.call(c, "GET", "/auth/v1/health", "", auth = false, allocator = context.temp_allocator); e.kind == .Unavailable {
		fmt.eprintfln("skip live flows: no stack at %s", c.url_text)
		return
	}
	tag := fmt.tprintf("%x", rand.uint32())
	email := fmt.tprintf("accounts-%s@palm.test", tag)
	e := act_create_account(st, email, "selftest password", "Self Test", fmt.tprintf("self-%s", tag))
	check(ck.ok(e) && st.signed_in && len(st.ids) == 1, "create the account and its first identity")
	check(st.current == fmt.tprintf("self-%s", tag), "the first identity is current")

	work: ck.Identity
	work, e = act_create_identity(st, fmt.tprintf("work-%s", tag), "Self at work", "work", "sky")
	check(ck.ok(e) && len(st.ids) == 2, "create a second identity")
	e = act_switch(st, work.handle)
	check(ck.ok(e) && st.current == work.handle && st.stored[work.handle], "switching stores a session scoped to it")

	// The scoped view of the same account.
	sst := new(St)
	st_init(sst)
	sc_, _ := ck.open(dir = dir, scope = work.handle, app = "accounts-selftest")
	sst.c = sc_
	reload(sst)
	check(sst.signed_in && len(sst.ids) == 1 && sst.scope.id == work.id, "PALM_IDENTITY=work sees work alone, and knows it is scoped")
	_, e = act_create_identity(sst, fmt.tprintf("sneak-%s", tag), "Sneak", "work", "rose")
	check(e.kind == .Out_Of_Scope, "scoped: creating an identity is refused")
	home, _ := ck.find_identity(st.ids, fmt.tprintf("self-%s", tag))
	_, e = act_delegate(sst, home, "escape", "assistant", 0)
	check(e.kind == .Out_Of_Scope, "scoped: delegating is refused")

	m: ck.Minted
	m, e = act_delegate(st, work, "Selftest assistant", "assistant", 3600)
	check(ck.ok(e) && len(st.devs) == 2, "delegate an assistant (%d devices)", len(st.devs))
	check(len(st.sess) == 3, "three sessions: this one, the switch, the assistant (got %d)", len(st.sess))
	e = act_revoke(st, m.device_id)
	check(ck.ok(e), "revoke the assistant")
	active := 0
	for d in st.devs {
		if d.active {
			active += 1
		}
	}
	check(active == 1, "one delegation still active")
	e = act_sign_out(st)
	check(ck.ok(e) && !st.signed_in, "sign out")
	e = act_sign_in(st, email, "selftest password")
	check(ck.ok(e) && st.signed_in, "sign in again")
	_, e = ck.archive_identity(st.c, work.id, context.temp_allocator)
	reload(sst)
	check(!sst.signed_in || len(sst.ids) == 0, "archiving work ends the session scoped to it")
	act_sign_out(st)
}
