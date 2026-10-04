package main

// Subtitle import and export.
//
// This is the interface to the captioning app: it writes SRT, WebVTT or ASS,
// and this file reads all three into the same `Caption` cue list. Nothing is
// shared but the files.
//
// The three timecode dialects are close enough to be confusing:
//
//	SRT   00:00:01,500 --> 00:00:03,250      HH:MM:SS,mmm, hours required
//	VTT   00:01.500 --> 00:03.250 align:...  HH optional, dot, trailing settings
//	ASS   0:00:01.50,0:00:03.25              H:MM:SS.cc, centiseconds
//
// so `parse_timecode` accepts any of them: one or two digit hours, an optional
// hours field, `,` or `.` before a fraction of any length. The self-test pins
// sub-second and over-an-hour cases in all three.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

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

Caption_Format :: enum {
	Unknown,
	SRT,
	VTT,
	ASS,
}

caption_format_of :: proc(path, body: string) -> Caption_Format {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".srt"):
		return .SRT
	case strings.has_suffix(lower, ".vtt"):
		return .VTT
	case strings.has_suffix(lower, ".ass"), strings.has_suffix(lower, ".ssa"):
		return .ASS
	}
	// Fall back to sniffing, so a mislabelled file still loads.
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

// parse_captions reads any of the three formats. Cues come back in time order
// with the text already unescaped and newlines normalised to "\n".
parse_captions :: proc(
	path, body: string,
	alloc := context.allocator,
) -> (
	cues: [dynamic]Caption,
	format: Caption_Format,
	ok: bool,
) {
	format = caption_format_of(path, body)
	cues = make([dynamic]Caption, alloc)
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

sort_cues :: proc(cues: ^[dynamic]Caption) {
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
parse_cue_blocks :: proc(cues: ^[dynamic]Caption, body: string, alloc: mem.Allocator) -> bool {
	lines := strings.split_lines(normalise_newlines(body, context.temp_allocator), context.temp_allocator)
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
		append(cues, Caption{start = start, end = end, text = strings.clone(text, alloc)})
		any = true
	}
	return any
}

// parse_ass reads the [Events] section. The Format line names the columns, so
// the Start/End/Text indices are read from it rather than assumed — an ASS
// writer is free to reorder them.
@(private)
parse_ass :: proc(cues: ^[dynamic]Caption, body: string, alloc: mem.Allocator) -> bool {
	lines := strings.split_lines(normalise_newlines(body, context.temp_allocator), context.temp_allocator)
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
		append(cues, Caption{start = start, end = end, text = strings.clone(text, alloc)})
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
// SRT allow. The caption track and the burn-in both want plain text.
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

load_captions :: proc(pr: ^Project, path: string) -> (n: int, format: Caption_Format, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return 0, .Unknown, false
	}
	cues, fmt_, good := parse_captions(path, string(data))
	if !good {
		delete(cues)
		return 0, fmt_, false
	}
	for c in pr.captions {
		delete(c.text)
	}
	clear(&pr.captions)
	for c in cues {
		append(&pr.captions, c)
	}
	delete(cues)
	delete(pr.caption_src)
	pr.caption_src = strings.clone(path)
	pr.caption_offset = 0
	return len(pr.captions), fmt_, true
}

// write_shifted_srt writes the cue list with the nudge baked in, which is what
// gets handed to ffmpeg's `subtitles` filter at export time. Writing SRT
// rather than passing the original keeps the burn-in honest: what is on the
// caption track is exactly what is rendered.
write_shifted_srt :: proc(pr: ^Project, path: string) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	n := 0
	for c in pr.captions {
		s := c.start + pr.caption_offset
		e := c.end + pr.caption_offset
		if e <= 0 {
			continue // nudged off the front of the timeline
		}
		if s < 0 {
			s = 0
		}
		n += 1
		fmt.sbprintf(&sb, "%d\n", n)
		fmt.sbprintf(&sb, "%s --> %s\n", format_srt_time(s), format_srt_time(e))
		fmt.sbprintf(&sb, "%s\n\n", c.text)
	}
	if n == 0 {
		return false
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}
