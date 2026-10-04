#+feature dynamic-literals
// A tolerant XML/XHTML pull parser.
//
// Real books are not well-formed. This parser is written for what actually
// arrives: unclosed `<p>` and `<li>`, bare `<br>`, attributes without quotes,
// a BOM, `<![CDATA[...]]>`, HTML entities that are not XML entities, and a
// declared encoding that is a lie. It never fails — the worst case is that a
// malformed region comes through as text.
//
// It is a pull parser rather than a tree builder because the HTML reader wants
// to make block decisions as it goes, and because a tree of a 2 MB chapter is
// a lot of allocation for something read once.
package main

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Xml_Kind :: enum u8 {
	Eof,
	Text, // character data, entities already decoded
	Open, // <tag ...>
	Close, // </tag>
	Empty, // <tag ... />
	Decl, // <?...?>, <!DOCTYPE ...>, comments — reported so a caller can skip
}

Xml_Attr :: struct {
	name:  string, // lower-cased, namespace prefix kept
	value: string, // entities decoded
}

Xml_Token :: struct {
	kind:  Xml_Kind,
	name:  string, // lower-cased, namespace prefix stripped
	raw:   string, // the name as written, prefix included
	text:  string, // Text only
	attrs: []Xml_Attr,
}

Xml :: struct {
	src:   string,
	at:    int,
	// Decoded text and attribute values are copied here so a token's strings
	// stay valid for the parser's lifetime: one arena per document rather
	// than a clone per token.
	//
	// It is a fixed buffer, not a [dynamic], and that is the point. A slice
	// into a dynamic array dangles the moment the array grows, and every
	// token this parser hands out is such a slice. The buffer is instead
	// sized once from a bound the parser cannot exceed: every byte written
	// comes from a source byte, decoding an entity is never longer than the
	// reference that produced it, and the only thing written twice is an
	// element or attribute name (once lowered, once more as the value of a
	// valueless attribute). 2x the source plus slack covers it, and `pb`
	// refuses to write past the end rather than reallocating.
	pool:  []u8,
	n:     int,
	attrs: [dynamic]Xml_Attr,
}

xml_init :: proc(x: ^Xml, src: string) {
	x^ = {}
	x.src = xml_strip_bom(src)
	x.pool = make([]u8, 2 * len(x.src) + 4096)
	x.attrs = make([dynamic]Xml_Attr, 0, 8)
}

xml_destroy :: proc(x: ^Xml) {
	delete(x.pool)
	delete(x.attrs)
	x^ = {}
}

// pb appends one byte, and drops it if the arena is somehow full. Dropping a
// byte shows up as a missing character; growing the arena would show up as a
// use-after-free, so this is the safe failure.
@(private = "file")
pb :: proc(x: ^Xml, c: u8) {
	if x.n < len(x.pool) {
		x.pool[x.n] = c
		x.n += 1
	}
}

@(private = "file")
pbs :: proc(x: ^Xml, s: string) {
	for c in transmute([]u8)s {
		pb(x, c)
	}
}

xml_strip_bom :: proc(s: string) -> string {
	if len(s) >= 3 && s[0] == 0xef && s[1] == 0xbb && s[2] == 0xbf {
		return s[3:]
	}
	return s
}

@(private = "file")
pool_push :: proc(x: ^Xml, s: string) -> string {
	at := x.n
	pbs(x, s)
	return string(x.pool[at:x.n])
}

@(private = "file")
pool_begin :: proc(x: ^Xml) -> int {
	return x.n
}

@(private = "file")
pool_end :: proc(x: ^Xml, at: int) -> string {
	return string(x.pool[at:x.n])
}

@(private = "file")
is_name_byte :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ':', '-', '_', '.':
		return true
	}
	return c >= 0x80
}

@(private = "file")
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == 0x0b
}

// xml_next returns the next token. The strings in it live in the parser's
// arena and stay valid for the parser's lifetime.
xml_next :: proc(x: ^Xml) -> Xml_Token {
	n := len(x.src)
	if x.at >= n {
		return {kind = .Eof}
	}

	if x.src[x.at] != '<' {
		// Character data up to the next '<'. A lone '<' that cannot start a
		// tag is swallowed into the text by the loop below.
		start := pool_begin(x)
		for x.at < n {
			c := x.src[x.at]
			if c == '<' {
				// Only stop if this really opens something.
				if x.at + 1 < n {
					d := x.src[x.at + 1]
					if is_name_byte(d) || d == '/' || d == '!' || d == '?' {
						break
					}
				}
				pb(x, '<')
				x.at += 1
				continue
			}
			if c == '&' {
				consumed := xml_entity(x, x.src[x.at:])
				if consumed > 0 {
					x.at += consumed
					continue
				}
			}
			pb(x, c)
			x.at += 1
		}
		return {kind = .Text, text = pool_end(x, start)}
	}

	// <!-- comment -->, <![CDATA[ ... ]]>, <!DOCTYPE ...>, <?...?>
	if x.at + 1 < n {
		switch x.src[x.at + 1] {
		case '!':
			if strings.has_prefix(x.src[x.at:], "<!--") {
				end := strings.index(x.src[x.at + 4:], "-->")
				x.at = end < 0 ? n : x.at + 4 + end + 3
				return {kind = .Decl, name = "comment"}
			}
			if strings.has_prefix(x.src[x.at:], "<![CDATA[") {
				body := x.src[x.at + 9:]
				end := strings.index(body, "]]>")
				raw := end < 0 ? body : body[:end]
				x.at = end < 0 ? n : x.at + 9 + end + 3
				return {kind = .Text, text = pool_push(x, raw)}
			}
			// <!DOCTYPE ...>, possibly with an internal subset in [].
			depth := 0
			i := x.at + 2
			for i < n {
				if x.src[i] == '[' {depth += 1}
				if x.src[i] == ']' {depth -= 1}
				if x.src[i] == '>' && depth <= 0 {
					i += 1
					break
				}
				i += 1
			}
			x.at = i
			return {kind = .Decl, name = "doctype"}
		case '?':
			end := strings.index(x.src[x.at:], "?>")
			x.at = end < 0 ? n : x.at + end + 2
			return {kind = .Decl, name = "pi"}
		case '/':
			i := x.at + 2
			ns := i
			for i < n && is_name_byte(x.src[i]) {
				i += 1
			}
			raw := x.src[ns:i]
			for i < n && x.src[i] != '>' {
				i += 1
			}
			x.at = min(n, i + 1)
			return {kind = .Close, name = xml_local_lower(x, raw), raw = raw}
		}
	}

	// An open or empty element.
	i := x.at + 1
	ns := i
	for i < n && is_name_byte(x.src[i]) {
		i += 1
	}
	raw := x.src[ns:i]
	if len(raw) == 0 {
		// A '<' that led nowhere: emit it as text rather than looping.
		x.at += 1
		return {kind = .Text, text = pool_push(x, "<")}
	}

	clear(&x.attrs)
	empty := false
	for i < n {
		for i < n && is_space(x.src[i]) {
			i += 1
		}
		if i >= n {
			break
		}
		if x.src[i] == '>' {
			i += 1
			break
		}
		if x.src[i] == '/' {
			empty = true
			i += 1
			continue
		}
		if !is_name_byte(x.src[i]) {
			i += 1
			continue
		}
		as := i
		for i < n && is_name_byte(x.src[i]) {
			i += 1
		}
		aname := x.src[as:i]
		for i < n && is_space(x.src[i]) {
			i += 1
		}
		val := ""
		if i < n && x.src[i] == '=' {
			i += 1
			for i < n && is_space(x.src[i]) {
				i += 1
			}
			if i < n && (x.src[i] == '"' || x.src[i] == '\'') {
				q := x.src[i]
				i += 1
				vs := i
				for i < n && x.src[i] != q {
					i += 1
				}
				val = xml_decode(x, x.src[vs:min(i, n)])
				i = min(n, i + 1)
			} else {
				vs := i
				for i < n && !is_space(x.src[i]) && x.src[i] != '>' {
					i += 1
				}
				val = xml_decode(x, x.src[vs:i])
			}
		} else {
			// A valueless attribute, as in `<hr noshade>`.
			val = pool_push(x, aname)
		}
		append(&x.attrs, Xml_Attr{name = xml_lower(x, aname), value = val})
	}
	x.at = i

	return {
		kind = empty ? .Empty : .Open,
		name = xml_local_lower(x, raw),
		raw = raw,
		attrs = x.attrs[:],
	}
}

// xml_local_lower strips a namespace prefix and lower-cases what is left, so
// `<dc:title>`, `<DC:Title>` and `<title>` are all "title".
@(private = "file")
xml_local_lower :: proc(x: ^Xml, raw: string) -> string {
	s := raw
	if i := strings.last_index_byte(s, ':'); i >= 0 {
		s = s[i + 1:]
	}
	return xml_lower(x, s)
}

@(private = "file")
xml_lower :: proc(x: ^Xml, s: string) -> string {
	start := pool_begin(x)
	for c in transmute([]u8)s {
		pb(x, c >= 'A' && c <= 'Z' ? c + 32 : c)
	}
	return pool_end(x, start)
}

@(private = "file")
xml_decode :: proc(x: ^Xml, s: string) -> string {
	start := pool_begin(x)
	i := 0
	for i < len(s) {
		if s[i] == '&' {
			if k := xml_entity(x, s[i:]); k > 0 {
				i += k
				continue
			}
		}
		pb(x, s[i])
		i += 1
	}
	return pool_end(x, start)
}

// xml_entity appends the expansion of the reference at the head of `s` and
// returns how many source bytes it consumed, or 0 when this is not a
// recognisable entity (a bare `&`, which books contain).
@(private = "file")
xml_entity :: proc(x: ^Xml, s: string) -> int {
	if len(s) < 3 || s[0] != '&' {
		return 0
	}
	semi := -1
	for i in 1 ..< min(len(s), 34) {
		if s[i] == ';' {
			semi = i
			break
		}
		if is_space(s[i]) || s[i] == '&' || s[i] == '<' {
			break
		}
	}
	if semi < 0 {
		return 0
	}
	body := s[1:semi]
	if len(body) == 0 {
		return 0
	}

	if body[0] == '#' {
		cp := 0
		ok := false
		if len(body) > 2 && (body[1] == 'x' || body[1] == 'X') {
			v, good := strconv.parse_u64_of_base(body[2:], 16)
			cp, ok = int(v), good
		} else {
			v, good := strconv.parse_u64_of_base(body[1:], 10)
			cp, ok = int(v), good
		}
		if !ok || cp <= 0 || cp > 0x10ffff {
			return 0
		}
		buf, w := utf8.encode_rune(rune(cp))
		pbs(x, string(buf[:w]))
		return semi + 1
	}

	if rep, found := XML_ENTITIES[body]; found {
		pbs(x, rep)
		return semi + 1
	}
	return 0
}

// The entity set books actually use. XHTML nominally requires a DTD for all of
// these; nothing here reads DTDs, so the table is the DTD. Anything missing
// falls through as literal text rather than vanishing.
XML_ENTITIES := map[string]string {
	"amp"    = "&",
	"lt"     = "<",
	"gt"     = ">",
	"quot"   = "\"",
	"apos"   = "'",
	"nbsp"   = " ",
	"ensp"   = " ",
	"emsp"   = " ",
	"thinsp" = " ",
	"shy"    = "­",
	"ndash"  = "–",
	"mdash"  = "—",
	"horbar" = "―",
	"lsquo"  = "‘",
	"rsquo"  = "’",
	"sbquo"  = "‚",
	"ldquo"  = "“",
	"rdquo"  = "”",
	"bdquo"  = "„",
	"dagger" = "†",
	"Dagger" = "‡",
	"bull"   = "•",
	"hellip" = "…",
	"prime"  = "′",
	"Prime"  = "″",
	"lsaquo" = "‹",
	"rsaquo" = "›",
	"oline"  = "‾",
	"frasl"  = "⁄",
	"euro"   = "€",
	"trade"  = "™",
	"copy"   = "©",
	"reg"    = "®",
	"deg"    = "°",
	"plusmn" = "±",
	"sup2"   = "²",
	"sup3"   = "³",
	"micro"  = "µ",
	"para"   = "¶",
	"middot" = "·",
	"frac14" = "¼",
	"frac12" = "½",
	"frac34" = "¾",
	"iquest" = "¿",
	"iexcl"  = "¡",
	"cent"   = "¢",
	"pound"  = "£",
	"curren" = "¤",
	"yen"    = "¥",
	"sect"   = "§",
	"uml"    = "¨",
	"ordf"   = "ª",
	"laquo"  = "«",
	"not"    = "¬",
	"macr"   = "¯",
	"acute"  = "´",
	"cedil"  = "¸",
	"ordm"   = "º",
	"raquo"  = "»",
	"times"  = "×",
	"divide" = "÷",
	"szlig"  = "ß",
	"agrave" = "à",
	"aacute" = "á",
	"acirc"  = "â",
	"atilde" = "ã",
	"auml"   = "ä",
	"aring"  = "å",
	"aelig"  = "æ",
	"ccedil" = "ç",
	"egrave" = "è",
	"eacute" = "é",
	"ecirc"  = "ê",
	"euml"   = "ë",
	"igrave" = "ì",
	"iacute" = "í",
	"icirc"  = "î",
	"iuml"   = "ï",
	"ntilde" = "ñ",
	"ograve" = "ò",
	"oacute" = "ó",
	"ocirc"  = "ô",
	"otilde" = "õ",
	"ouml"   = "ö",
	"oslash" = "ø",
	"ugrave" = "ù",
	"uacute" = "ú",
	"ucirc"  = "û",
	"uuml"   = "ü",
	"yacute" = "ý",
	"yuml"   = "ÿ",
	"Agrave" = "À",
	"Aacute" = "Á",
	"Acirc"  = "Â",
	"Atilde" = "Ã",
	"Auml"   = "Ä",
	"Aring"  = "Å",
	"AElig"  = "Æ",
	"Ccedil" = "Ç",
	"Egrave" = "È",
	"Eacute" = "É",
	"Ecirc"  = "Ê",
	"Euml"   = "Ë",
	"Igrave" = "Ì",
	"Iacute" = "Í",
	"Icirc"  = "Î",
	"Iuml"   = "Ï",
	"Ntilde" = "Ñ",
	"Ograve" = "Ò",
	"Oacute" = "Ó",
	"Ocirc"  = "Ô",
	"Otilde" = "Õ",
	"Ouml"   = "Ö",
	"Oslash" = "Ø",
	"Ugrave" = "Ù",
	"Uacute" = "Ú",
	"Ucirc"  = "Û",
	"Uuml"   = "Ü",
	"Yacute" = "Ý",
	"alpha"  = "α",
	"beta"   = "β",
	"gamma"  = "γ",
	"delta"  = "δ",
	"pi"     = "π",
	"sigma"  = "σ",
	"omega"  = "ω",
	"Omega"  = "Ω",
	"larr"   = "←",
	"uarr"   = "↑",
	"rarr"   = "→",
	"darr"   = "↓",
	"harr"   = "↔",
	"minus"  = "−",
	"ne"     = "≠",
	"le"     = "≤",
	"ge"     = "≥",
	"infin"  = "∞",
	"radic"  = "√",
	"asymp"  = "≈",
	"equiv"  = "≡",
	"sum"    = "∑",
	"prod"   = "∏",
	"int"    = "∫",
	"part"   = "∂",
	"nabla"  = "∇",
	"isin"   = "∈",
	"notin"  = "∉",
	"cap"    = "∩",
	"cup"    = "∪",
	"sub"    = "⊂",
	"sup"    = "⊃",
	"and"    = "∧",
	"or"     = "∨",
	"there4" = "∴",
	"loz"    = "◊",
	"spades" = "♠",
	"clubs"  = "♣",
	"hearts" = "♥",
	"diams"  = "♦",
	"zwj"    = "‍",
	"zwnj"   = "‌",
	"lrm"    = "‎",
	"rlm"    = "‏",
}

// xml_attr looks up an attribute by lower-cased name. Namespace prefixes are
// kept on attributes, so both "href" and "xlink:href" are asked for by name.
xml_attr :: proc(t: Xml_Token, name: string) -> (string, bool) {
	for a in t.attrs {
		if a.name == name {
			return a.value, true
		}
	}
	// Try the local part, so xlink:href answers for href.
	for a in t.attrs {
		if i := strings.last_index_byte(a.name, ':'); i >= 0 && a.name[i + 1:] == name {
			return a.value, true
		}
	}
	return "", false
}

xml_attr_or :: proc(t: Xml_Token, name, fallback: string) -> string {
	if v, ok := xml_attr(t, name); ok {
		return v
	}
	return fallback
}
