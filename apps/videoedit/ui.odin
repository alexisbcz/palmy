package main

// The interface.
//
// Two panels are drawn pixel by pixel rather than as elements: the preview,
// which composites decoded frames, and the timeline, which needs per-pixel
// control over clip bodies, waveforms and the playhead. Everything else is
// ordinary palmy layout with shadcn classes.
//
// A custom draw procedure runs during paint and is handed *device* pixels, so
// the timeline's time-to-x mapping exists twice: once in logical units for hit
// testing (input.odin) and once scaled by `c.scale` here. The two agree
// because they are the same expression with the scale factored in.

import "core:fmt"
import "core:math"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

BG_TL :: 0x101215
BG_RULER :: 0x17191e
BG_TRACK_V :: 0x1a1d23
BG_TRACK_A :: 0x171a1f
CLIP_V :: 0x2f5fa8
CLIP_V_SEL :: 0x4f8ae0
CLIP_A :: 0x2c7a5a
CLIP_A_SEL :: 0x42b183
CLIP_T :: 0x8a5a22
CLIP_T_SEL :: 0xd08a36
PLAYHEAD :: 0xff4d4d
SNAP_COL :: 0xffd166
CAP_COL :: 0x6d4f9c

DEBUG_RECTS := false

TOOLBAR_H :: f32(48)
STATUS_H :: f32(28)

timeline_height :: proc(ed: ^Editor) -> f32 {
	return RULER_H + f32(len(ed.pr.tracks)) * TRACK_H + CAPTION_H
}

draw_ui :: proc(ed: ^Editor, ui: ^p.Ctx) {
	// Nothing behind the file dialog may hold the keyboard. The inspector's
	// three path fields are palmy `text_field`s built during this draw, and
	// `text_field` reads the frame's typed text whenever it holds focus — so
	// a field left focused from a click would eat the name being typed into
	// the dialog, which is built after it. Taking focus away here is enough:
	// the dialog does its own text editing and never asks palmy for focus.
	if kit.pick_active(&ed.pick) {
		p.set_focus(ui, 0)
		ed.mode = .Normal
		ed.field = .None
	}

	p.col(ui, "relative w-full h-full bg-background text-foreground")
	defer p.end(ui)

	toolbar(ed, ui)

	// The middle band gets an explicit height rather than `flex-1`. The
	// inspector is a tall scrolling column, and a flex row sizes itself to its
	// tallest child before the row is shrunk, so the preview panel was being
	// handed the inspector's full content height and letterboxing against it.
	// Subtracting the fixed bands from the viewport is unambiguous.
	band := p.size(ui).y - TOOLBAR_H - timeline_height(ed) - STATUS_H
	p.row(ui, "w-full min-h-0 overflow-hidden")
	p.style(ui).h = p.px(math.max(band, 120))
	{
		media_bin(ed, ui)
		center_panel(ed, ui)
		inspector(ed, ui)
	}
	p.end(ui)

	timeline_panel(ed, ui)
	status_bar(ed, ui)

	if ed.mode == .Help {
		help_overlay(ed, ui)
	}

	// Last, over everything, inside the root that is already `relative`.
	pick_overlay(ed, ui)
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

tool_button :: proc(
	ui: ^p.Ctx,
	label, keyhint: string,
	active := false,
	disabled := false,
) -> bool {
	idx := sc.button_open(
		ui,
		active ? .Default : .Outline,
		.SM,
		{hover = !disabled && p.is_hovered(ui, p.node_count(ui)), disabled = disabled},
	)
	hit := p.clickable(ui, idx) && !disabled
	p.text(ui, label, "text-xs whitespace-nowrap")
	if keyhint != "" {
		p.text(ui, keyhint, "text-[10] text-muted-foreground whitespace-nowrap")
	}
	sc.button_end(ui)
	return hit
}

toolbar :: proc(ed: ^Editor, ui: ^p.Ctx) {
	p.row(ui, "w-full h-12 shrink-0 items-center gap-2 px-3 border-b border-border bg-card")
	defer p.end(ui)

	p.icon(ui, sc.ICON_FILE_PLAY, "size-4 text-primary")
	p.text(ui, "videoedit", "text-sm font-semibold mr-2")

	if tool_button(ui, "Import", "i") {
		import_new(ed, ui)
	}
	// The buttons stay a fixed width and grey out when there is nothing to do,
	// rather than carrying the name of the edit: this app is used in a tiling
	// window manager, and a label that grows with "trim the out point" would
	// push the right-hand half of the toolbar off a narrow window. *What*
	// would be undone is in the status bar, which has room for it, and the
	// status message says it again the moment you press the key.
	if tool_button(ui, "Undo", "^Z", false, undo_label(ed) == "") {
		if label, ok := undo_apply(ed); ok {
			status(ed, ui, fmt.tprintf("undid: %s", label))
		}
	}
	if tool_button(ui, "Redo", "^+Z", false, redo_label(ed) == "") {
		if label, ok := redo_apply(ed); ok {
			status(ed, ui, fmt.tprintf("redid: %s", label))
		}
	}
	sc.separator(ui, .Vertical, "h-5")
	if tool_button(ui, "Place", "a") {
		place_media(ed, ui, -1)
	}
	sc.separator(ui, .Vertical, "h-5 mx-1")
	if tool_button(ui, ed.playing ? "Pause" : "Play", "space", ed.playing) {
		ed.playing = !ed.playing
		if ed.playing {
			audio_reset_presentation(ed)
		}
	}
	if tool_button(ui, "Split", "s") {
		undo_mark(ed, .Split, "split")
		if _, ok := split_at(&ed.pr, ed.cur_track, ed.playhead); ok {
			edited(ed)
		} else {
			undo_drop(ed)
		}
	}
	if tool_button(ui, "Ripple delete", "d") {
		if t, i, ok := sel_find(ed); ok {
			undo_mark(ed, .Ripple, "ripple delete")
			ripple_delete(&ed.pr, t, i)
			ed.sel = -1
			edited(ed)
		}
	}
	if tool_button(ui, "Dissolve", "x") {
		if t, i, ok := sel_find(ed); ok {
			undo_mark(ed, .Dissolve, "toggle the dissolve", ed.sel)
			toggle_dissolve(&ed.pr, t, i)
			edited(ed)
		}
	}
	if tool_button(ui, "Title", "t") {
		undo_mark(ed, .Title_Add, "add a title")
		v := track_of_kind(&ed.pr, .Video, 0)
		ed.sel = insert_title(&ed.pr, v, ed.playhead, 2.5, buf_str(&ed.buf_title))
		ed.cur_track = v
		edited(ed)
	}
	if tool_button(ui, "Captions", "c") {
		load_caption_file(ed, ui)
	}

	p.spacer(ui)

	p.textf(
		ui,
		"text-xs font-mono text-muted-foreground",
		"%s / %s",
		timecode(ed.playhead, ed.pr.out_fps),
		timecode(project_duration(&ed.pr), ed.pr.out_fps),
	)
	sc.separator(ui, .Vertical, "h-5 mx-1")
	if tool_button(ui, "Draft export", "p") {
		start_export(ed, ui, .Draft)
	}
	if tool_button(ui, "Final export", "P") {
		start_export(ed, ui, .Final)
	}
	if tool_button(ui, "?", "F1", ed.mode == .Help) {
		ed.mode = ed.mode == .Help ? .Normal : .Help
	}
}

import_new :: proc(ed: ^Editor, ui: ^p.Ctx) {
	n := 0
	for f in discover_media() {
		known := false
		for m in ed.pr.media {
			if m.path == f {
				known = true
				break
			}
		}
		if !known {
			importer_push(&ed.im, f)
			n += 1
		}
	}
	status(ed, ui, n > 0 ? fmt.tprintf("importing %d file(s)", n) : "nothing new to import")
}

load_caption_file :: proc(ed: ^Editor, ui: ^p.Ctx) {
	path := buf_str(&ed.buf_caption)
	undo_mark(ed, .Captions, "import captions")
	n, f, ok := load_captions(&ed.pr, path)
	if ok {
		edited(ed)
		status(ed, ui, fmt.tprintf("%d cues from %v: %s", n, f, base_name(path)))
	} else {
		undo_drop(ed)
		status(ed, ui, fmt.tprintf("could not read captions from %s", path))
	}
}

// ---------------------------------------------------------------------------
// Media bin
// ---------------------------------------------------------------------------

media_bin :: proc(ed: ^Editor, ui: ^p.Ctx) {
	p.col(ui, "w-[268] shrink-0 self-stretch border-r border-border bg-card min-h-0")
	defer p.end(ui)

	p.row(ui, "h-9 shrink-0 items-center px-3 gap-2 border-b border-border")
	p.text(ui, "Media", "text-xs font-semibold uppercase tracking-wide")
	p.spacer(ui)
	sc.badge(ui, fmt.tprintf("%d", len(ed.pr.media)), .Secondary)
	p.end(ui)

	p.col(ui, "flex-1 overflow-scroll p-2 gap-2 min-h-0")
	defer p.end(ui)

	if len(ed.pr.media) == 0 {
		p.text(ui, "Nothing imported yet.", "text-xs text-muted-foreground p-2")
		if importer_busy(&ed.im) {
			p.row(ui, "items-center gap-2 p-2")
			p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-4 text-muted-foreground", p.elapsed(ui))
			p.text(ui, "probing with ffprobe", "text-xs text-muted-foreground")
			p.end(ui)
		}
		return
	}

	for &m, i in ed.pr.media {
		p.key(ui, m.path)
		selected := i == ed.bin_sel
		row := p.row(
			ui,
			selected ? "gap-2 p-2 rounded-lg border border-primary bg-accent cursor-pointer" : "gap-2 p-2 rounded-lg border border-border hover:bg-accent transition cursor-pointer",
		)
		if p.clickable(ui, row) {
			ed.bin_sel = i
		}

		// Thumbnail, or a placeholder that keeps the row the same height.
		if m.thumb_ok {
			p.image(ui, m.thumb, "w-[76] h-[44] rounded-md overflow-hidden shrink-0", .Cover)
		} else {
			p.div(ui, "w-[76] h-[44] rounded-md bg-muted items-center justify-center shrink-0")
			p.icon(ui, m.has_audio ? sc.ICON_FILE_HEADPHONE : sc.ICON_IMAGE, "size-4 text-muted-foreground")
			p.end(ui)
		}

		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, m.name, "text-xs font-medium truncate")
		p.textf(
			ui,
			"text-[10] text-muted-foreground truncate",
			"%.2fs  %dx%d  %.0ffps",
			m.duration,
			m.width,
			m.height,
			m.fps,
		)
		p.row(ui, "gap-1")
		if m.vcodec != "" {
			sc.badge(ui, m.vcodec, .Secondary)
		}
		if m.acodec != "" {
			sc.badge(ui, m.acodec, .Outline)
		}
		p.end(ui)
		p.end(ui)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

center_panel :: proc(ed: ^Editor, ui: ^p.Ctx) {
	p.col(ui, "flex-1 self-stretch min-w-0 min-h-0 bg-background")
	defer p.end(ui)

	// The canvas is the panel. Nesting it inside a styled div meant two
	// rectangles that had to agree about their height, and `h-full` on the
	// inner one resolved against the outer one's pre-shrink height, so the
	// composited frame ran past the clip. One node, one rectangle.
	p.pixels(ui, "flex-1 m-3 rounded-xl overflow-hidden border border-border bg-black", ed, draw_preview)

	// Transport
	p.row(ui, "h-11 shrink-0 items-center gap-3 px-3 border-t border-border bg-card")
	defer p.end(ui)

	if tool_button(ui, "|<", "Home") {
		ed.playhead = 0
	}
	if tool_button(ui, ed.playing ? "||" : ">", "space", ed.playing) {
		ed.playing = !ed.playing
	}
	if tool_button(ui, ">|", "End") {
		ed.playhead = project_duration(&ed.pr)
	}
	p.textf(
		ui,
		"text-xs font-mono",
		"%s",
		timecode(ed.playhead, ed.pr.out_fps),
	)
	p.textf(
		ui,
		ed_rate(ed) == 1 ? "text-xs font-mono text-muted-foreground" : "text-xs font-mono text-primary font-semibold",
		"%gx",
		ed_rate(ed),
	)
	p.spacer(ui)

	p.text(ui, audio_stat_line(ed), "text-[11] font-mono text-muted-foreground whitespace-nowrap")
	sc.separator(ui, .Vertical, "h-3.5")

	decoded, dms, busy := preview_stats(&ed.pv)
	per := decoded > 0 ? dms / f64(decoded) : 0
	p.textf(
		ui,
		"text-[11] font-mono text-muted-foreground",
		"preview %dpx  grid %gfps  cache %d/%d  %d frames @ %.1fms  ui %.0ffps%s",
		preview_width(ed.pv.quality),
		PREVIEW_FPS,
		cache_count(&ed.pv),
		CACHE_N,
		decoded,
		per,
		ed.draw_fps,
		busy ? "  decoding" : "",
	)
}

cache_count :: proc(pv: ^Preview) -> int {
	n := 0
	for i in 0 ..< CACHE_N {
		if pv.used[i] {
			n += 1
		}
	}
	return n
}

// draw_preview composites the frame at the playhead: every video clip that
// covers it, bottom track first, with a dissolving clip drawn at its ramped
// opacity — the same order and the same alpha the export's overlay chain
// produces, so what you see is what you get.
draw_preview :: proc(c: ^p.Canvas, r: p.Rect, ed: ^Editor) {
	if DEBUG_RECTS {fmt.printf("preview rect %v  canvas %dx%d scale %g\n", r, c.w, c.h, c.scale)}
	p.fill_rect(c, r, p.hex(0x000000))
	pr := &ed.pr
	t := ed.playhead
	fonts := ed.fonts
	s := c.scale

	// The frame rectangle, letterboxed inside the panel.
	ar := f32(pr.out_w) / f32(math.max(1, pr.out_h))
	fw := r.w
	fh := fw / ar
	if fh > r.h {
		fh = r.h
		fw = fh * ar
	}
	frame := p.Rect{r.x + (r.w - fw) / 2, r.y + (r.h - fh) / 2, fw, fh}
	p.fill_rect(c, frame, p.hex(0x0a0a0c))

	tol := 1.0 / PREVIEW_FPS * 0.75
	drew := false
	// The timeline time of the frame actually painted on top, which is what the
	// presentation error is measured against.
	shown_at := f64(0)
	wanted := false

	#reverse for &tr, ti in pr.tracks {
		if tr.kind != .Video || !track_enabled(pr, ti) {
			continue
		}
		for cl in tr.clips {
			if cl.media < 0 || !clip_covers(cl, t) {
				continue
			}
			wanted = true
			op := f32(1)
			if cl.trans == .Dissolve && cl.xfade > 0.01 && t < cl.start + cl.xfade {
				op = f32((t - cl.start) / cl.xfade)
			}
			img, at, ok := cache_lookup(&ed.pv, cl.id, t, tol)
			if !ok {
				continue
			}
			p.draw_image(c, img, frame, op)
			// Tracks are walked bottom to top, so the last one to draw is the
			// one the viewer is looking at.
			shown_at = at
			drew = true
		}
	}
	if wanted {
		audio_note_presentation(ed, shown_at, t, drew)
	}

	if !drew {
		msg := len(pr.media) == 0 ? "import media to begin" : "decoding frames..."
		w := p.text_width(fonts, msg, 13 * s)
		p.draw_text(
			c,
			fonts,
			msg,
			frame.x + (frame.w - w) / 2,
			frame.y + frame.h / 2,
			13 * s,
			p.hex(0x8a8f99),
		)
	}

	// Titles, drawn the way drawtext will place them.
	for &tr in pr.tracks {
		if tr.kind != .Video {
			continue
		}
		for cl in tr.clips {
			if cl.media >= 0 || cl.title == "" || !clip_covers(cl, t) {
				continue
			}
			size := f32(cl.font_size) * frame.h / f32(math.max(1, pr.out_h)) * s
			w := p.text_width(fonts, cl.title, size, .Sans, .Semibold)
			x := frame.x + frame.w * cl.pos_x - w / 2
			y := frame.y + frame.h * cl.pos_y
			p.fill_round_rect(
				c,
				{x - 10 * s, y - size * 0.86, w + 20 * s, size * 1.25},
				{4 * s, 4 * s, 4 * s, 4 * s},
				p.hexa(0x00000073),
			)
			p.draw_text(c, fonts, cl.title, x, y, size, p.hex(cl.color), .Sans, .Semibold)
		}
	}

	// Captions, as they will be burned in.
	if ci := caption_at(pr, t); ci >= 0 {
		size := 15 * s * (frame.h / 360)
		size = math.max(size, 11 * s)
		lines := strings.split_lines(pr.captions[ci].text, context.temp_allocator)
		y := frame.y + frame.h - size * 1.25 * f32(len(lines) - 1) - size * 0.9 - 14 * s
		for line in lines {
			w := p.text_width(fonts, line, size, .Sans, .Medium)
			x := frame.x + (frame.w - w) / 2
			p.fill_round_rect(
				c,
				{x - 7 * s, y - size * 0.86, w + 14 * s, size * 1.3},
				{3 * s, 3 * s, 3 * s, 3 * s},
				p.hexa(0x000000a6),
			)
			p.draw_text(c, fonts, line, x, y, size, p.WHITE, .Sans, .Medium)
			y += size * 1.2
		}
	}
}

// ---------------------------------------------------------------------------
// Inspector
// ---------------------------------------------------------------------------

field_row :: proc(ed: ^Editor, ui: ^p.Ctx, label: string, buf: ^[dynamic]u8, which: Field) {
	p.col(ui, "gap-1 w-full")
	defer p.end(ui)
	p.text(ui, label, "text-[10] uppercase tracking-wide text-muted-foreground")
	at := p.node_count(ui)
	p.text_field(ui, buf, "", "w-full h-8 text-xs font-mono")
	if p.focused(ui, at) {
		ed.mode = .Typing
		ed.field = which
	} else if ed.field == which && ed.mode == .Typing {
		ed.mode = .Normal
		ed.field = .None
	}
}

// title_field is the one text field whose edits land somewhere other than a
// path: it writes straight into the selected title clip, so the preview shows
// the words as they are typed.
title_field :: proc(ed: ^Editor, ui: ^p.Ctx) -> bool {
	p.col(ui, "gap-1 w-full")
	defer p.end(ui)
	p.text(ui, "TEXT", "text-[10] uppercase tracking-wide text-muted-foreground")
	at := p.node_count(ui)
	changed, _ := p.text_field(ui, &ed.buf_title, "Title text", "w-full h-8 text-xs")
	if p.focused(ui, at) {
		ed.mode = .Typing
		ed.field = .Title_Text
	} else if ed.field == .Title_Text && ed.mode == .Typing {
		ed.mode = .Normal
		ed.field = .None
	}
	return changed
}

inspector :: proc(ed: ^Editor, ui: ^p.Ctx) {
	pr := &ed.pr
	p.col(ui, "w-[312] shrink-0 self-stretch border-l border-border bg-card min-h-0 overflow-scroll")
	defer p.end(ui)

	p.col(ui, "p-3 gap-2 w-full")
	defer p.end(ui)

	// --- clip -----------------------------------------------------------
	p.text(ui, "Clip", "text-xs font-semibold uppercase tracking-wide")
	if t, i, ok := sel_find(ed); ok {
		cl := &pr.tracks[t].clips[i]
		p.col(ui, "gap-1 p-2 rounded-lg border border-border w-full")
		name := cl.media >= 0 && cl.media < len(pr.media) ? pr.media[cl.media].name : "Title"
		p.row(ui, "items-center gap-2 w-full")
		p.text(ui, name, "text-xs font-medium truncate flex-1 min-w-0")
		sc.badge(ui, pr.tracks[t].name, .Secondary)
		p.end(ui)
		kv(ui, "timeline", fmt.tprintf("%s → %s", timecode(cl.start, pr.out_fps), timecode(clip_end(cl^), pr.out_fps)))
		kv(ui, "source in/out", fmt.tprintf("%.2fs → %.2fs", cl.src_in, cl.src_out))
		kv(ui, "length", fmt.tprintf("%.2fs", clip_len(cl^)))
		kv(ui, "transition", cl.trans == .Dissolve ? fmt.tprintf("dissolve %.2fs", cl.xfade) : "cut")
		if pr.tracks[t].kind == .Audio && cl.media >= 0 {
			p.row(ui, "items-center gap-2 w-full")
			p.text(ui, "gain", "text-[11] text-muted-foreground w-[72] shrink-0")
			// A slider writes through the pointer, so by the time it says
			// "changed" the old value is gone — and the snapshot has to be of
			// the state *before*. Putting the old value back, marking, and
			// then applying the new one is the whole trick, and it is why
			// every widget edit in this file looks like this.
			was := cl.gain
			if p.slider(ui, &cl.gain, 0, 2, "flex-1") {
				now := cl.gain
				cl.gain = was
				undo_mark(ed, .Gain, "change the gain", cl.id)
				cl.gain = now
				edited_audio(ed)
			}
			p.textf(ui, "text-[11] font-mono w-[40] text-center shrink-0", "%.0f%%", cl.gain * 100)
			p.end(ui)
		}
		if cl.media < 0 {
			// The title's own text. The field keeps `buf_title` and the clip
			// in step, so typing changes the preview as it is typed and the
			// next `t` starts from whatever was last written.
			if ed.sel != ed.title_buf_for {
				set_str(&ed.buf_title, cl.title)
				ed.title_buf_for = ed.sel
			}
			changed := title_field(ed, ui)
			if changed {
				// Marked before `cl.title` is replaced, so the snapshot holds
				// the text as it was. Typing coalesces by kind and clip, so a
				// word is one undo step rather than one per letter.
				undo_mark(ed, .Title_Text, "edit the title", cl.id)
				delete(cl.title)
				cl.title = strings.clone(buf_str(&ed.buf_title))
				edited(ed)
			}
			p.row(ui, "items-center gap-2 w-full")
			p.text(ui, "size", "text-[11] text-muted-foreground w-[72] shrink-0")
			fs := f32(cl.font_size)
			if p.slider(ui, &fs, 16, 180, "flex-1") {
				undo_mark(ed, .Title_Style, "restyle the title", cl.id)
				cl.font_size = int(fs + 0.5)
				edited(ed)
			}
			p.textf(ui, "text-[11] font-mono w-[40] text-center shrink-0", "%dpt", cl.font_size)
			p.end(ui)
			p.row(ui, "items-center gap-2 w-full")
			p.text(ui, "y", "text-[11] text-muted-foreground w-[72] shrink-0")
			wy := cl.pos_y
			if p.slider(ui, &cl.pos_y, 0.05, 0.95, "flex-1") {
				ny := cl.pos_y
				cl.pos_y = wy
				undo_mark(ed, .Title_Style, "move the title", cl.id)
				cl.pos_y = ny
				edited(ed)
			}
			p.end(ui)
			p.row(ui, "items-center gap-2 w-full")
			p.text(ui, "x", "text-[11] text-muted-foreground w-[72] shrink-0")
			wx := cl.pos_x
			if p.slider(ui, &cl.pos_x, 0.05, 0.95, "flex-1") {
				nx := cl.pos_x
				cl.pos_x = wx
				undo_mark(ed, .Title_Style, "move the title", cl.id)
				cl.pos_x = nx
				edited(ed)
			}
			p.end(ui)
			p.row(ui, "gap-1 flex-wrap")
			for col in ([?]u32{0xffffff, 0xffd166, 0xef476f, 0x06d6a0, 0x118ab2}) {
				idx := p.div(ui, "size-5 rounded-md border border-border cursor-pointer")
				p.style(ui).bg = p.flat(p.hex(col))
				if p.clickable(ui, idx) {
					undo_mark(ed, .Title_Style, "recolour the title", cl.id)
					cl.color = col
					edited(ed)
				}
				p.end(ui)
			}
			p.end(ui)
		}
		p.end(ui)
	} else {
		p.text(ui, "No clip selected. Click one, or use [ and ].", "text-[11] text-muted-foreground")
	}

	sc.separator(ui, .Horizontal, "my-1")

	// --- captions -------------------------------------------------------
	p.row(ui, "items-center gap-2 w-full")
	p.text(ui, "Captions", "text-xs font-semibold uppercase tracking-wide")
	p.spacer(ui)
	sc.badge(ui, fmt.tprintf("%d cues", len(pr.captions)), .Secondary)
	p.end(ui)
	field_row(ed, ui, "SRT / VTT / ASS file", &ed.buf_caption, .Caption_Path)
	p.row(ui, "gap-2 w-full")
	if tool_button(ui, "Choose…", "^C") {
		begin_pick(ed, .Caption)
	}
	if tool_button(ui, "Import captions", "c") {
		load_caption_file(ed, ui)
	}
	if tool_button(ui, "-0.1s", ",") {
		undo_mark(ed, .Caption_Nudge, "nudge the captions")
		pr.caption_offset -= 0.1
		edited(ed)
	}
	if tool_button(ui, "+0.1s", ".") {
		undo_mark(ed, .Caption_Nudge, "nudge the captions")
		pr.caption_offset += 0.1
		edited(ed)
	}
	p.end(ui)
	p.textf(
		ui,
		"text-[11] font-mono text-muted-foreground",
		"nudge %+.1fs%s",
		pr.caption_offset,
		pr.caption_src == "" ? "" : fmt.tprintf("  ·  %s", base_name(pr.caption_src)),
	)

	sc.separator(ui, .Horizontal, "my-1")

	// --- export ---------------------------------------------------------
	p.text(ui, "Export", "text-xs font-semibold uppercase tracking-wide")
	field_row(ed, ui, "output file", &ed.buf_export, .Export_Path)
	p.row(ui, "gap-2 w-full")
	if tool_button(ui, "Choose…", "^E") {
		begin_pick(ed, .Export)
	}
	if tool_button(ui, "Draft 640x360", "p") {
		start_export(ed, ui, .Draft)
	}
	if tool_button(ui, "Final 1280x720", "P") {
		start_export(ed, ui, .Final)
	}
	p.end(ui)

	st := exporter_status(&ed.ex)
	switch st.state {
	case .Idle:
	case .Running:
		sc.progress_open(ui, "w-full")
		sc.progress_header(ui, "encoding", fmt.tprintf("%.0f%%", st.progress * 100))
		sc.progress_track(ui, st.progress * 100)
		sc.progress_end(ui)
		p.text(ui, st.message, "text-[11] font-mono text-muted-foreground truncate")
	case .Done:
		p.row(ui, "items-center gap-2")
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-4 text-emerald-500")
		p.text(ui, "export finished", "text-xs text-emerald-500")
		p.end(ui)
		p.text(ui, st.out_path, "text-[10] font-mono text-muted-foreground truncate")
		if tool_button(ui, "Verify with ffprobe", "v") {
			verify_last(ed, ui)
		}
	case .Failed:
		p.row(ui, "items-center gap-2")
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-4 text-destructive")
		p.text(ui, "export failed", "text-xs text-destructive")
		p.end(ui)
		p.text(ui, st.message, "text-[10] font-mono text-destructive")
	}

	if ed.verified {
		p.col(ui, "gap-1 p-2 rounded-lg border border-border w-full")
		p.text(ui, "ffprobe says", "text-[10] uppercase tracking-wide text-muted-foreground")
		if ed.verify.ok {
			kv(ui, "duration", fmt.tprintf("%.2fs", ed.verify.duration))
			kv(ui, "size", fmt.tprintf("%dx%d", ed.verify.width, ed.verify.height))
			kv(ui, "streams", fmt.tprintf("%d (%s / %s)", ed.verify.streams, ed.verify.vcodec, ed.verify.acodec))
		} else {
			p.text(ui, "unreadable", "text-[11] text-destructive")
		}
		if ed.still_ok {
			p.image(ui, ed.still, "w-full h-[120] rounded-md overflow-hidden", .Contain)
		}
		p.end(ui)
	}

	sc.separator(ui, .Horizontal, "my-1")
	p.text(ui, "Project", "text-xs font-semibold uppercase tracking-wide")
	field_row(ed, ui, "project file", &ed.buf_project, .Project_Path)
	p.row(ui, "gap-2 w-full")
	if tool_button(ui, "Choose…", "^P") {
		begin_pick(ed, .Project)
	}
	p.end(ui)
	p.row(ui, "gap-2 w-full")
	if tool_button(ui, "Save", "^S") {
		ok := project_save(pr, buf_str(&ed.buf_project), ed.playhead, ed.zoom)
		status(ed, ui, ok ? "saved" : "save failed")
	}
	if tool_button(ui, "Load", "^O") {
		res := project_load(pr, buf_str(&ed.buf_project))
		if res.ok {
			seek_to(ed, res.playhead)
			ed.zoom = res.zoom
			ed.sel = -1
			for m in pr.media {
				importer_push(&ed.im, m.path)
			}
			edited(ed)
			undo_reset(ed)
		}
		status(ed, ui, res.ok ? "loaded" : res.err)
	}
	p.end(ui)
}

kv :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "items-center gap-2 w-full")
	defer p.end(ui)
	p.text(ui, k, "text-[11] text-muted-foreground w-[90] shrink-0")
	p.text(ui, v, "text-[11] font-mono flex-1 truncate")
}

// ---------------------------------------------------------------------------
// Timeline
// ---------------------------------------------------------------------------

timeline_panel :: proc(ed: ^Editor, ui: ^p.Ctx) {
	idx := p.pixels(ui, "w-full shrink-0 border-t border-border overflow-hidden", ed, draw_timeline)
	p.style(ui).h = p.px(timeline_height(ed))

	// The id is stable across frames; the main loop reads the rectangle from
	// it at the top of the next frame.
	ed.tl_id = p.node_id(ui, idx)
	if ed.tl.w <= 0 {
		ed.tl = p.rect_of(ui, ed.tl_id)
	}
}

@(private = "file")
tick_step :: proc(zoom: f32) -> f64 {
	// A tick every 96 device pixels or so: closer than that and the labels
	// collide, further and the ruler stops telling you anything.
	for s in ([?]f64{0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600}) {
		if f64(zoom) * s >= 96 {
			return s
		}
	}
	return 600
}

// ruler_label is shorter than a full timecode, because a tick every hundred
// pixels cannot carry "00:00:03:00".
@(private = "file")
ruler_label :: proc(t: f64, step: f64) -> string {
	m := int(t) / 60
	s := t - f64(m * 60)
	if step < 1 {
		return fmt.tprintf("%d:%04.1f", m, s)
	}
	return fmt.tprintf("%d:%02d", m, int(s + 0.0001))
}

draw_timeline :: proc(c: ^p.Canvas, r: p.Rect, ed: ^Editor) {
	if DEBUG_RECTS {fmt.printf("timeline rect %v\n", r)}
	pr := &ed.pr
	fonts := ed.fonts
	s := c.scale
	gut := GUTTER * s
	zoom := f64(ed.zoom) * f64(s)

	t2x :: proc(r: p.Rect, gut: f32, zoom, scroll, t: f64) -> f32 {
		return r.x + gut + f32((t - scroll) * zoom)
	}

	p.fill_rect(c, r, p.hex(BG_TL))

	// --- ruler ---------------------------------------------------------
	ruler := p.Rect{r.x, r.y, r.w, RULER_H * s}
	p.fill_rect(c, ruler, p.hex(BG_RULER))
	step := tick_step(f32(zoom))
	t0 := math.floor(ed.scroll / step) * step
	t1 := ed.scroll + f64((r.w - gut) / f32(zoom))
	for t := t0; t <= t1 + step; t += step {
		if t < 0 {
			continue
		}
		x := t2x(r, gut, zoom, ed.scroll, t)
		if x < r.x + gut - 1 || x > r.x + r.w {
			continue
		}
		p.fill_rect(c, {x, ruler.y + ruler.h - 7 * s, math.max(1, s), 7 * s}, p.hex(0x4a5059))
		label := ruler_label(t, step)
		p.draw_text(c, fonts, label, x + 4 * s, ruler.y + 14 * s, 10 * s, p.hex(0x9aa1ab), .Mono)
	}

	// --- tracks --------------------------------------------------------
	for &tr, ti in pr.tracks {
		y := r.y + RULER_H * s + f32(ti) * TRACK_H * s
		row := p.Rect{r.x, y, r.w, TRACK_H * s}
		p.fill_rect(c, row, p.hex(tr.kind == .Video ? BG_TRACK_V : BG_TRACK_A))
		p.fill_rect(c, {r.x, y + row.h - math.max(1, s), r.w, math.max(1, s)}, p.hex(0x0b0c0f))

		// Name gutter.
		p.fill_rect(c, {r.x, y, gut, row.h}, p.hex(0x15171c))
		if ti == ed.cur_track {
			p.fill_rect(c, {r.x, y, 3 * s, row.h}, p.hex(0x4f8ae0))
		}
		p.draw_text(c, fonts, tr.name, r.x + 8 * s, y + 17 * s, 11 * s, p.hex(0xd6dae0), .Mono, .Medium)
		audible := track_enabled(pr, ti)
		mb := p.Rect{r.x + 8 * s, y + 26 * s, 18 * s, 15 * s}
		p.fill_round_rect(c, mb, {3 * s, 3 * s, 3 * s, 3 * s}, p.hex(tr.mute ? 0x7a2230 : 0x24282f))
		p.draw_text(c, fonts, "M", mb.x + 5 * s, mb.y + 11 * s, 9 * s, p.hex(tr.mute ? 0xffc9d1 : 0x7b818b), .Mono, .Bold)
		sb := p.Rect{r.x + 30 * s, y + 26 * s, 18 * s, 15 * s}
		p.fill_round_rect(c, sb, {3 * s, 3 * s, 3 * s, 3 * s}, p.hex(tr.solo ? 0x1f5fa8 : 0x24282f))
		p.draw_text(c, fonts, "S", sb.x + 6 * s, sb.y + 11 * s, 9 * s, p.hex(tr.solo ? 0xcfe3ff : 0x7b818b), .Mono, .Bold)

		// Clips.
		p.push_clip(c, {r.x + gut, y, r.w - gut, row.h})
		for cl in tr.clips {
			x0 := t2x(r, gut, zoom, ed.scroll, cl.start)
			x1 := t2x(r, gut, zoom, ed.scroll, clip_end(cl))
			if x1 < r.x + gut || x0 > r.x + r.w {
				continue
			}
			body := p.Rect{x0, y + 4 * s, math.max(x1 - x0, 2 * s), row.h - 10 * s}
			sel := cl.id == ed.sel
			base: u32
			switch {
			case cl.media < 0:
				base = sel ? CLIP_T_SEL : CLIP_T
			case tr.kind == .Video:
				base = sel ? CLIP_V_SEL : CLIP_V
			case:
				base = sel ? CLIP_A_SEL : CLIP_A
			}
			if !audible && tr.kind == .Audio {
				base = 0x3a3d44
			}
			rad := p.Radius{4 * s, 4 * s, 4 * s, 4 * s}
			p.fill_round_rect(c, body, rad, p.hex(base))

			p.push_clip(c, body)
			if cl.media >= 0 && cl.media < len(pr.media) {
				m := &pr.media[cl.media]
				if tr.kind == .Video && m.thumb_ok {
					tw := body.h * f32(m.thumb.w) / f32(math.max(1, m.thumb.h))
					p.draw_image(c, m.thumb, {body.x, body.y, tw, body.h}, 0.9)
					if body.w > tw * 2 {
						p.draw_image(
							c,
							m.thumb,
							{body.x + body.w - tw, body.y, tw, body.h},
							0.9,
						)
					}
				}
				if tr.kind == .Audio && m.peaks != nil {
					draw_waveform(c, body, m, cl, zoom, ed.scroll, r, gut)
				}
			}
			// Dissolve marker: a wedge over the overlap.
			if cl.trans == .Dissolve && cl.xfade > 0.01 {
				xw := f32(cl.xfade * zoom)
				n := int(math.min(xw, body.w))
				for i in 0 ..< n {
					a := f32(i) / math.max(1, xw)
					p.fill_rect(
						c,
						{body.x + f32(i), body.y, 1, body.h},
						p.fade(p.hex(0x000000), 0.55 * (1 - a)),
					)
				}
				p.draw_line(c, body.x, body.y + body.h, body.x + xw, body.y, math.max(1, s), p.hexa(0xffffffcc))
			}
			p.pop_clip(c)

			if sel {
				p.stroke_round_rect(c, body, rad, math.max(1.5 * s, 1), p.hex(0xffffff))
			}

			label := cl.media >= 0 && cl.media < len(pr.media) ? pr.media[cl.media].name : cl.title
			if body.w > 40 * s {
				p.push_clip(c, {body.x + 4 * s, body.y, body.w - 8 * s, body.h})
				p.draw_text(c, fonts, label, body.x + 6 * s, body.y + 13 * s, 10 * s, p.WHITE, .Sans, .Medium)
				if cl.gain != 1 && tr.kind == .Audio {
					p.draw_text(
						c,
						fonts,
						fmt.tprintf("%.0f%%", cl.gain * 100),
						body.x + 6 * s,
						body.y + body.h - 5 * s,
						9 * s,
						p.hexa(0xffffffcc),
						.Mono,
					)
				}
				p.pop_clip(c)
			}
		}
		p.pop_clip(c)
	}

	// --- caption lane ---------------------------------------------------
	cy := r.y + RULER_H * s + f32(len(pr.tracks)) * TRACK_H * s
	cap_row := p.Rect{r.x, cy, r.w, CAPTION_H * s}
	p.fill_rect(c, cap_row, p.hex(0x14121c))
	p.fill_rect(c, {r.x, cy, gut, cap_row.h}, p.hex(0x15171c))
	p.draw_text(c, fonts, "CC", r.x + 8 * s, cy + 19 * s, 11 * s, p.hex(0xb6a6e0), .Mono, .Medium)
	p.push_clip(c, {r.x + gut, cy, r.w - gut, cap_row.h})
	for cue in pr.captions {
		a := cue.start + pr.caption_offset
		b := cue.end + pr.caption_offset
		x0 := t2x(r, gut, zoom, ed.scroll, a)
		x1 := t2x(r, gut, zoom, ed.scroll, b)
		if x1 < r.x + gut || x0 > r.x + r.w {
			continue
		}
		box := p.Rect{x0, cy + 5 * s, math.max(x1 - x0, 2 * s), cap_row.h - 10 * s}
		live := ed.playhead >= a && ed.playhead < b
		p.fill_round_rect(c, box, {3 * s, 3 * s, 3 * s, 3 * s}, p.hex(live ? 0x9b7fd4 : CAP_COL))
		if box.w > 30 * s {
			p.push_clip(c, box)
			one := cue.text
			if i := strings.index_byte(one, '\n'); i >= 0 {
				one = one[:i]
			}
			p.draw_text(c, fonts, one, box.x + 5 * s, box.y + 13 * s, 9 * s, p.WHITE)
			p.pop_clip(c)
		}
	}
	p.pop_clip(c)

	// --- snap guide and playhead ----------------------------------------
	if ed.snap_show {
		x := t2x(r, gut, zoom, ed.scroll, ed.snap_at)
		p.fill_rect(c, {x - s / 2, r.y, math.max(1, s), r.h}, p.hex(SNAP_COL))
	}
	px := t2x(r, gut, zoom, ed.scroll, ed.playhead)
	if px >= r.x + gut - 1 && px <= r.x + r.w {
		p.fill_rect(c, {px - s, r.y, math.max(2, 2 * s), r.h}, p.hex(PLAYHEAD))
		p.fill_round_rect(
			c,
			{px - 6 * s, r.y + 1 * s, 12 * s, 11 * s},
			{2 * s, 2 * s, 2 * s, 2 * s},
			p.hex(PLAYHEAD),
		)
	}
	// Mask anything that drew over the gutter.
	p.fill_rect(c, {r.x, r.y, gut, RULER_H * s}, p.hex(BG_RULER))
	p.draw_text(c, fonts, "TIME", r.x + 8 * s, r.y + 16 * s, 10 * s, p.hex(0x6b7280), .Mono, .Medium)
}

// draw_waveform paints one peak per device pixel column, reading the media's
// 100-per-second peak table at the source time that column maps to.
draw_waveform :: proc(
	c: ^p.Canvas,
	body: p.Rect,
	m: ^Media,
	cl: Clip,
	zoom, scroll: f64,
	r: p.Rect,
	gut: f32,
) {
	mid := body.y + body.h / 2
	half := body.h / 2 - 3
	col := p.hexa(0xffffff99)
	x0 := int(math.max(body.x, r.x + gut))
	x1 := int(math.min(body.x + body.w, r.x + r.w))
	for x in x0 ..< x1 {
		tl := scroll + f64(f32(x) - r.x - gut) / zoom
		src := cl.src_in + (tl - cl.start)
		i := int(src * PEAKS_PER_SEC)
		if i < 0 || i >= len(m.peaks) {
			continue
		}
		v := m.peaks[i] * cl.gain
		h := math.min(half, half * v)
		if h < 0.5 {
			h = 0.5
		}
		p.fill_rect(c, {f32(x), mid - h, 1, h * 2}, col)
	}
}

// ---------------------------------------------------------------------------
// Status bar and help
// ---------------------------------------------------------------------------

status_bar :: proc(ed: ^Editor, ui: ^p.Ctx) {
	p.row(ui, "w-full h-7 shrink-0 items-center px-3 gap-3 border-t border-border bg-card")
	defer p.end(ui)

	st := exporter_status(&ed.ex)
	switch st.state {
	case .Idle:
	case .Running:
		p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-3.5 text-primary", p.elapsed(ui))
		p.textf(ui, "text-[11] font-mono text-primary whitespace-nowrap", "export %.0f%%", st.progress * 100)
		p.div(ui, "w-[120] h-1.5 rounded-full bg-muted overflow-hidden")
		p.div(ui, "h-full bg-primary")
		p.style(ui).w = p.pct(st.progress * 100)
		p.end(ui)
		p.end(ui)
		sc.separator(ui, .Vertical, "h-3.5")
	case .Done:
		p.icon(ui, sc.ICON_CIRCLE_CHECK, "size-3.5 text-emerald-500")
		p.text(ui, "export finished", "text-[11] text-emerald-500 whitespace-nowrap")
		sc.separator(ui, .Vertical, "h-3.5")
	case .Failed:
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-3.5 text-destructive")
		p.text(ui, "export failed", "text-[11] text-destructive whitespace-nowrap")
		sc.separator(ui, .Vertical, "h-3.5")
	}

	live := ed.status != "" && f64(p.elapsed(ui)) < ed.status_until
	p.text(
		ui,
		live ? ed.status : "F1 for the key map  ·  drag a clip to move it, its edges to trim",
		live ? "text-[11] truncate" : "text-[11] text-muted-foreground truncate",
	)
	p.spacer(ui)
	// `whitespace-nowrap shrink-0`: this row is a fixed 28px tall, so a line
	// that wraps is a line with half of itself clipped off the bottom. The
	// message on the left truncates instead, which is the right half to lose.
	p.textf(
		ui,
		"text-[11] font-mono text-muted-foreground whitespace-nowrap shrink-0",
		"%s  ·  %.0fpx/s  ·  %d cues",
		undo_summary(ed),
		ed.zoom,
		len(ed.pr.captions),
	)
}

HELP :: [?][2]string {
	{"space", "play / pause"},
	{"left right", "step one frame, and hear it (shift: one second)"},
	{"< >", "playback rate slower / faster, 0.25x to 4x"},
	{"home end", "jump to the start / end"},
	{"up down", "change track"},
	{"[ ]", "select the previous / next clip"},
	{"j k", "move through the media bin"},
	{"i", "import new files from the media folder"},
	{"a / n", "place the selected media at the end / at the playhead"},
	{"s", "split the clip under the playhead"},
	{"d", "ripple delete (closes the gap)"},
	{"delete", "delete and leave the gap"},
	{"q w", "trim the in point out / in"},
	{"e r", "trim the out point in / out"},
	{"h l", "nudge the clip, snapping to edges"},
	{"m", "move the clip to the next track"},
	{"x", "toggle a cross-dissolve with the clip before"},
	{"g G", "clip gain down / up"},
	{"u o", "mute / solo the current track"},
	{"- =", "zoom the timeline"},
	{"f", "preview resolution"},
	{"t", "add a title at the playhead"},
	{"c", "import the caption file"},
	{", .", "nudge the captions by 0.1s"},
	{"p P", "export a draft / a final"},
	{"v", "verify the last export with ffprobe"},
	{"ctrl-s ctrl-o", "save / load the project"},
	{"ctrl-z", "undo — the toolbar says what it will undo"},
	{"ctrl-shift-z", "redo (ctrl-y as well)"},
}

help_overlay :: proc(ed: ^Editor, ui: ^p.Ctx) {
	ov := p.div(ui, "absolute inset-0 z-50 items-center justify-center bg-black/70")
	_ = ov
	defer p.end(ui)

	p.col(ui, "w-[560] max-h-full p-5 gap-2 rounded-xl border border-border bg-card shadow-2xl overflow-scroll")
	defer p.end(ui)

	p.row(ui, "items-center gap-2 w-full")
	p.text(ui, "Keys", "text-sm font-semibold")
	p.spacer(ui)
	p.text(ui, "Esc or F1 closes", "text-[11] text-muted-foreground")
	p.end(ui)
	sc.separator(ui, .Horizontal, "my-1")

	for h in HELP {
		p.row(ui, "items-center gap-3 w-full")
		p.text(ui, h[0], "text-[11] font-mono text-primary w-[110] shrink-0")
		p.text(ui, h[1], "text-[11] text-muted-foreground flex-1")
		p.end(ui)
	}
}
