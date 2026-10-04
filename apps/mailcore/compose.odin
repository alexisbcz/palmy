package main

// Building a correct outgoing message.
//
// The structure is chosen from what the caller supplies, following RFC 2046
// rather than guessing:
//
//	text only                      -> text/plain
//	text + html                    -> multipart/alternative
//	bodies + inline images (cid:)  -> multipart/related { alternative, images }
//	bodies + attachments           -> multipart/mixed   { related-or-alt, files }
//
// A boundary is checked against the whole payload before it is used, so it
// cannot possibly appear inside a part — the failure mode that truncates a
// message in every client that receives it.

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

Compose_Attachment :: struct {
	filename:   string,
	mime_type:  string, // defaults to application/octet-stream
	content:    []u8,
	is_inline:  bool,
	content_id: string, // required for `is_inline` so the HTML can cid: it
}

Compose :: struct {
	from:        Address,
	to:          []Address,
	cc:          []Address,
	bcc:         []Address, // kept out of the headers; envelope only
	reply_to:    []Address,
	subject:     string,
	text:        string, // UTF-8
	html:        string, // UTF-8
	attachments: []Compose_Attachment,
	in_reply_to: string, // bare Message-ID, no angle brackets
	references:  []string,
	message_id:  string, // generated when empty
	date_unix:   i64, // 0 means "now"
	tz_minutes:  int,
	user_agent:  string,
}

@(private = "file")
uniq_counter: int

// unique_token is good enough for a boundary or a Message-ID left-hand side:
// the nanosecond clock, the pid and a per-process counter cannot collide
// within one machine, and mailcore never leaves one.
@(private = "file")
unique_token :: proc(allocator := context.allocator) -> string {
	uniq_counter += 1
	ns := time.to_unix_nanoseconds(time.now())
	return fmt.aprintf(
		"%x%x%x",
		u64(ns),
		u32(linux.getpid()),
		u32(uniq_counter),
		allocator = allocator,
	)
}

generate_message_id :: proc(domain := "localhost", allocator := context.allocator) -> string {
	return fmt.aprintf("%s.mailcore@%s", unique_token(context.temp_allocator), domain, allocator = allocator)
}

// make_boundary returns a delimiter that does not occur in `payloads`.
@(private = "file")
make_boundary :: proc(payloads: []string, allocator := context.allocator) -> string {
	for attempt in 0 ..< 64 {
		cand := fmt.aprintf("=_palmy_%s_%d", unique_token(context.temp_allocator), attempt, allocator = allocator)
		clash := false
		for p in payloads {
			if strings.contains(p, cand) {
				clash = true
				break
			}
		}
		if !clash {
			return cand
		}
	}
	// Unreachable in practice; still must not return something unsafe.
	return fmt.aprintf("=_palmy_fallback_%s", unique_token(context.temp_allocator), allocator = allocator)
}

@(private = "file")
addr_list :: proc(sb: ^strings.Builder, label: string, addrs: []Address) {
	if len(addrs) == 0 {
		return
	}
	fmt.sbprintf(sb, "%s: ", label)
	for a, i in addrs {
		if i > 0 {
			strings.write_string(sb, ", ")
		}
		if a.name != "" {
			enc := encode_header_value(a.name, context.temp_allocator)
			// A display name that is still raw UTF-8-free text may contain
			// specials, so quote it unless it is an encoded word.
			if strings.has_prefix(enc, "=?") {
				strings.write_string(sb, enc)
			} else {
				strings.write_byte(sb, '"')
				for i2 in 0 ..< len(enc) {
					if enc[i2] == '"' || enc[i2] == '\\' {
						strings.write_byte(sb, '\\')
					}
					strings.write_byte(sb, enc[i2])
				}
				strings.write_byte(sb, '"')
			}
			fmt.sbprintf(sb, " <%s>", a.email)
		} else {
			fmt.sbprintf(sb, "<%s>", a.email)
		}
	}
	strings.write_string(sb, "\r\n")
}

// fold_header breaks a long structured header at 76 columns using RFC 5322
// folding white space. Only used for References, which is the one header that
// routinely exceeds the limit.
@(private = "file")
fold_ids :: proc(sb: ^strings.Builder, label: string, ids: []string) {
	if len(ids) == 0 {
		return
	}
	fmt.sbprintf(sb, "%s:", label)
	col := len(label) + 1
	for id in ids {
		tok := fmt.tprintf(" <%s>", id)
		if col + len(tok) > 76 {
			strings.write_string(sb, "\r\n ")
			col = 1
		}
		strings.write_string(sb, tok)
		col += len(tok)
	}
	strings.write_string(sb, "\r\n")
}

@(private = "file")
needs_qp :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch >= 0x80 || ch == 0 {
			return true
		}
	}
	// A line longer than 998 octets is illegal in RFC 5322.
	longest, cur := 0, 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			if cur > longest {longest = cur}
			cur = 0
			continue
		}
		cur += 1
	}
	if cur > longest {longest = cur}
	return longest > 900
}

@(private = "file")
write_text_part :: proc(sb: ^strings.Builder, subtype, body: string) {
	fmt.sbprintf(sb, "Content-Type: text/%s; charset=\"UTF-8\"\r\n", subtype)
	if needs_qp(body) {
		strings.write_string(sb, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
		strings.write_string(sb, qp_encode(transmute([]u8)body, context.temp_allocator))
	} else {
		strings.write_string(sb, "Content-Transfer-Encoding: 7bit\r\n\r\n")
		strings.write_string(sb, crlf(body, context.temp_allocator))
	}
	if !strings.has_suffix(strings.to_string(sb^), "\r\n") {
		strings.write_string(sb, "\r\n")
	}
}

crlf :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, "\n") {
		return strings.clone(s, allocator)
	}
	out := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\r' {
			continue
		}
		if s[i] == '\n' {
			strings.write_string(&out, "\r\n")
			continue
		}
		strings.write_byte(&out, s[i])
	}
	return strings.to_string(out)
}

@(private = "file")
write_attachment :: proc(sb: ^strings.Builder, a: Compose_Attachment) {
	ct := a.mime_type != "" ? a.mime_type : "application/octet-stream"
	fmt.sbprintf(sb, "Content-Type: %s", ct)
	if a.filename != "" {
		// `name` on Content-Type is deprecated but every client still reads
		// it, and RFC 2231 is how a non-ASCII name travels.
		fmt.sbprintf(sb, ";\r\n name%s", encode_param(a.filename, context.temp_allocator))
	}
	strings.write_string(sb, "\r\n")
	strings.write_string(sb, "Content-Transfer-Encoding: base64\r\n")
	if a.content_id != "" {
		fmt.sbprintf(sb, "Content-ID: <%s>\r\n", a.content_id)
	}
	fmt.sbprintf(sb, "Content-Disposition: %s", a.is_inline ? "inline" : "attachment")
	if a.filename != "" {
		fmt.sbprintf(sb, ";\r\n filename%s", encode_param(a.filename, context.temp_allocator))
	}
	strings.write_string(sb, "\r\n\r\n")
	strings.write_string(sb, base64_encode(a.content, 76, context.temp_allocator))
	strings.write_string(sb, "\r\n")
}

// encode_param writes a parameter ASSIGNMENT, not just the value: `="plain"`
// for ASCII, `*=UTF-8''pct-encoded` for anything else. It includes the `=`
// because RFC 2231's extended form puts a `*` before it, so the caller cannot
// write the `=` itself without getting `filename=*=UTF-8''...`.
encode_param :: proc(v: string, allocator := context.allocator) -> string {
	ascii := true
	for i in 0 ..< len(v) {
		if v[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		sb := strings.builder_make(allocator)
		strings.write_string(&sb, "=\"")
		for i in 0 ..< len(v) {
			if v[i] == '"' || v[i] == '\\' {
				strings.write_byte(&sb, '\\')
			}
			strings.write_byte(&sb, v[i])
		}
		strings.write_byte(&sb, '"')
		return strings.to_string(sb)
	}
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "*=UTF-8''")
	for i in 0 ..< len(v) {
		ch := v[i]
		if (ch >= 'A' && ch <= 'Z') ||
		   (ch >= 'a' && ch <= 'z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '.' ||
		   ch == '-' ||
		   ch == '_' {
			strings.write_byte(&sb, ch)
			continue
		}
		fmt.sbprintf(&sb, "%%%02X", ch)
	}
	return strings.to_string(sb)
}

// compose_build renders the message. The returned bytes are a complete RFC
// 5322 message with CRLF line endings, ready for DATA or APPEND.
compose_build :: proc(c: Compose, allocator := context.allocator) -> (data: []u8, msgid: string) {
	msgid = c.message_id
	if msgid == "" {
		dom := "localhost"
		if at := strings.index_byte(c.from.email, '@'); at >= 0 {
			dom = c.from.email[at + 1:]
		}
		msgid = generate_message_id(dom, allocator)
	}
	unix := c.date_unix
	if unix == 0 {
		unix = time.to_unix_seconds(time.now())
	}

	// Decide the structure.
	inlines := make([dynamic]Compose_Attachment, 0, 4, context.temp_allocator)
	files := make([dynamic]Compose_Attachment, 0, 4, context.temp_allocator)
	for a in c.attachments {
		if a.is_inline && a.content_id != "" {
			append(&inlines, a)
		} else {
			append(&files, a)
		}
	}
	have_alt := c.text != "" && c.html != ""
	have_body := c.text != "" || c.html != ""

	payloads := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&payloads, c.text, c.html)
	for a in c.attachments {
		append(&payloads, base64_encode(a.content, 76, context.temp_allocator))
	}
	b_mixed := make_boundary(payloads[:], context.temp_allocator)
	b_rel := make_boundary(payloads[:], context.temp_allocator)
	b_alt := make_boundary(payloads[:], context.temp_allocator)

	sb := strings.builder_make(allocator)

	// --- headers -----------------------------------------------------------
	fmt.sbprintf(&sb, "Date: %s\r\n", format_date(unix, c.tz_minutes, context.temp_allocator))
	addr_list(&sb, "From", {c.from})
	addr_list(&sb, "To", c.to)
	addr_list(&sb, "Cc", c.cc)
	addr_list(&sb, "Reply-To", c.reply_to)
	// Bcc is deliberately absent: it belongs in the envelope, and writing it
	// into the message is the classic way to leak a blind copy list.
	fmt.sbprintf(&sb, "Subject: %s\r\n", encode_header_value(c.subject, context.temp_allocator))
	fmt.sbprintf(&sb, "Message-ID: <%s>\r\n", msgid)
	if c.in_reply_to != "" {
		fmt.sbprintf(&sb, "In-Reply-To: <%s>\r\n", c.in_reply_to)
	}
	refs := c.references
	if c.in_reply_to != "" {
		merged := make([dynamic]string, 0, len(c.references) + 1, context.temp_allocator)
		for r in c.references {
			append(&merged, r)
		}
		if len(merged) == 0 || merged[len(merged) - 1] != c.in_reply_to {
			append(&merged, c.in_reply_to)
		}
		refs = merged[:]
	}
	fold_ids(&sb, "References", refs)
	if c.user_agent != "" {
		fmt.sbprintf(&sb, "User-Agent: %s\r\n", c.user_agent)
	}
	strings.write_string(&sb, "MIME-Version: 1.0\r\n")

	// --- body --------------------------------------------------------------
	write_bodies :: proc(sb: ^strings.Builder, c: Compose, b_alt: string, have_alt: bool) {
		if have_alt {
			fmt.sbprintf(sb, "Content-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n", b_alt)
			// RFC 2046 5.1.4: least faithful first.
			fmt.sbprintf(sb, "--%s\r\n", b_alt)
			write_text_part(sb, "plain", c.text)
			fmt.sbprintf(sb, "--%s\r\n", b_alt)
			write_text_part(sb, "html", c.html)
			fmt.sbprintf(sb, "--%s--\r\n", b_alt)
			return
		}
		if c.html != "" {
			write_text_part(sb, "html", c.html)
			return
		}
		write_text_part(sb, "plain", c.text)
	}

	switch {
	case len(files) == 0 && len(inlines) == 0:
		write_bodies(&sb, c, b_alt, have_alt)

	case len(files) == 0:
		// Bodies plus inline images: related, so a cid: reference resolves.
		fmt.sbprintf(&sb, "Content-Type: multipart/related; boundary=\"%s\"", b_rel)
		strings.write_string(&sb, have_alt ? ";\r\n type=\"multipart/alternative\"\r\n\r\n" : ";\r\n type=\"text/html\"\r\n\r\n")
		fmt.sbprintf(&sb, "--%s\r\n", b_rel)
		write_bodies(&sb, c, b_alt, have_alt)
		for a in inlines {
			fmt.sbprintf(&sb, "--%s\r\n", b_rel)
			write_attachment(&sb, a)
		}
		fmt.sbprintf(&sb, "--%s--\r\n", b_rel)

	case:
		fmt.sbprintf(&sb, "Content-Type: multipart/mixed; boundary=\"%s\"\r\n\r\n", b_mixed)
		fmt.sbprintf(&sb, "--%s\r\n", b_mixed)
		if len(inlines) > 0 && have_body {
			fmt.sbprintf(&sb, "Content-Type: multipart/related; boundary=\"%s\"\r\n\r\n", b_rel)
			fmt.sbprintf(&sb, "--%s\r\n", b_rel)
			write_bodies(&sb, c, b_alt, have_alt)
			for a in inlines {
				fmt.sbprintf(&sb, "--%s\r\n", b_rel)
				write_attachment(&sb, a)
			}
			fmt.sbprintf(&sb, "--%s--\r\n", b_rel)
		} else if have_body {
			write_bodies(&sb, c, b_alt, have_alt)
		} else {
			write_text_part(&sb, "plain", "")
		}
		for a in files {
			fmt.sbprintf(&sb, "--%s\r\n", b_mixed)
			write_attachment(&sb, a)
		}
		fmt.sbprintf(&sb, "--%s--\r\n", b_mixed)
	}

	return transmute([]u8)strings.to_string(sb), msgid
}

// compose_envelope builds the SMTP envelope that goes with a composed message:
// the return path plus every recipient including the blind ones.
compose_envelope :: proc(c: Compose, body: []u8, allocator := context.allocator) -> Envelope {
	rcpts := make([dynamic]string, 0, len(c.to) + len(c.cc) + len(c.bcc), allocator)
	for group in ([?][]Address{c.to, c.cc, c.bcc}) {
		for a in group {
			if a.email != "" {
				append(&rcpts, strings.clone(a.email, allocator))
			}
		}
	}
	return Envelope{from = strings.clone(c.from.email, allocator), to = rcpts[:], body = body}
}
