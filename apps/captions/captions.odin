package main

// The caption model: a list of timed, editable segments, the operations an
// editor needs on them, and the two quality rules that separate captions a
// viewer can actually read from a dumped transcript.
//
// Timings are seconds as f64 throughout. Text is a `[dynamic]u8` because it is
// edited in place by the keystroke, and may contain `\n` for a line break
// inside one caption.

import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Seg :: struct {
	start, end: f64,
	text:       [dynamic]u8,
	// Mean token probability whisper reported for this segment, 0 when
	// unknown. Shown so a human knows which lines to check first.
	conf:       f32,
}

seg_make :: proc(start, end: f64, text: string) -> Seg {
	buf := make([dynamic]u8, 0, len(text) + 16)
	append(&buf, text)
	return Seg{start = start, end = end, text = buf}
}

seg_text :: proc(s: Seg) -> string {
	return string(s.text[:])
}

seg_destroy :: proc(s: ^Seg) {
	delete(s.text)
	s.text = nil
}

seg_set_text :: proc(s: ^Seg, text: string) {
	clear(&s.text)
	append(&s.text, text)
}

seg_duration :: proc(s: Seg) -> f64 {
	return max(0, s.end - s.start)
}

// ---------------------------------------------------------------------------
// Words
//
// whisper's `-ojf` output carries a timestamp per token. They are kept as a
// flat list for one job only: snapping a split to the word the caret is in, so
// the two halves get real times instead of a linear interpolation through the
// characters.
// ---------------------------------------------------------------------------

Word :: struct {
	start, end: f64,
	text:       string,
}

// word_time_at finds the start time of the word that covers `text_index` in a
// segment, by walking the words that fall inside the segment and matching them
// against the segment's own text. Returns ok = false when there is no word
// data, and the caller then interpolates.
word_time_at :: proc(words: []Word, s: Seg, text_index: int) -> (t: f64, ok: bool) {
	if len(words) == 0 {
		return 0, false
	}
	body := seg_text(s)
	if text_index <= 0 || text_index >= len(body) {
		return 0, false
	}

	// Count characters of non-space text before the caret: that is the
	// position in the concatenated word stream.
	target := 0
	for i in 0 ..< text_index {
		if body[i] != ' ' && body[i] != '\n' {
			target += 1
		}
	}

	// Only the words that fall inside this segment are candidates.
	inside := make([dynamic]Word, 0, 32, context.temp_allocator)
	for w in words {
		if w.end < s.start - 0.25 || w.start > s.end + 0.25 {
			continue
		}
		append(&inside, w)
	}

	seen := 0
	for w, i in inside {
		trimmed := strings.trim_space(w.text)
		n := 0
		for j in 0 ..< len(trimmed) {
			if trimmed[j] != ' ' {
				n += 1
			}
		}
		if seen + n > target {
			// The caret falls inside this word; snap to where it begins.
			return clamp(w.start, s.start, s.end), true
		}
		seen += n
		if seen == target {
			// The caret sits exactly between two words. The second caption
			// should appear when its first word is spoken, not during the
			// pause before it — so the next word's start wins, and the first
			// caption keeps the silence.
			if i + 1 < len(inside) {
				return clamp(inside[i + 1].start, s.start, s.end), true
			}
			return clamp(w.end, s.start, s.end), true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

// split_seg cuts segment `i` at a byte offset in its text. The split time is
// the start of the word the caret sits in when word timings are available, and
// a proportional interpolation otherwise; either way it is clamped so both
// halves keep a non-negative duration.
split_seg :: proc(segs: ^[dynamic]Seg, i: int, at: int, words: []Word) -> bool {
	if i < 0 || i >= len(segs) {
		return false
	}
	s := &segs[i]
	body := seg_text(s^)
	cut := clamp(at, 0, len(body))
	// Never produce an empty half.
	if strings.trim_space(body[:cut]) == "" || strings.trim_space(body[cut:]) == "" {
		return false
	}

	mid, ok := word_time_at(words, s^, cut)
	if !ok {
		frac := f64(cut) / f64(max(len(body), 1))
		mid = s.start + seg_duration(s^) * frac
	}
	mid = clamp(mid, s.start, s.end)

	left := strings.trim_space(body[:cut])
	right := strings.trim_space(body[cut:])

	new_end := s.end
	seg_set_text(s, left)
	s.end = mid

	b := seg_make(mid, new_end, right)
	b.conf = s.conf
	inject_at(segs, i + 1, b)
	return true
}

// merge_segs joins `i` with `i + 1`, which is the other half of split: the
// text is concatenated with a single space and the span covers both.
merge_segs :: proc(segs: ^[dynamic]Seg, i: int) -> bool {
	if i < 0 || i + 1 >= len(segs) {
		return false
	}
	a := &segs[i]
	b := segs[i + 1]
	left := strings.trim_space(seg_text(a^))
	right := strings.trim_space(seg_text(b))

	joined: string
	if left == "" {
		joined = right
	} else if right == "" {
		joined = left
	} else {
		joined = strings.concatenate({left, " ", right}, context.temp_allocator)
	}
	seg_set_text(a, joined)
	a.end = max(a.end, b.end)
	a.conf = (a.conf + b.conf) / 2

	bb := &segs[i + 1]
	seg_destroy(bb)
	ordered_remove(segs, i + 1)
	return true
}

// delete_seg removes a segment and frees its text.
delete_seg :: proc(segs: ^[dynamic]Seg, i: int) -> bool {
	if i < 0 || i >= len(segs) {
		return false
	}
	s := &segs[i]
	seg_destroy(s)
	ordered_remove(segs, i)
	return true
}

// insert_seg adds a blank caption after `i`, borrowing time from the gap that
// follows when there is one.
insert_seg :: proc(segs: ^[dynamic]Seg, i: int, duration: f64) -> int {
	start := f64(0)
	if i >= 0 && i < len(segs) {
		start = segs[i].end
	}
	end := start + duration
	if i + 1 < len(segs) {
		end = min(end, segs[i + 1].start)
		if end <= start {
			end = start + 0.5
		}
	}
	at := i + 1
	inject_at(segs, at, seg_make(start, end, ""))
	return at
}

// nudge_start moves a segment's in point, pushing no further back than the end
// of the previous caption and no further forward than its own out point minus
// a sixth of a second.
nudge_start :: proc(segs: ^[dynamic]Seg, i: int, by: f64, limits: Limits) {
	if i < 0 || i >= len(segs) {
		return
	}
	s := &segs[i]
	lo := f64(0)
	if i > 0 {
		lo = segs[i - 1].end
	}
	hi := s.end - limits.min_dur
	s.start = clamp(s.start + by, lo, max(lo, hi))
}

// nudge_end moves the out point, bounded by the next caption's in point.
nudge_end :: proc(segs: ^[dynamic]Seg, i: int, by: f64, limits: Limits, duration: f64) {
	if i < 0 || i >= len(segs) {
		return
	}
	s := &segs[i]
	hi := duration > 0 ? duration : s.end + by + 60
	if i + 1 < len(segs) {
		hi = min(hi, segs[i + 1].start)
	}
	lo := s.start + limits.min_dur
	s.end = clamp(s.end + by, min(lo, hi), hi)
}

// shift_seg slides a whole caption, keeping its duration.
shift_seg :: proc(segs: ^[dynamic]Seg, i: int, by: f64, duration: f64) {
	if i < 0 || i >= len(segs) {
		return
	}
	s := &segs[i]
	d := seg_duration(s^)
	lo := i > 0 ? segs[i - 1].end : 0
	hi := i + 1 < len(segs) ? segs[i + 1].start : (duration > 0 ? duration : s.end + 3600)
	start := clamp(s.start + by, lo, max(lo, hi - d))
	s.start = start
	s.end = start + d
}

// set_seg_times is the drag handler: it places both edges at once and keeps
// the neighbours intact.
set_seg_times :: proc(segs: ^[dynamic]Seg, i: int, start, end: f64, duration: f64) {
	if i < 0 || i >= len(segs) {
		return
	}
	s := &segs[i]
	lo := i > 0 ? segs[i - 1].end : 0
	hi := i + 1 < len(segs) ? segs[i + 1].start : (duration > 0 ? duration : end + 3600)
	a := clamp(min(start, end), lo, hi)
	b := clamp(max(start, end), a, hi)
	s.start = a
	s.end = b
}

// sort_segs restores chronological order, which editing timings can break.
sort_segs :: proc(segs: ^[dynamic]Seg) {
	slice.sort_by(segs[:], proc(a, b: Seg) -> bool {
		return a.start < b.start
	})
}

// seg_at returns the index of the caption covering `t`, or -1.
seg_at :: proc(segs: []Seg, t: f64) -> int {
	for s, i in segs {
		if t >= s.start && t < s.end {
			return i
		}
	}
	return -1
}

// auto_wrap re-breaks a caption's text at the line limit on word boundaries,
// which is the single most useful cleanup button in a caption editor.
auto_wrap :: proc(s: ^Seg, max_cpl: int, max_lines: int) {
	body := strings.trim_space(seg_text(s^))
	if body == "" {
		return
	}
	// Collapse existing breaks first, then re-flow.
	flat, _ := strings.replace_all(body, "\n", " ", context.temp_allocator)
	words := strings.fields(flat, context.temp_allocator)
	if len(words) == 0 {
		return
	}

	b := strings.builder_make(context.temp_allocator)
	line := 0
	line_len := 0
	for w in words {
		wl := utf8.rune_count(w)
		if line_len == 0 {
			strings.write_string(&b, w)
			line_len = wl
			continue
		}
		if line_len + 1 + wl <= max_cpl || line + 1 >= max_lines {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, w)
			line_len += 1 + wl
			continue
		}
		strings.write_byte(&b, '\n')
		line += 1
		strings.write_string(&b, w)
		line_len = wl
	}
	seg_set_text(s, strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Quality rules
//
// The numbers are the broadcast conventions: 42 characters a line, two lines,
// 17 characters a second of reading speed, a caption on screen for at least
// 5/6 of a second and at most seven, and a two-frame gap between captions.
// ---------------------------------------------------------------------------

Limits :: struct {
	max_cpl:   int,
	max_lines: int,
	max_cps:   f64,
	min_dur:   f64,
	max_dur:   f64,
	min_gap:   f64,
}

default_limits :: proc() -> Limits {
	return Limits {
		max_cpl = 42,
		max_lines = 2,
		max_cps = 17,
		min_dur = 0.833,
		max_dur = 7.0,
		min_gap = 0.083,
	}
}

Warn_Kind :: enum {
	Empty,
	Long_Line,
	Too_Many_Lines,
	Too_Fast,
	Too_Short,
	Too_Long,
	Overlap,
	Tight_Gap,
}

Warns :: bit_set[Warn_Kind]

// visible_chars counts what a reader actually reads: runes, line breaks not
// included, which is the denominator both the CPL and CPS rules use.
visible_chars :: proc(text: string) -> int {
	n := 0
	for r in text {
		if r != '\n' && r != '\r' {
			n += 1
		}
	}
	return n
}

longest_line :: proc(text: string) -> (longest: int, lines: int) {
	lines = 1
	cur := 0
	for r in text {
		if r == '\n' {
			longest = max(longest, cur)
			cur = 0
			lines += 1
			continue
		}
		if r == '\r' {
			continue
		}
		cur += 1
	}
	longest = max(longest, cur)
	return
}

// cps is the reading speed in characters per second.
cps :: proc(s: Seg) -> f64 {
	d := seg_duration(s)
	if d <= 0.001 {
		return 0
	}
	return f64(visible_chars(seg_text(s))) / d
}

seg_warnings :: proc(segs: []Seg, i: int, limits: Limits) -> Warns {
	w: Warns
	if i < 0 || i >= len(segs) {
		return w
	}
	s := segs[i]
	body := strings.trim_space(seg_text(s))
	if body == "" {
		w += {.Empty}
	}
	longest, lines := longest_line(body)
	if longest > limits.max_cpl {
		w += {.Long_Line}
	}
	if lines > limits.max_lines {
		w += {.Too_Many_Lines}
	}
	if body != "" && cps(s) > limits.max_cps {
		w += {.Too_Fast}
	}
	d := seg_duration(s)
	if d < limits.min_dur {
		w += {.Too_Short}
	}
	if d > limits.max_dur {
		w += {.Too_Long}
	}
	if i + 1 < len(segs) {
		gap := segs[i + 1].start - s.end
		// A gap of exactly zero is what continuous speech produces and is
		// correct; what is wrong is a sliver — a few frames of blank between
		// two captions, which reads as a flicker. So only a non-zero gap
		// below the minimum is flagged.
		if gap < 0 {
			w += {.Overlap}
		} else if gap > 0.0005 && gap < limits.min_gap {
			w += {.Tight_Gap}
		}
	}
	return w
}

warn_text :: proc(k: Warn_Kind, limits: Limits) -> string {
	switch k {
	case .Empty:
		return "no text"
	case .Long_Line:
		return "line over the character limit"
	case .Too_Many_Lines:
		return "more lines than the limit"
	case .Too_Fast:
		return "reading speed above the limit"
	case .Too_Short:
		return "on screen too briefly"
	case .Too_Long:
		return "on screen too long"
	case .Overlap:
		return "overlaps the next caption"
	case .Tight_Gap:
		return "a sliver of a gap to the next caption"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Accuracy, for the self test
// ---------------------------------------------------------------------------

// normalise lowercases, strips punctuation and collapses whitespace, which is
// the only fair way to compare a transcript against a sentence someone typed.
normalise :: proc(text: string, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	prev_space := true
	for r in text {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			strings.write_rune(&b, unicode.to_lower(r))
			prev_space = false
			continue
		}
		if !prev_space {
			strings.write_byte(&b, ' ')
			prev_space = true
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// word_error_rate is the Levenshtein distance over words divided by the
// reference length — the standard speech-recognition measure. Reported rather
// than hidden: whisper gets words wrong, and a test that pretends otherwise is
// not a test.
word_error_rate :: proc(reference, hypothesis: string) -> (rate: f64, edits: int, ref_n: int) {
	ref := strings.fields(normalise(reference, context.temp_allocator), context.temp_allocator)
	hyp := strings.fields(normalise(hypothesis, context.temp_allocator), context.temp_allocator)
	if len(ref) == 0 {
		return len(hyp) == 0 ? 0 : 1, len(hyp), 0
	}

	prev := make([]int, len(hyp) + 1, context.temp_allocator)
	cur := make([]int, len(hyp) + 1, context.temp_allocator)
	for j in 0 ..= len(hyp) {
		prev[j] = j
	}
	for i in 1 ..= len(ref) {
		cur[0] = i
		for j in 1 ..= len(hyp) {
			cost := ref[i - 1] == hyp[j - 1] ? 0 : 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		copy(prev, cur)
	}
	edits = prev[len(hyp)]
	return f64(edits) / f64(len(ref)), edits, len(ref)
}

// ---------------------------------------------------------------------------
// Styling
// ---------------------------------------------------------------------------

Position :: enum {
	Bottom,
	Bottom_Left,
	Bottom_Right,
	Middle,
	Top,
	Top_Left,
	Top_Right,
}

position_name :: proc(p: Position) -> string {
	switch p {
	case .Bottom:
		return "Bottom centre"
	case .Bottom_Left:
		return "Bottom left"
	case .Bottom_Right:
		return "Bottom right"
	case .Middle:
		return "Middle"
	case .Top:
		return "Top centre"
	case .Top_Left:
		return "Top left"
	case .Top_Right:
		return "Top right"
	}
	return ""
}

// Caption_Style is what the preview draws and what the ASS style line carries.
// Sizes are in source-video pixels, so PlayResX/PlayResY in the ASS script
// makes the burn-in match the preview.
Caption_Style :: struct {
	font:        string,
	size:        f32,
	bold:        bool,
	fill:        u32, // 0xRRGGBB
	outline_rgb: u32,
	outline:     f32,
	shadow:      f32,
	box:         bool,
	box_rgb:     u32,
	box_opacity: f32,
	box_pad:     f32,
	pos:         Position,
	margin_x:    int,
	margin_y:    int,
}

default_style :: proc() -> Caption_Style {
	return Caption_Style {
		font = "DejaVu Sans",
		size = 54,
		bold = true,
		fill = 0xffffff,
		outline_rgb = 0x000000,
		outline = 2.5,
		shadow = 1,
		box = false,
		box_rgb = 0x000000,
		box_opacity = 0.55,
		box_pad = 6,
		pos = .Bottom,
		margin_x = 48,
		margin_y = 54,
	}
}

// force_style is the escaped parameter list for ffmpeg's `subtitles` filter,
// used when burning an SRT in rather than an ASS. ASS carries its own styling,
// so this is the fallback path.
force_style :: proc(st: Caption_Style, al := context.temp_allocator) -> string {
	b := strings.builder_make(al)
	strings.write_string(&b, "FontName=")
	strings.write_string(&b, st.font)
	strings.write_string(&b, ",FontSize=")
	write_int(&b, int(math.round(f64(st.size))))
	strings.write_string(&b, ",PrimaryColour=")
	strings.write_string(&b, ass_colour(st.fill, 1, context.temp_allocator))
	strings.write_string(&b, ",OutlineColour=")
	// As in write_ass: with BorderStyle 3 the box is drawn in OutlineColour,
	// and BackColour is only the shadow.
	if st.box {
		strings.write_string(&b, ass_colour(st.box_rgb, st.box_opacity, context.temp_allocator))
	} else {
		strings.write_string(&b, ass_colour(st.outline_rgb, 1, context.temp_allocator))
	}
	strings.write_string(&b, ",BackColour=")
	strings.write_string(&b, ass_colour(0x000000, 1, context.temp_allocator))
	strings.write_string(&b, ",BorderStyle=")
	write_int(&b, st.box ? 3 : 1)
	strings.write_string(&b, ",Bold=")
	write_int(&b, st.bold ? 1 : 0)
	strings.write_string(&b, ",Alignment=")
	write_int(&b, ass_alignment(st.pos))
	strings.write_string(&b, ",MarginV=")
	write_int(&b, st.margin_y)
	return strings.to_string(b)
}

@(private = "file")
write_int :: proc(b: ^strings.Builder, v: int) {
	buf: [24]u8
	n := v
	neg := n < 0
	if neg {
		n = -n
	}
	i := len(buf)
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	strings.write_string(b, string(buf[i:]))
}
