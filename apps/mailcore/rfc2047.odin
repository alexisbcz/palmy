package main

// RFC 2047 encoded words, RFC 2231 parameter continuations, and RFC 5322
// header unfolding. This is the layer where almost every mail client has a
// visible bug.

import "core:mem"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Header unfolding
// ---------------------------------------------------------------------------

// unfold_header joins a folded header value into one line. RFC 5322 3.2.2:
// the CRLF of a folding white space sequence is removed, the whitespace that
// follows it is kept (it was part of the value). Callers that want it tidy
// collapse runs afterwards.
unfold_header :: proc(v: string, allocator := context.allocator) -> string {
	if strings.index_byte(v, '\n') < 0 && strings.index_byte(v, '\r') < 0 {
		return strings.clone(v, allocator)
	}
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(v) {
		ch := v[i]
		if ch == '\r' || ch == '\n' {
			// Swallow the line break; keep whatever whitespace follows, but
			// make sure at least one space survives so tokens do not fuse.
			for i < len(v) && (v[i] == '\r' || v[i] == '\n') {
				i += 1
			}
			if i < len(v) && (v[i] == ' ' || v[i] == '\t') {
				continue // the WSP itself is written on the next pass
			}
			// A header line break with no continuation WSP is malformed
			// folding. Treat it as a space rather than fusing the words.
			strings.write_byte(&sb, ' ')
			continue
		}
		strings.write_byte(&sb, ch)
		i += 1
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// RFC 2047 encoded words
// ---------------------------------------------------------------------------

@(private = "file")
Seg_Kind :: enum u8 {
	Literal,
	Encoded,
}

@(private = "file")
Seg :: struct {
	kind:    Seg_Kind,
	text:    string, // Literal only
	raw:     []u8, // Encoded only: the bytes the word decoded to, untranscoded
	cs:      Charset,
	cs_name: string,
	ws_only: bool, // Literal only: nothing but linear whitespace
}

// decode_encoded_words decodes every `=?charset?B|Q?text?=` in a header value.
//
// Two things here are what separate a correct implementation from the common
// one.
//
// First, adjacent encoded words separated only by linear whitespace are
// concatenated and the whitespace between them is DISCARDED (RFC 2047 6.2).
// Whitespace between an encoded word and ordinary text, or between two
// ordinary words, is preserved.
//
// Second — and this is the part almost everyone gets wrong — a run of adjacent
// encoded words that share a charset has its *octets* joined before the
// charset is decoded, not after. RFC 2047 5 forbids splitting a multi-octet
// character across two words, but senders do it anyway, and a decoder that
// transcodes each word independently turns the split character into two or
// three U+FFFD. Joining the bytes first recovers it. Words with different
// charsets are of course decoded separately.
//
// A malformed word (no closing `?=`, unknown encoding, bad base64) is emitted
// verbatim, which is what every reasonable client does: show the user the
// gibberish rather than nothing.
decode_encoded_words :: proc(
	value: string,
	allocator := context.allocator,
) -> (
	out: string,
	lossy: bool,
) {
	if !strings.contains(value, "=?") {
		return strings.clone(value, allocator), false
	}

	segs := make([dynamic]Seg, 0, 8, context.temp_allocator)
	push_literal :: proc(segs: ^[dynamic]Seg, s: string) {
		if len(s) == 0 {
			return
		}
		append(segs, Seg{kind = .Literal, text = s, ws_only = strings.trim_space(s) == ""})
	}

	i := 0
	lit_start := 0
	for i < len(value) {
		if !(value[i] == '=' && i + 1 < len(value) && value[i + 1] == '?') {
			i += 1
			continue
		}
		// Candidate encoded word: =?charset?e?text?=
		rest := value[i + 2:]
		q1 := strings.index_byte(rest, '?')
		if q1 < 0 {
			i += 2
			continue
		}
		charset_name := rest[:q1]
		if q1 + 2 >= len(rest) || rest[q1 + 2] != '?' {
			i += 2
			continue
		}
		enc := rest[q1 + 1]
		body_start := q1 + 3
		end := strings.index(rest[body_start:], "?=")
		if end < 0 {
			i += 2
			continue
		}
		body := rest[body_start:body_start + end]
		total := 2 + body_start + end + 2 // from value[i]

		// An encoded word may not contain whitespace (RFC 2047 2). If it does,
		// this is not an encoded word; leave it literal.
		if strings.index_byte(body, ' ') >= 0 || strings.index_byte(body, '\t') >= 0 {
			i += 2
			continue
		}

		raw: []u8
		ok := true
		switch enc {
		case 'B', 'b':
			raw = base64_decode(transmute([]u8)body, context.temp_allocator)
		case 'Q', 'q':
			raw = qp_decode(transmute([]u8)body, true, context.temp_allocator)
		case:
			ok = false
		}
		if !ok {
			i += 2
			continue
		}

		push_literal(&segs, value[lit_start:i])
		append(
			&segs,
			Seg {
				kind = .Encoded,
				raw = raw,
				cs = charset_from_name(charset_name),
				cs_name = strings.clone(charset_name, context.temp_allocator),
			},
		)
		i += total
		lit_start = i
	}
	push_literal(&segs, value[lit_start:])

	sb := strings.builder_make(allocator)
	// `run` accumulates the octets of consecutive same-charset encoded words.
	run := make([dynamic]u8, 0, 64, context.temp_allocator)
	run_cs := Charset.Unknown
	run_open := false
	flush_run :: proc(
		sb: ^strings.Builder,
		run: ^[dynamic]u8,
		cs: Charset,
		open: ^bool,
		lossy: ^bool,
		allocator: mem.Allocator,
	) {
		if !open^ {
			return
		}
		txt, lo := charset_to_utf8(run[:], cs, allocator)
		if lo {
			lossy^ = true
		}
		strings.write_string(sb, txt)
		clear(run)
		open^ = false
	}

	for si := 0; si < len(segs); si += 1 {
		sg := segs[si]
		if sg.kind == .Encoded {
			if run_open && run_cs != sg.cs {
				flush_run(&sb, &run, run_cs, &run_open, &lossy, allocator)
			}
			run_cs = sg.cs
			run_open = true
			append(&run, ..sg.raw)
			continue
		}
		// A literal. Whitespace sitting purely between two encoded words is
		// dropped; anything else closes the run.
		if sg.ws_only && si > 0 && si + 1 < len(segs) &&
		   segs[si - 1].kind == .Encoded && segs[si + 1].kind == .Encoded {
			// If the charsets differ the run has to be flushed anyway, but the
			// whitespace is still dropped: the words were adjacent.
			continue
		}
		flush_run(&sb, &run, run_cs, &run_open, &lossy, allocator)
		strings.write_string(&sb, sg.text)
	}
	flush_run(&sb, &run, run_cs, &run_open, &lossy, allocator)
	return strings.to_string(sb), lossy
}

// ---------------------------------------------------------------------------
// Structured parameter lists: Content-Type / Content-Disposition
// ---------------------------------------------------------------------------

Param :: struct {
	name:  string, // lowercased, without the RFC 2231 section/star suffix
	value: string, // decoded UTF-8
}

@(private = "file")
Raw_Param :: struct {
	base:      string, // lowercased name without *N / *
	section:   int, // -1 when there is no continuation
	extended:  bool, // the name ended in '*': value is charset'lang'pct-encoded
	value:     string,
	was_quote: bool,
}

// parse_params splits `text/plain; charset="utf-8"; name=a.txt` into the first
// token and its parameters. It handles:
//
//   - quoted strings with backslash escapes;
//   - RFC 2231 continuations (`name*0`, `name*1`, ...) reassembled in order;
//   - RFC 2231 extended values (`name*=utf-8''%41%42`), percent-decoded and
//     transcoded from the named charset;
//   - RFC 2047 encoded words in a parameter value, which is illegal but
//     extremely common (Outlook does it), decoded anyway.
parse_params :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	head: string,
	params: []Param,
) {
	semi := index_unquoted(text, ';')
	if semi < 0 {
		return strings.clone(strings.trim_space(text), allocator), nil
	}
	head = strings.clone(strings.trim_space(text[:semi]), allocator)

	raws := make([dynamic]Raw_Param, 0, 8, context.temp_allocator)
	rest := text[semi + 1:]
	for len(rest) > 0 {
		nx := index_unquoted(rest, ';')
		chunk: string
		if nx < 0 {
			chunk = rest
			rest = ""
		} else {
			chunk = rest[:nx]
			rest = rest[nx + 1:]
		}
		chunk = strings.trim_space(chunk)
		if chunk == "" {
			continue
		}
		eq := index_unquoted(chunk, '=')
		if eq < 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(chunk[:eq]), context.temp_allocator)
		val := strings.trim_space(chunk[eq + 1:])
		quoted := false
		if len(val) >= 2 && val[0] == '"' {
			val = unquote(val, context.temp_allocator)
			quoted = true
		}

		rp := Raw_Param {
			base      = name,
			section   = -1,
			value     = val,
			was_quote = quoted,
		}
		if strings.has_suffix(name, "*") {
			rp.extended = true
			rp.base = name[:len(name) - 1]
		}
		if star := strings.last_index_byte(rp.base, '*'); star >= 0 {
			if n, nok := strconv.parse_int(rp.base[star + 1:], 10); nok {
				rp.section = n
				rp.base = rp.base[:star]
			}
		}
		append(&raws, rp)
	}

	out := make([dynamic]Param, 0, len(raws), allocator)
	seen := make(map[string]bool, 8, context.temp_allocator)
	for rp in raws {
		if seen[rp.base] {
			continue
		}
		seen[rp.base] = true

		// Gather every section of this parameter, in order.
		sb := strings.builder_make(context.temp_allocator)
		charset_name := ""
		any_extended := false
		if rp.section < 0 {
			// Single-shot parameter.
			if rp.extended {
				cs, body := split_ext_value(rp.value)
				charset_name = cs
				any_extended = true
				strings.write_bytes(&sb, pct_decode(body, context.temp_allocator))
			} else {
				strings.write_string(&sb, rp.value)
			}
		} else {
			for sec := 0; ; sec += 1 {
				found := false
				for r2 in raws {
					if r2.base != rp.base || r2.section != sec {
						continue
					}
					found = true
					if r2.extended {
						any_extended = true
						if sec == 0 {
							cs, body := split_ext_value(r2.value)
							charset_name = cs
							strings.write_bytes(&sb, pct_decode(body, context.temp_allocator))
						} else {
							strings.write_bytes(&sb, pct_decode(r2.value, context.temp_allocator))
						}
					} else {
						strings.write_string(&sb, r2.value)
					}
					break
				}
				if !found {
					break
				}
			}
		}

		joined := strings.to_string(sb)
		val: string
		if any_extended {
			val, _ = charset_to_utf8(transmute([]u8)joined, charset_from_name(charset_name), allocator)
		} else {
			// Not RFC 2231. It may still carry RFC 2047 encoded words.
			val, _ = decode_encoded_words(joined, allocator)
		}
		append(&out, Param{name = strings.clone(rp.base, allocator), value = val})
	}
	return head, out[:]
}

param_get :: proc(params: []Param, name: string) -> (string, bool) {
	for p in params {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

// split_ext_value splits an RFC 2231 extended value `charset'language'text`.
// A value with no quotes at all is treated as all text, which is what broken
// senders produce.
@(private = "file")
split_ext_value :: proc(v: string) -> (charset, body: string) {
	a := strings.index_byte(v, '\'')
	if a < 0 {
		return "", v
	}
	b := strings.index_byte(v[a + 1:], '\'')
	if b < 0 {
		return v[:a], v[a + 1:]
	}
	return v[:a], v[a + 1 + b + 1:]
}

@(private = "file")
pct_decode :: proc(s: string, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(s), allocator)
	for i := 0; i < len(s); {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok1 := hexval2(s[i + 1])
			lo, ok2 := hexval2(s[i + 2])
			if ok1 && ok2 {
				append(&out, hi << 4 | lo)
				i += 3
				continue
			}
		}
		append(&out, s[i])
		i += 1
	}
	return out[:]
}

hexval2 :: proc(ch: u8) -> (v: u8, ok: bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}

// index_unquoted finds `target` outside of any double-quoted string.
index_unquoted :: proc(s: string, target: u8) -> int {
	in_q := false
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '\\':
			if in_q {
				i += 1
			}
		case '"':
			in_q = !in_q
		case target:
			if !in_q {
				return i
			}
		}
	}
	return -1
}

unquote :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) < 2 || s[0] != '"' {
		return strings.clone(s, allocator)
	}
	sb := strings.builder_make(allocator)
	for i := 1; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			strings.write_byte(&sb, s[i])
			continue
		}
		if s[i] == '"' {
			break
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Address lists
// ---------------------------------------------------------------------------

Address :: struct {
	name:  string, // display name, encoded words decoded
	email: string, // addr-spec
}

// parse_address_list is deliberately modest: it splits on commas outside
// quotes, angle brackets and comments, then pulls `<addr>` out of each entry.
// Group syntax (`undisclosed-recipients:;`) yields the group name with no
// address, which is the useful thing to show.
parse_address_list :: proc(v: string, allocator := context.allocator) -> []Address {
	out := make([dynamic]Address, 0, 4, allocator)
	depth_angle, depth_paren := 0, 0
	in_q := false
	start := 0
	emit :: proc(out: ^[dynamic]Address, s: string, allocator: mem.Allocator) {
		a, ok := parse_one_address(s, allocator)
		if ok {
			append(out, a)
		}
	}
	for i := 0; i < len(v); i += 1 {
		switch v[i] {
		case '\\':
			if in_q {i += 1}
		case '"':
			in_q = !in_q
		case '<':
			if !in_q {depth_angle += 1}
		case '>':
			if !in_q && depth_angle > 0 {depth_angle -= 1}
		case '(':
			if !in_q {depth_paren += 1}
		case ')':
			if !in_q && depth_paren > 0 {depth_paren -= 1}
		case ',':
			if !in_q && depth_angle == 0 && depth_paren == 0 {
				emit(&out, v[start:i], allocator)
				start = i + 1
			}
		}
	}
	emit(&out, v[start:], allocator)
	return out[:]
}

parse_one_address :: proc(
	s: string,
	allocator := context.allocator,
) -> (
	addr: Address,
	ok: bool,
) {
	s := strings.trim_space(s)
	if s == "" {
		return {}, false
	}
	lt := strings.last_index_byte(s, '<')
	if lt >= 0 {
		gt := strings.index_byte(s[lt:], '>')
		if gt < 0 {
			addr.email = strings.clone(strings.trim_space(s[lt + 1:]), allocator)
		} else {
			addr.email = strings.clone(strings.trim_space(s[lt + 1:lt + gt]), allocator)
		}
		name := strings.trim_space(s[:lt])
		name = strings.trim_space(unquote_if_quoted(name, context.temp_allocator))
		addr.name, _ = decode_encoded_words(name, allocator)
		return addr, true
	}
	// No angle brackets: either a bare addr-spec or a group label.
	if strings.contains(s, "@") {
		addr.email = strings.clone(strings.trim_space(strip_comments(s, context.temp_allocator)), allocator)
		return addr, true
	}
	addr.name, _ = decode_encoded_words(strings.trim_right(s, ":; "), allocator)
	return addr, addr.name != ""
}

@(private = "file")
unquote_if_quoted :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) >= 2 && s[0] == '"' {
		return unquote(s, allocator)
	}
	return s
}

@(private = "file")
strip_comments :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '(') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	depth := 0
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '(':
			depth += 1
		case ')':
			if depth > 0 {depth -= 1}
		case:
			if depth == 0 {strings.write_byte(&sb, s[i])}
		}
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Encoding headers on the way out
// ---------------------------------------------------------------------------

// encode_header_value emits an RFC 2047 encoded word only when the value is
// not plain ASCII, which keeps ordinary mail readable in a raw file.
encode_header_value :: proc(v: string, allocator := context.allocator) -> string {
	ascii := true
	for i in 0 ..< len(v) {
		if v[i] >= 0x80 || v[i] == '\r' || v[i] == '\n' {
			ascii = false
			break
		}
	}
	if ascii {
		return strings.clone(v, allocator)
	}
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "=?UTF-8?B?")
	strings.write_string(&sb, base64_encode(transmute([]u8)v, 0, context.temp_allocator))
	strings.write_string(&sb, "?=")
	return strings.to_string(sb)
}
