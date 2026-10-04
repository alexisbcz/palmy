package main

// What ffprobe knows about a file, turned into a struct.
//
// `ffprobe -print_format json -show_format -show_streams` is the only honest
// way to learn a container's duration, resolution and frame rate without
// decoding it, and it is fast enough (a few milliseconds) to run on open.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

Media :: struct {
	path:        string,
	name:        string,
	ok:          bool,
	err:         string,

	duration:    f64,
	size:        i64,
	bitrate:     i64,
	container:   string,

	has_video:   bool,
	vcodec:      string,
	width:       int,
	height:      int,
	fps:         f64,
	frames:      int,
	pix_fmt:     string,
	vbitrate:    i64,

	has_audio:   bool,
	acodec:      string,
	channels:    int,
	sample_rate: int,
	abitrate:    i64,

	title:       string,
	artist:      string,
	album:       string,
	date:        string,
	has_cover:   bool,
}

// probe_file runs ffprobe and reads the answer.
probe_file :: proc(path: string) -> Media {
	out, ok := kit.run(
		{
			"ffprobe",
			"-v",
			"quiet",
			"-print_format",
			"json",
			"-show_format",
			"-show_streams",
			path,
		},
		context.temp_allocator,
	)
	if !ok || out == "" {
		return Media {
			path = strings.clone(path),
			name = strings.clone(base_of(path)),
			err = "ffprobe could not read this file",
		}
	}
	return parse_probe(out, path)
}

// parse_probe is the half that does not touch the filesystem, so the shape of
// ffprobe's JSON can be tested without running it.
parse_probe :: proc(out: string, path: string) -> Media {
	m := Media {
		path = strings.clone(path),
		name = strings.clone(base_of(path)),
	}
	root, jerr := json.parse_string(out, .JSON, false, context.temp_allocator)
	if jerr != .None {
		m.err = "ffprobe returned something that is not JSON"
		return m
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		m.err = "ffprobe returned an unexpected shape"
		return m
	}

	if f, has := obj["format"]; has {
		if fo, o := f.(json.Object); o {
			m.duration = jnum(fo["duration"])
			m.size = i64(jnum(fo["size"]))
			m.bitrate = i64(jnum(fo["bit_rate"]))
			m.container = jstr(fo["format_name"])
			if t, th := fo["tags"]; th {
				if to, o2 := t.(json.Object); o2 {
					m.title = tag(to, "title", "TITLE")
					m.artist = tag(to, "artist", "ARTIST")
					m.album = tag(to, "album", "ALBUM")
					m.date = tag(to, "date", "DATE")
				}
			}
		}
	}

	if s, has := obj["streams"]; has {
		if arr, a := s.(json.Array); a {
			for v in arr {
				so, o := v.(json.Object)
				if !o {
					continue
				}
				kind := jstr(so["codec_type"])
				disp := so["disposition"]
				attached := false
				if d, dh := disp.(json.Object); dh {
					attached = jnum(d["attached_pic"]) > 0
				}
				switch kind {
				case "video":
					if attached {
						// A cover image riding in an audio file is not video.
						m.has_cover = true
						continue
					}
					if m.has_video {
						continue
					}
					m.has_video = true
					m.vcodec = jstr(so["codec_name"])
					m.width = int(jnum(so["width"]))
					m.height = int(jnum(so["height"]))
					m.pix_fmt = jstr(so["pix_fmt"])
					m.vbitrate = i64(jnum(so["bit_rate"]))
					m.frames = int(jnum(so["nb_frames"]))
					m.fps = parse_rate(jstr(so["avg_frame_rate"]))
					if m.fps <= 0 {
						m.fps = parse_rate(jstr(so["r_frame_rate"]))
					}
					if d := jnum(so["duration"]); d > m.duration {
						m.duration = d
					}
				case "audio":
					if m.has_audio {
						continue
					}
					m.has_audio = true
					m.acodec = jstr(so["codec_name"])
					m.channels = int(jnum(so["channels"]))
					m.sample_rate = int(jnum(so["sample_rate"]))
					m.abitrate = i64(jnum(so["bit_rate"]))
					if t, th := so["tags"]; th {
						if to, o2 := t.(json.Object); o2 {
							if m.title == "" {m.title = tag(to, "title", "TITLE")}
							if m.artist == "" {m.artist = tag(to, "artist", "ARTIST")}
							if m.album == "" {m.album = tag(to, "album", "ALBUM")}
						}
					}
					if d := jnum(so["duration"]); d > m.duration {
						m.duration = d
					}
				}
			}
		}
	}

	if !m.has_video && !m.has_audio {
		m.err = "no audio or video stream in this file"
		return m
	}
	if m.fps <= 0 || m.fps > 1000 {
		m.fps = 25
	}
	m.ok = true

	// Clone out of the temp arena: everything above points into the parse.
	m.container = strings.clone(m.container)
	m.vcodec = strings.clone(m.vcodec)
	m.acodec = strings.clone(m.acodec)
	m.pix_fmt = strings.clone(m.pix_fmt)
	m.title = strings.clone(m.title)
	m.artist = strings.clone(m.artist)
	m.album = strings.clone(m.album)
	m.date = strings.clone(m.date)
	return m
}

@(private)
tag :: proc(o: json.Object, names: ..string) -> string {
	for n in names {
		if v, has := o[n]; has {
			if s, ok := v.(json.String); ok && s != "" {
				return string(s)
			}
		}
	}
	// Tags arrive in whatever case the muxer felt like, so fall back to a
	// case-insensitive sweep rather than missing a title over an upper T.
	for n in names {
		for k, v in o {
			if strings.equal_fold(k, n) {
				if s, ok := v.(json.String); ok && s != "" {
					return string(s)
				}
			}
		}
	}
	return ""
}

// jnum reads a number that ffprobe may have written as a JSON string.
@(private)
jnum :: proc(v: json.Value) -> f64 {
	switch t in v {
	case json.Float:
		return f64(t)
	case json.Integer:
		return f64(t)
	case json.String:
		f, ok := strconv.parse_f64(string(t))
		return ok ? f : 0
	case json.Boolean:
		return t ? 1 : 0
	case json.Null, json.Array, json.Object:
		return 0
	}
	return 0
}

@(private)
jstr :: proc(v: json.Value) -> string {
	if s, ok := v.(json.String); ok {
		return string(s)
	}
	return ""
}

// parse_rate reads ffprobe's "30000/1001".
@(private)
parse_rate :: proc(s: string) -> f64 {
	if s == "" || s == "0/0" {
		return 0
	}
	if i := strings.index_byte(s, '/'); i > 0 {
		n, ok1 := strconv.parse_f64(s[:i])
		d, ok2 := strconv.parse_f64(s[i + 1:])
		if ok1 && ok2 && d != 0 {
			return n / d
		}
		return 0
	}
	f, ok := strconv.parse_f64(s)
	return ok ? f : 0
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

timecode :: proc(t: f64) -> string {
	if t < 0 {
		return "-:--"
	}
	total := int(t)
	h := total / 3600
	m := (total / 60) % 60
	s := total % 60
	if h > 0 {
		return fmt.tprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.tprintf("%d:%02d", m, s)
}

timecode_ms :: proc(t: f64) -> string {
	if t < 0 {
		t := 0
		_ = t
		return "0:00.000"
	}
	total := int(t)
	h := total / 3600
	m := (total / 60) % 60
	s := total % 60
	ms := int((t - f64(total)) * 1000)
	if h > 0 {
		return fmt.tprintf("%d:%02d:%02d.%03d", h, m, s, ms)
	}
	return fmt.tprintf("%d:%02d.%03d", m, s, ms)
}

human_bytes :: proc(n: i64) -> string {
	f := f64(n)
	switch {
	case n < 1024:
		return fmt.tprintf("%d B", n)
	case n < 1024 * 1024:
		return fmt.tprintf("%.1f KB", f / 1024)
	case n < 1024 * 1024 * 1024:
		return fmt.tprintf("%.1f MB", f / (1024 * 1024))
	}
	return fmt.tprintf("%.2f GB", f / (1024 * 1024 * 1024))
}

human_rate :: proc(bps: i64) -> string {
	if bps <= 0 {
		return "—"
	}
	if bps < 1_000_000 {
		return fmt.tprintf("%d kb/s", bps / 1000)
	}
	return fmt.tprintf("%.1f Mb/s", f64(bps) / 1e6)
}

base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	return strings.has_prefix(path, "/") ? "/" : "."
}

os_home :: proc() -> (string, bool) {
	home, err := os.user_home_dir(context.temp_allocator)
	return home, err == nil
}
