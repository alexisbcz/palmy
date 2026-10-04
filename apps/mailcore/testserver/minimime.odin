package main

// A small, independent MIME walker for the test server.
//
// WHY THIS EXISTS AND WHY IT IS SEPARATE. The server needs two things the raw
// bytes do not give it: an IMAP BODYSTRUCTURE, and a decomposed view of any
// message that arrived at runtime over SMTP rather than from the authored
// corpus. It could have shared the client's parser — and that is precisely
// what it must not do, because then a parser bug would produce a matching
// server bug and the self-test would agree with itself.
//
// So this is a second implementation, written from the RFCs independently. It
// is deliberately smaller: base64 and quoted-printable, UTF-8 and ISO-8859-1
// and KOI8-R, RFC 2047 B- and Q-words, one boundary scanner. It does not do
// RFC 2231 continuations, it does not do charset fallbacks, and it gives up
// rather than guessing. Where it and the client disagree, the corpus's
// hand-authored fields are the tie-breaker.

import "core:mem"
import "core:strconv"
import "core:strings"

MM_MAX_DEPTH :: 12

MM_Part :: struct {
	main:        string,
	sub:         string,
	params:      [][2]string,
	encoding:    string,
	disposition: string,
	filename:    string,
	cid:         string,
	charset:     string,
	raw_body:    []u8,
	decoded:     []u8,
	text:        string,
	lines:       int,
	parts:       []MM_Part,
	section:     string,
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

mm_split :: proc(raw: []u8, allocator := context.allocator) -> (headers: [][2]string, body: []u8) {
	hs := make([dynamic][2]string, 0, 16, allocator)
	cur := strings.builder_make(allocator)
	has := false
	flush :: proc(hs: ^[dynamic][2]string, cur: ^strings.Builder, has: ^bool, allocator: mem.Allocator) {
		if !has^ {
			return
		}
		line := strings.to_string(cur^)
		has^ = false
		c := strings.index_byte(line, ':')
		if c <= 0 {
			return
		}
		append(
			hs,
			[2]string {
				strings.to_lower(strings.trim_space(line[:c]), allocator),
				strings.clone(strings.trim_space(line[c + 1:]), allocator),
			},
		)
	}
	i := 0
	for i < len(raw) {
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
			i += 1
		}
		if line == "" {
			flush(&hs, &cur, &has, allocator)
			return hs[:], raw[i:]
		}
		if line[0] == ' ' || line[0] == '\t' {
			if has {
				strings.write_byte(&cur, ' ')
				strings.write_string(&cur, strings.trim_left(line, " \t"))
			}
			continue
		}
		if strings.index_byte(line, ':') < 0 {
			flush(&hs, &cur, &has, allocator)
			return hs[:], raw[start:]
		}
		flush(&hs, &cur, &has, allocator)
		strings.builder_reset(&cur)
		strings.write_string(&cur, line)
		has = true
	}
	flush(&hs, &cur, &has, allocator)
	return hs[:], raw[len(raw):]
}

mm_get :: proc(headers: [][2]string, name: string) -> (string, bool) {
	for h in headers {
		if h[0] == name {
			return h[1], true
		}
	}
	return "", false
}

mm_get_all :: proc(headers: [][2]string, name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 2, allocator)
	for h in headers {
		if h[0] == name {
			append(&out, h[1])
		}
	}
	return out[:]
}

// mm_params splits `text/plain; charset="utf-8"` into the head and the
// parameters. Quoted strings only; no RFC 2231.
mm_params :: proc(v: string, allocator := context.allocator) -> (head: string, params: [][2]string) {
	ps := make([dynamic][2]string, 0, 4, allocator)
	in_q := false
	cut := -1
	for i in 0 ..< len(v) {
		if v[i] == '"' {in_q = !in_q}
		if v[i] == ';' && !in_q {cut = i;break}
	}
	if cut < 0 {
		return strings.trim_space(v), ps[:]
	}
	head = strings.trim_space(v[:cut])
	rest := v[cut + 1:]
	for len(rest) > 0 {
		in_q = false
		nx := -1
		for i in 0 ..< len(rest) {
			if rest[i] == '"' {in_q = !in_q}
			if rest[i] == ';' && !in_q {nx = i;break}
		}
		chunk := nx < 0 ? rest : rest[:nx]
		rest = nx < 0 ? "" : rest[nx + 1:]
		chunk = strings.trim_space(chunk)
		eq := strings.index_byte(chunk, '=')
		if eq <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(chunk[:eq]), allocator)
		val := strings.trim_space(chunk[eq + 1:])
		if len(val) >= 2 && val[0] == '"' {
			sb := strings.builder_make(allocator)
			for i := 1; i < len(val); i += 1 {
				if val[i] == '\\' && i + 1 < len(val) {
					i += 1
					strings.write_byte(&sb, val[i])
					continue
				}
				if val[i] == '"' {break}
				strings.write_byte(&sb, val[i])
			}
			val = strings.to_string(sb)
		}
		append(&ps, [2]string{name, val})
	}
	return head, ps[:]
}

mm_param :: proc(ps: [][2]string, name: string) -> (string, bool) {
	for p in ps {
		if p[0] == name {
			return p[1], true
		}
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

@(rodata)
MM_B64 := [64]u8 {
	'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
	'Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f',
	'g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v',
	'w','x','y','z','0','1','2','3','4','5','6','7','8','9','+','/',
}

mm_b64_decode :: proc(src: []u8, allocator := context.allocator) -> []u8 {
	rev: [256]i8
	for i in 0 ..< 256 {rev[i] = -1}
	for i in 0 ..< 64 {rev[MM_B64[i]] = i8(i)}
	out := make([dynamic]u8, 0, len(src) * 3 / 4 + 3, allocator)
	acc: u32
	n := 0
	for ch in src {
		if ch == '=' {break}
		v := rev[ch]
		if v < 0 {continue}
		acc = acc << 6 | u32(v)
		n += 1
		if n == 4 {
			append(&out, u8(acc >> 16), u8(acc >> 8), u8(acc))
			acc = 0
			n = 0
		}
	}
	if n == 3 {
		acc <<= 6
		append(&out, u8(acc >> 16), u8(acc >> 8))
	} else if n == 2 {
		acc <<= 12
		append(&out, u8(acc >> 16))
	}
	return out[:]
}

mm_b64_encode :: proc(src: []u8, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	i := 0
	for ; i + 2 < len(src); i += 3 {
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8 | u32(src[i + 2])
		strings.write_byte(&sb, MM_B64[v >> 18 & 63])
		strings.write_byte(&sb, MM_B64[v >> 12 & 63])
		strings.write_byte(&sb, MM_B64[v >> 6 & 63])
		strings.write_byte(&sb, MM_B64[v & 63])
	}
	switch len(src) - i {
	case 1:
		v := u32(src[i]) << 16
		strings.write_byte(&sb, MM_B64[v >> 18 & 63])
		strings.write_byte(&sb, MM_B64[v >> 12 & 63])
		strings.write_string(&sb, "==")
	case 2:
		v := u32(src[i]) << 16 | u32(src[i + 1]) << 8
		strings.write_byte(&sb, MM_B64[v >> 18 & 63])
		strings.write_byte(&sb, MM_B64[v >> 12 & 63])
		strings.write_byte(&sb, MM_B64[v >> 6 & 63])
		strings.write_byte(&sb, '=')
	}
	return strings.to_string(sb)
}

mm_hex :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

mm_qp_decode :: proc(src: []u8, header: bool, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src), allocator)
	for i := 0; i < len(src); {
		c := src[i]
		if header && c == '_' {
			append(&out, ' ')
			i += 1
			continue
		}
		if c == '=' {
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {j += 1}
			if j < len(src) && (src[j] == '\r' || src[j] == '\n') {
				if src[j] == '\r' && j + 1 < len(src) && src[j + 1] == '\n' {j += 1}
				i = j + 1
				continue
			}
			if i + 2 < len(src) {
				hi, o1 := mm_hex(src[i + 1])
				lo, o2 := mm_hex(src[i + 2])
				if o1 && o2 {
					append(&out, hi << 4 | lo)
					i += 3
					continue
				}
			}
			append(&out, '=')
			i += 1
			continue
		}
		if !header && (c == '\r' || c == '\n') {
			for len(out) > 0 && (out[len(out) - 1] == ' ' || out[len(out) - 1] == '\t') {
				pop(&out)
			}
		}
		if header && (c == '\r' || c == '\n') {
			i += 1
			continue
		}
		append(&out, c)
		i += 1
	}
	return out[:]
}

@(rodata)
MM_KOI8R := [128]rune {
	0x2500,0x2502,0x250C,0x2510,0x2514,0x2518,0x251C,0x2524,
	0x252C,0x2534,0x253C,0x2580,0x2584,0x2588,0x258C,0x2590,
	0x2591,0x2592,0x2593,0x2320,0x25A0,0x2219,0x221A,0x2248,
	0x2264,0x2265,0x00A0,0x2321,0x00B0,0x00B2,0x00B7,0x00F7,
	0x2550,0x2551,0x2552,0x0451,0x2553,0x2554,0x2555,0x2556,
	0x2557,0x2558,0x2559,0x255A,0x255B,0x255C,0x255D,0x255E,
	0x255F,0x2560,0x2561,0x0401,0x2562,0x2563,0x2564,0x2565,
	0x2566,0x2567,0x2568,0x2569,0x256A,0x256B,0x256C,0x00A9,
	0x044E,0x0430,0x0431,0x0446,0x0434,0x0435,0x0444,0x0433,
	0x0445,0x0438,0x0439,0x043A,0x043B,0x043C,0x043D,0x043E,
	0x043F,0x044F,0x0440,0x0441,0x0442,0x0443,0x0436,0x0432,
	0x044C,0x044B,0x0437,0x0448,0x044D,0x0449,0x0447,0x044A,
	0x042E,0x0410,0x0411,0x0426,0x0414,0x0415,0x0424,0x0413,
	0x0425,0x0418,0x0419,0x041A,0x041B,0x041C,0x041D,0x041E,
	0x041F,0x042F,0x0420,0x0421,0x0422,0x0423,0x0416,0x0412,
	0x042C,0x042B,0x0417,0x0428,0x042D,0x0429,0x0427,0x042A,
}

mm_to_utf8 :: proc(data: []u8, charset: string, allocator := context.allocator) -> string {
	cs := strings.to_lower(strings.trim_space(charset), context.temp_allocator)
	if star := strings.index_byte(cs, '*'); star >= 0 {cs = cs[:star]}
	switch cs {
	case "", "utf-8", "utf8", "us-ascii", "ascii":
		return strings.clone(string(data), allocator)
	case "iso-8859-1", "latin1", "iso8859-1":
		sb := strings.builder_make(allocator)
		for b in data {
			if b < 0x80 {strings.write_byte(&sb, b)} else {strings.write_rune(&sb, rune(b))}
		}
		return strings.to_string(sb)
	case "koi8-r", "koi8r":
		sb := strings.builder_make(allocator)
		for b in data {
			if b < 0x80 {strings.write_byte(&sb, b)} else {strings.write_rune(&sb, MM_KOI8R[b - 0x80])}
		}
		return strings.to_string(sb)
	}
	// This minimal parser declines to guess. The corpus's authored fields are
	// the answer for anything else.
	return strings.clone(string(data), allocator)
}

// mm_decode_words decodes RFC 2047 encoded words, concatenating adjacent ones.
mm_decode_words :: proc(v: string, allocator := context.allocator) -> string {
	if !strings.contains(v, "=?") {
		return strings.clone(v, allocator)
	}
	sb := strings.builder_make(allocator)
	i := 0
	last_was_word := false
	pending_ws := strings.builder_make(context.temp_allocator)
	for i < len(v) {
		if v[i] == '=' && i + 1 < len(v) && v[i + 1] == '?' {
			rest := v[i + 2:]
			q1 := strings.index_byte(rest, '?')
			if q1 >= 0 && q1 + 2 < len(rest) && rest[q1 + 2] == '?' {
				body_start := q1 + 3
				end := strings.index(rest[body_start:], "?=")
				if end >= 0 {
					cs := rest[:q1]
					enc := rest[q1 + 1]
					body := rest[body_start:body_start + end]
					raw: []u8
					ok := true
					switch enc {
					case 'B', 'b':
						raw = mm_b64_decode(transmute([]u8)body, context.temp_allocator)
					case 'Q', 'q':
						raw = mm_qp_decode(transmute([]u8)body, true, context.temp_allocator)
					case:
						ok = false
					}
					if ok {
						if !last_was_word {
							strings.write_string(&sb, strings.to_string(pending_ws))
						}
						strings.builder_reset(&pending_ws)
						strings.write_string(&sb, mm_to_utf8(raw, cs, context.temp_allocator))
						last_was_word = true
						i += 2 + body_start + end + 2
						continue
					}
				}
			}
		}
		if v[i] == ' ' || v[i] == '\t' {
			strings.write_byte(&pending_ws, v[i])
			i += 1
			continue
		}
		strings.write_string(&sb, strings.to_string(pending_ws))
		strings.builder_reset(&pending_ws)
		strings.write_byte(&sb, v[i])
		last_was_word = false
		i += 1
	}
	strings.write_string(&sb, strings.to_string(pending_ws))
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

mm_parse :: proc(raw: []u8, section := "", depth := 0, allocator := context.allocator) -> MM_Part {
	headers, body := mm_split(raw, allocator)
	return mm_parse_entity(headers, body, section, depth, allocator)
}

mm_parse_entity :: proc(
	headers: [][2]string,
	body: []u8,
	section: string,
	depth: int,
	allocator := context.allocator,
) -> MM_Part {
	p := MM_Part {
		main     = "text",
		sub      = "plain",
		encoding = "7bit",
		raw_body = body,
		section  = section,
		charset  = "us-ascii",
	}
	boundary := ""
	if ct, ok := mm_get(headers, "content-type"); ok {
		head, ps := mm_params(ct, allocator)
		p.params = ps
		h := strings.to_lower(head, allocator)
		if sl := strings.index_byte(h, '/'); sl > 0 {
			p.main = h[:sl]
			p.sub = h[sl + 1:]
		}
		if b, k := mm_param(ps, "boundary"); k {boundary = b}
		if cs, k := mm_param(ps, "charset"); k {p.charset = cs}
		if n, k := mm_param(ps, "name"); k {p.filename = n}
	}
	if cte, ok := mm_get(headers, "content-transfer-encoding"); ok {
		h, _ := mm_params(cte, allocator)
		p.encoding = strings.to_lower(strings.trim_space(h), allocator)
	}
	if cd, ok := mm_get(headers, "content-disposition"); ok {
		h, ps := mm_params(cd, allocator)
		p.disposition = strings.to_lower(strings.trim_space(h), allocator)
		if f, k := mm_param(ps, "filename"); k {p.filename = f}
	}
	if cid, ok := mm_get(headers, "content-id"); ok {
		p.cid = strings.trim(strings.trim_space(cid), "<>")
	}

	if p.main == "multipart" && boundary != "" && depth < MM_MAX_DEPTH {
		dash := strings.concatenate({"--", boundary}, context.temp_allocator)
		kids := make([dynamic]MM_Part, 0, 4, allocator)
		region := -1
		i := 0
		for i < len(body) {
			ls := i
			j := i
			for j < len(body) && body[j] != '\n' {j += 1}
			le := j
			next := j < len(body) ? j + 1 : len(body)
			if le > ls && body[le - 1] == '\r' {le -= 1}
			line := string(body[ls:le])
			i = next
			if !strings.has_prefix(line, dash) {
				continue
			}
			tail := strings.trim_right(line[len(dash):], " \t")
			is_close := tail == "--"
			if tail != "" && !is_close {
				continue
			}
			if region >= 0 {
				cut := ls
				if cut > region && body[cut - 1] == '\n' {
					cut -= 1
					if cut > region && body[cut - 1] == '\r' {cut -= 1}
				}
				sec := section == "" ? itoa(len(kids) + 1) : strings.concatenate({section, ".", itoa(len(kids) + 1)}, allocator)
				append(&kids, mm_parse(body[region:cut], sec, depth + 1, allocator))
			}
			if is_close {
				region = -1
				break
			}
			region = next
		}
		if region >= 0 {
			sec := section == "" ? itoa(len(kids) + 1) : strings.concatenate({section, ".", itoa(len(kids) + 1)}, allocator)
			append(&kids, mm_parse(body[region:], sec, depth + 1, allocator))
		}
		p.parts = kids[:]
		return p
	}

	switch p.encoding {
	case "base64":
		p.decoded = mm_b64_decode(body, allocator)
	case "quoted-printable":
		p.decoded = mm_qp_decode(body, false, allocator)
	case:
		p.decoded = body
	}
	if p.main == "text" {
		s := mm_to_utf8(p.decoded, p.charset, allocator)
		// Normalise to LF, matching what the client stores.
		out := strings.builder_make(allocator)
		for k := 0; k < len(s); k += 1 {
			if s[k] == '\r' {continue}
			strings.write_byte(&out, s[k])
		}
		p.text = strings.to_string(out)
		for k in 0 ..< len(p.decoded) {
			if p.decoded[k] == '\n' {p.lines += 1}
		}
	}
	if p.main == "message" && p.sub == "rfc822" && depth < MM_MAX_DEPTH {
		kids := make([dynamic]MM_Part, 0, 1, allocator)
		append(&kids, mm_parse(p.decoded, section, depth + 1, allocator))
		p.parts = kids[:]
	}
	return p
}

itoa :: proc(n: int, allocator := context.allocator) -> string {
	buf: [24]u8
	n2 := strconv.write_int(buf[:], i64(n), 10)
	return strings.clone(n2, allocator)
}

// ---------------------------------------------------------------------------
// Deriving a Decomp for a runtime-delivered message
// ---------------------------------------------------------------------------

mm_first_addr :: proc(v: string, allocator := context.allocator) -> (name, email: string) {
	s := strings.trim_space(v)
	if c := strings.index_byte(s, ','); c >= 0 {
		// Only the first address; good enough for the derived view.
		depth := 0
		in_q := false
		for i in 0 ..< len(s) {
			switch s[i] {
			case '"':
				in_q = !in_q
			case '<':
				if !in_q {depth += 1}
			case '>':
				if !in_q && depth > 0 {depth -= 1}
			case ',':
				if !in_q && depth == 0 {
					s = s[:i]
					break
				}
			}
		}
	}
	if lt := strings.last_index_byte(s, '<'); lt >= 0 {
		gt := strings.index_byte(s[lt:], '>')
		email = gt < 0 ? strings.clone(strings.trim_space(s[lt + 1:]), allocator) : strings.clone(strings.trim_space(s[lt + 1:lt + gt]), allocator)
		n := strings.trim_space(s[:lt])
		n = strings.trim(n, "\"")
		name = mm_decode_words(n, allocator)
		return
	}
	return "", strings.clone(s, allocator)
}

mm_ids :: proc(v: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	i := 0
	for i < len(v) {
		if v[i] != '<' {i += 1;continue}
		c := strings.index_byte(v[i + 1:], '>')
		if c < 0 {break}
		id := strings.trim_space(v[i + 1:i + 1 + c])
		if id != "" {append(&out, strings.clone(id, allocator))}
		i += 1 + c + 1
	}
	return out[:]
}

// mm_derive_decomp builds the structured view of a message the server was
// handed at runtime. Marked `authored = false` so the self-test can tell the
// difference between a human's reading and this parser's.
mm_derive_decomp :: proc(raw: []u8, received: i64, allocator := context.allocator) -> Decomp {
	headers, _ := mm_split(raw, allocator)
	root := mm_parse(raw, "", 0, allocator)
	d: Decomp
	d.authored = false
	if v, ok := mm_get(headers, "subject"); ok {
		d.subject = mm_decode_words(v, allocator)
	}
	if v, ok := mm_get(headers, "from"); ok {
		d.from_name, d.from_email = mm_first_addr(v, allocator)
	}
	if v, ok := mm_get(headers, "to"); ok {
		d.to_name, d.to_email = mm_first_addr(v, allocator)
	}
	if v, ok := mm_get(headers, "message-id"); ok {
		ids := mm_ids(v, allocator)
		if len(ids) > 0 {d.message_id = ids[0]}
	}
	irt := make([dynamic]string, 0, 2, allocator)
	for v in mm_get_all(headers, "in-reply-to", allocator) {
		for id in mm_ids(v, allocator) {append(&irt, id)}
	}
	d.in_reply_to = irt[:]
	refs := make([dynamic]string, 0, 4, allocator)
	for v in mm_get_all(headers, "references", allocator) {
		for id in mm_ids(v, allocator) {append(&refs, id)}
	}
	d.references = refs[:]
	d.sent_at = iso8601(received, allocator)

	tb := make([dynamic]Body_Part_Spec, 0, 1, allocator)
	hb := make([dynamic]Body_Part_Spec, 0, 1, allocator)
	atts := make([dynamic]Body_Part_Spec, 0, 4, allocator)
	collect :: proc(
		p: ^MM_Part,
		tb, hb, atts: ^[dynamic]Body_Part_Spec,
		allocator: mem.Allocator,
	) {
		if p.main == "multipart" {
			for i in 0 ..< len(p.parts) {
				collect(&p.parts[i], tb, hb, atts, allocator)
			}
			return
		}
		is_att := p.disposition == "attachment" || (p.filename != "" && p.main != "text")
		if p.main == "text" && !is_att {
			spec := Body_Part_Spec {
				part_id = p.section == "" ? "1" : p.section,
				type    = strings.concatenate({p.main, "/", p.sub}, allocator),
				charset = p.charset,
				size    = len(p.decoded),
				value   = p.text,
			}
			if p.sub == "html" {
				if len(hb) == 0 {append(hb, spec)}
			} else {
				if len(tb) == 0 {append(tb, spec)}
			}
			if p.filename == "" && p.cid == "" {
				return
			}
		}
		append(
			atts,
			Body_Part_Spec {
				part_id = p.section,
				type = strings.concatenate({p.main, "/", p.sub}, allocator),
				name = p.filename,
				disposition = p.disposition == "" ? (p.cid != "" ? "inline" : "attachment") : p.disposition,
				cid = p.cid,
				size = len(p.decoded),
			},
		)
	}
	collect(&root, &tb, &hb, &atts, allocator)
	d.text_body = tb[:]
	d.html_body = hb[:]
	d.attachments = atts[:]
	d.has_attachment = len(atts) > 0
	prev := len(tb) > 0 ? tb[0].value : (len(hb) > 0 ? hb[0].value : "")
	if len(prev) > 200 {prev = prev[:200]}
	d.preview = prev
	d.structure = Body_Part_Spec {
		part_id = "0",
		type    = strings.concatenate({root.main, "/", root.sub}, allocator),
	}
	return d
}

// ---------------------------------------------------------------------------
// BODYSTRUCTURE
// ---------------------------------------------------------------------------

// mm_bodystructure renders RFC 3501 7.4.2's BODYSTRUCTURE from the walk. The
// extension fields (disposition, language, location) are included for single
// parts and for multiparts, which is what `BODYSTRUCTURE` (as opposed to
// `BODY`) means.
mm_bodystructure :: proc(p: ^MM_Part, sb: ^strings.Builder, extended := true) {
	iq :: proc(sb: ^strings.Builder, s: string) {
		if s == "" {
			strings.write_string(sb, "NIL")
			return
		}
		strings.write_byte(sb, '"')
		for i in 0 ..< len(s) {
			if s[i] == '"' || s[i] == '\\' {strings.write_byte(sb, '\\')}
			strings.write_byte(sb, s[i])
		}
		strings.write_byte(sb, '"')
	}
	params :: proc(sb: ^strings.Builder, ps: [][2]string) {
		real := 0
		for p in ps {
			if p[0] != "boundary" || true {real += 1}
		}
		if real == 0 {
			strings.write_string(sb, "NIL")
			return
		}
		strings.write_byte(sb, '(')
		first := true
		for p in ps {
			if !first {strings.write_byte(sb, ' ')}
			first = false
			iq(sb, p[0])
			strings.write_byte(sb, ' ')
			iq(sb, p[1])
		}
		strings.write_byte(sb, ')')
	}

	strings.write_byte(sb, '(')
	if p.main == "multipart" {
		for i in 0 ..< len(p.parts) {
			mm_bodystructure(&p.parts[i], sb, extended)
		}
		strings.write_byte(sb, ' ')
		iq(sb, strings.to_upper(p.sub, context.temp_allocator))
		if extended {
			strings.write_byte(sb, ' ')
			params(sb, p.params)
			strings.write_string(sb, " NIL NIL NIL")
		}
		strings.write_byte(sb, ')')
		return
	}
	iq(sb, strings.to_upper(p.main, context.temp_allocator))
	strings.write_byte(sb, ' ')
	iq(sb, strings.to_upper(p.sub, context.temp_allocator))
	strings.write_byte(sb, ' ')
	params(sb, p.params)
	strings.write_byte(sb, ' ')
	if p.cid == "" {
		strings.write_string(sb, "NIL")
	} else {
		iq(sb, strings.concatenate({"<", p.cid, ">"}, context.temp_allocator))
	}
	strings.write_string(sb, " NIL ") // Content-Description
	iq(sb, strings.to_upper(p.encoding, context.temp_allocator))
	strings.write_byte(sb, ' ')
	strings.write_int(sb, len(p.raw_body))
	if p.main == "text" {
		strings.write_byte(sb, ' ')
		strings.write_int(sb, p.lines)
	}
	if p.main == "message" && p.sub == "rfc822" && len(p.parts) == 1 {
		// envelope, body, lines — the envelope is served as NIL here, which is
		// a documented simplification of this test server.
		strings.write_string(sb, " NIL ")
		mm_bodystructure(&p.parts[0], sb, extended)
		strings.write_byte(sb, ' ')
		strings.write_int(sb, p.lines)
	}
	if extended {
		strings.write_string(sb, " NIL") // body MD5
		if p.disposition != "" || p.filename != "" {
			strings.write_string(sb, " (")
			iq(sb, strings.to_upper(p.disposition == "" ? "attachment" : p.disposition, context.temp_allocator))
			if p.filename != "" {
				strings.write_string(sb, " (\"FILENAME\" ")
				iq(sb, p.filename)
				strings.write_byte(sb, ')')
			} else {
				strings.write_string(sb, " NIL")
			}
			strings.write_byte(sb, ')')
		} else {
			strings.write_string(sb, " NIL")
		}
		strings.write_string(sb, " NIL NIL")
	}
	strings.write_byte(sb, ')')
}

// mm_envelope renders RFC 3501's ENVELOPE from the headers.
mm_envelope :: proc(raw: []u8, sb: ^strings.Builder) {
	headers, _ := mm_split(raw, context.temp_allocator)
	iq :: proc(sb: ^strings.Builder, s: string) {
		if s == "" {
			strings.write_string(sb, "NIL")
			return
		}
		strings.write_byte(sb, '"')
		for i in 0 ..< len(s) {
			if s[i] == '"' || s[i] == '\\' {strings.write_byte(sb, '\\')}
			strings.write_byte(sb, s[i])
		}
		strings.write_byte(sb, '"')
	}
	addrs :: proc(sb: ^strings.Builder, v: string) {
		if v == "" {
			strings.write_string(sb, "NIL")
			return
		}
		name, email := mm_first_addr(v, context.temp_allocator)
		strings.write_string(sb, "((")
		iq(sb, name)
		strings.write_string(sb, " NIL ")
		local := email
		domain := ""
		if at := strings.index_byte(email, '@'); at >= 0 {
			local = email[:at]
			domain = email[at + 1:]
		}
		iq(sb, local)
		strings.write_byte(sb, ' ')
		iq(sb, domain)
		strings.write_string(sb, "))")
	}
	g :: proc(headers: [][2]string, n: string) -> string {
		v, _ := mm_get(headers, n)
		return v
	}
	strings.write_byte(sb, '(')
	iq(sb, g(headers, "date"))
	strings.write_byte(sb, ' ')
	iq(sb, g(headers, "subject"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "from"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "sender") != "" ? g(headers, "sender") : g(headers, "from"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "reply-to") != "" ? g(headers, "reply-to") : g(headers, "from"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "to"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "cc"))
	strings.write_byte(sb, ' ')
	addrs(sb, g(headers, "bcc"))
	strings.write_byte(sb, ' ')
	iq(sb, g(headers, "in-reply-to"))
	strings.write_byte(sb, ' ')
	iq(sb, g(headers, "message-id"))
	strings.write_byte(sb, ')')
}
