package main

// Open, through the shared file dialog in `kit`.
//
// The viewer has always taken its subject from argv — `image photo.jpg` or
// `image ~/Pictures` — and that still works unchanged. What it had no way of
// doing was opening something else once it was already running: the library
// screen lists the folders it knows about, and anything outside them was
// unreachable without quitting and starting again.
//
//   Ctrl O        open an image file
//   Ctrl Shift O  open a folder, which lands in the grid

import "core:fmt"
import kit "kit:."
import p "palmy:."

Pick_Use :: enum {
	None,
	File,
	Folder,
}

// The viewer decodes through stb_image, so the filter offers exactly what it
// can actually open; "All files" is still there for a file with no extension
// or an unusual one.
IMAGE_FILTERS := [?]kit.Pick_Filter {
	{"Images", {"png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "ppm", "pgm", "pnm", "hdr"}},
	kit.PICK_ALL,
}

begin_pick :: proc(st: ^St, use: Pick_Use) {
	st.pick_use = use
	// Start where we are: the folder on screen, or whatever was opened last.
	dir := st.dir
	switch use {
	case .None:
	case .File:
		kit.pick_begin(&st.pick, .Open_File, {dir = dir, filters = IMAGE_FILTERS[:]})
	case .Folder:
		kit.pick_begin(
			&st.pick,
			.Open_Folder,
			{title = "Open Folder", dir = dir, confirm = "Open"},
		)
	}
}

// pick_overlay is drawn after whichever of the three screens is showing. All
// three add their content straight to palmy's root element, so the dialog is
// a sibling at the top level and its absolute insets resolve against the
// window.
pick_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	if !kit.pick_active(&st.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &st.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := st.pick_use
	st.pick_use = .None
	if !res.ok {
		return
	}

	switch use {
	case .None:
	case .File:
		open_folder(st, dir_of(res.path), res.path)
		if st.sel < 0 || len(st.shots) == 0 {
			// Chosen through an "All files" filter, and not something stb can
			// decode. Say so rather than showing an empty viewer.
			toast(st, ui, fmt.tprintf("%s is not an image palmy can decode", base_of(res.path)))
			build_library(st)
			st.view = .Library
			return
		}
		st.view = .Viewer
		st.fit = true
		st.rot = 0
		st.pan = {}
	case .Folder:
		open_folder(st, res.path, "")
		if len(st.shots) == 0 {
			toast(st, ui, fmt.tprintf("No images in %s", base_of(res.path)))
		}
		st.view = .Grid
		st.grid_top = 0
	}
}
