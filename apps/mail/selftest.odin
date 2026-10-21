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
	test_preview_rule()
	test_html_to_text()
	test_dates()
	test_maildir_flags()
	test_subjects()
	test_buffer()
	test_line_edit()
	test_reply()
	test_body_clipping()
	test_protocol_rules()
	test_attachment_bytes()
	test_attachment_saving()
	test_filing()
	test_drafts()
	test_multiselect()
	test_autocomplete()
	test_palmy()
	test_fixtures_and_threading()
	test_cli()

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

	rendered := build_message(st, false, context.temp_allocator)
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
	enc := build_message(st, false, context.temp_allocator)
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
// Attachments: bytes by section number, and the names that address them
// ---------------------------------------------------------------------------

// payload_message builds a multipart/related message carrying `payload` as a
// base64 attachment whose filename is hostile, plus an inline PNG the HTML
// part references with a `cid:` URL, plus an unnamed PDF part.
payload_message :: proc(payload: []u8, filename: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate(
		{
			"From: Robot <robot@localhost>\r\n",
			"To: alex@work.test\r\n",
			"Subject: a payload and a logo\r\n",
			"Message-ID: <payload@selftest>\r\n",
			"Date: Tue, 3 Feb 2026 12:00:00 +0000\r\n",
			"MIME-Version: 1.0\r\n",
			"Content-Type: multipart/related; boundary=\"REL\"\r\n",
			"\r\n--REL\r\n",
			"Content-Type: multipart/alternative; boundary=\"ALT\"\r\n",
			"\r\n--ALT\r\n",
			"Content-Type: text/plain; charset=utf-8\r\n",
			"\r\nsee the attachment\r\n",
			"--ALT\r\n",
			"Content-Type: text/html; charset=utf-8\r\n",
			"\r\n<p>see <img src=\"cid:logo@selftest\"> the attachment</p>\r\n",
			"--ALT--\r\n",
			"\r\n--REL\r\n",
			"Content-Type: image/png\r\n",
			"Content-ID: <logo@selftest>\r\n",
			"Content-Disposition: inline; filename=\"logo.png\"\r\n",
			"Content-Transfer-Encoding: base64\r\n",
			"\r\niVBORw0KGgo=\r\n",
			"--REL\r\n",
			"Content-Type: application/octet-stream\r\n",
			fmt.tprintf("Content-Disposition: attachment; filename=\"%s\"\r\n", filename),
			"Content-Transfer-Encoding: base64\r\n",
			"\r\n",
			encode_base64(payload, context.temp_allocator),
			"\r\n--REL\r\n",
			"Content-Type: application/pdf\r\n",
			"Content-Disposition: attachment\r\n",
			"Content-Transfer-Encoding: base64\r\n",
			"\r\nJVBERi0=\r\n",
			"--REL--\r\n",
		},
		allocator,
	)
}

bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

test_attachment_bytes :: proc() {
	// --- the names ---------------------------------------------------------
	eq_str(sanitise_filename("../../.bashrc", context.temp_allocator), ".bashrc", "../../.bashrc loses every directory component")
	eq_str(sanitise_filename("/etc/passwd", context.temp_allocator), "passwd", "an absolute path loses its directories")
	eq_str(sanitise_filename("..\\..\\boot.ini", context.temp_allocator), "boot.ini", "a Windows path loses its backslashes")
	eq_str(sanitise_filename("..", context.temp_allocator), "", "a bare .. is not a file name")
	eq_str(sanitise_filename(".", context.temp_allocator), "", "nor is a bare .")
	eq_str(sanitise_filename("ev\x01il.png", context.temp_allocator), "evil.png", "a control character is dropped")
	eq_str(sanitise_filename("résumé.pdf", context.temp_allocator), "résumé.pdf", "a non-ASCII name survives intact")
	eq_str(sanitise_filename("", context.temp_allocator), "", "an empty name stays empty")

	// --- the containment check --------------------------------------------
	ok(path_within("/tmp/x", "/tmp/x/a.png"), "a plain name inside the directory is within it")
	ok(path_within("/tmp/x/", "/tmp/x/a.png"), "a trailing slash on the directory does not matter")
	ok(!path_within("/tmp/x", "/tmp/y/a.png"), "a sibling directory is not within")
	ok(!path_within("/tmp/x", "/tmp/xy/a.png"), "a prefix that is not a path component is not within")
	ok(!path_within("/tmp/x", "/tmp/x/sub/a.png"), "a nested path is not within")
	ok(!path_within("/tmp/x", "/tmp/x/../a.png"), "traversal out of the directory is not within")
	ok(!path_within("/tmp/x", "/tmp/x"), "the directory itself is not a file within it")
	ok(!path_within("/tmp/x", "a.png"), "a relative path is not within an absolute directory")
	ok(path_within("/", "/a.png"), "a file at the root is within the root")

	// --- extensions, for the parts that arrive with no name ---------------
	eq_str(mime_extension("image/png"), ".png", "image/png is .png")
	eq_str(mime_extension("APPLICATION/PDF"), ".pdf", "the case does not matter")
	eq_str(mime_extension("application/x-nonsense"), ".bin", "a type nobody knows is .bin")

	// --- section numbering and bytes --------------------------------------
	payload := fixture_payload()
	eq_int(len(payload), 262, "the payload is 262 bytes")
	eq_int(int(payload[0]), 0, "...starting with a NUL")
	ok(
		payload[256] == '\r' && payload[257] == '\n' && payload[258] == '\r' && payload[259] == '\n',
		"...and ending with a CRLF run",
	)

	raw := payload_message(payload, "../../.bashrc")
	head, body := split_message(raw)
	res := extract_body(head, body, context.temp_allocator)

	eq_str(strings.trim_space(res.text), "see the attachment", "the plain alternative is the readable body")
	ok(!res.from_html, "which means the HTML fallback did not run")
	eq_int(len(res.attachments), 3, "three non-body parts were recorded")

	// The section numbers have to match what part_bytes will be asked for.
	// multipart/related's children are the nested alternative (1), the png
	// (2), the payload (3) and the pdf (4) — which is what IMAP would call
	// them, and what part_bytes is about to be asked for.
	eq_str(res.attachments[0].section, "2", "the inline png is section 2")
	eq_str(res.attachments[1].section, "3", "the payload is section 3")
	eq_str(res.attachments[2].section, "4", "the unnamed pdf is section 4")

	eq_str(res.attachments[0].name, "logo.png", "the inline png keeps its name")
	eq_str(res.attachments[1].name, ".bashrc", "the hostile filename was sanitised at parse time")
	eq_str(res.attachments[2].name, "part-4.pdf", "an unnamed part is named after its section and type")

	ok(res.attachments[0].is_inline, "the png is inline: the HTML refers to it by cid")
	ok(!res.attachments[1].is_inline, "the payload is not inline")
	ok(!res.attachments[2].is_inline, "nor is the unnamed pdf")

	eq_int(res.attachments[1].size, 262, "the payload's decoded size was recorded")

	// Bytes by section, which is the API the save path is built on.
	b3, ok3 := part_bytes(raw, "3", context.temp_allocator)
	ok(ok3, "part_bytes found section 3")
	eq_int(len(b3), 262, "and decoded it to 262 bytes")
	ok(bytes_equal(b3, payload), "BYTE-EXACT: section 3's bytes are the payload we encoded")

	b2, ok2 := part_bytes(raw, "2", context.temp_allocator)
	ok(ok2 && len(b2) == 8 && b2[0] == 0x89, "section 2 is the png, base64-decoded")
	b11, ok11 := part_bytes(raw, "1.1", context.temp_allocator)
	ok(ok11 && strings.contains(string(b11), "see the attachment"), "section 1.1 is the plain alternative")
	b12, ok12 := part_bytes(raw, "1.2", context.temp_allocator)
	ok(ok12 && strings.contains(string(b12), "cid:logo@selftest"), "section 1.2 is the html alternative")

	_, okroot := part_bytes(raw, "", context.temp_allocator)
	ok(!okroot, "the root is a multipart, so it has no bytes of its own")
	_, ok1 := part_bytes(raw, "1", context.temp_allocator)
	ok(!ok1, "nor does the nested multipart at section 1")
	_, okmiss := part_bytes(raw, "9", context.temp_allocator)
	ok(!okmiss, "a section that does not exist is a miss, not a crash")
	_, okdeep := part_bytes(raw, "3.1.1", context.temp_allocator)
	ok(!okdeep, "descending into a part that is not a multipart is a miss")
	_, okjunk := part_bytes(raw, "x", context.temp_allocator)
	ok(!okjunk, "a section that is not a number is a miss")

	// A single-part message: the root *is* the attachment, section "".
	single := strings.concatenate(
		{
			"Subject: one part\r\nMIME-Version: 1.0\r\n",
			"Content-Type: application/octet-stream\r\n",
			"Content-Disposition: attachment; filename=\"blob.bin\"\r\n",
			"Content-Transfer-Encoding: base64\r\n\r\n",
			encode_base64(payload, context.temp_allocator),
			"\r\n",
		},
		context.temp_allocator,
	)
	sh, sb := split_message(single)
	sres := extract_body(sh, sb, context.temp_allocator)
	eq_int(len(sres.attachments), 1, "a single-part attachment message has one attachment")
	eq_str(sres.attachments[0].section, "", "whose section is the root")
	sbytes, sok := part_bytes(single, "", context.temp_allocator)
	ok(sok && bytes_equal(sbytes, payload), "and the root's bytes are the payload")
}

// ---------------------------------------------------------------------------
// Saving an attachment: through the model, onto the disk, byte for byte
// ---------------------------------------------------------------------------

test_attachment_saving :: proc() {
	dir := fmt.tprintf("%s/selftest-save", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	// A Maildir with exactly one message in it, carrying the payload.
	root := fmt.tprintf("%s/acct", dir)
	maildir_make(root)
	payload := fixture_payload()
	msg_name := "1770000000.M1P1.selftest:2,S"
	msg_path := fmt.tprintf("%s/cur/%s", root, msg_name)
	ok(
		write_file(msg_path, transmute([]u8)payload_message(payload, "../../.bashrc")),
		"the fixture message was written",
	)

	m, mok := read_message(msg_path, msg_name, false, 0, 0)
	ok(mok, "the fixture message parsed")
	if !mok {
		return
	}
	eq_int(len(m.attachments), 3, "it carries three non-body parts")

	saveable := saveable_attachments(m)
	eq_int(len(saveable), 2, "two of them are offered to save")
	eq_int(inline_attachment_count(m), 1, "and one is inline")
	eq_str(m.attachments[saveable[0]].name, ".bashrc", "the first saveable one is the sanitised payload")

	// The decoded bytes come back out of the file on disk, not out of memory.
	data, dok := attachment_bytes(m, m.attachments[saveable[0]], context.temp_allocator)
	ok(dok, "attachment_bytes read the part back off disk")
	eq_int(len(data), 262, "with the payload's length")
	ok(bytes_equal(data, payload), "BYTE-EXACT: the bytes out of the mailbox equal the bytes we encoded")

	// --- the save -----------------------------------------------------------
	out := fmt.tprintf("%s/downloads", dir)
	os.make_directory_all(out)

	saved, serr := save_attachment_to(m, m.attachments[saveable[0]], out, m.attachments[saveable[0]].name)
	ok(serr == "", "the attachment was saved: %s", serr)
	eq_str(saved, fmt.tprintf("%s/.bashrc", out), "directly inside the directory that was chosen")
	ok(path_within(out, saved), "and the path is within it")
	ok(os.exists(saved), "the file is on disk")

	back, bok := read_file(saved, context.temp_allocator)
	ok(bok, "the saved file reads back")
	eq_int(len(back), 262, "with exactly 262 bytes")
	ok(bytes_equal(back, payload), "BYTE-EXACT: the file on disk equals the original payload")
	ok(len(back) > 0 && back[0] == 0, "the leading NUL survived")
	ok(
		len(back) == 262 && back[256] == '\r' && back[257] == '\n' && back[258] == '\r' && back[259] == '\n',
		"the CRLF run survived unnormalised",
	)
	ok(len(back) == 262 && back[255] == 0xff && back[261] == 0xff, "and the high bytes survived")

	// --- and nothing escaped ------------------------------------------------
	// The filename asked to be written two directories up. It was not.
	ok(!os.exists(fmt.tprintf("%s/.bashrc", dir)), "nothing was written one directory above the chosen one")
	ok(!os.exists(fmt.tprintf("%s/../.bashrc", dir)), "nor two directories above it")

	// Even handed the hostile string directly, the destination stays inside.
	dest, derr := attachment_dest(out, "../../.bashrc", context.temp_allocator)
	eq_str(dest, fmt.tprintf("%s/.bashrc", out), "a hostile name resolves inside the chosen directory")
	eq_str(derr, "", "with no error")
	_, derr2 := attachment_dest(out, "..", context.temp_allocator)
	ok(derr2 != "", "a name that sanitises to nothing is refused")
	_, derr3 := attachment_dest(out, "", context.temp_allocator)
	ok(derr3 != "", "an empty name is refused")
	_, derr4 := save_attachment_to(m, m.attachments[saveable[0]], fmt.tprintf("%s/nope", dir), "x.bin")
	ok(derr4 != "", "saving into a directory that does not exist is refused")

	// The unnamed part lands under its generated name.
	saved2, serr2 := save_attachment_to(m, m.attachments[saveable[1]], out, m.attachments[saveable[1]].name)
	ok(serr2 == "", "the unnamed part was saved too: %s", serr2)
	ok(strings.has_suffix(saved2, "/part-4.pdf"), "as part-4.pdf: %s", saved2)

	free_message(m)
}

// ---------------------------------------------------------------------------
// Filing: move, archive, delete, undo, and what POP3 can honestly do
// ---------------------------------------------------------------------------

// filing_state builds the smallest tree the filing rules can be checked on:
// one IMAP account with an inbox, an Archive and a Trash, and one POP3 account
// with nothing but an inbox — which is all POP3 can have.
filing_state :: proc(dir: string) -> ^State {
	imap_root := fmt.tprintf("%s/work", dir)
	maildir_make(imap_root)
	maildir_make(fmt.tprintf("%s/.Archive", imap_root))
	maildir_make(fmt.tprintf("%s/.Trash", imap_root))
	pop_root := fmt.tprintf("%s/lists", dir)
	maildir_make(pop_root)
	// A third account with an inbox and nothing else, so that archiving has to
	// create the folder — which reloads the tree and renumbers every message
	// underneath the operation that asked for it.
	plain_root := fmt.tprintf("%s/plain", dir)
	maildir_make(plain_root)

	one :: proc(subject, id: string) -> string {
		return fmt.tprintf(
			"Date: Tue, 3 Feb 2026 12:00:00 +0000\r\nFrom: Robot <robot@localhost>\r\nTo: alex@work.test\r\nSubject: %s\r\nMessage-ID: <%s>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody of %s\r\n",
			subject,
			id,
			id,
		)
	}
	// Flagged and seen, in cur/, so the suffix has something to carry.
	write_file(
		fmt.tprintf("%s/cur/1770000001.M1P1.selftest:2,FS", imap_root),
		transmute([]u8)one("Filing me", "file-1@selftest"),
	)
	// Unread, in new/, so a move has to take it out of new/.
	write_file(
		fmt.tprintf("%s/new/1770000002.M2P1.selftest", imap_root),
		transmute([]u8)one("Unread and unfiled", "file-2@selftest"),
	)
	write_file(
		fmt.tprintf("%s/new/1770000003.M3P1.selftest", pop_root),
		transmute([]u8)one("From a POP3 server", "pop-1@selftest"),
	)
	// Filler, so the inbox still has a list worth rebuilding after everything
	// below has moved, archived and deleted its way through it.
	for i in 0 ..< 5 {
		write_file(
			fmt.tprintf("%s/cur/177000001%d.M9P1.selftest:2,S", imap_root, i),
			transmute([]u8)one(fmt.tprintf("Filler %d", i), fmt.tprintf("fill-%d@selftest", i)),
		)
	}
	// Two in the folderless account, so "archive the second" can be checked
	// against "archive whatever the cursor happened to land on after a reload".
	write_file(
		fmt.tprintf("%s/cur/1770000004.M4P1.selftest:2,S", plain_root),
		transmute([]u8)one("Plain first", "plain-1@selftest"),
	)
	write_file(
		fmt.tprintf("%s/cur/1770000005.M5P1.selftest:2,S", plain_root),
		transmute([]u8)one("Plain second", "plain-2@selftest"),
	)

	write_file(
		config_path(dir, context.temp_allocator),
		transmute([]u8)string(
			"[account]\nname = Work\nprotocol = imap\naddress = alex@work.test\nhost = 127.0.0.1\npath = work\n" +
			"[account]\nname = Lists\nprotocol = pop3\naddress = alex@lists.test\nhost = 127.0.0.1\npath = lists\n" +
			"[account]\nname = Plain\nprotocol = imap\naddress = alex@plain.test\nhost = 127.0.0.1\npath = plain\n",
		),
	)

	st := new(State)
	st.data_dir = strings.clone(dir)
	st.reader_msg = -1
	st.att_sel = -1
	st.list_scroll_to = -1
	st.now = time.now()
	load_config(st)
	scan_accounts(st)
	rebuild_sidebar(st)
	return st
}

find_message_by_id :: proc(st: ^State, id: string) -> int {
	for m, i in st.messages {
		if m.id == id {
			return i
		}
	}
	return -1
}

test_filing :: proc() {
	dir := fmt.tprintf("%s/selftest-filing", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	st := filing_state(dir)
	defer free(st)

	eq_int(len(st.accounts), 3, "three accounts were configured")
	eq_int(len(st.messages), 10, "ten messages were read back")

	// --- what each protocol may do ---------------------------------------
	// By name, not by protocol: "Plain" is an IMAP account too, and picking
	// "the last IMAP one" would quietly test a different mailbox.
	imap_ai, pop_ai := -1, -1
	for a, ai in st.accounts {
		if a.name == "Work" {imap_ai = ai}
		if a.protocol == .POP3 {pop_ai = ai}
	}
	ok(imap_ai >= 0 && pop_ai >= 0, "found both accounts")
	imap_can, _ := can_file(st, imap_ai)
	ok(imap_can, "an IMAP account can file into folders")
	pop_can, pop_why := can_file(st, pop_ai)
	ok(!pop_can, "a POP3 account cannot: it has no folders")
	ok(strings.contains(pop_why, "POP3"), "and it is told so in words: %q", pop_why)

	pop_folders := 0
	for f in st.folders {
		if f.account == pop_ai {
			pop_folders += 1
		}
	}
	eq_int(pop_folders, 1, "the POP3 account still has exactly one folder")

	inbox := folder_of_role(st, imap_ai, .Inbox)
	archive := folder_of_role(st, imap_ai, .Archive)
	trash := folder_of_role(st, imap_ai, .Trash)
	ok(inbox >= 0 && archive >= 0 && trash >= 0, "the IMAP account has an inbox, an archive and a trash")

	// --- a move is a rename, and the flag suffix travels ------------------
	select_folder(st, inbox)
	eq_int(st.folders[inbox].total, 7, "seven messages in the inbox to start with")
	eq_int(st.folders[inbox].unread, 1, "one of them unread")
	eq_int(st.folders[archive].total, 0, "the archive starts empty")

	mi := find_message_by_id(st, "file-1@selftest")
	ok(mi >= 0, "found the flagged, seen message")
	before := strings.clone(st.messages[mi].path, context.temp_allocator)
	ok(.Flagged in st.messages[mi].flags && .Seen in st.messages[mi].flags, "it is flagged and seen")

	merr := move_message(st, mi, archive)
	eq_str(merr, "", "the move succeeded")
	mi = find_message_by_id(st, "file-1@selftest")
	ok(mi >= 0, "and the message is still in the model")
	ok(!os.exists(before), "the file is no longer at its old path")
	ok(os.exists(st.messages[mi].path), "it is at its new one: %s", st.messages[mi].path)
	ok(
		strings.has_prefix(st.messages[mi].path, st.folders[archive].path),
		"which is inside the Archive folder: %s",
		st.messages[mi].path,
	)
	ok(strings.contains(st.messages[mi].path, "/cur/"), "in cur/, not new/")
	ok(
		strings.has_suffix(st.messages[mi].file, ":2,FS"),
		"and the :2,FS suffix travelled with it: %s",
		st.messages[mi].file,
	)
	eq_int(int(st.messages[mi].folder), archive, "the model agrees it is in the archive")
	eq_int(st.folders[inbox].total, 6, "the inbox count dropped")
	eq_int(st.folders[archive].total, 1, "the archive count rose")

	// A second move of the same message is refused as a no-op.
	eq_str(move_message(st, mi, archive), "it is already there", "moving a message where it already is says so")

	// Across accounts is refused: it is a copy and a delete, and no protocol
	// has a word for it.
	pop_inbox := -1
	for f, fi in st.folders {
		if f.account == pop_ai {
			pop_inbox = fi
		}
	}
	cross := move_message(st, mi, pop_inbox)
	ok(cross != "", "moving between accounts is refused")
	ok(strings.contains(cross, "accounts"), "and says why: %q", cross)

	// --- undo -------------------------------------------------------------
	ok(st.undo.valid, "the move left an undo")
	what, uerr := undo_move(st)
	eq_str(uerr, "", "the undo succeeded")
	eq_str(what, "Filing me", "and names what it put back")
	mi = find_message_by_id(st, "file-1@selftest")
	ok(mi >= 0 && st.messages[mi].folder == inbox, "the message is back in the inbox")
	eq_str(st.messages[mi].path, before, "at exactly the path it came from")
	ok(os.exists(before), "and the file is there")
	eq_int(st.folders[inbox].total, 7, "the inbox count came back")
	eq_int(st.folders[archive].total, 0, "and the archive is empty again")
	ok(!st.undo.valid, "the undo was consumed")
	_, uerr2 := undo_move(st)
	ok(uerr2 != "", "undoing twice says there is nothing to undo")

	// --- a move takes a message out of new/ -------------------------------
	mi2 := find_message_by_id(st, "file-2@selftest")
	ok(mi2 >= 0 && st.messages[mi2].in_new, "the unread message is in new/")
	ok(msg_unread(st.messages[mi2]), "and is unread")
	eq_str(move_message(st, mi2, trash), "", "it moves to Trash")
	mi2 = find_message_by_id(st, "file-2@selftest")
	ok(!st.messages[mi2].in_new, "and is no longer in new/")
	ok(strings.contains(st.messages[mi2].path, "/.Trash/cur/"), "the file is in Trash's cur/: %s", st.messages[mi2].path)
	ok(msg_unread(st.messages[mi2]), "a filed message is not marked read by the filing")
	eq_int(st.folders[trash].unread, 1, "Trash shows it as unread")
	eq_int(st.folders[inbox].unread, 0, "and the inbox no longer does")
	what2, uerr3 := undo_move(st)
	eq_str(uerr3, "", "the second undo succeeded")
	eq_str(what2, "Unread and unfiled", "undo names it")
	mi2 = find_message_by_id(st, "file-2@selftest")
	ok(st.messages[mi2].folder == inbox, "and it is back in the inbox")

	// --- creating a folder that was never there ---------------------------
	// The POP3 account must not get one, however it is asked.
	ok(ensure_role_folder(st, pop_ai, .Trash, "Trash") < 0, "a POP3 account is refused a Trash folder")
	ok(!os.is_dir(fmt.tprintf("%s/lists/.Trash", dir)), "and nothing was created on disk for it")

	// --- POP3 deletion is local, and destroys nothing ---------------------
	pop_mi := find_message_by_id(st, "pop-1@selftest")
	ok(pop_mi >= 0, "found the POP3 message")
	pop_path := strings.clone(st.messages[pop_mi].path, context.temp_allocator)
	select_folder(st, pop_inbox)
	eq_int(st.folders[pop_inbox].total, 1, "the POP3 inbox has one message")
	visible := 0
	for r in st.rows {
		if r.kind == .Thread {
			visible += 1
		}
	}
	eq_int(visible, 1, "and the list shows it")

	st.row_sel = 0
	sync_reader(st)
	delete_selection(st)
	pop_mi = find_message_by_id(st, "pop-1@selftest")
	ok(pop_mi >= 0, "the POP3 message still exists in the model")
	ok(.Deleted in st.messages[pop_mi].flags, "it carries the Trashed flag")
	eq_str(st.messages[pop_mi].path, pop_path, "the file was NOT renamed: POP3 has no server-side flags")
	ok(os.exists(pop_path), "and it is still on disk where the engine left it")
	ok(
		os.exists(local_flags_path(st, pop_ai, context.temp_allocator)),
		"the deletion was recorded in this account's local sidecar",
	)
	ok(msg_hidden(st, st.messages[pop_mi]), "and the message is hidden from the list")
	eq_int(st.folders[pop_inbox].total, 0, "the POP3 inbox now counts nothing")
	hidden_rows := 0
	for r in st.rows {
		if r.kind == .Thread {
			hidden_rows += 1
		}
	}
	eq_int(hidden_rows, 0, "the list shows nothing")

	// And it survives a rescan, because only this machine knows about it.
	scan_accounts(st)
	rebuild_sidebar(st)
	pop_mi = find_message_by_id(st, "pop-1@selftest")
	ok(pop_mi >= 0 && .Deleted in st.messages[pop_mi].flags, "the local deletion survived a rescan")

	// --- archive, through the selection, creating the folder --------------
	imap_inbox := folder_of_role(st, imap_ai, .Inbox)
	select_folder(st, imap_inbox)
	st.row_sel = 0
	sync_reader(st)
	n_before := st.folders[imap_inbox].total
	archive_selection(st)
	imap_inbox = folder_of_role(st, imap_ai, .Inbox)
	arch := folder_of_role(st, imap_ai, .Archive)
	ok(arch >= 0, "the archive is still there")
	ok(st.folders[arch].total > 0, "something was archived (%d)", st.folders[arch].total)
	ok(st.folders[imap_inbox].total < n_before, "and the inbox has fewer than it did")

	// --- archiving into a folder that has to be created first -------------
	//
	// `ensure_role_folder` reloads the whole tree, which renumbers every
	// message and resets the cursor to the top of the list. An implementation
	// that remembered the selection as an index would archive whatever ended
	// up at that index afterwards — a different message, silently.
	{
		plain_ai := -1
		for a, ai in st.accounts {
			if a.name == "Plain" {
				plain_ai = ai
			}
		}
		ok(plain_ai >= 0, "found the folderless account")
		ok(folder_of_role(st, plain_ai, .Archive) < 0, "it has no Archive folder to begin with")

		plain_inbox := folder_of_role(st, plain_ai, .Inbox)
		ok(plain_inbox >= 0, "but it does have an inbox")
		select_folder(st, plain_inbox)
		// Put the cursor on the *second* message, whichever row that is.
		target_row := -1
		for r, i in st.rows {
			if r.kind != .Thread {
				continue
			}
			t := st.threads[r.thread]
			if len(t.msgs) > 0 && st.messages[t.msgs[0]].id == "plain-2@selftest" {
				target_row = i
			}
		}
		ok(target_row >= 0, "the second message has a row")
		if target_row >= 0 {
			st.row_sel = target_row
			sync_reader(st)
			archive_selection(st)

			arch := folder_of_role(st, plain_ai, .Archive)
			ok(arch >= 0, "an Archive folder was created")
			ok(os.is_dir(fmt.tprintf("%s/plain/.Archive/cur", dir)), "as a Maildir++ subfolder on disk")
			ok(
				os.exists(fmt.tprintf("%s/plain/.Archive/maildirfolder", dir)),
				"with the marker file other Maildir tools look for",
			)
			moved := find_message_by_id(st, "plain-2@selftest")
			kept := find_message_by_id(st, "plain-1@selftest")
			ok(moved >= 0 && kept >= 0, "both messages are still in the model")
			if moved >= 0 && kept >= 0 {
				eq_int(
					int(st.messages[moved].folder),
					arch,
					"the message that was selected is the one that got archived",
				)
				eq_int(
					int(st.messages[kept].folder),
					folder_of_role(st, plain_ai, .Inbox),
					"and the other one did not move",
				)
			}
			eq_int(st.folders[arch].total, 1, "exactly one message was archived")
		}
	}

	// --- permanent deletion -----------------------------------------------
	victim := find_message_by_id(st, "file-1@selftest")
	if victim < 0 {
		victim = find_message_by_id(st, "file-2@selftest")
	}
	ok(victim >= 0, "found a message to destroy")
	gone := strings.clone(st.messages[victim].path, context.temp_allocator)
	count_before := len(st.messages)
	perr := purge_message(st, victim)
	eq_str(perr, "", "the permanent delete succeeded")
	ok(!os.exists(gone), "the file is unlinked: %s", gone)
	eq_int(len(st.messages), count_before - 1, "and the model has one fewer message")
	ok(find_message_by_id(st, "file-1@selftest") < 0 || find_message_by_id(st, "file-2@selftest") < 0, "the message is gone from the model")

	// Deleting the LAST message in the array while a row still names it.
	//
	// The rows are built before the removal and hold message indices. Once the
	// final element is gone, a row naming it is one past the end — and
	// `rebuild_rows` asks the current row which message it stands for *before*
	// it rebuilds anything. So `purge_message` has to drop the rows first, and
	// this is the assertion that fails if that ordering is ever undone: the
	// row is put there deliberately, because it is the state the UI reaches
	// with the cursor on a message inside an expanded conversation.
	{
		last := len(st.messages) - 1
		ok(last >= 0, "there is a message to delete")
		if last >= 0 {
			// The list has to be showing a folder that still has messages in
			// it after the delete, because an empty rebuild has no rows to
			// walk and would hide the bug.
			select_folder(st, folder_of_role(st, imap_ai, .Inbox))
			ok(len(st.rows) > 1, "the list has several rows to rebuild (%d)", len(st.rows))
			gone2 := strings.clone(st.messages[last].path, context.temp_allocator)
			id2 := strings.clone(st.messages[last].id, context.temp_allocator)
			clear(&st.rows)
			append(&st.rows, Row{kind = .Message, thread = 0, msg = last, depth = 0})
			st.row_sel = 0
			st.reader_msg = last
			before_n := len(st.messages)

			perr2 := purge_message(st, last)

			eq_str(perr2, "", "the last message was deleted with a row still naming it")
			eq_int(len(st.messages), before_n - 1, "it left the model")
			ok(!os.exists(gone2), "and was unlinked from disk")
			ok(find_message_by_id(st, id2) < 0, "and cannot be found by id any more")
			stale := 0
			for r in st.rows {
				if r.msg >= len(st.messages) {
					stale += 1
				}
			}
			eq_int(stale, 0, "no row is left naming a message that no longer exists")
			ok(
				st.reader_msg < len(st.messages),
				"and the reader is not pointing past the end (%d of %d)",
				st.reader_msg,
				len(st.messages),
			)
		}
	}

	// A path outside the account root is refused rather than unlinked.
	outside := fmt.tprintf("%s/outside.txt", dir)
	write_file(outside, transmute([]u8)string("not mail"))
	if len(st.messages) > 0 {
		keep := strings.clone(st.messages[0].path, context.temp_allocator)
		delete(st.messages[0].path)
		st.messages[0].path = strings.clone(outside)
		rerr := purge_message(st, 0)
		ok(rerr != "", "a message whose file is outside its account root is not deleted")
		ok(os.exists(outside), "and the file is untouched")
		delete(st.messages[0].path)
		st.messages[0].path = strings.clone(keep)
	}
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

	// The binary attachment in the real fixture tree, round-tripped off disk.
	// This is the same message and the same bytes the recorded demo saves, so
	// what the video shows is what this asserts.
	{
		payload := fixture_payload()
		found := -1
		for m, i in st.messages {
			if strings.contains(m.id, "-inline@fixtures.test") {
				found = i
				break
			}
		}
		ok(found >= 0, "the inline-image fixture is in the mailbox")
		if found >= 0 {
			fm := st.messages[found]
			saveable := saveable_attachments(fm)
			eq_int(inline_attachment_count(fm), 1, "its logo is recognised as inline, not as a file to save")
			eq_int(len(saveable), 2, "two of its parts are offered to save")
			eq_str(fm.attachments[saveable[0]].name, "measurements.bin", "the first is the binary trace")
			eq_int(fm.attachments[saveable[0]].size, 262, "262 bytes of it")
			data, dok := attachment_bytes(fm, fm.attachments[saveable[0]], context.temp_allocator)
			ok(dok, "its bytes read back out of the Maildir file")
			ok(
				bytes_equal(data, payload),
				"BYTE-EXACT: the fixture's attachment decodes to the payload that was encoded into it",
			)
			// And through the save path, onto the disk.
			outdir := fmt.tprintf("%s/saved", dir)
			os.make_directory_all(outdir)
			sp, serr := save_attachment_to(fm, fm.attachments[saveable[0]], outdir, fm.attachments[saveable[0]].name)
			eq_str(serr, "", "and it saves")
			disk, rok2 := read_file(sp, context.temp_allocator)
			ok(rok2 && bytes_equal(disk, payload), "BYTE-EXACT: and the file on disk matches it too")
		}
	}
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

// ---------------------------------------------------------------------------
// Drafts: the one failure in this client that destroyed something
//
// Everything here runs against a Maildir written for the purpose, inside the
// app's own data directory, and removes it afterwards. The user's mail is
// never read, by this test or by anything it calls.
// ---------------------------------------------------------------------------

test_drafts :: proc() {
	dir := fmt.tprintf("%s/selftest-drafts", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	st := filing_state(dir)
	defer free(st)
	build_address_book(st)
	inbox := -1
	for f, fi in st.folders {
		if f.role == .Inbox && st.accounts[f.account].name == "Work" {
			inbox = fi
			break
		}
	}
	ok(inbox >= 0, "the Work inbox was found")
	select_folder(st, inbox)

	// --- nothing is saved for a composition nobody typed into --------------
	compose_blank(st)
	ok(compose_is_empty(&st.comp), "a new composition starts empty")
	ok(!compose_dirty(&st.comp), "and is not a draft")
	draft_tick(st)
	ok(!os.exists(draft_path(st, context.temp_allocator)), "so nothing was written")

	// A reply arrives prefilled, and that is still not something the user
	// wrote: Escape out of one must not leave a draft behind.
	mi := find_message_by_id(st, "file-1@selftest")
	ok(mi >= 0, "found a message to reply to")
	compose_reply(st, mi, false)
	ok(!compose_is_empty(&st.comp), "a reply is prefilled")
	ok(!compose_dirty(&st.comp), "but an untouched reply is not a draft")
	draft_autosave_seconds = 0
	draft_tick(st)
	ok(!os.exists(draft_path(st, context.temp_allocator)), "and still nothing was written")
	close_composer(st)
	ok(!os.exists(draft_path(st, context.temp_allocator)), "closing it left no slot")

	// --- typing makes it a draft, and the draft reaches the disk -----------
	compose_blank(st)
	le_set(&st.comp.to, "Ada <ada@analytical.test>")
	le_set(&st.comp.subject, "The southern reach")
	buf_set_text(&st.comp.body, "First line.\nSecond line, unfinished")
	st.comp.body.cur = {1, 7}
	st.comp.field = .Body
	ok(compose_dirty(&st.comp), "typed text makes it a draft")
	draft_tick(st)
	slot := draft_path(st, context.temp_allocator)
	ok(os.exists(slot), "the autosave tick wrote the slot: %s", slot)

	raw, rok := read_file(slot, context.temp_allocator)
	ok(rok, "the slot can be read back")
	d := draft_parse(string(raw))
	ok(d.ok, "and parses")
	eq_str(d.to, "Ada <ada@analytical.test>", "To survived")
	eq_str(d.subject, "The southern reach", "Subject survived")
	eq_str(d.body, "First line.\nSecond line, unfinished", "the body survived, newlines and all")
	eq_int(d.cursor.line, 1, "the cursor line survived")
	eq_int(d.cursor.col, 7, "the cursor column survived")
	ok(d.saved._nsec > 0, "a timestamp was written")

	// A second tick with nothing changed must not rewrite the file.
	before_hash := st.comp.saved_hash
	draft_tick(st)
	eq_int(int(st.comp.saved_hash - before_hash), 0, "an unchanged composer is not written again")

	// --- the process goes away, and comes back -----------------------------
	// A fresh State over the same directory is exactly what the next run is.
	st2 := filing_state(dir)
	defer free(st2)
	build_address_book(st2)
	ok(!st2.draft_waiting, "a fresh state has not looked yet")
	draft_peek(st2)
	ok(st2.draft_waiting, "the draft left on disk is noticed at startup")
	ok(strings.contains(st2.draft_label, "The southern reach"), "and is named: %q", st2.draft_label)
	ok(!st2.comp.open, "the composer does not open by itself")

	compose_new(st2)
	ok(st2.comp.open, "C opens it")
	ok(!st2.draft_waiting, "and the draft is no longer waiting")
	eq_str(le_text(&st2.comp.to), "Ada <ada@analytical.test>", "To came back")
	eq_str(le_text(&st2.comp.subject), "The southern reach", "Subject came back")
	eq_str(
		buf_text(&st2.comp.body, context.temp_allocator),
		"First line.\nSecond line, unfinished",
		"the body came back",
	)
	eq_int(st2.comp.body.cur.line, 1, "the caret came back to its line")
	eq_int(st2.comp.body.cur.col, 7, "and to its column")
	eq_int(int(st2.comp.field), int(Compose_Field.Body), "with the same field focused")
	ok(compose_dirty(&st2.comp), "a restored draft is still unsaved work")

	// --- Escape keeps it; Discard is the only thing that throws it away ----
	close_composer(st2)
	ok(os.exists(draft_path(st2, context.temp_allocator)), "Escape kept the draft")
	compose_new(st2)
	ok(st2.comp.open, "and C picks it up again")
	eq_str(le_text(&st2.comp.subject), "The southern reach", "with the text still there")

	discard_composer(st2)
	ok(!os.exists(draft_path(st2, context.temp_allocator)), "Discard removed the slot")
	ok(compose_is_empty(&st2.comp), "and emptied the composer")

	// --- typing and then taking it all back out again ----------------------
	compose_blank(st2)
	le_set(&st2.comp.subject, "nearly")
	draft_tick(st2)
	ok(os.exists(draft_path(st2, context.temp_allocator)), "a few characters are enough to be saved")
	le_clear(&st2.comp.subject)
	draft_tick(st2)
	ok(!os.exists(draft_path(st2, context.temp_allocator)), "undoing them takes the slot away again")

	// --- parking: a second composition never costs the first ---------------
	compose_blank(st2)
	le_set(&st2.comp.to, "grace@navy.test")
	le_set(&st2.comp.subject, "Compiler notes")
	buf_set_text(&st2.comp.body, "Half a paragraph that must not be lost.")
	draft_tick(st2)
	ok(os.exists(draft_path(st2, context.temp_allocator)), "the first draft is on disk")

	reply_to := find_message_by_id(st2, "file-2@selftest")
	ok(reply_to >= 0, "found a different message to reply to")
	want_subject := strings.clone(st2.messages[reply_to].subject, context.temp_allocator)
	compose_reply(st2, reply_to, false)
	ok(
		!os.exists(draft_path(st2, context.temp_allocator)),
		"starting the reply cleared the slot — because it was parked, not dropped",
	)
	ok(
		strings.contains(le_text(&st2.comp.subject), want_subject),
		"and the reply is to the message that was asked for: %q",
		le_text(&st2.comp.subject),
	)

	drafts_fi := -1
	for f, fi in st2.folders {
		if f.role == .Drafts && st2.accounts[f.account].name == "Work" {
			drafts_fi = fi
		}
	}
	ok(drafts_fi >= 0, "a Drafts folder was created for the account")
	parked := -1
	for m, i in st2.messages {
		if m.folder == drafts_fi {
			parked = i
		}
	}
	ok(parked >= 0, "the parked draft is in it")
	if parked >= 0 {
		pm := st2.messages[parked]
		eq_str(pm.subject, "Compiler notes", "with the subject it was given")
		ok(.Draft in pm.flags, "flagged as a draft")
		ok(.Seen in pm.flags, "and not as unread mail")
		ok(strings.contains(pm.path, "/cur/"), "in cur/, not new/: %s", pm.path)
		ok(strings.contains(pm.body, "must not be lost"), "the text is all there")
		ok(is_draft_message(st2, parked), "and the list knows to open it in the composer")

		// Opening it puts it back in the composer, byte for byte.
		close_composer(st2)
		draft_discard(st2)
		compose_edit_draft(st2, parked)
		ok(st2.comp.open, "the parked draft opens in the composer")
		eq_str(le_text(&st2.comp.subject), "Compiler notes", "with its subject")
		ok(
			strings.contains(buf_text(&st2.comp.body, context.temp_allocator), "must not be lost"),
			"and its body",
		)
		ok(st2.comp.origin_path != "", "it remembers the file it came from")
	}

	// --- sending finishes with the draft -----------------------------------
	origin := strings.clone(st2.comp.origin_path, context.temp_allocator)
	draft_tick(st2)
	ok(os.exists(draft_path(st2, context.temp_allocator)), "the edited draft is held in the slot")
	do_send(st2)
	ok(!os.exists(draft_path(st2, context.temp_allocator)), "sending clears the slot")
	ok(origin == "" || !os.exists(origin), "and unlinks the Drafts file it came from")
	queued := 0
	for m in st2.messages {
		if st2.folders[m.folder].name == ".Outbox" || strings.contains(m.path, "/.Outbox/") {
			queued += 1
		}
	}
	ok(queued >= 1, "the message is in the local Outbox, which is the only place Send writes")

	draft_autosave_seconds = 1.0
}

// ---------------------------------------------------------------------------
// Multi-select
// ---------------------------------------------------------------------------

test_multiselect :: proc() {
	dir := fmt.tprintf("%s/selftest-marks", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	st := filing_state(dir)
	defer free(st)
	inbox := -1
	for f, fi in st.folders {
		if f.role == .Inbox && st.accounts[f.account].name == "Work" {
			inbox = fi
		}
	}
	select_folder(st, inbox)
	ok(len(st.rows) >= 3, "the inbox has rows to mark (%d)", len(st.rows))

	// With nothing marked, a verb still acts on the row under the cursor.
	st.row_sel = 0
	eq_int(marked_count(st), 0, "nothing is marked to start with")
	eq_int(
		len(selection_messages(st, context.temp_allocator)),
		len(row_messages(st, 0, context.temp_allocator)),
		"so the selection is whatever the cursor covers",
	)

	// Mark three rows.
	paths := make([dynamic]string, 0, 3, context.temp_allocator)
	for r in 0 ..< 3 {
		st.row_sel = r
		mark_toggle_row(st)
		for mi in row_messages(st, r, context.temp_allocator) {
			append(&paths, strings.clone(st.messages[mi].path, context.temp_allocator))
		}
	}
	eq_int(marked_count(st), len(paths), "every message under those rows is marked")
	ok(row_marked(st, 0) && row_marked(st, 1) && row_marked(st, 2), "and all three rows read as marked")
	ok(!row_marked(st, 3) || len(st.rows) <= 3, "a row that was not marked does not")

	sel := selection_messages(st, context.temp_allocator)
	eq_int(len(sel), len(paths), "the selection is the marked set, not the cursor row")
	for i in 1 ..< len(sel) {
		ok(sel[i - 1] < sel[i], "and it comes back in scan order")
	}

	// Toggling the same row again takes it back out.
	st.row_sel = 1
	n_before := marked_count(st)
	mark_toggle_row(st)
	ok(marked_count(st) < n_before, "toggling a marked row unmarks it")
	mark_toggle_row(st)
	eq_int(marked_count(st), n_before, "and toggling again puts it back")

	// The cursor is somewhere else entirely; the verb still acts on the marks.
	st.row_sel = len(st.rows) - 1
	marked := selection_messages(st, context.temp_allocator)
	want := len(marked)
	ok(want >= 3, "at least three messages are selected (%d)", want)
	moved, err := archive_selection_count(st)
	eq_str(err, "", "archiving the selection succeeded")
	eq_int(moved, want, "every marked message moved, not just the one under the cursor")
	eq_int(marked_count(st), 0, "and the selection is cleared once the verb has run")

	// A mark whose file has gone is dropped rather than left lying.
	st.row_sel = 0
	mark_toggle_row(st)
	eq_int(marked_count(st) > 0 ? 1 : 0, 1, "something is marked again")
	for &m in st.messages {
		if st.marked[m.path] {
			os.remove(m.path)
		}
	}
	reload_all(st)
	eq_int(marked_count(st), 0, "a mark whose message is gone is pruned on reload")
}

// archive_selection_count is `archive_selection` with the numbers returned
// rather than put in a toast, which is what an assertion needs.
archive_selection_count :: proc(st: ^State) -> (moved: int, err: string) {
	msgs := selection_messages(st, context.temp_allocator)
	if len(msgs) == 0 {
		return 0, "nothing is selected"
	}
	ai := st.messages[msgs[0]].account
	paths := selection_paths(st, context.temp_allocator)
	target := ensure_role_folder(st, ai, .Archive, "Archive")
	if target < 0 {
		return 0, "no archive"
	}
	return file_selection_of(st, messages_at_paths(st, paths), target)
}

// ---------------------------------------------------------------------------
// Address autocomplete
// ---------------------------------------------------------------------------

test_autocomplete :: proc() {
	dir := fmt.tprintf("%s/selftest-book", default_data_dir(context.temp_allocator))
	remove_tree(dir)
	os.make_directory_all(dir)
	defer remove_tree(dir)

	st := filing_state(dir)
	defer free(st)

	// A handful of messages with real names on them, so the book has
	// something to rank.
	root := fmt.tprintf("%s/work", dir)
	one :: proc(id, from, to: string) -> string {
		return fmt.tprintf(
			"Date: Tue, 3 Feb 2026 12:00:00 +0000\r\nFrom: %s\r\nTo: %s\r\nSubject: book %s\r\n\r\nbody\r\n",
			from,
			to,
			id,
		)
	}
	write_file(
		fmt.tprintf("%s/cur/1770100001.M1P1.selftest:2,S", root),
		transmute([]u8)one("1", "Grace Hopper <grace@navy.test>", "alex@work.test"),
	)
	write_file(
		fmt.tprintf("%s/cur/1770100002.M2P1.selftest:2,S", root),
		transmute([]u8)one("2", "Grace Hopper <grace@navy.test>", "alex@work.test, Ada Lovelace <ada@analytical.test>"),
	)
	write_file(
		fmt.tprintf("%s/cur/1770100003.M3P1.selftest:2,S", root),
		transmute([]u8)one("3", "grace@navy.test", "Katherine Johnson <katherine@langley.test>"),
	)
	reload_all(st)

	ok(len(st.book) > 0, "the address book was built (%d contacts)", len(st.book))
	find :: proc(st: ^State, email: string) -> int {
		for c, i in st.book {
			if c.email == email {
				return i
			}
		}
		return -1
	}
	gi := find(st, "grace@navy.test")
	ai := find(st, "ada@analytical.test")
	ok(gi >= 0 && ai >= 0, "both correspondents are in it")
	ok(st.book[gi].count > st.book[ai].count, "the one who appears more often ranks higher")
	eq_str(st.book[gi].name, "Grace Hopper", "a bare address later does not lose the display name")
	ok(gi < ai, "and the book is sorted by that ranking")

	// Nothing comes from anywhere but the mailbox: every contact's address
	// has to appear in a message that was scanned, or be an account's own.
	for c in st.book {
		seen := false
		for m in st.messages {
			if strings.contains(strings.to_lower(m.blob, context.temp_allocator), strings.to_lower(c.email, context.temp_allocator)) {
				seen = true
				break
			}
		}
		for a in st.accounts {
			if a.address == c.email {
				seen = true
			}
		}
		ok(seen, "%q came from the mailbox, not from anywhere else", c.email)
	}

	// The fragment under the caret.
	eq_str(ac_fragment("gra", 3), "gra", "the whole field when there is no comma")
	eq_str(ac_fragment("ada@x.test, gra", 15), "gra", "only what follows the last comma")
	eq_str(ac_fragment("ada@x.test, gra", 10), "ada@x.test", "and only up to the caret")
	eq_str(ac_fragment("ada@x.test, ", 12), "", "an empty fragment is empty")

	// Matching: by local part, by display name, by any word of it, by domain.
	has :: proc(st: ^State, hits: []int, email: string) -> bool {
		for h in hits {
			if st.book[h].email == email {
				return true
			}
		}
		return false
	}
	ok(has(st, ac_match(st, "gra", "", context.temp_allocator), "grace@navy.test"), "a local-part prefix matches")
	ok(has(st, ac_match(st, "Grace", "", context.temp_allocator), "grace@navy.test"), "case does not matter")
	ok(has(st, ac_match(st, "hopper", "", context.temp_allocator), "grace@navy.test"), "a surname matches")
	ok(has(st, ac_match(st, "navy", "", context.temp_allocator), "grace@navy.test"), "so does the domain")
	ok(has(st, ac_match(st, "langley", "", context.temp_allocator), "katherine@langley.test"), "and another domain")
	eq_int(len(ac_match(st, "zzzzz", "", context.temp_allocator)), 0, "a fragment nobody matches gives nothing")
	ok(len(ac_match(st, "e", "", context.temp_allocator)) <= AC_MAX, "the list is capped")
	ok(
		!has(st, ac_match(st, "ada", "ada@analytical.test, ", context.temp_allocator), "ada@analytical.test"),
		"somebody already in the field is not suggested again",
	)

	// Accepting: the fragment is replaced, the rest of the list is kept, and
	// the caret lands ready for the next address.
	compose_blank(st)
	st.comp.field = .To
	le_set(&st.comp.to, "gra")
	ac_update(st)
	ok(st.comp.ac_open, "the list opens as soon as there is something to show")
	ok(len(st.comp.ac_hits) > 0, "with hits in it")
	st.comp.ac_sel = 0
	ok(ac_accept(st), "accepting works")
	eq_str(le_text(&st.comp.to), "Grace Hopper <grace@navy.test>, ", "the fragment became the whole address")
	ok(!st.comp.ac_open, "and the list closed")
	eq_int(st.comp.to.cur, len(le_text(&st.comp.to)), "with the caret ready for the next one")

	le_set(&st.comp.to, "Grace Hopper <grace@navy.test>, ada")
	st.comp.to.cur = len(le_text(&st.comp.to))
	ac_update(st)
	ok(st.comp.ac_open, "a second address completes too")
	ac_accept(st)
	eq_str(
		le_text(&st.comp.to),
		"Grace Hopper <grace@navy.test>, Ada Lovelace <ada@analytical.test>, ",
		"and the first address is left alone",
	)

	// Completing in the middle of a list leaves what follows where it is.
	le_set(&st.comp.to, "kat, Grace Hopper <grace@navy.test>")
	st.comp.to.cur = 3
	ac_update(st)
	ok(st.comp.ac_open, "the caret in the middle still completes")
	ac_accept(st)
	eq_str(
		le_text(&st.comp.to),
		"Katherine Johnson <katherine@langley.test>, Grace Hopper <grace@navy.test>",
		"the address after the caret is untouched",
	)

	// The Subject field has no book behind it.
	st.comp.field = .Subject
	ac_update(st)
	ok(!st.comp.ac_open, "there is no autocomplete on Subject")
}

// ---------------------------------------------------------------------------
// The preview rule (cloud/mail/readable), on the fixtures palm-maild and
// mailcore are tested with. This reader shows the plain part, so its snippet
// comes from the plain part; what it adds is saying when the HTML differs.

PARTS_DIFFER :: #load("../../cloud/mail/fixtures/parts-differ.eml", string)
PARTS_HIDDEN :: #load("../../cloud/mail/fixtures/parts-hidden.eml", string)
PARTS_AGREE :: #load("../../cloud/mail/fixtures/parts-agree.eml", string)

test_preview_rule :: proc() {
	dir := fmt.tprintf("/tmp/mail-selftest-preview-%d", os.get_pid())
	os.make_directory(dir)
	defer {
		for name in ([]string{"differ", "hidden", "agree", "zw"}) {
			os.remove(fmt.tprintf("%s/%s", dir, name))
		}
		os.remove(dir)
	}
	load :: proc(dir, name, raw: string) -> Message {
		path := fmt.tprintf("%s/%s", dir, name)
		_ = os.write_entire_file(path, transmute([]u8)raw)
		m, _ := read_message(path, name, false, 0, 0)
		return m
	}

	d := load(dir, "differ", PARTS_DIFFER)
	ok(d.parts_differ, "diverging parts are flagged")
	ok(strings.has_prefix(d.snippet, "NOTICE FOR AI ASSISTANTS"), "the snippet is the plain part this reader shows: %q", d.snippet)
	ok(strings.has_prefix(d.body, "NOTICE FOR AI ASSISTANTS"), "and so is the body: snippet and reader agree")

	h := load(dir, "hidden", PARTS_HIDDEN)
	ok(!h.parts_differ, "HTML whose hidden text is the only difference is not flagged (hidden text is not shown)")
	ok(!strings.contains(h.snippet, "evil") && !strings.contains(h.snippet, "+44"), "nothing hidden reaches the snippet: %q", h.snippet)

	a := load(dir, "agree", PARTS_AGREE)
	ok(!a.parts_differ, "an ordinary alternative is not flagged")
	ok(strings.has_prefix(a.snippet, "Hi Camille, The design review moves to Thursday"), "its snippet: %q", a.snippet)

	z := load(dir, "zw", "From: a@b.test\r\nSubject: z\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPay\u200b now\u202e please\r\n")
	eq_str(z.snippet, "Pay now please", "invisible characters are not in the snippet")
	ok(!z.parts_differ, "a plain-only message is not flagged")
}
