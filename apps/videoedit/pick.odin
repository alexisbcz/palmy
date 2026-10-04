package main

// The four paths this editor needs, through the shared file dialog in `kit`.
//
// Every one of them used to be a text field you typed a whole path into, and
// media could only be imported by naming it on the command line. The fields
// are still there and still work — the dialog fills them in rather than
// replacing them, so a path typed by hand, a path from argv and a path chosen
// in the dialog all arrive at the same place.
//
//   Ctrl I        import media files (several at once)
//   Ctrl E        choose where the export is written
//   Ctrl Shift C  choose a subtitle file to load
//   Ctrl Shift P  choose a project file

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."

Pick_Use :: enum {
	None,
	Import,
	Export,
	Caption,
	Project,
}

VE_MEDIA_FILTERS := [?]kit.Pick_Filter {
	{
		"Media",
		{
			"mp4", "mkv", "webm", "mov", "avi", "m4v", "mpg", "mpeg",
			"mp3", "flac", "wav", "ogg", "opus", "m4a", "aac",
			"png", "jpg", "jpeg", "gif", "bmp",
		},
	},
	kit.PICK_VIDEO,
	kit.PICK_AUDIO,
	kit.PICK_ALL,
}

VE_EXPORT_FILTERS := [?]kit.Pick_Filter{{"MP4 video", {"mp4"}}, kit.PICK_ALL}
VE_CAPTION_FILTERS := [?]kit.Pick_Filter{kit.PICK_SUBTITLES, kit.PICK_ALL}
VE_PROJECT_FILTERS := [?]kit.Pick_Filter{{"Project", {"json"}}, kit.PICK_ALL}

begin_pick :: proc(ed: ^Editor, use: Pick_Use) {
	ed.pick_use = use
	switch use {
	case .None:
	case .Import:
		// Several at once: an edit almost never starts with one clip.
		kit.pick_begin(
			&ed.pick,
			.Open_Files,
			{
				title = "Import Media",
				dir = pick_dir_of(buf_str(&ed.buf_export)),
				filters = VE_MEDIA_FILTERS[:],
				confirm = "Import",
			},
		)
	case .Export:
		cur := buf_str(&ed.buf_export)
		kit.pick_begin(
			&ed.pick,
			.Save_File,
			{
				title = "Export To",
				dir = pick_dir_of(cur),
				name = cur == "" ? "export.mp4" : kit.pick_base(cur),
				filters = VE_EXPORT_FILTERS[:],
				confirm = "Choose",
			},
		)
	case .Caption:
		kit.pick_begin(
			&ed.pick,
			.Open_File,
			{
				title = "Load Captions",
				dir = pick_dir_of(buf_str(&ed.buf_caption)),
				filters = VE_CAPTION_FILTERS[:],
				confirm = "Load",
			},
		)
	case .Project:
		cur := buf_str(&ed.buf_project)
		kit.pick_begin(
			&ed.pick,
			.Save_File,
			{
				title = "Project File",
				dir = pick_dir_of(cur),
				name = cur == "" ? "project.json" : kit.pick_base(cur),
				filters = VE_PROJECT_FILTERS[:],
				confirm = "Choose",
			},
		)
	}
}

// pick_dir_of is the folder a path lives in, or "" when there is no path and
// the dialog should decide for itself.
pick_dir_of :: proc(path: string) -> string {
	if path == "" {
		return ""
	}
	return kit.pick_parent(path)
}

// pick_overlay runs the dialog, last, inside `draw_ui`'s `relative` root.
pick_overlay :: proc(ed: ^Editor, ui: ^p.Ctx) {
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
	case .Import:
		for path in res.paths {
			importer_push(&ed.im, path)
		}
		status(
			ed,
			ui,
			len(res.paths) == 1 \
			? fmt.tprintf("importing %s", base_name(res.path)) \
			: fmt.tprintf("importing %d files", len(res.paths)),
		)
	case .Export:
		set_str(&ed.buf_export, strings.clone(res.path, context.temp_allocator))
		status(ed, ui, fmt.tprintf("export target is %s", base_name(res.path)))
	case .Caption:
		set_str(&ed.buf_caption, strings.clone(res.path, context.temp_allocator))
		// Choosing a subtitle file means loading it; nobody picks one to look
		// at the path.
		load_caption_file(ed, ui)
	case .Project:
		set_str(&ed.buf_project, strings.clone(res.path, context.temp_allocator))
		status(ed, ui, fmt.tprintf("project file is %s", base_name(res.path)))
	}
}
