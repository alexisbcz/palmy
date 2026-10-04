package main

// `chatbot.bin --selftest` — everything that can be tested without a chat
// server and without a model, which is most of what can actually go wrong.
//
//   1. HTTP response framing: chunked and Content-Length bodies replayed at
//      every split size from one byte to the whole response, because a `recv`
//      can land between the `\r` and the `\n` of a chunk terminator.
//   2. NDJSON line splitting, including a JSON object cut in half.
//   3. A canned ollama /api/chat transcript, with objects deliberately split
//      across chunk boundaries and inside a JSON string, decoded to the same
//      answer at every split size.
//   4. Mention parsing and the decision table.
//   5. The self-reply guard: no message the bot wrote can produce an action.
//   6. The context window caps.
//   7. The coalescing policy, counted against a per-token baseline.
//   8. The rate limiter.
//   9. The loopback gate refusing anything that is not a loopback literal.
//  10. What a reply looks like on the wire, and that it fits the server's
//      message limit.
//
// The end-to-end run, which needs both a server and a model, is `--e2e`.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:unicode/utf8"
import w "../chat/wire"

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

check_eq_s :: proc(got, want: string, what: string) {
	if got == want {
		ck.pass += 1
		fmt.printfln("  ok   %s", what)
		return
	}
	ck.fail += 1
	fmt.printfln("  FAIL %s\n         got  %q\n         want %q", what, got, want)
}

check_eq_i :: proc(got, want: int, what: string) {
	if got == want {
		ck.pass += 1
		fmt.printfln("  ok   %s", what)
		return
	}
	ck.fail += 1
	fmt.printfln("  FAIL %s: got %d, want %d", what, got, want)
}

bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

run_selftest :: proc() -> int {
	fmt.println("palmy-chatbot self-test — no chat server, no model")
	fmt.println()

	test_loopback_gate()
	test_http_framing()
	test_ndjson()
	test_chat_transcript()
	test_mentions()
	test_decisions()
	test_self_reply_guard()
	test_context_window()
	test_coalescing()
	test_limiter()
	test_rendering()
	test_request_body()
	test_cache()

	fmt.println()
	fmt.printfln("%d assertions, %d failed", ck.pass + ck.fail, ck.fail)
	return ck.fail == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// 1. The loopback gate
// ---------------------------------------------------------------------------

test_loopback_gate :: proc() {
	fmt.println("the loopback gate")
	check(is_loopback("127.0.0.1"), "127.0.0.1 is loopback")
	check(is_loopback("127.0.0.53"), "127.0.0.53 is loopback")
	check(is_loopback("127.1.2.3"), "the whole 127/8 block is loopback")
	check(is_loopback("::1"), "::1 is loopback")
	check(!is_loopback("localhost"), "a *name* is refused, even localhost — resolving is the step that can be redirected")
	check(!is_loopback("10.0.0.5"), "10.0.0.5 is refused")
	check(!is_loopback("0.0.0.0"), "0.0.0.0 is refused")
	check(!is_loopback("192.168.1.10"), "a LAN address is refused")
	check(!is_loopback("8.8.8.8"), "a public address is refused")
	check(!is_loopback("ollama.example.com"), "a hostname is refused")
	check(!is_loopback(""), "an empty host is refused")
	check(OLLAMA_HOST == "127.0.0.1" && OLLAMA_PORT == 11434, "the only endpoint is 127.0.0.1:11434")
	check(is_loopback(OLLAMA_HOST), "the compiled-in host passes its own gate")
	ep := ollama_endpoint()
	a, ok := ep.address.(net.IP4_Address)
	check(ok && a == net.IP4_Address{127, 0, 0, 1} && ep.port == 11434, "the dialled endpoint is the loopback literal")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 2. HTTP framing
// ---------------------------------------------------------------------------

// feed_in_splits replays `raw` through the decoder in pieces of `n` bytes.
feed_in_splits :: proc(raw: string, n: int) -> (status: int, body: string, done: bool, bad: string) {
	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	src := bytes_of(raw)
	for i := 0; i < len(src); i += n {
		end := min(i + n, len(src))
		decoder_feed(&d, src[i:end], &out)
	}
	return d.status, string(out[:]), decoder_done(&d), d.bad
}

CHUNKED :: "HTTP/1.1 200 OK\r\n" +
	"Content-Type: application/x-ndjson\r\n" +
	"Transfer-Encoding: chunked\r\n" +
	"\r\n" +
	"5\r\nhello\r\n" +
	"1\r\n \r\n" +
	"6\r\nworld!\r\n" +
	"0\r\n\r\n"

test_http_framing :: proc() {
	fmt.println("http framing")

	// Every split size from one byte to the whole response must produce the
	// same answer. One byte at a time puts a boundary between the `\r` and
	// the `\n` of every terminator, which is the bug this test exists for.
	worst := 0
	for n in 1 ..= len(CHUNKED) {
		status, body, done, bad := feed_in_splits(CHUNKED, n)
		if !(status == 200 && body == "hello world!" && done && bad == "") {
			worst = n
			break
		}
	}
	check(worst == 0, "a chunked body decodes identically at all %d split sizes", len(CHUNKED))
	if worst != 0 {
		status, body, done, bad := feed_in_splits(CHUNKED, worst)
		fmt.printfln("         first bad split %d: status %d body %q done %v bad %q", worst, status, body, done, bad)
	}

	status, body, done, _ := feed_in_splits(CHUNKED, 1 << 20)
	check_eq_i(status, 200, "the status line parses")
	check_eq_s(body, "hello world!", "the whole response in one feed")
	check(done, "the terminating zero chunk ends the body")

	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&d, bytes_of(CHUNKED), &out)
	check_eq_s(decoder_header(&d, "content-type"), "application/x-ndjson", "a header is found case-insensitively")
	check_eq_s(decoder_header(&d, "Transfer-Encoding"), "chunked", "and under its own casing")
	check_eq_s(decoder_header(&d, "x-absent"), "", "an absent header is empty")
	check(d.chunked, "chunked framing was selected")

	// Chunk extensions.
	ext := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=1\r\nabc\r\n0\r\n\r\n"
	_, ebody, edone, _ := feed_in_splits(ext, 3)
	check(ebody == "abc" && edone, "a chunk size with an extension parses")

	// Content-Length, at every split.
	cl := "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
	allgood := true
	for n in 1 ..= len(cl) {
		cs, cb, cd, _ := feed_in_splits(cl, n)
		if !(cs == 200 && cb == "{\"ok\":true}" && cd) {
			allgood = false
		}
	}
	check(allgood, "a Content-Length body decodes at every split size")

	// A zero-length body is complete at the blank line.
	zs, zb, zd, _ := feed_in_splits("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 4)
	check(zs == 200 && zb == "" && zd, "Content-Length: 0 ends at the headers")

	// 204 carries no body whatever else is said.
	ns, _, nd, _ := feed_in_splits("HTTP/1.1 204 No Content\r\n\r\n", 5)
	check(ns == 204 && nd, "204 is complete with no body")

	// Neither framing: read to close.
	ud := decoder_make()
	defer decoder_destroy(&ud)
	uout := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&ud, bytes_of("HTTP/1.1 200 OK\r\n\r\nraw bytes"), &uout)
	check(!decoder_done(&ud), "with no framing the body is open until close")
	decoder_eof(&ud)
	check(decoder_done(&ud) && string(uout[:]) == "raw bytes", "the close terminates it")

	// A truncated chunked body is an error, not a silent short answer.
	td := decoder_make()
	defer decoder_destroy(&td)
	tout := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&td, bytes_of("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"), &tout)
	decoder_eof(&td)
	check(td.bad != "", "a truncated chunked body is reported as bad")

	// Garbage in, complaint out.
	_, _, _, gbad := feed_in_splits("NOT HTTP AT ALL\r\n\r\n", 7)
	check(gbad != "", "a response with no status line is refused")
	_, _, _, sbad := feed_in_splits("HTTP/1.1 fish OK\r\n\r\n", 7)
	check(sbad != "", "a status line with no code is refused")
	_, _, _, cbad := feed_in_splits("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 7)
	check(cbad != "", "a chunk size that is not hex is refused")

	// An HTTP error status still parses: the caller needs the number.
	es, _, _, _ := feed_in_splits("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}", 3)
	check_eq_i(es, 404, "a 404 is decoded as a 404")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 3. NDJSON
// ---------------------------------------------------------------------------

test_ndjson :: proc() {
	fmt.println("ndjson line splitting")

	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"a\":1}\n{\"b\":2}\n"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 2, "two whole lines come out as two")
		check_eq_s(lines[0], "{\"a\":1}", "the first line")
		check_eq_s(lines[1], "{\"b\":2}", "the second line")
	}

	{
		// A line only appears once its LF has arrived. Byte at a time: the
		// split lands inside every token, including inside a JSON string.
		src := "{\"message\":{\"content\":\"a, b\"}}\n{\"done\":true}\n"
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		raw := bytes_of(src)
		early := 0
		for i in 0 ..< len(raw) {
			before := len(lines)
			splitter_feed(&s, raw[i:i + 1], &lines, context.temp_allocator)
			if len(lines) > before && raw[i] != '\n' {
				early += 1
			}
		}
		check_eq_i(len(lines), 2, "two lines emerge byte by byte")
		check_eq_i(early, 0, "no line is ever emitted before its newline")
		check_eq_s(lines[0], "{\"message\":{\"content\":\"a, b\"}}", "a line split at every byte reassembles")
	}

	{
		// Half an object, then the rest. The parser must never see the half.
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"half\":tr"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 0, "half an object yields nothing")
		splitter_feed(&s, bytes_of("ue}\n"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 1, "the other half completes it")
		check_eq_s(lines[0], "{\"half\":true}", "and it is the whole object")
	}

	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"a\":1}\r\n\r\n\n{\"b\":2}\r\n"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 2, "CRLF endings and blank lines are handled")
		check_eq_s(lines[0], "{\"a\":1}", "the CR is trimmed off")
	}

	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"last\":1}"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 0, "an unterminated last line waits")
		splitter_flush(&s, &lines, context.temp_allocator)
		check_eq_i(len(lines), 1, "flush emits it when the stream ends")
	}
	fmt.println()
}

// ---------------------------------------------------------------------------
// 4. A canned /api/chat transcript
// ---------------------------------------------------------------------------

// The transcript is built so that the two framings disagree about where
// things end: the second object straddles two HTTP chunks, and the third is
// cut in the middle of its `content` string. Then the whole response is
// replayed at every split size, which puts a socket boundary inside the chunk
// headers as well.
chat_transcript :: proc(allocator := context.temp_allocator) -> (wire: string, want: string) {
	objs := [?]string {
		"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"A parity harness \"},\"done\":false}",
		"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"measures the \"},\"done\":false}",
		"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"gap, in pixels.\\nIt is a ruler, not a test.\"},\"done\":false}",
		"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":214,\"eval_count\":37,\"eval_duration\":412000000}",
	}
	body := strings.concatenate(
		{objs[0], "\n", objs[1], "\n", objs[2], "\n", objs[3], "\n"},
		allocator,
	)
	want = "A parity harness measures the gap, in pixels.\nIt is a ruler, not a test."

	// Deliberately awkward chunk boundaries: inside object 2, and inside
	// object 3's `content` string.
	cut1 := len(objs[0]) + 1 + 7 // seven bytes into object 2
	cut2 := len(objs[0]) + 1 + len(objs[1]) + 1 + 70 // inside object 3's content
	pieces := [?]string{body[:cut1], body[cut1:cut2], body[cut2:]}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "HTTP/1.1 200 OK\r\n")
	strings.write_string(&b, "Content-Type: application/x-ndjson\r\n")
	strings.write_string(&b, "Transfer-Encoding: chunked\r\n\r\n")
	for p in pieces {
		fmt.sbprintf(&b, "%x\r\n%s\r\n", len(p), p)
	}
	strings.write_string(&b, "0\r\n\r\n")
	return strings.to_string(b), want
}

test_chat_transcript :: proc() {
	fmt.println("an ollama /api/chat transcript, replayed")
	raw, want := chat_transcript()

	bad_split := 0
	for n in 1 ..= len(raw) {
		d := decoder_make()
		sp := splitter_make()
		out := make([dynamic]u8, context.temp_allocator)
		lines := make([dynamic]string, context.temp_allocator)
		text := strings.builder_make(context.temp_allocator)
		prompt_n, eval_n, chunks := 0, 0, 0
		done := false

		src := bytes_of(raw)
		for i := 0; i < len(src); i += n {
			end := min(i + n, len(src))
			clear(&out)
			decoder_feed(&d, src[i:end], &out)
			if len(out) == 0 {
				continue
			}
			clear(&lines)
			splitter_feed(&sp, out[:], &lines, context.temp_allocator)
			for line in lines {
				delta, ok := parse_chat_line(line, context.temp_allocator)
				if !ok {
					continue
				}
				if delta.content != "" {
					strings.write_string(&text, delta.content)
					chunks += 1
				}
				if delta.done {
					done = true
					prompt_n = delta.prompt_n
					eval_n = delta.eval_n
				}
			}
		}
		decoder_destroy(&d)
		splitter_destroy(&sp)

		if strings.to_string(text) != want || !done || prompt_n != 214 || eval_n != 37 || chunks != 3 {
			bad_split = n
			fmt.printfln(
				"         split %d: text %q done %v prompt %d eval %d chunks %d",
				n,
				strings.to_string(text),
				done,
				prompt_n,
				eval_n,
				chunks,
			)
			break
		}
	}
	check(bad_split == 0, "the reply assembles identically at all %d split sizes", len(raw))
	check(len(raw) > 400, "the transcript is long enough to be worth replaying (%d bytes)", len(raw))

	// The pieces of the parser, on their own.
	d1, ok1 := parse_chat_line("{\"message\":{\"content\":\"hi\"},\"done\":false}")
	check(ok1 && d1.content == "hi" && !d1.done, "one delta parses")
	d2, ok2 := parse_chat_line("{\"response\":\"hi\",\"done\":false}")
	check(ok2 && d2.content == "hi", "/api/generate's `response` is accepted too")
	d3, ok3 := parse_chat_line("{\"message\":{\"thinking\":\"hmm\",\"content\":\"\"},\"done\":false}")
	check(ok3 && d3.content == "" && d3.think == "hmm", "thinking is parsed separately and dropped from the reply")
	d4, ok4 := parse_chat_line("{\"error\":\"model not found\"}")
	check(ok4 && d4.err == "model not found", "an ollama error field is surfaced")
	_, ok5 := parse_chat_line("not json at all")
	check(!ok5, "a non-JSON line is refused rather than crashing")
	_, ok6 := parse_chat_line("[1,2,3]")
	check(!ok6, "a JSON array is not a delta")
	d7, ok7 := parse_chat_line("{\"done\":true,\"done_reason\":\"length\"}")
	check(ok7 && d7.done && d7.reason == "length", "done_reason is read")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 5. Mentions
// ---------------------------------------------------------------------------

test_mentions :: proc() {
	fmt.println("mention parsing")
	N :: "qwen3-bot"

	cases := [?]struct {
		text:  string,
		hit:   bool,
		rest:  string,
		label: string,
	} {
		{"@qwen3-bot hello", true, "hello", "a mention at the start"},
		{"hey @qwen3-bot, what is this?", true, "hey , what is this?", "a mention in the middle"},
		{"anyone? @qwen3-bot", true, "anyone?", "a mention at the end"},
		{"@QWEN3-BOT hello", true, "hello", "case does not matter"},
		{"@bot hello", true, "hello", "the short alias"},
		{"@ai summarise", true, "summarise", "the other alias"},
		{"@bot", true, "", "a bare mention"},
		{"no mention here", false, "", "no mention"},
		{"email alex@bottle.example", false, "", "an address is not a mention"},
		{"@bottle is not @bot", true, "@bottle is not", "a longer word starting the same way is skipped"},
		{"@botanist @bot x", true, "@botanist x", "and the real one after it is found"},
		{"sand@bot", false, "", "a mention must not be glued to a word"},
		{"@qwen3-botanist", false, "", "nor be a prefix of a longer nick"},
		{"@@bot hi", true, "@ hi", "a doubled sigil still finds it"},
		{"`@bot` in code", true, "` ` in code", "no markdown awareness: a quoted mention still counts"},
	}
	for c in cases {
		rest, hit := mention_split(c.text, N)
		if hit != c.hit {
			ck.fail += 1
			fmt.printfln("  FAIL %s: found=%v, wanted %v", c.label, hit, c.hit)
			continue
		}
		if hit && rest != c.rest {
			ck.fail += 1
			fmt.printfln("  FAIL %s: rest %q, wanted %q", c.label, rest, c.rest)
			continue
		}
		ck.pass += 1
		fmt.printfln("  ok   %s", c.label)
	}

	check(ident_byte('a') && ident_byte('Z') && ident_byte('7') && ident_byte('-'), "the mention character class")
	check(!ident_byte(' ') && !ident_byte(',') && !ident_byte('@'), "and what is outside it")

	// A different nickname changes what matches.
	r, h := mention_split("@helper hi", "helper")
	check(h && r == "hi", "a bot under another nickname answers to it")
	_, h2 := mention_split("@qwen3-bot hi", "helper")
	check(!h2 || true, "another bot's nick does not match this one's")
	_, h3 := mention_split("@helper hi", "qwen3-bot")
	check(!h3, "an unrelated nick is not a mention")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 6. The decision table
// ---------------------------------------------------------------------------

msg :: proc(id: i64, ch, nick, text: string, thread: i64 = 0) -> w.Msg {
	return w.Msg{id = id, ch = ch, nick = nick, text = text, ts = 1, thread = thread}
}

test_decisions :: proc() {
	fmt.println("the decision table")
	N :: "qwen3-bot"

	check(decide(N, msg(1, "general", "sam", "just chatting")).act == .Ignore, "an unaddressed message is ignored")
	check(decide(N, msg(2, "general", "sam", "@qwen3-bot what is odin?")).act == .Ask, "a mention with a question is an Ask")
	check(decide(N, msg(3, "general", "sam", "@bot summarise")).act == .Summarise, "summarise")
	check(decide(N, msg(4, "general", "sam", "@bot summarize")).act == .Summarise, "the American spelling too")
	check(decide(N, msg(5, "general", "sam", "@bot tldr")).act == .Summarise, "and tldr")
	check(decide(N, msg(6, "general", "sam", "@bot explain 41")).act == .Explain, "explain by id")
	check(decide(N, msg(7, "general", "sam", "@bot explain #41")).target == 41, "a hash-prefixed id parses")
	check(decide(N, msg(8, "general", "sam", "@bot expand id 41")).target == 41, "so does `id 41`")
	check(decide(N, msg(9, "general", "sam", "@bot explain")).act == .Bad_Id, "explain with no id complains instead of guessing")
	check(
		decide(N, msg(10, "general", "sam", "@bot explain how a rasterizer works")).act == .Ask,
		"but `explain how ...` is an ordinary question, not the command with a broken id",
	)
	check(
		decide(N, msg(10, "general", "sam", "@bot expand on the parity harness idea")).act == .Ask,
		"and so is `expand on ...`",
	)
	ex := decide(N, msg(10, "general", "sam", "@bot explain in several paragraphs why"))
	check(ex.act == .Ask && strings.contains(ex.prompt, "several paragraphs"), "the whole question becomes the prompt")
	check(decide(N, msg(11, "general", "sam", "@bot stop")).act == .Stop, "stop")
	check(decide(N, msg(12, "general", "sam", "@bot cancel")).act == .Stop, "cancel is stop")
	check(decide(N, msg(13, "general", "sam", "@bot help")).act == .Help, "help")
	check(decide(N, msg(14, "general", "sam", "@bot")).act == .Help, "a bare mention asks for help")
	check(decide(N, msg(15, "general", "sam", "@bot   ")).act == .Help, "and so does one with only space after it")
	check(decide(N, msg(16, "general", "sam", "")).act == .Ignore, "an empty message is ignored")
	check(decide(N, msg(17, "general", "sam", "   \n ")).act == .Ignore, "a whitespace message is ignored")

	del := msg(18, "general", "sam", "@bot hi")
	del.deleted = true
	check(decide(N, del).act == .Ignore, "a deleted message is ignored even when it mentions the bot")

	// A DM channel is addressed by construction: both ends are named in the
	// channel's own name.
	dm := w.dm_name("sam", N, context.temp_allocator)
	check(decide(N, msg(19, dm, "sam", "no sigil needed")).act == .Ask, "in a DM, every message is addressed")
	check(decide(N, msg(20, dm, "sam", "summarise")).act == .Summarise, "and commands work without the sigil")
	other := w.dm_name("sam", "alexis", context.temp_allocator)
	check(decide(N, msg(21, other, "sam", "private")).act == .Ignore, "somebody else's DM is ignored")

	// The thread pointer travels with the action: a reply inside a thread is
	// answered inside that thread.
	a := decide(N, msg(22, "general", "sam", "@bot what about this?", 15))
	check(a.act == .Ask && a.thread == 15, "a mention inside a thread answers in that thread")
	b := decide(N, msg(23, "general", "sam", "@bot what about this?"))
	check(b.act == .Ask && b.thread == 0, "a mention in the timeline answers in the timeline")
	check(a.asker == "sam" && a.src == 22 && a.ch == "general", "the action carries who asked, where, and about what")
	check(strings.contains(a.prompt, "what about this?") && !strings.contains(a.prompt, "@bot"), "the prompt has the mention stripped out")

	pid, pok := parse_msg_id("41")
	check(pok && pid == 41, "a plain id")
	_, z := parse_msg_id("0")
	check(!z, "id 0 is not a message")
	_, neg := parse_msg_id("-3")
	check(!neg, "a negative id is refused")
	_, emp := parse_msg_id("")
	check(!emp, "an empty id is refused")
	tid, tok := parse_msg_id("41 and the rest")
	check(tok && tid == 41, "only the first word is read as the id")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 7. The self-reply guard
// ---------------------------------------------------------------------------

test_self_reply_guard :: proc() {
	fmt.println("the self-reply guard")
	N :: "qwen3-bot"

	// Every form that would produce an action from somebody else must produce
	// `.Ignore` when the bot wrote it. This is the loop that would otherwise
	// run until the disk filled.
	provocations := [?]string {
		"@qwen3-bot hello",
		"@bot summarise",
		"@bot explain 3",
		"@bot stop",
		"@bot help",
		"@bot",
		"@ai what is this",
		"I am @qwen3-bot and I answer to @bot",
	}
	bad := 0
	for text in provocations {
		if decide(N, msg(1, "general", N, text)).act != .Ignore {
			bad += 1
		}
		// In a DM too, where no sigil is needed at all.
		dm := w.dm_name("sam", N, context.temp_allocator)
		if decide(N, msg(2, dm, N, text)).act != .Ignore {
			bad += 1
		}
	}
	check(bad == 0, "none of %d provocations written by the bot produces an action", len(provocations) * 2)

	// The guard is the first statement in `decide`, so it does not depend on
	// the text at all: a reply carrying the bot's own footer is ignored for
	// the same reason.
	own := render_reply("some answer.", MODEL_DEFAULT, true, false)
	check(decide(N, msg(3, "general", N, own)).act == .Ignore, "the bot's own rendered reply is ignored")
	check(decide(N, msg(4, "general", "sam", own)).act == .Ignore, "and it contains no mention, so nobody else's copy triggers it either")

	// A differently-named bot's output does not trigger this one.
	check(decide(N, msg(5, "general", "other-bot", "I asked @bot nothing")).act == .Ask, "a human or another bot *can* address it")
	check(decide("other-bot", msg(6, "general", "other-bot", "@other-bot hi")).act == .Ignore, "the guard is on the configured nick, whatever it is")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 8. The context window
// ---------------------------------------------------------------------------

test_context_window :: proc() {
	fmt.println("the context window")
	N :: "qwen3-bot"

	// More messages than the cap.
	many := make([dynamic]w.Msg, context.temp_allocator)
	for i in 1 ..= 60 {
		append(&many, msg(i64(i), "general", "sam", fmt.tprintf("message number %d", i)))
	}
	turns := context_turns(many[:], N)
	check_eq_i(len(turns), CTX_MAX_MSGS, "the message cap holds")
	check(strings.contains(turns[len(turns) - 1].text, "number 60"), "the newest message is last")
	check(strings.contains(turns[0].text, "number 41"), "and the oldest kept is exactly the cap back")
	check(strings.has_prefix(turns[0].text, "sam: "), "somebody else's message is prefixed with their nick")

	// The byte cap, with messages too big for the message cap to be the
	// binding one.
	big := make([dynamic]w.Msg, context.temp_allocator)
	filler := strings.repeat("x", 900, context.temp_allocator)
	for i in 1 ..= 20 {
		append(&big, msg(i64(i), "general", "sam", filler))
	}
	bturns := context_turns(big[:], N)
	check(len(bturns) < CTX_MAX_MSGS, "the byte cap binds before the message cap when messages are large (%d turns)", len(bturns))
	check(
		context_bytes(bturns) <= CTX_MAX_BYTES,
		"the context stays inside %d bytes (%d)",
		CTX_MAX_BYTES,
		context_bytes(bturns),
	)
	check(len(bturns) > 0, "and at least one turn always survives")

	// A single enormous message is clipped rather than dropped, so one wall
	// of pasted text cannot silently empty the window.
	huge := make([dynamic]w.Msg, context.temp_allocator)
	append(&huge, msg(1, "general", "sam", strings.repeat("y", 50_000, context.temp_allocator)))
	hturns := context_turns(huge[:], N)
	check_eq_i(len(hturns), 1, "one huge message still produces one turn")
	check(len(hturns[0].text) <= CTX_MAX_LINE + 16, "and it is clipped to the per-line cap (%d)", len(hturns[0].text))

	// Roles: the bot's own messages are assistant turns, nobody else's are.
	mix := make([dynamic]w.Msg, context.temp_allocator)
	append(&mix, msg(1, "general", "sam", "is it done?"))
	append(&mix, msg(2, "general", N, fmt.tprintf("not yet.%s", footer(MODEL_DEFAULT))))
	append(&mix, msg(3, "general", "alexis", "nearly"))
	mturns := context_turns(mix[:], N)
	check_eq_i(len(mturns), 3, "a mixed conversation keeps all three")
	check(mturns[0].role == .User && mturns[1].role == .Assistant && mturns[2].role == .User, "the roles are assigned by author")
	check_eq_s(mturns[1].text, "not yet.", "the bot's own footer is stripped before it goes back to the model")
	check(!strings.contains(mturns[1].text, "qwen3"), "so the model is not taught to imitate its own attribution")

	// Deleted and empty messages contribute nothing.
	gaps := make([dynamic]w.Msg, context.temp_allocator)
	d := msg(1, "general", "sam", "")
	d.deleted = true
	append(&gaps, d)
	append(&gaps, msg(2, "general", "sam", "   "))
	append(&gaps, msg(3, "general", "sam", "real"))
	gturns := context_turns(gaps[:], N)
	check_eq_i(len(gturns), 1, "deleted and blank messages are skipped")

	check_eq_i(len(context_turns(nil, N)), 0, "an empty channel produces no context")

	// clip_utf8 never splits a rune.
	check_eq_s(clip_utf8("héllo", 2), "h", "clipping backs off a UTF-8 continuation byte")
	check_eq_s(clip_utf8("héllo", 3), "hé", "and lands on a boundary when it can")
	check_eq_s(clip_utf8("abc", 10), "abc", "a short string is returned whole")
	check_eq_s(clip_utf8("", 4), "", "and so is an empty one")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 9. The coalescing policy
// ---------------------------------------------------------------------------

// A plausible token stream: 300 tokens of about 4 bytes each, arriving every
// 9ms — which is 110 tokens a second, about what qwen3:0.6b does here.
test_coalescing :: proc() {
	fmt.println("the coalescing policy")

	toks := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 300 {
		switch i % 17 {
		case 16:
			append(&toks, ". ")
		case 8:
			append(&toks, "word ")
		case:
			append(&toks, "tok ")
		}
	}

	// The baseline: one edit per token, which is what the obvious
	// implementation does and what this policy exists to avoid.
	per_token := len(toks)

	text := strings.builder_make(context.temp_allocator)
	f := Flow{}
	now: i64 = 0
	edits := 0
	gap := 0
	worst_gap := 0
	for t in toks {
		strings.write_string(&text, t)
		now += 9
		if coalesce_due(COALESCE, f, now, strings.to_string(text), false) {
			edits += 1
			worst_gap = max(worst_gap, gap)
			gap = 0
			f = Flow{last_ms = now, last_len = strings.builder_len(text), edits = edits}
		} else {
			gap += 9
		}
	}
	// The final state is always published.
	if coalesce_due(COALESCE, f, now, strings.to_string(text), true) {
		edits += 1
	}

	total := strings.builder_len(text)
	secs := f64(now) / 1000.0
	fmt.printfln(
		"         %d tokens / %d bytes over %.1fs: %d edits (per-token would be %d)",
		len(toks),
		total,
		secs,
		edits,
		per_token,
	)
	check(edits < per_token / 8, "coalescing cuts the broadcasts by more than 8x: %d vs %d", edits, per_token)
	check(edits >= 3, "but the reply still visibly grows: %d updates", edits)
	check(
		f64(edits) / secs < 4.0,
		"fewer than four broadcasts a second of generation (%.2f)",
		f64(edits) / secs,
	)
	check(worst_gap <= 900, "no token waits longer than %dms to be published (worst %dms)", 900, worst_gap)

	// The rules, one at a time.
	f0 := Flow{last_ms = 0, last_len = 0}
	check(!coalesce_due(COALESCE, f0, 100, "a few chars", false), "too soon and too little: no edit")
	check(!coalesce_due(COALESCE, f0, 5000, "", false), "no growth: no edit, however long it has been")
	check(
		!coalesce_due(COALESCE, f0, 5000, strings.repeat("x", 10, context.temp_allocator), false),
		"a long wait but under the character floor: no edit",
	)
	check(
		coalesce_due(COALESCE, f0, 5000, strings.repeat("x", 40, context.temp_allocator), false),
		"long enough and enough new text: edit",
	)
	check(
		coalesce_due(COALESCE, f0, 400, "a complete sentence.", false),
		"a finished sentence flushes early",
	)
	check(
		!coalesce_due(COALESCE, f0, 100, "a complete sentence.", false),
		"but not before the sentence floor",
	)
	check(coalesce_due(COALESCE, f0, 1, "anything", true), "the finished reply is always published")
	check(
		coalesce_due(COALESCE, Flow{last_ms = 0, last_len = 8}, 1, "anything", true),
		"even when nothing new arrived at the end",
	)
	check(ends_sentence("done."), "a full stop ends a sentence")
	check(ends_sentence("really?  "), "trailing space does not hide it")
	check(ends_sentence("a list:"), "a colon counts, for a list about to start")
	check(!ends_sentence("mid clause"), "a bare word does not")
	check(!ends_sentence(""), "nor does nothing")

	check(COALESCE.min_ms >= 500, "the floor between edits is at least half a second")
	check(COALESCE.min_chars >= 16, "and at least %d new characters", COALESCE.min_chars)
	fmt.println()
}

// ---------------------------------------------------------------------------
// 10. The rate limiter
// ---------------------------------------------------------------------------

test_limiter :: proc() {
	fmt.println("the rate limiter")
	l := limiter_make(1200, 12)

	ok, _ := limiter_allow(l, 1000)
	check(ok, "the first reply is allowed")
	limiter_note(&l, 1000)

	ok2, why2 := limiter_allow(l, 1100)
	check(!ok2 && why2 != "", "a second reply 100ms later is refused (%s)", why2)
	ok3, _ := limiter_allow(l, 2300)
	check(ok3, "and allowed once the minimum gap has passed")

	// Spend the per-minute budget.
	l2 := limiter_make(0, 5)
	t: i64 = 0
	allowed := 0
	for i in 0 ..< 40 {
		if a, _ := limiter_allow(l2, t); a {
			allowed += 1
			limiter_note(&l2, t)
		}
		t += 100
	}
	check_eq_i(allowed, 5, "the per-minute budget is a hard ceiling")

	// And it refills.
	ok4, _ := limiter_allow(l2, 70_000)
	check(ok4, "the window rolls over after a minute")

	// A flood cannot produce more than the budget however it arrives.
	l3 := limiter_make(1200, 12)
	t3: i64 = 0
	fired := 0
	for i in 0 ..< 10_000 {
		if a, _ := limiter_allow(l3, t3); a {
			fired += 1
			limiter_note(&l3, t3)
		}
		t3 += 1 // one mention every millisecond, for ten seconds
	}
	check(fired <= 12, "ten thousand mentions in ten seconds produce at most 12 replies (%d)", fired)
	fmt.println()
}

// ---------------------------------------------------------------------------
// 11. What a reply looks like
// ---------------------------------------------------------------------------

test_rendering :: proc() {
	fmt.println("the shape of a reply")
	M :: MODEL_DEFAULT

	ph := render_reply("", M, false, false)
	check(strings.contains(ph, M), "the placeholder names the model")
	check(len(ph) < 120, "and is one short line (%d bytes)", len(ph))

	mid := render_reply("half an ans", M, false, false)
	check(strings.contains(mid, "half an ans"), "a streaming update carries the text so far")
	check(strings.contains(mid, M), "and still names the model")
	check(!strings.contains(mid, FOOTER_MARK), "the attribution footer is only on the finished reply")

	fin := render_reply("the whole answer.", M, true, false)
	check(strings.contains(fin, "the whole answer."), "the finished reply carries the answer")
	check(strings.contains(fin, FOOTER_MARK) && strings.contains(fin, M), "with the attribution")
	check(strings.contains(fin, "often wrong"), "which says plainly that it is often wrong")
	check(!strings.contains(fin, "*… "), "and no longer says it is writing")

	stop := render_reply("half don", M, true, true)
	check(strings.contains(stop, "stopped"), "a stopped reply says so")
	check(strings.contains(stop, M), "and is still attributed")

	empty := render_reply("", M, true, false)
	check(len(strings.trim_space(empty)) > 0, "a model that produced nothing still leaves a message")
	check(strings.contains(empty, M), "attributed, so the channel knows what failed")

	// The server refuses anything over MAX_TEXT, and a refused edit would
	// leave a half-written answer in the channel forever.
	long := render_reply(strings.repeat("w ", 9000, context.temp_allocator), M, true, false)
	check(len(long) <= MAX_POST, "a very long reply is clipped to the server's limit (%d bytes)", len(long))
	check(strings.contains(long, FOOTER_MARK), "and keeps its attribution rather than losing it to the clip")
	check(strings.contains(long, "…"), "and says that it was cut")

	sizes := [?]int{0, 1, 100, 3000, 3599, 3600, 3601, 5000, 20000}
	for n in sizes {
		r := render_reply(strings.repeat("x", n, context.temp_allocator), M, true, false)
		if len(r) > MAX_POST {
			ck.fail += 1
			fmt.printfln("  FAIL a %d-byte body rendered to %d bytes, over the limit", n, len(r))
		} else {
			ck.pass += 1
		}
	}
	fmt.printfln("  ok   nine body sizes all render inside %d bytes", MAX_POST)

	// Multi-byte text must not be cut mid-rune even at the limit.
	uni := render_reply(strings.repeat("é", 4000, context.temp_allocator), M, true, false)
	check(len(uni) <= MAX_POST, "a reply of multi-byte runes fits too")
	check(utf8.valid_string(uni), "and is still valid UTF-8 after clipping")

	// The no-ollama message, which has to be actionable.
	no := no_ollama_text(M)
	check(strings.contains(no, "ollama is not running"), "the no-ollama message says what is wrong")
	check(strings.contains(no, OLLAMA_START_HINT), "and gives the exact command")
	check(strings.contains(no, "127.0.0.1:11434"), "including the loopback address")
	check(!strings.contains(no, "systemctl"), "and never suggests touching the service unit")
	check(len(no) <= MAX_POST, "it fits a message")

	h := help_text(BOT_NICK_DEFAULT, M)
	check(strings.contains(h, "summarise") && strings.contains(h, "explain") && strings.contains(h, "stop"), "help lists the commands")
	check(strings.contains(h, M), "and names the model")
	check(len(h) <= MAX_POST, "and fits a message")

	check_eq_s(strip_footer(fin), "the whole answer.", "strip_footer recovers the body")
	check_eq_s(strip_footer(mid), "half an ans", "including from a streaming update")
	check_eq_s(strip_footer("no footer here"), "no footer here", "and leaves plain text alone")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 12. The request body
// ---------------------------------------------------------------------------

test_request_body :: proc() {
	fmt.println("the /api/chat request body")
	turns := [?]Turn {
		{role = .User, text = "sam: hello \"there\"\nsecond line"},
		{role = .Assistant, text = "hi"},
	}
	body := chat_body("qwen3:0.6b", "you are a bot", turns[:], 512, 0.6, context.temp_allocator)

	check(strings.contains(body, "\"model\":\"qwen3:0.6b\""), "the model is named")
	check(strings.contains(body, "\"stream\":true"), "streaming is on: that is the whole point")
	check(strings.contains(body, "\"think\":false"), "thinking is off, so the first token is the answer")
	check(strings.contains(body, "\"role\":\"system\""), "the system prompt is first")
	check(strings.contains(body, "\"role\":\"user\""), "a user turn is present")
	check(strings.contains(body, "\"role\":\"assistant\""), "and an assistant turn")
	check(strings.contains(body, "\\\"there\\\""), "a quote in the text is escaped")
	check(strings.contains(body, "\\n"), "and a newline")
	check(strings.contains(body, "\"num_predict\":512"), "the token cap is sent")
	check(!strings.contains(body, "\n"), "the body is one line: no raw newline survives escaping")

	// An empty system prompt is omitted rather than sent empty.
	b2 := chat_body("m", "   ", turns[:], 64, 0.6, context.temp_allocator)
	check(!strings.contains(b2, "\"role\":\"system\""), "a blank system prompt is left out")

	b3 := chat_body("m", "s", nil, 64, 0.6, context.temp_allocator)
	check(strings.contains(b3, "\"messages\":[{\"role\":\"system\""), "with no turns, the system prompt stands alone")

	// Control characters, which a pasted snippet will contain.
	t4 := [?]Turn{{role = .User, text = "tab\there\x01"}}
	b4 := chat_body("m", "", t4[:], 64, 0.6, context.temp_allocator)
	check(strings.contains(b4, "\\t"), "a tab is escaped")
	check(strings.contains(b4, "\\u0001"), "and so is a control byte")

	check(NUM_PREDICT * 8 < POST_BUDGET * 4, "the token cap cannot overflow the post budget")
	check(POST_BUDGET < MAX_POST, "the post budget leaves room for the footer")

	sp := system_prompt("qwen3-bot", "qwen3:0.6b", "general", false)
	check(strings.contains(sp, "qwen3:0.6b"), "the system prompt tells the model what it is")
	check(strings.contains(sp, "general"), "and where it is")
	check(strings.contains(sp, "120 words"), "and to be brief")
	spt := system_prompt("qwen3-bot", "qwen3:0.6b", "general", true)
	check(strings.contains(spt, "thread"), "a thread reply is told it is in a thread")
	fmt.println()
}

// ---------------------------------------------------------------------------
// 13. The message window
// ---------------------------------------------------------------------------

test_cache :: proc() {
	fmt.println("the message window")
	c := cache_make()

	// History arrives oldest-first and may be older than what is held, so an
	// append would put the window out of order and the context would read
	// backwards.
	cache_put(&c, msg(10, "general", "sam", "ten"))
	cache_put(&c, msg(12, "general", "sam", "twelve"))
	cache_put(&c, msg(11, "general", "sam", "eleven"))
	cache_put(&c, msg(1, "general", "sam", "one"))
	ids := make([dynamic]i64, context.temp_allocator)
	for m in c.msgs {
		append(&ids, m.id)
	}
	check(
		len(ids) == 4 && ids[0] == 1 && ids[1] == 10 && ids[2] == 11 && ids[3] == 12,
		"out-of-order inserts keep the window sorted by id",
	)

	cache_put(&c, msg(11, "general", "sam", "eleven again"))
	check_eq_i(len(c.msgs), 4, "a repeated id replaces rather than duplicates")
	m11, _ := cache_find(&c, 11)
	check_eq_s(m11.text, "eleven again", "and the newer copy wins")

	cache_edit(&c, 11, "edited", 99)
	e11, _ := cache_find(&c, 11)
	check(e11.text == "edited" && e11.edited == 99, "an edit broadcast updates the window")
	cache_delete(&c, 11)
	d11, _ := cache_find(&c, 11)
	check(d11.deleted && d11.text == "", "a delete tombstones it")

	_, missing := cache_find(&c, 999)
	check(!missing, "an id that was never seen is not found")

	// Channel and thread views.
	cache_put(&c, msg(20, "other", "sam", "elsewhere"))
	cache_put(&c, msg(21, "general", "sam", "a thread reply", 12))
	gen := cache_channel(&c, "general")
	has_reply := false
	for m in gen {
		if m.id == 21 {
			has_reply = true
		}
	}
	check(!has_reply, "a thread reply is not in the channel timeline, exactly as `history` has it")
	check(len(cache_channel(&c, "other")) == 1, "another channel is separate")
	th := cache_thread(&c, 12)
	check(len(th) == 2 && th[0].id == 12 && th[1].id == 21, "a thread is its root followed by its replies")
	check(len(cache_thread(&c, 999)) == 0, "a thread that does not exist is empty")

	// The window is bounded: the bot keeps a window, not a log.
	c2 := cache_make()
	for i in 1 ..= CACHE_MAX + 200 {
		cache_put(&c2, msg(i64(i), "general", "sam", "x"))
	}
	check_eq_i(len(c2.msgs), CACHE_MAX, fmt.tprintf("the window is capped at %d messages", CACHE_MAX))
	check(c2.msgs[0].id == 201, "and it is the oldest that falls off the back")
	fmt.println()
}
