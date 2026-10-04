package main

// Choosing the media file, and choosing where the subtitles are written,
// through the shared file dialog in `kit`.
//
// Both paths were text fields you typed into. They still are — the dialog
// fills them in, so a path on the command line, a path typed by hand and a
// path chosen here all arrive at `open_path` and `export_now` the same way.
//
//   Ctrl O        choose the media (or a subtitle file to edit)
//   Ctrl Shift S  choose where to export, then export

import "core:strings"
import kit "kit:."
import p "palmy:."

Pick_Use :: enum {
	None,
	Media,
	Output,
}

// What this application can actually open: anything ffprobe will read, plus a
// subtitle file, which it loads for editing rather than transcribing.
CAP_OPEN_FILTERS := [?]kit.Pick_Filter {
	{
		"Media and subtitles",
		{
			"mp4", "mkv", "webm", "mov", "avi", "m4v", "mpg", "mpeg", "ogv",
			"mp3", "flac", "wav", "ogg", "opus", "m4a", "aac", "wma",
			"srt", "vtt", "ass", "ssa",
		},
	},
	kit.PICK_VIDEO,
	kit.PICK_AUDIO,
	kit.PICK_SUBTITLES,
	kit.PICK_ALL,
}

CAP_SAVE_FILTERS := [?]kit.Pick_Filter {
	{"SubRip", {"srt"}},
	{"WebVTT", {"vtt"}},
	{"Advanced SubStation", {"ass"}},
	kit.PICK_ALL,
}

begin_pick :: proc(m: ^App_State, use: Pick_Use) {
	m.pick_use = use
	switch use {
	case .None:
	case .Media:
		// Start beside the media that is already open, else the directory the
		// file browser pane is showing.
		dir := m.loaded ? kit.pick_parent(m.info.path) : m.dir
		kit.pick_begin(
			&m.pick,
			.Open_File,
			{title = "Open Media", dir = dir, filters = CAP_OPEN_FILTERS[:], confirm = "Open"},
		)
	case .Output:
		cur := strings.trim_space(string(m.out_buf[:]))
		if cur == "" {
			cur = default_output(
				m.loaded ? m.info.path : "captions",
				"",
				format_ext(m.fmt_i),
				context.temp_allocator,
			)
		}
		// The filter list is ordered so that the format already chosen in the
		// Export pane is the one the dialog offers first.
		start := 0
		switch m.fmt_i {
		case .SRT:
			start = 0
		case .VTT:
			start = 1
		case .ASS:
			start = 2
		case .TXT:
			start = 3 // plain text has no filter of its own; All files it is
		}
		kit.pick_begin(
			&m.pick,
			.Save_File,
			{
				title = "Export Captions",
				dir = kit.pick_parent(cur),
				name = kit.pick_base(cur),
				filters = CAP_SAVE_FILTERS[:],
				filter = start,
				confirm = "Export",
			},
		)
	}
}

pick_overlay :: proc(ui: ^p.Ctx, m: ^App_State) {
	if !kit.pick_active(&m.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &m.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	use := m.pick_use
	m.pick_use = .None
	if !res.ok {
		return
	}

	switch use {
	case .None:
	case .Media:
		clear(&m.path_buf)
		append(&m.path_buf, res.path)
		m.path_caret = len(m.path_buf)
		// Opening reshapes `segs`, and the waveform painter holds a slice of
		// it until the frame is painted — so it goes on the queue like every
		// other structural edit rather than happening here.
		queue_act(m, .Open, 0, res.path)
		m.focus = .Browse
	case .Output:
		clear(&m.out_buf)
		append(&m.out_buf, res.path)
		m.out_caret = len(m.out_buf)
		m.focus = .Browse
		// Writing over the media file is refused inside export_now, and the
		// dialog has already asked about replacing anything else.
		export_now(m)
	}
}
