package main

// The shared mailbox store behind all four front ends.
//
// One in-memory store, three read protocols (IMAP, POP3, JMAP) and one write
// protocol (SMTP). That sharing is the point: a message delivered over SMTP is
// immediately visible over all three, and the same message served three
// different ways must land in the client's Maildir identically. Any divergence
// is a client bug, and there is nowhere for it to hide.
//
// Every account, password and message in here is synthetic. The passwords are
// invented for this server and exist nowhere else; see `seed_accounts`.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Flag :: enum u8 {
	Seen,
	Answered,
	Flagged,
	Deleted,
	Draft,
	Recent,
}
Flags :: bit_set[Flag;u8]

flags_to_imap :: proc(f: Flags, allocator := context.allocator) -> string {
	parts := make([dynamic]string, 0, 6, context.temp_allocator)
	if .Seen in f {append(&parts, "\\Seen")}
	if .Answered in f {append(&parts, "\\Answered")}
	if .Flagged in f {append(&parts, "\\Flagged")}
	if .Deleted in f {append(&parts, "\\Deleted")}
	if .Draft in f {append(&parts, "\\Draft")}
	if .Recent in f {append(&parts, "\\Recent")}
	return strings.join(parts[:], " ", allocator)
}

flag_from_imap :: proc(name: string) -> (Flag, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "\\seen":
		return .Seen, true
	case "\\answered":
		return .Answered, true
	case "\\flagged":
		return .Flagged, true
	case "\\deleted":
		return .Deleted, true
	case "\\draft":
		return .Draft, true
	case "\\recent":
		return .Recent, true
	}
	return .Seen, false
}

flags_to_keywords :: proc(f: Flags, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 5, allocator)
	if .Seen in f {append(&out, "$seen")}
	if .Answered in f {append(&out, "$answered")}
	if .Flagged in f {append(&out, "$flagged")}
	if .Draft in f {append(&out, "$draft")}
	return out[:]
}

keyword_to_flag :: proc(k: string) -> (Flag, bool) {
	switch strings.to_lower(k, context.temp_allocator) {
	case "$seen":
		return .Seen, true
	case "$answered":
		return .Answered, true
	case "$flagged":
		return .Flagged, true
	case "$draft":
		return .Draft, true
	}
	return .Seen, false
}

// Decomp is the structured view of a message that JMAP serves.
//
// For the corpus it is *authored by hand* next to the raw bytes, not derived
// from them. That makes the cross-protocol test meaningful: the client's MIME
// parser is checked against a human's reading of the message, rather than
// against another copy of itself.
Body_Part_Spec :: struct {
	part_id:     string,
	blob_id:     string,
	type:        string,
	charset:     string,
	name:        string,
	disposition: string,
	cid:         string,
	size:        int,
	value:       string, // for text parts: the decoded UTF-8 text
	sub_parts:   []Body_Part_Spec,
}

Decomp :: struct {
	subject:      string, // decoded, as a human reads it
	from_name:    string,
	from_email:   string,
	to_name:      string,
	to_email:     string,
	message_id:   string,
	in_reply_to:  []string,
	references:   []string,
	sent_at:      string, // ISO 8601, UTC
	preview:      string,
	text_body:    []Body_Part_Spec,
	html_body:    []Body_Part_Spec,
	attachments:  []Body_Part_Spec,
	structure:    Body_Part_Spec,
	has_attachment: bool,
	authored:     bool, // false = derived by the server's minimal parser
}

Message :: struct {
	uid:          u32,
	jid:          string, // JMAP Email id
	blob_id:      string,
	thread_id:    string,
	raw:          []u8,
	flags:        Flags,
	received:     i64, // unix seconds
	internaldate: string, // IMAP INTERNALDATE form
	expunged:     bool,
	decomp:       Decomp,
}

Mailbox :: struct {
	name:        string, // IMAP name, e.g. "Lists.odin"
	jid:         string, // JMAP Mailbox id
	role:        string, // inbox / archive / sent / trash / drafts / junk
	parent_jid:  string,
	uidnext:     u32,
	uidvalidity: u32,
	msgs:        [dynamic]Message,
	// Bumped on every change, so IDLE has something real to watch.
	version:     int,
}

Account :: struct {
	user:     string,
	password: string,
	email:    string,
	boxes:    [dynamic]Mailbox,
	// JMAP state: a monotonic counter rendered as a string, plus a change log.
	state:    int,
	changes:  [dynamic]Change,
}

Change_Kind :: enum u8 {
	Created,
	Updated,
	Destroyed,
}

Change :: struct {
	state: int, // the state this change produced
	jid:   string,
	kind:  Change_Kind,
}

Store :: struct {
	mu:       sync.Mutex,
	accounts: [dynamic]Account,
	next_uid_seed: u32,
	next_jid: int,
}

store: Store

HIERARCHY_DELIM :: "."

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

store_account :: proc(user: string) -> ^Account {
	for i in 0 ..< len(store.accounts) {
		if strings.equal_fold(store.accounts[i].user, user) {
			return &store.accounts[i]
		}
	}
	// Also accept the full address as the login name.
	for i in 0 ..< len(store.accounts) {
		if strings.equal_fold(store.accounts[i].email, user) {
			return &store.accounts[i]
		}
	}
	return nil
}

store_account_by_email :: proc(email: string) -> ^Account {
	e := strings.to_lower(strings.trim_space(email), context.temp_allocator)
	for i in 0 ..< len(store.accounts) {
		if strings.equal_fold(store.accounts[i].email, e) {
			return &store.accounts[i]
		}
	}
	return nil
}

account_box :: proc(a: ^Account, name: string) -> ^Mailbox {
	for i in 0 ..< len(a.boxes) {
		if strings.equal_fold(a.boxes[i].name, name) {
			return &a.boxes[i]
		}
	}
	return nil
}

account_box_by_jid :: proc(a: ^Account, jid: string) -> ^Mailbox {
	for i in 0 ..< len(a.boxes) {
		if a.boxes[i].jid == jid {
			return &a.boxes[i]
		}
	}
	return nil
}

account_message_by_jid :: proc(a: ^Account, jid: string) -> (^Mailbox, ^Message) {
	for i in 0 ..< len(a.boxes) {
		for k in 0 ..< len(a.boxes[i].msgs) {
			if a.boxes[i].msgs[k].jid == jid && !a.boxes[i].msgs[k].expunged {
				return &a.boxes[i], &a.boxes[i].msgs[k]
			}
		}
	}
	return nil, nil
}

// live returns the messages that have not been expunged, which is what every
// protocol's sequence numbering is based on.
box_live :: proc(b: ^Mailbox, allocator := context.allocator) -> []^Message {
	out := make([dynamic]^Message, 0, len(b.msgs), allocator)
	for i in 0 ..< len(b.msgs) {
		if !b.msgs[i].expunged {
			append(&out, &b.msgs[i])
		}
	}
	return out[:]
}

box_count :: proc(b: ^Mailbox) -> (n: int) {
	for m in b.msgs {
		if !m.expunged {
			n += 1
		}
	}
	return
}

box_unseen :: proc(b: ^Mailbox) -> (n: int) {
	for m in b.msgs {
		if !m.expunged && .Seen not_in m.flags {
			n += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Mutation
// ---------------------------------------------------------------------------

account_bump :: proc(a: ^Account, jid: string, kind: Change_Kind) {
	a.state += 1
	append(&a.changes, Change{state = a.state, jid = strings.clone(jid), kind = kind})
}

account_state_string :: proc(a: ^Account, allocator := context.allocator) -> string {
	return fmt.aprintf("s%d", a.state, allocator = allocator)
}

// store_deliver puts a message into a mailbox, assigning every identifier the
// three protocols need: an IMAP UID, a JMAP id and a blob id.
store_deliver :: proc(a: ^Account, b: ^Mailbox, raw: []u8, flags: Flags, decomp: Decomp) -> ^Message {
	store.next_jid += 1
	now := time.to_unix_seconds(time.now())
	m := Message {
		uid          = b.uidnext,
		jid          = fmt.aprintf("M%04d", store.next_jid),
		blob_id      = fmt.aprintf("B%04d", store.next_jid),
		raw          = raw,
		flags        = flags | {.Recent},
		received     = now,
		internaldate = imap_internaldate(now),
		decomp       = decomp,
	}
	// Threading on the server side is by Message-ID chain, same as the client.
	m.thread_id = thread_id_for(a, m.decomp)
	append(&b.msgs, m)
	b.uidnext += 1
	b.version += 1
	account_bump(a, m.jid, .Created)
	return &b.msgs[len(b.msgs) - 1]
}

// thread_id_for groups by the References chain: a message whose In-Reply-To or
// References names a message already here joins that thread.
thread_id_for :: proc(a: ^Account, d: Decomp) -> string {
	refs := make([dynamic]string, 0, 8, context.temp_allocator)
	for r in d.references {
		append(&refs, r)
	}
	for r in d.in_reply_to {
		append(&refs, r)
	}
	for i in 0 ..< len(a.boxes) {
		for m in a.boxes[i].msgs {
			if m.expunged {
				continue
			}
			for r in refs {
				if m.decomp.message_id == r {
					return m.thread_id
				}
			}
			// The reverse link too: this message may be the parent of one we
			// already hold.
			for r2 in m.decomp.references {
				if r2 == d.message_id {
					return m.thread_id
				}
			}
			for r2 in m.decomp.in_reply_to {
				if r2 == d.message_id {
					return m.thread_id
				}
			}
		}
	}
	store.next_jid += 1
	return fmt.aprintf("T%04d", store.next_jid)
}

imap_internaldate :: proc(unix: i64, allocator := context.allocator) -> string {
	MON := [12]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}
	days := unix / 86400
	secs := unix % 86400
	if secs < 0 {secs += 86400;days -= 1}
	y, mo, d := civil_from_days(days)
	return fmt.aprintf(
		"%02d-%s-%04d %02d:%02d:%02d +0000",
		d,
		MON[mo - 1],
		y,
		secs / 3600,
		secs / 60 % 60,
		secs % 60,
		allocator = allocator,
	)
}

iso8601 :: proc(unix: i64, allocator := context.allocator) -> string {
	days := unix / 86400
	secs := unix % 86400
	if secs < 0 {secs += 86400;days -= 1}
	y, mo, d := civil_from_days(days)
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		mo,
		d,
		secs / 3600,
		secs / 60 % 60,
		secs % 60,
		allocator = allocator,
	)
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
