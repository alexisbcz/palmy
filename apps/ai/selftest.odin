package main

// `ai --selftest` — the parts of this program that are not visual.
//
// Four areas, chosen because each one is where a streaming client actually
// breaks:
//
//   1. HTTP response framing: status, headers, chunked and Content-Length
//      bodies, fed in every awkward split a socket can produce.
//   2. NDJSON line splitting, including a JSON object cut in half by a read
//      boundary — the bug that bites every streaming client exactly once.
//   3. Markdown tokenising, blocks and inline spans.
//   4. Conversation persistence, round-tripping text that contains the
//      characters the record format uses as structure.

import "core:fmt"
import "core:mem/virtual"
import p "palmy:."
import sc "shadcn:."
import "core:strings"

// sc_register applies the same theme the window does, so a headless frame
// measures with the same radii and type scale.
sc_register :: proc() {
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)
	fonts := [?]string{"Geist-400.ttf", "Geist-500.ttf", "Geist-600.ttf", "Geist-700.ttf"}
	_ = fonts
}

// bytes_of exists because Odin will not transmute an untyped string literal.
bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

PASSED := 0
FAILED := 0

check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		PASSED += 1
		return
	}
	FAILED += 1
	fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
}

check_eq_s :: proc(got, want: string, what: string) {
	if got == want {
		PASSED += 1
		return
	}
	FAILED += 1
	fmt.printf("  FAIL  %s\n        got  %q\n        want %q\n", what, got, want)
}

check_eq_i :: proc(got, want: int, what: string) {
	if got == want {
		PASSED += 1
		return
	}
	FAILED += 1
	fmt.printf("  FAIL  %s: got %d, want %d\n", what, got, want)
}

run_selftest :: proc() -> int {
	fmt.println("palmy ai self-test")
	fmt.println()

	test_http_framing()
	test_ndjson()
	test_chat_stream()
	test_pull_stream()
	test_markdown()
	test_persistence()
	test_request_bodies()
	test_layout()

	fmt.println()
	fmt.printfln("%d assertions, %d failed", PASSED + FAILED, FAILED)
	if FAILED == 0 {
		fmt.println("ok")
	}
	return FAILED == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// 1. HTTP framing
// ---------------------------------------------------------------------------

// feed_in_splits runs the decoder over `wire` cut into pieces of `n` bytes,
// so one response can be replayed as any sequence of socket reads.
feed_in_splits :: proc(wire: string, n: int) -> (status: int, body: string, done: bool, bad: string) {
	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	raw := transmute([]u8)wire
	i := 0
	for i < len(raw) {
		step := min(n, len(raw) - i)
		decoder_feed(&d, raw[i:i + step], &out)
		i += step
	}
	return d.status, strings.clone(string(out[:]), context.temp_allocator), decoder_done(&d), d.bad
}

test_http_framing :: proc() {
	fmt.println("http framing")

	// A chunked response whose chunk boundaries do not line up with anything.
	chunked :=
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/x-ndjson\r\n" +
		"Transfer-Encoding: chunked\r\n" +
		"\r\n" +
		"5\r\nhello\r\n" +
		"1\r\n \r\n" +
		"6\r\nworld!\r\n" +
		"0\r\n\r\n"

	// Every split size from 1 to the whole thing must give the same answer.
	// 1 is the cruel case: every CRLF, every chunk-size digit and every body
	// byte arrives in its own read.
	for n in 1 ..= len(chunked) {
		status, body, done, bad := feed_in_splits(chunked, n)
		if status != 200 || body != "hello world!" || !done || bad != "" {
			check(
				false,
				"chunked response decoded wrongly at split %d: status %d body %q done %v bad %q",
				n,
				status,
				body,
				done,
				bad,
			)
			break
		}
	}
	check(true, "chunked body decodes identically at every one of %d split sizes", len(chunked))

	status, body, done, bad := feed_in_splits(chunked, 1 << 20)
	check_eq_i(status, 200, "status line")
	check_eq_s(body, "hello world!", "chunked body in one read")
	check(done, "chunked response is complete")
	check(bad == "", "chunked response reported no framing error")

	// Chunk size with an extension, and uppercase hex.
	ext :=
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
		"A;name=value\r\n0123456789\r\n0\r\n\r\n"
	_, ebody, edone, _ := feed_in_splits(ext, 3)
	check_eq_s(ebody, "0123456789", "uppercase hex chunk size with an extension")
	check(edone, "extension-bearing chunked response completes")

	// Content-Length framing.
	cl := "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
	for n in 1 ..= 7 {
		cs, cb, cd, _ := feed_in_splits(cl, n)
		check(cs == 200 && cb == "{\"ok\":true}" && cd, "content-length body at split %d", n)
	}

	// Neither framing: the body runs to the close.
	uc := "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\nboom"
	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&d, transmute([]u8)uc, &out)
	check_eq_i(d.status, 500, "non-2xx status is reported")
	check(!decoder_done(&d), "a close-delimited body is not done before the close")
	decoder_eof(&d)
	check(decoder_done(&d), "the close ends a close-delimited body")
	check_eq_s(string(out[:]), "boom", "close-delimited body")
	check_eq_s(decoder_header(&d, "Content-Type"), "text/plain", "header lookup ignores case")
	check_eq_s(decoder_header(&d, "x-absent"), "", "a missing header reads empty")

	// A truncated chunked body is an error, not a silent success.
	trunc := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"
	d2 := decoder_make()
	defer decoder_destroy(&d2)
	out2 := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&d2, transmute([]u8)trunc, &out2)
	decoder_eof(&d2)
	check(d2.bad != "", "a truncated chunked body is reported as an error")

	// Garbage is rejected rather than parsed.
	d3 := decoder_make()
	defer decoder_destroy(&d3)
	out3 := make([dynamic]u8, context.temp_allocator)
	decoder_feed(&d3, bytes_of("not an http response\r\n\r\n"), &out3)
	check(d3.bad != "", "a response with no status line is rejected")

	// LF-only line endings, which a hand-rolled server will send.
	lf := "HTTP/1.1 200 OK\nTransfer-Encoding: chunked\n\n3\nabc\n0\n\n"
	_, lbody, ldone, _ := feed_in_splits(lf, 2)
	check_eq_s(lbody, "abc", "bare LF line endings")
	check(ldone, "bare-LF chunked response completes")
}

// ---------------------------------------------------------------------------
// 2. NDJSON
// ---------------------------------------------------------------------------

test_ndjson :: proc() {
	fmt.println("ndjson splitting")

	src := "{\"a\":1}\n{\"b\":\"two\"}\n\n{\"c\":[3]}\n"

	// Whole.
	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, transmute([]u8)src, &lines, context.temp_allocator)
		check_eq_i(len(lines), 3, "three objects, the blank line dropped")
		check_eq_s(lines[1], "{\"b\":\"two\"}", "the second object")
	}

	// One byte at a time: the split lands inside every token, including
	// between a key and its value.
	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		raw := transmute([]u8)src
		// A line may never appear before its newline has: the running count
		// is checked after every single byte.
		monotone := true
		for i in 0 ..< len(raw) {
			splitter_feed(&s, raw[i:i + 1], &lines, context.temp_allocator)
			seen := 0
			for j in 0 ..= i {
				if raw[j] == '\n' {
					seen += 1
				}
			}
			if len(lines) > seen {
				monotone = false
			}
		}
		check(monotone, "no object is emitted before its newline arrives")
		check_eq_i(len(lines), 3, "byte-at-a-time gives the same three objects")
		check_eq_s(lines[0], "{\"a\":1}", "first object survives a byte-at-a-time feed")
		check_eq_s(lines[2], "{\"c\":[3]}", "third object survives a byte-at-a-time feed")
	}

	// A line with no trailing newline is held back until flushed, which is
	// what keeps a half-arrived object out of the parser.
	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"half\":tr"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 0, "an unterminated object is not emitted")
		splitter_feed(&s, bytes_of("ue}"), &lines, context.temp_allocator)
		check_eq_i(len(lines), 0, "still not emitted without its newline")
		splitter_flush(&s, &lines, context.temp_allocator)
		check_eq_i(len(lines), 1, "flush emits the last line")
		check_eq_s(lines[0], "{\"half\":true}", "the two halves rejoin exactly")
	}

	// CRLF-terminated NDJSON: the \r must not survive into the JSON.
	{
		s := splitter_make()
		defer splitter_destroy(&s)
		lines := make([dynamic]string, context.temp_allocator)
		splitter_feed(&s, bytes_of("{\"a\":1}\r\n"), &lines, context.temp_allocator)
		check_eq_s(lines[0], "{\"a\":1}", "a trailing CR is trimmed")
	}
}

// ---------------------------------------------------------------------------
// 3. A real /api/chat stream, through both framings at once
// ---------------------------------------------------------------------------

// CHAT_WIRE is a transcript of what ollama 0.33.3 actually sends, re-chunked
// so that the second JSON object is split across two HTTP chunks and the
// third is split in the middle of its `content` string.
CHAT_WIRE ::
	"HTTP/1.1 200 OK\r\n" +
	"Content-Type: application/x-ndjson\r\n" +
	"Transfer-Encoding: chunked\r\n" +
	"\r\n" +
	// object 1, whole (82 bytes)
	"52\r\n" +
	"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi\"},\"done\":false}\n" +
	"\r\n" +
	// object 2, first half (47 bytes)
	"2f\r\n" +
	"{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assist" +
	"\r\n" +
	// object 2's second half, plus the start of object 3 (91 bytes)
	"5b\r\n" +
	"ant\",\"content\":\"!\"},\"done\":false}\n{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"cont" +
	"\r\n" +
	// the rest of object 3 and the final object with the counters (173 bytes)
	"ad\r\n" +
	"ent\":\" there\\n\"},\"done\":false}\n{\"model\":\"qwen3:0.6b\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"prompt_eval_count\":23,\"eval_count\":4,\"eval_duration\":92160000}\n" +
	"\r\n" +
	"0\r\n\r\n"

test_chat_stream :: proc() {
	fmt.println("chat stream end to end")

	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena, 1 << 18)
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	// Replay it at every split size, because the point of this test is that
	// the read boundary is irrelevant.
	for step in ([?]int{1, 2, 3, 7, 13, 64, 1 << 20}) {
		d := decoder_make()
		defer decoder_destroy(&d)
		sp := splitter_make()
		defer splitter_destroy(&sp)

		body := make([dynamic]u8, context.temp_allocator)
		lines := make([dynamic]string, context.temp_allocator)
		raw := bytes_of(CHAT_WIRE)
		i := 0
		for i < len(raw) {
			n := min(step, len(raw) - i)
			clear(&body)
			decoder_feed(&d, raw[i:i + n], &body)
			splitter_feed(&sp, body[:], &lines, context.temp_allocator)
			i += n
		}
		splitter_flush(&sp, &lines, context.temp_allocator)

		text := strings.builder_make(context.temp_allocator)
		prompt_n, eval_n, done_seen := 0, 0, 0
		eval_ns: i64 = 0
		for line in lines {
			delta, ok := parse_chat_line(line, al)
			if !ok {
				continue
			}
			strings.write_string(&text, delta.content)
			if delta.done {
				done_seen += 1
				prompt_n = delta.prompt_n
				eval_n = delta.eval_n
				eval_ns = delta.eval_ns
			}
		}
		virtual.arena_free_all(&arena)

		got := strings.to_string(text)
		if got != "Hi! there\n" || prompt_n != 23 || eval_n != 4 || done_seen != 1 {
			check(
				false,
				"chat stream at split %d: text %q prompt %d eval %d done %d",
				step,
				got,
				prompt_n,
				eval_n,
				done_seen,
			)
			continue
		}
		rate := f64(eval_n) / (f64(eval_ns) / 1e9)
		check(rate > 43 && rate < 44, "tok/s from eval_count/eval_duration is %.2f", rate)
	}
	check(true, "the assembled reply is identical at every split size")

	// The reasoning field, which is where qwen3's tokens go when `think` is
	// left on and `content` comes back empty.
	{
		d, ok := parse_chat_line(
			"{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"Let me count.\"},\"done\":false}",
			al,
		)
		check(ok, "a thinking chunk parses")
		check_eq_s(d.think, "Let me count.", "message.thinking is read")
		check_eq_s(d.content, "", "message.content stays empty while thinking")
	}

	// An error object ends the stream rather than being rendered as text.
	{
		d, ok := parse_chat_line("{\"error\":\"model 'nope' not found\"}", al)
		check(ok, "an error object parses")
		check_eq_s(d.err, "model 'nope' not found", "the error text is lifted out")
	}

	// Escapes inside the content: a reply containing a quoted JSON key must
	// not confuse the reader.
	{
		d, ok := parse_chat_line(
			"{\"message\":{\"content\":\"use \\\"content\\\":\\\"x\\\" and a \\\\ and a \\n\"},\"done\":false}",
			al,
		)
		check(ok, "a chunk whose text contains JSON parses")
		check_eq_s(
			d.content,
			"use \"content\":\"x\" and a \\ and a \n",
			"escapes inside content are decoded, not matched as structure",
		)
	}

	// /api/generate's field name.
	{
		d, ok := parse_chat_line("{\"response\":\"abc\",\"done\":false}", al)
		check(ok, "a /api/generate chunk parses")
		check_eq_s(d.content, "abc", "`response` is accepted as content")
	}

	virtual.arena_free_all(&arena)
}

test_pull_stream :: proc() {
	fmt.println("pull progress")
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena, 1 << 16)
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	d1, ok1 := parse_pull_line("{\"status\":\"pulling manifest\"}", al)
	check(ok1, "a pull status line parses")
	check_eq_s(d1.status, "pulling manifest", "the status text")
	check(!d1.done, "a manifest line is not the end")

	d2, _ := parse_pull_line(
		"{\"status\":\"pulling 7f40\",\"digest\":\"sha256:7f40\",\"total\":522640096,\"completed\":261320048}",
		al,
	)
	check(d2.total == 522640096, "total bytes")
	check(d2.completed == 261320048, "completed bytes")
	check(f64(d2.completed) / f64(d2.total) == 0.5, "halfway through the blob")

	d3, _ := parse_pull_line("{\"status\":\"success\"}", al)
	check(d3.done, "`success` ends the pull")

	d4, _ := parse_pull_line("{\"error\":\"pull model manifest: file does not exist\"}", al)
	check_eq_s(d4.err, "pull model manifest: file does not exist", "a pull error is reported")
}

// ---------------------------------------------------------------------------
// 4. Markdown
// ---------------------------------------------------------------------------

MD_SRC ::
	"# Title\n" +
	"\n" +
	"Some **bold** and *thin* and `code()` text that\n" +
	"wraps onto a second source line.\n" +
	"\n" +
	"## Steps\n" +
	"\n" +
	"- first\n" +
	"- second with `inline`\n" +
	"  - nested\n" +
	"\n" +
	"1. one\n" +
	"2. two\n" +
	"\n" +
	"> a quotation\n" +
	"> continued\n" +
	"\n" +
	"---\n" +
	"\n" +
	"```odin\n" +
	"x := 1\n" +
	"\n" +
	"y := 2\n" +
	"```\n"

test_markdown :: proc() {
	fmt.println("markdown")

	blocks := md_blocks(MD_SRC, context.temp_allocator)
	kinds := make([dynamic]Block_Kind, context.temp_allocator)
	for b in blocks {
		append(&kinds, b.kind)
	}
	want := [?]Block_Kind {
		.Heading,
		.Paragraph,
		.Heading,
		.Bullet,
		.Bullet,
		.Bullet,
		.Numbered,
		.Numbered,
		.Quote,
		.Rule,
		.Code,
	}
	check_eq_i(len(blocks), len(want), "block count")
	same := len(blocks) == len(want)
	if same {
		for b, i in blocks {
			if b.kind != want[i] {
				same = false
				break
			}
		}
	}
	check(same, "block kinds in order: %v", kinds[:])

	check_eq_i(blocks[0].level, 1, "an h1")
	check_eq_s(blocks[0].text, "Title", "heading text has no hashes")
	check_eq_s(
		blocks[1].text,
		"Some **bold** and *thin* and `code()` text that wraps onto a second source line.",
		"soft-wrapped source lines join into one paragraph",
	)
	check_eq_i(blocks[2].level, 2, "an h2")
	check_eq_s(blocks[4].text, "second with `inline`", "a bullet keeps its inline markup")
	check_eq_i(blocks[5].level, 1, "two spaces of indent is one level of nesting")
	check_eq_i(blocks[7].ordinal, 2, "the second numbered item knows its number")
	check_eq_s(blocks[8].text, "a quotation continued", "consecutive quote lines join")
	check_eq_s(blocks[10].lang, "odin", "the fence's language")
	check_eq_i(len(blocks[10].lines), 3, "a blank line inside a fence is kept")
	check_eq_s(blocks[10].lines[1], "", "and stays blank")
	check(!blocks[10].open, "a closed fence is not marked open")

	// A fence the model has not finished typing: the normal state halfway
	// through a stream.
	half := md_blocks("text\n\n```sh\nls -l\n", context.temp_allocator)
	check_eq_i(len(half), 2, "an unterminated fence still produces a block")
	check(half[1].open, "an unterminated fence is marked open")
	check_eq_i(len(half[1].lines), 1, "with the lines typed so far")

	// Inline spans.
	spans := md_spans("Some **bold** and *thin* and `code()` text", context.temp_allocator)
	check_eq_i(len(spans), 7, "seven inline spans: four of text and three of markup")
	check(spans[0].kind == .Text && spans[0].text == "Some ", "leading text")
	check(spans[1].kind == .Bold && spans[1].text == "bold", "a bold span")
	check(spans[3].kind == .Italic && spans[3].text == "thin", "an italic span")
	check(spans[5].kind == .Code && spans[5].text == "code()", "a code span")

	both := md_spans("***all of it***", context.temp_allocator)
	check(both[0].kind == .Bold_Italic, "three asterisks are bold and italic at once")

	// Markup that must be left alone.
	snake := md_spans("call some_long_name now", context.temp_allocator)
	check_eq_i(len(snake), 1, "snake_case is not emphasis")
	check_eq_s(snake[0].text, "call some_long_name now", "and comes through untouched")

	unmatched := md_spans("2 * 3 * 4 is twelve", context.temp_allocator)
	joined := strings.builder_make(context.temp_allocator)
	for s in unmatched {
		strings.write_string(&joined, s.text)
	}
	check_eq_s(
		strings.to_string(joined),
		"2 * 3 * 4 is twelve",
		"loose asterisks keep all their characters",
	)

	// An emphasis run must not borrow its closing marker from inside a code
	// span: this is the case that turned `num_predict` into `numpredict`.
	mixed := md_spans(
		"_The reply limit (`num_predict`) was reached._",
		context.temp_allocator,
	)
	joined3 := strings.builder_make(context.temp_allocator)
	code_seen := false
	for sp in mixed {
		strings.write_string(&joined3, sp.text)
		if sp.kind == .Code {
			code_seen = true
			check_eq_s(sp.text, "num_predict", "the code span keeps its underscore")
		}
	}
	check(code_seen, "the code span survives inside an emphasis run")
	check_eq_s(
		strings.to_string(joined3),
		"The reply limit (num_predict) was reached.",
		"the emphasis closes at the end, not inside the backticks",
	)

	snake2 := md_spans("set num_predict and top_p now", context.temp_allocator)
	check_eq_i(len(snake2), 1, "two snake_case words do not pair into emphasis")

	code_wins := md_spans("`a *b* c`", context.temp_allocator)
	check_eq_i(len(code_wins), 1, "nothing inside a code span is markup")
	check_eq_s(code_wins[0].text, "a *b* c", "the code span's text is literal")

	link := md_spans("see [the docs](https://example.test/x) now", context.temp_allocator)
	check_eq_i(len(link), 3, "a link splits the run in three")
	check(link[1].kind == .Link, "the middle span is a link")
	check_eq_s(link[1].text, "the docs", "with the label as its text")
	check_eq_s(link[1].href, "https://example.test/x", "and the target as its href")

	esc := md_spans("a \\*not italic\\* b", context.temp_allocator)
	j2 := strings.builder_make(context.temp_allocator)
	for s in esc {
		strings.write_string(&j2, s.text)
	}
	check_eq_s(strings.to_string(j2), "a *not italic* b", "a backslash escapes a marker")

	// md_plain is what a title or a clipboard copy uses.
	check_eq_s(
		md_plain("## Hello **there**", context.temp_allocator),
		"Hello there",
		"md_plain strips the markup",
	)
}

// ---------------------------------------------------------------------------
// 5. Persistence
// ---------------------------------------------------------------------------

test_persistence :: proc() {
	fmt.println("persistence")

	// The escape has to survive exactly the bytes the record format uses as
	// structure, plus multi-byte UTF-8.
	for s in ([?]string {
		"",
		"plain",
		"two\nlines",
		"a\tb",
		"back\\slash",
		"\\n literal backslash-n",
		"trailing newline\n",
		"\r\n mixed \n\r",
		"émoji ✨ and 日本語",
		"msg user - 0 0 0 0 0 looks like a record",
	}) {
		round := store_unescape(store_escape(s, context.temp_allocator), context.temp_allocator)
		check_eq_s(round, s, "escape round-trips")
		esc := store_escape(s, context.temp_allocator)
		check(
			!strings.contains(esc, "\n"),
			"an escaped payload holds no newline: %q",
			esc,
		)
	}

	// A whole conversation.
	c := Conversation {
		id      = "1759570000-007",
		title   = "A title with\na newline and a \\ backslash",
		model   = "qwen3:0.6b",
		created = 1759570000,
		msgs    = make([dynamic]Message, context.temp_allocator),
	}
	append(&c.msgs, Message{role = .User, text = "Write\ta haiku\nabout sockets"})
	append(
		&c.msgs,
		Message {
			role = .Assistant,
			model = "qwen3:0.6b",
			text = "# Reply\n\n- one\n- two\n\n```sh\necho \"hi\"\n```\n",
			think = "The user wants\na haiku.",
			ttft = 0.1234,
			tps = 88.5,
			in_n = 23,
			out_n = 41,
			halted = true,
		},
	)

	text := conv_serialise(&c, context.temp_allocator)
	back, ok := conv_parse(text, context.temp_allocator)
	check(ok, "a serialised conversation parses back")
	check_eq_s(back.id, c.id, "id round-trips")
	check_eq_s(back.title, c.title, "title round-trips through the escape")
	check_eq_s(back.model, c.model, "model round-trips")
	check(back.created == c.created, "created timestamp round-trips")
	check_eq_i(len(back.msgs), 2, "both messages round-trip")
	check(back.msgs[0].role == .User, "the first message is the user's")
	check_eq_s(back.msgs[0].text, c.msgs[0].text, "tabs and newlines survive")
	check(back.msgs[1].role == .Assistant, "the second is the assistant's")
	check_eq_s(back.msgs[1].text, c.msgs[1].text, "a markdown reply survives verbatim")
	check_eq_s(back.msgs[1].think, c.msgs[1].think, "the reasoning block survives")
	check_eq_s(back.msgs[1].model, "qwen3:0.6b", "which model answered is remembered")
	check_eq_i(back.msgs[1].in_n, 23, "prompt token count is remembered")
	check_eq_i(back.msgs[1].out_n, 41, "completion token count is remembered")
	check(back.msgs[1].halted, "a halted reply stays halted")
	check(
		back.msgs[1].ttft > 0.1233 && back.msgs[1].ttft < 0.1235,
		"time to first token survives (%.4f)",
		back.msgs[1].ttft,
	)
	check(
		back.msgs[1].tps > 88.4 && back.msgs[1].tps < 88.6,
		"tok/s survives (%.2f)",
		back.msgs[1].tps,
	)

	// Re-serialising the parsed copy must be byte-identical: the format has no
	// lossy corner.
	text2 := conv_serialise(&back, context.temp_allocator)
	check_eq_s(text2, text, "serialise(parse(x)) == x")

	// Rubbish is rejected rather than half-loaded.
	_, bad := conv_parse("not a palmy-ai file\nid 1\n", context.temp_allocator)
	check(!bad, "a file without the magic line is rejected")

	// Titles.
	check_eq_s(
		title_from("Explain how a mutex works\nin detail", context.temp_allocator),
		"Explain how a mutex works",
		"a title is the first line",
	)
	long := title_from(
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		context.temp_allocator,
	)
	check(len(long) <= 46, "a long title is cut (%d bytes)", len(long))
	check_eq_s(title_from("", context.temp_allocator), "New conversation", "an empty title")
}

// ---------------------------------------------------------------------------
// 6. Request bodies
// ---------------------------------------------------------------------------

test_request_bodies :: proc() {
	fmt.println("request bodies")

	b := strings.builder_make(context.temp_allocator)
	json_escape(&b, "a \"quote\", a \\ and a \n plus \x01")
	check_eq_s(
		strings.to_string(b),
		"\"a \\\"quote\\\", a \\\\ and a \\n plus \\u0001\"",
		"json_escape covers quotes, backslashes, newlines and control bytes",
	)

	msgs := make([dynamic]Message, context.temp_allocator)
	append(&msgs, Message{role = .User, text = "hi"})
	append(&msgs, Message{role = .Assistant, text = "hello"})
	append(&msgs, Message{role = .User, text = "again"})

	body := chat_body(
		"qwen3:0.6b",
		msgs[:],
		Params{temperature = 0.42, top_p = 0.85, num_predict = 128, think = false, system = "be terse"},
		context.temp_allocator,
	)
	check(strings.contains(body, "\"think\":false"), "think is explicit in the request")
	check(strings.contains(body, "\"stream\":true"), "the request asks for a stream")
	check(strings.contains(body, "\"temperature\":0.420"), "temperature reaches the request")
	check(strings.contains(body, "\"top_p\":0.850"), "top_p reaches the request")
	check(strings.contains(body, "\"num_predict\":128"), "num_predict reaches the request")
	check(
		strings.contains(body, "{\"role\":\"system\",\"content\":\"be terse\"}"),
		"the system prompt is the first message",
	)
	check(
		strings.index(body, "\"user\"") < strings.index(body, "\"assistant\""),
		"the history keeps its order",
	)
	check_eq_i(strings.count(body, "\"role\""), 4, "system plus three turns")

	thinking := chat_body(
		"qwen3:0.6b",
		msgs[:],
		Params{temperature = 0.7, top_p = 0.9, num_predict = 512, think = true},
		context.temp_allocator,
	)
	check(strings.contains(thinking, "\"think\":true"), "thinking can be asked for")
	check(
		!strings.contains(thinking, "\"role\":\"system\""),
		"an empty system prompt is omitted entirely",
	)

	pb := pull_body("qwen3:1.7b", context.temp_allocator)
	check_eq_s(pb, "{\"model\":\"qwen3:1.7b\",\"stream\":true}", "the pull body")

	// Nothing in this program names a host other than the loopback address.
	check_eq_s(HOST, "127.0.0.1", "the only host is the loopback address")
	check(PORT == 11434, "the only port is ollama's")

	check_eq_s(human_bytes(522653767, context.temp_allocator), "498 MB", "bytes are human-readable")
	check_eq_s(human_bytes(1018534295, context.temp_allocator), "971 MB", "the resident footprint ollama reports")
	check_eq_s(human_bytes(3 << 30, context.temp_allocator), "3.0 GB", "and so are gigabytes")
}

// ---------------------------------------------------------------------------
// 7. Layout, headless
//
// A chat window is three fixed bands around one scrolling region, and the way
// that goes wrong is silent: the transcript's content height leaks into the
// sizing of its siblings and the composer slides off the bottom of the window.
// palmy renders without a compositor, so the whole frame can be built here and
// the bands measured — with a transcript ten times taller than the window, and
// again with an empty one.
// ---------------------------------------------------------------------------

LOREM ::
	"A software rasteriser can keep a desktop interface at sixty frames a " +
	"second because almost every pixel it writes is a flat span, and a flat " +
	"span costs what a memset costs. The expensive part is the edges, and the " +
	"edges are a vanishing fraction of the area.\n\n" +
	"- memory bandwidth is the budget\n" +
	"- a 1080p frame is eight megabytes\n" +
	"- `fill_round_rect` is a span loop with a signed distance field at the ends\n\n" +
	"```odin\nfor y in 0 ..< h {\n\trow := px[y * w:][:w]\n}\n```\n\n" +
	"That is the whole trick, and it is why **the window stays responsive**.\n"

layout_state :: proc(messages: int) -> ^St {
	st := new(St)
	probe_init(&st.probe)
	stream_init(&st.chat)
	stream_init(&st.pull)
	st.input = make([dynamic]u8)
	st.pull_name = make([dynamic]u8)
	st.sys_buf = make([dynamic]u8)
	st.think_open = make(map[int]bool)
	st.prompts = make([dynamic]Prompt)
	st.model = "qwen3:0.6b"
	st.pinned = true
	st.show_think = true
	st.pr = Params{temperature = 0.7, top_p = 0.9, num_predict = 512}

	st.convs = make([dynamic]Conversation)
	c := Conversation {
		id      = "test-0001",
		title   = "A headless conversation",
		model   = "qwen3:0.6b",
		created = 1,
		msgs    = make([dynamic]Message),
	}
	for i in 0 ..< messages {
		append(&c.msgs, Message{role = .User, text = "Why is a software rasteriser fast?"})
		append(
			&c.msgs,
			Message {
				role = .Assistant,
				model = "qwen3:0.6b",
				text = LOREM,
				think = "Let me think about bandwidth first.",
				ttft = 0.09,
				tps = 88.8,
				in_n = 40,
				out_n = 220,
			},
		)
	}
	append(&st.convs, c)
	return st
}

test_layout :: proc() {
	fmt.println("layout, headless")

	WIN_W :: 1280
	WIN_H :: 820

	sc_register()
	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-row bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)

	for messages in ([?]int{0, 1, 12}) {
		st := layout_state(messages)

		// Three frames: palmy's hit testing and text wrapping run against the
		// previous frame, so a layout is only settled once it has repeated.
		rc, rf, rm: p.Rect
		for _ in 0 ..< 3 {
			ui := p.offscreen_begin(off)
			build(ui, st)
			p.offscreen_end(off)
			rc = p.rect_of(&off.ctx, st.composer_id)
			rf = p.rect_of(&off.ctx, st.footer_id)
			rm = p.rect_of(&off.ctx, st.main_id)
		}

		label := fmt.tprintf("with %d exchanges", messages)

		check(
			rm.h > WIN_H - 1 && rm.h < WIN_H + 1,
			"%s: the workspace column is the window's height, not its content's (%.1f)",
			label,
			rm.h,
		)
		check(
			rf.y + rf.h > WIN_H - 1 && rf.y + rf.h < WIN_H + 1,
			"%s: the footer sits on the bottom edge (bottom %.1f, want %d)",
			label,
			rf.y + rf.h,
			WIN_H,
		)
		check(
			rf.h > FOOTER_H - 1 && rf.h < FOOTER_H + 1,
			"%s: the footer keeps its %dpx height (%.1f)",
			label,
			FOOTER_H,
			rf.h,
		)
		check(
			rc.y + rc.h < rf.y + 1 && rc.y + rc.h > rf.y - 20,
			"%s: the composer sits directly above the footer (composer bottom %.1f, footer top %.1f)",
			label,
			rc.y + rc.h,
			rf.y,
		)
		check(
			rc.y > TOPBAR_H && rc.y < WIN_H,
			"%s: the composer is inside the window (y %.1f)",
			label,
			rc.y,
		)
		check(
			rc.w > 400,
			"%s: the composer spans the workspace (%.1f wide)",
			label,
			rc.w,
		)

		// The transcript must be a window onto its content, not as tall as it.
		tr := p.rect_of(&off.ctx, st.tr_id)
		over := p.scroll_extent(&off.ctx, st.tr_id)
		check(
			tr.h > 100 && tr.h < WIN_H,
			"%s: the transcript is a viewport (%.1f tall)",
			label,
			tr.h,
		)
		if messages >= 12 {
			check(
				over.y > 0,
				"%s: a transcript taller than the window actually overflows (%.1f)",
				label,
				over.y,
			)
		}
	}

	// And with the parameter panel open, which takes 268px off the workspace.
	st := layout_state(6)
	st.show_params = true
	rc, rf: p.Rect
	for _ in 0 ..< 3 {
		ui := p.offscreen_begin(off)
		build(ui, st)
		p.offscreen_end(off)
		rc = p.rect_of(&off.ctx, st.composer_id)
		rf = p.rect_of(&off.ctx, st.footer_id)
	}
	check(
		rf.y + rf.h > WIN_H - 1 && rf.y + rf.h < WIN_H + 1,
		"with the parameter panel open the footer is still on the bottom edge (%.1f)",
		rf.y + rf.h,
	)
	check(
		rc.w > 300 && rc.w < WIN_W - SIDEBAR_W - PARAMS_W,
		"the composer narrows for the parameter panel (%.1f wide)",
		rc.w,
	)

	// Finally, render one and keep it: a frame that can be looked at is worth
	// more than an assertion about it.
	st2 := layout_state(3)
	for _ in 0 ..< 3 {
		ui := p.offscreen_begin(off)
		build(ui, st2)
		p.offscreen_end(off)
	}
	if p.offscreen_write_png(off, "/tmp/palmy-ai-layout.png") {
		fmt.println("  (wrote /tmp/palmy-ai-layout.png)")
	}
}
