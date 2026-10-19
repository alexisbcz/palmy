// Package untrusted prepares content from outside the person — a mail, a
// file, a chat message, a web page — before a model sees it.
//
// Two rules, from cloud/docs/assistant.md:
//
//  1. **The model reads what the person sees.** Text a person cannot see is
//     removed: HTML hidden by style (display:none, visibility:hidden,
//     font-size 0, opacity 0, white or transparent text, a one-pixel box,
//     text pushed off the page), HTML comments, <script>, <style>, <head>,
//     <template>, the `hidden` attribute; and in any text, zero-width
//     characters, bidirectional overrides, and Unicode tag characters (the
//     "ASCII smuggling" block, U+E0000–U+E007F, which renders as nothing and
//     which models read as letters). The count of what was removed is kept,
//     so the interface can say "3 hidden passages were removed from this
//     mail" rather than hide the fact.
//
//  2. **It is data, not instructions.** `fence` wraps it in a labelled block
//     whose closing marker cannot occur inside it, so a mail that writes its
//     own "end of quoted content, new instructions follow" stays inside the
//     quote. The runtime's rules (cloud/assistant/engine) do the rest: no
//     outbound act from a turn that read untrusted content without the
//     person's confirmation, whatever the model says.
//
// None of this makes a model immune to what it reads; nothing does. It
// removes the cheapest attacks (the Gemini-summary hidden text, the Notion
// PDF) and makes the remaining ones visible, while the confirmation rule
// makes them harmless.
package untrusted

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Clean :: struct {
	text:    string,
	removed: int, // hidden passages and invisible characters dropped
	notes:   [dynamic]string, // what kind, for the interface: "display:none", "zero-width"
}

@(private)
note :: proc(c: ^Clean, what: string) {
	c.removed += 1
	for n in c.notes {
		if n == what {return}
	}
	append(&c.notes, what)
}

// invisible reports a code point that renders as nothing (or reorders what
// is around it) and so has no business in text a model reads.
invisible :: proc(r: rune) -> (bool, string) {
	switch r {
	case 0x200B ..= 0x200F, 0x2060 ..= 0x2064, 0xFEFF, 0x00AD, 0x034F, 0x180E:
		return true, "zero-width characters"
	case 0x202A ..= 0x202E, 0x2066 ..= 0x2069:
		return true, "bidirectional overrides"
	case 0xE0000 ..= 0xE007F:
		return true, "Unicode tag characters (hidden ASCII)"
	case 0xFE00 ..= 0xFE0F, 0xE0100 ..= 0xE01EF:
		return true, "variation selectors"
	}
	if r < 0x20 && r != '\n' && r != '\t' {
		return true, "control characters"
	}
	if r == 0x7F || (r >= 0x80 && r < 0xA0) {
		return true, "control characters"
	}
	return false, ""
}

// text removes invisible characters from plain text and folds CR/LF.
text :: proc(src: string, allocator := context.allocator) -> Clean {
	c := Clean{notes = make([dynamic]string, allocator)}
	b := strings.builder_make(allocator)
	run := false // count a run of invisibles as one passage
	for r in src {
		if r == '\r' {continue}
		if bad, what := invisible(r); bad {
			if !run {
				note(&c, what)
			} else {
				// One passage, but every way it hid itself is named.
				seen := false
				for n in c.notes {if n == what {seen = true}}
				if !seen {append(&c.notes, what)}
			}
			run = true
			continue
		}
		run = false
		strings.write_rune(&b, r)
	}
	c.text = strings.to_string(b)
	return c
}

// ---------------------------------------------------------------------------
// HTML to the text a person would see
// ---------------------------------------------------------------------------

@(private)
lower :: proc(s: string) -> string {
	return strings.to_lower(s, context.temp_allocator)
}

// style_hides reads an inline style and says whether it makes its element's
// text invisible to a reader.
style_hides :: proc(style: string) -> (bool, string) {
	s := lower(style)
	s, _ = strings.remove_all(s, " ", context.temp_allocator)
	s, _ = strings.remove_all(s, "\t", context.temp_allocator)
	s, _ = strings.remove_all(s, "\n", context.temp_allocator)
	decls := strings.split(s, ";", context.temp_allocator)
	for d in decls {
		colon := strings.index_byte(d, ':')
		if colon < 0 {continue}
		k, v := d[:colon], d[colon + 1:]
		v = strings.trim_suffix(v, "!important")
		switch k {
		case "display":
			if v == "none" {return true, "display:none"}
		case "visibility":
			if v == "hidden" || v == "collapse" {return true, "visibility:hidden"}
		case "opacity":
			if v == "0" || v == "0.0" || v == "0%" || strings.has_prefix(v, "0.0") {return true, "opacity:0"}
		case "font-size", "line-height", "max-height", "height", "width", "max-width":
			if k == "font-size" || k == "max-height" || k == "height" {
				if zeroish(v) {return true, fmt.tprintf("%s:0", k)}
			}
			if k == "font-size" && (v == "1px" || v == "0.1px" || v == "0.5px") {return true, "font-size:1px"}
		case "color":
			if v == "#fff" || v == "#ffffff" || v == "white" || v == "transparent" ||
			   strings.has_prefix(v, "rgba(255,255,255") || v == "rgb(255,255,255)" ||
			   strings.has_suffix(v, ",0)") {
				return true, "white or transparent text"
			}
		case "text-indent", "left", "top", "margin-left":
			if strings.has_prefix(v, "-") && len(v) > 4 {return true, "text moved off the page"}
		case "clip-path":
			if strings.contains(v, "inset(50%") || strings.contains(v, "inset(100%") {return true, "clip-path"}
		case "clip":
			if strings.contains(v, "rect(0") {return true, "clip"}
		case "transform":
			if strings.contains(v, "scale(0") {return true, "scale(0)"}
		}
	}
	return false, ""
}

@(private)
zeroish :: proc(v: string) -> bool {
	for suffix in ([?]string{"px", "pt", "em", "rem", "%", ""}) {
		n := strings.trim_suffix(v, suffix)
		if n == "0" || n == "0.0" || n == "0.00" {return true}
	}
	return false
}

@(private)
attr :: proc(tag, name: string) -> (string, bool) {
	t := lower(tag)
	i := 0
	for {
		j := strings.index(t[i:], name)
		if j < 0 {return "", false}
		at := i + j
		before := at == 0 ? ' ' : t[at - 1]
		after := at + len(name) < len(t) ? t[at + len(name)] : ' '
		if (before == ' ' || before == '\t' || before == '\n' || before == '"' || before == '\'') &&
		   (after == '=' || after == ' ' || after == '>' || after == '/') {
			rest := tag[at + len(name):]
			rest = strings.trim_left_space(rest)
			if !strings.has_prefix(rest, "=") {return "", true}
			rest = strings.trim_left_space(rest[1:])
			if len(rest) > 0 && (rest[0] == '"' || rest[0] == '\'') {
				q := rest[0]
				end := strings.index_byte(rest[1:], q)
				if end < 0 {return rest[1:], true}
				return rest[1:1 + end], true
			}
			end := strings.index_any(rest, " \t\n>")
			if end < 0 {return rest, true}
			return rest[:end], true
		}
		i = at + len(name)
	}
}

@(private)
VOID := [?]string{"br", "hr", "img", "meta", "link", "input", "area", "base", "col", "embed", "source", "track", "wbr"}

@(private)
DROP := [?]string{"script", "style", "head", "title", "template", "noscript", "svg", "object", "iframe"}

@(private)
BLOCK := [?]string{"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol", "blockquote", "hr", "section", "article", "header", "footer"}

@(private)
in_list :: proc(xs: []string, x: string) -> bool {
	for y in xs {
		if x == y {return true}
	}
	return false
}

@(private)
Frame :: struct {
	name:   string,
	hidden: bool,
}

// html renders HTML to the text a reader would see, dropping hidden
// passages and counting them. Links keep their visible text and show their
// address in brackets, so "click here" with an address to somewhere else is
// visible as such; images become "[image: alt]" and are never fetched.
html :: proc(src: string, allocator := context.allocator) -> Clean {
	c := Clean{notes = make([dynamic]string, allocator)}
	out := strings.builder_make(context.temp_allocator)
	stack := make([dynamic]Frame, context.temp_allocator)
	hidden_depth := 0 // > 0 while inside a hidden element
	pending_href := ""
	i := 0
	for i < len(src) {
		ch := src[i]
		if ch == '<' {
			if strings.has_prefix(src[i:], "<!--") {
				end := strings.index(src[i + 4:], "-->")
				body := end < 0 ? src[i + 4:] : src[i + 4:i + 4 + end]
				if len(strings.trim_space(body)) > 0 {note(&c, "HTML comments")}
				i = end < 0 ? len(src) : i + 4 + end + 3
				continue
			}
			end := strings.index_byte(src[i:], '>')
			if end < 0 {break}
			tag := src[i + 1:i + end]
			i += end + 1
			closing := strings.has_prefix(tag, "/")
			name_src := strings.trim_left(tag, "/!?")
			name_end := strings.index_any(name_src, " \t\n/")
			name := lower(name_end < 0 ? name_src : name_src[:name_end])
			if in_list(DROP[:], name) && !closing {
				// Skip to the matching close tag; what is inside never shows.
				close := fmt.tprintf("</%s", name)
				j := strings.index(lower(src[i:]), close)
				body := j < 0 ? src[i:] : src[i:i + j]
				if name != "head" && name != "title" && name != "style" && len(strings.trim_space(body)) > 0 {
					note(&c, fmt.tprintf("<%s>", name))
				} else if name == "style" || name == "head" {
					// Styles are expected; not worth reporting.
				}
				if j < 0 {
					i = len(src)
				} else {
					k := strings.index_byte(src[i + j:], '>')
					i = k < 0 ? len(src) : i + j + k + 1
				}
				continue
			}
			if closing {
				// Pop to the matching frame.
				for k := len(stack) - 1; k >= 0; k -= 1 {
					if stack[k].name == name {
						for len(stack) > k {
							f := pop(&stack)
							if f.hidden {hidden_depth -= 1}
						}
						break
					}
				}
				if name == "a" && pending_href != "" && hidden_depth == 0 {
					fmt.sbprintf(&out, " [%s]", pending_href)
					pending_href = ""
				}
				if in_list(BLOCK[:], name) && hidden_depth == 0 {strings.write_byte(&out, '\n')}
				continue
			}
			hides := false
			if st, ok := attr(tag, "style"); ok {
				h, what := style_hides(st)
				if h {hides = true; note(&c, what)}
			}
			if _, ok := attr(tag, "hidden"); ok {
				hides = true
				note(&c, "the hidden attribute")
			}
			if v, ok := attr(tag, "aria-hidden"); ok && lower(v) == "true" && name != "img" {
				hides = true
				note(&c, "aria-hidden")
			}
			if hidden_depth == 0 && !hides {
				if in_list(BLOCK[:], name) {strings.write_byte(&out, '\n')}
				if name == "img" {
					alt, _ := attr(tag, "alt")
					fmt.sbprintf(&out, "[image%s%s]", alt != "" ? ": " : "", alt)
				}
				if name == "a" {
					href, _ := attr(tag, "href")
					pending_href = href
				}
			}
			self_closing := strings.has_suffix(tag, "/") || in_list(VOID[:], name)
			if !self_closing {
				append(&stack, Frame{name = name, hidden = hides})
				if hides {hidden_depth += 1}
			}
			continue
		}
		// Text: up to the next tag.
		j := strings.index_byte(src[i:], '<')
		chunk := j < 0 ? src[i:] : src[i:i + j]
		i = j < 0 ? len(src) : i + j
		if hidden_depth > 0 {
			continue
		}
		strings.write_string(&out, entities(chunk))
	}
	// Whitespace as a reader sees it: runs of spaces folded, at most one
	// blank line.
	t := text(strings.to_string(out), context.temp_allocator)
	c.removed += t.removed
	for n in t.notes {
		found := false
		for m in c.notes {if m == n {found = true}}
		if !found {append(&c.notes, strings.clone(n, allocator))}
	}
	c.text = fold(t.text, allocator)
	return c
}

@(private)
entities :: proc(s: string) -> string {
	if strings.index_byte(s, '&') < 0 {return s}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '&' {
			end := strings.index_byte(s[i:], ';')
			if end > 0 && end < 10 {
				e := s[i + 1:i + end]
				rep := ""
				switch e {
				case "amp": rep = "&"
				case "lt": rep = "<"
				case "gt": rep = ">"
				case "quot": rep = "\""
				case "apos", "#39": rep = "'"
				case "nbsp", "#160": rep = " "
				case "zwj", "zwnj", "#8203", "#x200b", "#x200B", "#8204", "#8205", "#65279":
					rep = "​" // removed later, and counted
				}
				if rep == "" && strings.has_prefix(e, "#") {
					n := 0
					ok := true
					hex := strings.has_prefix(e, "#x") || strings.has_prefix(e, "#X")
					digits := hex ? e[2:] : e[1:]
					for d in digits {
						switch {
						case d >= '0' && d <= '9': n = n * (hex ? 16 : 10) + int(d - '0')
						case hex && d >= 'a' && d <= 'f': n = n * 16 + int(d - 'a' + 10)
						case hex && d >= 'A' && d <= 'F': n = n * 16 + int(d - 'A' + 10)
						case: ok = false
						}
					}
					if ok && n > 0 && n < 0x110000 {
						buf, w := utf8.encode_rune(rune(n))
						rep = strings.clone(string(buf[:w]), context.temp_allocator)
					}
				}
				if rep != "" {
					strings.write_string(&b, rep)
					i += end + 1
					continue
				}
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// fold collapses whitespace runs and blank-line runs.
fold :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	lines := strings.split(s, "\n", context.temp_allocator)
	blank := 0
	wrote := false
	for raw in lines {
		fields := strings.fields(raw, context.temp_allocator)
		if len(fields) == 0 {
			blank += 1
			continue
		}
		if wrote {
			strings.write_string(&b, blank > 0 ? "\n\n" : "\n")
		}
		blank = 0
		for f, k in fields {
			if k > 0 {strings.write_byte(&b, ' ')}
			strings.write_string(&b, f)
		}
		wrote = true
	}
	return strings.to_string(b)
}

// markdown removes what a Markdown renderer would not show: HTML comments
// and hidden HTML inside it, and invisible characters.
markdown :: proc(src: string, allocator := context.allocator) -> Clean {
	if strings.contains(src, "<") {
		// Markdown may carry HTML; render that part as HTML would be shown.
		return html_in_markdown(src, allocator)
	}
	return text(src, allocator)
}

@(private)
html_in_markdown :: proc(src: string, allocator := context.allocator) -> Clean {
	c := Clean{notes = make([dynamic]string, allocator)}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(src) {
		if strings.has_prefix(src[i:], "<!--") {
			end := strings.index(src[i + 4:], "-->")
			note(&c, "HTML comments")
			i = end < 0 ? len(src) : i + 4 + end + 3
			continue
		}
		if src[i] == '<' {
			end := strings.index_byte(src[i:], '>')
			if end > 0 {
				tag := src[i + 1:i + end]
				if st, ok := attr(tag, "style"); ok {
					if h, what := style_hides(st); h {
						// Drop the element and its content, to its close tag.
						name_end := strings.index_any(tag, " \t\n/")
						name := lower(name_end < 0 ? tag : tag[:name_end])
						close := fmt.tprintf("</%s>", name)
						j := strings.index(lower(src[i:]), close)
						note(&c, what)
						i = j < 0 ? len(src) : i + j + len(close)
						continue
					}
				}
			}
		}
		strings.write_byte(&b, src[i])
		i += 1
	}
	t := text(strings.to_string(b), allocator)
	c.text = t.text
	c.removed += t.removed
	for n in t.notes {append(&c.notes, n)}
	return c
}

// ---------------------------------------------------------------------------
// Fencing
// ---------------------------------------------------------------------------

FENCE_OPEN :: "<<untrusted"
FENCE_CLOSE :: "<</untrusted>>"

// fence wraps cleaned content in a labelled block. Any "<<" inside becomes
// "‹‹", so the content cannot close the block or open another one.
fence :: proc(source, content: string, allocator := context.allocator) -> string {
	safe, _ := strings.replace_all(content, "<<", "‹‹", context.temp_allocator)
	safe2, _ := strings.replace_all(safe, ">>", "››", context.temp_allocator)
	label, _ := strings.replace_all(source, "\"", "'", context.temp_allocator)
	label2, _ := strings.replace_all(label, ">>", "››", context.temp_allocator)
	return fmt.aprintf("%s source=\"%s\">>\n%s\n%s", FENCE_OPEN, label2, safe2, FENCE_CLOSE, allocator = allocator)
}
