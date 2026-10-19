// What a note is inside the CRDT (cloud/collab/crdt).
//
//	sequence "body"            the Markdown, one element per UTF-8 byte
//	register note/notebook     the folder it is filed in ("" for the inbox)
//	register note/tags         front matter tags, comma separated
//	register note/pinned       "1" or unset
//	register note/trashed      when it went to the trash (ISO 8601), or unset
//
// The text merges character by character (FugueMax: two people typing at the
// same spot never interleave), and each register is last-writer-wins by
// Lamport clock, so a note moved to Travel on the laptop and pinned on the
// phone ends up both moved and pinned. Two different notebooks for the same
// note is the one real conflict, and the later move wins on every device.
//
// The title is not a register: it is the body's first line, so renaming is
// editing, and it merges like editing.
package main

import "core:strings"
import crdt "../../cloud/collab/crdt"

BODY_KEY :: "body"
NOTE_REG :: "note"

Doc_Meta :: struct {
	notebook: string,
	tags:     string, // comma separated, normalised
	pinned:   bool,
	trashed:  string, // "" when not in the trash
}

doc_body :: proc(d: ^crdt.Doc, allocator := context.temp_allocator) -> string {
	return crdt.read_text(d, BODY_KEY, allocator)
}

doc_meta :: proc(d: ^crdt.Doc) -> Doc_Meta {
	return Doc_Meta {
		notebook = crdt.reg_str(d, NOTE_REG, "notebook"),
		tags = crdt.reg_str(d, NOTE_REG, "tags"),
		pinned = crdt.reg_str(d, NOTE_REG, "pinned") == "1",
		trashed = crdt.reg_str(d, NOTE_REG, "trashed"),
	}
}

// doc_set_body turns the current text into `text` with the fewest element
// operations diff.odin can find. Returns whether anything changed.
doc_set_body :: proc(d: ^crdt.Doc, text: string) -> bool {
	cur := doc_body(d)
	if cur == text {
		return false
	}
	hunks := diff_text(cur, text)
	// From the end backwards, so every hunk's offset is still the old text's.
	#reverse for h in hunks {
		if h.remove > 0 {
			crdt.remove(d, BODY_KEY, u64(h.at), u64(h.remove))
		}
		if len(h.insert) > 0 {
			crdt.insert_text(d, BODY_KEY, u64(h.at), h.insert)
		}
	}
	return len(hunks) > 0
}

doc_set_meta :: proc(d: ^crdt.Doc, m: Doc_Meta) -> bool {
	before := doc_meta(d)
	reg :: proc(d: ^crdt.Doc, field, want, have: string) {
		if want == have {
			return
		}
		if want == "" {
			crdt.unset(d, NOTE_REG, field)
		} else {
			crdt.set_str(d, NOTE_REG, field, want)
		}
	}
	reg(d, "notebook", m.notebook, before.notebook)
	reg(d, "tags", m.tags, before.tags)
	reg(d, "pinned", m.pinned ? "1" : "", before.pinned ? "1" : "")
	reg(d, "trashed", m.trashed, before.trashed)
	return before.notebook != m.notebook || before.tags != m.tags || before.pinned != m.pinned || before.trashed != m.trashed
}

tags_join :: proc(tags: []string, allocator := context.temp_allocator) -> string {
	return strings.join(tags, ",", allocator)
}

tags_split :: proc(s: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	if s == "" {
		return out
	}
	for t in strings.split(s, ",", context.temp_allocator) {
		add_tag(&out, t, allocator)
	}
	return out
}
