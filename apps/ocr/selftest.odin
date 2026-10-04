package main

// `ocr --selftest` runs the whole thing against text it generated itself.
//
// The strongest test available on this machine costs nothing: render known
// text to an image with palmy's offscreen renderer, OCR it, and compare
// against the text we started with. A scanned document can never give that,
// because nobody knows exactly what is on it. So accuracy here is **measured
// and printed per case**, not asserted and hidden — a threshold that passes
// tells you nothing about whether a recogniser got 1% or 19% wrong.
//
// What is asserted, as opposed to measured:
//
//   * structure: paragraph counts, heading levels, column order, the hyphen
//     join, the running header and footer being gone;
//   * the EPUB is an EPUB: `mimetype` first and stored, every XML part
//     parsing under xmllint, the chapter text matching the Doc;
//   * a PDF with a text layer is not OCRed;
//   * a missing tesseract is reported and never becomes a silent upload;
//   * the remote backend sends **nothing** without consent — asserted by
//     pointing it at the local mock and reading the mock's own counter.
//
// Nothing here touches the network beyond 127.0.0.1, and nothing here reads a
// file it did not write.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

@(private = "file")
pass_n: int
@(private = "file")
fail_n: int
@(private = "file")
verbose: bool

@(private = "file")
check :: proc(ok: bool, format: string, args: ..any) -> bool {
	if ok {
		pass_n += 1
	} else {
		fail_n += 1
	}
	fmt.printfln("%s  %s", ok ? "pass" : "FAIL", fmt.tprintf(format, ..args))
	return ok
}

@(private = "file")
note :: proc(format: string, args: ..any) {
	fmt.printfln("      %s", fmt.tprintf(format, ..args))
}

@(private = "file")
eq_s :: proc(got, want: string, format: string, args: ..any) -> bool {
	ok := got == want
	check(ok, format, ..args)
	if !ok {
		note("got  %q", got)
		note("want %q", want)
	}
	return ok
}

@(private = "file")
eq_i :: proc(got, want: int, format: string, args: ..any) -> bool {
	ok := got == want
	check(ok, format, ..args)
	if !ok {
		note("got %d, want %d", got, want)
	}
	return ok
}

@(private = "file")
section :: proc(title: string) {
	fmt.printfln("\n-- %s %s", title, strings.repeat("-", max(2, 62 - len(title)), context.temp_allocator))
}

// ---------------------------------------------------------------------------

selftest :: proc(args: []string) -> int {
	for a in args {
		if a == "--verbose" || a == "-v" {
			verbose = true
		}
	}
	fmt.println("palmy ocr — self test")
	fmt.println(strings.repeat("=", 72, context.temp_allocator))

	work := cache_path("selftest", context.temp_allocator)
	os.make_directory_all(work)

	test_units()
	test_http_framing()
	test_zip_and_epub()
	test_consent_gate()
	test_network_gate()
	test_tls(work)
	test_mock_flow(work)
	test_corpus(work)
	test_pdfs(work)
	test_reader_interop(work)
	test_missing_tool()
	test_interface()

	fmt.println()
	fmt.println(strings.repeat("=", 72, context.temp_allocator))
	fmt.printfln("%d assertions, %d passed, %d failed", pass_n + fail_n, pass_n, fail_n)
	return fail_n == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// The small pieces
// ---------------------------------------------------------------------------

@(private = "file")
test_units :: proc() {
	section("text handling")

	eq_s(xml_escape("a & b < c > d", context.temp_allocator), "a &amp; b &lt; c &gt; d", "XML entities are escaped")
	eq_s(xml_escape("say \"hi\" & 'bye'", context.temp_allocator), "say &quot;hi&quot; &amp; &apos;bye&apos;", "quotes are escaped")
	eq_s(xml_escape("a\x0cb", context.temp_allocator), "ab", "a control byte XML cannot represent is dropped, not escaped")
	eq_s(xml_escape("line\nbreak", context.temp_allocator), "line break", "a newline inside a block becomes a space")

	eq_s(md_escape_inline("a * b _ c", context.temp_allocator), "a \\* b \\_ c", "Markdown emphasis characters are escaped")
	eq_s(md_escape_inline("# not a heading", context.temp_allocator), "\\# not a heading", "a leading # is escaped")
	eq_s(md_escape_inline("mid # hash", context.temp_allocator), "mid # hash", "a # inside a line is left alone")
	eq_s(md_unescape(md_escape_inline("a * b [c]", context.temp_allocator), context.temp_allocator), "a * b [c]", "escape and unescape round-trip")

	s1, h1 := ends_with_hyphen("weather-")
	check(h1 && s1 == "weather", "a trailing ASCII hyphen is found")
	s2, h2 := ends_with_hyphen("weather‐")
	check(h2 && s2 == "weather", "a trailing U+2010 hyphen is found")
	_, h3 := ends_with_hyphen("weather")
	check(!h3, "a word with no hyphen is left alone")
	_, h4 := ends_with_hyphen("-")
	check(!h4, "a bare hyphen is not a broken word")

	check(starts_lower("vane"), "a lowercase continuation is recognised")
	check(!starts_lower("German"), "a capitalised continuation is not a hyphen break")

	eq_s(furniture_key("Page 3 of 12", context.temp_allocator), "page # of ##", "digits collapse so page numbers match across pages")
	eq_s(furniture_key("THE WEATHER", context.temp_allocator), "the weather", "case is folded")
	eq_s(furniture_key("A. B, C!", context.temp_allocator), "a b c", "punctuation is dropped, where OCR is least reliable")

	eq_s(pretty_title("scan_2026-10-04_page1", context.temp_allocator), "Scan 2026 10 04 Page1", "a filename becomes a title")

	eq_s(json_string("a\"b\\c", context.temp_allocator), `"a\"b\\c"`, "JSON strings escape quotes and backslashes")
	eq_s(json_string("tab\there", context.temp_allocator), `"tab\there"`, "JSON strings escape tabs")
	eq_s(url_escape("file-abc_123", context.temp_allocator), "file-abc_123", "an unreserved file id is unchanged")
	eq_s(url_escape("a/b?c", context.temp_allocator), "a%2Fb%3Fc", "a file id cannot inject a path or a query")

	section("error rates")
	r0 := error_rates("the quick brown fox", "the quick brown fox")
	check(r0.cer == 0 && r0.wer == 0, "identical text scores zero")
	r1 := error_rates("the quick browm fox", "the quick brown fox")
	eq_i(r1.char_err, 1, "one wrong letter is one character error")
	eq_i(r1.word_err, 1, "...and one word error")
	r2 := error_rates("the  quick\nbrown fox", "the quick brown fox")
	check(r2.cer == 0, "whitespace runs are normalised before comparing")
	r3 := error_rates("the ‘quick’ fox", "the 'quick' fox")
	check(r3.cer == 0, "typographic quotes fold to ASCII")
	r4 := error_rates("", "four words go here")
	check(r4.wer == 1, "an empty result scores a word error rate of one")

	section("tesseract TSV parsing")
	tsv := "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" +
		"1\t1\t0\t0\t0\t0\t0\t0\t900\t300\t-1\t\n" +
		"5\t1\t1\t1\t1\t1\t40\t60\t45\t20\t90.8\tThe\n" +
		"5\t1\t1\t1\t1\t2\t94\t60\t68\t24\t91.0\tquick\n" +
		"5\t1\t1\t1\t1\t3\t173\t60\t0\t20\t12.0\t\n" +
		"5\t1\t1\t1\t1\t4\t180\t60\t38\t20\t-1\t \n"
	words := make([dynamic]Ocr_Word, context.temp_allocator)
	tess_parse_tsv(tsv, 1, &words, context.temp_allocator)
	eq_i(len(words), 2, "only level-5 rows with real text become words")
	if len(words) == 2 {
		eq_s(words[0].text, "The", "the first word came through")
		eq_i(words[1].x, 94, "...with its box")
		check(words[1].conf > 90, "...and its confidence")
	}
}

// ---------------------------------------------------------------------------
// HTTP framing, driven with deliberately cruel splits
// ---------------------------------------------------------------------------

@(private = "file")
feed_split :: proc(raw: string, step: int) -> (status: int, body: string, bad: string) {
	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	data := transmute([]u8)raw
	i := 0
	for i < len(data) {
		n := min(step, len(data) - i)
		decoder_feed(&d, data[i:i + n], &out)
		i += n
	}
	if !decoder_done(&d) {
		decoder_eof(&d)
	}
	return d.status, strings.clone(string(out[:]), context.temp_allocator), d.bad
}

@(private = "file")
test_http_framing :: proc() {
	section("HTTP response framing")

	chunked := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" +
		"9\r\n{\"pages\":\r\n" +
		"b\r\n[{\"index\":0\r\n" +
		"3\r\n}]}\r\n" +
		"0\r\n\r\n"
	want := `{"pages":[{"index":0}]}`

	for step in ([?]int{1, 2, 3, 7, 64, 4096}) {
		st, body, bad := feed_split(chunked, step)
		ok := bad == "" && st == 200 && body == want
		check(ok, "a chunked response decodes when read %d byte%s at a time", step, step == 1 ? "" : "s")
		if !ok {
			note("status %d body %q bad %q", st, body, bad)
		}
	}

	lenbody := "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n"
	st, body, bad := feed_split(lenbody, 3)
	check(bad == "" && st == 200 && len(body) == 13, "a Content-Length response is framed by its length")

	closed := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":1}"
	st2, body2, bad2 := feed_split(closed, 5)
	check(bad2 == "" && st2 == 200 && body2 == `{"ok":1}`, "a response with neither framing ends at the close")

	trunc := "HTTP/1.1 200 OK\r\nContent-Length: 400\r\n\r\n{\"pages\":[{\"index\":0,\"mark"
	_, _, bad3 := feed_split(trunc, 8)
	check(bad3 != "", "a body that stops short of its Content-Length is an error, not a success")

	junk := "NOT HTTP AT ALL\r\n\r\n"
	_, _, bad4 := feed_split(junk, 4)
	check(bad4 != "", "a response with no status line is rejected")

	err401 := "HTTP/1.1 401 Unauthorized\r\nContent-Length: 33\r\n\r\n{\"detail\":\"Unauthorized: bad key\"}"
	st5, body5, _ := feed_split(err401, 1)
	check(st5 == 401 && strings.contains(body5, "bad key"), "an error status and its body both survive")

	section("redaction")
	eq_s(
		redact_header("Authorization: Bearer sk-abc123", context.temp_allocator),
		"Authorization: <redacted>",
		"an API key never reaches the trace",
	)
	eq_s(
		redact_header("Content-Type: application/json", context.temp_allocator),
		"Content-Type: application/json",
		"other headers are kept verbatim",
	)
}

// ---------------------------------------------------------------------------
// ZIP and EPUB
// ---------------------------------------------------------------------------

@(private = "file")
sample_doc :: proc(d: ^Doc) {
	doc_init(d)
	doc_set(&d.title, "The Weather of Small Islands")
	doc_set(&d.source, "/tmp/scan.png")
	doc_set(&d.backend, "tesseract (on this machine)")
	doc_add(d, .Heading, "The Weather of Small Islands", 1, 0, 1)
	doc_add(d, .Paragraph, "A field account of nine summers & one stretch of <water>.", 1, 0)
	doc_add(d, .Heading, "Reading the Cloud", 1, 0, 2)
	doc_add(d, .Paragraph, "Low cloud over the mainland means nothing by itself.", 1, 0)
	doc_add(d, .Page_Break, "", 2, 0)
	doc_add(d, .Heading, "Off the Point", 2, 0, 1)
	doc_add(d, .Paragraph, "The water changes colour before the wind arrives.", 2, 0)
}

@(private = "file")
test_zip_and_epub :: proc() {
	section("EPUB 3 container")

	d: Doc
	sample_doc(&d)
	defer doc_destroy(&d)

	data := doc_to_epub(&d, context.temp_allocator)
	members := zip_list(data, context.temp_allocator)
	check(len(members) >= 6, "the archive has every part (%d members)", len(members))

	if len(members) > 0 {
		eq_s(members[0].name, "mimetype", "mimetype is the first entry in the central directory")
		eq_i(int(members[0].method), 0, "...and it is stored, not deflated")
		eq_s(string(members[0].data), EPUB_MIMETYPE, "...and holds exactly the EPUB media type")
	}
	// OCF lets a reader identify the file from bytes 30..60, which only works
	// when the first local header is mimetype's with no extra field.
	check(len(data) > 60 && string(data[30:38]) == "mimetype", "the local header at offset 30 names mimetype")
	check(len(data) > 68 && string(data[38:38 + len(EPUB_MIMETYPE)]) == EPUB_MIMETYPE, "...and its bytes follow immediately, uncompressed")

	for want in ([?]string{"META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/style.css", "OEBPS/ch001.xhtml"}) {
		_, found := zip_member(members, want)
		check(found, "the archive contains %s", want)
	}

	opf, _ := zip_member(members, "OEBPS/content.opf")
	opf_text := string(opf.data)
	check(strings.contains(opf_text, `unique-identifier="bookid"`), "the package names its unique identifier")
	check(strings.contains(opf_text, `<dc:identifier id="bookid">`), "...and an identifier carries that id")
	check(strings.contains(opf_text, `property="dcterms:modified"`), "dcterms:modified is present, as EPUB 3 requires")
	check(strings.contains(opf_text, `properties="nav"`), "the nav document is declared in the manifest")
	check(strings.contains(opf_text, "<itemref"), "the spine has reading order")
	check(!strings.contains(opf_text, "<water>"), "no unescaped markup reached the package")

	// Two chapters, because the Doc has two level-1 headings.
	_, ch2 := zip_member(members, "OEBPS/ch002.xhtml")
	check(ch2, "a level-1 heading starts a new chapter")

	ch1, _ := zip_member(members, "OEBPS/ch001.xhtml")
	c1 := string(ch1.data)
	check(strings.contains(c1, "<h1>"), "a level-1 heading is an h1")
	check(strings.contains(c1, "<h2>"), "a level-2 heading is an h2")
	check(strings.contains(c1, "&amp;"), "an ampersand from the page is escaped")
	check(strings.contains(c1, "&lt;water&gt;"), "angle brackets from the page are escaped")

	nav, _ := zip_member(members, "OEBPS/nav.xhtml")
	navt := string(nav.data)
	check(strings.contains(navt, `epub:type="toc"`), "the nav document has a toc nav")
	check(strings.contains(navt, `href="ch001.xhtml"`), "...pointing at the first chapter")

	// Reproducibility: the same Doc twice must be byte-identical, which is
	// only true because every timestamp in the ZIP is fixed.
	again := doc_to_epub(&d, context.temp_allocator)
	same := len(again) == len(data)
	if same {
		for i in 0 ..< len(data) {
			if data[i] != again[i] {
				// dcterms:modified is a wall clock and may tick between the
				// two builds; that is the only field allowed to differ.
				same = false
				break
			}
		}
	}
	check(same, "converting the same document twice produces the same archive")

	// xmllint on every XML part, which is the only check that catches a
	// malformed document this program's own reader would accept.
	dir := cache_path("epubparts", context.temp_allocator)
	os.make_directory_all(dir)
	lint_ok := kit.has_tool("xmllint")
	parts := epub_xml_parts(members, context.temp_allocator)
	eq_i(len(parts), 5, "five parts must parse as XML")
	if lint_ok {
		for name in parts {
			m, _ := zip_member(members, name)
			flat, _ := strings.replace_all(name, "/", "_", context.temp_allocator)
			path := fmt.tprintf("%s/%s", dir, flat)
			_ = os.write_entire_file(path, m.data)
			out, ok := kit.run({"xmllint", "--noout", path}, context.temp_allocator)
			check(ok, "xmllint parses %s", name)
			if !ok {
				note("%s", out)
			}
			os.remove(path)
		}
	} else {
		note("xmllint is not installed; the XML parse check was skipped")
	}

	// `unzip -l` is the independent reader: it walks the central directory
	// with code this program did not write.
	if kit.has_tool("unzip") {
		path := fmt.tprintf("%s/check.epub", dir)
		_ = os.write_entire_file(path, data)
		out, ok := kit.run({"unzip", "-l", path}, context.temp_allocator)
		check(ok, "unzip reads the archive")
		if verbose {
			note("%s", out)
		}
		vout, _ := kit.run({"unzip", "-v", path}, context.temp_allocator)
		first_data := strings.index(vout, "mimetype")
		stored := strings.contains(vout, "Stored")
		check(first_data > 0 && stored, "unzip -v reports mimetype as Stored")
		tout, tok := kit.run({"unzip", "-t", path}, context.temp_allocator)
		check(tok && strings.contains(tout, "No errors"), "every CRC in the archive verifies")
		os.remove(path)
	} else {
		note("unzip is not installed; the independent-reader check was skipped")
	}

	// The chapter text must be the Doc's text. This is the assertion that
	// `apps/reader` would make from the outside, done from the inside.
	body := doc_body_text(&d, context.temp_allocator)
	all := strings.builder_make(context.temp_allocator)
	for m in members {
		if !strings.has_suffix(m.name, ".xhtml") || m.name == "OEBPS/nav.xhtml" {
			continue
		}
		// Only what is inside <body>. The <title> in the head repeats the
		// chapter heading, and counting it would make the comparison measure
		// this test's own extractor rather than the exporter.
		src := string(m.data)
		if at := strings.index(src, "<body>"); at >= 0 {
			src = src[at + len("<body>"):]
		}
		if at := strings.index(src, "</body>"); at >= 0 {
			src = src[:at]
		}
		strings.write_string(&all, strip_tags(src, context.temp_allocator))
		strings.write_byte(&all, ' ')
	}
	r := error_rates(strings.to_string(all), body)
	check(r.wer == 0, "the chapter text is exactly the document's text (%s)", rates_line(r, context.temp_allocator))
	if r.wer != 0 {
		note("%s", first_difference(strings.to_string(all), body, 60, context.temp_allocator))
	}
}

// strip_tags is a crude XHTML text extractor, good enough to read back a
// document this program wrote. It is not a parser and is not used anywhere
// but here.
strip_tags :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	in_tag := false
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '<':
			in_tag = true
			strings.write_byte(&b, ' ')
		case c == '>':
			in_tag = false
		case in_tag:
		case c == '&':
			semi := strings.index_byte(s[i:], ';')
			if semi > 0 && semi < 8 {
				switch s[i:i + semi + 1] {
				case "&amp;":
					strings.write_byte(&b, '&')
				case "&lt;":
					strings.write_byte(&b, '<')
				case "&gt;":
					strings.write_byte(&b, '>')
				case "&quot;":
					strings.write_byte(&b, '"')
				case "&apos;":
					strings.write_byte(&b, '\'')
				case:
					strings.write_string(&b, s[i:i + semi + 1])
				}
				i += semi + 1
				continue
			}
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return collapse_spaces(strings.to_string(b), allocator)
}

// ---------------------------------------------------------------------------
// The consent gate, with no server involved at all
// ---------------------------------------------------------------------------

@(private = "file")
test_consent_gate :: proc() {
	section("consent, before any socket exists")

	local := backend_tesseract()
	remote := backend_mistral()

	check(consent_check(&local, Ocr_Request{}) == "", "a local backend needs no consent")

	r1 := consent_check(&remote, Ocr_Request{consent = nil})
	check(r1 != "", "a remote backend with no consent value at all is refused")
	check(strings.contains(r1, "Nothing was sent"), "...and the refusal says nothing was sent")

	c: Consent
	defer consent_destroy(&c)
	r2 := consent_check(&remote, Ocr_Request{consent = &c, endpoint = endpoint_default()})
	check(r2 != "", "a remote backend with consent not yet granted is refused")
	check(strings.contains(r2, MISTRAL_HOST), "...and the refusal names the host it would have uploaded to")

	consent_grant(&c, MISTRAL_HOST, "scan.png", 1234, 1, 0)
	check(consent_check(&remote, Ocr_Request{consent = &c, endpoint = endpoint_default()}) == "", "granted consent lets it through")
	eq_s(c.host, MISTRAL_HOST, "the grant records the host it was given for")
	eq_i(c.bytes, 1234, "...and how many bytes were agreed to")

	consent_revoke(&c)
	check(consent_check(&remote, Ocr_Request{consent = &c}) != "", "revoking consent closes it again")

	section("what the user is shown")
	tmp := cache_path("plan.png", context.temp_allocator)
	_ = os.write_entire_file(tmp, transmute([]u8)strings.repeat("x", 4096, context.temp_allocator))
	defer os.remove(tmp)
	pl := mistral_plan({tmp}, endpoint_default(), 1)
	defer plan_destroy(&pl)
	check(strings.contains(pl.text, MISTRAL_HOST), "the consent text names the host")
	check(strings.contains(pl.text, "plan.png"), "...names the file")
	check(strings.contains(pl.text, "4 kB"), "...states the size")
	check(strings.contains(pl.text, "leaves this machine"), "...says plainly that the document leaves the machine")
	check(strings.contains(pl.text, "Nothing has been sent yet"), "...and that nothing has happened yet")
	check(!strings.contains(strings.to_lower(pl.text, context.temp_allocator), "sk-"), "...and carries no key material")
}

// ---------------------------------------------------------------------------
// The network gate
// ---------------------------------------------------------------------------

@(private = "file")
test_network_gate :: proc() {
	section("the network gate")

	_, loop1 := is_loopback_literal("127.0.0.1")
	check(loop1, "127.0.0.1 is loopback")
	_, loop2 := is_loopback_literal("127.9.9.9")
	check(loop2, "all of 127/8 is loopback")
	_, loop3 := is_loopback_literal("localhost")
	check(loop3, "localhost is matched as a string, with no resolver involved")
	_, loop4 := is_loopback_literal(MISTRAL_HOST)
	check(!loop4, "%s is not loopback", MISTRAL_HOST)
	_, loop5 := is_loopback_literal("128.0.0.1")
	check(!loop5, "128.0.0.1 is not loopback")

	// The real endpoint, with remote access off. This must fail before any
	// DNS lookup and long before any TCP handshake.
	ep := endpoint_default()
	check(!ep.allow_remote, "the default Mistral endpoint has remote access off")
	started := time.tick_now()
	_, err := http_connect(ep, 1000)
	elapsed := time.duration_milliseconds(time.tick_since(started))
	check(err != "", "connecting to %s is refused", MISTRAL_HOST)
	check(strings.contains(err, "Nothing was sent"), "...and says nothing was sent")
	check(elapsed < 50, "...and is refused in %0.1f ms, which is too fast for a lookup", elapsed)

	// Nothing is listening on this port; the point is only that the gate lets
	// a loopback address past it to fail for an honest reason.
	_, err2 := http_connect(Endpoint{host = "127.0.0.1", port = 9, tls = false}, 300)
	check(err2 != "" && !strings.contains(err2, "refusing"), "a loopback address passes the gate and fails on the socket instead")
}

// ---------------------------------------------------------------------------
// TLS
//
// The mock speaks plaintext, which leaves the TLS half of the transport
// untested — and untested TLS is worse than none, because it looks like
// security. `openssl s_server` is on this machine and is a real TLS server, so
// the handshake, the certificate check and the HTTP framing on top of it are
// all driven against it with a throwaway self-signed certificate generated
// here and deleted afterwards.
//
// Both directions are asserted, and the second matters more than the first:
// a client that accepts a self-signed certificate while claiming to verify is
// the common way this code is wrong.
// ---------------------------------------------------------------------------

@(private = "file")
test_tls :: proc(work: string) {
	section("TLS, against a real server")

	if !kit.has_tool("openssl") {
		note("openssl is not installed; the TLS checks were skipped")
		return
	}
	key := fmt.tprintf("%s/tls-key.pem", work)
	crt := fmt.tprintf("%s/tls-cert.pem", work)
	defer {
		os.remove(key)
		os.remove(crt)
	}
	_, gok := kit.run(
		{
			"openssl",
			"req",
			"-x509",
			"-newkey",
			"rsa:2048",
			"-keyout",
			key,
			"-out",
			crt,
			"-days",
			"1",
			"-nodes",
			"-subj",
			"/CN=127.0.0.1",
			"-addext",
			"subjectAltName=IP:127.0.0.1",
		},
		context.temp_allocator,
	)
	if !gok || !os.exists(crt) {
		check(false, "a throwaway self-signed certificate was generated")
		return
	}
	check(true, "a throwaway self-signed certificate was generated")

	port := 18443
	logf, lerr := os.open(
		fmt.tprintf("%s/s_server.log", work),
		os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
		os.Permissions{.Read_User, .Write_User},
	)
	if lerr != nil {
		check(false, "the TLS server log was opened")
		return
	}
	proc_, perr := os.process_start(
		os.Process_Desc {
			command = {
				"openssl",
				"s_server",
				"-quiet",
				"-accept",
				fmt.tprintf("127.0.0.1:%d", port),
				"-cert",
				crt,
				"-key",
				key,
				"-www",
			},
			stdout = logf,
			stderr = logf,
		},
	)
	os.close(logf)
	if perr != nil {
		check(false, "openssl s_server started (%v)", perr)
		return
	}
	defer {
		_ = os.process_kill(proc_)
		_, _ = os.process_wait(proc_)
		os.remove(fmt.tprintf("%s/s_server.log", work))
	}
	time.sleep(400 * time.Millisecond)

	// Verification on, against a certificate nothing has signed: this must
	// fail, and it is the assertion that says verification is really on.
	strict := Endpoint {
		host         = "127.0.0.1",
		port         = port,
		tls          = true,
		allow_remote = false,
		tls_insecure = false,
	}
	_, verr := http_do(strict, "GET", "/", nil, nil, nil, 5000, context.temp_allocator)
	check(verr != "", "a self-signed certificate is rejected when verification is on")
	check(
		strings.contains(verr, "certificate") || strings.contains(verr, "handshake"),
		"...and the reason says so: %s",
		verr,
	)

	// Verification off, which is only ever set for a loopback mock: the
	// handshake completes and the HTTP layer on top of it works.
	loose := strict
	loose.tls_insecure = true
	res, rerr := http_do(loose, "GET", "/", nil, nil, nil, 10000, context.temp_allocator)
	check(rerr == "", "the TLS handshake completes when verification is off: %s", rerr == "" ? "ok" : rerr)
	if rerr == "" {
		eq_i(res.status, 200, "...and a response comes back over it")
		check(len(res.body) > 0, "...with a body (%d bytes), framed by the close", len(res.body))
	}

	// The gate still applies over TLS: the real endpoint is unreachable.
	ep := endpoint_default()
	_, gerr := http_connect(ep, 500)
	check(gerr != "" && strings.contains(gerr, "refusing"), "the gate refuses %s even with TLS available", MISTRAL_HOST)
}

// ---------------------------------------------------------------------------
// The remote backend, against the mock
// ---------------------------------------------------------------------------

@(private = "file")
test_mock_flow :: proc(work: string) {
	section("the remote backend against a local mock")

	m: Mock
	mock_init(&m)
	defer mock_destroy(&m)
	if err := mock_start(&m, 0); err != "" {
		check(false, "the mock server started: %s", err)
		return
	}
	check(m.port > 0, "the mock is listening on 127.0.0.1:%d", m.port)

	img := fmt.tprintf("%s/mock-page.png", work)
	cases := corpus_cases(context.temp_allocator)
	rendered := false
	for c in cases {
		if c.id != "plain" {
			continue
		}
		paths, rerr := corpus_render(c, work, context.temp_allocator)
		if rerr == "" && len(paths) > 0 {
			data, _ := os.read_entire_file_from_path(paths[0], context.temp_allocator)
			_ = os.write_entire_file(img, data)
			rendered = true
		}
	}
	if !rendered {
		check(false, "a page image for the upload test was rendered")
		return
	}
	defer os.remove(img)

	b := backend_mistral()
	ep := endpoint_mock(m.port)
	trace: Trace
	trace_init(&trace)
	defer trace_destroy(&trace)

	// --- WITHOUT CONSENT ---------------------------------------------------
	// The whole remote path is driven with consent withheld, and then the
	// mock's own counter is read. This is the assertion that matters most in
	// this file.
	mock_reset(&m)
	no_consent: Consent
	defer consent_destroy(&no_consent)
	_, err := b.recognize(
		&b,
		Ocr_Request{image_path = img, page = 1, consent = &no_consent, endpoint = ep, trace = &trace},
		context.temp_allocator,
	)
	check(err != "", "with consent withheld, the backend refuses")
	eq_i(mock_count(&m), 0, "the mock received nothing at all")
	eq_i(mock_bytes(&m), 0, "...not one byte of the document")

	_, err_nil := b.recognize(
		&b,
		Ocr_Request{image_path = img, page = 1, consent = nil, endpoint = ep, trace = &trace},
		context.temp_allocator,
	)
	check(err_nil != "", "with no consent value at all, the backend refuses")
	eq_i(mock_count(&m), 0, "the mock still received nothing")

	// --- A KEY IS ALSO REQUIRED --------------------------------------------
	// Consent without a key must not send either. There is no key on this
	// machine, so this is the state the test is already in.
	yes: Consent
	defer consent_destroy(&yes)
	consent_grant(&yes, "127.0.0.1", "mock-page.png", 0, 1, 0)
	have_key, have_key_info := mistral_key()
	defer {
		hk := have_key_info
		key_info_destroy(&hk)
	}
	if have_key == "" {
		mock_reset(&m)
		_, kerr := b.recognize(
			&b,
			Ocr_Request{image_path = img, page = 1, consent = &yes, endpoint = ep, trace = &trace},
			context.temp_allocator,
		)
		check(kerr != "", "consent without an API key still sends nothing")
		check(strings.contains(kerr, "Nothing was sent"), "...and says so")
		eq_i(mock_count(&m), 0, "the mock received nothing")
	} else {
		note("a Mistral key is present in this environment; the no-key case was skipped")
	}

	// --- WITH CONSENT AND A KEY --------------------------------------------
	// The key is invented here and only reaches the mock on loopback. It is
	// not a real credential and does not authenticate against anything.
	os.set_env("MISTRAL_API_KEY", "loopback-only-not-a-real-key-4f2a")
	defer os.unset_env("MISTRAL_API_KEY")
	_, kinfo := mistral_key()
	defer {
		ki := kinfo
		key_info_destroy(&ki)
	}
	check(kinfo.source == .Env, "the key is read from the environment")

	mock_reset(&m)
	trace2: Trace
	trace_init(&trace2)
	defer trace_destroy(&trace2)
	res, rerr := b.recognize(
		&b,
		Ocr_Request{image_path = img, page = 1, consent = &yes, endpoint = ep, trace = &trace2},
		context.allocator,
	)
	defer {
		r := res
		result_destroy(&r)
	}
	check(rerr == "", "with consent and a key, the upload runs: %s", rerr == "" ? "ok" : rerr)
	check(res.kind == .Blocks, "the remote backend returns Markdown, not boxes")
	paths := mock_paths(&m, context.temp_allocator)
	eq_i(len(paths), 1, "an image under the inline limit is one request, not three")
	if len(paths) == 1 {
		eq_s(paths[0], "POST /v1/ocr", "...and that request is the OCR call")
	}
	check(mock_bytes(&m) > 100000, "the document really was sent (%d bytes)", mock_bytes(&m))
	check(strings.contains(res.markdown, "Weather of Small Islands"), "the Markdown came back")

	for l in trace2.lines {
		check(!strings.contains(l, "loopback-only-not-a-real-key"), "the trace carries no key material")
		break
	}
	leaked := false
	for l in trace2.lines {
		if strings.contains(l, "loopback-only-not-a-real-key") {
			leaked = true
		}
	}
	check(!leaked, "no line of the trace contains the key")

	// --- THE THREE-REQUEST PATH --------------------------------------------
	// A PDF is too big to inline, so it goes upload, sign, OCR.
	pdf := fmt.tprintf("%s/mock-upload.pdf", work)
	if werr := write_text_pdf(pdf, {"A short document for the upload path."}); werr == "" {
		defer os.remove(pdf)
		mock_reset(&m)
		res2, e2 := b.recognize(
			&b,
			Ocr_Request{image_path = pdf, page = 1, consent = &yes, endpoint = ep, trace = &trace2},
			context.allocator,
		)
		defer {
			r := res2
			result_destroy(&r)
		}
		check(e2 == "", "a PDF goes through the upload path: %s", e2 == "" ? "ok" : e2)
		p3 := mock_paths(&m, context.temp_allocator)
		eq_i(len(p3), 3, "upload, signed URL, OCR")
		if len(p3) == 3 {
			eq_s(p3[0], "POST /v1/files", "step 1 is the multipart upload")
			check(strings.has_prefix(p3[1], "GET /v1/files/"), "step 2 asks for a signed URL")
			eq_s(p3[2], "POST /v1/ocr", "step 3 is the OCR call")
		}
		// The mock refuses a multipart body with no terminating boundary, so
		// a success here is a statement about the encoder.
		check(e2 == "", "the multipart body the encoder produced was accepted")
	}

	// --- ERRORS ------------------------------------------------------------
	for pair in ([?]struct {
		fail: Mock_Fail,
		want: string,
		name: string,
	} {
		{.Unauthorized, "rejected the API key", "a 401 says the key was rejected"},
		{.Rate_Limited, "rate-limited", "a 429 says the account was rate-limited"},
		{.Malformed, "not JSON", "a non-JSON body is reported as one"},
		{.No_Pages, "no page", "a response with no pages is reported"},
		{.Truncated, "closed before", "a truncated response is an error, not an empty document"},
	}) {
		m.fail = pair.fail
		mock_reset(&m)
		_, ferr := b.recognize(
			&b,
			Ocr_Request{image_path = img, page = 1, consent = &yes, endpoint = ep, trace = &trace2},
			context.temp_allocator,
		)
		ok := ferr != "" && strings.contains(ferr, pair.want)
		check(ok, "%s", pair.name)
		if !ok {
			note("got %q", ferr)
		}
	}
	m.fail = .None

	// A request with no Authorization header is refused by the mock, which is
	// how we know the header is really being sent on every call.
	section("Markdown from a service, back into a Doc")
	d: Doc
	doc_init(&d)
	defer doc_destroy(&d)
	markdown_to_doc(MOCK_MARKDOWN, &d)
	heads := 0
	paras := 0
	for blk in d.blocks {
		if blk.kind == .Heading {heads += 1}
		if blk.kind == .Paragraph {paras += 1}
	}
	eq_i(heads, 2, "two headings survive the Markdown round trip")
	check(paras >= 3, "the paragraphs survive (%d)", paras)
	if len(d.blocks) > 0 {
		eq_s(d.blocks[0].text, "The Weather of Small Islands", "the first heading is the title")
		eq_i(d.blocks[0].level, 1, "...at level 1")
	}
	found_fig := false
	for blk in d.blocks {
		if blk.text == "[figure]" {found_fig = true}
	}
	check(found_fig, "an extracted figure is noted rather than silently dropped")
	eq_i(d.pages, 2, "the page separator split the document in two")

	// The whole conversion, through the public entry point.
	section("a full conversion through the remote backend")
	o := default_opts()
	o.backend = .Mistral
	o.endpoint = ep
	o.consent = &yes
	d2: Doc
	doc_init(&d2)
	defer doc_destroy(&d2)
	st: Convert_Stats
	defer stats_destroy(&st)
	cerr := convert(img, o, &d2, &st)
	check(cerr == "", "convert() runs the remote backend end to end: %s", cerr == "" ? "ok" : cerr)
	check(len(d2.blocks) > 0, "...and produces a document")
	saw_note := false
	for n in d2.notes {
		if strings.contains(n, "structure is the service's") {
			saw_note = true
		}
	}
	check(saw_note, "...and says plainly that the structure is the service's, not ours")
}

// ---------------------------------------------------------------------------
// The corpus: the measurement
// ---------------------------------------------------------------------------

@(private = "file")
Case_Result :: struct {
	id:     string,
	rates:  Error_Rates,
	blocks: int,
	want:   int,
}

@(private = "file")
test_corpus :: proc(work: string) {
	section("accuracy against text we generated")

	if !kit.has_tool("tesseract") {
		check(false, "tesseract is installed (every accuracy figure below needs it)")
		return
	}
	dir := fmt.tprintf("%s/corpus", work)
	os.make_directory_all(dir)

	cases := corpus_cases(context.temp_allocator)
	results := make([dynamic]Case_Result, context.temp_allocator)

	for c in cases {
		paths, rerr := corpus_render(c, dir, context.temp_allocator)
		if rerr != "" {
			check(false, "%s: rendered (%s)", c.id, rerr)
			continue
		}
		defer for pth in paths {
			os.remove(pth)
		}

		want: Doc
		doc_init(&want)
		defer doc_destroy(&want)
		corpus_truth(c, &want)

		got: Doc
		doc_init(&got)
		defer doc_destroy(&got)
		st: Convert_Stats
		defer stats_destroy(&st)

		o := default_opts()
		if cerr := convert_images(paths, o, &got, &st); cerr != "" {
			check(false, "%s: converted (%s)", c.id, cerr)
			continue
		}

		r := error_rates(doc_body_text(&got, context.temp_allocator), doc_body_text(&want, context.temp_allocator))
		append(&results, Case_Result{id = c.id, rates = r, blocks = block_count(&got), want = block_count(&want)})

		fmt.printfln("      %-12s %s   %s", c.id, rates_line(r, context.temp_allocator), c.what)
		if verbose && r.wer > 0 {
			note("%s", first_difference(doc_body_text(&got, context.temp_allocator), doc_body_text(&want, context.temp_allocator), 70, context.temp_allocator))
		}

		// Per-case structural assertions. These are the ones that say whether
		// the output is readable, which an error rate does not.
		switch c.id {
		case "plain":
			check(r.cer < 0.02, "plain: the characters are right (CER %.2f%%)", r.cer * 100)
			eq_i(block_count(&got), 3, "plain: three paragraphs, not one and not nine")
		case "indented":
			eq_i(block_count(&got), 3, "indented: a first-line indent starts a paragraph with no blank line to help")
			saw := false
			for n in got.notes {
				if strings.contains(n, "first-line indents") {saw = true}
			}
			check(saw, "indented: the note says the indent was the signal")
		case "headings":
			levels := make([dynamic]int, context.temp_allocator)
			for blk in got.blocks {
				if blk.kind == .Heading {
					append(&levels, blk.level)
				}
			}
			eq_i(len(levels), 3, "headings: three headings were found")
			if len(levels) == 3 {
				eq_i(levels[0], 1, "headings: the 62px line is a level-1 heading")
				eq_i(levels[1], 2, "headings: the 46px line is a level-2 heading")
				eq_i(levels[2], 3, "headings: the 38px line is a level-3 heading")
			}
		case "two-column":
			eq_i(st.columns, 2, "two-column: two columns were detected")
			text := doc_body_text(&got, context.temp_allocator)
			li := strings.index(text, "gutter between")
			ri := strings.index(text, "right column says")
			check(li >= 0 && ri > li, "two-column: the left column is read before the right, not interleaved")
			check(strings.index(text, "Title Across Both") >= 0 && strings.index(text, "Title Across Both") < li, "two-column: the full-width title comes first")
			check(r.wer < 0.05, "two-column: the words are right (WER %.2f%%)", r.wer * 100)
		case "hyphen":
			text := doc_body_text(&got, context.temp_allocator)
			check(strings.contains(text, "weathervane"), "hyphen: a word broken across a line end was rejoined")
			check(strings.contains(text, "south-west"), "hyphen: a real compound kept its hyphen")
			check(!strings.contains(text, "weather- vane"), "hyphen: no stray hyphen and space was left behind")
		case "furniture":
			text := doc_body_text(&got, context.temp_allocator)
			check(!strings.contains(strings.to_lower(text, context.temp_allocator), "weather of small islands"), "furniture: the running header is gone from the text")
			check(!strings.contains(text, "Page 2 of 3"), "furniture: the running footer is gone too")
			check(strings.contains(text, "lifeboat"), "furniture: the body text is still there")
			eq_i(st.dropped, 6, "furniture: six lines were dropped, a header and a footer from each of three pages")
			saw := false
			for n in got.notes {
				if strings.contains(n, "running header") {saw = true}
			}
			check(saw, "furniture: the removal is reported, not silent")
		case "flush":
			eq_i(block_count(&got), 3, "flush: the short-last-line rule found the paragraphs on its own")
			saw := false
			for n in got.notes {
				if strings.contains(n, "short last lines") {saw = true}
			}
			check(saw, "flush: the note says which signal was used")
		case "sizes":
			heads := 0
			for blk in got.blocks {
				if blk.kind == .Heading {heads += 1}
			}
			eq_i(heads, 0, "sizes: three body sizes on one page produced no false headings")
			eq_i(block_count(&got), 3, "sizes: three paragraphs")
		case "scanned":
			check(r.cer < 0.03, "scanned: a blurred, noisy, half-resolution page still reads (CER %.2f%%)", r.cer * 100)
			eq_i(block_count(&got), 3, "scanned: and the paragraphs still separate")
		case "skewed":
			check(r.cer < 0.02, "skewed: six degrees was straightened and read (CER %.2f%%)", r.cer * 100)
			eq_i(st.deskewed, 1, "skewed: the page was straightened before recognition")
			saw := false
			for n in got.notes {
				if strings.contains(n, "straightened") {saw = true}
			}
			check(saw, "skewed: the correction is reported, not silent")
		case "rotated":
			check(r.cer < 0.05, "rotated: 1.5 degrees of skew did not break the line grouper (CER %.2f%%)", r.cer * 100)
			eq_i(block_count(&got), 3, "rotated: the paragraphs still separated")
		}
	}

	// The summary table, which is the part worth reading.
	fmt.println()
	fmt.println("      case          CER      WER    blocks (want)")
	worst := f64(0)
	for res in results {
		fmt.printfln(
			"      %-12s %6.2f%%  %6.2f%%   %d (%d)",
			res.id,
			res.rates.cer * 100,
			res.rates.wer * 100,
			res.blocks,
			res.want,
		)
		worst = max(worst, res.rates.cer)
	}
	check(worst < 0.03, "no case has a character error rate above 3%% (worst %.2f%%)", worst * 100)
}

@(private = "file")
block_count :: proc(d: ^Doc) -> int {
	n := 0
	for b in d.blocks {
		if b.kind != .Page_Break {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// PDFs: the text layer, and the absence of one
// ---------------------------------------------------------------------------

@(private = "file")
test_pdfs :: proc(work: string) {
	section("PDFs with and without a text layer")

	if !kit.has_tool("pdftotext") || !kit.has_tool("pdftoppm") {
		check(false, "poppler (pdftotext, pdftoppm) is installed")
		return
	}

	lines := []string {
		"The Weather of Small Islands",
		"",
		"The harbour was empty by the time the wind turned, and the boats",
		"that had been there all morning were drawn up above the tideline",
		"with their sails furled and tied.",
		"",
		"Nobody on the island kept a barometer, which is not the same thing",
		"as nobody knowing what the weather would do.",
	}
	born := fmt.tprintf("%s/born-digital.pdf", work)
	if werr := write_text_pdf(born, lines); werr != "" {
		check(false, "a PDF with a text layer was written (%s)", werr)
		return
	}
	defer os.remove(born)

	// An independent reader has to accept the file, or the rest proves
	// nothing about PDFs.
	if kit.has_tool("pdfinfo") {
		eq_i(pdf_page_count(born), 1, "pdfinfo reads the hand-written PDF and sees one page")
	}

	tl := pdf_text_layer(born, 3, context.temp_allocator)
	check(tl.present, "the text layer is detected (%.0f letters per page)", tl.per_page)
	check(tl.per_page > TEXT_LAYER_PER_PAGE, "...well above the threshold of %.0f", f64(TEXT_LAYER_PER_PAGE))

	d: Doc
	doc_init(&d)
	defer doc_destroy(&d)
	st: Convert_Stats
	defer stats_destroy(&st)
	o := default_opts()
	cerr := convert(born, o, &d, &st)
	check(cerr == "", "it converts: %s", cerr == "" ? "ok" : cerr)
	check(st.text_layer, "it was read, not OCRed")
	eq_i(st.ocr_pages, 0, "no page was handed to a recogniser")
	eq_s(st.backend, "pdftotext", "the backend used was pdftotext")

	text := doc_body_text(&d, context.temp_allocator)
	want := strings.join(lines, " ", context.temp_allocator)
	r := error_rates(text, want)
	check(r.cer == 0, "the text layer round-trips exactly (%s)", rates_line(r, context.temp_allocator))
	if r.cer != 0 {
		note("%s", first_difference(text, want, 70, context.temp_allocator))
	}
	saw := false
	for n in d.notes {
		if strings.contains(n, "nothing was OCRed") {saw = true}
	}
	check(saw, "the decision not to OCR is reported to the user")

	// --force-ocr is the override, and it must say that it is the worse
	// choice rather than quietly being it.
	d2: Doc
	doc_init(&d2)
	defer doc_destroy(&d2)
	st2: Convert_Stats
	defer stats_destroy(&st2)
	o2 := default_opts()
	o2.force_ocr = true
	o2.dpi = 200
	if cerr2 := convert(born, o2, &d2, &st2); cerr2 == "" {
		check(!st2.text_layer, "--force-ocr overrides the detection")
		check(st2.ocr_pages == 1, "...and really does OCR the page")
		saw2 := false
		for n in d2.notes {
			if strings.contains(n, "would have been exact") {saw2 = true}
		}
		check(saw2, "...and says the text layer would have been better")
	} else {
		check(false, "--force-ocr converts (%s)", cerr2)
	}

	// --- a scan: the same page, as pixels only -----------------------------
	cases := corpus_cases(context.temp_allocator)
	png := ""
	for c in cases {
		if c.id != "plain" {
			continue
		}
		paths, rerr := corpus_render(c, work, context.temp_allocator)
		if rerr == "" && len(paths) > 0 {
			png = paths[0]
		}
	}
	if png == "" {
		check(false, "a page image for the scanned PDF was rendered")
		return
	}
	defer os.remove(png)

	scan := fmt.tprintf("%s/scanned.pdf", work)
	if werr := write_scan_pdf(scan, png, 200); werr != "" {
		check(false, "a scanned PDF was written (%s)", werr)
		return
	}
	defer os.remove(scan)

	tl2 := pdf_text_layer(scan, 3, context.temp_allocator)
	check(!tl2.present, "a scanned PDF has no text layer (%d letters found)", tl2.letters)

	d3: Doc
	doc_init(&d3)
	defer doc_destroy(&d3)
	st3: Convert_Stats
	defer stats_destroy(&st3)
	o3 := default_opts()
	o3.dpi = 200
	cerr3 := convert(scan, o3, &d3, &st3)
	check(cerr3 == "", "a scanned PDF converts: %s", cerr3 == "" ? "ok" : cerr3)
	check(!st3.text_layer, "...by OCR")
	eq_i(st3.ocr_pages, 1, "...one page through the recogniser")

	// The ground truth is the same `plain` case, so this is a real accuracy
	// figure for the whole PDF path and not just for the image path.
	wantd: Doc
	doc_init(&wantd)
	defer doc_destroy(&wantd)
	for c in cases {
		if c.id == "plain" {
			corpus_truth(c, &wantd)
		}
	}
	r3 := error_rates(doc_body_text(&d3, context.temp_allocator), doc_body_text(&wantd, context.temp_allocator))
	check(r3.cer < 0.05, "the scanned PDF round-trips (%s)", rates_line(r3, context.temp_allocator))

	// And the whole point: it becomes an EPUB.
	epub_path := fmt.tprintf("%s/scanned.epub", work)
	werr := write_export(&d3, .Epub, epub_path, true)
	check(werr == "", "the scan becomes an EPUB: %s", werr == "" ? "ok" : werr)
	if werr == "" {
		defer os.remove(epub_path)
		data, _ := os.read_entire_file_from_path(epub_path, context.temp_allocator)
		members := zip_list(data, context.temp_allocator)
		check(len(members) > 0 && members[0].name == "mimetype", "...with mimetype first")
		if kit.has_tool("unzip") {
			out, ok := kit.run({"unzip", "-t", epub_path}, context.temp_allocator)
			check(ok && strings.contains(out, "No errors"), "...and unzip verifies every CRC")
		}
	}
}

// ---------------------------------------------------------------------------
// Does another program agree this is a book?
//
// `apps/reader` is an EPUB reader built against the same toolkit by somebody
// else, and it parses the container independently: its own ZIP reader, its own
// OPF parser, its own XHTML parser. If it opens a file this program wrote and
// counts the same chapters and the same blocks, then the EPUB is an EPUB by
// more than this program's own say-so.
//
// It is a soft dependency on purpose. The binary may not be built, and its
// `--bench` output is its own business and may change, so a parse failure is a
// note rather than a failure: this test is allowed to say "I could not check",
// and never to fail because another application was mid-edit.
// ---------------------------------------------------------------------------

@(private = "file")
test_reader_interop :: proc(work: string) {
	section("the EPUB, opened by another program")

	bin := ""
	for c in ([?]string{"apps/reader/reader.bin", "/home/alex/Work/palmy/apps/reader/reader.bin"}) {
		if os.exists(c) {
			bin = c
			break
		}
	}
	if bin == "" {
		note("apps/reader is not built; the independent-reader check was skipped")
		return
	}

	d: Doc
	sample_doc(&d)
	defer doc_destroy(&d)
	path := fmt.tprintf("%s/interop.epub", work)
	if werr := write_export(&d, .Epub, path, true); werr != "" {
		check(false, "the EPUB for the interop check was written (%s)", werr)
		return
	}
	defer os.remove(path)

	chapters := doc_chapters(&d, context.temp_allocator)
	want_blocks := 0
	for b in d.blocks {
		if b.kind != .Page_Break {
			want_blocks += 1
		}
	}

	out, ok := kit.run({bin, "--bench", path}, context.temp_allocator)
	if !ok {
		note("apps/reader would not run on it; the check was skipped")
		if verbose {
			note("%s", out)
		}
		return
	}
	check(true, "apps/reader opened the EPUB without complaint")

	got_ch, got_bl := -1, -1
	for line in strings.split_lines(out, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "chapters":
			got_ch, _ = strconv.parse_int(f[1], 10)
		case "blocks":
			got_bl, _ = strconv.parse_int(f[1], 10)
		}
	}
	if got_ch < 0 || got_bl < 0 {
		note("apps/reader reported something this test does not know how to read; skipped")
		return
	}
	eq_i(got_ch, len(chapters), "apps/reader counts the same chapters")
	// Its `blocks` figure is for the first chapter, which is where every
	// block of this document lives when there is only one.
	if len(chapters) == 1 {
		eq_i(got_bl, want_blocks, "...and the same blocks in it")
	} else {
		check(got_bl > 0, "...and found %d blocks in the first chapter", got_bl)
	}
	// The text itself: `--bench` runs a search, so a word only in our text
	// having hits is a statement that the words arrived.
	check(strings.contains(out, "search"), "...and could search the text it extracted")
}

// ---------------------------------------------------------------------------
// A missing recogniser
// ---------------------------------------------------------------------------

@(private = "file")
test_missing_tool :: proc() {
	section("a missing local recogniser")

	// PATH is emptied so `tesseract` genuinely cannot be found, which
	// exercises the real probe rather than a flag.
	saved := os.get_env("PATH", context.allocator)
	defer {
		os.set_env("PATH", saved)
		delete(saved)
	}
	os.set_env("PATH", "/nonexistent")

	b := backend_tesseract()
	ok, why := b.probe(&b)
	defer if why != "" {delete(why)}
	check(!ok, "the probe reports that tesseract is missing")
	check(strings.contains(why, "Install"), "...and says how to fix it")
	check(strings.contains(why, "Nothing will be uploaded"), "...and promises not to upload instead")

	d: Doc
	doc_init(&d)
	defer doc_destroy(&d)
	st: Convert_Stats
	defer stats_destroy(&st)
	o := default_opts()
	err := convert_images({"/nonexistent/page.png"}, o, &d, &st)
	check(err != "", "a conversion with no recogniser fails")
	check(strings.contains(err, "tesseract"), "...naming the tool that is missing")
	check(!strings.contains(strings.to_lower(err, context.temp_allocator), "mistral"), "...and does not offer the network as a fix")
	eq_i(len(d.blocks), 0, "...and produces no document")
	eq_s(st.backend, "", "...and never selected a backend")
}

// ---------------------------------------------------------------------------
// The interface, with no compositor
// ---------------------------------------------------------------------------

@(private = "file")
step :: proc(off: ^p.Offscreen, m: ^App) {
	ui := p.offscreen_begin(off)
	tick(m)
	keys(ui, m)
	build(ui, m)
	p.offscreen_end(off)
}

@(private = "file")
ink :: proc(off: ^p.Offscreen) -> f64 {
	px := p.offscreen_pixels(off)
	n := 0
	first := len(px) > 0 ? px[0] : 0
	for v in px {
		if v != first {
			n += 1
		}
	}
	return f64(n) / f64(max(1, len(px)))
}

@(private = "file")
test_interface :: proc() {
	section("the interface, with no compositor")

	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_ui_fonts(&off.fonts)

	m := new(App)
	defer free(m)
	app_init(m)
	defer app_destroy(m)

	step(off, m)
	step(off, m)
	check(ink(off) > 0.01, "the window drew something (ink %.3f)", ink(off))

	// Views.
	p.press_key(off, '2')
	step(off, m)
	check(m.view == .Structure, "2 shows the structure view")
	p.press_key(off, '3')
	step(off, m)
	check(m.view == .Notes, "3 shows the notes view")
	p.press_key(off, '1')
	step(off, m)
	check(m.view == .Document, "1 comes back to the document")

	// Settings.
	before := m.dpi
	p.press_key(off, 'd')
	step(off, m)
	check(m.dpi != before, "d changes the rasterisation dpi (%d -> %d)", before, m.dpi)
	p.press_key(off, 'f')
	step(off, m)
	check(m.force_ocr, "f turns on --force-ocr")
	check(m.status_bad, "...and says so as a warning, because it is the worse choice")
	p.press_key(off, 'f')
	step(off, m)
	check(!m.force_ocr, "f turns it off again")

	// --- the remote backend cannot even be selected without a key ----------
	os.unset_env("MISTRAL_API_KEY")
	key_info_destroy(&m.key)
	_, m.key = mistral_key()
	if m.key.source == .None {
		p.press_key(off, 'b')
		step(off, m)
		check(m.backend == .Tesseract, "with no API key, b does not select the remote backend")
		check(strings.contains(m.status, "API key"), "...and says what is missing")
	} else {
		note("a Mistral key is present in this environment; the no-key case was skipped")
	}

	// --- with a key, selecting it still uploads nothing --------------------
	os.set_env("MISTRAL_API_KEY", "loopback-only-not-a-real-key-4f2a")
	defer os.unset_env("MISTRAL_API_KEY")
	key_info_destroy(&m.key)
	_, m.key = mistral_key()

	p.press_key(off, 'b')
	step(off, m)
	check(m.backend == .Mistral, "with a key, b selects the remote backend")
	check(!m.consent.granted, "...and consent is still not granted")
	check(!m.asking, "...and no overlay is up yet, because nothing was asked for")

	// Point it at a file and ask for a conversion. This must put the question
	// up rather than convert.
	work := cache_path("ui", context.temp_allocator)
	os.make_directory_all(work)
	img := fmt.tprintf("%s/ui-page.png", work)
	cases := corpus_cases(context.temp_allocator)
	for c in cases {
		if c.id != "plain" {
			continue
		}
		if paths, rerr := corpus_render(c, work, context.temp_allocator); rerr == "" && len(paths) > 0 {
			data, _ := os.read_entire_file_from_path(paths[0], context.temp_allocator)
			_ = os.write_entire_file(img, data)
			os.remove(paths[0])
		}
	}
	defer os.remove(img)
	open_path(m, img)
	check(m.src != "", "a page image is open")

	p.press_key(off, 'c')
	step(off, m)
	check(m.asking, "asking to convert with the remote backend puts the consent question up")
	check(!job_busy(), "...and starts no job")
	check(!m.consent.granted, "...and grants nothing")
	check(strings.contains(m.plan.text, MISTRAL_HOST), "the question names the host")
	check(strings.contains(m.plan.text, "ui-page.png"), "...and the file")

	// While the overlay is up, the keys that would normally do something do
	// nothing at all.
	for ch in ([?]rune{'1', 'c', 'e', 'o', 't'}) {
		p.press_key(off, u32(ch))
	}
	step(off, m)
	check(m.asking, "the overlay eats every other key")
	check(m.view == .Document, "...including the view keys")
	check(!m.consent.granted, "...and Enter-ish keys do not grant consent")

	p.press_key(off, p.KEY_RETURN)
	step(off, m)
	check(!m.consent.granted, "Return does not grant consent")
	p.press_key(off, p.KEY_SPACE)
	step(off, m)
	check(!m.consent.granted, "Space does not grant consent")

	p.press_key(off, 'n')
	step(off, m)
	check(!m.asking, "n closes the question")
	check(!m.consent.granted, "...having granted nothing")
	check(m.backend == .Tesseract, "...and puts the local recogniser back")
	eq_i(m.trace.calls, 0, "no request was ever made")

	// The local path, end to end, through the interface.
	section("a conversion through the interface")
	p.press_key(off, 'c')
	step(off, m)
	check(job_busy(), "a job started")
	for i in 0 ..< 600 {
		if !job_busy() {
			break
		}
		time.sleep(25 * time.Millisecond)
		_ = i
	}
	step(off, m)
	check(m.have_doc, "the conversion finished and produced a document")
	check(len(m.doc.blocks) >= 3, "...with the paragraphs in it (%d blocks)", len(m.doc.blocks))
	eq_i(m.trace.calls, 0, "...and still made no network request of any kind")

	p.press_key(off, 'e')
	step(off, m)
	check(strings.contains(m.status, ".epub"), "e exported an EPUB: %s", m.status)
	check(!m.status_bad, "...without an error")
	epub_at := default_export_path(m.src, .Epub, context.temp_allocator)
	check(os.exists(epub_at), "...and the file is on disk at %s", epub_at)

	check(ink(off) > 0.02, "the document view has content (ink %.3f)", ink(off))
}

load_ui_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}
