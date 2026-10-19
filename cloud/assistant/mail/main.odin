// palm-mail — an identity's mailbox, on the command-line convention.
//
// The assistant's mail tools are this binary's verbs, generated from its
// --schema like every other tool. It exists because the mail engine
// (apps/mailcore) is not on the kit convention yet — `palm mail` still routes
// to a binary that would open a window — and an assistant that cannot read
// mail is not much of one. It is small on purpose and goes through PostgREST
// with whatever session it is given, so RLS decides everything it can reach:
//
//	PALM_IDENTITY=camille.roux palm-mail unread --json
//	PALM_CLOUD_SESSION=<delegated.json> palm-mail read <id> --json
//
// It belongs in the mail area; cloud/docs/assistant.md asks for these verbs
// to move into mailcore (or apps/mail's CLI) and for this binary to go.
//
// What it reads, it returns as the recipient would see it: the HTML part
// when there is one, with hidden passages removed and counted (see
// cloud/assistant/untrusted), and `untrusted: true` on every body, because
// a mail is somebody else's words.
package main

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ck "../../../apps/cloudkit"
import un "../untrusted"
import kit "kit:."

@(private = "file")
SUMMARY_FIELDS :: []kit.Field {
	{name = "id", kind = .String},
	{name = "from", kind = .String},
	{name = "subject", kind = .String},
	{name = "date", kind = .String},
	{name = "preview", kind = .String},
	{name = "unread", kind = .Bool},
	{name = "has_attachment", kind = .Bool},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "unread",
		summary = "unread mail in the Inbox, newest first",
		effect = .Read,
		flags = {{name = "limit", kind = .Int, def = "10", help = "at most this many"}},
		out = {{name = "identity", kind = .String}, {name = "messages", kind = .Array, of = SUMMARY_FIELDS}, {name = "count", kind = .Int}},
		examples = {"palm-mail unread --json"},
		run = cmd_unread,
	},
	{
		verb = "search",
		summary = "mail whose sender, subject or opening words match",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true, help = "words that must all appear"}},
		flags = {{name = "limit", kind = .Int, def = "10"}},
		out = {{name = "identity", kind = .String}, {name = "messages", kind = .Array, of = SUMMARY_FIELDS}, {name = "count", kind = .Int}},
		examples = {"palm-mail search invoice --json"},
		run = cmd_search,
	},
	{
		verb = "read",
		summary = "one message as its recipient sees it, hidden text removed",
		effect = .Read,
		args = {{name = "id", kind = .String, required = true}},
		out = {
			{name = "id", kind = .String},
			{name = "from", kind = .String},
			{name = "to", kind = .String},
			{name = "subject", kind = .String},
			{name = "date", kind = .String},
			{name = "message_id", kind = .String},
			{name = "text", kind = .String, help = "the body a reader sees"},
			{name = "hidden_removed", kind = .Int, help = "hidden passages and invisible characters dropped"},
			{name = "hidden_kinds", kind = .Array, help = "how they were hidden"},
			{name = "attachments", kind = .Array, help = "file names"},
			{name = "untrusted", kind = .Bool, help = "always true: a mail is somebody else's words"},
		},
		examples = {"palm-mail read 2f0c… --json"},
		run = cmd_read,
	},
	{
		verb = "drafts",
		summary = "the drafts waiting to be sent",
		effect = .Read,
		out = {{name = "identity", kind = .String}, {name = "drafts", kind = .Array, of = SUMMARY_FIELDS}, {name = "count", kind = .Int}},
		run = cmd_drafts,
	},
	{
		verb = "draft",
		summary = "write a draft into Drafts; nothing is sent",
		effect = .Mutate,
		flags = {
			{name = "to", kind = .String, required = true, help = "addresses, comma-separated"},
			{name = "subject", kind = .String, required = true},
			{name = "body", kind = .String, required = true},
			{name = "reply-to", kind = .String, help = "the id of the message this answers"},
			{name = "attach", kind = .Path, help = "a file to attach, comma-separated for several"},
		},
		out = {{name = "id", kind = .String}, {name = "to", kind = .String}, {name = "subject", kind = .String}, {name = "attachments", kind = .Array}},
		examples = {"palm-mail draft --to noor@palm.test --subject 'Re: Halden' --body 'Attached.' --attach ~/Drive/camille.roux/Invoices/halden.pdf"},
		run = cmd_draft,
	},
	{
		verb = "send",
		summary = "send a draft: submits it and removes it from Drafts",
		effect = .Mutate,
		args = {{name = "id", kind = .String, required = true, help = "a draft's id"}},
		out = {{name = "id", kind = .String}, {name = "recipients", kind = .Array}},
		examples = {"palm-mail send 2f0c… --json"},
		run = cmd_send,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "mail",
			summary  = "an identity's mailbox: unread, search, read, draft, send",
			commands = COMMANDS,
			selftest = selftest,
			notes    = "Scope: PALM_IDENTITY, or a delegated session in PALM_CLOUD_SESSION. The database decides what is reachable; a session that is not scoped to one identity is refused here, because a mailbox is one identity's.",
		}
	}
	return &g_surface
}

main :: proc() {
	code, handled := kit.cli(surface())
	if !handled {
		fmt.eprint(kit.cli_help_text(surface()))
		code = kit.EXIT_USAGE
	}
	os.exit(code)
}

// ---------------------------------------------------------------------------
// Opening, with scope
// ---------------------------------------------------------------------------

Box :: struct {
	c:       ^ck.Client,
	ident:   string, // the identity's id
	handle:  string,
	address: string,
	name:    string,
}

@(private = "file")
fail_from :: proc(c: ^kit.Call, e: ck.Error) -> int {
	code := kit.EXIT_FAILED
	#partial switch e.kind {
	case .Unavailable:
		code = kit.EXIT_UNAVAILABLE
	case .Not_Signed_In, .Unauthorized:
		code = kit.EXIT_UNAVAILABLE
	case .Out_Of_Scope:
		code = kit.EXIT_OUT_OF_SCOPE
	case .Not_Found:
		code = kit.EXIT_NOT_FOUND
	case .Invalid:
		code = kit.EXIT_USAGE
	}
	kit.cli_fail(c, code, e.message)
	if e.code != "" {
		kit.cli_err_field(c, "reason", e.code)
	}
	return code
}

@(private = "file")
open_box :: proc(c: ^kit.Call) -> (b: Box, code: int) {
	cl, err := ck.open(scope = c.identity, app = "mail")
	b.c = cl
	if !ck.ok(err) {
		return b, fail_from(c, err)
	}
	if !ck.signed_in(cl) {
		return b, kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "not signed in: sign in with Accounts, or hand this a delegated session")
	}
	if !ck.scoped(cl) {
		return b, kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a mailbox is one identity's: set PALM_IDENTITY or --identity")
	}
	v, e := ck.rpc(cl, "mail_identities", "{}", context.temp_allocator)
	if !ck.ok(e) {
		return b, fail_from(c, e)
	}
	rows := ck.array(v)
	want := cl.scope
	for r in rows {
		if want == "" || ck.get_str(r, "handle") == want {
			b.ident = strings.clone(ck.get_str(r, "id"))
			b.handle = strings.clone(ck.get_str(r, "handle"))
			b.address = strings.clone(ck.get_str(r, "address"))
			b.name = strings.clone(ck.get_str(r, "display_name"))
			break
		}
	}
	if b.ident == "" {
		kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("this session does not reach identity %q", want))
		kit.cli_err_field(c, "requested", want)
		return b, kit.EXIT_OUT_OF_SCOPE
	}
	return b, kit.EXIT_OK
}

@(private = "file")
mailbox :: proc(b: ^Box, role: string) -> string {
	v, e := ck.select(b.c, "mail_mailboxes", fmt.tprintf("select=id&role=eq.%s&identity_id=eq.%s", role, b.ident), context.temp_allocator)
	if ck.ok(e) && len(ck.array(v)) > 0 {
		return ck.get_str(ck.array(v)[0], "id")
	}
	ck.rpc(b.c, "mail_bootstrap", "{}", context.temp_allocator)
	v, e = ck.select(b.c, "mail_mailboxes", fmt.tprintf("select=id&role=eq.%s&identity_id=eq.%s", role, b.ident), context.temp_allocator)
	if ck.ok(e) && len(ck.array(v)) > 0 {
		return ck.get_str(ck.array(v)[0], "id")
	}
	return ""
}

// ---------------------------------------------------------------------------
// Rows to JSON
// ---------------------------------------------------------------------------

addr_text :: proc(v: ck.Value) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for a in ck.array(v) {
		name, email := ck.get_str(a, "name"), ck.get_str(a, "email")
		if name != "" {
			append(&parts, fmt.tprintf("%s <%s>", name, email))
		} else {
			append(&parts, email)
		}
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private = "file")
has_kw :: proc(v: ck.Value, kw: string) -> bool {
	for k in ck.array(ck.get(v, "keywords")) {
		if s, ok := k.(string); ok && s == kw {return true}
	}
	return false
}

@(private = "file")
summary_json :: proc(r: ck.Value, seen_preview: map[string]string) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", ck.get_str(r, "id"))
	kit.jset_str(o, "from", addr_text(ck.get(r, "from")))
	kit.jset_str(o, "subject", un.text(ck.get_str(r, "subject"), context.temp_allocator).text)
	kit.jset_str(o, "date", ck.get_str(r, "received_at"))
	// The stored preview is whatever the delivering server took from the
	// message, which may be a text/plain part the person never sees. The
	// preview here is made the way `read` makes the body.
	pv, ok := seen_preview[ck.get_str(r, "blob_id")]
	if !ok {pv = un.text(ck.get_str(r, "preview"), context.temp_allocator).text}
	kit.jset_str(o, "preview", pv)
	kit.jset_bool(o, "unread", !has_kw(r, "$seen"))
	kit.jset_bool(o, "has_attachment", ck.get_bool(r, "has_attachment"))
	return o
}

// previews_of renders the opening of each listed message from its raw bytes,
// in one request, as `read` would show it.
@(private = "file")
previews_of :: proc(b: ^Box, rows: ck.Value) -> map[string]string {
	m := make(map[string]string, allocator = context.temp_allocator)
	ids := make([dynamic]string, context.temp_allocator)
	for r in ck.array(rows) {append(&ids, ck.get_str(r, "blob_id"))}
	if len(ids) == 0 {return m}
	v, e := ck.select(b.c, "mail_blobs", fmt.tprintf("select=id,raw&id=in.(%s)", strings.join(ids[:], ",", context.temp_allocator)), context.temp_allocator)
	if !ck.ok(e) {return m}
	for row in ck.array(v) {
		hx := strings.trim_prefix(ck.get_str(row, "raw"), "\\x")
		data, ok := hex.decode(transmute([]u8)hx, context.temp_allocator)
		if !ok {continue}
		p := parse(string(data))
		body, is_html := best_body(p)
		clean := is_html ? un.html(body, context.temp_allocator) : un.text(body, context.temp_allocator)
		flat := strings.join(strings.fields(clean.text, context.temp_allocator), " ", context.temp_allocator)
		if len(flat) > 200 {
			cut := 200
			for cut > 0 && (flat[cut] & 0xC0) == 0x80 {cut -= 1}
			flat = fmt.tprintf("%s…", flat[:cut])
		}
		m[ck.get_str(row, "id")] = flat
	}
	return m
}

@(private = "file")
LIST_COLS :: "id,blob_id,subject,from,received_at,preview,keywords,has_attachment"

@(private = "file")
list_out :: proc(c: ^kit.Call, b: ^Box, key: string, rows: ck.Value) {
	out := kit.jobj()
	kit.jset_str(out, "identity", b.handle)
	arr := kit.jarr()
	pv := previews_of(b, rows)
	for r in ck.array(rows) {
		kit.jpush(arr, summary_json(r, pv))
	}
	kit.jset(out, key, arr)
	kit.jset_int(out, "count", kit.jlen(arr))
	c.out = out
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

@(private = "file")
cmd_unread :: proc(c: ^kit.Call) -> int {
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}
	inbox := mailbox(&b, "inbox")
	if inbox == "" {
		list_out(c, &b, "messages", nil)
		return kit.EXIT_OK
	}
	q := fmt.tprintf("select=%s&identity_id=eq.%s&mailbox_ids=cs.%%7B%s%%7D&keywords=not.cs.%%7B%%24seen%%7D&order=received_at.desc&limit=%d",
		LIST_COLS, b.ident, inbox, clamp(kit.cli_int(c, "limit", 10), 1, 50))
	v, e := ck.select(b.c, "mail_messages", q, context.temp_allocator)
	if !ck.ok(e) {return fail_from(c, e)}
	list_out(c, &b, "messages", v)
	return kit.EXIT_OK
}

@(private = "file")
cmd_search :: proc(c: ^kit.Call) -> int {
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}
	q := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&q, "select=%s&identity_id=eq.%s&order=received_at.desc&limit=%d", LIST_COLS, b.ident, clamp(kit.cli_int(c, "limit", 10), 1, 50))
	words := strings.fields(strings.to_lower(kit.cli_str(c, "query"), context.temp_allocator), context.temp_allocator)
	// Every word must appear: one ilike per word, on the generated `search`
	// column (subject, preview and addresses).
	if len(words) > 0 {
		strings.write_string(&q, "&and=(")
		for w, i in words {
			if i > 0 {strings.write_byte(&q, ',')}
			clean := strings.trim(w, "\"'(),.*%")
			fmt.sbprintf(&q, "search.ilike.*%s*", ck.escape(clean))
		}
		strings.write_byte(&q, ')')
	}
	v, e := ck.select(b.c, "mail_messages", strings.to_string(q), context.temp_allocator)
	if !ck.ok(e) {return fail_from(c, e)}
	list_out(c, &b, "messages", v)
	return kit.EXIT_OK
}

@(private = "file")
uuid_ok :: proc(s: string) -> bool {
	if len(s) != 36 {return false}
	for ch, i in s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if ch != '-' {return false}
		} else if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
			return false
		}
	}
	return true
}

@(private = "file")
fetch_raw :: proc(b: ^Box, id: string) -> (msg: ck.Value, raw: string, e: ck.Error) {
	v: ck.Value
	v, e = ck.select(b.c, "mail_messages", fmt.tprintf("select=*&id=eq.%s", id), context.temp_allocator)
	if !ck.ok(e) {return}
	rows := ck.array(v)
	if len(rows) == 0 {
		e = ck.Error{kind = .Not_Found, message = "no such message in this identity's mailbox"}
		return
	}
	msg = rows[0]
	bv: ck.Value
	bv, e = ck.select(b.c, "mail_blobs", fmt.tprintf("select=raw&id=eq.%s", ck.get_str(msg, "blob_id")), context.temp_allocator)
	if !ck.ok(e) {return}
	brows := ck.array(bv)
	if len(brows) == 0 {
		e = ck.Error{kind = .Not_Found, message = "the message's content is missing"}
		return
	}
	hx := strings.trim_prefix(ck.get_str(brows[0], "raw"), "\\x")
	data, ok := hex.decode(transmute([]u8)hx, context.temp_allocator)
	if !ok {
		e = ck.Error{kind = .Failed, message = "could not decode the stored message"}
		return
	}
	raw = string(data)
	return
}

@(private = "file")
cmd_read :: proc(c: ^kit.Call) -> int {
	id := kit.cli_str(c, "id")
	if !uuid_ok(id) {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such message in this identity's mailbox")
	}
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}
	msg, raw, e := fetch_raw(&b, id)
	if !ck.ok(e) {return fail_from(c, e)}
	p := parse(raw)
	body, is_html := best_body(p)
	clean := is_html ? un.html(body, context.temp_allocator) : un.text(body, context.temp_allocator)
	out := kit.jobj()
	kit.jset_str(out, "id", id)
	kit.jset_str(out, "from", addr_text(ck.get(msg, "from")))
	kit.jset_str(out, "to", addr_text(ck.get(msg, "to")))
	kit.jset_str(out, "subject", un.text(ck.get_str(msg, "subject"), context.temp_allocator).text)
	kit.jset_str(out, "date", ck.get_str(msg, "received_at"))
	kit.jset_str(out, "message_id", ck.get_str(msg, "message_id"))
	text := clean.text
	if len(text) > 12000 {
		text = fmt.tprintf("%s\n[… %d more characters not shown]", text[:12000], len(text) - 12000)
	}
	kit.jset_str(out, "text", text)
	kit.jset_int(out, "hidden_removed", clean.removed)
	kinds := kit.jarr()
	for n in clean.notes {kit.jpush(kinds, kit.jstr(n))}
	kit.jset(out, "hidden_kinds", kinds)
	att := kit.jarr()
	for part in p.parts {
		if part.filename != "" {kit.jpush(att, kit.jstr(part.filename))}
	}
	kit.jset(out, "attachments", att)
	kit.jset_bool(out, "untrusted", true)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_drafts :: proc(c: ^kit.Call) -> int {
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}
	drafts := mailbox(&b, "drafts")
	q := fmt.tprintf("select=%s,to&identity_id=eq.%s&mailbox_ids=cs.%%7B%s%%7D&order=received_at.desc&limit=50", LIST_COLS, b.ident, drafts)
	v, e := ck.select(b.c, "mail_messages", q, context.temp_allocator)
	if !ck.ok(e) {return fail_from(c, e)}
	list_out(c, &b, "drafts", v)
	return kit.EXIT_OK
}

@(private = "file")
split_addrs :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for a in strings.split(s, ",", context.temp_allocator) {
		t := strings.trim_space(a)
		if lt := strings.index_byte(t, '<'); lt >= 0 {
			gt := strings.index_byte(t, '>')
			if gt > lt {t = t[lt + 1:gt]}
		}
		t = strings.to_lower(strings.trim_space(t), context.temp_allocator)
		if t != "" {append(&out, t)}
	}
	return out[:]
}

@(private = "file")
addr_ok :: proc(a: string) -> bool {
	at := strings.index_byte(a, '@')
	if at <= 0 || at == len(a) - 1 || strings.count(a, "@") != 1 {return false}
	for ch in a {
		if ch <= ' ' || ch == '<' || ch == '>' || ch == ',' || ch == ';' || ch == '"' {return false}
	}
	return strings.contains(a[at:], ".")
}

@(private = "file")
addr_json :: proc(addrs: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for a, i in addrs {
		if i > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, "{{\"name\":\"\",\"email\":%s}}", ck.quote(a))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
new_message_id :: proc(b: ^Box) -> string {
	r: [8]u8
	for i in 0 ..< 8 {
		r[i] = u8((time.tick_now()._nsec >> uint(i * 7)) ~ i64(i * 37))
	}
	dom := b.address[strings.index_byte(b.address, '@') + 1:]
	return fmt.tprintf("%d.%s@%s", time.to_unix_nanoseconds(time.now()), string(hex.encode(r[:], context.temp_allocator)), dom)
}

@(private = "file")
cmd_draft :: proc(c: ^kit.Call) -> int {
	to := split_addrs(kit.cli_str(c, "to"))
	if len(to) == 0 {return kit.cli_fail(c, kit.EXIT_USAGE, "--to needs at least one address")}
	for a in to {
		if !addr_ok(a) {return kit.cli_failf(c, kit.EXIT_USAGE, "not an address: %q", a)}
	}
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}

	d := Draft {
		from_name  = b.name,
		from       = b.address,
		to         = to,
		subject    = kit.cli_str(c, "subject"),
		body       = kit.cli_str(c, "body"),
		message_id = new_message_id(&b),
	}
	if rt := kit.cli_str(c, "reply-to"); rt != "" {
		if !uuid_ok(rt) {return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "--reply-to: no such message")}
		v, e := ck.select(b.c, "mail_messages", fmt.tprintf("select=message_id,references&id=eq.%s", rt), context.temp_allocator)
		if !ck.ok(e) {return fail_from(c, e)}
		if len(ck.array(v)) == 0 {return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "--reply-to: no such message in this identity's mailbox")}
		parent := ck.array(v)[0]
		mid := ck.get_str(parent, "message_id")
		if mid != "" {
			d.in_reply_to = strings.trim(mid, "<>")
			refs := make([dynamic]string, context.temp_allocator)
			for r in ck.array(ck.get(parent, "references")) {
				if s, ok := r.(string); ok {append(&refs, fmt.tprintf("<%s>", strings.trim(s, "<>")))}
			}
			append(&refs, fmt.tprintf("<%s>", d.in_reply_to))
			d.references = strings.join(refs[:], " ", context.temp_allocator)
		}
	}
	atts := make([dynamic]Attachment, context.temp_allocator)
	names := kit.jarr()
	if ap := kit.cli_str(c, "attach"); ap != "" {
		for path in strings.split(ap, ",", context.temp_allocator) {
			p := strings.trim_space(path)
			data, err := os.read_entire_file_from_path(p, context.temp_allocator)
			if err != nil {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s to attach it", p)
			}
			name := p[strings.last_index_byte(p, '/') + 1:]
			append(&atts, Attachment{name = name, ctype = guess_type(name), data = data})
			kit.jpush(names, kit.jstr(name))
		}
	}
	d.attachments = atts[:]
	raw := build(d)

	drafts := mailbox(&b, "drafts")
	if drafts == "" {return kit.cli_fail(c, kit.EXIT_FAILED, "this identity has no Drafts mailbox")}
	meta := ck.obj()
	ck.put(&meta, "subject", d.subject)
	ck.put_raw(&meta, "from", fmt.tprintf("[{{\"name\":%s,\"email\":%s}}]", ck.quote(b.name), ck.quote(b.address)))
	ck.put_raw(&meta, "to", addr_json(to))
	ck.put(&meta, "messageId", d.message_id)
	if d.in_reply_to != "" {
		ck.put_raw(&meta, "inReplyTo", fmt.tprintf("[%s]", ck.quote(d.in_reply_to)))
	}
	preview := d.body[:min(len(d.body), 200)]
	ck.put(&meta, "preview", preview)
	ck.put(&meta, "hasAttachment", len(atts) > 0)
	args := ck.obj()
	ck.put(&args, "p_identity", b.ident)
	ck.put(&args, "p_raw", fmt.tprintf("\\x%s", string(hex.encode(transmute([]u8)raw, context.temp_allocator))))
	ck.put_raw(&args, "p_meta", ck.obj_done(&meta))
	ck.put_raw(&args, "p_boxes", fmt.tprintf("[%s]", ck.quote(drafts)))
	ck.put_raw(&args, "p_keywords", `["$draft","$seen"]`)
	if c.dry_run {
		out := kit.jobj()
		kit.jset_str(out, "id", "")
		kit.jset_str(out, "to", strings.join(to, ", ", context.temp_allocator))
		kit.jset_str(out, "subject", d.subject)
		kit.jset(out, "attachments", names)
		c.out = out
		return kit.EXIT_OK
	}
	v, e := ck.rpc(b.c, "mail_import", ck.obj_done(&args), context.temp_allocator)
	if !ck.ok(e) {return fail_from(c, e)}
	id := ""
	if s, ok := v.(string); ok {id = s}
	out := kit.jobj()
	kit.jset_str(out, "id", id)
	kit.jset_str(out, "to", strings.join(to, ", ", context.temp_allocator))
	kit.jset_str(out, "subject", d.subject)
	kit.jset(out, "attachments", names)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_send :: proc(c: ^kit.Call) -> int {
	id := kit.cli_str(c, "id")
	if !uuid_ok(id) {return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such draft")}
	b, code := open_box(c)
	if code != kit.EXIT_OK {return code}
	msg, raw, e := fetch_raw(&b, id)
	if !ck.ok(e) {return fail_from(c, e)}
	if !has_kw(msg, "$draft") {return kit.cli_fail(c, kit.EXIT_USAGE, "that message is not a draft")}
	rcpts := make([dynamic]string, context.temp_allocator)
	for k in ([?]string{"to", "cc", "bcc"}) {
		for a in ck.array(ck.get(msg, k)) {
			append(&rcpts, ck.get_str(a, "email"))
		}
	}
	if len(rcpts) == 0 {return kit.cli_fail(c, kit.EXIT_USAGE, "the draft has no recipients")}
	meta := ck.obj()
	ck.put(&meta, "subject", ck.get_str(msg, "subject"))
	ck.put_raw(&meta, "from", fmt.tprintf("[{{\"name\":%s,\"email\":%s}}]", ck.quote(b.name), ck.quote(b.address)))
	ck.put_raw(&meta, "to", addr_json(rcpts[:]))
	ck.put(&meta, "messageId", ck.get_str(msg, "message_id"))
	ck.put(&meta, "preview", ck.get_str(msg, "preview"))
	ck.put(&meta, "hasAttachment", ck.get_bool(msg, "has_attachment"))
	args := ck.obj()
	ck.put(&args, "p_identity", b.ident)
	ck.put(&args, "p_raw", fmt.tprintf("\\x%s", string(hex.encode(transmute([]u8)raw, context.temp_allocator))))
	ck.put_raw(&args, "p_meta", ck.obj_done(&meta))
	ck.put_raw(&args, "p_rcpts", fmt.tprintf("[%s]", strings.join(quoted(rcpts[:]), ",", context.temp_allocator)))
	if c.dry_run {
		out := kit.jobj()
		kit.jset_str(out, "id", id)
		arr := kit.jarr()
		for r in rcpts {kit.jpush(arr, kit.jstr(r))}
		kit.jset(out, "recipients", arr)
		c.out = out
		return kit.EXIT_OK
	}
	v, se := ck.rpc(b.c, "mail_submit", ck.obj_done(&args), context.temp_allocator)
	if !ck.ok(se) {return fail_from(c, se)}
	// The draft has become a sent message; take it out of Drafts.
	ck.delete_rows(b.c, "mail_messages", fmt.tprintf("id=eq.%s", id))
	out := kit.jobj()
	kit.jset_str(out, "id", ck.get_str(v, "emailId"))
	arr := kit.jarr()
	for r in ck.array(ck.get(v, "recipients")) {
		o := kit.jobj()
		kit.jset_str(o, "rcpt", ck.get_str(r, "rcpt"))
		kit.jset_str(o, "status", ck.get_str(r, "status"))
		kit.jpush(arr, o)
	}
	kit.jset(out, "recipients", arr)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
quoted :: proc(xs: []string) -> []string {
	out := make([]string, len(xs), context.temp_allocator)
	for x, i in xs {out[i] = ck.quote(x)}
	return out
}
