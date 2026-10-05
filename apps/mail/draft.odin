// Drafts: the composer's work survives the process.
//
// WHY THIS EXISTS. Until now the composer held everything in memory and
// nothing anywhere else: Escape, a close, a crash or a power cut and the text
// was gone. That is the one failure in this client that destroys something the
// user made, so it is the one worth the most care.
//
// TWO PLACES, FOR TWO DIFFERENT JOBS.
//
//   The slot.   `<data dir>/draft.compose` — one file, rewritten in place
//               about once a second while the composer is open and the text
//               has changed. It is a scratch file, not mail: it holds the
//               cursor and which field had focus as well as the text, so
//               reopening it puts the caret back where it was. One slot is
//               enough because only one composition can be open at a time.
//
//   Drafts/.    When a second composition starts while the first still holds
//               unsent text, the first is written into the account's own
//               `.Drafts` Maildir as a real message with the `D` flag, where
//               it is visible in the folder list like any other message and
//               can be reopened with Enter. Nothing is ever dropped to make
//               room for something else.
//
// SAFETY. Both paths are inside the app's own data directory — the slot
// directly, the parked draft inside the account root, which `--maildir` or the
// config chose. Nothing here opens a socket; a draft is not a sent message and
// this binary cannot send one anyway. See compose.odin.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// How long the composer may hold unsaved text. A second is short enough that
// what is lost to a power cut is a few words, and long enough that a file is
// not rewritten on every keystroke. The offscreen harness sets it to zero so a
// test does not have to sleep to watch a save happen.
draft_autosave_seconds: f64 = 1.0

DRAFT_SLOT :: "draft.compose"

draft_path :: proc(st: ^State, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s", st.data_dir, DRAFT_SLOT, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Is there anything worth keeping?
// ---------------------------------------------------------------------------

// compose_is_empty is "there is no message here", not "no bytes here": a reply
// arrives with two blank lines above the quote, and that is still nothing.
compose_is_empty :: proc(c: ^Composer) -> bool {
	if strings.trim_space(le_text(&c.to)) != "" {
		return false
	}
	if strings.trim_space(le_text(&c.cc)) != "" {
		return false
	}
	if strings.trim_space(le_text(&c.subject)) != "" {
		return false
	}
	return strings.trim_space(buf_text(&c.body, context.temp_allocator)) == ""
}

// compose_hash is FNV-1a over everything a draft would have to restore. It is
// taken once a second rather than once a frame, and over a composer body —
// kilobytes — which makes it free in the only sense that matters here.
compose_hash :: proc(c: ^Composer) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, s: string) {
		for i in 0 ..< len(s) {
			h^ = (h^ ~ u64(s[i])) * 0x100000001b3
		}
		h^ = (h^ ~ 0xff) * 0x100000001b3 // a separator, so "ab"+"c" ≠ "a"+"bc"
	}
	mix(&h, le_text(&c.to))
	mix(&h, le_text(&c.cc))
	mix(&h, le_text(&c.subject))
	mix(&h, buf_text(&c.body, context.temp_allocator))
	mix(&h, c.in_reply_to)
	mix(&h, c.references)
	h = (h ~ u64(c.mode)) * 0x100000001b3
	return h
}

// compose_dirty is "somebody typed something that is not on disk yet". A reply
// whose quote was never touched is not dirty, which is what keeps Escape out
// of a reply from leaving a draft nobody wrote.
compose_dirty :: proc(c: ^Composer) -> bool {
	if compose_is_empty(c) {
		return false
	}
	return compose_hash(c) != c.open_hash
}

// ---------------------------------------------------------------------------
// The slot
// ---------------------------------------------------------------------------

// draft_text is the slot's format: single-line headers, a blank line, then the
// body verbatim. Every header value here comes from a Line_Edit, which cannot
// hold a newline, so nothing needs escaping and the file stays readable in an
// editor — which is the point, since it is the last copy of something.
draft_text :: proc(st: ^State, allocator := context.allocator) -> string {
	c := &st.comp
	b := strings.builder_make(allocator)
	a := st.accounts[clamp(c.account, 0, max(0, len(st.accounts) - 1))]
	fmt.sbprintf(&b, "Palmy-Draft: 1\n")
	fmt.sbprintf(&b, "Saved: %d\n", time.now()._nsec)
	fmt.sbprintf(&b, "Mode: %v\n", c.mode)
	fmt.sbprintf(&b, "Account: %d\n", c.account)
	fmt.sbprintf(&b, "Account-Address: %s\n", a.address)
	fmt.sbprintf(&b, "Field: %v\n", c.field)
	fmt.sbprintf(&b, "Cursor: %d,%d\n", c.body.cur.line, c.body.cur.col)
	fmt.sbprintf(&b, "To: %s\n", le_text(&c.to))
	fmt.sbprintf(&b, "Cc: %s\n", le_text(&c.cc))
	fmt.sbprintf(&b, "Subject: %s\n", le_text(&c.subject))
	fmt.sbprintf(&b, "In-Reply-To: %s\n", c.in_reply_to)
	fmt.sbprintf(&b, "References: %s\n", c.references)
	fmt.sbprintf(&b, "Origin: %s\n", c.origin_path)
	fmt.sbprintf(&b, "\n")
	strings.write_string(&b, buf_text(&c.body, context.temp_allocator))
	return strings.to_string(b)
}

Draft :: struct {
	saved:       time.Time,
	mode:        Compose_Mode,
	field:       Compose_Field,
	account:     int,
	address:     string,
	cursor:      Pos,
	to:          string,
	cc:          string,
	subject:     string,
	in_reply_to: string,
	references:  string,
	origin:      string,
	body:        string,
	ok:          bool,
}

// draft_parse reads the slot back. Everything it returns points into `text`,
// so the caller keeps that alive for as long as it uses the result.
draft_parse :: proc(text: string) -> (d: Draft) {
	split := strings.index(text, "\n\n")
	head := text
	if split >= 0 {
		head = text[:split]
		d.body = text[split + 2:]
	}
	if !strings.has_prefix(head, "Palmy-Draft:") {
		return
	}
	rest := head
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := line[:colon]
		val := strings.trim_left_space(line[colon + 1:])
		switch key {
		case "Saved":
			n: i64 = 0
			for i in 0 ..< len(val) {
				if val[i] >= '0' && val[i] <= '9' {
					n = n * 10 + i64(val[i] - '0')
				}
			}
			d.saved = time.Time{_nsec = n}
		case "Mode":
			for m in Compose_Mode {
				if fmt.tprintf("%v", m) == val {
					d.mode = m
				}
			}
		case "Field":
			for f in Compose_Field {
				if fmt.tprintf("%v", f) == val {
					d.field = f
				}
			}
		case "Account":
			d.account = atoi_simple(val)
		case "Account-Address":
			d.address = val
		case "Cursor":
			if comma := strings.index_byte(val, ','); comma > 0 {
				d.cursor = Pos{atoi_simple(val[:comma]), atoi_simple(val[comma + 1:])}
			}
		case "To":
			d.to = val
		case "Cc":
			d.cc = val
		case "Subject":
			d.subject = val
		case "In-Reply-To":
			d.in_reply_to = val
		case "References":
			d.references = val
		case "Origin":
			d.origin = val
		}
	}
	d.ok = true
	return
}

atoi_simple :: proc(s: string) -> int {
	n, neg := 0, false
	for i in 0 ..< len(s) {
		if i == 0 && s[i] == '-' {
			neg = true
			continue
		}
		if s[i] < '0' || s[i] > '9' {
			break
		}
		n = n * 10 + int(s[i] - '0')
	}
	return neg ? -n : n
}

// draft_save writes the slot, through a temporary file and a rename so that a
// crash mid-write cannot leave half a draft where the whole one was.
draft_save :: proc(st: ^State) -> bool {
	c := &st.comp
	if compose_is_empty(c) {
		draft_discard(st)
		c.saved_hash = compose_hash(c)
		return false
	}
	os.make_directory_all(st.data_dir)
	path := draft_path(st, context.temp_allocator)
	tmp := tfmt("%s.tmp", path)
	text := draft_text(st, context.temp_allocator)
	if !write_file(tmp, transmute([]u8)text) {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	c.saved_hash = compose_hash(c)
	c.saved_at = time.now()
	c.saved_any = true
	st.draft_waiting = false
	return true
}

// draft_discard removes the slot. It does not touch a parked draft in
// `.Drafts`: that is mail, and mail is deleted the way mail is deleted.
draft_discard :: proc(st: ^State) {
	path := draft_path(st, context.temp_allocator)
	if os.exists(path) {
		os.remove(path)
	}
	st.comp.saved_any = false
	st.draft_waiting = false
	delete(st.draft_label)
	st.draft_label = ""
}

// draft_tick is called once a frame and does nothing almost every time.
draft_tick :: proc(st: ^State) {
	c := &st.comp
	if !c.open {
		return
	}
	now := time.now()
	if c.last_tick._nsec != 0 &&
	   time.duration_seconds(time.diff(c.last_tick, now)) < draft_autosave_seconds {
		return
	}
	c.last_tick = now
	h := compose_hash(c)
	if h == c.saved_hash && c.saved_any {
		return
	}
	if !compose_dirty(c) {
		// Typed and then taken all the way back out again: the slot should go
		// too, rather than keep offering something the user undid.
		if c.saved_any {
			draft_discard(st)
			c.saved_hash = h
		}
		return
	}
	draft_save(st)
}

// draft_peek reads the slot at startup, without opening the composer. Walking
// into a half-written message is startling; being told one is waiting is not.
draft_peek :: proc(st: ^State) {
	raw, ok := read_file(draft_path(st, context.temp_allocator), context.temp_allocator)
	if !ok || len(raw) == 0 {
		return
	}
	d := draft_parse(string(raw))
	if !d.ok {
		return
	}
	what := strings.trim_space(d.subject)
	if what == "" {
		what = strings.trim_space(d.to)
	}
	if what == "" {
		what = first_line_of(d.body)
	}
	if what == "" {
		what = "an unsent message"
	}
	delete(st.draft_label)
	st.draft_label = fmt.aprintf(
		"%s · %s",
		what,
		full_date(d.saved, st.tz_offset, context.temp_allocator),
	)
	st.draft_waiting = true
}

first_line_of :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = t[:i]
	}
	if len(t) > 48 {
		t = t[:48]
	}
	return t
}

// draft_load_into fills the composer from the slot. It does not open it: the
// one caller that wants it open says so, and the one that only wants the text
// in hand so it can be parked does not.
draft_load_into :: proc(st: ^State) -> bool {
	raw, ok := read_file(draft_path(st, context.temp_allocator), context.temp_allocator)
	if !ok || len(raw) == 0 {
		return false
	}
	d := draft_parse(string(raw))
	if !d.ok {
		return false
	}
	c := &st.comp
	compose_reset(c)
	c.mode = d.mode
	c.field = d.field
	c.account = clamp(d.account, 0, max(0, len(st.accounts) - 1))
	// The account list can have changed between runs; the address is what the
	// draft really meant, so it wins over the index when it still matches one.
	if d.address != "" {
		for a, i in st.accounts {
			if a.address == d.address {
				c.account = i
				break
			}
		}
	}
	le_set(&c.to, d.to)
	le_set(&c.cc, d.cc)
	le_set(&c.subject, d.subject)
	c.in_reply_to = strings.clone(d.in_reply_to)
	c.references = strings.clone(d.references)
	c.origin_path = strings.clone(d.origin)
	buf_init(&c.body, d.body)
	c.body.cur = buf_clamp(&c.body, d.cursor)
	c.saved_at = d.saved
	c.saved_any = true
	c.saved_hash = compose_hash(c)
	// A restored draft is dirty by definition: it is not what an empty
	// composer would hold, and closing it again must keep it.
	c.open_hash = 0
	return true
}

// draft_restore is C on a waiting draft: the composer opens exactly where it
// was left, caret included.
draft_restore :: proc(st: ^State) -> bool {
	if !draft_load_into(st) {
		st.draft_waiting = false
		return false
	}
	c := &st.comp
	c.open = true
	st.pane = .Compose
	st.draft_waiting = false
	note(st, tfmt("Picked your draft back up — saved %s", full_date(c.saved_at, st.tz_offset, context.temp_allocator)))
	return true
}

// ---------------------------------------------------------------------------
// Parking: a draft that has to make room for another one
// ---------------------------------------------------------------------------

// park_draft writes whatever the composer is holding into the account's own
// `.Drafts` Maildir and clears the slot, so starting a reply never costs the
// message already being written.
//
// It returns false when there was nothing to park, which is the common case.
park_draft :: proc(st: ^State) -> bool {
	c := &st.comp
	// A draft left on disk by a previous run and never picked up is parked
	// too: the next composition would otherwise overwrite its slot.
	if st.draft_waiting && !compose_dirty(c) {
		if !draft_load_into(st) {
			st.draft_waiting = false
			return false
		}
	}
	if !compose_dirty(c) {
		return false
	}

	content := build_message(st, true, context.temp_allocator)
	where_, ok := drafts_destination(st, c.account, context.temp_allocator)
	if !ok {
		note(st, "Could not find anywhere to keep the draft, so it is still in the composer.")
		return false
	}
	path, wok := maildir_store_draft(where_, content)
	if !wok {
		note(st, "Could not write the draft out, so it is still in the composer.")
		return false
	}
	// An edited draft is one draft, not two: the file it came from goes.
	if c.origin_path != "" && c.origin_path != path && os.exists(c.origin_path) {
		os.remove(c.origin_path)
	}
	draft_discard(st)
	what := strings.trim_space(le_text(&c.subject))
	if what == "" {
		what = "Your draft"
	}
	compose_reset(c)
	reload_all(st)
	note(st, tfmt("“%s” was kept in Drafts", what))
	return true
}

// drafts_destination is the account's Drafts folder, created if the account
// has never had one — the same thing `archive_selection` does for Archive.
// POP3 has no folders at all, so a draft for a POP3 account goes into the
// app's own directory instead, and is named so it is obvious which it was.
drafts_destination :: proc(st: ^State, account: int, allocator := context.allocator) -> (string, bool) {
	ai := clamp(account, 0, max(0, len(st.accounts) - 1))
	if len(st.accounts) == 0 {
		return "", false
	}
	if ok, _ := can_file(st, ai); ok {
		if fi := ensure_role_folder(st, ai, .Drafts, "Drafts"); fi >= 0 {
			return strings.clone(st.folders[fi].path, allocator), true
		}
	}
	dir := fmt.aprintf("%s/drafts", st.data_dir, allocator = allocator)
	if !make_folder_dir(dir) {
		delete(dir, allocator)
		return "", false
	}
	return dir, true
}

// maildir_store_draft writes into `cur/` with the `D` and `S` flags set,
// through tmp/ and a rename like every other delivery here. `cur/` rather than
// `new/`, and Seen, because a draft the user wrote is not unread mail.
maildir_store_draft :: proc(folder: string, content: string) -> (path: string, ok: bool) {
	for sub in ([?]string{"tmp", "new", "cur"}) {
		os.make_directory_all(tfmt("%s/%s", folder, sub))
	}
	name := fmt.tprintf(
		"%d.D%dP%d.palmy",
		time.now()._nsec / 1_000_000_000,
		draft_counter_next(),
		os.get_pid(),
	)
	tmp := tfmt("%s/tmp/%s", folder, name)
	if !write_file(tmp, transmute([]u8)content) {
		return "", false
	}
	dest := tfmt("%s/cur/%s", folder, maildir_name_with_flags(name, {.Draft, .Seen}, context.temp_allocator))
	if os.rename(tmp, dest) != nil {
		os.remove(tmp)
		return "", false
	}
	return strings.clone(dest), true
}

@(private = "file")
draft_counter := 0

draft_counter_next :: proc() -> int {
	draft_counter += 1
	return draft_counter
}

// ---------------------------------------------------------------------------
// Reopening a parked draft
// ---------------------------------------------------------------------------

// compose_edit_draft loads a message out of the Drafts folder back into the
// composer. The file stays where it is until the composition is sent,
// discarded or parked again — nothing is unlinked on the way in, because a
// client that deleted your draft in order to show it to you would be worse
// than one that never kept it.
compose_edit_draft :: proc(st: ^State, mi: int) -> bool {
	if mi < 0 || mi >= len(st.messages) {
		return false
	}
	// Parking whatever is already in the composer reloads the tree, so the
	// draft being opened is found again by path afterwards.
	idx := mi
	if compose_dirty(&st.comp) || st.draft_waiting {
		keep := strings.clone(st.messages[idx].path, context.temp_allocator)
		if park_draft(st) {
			idx = message_at_path(st, keep)
			if idx < 0 {
				note(st, "That draft has moved since the list was built.")
				return false
			}
		}
	}
	m := st.messages[idx]
	c := &st.comp
	compose_reset(c)
	c.open = true
	c.mode = .New
	c.field = .Body
	c.account = m.account
	le_set(&c.to, join_addresses(m.to, context.temp_allocator))
	le_set(&c.cc, join_addresses(m.cc, context.temp_allocator))
	le_set(&c.subject, m.subject)
	c.in_reply_to = strings.clone(m.in_reply_to)
	refs := make([dynamic]string, 0, len(m.refs), context.temp_allocator)
	for r in m.refs {
		append(&refs, fmt.tprintf("<%s>", r))
	}
	c.references = strings.join(refs[:], " ")
	c.origin_path = strings.clone(m.path)
	buf_init(&c.body, m.body)
	c.body.cur = {0, 0}
	// Loaded from a file that already exists, so this is a draft already: it
	// must be kept on close even if not another character is typed.
	c.open_hash = 0
	c.saved_any = false
	c.saved_hash = 0
	st.pane = .Compose
	note(st, "Editing a draft from Drafts")
	return true
}

// is_draft_message is "this row is a draft, so Enter should open the composer
// rather than the reader".
is_draft_message :: proc(st: ^State, mi: int) -> bool {
	if mi < 0 || mi >= len(st.messages) {
		return false
	}
	m := st.messages[mi]
	if .Draft not_in m.flags {
		return false
	}
	if m.folder < 0 || m.folder >= len(st.folders) {
		return false
	}
	return st.folders[m.folder].role == .Drafts
}
