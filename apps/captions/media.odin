package main

// Everything that talks to ffmpeg, ffprobe and the filesystem.
//
// Nothing in here is fast enough to run inside a frame: probing is tens of
// milliseconds, extracting audio from an hour of video is seconds, and a
// burn-in is minutes. They are all called from the worker thread in jobs.odin.

import "core:fmt"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import kit "kit:."

// ---------------------------------------------------------------------------
// Working directory
// ---------------------------------------------------------------------------

// work_dir is where the 16 kHz copy, the raw PCM, the preview frames and the
// ASS handed to ffmpeg live. It is a cache: everything in it is derived from a
// file the user already has.
work_dir :: proc() -> string {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		base = fmt.tprintf("%s/.cache", home)
	}
	dir := fmt.tprintf("%s/palmy-captions", base)
	// All of it: a fresh $XDG_CACHE_HOME (a scratch one, under a test) may not
	// exist yet, and a cache that cannot be created fails every import.
	os.make_directory_all(dir)
	return dir
}

work_path :: proc(name: string, al := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", work_dir(), name, allocator = al)
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

Model :: struct {
	path:         string,
	name:         string, // ggml-base.en
	bytes:        i64,
	multilingual: bool,
}

// MODEL_DIRS is searched in order. The first two are where whisper.cpp
// front-ends on this distribution keep their weights; the rest are the
// conventional spots. Nothing is ever written to any of them.
MODEL_DIRS := [?]string {
	"$XDG_DATA_HOME/voxtype/models",
	"$HOME/.local/share/voxtype/models",
	"$HOME/.local/share/whisper/models",
	"$HOME/.local/share/whisper.cpp/models",
	"$HOME/.cache/whisper",
	"$XDG_DATA_HOME/whisper/models",
	"/usr/share/whisper.cpp/models",
	"/usr/share/whisper/models",
	"/usr/share/ggml/models",
	"/opt/whisper.cpp/models",
	"./models",
}

expand_path :: proc(p: string, al := context.temp_allocator) -> string {
	out := p
	if strings.contains(out, "$XDG_DATA_HOME") {
		v := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if v == "" {
			home := os.get_env("HOME", context.temp_allocator)
			v = fmt.tprintf("%s/.local/share", home)
		}
		out, _ = strings.replace_all(out, "$XDG_DATA_HOME", v, context.temp_allocator)
	}
	if strings.contains(out, "$XDG_CACHE_HOME") {
		v := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
		if v == "" {
			home := os.get_env("HOME", context.temp_allocator)
			v = fmt.tprintf("%s/.cache", home)
		}
		out, _ = strings.replace_all(out, "$XDG_CACHE_HOME", v, context.temp_allocator)
	}
	if strings.contains(out, "$HOME") {
		v := os.get_env("HOME", context.temp_allocator)
		out, _ = strings.replace_all(out, "$HOME", v, context.temp_allocator)
	}
	return strings.clone(out, al)
}

// find_models walks the candidate directories and returns every `ggml-*.bin`
// that is not a voice-activity model. A speech model under 20 MB would be a
// truncated download, so those are skipped too.
find_models :: proc(al := context.allocator) -> []Model {
	out := make([dynamic]Model, al)
	seen := make(map[string]bool, 16, context.temp_allocator)

	for raw in MODEL_DIRS {
		dir := expand_path(raw, context.temp_allocator)
		entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if rerr != nil {
			continue
		}
		for e in entries {
			if e.type == .Directory {
				continue
			}
			name := e.name
			if !strings.has_prefix(name, "ggml-") || !strings.has_suffix(name, ".bin") {
				continue
			}
			if strings.contains(name, "vad") {
				continue // silero VAD, not a transcription model
			}
			if e.size < 20 * 1024 * 1024 {
				continue
			}
			stem := name[len("ggml-"):len(name) - len(".bin")]
			if stem in seen {
				continue
			}
			seen[stem] = true
			append(
				&out,
				Model {
					path = fmt.aprintf("%s/%s", dir, name, allocator = al),
					name = strings.clone(stem, al),
					bytes = e.size,
					multilingual = !strings.contains(stem, ".en"),
				},
			)
		}
	}
	return out[:]
}

// find_vad_model returns the silero weights when they are sitting next to the
// speech models, so the VAD option can be offered instead of greyed out.
find_vad_model :: proc(al := context.allocator) -> (path: string, ok: bool) {
	for raw in MODEL_DIRS {
		dir := expand_path(raw, context.temp_allocator)
		entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if rerr != nil {
			continue
		}
		for e in entries {
			if e.type != .Directory && strings.contains(e.name, "vad") && strings.has_suffix(e.name, ".bin") {
				return fmt.aprintf("%s/%s", dir, e.name, allocator = al), true
			}
		}
	}
	return "", false
}

human_size :: proc(b: i64, al := context.temp_allocator) -> string {
	f := f64(b)
	switch {
	case b >= 1024 * 1024 * 1024:
		return fmt.aprintf("%.1f GB", f / (1024 * 1024 * 1024), allocator = al)
	case b >= 1024 * 1024:
		return fmt.aprintf("%.0f MB", f / (1024 * 1024), allocator = al)
	}
	return fmt.aprintf("%d bytes", b, allocator = al)
}

// ---------------------------------------------------------------------------
// Probing
// ---------------------------------------------------------------------------

Media_Info :: struct {
	path:      string,
	duration:  f64,
	has_video: bool,
	has_audio: bool,
	width:     int,
	height:    int,
	vcodec:    string,
	acodec:    string,
}

probe :: proc(path: string, al := context.allocator) -> (info: Media_Info, err: string) {
	if !os.exists(path) {
		return {}, fmt.tprintf("no such file: %s", path)
	}
	// One ffprobe call, flat key=value, so the parse is a loop over lines.
	out, ok := kit.run(
		{
			"ffprobe",
			"-v",
			"error",
			"-show_entries",
			"format=duration:stream=codec_type,codec_name,width,height",
			"-of",
			"default=noprint_wrappers=0",
			path,
		},
		context.temp_allocator,
	)
	if !ok || out == "" {
		return {}, fmt.tprintf("ffprobe could not read %s", filepath.base(path))
	}

	info.path = strings.clone(path, al)
	cur_type := ""
	cur_codec := ""
	cur_w, cur_h := 0, 0

	// ffprobe prints one [STREAM] block per stream and then the [FORMAT]
	// block, so the fields are accumulated and committed at each close tag.
	commit :: proc(info: ^Media_Info, kind, codec: string, w, h: int, al: runtime.Allocator) {
		switch kind {
		case "video":
			if !info.has_video {
				info.has_video = true
				info.width = w
				info.height = h
				info.vcodec = strings.clone(codec, al)
			}
		case "audio":
			if !info.has_audio {
				info.has_audio = true
				info.acodec = strings.clone(codec, al)
			}
		}
	}

	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		switch {
		case l == "[/STREAM]":
			commit(&info, cur_type, cur_codec, cur_w, cur_h, al)
			cur_type, cur_codec, cur_w, cur_h = "", "", 0, 0
		case strings.has_prefix(l, "codec_type="):
			cur_type = l[len("codec_type="):]
		case strings.has_prefix(l, "codec_name="):
			cur_codec = l[len("codec_name="):]
		case strings.has_prefix(l, "width="):
			cur_w, _ = strconv.parse_int(l[len("width="):])
		case strings.has_prefix(l, "height="):
			cur_h, _ = strconv.parse_int(l[len("height="):])
		case strings.has_prefix(l, "duration="):
			v, good := strconv.parse_f64(l[len("duration="):])
			if good {
				info.duration = v
			}
		}
	}

	if info.duration <= 0 {
		return info, "ffprobe reported no duration — not a media file?"
	}
	if !info.has_audio {
		return info, "this file has no audio track, so there is nothing to transcribe"
	}
	return info, ""
}

MEDIA_EXTS := [?]string {
	".mp4",
	".mkv",
	".mov",
	".webm",
	".avi",
	".m4v",
	".mpg",
	".mpeg",
	".ts",
	".wav",
	".mp3",
	".m4a",
	".flac",
	".ogg",
	".opus",
	".aac",
	".wma",
	".oga",
}

is_media_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for e in MEDIA_EXTS {
		if ext == e {
			return true
		}
	}
	return false
}

is_subtitle_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return ext == ".srt" || ext == ".vtt"
}

// ---------------------------------------------------------------------------
// Audio extraction
// ---------------------------------------------------------------------------

// extract_wav writes the 16 kHz mono WAV whisper.cpp requires. It accepts only
// flac/mp3/ogg/wav, so video has to be demuxed first whatever the sample rate
// happens to be.
extract_wav :: proc(src, dst: string) -> (ok: bool, err: string) {
	_, good := kit.run(
		{"ffmpeg", "-v", "error", "-y", "-i", src, "-vn", "-ar", "16000", "-ac", "1", dst},
		context.temp_allocator,
	)
	if !good || !os.exists(dst) {
		return false, "ffmpeg could not extract a 16 kHz mono WAV"
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Waveform
//
// The peaks are decoded once at 8 kHz and bucketed into a fixed array, so the
// drawing code never touches the audio again and a four-hour file costs the
// same 200 KB as a four-second one.
// ---------------------------------------------------------------------------

PEAK_N :: 16384

Peaks :: struct {
	lo:    [PEAK_N]f32, // most negative sample in the bucket, -1 .. 0
	hi:    [PEAK_N]f32, // most positive, 0 .. 1
	rms:   [PEAK_N]f32,
	n:     int, // buckets actually filled
	ready: bool,
}

// decode_peaks runs the whole file through ffmpeg as signed 16-bit mono and
// reduces it to PEAK_N min/max/RMS buckets. The PCM goes to a file rather than
// a pipe because an hour of 8 kHz audio is 57 MB and buffering that in memory
// to throw it away is pointless.
decode_peaks :: proc(src: string, raw_path: string, p: ^Peaks) -> (ok: bool, err: string) {
	_, good := kit.run(
		{
			"ffmpeg",
			"-v",
			"error",
			"-y",
			"-i",
			src,
			"-vn",
			"-f",
			"s16le",
			"-acodec",
			"pcm_s16le",
			"-ac",
			"1",
			"-ar",
			"8000",
			raw_path,
		},
		context.temp_allocator,
	)
	if !good {
		return false, "ffmpeg could not decode the audio for a waveform"
	}

	f, oerr := os.open(raw_path)
	if oerr != nil {
		return false, "could not read the decoded audio"
	}
	defer os.close(f)

	size, serr := os.file_size(f)
	if serr != nil || size < 2 {
		return false, "the decoded audio is empty"
	}
	total := int(size / 2)
	buckets := min(PEAK_N, max(1, total))
	per := max(1, total / buckets)

	for i in 0 ..< PEAK_N {
		p.lo[i] = 0
		p.hi[i] = 0
		p.rms[i] = 0
	}

	chunk := make([]u8, 1 << 16, context.temp_allocator)
	idx := 0 // sample index
	bucket := 0
	blo, bhi := f32(0), f32(0)
	acc := f64(0)
	count := 0
	first := true

	for {
		n, rerr := os.read(f, chunk)
		if rerr != nil || n <= 0 {
			break
		}
		// An odd tail byte cannot form a sample; drop it.
		for off := 0; off + 1 < n; off += 2 {
			raw := i16(u16(chunk[off]) | (u16(chunk[off + 1]) << 8))
			v := f32(raw) / 32768.0
			if first {
				blo, bhi = v, v
				first = false
			} else {
				blo = min(blo, v)
				bhi = max(bhi, v)
			}
			acc += f64(v) * f64(v)
			count += 1
			idx += 1

			if count >= per && bucket < buckets {
				p.lo[bucket] = blo
				p.hi[bucket] = bhi
				p.rms[bucket] = f32(acc / f64(count))
				bucket += 1
				blo, bhi, acc, count = 0, 0, 0, 0
				first = true
			}
		}
	}
	if count > 0 && bucket < buckets {
		p.lo[bucket] = blo
		p.hi[bucket] = bhi
		p.rms[bucket] = f32(acc / f64(count))
		bucket += 1
	}

	p.n = max(bucket, 1)
	p.ready = true
	os.remove(raw_path)
	return true, ""
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

// grab_frame pulls a single video frame at `t`, scaled down, for the styling
// preview. `-ss` before `-i` is the fast seek: it jumps to the nearest
// keyframe, which is what makes this cheap enough to do while playing.
grab_frame :: proc(src: string, t: f64, dst: string, width: int) -> (ok: bool, err: string) {
	_, good := kit.run(
		{
			"ffmpeg",
			"-v",
			"error",
			"-y",
			"-ss",
			fmt.tprintf("%.3f", max(0, t)),
			"-i",
			src,
			"-frames:v",
			"1",
			"-vf",
			fmt.tprintf("scale=%d:-2", width),
			"-f",
			"image2",
			dst,
		},
		context.temp_allocator,
	)
	if !good || !os.exists(dst) {
		return false, "ffmpeg could not extract a frame"
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Playback
//
// palmy is one window with no video sink, so playback is the audio only: an
// ffplay with no display, started at an offset. The playhead is this
// application's own clock, which is why seeking is a restart rather than a
// command sent to the player.
// ---------------------------------------------------------------------------

Player :: struct {
	proc_:   os.Process,
	running: bool,
	// Where in the media the player was told to start, and the app clock at
	// the moment it was.
	base:    f64,
	at:      f64,
}

player_start :: proc(pl: ^Player, path: string, from: f64) -> bool {
	player_stop(pl)
	p, err := os.process_start(
		{
			command = {
				"ffplay",
				"-v",
				"quiet",
				"-nodisp",
				"-autoexit",
				"-ss",
				fmt.tprintf("%.3f", max(0, from)),
				"-i",
				path,
			},
			stdout = nil,
			stderr = nil,
			stdin = nil,
		},
	)
	if err != nil {
		return false
	}
	pl.proc_ = p
	pl.running = true
	pl.base = max(0, from)
	return true
}

player_stop :: proc(pl: ^Player) {
	if !pl.running {
		return
	}
	_ = os.process_kill(pl.proc_)
	_, _ = os.process_wait(pl.proc_)
	pl.running = false
}

// player_alive reaps the process when ffplay has run off the end of the file,
// so `playing` turns itself off at the end of the media.
player_alive :: proc(pl: ^Player) -> bool {
	if !pl.running {
		return false
	}
	_, err := os.process_wait(pl.proc_, 0)
	if err == nil {
		pl.running = false
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Burn-in
// ---------------------------------------------------------------------------

// burn_args builds the ffmpeg command that renders captions into a new file.
// ASS is used rather than `subtitles=...:force_style=...` because the styling
// is already expressed exactly in the script, and `-progress pipe:1` makes the
// progress machine-readable instead of scraped from the status line.
//
// The output is never the input: the caller checks that, and so does this.
burn_args :: proc(src, ass_path, dst: string, al := context.temp_allocator) -> []string {
	args := make([dynamic]string, al)
	for s in ([?]string {
			"ffmpeg",
			"-hide_banner",
			"-nostdin",
			"-y",
			"-progress",
			"pipe:1",
			"-i",
			src,
			"-vf",
			fmt.tprintf("ass=%s", ass_path),
			"-c:a",
			"copy",
			"-movflags",
			"+faststart",
			dst,
		}) {
		append(&args, strings.clone(s, al))
	}
	return args[:]
}

// same_file compares two paths after normalising them.
//
// It cannot use `filepath.abs`, which resolves through the filesystem and so
// fails on a path that does not exist yet — and the output of a burn-in never
// exists yet. The comparison is therefore lexical: make both absolute against
// the working directory, then clean away `.`, `..` and repeated slashes. That
// catches the case this exists to catch, a user naming the source as the
// output; it will not catch two different paths reaching one file through a
// symlink, which is why the burn-in also refuses to start when the output
// resolves to the input once it does exist.
same_file :: proc(a, b: string) -> bool {
	return normal_path(a) == normal_path(b)
}

normal_path :: proc(path: string, al := context.temp_allocator) -> string {
	full := path
	if !filepath.is_abs(path) {
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err == nil {
			full = fmt.tprintf("%s/%s", cwd, path)
		}
	}
	out, _ := filepath.clean(full, al)
	return out
}

// default_output derives a sibling path for an export or a burn-in, so the
// usual case needs no typing and still never lands on the source.
default_output :: proc(src, suffix, ext: string, al := context.temp_allocator) -> string {
	dir := filepath.dir(src)
	if dir == "" {
		dir = "."
	}
	stem := filepath.stem(filepath.base(src))
	return fmt.aprintf("%s/%s%s.%s", dir, stem, suffix, ext, allocator = al)
}

// list_media returns the media and subtitle files in a directory, sorted, for
// the import pane's picker. Everything in this application is keyboard
// drivable, and a list beats typing a path.
list_media :: proc(dir: string, al := context.allocator) -> []string {
	out := make([dynamic]string, al)
	entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil {
		return out[:]
	}
	for e in entries {
		if e.type == .Directory || strings.has_prefix(e.name, ".") {
			continue
		}
		if is_media_path(e.name) || is_subtitle_path(e.name) {
			append(&out, strings.clone(e.name, al))
		}
	}
	slice_sort_strings(out[:])
	return out[:]
}

@(private = "file")
slice_sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) {
		j := i
		for j > 0 && strings.compare(s[j - 1], s[j]) > 0 {
			s[j - 1], s[j] = s[j], s[j - 1]
			j -= 1
		}
	}
}
