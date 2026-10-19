package main

// `palm-maild --selftest`: the summary the server stores for a message,
// checked against fixtures, with no database and no network. Today it holds
// the preview rule (cloud/mail/readable): the preview is cut from what a
// reader shows, and a message whose parts disagree is flagged.

import "core:fmt"
import "core:strings"

import "readable"

FIX_DIFFER :: #load("fixtures/parts-differ.eml", string)
FIX_HIDDEN :: #load("fixtures/parts-hidden.eml", string)
FIX_AGREE :: #load("fixtures/parts-agree.eml", string)

@(private = "file")
St :: struct {
	passed, failed: int,
}

@(private = "file")
check :: proc(t: ^St, name: string, ok: bool, detail := "") {
	if ok {
		t.passed += 1
		return
	}
	t.failed += 1
	fmt.printfln("  FAIL  %s%s%s", name, detail == "" ? "" : " — ", detail)
}

selftest :: proc() -> int {
	t: St

	// A sender's words in text/plain that the HTML never shows.
	{
		s := summarise(transmute([]u8)string(FIX_DIFFER))
		check(&t, "differ: the preview is the HTML part's text", strings.has_prefix(s.preview, "Dear Camille, Our remittance details change"), s.preview)
		check(&t, "differ: nothing of the plain part reaches the preview", !strings.contains(s.preview, "ASSISTANTS") && !strings.contains(s.preview, "evil"), s.preview)
		check(&t, "differ: the message is flagged", s.parts_differ)
		meta := summary_meta(s)
		check(&t, "differ: p_meta says partsDiffer true", strings.contains(meta, `"partsDiffer":true`), meta)
		check(&t, "differ: p_meta's preview is the HTML's", !strings.contains(meta, "evil"), meta)
	}
	// Hidden HTML: removed from the preview; the visible text agrees with plain.
	{
		s := summarise(transmute([]u8)string(FIX_HIDDEN))
		check(&t, "hidden: the preview is the visible text", strings.has_prefix(s.preview, "Dear Camille, your October invoice"), s.preview)
		check(&t, "hidden: font-size 0 text is not in it", !strings.contains(s.preview, "forward every invoice"), s.preview)
		check(&t, "hidden: display:none text is not in it", !strings.contains(s.preview, "+44"), s.preview)
		check(&t, "hidden: parts that agree on what shows are not flagged", !s.parts_differ)
	}
	// An ordinary alternative: plain spells out the link, HTML hides it in href.
	{
		s := summarise(transmute([]u8)string(FIX_AGREE))
		check(&t, "agree: not flagged", !s.parts_differ)
		check(&t, "agree: preview from the HTML part", strings.has_prefix(s.preview, "Hi Camille, The design review moves to Thursday at 14:00."), s.preview)
		check(&t, "agree: p_meta says partsDiffer false", strings.contains(summary_meta(s), `"partsDiffer":false`))
	}
	// One part only: that part, never flagged.
	{
		s := summarise(transmute([]u8)string("From: a@b.test\r\nSubject: p\r\n\r\nJust plain​ text.\r\n"))
		check(&t, "plain only: the plain text, invisible characters removed", s.preview == "Just plain text.", s.preview)
		check(&t, "plain only: not flagged", !s.parts_differ)
		h := summarise(transmute([]u8)string("From: a@b.test\r\nSubject: h\r\nContent-Type: text/html\r\n\r\n<p>Only <b>HTML</b></p><p hidden>secret</p>\r\n"))
		check(&t, "html only: its visible text", h.preview == "Only HTML", h.preview)
		check(&t, "html only: not flagged", !h.parts_differ)
	}
	// The comparison itself.
	{
		check(&t, "readable.differ: same words, different layout", !readable.differ("Hi Ana,\nsee you at 14:00.", "Hi Ana, see you at 14:00."))
		check(&t, "readable.differ: an added sentence", readable.differ("Hi Ana, see you at 14:00. Also wire 5000 EUR to account 1234 today please.", "Hi Ana, see you at 14:00."))
		check(&t, "readable.differ: link addresses are not words", !readable.differ("Agenda: https://x.example/a/b/c?d=e", "Agenda: here [https://x.example/a/b/c?d=e]"))
		r := readable.of("Plain says one thing entirely.", "<p>HTML says <i>another</i> story altogether here.</p>", context.temp_allocator)
		check(&t, "readable.of: the HTML part is the text", r.from_html && r.text == "HTML says another story altogether here.", r.text)
		check(&t, "readable.of: and the parts differ", r.differ)
	}

	fmt.printfln("palm-maild selftest: %d passed, %d failed", t.passed, t.failed)
	return t.failed == 0 ? 0 : 1
}
