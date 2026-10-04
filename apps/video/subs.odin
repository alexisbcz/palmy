package main

// Subtitles: the parser, the track list and the cue lookup.
//
// The parser is adapted from apps/videoedit/captions.odin — copied, not
// imported, because an Odin package is a directory and these two apps share
// nothing but file formats. What was kept verbatim is the part that took the
// longest to get right: the timecode reader.
//
// The three dialects are close enough to be confusing:
//
//	SRT   00:00:01,500 --> 00:00:03,250      HH:MM:SS,mmm, hours required
//	VTT   00:01.500 --> 00:03.250 align:...  HH optional, dot, trailing settings
//	ASS   0:00:01.50,0:00:03.25              H:MM:SS.cc, centiseconds
//
// so `parse_timecode` accepts any of them: one or two digit hours, an optional
// hours field, `,` or `.` before a fraction of any length.
//
// Where this file goes beyond the editor's version is the player's side of the
// problem: finding the cue that covers a clock reading, sixty times a second,
// without a linear scan; discovering a sidecar file next to the media; and
// pulling an embedded track out of the container through ffmpeg.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."

Cue :: struct {
	start, end: f64,
	text:       string,
}

Sub_Format :: enum u8 {
	Unknown,
	SRT,
	VTT,
	ASS,
}

sub_format_name :: proc(f: Sub_Format) -> string {
	switch f {
	case .SRT:
		return "SRT"
	case .VTT:
		return "WebVTT"
	case .ASS:
		return "ASS"
	case .Unknown:
		return "?"
	}
	return "?"
}

// ---------------------------------------------------------------------------
// Timecodes
// ---------------------------------------------------------------------------

// parse_timecode reads [[HH:]MM:]SS[.,]fff into seconds.
parse_timecode :: proc(s: string) -> (secs: f64, ok: bool) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, false
	}
	// Split off the fraction first; both separators mean the same thing.
	frac := f64(0)
	whole := t
	if i := strings.last_index_any(t, ".,"); i >= 0 {
		whole = t[:i]
		digits := t[i + 1:]
		// Only an all-digit tail is a fraction; anything else is not a
		// timecode at all.
		if len(digits) == 0 {
			return 0, false
		}
		scale := f64(1)
		v := f64(0)
		for ch in digits {
			if ch < '0' || ch > '9' {
				return 0, false
			}
			v = v * 10 + f64(ch - '0')
			scale *= 10
		}
		frac = v / scale
	}

	parts := strings.split(whole, ":", context.temp_allocator)
	if len(parts) == 0 || len(parts) > 3 {
		return 0, false
	}
	vals: [3]f64
	for part, i in parts {
		pt := strings.trim_space(part)
		if pt == "" {
			return 0, false
		}
		n, good := strconv.parse_int(pt, 10)
		if !good || n < 0 {
			return 0, false
		}
		vals[i] = f64(n)
	}
	switch len(parts) {
	case 1:
		return vals[0] + frac, true
	case 2:
		return vals[0] * 60 + vals[1] + frac, true
	case 3:
		return vals[0] * 3600 + vals[1] * 60 + vals[2] + frac, true
	}
	return 0, false
}

// format_srt_time is the inverse, in SRT's dialect.
format_srt_time :: proc(t: f64, alloc := context.temp_allocator) -> string {
	v := t
	if v < 0 {
		v = 0
	}
	total := int(v)
	ms := int((v - f64(total)) * 1000 + 0.5)
	if ms >= 1000 {
		ms -= 1000
		total += 1
	}
	return fmt.aprintf(
		"%02d:%02d:%02d,%03d",
		total / 3600,
		(total / 60) % 60,
		total % 60,
		ms,
		allocator = alloc,
	)
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

sub_format_of :: proc(path, body: string) -> Sub_Format {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".srt"):
		return .SRT
	case strings.has_suffix(lower, ".vtt"):
		return .VTT
	case strings.has_suffix(lower, ".ass"), strings.has_suffix(lower, ".ssa"):
		return .ASS
	}
	// Fall back to sniffing, so a mislabelled file — or a stream pulled out of
	// a container with no name at all — still loads.
	switch {
	case strings.has_prefix(strings.trim_space(body), "WEBVTT"):
		return .VTT
	case strings.contains(body, "[Script Info]"), strings.contains(body, "Dialogue:"):
		return .ASS
	case strings.contains(body, "-->"):
		return .SRT
	}
	return .Unknown
}

// parse_subs reads any of the three formats. Cues come back in time order with
// the markup stripped and newlines normalised to "\n".
parse_subs :: proc(
	path, body: string,
	alloc := context.allocator,
) -> (
	cues: [dynamic]Cue,
	format: Sub_Format,
	ok: bool,
) {
	format = sub_format_of(path, body)
	cues = make([dynamic]Cue, alloc)
	switch format {
	case .SRT, .VTT:
		ok = parse_cue_blocks(&cues, body, alloc)
	case .ASS:
		ok = parse_ass(&cues, body, alloc)
	case .Unknown:
		ok = false
	}
	if ok {
		sort_cues(&cues)
	}
	return cues, format, ok
}

sort_cues :: proc(cues: ^[dynamic]Cue) {
	// Insertion sort: cue lists are small and nearly always already ordered.
	for i in 1 ..< len(cues) {
		c := cues[i]
		j := i - 1
		for j >= 0 && cues[j].start > c.start {
			cues[j + 1] = cues[j]
			j -= 1
		}
		cues[j + 1] = c
	}
}

// parse_cue_blocks handles SRT and VTT, which differ only in the header, the
// optional cue identifier and the trailing cue settings after the end time.
@(private)
parse_cue_blocks :: proc(cues: ^[dynamic]Cue, body: string, alloc: mem.Allocator) -> bool {
	lines := strings.split_lines(
		normalise_newlines(body, context.temp_allocator),
		context.temp_allocator,
	)
	i := 0
	any := false
	for i < len(lines) {
		line := strings.trim_space(lines[i])
		if line == "" || strings.has_prefix(line, "WEBVTT") ||
		   strings.has_prefix(line, "NOTE") || strings.has_prefix(line, "STYLE") ||
		   strings.has_prefix(line, "REGION") {
			i += 1
			continue
		}
		// A cue is a line containing "-->"; anything before it on its own line
		// is an index (SRT) or an identifier (VTT), both of which we drop.
		if !strings.contains(line, "-->") {
			i += 1
			continue
		}
		arrow := strings.index(line, "-->")
		left := strings.trim_space(line[:arrow])
		right := strings.trim_space(line[arrow + 3:])
		// VTT puts cue settings after the end time, space separated.
		if sp := strings.index_any(right, " \t"); sp >= 0 {
			right = right[:sp]
		}
		start, ok1 := parse_timecode(left)
		end, ok2 := parse_timecode(right)
		i += 1
		if !ok1 || !ok2 {
			continue
		}

		// The text runs to the next blank line.
		sb := strings.builder_make(context.temp_allocator)
		for i < len(lines) {
			tl := lines[i]
			if strings.trim_space(tl) == "" {
				break
			}
			if strings.builder_len(sb) > 0 {
				strings.write_string(&sb, "\n")
			}
			strings.write_string(&sb, strings.trim_space(tl))
			i += 1
		}
		text := strip_markup(strings.to_string(sb), context.temp_allocator)
		if end < start {
			start, end = end, start
		}
		append(cues, Cue{start = start, end = end, text = strings.clone(text, alloc)})
		any = true
	}
	return any
}

// parse_ass reads the [Events] section. The Format line names the columns, so
// the Start/End/Text indices are read from it rather than assumed — an ASS
// writer is free to reorder them.
@(private)
parse_ass :: proc(cues: ^[dynamic]Cue, body: string, alloc: mem.Allocator) -> bool {
	lines := strings.split_lines(
		normalise_newlines(body, context.temp_allocator),
		context.temp_allocator,
	)
	in_events := false
	i_start, i_end, i_text, ncols := 1, 2, 9, 10
	any := false

	for raw in lines {
		line := strings.trim_space(raw)
		if line == "" {
			continue
		}
		if strings.has_prefix(line, "[") {
			in_events = strings.has_prefix(line, "[Events]")
			continue
		}
		if !in_events {
			continue
		}
		if strings.has_prefix(line, "Format:") {
			cols := strings.split(line[len("Format:"):], ",", context.temp_allocator)
			ncols = len(cols)
			for c, ci in cols {
				switch strings.to_lower(strings.trim_space(c), context.temp_allocator) {
				case "start":
					i_start = ci
				case "end":
					i_end = ci
				case "text":
					i_text = ci
				}
			}
			continue
		}
		if !strings.has_prefix(line, "Dialogue:") {
			continue
		}
		rest := strings.trim_space(line[len("Dialogue:"):])
		// Text is last and may itself contain commas, so split only ncols-1
		// times and keep the tail whole.
		fields := split_n(rest, ",", ncols, context.temp_allocator)
		if len(fields) <= max(i_start, i_end) || i_text >= len(fields) {
			continue
		}
		start, ok1 := parse_timecode(fields[i_start])
		end, ok2 := parse_timecode(fields[i_end])
		if !ok1 || !ok2 {
			continue
		}
		text := ass_text(fields[i_text], context.temp_allocator)
		if end < start {
			start, end = end, start
		}
		append(cues, Cue{start = start, end = end, text = strings.clone(text, alloc)})
		any = true
	}
	return any
}

// split_n splits into at most n parts, the last keeping the remainder.
split_n :: proc(s, sep: string, n: int, alloc := context.temp_allocator) -> []string {
	out := make([dynamic]string, alloc)
	rest := s
	for len(out) < n - 1 {
		i := strings.index(rest, sep)
		if i < 0 {
			break
		}
		append(&out, rest[:i])
		rest = rest[i + len(sep):]
	}
	append(&out, rest)
	return out[:]
}

normalise_newlines :: proc(s: string, alloc := context.temp_allocator) -> string {
	if !strings.contains(s, "\r") {
		return s
	}
	out, _ := strings.replace_all(s, "\r\n", "\n", alloc)
	out2, _ := strings.replace_all(out, "\r", "\n", alloc)
	return out2
}

// strip_markup removes the <i>, <b>, <v Speaker> and <c.class> tags VTT and
// SRT allow. A subtitle plate drawn with one font wants plain text.
strip_markup :: proc(s: string, alloc := context.temp_allocator) -> string {
	if !strings.contains(s, "<") {
		return s
	}
	sb := strings.builder_make(alloc)
	depth := 0
	for ch in s {
		switch ch {
		case '<':
			depth += 1
		case '>':
			if depth > 0 {
				depth -= 1
			}
		case:
			if depth == 0 {
				strings.write_rune(&sb, ch)
			}
		}
	}
	return strings.to_string(sb)
}

// ass_text drops ASS override blocks `{\pos(..)}` and turns \N and \n into
// real newlines.
ass_text :: proc(s: string, alloc := context.temp_allocator) -> string {
	sb := strings.builder_make(alloc)
	depth := 0
	runes := s
	for i := 0; i < len(runes); i += 1 {
		ch := runes[i]
		switch ch {
		case '{':
			depth += 1
		case '}':
			if depth > 0 {
				depth -= 1
			}
		case '\\':
			if depth == 0 && i + 1 < len(runes) && (runes[i + 1] == 'N' || runes[i + 1] == 'n') {
				strings.write_string(&sb, "\n")
				i += 1
			} else if depth == 0 && i + 1 < len(runes) && runes[i + 1] == 'h' {
				strings.write_string(&sb, " ")
				i += 1
			}
		case:
			if depth == 0 {
				strings.write_byte(&sb, ch)
			}
		}
	}
	return strings.trim_space(strings.to_string(sb))
}

// ---------------------------------------------------------------------------
// The lookup
// ---------------------------------------------------------------------------

// cue_index_at is the cue covering `t`, or -1. The interval is half open —
// [start, end) — so a cue ending exactly where the next begins never shows two
// at once, and a gap between cues really is empty.
//
// `hint` is the index that was on screen last frame: the common case is that it
// still applies, which is one comparison. Otherwise this binary searches for
// the last cue that has started, then walks back over any that overlap it.
// `max_dur` bounds that walk — no cue can cover `t` if it started more than the
// longest cue's duration ago — which is what keeps a long gap from costing a
// scan of the whole list on every frame.
cue_index_at :: proc(cues: []Cue, t: f64, hint: int = -1, max_dur: f64 = 1e18) -> int {
	if len(cues) == 0 {
		return -1
	}
	if hint >= 0 && hint < len(cues) && cues[hint].start <= t && t < cues[hint].end {
		return hint
	}
	// Upper bound: the first cue that has not started yet.
	lo, hi := 0, len(cues)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if cues[mid].start <= t {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	// Walk back from there. Later-starting cues win, which is what a renderer
	// that can only draw one plate should do with an overlap.
	for j := lo - 1; j >= 0; j -= 1 {
		if t < cues[j].end {
			return j
		}
		if t - cues[j].start > max_dur {
			break
		}
	}
	return -1
}

cues_max_dur :: proc(cues: []Cue) -> f64 {
	d := f64(0)
	for c in cues {
		d = max(d, c.end - c.start)
	}
	return d
}

// ---------------------------------------------------------------------------
// Tracks
// ---------------------------------------------------------------------------

Sub_Source :: enum u8 {
	Sidecar,
	Embedded,
}

Sub_Track :: struct {
	src:     Sub_Source,
	path:    string, // sidecar file, empty when embedded
	media:   string, // the container to pull an embedded stream out of
	index:   int, // ffmpeg stream index, -1 when a sidecar
	codec:   string,
	lang:    string,
	title:   string,
	bitmap:  bool, // a picture codec: no text to extract
	label:   string,
	tried:   bool,
	err:     string,
	format:  Sub_Format,
	cues:    []Cue,
	max_dur: f64,
}

Subs :: struct {
	tracks: [dynamic]Sub_Track,
	active: int, // -1 is off
	show:   bool,
	offset: f64, // nudge, seconds; positive shows cues later
	cursor: int, // the cue on screen, the hint for the next lookup
	panel:  bool,
}

// SUB_EXT is the sidecar extensions, in the order a player should prefer them.
SUB_EXT := [?]string{".srt", ".vtt", ".ass", ".ssa"}

// BITMAP_SUB_CODECS cannot be turned into text by any amount of ffmpeg: the
// cues are pictures. Listing them as unsupported is the honest answer; silently
// loading nothing is not.
BITMAP_SUB_CODECS := [?]string {
	"dvd_subtitle",
	"hdmv_pgs_subtitle",
	"dvb_subtitle",
	"xsub",
	"dvb_teletext",
}

is_bitmap_sub :: proc(codec: string) -> bool {
	for c in BITMAP_SUB_CODECS {
		if strings.equal_fold(codec, c) {
			return true
		}
	}
	return false
}

// strip_ext is the media path with its last extension removed.
strip_ext :: proc(path: string) -> string {
	base := base_of(path)
	if i := strings.last_index_byte(base, '.'); i > 0 {
		return path[:len(path) - (len(base) - i)]
	}
	return path
}

// sidecar_matches picks the subtitle files in a directory listing that belong
// to `stem` — the media's name without its extension. Both the plain
// `name.srt` and the language-tagged `name.en.srt` count, with the plain ones
// first and the extensions in SUB_EXT order, so `.srt` wins over `.vtt`.
//
// Pure, so the selftest can hand it a listing rather than a filesystem.
sidecar_matches :: proc(names: []string, stem: string, alloc := context.allocator) -> []string {
	plain := make([dynamic]string, context.temp_allocator)
	tagged := make([dynamic]string, context.temp_allocator)
	for ext in SUB_EXT {
		for n in names {
			lower := strings.to_lower(n, context.temp_allocator)
			if !strings.has_suffix(lower, ext) {
				continue
			}
			body := n[:len(n) - len(ext)]
			if strings.equal_fold(body, stem) {
				append(&plain, n)
			} else if len(body) > len(stem) + 1 &&
			   strings.equal_fold(body[:len(stem)], stem) &&
			   body[len(stem)] == '.' {
				append(&tagged, n)
			}
		}
	}
	out := make([dynamic]string, alloc)
	for n in plain {
		append(&out, strings.clone(n, alloc))
	}
	for n in tagged {
		append(&out, strings.clone(n, alloc))
	}
	return out[:]
}

// sub_lang_of pulls the language out of `name.en.srt`, or "" if there is none.
sub_lang_of :: proc(name: string, stem: string) -> string {
	for ext in SUB_EXT {
		lower := strings.to_lower(name, context.temp_allocator)
		if !strings.has_suffix(lower, ext) {
			continue
		}
		body := name[:len(name) - len(ext)]
		if len(body) > len(stem) + 1 && body[len(stem)] == '.' {
			return body[len(stem) + 1:]
		}
	}
	return ""
}

// subs_build discovers every track for a file: the sidecars next to it and the
// subtitle streams ffprobe found inside it. Nothing is parsed yet — a track's
// cues are read the first time it is selected.
subs_build :: proc(s: ^Subs, m: Media) {
	subs_free(s)
	s.tracks = make([dynamic]Sub_Track)
	s.active = -1
	s.show = true
	s.cursor = -1

	stem_path := strip_ext(m.path)
	stem := base_of(stem_path)
	dir := dir_of(m.path)
	if infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator); err == nil {
		names := make([dynamic]string, context.temp_allocator)
		for fi in infos {
			if fi.type != .Directory {
				append(&names, fi.name)
			}
		}
		for n in sidecar_matches(names[:], stem, context.temp_allocator) {
			lang := sub_lang_of(n, stem)
			path := fmt.aprintf("%s/%s", dir, n)
			label := lang != "" \
				? fmt.aprintf("%s · sidecar", strings.to_upper(lang, context.temp_allocator)) \
				: strings.clone("Sidecar file")
			append(
				&s.tracks,
				Sub_Track {
					src = .Sidecar,
					path = path,
					media = m.path,
					index = -1,
					lang = strings.clone(lang),
					title = strings.clone(n),
					label = label,
				},
			)
		}
	}

	for ss in m.subs {
		lab: string
		switch {
		case ss.title != "" && ss.lang != "":
			lab = fmt.aprintf("%s (%s)", ss.title, ss.lang)
		case ss.title != "":
			lab = strings.clone(ss.title)
		case ss.lang != "":
			lab = fmt.aprintf("%s · stream %d", strings.to_upper(ss.lang, context.temp_allocator), ss.index)
		case:
			lab = fmt.aprintf("Stream %d", ss.index)
		}
		append(
			&s.tracks,
			Sub_Track {
				src = .Embedded,
				media = m.path,
				index = ss.index,
				codec = strings.clone(ss.codec),
				lang = strings.clone(ss.lang),
				title = strings.clone(ss.title),
				bitmap = ss.bitmap,
				label = lab,
			},
		)
	}

	// Open on the first track that can actually show text.
	for _, i in s.tracks {
		if s.tracks[i].bitmap {
			continue
		}
		if subs_select(s, i) {
			break
		}
	}
}

subs_free :: proc(s: ^Subs) {
	for &t in s.tracks {
		for c in t.cues {
			delete(c.text)
		}
		delete(t.cues)
		delete(t.path)
		delete(t.codec)
		delete(t.lang)
		delete(t.title)
		delete(t.label)
		delete(t.err)
	}
	delete(s.tracks)
	s.tracks = nil
	s.active = -1
	s.cursor = -1
	s.offset = 0
}

// subs_load reads a track's cues, which for an embedded stream means asking
// ffmpeg to convert it to SRT on stdout. A bitmap codec is refused here rather
// than handed to ffmpeg, because `-f srt` on a picture stream fails with a
// message no one would connect to the subtitle track they chose.
subs_load :: proc(t: ^Sub_Track) -> bool {
	if t.tried {
		return len(t.cues) > 0
	}
	t.tried = true
	if t.bitmap {
		t.err = fmt.aprintf("%s is a bitmap format — it has no text to show", t.codec)
		return false
	}

	body: string
	name: string
	if t.src == .Sidecar {
		data, err := os.read_entire_file_from_path(t.path, context.temp_allocator)
		if err != nil {
			t.err = strings.clone("the sidecar file could not be read")
			return false
		}
		body = string(data)
		name = t.path
	} else {
		if !kit.has_tool("ffmpeg") {
			t.err = strings.clone("ffmpeg is not installed")
			return false
		}
		out, ok := kit.run(
			{
				"ffmpeg",
				"-v",
				"error",
				"-i",
				t.media,
				"-map",
				fmt.tprintf("0:%d", t.index),
				"-f",
				"srt",
				"-",
			},
			context.temp_allocator,
		)
		if !ok || strings.trim_space(out) == "" {
			t.err = strings.clone("ffmpeg could not convert this stream to text")
			return false
		}
		body = out
		name = "stream.srt"
	}

	cues, format, ok := parse_subs(name, body)
	if !ok || len(cues) == 0 {
		delete(cues)
		t.err = strings.clone("no cues could be read from this track")
		return false
	}
	t.cues = cues[:]
	t.format = format
	t.max_dur = cues_max_dur(t.cues)
	return true
}

subs_select :: proc(s: ^Subs, i: int) -> bool {
	s.cursor = -1
	if i < 0 || i >= len(s.tracks) {
		s.active = -1
		return false
	}
	if subs_load(&s.tracks[i]) {
		s.active = i
		return true
	}
	// A track that will not load is still worth selecting: the UI says why,
	// which is the whole point of listing an unsupported codec.
	s.active = i
	return false
}

// subs_cycle steps through the tracks and off again, so one key reaches every
// state. Off is the slot past the end.
subs_cycle :: proc(s: ^Subs, d: int) {
	n := len(s.tracks)
	if n == 0 {
		s.active = -1
		return
	}
	// -1 is off, which sits at index n in the ring.
	cur := s.active < 0 ? n : s.active
	next := ((cur + d) % (n + 1) + (n + 1)) % (n + 1)
	if next == n {
		s.active = -1
		s.cursor = -1
		return
	}
	subs_select(s, next)
}

subs_active :: proc(s: ^Subs) -> ^Sub_Track {
	if s.active < 0 || s.active >= len(s.tracks) {
		return nil
	}
	return &s.tracks[s.active]
}

// subs_text_at is the cue to draw at a media time, with the nudge applied and
// the cursor cached so the usual frame costs one comparison.
subs_text_at :: proc(s: ^Subs, t: f64) -> (text: string, ok: bool) {
	if !s.show {
		return "", false
	}
	tr := subs_active(s)
	if tr == nil || len(tr.cues) == 0 {
		return "", false
	}
	i := cue_index_at(tr.cues, t - s.offset, s.cursor, tr.max_dur)
	s.cursor = i
	if i < 0 {
		return "", false
	}
	return tr.cues[i].text, true
}

// subs_summary is the one line the status bar and the panel header share.
subs_summary :: proc(s: ^Subs) -> string {
	tr := subs_active(s)
	if tr == nil {
		return len(s.tracks) == 0 ? "none found" : "off"
	}
	if len(tr.cues) == 0 {
		return fmt.tprintf("%s — unsupported", tr.label)
	}
	return fmt.tprintf("%s · %d cues", tr.label, len(tr.cues))
}
