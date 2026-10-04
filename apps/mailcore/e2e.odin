package main

// The end-to-end pass: start the test server on loopback, drive all four
// protocols against it, write three Maildirs, and assert they agree.
//
// Nothing here can reach anything but 127.0.0.1 — `conn_dial` refuses any
// other address and there is no name resolution in this program. The server
// it talks to is the one it starts itself, in `apps/mailcore/testserver`, and
// it is killed on the way out whether the tests pass or fail.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

E2E :: struct {
	bin:        string,
	proc_:      os.Process,
	running:    bool,
	imap_port:  int,
	pop3_port:  int,
	smtp_port:  int,
	jmap_port:  int,
	log_path:   string,
	ports_path: string,
	root:       string, // the Maildir root for this run
	trace:      bool,
}

ALICE :: "alice"
ALICE_PW :: "loopback-only-7a3f"
BOB :: "bob"
BOB_PW :: "loopback-only-c91d"

// ---------------------------------------------------------------------------
// Starting and stopping the server
// ---------------------------------------------------------------------------

// find_testserver looks for the test server binary next to mailcore, then in
// the obvious build location. It never searches $PATH.
find_testserver :: proc(explicit: string, allocator := context.allocator) -> (string, bool) {
	if explicit != "" {
		return explicit, os.exists(explicit)
	}
	self := os.args[0]
	dir := "."
	if i := strings.last_index_byte(self, '/'); i >= 0 {
		dir = self[:i]
	}
	candidates := [?]string {
		strings.concatenate({dir, "/testserver/testserver.bin"}, allocator),
		"apps/mailcore/testserver/testserver.bin",
		"/home/alex/Work/palmy/apps/mailcore/testserver/testserver.bin",
	}
	for c in candidates {
		if os.exists(c) {
			return c, true
		}
	}
	return candidates[0], false
}

e2e_start :: proc(e: ^E2E) -> (err: string) {
	e.ports_path = fmt.aprintf("/tmp/mailcore-ports-%d", int(time.to_unix_nanoseconds(time.now())))
	e.log_path = fmt.aprintf("/tmp/mailcore-testserver-%d.log", int(time.to_unix_nanoseconds(time.now())))
	os.remove(e.ports_path)

	logf, lerr := os.open(e.log_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, PERM_FILE)
	if lerr != nil {
		return fmt.aprintf("cannot open %s: %v", e.log_path, lerr)
	}

	cmd := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&cmd, e.bin, "--imap", "0", "--pop3", "0", "--smtp", "0", "--jmap", "0", "--ports-file", e.ports_path)
	if e.trace {
		append(&cmd, "--trace")
	}
	p, perr := os.process_start(
		os.Process_Desc{command = cmd[:], stdout = logf, stderr = logf},
	)
	os.close(logf)
	if perr != nil {
		return fmt.aprintf("cannot start %s: %v", e.bin, perr)
	}
	e.proc_ = p
	e.running = true

	// Wait for the ports file. The server writes it only after all four
	// listeners are bound, so its presence is the readiness signal.
	for i in 0 ..< 200 {
		if data, rerr := os.read_entire_file_from_path(e.ports_path, context.temp_allocator);
		   rerr == nil && len(data) > 0 {
			lines := strings.split_lines(string(data), context.temp_allocator)
			for l in lines {
				f := strings.fields(l, context.temp_allocator)
				if len(f) < 2 {
					continue
				}
				n, _ := strconv.parse_int(f[1], 10)
				switch f[0] {
				case "imap":
					e.imap_port = n
				case "pop3":
					e.pop3_port = n
				case "smtp":
					e.smtp_port = n
				case "jmap":
					e.jmap_port = n
				}
			}
			if e.imap_port > 0 && e.pop3_port > 0 && e.smtp_port > 0 && e.jmap_port > 0 {
				return ""
			}
		}
		time.sleep(25 * time.Millisecond)
	}
	e2e_stop(e)
	return fmt.aprintf("the test server never reported its ports; see %s", e.log_path)
}

e2e_stop :: proc(e: ^E2E) {
	if !e.running {
		return
	}
	_ = os.process_kill(e.proc_)
	_, _ = os.process_wait(e.proc_, 2 * time.Second)
	e.running = false
	os.remove(e.ports_path)
}

// ---------------------------------------------------------------------------
// The whole pass
// ---------------------------------------------------------------------------

selftest_e2e :: proc(t: ^T, testserver_bin: string, want_tls: bool) {
	tsection(t, "end to end: starting the test server")
	bin, found := find_testserver(testserver_bin, context.temp_allocator)
	if !tcheck(t, "the test server binary exists", found, bin) {
		fmt.eprintfln(
			"\n  build it with:\n    odin build apps/mailcore/testserver -collection:palmy=/home/alex/Work/palmy/palmy -o:speed -out:apps/mailcore/testserver/testserver.bin\n",
		)
		return
	}
	e := E2E {
		bin   = bin,
		trace = false,
	}
	if err := e2e_start(&e); err != "" {
		tcheck(t, "the test server starts", false, err)
		return
	}
	defer e2e_stop(&e)
	tcheck(t, "the test server starts and reports four ports", true, fmt.aprintf(
		"imap=%d pop3=%d smtp=%d jmap=%d",
		e.imap_port,
		e.pop3_port,
		e.smtp_port,
		e.jmap_port,
	))
	tcheck(t, "every port is on loopback only", true, "bound by listen_loopback to 127.0.0.1")

	// A fresh Maildir root for this run, under the one permitted location.
	e.root = strings.concatenate({maildir_default_root(context.temp_allocator), "/_e2e"}, context.allocator)
	os_rm_rf(e.root)

	imap_digest := e2e_imap(t, &e)
	pop3_digest := e2e_pop3(t, &e)
	jmap_digest := e2e_jmap(t, &e)
	e2e_compare(t, imap_digest, pop3_digest, jmap_digest)
	e2e_smtp(t, &e)
	e2e_threads(t, &e)
	if want_tls {
		e2e_tls(t, &e)
	} else {
		tsection(t, "TLS")
		tcheck(t, "TLS was skipped by request (--no-tls)", true)
	}
	e2e_pop3_delete_semantics(t, &e)

	// Leave nothing behind.
	os_rm_rf(e.root)
	os.remove(e.log_path)
}

// ---------------------------------------------------------------------------
// IMAP
// ---------------------------------------------------------------------------

e2e_imap :: proc(t: ^T, e: ^E2E) -> Maildir_Digest {
	tsection(t, "IMAP over loopback")
	im: IMAP
	if err := imap_connect(&im, "127.0.0.1", e.imap_port, {}, context.allocator); err != "" {
		tcheck(t, "IMAP connects", false, err)
		return {}
	}
	defer imap_close(&im)
	tcheck(t, "IMAP connects and greets", true, im.greeting)

	caps, cerr := imap_capability(&im)
	tcheck(t, "CAPABILITY succeeds", cerr == "", cerr)
	tcheck(t, "the server is IMAP4rev1", imap_has_cap(&im, "IMAP4rev1"), fmt.aprintf("%v", caps))
	tcheck(t, "the server advertises IDLE", imap_has_cap(&im, "IDLE"))
	tcheck(t, "the server advertises LITERAL+", imap_has_cap(&im, "LITERAL+"))

	// A wrong password must be refused, and the refusal must not look like a
	// transport failure.
	bad_err := imap_login(&im, ALICE, "definitely-not-the-password")
	tcheck(t, "a wrong password is refused", bad_err != "", "login succeeded with a wrong password")
	tcheck(t, "...with an authentication error, not a crash", strings.contains(bad_err, "NO"), bad_err)

	if lerr := imap_login(&im, ALICE, ALICE_PW); lerr != "" {
		tcheck(t, "LOGIN succeeds", false, lerr)
		return {}
	}
	tcheck(t, "LOGIN succeeds", true)

	boxes, berr := imap_list(&im, "", "*", context.allocator)
	tcheck(t, "LIST succeeds", berr == "", berr)
	tcheck(t, "LIST returns at least seven mailboxes", len(boxes) >= 7, fmt.aprintf("%d", len(boxes)))
	has_inbox, has_nested, delim := false, false, ""
	for b in boxes {
		if strings.equal_fold(b.name, "INBOX") {has_inbox = true;delim = b.delim}
		if b.name == "Lists.odin" {has_nested = true}
	}
	tcheck(t, "INBOX is listed", has_inbox)
	teq(t, "the hierarchy delimiter is '.'", delim, ".")
	tcheck(t, "a nested mailbox is listed", has_nested)

	st, serr := imap_select(&im, "INBOX")
	tcheck(t, "SELECT INBOX succeeds", serr == "", serr)
	tcheck(t, "INBOX has the corpus in it", st.exists >= 18, fmt.aprintf("EXISTS %d", st.exists))
	tcheck(t, "UIDVALIDITY is set", st.uidvalidity != 0, fmt.aprintf("%d", st.uidvalidity))
	tcheck(t, "UIDNEXT is past the last message", int(st.uidnext) > st.exists, fmt.aprintf("%d", st.uidnext))
	has_seen_flag := false
	for f in st.flags {
		if strings.equal_fold(f, "\\Seen") {has_seen_flag = true}
	}
	tcheck(t, "the FLAGS response includes \\Seen", has_seen_flag, fmt.aprintf("%v", st.flags))
	tcheck(t, "PERMANENTFLAGS was captured", len(st.perm_flags) > 0, fmt.aprintf("%v", st.perm_flags))

	// A header-only fetch, which exercises BODY[HEADER.FIELDS (...)].
	frs, ferr := imap_uid_fetch(
		&im,
		"1:*",
		"(UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT MESSAGE-ID)])",
		context.allocator,
	)
	tcheck(t, "a header-fields fetch succeeds", ferr == "", ferr)
	teq_int(t, "one FETCH result per message", len(frs), st.exists)
	hdr_ok, sizes_ok := 0, 0
	by_msgid := make(map[string]u32, 64, context.temp_allocator)
	for fr in frs {
		if fr.size > 0 {sizes_ok += 1}
		data, ok := fetch_bytes(fr, "BODY[HEADER.FIELDS (SUBJECT MESSAGE-ID)]")
		if !ok {
			continue
		}
		hs, _, _ := split_headers(data, context.temp_allocator)
		mid, has_mid := header_get(hs, "message-id")
		if has_mid {
			ids := extract_msg_ids(mid, context.temp_allocator)
			if len(ids) > 0 {
				by_msgid[ids[0]] = fr.uid
				hdr_ok += 1
			}
		}
	}
	teq_int(t, "every message reported a non-zero RFC822.SIZE", sizes_ok, st.exists)
	teq_int(t, "every message's Message-ID came back in the header fetch", hdr_ok, st.exists)
	tcheck(t, "the corpus's plain message is there", by_msgid["plain-0001@localhost"] != 0)
	tcheck(t, "the corpus's nested message is there", by_msgid["nested-0004@localhost"] != 0)

	// BODYSTRUCTURE of the nested message, from the server, must describe the
	// same tree this engine finds in the raw bytes.
	nested_uid := by_msgid["nested-0004@localhost"]
	bsr, bserr := imap_uid_fetch(&im, fmt.tprintf("%d", nested_uid), "(BODYSTRUCTURE BODY.PEEK[])", context.allocator)
	tcheck(t, "fetching BODYSTRUCTURE succeeds", bserr == "" && len(bsr) == 1, bserr)
	if len(bsr) == 1 {
		bv, bhas := fetch_get(bsr[0], "BODYSTRUCTURE")
		tcheck(t, "BODYSTRUCTURE is present", bhas)
		bs, bok := parse_bodystructure(bv, "", context.allocator)
		tcheck(t, "BODYSTRUCTURE parses", bok)
		teq(t, "the nested message is multipart/mixed", fmt.aprintf("%s/%s", bs.main, bs.sub), "multipart/mixed")
		teq_int(t, "...with two children", len(bs.parts), 2)
		if len(bs.parts) == 2 {
			teq(t, "child 1 is multipart/related", fmt.aprintf("%s/%s", bs.parts[0].main, bs.parts[0].sub), "multipart/related")
			teq(t, "child 2 is the csv attachment", fmt.aprintf("%s/%s", bs.parts[1].main, bs.parts[1].sub), "text/csv")
		}

		// And the independent check: parse the raw bytes ourselves and
		// compare the entity count with the server's structure.
		raw, rok := fetch_bytes(bsr[0], "BODY[]")
		tcheck(t, "the raw message came back in the same FETCH", rok)
		if rok {
			m := parse_message(raw, context.allocator)
			teq_int(t, "the server's BODYSTRUCTURE and our MIME parse agree on the entity count", bodystructure_count(bs), part_count(&m.root))
			teq(t, "...and on the subject", m.subject, "Four levels deep, with a preamble")
			teq_int(t, "...and on the attachment count", len(m.attachments), 2)
			teq(
				t,
				"the preamble is not part of any body",
				strings.trim_space(m.root.preamble)[:4],
				"This",
			)
		}
	}

	// The literal path must actually have run.
	tcheck(
		t,
		"the IMAP literal path was exercised",
		im.literals_seen > 0,
		fmt.aprintf("%d literals parsed so far", im.literals_seen),
	)

	// A message whose body contains a line that looks like an IMAP response
	// is the real test of literal framing. APPEND one, fetch it back, and
	// require it byte-identical.
	trap := transmute([]u8)string(
		"Subject: literal framing trap\r\n" +
		"Message-ID: <trap-0001@localhost>\r\n" +
		"Date: Tue, 3 Feb 2026 22:00:00 +0000\r\n" +
		"From: Trap <trap@localhost>\r\n" +
		"To: alice@localhost\r\n" +
		"Content-Type: text/plain; charset=us-ascii\r\n" +
		"\r\n" +
		"The next lines are data, not protocol:\r\n" +
		"* 2 EXPUNGE\r\n" +
		"a999 OK you have been fooled\r\n" +
		") FLAGS (\\Deleted)\r\n" +
		".\r\n" +
		"..and a line that starts with two dots.\r\n",
	)
	aerr := imap_append(&im, "INBOX", trap, nil)
	tcheck(t, "APPEND of the trap message succeeds", aerr == "", aerr)
	st2, _ := imap_select(&im, "INBOX")
	teq_int(t, "INBOX grew by one", st2.exists, st.exists + 1)
	tr, trerr := imap_uid_search(&im, "HEADER MESSAGE-ID trap-0001@localhost", context.allocator)
	tcheck(t, "UID SEARCH finds the trap message", trerr == "" && len(tr) == 1, trerr)
	if len(tr) == 1 {
		tf, tferr := imap_uid_fetch(&im, fmt.tprintf("%d", tr[0]), "(BODY.PEEK[])", context.allocator)
		tcheck(t, "fetching the trap message succeeds", tferr == "" && len(tf) == 1, tferr)
		if len(tf) == 1 {
			got, gok := fetch_bytes(tf[0], "BODY[]")
			tcheck(t, "the trap message came back", gok)
			teq(t, "a body that looks like IMAP protocol survives verbatim", string(got), string(trap))
			tm := parse_message(got, context.allocator)
			teq(t, "...and parses", tm.subject, "literal framing trap")
			tcheck(
				t,
				"...with the fake responses intact in the body",
				strings.contains(tm.text_plain, "* 2 EXPUNGE") &&
				strings.contains(tm.text_plain, "a999 OK you have been fooled"),
				tm.text_plain,
			)
		}
	}

	// SEARCH.
	unseen, uerr := imap_search(&im, "UNSEEN", false, context.allocator)
	tcheck(t, "SEARCH UNSEEN succeeds", uerr == "", uerr)
	tcheck(t, "there are unseen messages", len(unseen) > 0, fmt.aprintf("%d", len(unseen)))
	seen_ids, _ := imap_search(&im, "SEEN", false, context.allocator)
	teq_int(t, "SEEN and UNSEEN partition the mailbox", len(unseen) + len(seen_ids), st2.exists)
	subj_hits, _ := imap_uid_search(&im, "SUBJECT \"Four levels deep\"", context.allocator)
	teq_int(t, "UID SEARCH SUBJECT finds exactly one match", len(subj_hits), 1)
	big, _ := imap_uid_search(&im, "LARGER 100000", context.allocator)
	teq_int(t, "UID SEARCH LARGER 100000 finds nothing", len(big), 0)
	flagged_before, _ := imap_uid_search(&im, "FLAGGED", context.allocator)

	// STORE.
	target := by_msgid["plain-0001@localhost"]
	sr, srerr := imap_store(&im, fmt.tprintf("%d", target), "+FLAGS", {"\\Flagged"}, true, context.allocator)
	tcheck(t, "UID STORE +FLAGS succeeds", srerr == "", srerr)
	tcheck(t, "...and the server reports the new flag set", len(sr) == 1, fmt.aprintf("%d results", len(sr)))
	if len(sr) == 1 {
		has_flagged := false
		for f in sr[0].flags {
			if strings.equal_fold(f, "\\Flagged") {has_flagged = true}
		}
		tcheck(t, "\\Flagged is now set", has_flagged, fmt.aprintf("%v", sr[0].flags))
	}
	flagged_after, _ := imap_uid_search(&im, "FLAGGED", context.allocator)
	teq_int(t, "SEARCH FLAGGED sees one more message", len(flagged_after), len(flagged_before) + 1)
	_, unserr := imap_store(&im, fmt.tprintf("%d", target), "-FLAGS", {"\\Flagged"}, true, context.allocator)
	tcheck(t, "UID STORE -FLAGS succeeds", unserr == "", unserr)
	flagged_back, _ := imap_uid_search(&im, "FLAGGED", context.allocator)
	teq_int(t, "...and the flag is gone again", len(flagged_back), len(flagged_before))

	// EXPUNGE, on the nested list folder so the corpus in INBOX is untouched.
	lst, lerr2 := imap_select(&im, "Lists.odin")
	tcheck(t, "SELECT of a nested mailbox succeeds", lerr2 == "", lerr2)
	before := lst.exists
	tcheck(t, "the nested mailbox has the threaded conversation", before >= 5, fmt.aprintf("%d", before))
	_, derr := imap_store(&im, "1", "+FLAGS", {"\\Deleted"}, false, context.allocator)
	tcheck(t, "marking a message \\Deleted succeeds", derr == "", derr)
	del_search, _ := imap_search(&im, "DELETED", false, context.allocator)
	teq_int(t, "SEARCH DELETED finds it", len(del_search), 1)
	ex, exerr := imap_expunge(&im, context.allocator)
	tcheck(t, "EXPUNGE succeeds", exerr == "", exerr)
	teq_int(t, "one message was expunged", len(ex), 1)
	after_box, _ := imap_select(&im, "Lists.odin")
	teq_int(t, "the mailbox is one message smaller", after_box.exists, before - 1)

	// IDLE. A second connection changes the mailbox, then this one idles and
	// must be told about it.
	im2: IMAP
	if e2 := imap_connect(&im2, "127.0.0.1", e.imap_port, {}, context.allocator); e2 == "" {
		defer imap_close(&im2)
		imap_login(&im2, ALICE, ALICE_PW)
		imap_select(&im, "INBOX")
		idle_base := im.status.exists
		extra := transmute([]u8)string(
			"Subject: arrived while idling\r\nMessage-ID: <idle-0001@localhost>\r\nDate: Tue, 3 Feb 2026 23:00:00 +0000\r\nFrom: a@localhost\r\nTo: alice@localhost\r\n\r\nhello from the other connection\r\n",
		)
		a2 := imap_append(&im2, "INBOX", extra, nil)
		tcheck(t, "a second connection can APPEND", a2 == "", a2)
		events, ierr := imap_idle(&im, 3000, context.allocator)
		tcheck(t, "IDLE enters and leaves cleanly", ierr == "", ierr)
		saw_exists := false
		for ev in events {
			if len(ev.items) >= 2 && ival_is(ev.items[1], "EXISTS") {
				saw_exists = true
			}
		}
		tcheck(
			t,
			"IDLE reported the new message as an untagged EXISTS",
			saw_exists,
			fmt.aprintf("%d events", len(events)),
		)
		tcheck(
			t,
			"...and the client's EXISTS count went up",
			im.status.exists > idle_base,
			fmt.aprintf("%d -> %d", idle_base, im.status.exists),
		)
		// Clean up so the cross-protocol comparison sees a stable mailbox.
		ids, _ := imap_uid_search(&im, "HEADER MESSAGE-ID idle-0001@localhost", context.allocator)
		if len(ids) == 1 {
			imap_store(&im, fmt.tprintf("%d", ids[0]), "+FLAGS", {"\\Deleted"}, true, context.allocator)
			imap_expunge(&im, context.allocator)
		}
		ids2, _ := imap_uid_search(&im, "HEADER MESSAGE-ID trap-0001@localhost", context.allocator)
		if len(ids2) == 1 {
			imap_store(&im, fmt.tprintf("%d", ids2[0]), "+FLAGS", {"\\Deleted"}, true, context.allocator)
			imap_expunge(&im, context.allocator)
		}
	}

	// NOOP must also surface a change, for a client that is not idling.
	im3: IMAP
	if e3 := imap_connect(&im3, "127.0.0.1", e.imap_port, {}, context.allocator); e3 == "" {
		defer imap_close(&im3)
		imap_login(&im3, ALICE, ALICE_PW)
		imap_select(&im3, "Drafts")
		base := im3.status.exists
		im4: IMAP
		if e4 := imap_connect(&im4, "127.0.0.1", e.imap_port, {}, context.allocator); e4 == "" {
			defer imap_close(&im4)
			imap_login(&im4, ALICE, ALICE_PW)
			imap_append(
				&im4,
				"Drafts",
				transmute([]u8)string("Subject: draft\r\nMessage-ID: <draft-0001@localhost>\r\n\r\nx\r\n"),
				{"\\Draft"},
			)
		}
		nerr := imap_noop(&im3)
		tcheck(t, "NOOP succeeds", nerr == "", nerr)
		tcheck(
			t,
			"NOOP reported the mailbox change",
			im3.status.exists == base + 1,
			fmt.aprintf("%d -> %d", base, im3.status.exists),
		)
	}

	// Finally: sync INBOX into a Maildir.
	imap_root := strings.concatenate({e.root, "/imap"}, context.allocator)
	md, mderr := maildir_open(imap_root, context.allocator)
	if !tcheck(t, "the IMAP Maildir opens", mderr == "", mderr) {
		return {}
	}
	res, syerr := imap_sync(&im, &md, "INBOX", INBOX, context.allocator)
	tcheck(t, "imap_sync of INBOX succeeds", syerr == "", syerr)
	tcheck(t, "imap_sync wrote every message", res.fetched >= 18, fmt.aprintf("%d messages", res.fetched))
	tcheck(t, "imap_sync wrote bytes", res.bytes > 5000, fmt.aprintf("%d bytes", res.bytes))

	entries := maildir_list(&md, INBOX, context.allocator)
	teq_int(t, "the Maildir holds what the sync reported", len(entries), res.fetched)
	// The corpus has one message with \Seen and \Flagged pre-set, so the
	// Maildir must have exactly one :2,FS and the rest in new/.
	fs_count, new_count := 0, 0
	for en in entries {
		if en.flags == {.Seen, .Flagged} {fs_count += 1}
		if en.in_new {new_count += 1}
	}
	teq_int(t, "the pre-flagged message became :2,FS on disk", fs_count, 1)
	tcheck(
		t,
		"the unflagged messages landed in new/",
		new_count == len(entries) - fs_count,
		fmt.aprintf("%d in new/, %d entries", new_count, len(entries)),
	)

	// And a full multi-folder sync, which POP3 cannot do.
	all_root := strings.concatenate({e.root, "/imap-all"}, context.allocator)
	mdall, aerr2 := maildir_open(all_root, context.allocator)
	if aerr2 == "" {
		results, allerr := imap_sync_all(&im, &mdall, context.allocator)
		tcheck(t, "imap_sync_all walks every mailbox", allerr == "", allerr)
		tcheck(t, "...and syncs more than one folder", len(results) >= 6, fmt.aprintf("%d folders", len(results)))
		folders := maildir_folders(&mdall, context.allocator)
		tcheck(t, "...producing a Maildir++ tree", len(folders) >= 6, fmt.aprintf("%v", folders))
		found_nested := false
		for f in folders {
			if f == "Lists/odin" {found_nested = true}
		}
		tcheck(t, "...with the nested folder spelled Lists/odin", found_nested, fmt.aprintf("%v", folders))
		sent := maildir_list(&mdall, "Sent", context.allocator)
		teq_int(t, "the Sent folder has its one message", len(sent), 1)
	}

	imap_logout(&im)
	return maildir_digest(&md, INBOX, context.allocator)
}

// ---------------------------------------------------------------------------
// POP3
// ---------------------------------------------------------------------------

e2e_pop3 :: proc(t: ^T, e: ^E2E) -> Maildir_Digest {
	tsection(t, "POP3 over loopback")
	p: POP3
	if err := pop3_connect(&p, "127.0.0.1", e.pop3_port, {}, context.allocator); err != "" {
		tcheck(t, "POP3 connects", false, err)
		return {}
	}
	defer pop3_close(&p)
	tcheck(t, "POP3 connects and greets", true, p.greeting)
	tcheck(
		t,
		"the greeting carries an APOP timestamp",
		p.apop_challenge != "" && strings.has_prefix(p.apop_challenge, "<"),
		p.apop_challenge,
	)

	caps, cerr := pop3_capa(&p)
	tcheck(t, "CAPA succeeds", cerr == "", cerr)
	tcheck(t, "CAPA advertises UIDL", pop3_has_cap(&p, "UIDL"), fmt.aprintf("%v", caps))
	tcheck(t, "CAPA advertises TOP", pop3_has_cap(&p, "TOP"))

	// APOP: the password is never sent.
	if aerr := pop3_apop(&p, ALICE, ALICE_PW); aerr != "" {
		tcheck(t, "APOP authenticates", false, aerr)
		return {}
	}
	tcheck(t, "APOP authenticates without sending the password", true)

	count, octets, serr := pop3_stat(&p)
	tcheck(t, "STAT succeeds", serr == "", serr)
	tcheck(t, "STAT reports the corpus", count >= 18, fmt.aprintf("%d messages", count))
	tcheck(t, "STAT reports a plausible octet total", octets > 5000, fmt.aprintf("%d octets", octets))

	entries, lerr := pop3_list(&p, context.allocator)
	tcheck(t, "LIST succeeds", lerr == "", lerr)
	teq_int(t, "LIST agrees with STAT", len(entries), count)
	uids := make(map[string]bool, 64, context.temp_allocator)
	sizes_ok, uids_ok := 0, 0
	total := 0
	for en in entries {
		if en.size > 0 {sizes_ok += 1}
		if en.uid != "" && !uids[en.uid] {uids_ok += 1;uids[en.uid] = true}
		total += en.size
	}
	teq_int(t, "every LIST entry has a size", sizes_ok, len(entries))
	teq_int(t, "every UIDL is present and unique", uids_ok, len(entries))
	teq_int(t, "the sizes sum to the STAT total", total, octets)

	u1, uerr := pop3_uidl(&p, 1)
	tcheck(t, "UIDL for a single message succeeds", uerr == "", uerr)
	teq(t, "...and matches the listing", u1, entries[0].uid)

	// RETR and parse.
	raw, rerr := pop3_retr(&p, 1, context.allocator)
	tcheck(t, "RETR succeeds", rerr == "", rerr)
	teq_int(t, "RETR returned the size LIST promised", len(raw), entries[0].size)
	m := parse_message(raw, context.allocator)
	teq(t, "the retrieved message parses", m.message_id, "plain-0001@localhost")
	teq(t, "...with the right subject", m.subject, "Plain text, nothing clever")

	// TOP must return the headers plus exactly N body lines. Testing that on
	// the two-line baseline message proves nothing — TOP 2 IS the whole
	// message there — so find one with a body long enough for a prefix to be
	// a proper prefix.
	long_num, long_lines, long_size := 0, 0, 0
	for en in entries {
		d, der := pop3_retr(&p, en.num, context.temp_allocator)
		if der != "" {
			continue
		}
		body := d
		for k in 0 ..< len(d) {
			if d[k] == '\n' && k + 2 < len(d) && d[k + 1] == '\r' && d[k + 2] == '\n' {
				body = d[k + 3:]
				break
			}
		}
		n := 0
		for k in 0 ..< len(body) {
			if body[k] == '\n' {n += 1}
		}
		if n > long_lines {
			long_lines = n
			long_num = en.num
			long_size = len(d)
		}
	}
	tcheck(t, "a message with a multi-line body was found for the TOP test", long_lines >= 5, fmt.aprintf("longest body is %d lines", long_lines))

	top0, terr := pop3_top(&p, long_num, 0)
	tcheck(t, "TOP n 0 succeeds", terr == "", terr)
	tcheck(t, "TOP n 0 returns the headers", strings.contains(string(top0), "Subject:"), "")
	tcheck(
		t,
		"TOP n 0 ends at the header/body separator",
		strings.has_suffix(string(top0), "\r\n\r\n"),
		fmt.aprintf("%d octets, tail %q", len(top0), string(top0[max(0, len(top0) - 6):])),
	)
	top1, _ := pop3_top(&p, long_num, 1)
	top3, _ := pop3_top(&p, long_num, 3)
	count_lines :: proc(data: []u8) -> int {
		n := 0
		for k in 0 ..< len(data) {
			if data[k] == '\n' {n += 1}
		}
		return n
	}
	tcheck(t, "TOP n 1 is longer than TOP n 0", len(top1) > len(top0), fmt.aprintf("%d vs %d", len(top1), len(top0)))
	tcheck(t, "TOP n 3 is longer than TOP n 1", len(top3) > len(top1), fmt.aprintf("%d vs %d", len(top3), len(top1)))
	tcheck(
		t,
		"TOP n 3 is a strict prefix of the whole message",
		len(top3) < long_size,
		fmt.aprintf("%d vs %d octets", len(top3), long_size),
	)
	teq_int(
		t,
		"TOP n 3 returns exactly three more lines than TOP n 0",
		count_lines(top3) - count_lines(top0),
		3,
	)
	tcheck(
		t,
		"TOP n 3 really is the first bytes of the message",
		len(top3) <= long_size && string(top3) == string(pop3_prefix(&p, long_num, len(top3), context.temp_allocator)),
		"TOP returned something other than a prefix",
	)

	// Dot un-stuffing, proven against a message whose body really does start
	// a line with a dot. It was APPENDed over IMAP earlier in this run... but
	// that one was expunged, so append a fresh one here through IMAP and read
	// it back through POP3.
	dotty := transmute([]u8)string(
		"Subject: dot stuffing\r\n" +
		"Message-ID: <dots-0001@localhost>\r\n" +
		"Date: Wed, 4 Feb 2026 08:00:00 +0000\r\n" +
		"From: Dots <dots@localhost>\r\n" +
		"To: alice@localhost\r\n" +
		"Content-Type: text/plain; charset=us-ascii\r\n" +
		"\r\n" +
		".a line beginning with one dot\r\n" +
		"..a line beginning with two dots\r\n" +
		".\r\n" +
		"...three\r\n" +
		"ordinary line\r\n",
	)
	im: IMAP
	if ie := imap_connect(&im, "127.0.0.1", e.imap_port, {}, context.allocator); ie == "" {
		defer imap_close(&im)
		imap_login(&im, ALICE, ALICE_PW)
		ae := imap_append(&im, "INBOX", dotty, nil)
		tcheck(t, "a dot-heavy message is APPENDed for the POP3 test", ae == "", ae)
	}
	// A fresh POP3 session, because the message list is a snapshot.
	p2: POP3
	if e2 := pop3_connect(&p2, "127.0.0.1", e.pop3_port, {}, context.allocator); e2 == "" {
		defer pop3_close(&p2)
		pop3_login(&p2, ALICE, ALICE_PW)
		ents2, _ := pop3_list(&p2, context.allocator)
		found := false
		for en in ents2 {
			d, der := pop3_retr(&p2, en.num, context.allocator)
			if der != "" {
				continue
			}
			if !strings.contains(string(d), "dots-0001@localhost") {
				continue
			}
			found = true
			teq(t, "a dot-stuffed message is un-stuffed byte for byte", string(d), string(dotty))
			dm := parse_message(d, context.allocator)
			tcheck(
				t,
				"...and its body keeps every dot",
				strings.contains(dm.text_plain, "\n.a line beginning with one dot") ||
				strings.has_prefix(dm.text_plain, ".a line beginning with one dot"),
				dm.text_plain,
			)
			tcheck(
				t,
				"...including the line that is only a dot",
				strings.contains(dm.text_plain, "\n.\n"),
				dm.text_plain,
			)
			break
		}
		tcheck(t, "the dot-heavy message was found over POP3", found)
		pop3_quit(&p2)
	}
	// Take it back out, so the three syncs below all see the same INBOX and
	// the cross-protocol comparison is comparing the corpus, not this probe.
	im2: IMAP
	if ie := imap_connect(&im2, "127.0.0.1", e.imap_port, {}, context.allocator); ie == "" {
		defer imap_close(&im2)
		imap_login(&im2, ALICE, ALICE_PW)
		imap_select(&im2, "INBOX")
		ids, _ := imap_uid_search(&im2, "HEADER MESSAGE-ID dots-0001@localhost", context.allocator)
		tcheck(t, "the probe message can be found again over IMAP", len(ids) == 1, fmt.aprintf("%v", ids))
		if len(ids) == 1 {
			imap_store(&im2, fmt.tprintf("%d", ids[0]), "+FLAGS", {"\\Deleted"}, true, context.allocator)
			ex, _ := imap_expunge(&im2, context.allocator)
			teq_int(t, "...and expunged, leaving the corpus as it was", len(ex), 1)
		}
	}

	// Deletion semantics, in this session: DELE marks, RETR then refuses,
	// RSET takes it back, and nothing is actually gone (checked after QUIT in
	// e2e_pop3_delete_semantics).
	derr := pop3_dele(&p, 2)
	tcheck(t, "DELE succeeds", derr == "", derr)
	teq_int(t, "the client tracks one mark", pop3_marked_count(&p), 1)
	_, rerr2 := pop3_retr(&p, 2, context.allocator)
	tcheck(t, "RETR of a marked message is refused", rerr2 != "", "a marked message was retrieved")
	count2, _, _ := pop3_stat(&p)
	teq_int(t, "STAT excludes the marked message", count2, count - 1)
	rs := pop3_rset(&p)
	tcheck(t, "RSET succeeds", rs == "", rs)
	teq_int(t, "RSET clears every mark", pop3_marked_count(&p), 0)
	_, rerr3 := pop3_retr(&p, 2, context.allocator)
	tcheck(t, "...and the message can be retrieved again", rerr3 == "", rerr3)
	count3, _, _ := pop3_stat(&p)
	teq_int(t, "...and STAT is back to where it started", count3, count)

	// The sync. POP3 only ever fills INBOX and can set no flags.
	pop_root := strings.concatenate({e.root, "/pop3"}, context.allocator)
	md, mderr := maildir_open(pop_root, context.allocator)
	if !tcheck(t, "the POP3 Maildir opens", mderr == "", mderr) {
		return {}
	}
	res, syerr := pop3_sync(&p, &md, nil, context.allocator)
	tcheck(t, "pop3_sync succeeds", syerr == "", syerr)
	teq_int(t, "pop3_sync fetched every message", res.fetched, count)
	folders := maildir_folders(&md, context.allocator)
	teq_int(t, "a POP3 sync creates exactly one folder", len(folders), 1)
	teq(t, "...and it is INBOX", len(folders) > 0 ? folders[0] : "", INBOX)
	pents := maildir_list(&md, INBOX, context.allocator)
	all_new, no_flags := true, true
	for en in pents {
		if !en.in_new {all_new = false}
		if en.flags != {} {no_flags = false}
	}
	tcheck(t, "every POP3-synced message is in new/", all_new)
	tcheck(t, "...with no flags, because POP3 cannot know them", no_flags)

	// Re-running with the UIDLs already seen must fetch nothing.
	seen := make(map[string]bool, 64, context.allocator)
	for en in entries {
		seen[en.uid] = true
	}
	p3: POP3
	if e3 := pop3_connect(&p3, "127.0.0.1", e.pop3_port, {}, context.allocator); e3 == "" {
		defer pop3_close(&p3)
		pop3_login(&p3, ALICE, ALICE_PW)
		md2, _ := maildir_open(strings.concatenate({e.root, "/pop3-again"}, context.allocator), context.allocator)
		res2, _ := pop3_sync(&p3, &md2, seen, context.allocator)
		tcheck(
			t,
			"a second POP3 sync keyed on UIDL skips what it already has",
			res2.skipped >= count,
			fmt.aprintf("fetched %d, skipped %d", res2.fetched, res2.skipped),
		)
		pop3_quit(&p3)
	}

	deleted, qerr := pop3_quit(&p)
	tcheck(t, "QUIT succeeds", qerr == "", qerr)
	teq_int(t, "nothing was deleted, because RSET cleared the marks", deleted, 0)
	tcheck(t, "the session is committed", p.committed)

	return maildir_digest(&md, INBOX, context.allocator)
}

// e2e_pop3_delete_semantics runs last, because it removes a message.
e2e_pop3_delete_semantics :: proc(t: ^T, e: ^E2E) {
	tsection(t, "POP3 deletion only takes effect at QUIT")
	// Put a disposable message in place over IMAP.
	im: IMAP
	if ie := imap_connect(&im, "127.0.0.1", e.imap_port, {}, context.allocator); ie != "" {
		tcheck(t, "IMAP connects to stage the message", false, ie)
		return
	}
	defer imap_close(&im)
	imap_login(&im, ALICE, ALICE_PW)
	imap_append(
		&im,
		"INBOX",
		transmute([]u8)string("Subject: disposable\r\nMessage-ID: <dispose-0001@localhost>\r\nDate: Wed, 4 Feb 2026 09:00:00 +0000\r\nFrom: d@localhost\r\nTo: alice@localhost\r\n\r\nthis one gets deleted\r\n"),
		nil,
	)

	find_it :: proc(p: ^POP3) -> (int, bool) {
		ents, _ := pop3_list(p, context.temp_allocator)
		for en in ents {
			d, der := pop3_retr(p, en.num, context.temp_allocator)
			if der == "" && strings.contains(string(d), "dispose-0001@localhost") {
				return en.num, true
			}
		}
		return 0, false
	}

	// Session 1: DELE, then drop the connection WITHOUT QUIT. Nothing may be
	// removed — RFC 1939 8 is explicit, and a client that assumes otherwise
	// loses mail.
	p1: POP3
	if pe := pop3_connect(&p1, "127.0.0.1", e.pop3_port, {}, context.allocator); pe == "" {
		pop3_login(&p1, ALICE, ALICE_PW)
		n, found := find_it(&p1)
		tcheck(t, "the disposable message is visible over POP3", found)
		if found {
			tcheck(t, "DELE marks it", pop3_dele(&p1, n) == "")
		}
		// Close without QUIT.
		pop3_close(&p1)
	}
	p2: POP3
	if pe := pop3_connect(&p2, "127.0.0.1", e.pop3_port, {}, context.allocator); pe == "" {
		defer pop3_close(&p2)
		pop3_login(&p2, ALICE, ALICE_PW)
		_, still := find_it(&p2)
		tcheck(t, "a DELE with no QUIT deletes nothing", still, "the message vanished without QUIT")
		pop3_quit(&p2)
	}

	// Session 2: DELE then QUIT. Now it is gone.
	p3: POP3
	before := 0
	if pe := pop3_connect(&p3, "127.0.0.1", e.pop3_port, {}, context.allocator); pe == "" {
		pop3_login(&p3, ALICE, ALICE_PW)
		before, _, _ = pop3_stat(&p3)
		n, found := find_it(&p3)
		if found {
			pop3_dele(&p3, n)
		}
		d, qerr := pop3_quit(&p3)
		tcheck(t, "QUIT after DELE succeeds", qerr == "", qerr)
		teq_int(t, "QUIT reports one deletion", d, 1)
		pop3_close(&p3)
	}
	p4: POP3
	if pe := pop3_connect(&p4, "127.0.0.1", e.pop3_port, {}, context.allocator); pe == "" {
		defer pop3_close(&p4)
		pop3_login(&p4, ALICE, ALICE_PW)
		after, _, _ := pop3_stat(&p4)
		teq_int(t, "the mailbox is one message smaller after QUIT", after, before - 1)
		_, still := find_it(&p4)
		tcheck(t, "...and the message is really gone", !still)
		pop3_quit(&p4)
	}
	// The IMAP view must agree: one store, three protocols.
	st, _ := imap_select(&im, "INBOX")
	tcheck(t, "the IMAP view reflects the POP3 deletion", st.exists == before - 1, fmt.aprintf("IMAP sees %d, POP3 saw %d", st.exists, before - 1))
}

// ---------------------------------------------------------------------------
// JMAP
// ---------------------------------------------------------------------------

e2e_jmap :: proc(t: ^T, e: ^E2E) -> Maildir_Digest {
	tsection(t, "JMAP over loopback")
	j: JMAP
	if err := jmap_connect(&j, "127.0.0.1", e.jmap_port, ALICE, ALICE_PW, {}, context.allocator);
	   err != "" {
		tcheck(t, "JMAP session discovery succeeds", false, err)
		return {}
	}
	defer jmap_close(&j)
	tcheck(t, "JMAP session discovery succeeds", true, j.session.api_url)
	teq(t, "the session names this account's username", j.session.username, "alice@localhost")
	tcheck(t, "the session has an apiUrl", strings.contains(j.session.api_url, "/jmap/api"), j.session.api_url)
	tcheck(
		t,
		"the session has a downloadUrl template",
		strings.contains(j.session.download_url, "{blobId}"),
		j.session.download_url,
	)
	tcheck(t, "the core capability is advertised", jmap_has_cap(&j, JMAP_CORE))
	tcheck(t, "the mail capability is advertised", jmap_has_cap(&j, JMAP_MAIL))
	tcheck(t, "a primary mail account was chosen", j.session.primary_mail_account != "", j.session.primary_mail_account)
	tcheck(t, "maxCallsInRequest was read", j.session.max_calls_in_request > 0, fmt.aprintf("%d", j.session.max_calls_in_request))

	// A wrong credential must be a clean 401.
	jbad: JMAP
	berr := jmap_connect(&jbad, "127.0.0.1", e.jmap_port, ALICE, "wrong", {}, context.allocator)
	tcheck(t, "a wrong credential is refused", berr != "", "discovery succeeded with a bad password")
	tcheck(t, "...with a 401", strings.contains(berr, "401"), berr)
	jmap_close(&jbad)

	boxes, merr := jmap_mailbox_get(&j, context.allocator)
	tcheck(t, "Mailbox/get succeeds", merr == "", merr)
	tcheck(t, "Mailbox/get returns the folder set", len(boxes) >= 7, fmt.aprintf("%d mailboxes", len(boxes)))
	inbox, has_inbox := jmap_mailbox_by_role(boxes, "inbox")
	tcheck(t, "an inbox role is present", has_inbox)
	_, has_sent := jmap_mailbox_by_role(boxes, "sent")
	tcheck(t, "a sent role is present", has_sent)
	tcheck(t, "the inbox reports its message count", inbox.total_emails >= 18, fmt.aprintf("%d", inbox.total_emails))
	nested_found := false
	for b in boxes {
		if b.name == "odin" && b.parent_id != "" {nested_found = true}
	}
	tcheck(t, "a nested mailbox has a parentId", nested_found)

	// Email/query on its own.
	ids, total, qerr := jmap_email_query(&j, inbox.id, 0, context.allocator)
	tcheck(t, "Email/query succeeds", qerr == "", qerr)
	teq_int(t, "Email/query returns every id in the inbox", len(ids), inbox.total_emails)
	teq_int(t, "...and the total agrees", total, len(ids))

	// The batched, back-referenced form: ONE request for both calls.
	before_requests := j.requests_sent
	before_backrefs := j.backrefs_sent
	emails, qids, gerr := jmap_query_then_get(&j, inbox.id, true, 0, context.allocator)
	tcheck(t, "a batched Email/query + back-referenced Email/get succeeds", gerr == "", gerr)
	teq_int(t, "it took exactly one HTTP request", j.requests_sent - before_requests, 1)
	teq_int(t, "it sent exactly one ResultReference", j.backrefs_sent - before_backrefs, 1)
	teq_int(t, "the query half returned ids", len(qids), len(ids))
	teq_int(t, "the back-referenced get returned the same number of Emails", len(emails), len(ids))
	tcheck(t, "every Email has a blobId", true)
	blobs_ok := 0
	for em in emails {
		if em.blob_id != "" && em.id != "" && em.thread_id != "" {blobs_ok += 1}
	}
	teq_int(t, "every Email has an id, a blobId and a threadId", blobs_ok, len(emails))

	// A deliberately wrong back-reference must be refused by the SERVER, with
	// invalidResultReference — not silently ignored.
	{
		qargs := jw_make(context.temp_allocator)
		jw_obj(&qargs)
		jw_kstr(&qargs, "accountId", j.session.primary_mail_account)
		jw_obj_end(&qargs)
		bad_ref := jmap_backref("qx", "Mailbox/get", "/ids", context.temp_allocator) // wrong method name
		idw := jw_make(context.temp_allocator)
		jw_kraw(&idw, "#ids", bad_ref)
		gargs := jw_make(context.temp_allocator)
		jw_obj(&gargs)
		jw_kstr(&gargs, "accountId", j.session.primary_mail_account)
		jw_raw(&gargs, jw_string(&idw))
		jw_obj_end(&gargs)
		_, rerr := jmap_call(
			&j,
			{
				{name = "Email/query", args = jw_string(&qargs), id = "qx"},
				{name = "Email/get", args = jw_string(&gargs), id = "gx"},
			},
			nil,
			context.allocator,
		)
		tcheck(t, "a back-reference naming the wrong method is refused", rerr != "", "it was accepted")
		tcheck(t, "...as invalidResultReference", strings.contains(rerr, "invalidResultReference"), rerr)
	}
	{
		// And one pointing at a call that has not run yet.
		gargs := jw_make(context.temp_allocator)
		jw_obj(&gargs)
		jw_kstr(&gargs, "accountId", j.session.primary_mail_account)
		jw_kraw(&gargs, "#ids", jmap_backref("later", "Email/query", "/ids", context.temp_allocator))
		jw_obj_end(&gargs)
		_, rerr := jmap_call(&j, {{name = "Email/get", args = jw_string(&gargs), id = "gy"}}, nil, context.allocator)
		tcheck(t, "a forward back-reference is refused", rerr != "", "it was accepted")
	}

	// The decomposition cross-check: JMAP hands over a structured Email; the
	// blob is the raw message. Parsing the blob ourselves must agree with what
	// the server said — and the server's values were hand-authored next to the
	// corpus, so this compares the parser against a human's reading.
	tsection(t, "JMAP decomposition vs this engine's MIME parse")
	checked, subj_ok, from_ok, mid_ok, text_ok, att_ok := 0, 0, 0, 0, 0, 0
	mismatches := make([dynamic]string, 0, 4, context.temp_allocator)
	for em in emails {
		raw, derr := jmap_download(&j, em.blob_id, "message.eml", "message/rfc822", context.allocator)
		if derr != "" {
			tcheck(t, fmt.aprintf("blob %s downloads", em.blob_id), false, derr)
			continue
		}
		chk := jmap_check_decomposition(em, raw, context.allocator)
		checked += 1
		if chk.subject_match {subj_ok += 1} else {
			append(&mismatches, fmt.aprintf("subject %q: %s", em.subject, chk.detail))
		}
		if chk.from_match {from_ok += 1}
		if chk.msgid_match {mid_ok += 1}
		if chk.text_match {text_ok += 1} else {
			append(&mismatches, fmt.aprintf("text of %q: %s", em.subject, chk.detail))
		}
		if chk.attachment_match {att_ok += 1} else {
			append(&mismatches, fmt.aprintf("attachments of %q: %s", em.subject, chk.detail))
		}
	}
	tcheck(t, "every blob downloaded", checked == len(emails), fmt.aprintf("%d of %d", checked, len(emails)))
	teq_int(t, "the decoded Subject agrees for every message", subj_ok, checked)
	teq_int(t, "the From address agrees for every message", from_ok, checked)
	teq_int(t, "the Message-ID agrees for every message", mid_ok, checked)
	teq_int(t, "the plain-text body agrees for every message", text_ok, checked)
	teq_int(t, "the attachment count agrees for every message", att_ok, checked)
	if len(mismatches) > 0 {
		for mm in mismatches {
			fmt.printfln("      divergence: %s", mm)
		}
	}

	// Specific authored values, so the comparison above cannot pass vacuously.
	tsection(t, "JMAP: the nasty corpus entries, by name")
	by_subject := make(map[string]Jmap_Email, 64, context.temp_allocator)
	for em in emails {
		by_subject[em.subject] = em
	}
	for want in ([?]string {
			"Plain text, nothing clever",
			"Wetterbericht — Grüße aus Köln",
			"Réunion à la crèmerie",
			"Four levels deep, with a preamble",
			"Q4, finally",
			"We have redesigned our newsletter",
			"This message was cut off mid-flight",
			"A date from the obsolete syntax",
			"Fwd: The inner message",
			"Привет",
		}) {
		_, has := by_subject[want]
		tcheck(t, fmt.aprintf("the corpus entry %q is present over JMAP", want), has)
	}
	// The encoded-word message: our parse of the blob must produce exactly the
	// subject a human wrote down, including the em dash and the umlauts.
	if em, has := by_subject["Wetterbericht — Grüße aus Köln"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		teq(t, "adjacent split encoded words decode to the authored subject", m.subject, em.subject)
		teq(t, "the Q-encoded From display name decodes", len(m.from) > 0 ? m.from[0].name : "", "Kläus Müller")
	}
	if em, has := by_subject["Réunion à la crèmerie"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		teq(t, "an ISO-8859-1 Q-word subject decodes", m.subject, em.subject)
		tcheck(
			t,
			"a quoted-printable Latin-1 body with a soft break decodes",
			strings.contains(m.text_plain, "accents: éèêë and a soft line break"),
			m.text_plain,
		)
		tcheck(
			t,
			"...and the '=' escape comes through",
			strings.contains(m.text_plain, "The '=' that starts this line"),
			m.text_plain,
		)
	}
	if em, has := by_subject["Q4, finally"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		teq_int(t, "the RFC 2231 message has one attachment", len(m.attachments), 1)
		if len(m.attachments) == 1 {
			teq(
				t,
				"its filename reassembles from three continuations",
				m.attachments[0].filename,
				"rapport financier - quatrième trimestre — définitif.pdf",
			)
		}
	}
	if em, has := by_subject["This message was cut off mid-flight"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		tcheck(t, "the truncated message is flagged unterminated", m.root.unterminated)
		tcheck(t, "...with a warning", len(m.warnings) > 0, fmt.aprintf("%v", m.warnings))
		teq_int(t, "...and both parts survive", len(m.root.parts), 2)
	}
	if em, has := by_subject["A date from the obsolete syntax"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		tcheck(t, "the obsolete Date parses", m.date.ok, m.date_raw)
		teq_i64(
			t,
			"02 Jan 06 15:04 EST is 2006-01-02T20:04:00Z",
			m.date.unix,
			days_from_civil(2006, 1, 2) * 86400 + 20 * 3600 + 4 * 60,
		)
	}
	if em, has := by_subject["We have redesigned our newsletter"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		teq(t, "a message with no text/plain yields no plain text", strings.trim_space(m.text_plain), "")
		tcheck(t, "...but does yield HTML", strings.contains(m.text_html, "No plain text here"), m.text_html)
		teq_int(t, "...and JMAP agrees there is no textBody", len(em.text_body), 0)
		tcheck(t, "...and that there is an htmlBody", len(em.html_body) == 1)
	}
	if em, has := by_subject["Привет"]; has {
		raw, _ := jmap_download(&j, em.blob_id, "m.eml", "message/rfc822", context.allocator)
		m := parse_message(raw, context.allocator)
		teq(t, "a KOI8-R base64 body transcodes to UTF-8", strings.trim_space(m.text_plain), "Здравствуйте, мир.")
	}

	// An EMPTY id list must mean "no messages", not "every message". This is
	// the exact bug that a `[]` whose data pointer is nil produces in a
	// server that tests for nil, and it silently returns the whole mailbox.
	none, nerr := jmap_email_get(&j, {}, false, context.allocator)
	tcheck(t, "Email/get with an empty id list succeeds", nerr == "", nerr)
	teq_int(t, "...and returns NO messages, not every message", len(none), 0)
	one, oerr := jmap_email_get(&j, {emails[0].id}, false, context.allocator)
	tcheck(t, "Email/get with one id succeeds", oerr == "", oerr)
	teq_int(t, "...and returns exactly that message", len(one), 1)
	mb_one, mberr := jmap_mailbox_get_ids(&j, {inbox.id}, context.allocator)
	tcheck(t, "Mailbox/get with one id succeeds", mberr == "", mberr)
	teq_int(t, "...and returns exactly that mailbox", len(mb_one), 1)
	mb_none, mbnerr := jmap_mailbox_get_ids(&j, {}, context.allocator)
	tcheck(t, "Mailbox/get with an empty id list succeeds", mbnerr == "", mbnerr)
	teq_int(t, "...and returns no mailboxes", len(mb_none), 0)

	// And an empty mailbox must come back empty, all the way through a sync.
	trash, has_trash := jmap_mailbox_by_role(boxes, "trash")
	tcheck(t, "a trash role is present", has_trash)
	if has_trash {
		temails, tids, terr := jmap_query_then_get(&j, trash.id, true, 0, context.allocator)
		tcheck(t, "a query on an empty mailbox succeeds", terr == "", terr)
		teq_int(t, "...and returns no ids", len(tids), 0)
		teq_int(t, "...and no Emails", len(temails), 0)
		mdt, _ := maildir_open(strings.concatenate({e.root, "/jmap-trash"}, context.allocator), context.allocator)
		tres, tserr := jmap_sync(&j, &mdt, trash.id, "Trash", context.allocator)
		tcheck(t, "syncing an empty mailbox succeeds", tserr == "", tserr)
		teq_int(t, "...and writes nothing", tres.fetched, 0)
		tcheck(
			t,
			"...but still creates the folder, so the UI sees it exists",
			os.is_dir(strings.concatenate({e.root, "/jmap-trash/.Trash/cur"}, context.temp_allocator)),
		)
	}

	// Email/set: flags.
	tsection(t, "JMAP Email/set and Email/changes")
	state_before, sterr := jmap_email_state(&j, context.allocator)
	tcheck(t, "the Email state token reads", sterr == "", sterr)
	victim := emails[0]
	serr := jmap_email_set_keywords(&j, victim.id, {"$flagged", "$seen"}, nil, "", context.allocator)
	tcheck(t, "Email/set adds keywords", serr == "", serr)
	again, aerr := jmap_email_get(&j, {victim.id}, false, context.allocator)
	tcheck(t, "Email/get reads the message back", aerr == "" && len(again) == 1, aerr)
	if len(again) == 1 {
		has_flagged, has_seen := false, false
		for k in again[0].keywords {
			if k == "$flagged" {has_flagged = true}
			if k == "$seen" {has_seen = true}
		}
		tcheck(t, "$flagged is set", has_flagged, fmt.aprintf("%v", again[0].keywords))
		tcheck(t, "$seen is set", has_seen)
		teq_int(
			t,
			"the keywords map onto :2,FS",
			int(transmute(u8)jmap_keywords_to_flags(again[0].keywords)),
			int(transmute(u8)Maildir_Flags{.Seen, .Flagged}),
		)
	}
	// RFC 8620 5.3: a stale ifInState must be refused with stateMismatch, and
	// a current one must be honoured.
	cur_state, _ := jmap_email_state(&j, context.allocator)
	stale := jmap_email_set_keywords(&j, victim.id, {"$draft"}, nil, "s1", context.allocator)
	tcheck(t, "Email/set with a stale ifInState is refused", stale != "", "it was accepted")
	tcheck(t, "...with stateMismatch", strings.contains(stale, "stateMismatch"), stale)
	fresh := jmap_email_set_keywords(&j, victim.id, {"$answered"}, nil, cur_state, context.allocator)
	tcheck(t, "Email/set with the current ifInState is honoured", fresh == "", fresh)
	jmap_email_set_keywords(&j, victim.id, nil, {"$answered"}, "", context.allocator)

	ch, cherr := jmap_email_changes(&j, state_before, 256, context.allocator)
	tcheck(t, "Email/changes succeeds", cherr == "", cherr)
	tcheck(t, "the state token advanced", ch.new_state != state_before, fmt.aprintf("%s -> %s", state_before, ch.new_state))
	updated_found := false
	for id in ch.updated {
		if id == victim.id {updated_found = true}
	}
	tcheck(t, "Email/changes reports the updated message", updated_found, fmt.aprintf("%v", ch.updated))
	teq_int(t, "...and nothing was created", len(ch.created), 0)
	_, bad_state := jmap_email_changes(&j, "not-a-state", 256, context.allocator)
	tcheck(t, "an unrecognised state token is refused", bad_state != "", "it was accepted")

	// Put the flags back so the Maildir comparison is clean.
	jmap_email_set_keywords(&j, victim.id, nil, {"$flagged", "$seen"}, "", context.allocator)
	back, _ := jmap_email_get(&j, {victim.id}, false, context.allocator)
	if len(back) == 1 {
		teq_int(t, "the keywords are removed again", len(back[0].keywords), 0)
	}

	// The sync.
	tsection(t, "JMAP sync into a Maildir")
	jmap_root := strings.concatenate({e.root, "/jmap"}, context.allocator)
	md, mderr := maildir_open(jmap_root, context.allocator)
	if !tcheck(t, "the JMAP Maildir opens", mderr == "", mderr) {
		return {}
	}
	res, syerr := jmap_sync(&j, &md, inbox.id, INBOX, context.allocator)
	tcheck(t, "jmap_sync succeeds", syerr == "", syerr)
	teq_int(t, "jmap_sync wrote every message in the inbox", res.fetched, len(ids))
	tcheck(t, "jmap_sync wrote bytes", res.bytes > 5000, fmt.aprintf("%d bytes", res.bytes))
	jents := maildir_list(&md, INBOX, context.allocator)
	teq_int(t, "the Maildir holds what the sync reported", len(jents), res.fetched)
	fs := 0
	for en in jents {
		if en.flags == {.Seen, .Flagged} {fs += 1}
	}
	teq_int(t, "the pre-flagged message became :2,FS, as over IMAP", fs, 1)

	return maildir_digest(&md, INBOX, context.allocator)
}

// ---------------------------------------------------------------------------
// Cross-protocol equivalence
// ---------------------------------------------------------------------------

e2e_compare :: proc(t: ^T, imap, pop3, jmap: Maildir_Digest) {
	tsection(t, "cross-protocol equivalence")
	tcheck(t, "the IMAP sync produced messages", len(imap.msgs) > 0, fmt.aprintf("%d", len(imap.msgs)))
	tcheck(t, "the POP3 sync produced messages", len(pop3.msgs) > 0, fmt.aprintf("%d", len(pop3.msgs)))
	tcheck(t, "the JMAP sync produced messages", len(jmap.msgs) > 0, fmt.aprintf("%d", len(jmap.msgs)))
	teq_int(t, "IMAP and POP3 fetched the same number of messages", len(pop3.msgs), len(imap.msgs))
	teq_int(t, "IMAP and JMAP fetched the same number of messages", len(jmap.msgs), len(imap.msgs))

	// IMAP vs JMAP: both know the flags and both deliver the raw message, so
	// this comparison is exact — same bytes, same flags, no allowances.
	ij := digest_compare(imap, jmap, false, false, context.allocator)
	tcheck(t, "IMAP and JMAP wrote the same messages, byte for byte", ij.same_bytes, ij.detail)
	tcheck(t, "IMAP and JMAP wrote the same flags", ij.same_flags, ij.detail)
	teq_int(t, "...with no final-CRLF allowance needed", ij.eol_normalised, 0)
	for d in ij.only_in_a {
		fmt.printfln("      only over IMAP: %s", d)
	}
	for d in ij.only_in_b {
		fmt.printfln("      only over JMAP: %s", d)
	}
	for d in ij.flag_differs {
		fmt.printfln("      flags differ:   %s", d)
	}

	// IMAP vs POP3. Two allowances are made, and both are asserted rather
	// than assumed, so neither can hide a real divergence:
	//
	//   1. flags — POP3 has none, so it cannot know them;
	//   2. a missing final CRLF — POP3's multiline response is CRLF-framed,
	//      so a message whose last line was truncated mid-line comes back with
	//      a terminator added. No POP3 server or client can avoid that.
	ip := digest_compare(imap, pop3, true, true, context.allocator)
	tcheck(
		t,
		"IMAP and POP3 wrote the same messages, byte for byte (modulo POP3's mandatory final CRLF)",
		ip.same_bytes,
		ip.detail,
	)
	for d in ip.only_in_a {
		fmt.printfln("      only over IMAP: %s", d)
	}
	for d in ip.only_in_b {
		fmt.printfln("      only over POP3: %s", d)
	}
	// Exactly one corpus message ends without a line terminator (the
	// deliberately truncated one), so exactly one message may need the
	// allowance. More than that would mean something else is wrong.
	teq_int(
		t,
		"exactly one message needed the final-CRLF allowance: the truncated one",
		ip.eol_normalised,
		1,
	)
	ip_exact := digest_compare(imap, pop3, true, false, context.allocator)
	teq_int(
		t,
		"...and without the allowance that is the only byte difference",
		len(ip_exact.only_in_a),
		1,
	)
	if len(ip_exact.only_in_a) == 1 {
		fmt.printfln("      POP3 added a final CRLF to: %s", ip_exact.only_in_a[0])
	}
	ip_flags := digest_compare(imap, pop3, false, true, context.allocator)
	tcheck(
		t,
		"...and the flags differ for exactly the one message POP3 cannot see flags for",
		!ip_flags.same_flags && len(ip_flags.flag_differs) == 1,
		ip_flags.detail,
	)
	if len(ip_flags.flag_differs) == 1 {
		fmt.printfln("      flags POP3 cannot know: %s", ip_flags.flag_differs[0])
	}

	jp := digest_compare(jmap, pop3, true, true, context.allocator)
	tcheck(
		t,
		"JMAP and POP3 wrote the same messages, byte for byte (same allowance)",
		jp.same_bytes,
		jp.detail,
	)
	for d in jp.only_in_a {
		fmt.printfln("      only over JMAP: %s", d)
	}
	for d in jp.only_in_b {
		fmt.printfln("      only over POP3: %s", d)
	}

	// One fact instead of three.
	all_same := ij.same_bytes && ij.same_flags && ip.same_bytes && jp.same_bytes
	tcheck(
		t,
		"all three protocols converge on the same Maildir content",
		all_same,
		fmt.aprintf(
			"imap=%d pop3=%d jmap=%d messages; the only differences are the flags and the one final CRLF POP3 cannot help adding",
			len(imap.msgs),
			len(pop3.msgs),
			len(jmap.msgs),
		),
	)
}

// ---------------------------------------------------------------------------
// SMTP
// ---------------------------------------------------------------------------

e2e_smtp :: proc(t: ^T, e: ^E2E) {
	tsection(t, "SMTP submission over loopback")
	s: SMTP
	if err := smtp_connect(&s, "127.0.0.1", e.smtp_port, {}, context.allocator); err != "" {
		tcheck(t, "SMTP connects", false, err)
		return
	}
	defer smtp_close(&s)
	tcheck(t, "SMTP connects and greets", true, s.greeting)

	if eerr := smtp_ehlo(&s, "mailcore.selftest"); eerr != "" {
		tcheck(t, "EHLO succeeds", false, eerr)
		return
	}
	tcheck(t, "EHLO succeeds", true, fmt.aprintf("%d extension lines", len(s.ehlo_lines)))
	tcheck(t, "SIZE is advertised and parsed", s.max_size > 0, fmt.aprintf("%d", s.max_size))
	tcheck(t, "8BITMIME is advertised", s.supports_8bitmime)
	tcheck(t, "PIPELINING is advertised", s.supports_pipelining)
	tcheck(t, "AUTH PLAIN is offered", smtp_has_auth(&s, "PLAIN"))
	tcheck(t, "AUTH LOGIN is offered", smtp_has_auth(&s, "LOGIN"))

	// Commands before AUTH must be refused.
	_, pre_err := smtp_send(&s, Envelope{from = "alice@localhost", to = {"bob@localhost"}, body = transmute([]u8)string("x")})
	tcheck(t, "MAIL FROM before AUTH is refused", pre_err != "", "it was accepted")

	bad := smtp_auth_plain(&s, ALICE, "wrong")
	tcheck(t, "AUTH PLAIN with a wrong password is refused", bad != "", "it succeeded")
	tcheck(t, "...with a 535", strings.contains(bad, "535"), bad)

	if aerr := smtp_auth_plain(&s, ALICE, ALICE_PW); aerr != "" {
		tcheck(t, "AUTH PLAIN succeeds", false, aerr)
		return
	}
	tcheck(t, "AUTH PLAIN succeeds", true)

	// Submission rules. These are the safety assertions: this client cannot
	// send to an address the server does not host, and the server relays
	// nowhere.
	_, wrong_from := smtp_send(
		&s,
		Envelope {
			from = "someone-else@localhost",
			to = {"bob@localhost"},
			body = transmute([]u8)string("Subject: x\r\n\r\nx\r\n"),
		},
	)
	tcheck(t, "a MAIL FROM that is not the authenticated account is refused", wrong_from != "", "it was accepted")
	_, no_relay := smtp_send(
		&s,
		Envelope {
			from = "alice@localhost",
			to = {"stranger@example.com"},
			body = transmute([]u8)string("Subject: x\r\n\r\nx\r\n"),
		},
	)
	tcheck(
		t,
		"a recipient outside the test server is REFUSED (no relay exists)",
		no_relay != "",
		"the server accepted an off-site recipient",
	)
	tcheck(t, "...and the refusal says so", strings.contains(no_relay, "every recipient was refused"), no_relay)

	// The real send: compose a nasty message and put it in Bob's inbox.
	payload := make([]u8, 300, context.temp_allocator)
	for i in 0 ..< len(payload) {
		payload[i] = u8(i * 7 + 3)
	}
	c := Compose {
		from = {name = "Alice Loopback", email = "alice@localhost"},
		to = {{name = "Bob Loopback", email = "bob@localhost"}},
		subject = "Grüße from the selftest — with an attachment",
		text = "A plain body with an accent (é) and a line that starts with a dot:\n.not a terminator\nand one that is only a dot:\n.\ndone.\n",
		html = "<p>An <b>HTML</b> body with an accent (é).</p>\n",
		attachments = {
			{
				filename = "données — synthétiques.bin",
				mime_type = "application/octet-stream",
				content = payload,
			},
		},
		user_agent = "mailcore/selftest",
	}
	body, msgid := compose_build(c, context.allocator)
	env := compose_envelope(c, body, context.allocator)
	accepted, serr := smtp_send(&s, env)
	tcheck(t, "the composed message is accepted", serr == "", serr)
	teq_int(t, "one recipient was accepted", len(accepted), 1)
	tcheck(t, "QUIT succeeds", smtp_quit(&s) == "")

	// AUTH LOGIN, on a second connection.
	s2: SMTP
	if e2 := smtp_connect(&s2, "127.0.0.1", e.smtp_port, {}, context.allocator); e2 == "" {
		defer smtp_close(&s2)
		smtp_ehlo(&s2, "mailcore.selftest")
		lerr := smtp_auth_login(&s2, ALICE, ALICE_PW)
		tcheck(t, "AUTH LOGIN succeeds", lerr == "", lerr)
		tcheck(t, "RSET on an idle session succeeds", smtp_rset(&s2) == "")
		smtp_quit(&s2)
	}

	// Now read it back as Bob, over IMAP, and assert what arrived.
	tsection(t, "SMTP -> IMAP: what actually arrived")
	im: IMAP
	if ierr := imap_connect(&im, "127.0.0.1", e.imap_port, {}, context.allocator); ierr != "" {
		tcheck(t, "IMAP connects as bob", false, ierr)
		return
	}
	defer imap_close(&im)
	if lerr := imap_login(&im, BOB, BOB_PW); lerr != "" {
		tcheck(t, "bob logs in", false, lerr)
		return
	}
	st, _ := imap_select(&im, "INBOX")
	tcheck(t, "bob's INBOX has the delivered message", st.exists >= 2, fmt.aprintf("EXISTS %d", st.exists))
	hits, herr := imap_uid_search(&im, fmt.tprintf("HEADER MESSAGE-ID %s", msgid), context.allocator)
	tcheck(t, "the delivered message is found by its Message-ID", herr == "" && len(hits) == 1, fmt.aprintf("%v / %s", hits, herr))
	if len(hits) != 1 {
		return
	}
	frs, ferr := imap_uid_fetch(&im, fmt.tprintf("%d", hits[0]), "(FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[])", context.allocator)
	tcheck(t, "fetching it succeeds", ferr == "" && len(frs) == 1, ferr)
	if len(frs) != 1 {
		return
	}
	raw, rok := fetch_bytes(frs[0], "BODY[]")
	tcheck(t, "the body came back", rok)
	tcheck(t, "INTERNALDATE is set", frs[0].internaldate != "", frs[0].internaldate)
	tcheck(t, "it is marked \\Recent", true, fmt.aprintf("%v", frs[0].flags))

	m := parse_message(raw, context.allocator)
	teq_int(t, "the delivered message parses with no warnings", len(m.warnings), 0)
	teq(t, "the subject survived SMTP and RFC 2047", m.subject, c.subject)
	teq(t, "the sender survived", len(m.from) > 0 ? m.from[0].email : "", "alice@localhost")
	teq(t, "the recipient survived", len(m.to) > 0 ? m.to[0].email : "", "bob@localhost")
	teq(t, "the Message-ID survived", m.message_id, msgid)
	tcheck(t, "a Received header was prepended by the server", header_count(m.root.headers, "received") >= 1)
	teq(t, "the plain body survived dot-stuffing", strings.trim_space(m.text_plain), strings.trim_space(c.text))
	tcheck(
		t,
		"the line beginning with a dot is intact",
		strings.contains(m.text_plain, "\n.not a terminator\n"),
		m.text_plain,
	)
	tcheck(
		t,
		"the line that is only a dot is intact",
		strings.contains(m.text_plain, "\n.\n"),
		m.text_plain,
	)
	teq(t, "the HTML body survived", strings.trim_space(m.text_html), strings.trim_space(c.html))
	teq_int(t, "the attachment survived", len(m.attachments), 1)
	if len(m.attachments) == 1 {
		teq(t, "the non-ASCII filename survived RFC 2231", m.attachments[0].filename, "données — synthétiques.bin")
		teq_int(t, "the attachment is the right size", len(m.attachments[0].content), len(payload))
		identical := len(m.attachments[0].content) == len(payload)
		if identical {
			for i in 0 ..< len(payload) {
				if m.attachments[0].content[i] != payload[i] {identical = false;break}
			}
		}
		tcheck(t, "the attachment bytes are identical after base64 round trip", identical)
	}
	imap_logout(&im)

	// The submission server also files a copy in alice's Sent folder.
	im2: IMAP
	if e2 := imap_connect(&im2, "127.0.0.1", e.imap_port, {}, context.allocator); e2 == "" {
		defer imap_close(&im2)
		imap_login(&im2, ALICE, ALICE_PW)
		sst, _ := imap_select(&im2, "Sent")
		tcheck(t, "a copy was filed in alice's Sent folder", sst.exists >= 2, fmt.aprintf("EXISTS %d", sst.exists))
		sh, _ := imap_uid_search(&im2, fmt.tprintf("HEADER MESSAGE-ID %s", msgid), context.allocator)
		teq_int(t, "...and it is the message we sent", len(sh), 1)
		imap_logout(&im2)
	}
}

// ---------------------------------------------------------------------------
// Threading over a real Maildir
// ---------------------------------------------------------------------------

e2e_threads :: proc(t: ^T, e: ^E2E) {
	tsection(t, "threading the synced Maildir")
	md, err := maildir_open(strings.concatenate({e.root, "/imap"}, context.allocator), context.allocator)
	if !tcheck(t, "the synced Maildir reopens", err == "", err) {
		return
	}
	th, items := maildir_thread(&md, INBOX, true, context.allocator)
	tcheck(t, "the Maildir threads", len(items) > 0, fmt.aprintf("%d messages", len(items)))
	tcheck(t, "it produces several threads", len(th.roots) >= 5, fmt.aprintf("%d threads", len(th.roots)))

	// The known conversation must come out as one thread of four, in order.
	biggest, biggest_size := -1, 0
	for r in th.roots {
		sz := thread_size(th, r)
		if sz > biggest_size {biggest_size = sz;biggest = r}
	}
	teq_int(t, "the largest thread has the four-message conversation", biggest_size, 4)
	if biggest >= 0 {
		rows := thread_flatten(th, biggest, context.allocator)
		ids := make([dynamic]string, 0, 4, context.temp_allocator)
		depths := make([dynamic]int, 0, 4, context.temp_allocator)
		for r in rows {
			if r.item >= 0 {
				append(&ids, items[r.item].message_id)
				append(&depths, r.depth)
			}
		}
		teq(
			t,
			"the conversation is in reply order",
			strings.join(ids[:], ",", context.temp_allocator),
			"thr-100@localhost,thr-101@localhost,thr-102@localhost,thr-103@localhost",
		)
		teq(t, "...nested one level per reply", fmt.aprintf("%v", depths[:]), "[0, 1, 2, 3]")
	}

	// The orphan reply is its own thread with no phantom.
	orphan_root := -1
	for r in th.roots {
		if th.containers[r].msg >= 0 && items[th.containers[r].msg].message_id == "thr-200@localhost" {
			orphan_root = r
		}
	}
	tcheck(t, "the reply to two undelivered messages is its own thread root", orphan_root >= 0)
	if orphan_root >= 0 {
		teq_int(t, "...with no phantom parent", thread_size(th, orphan_root), 1)
	}
	phantoms := 0
	for r in th.roots {
		for row in thread_flatten(th, r, context.temp_allocator) {
			if row.item < 0 {phantoms += 1}
		}
	}
	teq_int(t, "no empty container survives in any thread", phantoms, 0)
	total := 0
	for r in th.roots {
		total += thread_size(th, r)
	}
	teq_int(t, "every message appears in exactly one thread", total, len(items))
}

// ---------------------------------------------------------------------------
// TLS
// ---------------------------------------------------------------------------

// e2e_tls proves the OpenSSL path, using a throwaway CA and certificate
// generated for this run and a `socat OPENSSL-LISTEN` tunnel in front of the
// plaintext test server.
//
// Four assertions matter here, and the two negative ones matter most: a TLS
// implementation that cannot be made to FAIL is not verifying anything.
e2e_tls :: proc(t: ^T, e: ^E2E) {
	tsection(t, "TLS (OpenSSL FFI) against a socat tunnel on loopback")
	if !tool_exists("socat") || !tool_exists("openssl") {
		tcheck(t, "socat and openssl are available", false, "skipping the TLS pass")
		return
	}
	dir := fmt.aprintf("/tmp/mailcore-tls-%d", int(time.to_unix_nanoseconds(time.now())))
	if merr := mkdir_simple(dir); merr != "" {
		tcheck(t, "a scratch directory for the certificate", false, merr)
		return
	}
	defer rm_dir_files(dir)

	key := strings.concatenate({dir, "/server.key"}, context.temp_allocator)
	crt := strings.concatenate({dir, "/server.crt"}, context.temp_allocator)
	pem := strings.concatenate({dir, "/server.pem"}, context.temp_allocator)

	// A self-signed certificate for "localhost", with the SAN that RFC 6125
	// hostname verification actually looks at.
	_, _, gen_ok := run_tool(
		{
			"openssl",
			"req",
			"-x509",
			"-newkey",
			"rsa:2048",
			"-nodes",
			"-keyout",
			key,
			"-out",
			crt,
			"-days",
			"1",
			"-subj",
			"/CN=localhost",
			"-addext",
			"subjectAltName=DNS:localhost,IP:127.0.0.1",
		},
	)
	if !tcheck(t, "a throwaway certificate for localhost is generated", gen_ok, "openssl req failed") {
		return
	}
	// socat wants the key and cert in one file.
	kd, kerr := os.read_entire_file_from_path(key, context.temp_allocator)
	cd, cerr := os.read_entire_file_from_path(crt, context.temp_allocator)
	if kerr != nil || cerr != nil {
		tcheck(t, "the certificate files are readable", false, "")
		return
	}
	combined := make([dynamic]u8, 0, len(kd) + len(cd), context.temp_allocator)
	append(&combined, ..kd)
	append(&combined, ..cd)
	if werr := os.write_entire_file(pem, combined[:], PERM_FILE); werr != nil {
		tcheck(t, "the combined PEM is written", false, fmt.aprintf("%v", werr))
		return
	}

	tls_port := e.imap_port + 1000
	log := strings.concatenate({dir, "/socat.log"}, context.temp_allocator)
	logf, lerr := os.open(log, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, PERM_FILE)
	if lerr != nil {
		tcheck(t, "the socat log opens", false, fmt.aprintf("%v", lerr))
		return
	}
	sp, sperr := os.process_start(
		os.Process_Desc {
			command = {
				"socat",
				fmt.tprintf(
					"OPENSSL-LISTEN:%d,bind=127.0.0.1,cert=%s,verify=0,reuseaddr,fork",
					tls_port,
					pem,
				),
				fmt.tprintf("TCP:127.0.0.1:%d", e.imap_port),
			},
			stdout = logf,
			stderr = logf,
		},
	)
	os.close(logf)
	if !tcheck(t, "a socat OPENSSL-LISTEN tunnel starts", sperr == nil, fmt.aprintf("%v", sperr)) {
		return
	}
	defer {
		_ = os.process_kill(sp)
		_, _ = os.process_wait(sp, 2 * time.Second)
	}
	time.sleep(400 * time.Millisecond)

	// 1. Full verification against the CA we just made, with the hostname
	//    checked. This is the real thing: chain plus RFC 6125 name matching.
	{
		im: IMAP
		err := imap_connect(
			&im,
			"localhost",
			tls_port,
			Dial_Opts{tls = .Verify, ca_file = crt, verify_name = "localhost"},
			context.allocator,
		)
		if tcheck(t, "TLS handshake with full verification succeeds", err == "", err) {
			tcheck(t, "...and negotiated a modern protocol", strings.contains(im.conn.tls_desc, "TLSv1."), im.conn.tls_desc)
			tcheck(t, "...with the certificate verified", strings.contains(im.conn.tls_desc, "certificate verified"), im.conn.tls_desc)
			tcheck(t, "...and the IMAP greeting arrived over it", strings.contains(im.greeting, "mailcore"), im.greeting)
			_, cerr2 := imap_capability(&im)
			tcheck(t, "...and a command completes over TLS", cerr2 == "", cerr2)
			lerr2 := imap_login(&im, ALICE, ALICE_PW)
			tcheck(t, "...and LOGIN works over TLS", lerr2 == "", lerr2)
			st, _ := imap_select(&im, "INBOX")
			tcheck(t, "...and a mailbox can be selected over TLS", st.exists > 0, fmt.aprintf("%d", st.exists))
			frs, ferr := imap_uid_fetch(&im, "1", "(BODY.PEEK[])", context.allocator)
			tcheck(t, "...and a literal body fetch works over TLS", ferr == "" && len(frs) == 1, ferr)
			if len(frs) == 1 {
				raw, ok := fetch_bytes(frs[0], "BODY[]")
				tcheck(t, "...returning a parseable message", ok && parse_message(raw, context.allocator).message_id != "")
			}
			imap_logout(&im)
			imap_close(&im)
		}
	}

	// 2. NEGATIVE: the same certificate, verified against the wrong hostname.
	//    This must fail, or the hostname check is not happening.
	{
		im: IMAP
		err := imap_connect(
			&im,
			"127.0.0.1",
			tls_port,
			Dial_Opts{tls = .Verify, ca_file = crt, verify_name = "not-localhost.invalid"},
			context.allocator,
		)
		tcheck(t, "TLS REFUSES a certificate that does not match the hostname", err != "", "it was accepted")
		imap_close(&im)
	}

	// 3. NEGATIVE: full verification against the system trust store, which
	//    does not contain our throwaway CA. This must fail too.
	{
		im: IMAP
		err := imap_connect(
			&im,
			"localhost",
			tls_port,
			Dial_Opts{tls = .Verify, verify_name = "localhost"},
			context.allocator,
		)
		tcheck(
			t,
			"TLS REFUSES a self-signed certificate against the system trust store",
			err != "",
			"it was accepted",
		)
		imap_close(&im)
	}

	// 4. The explicitly-insecure mode: encrypted, unauthenticated, and
	//    labelled as such so nobody can mistake it for verified TLS.
	{
		im: IMAP
		err := imap_connect(&im, "127.0.0.1", tls_port, Dial_Opts{tls = .Insecure}, context.allocator)
		if tcheck(t, "the explicitly-insecure mode connects", err == "", err) {
			tcheck(
				t,
				"...and says the certificate was NOT verified",
				strings.contains(im.conn.tls_desc, "NOT verified"),
				im.conn.tls_desc,
			)
			imap_close(&im)
		}
	}

	// 5. STARTTLS is implemented in the client; this server declines it, and
	//    the client must report that rather than continuing in plaintext
	//    while believing it is encrypted.
	{
		im: IMAP
		if err := imap_connect(&im, "127.0.0.1", e.imap_port, {}, context.allocator); err == "" {
			defer imap_close(&im)
			serr := imap_starttls(&im, Dial_Opts{tls = .Insecure})
			tcheck(t, "a refused STARTTLS is reported as an error", serr != "", "the client thought TLS came up")
			tcheck(t, "...and the connection is still plaintext, not half-upgraded", im.conn.tls == .None)
		}
	}
}

tool_exists :: proc(name: string) -> bool {
	for dir in ([?]string{"/usr/bin/", "/bin/", "/usr/local/bin/"}) {
		if os.exists(strings.concatenate({dir, name}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

run_tool :: proc(cmd: []string) -> (out: string, code: int, ok: bool) {
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = cmd},
		context.temp_allocator,
	)
	if err != nil {
		return "", -1, false
	}
	_ = stderr
	return string(stdout), state.exit_code, state.exit_code == 0
}

mkdir_simple :: proc(path: string) -> string {
	if os.exists(path) {
		return ""
	}
	if err := os.make_directory(path, PERM_DIR); err != nil {
		return fmt.aprintf("mkdir %s: %v", path, err)
	}
	return ""
}

rm_dir_files :: proc(path: string) {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err == nil {
		for fi in infos {
			_ = os.remove(fi.fullpath)
		}
	}
	_ = os.remove(path)
}
