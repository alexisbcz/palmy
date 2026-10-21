package main

// `captions --shot out.png [media] [options]` renders the interface into a PNG
// with no compositor involved.
//
// palmy runs its whole UI offscreen, which is how it tests itself — and it is
// the only way to check a layout on a machine whose tiling compositor decides
// the window size for you. Everything is real here: the file is really probed,
// the waveform really decoded, the transcription really run. Only the window
// is missing.
//
//   --pane transcribe|captions|style|export
//   --transcribe         run whisper before rendering
//   --editing            put the caret in the selected caption
//   --box                turn the background box on
//   --karaoke            light the words already spoken at the playhead
//   --help-overlay       draw the keyboard overlay
//   --size WxH

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

shot_main :: proc(args: []string) -> int {
	out := ""
	media := ""
	pane := Pane.Transcribe
	do_transcribe := false
	editing := false
	overlay := false
	box := false
	karaoke := false
	w, h := 1380, 900

	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--shot":
			i += 1
			if i < len(args) {
				out = args[i]
			}
		case a == "--pane":
			i += 1
			if i < len(args) {
				switch strings.to_lower(args[i], context.temp_allocator) {
				case "transcribe":
					pane = .Transcribe
				case "captions":
					pane = .Captions
				case "style":
					pane = .Style
				case "export":
					pane = .Export
				}
			}
		case a == "--size":
			i += 1
			if i < len(args) {
				parts := strings.split(args[i], "x", context.temp_allocator)
				if len(parts) == 2 {
					w, _ = strconv.parse_int(parts[0])
					h, _ = strconv.parse_int(parts[1])
				}
			}
		case a == "--transcribe":
			do_transcribe = true
		case a == "--editing":
			editing = true
		case a == "--box":
			box = true
		case a == "--karaoke":
			karaoke = true
		case a == "--help-overlay":
			overlay = true
		case !strings.has_prefix(a, "-"):
			media = a
		}
		i += 1
	}
	if out == "" {
		fmt.eprintln("--shot needs an output path")
		return 1
	}

	m := new(App_State)
	state_init(m)
	m.pane = pane
	m.help = overlay
	m.style.box = box
	m.style.karaoke = karaoke

	// The import and the transcription are the jobs the window runs on a
	// thread; here they are simply called in order, because there is no frame
	// loop to keep responsive.
	if media != "" {
		media = normal_path(media, context.allocator)
		info, err := probe(media, context.allocator)
		if err != "" {
			fmt.eprintfln("shot: %s", err)
			return 1
		}
		m.info = info
		m.loaded = true
		m.view_span = info.duration
		wav := work_path("shot-audio.wav", context.allocator)
		if ok, werr := extract_wav(media, wav); !ok {
			fmt.eprintfln("shot: %s", werr)
			return 1
		}
		m.wav = wav
		decode_peaks(media, work_path("shot-audio.raw"), m.peaks)
		m.pos = min(info.duration * 0.35, info.duration)

		if info.has_video {
			frame := work_path("shot-frame.png", context.allocator)
			if ok, _ := grab_frame(media, m.pos, frame, 640); ok {
				if img, got := p.load_image(frame); got {
					m.preview = img
					m.preview_ok = true
					m.preview_t = m.pos
				}
			}
		}

		if do_transcribe && len(m.models) > 0 {
			mdl := m.models[clamp(m.model_i, 0, len(m.models) - 1)]
			argv := whisper_argv(
				Transcribe_Opts {
					model = mdl.path,
					lang = mdl.multilingual ? "en" : "",
					threads = m.threads,
					max_len = m.max_len,
					split_word = m.split_word,
					wav = wav,
					out_prefix = work_path("shot-transcript"),
				},
				context.temp_allocator,
			)
			fmt.eprintfln("shot: transcribing %s with %s…", media, mdl.name)
			t0 := time.tick_now()
			kit.run(argv, context.temp_allocator)
			decode_sec := time.duration_seconds(time.tick_since(t0))
			tr, terr := load_transcript(
				fmt.tprintf("%s.json", work_path("shot-transcript")),
				context.allocator,
			)
			if terr != "" {
				fmt.eprintfln("shot: %s", terr)
			} else {
				for s in tr.segs {
					append(&m.segs, s)
				}
				for wd in tr.words {
					append(&m.words, wd)
				}
				m.sel = 0
				m.transcribed = true
				m.decode_sec = decode_sec
				m.rtf = info.duration / max(decode_sec, 0.0001)
				m.heard_lang = tr.lang
				// Put the playhead inside a caption so the preview and the
				// row highlight both have something to show.
				if len(m.segs) > 1 {
					m.sel = 1
					mid := (m.segs[1].start + m.segs[1].end) / 2
					m.pos = mid
					if info.has_video {
						frame := work_path("shot-frame2.png", context.allocator)
						if ok, _ := grab_frame(media, mid, frame, 640); ok {
							if img, got := p.load_image(frame); got {
								if m.preview_ok {
									p.image_destroy(&m.preview)
								}
								m.preview = img
								m.preview_ok = true
								m.preview_t = mid
							}
						}
					}
				}
			}
		}
	}
	if m.loaded {
		streams := fmt.tprintf("audio only, %s", m.info.acodec)
		if m.info.has_video {
			streams = fmt.tprintf("%dx%d %s", m.info.width, m.info.height, m.info.vcodec)
		}
		set_status(
			m,
			fmt.tprintf("%s · %s · %s", base_name(m.info.path), clock(m.info.duration), streams),
			false,
		)
	}
	if editing && m.sel >= 0 {
		m.focus = .Caption
		m.caret = len(m.segs[m.sel].text) / 2
	}

	off := p.offscreen_create(w, h, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
			"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
			"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
			"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
		}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)

	// Two frames: hit testing, scrolling and the caret measurement all read
	// the previous frame's geometry, so a single pass would draw a layout that
	// has never seen itself.
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		draw(ui, &off.fonts, m)
		p.offscreen_end(off)
	}

	if !p.offscreen_write_png(off, out) {
		fmt.eprintfln("shot: could not write %s", out)
		return 1
	}
	fmt.printfln("wrote %s (%dx%d)", out, w, h)
	return 0
}
