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

project_save :: proc(pr: ^Project, path: string, playhead: f64, zoom: f32) -> bool {
	sb := strings.builder_make(context.temp_allocator)
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
	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

Project_Load :: struct {
	playhead: f64,
	zoom:     f32,
	ok:       bool,
	err:      string,
}

// project_load replaces everything in `pr`. Media is re-probed lazily by the
// caller (the thumbnails and waveforms are not in the file — they are derived
// data and cheap to rebuild).
project_load :: proc(pr: ^Project, path: string) -> Project_Load {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {err = "cannot read the project file"}
	}
	body := string(data)
	lines := strings.split_lines(body, context.temp_allocator)
	if len(lines) == 0 || !strings.has_prefix(lines[0], PROJECT_MAGIC) {
		return {err = "not a videoedit project"}
	}

	project_destroy(pr)
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
			m := Media{}
			m.duration, _ = strconv.parse_f64(f[1])
			m.width, _ = strconv.parse_int(f[2], 10)
			m.height, _ = strconv.parse_int(f[3], 10)
			m.fps, _ = strconv.parse_f64(f[4])
			m.path = unesc(join_rest(f, 5))
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
				name = unesc(join_rest(f, 4)),
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
			c.title = unesc(join_rest(f, 12))
			append(&pr.tracks[cur_track].clips, c)
		case "captions":
			if len(f) >= 3 {
				pr.caption_offset, _ = strconv.parse_f64(f[1])
				pr.caption_src = unesc(join_rest(f, 2))
			}
		case "cue":
			if len(f) >= 4 {
				c := Caption{}
				c.start, _ = strconv.parse_f64(f[1])
				c.end, _ = strconv.parse_f64(f[2])
				c.text = unesc(join_rest(f, 3))
				append(&pr.captions, c)
			}
		}
	}
	if len(pr.tracks) == 0 {
		project_init(pr)
	}
	for &t in pr.tracks {
		track_sort(&t)
	}
	return out
}

// join_rest puts the tail of a line back together, because the free-text
// field is always last and may contain spaces.
join_rest :: proc(f: []string, n: int) -> string {
	if n >= len(f) {
		return ""
	}
	return strings.join(f[n:], " ", context.temp_allocator)
}

base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}
