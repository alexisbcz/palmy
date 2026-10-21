package main

// Speech to text, locally, through whisper.cpp's `whisper-cli`.
//
// Nothing here leaves the machine. The binary is on PATH, the weights are a
// file on disk, and the only output is a JSON file in the cache directory.
//
// `whisper-cli` is run rather than linked because libwhisper would drag a
// C++ runtime and a BLAS into a toolkit whose whole premise is `ldd` printing
// three lines. The cost is a process and a JSON parse per transcription, which
// against a decoder that takes seconds is nothing.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

WHISPER_BIN :: "whisper-cli"

// LANGUAGES is the subset worth offering in a picker. `auto` asks whisper to
// detect, which only multilingual models can do.
Language :: struct {
	code: string,
	name: string,
}

LANGUAGES := [?]Language {
	{"auto", "Detect automatically"},
	{"en", "English"},
	{"fr", "French"},
	{"de", "German"},
	{"es", "Spanish"},
	{"it", "Italian"},
	{"pt", "Portuguese"},
	{"nl", "Dutch"},
	{"pl", "Polish"},
	{"ru", "Russian"},
	{"uk", "Ukrainian"},
	{"tr", "Turkish"},
	{"ar", "Arabic"},
	{"hi", "Hindi"},
	{"zh", "Chinese"},
	{"ja", "Japanese"},
	{"ko", "Korean"},
}

Transcribe_Opts :: struct {
	model:       string, // path to the ggml weights
	lang:        string, // "en", "auto", ...
	threads:     int,
	max_len:     int, // characters per segment, 0 to let whisper decide
	split_word:  bool,
	translate:   bool,
	diarize:     bool, // -tdrz, with a tinydiarize model
	vad:         bool,
	vad_model:   string,
	// Where the WAV lives and where the JSON goes (without its extension).
	wav:         string,
	out_prefix:  string,
	log:         string,
}

// whisper_argv builds the command line. It is a separate procedure so the self
// test can assert on it without running a decoder.
whisper_argv :: proc(o: Transcribe_Opts, al := context.temp_allocator) -> []string {
	a := make([dynamic]string, al)
	append(&a, WHISPER_BIN)
	append(&a, "-m", o.model)
	append(&a, "-f", o.wav)
	// -ojf is the full JSON: segments *and* a timestamp per token, which is
	// what lets a split land on a word boundary rather than between two
	// characters.
	append(&a, "-ojf")
	append(&a, "-of", o.out_prefix)
	append(&a, "-np") // no banner; the segment lines are all we scrape
	append(&a, "-pp") // progress percentages
	append(&a, "-t", fmt.aprintf("%d", max(1, o.threads), allocator = al))
	if o.lang != "" {
		append(&a, "-l", o.lang)
	}
	if o.max_len > 0 {
		append(&a, "-ml", fmt.aprintf("%d", o.max_len, allocator = al))
		if o.split_word {
			append(&a, "-sow")
		}
	}
	if o.translate {
		append(&a, "-tr")
	}
	if o.diarize {
		append(&a, "-tdrz")
	}
	if o.vad && o.vad_model != "" {
		append(&a, "--vad", "-vm", o.vad_model)
	}
	return a[:]
}

// ---------------------------------------------------------------------------
// Parsing the result
// ---------------------------------------------------------------------------

Transcript :: struct {
	segs:  [dynamic]Seg,
	words: [dynamic]Word,
	lang:  string,
}

@(private = "file")
obj_get :: proc(v: json.Value, key: string) -> (out: json.Value, ok: bool) {
	o, is_obj := v.(json.Object)
	if !is_obj {
		return nil, false
	}
	out, ok = o[key]
	return
}

@(private = "file")
num_of :: proc(v: json.Value) -> (f: f64, ok: bool) {
	#partial switch n in v {
	case json.Integer:
		return f64(n), true
	case json.Float:
		return f64(n), true
	case json.String:
		return strconv.parse_f64(n)
	}
	return 0, false
}

@(private = "file")
str_of :: proc(v: json.Value) -> (s: string, ok: bool) {
	t, is := v.(json.String)
	return string(t), is
}

// offsets_of reads the `{"offsets": {"from": ms, "to": ms}}` pair whisper
// writes on both segments and tokens. Milliseconds, so it is exact.
@(private = "file")
offsets_of :: proc(v: json.Value) -> (from, to: f64, ok: bool) {
	off, got := obj_get(v, "offsets")
	if !got {
		return
	}
	fv, got_f := obj_get(off, "from")
	tv, got_t := obj_get(off, "to")
	if !got_f || !got_t {
		return
	}
	a, ok_a := num_of(fv)
	b, ok_b := num_of(tv)
	if !ok_a || !ok_b {
		return
	}
	return a / 1000, b / 1000, true
}

// parse_transcript reads whisper's JSON. The token list is kept separately
// from the segments: a special token like `[_BEG_]` carries no text and a
// sub-word piece is not a word, so the stream is reassembled into words by
// joining pieces that do not start with a space.
parse_transcript :: proc(
	data: string,
	al := context.allocator,
) -> (
	tr: Transcript,
	err: string,
) {
	root, perr := json.parse_string(data, .JSON, false, context.temp_allocator)
	if perr != .None {
		return tr, fmt.tprintf("whisper's JSON would not parse (%v)", perr)
	}

	tr.segs = make([dynamic]Seg, al)
	tr.words = make([dynamic]Word, al)

	if res, got := obj_get(root, "result"); got {
		if lv, got_l := obj_get(res, "language"); got_l {
			if s, is := str_of(lv); is {
				tr.lang = strings.clone(s, al)
			}
		}
	}

	tv, got := obj_get(root, "transcription")
	if !got {
		return tr, "whisper's JSON has no transcription array"
	}
	arr, is_arr := tv.(json.Array)
	if !is_arr {
		return tr, "whisper's transcription is not an array"
	}

	// tinydiarize puts `"speaker_turn_next": true` on the segment *before* a
	// change of speaker; the caption that gets the mark is the one after.
	turn_next := false
	for item in arr {
		from, to, ok := offsets_of(item)
		if !ok {
			continue
		}
		turn_here := turn_next
		turn_next = false
		if tv, got_tv := obj_get(item, "speaker_turn_next"); got_tv {
			if b, is_b := tv.(json.Boolean); is_b && bool(b) {
				turn_next = true
			}
		}
		text_v, got_text := obj_get(item, "text")
		if !got_text {
			continue
		}
		raw, is_s := str_of(text_v)
		if !is_s {
			continue
		}
		body := strings.trim_space(raw)
		if body == "" {
			turn_next = turn_next || turn_here // the change carries to the next caption
			continue
		}

		seg := seg_make(from, max(to, from), body)
		seg.turn = turn_here

		// Average token probability, skipping the specials, as a confidence.
		psum, pn := f64(0), 0
		if toks_v, got_toks := obj_get(item, "tokens"); got_toks {
			if toks, is_t := toks_v.(json.Array); is_t {
				pending := strings.builder_make(context.temp_allocator)
				pend_start, pend_end := f64(0), f64(0)
				has_pending := false

				for t in toks {
					tt_v, got_tt := obj_get(t, "text")
					if !got_tt {
						continue
					}
					tt, is_tt := str_of(tt_v)
					if !is_tt || tt == "" {
						continue
					}
					if strings.has_prefix(tt, "[_") {
						continue // [_BEG_], [_TT_xx] and friends
					}
					tf, tto, ok_t := offsets_of(t)
					if !ok_t {
						continue
					}
					if pv, got_p := obj_get(t, "p"); got_p {
						if p, ok_p := num_of(pv); ok_p {
							psum += p
							pn += 1
						}
					}

					starts_word := strings.has_prefix(tt, " ")
					if starts_word && has_pending {
						append(
							&tr.words,
							Word {
								start = pend_start,
								end = pend_end,
								text = strings.clone(
									strings.trim_space(strings.to_string(pending)),
									al,
								),
							},
						)
						strings.builder_reset(&pending)
						has_pending = false
					}
					if !has_pending {
						pend_start = tf
						has_pending = true
					}
					pend_end = max(tto, tf)
					strings.write_string(&pending, tt)
				}
				if has_pending {
					w := strings.trim_space(strings.to_string(pending))
					if w != "" {
						append(
							&tr.words,
							Word {
								start = pend_start,
								end = pend_end,
								text = strings.clone(w, al),
							},
						)
					}
				}
			}
		}
		if pn > 0 {
			seg.conf = f32(psum / f64(pn))
		}
		append(&tr.segs, seg)
	}

	if len(tr.segs) == 0 {
		return tr, "whisper produced no speech segments — is there speech in this file?"
	}
	return tr, ""
}

load_transcript :: proc(path: string, al := context.allocator) -> (tr: Transcript, err: string) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return tr, fmt.tprintf("whisper wrote no JSON at %s", path)
	}
	return parse_transcript(string(data), al)
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

// progress_from_log reads whatever whisper has printed so far and works out
// how far through it is. There are two signals and the better one wins:
//
//   - `[00:01:23.000 --> 00:01:27.480]` lines, printed as each segment is
//     decoded. The last end time over the media duration is the true
//     fraction, and it is accurate on a file of any length.
//   - `progress = NN%`, which whisper prints per 30-second window and which
//     is all there is before the first segment comes out.
progress_from_log :: proc(text: string, duration: f64) -> f32 {
	best := f32(0)
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "[") {
			arrow := strings.index(l, "-->")
			close := strings.index(l, "]")
			if arrow > 0 && close > arrow {
				if t, ok := parse_timecode(strings.trim_space(l[arrow + 3:close])); ok &&
				   duration > 0 {
					best = max(best, f32(clamp(t / duration, 0, 1)))
				}
			}
			continue
		}
		if at := strings.index(l, "progress ="); at >= 0 {
			rest := strings.trim_space(l[at + len("progress ="):])
			rest = strings.trim_suffix(rest, "%")
			if v, ok := strconv.parse_f64(strings.trim_space(rest)); ok {
				best = max(best, f32(clamp(v / 100, 0, 1)))
			}
		}
	}
	return best
}

// last_segment_line is what the UI shows while a long file decodes: the text
// whisper most recently emitted, so there is something true moving on screen
// rather than only a bar.
last_segment_line :: proc(text: string, al := context.temp_allocator) -> string {
	out := ""
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "[") {
			continue
		}
		close := strings.index(l, "]")
		if close < 0 || close + 1 >= len(l) {
			continue
		}
		body := strings.trim_space(l[close + 1:])
		if body != "" {
			out = body
		}
	}
	return strings.clone(out, al)
}
