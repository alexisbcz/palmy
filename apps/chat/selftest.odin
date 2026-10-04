package main

// `chat --selftest` drives the protocol with no UI at all: it starts a real
// server on a scratch port and directory, connects three real clients, and
// asserts on the frames that come back.
//
// It covers what the headline claim rests on — two clients genuinely talking,
// in a defined order — plus the things that are easy to get wrong and
// invisible from the UI: history paging, DM visibility, a client disappearing
// mid-conversation, and whether anything survives a server restart.

import "core:encoding/base64"
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

// inbox_len is the only way the test body reads a client's inbox. `tc_dial`
// returns nil when the dial is refused — which happens the moment anything
// takes the server away — and a direct `len(tc.inbox)` on that nil is a
// segfault rather than a failed assertion. This is how the first version of
// this file crashed instead of reporting.
inbox_len :: proc(tc: ^TC) -> int {
	return tc == nil ? 0 : len(tc.inbox)
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

tc_post_thread :: proc(tc: ^TC, ch, text: string, thread: i64) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "post", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	w.kv_int(&e, "thread", thread)
	tc_send(tc, w.enc_done(&e))
}

tc_thread_get :: proc(tc: ^TC, id: i64) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "thread", context.allocator)
	w.kv_int(&e, "id", id)
	tc_send(tc, w.enc_done(&e))
}

tc_read :: proc(tc: ^TC, ch: string, id: i64) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "read", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_int(&e, "id", id)
	tc_send(tc, w.enc_done(&e))
}

tc_reads :: proc(tc: ^TC) {
	tc_simple(tc, "reads")
}

tc_attach :: proc(tc: ^TC, ch, name, mime, text: string, data: []u8) {
	if tc == nil {
		return
	}
	b64, _ := base64.encode(data, allocator = context.allocator)
	e: w.Enc
	w.enc_begin(&e, "attach", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "name", name)
	w.kv_str(&e, "mime", mime)
	w.kv_str(&e, "text", text)
	w.kv_str(&e, "data", b64)
	tc_send(tc, w.enc_done(&e))
}

tc_fetch :: proc(tc: ^TC, id: i64) {
	if tc == nil {
		return
	}
	e: w.Enc
	w.enc_begin(&e, "fetch", context.allocator)
	w.kv_int(&e, "id", id)
	tc_send(tc, w.enc_done(&e))
}

Read_Row :: struct {
	id:      i64,
	unread:  int,
	threads: int,
	mention: bool,
	ok:      bool,
}

// read_row pulls one channel's row out of the next `reads` frame at or after
// `from`. Every unread assertion in this file goes through here, so none of
// them can accidentally read a number the client computed for itself.
read_row :: proc(tc: ^TC, ch: string, from: int) -> Read_Row {
	i, got := tc_wait(tc, "reads", from)
	if !got {
		return {}
	}
	for rv in w.oarr(tc_at(tc, i), "list") {
		ro, is := w.as_obj(rv)
		if !is || w.ostr(ro, "ch") != ch {
			continue
		}
		return Read_Row {
			id      = w.oint(ro, "id"),
			unread  = int(w.oint(ro, "unread")),
			threads = int(w.oint(ro, "threads")),
			mention = w.obool(ro, "mention"),
			ok      = true,
		}
	}
	return {}
}

// read_echo is the same, for the `read` frame the server sends back when a
// cursor moves.
read_echo :: proc(tc: ^TC, ch: string, from: int) -> Read_Row {
	for spent := 0; spent <= 1500; spent += 60 {
		for i in from ..< len(tc.inbox) {
			o := tc.inbox[i]
			if w.ostr(o, "t") == "read" && w.ostr(o, "ch") == ch {
				return Read_Row {
					id      = w.oint(o, "id"),
					unread  = int(w.oint(o, "unread")),
					threads = int(w.oint(o, "threads")),
					mention = w.obool(o, "mention"),
					ok      = true,
				}
			}
		}
		if tc.closed {
			break
		}
		tc_pump(tc, 60)
	}
	return {}
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
	mark := inbox_len(A)
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
	amark, bmark := inbox_len(A), inbox_len(B)
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

	amark = inbox_len(A)
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
	bmark, amark = inbox_len(B), inbox_len(A)
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
	amark = inbox_len(A)
	react(B, m1, "heart", true)
	ri, rgot := tc_wait(A, "react", amark)
	check(rgot, "alice saw the reaction")
	check(w.oint(tc_at(A, ri), "id") == m1, "the reaction names the right message")
	check(w.ostr(tc_at(A, ri), "key") == "heart", "the key is heart")
	check(w.ostr(tc_at(A, ri), "nick") == "bob", "the reactor is bob")

	amark = inbox_len(A)
	react(B, m1, "heart", true)
	tc_pump(A, 200)
	check(tc_count(A, "react", amark) == 0, "reacting twice with the same key changes nothing")

	amark = inbox_len(A)
	react(B, m1, "heart", false)
	ri2, rgot2 := tc_wait(A, "react", amark)
	check(rgot2 && !w.obool(tc_at(A, ri2), "on"), "removing a reaction broadcasts on=false")

	amark = inbox_len(A)
	react(B, m1, "banana", true)
	ei, egot := tc_wait(B, "error", 0)
	check(egot && w.ostr(tc_at(B, ei), "code") == "bad_reaction", "an unknown reaction key is refused")

	// Put one back so the restart has something to find.
	react(B, m1, "rocket", true)
	tc_pump(A, 150)

	// -- edit and delete ---------------------------------------------------
	fmt.println("\nedits and deletions")
	bmark = inbox_len(B)
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

	bmark = inbox_len(B)
	{
		e: w.Enc
		w.enc_begin(&e, "edit", context.allocator)
		w.kv_int(&e, "id", m1)
		w.kv_str(&e, "text", "bob was here")
		tc_send(B, w.enc_done(&e))
	}
	eidx2, eok2 := tc_wait(B, "error", bmark)
	check(eok2 && w.ostr(tc_at(B, eidx2), "code") == "not_yours", "only the author may edit")

	bmark = inbox_len(B)
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

	amark = inbox_len(A)
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

	amark = inbox_len(A)
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
	amark = inbox_len(A)
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

	bmark = inbox_len(B)
	cmark := inbox_len(C)
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

	cmark = inbox_len(C)
	history(C, dm, 0, 10)
	cerr, cerrok := tc_wait(C, "error", cmark)
	check(cerrok && w.ostr(tc_at(C, cerr), "code") == "no_channel", "carol cannot read that history")

	// -- a client vanishing mid-conversation -------------------------------
	fmt.println("\na client disconnecting")
	amark = inbox_len(A)
	tc_close(C)
	cpi, cpok := tc_wait(A, "presence", amark, 2500)
	check(cpok, "alice was told carol left")
	check(
		cpok && w.ostr(tc_at(A, cpi), "nick") == "carol" && w.ostr(tc_at(A, cpi), "state") == "offline",
		"carol is offline",
	)

	amark, bmark = inbox_len(A), inbox_len(B)
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
		marks[i] = inbox_len(tc)
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

	// -- threads ----------------------------------------------------------
	//
	// A thread is a first-class place, not a decorated reply. The two
	// properties worth asserting are that its replies stay out of the
	// channel timeline, and that the parent's count can never be seen
	// before the reply it counts.
	fmt.println("\nthreads")
	// Drain first. The four stress clients posted a hundred and twenty
	// messages to a public channel, which every connection can see, so there
	// is a tail of those still arriving — and `tc_wait(A, "message", mark)`
	// would hand back one of them as the root. Ask for the message by its
	// text instead of by position.
	for _ in 0 ..< 10 {
		tc_pump(A, 60)
		tc_pump(B, 60)
	}
	amark, bmark = inbox_len(A), inbox_len(B)
	ROOT_TEXT :: "Thread root: the layout pass"
	tc_post(A, "general", ROOT_TEXT)
	root_id: i64 = 0
	for _ in 0 ..< 25 {
		tc_pump(A, 60)
		for mo in tc_msgs_from(A, amark) {
			if w.ostr(mo, "text") == ROOT_TEXT {
				root_id = w.oint(mo, "id")
			}
		}
		if root_id != 0 {
			break
		}
	}
	check(root_id != 0, "the thread root was posted, and is the message we think it is")
	root_in_general := false
	for mo in tc_msgs_from(A, amark) {
		if w.oint(mo, "id") == root_id {
			root_in_general = w.ostr(mo, "ch") == "general"
		}
	}
	check(root_in_general, "the root is in #general")

	bmark = inbox_len(B)
	for k in 1 ..= 3 {
		tc_post_thread(B, "general", fmt.tprintf("thread reply %d", k), root_id)
		for _ in 0 ..< 20 {
			tc_pump(B, 50)
			if tc_count(B, "replies", bmark) >= k {
				break
			}
		}
	}
	tc_pump(B, 200)

	treplies := make([dynamic]i64, context.temp_allocator)
	msg_order := make([dynamic]int, context.temp_allocator)
	rep_order := make([dynamic]int, context.temp_allocator)
	last_n := 0
	for i in bmark ..< inbox_len(B) {
		o := tc_at(B, i)
		switch w.ostr(o, "t") {
		case "message":
			if mo, ok := w.as_obj(o["msg"] or_else nil); ok && w.oint(mo, "thread") == root_id {
				append(&treplies, w.oint(mo, "id"))
				append(&msg_order, i)
			}
		case "replies":
			if w.oint(o, "id") == root_id {
				append(&rep_order, i)
				last_n = int(w.oint(o, "n"))
			}
		}
	}
	check(len(treplies) == 3, "three thread replies were broadcast (got %d)", len(treplies))
	check(len(rep_order) == 3, "three reply-count updates were broadcast (got %d)", len(rep_order))
	check(last_n == 3, "the final count is 3 (got %d)", last_n)
	order_ok := len(msg_order) == 3 && len(rep_order) == 3
	if order_ok {
		for k in 0 ..< 3 {
			if msg_order[k] >= rep_order[k] {
				order_ok = false
			}
		}
	}
	check(order_ok, "every reply arrives before the count that counts it")
	thread_asc :=
		len(treplies) == 3 &&
		treplies[0] < treplies[1] &&
		treplies[1] < treplies[2] &&
		treplies[0] > root_id
	check(thread_asc, "thread replies take ids from the one counter, after the root")

	// The timeline must not hold them.
	amark = inbox_len(A)
	history(A, "general", 0, 200)
	thi, thok := tc_wait(A, "history", amark)
	check(thok, "history came back")
	in_timeline, root_count := 0, -1
	for mv in w.oarr(tc_at(A, thi), "msgs") {
		mo, ok := w.as_obj(mv)
		if !ok {
			continue
		}
		if w.oint(mo, "thread") != 0 {
			in_timeline += 1
		}
		if w.oint(mo, "id") == root_id {
			root_count = int(w.oint(mo, "replies"))
		}
	}
	check(in_timeline == 0, "no thread reply appears in the channel timeline (found %d)", in_timeline)
	check(root_count == 3, "the root in history carries its reply count (got %d)", root_count)

	// The thread itself.
	amark = inbox_len(A)
	tc_thread_get(A, root_id)
	tgi, tgok := tc_wait(A, "thread", amark)
	check(tgok, "the thread came back")
	if tgok {
		to_ := tc_at(A, tgi)
		check(w.oint(to_, "id") == root_id, "the thread is named by its root id")
		check(w.ostr(to_, "ch") == "general", "the thread knows its channel")
		if ro, ok := w.as_obj(to_["root"] or_else nil); ok {
			check(w.oint(ro, "id") == root_id, "the root message came with it")
			check(w.oint(ro, "replies") == 3, "the root carries replies=3")
		}
		tms := w.oarr(to_, "msgs")
		check(len(tms) == 3, "the thread holds 3 replies (got %d)", len(tms))
		asc := true
		prev: i64 = 0
		for mv in tms {
			if mo, ok := w.as_obj(mv); ok {
				if prev != 0 && w.oint(mo, "id") <= prev {
					asc = false
				}
				prev = w.oint(mo, "id")
			}
		}
		check(asc, "the thread is oldest-first")
	}

	// Asking from inside the thread finds the same thread: one level deep.
	amark = inbox_len(A)
	tc_thread_get(A, len(treplies) == 3 ? treplies[1] : root_id)
	tgi2, tgok2 := tc_wait(A, "thread", amark)
	check(tgok2 && w.oint(tc_at(A, tgi2), "id") == root_id, "a reply resolves to its own root")

	// Replying "inside a reply" lands in the same thread rather than nesting.
	bmark = inbox_len(B)
	tc_post_thread(B, "general", "nested on purpose", len(treplies) == 3 ? treplies[2] : root_id)
	nmi, nmok := tc_wait(B, "message", bmark)
	nested_root: i64 = -1
	if nmok {
		if mo, ok := w.as_obj(tc_at(B, nmi)["msg"] or_else nil); ok {
			nested_root = w.oint(mo, "thread")
		}
	}
	check(nested_root == root_id, "a reply to a reply belongs to the root, not the reply")

	// A root in another channel is refused rather than quietly re-homed.
	bmark = inbox_len(B)
	tc_post_thread(B, "design", "wrong channel", root_id)
	wci, wcok := tc_wait(B, "error", bmark)
	check(
		wcok && w.ostr(tc_at(B, wci), "code") == "no_thread",
		"a thread root in another channel is refused",
	)

	// -- read cursors, and what a reconnect finds -------------------------
	//
	// This is the one thing a chat client must not get wrong. Unread used
	// to be "the highest id seen while connected", so every reconnect
	// marked everything read. The cursor lives on the server now, so the
	// same person coming back finds the same count.
	fmt.println("\nread cursors across a reconnect")
	E1, e1ok := tc_dial(port, "erin")
	check(e1ok, "erin connected")
	seeded := read_row(E1, "general", 0)
	check(seeded.ok, "erin was told her read cursors at hello")
	check(seeded.unread == 0, "a nickname the server has never seen starts caught up (got %d)", seeded.unread)
	check(seeded.id > 0, "her cursor was parked at the newest message (%d)", seeded.id)
	tc_close(E1)

	tc_post(A, "general", "while erin was away: one")
	tc_post(A, "general", "ping erin about the margins")
	tc_post(A, "general", "while erin was away: three")
	tc_pump(A, 400)

	E2, e2ok := tc_dial(port, "erin")
	check(e2ok, "erin reconnected")
	back := read_row(E2, "general", 0)
	check(back.ok, "the reconnect carried her cursors")
	check(back.unread == 3, "a reconnect finds 3 unread, not 0 (got %d)", back.unread)
	check(back.mention, "the message naming her is flagged as a mention")
	check(back.id == seeded.id, "the cursor itself did not move while she was away")

	newest_general := back.id
	history(E2, "general", 0, 200)
	ehi, ehok := tc_wait(E2, "history", 0)
	if ehok {
		for mv in w.oarr(tc_at(E2, ehi), "msgs") {
			if mo, ok := w.as_obj(mv); ok && w.oint(mo, "id") > newest_general {
				newest_general = w.oint(mo, "id")
			}
		}
	}
	emark := inbox_len(E2)
	tc_read(E2, "general", newest_general)
	echoed := read_echo(E2, "general", emark)
	check(echoed.ok, "moving the cursor is echoed back")
	check(echoed.id == newest_general, "the cursor is where she put it (%d)", echoed.id)
	check(echoed.unread == 0, "nothing is unread behind it (got %d)", echoed.unread)
	check(!echoed.mention, "the mention flag cleared with it")

	emark = inbox_len(E2)
	tc_read(E2, "general", newest_general - 1)
	back2 := read_echo(E2, "general", emark)
	check(
		back2.ok && back2.id == newest_general,
		"a cursor never moves backwards (asked for %d, stayed %d)",
		newest_general - 1,
		back2.id,
	)
	tc_close(E2)

	E3, e3ok := tc_dial(port, "erin")
	check(e3ok, "erin reconnected a second time")
	still_read := read_row(E3, "general", 0)
	check(
		still_read.ok && still_read.unread == 0,
		"what she read stays read across a reconnect (got %d)",
		still_read.unread,
	)

	// A thread reply is not a timeline row, so it is counted apart from the
	// badge rather than promising a message that is not there.
	emark = inbox_len(E3)
	tc_post_thread(B, "general", "a reply erin has not seen", root_id)
	tc_pump(B, 250)
	tc_reads(E3)
	trow := read_row(E3, "general", emark)
	check(trow.ok, "erin asked for her cursors again")
	check(trow.unread == 0, "a thread reply does not inflate the channel badge (got %d)", trow.unread)
	check(trow.threads == 1, "it is counted as an unread thread reply instead (got %d)", trow.threads)

	// A partial read: the cursor is a position, not a flag.
	tc_simple(A, "join", "ch", "quiet")
	tc_pump(A, 200)
	qmark := inbox_len(A)
	for k in 1 ..= 4 {
		tc_post(A, "quiet", fmt.tprintf("quiet %d", k))
	}
	for _ in 0 ..< 20 {
		tc_pump(A, 50)
		if tc_count(A, "message", qmark) >= 4 {
			break
		}
	}
	qids := make([dynamic]i64, context.temp_allocator)
	for mo in tc_msgs_from(A, qmark) {
		if w.ostr(mo, "ch") == "quiet" {
			append(&qids, w.oint(mo, "id"))
		}
	}
	check(len(qids) == 4, "four messages landed in #quiet (got %d)", len(qids))

	emark = inbox_len(E3)
	tc_reads(E3)
	qrow := read_row(E3, "quiet", emark)
	check(qrow.ok && qrow.unread == 4, "a channel erin has never opened is 4 unread (got %d)", qrow.unread)

	// A cursor belongs to the person, not to the connection, so a second
	// client of the same nickname is told the moment the first one reads
	// something — without asking, and with the same numbers.
	E3b, e3bok := tc_dial(port, "erin")
	check(e3bok, "erin opened a second client")
	tc_pump(E3b, 300)
	bmark2 := inbox_len(E3b)

	emark = inbox_len(E3)
	tc_read(E3, "quiet", len(qids) == 4 ? qids[1] : 0)
	qecho := read_echo(E3, "quiet", emark)
	check(qecho.ok && qecho.unread == 2, "reading two of four leaves two unread (got %d)", qecho.unread)

	other := read_echo(E3b, "quiet", bmark2)
	check(other.ok, "her other client was told, without asking for it")
	check(other.id == qecho.id, "both of her clients hold the same cursor (%d and %d)", other.id, qecho.id)
	check(other.unread == 2, "and the same count (got %d)", other.unread)
	tc_close(E3b)
	tc_close(E3)

	// -- attachments -------------------------------------------------------
	fmt.println("\nattachments")
	payload := make([]u8, 2048, context.temp_allocator)
	for i in 0 ..< len(payload) {
		payload[i] = u8((i * 7 + 13) & 0xff)
	}
	amark = inbox_len(A)
	// A deliberately hostile name. The server builds the stored name; it
	// never joins what a client sent onto its own path.
	tc_attach(A, "general", "../escaped.txt", "text/plain", "the parity numbers", payload)
	fai, faok := tc_wait(A, "message", amark, 3000)
	check(faok, "the attachment came back as a message")
	file_id: i64 = 0
	stored_name := ""
	if faok {
		if mo, ok := w.as_obj(tc_at(A, fai)["msg"] or_else nil); ok {
			check(w.ostr(mo, "text") == "the parity numbers", "the caption travelled with it")
			if fo, has := w.as_obj(mo["file"] or_else nil); has {
				file_id = w.oint(fo, "id")
				stored_name = strings.clone(w.ostr(fo, "name"), context.temp_allocator)
				check(
					int(w.oint(fo, "size")) == len(payload),
					"the size is %d (got %d)",
					len(payload),
					w.oint(fo, "size"),
				)
				check(w.ostr(fo, "mime") == "text/plain", "the mime type survived")
			}
		}
	}
	check(file_id != 0, "the attachment has an id")
	check(stored_name == "escaped.txt", "the name was reduced to one component (got %q)", stored_name)
	check(!strings.contains(stored_name, "/"), "no separator survived in the stored name")
	check(!strings.contains(stored_name, ".."), "no parent reference survived in the stored name")
	check(
		os.exists(fmt.tprintf("%s/files/%d-%s", dir, file_id, stored_name)),
		"the bytes are in the server's own store",
	)
	check(!os.exists(fmt.tprintf("%s/escaped.txt", dir)), "nothing was written outside the store")

	amark = inbox_len(A)
	tc_fetch(A, file_id)
	dfi, dfok := tc_wait(A, "file", amark, 3000)
	check(dfok, "the attachment came back on request")
	if dfok {
		fo := tc_at(A, dfi)
		check(int(w.oint(fo, "size")) == len(payload), "the fetched size matches")
		got, derr := base64.decode(w.ostr(fo, "data"), allocator = context.temp_allocator)
		check(derr == nil, "the payload decoded")
		same := derr == nil && len(got) == len(payload)
		if same {
			for i in 0 ..< len(payload) {
				if got[i] != payload[i] {
					same = false
					break
				}
			}
		}
		check(same, "every byte round-tripped unchanged")
	}

	amark = inbox_len(A)
	big := make([]u8, w.MAX_ATTACH + 1, context.temp_allocator)
	tc_attach(A, "general", "huge.bin", "application/octet-stream", "", big)
	bgi, bgok := tc_wait(A, "error", amark, 4000)
	check(
		bgok && w.ostr(tc_at(A, bgi), "code") == "too_big",
		"an attachment over the cap is refused by name",
	)

	amark = inbox_len(A)
	tc_fetch(A, root_id)
	nfi, nfok := tc_wait(A, "error", amark, 2000)
	check(
		nfok && w.ostr(tc_at(A, nfi), "code") == "no_file",
		"fetching a message with no attachment is refused",
	)

	// A doubled dot is not a traversal — there is no separator and the stored
	// name always begins with the server's id — so a legal name like
	// `report..final.txt` must be accepted rather than rejected by an
	// over-eager path check.
	amark = inbox_len(A)
	tc_attach(A, "general", "report..final.txt", "text/plain", "", payload)
	ddi, ddok := tc_wait(A, "message", amark, 3000)
	dotted := ""
	if ddok {
		if mo, ok := w.as_obj(tc_at(A, ddi)["msg"] or_else nil); ok {
			if fo, has := w.as_obj(mo["file"] or_else nil); has {
				dotted = strings.clone(w.ostr(fo, "name"), context.temp_allocator)
			}
		}
	}
	check(dotted == "report..final.txt", "a doubled dot in a legal name is kept (got %q)", dotted)

	// `mime` is the one string a client sends that nothing else caps, and it
	// is persisted and re-emitted in every history frame.
	amark = inbox_len(A)
	huge_mime := strings.repeat("x", 4096, context.temp_allocator)
	tc_attach(A, "general", "mime.bin", huge_mime, "", payload)
	mmi, mmok := tc_wait(A, "message", amark, 3000)
	got_mime := ""
	if mmok {
		if mo, ok := w.as_obj(tc_at(A, mmi)["msg"] or_else nil); ok {
			if fo, has := w.as_obj(mo["file"] or_else nil); has {
				got_mime = strings.clone(w.ostr(fo, "mime"), context.temp_allocator)
			}
		}
	}
	check(len(got_mime) <= 127, "an over-long mime type is bounded (got %d bytes)", len(got_mime))

	// -- limits that stop a frame outgrowing MAX_FRAME --------------------
	fmt.println("\nframe limits")
	amark = inbox_len(A)
	{
		e: w.Enc
		w.enc_begin(&e, "thread", context.allocator)
		w.kv_int(&e, "id", root_id)
		w.kv_int(&e, "limit", 2)
		tc_send(A, w.enc_done(&e))
	}
	tli, tlok := tc_wait(A, "thread", amark)
	check(tlok, "a capped thread page came back")
	if tlok {
		to2 := tc_at(A, tli)
		check(len(w.oarr(to2, "msgs")) == 2, "it holds exactly the 2 asked for (got %d)", len(w.oarr(to2, "msgs")))
		check(w.obool(to2, "more"), "and says there are more")
		check(w.oint(to2, "replies") == 5, "while still reporting the real count of 5 (got %d)", w.oint(to2, "replies"))
	}

	// A cursor is forward-only and persisted, so an id past the end of the
	// channel would mark it read for ever, including messages not yet written.
	F, fok2 := tc_dial(port, "frank")
	check(fok2, "frank connected")
	_ = read_row(F, "general", 0)
	fmark := inbox_len(F)
	tc_read(F, "general", 9223372036854775807)
	fecho := read_echo(F, "general", fmark)
	check(fecho.ok, "an absurd cursor is answered rather than ignored")
	check(
		fecho.id > 0 && fecho.id < 9223372036854775807,
		"and clamped to a message that exists (got %d)",
		fecho.id,
	)
	fmark = inbox_len(F)
	tc_post(A, "general", "after frank over-claimed")
	fnew, fnewok := tc_wait(F, "message", fmark)
	_ = fnew
	check(fnewok, "a new message still arrives for frank")
	fmark = inbox_len(F)
	tc_reads(F)
	frow := read_row(F, "general", fmark)
	check(frow.ok && frow.unread == 1, "and it counts as unread, so the clamp held (got %d)", frow.unread)
	tc_close(F)

	// -- malformed input ---------------------------------------------------
	fmt.println("\nbad input")
	bmark = inbox_len(B)
	tc_send(B, "{this is not json")
	jerr, jok := tc_wait(B, "error", bmark)
	check(jok && w.ostr(tc_at(B, jerr), "code") == "bad_json", "a malformed frame is refused by name")
	bmark = inbox_len(B)
	tc_post(B, "general", "still usable")
	_, still := tc_wait(B, "message", bmark)
	check(still, "the connection survives a malformed frame")

	bmark = inbox_len(B)
	tc_simple(B, "hello", "nick", "bob")
	h2, h2ok := tc_wait(B, "error", bmark)
	check(h2ok && w.ostr(tc_at(B, h2), "code") == "already_hello", "a second hello is refused")

	bmark = inbox_len(B)
	tc_post(B, "nowhere", "hello?")
	n1, n1ok := tc_wait(B, "error", bmark)
	check(n1ok && w.ostr(tc_at(B, n1), "code") == "no_channel", "posting to a missing channel is refused")

	// Count what the store should hold, before the restart.
	amark = inbox_len(A)
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
	saw_thread_count, saw_file := false, false
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
		if id == root_id {
			// The counts are derived at replay rather than logged, so this is
			// the assertion that the derivation runs.
			saw_thread_count = w.oint(mo, "replies") == 5
		}
		if fo, has := w.as_obj(mo["file"] or_else nil); has && w.oint(fo, "id") == file_id {
			saw_file = w.ostr(fo, "name") == stored_name && int(w.oint(fo, "size")) == 2048
		}
	}
	check(saw_edit, "the edited text survived the restart")
	check(saw_delete, "the deletion survived the restart")
	check(saw_react, "the reaction survived the restart")
	check(saw_thread_count, "the thread's reply count was rebuilt from the log")
	check(saw_file, "the attachment's metadata survived the restart")

	// The cursor erin left behind is in the log, so her partial read of #quiet
	// is still a partial read.
	E4, e4ok := tc_dial(port, "erin")
	check(e4ok, "erin connected after the restart")
	qafter := read_row(E4, "quiet", 0)
	check(qafter.ok, "her cursors came back after the restart")
	check(qafter.unread == 2, "#quiet is still 2 unread, not 0 and not 4 (got %d)", qafter.unread)

	emark2 := inbox_len(E4)
	tc_thread_get(E4, root_id)
	tai, taok := tc_wait(E4, "thread", emark2)
	check(taok, "the thread survived the restart")
	check(taok && len(w.oarr(tc_at(E4, tai), "msgs")) == 5, "all five replies are still in it")

	emark2 = inbox_len(E4)
	tc_fetch(E4, file_id)
	fai2, faok2 := tc_wait(E4, "file", emark2, 3000)
	check(faok2, "the attachment's bytes survived the restart")
	check(faok2 && int(w.oint(tc_at(E4, fai2), "size")) == 2048, "and they are all there")
	tc_close(E4)

	dmark := inbox_len(D)
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
