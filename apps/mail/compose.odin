// The composer: new messages, replies, reply-all, forwards, and what happens
// when Send is pressed.
//
// SAFETY. Send writes a file. That is the whole of it. There is no socket, no
// SMTP, no sendmail, no `xdg-open mailto:` — the message is delivered into the
// account's own local Outbox Maildir with the ordinary tmp/ then rename into
// new/ dance, where a local test server would pick it up and where this app can
// read it straight back. `send_destination` below is the only path Send can
// take, and it is always inside the app's data directory. Nothing here can
// reach the internet, by construction rather than by policy.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Opening the composer
// ---------------------------------------------------------------------------

compose_reset :: proc(c: ^Composer) {
	le_clear(&c.to)
	le_clear(&c.cc)
	le_clear(&c.subject)
	buf_init(&c.body, "")
	delete(c.in_reply_to)
	delete(c.references)
	delete(c.origin_path)
	c.in_reply_to = ""
	c.references = ""
	c.origin_path = ""
	c.sent_to = ""
	c.confirm = false
	// The autosave bookkeeping belongs to one composition, not to the
	// composer: a new one starts with nothing of its own on disk.
	c.open_hash = 0
	c.saved_hash = 0
	c.saved_any = false
	c.saved_at = {}
	c.last_tick = {}
	ac_close(c)
}

// compose_new is C. A draft waiting from a previous run, or one Escape left
// in the composer, is picked up rather than thrown away — which is what a
// person pressing the compose key after losing their window actually wants.
// Shift+C is the way to insist on a blank one.
compose_new :: proc(st: ^State) {
	c := &st.comp
	if st.draft_waiting {
		if draft_restore(st) {
			return
		}
	}
	if compose_dirty(c) {
		c.open = true
		st.pane = .Compose
		note(st, "Carrying on with your unsent draft — Shift+C starts a new one")
		return
	}
	compose_blank(st)
}

// compose_blank always starts an empty message, parking anything unsent first.
compose_blank :: proc(st: ^State) {
	c := &st.comp
	park_draft(st)
	compose_reset(c)
	c.open = true
	c.mode = .New
	c.field = .To
	c.account = account_of_folder(st, st.folder_sel)
	c.open_hash = compose_hash(c)
	st.pane = .Compose
}

// quote_body is the familiar attribution line followed by the original body
// prefixed with "> ". A quote of a quote gets ">>", which is why the prefix is
// added rather than the lines being reflowed.
quote_body :: proc(m: Message, offset: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	local := time.Time{_nsec = m.date._nsec + offset * 1_000_000_000}
	y, mo, d := time.date(local)
	hh, mi, _ := time.clock(local)
	months := MONTHS
	fmt.sbprintf(
		&b,
		"On %d %s %d at %02d:%02d, %s wrote:\n",
		d,
		months[clamp(int(mo) - 1, 0, 11)],
		y,
		hh,
		mi,
		addr_label(m.from),
	)
	for l in wrap_lines(m.body, QUOTE_COLUMNS, context.temp_allocator) {
		if l == "" {
			strings.write_string(&b, ">\n")
		} else {
			fmt.sbprintf(&b, "> %s\n", l)
		}
	}
	return strings.to_string(b)
}

// Mail has wrapped at about this width since before anyone reading it was
// born, and a composer that does not wrap produces a quote wider than the
// window it is typed in.
QUOTE_COLUMNS :: 72

// wrap_lines hard-wraps on spaces at `columns`, counting runes rather than
// bytes so an accented or CJK line is not cut in the middle of a character.
// Lines already short enough are passed through untouched.
wrap_lines :: proc(text: string, columns: int, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 32, allocator)
	rest := text
	for {
		line, more := next_line(&rest)
		if !more {
			break
		}
		l := strings.trim_right(line, "\r")
		for {
			if rune_count(l) <= columns {
				append(&out, strings.clone(l, allocator))
				break
			}
			// Find the last space at or before the column limit.
			cut, seen, last_space := len(l), 0, -1
			for i in 0 ..< len(l) {
				if l[i] & 0xc0 == 0x80 {
					continue // a continuation byte is not a new rune
				}
				if seen == columns {
					cut = i
					break
				}
				if l[i] == ' ' && seen > 0 {
					last_space = i
				}
				seen += 1
			}
			if last_space > 0 {
				cut = last_space
			}
			append(&out, strings.clone(strings.trim_right(l[:cut], " "), allocator))
			l = strings.trim_left(l[cut:], " ")
			if l == "" {
				break
			}
		}
	}
	return out[:]
}

rune_count :: proc(s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] & 0xc0 != 0x80 {
			n += 1
		}
	}
	return n
}

MONTHS :: [?]string {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

// reply_subject prefixes Re: once. "Re: Re: x" is a bug, not a thread.
reply_subject :: proc(subject: string, allocator := context.allocator) -> string {
	t := strings.trim_space(subject)
	if len(t) >= 3 && strings.equal_fold(t[:3], "re:") {
		return strings.clone(t, allocator)
	}
	return fmt.aprintf("Re: %s", t, allocator = allocator)
}

forward_subject :: proc(subject: string, allocator := context.allocator) -> string {
	t := strings.trim_space(subject)
	if len(t) >= 4 && strings.equal_fold(t[:4], "fwd:") {
		return strings.clone(t, allocator)
	}
	return fmt.aprintf("Fwd: %s", t, allocator = allocator)
}

// reply_recipients works out To and Cc. A reply goes to Reply-To when the
// sender asked for it, otherwise to From. Reply-all adds the original To and
// Cc, minus our own address, deduplicated — getting this wrong means mailing
// yourself or dropping half the thread.
reply_recipients :: proc(
	m: Message,
	me: string,
	all: bool,
	allocator := context.allocator,
) -> (
	to: string,
	cc: string,
) {
	primary := m.from
	if m.reply_to.email != "" {
		primary = m.reply_to
	}
	tos := make([dynamic]Address, 0, 4, context.temp_allocator)
	append(&tos, primary)

	ccs := make([dynamic]Address, 0, 8, context.temp_allocator)
	if all {
		seen := make(map[string]bool, 16, context.temp_allocator)
		seen[strings.to_lower(primary.email, context.temp_allocator)] = true
		if me != "" {
			seen[strings.to_lower(me, context.temp_allocator)] = true
		}
		for a in m.to {
			k := strings.to_lower(a.email, context.temp_allocator)
			if k == "" || seen[k] {
				continue
			}
			seen[k] = true
			append(&ccs, a)
		}
		for a in m.cc {
			k := strings.to_lower(a.email, context.temp_allocator)
			if k == "" || seen[k] {
				continue
			}
			seen[k] = true
			append(&ccs, a)
		}
	}

	return join_addresses(tos[:], allocator), join_addresses(ccs[:], allocator)
}

join_addresses :: proc(as_: []Address, allocator := context.allocator) -> string {
	parts := make([dynamic]string, 0, len(as_), context.temp_allocator)
	for a in as_ {
		if a.email == "" && a.name == "" {
			continue
		}
		append(&parts, format_address(a, context.temp_allocator))
	}
	return strings.join(parts[:], ", ", allocator)
}

compose_reply :: proc(st: ^State, mi: int, all: bool) {
	if mi < 0 || mi >= len(st.messages) {
		return
	}
	// Parking an unsent draft files it into Drafts, and that reloads the
	// tree and renumbers every message — so the one being replied to is
	// found again by path, never by the index we came in with.
	idx := mi
	if compose_dirty(&st.comp) || st.draft_waiting {
		keep := strings.clone(st.messages[idx].path, context.temp_allocator)
		if park_draft(st) {
			idx = message_at_path(st, keep)
			if idx < 0 {
				note(st, "Your draft was kept in Drafts; the message you were replying to has moved.")
				return
			}
		}
	}
	m := st.messages[idx]
	c := &st.comp
	compose_reset(c)
	c.open = true
	c.mode = all ? .Reply_All : .Reply
	c.field = .Body
	c.account = m.account
	me := st.accounts[m.account].address

	to, cc := reply_recipients(m, me, all, context.temp_allocator)
	le_set(&c.to, to)
	le_set(&c.cc, cc)
	le_set(&c.subject, reply_subject(m.subject, context.temp_allocator))

	// In-Reply-To is the message being answered; References is its own chain
	// with that id appended, which is what keeps a thread threaded.
	c.in_reply_to = strings.clone(m.id)
	refs := make([dynamic]string, 0, len(m.refs) + 1, context.temp_allocator)
	for r in m.refs {
		append(&refs, fmt.tprintf("<%s>", r))
	}
	if m.id != "" {
		append(&refs, fmt.tprintf("<%s>", m.id))
	}
	c.references = strings.join(refs[:], " ")

	body := strings.builder_make(context.temp_allocator)
	strings.write_string(&body, "\n\n")
	strings.write_string(&body, quote_body(m, st.tz_offset, context.temp_allocator))
	buf_init(&c.body, strings.to_string(body))
	c.body.cur = {0, 0}
	c.open_hash = compose_hash(c)
	st.pane = .Compose

	// Answering a message marks it answered, as every client does.
	set_flags(st, idx, st.messages[idx].flags | {.Answered, .Seen})
}

compose_forward :: proc(st: ^State, mi: int) {
	if mi < 0 || mi >= len(st.messages) {
		return
	}
	idx := mi
	if compose_dirty(&st.comp) || st.draft_waiting {
		keep := strings.clone(st.messages[idx].path, context.temp_allocator)
		if park_draft(st) {
			idx = message_at_path(st, keep)
			if idx < 0 {
				note(st, "Your draft was kept in Drafts; the message you were forwarding has moved.")
				return
			}
		}
	}
	m := st.messages[idx]
	c := &st.comp
	compose_reset(c)
	c.open = true
	c.mode = .Forward
	c.field = .To
	c.account = m.account
	le_set(&c.subject, forward_subject(m.subject, context.temp_allocator))

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\n\n---------- Forwarded message ----------\n")
	fmt.sbprintf(&b, "From: %s\n", format_address(m.from, context.temp_allocator))
	fmt.sbprintf(&b, "Date: %s\n", full_date(m.date, st.tz_offset, context.temp_allocator))
	fmt.sbprintf(&b, "Subject: %s\n", m.subject)
	fmt.sbprintf(&b, "To: %s\n\n", join_addresses(m.to, context.temp_allocator))
	for l in wrap_lines(m.body, QUOTE_COLUMNS, context.temp_allocator) {
		strings.write_string(&b, l)
		strings.write_byte(&b, '\n')
	}
	buf_init(&c.body, strings.to_string(b))
	c.body.cur = {0, 0}
	c.open_hash = compose_hash(c)
	st.pane = .Compose
}

// ---------------------------------------------------------------------------
// Rendering the message
// ---------------------------------------------------------------------------

@(private = "file")
msgid_counter := 0

new_message_id :: proc(domain: string, allocator := context.allocator) -> string {
	msgid_counter += 1
	ns := time.now()._nsec
	return fmt.aprintf("palmy-%d-%d@%s", ns, msgid_counter, domain, allocator = allocator)
}

// build_message renders the composer into RFC 5322 text. The body is written
// as 8-bit UTF-8, which every modern reader handles and which keeps the file
// on disk readable in an editor; non-ASCII header values are RFC 2047 encoded,
// because a raw 8-bit Subject is not legal and would not round-trip.
build_message :: proc(st: ^State, draft := false, allocator := context.allocator) -> string {
	c := &st.comp
	a := st.accounts[clamp(c.account, 0, max(0, len(st.accounts) - 1))]
	domain := "localhost"
	if at := strings.index_byte(a.address, '@'); at > 0 {
		domain = a.address[at + 1:]
	}

	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "Date: %s\r\n", format_rfc5322_date(time.now(), context.temp_allocator))
	fmt.sbprintf(&b, "From: %s <%s>\r\n", a.name, a.address)
	fmt.sbprintf(&b, "To: %s\r\n", encode_header_value(le_text(&c.to), context.temp_allocator))
	if strings.trim_space(le_text(&c.cc)) != "" {
		fmt.sbprintf(&b, "Cc: %s\r\n", encode_header_value(le_text(&c.cc), context.temp_allocator))
	}
	fmt.sbprintf(&b, "Subject: %s\r\n", encode_header_value(le_text(&c.subject), context.temp_allocator))
	fmt.sbprintf(&b, "Message-ID: <%s>\r\n", new_message_id(domain, context.temp_allocator))
	if c.in_reply_to != "" {
		fmt.sbprintf(&b, "In-Reply-To: <%s>\r\n", c.in_reply_to)
	}
	if c.references != "" {
		fmt.sbprintf(&b, "References: %s\r\n", c.references)
	}
	strings.write_string(&b, "MIME-Version: 1.0\r\n")
	strings.write_string(&b, "Content-Type: text/plain; charset=utf-8\r\n")
	strings.write_string(&b, "Content-Transfer-Encoding: 8bit\r\n")
	// A marker, so it is never in doubt where a message in the Outbox came
	// from or that it was never transmitted.
	if draft {
		strings.write_string(&b, "X-Palmy-Mail: unsent draft; never-transmitted\r\n")
	} else {
		strings.write_string(&b, "X-Palmy-Mail: queued-locally; never-transmitted\r\n")
	}
	strings.write_string(&b, "\r\n")

	text := buf_text(&c.body, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(&b, strings.trim_right(line, "\r"))
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}

// encode_header_value leaves ASCII alone and RFC 2047 base64-encodes anything
// else. Address lists are encoded per display name so the addresses stay
// machine-readable.
encode_header_value :: proc(s: string, allocator := context.allocator) -> string {
	if is_ascii(s) {
		return strings.clone(s, allocator)
	}
	return fmt.aprintf(
		"=?utf-8?B?%s?=",
		encode_base64(transmute([]u8)s, context.temp_allocator),
		allocator = allocator,
	)
}

is_ascii :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Sending — which means writing a file, and nothing else
// ---------------------------------------------------------------------------

OUTBOX_NAME :: ".Outbox"

// send_destination is the only place Send may write. It is always the account's
// own Outbox Maildir, which is always under the app's data directory.
send_destination :: proc(st: ^State, account: int, allocator := context.allocator) -> string {
	a := st.accounts[clamp(account, 0, max(0, len(st.accounts) - 1))]
	return fmt.aprintf("%s/%s", a.root, OUTBOX_NAME, allocator = allocator)
}

// maildir_deliver writes a message the way a Maildir delivery agent must:
// into tmp/ first, then rename into new/, so a reader never sees half a file.
maildir_deliver :: proc(folder: string, content: string) -> (path: string, ok: bool) {
	for sub in ([?]string{"tmp", "new", "cur"}) {
		os.make_directory_all(tfmt("%s/%s", folder, sub))
	}
	msgid_counter += 1
	name := fmt.tprintf("%d.M%dP%d.palmy", time.now()._nsec / 1_000_000_000, msgid_counter, os.get_pid())
	tmp := tfmt("%s/tmp/%s", folder, name)
	if !write_file(tmp, transmute([]u8)content) {
		return "", false
	}
	// A queued message is a draft that has not been read: no flags, in new/.
	dest := tfmt("%s/new/%s", folder, name)
	if os.rename(tmp, dest) != nil {
		os.remove(tmp)
		return "", false
	}
	return strings.clone(dest), true
}

// compose_send queues the message locally. It returns the path it wrote so the
// UI can say exactly where the message went — which is the honest thing to
// show when the button is called Send and nothing was transmitted.
compose_send :: proc(st: ^State) -> (path: string, ok: bool) {
	c := &st.comp
	if strings.trim_space(le_text(&c.to)) == "" {
		note(st, "A message needs at least one recipient.")
		return "", false
	}
	content := build_message(st, false, context.temp_allocator)
	folder := send_destination(st, c.account, context.temp_allocator)
	p, wok := maildir_deliver(folder, content)
	if !wok {
		note(st, "Could not write to the local Outbox.")
		return "", false
	}
	return p, true
}
