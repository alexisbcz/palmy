package main

// Open and Save As, through the shared file dialog in `kit`.
//
// Before this the only way to name a file was to type its whole path into the
// prompt bar, which meant knowing it by heart. The command line argument still
// works exactly as it did — the dialog is an addition, not a replacement.

import "core:strings"
import kit "kit:."
import p "palmy:."

// What the dialog was opened for, since one `kit.Pick` serves both commands.
Pick_Use :: enum {
	None,
	Open,
	Save_As,
}

// The filters an editor cares about. "All files" comes first because a text
// editor is routinely pointed at a file with no extension at all — a Makefile,
// a config, a script.
EDITOR_FILTERS := [?]kit.Pick_Filter {
	kit.PICK_ALL,
	kit.PICK_TEXT,
	{"Code", {"odin", "c", "h", "cpp", "hpp", "rs", "go", "py", "js", "ts", "sh", "lua", "zig"}},
	{"Data", {"json", "yaml", "yml", "toml", "xml", "ini", "conf", "csv"}},
}

begin_pick :: proc(ed: ^Editor, use: Pick_Use) {
	ed.pick_use = use
	// Open where the current file lives, so "open the one next to this one" —
	// which is most of the time — is already where you are.
	dir := ed.buf.path == "" ? "" : kit.pick_parent(ed.buf.path)

	switch use {
	case .None:
	case .Open:
		if buf_dirty(&ed.buf) {
			// Refuse here rather than after the dialog has been used: being
			// told "no" once you have already chosen the file is worse than
			// not being offered the choice.
			ed.pick_use = .None
			note(ed, "Save this file first — Ctrl S")
			return
		}
		kit.pick_begin(&ed.pick, .Open_File, {dir = dir, filters = EDITOR_FILTERS[:]})
	case .Save_As:
		name := ed.buf.path == "" ? "untitled.txt" : base_of(ed.buf.path)
		kit.pick_begin(
			&ed.pick,
			.Save_File,
			{dir = dir, name = name, filters = EDITOR_FILTERS[:], confirm = "Save"},
		)
	}
}

// pick_overlay runs the dialog. It is drawn last, inside the editor's own
// `relative` root, because there is no xdg_popup here and a modal has to live
// in the window it belongs to.
pick_overlay :: proc(ui: ^p.Ctx, ed: ^Editor) {
	if !kit.pick_active(&ed.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &ed.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := ed.pick_use
	ed.pick_use = .None
	if !res.ok {
		return
	}

	switch use {
	case .None:
	case .Open:
		if buf_dirty(&ed.buf) {
			// Edited while the dialog was up, which the keyboard guard makes
			// unlikely but not impossible. Opening replaces the buffer and
			// this editor has no second tab to put the old one in, so losing
			// unsaved work to a file dialog is not a trade worth making.
			note(ed, "Save this file first — Ctrl S")
			return
		}
		path := strings.clone(res.path, context.temp_allocator)
		if !buf_load(&ed.buf, path) {
			note(ed, tfmt("Could not read %s", base_of(path)))
			return
		}
		ed.cur, ed.anchor = Pos{0, 0}, Pos{0, 0}
		ed.has_sel = false
		ed.top, ed.left = 0, 0
		ed.odin = strings.has_suffix(ed.buf.path, ".odin")
		note(ed, tfmt("Opened %s", base_of(ed.buf.path)))
	case .Save_As:
		// The dialog has already asked about an overwrite, and `res.overwrite`
		// says the answer was yes. There is nothing left to confirm here.
		do_save(ed, strings.clone(res.path, context.temp_allocator))
	}
}
