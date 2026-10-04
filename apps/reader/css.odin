// The slice of CSS that books use.
//
// This is not a cascade engine and does not pretend to be. The line drawn:
//
//   selectors     a comma list of selectors, each one or two compounds: a
//                 tag, a class, an id, or any combination of them, optionally
//                 preceded by one ancestor compound. So `p`, `.verse`,
//                 `p.verse`, `#note`, `blockquote p` and `.chapter > h2` all
//                 work and mean what they say. A chain of three or more
//                 (`body div.x p em`) keeps only its nearest ancestor and its
//                 subject, which over-applies rather than under-applies; `>`
//                 is read as a descendant combinator rather than a child one,
//                 for the same reason. Matching the nearest ancestor is what
//                 matters in practice: `blockquote p { font-style: italic }`
//                 is in a great many books, and flattening it to `p` sets the
//                 entire book in italic.
//   properties    font-weight, font-style, font-family (only "is it
//                 monospace"), font-size, text-align, text-decoration,
//                 margin-top/bottom (and the shorthand), text-indent,
//                 display:none, page-break-before.
//   units         em, rem, %, pt, px, and the absolute keywords. All of them
//                 become a multiplier on the reader's chosen type size, never
//                 a pixel count, because a book's pixels are the author's
//                 guess and the reader's font size is the reader's decision.
//
//   not here      the box model, floats, positioning, colour, backgrounds,
//                 borders, @media, @font-face, pseudo-classes, counters,
//                 inheritance beyond what the element stack already carries,
//                 and `!important` priority (it parses, it does not win).
//
// A book that leans on any of that still reads; it just reads as the reader's
// typography rather than the author's.
package main

import "core:strconv"
import "core:strings"

Css_Prop :: enum u8 {
	Weight,
	Slant,
	Mono,
	Align,
	Underline,
	Strike,
	Size,
	Margin_Top,
	Margin_Bottom,
	Indent,
	Hidden,
	Break,
}

// Css_Decl is a parsed declaration block: which properties it sets, and to
// what. `has` is what makes the cascade work without inheritance plumbing —
// an unset property is left as whatever the element stack already had.
Css_Decl :: struct {
	has:        bit_set[Css_Prop],
	bold:       bool,
	italic:     bool,
	mono:       bool,
	align:      Align,
	underline:  bool,
	strike:     bool,
	size:       f32, // multiplier
	margin_top: f32, // em
	margin_bot: f32,
	indent:     f32, // em
	hidden:     bool,
	brk:        bool,
}

// Css_Sel is one compound selector: any of its three parts may be empty, and
// an empty part matches anything.
Css_Sel :: struct {
	tag:   string,
	class: string,
	id:    string,
}

Css_Rule :: struct {
	sel:     Css_Sel, // the subject: the element the rule is about
	anc:     Css_Sel, // the nearest ancestor it requires, all-empty for none
	has_anc: bool,
	spec:    int,
	order:   int,
	decl:    Css_Decl,
}

Css :: struct {
	rules: [dynamic]Css_Rule,
	// Rules are kept grouped by tag so matching an element is a short scan
	// rather than a pass over a stylesheet with 400 rules in it.
	by_tag: map[string][dynamic]int,
	any:    [dynamic]int, // rules with no tag
	order:  int,
}

css_init :: proc(c: ^Css) {
	c^ = {}
	c.rules = make([dynamic]Css_Rule, 0, 64)
	c.by_tag = make(map[string][dynamic]int)
	c.any = make([dynamic]int, 0, 16)
}

css_destroy :: proc(c: ^Css) {
	for r in c.rules {
		delete(r.sel.tag)
		delete(r.sel.class)
		delete(r.sel.id)
		delete(r.anc.tag)
		delete(r.anc.class)
		delete(r.anc.id)
	}
	delete(c.rules)
	for k, v in c.by_tag {
		delete(k)
		delete(v)
	}
	delete(c.by_tag)
	delete(c.any)
	c^ = {}
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

css_parse :: proc(c: ^Css, src: string) {
	i := 0
	n := len(src)
	for i < n {
		// Skip comments and whitespace.
		if strings.has_prefix(src[i:], "/*") {
			e := strings.index(src[i + 2:], "*/")
			i = e < 0 ? n : i + 2 + e + 2
			continue
		}
		if src[i] <= ' ' {
			i += 1
			continue
		}
		// An at-rule: skip its block or its statement entirely. @media is the
		// common one and applying its contents unconditionally would be
		// worse than ignoring it.
		if src[i] == '@' {
			j := i
			depth := 0
			for j < n {
				if src[j] == '{' {
					depth += 1
				} else if src[j] == '}' {
					depth -= 1
					if depth == 0 {
						j += 1
						break
					}
				} else if src[j] == ';' && depth == 0 {
					j += 1
					break
				}
				j += 1
			}
			i = j
			continue
		}

		// selector list { declarations }
		ob := strings.index_byte(src[i:], '{')
		if ob < 0 {
			break
		}
		sel := src[i:i + ob]
		rest := i + ob + 1
		cb := strings.index_byte(src[rest:], '}')
		body := cb < 0 ? src[rest:] : src[rest:rest + cb]
		i = cb < 0 ? n : rest + cb + 1

		decl := css_parse_decl(body)
		if decl.has == {} {
			continue
		}
		for one in strings.split(sel, ",", context.temp_allocator) {
			css_add_selector(c, strings.trim_space(one), decl)
		}
	}
}

// css_add_selector records a selector as its subject compound plus, when there
// is one, the nearest ancestor compound it requires.
@(private = "file")
css_add_selector :: proc(c: ^Css, sel_in: string, decl: Css_Decl) {
	sel := strings.trim_space(sel_in)
	if sel == "" {
		return
	}
	// Normalise the combinators to spaces, then split. `>` is treated as a
	// descendant combinator: a child selector that matches a grandchild is a
	// smaller error than one that matches nothing.
	flat, _ := strings.replace_all(sel, ">", " ", context.temp_allocator)
	flat2, _ := strings.replace_all(flat, "+", " ", context.temp_allocator)
	flat3, _ := strings.replace_all(flat2, "~", " ", context.temp_allocator)
	parts := strings.fields(flat3, context.temp_allocator)
	if len(parts) == 0 {
		return
	}

	subject, sok := css_compound(parts[len(parts) - 1])
	if !sok {
		return
	}
	anc := Css_Sel{}
	has_anc := false
	if len(parts) >= 2 {
		if a, aok := css_compound(parts[len(parts) - 2]); aok && a != (Css_Sel{}) {
			anc = a
			has_anc = true
		}
	}

	spec := css_spec(subject)
	if has_anc {
		spec += css_spec(anc)
	}

	c.order += 1
	idx := len(c.rules)
	append(
		&c.rules,
		Css_Rule {
			sel = {
				tag = strings.clone(subject.tag),
				class = strings.clone(subject.class),
				id = strings.clone(subject.id),
			},
			anc = {
				tag = strings.clone(anc.tag),
				class = strings.clone(anc.class),
				id = strings.clone(anc.id),
			},
			has_anc = has_anc,
			spec = spec,
			order = c.order,
			decl = decl,
		},
	)
	if subject.tag == "" {
		append(&c.any, idx)
	} else {
		key := c.rules[idx].sel.tag
		if _, have := c.by_tag[key]; !have {
			c.by_tag[strings.clone(key)] = make([dynamic]int, 0, 4)
		}
		lst := &c.by_tag[key]
		append(lst, idx)
	}
}

// css_compound splits one compound selector into tag, class and id. A pseudo
// class or element is dropped, which makes `a:hover` behave as `a`.
css_compound :: proc(raw: string, allocator := context.temp_allocator) -> (Css_Sel, bool) {
	s := strings.trim_space(raw)
	if k := strings.index_byte(s, ':'); k > 0 {
		s = s[:k]
	} else if k == 0 {
		return {}, false // a bare pseudo-class like `:first-child`
	}
	if s == "" {
		return {}, false
	}
	if s == "*" {
		return {}, true
	}
	out := Css_Sel{}
	cut := len(s)
	for k in 0 ..< len(s) {
		if s[k] == '.' || s[k] == '#' || s[k] == '[' {
			cut = k
			break
		}
	}
	out.tag = strings.to_lower(s[:cut], allocator)
	rest := s[cut:]
	for len(rest) > 0 {
		mark := rest[0]
		rest = rest[1:]
		if mark == '[' {
			// An attribute selector is dropped, along with its contents.
			if k := strings.index_byte(rest, ']'); k >= 0 {
				rest = rest[k + 1:]
			} else {
				rest = ""
			}
			continue
		}
		cut = len(rest)
		for k in 0 ..< len(rest) {
			if rest[k] == '.' || rest[k] == '#' || rest[k] == '[' {
				cut = k
				break
			}
		}
		piece := rest[:cut]
		rest = rest[cut:]
		if mark == '.' {
			out.class = strings.to_lower(piece, allocator)
		} else {
			out.id = piece
		}
	}
	return out, true
}

css_spec :: proc(s: Css_Sel) -> int {
	n := 0
	if s.tag != "" {n += 1}
	if s.class != "" {n += 10}
	if s.id != "" {n += 100}
	return n
}

css_parse_decl :: proc(body: string) -> (d: Css_Decl) {
	for piece in strings.split(body, ";", context.temp_allocator) {
		colon := strings.index_byte(piece, ':')
		if colon < 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(piece[:colon]), context.temp_allocator)
		raw := strings.trim_space(piece[colon + 1:])
		// `!important` is recognised so it does not corrupt the value; it does
		// not raise priority.
		if k := strings.index(raw, "!"); k >= 0 {
			raw = strings.trim_space(raw[:k])
		}
		val := strings.to_lower(raw, context.temp_allocator)
		if val == "" {
			continue
		}

		switch name {
		case "font-weight":
			d.has += {.Weight}
			switch val {
			case "bold", "bolder", "600", "700", "800", "900":
				d.bold = true
			case:
				d.bold = false
			}
		case "font-style":
			d.has += {.Slant}
			d.italic = val == "italic" || val == "oblique"
		case "font-family":
			// Only one question is asked of a font stack: is it monospace.
			// Mapping a book's choice of serif onto the reader's installed
			// faces is a promise this program cannot keep.
			if strings.contains(val, "monospace") ||
			   strings.contains(val, "courier") ||
			   strings.contains(val, "consolas") ||
			   strings.contains(val, "mono") {
				d.has += {.Mono}
				d.mono = true
			}
		case "text-align":
			d.has += {.Align}
			switch val {
			case "center", "centre":
				d.align = .Center
			case "right", "end":
				d.align = .Right
			case "justify":
				d.align = .Justify
			case:
				d.align = .Left
			}
		case "text-decoration", "text-decoration-line":
			if strings.contains(val, "underline") {
				d.has += {.Underline}
				d.underline = true
			}
			if strings.contains(val, "line-through") {
				d.has += {.Strike}
				d.strike = true
			}
			if val == "none" {
				d.has += {.Underline, .Strike}
				d.underline = false
				d.strike = false
			}
		case "font-size":
			if m, ok := css_size(val); ok {
				d.has += {.Size}
				d.size = m
			}
		case "margin-top":
			if v, ok := css_len_em(val); ok {
				d.has += {.Margin_Top}
				d.margin_top = v
			}
		case "margin-bottom":
			if v, ok := css_len_em(val); ok {
				d.has += {.Margin_Bottom}
				d.margin_bot = v
			}
		case "margin":
			parts := strings.fields(val, context.temp_allocator)
			if len(parts) > 0 {
				if v, ok := css_len_em(parts[0]); ok {
					d.has += {.Margin_Top}
					d.margin_top = v
					bot := v
					if len(parts) >= 3 {
						if v2, ok2 := css_len_em(parts[2]); ok2 {
							bot = v2
						}
					}
					d.has += {.Margin_Bottom}
					d.margin_bot = bot
				}
			}
		case "text-indent":
			if v, ok := css_len_em(val); ok {
				d.has += {.Indent}
				d.indent = v
			}
		case "display":
			if val == "none" {
				d.has += {.Hidden}
				d.hidden = true
			}
		case "page-break-before", "break-before":
			if val == "always" || val == "page" || val == "left" || val == "right" {
				d.has += {.Break}
				d.brk = true
			}
		}
	}
	return d
}

// css_size turns a font-size into a multiplier on the inherited size.
css_size :: proc(val: string) -> (m: f32, ok: bool) {
	switch val {
	case "xx-small":
		return 0.6, true
	case "x-small":
		return 0.75, true
	case "small", "smaller":
		return 0.86, true
	case "medium":
		return 1, true
	case "large", "larger":
		return 1.15, true
	case "x-large":
		return 1.4, true
	case "xx-large":
		return 1.7, true
	case "inherit", "initial", "unset":
		return 1, true
	}
	if strings.has_suffix(val, "%") {
		if v, good := strconv.parse_f32(val[:len(val) - 1]); good && v > 0 {
			return clamp(v / 100, 0.3, 4), true
		}
		return 0, false
	}
	if strings.has_suffix(val, "em") || strings.has_suffix(val, "rem") {
		cut := strings.has_suffix(val, "rem") ? len(val) - 3 : len(val) - 2
		if v, good := strconv.parse_f32(val[:cut]); good && v > 0 {
			return clamp(v, 0.3, 4), true
		}
		return 0, false
	}
	// An absolute size is read as a ratio against a 12 pt / 16 px body, which
	// is the assumption the author was making when they typed it.
	if strings.has_suffix(val, "pt") {
		if v, good := strconv.parse_f32(val[:len(val) - 2]); good && v > 0 {
			return clamp(v / 12, 0.3, 4), true
		}
	}
	if strings.has_suffix(val, "px") {
		if v, good := strconv.parse_f32(val[:len(val) - 2]); good && v > 0 {
			return clamp(v / 16, 0.3, 4), true
		}
	}
	return 0, false
}

// css_len_em turns a length into ems. A pixel or point value is converted on
// the same 16 px / 12 pt body assumption.
css_len_em :: proc(val: string) -> (v: f32, ok: bool) {
	switch val {
	case "0", "auto", "inherit", "initial", "unset", "none":
		return 0, true
	}
	if strings.has_suffix(val, "em") || strings.has_suffix(val, "rem") {
		cut := strings.has_suffix(val, "rem") ? len(val) - 3 : len(val) - 2
		if f, good := strconv.parse_f32(val[:cut]); good {
			return clamp(f, -4, 8), true
		}
		return 0, false
	}
	if strings.has_suffix(val, "%") {
		if f, good := strconv.parse_f32(val[:len(val) - 1]); good {
			return clamp(f / 100, -4, 8), true
		}
		return 0, false
	}
	if strings.has_suffix(val, "px") {
		if f, good := strconv.parse_f32(val[:len(val) - 2]); good {
			return clamp(f / 16, -4, 8), true
		}
		return 0, false
	}
	if strings.has_suffix(val, "pt") {
		if f, good := strconv.parse_f32(val[:len(val) - 2]); good {
			return clamp(f / 12, -4, 8), true
		}
		return 0, false
	}
	if f, good := strconv.parse_f32(val); good {
		return clamp(f / 16, -4, 8), true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

// css_match collects every rule that applies to an element and folds them in
// specificity-then-source order, so a later, more specific rule wins. `anc` is
// the open element stack, innermost last, which is what makes a descendant
// selector mean something.
css_match :: proc(c: ^Css, tag, class, id: string, anc: []Css_Sel, out: ^Css_Decl) {
	if len(c.rules) == 0 {
		return
	}
	hits := make([dynamic]int, 0, 8, context.temp_allocator)
	consider :: proc(c: ^Css, idx: int, tag, class, id: string, anc: []Css_Sel, hits: ^[dynamic]int) {
		r := c.rules[idx]
		if !sel_matches(r.sel, tag, class, id) {
			return
		}
		if r.has_anc {
			found := false
			for a in anc {
				if sel_matches(r.anc, a.tag, a.class, a.id) {
					found = true
					break
				}
			}
			if !found {
				return
			}
		}
		append(hits, idx)
	}
	for idx in c.any {
		consider(c, idx, tag, class, id, anc, &hits)
	}
	if lst, have := c.by_tag[tag]; have {
		for idx in lst {
			consider(c, idx, tag, class, id, anc, &hits)
		}
	}
	if len(hits) == 0 {
		return
	}
	// Insertion sort: a handful of hits, so this beats a general sort and
	// allocates nothing.
	for i in 1 ..< len(hits) {
		j := i
		for j > 0 {
			a, b := c.rules[hits[j - 1]], c.rules[hits[j]]
			if a.spec > b.spec || (a.spec == b.spec && a.order > b.order) {
				hits[j - 1], hits[j] = hits[j], hits[j - 1]
				j -= 1
				continue
			}
			break
		}
	}
	for idx in hits {
		css_fold(out, c.rules[idx].decl)
	}
}

sel_matches :: proc(s: Css_Sel, tag, class, id: string) -> bool {
	if s.tag != "" && s.tag != tag {
		return false
	}
	if s.id != "" && s.id != id {
		return false
	}
	if s.class != "" && !class_has(class, s.class) {
		return false
	}
	return true
}

// css_fold applies `src` over `dst`, property by property.
css_fold :: proc(dst: ^Css_Decl, src: Css_Decl) {
	if .Weight in src.has {dst.bold = src.bold}
	if .Slant in src.has {dst.italic = src.italic}
	if .Mono in src.has {dst.mono = src.mono}
	if .Align in src.has {dst.align = src.align}
	if .Underline in src.has {dst.underline = src.underline}
	if .Strike in src.has {dst.strike = src.strike}
	if .Size in src.has {dst.size = src.size}
	if .Margin_Top in src.has {dst.margin_top = src.margin_top}
	if .Margin_Bottom in src.has {dst.margin_bot = src.margin_bot}
	if .Indent in src.has {dst.indent = src.indent}
	if .Hidden in src.has {dst.hidden = src.hidden}
	if .Break in src.has {dst.brk = src.brk}
	dst.has += src.has
}

class_has :: proc(attr, want: string) -> bool {
	if attr == "" || want == "" {
		return false
	}
	rest := attr
	for len(rest) > 0 {
		for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r') {
			rest = rest[1:]
		}
		cut := len(rest)
		for k in 0 ..< len(rest) {
			if rest[k] == ' ' || rest[k] == '\t' || rest[k] == '\n' || rest[k] == '\r' {
				cut = k
				break
			}
		}
		if strings.equal_fold(rest[:cut], want) {
			return true
		}
		rest = rest[cut:]
	}
	return false
}
