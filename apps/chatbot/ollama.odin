package main

// The ollama side: one generation at a time, pumped from the main loop.
//
// There are no threads in this program. `apps/ai` needs a worker thread
// because a UI must keep painting at 60Hz; a bot has nothing to paint, so the
// same loop that services the chat socket also services ollama's socket, and
// a `Gen` is a plain value with no mutex anywhere near it.
//
// That is what makes cancellation cheap and bounded. The ollama socket has a
// RECV_TIMEOUT_MS receive timeout, so `gen_pump` returns at least five times
// a second whether or not a token arrived. Between two pumps the loop drains
// the chat socket, and a `@bot stop` that landed there takes effect on the
// next pass — under a fifth of a second, with no flag shared across threads
// and therefore nothing to get the memory ordering wrong about.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// A fifth of a second: the cancellation budget, and the pacing of the whole
// loop while a reply is being generated.
RECV_TIMEOUT_MS :: 200

// ---------------------------------------------------------------------------
// One NDJSON object from /api/chat
// ---------------------------------------------------------------------------

Chat_Delta :: struct {
	content:  string,
	think:    string,
	err:      string,
	done:     bool,
	reason:   string, // done_reason: "stop", "length", "unload", "load"
	prompt_n: int,
	eval_n:   int,
	eval_ns:  i64,
}

// parse_chat_line decodes one line. `ok` is false for a line that is not a
// JSON object at all, which is not fatal: a server is allowed to send a blank
// line, and a half-line never reaches here because the splitter holds it back.
parse_chat_line :: proc(line: string, alloc := context.allocator) -> (d: Chat_Delta, ok: bool) {
	val, jerr := json.parse_string(line, .JSON, true, alloc)
	if jerr != nil {
		return {}, false
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return {}, false
	}
	d.err = jstr(obj, "error")
	if m, has := obj["message"].(json.Object); has {
		d.content = jstr(m, "content")
		d.think = jstr(m, "thinking")
	}
	// /api/generate names it `response`; accept both so one reader works.
	if d.content == "" {
		d.content = jstr(obj, "response")
	}
	d.done = jbool(obj, "done")
	d.reason = jstr(obj, "done_reason")
	d.prompt_n = int(jnum(obj, "prompt_eval_count"))
	d.eval_n = int(jnum(obj, "eval_count"))
	d.eval_ns = i64(jnum(obj, "eval_duration"))
	return d, true
}

jstr :: proc(o: json.Object, key: string) -> string {
	if v, found := o[key]; found {
		if s, ok := v.(json.String); ok {
			return string(s)
		}
	}
	return ""
}

jnum :: proc(o: json.Object, key: string) -> f64 {
	v, found := o[key]
	if !found {
		return 0
	}
	#partial switch n in v {
	case json.Integer:
		return f64(n)
	case json.Float:
		return f64(n)
	case json.String:
		f, _ := strconv.parse_f64(string(n))
		return f
	}
	return 0
}

jbool :: proc(o: json.Object, key: string) -> bool {
	b, _ := o[key].(json.Boolean)
	return bool(b)
}

// ---------------------------------------------------------------------------
// A generation in flight
// ---------------------------------------------------------------------------

Gen :: struct {
	h:        Http,
	sp:       Line_Splitter,
	raw:      [dynamic]u8,
	lines:    [dynamic]string,
	text:     strings.Builder, // the reply assembled so far
	open:     bool,
	finished: bool,
	stopped:  bool, // finished because somebody asked it to
	err:      string,
	reason:   string,
	chunks:   int, // NDJSON objects carrying text: one per token from ollama
	prompt_n: int,
	eval_n:   int,
	started:  time.Tick,
	first_at: f64, // seconds to the first token
}

gen_start :: proc(g: ^Gen, body: string) -> (err: string) {
	g^ = Gen {
		raw     = make([dynamic]u8),
		lines   = make([dynamic]string),
		text    = strings.builder_make(),
		started = time.tick_now(),
	}
	g.sp = splitter_make()

	h, oerr := http_open()
	if oerr != "" {
		g.finished = true
		g.err = fmt.aprintf("%s. Start it with:  %s", oerr, OLLAMA_START_HINT)
		return g.err
	}
	g.h = h
	g.open = true

	if rerr := http_request(&g.h, "POST", "/api/chat", body); rerr != "" {
		g.finished = true
		g.err = rerr
		return g.err
	}
	return ""
}

gen_destroy :: proc(g: ^Gen) {
	if g.open {
		http_close(&g.h)
		g.open = false
	}
	splitter_destroy(&g.sp)
	delete(g.raw)
	delete(g.lines)
	strings.builder_destroy(&g.text)
}

// gen_stop asks for the generation to end. The socket is not touched here;
// the next pump sees the flag and unwinds, which keeps every close on one
// code path.
gen_stop :: proc(g: ^Gen) {
	g.stopped = true
}

gen_elapsed :: proc(g: ^Gen) -> f64 {
	return time.duration_seconds(time.tick_since(g.started))
}

// gen_pump does one bounded read — at most RECV_TIMEOUT_MS — and appends
// whatever text arrived to `g.text`. It returns whether the reply grew, which
// is the only input the coalescing policy needs beyond the clock.
gen_pump :: proc(g: ^Gen) -> (grew: bool) {
	if g.finished {
		return false
	}
	if g.stopped {
		g.finished = true
		return false
	}

	before := strings.builder_len(g.text)
	state, perr := http_pump(&g.h, &g.raw)
	if state == .Error {
		g.err = perr
		g.finished = true
		return false
	}

	if len(g.raw) > 0 {
		clear(&g.lines)
		splitter_feed(&g.sp, g.raw[:], &g.lines, context.temp_allocator)
		clear(&g.raw)
		for line in g.lines {
			if !gen_line(g, line) {
				g.finished = true
				break
			}
		}
	}

	if state == .End && !g.finished {
		clear(&g.lines)
		splitter_flush(&g.sp, &g.lines, context.temp_allocator)
		for line in g.lines {
			if !gen_line(g, line) {
				break
			}
		}
		g.finished = true
	}

	if g.finished && g.err == "" && g.h.dec.status != 0 && g.h.dec.status / 100 != 2 {
		g.err = fmt.aprintf("ollama answered HTTP %d for /api/chat", g.h.dec.status)
	}
	return strings.builder_len(g.text) > before
}

// gen_line applies one NDJSON object. Returns false when the stream is over.
@(private = "file")
gen_line :: proc(g: ^Gen, line: string) -> bool {
	d, ok := parse_chat_line(line, context.temp_allocator)
	if !ok {
		return true
	}
	if d.err != "" {
		g.err = strings.clone(d.err)
		return false
	}
	// `thinking` is deliberately dropped. qwen3 reasons at length before it
	// answers, and a channel wants the answer, not the deliberation.
	if d.content != "" {
		if strings.builder_len(g.text) == 0 {
			g.first_at = gen_elapsed(g)
		}
		strings.write_string(&g.text, d.content)
		g.chunks += 1
	}
	if d.done {
		g.reason = strings.clone(d.reason)
		g.prompt_n = d.prompt_n
		g.eval_n = d.eval_n
		return false
	}
	return true
}

gen_text :: proc(g: ^Gen) -> string {
	return strings.to_string(g.text)
}

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

json_escape :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

Turn_Role :: enum u8 {
	User,
	Assistant,
}

// A Turn is one line of context on its way to the model. The transformation
// from chat messages to turns is in bot.odin and is a pure procedure, so the
// context cap is tested without a socket.
Turn :: struct {
	role: Turn_Role,
	text: string,
}

// chat_body builds the /api/chat request.
//
// `think` is false on every call. qwen3 defaults to reasoning, and with
// thinking on, the first token of visible content arrives after the model has
// finished deliberating — which for a 0.6B model on a chat question is most
// of the wall clock. A reply that streams is worth more here than a reply
// that reasons.
chat_body :: proc(
	model: string,
	system: string,
	turns: []Turn,
	num_predict: int,
	temperature: f32 = 0.6,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"model\":")
	json_escape(&b, model)
	strings.write_string(&b, ",\"stream\":true,\"think\":false,\"messages\":[")

	first := true
	if strings.trim_space(system) != "" {
		strings.write_string(&b, "{\"role\":\"system\",\"content\":")
		json_escape(&b, system)
		strings.write_byte(&b, '}')
		first = false
	}
	for t in turns {
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"role\":")
		json_escape(&b, t.role == .User ? "user" : "assistant")
		strings.write_string(&b, ",\"content\":")
		json_escape(&b, t.text)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "],\"options\":{")
	fmt.sbprintf(&b, "\"temperature\":%.3f,\"top_p\":0.900,", temperature)
	fmt.sbprintf(&b, "\"num_predict\":%d", num_predict)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Is ollama there, and does it have the model?
// ---------------------------------------------------------------------------

Ollama_Status :: struct {
	up:      bool,
	version: string,
	has:     bool, // the model we were asked for is pulled
	models:  int,
	err:     string,
}

ollama_probe :: proc(model: string, allocator := context.allocator) -> Ollama_Status {
	out: Ollama_Status
	st, text, err := http_json("GET", "/api/version", "", 1500, context.temp_allocator)
	if err != "" {
		out.err = strings.clone(err, allocator)
		return out
	}
	if st / 100 != 2 {
		out.err = fmt.aprintf("ollama answered HTTP %d for /api/version", st, allocator = allocator)
		return out
	}
	out.up = true
	if v, jerr := json.parse_string(text, .JSON, true, context.temp_allocator); jerr == nil {
		if o, ok := v.(json.Object); ok {
			out.version = strings.clone(jstr(o, "version"), allocator)
		}
	}

	st2, tags, err2 := http_json("GET", "/api/tags", "", 3000, context.temp_allocator)
	if err2 != "" || st2 / 100 != 2 {
		return out
	}
	if v, jerr := json.parse_string(tags, .JSON, true, context.temp_allocator); jerr == nil {
		if o, ok := v.(json.Object); ok {
			if arr, ok2 := o["models"].(json.Array); ok2 {
				out.models = len(arr)
				for item in arr {
					m, is := item.(json.Object)
					if !is {
						continue
					}
					if jstr(m, "name") == model || jstr(m, "model") == model {
						out.has = true
					}
				}
			}
		}
	}
	return out
}
