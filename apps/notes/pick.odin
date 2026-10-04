package main

// Import and Export, through the shared file dialog in `kit`.
//
// A note is a Markdown file in one fixed directory, so there is no "open a
// path" in the editor sense — but there are two things a notebook over real
// files owes you, and neither was reachable before: bringing a Markdown file
// in from somewhere else, and taking one back out.
//
//   Ctrl O        import a file as a new note
//   Ctrl Shift S  export the open note somewhere
//
// Ctrl S still means "write now" — notes autosaves, and that has not changed.

import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

Pick_Use :: enum {
	None,
	Import,
	Export,
}

NOTES_FILTERS := [?]kit.Pick_Filter {
	{"Markdown and text", {"md", "markdown", "txt", "text", "org", "rst"}},
	kit.PICK_ALL,
}

begin_pick :: proc(nt: ^Notes, use: Pick_Use) {
	nt.pick_use = use
	switch use {
	case .None:
	case .Import:
		kit.pick_begin(
			&nt.pick,
			.Open_File,
			{title = "Import a Note", filters = NOTES_FILTERS[:], confirm = "Import"},
		)
	case .Export:
		n, ok := selected(nt)
		if !ok {
			note(nt, "No note to export")
			nt.pick_use = .None
			return
		}
		// Offer the note's own title as the file name, which is what its file
		// on disk is already called.
		kit.pick_begin(
			&nt.pick,
			.Save_File,
			{
				title = "Export Note",
				name = tfmt("%s.md", slug(n.title)),
				filters = NOTES_FILTERS[:],
				confirm = "Export",
			},
		)
	}
}

// note_text is the open buffer as one string, which is what both the autosave
// and the export write.
note_text :: proc(nt: ^Notes, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< buf_lines(&nt.buf) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buf_line(&nt.buf, i))
	}
	return strings.to_string(sb)
}

pick_overlay :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !kit.pick_active(&nt.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &nt.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := nt.pick_use
	nt.pick_use = .None
	if !res.ok {
		return
	}

	switch use {
	case .None:
	case .Import:
		data, rerr := os.read_entire_file(res.path, context.temp_allocator)
		if rerr != nil {
			note(nt, tfmt("Could not read %s", kit.pick_base(res.path)))
			return
		}
		// A note is named after its own first line, so importing is simply
		// writing the text into the store and letting it name itself.
		new_path, ok := store_write(nt.dir, "", string(data))
		if !ok {
			note(nt, "Could not write the note")
			return
		}
		flush(nt)
		reload(nt)
		select_path(nt, new_path)
		delete(new_path)
		note(nt, tfmt("Imported %s", kit.pick_base(res.path)))

	case .Export:
		body := note_text(nt, context.temp_allocator)
		// The dialog has already asked about replacing an existing file.
		if werr := os.write_entire_file(res.path, transmute([]u8)body); werr != nil {
			note(nt, tfmt("Could not write %s", kit.pick_base(res.path)))
			return
		}
		note(nt, tfmt("Exported to %s", kit.pick_abbreviate(res.path)))
	}
}

// select_path puts the cursor on the note with this path and opens it.
select_path :: proc(nt: ^Notes, path: string) -> bool {
	for v, i in nt.vis {
		if nt.all[v].path == path {
			nt.sel = i
			open_sel(nt)
			return true
		}
	}
	return false
}
