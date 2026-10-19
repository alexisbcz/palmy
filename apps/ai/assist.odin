package main

// The person's side of the assistant: everything that runs as the person,
// outside the sandbox.
//
//   - Choosing the identity. There is no assistant for "All identities"; a
//     request without one is refused with a question, not answered.
//   - The scope check before anything runs: a request that names another of
//     the person's identities is answered by this process ("this is the
//     Northwind assistant; it cannot see Personal") without starting the
//     assistant, so it never learns the other identity exists.
//   - The delegated session: minted once per identity with
//     mint_scoped_session(kind 'assistant') through cloudkit, kept in the
//     identity's own assistant directory, which is the only token store the
//     sandbox can read.
//   - Starting the assistant: this binary, re-executed as `ai agent`, with a
//     clean environment, confined by cloud/assistant/sandbox before it reads
//     a byte of its request.
//   - Brokering model calls: the assistant asks, this answers, through
//     ollama on loopback or — only when the person opted that identity in —
//     a remote provider whose key never enters the sandbox.
//   - Keeping the conversation, and confirming or declining proposals, with
//     this machine's own session for the identity (kind 'device'), which the
//     database lets do what the assistant's may not.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:time"
import ck "../cloudkit"
import en "../../cloud/assistant/engine"

ASSISTANT_MODEL_DEFAULT :: "qwen3:0.6b"
REMOTE_MODEL_DEFAULT :: "claude-opus-5-5"

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

home_dir :: proc() -> string {
	return os.get_env("HOME", context.temp_allocator)
}

state_dir :: proc(handle: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/.local/share/palm/assistant/%s", home_dir(), handle, allocator = allocator)
}

// tools_dir holds the tool binaries and nothing else: the sandbox lets the
// assistant execute from here alone. $PALM_TOOLS_DIR, else `tools/` beside
// this binary, else the installed location.
tools_dir :: proc(allocator := context.temp_allocator) -> string {
	if d := os.get_env("PALM_TOOLS_DIR", context.temp_allocator); d != "" {
		return strings.clone(d, allocator)
	}
	self, err := os.get_executable_path(context.temp_allocator)
	if err == nil {
		cand := fmt.tprintf("%s/tools", filepath.dir(self))
		if os.is_dir(cand) {return strings.clone(cand, allocator)}
	}
	return strings.clone("/usr/lib/palm/assistant/tools", allocator)
}

@(private = "file")
port_of :: proc(url: string, def: int) -> int {
	u, ok := ck.parse_url(url)
	if !ok {return def}
	return u.port
}

cloud_url :: proc() -> string {
	if u := os.get_env("PALM_CLOUD_URL", context.temp_allocator); u != "" {return u}
	return ck.DEFAULT_URL
}

dav_url :: proc() -> string {
	if u := os.get_env("PALM_DAV_URL", context.temp_allocator); u != "" {return u}
	return "http://127.0.0.1:59580"
}

ollama_url :: proc() -> string {
	if h := os.get_env("OLLAMA_HOST", context.temp_allocator); h != "" {
		return strings.has_prefix(h, "http") ? h : fmt.tprintf("http://%s", h)
	}
	return "http://127.0.0.1:11434"
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

Person :: struct {
	c:          ^ck.Client, // the person's own session: unscoped, unless this process was started inside a scope
	identities: []ck.Identity,
	scoped_to:  string, // PALM_IDENTITY at start, if any
}

person_open :: proc() -> (p: Person, err: string) {
	c, e := ck.open(app = "ai")
	p.c = c
	p.scoped_to = strings.clone(c.scope)
	if !ck.ok(e) {return p, e.message}
	if !ck.signed_in(c) {
		return p, "not signed in: sign in with Accounts first (accounts signin)"
	}
	ids, ie := ck.identities(c)
	if !ck.ok(ie) {return p, ie.message}
	p.identities = ids
	return p, ""
}

find_ident :: proc(p: ^Person, key: string) -> (ck.Identity, bool) {
	return ck.find_identity(p.identities, key)
}

// machine_session is this machine's own session for one identity: the one
// `accounts switch` stores, minted here the first time if need be. It is a
// device's, not an assistant's, so confirmations made with it go through.
machine_session :: proc(p: ^Person, ident: ck.Identity) -> (c: ^ck.Client, err: string) {
	c2, e := ck.open(scope = ident.handle, app = "ai")
	if !ck.ok(e) {return c2, e.message}
	if ck.signed_in(c2) {return c2, ""}
	if p.scoped_to != "" {
		return c2, fmt.tprintf("this machine holds no session for %s, and a process scoped to %s cannot make one", ident.handle, p.scoped_to)
	}
	_, me := ck.scope_to(p.c, ident, ck.machine_name() != "" ? ck.machine_name() : "this machine")
	if !ck.ok(me) {return c2, me.message}
	ck.close(c2)
	c3, e3 := ck.open(scope = ident.handle, app = "ai")
	if !ck.ok(e3) {return c3, e3.message}
	return c3, ""
}

// delegated_session makes sure the identity's assistant holds a session of
// its own — kind 'assistant', 30 days — in its own directory, and that the
// session still works. Returns its path.
delegated_session :: proc(p: ^Person, ident: ck.Identity) -> (path: string, err: string) {
	dir := state_dir(ident.handle)
	os.make_directory_all(dir, os.perm_number(0o700))
	os.chmod(dir, os.perm_number(0o700))
	path = fmt.tprintf("%s/session.json", dir)
	if os.exists(path) {
		// Check it is alive: a refresh, through cloudkit, as the assistant will.
		sess := os.get_env("PALM_CLOUD_SESSION", context.temp_allocator)
		os.set_env("PALM_CLOUD_SESSION", path)
		c, e := ck.open(app = "ai")
		alive := ck.ok(e) && ck.signed_in(c) && ck.ok(ck.ensure_fresh(c))
		ck.close(c)
		if sess == "" {os.unset_env("PALM_CLOUD_SESSION")} else {os.set_env("PALM_CLOUD_SESSION", sess)}
		if alive {return path, ""}
		os.remove(path)
	}
	if p.scoped_to != "" {
		return "", fmt.tprintf("the %s assistant has no session, and a process scoped to %s cannot delegate one", ident.handle, p.scoped_to)
	}
	m, me := ck.scope_to(p.c, ident, fmt.tprintf("%s assistant", ident.display_name), kind = "assistant",
		expires_in = 30 * 86400, store = .Delegated)
	if !ck.ok(me) {return "", me.message}
	if re := os.rename(m.path, path); re != nil {
		return "", fmt.tprintf("could not move the delegated session into place (%v)", re)
	}
	os.chmod(path, os.perm_number(0o600))
	return path, ""
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

Settings :: struct {
	exists:       bool,
	enabled:      bool,
	model:        string,
	provider:     string, // local | anthropic
	remote_model: string,
	opted_in_at:  string,
}

settings_get :: proc(c: ^ck.Client, ident: ck.Identity) -> (s: Settings, err: string) {
	s.model = ASSISTANT_MODEL_DEFAULT
	s.provider = "local"
	v, e := ck.select(c, "assistant_settings", fmt.tprintf("select=*&identity_id=eq.%s", ident.id), context.temp_allocator)
	if !ck.ok(e) {return s, e.message}
	rows := ck.array(v)
	if len(rows) == 0 {return s, ""}
	r := rows[0]
	s.exists = true
	s.enabled = ck.get_bool(r, "enabled")
	s.model = strings.clone(ck.get_str(r, "model"))
	s.provider = strings.clone(ck.get_str(r, "provider"))
	s.remote_model = strings.clone(ck.get_str(r, "remote_model"))
	s.opted_in_at = strings.clone(ck.get_str(r, "remote_opt_in_at"))
	return s, ""
}

settings_put :: proc(c: ^ck.Client, ident: ck.Identity, s: Settings) -> string {
	o := ck.obj()
	ck.put(&o, "identity_id", ident.id)
	ck.put(&o, "enabled", s.enabled)
	ck.put(&o, "model", s.model)
	ck.put(&o, "provider", s.provider)
	if s.remote_model != "" {ck.put(&o, "remote_model", s.remote_model)} else {ck.put_null(&o, "remote_model")}
	if s.opted_in_at != "" {ck.put(&o, "remote_opt_in_at", s.opted_in_at)} else {ck.put_null(&o, "remote_opt_in_at")}
	ck.put(&o, "updated_at", "now()")
	body := ck.obj_done(&o)
	body, _ = strings.replace(body, `"updated_at":"now()"`, fmt.tprintf(`"updated_at":%s`, ck.quote(now_iso())), 1, context.temp_allocator)
	_, e := ck.upsert(c, "assistant_settings", body, "identity_id", context.temp_allocator)
	return ck.ok(e) ? "" : e.message
}

now_iso :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

today_text :: proc() -> string {
	if d := os.get_env("PALM_TODAY", context.temp_allocator); d != "" {return d}
	y, mo, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
}

// ---------------------------------------------------------------------------
// The scope check
// ---------------------------------------------------------------------------

@(private = "file")
KIND_WORDS := [?][2]string {
	{"personal", "personal"}, {"personal", "private"}, {"personal", "home"},
	{"work", "work"}, {"work", "job"}, {"work", "office"},
	{"public", "public"}, {"project", "project"}, {"project", "side-project"},
}

@(private = "file")
NOUNS_AFTER := [?]string {
	"identity", "mail", "email", "emails", "inbox", "mailbox", "files", "file", "drive", "calendar", "agenda",
	"notes", "note", "account", "messages", "contacts", "chats", "chat", "documents", "docs", "stuff", "side", "life", "self",
}

@(private = "file")
tokens_of :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	flush :: proc(out: ^[dynamic]string, b: ^strings.Builder) {
		if strings.builder_len(b^) > 0 {
			append(out, strings.clone(strings.trim(strings.to_string(b^), ".-"), context.temp_allocator))
			strings.builder_reset(b)
		}
	}
	for r in strings.to_lower(s, context.temp_allocator) {
		alnum := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r > 127 || r == '.' || r == '@' || r == '-' || r == '_' || r == '\''
		if alnum {
			strings.write_rune(&b, r)
		} else {
			flush(&out, &b)
		}
	}
	flush(&out, &b)
	return out[:]
}

// other_identity_named reports another of the person's identities that a
// request names: by its address or @handle, by the part of its display name
// that is not the person's own name ("Northwind"), or by its kind used as one
// ("my personal mail", "the work calendar"). It is deliberately simple and
// errs towards refusing; a refusal costs the person one rephrasing, an
// answer drawn from the wrong identity costs the separation.
other_identity_named :: proc(request: string, self: ck.Identity, all: []ck.Identity, person_name := "") -> (ck.Identity, string, bool) {
	toks := tokens_of(request)
	low := strings.to_lower(request, context.temp_allocator)
	own_words := tokens_of(fmt.tprintf("%s %s", self.display_name, person_name))
	for y in all {
		if y.id == self.id || y.archived {continue}
		if strings.contains(low, fmt.tprintf("%s@", y.handle)) || strings.contains(low, fmt.tprintf("@%s", y.handle)) {
			return y, fmt.tprintf("it names %s", y.handle), true
		}
		for w in tokens_of(y.display_name) {
			// Words shared with this identity's own name (the person's name)
			// say nothing about which identity is meant.
			shared := false
			for o in own_words {if o == w {shared = true}}
			// A name that is also a kind word ("Personal", "Work") is matched
			// by the kind rule below, which wants it used as an identity ("my
			// personal mail"), not as an adjective ("a personal note").
			for kw in KIND_WORDS {if kw[1] == w {shared = true}}
			if shared || len(w) < 4 {continue}
			for t in toks {
				if t == w || t == fmt.tprintf("%s's", w) {
					return y, fmt.tprintf("it names %s", y.display_name), true
				}
			}
		}
		if y.kind != self.kind {
			for kw in KIND_WORDS {
				if kw[0] != y.kind {continue}
				for t, i in toks {
					if t != kw[1] {continue}
					next := i + 1 < len(toks) ? toks[i + 1] : ""
					prev := i > 0 ? toks[i - 1] : ""
					// "my personal mail", "the work calendar": the kind used to
					// name an identity's things. "a personal note" is not.
					owner := prev == "my" || prev == "the" || prev == "our" || prev == "in" || prev == "from" || prev == "on"
					for n in NOUNS_AFTER {
						if next == n && owner {return y, fmt.tprintf("it asks about the %s %s", kw[1], n), true}
					}
					if prev == "my" && (next == "" || next == "one" || next == "side") {
						return y, fmt.tprintf("it asks about \"my %s\"", kw[1]), true
					}
				}
			}
		}
	}
	return {}, "", false
}

scope_refusal_text :: proc(self, other: ck.Identity) -> string {
	return fmt.tprintf(
		"This is the %s assistant, and it can only see %s. %s's mail, files, notes and calendar are outside its reach, so it has not looked and will not. Ask the %s assistant instead.",
		self.display_name, self.display_name, other.display_name, other.display_name)
}

// ---------------------------------------------------------------------------
// Model brokering
// ---------------------------------------------------------------------------

@(private = "file")
messages_json :: proc(msgs: []en.Turn, skip_system := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n := 0
	for m in msgs {
		if skip_system && m.role == "system" {continue}
		if n > 0 {strings.write_byte(&b, ',')}
		fmt.sbprintf(&b, `{{"role":%s,"content":%s}}`, ck.quote(m.role), ck.quote(m.content))
		n += 1
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

ollama_call :: proc(model: string, call: en.Model_Call) -> en.Model_Reply {
	start := time.tick_now()
	u, ok := ck.parse_url(ollama_url())
	if !ok {return {err = "bad OLLAMA_HOST"}}
	o := ck.obj()
	ck.put(&o, "model", model)
	ck.put_raw(&o, "messages", messages_json(call.messages))
	ck.put(&o, "stream", false)
	ck.put(&o, "think", false)
	if call.format != "" {ck.put_raw(&o, "format", call.format)}
	opts := ck.obj()
	ck.put_raw(&opts, "temperature", call.purpose == "answer" ? "0.3" : "0")
	ck.put(&opts, "num_predict", i64(call.max_tokens > 0 ? call.max_tokens : 400))
	ck.put(&opts, "num_ctx", i64(8192))
	ck.put_raw(&o, "options", ck.obj_done(&opts))
	body := ck.obj_done(&o)
	resp, err := ck.http_do(u, ck.Request{
		method = "POST", path = "/api/chat", body = transmute([]u8)body, timeout_ms = 180000,
		headers = {{"Content-Type", "application/json"}},
	})
	ms := i64(time.duration_milliseconds(time.tick_since(start)))
	if err != "" {
		return {err = fmt.aprintf("ollama is not reachable at %s (%s); start it with `ollama serve`", ollama_url(), err), ms = ms}
	}
	defer ck.response_destroy(&resp)
	v, pok := ck.parse(resp.body, context.temp_allocator)
	if resp.status != 200 || !pok {
		return {err = fmt.aprintf("ollama answered %d: %s", resp.status, ck.get_str(v, "error")), ms = ms}
	}
	text := ck.get_str(v, "message", "content")
	if i := strings.index(text, "</think>"); i >= 0 {text = text[i + len("</think>"):]}
	return {text = strings.clone(strings.trim_space(text)), ms = ms}
}

// anthropic_call goes to the Messages API with curl, from this process only.
// It runs only for an identity whose settings record the person's opt-in,
// and the key comes from this process's environment ($ANTHROPIC_API_KEY),
// which the assistant's sandbox never sees.
anthropic_call :: proc(model: string, call: en.Model_Call) -> en.Model_Reply {
	start := time.tick_now()
	key := os.get_env("ANTHROPIC_API_KEY", context.temp_allocator)
	if key == "" {return {err = "the remote provider is chosen for this identity but ANTHROPIC_API_KEY is not set"}}
	system := ""
	for m in call.messages {if m.role == "system" {system = m.content}}
	o := ck.obj()
	ck.put(&o, "model", model)
	ck.put(&o, "max_tokens", i64(max(call.max_tokens * 4, 2048)))
	ck.put(&o, "system", system)
	ck.put_raw(&o, "messages", messages_json(call.messages, skip_system = true))
	oc := ck.obj()
	ck.put(&oc, "effort", "low")
	if call.format != "" {
		// Structured outputs want closed objects.
		f, _ := strings.replace(call.format, `"type":"object",`, `"type":"object","additionalProperties":false,`, -1, context.temp_allocator)
		ck.put_raw(&oc, "format", fmt.tprintf(`{{"type":"json_schema","schema":%s}}`, f))
	}
	ck.put_raw(&o, "output_config", ck.obj_done(&oc))
	ck.put(&o, "fallbacks", "default")
	body := ck.obj_done(&o)
	dir := fmt.tprintf("%s/.cache/palm-ai", home_dir())
	os.make_directory_all(dir, os.perm_number(0o700))
	bodyf := fmt.tprintf("%s/req-%d.json", dir, os.get_pid())
	keyf := fmt.tprintf("%s/hdr-%d", dir, os.get_pid())
	_ = os.write_entire_file(bodyf, transmute([]u8)body, os.perm_number(0o600))
	_ = os.write_entire_file(keyf, transmute([]u8)fmt.tprintf("x-api-key: %s\n", key), os.perm_number(0o600))
	defer os.remove(bodyf)
	defer os.remove(keyf)
	state, out, errb, perr := os.process_exec({command = {
		"curl", "-sS", "--max-time", "300", "https://api.anthropic.com/v1/messages",
		"-H", fmt.tprintf("@%s", keyf), "-H", "anthropic-version: 2023-06-01",
		"-H", "anthropic-beta: server-side-fallback-2026-07-01",
		"-H", "content-type: application/json", "--data-binary", fmt.tprintf("@%s", bodyf),
	}}, context.temp_allocator)
	ms := i64(time.duration_milliseconds(time.tick_since(start)))
	if perr != nil || state.exit_code != 0 {
		return {err = fmt.aprintf("the remote provider could not be reached (%s)", strings.trim_space(string(errb))), ms = ms}
	}
	v, ok := ck.parse(string(out), context.temp_allocator)
	if !ok {return {err = "the remote provider's answer was not JSON", ms = ms}}
	if ck.get_str(v, "type") == "error" {
		return {err = fmt.aprintf("the remote provider refused: %s", ck.get_str(v, "error", "message")), ms = ms}
	}
	if ck.get_str(v, "stop_reason") == "refusal" {
		return {err = "the remote model declined this request", ms = ms}
	}
	b := strings.builder_make(context.temp_allocator)
	for blk in ck.array(ck.get(v, "content")) {
		if ck.get_str(blk, "type") == "text" {strings.write_string(&b, ck.get_str(blk, "text"))}
	}
	return {text = strings.clone(strings.to_string(b)), ms = ms}
}

// ---------------------------------------------------------------------------
// Running the assistant
// ---------------------------------------------------------------------------

Event_Sink :: proc(data: rawptr, line: string, v: ck.Value)

Outcome :: struct {
	conversation_id: string,
	answer:          string,
	refused:         bool, // the scope check answered instead
	refusal:         string,
	proposals:       [dynamic]string, // action ids
	events:          [dynamic]string,
	model_calls:     int,
	ms:              i64,
	error:           string,
	sandbox:         string, // the child's sandbox report, as JSON
	provider:        string,
	model:           string,
}

Ask :: struct {
	handle:          string,
	request:         string,
	conversation_id: string, // "" starts a new one
	max_steps:       int,
	sink:            Event_Sink,
	sink_data:       rawptr,
	cancel:          ^bool,
	// For tests: skip the database (no conversation, no log) — never set by
	// the CLI or the window.
	no_persist:      bool,
}

@(private = "file")
line_reader :: struct {
	f:   ^os.File,
	buf: [dynamic]u8,
}

@(private = "file")
read_line :: proc(r: ^line_reader) -> (line: string, ok: bool) {
	for {
		for c, i in r.buf {
			if c == '\n' {
				line = strings.clone(string(r.buf[:i]), context.temp_allocator)
				remove_range(&r.buf, 0, i + 1)
				return line, true
			}
		}
		chunk: [16384]u8
		n, err := os.read(r.f, chunk[:])
		if n <= 0 || err != nil {
			if len(r.buf) > 0 {
				line = strings.clone(string(r.buf[:]), context.temp_allocator)
				clear(&r.buf)
				return line, true
			}
			return "", false
		}
		append(&r.buf, ..chunk[:n])
	}
}

@(private = "file")
write_line :: proc(f: ^os.File, s: string) {
	data := transmute([]u8)fmt.tprintf("%s\n", s)
	for len(data) > 0 {
		n, err := os.write(f, data)
		if err != nil || n <= 0 {return}
		data = data[n:]
	}
}

// history_of loads the last turns of a conversation, for context.
history_of :: proc(c: ^ck.Client, conv: string) -> []en.Turn {
	out := make([dynamic]en.Turn, context.temp_allocator)
	if conv == "" {return out[:]}
	v, e := ck.select(c, "assistant_messages", fmt.tprintf("select=role,content&conversation_id=eq.%s&role=in.(user,assistant)&order=seq.desc&limit=6", conv), context.temp_allocator)
	if !ck.ok(e) {return out[:]}
	rows := ck.array(v)
	for i := len(rows) - 1; i >= 0; i -= 1 {
		append(&out, en.Turn{ck.get_str(rows[i], "role"), ck.get_str(rows[i], "content")})
	}
	return out[:]
}

@(private = "file")
next_seq :: proc(c: ^ck.Client, conv: string) -> int {
	v, e := ck.select(c, "assistant_messages", fmt.tprintf("select=seq&conversation_id=eq.%s&order=seq.desc&limit=1", conv), context.temp_allocator)
	if !ck.ok(e) || len(ck.array(v)) == 0 {return 0}
	return int(ck.get_int(ck.array(v)[0], "seq")) + 1
}

add_message :: proc(c: ^ck.Client, ident: ck.Identity, conv: string, role, content: string, tool := "", tainted := false) {
	if conv == "" {return}
	o := ck.obj()
	ck.put(&o, "identity_id", ident.id)
	ck.put(&o, "conversation_id", conv)
	ck.put(&o, "seq", i64(next_seq(c, conv)))
	ck.put(&o, "role", role)
	ck.put(&o, "content", content)
	if tool != "" {ck.put_raw(&o, "tool", tool)}
	ck.put(&o, "tainted", tainted)
	ck.insert(c, "assistant_messages", ck.obj_done(&o), context.temp_allocator)
	uo := ck.obj()
	ck.put(&uo, "updated_at", now_iso())
	ck.update(c, "assistant_conversations", fmt.tprintf("id=eq.%s", conv), ck.obj_done(&uo), context.temp_allocator)
}

title_of :: proc(request: string) -> string {
	t := strings.join(strings.fields(request, context.temp_allocator), " ", context.temp_allocator)
	if len(t) > 60 {
		cut := 57
		for cut > 0 && (t[cut] & 0xC0) == 0x80 {cut -= 1}
		t = fmt.tprintf("%s…", t[:cut])
	}
	if t == "" {t = "New conversation"}
	return t
}

log_person :: proc(c: ^ck.Client, ident: ck.Identity, conv, tool, status, summary: string) {
	o := ck.obj()
	ck.put(&o, "identity_id", ident.id)
	if conv != "" {ck.put(&o, "conversation_id", conv)}
	ck.put(&o, "tool", tool)
	ck.put(&o, "class", "read")
	ck.put(&o, "status", status)
	ck.put(&o, "summary", summary)
	ck.insert(c, "assistant_actions", ck.obj_done(&o), context.temp_allocator)
}

// assist runs one request for one identity, end to end.
assist :: proc(p: ^Person, ask: Ask) -> (out: Outcome) {
	out.proposals = make([dynamic]string)
	out.events = make([dynamic]string)
	ident, found := find_ident(p, ask.handle)
	if !found {
		out.error = fmt.aprintf("no identity %q on this account (or not in this process's scope)", ask.handle)
		return
	}
	if ident.archived {
		out.error = fmt.aprintf("%s is archived", ident.handle)
		return
	}
	mc, merr := machine_session(p, ident)
	if merr != "" {
		out.error = strings.clone(merr)
		return
	}
	settings, serr := settings_get(mc, ident)
	if serr != "" {
		out.error = strings.clone(serr)
		return
	}
	if !settings.enabled {
		out.error = fmt.aprintf("the %s assistant is off. Turn it on with: ai enable --identity %s", ident.display_name, ident.handle)
		return
	}
	out.provider = strings.clone(settings.provider)
	out.model = strings.clone(settings.provider == "anthropic" ? (settings.remote_model != "" ? settings.remote_model : REMOTE_MODEL_DEFAULT) : settings.model)

	// The conversation.
	conv := ask.conversation_id
	if conv == "" && !ask.no_persist {
		o := ck.obj()
		ck.put(&o, "identity_id", ident.id)
		ck.put(&o, "title", title_of(ask.request))
		ck.put(&o, "model", out.model)
		ck.put(&o, "provider", out.provider)
		v, e := ck.insert(mc, "assistant_conversations", ck.obj_done(&o), context.temp_allocator)
		if !ck.ok(e) {
			out.error = fmt.aprintf("could not start a conversation: %s", e.message)
			return
		}
		conv = ck.get_str(ck.array(v)[0], "id")
	}
	out.conversation_id = strings.clone(conv)
	history := ask.no_persist ? nil : history_of(mc, conv)
	if !ask.no_persist {add_message(mc, ident, conv, "user", ask.request)}

	// The scope check, before anything starts.
	person_name := ""
	if other, why, named := other_identity_named(ask.request, ident, p.identities, person_name); named {
		out.refused = true
		out.refusal = strings.clone(scope_refusal_text(ident, other))
		out.answer = out.refusal
		if !ask.no_persist {
			add_message(mc, ident, conv, "notice", out.refusal)
			log_person(mc, ident, conv, "scope_check", "refused", fmt.tprintf("Refused before starting: %s (%s).", why, other.display_name))
		}
		return
	}

	sess, derr := delegated_session(p, ident)
	if derr != "" {
		out.error = strings.clone(derr)
		return
	}

	// Start the assistant: this binary as `ai agent`, environment built from
	// nothing, stderr to a log in its own directory.
	dir := state_dir(ident.handle)
	self, _ := os.get_executable_path(context.temp_allocator)
	ports := fmt.tprintf("%d,%d", port_of(cloud_url(), 54321), port_of(dav_url(), 59580))
	env := make([dynamic]string, context.temp_allocator)
	append(&env,
		fmt.tprintf("HOME=%s", home_dir()),
		"PATH=/usr/bin:/bin",
		fmt.tprintf("PALM_CLOUD_URL=%s", cloud_url()),
		fmt.tprintf("PALM_CLOUD_SESSION=%s", sess),
		fmt.tprintf("PALM_CLOUD_DIR=%s/cloud", dir),
		fmt.tprintf("PALM_IDENTITY=%s", ident.handle),
		fmt.tprintf("PALM_DAV_URL=%s", dav_url()),
		"PALM_DAV_CACHE=dav", // relative to the state directory; see run_argv
		fmt.tprintf("PALM_ASSISTANT_STATE=%s", dir),
		fmt.tprintf("PALM_INDEX_DIR=%s/.local/share/palm/index", home_dir()),
		fmt.tprintf("PALMY_NOTES_DIR=%s/Notes/%s", home_dir(), ident.handle),
		fmt.tprintf("PALM_AUDIT=%s/audit.jsonl", dir),
		fmt.tprintf("TMPDIR=%s/tmp", dir),
		"XDG_DATA_HOME=",
		"LANG=C.UTF-8",
	)
	if os.get_env("PALM_ASSISTANT_TRACE", context.temp_allocator) != "" {append(&env, "PALM_ASSISTANT_TRACE=1")}
	if k := os.get_env("PALM_CLOUD_ANON_KEY", context.temp_allocator); k != "" {
		append(&env, fmt.tprintf("PALM_CLOUD_ANON_KEY=%s", k))
	}
	if tz := os.get_env("TZ", context.temp_allocator); tz != "" {append(&env, fmt.tprintf("TZ=%s", tz))}
	os.make_directory_all(fmt.tprintf("%s/tmp", dir), os.perm_number(0o700))

	in_r, in_w, e1 := os.pipe()
	out_r, out_w, e2 := os.pipe()
	if e1 != nil || e2 != nil {
		out.error = "could not make pipes"
		return
	}
	logf, _ := os.open(fmt.tprintf("%s/agent.log", dir), {.Write, .Create, .Trunc}, os.perm_number(0o600))
	proc_, perr := os.process_start({
		command = {self, "agent", "--handle", ident.handle, "--ports", ports, "--tools", tools_dir()},
		env = env[:],
		working_dir = dir,
		stdin = in_r,
		stdout = out_w,
		stderr = logf,
	})
	os.close(in_r)
	os.close(out_w)
	if logf != nil {os.close(logf)}
	if perr != nil {
		os.close(in_w)
		os.close(out_r)
		out.error = fmt.aprintf("could not start the assistant (%v)", perr)
		return
	}

	addr := ""
	mv, me := ck.rpc(mc, "mail_identities", "{}", context.temp_allocator)
	if ck.ok(me) {
		for r in ck.array(mv) {
			if ck.get_str(r, "id") == ident.id {addr = ck.get_str(r, "address")}
		}
	}
	req := en.Request {
		request         = ask.request,
		conversation_id = conv,
		today           = today_text(),
		identity        = {handle = ident.handle, name = ident.display_name, kind = ident.kind, address = addr},
		history         = history,
		max_steps       = ask.max_steps > 0 ? ask.max_steps : 6,
	}
	write_line(in_w, en.request_json(req, context.temp_allocator))

	replay := replay_open()
	rd := line_reader{f = out_r, buf = make([dynamic]u8)}
	defer delete(rd.buf)
	start := time.tick_now()
	tool_lines := make([dynamic]string, context.temp_allocator)
	tainted := false
	for {
		if ask.cancel != nil && sync.atomic_load(ask.cancel) {
			_ = os.process_kill(proc_)
			out.error = "stopped"
			break
		}
		line, ok := read_line(&rd)
		if !ok {break}
		v, pok := ck.parse(line, context.temp_allocator)
		if !pok {continue}
		t := ck.get_str(v, "t")
		if t == "model" {
			call := en.parse_model_call(v, context.temp_allocator)
			reply: en.Model_Reply
			if replay != nil {
				reply = replay_next(replay, call)
			} else if settings.provider == "anthropic" && settings.opted_in_at != "" {
				reply = anthropic_call(out.model, call)
			} else {
				reply = ollama_call(settings.model, call)
			}
			out.model_calls += 1
			write_line(in_w, en.model_reply_json(int(ck.get_int(v, "id")), reply))
			if reply.err != "" && ask.sink != nil {
				eo := ck.obj()
				ck.put(&eo, "t", "error")
				ck.put(&eo, "message", reply.err)
				el := ck.obj_done(&eo)
				ev, _ := ck.parse(el, context.temp_allocator)
				ask.sink(ask.sink_data, el, ev)
			}
			continue
		}
		append(&out.events, strings.clone(line))
		if ask.sink != nil {ask.sink(ask.sink_data, line, v)}
		switch t {
		case "sandbox":
			out.sandbox = strings.clone(line)
		case "proposal":
			append(&out.proposals, strings.clone(ck.get_str(v, "action_id")))
			append(&tool_lines, line)
		case "result", "draft", "refused", "step":
			if t != "step" {append(&tool_lines, line)}
			if ck.get_bool(v, "untrusted") {tainted = true}
		case "answer":
			out.answer = strings.clone(ck.get_str(v, "text"))
		case "error":
			if out.error == "" {out.error = strings.clone(ck.get_str(v, "message"))}
		}
	}
	os.close(in_w)
	os.close(out_r)
	_, _ = os.process_wait(proc_, 5 * time.Second)
	out.ms = i64(time.duration_milliseconds(time.tick_since(start)))

	if !ask.no_persist {
		for l in tool_lines {
			lv, _ := ck.parse(l, context.temp_allocator)
			summary := ck.get_str(lv, "summary")
			if summary == "" {summary = ck.get_str(lv, "why")}
			add_message(mc, ident, conv, "tool", fmt.tprintf("%s: %s", ck.get_str(lv, "tool"), summary), tool = trim_data(l), tainted = ck.get_bool(lv, "untrusted"))
		}
		if out.answer != "" {
			add_message(mc, ident, conv, "assistant", out.answer, tainted = tainted)
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Replay: a scripted model, for tests
//
// $PALM_ASSISTANT_REPLAY names a file of model replies, one JSON string per
// line, used in order instead of any provider. It is how the end-to-end
// test plays a model that has been fully taken over by an injected mail —
// one that answers every step with whatever the attacker wants — and checks
// what the runtime and the database let through. Off unless the variable is
// set; nothing in the window sets it.
// ---------------------------------------------------------------------------

Replay :: struct {
	lines: []string,
	at:    int,
}

replay_open :: proc() -> ^Replay {
	path := os.get_env("PALM_ASSISTANT_REPLAY", context.temp_allocator)
	if path == "" {return nil}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return nil}
	r := new(Replay)
	lines := make([dynamic]string)
	for l in strings.split_lines(string(data)) {
		if strings.trim_space(l) != "" {append(&lines, l)}
	}
	r.lines = lines[:]
	return r
}

replay_next :: proc(r: ^Replay, call: en.Model_Call) -> en.Model_Reply {
	if r.at >= len(r.lines) {
		return {text = call.purpose == "choose" ? `{"tool":"answer"}` : "(the script has ended)"}
	}
	line := r.lines[r.at]
	r.at += 1
	// Each line is a JSON string holding the reply, so replies can contain
	// newlines and quotes.
	v, ok := ck.parse(line, context.temp_allocator)
	if s, sok := v.(json.String); ok && sok {return {text = strings.clone(s)}}
	return {text = strings.clone(line)}
}

// trim_data keeps a tool event for the history without the bulk of its data.
@(private = "file")
trim_data :: proc(line: string) -> string {
	if len(line) <= 8000 {return line}
	v, ok := ck.parse(line, context.temp_allocator)
	if !ok {return "{}"}
	o := ck.obj()
	for k in ([?]string{"t", "tool", "summary", "why", "action_id"}) {
		if s := ck.get_str(v, k); s != "" {ck.put(&o, k, s)}
	}
	ck.put(&o, "ok", ck.get_bool(v, "ok"))
	return ck.obj_done(&o)
}

// ---------------------------------------------------------------------------
// Confirming
// ---------------------------------------------------------------------------

Action :: struct {
	id, tool, class, status, summary: string,
	args:     ck.Value,
	warnings: ck.Value,
	sources:  ck.Value,
	tainted:  bool,
	created:  string,
	conv:     string,
	result:   ck.Value,
}

action_from :: proc(r: ck.Value) -> Action {
	return Action {
		id = ck.get_str(r, "id"), tool = ck.get_str(r, "tool"), class = ck.get_str(r, "class"),
		status = ck.get_str(r, "status"), summary = ck.get_str(r, "summary"), args = ck.get(r, "args"),
		warnings = ck.get(r, "warnings"), sources = ck.get(r, "sources"), tainted = ck.get_bool(r, "tainted"),
		created = ck.get_str(r, "created_at"), conv = ck.get_str(r, "conversation_id"), result = ck.get(r, "result"),
	}
}

actions_list :: proc(c: ^ck.Client, ident: ck.Identity, pending_only := false, limit := 50, conv := "") -> (out: []Action, err: string) {
	q := fmt.tprintf("select=*&identity_id=eq.%s&order=created_at.desc&limit=%d%s%s", ident.id, limit,
		pending_only ? "&status=eq.proposed" : "", conv != "" ? fmt.tprintf("&conversation_id=eq.%s", conv) : "")
	v, e := ck.select(c, "assistant_actions", q, context.temp_allocator)
	if !ck.ok(e) {return nil, e.message}
	rows := ck.array(v)
	list := make([]Action, len(rows), context.temp_allocator)
	for r, i in rows {list[i] = action_from(r)}
	return list, ""
}

// confirm_argv rebuilds the command line for a confirmed action from the
// recorded arguments and the tool's own declaration — the same rules the
// assistant's proposals were made under, applied again here, outside the
// sandbox, so a tampered row cannot name a tool or flag that is not offered.
confirm_argv :: proc(a: Action, reg: ^en.Registry, handle: string) -> (argv: []string, err: string) {
	t := en.find_tool(reg, a.tool)
	if t == nil {return nil, fmt.tprintf("%s is not a tool this assistant offers", a.tool)}
	if t.class != .Confirm {return nil, fmt.tprintf("%s is not something the person confirms", a.tool)}
	args := make(map[string]string, allocator = context.temp_allocator)
	if obj, ok := a.args.(json.Object); ok {
		for k, v in obj {
			s, sok := v.(string)
			if !sok {continue}
			known := false
			for p in t.params {if p.name == k {known = true}}
			if !known {return nil, fmt.tprintf("%s takes no argument %q", a.tool, k)}
			args[k] = s
		}
	}
	if t.name == "calendar_add" {
		// The runtime, not the model, says where an event goes: the
		// identity's own calendar in the cloud.
		args["calendar"] = fmt.tprintf("%s/default", handle)
	}
	return en.argv_for(t, args), ""
}

decide :: proc(c: ^ck.Client, id: string, status: string, result := "") -> string {
	o := ck.obj()
	ck.put(&o, "status", status)
	if result != "" {ck.put_raw(&o, "result", result)}
	v, e := ck.update(c, "assistant_actions", fmt.tprintf("id=eq.%s", id), ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {return e.message}
	if len(ck.array(v)) == 0 {return "no such action in this identity's log"}
	return ""
}

// confirm runs a proposal as the person: proposed -> confirmed, then the
// tool, with this machine's session for the identity, then -> executed or
// failed with the tool's own answer as the result.
confirm :: proc(p: ^Person, handle, id: string) -> (result: string, err: string) {
	ident, found := find_ident(p, handle)
	if !found {return "", fmt.tprintf("no identity %q", handle)}
	mc, merr := machine_session(p, ident)
	if merr != "" {return "", merr}
	v, e := ck.select(mc, "assistant_actions", fmt.tprintf("select=*&id=eq.%s&identity_id=eq.%s", id, ident.id), context.temp_allocator)
	if !ck.ok(e) {return "", e.message}
	if len(ck.array(v)) == 0 {return "", "no such action in this identity's log"}
	a := action_from(ck.array(v)[0])
	if a.status != "proposed" {return "", fmt.tprintf("this action is %s, not waiting for a decision", a.status)}
	reg := en.load_registry(tools_dir(), context.temp_allocator)
	argv, aerr := confirm_argv(a, &reg, ident.handle)
	if aerr != "" {
		decide(mc, id, "declined")
		return "", aerr
	}
	if de := decide(mc, id, "confirmed"); de != "" {return "", de}

	env := make([dynamic]string, context.temp_allocator)
	for k in ([?]string{"HOME", "PATH", "PALM_CLOUD_URL", "PALM_CLOUD_ANON_KEY", "PALM_CLOUD_DIR", "PALM_DAV_URL", "PALM_DAV_CACHE", "XDG_DATA_HOME", "PALM_AUDIT", "LANG", "TZ"}) {
		if val, ok := os.lookup_env(k, context.temp_allocator); ok {append(&env, fmt.tprintf("%s=%s", k, val))}
	}
	append(&env, fmt.tprintf("PALM_IDENTITY=%s", ident.handle), "WAYLAND_DISPLAY=", "DISPLAY=")
	state, out, errb, perr := os.process_exec({command = argv, env = env[:]}, context.temp_allocator)
	ok := perr == nil && state.exit_code == 0
	res := strings.trim_space(string(out))
	if _, jok := ck.parse(res, context.temp_allocator); !jok {
		o := ck.obj()
		ck.put(&o, "output", res)
		ck.put(&o, "stderr", strings.trim_space(string(errb)))
		res = ck.obj_done(&o)
	}
	decide(mc, id, ok ? "executed" : "failed", res)
	if !ok {
		rv, _ := ck.parse(res, context.temp_allocator)
		d := ck.get_str(rv, "detail")
		if d == "" {d = strings.trim_space(string(errb))}
		return res, fmt.tprintf("it ran and failed: %s", d)
	}
	return res, ""
}

decline :: proc(p: ^Person, handle, id: string) -> string {
	ident, found := find_ident(p, handle)
	if !found {return fmt.tprintf("no identity %q", handle)}
	mc, merr := machine_session(p, ident)
	if merr != "" {return merr}
	return decide(mc, id, "declined")
}

