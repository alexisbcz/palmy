// Just enough RFC 5322 / MIME to index a message: the headers that matter,
// the text a person would read, and the names (and, when cheap, the text)
// of its attachments.
//
// mailcore has a full parser, but it is `package main` and can't be
// imported; this one is deliberately smaller: no structure is kept, only
// text. Decoded: RFC 2047 encoded words (B and Q), quoted-printable,
// base64, UTF-8 / ISO-8859-1 / Windows-1252 / US-ASCII. HTML parts are
// used only when there is no plain one, with tags and scripts dropped and
// the common entities decoded.
package indexfeed

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Message :: struct {
	subject:     string,
	from:        string,
	from_addr:   string,
	to:          string, // decoded To and Cc, joined
	date:        i64,
	message_id:  string,
	in_reply_to: string,
	references:  string,
	machine:     bool, // a list, a bulk sender, an auto-reply, a no-reply
	body:        string,
	attachments: [dynamic]string,
}

@(private)
Header :: struct {
	name:  string, // lowercased
	value: string, // unfolded, raw
}

// split_headers separates the header block from the body and unfolds it.
@(private)
split_headers :: proc(raw: string) -> (hs: [dynamic]Header, body: string) {
	hs = make([dynamic]Header, context.temp_allocator)
	i := 0
	cur_name, cur_val := "", strings.builder_make(context.temp_allocator)
	have := false
	flush :: proc(hs: ^[dynamic]Header, name: string, val: ^strings.Builder, have: bool) {
		if have {
			append(hs, Header{strings.to_lower(name, context.temp_allocator), strings.clone(strings.trim_space(strings.to_string(val^)), context.temp_allocator)})
		}
		strings.builder_reset(val)
	}
	for i < len(raw) {
		j := strings.index_byte(raw[i:], '\n')
		line: string
		next: int
		if j < 0 {
			line = raw[i:]
			next = len(raw)
		} else {
			line = raw[i:i + j]
			next = i + j + 1
		}
		line = strings.trim_right(line, "\r")
		if line == "" {
			flush(&hs, cur_name, &cur_val, have)
			return hs, raw[next:]
		}
		if line[0] == ' ' || line[0] == '\t' {
			strings.write_byte(&cur_val, ' ')
			strings.write_string(&cur_val, strings.trim_space(line))
		} else {
			flush(&hs, cur_name, &cur_val, have)
			c := strings.index_byte(line, ':')
			if c > 0 {
				cur_name = line[:c]
				strings.write_string(&cur_val, line[c + 1:])
				have = true
			} else {
				have = false
			}
		}
		i = next
	}
	flush(&hs, cur_name, &cur_val, have)
	return hs, ""
}

@(private)
header :: proc(hs: []Header, name: string) -> string {
	for h in hs {
		if h.name == name {
			return h.value
		}
	}
	return ""
}

// param reads `name=value` out of a structured header (Content-Type,
// Content-Disposition), quoted or not, and RFC 2231 `name*=` in its
// simplest form.
@(private)
param :: proc(v, name: string) -> string {
	lower := strings.to_lower(v, context.temp_allocator)
	for key in ([2]string{name, strings.concatenate({name, "*"}, context.temp_allocator)}) {
		at := 0
		for {
			k := strings.index(lower[at:], key)
			if k < 0 {
				break
			}
			k += at
			e := k + len(key)
			before_ok := k == 0 || lower[k - 1] == ';' || lower[k - 1] == ' ' || lower[k - 1] == '\t'
			if before_ok && e < len(lower) && lower[e] == '=' {
				val := v[e + 1:]
				if len(val) > 0 && val[0] == '"' {
					end := strings.index_byte(val[1:], '"')
					if end >= 0 {
						return val[1:end + 1]
					}
					return val[1:]
				}
				end := strings.index_byte(val, ';')
				if end >= 0 {
					val = val[:end]
				}
				val = strings.trim_space(val)
				if strings.has_suffix(key, "*") {
					// charset'lang'percent-encoded
					if q := strings.last_index_byte(val, '\''); q >= 0 {
						val = percent_decode(val[q + 1:])
					}
				}
				return val
			}
			at = e
		}
	}
	return ""
}

@(private)
percent_decode :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// to_utf8 converts from a declared charset. Unknown charsets are kept as
// they are if they happen to be valid UTF-8, else read as Windows-1252,
// which is what mislabelled mail usually is.
to_utf8 :: proc(data: string, charset: string) -> string {
	cs := strings.to_lower(strings.trim(charset, "\" "), context.temp_allocator)
	switch cs {
	case "", "utf-8", "utf8", "us-ascii", "ascii":
		if utf8.valid_string(data) {
			return data
		}
	}
	if cs != "iso-8859-1" && cs != "latin1" && cs != "windows-1252" && cs != "cp1252" && cs != "iso-8859-15" && utf8.valid_string(data) {
		return data
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(data) {
		c := data[i]
		if c < 0x80 {
			strings.write_byte(&b, c)
		} else if c >= 0x80 && c < 0xa0 && cs != "iso-8859-1" {
			strings.write_rune(&b, CP1252_HIGH[c - 0x80])
		} else {
			strings.write_rune(&b, rune(c))
		}
	}
	return strings.to_string(b)
}

@(private)
CP1252_HIGH := [32]rune {
	'€', ' ', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', ' ', 'Ž', ' ',
	' ', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ', ' ', 'ž', 'Ÿ',
}

@(private)
qp_decode :: proc(s: string, header_mode := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if header_mode && c == '_' {
			strings.write_byte(&b, ' ')
			continue
		}
		if c == '=' {
			if i + 1 < len(s) && (s[i + 1] == '\n' || s[i + 1] == '\r') {
				i += 1
				if s[i] == '\r' && i + 1 < len(s) && s[i + 1] == '\n' {
					i += 1
				}
				continue
			}
			if i + 2 < len(s) {
				if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
					strings.write_byte(&b, u8(v))
					i += 2
					continue
				}
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

@(private)
b64_decode :: proc(s: string) -> string {
	clean := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/' {
			append(&clean, c)
		}
	}
	for len(clean) % 4 != 0 {
		append(&clean, '=')
	}
	out, err := base64.decode(string(clean[:]), allocator = context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(out)
}

// decode_words decodes RFC 2047 encoded words in a header value.
decode_words :: proc(v: string) -> string {
	if !strings.contains(v, "=?") {
		return to_utf8(v, "")
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	last_was_word := false
	for i < len(v) {
		s := strings.index(v[i:], "=?")
		if s < 0 {
			strings.write_string(&b, v[i:])
			break
		}
		gap := v[i:i + s]
		// Whitespace between two encoded words is dropped (RFC 2047 §6.2).
		if !(last_was_word && strings.trim_space(gap) == "") {
			strings.write_string(&b, gap)
		}
		rest := v[i + s + 2:]
		q1 := strings.index_byte(rest, '?')
		if q1 < 0 || q1 + 2 >= len(rest) || rest[q1 + 2] != '?' {
			strings.write_string(&b, "=?")
			i += s + 2
			last_was_word = false
			continue
		}
		charset := rest[:q1]
		if star := strings.index_byte(charset, '*'); star >= 0 {
			charset = charset[:star]
		}
		enc := rest[q1 + 1]
		text_start := q1 + 3
		end := strings.index(rest[text_start:], "?=")
		if end < 0 {
			strings.write_string(&b, "=?")
			i += s + 2
			last_was_word = false
			continue
		}
		payload := rest[text_start:text_start + end]
		dec: string
		switch enc {
		case 'B', 'b':
			dec = b64_decode(payload)
		case:
			dec = qp_decode(payload, true)
		}
		strings.write_string(&b, to_utf8(dec, charset))
		i += s + 2 + text_start + end + 2
		last_was_word = true
	}
	return strings.to_string(b)
}

MONTHS := [12]string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

// parse_date reads an RFC 5322 date ("Mon, 19 Oct 2026 09:14:00 +0200").
parse_mail_date :: proc(v: string) -> (i64, bool) {
	f := strings.fields(v, context.temp_allocator)
	k := 0
	if k < len(f) && strings.has_suffix(f[k], ",") {
		k += 1
	}
	if len(f) - k < 4 {
		return 0, false
	}
	d, dok := strconv.parse_int(f[k])
	mon := -1
	ml := strings.to_lower(f[k + 1], context.temp_allocator)
	for m, i in MONTHS {
		if strings.has_prefix(ml, m) {
			mon = i + 1
		}
	}
	y, yok := strconv.parse_int(f[k + 2])
	if !dok || !yok || mon < 0 {
		return 0, false
	}
	if y < 100 {
		y += y < 50 ? 2000 : 1900
	}
	hh, mm, ss := 0, 0, 0
	tp := strings.split(f[k + 3], ":", context.temp_allocator)
	if len(tp) >= 2 {
		hh, _ = strconv.parse_int(tp[0])
		mm, _ = strconv.parse_int(tp[1])
		if len(tp) > 2 {
			ss, _ = strconv.parse_int(tp[2])
		}
	}
	off := 0
	if len(f) > k + 4 {
		z := f[k + 4]
		if len(z) == 5 && (z[0] == '+' || z[0] == '-') {
			if n, ok := strconv.parse_int(z[1:]); ok {
				off = (n / 100) * 3600 + (n % 100) * 60
				if z[0] == '-' {
					off = -off
				}
			}
		}
	}
	t, ok := time.components_to_time(y, mon, d, hh, mm, ss)
	if !ok {
		return 0, false
	}
	return time.to_unix_seconds(t) - i64(off), true
}

// split_address cuts `Name <addr>` into its parts.
split_address :: proc(v: string) -> (name, addr: string) {
	if lt := strings.last_index_byte(v, '<'); lt >= 0 {
		gt := strings.index_byte(v[lt:], '>')
		addr = gt > 0 ? v[lt + 1:lt + gt] : v[lt + 1:]
		name = strings.trim(strings.trim_space(v[:lt]), "\"")
		return name, strings.to_lower(strings.trim_space(addr), context.temp_allocator)
	}
	return "", strings.to_lower(strings.trim_space(v), context.temp_allocator)
}

MACHINE_LOCALS := [?]string {
	"noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications", "notification",
	"mailer-daemon", "postmaster", "newsletter", "news", "billing", "alerts", "alert", "bounce",
	"bounces", "automated", "updates", "digest", "marketing", "receipts", "orders",
}

is_machine_address :: proc(addr: string) -> bool {
	at := strings.index_byte(addr, '@')
	local := at > 0 ? addr[:at] : addr
	for m in MACHINE_LOCALS {
		if local == m || strings.has_prefix(local, strings.concatenate({m, "+"}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

// html_text drops tags, scripts and styles, and decodes the common entities.
html_text :: proc(h: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	lower := strings.to_lower(h, context.temp_allocator)
	i := 0
	for i < len(h) {
		c := h[i]
		if c == '<' {
			for skip in ([2]string{"script", "style"}) {
				if strings.has_prefix(lower[i + 1:], skip) {
					end := strings.index(lower[i:], strings.concatenate({"</", skip}, context.temp_allocator))
					if end >= 0 {
						i += end
					}
				}
			}
			e := strings.index_byte(h[i:], '>')
			if e < 0 {
				break
			}
			tag := lower[i:i + e]
			if strings.has_prefix(tag, "<br") || strings.has_prefix(tag, "<p") || strings.has_prefix(tag, "</p") || strings.has_prefix(tag, "<div") || strings.has_prefix(tag, "<tr") || strings.has_prefix(tag, "<li") {
				strings.write_byte(&b, '\n')
			} else {
				strings.write_byte(&b, ' ')
			}
			i += e + 1
			continue
		}
		if c == '&' {
			semi := strings.index_byte(h[i:min(i + 10, len(h))], ';')
			if semi > 0 {
				ent := h[i + 1:i + semi]
				r: rune = -1
				switch ent {
				case "amp":
					r = '&'
				case "lt":
					r = '<'
				case "gt":
					r = '>'
				case "quot":
					r = '"'
				case "apos", "#39":
					r = '\''
				case "nbsp":
					r = ' '
				case "eacute":
					r = 'é'
				case "egrave":
					r = 'è'
				case "agrave":
					r = 'à'
				case "ccedil":
					r = 'ç'
				case:
					if len(ent) > 1 && ent[0] == '#' {
						if ent[1] == 'x' || ent[1] == 'X' {
							if n, ok := strconv.parse_int(ent[2:], 16); ok {
								r = rune(n)
							}
						} else if n, ok := strconv.parse_int(ent[1:]); ok {
							r = rune(n)
						}
					}
				}
				if r >= 0 {
					strings.write_rune(&b, r)
					i += semi + 1
					continue
				}
			}
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

// Office documents attached to a mail are opened when smaller than this.
MAX_ATTACH_EXTRACT :: 5 * 1024 * 1024

@(private)
walk_part :: proc(hs: []Header, body: string, m: ^Message, plain, html: ^strings.Builder, depth: int) {
	if depth > 8 {
		return
	}
	ct := header(hs, "content-type")
	ctl := strings.to_lower(ct, context.temp_allocator)
	cte := strings.to_lower(strings.trim_space(header(hs, "content-transfer-encoding")), context.temp_allocator)
	disp := header(hs, "content-disposition")
	name := param(disp, "filename")
	if name == "" {
		name = param(ct, "name")
	}
	name = decode_words(name)

	if strings.has_prefix(ctl, "multipart/") {
		boundary := param(ct, "boundary")
		if boundary == "" {
			return
		}
		delim := strings.concatenate({"--", boundary}, context.temp_allocator)
		parts := strings.split(body, delim, context.temp_allocator)
		for p, i in parts {
			if i == 0 || strings.has_prefix(p, "--") {
				continue
			}
			ph, pb := split_headers(strings.trim_left(p, "\r\n"))
			walk_part(ph[:], pb, m, plain, html, depth + 1)
		}
		return
	}
	if strings.has_prefix(ctl, "message/rfc822") {
		ph, pb := split_headers(body)
		if s := header(ph[:], "subject"); s != "" {
			strings.write_string(plain, "\n")
			strings.write_string(plain, decode_words(s))
			strings.write_string(plain, "\n")
		}
		walk_part(ph[:], pb, m, plain, html, depth + 1)
		return
	}
	decode :: proc(cte, body: string) -> string {
		switch cte {
		case "base64":
			return b64_decode(body)
		case "quoted-printable":
			return qp_decode(body)
		}
		return body
	}
	attached := name != "" || strings.has_prefix(strings.to_lower(strings.trim_space(disp), context.temp_allocator), "attachment")
	if attached {
		append(&m.attachments, strings.clone(name != "" ? name : "attachment", context.temp_allocator))
		// Cheap text: plain text attachments and office files, small ones.
		ln := strings.to_lower(name, context.temp_allocator)
		if (strings.has_prefix(ctl, "text/plain") || strings.has_suffix(ln, ".txt") || strings.has_suffix(ln, ".md") || strings.has_suffix(ln, ".csv")) && len(body) < 256 * 1024 {
			strings.write_string(plain, "\n")
			strings.write_string(plain, to_utf8(decode(cte, body), param(ct, "charset")))
		} else if office_kind(ln) != .None && len(body) < MAX_ATTACH_EXTRACT * 4 / 3 {
			if t, ok := office_text(transmute([]u8)decode(cte, body), office_kind(ln)); ok {
				strings.write_string(plain, "\n")
				strings.write_string(plain, t)
			}
		}
		return
	}
	if strings.has_prefix(ctl, "text/plain") || ct == "" {
		strings.write_string(plain, to_utf8(decode(cte, body), param(ct, "charset")))
		strings.write_byte(plain, '\n')
	} else if strings.has_prefix(ctl, "text/html") {
		strings.write_string(html, html_text(to_utf8(decode(cte, body), param(ct, "charset"))))
		strings.write_byte(html, '\n')
	}
}

// parse_message reads a whole message. Strings are temp-allocated.
parse_message :: proc(raw: string) -> Message {
	m: Message
	m.attachments = make([dynamic]string, context.temp_allocator)
	hs, body := split_headers(raw)
	m.subject = decode_words(header(hs[:], "subject"))
	from := decode_words(header(hs[:], "from"))
	fname, faddr := split_address(from)
	m.from = fname != "" ? strings.concatenate({fname, " ", faddr}, context.temp_allocator) : faddr
	m.from_addr = faddr
	to := decode_words(header(hs[:], "to"))
	cc := decode_words(header(hs[:], "cc"))
	m.to = cc != "" ? strings.concatenate({to, ", ", cc}, context.temp_allocator) : to
	m.date, _ = parse_mail_date(header(hs[:], "date"))
	m.message_id = strings.trim(strings.trim_space(header(hs[:], "message-id")), "<>")
	m.in_reply_to = header(hs[:], "in-reply-to")
	m.references = header(hs[:], "references")
	prec := strings.to_lower(header(hs[:], "precedence"), context.temp_allocator)
	auto := strings.to_lower(header(hs[:], "auto-submitted"), context.temp_allocator)
	m.machine = header(hs[:], "list-id") != "" || header(hs[:], "list-unsubscribe") != "" ||
		prec == "bulk" || prec == "list" || prec == "junk" || (auto != "" && auto != "no") || is_machine_address(faddr)
	plain := strings.builder_make(context.temp_allocator)
	html := strings.builder_make(context.temp_allocator)
	walk_part(hs[:], body, &m, &plain, &html, 0)
	text := strings.to_string(plain)
	if strings.trim_space(text) == "" {
		text = strings.to_string(html)
	}
	m.body = strip_quoted(text)
	return m
}

// strip_quoted drops the quoted history under a reply ("> " lines and an
// "On … wrote:" line before them): it is the earlier message's text, which
// is indexed already as that message, and leaving it in makes every reply
// in a thread match what the first one said.
strip_quoted :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	t := text
	pending := ""
	for line in strings.split_lines_iterator(&t) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, ">") {
			pending = ""
			continue
		}
		if strings.has_suffix(l, "wrote:") || strings.has_suffix(l, "a écrit :") || strings.has_suffix(l, "schrieb:") {
			pending = line
			continue
		}
		if pending != "" {
			strings.write_string(&b, pending)
			strings.write_byte(&b, '\n')
			pending = ""
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
