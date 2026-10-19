// Package readable decides which text of a message is "the message": what
// its preview is cut from, what search matches, and whether its parts tell
// two different stories.
//
// A multipart/alternative message carries the same message twice, as
// text/plain and as text/html, and nothing makes a sender keep them alike.
// A preview taken from the plain part while the reader shows the HTML part
// lets a sender put words in the list, in search and in front of the
// assistant that the person never sees in the message (and the reverse,
// with HTML hidden by CSS). The rule, everywhere Palmy computes a
// preview:
//
//  1. The preview is cut from the text the reader shows. A reader that
//     renders HTML (palm-maild's JMAP clients, the assistant) shows the HTML
//     part's *visible* text: hidden passages and invisible characters are
//     removed exactly as cloud/assistant/untrusted removes them. With no HTML
//     part, the plain part, invisible characters removed. A reader that
//     renders text/plain (apps/mail) cuts its preview from the plain part it
//     shows, and nothing else.
//  2. When a message has both parts and their words differ significantly
//     (`differ`), the message is flagged, so whichever part a reader shows,
//     the person can be told the other one says something else.
package readable

import "core:strings"
import "core:unicode"

import un "../../assistant/untrusted"

Readable :: struct {
	text:      string, // what an HTML-rendering reader shows; the preview's source
	from_html: bool, // text came from the HTML part
	plain:     string, // the plain part, invisible characters removed ("" if none)
	html:      string, // the HTML part's visible text ("" if none)
	differ:    bool, // both parts present and significantly different
	hidden:    int, // hidden passages and invisible characters removed
}

// of applies the rule to a message's plain and HTML bodies (either may be
// empty). Everything returned is allocated with `allocator`.
of :: proc(plain, html: string, allocator := context.allocator) -> Readable {
	r: Readable
	if strings.trim_space(plain) != "" {
		c := un.text(plain, allocator)
		r.plain = un.fold(c.text, allocator)
		r.hidden += c.removed
	}
	if strings.trim_space(html) != "" {
		c := un.html(html, allocator)
		r.html = c.text
		r.hidden += c.removed
	}
	if r.html != "" {
		r.text = r.html
		r.from_html = true
	} else {
		r.text = r.plain
	}
	r.differ = r.plain != "" && r.html != "" && differ(r.plain, r.html)
	return r
}

// preview cuts a readable text to one line: whitespace runs folded to one
// space, at most `limit` bytes, cut on a UTF-8 boundary.
preview :: proc(text: string, limit := 256, allocator := context.allocator) -> string {
	flat := strings.join(strings.fields(text, context.temp_allocator), " ", context.temp_allocator)
	if len(flat) > limit {
		cut := limit
		for cut > 0 && (flat[cut] & 0xC0) == 0x80 {cut -= 1}
		flat = flat[:cut]
	}
	return strings.clone(flat, allocator)
}

// clean_plain is a plain part as a reader that renders text/plain shows it:
// line structure kept, invisible characters (zero-width, bidi overrides,
// Unicode tags, controls) removed, so a preview cut from it holds nothing
// the reader would not show.
clean_plain :: proc(plain: string, allocator := context.allocator) -> string {
	return un.text(plain, allocator).text
}

// The thresholds of `differ`: at least MIN_WORDS distinct words found in only
// one of the two, and those at least PERCENT of all distinct words. A plain
// part generated from the HTML (the normal case) differs by link addresses
// and line breaks, which are not words here; a sentence added to one side
// is a dozen words.
MIN_WORDS :: 4
PERCENT :: 20

// differ compares the distinct words of two texts. Link addresses, mail
// addresses and image placeholders are not words: the plain part spells
// out what the HTML puts in an href, and that is not a difference a reader
// would call one.
differ :: proc(a, b: string) -> bool {
	wa := words(a)
	wb := words(b)
	only, all := 0, len(wa)
	for w in wa {
		if !(w in wb) {only += 1}
	}
	for w in wb {
		if !(w in wa) {
			only += 1
			all += 1
		}
	}
	return only >= MIN_WORDS && only * 100 >= all * PERCENT
}

@(private)
words :: proc(s: string) -> map[string]bool {
	set := make(map[string]bool, 64, context.temp_allocator)
	for field in strings.fields(s, context.temp_allocator) {
		f := strings.trim(field, "<>[]()\"'")
		if strings.contains(f, "://") || strings.contains(f, "@") || strings.has_prefix(f, "www.") ||
		   strings.has_prefix(f, "mailto:") || strings.has_prefix(field, "[image") {
			continue
		}
		b := strings.builder_make(context.temp_allocator)
		flush :: proc(set: ^map[string]bool, b: ^strings.Builder) {
			if strings.rune_count(strings.to_string(b^)) >= 2 {
				set[strings.clone(strings.to_string(b^), context.temp_allocator)] = true
			}
			strings.builder_reset(b)
		}
		for r in f {
			if unicode.is_letter(r) || unicode.is_digit(r) {
				strings.write_rune(&b, unicode.to_lower(r))
			} else {
				flush(&set, &b)
			}
		}
		flush(&set, &b)
	}
	return set
}
