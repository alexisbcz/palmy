package main

// Keyboard and pointer.
//
// Every edit has a key, not just a mouse gesture. That is partly because an
// editor is faster that way, and partly because this compositor build cannot
// synthesize pointer clicks, so a recorded demo can only drive the app from
// the keyboard — if an operation has no key, it cannot be shown.

import "core:fmt"
import "core:math"
import "core:strings"
import kit "kit:."
import p "palmy:."

FRAME_STEP :: 1.0 / 30.0
NUDGE :: 0.25

sel_find :: proc(ed: ^Editor) -> (track, idx: int, ok: bool) {
	if ed.sel < 0 {
		return -1, -1, false
	}
	t, i := find_clip(&ed.pr, ed.sel)
	return t, i, t >= 0
}

// edited is what every timeline mutation ends with. The preview's cached
// frames may now be at the wrong timeline position, and what is audible under
// the playhead may have changed, so both have to be told.
edited :: proc(ed: ^Editor) {
	ed.last_edit += 1
	ed.mix_dirty = true
}

// edited_audio is for a change only the speakers can notice — a clip gain, or
// mute and solo on an audio track. The decoded frames are all still in the
// right places, so there is no reason to throw a cache of them away.
edited_audio :: proc(ed: ^Editor) {
	ed.mix_dirty = true
}

// seek_to moves the playhead *deliberately*, as opposed to the playhead moving
// because the audio clock advanced. That distinction is the whole of seeking:
// `seek_req` is what tells the mixer to throw its pipeline away and build a
// new one at the new position, and tearing the pipeline down is the flush —
// the pipe, ffmpeg's buffer and pw-cat's queue all go with the processes, so
// there is nothing stale left to come out.
seek_to :: proc(ed: ^Editor, t: f64) {
	ed.playhead = math.max(0, t)
	ed.seek_req = true
}

handle_keys :: proc(ed: ^Editor, ui: ^p.Ctx) {
	// The file dialog owns the keyboard while it is up; it reads its own
	// input in `pick_overlay`, during the draw pass.
	if kit.pick_active(&ed.pick) {
		return
	}
	if p.shortcut(ui, 'i', {.Ctrl}) {
		begin_pick(ed, .Import)
		return
	}
	if p.shortcut(ui, 'e', {.Ctrl}) {
		begin_pick(ed, .Export)
		return
	}
	if p.shortcut(ui, 'c', {.Ctrl, .Shift}) || p.shortcut(ui, 'C', {.Ctrl, .Shift}) {
		begin_pick(ed, .Caption)
		return
	}
	if p.shortcut(ui, 'p', {.Ctrl, .Shift}) || p.shortcut(ui, 'P', {.Ctrl, .Shift}) {
		begin_pick(ed, .Project)
		return
	}
	// Undo and redo come before the mode check: an undo is useful while a text
	// field has the keyboard, and Ctrl-Z is not something a path field wants.
	if p.shortcut(ui, 'z', {.Ctrl}) {
		if label, ok := undo_apply(ed); ok {
			status(ed, ui, fmt.tprintf("undid: %s", label))
		} else {
			status(ed, ui, "nothing to undo")
		}
		return
	}
	if p.shortcut(ui, 'z', {.Ctrl, .Shift}) ||
	   p.shortcut(ui, 'Z', {.Ctrl, .Shift}) ||
	   p.shortcut(ui, 'y', {.Ctrl}) {
		if label, ok := redo_apply(ed); ok {
			status(ed, ui, fmt.tprintf("redid: %s", label))
		} else {
			status(ed, ui, "nothing to redo")
		}
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		if ed.mode != .Normal {
			ed.mode = .Normal
			ed.field = .None
			p.set_focus(ui, 0)
		} else {
			ed.playing = false
		}
		return
	}
	if ed.mode == .Typing {
		return // the text field owns the keyboard
	}

	pr := &ed.pr
	total := project_duration(pr)

	// --- transport ------------------------------------------------------
	if p.shortcut(ui, p.KEY_SPACE, {}) {
		ed.playing = !ed.playing
		if ed.playing && ed.playhead >= total - 0.01 {
			seek_to(ed, 0)
		}
		if ed.playing {
			audio_reset_presentation(ed)
		}
	}
	step := .Shift in ui.input.mods ? 1.0 : FRAME_STEP
	if n := p.key_count(ui, p.KEY_LEFT); n > 0 {
		seek_to(ed, ed.playhead - f64(n) * step)
	}
	if n := p.key_count(ui, p.KEY_RIGHT); n > 0 {
		seek_to(ed, math.min(total, ed.playhead + f64(n) * step))
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		seek_to(ed, 0)
	}
	if p.key_pressed(ui, p.KEY_END) {
		seek_to(ed, total)
	}

	// --- media bin ------------------------------------------------------
	if p.shortcut(ui, 'j', {}) {
		ed.bin_sel = min(ed.bin_sel + 1, max(0, len(pr.media) - 1))
	}
	if p.shortcut(ui, 'k', {}) {
		ed.bin_sel = max(0, ed.bin_sel - 1)
	}
	if p.shortcut(ui, 'i', {}) {
		n := 0
		for f in discover_media() {
			known := false
			for m in pr.media {
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
	if p.shortcut(ui, 'a', {}) {
		undo_mark(ed, .Place, "place a clip")
		place_media(ed, ui, -1)
	}
	if p.shortcut(ui, 'n', {}) {
		undo_mark(ed, .Place, "place a clip")
		place_media(ed, ui, ed.playhead)
	}

	// --- selection ------------------------------------------------------
	if n := p.key_count(ui, p.KEY_DOWN); n > 0 {
		ed.cur_track = min(ed.cur_track + n, len(pr.tracks) - 1)
		select_nearest(ed)
	}
	if n := p.key_count(ui, p.KEY_UP); n > 0 {
		ed.cur_track = max(ed.cur_track - n, 0)
		select_nearest(ed)
	}
	if p.shortcut(ui, '[', {}) {
		step_selection(ed, -1)
	}
	if p.shortcut(ui, ']', {}) {
		step_selection(ed, +1)
	}

	// --- clip operations -------------------------------------------------
	if p.shortcut(ui, 's', {}) {
		// The mark has to come first, and a refused split must not leave an
		// empty step behind, so the state is snapshotted and the step dropped
		// again when nothing happened.
		fresh := undo_mark(ed, .Split, "split")
		if id, ok := split_at(pr, ed.cur_track, ed.playhead); ok {
			edited(ed)
			status(ed, ui, fmt.tprintf("split at %s", timecode(ed.playhead, pr.out_fps)))
			_ = id
		} else {
			if fresh {
				undo_drop(ed)
			}
			status(ed, ui, "nothing to split under the playhead")
		}
	}
	if p.shortcut(ui, 'd', {}) {
		if t, i, ok := sel_find(ed); ok {
			undo_mark(ed, .Ripple, "ripple delete")
			ripple_delete(pr, t, i)
			ed.sel = -1
			edited(ed)
			status(ed, ui, "ripple delete: the gap closed")
		}
	}
	if p.key_pressed(ui, p.KEY_DELETE, false) || p.key_pressed(ui, p.KEY_BACKSPACE, false) {
		if t, i, ok := sel_find(ed); ok {
			undo_mark(ed, .Lift, "delete")
			lift_delete(pr, t, i)
			ed.sel = -1
			edited(ed)
			status(ed, ui, "deleted, gap left")
		}
	}
	if t, i, ok := sel_find(ed); ok {
		moved := false
		// `trim_in`/`trim_out` return the delta they actually applied, which is
		// zero once the clip is against the end of its source or the timeline
		// origin. A clamped trim is not an edit, so the step it marked is
		// dropped — but only if the mark opened a new one.
		if p.shortcut(ui, 'q', {}, true) {
			moved |= trimmed(ed, .Trim_In, true, t, i, -NUDGE)
		}
		if p.shortcut(ui, 'w', {}, true) {
			moved |= trimmed(ed, .Trim_In, true, t, i, NUDGE)
		}
		if p.shortcut(ui, 'e', {}, true) {
			moved |= trimmed(ed, .Trim_Out, false, t, i, -NUDGE)
		}
		if p.shortcut(ui, 'r', {}, true) {
			moved |= trimmed(ed, .Trim_Out, false, t, i, NUDGE)
		}
		if moved {
			edited(ed)
			_, ci := find_clip(pr, ed.sel)
			if ci >= 0 {
				c := pr.tracks[t].clips[ci]
				status(
					ed,
					ui,
					fmt.tprintf(
						"trim: in %.2fs out %.2fs, %.2fs long",
						c.src_in,
						c.src_out,
						clip_len(c),
					),
				)
			}
		}
	}
	if t, i, ok := sel_find(ed); ok {
		d := f64(0)
		if p.shortcut(ui, 'h', {}, true) {
			d = -NUDGE
		}
		if p.shortcut(ui, 'l', {}, true) {
			d = NUDGE
		}
		if d != 0 {
			c0 := pr.tracks[t].clips[i]
			fresh := undo_mark(ed, .Move, "move a clip", ed.sel)
			c := c0
			want := c.start + d
			snapped, hit := snap_time(pr, want, ed.zoom, ed.playhead, c.id)
			if hit {
				want = snapped
			}
			move_clip(pr, t, i, t, want)
			if _, ci := find_clip(pr, c0.id); ci >= 0 && pr.tracks[t].clips[ci].start == c0.start {
				if fresh {
					undo_drop(ed)
				}
			}
			edited(ed)
			status(
				ed,
				ui,
				hit ? fmt.tprintf("snapped to %s", timecode(want, pr.out_fps)) : fmt.tprintf("moved to %s", timecode(want, pr.out_fps)),
			)
		}
	}
	if p.shortcut(ui, 'm', {}) {
		if t, i, ok := sel_find(ed); ok {
			to := next_track_of_kind(pr, t)
			if to != t {
				undo_mark(ed, .Retrack, "move to another track", ed.sel)
				nt, _ := move_clip(pr, t, i, to, pr.tracks[t].clips[i].start)
				ed.cur_track = nt
				edited(ed)
				status(ed, ui, fmt.tprintf("moved to track %s", pr.tracks[nt].name))
			}
		}
	}
	if p.shortcut(ui, 'x', {}) {
		if t, i, ok := sel_find(ed); ok {
			undo_mark(ed, .Dissolve, "toggle the dissolve", ed.sel)
			toggle_dissolve(pr, t, i)
			edited(ed)
			c := pr.tracks[t].clips[i]
			status(
				ed,
				ui,
				c.trans == .Dissolve ? fmt.tprintf("cross-dissolve, %.2fs", c.xfade) : "hard cut",
			)
		}
	}
	if p.shortcut(ui, 'g', {}, true) || p.shortcut(ui, 'G', {.Shift}, true) {
		if t, i, ok := sel_find(ed); ok {
			up := p.shortcut(ui, 'G', {.Shift}, true)
			was := pr.tracks[t].clips[i].gain
			fresh := undo_mark(ed, .Gain, "change the gain", ed.sel)
			c := &pr.tracks[t].clips[i]
			c.gain = clamp(c.gain + (up ? 0.1 : -0.1), 0, 4)
			if c.gain == was && fresh {
				undo_drop(ed)
			}
			// The gain is in the mix graph, so the mixer has to rebuild for
			// the change to be heard — but the frames are untouched.
			edited_audio(ed)
			status(ed, ui, fmt.tprintf("gain %.0f%%", c.gain * 100))
		}
	}

	// --- tracks ----------------------------------------------------------
	if p.shortcut(ui, 'u', {}) {
		undo_mark(ed, .Track_Flags, "mute a track", ed.cur_track)
		pr.tracks[ed.cur_track].mute = !pr.tracks[ed.cur_track].mute
		edited(ed)
		status(
			ed,
			ui,
			fmt.tprintf(
				"%s %s",
				pr.tracks[ed.cur_track].name,
				pr.tracks[ed.cur_track].mute ? "muted" : "unmuted",
			),
		)
	}
	if p.shortcut(ui, 'o', {}) {
		undo_mark(ed, .Track_Flags, "solo a track", ed.cur_track)
		pr.tracks[ed.cur_track].solo = !pr.tracks[ed.cur_track].solo
		edited(ed)
		status(
			ed,
			ui,
			fmt.tprintf(
				"%s %s",
				pr.tracks[ed.cur_track].name,
				pr.tracks[ed.cur_track].solo ? "solo" : "unsolo",
			),
		)
	}

	// --- view --------------------------------------------------------------
	if p.shortcut(ui, '=', {}, true) || p.shortcut(ui, '+', {.Shift}, true) {
		zoom_about(ed, 1.25)
	}
	if p.shortcut(ui, '-', {}, true) {
		zoom_about(ed, 1 / 1.25)
	}
	if p.shortcut(ui, 'f', {}) {
		ed.pv.quality = ed.pv.quality == .Draft ? .Fine : .Draft
		cache_drop_all(&ed.pv)
		status(
			ed,
			ui,
			fmt.tprintf("preview at %dpx wide", preview_width(ed.pv.quality)),
		)
	}

	// --- titles and captions -----------------------------------------------
	if p.shortcut(ui, 't', {}) {
		undo_mark(ed, .Title_Add, "add a title")
		v := track_of_kind(pr, .Video, 0)
		id := insert_title(pr, v, ed.playhead, 2.5, buf_str(&ed.buf_title))
		ed.sel = id
		ed.cur_track = v
		edited(ed)
		status(ed, ui, "title added on the top video track")
	}
	if p.shortcut(ui, 'c', {}) {
		path := buf_str(&ed.buf_caption)
		fresh := undo_mark(ed, .Captions, "import captions")
		n, f, ok := load_captions(pr, path)
		if ok {
			edited(ed)
			status(ed, ui, fmt.tprintf("%d cues from %v: %s", n, f, base_name(path)))
		} else {
			if fresh {
				undo_drop(ed)
			}
			status(ed, ui, fmt.tprintf("could not read captions from %s", path))
		}
	}
	if p.shortcut(ui, ',', {}, true) {
		undo_mark(ed, .Caption_Nudge, "nudge the captions")
		pr.caption_offset -= 0.1
		status(ed, ui, fmt.tprintf("caption offset %+.1fs", pr.caption_offset))
	}
	if p.shortcut(ui, '.', {}, true) {
		undo_mark(ed, .Caption_Nudge, "nudge the captions")
		pr.caption_offset += 0.1
		status(ed, ui, fmt.tprintf("caption offset %+.1fs", pr.caption_offset))
	}

	// --- export, save, load ---------------------------------------------
	if p.shortcut(ui, 'p', {}) {
		start_export(ed, ui, .Draft)
	}
	if p.shortcut(ui, 'P', {.Shift}) {
		start_export(ed, ui, .Final)
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		path := buf_str(&ed.buf_project)
		ok := project_save(pr, path, ed.playhead, ed.zoom)
		status(ed, ui, ok ? fmt.tprintf("saved %s", path) : "save failed")
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		path := buf_str(&ed.buf_project)
		res := project_load(pr, path)
		if res.ok {
			seek_to(ed, res.playhead)
			ed.zoom = res.zoom
			ed.sel = -1
			ed.cur_track = min(ed.cur_track, len(pr.tracks) - 1)
			// Loading is not an edit; there is nothing behind it to go back to.
			undo_reset(ed)
			// Thumbnails and waveforms are derived, so rebuild them.
			for m in pr.media {
				importer_push(&ed.im, m.path)
			}
			edited(ed)
			status(ed, ui, fmt.tprintf("loaded %s", path))
		} else {
			status(ed, ui, res.err)
		}
	}
	if p.shortcut(ui, 'v', {}) {
		verify_last(ed, ui)
	}
	if p.shortcut(ui, '?', {.Shift}) || p.key_pressed(ui, p.KEY_F1, false) {
		ed.mode = ed.mode == .Help ? .Normal : .Help
	}
}

// trimmed marks, trims, and unmarks again when the trim was fully clamped.
// Both trim procedures report the delta they applied, so "did anything happen"
// is an answer the model already has rather than something to guess at.
trimmed :: proc(ed: ^Editor, kind: Undo_Kind, in_point: bool, t, i: int, delta: f64) -> bool {
	label := in_point ? "trim the in point" : "trim the out point"
	fresh := undo_mark(ed, kind, label, ed.sel)
	d := in_point ? trim_in(&ed.pr, t, i, delta) : trim_out(&ed.pr, t, i, delta)
	if d == 0 {
		if fresh {
			undo_drop(ed)
		}
		return false
	}
	return true
}

// follow_playhead keeps the playhead on screen while the timeline plays or the
// selection jumps, scrolling by a screenful rather than tracking continuously
// so the picture does not slide under the eye on every frame.
follow_playhead :: proc(ed: ^Editor) {
	if ed.tl.w <= GUTTER {
		return
	}
	span := f64((ed.tl.w - GUTTER) / ed.zoom)
	if ed.playhead < ed.scroll {
		ed.scroll = math.max(0, ed.playhead - span * 0.2)
	} else if ed.playhead > ed.scroll + span * 0.92 {
		ed.scroll = math.max(0, ed.playhead - span * 0.2)
	}
}

zoom_about :: proc(ed: ^Editor, k: f32) {
	// Keep the playhead where it is on screen while the scale changes.
	ed.zoom = clamp(ed.zoom * k, 4, 600)
	ed.scroll = math.max(0, ed.playhead - f64((ed.tl.w - GUTTER) / ed.zoom) * 0.5)
}

select_nearest :: proc(ed: ^Editor) {
	t := &ed.pr.tracks[ed.cur_track]
	if i := clip_at(t, ed.playhead); i >= 0 {
		ed.sel = t.clips[i].id
		return
	}
	best := -1
	bestd := math.inf_f64(1)
	for c, i in t.clips {
		d := math.abs(c.start - ed.playhead)
		if d < bestd {
			bestd = d
			best = i
		}
	}
	ed.sel = best >= 0 ? t.clips[best].id : -1
}

step_selection :: proc(ed: ^Editor, dir: int) {
	t := &ed.pr.tracks[ed.cur_track]
	if len(t.clips) == 0 {
		ed.sel = -1
		return
	}
	at := -1
	for c, i in t.clips {
		if c.id == ed.sel {
			at = i
			break
		}
	}
	next := at < 0 ? (dir > 0 ? 0 : len(t.clips) - 1) : clamp(at + dir, 0, len(t.clips) - 1)
	ed.sel = t.clips[next].id
	seek_to(ed, t.clips[next].start)
}

next_track_of_kind :: proc(pr: ^Project, from: int) -> int {
	kind := pr.tracks[from].kind
	n := len(pr.tracks)
	for d in 1 ..< n + 1 {
		i := (from + d) % n
		if pr.tracks[i].kind == kind {
			return i
		}
	}
	return from
}

// toggle_dissolve turns a cut into a cross-dissolve by *overlapping* the clip
// with the one before it, which is what makes the fade have something to fade
// over. Turning it back off pulls the clip back to the cut.
// toggle_dissolve turns a clip's join into a cross-dissolve or back into a
// cut. It touches only the project, so `videoedit dissolve` calls it too.
toggle_dissolve :: proc(pr: ^Project, track, idx: int) {
	t := &pr.tracks[track]
	c := &t.clips[idx]
	if c.trans == .Dissolve {
		c.trans = .Cut
		c.start += c.xfade
		track_sort(t)
		return
	}
	if idx == 0 {
		// Nothing underneath: a dissolve from black is still a dissolve.
		c.trans = .Dissolve
		return
	}
	prev := t.clips[idx - 1]
	d := math.min(c.xfade, math.min(clip_len(prev), clip_len(c^)) * 0.5)
	if d < 0.05 {
		return
	}
	c.xfade = d
	c.trans = .Dissolve
	c.start = math.max(0, clip_end(prev) - d)
	track_sort(t)
}

// place_media puts the selected bin item on the timeline: its video on the
// current video track (or the first one) and its audio alongside on an audio
// track, which is what dragging a clip in from a bin normally does.
place_media :: proc(ed: ^Editor, ui: ^p.Ctx, at: f64) {
	pr := &ed.pr
	if len(pr.media) == 0 {
		status(ed, ui, "the media bin is empty")
		return
	}
	mi := clamp(ed.bin_sel, 0, len(pr.media) - 1)
	m := pr.media[mi]
	vt := pr.tracks[ed.cur_track].kind == .Video ? ed.cur_track : track_of_kind(pr, .Video, 1)
	pl := place_clip(pr, mi, vt, at, 0, math.min(m.duration, 4.0))
	if pl.id >= 0 {
		ed.sel = pl.id
		ed.cur_track = pl.track
	}
	edited(ed)
	status(ed, ui, fmt.tprintf("placed %s at %s", m.name, timecode(pl.at, pr.out_fps)))
}

Placed :: struct {
	id:       int, // the clip a selection should land on: the video, else the audio
	track:    int,
	video_id: int, // -1 when the media has no picture
	audio_id: int, // -1 when it has no sound
	at:       f64, // the timeline position it went to
}

// place_clip is placing one bin item, with no window attached: the video part
// on track `vt`, the sound on the first audio track at the same position, and
// `at < 0` meaning "after the last clip on vt". The window's `a`/`n` keys and
// `videoedit add` both come through here, so a clip placed either way has the
// same shape on the timeline.
place_clip :: proc(pr: ^Project, mi, vt: int, at, src_in, src_out: f64) -> Placed {
	out := Placed{id = -1, track = vt, video_id = -1, audio_id = -1}
	m := pr.media[mi]
	at_v := at
	if at < 0 {
		at_v = 0
		for c in pr.tracks[vt].clips {
			at_v = math.max(at_v, clip_end(c))
		}
	}
	out.at = at_v
	if m.has_video {
		out.video_id = insert_clip(pr, vt, mi, at_v, src_in, src_out)
		out.id = out.video_id
	}
	if m.has_audio {
		a := track_of_kind(pr, .Audio, 0)
		out.audio_id = insert_clip(pr, a, mi, at_v, src_in, src_out)
		if !m.has_video {
			out.id = out.audio_id
			out.track = a
		}
	}
	return out
}

start_export :: proc(ed: ^Editor, ui: ^p.Ctx, q: Export_Quality) {
	out := strings.clone(buf_str(&ed.buf_export), context.temp_allocator)
	if q == .Draft && strings.has_suffix(out, ".mp4") {
		out = fmt.tprintf("%s-draft.mp4", out[:len(out) - 4])
	}
	w, h, err := export_submit(&ed.pr, &ed.ex, out, q)
	if err != "" {
		status(ed, ui, err)
		return
	}
	ed.verified = false
	status(ed, ui, fmt.tprintf("exporting %dx%d to %s", w, h, base_name(out)))
}

// export_submit builds the ffmpeg plan for the timeline and hands it to the
// exporter thread. The window's `p`/`P` and `videoedit export` both start an
// export here; the command line then waits on `exporter_status` where the
// window draws a progress bar from it.
export_submit :: proc(pr: ^Project, ex: ^Exporter, out: string, q: Export_Quality) -> (w, h: int, err: string) {
	plan := build_export(pr, Export_Settings{quality = q, out_path = out})
	if plan.err != "" {
		err = strings.clone(plan.err, context.temp_allocator)
		export_plan_destroy(&plan)
		return 0, 0, err
	}
	w, h = plan.width, plan.height
	if !exporter_submit(ex, plan, out) {
		export_plan_destroy(&plan)
		return 0, 0, "an export is already running"
	}
	return w, h, ""
}

// verify_last reads the finished file back with ffprobe and pulls a frame out
// of it, which is the only way to know an export worked.
verify_last :: proc(ed: ^Editor, ui: ^p.Ctx) {
	st := exporter_status(&ed.ex)
	if st.out_path == "" {
		status(ed, ui, "nothing exported yet")
		return
	}
	delete(ed.verify.vcodec)
	delete(ed.verify.acodec)
	ed.verify = verify_output(st.out_path)
	ed.verified = true
	if ed.still_ok {
		p.image_destroy(&ed.still)
		ed.still_ok = false
	}
	if ed.verify.ok {
		ed.still, ed.still_ok = export_still(st.out_path, ed.verify.duration * 0.4)
		status(
			ed,
			ui,
			fmt.tprintf(
				"verified: %.2fs, %dx%d, %d streams (%s/%s)",
				ed.verify.duration,
				ed.verify.width,
				ed.verify.height,
				ed.verify.streams,
				ed.verify.vcodec,
				ed.verify.acodec,
			),
		)
	} else {
		status(ed, ui, "ffprobe could not read the exported file")
	}
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

EDGE_PX :: f32(7)

time_to_x :: proc(ed: ^Editor, t: f64) -> f32 {
	return ed.tl.x + GUTTER + f32(t - ed.scroll) * ed.zoom
}

x_to_time :: proc(ed: ^Editor, x: f32) -> f64 {
	return f64((x - ed.tl.x - GUTTER) / ed.zoom) + ed.scroll
}

track_y :: proc(ed: ^Editor, i: int) -> f32 {
	return ed.tl.y + RULER_H + f32(i) * TRACK_H
}

track_at_y :: proc(ed: ^Editor, y: f32) -> int {
	i := int((y - ed.tl.y - RULER_H) / TRACK_H)
	return clamp(i, 0, len(ed.pr.tracks) - 1)
}

handle_timeline_mouse :: proc(ed: ^Editor, ui: ^p.Ctx) {
	pr := &ed.pr
	m := p.mouse_pos(ui)
	inside := p.rect_contains(ed.tl, m.x, m.y)

	// Wheel: scroll, or zoom with Ctrl.
	if inside {
		w := p.wheel(ui)
		if w.y != 0 || w.x != 0 {
			if .Ctrl in ui.input.mods {
				zoom_about(ed, w.y > 0 ? 1.15 : 1 / 1.15)
			} else {
				ed.scroll = math.max(0, ed.scroll - f64(w.y + w.x) * 0.5)
			}
			p.redraw(ui)
		}
	}

	if ui.input.pressed[.Left] && inside {
		ed.snap_show = false
		if m.y < ed.tl.y + RULER_H {
			ed.drag = .Scrub
			seek_to(ed, x_to_time(ed, m.x))
		} else if m.x < ed.tl.x + GUTTER {
			// The name gutter: the M and S buttons, at the rectangles
			// draw_timeline paints them in.
			ti := track_at_y(ed, m.y)
			ry := m.y - track_y(ed, ti)
			if ti < len(pr.tracks) && ry >= 26 && ry <= 41 {
				rx := m.x - ed.tl.x
				switch {
				case rx >= 8 && rx <= 26:
					undo_mark(ed, .Track_Flags, "mute a track", ti)
					pr.tracks[ti].mute = !pr.tracks[ti].mute
					edited(ed)
				case rx >= 30 && rx <= 48:
					undo_mark(ed, .Track_Flags, "solo a track", ti)
					pr.tracks[ti].solo = !pr.tracks[ti].solo
					edited(ed)
				}
			}
			ed.cur_track = ti
		} else {
			ti := track_at_y(ed, m.y)
			if ti < len(pr.tracks) && m.x > ed.tl.x + GUTTER {
				t := &pr.tracks[ti]
				tm := x_to_time(ed, m.x)
				hit := -1
				for c, i in t.clips {
					if clip_covers(c, tm) {
						hit = i
						break
					}
				}
				if hit >= 0 {
					c := t.clips[hit]
					ed.sel = c.id
					ed.cur_track = ti
					ed.drag_id = c.id
					ed.drag_track = ti
					x0 := time_to_x(ed, c.start)
					x1 := time_to_x(ed, clip_end(c))
					switch {
					case m.x - x0 < EDGE_PX:
						ed.drag = .Trim_In
					case x1 - m.x < EDGE_PX:
						ed.drag = .Trim_Out
					case:
						ed.drag = .Move
						ed.drag_grab = tm - c.start
					}
				} else {
					ed.drag = .Scrub
					seek_to(ed, tm)
					ed.cur_track = ti
				}
			}
		}
	}

	if ed.drag != .None && ui.input.down[.Left] {
		tm := x_to_time(ed, m.x)
		switch ed.drag {
		case .None:
		case .Scrub:
			seek_to(ed, tm)
		case .Move:
			t, i := find_clip(pr, ed.drag_id)
			if t >= 0 {
				// One mark for the whole gesture: `undo_mark` folds every
				// frame of the drag into the step the first one opened,
				// because the kind, the clip and the time window all match.
				// `undo_break` on release is what ends it.
				undo_mark(ed, .Move, "move a clip", ed.drag_id)
				want := math.max(0, tm - ed.drag_grab)
				snapped, hit := snap_time(pr, want, ed.zoom, ed.playhead, ed.drag_id)
				if hit {
					want = snapped
				}
				ed.snap_at, ed.snap_show = want, hit
				to := track_at_y(ed, m.y)
				if pr.tracks[to].kind != pr.tracks[t].kind {
					to = t
				}
				nt, _ := move_clip(pr, t, i, to, want)
				ed.cur_track = nt
				ed.drag_track = nt
				edited(ed)
			}
		case .Trim_In:
			t, i := find_clip(pr, ed.drag_id)
			if t >= 0 {
				_ = undo_mark(ed, .Trim_In, "trim the in point", ed.drag_id)
				c := pr.tracks[t].clips[i]
				want := tm
				snapped, hit := snap_time(pr, want, ed.zoom, ed.playhead, ed.drag_id)
				if hit {
					want = snapped
				}
				ed.snap_at, ed.snap_show = want, hit
				trim_in(pr, t, i, want - c.start)
				edited(ed)
			}
		case .Trim_Out:
			t, i := find_clip(pr, ed.drag_id)
			if t >= 0 {
				_ = undo_mark(ed, .Trim_Out, "trim the out point", ed.drag_id)
				c := pr.tracks[t].clips[i]
				want := tm
				snapped, hit := snap_time(pr, want, ed.zoom, ed.playhead, ed.drag_id)
				if hit {
					want = snapped
				}
				ed.snap_at, ed.snap_show = want, hit
				trim_out(pr, t, i, want - clip_end(c))
				edited(ed)
			}
		}
		p.redraw(ui)
	}

	if ui.input.released[.Left] {
		if ed.drag != .None {
			// The gesture is over: a second drag of the same clip is a second
			// undo step however quickly it follows this one.
			undo_break(ed)
		}
		if ed.drag == .Scrub && ed.playing {
			// Starting the mixer again at the new position is the flush.
			ed.seek_req = true
		}
		ed.drag = .None
		ed.snap_show = false
	}
}
