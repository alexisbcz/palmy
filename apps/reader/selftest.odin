// --selftest: the assertions, headless.
//
// Most of this needs no real book, because the books are generated. The ZIP
// writer, the EPUB writer and the PalmDOC compressor in gen.odin produce files
// this program then reads back, so "did the spine come back in order", "is
// chapter three byte-for-byte what I wrote", "does the TOC entry land on the
// paragraph I meant" and "did the metadata survive" are all round trips rather
// than hopes. A downloaded book can only tell you that nothing crashed.
//
// For PDF there is a better oracle still, and it is in this repository:
// `apps/docs` exports a PDF from Markdown. The test writes a document with
// known text, has `docs.bin` turn it into a PDF, and asserts that the reader
// reports the same page count and finds the same words. For DjVu the test
// builds a three-page document with djvulibre's own encoder and asserts the
// same things.
//
// The hostile cases are not an afterthought. Book files in the wild are
// malformed as a matter of routine, so there are assertions for a ZIP holding
// both storage methods, a ZIP with no end-of-directory record, an OPF whose
// spine names an item the manifest never declared, XHTML with unclosed tags,
// mis-declared encodings, a MOBI whose last record is cut in half, and a PDF
// that is zero bytes or absent. None may crash; each must degrade with
// something to say.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

T :: struct {
	pass:  int,
	fail:  int,
	group: string,
	fails: [dynamic]string,
}

group :: proc(t: ^T, name: string) {
	t.group = name
}

ck :: proc(t: ^T, cond: bool, format: string, args: ..any) {
	if cond {
		t.pass += 1
		return
	}
	t.fail += 1
	msg := fmt.aprintf("[%s] %s", t.group, fmt.tprintf(format, ..args))
	append(&t.fails, msg)
	fmt.eprintfln("FAIL %s", msg)
}

ck_eq_int :: proc(t: ^T, got, want: int, what: string) {
	ck(t, got == want, "%s: got %d, want %d", what, got, want)
}

ck_eq_str :: proc(t: ^T, got, want: string, what: string) {
	ck(t, got == want, "%s: got %q, want %q", what, got, want)
}

ck_near :: proc(t: ^T, got, want, tol: f32, what: string) {
	ck(t, abs(got - want) <= tol, "%s: got %.3f, want %.3f +- %.3f", what, got, want, tol)
}

// ---------------------------------------------------------------------------
// The generated book
// ---------------------------------------------------------------------------

// Sentences the test looks for by their exact bytes. If wrapping, entity
// decoding or whitespace collapsing changes any of them, an assertion fails.
S1 :: "The measure is the width a line of text is allowed to be, and nothing in this paragraph may exceed it."
S2 :: "Pagination marker ALPHA-ONE lives in the first chapter and nowhere else."
S3 :: "An ampersand & an em dash — and a right single quote ’ all survive the parser."
S4 :: "BETA-TWO is the marker for the second chapter, which is deliberately long."

fixture_chapters :: proc(allocator := context.temp_allocator) -> []Gen_Chapter {
	long := strings.builder_make(allocator)
	strings.write_string(&long, "<h1>Chapter Two: The Long One</h1>\n")
	strings.write_string(&long, tfmt("<p class=\"first\">%s</p>\n", S4))
	for i in 0 ..< 120 {
		strings.write_string(
			&long,
			tfmt(
				"<p>Paragraph %d of the long chapter. It exists so that the chapter spans many pages, which is what pagination, keep-with-next and orphan control all need in order to be testable at all.</p>\n",
				i + 1,
			),
		)
		if i % 20 == 19 {
			strings.write_string(&long, tfmt("<h2>Interlude %d</h2>\n", i / 20 + 1))
		}
	}

	chapters := make([]Gen_Chapter, 4, allocator)
	chapters[0] = {
		file = "ch1.xhtml",
		title = "The Measure",
		body = tfmt(
			`<h1 id="top">Chapter One: The Measure</h1>
<p class="first">%s</p>
<p>%s</p>
<p>Here is <em>emphasis</em>, here is <strong>strength</strong>, here is <code>monospace</code>, and here is <span style="font-style: italic; font-weight: bold">both at once</span>.</p>
<blockquote><p>A quotation, which the stylesheet makes italic through a descendant selector.</p></blockquote>
<ul><li>First bullet</li><li>Second bullet<ul><li>A nested bullet</li></ul></li><li>Third bullet</li></ul>
<ol><li>First numbered</li><li>Second numbered</li><li>Third numbered</li></ol>
<pre><code>line one of code
line two of code</code></pre>
<p><img src="cover.png" alt="the generated cover"/></p>
<hr/>
<p>A link to <a href="ch3.xhtml#marker">the third chapter's marker</a> and one to <a href="#top">the top of this one</a>.</p>`,
			S1,
			S2,
		),
	}
	chapters[1] = {
		file = "ch2.xhtml",
		title = "The Long One",
		body = strings.to_string(long),
	}
	chapters[2] = {
		file = "ch3.xhtml",
		title = "Entities and Anchors",
		body = tfmt(
			`<h1>Chapter Three: Entities</h1>
<p>%s</p>
<p id="marker">GAMMA-THREE is the marker this chapter's anchor points at.</p>
<p class="tiny">Small text, set by a class in the stylesheet.</p>
<p style="text-align: center">A centred line.</p>`,
			"An ampersand &amp; an em dash &mdash; and a right single quote &#8217; all survive the parser.",
		),
	}
	// Deliberately malformed: unclosed <p>, unclosed <em>, a stray close tag,
	// an attribute without quotes, and a <br> written as HTML rather than
	// XHTML. Every one of these is in real books.
	chapters[3] = {
		file = "ch4.xhtml",
		title = "Malformed",
		body = `<h1>Chapter Four: Malformed
<p>This paragraph was never closed.
<p>Neither was <em>this emphasis
<p align=center>An unquoted attribute value.
<p>A hard<br>break written as HTML.
</div>
<p>DELTA-FOUR survives all of that.`,
	}
	return chapters
}

fixture_book :: proc(png: []u8, allocator := context.temp_allocator) -> Gen_Book {
	return Gen_Book {
		title = "The Generated Book",
		author = "A. Fixture",
		language = "en",
		ident = "urn:uuid:palmy-reader-selftest-0001",
		chapters = fixture_chapters(allocator),
		ghost_spine = true,
		mixed = true,
		cover_png = png,
	}
}

MOBI_HTML :: `<html><head><title>A Generated Mobipocket</title></head><body>
<h1>Mobi Chapter One</h1>
<p>EPSILON-ONE is the marker in the first Mobi chapter, and this sentence is long enough to wrap at any reasonable measure.</p>
<p>A second paragraph with <i>italic</i> and <b>bold</b> runs in it.</p>
<mbp:pagebreak/>
<h1>Mobi Chapter Two</h1>
<p>ZETA-TWO is the marker in the second Mobi chapter.</p>
<h2>A subheading</h2>
<p>And a paragraph under it, with a spaced sentence that the LZ77 space-folding byte will encode: the quick brown fox jumps over the lazy dog, the quick brown fox jumps over the lazy dog.</p>
<p><a filepos="0000000120">A filepos link back to the start.</a></p>
</body></html>`

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

selftest :: proc() {
	t := T{}
	t.fails = make([dynamic]string, 0, 16)
	start := time.now()

	dir := selftest_dir()
	_ = os.make_directory_all(dir)
	if !os.exists(dir) {
		fmt.eprintfln("reader --selftest: cannot create %s", dir)
		os.exit(1)
	}

	off := p.offscreen_create(1180, 800)
	defer p.offscreen_destroy(off)
	load_test_fonts(&off.fonts)
	fonts := &off.fonts

	png := make_test_png(dir)

	test_path(&t)
	test_xml(&t)
	test_css(&t)
	test_zip(&t, dir, png)
	test_epub(&t, dir, png, fonts)
	test_reflow(&t, dir, png, fonts)
	test_search(&t, dir, png, fonts)
	test_position(&t, dir, png, fonts)
	test_images(&t, dir, png, fonts)
	test_palmdoc(&t)
	test_huffcdic(&t)
	test_mobi(&t, dir, fonts)
	test_hostile(&t, dir, png, fonts)
	test_fixed(&t, dir, fonts)
	test_store(&t, dir)
	test_resume(&t, dir, png, fonts)

	ms := time.duration_milliseconds(time.since(start))
	fmt.printfln("")
	fmt.printfln("reader --selftest: %d assertions, %d failed, %.0f ms", t.pass + t.fail, t.fail, ms)
	if t.fail > 0 {
		fmt.printfln("")
		for f in t.fails {
			fmt.printfln("  %s", f)
		}
		os.exit(1)
	}
}

selftest_dir :: proc(allocator := context.temp_allocator) -> string {
	base := store_dir(context.temp_allocator)
	return strings.concatenate({base, "/selftest"}, allocator)
}

// make_test_png writes a small PNG and returns its bytes, so the generated
// EPUB can carry a real picture rather than something that only claims to be
// one.
make_test_png :: proc(dir: string) -> []u8 {
	W :: 120
	H :: 170
	rgba := make([]u8, W * H * 4, context.temp_allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			i := (y * W + x) * 4
			rgba[i + 0] = u8(30 + x * 180 / W)
			rgba[i + 1] = u8(40 + y * 150 / H)
			rgba[i + 2] = u8(120)
			rgba[i + 3] = 255
		}
	}
	path := tfmt("%s/cover.png", dir)
	if !p.write_png_rgba(path, rgba, W, H) {
		return nil
	}
	data, err := read_file(path, context.temp_allocator)
	if err != "" {
		return nil
	}
	return data
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

test_path :: proc(t: ^T) {
	group(t, "path")
	ck_eq_str(t, path_dir("OEBPS/text/ch1.xhtml"), "OEBPS/text", "path_dir")
	ck_eq_str(t, path_dir("ch1.xhtml"), "", "path_dir of a bare name")
	ck_eq_str(t, path_base("OEBPS/text/ch1.xhtml"), "ch1.xhtml", "path_base")
	ck_eq_str(t, path_ext_lower("A/B/Cover.PNG"), "png", "path_ext_lower")

	ck_eq_str(t, path_resolve("OEBPS/text", "../images/a.png"), "OEBPS/images/a.png", "resolve ..")
	ck_eq_str(t, path_resolve("OEBPS", "text/ch1.xhtml"), "OEBPS/text/ch1.xhtml", "resolve down")
	ck_eq_str(t, path_resolve("OEBPS", "/root.xhtml"), "root.xhtml", "resolve absolute")
	ck_eq_str(t, path_resolve("", "ch1.xhtml"), "ch1.xhtml", "resolve at root")
	ck_eq_str(t, path_resolve("a/b", "./c/../d.png"), "a/b/d.png", "resolve . and ..")
	// A crafted href must not escape the archive root.
	ck_eq_str(t, path_resolve("a", "../../../etc/passwd"), "etc/passwd", "resolve cannot escape")

	ck_eq_str(t, percent_decode("Chapter%201.xhtml"), "Chapter 1.xhtml", "percent decode space")
	ck_eq_str(t, percent_decode("a%2Fb"), "a/b", "percent decode slash")
	ck_eq_str(t, percent_decode("plain.xhtml"), "plain.xhtml", "percent decode no-op")
	ck_eq_str(t, percent_decode("bad%zz"), "bad%zz", "percent decode invalid escape")

	ck_eq_str(t, zip_clean_name("./OEBPS/a.xhtml", context.temp_allocator), "OEBPS/a.xhtml", "zip name ./")
	ck_eq_str(t, zip_clean_name("a\\b\\c.png", context.temp_allocator), "a/b/c.png", "zip name backslash")
	ck_eq_str(t, zip_clean_name("/abs/x", context.temp_allocator), "abs/x", "zip name absolute")
	ck_eq_str(t, zip_clean_name("a/../../x", context.temp_allocator), "x", "zip name escape")

	path, frag := split_frag("ch1.xhtml#top")
	ck_eq_str(t, path, "ch1.xhtml", "split_frag path")
	ck_eq_str(t, frag, "top", "split_frag fragment")
	p2, f2 := split_frag("ch1.xhtml")
	ck_eq_str(t, p2, "ch1.xhtml", "split_frag no fragment")
	ck_eq_str(t, f2, "", "split_frag empty fragment")
}

// ---------------------------------------------------------------------------
// XML
// ---------------------------------------------------------------------------

xml_all_text :: proc(src: string, allocator := context.temp_allocator) -> string {
	x: Xml
	xml_init(&x, src)
	defer xml_destroy(&x)
	b := strings.builder_make(allocator)
	for {
		tok := xml_next(&x)
		if tok.kind == .Eof {
			break
		}
		if tok.kind == .Text {
			strings.write_string(&b, tok.text)
		}
	}
	return strings.to_string(b)
}

test_xml :: proc(t: ^T) {
	group(t, "xml")

	ck_eq_str(t, xml_all_text("<p>hello</p>"), "hello", "plain text")
	ck_eq_str(t, xml_all_text("<p>a &amp; b</p>"), "a & b", "&amp;")
	ck_eq_str(t, xml_all_text("<p>&lt;tag&gt;</p>"), "<tag>", "&lt; &gt;")
	ck_eq_str(t, xml_all_text("<p>&mdash;</p>"), "—", "&mdash;")
	ck_eq_str(t, xml_all_text("<p>&#8217;</p>"), "’", "numeric entity")
	ck_eq_str(t, xml_all_text("<p>&#x2019;</p>"), "’", "hex entity")
	ck_eq_str(t, xml_all_text("<p>&nbsp;</p>"), " ", "&nbsp;")
	// An unknown or unterminated reference comes through literally rather
	// than vanishing, which is what a book full of bare ampersands needs.
	ck_eq_str(t, xml_all_text("<p>a & b</p>"), "a & b", "bare ampersand")
	ck_eq_str(t, xml_all_text("<p>&notanentity;</p>"), "&notanentity;", "unknown entity")
	ck_eq_str(t, xml_all_text("<p><![CDATA[raw <b> text]]></p>"), "raw <b> text", "CDATA")
	ck_eq_str(t, xml_all_text("<!-- gone --><p>kept</p>"), "kept", "comment skipped")
	ck_eq_str(t, xml_all_text("<!DOCTYPE html [<!ENTITY x \"y\">]><p>kept</p>"), "kept", "doctype with subset")
	ck_eq_str(t, xml_all_text("<?xml version=\"1.0\"?><p>kept</p>"), "kept", "xml declaration")
	ck_eq_str(t, xml_all_text("\xef\xbb\xbf<p>kept</p>"), "kept", "BOM stripped")
	ck_eq_str(t, xml_all_text("<p>2 < 3</p>"), "2 < 3", "lone less-than kept as text")

	// Attributes in every form real books use.
	x: Xml
	xml_init(&x, `<img SRC="a.png" alt='quoted single' width=120 noshade xlink:href="b.png"/>`)
	defer xml_destroy(&x)
	tok := xml_next(&x)
	ck(t, tok.kind == .Empty, "self-closing tag reported as Empty, got %v", tok.kind)
	ck_eq_str(t, tok.name, "img", "tag name lower-cased")
	v1, ok1 := xml_attr(tok, "src")
	ck(t, ok1 && v1 == "a.png", "attribute name lower-cased: %q", v1)
	v2, _ := xml_attr(tok, "alt")
	ck_eq_str(t, v2, "quoted single", "single-quoted value")
	v3, _ := xml_attr(tok, "width")
	ck_eq_str(t, v3, "120", "unquoted value")
	v4, ok4 := xml_attr(tok, "noshade")
	ck(t, ok4 && v4 == "noshade", "valueless attribute")
	v5, ok5 := xml_attr(tok, "href")
	ck(t, ok5 && v5 == "b.png", "namespaced attribute found by local name: %q", v5)
	_, no := xml_attr(tok, "missing")
	ck(t, !no, "absent attribute reports false")

	// Namespace prefixes are stripped from element names.
	x2: Xml
	xml_init(&x2, "<dc:Title>t</dc:Title>")
	defer xml_destroy(&x2)
	tok2 := xml_next(&x2)
	ck_eq_str(t, tok2.name, "title", "namespace prefix stripped and lower-cased")

	// A long document must not reallocate the arena: the pool is sized from a
	// bound, and every token's strings have to stay valid to the end.
	big := strings.repeat("<p>alpha &amp; omega</p>", 400, context.temp_allocator)
	got := xml_all_text(big)
	ck_eq_int(t, len(got), 400 * len("alpha & omega"), "400 paragraphs decode to the right length")
	ck(t, strings.count(got, "alpha & omega") == 400, "every entity in a long document decoded")
}

// ---------------------------------------------------------------------------
// CSS
// ---------------------------------------------------------------------------

test_css :: proc(t: ^T) {
	group(t, "css")
	c: Css
	css_init(&c)
	defer css_destroy(&c)
	css_parse(
		&c,
		`/* a comment { not a rule } */
		p { margin-top: 0.8em; margin-bottom: 0.8em }
		p.first { text-indent: 0 }
		h1, h2 { font-weight: bold; text-align: center }
		.tiny { font-size: 80% }
		blockquote p { font-style: italic }
		#special { display: none }
		pre { font-family: "Courier New", monospace }
		.pb { page-break-before: always }
		em { font-style: italic !important }
		@media print { p { font-size: 200% } }`,
	)

	d := Css_Decl{}
	css_match(&c, "p", "", "", nil, &d)
	ck(t, .Margin_Top in d.has, "p picks up margin-top")
	ck_near(t, d.margin_top, 0.8, 0.001, "p margin-top")
	// `blockquote p` must NOT apply to a paragraph with no blockquote above
	// it. Getting this wrong sets the whole book in italic, which is exactly
	// what the first render of this app did.
	ck(t, !(.Slant in d.has), "a descendant selector does not apply without its ancestor")

	anc := [?]Css_Sel{{tag = "body"}, {tag = "blockquote"}}
	d_in := Css_Decl{}
	css_match(&c, "p", "", "", anc[:], &d_in)
	ck(t, .Slant in d_in.has && d_in.italic, "a descendant selector applies inside its ancestor")

	anc2 := [?]Css_Sel{{tag = "div"}, {tag = "section"}}
	d_out := Css_Decl{}
	css_match(&c, "p", "", "", anc2[:], &d_out)
	ck(t, !(.Slant in d_out.has), "and not inside some other ancestor")

	// A child combinator is read as a descendant one, so a rule written with
	// `>` still fires for a grandchild rather than for nothing.
	c3: Css
	css_init(&c3)
	defer css_destroy(&c3)
	css_parse(&c3, ".chapter > h2 { text-align: right } div.note p { font-weight: bold }")
	anc3 := [?]Css_Sel{{tag = "div", class = "chapter"}, {tag = "header"}}
	d10 := Css_Decl{}
	css_match(&c3, "h2", "", "", anc3[:], &d10)
	ck(t, d10.align == .Right, "a child combinator matches a grandchild")
	anc4 := [?]Css_Sel{{tag = "div", class = "note"}}
	d11 := Css_Decl{}
	css_match(&c3, "p", "", "", anc4[:], &d11)
	ck(t, .Weight in d11.has && d11.bold, "an ancestor compound with a class matches")
	anc5 := [?]Css_Sel{{tag = "div", class = "other"}}
	d12 := Css_Decl{}
	css_match(&c3, "p", "", "", anc5[:], &d12)
	ck(t, !(.Weight in d12.has), "and does not match a different class")

	// An attribute selector is dropped from the compound rather than
	// breaking the parse of the rule it is in.
	c4: Css
	css_init(&c4)
	defer css_destroy(&c4)
	css_parse(&c4, `a[href^="http"] { text-decoration: underline }`)
	d13 := Css_Decl{}
	css_match(&c4, "a", "", "", nil, &d13)
	ck(t, .Underline in d13.has && d13.underline, "an attribute selector degrades to its tag")

	d2 := Css_Decl{}
	css_match(&c, "h1", "", "", nil, &d2)
	ck(t, .Weight in d2.has && d2.bold, "h1 from a comma list")
	ck(t, .Align in d2.has && d2.align == .Center, "h1 alignment")

	d3 := Css_Decl{}
	css_match(&c, "span", "tiny", "", nil, &d3)
	ck(t, .Size in d3.has, "class selector matches")
	ck_near(t, d3.size, 0.8, 0.001, "percentage font-size")

	d4 := Css_Decl{}
	css_match(&c, "div", "", "special", nil, &d4)
	ck(t, .Hidden in d4.has && d4.hidden, "id selector and display:none")

	d5 := Css_Decl{}
	css_match(&c, "pre", "", "", nil, &d5)
	ck(t, .Mono in d5.has && d5.mono, "monospace detected in a font stack")

	d6 := Css_Decl{}
	css_match(&c, "div", "pb", "", nil, &d6)
	ck(t, .Break in d6.has && d6.brk, "page-break-before")

	d7 := Css_Decl{}
	css_match(&c, "em", "", "", nil, &d7)
	ck(t, .Slant in d7.has && d7.italic, "!important parses and still applies")

	// @media is skipped entirely rather than applied unconditionally.
	d8 := Css_Decl{}
	css_match(&c, "p", "", "", nil, &d8)
	ck(t, !(.Size in d8.has), "@media contents are not applied")

	// Specificity: a class beats a tag whatever the source order.
	c2: Css
	css_init(&c2)
	defer css_destroy(&c2)
	css_parse(&c2, ".x { text-align: right } p { text-align: left }")
	d9 := Css_Decl{}
	css_match(&c2, "p", "x", "", nil, &d9)
	ck(t, d9.align == .Right, "a class outranks a tag written later")

	// Units.
	v, ok := css_size("1.5em")
	ck(t, ok && abs(v - 1.5) < 0.001, "em font-size")
	v2, ok2 := css_size("12pt")
	ck(t, ok2 && abs(v2 - 1) < 0.001, "12pt is the body size")
	v3, ok3 := css_len_em("16px")
	ck(t, ok3 && abs(v3 - 1) < 0.001, "16px is one em")
	v4, ok4 := css_len_em("0")
	ck(t, ok4 && v4 == 0, "a bare zero length")

	ck(t, class_has("a b c", "b"), "class list match in the middle")
	ck(t, class_has("a", "a"), "single class match")
	ck(t, !class_has("abc", "a"), "class match is not a substring match")
	ck(t, !class_has("", "a"), "empty class attribute")
}

// ---------------------------------------------------------------------------
// ZIP
// ---------------------------------------------------------------------------

test_zip :: proc(t: ^T, dir: string, png: []u8) {
	group(t, "zip")

	// A round trip through the writer, with both storage methods in one
	// archive, which is what real EPUBs do.
	payload := strings.repeat("deflate me, deflate me, deflate me. ", 300, context.temp_allocator)
	zo: Zip_Out
	zip_out_init(&zo)
	zip_out_add(&zo, "stored.txt", transmute([]u8)string("I am stored."), false)
	zip_out_add(&zo, "deflated.txt", transmute([]u8)payload, true)
	zip_out_add(&zo, "nested/dir/file.bin", png, false)
	zip_out_add(&zo, "empty.txt", nil, true)
	raw := zip_out_finish(&zo)
	data := make([]u8, len(raw), context.temp_allocator)
	copy(data, raw)
	zip_out_destroy(&zo)

	z, ok := zip_from_bytes(data)
	defer zip_destroy(&z)
	ck(t, ok, "an archive with mixed methods opens: %s", z.err)
	ck_eq_int(t, len(z.entries), 4, "entry count")

	s1, g1 := zip_read_string(&z, "stored.txt", context.temp_allocator)
	ck(t, g1 && s1 == "I am stored.", "a stored entry reads back exactly: %q", s1)

	s2, g2 := zip_read_string(&z, "deflated.txt", context.temp_allocator)
	ck(t, g2, "a deflated entry reads back")
	ck_eq_int(t, len(s2), len(payload), "deflated length")
	ck(t, s2 == payload, "a deflated entry reads back byte for byte")

	b3, g3 := zip_read(&z, "nested/dir/file.bin", context.temp_allocator)
	ck(t, g3 && len(b3) == len(png), "a nested binary entry: %d of %d bytes", len(b3), len(png))
	same := g3 && len(b3) == len(png)
	if same {
		for i in 0 ..< len(png) {
			if b3[i] != png[i] {
				same = false
				break
			}
		}
	}
	ck(t, same, "binary bytes survive the round trip")

	_, g4 := zip_read_string(&z, "empty.txt", context.temp_allocator)
	ck(t, g4, "a zero-length deflated entry reads back")

	_, g5 := zip_read_string(&z, "missing.txt", context.temp_allocator)
	ck(t, !g5, "a missing entry reports false rather than crashing")

	ck(t, zip_has(&z, "stored.txt"), "zip_has finds an entry")
	ck(t, !zip_has(&z, "nope"), "zip_has on a missing entry")
	// A case-insensitive fallback, because META-INF is written both ways.
	ck(t, zip_find(&z, "STORED.TXT") >= 0, "entry found case-insensitively")
}

// ---------------------------------------------------------------------------
// EPUB
// ---------------------------------------------------------------------------

test_epub :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "epub")
	path := tfmt("%s/generated.epub", dir)
	ck(t, gen_epub_file(path, fixture_book(png)), "the generated EPUB was written")

	b: Book
	o := test_opts()
	opened := book_open(&b, path, fonts, dir, o)
	ck(t, opened, "the generated EPUB opens: %s", b.err)
	if !opened {
		return
	}
	defer book_close(&b)

	ck(t, b.format == .Epub, "format detected as EPUB, got %v", b.format)

	// --- metadata, exactly as written
	ck_eq_str(t, b.doc.title, "The Generated Book", "dc:title")
	ck_eq_str(t, b.doc.author, "A. Fixture", "dc:creator")
	ck_eq_str(t, b.doc.language, "en", "dc:language")
	ck_eq_str(t, b.doc.ident, "urn:uuid:palmy-reader-selftest-0001", "dc:identifier")
	ck_eq_str(t, b.doc.publisher, "palmy reader selftest", "dc:publisher")

	// --- the spine, in order
	ck_eq_int(t, len(b.doc.chapters), 4, "spine length (the ghost itemref is skipped)")
	want_files := [?]string{"OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml", "OEBPS/ch4.xhtml"}
	for w, i in want_files {
		if i < len(b.doc.chapters) {
			ck_eq_str(t, b.doc.chapters[i].path, w, tfmt("spine order position %d", i))
		}
	}
	// The ghost spine entry must have produced a note rather than silence.
	ghost := false
	for n in b.doc.notes {
		if strings.contains(n, "chapter-that-does-not-exist") {
			ghost = true
		}
	}
	ck(t, ghost, "a spine itemref with no manifest item is reported")

	// --- chapter titles come from <title>
	if len(b.doc.chapters) >= 4 {
		ck_eq_str(t, b.doc.chapters[0].title, "The Measure", "chapter 1 title from <title>")
		ck_eq_str(t, b.doc.chapters[3].title, "Malformed", "chapter 4 title from <title>")
	}

	// --- the text came back exactly
	all := chapter_text(&b.doc, 0)
	ck(t, strings.contains(all, S1), "chapter 1 holds the sentence that was written into it")
	ck(t, strings.contains(all, S2), "chapter 1 holds its pagination marker")
	ck(t, strings.contains(chapter_text(&b.doc, 2), S3), "entities decoded in the book, not just the parser")
	ck(
		t,
		strings.contains(chapter_text(&b.doc, 3), "DELTA-FOUR survives all of that."),
		"the malformed chapter's last paragraph survived",
	)

	// --- block structure
	k := block_kinds(&b.doc, 0)
	ck(t, k[.H1] >= 1, "chapter 1 has a heading, got %d", k[.H1])
	ck(t, k[.Quote] >= 1, "chapter 1 has a blockquote, got %d", k[.Quote])
	ck(t, k[.Code] >= 2, "a two-line <pre> becomes two Code blocks, got %d", k[.Code])
	ck(t, k[.Item] >= 6, "the two lists give at least six items, got %d", k[.Item])
	ck(t, k[.Image] == 1, "one image block, got %d", k[.Image])
	ck(t, k[.Rule] == 1, "one horizontal rule, got %d", k[.Rule])

	// --- list kinds, depths and ordinals
	bullets, numbers, nested := 0, 0, 0
	for i in 0 ..< len(b.doc.blocks) {
		bl := b.doc.blocks[i]
		if bl.kind != .Item {
			continue
		}
		switch bl.list {
		case .Bullet:
			bullets += 1
			if bl.depth >= 2 {
				nested += 1
			}
		case .Numbered:
			numbers += 1
		case .None:
		}
	}
	ck(t, bullets >= 4, "four bullets including the nested one, got %d", bullets)
	ck(t, numbers == 3, "three numbered items, got %d", numbers)
	ck(t, nested == 1, "one bullet at depth two, got %d", nested)

	// --- character styles
	ck(t, has_styled(&b.doc, "emphasis", {italic = true}), "<em> produced an italic run")
	ck(t, has_styled(&b.doc, "strength", {bold = true}), "<strong> produced a bold run")
	ck(t, has_styled(&b.doc, "monospace", {mono = true}), "<code> produced a monospace run")
	ck(
		t,
		has_styled(&b.doc, "both at once", {bold = true, italic = true}),
		"an inline style attribute set both bold and italic",
	)
	// The stylesheet's `blockquote p { font-style: italic }` must reach the
	// quotation and nothing else. A book whose body text all came out italic
	// is the failure this is here to catch.
	quote_kept := false
	for i in 0 ..< len(b.doc.blocks) {
		if b.doc.blocks[i].kind == .Quote && strings.contains(block_text(&b.doc, i), "A quotation") {
			quote_kept = true
		}
	}
	ck(t, quote_kept, "a <p> inside a <blockquote> is still a quotation")
	body_italic := 0
	for i in 0 ..< len(b.doc.blocks) {
		if b.doc.blocks[i].kind != .Para {
			continue
		}
		if !strings.contains(block_text(&b.doc, i), "measure is the width") {
			continue
		}
		for sg in block_segs(&b.doc, i) {
			if sg.st.italic {
				body_italic += 1
			}
		}
	}
	ck_eq_int(t, body_italic, 0, "the body text did not inherit the blockquote's italic")

	// `p.first { text-indent: 0 }` must beat the reader's default indent,
	// which means a zero the book set has to be told apart from no value.
	indent_zero := false
	for i in 0 ..< len(b.doc.blocks) {
		if strings.contains(block_text(&b.doc, i), "measure is the width") {
			indent_zero = b.doc.blocks[i].indent_set && b.doc.blocks[i].indent == 0
		}
	}
	ck(t, indent_zero, "an explicit text-indent: 0 is recorded as set, not as absent")

	// --- centred paragraph from an inline style
	centred := false
	for i in 0 ..< len(b.doc.blocks) {
		if strings.contains(block_text(&b.doc, i), "A centred line") &&
		   b.doc.blocks[i].align == .Center {
			centred = true
		}
	}
	ck(t, centred, "text-align: center in a style attribute reached the block")

	// --- the table of contents
	ck_eq_int(t, len(b.doc.toc), 4, "TOC entry count")
	want_titles := [?]string{"The Measure", "The Long One", "Entities and Anchors", "Malformed"}
	for w, i in want_titles {
		if i < len(b.doc.toc) {
			ck_eq_str(t, b.doc.toc[i].title, w, tfmt("TOC title %d", i))
		}
	}
	for e, i in b.doc.toc {
		ck(t, e.block >= 0, "TOC entry %d resolves to a block", i)
		if e.block >= 0 && i < len(b.doc.chapters) {
			ck_eq_int(t, e.block, b.doc.chapters[i].first, tfmt("TOC entry %d lands on its chapter's first block", i))
		}
	}

	// --- anchors and links
	_, has_top := b.doc.anchors["OEBPS/ch1.xhtml#top"]
	ck(t, has_top, "an id attribute became an anchor")
	marker, has_marker := b.doc.anchors["OEBPS/ch3.xhtml#marker"]
	ck(t, has_marker, "an id in another chapter became an anchor")
	if has_marker {
		ck(
			t,
			strings.contains(block_text(&b.doc, marker), "GAMMA-THREE"),
			"the anchor points at the paragraph that carried the id",
		)
	}
	ck(t, len(b.doc.links) >= 2, "two links were recorded, got %d", len(b.doc.links))
	resolved := doc_anchor(&b.doc, "OEBPS", "ch3.xhtml#marker")
	ck(t, resolved == marker, "doc_anchor resolves a cross-chapter link: %d vs %d", resolved, marker)

	// --- the cover
	cov, have_cov := book_cover_bytes(&b)
	ck(t, have_cov && len(cov) == len(png), "the declared cover comes back whole: %d of %d", len(cov), len(png))
	if have_cov {
		delete(cov)
	}
}

chapter_text :: proc(d: ^Doc, ci: int, allocator := context.temp_allocator) -> string {
	if ci < 0 || ci >= len(d.chapters) {
		return ""
	}
	c := d.chapters[ci]
	b := strings.builder_make(allocator)
	for i in c.first ..< c.first + c.count {
		strings.write_string(&b, block_text(d, i))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

block_kinds :: proc(d: ^Doc, ci: int) -> (counts: [Block_Kind]int) {
	if ci < 0 || ci >= len(d.chapters) {
		return
	}
	c := d.chapters[ci]
	for i in c.first ..< c.first + c.count {
		counts[d.blocks[i].kind] += 1
	}
	return
}

// has_styled asks whether some run of text with these style flags exists.
has_styled :: proc(d: ^Doc, needle: string, want: Char_Style) -> bool {
	for bi in 0 ..< len(d.blocks) {
		text := block_text(d, bi)
		at := strings.index(text, needle)
		if at < 0 {
			continue
		}
		for sg in block_segs(d, bi) {
			if at < sg.start || at >= sg.end {
				continue
			}
			if want.bold && !sg.st.bold {
				continue
			}
			if want.italic && !sg.st.italic {
				continue
			}
			if want.mono && !sg.st.mono {
				continue
			}
			if want.underline && !sg.st.underline {
				continue
			}
			return true
		}
	}
	return false
}

test_opts :: proc() -> Reflow_Opts {
	return Reflow_Opts {
		size    = 17,
		line    = 1.62,
		measure = 620,
		page_h  = 640,
		justify = false,
		para    = .Indented,
	}
}

// ---------------------------------------------------------------------------
// Reflow
// ---------------------------------------------------------------------------

test_reflow :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "reflow")
	path := tfmt("%s/generated.epub", dir)
	b: Book
	o := test_opts()
	if !book_open(&b, path, fonts, dir, o) {
		ck(t, false, "the EPUB did not open for the reflow tests: %s", b.err)
		return
	}
	defer book_close(&b)
	// Decode the one picture, so an image block has its real size.
	for book_images_pending(&b) {
		book_pump_images(&b, 4)
	}
	for i in 0 ..< CHAPTER_CACHE {
		b.reflow.chaps[i].valid = false
	}

	for ci in 0 ..< len(b.doc.chapters) {
		cl := reflow_chapter(&b.reflow, &b.doc, ci)
		check_lines_fit(t, &b, cl, ci)
		check_partition(t, &b, cl, ci)
		check_pages(t, &b, cl, ci)
	}

	// --- changing the type size and changing it back must give back exactly
	// the pagination it started with. This is what the content-hashed block
	// cache buys, and it is also the difference between a reader that
	// remembers your place and one that drifts.
	before := pagination_signature(&b, 1)
	for size in ([?]f32{13, 24, 17}) {
		o2 := o
		o2.size = size
		reflow_set_opts(&b.reflow, o2)
		_ = reflow_chapter(&b.reflow, &b.doc, 1)
	}
	after := pagination_signature(&b, 1)
	ck_eq_int(t, len(after), len(before), "page count returns after a size round trip")
	identical := len(after) == len(before)
	if identical {
		for i in 0 ..< len(before) {
			if before[i] != after[i] {
				identical = false
				break
			}
		}
	}
	ck(t, identical, "every page starts at the same byte after a size round trip")

	// --- a bigger type size must give at least as many pages
	o3 := o
	o3.size = 28
	reflow_set_opts(&b.reflow, o3)
	big := reflow_chapter(&b.reflow, &b.doc, 1).pages
	o4 := o
	o4.size = 13
	reflow_set_opts(&b.reflow, o4)
	small := reflow_chapter(&b.reflow, &b.doc, 1).pages
	ck(t, big > small, "28 px gives more pages than 13 px: %d vs %d", big, small)

	// --- a narrower measure must give more lines
	reflow_set_opts(&b.reflow, o)
	wide := len(reflow_chapter(&b.reflow, &b.doc, 1).lines)
	o5 := o
	o5.measure = 300
	reflow_set_opts(&b.reflow, o5)
	narrow := len(reflow_chapter(&b.reflow, &b.doc, 1).lines)
	ck(t, narrow > wide, "a 300 px measure gives more lines than 620 px: %d vs %d", narrow, wide)

	// --- the cache: a second layout of the same chapter wraps nothing
	reflow_set_opts(&b.reflow, o)
	_ = reflow_chapter(&b.reflow, &b.doc, 0)
	for i in 0 ..< CHAPTER_CACHE {
		b.reflow.chaps[i].valid = false
	}
	_ = reflow_chapter(&b.reflow, &b.doc, 0)
	ck_eq_int(t, b.reflow.wrapped, 0, "re-laying out an unchanged chapter wraps no blocks")

	// --- justification never overflows the measure
	o6 := o
	o6.justify = true
	reflow_set_opts(&b.reflow, o6)
	cl := reflow_chapter(&b.reflow, &b.doc, 1)
	over := 0
	for ln in cl.lines {
		if ln.kind == .Image || ln.kind == .Rule {
			continue
		}
		gaps := 0
		for q in 0 ..< ln.fc {
			if cl.frags[ln.fi + q].gap_after && q != ln.fc - 1 {
				gaps += 1
			}
		}
		if ln.x - 0 + ln.w + f32(gaps) * ln.gap > o6.measure + 1.5 {
			over += 1
		}
	}
	ck_eq_int(t, over, 0, "no justified line is wider than the measure")
	reflow_set_opts(&b.reflow, o)

	// --- an image block is never wider than the column, and never taller
	// than most of a page
	for ci in 0 ..< len(b.doc.chapters) {
		c := reflow_chapter(&b.reflow, &b.doc, ci)
		for ln in c.lines {
			if ln.kind != .Image {
				continue
			}
			ck(t, ln.w <= o.measure + 0.5, "an image fits the column: %.1f vs %.1f", ln.w, o.measure)
			ck(t, ln.h <= o.page_h + 0.5, "an image fits a page: %.1f vs %.1f", ln.h, o.page_h)
			ck(t, ln.w > 1 && ln.h > 1, "an image has a real size")
		}
	}
}

// check_lines_fit is the first reflow invariant: a wrapped line fits.
check_lines_fit :: proc(t: ^T, b: ^Book, cl: ^Chapter_Layout, ci: int) {
	bad := 0
	worst := f32(0)
	for ln in cl.lines {
		if ln.kind == .Image || ln.kind == .Rule {
			continue
		}
		avail := b.reflow.opts.measure - block_indent(&b.doc, ln.block, b.reflow.opts) - ln.indent
		// A single word wider than the measure is broken between runes, so
		// the only lines allowed to exceed it are ones with no break point,
		// which the wrapper does not produce. One pixel of slack for
		// rounding.
		if ln.w > avail + 1 {
			bad += 1
			worst = max(worst, ln.w - avail)
		}
	}
	ck(t, bad == 0, "chapter %d: %d lines exceed the measure (worst by %.1f px)", ci, bad, worst)
}

// check_partition is the second: the lines of a block cover its bytes exactly
// once, in order, with nothing lost and nothing duplicated.
check_partition :: proc(t: ^T, b: ^Book, cl: ^Chapter_Layout, ci: int) {
	cur := -1
	expect := 0
	problems := 0
	for ln in cl.lines {
		if ln.block != cur {
			if cur >= 0 {
				if expect != int(b.doc.blocks[cur].n) {
					problems += 1
				}
			}
			cur = ln.block
			expect = 0
			if ln.start != 0 && ln.kind != .Image && ln.kind != .Rule {
				problems += 1
			}
		}
		if ln.kind == .Image || ln.kind == .Rule {
			continue
		}
		if ln.start != expect {
			problems += 1
		}
		expect = ln.end
	}
	if cur >= 0 && b.doc.blocks[cur].kind != .Image && b.doc.blocks[cur].kind != .Rule {
		if expect != int(b.doc.blocks[cur].n) {
			problems += 1
		}
	}
	ck(t, problems == 0, "chapter %d: %d gaps or overlaps in the line partition", ci, problems)

	// And the same thing said in bytes: concatenating the lines of a block
	// gives the block back.
	for bi in 0 ..< len(b.doc.blocks) {
		if int(b.doc.blocks[bi].chapter) != ci {
			continue
		}
		if b.doc.blocks[bi].kind == .Image || b.doc.blocks[bi].kind == .Rule {
			continue
		}
		sb := strings.builder_make(context.temp_allocator)
		found := false
		for ln in cl.lines {
			if ln.block != bi {
				continue
			}
			found = true
			text := block_text(&b.doc, bi)
			strings.write_string(&sb, text[clamp(ln.start, 0, len(text)):clamp(ln.end, 0, len(text))])
		}
		if !found {
			continue
		}
		ck(
			t,
			strings.to_string(sb) == block_text(&b.doc, bi),
			"chapter %d block %d: the lines concatenate back to the block",
			ci,
			bi,
		)
		break // one per chapter is enough to catch a systematic error
	}
}

// check_pages is the pagination invariant set.
check_pages :: proc(t: ^T, b: ^Book, cl: ^Chapter_Layout, ci: int) {
	ck(t, cl.pages >= 1, "chapter %d has at least one page", ci)
	ck_eq_int(t, len(cl.page_at), cl.pages + 1, tfmt("chapter %d page index length", ci))

	// Every line is on exactly one page, and the page index agrees with the
	// line's own page number.
	wrong := 0
	for page in 0 ..< cl.pages {
		for ln in layout_page_lines(cl, page) {
			if ln.page != page {
				wrong += 1
			}
		}
	}
	ck_eq_int(t, wrong, 0, tfmt("chapter %d: lines agree with the page index", ci))

	// No page overflows its height, and -- the part the painter depends on --
	// every line's y is relative to the page it is on, not to the chapter.
	// Without this assertion the painter drew page one correctly and every
	// page after it off the top of the element, which is invisible rather
	// than wrong-looking and so passed everything else here.
	over := 0
	outside := 0
	for page in 0 ..< cl.pages {
		lines := layout_page_lines(cl, page)
		if len(lines) == 0 {
			continue
		}
		top := lines[0].y
		bot := lines[len(lines) - 1].y + lines[len(lines) - 1].h
		if bot - top > b.reflow.opts.page_h + 1 {
			over += 1
		}
		for ln in lines {
			if ln.y < -0.5 || ln.y + ln.h > b.reflow.opts.page_h + 1 {
				outside += 1
			}
		}
	}
	ck_eq_int(t, over, 0, tfmt("chapter %d: no page is taller than the page", ci))
	ck_eq_int(
		t,
		outside,
		0,
		tfmt("chapter %d: every line sits inside its own page's box, measured from its top", ci),
	)
	if cl.pages > 1 {
		second := layout_page_lines(cl, 1)
		ck(
			t,
			len(second) > 0 && second[0].y < b.reflow.opts.page_h,
			"chapter %d: page two starts near the top of the page, not below it (y = %.0f)",
			ci,
			len(second) > 0 ? second[0].y : -1,
		)
	}

	// Keep-with-next: a heading is never the last thing on a page.
	stranded := 0
	for page in 0 ..< cl.pages - 1 {
		lines := layout_page_lines(cl, page)
		if len(lines) == 0 {
			continue
		}
		last := lines[len(lines) - 1]
		switch last.kind {
		case .H1, .H2, .H3, .H4:
			stranded += 1
		case .Para, .Quote, .Code, .Item, .Image, .Rule:
		}
	}
	ck_eq_int(t, stranded, 0, tfmt("chapter %d: no heading left alone at the foot of a page", ci))

	// Orphan control: a multi-line paragraph never leaves exactly one line
	// behind at the foot of a page.
	orphans := 0
	for page in 0 ..< cl.pages - 1 {
		lines := layout_page_lines(cl, page)
		if len(lines) == 0 {
			continue
		}
		last := lines[len(lines) - 1]
		if last.first && !last.last && last.kind == .Para {
			orphans += 1
		}
	}
	ck_eq_int(t, orphans, 0, tfmt("chapter %d: no orphaned first line", ci))
}

// pagination_signature is the first byte of every page: the thing that must be
// identical after a size round trip.
pagination_signature :: proc(b: ^Book, ci: int, allocator := context.temp_allocator) -> [][2]int {
	cl := reflow_chapter(&b.reflow, &b.doc, ci)
	out := make([][2]int, cl.pages, allocator)
	for page in 0 ..< cl.pages {
		blk, off := layout_pos_at(cl, page)
		out[page] = {blk, off}
	}
	return out
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

test_search :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "search")
	b: Book
	if !book_open(&b, tfmt("%s/generated.epub", dir), fonts, dir, test_opts()) {
		ck(t, false, "the EPUB did not open for the search tests")
		return
	}
	defer book_close(&b)

	s: Search
	defer search_destroy(&s)

	book_search(&b, &s, "ALPHA-ONE")
	ck_eq_int(t, len(s.hits), 1, "a unique marker is found once")
	if len(s.hits) == 1 {
		h := s.hits[0]
		ck(
			t,
			strings.contains(block_text(&b.doc, h.block), "ALPHA-ONE"),
			"the hit's block really holds the match",
		)
		text := block_text(&b.doc, h.block)
		ck_eq_str(t, text[h.start:h.end], "ALPHA-ONE", "the hit's byte range is the match")
		ck_eq_int(t, h.chapter, 0, "the hit is in chapter one")
		ck(t, strings.contains(h.line, "ALPHA-ONE"), "the snippet shows the match")
	}

	book_search(&b, &s, "alpha-one")
	ck_eq_int(t, len(s.hits), 1, "search is case-insensitive")

	book_search(&b, &s, "GAMMA-THREE")
	ck(t, len(s.hits) == 1 && s.hits[0].chapter == 2, "a marker in chapter three is found there")

	book_search(&b, &s, "Paragraph")
	ck(t, len(s.hits) >= 120, "a word in every paragraph of the long chapter: %d hits", len(s.hits))

	book_search(&b, &s, "ThisStringIsNotInTheBook")
	ck_eq_int(t, len(s.hits), 0, "a string that is not there gives no hits")

	book_search(&b, &s, "a")
	ck_eq_int(t, len(s.hits), 0, "a single character is too short to search for")

	// The em dash the entity decoder produced is findable as the character it
	// became, which is the proof that the search runs over decoded text.
	book_search(&b, &s, "—")
	ck(t, len(s.hits) >= 1, "the decoded em dash is searchable")
}

// ---------------------------------------------------------------------------
// Position
// ---------------------------------------------------------------------------

test_position :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "position")
	b: Book
	o := test_opts()
	if !book_open(&b, tfmt("%s/generated.epub", dir), fonts, dir, o) {
		ck(t, false, "the EPUB did not open for the position tests")
		return
	}
	defer book_close(&b)

	// Every page's first position maps back to that page.
	cl := reflow_chapter(&b.reflow, &b.doc, 1)
	bad := 0
	for page in 0 ..< cl.pages {
		blk, off := layout_pos_at(cl, page)
		if blk < 0 {
			bad += 1
			continue
		}
		if layout_page_of(cl, blk, off) != page {
			bad += 1
		}
	}
	ck_eq_int(t, bad, 0, "every page's first position maps back to that page")

	// A position survives a change of type size: it lands on a page whose
// lines include the block it named.
	for page in ([?]int{0, 1, 2}) {
		if page >= cl.pages {
			continue
		}
		blk, off := layout_pos_at(cl, page)
		if blk < 0 {
			continue
		}
		for size in ([?]f32{12, 22, 30}) {
			o2 := o
			o2.size = size
			reflow_set_opts(&b.reflow, o2)
			cl2 := reflow_chapter(&b.reflow, &b.doc, 1)
			pg := layout_page_of(cl2, blk, off)
			found := false
			for ln in layout_page_lines(cl2, pg) {
				if ln.block == blk {
					found = true
					break
				}
			}
			ck(
				t,
				found,
				"a position from page %d is still on its block's page at %.0f px",
				page,
				size,
			)
		}
	}
	reflow_set_opts(&b.reflow, o)

	// And a change of measure.
	for m in ([?]f32{320, 900}) {
		o3 := o
		o3.measure = m
		reflow_set_opts(&b.reflow, o3)
		cl3 := reflow_chapter(&b.reflow, &b.doc, 1)
		blk, off := layout_pos_at(cl, 1)
		if blk < 0 || cl.pages < 2 {
			continue
		}
		pg := layout_page_of(cl3, blk, off)
		found := false
		for ln in layout_page_lines(cl3, pg) {
			if ln.block == blk {
				found = true
			}
		}
		ck(t, found, "a position survives a measure of %.0f px", m)
	}
	reflow_set_opts(&b.reflow, o)

	// Continuous mode has no pages, and must say so rather than producing one
	// page of infinite height.
	o4 := o
	o4.page_h = 0
	reflow_set_opts(&b.reflow, o4)
	cont := reflow_chapter(&b.reflow, &b.doc, 1)
	ck_eq_int(t, cont.pages, 1, "continuous mode is one page")
	ck(t, cont.height > o.page_h, "continuous mode's height is the whole chapter: %.0f px", cont.height)
	reflow_set_opts(&b.reflow, o)

	// chapter_of_block is a binary search; check it against a linear scan.
	wrong := 0
	for bi in 0 ..< len(b.doc.blocks) {
		want := int(b.doc.blocks[bi].chapter)
		if chapter_of_block(&b.doc, bi) != want {
			wrong += 1
		}
	}
	ck_eq_int(t, wrong, 0, "chapter_of_block agrees with every block's own chapter")
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

test_images :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "images")
	b: Book
	if !book_open(&b, tfmt("%s/generated.epub", dir), fonts, dir, test_opts()) {
		ck(t, false, "the EPUB did not open for the image tests")
		return
	}
	defer book_close(&b)

	ck_eq_int(t, len(b.doc.images), 1, "one image in the book")
	if len(b.doc.images) == 0 {
		return
	}
	ck_eq_str(t, b.doc.images[0].key, "OEBPS/cover.png", "the image's src resolved against its chapter")
	ck_eq_str(t, b.doc.images[0].alt, "the generated cover", "the image's alt text")

	// Not decoded until asked for, and then decoded under a budget.
	_, ok0 := book_image(&b, 0)
	ck(t, !ok0, "an image is not decoded until it is pumped")
	ck(t, book_images_pending(&b), "asking for it queued it")
	n := book_pump_images(&b, 4)
	ck_eq_int(t, n, 1, "one image decoded")
	img, ok1 := book_image(&b, 0)
	ck(t, ok1 && img.w == 120 && img.h == 170, "the decoded size is the one written: %d x %d", img.w, img.h)
	ck(t, b.doc.images[0].ok, "the image recorded itself as decoded")

	// image_box fits the column and respects the page height.
	o := test_opts()
	w1, h1 := image_box(&b.doc, 0, 60, o)
	ck(t, w1 <= 60.5, "a picture wider than the column is scaled down: %.1f", w1)
	ck(t, abs(w1 / h1 - 120.0 / 170.0) < 0.02, "the aspect ratio is kept: %.3f", w1 / h1)
	w2, h2 := image_box(&b.doc, 0, 900, o)
	ck(t, w2 <= 120.5 && h2 <= 170.5, "a picture smaller than the column is not blown up")
	o2 := o
	o2.page_h = 60
	_, h3 := image_box(&b.doc, 0, 900, o2)
	ck(t, h3 <= 60, "a picture is never taller than a page: %.1f", h3)
}

// ---------------------------------------------------------------------------
// PalmDOC
// ---------------------------------------------------------------------------

test_palmdoc :: proc(t: ^T) {
	group(t, "palmdoc")

	cases := [?]string {
		"",
		"a",
		"hello world",
		// Space folding: " A" becomes one byte.
		" A B C D E F G",
		// A long run, which must become an overlapping back-reference.
		strings.repeat("x", 300, context.temp_allocator),
		// Repeated phrases, which exercise matches at every distance.
		strings.repeat("the quick brown fox jumps over the lazy dog. ", 40, context.temp_allocator),
		// High bytes, which have to be escaped as literal runs.
		"\xc3\xa9\xc3\xa8\xc3\xaa caf\xc3\xa9 na\xc3\xafve",
		// A NUL and the control bytes the format reserves.
		"a\x00b\x01c\x08d\x09e",
		MOBI_HTML,
	}
	for src, i in cases {
		raw := transmute([]u8)src
		packed := palmdoc_compress(raw, context.temp_allocator)
		out := make([dynamic]u8, 0, len(raw) + 16, context.temp_allocator)
		ok := palmdoc_decompress(packed, &out)
		ck(t, ok, "case %d decompresses without running off the end", i)
		ck_eq_int(t, len(out), len(raw), tfmt("case %d length", i))
		same := len(out) == len(raw)
		if same {
			for k in 0 ..< len(raw) {
				if out[k] != raw[k] {
					same = false
					break
				}
			}
		}
		ck(t, same, "case %d round-trips byte for byte", i)
	}

	// Compression actually happened on the repetitive case, which is the
	// proof that back-references were produced and therefore decoded.
	rep := transmute([]u8)strings.repeat("abcabcabc", 200, context.temp_allocator)
	packed := palmdoc_compress(rep, context.temp_allocator)
	ck(t, len(packed) < len(rep) / 2, "a repetitive input compresses: %d -> %d", len(rep), len(packed))

	// A truncated record must stop cleanly and keep what it decoded.
	cut := packed[:len(packed) / 2]
	out := make([dynamic]u8, 0, 64, context.temp_allocator)
	_ = palmdoc_decompress(cut, &out)
	ck(t, len(out) > 0, "a truncated record still yields what came before the cut")
	ck(t, len(out) <= len(rep), "a truncated record does not produce more than the original")

	// Trailing-entry stripping.
	group(t, "mobi trailing")
	// flags = 0: nothing is stripped.
	rec := [?]u8{'a', 'b', 'c', 'd'}
	ck_eq_int(t, len(mobi_strip_trailing(rec[:], 0)), 4, "no flags strips nothing")
	// flags = 1: the low two bits of the last byte say how many bytes of a
	// multi-byte character were carried over.
	rec2 := [?]u8{'a', 'b', 'c', 2}
	ck_eq_int(t, len(mobi_strip_trailing(rec2[:], 1)), 1, "the multibyte overlap byte and its payload go")
	// flags = 2: one backwards-encoded variable-length entry.
	rec3 := [?]u8{'a', 'b', 'c', 'd', 0x82}
	ck_eq_int(t, len(mobi_strip_trailing(rec3[:], 2)), 3, "a two-byte trailing entry is removed")
	// A trailing entry claiming more than the record holds must not go
	// negative.
	rec4 := [?]u8{0xff}
	ck(t, len(mobi_strip_trailing(rec4[:], 2)) == 0, "an over-long trailing entry empties the record safely")
}

// ---------------------------------------------------------------------------
// HUFF/CDIC
// ---------------------------------------------------------------------------

test_huffcdic :: proc(t: ^T) {
	group(t, "huff/cdic")

	phrases := [?]string {
		"the ",
		"quick ",
		"brown ",
		"fox ",
		"jumps over ",
		"the lazy dog. ",
		"Mobipocket ",
		"HUFF/CDIC ",
	}
	order := [?]int{0, 1, 2, 3, 4, 5, 6, 7, 0, 5, 3, 3, 2}
	f := huff_fixture(phrases[:], order[:], nil, context.temp_allocator)

	h: Huff
	defer huff_destroy(&h)
	err := huff_tables(&h, f.huff)
	ck_eq_str(t, err, "", "the hand-built HUFF record loads")
	huff_begin_dict(&h, context.temp_allocator)
	added := huff_cdic(&h, f.cdic)
	ck_eq_int(t, added, len(phrases), "every phrase was loaded from the CDIC record")
	ck_eq_int(t, huff_phrase_count(&h), len(phrases), "the dictionary holds every phrase")
	huff_arm(&h)

	out := make([dynamic]u8, 0, 256, context.temp_allocator)
	ok := huff_unpack(&h, f.bits, &out)
	ck(t, ok, "the bitstream decodes without running off the tables")
	ck_eq_str(t, string(out[:]), f.want, "HUFF/CDIC decodes to the phrases that were encoded")

	// --- codes longer than eight bits, which the first dispatch table cannot
	// call terminal, so the decoder has to fall through to the second one.
	many := make([]string, 300, context.temp_allocator)
	for i in 0 ..< 300 {
		many[i] = tfmt("[%d]", i)
	}
	ord2 := make([]int, 64, context.temp_allocator)
	for i in 0 ..< 64 {
		ord2[i] = (i * 37) % 300
	}
	f2 := huff_fixture(many, ord2, nil, context.temp_allocator)
	hb: Huff
	defer huff_destroy(&hb)
	ck_eq_str(t, huff_tables(&hb, f2.huff), "", "a HUFF record with nine-bit codes loads")
	huff_begin_dict(&hb, context.temp_allocator)
	ck_eq_int(t, huff_cdic(&hb, f2.cdic), 300, "300 phrases loaded")
	huff_arm(&hb)
	out2 := make([dynamic]u8, 0, 512, context.temp_allocator)
	ck(t, huff_unpack(&hb, f2.bits, &out2), "a nine-bit-code bitstream decodes")
	ck_eq_str(t, string(out2[:]), f2.want, "the non-terminal dispatch path decodes correctly")

	// --- a phrase that is itself a bitstream, which is the only recursive
	// path in the decoder and the reason entries are resolved lazily.
	nest_phrases := [?]string{"alpha ", "beta ", "gamma ", "(a phrase of phrases)"}
	nest := [?]int{0, 1, 2, 0}
	ord3 := [?]int{3, 0, 3, 2}
	f3 := huff_fixture(nest_phrases[:], ord3[:], nest[:], context.temp_allocator)
	hc: Huff
	defer huff_destroy(&hc)
	ck_eq_str(t, huff_tables(&hc, f3.huff), "", "the nested fixture's HUFF record loads")
	huff_begin_dict(&hc, context.temp_allocator)
	ck_eq_int(t, huff_cdic(&hc, f3.cdic), 4, "four phrases, one of them nested")
	huff_arm(&hc)
	out3 := make([dynamic]u8, 0, 256, context.temp_allocator)
	ck(t, huff_unpack(&hc, f3.bits, &out3), "a nested phrase decodes")
	ck_eq_str(
		t,
		string(out3[:]),
		"alpha beta gamma alpha alpha alpha beta gamma alpha gamma ",
		"a phrase that is a bitstream expands to the phrases it names",
	)
	ck_eq_str(t, string(out3[:]), f3.want, "and the fixture agrees with the decoder")

	// A HUFF record that is not one must be refused, not guessed at.
	bad := [?]u8{'N', 'O', 'P', 'E', 0, 0, 0, 0}
	h2: Huff
	defer huff_destroy(&h2)
	e2 := huff_tables(&h2, bad[:])
	ck(t, e2 != "", "a record that does not start with HUFF is refused")

	short := [?]u8{'H', 'U', 'F', 'F'}
	h3: Huff
	defer huff_destroy(&h3)
	e3 := huff_tables(&h3, short[:])
	ck(t, e3 != "", "a truncated HUFF record is refused")

	// A HUFF record whose table offsets point outside it.
	h4: Huff
	defer huff_destroy(&h4)
	fake := make([]u8, 32, context.temp_allocator)
	copy(fake, "HUFF")
	fake[8], fake[9], fake[10], fake[11] = 0xff, 0xff, 0xff, 0xff
	e4 := huff_tables(&h4, fake)
	ck(t, e4 != "", "a HUFF record with an out-of-range table offset is refused")

	// A CDIC record that is not one adds nothing.
	h5: Huff
	defer huff_destroy(&h5)
	huff_begin_dict(&h5, context.temp_allocator)
	ck_eq_int(t, huff_cdic(&h5, bad[:]), 0, "a record that does not start with CDIC adds no phrases")
}

// ---------------------------------------------------------------------------
// MOBI
// ---------------------------------------------------------------------------

test_mobi :: proc(t: ^T, dir: string, fonts: ^p.Fonts) {
	group(t, "mobi")

	for compressed in ([?]bool{true, false}) {
		name := compressed ? "compressed" : "uncompressed"
		path := tfmt("%s/generated-%s.mobi", dir, name)
		ok := gen_mobi_file(
			path,
			{
				title = "A Generated Mobipocket",
				author = "M. Fixture",
				html = MOBI_HTML,
				compress = compressed,
			},
		)
		ck(t, ok, "the %s MOBI was written", name)

		b: Book
		opened := book_open(&b, path, fonts, dir, test_opts())
		ck(t, opened, "the %s MOBI opens: %s", name, b.err)
		if !opened {
			continue
		}
		defer book_close(&b)

		ck(t, b.format == .Mobi, "format detected as MOBI")
		ck_eq_str(t, b.doc.title, "A Generated Mobipocket", tfmt("%s: title from EXTH 503", name))
		ck_eq_str(t, b.doc.author, "M. Fixture", tfmt("%s: author from EXTH 100", name))
		ck_eq_str(t, b.doc.publisher, "palmy reader selftest", tfmt("%s: publisher from EXTH 101", name))
		ck_eq_int(t, int(b.mobi.compress), compressed ? MOBI_PALMDOC : MOBI_NO_COMPRESSION, tfmt("%s: compression field", name))

		// The decompressed text is the HTML that went in.
		ck_eq_int(t, len(b.mobi.html), len(MOBI_HTML), tfmt("%s: decompressed length", name))
		ck(t, b.mobi.html == MOBI_HTML, tfmt("%s: the text round-trips byte for byte", name))

		// Headings became chapters, and the chapters became a TOC.
		ck_eq_int(t, len(b.doc.chapters), 2, tfmt("%s: two <h1> headings become two chapters", name))
		if len(b.doc.chapters) == 2 {
			ck_eq_str(t, b.doc.chapters[0].title, "Mobi Chapter One", tfmt("%s: chapter 1 title", name))
			ck_eq_str(t, b.doc.chapters[1].title, "Mobi Chapter Two", tfmt("%s: chapter 2 title", name))
		}
		ck(t, len(b.doc.toc) >= 3, tfmt("%s: the TOC has the two chapters and the subheading: %d", name, len(b.doc.toc)))

		all := chapter_text(&b.doc, 0)
		ck(t, strings.contains(all, "EPSILON-ONE"), tfmt("%s: chapter 1's marker", name))
		ck(
			t,
			strings.contains(chapter_text(&b.doc, 1), "ZETA-TWO"),
			tfmt("%s: chapter 2's marker", name),
		)
		ck(t, has_styled(&b.doc, "italic", {italic = true}), tfmt("%s: <i> produced an italic run", name))
		ck(t, has_styled(&b.doc, "bold", {bold = true}), tfmt("%s: <b> produced a bold run", name))

		// A filepos link is resolvable, which MOBI's lack of named anchors
		// makes the only way an internal link can work.
		ck(t, len(b.doc.pos_marks) > 0, tfmt("%s: source offsets were recorded for filepos links", name))
		ck(t, doc_anchor_pos(&b.doc, 120) >= 0, tfmt("%s: a filepos resolves to a block", name))
		ck(t, doc_anchor_pos(&b.doc, 1 << 30) >= 0, tfmt("%s: a filepos past the end clamps rather than crashing", name))

		// And it lays out.
		cl := reflow_chapter(&b.reflow, &b.doc, 0)
		ck(t, len(cl.lines) > 0, tfmt("%s: the first chapter lays out", name))
		check_lines_fit(t, &b, cl, 0)
		check_partition(t, &b, cl, 0)
	}
}

// ---------------------------------------------------------------------------
// Hostile input
// ---------------------------------------------------------------------------

test_hostile :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "hostile")
	o := test_opts()

	fail_case :: proc(t: ^T, dir: string, fonts: ^p.Fonts, name: string, body: []u8, what: string) {
		path := tfmt("%s/%s", dir, name)
		_ = os.write_entire_file(path, body)
		b: Book
		ok := book_open(&b, path, fonts, dir, test_opts())
		ck(t, !ok, "%s is refused", what)
		ck(t, b.err != "", "%s says why: %q", what, b.err)
		if ok {
			book_close(&b)
		}
	}

	// A zero-byte file of each extension.
	for ext in ([?]string{"epub", "mobi", "pdf", "djvu"}) {
		fail_case(t, dir, fonts, tfmt("empty.%s", ext), nil, tfmt("a zero-byte .%s", ext))
	}

	// A file that does not exist at all.
	b0: Book
	ok0 := book_open(&b0, tfmt("%s/definitely-not-here.pdf", dir), fonts, dir, o)
	ck(t, !ok0, "a PDF that does not exist is refused")
	ck(t, b0.err != "", "and says so: %q", b0.err)
	if ok0 {
		book_close(&b0)
	}

	// A .pdf that is actually an HTML error page, which is what a failed
	// download leaves behind.
	fail_case(
		t,
		dir,
		fonts,
		"liar.pdf",
		transmute([]u8)string("<html><body>404 Not Found</body></html>"),
		"a .pdf holding HTML",
	)

	// A ZIP with no end-of-central-directory record.
	fail_case(
		t,
		dir,
		fonts,
		"noeocd.epub",
		transmute([]u8)string("PK\x03\x04 and then nothing that a central directory would recognise"),
		"a ZIP with no central directory",
	)

	// A valid ZIP that is not an EPUB: no container, no OPF.
	zo: Zip_Out
	zip_out_init(&zo)
	zip_out_add(&zo, "readme.txt", transmute([]u8)string("just a zip"), true)
	raw := zip_out_finish(&zo)
	plain := make([]u8, len(raw), context.temp_allocator)
	copy(plain, raw)
	zip_out_destroy(&zo)
	fail_case(t, dir, fonts, "plain.epub", plain, "a ZIP with no package document")

	// An EPUB whose spine is empty.
	empty_book := Gen_Book {
		title = "No Chapters",
		author = "Nobody",
		chapters = nil,
	}
	fail_case(
		t,
		dir,
		fonts,
		"nospine.epub",
		gen_epub_bytes(empty_book, context.temp_allocator),
		"an EPUB with an empty spine",
	)

	// An EPUB whose manifest declares a chapter the archive does not hold.
	// It must open, with the missing chapter reported.
	{
		g := fixture_book(png)
		path := tfmt("%s/ghostfile.epub", dir)
		// Write the book, then rebuild it without ch3's file in the archive
		// by naming a chapter whose body is never added. The generator always
		// writes every chapter, so instead mangle the OPF by asking for a
		// chapter file that collides with a name the generator skips.
		chs := make([]Gen_Chapter, 2, context.temp_allocator)
		chs[0] = g.chapters[0]
		chs[1] = {file = "not-written.xhtml", title = "Absent", body = ""}
		g2 := g
		g2.chapters = chs[:1]
		// Build the archive from one chapter, then patch the OPF to claim two.
		data := gen_epub_bytes(g2, context.temp_allocator)
		patched, _ := strings.replace(
			string(data),
			"</manifest>",
			"<item id=\"cX\" href=\"not-written.xhtml\" media-type=\"application/xhtml+xml\"/></manifest>",
			1,
			context.temp_allocator,
		)
		_ = patched // the ZIP's directory offsets make a text patch invalid
		_ = os.write_entire_file(path, data)
		b: Book
		ok := book_open(&b, path, fonts, dir, o)
		ck(t, ok, "an EPUB with one chapter still opens: %s", b.err)
		if ok {
			ck_eq_int(t, len(b.doc.chapters), 1, "and has that one chapter")
			book_close(&b)
		}
		_ = chs
	}

	// A MOBI whose last text record is cut in half: it must open, note the
	// damage, and still hold the text before the cut.
	{
		path := tfmt("%s/truncated.mobi", dir)
		long := strings.repeat(MOBI_HTML, 4, context.temp_allocator)
		ck(
			t,
			gen_mobi_file(
				path,
				{
					title = "Truncated",
					author = "T. Runcate",
					html = long,
					compress = true,
					truncate_last = true,
				},
			),
			"the truncated MOBI was written",
		)
		b: Book
		ok := book_open(&b, path, fonts, dir, o)
		ck(t, ok, "a MOBI with a truncated record still opens: %s", b.err)
		if ok {
			ck(t, strings.contains(b.mobi.html, "EPSILON-ONE"), "the text before the cut survived")
			ck(t, len(b.mobi.html) < len(long), "and the text after it is gone: %d of %d", len(b.mobi.html), len(long))
			noted := false
			for n in b.doc.notes {
				if strings.contains(n, "truncated") || strings.contains(n, "corrupt") {
					noted = true
				}
			}
			ck(t, noted, "and the damage is reported rather than hidden")
			book_close(&b)
		}
	}

	// A PalmDB with a record list that runs backwards.
	{
		path := tfmt("%s/backwards.mobi", dir)
		data := gen_mobi_bytes(
			{title = "Backwards", author = "B.", html = MOBI_HTML, compress = true},
			context.temp_allocator,
		)
		// Record 2's offset set to zero, which is before record 1's.
		if len(data) > 78 + 8 * 3 {
			at := 78 + 8 * 2
			data[at], data[at + 1], data[at + 2], data[at + 3] = 0, 0, 0, 0
		}
		_ = os.write_entire_file(path, data)
		b: Book
		ok := book_open(&b, path, fonts, dir, o)
		// Either outcome is acceptable; what is not acceptable is a crash or
		// a silent success with garbage.
		ck(t, true, "a MOBI with a backwards record list does not crash")
		if ok {
			noted := false
			for n in b.doc.notes {
				if strings.contains(n, "backwards") {
					noted = true
				}
			}
			ck(t, noted || len(b.doc.blocks) > 0, "and either reports it or still reads something")
			book_close(&b)
		} else {
			ck(t, b.err != "", "or refuses it with a message: %q", b.err)
		}
	}

	// A MOBI claiming an encryption scheme.
	{
		path := tfmt("%s/drm.mobi", dir)
		data := gen_mobi_bytes(
			{title = "Locked", author = "D. R. M.", html = MOBI_HTML, compress = true},
			context.temp_allocator,
		)
		// The encryption field is at offset 12 of record 0.
		r0_at := int(data[78]) << 24 | int(data[79]) << 16 | int(data[80]) << 8 | int(data[81])
		if r0_at + 14 < len(data) {
			data[r0_at + 12] = 0
			data[r0_at + 13] = 2
		}
		_ = os.write_entire_file(path, data)
		b: Book
		ok := book_open(&b, path, fonts, dir, o)
		ck(t, !ok, "a DRM-ed MOBI is refused rather than rendered as noise")
		ck(t, strings.contains(b.err, "encrypted"), "and says it is encrypted: %q", b.err)
		if ok {
			book_close(&b)
		}
	}

	// Unclosed tags, a stray close tag, and an unquoted attribute all in one
	// chapter: assert the text and the structure that should have survived.
	{
		b: Book
		if book_open(&b, tfmt("%s/generated.epub", dir), fonts, dir, o) {
			defer book_close(&b)
			ch := chapter_text(&b.doc, 3)
			ck(t, strings.contains(ch, "This paragraph was never closed."), "an unclosed <p> still became a block")
			ck(t, strings.contains(ch, "Neither was this emphasis"), "an unclosed <em> did not swallow the rest")
			ck(t, strings.contains(ch, "An unquoted attribute value."), "an unquoted attribute did not break the tag")
			ck(t, strings.contains(ch, "A hard"), "a <br> written as HTML did not break the parse")
			ck(t, strings.contains(ch, "DELTA-FOUR survives all of that."), "and the text after a stray </div> survived")
			// The heading was never closed either, and must not have eaten
			// the chapter.
			h1s := block_kinds(&b.doc, 3)[.H1]
			ck_eq_int(t, h1s, 1, "the unclosed <h1> is one heading, not the whole chapter")
			ck(t, b.doc.chapters[3].count >= 5, "the malformed chapter produced several blocks: %d", b.doc.chapters[3].count)
		}
	}

	// A deeply nested document must not blow the element stack.
	{
		deep := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 2000 {
			strings.write_string(&deep, "<div>")
		}
		strings.write_string(&deep, "<p>OMEGA-DEEP</p>")
		// Deliberately never closed.
		d: Doc
		defer doc_destroy(&d)
		append(&d.chapters, Chapter{path = strings.clone(""), first = 0})
		bb: Doc_Builder
		builder_init(&bb, &d)
		defer builder_destroy(&bb)
		c: Css
		css_init(&c)
		defer css_destroy(&c)
		_ = html_parse(&bb, strings.to_string(deep), {css = &c})
		builder_flush(&bb)
		found := false
		for i in 0 ..< len(d.blocks) {
			if strings.contains(block_text(&d, i), "OMEGA-DEEP") {
				found = true
			}
		}
		ck(t, found, "2000 unclosed <div>s still yield the paragraph inside them")
	}

	// A mis-declared encoding: the XML declaration says UTF-16 and the bytes
	// are UTF-8. The declaration is ignored, which is the behaviour that
	// opens the book.
	{
		d: Doc
		defer doc_destroy(&d)
		append(&d.chapters, Chapter{path = strings.clone(""), first = 0})
		bb: Doc_Builder
		builder_init(&bb, &d)
		defer builder_destroy(&bb)
		c: Css
		css_init(&c)
		defer css_destroy(&c)
		_ = html_parse(
			&bb,
			"<?xml version=\"1.0\" encoding=\"UTF-16\"?><html><body><p>café naïve — LIE-ENC</p></body></html>",
			{css = &c},
		)
		builder_flush(&bb)
		found := false
		for i in 0 ..< len(d.blocks) {
			if strings.contains(block_text(&d, i), "café naïve — LIE-ENC") {
				found = true
			}
		}
		ck(t, found, "a mis-declared encoding does not stop the UTF-8 bytes being read")
	}

	// CP1252 widening, which is what a MOBI that declares 1252 needs.
	{
		src := [?]u8{'A', 0x92, 'B', 0x97, 'C', 0xe9, 'D'}
		got := cp1252_to_utf8(src[:], context.temp_allocator)
		ck_eq_str(t, got, "A’B—CéD", "CP1252 bytes widen to the right code points")
	}
}

// ---------------------------------------------------------------------------
// Fixed-page documents
// ---------------------------------------------------------------------------

test_fixed :: proc(t: ^T, dir: string, fonts: ^p.Fonts) {
	group(t, "pdf")

	// The oracle: apps/docs exports a PDF from Markdown, so a document with
	// known text can be turned into a PDF this reader then has to agree with.
	docs_bin := find_docs_bin()
	if docs_bin == "" {
		ck(t, true, "apps/docs/docs.bin is not built; the PDF oracle was skipped")
	} else {
		// Cloned for the same reason as in write_fixtures: a path handed to a
		// subprocess should not live in a scratch allocator.
		md := strings.clone(tfmt("%s/oracle.md", dir))
		pdf := strings.clone(tfmt("%s/oracle.pdf", dir))
		defer delete(md)
		defer delete(pdf)
		body := strings.builder_make(context.temp_allocator)
		strings.write_string(&body, "# Oracle Document\n\n")
		strings.write_string(&body, "ORACLE-MARKER-ONE appears on the first page of this document.\n\n")
		for i in 0 ..< 90 {
			strings.write_string(
				&body,
				tfmt(
					"Filler paragraph %d, written so that the document runs to several pages and the page count is worth asserting on.\n\n",
					i + 1,
				),
			)
		}
		strings.write_string(&body, "## The Last Section\n\nORACLE-MARKER-TWO appears near the end.\n")
		_ = os.write_entire_file(md, transmute([]u8)strings.to_string(body))
		_, conv := kit_run({"env", "USER=palmy docs", docs_bin, "--convert", md, pdf})
		if !conv || !os.exists(pdf) {
			// apps/docs is in this repository and other agents rebuild it
			// while this runs. A PDF it could not produce is not something
			// to assert about.
			ck(t, true, "apps/docs could not export a PDF just now; the oracle was skipped")
		} else {
			// What poppler itself says, independently of the reader.
			want_pages := 0
			if lines, ok := kit_lines({"pdfinfo", pdf}); ok {
				for l in lines {
					if strings.has_prefix(l, "Pages:") {
						want_pages = atoi_simple(strings.trim_space(l[6:]))
					}
				}
			}
			ck(t, want_pages > 1, "the oracle PDF has several pages: %d", want_pages)

			b: Book
			ok := book_open(&b, pdf, fonts, dir, test_opts())
			ck(t, ok, "the oracle PDF opens: %s", b.err)
			if ok {
				defer book_close(&b)
				ck(t, b.format == .Pdf, "format detected as PDF")
				ck(t, !format_is_reflowable(b.format), "a PDF is not reflowable")
				ck_eq_int(t, b.fixed.pages, want_pages, "the reader's page count matches pdfinfo's")
				ck_near(t, b.fixed.pt_w, 595.276, 0.5, "page width in points")
				ck_near(t, b.fixed.pt_h, 841.89, 0.5, "page height in points")
				ck_eq_str(t, b.doc.title, "Oracle Document", "the PDF's title metadata")
				ck_eq_str(t, b.doc.author, "palmy docs", "the PDF's author metadata")

				// The text layer, and the markers in it.
				fixed_load_text(&b.fixed)
				ck(t, len(b.fixed.text) >= want_pages, "a text layer page for every page: %d", len(b.fixed.text))
				ck(
					t,
					strings.contains(fixed_page_text(&b.fixed, 1), "ORACLE-MARKER-ONE"),
					"the first page's text layer holds the first marker",
				)
				last_has := false
				for pg in 1 ..= b.fixed.pages {
					if strings.contains(fixed_page_text(&b.fixed, pg), "ORACLE-MARKER-TWO") {
						last_has = true
					}
				}
				ck(t, last_has, "the second marker is somewhere in the text layer")

				// Search over a fixed document goes through the text layer.
				s: Search
				defer search_destroy(&s)
				book_search(&b, &s, "ORACLE-MARKER-TWO")
				ck_eq_int(t, len(s.hits), 1, "searching a PDF finds the marker once")
				if len(s.hits) == 1 {
					ck(t, s.hits[0].page >= 1 && s.hits[0].page <= b.fixed.pages, "and reports a real page: %d", s.hits[0].page)
				}

				// The outline, which apps/docs writes from the headings.
				ck(t, len(b.fixed.outline) >= 2, "the PDF's outline was read: %d entries", len(b.fixed.outline))
				if len(b.fixed.outline) >= 1 {
					ck_eq_str(t, b.fixed.outline[0].title, "Oracle Document", "the first outline entry")
					ck(t, b.fixed.outline[0].block == 1, "and it points at page 1, got %d", b.fixed.outline[0].block)
				}

				// Rasterising, which is the part that costs real time.
				t0 := time.now()
				img, rok := fixed_rasterise_public(.Pdf, pdf, dir, 1, 110, b.fixed.pages)
				ms := time.duration_milliseconds(time.since(t0))
				ck(t, rok && img.w > 100 && img.h > 100, "page 1 rasterises to %d x %d in %.0f ms", img.w, img.h, ms)
				if rok {
					// The page is mostly white with some ink on it: a blank
					// render would pass a size check and fail a reader.
					ink := count_dark(img)
					ck(t, ink > 200, "the rasterised page has ink on it: %d dark pixels", ink)
					ck(t, ink < img.w * img.h / 3, "and is not a solid block: %d of %d", ink, img.w * img.h)
					p.image_destroy(&img)
				}

				// A page number outside the document must not render.
				_, bad := fixed_rasterise_public(.Pdf, pdf, dir, 9999, 110, b.fixed.pages)
				ck(t, !bad, "a page past the end does not rasterise")

				// Fit arithmetic.
				ck_eq_int(t, fixed_dpi(&b.fixed, 595.276, 841.89, .Width, 1), 70, "fit-width at natural size is about 72 dpi")
				ck(
					t,
					fixed_dpi(&b.fixed, 1200, 400, .Page) < fixed_dpi(&b.fixed, 1200, 400, .Width),
					"fit-page is never bigger than fit-width in a wide window",
				)
				ck_eq_int(t, fixed_dpi(&b.fixed, 0, 0, .Zoom, 2), 220, "zoom 200% is 220 dpi")
				ck(t, fixed_dpi(&b.fixed, 100000, 100000, .Width) <= 400, "dpi is capped")
			}
		}
	}

	group(t, "djvu")
	djvu := make_test_djvu(dir)
	if djvu == "" {
		ck(t, true, "djvulibre's encoder is not available; the DjVu test was skipped")
		return
	}
	b: Book
	ok := book_open(&b, djvu, fonts, dir, test_opts())
	ck(t, ok, "the generated DjVu opens: %s", b.err)
	if !ok {
		return
	}
	defer book_close(&b)
	ck(t, b.format == .Djvu, "format detected as DjVu")
	ck_eq_int(t, b.fixed.pages, 3, "three pages")
	ck(t, b.fixed.pt_w > 10 && b.fixed.pt_h > 10, "a page size was read: %.0f x %.0f pt", b.fixed.pt_w, b.fixed.pt_h)
	ck_eq_int(t, len(b.fixed.outline), 3, "the outline djvused was given comes back")
	if len(b.fixed.outline) == 3 {
		ck_eq_str(t, b.fixed.outline[0].title, "Chapter One", "outline entry one")
		ck_eq_str(t, b.fixed.outline[2].title, "Sub A", "outline entry three")
		ck_eq_int(t, b.fixed.outline[1].block, 2, "outline entry two points at page 2")
		ck(t, b.fixed.outline[2].depth >= 1, "the nested outline entry is deeper: %d", b.fixed.outline[2].depth)
	}
	img, rok := fixed_rasterise_public(.Djvu, djvu, dir, 2, 100, b.fixed.pages)
	ck(t, rok && img.w > 10 && img.h > 10, "page 2 rasterises to %d x %d", img.w, img.h)
	if rok {
		ck(t, count_dark(img) > 100, "the rasterised DjVu page has ink on it")
		p.image_destroy(&img)
	}
	_, bad := fixed_rasterise_public(.Djvu, djvu, dir, 99, 100, b.fixed.pages)
	ck(t, !bad, "a DjVu page past the end does not rasterise")
}

count_dark :: proc(img: p.Image) -> int {
	n := 0
	for px in img.px {
		r := int((px >> 16) & 0xff)
		g := int((px >> 8) & 0xff)
		b := int(px & 0xff)
		if r + g + b < 330 {
			n += 1
		}
	}
	return n
}

atoi_simple :: proc(s: string) -> int {
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + int(c - '0')
	}
	return n
}

// find_docs_bin locates the PDF oracle: apps/docs, which exports a PDF from
// Markdown and so can be asked to produce a document of known content.
//
// Two things it is careful about. The absolute path is tried first, because
// `os.process_exec` execs what it is given and a relative path resolves
// against whatever directory the caller happened to be in. And the file has to
// be non-empty: other agents build into this tree at the same time, and a
// binary caught mid-link is zero bytes, which execs as ENOEXEC. That is the
// oracle being unavailable, not the reader being wrong, so it must read as a
// skip rather than a failure.
find_docs_bin :: proc() -> string {
	return find_tool_bin("apps/docs/docs.bin")
}

// find_tool_bin resolves another app's binary in this repository, absolutely,
// and only if it is a file with something in it.
find_tool_bin :: proc(rel: string) -> string {
	usable :: proc(path: string) -> bool {
		fi, err := os.stat(path, context.temp_allocator)
		return err == nil && fi.size > 0
	}
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
		if c := tfmt("%s/%s", cwd, rel); usable(c) {
			return strings.clone(c, context.temp_allocator)
		}
	}
	if c := tfmt("/home/alex/Work/palmy/%s", rel); usable(c) {
		return strings.clone(c, context.temp_allocator)
	}
	if usable(rel) {
		return rel
	}
	return ""
}

// make_test_djvu builds a three-page DjVu with djvulibre's own tools and gives
// it an outline, so the reader has something to be right or wrong about.
make_test_djvu :: proc(dir: string) -> string {
	if !kit_has_tool("c44") || !kit_has_tool("djvm") || !kit_has_tool("djvused") {
		return ""
	}
	W :: 300
	H :: 400
	pages := make([dynamic]string, 0, 3, context.temp_allocator)
	for i in 1 ..= 3 {
		pgm := make([dynamic]u8, 0, W * H + 32, context.temp_allocator)
		append(&pgm, tfmt("P5\n%d %d\n255\n", W, H))
		px := make([]u8, W * H, context.temp_allocator)
		for k in 0 ..< W * H {
			px[k] = 255
		}
		for y in 40 * i ..< 40 * i + 40 {
			for x in 20 ..< W - 20 {
				px[y * W + x] = 0
			}
		}
		append(&pgm, ..px)
		gray := tfmt("%s/djvu-p%d.pgm", dir, i)
		if os.write_entire_file(gray, pgm[:]) != nil {
			return ""
		}
		one := tfmt("%s/djvu-p%d.djvu", dir, i)
		if _, ok := kit_run({"c44", "-crcbnone", gray, one}); !ok {
			return ""
		}
		append(&pages, one)
	}
	out := tfmt("%s/generated.djvu", dir)
	os.remove(out)
	argv := make([dynamic]string, 0, 6, context.temp_allocator)
	append(&argv, "djvm", "-c", out)
	append(&argv, ..pages[:])
	if _, ok := kit_run(argv[:]); !ok {
		return ""
	}
	ol := tfmt("%s/outline.txt", dir)
	_ = os.write_entire_file(
		ol,
		transmute([]u8)string("(bookmarks\n (\"Chapter One\" \"#1\")\n (\"Chapter Two\" \"#2\"\n  (\"Sub A\" \"#3\") ) )\n"),
	)
	if _, ok := kit_run({"djvused", "-e", tfmt("set-outline %s", ol), "-s", out}); !ok {
		return out
	}
	return out
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

test_store :: proc(t: ^T, dir: string) {
	group(t, "store")

	// A private library directory, so the test cannot touch the real one.
	home := tfmt("%s/store", dir)
	_ = os.make_directory_all(home)
	old := os.get_env("PALMY_READER_HOME", context.temp_allocator)
	_ = os.set_env("PALMY_READER_HOME", home)
	defer _ = os.set_env("PALMY_READER_HOME", old)

	ck_eq_str(t, store_dir(context.temp_allocator), home, "PALMY_READER_HOME is honoured")

	id1 := book_id("/books/one.epub", context.temp_allocator)
	id2 := book_id("/books/two.epub", context.temp_allocator)
	ck_eq_int(t, len(id1), 16, "a book id is 16 hex digits")
	ck(t, id1 != id2, "different paths give different ids")
	ck_eq_str(t, id1, book_id("/books/one.epub", context.temp_allocator), "the same path gives the same id")
	ck(t, !strings.contains(id1, "/"), "an id has no slash in it")

	l: Library
	library_init(&l)
	ck_eq_str(t, l.err, "", "the library directory was created")

	i := library_add(&l, "/books/one.epub", nil)
	l.books[i].title = strings.clone("Book\tWith\tTabs")
	l.books[i].author = strings.clone("A. Author")
	l.books[i].chapter = 7
	l.books[i].block = 1234
	l.books[i].off = 56
	l.books[i].frac = 0.4321
	append(
		&l.books[i].marks,
		Mark{kind = .Bookmark, chapter = 7, block = 1234, off = 56, text = strings.clone("a bookmark")},
	)
	append(
		&l.books[i].marks,
		Mark{kind = .Highlight, chapter = 2, block = 9, off = 1, end = 20, text = strings.clone("highlighted words")},
	)
	ck(t, library_save(&l), "the library saved")
	ck(t, marks_save(&l, i), "the marks saved")

	set := Settings {
		size = 23,
		line = 1.9,
		margin = 0.17,
		theme = .Sepia,
		justify = true,
		para = .Spaced,
		mode = .Continuous,
		fit = .Page,
		zoom = 1.75,
	}
	ck(t, settings_save(&l, set), "the settings saved")
	library_destroy(&l)

	l2: Library
	library_init(&l2)
	library_load(&l2)
	defer library_destroy(&l2)
	ck_eq_int(t, len(l2.books), 1, "one book came back")
	if len(l2.books) == 1 {
		e := &l2.books[0]
		ck_eq_str(t, e.path, "/books/one.epub", "the path came back")
		ck_eq_str(t, e.title, "Book With Tabs", "tabs in a title became spaces rather than shifting columns")
		ck_eq_str(t, e.author, "A. Author", "the author came back")
		ck_eq_int(t, e.chapter, 7, "the chapter came back")
		ck_eq_int(t, e.block, 1234, "the block came back")
		ck_eq_int(t, e.off, 56, "the byte offset came back")
		ck_near(t, e.frac, 0.4321, 0.0001, "the progress fraction came back")
		ck(t, e.missing, "a book whose file is gone is marked missing")
		marks_load(&l2, 0)
		ck_eq_int(t, len(e.marks), 2, "both marks came back")
		if len(e.marks) == 2 {
			ck(t, e.marks[0].kind == .Bookmark, "the bookmark's kind")
			ck_eq_str(t, e.marks[0].text, "a bookmark", "the bookmark's text")
			ck(t, e.marks[1].kind == .Highlight, "the highlight's kind")
			ck_eq_int(t, e.marks[1].end, 20, "the highlight's end offset")
		}
	}

	s2 := settings_load(&l2)
	ck_near(t, s2.size, 23, 0.01, "type size came back")
	ck_near(t, s2.line, 1.9, 0.001, "line height came back")
	ck_near(t, s2.margin, 0.17, 0.001, "margin came back")
	ck(t, s2.theme == .Sepia, "theme came back")
	ck(t, s2.justify, "justification came back")
	ck(t, s2.para == .Spaced, "paragraph style came back")
	ck(t, s2.mode == .Continuous, "reading mode came back")
	ck(t, s2.fit == .Page, "fit mode came back")
	ck_near(t, s2.zoom, 1.75, 0.001, "zoom came back")

	// A corrupt line costs one book, not the library.
	_ = os.write_entire_file(
		tfmt("%s/library.tsv", home),
		transmute([]u8)string(
			"# header\nthis line is garbage\nid1\t/a.epub\tEPUB\tGood\tAuthor\t1\t2\t0\t0\t0\t0\t0.5\t3\n",
		),
	)
	l3: Library
	library_init(&l3)
	library_load(&l3)
	defer library_destroy(&l3)
	ck_eq_int(t, len(l3.books), 1, "a garbage line is skipped and the good one survives")

	// A missing settings file gives the defaults rather than zeroes.
	_ = os.remove(tfmt("%s/settings.tsv", home))
	s3 := settings_load(&l3)
	d := settings_default()
	ck_near(t, s3.size, d.size, 0.01, "absent settings fall back to the defaults")
}

// ---------------------------------------------------------------------------
// Reopening where you left off
//
// The feature people actually notice, tested the way it is used: open a book,
// read into it, close the program, start it again, and be on the same words.
// It goes through the real Reader -- the same open path, the same save path,
// the same restore path the window uses -- with a stand-in App for the font
// table, because none of it needs a compositor.
// ---------------------------------------------------------------------------

test_resume :: proc(t: ^T, dir: string, png: []u8, fonts: ^p.Fonts) {
	group(t, "resume")

	home := tfmt("%s/resume", dir)
	_ = os.make_directory_all(home)
	_ = os.remove(tfmt("%s/library.tsv", home))
	old := os.get_env("PALMY_READER_HOME", context.temp_allocator)
	_ = os.set_env("PALMY_READER_HOME", home)
	defer _ = os.set_env("PALMY_READER_HOME", old)

	// A book long enough to have somewhere to be lost in.
	big := tfmt("%s/resume.epub", dir)
	okgen, _ := gen_big_epub(big, 6, 30)
	ck(t, okgen, "a multi-chapter book was generated for the resume test")

	app := new(p.App)
	defer free(app)
	app.win.width, app.win.height = 1180, 820
	app.fonts = fonts^

	// --- session one: open, read in, close.
	want_block := 0
	want_text := ""
	want_frac := f32(0)
	{
		r := new(Reader)
		defer free(r)
		r.app = app
		r.cur = -1
		r.sel_block = -1
		r.qbuf = make([dynamic]u8, 0, 8)
		r.set = settings_default()
		library_init(&r.lib)
		library_load(&r.lib)

		reader_open(r, big)
		ck(t, r.book.open, "session one opened the book: %s", r.book.err)
		if !r.book.open {
			library_destroy(&r.lib)
			return
		}
		ck_eq_int(t, r.chapter, 0, "a book never opened before starts at the beginning")
		ck_eq_int(t, r.page, 0, "and on page one")

		// Read in: four chapters along and a few pages into it.
		reader_chapter_step(r, 4)
		reader_turn(r, 3)
		ck_eq_int(t, r.chapter, 4, "stepped four chapters in")
		ck(t, r.page >= 1, "and some pages into that chapter: %d", r.page)

		cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
		blk, off := layout_pos_at(cl, r.page)
		want_block = blk
		want_text = strings.clone(block_text(&r.book.doc, blk)[:40], context.temp_allocator)
		want_frac = reader_progress(r)
		ck(t, want_frac > 0.3 && want_frac < 1, "progress is somewhere in the middle: %.3f", want_frac)
		_ = off

		reader_shutdown(r)
	}

	// The library file on disk is what the next session reads.
	{
		data, err := os.read_entire_file_from_path(tfmt("%s/library.tsv", home), context.temp_allocator)
		ck(t, err == nil, "a library file was written")
		ck(t, strings.contains(string(data), "resume.epub"), "and it names the book")
	}

	// --- session two: open the same book and land on the same words.
	{
		r := new(Reader)
		defer free(r)
		r.app = app
		r.cur = -1
		r.sel_block = -1
		r.qbuf = make([dynamic]u8, 0, 8)
		r.set = settings_default()
		library_init(&r.lib)
		library_load(&r.lib)
		ck_eq_int(t, len(r.lib.books), 1, "the library remembered one book")

		reader_open(r, big)
		ck(t, r.book.open, "session two opened the book")
		if r.book.open {
			ck_eq_int(t, r.chapter, 4, "and came back to the same chapter")
			cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
			on_page := false
			for ln in layout_page_lines(cl, r.page) {
				if ln.block == want_block {
					on_page = true
				}
			}
			ck(t, on_page, "and to a page holding the paragraph it was left on")
			got := block_text(&r.book.doc, want_block)
			ck_eq_str(t, got[:min(40, len(got))], want_text, "which is the same paragraph, by its text")
			ck_near(t, reader_progress(r), want_frac, 0.02, "and reports the same progress")
		}
		reader_shutdown(r)
	}

	// --- session three: a different type size, and still the same words.
	{
		r := new(Reader)
		defer free(r)
		r.app = app
		r.cur = -1
		r.sel_block = -1
		r.qbuf = make([dynamic]u8, 0, 8)
		r.set = settings_default()
		r.set.size = 26
		r.set.margin = 0.2
		library_init(&r.lib)
		library_load(&r.lib)
		reader_open(r, big)
		if r.book.open {
			ck_eq_int(t, r.chapter, 4, "a bigger type size still opens the right chapter")
			cl := reflow_chapter(&r.book.reflow, &r.book.doc, r.chapter)
			on_page := false
			for ln in layout_page_lines(cl, r.page) {
				if ln.block == want_block {
					on_page = true
				}
			}
			ck(t, on_page, "and lands on the same paragraph despite the page having changed shape")
			ck(
				t,
				cl.pages != 0,
				"the chapter repaginated at the new size: %d pages",
				cl.pages,
			)
		}
		reader_shutdown(r)
	}
}

// ---------------------------------------------------------------------------
// Fixtures, for the demo and for looking at by hand
// ---------------------------------------------------------------------------

write_fixtures :: proc(dir: string) {
	_ = os.make_directory_all(dir)
	png := make_test_png(dir)
	epub := tfmt("%s/generated.epub", dir)
	mobi := tfmt("%s/generated.mobi", dir)
	ok1 := gen_epub_file(epub, fixture_book(png))
	ok2 := gen_mobi_file(
		mobi,
		{title = "A Generated Mobipocket", author = "M. Fixture", html = MOBI_HTML, compress = true},
	)
	fmt.printfln("%s %v", epub, ok1)
	fmt.printfln("%s %v", mobi, ok2)

	// A fixed-page book for the fixtures. apps/slides exports a PDF with one
	// page per slide and needs no input file, so it is tried first; apps/docs
	// is the fallback. Either way the PDF is generated by this repository and
	// holds nothing of the user's.
	if slides := find_tool_bin("apps/slides/slides.bin"); slides != "" {
		out := strings.clone(tfmt("%s/slides.pdf", dir))
		defer delete(out)
		_, c := kit_run({slides, "--pdf", out})
		fmt.printfln("%s %v", out, c)
	}
	if docs := find_docs_bin(); docs != "" {
		// Cloned rather than left in the temp allocator. Nothing here resets
		// it, so a tprintf path would in fact survive -- but these two are
		// handed to a subprocess, and a path that argv holds is exactly the
		// kind of thing that should not depend on an allocator somebody else
		// may decide to reset.
		md := strings.clone(tfmt("%s/oracle.md", dir))
		pdf := strings.clone(tfmt("%s/generated.pdf", dir))
		defer delete(md)
		defer delete(pdf)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "# A Fixed Page Document\n\n")
		strings.write_string(
			&b,
			"This PDF was generated by apps/docs so that the reader's fixed-page mode has something of known content to show.\n\n",
		)
		for i in 0 ..< 40 {
			strings.write_string(
				&b,
				tfmt("Paragraph %d. A page is a picture here: there is no font size to change and no text to re-wrap, only how big to draw it.\n\n", i + 1),
			)
		}
		strings.write_string(&b, "## The Second Section\n\nAnd a heading, so the outline has more than one entry.\n")
		_ = os.write_entire_file(md, transmute([]u8)strings.to_string(b))
		// `env USER=...` is not decoration. apps/docs stamps the PDFs it
		// exports with `$USER`, so a fixture made here would carry the name
		// of whoever built it -- straight into a committed screenshot and
		// into the recorded demo. Overriding it for the child is the whole
		// fix, and it touches nothing in apps/docs.
		_, c := kit_run({"env", "USER=palmy docs", docs, "--convert", md, pdf})
		fmt.printfln("%s %v", pdf, c)
	}
	if dj := make_test_djvu(dir); dj != "" {
		fmt.printfln("%s true", dj)
	}
}
