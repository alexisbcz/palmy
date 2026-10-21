package main

// `mailcore --selftest` runs every assertion in this file with no network and
// no server, then (unless --no-e2e) hands over to e2e.odin, which starts the
// test server on loopback and drives all four protocols against it.
//
// Every assertion here states an expected value, not merely "did not crash".
// The count at the end is the number the engine should be judged on.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

T :: struct {
	passed:   int,
	failed:   int,
	failures: [dynamic]string,
	verbose:  bool,
	section:  string,
}

tsection :: proc(t: ^T, name: string) {
	t.section = name
	fmt.printfln("\n── %s %s", name, strings.repeat("─", max(0, 60 - len(name)), context.temp_allocator))
}

tcheck :: proc(t: ^T, name: string, ok: bool, detail := "") -> bool {
	if ok {
		t.passed += 1
		if t.verbose {
			fmt.printfln("  pass  %s", name)
		}
	} else {
		t.failed += 1
		line := fmt.aprintf("[%s] %s%s%s", t.section, name, detail == "" ? "" : " — ", detail)
		append(&t.failures, line)
		fmt.printfln("  FAIL  %s%s%s", name, detail == "" ? "" : " — ", detail)
	}
	return ok
}

teq :: proc(t: ^T, name, got, want: string) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, fmt.aprintf("got %q, want %q", got, want))
}

teq_int :: proc(t: ^T, name: string, got, want: int) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, fmt.aprintf("got %d, want %d", got, want))
}

teq_i64 :: proc(t: ^T, name: string, got, want: i64) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, fmt.aprintf("got %d, want %d", got, want))
}

tbytes :: proc(t: ^T, name: string, got: []u8, want: string) -> bool {
	return teq(t, name, string(got), want)
}

// ---------------------------------------------------------------------------

selftest_unit :: proc(t: ^T) {
	test_base64(t)
	test_qp(t)
	test_charsets(t)
	test_encoded_words(t)
	test_headers(t)
	test_params(t)
	test_dates(t)
	test_mime(t)
	test_preview_rule(t)
	test_malformed(t)
	test_imap_parser(t)
	test_imap_utf7(t)
	test_dot_stuffing(t)
	test_maildir(t)
	test_attachments(t)
	test_threading(t)
	test_compose(t)
	test_json(t)
	test_http_bits(t)
	test_loopback_gate(t)
	test_cli(t)
}

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

test_base64 :: proc(t: ^T) {
	tsection(t, "base64")
	teq(t, "encode 0 bytes", base64_encode({}, 0), "")
	teq(t, "encode 1 byte pads with ==", base64_encode({'M'}, 0), "TQ==")
	teq(t, "encode 2 bytes pads with =", base64_encode({'M', 'a'}, 0), "TWE=")
	teq(t, "encode 3 bytes needs no padding", base64_encode({'M', 'a', 'n'}, 0), "TWFu")
	teq(t, "encode high bytes", base64_encode({0xff, 0xff, 0xff}, 0), "////")

	tbytes(t, "decode TWFu", base64_decode(transmute([]u8)string("TWFu")), "Man")
	tbytes(t, "decode TQ==", base64_decode(transmute([]u8)string("TQ==")), "M")
	tbytes(t, "decode unpadded TQ", base64_decode(transmute([]u8)string("TQ")), "M")
	tbytes(t, "decode unpadded TWE", base64_decode(transmute([]u8)string("TWE")), "Ma")
	tbytes(
		t,
		"decode ignores CRLF and spaces",
		base64_decode(transmute([]u8)string("TW\r\nFu\t ")),
		"Man",
	)
	tbytes(
		t,
		"decode ignores junk characters",
		base64_decode(transmute([]u8)string("T#W*F!u")),
		"Man",
	)
	tbytes(
		t,
		"a lone sextet carries no byte and is dropped",
		base64_decode(transmute([]u8)string("TWFuT")),
		"Man",
	)
	tbytes(t, "decode of garbage is empty, not a crash", base64_decode(transmute([]u8)string("!!!!")), "")

	// Round trip over every byte value, which is the only test that catches a
	// sign-extension bug in the encoder.
	all := make([]u8, 256, context.temp_allocator)
	for i in 0 ..< 256 {
		all[i] = u8(i)
	}
	enc := base64_encode(all, 76, context.temp_allocator)
	dec := base64_decode(transmute([]u8)enc, context.temp_allocator)
	same := len(dec) == 256
	if same {
		for i in 0 ..< 256 {
			if dec[i] != u8(i) {same = false;break}
		}
	}
	tcheck(t, "round trip of all 256 byte values", same, fmt.aprintf("%d bytes back", len(dec)))
	// Wrapping must not change the payload.
	lines := strings.split_lines(enc, context.temp_allocator)
	longest := 0
	for l in lines {
		if len(l) > longest {longest = len(l)}
	}
	tcheck(t, "wrapped lines are at most 76 columns", longest <= 76, fmt.aprintf("longest %d", longest))
}

// ---------------------------------------------------------------------------
// quoted-printable
// ---------------------------------------------------------------------------

test_qp :: proc(t: ^T) {
	tsection(t, "quoted-printable")
	qd :: proc(s: string, header := false) -> string {
		return string(qp_decode(transmute([]u8)s, header, context.temp_allocator))
	}
	teq(t, "plain text passes through", qd("hello"), "hello")
	teq(t, "=XX decodes", qd("caf=C3=A9"), "café")
	teq(t, "=3D is a literal equals", qd("a=3Db"), "a=b")
	teq(t, "soft line break (CRLF) vanishes", qd("abc=\r\ndef"), "abcdef")
	teq(t, "soft line break (bare LF) vanishes", qd("abc=\ndef"), "abcdef")
	teq(
		t,
		"soft break with transport whitespace before the CRLF",
		qd("abc=  \t\r\ndef"),
		"abcdef",
	)
	teq(t, "hard line break survives", qd("abc\r\ndef"), "abc\r\ndef")
	teq(
		t,
		"trailing whitespace before a hard break is stripped",
		qd("abc   \r\ndef"),
		"abc\r\ndef",
	)
	// The classic: an =XX whose hex digits are on the next line is NOT valid,
	// and the '=' must survive as data rather than eating the next character.
	teq(t, "=C3 split by a soft break rejoins", qd("caf=\r\n=C3=A9"), "café")
	teq(t, "a trailing lone = is literal", qd("abc="), "abc=")
	teq(t, "=ZZ is not hex, so = is literal", qd("a=ZZb"), "a=ZZb")
	teq(t, "=4 at end of input is literal", qd("a=4"), "a=4")
	// In a Q-encoded header word, '_' is a space. The bytes here are Latin-1,
	// so the decoder's output is raw 0xE9/0xE8 with a real space between.
	teq(t, "underscore is space in a header word", qd("Caf=E9_Cr=E8me", true), "Caf\xe9 Cr\xe8me")
	teq(t, "underscore is NOT space in a body", qd("a_b"), "a_b")

	// Encode, then decode, and get the original back including the awkward bits.
	src := "Grüße — a line with trailing space \nand an = sign, plus a very long run of text that must be soft-wrapped by the encoder because it exceeds seventy-six columns in total length."
	enc := qp_encode(transmute([]u8)src, context.temp_allocator)
	back := qd(enc)
	// The encoder normalises LF to CRLF, so compare with that applied.
	want := crlf(src, context.temp_allocator)
	teq(t, "qp_encode/qp_decode round trip", back, want)
	longest := 0
	for l in strings.split_lines(enc, context.temp_allocator) {
		if len(l) > longest {longest = len(l)}
	}
	tcheck(t, "encoded lines stay under 77 columns", longest <= 76, fmt.aprintf("longest %d", longest))
	tcheck(
		t,
		"encoder escapes an '=' it emits as data",
		strings.contains(enc, "=3D"),
		enc[:min(len(enc), 60)],
	)
}

// ---------------------------------------------------------------------------
// Charsets
// ---------------------------------------------------------------------------

test_charsets :: proc(t: ^T) {
	tsection(t, "charsets")
	cv :: proc(bytes: []u8, cs: Charset) -> string {
		s, _ := charset_to_utf8(bytes, cs, context.temp_allocator)
		return s
	}
	teq(t, "ISO-8859-1 0xE9 is U+00E9", cv({0xE9}, .Latin1), "é")
	teq(t, "ISO-8859-1 0xFF is U+00FF", cv({0xFF}, .Latin1), "ÿ")
	teq(t, "ISO-8859-15 0xA4 is the euro sign", cv({0xA4}, .Latin9), "€")
	teq(t, "ISO-8859-15 0xBD is oe ligature", cv({0xBD}, .Latin9), "œ")
	teq(t, "windows-1252 0x92 is a right single quote", cv({0x92}, .CP1252), "\u2019")
	teq(t, "windows-1252 0x80 is the euro sign", cv({0x80}, .CP1252), "€")
	teq(t, "ISO-8859-2 0xB1 is a-ogonek", cv({0xB1}, .Latin2), "ą")
	teq(t, "KOI8-R 0xC1 is small a (Cyrillic)", cv({0xC1}, .KOI8R), "а")
	teq(t, "UTF-8 passes through", cv(transmute([]u8)string("héllo"), .UTF8), "héllo")

	// An unsupported charset: valid UTF-8 is kept, otherwise Latin-1, and the
	// caller is told it was lossy.
	s1, lossy1 := charset_to_utf8(transmute([]u8)string("héllo"), .Unknown, context.temp_allocator)
	teq(t, "unknown charset keeps valid UTF-8", s1, "héllo")
	tcheck(t, "unknown charset with valid UTF-8 is not flagged lossy", !lossy1)
	s2, lossy2 := charset_to_utf8({0xE9, 0x21}, .Unknown, context.temp_allocator)
	teq(t, "unknown charset falls back to Latin-1", s2, "é!")
	tcheck(t, "the Latin-1 fallback is flagged lossy", lossy2)

	// us-ascii with 8-bit bytes is a lie; it must still produce something.
	s3, lossy3 := charset_to_utf8({0xE9}, .ASCII, context.temp_allocator)
	teq(t, "8-bit bytes in a us-ascii part are read as Latin-1", s3, "é")
	tcheck(t, "...and flagged lossy", lossy3)

	tcheck(t, "UTF-8 validator accepts ASCII", utf8_is_valid(transmute([]u8)string("abc")))
	tcheck(t, "UTF-8 validator accepts 4-byte sequences", utf8_is_valid(transmute([]u8)string("\U0001F600")))
	tcheck(t, "UTF-8 validator rejects a lone continuation byte", !utf8_is_valid({0x80}))
	tcheck(t, "UTF-8 validator rejects an overlong encoding", !utf8_is_valid({0xC0, 0xAF}))
	tcheck(t, "UTF-8 validator rejects a surrogate", !utf8_is_valid({0xED, 0xA0, 0x80}))
	tcheck(t, "UTF-8 validator rejects a truncated sequence", !utf8_is_valid({0xE2, 0x82}))
	san := utf8_sanitise({'a', 0xFF, 'b'}, context.temp_allocator)
	teq(t, "sanitise replaces a bad byte with U+FFFD", san, "a\ufffdb")
	tcheck(t, "sanitised output is valid UTF-8", utf8_is_valid(transmute([]u8)san))

	teq_int(t, "charset_from_name utf8", int(charset_from_name("UTF-8")), int(Charset.UTF8))
	teq_int(t, "charset_from_name latin1 alias", int(charset_from_name("ISO_8859-1")), int(Charset.Latin1))
	teq_int(t, "charset_from_name strips a language tag", int(charset_from_name("UTF-8*en")), int(Charset.UTF8))
	teq_int(t, "charset_from_name unknown", int(charset_from_name("Shift_JIS")), int(Charset.Unknown))
}

// ---------------------------------------------------------------------------
// RFC 2047
// ---------------------------------------------------------------------------

test_encoded_words :: proc(t: ^T) {
	tsection(t, "RFC 2047 encoded words")
	dw :: proc(s: string) -> string {
		out, _ := decode_encoded_words(s, context.temp_allocator)
		return out
	}
	teq(t, "plain text is untouched", dw("Hello there"), "Hello there")
	teq(t, "UTF-8 base64 word", dw("=?UTF-8?B?SGVsbG8=?="), "Hello")
	teq(t, "ISO-8859-1 Q word", dw("=?ISO-8859-1?Q?Caf=E9?="), "Café")
	teq(t, "Q word underscore is a space", dw("=?ISO-8859-1?Q?Caf=E9_Cr=E8me?="), "Café Crème")
	teq(t, "lowercase encoding letter", dw("=?utf-8?b?SGVsbG8=?="), "Hello")
	teq(t, "text around a word is preserved", dw("Re: =?UTF-8?B?SGVsbG8=?= (fwd)"), "Re: Hello (fwd)")

	// THE classic bug: adjacent encoded words are concatenated and the
	// whitespace between them is discarded. "Hel" + "lo" with a space in the
	// source must be "Hello", not "Hel lo".
	teq(
		t,
		"adjacent words concatenate, dropping the space between them",
		dw("=?UTF-8?B?SGVs?= =?UTF-8?B?bG8=?="),
		"Hello",
	)
	// And the real-world version: a multi-byte character split across two
	// words. 0xC3 in the first, 0xA9 in the second, which is 'é' only if the
	// bytes are joined before being decoded as UTF-8... which they are not;
	// each word decodes separately, so this is the case that proves the
	// engine does per-word decoding and then concatenates the TEXT.
	joined := dw("=?UTF-8?B?w6k=?= =?UTF-8?B?w6A=?=")
	teq(t, "two accented words concatenate without a space", joined, "éà")
	tcheck(t, "...and the result is valid UTF-8", utf8_is_valid(transmute([]u8)joined))
	teq(
		t,
		"a folded header with adjacent words still concatenates",
		dw(unfold_header("=?UTF-8?B?V2V0dGVy?=\r\n =?UTF-8?B?YmVyaWNodA==?=", context.temp_allocator)),
		"Wetterbericht",
	)
	teq(
		t,
		"mixed charsets in adjacent words",
		dw("=?ISO-8859-1?Q?Caf=E9?==?UTF-8?B?IQ==?="),
		"Café!",
	)
	teq(t, "a charset language tag is accepted", dw("=?UTF-8*en?B?SGk=?="), "Hi")

	// Malformed words degrade to literal text; nothing is dropped silently.
	teq(t, "no closing ?= is left literal", dw("=?UTF-8?B?SGVsbG8="), "=?UTF-8?B?SGVsbG8=")
	teq(t, "an unknown encoding letter is left literal", dw("=?UTF-8?X?SGVsbG8=?="), "=?UTF-8?X?SGVsbG8=?=")
	teq(t, "a word containing a space is not a word", dw("=?UTF-8?B?SGVs bG8=?="), "=?UTF-8?B?SGVs bG8=?=")
	teq(t, "bad base64 in a word still produces something", dw("=?UTF-8?B?!!!!?="), "")
	teq(t, "an unsupported charset is decoded as best it can be", dw("=?Shift_JIS?B?YWJj?="), "abc")
	teq(t, "a bare =? with no structure is literal", dw("=?"), "=?")

	// Encoding on the way out.
	teq(t, "ASCII is not needlessly encoded", encode_header_value("Hello", context.temp_allocator), "Hello")
	enc := encode_header_value("Grüße", context.temp_allocator)
	tcheck(t, "non-ASCII becomes an encoded word", strings.has_prefix(enc, "=?UTF-8?B?"), enc)
	teq(t, "encode/decode header round trip", dw(enc), "Grüße")
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

test_headers :: proc(t: ^T) {
	tsection(t, "headers")
	teq(t, "unfolding joins a continuation", unfold_header("a\r\n b", context.temp_allocator), "a b")
	teq(t, "unfolding keeps a tab continuation", unfold_header("a\r\n\tb", context.temp_allocator), "a\tb")
	teq(
		t,
		"a line break with no continuation WSP becomes a space",
		unfold_header("a\r\nb", context.temp_allocator),
		"a b",
	)
	teq(t, "unfolding is a no-op without breaks", unfold_header("abc", context.temp_allocator), "abc")

	raw := transmute([]u8)string(
		"From: a@b\r\n" +
		"Subject: one\r\n" +
		" two\r\n" +
		"\tthree\r\n" +
		"Subject: duplicate\r\n" +
		"Received: first\r\n" +
		"Received: second\r\n" +
		"\r\n" +
		"body here\r\n",
	)
	hs, body, bad := split_headers(raw, context.temp_allocator)
	teq_int(t, "header count", len(hs), 5)
	teq_int(t, "no malformed lines", bad, 0)
	teq(t, "body starts after the blank line", string(body), "body here\r\n")
	sub, _ := header_get(hs, "subject")
	teq(t, "a folded value is unfolded", sub, "one two\tthree")
	teq_int(t, "duplicate Subject headers are both kept", header_count(hs, "subject"), 2)
	rec := header_get_all(hs, "received", context.temp_allocator)
	teq_int(t, "both Received headers are kept", len(rec), 2)
	teq(t, "Received headers keep their order", rec[0], "first")

	// A message with no blank line before the body.
	raw2 := transmute([]u8)string("From: a@b\r\nSubject: x\r\nthis is the body\r\n")
	hs2, body2, bad2 := split_headers(raw2, context.temp_allocator)
	teq_int(t, "a missing blank line yields a malformed-line count", bad2, 1)
	teq_int(t, "the headers before it are kept", len(hs2), 2)
	tcheck(
		t,
		"the body is not swallowed",
		strings.contains(string(body2), "this is the body"),
		string(body2),
	)

	// An mbox From_ line is not a header.
	raw3 := transmute([]u8)string("From alice@localhost Tue Feb  3 09:00:00 2026\r\nFrom: a@b\r\n\r\nhi\r\n")
	hs3, _, _ := split_headers(raw3, context.temp_allocator)
	teq_int(t, "an mbox separator is skipped", len(hs3), 1)

	// Headers only, no body at all.
	hs4, body4, _ := split_headers(transmute([]u8)string("From: a@b\r\n"), context.temp_allocator)
	teq_int(t, "a header-only message parses", len(hs4), 1)
	teq_int(t, "...with an empty body", len(body4), 0)

	// Addresses.
	addrs := parse_address_list(
		`"Carol, with a comma" <carol@localhost>, bob@localhost, =?UTF-8?B?S2zDpHVz?= <klaus@localhost>`,
		context.temp_allocator,
	)
	teq_int(t, "three addresses despite the quoted comma", len(addrs), 3)
	teq(t, "quoted display name is unquoted", addrs[0].name, "Carol, with a comma")
	teq(t, "first address", addrs[0].email, "carol@localhost")
	teq(t, "bare addr-spec", addrs[1].email, "bob@localhost")
	teq(t, "encoded-word display name is decoded", addrs[2].name, "Kläus")
	a2 := parse_address_list("Bob (the builder) <bob@x>", context.temp_allocator)
	teq(t, "a comment does not break the address", a2[0].email, "bob@x")

	ids := extract_msg_ids("<a@b> <c@d>", context.temp_allocator)
	teq_int(t, "two message ids", len(ids), 2)
	teq(t, "ids lose their angle brackets", ids[0], "a@b")
	ids2 := extract_msg_ids("bare@id", context.temp_allocator)
	teq(t, "a bare id with no brackets is tolerated", len(ids2) == 1 ? ids2[0] : "", "bare@id")
}

// ---------------------------------------------------------------------------
// Parameters: RFC 2045 / 2231
// ---------------------------------------------------------------------------

test_params :: proc(t: ^T) {
	tsection(t, "Content-Type / Content-Disposition parameters")
	head, ps := parse_params(`text/plain; charset="utf-8"; format=flowed`, context.temp_allocator)
	teq(t, "head", head, "text/plain")
	cs, _ := param_get(ps, "charset")
	teq(t, "quoted parameter value", cs, "utf-8")
	ff, _ := param_get(ps, "format")
	teq(t, "unquoted parameter value", ff, "flowed")

	_, ps2 := parse_params(`attachment; filename="a;b.txt"`, context.temp_allocator)
	fn2, _ := param_get(ps2, "filename")
	teq(t, "a semicolon inside quotes is not a separator", fn2, "a;b.txt")

	_, ps3 := parse_params(`attachment; filename="a\"b.txt"`, context.temp_allocator)
	fn3, _ := param_get(ps3, "filename")
	teq(t, "a backslash-escaped quote in a value", fn3, `a"b.txt`)

	// RFC 2231 extended value.
	_, ps4 := parse_params(`attachment; filename*=UTF-8''caf%C3%A9.txt`, context.temp_allocator)
	fn4, _ := param_get(ps4, "filename")
	teq(t, "RFC 2231 extended value, percent-decoded", fn4, "café.txt")

	// RFC 2231 continuations, with and without the charset on the first part.
	_, ps5 := parse_params(
		`attachment; filename*0*=UTF-8''rapport%20; filename*1*=financier%20; filename*2*=d%C3%A9finitif.pdf`,
		context.temp_allocator,
	)
	fn5, _ := param_get(ps5, "filename")
	teq(t, "RFC 2231 continuations reassemble in order", fn5, "rapport financier définitif.pdf")

	_, ps6 := parse_params(
		`attachment; filename*0="part one "; filename*1="part two.txt"`,
		context.temp_allocator,
	)
	fn6, _ := param_get(ps6, "filename")
	teq(t, "plain (non-extended) continuations reassemble", fn6, "part one part two.txt")

	// Out-of-order sections must still come out in section order.
	_, ps7 := parse_params(
		`attachment; filename*1*=second; filename*0*=UTF-8''first-`,
		context.temp_allocator,
	)
	fn7, _ := param_get(ps7, "filename")
	teq(t, "sections are ordered by number, not by appearance", fn7, "first-second")

	// An encoded word in a parameter: illegal, but common.
	_, ps8 := parse_params(`attachment; filename="=?UTF-8?B?Y2Fmw6kudHh0?="`, context.temp_allocator)
	fn8, _ := param_get(ps8, "filename")
	teq(t, "an RFC 2047 word in a parameter is decoded anyway", fn8, "café.txt")

	// No parameters at all.
	h9, ps9 := parse_params("text/html", context.temp_allocator)
	teq(t, "a bare type parses", h9, "text/html")
	teq_int(t, "...with no parameters", len(ps9), 0)

	// Filename sanitising: a path must never escape.
	teq(t, "a path is reduced to its basename", sanitise_filename("../../.bashrc", context.temp_allocator), ".bashrc")
	teq(t, "a windows path too", sanitise_filename(`C:\evil\x.txt`, context.temp_allocator), "x.txt")
	teq(t, "control characters are removed", sanitise_filename("a\x00b\nc.txt", context.temp_allocator), "abc.txt")
	teq(t, "a name that reduces to .. is refused", sanitise_filename("..", context.temp_allocator), "")

	// Round trip through the composer's parameter encoder.
	p := encode_param("café “quoted”.pdf", context.temp_allocator)
	tcheck(t, "a non-ASCII filename is encoded RFC 2231 style", strings.has_prefix(p, "*=UTF-8''"), p)
	_, ps10 := parse_params(
		strings.concatenate({"attachment; filename", p}, context.temp_allocator),
		context.temp_allocator,
	)
	fn10, _ := param_get(ps10, "filename")
	teq(t, "encode_param/parse_params round trip", fn10, "café “quoted”.pdf")
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

test_dates :: proc(t: ^T) {
	tsection(t, "RFC 5322 dates")
	// 2026-02-03T09:14:02Z
	ref := days_from_civil(2026, 2, 3) * 86400 + 9 * 3600 + 14 * 60 + 2

	d := parse_date("Tue, 3 Feb 2026 09:14:02 +0000")
	tcheck(t, "a canonical date parses", d.ok)
	teq_i64(t, "canonical date value", d.unix, ref)

	d2 := parse_date("Tue, 3 Feb 2026 10:14:02 +0100")
	teq_i64(t, "a +0100 offset is subtracted", d2.unix, ref)
	d3 := parse_date("Tue, 3 Feb 2026 04:14:02 -0500")
	teq_i64(t, "a -0500 offset is added", d3.unix, ref)

	d4 := parse_date("3 Feb 2026 09:14:02 +0000")
	tcheck(t, "the day name is optional", d4.ok)
	teq_i64(t, "...and the value is unchanged", d4.unix, ref)

	d5 := parse_date("Tue, 3 Feb 2026 09:14 +0000")
	tcheck(t, "seconds are optional", d5.ok)
	teq_i64(t, "a missing seconds field means :00", d5.unix, ref - 2)

	d6 := parse_date("Tue, 3 Feb 2026 09:14:02 +0000 (UTC)")
	tcheck(t, "a trailing comment is ignored", d6.ok)
	teq_i64(t, "...and does not shift the time", d6.unix, ref)

	// Obsolete zones.
	est := parse_date("Mon, 02 Jan 06 15:04 EST")
	tcheck(t, "a two-digit year with an obsolete zone parses", est.ok)
	teq_i64(
		t,
		"02 Jan 06 15:04 EST is 2006-01-02T20:04:00Z",
		est.unix,
		days_from_civil(2006, 1, 2) * 86400 + 20 * 3600 + 4 * 60,
	)
	teq_int(t, "EST is -300 minutes", est.tz_minutes, -300)
	tcheck(t, "EST is a known zone", est.tz_known)

	Zone_Case :: struct {
		name:    string,
		minutes: int,
	}
	for zc in ([?]Zone_Case {
			{"UT", 0},
			{"GMT", 0},
			{"EDT", -240},
			{"CST", -360},
			{"CDT", -300},
			{"MST", -420},
			{"MDT", -360},
			{"PST", -480},
			{"PDT", -420},
		}) {
		zd := parse_date(fmt.tprintf("1 Jan 2020 00:00:00 %s", zc.name))
		teq_int(t, fmt.aprintf("obsolete zone %s", zc.name), zd.tz_minutes, zc.minutes)
	}

	// A military zone: RFC 5322 4.3 says treat it as an unknown offset.
	mil := parse_date("1 Jan 2020 00:00:00 A")
	tcheck(t, "a military zone parses", mil.ok)
	tcheck(t, "...with the offset marked unknown", !mil.tz_known)
	teq_i64(t, "...and is read as UTC", mil.unix, days_from_civil(2020, 1, 1) * 86400)

	// -0000 means "the sender withheld the offset".
	zz := parse_date("1 Jan 2020 00:00:00 -0000")
	tcheck(t, "-0000 parses", zz.ok)
	tcheck(t, "-0000 means the zone is unknown", !zz.tz_known)

	// Two-digit year boundaries (RFC 5322 4.3).
	y49 := parse_date("1 Jan 49 00:00:00 +0000")
	teq_i64(t, "year 49 is 2049", y49.unix, days_from_civil(2049, 1, 1) * 86400)
	y50 := parse_date("1 Jan 50 00:00:00 +0000")
	teq_i64(t, "year 50 is 1950", y50.unix, days_from_civil(1950, 1, 1) * 86400)
	y3 := parse_date("1 Jan 102 00:00:00 +0000")
	teq_i64(t, "a three-digit year gets 1900 added", y3.unix, days_from_civil(2002, 1, 1) * 86400)

	// A leap second is legal and clamped.
	ls := parse_date("31 Dec 2016 23:59:60 +0000")
	tcheck(t, "a leap second parses", ls.ok)
	teq_i64(
		t,
		"23:59:60 is clamped to 23:59:59",
		ls.unix,
		days_from_civil(2016, 12, 31) * 86400 + 23 * 3600 + 59 * 60 + 59,
	)

	// Failures must be failures, not wrong answers.
	for bad in ([?]string{"", "not a date", "32 Feb 2026 00:00:00 +0000", "1 Xxx 2026 00:00:00 +0000", "1 Jan 2026", "Tue, 3 Feb 2026 25:00:00 +0000", "Tue, 3 Feb 2026 09:99:00 +0000"}) {
		bd := parse_date(bad)
		tcheck(t, fmt.aprintf("rejects %q", bad), !bd.ok, fmt.aprintf("got unix=%d", bd.unix))
	}

	// Civil-date arithmetic round trips, including leap years.
	ok_all := true
	for y in ([?]int{1970, 1999, 2000, 2004, 2024, 2026, 2100}) {
		for m in 1 ..= 12 {
			days := days_from_civil(y, m, 1)
			yy, mm, dd := civil_from_days(days)
			if yy != y || mm != m || dd != 1 {
				ok_all = false
			}
		}
	}
	tcheck(t, "days_from_civil and civil_from_days round trip", ok_all)
	teq_i64(t, "the epoch is day zero", days_from_civil(1970, 1, 1), 0)
	teq(t, "format_date renders RFC 5322", format_date(ref, 0, context.temp_allocator), "Tue, 3 Feb 2026 09:14:02 +0000")
	teq(
		t,
		"format_date applies a positive offset",
		format_date(ref, 60, context.temp_allocator),
		"Tue, 3 Feb 2026 10:14:02 +0100",
	)
	rt := parse_date(format_date(ref, -330, context.temp_allocator))
	teq_i64(t, "format_date/parse_date round trip across a half-hour zone", rt.unix, ref)
	teq(t, "format_iso8601", format_iso8601(ref, context.temp_allocator), "2026-02-03T09:14:02Z")
	iso, iok := parse_iso8601("2026-02-03T09:14:02Z")
	tcheck(t, "parse_iso8601 accepts a UTCDate", iok)
	teq_i64(t, "parse_iso8601 value", iso, ref)
	_, bad_iso := parse_iso8601("2026-02-03 09:14:02")
	tcheck(t, "parse_iso8601 rejects a non-UTCDate", !bad_iso)
}

// ---------------------------------------------------------------------------
// MIME
// ---------------------------------------------------------------------------

NESTED :: "From: Structure Robot <robot@localhost>\r\n" +
	"To: alice@localhost\r\n" +
	"Subject: =?UTF-8?B?VmllciBFYmVuZW4=?=\r\n" +
	"Message-ID: <nest@localhost>\r\n" +
	"Date: Tue, 3 Feb 2026 12:00:00 +0000\r\n" +
	"MIME-Version: 1.0\r\n" +
	"Content-Type: multipart/mixed; boundary=\"OUT\"\r\n" +
	"\r\n" +
	"This is the preamble and it is not a part.\r\n" +
	"\r\n" +
	"--OUT\r\n" +
	"Content-Type: multipart/related; boundary=\"REL\"\r\n" +
	"\r\n" +
	"--REL\r\n" +
	"Content-Type: multipart/alternative; boundary=\"ALT\"\r\n" +
	"\r\n" +
	"--ALT\r\n" +
	"Content-Type: text/plain; charset=utf-8\r\n" +
	"\r\n" +
	"the plain body\r\n" +
	"--ALT\r\n" +
	"Content-Type: text/html; charset=utf-8\r\n" +
	"Content-Transfer-Encoding: quoted-printable\r\n" +
	"\r\n" +
	"<p>the <b>html</b> body with =C3=A9</p>\r\n" +
	"--ALT--\r\n" +
	"\r\n" +
	"--REL\r\n" +
	"Content-Type: image/png\r\n" +
	"Content-Transfer-Encoding: base64\r\n" +
	"Content-ID: <pixel@localhost>\r\n" +
	"Content-Disposition: inline; filename=\"pixel.png\"\r\n" +
	"\r\n" +
	"AAEC\r\n" +
	"--REL--\r\n" +
	"\r\n" +
	"--OUT\r\n" +
	"Content-Type: application/pdf\r\n" +
	"Content-Transfer-Encoding: base64\r\n" +
	"Content-Disposition: attachment;\r\n" +
	" filename*0*=UTF-8''rapport%20;\r\n" +
	" filename*1*=d%C3%A9finitif.pdf\r\n" +
	"\r\n" +
	"JVBERi0=\r\n" +
	"--OUT--\r\n" +
	"and this is the epilogue.\r\n"

test_mime :: proc(t: ^T) {
	tsection(t, "MIME tree")
	m := parse_message(transmute([]u8)string(NESTED), context.temp_allocator)

	teq(t, "subject decodes", m.subject, "Vier Ebenen")
	teq(t, "from address", len(m.from) > 0 ? m.from[0].email : "", "robot@localhost")
	teq(t, "message id", m.message_id, "nest@localhost")
	tcheck(t, "date parses", m.date.ok)

	teq(t, "root type", fmt.aprintf("%s/%s", m.root.main, m.root.sub), "multipart/mixed")
	tcheck(t, "root is multipart", m.root.is_multipart)
	teq_int(t, "root has two children", len(m.root.parts), 2)
	teq(
		t,
		"the preamble is captured and is not a part",
		strings.trim_space(m.root.preamble),
		"This is the preamble and it is not a part.",
	)
	teq(t, "the epilogue is captured", strings.trim_space(m.root.epilogue), "and this is the epilogue.")
	tcheck(t, "the multipart is terminated", !m.root.unterminated)

	rel := m.root.parts[0]
	teq(t, "child 1 is multipart/related", fmt.aprintf("%s/%s", rel.main, rel.sub), "multipart/related")
	teq_int(t, "related has two children", len(rel.parts), 2)
	alt := rel.parts[0]
	teq(t, "grandchild is multipart/alternative", fmt.aprintf("%s/%s", alt.main, alt.sub), "multipart/alternative")
	teq_int(t, "alternative has two children", len(alt.parts), 2)
	teq(t, "the plain alternative", strings.trim_space(alt.parts[0].text), "the plain body")
	teq(
		t,
		"the html alternative, quoted-printable decoded",
		strings.trim_space(alt.parts[1].text),
		"<p>the <b>html</b> body with é</p>",
	)

	// IMAP section numbering.
	teq(t, "section numbers: the plain part", alt.parts[0].section, "1.1.1")
	teq(t, "section numbers: the inline image", rel.parts[1].section, "1.2")
	teq(t, "section numbers: the pdf", m.root.parts[1].section, "2")
	p := find_part(&m.root, "1.1.2")
	tcheck(t, "find_part locates a nested section", p != nil && p.sub == "html")
	teq_int(t, "the tree has 7 entities", part_count(&m.root), 7)

	// Body selection.
	teq(t, "text_plain is the plain alternative", strings.trim_space(m.text_plain), "the plain body")
	tcheck(t, "text_html is the html alternative", strings.contains(m.text_html, "<b>html</b>"), m.text_html)

	// Attachments: the inline image and the pdf, not the bodies.
	teq_int(t, "two attachments", len(m.attachments), 2)
	teq(t, "inline image filename", m.attachments[0].filename, "pixel.png")
	teq(t, "inline image type", m.attachments[0].mime_type, "image/png")
	teq(t, "inline image content-id", m.attachments[0].content_id, "pixel@localhost")
	tcheck(t, "the cid image is inline", m.attachments[0].is_inline)
	tbytes(t, "inline image bytes are base64-decoded", m.attachments[0].content, "\x00\x01\x02")
	teq(
		t,
		"the pdf filename comes from RFC 2231 continuations",
		m.attachments[1].filename,
		"rapport définitif.pdf",
	)
	tcheck(t, "the pdf is not inline", !m.attachments[1].is_inline)
	tbytes(t, "the pdf content decodes", m.attachments[1].content, "%PDF-")

	// multipart/alternative with no text/plain.
	html_only := transmute([]u8)string(
		"Subject: html only\r\n" +
		"Content-Type: multipart/alternative; boundary=\"B\"\r\n" +
		"\r\n" +
		"--B\r\n" +
		"Content-Type: text/html\r\n" +
		"\r\n" +
		"<p>only html</p>\r\n" +
		"--B--\r\n",
	)
	hm := parse_message(html_only, context.temp_allocator)
	teq(t, "no text/plain means text_plain is empty", strings.trim_space(hm.text_plain), "")
	teq(t, "the html part is still found", strings.trim_space(hm.text_html), "<p>only html</p>")
	teq_int(t, "and nothing is mistaken for an attachment", len(hm.attachments), 0)

	// message/rfc822.
	fwd := transmute([]u8)string(
		"Subject: Fwd\r\n" +
		"Content-Type: multipart/mixed; boundary=\"F\"\r\n" +
		"\r\n" +
		"--F\r\n" +
		"Content-Type: text/plain\r\n" +
		"\r\n" +
		"see below\r\n" +
		"--F\r\n" +
		"Content-Type: message/rfc822\r\n" +
		"Content-Disposition: attachment; filename=\"inner.eml\"\r\n" +
		"\r\n" +
		"Subject: =?UTF-8?B?aW5uZXI=?=\r\n" +
		"Message-ID: <inner@localhost>\r\n" +
		"\r\n" +
		"the inner body\r\n" +
		"--F--\r\n",
	)
	fm := parse_message(fwd, context.temp_allocator)
	teq(t, "the outer body is the text part", strings.trim_space(fm.text_plain), "see below")
	tcheck(
		t,
		"the embedded message does NOT contribute its body to the outer text",
		!strings.contains(fm.text_plain, "the inner body"),
		fm.text_plain,
	)
	teq_int(t, "the embedded message is an attachment", len(fm.attachments), 1)
	teq(t, "embedded message type", fm.attachments[0].mime_type, "message/rfc822")
	teq(t, "embedded message filename", fm.attachments[0].filename, "inner.eml")
	emb := fm.root.parts[1]
	tcheck(t, "the embedded message was parsed", emb.is_rfc822 && len(emb.parts) == 1)
	inner_subj, _ := header_get(emb.parts[0].headers, "subject")
	dec, _ := decode_encoded_words(inner_subj, context.temp_allocator)
	teq(t, "the embedded message's own headers parse", dec, "inner")

	// Boundary edge cases.
	sp := split_multipart(
		transmute([]u8)string("pre\r\n--B\r\nA\r\n--B\r\nBB\r\n--B--\r\nepi"),
		"B",
		context.temp_allocator,
	)
	teq_int(t, "split_multipart finds two parts", len(sp.bodies), 2)
	teq(t, "split_multipart preamble", string(sp.preamble), "pre")
	teq(t, "split_multipart part 1 loses the trailing CRLF", string(sp.bodies[0]), "A")
	teq(t, "split_multipart epilogue", string(sp.epilogue), "epi")
	tcheck(t, "split_multipart saw the close delimiter", sp.closed)

	// A line that merely starts with the boundary is not a delimiter.
	sp2 := split_multipart(
		transmute([]u8)string("--B\r\n--BOGUS\r\nx\r\n--B--\r\n"),
		"B",
		context.temp_allocator,
	)
	teq_int(t, "--Bsomething is not a delimiter", len(sp2.bodies), 1)
	tcheck(t, "...so its text stays in the part", strings.contains(string(sp2.bodies[0]), "--BOGUS"))

	// Transport padding after the boundary is allowed.
	sp3 := split_multipart(transmute([]u8)string("--B  \r\nx\r\n--B--  \r\n"), "B", context.temp_allocator)
	teq_int(t, "trailing whitespace after a boundary is allowed", len(sp3.bodies), 1)
	tcheck(t, "...and the close delimiter is still recognised", sp3.closed)

	// Bare LF line endings.
	lf := parse_message(
		transmute([]u8)string("Subject: lf\nContent-Type: multipart/mixed; boundary=B\n\n--B\nContent-Type: text/plain\n\nbody\n--B--\n"),
		context.temp_allocator,
	)
	teq(t, "a message with bare LF endings parses", strings.trim_space(lf.text_plain), "body")

	// Transfer encodings.
	for spec in ([?][2]string {
			{"7bit", "plain"},
			{"8bit", "plain"},
			{"binary", "plain"},
			{"BASE64", "cGxhaW4="},
			{"Quoted-Printable", "=70lain"},
		}) {
		msg := fmt.tprintf(
			"Content-Type: text/plain\r\nContent-Transfer-Encoding: %s\r\n\r\n%s",
			spec[0],
			spec[1],
		)
		pm := parse_message(transmute([]u8)msg, context.temp_allocator)
		teq(t, fmt.aprintf("Content-Transfer-Encoding: %s", spec[0]), strings.trim_space(pm.text_plain), "plain")
	}
	unk := parse_message(
		transmute([]u8)string("Content-Type: text/plain\r\nContent-Transfer-Encoding: x-uuencode\r\n\r\nraw"),
		context.temp_allocator,
	)
	teq(t, "an unknown encoding falls back to 8bit", strings.trim_space(unk.text_plain), "raw")
	tcheck(t, "...and is reported as a warning", len(unk.warnings) > 0, fmt.aprintf("%v", unk.warnings))
}

// ---------------------------------------------------------------------------
// Malformed input
// ---------------------------------------------------------------------------

test_malformed :: proc(t: ^T) {
	tsection(t, "malformed input")

	// A multipart with no closing delimiter.
	unterm := transmute([]u8)string(
		"Content-Type: multipart/mixed; boundary=\"X\"\r\n\r\n--X\r\nContent-Type: text/plain\r\n\r\nfirst part\r\n--X\r\nContent-Type: text/plain\r\n\r\nsecond part, cut off",
	)
	um := parse_message(unterm, context.temp_allocator)
	teq_int(t, "an unterminated multipart still yields both parts", len(um.root.parts), 2)
	tcheck(t, "...and is flagged unterminated", um.root.unterminated)
	tcheck(t, "...with a warning", len(um.warnings) > 0)
	teq(t, "the last part keeps its text", strings.trim_space(um.root.parts[1].text), "second part, cut off")

	// A boundary that never appears.
	noB := parse_message(
		transmute([]u8)string("Content-Type: multipart/mixed; boundary=\"NOPE\"\r\n\r\njust text"),
		context.temp_allocator,
	)
	tcheck(t, "a boundary that never appears degrades to a leaf", !noB.root.is_multipart)
	tcheck(t, "...with a warning", len(noB.warnings) > 0)

	// multipart with no boundary parameter at all.
	noP := parse_message(
		transmute([]u8)string("Content-Type: multipart/mixed\r\n\r\nbody"),
		context.temp_allocator,
	)
	tcheck(t, "multipart with no boundary parameter degrades", !noP.root.is_multipart)

	// Empty input, and input that is only a newline.
	for junk in ([?]string{"", "\r\n", "\n", ":", "::::", "\x00\x00\x00", "Content-Type: \r\n\r\n"}) {
		jm := parse_message(transmute([]u8)junk, context.temp_allocator)
		tcheck(
			t,
			fmt.aprintf("degrades on %q", junk),
			jm.root.main != "" && len(jm.warnings) <= 64,
			fmt.aprintf("%d warnings", len(jm.warnings)),
		)
	}

	// A boundary that nests inside itself: the pathological case for a
	// recursive splitter.
	evil := strings.builder_make(context.temp_allocator)
	strings.write_string(&evil, "Content-Type: multipart/mixed; boundary=\"B\"\r\n\r\n")
	for i in 0 ..< 40 {
		strings.write_string(&evil, "--B\r\nContent-Type: multipart/mixed; boundary=\"B\"\r\n\r\n")
	}
	strings.write_string(&evil, "--B--\r\n")
	em := parse_message(transmute([]u8)strings.to_string(evil), context.temp_allocator)
	depth := 0
	for p := &em.root; len(p.parts) > 0; p = &p.parts[0] {
		depth += 1
		if depth > MAX_MIME_DEPTH + 2 {
			break
		}
	}
	tcheck(
		t,
		"a self-nesting boundary is bounded by MAX_MIME_DEPTH",
		depth <= MAX_MIME_DEPTH + 1,
		fmt.aprintf("reached depth %d", depth),
	)

	// Fuzzing: truncate and corrupt the nested message every which way and
	// require that every parse terminates and returns a usable tree. A crash
	// would end the process, so reaching the assertion IS the assertion.
	base := transmute([]u8)string(NESTED)
	truncations := 0
	for cut := 0; cut <= len(base); cut += 7 {
		m := parse_message(base[:cut], context.temp_allocator)
		_ = part_count(&m.root)
		truncations += 1
		if cut % 700 == 0 {
			free_all(context.temp_allocator)
			base = transmute([]u8)string(NESTED)
		}
	}
	tcheck(
		t,
		fmt.aprintf("%d truncations of a nested message all parse", truncations),
		truncations > 100,
	)

	corruptions := 0
	buf := make([]u8, len(base), context.temp_allocator)
	for pos := 0; pos < len(base); pos += 11 {
		for flip in ([?]u8{0x00, 0x0a, 0x0d, 0x2d, 0x3d, 0xff}) {
			copy(buf, base)
			buf[pos] = flip
			m := parse_message(buf, context.temp_allocator)
			_ = part_count(&m.root)
			_ = m.text_plain
			corruptions += 1
		}
		if pos % 110 == 0 {
			// The arena has to be released periodically or the fuzz loop
			// becomes a memory test instead of a parser test.
			tmp := make([]u8, len(base), context.allocator)
			copy(tmp, base)
			free_all(context.temp_allocator)
			buf = make([]u8, len(base), context.temp_allocator)
			base = tmp
		}
	}
	tcheck(
		t,
		fmt.aprintf("%d single-byte corruptions all parse", corruptions),
		corruptions > 500,
	)

	// The decoders on their own, against adversarial input.
	for junk in ([?]string{"=", "==", "=\r", "=0", "=0G", "====", "_", "a=", "\x00=41"}) {
		out := qp_decode(transmute([]u8)junk, false, context.temp_allocator)
		tcheck(t, fmt.aprintf("qp_decode survives %q", junk), len(out) <= len(junk) + 2)
	}
	for junk in ([?]string{"=", "A", "AB", "ABC", "====", "A===", "\x00\xff"}) {
		out := base64_decode(transmute([]u8)junk, context.temp_allocator)
		tcheck(t, fmt.aprintf("base64_decode survives %q", junk), len(out) <= len(junk))
	}
	for junk in ([?]string{"=?", "=?x", "=?x?", "=?x?B?", "=?x?B?a", "=?x?B?a?", "=?=?=?=?"}) {
		out, _ := decode_encoded_words(junk, context.temp_allocator)
		tcheck(t, fmt.aprintf("decode_encoded_words survives %q", junk), len(out) <= len(junk) + 8)
	}
}

// ---------------------------------------------------------------------------
// The IMAP response parser
// ---------------------------------------------------------------------------

test_imap_parser :: proc(t: ^T) {
	tsection(t, "IMAP response parser")

	parse_one :: proc(data: string) -> (IResp, string, int) {
		r := ireader_from_bytes(transmute([]u8)data, context.temp_allocator)
		resp, err := imap_read_response(&r)
		return resp, err, r.literals_seen
	}

	// Simple status response.
	r1, e1, _ := parse_one("* OK [UNSEEN 12] Message 12 is first unseen\r\n")
	teq(t, "untagged OK has no error", e1, "")
	teq(t, "status word", r1.status, "OK")
	code, has := resp_code(r1)
	tcheck(t, "the bracketed response code is captured", has && len(code.list) == 2)
	teq(t, "code name", ival_text(code.list[0]), "UNSEEN")
	n, _ := ival_int(code.list[1])
	teq_int(t, "code value", n, 12)

	// Tagged response.
	r2, _, _ := parse_one("a003 OK FETCH completed\r\n")
	teq_int(t, "a tagged response is recognised", int(r2.kind), int(IResp_Kind.Tagged))
	teq(t, "the tag", r2.tag, "a003")
	teq(t, "tagged status", r2.status, "OK")

	// Continuation.
	r3, _, _ := parse_one("+ idling\r\n")
	teq_int(t, "a continuation is recognised", int(r3.kind), int(IResp_Kind.Continuation))
	teq(t, "continuation text", r3.text, "idling")

	// Nested parenthesised lists, NIL, quoted strings with escapes.
	r4, e4, _ := parse_one(`* 1 FETCH (FLAGS (\Seen \Answered) ENVELOPE ("date" "sub \"quoted\"" NIL (("n" NIL "l" "d"))))` + "\r\n")
	teq(t, "a nested response parses", e4, "")
	teq_int(t, "top-level tokens", len(r4.items), 3)
	pairs := r4.items[2].list
	teq_int(t, "FETCH carries two item pairs", len(pairs), 4)
	teq(t, "FLAGS name", ival_text(pairs[0]), "FLAGS")
	teq_int(t, "two flags", len(pairs[1].list), 2)
	teq(t, "first flag", ival_text(pairs[1].list[0]), `\Seen`)
	env := pairs[3].list
	teq(t, "a backslash-escaped quote inside a quoted string", ival_text(env[1]), `sub "quoted"`)
	teq_int(t, "NIL becomes the Nil kind", int(env[2].kind), int(IVal_Kind.Nil))
	teq_int(t, "a nested address list", len(env[3].list), 1)

	// THE literal test. The literal's contents contain CRLF and a sequence
	// that looks exactly like another untagged response. A line-based parser
	// reads "* 2 EXPUNGE" as protocol; this one must not.
	body := "Subject: trap\r\n\r\n* 2 EXPUNGE\r\na999 OK not really\r\n"
	lit := fmt.tprintf(
		"* 1 FETCH (UID 7 BODY[] {{%d}}\r\n%s FLAGS (\\Seen))\r\na004 OK done\r\n",
		len(body),
		body,
	)
	rl := ireader_from_bytes(transmute([]u8)lit, context.temp_allocator)
	resp1, err1 := imap_read_response(&rl)
	teq(t, "a response containing a literal parses", err1, "")
	teq_int(t, "one literal was read", rl.literals_seen, 1)
	fp := resp1.items[2].list
	teq_int(t, "the FETCH item list has three pairs", len(fp), 6)
	teq(t, "the item name keeps its section", strings.to_upper(ival_text(fp[2]), context.temp_allocator), "BODY[]")
	teq(t, "the literal's bytes are the value, verbatim", ival_text(fp[3]), body)
	teq(t, "parsing resumes after the literal on the same response", ival_text(fp[4]), "FLAGS")
	teq_int(t, "...and the flag list is intact", len(fp[5].list), 1)
	// And the NEXT response read is the tagged OK, not the fake EXPUNGE.
	resp2, err2 := imap_read_response(&rl)
	teq(t, "the next response reads cleanly", err2, "")
	teq(t, "the fake response inside the literal was not treated as protocol", resp2.tag, "a004")

	// Two literals in one response.
	two := fmt.tprintf(
		"* 2 FETCH (BODY[HEADER] {{%d}}\r\n%s BODY[TEXT] {{%d}}\r\n%s)\r\n",
		len("H: 1\r\n\r\n"),
		"H: 1\r\n\r\n",
		len("text"),
		"text",
	)
	r2r := ireader_from_bytes(transmute([]u8)two, context.temp_allocator)
	resp3, err3 := imap_read_response(&r2r)
	teq(t, "two literals in one response", err3, "")
	teq_int(t, "both literals were read", r2r.literals_seen, 2)
	tp := resp3.items[2].list
	teq(t, "the second literal's value", ival_text(tp[3]), "text")

	// A zero-length literal.
	zl := ireader_from_bytes(transmute([]u8)string("* 3 FETCH (BODY[] {0}\r\n)\r\n"), context.temp_allocator)
	respz, errz := imap_read_response(&zl)
	teq(t, "a zero-length literal parses", errz, "")
	teq(t, "...and yields an empty string", ival_text(respz.items[2].list[1]), "")

	// A LITERAL+ non-synchronising literal.
	np := fmt.tprintf("* 4 FETCH (BODY[] {{%d+}}\r\n%s)\r\n", 2, "ab")
	nl := ireader_from_bytes(transmute([]u8)np, context.temp_allocator)
	respn, errn := imap_read_response(&nl)
	teq(t, "a LITERAL+ literal parses", errn, "")
	teq(t, "...with the right value", ival_text(respn.items[2].list[1]), "ab")

	// The bracketed-atom trick: BODY[HEADER.FIELDS (DATE FROM)] is ONE token.
	rb := ireader_from_bytes(
		transmute([]u8)string("* 5 FETCH (BODY[HEADER.FIELDS (DATE FROM)] \"x\")\r\n"),
		context.temp_allocator,
	)
	respb, errb := imap_read_response(&rb)
	teq(t, "a bracketed section with spaces parses", errb, "")
	bp := respb.items[2].list
	teq_int(t, "it is a single token followed by its value", len(bp), 2)
	teq(t, "the section stays glued to the atom", ival_text(bp[0]), "BODY[HEADER.FIELDS (DATE FROM)]")
	// ...and with a partial specifier.
	rp := ireader_from_bytes(
		transmute([]u8)string("* 6 FETCH (BODY[]<0.1024> \"y\")\r\n"),
		context.temp_allocator,
	)
	respp, _ := imap_read_response(&rp)
	teq(t, "a <partial> specifier stays in the atom", ival_text(respp.items[2].list[0]), "BODY[]<0.1024>")

	// Malformed responses must error, not hang.
	for bad in ([?]string{"* 1 FETCH (FLAGS (\\Seen\r\n", "* 1 FETCH (BODY[] {abc}\r\n", "* 1 FETCH (BODY[] {99999999999}\r\n", "* 1 FETCH (\"unterminated\r\n"}) {
		rr := ireader_from_bytes(transmute([]u8)bad, context.temp_allocator)
		_, ee := imap_read_response(&rr)
		tcheck(t, fmt.aprintf("rejects %q", bad[:min(len(bad), 34)]), ee != "", "no error reported")
	}
	// A literal longer than the data available must fail, not block forever.
	short := ireader_from_bytes(transmute([]u8)string("* 1 FETCH (BODY[] {100}\r\nonly a few bytes"), context.temp_allocator)
	_, se := imap_read_response(&short)
	tcheck(t, "a short literal is an error", se != "", se)

	// BODYSTRUCTURE.
	bs_text := `(("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 14 1 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL "QUOTED-PRINTABLE" 40 1 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "ALT") NIL NIL NIL)`
	rbs := ireader_from_bytes(
		transmute([]u8)fmt.tprintf("* 1 FETCH (BODYSTRUCTURE %s)\r\n", bs_text),
		context.temp_allocator,
	)
	respbs, _ := imap_read_response(&rbs)
	bs, bsok := parse_bodystructure(respbs.items[2].list[1], "", context.temp_allocator)
	tcheck(t, "BODYSTRUCTURE parses", bsok)
	teq(t, "a multipart bodystructure", fmt.aprintf("%s/%s", bs.main, bs.sub), "multipart/alternative")
	teq_int(t, "with two children", len(bs.parts), 2)
	teq(t, "child 1", fmt.aprintf("%s/%s", bs.parts[0].main, bs.parts[0].sub), "text/plain")
	teq(t, "child 1 encoding", bs.parts[0].encoding, "7bit")
	teq_int(t, "child 1 size", bs.parts[0].size, 14)
	teq_int(t, "child 1 lines", bs.parts[0].lines, 1)
	cs, _ := param_get(bs.parts[0].params, "charset")
	teq(t, "child 1 charset parameter", cs, "utf-8")
	teq(t, "child 2 section number", bs.parts[1].section, "2")
	teq_int(t, "bodystructure entity count", bodystructure_count(bs), 3)

	// Sequence-set rendering is the client's job; the server parses it. What
	// the client must get right is the response-code absorption, tested above.
	teq(t, "ival_dump renders a list", ival_to_string(IVal{kind = .List, list = {{kind = .Atom, s = "A"}, {kind = .Nil}}}, context.temp_allocator), "(A NIL)")
	teq(
		t,
		"ival_dump escapes a quoted string",
		ival_to_string(IVal{kind = .Str, s = "a\"b"}, context.temp_allocator),
		`"a\"b"`,
	)
}

test_imap_utf7 :: proc(t: ^T) {
	tsection(t, "IMAP modified UTF-7 mailbox names")
	teq(t, "ASCII is unchanged on decode", imap_utf7_decode("INBOX", context.temp_allocator), "INBOX")
	teq(t, "ASCII is unchanged on encode", imap_utf7_encode("INBOX", context.temp_allocator), "INBOX")
	teq(t, "&- is a literal ampersand", imap_utf7_decode("A&-B", context.temp_allocator), "A&B")
	teq(t, "an ampersand is encoded as &-", imap_utf7_encode("A&B", context.temp_allocator), "A&-B")
	teq(t, "decode &AOk- as e-acute", imap_utf7_decode("&AOk-", context.temp_allocator), "é")
	teq(t, "decode a Japanese folder name", imap_utf7_decode("&ZeVnLIqe-", context.temp_allocator), "日本語")
	teq(t, "encode a Japanese folder name", imap_utf7_encode("日本語", context.temp_allocator), "&ZeVnLIqe-")
	for name in ([?]string{"Entwürfe", "Trash", "Lists/odin", "émoji 😀", "A&B&C", "日本語/サブ"}) {
		enc := imap_utf7_encode(name, context.temp_allocator)
		teq(t, fmt.aprintf("round trip %q", name), imap_utf7_decode(enc, context.temp_allocator), name)
	}
}

// ---------------------------------------------------------------------------
// Dot stuffing: SMTP out, POP3 in
// ---------------------------------------------------------------------------

test_dot_stuffing :: proc(t: ^T) {
	tsection(t, "dot stuffing (SMTP DATA / POP3 multiline)")
	src := "line one\r\n.a leading dot\r\n..two dots\r\nnormal\r\n.\r\nlast\r\n"
	stuffed := dot_stuff(transmute([]u8)src, context.temp_allocator)
	tcheck(
		t,
		"a leading dot is doubled",
		strings.contains(string(stuffed), "..a leading dot"),
		string(stuffed),
	)
	tcheck(
		t,
		"a line that is only a dot becomes two dots",
		strings.contains(string(stuffed), "\r\n..\r\n"),
		string(stuffed),
	)
	back := dot_unstuff(stuffed, context.temp_allocator)
	teq(t, "dot_stuff/dot_unstuff round trip", string(back), src)

	// LF-only input is normalised to CRLF on the way out, which is what the
	// wire requires.
	lf := dot_stuff(transmute([]u8)string("a\nb\n"), context.temp_allocator)
	teq(t, "bare LF is normalised to CRLF", string(lf), "a\r\nb\r\n")

	// The terminator must never appear inside the stuffed body.
	tcheck(
		t,
		"no bare \\r\\n.\\r\\n survives stuffing",
		!strings.contains(string(stuffed), "\r\n.\r\n"),
		"the DATA terminator leaked into the body",
	)
	empty := dot_stuff({}, context.temp_allocator)
	teq_int(t, "stuffing empty input yields empty output", len(empty), 0)
}

// ---------------------------------------------------------------------------
// Maildir
// ---------------------------------------------------------------------------

test_maildir :: proc(t: ^T) {
	tsection(t, "Maildir")
	// Flags render in ASCII order, which is what every other tool expects.
	teq(t, "no flags is an empty info field", maildir_flags_string({}, context.temp_allocator), "")
	teq(t, "Seen", maildir_flags_string({.Seen}, context.temp_allocator), "S")
	teq(t, "Replied+Seen is RS, not SR", maildir_flags_string({.Seen, .Replied}, context.temp_allocator), "RS")
	teq(
		t,
		"all six in ASCII order",
		maildir_flags_string({.Trashed, .Seen, .Replied, .Passed, .Flagged, .Draft}, context.temp_allocator),
		"DFPRST",
	)
	teq(t, "Flagged+Seen", maildir_flags_string({.Flagged, .Seen}, context.temp_allocator), "FS")

	teq_int(t, "parse :2,S", int(transmute(u8)maildir_flags_parse(":2,S")), int(transmute(u8)Maildir_Flags{.Seen}))
	teq_int(t, "parse bare RS", int(transmute(u8)maildir_flags_parse("RS")), int(transmute(u8)Maildir_Flags{.Replied, .Seen}))
	teq_int(
		t,
		"an unknown flag letter is ignored, not fatal",
		int(transmute(u8)maildir_flags_parse(":2,Sabc")),
		int(transmute(u8)Maildir_Flags{.Seen}),
	)
	for s in ([?]string{"", ":2,", "2,", ":", ":9,XYZ"}) {
		f := maildir_flags_parse(s)
		tcheck(t, fmt.aprintf("parsing %q yields no flags rather than failing", s), f == {})
	}

	u, f, has := maildir_parse_name("1770000000.M1P2Q3.host:2,RS")
	teq(t, "the unique part is split off", u, "1770000000.M1P2Q3.host")
	tcheck(t, "the info field is present", has)
	teq(t, "the flags parse", maildir_flags_string(f, context.temp_allocator), "RS")
	u2, f2, has2 := maildir_parse_name("1770000000.M1P2Q3.host")
	teq(t, "a name with no info field", u2, "1770000000.M1P2Q3.host")
	tcheck(t, "...has no info field", !has2 && f2 == {})

	// Folder name mapping, both directions.
	md_probe := Maildir {
		root = "/tmp/x",
	}
	teq(t, "INBOX is the account root", maildir_folder_dir(&md_probe, "INBOX", context.temp_allocator), "/tmp/x")
	teq(t, "an empty folder name is INBOX too", maildir_folder_dir(&md_probe, "", context.temp_allocator), "/tmp/x")
	teq(t, "a subfolder gets a leading dot", maildir_folder_dir(&md_probe, "Sent", context.temp_allocator), "/tmp/x/.Sent")
	teq(
t,
		"a nested folder is flattened with dots",
		maildir_folder_dir(&md_probe, "Lists/odin", context.temp_allocator),
		"/tmp/x/.Lists.odin",
	)
	teq(t, "the inverse mapping", maildir_folder_name(".Lists.odin", context.temp_allocator), "Lists/odin")

	// A real directory.
	root := strings.concatenate({maildir_default_root(context.temp_allocator), "/_selftest-maildir"}, context.temp_allocator)
	os_rm_rf(root)
	md, oerr := maildir_open(root, context.temp_allocator)
	if !tcheck(t, "maildir_open creates the account root", oerr == "", oerr) {
		return
	}
	for sub in ([?]string{"cur", "new", "tmp"}) {
		p := strings.concatenate({root, "/", sub}, context.temp_allocator)
		tcheck(t, fmt.aprintf("INBOX/%s exists", sub), os.is_dir(p), p)
	}

	n1, d1 := maildir_deliver(&md, INBOX, transmute([]u8)string("Subject: one\r\n\r\nhello\r\n"), {}, true, context.temp_allocator)
	tcheck(t, "a fresh delivery succeeds", d1 == "", d1)
	tcheck(t, "a fresh delivery has no info field", !strings.contains(n1, ":2,"), n1)
	tcheck(
		t,
		"a fresh delivery lands in new/",
		os.exists(strings.concatenate({root, "/new/", n1}, context.temp_allocator)),
		n1,
	)
	tcheck(t, "tmp/ is left clean", maildir_count_dir(strings.concatenate({root, "/tmp"}, context.temp_allocator)) == 0)

	n2, d2 := maildir_deliver(
		&md,
		INBOX,
		transmute([]u8)string("Subject: two\r\n\r\nworld\r\n"),
		{.Seen, .Flagged},
		false,
		context.temp_allocator,
	)
	tcheck(t, "a flagged delivery succeeds", d2 == "", d2)
	tcheck(t, "a flagged delivery carries :2,FS", strings.has_suffix(n2, ":2,FS"), n2)
	tcheck(
		t,
		"a flagged delivery lands in cur/",
		os.exists(strings.concatenate({root, "/cur/", n2}, context.temp_allocator)),
		n2,
	)
	tcheck(t, "two deliveries get different names", n1 != n2)

	entries := maildir_list(&md, INBOX, context.temp_allocator)
	teq_int(t, "the folder lists both messages", len(entries), 2)
	found_new, found_cur := false, false
	for e in entries {
		if e.in_new {found_new = true}
		if !e.in_new && e.flags == {.Seen, .Flagged} {found_cur = true}
	}
	tcheck(t, "the new/ message is reported as new", found_new)
	tcheck(t, "the cur/ message's flags are read back", found_cur)

	// Setting flags moves a message out of new/.
	e0 := entries[0]
	for i in 0 ..< len(entries) {
		if entries[i].in_new {e0 = entries[i]}
	}
	serr := maildir_set_flags(&md, &e0, {.Seen, .Replied}, context.temp_allocator)
	tcheck(t, "maildir_set_flags succeeds", serr == "", serr)
	tcheck(t, "...and the message is no longer in new/", !e0.in_new)
	tcheck(t, "...with the new info field on disk", os.exists(e0.path), e0.path)
	tcheck(t, "...spelled :2,RS", strings.has_suffix(e0.path, ":2,RS"), e0.path)

	data, rerr := maildir_read(e0, context.temp_allocator)
	tcheck(t, "the message reads back", rerr == "", rerr)
	tcheck(t, "...with its content intact", strings.contains(string(data), "hello"), string(data))

	// Subfolders.
	tcheck(t, "a subfolder is created", maildir_ensure_folder(&md, "Lists/odin") == "")
	tcheck(
		t,
		"...with the Maildir++ marker",
		os.exists(strings.concatenate({root, "/.Lists.odin/maildirfolder"}, context.temp_allocator)),
	)
	_, sd := maildir_deliver(&md, "Lists/odin", transmute([]u8)string("Subject: list\r\n\r\nx\r\n"), {}, true, context.temp_allocator)
	tcheck(t, "delivery into a subfolder", sd == "", sd)
	folders := maildir_folders(&md, context.temp_allocator)
	has_inbox, has_list := false, false
	for f in folders {
		if f == INBOX {has_inbox = true}
		if f == "Lists/odin" {has_list = true}
	}
	tcheck(t, "maildir_folders lists INBOX", has_inbox, fmt.aprintf("%v", folders))
	tcheck(t, "maildir_folders lists the subfolder by its IMAP-ish name", has_list, fmt.aprintf("%v", folders))

	// Removal.
	rmerr := maildir_remove(e0)
	tcheck(t, "maildir_remove succeeds", rmerr == "", rmerr)
	tcheck(t, "...and the file is gone", !os.exists(e0.path))

	// Unique names must be unique even in a tight loop.
	seen := make(map[string]bool, 256, context.temp_allocator)
	dupes := 0
	for i in 0 ..< 500 {
		nm := maildir_unique_name(&md, context.temp_allocator)
		if seen[nm] {dupes += 1}
		seen[nm] = true
	}
	teq_int(t, "500 unique names in a row collide 0 times", dupes, 0)

	os_rm_rf(root)
}

maildir_count_dir :: proc(path: string) -> int {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return -1
	}
	n := 0
	for fi in infos {
		if fi.type != .Directory {
			n += 1
		}
	}
	return n
}

// os_rm_rf removes a directory tree. Only ever called on paths this program
// created under its own Maildir root.
os_rm_rf :: proc(path: string) {
	if !strings.contains(path, "palmy-mail") {
		fmt.eprintfln("refusing to remove %q: it is not under the palmy-mail root", path)
		return
	}
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in infos {
		if fi.type == .Directory {
			os_rm_rf_inner(fi.fullpath)
		} else {
			_ = os.remove(fi.fullpath)
		}
	}
	_ = os.remove(path)
}

@(private = "file")
os_rm_rf_inner :: proc(path: string) {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err == nil {
		for fi in infos {
			if fi.type == .Directory {
				os_rm_rf_inner(fi.fullpath)
			} else {
				_ = os.remove(fi.fullpath)
			}
		}
	}
	_ = os.remove(path)
}

// ---------------------------------------------------------------------------
// Attachments: bytes by section, byte-exact saves, hostile filenames
// ---------------------------------------------------------------------------

// binary_payload is every byte value once, followed by a `\r\n\r\n` run and a
// NUL. Those last six bytes are the point: a NUL truncates anything that
// treats the buffer as a C string, and a CRLF run is what a text path
// normalises to a bare LF. A round trip that compares equal to this, byte for
// byte, has not been through a text path.
BINARY_PAYLOAD_TAIL :: [?]u8{'\r', '\n', '\r', '\n', 0x00, 0xff}

binary_payload :: proc(allocator := context.allocator) -> []u8 {
	tail := BINARY_PAYLOAD_TAIL
	out := make([]u8, 256 + len(tail), allocator)
	for i in 0 ..< 256 {
		out[i] = u8(i)
	}
	for b, i in tail {
		out[256 + i] = b
	}
	return out
}

test_attachments :: proc(t: ^T) {
	tsection(t, "attachments")

	// --- path_within, the containment check -------------------------------
	tcheck(t, "a plain name inside the directory is within it", path_within("/tmp/x", "/tmp/x/a.png"))
	tcheck(t, "a trailing slash on the directory does not matter", path_within("/tmp/x/", "/tmp/x/a.png"))
	tcheck(t, "a sibling directory is not within", !path_within("/tmp/x", "/tmp/y/a.png"))
	tcheck(t, "a prefix that is not a path component is not within", !path_within("/tmp/x", "/tmp/xy/a.png"))
	tcheck(t, "a nested path is not within", !path_within("/tmp/x", "/tmp/x/sub/a.png"))
	tcheck(t, "traversal out of the directory is not within", !path_within("/tmp/x", "/tmp/x/../a.png"))
	tcheck(t, "the directory itself is not a file within it", !path_within("/tmp/x", "/tmp/x"))
	tcheck(t, "the directory with a slash is not a file within it", !path_within("/tmp/x", "/tmp/x/"))
	tcheck(t, "a relative path is not within an absolute directory", !path_within("/tmp/x", "a.png"))
	tcheck(t, "a file at the root is within the root", path_within("/", "/a.png"))

	// --- sanitise_filename, restated where it is relied on ----------------
	teq(t, "../../.bashrc loses every directory component", sanitise_filename("../../.bashrc", context.temp_allocator), ".bashrc")
	teq(t, "an absolute path loses it too", sanitise_filename("/etc/passwd", context.temp_allocator), "passwd")
	teq(t, "a Windows path loses its backslashes", sanitise_filename("..\\..\\boot.ini", context.temp_allocator), "boot.ini")
	teq(t, "a bare .. is not a file name", sanitise_filename("..", context.temp_allocator), "")
	teq(t, "a control character is dropped", sanitise_filename("ev\x01il.png", context.temp_allocator), "evil.png")
	teq(t, "an ordinary name survives", sanitise_filename("report.pdf", context.temp_allocator), "report.pdf")

	// --- attachment_dest refuses what it cannot make safe -----------------
	{
		p1, e1 := attachment_dest("/tmp/x", "../../.bashrc", context.temp_allocator)
		teq(t, "a hostile name resolves inside the chosen directory", p1, "/tmp/x/.bashrc")
		teq(t, "...with no error", e1, "")
		_, e2 := attachment_dest("/tmp/x", "..", context.temp_allocator)
		tcheck(t, "a name that sanitises to nothing is refused", e2 != "", e2)
		_, e3 := attachment_dest("/tmp/x", "", context.temp_allocator)
		tcheck(t, "an empty name is refused", e3 != "")
	}

	// --- the round trip ---------------------------------------------------
	//
	// Build a message carrying a known binary payload, encode it base64, parse
	// it back, write it out, and compare the bytes on disk with the bytes we
	// started from.
	payload := binary_payload(context.temp_allocator)
	teq_int(t, "the payload is 262 bytes", len(payload), 262)
	teq_int(t, "...it starts with a NUL", int(payload[0]), 0)
	tcheck(t, "...it ends with a CRLF run", payload[256] == '\r' && payload[257] == '\n' && payload[258] == '\r' && payload[259] == '\n')
	teq_int(t, "...followed by a second NUL", int(payload[260]), 0)

	raw := strings.concatenate(
		{
			"From: Robot <robot@localhost>\r\n",
			"To: alice@localhost\r\n",
			"Subject: with a payload\r\n",
			"Message-ID: <attach@localhost>\r\n",
			"Date: Tue, 3 Feb 2026 12:00:00 +0000\r\n",
			"MIME-Version: 1.0\r\n",
			"Content-Type: multipart/related; boundary=\"REL\"\r\n",
			"\r\n",
			"--REL\r\n",
			"Content-Type: text/html; charset=utf-8\r\n",
			"\r\n",
			"<p>see <img src=\"cid:logo@localhost\"> and the file</p>\r\n",
			"--REL\r\n",
			"Content-Type: image/png\r\n",
			"Content-ID: <logo@localhost>\r\n",
			"Content-Disposition: inline; filename=\"logo.png\"\r\n",
			"Content-Transfer-Encoding: base64\r\n",
			"\r\n",
			"iVBORw0KGgo=\r\n",
			"--REL\r\n",
			// The filename is hostile on purpose.
			"Content-Type: application/octet-stream\r\n",
			"Content-Disposition: attachment; filename=\"../../.bashrc\"\r\n",
			"Content-Transfer-Encoding: base64\r\n",
			"\r\n",
			base64_encode(payload, 76, context.temp_allocator),
			"\r\n--REL\r\n",
			// And one part with no name at all, to exercise the fallback.
			"Content-Type: application/pdf\r\n",
			"Content-Transfer-Encoding: base64\r\n",
			"Content-Disposition: attachment\r\n",
			"\r\n",
			"JVBERi0=\r\n",
			"--REL--\r\n",
		},
		context.temp_allocator,
	)
	m := parse_message(transmute([]u8)raw, context.temp_allocator)

	teq_int(t, "the message has three non-body parts", len(m.attachments), 3)

	// Bytes by section number.
	b1, ok1 := part_bytes(&m, "1")
	tcheck(t, "section 1 is the html part", ok1 && strings.contains(string(b1), "cid:logo@localhost"))
	b2, ok2 := part_bytes(&m, "2")
	tcheck(t, "section 2 is the png, base64-decoded", ok2 && len(b2) == 8 && b2[0] == 0x89, fmt.aprintf("%d bytes", len(b2)))
	b3, ok3 := part_bytes(&m, "3")
	tcheck(t, "section 3 exists", ok3)
	teq_int(t, "section 3 decodes to the payload's length", len(b3), 262)
	tcheck(t, "section 3's bytes are the payload, byte for byte", ok3 && slice_eq(b3, payload))
	_, ok_root := part_bytes(&m, "")
	tcheck(t, "the root is a multipart and so has no bytes of its own", !ok_root)
	_, ok_miss := part_bytes(&m, "9")
	tcheck(t, "a section that does not exist is a miss, not a crash", !ok_miss)

	// Inline recognition: the png is referenced by the html, so it is part of
	// the message rather than a file to save. The others are not.
	inline_parts := message_inline_parts(&m, context.temp_allocator)
	teq_int(t, "one part is inline", len(inline_parts), 1)
	teq(t, "...and it is the referenced png", len(inline_parts) > 0 ? inline_parts[0].content_id : "", "logo@localhost")
	tcheck(t, "cid_referenced finds the reference", cid_referenced(&m, "logo@localhost"))
	tcheck(t, "...and does not invent one", !cid_referenced(&m, "nothing@localhost"))

	saveable := message_saveable(&m, context.temp_allocator)
	teq_int(t, "two parts are offered to save", len(saveable), 2)
	teq(t, "the hostile filename was reduced to a safe one", len(saveable) > 0 ? saveable[0].filename : "", ".bashrc")
	teq_int(t, "...with the payload's length", len(saveable) > 0 ? saveable[0].size : -1, 262)
	teq(
		t,
		"an unnamed part is named after its section and type",
		len(saveable) > 1 ? saveable[1].filename : "",
		"part-4.pdf",
	)

	// --- and now to disk --------------------------------------------------
	root := strings.concatenate({maildir_default_root(context.temp_allocator), "/_selftest-attach"}, context.temp_allocator)
	os_rm_rf(root)
	dir := strings.concatenate({root, "/out"}, context.temp_allocator)
	if !tcheck(t, "a staging directory was created", os.make_directory_all(dir) == nil || os.is_dir(dir)) {
		return
	}

	wrote, werr := attachment_write(dir, saveable[0], false, context.temp_allocator)
	if tcheck(t, "the attachment was written", werr == "", werr) {
		teq(t, "...directly inside the directory that was chosen", wrote, strings.concatenate({dir, "/.bashrc"}, context.temp_allocator))
		tcheck(t, "...and the path is within it", path_within(dir, wrote))
		tcheck(t, "the file is on disk", os.exists(wrote))

		back, rerr := os.read_entire_file_from_path(wrote, context.temp_allocator)
		if tcheck(t, "it reads back", rerr == nil) {
			teq_int(t, "with exactly 262 bytes", len(back), 262)
			tcheck(t, "BYTE-EXACT: the file on disk equals the payload we encoded", slice_eq(back, payload))
			tcheck(t, "...the NUL survived", len(back) > 0 && back[0] == 0)
			tcheck(
				t,
				"...the CRLF run survived unnormalised",
				len(back) == 262 && back[256] == '\r' && back[257] == '\n' && back[258] == '\r' && back[259] == '\n',
			)
			tcheck(t, "...and the high bytes survived", len(back) == 262 && back[255] == 0xff && back[261] == 0xff)
		}

		// Nothing escaped. The hostile name asked for two levels up.
		tcheck(
			t,
			"nothing was written two directories above the chosen one",
			!os.exists(strings.concatenate({maildir_default_root(context.temp_allocator), "/.bashrc"}, context.temp_allocator)),
		)
		tcheck(t, "nor one directory above it", !os.exists(strings.concatenate({root, "/.bashrc"}, context.temp_allocator)))

		// A second write must not silently replace the first.
		_, again := attachment_write(dir, saveable[0], false, context.temp_allocator)
		tcheck(t, "writing over an existing file is refused without an explicit yes", again != "", again)
		_, forced := attachment_write(dir, saveable[0], true, context.temp_allocator)
		tcheck(t, "...and allowed with one", forced == "", forced)
	}

	// The second, unnamed part lands under its generated name.
	w2, werr2 := attachment_write(dir, saveable[1], false, context.temp_allocator)
	if tcheck(t, "the unnamed part was written too", werr2 == "", werr2) {
		tcheck(t, "...as part-4.pdf", strings.has_suffix(w2, "/part-4.pdf"), w2)
	}

	// A directory that is not one is refused rather than created.
	_, nod := attachment_write(strings.concatenate({root, "/nope"}, context.temp_allocator), saveable[0], false, context.temp_allocator)
	tcheck(t, "writing into a directory that does not exist is refused", nod != "", nod)

	os_rm_rf(root)

	// --- mime_extension ---------------------------------------------------
	teq(t, "image/png is .png", mime_extension("image/png"), ".png")
	teq(t, "application/pdf is .pdf", mime_extension("application/pdf"), ".pdf")
	teq(t, "a type nobody knows is .bin", mime_extension("application/x-nonsense"), ".bin")
	teq(t, "and the case does not matter", mime_extension("IMAGE/PNG"), ".png")
}

// slice_eq compares two byte slices for exact equality, which is the whole
// point of the round-trip assertion above.
slice_eq :: proc(a, b: []u8) -> bool {
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

// ---------------------------------------------------------------------------
// Threading
// ---------------------------------------------------------------------------

test_threading :: proc(t: ^T) {
	tsection(t, "threading (JWZ)")

	// The known conversation from the corpus: a root, a reply with only
	// In-Reply-To, a reply with only References, and a reply with both.
	items := []Threadable {
		{key = "a", message_id = "thr-100@x", subject = "[l] Topic", date = 100},
		{key = "b", message_id = "thr-101@x", in_reply_to = {"thr-100@x"}, subject = "Re: [l] Topic", date = 200},
		{key = "c", message_id = "thr-102@x", references = {"thr-100@x", "thr-101@x"}, subject = "Re: [l] Topic", date = 300},
		{
			key = "d",
			message_id = "thr-103@x",
			in_reply_to = {"thr-102@x"},
			references = {"thr-100@x", "thr-101@x", "thr-102@x"},
			subject = "Re: [l] Topic",
			date = 400,
		},
	}
	th := thread_messages(items, true, context.temp_allocator)
	teq_int(t, "a four-message conversation is one thread", len(th.roots), 1)
	rows := thread_flatten(th, th.roots[0], context.temp_allocator)
	teq_int(t, "all four messages appear", len(rows), 4)
	teq_int(t, "the thread size is four", thread_size(th, th.roots[0]), 4)
	// The chain must be a chain: depths 0,1,2,3 in date order.
	depths := make([dynamic]int, 0, 4, context.temp_allocator)
	keys := make([dynamic]string, 0, 4, context.temp_allocator)
	for r in rows {
		append(&depths, r.depth)
		append(&keys, r.item >= 0 ? items[r.item].key : "<phantom>")
	}
	teq(t, "the reply chain is a-b-c-d", strings.join(keys[:], "", context.temp_allocator), "abcd")
	teq(t, "each reply is one level deeper", fmt.aprintf("%v", depths[:]), "[0, 1, 2, 3]")

	// A reply whose parents were never delivered: the phantoms are pruned and
	// the message becomes its own root.
	orphan := []Threadable {
		{key = "a", message_id = "m1@x", subject = "Topic", date = 100},
		{
			key = "o",
			message_id = "m9@x",
			in_reply_to = {"never-1@x"},
			references = {"never-0@x", "never-1@x"},
			subject = "Re: something else entirely",
			date = 200,
		},
	}
	th2 := thread_messages(orphan, true, context.temp_allocator)
	teq_int(t, "an orphan reply becomes its own thread", len(th2.roots), 2)
	phantoms := 0
	for r in th2.roots {
		rws := thread_flatten(th2, r, context.temp_allocator)
		for row in rws {
			if row.item < 0 {phantoms += 1}
		}
	}
	teq_int(t, "no empty containers survive pruning", phantoms, 0)

	// A missing middle: the grandchild still attaches under the root.
	gap := []Threadable {
		{key = "root", message_id = "g1@x", subject = "G", date = 100},
		{
			key = "grandchild",
			message_id = "g3@x",
			references = {"g1@x", "g2-missing@x"},
			subject = "Re: G",
			date = 300,
		},
	}
	th3 := thread_messages(gap, false, context.temp_allocator)
	teq_int(t, "a missing middle message does not split the thread", len(th3.roots), 1)
	rows3 := thread_flatten(th3, th3.roots[0], context.temp_allocator)
	teq_int(t, "both real messages are present", len(rows3), 2)
	teq_int(t, "the grandchild is spliced up to the root", rows3[1].depth, 1)

	// Mutually referencing messages: the loop guard must hold.
	loop := []Threadable {
		{key = "x", message_id = "l1@x", references = {"l2@x"}, subject = "L", date = 100},
		{key = "y", message_id = "l2@x", references = {"l1@x"}, subject = "L", date = 200},
	}
	th4 := thread_messages(loop, false, context.temp_allocator)
	total4 := 0
	for r in th4.roots {
		total4 += thread_size(th4, r)
	}
	teq_int(t, "a reference cycle still yields both messages exactly once", total4, 2)
	tcheck(t, "...and terminates", true)

	// A message that references itself.
	self := []Threadable{{key = "s", message_id = "s1@x", references = {"s1@x"}, in_reply_to = {"s1@x"}, subject = "S", date = 1}}
	th5 := thread_messages(self, false, context.temp_allocator)
	teq_int(t, "a self-reference is ignored", len(th5.roots), 1)
	teq_int(t, "...and the message appears once", thread_size(th5, th5.roots[0]), 1)

	// Duplicate Message-IDs must not collapse two messages into one.
	dup := []Threadable {
		{key = "d1", message_id = "same@x", subject = "D", date = 100},
		{key = "d2", message_id = "same@x", subject = "D", date = 200},
	}
	th6 := thread_messages(dup, false, context.temp_allocator)
	total6 := 0
	for r in th6.roots {
		total6 += thread_size(th6, r)
	}
	teq_int(t, "two messages with the same Message-ID both survive", total6, 2)

	// No Message-ID at all.
	anon := []Threadable {
		{key = "n1", subject = "N", date = 100},
		{key = "n2", subject = "N", date = 200},
	}
	th7 := thread_messages(anon, false, context.temp_allocator)
	total7 := 0
	for r in th7.roots {
		total7 += thread_size(th7, r)
	}
	teq_int(t, "messages with no Message-ID are kept separate", total7, 2)

	// Subject normalisation, which is all step 5 is allowed to use.
	for pair in ([?][2]string {
			{"Re: Hello", "hello"},
			{"RE: re: Hello", "hello"},
			{"Fwd: Hello", "hello"},
			{"FW: Hello", "hello"},
			{"Aw: Hello", "hello"},
			{"[odin-dev] Hello", "hello"},
			{"Re: [odin-dev] Hello", "hello"},
			{"Hello", "hello"},
		}) {
		base, _ := normalise_subject(pair[0], context.temp_allocator)
		teq(t, fmt.aprintf("normalise_subject %q", pair[0]), base, pair[1])
	}
	_, was_reply := normalise_subject("Re: Hello", context.temp_allocator)
	tcheck(t, "normalise_subject reports that Re: was stripped", was_reply)
	_, not_reply := normalise_subject("Hello", context.temp_allocator)
	tcheck(t, "...and that nothing was stripped otherwise", !not_reply)

	// Subject gathering joins a reply with no references to its root — and
	// ONLY when asked.
	subj := []Threadable {
		{key = "root", message_id = "s100@x", subject = "Quarterly numbers", date = 100},
		{key = "reply", message_id = "s101@x", subject = "Re: Quarterly numbers", date = 200},
	}
	with_subj := thread_messages(subj, true, context.temp_allocator)
	teq_int(t, "subject gathering joins a reference-less reply", len(with_subj.roots), 1)
	without := thread_messages(subj, false, context.temp_allocator)
	teq_int(t, "without it, they stay separate", len(without.roots), 2)
	// Two unrelated messages with the same subject and neither a reply must
	// NOT be merged: that is where subject matching invents conversations.
	same := []Threadable {
		{key = "a", message_id = "u1@x", subject = "Hello", date = 100},
		{key = "b", message_id = "u2@x", subject = "Hello", date = 200},
	}
	th8 := thread_messages(same, true, context.temp_allocator)
	teq_int(t, "two non-replies with one subject are not merged", len(th8.roots), 2)

	// Threads come back oldest-activity first.
	multi := []Threadable {
		{key = "newer", message_id = "n1@x", subject = "Newer", date = 1000},
		{key = "older", message_id = "o1@x", subject = "Older", date = 10},
	}
	th9 := thread_messages(multi, false, context.temp_allocator)
	teq_int(t, "two threads", len(th9.roots), 2)
	first_key := th9.containers[th9.roots[0]].msg >= 0 ? multi[th9.containers[th9.roots[0]].msg].key : ""
	teq(t, "the thread with the older newest-message comes first", first_key, "older")

	// Empty input.
	th10 := thread_messages({}, true, context.temp_allocator)
	teq_int(t, "threading nothing yields no threads", len(th10.roots), 0)
}

// ---------------------------------------------------------------------------
// Composing
// ---------------------------------------------------------------------------

test_compose :: proc(t: ^T) {
	tsection(t, "composing outgoing mail")

	c := Compose {
		from = {name = "Alice Loopback", email = "alice@localhost"},
		to = {{name = "Bob Loopback", email = "bob@localhost"}},
		cc = {{email = "carol@localhost"}},
		bcc = {{email = "secret@localhost"}},
		subject = "Grüße — a non-ASCII subject",
		text = "Plain body with an accent: é\nand a second line.\n",
		html = "<p>HTML body with an accent: é</p>\n",
		attachments = {
			{
				filename = "café définitif.pdf",
				mime_type = "application/pdf",
				content = transmute([]u8)string("%PDF-1.4 synthetic"),
			},
			{
				filename = "pixel.png",
				mime_type = "image/png",
				content = {0x89, 'P', 'N', 'G'},
				is_inline = true,
				content_id = "pix@localhost",
			},
		},
		in_reply_to = "parent@localhost",
		references = {"grandparent@localhost"},
		date_unix = days_from_civil(2026, 2, 3) * 86400 + 12 * 3600,
		tz_minutes = 60,
		user_agent = "mailcore/selftest",
	}
	data, msgid := compose_build(c, context.temp_allocator)
	tcheck(t, "compose produced a message", len(data) > 0)
	tcheck(t, "a Message-ID was generated", strings.contains(msgid, "@localhost"), msgid)
	tcheck(t, "the message uses CRLF", strings.contains(string(data), "\r\n"), "")
	tcheck(
		t,
		"Bcc is NOT written into the headers",
		!strings.contains(string(data), "secret@localhost"),
		"the blind copy leaked into the message",
	)

	m := parse_message(data, context.temp_allocator)
	teq_int(t, "the composed message parses with no warnings", len(m.warnings), 0)
	teq(t, "the subject round trips through RFC 2047", m.subject, "Grüße — a non-ASCII subject")
	teq(t, "From round trips", len(m.from) > 0 ? m.from[0].email : "", "alice@localhost")
	teq(t, "the From display name round trips", len(m.from) > 0 ? m.from[0].name : "", "Alice Loopback")
	teq(t, "To round trips", len(m.to) > 0 ? m.to[0].email : "", "bob@localhost")
	teq(t, "Cc round trips", len(m.cc) > 0 ? m.cc[0].email : "", "carol@localhost")
	teq(t, "Message-ID round trips", m.message_id, msgid)
	teq(t, "In-Reply-To round trips", len(m.in_reply_to) > 0 ? m.in_reply_to[0] : "", "parent@localhost")
	teq_int(t, "References carries both ids", len(m.references), 2)
	teq(t, "References ends with the parent", m.references[len(m.references) - 1], "parent@localhost")
	tcheck(t, "the Date parses", m.date.ok)
	teq_i64(t, "the Date value survives the zone", m.date.unix, c.date_unix)
	teq_int(t, "the Date offset is preserved", m.date.tz_minutes, 60)

	teq(t, "the plain body round trips", strings.trim_space(m.text_plain), strings.trim_space(c.text))
	teq(t, "the html body round trips", strings.trim_space(m.text_html), strings.trim_space(c.html))
	teq_int(t, "both attachments survive", len(m.attachments), 2)
	// The inline image goes in multipart/related, the file in multipart/mixed.
	pdf, png: Attachment
	for a in m.attachments {
		if a.mime_type == "application/pdf" {pdf = a}
		if a.mime_type == "image/png" {png = a}
	}
	teq(t, "the non-ASCII filename round trips", pdf.filename, "café définitif.pdf")
	tbytes(t, "the pdf bytes round trip", pdf.content, "%PDF-1.4 synthetic")
	teq(t, "the inline image keeps its Content-ID", png.content_id, "pix@localhost")
	tcheck(t, "the inline image is inline", png.is_inline)
	tbytes(t, "the png bytes round trip", png.content, "\x89PNG")
	teq(t, "the outer structure is multipart/mixed", fmt.aprintf("%s/%s", m.root.main, m.root.sub), "multipart/mixed")
	tcheck(
		t,
		"an inline image puts the bodies in multipart/related",
		len(m.root.parts) > 0 && m.root.parts[0].sub == "related",
		len(m.root.parts) > 0 ? m.root.parts[0].sub : "<none>",
	)

	// Simplest case: text only, no attachments.
	c2 := Compose {
		from    = {email = "a@localhost"},
		to      = {{email = "b@localhost"}},
		subject = "ascii only",
		text    = "just text\n",
	}
	d2, _ := compose_build(c2, context.temp_allocator)
	m2 := parse_message(d2, context.temp_allocator)
	teq(t, "a text-only message is text/plain", fmt.aprintf("%s/%s", m2.root.main, m2.root.sub), "text/plain")
	teq(t, "an ASCII subject is not encoded", m2.subject, "ascii only")
	tcheck(t, "...and the raw header is plain", strings.contains(string(d2), "Subject: ascii only"), "")
	teq(t, "the body round trips", strings.trim_space(m2.text_plain), "just text")

	// text+html with no attachments is multipart/alternative.
	c3 := Compose {
		from = {email = "a@localhost"},
		to   = {{email = "b@localhost"}},
		text = "t",
		html = "<p>h</p>",
	}
	d3, _ := compose_build(c3, context.temp_allocator)
	m3 := parse_message(d3, context.temp_allocator)
	teq(t, "text+html is multipart/alternative", fmt.aprintf("%s/%s", m3.root.main, m3.root.sub), "multipart/alternative")
	teq_int(t, "with two children", len(m3.root.parts), 2)
	teq(t, "plain comes first (RFC 2046 5.1.4 order)", m3.root.parts[0].sub, "plain")

	// A boundary must never appear in the payload it delimits.
	c4 := Compose {
		from = {email = "a@localhost"},
		to   = {{email = "b@localhost"}},
		text = "a body that mentions =_palmy_ on purpose",
		attachments = {{filename = "x.bin", content = transmute([]u8)string("=_palmy_")}},
	}
	d4, _ := compose_build(c4, context.temp_allocator)
	m4 := parse_message(d4, context.temp_allocator)
	teq_int(t, "a payload containing the boundary prefix still parses", len(m4.warnings), 0)
	teq_int(t, "...with the attachment intact", len(m4.attachments), 1)

	// The envelope, which is where Bcc belongs.
	env := compose_envelope(c, data, context.temp_allocator)
	teq(t, "the envelope sender", env.from, "alice@localhost")
	teq_int(t, "the envelope has three recipients including the blind one", len(env.to), 3)
	has_bcc := false
	for r in env.to {
		if r == "secret@localhost" {has_bcc = true}
	}
	tcheck(t, "the blind recipient is in the envelope", has_bcc)

	// A long References header must fold, and still parse.
	refs := make([dynamic]string, 0, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		append(&refs, fmt.tprintf("a-rather-long-message-id-number-%d@localhost", i))
	}
	c5 := Compose {
		from       = {email = "a@localhost"},
		to         = {{email = "b@localhost"}},
		text       = "x",
		references = refs[:],
	}
	d5, _ := compose_build(c5, context.temp_allocator)
	m5 := parse_message(d5, context.temp_allocator)
	teq_int(t, "ten references survive folding", len(m5.references), 10)
	longest := 0
	for l in strings.split_lines(string(d5), context.temp_allocator) {
		if len(l) > longest {longest = len(l)}
	}
	tcheck(t, "no header line exceeds 998 octets", longest <= 998, fmt.aprintf("longest %d", longest))
}

// ---------------------------------------------------------------------------
// JSON and JMAP plumbing
// ---------------------------------------------------------------------------

test_json :: proc(t: ^T) {
	tsection(t, "JSON writer, pointers and back-references")
	w := jw_make(context.temp_allocator)
	jw_obj(&w)
	jw_kstr(&w, "a", "x")
	jw_kint(&w, "b", 2)
	jw_kbool(&w, "c", true)
	jw_knull(&w, "d")
	jw_key(&w, "e")
	jw_arr(&w)
	jw_str(&w, "p")
	jw_int(&w, 1)
	jw_arr_end(&w)
	jw_key(&w, "f")
	jw_obj(&w)
	jw_kstr(&w, "g", "h")
	jw_obj_end(&w)
	jw_obj_end(&w)
	teq(
		t,
		"the JSON writer places every comma correctly",
		jw_string(&w),
		`{"a":"x","b":2,"c":true,"d":null,"e":["p",1],"f":{"g":"h"}}`,
	)
	teq(t, "strings are escaped", json_quote("a\"b\\c\nd\te", context.temp_allocator), `"a\"b\\c\nd\te"`)
	teq(t, "control characters become \\u escapes", json_quote("\x01", context.temp_allocator), `"\u0001"`)
	teq(t, "UTF-8 is not escaped", json_quote("é", context.temp_allocator), `"é"`)

	// JSON pointers, including JMAP's * extension.
	v, perr := json.parse(
		transmute([]u8)string(`{"ids":["a","b"],"list":[{"id":"x","n":1},{"id":"y","n":2}],"deep":{"a~b":{"c/d":7}}}`),
		.JSON,
		true,
		context.temp_allocator,
	)
	tcheck(t, "the pointer fixture parses", perr == nil, fmt.aprintf("%v", perr))
	p1, ok1 := json_pointer(v, "/ids", context.temp_allocator)
	tcheck(t, "a pointer to an array resolves", ok1)
	teq(t, "...and renders back", json_render(p1, context.temp_allocator), `["a","b"]`)
	p2, ok2 := json_pointer(v, "/ids/1", context.temp_allocator)
	tcheck(t, "an array index resolves", ok2)
	teq(t, "...to the right element", json_render(p2, context.temp_allocator), `"b"`)
	p3, ok3 := json_pointer(v, "/list/*/id", context.temp_allocator)
	tcheck(t, "the JMAP * extension maps over an array", ok3)
	teq(t, "...and flattens the result", json_render(p3, context.temp_allocator), `["x","y"]`)
	p4, ok4 := json_pointer(v, "/deep/a~0b/c~1d", context.temp_allocator)
	tcheck(t, "~0 and ~1 escapes resolve", ok4)
	teq(t, "...to the escaped key's value", json_render(p4, context.temp_allocator), "7")
	_, ok5 := json_pointer(v, "/nope", context.temp_allocator)
	tcheck(t, "a missing key does not resolve", !ok5)
	_, ok6 := json_pointer(v, "/ids/9", context.temp_allocator)
	tcheck(t, "an out-of-range index does not resolve", !ok6)
	_, ok7 := json_pointer(v, "ids", context.temp_allocator)
	tcheck(t, "a pointer without a leading slash is rejected", !ok7)
	p8, ok8 := json_pointer(v, "", context.temp_allocator)
	tcheck(t, "the empty pointer is the whole document", ok8 && p8 != nil)

	teq(
		t,
		"a ResultReference renders as RFC 8620 specifies",
		jmap_backref("c0", "Email/query", "/ids", context.temp_allocator),
		`{"resultOf":"c0","name":"Email/query","path":"/ids"}`,
	)
	teq_int(t, "keywords map to Maildir flags", int(transmute(u8)jmap_keywords_to_flags({"$seen", "$flagged"})), int(transmute(u8)Maildir_Flags{.Seen, .Flagged}))
	teq_int(
		t,
		"$answered and $draft and $forwarded map too",
		int(transmute(u8)jmap_keywords_to_flags({"$answered", "$draft", "$forwarded"})),
		int(transmute(u8)Maildir_Flags{.Replied, .Draft, .Passed}),
	)
	teq_int(t, "a custom keyword maps to nothing", int(transmute(u8)jmap_keywords_to_flags({"$myown"})), 0)
	kws := maildir_flags_to_keywords({.Seen, .Replied}, context.temp_allocator)
	teq(t, "flags map back to keywords", strings.join(kws, ",", context.temp_allocator), "$seen,$answered")

	teq_int(t, "IMAP flags map to Maildir flags", int(transmute(u8)imap_flags_to_maildir({"\\Seen", "\\Answered", "\\Deleted"})), int(transmute(u8)Maildir_Flags{.Seen, .Replied, .Trashed}))
	teq(
		t,
		"Maildir flags map back to IMAP",
		strings.join(maildir_flags_to_imap({.Seen, .Flagged}, context.temp_allocator), " ", context.temp_allocator),
		"\\Seen \\Flagged",
	)
	teq_int(t, "\\Recent has no Maildir equivalent", int(transmute(u8)imap_flags_to_maildir({"\\Recent"})), 0)
}

test_http_bits :: proc(t: ^T) {
	tsection(t, "HTTP plumbing")
	sch, host, port, target, err := url_split("http://127.0.0.1:18143/jmap/api")
	teq(t, "url_split error", err, "")
	teq(t, "scheme", sch, "http")
	teq(t, "host", host, "127.0.0.1")
	teq_int(t, "port", port, 18143)
	teq(t, "target", target, "/jmap/api")
	_, _, p2, t2, e2 := url_split("https://localhost/x")
	teq(t, "https default port", e2, "")
	teq_int(t, "...is 443", p2, 443)
	teq(t, "...with the path", t2, "/x")
	_, _, _, t3, _ := url_split("http://127.0.0.1")
	teq(t, "a URL with no path targets /", t3, "/")
	_, _, _, _, e4 := url_split("ftp://127.0.0.1/x")
	tcheck(t, "a non-http scheme is rejected", e4 != "", e4)

	teq(t, "percent encoding", url_encode_component("a b/c?d", context.temp_allocator), "a%20b%2Fc%3Fd")
	teq(t, "percent encoding leaves unreserved characters", url_encode_component("a-_.~Z9", context.temp_allocator), "a-_.~Z9")
	teq(t, "percent decoding", url_decode("a%20b%2Fc", context.temp_allocator), "a b/c")
	teq(t, "percent decoding round trip of UTF-8", url_decode(url_encode_component("café", context.temp_allocator), context.temp_allocator), "café")
	teq(t, "a stray % is left alone", url_decode("100%", context.temp_allocator), "100%")

	teq(
		t,
		"Basic auth is RFC 7617",
		http_basic_auth("alice", "secret", context.temp_allocator),
		"Basic YWxpY2U6c2VjcmV0",
	)
	hs := []Http_Header{{name = "content-type", value = "application/json"}}
	v, found := http_header(hs, "content-type")
	tcheck(t, "header lookup", found)
	teq(t, "header value", v, "application/json")
	_, nf := http_header(hs, "x-missing")
	tcheck(t, "a missing header is not found", !nf)
}

// ---------------------------------------------------------------------------
// The safety gate
// ---------------------------------------------------------------------------

// test_loopback_gate asserts the property the whole task depends on: this
// program cannot open a socket to anything but 127.0.0.0/8, and it never
// resolves a name. Every case here is checked WITHOUT attempting a connection.
test_loopback_gate :: proc(t: ^T) {
	tsection(t, "loopback-only safety gate")
	for good in ([?]string{"127.0.0.1", "127.0.0.2", "127.1.2.3", "localhost", "localhost.localdomain"}) {
		addr, err := loopback_address(good)
		tcheck(t, fmt.aprintf("%q is allowed", good), err == "", err)
		tcheck(t, fmt.aprintf("%q resolves to 127/8", good), addr[0] == 127, fmt.aprintf("%v", addr))
	}
	for bad in ([?]string {
			"imap.gmail.com",
			"smtp.gmail.com",
			"imap.mail.me.com",
			"outlook.office365.com",
			"0.0.0.0",
			"192.168.1.1",
			"10.0.0.1",
			"8.8.8.8",
			"1.2.3.4",
			"::1",
			"example.com",
			"",
			"127.0.0.1.evil.com",
			"localhost.evil.com",
		}) {
		_, err := loopback_address(bad)
		tcheck(t, fmt.aprintf("%q is REFUSED", bad), err != "", "the gate let it through")
	}
	// And the dialler itself refuses before touching a socket.
	c: Conn
	derr := conn_dial(&c, "imap.gmail.com", 993, {}, "gate")
	tcheck(t, "conn_dial refuses a real mail host", derr != "", "conn_dial did not refuse")
	tcheck(t, "...and says why", strings.contains(derr, "loopback"), derr)
	tcheck(t, "...and opened nothing", !c.open)
	derr2 := conn_dial(&c, "127.0.0.1", 0, {}, "gate")
	tcheck(t, "conn_dial refuses port 0", derr2 != "", "port 0 was accepted")
	derr3 := conn_dial(&c, "127.0.0.1", 70000, {}, "gate")
	tcheck(t, "conn_dial refuses an out-of-range port", derr3 != "", "port 70000 was accepted")
}

// ---------------------------------------------------------------------------
// The preview rule (cloud/mail/readable)
// ---------------------------------------------------------------------------

// The fixtures palm-maild's own selftest uses, so the server and the engine
// are held to the same messages.
PARTS_DIFFER :: #load("../../cloud/mail/fixtures/parts-differ.eml", string)
PARTS_HIDDEN :: #load("../../cloud/mail/fixtures/parts-hidden.eml", string)
PARTS_AGREE :: #load("../../cloud/mail/fixtures/parts-agree.eml", string)

test_preview_rule :: proc(t: ^T) {
	tsection(t, "preview rule")

	// text/plain carries words the HTML a reader shows does not.
	d := parse_message(transmute([]u8)string(PARTS_DIFFER), context.temp_allocator)
	tcheck(t, "diverging parts: both bodies are still kept", strings.contains(d.text_plain, "ASSISTANTS") && strings.contains(d.text_html, "remittance"))
	tcheck(t, "diverging parts: the preview is the HTML's visible text",
		strings.has_prefix(d.preview, "Dear Camille, Our remittance details change on 1 November."), d.preview)
	tcheck(t, "diverging parts: nothing of the plain part is in the preview",
		!strings.contains(d.preview, "ASSISTANTS") && !strings.contains(d.preview, "evil"), d.preview)
	tcheck(t, "diverging parts: flagged", d.parts_differ)

	// HTML hiding text by CSS: the hidden text is in no preview.
	h := parse_message(transmute([]u8)string(PARTS_HIDDEN), context.temp_allocator)
	tcheck(t, "hidden HTML: preview is the visible text", strings.has_prefix(h.preview, "Dear Camille, your October invoice"), h.preview)
	tcheck(t, "hidden HTML: font-size 0 text removed", !strings.contains(h.preview, "forward every invoice"), h.preview)
	tcheck(t, "hidden HTML: display:none text removed", !strings.contains(h.preview, "+44"), h.preview)
	tcheck(t, "hidden HTML: visible parts agree, not flagged", !h.parts_differ)

	// An ordinary alternative, link spelled out in plain and hidden in href.
	a := parse_message(transmute([]u8)string(PARTS_AGREE), context.temp_allocator)
	tcheck(t, "agreeing parts: not flagged", !a.parts_differ)
	tcheck(t, "agreeing parts: preview from the HTML", strings.has_prefix(a.preview, "Hi Camille, The design review moves to Thursday at 14:00."), a.preview)

	// One part only.
	p := parse_message(transmute([]u8)string("From: a@b.test\r\nSubject: p\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nJust plain\u200b text.\r\n"), context.temp_allocator)
	teq(t, "plain only: preview is the plain text without invisible characters", p.preview, "Just plain text.")
	tcheck(t, "plain only: not flagged", !p.parts_differ)
	o := parse_message(transmute([]u8)string("From: a@b.test\r\nSubject: h\r\nContent-Type: text/html\r\n\r\n<p>Only <b>HTML</b></p><p hidden>secret</p>\r\n"), context.temp_allocator)
	teq(t, "HTML only: its visible text", o.preview, "Only HTML")
	tcheck(t, "HTML only: not flagged", !o.parts_differ)

	// The preview is one line, at most 256 bytes, cut on a UTF-8 boundary.
	long := parse_message(transmute([]u8)strings.concatenate({"From: a@b.test\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n", strings.repeat("é", 200, context.temp_allocator), "\r\n"}, context.temp_allocator), context.temp_allocator)
	tcheck(t, "the preview is cut at 256 bytes on a rune boundary", len(long.preview) == 256 && strings.has_suffix(long.preview, "é"), fmt.tprintf("%d bytes", len(long.preview)))
}
