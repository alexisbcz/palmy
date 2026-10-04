package main

// Project files.
//
// One line per thing, fields separated by single spaces, and whatever can
// contain a space — a path, a title, a caption — is last on its line so the
// rest parses by splitting. Newlines inside a caption become `\n` and a
// literal backslash becomes `\\`; nothing else is escaped, which is enough
// because nothing else is ambiguous.
//
// Media is referenced by path, never copied, and clips reference media by
// their index in the file, which is rebuilt on load. The format round-trips
// exactly: the self-test saves a timeline, loads it back and compares every
// field.
//
// This serialiser is also the undo representation (see undo.odin). That is the
// reason the file is split the way it is: `project_serialise` produces the
// string and `project_save` only writes it, `project_parse` consumes a string
// and `project_load` only reads it. One format, one parser, so an undo entry
// cannot drift away from what a saved project means — and
// `serialise(parse(x)) == x` byte for byte, which is what the undo round-trip
// test asserts over a long random sequence of edits.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

PROJECT_MAGIC :: "videoedit"
PROJECT_VERSION :: 1

esc :: proc(s: string, alloc := context.temp_allocator) -> string {
	sb := strings.builder_make(alloc)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
		case:
			strings.write_byte(&sb, s[i])
		}
	}
	if strings.builder_len(sb) == 0 {
		strings.write_string(&sb, "\\e") // an empty field still needs a token
	}
	return strings.to_string(sb)
}

unesc :: proc(s: string, alloc := context.allocator) -> string {
	if s == "\\e" {
		return strings.clone("", alloc)
	}
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n')
			case '\\':
				strings.write_byte(&sb, '\\')
			case 'e':
			case:
				strings.write_byte(&sb, s[i + 1])
			}
			i += 2
			continue
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.clone(strings.to_string(sb), alloc)
}

// project_serialise is the whole document as one string. Nothing else in the
// program may write this format.
project_serialise :: proc(
	pr: ^Project,
	playhead: f64,
	zoom: f32,
	alloc := context.allocator,
) -> string {
	sb := strings.builder_make(alloc)
	fmt.sbprintf(&sb, "%s %d\n", PROJECT_MAGIC, PROJECT_VERSION)
	fmt.sbprintf(&sb, "out %d %d %.6f\n", pr.out_w, pr.out_h, pr.out_fps)
	fmt.sbprintf(&sb, "view %.6f %.6f\n", playhead, f64(zoom))
	for m in pr.media {
		fmt.sbprintf(
			&sb,
			"media %.6f %d %d %.6f %s\n",
			m.duration,
			m.width,
			m.height,
			m.fps,
			esc(m.path),
		)
	}
	for &t in pr.tracks {
		fmt.sbprintf(
			&sb,
			"track %d %d %d %s\n",
			int(t.kind),
			t.mute ? 1 : 0,
			t.solo ? 1 : 0,
			esc(t.name),
		)
		for c in t.clips {
			fmt.sbprintf(
				&sb,
				"clip %d %.6f %.6f %.6f %.6f %d %.6f %d %d %.6f %.6f %s\n",
				c.media,
				c.start,
				c.src_in,
				c.src_out,
				f64(c.gain),
				int(c.trans),
				c.xfade,
				c.font_size,
				int(c.color),
				f64(c.pos_x),
				f64(c.pos_y),
				esc(c.title),
			)
		}
	}
	if len(pr.captions) > 0 {
		fmt.sbprintf(&sb, "captions %.6f %s\n", pr.caption_offset, esc(pr.caption_src))
		for c in pr.captions {
			fmt.sbprintf(&sb, "cue %.6f %.6f %s\n", c.start, c.end, esc(c.text))
		}
	}
	return strings.to_string(sb)
}

project_save :: proc(pr: ^Project, path: string, playhead: f64, zoom: f32) -> bool {
	body := project_serialise(pr, playhead, zoom, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)body) == nil
}

Project_Load :: struct {
	playhead: f64,
	zoom:     f32,
	ok:       bool,
	err:      string,
}

// project_load replaces everything in `pr` with the project on disk.
project_load :: proc(pr: ^Project, path: string) -> Project_Load {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {err = "cannot read the project file"}
	}
	return project_parse(pr, string(data), false)
}

// project_parse replaces the document in `pr` with the one the string
// describes. It is the only parser for this format, and it is what an undo
// restores through.
//
// Media rows are *adopted*, not rebuilt. A row carries a thumbnail, a waveform
// and the codec names, none of which are in the format — they are derived data
// — so a row whose path the string already mentions is moved across whole.
// That is what makes restoring a snapshot free: an undo does not throw away
// every thumbnail in the bin and then re-probe four files to get them back.
//
// `keep_extra` decides what happens to rows the string does not mention. An
// undo keeps them (`true`): an import is not an edit to the document, it is a
// resource arriving, and undoing a split must not empty the media bin. Because
// the string's own rows are written in index order they still land at indices
// 0..n-1, so no clip's `media` index moves and the kept rows simply sit above
// them, referenced by nothing. Loading a project from disk drops them
// (`false`), because then the file is the whole truth.
project_parse :: proc(pr: ^Project, body: string, keep_extra: bool) -> Project_Load {
	lines := strings.split_lines(body, context.temp_allocator)
	if len(lines) == 0 || !strings.has_prefix(lines[0], PROJECT_MAGIC) {
		return {err = "not a videoedit project"}
	}

	// Lift the media rows out before anything is freed, so they can be
	// adopted below rather than destroyed and re-probed.
	old := pr.media
	pr.media = nil
	taken := make([]bool, len(old), context.temp_allocator)

	project_destroy(pr) // tracks and captions; pr.media is already nil
	pr^ = {}
	pr.next_id = 1
	pr.out_w, pr.out_h, pr.out_fps = 1280, 720, 30
	out := Project_Load {
		zoom = 60,
		ok   = true,
	}
	cur_track := -1

	for li in 1 ..< len(lines) {
		line := strings.trim_space(lines[li])
		if line == "" {
			continue
		}
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 {
			continue
		}
		switch f[0] {
		case "out":
			if len(f) >= 4 {
				pr.out_w, _ = strconv.parse_int(f[1], 10)
				pr.out_h, _ = strconv.parse_int(f[2], 10)
				pr.out_fps, _ = strconv.parse_f64(f[3])
			}
		case "view":
			if len(f) >= 3 {
				out.playhead, _ = strconv.parse_f64(f[1])
				z, _ := strconv.parse_f64(f[2])
				out.zoom = f32(z)
			}
		case "media":
			if len(f) < 6 {
				continue
			}
			path := unesc(tail_field(line, 5), context.temp_allocator)
			if m, ok := adopt_media(old[:], taken, path); ok {
				append(&pr.media, m)
				continue
			}
			m := Media{}
			m.duration, _ = strconv.parse_f64(f[1])
			m.width, _ = strconv.parse_int(f[2], 10)
			m.height, _ = strconv.parse_int(f[3], 10)
			m.fps, _ = strconv.parse_f64(f[4])
			m.path = strings.clone(path)
			m.name = strings.clone(base_name(m.path))
			m.has_video = m.width > 0
			// `probed` stays false: the thumbnail, the waveform and the codec
			// names are rebuilt by pushing the path back through the importer.
			append(&pr.media, m)
		case "track":
			if len(f) < 5 {
				continue
			}
			kind, _ := strconv.parse_int(f[1], 10)
			t := Track {
				kind = Track_Kind(clamp(kind, 0, 1)),
				mute = f[2] == "1",
				solo = f[3] == "1",
				name = unesc(tail_field(line, 4)),
			}
			append(&pr.tracks, t)
			cur_track = len(pr.tracks) - 1
		case "clip":
			if cur_track < 0 || len(f) < 13 {
				continue
			}
			c := Clip{}
			c.id = pr.next_id
			pr.next_id += 1
			c.media, _ = strconv.parse_int(f[1], 10)
			c.start, _ = strconv.parse_f64(f[2])
			c.src_in, _ = strconv.parse_f64(f[3])
			c.src_out, _ = strconv.parse_f64(f[4])
			g, _ := strconv.parse_f64(f[5])
			c.gain = f32(g)
			tr, _ := strconv.parse_int(f[6], 10)
			c.trans = Transition(clamp(tr, 0, 1))
			c.xfade, _ = strconv.parse_f64(f[7])
			c.font_size, _ = strconv.parse_int(f[8], 10)
			col, _ := strconv.parse_int(f[9], 10)
			c.color = u32(col)
			px, _ := strconv.parse_f64(f[10])
			py, _ := strconv.parse_f64(f[11])
			c.pos_x, c.pos_y = f32(px), f32(py)
			c.title = unesc(tail_field(line, 12))
			append(&pr.tracks[cur_track].clips, c)
		case "captions":
			if len(f) >= 3 {
				pr.caption_offset, _ = strconv.parse_f64(f[1])
				pr.caption_src = unesc(tail_field(line, 2))
			}
		case "cue":
			if len(f) >= 4 {
				c := Caption{}
				c.start, _ = strconv.parse_f64(f[1])
				c.end, _ = strconv.parse_f64(f[2])
				c.text = unesc(tail_field(line, 3))
				append(&pr.captions, c)
			}
		}
	}

	// Whatever the string did not claim.
	for i in 0 ..< len(old) {
		if taken[i] {
			continue
		}
		if keep_extra {
			append(&pr.media, old[i])
		} else {
			m := old[i]
			media_destroy(&m)
		}
	}
	delete(old)

	if len(pr.tracks) == 0 {
		project_init(pr)
	}
	for &t in pr.tracks {
		track_sort(&t)
	}
	return out
}

// adopt_media hands over the first unclaimed row with this path, derived data
// and all. The caller owns it from here; the row is marked so two media lines
// naming the same file cannot both take it.
@(private = "file")
adopt_media :: proc(old: []Media, taken: []bool, path: string) -> (Media, bool) {
	for i in 0 ..< len(old) {
		if taken[i] || old[i].path != path {
			continue
		}
		taken[i] = true
		return old[i], true
	}
	return {}, false
}

// tail_field returns everything after the first `n` whitespace-separated
// tokens, verbatim. `strings.fields` plus a re-join collapses a run of spaces,
// which silently rewrote any path or title that contained two in a row — and
// now that every edit round-trips through this format, a rewrite would not
// merely corrupt a save, it would corrupt an undo.
tail_field :: proc(line: string, n: int) -> string {
	i := 0
	for tok in 0 ..< n {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i += 1
		}
		for i < len(line) && line[i] != ' ' && line[i] != '\t' {
			i += 1
		}
		_ = tok
	}
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	return line[i:]
}

base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}
