package main

// palmy ai — a desktop client for models running on this machine.
//
// Everything it talks to is ollama on 127.0.0.1:11434. There is no remote
// endpoint in the binary and no way to configure one: `http.odin` dials the
// loopback address as a literal. Conversations live under
// ~/.local/share/palmy-ai/ as plain text.
//
// The shape of the program:
//
//   main.odin     state, the frame loop, the keyboard, actions
//   http.odin     HTTP/1.1 and chunked/NDJSON framing over core:net
//   ollama.odin   the endpoints, the worker threads, the request bodies
//   md.odin       markdown tokenising and rendering
//   store.odin    conversations, settings and the prompt library on disk
//   ui.odin       the frame
//   selftest.odin the headless assertions (`ai --selftest`)
//
// Threading. The socket never touches the UI thread. A chat or a pull runs on
// a worker that publishes into a `Stream` through leaf procedures that lock,
// write and unlock; the frame takes one `Snapshot` per frame and draws from
// that, so the numbers on screen are always self-consistent. Cancellation is
// an atomic flag plus a 200ms receive timeout, so Esc stops a generation
// within a fifth of a second without the UI ever waiting on the worker.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

WIN_W :: 1280
WIN_H :: 820

SIDEBAR_W :: 248
PARAMS_W :: 268

Zone :: enum u8 {
	Composer,
	Chats,
	Params,
}

Overlay :: enum u8 {
	None,
	Models,
	Prompts,
	Pull,
	Confirm_Delete,
	System,
	Help,
}

Param_Row :: enum u8 {
	Temperature,
	Top_P,
	Num_Predict,
	Think,
	Reasoning,
}

St :: struct {
	probe:        Probe,
	chat:         Stream,
	pull:         Stream,

	convs:        [dynamic]Conversation,
	cur:          int,
	prompts:      [dynamic]Prompt,

	model:        string,
	pr:           Params,
	show_think:   bool,

	// The composer, which is a text editor this app owns: palmy's text_field
	// is single-line and a chat composer needs Shift+Enter.
	input:        [dynamic]u8,
	caret:        int,

	// Transcript scrolling.
	pinned:       bool,
	tr_id:        u64,
	end_id:       u64,

	// Element ids the headless layout test reads back after a frame. They
	// cost one assignment each and they are the only way to assert that a
	// chat window's fixed bands stay put when the transcript is ten times
	// taller than the window.
	composer_id:  u64,
	footer_id:    u64,
	main_id:      u64,

	zone:         Zone,
	overlay:      Overlay,
	ov_sel:       int,
	pull_name:    [dynamic]u8,
	sys_buf:      [dynamic]u8,
	param_sel:    Param_Row,
	show_params:  bool,

	// Streaming bookkeeping.
	streaming:    bool,
	live:         Snapshot,
	pulling:      bool,
	pull_live:    Snapshot,
	last_probe:   f64,
	think_open:   map[int]bool,

	toast:        string,
	toast_t:      f64,
	mouse:        [2]f32,
	moved:        bool,
	started:      bool,
	quit_at:      f64,

	// The shared file dialog, for attaching a file. See pick.odin.
	pick:         kit.Pick,
}

main :: proc() {
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" || a == "-selftest" {
			os.exit(run_selftest())
		}
		// `ai --shots <dir>` renders the window offscreen. See shot.odin: it
		// opens no socket and reads no conversation of the user's.
		if a == "--shots" || a == "-shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("ai: --shots needs a directory")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
		if a == "--help" || a == "-h" {
			fmt.println("palmy ai — a local model client.")
			fmt.println("  ai             open the window")
			fmt.println("  ai --selftest  run the headless assertions")
			fmt.println("  ai --shots <dir>  render the window to PNGs, no window and no socket")
			fmt.printfln("  talks only to %s", OLLAMA_URL)
			os.exit(0)
		}
	}

	app, err := kit.start(
		{
			title = "palmy ai",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 900,
			min_height = 560,
			root_class = "w-full h-full flex-row bg-background text-foreground overflow-hidden",
		},
		true, // dark: a model client is a tool you keep open next to an editor
	)
	if err != "" {
		fmt.eprintfln("ai: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	st := St {
		model      = strings.clone("qwen3:0.6b"),
		pinned     = true,
		show_think = true,
		pr         = Params {
			temperature = 0.7,
			top_p       = 0.9,
			num_predict = 512,
			think       = false,
			system      = strings.clone(""),
		},
	}
	probe_init(&st.probe)
	stream_init(&st.chat)
	stream_init(&st.pull)
	st.input = make([dynamic]u8)
	st.pull_name = make([dynamic]u8)
	st.sys_buf = make([dynamic]u8)
	st.think_open = make(map[int]bool)
	st.prompts = prompts_load()
	defer kit.pick_destroy(&st.pick)

	ensure_dirs()
	settings_load(&st.model, &st.pr, &st.show_think)
	st.convs = conv_load_all()
	if len(st.convs) == 0 {
		new_conversation(&st)
	}
	probe_refresh(&st.probe)
	st.last_probe = mono()

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		st.moved = st.started && st.mouse != p.mouse_pos(ui)
		st.mouse = p.mouse_pos(ui)
		st.started = true

		// One snapshot per frame, so every number drawn below agrees with
		// every other one.
		st.live = stream_snapshot(&st.chat, context.temp_allocator)
		st.pull_live = stream_snapshot(&st.pull, context.temp_allocator)

		if st.streaming {
			settle_stream(&st)
		}
		if st.pulling {
			settle_pull(&st)
		}

		// /api/ps and /api/tags are refreshed on the probe thread; nothing
		// below ever blocks on a socket.
		interval := st.streaming ? 1.2 : 6.0
		if mono() - st.last_probe > interval {
			st.last_probe = mono()
			probe_refresh(&st.probe)
		}

		handle_keys(ui, app, &st)
		build(ui, &st)
		pick_overlay(ui, &st)

		// A worker thread cannot wake palmy's `poll`, and there is no wake
		// descriptor to write to, so while anything is in flight the window
		// marks itself animating and paces to the display instead. This has
		// to come after the input handling: the frame that starts a stream is
		// the frame that must already be asking for the next one.
		if st.streaming || st.pulling {
			ui.animating = true
		}

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			} else {
				ui.animating = true
			}
		}
	}

	// Leave nothing generating behind us.
	stream_request_stop(&st.chat)
	stream_request_stop(&st.pull)
	for i in 0 ..< 25 {
		if !stream_is_running(&st.chat) && !stream_is_running(&st.pull) {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	settings_save(st.model, st.pr, st.show_think)
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

cur_conv :: proc(st: ^St) -> ^Conversation {
	if st.cur < 0 || st.cur >= len(st.convs) {
		return nil
	}
	return &st.convs[st.cur]
}

new_conversation :: proc(st: ^St) {
	c := Conversation {
		id      = new_id(time.time_to_unix(time.now())),
		title   = strings.clone("New conversation"),
		model   = strings.clone(st.model),
		created = time.time_to_unix(time.now()),
		msgs    = make([dynamic]Message),
	}
	inject_at(&st.convs, 0, c)
	st.cur = 0
	st.pinned = true
	clear(&st.think_open)
}

delete_conversation :: proc(st: ^St) {
	c := cur_conv(st)
	if c == nil {
		return
	}
	conv_delete_file(c.id)
	ordered_remove(&st.convs, st.cur)
	if len(st.convs) == 0 {
		new_conversation(st)
	} else {
		st.cur = clamp(st.cur, 0, len(st.convs) - 1)
	}
	clear(&st.think_open)
	toast(st, "Conversation deleted")
}

// ---------------------------------------------------------------------------
// Sending, stopping, settling
// ---------------------------------------------------------------------------

composer_text :: proc(st: ^St) -> string {
	return string(st.input[:])
}

send :: proc(st: ^St) {
	if st.streaming {
		return
	}
	text := strings.trim_space(composer_text(st))
	if text == "" {
		return
	}
	c := cur_conv(st)
	if c == nil {
		return
	}

	if len(c.msgs) == 0 {
		delete(c.title)
		c.title = title_from(text)
	}
	append(&c.msgs, Message{role = .User, text = strings.clone(text)})
	clear(&st.input)
	st.caret = 0

	start_generation(st)
}

// start_generation sends whatever history the conversation now holds and opens
// an assistant message for the reply to land in.
start_generation :: proc(st: ^St) {
	c := cur_conv(st)
	if c == nil || len(c.msgs) == 0 || st.streaming {
		return
	}
	append(
		&c.msgs,
		Message{role = .Assistant, model = strings.clone(st.model), text = strings.clone("")},
	)
	delete(c.model)
	c.model = strings.clone(st.model)

	history := c.msgs[:len(c.msgs) - 1]
	body := chat_body(st.model, history, st.pr)
	stream_start(&st.chat, "/api/chat", body, .Chat, st.model)
	st.streaming = true
	st.pinned = true
	conv_save(c)
}

stop_generation :: proc(st: ^St) {
	if !st.streaming {
		return
	}
	stream_request_stop(&st.chat)
	toast(st, "Stopping…")
}

// settle_stream commits a finished reply into the conversation. The worker has
// already stopped by the time `finished` is visible, so nothing races here.
settle_stream :: proc(st: ^St) {
	s := st.live
	if !s.finished {
		return
	}
	if stream_is_running(&st.chat) {
		// `finished` is published before the worker's last statement; wait
		// one more frame so the thread is genuinely gone.
		return
	}
	st.streaming = false

	c := cur_conv(st)
	if c != nil && len(c.msgs) > 0 {
		m := &c.msgs[len(c.msgs) - 1]
		if m.role == .Assistant {
			delete(m.text)
			delete(m.think)
			m.text = strings.clone(s.content)
			m.think = strings.clone(s.think)
			m.ttft = s.ttft
			m.in_n = s.prompt_n
			m.out_n = s.eval_n
			m.halted = s.stopped
			m.tps = s.eval_ns > 0 ? f32(f64(s.eval_n) / (f64(s.eval_ns) / 1e9)) : 0
			// An error belongs in the transcript, not only in a toast: it is
			// part of what happened in this conversation and it has to
			// survive a reload.
			if m.text == "" && s.err != "" {
				delete(m.text)
				m.text = fmt.aprintf(
					"**The request failed.** %s\n\nStart the runtime with:\n\n```sh\n%s\n```",
					s.err,
					START_HINT,
				)
			}

			// An empty answer is the one failure a chat client must explain
			// rather than draw as a blank bubble. With qwen3 the usual cause
			// is the whole token budget going into the reasoning block.
			if m.text == "" && s.err == "" {
				delete(m.text)
				switch {
				case s.stopped:
					m.text = strings.clone("_Stopped before the model produced an answer._")
				case m.think != "" && s.reason == "length":
					m.text = strings.clone(
						"_The reply limit (`num_predict`) was reached inside the reasoning block, so there is no answer. Raise num_predict in the parameter panel, or turn Thinking off with Ctrl+T._",
					)
				case m.think != "":
					m.text = strings.clone(
						"_The model reasoned but produced no answer. Turn Thinking off with Ctrl+T, or raise num_predict._",
					)
				case s.reason == "length":
					m.text = strings.clone("_The reply limit (`num_predict`) was reached._")
				case:
					m.text = strings.clone("_The model returned nothing._")
				}
			}
		}
		conv_save(c)
	}

	if s.err != "" {
		toast(st, s.err)
	} else if s.stopped {
		toast(st, fmt.tprintf("Stopped after %d tokens", s.eval_n))
	}
	st.last_probe = 0 // refresh /api/ps now that the model is resident
}

settle_pull :: proc(st: ^St) {
	if !st.pull_live.finished || stream_is_running(&st.pull) {
		return
	}
	st.pulling = false
	if st.pull_live.err != "" {
		toast(st, st.pull_live.err)
	} else {
		toast(st, fmt.tprintf("Pulled %s", st.pull_live.model))
		probe_refresh(&st.probe)
	}
}

regenerate :: proc(st: ^St) {
	if st.streaming {
		return
	}
	c := cur_conv(st)
	if c == nil || len(c.msgs) == 0 {
		return
	}
	// Drop trailing assistant messages, then ask again.
	for len(c.msgs) > 0 && c.msgs[len(c.msgs) - 1].role == .Assistant {
		m := c.msgs[len(c.msgs) - 1]
		delete(m.text);delete(m.think);delete(m.model)
		pop(&c.msgs)
	}
	if len(c.msgs) == 0 {
		return
	}
	start_generation(st)
	toast(st, "Regenerating")
}

// edit_last lifts the last user message back into the composer and forgets
// everything after it, which is the honest version of "edit and resend".
edit_last :: proc(st: ^St) {
	if st.streaming {
		return
	}
	c := cur_conv(st)
	if c == nil {
		return
	}
	for i := len(c.msgs) - 1; i >= 0; i -= 1 {
		if c.msgs[i].role != .User {
			continue
		}
		clear(&st.input)
		append(&st.input, ..transmute([]u8)c.msgs[i].text)
		st.caret = len(st.input)
		for j := len(c.msgs) - 1; j >= i; j -= 1 {
			m := c.msgs[j]
			delete(m.text);delete(m.think);delete(m.model)
			pop(&c.msgs)
		}
		conv_save(c)
		st.zone = .Composer
		toast(st, "Edit and press Enter to resend")
		return
	}
}

copy_last :: proc(st: ^St) {
	c := cur_conv(st)
	if c == nil {
		return
	}
	for i := len(c.msgs) - 1; i >= 0; i -= 1 {
		if c.msgs[i].role == .Assistant {
			text := st.streaming && i == len(c.msgs) - 1 ? st.live.content : c.msgs[i].text
			if kit.clipboard_set(text) {
				toast(st, fmt.tprintf("Copied %d characters", len(text)))
			} else {
				toast(st, "wl-copy is not installed, so there is no clipboard")
			}
			return
		}
	}
}

toast :: proc(st: ^St, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_t = mono() + 3.5
}

// ---------------------------------------------------------------------------
// The keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	// The file dialog owns the keyboard while it is up; it reads its own
	// input in `pick_overlay`, during the draw pass.
	if kit.pick_active(&st.pick) {
		return
	}
	// Ctrl+Shift+O, not Ctrl+O: this application already binds Ctrl+O to
	// pulling a model, and a shared component arriving late does not get to
	// take a key that already means something.
	if p.shortcut(ui, 'o', {.Ctrl, .Shift}) || p.shortcut(ui, 'O', {.Ctrl, .Shift}) {
		begin_attach(st)
		return
	}
	if st.overlay != .None {
		overlay_keys(ui, app, st)
		return
	}

	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}

	// Esc is the stop key first and foremost: a generation you cannot
	// interrupt is a generation you cannot trust.
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if st.streaming {
			stop_generation(st)
		} else if st.pulling {
			stream_request_stop(&st.pull)
		}
		return
	}

	if p.key_pressed(ui, p.KEY_TAB) {
		back := .Shift in ui.input.mods
		n := 3
		cur := int(st.zone)
		for i in 0 ..< n {
			cur = (cur + (back ? -1 : 1) + n) % n
			if Zone(cur) == .Params && !st.show_params {
				continue
			}
			break
		}
		st.zone = Zone(cur)
		return
	}

	// The function keys duplicate the Ctrl bindings. They are not decoration:
	// the demo recorder drives this machine through `wtype -k <name>`, which
	// has no way to hold a modifier, so every action worth filming needs one
	// unmodified key.
	if p.shortcut(ui, 'n', {.Ctrl}) || p.key_pressed(ui, p.KEY_F2) {
		new_conversation(st)
		return
	}
	if p.shortcut(ui, 'm', {.Ctrl}) {
		open_overlay(st, .Models)
		return
	}
	if p.shortcut(ui, 'p', {.Ctrl}) {
		open_overlay(st, .Prompts)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		open_overlay(st, .Pull)
		return
	}
	if p.shortcut(ui, 's', {.Ctrl}) {
		open_overlay(st, .System)
		return
	}
	if p.shortcut(ui, 'd', {.Ctrl}) {
		open_overlay(st, .Confirm_Delete)
		return
	}
	if p.key_pressed(ui, p.KEY_F1) {
		open_overlay(st, .Help)
		return
	}
	if p.shortcut(ui, 'r', {.Ctrl}) || p.key_pressed(ui, p.KEY_F4) {
		st.show_think = !st.show_think
		toast(st, st.show_think ? "Reasoning shown" : "Reasoning hidden")
		settings_save(st.model, st.pr, st.show_think)
		return
	}
	if p.shortcut(ui, 't', {.Ctrl}) || p.key_pressed(ui, p.KEY_F3) {
		st.pr.think = !st.pr.think
		toast(
			st,
			st.pr.think \
			? "Thinking on — qwen3 will reason before answering" \
			: "Thinking off — the model answers directly",
		)
		settings_save(st.model, st.pr, st.show_think)
		return
	}
	if p.shortcut(ui, ',', {.Ctrl}) || p.key_pressed(ui, p.KEY_F5) {
		st.show_params = !st.show_params
		if !st.show_params && st.zone == .Params {
			st.zone = .Composer
		}
		return
	}
	if p.shortcut(ui, 'g', {.Ctrl}) {
		regenerate(st)
		return
	}
	if p.shortcut(ui, 'e', {.Ctrl}) {
		edit_last(st)
		return
	}
	if p.shortcut(ui, 'y', {.Ctrl}) {
		copy_last(st)
		return
	}
	if p.shortcut(ui, 'j', {.Ctrl}) {
		pick_conv(st, st.cur + 1)
		return
	}
	if p.shortcut(ui, 'k', {.Ctrl}) {
		pick_conv(st, st.cur - 1)
		return
	}
	if p.shortcut(ui, 'b', {.Ctrl}) {
		// Collapse or expand the newest reasoning block.
		c := cur_conv(st)
		if c != nil {
			for i := len(c.msgs) - 1; i >= 0; i -= 1 {
				if c.msgs[i].role == .Assistant {
					st.think_open[i] = !st.think_open[i]
					break
				}
			}
		}
		return
	}

	// Transcript scrolling, from anywhere.
	if p.key_pressed(ui, p.KEY_PAGE_UP) {
		p.scroll_nudge(ui, st.tr_id, {0, -360})
		st.pinned = false
		return
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
		p.scroll_nudge(ui, st.tr_id, {0, 360})
		check_pinned(ui, st)
		return
	}
	if p.shortcut(ui, p.KEY_END, {.Ctrl}) {
		st.pinned = true
		return
	}

	// Wheel over the transcript breaks the pin, and restores it at the bottom.
	if w := p.wheel(ui); w.y != 0 {
		if w.y < 0 {
			st.pinned = false
		} else {
			check_pinned(ui, st)
		}
	}

	switch st.zone {
	case .Chats:
		if p.key_pressed(ui, p.KEY_DOWN) {
			pick_conv(st, st.cur + 1)
		}
		if p.key_pressed(ui, p.KEY_UP) {
			pick_conv(st, st.cur - 1)
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			st.zone = .Composer
		}
	case .Params:
		params_keys(ui, st)
	case .Composer:
		composer_keys(ui, st)
	}
}

pick_conv :: proc(st: ^St, i: int) {
	if st.streaming {
		// Switching away mid-stream would leave the reply landing in a
		// conversation the user cannot see.
		toast(st, "Stop the generation first (Esc)")
		return
	}
	if len(st.convs) == 0 {
		return
	}
	st.cur = clamp(i, 0, len(st.convs) - 1)
	st.pinned = true
	clear(&st.think_open)
}

check_pinned :: proc(ui: ^p.Ctx, st: ^St) {
	off := p.scroll_of(ui, st.tr_id)
	ext := p.scroll_extent(ui, st.tr_id)
	if ext.y - off.y < 24 {
		st.pinned = true
	}
}

params_keys :: proc(ui: ^p.Ctx, st: ^St) {
	rows := len(Param_Row)
	if p.key_pressed(ui, p.KEY_DOWN) {
		st.param_sel = Param_Row((int(st.param_sel) + 1) % rows)
	}
	if p.key_pressed(ui, p.KEY_UP) {
		st.param_sel = Param_Row((int(st.param_sel) - 1 + rows) % rows)
	}

	d := 0
	if p.key_pressed(ui, p.KEY_RIGHT) {
		d = 1
	}
	if p.key_pressed(ui, p.KEY_LEFT) {
		d = -1
	}
	toggled := p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE)
	if d == 0 && !toggled {
		return
	}
	big := .Shift in ui.input.mods

	switch st.param_sel {
	case .Temperature:
		st.pr.temperature = clamp(st.pr.temperature + f32(d) * (big ? 0.2 : 0.05), 0, 2)
	case .Top_P:
		st.pr.top_p = clamp(st.pr.top_p + f32(d) * (big ? 0.2 : 0.05), 0.01, 1)
	case .Num_Predict:
		step := big ? 512 : 64
		st.pr.num_predict = clamp(st.pr.num_predict + d * step, 16, 8192)
	case .Think:
		if toggled || d != 0 {
			st.pr.think = toggled ? !st.pr.think : d > 0
		}
	case .Reasoning:
		if toggled || d != 0 {
			st.show_think = toggled ? !st.show_think : d > 0
		}
	}
	settings_save(st.model, st.pr, st.show_think)
}

// ---------------------------------------------------------------------------
// The composer
// ---------------------------------------------------------------------------

composer_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if .Ctrl not_in ui.input.mods {
		if typed := printable(p.typed_text(ui)); len(typed) > 0 {
			inject_at_elems(&st.input, st.caret, ..transmute([]u8)typed)
			st.caret += len(typed)
		}
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		// palmy implements no wl_data_device, so a paste goes through
		// wl-paste the way kit does everywhere else.
		if text, ok := kit.clipboard_get(context.temp_allocator); ok && text != "" {
			inject_at_elems(&st.input, st.caret, ..transmute([]u8)text)
			st.caret += len(text)
		}
	}

	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if .Shift in k.mods {
				inject_at(&st.input, st.caret, u8('\n'))
				st.caret += 1
			} else if st.streaming {
				toast(st, "Still generating — press Esc to stop")
			} else {
				send(st)
				return
			}
		case p.KEY_BACKSPACE:
			if .Ctrl in k.mods {
				continue
			}
			if st.caret > 0 {
				n := utf8_back(st.input[:], st.caret)
				remove_range(&st.input, st.caret - n, st.caret)
				st.caret -= n
			}
		case p.KEY_DELETE:
			if st.caret < len(st.input) {
				n := utf8_fwd(st.input[:], st.caret)
				remove_range(&st.input, st.caret, st.caret + n)
			}
		case p.KEY_LEFT:
			if st.caret > 0 {
				st.caret -= utf8_back(st.input[:], st.caret)
			}
		case p.KEY_RIGHT:
			if st.caret < len(st.input) {
				st.caret += utf8_fwd(st.input[:], st.caret)
			}
		case p.KEY_UP:
			st.caret = line_move(st.input[:], st.caret, -1)
		case p.KEY_DOWN:
			st.caret = line_move(st.input[:], st.caret, 1)
		case p.KEY_HOME:
			st.caret = line_start(st.input[:], st.caret)
		case p.KEY_END:
			st.caret = line_end(st.input[:], st.caret)
		case 'u':
			if .Ctrl in k.mods {
				clear(&st.input)
				st.caret = 0
			}
		case 'w':
			if .Ctrl in k.mods && st.caret > 0 {
				i := st.caret
				for i > 0 && st.input[i - 1] == ' ' {i -= 1}
				for i > 0 && st.input[i - 1] != ' ' && st.input[i - 1] != '\n' {i -= 1}
				remove_range(&st.input, i, st.caret)
				st.caret = i
			}
		}
	}
}

line_start :: proc(b: []u8, at: int) -> int {
	i := at
	for i > 0 && b[i - 1] != '\n' {i -= 1}
	return i
}

line_end :: proc(b: []u8, at: int) -> int {
	i := at
	for i < len(b) && b[i] != '\n' {i += 1}
	return i
}

line_move :: proc(b: []u8, at: int, d: int) -> int {
	col := at - line_start(b, at)
	if d < 0 {
		s := line_start(b, at)
		if s == 0 {
			return 0
		}
		ps := line_start(b, s - 1)
		return min(ps + col, s - 1)
	}
	e := line_end(b, at)
	if e >= len(b) {
		return len(b)
	}
	ne := line_end(b, e + 1)
	return min(e + 1 + col, ne)
}

// printable drops the control bytes a modified key produces — Ctrl+N arrives
// as 0x0e through xkb, and a composer that accepts it ends up holding
// characters no font can draw.
printable :: proc(s: string) -> string {
	for i in 0 ..< len(s) {
		if s[i] < 0x20 && s[i] != '\n' && s[i] != '\t' {
			return ""
		}
	}
	return s
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return max(1, at - i)
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return min(i, len(b)) - at
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

open_overlay :: proc(st: ^St, o: Overlay) {
	st.overlay = o
	st.ov_sel = 0
	switch o {
	case .Models:
		sync_model_selection(st)
	case .System:
		clear(&st.sys_buf)
		append(&st.sys_buf, ..transmute([]u8)st.pr.system)
	case .Pull:
		clear(&st.pull_name)
	case .None, .Prompts, .Confirm_Delete, .Help:
	}
}

sync_model_selection :: proc(st: ^St) {
	sync_lock_free_models(st)
}

// sync_lock_free_models reads the probe's model list under its lock and finds
// the row the current model sits on.
sync_lock_free_models :: proc(st: ^St) {
	names := probe_model_names(&st.probe, context.temp_allocator)
	for n, i in names {
		if n == st.model {
			st.ov_sel = i
			return
		}
	}
	st.ov_sel = 0
}

overlay_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		st.overlay = .None
		return
	}

	switch st.overlay {
	case .None:

	case .Help:
		if p.key_pressed(ui, p.KEY_RETURN) {
			st.overlay = .None
		}

	case .Models:
		names := probe_model_names(&st.probe, context.temp_allocator)
		if len(names) == 0 {
			if p.key_pressed(ui, p.KEY_RETURN) {
				st.overlay = .Pull
			}
			return
		}
		if p.key_pressed(ui, p.KEY_DOWN) {
			st.ov_sel = min(st.ov_sel + 1, len(names) - 1)
		}
		if p.key_pressed(ui, p.KEY_UP) {
			st.ov_sel = max(st.ov_sel - 1, 0)
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			delete(st.model)
			st.model = strings.clone(names[clamp(st.ov_sel, 0, len(names) - 1)])
			settings_save(st.model, st.pr, st.show_think)
			toast(st, fmt.tprintf("Model set to %s", st.model))
			st.overlay = .None
		}

	case .Prompts:
		if len(st.prompts) == 0 {
			return
		}
		if p.key_pressed(ui, p.KEY_DOWN) {
			st.ov_sel = min(st.ov_sel + 1, len(st.prompts) - 1)
		}
		if p.key_pressed(ui, p.KEY_UP) {
			st.ov_sel = max(st.ov_sel - 1, 0)
		}
		if p.key_pressed(ui, p.KEY_RETURN) {
			pr := st.prompts[clamp(st.ov_sel, 0, len(st.prompts) - 1)]
			clear(&st.input)
			append(&st.input, ..transmute([]u8)pr.body)
			st.caret = len(st.input)
			st.overlay = .None
			st.zone = .Composer
			toast(st, fmt.tprintf("Loaded “%s”", pr.name))
		}
		if p.shortcut(ui, 'a', {.Ctrl}) {
			// Save whatever is in the composer as a new reusable prompt.
			text := strings.trim_space(composer_text(st))
			if text != "" {
				append(
					&st.prompts,
					Prompt{strings.clone(title_from(text)), strings.clone(text)},
				)
				prompts_save(st.prompts[:])
				toast(st, "Saved to the prompt library")
			}
		}
		if p.shortcut(ui, p.KEY_DELETE, {.Ctrl}) && len(st.prompts) > 0 {
			ordered_remove(&st.prompts, clamp(st.ov_sel, 0, len(st.prompts) - 1))
			prompts_save(st.prompts[:])
			st.ov_sel = clamp(st.ov_sel, 0, max(0, len(st.prompts) - 1))
		}

	case .Pull:
		if typed := printable(p.typed_text(ui));
		   len(typed) > 0 && !st.pulling && .Ctrl not_in ui.input.mods {
			append(&st.pull_name, ..transmute([]u8)typed)
		}
		for k in ui.input.keys {
			if k.sym == p.KEY_BACKSPACE && len(st.pull_name) > 0 && !st.pulling {
				n := utf8_back(st.pull_name[:], len(st.pull_name))
				remove_range(&st.pull_name, len(st.pull_name) - n, len(st.pull_name))
			}
		}
		if p.key_pressed(ui, p.KEY_RETURN) && !st.pulling {
			name := strings.trim_space(string(st.pull_name[:]))
			if name != "" {
				stream_start(&st.pull, "/api/pull", pull_body(name), .Pull, name)
				st.pulling = true
			}
		}

	case .Confirm_Delete:
		if p.key_pressed(ui, p.KEY_RETURN) {
			delete_conversation(st)
			st.overlay = .None
		}

	case .System:
		if typed := printable(p.typed_text(ui)); len(typed) > 0 && .Ctrl not_in ui.input.mods {
			append(&st.sys_buf, ..transmute([]u8)typed)
		}
		for k in ui.input.keys {
			switch k.sym {
			case p.KEY_BACKSPACE:
				if len(st.sys_buf) > 0 {
					n := utf8_back(st.sys_buf[:], len(st.sys_buf))
					remove_range(&st.sys_buf, len(st.sys_buf) - n, len(st.sys_buf))
				}
			case p.KEY_RETURN:
				if .Shift in k.mods {
					append(&st.sys_buf, u8('\n'))
				} else {
					delete(st.pr.system)
					st.pr.system = strings.clone(string(st.sys_buf[:]))
					settings_save(st.model, st.pr, st.show_think)
					st.overlay = .None
					toast(
						st,
						st.pr.system == "" \
						? "System prompt cleared" \
						: fmt.tprintf("System prompt set (%d chars)", len(st.pr.system)),
					)
				}
			case 'u':
				if .Ctrl in k.mods {
					clear(&st.sys_buf)
				}
			}
		}
	}
	_ = app
}

// probe_model_names names the installed models, through the probe's own leaf
// accessor so the UI thread never holds a lock for longer than a copy.
probe_model_names :: proc(pb: ^Probe, allocator := context.allocator) -> []string {
	v := probe_view(pb, allocator)
	out := make([]string, len(v.models), allocator)
	for m, i in v.models {
		out[i] = m.name
	}
	return out
}
