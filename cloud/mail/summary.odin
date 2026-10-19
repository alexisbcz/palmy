package main

// From raw RFC 5322 bytes to the two things the rest of the server needs:
//
//   - the header summary stored on the message row (subject, addresses,
//     message ids, date, preview, has-attachment), rendered as the `p_meta`
//     JSON the delivery functions take;
//   - the JMAP body properties (bodyStructure, textBody, htmlBody,
//     attachments, bodyValues), computed on demand from the stored blob.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Addr :: struct {
	name:  string,
	email: string,
}

Summary :: struct {
	subject:        string,
	message_id:     string,
	in_reply_to:    []string,
	references:     []string,
	from:           []Addr,
	sender:         []Addr,
	reply_to:       []Addr,
	to:             []Addr,
	cc:             []Addr,
	bcc:            []Addr,
	sent_at:        string, // RFC 3339, or ""
	preview:        string,
	has_attachment: bool,
}

// parse_addr_list reads an RFC 5322 address-list: commas outside quotes and
// angle brackets separate, `Name <a@b>` and bare `a@b` both work, a group's
// `label:` and `;` are dropped and its members kept.
parse_addr_list :: proc(v: string) -> []Addr {
	out := make([dynamic]Addr, 0, 2, context.temp_allocator)
	s := v
	items := make([dynamic]string, 0, 4, context.temp_allocator)
	in_q, depth, start := false, 0, 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '"':
			in_q = !in_q
		case '<':
			if !in_q {depth += 1}
		case '>':
			if !in_q && depth > 0 {depth -= 1}
		case ',', ';':
			if !in_q && depth == 0 {
				append(&items, s[start:i])
				start = i + 1
			}
		}
	}
	append(&items, s[start:])
	for raw in items {
		it := strings.trim_space(raw)
		// A group label: "Team: a@b" — a colon before any quote or bracket.
		if c := strings.index_byte(it, ':'); c >= 0 && strings.index_any(it[:c], "\"<") < 0 {
			it = strings.trim_space(it[c + 1:])
		}
		if it == "" {
			continue
		}
		a: Addr
		if lt := strings.last_index_byte(it, '<'); lt >= 0 {
			gt := strings.index_byte(it[lt:], '>')
			a.email = gt < 0 ? strings.trim_space(it[lt + 1:]) : strings.trim_space(it[lt + 1:lt + gt])
			n := strings.trim_space(it[:lt])
			if len(n) >= 2 && n[0] == '"' && n[len(n) - 1] == '"' {
				n = n[1:len(n) - 1]
			}
			a.name = mm_decode_words(n, context.temp_allocator)
		} else {
			// `a@b (Comment Name)` — the old comment form.
			if p := strings.index_byte(it, '('); p > 0 {
				a.name = strings.trim(strings.trim_space(it[p:]), "()")
				it = strings.trim_space(it[:p])
			}
			a.email = it
		}
		if strings.index_byte(a.email, '@') < 0 {
			continue
		}
		append(&out, a)
	}
	return out[:]
}

MONTHS := [12]string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

// parse_rfc5322_date: `[Day, ] DD Mon YYYY HH:MM[:SS] (+|-)HHMM`, plus the
// obsolete zone names that still turn up (GMT, UT, EST...). Returns unix time.
parse_rfc5322_date :: proc(v: string) -> (unix: i64, ok: bool) {
	s := strings.trim_space(v)
	if c := strings.index_byte(s, ','); c >= 0 {
		s = strings.trim_space(s[c + 1:])
	}
	if p := strings.index_byte(s, '('); p >= 0 {
		s = strings.trim_space(s[:p])
	}
	f := strings.fields(s, context.temp_allocator)
	if len(f) < 4 {
		return 0, false
	}
	day, d_ok := strconv.parse_int(f[0], 10)
	mon := -1
	ml := strings.to_lower(f[1], context.temp_allocator)
	for m, i in MONTHS {
		if strings.has_prefix(ml, m) {
			mon = i + 1
		}
	}
	year, y_ok := strconv.parse_int(f[2], 10)
	if !d_ok || !y_ok || mon < 0 {
		return 0, false
	}
	if year < 50 {
		year += 2000
	} else if year < 1000 {
		year += 1900
	}
	tparts := strings.split(f[3], ":", context.temp_allocator)
	if len(tparts) < 2 {
		return 0, false
	}
	hh, _ := strconv.parse_int(tparts[0], 10)
	mi, _ := strconv.parse_int(tparts[1], 10)
	ss := 0
	if len(tparts) > 2 {
		ss, _ = strconv.parse_int(tparts[2], 10)
	}
	off := 0
	if len(f) > 4 {
		z := f[4]
		if len(z) == 5 && (z[0] == '+' || z[0] == '-') {
			zh, _ := strconv.parse_int(z[1:3], 10)
			zm, _ := strconv.parse_int(z[3:5], 10)
			off = zh * 3600 + zm * 60
			if z[0] == '-' {off = -off}
		} else {
			switch strings.to_upper(z, context.temp_allocator) {
			case "EDT":
				off = -4 * 3600
			case "EST", "CDT":
				off = -5 * 3600
			case "CST", "MDT":
				off = -6 * 3600
			case "MST", "PDT":
				off = -7 * 3600
			case "PST":
				off = -8 * 3600
			}
		}
	}
	days := days_from_civil(year, mon, day)
	return days * 86400 + i64(hh * 3600 + mi * 60 + ss) - i64(off), true
}

iso8601 :: proc(unix: i64, allocator := context.temp_allocator) -> string {
	days := unix / 86400
	secs := unix % 86400
	if secs < 0 {secs += 86400;days -= 1}
	y, mo, d := civil_from_days(days)
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, mo, d, secs / 3600, secs / 60 % 60, secs % 60, allocator = allocator)
}

rfc5322_date_now :: proc() -> string {
	DAYS := [7]string{"Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"}
	MON := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	unix := time.time_to_unix(time.now())
	days := unix / 86400
	secs := unix % 86400
	y, mo, d := civil_from_days(days)
	return fmt.tprintf("%s, %d %s %04d %02d:%02d:%02d +0000", DAYS[days % 7], d, MON[mo - 1], y, secs / 3600, secs / 60 % 60, secs % 60)
}

days_from_civil :: proc(y_in, m, d: int) -> i64 {
	y := y_in
	y -= m <= 2 ? 1 : 0
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return i64(era) * 146097 + i64(doe) - 719468
}

civil_from_days :: proc(z_in: i64) -> (y, m, d: int) {
	z := z_in + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	dd := doy - (153 * mp + 2) / 5 + 1
	mm := mp + (mp < 10 ? 3 : -9)
	return int(yy + (mm <= 2 ? 1 : 0)), int(mm), int(dd)
}

// strip_html is for the preview only: tags dropped, entities for the common
// five decoded, nothing fetched.
strip_html :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	in_tag := false
	lower := strings.to_lower(s, context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if !in_tag && s[i] == '<' {
			// Skip <style> and <script> bodies whole.
			for tag in ([]string{"<style", "<script"}) {
				if strings.has_prefix(lower[i:], tag) {
					close := strings.concatenate({"</", tag[1:]}, context.temp_allocator)
					if e := strings.index(lower[i:], close); e >= 0 {
						i += e
					}
				}
			}
			in_tag = true
			continue
		}
		if in_tag {
			if s[i] == '>' {
				in_tag = false
				strings.write_byte(&sb, ' ')
			}
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	out := strings.to_string(sb)
	for pair in ([][2]string{{"&nbsp;", " "}, {"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}}) {
		out, _ = strings.replace_all(out, pair[0], pair[1], context.temp_allocator)
	}
	return out
}

// make_preview: whitespace collapsed, quoted lines skipped, cut at 256 bytes
// on a UTF-8 boundary (RFC 8621 4.1.4 says "up to 256 characters").
make_preview :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rest := text
	space := false
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, ">") {
			continue
		}
		for r in l {
			if r == ' ' || r == '\t' {
				space = true
				continue
			}
			if space && strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, ' ')
			}
			space = false
			strings.write_rune(&sb, r)
		}
		space = true
		if strings.builder_len(sb) > 300 {
			break
		}
	}
	out := strings.to_string(sb)
	if len(out) > 256 {
		cut := 256
		for cut > 0 && !utf8.rune_start(out[cut]) {
			cut -= 1
		}
		out = out[:cut]
	}
	return out
}

// Body_Leaf is one non-multipart part, in document order.
Body_Leaf :: struct {
	part: ^MM_Part,
	id:   string, // partId: the section number, "1" for a single-part message
}

Body_Split :: struct {
	text_body:   [dynamic]Body_Leaf,
	html_body:   [dynamic]Body_Leaf,
	attachments: [dynamic]Body_Leaf,
}

// split_body follows RFC 8621 4.1.4's parsing algorithm in a simplified form:
// inline text parts go to textBody/htmlBody (an alternative's plain side to
// textBody, its HTML side to htmlBody, a lone part to both), everything else
// is an attachment.
split_body :: proc(root: ^MM_Part) -> Body_Split {
	bs := Body_Split {
		text_body   = make([dynamic]Body_Leaf, 0, 2, context.temp_allocator),
		html_body   = make([dynamic]Body_Leaf, 0, 2, context.temp_allocator),
		attachments = make([dynamic]Body_Leaf, 0, 2, context.temp_allocator),
	}
	walk :: proc(p: ^MM_Part, bs: ^Body_Split, in_alt: bool) {
		if p.main == "multipart" {
			alt := p.sub == "alternative"
			for i in 0 ..< len(p.parts) {
				walk(&p.parts[i], bs, alt || in_alt)
			}
			return
		}
		leaf := Body_Leaf{part = p, id = p.section == "" ? "1" : p.section}
		is_att := p.disposition == "attachment" || (p.filename != "" && p.main != "text")
		if p.main == "text" && !is_att && (p.sub == "plain" || p.sub == "html") {
			if p.sub == "plain" {
				append(&bs.text_body, leaf)
				if !in_alt {append(&bs.html_body, leaf)}
			} else {
				append(&bs.html_body, leaf)
				if !in_alt {append(&bs.text_body, leaf)}
			}
			return
		}
		append(&bs.attachments, leaf)
	}
	walk(root, &bs, false)
	return bs
}

summarise :: proc(raw: []u8) -> Summary {
	s: Summary
	headers, _ := mm_split(raw, context.temp_allocator)
	if v, ok := mm_get(headers, "subject"); ok {
		s.subject = mm_decode_words(v, context.temp_allocator)
	}
	addr :: proc(headers: [][2]string, name: string) -> []Addr {
		all := mm_get_all(headers, name, context.temp_allocator)
		return parse_addr_list(strings.join(all, ", ", context.temp_allocator))
	}
	s.from = addr(headers, "from")
	s.sender = addr(headers, "sender")
	s.reply_to = addr(headers, "reply-to")
	s.to = addr(headers, "to")
	s.cc = addr(headers, "cc")
	s.bcc = addr(headers, "bcc")
	if v, ok := mm_get(headers, "message-id"); ok {
		ids := mm_ids(v, context.temp_allocator)
		if len(ids) > 0 {s.message_id = ids[0]}
	}
	irt := make([dynamic]string, 0, 2, context.temp_allocator)
	for v in mm_get_all(headers, "in-reply-to", context.temp_allocator) {
		append(&irt, ..mm_ids(v, context.temp_allocator))
	}
	s.in_reply_to = irt[:]
	refs := make([dynamic]string, 0, 4, context.temp_allocator)
	for v in mm_get_all(headers, "references", context.temp_allocator) {
		append(&refs, ..mm_ids(v, context.temp_allocator))
	}
	s.references = refs[:]
	if v, ok := mm_get(headers, "date"); ok {
		if u, dok := parse_rfc5322_date(v); dok {
			s.sent_at = iso8601(u)
		}
	}
	root := mm_parse(raw, "", 0, context.temp_allocator)
	bs := split_body(&root)
	s.has_attachment = len(bs.attachments) > 0
	if len(bs.text_body) > 0 {
		p := bs.text_body[0].part
		s.preview = make_preview(p.sub == "html" ? strip_html(p.text) : p.text)
	} else if len(bs.html_body) > 0 {
		s.preview = make_preview(strip_html(bs.html_body[0].part.text))
	}
	return s
}

addrs_json :: proc(as: []Addr) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	for a, i in as {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, `{{"name":%s,"email":%s}}`, jq_null(a.name), jq(a.email))
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

// summary_meta renders the `p_meta` argument of mail_deliver / mail_submit.
summary_meta :: proc(s: Summary) -> string {
	return fmt.tprintf(
		`{{"subject":%s,"messageId":%s,"inReplyTo":%s,"references":%s,"from":%s,"sender":%s,"replyTo":%s,"to":%s,"cc":%s,"bcc":%s,"sentAt":%s,"preview":%s,"hasAttachment":%v}}`,
		jq(s.subject),
		jq(s.message_id),
		jq_list(s.in_reply_to),
		jq_list(s.references),
		addrs_json(s.from),
		addrs_json(s.sender),
		addrs_json(s.reply_to),
		addrs_json(s.to),
		addrs_json(s.cc),
		addrs_json(s.bcc),
		jq_null(s.sent_at),
		jq(s.preview),
		s.has_attachment,
	)
}

// ---------------------------------------------------------------------------
// JMAP body properties
// ---------------------------------------------------------------------------

part_type :: proc(p: ^MM_Part) -> string {
	return fmt.tprintf("%s/%s", p.main, p.sub)
}

// part_json renders an EmailBodyPart (RFC 8621 4.1.4). Leaf parts get a blobId
// of the form <message blob>.<partId>, which the download endpoint resolves
// by re-walking the message.
part_json :: proc(p: ^MM_Part, id, blob: string, deep: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	if p.main == "multipart" {
		fmt.sbprintf(&sb, `"partId":null,"blobId":null,"type":%s,"size":0`, jq(part_type(p)))
		if deep {
			strings.write_string(&sb, `,"subParts":[`)
			for i in 0 ..< len(p.parts) {
				if i > 0 {strings.write_byte(&sb, ',')}
				cid := p.parts[i].section == "" ? "1" : p.parts[i].section
				strings.write_string(&sb, part_json(&p.parts[i], cid, blob, true))
			}
			strings.write_byte(&sb, ']')
		}
	} else {
		fmt.sbprintf(
			&sb,
			`"partId":%s,"blobId":%s,"type":%s,"size":%d`,
			jq(id),
			jq(fmt.tprintf("%s.%s", blob, id)),
			jq(part_type(p)),
			len(p.decoded),
		)
		if p.main == "text" {
			fmt.sbprintf(&sb, `,"charset":%s`, jq(strings.to_lower(p.charset, context.temp_allocator)))
		} else {
			strings.write_string(&sb, `,"charset":null`)
		}
	}
	fmt.sbprintf(&sb, `,"name":%s,"disposition":%s,"cid":%s,"language":null,"location":null}}`,
		jq_null(mm_decode_words(p.filename, context.temp_allocator)), jq_null(p.disposition), jq_null(p.cid))
	return strings.to_string(sb)
}

// find_part locates a leaf by partId.
find_part :: proc(p: ^MM_Part, id: string) -> ^MM_Part {
	pid := p.section == "" ? "1" : p.section
	if p.main != "multipart" && pid == id {
		return p
	}
	for i in 0 ..< len(p.parts) {
		if f := find_part(&p.parts[i], id); f != nil {
			return f
		}
	}
	return nil
}
