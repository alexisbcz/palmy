package main

// The timeline model.
//
// Shape of the data
// -----------------
// A Project owns three flat arrays: media (what was imported), tracks (the
// lanes), and captions (one imported subtitle file, nudged by a single
// offset). A Track owns its clips in a dynamic array that is *always kept
// sorted by start time* — every mutation ends with `track_sort`. Keeping the
// invariant in one place is what makes split, ripple delete and snapping
// short enough to read.
//
// A Clip is a window onto a Media: `src_in`/`src_out` are source timestamps,
// `start` is where that window lands on the timeline. Its length on the
// timeline is therefore always `src_out - src_in`; there is no separate
// duration field that could disagree. A title clip has no media (`media = -1`)
// and uses the same start/length arithmetic so the ruler, the playhead and the
// export all treat it like anything else.
//
// Nothing in this file touches ffmpeg, the UI or the filesystem, which is why
// the self-test can assert on it directly.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import p "palmy:."

Track_Kind :: enum u8 {
	Video,
	Audio,
}

// Transition into a clip: a hard cut, or a cross-dissolve that overlaps the
// previous clip by `xfade` seconds.
Transition :: enum u8 {
	Cut,
	Dissolve,
}

Clip :: struct {
	id:         int,
	media:      int, // index into Project.media, -1 for a title
	start:      f64, // timeline seconds
	src_in:     f64, // source seconds
	src_out:    f64,
	gain:       f32, // linear, 1.0 = unity
	trans:      Transition,
	xfade:      f64, // dissolve length in seconds, used when trans == .Dissolve

	// Title fields, used when media < 0.
	title:      string,
	font_size:  int,
	color:      u32, // 0xRRGGBB
	pos_x:      f32, // 0..1 of frame width, centre of the text
	pos_y:      f32, // 0..1 of frame height
}

clip_len :: proc(c: Clip) -> f64 {
	return math.max(0, c.src_out - c.src_in)
}

clip_end :: proc(c: Clip) -> f64 {
	return c.start + clip_len(c)
}

clip_covers :: proc(c: Clip, t: f64) -> bool {
	return t >= c.start && t < clip_end(c)
}

Track :: struct {
	kind:  Track_Kind,
	name:  string,
	clips: [dynamic]Clip,
	mute:  bool,
	solo:  bool,
}

Caption :: struct {
	start, end: f64,
	text:       string,
}

Media :: struct {
	path:       string,
	name:       string,
	duration:   f64,
	width:      int,
	height:     int,
	fps:        f64,
	vcodec:     string,
	acodec:     string,
	has_video:  bool,
	has_audio:  bool,

	// Filled in by the worker thread, read only by the UI thread.
	thumb:      p.Image,
	thumb_ok:   bool,
	peaks:      []f32, // PEAKS_PER_SEC samples per second, 0..1
	probed:     bool,
}

Project :: struct {
	media:          [dynamic]Media,
	tracks:         [dynamic]Track,
	captions:       [dynamic]Caption,
	caption_src:    string, // path the captions came from
	caption_offset: f64,    // user nudge, added to every cue
	next_id:        int,
	// Render settings, stored with the project.
	out_w, out_h:   int,
	out_fps:        f64,
}

PEAKS_PER_SEC :: 100

project_init :: proc(pr: ^Project) {
	pr.next_id = 1
	pr.out_w, pr.out_h, pr.out_fps = 1280, 720, 30
	append(&pr.tracks, Track{kind = .Video, name = "V2"})
	append(&pr.tracks, Track{kind = .Video, name = "V1"})
	append(&pr.tracks, Track{kind = .Audio, name = "A1"})
	append(&pr.tracks, Track{kind = .Audio, name = "A2"})
}

project_destroy :: proc(pr: ^Project) {
	for &t in pr.tracks {
		for &c in t.clips {
			delete(c.title)
		}
		delete(t.clips)
	}
	delete(pr.tracks)
	for &m in pr.media {
		delete(m.path)
		delete(m.name)
		delete(m.vcodec)
		delete(m.acodec)
		if m.thumb.px != nil {
			p.image_destroy(&m.thumb)
		}
		delete(m.peaks)
	}
	delete(pr.media)
	for c in pr.captions {
		delete(c.text)
	}
	delete(pr.captions)
	delete(pr.caption_src)
}

// track_sort restores the by-start ordering every mutation must leave behind.
track_sort :: proc(t: ^Track) {
	slice.sort_by(t.clips[:], proc(a, b: Clip) -> bool {
		if a.start == b.start {
			return a.id < b.id
		}
		return a.start < b.start
	})
}

// clip_at finds the clip covering a time, or -1.
clip_at :: proc(t: ^Track, time: f64) -> int {
	for c, i in t.clips {
		if clip_covers(c, time) {
			return i
		}
	}
	return -1
}

find_clip :: proc(pr: ^Project, id: int) -> (track: int, idx: int) {
	for &t, ti in pr.tracks {
		for c, ci in t.clips {
			if c.id == id {
				return ti, ci
			}
		}
	}
	return -1, -1
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

// append_clip puts a media item at the end of a track, which is what importing
// and then hitting "append" does.
append_clip :: proc(pr: ^Project, track: int, media: int, src_in, src_out: f64) -> int {
	t := &pr.tracks[track]
	at := f64(0)
	for c in t.clips {
		at = math.max(at, clip_end(c))
	}
	return insert_clip(pr, track, media, at, src_in, src_out)
}

insert_clip :: proc(pr: ^Project, track: int, media: int, start, src_in, src_out: f64) -> int {
	t := &pr.tracks[track]
	id := pr.next_id
	pr.next_id += 1
	append(
		&t.clips,
		Clip {
			id = id,
			media = media,
			start = start,
			src_in = src_in,
			src_out = src_out,
			gain = 1,
			trans = .Cut,
			xfade = 0.5,
			font_size = 64,
			color = 0xffffff,
			pos_x = 0.5,
			pos_y = 0.82,
		},
	)
	track_sort(t)
	return id
}

insert_title :: proc(pr: ^Project, track: int, start, length: f64, text: string) -> int {
	id := insert_clip(pr, track, -1, start, 0, length)
	_, ci := find_clip(pr, id)
	pr.tracks[track].clips[ci].title = strings.clone(text)
	return id
}

// split_at cuts the clip under `time` into two clips that share the source.
// The second half keeps the original id so a selection survives the cut the
// way an editor expects — you cut at the playhead and keep editing the piece
// to the right.
split_at :: proc(pr: ^Project, track: int, time: f64) -> (new_id: int, ok: bool) {
	t := &pr.tracks[track]
	ci := clip_at(t, time)
	if ci < 0 {
		return 0, false
	}
	c := t.clips[ci]
	off := time - c.start
	if off <= 1e-6 || off >= clip_len(c) - 1e-6 {
		return 0, false // the cut would make a zero-length clip
	}

	left := c
	left.src_out = c.src_in + off
	left.id = pr.next_id
	pr.next_id += 1
	if c.title != "" {
		left.title = strings.clone(c.title)
	}

	right := &t.clips[ci]
	right.start = time
	right.src_in = c.src_in + off
	// A dissolve belongs to the join it was made for; a fresh cut is a cut.
	right.trans = .Cut

	append(&t.clips, left)
	track_sort(t)
	return left.id, true
}

// trim_in moves a clip's in point, in timeline seconds. The clip's start moves
// with it so the frames already on screen do not shift: that is a trim, not a
// slip. Clamped so the clip can neither invert nor run past the source.
trim_in :: proc(pr: ^Project, track, idx: int, delta: f64) -> f64 {
	c := &pr.tracks[track].clips[idx]
	d := delta
	// Cannot trim before the source start.
	d = math.max(d, -c.src_in)
	// Cannot trim past the out point (keep at least 2 frames).
	minlen := 2.0 / math.max(1.0, pr.out_fps)
	d = math.min(d, clip_len(c^) - minlen)
	// Cannot trim before the timeline origin.
	d = math.max(d, -c.start)
	if math.abs(d) < 1e-9 {
		return 0
	}
	c.src_in += d
	c.start += d
	track_sort(&pr.tracks[track])
	return d
}

// trim_out moves the out point. `start` does not change.
trim_out :: proc(pr: ^Project, track, idx: int, delta: f64) -> f64 {
	c := &pr.tracks[track].clips[idx]
	d := delta
	minlen := 2.0 / math.max(1.0, pr.out_fps)
	d = math.max(d, minlen - clip_len(c^))
	if c.media >= 0 && c.media < len(pr.media) {
		if lim := pr.media[c.media].duration; lim > 0 {
			d = math.min(d, lim - c.src_out)
		}
	}
	if math.abs(d) < 1e-9 {
		return 0
	}
	c.src_out += d
	return d
}

// move_clip slides a clip and optionally re-parents it onto another track.
// Returns the clip's new index on its (possibly new) track.
move_clip :: proc(pr: ^Project, track, idx, to_track: int, new_start: f64) -> (int, int) {
	c := pr.tracks[track].clips[idx]
	c.start = math.max(0, new_start)
	if to_track == track {
		pr.tracks[track].clips[idx].start = c.start
		track_sort(&pr.tracks[track])
		_, ci := find_clip(pr, c.id)
		return track, ci
	}
	ordered_remove(&pr.tracks[track].clips, idx)
	append(&pr.tracks[to_track].clips, c)
	track_sort(&pr.tracks[to_track])
	_, ci := find_clip(pr, c.id)
	return to_track, ci
}

// ripple_delete removes a clip and pulls everything after it on the same track
// back by its length, so the gap closes.
ripple_delete :: proc(pr: ^Project, track, idx: int) -> bool {
	t := &pr.tracks[track]
	if idx < 0 || idx >= len(t.clips) {
		return false
	}
	gone := t.clips[idx]
	span := clip_len(gone)
	at := gone.start
	delete(gone.title)
	ordered_remove(&t.clips, idx)
	for &c in t.clips {
		if c.start >= at {
			c.start = math.max(0, c.start - span)
		}
	}
	track_sort(t)
	return true
}

// lift_delete removes a clip and leaves the hole, which is the other half of
// what a delete key can mean.
lift_delete :: proc(pr: ^Project, track, idx: int) -> bool {
	t := &pr.tracks[track]
	if idx < 0 || idx >= len(t.clips) {
		return false
	}
	delete(t.clips[idx].title)
	ordered_remove(&t.clips, idx)
	return true
}

// ---------------------------------------------------------------------------
// Snapping
// ---------------------------------------------------------------------------

SNAP_PX :: f32(10)

// snap_time pulls `time` to the nearest interesting edge: the playhead, or any
// clip boundary other than the ones belonging to `exclude_id`. The tolerance
// is given in pixels and converted with the current zoom, so snapping feels
// the same whether the timeline is showing four seconds or four minutes.
snap_time :: proc(
	pr: ^Project,
	time: f64,
	px_per_sec: f32,
	playhead: f64,
	exclude_id: int = -1,
) -> (
	snapped: f64,
	hit: bool,
) {
	tol := f64(SNAP_PX / math.max(px_per_sec, 0.001))
	best := time
	bestd := tol
	found := false

	try :: proc(cand, time: f64, best: ^f64, bestd: ^f64, found: ^bool) {
		d := math.abs(cand - time)
		if d < bestd^ {
			bestd^ = d
			best^ = cand
			found^ = true
		}
	}

	try(playhead, time, &best, &bestd, &found)
	try(0, time, &best, &bestd, &found)
	for &t in pr.tracks {
		for c in t.clips {
			if c.id == exclude_id {
				continue
			}
			try(c.start, time, &best, &bestd, &found)
			try(clip_end(c), time, &best, &bestd, &found)
		}
	}
	return best, found
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

project_duration :: proc(pr: ^Project) -> f64 {
	d := f64(0)
	for &t in pr.tracks {
		for c in t.clips {
			d = math.max(d, clip_end(c))
		}
	}
	for c in pr.captions {
		d = math.max(d, c.end + pr.caption_offset)
	}
	return d
}

// any_solo decides whether the mute flags or the solo flags are in charge.
any_solo :: proc(pr: ^Project) -> bool {
	for &t in pr.tracks {
		if t.solo {
			return true
		}
	}
	return false
}

// track_enabled is the M/S state resolved: solo anywhere means only the soloed
// tracks play, otherwise mute decides. It governs video as well as audio — on
// a video track, M hides the pictures.
track_enabled :: proc(pr: ^Project, track: int) -> bool {
	t := &pr.tracks[track]
	if any_solo(pr) {
		return t.solo
	}
	return !t.mute
}

// topmost_video_at is what the preview needs: the clip the viewer would
// actually see at this instant. Tracks are ordered top to bottom, so the first
// video track with a clip wins.
topmost_video_at :: proc(pr: ^Project, time: f64) -> (track: int, idx: int) {
	for &t, ti in pr.tracks {
		if t.kind != .Video {
			continue
		}
		for c, ci in t.clips {
			if c.media >= 0 && clip_covers(c, time) {
				return ti, ci
			}
		}
	}
	return -1, -1
}

// caption_at returns the cue showing at a time, with the nudge applied.
caption_at :: proc(pr: ^Project, time: f64) -> int {
	for c, i in pr.captions {
		s := c.start + pr.caption_offset
		e := c.end + pr.caption_offset
		if time >= s && time < e {
			return i
		}
	}
	return -1
}

// timecode formats seconds as HH:MM:SS:FF at the project frame rate, which is
// the only format an editor should print a time in.
timecode :: proc(t: f64, fps: f64, alloc := context.temp_allocator) -> string {
	v := math.max(0, t)
	total := int(v)
	frames := int((v - f64(total)) * fps + 0.0001)
	return fmt.aprintf(
		"%02d:%02d:%02d:%02d",
		total / 3600,
		(total / 60) % 60,
		total % 60,
		frames,
		allocator = alloc,
	)
}
