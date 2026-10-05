// Selecting a folder, threading what is in it, searching across everything,
// and flattening the result into the rows the list pane and the keyboard walk.
package main

import "core:fmt"
import "core:strings"
import "core:time"

account_of_folder :: proc(st: ^State, fi: int) -> int {
	if fi < 0 || fi >= len(st.folders) {
		return 0
	}
	return st.folders[fi].account
}

note :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = 0
}

// ---------------------------------------------------------------------------
// The sidebar, flattened
// ---------------------------------------------------------------------------

rebuild_sidebar :: proc(st: ^State) {
	clear(&st.side_rows)
	for a, ai in st.accounts {
		append(&st.side_rows, Side_Row{kind = .Account, account = ai, folder = -1})
		if a.collapsed {
			continue
		}
		for f, fi in st.folders {
			if f.account == ai {
				append(&st.side_rows, Side_Row{kind = .Folder, account = ai, folder = fi})
			}
		}
	}
	st.side_sel = clamp(st.side_sel, 0, max(0, len(st.side_rows) - 1))
}

// side_row_of_folder finds where a folder sits in the flattened sidebar, so
// selecting a folder by any route keeps the sidebar cursor in step.
side_row_of_folder :: proc(st: ^State, fi: int) -> int {
	for r, i in st.side_rows {
		if r.kind == .Folder && r.folder == fi {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Selecting a folder
// ---------------------------------------------------------------------------

select_folder :: proc(st: ^State, fi: int) {
	if fi < 0 || fi >= len(st.folders) {
		return
	}
	st.folder_sel = fi
	st.searching = false
	le_clear(&st.query)
	st.row_sel = 0
	st.list_scroll_home = true
	rebuild_list(st)
	if i := side_row_of_folder(st, fi); i >= 0 {
		st.side_sel = i
	}
}

// rebuild_list threads whatever the current view is — a folder, or a set of
// search hits — and flattens it into rows.
rebuild_list :: proc(st: ^State) {
	set := make([dynamic]int, 0, 256, context.temp_allocator)
	if st.searching {
		for m, i in st.messages {
			if msg_hidden(st, m) {
				continue
			}
			if matches_query(st, m, le_text(&st.query)) {
				append(&set, i)
			}
		}
	} else {
		for m, i in st.messages {
			if msg_hidden(st, m) {
				continue
			}
			if m.folder == st.folder_sel {
				append(&set, i)
			}
		}
	}
	build_threads(st, set[:])
	rebuild_rows(st)
	st.row_sel = clamp(st.row_sel, 0, max(0, len(st.rows) - 1))
	sync_reader(st)
}

rebuild_rows :: proc(st: ^State) {
	keep_msg := current_message(st)
	clear(&st.rows)
	for t, ti in st.threads {
		append(&st.rows, Row{kind = .Thread, thread = ti, msg = -1, depth = 0})
		if t.expanded && len(t.msgs) > 1 {
			for mi in t.msgs {
				append(
					&st.rows,
					Row {
						kind = .Message,
						thread = ti,
						msg = mi,
						depth = min(st.messages[mi].depth, 4),
					},
				)
			}
		}
	}
	st.row_sel = clamp(st.row_sel, 0, max(0, len(st.rows) - 1))
	measure_rows(st)

	// Keep the cursor on whatever the user was looking at when the shape of
	// the list changed under them.
	if keep_msg >= 0 {
		for r, i in st.rows {
			if r.kind == .Message && r.msg == keep_msg {
				st.row_sel = i
				return
			}
		}
		for r, i in st.rows {
			if r.kind == .Thread && st.messages[keep_msg].thread == r.thread {
				st.row_sel = i
				return
			}
		}
	}
}

// row_height is fixed per kind, which is what makes the list virtualisable
// without measuring anything.
row_height :: proc(kind: Row_Kind) -> f32 {
	return kind == .Thread ? THREAD_ROW_H : MSG_ROW_H
}

// measure_rows lays out the row offsets once per rebuild rather than once per
// frame, so a few hundred conversations cost nothing to scroll through.
measure_rows :: proc(st: ^State) {
	resize(&st.row_y, len(st.rows))
	y := f32(0)
	for r, i in st.rows {
		st.row_y[i] = y
		y += row_height(r.kind)
	}
	st.list_h = y
}

// current_message is what the reader should show for the selected row: the
// message itself on a message row, the newest unread (or newest) on a thread.
current_message :: proc(st: ^State) -> int {
	if st.row_sel < 0 || st.row_sel >= len(st.rows) {
		return -1
	}
	r := st.rows[st.row_sel]
	if r.kind == .Message {
		return r.msg
	}
	if r.thread < 0 || r.thread >= len(st.threads) {
		return -1
	}
	t := st.threads[r.thread]
	if len(t.msgs) == 0 {
		return -1
	}
	best := -1
	for mi in t.msgs {
		if msg_unread(st.messages[mi]) {
			if best < 0 || st.messages[mi].date._nsec < st.messages[best].date._nsec {
				best = mi
			}
		}
	}
	if best >= 0 {
		return best
	}
	newest := t.msgs[0]
	for mi in t.msgs {
		if st.messages[mi].date._nsec > st.messages[newest].date._nsec {
			newest = mi
		}
	}
	return newest
}

sync_reader :: proc(st: ^State) {
	mi := current_message(st)
	if mi != st.reader_msg {
		st.reader_msg = mi
		st.read_scroll_home = true
		// A different message has different attachments, so the attachment
		// cursor cannot survive the change.
		st.att_sel = -1
	}
}

current_thread :: proc(st: ^State) -> int {
	if st.row_sel < 0 || st.row_sel >= len(st.rows) {
		return -1
	}
	return st.rows[st.row_sel].thread
}

// ---------------------------------------------------------------------------
// Search
//
// Every message carries a prebuilt lowercase blob of sender, recipients,
// subject and body, so a query is a substring scan over a few hundred strings
// — microseconds, which is what "instant" has to mean. Operators narrow it:
// from:, to:, subject:, is:unread, is:flagged, has:attachment, in:<folder>.
// ---------------------------------------------------------------------------

matches_query :: proc(st: ^State, m: Message, query: string) -> bool {
	q := strings.trim_space(query)
	if q == "" {
		return false
	}
	terms := strings.fields(q, context.temp_allocator)
	for raw in terms {
		term := strings.to_lower(raw, context.temp_allocator)
		if !matches_term(st, m, term) {
			return false
		}
	}
	return true
}

@(private = "file")
matches_term :: proc(st: ^State, m: Message, term: string) -> bool {
	if colon := strings.index_byte(term, ':'); colon > 0 {
		key := term[:colon]
		val := term[colon + 1:]
		switch key {
		case "from":
			return contains_fold(m.from.name, val) || contains_fold(m.from.email, val)
		case "to":
			for a in m.to {
				if contains_fold(a.name, val) || contains_fold(a.email, val) {
					return true
				}
			}
			for a in m.cc {
				if contains_fold(a.name, val) || contains_fold(a.email, val) {
					return true
				}
			}
			return false
		case "subject":
			return contains_fold(m.subject, val)
		case "body":
			return contains_fold(m.body, val)
		case "is":
			switch val {
			case "unread":
				return msg_unread(m)
			case "read", "seen":
				return !msg_unread(m)
			case "flagged", "starred":
				return .Flagged in m.flags
			case "answered", "replied":
				return .Answered in m.flags
			case "draft":
				return .Draft in m.flags
			}
			return false
		case "has":
			switch val {
			case "attachment", "attachments", "file":
				return len(m.attachments) > 0
			}
			return false
		case "in", "folder":
			if m.folder < 0 || m.folder >= len(st.folders) {
				return false
			}
			return contains_fold(st.folders[m.folder].name, val)
		}
	}
	return strings.contains(m.blob, term)
}

contains_fold :: proc(hay, needle: string) -> bool {
	if needle == "" {
		return true
	}
	return strings.contains(strings.to_lower(hay, context.temp_allocator), needle)
}

run_search :: proc(st: ^State) {
	q := strings.trim_space(le_text(&st.query))
	if q == "" {
		if st.searching {
			st.searching = false
			rebuild_list(st)
		}
		return
	}
	st.searching = true
	st.row_sel = 0
	st.list_scroll_home = true
	rebuild_list(st)
}

search_hit_count :: proc(st: ^State) -> int {
	n := 0
	for t in st.threads {
		n += len(t.msgs)
	}
	return n
}

// ---------------------------------------------------------------------------
// Dates, for a human
// ---------------------------------------------------------------------------

// relative_date is the message list's column: a clock today, a weekday this
// week, a day and month this year, a year before that.
relative_date :: proc(t, now: time.Time, offset: i64, allocator := context.allocator) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	lnow := time.Time{_nsec = now._nsec + offset * 1_000_000_000}
	y, mo, d := time.date(local)
	ny, nmo, nd := time.date(lnow)
	hh, mi, _ := time.clock(local)
	months := MONTHS

	if y == ny && mo == nmo && d == nd {
		return fmt.aprintf("%02d:%02d", hh, mi, allocator = allocator)
	}
	days := (lnow._nsec - local._nsec) / (86_400 * 1_000_000_000)
	if days >= 0 && days < 7 {
		wd := time.weekday(local)
		names := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
		return fmt.aprintf("%s", names[clamp(int(wd), 0, 6)], allocator = allocator)
	}
	if y == ny {
		return fmt.aprintf("%d %s", d, months[clamp(int(mo) - 1, 0, 11)], allocator = allocator)
	}
	return fmt.aprintf("%d/%02d/%02d", y, int(mo), d, allocator = allocator)
}

// full_date is the reader's header line.
full_date :: proc(t: time.Time, offset: i64, allocator := context.allocator) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	y, mo, d := time.date(local)
	hh, mi, _ := time.clock(local)
	months := MONTHS
	wd := time.weekday(local)
	names := [?]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
	return fmt.aprintf(
		"%s %d %s %d at %02d:%02d",
		names[clamp(int(wd), 0, 6)],
		d,
		months[clamp(int(mo) - 1, 0, 11)],
		y,
		hh,
		mi,
		allocator = allocator,
	)
}

// clock_of is the wall-clock time alone, for the places that are saying
// "just now" and only need the minute.
clock_of :: proc(t: time.Time, offset: i64, allocator := context.allocator) -> string {
	local := time.Time{_nsec = t._nsec + offset * 1_000_000_000}
	hh, mi, _ := time.clock(local)
	return fmt.aprintf("%02d:%02d", hh, mi, allocator = allocator)
}

human_bytes :: proc(n: int, allocator := context.allocator) -> string {
	if n < 1000 {
		return fmt.aprintf("%d B", n, allocator = allocator)
	}
	units := [?]string{"KB", "MB", "GB"}
	v := f64(n)
	u := -1
	for v >= 1000 && u < len(units) - 1 {
		v /= 1000
		u += 1
	}
	if v < 10 {
		return fmt.aprintf("%.1f %s", v, units[u], allocator = allocator)
	}
	return fmt.aprintf("%.0f %s", v, units[u], allocator = allocator)
}

// ---------------------------------------------------------------------------
// Actions on the selection
// ---------------------------------------------------------------------------

// mark_thread_read is what opening a conversation does, and what `Shift-U`
// undoes. It goes through set_flags, so an IMAP or JMAP account renames its
// Maildir files and a POP3 account writes its local sidecar instead.
mark_thread :: proc(st: ^State, ti: int, seen: bool) {
	if ti < 0 || ti >= len(st.threads) {
		return
	}
	msgs := st.threads[ti].msgs
	for mi in msgs {
		fl := st.messages[mi].flags
		if seen {
			fl |= {.Seen}
		} else {
			fl &~= {.Seen}
		}
		set_flags(st, mi, fl)
	}
}

toggle_flagged :: proc(st: ^State) {
	ti := current_thread(st)
	if ti < 0 {
		return
	}
	on := !st.threads[ti].flagged
	for mi in st.threads[ti].msgs {
		fl := st.messages[mi].flags
		if on {
			fl |= {.Flagged}
		} else {
			fl &~= {.Flagged}
		}
		set_flags(st, mi, fl)
	}
	note(st, on ? "Flagged" : "Unflagged")
}

mark_read_toggle :: proc(st: ^State) {
	ti := current_thread(st)
	if ti < 0 {
		return
	}
	unread := st.threads[ti].unread > 0
	mark_thread(st, ti, unread)
	note(st, unread ? "Marked read" : "Marked unread")
}

// open_row expands a thread, or opens the message under the cursor. A thread
// of one needs no expanding: opening it is reading it.
open_row :: proc(st: ^State) {
	if st.row_sel < 0 || st.row_sel >= len(st.rows) {
		return
	}
	r := st.rows[st.row_sel]
	if r.kind == .Thread && len(st.threads[r.thread].msgs) > 1 {
		st.threads[r.thread].expanded = !st.threads[r.thread].expanded
		rebuild_rows(st)
		sync_reader(st)
		st.list_scroll_to = st.row_sel
		return
	}
	mi := current_message(st)
	// A draft opens in the composer, not in the reader. Opening your own
	// unfinished message read-only is the one thing nobody wants to do with
	// it, and every mail client agrees.
	if is_draft_message(st, mi) {
		compose_edit_draft(st, mi)
		return
	}
	if mi >= 0 {
		set_flags(st, mi, st.messages[mi].flags | {.Seen})
	}
	st.pane = .Reader
	sync_reader(st)
}

// move_selection walks the flattened rows, marking nothing read — a mail
// client that marks a message read merely because the cursor passed over it is
// a mail client that loses mail.
move_selection :: proc(st: ^State, by: int) {
	if len(st.rows) == 0 {
		return
	}
	st.row_sel = clamp(st.row_sel + by, 0, len(st.rows) - 1)
	st.list_scroll_to = st.row_sel
	sync_reader(st)
}

// ---------------------------------------------------------------------------
// Multi-select
//
// Marks are kept as a set of Maildir paths, not row or message indices, for
// the reason `selection_paths` already gives: creating a folder reloads the
// tree and renumbers every message, so an index taken before a reload names a
// different message after it. A path is what the message *is*.
//
// A thread row stands for every message under it, so marking one marks them
// all and the row only reads as marked when all of them are.
// ---------------------------------------------------------------------------

marked_count :: proc(st: ^State) -> int {
	return len(st.marked)
}

marks_clear :: proc(st: ^State) {
	for k in st.marked {
		delete(k)
	}
	clear(&st.marked)
}

// prune_marks drops marks whose file is no longer in the model — moved out
// from under us by the engine, or deleted. A mark that no longer names
// anything would make "3 selected" a lie.
prune_marks :: proc(st: ^State) {
	if len(st.marked) == 0 {
		return
	}
	live := make(map[string]bool, len(st.messages), context.temp_allocator)
	for m in st.messages {
		live[m.path] = true
	}
	gone := make([dynamic]string, 0, 8, context.temp_allocator)
	for k in st.marked {
		if !live[k] {
			append(&gone, k)
		}
	}
	for k in gone {
		key, _ := delete_key(&st.marked, k)
		delete(key)
	}
}

// row_messages is what one row stands for, without regard to the marks —
// `selection_messages` is the one that consults them.
row_messages :: proc(st: ^State, ri: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, 8, allocator)
	if ri < 0 || ri >= len(st.rows) {
		return out[:]
	}
	r := st.rows[ri]
	if r.kind == .Message {
		append(&out, r.msg)
		return out[:]
	}
	if r.thread < 0 || r.thread >= len(st.threads) {
		return out[:]
	}
	for mi in st.threads[r.thread].msgs {
		append(&out, mi)
	}
	return out[:]
}

row_marked :: proc(st: ^State, ri: int) -> bool {
	msgs := row_messages(st, ri, context.temp_allocator)
	if len(msgs) == 0 {
		return false
	}
	for mi in msgs {
		if !st.marked[st.messages[mi].path] {
			return false
		}
	}
	return true
}

// mark_toggle_row is T. A partly marked thread marks the rest rather than
// unmarking what is there, which is the behaviour that never loses a mark by
// surprise.
mark_toggle_row :: proc(st: ^State) {
	msgs := row_messages(st, st.row_sel, context.temp_allocator)
	if len(msgs) == 0 {
		return
	}
	on := !row_marked(st, st.row_sel)
	for mi in msgs {
		path := st.messages[mi].path
		if on {
			if !st.marked[path] {
				st.marked[strings.clone(path)] = true
			}
		} else {
			if key, found := delete_key(&st.marked, path); found {
				delete(key)
			}
		}
	}
	if n := marked_count(st); n > 0 {
		note(st, tfmt("%d message%s selected  ·  E M D act on all of them, Shift+T clears", n, plural(n)))
	} else {
		note(st, "Selection cleared")
	}
}

// marked_messages is the marked set in scan order, which is the order every
// other loop over messages here uses.
marked_messages :: proc(st: ^State, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, max(1, len(st.marked)), allocator)
	if len(st.marked) == 0 {
		return out[:]
	}
	for m, i in st.messages {
		if st.marked[m.path] {
			append(&out, i)
		}
	}
	return out[:]
}
