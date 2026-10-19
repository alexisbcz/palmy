// `mail --selftest`, the Palmy part.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// test_palmy reads a palmy.conf the way `mailcore palm sync` writes it
// and checks the views: one identity at a time by default, all of them on 0,
// and the prototype unified inbox only behind its toggle — and never a
// message from one identity listed under another.
test_palmy :: proc() {
	dir := fmt.tprintf("%s/selftest-palm", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	one :: proc(subject, id, to: string) -> string {
		return fmt.tprintf(
			"Date: Mon, 19 Oct 2026 09:00:00 +0000\r\nFrom: Bob <bob@palm.test>\r\nTo: %s\r\nSubject: %s\r\nMessage-ID: <%s>\r\n\r\nbody\r\n",
			to,
			subject,
			id,
		)
	}
	for who in ([]string{"alice@palm.test", "alice.work@palm.test"}) {
		root := fmt.tprintf("%s/%s", dir, who)
		maildir_make(root)
		maildir_make(fmt.tprintf("%s/.Sent", root))
		maildir_make(fmt.tprintf("%s/.Outbox", root))
		write_file(fmt.tprintf("%s/new/1.M1P1.t", root), transmute([]u8)one(fmt.tprintf("For %s", who), fmt.tprintf("%s-1@t", who), who))
		write_file(fmt.tprintf("%s/cur/2.M2P1.t:2,S", root), transmute([]u8)one(fmt.tprintf("Also for %s", who), fmt.tprintf("%s-2@t", who), who))
	}
	// Same Message-ID in both identities: the same mail delivered to both.
	write_file(fmt.tprintf("%s/alice@palm.test/new/3.M3P1.t", dir), transmute([]u8)one("Shared", "shared@t", "alice@palm.test"))
	write_file(fmt.tprintf("%s/alice.work@palm.test/new/3.M3P1.t", dir), transmute([]u8)one("Shared", "shared@t", "alice.work@palm.test"))
	// Held in the work Outbox.
	write_file(fmt.tprintf("%s/alice.work@palm.test/.Outbox/cur/4.M4P1.t:2,S", dir), transmute([]u8)one("To a client", "held@t", "client@example.com"))

	write_file(
		palm_conf_path(dir, context.temp_allocator),
		transmute([]u8)string(
			"[session]\nemail = alice@example.test\n\n" +
			"[identity]\nid = a\nhandle = alice\nname = Alice\nkind = personal\ncolor = indigo\naddress = alice@palm.test\npath = alice@palm.test\n\n" +
			"[identity]\nid = w\nhandle = alice.work\nname = Alice (Acme)\nkind = work\ncolor = emerald\naddress = alice.work@palm.test\npath = alice.work@palm.test\n\n" +
			"[identity]\nid = x\nhandle = evil\nname = Evil\nkind = work\ncolor = javascript\naddress = evil@palm.test\npath = ../../etc\n",
		),
	)

	st := new(State)
	defer free(st)
	st.data_dir = dir
	st.reader_msg = -1
	st.now = time.now()
	load_config(st)
	eq_int(len(st.accounts), 2, "palmy.conf gives two identities, the unsafe third is dropped, no built-in test accounts")
	eq_int(palm_identities(st), 2, "both are Palmy identities")
	eq_str(st.palm_email, "alice@example.test", "the signed-in account")
	if len(st.accounts) < 2 {
		return
	}
	eq_str(st.accounts[1].kind, "work", "the second identity is the work one")
	eq_str(st.accounts[0].color, "indigo", "an identity keeps its colour")
	for a in st.accounts {
		ok(strings.has_prefix(a.root, dir) && !strings.contains(a.root, ".."), "every identity reads inside the data directory: %s", a.root)
	}

	scan_accounts(st)
	rebuild_sidebar(st)

	// Per identity: the sidebar holds that identity and nothing else, and
	// every message listed belongs to it.
	for ai in 0 ..< 2 {
		set_identity_view(st, ai)
		for r in st.side_rows {
			ok(r.account == ai, "identity %d's view shows only its own sidebar rows (saw %d)", ai, r.account)
		}
		ok(len(st.rows) > 0, "identity %d's inbox is not empty", ai)
		for r in st.rows {
			for mi in st.threads[r.thread].msgs {
				ok(st.messages[mi].account == ai, "identity %d's list holds only its own mail", ai)
			}
		}
		ok(!st.unified, "a per-identity view is not the unified one")
	}

	// All identities: both accounts in the sidebar, no unified row while the
	// toggle is off.
	set_identity_view(st, -1)
	saw := [2]bool{}
	for r in st.side_rows {
		ok(r.kind != .Unified, "no unified row while the prototype is off")
		if r.account >= 0 && r.account < 2 {saw[r.account] = true}
	}
	ok(saw[0] && saw[1], "the all-identities view shows both")

	// The prototype: every inbox, each conversation from one identity only,
	// and the shared message once per identity rather than merged.
	set_unified(st, true)
	ok(st.unified, "Shift+I turns the unified inbox on")
	ok(len(st.side_rows) > 0 && st.side_rows[0].kind == .Unified, "the unified row heads the sidebar")
	seen := [2]int{}
	shared := 0
	for t in st.threads {
		acct := st.messages[t.msgs[0]].account
		for mi in t.msgs {
			ok(st.messages[mi].account == acct, "a unified conversation never mixes identities")
			if st.messages[mi].id == "shared@t" {shared += 1}
		}
		if acct >= 0 && acct < 2 {seen[acct] += 1}
	}
	ok(seen[0] > 0 && seen[1] > 0, "the unified inbox holds both identities' mail")
	eq_int(shared, 2, "the same message delivered to two identities is listed once for each")
	set_unified(st, false)
	ok(!st.unified && !st.unified_on, "Shift+I again turns it off")

	// The work Outbox says what it is.
	found := false
	for f, fi in st.folders {
		if f.role == .Outbox && f.account == 1 {
			select_folder(st, fi)
			ok(palm_outbox(st), "a Palmy Outbox is recognised, so its banner shows")
			found = true
		}
	}
	ok(found, "the work identity has an Outbox folder")
}
