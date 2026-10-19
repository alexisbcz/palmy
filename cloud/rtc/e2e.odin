package main

// palm-rtc --e2e: the gateway, end to end, against a running stack.
//
// Three real accounts are signed up through GoTrue with cloudkit, each makes
// its identities through PostgREST, and then real TCP clients speak the wire
// protocol to a gateway running in this process. Nothing is mocked: the
// tokens are GoTrue's, the rows are Postgres's, the attachment is in Storage,
// and every broadcast a client receives came out of pg_notify.
//
//	palm-rtc --e2e --db … --api … --jwt-secret … --sfu-secret-file … [--port N]

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import w "../../apps/chat/wire"
import ck "../../apps/cloudkit"
import "pcp"

E2E :: struct {
	pass, fail: int,
}
ee: E2E

check :: proc(cond: bool, what: string, args: ..any) {
	msg := fmt.tprintf(what, ..args)
	if cond {
		ee.pass += 1
		fmt.printfln("  ok    %s", msg)
	} else {
		ee.fail += 1
		fmt.printfln("  FAIL  %s", msg)
	}
}

section :: proc(name: string) {
	fmt.printfln("\n%s", name)
}

// ---------------------------------------------------------------------------
// A test client: a blocking socket, and frames kept until something asks.
// ---------------------------------------------------------------------------

TC :: struct {
	name:    string,
	sock:    net.TCP_Socket,
	rd:      w.Reader,
	pending: [dynamic]json.Object,
	raw:     [dynamic]string, // every frame received, in order
	up:      bool,
}

tc_dial :: proc(name: string) -> ^TC {
	t := new(TC)
	t.name = name
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = srv.port})
	if err != nil {
		return t
	}
	_ = net.set_option(sock, .Receive_Timeout, 50 * time.Millisecond)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	t.sock = sock
	t.up = true
	return t
}

tc_close :: proc(t: ^TC) {
	if t.up {
		net.close(t.sock)
		t.up = false
	}
}

tc_send :: proc(t: ^TC, e: ^w.Enc) {
	if t.up {
		w.send_frame(t.sock, w.enc_done(e))
	}
}

// tc_pump reads whatever arrives within `ms` into the pending queue.
tc_pump :: proc(t: ^TC, ms: int) {
	deadline := time.tick_now()
	buf: [64 * 1024]u8
	for t.up {
		n, err := net.recv_tcp(t.sock, buf[:])
		if err == nil && n == 0 {
			t.up = false
			break
		}
		if n > 0 {
			w.reader_feed(&t.rd, buf[:n])
			for {
				payload, ok := w.reader_next(&t.rd, context.allocator)
				if !ok {
					break
				}
				append(&t.raw, payload)
				if o, good := w.parse_obj(payload, context.allocator); good {
					append(&t.pending, o)
				}
			}
			// Hand what arrived to the caller now; waiting on for more would
			// add a receive timeout to every latency this file measures.
			if n < len(buf) {
				break
			}
			continue
		}
		if time.duration_milliseconds(time.tick_since(deadline)) >= f64(ms) {
			break
		}
	}
}

// tc_expect waits for the first frame of type `t` (whose `key` equals `val`,
// when given), removing it and everything before it that did not match is
// kept for later.
tc_expect :: proc(t: ^TC, ty: string, key := "", val := "", ms := 4000) -> (json.Object, bool) {
	start := time.tick_now()
	for {
		for o, i in t.pending {
			if w.ostr(o, "t") != ty {
				continue
			}
			if key != "" && field(o, key) != val {
				continue
			}
			ordered_remove(&t.pending, i)
			return o, true
		}
		if time.duration_milliseconds(time.tick_since(start)) > f64(ms) || !t.up {
			for o in t.pending {
				if w.ostr(o, "t") == "error" {
					fmt.printfln("    (%s waiting for %s saw error %s: %s)", t.name, ty, w.ostr(o, "code"), w.ostr(o, "msg"))
				}
			}
			return nil, false
		}
		tc_pump(t, 25)
	}
}

// tc_none says no frame of type `t` arrives within `ms`.
tc_none :: proc(t: ^TC, ty: string, ms := 600) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) && t.up {
		tc_pump(t, 25)
	}
	for o in t.pending {
		if w.ostr(o, "t") == ty {
			return false
		}
	}
	return true
}

// tc_flush drops everything until the line has been quiet for 150 ms.
tc_flush :: proc(t: ^TC) {
	for t.up {
		before := len(t.raw)
		start := time.tick_now()
		for time.duration_milliseconds(time.tick_since(start)) < 150 && len(t.raw) == before {
			tc_pump(t, 25)
		}
		if len(t.raw) == before {
			break
		}
	}
	clear(&t.pending)
}

field :: proc(o: json.Object, key: string) -> string {
	#partial switch v in o[key] {
	case json.String:
		return string(v)
	case json.Integer:
		return fmt.tprintf("%d", v)
	case json.Float:
		return fmt.tprintf("%d", i64(v))
	case json.Boolean:
		return v ? "true" : "false"
	}
	return ""
}

rq_counter: i64

req :: proc(t: string) -> w.Enc {
	e: w.Enc
	w.enc_begin(&e, t, context.allocator)
	rq_counter += 1
	w.kv_int(&e, "rq", rq_counter)
	return e
}

tc_hello :: proc(name, token, identity: string) -> (^TC, json.Object) {
	t := tc_dial(name)
	e := req("hello")
	w.kv_str(&e, "token", token)
	if identity != "" {
		w.kv_str(&e, "identity", identity)
	}
	tc_send(t, &e)
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < 4000 {
		tc_pump(t, 25)
		for o, i in t.pending {
			ty := w.ostr(o, "t")
			if ty == "welcome" || ty == "error" {
				ordered_remove(&t.pending, i)
				return t, o
			}
		}
	}
	return t, nil
}

list_of :: proc(o: json.Object, key := "list") -> json.Array {
	return w.oarr(o, key)
}

find_in :: proc(arr: json.Array, key, val: string) -> (json.Object, bool) {
	for v in arr {
		if o, ok := w.as_obj(v); ok && field(o, key) == val {
			return o, true
		}
	}
	return nil, false
}

msg_of :: proc(o: json.Object) -> json.Object {
	m, _ := w.as_obj(o["msg"])
	return m
}

// ---------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------

Person :: struct {
	cl:    ^ck.Client,
	email: string,
	ids:   [dynamic]ck.Identity,
}

person :: proc(dir, name, run: string) -> (p: Person, err: string) {
	cl, e := ck.open(url = srv.api, anon_key = srv.anon_key, dir = fmt.aprintf("%s/%s", dir, name))
	if !ck.ok(e) {
		return p, e.message
	}
	p.cl = cl
	p.email = fmt.aprintf("%s.%s@palm.test", name, run)
	if se := ck.sign_up(cl, p.email, "correct-horse-battery-9"); !ck.ok(se) {
		return p, fmt.aprintf("sign up %s: %s", p.email, se.message)
	}
	return p, ""
}

add_identity :: proc(p: ^Person, handle, display, kind, color: string) -> string {
	id, e := ck.create_identity(p.cl, handle, display, kind, color)
	if !ck.ok(e) {
		return fmt.aprintf("create identity %s: %s", handle, e.message)
	}
	append(&p.ids, id)
	return ""
}

serve_thread :: proc() {
	serve()
}

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

e2e_run :: proc() -> int {
	if srv.port == DEFAULT_PORT {
		srv.port = 8791
	}
	srv.quiet = true
	thread.create_and_start(serve_thread, self_cleanup = true)
	for i := 0; i < 200 && !srv.ready; i += 1 {
		time.sleep(20 * time.Millisecond)
	}
	time.sleep(150 * time.Millisecond)
	if !srv.ready {
		fmt.eprintln("e2e: the gateway did not start")
		return 1
	}

	now := time.time_to_unix(time.now())
	run := fmt.aprintf("%x", now % 0xffffff)
	dir := fmt.aprintf("%s/palm-rtc-e2e-%s", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", run)
	os.make_directory_all(dir)
	fmt.printfln("palm-rtc end-to-end, run %s, gateway 127.0.0.1:%d, api %s", run, srv.port, srv.api)

	section("accounts and identities (GoTrue + PostgREST, through cloudkit)")
	alice, e1 := person(dir, "alice", run)
	bob, e2 := person(dir, "bob", run)
	carol, e3 := person(dir, "carol", run)
	check(e1 == "" && e2 == "" && e3 == "", "three people sign up %s", strings.concatenate({e1, e2, e3}, context.temp_allocator))
	if e1 != "" || e2 != "" || e3 != "" {
		return report()
	}
	hw, hp := fmt.aprintf("alice.%s", run), fmt.aprintf("alice-home.%s", run)
	bw, bp := fmt.aprintf("bob.%s", run), fmt.aprintf("bob-home.%s", run)
	cw := fmt.aprintf("carol.%s", run)
	errs := strings.concatenate({
		add_identity(&alice, hw, "Alice Martin", "work", "indigo"),
		add_identity(&alice, hp, "Alice", "personal", "rose"),
		add_identity(&bob, bw, "Bob Chen", "work", "emerald"),
		add_identity(&bob, bp, "Bob", "personal", "amber"),
		add_identity(&carol, cw, "Carol Diaz", "work", "sky"),
	}, context.temp_allocator)
	check(errs == "", "five identities are created by their owners %s", errs)
	if errs != "" {
		return report()
	}
	atok, btok, ctok := alice.cl.session.access_token, bob.cl.session.access_token, carol.cl.session.access_token

	section("hello: who you are is the token's, which identity you speak as is yours to say")
	A, wa := tc_hello("A", atok, hw)
	check(wa != nil && w.ostr(wa, "t") == "welcome", "Alice says hello as %s", hw)
	if wa == nil || w.ostr(wa, "t") != "welcome" {
		fmt.printfln("    got %v", wa)
		return report()
	}
	ident, _ := w.as_obj(wa["identity"])
	check(w.ostr(ident, "name") == "Alice Martin" && w.ostr(ident, "color") == "indigo", "welcome carries the identity's name and colour")
	check(w.oint(wa, "proto") == 2, "the gateway speaks protocol 2")
	tc_flush(A)
	_, amb := tc_hello("A?", atok, "")
	check(amb != nil && w.ostr(amb, "code") == "identity_required", "an unscoped token without an identity is asked which one, never defaulted")
	bad := strings.concatenate({atok[:len(atok) - 4], "AAAA"}, context.temp_allocator)
	_, wb := tc_hello("X", bad, hw)
	check(wb != nil && w.ostr(wb, "code") == "auth", "a token with a forged signature is refused")
	_, wbob := tc_hello("X2", btok, hw)
	check(wbob != nil && w.ostr(wbob, "code") == "no_identity", "Bob's token cannot speak as Alice's identity")
	_, wanon := tc_hello("X3", srv.anon_key, "")
	check(wanon != nil && w.ostr(wanon, "code") == "auth", "the anon key is not a person")

	section("a space, its channels, and an invite")
	e := req("create_space")
	w.kv_str(&e, "name", "Northwind")
	tc_send(A, &e)
	sp, ok := tc_expect(A, "space")
	space := ok ? w.ostr(sp, "id") : ""
	check(ok && is_uuid(space), "Alice creates the space Northwind")
	chl, _ := tc_expect(A, "channels")
	gen, has_gen := find_in(list_of(chl), "label", "general")
	general := w.ostr(gen, "name")
	check(has_gen && is_uuid(general), "it comes with #general")
	e = req("create_channel")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "name", "design")
	w.kv_bool(&e, "private", true)
	tc_send(A, &e)
	j, okj := tc_expect(A, "joined")
	design := w.ostr(j, "ch")
	check(okj && is_uuid(design), "and a private #design")

	B, wbw := tc_hello("B", btok, bw)
	check(wbw != nil && w.ostr(wbw, "t") == "welcome", "Bob says hello as %s", bw)
	bch, _ := tc_expect(B, "channels")
	check(len(list_of(bch)) == 0, "Bob sees no channels before he is invited")
	e = req("history")
	w.kv_str(&e, "ch", general)
	tc_send(B, &e)
	he, _ := tc_expect(B, "error")
	check(w.ostr(he, "code") == "no_channel", "and cannot read #general's history by its id")

	tc_flush(B)
	e = req("invite")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "handle", bw)
	tc_send(A, &e)
	_, inv_ok := tc_expect(A, "invited")
	check(inv_ok, "Alice invites %s", bw)
	binv, got_inv := tc_expect(B, "invites")
	invite, has_inv := find_in(list_of(binv), "space", space)
	check(got_inv && has_inv, "Bob is told about the invite as it happens")
	from, _ := w.as_obj(invite["from"])
	check(w.ostr(invite, "space_name") == "Northwind" && w.ostr(from, "name") == "Alice Martin", "the invite names the space and who sent it")
	e = req("accept")
	w.kv_str(&e, "id", w.ostr(invite, "id"))
	tc_send(B, &e)
	_, acc := tc_expect(B, "accepted")
	check(acc, "Bob accepts")
	bch2, _ := tc_expect(B, "channels")
	_, sees_gen := find_in(list_of(bch2), "name", general)
	_, sees_design := find_in(list_of(bch2), "name", design)
	check(sees_gen && !sees_design, "and now sees #general but not the private #design")
	tc_flush(A)
	tc_flush(B)

	section("messages, threads, reactions, edits — every broadcast from pg_notify, in commit order")
	e = req("post")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "text", "the deploy is on **thursday**")
	w.kv_str(&e, "tag", "t-1")
	tc_send(A, &e)
	am, got_am := tc_expect(A, "message")
	bm, got_bm := tc_expect(B, "message")
	root := w.oint(msg_of(am), "id")
	check(got_am && w.ostr(am, "tag") == "t-1", "the author gets its own message back with its tag")
	check(got_bm && w.oint(msg_of(bm), "id") == root, "Bob gets the same message")
	mi, _ := w.as_obj(msg_of(bm)["ident"])
	check(w.ostr(mi, "name") == "Alice Martin" && w.ostr(mi, "color") == "indigo", "carrying who wrote it: name and colour")
	check(w.oint(msg_of(bm), "seq") >= 1 && w.oint(msg_of(bm), "rev") == w.oint(msg_of(bm), "seq"), "a new message's rev is its seq")

	e = req("post")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "text", "10am works?")
	w.kv_int(&e, "thread", root)
	tc_send(B, &e)
	tm, got_tm := tc_expect(A, "message")
	tr, got_tr := tc_expect(A, "replies")
	check(got_tm && w.oint(msg_of(tm), "thread") == root, "a thread reply arrives as a message inside the thread")
	check(got_tr && w.oint(tr, "n") == 1 && w.oint(tr, "id") == root, "followed by the root's new reply count")
	order_ok := false
	for raw, i in A.raw {
		if strings.contains(raw, `"t":"replies"`) {
			for k in 0 ..< i {
				if strings.contains(A.raw[k], `"10am works?"`) {
					order_ok = true
				}
			}
			break
		}
	}
	check(order_ok, "and never before it: the count follows the reply on the wire")
	e = req("thread")
	w.kv_int(&e, "id", root)
	tc_send(A, &e)
	th, got_th := tc_expect(A, "thread")
	check(got_th && w.oint(th, "replies") == 1 && len(w.oarr(th, "msgs")) == 1, "the thread request returns the root and its reply")
	e = req("history")
	w.kv_str(&e, "ch", general)
	tc_send(B, &e)
	hb, _ := tc_expect(B, "history")
	check(len(w.oarr(hb, "msgs")) == 1, "a thread reply is not in the channel timeline")

	e = req("react")
	w.kv_int(&e, "id", root)
	w.kv_str(&e, "key", "heart")
	tc_send(B, &e)
	rx, got_rx := tc_expect(A, "react")
	check(got_rx && w.ostr(rx, "nick") == bw && w.obool(rx, "on"), "Bob's reaction reaches Alice")
	e = req("edit")
	w.kv_int(&e, "id", root)
	w.kv_str(&e, "text", "edited by bob")
	tc_send(B, &e)
	ne, _ := tc_expect(B, "error")
	check(w.ostr(ne, "code") == "not_yours", "Bob cannot edit Alice's message")
	e = req("edit")
	w.kv_int(&e, "id", root)
	w.kv_str(&e, "text", "the deploy is on **friday**")
	tc_send(A, &e)
	ed, got_ed := tc_expect(B, "edit")
	check(got_ed && w.ostr(ed, "text") == "the deploy is on **friday**" && w.oint(ed, "edited") > 0, "Alice's edit reaches Bob")
	e = req("typing")
	w.kv_str(&e, "ch", general)
	w.kv_bool(&e, "on", true)
	tc_send(B, &e)
	ty, got_ty := tc_expect(A, "typing")
	check(got_ty && w.ostr(ty, "name") == "Bob Chen", "typing reaches the channel, with the typist's name")
	check(tc_none(B, "typing", 200), "but is not echoed to the typist")

	section("search: Postgres full text, through RLS")
	e = req("post")
	w.kv_str(&e, "ch", design)
	w.kv_str(&e, "text", "secret mockups for the launch")
	tc_send(A, &e)
	tc_expect(A, "message")
	e = req("search")
	w.kv_str(&e, "q", "deplo")
	tc_send(B, &e)
	rs, _ := tc_expect(B, "results")
	check(len(w.oarr(rs, "msgs")) == 1, "Bob finds the deploy message by a prefix of a word")
	e = req("search")
	w.kv_str(&e, "q", "mockups")
	tc_send(B, &e)
	rs2, _ := tc_expect(B, "results")
	check(len(w.oarr(rs2, "msgs")) == 0, "and does not find what is in #design")
	e = req("search")
	w.kv_str(&e, "q", "mockups")
	tc_send(A, &e)
	rs3, _ := tc_expect(A, "results")
	check(len(w.oarr(rs3, "msgs")) == 1, "which Alice does")

	section("isolation: the same person's other identity is a stranger")
	AP, wap := tc_hello("AP", atok, hp)
	check(wap != nil && w.ostr(wap, "t") == "welcome", "Alice says hello as her personal identity %s", hp)
	apch, _ := tc_expect(AP, "channels")
	check(len(list_of(apch)) == 0, "it sees none of her work space's channels")
	e = req("post")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "text", "from home")
	tc_send(AP, &e)
	ape, _ := tc_expect(AP, "error")
	check(w.ostr(ape, "code") == "no_channel", "cannot post into #general")
	e = req("search")
	w.kv_str(&e, "q", "deploy")
	tc_send(AP, &e)
	aps, _ := tc_expect(AP, "results")
	check(len(w.oarr(aps, "msgs")) == 0, "and search finds nothing of it")
	check(tc_none(AP, "message", 300), "and it received none of the broadcasts")

	// A scoped session (the accounts area's mint_scoped_session) is held to
	// its identity by the token itself.
	homeid: ck.Identity
	for x in alice.ids {
		if x.handle == hp {
			homeid = x
		}
	}
	m, me := ck.scope_to(alice.cl, homeid, "e2e laptop", store = .Delegated)
	check(ck.ok(me), "Alice mints a session scoped to her personal identity %s", me.message)
	if ck.ok(me) {
		data, _ := os.read_entire_file_from_path(m.path, context.temp_allocator)
		sv, _ := ck.parse(string(data), context.temp_allocator)
		stok := ck.get_str(sv, "access_token")
		claims, _ := ck.jwt_claims(stok, context.temp_allocator)
		check(ck.get_str(claims, "palm_identity") == homeid.id, "its token carries palm_identity")
		_, so := tc_hello("S1", stok, hw)
		check(so != nil && (w.ostr(so, "code") == "out_of_scope" || w.ostr(so, "code") == "no_identity"), "the scoped token cannot speak as the work identity")
		S2, so2 := tc_hello("S2", stok, "")
		check(so2 != nil && w.ostr(so2, "nick") == hp, "and without asking, it is its own identity")
		tc_close(S2)
	}

	section("a guest invited to one private channel gets that channel")
	e = req("invite")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "ch", design)
	w.kv_str(&e, "handle", cw)
	tc_send(A, &e)
	tc_expect(A, "invited")
	C, wc := tc_hello("C", ctok, cw)
	check(wc != nil && w.ostr(wc, "t") == "welcome", "Carol says hello")
	cinv, _ := tc_expect(C, "invites")
	ci, hasci := find_in(list_of(cinv), "ch", design)
	check(hasci && w.ostr(ci, "ch_name") == "design" && w.ostr(ci, "role") == "guest", "her invite says: #design, as a guest")
	tc_flush(C)
	e = req("accept")
	w.kv_str(&e, "id", w.ostr(ci, "id"))
	tc_send(C, &e)
	tc_expect(C, "accepted")
	cch, _ := tc_expect(C, "channels")
	check(len(list_of(cch)) == 1 && field(w.as_obj(list_of(cch)[0]) or_else nil, "name") == design, "she sees exactly one channel, #design")
	e = req("history")
	w.kv_str(&e, "ch", design)
	tc_send(C, &e)
	ch1, _ := tc_expect(C, "history")
	check(len(w.oarr(ch1, "msgs")) == 1, "and reads it")
	e = req("history")
	w.kv_str(&e, "ch", general)
	tc_send(C, &e)
	ch2, _ := tc_expect(C, "error")
	check(w.ostr(ch2, "code") == "no_channel", "but not #general")

	section("reconnect: Bob misses four changes and asks for exactly those")
	tc_flush(B)
	tc_flush(A)
	e = req("history")
	w.kv_str(&e, "ch", general)
	tc_send(B, &e)
	hb2, _ := tc_expect(B, "history")
	high: i64 = 0
	for v in w.oarr(hb2, "msgs") {
		mo, _ := w.as_obj(v)
		high = max(high, w.oint(mo, "rev"))
	}
	tc_close(B)
	off, got_off := tc_expect(A, "presence", "nick", bw)
	check(got_off && w.ostr(off, "state") == "offline", "Alice sees Bob go offline")
	ids := [3]i64{}
	for k in 0 ..< 3 {
		e = req("post")
		w.kv_str(&e, "ch", general)
		w.kv_str(&e, "text", fmt.tprintf("while you were out, %d", k + 1))
		tc_send(A, &e)
		mm, _ := tc_expect(A, "message")
		ids[k] = w.oint(msg_of(mm), "id")
	}
	e = req("edit")
	w.kv_int(&e, "id", root)
	w.kv_str(&e, "text", "the deploy is on **monday** now")
	tc_send(A, &e)
	tc_expect(A, "edit")
	e = req("react")
	w.kv_int(&e, "id", ids[0])
	w.kv_str(&e, "key", "rocket")
	tc_send(A, &e)
	tc_expect(A, "react")
	B, wbw = tc_hello("B", btok, bw)
	check(wbw != nil && w.ostr(wbw, "t") == "welcome", "Bob reconnects")
	on, got_on := tc_expect(A, "presence", "nick", bw)
	check(got_on && w.ostr(on, "state") == "online", "and Alice sees him come back")
	e = req("sync")
	// Built by concatenation: a JSON literal is never an fmt format string.
	w.kv_raw(&e, "chs", strings.concatenate({`[{"ch":"`, general, `","rev":`, itoa(high), `}]`}, context.temp_allocator))
	tc_send(B, &e)
	chg, got_chg := tc_expect(B, "changes")
	_, got_synced := tc_expect(B, "synced")
	cm := w.oarr(chg, "msgs")
	check(got_chg && got_synced, "sync answers with changes, then synced")
	check(len(cm) == 4, "exactly four messages changed since rev %d (got %d)", high, len(cm))
	order := make([dynamic]i64, context.temp_allocator)
	revs_up := true
	last_rev: i64 = high
	for v in cm {
		mo, _ := w.as_obj(v)
		append(&order, w.oint(mo, "id"))
		if w.oint(mo, "rev") <= last_rev {
			revs_up = false
		}
		last_rev = w.oint(mo, "rev")
	}
	check(revs_up, "in rev order, each above the one he had")
	check(len(order) == 4 && order[0] == ids[1] && order[1] == ids[2] && order[2] == root && order[3] == ids[0],
		"the two untouched new ones, then the edited root, then the reacted one")
	if len(cm) == 4 {
		r0, _ := w.as_obj(cm[2])
		r3, _ := w.as_obj(cm[3])
		check(w.ostr(r0, "text") == "the deploy is on **monday** now", "the edit arrives as the message's current text")
		check(len(w.oarr(r3, "reacts")) == 1, "the reaction arrives as the message's current reactions")
	}
	check(w.oint(chg, "rev") == last_rev, "the answer's rev is the new high-water mark")

	section("read receipts")
	e = req("read")
	w.kv_str(&e, "ch", general)
	w.kv_int(&e, "id", ids[2])
	tc_send(B, &e)
	rd, got_rd := tc_expect(B, "read")
	check(got_rd && w.oint(rd, "unread") == 0, "Bob reads #general to the end")
	rc, got_rc := tc_expect(A, "receipt")
	check(got_rc && w.ostr(rc, "nick") == bw && w.oint(rc, "id") == ids[2], "Alice gets his read receipt")

	section("attachments: Storage, under the channel's policy")
	content := "parity: 182 cases, 0 geometry mismatches\n"
	e = req("attach")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "name", "parity report.txt")
	w.kv_str(&e, "mime", "text/plain")
	b64, _ := base64.encode(transmute([]u8)content, allocator = context.temp_allocator)
	w.kv_str(&e, "data", b64)
	tc_send(B, &e)
	fm, got_fm := tc_expect(A, "message", ms = 8000)
	file, _ := w.as_obj(msg_of(fm)["file"])
	check(got_fm && w.ostr(file, "name") == "parity_report.txt", "Bob's attachment reaches Alice as a message with a file")
	if !got_fm {
		tc_expect(B, "never", ms = 100)
	}
	fid := w.oint(file, "id")
	e = req("fetch")
	w.kv_int(&e, "id", fid)
	tc_send(A, &e)
	ff, got_ff := tc_expect(A, "file", ms = 8000)
	fdata, _ := base64.decode(w.ostr(ff, "data"), allocator = context.temp_allocator)
	check(got_ff && string(fdata) == content, "Alice fetches it and gets the same bytes")
	e = req("fetch")
	w.kv_int(&e, "id", fid)
	tc_send(C, &e)
	cf, _ := tc_expect(C, "error")
	check(w.ostr(cf, "code") == "no_file", "Carol, not in #general, cannot")
	e = req("attach")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "name", "x.txt")
	w.kv_str(&e, "data", b64)
	tc_send(C, &e)
	ca, _ := tc_expect(C, "error", ms = 8000)
	check(w.ostr(ca, "code") == "forbidden" || w.ostr(ca, "code") == "no_channel", "nor upload into it (%s)", w.ostr(ca, "code"))

	section("calls: admission is decided by Postgres, the token by the gateway")
	S := tc_dial("SFU")
	ts := time.time_to_unix(time.now())
	e = req("sfu_hello")
	w.kv_int(&e, "ts", ts)
	w.kv_str(&e, "mac", "00")
	tc_send(S, &e)
	se, _ := tc_expect(S, "error")
	check(w.ostr(se, "code") == "auth", "an SFU with the wrong secret is refused")
	S = tc_dial("SFU")
	e = req("sfu_hello")
	w.kv_int(&e, "ts", ts)
	w.kv_str(&e, "mac", pcp.sfu_hello_mac(srv.secret, ts))
	tc_send(S, &e)
	_, sw := tc_expect(S, "sfu_welcome")
	check(sw, "the real SFU is welcomed")

	e = req("call_join")
	w.kv_str(&e, "ch", general)
	tc_send(B, &e)
	ct, got_ct := tc_expect(B, "call_token")
	call := w.ostr(ct, "call")
	jn, terr := pcp.token_verify(srv.secret, w.ostr(ct, "token"), allocator = context.temp_allocator)
	check(got_ct && terr == .None, "Bob asks to join a call in #general and gets a token")
	check(jn.call == call && jn.ch == general && jn.handle == bw && jn.name == "Bob Chen" && jn.e2ee, "naming exactly this call, this channel and Bob")
	check(jn.exp - time.time_to_unix(time.now()) <= pcp.TOKEN_TTL, "valid for at most %d s", pcp.TOKEN_TTL)
	ac, got_ac := tc_expect(A, "call")
	check(got_ac && w.ostr(ac, "state") == "active" && w.ostr(ac, "call") == call, "the channel learns a call is live")
	e = req("call_join")
	w.kv_str(&e, "ch", general)
	tc_send(C, &e)
	cc, _ := tc_expect(C, "error")
	check(w.ostr(cc, "code") == "no_channel", "Carol cannot get a token for it")
	_, tamper := pcp.token_verify(srv.secret, strings.concatenate({w.ostr(ct, "token"), "x"}, context.temp_allocator))
	check(tamper != .None, "a tampered token does not verify")

	bob_id := ""
	for x in bob.ids {
		if x.handle == bw {
			bob_id = x.id
		}
	}
	e = req("sfu_room")
	w.kv_str(&e, "call", call)
	w.kv_raw(&e, "ids", fmt.tprintf(`["%s"]`, bob_id))
	tc_send(S, &e)
	rr, got_rr := tc_expect(A, "call")
	who := w.oarr(rr, "who")
	wo: json.Object
	if len(who) > 0 {
		wo, _ = w.as_obj(who[0])
	}
	check(got_rr && len(who) == 1 && w.ostr(wo, "name") == "Bob Chen", "the SFU's roster reaches the channel: Bob is in the call")

	section("revocation: removed members lose the channel, and the call")
	tc_flush(B)
	e = req("dm")
	w.kv_str(&e, "with", bw)
	tc_send(A, &e)
	dj, got_dj := tc_expect(A, "joined")
	dm := w.ostr(dj, "ch")
	check(got_dj && is_uuid(dm), "Alice opens a DM with Bob")
	bdm, _ := tc_expect(B, "channels")
	dmo, has_dm := find_in(list_of(bdm), "name", dm)
	check(has_dm && w.ostr(dmo, "kind") == "dm" && w.ostr(dmo, "label") == "Alice Martin", "Bob sees it, labelled with Alice's name")
	e = req("channels")
	tc_send(AP, &e)
	apc, _ := tc_expect(AP, "channels")
	_, ap_dm := find_in(list_of(apc), "name", dm)
	check(!ap_dm, "Alice's personal identity does not")

	e = req("remove")
	w.kv_str(&e, "space", space)
	w.kv_str(&e, "handle", cw)
	tc_send(A, &e)
	_, rem := tc_expect(A, "removed_member")
	check(rem, "Alice removes Carol from the space")
	gone, got_gone := tc_expect(C, "removed", "ch", design)
	check(got_gone && w.ostr(gone, "ch") == design, "Carol is told #design is gone, as it happens")
	e = req("post")
	w.kv_str(&e, "ch", design)
	w.kv_str(&e, "text", "still here?")
	tc_send(C, &e)
	cpe, _ := tc_expect(C, "error")
	check(w.ostr(cpe, "code") == "no_channel", "and can no longer post there")

	e = req("leave_space")
	w.kv_str(&e, "space", space)
	tc_send(B, &e)
	_, left := tc_expect(B, "left_space")
	check(left, "Bob leaves the space while he is in its call")
	kick, got_kick := tc_expect(S, "sfu_kick")
	check(got_kick && w.ostr(kick, "id") == bob_id && w.ostr(kick, "call") == call, "the gateway tells the SFU to drop him from the call")
	tc_flush(B)
	e = req("post")
	w.kv_str(&e, "ch", general)
	w.kv_str(&e, "text", "after bob left")
	tc_send(A, &e)
	tc_expect(A, "message")
	check(tc_none(B, "message", 500), "and he no longer receives #general")
	e = req("sfu_end")
	w.kv_str(&e, "call", call)
	tc_send(S, &e)
	en, got_en := tc_expect(A, "call")
	check(got_en && w.ostr(en, "state") == "ended", "when the room empties the call ends in the channel")

	section("latency: post on one connection to delivery on another")
	B2, _ := tc_hello("B2", atok, hw) // a second connection of Alice's, as a second device
	tc_flush(B2)
	tc_flush(A)
	samples := make([dynamic]f64, context.temp_allocator)
	for k in 0 ..< 100 {
		e = req("post")
		w.kv_str(&e, "ch", general)
		w.kv_str(&e, "text", fmt.tprintf("latency probe %d", k))
		t0 := time.tick_now()
		tc_send(A, &e)
		if _, got := tc_expect(B2, "message", ms = 2000); got {
			append(&samples, time.duration_milliseconds(time.tick_since(t0)))
		}
		tc_expect(A, "message", ms = 2000)
	}
	slice.sort(samples[:])
	if len(samples) > 0 {
		sum := 0.0
		for s in samples {
			sum += s
		}
		n := len(samples)
		fmt.printfln("  %d posts: mean %.2f ms, p50 %.2f ms, p95 %.2f ms, max %.2f ms (insert, commit, notify, fetch, send)",
			n, sum / f64(n), samples[n / 2], samples[min(n - 1, n * 95 / 100)], samples[n - 1])
	}
	check(len(samples) == 100, "every one of 100 posts was delivered to the second device")

	return report()
}

report :: proc() -> int {
	fmt.printfln("\n%d checks: %d passed, %d failed", ee.pass + ee.fail, ee.pass, ee.fail)
	return ee.fail == 0 ? 0 : 1
}
