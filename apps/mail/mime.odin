// RFC 5322 and MIME, enough of it to read a mailbox honestly.
//
// This is a reader, not a mail library: it parses headers, unfolds them,
// decodes RFC 2047 encoded words, walks a MIME tree, decodes base64 and
// quoted-printable, and reduces text/html to readable text. It never opens a
// socket and never resolves an external reference — see html_to_text, where
// every `src` is deliberately dropped on the floor.
package main

import "core:fmt"
import "core:strconv"
import "core:mem"
import "core:strings"
import "core:time"

import "../../cloud/mail/readable"

// Allocator is spelled out so the MIME walk can take one explicitly.
Allocator :: mem.Allocator

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

Header :: struct {
	name:  string, // as written
	lower: string, // folded, for lookup
	value: string, // unfolded, leading space trimmed
}

// split_message finds the header/body boundary. A message is headers, a blank
// line, then the body; a file with no blank line at all is all headers.
split_message :: proc(raw: string) -> (head: string, body: string) {
	// A MIME part may carry no headers at all, in which case it opens with the
	// blank line that would otherwise separate them.
	if strings.has_prefix(raw, "\r\n") {
		return "", raw[2:]
	}
	if strings.has_prefix(raw, "\n") {
		return "", raw[1:]
	}
	if i := strings.index(raw, "\r\n\r\n"); i >= 0 {
		return raw[:i + 2], raw[i + 4:]
	}
	if i := strings.index(raw, "\n\n"); i >= 0 {
		return raw[:i + 1], raw[i + 2:]
	}
	return raw, ""
}

// parse_headers unfolds the header block. A continuation line starts with
// space or tab and belongs to the field above it; the fold is replaced by a
// single space, which is what every reader does.
parse_headers :: proc(head: string, allocator := context.allocator) -> []Header {
	out := make([dynamic]Header, 0, 16, allocator)
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	name, lower := "", ""
	rest := head
	for {
		line, more := next_line(&rest)
		if !more {
			break
		}
		l := strings.trim_right(line, "\r")
		if l == "" {
			continue
		}
		if l[0] == ' ' || l[0] == '\t' {
			if name != "" {
				strings.write_byte(&b, ' ')
				strings.write_string(&b, strings.trim_space(l))
			}
			continue
		}
		colon := strings.index_byte(l, ':')
		if colon < 0 {
			continue
		}
		if name != "" {
			append(&out, Header{name, lower, strings.clone(strings.trim_space(strings.to_string(b)), allocator)})
		}
		strings.builder_reset(&b)
		name = strings.clone(strings.trim_space(l[:colon]), allocator)
		lower = strings.to_lower(name, allocator)
		strings.write_string(&b, strings.trim_space(l[colon + 1:]))
	}
	if name != "" {
		append(&out, Header{name, lower, strings.clone(strings.trim_space(strings.to_string(b)), allocator)})
	}
	return out[:]
}

// next_line is `split_lines_iterator` over a value rather than a pointer to a
// parameter, which Odin will not let a procedure take.
next_line :: proc(rest: ^string) -> (line: string, more: bool) {
	if len(rest^) == 0 {
		return "", false
	}
	if nl := strings.index_byte(rest^, '\n'); nl >= 0 {
		line = rest^[:nl]
		rest^ = rest^[nl + 1:]
		return line, true
	}
	line = rest^
	rest^ = ""
	return line, true
}


header_of :: proc(hs: []Header, name: string) -> string {
	for h in hs {
		if h.lower == name {
			return h.value
		}
	}
	return ""
}

headers_of :: proc(hs: []Header, name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 2, allocator)
	for h in hs {
		if h.lower == name {
			append(&out, h.value)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Transfer decoding
// ---------------------------------------------------------------------------

@(private = "file")
B64_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

@(private = "file")
b64_val: [256]i8

@(private = "file")
b64_ready := false

b64_lookup :: proc(c: u8) -> i8 {
	if !b64_ready {
		for i in 0 ..< 256 {
			b64_val[i] = -1
		}
		for i in 0 ..< len(B64_ALPHABET) {
			b64_val[B64_ALPHABET[i]] = i8(i)
		}
		b64_ready = true
	}
	return b64_val[c]
}

// encode_base64 is what the composer needs when it writes an attachment or a
// non-ASCII header; the body itself is written 8-bit UTF-8.
encode_base64 :: proc(data: []u8, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i + 2 < len(data) {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		strings.write_byte(&b, B64_ALPHABET[v >> 18 & 63])
		strings.write_byte(&b, B64_ALPHABET[v >> 12 & 63])
		strings.write_byte(&b, B64_ALPHABET[v >> 6 & 63])
		strings.write_byte(&b, B64_ALPHABET[v & 63])
		i += 3
	}
	switch len(data) - i {
	case 1:
		v := u32(data[i]) << 16
		strings.write_byte(&b, B64_ALPHABET[v >> 18 & 63])
		strings.write_byte(&b, B64_ALPHABET[v >> 12 & 63])
		strings.write_string(&b, "==")
	case 2:
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		strings.write_byte(&b, B64_ALPHABET[v >> 18 & 63])
		strings.write_byte(&b, B64_ALPHABET[v >> 12 & 63])
		strings.write_byte(&b, B64_ALPHABET[v >> 6 & 63])
		strings.write_byte(&b, '=')
	}
	return strings.to_string(b)
}

// decode_base64 skips anything that is not an alphabet character, which is how
// a transport-encoded body with hard line breaks has to be read.
decode_base64 :: proc(s: string, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(s) * 3 / 4 + 3, allocator)
	acc: u32 = 0
	bits := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '=' {
			break
		}
		v := b64_lookup(c)
		if v < 0 {
			continue
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&out, u8(acc >> uint(bits) & 0xff))
		}
	}
	return out[:]
}

hexval :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// decode_qp decodes quoted-printable. In header mode (`underscore`) a `_`
// stands for a space, which is RFC 2047's Q encoding rather than RFC 2045's.
decode_qp :: proc(s: string, underscore := false, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '=' && i + 1 < len(s) && (s[i + 1] == '\n' || s[i + 1] == '\r'):
			// A soft line break: the = and the newline both vanish.
			i += 1
			if i < len(s) && s[i] == '\r' {
				i += 1
			}
			if i < len(s) && s[i] == '\n' {
				i += 1
			}
		case c == '=' && i + 2 < len(s):
			hi, lo := hexval(s[i + 1]), hexval(s[i + 2])
			if hi >= 0 && lo >= 0 {
				append(&out, u8(hi * 16 + lo))
				i += 3
			} else {
				append(&out, c)
				i += 1
			}
		case c == '_' && underscore:
			append(&out, ' ')
			i += 1
		case:
			append(&out, c)
			i += 1
		}
	}
	return out[:]
}

// latin1_to_utf8 widens an ISO-8859-1 body. Without it an accented name from a
// legacy sender renders as a replacement box.
latin1_to_utf8 :: proc(b: []u8, allocator := context.allocator) -> string {
	need := false
	for c in b {
		if c >= 0x80 {
			need = true
			break
		}
	}
	if !need {
		return strings.clone(string(b), allocator)
	}
	out := make([dynamic]u8, 0, len(b) * 2, allocator)
	for c in b {
		if c < 0x80 {
			append(&out, c)
		} else {
			append(&out, 0xc0 | c >> 6, 0x80 | c & 0x3f)
		}
	}
	return string(out[:])
}

charset_to_utf8 :: proc(b: []u8, charset: string, allocator := context.allocator) -> string {
	cs := strings.to_lower(charset, context.temp_allocator)
	switch {
	case cs == "" || cs == "utf-8" || cs == "utf8" || cs == "us-ascii" || cs == "ascii":
		return strings.clone(string(b), allocator)
	case strings.has_prefix(cs, "iso-8859") || cs == "latin1" || strings.has_prefix(cs, "windows-12"):
		return latin1_to_utf8(b, allocator)
	}
	// Anything else is passed through: mangled text is more useful than none,
	// and the reader says which charset it was.
	return strings.clone(string(b), allocator)
}

// ---------------------------------------------------------------------------
// RFC 2047 encoded words
// ---------------------------------------------------------------------------

// decode_encoded_words turns `=?utf-8?B?...?=` runs inside a header into text.
// Adjacent encoded words separated only by whitespace join without the space,
// as the RFC requires, so a split multi-byte name reassembles.
decode_encoded_words :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, "=?") {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	last_was_word := false
	for i < len(s) {
		if s[i] == '=' && i + 1 < len(s) && s[i + 1] == '?' {
			// =?charset?enc?text?=
			rest := s[i + 2:]
			q1 := strings.index_byte(rest, '?')
			if q1 > 0 && q1 + 2 < len(rest) && rest[q1 + 2] == '?' {
				charset := rest[:q1]
				enc := rest[q1 + 1]
				tail := rest[q1 + 3:]
				end := strings.index(tail, "?=")
				if end >= 0 {
					payload := tail[:end]
					raw: []u8
					switch enc {
					case 'B', 'b':
						raw = decode_base64(payload, context.temp_allocator)
					case 'Q', 'q':
						raw = decode_qp(payload, true, context.temp_allocator)
					case:
						raw = transmute([]u8)payload
					}
					strings.write_string(&b, charset_to_utf8(raw, charset, context.temp_allocator))
					i += 2 + q1 + 3 + end + 2
					last_was_word = true
					continue
				}
			}
		}
		// Whitespace between two encoded words is not part of the text.
		if last_was_word && (s[i] == ' ' || s[i] == '\t') {
			j := i
			for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
				j += 1
			}
			if j + 1 < len(s) && s[j] == '=' && s[j + 1] == '?' {
				i = j
				continue
			}
		}
		strings.write_byte(&b, s[i])
		last_was_word = false
		i += 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

Address :: struct {
	name:  string, // display name, decoded; "" when there was none
	email: string,
}

// addr_label is what a message list shows: the name if there is one, else the
// local part of the address, which is still better than the whole thing.
addr_label :: proc(a: Address) -> string {
	if a.name != "" {
		return a.name
	}
	if at := strings.index_byte(a.email, '@'); at > 0 {
		return a.email[:at]
	}
	return a.email
}

// parse_addresses splits an address list on commas that are not inside a
// quoted string or an angle-addr, then pulls each one apart.
parse_addresses :: proc(s: string, allocator := context.allocator) -> []Address {
	out := make([dynamic]Address, 0, 4, allocator)
	depth_angle, in_quote := 0, false
	start := 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '"':
			if !(i > 0 && s[i - 1] == '\\') {
				in_quote = !in_quote
			}
		case '<':
			if !in_quote {
				depth_angle += 1
			}
		case '>':
			if !in_quote && depth_angle > 0 {
				depth_angle -= 1
			}
		case ',':
			if !in_quote && depth_angle == 0 {
				if t := strings.trim_space(s[start:i]); t != "" {
					append(&out, parse_address(t, allocator))
				}
				start = i + 1
			}
		}
	}
	if t := strings.trim_space(s[start:]); t != "" {
		append(&out, parse_address(t, allocator))
	}
	return out[:]
}

parse_address :: proc(s: string, allocator := context.allocator) -> Address {
	t := strings.trim_space(s)
	if lt := strings.last_index_byte(t, '<'); lt >= 0 {
		gt := strings.index_byte(t[lt:], '>')
		email := gt > 0 ? t[lt + 1:lt + gt] : t[lt + 1:]
		name := strings.trim_space(t[:lt])
		name = strings.trim(name, "\"")
		name = strings.trim_space(name)
		return Address {
			name = decode_encoded_words(name, allocator),
			email = strings.clone(strings.trim_space(email), allocator),
		}
	}
	// A bare address, possibly with a trailing (comment) form of display name.
	if op := strings.index_byte(t, '('); op > 0 && strings.has_suffix(t, ")") {
		return Address {
			name = decode_encoded_words(strings.trim_space(t[op + 1:len(t) - 1]), allocator),
			email = strings.clone(strings.trim_space(t[:op]), allocator),
		}
	}
	return Address{name = "", email = strings.clone(t, allocator)}
}

format_address :: proc(a: Address, allocator := context.allocator) -> string {
	if a.name == "" {
		return strings.clone(a.email, allocator)
	}
	return fmt.aprintf("%s <%s>", a.name, a.email, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Content-Type and other structured headers
// ---------------------------------------------------------------------------

Content_Type :: struct {
	kind:     string, // "text"
	sub:      string, // "plain"
	charset:  string,
	boundary: string,
	name:     string, // the `name=` parameter, for an attachment part
}

content_type_full :: proc(ct: Content_Type, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s", ct.kind, ct.sub, allocator = allocator)
}

// parse_content_type reads `type/subtype; p=v; p="v"`. Parameter values may be
// quoted and may contain semicolons, so the scan is character by character.
parse_content_type :: proc(s: string, allocator := context.allocator) -> Content_Type {
	ct := Content_Type {
		kind    = "text",
		sub     = "plain",
		charset = "",
	}
	if strings.trim_space(s) == "" {
		return ct
	}
	semi := param_split(s, context.temp_allocator)
	mime := strings.to_lower(strings.trim_space(semi[0]), allocator)
	if slash := strings.index_byte(mime, '/'); slash > 0 {
		ct.kind = mime[:slash]
		ct.sub = mime[slash + 1:]
	} else if mime != "" {
		ct.kind = mime
		ct.sub = ""
	}
	for pv in semi[1:] {
		k, v, ok := param_kv(pv)
		if !ok {
			continue
		}
		switch strings.to_lower(k, context.temp_allocator) {
		case "charset":
			ct.charset = strings.clone(v, allocator)
		case "boundary":
			ct.boundary = strings.clone(v, allocator)
		case "name":
			ct.name = decode_encoded_words(v, allocator)
		}
	}
	return ct
}

// param_split splits on semicolons outside quotes.
param_split :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	in_quote := false
	start := 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '"':
			if !(i > 0 && s[i - 1] == '\\') {
				in_quote = !in_quote
			}
		case ';':
			if !in_quote {
				append(&out, s[start:i])
				start = i + 1
			}
		}
	}
	append(&out, s[start:])
	return out[:]
}

param_kv :: proc(s: string) -> (key, value: string, ok: bool) {
	t := strings.trim_space(s)
	eq := strings.index_byte(t, '=')
	if eq <= 0 {
		return "", "", false
	}
	k := strings.trim_space(t[:eq])
	v := strings.trim_space(t[eq + 1:])
	if len(v) >= 2 && v[0] == '"' {
		if close := strings.index_byte(v[1:], '"'); close >= 0 {
			v = v[1:1 + close]
		} else {
			v = v[1:]
		}
	}
	return k, v, true
}

// ---------------------------------------------------------------------------
// The MIME tree
// ---------------------------------------------------------------------------

Attachment :: struct {
	name:       string, // sanitised: safe to use as a file name, never a path
	mime:       string,
	size:       int, // decoded size in bytes
	inline_cid: string,

	// The IMAP section number of the part these bytes came from: "" for a
	// single-part message, "2" for the second part of a multipart, "2.1" for
	// the first part inside that. This is the handle `part_bytes` takes, and
	// it is why the decoded bytes do not have to be held in memory for every
	// message in the mailbox.
	section:    string,

	// An inline part the message itself points at — an image a `cid:` URL in
	// the HTML refers to. Those belong to the rendering of the message, not to
	// the list of files the reader is offered to save.
	is_inline:  bool,
}

Body_Result :: struct {
	text:        string, // the readable body, always plain text
	from_html:   bool, // true when it came out of the HTML fallback
	had_plain:   bool,
	had_html:    bool,
	// Both parts present and saying different things (cloud/mail/readable).
	// This reader shows the plain part; other readers, and the assistant,
	// show the HTML one, so the reader says so.
	parts_differ: bool,
	attachments: []Attachment,
}

MAX_MIME_DEPTH :: 12

// extract_body walks a part and produces the one readable text the reader
// shows, preferring text/plain exactly as the brief requires.
//
// Attachments are recorded by name, type, decoded size and *section number*.
// Their bytes are deliberately not kept: a few hundred messages carrying
// attachments is tens of megabytes that the reader needs none of until someone
// asks to save one, and `part_bytes` can fetch them again from the file on
// disk in microseconds.
extract_body :: proc(head, body: string, allocator := context.allocator) -> Body_Result {
	hs := parse_headers(head, context.temp_allocator)
	atts := make([dynamic]Attachment, 0, 4, allocator)
	plain := strings.builder_make(context.temp_allocator)
	html := strings.builder_make(context.temp_allocator)
	cids := make([dynamic]string, 0, 4, context.temp_allocator)

	walk_part(hs, body, &plain, &html, &atts, &cids, "", 0, allocator)

	// Inline is decided here rather than inside the walk, because the HTML
	// part that references an image can appear after the image part does.
	for &at in atts {
		if at.inline_cid == "" {
			continue
		}
		for c in cids {
			if c == at.inline_cid {
				at.is_inline = true
				break
			}
		}
	}

	res := Body_Result{attachments = atts[:]}
	pt := strings.trim_space(strings.to_string(plain))
	ht := strings.trim_space(strings.to_string(html))
	res.had_plain = pt != ""
	res.had_html = ht != ""
	if pt != "" && ht != "" {
		res.parts_differ = readable.of(pt, ht, context.temp_allocator).differ
	}
	if pt != "" {
		res.text = strings.clone(pt, allocator)
	} else if ht != "" {
		res.text = html_to_text(ht, allocator)
		res.from_html = true
	} else {
		res.text = strings.clone("", allocator)
	}
	return res
}

@(private = "file")
walk_part :: proc(
	hs: []Header,
	body: string,
	plain, html: ^strings.Builder,
	atts: ^[dynamic]Attachment,
	cids: ^[dynamic]string,
	section: string,
	depth: int,
	allocator: Allocator,
) {
	if depth > MAX_MIME_DEPTH {
		return
	}
	ct := parse_content_type(header_of(hs, "content-type"), context.temp_allocator)
	cte := strings.to_lower(strings.trim_space(header_of(hs, "content-transfer-encoding")), context.temp_allocator)
	disp_raw := header_of(hs, "content-disposition")
	disp_parts := param_split(disp_raw, context.temp_allocator)
	disposition := strings.to_lower(strings.trim_space(disp_parts[0]), context.temp_allocator)
	filename := ct.name
	for pv in disp_parts[1:] {
		if k, v, ok := param_kv(pv); ok && strings.to_lower(k, context.temp_allocator) == "filename" {
			filename = decode_encoded_words(v, allocator)
		}
	}

	if ct.kind == "multipart" {
		if ct.boundary == "" {
			return
		}
		for sub, i in split_multipart(body, ct.boundary, context.temp_allocator) {
			sh, sb := split_message(sub)
			shs := parse_headers(sh, context.temp_allocator)
			walk_part(shs, sb, plain, html, atts, cids, child_section(section, i + 1), depth + 1, allocator)
			// alternative: the last readable representation wins per part, and
			// the plain/html preference is resolved by the caller, so nothing
			// special is needed here.
		}
		return
	}

	if ct.kind == "message" && ct.sub == "rfc822" {
		// RFC 3501 numbers an embedded message's body at the same section as
		// the part that carries it, so the section does not change here.
		// `part_bytes` steps through an rfc822 wrapper the same way.
		inner := decode_part(hs, body, context.temp_allocator)
		sh, sb := split_message(string(inner))
		shs := parse_headers(sh, context.temp_allocator)
		walk_part(shs, sb, plain, html, atts, cids, section, depth + 1, allocator)
		return
	}

	decoded := decode_part(hs, body, context.temp_allocator)

	is_attachment := disposition == "attachment" || (filename != "" && ct.kind != "text")
	if is_attachment || ct.kind != "text" {
		// A non-text part with no disposition is still something the user
		// should see is there.
		cid := strings.trim(header_of(hs, "content-id"), "<> ")
		// A filename out of a message is hostile input. Every directory
		// component goes, here, once, so that `Attachment.name` is a name and
		// never a path from this point on.
		name := sanitise_filename(filename, context.temp_allocator)
		if name == "" {
			name = fmt.tprintf(
				"part%s%s",
				section == "" ? "" : fmt.tprintf("-%s", section),
				mime_extension(content_type_full(ct, context.temp_allocator)),
			)
		}
		append(
			atts,
			Attachment {
				name = strings.clone(name, allocator),
				mime = content_type_full(ct, allocator),
				size = len(decoded),
				inline_cid = strings.clone(cid, allocator),
				section = strings.clone(section, allocator),
			},
		)
		return
	}

	text := charset_to_utf8(decoded, ct.charset, context.temp_allocator)
	// A `cid:` URL only ever appears in HTML, and html_to_text drops every
	// attribute, so the references have to be collected from the source while
	// it is still here.
	if ct.sub == "html" {
		collect_cids(text, cids)
	}
	target := ct.sub == "html" ? html : plain
	if strings.builder_len(target^) > 0 {
		strings.write_string(target, "\n\n")
	}
	strings.write_string(target, text)
}

// child_section numbers a multipart's children the way IMAP does: 1-based,
// dotted, with the root carrying no number at all.
child_section :: proc(parent: string, n: int, allocator := context.temp_allocator) -> string {
	if parent == "" {
		return fmt.aprintf("%d", n, allocator = allocator)
	}
	return fmt.aprintf("%s.%d", parent, n, allocator = allocator)
}

// decode_part applies a part's Content-Transfer-Encoding. The result aliases
// `body` for the identity encodings, so a caller that needs to own the bytes
// copies them — which is what `part_bytes` does.
decode_part :: proc(hs: []Header, body: string, allocator := context.allocator) -> []u8 {
	switch strings.to_lower(
		strings.trim_space(header_of(hs, "content-transfer-encoding")),
		context.temp_allocator,
	) {
	case "base64":
		return decode_base64(body, allocator)
	case "quoted-printable":
		return decode_qp(body, false, allocator)
	}
	return transmute([]u8)body
}

// collect_cids pulls every `cid:ID` out of an HTML part. The id ends at the
// first character a URL cannot continue with, which for a Content-ID is the
// quote, bracket or whitespace that closes the attribute.
collect_cids :: proc(html: string, out: ^[dynamic]string) {
	rest := html
	for {
		i := strings.index(rest, "cid:")
		if i < 0 {
			return
		}
		rest = rest[i + 4:]
		end := 0
		for end < len(rest) {
			c := rest[end]
			if c <= ' ' || c == '"' || c == '\'' || c == '>' || c == ')' || c == '<' {
				break
			}
			end += 1
		}
		if end > 0 {
			append(out, strings.clone(rest[:end], context.temp_allocator))
		}
		rest = rest[end:]
	}
}

// ---------------------------------------------------------------------------
// Bytes, by section number
//
// This is the other half of what `extract_body` records. An attachment chip in
// the reader carries a section number; handing that section number and the
// message's own file back here produces the decoded octets, byte for byte as
// the sender encoded them.
// ---------------------------------------------------------------------------

// part_bytes returns one MIME entity's transfer-decoded octets. "" is the
// root; "2" is the second part of a multipart; "2.1" is the first part inside
// that one. The bytes are freshly allocated and belong to the caller.
//
// A multipart container has no bytes of its own — its body is its children and
// the delimiters between them — so asking for one is a miss, not a lie.
part_bytes :: proc(raw: string, section: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	head, body := split_message(raw)
	rest := section
	for depth := 0; depth <= MAX_MIME_DEPTH; depth += 1 {
		hs := parse_headers(head, context.temp_allocator)
		ct := parse_content_type(header_of(hs, "content-type"), context.temp_allocator)

		if ct.kind == "message" && ct.sub == "rfc822" {
			// The embedded message keeps this section number, so step inside
			// and carry on looking at the same level — which is exactly what
			// the collector above did on the way in.
			inner := decode_part(hs, body, context.temp_allocator)
			head, body = split_message(string(inner))
			continue
		}

		if rest == "" {
			if ct.kind == "multipart" {
				return nil, false
			}
			src := decode_part(hs, body, context.temp_allocator)
			out := make([]u8, len(src), allocator)
			copy(out, src)
			return out, true
		}

		if ct.kind != "multipart" || ct.boundary == "" {
			return nil, false
		}
		seg := rest
		if dot := strings.index_byte(rest, '.'); dot >= 0 {
			seg = rest[:dot]
			rest = rest[dot + 1:]
		} else {
			rest = ""
		}
		n, pok := strconv.parse_int(seg, 10)
		if !pok || n < 1 {
			return nil, false
		}
		parts := split_multipart(body, ct.boundary, context.temp_allocator)
		if n > len(parts) {
			return nil, false
		}
		head, body = split_message(parts[n - 1])
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// Names that are safe on disk
// ---------------------------------------------------------------------------

// sanitise_filename strips every directory component and the characters that
// make a name dangerous on disk. An attachment called "../../.bashrc" becomes
// ".bashrc"; one that reduces to nothing becomes "".
//
// This is the first of two locks. The second is `path_within`, which checks
// the path this name is joined onto.
sanitise_filename :: proc(name: string, allocator := context.allocator) -> string {
	if name == "" {
		return ""
	}
	s := name
	if k := strings.last_index_byte(s, '/'); k >= 0 {
		s = s[k + 1:]
	}
	if k := strings.last_index_byte(s, '\\'); k >= 0 {
		s = s[k + 1:]
	}
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < 0x20 || ch == 0x7f {
			continue
		}
		strings.write_byte(&sb, ch)
	}
	out := strings.trim_space(strings.to_string(sb))
	if out == "." || out == ".." {
		return ""
	}
	return out
}

// path_within reports whether `path` names a plain file sitting *directly*
// inside `dir`: no traversal, no nesting, and not `dir` itself.
//
// It compares strings rather than touching the filesystem on purpose. It is
// called on a path the app is about to construct, before anything exists, and
// its job is to prove the construction was sound.
path_within :: proc(dir, path: string) -> bool {
	d := strings.trim_right(dir, "/")
	if d == "" {
		d = "/"
	}
	prefix := d == "/" ? "/" : strings.concatenate({d, "/"}, context.temp_allocator)
	if !strings.has_prefix(path, prefix) {
		return false
	}
	rest := path[len(prefix):]
	if rest == "" || rest == "." || rest == ".." {
		return false
	}
	return !strings.contains(rest, "/")
}

// mime_extension is a short, deliberately incomplete table: the content types
// a mail client actually meets. Anything else gets ".bin", which is honest.
mime_extension :: proc(mime: string) -> string {
	switch strings.to_lower(strings.trim_space(mime), context.temp_allocator) {
	case "text/plain":
		return ".txt"
	case "text/html":
		return ".html"
	case "text/csv":
		return ".csv"
	case "text/calendar":
		return ".ics"
	case "image/png":
		return ".png"
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/svg+xml":
		return ".svg"
	case "application/pdf":
		return ".pdf"
	case "application/zip":
		return ".zip"
	case "application/gzip":
		return ".gz"
	case "application/json":
		return ".json"
	case "message/rfc822":
		return ".eml"
	}
	return ".bin"
}

// split_multipart returns the parts between the `--boundary` delimiter lines,
// discarding the preamble before the first and the epilogue after the closing
// `--boundary--`. A delimiter is a whole line, so a boundary string appearing
// inside a part's own text is not mistaken for one.
split_multipart :: proc(body: string, boundary: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	delim := strings.concatenate({"--", boundary}, context.temp_allocator)

	started := false
	part_start := 0
	at := 0
	for at <= len(body) {
		// The current line runs to the next \n, or to the end.
		nl := strings.index_byte(body[at:], '\n')
		line_end := nl < 0 ? len(body) : at + nl
		next := nl < 0 ? len(body) + 1 : line_end + 1
		line := strings.trim_right(body[at:line_end], "\r")

		if strings.has_prefix(line, delim) {
			tail := strings.trim_space(line[len(delim):])
			if started {
				piece := body[part_start:at]
				append(&out, strings.trim_right(piece, "\r\n"))
			}
			if tail == "--" {
				return out[:]
			}
			started = true
			part_start = next
		}
		at = next
	}
	if started && part_start <= len(body) {
		append(&out, strings.trim_right(body[part_start:], "\r\n"))
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// HTML to text
//
// palmy has no HTML engine and this is not pretending to be one. It is a text
// fallback: script and style content is dropped entirely, block-level tags
// become line breaks, <br> becomes one, entities are decoded, and attributes
// are discarded — which is also why no remote resource can ever be fetched.
// There is no code path here, or anywhere in this app, that takes a URL.
// ---------------------------------------------------------------------------

@(private = "file")
BLOCK_TAGS := [?]string {
	"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
	"blockquote", "pre", "table", "thead", "tbody", "section", "article",
	"header", "footer", "ul", "ol", "hr", "figure", "address", "dd", "dt", "dl",
}

@(private = "file")
DROP_TAGS := [?]string{"script", "style", "head", "title", "svg", "noscript"}

html_to_text :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '<' {
			// A comment runs to -->.
			if strings.has_prefix(s[i:], "<!--") {
				if e := strings.index(s[i:], "-->"); e >= 0 {
					i += e + 3
					continue
				}
				break
			}
			close := strings.index_byte(s[i:], '>')
			if close < 0 {
				break
			}
			tag := s[i + 1:i + close]
			i += close + 1

			closing := len(tag) > 0 && tag[0] == '/'
			nm := tag
			if closing {
				nm = tag[1:]
			}
			// The name is up to the first space or slash.
			end := len(nm)
			for k in 0 ..< len(nm) {
				if nm[k] == ' ' || nm[k] == '\t' || nm[k] == '\n' || nm[k] == '/' {
					end = k
					break
				}
			}
			nm = strings.to_lower(nm[:end], context.temp_allocator)

			if !closing {
				dropped := false
				for d in DROP_TAGS {
					if nm == d {
						// Skip to the matching close tag; its content is not
						// text and must not reach the reader.
						needle := strings.concatenate({"</", d}, context.temp_allocator)
						if e := index_ci(s[i:], needle); e >= 0 {
							j := i + e
							if gt := strings.index_byte(s[j:], '>'); gt >= 0 {
								i = j + gt + 1
							} else {
								i = len(s)
							}
						} else {
							i = len(s)
						}
						dropped = true
						break
					}
				}
				if dropped {
					continue
				}
			}

			for t in BLOCK_TAGS {
				if nm == t {
					write_break(&b, nm == "p" || nm == "blockquote" || nm == "table" || nm == "pre")
					break
				}
			}
			continue
		}
		if c == '&' {
			if semi := strings.index_byte(s[i:], ';'); semi > 1 && semi <= 10 {
				if ent, ok := decode_entity(s[i + 1:i + semi]); ok {
					strings.write_string(&b, ent)
					i += semi + 1
					continue
				}
			}
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if c == '\r' {
			i += 1
			continue
		}
		if c == '\n' || c == '\t' {
			// Source newlines are not content in HTML; they collapse to a
			// space, and runs of space collapse too.
			write_space(&b)
			i += 1
			continue
		}
		if c == ' ' {
			write_space(&b)
			i += 1
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}

	// Collapse runs of three or more newlines, then trim.
	raw := strings.to_string(b)
	out := strings.builder_make(allocator)
	run := 0
	for k in 0 ..< len(raw) {
		if raw[k] == '\n' {
			run += 1
			if run > 2 {
				continue
			}
		} else {
			run = 0
		}
		strings.write_byte(&out, raw[k])
	}
	return strings.clone(strings.trim_space(strings.to_string(out)), allocator)
}

@(private = "file")
write_break :: proc(b: ^strings.Builder, double: bool) {
	s := strings.to_string(b^)
	// Never start the output with blank lines, and never stack more than two.
	if len(s) == 0 {
		return
	}
	have := 0
	for i := len(s) - 1; i >= 0 && s[i] == '\n'; i -= 1 {
		have += 1
	}
	want := double ? 2 : 1
	// Trim a trailing space before a break.
	for strings.builder_len(b^) > 0 && strings.to_string(b^)[strings.builder_len(b^) - 1] == ' ' {
		resize(&b.buf, strings.builder_len(b^) - 1)
	}
	for have < want {
		strings.write_byte(b, '\n')
		have += 1
	}
}

@(private = "file")
write_space :: proc(b: ^strings.Builder) {
	n := strings.builder_len(b^)
	if n == 0 {
		return
	}
	last := strings.to_string(b^)[n - 1]
	if last == ' ' || last == '\n' {
		return
	}
	strings.write_byte(b, ' ')
}

@(private = "file")
index_ci :: proc(hay, needle: string) -> int {
	if len(needle) == 0 || len(hay) < len(needle) {
		return -1
	}
	for i in 0 ..= len(hay) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			a, bb := hay[i + j], needle[j]
			if a >= 'A' && a <= 'Z' {
				a += 32
			}
			if bb >= 'A' && bb <= 'Z' {
				bb += 32
			}
			if a != bb {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

decode_entity :: proc(name: string) -> (string, bool) {
	switch name {
	case "amp":
		return "&", true
	case "lt":
		return "<", true
	case "gt":
		return ">", true
	case "quot":
		return "\"", true
	case "apos", "#39":
		return "'", true
	case "nbsp", "#160":
		return " ", true
	case "mdash", "#8212":
		return "—", true
	case "ndash", "#8211":
		return "–", true
	case "hellip", "#8230":
		return "…", true
	case "rsquo", "#8217":
		return "’", true
	case "lsquo", "#8216":
		return "‘", true
	case "ldquo", "#8220":
		return "“", true
	case "rdquo", "#8221":
		return "”", true
	case "copy":
		return "©", true
	case "reg":
		return "®", true
	case "trade":
		return "™", true
	case "euro":
		return "€", true
	case "pound":
		return "£", true
	case "deg":
		return "°", true
	case "middot":
		return "·", true
	case "bull":
		return "•", true
	// The Latin-1 letters, which turn up in any message from a sender whose
	// name has an accent in it, and which a reader that drops them renders
	// as mojibake.
	case "aacute":
		return "á", true
	case "eacute":
		return "é", true
	case "iacute":
		return "í", true
	case "oacute":
		return "ó", true
	case "uacute":
		return "ú", true
	case "agrave":
		return "à", true
	case "egrave":
		return "è", true
	case "ugrave":
		return "ù", true
	case "acirc":
		return "â", true
	case "ecirc":
		return "ê", true
	case "ocirc":
		return "ô", true
	case "ucirc":
		return "û", true
	case "auml":
		return "ä", true
	case "euml":
		return "ë", true
	case "iuml":
		return "ï", true
	case "ouml":
		return "ö", true
	case "uuml":
		return "ü", true
	case "ccedil":
		return "ç", true
	case "ntilde":
		return "ñ", true
	case "atilde":
		return "ã", true
	case "otilde":
		return "õ", true
	case "aring":
		return "å", true
	case "aelig":
		return "æ", true
	case "oslash":
		return "ø", true
	case "szlig":
		return "ß", true
	case "Aacute":
		return "Á", true
	case "Eacute":
		return "É", true
	case "Oacute":
		return "Ó", true
	case "Auml":
		return "Ä", true
	case "Ouml":
		return "Ö", true
	case "Uuml":
		return "Ü", true
	case "laquo":
		return "«", true
	case "raquo":
		return "»", true
	case "dagger":
		return "†", true
	case "times":
		return "×", true
	case "frac12":
		return "½", true
	case "sect":
		return "§", true
	case "para":
		return "¶", true
	case "yen":
		return "¥", true
	case "cent":
		return "¢", true
	// Invisible formatting characters contribute nothing to readable text.
	case "shy", "zwnj", "zwj", "lrm", "rlm":
		return "", true
	}
	// Numeric references.
	if len(name) > 1 && name[0] == '#' {
		digits := name[1:]
		base := 10
		if digits[0] == 'x' || digits[0] == 'X' {
			base = 16
			digits = digits[1:]
		}
		if v, ok := strconv.parse_i64_of_base(digits, base); ok && v > 0 && v <= 0x10ffff {
			buf: [4]u8
			n := encode_rune_into(buf[:], rune(v))
			return strings.clone(string(buf[:n]), context.temp_allocator), true
		}
	}
	return "", false
}

encode_rune_into :: proc(buf: []u8, r: rune) -> int {
	c := u32(r)
	switch {
	case c < 0x80:
		buf[0] = u8(c)
		return 1
	case c < 0x800:
		buf[0] = 0xc0 | u8(c >> 6)
		buf[1] = 0x80 | u8(c & 0x3f)
		return 2
	case c < 0x10000:
		buf[0] = 0xe0 | u8(c >> 12)
		buf[1] = 0x80 | u8(c >> 6 & 0x3f)
		buf[2] = 0x80 | u8(c & 0x3f)
		return 3
	}
	buf[0] = 0xf0 | u8(c >> 18)
	buf[1] = 0x80 | u8(c >> 12 & 0x3f)
	buf[2] = 0x80 | u8(c >> 6 & 0x3f)
	buf[3] = 0x80 | u8(c & 0x3f)
	return 4
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

@(private = "file")
MONTH_NAMES := [?]string {
	"jan", "feb", "mar", "apr", "may", "jun",
	"jul", "aug", "sep", "oct", "nov", "dec",
}

// parse_rfc5322_date reads `Tue, 15 Apr 2025 09:12:33 +0200`, with the day
// name, the seconds and the zone all optional, which is what turns up in the
// wild. Returns UTC.
parse_rfc5322_date :: proc(s: string) -> (t: time.Time, ok: bool) {
	str := strings.trim_space(s)
	if comma := strings.index_byte(str, ','); comma >= 0 && comma <= 4 {
		str = strings.trim_space(str[comma + 1:])
	}
	// Drop a trailing (ZONE) comment.
	if op := strings.index_byte(str, '('); op > 0 {
		str = strings.trim_space(str[:op])
	}
	fields := strings.fields(str, context.temp_allocator)
	if len(fields) < 4 {
		return {}, false
	}
	day, dok := strconv.parse_int(fields[0])
	if !dok {
		return {}, false
	}
	mon := -1
	mname := strings.to_lower(fields[1], context.temp_allocator)
	for m, i in MONTH_NAMES {
		if strings.has_prefix(mname, m) {
			mon = i + 1
			break
		}
	}
	if mon < 0 {
		return {}, false
	}
	year, yok := strconv.parse_int(fields[2])
	if !yok {
		return {}, false
	}
	if year < 100 {
		year += year < 50 ? 2000 : 1900
	}
	hh, mm, ss := 0, 0, 0
	clock := strings.split(fields[3], ":", context.temp_allocator)
	if len(clock) >= 2 {
		hh, _ = strconv.parse_int(clock[0])
		mm, _ = strconv.parse_int(clock[1])
		if len(clock) >= 3 {
			ss, _ = strconv.parse_int(clock[2])
		}
	}
	zone_secs := 0
	if len(fields) >= 5 {
		zone_secs = parse_zone(fields[4])
	}

	tt, tok := time.components_to_time(year, mon, day, hh, mm, ss)
	if !tok {
		return {}, false
	}
	return time.Time{_nsec = tt._nsec - i64(zone_secs) * 1_000_000_000}, true
}

@(private = "file")
parse_zone :: proc(z: string) -> int {
	if len(z) >= 5 && (z[0] == '+' || z[0] == '-') {
		hh := int(z[1] - '0') * 10 + int(z[2] - '0')
		mm := int(z[3] - '0') * 10 + int(z[4] - '0')
		sign := z[0] == '-' ? -1 : 1
		return sign * (hh * 3600 + mm * 60)
	}
	switch strings.to_upper(z, context.temp_allocator) {
	case "UT", "UTC", "GMT", "Z":
		return 0
	case "EST":
		return -5 * 3600
	case "EDT":
		return -4 * 3600
	case "CST":
		return -6 * 3600
	case "CDT":
		return -5 * 3600
	case "MST":
		return -7 * 3600
	case "MDT":
		return -6 * 3600
	case "PST":
		return -8 * 3600
	case "PDT":
		return -7 * 3600
	}
	return 0
}

// format_rfc5322_date writes the form the composer puts in a Date header.
format_rfc5322_date :: proc(t: time.Time, allocator := context.allocator) -> string {
	y, m, d := time.date(t)
	hh, mi, ss := time.clock(t)
	months := MONTH_NAMES
	name := months[clamp(int(m) - 1, 0, 11)]
	upper := strings.to_upper(name[:1], context.temp_allocator)
	return fmt.aprintf(
		"%02d %s%s %d %02d:%02d:%02d +0000",
		d,
		upper,
		name[1:],
		y,
		hh,
		mi,
		ss,
		allocator = allocator,
	)
}
