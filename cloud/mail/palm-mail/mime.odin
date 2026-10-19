package main

// Just enough RFC 5322 / MIME to read a message the way its recipient sees
// it, and to write a draft with attachments. Reading prefers the HTML part
// when there is one, because that is what a mail client shows: an attacker
// who puts one thing in text/plain and another in text/html is aiming at
// whichever the model reads, and the answer is that the model reads what the
// person reads.

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"

Part :: struct {
	ctype:    string, // lower-case, without parameters
	charset:  string,
	filename: string,
	body:     []u8, // decoded
}

Parsed :: struct {
	headers: map[string]string, // lower-case name -> unfolded value (first occurrence)
	parts:   [dynamic]Part, // leaves, in order
}

@(private = "file")
split_head :: proc(raw: string) -> (head, body: string) {
	if i := strings.index(raw, "\r\n\r\n"); i >= 0 {
		return raw[:i], raw[i + 4:]
	}
	if i := strings.index(raw, "\n\n"); i >= 0 {
		return raw[:i], raw[i + 2:]
	}
	return raw, ""
}

@(private = "file")
parse_headers :: proc(head: string, allocator := context.temp_allocator) -> map[string]string {
	m := make(map[string]string, allocator = allocator)
	lines := strings.split_lines(head, context.temp_allocator)
	cur_name := ""
	cur := strings.builder_make(context.temp_allocator)
	flush :: proc(m: ^map[string]string, name: string, b: ^strings.Builder, allocator := context.temp_allocator) {
		if name != "" && !(name in m) {
			m[strings.clone(name, allocator)] = strings.clone(strings.trim_space(strings.to_string(b^)), allocator)
		}
		strings.builder_reset(b)
	}
	for l in lines {
		line := strings.trim_right(l, "\r")
		if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
			strings.write_byte(&cur, ' ')
			strings.write_string(&cur, strings.trim_space(line))
			continue
		}
		flush(&m, cur_name, &cur, allocator)
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			cur_name = ""
			continue
		}
		cur_name = strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		strings.write_string(&cur, line[colon + 1:])
	}
	flush(&m, cur_name, &cur, allocator)
	return m
}

// param reads `name=value` out of a Content-Type or Content-Disposition.
param :: proc(v, name: string) -> string {
	lv := strings.to_lower(v, context.temp_allocator)
	key := fmt.tprintf("%s=", name)
	i := strings.index(lv, key)
	for i > 0 && lv[i - 1] != ';' && lv[i - 1] != ' ' && lv[i - 1] != '\t' {
		j := strings.index(lv[i + 1:], key)
		if j < 0 {return ""}
		i = i + 1 + j
	}
	if i < 0 {return ""}
	rest := v[i + len(key):]
	if strings.has_prefix(rest, "\"") {
		end := strings.index_byte(rest[1:], '"')
		return end < 0 ? rest[1:] : rest[1:1 + end]
	}
	end := strings.index_any(rest, "; \t")
	return end < 0 ? rest : rest[:end]
}

@(private = "file")
unhex :: proc(c: u8) -> (u8, bool) {
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

quoted_printable :: proc(s: string, underscores := false, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '=' {
			if i + 1 < len(s) && (s[i + 1] == '\n' || s[i + 1] == '\r') {
				i += 1
				if s[i] == '\r' && i + 1 < len(s) && s[i + 1] == '\n' {i += 1}
				i += 1
				continue
			}
			if i + 2 < len(s) {
				h, ok1 := unhex(s[i + 1])
				l, ok2 := unhex(s[i + 2])
				if ok1 && ok2 {
					append(&out, h << 4 | l)
					i += 3
					continue
				}
			}
		}
		if underscores && c == '_' {
			append(&out, ' ')
		} else {
			append(&out, c)
		}
		i += 1
	}
	return out[:]
}

@(private = "file")
b64 :: proc(s: string, allocator := context.temp_allocator) -> []u8 {
	clean := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=' {
			strings.write_byte(&clean, c)
		}
	}
	data, err := base64.decode(strings.to_string(clean), allocator = allocator)
	if err != nil {return nil}
	return data
}

// latin1 widens ISO-8859-1 (and, close enough, Windows-1252) to UTF-8.
@(private = "file")
latin1 :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c in b {strings.write_rune(&sb, rune(c))}
	return strings.to_string(sb)
}

as_text :: proc(p: Part, allocator := context.temp_allocator) -> string {
	cs := strings.to_lower(p.charset, context.temp_allocator)
	if cs == "iso-8859-1" || cs == "latin1" || cs == "windows-1252" {
		return latin1(p.body, allocator)
	}
	return strings.clone(string(p.body), allocator)
}

// decode_words decodes RFC 2047 encoded words in a header value.
decode_words :: proc(v: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(v, "=?") {return strings.clone(v, allocator)}
	out := strings.builder_make(allocator)
	i := 0
	last_was_word := false
	for i < len(v) {
		if strings.has_prefix(v[i:], "=?") {
			end := strings.index(v[i + 2:], "?=")
			// charset?enc?text?=
			inner := end < 0 ? "" : v[i + 2:i + 2 + end]
			parts := strings.split(inner, "?", context.temp_allocator)
			if len(parts) == 3 {
				data: []u8
				switch strings.to_lower(parts[1], context.temp_allocator) {
				case "b":
					data = b64(parts[2])
				case "q":
					data = quoted_printable(parts[2], true)
				}
				p := Part{charset = parts[0], body = data}
				strings.write_string(&out, as_text(p))
				i += 2 + end + 2
				last_was_word = true
				continue
			}
		}
		// Whitespace between two encoded words is not shown.
		if last_was_word && (v[i] == ' ' || v[i] == '\t') {
			j := i
			for j < len(v) && (v[j] == ' ' || v[j] == '\t') {j += 1}
			if strings.has_prefix(v[j:], "=?") {
				i = j
				continue
			}
		}
		strings.write_byte(&out, v[i])
		last_was_word = false
		i += 1
	}
	return strings.to_string(out)
}

@(private = "file")
walk :: proc(p: ^Parsed, raw: string, depth: int) {
	if depth > 8 {return}
	head, body := split_head(raw)
	hs := parse_headers(head)
	ct := hs["content-type"] or_else "text/plain; charset=us-ascii"
	semi := strings.index_byte(ct, ';')
	ctype := strings.to_lower(strings.trim_space(semi < 0 ? ct : ct[:semi]), context.temp_allocator)
	if strings.has_prefix(ctype, "multipart/") {
		boundary := param(ct, "boundary")
		if boundary == "" {return}
		delim := fmt.tprintf("--%s", boundary)
		chunks := strings.split(body, delim, context.temp_allocator)
		for chunk, k in chunks {
			if k == 0 {continue} // the preamble
			if strings.has_prefix(chunk, "--") {break} // the close delimiter
			c := strings.trim_prefix(strings.trim_prefix(chunk, "\r\n"), "\n")
			walk(p, c, depth + 1)
		}
		return
	}
	if ctype == "message/rfc822" {
		walk(p, body, depth + 1)
		return
	}
	enc := strings.to_lower(strings.trim_space(hs["content-transfer-encoding"] or_else ""), context.temp_allocator)
	data: []u8
	switch enc {
	case "base64":
		data = b64(body)
	case "quoted-printable":
		data = quoted_printable(body)
	case:
		data = transmute([]u8)strings.clone(body, context.temp_allocator)
	}
	disp := hs["content-disposition"] or_else ""
	name := param(disp, "filename")
	if name == "" {name = param(ct, "name")}
	append(&p.parts, Part{ctype = ctype, charset = param(ct, "charset"), filename = decode_words(name), body = data})
}

parse :: proc(raw: string) -> Parsed {
	p := Parsed{parts = make([dynamic]Part, context.temp_allocator)}
	head, _ := split_head(raw)
	p.headers = parse_headers(head)
	walk(&p, raw, 0)
	return p
}

// best_body picks what the recipient's client would show: the first HTML
// part that is not an attachment, else the first plain part.
best_body :: proc(p: Parsed) -> (body: string, is_html: bool) {
	for part in p.parts {
		if part.ctype == "text/html" && part.filename == "" {
			return as_text(part), true
		}
	}
	for part in p.parts {
		if part.ctype == "text/plain" && part.filename == "" {
			return as_text(part), false
		}
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

Attachment :: struct {
	name:  string,
	ctype: string,
	data:  []u8,
}

Draft :: struct {
	from_name:   string,
	from:        string,
	to:          []string,
	cc:          []string,
	subject:     string,
	body:        string,
	in_reply_to: string,
	references:  string,
	message_id:  string,
	attachments: []Attachment,
}

@(private = "file")
needs_encoding :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if c >= 0x80 || c < 0x20 {return true}
	}
	return false
}

encode_header :: proc(s: string) -> string {
	if !needs_encoding(s) {return s}
	return fmt.tprintf("=?UTF-8?B?%s?=", base64.encode(transmute([]u8)s, allocator = context.temp_allocator))
}

@(private = "file")
wrap76 :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 76 {
		strings.write_string(b, s[i:min(i + 76, len(s))])
		strings.write_string(b, "\r\n")
	}
}

guess_type :: proc(name: string) -> string {
	n := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.has_suffix(n, ".pdf"): return "application/pdf"
	case strings.has_suffix(n, ".txt"): return "text/plain"
	case strings.has_suffix(n, ".md"): return "text/markdown"
	case strings.has_suffix(n, ".csv"): return "text/csv"
	case strings.has_suffix(n, ".png"): return "image/png"
	case strings.has_suffix(n, ".jpg"), strings.has_suffix(n, ".jpeg"): return "image/jpeg"
	case strings.has_suffix(n, ".docx"): return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	case strings.has_suffix(n, ".xlsx"): return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	}
	return "application/octet-stream"
}

rfc2822_now :: proc() -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	wd := time.weekday(now)
	days := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s, %02d %s %d %02d:%02d:%02d +0000", days[int(wd)], d, months[int(mo) - 1], y, h, mi, s)
}

build :: proc(d: Draft, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	from := d.from_name != "" ? fmt.tprintf("%s <%s>", encode_header(d.from_name), d.from) : d.from
	fmt.sbprintf(&b, "From: %s\r\n", from)
	if len(d.to) > 0 {fmt.sbprintf(&b, "To: %s\r\n", strings.join(d.to, ", ", context.temp_allocator))}
	if len(d.cc) > 0 {fmt.sbprintf(&b, "Cc: %s\r\n", strings.join(d.cc, ", ", context.temp_allocator))}
	fmt.sbprintf(&b, "Subject: %s\r\n", encode_header(d.subject))
	fmt.sbprintf(&b, "Date: %s\r\n", rfc2822_now())
	fmt.sbprintf(&b, "Message-ID: <%s>\r\n", d.message_id)
	if d.in_reply_to != "" {fmt.sbprintf(&b, "In-Reply-To: <%s>\r\n", d.in_reply_to)}
	if d.references != "" {fmt.sbprintf(&b, "References: %s\r\n", d.references)}
	strings.write_string(&b, "MIME-Version: 1.0\r\n")
	if len(d.attachments) == 0 {
		strings.write_string(&b, "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n")
		wrap76(&b, base64.encode(transmute([]u8)d.body, allocator = context.temp_allocator))
		return strings.to_string(b)
	}
	boundary := fmt.tprintf("palm-%s", d.message_id[:min(16, len(d.message_id))])
	fmt.sbprintf(&b, "Content-Type: multipart/mixed; boundary=\"%s\"\r\n\r\n", boundary)
	fmt.sbprintf(&b, "--%s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", boundary)
	wrap76(&b, base64.encode(transmute([]u8)d.body, allocator = context.temp_allocator))
	for a in d.attachments {
		fmt.sbprintf(&b, "--%s\r\nContent-Type: %s; name=\"%s\"\r\nContent-Disposition: attachment; filename=\"%s\"\r\nContent-Transfer-Encoding: base64\r\n\r\n",
			boundary, a.ctype, a.name, a.name)
		wrap76(&b, base64.encode(a.data, allocator = context.temp_allocator))
	}
	fmt.sbprintf(&b, "--%s--\r\n", boundary)
	return strings.to_string(b)
}
