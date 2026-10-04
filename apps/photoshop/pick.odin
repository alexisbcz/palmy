package main

// Open and Save As, through the shared file dialog in `kit`.
//
// This app grew its own: `Overlay.Open` lists exactly one directory with no
// sidebar, no filter and no sorting, and `Overlay.Save_As` is a line you type
// a whole path into. Both still exist — `--shot open` and `--shot save` render
// them, and nothing else in the app has changed — but every way a person
// reaches a file now goes through the shared dialog instead.
//
//   Ctrl O        open an image
//   Ctrl S        save, asking for a name the first time
//   Ctrl Shift S  save as
//
// The Save filter is PNG and only PNG, which is not a limitation imported from
// the dialog: `save_to` refuses anything else, because the only encoder here
// is PNG and writing PNG bytes into a file called `.jpg` would be a lie. With
// the filter set this way the dialog appends `.png` itself and that refusal
// can no longer be reached by accident.

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."

File_Pick :: enum {
	None,
	Open,
	Save_As,
}

PS_OPEN_FILTERS := [?]kit.Pick_Filter {
	// Exactly what stb_image decodes, which is what `p.load_image` uses.
	{"Images", {"png", "jpg", "jpeg", "bmp", "gif", "tga", "psd", "ppm", "pgm", "pnm", "hdr"}},
	kit.PICK_ALL,
}

PS_SAVE_FILTERS := [?]kit.Pick_Filter{{"PNG image", {"png"}}}

begin_pick :: proc(st: ^St, use: File_Pick) {
	st.fpick_use = use
	// Start where the document came from, else the directory the app was
	// started in — the same rule the old overlay used.
	dir := st.doc.path != "" ? dir_of(st.doc.path) : (st.files_dir == "" ? cwd() : st.files_dir)

	switch use {
	case .None:
	case .Open:
		kit.pick_begin(&st.fpick, .Open_File, {dir = dir, filters = PS_OPEN_FILTERS[:]})
	case .Save_As:
		name := st.doc.path != "" ? base_of(st.doc.path) : "untitled.png"
		kit.pick_begin(
			&st.fpick,
			.Save_File,
			{dir = dir, name = name, filters = PS_SAVE_FILTERS[:], confirm = "Save"},
		)
	}
}

// save_or_ask is Ctrl S: write straight back over a document that has a name,
// and otherwise ask for one.
save_or_ask :: proc(st: ^St) {
	if st.doc.path == "" {
		begin_pick(st, .Save_As)
		return
	}
	save_to(st, st.doc.path)
}

pick_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	if !kit.pick_active(&st.fpick) {
		return
	}
	res, done := kit.pick_draw(ui, &st.fpick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := st.fpick_use
	st.fpick_use = .None
	if !res.ok {
		return
	}

	path := strings.clone(res.path, context.temp_allocator)
	switch use {
	case .None:
	case .Open:
		if open_file(st, path) {
			toast(st, fmt.tprintf("opened %s", base_of(path)))
		} else {
			toast(st, fmt.tprintf("could not decode %s", base_of(path)))
		}
	case .Save_As:
		// The dialog has already asked about replacing an existing file, so
		// `save_to` writes without a second question.
		save_to(st, path)
	}
}
