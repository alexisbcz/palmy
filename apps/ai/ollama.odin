package main

// The ollama client.
//
// Everything here talks to 127.0.0.1:11434 and nowhere else; `http.odin` has
// no way to name another host. Two kinds of call:
//
//   * one-shot queries (/api/tags, /api/ps, /api/show, /api/version) run on a
//     short-lived probe thread and publish into `Probe`.
//   * streaming calls (/api/chat, /api/pull) run on a worker thread and
//     publish into `Stream`.
//
// LOCKING. Each of `Stream` and `Probe` has exactly one mutex, and every
// procedure that takes it is a leaf: it locks, touches fields, unlocks, and
// calls nothing that could lock again. Nothing in this file takes two mutexes.
// `cancel` and `running` are atomics so the UI can ask a worker to stop, and
// see that it has, without ever blocking on the worker's lock.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

OLLAMA_URL :: "http://127.0.0.1:11434"
START_HINT :: "OLLAMA_HOST=127.0.0.1:11434 ollama serve"

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

Model_Info :: struct {
	name:     string,
	size:     i64,    // bytes on disk
	params:   string, // "751.63M"
	quant:    string, // "Q4_K_M"
	family:   string,
	ctx_len:  int,
	thinking: bool, // the model advertises a thinking capability
}

Loaded_Info :: struct {
	name:    string,
	size:    i64, // resident footprint
	vram:    i64,
	ctx:     int,
	expires: string,
}

// Probe is everything the one-shot endpoints report, published as a unit.
Probe :: struct {
	mu:       sync.Mutex,
	busy:     b32, // atomic
	// guarded by mu
	models:   [dynamic]Model_Info,
	loaded:   [dynamic]Loaded_Info,
	version:  string,
	err:      string,
	stamp:    f64, // ui.now when this was published
	got:      bool,
}

probe_init :: proc(p: ^Probe) {
	p.models = make([dynamic]Model_Info)
	p.loaded = make([dynamic]Loaded_Info)
}

// ---------------------------------------------------------------------------
// Streams
// ---------------------------------------------------------------------------

Job_Kind :: enum u8 {
	Chat,
	Pull,
}

Stream :: struct {
	mu:        sync.Mutex,
	// Atomics, never under the lock.
	cancel:    b32,
	running:   b32,
	// Guarded by mu.
	content:   [dynamic]u8,
	think:     [dynamic]u8,
	err:       string,
	status:    string, // /api/pull's human-readable stage
	total:     i64,
	completed: i64,
	prompt_n:  int,
	eval_n:    int,
	eval_ns:   i64,
	load_ns:   i64,
	tokens:    int, // chunks seen so far: ollama emits one per token
	reason:    string, // ollama's done_reason: "stop", "length", "unload"
	ttft:      f64, // seconds from request to first token
	started:   f64, // monotonic seconds, for the live rate
	elapsed:   f64,
	finished:  bool,
	stopped:   bool, // finished because the user asked it to
	model:     string,
	kind:      Job_Kind,
}

stream_init :: proc(s: ^Stream) {
	s.content = make([dynamic]u8)
	s.think = make([dynamic]u8)
}

// stream_reset prepares the stream for a new job. The UI thread calls it only
// when no worker is running.
stream_reset :: proc(s: ^Stream, model: string, kind: Job_Kind) {
	sync.mutex_lock(&s.mu)
	clear(&s.content)
	clear(&s.think)
	s.err = ""
	s.status = ""
	s.total = 0
	s.completed = 0
	s.prompt_n = 0
	s.eval_n = 0
	s.eval_ns = 0
	s.load_ns = 0
	s.tokens = 0
	delete(s.reason)
	s.reason = ""
	s.ttft = 0
	s.elapsed = 0
	s.finished = false
	s.stopped = false
	s.model = model
	s.kind = kind
	s.started = 0
	sync.mutex_unlock(&s.mu)
	sync.atomic_store(&s.cancel, false)
}

// Snapshot is a copy of a stream taken under the lock, so the frame that draws
// it sees one consistent set of numbers. The two text fields point at the
// frame allocator.
Snapshot :: struct {
	content:   string,
	think:     string,
	err:       string,
	status:    string,
	total:     i64,
	completed: i64,
	prompt_n:  int,
	eval_n:    int,
	eval_ns:   i64,
	load_ns:   i64,
	tokens:    int,
	reason:    string,
	ttft:      f64,
	elapsed:   f64,
	finished:  bool,
	stopped:   bool,
	running:   bool,
	model:     string,
	kind:      Job_Kind,
}

// stream_snapshot is a leaf: it locks, copies, unlocks.
stream_snapshot :: proc(s: ^Stream, allocator := context.allocator) -> Snapshot {
	out: Snapshot
	out.running = bool(sync.atomic_load(&s.running))
	sync.mutex_lock(&s.mu)
	out.content = strings.clone(string(s.content[:]), allocator)
	out.think = strings.clone(string(s.think[:]), allocator)
	out.err = strings.clone(s.err, allocator)
	out.status = strings.clone(s.status, allocator)
	out.total = s.total
	out.completed = s.completed
	out.prompt_n = s.prompt_n
	out.eval_n = s.eval_n
	out.eval_ns = s.eval_ns
	out.load_ns = s.load_ns
	out.tokens = s.tokens
	out.reason = strings.clone(s.reason, allocator)
	out.ttft = s.ttft
	out.elapsed = s.elapsed
	out.finished = s.finished
	out.stopped = s.stopped
	out.model = strings.clone(s.model, allocator)
	out.kind = s.kind
	sync.mutex_unlock(&s.mu)
	return out
}

stream_request_stop :: proc(s: ^Stream) {
	sync.atomic_store(&s.cancel, true)
}

stream_is_running :: proc(s: ^Stream) -> bool {
	return bool(sync.atomic_load(&s.running))
}

// --- the leaf writers the worker uses -------------------------------------

@(private = "file")
pub_text :: proc(s: ^Stream, content, think: string, now: f64) {
	sync.mutex_lock(&s.mu)
	if len(content) > 0 {
		if s.ttft == 0 && len(s.content) == 0 {
			s.ttft = now - s.started
		}
		append(&s.content, ..transmute([]u8)content)
	}
	if len(think) > 0 {
		if s.ttft == 0 && len(s.think) == 0 {
			s.ttft = now - s.started
		}
		append(&s.think, ..transmute([]u8)think)
	}
	s.tokens += 1
	s.elapsed = now - s.started
	sync.mutex_unlock(&s.mu)
}

@(private = "file")
pub_stats :: proc(s: ^Stream, prompt_n, eval_n: int, eval_ns, load_ns: i64, reason: string, now: f64) {
	sync.mutex_lock(&s.mu)
	if reason != "" {
		delete(s.reason)
		s.reason = strings.clone(reason)
	}
	s.prompt_n = prompt_n
	s.eval_n = eval_n
	s.eval_ns = eval_ns
	s.load_ns = load_ns
	s.elapsed = now - s.started
	sync.mutex_unlock(&s.mu)
}

@(private = "file")
pub_progress :: proc(s: ^Stream, status: string, total, completed: i64, now: f64) {
	sync.mutex_lock(&s.mu)
	if status != "" && status != s.status {
		delete(s.status)
		s.status = strings.clone(status)
	}
	if total > 0 {
		s.total = total
	}
	if completed >= 0 {
		s.completed = completed
	}
	s.elapsed = now - s.started
	sync.mutex_unlock(&s.mu)
}

@(private = "file")
pub_start :: proc(s: ^Stream, now: f64) {
	sync.mutex_lock(&s.mu)
	s.started = now
	sync.mutex_unlock(&s.mu)
}

@(private = "file")
pub_done :: proc(s: ^Stream, err: string, stopped: bool, now: f64) {
	sync.mutex_lock(&s.mu)
	if err != "" {
		delete(s.err)
		s.err = strings.clone(err)
	}
	s.stopped = stopped
	s.finished = true
	s.elapsed = now - s.started
	sync.mutex_unlock(&s.mu)
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

Job :: struct {
	path: string,
	body: string,
	st:   ^Stream,
	kind: Job_Kind,
}

mono :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(START_TICK))
}

START_TICK := time.tick_now()

// stream_start launches the worker. `body` must be freshly allocated; the
// worker owns it. Only one job per Stream may be in flight, which the UI
// guarantees by checking `stream_is_running` first.
stream_start :: proc(s: ^Stream, path, body: string, kind: Job_Kind, model: string) {
	stream_reset(s, model, kind)
	sync.atomic_store(&s.running, true)

	j := new(Job)
	j.path = strings.clone(path)
	j.body = body
	j.st = s
	j.kind = kind
	thread.create_and_start_with_poly_data(j, stream_worker, nil, .Normal, true)
}

// stream_worker is the whole of the socket side. It never touches the UI, it
// never allocates out of a shared arena, and it publishes only through the
// leaf writers above.
stream_worker :: proc(j: ^Job) {
	s := j.st
	defer {
		delete(j.path)
		delete(j.body)
		free(j)
		sync.atomic_store(&s.running, false)
	}

	pub_start(s, mono())

	h, oerr := http_open(200)
	if oerr != "" {
		pub_done(s, fmt.tprintf("%s. Start it with:  %s", oerr, START_HINT), false, mono())
		return
	}
	defer http_close(&h)

	if rerr := http_request(&h, "POST", j.path, j.body); rerr != "" {
		pub_done(s, rerr, false, mono())
		return
	}

	// A per-line arena: the JSON parser allocates freely and the whole lot is
	// released once the line has been published.
	arena: virtual.Arena
	if aerr := virtual.arena_init_growing(&arena, 1 << 20); aerr != nil {
		pub_done(s, "out of memory", false, mono())
		return
	}
	defer virtual.arena_destroy(&arena)
	aalloc := virtual.arena_allocator(&arena)

	raw := make([dynamic]u8)
	defer delete(raw)
	sp := splitter_make()
	defer splitter_destroy(&sp)
	lines := make([dynamic]string)
	defer delete(lines)

	stopped := false
	fatal := ""

	read_loop: for {
		if sync.atomic_load(&s.cancel) {
			stopped = true
			break read_loop
		}

		state, perr := http_pump(&h, &raw)
		if state == .Error {
			fatal = perr
			break read_loop
		}

		if len(raw) > 0 {
			clear(&lines)
			splitter_feed(&sp, raw[:], &lines, aalloc)
			clear(&raw)
			for line in lines {
				if !handle_line(j, line, aalloc) {
					// `done` arrived, or the server reported an error.
					virtual.arena_free_all(&arena)
					break read_loop
				}
			}
			virtual.arena_free_all(&arena)
		}

		if state == .End {
			clear(&lines)
			splitter_flush(&sp, &lines, aalloc)
			for line in lines {
				handle_line(j, line, aalloc)
			}
			virtual.arena_free_all(&arena)
			break read_loop
		}
	}

	// A non-2xx status with no JSON error of its own still has to say
	// something, otherwise the UI shows an empty bubble and no reason.
	if fatal == "" && h.dec.status != 0 && h.dec.status / 100 != 2 {
		fatal = fmt.tprintf("ollama answered HTTP %d for %s", h.dec.status, j.path)
	}
	pub_done(s, fatal, stopped, mono())
}

// A single NDJSON object from /api/chat, decoded. Kept as a named value so
// the self-test can assert on the parser rather than on a mock of it.
Chat_Delta :: struct {
	content:  string,
	think:    string,
	err:      string,
	done:     bool,
	reason:   string, // done_reason: "stop", "length", "unload", "load"
	prompt_n: int,
	eval_n:   int,
	eval_ns:  i64,
	load_ns:  i64,
}

// parse_chat_line decodes one line. `ok` is false for a line that is not a
// JSON object at all, which is not fatal: a server is allowed to send a blank.
parse_chat_line :: proc(line: string, alloc := context.allocator) -> (d: Chat_Delta, ok: bool) {
	val, jerr := json.parse_string(line, .JSON, true, alloc)
	if jerr != nil {
		return {}, false
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return {}, false
	}
	d.err, _ = jstr(obj, "error")
	if m, has := obj["message"].(json.Object); has {
		d.content, _ = jstr(m, "content")
		d.think, _ = jstr(m, "thinking")
	}
	// /api/generate names it `response`; accept both so the same reader works.
	if d.content == "" {
		if r, has := jstr(obj, "response"); has {
			d.content = r
		}
	}
	d.done = jbool(obj, "done")
	d.reason, _ = jstr(obj, "done_reason")
	d.prompt_n = jint(obj, "prompt_eval_count")
	d.eval_n = jint(obj, "eval_count")
	d.eval_ns = i64(jnum(obj, "eval_duration"))
	d.load_ns = i64(jnum(obj, "load_duration"))
	return d, true
}

Pull_Delta :: struct {
	status:    string,
	err:       string,
	total:     i64,
	completed: i64,
	done:      bool,
}

parse_pull_line :: proc(line: string, alloc := context.allocator) -> (d: Pull_Delta, ok: bool) {
	val, jerr := json.parse_string(line, .JSON, true, alloc)
	if jerr != nil {
		return {}, false
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return {}, false
	}
	d.status, _ = jstr(obj, "status")
	d.err, _ = jstr(obj, "error")
	d.total = i64(jnum(obj, "total"))
	d.completed = i64(jnum(obj, "completed"))
	d.done = jbool(obj, "done") || d.status == "success"
	return d, true
}

// handle_line publishes one NDJSON object. It returns false when the stream is
// over — `done: true`, or an `error` field.
@(private = "file")
handle_line :: proc(j: ^Job, line: string, alloc: mem.Allocator) -> bool {
	now := mono()
	switch j.kind {
	case .Chat:
		d, ok := parse_chat_line(line, alloc)
		if !ok {
			return true
		}
		if d.err != "" {
			pub_done(j.st, d.err, false, now)
			return false
		}
		if d.content != "" || d.think != "" {
			pub_text(j.st, d.content, d.think, now)
		}
		if d.done {
			pub_stats(j.st, d.prompt_n, d.eval_n, d.eval_ns, d.load_ns, d.reason, now)
			return false
		}

	case .Pull:
		d, ok := parse_pull_line(line, alloc)
		if !ok {
			return true
		}
		if d.err != "" {
			pub_done(j.st, d.err, false, now)
			return false
		}
		pub_progress(j.st, d.status, d.total, d.completed, now)
		if d.done {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

jstr :: proc(o: json.Object, key: string) -> (string, bool) {
	v, found := o[key]
	if !found {
		return "", false
	}
	s, ok := v.(json.String)
	return string(s), ok
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

jint :: proc(o: json.Object, key: string) -> int {
	return int(jnum(o, key))
}

jbool :: proc(o: json.Object, key: string) -> bool {
	b, _ := o[key].(json.Boolean)
	return bool(b)
}

// ---------------------------------------------------------------------------
// The probe thread: /api/version, /api/tags, /api/ps
// ---------------------------------------------------------------------------

probe_refresh :: proc(p: ^Probe) {
	if sync.atomic_load(&p.busy) {
		return
	}
	sync.atomic_store(&p.busy, true)
	thread.create_and_start_with_poly_data(p, probe_worker, nil, .Normal, true)
}

probe_worker :: proc(p: ^Probe) {
	defer sync.atomic_store(&p.busy, false)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 19) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	al := virtual.arena_allocator(&arena)

	version := ""
	err := ""

	if st, text, e := http_json("GET", "/api/version", "", 1500, al); e != "" {
		err = fmt.tprintf("%s. Start it with:  %s", e, START_HINT)
	} else if st / 100 == 2 {
		if v, jerr := json.parse_string(text, .JSON, true, al); jerr == nil {
			if o, ok := v.(json.Object); ok {
				version, _ = jstr(o, "version")
			}
		}
	}

	models := make([dynamic]Model_Info)
	loaded := make([dynamic]Loaded_Info)

	if err == "" {
		if st, text, e := http_json("GET", "/api/tags", "", 3000, al); e == "" && st / 100 == 2 {
			if v, jerr := json.parse_string(text, .JSON, true, al); jerr == nil {
				if o, ok := v.(json.Object); ok {
					if arr, ok2 := o["models"].(json.Array); ok2 {
						for item in arr {
							m, is := item.(json.Object)
							if !is {
								continue
							}
							mi: Model_Info
							name, _ := jstr(m, "name")
							mi.name = strings.clone(name)
							mi.size = i64(jnum(m, "size"))
							if d, ok3 := m["details"].(json.Object); ok3 {
								ps, _ := jstr(d, "parameter_size")
								q, _ := jstr(d, "quantization_level")
								fam, _ := jstr(d, "family")
								mi.params = strings.clone(ps)
								mi.quant = strings.clone(q)
								mi.family = strings.clone(fam)
								mi.ctx_len = jint(d, "context_length")
							}
							if caps, ok3 := m["capabilities"].(json.Array); ok3 {
								for c in caps {
									if cs, ok4 := c.(json.String); ok4 && string(cs) == "thinking" {
										mi.thinking = true
									}
								}
							}
							append(&models, mi)
						}
					}
				}
			}
		}

		if st, text, e := http_json("GET", "/api/ps", "", 2000, al); e == "" && st / 100 == 2 {
			if v, jerr := json.parse_string(text, .JSON, true, al); jerr == nil {
				if o, ok := v.(json.Object); ok {
					if arr, ok2 := o["models"].(json.Array); ok2 {
						for item in arr {
							m, is := item.(json.Object)
							if !is {
								continue
							}
							li: Loaded_Info
							name, _ := jstr(m, "name")
							exp, _ := jstr(m, "expires_at")
							li.name = strings.clone(name)
							li.size = i64(jnum(m, "size"))
							li.vram = i64(jnum(m, "size_vram"))
							li.ctx = jint(m, "context_length")
							li.expires = strings.clone(exp)
							append(&loaded, li)
						}
					}
				}
			}
		}
	}

	// Publish as one unit. Leaf: nothing below here calls out.
	sync.mutex_lock(&p.mu)
	for m in p.models {
		delete(m.name);delete(m.params);delete(m.quant);delete(m.family)
	}
	clear(&p.models)
	for l in p.loaded {
		delete(l.name);delete(l.expires)
	}
	clear(&p.loaded)
	for m in models {
		append(&p.models, m)
	}
	for l in loaded {
		append(&p.loaded, l)
	}
	delete(p.version)
	delete(p.err)
	p.version = strings.clone(version)
	p.err = strings.clone(err)
	p.got = true
	sync.mutex_unlock(&p.mu)

	delete(models)
	delete(loaded)
}

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

// json_escape writes a Go/JSON-compatible string literal, including the
// control characters a system prompt or a pasted snippet will contain.
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

Params :: struct {
	temperature: f32,
	top_p:       f32,
	num_predict: int,
	think:       bool,
	system:      string,
}

// chat_body builds the /api/chat request. `think` is explicit on every call:
// qwen3 defaults to reasoning, and a caller that leaves it out gets an empty
// `message.content` and an empty bubble.
chat_body :: proc(
	model: string,
	history: []Message,
	pr: Params,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"model\":")
	json_escape(&b, model)
	strings.write_string(&b, ",\"stream\":true,\"think\":")
	strings.write_string(&b, pr.think ? "true" : "false")
	strings.write_string(&b, ",\"messages\":[")

	first := true
	if strings.trim_space(pr.system) != "" {
		strings.write_string(&b, "{\"role\":\"system\",\"content\":")
		json_escape(&b, pr.system)
		strings.write_string(&b, "}")
		first = false
	}
	for m in history {
		if m.role == .System {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"role\":")
		json_escape(&b, m.role == .User ? "user" : "assistant")
		strings.write_string(&b, ",\"content\":")
		json_escape(&b, m.text)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "],\"options\":{")
	fmt.sbprintf(&b, "\"temperature\":%.3f,", pr.temperature)
	fmt.sbprintf(&b, "\"top_p\":%.3f,", pr.top_p)
	fmt.sbprintf(&b, "\"num_predict\":%d", pr.num_predict)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

pull_body :: proc(model: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"model\":")
	json_escape(&b, model)
	strings.write_string(&b, ",\"stream\":true}")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

human_bytes :: proc(n: i64, allocator := context.allocator) -> string {
	f := f64(n)
	switch {
	case n >= 1 << 30:
		return fmt.aprintf("%.1f GB", f / f64(1 << 30), allocator = allocator)
	case n >= 1 << 20:
		return fmt.aprintf("%.0f MB", f / f64(1 << 20), allocator = allocator)
	case n >= 1 << 10:
		return fmt.aprintf("%.0f KB", f / f64(1 << 10), allocator = allocator)
	}
	return fmt.aprintf("%d B", n, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Reading the probe
// ---------------------------------------------------------------------------

Probe_View :: struct {
	models:  []Model_Info,
	loaded:  []Loaded_Info,
	version: string,
	err:     string,
	got:     bool,
}

// probe_view is a leaf: it locks, copies into `allocator`, unlocks. The frame
// calls it once and draws from the copy.
probe_view :: proc(pb: ^Probe, allocator := context.allocator) -> Probe_View {
	v: Probe_View
	sync.mutex_lock(&pb.mu)
	v.models = make([]Model_Info, len(pb.models), allocator)
	for m, i in pb.models {
		v.models[i] = Model_Info {
			name     = strings.clone(m.name, allocator),
			size     = m.size,
			params   = strings.clone(m.params, allocator),
			quant    = strings.clone(m.quant, allocator),
			family   = strings.clone(m.family, allocator),
			ctx_len  = m.ctx_len,
			thinking = m.thinking,
		}
	}
	v.loaded = make([]Loaded_Info, len(pb.loaded), allocator)
	for l, i in pb.loaded {
		v.loaded[i] = Loaded_Info {
			name    = strings.clone(l.name, allocator),
			size    = l.size,
			vram    = l.vram,
			ctx     = l.ctx,
			expires = strings.clone(l.expires, allocator),
		}
	}
	v.version = strings.clone(pb.version, allocator)
	v.err = strings.clone(pb.err, allocator)
	v.got = pb.got
	sync.mutex_unlock(&pb.mu)
	return v
}
