package main

// Attachments, from "a part exists" to "these bytes are on disk".
//
// The MIME parser already decodes every entity: `Part.content` is the
// transfer-decoded octets and `Message.attachments` records one entry per
// non-body entity. What was missing was the step after that — a way to ask for
// a part's bytes by its section number, a way to enumerate the attachments a
// UI could actually offer to save, and a writer that cannot be talked into
// writing somewhere else by a hostile filename.
//
// THE THREAT MODEL, because this is the file where it matters
//
// A filename in a message is attacker-controlled. `sanitise_filename` already
// strips every directory component, so "../../.bashrc" arrives here as
// ".bashrc". That is necessary and it is not sufficient: a caller could still
// join a sanitised name onto the wrong directory, or be handed a path by a
// file dialog that the user had navigated elsewhere. So `attachment_write`
// takes the directory and the name separately, sanitises the name a second
// time, and then refuses outright unless the resulting path is a plain file
// sitting *directly* inside that directory — `path_within` is the check, and
// it rejects "..", nested paths, symlink-ish tricks spelled with slashes, and
// the directory itself.
//
// Nothing here opens a socket. Nothing here resolves a name.

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Bytes by section number
// ---------------------------------------------------------------------------

// part_bytes hands back one entity's transfer-decoded octets, addressed the
// way IMAP addresses them: "" is the root, "2" is the second part of a
// multipart, "2.1" the first part inside that one.
//
// A multipart container has no bytes of its own — its body is its children
// plus delimiters — so asking for one is a miss rather than a lie.
part_bytes :: proc(m: ^Message, section: string) -> (data: []u8, ok: bool) {
	pt := find_part(&m.root, section)
	if pt == nil {
		return nil, false
	}
	if pt.is_multipart {
		return nil, false
	}
	return pt.content, true
}

// part_decoded_size is the length `part_bytes` would return, without the
// caller having to care whether the part exists.
part_decoded_size :: proc(m: ^Message, section: string) -> int {
	data, ok := part_bytes(m, section)
	if !ok {
		return 0
	}
	return len(data)
}

// ---------------------------------------------------------------------------
// Enumerating what can be saved
// ---------------------------------------------------------------------------

// Saveable is one attachment with everything a writer needs and nothing it
// does not: a name that is already safe on disk, the content type, the decoded
// length, the decoded bytes, and the section they came from so a UI can ask
// again later.
Saveable :: struct {
	section:   string,
	filename:  string, // sanitised; never empty
	mime_type: string,
	size:      int,
	content:   []u8,
}

// attachment_inline reports whether an attachment is an inline part the
// message itself points at — an image a `cid:` URL in the HTML body refers to.
// Those belong to the rendering of the message, not to the list of files the
// reader is offered.
//
// A part marked `Content-Disposition: inline` that *nothing* references is
// still an attachment: senders mark PDFs inline all the time, and hiding one
// would lose it.
attachment_inline :: proc(m: ^Message, a: Attachment) -> bool {
	if a.content_id == "" {
		return false
	}
	if !a.is_inline {
		return false
	}
	return cid_referenced(m, a.content_id)
}

// cid_referenced looks for `cid:ID` in the display bodies. The angle brackets
// are already stripped from `content_id`, and a `cid:` URL never carries them.
cid_referenced :: proc(m: ^Message, content_id: string) -> bool {
	if content_id == "" {
		return false
	}
	needle := strings.concatenate({"cid:", content_id}, context.temp_allocator)
	return strings.contains(m.text_html, needle) || strings.contains(m.text_plain, needle)
}

// attachment_save_name is the name to write a part under: its own filename
// when it has a usable one, and otherwise one built from its section number
// and its content type, because "" is not a filename and "attachment" twice in
// one directory is worse than "part-2.png".
attachment_save_name :: proc(a: Attachment, allocator := context.allocator) -> string {
	// Sanitised at parse time already; done again because this is the
	// procedure whose output becomes a path.
	n := sanitise_filename(a.filename, context.temp_allocator)
	if n != "" {
		return strings.clone(n, allocator)
	}
	label := a.section == "" ? "part" : fmt.tprintf("part-%s", a.section)
	return fmt.aprintf("%s%s", label, mime_extension(a.mime_type), allocator = allocator)
}

// mime_extension is a short, deliberately incomplete table: the types a mail
// client actually meets. Anything else gets ".bin", which is honest.
mime_extension :: proc(mime: string) -> string {
	switch strings.to_lower(strings.trim_space(mime), context.temp_allocator) {
	case "text/plain":
		return ".txt"
	case "text/html":
		return ".html"
	case "text/csv":
		return ".csv"
	case "text/calendar":
		return ".ics"
	case "image/png":
		return ".png"
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/svg+xml":
		return ".svg"
	case "application/pdf":
		return ".pdf"
	case "application/zip":
		return ".zip"
	case "application/gzip":
		return ".gz"
	case "application/json":
		return ".json"
	case "message/rfc822":
		return ".eml"
	}
	return ".bin"
}

// message_saveable lists the attachments worth offering to save, in the order
// they appear in the message, each one already carrying its bytes.
message_saveable :: proc(m: ^Message, allocator := context.allocator) -> []Saveable {
	out := make([dynamic]Saveable, 0, len(m.attachments), allocator)
	for a in m.attachments {
		if attachment_inline(m, a) {
			continue
		}
		data, ok := part_bytes(m, a.section)
		if !ok {
			// message/rfc822 keeps its parent's section number, so the lookup
			// can land on the container; the attachment already holds the
			// decoded bytes in that case.
			data = a.content
		}
		append(
			&out,
			Saveable {
				section = a.section,
				filename = attachment_save_name(a, allocator),
				mime_type = a.mime_type,
				size = len(data),
				content = data,
			},
		)
	}
	return out[:]
}

// message_inline_parts is the complement: the parts the message renders
// itself, which a UI should mention but not offer as files.
message_inline_parts :: proc(m: ^Message, allocator := context.allocator) -> []Attachment {
	out := make([dynamic]Attachment, 0, 4, allocator)
	for a in m.attachments {
		if attachment_inline(m, a) {
			append(&out, a)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Writing one out
// ---------------------------------------------------------------------------

// path_within is the containment check. `path` must name a plain file sitting
// directly inside `dir`: no traversal, no nesting, and not `dir` itself.
//
// It compares strings rather than resolving the filesystem on purpose — it is
// called on a path this program is about to *construct*, before anything
// exists, and its job is to prove the construction was sound.
path_within :: proc(dir, path: string) -> bool {
	d := strings.trim_right(dir, "/")
	if d == "" {
		d = "/"
	}
	prefix := d == "/" ? "/" : strings.concatenate({d, "/"}, context.temp_allocator)
	if !strings.has_prefix(path, prefix) {
		return false
	}
	rest := path[len(prefix):]
	if rest == "" || rest == "." || rest == ".." {
		return false
	}
	// One component, and a real one.
	if strings.contains(rest, "/") {
		return false
	}
	return true
}

// attachment_dest resolves where a part may be written: `dir`, plus `name`
// sanitised into a single safe component. It is the one place a path is built,
// so it is the one place that has to be right.
attachment_dest :: proc(dir, name: string, allocator := context.allocator) -> (path: string, err: string) {
	safe := sanitise_filename(name, context.temp_allocator)
	if safe == "" {
		return "", fmt.aprintf("%q is not a usable file name", name, allocator = allocator)
	}
	d := strings.trim_right(dir, "/")
	if d == "" {
		d = "/"
	}
	p := d == "/" \
		? strings.concatenate({"/", safe}, allocator) \
		: strings.concatenate({d, "/", safe}, allocator)
	if !path_within(dir, p) {
		return "", fmt.aprintf("refusing to write %q outside %s", name, dir, allocator = allocator)
	}
	return p, ""
}

// attachment_write writes a part's decoded bytes into `dir`.
//
// `overwrite` must be an explicit yes from whoever asked; without it an
// existing file is left alone and the caller is told why.
attachment_write :: proc(
	dir: string,
	s: Saveable,
	overwrite := false,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	p, derr := attachment_dest(dir, s.filename, allocator)
	if derr != "" {
		return "", derr
	}
	if !os.is_dir(dir) {
		return "", fmt.aprintf("%s is not a directory", dir, allocator = allocator)
	}
	if os.exists(p) && !overwrite {
		return "", fmt.aprintf("%s already exists", p, allocator = allocator)
	}
	f, oe := os.open(p, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, PERM_FILE)
	if oe != nil {
		return "", fmt.aprintf("open %s: %v", p, oe, allocator = allocator)
	}
	off := 0
	for off < len(s.content) {
		n, we := os.write(f, s.content[off:])
		if we != nil || n <= 0 {
			os.close(f)
			return "", fmt.aprintf("write %s: %v", p, we, allocator = allocator)
		}
		off += n
	}
	os.close(f)
	return p, ""
}
