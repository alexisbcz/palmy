package main

// `chatbot.bin --e2e` — the whole thing, for real.
//
// It starts a real chat server on a scratch port and directory, starts this
// same binary again in bot mode as a separate process, connects an ordinary
// client of its own, and then talks to the bot and watches the wire.
//
// Three processes, because that is the architecture: the bot is a client, not
// a part of the server, and the only way to prove it is to run it as one.
//
// This one needs ollama. Everything in `--selftest` does not.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import w "../chat/wire"

E2E_PORT :: 8981

// ---------------------------------------------------------------------------
// An ordinary client
// ---------------------------------------------------------------------------

TC :: struct {
	sock:   net.TCP_Socket,
	rd:     w.Reader,
	nick:   string,
	inbox:  [dynamic]json.Object,
	closed: bool,
}

tc_dial :: proc(port: int, nick: string) -> (tc: ^TC, ok: bool) {
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

	e: w.Enc
	w.enc_begin(&e, "hello", context.allocator)
	w.kv_str(&e, "nick", nick)
	tc_send(tc, w.enc_done(&e))
	return tc, true
}

tc_send :: proc(tc: ^TC, payload: string) {
	if tc == nil || tc.closed {
		return
	}
	if !w.send_frame(tc.sock, payload) {
		tc.closed = true
	}
}

tc_close :: proc(tc: ^TC) {
	if tc == nil || tc.closed {
		return
	}
	net.close(tc.sock)
	tc.closed = true
}

tc_pump :: proc(tc: ^TC, ms: int) {
	if tc == nil || tc.closed {
		return
	}
	start := time.tick_now()
	buf: [32 * 1024]u8
	for int(time.duration_milliseconds(time.tick_since(start))) < ms {
		n, err := net.recv_tcp(tc.sock, buf[:])
		if err == .Timeout || err == .Would_Block || err == .Interrupted {
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

tc_post :: proc(tc: ^TC, ch, text: string) {
	e: w.Enc
	w.enc_begin(&e, "post", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "text", text)
	tc_send(tc, w.enc_done(&e))
}

tc_join :: proc(tc: ^TC, ch: string) {
	e: w.Enc
	w.enc_begin(&e, "join", context.allocator)
	w.kv_str(&e, "ch", ch)
	w.kv_str(&e, "kind", "channel")
	tc_send(tc, w.enc_done(&e))
}

// tc_wait_for pumps until `pred` is true of some frame at or after `from`.
tc_wait_for :: proc(
	tc: ^TC,
	from: int,
	ms: int,
	pred: proc(o: json.Object) -> bool,
) -> (
	int,
	bool,
) {
	spent := 0
	for {
		for i in from ..< len(tc.inbox) {
			if pred(tc.inbox[i]) {
				return i, true
			}
		}
		if spent >= ms || tc.closed {
			return -1, false
		}
		tc_pump(tc, 80)
		spent += 80
	}
}

// ---------------------------------------------------------------------------
// The children
// ---------------------------------------------------------------------------

server_binary :: proc(args: Args) -> string {
	if args.server != "" {
		return args.server
	}
	exe := os.args[0]
	slash := strings.last_index_byte(exe, '/')
	dir := slash > 0 ? exe[:slash] : "."
	return strings.concatenate({dir, "/../chat/server/chat-server.bin"})
}

spawn :: proc(cmd: []string) -> (os.Process, bool) {
	p, err := os.process_start({command = cmd})
	if err != nil {
		fmt.eprintfln("  !! cannot start %v: %v", cmd, err)
		return {}, false
	}
	return p, true
}

reap :: proc(p: os.Process) {
	_ = os.process_kill(p)
	_, _ = os.process_wait(p, 2 * time.Second)
}

// ---------------------------------------------------------------------------
// Counting what one reply costs
// ---------------------------------------------------------------------------

Reply_Trace :: struct {
	id:          i64,
	posts:       int, // 1
	edits:       int,
	first_text:  string,
	final_text:  string,
	uniq:        int, // distinct texts seen, placeholder included
}

// trace_reply walks a client's inbox and reconstructs what the workspace saw:
// the `message` the bot posted and every `edit` that followed it. This is the
// honest broadcast count, measured from the receiving end rather than claimed
// by the sender.
trace_reply :: proc(tc: ^TC, from: int, bot_nick: string) -> (t: Reply_Trace, ok: bool) {
	seen := make([dynamic]string, context.temp_allocator)
	for i in from ..< len(tc.inbox) {
		o := tc.inbox[i]
		switch w.ostr(o, "t") {
		case "message":
			mo, good := w.as_obj(o["msg"] or_else nil)
			if !good || w.ostr(mo, "nick") != bot_nick {
				continue
			}
			if t.id != 0 {
				continue // a later reply; this trace is about the first
			}
			t.id = w.oint(mo, "id")
			t.posts += 1
			t.first_text = w.ostr(mo, "text")
			t.final_text = t.first_text
			append(&seen, t.first_text)
		case "edit":
			if t.id == 0 || w.oint(o, "id") != t.id {
				continue
			}
			t.edits += 1
			t.final_text = w.ostr(o, "text")
			append(&seen, t.final_text)
		}
	}
	uniq := 0
	for s, i in seen {
		dup := false
		for j in 0 ..< i {
			if seen[j] == s {
				dup = true
				break
			}
		}
		if !dup {
			uniq += 1
		}
	}
	t.uniq = uniq
	return t, t.id != 0
}

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

run_e2e :: proc(args: Args) -> int {
	srv_bin := server_binary(args)
	if !os.exists(srv_bin) {
		fmt.eprintfln("--e2e: no chat server at %s (build it, or pass --server PATH)", srv_bin)
		return 2
	}
	self := os.args[0]
	port := args.port == w.DEFAULT_PORT ? E2E_PORT : args.port
	dir := fmt.tprintf("/tmp/palmy-chatbot-e2e-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)

	nick := args.nick
	model := args.model

	fmt.printfln("palmy-chatbot end-to-end — server %s, port %d, store %s", srv_bin, port, dir)
	fmt.printfln("bot %q on model %s", nick, model)
	fmt.println()

	st := ollama_probe(model, context.temp_allocator)
	check(st.up, "ollama is up (%s)", st.up ? st.version : st.err)
	if !st.up {
		fmt.eprintfln("--e2e needs ollama. Start it with: %s", OLLAMA_START_HINT)
		return 2
	}
	check(st.has, "the model %s is pulled", model)

	srv, up := spawn({srv_bin, "--port", fmt.tprintf("%d", port), "--dir", dir, "--quiet"})
	if !up {
		return 2
	}
	defer reap(srv)
	check(wait_for_port(port, 4000), "the chat server is listening on 127.0.0.1:%d", port)

	botp, bup := spawn(
		{
			self,
			"--port",
			fmt.tprintf("%d", port),
			"--nick",
			nick,
			"--model",
			model,
			"--channels",
			"general",
		},
	)
	if !bup {
		return 2
	}
	defer reap(botp)

	// Give the bot time to connect, join and seed.
	time.sleep(900 * time.Millisecond)

	sam, dialed := tc_dial(port, "sam")
	check(dialed, "an ordinary second client connects")
	if !dialed {
		return 1
	}
	defer tc_close(sam)
	tc_pump(sam, 400)
	tc_join(sam, "general")
	tc_pump(sam, 200)

	// The bot is a peer: it shows up in the user list like anybody else.
	bot_present := false
	for o in sam.inbox {
		if w.ostr(o, "t") != "users" {
			continue
		}
		for uv in w.oarr(o, "list") {
			if uo, ok := w.as_obj(uv); ok && w.ostr(uo, "nick") == nick {
				bot_present = true
			}
		}
	}
	check(bot_present, "the bot appears in the user list as an ordinary participant")

	// Some ordinary conversation first, so there is context to read.
	tc_post(sam, "general", "morning — I am moving the parity harness to its own binary today")
	tc_pump(sam, 150)
	tc_post(sam, "general", "the shadcn side is measured, the Odin side is not yet")
	tc_pump(sam, 250)

	// ---- a mention, answered with a streamed reply -------------------------
	mark := len(sam.inbox)
	tc_post(sam, "general", fmt.tprintf("@%s in one sentence, what is a pixel parity harness for?", nick))

	_, got := tc_wait_for(sam, mark, 6000, proc(o: json.Object) -> bool {
		if w.ostr(o, "t") != "message" {
			return false
		}
		mo, ok := w.as_obj(o["msg"] or_else nil)
		return ok && w.oint(mo, "id") != 0 && strings.contains(w.ostr(mo, "text"), "*")
	})
	check(got, "a reply from the bot arrives within 6s")

	// Let the generation run to completion. 45s is generous for a 0.6B model
	// answering one sentence; the loop stops early once the footer lands.
	spent := 0
	for spent < 45_000 {
		tc_pump(sam, 300)
		spent += 300
		t, ok := trace_reply(sam, mark, nick)
		if ok && strings.contains(t.final_text, FOOTER_MARK) {
			break
		}
	}

	tr, traced := trace_reply(sam, mark, nick)
	check(traced, "the second client saw the bot's message")
	check(tr.posts == 1, "the reply is one posted message (%d)", tr.posts)
	check(tr.edits > 1, "it was updated more than once: %d edits", tr.edits)
	check(
		strings.contains(tr.first_text, model),
		"the first thing posted names the model",
	)
	check(
		strings.contains(tr.final_text, FOOTER_MARK) && strings.contains(tr.final_text, model),
		"the final text carries the model attribution",
	)
	body := strings.trim_space(strip_footer(tr.final_text))
	check(len(body) > 40, "the final text is a real answer: %d bytes of body", len(body))
	check(
		tr.final_text != tr.first_text,
		"the reply converged to something other than the placeholder",
	)
	check(len(tr.final_text) <= MAX_POST, "the final text is inside the server's limit")
	check(
		!strings.contains(tr.final_text, "*… "),
		"the writing marker is gone once it is finished",
	)

	total := tr.posts + tr.edits
	fmt.println()
	fmt.printfln(
		"  >>> BROADCASTS FOR ONE REPLY: %d  (1 post + %d edits, %d distinct texts)",
		total,
		tr.edits,
		tr.uniq,
	)
	fmt.printfln("  >>> final reply: %d bytes, body %d bytes", len(tr.final_text), len(body))
	fmt.println()
	check(total < 60, "one reply cost fewer than 60 broadcasts (%d)", total)

	// ---- a long reply, so the broadcast count means something -------------
	// The first measurement was one sentence. This one asks for as much as the
	// token cap allows, which is the worst case the coalescing policy has to
	// hold: it is where an edit-per-token would be a hundred broadcasts.
	time.sleep(1400 * time.Millisecond)
	markL := len(sam.inbox)
	tc_post(
		sam,
		"general",
		fmt.tprintf(
			"@%s describe in several paragraphs how a software rasterizer turns triangles into pixels, and why anyone would write one by hand",
			nick,
		),
	)
	spentL := 0
	for spentL < 90_000 {
		tc_pump(sam, 300)
		spentL += 300
		t, ok := trace_reply(sam, markL, nick)
		if ok && strings.contains(t.final_text, FOOTER_MARK) {
			break
		}
	}
	trL, tracedL := trace_reply(sam, markL, nick)
	check(tracedL, "the long question is answered too")
	bodyL := strings.trim_space(strip_footer(trL.final_text))
	totalL := trL.posts + trL.edits
	fmt.println()
	fmt.printfln(
		"  >>> BROADCASTS FOR A LONG REPLY: %d  (1 post + %d edits) for %d bytes of answer",
		totalL,
		trL.edits,
		len(bodyL),
	)
	fmt.printfln(
		"  >>> an edit per token would have been roughly %d broadcasts",
		len(bodyL) / 4,
	)
	fmt.println()
	check(len(bodyL) > 300, "the long answer really is long: %d bytes", len(bodyL))
	check(trL.edits >= 3, "and it streamed in %d updates", trL.edits)
	check(
		totalL * 6 < len(bodyL) / 4,
		"the policy cost under a sixth of an edit-per-token: %d vs about %d",
		totalL,
		len(bodyL) / 4,
	)
	check(len(trL.final_text) <= MAX_POST, "and the long answer still fits one message")

	// ---- stop a generation in flight --------------------------------------
	time.sleep(1400 * time.Millisecond) // clear the rate limiter's minimum gap
	mark2 := len(sam.inbox)
	tc_post(
		sam,
		"general",
		fmt.tprintf("@%s write a long description of what a software rasterizer does", nick),
	)
	_, got2 := tc_wait_for(sam, mark2, 6000, proc(o: json.Object) -> bool {
		if w.ostr(o, "t") != "message" {
			return false
		}
		mo, ok := w.as_obj(o["msg"] or_else nil)
		return ok && strings.contains(w.ostr(mo, "text"), "*")
	})
	check(got2, "the second question is picked up")

	time.sleep(900 * time.Millisecond)
	tc_post(sam, "general", fmt.tprintf("@%s stop", nick))
	stop_at := time.tick_now()

	stopped := false
	for int(time.duration_milliseconds(time.tick_since(stop_at))) < 4000 {
		tc_pump(sam, 100)
		t, ok := trace_reply(sam, mark2, nick)
		if ok && strings.contains(t.final_text, "stopped") {
			stopped = true
			break
		}
	}
	lat := int(time.duration_milliseconds(time.tick_since(stop_at)))
	check(stopped, "`stop` ended the generation in flight (%dms from the ask)", lat)

	// ---- the guard, live --------------------------------------------------
	// The bot's own messages are all over this channel now. If the self-reply
	// guard were wrong, the reply count would be climbing on its own.
	quiet_mark := len(sam.inbox)
	time.sleep(2500 * time.Millisecond)
	tc_pump(sam, 400)
	extra := 0
	for i in quiet_mark ..< len(sam.inbox) {
		o := sam.inbox[i]
		if w.ostr(o, "t") != "message" {
			continue
		}
		if mo, ok := w.as_obj(o["msg"] or_else nil); ok && w.ostr(mo, "nick") == nick {
			extra += 1
		}
	}
	check(extra == 0, "the bot said nothing unprompted for 2.5s (%d messages)", extra)

	fmt.println()
	fmt.printfln("%d assertions, %d failed", ck.pass + ck.fail, ck.fail)
	return ck.fail == 0 ? 0 : 1
}
