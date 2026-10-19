// palm-collab-cli — collaborative documents from the command line, and the
// end-to-end test of the sync service.
//
//	palm-collab-cli [--dir TOKENSTORE] [--as HANDLE] <command>
//
//	signup|signin <email> <password>
//	identity <handle> <display name> [kind] [color]
//	new <doc|sheet|deck> <title>        prints the document id
//	ls                                  what this identity can open
//	share <doc> <handle> <view|comment|suggest|edit>
//	unshare <doc> <handle>
//	link <doc> <view|comment|suggest>   prints a link token, once
//	cat <doc> [seq-key]                 the text of one sequence, synced live
//	append <doc> <text> [seq-key]       type at the end, wait for the ack
//	history <doc>                       sessions and named versions
//	e2e <dirA> <handleA> <dirB> <handleB>
//
// The sync server is PALM_COLLAB_URL (ws://127.0.0.1:8790), the database
// PALM_CLOUD_URL, as for every Palmframe program.
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ck "../../../apps/cloudkit"
import client "../client"
import crdt "../crdt"

dir_flag := ""
as_flag := ""

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("palm-collab-cli: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

open_account :: proc(dir, handle: string) -> client.Account {
	a, err := client.account_open(dir, handle)
	if err != "" {
		die("%s", err)
	}
	return a
}

open_session :: proc(a: ^client.Account, doc: string, state_dir: string, app := "cli") -> ^client.Session {
	host, port := client.server_address()
	return client.session_open(
		client.Config {
			host = host,
			port = port,
			doc_id = doc,
			as_id = a.me.id,
			token = client.account_token(a),
			app = app,
			dir = state_dir,
		},
	)
}

// wait polls until `cond` holds or the timeout passes.
wait :: proc(s: ^client.Session, cond: proc(s: ^client.Session) -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < seconds {
		client.poll(s)
		if cond(s) {
			return true
		}
		time.sleep(20 * time.Millisecond)
	}
	return false
}

is_live :: proc(s: ^client.Session) -> bool {return s.status == .Live}
is_refused :: proc(s: ^client.Session) -> bool {return s.status == .Refused}
all_acked :: proc(s: ^client.Session) -> bool {return s.status == .Live && client.pending_count(s) == 0}

main :: proc() {
	args := make([dynamic]string)
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--dir":
			i += 1
			dir_flag = os.args[i]
		case "--as":
			i += 1
			as_flag = os.args[i]
		case:
			append(&args, os.args[i])
		}
	}
	if len(args) == 0 {
		fmt.println("palm-collab-cli [--dir D] [--as HANDLE] signup|signin|identity|new|ls|share|unshare|link|cat|append|history|e2e ...")
		return
	}
	cmd := args[0]
	rest := args[1:]
	switch cmd {
	case "signup", "signin":
		if len(rest) < 2 {die("%s <email> <password>", cmd)}
		c, e := ck.open(dir = dir_flag, app = "collab")
		if !ck.ok(e) {die("%s", e.message)}
		if cmd == "signup" {
			e = ck.sign_up(c, rest[0], rest[1])
		} else {
			e = ck.sign_in(c, rest[0], rest[1])
		}
		if !ck.ok(e) {die("%s", e.message)}
		fmt.printfln("signed in as %s", c.session.email)
	case "identity":
		if len(rest) < 2 {die("identity <handle> <name> [kind] [color]")}
		c, e := ck.open(dir = dir_flag, app = "collab")
		if !ck.ok(e) {die("%s", e.message)}
		kind := len(rest) > 2 ? rest[2] : "personal"
		color := len(rest) > 3 ? rest[3] : "indigo"
		id, ie := ck.create_identity(c, rest[0], rest[1], kind, color)
		if !ck.ok(ie) {die("%s", ie.message)}
		fmt.println(id.id)
	case "new":
		if len(rest) < 2 {die("new <doc|sheet|deck> <title>")}
		a := open_account(dir_flag, as_flag)
		id, err := client.doc_create(&a, rest[0], rest[1])
		if err != "" {die("%s", err)}
		fmt.println(id)
	case "ls":
		a := open_account(dir_flag, as_flag)
		v, err := client.rpc_raw(&a, "collab_documents_mine", "{}")
		if err != "" {die("%s", err)}
		for d in ck.array(v) {
			fmt.printfln("%s  %-5s  %-7s  %-24s  owner %s", ck.get_str(d, "id"), ck.get_str(d, "kind"), ck.get_str(d, "role"), ck.get_str(d, "title"), ck.get_str(d, "owner_handle"))
		}
	case "share":
		if len(rest) < 3 {die("share <doc> <handle> <role>")}
		a := open_account(dir_flag, as_flag)
		if err := client.doc_share(&a, rest[0], rest[1], rest[2]); err != "" {die("%s", err)}
		fmt.printfln("shared with %s as %s", rest[1], rest[2])
	case "unshare":
		if len(rest) < 2 {die("unshare <doc> <handle>")}
		a := open_account(dir_flag, as_flag)
		v, err := client.rpc_raw(&a, "collab_unshare", fmt.tprintf(`{{"p_doc":"%s","p_handle":"%s"}}`, rest[0], rest[1]))
		if err != "" {die("%s", err)}
		fmt.println(v)
	case "link":
		if len(rest) < 2 {die("link <doc> <role>")}
		a := open_account(dir_flag, as_flag)
		tok, err := client.doc_make_link(&a, rest[0], rest[1])
		if err != "" {die("%s", err)}
		fmt.println(tok)
	case "cat", "append":
		if len(rest) < 1 || (cmd == "append" && len(rest) < 2) {die("cat <doc> | append <doc> <text>")}
		a := open_account(dir_flag, as_flag)
		key := "b"
		if cmd == "cat" && len(rest) > 1 {key = rest[1]}
		if cmd == "append" && len(rest) > 2 {key = rest[2]}
		s := open_session(&a, rest[0], "")
		if !wait(s, is_live) {
			die("could not sync: %v %s", s.status, s.error)
		}
		if cmd == "append" {
			sq := crdt.seq_get(s.doc, key)
			crdt.insert_text(s.doc, key, sq.vis, rest[1])
			client.flush(s)
			if !wait(s, all_acked) {die("not acknowledged: %s", s.error)}
		}
		fmt.println(crdt.read_text(s.doc, key))
		client.session_close(s)
	case "history":
		if len(rest) < 1 {die("history <doc>")}
		a := open_account(dir_flag, as_flag)
		v, err := client.rpc_raw(&a, "collab_history", fmt.tprintf(`{{"p_doc":"%s"}}`, rest[0]))
		if err != "" {die("%s", err)}
		out, _ := json.marshal(v, {pretty = true})
		fmt.println(string(out))
	case "e2e":
		if len(rest) < 4 {die("e2e <dirA> <handleA> <dirB> <handleB>")}
		os.exit(e2e(rest[0], rest[1], rest[2], rest[3]))
	case:
		die("unknown command %s", cmd)
	}
}

// ---------------------------------------------------------------------------
// The end-to-end test
// ---------------------------------------------------------------------------

passed, failed: int

check :: proc(ok: bool, what: string) {
	if ok {
		passed += 1
		fmt.printfln("ok    %s", what)
	} else {
		failed += 1
		fmt.printfln("FAIL  %s", what)
	}
}

text_of :: proc(s: ^client.Session) -> string {
	return crdt.read_text(s.doc, "b")
}

e2e :: proc(dir_a, handle_a, dir_b, handle_b: string) -> int {
	scratch := fmt.tprintf("%s/e2e-%d", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", time.now()._nsec)
	sa_dir := fmt.tprintf("%s/a", scratch)
	sb_dir := fmt.tprintf("%s/b", scratch)
	sb2_dir := fmt.tprintf("%s/b2", scratch)

	a := open_account(dir_a, handle_a)
	b := open_account(dir_b, handle_b)
	fmt.printfln("A = %s (%s), B = %s (%s)", a.me.handle, a.me.display_name, b.me.handle, b.me.display_name)

	doc, err := client.doc_create(&a, "doc", "e2e")
	check(err == "", fmt.tprintf("A creates a document %s", err))

	// 1. A types; the log has it.
	sa := open_session(&a, doc, sa_dir)
	check(wait(sa, is_live), "A's window syncs")
	crdt.insert_text(sa.doc, "b", 0, "Hello")
	client.flush(sa)
	check(wait(sa, all_acked) && sa.last_seq == 1, "A's first edit is acknowledged as update 1")

	// 2. B has no grant: refused.
	sb := open_session(&b, doc, sb_dir)
	check(wait(sb, is_refused), fmt.tprintf("B without a grant is refused (%s)", sb.error))
	client.session_close(sb)

	// 3. View: B sees, cannot write.
	check(client.doc_share(&a, doc, b.me.handle, "view") == "", "A shares with B: view")
	sb = open_session(&b, doc, sb_dir)
	check(wait(sb, is_live), "B (view) syncs")
	check(wait(sb, proc(s: ^client.Session) -> bool {return crdt.read_text(s.doc, "b") == "Hello"}), "B sees A's text")
	check(sb.role == "view", fmt.tprintf("the server says B is a viewer (%s)", sb.role))
	crdt.insert_text(sb.doc, "b", 0, "forged ")
	client.flush(sb)
	check(wait(sb, proc(s: ^client.Session) -> bool {return s.nacks > 0}), "the server refuses a viewer's edit")
	client.session_close(sb)

	// 4. Comment: B can comment but not edit text.
	check(client.doc_share(&a, doc, b.me.handle, "comment") == "", "A raises B to comment")
	sb = open_session(&b, doc, sb2_dir)
	check(wait(sb, is_live), "B (comment) syncs")
	crdt.set_str(sb.doc, "cmt/c1", "text", "Is this right?")
	client.flush(sb)
	check(wait(sb, all_acked) && sb.nacks == 0, "a commenter's comment is accepted")
	crdt.insert_text(sb.doc, "b", 0, "sneaky ")
	client.flush(sb)
	check(wait(sb, proc(s: ^client.Session) -> bool {return s.nacks > 0}), "a commenter's text edit is refused")
	client.session_close(sb)

	// 5. Edit, concurrently.
	check(client.doc_share(&a, doc, b.me.handle, "edit") == "", "A raises B to edit")
	sb = open_session(&b, doc, fmt.tprintf("%s/b3", scratch))
	check(wait(sb, is_live), "B (edit) syncs")
	wait(sb, proc(s: ^client.Session) -> bool {return crdt.read_text(s.doc, "b") == "Hello"})
	crdt.insert_text(sa.doc, "b", 5, " world")
	crdt.insert_text(sb.doc, "b", 0, "Oh, ")
	client.flush(sa)
	client.flush(sb)
	conv :: proc(s: ^client.Session) -> bool {return crdt.read_text(s.doc, "b") == "Oh, Hello world"}
	check(wait(sa, conv) && wait(sb, conv), fmt.tprintf("concurrent edits converge: %q / %q", text_of(sa), text_of(sb)))

	// 6. Presence.
	client.set_awareness(sa, `{"c":"b","o":3}`)
	check(wait(sb, proc(s: ^client.Session) -> bool {
		for p in s.peers {
			if client.jint(p.state, "o") == 3 {return true}
		}
		return false
	}), "B sees A's caret, with A's verified name")
	if len(sb.peers) > 0 {
		check(sb.peers[0].identity.handle == a.me.handle, fmt.tprintf("presence names A as %s", sb.peers[0].identity.handle))
	}

	// 7. Offline: B drops off, both edit, B comes back.
	client.go_offline(sb)
	crdt.insert_text(sb.doc, "b", crdt.seq_get(sb.doc, "b").vis, " [B offline]")
	client.flush(sb)
	crdt.insert_text(sa.doc, "b", 0, "[A online] ")
	client.flush(sa)
	check(wait(sa, all_acked), "A's edit lands while B is away")
	check(client.pending_count(sb) == 1, "B's offline edit waits in the outbox")
	client.save_local(sb)
	client.reconnect(sb)
	merged :: proc(s: ^client.Session) -> bool {
		return crdt.read_text(s.doc, "b") == "[A online] Oh, Hello world [B offline]"
	}
	check(wait(sb, merged) && wait(sb, all_acked) && wait(sa, merged), fmt.tprintf("the offline edit merges on reconnect: %q / %q", text_of(sa), text_of(sb)))

	// 8. Reopening from the local copy catches up incrementally.
	b_state := sb.cfg.dir
	_ = b_state
	client.session_close(sb)
	crdt.insert_text(sa.doc, "b", 0, ">")
	client.flush(sa)
	wait(sa, all_acked)
	sb = open_session(&b, doc, fmt.tprintf("%s/b3", scratch))
	check(sb.last_seq > 0 && crdt.read_text(sb.doc, "b") != "", "B reopens instantly from its local copy, before the network")
	opened :: proc(s: ^client.Session) -> bool {return crdt.read_text(s.doc, "b") == ">[A online] Oh, Hello world [B offline]"}
	check(wait(sb, opened), fmt.tprintf("and catches up with what it missed: %q (seq %d, status %v)", text_of(sb), sb.last_seq, sb.status))

	// 9. History: sessions, and the state as it was after update 1.
	hv, herr := client.rpc_raw(&a, "collab_history", fmt.tprintf(`{{"p_doc":"%s"}}`, doc))
	sessions := ck.array(ck.get(hv, "sessions"))
	check(herr == "" && len(sessions) >= 1 && len(ck.array(ck.get(sessions[0], "authors"))) == 2, fmt.tprintf("history groups the log into %d session(s), naming both authors", len(sessions)))
	sv, serr := client.rpc_raw(&a, "collab_state_at", fmt.tprintf(`{{"p_doc":"%s","p_seq":1}}`, doc))
	old := crdt.doc_make(99)
	if serr == "" {
		if snap := ck.get_str(sv, "snapshot"); snap != "" {
			d, _ := base64.decode(snap)
			crdt.doc_destroy(old)
			old, _ = crdt.doc_load(99, d)
		}
		for u in ck.array(ck.get(sv, "updates")) {
			if s, ok := u.(json.String); ok {
				d, _ := base64.decode(s)
				crdt.apply_update(old, d)
			}
		}
	}
	check(crdt.read_text(old, "b") == "Hello", fmt.tprintf("the version after update 1 reads %q", crdt.read_text(old, "b")))

	// 10. Revocation reaches an open window.
	v, rerr := client.rpc_raw(&a, "collab_unshare", fmt.tprintf(`{{"p_doc":"%s","p_handle":"%s"}}`, doc, b.me.handle))
	_ = v
	check(rerr == "", "A revokes B")
	check(wait(sb, is_refused, 15), fmt.tprintf("B's open window is closed by the server (%s)", sb.error))

	client.session_close(sb)
	client.session_close(sa)
	fmt.printfln("%d passed, %d failed", passed, failed)
	return failed == 0 ? 0 : 1
}
