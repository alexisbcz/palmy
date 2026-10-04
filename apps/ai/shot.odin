package main

// `ai --shots <dir>`: render the window offscreen and write PNGs.
//
// Nothing here opens a socket. The window's own code path polls ollama on a
// worker thread, so a screenshot run must not go anywhere near `probe_refresh`
// or `start_generation`; instead the probe is filled in directly with a
// fixture, which is the same structure the worker publishes. Nothing here
// reads the user's conversations either: `conv_load_all`, `settings_load` and
// `prompts_load` are all skipped, and `XDG_DATA_HOME` is pointed at the output
// directory so that any write the frame provokes lands there and not in
// ~/.local/share/palmy-ai.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// shot_load_fonts loads exactly the faces `kit.start` gives a window, so the
// PNG is in the same type as the real interface.
shot_load_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

SHOT_REPLY ::
	"A software rasteriser is fast for one reason: it never leaves the cache it is already in.\n\n" +
	"- **Spans, not pixels.** A filled rectangle is one `memset` per row, so the inner loop is a write of 64 bytes at a time rather than a branch per pixel.\n" +
	"- **One buffer.** The window is a `[]u32` the compositor maps; there is no upload, no fence and no driver between the loop and the screen.\n" +
	"- **Coverage is a byte.** Anti-aliasing is an 8-bit mask multiplied into the span, which is a multiply-add the compiler vectorises on its own.\n\n" +
	"```odin\nfor y in y0 ..< y1 {\n\trow := px[y * stride:][:w]\n\tfor x in x0 ..< x1 {\n\t\trow[x] = blend(row[x], colour, cov[x])\n\t}\n}\n```\n\n" +
	"The cost that matters is the one you cannot see in that loop: *overdraw*. Painting the same pixel four times costs four times as much, which is why the layout pass computes a clip rectangle per node and the painter honours it.\n"

SHOT_REPLY_2 ::
	"Three things, in the order they bite:\n\n" +
	"1. Measure text once per frame and cache the advance table per face and size.\n" +
	"2. Clip early — a node outside the viewport should cost a rectangle test, not a glyph run.\n" +
	"3. Keep the blend in `u32` lanes; converting to float per pixel is what makes a rasteriser slow.\n"

// shot_state builds the application state a window would have after a few
// exchanges, with no file and no socket behind any of it.
shot_state :: proc() -> ^St {
	st := new(St)
	probe_init(&st.probe)
	stream_init(&st.chat)
	stream_init(&st.pull)
	st.input = make([dynamic]u8)
	st.pull_name = make([dynamic]u8)
	st.sys_buf = make([dynamic]u8)
	st.think_open = make(map[int]bool)
	st.model = strings.clone("qwen3:4b")
	st.pinned = true
	st.show_think = true
	st.pr = Params {
		temperature = 0.7,
		top_p       = 0.9,
		num_predict = 512,
		think       = true,
		system      = strings.clone("You are a careful assistant. Answer in British English and prefer short paragraphs."),
	}

	// The prompt library, which the window would have read from disk.
	st.prompts = make([dynamic]Prompt)
	for pr in ([?]Prompt {
		{"Explain like an engineer", "Explain the following as you would to a senior engineer: no analogies, no hedging, and say what you are unsure of."},
		{"Summarise", "Summarise the text below in at most five bullet points, keeping every number exact."},
		{"Review this Odin", "Review this Odin procedure for correctness and allocation mistakes. Quote the lines you mean."},
		{"Rewrite plainly", "Rewrite the passage in plain English, keeping the meaning and losing the jargon."},
		{"Name things", "Suggest five names for the thing described, each with one line saying what it implies."},
	}) {
		append(&st.prompts, Prompt{strings.clone(pr.name), strings.clone(pr.body)})
	}

	// What the probe thread would have published, as a fixture. No request is
	// ever made: these rows are written here and read by `probe_view`.
	for m in ([?]Model_Info {
		{"qwen3:4b", 2_600_000_000, "4.02B", "Q4_K_M", "qwen3", 40960, true},
		{"qwen3:0.6b", 522_000_000, "751.63M", "Q4_K_M", "qwen3", 40960, true},
		{"llama3.2:3b", 2_020_000_000, "3.21B", "Q4_K_M", "llama", 131072, false},
		{"gemma3:4b", 3_340_000_000, "4.30B", "Q4_K_M", "gemma3", 8192, false},
		{"nomic-embed-text:latest", 274_000_000, "137M", "F16", "nomic-bert", 2048, false},
	}) {
		append(&st.probe.models, m)
	}
	append(
		&st.probe.loaded,
		Loaded_Info{"qwen3:4b", 3_900_000_000, 3_900_000_000, 8192, "in 4 minutes"},
	)
	st.probe.version = strings.clone("0.12.3")
	st.probe.got = true

	// One conversation in the list, and a couple beside it so the sidebar is
	// a list rather than a single row.
	st.convs = make([dynamic]Conversation)
	c := Conversation {
		id      = strings.clone("shot-0001"),
		title   = strings.clone("Why a software rasteriser is fast"),
		model   = strings.clone("qwen3:4b"),
		created = 1,
		msgs    = make([dynamic]Message),
	}
	append(
		&c.msgs,
		Message{role = .User, text = strings.clone("Why is a software rasteriser fast enough for a desktop toolkit?")},
	)
	append(
		&c.msgs,
		Message {
			role  = .Assistant,
			model = strings.clone("qwen3:4b"),
			text  = strings.clone(SHOT_REPLY),
			think = strings.clone(
				"They are asking about throughput rather than correctness, so bandwidth first, then overdraw. Keep the code sample to the span loop.",
			),
			ttft  = 0.11,
			tps   = 94.3,
			in_n  = 46,
			out_n = 268,
		},
	)
	append(
		&c.msgs,
		Message{role = .User, text = strings.clone("What would you optimise next?")},
	)
	append(
		&c.msgs,
		Message {
			role  = .Assistant,
			model = strings.clone("qwen3:4b"),
			text  = strings.clone(SHOT_REPLY_2),
			think = strings.clone(
				"They want an ordering, not a list. Text measurement is the one that actually shows up in a profile, " +
				"so that goes first; clipping second because it is cheap to add; the u32 blend last, since it is " +
				"already true of this painter and is really a warning rather than a change.",
			),
			ttft  = 0.08,
			tps   = 101.6,
			in_n  = 332,
			out_n = 96,
		},
	)
	append(&st.convs, c)

	for t in ([?]string{"Odin allocators and temp", "Wayland surfaces, step by step", "A grep that knows about Odin"}) {
		append(
			&st.convs,
			Conversation {
				id      = strings.clone(fmt.tprintf("shot-%s", t[:4])),
				title   = strings.clone(t),
				model   = strings.clone("qwen3:0.6b"),
				created = 1,
				msgs    = make([dynamic]Message),
			},
		)
	}
	st.cur = 0

	// The stats strip reads the last reply's measured numbers.
	st.live = Snapshot {
		model    = "qwen3:4b",
		eval_n   = 96,
		eval_ns  = 945_000_000, // 96 tokens in 0.945 s — 101.6 tok/s
		prompt_n = 332,
		ttft     = 0.08,
		elapsed  = 1.03,
		load_ns  = 61_000_000,
		finished = true,
	}
	return st
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("ai --shots: cannot create %s", dir)
		return 1
	}
	// Anything the frame decides to persist lands here, not in the real
	// ~/.local/share/palmy-ai.
	_ = os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/.ai-shot-state", dir))

	sc.register_shadcn_theme(true) // the window opens dark
	p.set_text_gamma(1.8)

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-row bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_load_fonts(&off.fonts)

	st := shot_state()

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		build(ui, st)
		pick_overlay(ui, st)
		p.offscreen_end(off)
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// Three frames: wrapping and hit testing run against the previous one, so
	// a transcript is only settled once the layout has repeated.
	settle :: proc(off: ^p.Offscreen, st: ^St) {
		for _ in 0 ..< 3 {
			step(off, st)
		}
	}

	// 1. The conversation, with something half-typed in the composer.
	append(&st.input, "Show me the span loop with the clip rectangle folded in")
	st.caret = len(st.input)
	settle(off, st)
	shot(off, dir, "app-ai", &n)

	// 2. The model picker, which is the probe's model list.
	clear(&st.input)
	st.caret = 0
	st.overlay = .Models
	st.ov_sel = 0
	settle(off, st)
	shot(off, dir, "02-ai-models", &n)

	// 3. The prompt library.
	st.overlay = .Prompts
	st.ov_sel = 1
	settle(off, st)
	shot(off, dir, "03-ai-prompts", &n)

	// 4. The parameter panel beside the transcript.
	st.overlay = .None
	st.show_params = true
	st.param_sel = .Temperature
	settle(off, st)
	shot(off, dir, "04-ai-params", &n)

	// 5. The reasoning block opened, which is the thing this client has that
	//    a plain chat window does not.
	st.show_params = false
	st.think_open[3] = true
	settle(off, st)
	shot(off, dir, "05-ai-thinking", &n)

	fmt.printfln("ai --shots: %d PNGs in %s", n, dir)
	return 0
}
