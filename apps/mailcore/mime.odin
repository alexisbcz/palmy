package main

// RFC 5322 / RFC 2045-2049 message parsing.
//
// ARCHITECTURE
//
// Two passes, no backtracking, no recursion on untrusted depth beyond a hard
// limit:
//
//  1. `split_headers` finds the header/body boundary and unfolds the header
//     block into a flat `[]Header`. Duplicate names are kept in order, so
//     `Received:` chains and repeated `References:` survive.
//  2. `parse_part` interprets one entity. If it is `multipart/*` it calls
//     `split_multipart`, which is a *line scanner*, not a substring search:
//     a delimiter only counts at the start of a line, and the CRLF before it
//     belongs to the delimiter rather than to the part (RFC 2046 5.1.1).
//     Each child is then handed back to `parse_part`, so nesting is
//     arbitrary-depth by construction.
//
// Decoding is lazy-ish but eager in practice: every part carries `raw_body`
// (exactly the octets that were on the wire) and `content` (transfer-decoded).
// `text` is `content` transcoded to UTF-8 for `text/*`. Nothing is ever
// decoded twice and nothing aliases into a shared mutable buffer.
//
// Every malformed input path records a string in `warnings` and continues.
// There is no code path in this file that can panic, and every loop is bounded
// by the input length or by MAX_DEPTH/MAX_PARTS.

import "core:fmt"
import "core:mem"
import "core:strings"

import "../../cloud/mail/readable"

MAX_MIME_DEPTH :: 24
MAX_MIME_PARTS :: 512

Header :: struct {
	name:  string, // lowercased, for lookup
	key:   string, // as it appeared on the wire
	value: string, // unfolded, still RFC 2047 encoded
}

Part :: struct {
	headers:      []Header,
	section:      string, // IMAP body part number: "1", "1.2", "" for the root
	main:         string, // lowercased top-level type, e.g. "text"
	sub:          string, // lowercased subtype, e.g. "plain"
	params:       []Param,
	charset_name: string,
	charset:      Charset,
	encoding:     string, // lowercased Content-Transfer-Encoding
	disposition:  string, // lowercased: "inline", "attachment", or ""
	disp_params:  []Param,
	filename:     string, // decoded, from Content-Disposition or Content-Type
	content_id:   string, // without the angle brackets
	description:  string,
	boundary:     string,
	raw_body:     []u8, // octets as received, still encoded
	content:      []u8, // transfer-decoded octets
	text:         string, // text/* only: `content` as UTF-8, LF line endings
	parts:        []Part,
	preamble:     string,
	epilogue:     string,
	is_multipart: bool,
	is_rfc822:    bool, // message/rfc822: parts[0] is the embedded message
	unterminated: bool, // multipart with no closing --boundary--
}

Attachment :: struct {
	filename:   string,
	mime_type:  string, // "image/png"
	content_id: string,
	is_inline:  bool,
	size:       int, // decoded size
	content:    []u8,
	section:    string,
}

Message :: struct {
	raw:         []u8,
	root:        Part,
	subject:     string, // encoded words decoded
	from:        []Address,
	sender:      []Address,
	to:          []Address,
	cc:          []Address,
	bcc:         []Address,
	reply_to:    []Address,
	message_id:  string, // without angle brackets
	in_reply_to: []string, // without angle brackets
	references:  []string, // without angle brackets, in order
	date:        Mail_Date,
	date_raw:    string,
	text_plain:  string,
	text_html:   string,
	// The list line, by the rule in cloud/mail/readable: cut from what a
	// reader shows (the HTML part's visible text when there is one, else
	// the plain part), never from a part the reader would not show.
	preview:      string,
	parts_differ: bool, // text/plain and text/html say different things
	attachments: []Attachment,
	warnings:    []string,
}

@(private = "file")
Ctx :: struct {
	warnings:  [dynamic]string,
	parts_cut: int,
	alloc:     mem.Allocator,
}

@(private = "file")
warn :: proc(c: ^Ctx, format: string, args: ..any) {
	if len(c.warnings) >= 64 {
		return // a corrupt message must not produce unbounded output
	}
	append(&c.warnings, fmt.aprintf(format, ..args, allocator = c.alloc))
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

// split_headers returns the unfolded header list and the body.
//
// It accepts CRLF and bare LF line endings in the same message, because
// messages that have been through a Unix pipe have both. A message whose first
// line is an mbox `From ` separator loses that line.
split_headers :: proc(
	raw: []u8,
	allocator := context.allocator,
) -> (
	headers: []Header,
	body: []u8,
	malformed_lines: int,
) {
	hs := make([dynamic]Header, 0, 16, allocator)
	i := 0
	if len(raw) >= 5 && string(raw[:5]) == "From " {
		for i < len(raw) && raw[i] != '\n' {
			i += 1
		}
		i += 1
	}

	// Current logical header being accumulated.
	cur := strings.builder_make(allocator)
	cur_has := false
	flush :: proc(hs: ^[dynamic]Header, cur: ^strings.Builder, has: ^bool, allocator: mem.Allocator) {
		if !has^ {
			return
		}
		line := strings.to_string(cur^)
		has^ = false
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return
		}
		key := strings.trim_space(line[:colon])
		val := line[colon + 1:]
		// A single leading space after the colon is syntax, not data.
		if len(val) > 0 && (val[0] == ' ' || val[0] == '\t') {
			val = val[1:]
		}
		append(
			hs,
			Header {
				name = strings.to_lower(key, allocator),
				key = strings.clone(key, allocator),
				value = strings.clone(strings.trim_right(val, " \t"), allocator),
			},
		)
	}

	for i < len(raw) {
		// Read one physical line.
		start := i
		for i < len(raw) && raw[i] != '\n' {
			i += 1
		}
		end := i
		if end > start && raw[end - 1] == '\r' {
			end -= 1
		}
		line := string(raw[start:end])
		if i < len(raw) {
			i += 1 // step over the \n
		}

		if line == "" {
			// End of the header block. Everything after is the body.
			flush(&hs, &cur, &cur_has, allocator)
			strings.builder_destroy(&cur)
			return hs[:], raw[i:], malformed_lines
		}

		if line[0] == ' ' || line[0] == '\t' {
			if !cur_has {
				// A continuation with nothing to continue. Drop it.
				malformed_lines += 1
				continue
			}
			// Unfolding, RFC 5322 3.2.2: the CRLF is removed and the folding
			// white space that follows it is KEPT, verbatim. Collapsing it to
			// a single space would be lossy for a header whose value really
			// does contain a tab or a run of spaces.
			strings.write_string(&cur, line)
			continue
		}

		if strings.index_byte(line, ':') < 0 {
			// A line with no colon is either a single broken header (senders
			// emit those) or the first line of a body whose blank separator is
			// missing. One line of lookahead tells the two apart: if what
			// follows still looks like a header block, skip this line and
			// carry on; if it does not, the header block ended here and the
			// rest is the body.
			//
			// This is a heuristic, and it has exactly one failure mode: a
			// message with no blank line whose first body line happens to look
			// like a header field. That is the lesser of the two mistakes,
			// because the other one silently swallows the whole body.
			malformed_lines += 1
			if looks_like_header_line(raw, i) {
				continue
			}
			flush(&hs, &cur, &cur_has, allocator)
			strings.builder_destroy(&cur)
			return hs[:], raw[start:], malformed_lines
		}

		flush(&hs, &cur, &cur_has, allocator)
		strings.builder_reset(&cur)
		strings.write_string(&cur, line)
		cur_has = true
	}

	flush(&hs, &cur, &cur_has, allocator)
	strings.builder_destroy(&cur)
	return hs[:], raw[len(raw):], malformed_lines
}

// looks_like_header_line peeks at the line starting at `pos` and reports
// whether it could be part of a header block: a folding continuation, or a
// `field-name: value` whose field name is a run of printable non-space
// characters (RFC 5322 3.6.8's ftext).
@(private = "file")
looks_like_header_line :: proc(raw: []u8, pos: int) -> bool {
	if pos >= len(raw) {
		return false
	}
	end := pos
	for end < len(raw) && raw[end] != '\n' {
		end += 1
	}
	if end > pos && raw[end - 1] == '\r' {
		end -= 1
	}
	line := string(raw[pos:end])
	if line == "" {
		return false
	}
	if line[0] == ' ' || line[0] == '\t' {
		return true
	}
	colon := strings.index_byte(line, ':')
	if colon <= 0 {
		return false
	}
	for k in 0 ..< colon {
		ch := line[k]
		if ch <= 32 || ch >= 127 {
			return false
		}
	}
	return true
}

header_get :: proc(headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if h.name == name {
			return h.value, true
		}
	}
	return "", false
}

header_get_all :: proc(headers: []Header, name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 2, allocator)
	for h in headers {
		if h.name == name {
			append(&out, h.value)
		}
	}
	return out[:]
}

header_count :: proc(headers: []Header, name: string) -> (n: int) {
	for h in headers {
		if h.name == name {
			n += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Multipart splitting
// ---------------------------------------------------------------------------

Multipart_Split :: struct {
	preamble: []u8,
	bodies:   [][]u8,
	epilogue: []u8,
	closed:   bool, // a --boundary-- was seen
	found:    bool, // at least one --boundary was seen
}

// split_multipart is a line scanner. `boundary` is the raw value from the
// Content-Type parameter, without the leading dashes.
//
// RFC 2046 5.1.1:
//   - a delimiter is CRLF "--" boundary, at the start of a line;
//   - transport padding (trailing whitespace) after the boundary is allowed;
//   - "--" boundary "--" closes the part and the rest is the epilogue;
//   - the CRLF *before* a delimiter belongs to the delimiter, so it is stripped
//     from the preceding body.
split_multipart :: proc(body: []u8, boundary: string, allocator := context.allocator) -> Multipart_Split {
	res: Multipart_Split
	bodies := make([dynamic][]u8, 0, 4, allocator)
	res.preamble = body[:0]
	res.epilogue = body[len(body):]

	if boundary == "" {
		res.bodies = bodies[:]
		return res
	}

	dash := strings.concatenate({"--", boundary}, context.temp_allocator)

	// The offset where the current region (preamble or part) starts.
	region := 0
	seen_first := false
	i := 0
	for i <= len(body) {
		// Identify the current line [i, line_end), and where the next starts.
		if i == len(body) {
			break
		}
		line_start := i
		j := i
		for j < len(body) && body[j] != '\n' {
			j += 1
		}
		line_end := j
		next := j < len(body) ? j + 1 : len(body)
		if line_end > line_start && body[line_end - 1] == '\r' {
			line_end -= 1
		}
		line := string(body[line_start:line_end])
		i = next

		if !strings.has_prefix(line, dash) {
			continue
		}
		tail := strings.trim_right(line[len(dash):], " \t")
		is_close := tail == "--"
		if tail != "" && !is_close {
			continue // --boundaryXYZ is not our delimiter
		}

		// `line_start` is the first byte of the delimiter line; the CRLF just
		// before it belongs to the delimiter.
		cut := line_start
		if cut > region && body[cut - 1] == '\n' {
			cut -= 1
			if cut > region && body[cut - 1] == '\r' {
				cut -= 1
			}
		}

		if !seen_first {
			res.preamble = body[region:cut]
			seen_first = true
			res.found = true
			if is_close {
				// A close delimiter with no parts at all.
				res.closed = true
				res.epilogue = body[next:]
				res.bodies = bodies[:]
				return res
			}
			region = next
			continue
		}

		append(&bodies, body[region:cut])
		if is_close {
			res.closed = true
			res.epilogue = body[next:]
			res.bodies = bodies[:]
			return res
		}
		region = next
		if len(bodies) >= MAX_MIME_PARTS {
			break
		}
	}

	if seen_first {
		// No close delimiter: the last part runs to the end of the entity.
		append(&bodies, body[region:])
	} else {
		res.preamble = body
	}
	res.bodies = bodies[:]
	return res
}

// ---------------------------------------------------------------------------
// One entity
// ---------------------------------------------------------------------------

@(private = "file")
parse_part :: proc(c: ^Ctx, headers: []Header, body: []u8, section: string, depth: int) -> Part {
	p: Part
	p.headers = headers
	p.section = section
	p.raw_body = body
	p.main, p.sub = "text", "plain"
	p.charset = .ASCII
	p.encoding = "7bit"

	if ct, has := header_get(headers, "content-type"); has {
		if header_count(headers, "content-type") > 1 {
			warn(c, "part %q: %d Content-Type headers, using the first", section, header_count(headers, "content-type"))
		}
		head, params := parse_params(ct, c.alloc)
		p.params = params
		ht := strings.to_lower(strings.trim_space(head), c.alloc)
		if slash := strings.index_byte(ht, '/'); slash > 0 {
			p.main = ht[:slash]
			p.sub = strings.trim_space(ht[slash + 1:])
		} else if ht != "" {
			// "Content-Type: text" and friends. RFC 2045 says treat an
			// unrecognised type as application/octet-stream, but a bare top
			// level type with a known name is more usefully kept.
			p.main = ht
			p.sub = ht == "text" ? "plain" : "octet-stream"
			warn(c, "part %q: Content-Type %q has no subtype", section, ht)
		}
		if cs, ok := param_get(params, "charset"); ok {
			p.charset_name = cs
			p.charset = charset_from_name(cs)
			if p.charset == .Unknown {
				warn(c, "part %q: unsupported charset %q, falling back", section, cs)
			}
		} else if p.main == "text" {
			p.charset = .ASCII
			p.charset_name = "us-ascii"
		}
		if b, ok := param_get(params, "boundary"); ok {
			p.boundary = b
		}
		if n, ok := param_get(params, "name"); ok {
			p.filename = n
		}
	}

	if cte, has := header_get(headers, "content-transfer-encoding"); has {
		// The value is a token; strip any stray parameters and comments.
		h, _ := parse_params(cte, c.alloc)
		p.encoding = strings.to_lower(strings.trim_space(h), c.alloc)
	}

	if cd, has := header_get(headers, "content-disposition"); has {
		head, params := parse_params(cd, c.alloc)
		p.disposition = strings.to_lower(strings.trim_space(head), c.alloc)
		p.disp_params = params
		if fn, ok := param_get(params, "filename"); ok {
			p.filename = fn
		}
	}
	if cid, has := header_get(headers, "content-id"); has {
		p.content_id = strings.trim(strings.trim_space(cid), "<>")
	}
	if cdesc, has := header_get(headers, "content-description"); has {
		p.description, _ = decode_encoded_words(cdesc, c.alloc)
	}
	// A filename must never be allowed to escape a directory.
	p.filename = sanitise_filename(p.filename, c.alloc)

	if p.main == "multipart" {
		p.is_multipart = true
		if depth >= MAX_MIME_DEPTH {
			warn(c, "part %q: nesting deeper than %d, not descending", section, MAX_MIME_DEPTH)
			p.content = body
			return p
		}
		if p.boundary == "" {
			warn(c, "part %q: multipart/%s with no boundary parameter", section, p.sub)
			p.is_multipart = false
			p.content = body
			return p
		}
		sp := split_multipart(body, p.boundary, c.alloc)
		p.preamble = strings.clone(string(sp.preamble), c.alloc)
		p.epilogue = strings.clone(string(sp.epilogue), c.alloc)
		if !sp.found {
			warn(c, "part %q: boundary %q never appears in the body", section, p.boundary)
			p.is_multipart = false
			p.content = body
			return p
		}
		if !sp.closed {
			p.unterminated = true
			warn(c, "part %q: no closing --%s--, message is truncated", section, p.boundary)
		}
		kids := make([dynamic]Part, 0, len(sp.bodies), c.alloc)
		for kb, ki in sp.bodies {
			c.parts_cut += 1
			if c.parts_cut > MAX_MIME_PARTS {
				warn(c, "part %q: more than %d parts, stopping", section, MAX_MIME_PARTS)
				break
			}
			sub_section := section == "" ? fmt.aprintf("%d", ki + 1, allocator = c.alloc) : fmt.aprintf("%s.%d", section, ki + 1, allocator = c.alloc)
			kh, kbody, bad := split_headers(kb, c.alloc)
			if bad > 0 {
				warn(c, "part %q: %d malformed header line(s)", sub_section, bad)
			}
			append(&kids, parse_part(c, kh, kbody, sub_section, depth + 1))
		}
		p.parts = kids[:]
		return p
	}

	// Transfer-decode.
	switch p.encoding {
	case "base64":
		p.content = base64_decode(body, c.alloc)
	case "quoted-printable":
		p.content = qp_decode(body, false, c.alloc)
	case "7bit", "8bit", "binary", "":
		p.content = body
	case:
		warn(c, "part %q: unknown Content-Transfer-Encoding %q, treating as 8bit", section, p.encoding)
		p.content = body
	}

	if p.main == "message" && (p.sub == "rfc822" || p.sub == "news" || p.sub == "global") {
		p.is_rfc822 = true
		if depth >= MAX_MIME_DEPTH {
			warn(c, "part %q: embedded message too deep, not descending", section)
			return p
		}
		eh, ebody, bad := split_headers(p.content, c.alloc)
		if bad > 0 {
			warn(c, "part %q: embedded message has %d malformed header line(s)", section, bad)
		}
		kids := make([dynamic]Part, 0, 1, c.alloc)
		// RFC 3501 numbering: the embedded message's body is section.1 when it
		// is a single part, so keep the same section prefix.
		append(&kids, parse_part(c, eh, ebody, section, depth + 1))
		p.parts = kids[:]
		return p
	}

	if p.main == "text" {
		s, lossy := charset_to_utf8(p.content, p.charset, c.alloc)
		if lossy {
			warn(c, "part %q: charset %q decoded lossily", section, p.charset_name)
		}
		p.text = normalise_newlines(s, c.alloc)
	}
	return p
}

// sanitise_filename strips directory components and the characters that make a
// name dangerous on disk. An attachment called "../../.bashrc" becomes
// ".bashrc"; a name that reduces to nothing becomes "".
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

normalise_newlines :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '\r') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\r' {
			if i + 1 < len(s) && s[i + 1] == '\n' {
				continue
			}
			strings.write_byte(&sb, '\n')
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Whole message
// ---------------------------------------------------------------------------

parse_message :: proc(raw: []u8, allocator := context.allocator) -> Message {
	c := Ctx {
		alloc    = allocator,
		warnings = make([dynamic]string, 0, 4, allocator),
	}
	m: Message
	m.raw = raw

	headers, body, bad := split_headers(raw, allocator)
	if bad > 0 {
		warn(&c, "top level: %d malformed header line(s)", bad)
	}
	if len(headers) == 0 {
		warn(&c, "message has no headers at all")
	}
	m.root = parse_part(&c, headers, body, "", 0)

	if v, has := header_get(headers, "subject"); has {
		s, lossy := decode_encoded_words(v, allocator)
		if lossy {
			warn(&c, "Subject: decoded lossily")
		}
		m.subject = s
		if header_count(headers, "subject") > 1 {
			warn(&c, "%d Subject headers, using the first", header_count(headers, "subject"))
		}
	}
	if v, has := header_get(headers, "from"); has {
		m.from = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "sender"); has {
		m.sender = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "to"); has {
		m.to = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "cc"); has {
		m.cc = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "bcc"); has {
		m.bcc = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "reply-to"); has {
		m.reply_to = parse_address_list(v, allocator)
	}
	if v, has := header_get(headers, "message-id"); has {
		ids := extract_msg_ids(v, allocator)
		if len(ids) > 0 {
			m.message_id = ids[0]
		}
	}
	// In-Reply-To and References may both appear more than once; JWZ wants
	// every id, in order, so all occurrences are concatenated.
	{
		ids := make([dynamic]string, 0, 4, allocator)
		for v in header_get_all(headers, "in-reply-to", context.temp_allocator) {
			for id in extract_msg_ids(v, allocator) {
				append(&ids, id)
			}
		}
		m.in_reply_to = ids[:]
	}
	{
		ids := make([dynamic]string, 0, 8, allocator)
		for v in header_get_all(headers, "references", context.temp_allocator) {
			for id in extract_msg_ids(v, allocator) {
				append(&ids, id)
			}
		}
		m.references = ids[:]
	}
	if v, has := header_get(headers, "date"); has {
		m.date_raw = v
		m.date = parse_date(v)
		if !m.date.ok {
			warn(&c, "Date: %q is unparseable", v)
		}
	} else {
		warn(&c, "no Date header")
	}

	// Body selection and attachment collection.
	atts := make([dynamic]Attachment, 0, 4, allocator)
	collect_bodies(&m.root, &m, &atts, false)
	m.attachments = atts[:]

	r := readable.of(m.text_plain, m.text_html, context.temp_allocator)
	m.preview = readable.preview(r.text, 256, allocator)
	m.parts_differ = r.differ

	m.warnings = c.warnings[:]
	return m
}

// extract_msg_ids pulls every <addr-spec> out of a header value. Senders that
// omit the angle brackets entirely are tolerated: a value with no `<` at all
// but exactly one token containing `@` is taken as a bare id.
extract_msg_ids :: proc(v: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	i := 0
	for i < len(v) {
		if v[i] != '<' {
			i += 1
			continue
		}
		close := strings.index_byte(v[i + 1:], '>')
		if close < 0 {
			break
		}
		id := strings.trim_space(v[i + 1:i + 1 + close])
		if id != "" {
			append(&out, strings.clone(id, allocator))
		}
		i += 1 + close + 1
	}
	if len(out) == 0 {
		for tok in strings.fields(v, context.temp_allocator) {
			if strings.contains(tok, "@") {
				append(&out, strings.clone(strings.trim(tok, "<>,;"), allocator))
			}
		}
	}
	return out[:]
}

// collect_bodies walks the tree once, choosing the display bodies and
// gathering attachments.
//
// The rule for `multipart/alternative` is RFC 2046 5.1.4 read honestly: the
// parts are in increasing order of faithfulness, so the *last* representation
// the client understands wins. For a mail client that means: the last
// text/html is the body to render, and the last text/plain is the fallback.
// Anything with a `Content-Disposition: attachment` is an attachment no matter
// what its type is.
@(private = "file")
collect_bodies :: proc(p: ^Part, m: ^Message, atts: ^[dynamic]Attachment, inside_attachment: bool) {
	if p.is_multipart {
		for i in 0 ..< len(p.parts) {
			collect_bodies(&p.parts[i], m, atts, inside_attachment)
		}
		return
	}
	if p.is_rfc822 {
		// An embedded message is an attachment; its own parts are not this
		// message's body.
		append(
			atts,
			Attachment {
				filename = p.filename != "" ? p.filename : "message.eml",
				mime_type = "message/rfc822",
				content_id = p.content_id,
				is_inline = p.disposition == "inline",
				size = len(p.content),
				content = p.content,
				section = p.section,
			},
		)
		return
	}

	is_att := p.disposition == "attachment" || (p.filename != "" && p.main != "text")
	if p.main == "text" && !is_att && p.disposition != "attachment" {
		if p.sub == "plain" {
			m.text_plain = p.text
		} else if p.sub == "html" {
			m.text_html = p.text
		} else if m.text_plain == "" {
			// text/enriched, text/calendar and friends: better than nothing.
			m.text_plain = p.text
		}
		if p.filename == "" && p.content_id == "" {
			return
		}
	}
	if p.main == "multipart" {
		return
	}
	append(
		atts,
		Attachment {
			filename = p.filename,
			mime_type = fmt.aprintf("%s/%s", p.main, p.sub),
			content_id = p.content_id,
			is_inline = p.disposition == "inline" || (p.disposition == "" && p.content_id != ""),
			size = len(p.content),
			content = p.content,
			section = p.section,
		},
	)
}

// find_part looks a part up by its IMAP section number.
find_part :: proc(p: ^Part, section: string) -> ^Part {
	if p.section == section {
		return p
	}
	for i in 0 ..< len(p.parts) {
		if r := find_part(&p.parts[i], section); r != nil {
			return r
		}
	}
	return nil
}

// part_count counts every entity in the tree including multipart containers.
part_count :: proc(p: ^Part) -> (n: int) {
	n = 1
	for i in 0 ..< len(p.parts) {
		n += part_count(&p.parts[i])
	}
	return
}
