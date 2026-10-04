package main

// `chat --selftest` drives the protocol with no UI at all: it starts a real
// server on a scratch port and directory, connects three real clients, and
// asserts on the frames that come back.
//
// It covers what the headline claim rests on — two clients genuinely talking,
// in a defined order — plus the things that are easy to get wrong and
// invisible from the UI: history paging, DM visibility, a client disappearing
// mid-conversation, and whether anything survives a server restart.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import w "wire"

TEST_PORT :: 8979

Checks :: struct {
	pass: int,
	fail: int,
}

ck: Checks

check :: proc(cond: bool, format: string, args: ..any) {
	label := fmt.tprintf(format, ..args)
	if cond {
		ck.pass += 1
		fmt.printfln("  ok   %s", label)
	} else {
		ck.fail += 1
		fmt.printfln("  FAIL %s", label)
	}
}

// ---------------------------------------------------------------------------
// A test client: one socket, one inbox of parsed frames in arrival order.
// ---------------------------------------------------------------------------

TC :: struct {
	sock:   net.TCP_Socket,
	rd:     w.Reader,
	nick:   string,
	inbox:  [dynamic]json.Object,
	closed: bool,
}

tc_dial :: proc(port: int, nick: string, say_hello := true) -> (tc: ^TC, ok: bool) {
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		fmt.eprintfln("  !! %s could not dial: %v", nick, err)
		return nil, false
	}
	_ = net.set_option(sock, .Receive_Timeout, 40 * time.Millisecond)

	tc = new(TC)
	tc.sock = sock
	tc.nick = strings.clone(nick)
	tc.inbox = make([dynamic]json.Object)
	if say_hello {
		e: w.Enc
		w.enc_begin(&e, "hello", context.allocator)
		w.kv_str(&e, "nick", nick)
		tc_send(tc, w.enc_done(&e))
	}
	return tc, true
}

tc_close :: proc(tc: ^TC) {
	if tc == nil || tc.closed {
		return
	}
	net.close(tc.sock)
	tc.closed = true
}

tc_send :: proc(tc: ^TC, payload: string) {
	if tc == nil || tc.closed {
		return
	}
	if !w.send_frame(tc.sock, payload) {
		tc.closed = true
	}
}

// tc_pump reads for `ms` milliseconds and parses whatever arrives.
tc_pump :: proc(tc: ^TC, ms: int) {
	if tc == nil || tc.closed {
		return
	}
	start := time.tick_now()
	buf: [32 * 1024]u8
	for {
		if int(time.duration_milliseconds(time.tick_since(start))) >= ms {
			break
		}
		n, err := net.recv_tcp(tc.sock, buf[:])
		if err == .Timeout || err == .Would_Block {
			continue
		}
		if err == .Interrupted {
			continue
		}
		if err != nil || n == 0 {
			tc.closed = true
			break
		}
		w.reader_feed(&tc.rd, buf[:n])
		for {
			payload, got := w.reader_next(&tc.rd, context.allocator)
			if !got {
				break
			}
			if o, good := w.parse_obj(payload, context.allocator); good {
				append(&tc.inbox, o)
			}
		}
	}
}

// tc_wait pumps until a frame of type `t` appears at or after `from`, or the
// budget runs out. Returns its index.
tc_wait :: proc(tc: ^TC, t: string, from: int, ms := 1500) -> (int, bool) {
	if tc == nil {
		return -1, false
	}
	spent := 0
	for {
		for i in from ..< len(tc.inbox) {
			if w.ostr(tc.inbox[i], "t") == t {
				return i, true
			}
		}
		if spent >= ms || tc.closed {
			return -1, false
		}
		tc_pump(tc, 60)
		spent += 60
	}
}

tc_count :: proc(tc: ^TC, t: string, from: int) -> int {
	if tc == nil {
		return 0
	}
	n := 0
	for i in from ..< len(tc.inbox) {
		if w.ostr(tc.inbox[i], "t") == t {
			n += 1
		}
	}
	return n
}

tc_at :: proc(tc: ^TC, i: int) -> json.Object {
	if tc == nil || i < 0 || i >= len(tc.inbox) {
		return nil
	}
	return tc.inbox[i]
}

// tc_msgs_from lists the message objects broadcast at or after `from`.
tc_msgs_from :: proc(tc: ^TC, from: int, allocator := context.temp_allocator) -> []json.Object {
	out := make([dynamic]json.Object, allocator)
	if tc == nil {
		return out[:]
	}
	for i in from ..< len(tc.inbox) {
		o := tc.inbox[i]
		if w.ostr(o, "t") != "message" {
			continue
		}
		if mo, ok := w.as_obj(o["msg"] or_else nil); ok {
			append(&out, mo)
		}
	}
	return out[:]
}

tc_post :: proc(tc: ^TC, ch, text: string) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "post", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	tc_send(tc, w.enc_done(&e))
}

tc_simple :: proc(tc: ^TC, t: string, k1 := "", v1 := "", k2 := "", v2 := "") {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, t, context.allocator)
	if k1 != "" {
		w.kv_str(&e, k1, v1)
	}
	if k2 != "" {
		w.kv_str(&e, k2, v2)
	}
	tc_send(tc, w.enc_done(&e))
}

// ---------------------------------------------------------------------------
// The server under test
// ---------------------------------------------------------------------------

server_binary :: proc(args: Args) -> string {
	if args.server != "" {
		return args.server
	}
	exe := os.args[0]
	slash := strings.last_index_byte(exe, '/')
	dir := slash > 0 ? exe[:slash] : "."
	return strings.concatenate({dir, "/server/chat-server.bin"})
}

start_server :: proc(bin, dir: string, port: int) -> (os.Process, bool) {
	proc_, err := os.process_start(
		{
			command = {bin, "--port", fmt.tprintf("%d", port), "--dir", dir, "--quiet"},
		},
	)
	if err != nil {
		fmt.eprintfln("chat --selftest: cannot start %s: %v", bin, err)
		return {}, false
	}
	// Wait for the listener rather than guessing a sleep.
	for _ in 0 ..< 100 {
		sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
		if derr == nil {
			net.close(sock)
			return proc_, true
		}
		time.sleep(30 * time.Millisecond)
	}
	fmt.eprintln("chat --selftest: the server never started listening")
	return proc_, false
}

stop_server :: proc(proc_: os.Process) {
	_ = os.process_kill(proc_)
	_, _ = os.process_wait(proc_, 2 * time.Second)
	// Give the kernel a moment to release the port before it is rebound.
	time.sleep(120 * time.Millisecond)
}

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

selftest :: proc(args: Args) -> int {
	bin := server_binary(args)
	if !os.exists(bin) {
		fmt.eprintfln("chat --selftest: no server binary at %s (build it, or pass --server)", bin)
		return 2
	}

	dir := fmt.tprintf("/tmp/palmy-chat-selftest-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)

	port := args.port == w.DEFAULT_PORT ? TEST_PORT : args.port
	fmt.printfln("palmy-chat self-test — server %s, port %d, store %s", bin, port, dir)

	srv_proc, up := start_server(bin, dir, port)
	if !up {
		stop_server(srv_proc)
		return 1
	}

	// -- hello, channels, users -------------------------------------------
	fmt.println("\nhello and the channel list")
	A, aok := tc_dial(port, "alice")
	check(aok, "alice connected")
	if !aok {
		stop_server(srv_proc)
		return 1
	}
	wi, got := tc_wait(A, "welcome", 0)
	check(got, "alice got a welcome")
	check(w.oint(tc_at(A, wi), "proto") == i64(w.PROTO_VERSION), "welcome names protocol %d", w.PROTO_VERSION)
	check(w.ostr(tc_at(A, wi), "nick") == "alice", "welcome echoes the nickname")

	ci, cgot := tc_wait(A, "channels", 0)
	check(cgot, "alice got the channel list")
	names := make(map[string]bool, context.temp_allocator)
	for cv in w.oarr(tc_at(A, ci), "list") {
		if co, ok := w.as_obj(cv); ok {
			names[w.ostr(co, "name")] = true
		}
	}
	check(names["general"], "#general exists")
	check(names["engineering"], "#engineering exists")
	check(names["design"], "#design exists")
	check(names["random"], "#random exists")

	ui_, ugot := tc_wait(A, "users", 0)
	check(ugot, "alice got the member list")
	found_alice := false
	for uv in w.oarr(tc_at(A, ui_), "list") {
		if uo, ok := w.as_obj(uv); ok && w.ostr(uo, "nick") == "alice" {
			found_alice = w.ostr(uo, "state") == "online"
		}
	}
	check(found_alice, "alice is listed online")

	// -- a second client ---------------------------------------------------
	fmt.println("\na second client, and presence")
	mark := len(A.inbox)
	B, bok := tc_dial(port, "bob")
	check(bok, "bob connected")
	if !bok {
		stop_server(srv_proc)
		report()
		return 1
	}
	_, _ = tc_wait(B, "users", 0)

	pi, pgot := tc_wait(A, "presence", mark)
	check(pgot, "alice was told about a presence change")
	check(w.ostr(tc_at(A, pi), "nick") == "bob", "the presence event names bob")
	check(w.ostr(tc_at(A, pi), "state") == "online", "bob came online")

	tc_simple(A, "join", "ch", "general")
	tc_simple(B, "join", "ch", "general")
	_, ja := tc_wait(A, "joined", 0)
	_, jb := tc_wait(B, "joined", 0)
	check(ja, "alice joined #general")
	check(jb, "bob joined #general")

	// -- the headline: two clients talking --------------------------------
	fmt.println("\nmessages, in order, both ways")
	amark, bmark := len(A.inbox), len(B.inbox)
	tc_post(A, "general", "first")
	tc_post(A, "general", "second")
	tc_post(A, "general", "third")

	for _ in 0 ..< 20 {
		tc_pump(B, 60)
		if tc_count(B, "message", bmark) >= 3 {
			break
		}
	}
	tc_pump(A, 150)

	bm := tc_msgs_from(B, bmark)
	check(len(bm) == 3, "bob received 3 messages (got %d)", len(bm))
	if len(bm) == 3 {
		check(w.ostr(bm[0], "text") == "first", "bob's first message is \"first\"")
		check(w.ostr(bm[1], "text") == "second", "bob's second message is \"second\"")
		check(w.ostr(bm[2], "text") == "third", "bob's third message is \"third\"")
		check(
			w.oint(bm[0], "id") < w.oint(bm[1], "id") && w.oint(bm[1], "id") < w.oint(bm[2], "id"),
			"ids arrive strictly increasing (%d, %d, %d)",
			w.oint(bm[0], "id"),
			w.oint(bm[1], "id"),
			w.oint(bm[2], "id"),
		)
		check(w.ostr(bm[0], "nick") == "alice", "the author is recorded as alice")
		check(w.ostr(bm[0], "ch") == "general", "the channel is recorded as general")
	}
	am := tc_msgs_from(A, amark)
	check(len(am) == 3, "alice is echoed her own 3 messages (got %d)", len(am))

	m1 := len(bm) == 3 ? w.oint(bm[0], "id") : 0
	m2 := len(bm) == 3 ? w.oint(bm[1], "id") : 0

	amark = len(A.inbox)
	tc_post(B, "general", "bob replies")
	bi, bgot := tc_wait(A, "message", amark)
	check(bgot, "alice received bob's message")
	if bgot {
		if mo, ok := w.as_obj(tc_at(A, bi)["msg"] or_else nil); ok {
			check(w.ostr(mo, "text") == "bob replies", "the text survived the round trip")
			check(w.ostr(mo, "nick") == "bob", "the author is bob")
			check(w.oint(mo, "id") > m2, "bob's id follows alice's")
		}
	}

	// -- typing indicators -------------------------------------------------
	fmt.println("\ntyping indicators")
	bmark, amark = len(B.inbox), len(A.inbox)
	{
		e: w.Enc
		w.enc_begin(&e, "typing", context.allocator)
		w.kv_str(&e, "ch", "general")
		w.kv_bool(&e, "on", true)
		tc_send(A, w.enc_done(&e))
	}
	ti, tgot := tc_wait(B, "typing", bmark)
	check(tgot, "bob saw a typing indicator")
	check(w.ostr(tc_at(B, ti), "nick") == "alice", "the typist is alice")
	check(w.obool(tc_at(B, ti), "on"), "the indicator is on")
	tc_pump(A, 150)
	check(tc_count(A, "typing", amark) == 0, "a typist is not told about themselves")

	// -- reactions ---------------------------------------------------------
	fmt.println("\nreactions")
	amark = len(A.inbox)
	react(B, m1, "heart", true)
	ri, rgot := tc_wait(A, "react", amark)
	check(rgot, "alice saw the reaction")
	check(w.oint(tc_at(A, ri), "id") == m1, "the reaction names the right message")
	check(w.ostr(tc_at(A, ri), "key") == "heart", "the key is heart")
	check(w.ostr(tc_at(A, ri), "nick") == "bob", "the reactor is bob")

	amark = len(A.inbox)
	react(B, m1, "heart", true)
	tc_pump(A, 200)
	check(tc_count(A, "react", amark) == 0, "reacting twice with the same key changes nothing")

	amark = len(A.inbox)
	react(B, m1, "heart", false)
	ri2, rgot2 := tc_wait(A, "react", amark)
	check(rgot2 && !w.obool(tc_at(A, ri2), "on"), "removing a reaction broadcasts on=false")

	amark = len(A.inbox)
	react(B, m1, "banana", true)
	ei, egot := tc_wait(B, "error", 0)
	check(egot && w.ostr(tc_at(B, ei), "code") == "bad_reaction", "an unknown reaction key is refused")

	// Put one back so the restart has something to find.
	react(B, m1, "rocket", true)
	tc_pump(A, 150)

	// -- edit and delete ---------------------------------------------------
	fmt.println("\nedits and deletions")
	bmark = len(B.inbox)
	{
		e: w.Enc
		w.enc_begin(&e, "edit", context.allocator)
		w.kv_int(&e, "id", m1)
		w.kv_str(&e, "text", "first, corrected")
		tc_send(A, w.enc_done(&e))
	}
	eidx, eok := tc_wait(B, "edit", bmark)
	check(eok, "bob saw the edit")
	check(w.ostr(tc_at(B, eidx), "text") == "first, corrected", "the edited text arrived")
	check(w.oint(tc_at(B, eidx), "edited") > 0, "the edit carries a timestamp")

	bmark = len(B.inbox)
	{
		e: w.Enc
		w.enc_begin(&e, "edit", context.allocator)
		w.kv_int(&e, "id", m1)
		w.kv_str(&e, "text", "bob was here")
		tc_send(B, w.enc_done(&e))
	}
	eidx2, eok2 := tc_wait(B, "error", bmark)
	check(eok2 && w.ostr(tc_at(B, eidx2), "code") == "not_yours", "only the author may edit")

	bmark = len(B.inbox)
	{
		e: w.Enc
		w.enc_begin(&e, "delete", context.allocator)
		w.kv_int(&e, "id", m2)
		tc_send(A, w.enc_done(&e))
	}
	didx, dok := tc_wait(B, "delete", bmark)
	check(dok, "bob saw the deletion")
	check(w.oint(tc_at(B, didx), "id") == m2, "the deletion names the right message")

	// -- history paging ----------------------------------------------------
	fmt.println("\nhistory paging")
	for i in 0 ..< 25 {
		tc_post(A, "general", fmt.tprintf("filler %d", i))
	}
	for _ in 0 ..< 30 {
		tc_pump(A, 50)
		if tc_count(A, "message", 0) >= 28 {
			break
		}
	}

	amark = len(A.inbox)
	history(A, "general", 0, 10)
	hi, hok := tc_wait(A, "history", amark)
	check(hok, "the first history page came back")
	page1 := w.oarr(tc_at(A, hi), "msgs")
	check(len(page1) == 10, "the page holds 10 messages (got %d)", len(page1))
	check(w.obool(tc_at(A, hi), "more"), "the server says there is more")
	oldest: i64 = 0
	ascending := true
	if len(page1) == 10 {
		prev: i64 = 0
		for mv, k in page1 {
			if mo, ok := w.as_obj(mv); ok {
				id := w.oint(mo, "id")
				if k == 0 {
					oldest = id
				}
				if prev != 0 && id <= prev {
					ascending = false
				}
				prev = id
			}
		}
	}
	check(ascending, "a page is oldest-first")

	amark = len(A.inbox)
	history(A, "general", oldest, 10)
	hi2, hok2 := tc_wait(A, "history", amark)
	check(hok2, "the second page came back")
	page2 := w.oarr(tc_at(A, hi2), "msgs")
	check(len(page2) == 10, "the second page holds 10 messages (got %d)", len(page2))
	all_older := true
	for mv in page2 {
		if mo, ok := w.as_obj(mv); ok && w.oint(mo, "id") >= oldest {
			all_older = false
		}
	}
	check(all_older, "every message on page two is older than page one")

	// -- search ------------------------------------------------------------
	fmt.println("\nsearch")
	tc_post(A, "general", "a quite unmistakable sentinel token")
	tc_pump(A, 250)
	amark = len(A.inbox)
	{
		e: w.Enc
		w.enc_begin(&e, "search", context.allocator)
		w.kv_str(&e, "q", "unmistakable sentinel")
		tc_send(A, w.enc_done(&e))
	}
	si, sok := tc_wait(A, "search", amark)
	if !sok {
		si, sok = tc_wait(A, "results", amark)
	}
	check(sok, "search answered")
	if sok {
		hits := w.oarr(tc_at(A, si), "msgs")
		check(len(hits) == 1, "exactly one message matched (got %d)", len(hits))
		if len(hits) == 1 {
			if mo, ok := w.as_obj(hits[0]); ok {
				check(
					strings.contains(w.ostr(mo, "text"), "sentinel"),
					"the hit is the sentinel message",
				)
			}
		}
	}

	// -- direct messages, and who may see them -----------------------------
	fmt.println("\ndirect messages")
	C, cok2 := tc_dial(port, "carol")
	check(cok2, "carol connected")
	tc_pump(C, 200)

	dm := w.dm_name("alice", "bob", context.temp_allocator)
	tc_simple(A, "join", "ch", dm, "kind", "dm")
	tc_simple(B, "join", "ch", dm, "kind", "dm")
	tc_pump(A, 200)
	tc_pump(B, 200)

	bmark = len(B.inbox)
	cmark := len(C.inbox)
	tc_post(A, dm, "just between us")
	dmi, dmok := tc_wait(B, "message", bmark)
	check(dmok, "bob received the direct message")
	if dmok {
		if mo, ok := w.as_obj(tc_at(B, dmi)["msg"] or_else nil); ok {
			check(w.ostr(mo, "ch") == dm, "it arrived on the DM channel")
		}
	}
	tc_pump(C, 300)
	check(tc_count(C, "message", cmark) == 0, "carol received nothing from someone else's DM")

	cmark = len(C.inbox)
	history(C, dm, 0, 10)
	cerr, cerrok := tc_wait(C, "error", cmark)
	check(cerrok && w.ostr(tc_at(C, cerr), "code") == "no_channel", "carol cannot read that history")

	// -- a client vanishing mid-conversation -------------------------------
	fmt.println("\na client disconnecting")
	amark = len(A.inbox)
	tc_close(C)
	cpi, cpok := tc_wait(A, "presence", amark, 2500)
	check(cpok, "alice was told carol left")
	check(
		cpok && w.ostr(tc_at(A, cpi), "nick") == "carol" && w.ostr(tc_at(A, cpi), "state") == "offline",
		"carol is offline",
	)

	amark, bmark = len(A.inbox), len(B.inbox)
	tc_post(A, "general", "still here")
	si2, sok2 := tc_wait(B, "message", bmark)
	check(sok2, "bob still receives after another client vanished")
	_, aok2 := tc_wait(A, "message", amark)
	check(aok2, "alice still receives her own echo")
	_ = si2

	// -- many clients at once ---------------------------------------------
	//
	// The headline claim is that two clients see the same conversation. This
	// is the sharper version: four clients interleaving posts must all see
	// every message, in one order, with the ids the server assigned.
	fmt.println("\nfour clients interleaving")
	stress: [4]^TC
	stress_ok := true
	for i in 0 ..< 4 {
		tc, sok := tc_dial(port, fmt.tprintf("s%d", i))
		stress[i] = tc
		stress_ok &&= sok
		if sok {
			tc_simple(tc, "join", "ch", "stress")
		}
	}
	check(stress_ok, "four more clients connected")
	for tc in stress {
		tc_pump(tc, 120)
	}

	marks: [4]int
	for tc, i in stress {
		marks[i] = len(tc.inbox)
	}
	// Round-robin, so the posts genuinely interleave across connections.
	for round in 0 ..< 30 {
		for tc, i in stress {
			tc_post(tc, "stress", fmt.tprintf("s%d-%d", i, round))
		}
	}
	want := 4 * 30
	for _ in 0 ..< 60 {
		done := true
		for tc, i in stress {
			tc_pump(tc, 40)
			if tc_count(tc, "message", marks[i]) < want {
				done = false
			}
		}
		if done {
			break
		}
	}

	first_ids := make([dynamic]i64, context.temp_allocator)
	same_order := true
	all_complete := true
	increasing := true
	for tc, i in stress {
		got := tc_msgs_from(tc, marks[i])
		if len(got) != want {
			all_complete = false
			continue
		}
		if i == 0 {
			for mo in got {
				append(&first_ids, w.oint(mo, "id"))
			}
			for k in 1 ..< len(first_ids) {
				if first_ids[k] <= first_ids[k - 1] {
					increasing = false
				}
			}
		} else {
			for mo, k in got {
				if k < len(first_ids) && w.oint(mo, "id") != first_ids[k] {
					same_order = false
				}
			}
		}
	}
	check(all_complete, "every one of the four clients received all %d messages", want)
	check(increasing, "the ids arrive strictly increasing")
	check(same_order, "all four clients saw the same order")
	for tc in stress {
		tc_close(tc)
	}

	// -- malformed input ---------------------------------------------------
	fmt.println("\nbad input")
	bmark = len(B.inbox)
	tc_send(B, "{this is not json")
	jerr, jok := tc_wait(B, "error", bmark)
	check(jok && w.ostr(tc_at(B, jerr), "code") == "bad_json", "a malformed frame is refused by name")
	bmark = len(B.inbox)
	tc_post(B, "general", "still usable")
	_, still := tc_wait(B, "message", bmark)
	check(still, "the connection survives a malformed frame")

	bmark = len(B.inbox)
	tc_simple(B, "hello", "nick", "bob")
	h2, h2ok := tc_wait(B, "error", bmark)
	check(h2ok && w.ostr(tc_at(B, h2), "code") == "already_hello", "a second hello is refused")

	bmark = len(B.inbox)
	tc_post(B, "nowhere", "hello?")
	n1, n1ok := tc_wait(B, "error", bmark)
	check(n1ok && w.ostr(tc_at(B, n1), "code") == "no_channel", "posting to a missing channel is refused")

	// Count what the store should hold, before the restart.
	amark = len(A.inbox)
	history(A, "general", 0, 200)
	hfi, hfok := tc_wait(A, "history", amark)
	check(hfok, "a full history page came back")
	before_count := len(w.oarr(tc_at(A, hfi), "msgs"))

	tc_close(A)
	tc_close(B)

	// -- restart -----------------------------------------------------------
	fmt.println("\nsurviving a restart")
	stop_server(srv_proc)
	srv2, up2 := start_server(bin, dir, port)
	check(up2, "the server restarted on the same store")
	if !up2 {
		stop_server(srv2)
		report()
		return ck.fail == 0 ? 0 : 1
	}

	D, dok2 := tc_dial(port, "dave")
	check(dok2, "a new client connected after the restart")
	tc_pump(D, 250)
	history(D, "general", 0, 200)
	ri3, rok3 := tc_wait(D, "history", 0)
	check(rok3, "history came back after the restart")
	msgs := w.oarr(tc_at(D, ri3), "msgs")
	check(len(msgs) == before_count, "the same %d messages are still there (got %d)", before_count, len(msgs))

	saw_edit, saw_delete, saw_react := false, false, false
	for mv in msgs {
		mo, ok := w.as_obj(mv)
		if !ok {
			continue
		}
		id := w.oint(mo, "id")
		if id == m1 {
			saw_edit = w.ostr(mo, "text") == "first, corrected"
			for rv in w.oarr(mo, "reacts") {
				if ro, rok := w.as_obj(rv); rok && w.ostr(ro, "key") == "rocket" {
					saw_react = true
				}
			}
		}
		if id == m2 {
			saw_delete = w.obool(mo, "deleted") && w.ostr(mo, "text") == ""
		}
	}
	check(saw_edit, "the edited text survived the restart")
	check(saw_delete, "the deletion survived the restart")
	check(saw_react, "the reaction survived the restart")

	dmark := len(D.inbox)
	tc_post(D, "general", "after the restart")
	_, dpok := tc_wait(D, "message", dmark)
	check(dpok, "the restarted server accepts new messages")

	tc_close(D)
	stop_server(srv2)

	report()
	return ck.fail == 0 ? 0 : 1
}

report :: proc() {
	fmt.printfln("\n%d assertions: %d passed, %d failed", ck.pass + ck.fail, ck.pass, ck.fail)
}

react :: proc(tc: ^TC, id: i64, key: string, on: bool) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "react", context.allocator)
	w.kv_int(&e, "id", id)
	w.kv_str(&e, "key", key)
	w.kv_bool(&e, "on", on)
	tc_send(tc, w.enc_done(&e))
}

history :: proc(tc: ^TC, ch: string, before: i64, limit: int) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "history", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "before", before)
	w.kv_int(&e, "limit", i64(limit))
	tc_send(tc, w.enc_done(&e))
}
