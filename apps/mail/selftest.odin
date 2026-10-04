// Headless assertions: `mail --selftest`.
//
// Everything that can be wrong without being visible is checked here — header
// unfolding, encoded words, transfer decoding, the MIME walk, the HTML text
// fallback, Maildir flag round-trips, threading over the real fixtures, search,
// the composer's buffer and its reply arithmetic, and the fact that Send
// writes into the local Outbox and nowhere else.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

@(private = "file")
checks := 0

@(private = "file")
failures := 0

ok :: proc(cond: bool, what: string, args: ..any) {
	checks += 1
	if !cond {
		failures += 1
		fmt.eprintf("  FAIL  ")
		fmt.eprintfln(what, ..args)
	}
}

eq_str :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.eprintfln("  FAIL  %s\n        got  %q\n        want %q", what, got, want)
	}
}

eq_int :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.eprintfln("  FAIL  %s: got %d, want %d", what, got, want)
	}
}

run_selftest :: proc() -> int {
	fmt.println("mail --selftest")

	test_headers()
	test_encoded_words()
	test_transfer_encodings()
	test_addresses()
	test_content_type()
	test_multipart()
	test_body_extraction()
	test_html_to_text()
	test_dates()
	test_maildir_flags()
	test_subjects()
	test_buffer()
	test_line_edit()
	test_reply()
	test_body_clipping()
	test_protocol_rules()
	test_fixtures_and_threading()

	fmt.printfln("")
	if failures == 0 {
		fmt.printfln("%d assertions, all passed", checks)
		return 0
	}
	fmt.printfln("%d assertions, %d FAILED", checks, failures)
	return 1
}

// ---------------------------------------------------------------------------

test_headers :: proc() {
	raw := "Subject: a folded\r\n\tsubject line\r\nFrom: a@b.test\r\nX-Multi: one\r\nX-Multi: two\r\n\r\nbody here\r\n"
	head, body := split_message(raw)
	eq_str(strings.trim_space(body), "body here", "split_message body")
	hs := parse_headers(head, context.temp_allocator)
	eq_str(header_of(hs, "subject"), "a folded subject line", "header unfolding joins with one space")
	eq_str(header_of(hs, "from"), "a@b.test", "header lookup is case-folded")
	eq_int(len(headers_of(hs, "x-multi", context.temp_allocator)), 2, "repeated headers are all kept")
	eq_str(header_of(hs, "nope"), "", "a missing header is empty")

	// LF-only, which is what a file written by a unix tool looks like.
	h2, b2 := split_message("A: 1\nB: 2\n\nbody")
	eq_str(strings.trim_space(b2), "body", "LF-only split")
	eq_str(header_of(parse_headers(h2, context.temp_allocator), "b"), "2", "LF-only headers")

	// All headers, no blank line: a truncated file must not lose them.
	h3, b3 := split_message("A: 1\nB: 2\n")
	eq_str(b3, "", "a message with no body has no body")
	eq_str(header_of(parse_headers(h3, context.temp_allocator), "a"), "1", "headers without a body")
}

test_encoded_words :: proc() {
	eq_str(
		decode_encoded_words("=?utf-8?B?U8O4cmVu?=", context.temp_allocator),
		"Søren",
		"base64 encoded word",
	)
	eq_str(
		decode_encoded_words("=?utf-8?Q?Caf=C3=A9?=", context.temp_allocator),
		"Café",
		"Q encoded word",
	)
	eq_str(
		decode_encoded_words("=?utf-8?Q?one_two?=", context.temp_allocator),
		"one two",
		"underscore is a space in Q encoding",
	)
	// Adjacent encoded words separated by whitespace join with no space, which
	// is what reassembles a split multi-byte name.
	eq_str(
		decode_encoded_words("=?utf-8?B?5p2O?= =?utf-8?B?6Zuv?=", context.temp_allocator),
		"李雯",
		"adjacent encoded words join without the fold space",
	)
	eq_str(
		decode_encoded_words("Plain =?utf-8?Q?caf=C3=A9?= tail", context.temp_allocator),
		"Plain café tail",
		"encoded word inside plain text",
	)
	eq_str(decode_encoded_words("no words here", context.temp_allocator), "no words here", "passthrough")
	eq_str(
		decode_encoded_words("=?utf-8?B?broken", context.temp_allocator),
		"=?utf-8?B?broken",
		"an unterminated encoded word is left alone",
	)
}

test_transfer_encodings :: proc() {
	round :: proc(s: string) -> string {
		enc := encode_base64(transmute([]u8)s, context.temp_allocator)
		return string(decode_base64(enc, context.temp_allocator))
	}
	eq_str(round(""), "", "base64 round-trip, empty")
	eq_str(round("a"), "a", "base64 round-trip, 1 byte")
	eq_str(round("ab"), "ab", "base64 round-trip, 2 bytes")
	eq_str(round("abc"), "abc", "base64 round-trip, 3 bytes")
	eq_str(round("hello world"), "hello world", "base64 round-trip, 11 bytes")
	eq_str(round("日本語テキスト"), "日本語テキスト", "base64 round-trip, multi-byte")
	eq_str(encode_base64(transmute([]u8)string("Man"), context.temp_allocator), "TWFu", "base64 known vector")
	// Hard line breaks inside a transport-encoded body must be skipped.
	eq_str(
		string(decode_base64("aGVs\r\nbG8=", context.temp_allocator)),
		"hello",
		"base64 ignores line breaks",
	)

	eq_str(
		string(decode_qp("Caf=C3=A9", false, context.temp_allocator)),
		"Café",
		"quoted-printable hex escapes",
	)
	eq_str(
		string(decode_qp("one=\r\ntwo", false, context.temp_allocator)),
		"onetwo",
		"quoted-printable soft line break",
	)
	eq_str(
		string(decode_qp("a_b", true, context.temp_allocator)),
		"a b",
		"underscore is a space only in header mode",
	)
	eq_str(
		string(decode_qp("a_b", false, context.temp_allocator)),
		"a_b",
		"underscore is literal in a body",
	)
	eq_str(
		string(decode_qp("100=", false, context.temp_allocator)),
		"100=",
		"a dangling = is literal",
	)

	// The fixture writer and the reader have to agree.
	src := "Voici le résumé de l'étape deux, avec un = et une ligne très longue qui doit être coupée par le codage quoted-printable à soixante-seize colonnes."
	eq_str(
		string(decode_qp(qp_encode(src, context.temp_allocator), false, context.temp_allocator)),
		src,
		"qp_encode round-trips through decode_qp",
	)

	eq_str(latin1_to_utf8({0x43, 0x61, 0x66, 0xe9}, context.temp_allocator), "Café", "latin-1 widening")
	eq_str(
		charset_to_utf8({0x43, 0x61, 0x66, 0xe9}, "iso-8859-1", context.temp_allocator),
		"Café",
		"charset_to_utf8 handles iso-8859-1",
	)
}

test_addresses :: proc() {
	a := parse_address("Ada Lovelace <ada@analytical.test>", context.temp_allocator)
	eq_str(a.name, "Ada Lovelace", "display name")
	eq_str(a.email, "ada@analytical.test", "angle address")

	b := parse_address("bare@host.test", context.temp_allocator)
	eq_str(b.name, "", "a bare address has no display name")
	eq_str(b.email, "bare@host.test", "bare address")
	eq_str(addr_label(b), "bare", "addr_label falls back to the local part")

	q := parse_address("\"Lovelace, Ada\" <ada@analytical.test>", context.temp_allocator)
	eq_str(q.name, "Lovelace, Ada", "a quoted display name keeps its comma")

	e := parse_address("=?utf-8?B?5p2O6Zuv?= <liwen@example.test>", context.temp_allocator)
	eq_str(e.name, "李雯", "an encoded display name is decoded")

	list := parse_addresses(
		"\"Lovelace, Ada\" <ada@a.test>, Grace <grace@b.test>, bare@c.test",
		context.temp_allocator,
	)
	eq_int(len(list), 3, "the comma inside a quoted name does not split the list")
	eq_str(list[1].email, "grace@b.test", "second address in the list")
	eq_str(list[2].email, "bare@c.test", "third address in the list")

	eq_int(len(parse_addresses("", context.temp_allocator)), 0, "an empty address list is empty")
	eq_str(
		format_address({name = "Ada", email = "a@b.test"}, context.temp_allocator),
		"Ada <a@b.test>",
		"format_address",
	)
}

test_content_type :: proc() {
	ct := parse_content_type("text/plain; charset=\"utf-8\"", context.temp_allocator)
	eq_str(ct.kind, "text", "content type kind")
	eq_str(ct.sub, "plain", "content type subtype")
	eq_str(ct.charset, "utf-8", "a quoted charset parameter")

	mp := parse_content_type("multipart/mixed; boundary=\"a;b=c\"", context.temp_allocator)
	eq_str(mp.boundary, "a;b=c", "a quoted boundary may contain a semicolon")

	up := parse_content_type("TEXT/HTML; CharSet=UTF-8", context.temp_allocator)
	eq_str(up.sub, "html", "the mime type is folded to lower case")
	eq_str(up.charset, "UTF-8", "a parameter value keeps its case")

	def := parse_content_type("", context.temp_allocator)
	eq_str(content_type_full(def, context.temp_allocator), "text/plain", "the default is text/plain")
}

test_multipart :: proc() {
	body := "preamble, not content\r\n--B\r\nA: 1\r\n\r\nfirst\r\n--B\r\nA: 2\r\n\r\nsecond\r\n--B--\r\nepilogue"
	parts := split_multipart(body, "B", context.temp_allocator)
	eq_int(len(parts), 2, "the preamble and epilogue are not parts")
	_, b1 := split_message(parts[0])
	_, b2 := split_message(parts[1])
	eq_str(strings.trim_space(b1), "first", "first part body")
	eq_str(strings.trim_space(b2), "second", "second part body")

	// A boundary string appearing mid-line is not a delimiter.
	inner := "--B\r\n\r\nthe text --B is not a delimiter\r\n--B--\r\n"
	p2 := split_multipart(inner, "B", context.temp_allocator)
	eq_int(len(p2), 1, "a boundary must start its own line")
	_, ib := split_message(p2[0])
	ok(strings.contains(ib, "not a delimiter"), "the mid-line boundary stayed in the body")

	eq_int(
		len(split_multipart("no boundaries at all", "B", context.temp_allocator)),
		0,
		"a body with no delimiters has no parts",
	)
}

test_body_extraction :: proc() {
	// text/plain preferred over text/html in a multipart/alternative.
	alt := strings.concatenate(
		{
			"MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"X\"\r\n",
			"\r\n--X\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nthe plain part\r\n",
			"--X\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>the html part</p>\r\n--X--\r\n",
		},
		context.temp_allocator,
	)
	h, b := split_message(alt)
	res := extract_body(h, b, context.temp_allocator)
	eq_str(strings.trim_space(res.text), "the plain part", "text/plain wins over text/html")
	ok(res.had_plain && res.had_html, "both representations were seen")
	ok(!res.from_html, "the alternative did not need the fallback")

	// html only: the fallback must run.
	only := "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>only html</p><p>second</p>"
	h2, b2 := split_message(only)
	r2 := extract_body(h2, b2, context.temp_allocator)
	ok(r2.from_html, "an html-only message falls back")
	ok(!r2.had_plain, "an html-only message has no plain part")
	ok(strings.contains(r2.text, "only html"), "the fallback produced the text")

	// Attachments: name, type and decoded size, bytes not kept.
	payload := encode_base64(transmute([]u8)string("0123456789"), context.temp_allocator)
	mixed := strings.concatenate(
		{
			"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"M\"\r\n",
			"\r\n--M\r\nContent-Type: text/plain\r\n\r\nsee attached\r\n",
			"--M\r\nContent-Type: application/pdf; name=\"résumé.pdf\"\r\n",
			"Content-Disposition: attachment; filename=\"résumé.pdf\"\r\n",
			"Content-Transfer-Encoding: base64\r\n\r\n",
			payload,
			"\r\n--M--\r\n",
		},
		context.temp_allocator,
	)
	h3, b3 := split_message(mixed)
	r3 := extract_body(h3, b3, context.temp_allocator)
	eq_str(strings.trim_space(r3.text), "see attached", "the text part of a mixed message")
	eq_int(len(r3.attachments), 1, "one attachment was recorded")
	eq_str(r3.attachments[0].name, "résumé.pdf", "the attachment filename")
	eq_str(r3.attachments[0].mime, "application/pdf", "the attachment type")
	eq_int(r3.attachments[0].size, 10, "the attachment's decoded size")

	// A nested multipart: alternative inside mixed.
	nested := strings.concatenate(
		{
			"Content-Type: multipart/mixed; boundary=\"O\"\r\n\r\n--O\r\n",
			"Content-Type: multipart/alternative; boundary=\"I\"\r\n\r\n--I\r\n",
			"Content-Type: text/plain\r\n\r\ndeep plain\r\n--I\r\n",
			"Content-Type: text/html\r\n\r\n<p>deep html</p>\r\n--I--\r\n\r\n--O--\r\n",
		},
		context.temp_allocator,
	)
	h4, b4 := split_message(nested)
	r4 := extract_body(h4, b4, context.temp_allocator)
	eq_str(strings.trim_space(r4.text), "deep plain", "a nested alternative is walked")

	// A base64 text part has to be decoded, not shown as base64.
	enc := strings.concatenate(
		{
			"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n",
			encode_base64(transmute([]u8)string("decoded body"), context.temp_allocator),
		},
		context.temp_allocator,
	)
	h5, b5 := split_message(enc)
	r5 := extract_body(h5, b5, context.temp_allocator)
	eq_str(strings.trim_space(r5.text), "decoded body", "a base64 text part is decoded")
}

test_html_to_text :: proc() {
	html :=
		"<html><head><style>p{color:red}</style><title>T</title></head><body>" +
		"<script>alert('no')</script>" +
		"<h1>Heading</h1><p>First para</p><p>Second &amp; third</p>" +
		"<img src=\"http://tracker.invalid/pixel.gif\" width=1>" +
		"<ul><li>one</li><li>two</li></ul>" +
		"<p>Caf&eacute; &mdash; 3&nbsp;&euro;</p>" +
		"<a href=\"http://example.invalid/x\">link text</a><br>after break" +
		"</body></html>"
	out := html_to_text(html, context.temp_allocator)

	ok(!strings.contains(out, "alert"), "script content is dropped")
	ok(!strings.contains(out, "color:red"), "style content is dropped")
	ok(!strings.contains(out, "tracker.invalid"), "an image src never reaches the text")
	ok(!strings.contains(out, "example.invalid"), "a link href never reaches the text")
	ok(!strings.contains(out, "<"), "no markup survives")
	ok(strings.contains(out, "Heading"), "heading text survives")
	ok(strings.contains(out, "First para"), "paragraph text survives")
	ok(strings.contains(out, "Second & third"), "&amp; is decoded")
	ok(strings.contains(out, "Café"), "&eacute; is decoded")
	ok(strings.contains(out, "€"), "&euro; is decoded")
	ok(strings.contains(out, "—"), "&mdash; is decoded")
	ok(strings.contains(out, "link text"), "anchor text survives")
	ok(strings.contains(out, "\n"), "block tags became line breaks")
	ok(strings.contains(out, "after break"), "<br> separates rather than swallows")
	ok(!strings.contains(out, "\n\n\n"), "runs of blank lines are collapsed")
	ok(!strings.has_prefix(out, "\n"), "the text does not start with a break")

	eq_str(html_to_text("<p>a</p>", context.temp_allocator), "a", "the simplest document")
	eq_str(html_to_text("a<!-- comment -->b", context.temp_allocator), "ab", "comments are dropped")
	eq_str(html_to_text("a   \n  b", context.temp_allocator), "a b", "whitespace collapses")
	eq_str(html_to_text("&#65;&#x42;", context.temp_allocator), "AB", "numeric entities")
	eq_str(html_to_text("5 &lt; 7 &gt; 3", context.temp_allocator), "5 < 7 > 3", "lt and gt")
	eq_str(html_to_text("", context.temp_allocator), "", "empty input")
}

test_dates :: proc() {
	t, dok := parse_rfc5322_date("Tue, 15 Apr 2025 09:12:33 +0200")
	ok(dok, "a full RFC 5322 date parses")
	y, m, d := time.date(t)
	hh, mm, ss := time.clock(t)
	eq_int(y, 2025, "year")
	eq_int(int(m), 4, "month")
	eq_int(d, 15, "day")
	eq_int(hh, 7, "the zone offset is applied (09:12 +0200 is 07:12 UTC)")
	eq_int(mm, 12, "minute")
	eq_int(ss, 33, "second")

	t2, ok2 := parse_rfc5322_date("15 Apr 2025 09:12 GMT")
	ok(ok2, "no day name and no seconds still parses")
	h2, m2, s2 := time.clock(t2)
	eq_int(h2, 9, "GMT needs no shift")
	eq_int(m2, 12, "minute without seconds")
	eq_int(s2, 0, "missing seconds default to zero")

	t3, ok3 := parse_rfc5322_date("Mon, 3 Mar 97 11:00:00 -0500")
	ok(ok3, "a two-digit year parses")
	y3, _, _ := time.date(t3)
	eq_int(y3, 1997, "a two-digit year below 50 is 20xx, above is 19xx")

	t4, ok4 := parse_rfc5322_date("Tue, 15 Apr 2025 09:12:33 -0000 (UTC)")
	ok(ok4, "a trailing zone comment is tolerated")
	h4, _, _ := time.clock(t4)
	eq_int(h4, 9, "-0000 is UTC")

	_, bad := parse_rfc5322_date("not a date at all")
	ok(!bad, "nonsense does not parse")
	_, bad2 := parse_rfc5322_date("")
	ok(!bad2, "an empty date does not parse")

	// Round-trip through the formatter the composer uses.
	formatted := format_rfc5322_date(t, context.temp_allocator)
	back, rok := parse_rfc5322_date(formatted)
	ok(rok, "format_rfc5322_date round-trips")
	eq_int(int(back._nsec / 1_000_000_000), int(t._nsec / 1_000_000_000), "the round-trip is exact to the second")
}

test_maildir_flags :: proc() {
	eq_int(card(parse_maildir_flags("1234.abc.host")), 0, "a file in new/ has no flags")
	f := parse_maildir_flags("1234.abc.host:2,FRS")
	ok(.Flagged in f, "F is Flagged")
	ok(.Answered in f, "R is Answered (replied)")
	ok(.Seen in f, "S is Seen")
	ok(.Draft not_in f, "D was not present")
	eq_int(card(f), 3, "exactly three flags")

	all := parse_maildir_flags("x:2,DFPRST")
	eq_int(card(all), 6, "every flag character is recognised")
	ok(.Deleted in all, "T is Deleted")
	ok(.Passed in all, "P is Passed")

	eq_str(
		maildir_name_with_flags("1234.abc.host", {.Seen}, context.temp_allocator),
		"1234.abc.host:2,S",
		"a new/ name gains an info suffix",
	)
	eq_str(
		maildir_name_with_flags("1234.abc.host:2,S", {.Seen, .Flagged}, context.temp_allocator),
		"1234.abc.host:2,FS",
		"flags are rewritten in ASCII order",
	)
	eq_str(
		maildir_name_with_flags("1234.abc.host:2,FRS", {}, context.temp_allocator),
		"1234.abc.host:2,",
		"clearing every flag leaves an empty suffix",
	)
	// Round-trip: whatever is written must read back identically.
	for fl in ([?]Flags{{}, {.Seen}, {.Seen, .Flagged}, {.Draft, .Seen}, {.Answered, .Flagged, .Seen}}) {
		name := maildir_name_with_flags("base.name", fl, context.temp_allocator)
		ok(parse_maildir_flags(name) == fl, "flag round-trip through the filename")
	}
}

test_subjects :: proc() {
	eq_str(base_subject("Re: Lunch?", context.temp_allocator), "lunch?", "Re: is stripped and folded")
	eq_str(base_subject("RE: re: Fwd: Lunch?", context.temp_allocator), "lunch?", "stacked prefixes are stripped")
	eq_str(base_subject("[palmy] Re: Build is red", context.temp_allocator), "build is red", "a list tag is stripped")
	eq_str(base_subject("Antw: Serverwartung", context.temp_allocator), "serverwartung", "a localised prefix is stripped")
	eq_str(base_subject("a  b   c", context.temp_allocator), "a b c", "internal whitespace is collapsed")
	eq_str(base_subject("", context.temp_allocator), "", "an empty subject stays empty")
	ok(
		base_subject("Re: Lunch?", context.temp_allocator) == base_subject("Lunch?", context.temp_allocator),
		"a reply and its parent share a base subject",
	)

	eq_str(reply_subject("Lunch?", context.temp_allocator), "Re: Lunch?", "reply_subject adds Re:")
	eq_str(reply_subject("Re: Lunch?", context.temp_allocator), "Re: Lunch?", "reply_subject never stacks Re:")
	eq_str(reply_subject("RE: Lunch?", context.temp_allocator), "RE: Lunch?", "the existing prefix's case is kept")
	eq_str(forward_subject("Lunch?", context.temp_allocator), "Fwd: Lunch?", "forward_subject adds Fwd:")
	eq_str(forward_subject("Fwd: Lunch?", context.temp_allocator), "Fwd: Lunch?", "forward_subject never stacks")
}

test_buffer :: proc() {
	b: Buffer
	buf_init(&b, "")
	defer buf_free(&b)

	eq_int(buf_line_count(&b), 1, "an empty buffer has one line")
	buf_insert(&b, "Hello")
	eq_str(buf_text(&b, context.temp_allocator), "Hello", "insert at the start")
	eq_int(b.cur.col, 5, "the cursor followed the insert")

	buf_newline(&b)
	buf_insert(&b, "World")
	eq_str(buf_text(&b, context.temp_allocator), "Hello\nWorld", "a newline splits the line")
	eq_int(buf_line_count(&b), 2, "two lines now")
	eq_int(b.cur.line, 1, "the cursor is on the second line")

	// Backspace at column zero joins the lines back.
	buf_home(&b)
	buf_backspace(&b)
	eq_str(buf_text(&b, context.temp_allocator), "HelloWorld", "backspace at column 0 joins lines")
	eq_int(buf_line_count(&b), 1, "back to one line")
	eq_int(b.cur.col, 5, "the cursor sits at the join")

	// Insert in the middle.
	buf_insert(&b, ", ")
	eq_str(buf_text(&b, context.temp_allocator), "Hello, World", "insert in the middle")

	// Multi-byte motion: one arrow press crosses one rune, not one byte.
	buf_init(&b, "héllo")
	buf_home(&b)
	buf_right(&b)
	eq_int(b.cur.col, 1, "right over 'h'")
	buf_right(&b)
	eq_int(b.cur.col, 3, "right over 'é' crosses two bytes")
	buf_left(&b)
	eq_int(b.cur.col, 1, "left back over 'é'")
	buf_end_of_line(&b)
	buf_backspace(&b)
	eq_str(buf_text(&b, context.temp_allocator), "héll", "backspace removes one rune")
	buf_home(&b)
	buf_right(&b)
	buf_delete_forward(&b)
	eq_str(buf_text(&b, context.temp_allocator), "hll", "delete removes the whole multi-byte rune")

	// Undo and redo.
	buf_init(&b, "start")
	buf_end_of_line(&b)
	buf_checkpoint(&b)
	buf_insert(&b, " more")
	eq_str(buf_text(&b, context.temp_allocator), "start more", "the edit landed")
	ok(buf_undo(&b), "undo reports success")
	eq_str(buf_text(&b, context.temp_allocator), "start", "undo restored the text")
	ok(buf_redo(&b), "redo reports success")
	eq_str(buf_text(&b, context.temp_allocator), "start more", "redo reapplied the edit")
	ok(buf_undo(&b), "undo again")
	ok(!buf_undo(&b), "undo past the start of history reports failure")
	eq_str(buf_text(&b, context.temp_allocator), "start", "the text did not move on a failed undo")

	// Kill operations.
	buf_init(&b, "one two three")
	buf_home(&b)
	for _ in 0 ..< 4 {
		buf_right(&b)
	}
	buf_kill_to_end(&b)
	eq_str(buf_text(&b, context.temp_allocator), "one ", "Ctrl-K clears to end of line")
	buf_init(&b, "one two")
	buf_end_of_line(&b)
	buf_kill_to_start(&b)
	eq_str(buf_text(&b, context.temp_allocator), "", "Ctrl-U clears to the start")

	// Word motion.
	buf_init(&b, "alpha beta gamma")
	buf_home(&b)
	buf_word_right(&b)
	eq_int(b.cur.col, 6, "word right lands on the next word")
	buf_word_right(&b)
	eq_int(b.cur.col, 11, "word right again")
	buf_word_left(&b)
	eq_int(b.cur.col, 6, "word left goes back")

	// A trailing newline is a real empty line, which a composer must keep.
	buf_init(&b, "a\n")
	eq_int(buf_line_count(&b), 2, "a trailing newline is an empty last line")
	eq_str(buf_text(&b, context.temp_allocator), "a\n", "and it round-trips")

	// Multi-line insert.
	buf_init(&b, "")
	buf_insert(&b, "l1\nl2\nl3")
	eq_int(buf_line_count(&b), 3, "a pasted multi-line string splits")
	eq_str(buf_line(&b, 1), "l2", "the middle line")
	eq_int(buf_byte_len(&b), 8, "byte length counts the newlines")
}

test_line_edit :: proc() {
	e: Line_Edit
	defer le_free(&e)

	le_set(&e, "hello")
	eq_str(le_text(&e), "hello", "le_set")
	eq_int(e.cur, 5, "le_set puts the cursor at the end")
	le_home(&e)
	le_insert(&e, ">")
	eq_str(le_text(&e), ">hello", "insert at the cursor")
	eq_int(e.cur, 1, "the cursor advanced")
	le_end(&e)
	ok(le_backspace(&e), "backspace")
	eq_str(le_text(&e), ">hell", "backspace removed one byte")

	le_set(&e, "café")
	le_end(&e)
	ok(le_backspace(&e), "backspace over a multi-byte rune")
	eq_str(le_text(&e), "caf", "the whole rune went")

	le_set(&e, "ab")
	le_home(&e)
	ok(le_delete(&e), "delete forward")
	eq_str(le_text(&e), "b", "delete removed the first byte")
	le_clear(&e)
	eq_str(le_text(&e), "", "le_clear")
	ok(!le_backspace(&e), "backspace on an empty field does nothing")
	ok(!le_delete(&e), "delete on an empty field does nothing")
}

test_reply :: proc() {
	m := Message {
		id = "parent@host.test",
		subject = "Deployment window",
		from = {name = "Ada Lovelace", email = "ada@analytical.test"},
		to = []Address{{name = "Alex", email = "alex@work.test"}, {name = "Grace", email = "grace@navy.test"}},
		cc = []Address{{name = "Ken", email = "ken@unix.test"}},
		refs = []string{"grandparent@host.test"},
		body = "The window is Thursday.\n\nAda",
	}

	to1, cc1 := reply_recipients(m, "alex@work.test", false, context.temp_allocator)
	eq_str(to1, "Ada Lovelace <ada@analytical.test>", "a reply goes to the sender")
	eq_str(cc1, "", "a plain reply has no Cc")

	to2, cc2 := reply_recipients(m, "alex@work.test", true, context.temp_allocator)
	eq_str(to2, "Ada Lovelace <ada@analytical.test>", "reply-all still goes to the sender")
	ok(strings.contains(cc2, "grace@navy.test"), "reply-all Cc keeps the other recipient")
	ok(strings.contains(cc2, "ken@unix.test"), "reply-all Cc keeps the original Cc")
	ok(!strings.contains(cc2, "alex@work.test"), "reply-all never Ccs yourself")
	ok(!strings.contains(cc2, "ada@analytical.test"), "reply-all does not duplicate the sender into Cc")

	// Reply-To wins over From when the sender asked for it.
	m2 := m
	m2.reply_to = {name = "List", email = "list@lists.test"}
	to3, _ := reply_recipients(m2, "alex@work.test", false, context.temp_allocator)
	eq_str(to3, "List <list@lists.test>", "Reply-To overrides From")

	// Wrapping, which the quote depends on.
	w1 := wrap_lines("short line", 20, context.temp_allocator)
	eq_int(len(w1), 1, "a short line is not wrapped")
	eq_str(w1[0], "short line", "and it is unchanged")

	w2 := wrap_lines("aaa bbb ccc ddd eee fff", 11, context.temp_allocator)
	ok(len(w2) >= 2, "a long line wraps (%d pieces)", len(w2))
	for piece in w2 {
		ok(rune_count(piece) <= 11, "no wrapped piece exceeds the column limit: %q", piece)
		ok(!strings.has_suffix(piece, " "), "no wrapped piece keeps a trailing space")
	}
	eq_str(strings.join(w2, " ", context.temp_allocator), "aaa bbb ccc ddd eee fff", "wrapping loses no words")

	// A line with no spaces has to be cut somewhere, and the cut must land on
	// a rune boundary rather than inside a character.
	w3 := wrap_lines("ééééééééé", 4, context.temp_allocator)
	ok(len(w3) >= 2, "an unbreakable line is still cut (%d pieces)", len(w3))
	joined := strings.concatenate(w3, context.temp_allocator)
	eq_str(joined, "ééééééééé", "and the cut loses nothing")
	for piece in w3 {
		ok(rune_count(piece) <= 4, "each piece respects the limit in runes, not bytes")
	}

	eq_int(len(wrap_lines("a\nb\nc", 10, context.temp_allocator)), 3, "existing line breaks are kept")

	// The quote.
	q := quote_body(m, 0, context.temp_allocator)
	ok(strings.has_prefix(q, "On "), "the quote opens with an attribution line")
	ok(strings.contains(q, "Ada Lovelace wrote:"), "the attribution names the sender")
	ok(strings.contains(q, "> The window is Thursday."), "every body line is prefixed")
	ok(strings.contains(q, "\n>\n"), "a blank line becomes a bare >")

	// The whole composer path: the headers a reply must carry.
	st := new(State)
	defer free(st)
	append(&st.accounts, Account{name = "Work", address = "alex@work.test", root = "/tmp/none", loopback = true})
	append(&st.folders, Folder{account = 0, name = "Inbox", display = "Inbox", role = .Inbox})
	append(&st.messages, m)
	st.messages[0].folder = 0
	st.messages[0].thread = -1
	append(&st.threads, Thread{msgs = make([dynamic]int)})
	append(&st.threads[0].msgs, 0)
	st.messages[0].thread = 0

	compose_reply(st, 0, true)
	eq_str(le_text(&st.comp.subject), "Re: Deployment window", "the reply subject")
	eq_str(st.comp.in_reply_to, "parent@host.test", "In-Reply-To is the parent's Message-ID")
	ok(
		strings.contains(st.comp.references, "<grandparent@host.test>") &&
		strings.contains(st.comp.references, "<parent@host.test>"),
		"References is the parent's chain with the parent appended",
	)
	ok(.Answered in st.messages[0].flags, "replying marks the parent answered")
	ok(buf_line_count(&st.comp.body) > 3, "the quoted parent is in the body")

	rendered := build_message(st, context.temp_allocator)
	head, _ := split_message(rendered)
	hs := parse_headers(head, context.temp_allocator)
	eq_str(header_of(hs, "in-reply-to"), "<parent@host.test>", "the rendered In-Reply-To header")
	eq_str(header_of(hs, "subject"), "Re: Deployment window", "the rendered Subject header")
	ok(header_of(hs, "message-id") != "", "a Message-ID was generated")
	ok(header_of(hs, "date") != "", "a Date header was written")
	ok(
		strings.contains(header_of(hs, "x-palmy-mail"), "never-transmitted"),
		"the queued marker is on the message",
	)
	ok(strings.contains(header_of(hs, "to"), "ada@analytical.test"), "the rendered To header")

	// A non-ASCII subject has to be encoded, not written raw.
	le_set(&st.comp.subject, "Résumé")
	enc := build_message(st, context.temp_allocator)
	h2, _ := split_message(enc)
	subj := header_of(parse_headers(h2, context.temp_allocator), "subject")
	ok(strings.has_prefix(subj, "=?utf-8?B?"), "a non-ASCII subject is RFC 2047 encoded")
	eq_str(decode_encoded_words(subj, context.temp_allocator), "Résumé", "and it decodes back")
}

test_body_clipping :: proc() {
	short := "one\ntwo\nthree\n"
	shown, dropped, clipped := clip_body(short)
	ok(!clipped, "a short body is not clipped")
	eq_str(shown, short, "and is returned unchanged")
	eq_int(dropped, 0, "with nothing dropped")

	// A body longer than the reader's line budget. Every line is an element,
	// so this bound is the difference between a frame and a freeze.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< READER_MAX_LINES + 500 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	long := strings.to_string(b)
	shown2, dropped2, clipped2 := clip_body(long)
	ok(clipped2, "a very long body is clipped")
	ok(len(shown2) < len(long), "and what is shown is shorter than what arrived")
	// The body ends in a newline, so there is no trailing partial line: the
	// 500 lines past the budget are exactly what is dropped.
	eq_int(dropped2, 500, "the dropped-line count is reported")
	ok(strings.has_suffix(shown2, "\n"), "the cut lands on a line boundary")
	ok(strings.has_prefix(shown2, "line 0\n"), "the start of the message is what is kept")
	n := strings.count(shown2, "\n")
	ok(n <= READER_MAX_LINES, "no more than the line budget is laid out (%d)", n)

	// One enormous line is bounded by bytes rather than by lines.
	huge := strings.repeat("x", READER_MAX_BYTES * 2, context.temp_allocator)
	shown3, _, clipped3 := clip_body(huge)
	ok(!clipped3, "a single line with no breaks cannot be cut on one")
	eq_int(len(shown3), len(huge), "so it is returned whole, which costs one element, not a million")
}

test_protocol_rules :: proc() {
	ok(has_server_folders(.IMAP), "IMAP has a folder tree")
	ok(has_server_folders(.JMAP), "JMAP has a folder tree")
	ok(!has_server_folders(.POP3), "POP3 has no folders beyond the inbox")
	ok(has_server_flags(.IMAP), "IMAP has server-side flags")
	ok(has_server_flags(.JMAP), "JMAP has server-side flags")
	ok(!has_server_flags(.POP3), "POP3 has no server-side flags")

	eq_str(protocol_name(.IMAP), "IMAP", "protocol name, IMAP")
	eq_str(protocol_name(.JMAP), "JMAP", "protocol name, JMAP")
	eq_str(protocol_name(.POP3), "POP3", "protocol name, POP3")

	// The host allow-list. This is the safety boundary, so it is asserted.
	ok(is_loopback("127.0.0.1"), "127.0.0.1 is loopback")
	ok(is_loopback("localhost"), "localhost is loopback")
	ok(is_loopback("::1"), "::1 is loopback")
	ok(is_loopback(""), "an unset host is treated as loopback")
	ok(!is_loopback("imap.gmail.com"), "a real provider is refused")
	ok(!is_loopback("outlook.office365.com"), "another real provider is refused")
	ok(!is_loopback("192.168.1.10"), "a LAN address is not loopback")

	// Folder roles.
	eq_int(int(role_of_name("Inbox")), int(Folder_Role.Inbox), "Inbox role")
	eq_int(int(role_of_name("Sent Items")), int(Folder_Role.Sent), "Sent role")
	eq_int(int(role_of_name("Archive/2024")), int(Folder_Role.Archive), "a nested folder keeps its parent's role")
	eq_int(int(role_of_name("Archive")), int(Folder_Role.Archive), "the archive itself")
	eq_int(int(role_of_name("Projects/Palmy")), int(Folder_Role.Other), "an ordinary folder")
	ok(role_order(.Inbox) < role_order(.Sent), "the inbox sorts first")
	ok(role_order(.Trash) < role_order(.Other), "trash sorts before ordinary folders")

	// A non-loopback host in the config is loaded, flagged, and never used.
	st := new(State)
	defer free(st)
	st.data_dir = "/tmp/palmy-mail-selftest-nonexistent"
	parse_config(
		st,
		"[account]\nname = Bad\nprotocol = imap\nhost = imap.gmail.com\npath = bad\n",
	)
	eq_int(len(st.accounts), 1, "the account was loaded")
	ok(!st.accounts[0].loopback, "and marked as not loopback")
	ok(st.warn != "", "and a warning was raised")

	// A relative path stays inside the data directory.
	st2 := new(State)
	defer free(st2)
	st2.data_dir = "/tmp/palmy-data"
	parse_config(st2, "[account]\nname = Rel\nprotocol = pop3\nhost = 127.0.0.1\npath = inner\n")
	eq_str(st2.accounts[0].root, "/tmp/palmy-data/inner", "a relative path is resolved under the data dir")
	eq_int(int(st2.accounts[0].protocol), int(Protocol.POP3), "the protocol was read")
}

// ---------------------------------------------------------------------------
// The fixtures, end to end: generate, scan, thread, search, flag, send.
// ---------------------------------------------------------------------------

test_fixtures_and_threading :: proc() {
	dir := fmt.tprintf("%s/selftest", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)

	accounts, folders, messages := write_fixtures(dir)
	eq_int(accounts, 3, "three fixture accounts were written")
	ok(messages > 300, "the fixtures hold more than 300 messages (got %d)", messages)
	ok(folders >= 12, "the fixtures hold at least twelve folders (got %d)", folders)

	st := new(State)
	defer free(st)
	st.data_dir = dir
	st.reader_msg = -1
	st.now = time.now()
	load_config(st)
	eq_int(len(st.accounts), 3, "the written config declares three accounts")
	for a in st.accounts {
		ok(a.loopback, "every fixture account is loopback: %s", a.host)
	}

	scan_accounts(st)
	rebuild_sidebar(st)
	ok(len(st.messages) == messages, "every written message was read back (%d of %d)", len(st.messages), messages)
	ok(len(st.folders) >= 12, "the folder tree was discovered (%d)", len(st.folders))

	// Protocol shapes. The POP3 account must have exactly one folder.
	by_proto := [Protocol]int{}
	pop_folders := 0
	imap_folders := 0
	for a, ai in st.accounts {
		by_proto[a.protocol] += 1
		n := 0
		for f in st.folders {
			if f.account == ai {
				n += 1
			}
		}
		switch a.protocol {
		case .POP3:
			pop_folders = n
		case .IMAP:
			imap_folders = n
		case .JMAP:
			ok(n >= 6, "the JMAP account has a folder tree (%d)", n)
		}
	}
	eq_int(by_proto[.IMAP], 1, "one IMAP account")
	eq_int(by_proto[.JMAP], 1, "one JMAP account")
	eq_int(by_proto[.POP3], 1, "one POP3 account")
	eq_int(pop_folders, 1, "the POP3 account has exactly one folder, its inbox")
	ok(imap_folders >= 7, "the IMAP account has a full folder tree (%d)", imap_folders)
	for f in st.folders {
		if !has_server_folders(st.accounts[f.account].protocol) {
			eq_int(int(f.role), int(Folder_Role.Inbox), "a POP3 account's only folder is the inbox")
		}
	}

	// Nesting: the fixtures write Archive/2024 and Archive/Travel.
	nested := 0
	for f in st.folders {
		if f.depth > 0 {
			nested += 1
		}
	}
	ok(nested >= 2, "nested folders were discovered (%d)", nested)

	// Unread counts: new/ and cur/ both populated, and the two disagree.
	in_new, unread := 0, 0
	for m in st.messages {
		if m.in_new {
			in_new += 1
		}
		if msg_unread(m) {
			unread += 1
		}
	}
	ok(in_new > 0, "some messages live in new/ (%d)", in_new)
	ok(unread > in_new, "flagged-but-unread messages in cur/ are unread too (%d unread)", unread)
	ok(unread < len(st.messages), "not everything is unread")

	flagged, with_attach, html_only, no_subject := 0, 0, 0, 0
	for m in st.messages {
		if .Flagged in m.flags {
			flagged += 1
		}
		if len(m.attachments) > 0 {
			with_attach += 1
		}
		if m.from_html {
			html_only += 1
		}
		if m.subject == "(no subject)" {
			no_subject += 1
		}
	}
	ok(flagged > 0, "the fixtures include flagged messages (%d)", flagged)
	ok(with_attach > 0, "the fixtures include attachments (%d)", with_attach)
	eq_int(html_only, 6, "two HTML-only messages per account needed the text fallback")
	eq_int(no_subject, 3, "one subject-less message per account")

	// Unicode survived the round trip through the filesystem and the parser.
	found_cjk, found_cyrillic, found_accent := false, false, false
	for m in st.messages {
		if strings.contains(m.from.name, "李") {
			found_cjk = true
		}
		if strings.contains(m.from.name, "Иван") {
			found_cyrillic = true
		}
		if strings.contains(m.from.name, "Péron") {
			found_accent = true
		}
	}
	ok(found_cjk, "a CJK display name round-tripped")
	ok(found_cyrillic, "a Cyrillic display name round-tripped")
	ok(found_accent, "an accented display name round-tripped")

	// Threading.
	inbox := 0
	for f, i in st.folders {
		if f.role == .Inbox && f.account == 0 {
			inbox = i
			break
		}
	}
	select_folder(st, inbox)
	ok(len(st.threads) > 0, "the inbox threaded into conversations (%d)", len(st.threads))
	ok(len(st.threads) < len(st.messages), "threading actually grouped messages")

	deep, max_depth, total_in_threads := 0, 0, 0
	for t in st.threads {
		total_in_threads += len(t.msgs)
		if len(t.msgs) >= 3 {
			deep += 1
		}
		for mi in t.msgs {
			max_depth = max(max_depth, st.messages[mi].depth)
		}
	}
	ok(deep > 0, "some conversations are three or more deep (%d)", deep)
	ok(max_depth >= 3, "the reply tree nests at least three levels (%d)", max_depth)

	// Every message in the folder is in exactly one thread, and no message is
	// lost — the property that matters most about a threading pass.
	in_folder := 0
	for m in st.messages {
		if m.folder == inbox {
			in_folder += 1
		}
	}
	eq_int(total_in_threads, in_folder, "threading neither drops nor duplicates a message")

	// Parents come before children, and a thread is date-ordered at the root.
	order_ok := true
	for t in st.threads {
		seen := make(map[int]bool, len(t.msgs), context.temp_allocator)
		for mi in t.msgs {
			m := st.messages[mi]
			if m.depth > 0 && m.in_reply_to != "" {
				// The parent, if it is in this thread, must already be listed.
				for other in t.msgs {
					if st.messages[other].id == m.in_reply_to && !seen[other] {
						order_ok = false
					}
				}
			}
			seen[mi] = true
		}
	}
	ok(order_ok, "a parent is always listed before its children")

	// The subject fallback: an orphaned reply with no In-Reply-To and no
	// References still lands in its parent's conversation, and nothing else
	// gets swept in with it.
	orphan, parent_msg := -1, -1
	for m, i in st.messages {
		if m.account != 0 {
			continue
		}
		if m.subject == "Re: The polonium order never arrived" {
			orphan = i
		}
		if m.subject == "The polonium order never arrived" {
			parent_msg = i
		}
	}
	ok(orphan >= 0 && parent_msg >= 0, "the orphaned-reply fixture is present")
	if orphan >= 0 && parent_msg >= 0 {
		eq_int(len(st.messages[orphan].refs), 0, "the orphan really has no References")
		eq_str(st.messages[orphan].in_reply_to, "", "and no In-Reply-To")
		eq_int(
			st.messages[orphan].thread,
			st.messages[parent_msg].thread,
			"the subject fallback put the orphan in its parent's conversation",
		)
		ti := st.messages[orphan].thread
		ok(ti >= 0 && ti < len(st.threads), "the conversation exists")
		if ti >= 0 && ti < len(st.threads) {
			eq_int(len(st.threads[ti].msgs), 2, "and swept nothing else in with it")
		}
	}

	// Threads with full References are never merged on subject alone, which is
	// what keeps a busy folder from collapsing into a handful of giants.
	biggest := 0
	for t in st.threads {
		biggest = max(biggest, len(t.msgs))
	}
	ok(biggest <= 8, "no conversation has run away on the subject fallback (largest is %d)", biggest)
	ok(
		len(st.threads) > 50,
		"the inbox threads into many conversations rather than a few giants (%d)",
		len(st.threads),
	)

	// A conversation never spans two accounts: two mailboxes are two
	// conversations even when the subject or the Message-ID is the same.
	le_set(&st.query, "digest")
	run_search(st)
	ok(search_hit_count(st) >= 3, "the per-account digest messages are all found")
	for t in st.threads {
		acct := -1
		for mi in t.msgs {
			if acct < 0 {
				acct = st.messages[mi].account
			}
			eq_int(st.messages[mi].account, acct, "every message in a conversation is in one account")
		}
	}
	le_clear(&st.query)
	run_search(st)
	select_folder(st, inbox)

	// Threads are newest-first, which is what a mail list is.
	sorted := true
	for i in 1 ..< len(st.threads) {
		if st.threads[i - 1].newest._nsec < st.threads[i].newest._nsec {
			sorted = false
		}
	}
	ok(sorted, "the thread list is newest-first")

	// Rows: a collapsed thread is one row; expanded, it is one plus its
	// messages.
	rows_before := len(st.rows)
	eq_int(rows_before, len(st.threads), "a collapsed list is one row per conversation")
	big := -1
	for t, ti in st.threads {
		if len(t.msgs) >= 3 {
			big = ti
			break
		}
	}
	ok(big >= 0, "found a conversation to expand")
	if big >= 0 {
		st.threads[big].expanded = true
		rebuild_rows(st)
		eq_int(
			len(st.rows),
			rows_before + len(st.threads[big].msgs),
			"expanding a conversation adds one row per message",
		)
		st.threads[big].expanded = false
		rebuild_rows(st)
		eq_int(len(st.rows), rows_before, "collapsing it again removes them")
	}

	// Search.
	le_set(&st.query, "zzzzznotpresentanywhere")
	run_search(st)
	eq_int(search_hit_count(st), 0, "a query that matches nothing finds nothing")

	le_set(&st.query, "deployment")
	run_search(st)
	hits := search_hit_count(st)
	ok(hits > 0, "a body/subject search finds messages (%d)", hits)
	ok(st.searching, "the list is in search mode")

	le_set(&st.query, "is:unread")
	run_search(st)
	unread_hits := search_hit_count(st)
	eq_int(unread_hits, unread, "is:unread finds exactly the unread messages")

	le_set(&st.query, "has:attachment")
	run_search(st)
	eq_int(search_hit_count(st), with_attach, "has:attachment finds exactly the messages with one")

	le_set(&st.query, "from:ada")
	run_search(st)
	from_hits := search_hit_count(st)
	ok(from_hits > 0, "from: narrows to a sender (%d)", from_hits)
	for t in st.threads {
		for mi in t.msgs {
			ok(
				contains_fold(st.messages[mi].from.name, "ada") ||
				contains_fold(st.messages[mi].from.email, "ada"),
				"every from: hit really is from that sender",
			)
			break
		}
		break
	}

	// Two terms narrow rather than widen.
	le_set(&st.query, "is:unread has:attachment")
	run_search(st)
	both := search_hit_count(st)
	ok(both <= unread_hits && both <= with_attach, "two terms intersect (%d)", both)

	le_clear(&st.query)
	run_search(st)
	ok(!st.searching, "clearing the query leaves search mode")

	// Flags. An IMAP account renames the file on disk; a POP3 account must not.
	select_folder(st, inbox)
	victim := -1
	for m, i in st.messages {
		if m.folder == inbox && msg_unread(m) {
			victim = i
			break
		}
	}
	ok(victim >= 0, "found an unread message to mark")
	if victim >= 0 {
		old_path := strings.clone(st.messages[victim].path, context.temp_allocator)
		folder_unread := st.folders[inbox].unread
		set_flags(st, victim, st.messages[victim].flags | {.Seen})
		ok(!msg_unread(st.messages[victim]), "the message is now read")
		eq_int(st.folders[inbox].unread, folder_unread - 1, "the folder's unread count dropped by one")
		ok(st.messages[victim].path != old_path, "an IMAP account renamed the Maildir file")
		ok(!os.exists(old_path), "the old filename is gone")
		ok(os.exists(st.messages[victim].path), "the new filename is on disk")
		ok(
			strings.contains(st.messages[victim].file, ":2,S"),
			"the new filename carries the S flag: %s",
			st.messages[victim].file,
		)
		ok(strings.contains(st.messages[victim].path, "/cur/"), "and it moved out of new/")
	}

	// POP3: the same operation must leave the file alone and write a sidecar.
	pop_account := -1
	for a, ai in st.accounts {
		if a.protocol == .POP3 {
			pop_account = ai
		}
	}
	ok(pop_account >= 0, "found the POP3 account")
	pop_victim := -1
	for m, i in st.messages {
		if m.account == pop_account && msg_unread(m) {
			pop_victim = i
			break
		}
	}
	ok(pop_victim >= 0, "found an unread POP3 message")
	if pop_victim >= 0 {
		before := strings.clone(st.messages[pop_victim].path, context.temp_allocator)
		set_flags(st, pop_victim, st.messages[pop_victim].flags | {.Seen})
		eq_str(st.messages[pop_victim].path, before, "a POP3 account does not rename the file")
		ok(os.exists(before), "the POP3 message is still where it was")
		ok(
			os.exists(local_flags_path(st, pop_account, context.temp_allocator)),
			"a local flag sidecar was written for the POP3 account",
		)
		// And it has to survive a rescan, since the server cannot remember it.
		id := strings.clone(st.messages[pop_victim].id, context.temp_allocator)
		scan_accounts(st)
		found := false
		for m in st.messages {
			if m.account == pop_account && m.id == id {
				ok(!msg_unread(m), "the POP3 read state survived a rescan")
				found = true
			}
		}
		ok(found, "the POP3 message was found again after the rescan")
	}

	// Send. The one destructive-looking action: it must write exactly one file,
	// into the account's own Outbox, and nowhere else.
	rebuild_sidebar(st)
	st.comp.account = 0
	compose_reset(&st.comp)
	le_set(&st.comp.to, "ada@analytical.test")
	le_set(&st.comp.subject, "Composed by the self-test")
	buf_init(&st.comp.body, "Typed in the composer.\nSecond line.")

	outbox := send_destination(st, 0, context.temp_allocator)
	ok(
		strings.has_prefix(outbox, st.accounts[0].root),
		"the send destination is inside the account root: %s",
		outbox,
	)
	ok(strings.has_prefix(outbox, dir), "which is inside the data directory")
	ok(strings.has_suffix(outbox, "/.Outbox"), "and it is the Outbox")

	path, sent := compose_send(st)
	ok(sent, "the message was queued")
	ok(os.exists(path), "the queued file is on disk: %s", path)
	ok(strings.has_prefix(path, outbox), "and it is inside the Outbox")
	ok(strings.contains(path, "/new/"), "a queued message is delivered into new/")
	raw, rok := read_file(path, context.temp_allocator)
	ok(rok, "the queued file reads back")
	if rok {
		h, b := split_message(string(raw))
		qhs := parse_headers(h, context.temp_allocator)
		eq_str(header_of(qhs, "subject"), "Composed by the self-test", "the queued Subject")
		eq_str(header_of(qhs, "to"), "ada@analytical.test", "the queued To")
		ok(strings.contains(b, "Typed in the composer."), "the queued body")
		ok(strings.contains(b, "Second line."), "the queued body's second line")
		ok(
			strings.contains(header_of(qhs, "x-palmy-mail"), "never-transmitted"),
			"the queued message is marked as never transmitted",
		)
		// And the Outbox is now a folder the app can read like any other.
		scan_accounts(st)
		outbox_folder := -1
		for f, i in st.folders {
			if f.role == .Outbox && f.account == 0 {
				outbox_folder = i
			}
		}
		ok(outbox_folder >= 0, "the Outbox appears as a folder after a rescan")
		if outbox_folder >= 0 {
			eq_int(st.folders[outbox_folder].total, 1, "with exactly the one queued message in it")
		}
	}

	// Interop with the engine: a Maildir in the data directory that no account
	// names is discovered and shown, and regenerating the fixtures does not
	// delete someone else's account from the config.
	{
		engine_dir := fmt.tprintf("%s/engine-imap", dir)
		maildir_make(engine_dir)
		maildir_make(fmt.tprintf("%s/.Sent", engine_dir))
		st2 := new(State)
		defer free(st2)
		st2.data_dir = dir
		load_config(st2)
		before := len(st2.accounts)
		discover_accounts(st2)
		eq_int(len(st2.accounts), before + 1, "the engine's Maildir was discovered")
		found := false
		for a in st2.accounts {
			if a.name == "engine-imap" {
				found = true
				ok(a.discovered, "and is marked as discovered rather than configured")
				ok(a.loopback, "and is never treated as remote")
			}
		}
		ok(found, "the discovered account is named after its directory")
		// Discovery is idempotent.
		discover_accounts(st2)
		eq_int(len(st2.accounts), before + 1, "running discovery twice adds nothing")

		// A hand-written account block survives a fixture regeneration.
		conf := config_path(dir, context.temp_allocator)
		existing, _ := read_file(conf, context.temp_allocator)
		keep := fmt.tprintf("%s\n[account]\nname = Engine\nprotocol = imap\nhost = 127.0.0.1\npath = engine-imap\n", string(existing))
		write_file(conf, transmute([]u8)keep)
		write_fixtures(dir)
		after, _ := read_file(conf, context.temp_allocator)
		ok(
			strings.contains(string(after), "name = Engine"),
			"regenerating the fixtures kept the foreign account block",
		)
		ok(
			strings.contains(string(after), "name = Work"),
			"and still wrote the fixture accounts",
		)
	}

	// An empty recipient list must be refused rather than written.
	le_clear(&st.comp.to)
	_, refused := compose_send(st)
	ok(!refused, "a message with no recipient is not queued")

	// A sender with no To is also the last thing we do, so clean up.
	remove_tree(dir)
	ok(!os.is_dir(dir), "the self-test's fixture tree was removed")
}
