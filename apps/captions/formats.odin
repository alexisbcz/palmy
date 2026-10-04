package main

// Subtitle file formats.
//
// This is the application's interface to the rest of the world — the editor in
// apps/videoedit/ reads what is written here, and so does ffmpeg's `subtitles`
// and `ass` filter. So the shapes matter more than the convenience:
//
//   SRT   1-based index, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, blank line between
//         cues. No markup, no escaping, but a cue may never contain a blank
//         line or the parser on the other side splits it in two.
//   WebVTT `WEBVTT` header, `HH:MM:SS.mmm`, and the text is HTML-ish, so `&`,
//         `<` and `>` have to be entities. Escaping `>` is also what keeps a
//         literal `-->` out of a cue body.
//   ASS   the only one of the three that carries styling, which is why it is
//         what the burn-in uses. Colours are `&HAABBGGRR` with alpha
//         *inverted* (00 is opaque), times are centisecond-resolution with a
//         single-digit hour, and the text field is the last one on the line so
//         it may contain commas.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

Format :: enum {
	SRT,
	VTT,
	ASS,
	TXT,
}

format_name :: proc(f: Format) -> string {
	switch f {
	case .SRT:
		return "SubRip (.srt)"
	case .VTT:
		return "WebVTT (.vtt)"
	case .ASS:
		return "Advanced SSA (.ass)"
	case .TXT:
		return "Plain text (.txt)"
	}
	return ""
}

format_ext :: proc(f: Format) -> string {
	switch f {
	case .SRT:
		return "srt"
	case .VTT:
		return "vtt"
	case .ASS:
		return "ass"
	case .TXT:
		return "txt"
	}
	return "txt"
}

// ---------------------------------------------------------------------------
// Timecodes
// ---------------------------------------------------------------------------

// ms_of rounds seconds to whole milliseconds, which is the resolution SRT and
// WebVTT actually store. Rounding rather than truncating matters: a segment
// ending at 3.4799999 must not be written as 3.479 while the next one starts
// at 3.480, or a strict reader sees a gap that is not there.
ms_of :: proc(t: f64) -> i64 {
	if t <= 0 {
		return 0
	}
	return i64(math.round(t * 1000))
}

// fmt_timecode writes `HH:MM:SS<sep>mmm`. SRT wants a comma, WebVTT a period.
// Hours are not clamped to two digits: a nine-hour recording is rare but a
// silent truncation to `09:` of a ten-hour one would be a corruption.
fmt_timecode :: proc(t: f64, sep: string, al := context.temp_allocator) -> string {
	ms := ms_of(t)
	h := ms / 3_600_000
	m := (ms % 3_600_000) / 60_000
	s := (ms % 60_000) / 1000
	f := ms % 1000
	return fmt.aprintf("%02d:%02d:%02d%s%03d", h, m, s, sep, f, allocator = al)
}

srt_timecode :: proc(t: f64, al := context.temp_allocator) -> string {
	return fmt_timecode(t, ",", al)
}

vtt_timecode :: proc(t: f64, al := context.temp_allocator) -> string {
	return fmt_timecode(t, ".", al)
}

// ass_timecode is `H:MM:SS.cc` — one hour digit and centiseconds, which is all
// the format has room for. Sub-centisecond detail is lost here by design, so
// the rounding is explicit rather than a truncation.
ass_timecode :: proc(t: f64, al := context.temp_allocator) -> string {
	cs := i64(0)
	if t > 0 {
		cs = i64(math.round(t * 100))
	}
	h := cs / 360_000
	m := (cs % 360_000) / 6_000
	s := (cs % 6_000) / 100
	c := cs % 100
	return fmt.aprintf("%d:%02d:%02d.%02d", h, m, s, c, allocator = al)
}

// parse_timecode reads `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `H:MM:SS.cc` and
// `MM:SS.mmm`, which between them covers SRT, WebVTT and ASS. The fractional
// part is scaled by its digit count, so `.5` is half a second and `.50` is
// also half a second — not 50ms.
parse_timecode :: proc(text: string) -> (t: f64, ok: bool) {
	s := strings.trim_space(text)
	if s == "" {
		return 0, false
	}

	frac := f64(0)
	// Split the fraction off first, accepting either separator.
	cut := -1
	for i in 0 ..< len(s) {
		if s[i] == ',' || s[i] == '.' {
			cut = i
			break
		}
	}
	if cut >= 0 {
		digits := s[cut + 1:]
		for i in 0 ..< len(digits) {
			if digits[i] < '0' || digits[i] > '9' {
				return 0, false
			}
		}
		if len(digits) == 0 || len(digits) > 9 {
			return 0, false
		}
		v, good := strconv.parse_f64(digits)
		if !good {
			return 0, false
		}
		frac = v / math.pow(f64(10), f64(len(digits)))
		s = s[:cut]
	}

	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 {
		return 0, false
	}
	vals: [3]f64
	for p, i in parts {
		if p == "" {
			return 0, false
		}
		v, good := strconv.parse_f64(p)
		if !good {
			return 0, false
		}
		vals[i] = v
	}
	if len(parts) == 3 {
		t = vals[0] * 3600 + vals[1] * 60 + vals[2]
	} else {
		t = vals[0] * 60 + vals[1]
	}
	return t + frac, true
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

// srt_body flattens a caption for SRT. A blank line would terminate the cue,
// so runs of newlines collapse to one.
srt_body :: proc(text: string, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	prev_nl := true // suppress leading newlines too
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '\r' {
			continue
		}
		if c == '\n' {
			if !prev_nl {
				strings.write_byte(&b, '\n')
			}
			prev_nl = true
			continue
		}
		prev_nl = false
		strings.write_byte(&b, c)
	}
	out := strings.to_string(b)
	return strings.trim_right_space(out)
}

// vtt_body is srt_body plus the three XML entities WebVTT requires. `>` is
// escaped as well as `<`, which is what stops a line reading `a --> b` from
// being mistaken for a cue timing.
vtt_body :: proc(text: string, al := context.temp_allocator) -> string {
	flat := srt_body(text, context.temp_allocator)
	b := strings.builder_make(al)
	for i in 0 ..< len(flat) {
		switch flat[i] {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case:
			strings.write_byte(&b, flat[i])
		}
	}
	return strings.to_string(b)
}

// ass_body puts a caption into an ASS Dialogue text field. Line breaks become
// `\N`, braces are escaped because `{...}` is an override block, and a literal
// backslash is doubled — libass renders an unknown `\x` as `x`, so `\\` comes
// back out as one backslash.
//
// Leading and trailing spaces are turned into `\h` (a hard space); libass
// trims ordinary ones.
ass_body :: proc(text: string, al := context.temp_allocator) -> string {
	flat := srt_body(text, context.temp_allocator)
	b := strings.builder_make(al)
	for i in 0 ..< len(flat) {
		c := flat[i]
		at_edge := i == 0 || i == len(flat) - 1
		switch c {
		case '\n':
			strings.write_string(&b, "\\N")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '{':
			strings.write_string(&b, "\\{")
		case '}':
			strings.write_string(&b, "\\}")
		case ' ':
			strings.write_string(&b, at_edge ? "\\h" : " ")
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// ass_colour converts 0xRRGGBB plus an opacity into ASS's `&HAABBGGRR&`. The
// channel order is reversed from everything else, and the alpha byte is
// transparency, not opacity — 00 is fully visible.
ass_colour :: proc(rgb: u32, opacity: f32, al := context.temp_allocator) -> string {
	o := clamp(opacity, 0, 1)
	a := u32(math.round(f64((1 - o) * 255)))
	r := (rgb >> 16) & 0xff
	g := (rgb >> 8) & 0xff
	bl := rgb & 0xff
	return fmt.aprintf("&H%02X%02X%02X%02X", a, bl, g, r, allocator = al)
}

// ---------------------------------------------------------------------------
// Writers
// ---------------------------------------------------------------------------

write_srt :: proc(segs: []Seg, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	n := 0
	for s in segs {
		body := srt_body(seg_text(s), context.temp_allocator)
		if body == "" {
			continue
		}
		n += 1
		fmt.sbprintf(&b, "%d\n", n)
		fmt.sbprintf(
			&b,
			"%s --> %s\n",
			srt_timecode(s.start, context.temp_allocator),
			srt_timecode(s.end, context.temp_allocator),
		)
		strings.write_string(&b, body)
		strings.write_string(&b, "\n\n")
	}
	return strings.to_string(b)
}

write_vtt :: proc(segs: []Seg, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	strings.write_string(&b, "WEBVTT\n\n")
	n := 0
	for s in segs {
		body := vtt_body(seg_text(s), context.temp_allocator)
		if body == "" {
			continue
		}
		n += 1
		fmt.sbprintf(&b, "%d\n", n)
		fmt.sbprintf(
			&b,
			"%s --> %s\n",
			vtt_timecode(s.start, context.temp_allocator),
			vtt_timecode(s.end, context.temp_allocator),
		)
		strings.write_string(&b, body)
		strings.write_string(&b, "\n\n")
	}
	return strings.to_string(b)
}

write_txt :: proc(segs: []Seg, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	for s in segs {
		body := srt_body(seg_text(s), context.temp_allocator)
		if body == "" {
			continue
		}
		// Plain text wants running prose, so an in-caption break becomes a
		// space rather than a paragraph.
		for i in 0 ..< len(body) {
			strings.write_byte(&b, body[i] == '\n' ? ' ' : body[i])
		}
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

// ASS_ALIGN maps a Position to the numpad alignment ASS uses: 1-3 bottom,
// 4-6 middle, 7-9 top, left/centre/right within each row.
ass_alignment :: proc(pos: Position) -> int {
	switch pos {
	case .Bottom_Left:
		return 1
	case .Bottom:
		return 2
	case .Bottom_Right:
		return 3
	case .Middle:
		return 5
	case .Top_Left:
		return 7
	case .Top:
		return 8
	case .Top_Right:
		return 9
	}
	return 2
}

// write_ass emits a complete script: Script Info with the play resolution the
// font size is relative to, one V4+ style built from the editor's styling, and
// the events.
//
// PlayResX/PlayResY are the source video's real pixel size, so a Fontsize of
// 54 is 54 source pixels and the burn-in looks like the preview.
write_ass :: proc(
	segs: []Seg,
	st: Caption_Style,
	play_w, play_h: int,
	al := context.temp_allocator,
) -> string {
	b := strings.builder_make(al)

	pw := play_w > 0 ? play_w : 1920
	ph := play_h > 0 ? play_h : 1080

	strings.write_string(&b, "[Script Info]\n")
	strings.write_string(&b, "; Generated by palmy captions\n")
	strings.write_string(&b, "ScriptType: v4.00+\n")
	strings.write_string(&b, "WrapStyle: 0\n")
	strings.write_string(&b, "ScaledBorderAndShadow: yes\n")
	strings.write_string(&b, "YCbCr Matrix: None\n")
	fmt.sbprintf(&b, "PlayResX: %d\n", pw)
	fmt.sbprintf(&b, "PlayResY: %d\n\n", ph)

	strings.write_string(&b, "[V4+ Styles]\n")
	strings.write_string(
		&b,
		"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, " +
		"OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, " +
		"ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, " +
		"MarginL, MarginR, MarginV, Encoding\n",
	)

	// BorderStyle 3 is an opaque box behind the text and 1 is an outline plus
	// a drop shadow; the format allows only one of the two.
	//
	// The box is drawn in **OutlineColour**, not BackColour — BackColour is
	// the shadow. This was checked by burning a script in with ffmpeg and
	// looking at the frame, because the documentation for this format says
	// otherwise about as often as it says it correctly.
	border_style := st.box ? 3 : 1
	outline := st.box ? f64(st.box_pad) : f64(st.outline)
	shadow := st.box ? 0.0 : f64(st.shadow)

	outline_col := ass_colour(st.outline_rgb, 1, context.temp_allocator)
	back_col := ass_colour(0x000000, 0.5, context.temp_allocator)
	if st.box {
		outline_col = ass_colour(st.box_rgb, st.box_opacity, context.temp_allocator)
		back_col = ass_colour(0x000000, 1, context.temp_allocator)
	}

	fmt.sbprintf(
		&b,
		"Style: Default,%s,%d,%s,%s,%s,%s,%d,0,0,0,100,100,0,0,%d,%.1f,%.1f,%d,%d,%d,%d,1\n\n",
		st.font,
		int(math.round(f64(st.size))),
		ass_colour(st.fill, 1, context.temp_allocator),
		ass_colour(st.fill, 1, context.temp_allocator),
		outline_col,
		back_col,
		st.bold ? -1 : 0,
		border_style,
		outline,
		shadow,
		ass_alignment(st.pos),
		st.margin_x,
		st.margin_x,
		st.margin_y,
	)

	strings.write_string(&b, "[Events]\n")
	strings.write_string(
		&b,
		"Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n",
	)
	for s in segs {
		body := ass_body(seg_text(s), context.temp_allocator)
		if body == "" {
			continue
		}
		fmt.sbprintf(
			&b,
			"Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n",
			ass_timecode(s.start, context.temp_allocator),
			ass_timecode(s.end, context.temp_allocator),
			body,
		)
	}
	return strings.to_string(b)
}

// render writes whichever format was asked for.
render_subtitles :: proc(
	f: Format,
	segs: []Seg,
	st: Caption_Style,
	play_w, play_h: int,
	al := context.temp_allocator,
) -> string {
	switch f {
	case .SRT:
		return write_srt(segs, al)
	case .VTT:
		return write_vtt(segs, al)
	case .ASS:
		return write_ass(segs, st, play_w, play_h, al)
	case .TXT:
		return write_txt(segs, al)
	}
	return ""
}

save_subtitles :: proc(
	path: string,
	f: Format,
	segs: []Seg,
	st: Caption_Style,
	play_w, play_h: int,
) -> (
	ok: bool,
	err: string,
) {
	text := render_subtitles(f, segs, st, play_w, play_h, context.temp_allocator)
	werr := os.write_entire_file(path, transmute([]u8)text)
	if werr != nil {
		return false, fmt.tprintf("%v", werr)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Reading
//
// Importing SRT and WebVTT closes the loop: captions written here can be
// reopened here, and subtitles produced by anything else can be edited here.
// ---------------------------------------------------------------------------

// parse_cues reads SRT or WebVTT. It is deliberately forgiving — a numeric
// index line is optional, cue identifiers are skipped, `WEBVTT`, `NOTE` and
// `STYLE` blocks are ignored, and CRLF is tolerated.
parse_cues :: proc(src: string, al := context.allocator) -> (segs: [dynamic]Seg, err: string) {
	segs = make([dynamic]Seg, al)
	lines := strings.split_lines(src, context.temp_allocator)

	i := 0
	for i < len(lines) {
		line := strings.trim_space(lines[i])
		i += 1
		if line == "" {
			continue
		}
		arrow := strings.index(line, "-->")
		if arrow < 0 {
			continue // index, cue id, WEBVTT header, NOTE — all skippable
		}

		left := strings.trim_space(line[:arrow])
		// WebVTT puts cue settings after the end time, space separated.
		right_all := strings.trim_space(line[arrow + 3:])
		right := right_all
		if sp := strings.index_any(right_all, " \t"); sp >= 0 {
			right = right_all[:sp]
		}

		start, ok_a := parse_timecode(left)
		end, ok_b := parse_timecode(right)
		if !ok_a || !ok_b {
			continue
		}

		body := strings.builder_make(context.temp_allocator)
		first := true
		for i < len(lines) {
			t := strings.trim_right_space(lines[i])
			if strings.trim_space(t) == "" {
				i += 1
				break
			}
			if !first {
				strings.write_byte(&body, '\n')
			}
			strings.write_string(&body, unescape_vtt(t, context.temp_allocator))
			first = false
			i += 1
		}

		append(&segs, seg_make(start, max(end, start), strings.to_string(body)))
	}

	if len(segs) == 0 {
		return segs, "no cues found"
	}
	return segs, ""
}

unescape_vtt :: proc(s: string, al := context.temp_allocator) -> string {
	if !strings.contains(s, "&") {
		return s
	}
	out, _ := strings.replace_all(s, "&lt;", "<", al)
	out, _ = strings.replace_all(out, "&gt;", ">", al)
	out, _ = strings.replace_all(out, "&amp;", "&", al)
	return out
}

load_cues :: proc(path: string, al := context.allocator) -> (segs: [dynamic]Seg, err: string) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return nil, fmt.tprintf("cannot read %s", path)
	}
	return parse_cues(string(data), al)
}
