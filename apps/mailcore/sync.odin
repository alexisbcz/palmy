package main

// Protocol -> Maildir. One function per protocol, and one comparator that
// checks they produced the same thing.
//
// The three protocols know different amounts, and the sync functions are
// honest about that rather than filling the gaps with invention:
//
//	IMAP   folders, server-side flags, UIDs    -> every folder, flags written
//	JMAP   mailboxes, keywords, state tokens   -> every mailbox, flags written
//	POP3   one undifferentiated spool, no flags-> INBOX only, everything in new/
//
// A POP3 sync therefore *cannot* produce the same Maildir as the other two,
// and `maildir_digest` is built to make the difference visible in exactly one
// place — the flags — while still comparing the message bytes exactly.

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// IMAP
// ---------------------------------------------------------------------------

Imap_Sync_Result :: struct {
	folder:    string,
	fetched:   int,
	bytes:     int,
	uidvalidity: u32,
	delivered: []string,
	uids:      []u32,
}

// imap_flags_to_maildir maps RFC 3501 system flags. `\Recent` has no Maildir
// equivalent that survives a restart (it is "no client has seen this session"),
// and is expressed by leaving the message in new/ instead.
imap_flags_to_maildir :: proc(flags: []string) -> (f: Maildir_Flags) {
	for fl in flags {
		switch strings.to_lower(fl, context.temp_allocator) {
		case "\\seen":
			f |= {.Seen}
		case "\\answered":
			f |= {.Replied}
		case "\\flagged":
			f |= {.Flagged}
		case "\\deleted":
			f |= {.Trashed}
		case "\\draft":
			f |= {.Draft}
		}
	}
	return
}

maildir_flags_to_imap :: proc(f: Maildir_Flags, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 5, allocator)
	if .Seen in f {append(&out, "\\Seen")}
	if .Replied in f {append(&out, "\\Answered")}
	if .Flagged in f {append(&out, "\\Flagged")}
	if .Trashed in f {append(&out, "\\Deleted")}
	if .Draft in f {append(&out, "\\Draft")}
	return out[:]
}

// imap_sync fetches a whole mailbox into a Maildir folder.
//
// It uses BODY.PEEK[] rather than BODY[], because BODY[] sets \Seen as a side
// effect — a fetch that marks the user's mail as read is a bug, and it is one
// that only shows up after the fact.
imap_sync :: proc(
	im: ^IMAP,
	md: ^Maildir,
	mailbox: string,
	folder: string,
	allocator := context.allocator,
) -> (
	res: Imap_Sync_Result,
	err: string,
) {
	res.folder = folder
	// The folder is created first, unconditionally: an empty mailbox on the
	// server must still appear on disk.
	if ee := maildir_ensure_folder(md, folder); ee != "" {
		return res, ee
	}
	st, se := imap_select(im, mailbox, true)
	if se != "" {
		return res, se
	}
	res.uidvalidity = st.uidvalidity
	if st.exists == 0 {
		return res, ""
	}

	frs, fe := imap_uid_fetch(im, "1:*", "(UID FLAGS RFC822.SIZE BODY.PEEK[])", allocator)
	if fe != "" {
		return res, fe
	}
	names := make([dynamic]string, 0, len(frs), allocator)
	uids := make([dynamic]u32, 0, len(frs), allocator)
	for fr in frs {
		// The server may spell the returned item either way.
		raw, ok := fetch_bytes(fr, "BODY[]")
		if !ok {
			raw, ok = fetch_bytes(fr, "BODY.PEEK[]")
		}
		if !ok {
			raw, ok = fetch_bytes(fr, "RFC822")
		}
		if !ok {
			return res, fmt.aprintf("UID %d came back with no body", fr.uid)
		}
		flags := imap_flags_to_maildir(fr.flags)
		// A message the server has not marked \Seen goes to new/ with no info
		// field, which is what Maildir means by "unread".
		name, de := maildir_deliver(md, folder, raw, flags, flags == {}, allocator)
		if de != "" {
			return res, de
		}
		append(&names, name)
		append(&uids, fr.uid)
		res.fetched += 1
		res.bytes += len(raw)
	}
	res.delivered = names[:]
	res.uids = uids[:]
	return res, ""
}

// imap_sync_all walks every LISTed mailbox. The IMAP hierarchy delimiter is
// translated to '/' so that `maildir_folder_dir` can flatten it back to the
// Maildir++ dotted form.
imap_sync_all :: proc(
	im: ^IMAP,
	md: ^Maildir,
	allocator := context.allocator,
) -> (
	results: []Imap_Sync_Result,
	err: string,
) {
	boxes, le := imap_list(im, "", "*", allocator)
	if le != "" {
		return nil, le
	}
	out := make([dynamic]Imap_Sync_Result, 0, len(boxes), allocator)
	for b in boxes {
		skip := false
		for a in b.attrs {
			if strings.equal_fold(a, "\\Noselect") {
				skip = true
			}
		}
		if skip {
			continue
		}
		folder := b.name
		if b.delim != "" && b.delim != "/" {
			folder, _ = strings.replace_all(b.name, b.delim, "/", allocator)
		}
		r, e := imap_sync(im, md, b.raw_name, folder, allocator)
		if e != "" {
			return out[:], fmt.aprintf("syncing %q: %s", b.name, e)
		}
		append(&out, r)
	}
	return out[:], ""
}

// ---------------------------------------------------------------------------
// Comparing what the protocols produced
// ---------------------------------------------------------------------------

Msg_Digest :: struct {
	size:       int,
	hash:       u32, // crc32 of the bytes exactly as stored
	// hash_eol is the same, over the bytes with a final CRLF guaranteed.
	//
	// It exists for one honest reason: POP3's multiline response is defined in
	// terms of CRLF-terminated lines, so a message whose last line has no
	// terminator — a truncated transfer, say — comes back with one added. No
	// POP3 server can do otherwise and no POP3 client can tell. Comparing on
	// this hash isolates that single, unavoidable difference instead of
	// letting it mask a real one.
	hash_eol:   u32,
	message_id: string,
	subject:    string,
	flags:      Maildir_Flags,
	in_new:     bool,
}

Maildir_Digest :: struct {
	folder: string,
	msgs:   []Msg_Digest,
}

// maildir_digest reads a folder and summarises every message in it, sorted so
// that two independently built Maildirs can be compared element by element.
// The hash is over the raw bytes, so "the same message" means byte identical,
// not merely similar.
maildir_digest :: proc(
	md: ^Maildir,
	folder: string,
	allocator := context.allocator,
) -> Maildir_Digest {
	entries := maildir_list(md, folder, context.temp_allocator)
	out := make([dynamic]Msg_Digest, 0, len(entries), allocator)
	for e in entries {
		data, re := maildir_read(e, context.temp_allocator)
		if re != "" {
			continue
		}
		m := parse_message(data, context.temp_allocator)
		eol := data
		if len(data) < 2 || string(data[len(data) - 2:]) != "\r\n" {
			padded := make([dynamic]u8, 0, len(data) + 2, context.temp_allocator)
			append(&padded, ..data)
			if len(padded) > 0 && padded[len(padded) - 1] == '\n' {
				pop(&padded)
			}
			append(&padded, '\r', '\n')
			eol = padded[:]
		}
		append(
			&out,
			Msg_Digest {
				size = len(data),
				hash = hash.crc32(data),
				hash_eol = hash.crc32(eol),
				message_id = strings.clone(m.message_id, allocator),
				subject = strings.clone(m.subject, allocator),
				flags = e.flags,
				in_new = e.in_new,
			},
		)
	}
	slice.sort_by(out[:], proc(a, b: Msg_Digest) -> bool {
		if a.message_id != b.message_id {
			return a.message_id < b.message_id
		}
		return a.hash < b.hash
	})
	return Maildir_Digest{folder = strings.clone(folder, allocator), msgs = out[:]}
}

Digest_Diff :: struct {
	same_bytes:     bool, // every message is byte identical and in the same set
	same_flags:     bool,
	count_a:        int,
	count_b:        int,
	only_in_a:      []string,
	only_in_b:      []string,
	flag_differs:   []string,
	// How many messages matched only after the final-CRLF normalisation —
	// i.e. the exact bytes differ by nothing but a missing line terminator.
	eol_normalised: int,
	detail:         string,
}

// digest_compare is the cross-protocol equivalence check.
//
// `ignore_flags` exists because POP3 has no flags at all: comparing a POP3
// Maildir against an IMAP one with flags enabled would fail for a reason that
// is correct behaviour, not a bug. The byte comparison is never relaxed.
digest_compare :: proc(
	a, b: Maildir_Digest,
	ignore_flags := false,
	allow_final_crlf := false,
	allocator := context.allocator,
) -> Digest_Diff {
	d: Digest_Diff
	d.count_a = len(a.msgs)
	d.count_b = len(b.msgs)
	only_a := make([dynamic]string, 0, 4, allocator)
	only_b := make([dynamic]string, 0, 4, allocator)
	fdiff := make([dynamic]string, 0, 4, allocator)

	key :: proc(m: Msg_Digest, loose: bool, allocator := context.allocator) -> string {
		if loose {
			return fmt.aprintf("%s/%08x", m.message_id, m.hash_eol, allocator = allocator)
		}
		return fmt.aprintf("%s/%08x/%d", m.message_id, m.hash, m.size, allocator = allocator)
	}
	loose := allow_final_crlf

	in_b := make(map[string]Msg_Digest, len(b.msgs) * 2 + 4, context.temp_allocator)
	for m in b.msgs {
		in_b[key(m, loose, context.temp_allocator)] = m
	}
	in_a := make(map[string]bool, len(a.msgs) * 2 + 4, context.temp_allocator)
	for m in a.msgs {
		in_a[key(m, loose, context.temp_allocator)] = true
	}

	for m in a.msgs {
		k := key(m, loose, context.temp_allocator)
		other, has := in_b[k]
		if !has {
			append(&only_a, fmt.aprintf("%s (%s)", m.message_id, m.subject, allocator = allocator))
			continue
		}
		if m.hash != other.hash {
			d.eol_normalised += 1
		}
		if !ignore_flags && other.flags != m.flags {
			append(
				&fdiff,
				fmt.aprintf(
					"%s: %q vs %q",
					m.message_id,
					maildir_flags_string(m.flags, allocator),
					maildir_flags_string(other.flags, allocator),
					allocator = allocator,
				),
			)
		}
	}
	for m in b.msgs {
		if !in_a[key(m, loose, context.temp_allocator)] {
			append(&only_b, fmt.aprintf("%s (%s)", m.message_id, m.subject, allocator = allocator))
		}
	}

	d.only_in_a = only_a[:]
	d.only_in_b = only_b[:]
	d.flag_differs = fdiff[:]
	d.same_bytes = len(only_a) == 0 && len(only_b) == 0 && len(a.msgs) == len(b.msgs)
	d.same_flags = len(fdiff) == 0
	d.detail = fmt.aprintf(
		"%d vs %d messages; %d only in the first, %d only in the second, %d with different flags, %d matched only after the final-CRLF normalisation",
		d.count_a,
		d.count_b,
		len(only_a),
		len(only_b),
		len(fdiff),
		d.eol_normalised,
		allocator = allocator,
	)
	return d
}

// ---------------------------------------------------------------------------
// Threading a Maildir folder
// ---------------------------------------------------------------------------

// maildir_thread reads a folder and threads it, which is the operation the UI
// actually needs and the one worth exercising end to end.
maildir_thread :: proc(
	md: ^Maildir,
	folder: string,
	use_subject := true,
	allocator := context.allocator,
) -> (
	t: Threading,
	items: []Threadable,
) {
	entries := maildir_list(md, folder, allocator)
	rows := make([dynamic]Threadable, 0, len(entries), allocator)
	for e in entries {
		data, re := maildir_read(e, allocator)
		if re != "" {
			continue
		}
		m := parse_message(data, allocator)
		append(
			&rows,
			Threadable {
				key = e.name,
				message_id = m.message_id,
				in_reply_to = m.in_reply_to,
				references = m.references,
				subject = m.subject,
				date = m.date.ok ? m.date.unix : 0,
			},
		)
	}
	items = rows[:]
	return thread_messages(items, use_subject, allocator), items
}
