// Attachments you can actually open: pick one, and write its decoded bytes to
// a file the user chose.
//
// The reader has always listed what a message carries — name, type, decoded
// size — and been unable to do anything with it, because the MIME walk threw
// the bytes away as soon as it had counted them. It still does, deliberately:
// a mailbox of a few hundred messages with attachments is tens of megabytes
// that nothing on screen needs. What changed is that each attachment now
// remembers its *section number*, so `part_bytes` can go back to the file on
// disk and decode exactly that part on demand.
//
// TWO LOCKS ON A HOSTILE FILENAME
//
// A filename in a message is attacker-controlled: "../../.bashrc" is a name a
// sender can choose. The first lock is `sanitise_filename`, applied when the
// attachment is recorded and applied again on the way out, which strips every
// directory component. The second is `path_within`: the path this app is about
// to write must name a plain file sitting directly inside the directory the
// dialog came back with. Either one alone would probably do. Both is what this
// deserves, because the cost of being wrong is overwriting a file in somebody's
// home directory.
//
// The overwrite question is the file dialog's, not ours: `kit` already refuses
// to replace an existing file without a confirmation that starts on Cancel.
package main

import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

// Saver is the Save-As flow: the shared dialog, and which attachment it is
// for. It lives in its own struct so `model.odin` — which must stay free of
// anything that could reach the outside world — does not have to import the
// kit at all.
Saver :: struct {
	pick:   kit.Pick,
	active: bool,
	msg:    int, // index into State.messages
	att:    int, // index into that message's attachments
	last:   string, // the path of the last successful save, for the status line
}

ATTACH_FILTERS := [?]kit.Pick_Filter{kit.PICK_ALL}

// ---------------------------------------------------------------------------
// Which attachments are offered
// ---------------------------------------------------------------------------

// saveable_attachments lists the indices of the parts worth offering as files.
//
// An inline image the message's own HTML points at with a `cid:` URL is part
// of how the message reads, not a file somebody wants on their desktop, so it
// is counted and named separately. A part marked `Content-Disposition: inline`
// that *nothing* references is still an attachment: senders mark PDFs inline
// all the time and hiding one would lose it.
saveable_attachments :: proc(m: Message, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(m.attachments), allocator)
	for at, i in m.attachments {
		if at.is_inline {
			continue
		}
		append(&out, i)
	}
	return out[:]
}

inline_attachment_count :: proc(m: Message) -> (n: int) {
	for at in m.attachments {
		if at.is_inline {
			n += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// The bytes
// ---------------------------------------------------------------------------

// attachment_bytes re-reads the message off disk and decodes one part.
//
// Re-reading rather than caching is the point: nothing in the reader needs
// these bytes, and a mailbox's worth of them in memory would be the single
// largest thing this process holds. A Maildir file is a few kilobytes and the
// decode is a linear scan, so the cost of asking is not measurable next to the
// file dialog the user is about to see.
attachment_bytes :: proc(
	m: Message,
	at: Attachment,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	raw, rok := read_file(m.path, context.temp_allocator)
	if !rok {
		return nil, false
	}
	return part_bytes(string(raw), at.section, allocator)
}

// ---------------------------------------------------------------------------
// Writing one out
// ---------------------------------------------------------------------------

// attachment_dest resolves where an attachment may be written: `dir`, plus
// `name` reduced to a single safe component. It is the one place in this app
// where an attachment's path is built, which is why both locks are here.
attachment_dest :: proc(dir, name: string, allocator := context.allocator) -> (path: string, err: string) {
	safe := sanitise_filename(name, context.temp_allocator)
	if safe == "" {
		return "", tfmt("%q is not a usable file name", name)
	}
	d := strings.trim_right(dir, "/")
	if d == "" {
		d = "/"
	}
	p_ := d == "/" \
		? strings.concatenate({"/", safe}, allocator) \
		: strings.concatenate({d, "/", safe}, allocator)
	if !path_within(dir, p_) {
		return "", tfmt("refusing to write %q outside %s", name, dir)
	}
	return p_, ""
}

// save_attachment_to writes an attachment's decoded bytes into `dir` under
// `name`, byte for byte as the sender encoded them.
//
// `dir` is the directory the dialog came back with and nothing else: the path
// is rebuilt from it rather than trusted, so no name — however hostile, and
// whether it came from the message or was typed into the dialog — can land a
// file anywhere else.
save_attachment_to :: proc(
	m: Message,
	at: Attachment,
	dir, name: string,
) -> (
	path: string,
	err: string,
) {
	dest, derr := attachment_dest(dir, name)
	if derr != "" {
		return "", derr
	}
	if !os.is_dir(dir) {
		return "", tfmt("%s is not a directory", dir)
	}
	data, ok := attachment_bytes(m, at, context.temp_allocator)
	if !ok {
		return "", tfmt("%s could not be decoded out of the message", at.name)
	}
	if !write_file(dest, data) {
		return "", tfmt("could not write %s", dest)
	}
	return dest, ""
}

// save_attachment_at is the same thing addressed the way the UI addresses it,
// and the way the dialog hands a path back: one path, which is split into the
// directory the user chose and the name they left in the field.
save_attachment_at :: proc(st: ^State, mi, ai: int, chosen: string) -> (path: string, err: string) {
	if mi < 0 || mi >= len(st.messages) {
		return "", "no message"
	}
	m := st.messages[mi]
	if ai < 0 || ai >= len(m.attachments) {
		return "", "no attachment"
	}
	dir := kit.pick_parent(chosen)
	name := kit.pick_base(chosen)
	return save_attachment_to(m, m.attachments[ai], dir, name)
}

// ---------------------------------------------------------------------------
// Selecting one in the reader
// ---------------------------------------------------------------------------

// attachment_cycle moves the keyboard's attachment cursor. With nothing
// selected it lands on the first; past the end it wraps, because a list of
// three chips is not somewhere a cursor should get stuck.
attachment_cycle :: proc(st: ^State, by: int) {
	mi := st.reader_msg
	if mi < 0 || mi >= len(st.messages) {
		st.att_sel = -1
		return
	}
	saveable := saveable_attachments(st.messages[mi])
	if len(saveable) == 0 {
		st.att_sel = -1
		note(st, "This message has no attachments to save")
		return
	}
	// `att_sel` is an index into the saveable list, not into `attachments`.
	if st.att_sel < 0 {
		st.att_sel = by >= 0 ? 0 : len(saveable) - 1
	} else {
		st.att_sel = (st.att_sel + by + len(saveable)) % len(saveable)
	}
	at := st.messages[mi].attachments[saveable[st.att_sel]]
	note(st, tfmt("%s  ·  %s  ·  %s  —  W to save", at.name, at.mime, human_bytes(at.size, context.temp_allocator)))
}

// selected_attachment resolves `att_sel` into a real attachment index.
selected_attachment :: proc(st: ^State) -> (mi: int, ai: int, ok: bool) {
	mi = st.reader_msg
	if mi < 0 || mi >= len(st.messages) {
		return -1, -1, false
	}
	saveable := saveable_attachments(st.messages[mi])
	if len(saveable) == 0 {
		return mi, -1, false
	}
	k := st.att_sel
	if k < 0 || k >= len(saveable) {
		// Nothing chosen yet, and exactly one candidate: that is the one.
		if len(saveable) == 1 {
			return mi, saveable[0], true
		}
		return mi, -1, false
	}
	return mi, saveable[k], true
}

// ---------------------------------------------------------------------------
// The dialog
// ---------------------------------------------------------------------------

// begin_save_attachment opens the shared Save dialog with the attachment's own
// name pre-filled — sanitised first, so the dialog is never handed a path
// masquerading as a name.
begin_save_attachment :: proc(st: ^State) {
	mi, ai, ok := selected_attachment(st)
	if !ok {
		if mi >= 0 && len(st.messages[mi].attachments) > 0 {
			note(st, "Press V to choose an attachment, then W to save it")
		} else {
			note(st, "This message has no attachments")
		}
		return
	}
	at := st.messages[mi].attachments[ai]
	st.saver.active = true
	st.saver.msg = mi
	st.saver.att = ai
	kit.pick_begin(
		&st.saver.pick,
		.Save_File,
		{
			title = "Save Attachment",
			dir = st.save_dir,
			name = sanitise_filename(at.name, context.temp_allocator),
			filters = ATTACH_FILTERS[:],
			confirm = "Save",
		},
	)
}

// save_overlay draws the dialog and collects its answer. It owns the keyboard
// while it is up, which is why `handle_keys` returns early for it.
save_overlay :: proc(ui: ^p.Ctx, st: ^State) {
	if !kit.pick_active(&st.saver.pick) && !st.saver.active {
		return
	}
	res, done := kit.pick_draw(ui, &st.saver.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	st.saver.active = false
	if !res.ok {
		return
	}
	path, err := save_attachment_at(st, st.saver.msg, st.saver.att, res.path)
	if err != "" {
		note(st, err)
		return
	}
	// Open the next save in the same place, which is what every app does.
	delete(st.save_dir)
	st.save_dir = strings.clone(kit.pick_parent(path))
	delete(st.saver.last)
	st.saver.last = strings.clone(path)
	note(st, tfmt("Saved %s", kit.pick_abbreviate(path, "", context.temp_allocator)))
}
